## bridge/core.nim -- CONFIG, THE HOST-VERB WRAPPERS, AND THE REFUSAL LEDGER.
##
## Everything in `mods/basement/bridge/` that touches the host goes through
## this file, for one reason: a host verb can be ABSENT (an older host) or
## REFUSED BY A FLAG, and those two are different answers that a mod must not
## flatten into "it did not work". Both are logged ONCE, at warn, NAMING THE
## FLAG -- `hostHttp` for the network, `hostPlayWav` for the sound -- because a
## feature that declines in silence is the worst thing this project produces.
##
## THREE OUTCOMES, NOT TWO, on every call:
##   * `call(...) != Ok`      -> the verb does not exist on this host. The
##                              bridge is INERT and says so; it is not a
##                              failure of the backend and is not reported as
##                              one.
##   * `accepted:false`       -> the host answered and refused. `why` is the
##                              host's own sentence, logged verbatim and
##                              deduplicated by its text.
##   * `accepted:true`        -> in flight. The ANSWER arrives later on the
##                              `host.http.done` event, keyed by our `id`.
##
## Nothing here parses a route, knows a directive kind or touches game memory.

import aowlspt
import aowlspt/server
import aowlspt/json

const
  HttpVerb* = "aowlspt.host::http"
  PlayWavVerb* = "aowlspt.host::play_wav"
  PhaseVerb* = "aowlspt.host::raid_phase"

# --------------------------------------------------------------- config

var cfgUrl = "http://127.0.0.1:6969"
var cfgEnabled = false
var cfgPollWaitMs = 20000
var cfgPttKey = "V"
var cfgSpawnOnMenu = true

proc backendUrl*(): string = cfgUrl
proc bridgeOn*(): bool = cfgEnabled
proc pollWaitMs*(): int = cfgPollWaitMs
proc pttKeyName*(): string = cfgPttKey
proc spawnOnMenu*(): bool = cfgSpawnOnMenu

proc loadBridgeConfig*() =
  ## Every key has a default that WORKS WHEN THE KEY IS ABSENT: this half of
  ## the mod is written against a `config.json` somebody else owns, so a
  ## missing key reads its default and is not announced as a fault.
  ## The backend clamps `wait` to 25 000 ms (CLIENT-CONTRACT section 4);
  ## clamping here as well means the number `bridgeStatusJson` reports is the
  ## number that was actually asked for.
  cfgUrl = setting("bridgeBackendUrl").asText(cfgUrl)
  cfgEnabled = setting("bridgeEnabled").asBool(cfgEnabled)
  cfgPollWaitMs = setting("bridgePollWaitMs").asInt(cfgPollWaitMs)
  cfgPttKey = setting("bridgePttKey").asText(cfgPttKey)
  cfgSpawnOnMenu = setting("bridgeSpawnOnMenu").asBool(cfgSpawnOnMenu)
  if cfgPollWaitMs < 0: cfgPollWaitMs = 0
  if cfgPollWaitMs > 25000: cfgPollWaitMs = 25000

proc routeUrl*(path: string): string =
  var base = cfgUrl
  while base.len > 0 and base[base.len - 1] == '/':
    base = substr(base, 0, base.len - 2)
  result = base & "/aowlspt/basement" & path

# ------------------------------------------------- the said-once ledger

var gSaid: seq[string] = @[]

proc saidOnce*(tag: string): bool =
  ## True if this exact sentence has already been said. The ledger is keyed by
  ## the host's own `why` text, so a NEW reason is always heard while a
  ## repeating one cannot fill the log.
  var i = 0
  while i < gSaid.len:
    if gSaid[i] == tag: return true
    i = i + 1
  gSaid.add tag
  result = false

proc saidCount*(): int = gSaid.len

# ------------------------------------------------------------ counters

var gSubmitted = 0
var gAccepted = 0
var gRefused = 0
var gCompleted = 0
var gVerbMissing = false
var gFlagOff = false
var gLastWhy = ""
var gLastStatus = 0
var gLastError = ""
var gIdSeq = 0

proc httpVerbMissing*(): bool = gVerbMissing
proc httpFlagOff*(): bool = gFlagOff
proc submitted*(): int = gSubmitted
proc accepted*(): int = gAccepted
proc refused*(): int = gRefused
proc completed*(): int = gCompleted
proc lastWhy*(): string = gLastWhy
proc lastStatus*(): int = gLastStatus
proc lastHttpError*(): string = gLastError

proc noteCompletion*(status: int; error: string) =
  gCompleted = gCompleted + 1
  gLastStatus = status
  gLastError = error

proc nextId*(prefix: string): string =
  gIdSeq = gIdSeq + 1
  result = prefix & "-" & $gIdSeq

proc idPrefix*(id: string): string =
  ## The tag before the first dash. This is how a completion is routed back to
  ## the piece of the bridge that asked for it: the host hands back only the
  ## id we chose, so the id IS the routing.
  var i = 0
  while i < id.len:
    if id[i] == '-': return substr(id, 0, i - 1)
    i = i + 1
  result = id

# ------------------------------------------------------- the http verb

proc httpSend*(id, meth, url, body: string): bool =
  ## Submit one request. Returns whether the HOST ACCEPTED IT, which is not
  ## whether it succeeded -- the outcome arrives on `host.http.done`.
  var d = newDoc()
  d.setText("id", id)
  d.setText("method", meth)
  d.setText("url", url)
  d.setText("body", body)
  d.setNumber("timeoutMs", cfgPollWaitMs + 10000)
  var raw = ""
  gSubmitted = gSubmitted + 1
  if call(HttpVerb, d.text, raw) != Ok or raw.len == 0:
    gVerbMissing = true
    gRefused = gRefused + 1
    gLastWhy = "no `" & HttpVerb & "` verb on this host"
    if not saidOnce("verb-missing:http"):
      warn "basement bridge: this host has NO `" & HttpVerb & "` verb, so " &
           "the bridge cannot reach the backend at all. The whole client " &
           "half is INERT for this session. That is a HOST capability " &
           "question (the verb landed 2026-09-06, flag `hostHttp`), NOT a " &
           "backend fault, and it is deliberately not reported as one."
    return false
  if not asBool(field(raw, "accepted"), false):
    let why = asText(field(raw, "why"), "the host refused and gave no reason")
    gRefused = gRefused + 1
    gLastWhy = why
    if why.len >= 4 and substr(why, 0, 3) == "flag": gFlagOff = true
    if not saidOnce("refused:" & why):
      warn "basement bridge: `" & HttpVerb & "` REFUSED this request -- " &
           why & ". (The network verb is gated by the host flag `hostHttp`, " &
           "default OFF, with the allowlist `hostHttpAllow`; see " &
           "docs/MODDING.md.) Nothing is retried behind your back."
    return false
  gFlagOff = false
  gAccepted = gAccepted + 1
  result = true

proc httpGet*(id, url: string): bool = httpSend(id, "GET", url, "")
proc httpPost*(id, url, body: string): bool = httpSend(id, "POST", url, body)

# ------------------------------------------------------------- /observe

var gObserved = 0

proc observed*(): int = gObserved

proc observe*(d: var Doc; kind: string) =
  ## `POST /observe`, fire and forget: the reply carries `directives` and a
  ## `note`, both read on the completion path, neither waited for.
  d.setText("kind", kind)
  gObserved = gObserved + 1
  discard httpPost(nextId("bmobs"), routeUrl("/observe"), d.text)

# ---------------------------------------------------------------- /ack

var gAcks = 0
var gAcksOk = 0

proc acks*(): int = gAcks
proc acksOk*(): int = gAcksOk

proc ackDirective*(seqNo: int; ok: bool; note: string) =
  ## Every directive is acked exactly once, executed or refused. `ok:false`
  ## with a reason is a FIRST-CLASS ANSWER (CLIENT-CONTRACT section 5): the
  ## backend can react to a refusal and cannot react to silence.
  var d = newDoc()
  d.setNumber("seq", seqNo)
  d.setBool("ok", ok)
  d.setText("note", note)
  gAcks = gAcks + 1
  if ok: gAcksOk = gAcksOk + 1
  discard httpPost(nextId("bmack"), routeUrl("/ack"), d.text)

# ------------------------------------------------------------- play_wav

var gPlayed = 0
var gPlayRefused = 0

proc played*(): int = gPlayed
proc playRefused*(): int = gPlayRefused

proc playWav*(path: string; why: var string): bool =
  ## Non-spatial, and `volume` is IGNORED by the host -- both stated in the
  ## host's own answer, and neither worked around here.
  var d = newDoc()
  d.setText("path", path)
  var raw = ""
  if call(PlayWavVerb, d.text, raw) != Ok or raw.len == 0:
    why = "no `" & PlayWavVerb & "` verb on this host"
    gPlayRefused = gPlayRefused + 1
    if not saidOnce("verb-missing:play_wav"):
      warn "basement bridge: this host has NO `" & PlayWavVerb & "` verb, so " &
           "no `say` segment can be HEARD this session. Every line is still " &
           "shown as a subtitle in the log and every directive is still " &
           "acked -- with ok:false and this reason, never in silence."
    return false
  if not asBool(field(raw, "ok"), false):
    why = asText(field(raw, "why"), "the host refused and gave no reason")
    gPlayRefused = gPlayRefused + 1
    if not saidOnce("playwav-refused:" & why):
      warn "basement bridge: `" & PlayWavVerb & "` REFUSED -- " & why &
           ". (Gated by the host flag `hostPlayWav`, default OFF, and the " &
           "path must sit under `hostPlayWavRoots`.)"
    return false
  gPlayed = gPlayed + 1
  why = ""
  result = true

# ------------------------------------------------------------ raid_phase

type
  Phase* = object
    asked*: bool
    phase*: string
    gameWorld*: bool
    why*: string

proc raidPhase*(): Phase =
  ## Asked of the host, exactly as `mods/autoraid/ar/phase.nim` does. `asked =
  ## false` is INCONCLUSIVE -- "I could not look" -- and is never reported as
  ## "not in a raid".
  result = Phase(asked: false, phase: "UNKNOWN", gameWorld: false, why: "")
  var raw = ""
  let empty = ""
  if call(PhaseVerb, empty, raw) != Ok or raw.len == 0:
    if not saidOnce("verb-missing:raid_phase"):
      warn "basement bridge: this host has no `" & PhaseVerb & "` verb, so " &
           "the bridge cannot tell MENU from DEPLOYED. The `raid_started` / " &
           "`raid_ended` facts and the /spawn gesture are OFF for this " &
           "session, and that is said here, once."
    return
  result.asked = true
  result.phase = asText(field(raw, "phase"), "UNKNOWN")
  result.gameWorld = asBool(field(raw, "gameWorld"), false)
  result.why = asText(field(raw, "why"), "")
