## bm/stream — the directive event log: a bounded in-memory ring with a
## monotonic sequence, a cursor (`since`), an acknowledgement list with a TTL,
## and an optional server push.
##
## ---------------------------------------------------------------------------
## WHY A RING AND A CURSOR RATHER THAN A QUEUE
## ---------------------------------------------------------------------------
##
## Two clients may read the stream (the aowlspt IL2CPP host bridge and a
## BepInEx plugin), and a client may reconnect mid-raid. A queue that pops on
## read cannot serve either case: the second reader gets nothing and the
## reconnecting one has lost whatever arrived while it was away. So the log is
## append-only, every event carries a `seq`, and a reader states where it got
## to. `eventsSince(N)` returns strictly `seq > N`, which is the property the
## selfcheck asserts and the only contract the client depends on.
##
## The ring is bounded (`maxEvents`). When it overflows, the OLDEST events are
## dropped and `firstSeq()` moves forward -- a client whose cursor is older than
## `firstSeq()` has provably missed events, and `streamStats()` reports both
## numbers so it can detect that instead of silently resuming with a hole.
##
## ---------------------------------------------------------------------------
## ACKS: THE FAILURE PATH ANNOUNCES ITSELF
## ---------------------------------------------------------------------------
##
## A directive that must actually happen in the world (spawn a group, take the
## player prisoner) is emitted with `needsAck` and a `ttlMs`. It sits in the
## pending list until `ackEvent` clears it. `expirePending` -- called from the
## backend tick -- removes anything past its deadline and reports it through the
## `DropSink` **exactly once**, because expiry removes the entry in the same
## step that reports it. A client that never acks therefore produces a visible
## `directive.dropped` journal line rather than a directive that quietly never
## ran.
##
## ---------------------------------------------------------------------------
## PUSH
## ---------------------------------------------------------------------------
##
## When a session id is known AND the host can push, `emitEvent` also calls
## `notifyPush`. **In `aowlspt-sim` `notifyReady()` is false** (the simulator
## holds no game websocket), so nothing is pushed there and `streamStats`
## reports `pushReady:false` with the reason. That is not faked: the long-poll
## is the transport that is actually proven here.

import std/strutils
import aowlspt
import aowlspt/server as server
import aowlspt/json as jr
import util
import hearing

# ---------------------------------------------------------------------------
# State. Literal initialisers only -- a mod is a DLL and nimony silently zeroes
# a global whose initialiser is a call.
# ---------------------------------------------------------------------------

var gMax: int = 2048
var gDefaultTtlMs: int64 = 15000

var gSeqNo: seq[int] = @[]
var gAtMs: seq[int64] = @[]
var gKind: seq[string] = @[]
var gData: seq[string] = @[]       ## already-JSON text, "{}" when absent
var gAck: seq[bool] = @[]          ## did this event ask to be acknowledged
var gTtl: seq[int64] = @[]         ## its ttl in ms (0 when it needs no ack)

var gTorn: int = 0                 ## reads that found the columns disagreeing

var gNext: int = 0                 ## the seq the NEXT event gets
var gDropped: int = 0              ## events evicted from the ring (overflow)

var gPendSeq: seq[int] = @[]
var gPendKind: seq[string] = @[]
var gPendDue: seq[int64] = @[]     ## nowMs deadline
var gPendAcked: int = 0
var gPendExpired: int = 0

var gPushSession: string = ""
var gPushOk: int = 0
var gPushFail: int = 0

type
  DropSink* = nil proc (seq: int; kind: string)
    ## `nil proc` because nimony's proc types are non-nil by default and this
    ## must be nil until a sink is installed -- the spelling used by
    ## `mods/manager/mgr/refresh.nim:96`. CONTRACT.md writes `{.closure.}`;
    ## nimony has no closures, and the two failures are worth recording:
    ## a closure LITERAL crashes the compiler itself
    ## (`hexer/lambdalifting.nim(369) untypedEnv`, `env.s != SymId(0)`), and a
    ## `{.closure.}` proc TYPE crossing a module boundary emits a `(fn, env)`
    ## tuple against a bare-function-pointer prototype, which gcc refuses.
    ## Both measured 2026-09-06. Consequence for callers: a sink is a top-level
    ## proc and captures nothing; put what it needs in a module global.

var gDropSink: DropSink = nil

proc setDropSink*(s: DropSink) =
  gDropSink = s

proc streamConfigure*(maxEvents: int; defaultTtlMs: int64) =
  if maxEvents > 0: gMax = maxEvents
  if defaultTtlMs > 0: gDefaultTtlMs = defaultTtlMs

proc setPushSession*(session: string) =
  gPushSession = session

proc pushSession*(): string = gPushSession

proc latestSeq*(): int =
  ## The highest seq issued so far. A fresh stream is 0 and `since=0` therefore
  ## returns everything.
  result = gNext

proc firstSeq*(): int =
  ## The oldest seq still in the ring, or 0 when empty. A cursor below this has
  ## missed events.
  if gSeqNo.len == 0: return 0
  result = gSeqNo[0]

proc eventCount*(): int = gSeqNo.len

proc ringLen(): int =
  ## How many events every parallel column ACTUALLY has.
  ##
  ## Under the mod lock these six seqs are always the same length. They can
  ## only disagree if a reader ran WITHOUT the lock while a writer rebuilt the
  ## ring -- MEASURED 2026-09-07: `onEvents` built its payload unlocked while
  ## the tick's `expirePending` swapped in shorter seqs, and the reader indexed
  ## past the new end. nimony answers that with
  ## `seqimpl.nim(167, 41): i < s.len and 0 <= i [AssertionDefect]` and the
  ## whole backend process dies with no stack.
  ##
  ## The lock is the fix; this is the guard that makes the failure LOUD instead
  ## of fatal if the lock is ever dropped again. It returns the shortest column
  ## and `gTorn` counts every disagreement, which `streamStats` reports -- a
  ## torn read is announced, never silently rounded away.
  result = gSeqNo.len
  if gAtMs.len < result: result = gAtMs.len
  if gKind.len < result: result = gKind.len
  if gData.len < result: result = gData.len
  if gAck.len < result: result = gAck.len
  if gTtl.len < result: result = gTtl.len
  if result != gSeqNo.len: gTorn = gTorn + 1

proc pendLen(): int =
  ## The same property for the pending-ack columns, which `dropPendingAt`
  ## REBUILDS -- so an unlocked reader sees them shrink under it.
  result = gPendSeq.len
  if gPendKind.len < result: result = gPendKind.len
  if gPendDue.len < result: result = gPendDue.len
  if result != gPendSeq.len: gTorn = gTorn + 1

proc streamTornReads*(): int = gTorn

proc trimRing() =
  ## Enforce the bound by rebuilding without the oldest entries -- nimony's seq
  ## has no `delete`, so this is a copy, not an in-place shift.
  if gSeqNo.len <= gMax: return
  let n = ringLen()
  let cut = n - gMax
  if cut <= 0: return
  var s2: seq[int] = @[]; var a2: seq[int64] = @[]
  var k2: seq[string] = @[]; var d2: seq[string] = @[]
  var q2: seq[bool] = @[]; var t2: seq[int64] = @[]
  var i = cut
  while i < n:
    s2.add gSeqNo[i]; a2.add gAtMs[i]; k2.add gKind[i]; d2.add gData[i]
    q2.add gAck[i]; t2.add gTtl[i]
    i = i + 1
  gSeqNo = s2; gAtMs = a2; gKind = k2; gData = d2; gAck = q2; gTtl = t2
  gDropped = gDropped + cut

proc eventJsonText(i: int): string =
  ## One event as JSON text. `data` is spliced in raw -- it is JSON produced by
  ## a caller inside this mod, never a request body -- and an empty/blank data
  ## becomes `{}` so the document is always parseable.
  ##
  ## `ack` and `ttlMs` are per EVENT because they are the client's only way to
  ## know a directive must be acknowledged: the pending list is server-side
  ## state the client never sees. Without them every needsAck directive is
  ## dropped after its ttl while the client logs "carries no ack. Ignored" --
  ## MEASURED 2026-09-07 on the first live SPT 4.1.5 raid.
  if i < 0 or i >= ringLen():
    var t = obj()
    t.put("seq", -1)
    t.put("atMs", 0)
    t.put("kind", "stream.torn")
    t.put("data", server.raw("{}"))
    t.put("ack", false)
    t.put("ttlMs", 0)
    t.put("note", "REFUSED: event index " & $i & " is outside the ring (" &
          $ringLen() & " entries). The stream was read without the mod lock " &
          "while it was being rebuilt. No event is invented here.")
    return done(t).text
  var d = gData[i].strip()
  if d.len == 0: d = "{}"
  var o = obj()
  o.put("seq", gSeqNo[i])
  o.put("atMs", int(gAtMs[i]))
  o.put("kind", gKind[i])
  o.put("data", server.raw(d))
  o.put("ack", gAck[i])
  o.put("ttlMs", int(gTtl[i]))
  result = done(o).text

proc emitEvent*(kind, json: string; needsAck: bool; ttlMs: int64 = 0): int =
  ## Append one event, return its seq. Also pushes it when a session is known
  ## and the host can push -- and counts the pushes that failed, because
  ## `ErrNotFound` (no socket for that session) is a normal answer and must not
  ## read as delivery.
  ##
  ## ------------------------------------------------------------------ hearing
  ## THE ONE CHOKE POINT for "could the player have heard that". Every `say`
  ## reaches the client through here -- the encounter machine's barks, the
  ## brain's streamed sentences out of `speech.sayDrain`, and anything added
  ## later -- so the gate is here rather than at each emitter, where the third
  ## one would inevitably forget it. A payload that already carries `audible`
  ## has been decided by its emitter (`encounter.emitBarkEx`, which needs the
  ## verdict BEFORE it picks the words) and is passed through untouched.
  ##
  ## Beyond `hearYellM` the event is NOT APPENDED AT ALL and 0 is returned:
  ## the record is the journaled `say.suppressed` row, not a directive the
  ## client would have to be trusted to ignore.
  var body = json
  if kind == "say" and find(body, "\"audible\"") < 0:
    let pid = jr.asText(jr.field(body, "personId"), "")
    var mode = "speak"
    var audible = true
    var why = ""
    let d = hearingDecide(pid, false, mode, audible, why)
    if not audible:
      journalSuppressed(pid, jr.asText(jr.field(body, "text"), ""), why)
      return 0
    body = decorateSay(body, d, mode, audible, false, why)
  gNext = gNext + 1
  let s = gNext
  var ttl = 0'i64
  if needsAck:
    ttl = ttlMs
    if ttl <= 0: ttl = gDefaultTtlMs
  gSeqNo.add s
  gAtMs.add nowMs()
  gKind.add kind
  gData.add body
  gAck.add needsAck
  gTtl.add ttl
  trimRing()
  if needsAck:
    gPendSeq.add s
    gPendKind.add kind
    gPendDue.add (nowMs() + ttl)
  if gPushSession.len > 0 and notifyReady():
    let sess = gPushSession
    let payload = eventJsonText(ringLen() - 1)
    let st = notifyPush(sess, payload)
    if st == Ok: gPushOk = gPushOk + 1
    else: gPushFail = gPushFail + 1
  result = s

proc eventsSince*(since: int; limit: int): JsonArray =
  ## STRICTLY `seq > since`, oldest first, at most `limit` (<=0 means all).
  var a = arr()
  var n = 0
  var i = 0
  let stop = ringLen()
  while i < stop:
    if gSeqNo[i] > since:
      if limit > 0 and n >= limit: break
      a.add server.raw(eventJsonText(i))
      n = n + 1
    i = i + 1
  result = a

proc findPending(s: int): int =
  var i = 0
  let stop = pendLen()
  while i < stop:
    if gPendSeq[i] == s: return i
    i = i + 1
  result = -1

proc dropPendingAt(idx: int) =
  if idx < 0 or idx >= pendLen(): return
  var s2: seq[int] = @[]; var k2: seq[string] = @[]; var d2: seq[int64] = @[]
  var i = 0
  let stop = pendLen()
  while i < stop:
    if i != idx:
      s2.add gPendSeq[i]; k2.add gPendKind[i]; d2.add gPendDue[i]
    i = i + 1
  gPendSeq = s2; gPendKind = k2; gPendDue = d2

proc ackEvent*(seq: int; ok: bool; note: string): bool =
  ## Clear one pending directive. FALSE when that seq is not pending -- an ack
  ## for something already expired or never acknowledgeable is a real answer,
  ## not success.
  let i = findPending(seq)
  if i < 0: return false
  let kind = gPendKind[i]
  dropPendingAt(i)
  gPendAcked = gPendAcked + 1
  var o = obj()
  o.put("seq", seq)
  o.put("kind", kind)
  o.put("ok", ok)
  o.put("note", note)
  discard emitEvent("directive.acked", done(o).text, false, 0)
  result = true

proc pendingAcks*(): JsonArray =
  var a = arr()
  var i = 0
  let stop = pendLen()
  while i < stop:
    var o = obj()
    o.put("seq", gPendSeq[i])
    o.put("kind", gPendKind[i])
    o.put("dueMs", int(gPendDue[i]))
    a.add done(o)
    i = i + 1
  result = a

proc expirePending*(nowMs: int64; dropped: var seq[int]): int =
  ## Remove every pending directive past its deadline and report each one ONCE
  ## through the drop sink. Reported and removed in the same step, so a second
  ## call cannot report it again -- that is what makes "exactly once" a property
  ## of the code rather than a promise.
  dropped = @[]
  var i = 0
  while i < pendLen():
    if gPendDue[i] <= nowMs:
      let s = gPendSeq[i]
      let k = gPendKind[i]
      dropPendingAt(i)
      gPendExpired = gPendExpired + 1
      dropped.add s
      var o = obj()
      o.put("seq", s)
      o.put("kind", k)
      o.put("reason", "no ack within ttl")
      discard emitEvent("directive.dropped", done(o).text, false, 0)
      if gDropSink != nil: gDropSink(s, k)
    else:
      i = i + 1
  result = dropped.len

proc streamStats*(): JsonObject =
  var o = obj()
  o.put("latestSeq", gNext)
  o.put("firstSeq", firstSeq())
  o.put("events", gSeqNo.len)
  o.put("maxEvents", gMax)
  o.put("evicted", gDropped)
  o.put("pending", gPendSeq.len)
  o.put("acked", gPendAcked)
  o.put("expired", gPendExpired)
  o.put("defaultTtlMs", int(gDefaultTtlMs))
  o.put("pushSession", gPushSession)
  o.put("pushReady", notifyReady())
  o.put("pushOk", gPushOk)
  o.put("tornReads", gTorn)
  o.put("tornReadsNote",
    "how many times the parallel event/pending columns were found at " &
    "DIFFERENT lengths. It must stay 0: any other number means a route read " &
    "the stream without the mod lock while the tick rebuilt it, which is the " &
    "AssertionDefect that killed the backend on 2026-09-07.")
  o.put("pushFail", gPushFail)
  o.put("pushNote",
    (if notifyReady(): "host can push; each event is also notifyPush()ed"
     else: "notifyReady() is FALSE here (aowlspt-sim holds no game websocket) " &
           "-- nothing is pushed; the long-poll is the transport"))
  result = o

# ---------------------------------------------------------------------------
# Snapshot / restore -- the tail is persisted with the world so a backend
# restart does not reset the cursor and make a client replay old directives.
# ---------------------------------------------------------------------------

proc streamSnapshotJson*(): string =
  var a = arr()
  var i = 0
  let stop = ringLen()
  while i < stop:
    a.add server.raw(eventJsonText(i))
    i = i + 1
  var p = arr()
  i = 0
  let pstop = pendLen()
  while i < pstop:
    var o = obj()
    o.put("seq", gPendSeq[i])
    o.put("kind", gPendKind[i])
    o.put("dueMs", int(gPendDue[i]))
    p.add done(o)
    i = i + 1
  var root = obj()
  root.put("schema", "aowlspt.basement.stream/1")
  root.put("next", gNext)
  root.put("events", done(a))
  root.put("pending", done(p))
  result = done(root).text

proc streamAckFlag*(s: int): int =
  ## -1 = no such seq in the ring, 0 = ack:false, 1 = ack:true. The selfcheck
  ## asserts the SERVED flag through `eventsSince`, not this -- this exists so
  ## a caller can ask about one seq without parsing the whole document.
  var i = 0
  let stop = ringLen()
  while i < stop:
    if gSeqNo[i] == s: return (if gAck[i]: 1 else: 0)
    i = i + 1
  result = -1

proc streamRestore*(text: string): int =
  ## Replace the ring with a snapshot. Returns the number of events restored,
  ## or -1 when the text is not a stream snapshot (so a corrupt document is a
  ## reported refusal, not a half-loaded log).
  if text.len == 0: return -1
  if jr.asText(jr.field(text, "schema"), "") != "aowlspt.basement.stream/1":
    return -1
  gSeqNo = @[]; gAtMs = @[]; gKind = @[]; gData = @[]
  gAck = @[]; gTtl = @[]
  gPendSeq = @[]; gPendKind = @[]; gPendDue = @[]
  var maxSeen = 0
  for e in jr.each(jr.field(text, "events")):
    let s = jr.asInt(jr.child(e, "seq"), 0)
    if s <= 0: continue
    gSeqNo.add s
    gAtMs.add int64(jr.asInt(jr.child(e, "atMs"), 0))
    gKind.add jr.asText(jr.child(e, "kind"), "")
    gData.add jr.raw(jr.child(e, "data"))
    gAck.add jr.asBool(jr.child(e, "ack"), false)
    gTtl.add int64(jr.asInt(jr.child(e, "ttlMs"), 0))
    if s > maxSeen: maxSeen = s
  for e in jr.each(jr.field(text, "pending")):
    let s = jr.asInt(jr.child(e, "seq"), 0)
    if s <= 0: continue
    gPendSeq.add s
    gPendKind.add jr.asText(jr.child(e, "kind"), "")
    gPendDue.add int64(jr.asInt(jr.child(e, "dueMs"), 0))
  let restoredNext = jr.asInt(jr.field(text, "next"), 0)
  gNext = (if restoredNext > maxSeen: restoredNext else: maxSeen)
  trimRing()
  result = gSeqNo.len
