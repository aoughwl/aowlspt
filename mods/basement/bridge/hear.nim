## bridge/hear.nim -- PUSH-TO-TALK. THE WIRE HALF IS REAL; THE KEY IS A STUB.
##
## WHAT IS MISSING, NAMED: there is no primitive on this host that gives a
## client mod the HELD state of a key.
##
##   * The verb list of `aowlspt_nim_call` (`host/Aowlspt.Host.Il2Cpp/
##     aowlhost.nim`, MEASURED 2026-09-06) is: `args_declare`, `cmdline`,
##     `frame_bench`, `frame_bench_arm`, `gfx_apply`, `http`, `http_poll`,
##     `main_thread`, `original_bytes`, `patch_stats`, `play_wav`,
##     `raid_phase`, `render_thread`, `table_stats`, `ui_show_status`. NOT ONE
##     of them reports a key.
##   * The SDK (`aowl/src/aowlspt*`) has `keybindSetting` -- which stores a key
##     NAME in config so a settings row can show it -- and no reader for it.
##   * The only MEASURED read path in this repo is `mods/autoraid/ar/native.nim`:
##     its OWN C translation unit calling `UnityEngine.Input::GetKeyDown` at a
##     byte-verified RVA, on Unity's thread. It is autoraid-private, and it is
##     EDGE-triggered (`GetKeyDown`), while push-to-talk needs the HELD state
##     (`Input::GetKey`, a different method at a different RVA).
##
## So this file does NOT poll a key, and it does NOT invent an offset. It logs
## that refusal ONCE, naming the primitive, and it implements the half that can
## be written and tested today: the two POSTs. They are driven by the bus event
## `basement.ptt {state:"down"|"up"}`, so the protocol can be exercised end to
## end from `aowlspt-sim --emit` or from any other mod, and so that when a
## generic host key verb (or a `GetKey` RVA in a shared module) does land, the
## only change here is what CALLS `pttDown`/`pttUp`.
##
## The backend half of `POST /aowlspt/basement/speech/ptt` is being added
## separately (BRIDGE-AOWLSPT.md); a 404 from it is reported by the link as an
## HTTP status, not silently swallowed.

import aowlspt
import aowlspt/server
import aowlspt/json
import core

var gSession = ""
var gSessions = 0
var gDowns = 0
var gUps = 0
var gHeld = false
var gSubscribed = false

proc sessionId*(): string = gSession
proc pttSessions*(): int = gSessions
proc pttDowns*(): int = gDowns
proc pttUps*(): int = gUps
proc holding*(): bool = gHeld

proc post(state: string) =
  var d = newDoc()
  d.setText("session", gSession)
  d.setText("state", state)
  discard httpPost(nextId("bmptt"), routeUrl("/speech/ptt"), d.text)

proc pttDown*() =
  ## A NEW session id per utterance (CLIENT-CONTRACT section 3: reusing one
  ## after `final` starts a new buffer, so a fresh id per press keeps the two
  ## sides describing the same thing).
  if gHeld:
    return
  gSessions = gSessions + 1
  gSession = "bmptt-" & $nowMs() & "-" & $gSessions
  gHeld = true
  gDowns = gDowns + 1
  post("down")

proc pttUp*() =
  ## Always sent, including on cancel: a session that is never finalised leaks
  ## a buffer on the backend.
  if not gHeld:
    return
  gHeld = false
  gUps = gUps + 1
  post("up")

proc onBusPtt(payload: string): string =
  result = ""
  let state = asText(field(payload, "state"), "")
  if state == "down": pttDown()
  elif state == "up": pttUp()
  else:
    warn "basement hear: `basement.ptt` needs {\"state\":\"down\"} or " &
         "{\"state\":\"up\"}; got \"" & state & "\". Nothing was sent."

proc install*() =
  ## Announces the missing primitive ONCE, at load, and wires the bus entry
  ## point that stands in for it.
  if gSubscribed: return
  if on("basement.ptt", onBusPtt) != Ok:
    warn "basement hear: could not subscribe to `basement.ptt`; push-to-talk " &
         "has no entry point at all this session."
    return
  gSubscribed = true
  if not saidOnce("ptt-no-key-primitive"):
    warn "basement hear: push-to-talk is NOT bound to a key. The configured " &
         "key is `" & pttKeyName() & "` and NOTHING READS IT: no " &
         "`aowlspt.host::*` verb reports key state, and the only measured " &
         "read path in this repo is mods/autoraid's private C unit calling " &
         "`UnityEngine.Input::GetKeyDown` at a byte-verified RVA -- which is " &
         "edge-triggered, while push-to-talk needs the HELD state " &
         "(`Input::GetKey`). No offset is guessed here. Until a generic key " &
         "primitive exists, drive it with the bus event `basement.ptt` " &
         "{state:\"down\"|\"up\"}; the two POSTs to /speech/ptt are real."
