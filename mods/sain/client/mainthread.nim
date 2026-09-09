## Whether `onMainThread` is actually Unity's thread, asked rather than assumed.
##
## Every other sensor in this mod reads a managed field, and reading a managed
## field from the host's own thread is fine. The cover sampler is the first
## thing here that calls *the engine* -- `Physics.Raycast` touches Unity's
## scene state -- and doing that from a thread that is not the player loop is
## not a wrong number, it is a crash.
##
## The host answers the question outright. `docs/IL2CPP.md`: it detours a
## method Unity runs once per frame and drains `invoke_main` from inside it,
## and `call("aowlspt.host::main_thread")` reports whether that hook has
## **actually fired** rather than merely been installed. `bound` is the gate,
## and it is the only gate: a hook installed and never reached has proved
## nothing, and a mod that trusted "installed" would raycast from a worker.
##
## `perFrame` is read too and is *tri-state*. Absent is not false -- it is a
## host that predates the question -- and the difference matters here for one
## reason: a drain method that fires many times a frame is still Unity's
## thread, so the sampler is still legal, but the rate at which a queued job
## comes back is not a frame rate and this mod does not report it as one.
## `mods/perf` reached the same conclusion for its own readout and this follows
## it rather than inventing a second convention.
##
## Asked on a timer, never per frame: `call` is the host's reflective path at
## about a microsecond, the answer changes at most once in a session, and
## paying a microsecond a frame to re-learn something that has already settled
## is the shape of cost this whole mod is arranged against.

import aowlspt
import aowlspt/json

type
  MainThread* = object
    asked*: bool
    ok*: bool              ## the host answered at all
    bound*: bool           ## the drain hook has fired on a Unity thread
    stalled*: bool
    perFrameKnown*: bool
    perFrame*: bool
    frames*: int64
    methodName*: string

func unknownMainThread*(): MainThread =
  MainThread(asked: false, ok: false, bound: false, stalled: false,
             perFrameKnown: false, perFrame: false, frames: 0'i64,
             methodName: "")

var gMt = unknownMainThread()
var gAskedAt = 0'i64

const AskIntervalMs = 2000'i64
  ## How often the question is re-asked while the answer is still "not yet".
  ## Once it is `bound` it is never asked again -- a drain that has fired
  ## cannot un-fire.

proc decode(raw: string): MainThread =
  result = unknownMainThread()
  result.asked = true
  if raw.len == 0:
    return
  result.ok = true
  result.bound = asBool(field(raw, "bound"), false)
  result.stalled = asBool(field(raw, "stalled"), false)
  result.frames = int64(asInt(field(raw, "frames"), 0))
  result.methodName = asText(field(raw, "method"), "")
  let pf = field(raw, "perFrame")
  result.perFrameKnown = pf.exists
  result.perFrame = asBool(pf, false)

proc refreshMainThread*(nowMillis: int64): MainThread =
  ## The host's answer, cached, re-asked at most every two seconds until it is
  ## affirmative.
  if gMt.bound:
    return gMt
  if gMt.asked and nowMillis - gAskedAt < AskIntervalMs:
    return gMt
  gAskedAt = nowMillis
  var raw = ""
  let empty = "[]"
  if call("aowlspt.host::main_thread", empty, raw) != Ok:
    gMt = unknownMainThread()
    gMt.asked = true
    return gMt
  gMt = decode(raw)
  result = gMt

proc mainThread*(): MainThread = gMt

proc mainThreadNote*(): string =
  ## One sentence for the log, saying what was asked and what came back.
  if not gMt.asked:
    return "the host has not been asked yet"
  if not gMt.ok:
    return "the host does not answer aowlspt.host::main_thread, so nothing " &
           "here may touch the engine"
  if not gMt.bound:
    return "the host's main-thread drain has not fired yet" &
           (if gMt.methodName.len > 0: " (drain method " & gMt.methodName & ")"
            else: " (no drain method bound)") &
           ", so no engine call is being made"
  var s = "Unity's thread, confirmed by " &
          (if gMt.methodName.len > 0: gMt.methodName else: "an unnamed drain") &
          " after " & $gMt.frames & " firings"
  if not gMt.perFrameKnown:
    s = s & "; this host does not say whether that method runs once a frame, " &
        "so the firing count is not read as a frame rate"
  elif not gMt.perFrame:
    s = s & "; that method runs more than once a frame, which is still the " &
        "right thread and is not a frame count"
  if gMt.stalled:
    s = s & " -- and the host reports the drain stalled"
  result = s
