## A server-side mod that actually changes the game.
##
## Where examples/hello proves the plumbing, this one shows the surface a real
## backend mod uses: read its own config, patch the SPT database, serve a
## dynamic route, and reach anything the ABI does not name through `call`.
##
## Build:  pwsh tools/aowlspt-build.ps1 -Mod examples/backend
## Try it: aowlspt-sim examples/backend --side server --db examples/backend/testdb.json \
##           --stubs examples/backend/stubs.json --route /aowlspt/backend/status

import std/strutils
import aowlspt

var
  weightMultiplier = 1.0
  itemsPatched = 0

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

proc readConfig() =
  ## Config is JSON on disk next to the mod. Reading a missing key is not an
  ## error worth failing the load over — the default stands and we say so once.
  var raw = ""
  let st = configGet("weightMultiplier", raw)
  if st != Ok:
    info "no weightMultiplier configured, using " & $weightMultiplier
    return

  # A tiny hand parse: the value arrives as a bare JSON number, and pulling in a
  # whole JSON reader to turn "0.5" into a float would be the tail wagging the dog.
  var value = 0.0
  var seenDot = false
  var scale = 0.1
  var ok = false
  for ch in raw:
    if ch >= '0' and ch <= '9':
      ok = true
      if seenDot:
        value = value + float(ord(ch) - ord('0')) * scale
        scale = scale * 0.1
      else:
        value = value * 10.0 + float(ord(ch) - ord('0'))
    elif ch == '.':
      seenDot = true
    elif ch == ' ' or ch == '"':
      discard
    else:
      ok = false
      break

  if ok and value > 0.0:
    weightMultiplier = value
    info "weightMultiplier = " & $weightMultiplier
  else:
    warn "weightMultiplier is not a number (" & raw & "), keeping " & $weightMultiplier

# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------

proc applyDatabaseChanges() =
  ## `dbPatch` merges rather than replaces, which is the whole reason it is safe
  ## to run alongside other mods: writing `_props.Weight` leaves every sibling
  ## property of that item exactly as another mod left it.
  const SampleItem = "templates.items.5447a9cd4bdc2dbd208b4567"

  var current = ""
  let readSt = dbGet(SampleItem & "._props.Weight", current)
  if readSt != Ok:
    # On a live server the item exists; in the simulator it depends on --db.
    debug "no weight to read at " & SampleItem & " (" & lastError() & ")"
    return

  info "current weight: " & current

  let patchSt = dbPatch(SampleItem, """{"_props":{"Weight":0.5}}""")
  if patchSt != Ok:
    warn "weight patch failed: " & lastError()
    return

  inc itemsPatched

  # Read it back. "dbPatch returned Ok" only says the call succeeded; reading
  # the value again is what proves the live object graph actually changed.
  var after = ""
  if dbGet(SampleItem & "._props.Weight", after) == Ok:
    success "weight " & current & " -> " & after
  else:
    success "patched weight of " & SampleItem

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

proc onLoad(): Status =
  if side() != sideServer and side() != sideSim:
    # Declared for the client too so a single package can ship everywhere, but
    # there is nothing for this mod to do there.
    info "backend mod idle on the client"
    return Ok

  readConfig()
  applyDatabaseChanges()

  # A dynamic route matches by prefix, so one handler can serve a family of
  # URLs and read the tail as a parameter.
  discard route("/aowlspt/backend/", rkDynamic,
    proc (url, body, session: string): string =
      let tail = url[len("/aowlspt/backend/") .. ^1]
      case tail
      of "status":
        """{"ok":true,"itemsPatched":""" & $itemsPatched &
          ""","weightMultiplier":""" & $weightMultiplier & "}"
      of "reload":
        readConfig()
        """{"ok":true,"reloaded":true}"""
      else:
        """{"err":1,"errmsg":"unknown endpoint: """ & tail & "\"}")

  # The escape hatch. Anything the ABI does not name is still reachable by
  # name; this is the slow path, so it belongs in setup code, not a hot loop.
  var version = ""
  let st = call("SPTarkov.Server.Core.Utils.Watermark::GetVersionTag", "[]", version)
  if st == Ok:
    info "server watermark: " & version
  else:
    debug "watermark unavailable here: " & lastError()

  Ok

proc onUnload(): Status =
  info "backend mod unloading, patched " & $itemsPatched & " item(s)"
  Ok

exportMod(
  guid = "aowl.backend",
  name = "Backend Example",
  author = "aowlspt",
  version = "1.0.0",
  sptRange = "~4.1.0",
  sides = {sideServer, sideSim},
  onLoad = onLoad,
  onUnload = onUnload)
