## A worked capability PROVIDER, and the fixture the mutation proofs run
## against.
##
## It publishes `items.spawn/1` -- the same name and the same request shape
## `mods/admin`'s `presetRequestJson()` already emits, so the migration note
## for that mod is "call it", not "reshape the payload":
##
##   request   {"preset":"Starter kit","lines":[{"q":"AKM","n":1,"c":85}, ...]}
##   response  {"ok":true,"spawned":<int>,"lines":<int>,"stash":<int>,
##              "items":["AKM x1 @85", ...]}
##
## It is a FIXTURE, not a spawner: the "stash" is a counter in this process and
## nothing here touches a profile or the database. That is the point -- the
## mutation proofs need a provider whose presence or absence is the only
## variable, and a real spawner would drag a database in with it. The real
## provider is `spawnInto()` in `mods/tarkov/emu/spawn.nim`; migrating it means
## adding a `provide("items.spawn", 1, ...)` that calls it, and nothing here
## needs to change for that to work.
##
## Build:  aowl build-mod examples/capprovider

import std/strutils
import aowlspt
import aowlspt/json
import aowlspt/capability

var gStash = 0

proc spawnHandler(request: string): CapReply =
  ## Refusals are specific and the mod says which line was wrong. A provider
  ## that answers "no" without saying why is only marginally better than one
  ## that answers "yes" without doing anything.
  if not strictObject(request):
    return capFail("the request is not a JSON object")
  let j = whole(request)
  let lines = j.field("lines")
  if not lines.isArray():
    return capFail("the request has no `lines` array")
  if lines.count() == 0:
    return capFail("the request names no lines, so there is nothing to spawn")

  var spawned = 0
  var items = newList()
  var i = 0
  while i < lines.count():
    let l = lines.at(i)
    let q = l.field("q").asText("")
    let n = l.field("n").asInt(0)
    let c = l.field("c").asInt(100)
    if q.len == 0:
      return capFail("line " & $i & " has no query")
    if n <= 0:
      return capFail("line " & $i & " (" & q & ") asks for " & $n & " items")
    if c < 0 or c > 100:
      return capFail("line " & $i & " (" & q & ") has condition " & $c &
                     ", which is not a percentage")
    spawned = spawned + n
    items.add quoted(q & " x" & $n & " @" & $c)
    inc i

  gStash = gStash + spawned
  var d = newDoc()
  d.setBool("ok", true)
  d.setNumber("spawned", spawned)
  d.setNumber("lines", lines.count())
  d.setNumber("stash", gStash)
  d.setRaw("items", text(items))
  result = capOk(text(d))

proc onLoad(): Status =
  # Published from `onLoad`, but nothing depends on that: resolution is lazy,
  # so a consumer that ran first simply gets a refusal until this line runs and
  # succeeds afterwards with no restart.
  let st = provide("items.spawn", 1, spawnHandler)
  if st != Ok:
    error "capprovider: could not publish items.spawn/1: " & lastError()
    return st
  info "capprovider: providing " & providedHere()[0]
  result = Ok

exportMod(
  guid = "aowl.capprovider", name = "Capability provider example",
  author = "aowlspt", version = "1.0.0", sptRange = "*",
  sides = {sideServer, sideSim}, onLoad = onLoad)
