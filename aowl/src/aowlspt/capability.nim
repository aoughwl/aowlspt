## Named, versioned capabilities: how one server-side mod calls another.
##
## ---------------------------------------------------------------------------
## THE GAP THIS CLOSES
## ---------------------------------------------------------------------------
##
## `call()` in `aowlspt.nim` reaches the `aowlspt.host::` namespace and nothing
## else, and there is no HTTP client anywhere in the SDK. So a mod that has
## built a feature and needs one operation another mod already implements has
## had exactly two options: reimplement it, or refuse. `mods/admin` refuses --
## `presetApplyStatus()` there says so at length -- while the spawner it needs
## sits finished in `mods/tarkov/emu/spawn.nim`.
##
## A capability is a NAME (`items.spawn`), a VERSION (an integer), and a
## request/response schema the provider documents. A provider publishes one
## with `provide`; a consumer invokes one with `invoke`. Neither knows the
## other guid, its routes, or its port.
##
## ---------------------------------------------------------------------------
## WHAT IT IS BUILT ON, AND WHY THAT AND NOT SOMETHING ELSE
## ---------------------------------------------------------------------------
##
## Events, in both directions. That is not a shortcut around a better
## mechanism; it is the only in-process channel that already has the lifetime
## discipline this needs, and `abi/**` and `host/**` are not this module to
## change.
##
##  * `event_emit` is delivered **synchronously**, on the caller thread, to
##    every subscriber but the emitter, and the backend takes `modEnter` /
##    `modLeave` around each one (`deliverEvent` in `backend/aowlbackend.nim`).
##    A provider being unloaded is *skipped*, not called into. So a capability
##    invocation inherits a use-after-free guard that a raw cross-DLL function
##    pointer -- the obvious alternative -- would not have had.
##  * There is no reply buffer on `event_emit`, so the answer comes back the
##    same way: the provider emits onto `aowl.cap.reply/<consumer-guid>`, which
##    the consumer subscribed to once. Because delivery is synchronous, that
##    reply has already landed by the time `emit` returns, on the same stack.
##    The consumer therefore blocks for exactly as long as the provider takes
##    and no longer, with no polling and no timeout to tune.
##
## **None of this goes over HTTP.** It never chunks a request, never negotiates
## an encoding, and never parses a `/aowlspt/settings` document -- so the three
## measured wire traps (a chunked POST answered 200 with the schema unchanged;
## the always-deflate default; `value` emitted unquoted) cannot reach it. The
## price is that this is server-side only, in one process. It is not a network
## protocol and must not become one.
##
## ---------------------------------------------------------------------------
## RESOLUTION IS LAZY, AND THAT IS A DECISION
## ---------------------------------------------------------------------------
##
## Nothing is resolved at load time and nothing is cached between calls. Every
## `invoke` asks, live, whether a provider is answering right now.
##
## That is deliberate, and it is the answer to `loadAfter`. `loadAfter` is
## ORDERING ONLY -- SAIN declares `loadAfter aowl.morebots` and that is a hint
## about sequence, not a dependency the host enforces -- so a load-time bind
## would turn "the provider happened to load second" into a permanent, silent
## failure for the rest of the session. Here it is not even a transient one:
## the first `invoke` after the provider registers succeeds. A mod may call a
## capability from `onLoad` and get a refusal, call it again on the first tick
## and get an answer, and both are correct.
##
## The cost is one event fanout per call: a table walk and a synchronous C
## call in the same process. A capability invoked in a per-frame loop is being
## used wrongly regardless of what it costs.
##
## ---------------------------------------------------------------------------
## THE REFUSAL TAXONOMY, WHICH IS THE POINT OF THE MODULE
## ---------------------------------------------------------------------------
##
## A missing provider must never look like a working one. `invoke` never
## returns a body it did not receive, and the outcome enum has no member
## meaning "probably fine".
##
##   coOk                 a provider answered and its payload parsed strictly.
##   coProviderError      a provider answered and said no. `message` is its
##                        words, not ours.
##   coVersionMismatch    a provider for this NAME is loaded and answering, at
##                        other versions. `versions` lists them.
##   coProviderNotLoaded  the registry says a mod provides this and the
##                        selection does not load it. This is the distinction
##                        that was missing: a stale override in
##                        `store/aowl.manager/selection` disabled two mods for
##                        days while the roster still called them "enabled",
##                        and "not installed" would have been a lie about it.
##   coProviderSilent     the registry says a mod provides this AND the
##                        selection loads it, and nothing answered anyway --
##                        so it is loaded and never called `provide`, or it
##                        failed during `onLoad`. INCONCLUSIVE, not absent.
##   coNoProvider         nothing answered and no installed mod declares this
##                        capability in the registry. Genuinely not installed.
##   coRosterUnknown      nothing answered and the roster could not be read,
##                        so WHY is unknown. Never collapsed into
##                        `coNoProvider`: "I could not look" is not "it is not
##                        there".
##   coBadReply           something answered with a payload that is not
##                        strictly valid JSON, or whose envelope does not
##                        match what was asked. Treated as a failure, loudly.
##   coUnavailable        no host, or every in-flight slot is taken.
##
## `message` is populated on EVERY non-ok outcome and is written to be shown
## to a player verbatim.
##
## ---------------------------------------------------------------------------
## STRICTNESS
## ---------------------------------------------------------------------------
##
## `aowlspt/json` is deliberately a *finder*, not a validator: `skipValue`
## counts brackets, so `{"a":}` walks past it and `members` on a malformed
## object returns the prefix it managed to read and no error. That is the right
## trade for pulling one field out of a 40 MB response and the wrong one for
## accepting a reply. `strictValue` below is a real recursive-descent validator
## and every envelope crossing this module goes through it first. The backend
## selftest once asserted with substring `contains` and let a payload that was
## not JSON at all pass for months; this module does not get to repeat that.

import std/strutils
import std/syncio
import ".." / aowlspt
import "." / json

# Its own critical section, for the same reason `aowlspt.nim` and `sync.nim`
# each keep one: `aowlspt_lock.h` is a `static` one-time-initialised
# CRITICAL_SECTION and nimony emits one translation unit per module, so this
# include is a third, independent lock. It is never held across a call out --
# not into a provider handler, not into the host -- which is what makes a
# capability handler free to invoke another capability without deadlocking on
# a non-recursive section.
{.emit: """#include "aowlspt_lock.h" """.}

proc cCapLock() {.importc: "aowl_lock", nodecl.}
proc cCapUnlock() {.importc: "aowl_unlock", nodecl.}

template withCapLock(body: untyped) =
  cCapLock()
  body
  cCapUnlock()

const
  CapSchema* = "aowl.cap/1"
  ReplySchema* = "aowl.cap.reply/1"
  ProbeSchema* = "aowl.cap.probe/1"
  ProbeReplySchema* = "aowl.cap.probe.reply/1"

  SlotCapacity* = 32
    ## In-flight invocations across all threads. The backend serves on sixteen
    ## workers and an invocation occupies a slot only for the duration of one
    ## synchronous fanout, so this is twice the arrival bound. Exhaustion is
    ## `coUnavailable` with a message saying so -- never a wait, because a wait
    ## here would be a wait on a thread that is holding nothing.

  ProviderCapacity* = 32

type
  CapOutcome* = enum
    coOk
    coProviderError
    coVersionMismatch
    coProviderNotLoaded
    coProviderSilent
    coNoProvider
    coRosterUnknown
    coBadReply
    coUnavailable

  CapResult* = object
    outcome*: CapOutcome
    body*: string        ## the provider response JSON. Empty unless `coOk`.
    message*: string     ## why, in words, on every outcome but `coOk`.
    provider*: string    ## the guid that answered, or that the roster names.
    versions*: seq[int]  ## on `coVersionMismatch`, what IS offered.

  CapReply* = object
    ## What a provider handler decided. Build one with `capOk` or `capFail`;
    ## the zero value is a failure, so a handler that falls off the end cannot
    ## read as success.
    ok*: bool
    body*: string
    message*: string

  CapHandler* = proc (request: string): CapReply

func capOk*(body: string): CapReply =
  CapReply(ok: true, body: body, message: "")

func capFail*(message: string): CapReply =
  CapReply(ok: false, body: "", message: message)

func isOk*(r: CapResult): bool = r.outcome == coOk

func status*(r: CapResult): Status =
  ## For a caller that wants an ABI status rather than the enum. Lossy on
  ## purpose: use `outcome` when the distinction matters, which is most of the
  ## time, and this only at a boundary that speaks `Status`.
  case r.outcome
  of coOk: Ok
  of coProviderError: ErrGeneric
  of coVersionMismatch: ErrUnsupported
  of coBadReply: ErrDecode
  of coUnavailable: ErrBadArg
  else: ErrNotFound

func outcomeName*(o: CapOutcome): string =
  case o
  of coOk: "ok"
  of coProviderError: "provider-error"
  of coVersionMismatch: "version-mismatch"
  of coProviderNotLoaded: "provider-not-loaded"
  of coProviderSilent: "provider-silent"
  of coNoProvider: "no-provider"
  of coRosterUnknown: "roster-unknown"
  of coBadReply: "bad-reply"
  of coUnavailable: "unavailable"

# ---------------------------------------------------------------------------
# A real JSON validator
# ---------------------------------------------------------------------------

proc vWs(s: string; i: var int) =
  while i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\n' or
                       s[i] == '\r'):
    inc i

proc vLit(s: string; i: var int; want: string): bool =
  if i + want.len > s.len: return false
  for k in 0 ..< want.len:
    if s[i + k] != want[k]: return false
  i = i + want.len
  result = true

proc vHex(c: char): bool =
  (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F')

proc vString(s: string; i: var int): bool =
  if i >= s.len or s[i] != '"': return false
  inc i
  while i < s.len:
    let c = s[i]
    if c == '"':
      inc i
      return true
    if c == '\\':
      inc i
      if i >= s.len: return false
      let e = s[i]
      if e == 'u':
        if i + 4 >= s.len: return false
        for k in 1 .. 4:
          if not vHex(s[i + k]): return false
        i = i + 5
        continue
      if e != '"' and e != '\\' and e != '/' and e != 'b' and e != 'f' and
         e != 'n' and e != 'r' and e != 't':
        return false
      inc i
      continue
    if ord(c) < 0x20: return false
    inc i
  result = false

proc vNumber(s: string; i: var int): bool =
  let start = i
  if i < s.len and s[i] == '-': inc i
  if i >= s.len: return false
  if s[i] == '0':
    inc i
  elif s[i] >= '1' and s[i] <= '9':
    while i < s.len and s[i] >= '0' and s[i] <= '9': inc i
  else:
    return false
  if i < s.len and s[i] == '.':
    inc i
    if i >= s.len or s[i] < '0' or s[i] > '9': return false
    while i < s.len and s[i] >= '0' and s[i] <= '9': inc i
  if i < s.len and (s[i] == 'e' or s[i] == 'E'):
    inc i
    if i < s.len and (s[i] == '+' or s[i] == '-'): inc i
    if i >= s.len or s[i] < '0' or s[i] > '9': return false
    while i < s.len and s[i] >= '0' and s[i] <= '9': inc i
  result = i > start

proc vValue(s: string; i: var int; depth: int): bool =
  ## Recursive descent, depth-capped. A reply is an envelope this module built
  ## or a provider response body; neither is legitimately 64 deep, and an
  ## uncapped recursion on hostile text is a stack overflow rather than a
  ## refusal.
  if depth > 64: return false
  vWs(s, i)
  if i >= s.len: return false
  let c = s[i]
  if c == '"': return vString(s, i)
  if c == 't': return vLit(s, i, "true")
  if c == 'f': return vLit(s, i, "false")
  if c == 'n': return vLit(s, i, "null")
  if c == '[':
    inc i
    vWs(s, i)
    if i < s.len and s[i] == ']':
      inc i
      return true
    while true:
      if not vValue(s, i, depth + 1): return false
      vWs(s, i)
      if i >= s.len: return false
      if s[i] == ',':
        inc i
        continue
      if s[i] == ']':
        inc i
        return true
      return false
  if c == '{':
    inc i
    vWs(s, i)
    if i < s.len and s[i] == '}':
      inc i
      return true
    while true:
      vWs(s, i)
      if not vString(s, i): return false
      vWs(s, i)
      if i >= s.len or s[i] != ':': return false
      inc i
      if not vValue(s, i, depth + 1): return false
      vWs(s, i)
      if i >= s.len: return false
      if s[i] == ',':
        inc i
        continue
      if s[i] == '}':
        inc i
        return true
      return false
  result = vNumber(s, i)

proc strictValue*(text: string): bool =
  ## True only if `text` is ONE complete, well-formed JSON value with nothing
  ## after it but whitespace. This is the check `aowlspt/json` deliberately
  ## does not do; see the header.
  var i = 0
  if not vValue(text, i, 0): return false
  vWs(text, i)
  result = i == text.len

proc strictObject*(text: string): bool =
  var i = 0
  vWs(text, i)
  if i >= text.len or text[i] != '{': return false
  result = strictValue(text)

# ---------------------------------------------------------------------------
# Registration tables
# ---------------------------------------------------------------------------

type
  Provided = object
    name: string
    version: int
    handler: CapHandler
    live: bool

  Slot = object
    token: int
    live: bool          ## claimed by an in-flight invoke
    kind: int           ## 0 nothing yet, 1 call reply, 2 probe reply
    ok: bool
    body: string
    err: string
    by: string
    versions: seq[int]

proc noHandler(request: string): CapReply =
  capFail("no handler")

var gProv: seq[Provided] = @[]
var gProvReady = false
var gSlots: seq[Slot] = @[]
var gSlotsReady = false
var gNextToken = 1
var gReplySubscribed = false

proc ensureTables() =
  ## Both tables are reserved to full capacity once and never grow again. Same
  ## reasoning as `RouteCapacity` in `aowlspt.nim`: an index is read by a
  ## thread that did not write it, and a `seq` that reallocates under a reader
  ## is how that becomes a read of freed memory.
  withCapLock:
    if not gProvReady:
      var i = 0
      while i < ProviderCapacity:
        gProv.add Provided(name: "", version: 0, handler: noHandler,
                           live: false)
        inc i
      gProvReady = true
    if not gSlotsReady:
      var i = 0
      while i < SlotCapacity:
        gSlots.add Slot(token: 0, live: false, kind: 0, ok: false, body: "",
                        err: "", by: "", versions: @[])
        inc i
      gSlotsReady = true

# ---------------------------------------------------------------------------
# Envelope construction
# ---------------------------------------------------------------------------

proc replyName(consumer: string): string = "aowl.cap.reply/" & consumer
proc capName(cap: string; version: int): string =
  "aowl.cap/" & cap & "/" & $version
proc probeName(cap: string): string = "aowl.cap.probe/" & cap

proc envRequest(cap: string; version, token: int; requestJson: string): string =
  var d = newDoc()
  d.setText("schema", CapSchema)
  d.setText("cap", cap)
  d.setNumber("v", version)
  d.setText("from", modGuid())
  d.setNumber("token", token)
  d.setRaw("req", if requestJson.len > 0: requestJson else: "null")
  result = text(d)

proc envProbe(cap: string; token: int): string =
  var d = newDoc()
  d.setText("schema", ProbeSchema)
  d.setText("cap", cap)
  d.setText("from", modGuid())
  d.setNumber("token", token)
  result = text(d)

# ---------------------------------------------------------------------------
# Consumer side: the single reply subscription
# ---------------------------------------------------------------------------

proc fillSlot(token, kind: int; ok: bool; body, err, by: string;
              versions: seq[int]): bool =
  ## Writes a reply into the slot holding `token`, once. A second reply for the
  ## same token -- two mods providing the same name and version, which is a
  ## misconfiguration rather than an impossibility -- is DROPPED and reported
  ## `false`, so the first answer wins deterministically instead of the last.
  result = false
  withCapLock:
    var i = 0
    while i < gSlots.len:
      if gSlots[i].live and gSlots[i].token == token and gSlots[i].kind == 0:
        gSlots[i].kind = kind
        gSlots[i].ok = ok
        gSlots[i].body = body
        gSlots[i].err = err
        gSlots[i].by = by
        gSlots[i].versions = versions
        result = true
        break
      inc i

proc onCapReply(payload: string): string =
  ## Every reply this mod receives, of both kinds, on ONE subscription -- one
  ## per consumer mod, not one per call, because the ABI has no
  ## `event_unsubscribe` and a per-call subscription would burn an
  ## `EventCapacity` slot on every invocation.
  result = ""
  if not strictObject(payload):
    warn "capability: dropped a reply that is not strictly valid JSON (" &
         $payload.len & " bytes)"
    return
  let j = whole(payload)
  let schema = j.field("schema").asText("")
  let token = j.field("token").asInt(-1)
  if token < 0:
    warn "capability: dropped a reply with no token"
    return
  if schema == ReplySchema:
    let ok = j.field("ok").asBool(false)
    let res = j.field("res").raw()
    if ok and not strictValue(res):
      discard fillSlot(token, 1, false, "",
                       "the provider response body is not strictly valid JSON",
                       j.field("by").asText(""), @[])
      return
    discard fillSlot(token, 1, ok, res, j.field("err").asText(""),
                     j.field("by").asText(""), @[])
    return
  if schema == ProbeReplySchema:
    var vs: seq[int] = @[]
    let arr = j.field("versions")
    var k = 0
    while k < arr.count():
      vs.add arr.at(k).asInt(0)
      inc k
    discard fillSlot(token, 2, true, "", "", j.field("by").asText(""), vs)
    return
  warn "capability: dropped a reply with unknown schema " & schema

proc ensureReplySub(): bool =
  var need = false
  withCapLock:
    if not gReplySubscribed:
      gReplySubscribed = true
      need = true
  if not need: return true
  let st = on(replyName(modGuid()), onCapReply)
  if st != Ok:
    withCapLock:
      gReplySubscribed = false
    error "capability: could not subscribe to " & replyName(modGuid()) &
          ": " & lastError()
    return false
  result = true

# ---------------------------------------------------------------------------
# Provider side
# ---------------------------------------------------------------------------

proc emitReply(to: string; token: int; ok: bool; body, err: string) =
  var d = newDoc()
  d.setText("schema", ReplySchema)
  d.setNumber("token", token)
  d.setText("by", modGuid())
  d.setBool("ok", ok)
  if ok:
    d.setRaw("res", if body.len > 0: body else: "null")
  else:
    d.setText("err", err)
  discard emit(replyName(to), text(d))

proc onCapRequest(payload: string): string =
  ## One trampoline for every capability this mod provides. A `{.cdecl.}`
  ## handler cannot carry a closure, so dispatch is by the `cap`/`v` the
  ## envelope names rather than by which subscription fired.
  result = ""
  if not strictObject(payload):
    warn "capability: a request arrived that is not strictly valid JSON"
    return
  let j = whole(payload)
  if j.field("schema").asText("") != CapSchema: return
  let cap = j.field("cap").asText("")
  let version = j.field("v").asInt(-1)
  let asker = j.field("from").asText("")
  let token = j.field("token").asInt(-1)
  if cap.len == 0 or version < 0 or asker.len == 0 or token < 0: return

  var h: CapHandler = noHandler
  var have = false
  withCapLock:
    var i = 0
    while i < gProv.len:
      if gProv[i].live and gProv[i].name == cap and gProv[i].version == version:
        h = gProv[i].handler
        have = true
        break
      inc i
  if not have:
    # Subscribed and not providing: reachable only if `revoke` ran between the
    # fanout starting and here. ANSWERING is the point -- silence would read at
    # the consumer as "no provider anywhere", a different and wrong diagnosis.
    emitReply(asker, token, false, "",
              modGuid() & " no longer provides " & cap & "/" & $version)
    return

  let r = h(j.field("req").raw())
  if not r.ok:
    emitReply(asker, token, false, "",
              if r.message.len > 0: r.message
              else: "the provider refused without saying why")
    return
  if not strictValue(r.body):
    # The provider own bug, caught here rather than at the consumer, and NOT
    # forwarded as success. A handler returning malformed JSON is exactly the
    # shape that otherwise arrives looking like a 200 with nothing in it.
    error "capability: the " & cap & "/" & $version & " handler returned a " &
          "body that is not strictly valid JSON; refusing rather than " &
          "forwarding it"
    emitReply(asker, token, false, "",
              modGuid() & " produced a malformed response for " & cap)
    return
  emitReply(asker, token, true, r.body, "")

proc onCapProbe(payload: string): string =
  result = ""
  if not strictObject(payload): return
  let j = whole(payload)
  if j.field("schema").asText("") != ProbeSchema: return
  let cap = j.field("cap").asText("")
  let asker = j.field("from").asText("")
  let token = j.field("token").asInt(-1)
  if cap.len == 0 or asker.len == 0 or token < 0: return
  var vs: seq[int] = @[]
  withCapLock:
    var i = 0
    while i < gProv.len:
      if gProv[i].live and gProv[i].name == cap: vs.add gProv[i].version
      inc i
  if vs.len == 0: return
  var l = newList()
  for v in vs: l.add $v
  var d = newDoc()
  d.setText("schema", ProbeReplySchema)
  d.setNumber("token", token)
  d.setText("cap", cap)
  d.setText("by", modGuid())
  d.setRaw("versions", text(l))
  discard emit(replyName(asker), text(d))

proc provide*(cap: string; version: int; handler: CapHandler): Status =
  ## Publish `cap`/`version`. Callable from `onLoad` or later, from any thread.
  ##
  ## The registry entry for this mod SHOULD also list the name in its
  ## `provides` array -- `registry/mods.json` already carries that field. It is
  ## not what makes the call work (this is), but it is what lets a consumer say
  ## "aowl.tarkov declares it and the selection does not load it" instead of
  ## "not installed", and that sentence is the whole reason this module has a
  ## roster reader.
  ##
  ## `ErrUnsupported` on the client: there is no server-side mod set there.
  ## `ErrBadArg` for an empty name, a name containing `/`, a negative version,
  ## or a second `provide` of a pair already published. `ErrGeneric` when all
  ## `ProviderCapacity` slots are taken.
  if cap.len == 0 or version < 0: return ErrBadArg
  if cap.contains("/"): return ErrBadArg
  if side() == sideClient: return ErrUnsupported
  ensureTables()
  var idx = -1
  var dup = false
  withCapLock:
    var i = 0
    while i < gProv.len:
      if gProv[i].live and gProv[i].name == cap and gProv[i].version == version:
        dup = true
        break
      inc i
    if not dup:
      i = 0
      while i < gProv.len:
        if not gProv[i].live:
          gProv[i] = Provided(name: cap, version: version, handler: handler,
                              live: true)
          idx = i
          break
        inc i
  if dup:
    warn "capability: " & cap & "/" & $version & " is already provided by " &
         "this mod; the second provide() was refused rather than shadowing " &
         "the first"
    return ErrBadArg
  if idx < 0: return ErrGeneric

  var st = on(capName(cap, version), onCapRequest)
  if st != Ok:
    withCapLock:
      gProv[idx].live = false
    return st
  st = on(probeName(cap), onCapProbe)
  if st != Ok:
    # The probe subscription is what turns a wrong-version call into
    # `coVersionMismatch` instead of `coProviderSilent`. Losing it would leave
    # this provider answering correct calls while misdiagnosing incorrect
    # ones, so the registration is rolled back rather than kept half-working.
    withCapLock:
      gProv[idx].live = false
    error "capability: " & cap & " registered its request subscription but " &
          "not its probe; rolled back so a version mismatch stays " &
          "diagnosable. " & lastError()
    return st
  success "capability: providing " & cap & "/" & $version
  result = Ok

proc revoke*(cap: string; version: int): bool =
  ## Stop answering. The subscriptions stay (the ABI has no unsubscribe), but
  ## `onCapRequest` now answers a clean refusal naming this mod instead of
  ## calling a handler its owner has retired.
  ensureTables()
  result = false
  withCapLock:
    var i = 0
    while i < gProv.len:
      if gProv[i].live and gProv[i].name == cap and gProv[i].version == version:
        gProv[i].live = false
        gProv[i].handler = noHandler
        result = true
        break
      inc i

proc providedHere*(): seq[string] =
  ## What this mod publishes, for a diagnostic.
  ensureTables()
  result = @[]
  withCapLock:
    var i = 0
    while i < gProv.len:
      if gProv[i].live: result.add gProv[i].name & "/" & $gProv[i].version
      inc i

# ---------------------------------------------------------------------------
# The roster: what "no answer" MEANS
# ---------------------------------------------------------------------------
#
# Mod loading has three gates -- a library on disk, an entry in
# `registry/mods.json`, and the manager-owned selection in
# `aowlspt-selection.json`. A stale selection override once disabled two mods
# for days while the roster still reported them "enabled", and the reason that
# cost days is that nothing downstream could tell "not installed" from
# "installed and not loaded". This reader exists to make `invoke` able to say
# which, and to say `coRosterUnknown` when it genuinely cannot look.

type
  Roster = object
    read: bool
    note: string
    declaring: seq[string]   ## guids whose registry entry provides the cap
    selected: seq[string]    ## of those, the ones the selection loads
    haveSelection: bool

proc parentOf(p: string): string =
  var i = p.len - 1
  while i >= 0 and p[i] != '/' and p[i] != '\\': dec i
  if i <= 0: return ""
  result = p.substr(0, i - 1)

proc readTextFile(path: string): string =
  ## `readFile` is `{.raises.}` in nimony, so every call is wrapped. The empty
  ## string is the failure and the caller turns it into a message NAMING THE
  ## PATH -- a diagnostic that cannot say which file it could not read is a
  ## twenty-minute problem instead of a ten-second one.
  result = ""
  try:
    result = readFile(path)
  except:
    result = ""
  if result.len >= 3 and ord(result[0]) == 0xEF and ord(result[1]) == 0xBB and
     ord(result[2]) == 0xBF:
    result = result.substr(3, result.len - 1)

proc providesCap(entry: JsonRef; cap: string): bool =
  ## `provides` may name a bare capability or a versioned one. Both count for
  ## the ROSTER question, which is "is this mod meant to be the provider",
  ## never "does it offer the version asked for" -- that question is answered
  ## on the wire by the probe, because a registry file is a claim and the probe
  ## is a measurement.
  let arr = entry.field("provides")
  var i = 0
  while i < arr.count():
    let s = arr.at(i).asText("")
    if s == cap or s.startsWith(cap & "/"): return true
    inc i
  result = false

proc readRoster(cap: string): Roster =
  result = Roster(read: false, note: "", declaring: @[], selected: @[],
                  haveSelection: false)
  let mods = parentOf(modDir())
  if mods.len == 0:
    result.note = "the host reported no mod directory, so neither the " &
                  "registry nor the selection could be located"
    return
  let selPath = mods & "/aowlspt-selection.json"
  let selText = readTextFile(selPath)

  var regPath = ""
  var load: seq[string] = @[]
  if selText.len > 0:
    if not strictObject(selText):
      result.note = selPath & " is present and is not strictly valid JSON, " &
                    "so which mods are loaded cannot be established from it"
      return
    let sj = whole(selText)
    result.haveSelection = true
    regPath = sj.field("registry").asText("")
    let arr = sj.field("load")
    var i = 0
    while i < arr.count():
      load.add arr.at(i).asText("")
      inc i
  if regPath.len == 0:
    regPath = parentOf(mods) & "/registry/mods.json"
  let regText = readTextFile(regPath)
  if regText.len == 0:
    result.note = "the registry at " & regPath & " could not be read, so " &
                  "whether any installed mod declares " & cap & " is unknown"
    return
  if not strictObject(regText):
    result.note = regPath & " is present and is not strictly valid JSON, so " &
                  "the roster cannot be trusted about " & cap
    return

  let rj = whole(regText)
  let entries = rj.field("mods")
  var i = 0
  while i < entries.count():
    let e = entries.at(i)
    let id = e.field("id").asText("")
    if id.len > 0 and providesCap(e, cap):
      result.declaring.add id
      if not result.haveSelection:
        result.selected.add id
      else:
        for w in load:
          if w == id:
            result.selected.add id
            break
    inc i
  result.read = true
  result.note = regPath & (if result.haveSelection: " + " & selPath
                           else: " (no selection file; every installed mod " &
                                 "is loaded)")

# ---------------------------------------------------------------------------
# Consumer side: invoke
# ---------------------------------------------------------------------------

proc claimSlot(outIdx: var int; outToken: var int): bool =
  outIdx = -1
  outToken = 0
  withCapLock:
    var i = 0
    while i < gSlots.len:
      if not gSlots[i].live:
        gNextToken = gNextToken + 1
        if gNextToken < 1: gNextToken = 1
        gSlots[i] = Slot(token: gNextToken, live: true, kind: 0, ok: false,
                         body: "", err: "", by: "", versions: @[])
        outIdx = i
        outToken = gNextToken
        break
      inc i
  result = outIdx >= 0

proc takeSlot(idx: int; outKind: var int; outOk: var bool;
              outBody, outErr, outBy: var string; outVersions: var seq[int]) =
  outKind = 0
  outOk = false
  outBody = ""
  outErr = ""
  outBy = ""
  outVersions = @[]
  withCapLock:
    if idx >= 0 and idx < gSlots.len:
      outKind = gSlots[idx].kind
      outOk = gSlots[idx].ok
      outBody = gSlots[idx].body
      outErr = gSlots[idx].err
      outBy = gSlots[idx].by
      outVersions = gSlots[idx].versions
      gSlots[idx] = Slot(token: 0, live: false, kind: 0, ok: false, body: "",
                         err: "", by: "", versions: @[])

proc versionList(vs: seq[int]): string =
  result = ""
  for i in 0 ..< vs.len:
    if i > 0: result.add ", "
    result.add $vs[i]

proc probeFor(cap: string; outBy: var string; outVersions: var seq[int]): bool =
  ## Ask, version-agnostically, whether ANY provider of this name is answering
  ## right now. This is what separates "you asked for the wrong version" from
  ## "nothing is there", and it is a measurement rather than a file read.
  outBy = ""
  outVersions = @[]
  var idx = -1
  var token = 0
  if not claimSlot(idx, token): return false
  if emit(probeName(cap), envProbe(cap, token)) != Ok:
    var k = 0
    var o = false
    var b, e, by: string = ""
    var vs: seq[int] = @[]
    takeSlot(idx, k, o, b, e, by, vs)
    return false
  var kind = 0
  var ok = false
  var body = ""
  var err = ""
  takeSlot(idx, kind, ok, body, err, outBy, outVersions)
  result = kind == 2

proc diagnose(cap: string; version: int): CapResult =
  ## Nothing answered the request. WHY, in decreasing order of certainty --
  ## the live probe first, because it is a measurement, and the roster files
  ## only after, because they are a claim.
  var by = ""
  var versions: seq[int] = @[]
  if probeFor(cap, by, versions):
    var alsoThis = false
    for v in versions:
      if v == version: alsoThis = true
    if alsoThis:
      # It says it provides exactly what was asked for and did not answer it.
      # Reachable when two mods share a name and one revoked mid-flight.
      return CapResult(outcome: coProviderSilent, body: "", provider: by,
                       versions: versions,
                       message: cap & "/" & $version & ": " & by &
                         " answers a probe for " & cap & " claiming version " &
                         $version & " and did not answer the call itself. " &
                         "That is a provider bug, not a missing provider.")
    return CapResult(outcome: coVersionMismatch, body: "", provider: by,
                     versions: versions,
                     message: "no provider for " & cap & "/" & $version &
                       ": " & by & " provides " & cap & " at version " &
                       versionList(versions) & ", not " & $version)

  let r = readRoster(cap)
  if not r.read:
    return CapResult(outcome: coRosterUnknown, body: "", provider: "",
                     versions: @[],
                     message: "no provider answered " & cap & "/" & $version &
                       ", and WHY could not be established: " & r.note)
  if r.declaring.len == 0:
    return CapResult(outcome: coNoProvider, body: "", provider: "",
                     versions: @[],
                     message: "no provider for " & cap & "/" & $version &
                       ": no installed mod declares " & cap & " in " & r.note)
  if r.selected.len == 0:
    var names = ""
    for i in 0 ..< r.declaring.len:
      if i > 0: names.add ", "
      names.add r.declaring[i]
    return CapResult(outcome: coProviderNotLoaded, body: "",
                     provider: r.declaring[0], versions: @[],
                     message: "no provider for " & cap & "/" & $version &
                       ": " & names & " declares it in the registry and the " &
                       "selection does NOT load it (" & r.note & "). The mod " &
                       "is installed; it is switched off.")
  var names = ""
  for i in 0 ..< r.selected.len:
    if i > 0: names.add ", "
    names.add r.selected[i]
  result = CapResult(outcome: coProviderSilent, body: "",
                     provider: r.selected[0], versions: @[],
                     message: "no provider for " & cap & "/" & $version &
                       ": " & names & " declares it in the registry AND the " &
                       "selection loads it, yet nothing answered. It is " &
                       "loaded and never called provide(), or its onLoad " &
                       "failed. INCONCLUSIVE -- check the backend log for " &
                       names & ".")

proc invoke*(cap: string; version: int; requestJson: string): CapResult =
  ## Call `cap`/`version` on whichever loaded mod provides it, right now.
  ##
  ## Resolution is per-call and lazy: see the header. There is no timeout to
  ## set, because delivery is synchronous -- when this returns, either a
  ## provider ran or none exists.
  ##
  ## `result.body` is populated ONLY on `coOk`, and only after the provider
  ## payload validated strictly. Every other outcome carries a `message`
  ## written to be shown verbatim.
  if cap.len == 0 or version < 0:
    return CapResult(outcome: coUnavailable, body: "", provider: "",
                     versions: @[],
                     message: "invoke() needs a capability name and a " &
                              "non-negative version")
  if side() == sideClient:
    return CapResult(outcome: coUnavailable, body: "", provider: "",
                     versions: @[],
                     message: "capabilities are a server-side facility; this " &
                              "is the client host, which has no mod set to " &
                              "resolve against")
  if requestJson.len > 0 and not strictValue(requestJson):
    return CapResult(outcome: coUnavailable, body: "", provider: "",
                     versions: @[],
                     message: "the request for " & cap & "/" & $version &
                       " is not strictly valid JSON, so it was not sent")
  ensureTables()
  if not ensureReplySub():
    return CapResult(outcome: coUnavailable, body: "", provider: "",
                     versions: @[],
                     message: "no reply channel: this mod could not subscribe " &
                       "to " & replyName(modGuid()) & ", so an answer could " &
                       "not reach it and no request was sent")
  var idx = -1
  var token = 0
  if not claimSlot(idx, token):
    return CapResult(outcome: coUnavailable, body: "", provider: "",
                     versions: @[],
                     message: "all " & $SlotCapacity & " in-flight capability " &
                       "slots are taken; " & cap & "/" & $version &
                       " was refused rather than queued")
  let st = emit(capName(cap, version), envRequest(cap, version, token,
                                                  requestJson))
  var kind = 0
  var ok = false
  var body = ""
  var err = ""
  var by = ""
  var versions: seq[int] = @[]
  takeSlot(idx, kind, ok, body, err, by, versions)
  if st != Ok:
    return CapResult(outcome: coUnavailable, body: "", provider: "",
                     versions: @[],
                     message: "the host refused to publish " &
                       capName(cap, version) & ": " & lastError())
  if kind == 0:
    return diagnose(cap, version)
  if not ok:
    if err.len > 0 and err.startsWith("the provider response body"):
      return CapResult(outcome: coBadReply, body: "", provider: by,
                       versions: @[],
                       message: cap & "/" & $version & ": " & by &
                         " answered with a payload that is not strictly " &
                         "valid JSON. Treated as a failure.")
    return CapResult(outcome: coProviderError, body: "", provider: by,
                     versions: @[],
                     message: cap & "/" & $version & " refused by " & by &
                              ": " & err)
  result = CapResult(outcome: coOk, body: body, provider: by, versions: @[],
                     message: "")

proc invokeOrRefuse*(cap: string; version: int; requestJson: string;
                     outBody: var string): string =
  ## The two-line form for a caller that only wants "did it work, and if not
  ## what do I show the player". Returns "" on success, the refusal text
  ## otherwise, and NEVER writes `outBody` unless the call succeeded.
  outBody = ""
  let r = invoke(cap, version, requestJson)
  if r.outcome == coOk:
    outBody = r.body
    return ""
  result = "REFUSED (" & outcomeName(r.outcome) & ") " & r.message

proc describe*(r: CapResult): string =
  ## One line for a diagnostic block. Three outcomes, never two: `ok`, a hard
  ## refusal, or an INCONCLUSIVE one, and the word is in the text.
  if r.outcome == coOk:
    return "ok (" & r.provider & ", " & $r.body.len & " bytes)"
  if r.outcome == coProviderSilent or r.outcome == coRosterUnknown:
    return "INCONCLUSIVE (" & outcomeName(r.outcome) & ") " & r.message
  result = "REFUSED (" & outcomeName(r.outcome) & ") " & r.message
