## A backend mod: routes, the database, config.
##
##     aowl build-mod examples/gameserver
##
## The point of reading this next to `examples/lesson` is that they are the
## same shape. One reaches into a running game, the other answers HTTP, and
## both are a nimony file that names things and hands back values.
##
## (It pointed at `examples/highlevel` until 2026-08-19. That file is the
## client host's regression test and says in its own first line that it is not
## the one to copy from; `examples/lesson` is, and its sections 8 to 13 are the
## game-side half of the comparison.)
##
## ## What it changes, exactly
##
## Two paths in the database, and nothing else:
##
##   `aowlspt.demo.created`  a path of its own that the database never held.
##                           Its own corner; nothing else reads it.
##   `templates.items.5447a9cd4bdc2dbd208b4567._props.Weight`
##                           the M4A1's weight, multiplied by
##                           `weightMultiplier` from `config.json` (0.5 as
##                           shipped, so the rifle ends up half its weight).
##
## **The change is to the database the server holds in memory, for the life of
## that server process.** Nothing here rewrites SPT's JSON on disk, so a restart
## without the mod puts the item back. It is still live while the server is up,
## which is why `examples/` is not staged into a real install — `aowl run` and
## the backend's own stage are where this is meant to run.
##
## And it multiplies **on every load**: this mod loaded twice, or reloaded by
## the mod manager, halves that weight twice. A mod that wanted to be idempotent
## would have to record the original somewhere it owns and scale from that; this
## one is a demonstration of `dbWrite`, and says so rather than pretending the
## question does not arise.

import std/strutils
import aowlspt
import aowlspt/server

var hits = 0
var weightMultiplier = 1.0

proc onStatus(url, body, session: string): string =
  ## An exact route.
  inc hits
  var o = obj()
  put(o, "ok", true)
  put(o, "mod", "aowl.gameserver")
  put(o, "hits", hits)
  put(o, "session", session)
  result = done(o).text

proc onEcho(url, body, session: string): string =
  ## Proves the request body survived the round trip. The client compresses
  ## every body, so "it returned 200" alone does not establish that the payload
  ## arrived intact — echoing it back does.
  inc hits
  var o = obj()
  put(o, "ok", true)
  put(o, "echo", body)
  put(o, "length", body.len)
  result = done(o).text

proc onItem(url, body, session: string): string =
  ## A prefix route: everything under `/aowlspt/item/` lands here and the id
  ## comes out of the path. Most of the client's real endpoints are shaped this
  ## way.
  inc hits
  let id = pathAfter(url, "/aowlspt/item/")
  if id.len == 0:
    return errJson("no item id in " & url)

  let weight = dbRead("templates.items." & id & "._props.Weight")
  if not weight.ok:
    return errJson("no such item: " & id)

  var o = obj()
  put(o, "ok", true)
  put(o, "id", id)
  put(o, "weight", weight.asFloat())
  result = done(o).text

proc onCreated(url, body, session: string): string =
  ## Reads back a database path this mod created at load. Served as a route so
  ## the backend's self test can assert it over the wire rather than trusting a
  ## log line.
  let v = dbRead("aowlspt.demo.created.by")
  var o = obj()
  put(o, "ok", v.ok)
  put(o, "by", v.asText())
  result = done(o).text

proc onLoad(): Status =
  success "gameserver loaded on " & hostName()

  # `!= sideClient`, not `== sideServer`, and the difference is the whole
  # example working or silently not.
  #
  # It read `!= sideServer` and returned here, so under `aowlspt-sim` -- which
  # presents as `sim`, not `server` -- this mod registered **no routes and wrote
  # nothing to the database**. The gate's own `sim gameserver` run exercised the
  # two lines above and nothing else, and reported ok, because a run that does
  # nothing exits zero. `examples/hello` had the identical bug and the simulator
  # carries a bespoke "no route registered for..." message whose only job is to
  # explain the resulting confusion, which is how you can tell it has happened
  # to people.
  #
  # The client is the only host that genuinely refuses `route_register`, so the
  # guard belongs on the client and nowhere else.
  if side() == sideClient:
    info "this mod serves; there is no HTTP server inside the game"
    return Ok

  weightMultiplier = setting("weightMultiplier").asFloat(1.0)
  info "weightMultiplier = " & $weightMultiplier

  discard serve("/aowlspt/status", onStatus)
  discard serve("/aowlspt/echo", onEcho)
  discard servePrefix("/aowlspt/item/", onItem)
  discard serve("/aowlspt/created", onCreated)

  # A path the database has never held. `dbWrite` creates it rather than
  # refusing: a mod adding a table of its own -- a new location, its own
  # settings -- is the ordinary case, and refusing made that inexpressible.
  if dbWrite("aowlspt.demo.created", "{\"by\":\"gameserver\"}") == Ok:
    let back = dbRead("aowlspt.demo.created.by")
    if back.ok and back.asText() == "gameserver":
      success "created a database path that did not exist"
    else:
      warn "the created path did not read back"
  else:
    warn "could not create a database path: " & lastError()

  # A database patch. It merges, so a sibling field another mod set on the same
  # item survives this.
  const SampleItem = "templates.items.5447a9cd4bdc2dbd208b4567"
  let before = dbRead(SampleItem & "._props.Weight")
  if before.ok:
    info "weight before: " & $before.asFloat()
    var patch = obj()
    var props = obj()
    put(props, "Weight", before.asFloat() * weightMultiplier)
    put(patch, "_props", done(props))
    if dbWrite(SampleItem, done(patch)) == Ok:
      let after = dbRead(SampleItem & "._props.Weight")
      # The value is checked, not just printed. "dbWrite returned Ok" says the
      # call succeeded; a patch that merged into the wrong place leaves the
      # weight exactly as it was, and a line that printed "3.5 -> 3.5" as a
      # success would be reporting a failure in the voice of a success.
      #
      # With a tolerance, and not because floating point is vague: the number
      # went out as decimal digits and came back as decimal digits, and the
      # double rebuilt from those digits is not always the double that was
      # written. An exact test fails on a patch that worked.
      let wanted = before.asFloat() * weightMultiplier
      var diff = after.asFloat() - wanted
      if diff < 0.0:
        diff = -diff
      if after.ok and diff <= 0.0001 + wanted * 0.0001:
        success "weight " & $before.asFloat() & " -> " & $after.asFloat()
      else:
        warn "weight reads " & after.asText() & " after patching it to " &
             $wanted & ", so the patch did not land where it was aimed"
      # And the sibling must still be there — that is what "merge" means.
      let sibling = dbRead(SampleItem & "._props.Name")
      if sibling.ok:
        success "the sibling field survived the patch: " & sibling.asText()
      else:
        warn "the patch removed a sibling field, which it must not"
    else:
      warn "patch failed: " & lastError()
  else:
    info "no sample item in this database"

  Ok

proc onUnload(): Status =
  info "gameserver unloading after " & $hits & " requests"
  Ok

exportMod(
  guid = "aowl.gameserver",
  name = "Game Server",
  author = "aowlspt",
  version = "0.1.0",
  sptRange = "*",
  sides = {sideServer, sideSim},
  onLoad = onLoad,
  onUnload = onUnload)
