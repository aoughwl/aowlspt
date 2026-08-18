## A backend mod: routes, the database, config.
##
##     aowl build-mod examples/gameserver
##
## The point of reading this next to `examples/highlevel` is that they are the
## same shape. One reaches into a running game, the other answers HTTP, and
## both are a nimony file that names things and hands back values.

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

  if side() != sideServer:
    info "this mod only serves on the backend"
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
      success "weight " & $before.asFloat() & " -> " & $after.asFloat()
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
