## The SERVER side of the item spawner: drain the mailbox, call the emulator
## through a capability, put the answer back.
##
## ---------------------------------------------------------------------------
## THE CAPABILITY CONTRACT
## ---------------------------------------------------------------------------
##
## Name `aowl.items`, version 1. One capability with an `op`, rather than two
## capabilities, because search and spawn share a query grammar and a provider
## that could answer one but not the other would be a lie in either shape.
##
## REQUEST (an object; every other member is optional and ignored):
##
##   {"op":"search","query":"salewa","limit":10}
##   {"op":"spawn", "query":"salewa","count":3,"condition":100}
##   {"op":"spawn", "preset":"Starter kit",
##                  "lines":[{"q":"AKM","n":1,"c":85}, ...]}
##
##   op        "search" | "spawn"            required
##   query     free text: part of an English item name, or a 24-char lowercase
##             hex template id. `mods/tarkov/emu/spawn.nim` already resolves
##             both and this contract deliberately does not add a third form.
##   limit     max hits to RETURN (search). Default 10. Not a filter: see
##             `matched`.
##   count     how many to spawn. 1..5000; the provider caps and says so.
##   condition percent, 1..100, 100 = pristine.
##   lines     a batch. Present => `query`/`count` are ignored and each line is
##             spawned in order. This is what an inventory preset sends.
##
## RESPONSE, `op:"search"`:
##   {"matched": 57, "hits":[{"tpl":"5751a25...","name":"Salewa first aid kit"}]}
##     matched   how many there REALLY were. `hits.len` is what fitted in
##               `limit`. Collapsing those two is how a truncated list gets
##               presented as a complete one, so both are required.
##
## RESPONSE, `op:"spawn"`:
##   {"spawned": 3, "message":"...", "lines":[{"q":"AKM","ok":true,
##                                             "spawned":1,"message":"..."}]}
##     spawned   TOTAL items actually written into the stash. 0 with ok=true is
##               a legal and important answer (every line refused individually);
##               the caller must render it as a failure, and this one does.
##     lines     per-line outcome, present only for a batch request.
##
## A provider REFUSES with `capFail(reason)`; it must not answer `capOk` with
## `spawned: 0` and an empty message, because that is indistinguishable from
## success at the call site and this module cannot tell them apart for you.
##
## THE PROVIDER SIDE IS NOT IN THIS MOD AND MUST NOT BE. `mods/tarkov` owns
## `spawnInto`/`searchItemsCounted`; the registration there is
##
##     provide("aowl.items", 1, handler)
##
## plus `"provides": ["aowl.items"]` in its `registry/mods.json` entry -- the
## second is not what makes the call work, but it is what lets this module say
## "the emulator declares it and your mod selection does not load it"
## (`provider-not-loaded`) instead of "not installed" (`no-provider`). Those
## are different sentences to a player and the whole reason the SDK grew a
## roster reader.
##
## ---------------------------------------------------------------------------
## WHAT THIS MODULE PROMISES, AND WHAT IT REFUSES TO PROMISE
## ---------------------------------------------------------------------------
##
## It never reports success it did not observe. `capOk` with `spawned == 0` is
## rendered as a REFUSAL with the provider's own message attached, because a
## chunked POST answered 200 with nothing changed is a shape this project has
## already been bitten by. The only thing this module treats as success is a
## positive `spawned` count that the provider returned.

import std/strutils
import aowlspt
import aowlspt/json
import aowlspt/capability

import mailbox
import presets

const
  CapItems* = "aowl.items"
  CapItemsVersion* = 1

## The mailbox outcome for each `CapOutcome`. One place, so the taxonomy cannot
## drift between the log line and the thing the player reads on screen.
proc mapOutcome(o: CapOutcome): int32 =
  case o
  of coOk:                spwOutOk
  of coProviderError:     spwOutProviderError
  of coVersionMismatch:   spwOutVersionMismatch
  of coProviderNotLoaded: spwOutProviderNotLoaded
  of coProviderSilent:    spwOutProviderSilent
  of coNoProvider:        spwOutNoProvider
  of coRosterUnknown:     spwOutRosterUnknown
  of coBadReply:          spwOutBadReply
  of coUnavailable:       spwOutUnavailable

proc searchRequest(query: string; limit: int): string =
  var d = newDoc()
  setText(d, "op", "search")
  setText(d, "query", query)
  setNumber(d, "limit", limit)
  result = text(d)

proc itemRequest(query: string; count, condition: int): string =
  var d = newDoc()
  setText(d, "op", "spawn")
  setText(d, "query", query)
  setNumber(d, "count", count)
  setNumber(d, "condition", condition)
  result = text(d)

proc presetRequest(idx: int): string =
  ## `presetRequestJson` already emits `{"preset":..,"lines":[..]}`; this only
  ## puts the `op` in front of it, so the payload the mod has been able to
  ## build since day one is the payload that goes on the wire -- there is no
  ## second encoding of a preset anywhere.
  let inner = presetRequestJson(idx)
  if inner.len < 2: return ""
  result = "{\"op\":\"spawn\"," & inner.substr(1, inner.len - 1)

## Truncate to what one mailbox line holds, so a long item name becomes a short
## one rather than a silently dropped result.
proc fit(s: string; n: int): string =
  if s.len <= n: s else: s.substr(0, n - 4) & "..."

type Answer = object
  outcome: int32
  message: string
  matched: int
  shown: int
  spawned: int

proc runSearch(query: string; limit: int; s: SpawnRegion): Answer =
  result = Answer(outcome: spwOutUnavailable, message: "", matched: 0,
                  shown: 0, spawned: 0)
  let r = invoke(CapItems, CapItemsVersion, searchRequest(query, limit))
  result.outcome = mapOutcome(r.outcome)
  if r.outcome != coOk:
    result.message = fit(describe(r), 220)
    return
  let doc = whole(r.body)
  result.matched = asInt(field(doc, "matched"), 0)
  let hits = field(doc, "hits")
  var n = 0
  if isArray(hits):
    let items = each(hits)
    var i = 0
    while i < items.len and n < spwMaxLines:
      let nm = asText(field(items[i], "name"), "")
      let tp = asText(field(items[i], "tpl"), "")
      if nm.len > 0 or tp.len > 0:
        setLine(s, n, fit(nm & "  [" & tp & "]", 68))
        n = n + 1
      inc i
  result.shown = n
  if result.matched == 0:
    # NOT a refusal of the call -- the provider answered, correctly, "none".
    result.message = "no item matches \"" & fit(query, 40) & "\""
  elif n < result.matched:
    result.message = $result.matched & " match(es); showing " & $n
  else:
    result.message = $result.matched & " match(es)"

proc runSpawn(request, what: string): Answer =
  ## `what` names the thing being spawned, for the message only.
  result = Answer(outcome: spwOutUnavailable, message: "", matched: 0,
                  shown: 0, spawned: 0)
  if request.len == 0:
    result.outcome = spwOutLocalRefused
    result.message = "nothing to spawn: " & what & " declared no lines"
    return
  let r = invoke(CapItems, CapItemsVersion, request)
  result.outcome = mapOutcome(r.outcome)
  if r.outcome != coOk:
    result.message = fit(describe(r), 220)
    return
  let doc = whole(r.body)
  result.spawned = asInt(field(doc, "spawned"), 0)
  let provMsg = asText(field(doc, "message"), "")
  if result.spawned <= 0:
    # THE FALSE POSITIVE THIS BLOCK EXISTS FOR. The call succeeded; the spawn
    # did not. Reported as a refusal with the provider's own words, never as
    # success, and never as silence.
    result.outcome = spwOutProviderError
    result.message = fit(what & ": the spawner answered ok but put NOTHING in " &
                         "the stash" &
                         (if provMsg.len > 0: " -- " & provMsg else:
                            " and gave no reason"), 220)
    return
  result.message = fit(what & ": " & $result.spawned & " item(s) into the stash" &
                       (if provMsg.len > 0: " -- " & provMsg else: ""), 220)

proc serviceOne*(s: SpawnRegion): bool =
  ## One poll of the mailbox. Returns true when a request was served.
  ##
  ## Called from the SERVER-side `onUpdate`. Every path writes an answer before
  ## returning -- including the paths that refuse -- because leaving `ackSeq`
  ## behind `reqSeq` would leave the client waiting forever on a mailbox that
  ## had in fact already decided, which reads exactly like a hang.
  result = false
  let req = takeRequest(s)
  if not req.present: return
  result = true
  var a: Answer
  if req.kind == spwKindSearch:
    a = runSearch(req.query, spwMaxLines, s)
  elif req.kind == spwKindItem:
    a = runSpawn(itemRequest(req.query, req.count, req.condition),
                 $req.count & "x " & fit(req.query, 40))
  elif req.kind == spwKindPreset:
    let p = presetAt(req.presetIdx)
    a = runSpawn(presetRequest(req.presetIdx), p.name)
  else:
    a = Answer(outcome: spwOutLocalRefused,
               message: "unknown request kind " & $req.kind &
                        "; the client and the backend are running different " &
                        "builds of mods/admin",
               matched: 0, shown: 0, spawned: 0)
  answer(s, a.outcome, a.message, a.matched, a.shown, a.spawned)

proc providerDiag*(): string =
  ## What the capability layer says about `aowl.items` RIGHT NOW, without
  ## spawning anything. A probe, so this line is safe to print at load.
  ##
  ## Deliberately phrased so the three states cannot be flattened: a provider
  ## that answers, one that is installed but switched off, and one that is not
  ## installed at all.
  var body = ""
  let refusal = invokeOrRefuse(CapItems, CapItemsVersion,
                               searchRequest("bandage", 1), body)
  if refusal.len == 0:
    return "  spawner     : PASS  " & CapItems & "/" & $CapItemsVersion &
           " answered a probe search (" & $body.len & " bytes)\n"
  result = "  spawner     : " & refusal & "\n"
