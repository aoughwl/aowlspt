## Frame-time measurement.
##
## A performance mod that cannot show its effect is a claim rather than a
## result, so this is the half of `mods/perf` that has to be right even when
## every knob in `knobs.nim` is refused.
##
## ---------------------------------------------------------------------------
## Where the frame count comes from
## ---------------------------------------------------------------------------
##
## **The default source is the host, not the game, and it is a frame count only
## when the host says so.** `aowlspt.host::main_thread` reports `frames`, which
## is the host's `aowl_mq_fires`: one increment every time the drain hook fires
## on the thread that owns the drain. Whether that is a frame count depends
## entirely on which method the host managed to detour. Three of its four
## candidates are methods Unity's player loop enters once a frame; the
## last resort, `UnityEngine.Time::get_deltaTime`, is on the list because a
## main-thread-only API proves its caller's thread and it runs many times a
## frame. Dividing that by wall-clock time gives calls per second, larger than
## the frame rate by an unknown factor — a plausible number rather than a
## refusal, which is the shape this mod exists to avoid producing.
##
## The same report now carries **`perFrame`**, and that is where the answer
## comes from. This file used to hold a whitelist of the three per-frame method
## names, which worked and was the wrong place for it: a mod-side list of
## host-side names has to be edited every time the host's list is, and the
## failure when it is not is precisely the confident wrong number above. The
## host knows which method it picked and whether that method runs once a frame,
## because it picked it. `frameSourceOf` reads that fact; `Window.source`
## carries it; `rateWord` decides whether the line may say "fps" at all.
##
## A host too old to answer omits the key, and an absent key means **unknown**,
## not true — so the readout falls back to "drain firings/s" and says which
## kind of not-knowing it is. `srcDrainUnknown` and `srcDrainFirings` are
## separate constants for exactly that: "the host says this fires more than
## once a frame" and "this host does not report whether it does" want
## different actions from a reader, even though neither may be called fps.
##
## When `hud.readUnityTime` is on and `UnityEngine.Time::get_frameCount` bound,
## there is a true frame count available and the window uses **that** instead —
## one bound call per window, about 10 ns, and nothing to classify. That is the
## only source here that is a frame count by definition rather than by report.
##
## That matters because of what the alternative costs. `UnityEngine.Time`'s
## getters are Unity API, and Unity API is main-thread-only; `onUpdate` runs on
## the host's own attached thread whenever the host could not bind a per-frame
## method, so `Time` cannot be read from there. There *is* a repeating
## main-thread callback in the ABI now — `everyMain`, which the per-frame pump
## at the bottom of this file uses — but it fires once per drain, and the
## window sampler wants once per `hud.intervalMs`, which is a different thing.
## So reading `Time.frameCount` is **opt-in**, off by default, and gated on the
## host reporting that its drain really is Unity's thread.
##
## ---------------------------------------------------------------------------
## What this costs
## ---------------------------------------------------------------------------
##
## **This file used to say "nothing per frame, because there is no per-frame
## code here", and that is no longer true.** The per-frame pump at the bottom of
## this file runs once a frame, on the game's thread, whenever it is enabled and
## the host reports a per-frame drain — and the sentence is corrected rather
## than deleted because the reason it changed is the point.
##
## What changed is what was being measured. A window that divides frames by
## wall clock is a **mean**, and a mean cannot see a hitch: a second holding
## fifty-five even frames and one 200 ms freeze reports about the same number as
## a second of sixty even ones. `best` and `worst` do not rescue it, because
## they are the best and worst *of the one-second means*. Stutter is what a
## performance mod is for, so something has to sample every frame, and nothing
## that samples once a second can. `hist.nim` says the rest.
##
## What it costs is measured rather than assumed, and **what can be measured
## from here shrank when the chain moved into the library**. `benchPumpBody`
## times the recording — a clock read, a subtraction and a store into a fixed
## array — and `pumpBodyNs` times the same work from inside a real firing.
## Neither includes the re-arm any more: `everyMain` re-queues in the library's
## trampoline *after* this module's handler has returned, so the enqueue is no
## longer inside a window this module holds a clock around. It is said to be
## not measured rather than estimated. The pump is also the only part of this
## mod that can be switched off at run time by the thing it measures: a whole
## readout window with no firing is reported in the next readout rather than
## letting the distribution quietly stop growing.
##
## It still installs **no hooks**, and that is now a cost comparison rather than
## a principle. ABI revision 4's `hookTyped` hands a handler the saved registers
## instead of JSON, at about 24 ns a firing with a measured zero allocations on
## either side — cheaper per firing than the queued callback below by two orders
## of magnitude. What it costs instead is a second detour on the same per-frame
## method the host has already detoured for its drain, which is the hottest path
## in the process. The queue chain is microseconds and touches nothing; the hook
## is nanoseconds and touches everything. Until the microseconds show up in the
## measurement that is printed every window, the chain is the right trade, and
## when they do the swap is a small one.
##
## The window sampler still runs once per `hud.intervalMs` (1000 by default).
## The Unity cross-check, when enabled, is two bound calls and integer
## arithmetic into scalar globals — no string, no seq, no `Args` on the heap —
## and `benchUnitySample` measures it so the claim is a number rather than an
## assertion.
##
## Nothing here has ever run against BSG's client.

import aowlspt
import aowlspt/json
import aowlspt/il2cpp
import aowlspt/fast
import hist

# ---------------------------------------------------------------------------
# The host's own frame counter
# ---------------------------------------------------------------------------

type
  MainThreadInfo* = object
    ok*: bool          ## the report parsed
    bound*: bool       ## the drain really is on Unity's thread
    frames*: int64
    methodName*: string
    stalled*: bool
    perFrame*: bool       ## the host says its drain method runs once per frame
    perFrameKnown*: bool  ## the host answered that question at all

proc decodeMainThread*(raw: string): MainThreadInfo =
  ## The report, parsed. Split out from the call so the simulator can hand it
  ## payloads no runtime in that process would produce -- including the one an
  ## older host produces, which is the case that has to fall conservatively.
  result = MainThreadInfo(ok: false, bound: false, frames: 0'i64,
                          methodName: "", stalled: false, perFrame: false,
                          perFrameKnown: false)
  if raw.len == 0:
    return
  result.ok = true
  result.bound = asBool(field(raw, "bound"), false)
  result.frames = int64(asInt(field(raw, "frames"), 0))
  result.methodName = asText(field(raw, "method"), "")
  result.stalled = asBool(field(raw, "stalled"), false)
  # Tri-state on purpose. `perFrame` absent is **not** false and is **not**
  # true: it is a host that predates the question. `asBool(..., false)` alone
  # would collapse "this host does not know" into "this method is not
  # per-frame" -- which happens to be the safe direction, and would still be a
  # claim nobody made.
  let pf = field(raw, "perFrame")
  result.perFrameKnown = pf.exists
  result.perFrame = asBool(pf, false)

proc mainThreadInfo*(): MainThreadInfo =
  ## `call("aowlspt.host::main_thread")`, decoded.
  ##
  ## Answered by the host before it checks whether the runtime is up, so this
  ## is meaningful even with no game, which is what makes it usable as the
  ## "should I touch Unity at all?" gate rather than as an afterthought.
  result = decodeMainThread("")
  var raw = ""
  let empty = "[]"
  if call("aowlspt.host::main_thread", empty, raw) != Ok:
    return
  result = decodeMainThread(raw)

const
  srcNone* = 0
  srcDrainFrames* = 1    ## the host's drain, and the host says once per frame
  srcDrainFirings* = 2   ## the host's drain, and the host says more than once
  srcDrainUnknown* = 3   ## the host's drain, and this host does not say
  srcUnityFrames* = 4    ## UnityEngine.Time::frameCount, through a binding

proc frameSourceOf*(mt: MainThreadInfo): int =
  ## Which counter `mt.frames` is -- **asked of the host rather than guessed**.
  ##
  ## This used to be a whitelist of method names in this file, and the reason it
  ## is not any more is worth keeping written down. A mod-side list of host-side
  ## names has to be edited every time the host's candidate list is, and the
  ## failure when it is not edited is a readout confidently reporting fps for
  ## something that is not a frame count -- a plausible number rather than a
  ## refusal, which is the failure shape this whole mod is arranged to avoid
  ## producing. The host knows which method it chose and whether that method
  ## runs once a frame, because it made the choice; `perFrame` in
  ## `aowlspt.host::main_thread` is that fact recorded where the choice is made,
  ## rather than re-derived from a name over here.
  ##
  ## A host too old to answer omits the key, and **an absent key means unknown,
  ## not true**. `srcDrainUnknown` is kept distinct from `srcDrainFirings` so the
  ## log can say which of the two it is: "this method fires more than once a
  ## frame" and "this host does not report whether it does" want different
  ## actions from whoever reads them, even though the readout treats them the
  ## same and calls neither a frame rate.
  if not mt.perFrameKnown: return srcDrainUnknown
  if mt.perFrame: return srcDrainFrames
  result = srcDrainFirings

proc countsFrames*(src: int): bool =
  ## Whether a number from this source may honestly be called a frame rate.
  result = src == srcDrainFrames or src == srcUnityFrames

proc sourceName*(src: int): string =
  case src
  of srcDrainFrames:
    result = "the host's drain, which it reports as once per frame"
  of srcDrainFirings:
    result = "the host's drain, which it reports as more than once a frame"
  of srcDrainUnknown:
    result = "the host's drain, whose multiplicity this host does not report"
  of srcUnityFrames: result = "UnityEngine.Time.frameCount"
  else: result = "nothing"

proc rateWord*(src: int): string =
  ## What the number in the readout may honestly be called.
  if countsFrames(src): result = "fps"
  else: result = "drain firings/s"

# ---------------------------------------------------------------------------
# The optional Unity cross-check
# ---------------------------------------------------------------------------

var gRt: Il2Cpp
var gRtOpen = false
var bFrameCount: Binding
var bDeltaTime: Binding
var gUnityBound = false
var gUnityWhy = ""

proc bindUnity*(): bool =
  ## Binds `UnityEngine.Time`'s two cheap getters.
  ##
  ## From `onUpdate` on the first tick the type resolves, never from `onLoad`:
  ## the process has an IL2CPP runtime long before the game has loaded its own
  ## assemblies, and a binding refused then is refused permanently.
  if gUnityBound:
    return true
  if not gRtOpen:
    gRt = openIl2Cpp()
    if not gRt.loaded:
      gUnityWhy = "GameAssembly.dll is not in this process"
      return false
    gRtOpen = true
  bFrameCount = bindMethod(gRt, "UnityEngine.Time", "get_frameCount", 0)
  if not bFrameCount.ok:
    gUnityWhy = bFrameCount.why
    return false
  bDeltaTime = bindMethod(gRt, "UnityEngine.Time", "get_deltaTime", 0)
  if not bDeltaTime.ok:
    gUnityWhy = bDeltaTime.why
    return false
  gUnityBound = true
  gUnityWhy = bFrameCount.why & " / " & bDeltaTime.why
  result = true

proc unityBound*(): bool = gUnityBound
proc unityWhy*(): string = gUnityWhy

# The sample path's own state. Scalars only, on purpose: this is the one
# procedure in the mod whose cost is claimed, and a string or a seq anywhere in
# it would make the claim false.
var gUnityFrames: int64 = 0
var gUnityDeltaUs: int64 = 0
var gUnitySamples: int64 = 0
var gUnityWorstUs: int64 = 0
var gUnityBestUs: int64 = 0
var gUnitySumUs: int64 = 0
var gUnitySampleNs: int64 = 0

proc unitySample*(): bool =
  ## Two bound calls and integer arithmetic. Allocates nothing.
  ##
  ## `noArgs()` is a stack object holding a fixed array, so the argument block
  ## never reaches the heap either; `callInt32` and `callFloat` pack it and make
  ## one indirect call each (`docs/PERF.md`: ~10 ns and ~8 ns).
  if not gUnityBound:
    return false
  var a = noArgs()
  let frames = int64(callInt32(bFrameCount, nullPtr(), a))
  a.reset()
  let dt = callFloat(bDeltaTime, nullPtr(), a)

  var us = int64(dt * 1000000.0)
  if us < 0: us = 0
  gUnityFrames = frames
  gUnityDeltaUs = us
  gUnitySumUs = gUnitySumUs + us
  if gUnitySamples == 0 or us > gUnityWorstUs:
    gUnityWorstUs = us
  if gUnitySamples == 0 or us < gUnityBestUs:
    gUnityBestUs = us
  gUnitySamples = gUnitySamples + 1
  result = true

proc unityFrameCount*(ok1: var bool): int64 =
  ## `Time.frameCount`, on its own, for use as the window's frame source.
  ##
  ## One bound call — about 10 ns, `docs/PERF.md` — and unlike the host's drain
  ## counter it is a frame count by definition rather than by an argument about
  ## which method the host managed to detour. Legal only where the drain is
  ## Unity's thread, which is what `hud.readUnityTime` is gated on.
  ok1 = false
  if not gUnityBound:
    return 0
  var a = noArgs()
  result = int64(callInt32(bFrameCount, nullPtr(), a))
  ok1 = true

proc unityFrames*(): int64 = gUnityFrames
proc unityDeltaUs*(): int64 = gUnityDeltaUs
proc unityWorstUs*(): int64 = gUnityWorstUs
proc unityBestUs*(): int64 = gUnityBestUs
proc unitySampleNs*(): int64 = gUnitySampleNs
proc unitySamples*(): int64 = gUnitySamples

proc unityMeanUs*(): int64 =
  if gUnitySamples <= 0: return 0
  result = gUnitySumUs div gUnitySamples

proc benchUnitySample*(iterations: int): int64 =
  ## Nanoseconds per call of `unitySample`, averaged.
  ##
  ## This is the mod's own allocation proof, and it is an indirect one: the ABI
  ## has no "how many bytes has this mod allocated" and reaching for one would
  ## mean leaving the API this mod is written against. What it does establish is
  ## tight. A nimony heap allocation and its matching free are tens of
  ## nanoseconds even when the allocator is warm; over a million iterations one
  ## per call would also be tens of megabytes of churn, which shows up in the
  ## mean immediately and in the variance between batches straight after. A path
  ## that stays inside a few tens of nanoseconds per call, run a million times,
  ## is not allocating.
  if iterations <= 0 or not gUnityBound:
    return 0
  # Snapshot and restore the statistics, so measuring does not move them.
  let sFrames = gUnityFrames
  let sDelta = gUnityDeltaUs
  let sSamples = gUnitySamples
  let sWorst = gUnityWorstUs
  let sBest = gUnityBestUs
  let sSum = gUnitySumUs

  let t0 = perfCounter()
  var i = 0
  while i < iterations:
    discard unitySample()
    inc i
  let t1 = perfCounter()

  gUnityFrames = sFrames
  gUnityDeltaUs = sDelta
  gUnitySamples = sSamples
  gUnityWorstUs = sWorst
  gUnityBestUs = sBest
  gUnitySumUs = sSum
  result = nanosBetween(t0, t1) div int64(iterations)
  gUnitySampleNs = result

# ---------------------------------------------------------------------------
# The window
# ---------------------------------------------------------------------------
#
# One window per readout interval. `perfCounter` rather than `nowMs`, for the
# reason docs/PERF.md gives: a millisecond clock is the wrong resolution by
# three orders of magnitude for anything frame-shaped, and a window that
# straddles a clock tick would report a frame rate that is off by whatever
# fraction of a millisecond it lost.

type
  Window* = object
    ok*: bool
    frames*: int64      ## counts in the window, of whatever `source` says
    nanos*: int64       ## wall clock the window covered
    fpsMilli*: int64    ## counts per second x1000, so it stays an integer
    source*: int        ## which counter produced it; see `sourceName`

var gHaveBase = false
var gBaseTicks: int64 = 0
var gBaseFrames: int64 = 0
var gBaseSource = srcNone
var gWindows: int64 = 0
var gBestFpsMilli: int64 = 0
var gWorstFpsMilli: int64 = 0

proc resetWindow*() =
  gHaveBase = false
  gBaseSource = srcNone
  gWindows = 0
  gBestFpsMilli = 0
  gWorstFpsMilli = 0

proc closeWindow*(frames: int64; source: int = srcDrainFrames): Window =
  ## Closes the current window at `frames` and opens the next one.
  ##
  ## The first call establishes the base and reports nothing, because a window
  ## whose start is "whenever the mod loaded" would include the host's own boot
  ## and the game's loading screen, and averaging those into the first reading
  ## makes the first reading a lie.
  ##
  ## A window whose `source` differs from the base's is discarded rather than
  ## reported: the two counters have no common origin, so subtracting one from
  ## the other is a number with no meaning — and the switch happens for real,
  ## the first time `UnityEngine.Time` binds part-way through a run.
  result = Window(ok: false, frames: 0'i64, nanos: 0'i64, fpsMilli: 0'i64,
                  source: source)
  let now = perfCounter()
  if not gHaveBase or source != gBaseSource:
    if gHaveBase:
      # The best and worst so far were measured against a different counter.
      # Keeping them would let a "best" from the firings counter sit above every
      # honest frame rate for the rest of the session.
      gBestFpsMilli = 0
      gWorstFpsMilli = 0
      gWindows = 0
    gHaveBase = true
    gBaseSource = source
    gBaseTicks = now
    gBaseFrames = frames
    return
  let dn = nanosBetween(gBaseTicks, now)
  let df = frames - gBaseFrames
  gBaseTicks = now
  gBaseFrames = frames
  if dn <= 0 or df < 0:
    return
  result.ok = true
  result.frames = df
  result.nanos = dn
  result.fpsMilli = (df * 1000000000000'i64) div dn
  gWindows = gWindows + 1
  if gWindows == 1 or result.fpsMilli > gBestFpsMilli:
    gBestFpsMilli = result.fpsMilli
  if gWindows == 1 or result.fpsMilli < gWorstFpsMilli:
    gWorstFpsMilli = result.fpsMilli

proc windows*(): int64 = gWindows
proc bestFpsMilli*(): int64 = gBestFpsMilli
proc worstFpsMilli*(): int64 = gWorstFpsMilli

# ---------------------------------------------------------------------------
# The per-frame pump
# ---------------------------------------------------------------------------
#
# ## Where a per-frame callback comes from
#
# `hist.nim` needs one sample per frame, and `everyMain` is what supplies it:
# one callback per drain of the host's main-thread queue, on the thread the
# drain runs on.
#
# **This file used to build that chain by hand, and the comment here used to
# say that `every` "repeats on the host's own thread" and that there was no
# `everyMain`. The second half is simply out of date. The first half was never
# quite true and is the more useful correction:** on the IL2CPP client host,
# `hostSchedule` and `hostInvokeMain` feed **one** queue drained by **one**
# thread, so `every(16, ...)` does already land on the game's thread there.
# Nothing about a short `every` is off-thread on this host.
#
# The distinction that actually matters is two other things.
#
# 1. **A deadline is not a frame.** `every` fires when a wall-clock deadline
#    has passed; `everyMain` fires once per drain. At 144 fps a 16 ms timer
#    fires roughly every third frame, at 30 fps it fires once per frame and
#    drifts, and neither is the "one sample per frame" a frame-time histogram
#    is. Feeding `every`'s intervals into `hist.nim` would give a p50 of 16 ms
#    on every machine in the world, which is the shape of confident wrong
#    number this whole mod is arranged not to produce.
# 2. **The ABI only ever promised the main thread for `invoke_main`.** That the
#    two queues are one is this host's implementation, not a guarantee; the
#    backend host keeps its timers on its own thread. A mod that needs Unity's
#    thread has to ask for it by name, and `everyMain` is that name.
#
# **That the chain does not spin inside one frame is a property of the host,
# and it is stated here because this file's samples are only frame intervals if
# it holds.** `drainDue` takes the due callbacks out of `gPending` under the
# lock and runs them outside it, so a callback re-queued from inside a firing
# lands after the snapshot the current drain is walking, and is picked up by the
# next drain rather than this one. `everyMain` is now the single place that
# depends on that; this module depends on `everyMain`.
#
# It holds **one** scheduler slot, not one per firing. The hand-written chain
# called `onMainThread` again inside every firing, which claimed a fresh slot
# and released it at the end of the same firing: correct, but it churned the
# pool, and it meant `scheduledSlots()` could not tell a working chain from a
# leaking one. `everyMain` re-arms on the same cookie. `pumpMaxSlots` is how
# the self-test proves that of itself rather than citing the changelog.
#
# ## What it costs, and what can no longer be measured from here
#
# A firing is: the drain's snapshot (two seq allocations in the host, on the
# frames the queue is not empty -- which with this chain running is every
# frame), `tickTrampoline`'s `toString` on an empty slice, this handler's
# arithmetic, and then the trampoline's re-arm (`invoke_main`: a lock and a seq
# append in the host).
#
# `benchPumpBody` times this module's arithmetic in isolation and `pumpBodyNs`
# times the same arithmetic from inside a real firing. **Neither includes the
# re-arm any more, and that is a real loss of coverage rather than a saving.**
# When the chain was hand-rolled, the `onMainThread` call was inside this
# handler and inside the clock window around it, so `pumpBusyNs` -- what
# `pumpBodyNs` used to be called -- reported the whole firing at around a
# microsecond. `everyMain` re-queues after the handler returns, which is what
# makes the slot reuse possible and also puts the enqueue somewhere this module
# cannot hold a clock around. So the number this file prints got smaller
# without the work getting any cheaper -- 850-1350 ns against the stand-in with
# the enqueue inside, 350-800 ns without it, same machine, same minute -- and
# the readout says which part it is measuring and that the queue is not in it.
# Nothing here estimates the missing half.
#
# That ratio is itself worth keeping: the enqueue was about **half** of a
# firing, not nearly all of it as this file used to imply. The other half is
# two `perfCounter` reads and whatever the scheduler does to this thread
# between them, which is why the figure drifts with machine load and why the
# self-test bounds it at 5 us rather than at the several hundred nanoseconds
# it usually reads.
#
# If it ever matters, the cheaper shape is `hookTyped` on the same per-frame
# method the host detoured -- 23 ns and no allocation, `docs/PERF.md` -- at the
# price of a second trampoline on the game's hottest path, which is a trade
# this mod has declined once already and should decline again for anything less
# than a measured cost.
#
# ## What it is allowed to measure
#
# The interval between consecutive firings is a **frame** interval only when the
# host's drain method runs once per frame. Where the host reports otherwise, or
# does not report, the pump does not start: sub-frame intervals recorded into a
# frame-time histogram would produce a p99 of about zero and a confident claim
# that the game never stutters. That is the same gate, for the same reason, that
# `rateWord` puts on the word "fps".
#
# The clock is `perfCounter`, not `UnityEngine.Time`. It needs no binding, no
# runtime and no main-thread argument, so the distribution is available on every
# host on which the drain is per-frame -- including one where `Time` never
# bound. `unitySample` remains the cross-check and is unchanged.

var gPumpOn = false
var gPumpFirings: int64 = 0
var gPumpLast: int64 = 0
var gPumpHaveLast = false
var gPumpQuiet = false
var gPumpWindowFirings: int64 = 0
var gPumpMaxSlots = 0
var gPumpNs: int64 = 0
var gPumpBodyNs: int64 = 0
var gPumpWhy = ""

proc pumpTick(payload: string): string =
  ## One frame. Runs on the drain's thread -- Unity's, where the gate held.
  ##
  ## Scalars and one array store. `everyMain` re-arms this after it returns, so
  ## the re-arm is not in here any more and neither is its cost. Nothing here
  ## allocates, which the self-test checks against mimalloc's cumulative count
  ## rather than taking on trust.
  let now = perfCounter()
  if gPumpHaveLast:
    recordUs(nanosBetween(gPumpLast, now) div 1000'i64)
  gPumpLast = now
  gPumpHaveLast = true
  gPumpFirings = gPumpFirings + 1

  # The slot count, read from inside a firing because that is the only moment
  # at which a chain that claimed a slot per firing would be holding the extra
  # one. With `everyMain` this should stay flat at whatever the mod holds
  # anyway; with the hand-rolled chain it briefly held one more.
  let slots = scheduledSlots()
  if slots > gPumpMaxSlots:
    gPumpMaxSlots = slots

  # What this firing took out of the frame, accumulated -- **the recording
  # half only**, now that the re-arm happens in the library after this returns.
  # The name changed with the meaning: this used to be `gPumpBusyNs` and used
  # to include the `onMainThread` call, which was where nearly all of the cost
  # was. It is kept rather than dropped because it is still the only figure
  # taken from inside a real firing rather than from a benchmark loop, and a
  # regression in the histogram store shows up here first.
  #
  # It costs one extra `perfCounter` read, and the figure it produces includes
  # that read. Left on rather than sampled at boot and switched off, because a
  # cost that is only measured at boot is a cost nobody notices growing.
  gPumpBodyNs = gPumpBodyNs + nanosBetween(now, perfCounter())
  result = ""

proc startPump*(mt: MainThreadInfo; why: var string): bool =
  ## Arms the chain, if and only if one firing of the drain is one frame.
  why = ""
  if gPumpOn:
    return true
  if not mt.ok:
    why = "the host did not answer aowlspt.host::main_thread"
    return false
  if not mt.bound:
    why = "the host's drain is not Unity's thread, so the interval between " &
          "its firings is not a frame interval"
    return false
  if not mt.perFrameKnown:
    why = "this host does not report whether " &
          (if mt.methodName.len > 0: mt.methodName else: "its drain method") &
          " runs once per frame, and an absent answer is unknown rather " &
          "than yes; a newer host answers it"
    return false
  if not mt.perFrame:
    why = "the host reports that " & mt.methodName & " runs more than once a " &
          "frame, so the interval between its firings is not a frame interval"
    return false
  gPumpHaveLast = false
  gPumpQuiet = false
  gPumpWindowFirings = gPumpFirings
  if everyMain(pumpTick) != Ok:
    why = "the host refused to queue a main-thread callback"
    return false
  gPumpOn = true
  gPumpWhy = "armed on " & mt.methodName
  result = true

proc stopPump*() =
  ## Asks the chain not to re-arm.
  ##
  ## `stopMainRepeats` clears the repeat marker; the firing already queued runs
  ## one more time and then releases its slot instead of re-arming. That is the
  ## same lifetime the hand-rolled chain's stop flag gave, and for the same
  ## reason: the chain is queued on the game's thread and this is called from
  ## the host's, so yanking the slot out from under a callback that is about to
  ## run is the one thing that could turn a stop into a crash.
  discard stopMainRepeats()
  gPumpOn = false

proc pumpOn*(): bool = gPumpOn
proc pumpFirings*(): int64 = gPumpFirings
proc pumpMaxSlots*(): int = gPumpMaxSlots
proc pumpNs*(): int64 = gPumpNs
proc pumpWhy*(): string = gPumpWhy
proc pumpQuiet*(): bool = gPumpQuiet

proc chainWentQuiet*(armed: bool; firingsNow, firingsAtLastWindow: int64): bool =
  ## Whether a chain that **was** working has stopped.
  ##
  ## This replaces a check that the hand-rolled chain could make and `everyMain`
  ## cannot hand back: the old pump called `onMainThread` itself, saw the
  ## refusal, and set a flag. `everyMain` re-arms inside the library, and when
  ## the host refuses it releases the slot and returns to a host that is not
  ## this mod -- so nothing is told. What is still visible from here is the
  ## consequence: a whole readout window during which a chain that had been
  ## firing did not fire once.
  ##
  ## That is strictly more than the flag caught. The flag saw one failure mode,
  ## the host refusing to enqueue; this also sees a drain that went silent, a
  ## detour that was removed, and a game that stopped rendering -- all of which
  ## used to look like a healthy sampler whose distribution had quietly stopped
  ## growing.
  ##
  ## `firingsAtLastWindow > 0` is the guard that keeps it from firing on a chain
  ## that has only just armed: "armed and has never fired" is a different bug
  ## with its own check in the self-test, and reporting it here would mean
  ## reporting it on every boot in the gap between arming and the first drain.
  result = armed and firingsAtLastWindow > 0'i64 and
           firingsNow == firingsAtLastWindow

proc notePumpWindow*() =
  ## Called once per readout window. Latches `pumpQuiet` when the chain that had
  ## been firing stopped, and remembers the count for the next window.
  if chainWentQuiet(gPumpOn, gPumpFirings, gPumpWindowFirings):
    gPumpQuiet = true
    gPumpOn = false
  gPumpWindowFirings = gPumpFirings

proc pumpBodyNs*(): int64 =
  ## Mean nanoseconds spent in **this module's half** of a firing, over every
  ## firing so far: the clock read, the interval, the histogram store, the slot
  ## read, and the second clock read that measures them.
  ##
  ## It is deliberately not called the cost of a firing any more. Two pieces
  ## are outside it and both are larger:
  ##
  ## * the re-arm -- `everyMain`'s `invoke_main`, a lock and a seq append in the
  ##   host -- which happens in the library's trampoline after this handler has
  ##   returned, and which this module used to time because it made the call
  ##   itself;
  ## * the host's own drain overhead, two seq allocations in `drainDue` on any
  ##   frame the queue is not empty, which with this chain running is every
  ##   frame.
  ##
  ## Both are real, both are in another tree, and nothing in this mod can time
  ## either from here. Say "not measured" about them rather than folding a
  ## guess into this number.
  if gPumpFirings <= 0: return 0
  result = gPumpBodyNs div gPumpFirings

proc benchPumpBody*(iterations: int): int64 =
  ## Nanoseconds per call of the pump's **recording half**, in isolation.
  ##
  ## Deliberately not the whole firing: the queueing half crosses the host ABI
  ## and can only be timed by letting the host actually run it, which is what
  ## `pumpFirings` against wall clock measures in the live run. What this number
  ## isolates is the part that is this module's to be fast -- the clock read,
  ## the subtraction and the histogram store -- so that a regression in the
  ## histogram is not hidden inside the cost of a lock in another tree.
  ##
  ## The samples it takes are intervals between two adjacent clock reads, which
  ## are not frames and must never be reported as any — so the real
  ## distribution is snapshotted, the benchmark runs into a cleared one, and the
  ## snapshot is put back with its epoch intact. That is 4 KB copied twice per
  ## run and is the difference between a benchmark and a benchmark that quietly
  ## restarts the session's statistics every time it runs.
  if iterations <= 0:
    return 0
  saveHist()
  resetHist()
  let t0 = perfCounter()
  var i = 0
  var last = t0
  while i < iterations:
    let now = perfCounter()
    recordUs(nanosBetween(last, now) div 1000'i64)
    last = now
    inc i
  let t1 = perfCounter()
  gPumpNs = nanosBetween(t0, t1) div int64(iterations)
  restoreSavedHist()
  result = gPumpNs
