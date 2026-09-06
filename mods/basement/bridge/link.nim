## bridge/link.nim -- THE LONG POLL, THE DISPATCH, AND THE ACK.
##
## ONE REQUEST IN FLIGHT AT A TIME, on purpose: the `/events` cursor is a
## single value, and two overlapping polls with the same `since` deliver the
## same batch twice, which means every directive is executed twice. The latch
## is `gPolling`, cleared only by a completion or by a submit that the host
## refused -- never by a timer, because a timer that clears a latch nobody
## satisfied is how a client ends up polling in a tight loop.
##
## THE CURSOR lives in `gSince` and is advanced ONLY to `latestSeq` from a
## batch we actually parsed. `firstSeq` is the HOLE DETECTOR
## (CLIENT-CONTRACT section 4): if our cursor is older than `firstSeq - 1` we
## have PROVABLY missed events, and the recovery is to say so loudly and jump
## to `latestSeq` -- never to resume silently.
##
## DISPATCH IS BY KIND, and an unknown kind is ACKED `ok:false` with
## "unsupported kind", never ignored: ignoring turns a version mismatch into a
## mystery. A directive is anything whose `data` carries `ack:true`.
##
## THE COMPLETION PATH is the mod event `host.http.done`
## `{id,status,body,bytes,ms,error}`, emitted from the HOST's own tick loop.
## Requests are routed back by the PREFIX of the id we chose:
## `bmpoll` / `bmobs` / `bmack` / `bmspawn` / `bmptt`.

import aowlspt
import aowlspt/server
import aowlspt/json
import core
import say
import spawn

const
  RetryMs* = 3000'i64
    ## After a refused or failed poll. Bounded, and stated: a link that
    ## retries instantly against a backend that is down is a busy loop.

var gSince = 0
var gLatest = 0
var gFirst = 0
var gPolling = false
var gPolls = 0
var gBatches = 0
var gEvents = 0
var gDirectives = 0
var gUnsupported = 0
var gHoles = 0
var gNextPollAt = 0'i64
var gLinkState = "idle"
var gLastPollStatus = 0
var gLastPollError = ""
var gSubscribed = false

proc cursor*(): int = gSince
proc latestSeq*(): int = gLatest
proc firstSeq*(): int = gFirst
proc polls*(): int = gPolls
proc eventsSeen*(): int = gEvents
proc directivesSeen*(): int = gDirectives
proc unsupported*(): int = gUnsupported
proc holes*(): int = gHoles
proc linkState*(): string = gLinkState
proc lastPollStatus*(): int = gLastPollStatus
proc lastPollError*(): string = gLastPollError

# ------------------------------------------------------------- dispatch

proc dispatch(seqNo: int; kind: string; data: string) =
  ## One event. `data` is the RAW json of the event's `data` object, so every
  ## field read below is a lookup in that object and nothing is re-serialised.
  let wantsAck = asBool(field(data, "ack"), false)
  if wantsAck: gDirectives = gDirectives + 1
  if kind == "say":
    enqueue(asText(field(data, "personId"), ""), seqNo,
            asInt(field(data, "segmentIdx"), 0),
            asText(field(data, "wav"), ""),
            asText(field(data, "text"), ""),
            asBool(field(data, "final"), false), wantsAck)
    return
  if kind == "heard.partial" or kind == "heard.final":
    info "basement heard (" & kind & ", session " &
         asText(field(data, "session"), "") & "): " &
         asText(field(data, "text"), "")
    return
  if kind == "hud.note":
    let sev = asText(field(data, "severity"), "info")
    let text = asText(field(data, "text"), "")
    if sev == "warn": warn "basement HUD: " & text
    else: info "basement HUD: " & text
    return
  if kind == "quest.offer" or kind == "quest.update" or kind == "world.saved":
    info "basement " & kind & ": " & data
    return
  if kind == "directive.acked":
    return
  if kind == "directive.dropped":
    # LOUDLY. This is the backend telling us we failed to answer in time.
    warn "basement link: the backend DROPPED directive seq " &
         $asInt(field(data, "seq"), 0) & " (" &
         asText(field(data, "kind"), "?") & ") -- " &
         asText(field(data, "reason"), "no reason given") & ". That is a bug " &
         "in THIS client: an unacked directive means the world proceeded as " &
         "though the thing did not happen."
    return
  if not wantsAck:
    if not saidOnce("unknown-passive:" & kind):
      info "basement link: event kind `" & kind & "` is not handled by this " &
           "client and carries no ack. Ignored, and said once."
    return
  gUnsupported = gUnsupported + 1
  var why = "unsupported kind"
  if kind == "npc.stance" or kind == "npc.follow" or kind == "npc.hold" or
     kind == "npc.goto" or kind == "npc.attack":
    why = "unsupported kind: this client has NO bot actuator. The SAIN " &
          "driver does not move live bots yet (docs/BOTNAV.md), and this mod " &
          "installs no detour and resolves no name."
  elif kind == "npc.give" or kind == "npc.take" or kind == "player.captive" or
       kind == "player.release":
    why = "unsupported kind: inventory and equipment are a PROFILE-side " &
          "operation on aowlspt (mods/tarkov, over the bus), not something " &
          "the client half can do."
  elif kind == "group.spawn":
    why = "unsupported kind: bots are planted into the raid payload by the " &
          "emulator on aowlspt, not spawned by the client."
  elif kind == "player.spawn":
    why = "unsupported kind here: the always-in-raid gesture is driven by " &
          "this client from GET /spawn at MENU (bridge/spawn.nim), not from " &
          "a directive."
  if not saidOnce("unsupported:" & kind):
    warn "basement link: refusing directive kind `" & kind & "` -- " & why &
         " It is ACKED ok:false, never ignored."
  ackDirective(seqNo, false, why)

proc consume(body: string) =
  ## Parse one `/events` answer. STRICTLY: a body that does not carry `ok:true`
  ## is not treated as an empty batch, because "no events" and "the backend
  ## said no" are different answers.
  gBatches = gBatches + 1
  if not asBool(field(body, "ok"), false):
    gLinkState = "backend refused"
    if not saidOnce("events-notok"):
      warn "basement link: GET /events did not answer ok:true. First 200 " &
           "bytes: " & (if body.len > 200: substr(body, 0, 199) else: body)
    return
  let latest = asInt(field(body, "latestSeq"), 0)
  let first = asInt(field(body, "firstSeq"), 0)
  gLatest = latest
  gFirst = first
  if gSince > 0 and first > 0 and gSince < first - 1:
    gHoles = gHoles + 1
    warn "basement link: PROVABLY MISSED EVENTS -- the cursor was " & $gSince &
         " and the ring now starts at " & $first & ". Resyncing the cursor to " &
         $latest & " rather than resuming silently; everything between is gone."
    gSince = latest
    gLinkState = "resynced after a hole"
    return
  let evts = field(body, "events")
  let n = count(evts)
  var i = 0
  while i < n:
    let e = at(evts, i)
    let s = asInt(field(e, "seq"), 0)
    let kind = asText(field(e, "kind"), "")
    let data = raw(field(e, "data"))
    gEvents = gEvents + 1
    if s > gSince: gSince = s
    dispatch(s, kind, data)
    i = i + 1
  if n == 0 and latest > gSince and gSince == 0:
    gSince = latest
  gLinkState = "polling"

# ----------------------------------------------------------- completions

proc onHttpDone(payload: string): string =
  ## The single subscriber to `host.http.done` in this mod. Everything is
  ## routed by the prefix of the id WE chose -- the host hands back nothing
  ## else that identifies the request.
  result = ""
  let id = asText(field(payload, "id"), "")
  if id.len == 0: return
  let tag = idPrefix(id)
  if tag != "bmpoll" and tag != "bmobs" and tag != "bmack" and
     tag != "bmspawn" and tag != "bmptt":
    return    # not ours: another mod shares this event bus.
  let status = asInt(field(payload, "status"), 0)
  let err = asText(field(payload, "error"), "")
  let body = asText(field(payload, "body"), "")
  noteCompletion(status, err)
  if tag == "bmpoll":
    gPolling = false
    gLastPollStatus = status
    gLastPollError = err
    gNextPollAt = nowMs()
    if err.len > 0 or status != 200:
      gLinkState = "poll failed"
      gNextPollAt = nowMs() + RetryMs
      if not saidOnce("poll-fail:" & $status & ":" & err):
        warn "basement link: the long poll failed -- HTTP " & $status &
             (if err.len > 0: ", transport error: " & err else: "") &
             ". The cursor is UNCHANGED (" & $gSince & ") and the poll is " &
             "retried in " & $RetryMs & " ms. This is a backend/transport " &
             "answer, not a directive failure."
      return
    consume(body)
    return
  if tag == "bmspawn":
    onSpawnBody(status, body)
    return
  if status != 200 or err.len > 0:
    if not saidOnce("post-fail:" & tag & ":" & $status):
      warn "basement link: a `" & tag & "` POST answered HTTP " & $status &
           (if err.len > 0: " / " & err else: "") &
           ". Reported once for this prefix and status; nothing is retried."

# ------------------------------------------------------------ the poll

proc pollNow*(nowMsValue: int64) =
  if gPolling: return
  if nowMsValue < gNextPollAt: return
  var url = routeUrl("/events") & "?since=" & $gSince & "&wait=" &
            $pollWaitMs() & "&limit=64"
  gPolling = true
  gPolls = gPolls + 1
  if not httpGet(nextId("bmpoll"), url):
    gPolling = false
    gLinkState = "refused by the host"
    gNextPollAt = nowMsValue + RetryMs

proc install*(): bool =
  ## Subscribe FIRST, poll after: a completion that lands before the
  ## subscription exists is a request that can never be answered, and the
  ## latch would stay set forever.
  if gSubscribed: return true
  if on("host.http.done", onHttpDone) != Ok:
    warn "basement link: could NOT subscribe to `host.http.done`. Every " &
         "request would be submitted and never answered, so the link is " &
         "DISABLED for this session rather than latching forever."
    gLinkState = "no completion event"
    return false
  gSubscribed = true
  result = true

proc tick*(nowMsValue: int64) =
  if not gSubscribed: return
  pollNow(nowMsValue)
