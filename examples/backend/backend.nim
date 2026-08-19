## A server-side mod that actually changes the game.
##
## Where examples/hello proves the plumbing, this one shows the surface a real
## backend mod uses: read its own config, patch the SPT database, serve a
## dynamic route, and reach anything the ABI does not name through `call`.
##
## ## What it changes, exactly
##
## One item: `templates.items.5447a9cd4bdc2dbd208b4567` — the M4A1 — whose
## `_props.Weight` it multiplies by `weightMultiplier` from `config.json`
## (0.5 as shipped, so the rifle ends up half its weight). It touches nothing
## else, and `dbPatch` merges, so every sibling property of that item is left
## exactly as it was.
##
## **The change is to the database the server holds in memory, for the life of
## that server process.** Nothing here rewrites SPT's JSON on disk; restart the
## server without the mod and the item is back to what it always was. It is
## still a live change to a running install — a raid started with this loaded
## has a half-weight M4A1 in it — so it is `examples/` and the installer
## deliberately does not stage it into a real game.
##
## Build:  aowl build-mod examples/backend
## Try it: aowl run examples/backend
##         (or drive the simulator directly, for the db and stub fixtures:
##          aowlspt-sim examples/backend --side server
##            --db examples/backend/testdb.json
##            --stubs examples/backend/stubs.json
##            --route /aowlspt/backend/status)

import std/strutils
import aowlspt

var
  weightMultiplier = 1.0
  itemsPatched = 0

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

proc parseNumber(raw: string; value: var float): bool =
  ## A bare JSON number out of a string, or false.
  ##
  ## A tiny hand parse: both callers get a bare number back from the host —
  ## a config value and a database value — and pulling in a whole JSON reader to
  ## turn "0.5" into a float would be the tail wagging the dog. `aowlspt/json`
  ## is there when a document has structure worth walking; see
  ## `examples/gameserver`, which reads the same weight through it.
  ##
  ## Exponent notation is refused rather than half-read: nothing writes `1e-3`
  ## into a weight, and a parser that stopped at the `e` would answer 1.0 with
  ## every appearance of success.
  value = 0.0
  var seenDot = false
  var scale = 0.1
  var any = false
  for ch in raw:
    if ch >= '0' and ch <= '9':
      any = true
      if seenDot:
        value = value + float(ord(ch) - ord('0')) * scale
        scale = scale * 0.1
      else:
        value = value * 10.0 + float(ord(ch) - ord('0'))
    elif ch == '.' and not seenDot:
      seenDot = true
    elif ch == ' ' or ch == '"':
      discard
    else:
      return false
  result = any

proc readConfig() =
  ## Config is JSON on disk next to the mod. Reading a missing key is not an
  ## error worth failing the load over — the default stands and we say so once.
  var raw = ""
  let st = configGet("weightMultiplier", raw)
  if st != Ok:
    info "no weightMultiplier configured, using " & $weightMultiplier
    return

  var value = 0.0
  let ok = parseNumber(raw, value)
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

  # The multiplier is applied to the weight that is actually there, rather than
  # a constant being written over it. That is the difference between a mod and a
  # mod that happens to agree with the database it was written against: another
  # mod may have already changed this weight, and a mod that writes `0.5`
  # regardless has silently undone it. It also means the config value does
  # something — a `weightMultiplier` that is read at load and then ignored is a
  # setting whose name is a lie.
  var before = 0.0
  if not parseNumber(current, before):
    warn "the weight at " & SampleItem & " is not a number (" & current &
         "), so there is nothing to scale"
    return

  let wanted = before * weightMultiplier
  let patchSt = dbPatch(SampleItem, """{"_props":{"Weight":""" & $wanted & "}}")
  if patchSt != Ok:
    warn "weight patch failed: " & lastError()
    return

  inc itemsPatched

  # Read it back. "dbPatch returned Ok" only says the call succeeded; reading
  # the value again is what proves the live object graph actually changed. And
  # the value is checked rather than printed: a patch that landed somewhere else
  # in the document, or not at all, still answers a weight here.
  var after = ""
  if dbGet(SampleItem & "._props.Weight", after) != Ok:
    warn "the weight could not be read back after patching: " & lastError()
    return
  # Compared with a tolerance, and not because floating point is vague. The
  # value went out as decimal digits and comes back as decimal digits, and
  # rebuilding 1.75 by adding 1 + 7/10 + 5/100 does not land on the same double
  # that 3.5 * 0.5 produced. An exact test here fails on a patch that worked
  # perfectly, which is a check that cries wolf at exactly the moment somebody
  # is deciding whether to trust it.
  var got = 0.0
  var diff = 0.0
  if parseNumber(after, got):
    diff = got - wanted
    if diff < 0.0:
      diff = -diff
  else:
    diff = 1.0e9
  if diff <= 0.0001 + wanted * 0.0001:
    success "weight " & current & " -> " & after & " (x" &
            $weightMultiplier & ")"
  else:
    warn "the weight reads " & after & " after patching it to " & $wanted &
         ", so the patch did not land where it was aimed"

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
