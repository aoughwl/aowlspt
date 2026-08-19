## aowl.perf — engine-level performance settings for post-1.0 Tarkov.
##
##     aowl build-mod mods/perf
##     aowl run mods/perf
##
## ---------------------------------------------------------------------------
## READ THIS FIRST
## ---------------------------------------------------------------------------
##
## **Nothing in this mod has ever run against BSG's client.** Every type name,
## every property name, every assumption about what is present in the shipped
## `global-metadata.dat` is a *guess* until the runtime answers it. Post-1.0
## Tarkov is IL2CPP with managed code stripping on, and a Unity property setter
## that no code in the game calls can be absent from the build entirely — so
## "UnityEngine.QualitySettings has a shadowDistance setter" is a hypothesis
## here, not a fact.
##
## Everything in this mod is therefore written to the same shape:
##
##   * resolve **by name**, at runtime, on the first tick the type exists;
##   * **refuse cleanly** when the name is absent, and record what was asked
##     for and what the runtime said;
##   * **log the refusal** — once — so a setting that quietly did nothing is
##     distinguishable from a setting that did nothing quietly;
##   * **never crash the game**: no value is written that was not first read
##     back, nothing is written at all from a thread the host has not confirmed
##     is Unity's, and no name is dereferenced that the runtime did not hand
##     over.
##
## The numbers in the readout are real measurements. The claim that any
## particular knob makes Tarkov faster is not: it has never been measured
## against Tarkov, only against a stand-in runtime that answers the same C API.
##
## ---------------------------------------------------------------------------
## WHAT IT DOES
## ---------------------------------------------------------------------------
##
## Two halves, and the second is the one that makes the first checkable.
##
## **`knobs.nim` — engine settings.** A table of 23 Unity settings across
## `QualitySettings`, `Application` and `Time`, each one reversible and each one
## off until `config.json` turns it on. Applied through `aowlspt/game`'s boxed
## path, which is exactly the right budget for something that happens twice in a
## session — **including the enum-valued ones**, which it could not express when
## this mod was written and can now: the host binds an enum argument from a
## number and unboxes an enum return as one, both at the payload width the
## runtime reports. The `bindMethodAs` route past that is still here as a
## fallback for an older host, entered on the shape of the answer rather than on
## a version number, and a knob that used it says so. Every knob reads its
## original first, writes, and reads back — and so does the *restore*, which is
## new: the engine clamps, and a restore that only checked the setter for an
## error was making exactly the claim the apply path refuses to make.
##
## **`frame.nim` — the readout.** Mean frames per second over a window, and it
## now says which counter produced the number and where that verdict came
## from. The host's drain counter is a frame count only when the method the
## host detoured runs once per frame, and its last-resort candidate,
## `UnityEngine.Time::get_deltaTime`, does not. **The host answers this**:
## `aowlspt.host::main_thread` carries `perFrame` beside `frames`, recorded
## where the choice of method is made. This file kept a whitelist of method
## names until it did, which worked and was the wrong place for it — a
## mod-side list of host-side names has to be edited every time the host's is.
## A host too old to answer omits the key and that means *unknown*, not true,
## so the readout says "drain firings/s" and names which kind of not-knowing
## it is. Where `hud.readUnityTime` is on and `Time::get_frameCount` bound,
## that is used instead — a frame count by definition rather than by report,
## at one bound call a window.
##
## **`perf.nim` — and one line of it is worth naming.** The mod prints what host
## it is talking to, in capabilities rather than in a version string, before it
## prints a single refusal — and remembers that fingerprint in its own store, so
## a run against a different host than the last one says so outright. That line
## exists because this mod's own enum refusal outlived the gap it described, and
## went on being reproduced against a test stage holding a host DLL two hours
## older than the one being built. A refusal is evidence about the host that
## produced it and about no other, and the log now says which host that was.
##
## **What it deliberately does not do.** `Physics.autoSyncTransforms` and the
## solver iteration counts are read and reported and never written: all three
## change what a physics query answers, and a mod that changes what a bullet
## hits is not a graphics setting however it is spelled. Same line for anything
## culling-shaped: this mod does not touch camera far planes, layer culling
## distances, occlusion or LOD *culling* thresholds, because making something
## visible that the game meant to hide is the one direction that is not a
## performance change at all.
##
## ---------------------------------------------------------------------------
## WHAT THE API COULD NOT EXPRESS
## ---------------------------------------------------------------------------
##
## Four of the five things this section used to list have been fixed in the
## host since it was written. They are kept here rather than deleted, with what
## happened, because a list of gaps that only ever grows is a list nobody
## believes.
##
## * **An enum *return* on the boxed path — CLOSED.** `describeResult` unboxes
##   a small value type by the payload width the runtime reports now, so
##   `get("anisotropicFiltering")` answers `1` rather than
##   `{"handle":6,"type":"System.Int32"}`. That closes the failure shape this
##   section was written about: `asFloat()` on the old answer was 0.0 with `ok`
##   true, a plausible number rather than a refusal, and it leaked a GC handle
##   per read. The self-test still runs the experiment every run and reports the
##   verdict, and `readOne` still falls back to `bindMethodAs(..., [], fkI32)`
##   when it sees the old shape — chosen on the shape rather than on a version,
##   because a version number is a claim and the shape is the fact.
##
##   `aowlspt/fast`'s `classifyType` still refuses an enum, and is right to:
##   `findClass` plus `classIsValueType` cannot tell a byte enum from a long
##   one. The boxed path can, because it asks for the width.
##
## * **A repeating main-thread callback — HALF CLOSED, and the half that
##   mattered.** `onMainThread` is still one-shot; there is still no `everyMain`.
##   But it no longer leaks: `claimTick` reuses a freed slot and
##   `tickTrampoline` releases a one-shot's slot after it fires, so queueing
##   work every frame costs one slot at a time rather than one per frame. The
##   reason this mod samples off-thread is now purely that it does not need to be
##   on Unity's thread to read a counter, not that looping would leak.
##
## * **An allocation-free per-frame callback — CLOSED.** `hookTyped` /
##   `hookReturnTyped` (ABI revision 4) hand a handler the saved registers
##   rather than JSON: about 24 ns a firing against 650, and measured at zero
##   allocations in the mod and zero payload bytes in the host over 20,000
##   firings. The old sentence about `patchTrampoline` calling `toString` on two
##   slices is still true of the *JSON* hooks and no longer true of the ABI.
##
##   This mod still installs no hooks, and the reason is now a small one rather
##   than a refusal: the only method it would want is the per-frame method the
##   host's own drain is already detoured onto, and a second detour there — for
##   a readout — is not a trade worth making when the drain's counter answers
##   the same question for nothing. If a frame-time *distribution* is ever
##   wanted rather than a mean, `hookTyped` is the shape, and what it costs is a
##   patch slot and a second trampoline on the game's hottest path.
##
## * **A postfix hook — available, and deliberately not used.** `hookReturn`
##   exists and can adjust what a game method answers. It is 418 ns to watch a
##   return value and 2245 ns to also read the arguments and replace the result,
##   because the payload crosses as JSON; `hookReturnTyped` is 80 ns for the
##   same work. Nothing this mod does wants one: a setting is written twice in a
##   session, not adjusted per call, and a postfix that held a `QualitySettings`
##   property against the game's own settings menu would be fighting the player
##   rather than the frame time.
##
## * **A way to prove an allocation count — CLOSED, and not used here.**
##   `allocationCount()` and `allocProbeOk()` are exported from `aowlspt/fast`
##   and read mimalloc's cumulative block count in the calling binary; the host
##   answers `call("aowlspt.host::patch_stats")` with `payloadBytes` and
##   `handlesTaken`. Both would make this mod's allocation claim direct rather
##   than indirect. `benchUnitySample`'s nanoseconds-per-call is kept because
##   the thing being bounded is a *bound call path* whose cost is the claim, and
##   10 ns per call over 200,000 calls says both things at once; the counter is
##   the right tool for a hook, which this mod does not have.
##
## * **IL2CPP's garbage collector — still nothing, and still the right answer.**
##   IL2CPP uses Boehm, `System.GC`'s managed surface is a thin shim over it,
##   and `GCSettings.LatencyMode` is a no-op there. `GC.Collect` *is* reachable
##   by name and this mod will not call it — a forced collection is a stutter,
##   which is the opposite of the job.
##
## And one that was a gap when this list was last revised, closed since:
##
## * **`aowlspt.host::main_thread` did not say whether `frames` counted
##   frames — CLOSED.** It answers `perFrame` now, from the host's own
##   candidate table rather than from anything a mod re-derives, and the host
##   logs the caveat when it binds the last resort. `frame.nim`'s whitelist of
##   method names is gone; what is left is reading the key, and treating its
##   absence on an older host as unknown rather than as true.
##
## ---------------------------------------------------------------------------
## HOW YOU KNOW IT WORKED
## ---------------------------------------------------------------------------
##
## `aowl run mods/perf` runs the simulator self-test: the table's integrity, the
## config, the window arithmetic, the drain-method classification that decides
## whether the readout may say "fps", and — with no runtime in the process at
## all — that every knob refuses rather than crashes, that nothing is reported
## as applied, and that the revert path with nothing applied returns at once
## rather than blocking for its whole wait budget.
##
## Against `tests/mockil2cpp` the same mod resolves the knobs that exist there,
## refuses the ones that do not, observes the engine clamping `shadowCascades`,
## reads its one enum knob through the boxed getter and cross-checks it against
## the asserted binding, applies and restores, **queues a restore onto the
## game's thread and blocks until it has run**, and measures its own sample
## path.

import std/strutils
import aowlspt
import aowlspt/game
import aowlspt/json
import aowlspt/fast
import knobs
import frame
import hist

const
  ModGuid = "aowl.perf"
  ModName = "aowl.perf"
  ModAuthor = "savannt"
  ModVersion = "1.0.0"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

type
  Settings = object
    enabled: bool
    requireMainThread: bool
    restoreOnUnload: bool
    hudEnabled: bool
    hudIntervalMs: int
    hudReadUnityTime: bool
    selfTest: bool
    benchIterations: int
    verbose: bool
    restoreWaitMs: int
    hudFrameTimes: bool
    hudHitchMs: int

proc defaultSettings(): Settings =
  ## A template's worth of literal, written as a proc that is only ever called
  ## from inside another proc — never as a global initialiser, where a nimony
  ## `--app:lib` build would skip it and leave the global zeroed.
  Settings(enabled: true, requireMainThread: true, restoreOnUnload: true,
           hudEnabled: true, hudIntervalMs: 1000, hudReadUnityTime: false,
           selfTest: true, benchIterations: 200000, verbose: false,
           restoreWaitMs: 2000, hudFrameTimes: true, hudHitchMs: 50)

var gCfg = Settings(enabled: true, requireMainThread: true,
                    restoreOnUnload: true, hudEnabled: true,
                    hudIntervalMs: 1000, hudReadUnityTime: false,
                    selfTest: true, benchIterations: 200000, verbose: false,
                    restoreWaitMs: 2000, hudFrameTimes: true, hudHitchMs: 50)

var gConfigText = ""
var gMissing = 0

proc flag(path: string; default: bool): bool =
  let j = field(gConfigText, path)
  if not j.exists:
    inc gMissing
    return default
  result = asBool(j, default)

proc count(path: string; default: int): int =
  let j = field(gConfigText, path)
  if not j.exists:
    inc gMissing
    return default
  result = asInt(j, default)

proc loadConfig() =
  gCfg = defaultSettings()
  gMissing = 0
  var raw = ""
  let empty = ""
  if configGet(empty, raw) != Ok or raw.len == 0:
    warn "perf  config.json could not be read; every knob stays off"
    gConfigText = ""
    return
  gConfigText = raw
  gCfg.enabled = flag("general.enabled", gCfg.enabled)
  gCfg.requireMainThread = flag("general.requireMainThread",
                                gCfg.requireMainThread)
  gCfg.restoreOnUnload = flag("general.restoreOnUnload", gCfg.restoreOnUnload)
  gCfg.restoreWaitMs = count("general.restoreWaitMs", gCfg.restoreWaitMs)
  gCfg.verbose = flag("general.verbose", gCfg.verbose)
  gCfg.hudEnabled = flag("hud.enabled", gCfg.hudEnabled)
  gCfg.hudIntervalMs = count("hud.intervalMs", gCfg.hudIntervalMs)
  gCfg.hudReadUnityTime = flag("hud.readUnityTime", gCfg.hudReadUnityTime)
  gCfg.hudFrameTimes = flag("hud.frameTimes", gCfg.hudFrameTimes)
  gCfg.hudHitchMs = count("hud.hitchMs", gCfg.hudHitchMs)
  setHitchUs(int64(gCfg.hudHitchMs) * 1000'i64)
  gCfg.selfTest = flag("selftest.enabled", gCfg.selfTest)
  gCfg.benchIterations = count("selftest.benchIterations",
                               gCfg.benchIterations)
  readKnobConfig(gConfigText, gMissing)

# ---------------------------------------------------------------------------
# Formatting
# ---------------------------------------------------------------------------

proc f3(v: float): string =
  ## Three decimal places. `$` on a float prints the full repr, which for a
  ## readout of a dozen numbers a line is unreadable.
  var neg = false
  var x = v
  if x < 0.0:
    neg = true
    x = -x
  if x > 1.0e15:
    return "big"
  let scaled = int(x * 1000.0 + 0.5)
  let whole = scaled div 1000
  let fracv = scaled mod 1000
  var f = $fracv
  while f.len < 3:
    f = "0" & f
  result = (if neg: "-" else: "") & $whole & "." & f

proc milli(v: int64): string =
  ## An x1000 fixed-point integer as a decimal. Used for frames per second,
  ## which is computed in integer arithmetic so that a sample path that must not
  ## allocate does not have to touch a float formatter.
  var neg = false
  var x = v
  if x < 0:
    neg = true
    x = -x
  let whole = x div 1000
  let fracv = x mod 1000
  var f = $fracv
  while f.len < 3:
    f = "0" & f
  result = (if neg: "-" else: "") & $whole & "." & f

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

var gTicks = 0
var gStarted = false
var gApplyRequested = false
var gApplyDone = false
var gApplyRefusedWhy = ""
var gLastHudMs = 0'i64
var gAppliedCount = 0
var gSelfTestDone = false
var gSaidUnity = false
var gDevice = ""
var gFrameSource = srcNone
var gSaidSource = false
var gAppliedOffThread = false
  ## Whether the apply pass ran somewhere the host had not confirmed was
  ## Unity's thread. Only possible with `general.requireMainThread` false, and
  ## it decides how the restore is done: a setting written from a worker thread
  ## can be put back from one, and queueing that restore onto a drain that was
  ## never Unity's is ceremony rather than safety.

var gPumpTried = false
var gPumpArmedMs: int64 = 0
var gPumpArmedFirings: int64 = 0
  ## Wall clock and firing count at the moment the chain armed. The self-test
  ## divides one by the other; taking them at arm time rather than at load
  ## keeps the host's boot and the game's loading screen out of the average.

var gLastFpsMilli: int64 = 0
  ## The last window's rate, kept so the self-test can cross-check the
  ## histogram's median against it. Two independent measurements of the frame
  ## interval that disagree by a factor of two would mean the pump is not
  ## firing once a frame, and nothing else in this mod would notice.

var gPumpWhyNot = ""
  ## Why the per-frame distribution is unavailable, when it is. Kept rather
  ## than only logged: the self-test reports it, and "no distribution" with a
  ## reason and "no distribution" without one are different bugs.

var gRestoreRuns = 0
  ## Incremented by `restoreOnMainThread` — on the *drain's* thread. Read by
  ## `awaitRestore` on the host's, which is why every read there is separated by
  ## a call across the host ABI: an opaque call is the barrier that keeps the
  ## compiler from hoisting the load out of the wait loop.

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# What am I talking to?
# ---------------------------------------------------------------------------
#
# This exists because of a mistake this mod made about itself.
#
# Every refusal in `knobs.nim` is recorded honestly, and one of them stopped
# being true without anything here noticing: the host learned to unbox an enum
# return as a number, and this mod went on reading `{"handle":6,...}` and
# reporting the capability as missing. Not because the refusal was written
# carelessly -- it was correct when it was recorded, and it stayed correct
# against the host DLL sitting in the test stage, which was two hours older than
# the one in `host/`. A refusal is evidence about *the host it was recorded
# against*, and nothing in the log said which host that was. Two hours of
# re-deriving a conclusion that a single printed line would have settled.
#
# So: print the line. And keep the previous one, so the mod can say outright
# when the thing it is talking to is not the thing its refusals were recorded
# against.
#
# The fingerprint is deliberately made of *capabilities* rather than a version
# string. A version tells you what the host calls itself; capabilities tell you
# what it will do, which is the thing a refusal is about. All five are answers
# the host gives, and four of the five are exactly the answers that have changed
# under this mod at some point.

proc hostFingerprint(): string =
  var mt = mainThreadInfo()
  result = "{\"host\":\"" & hostName() &
           "\",\"version\":\"" & hostVersion() &
           "\",\"apiSize\":" & $hostApiSize() &
           ",\"store\":" & (if storeReady(): "true" else: "false") &
           ",\"livePointers\":" & (if livePointersReady(): "true" else: "false") &
           ",\"typedPatches\":" & (if typedPatchesReady(): "true" else: "false") &
           ",\"perFrameReported\":" &
           (if mt.perFrameKnown: "true" else: "false") & "}"

proc describeHost(): string =
  var mt = mainThreadInfo()
  result = hostName() & " " & hostVersion() & ", host API size " &
           $hostApiSize() & " (mod built against " & $expectedApiSize() &
           "), store " & (if storeReady(): "yes" else: "no") &
           ", live pointers " & (if livePointersReady(): "yes" else: "no") &
           ", typed patches " & (if typedPatchesReady(): "yes" else: "no") &
           ", perFrame reported " & (if mt.perFrameKnown: "yes" else: "no")

proc reportHostIdentity() =
  ## Logged once per run, before any refusal is. The order matters: a reader
  ## scrolling to the first refusal should already know what answered it.
  info "perf  talking to " & describeHost()
  if not storeReady():
    info "perf  this host has no store, so the mod cannot compare this run " &
         "with the last one; read the line above before trusting a refusal " &
         "recorded earlier"
    return
  let now = hostFingerprint()
  var was = ""
  if storeGet("perf.lastHost", was) != Ok or was.len == 0:
    info "perf  first run recorded against this host"
  elif was != now:
    # The whole point of the exercise.
    warn "perf  THIS IS A DIFFERENT HOST from the one the last run recorded " &
         "its refusals against. Every REFUSED line below is evidence about " &
         "this host and about no other, and any refusal you remember from a " &
         "previous run is not evidence about this one."
    warn "perf  was: " & was
    warn "perf  now: " & now
  discard storeSet("perf.lastHost", now)

proc knobLine(i: int): string =
  let k = knobAt(i)
  var s = "perf  " & k.section & "." & k.key & " [" & kindName(k.kind) & "] "
  if not gState[i].apply:
    return s & "off"
  if gState[i].applied:
    s = s & "applied " & f3(gState[i].orig) & " -> " & f3(gState[i].have)
    if gState[i].prop != k.prop:
      s = s & " (via " & k.prop & "'s alias " & gState[i].prop & ")"
    if gState[i].viaAssertion:
      s = s & " (through an asserted int32 binding, not the host's own " &
          "metadata — this host reports an enum as a handle)"
    if not gState[i].exact:
      s = s & "  [asked for " & f3(gState[i].want) & "; " & gState[i].why & "]"
    return s
  result = s & "REFUSED: " & (if gState[i].why.len > 0: gState[i].why
                              else: "no reason recorded")

proc reportKnobs() =
  var i = 0
  var off = 0
  while i < KnobCount:
    if gState[i].apply:
      info knobLine(i)
    else:
      inc off
    inc i
  info "perf  " & $appliedCount() & " applied, " & $refusedCount() &
       " refused, " & $off & " not enabled"

proc reportReadOnly() =
  ## The settings this mod reads and refuses to write. Logged because a number
  ## nobody can see is a number nobody can act on, and because the refusal is a
  ## design decision that should be visible rather than implied by absence.
  var i = 0
  while i < ReportCount:
    let k = reportAt(i)
    var value = 0.0
    var why = ""
    if readReport(i, value, why):
      info "perf  read-only  " & k.key & " = " & f3(value)
    else:
      info "perf  read-only  " & k.key & " unavailable (" & why & ")"
    inc i
  info "perf  the three Physics readings above are deliberately never " &
       "written: each changes what a physics query answers"

proc usMs(us: int64): string =
  ## Microseconds as milliseconds to three places. The histogram is integer
  ## microseconds throughout; this is the only place it becomes text.
  milli(us)

proc distributionLine() =
  ## The half of the readout a mean cannot give.
  ##
  ## Printed only when there is enough to say something. A percentile over a
  ## handful of samples is the maximum wearing a different name, so below a
  ## floor this says how many samples it has and nothing else — the alternative
  ## is a p99.9 computed from thirty frames, which is a number with a decimal
  ## point and no meaning.
  if not gCfg.hudFrameTimes:
    return
  if not pumpOn() and histCount() == 0:
    return
  let n = histCount()
  if n < 120:
    info "perf  frame times: " & $n & " sample(s) so far; percentiles need " &
         "at least 120 before they mean anything"
    return
  let p50 = percentile(50000'i64)
  let p99 = percentile(99000'i64)
  var s = "perf  frame time p50 " & usMs(p50.us) & " ms  p99 " &
          usMs(p99.us) & (if p99.fromTail: "+ ms" else: " ms")
  # p99.9 is only printed once a thousand samples exist. Below that its rank
  # rounds up to the largest sample, so it would be the maximum printed twice
  # under two different names — and the second name implies a distribution the
  # sample count cannot support. At 60 fps a thousand frames is seventeen
  # seconds, so this appears on its own shortly after the rest.
  if n >= 1000'i64:
    let p999 = percentile(99900'i64)
    s = s & "  p99.9 " & usMs(p999.us) &
        (if p999.fromTail: "+ ms" else: " ms")
  s = s & "  worst " & usMs(histMaxUs()) & " ms  (" & $n & " frames"
  if histHitches() > 0:
    s = s & ", " & $histHitches() & " over " & $(hitchUs() div 1000'i64) &
        " ms"
  s = s & ")"
  info s
  let ratio = stutterRatioMilli()
  if ratio > 0:
    info "perf  pacing p99/p50 " & milli(ratio) &
         "  (1.000 is perfectly even; the further above, the more the " &
         "stutter a mean cannot see)"
  if histTail() > 0:
    # Said out loud rather than folded into a percentile, because a percentile
    # that landed here is a bucket edge and the tail is exact.
    info "perf  " & $histTail() & " frame(s) exceeded the histogram's top (" &
         $(int64(HistTopUs) div 1000'i64) & " ms); the worst above is exact " &
         "at " & usMs(histMaxUs()) & " ms, the percentiles above it are not"

proc pumpLine() =
  ## What the distribution costs to collect. Printed beside it on purpose: an
  ## instrument that does not say what it costs is one nobody can decide to
  ## turn off.
  if not gCfg.hudFrameTimes:
    return
  # Before the readout, not after: this is the one place in the mod that runs
  # exactly once per readout window, which is what `chainWentQuiet` measures
  # against.
  notePumpWindow()
  if not pumpOn():
    if pumpQuiet():
      warn "perf  the per-frame sampler stopped after " & $pumpFirings() &
           " firing(s): a whole readout window passed without one. Either " &
           "the host stopped re-queueing it or the drain went silent — " &
           "`everyMain` re-arms inside the library, so which of the two it " &
           "was is not visible from here. The distribution above has stopped " &
           "growing and describes only what came before."
    elif pumpWhy().len > 0:
      discard
    return
  info "perf  per-frame sampler: " & $pumpFirings() & " firing(s), " &
       $pumpBodyNs() & " ns of each spent in this mod (of which " & $pumpNs() &
       " ns is the recording); the re-arm and the host's drain are NOT in " &
       "that figure, " & $pumpMaxSlots() & " scheduler slot(s) at peak"

var gCrossChecked = false

proc crossCheckMedian(w: Window) =
  ## The check that says the pump is sampling **frames** and not something else.
  ##
  ## Two independent measurements of one quantity. The window divides the host's
  ## drain counter by wall clock; the histogram is the median of intervals the
  ## pump timed for itself with a different clock read at a different place in
  ## the frame. If the chain were firing twice a frame, or every other frame,
  ## these would disagree by a factor of two and **nothing else in this mod
  ## would notice** — every percentile would still look like a frame time, in
  ## milliseconds, with a decimal point on it.
  ##
  ## Deferred out of `clientSelfTest` rather than run there, because the
  ## self-test fires after two windows and a median needs more samples than two
  ## windows hold. A check that reports "not enough samples" every run is a
  ## check that never runs.
  ##
  ## The band is wide (0.6x to 1.7x) on purpose: the two are not measuring quite
  ## the same thing. A median is not a mean, and the window's mean is dragged up
  ## by exactly the slow frames this histogram exists to separate out — so the
  ## median is expected to sit *below* the implied interval, and does. The band
  ## is sized to catch a factor of two, which is the failure that matters, and
  ## not to police the difference between a mean and a median.
  if gCrossChecked or not gCfg.hudFrameTimes or not pumpOn():
    return
  if histCount() < 400'i64 or w.fpsMilli <= 0'i64:
    return
  gCrossChecked = true
  let p50 = percentile(50000'i64)
  let impliedUs = 1000000000'i64 div w.fpsMilli
  let lo = (impliedUs * 60'i64) div 100'i64
  let hi = (impliedUs * 170'i64) div 100'i64
  if p50.ok and p50.us >= lo and p50.us <= hi:
    success "selftest  the sampler's median frame interval (" &
            milli(p50.us) & " ms) agrees with the " & milli(w.fpsMilli) &
            " " & rateWord(w.source) & " the window measured (" &
            milli(impliedUs) & " ms implied), over " & $histCount() &
            " samples — so one firing of the chain is one frame"
  else:
    error "selftest  the sampler's median frame interval is " &
          milli(p50.us) & " ms but the window's " & milli(w.fpsMilli) & " " &
          rateWord(w.source) & " implies " & milli(impliedUs) &
          " ms. A factor of two here means the chain fires twice a frame or " &
          "every other frame, and every percentile above is wrong by that " &
          "factor. Treat the distribution as unreliable until this agrees."

proc hudLine(w: Window) =
  var s = "perf  " & milli(w.fpsMilli) & " " & rateWord(w.source) & " over " &
          $(w.nanos div 1000000'i64) & " ms (" & $w.frames &
          (if countsFrames(w.source): " frames)" else: " firings)")
  if windows() > 1:
    s = s & "  best " & milli(bestFpsMilli()) & "  worst " &
        milli(worstFpsMilli())
  info s
  gLastFpsMilli = w.fpsMilli
  if unityBound() and unitySamples() > 0:
    info "perf  Unity cross-check: frame " & $unityFrames() &
         ", deltaTime " & $unityDeltaUs() & " us (best " & $unityBestUs() &
         ", mean " & $unityMeanUs() & ", worst " & $unityWorstUs() &
         ")"
    if unitySampleNs() > 0:
      info "perf  the sample path costs " & $unitySampleNs() &
           " ns/call, measured over " & $gCfg.benchIterations & " calls"
  distributionLine()
  pumpLine()
  crossCheckMedian(w)

proc publish(w: Window) =
  ## The last window, for anything else that wants it — an overlay, another
  ## mod, or a human reading `store/aowl.perf/`.
  if not storeReady():
    return
  let payload = "{\"fpsMilli\":" & $w.fpsMilli &
                ",\"frames\":" & $w.frames &
                ",\"nanos\":" & $w.nanos &
                ",\"source\":\"" & sourceName(w.source) & "\"" &
                ",\"isFrameRate\":" &
                (if countsFrames(w.source): "true" else: "false") &
                ",\"applied\":" & $appliedCount() &
                ",\"refused\":" & $refusedCount() & "}"
  discard storeSet("perf.lastWindow", payload)

  # The distribution goes out separately, and only when it is worth reading.
  # An overlay that plotted a p99 computed from thirty samples would be drawing
  # noise at three decimal places; `samples` is published beside every figure so
  # a consumer can apply the same floor rather than trusting the numbers blind.
  if not gCfg.hudFrameTimes or histCount() <= 0:
    return
  let p50 = percentile(50000'i64)
  let p99 = percentile(99000'i64)
  let p999 = percentile(99900'i64)
  # Published whatever the sample count, unlike the log line, because a
  # consumer gets `samples` beside it and can apply its own floor. What it must
  # not do is get a number with no way to tell how much of one it is.
  let dist = "{\"samples\":" & $histCount() &
             ",\"epoch\":" & $histEpoch() &
             ",\"meanUs\":" & $histMeanUs() &
             ",\"minUs\":" & $histMinUs() &
             ",\"maxUs\":" & $histMaxUs() &
             ",\"p50Us\":" & $p50.us &
             ",\"p99Us\":" & $p99.us &
             ",\"p999Us\":" & $p999.us &
             ",\"p99FromTail\":" & (if p99.fromTail: "true" else: "false") &
             ",\"p999FromTail\":" & (if p999.fromTail: "true" else: "false") &
             ",\"aboveHistogramTop\":" & $histTail() &
             ",\"hitches\":" & $histHitches() &
             ",\"hitchUs\":" & $hitchUs() &
             ",\"pacingMilli\":" & $stutterRatioMilli() &
             ",\"samplerOn\":" & (if pumpOn(): "true" else: "false") &
             ",\"samplerNs\":" & $pumpNs() & "}"
  discard storeSet("perf.frameTimes", dist)

# ---------------------------------------------------------------------------
# Applying, on the right thread
# ---------------------------------------------------------------------------

proc applyOnMainThread(payload: string): string =
  ## Runs inside the host's main-thread drain, which is Unity's own thread when
  ## the host managed to detour a per-frame method. Writing a `QualitySettings`
  ## property from anywhere else is the crash this gate exists to avoid.
  gAppliedCount = applyAll()
  gApplyDone = true
  success "perf  applied " & $gAppliedCount & " of " &
          $(appliedCount() + refusedCount()) & " requested settings"
  reportKnobs()
  # The distribution collected before this describes the settings that were in
  # force before this. Keeping it would average two configurations together and
  # report the result as though it were one, which is exactly the comparison
  # anyone reading these percentiles is trying to make.
  if gAppliedCount > 0:
    resetHist()
    info "perf  frame-time distribution reset: the settings it was measuring " &
         "have changed"
  result = ""

proc restoreOnMainThread(payload: string): string =
  let n = restoreAll()
  gRestoreRuns = gRestoreRuns + 1
  info "perf  restored " & $n & " setting(s) to the values they had"
  if n > 0:
    # Same reason as the apply side: what is being measured has changed. This
    # is also the second half of an A/B — apply, fill, read; restore, fill,
    # read — and it only works because neither half inherits the other's tail.
    resetHist()
  var stuck = 0
  var i = 0
  while i < KnobCount:
    if gState[i].applied: inc stuck
    inc i
  if stuck > 0:
    warn "perf  " & $stuck & " setting(s) could not be put back; the " &
         "per-knob lines say which"
  result = ""

proc requestApply() =
  if gApplyRequested:
    return
  let mt = mainThreadInfo()
  if gCfg.requireMainThread and not mt.bound:
    # Not an error yet: the drain hook reports `bound` only once it has
    # actually fired, so early in a run this is "not yet" rather than "never".
    gApplyRefusedWhy = "the host has not confirmed a Unity main thread" &
                       (if mt.methodName.len > 0:
                          " (drain method " & mt.methodName & ")"
                        else: " (no drain method bound)")
    return
  gApplyRequested = true
  gAppliedOffThread = not mt.bound
  if not mt.bound:
    warn "perf  general.requireMainThread is off and the host's drain is " &
         "not Unity's thread; the settings below are being written from a " &
         "worker thread, which Unity does not support"
  discard onMainThread(applyOnMainThread)

# ---------------------------------------------------------------------------
# Putting it back, and knowing whether that happened
# ---------------------------------------------------------------------------

proc awaitRestore(runsWanted: int; budgetMs: int; drainMoved: var bool): bool =
  ## Blocks the host's thread until the drain has run the queued restore, or
  ## the budget runs out.
  ##
  ## **Why blocking is the right answer here.** `onUnload` is the last moment
  ## this mod's code is mapped. The host runs it, then `dropModRegistrations`
  ## removes every callback this mod still has queued — under the queue's own
  ## lock, so it is not a race — and then frees the library. A restore that has
  ## not drained by the time `onUnload` returns therefore never runs at all.
  ## Queueing it and hoping was the old behaviour, and "hoping" is exactly the
  ## word: the queued callback was dropped a few microseconds later, every time,
  ## unless a frame happened to land in the gap.
  ##
  ## **Why it cannot deadlock.** The thread being blocked is the host's own tick
  ## thread, which is where `modcontrol.drain` runs an unload from. The thread
  ## being waited on is the game's, which enters the drain from inside a method
  ## Unity's player loop calls. They are different threads and neither holds
  ## anything the other needs — the queue lock is taken and released around a
  ## `seq` splice. The one case where they *are* the same thread is the host's
  ## stall fallback, where the host thread takes the queue back; `onUnload`
  ## checks `stalled` and does not come here at all in that case.
  ##
  ## The wait polls through `call("aowlspt.host::main_thread")` rather than
  ## spinning on a counter. That does two jobs: it is the opaque call that makes
  ## re-reading `gRestoreRuns` correct rather than something the optimiser may
  ## hoist, and it costs about a microsecond a turn, which throttles the spin
  ## without needing a sleep the ABI does not have.
  ##
  ## **The one shape that would wait on itself, and what happens instead.** If
  ## another mod emitted `aowl.perf.restore` from inside its *own*
  ## `onMainThread` callback, the handler would run on the drain's thread and
  ## this would be waiting for a drain it is standing in. Nothing in the ABI
  ## reports the calling thread, so that cannot be detected here. It is bounded
  ## rather than caught: the budget expires, the drain is observed not to have
  ## fired, and the error says exactly that. A stall of `restoreWaitMs` and a
  ## true sentence is the right failure for a case no interface can distinguish.
  drainMoved = false
  let startMs = nowMs()
  let mt0 = mainThreadInfo()
  let frames0 = mt0.frames
  while true:
    if gRestoreRuns >= runsWanted:
      drainMoved = true
      return true
    let mt = mainThreadInfo()
    if mt.frames != frames0:
      drainMoved = true
    if int(nowMs() - startMs) >= budgetMs:
      return false

proc restoreNowOrSayWhyNot(reason: string) =
  ## The whole revert path, in one place, used by the event and by unload.
  if appliedCount() == 0:
    return
  let n = appliedCount()
  let mt = mainThreadInfo()

  if gAppliedOffThread:
    # These settings were written from a thread the host never confirmed was
    # Unity's, because the config asked for that. Putting them back the same way
    # is not a new risk; queueing them onto a drain that was never Unity's
    # thread would be theatre.
    let done = restoreAll()
    gRestoreRuns = gRestoreRuns + 1
    warn "perf  " & reason & ": restored " & $done & " setting(s) from this " &
         "thread, because they were applied from it — general." &
         "requireMainThread was off"
    return

  if not mt.bound or mt.stalled:
    error "perf  " & reason & ": " & $n & " setting(s) are STILL APPLIED and " &
          "cannot be put back. The host's main-thread drain is " &
          (if mt.stalled: "stalled" else: "not bound") &
          ", and writing a Unity setting from this thread is the crash the " &
          "apply gate exists to avoid. They will persist until the game " &
          "exits. To avoid this, emit aowl.perf.restore while the game is " &
          "running and the drain is live."
    reportKnobs()
    return

  let want = gRestoreRuns + 1
  discard onMainThread(restoreOnMainThread)
  var drainMoved = false
  if awaitRestore(want, gCfg.restoreWaitMs, drainMoved):
    info "perf  " & reason & ": " & $n &
         " setting(s) put back on the game's thread"
    return

  # The budget ran out. This is the case the old code could not distinguish from
  # success, and it is stated rather than implied.
  error "perf  " & reason & ": " & $n & " setting(s) are STILL APPLIED. The " &
        "restore was queued onto the game's thread and did not run within " &
        $gCfg.restoreWaitMs & " ms" &
        (if drainMoved: " even though the drain kept firing, which means the " &
                        "queue is being drained by something else"
         else: " and the drain did not fire once in that time, so the game " &
               "has stopped calling " & mt.methodName) &
        ". They will persist until the game exits. Raise " &
        "general.restoreWaitMs, or emit aowl.perf.restore while the game is " &
        "running."
  reportKnobs()

# ---------------------------------------------------------------------------
# Events, so the settings can be undone without a restart
# ---------------------------------------------------------------------------

proc onRestoreEvent(payload: string): string =
  ## The documented way to revert while the game is running. It queues and waits
  ## like the unload path does, so the emitter gets an answer that is true when
  ## it reads it rather than a promise: an emit is delivered synchronously, and
  ## a mod manager that turned this mod off on the strength of `{"ok":true}`
  ## would otherwise be acting on a restore that had not happened yet.
  let before = appliedCount()
  restoreNowOrSayWhyNot("aowl.perf.restore")
  let after = appliedCount()
  result = "{\"ok\":" & (if after == 0: "true" else: "false") &
           ",\"restored\":" & $(before - after) & ",\"stillApplied\":" &
           $after & "}"

proc onHostUnloadRequest(payload: string): string =
  ## `aowlspt.host.mods.unload`, the mod manager's request.
  ##
  ## The host queues that request and performs it from its own loop on a later
  ## turn, and the event reaches subscribers *now* — so this is a whole host
  ## tick of warning, with the game still running normally and the drain still
  ## firing. Restoring here is the ordinary path; the wait in `onUnload` is the
  ## backstop for every other way a mod can be taken out.
  ##
  ## The guid is checked because the manager unloads other mods too, and putting
  ## this mod's settings back because a different mod was switched off would be
  ## a surprise with no log line attached to it. An unload request naming no
  ## guid is treated as ours: the cost of being wrong is a restore that did not
  ## need to happen, against settings that outlive the mod that set them.
  let g = asText(field(payload, "guid"), "")
  if g.len > 0 and g != ModGuid:
    return ""
  if appliedCount() > 0:
    restoreNowOrSayWhyNot("an unload of " & ModGuid & " was requested")
  result = ""

proc onApplyEvent(payload: string): string =
  gApplyRequested = false
  gApplyDone = false
  requestApply()
  result = "{\"ok\":true}"

proc onReportEvent(payload: string): string =
  reportKnobs()
  result = "{\"applied\":" & $appliedCount() & ",\"refused\":" &
           $refusedCount() & "}"

proc onResetFrameTimesEvent(payload: string): string =
  ## Start the distribution over, by hand.
  ##
  ## The mod already resets on its own when the settings change, which covers
  ## the A/B this mod can drive itself. This covers the one it cannot: a change
  ## made *outside* it — the player moving a slider in the game's own settings
  ## menu, a raid loading, a different mod arming a hook. None of those are
  ## visible from here, and a distribution that spans one of them describes a
  ## configuration that no longer exists.
  ##
  ## The answer carries the sample count being discarded, because "reset" with
  ## nothing to reset and "reset" throwing away four minutes of samples deserve
  ## different reactions from whoever emitted it.
  let n = histCount()
  resetHist()
  info "perf  frame-time distribution reset by aowl.perf.resetFrameTimes; " &
       $n & " sample(s) discarded"
  result = "{\"ok\":true,\"discarded\":" & $n & ",\"epoch\":" &
           $histEpoch() & "}"

# ---------------------------------------------------------------------------
# Self-tests
# ---------------------------------------------------------------------------

var gFailures = 0

proc check(what: string; ok1: bool; detail: string) =
  if ok1:
    success "selftest  " & what
  else:
    inc gFailures
    error "selftest  " & what & ": " & detail

proc checkTable() =
  ## The table's own integrity, which nothing else would catch: a duplicated
  ## config path means one of the two knobs silently reads the other's value,
  ## and an inverted band means the knob can never be enabled.
  var dupes = 0
  var badBands = 0
  var emptyProps = 0
  var i = 0
  while i < KnobCount:
    let a = knobAt(i)
    if a.prop.len == 0 or a.key.len == 0 or a.section.len == 0:
      inc emptyProps
    if a.lo > a.hi:
      inc badBands
    if a.owner < 0 or a.owner >= OwnerCount or ownerName(a.owner).len == 0:
      inc badBands
    var j = i + 1
    while j < KnobCount:
      let b = knobAt(j)
      if a.section == b.section and a.key == b.key:
        inc dupes
      inc j
    inc i
  check("the knob table has " & $KnobCount & " entries, all named",
        emptyProps == 0, $emptyProps & " entries are missing a name")
  check("no two knobs share a config path", dupes == 0,
        $dupes & " duplicated section.key pairs")
  check("every knob has a sane band and a real owner", badBands == 0,
        $badBands & " entries are malformed")

proc checkRefusalIsClean() =
  ## With no runtime in the process, every knob must refuse and none may claim
  ## to have applied. This is the case the simulator can prove and the game
  ## cannot: a mod that only ever runs where its types exist has never had its
  ## failure path executed.
  var i = 0
  while i < KnobCount:
    gState[i].apply = true
    gState[i].want = knobAt(i).lo
    inc i
  let applied = applyAll()
  var silent = 0
  i = 0
  while i < KnobCount:
    if not gState[i].applied and gState[i].why.len == 0:
      inc silent
    inc i
  check("nothing applied with no runtime present", applied == 0,
        $applied & " knobs claimed to apply")
  check("every refusal recorded a reason", silent == 0,
        $silent & " knobs refused silently")
  let restored = restoreAll()
  check("restoring nothing is a no-op", restored == 0,
        $restored & " knobs claimed to restore")

proc checkBandRefusal() =
  ## A value outside the band is refused rather than clamped, and the refusal
  ## happens before any call into the runtime — so it is observable here.
  var i = 0
  while i < KnobCount:
    gState[i].apply = true
    gState[i].want = knobAt(i).hi + 1000.0
    inc i
  discard applyAll()
  var banded = 0
  i = 0
  while i < KnobCount:
    if find(gState[i].why, "outside the band") >= 0:
      inc banded
    inc i
  check("an out-of-band value is refused, not clamped", banded == KnobCount,
        "only " & $banded & " of " & $KnobCount & " refused on the band")

proc checkWindow() =
  ## The window arithmetic, with frame counts fed in by hand. The first close
  ## must report nothing; the second must report a rate.
  resetWindow()
  let w0 = closeWindow(0'i64)
  check("the first window reports nothing", not w0.ok,
        "it reported " & $w0.frames & " frames")
  var spin = 0
  let t0 = perfCounter()
  while nanosBetween(t0, perfCounter()) < 2000000'i64:
    inc spin
  let w1 = closeWindow(120'i64)
  check("the second window reports a rate", w1.ok and w1.fpsMilli > 0,
        "ok=" & (if w1.ok: "true" else: "false") & " fps=" & milli(w1.fpsMilli))
  resetWindow()

proc checkRestoreRefusal() =
  ## With nothing applied, the whole revert path must be a silent no-op — and
  ## in particular must not block for `general.restoreWaitMs` waiting for a
  ## drain that will never run. The wait is on the unload path of a mod being
  ## taken out of a live game, and a simulator with no drain at all is exactly
  ## where a wait written the obvious way would sit for two seconds.
  let t0 = perfCounter()
  restoreNowOrSayWhyNot("selftest")
  let ns = nanosBetween(t0, perfCounter())
  check("reverting with nothing applied returns at once",
        ns < 100000000'i64,
        "it took " & $(ns div 1000000'i64) & " ms with no setting applied")

proc checkFrameSource() =
  ## The classification that decides whether the readout may say "fps", fed
  ## payloads by hand.
  ##
  ## This is a test of a **decoder**, not of a list of names, and that is the
  ## point of the change it is testing. The mod used to keep its own whitelist
  ## of the host's per-frame drain candidates; the host answers `perFrame` now,
  ## so what is left to get wrong is reading the answer -- and the case that
  ## matters is the one no current host produces, an older host that omits the
  ## key entirely. An absent key must mean unknown. Defaulting it to true would
  ## report a frame rate nobody vouched for, and that is the failure this whole
  ## file is arranged around.
  let perFrame = decodeMainThread(
    "{\"bound\":true,\"method\":\"EFT.MainApplication::Update\"," &
    "\"frames\":9042,\"perFrame\":true,\"stalled\":false}")
  let manyPerFrame = decodeMainThread(
    "{\"bound\":true,\"method\":\"UnityEngine.Time::get_deltaTime\"," &
    "\"frames\":90420,\"perFrame\":false,\"stalled\":false}")
  let oldHost = decodeMainThread(
    "{\"bound\":true,\"method\":\"EFT.MainApplication::Update\"," &
    "\"frames\":9042,\"stalled\":false}")

  check("a drain the host reports as per-frame counts frames",
        frameSourceOf(perFrame) == srcDrainFrames and
        countsFrames(frameSourceOf(perFrame)),
        "perFrame true was not read as a frame count")
  check("a drain the host reports as firing more than once a frame does not",
        frameSourceOf(manyPerFrame) == srcDrainFirings and
        not countsFrames(frameSourceOf(manyPerFrame)),
        "perFrame false was read as a frame count")
  check("a host that does not answer perFrame is unknown, not per-frame",
        frameSourceOf(oldHost) == srcDrainUnknown and
        not countsFrames(frameSourceOf(oldHost)),
        "an absent perFrame key was read as " &
        sourceName(frameSourceOf(oldHost)) &
        "; absent must mean unknown, and the method name must not be " &
        "consulted to fill the gap")
  check("the two not-a-frame-count cases stay distinguishable",
        srcDrainUnknown != srcDrainFirings and
        sourceName(srcDrainUnknown) != sourceName(srcDrainFirings) and
        rateWord(srcDrainUnknown) == rateWord(srcDrainFirings),
        "they must read differently in the log and identically in the number")
  check("a report that did not parse claims nothing",
        frameSourceOf(decodeMainThread("")) == srcDrainUnknown,
        "an empty report was classified as something")

  # And the counters must not be mixed. Two windows on different sources have
  # no common origin, so the second must be discarded rather than subtracted.
  resetWindow()
  discard closeWindow(1000'i64, srcDrainFrames)
  var spin = 0
  let t0 = perfCounter()
  while nanosBetween(t0, perfCounter()) < 2000000'i64:
    inc spin
  let w = closeWindow(10'i64, srcUnityFrames)
  check("a window whose counter changed is discarded, not subtracted",
        not w.ok, "it reported " & $w.frames & " frames across two counters")
  resetWindow()

proc checkHistogram() =
  ## The distribution's arithmetic, against answers worked out by hand.
  ##
  ## This is the half of the frame-time work that can be proved with no runtime,
  ## no host and no game, and it is the half most worth proving: a percentile is
  ## a number that always looks plausible. A histogram that silently clamped its
  ## tail, or that was off by one bucket, would report a p99 in milliseconds
  ## with a decimal point on it and no way for a reader to tell it was wrong.

  # ---- an empty distribution claims nothing -------------------------------
  resetHist()
  check("an empty distribution reports no percentile",
        not percentile(50000'i64).ok and histCount() == 0,
        "it answered a percentile with no samples")

  # ---- a known distribution, checked against the exact answer -------------
  #
  # 1000 samples: 990 at 10000 us and 10 at 30000 us. By construction the
  # median is 10000 and p99 is 10000 (the 990th sample) while p99.1 upward is
  # 30000. Bucket edges: 10000 us is inside bucket 156 (156*64 = 9984 ..
  # 10047), whose upper edge is 157*64 = 10048; 30000 us is inside bucket 468
  # (29952 .. 30015), upper edge 469*64 = 30016.
  resetHist()
  var i = 0
  while i < 990:
    recordUs(10000'i64)
    inc i
  i = 0
  while i < 10:
    recordUs(30000'i64)
    inc i

  check("the sample count is exact", histCount() == 1000'i64,
        "it counted " & $histCount() & " of 1000")
  check("the exact minimum and maximum survive bucketing",
        histMinUs() == 10000'i64 and histMaxUs() == 30000'i64,
        "min " & $histMinUs() & " max " & $histMaxUs() &
        ", expected 10000 and 30000")
  check("the mean is the arithmetic mean, not a bucket",
        histMeanUs() == 10200'i64,
        "it answered " & $histMeanUs() & ", expected 10200")

  let p50 = percentile(50000'i64)
  check("the median lands in the bucket holding the median sample",
        p50.ok and p50.us == 10048'i64 and not p50.fromTail,
        "p50 answered " & $p50.us & ", expected the upper edge 10048")

  # Rank for p99 is ceil(1000 * 0.99) = 990, which is the last 10000 us sample.
  let p99 = percentile(99000'i64)
  check("p99 is the 990th sample, not the largest one",
        p99.ok and p99.us == 10048'i64,
        "p99 answered " & $p99.us & ", expected 10048 -- if this says 30016 " &
        "the rank is off by one and every percentile is one sample high")

  # Rank for p99.9 is ceil(1000 * 0.999) = 999, which is in the 30000 us group.
  let p999 = percentile(99900'i64)
  check("p99.9 crosses into the slow group",
        p999.ok and p999.us == 30016'i64,
        "p99.9 answered " & $p999.us & ", expected 30016")

  check("the percentile is the bucket's upper edge, never its lower",
        p50.us > 10000'i64,
        "a percentile below the sample it names would understate every " &
        "frame time by up to one bucket")

  # ---- pacing --------------------------------------------------------------
  # p99/p50 = 10048/10048 = 1.000 for this distribution, because 99 percent of
  # it is one value. That is the answer a well-paced game gives.
  check("pacing is 1.000 when 99 percent of frames are the same length",
        stutterRatioMilli() == 1000'i64,
        "it answered " & $stutterRatioMilli())

  # ---- the tail is exact where the buckets are not ------------------------
  resetHist()
  recordUs(1000'i64)
  recordUs(int64(HistTopUs) + 100000'i64)   # 165.5 ms: well past the top
  check("a sample past the histogram's top is counted in the tail",
        histTail() == 1'i64,
        "the tail holds " & $histTail() & " of 1")
  check("a sample past the top is not clamped into the top bucket",
        histMaxUs() == int64(HistTopUs) + 100000'i64,
        "the maximum came back as " & $histMaxUs() &
        ", so the worst frame of the session was lost to clamping")
  let pTail = percentile(99000'i64)
  check("a percentile whose rank lands in the tail says so",
        pTail.ok and pTail.fromTail and pTail.us == int64(HistTopUs),
        "it answered " & $pTail.us & " with fromTail " &
        (if pTail.fromTail: "true" else: "false") &
        " -- reporting a tail percentile as a real value is the plausible " &
        "wrong number this mod exists not to produce")

  # ---- hitches are counted at the threshold, not to the nearest bucket ----
  resetHist()
  setHitchUs(50000'i64)
  recordUs(49999'i64)   # just under: not a hitch
  recordUs(50000'i64)   # exactly at: a hitch, because the test is >=
  recordUs(50001'i64)   # just over: a hitch
  check("hitches are counted against the threshold exactly",
        histHitches() == 2'i64,
        "it counted " & $histHitches() & " of 2 -- 49999, 50000 and 50001 " &
        "against a 50000 threshold; a count of 3 or 1 means the comparison " &
        "was rounded to a 64 us bucket edge")

  # ---- a negative interval is dropped, not folded in ---------------------
  resetHist()
  recordUs(5000'i64)
  recordUs(-1'i64)
  check("a negative interval is dropped rather than recorded",
        histCount() == 1'i64 and histMinUs() == 5000'i64,
        "it recorded " & $histCount() & " samples with a minimum of " &
        $histMinUs() & "; one backwards clock reading would otherwise sit " &
        "in the distribution forever")

  # ---- reset really resets, including the buckets -------------------------
  resetHist()
  i = 0
  while i < 500:
    recordUs(int64(i) * 100'i64)
    inc i
  let epochBefore = histEpoch()
  resetHist()
  check("reset clears the distribution and starts a new epoch",
        histCount() == 0'i64 and histMaxUs() == 0'i64 and
          histTail() == 0'i64 and histHitches() == 0'i64 and
          not percentile(50000'i64).ok and histEpoch() > epochBefore,
        "something survived the reset: count " & $histCount() & ", max " &
        $histMaxUs() & ", epoch " & $histEpoch())

  # A reset that left one bucket dirty would show up here and nowhere else:
  # the counters above are scalars and are easy to clear, the 4 KB of buckets
  # is the part a reset can get wrong.
  resetHist()
  recordUs(20000'i64)
  let after = percentile(50000'i64)
  check("no bucket survived the reset",
        after.ok and after.us == 20032'i64,
        "the median after a reset and one 20000 us sample was " & $after.us &
        ", expected 20032; anything else means a stale bucket outranked it")
  resetHist()

proc checkSampler() =
  ## The per-frame sampler's own cost and its refusal to run where a firing is
  ## not a frame. Simulator half: there is no drain here, so what is provable
  ## is the gate and the arithmetic.
  var why = ""

  # A host that never answered.
  var mt = decodeMainThread("")
  check("the sampler refuses a host that did not answer",
        not startPump(mt, why) and why.len > 0,
        "it armed against a report that did not parse")

  # A drain that is not Unity's thread.
  mt = decodeMainThread("{\"bound\":false,\"frames\":10,\"perFrame\":true}")
  check("the sampler refuses a drain that is not Unity's thread",
        not startPump(mt, why) and why.len > 0,
        "it armed on a worker thread's drain")

  # A drain the host reports as firing more than once a frame. This is the one
  # that would produce a confident, entirely wrong distribution: sub-frame
  # intervals give a p99 of about zero and a readout claiming the game never
  # stutters.
  mt = decodeMainThread("{\"bound\":true,\"frames\":10,\"perFrame\":false," &
                        "\"method\":\"UnityEngine.Time::get_deltaTime\"}")
  check("the sampler refuses a drain that fires more than once a frame",
        not startPump(mt, why) and why.len > 0,
        "it would have recorded sub-frame intervals as frame times")

  # A host too old to answer the question. Absent is unknown, not yes -- the
  # same rule the readout applies to the word fps.
  mt = decodeMainThread("{\"bound\":true,\"frames\":10}")
  check("the sampler treats an unanswered perFrame as unknown, not yes",
        not startPump(mt, why) and why.len > 0,
        "it armed on a host that never said its drain was per-frame")

  check("every sampler refusal named a reason", why.len > 0,
        "a refusal came back empty")

  # The liveness predicate, which is the part of the hand-rolled chain
  # `everyMain` does not hand back. The old pump called `onMainThread` itself,
  # saw the refusal and set a flag; `everyMain` re-arms inside the library, and
  # a refusal there releases the slot and tells nobody. What is left visible is
  # a readout window in which a chain that had been firing did not.
  #
  # Written as a pure function of three numbers precisely so it can be checked
  # here. The situation it detects cannot be produced in the simulator -- there
  # is no drain to silence -- so a predicate reachable only through its own
  # failure case would be one nothing had ever run, which is this project's
  # recurring bug rather than a hypothetical.
  check("a chain that fired during the window is not called quiet",
        not chainWentQuiet(true, 120'i64, 60'i64),
        "sixty firings in one window was read as a dead chain, which would " &
        "turn every readout into a warning")
  check("a chain that fired nothing over a whole window is called quiet",
        chainWentQuiet(true, 60'i64, 60'i64),
        "a chain whose firing count did not move across a whole readout " &
        "window was called healthy; that is exactly the distribution that " &
        "silently stops growing")
  check("a chain that has not fired yet is not called quiet",
        not chainWentQuiet(true, 0'i64, 0'i64),
        "a sampler armed a moment ago, before the first drain, was reported " &
        "as dead; this would fire on every boot")
  check("a chain that was never armed is not called quiet",
        not chainWentQuiet(false, 60'i64, 60'i64),
        "a sampler that never armed was reported as having stopped, which " &
        "names the wrong bug -- the refusal reason is what that case has")

  # The recording half's cost, which needs no host at all: it is a clock read,
  # a subtraction and a store into a fixed array.
  #
  # Run against a distribution that is deliberately *not* empty, because the
  # thing most worth checking about this benchmark is that it gives back what
  # it borrowed. It did not, once: it reset the histogram at both ends, which
  # threw away every frame collected before the self-test ran and made "the
  # worst frame this session" mean "the worst frame since the self-test".
  resetHist()
  var q = 0
  while q < 300:
    recordUs(16000'i64 + int64(q))
    inc q
  let beforeCount = histCount()
  let beforeMax = histMaxUs()
  let beforeEpoch = histEpoch()
  let beforeP50 = percentile(50000'i64).us

  let ns = benchPumpBody(50000)
  check("recording a frame interval costs under 200 ns",
        ns >= 0 and ns < 200'i64,
        "it cost " & $ns & " ns/sample; the store is into a 4 KB array that " &
        "should stay in L1, so anything near this bound means it is " &
        "allocating or missing cache")
  info "selftest  recording one frame interval costs " & $ns &
       " ns (50000 samples): one perfCounter read, a subtract and a store"

  check("measuring the recording path leaves the distribution untouched",
        histCount() == beforeCount and histMaxUs() == beforeMax and
          percentile(50000'i64).us == beforeP50,
        "before: " & $beforeCount & " samples, max " & $beforeMax &
        ", p50 " & $beforeP50 & "; after: " & $histCount() & " samples, max " &
        $histMaxUs() & ", p50 " & $percentile(50000'i64).us &
        ". A benchmark that eats the statistics restarts the session " &
        "silently every time it runs")
  check("and does not advance the epoch, because nothing changed",
        histEpoch() == beforeEpoch,
        "the epoch went from " & $beforeEpoch & " to " & $histEpoch() &
        "; a consumer watching it would think the configuration had changed")
  resetHist()

proc simSelfTest() =
  ## `aowl run mods/perf` ends here. No runtime, no game: what is provable
  ## without one is the table, the config, the arithmetic, and every refusal
  ## path — which is the half of this mod most likely to be wrong in the game
  ## and least likely to be exercised there.
  gFailures = 0
  info "selftest  simulator: no IL2CPP runtime in this process, by design"
  checkTable()
  check("the config named " & $KnobCount & " knobs without error",
        gConfigText.len > 0, "config.json was not readable")
  check("the frame sampler refuses to sample unbound", not unitySample(),
        "it sampled with no binding")
  check("binding Unity's Time refuses with a reason", not bindUnity(),
        "it bound a runtime that is not here")
  check("the refusal names something", unityWhy().len > 0,
        "the binding refused with an empty reason")
  checkWindow()
  checkFrameSource()
  checkHistogram()
  checkSampler()
  checkRefusalIsClean()
  checkBandRefusal()
  checkRestoreRefusal()
  if gFailures == 0:
    success "selftest  all simulator checks passed"
  else:
    error "selftest  " & $gFailures & " check(s) failed"
  # Leave the state as the config asked for it, not as the tests left it.
  gMissing = 0
  readKnobConfig(gConfigText, gMissing)

proc clientSelfTest() =
  ## Against a runtime — the mock, or one day the game. Everything here is a
  ## statement about what the runtime in this process actually answered.
  gFailures = 0

  # What answered. First line, before any verdict, for the reason
  # `reportHostIdentity` gives at length: every check below is a statement about
  # this host, and a reader who has to guess which host that was will re-derive
  # a conclusion that one line settles.
  info "selftest  host: " & describeHost()
  let mt0 = mainThreadInfo()
  check("the host says whether its drain counter counts frames",
        mt0.perFrameKnown,
        "aowlspt.host::main_thread carried no perFrame key, so the readout " &
        "cannot claim a frame rate from the drain counter on this host; that " &
        "is an older host rather than a fault, and the mod falls back " &
        "correctly, but it is worth seeing")

  # 1. Resolve-or-refuse, for every knob in the table and not only the ones
  #    config.json enabled. Read-only: nothing here writes.
  var resolved = 0
  var absent = 0
  var silent = 0
  var asserted = 0
  var i = 0
  while i < KnobCount:
    let k = knobAt(i)
    var value = 0.0
    var chosen = ""
    var viaAssert = false
    var why = ""
    if probeKnob(i, value, chosen, viaAssert, why):
      inc resolved
      if viaAssert: inc asserted
      if gCfg.verbose:
        info "selftest  " & k.section & "." & k.key & " resolves as " &
             ownerName(k.owner) & "::" & chosen & " = " & f3(value) &
             (if viaAssert: " (through an asserted int32 binding)" else: "")
    else:
      inc absent
      if why.len == 0:
        inc silent
      elif gCfg.verbose:
        info "selftest  " & k.section & "." & k.key & " refused: " & why
    inc i
  # Worded to avoid the substring "resolved " on its own: `hostharness`
  # counts lines containing it as evidence that *its* fixture mod resolved
  # types, and a mod that shouts the same words moves somebody else's gate.
  info "selftest  " & $resolved & " of " & $KnobCount &
       " knobs answered on this runtime; " & $absent & " did not"
  check("every knob answered or refused with a reason", silent == 0,
        $silent & " refused without saying why")
  check("the probe reached at least one knob", resolved > 0,
        "no knob resolved, so this runtime has none of these names")

  info "selftest  " & $asserted & " of " & $resolved &
       " knobs needed an asserted int32 binding to read"

  # 1b. The enum-return experiment, and it now has a verdict rather than a
  #     finding. The boxed getter used to hand an enum back as a live-object
  #     handle; `describeResult` unboxes it by the width the runtime reports
  #     now, so the plain path is correct and the asserted binding is a
  #     fallback. This checks the claim rather than restating it: whatever the
  #     boxed getter answers must *agree* with the asserted binding, and the
  #     two disagreeing is the failure worth catching either way round.
  i = 0
  while i < KnobCount:
    let ke = knobAt(i)
    if ke.kind == kkEnum:
      var raw = ""
      if rawGet(ke.owner, ke.prop, raw):
        var fast = 0.0
        var c3 = ""
        var a3 = false
        var w4 = ""
        if probeKnob(i, fast, c3, a3, w4):
          let boxedIsNumber = not handleShaped(raw)
          info "selftest  " & ke.key & ": the boxed getter answered " & raw &
               (if boxedIsNumber: " — a plain number, so no assertion is needed"
                else: " — handle-shaped, so the asserted int32 binding was " &
                      "used instead") & "; the value read is " & f3(fast)
          check("the boxed enum getter agrees with the asserted binding",
                (not boxedIsNumber) or raw == $int(fast),
                "the boxed getter answered " & raw &
                " and the asserted int32 binding read " & f3(fast) &
                "; one of the two is reading the wrong width")
          if boxedIsNumber and not a3:
            success "selftest  " & ke.key &
                    " needs no asserted binding on this host"
          else:
            # Not a failure: an older host is a supported host, and the
            # fallback is what supports it. It is a weaker claim than the
            # runtime's own metadata, so it is said out loud every run.
            warn "selftest  " & ke.key & " was read through an asserted " &
                 "int32 binding, because this host answered " & raw &
                 " rather than a number. That is correct and it is an " &
                 "assertion about the enum's underlying width, not a " &
                 "measurement of it."
      inc i
      continue
    inc i

  # 2. Every knob config.json enabled either applied or said why not.
  var quiet = 0
  i = 0
  while i < KnobCount:
    if gState[i].apply and not gState[i].applied and gState[i].why.len == 0:
      inc quiet
    inc i
  check("no enabled knob refused without saying why", quiet == 0,
        $quiet & " refused silently")

  # Reversibility, end to end: restore, confirm the originals are back, then
  # put the mod's own settings back so the test leaves nothing behind.
  var wasApplied = 0
  i = 0
  while i < KnobCount:
    if gState[i].applied: inc wasApplied
    inc i
  if wasApplied > 0:
    let restored = restoreAll()
    check("every applied setting was restored to its original",
          restored == wasApplied,
          $restored & " of " & $wasApplied & " came back")
    var wrong = 0
    i = 0
    while i < KnobCount:
      if gState[i].readable and gState[i].have != gState[i].orig:
        inc wrong
      inc i
    check("the restored values equal the originals that were read",
          wrong == 0, $wrong & " settings did not come back")
    gAppliedCount = applyAll()
    info "selftest  re-applied " & $gAppliedCount & " setting(s)"

    # The *queued* revert, which is the one that has to work on the way out.
    # Everything above ran `restoreAll` inline on whatever thread the self-test
    # is on; this is the path `onUnload` and `aowl.perf.restore` take — queue
    # onto the game's thread and block until it has run — and it is the half
    # that used to be untested and did not work.
    let queued0 = gRestoreRuns
    let t0 = perfCounter()
    restoreNowOrSayWhyNot("selftest")
    let waitedMs = nanosBetween(t0, perfCounter()) div 1000000'i64
    check("a restore queued onto the game's thread completes before the " &
          "caller returns", gRestoreRuns > queued0 and appliedCount() == 0,
          "after " & $waitedMs & " ms the drain had run the restore " &
          $(gRestoreRuns - queued0) & " time(s) and " & $appliedCount() &
          " setting(s) were still applied")
    info "selftest  the queued restore came back in " & $waitedMs & " ms"
    gAppliedCount = applyAll()
    info "selftest  re-applied " & $gAppliedCount &
         " setting(s) after the queued restore"
  else:
    info "selftest  no setting was applied, so there was nothing to restore " &
         "(this is what the shipped config.json does)"

  # The allocation claim, as a number.
  if gCfg.hudReadUnityTime and unityBound():
    let ns = benchUnitySample(gCfg.benchIterations)
    info "selftest  the frame sample path costs " & $ns & " ns/call over " &
         $gCfg.benchIterations & " calls"
    check("the sample path is allocation-free (under 200 ns/call over " &
          $gCfg.benchIterations & " calls)", ns > 0 and ns < 200,
          $ns & " ns/call is too slow for two bound calls; something on that " &
          "path is allocating")
  else:
    info "selftest  hud.readUnityTime is off, so there is no bound Unity " &
         "sample path to measure; the per-frame sampler below is measured " &
         "instead, and it needs no binding"

  # ---- the per-frame sampler ----------------------------------------------
  #
  # This block used to say "the mod runs no per-frame code at all, which is the
  # reason its per-frame allocation count is zero". That was true and is not any
  # more: the pump runs once a frame on the game's thread. A zero that came from
  # having no code is worth nothing once there is code, so it is measured here
  # the way `examples/highlevel` measures a typed hook — against mimalloc's
  # cumulative counter, with the probe that proves the counter is live.
  if not gCfg.hudFrameTimes:
    info "selftest  hud.frameTimes is off, so no distribution was collected " &
         "and the readout is means only"
  elif not pumpOn():
    info "selftest  the per-frame sampler is not running" &
         (if gPumpWhyNot.len > 0: ": " & gPumpWhyNot else: " and did not " &
          "say why, which is itself a bug")
    check("a sampler that did not arm said why", gPumpWhyNot.len > 0,
          "it refused silently")
  else:
    check("the per-frame sampler fired", pumpFirings() > 0'i64,
          "it armed and never ran, so the drain is not what it was thought " &
          "to be")

    # It must not leak a scheduler slot per frame: over hundreds of firings the
    # table must stay small rather than growing with the frame count.
    #
    # The bound came down from 32 to 4 with the move to `everyMain`, which
    # re-arms on the same cookie and so holds exactly one slot for the life of
    # the chain; the only other entries are this mod's own one-shots -- the
    # apply pass, and the restore at unload -- and those are not concurrent
    # with each other. Two is what it reads in practice.
    #
    # **What this number cannot tell you**, said here because it would be easy
    # to read it as saying it: it does not distinguish `everyMain` from the
    # hand-rolled chain. That chain called `onMainThread` from inside a firing,
    # which claims a slot -- but `claimTick` reuses freed ones, and the apply
    # pass has always freed one by then, so the peak was 2 for that chain too.
    # What the peak catches is a real leak, which is what it was put here for;
    # what rules out the churn is that `everyMain` re-arms on the same cookie,
    # and that is a property of a file this mod does not own.
    check("the sampler holds a bounded number of scheduler slots",
          pumpMaxSlots() > 0 and int64(pumpMaxSlots()) <= 4'i64,
          "the scheduler peaked at " & $pumpMaxSlots() & " slots over " &
          $pumpFirings() & " firings; a count that tracks the firings is the " &
          "per-frame slot leak this chain is only safe without, and anything " &
          "above this mod's handful of one-shots is on its way there")
    info "selftest  the sampler peaked at " & $pumpMaxSlots() &
         " scheduler slot(s) over " & $pumpFirings() & " firing(s)"

    # Allocation, measured. The counter is read outside the loop, and nothing
    # between the two reads builds a string -- `hostPatchStat` in
    # examples/highlevel cost five allocations by being read inside the window,
    # and read as "20000 firings made 5 allocations" until it was moved out.
    if not allocProbeOk():
      info "selftest  mimalloc's allocation counter is not readable in this " &
           "build, so the allocation claim below is the timing one only"
    else:
      let saveHitch = hitchUs()
      resetHist()
      let a0 = allocationCount()
      var k = 0
      while k < 20000:
        recordUs(16666'i64)
        inc k
      let a1 = allocationCount()
      resetHist()
      setHitchUs(saveHitch)
      check("recording 20000 frame intervals allocates nothing",
            a1 == a0,
            $(a1 - a0) & " allocation(s) over 20000 samples; the histogram " &
            "is a fixed array and must never reach the heap, because it is " &
            "written from inside the game's frame")
      info "selftest  20000 samples into the histogram: " & $(a1 - a0) &
           " allocation(s) in the mod"

    # The cost of the recording half, and of the whole firing. The two are
    # reported separately because they belong to different trees: the first is
    # this module's arithmetic, the second is that plus the host's queue, and a
    # regression in one should not be able to hide inside the other.
    let recNs = benchPumpBody(gCfg.benchIterations)
    check("recording a frame interval stays under 200 ns",
          recNs > 0'i64 and recNs < 200'i64,
          $recNs & " ns/sample is too slow for a clock read and an array store")
    info "selftest  recording half: " & $recNs & " ns/sample over " &
         $gCfg.benchIterations & " samples"

    # The whole firing, measured the only way it can be: by letting the host
    # actually run it. `gPumpArmedMs` and `gPumpArmedFirings` are taken when the
    # chain arms, so this is wall clock over firings and includes the host's
    # enqueue, its drain snapshot and the trampoline.
    let elapsed = nowMs() - gPumpArmedMs
    let fired = pumpFirings() - gPumpArmedFirings
    if elapsed > 0'i64 and fired > 0'i64:
      let perFiringUs = (elapsed * 1000'i64) div fired
      info "selftest  one sampler firing per " & $perFiringUs &
           " us of wall clock -- that is the frame interval, not the cost; " &
           "the cost is the recording figure above, and the re-arm and the " &
           "host's drain on top of it, neither of which is measured"

    # What this module's half of a firing takes out of the frame. Bounded
    # rather than merely printed -- but the bound moved with the meaning.
    #
    # This figure used to be `pumpBusyNs` and used to include the
    # `onMainThread` re-arm, because the hand-rolled chain made that call from
    # inside this handler. `everyMain` re-arms in the library after the handler
    # returns, so what is left in here is the recording, the slot read and the
    # two clock reads around them.
    #
    # It halved rather than vanishing, and that is worth saying because the
    # obvious prediction was wrong. Against the stand-in it read 850-1350 ns
    # with the enqueue inside and reads 350-800 ns without it, on the same
    # machine in the same minute; the enqueue was about half of it and the
    # other half is two `perfCounter` reads and whatever preemption lands
    # between them on a loaded box. That drift is why the bound is 5 us and not
    # 900 ns: a tighter one would be measuring the machine. It is twenty times
    # tighter than the 100 us it replaced, which had stopped bounding anything
    # once the expensive half moved out of reach.
    let body = pumpBodyNs()
    info "selftest  one sampler firing spends " & $body &
         " ns in this mod (" & $pumpNs() & " ns of it recording) over " &
         $pumpFirings() & " firing(s); the re-arm is in the library and the " &
         "drain is in the host, and neither is in that number"
    check("this mod's half of a sampler firing costs under 5 us",
          body >= 0'i64 and body < 5000'i64,
          $body & " ns for two clock reads, a subtraction, an array store " &
          "and a seq length is orders of magnitude too slow; at that price " &
          "the instrument is measuring itself and hookTyped (23 ns, " &
          "docs/PERF.md) is the shape this should take instead")
    if body > 0'i64:
      # As a share of a 60 fps frame, in parts per million, so the reader does
      # not have to do the division.
      info "selftest  that is " & $((body * 1000000'i64) div 16666667'i64) &
           " parts per million of a 16.7 ms frame, and it is a floor rather " &
           "than the price: everyMain's re-arm (a lock and a seq append in " &
           "the host) and the host's own drain overhead (two seq allocations " &
           "in drainDue, every frame while this runs) are both NOT MEASURED " &
           "and neither is included"

    info "selftest  the median-against-window-rate cross-check is deferred " &
         "until there are enough samples for a median; it runs from the " &
         "readout and reports there"

  if gFailures == 0:
    success "selftest  all runtime checks passed"
  else:
    error "selftest  " & $gFailures & " runtime check(s) failed"

# ---------------------------------------------------------------------------
# Entry points
# ---------------------------------------------------------------------------

proc onLoad(): Status =
  loadConfig()
  success ModName & " " & ModVersion & " loaded on " & hostName()
  if gMissing > 0:
    info "perf  " & $gMissing & " setting(s) were not in config.json; the " &
         "shipped defaults were used for those"
  if not gCfg.enabled:
    warn "perf  general.enabled is false; nothing will be applied"
  var wanted = 0
  var i = 0
  while i < KnobCount:
    if gState[i].apply: inc wanted
    inc i
  info "perf  config.json asks for " & $wanted & " of " & $KnobCount &
       " settings"
  discard on("aowl.perf.restore", onRestoreEvent)
  discard on("aowl.perf.apply", onApplyEvent)
  discard on("aowl.perf.report", onReportEvent)
  discard on("aowl.perf.resetFrameTimes", onResetFrameTimesEvent)
  # The mod manager's own control channel. Subscribed to rather than waited for:
  # an unload arrives here before the host performs it, which is the only point
  # at which a restore has a whole tick of running game ahead of it.
  discard on("aowlspt.host.mods.unload", onHostUnloadRequest)
  # Deliberately not opening the IL2CPP runtime here. At load the process has a
  # runtime but not yet a game, and a binding made now would be refused —
  # correctly, and permanently, since a refusal is not retried.
  Ok

proc onUpdate(elapsedMs: int64): Status =
  inc gTicks

  if side() == sideSim:
    if not gStarted:
      gStarted = true
      simSelfTest()
    return Ok

  if side() != sideClient:
    return Ok

  if not gCfg.enabled:
    return Ok

  let mt = mainThreadInfo()

  if not gStarted:
    gStarted = true
    # Before anything that could refuse: what is answering.
    reportHostIdentity()
    if mt.ok:
      info "perf  host drain: " & (if mt.bound: "bound to " & mt.methodName &
                                     (if mt.perFrameKnown:
                                        (if mt.perFrame:
                                           ", which the host reports runs " &
                                           "once per frame"
                                         else:
                                           ", which the host reports runs " &
                                           "more than once a frame")
                                      else:
                                        ", whose multiplicity this host does " &
                                        "not report")
                                   else: "not bound to a per-frame method")
    gDevice = readGraphicsDevice()
    if gDevice.len > 0:
      info "perf  gpu: " & gDevice
    reportReadOnly()

  # The optional Unity cross-check, bound once, and only where it is legal.
  if gCfg.hudReadUnityTime and not unityBound():
    if mt.bound:
      if bindUnity():
        info "perf  " & unityWhy()
      elif not gSaidUnity and gTicks > 60:
        gSaidUnity = true
        warn "perf  hud.readUnityTime is on but UnityEngine.Time did not " &
             "bind: " & unityWhy()
    elif not gSaidUnity and gTicks > 60:
      gSaidUnity = true
      warn "perf  hud.readUnityTime is on but the host's drain is not " &
           "Unity's thread, so reading Time would be an unsupported call " &
           "from a worker thread; refusing"

  # Open the runtime for the enum knobs. Retried until it takes.
  discard openRuntime()

  requestApply()

  # The per-frame sampler. Armed once, on the first tick the host reports a
  # drain that runs once per frame — which is later than load and may be never.
  #
  # The cost of its recording half is measured *before* it is armed, so the
  # benchmark's own samples cannot land in the distribution: `benchPumpBody`
  # leaves the histogram empty on purpose and this is the one ordering in which
  # that is harmless.
  if gCfg.hudFrameTimes and not gPumpTried:
    var why = ""
    let mt2 = mainThreadInfo()
    if mt2.ok and mt2.bound and mt2.perFrameKnown and mt2.perFrame:
      gPumpTried = true
      discard benchPumpBody(gCfg.benchIterations)
      if startPump(mt2, why):
        gPumpArmedMs = nowMs()
        gPumpArmedFirings = pumpFirings()
        info "perf  per-frame sampler armed on " & mt2.methodName &
             " through everyMain, which holds one scheduler slot for the " &
             "life of the chain; recording one frame interval costs " &
             $pumpNs() & " ns, and the re-arm that carries it costs whatever " &
             "the host's queue costs — that half is in the library now and " &
             "the readout says so rather than guessing at it"
      else:
        warn "perf  the per-frame sampler did not arm: " & why
        gPumpWhyNot = why
    elif gTicks == 300:
      # Said once, late, and only if it never became possible. Early in a run
      # "the drain has not fired yet" is indistinguishable from "it never
      # will", and warning about the first would be noise on every boot.
      gPumpTried = true
      discard startPump(mt2, why)
      warn "perf  no frame-time distribution on this host: " &
           (if why.len > 0: why else: "the host's drain never bound") &
           ". The mean in the readout is all this run can measure, and a " &
           "mean cannot see a hitch."
      gPumpWhyNot = why

  if gCfg.hudEnabled:
    let now = nowMs()

    # Which counter the window is closed against, decided every time rather than
    # once: the Unity binding can arrive part-way through a run, and the host's
    # drain method is known only after it has fired.
    var frames = mt.frames
    var source = frameSourceOf(mt)
    if unityBound():
      var got = false
      let uf = unityFrameCount(got)
      if got:
        frames = uf
        source = srcUnityFrames
    if source != gFrameSource:
      # Logged on every change rather than once. The source changes at most
      # twice in a run — when the drain binds and when `Time` does — and a
      # readout whose meaning changed silently is the thing this is for.
      gFrameSource = source
      gSaidSource = true
      if source == srcDrainUnknown:
        warn "perf  the readout counts " & sourceName(source) &
             " (" & (if mt.methodName.len > 0: mt.methodName
                     else: "no method yet") & "). This host does not answer " &
             "perFrame in aowlspt.host::main_thread, so whether its drain " &
             "counter is a frame count is not something anything in this " &
             "process knows. The number below is firings per second and is " &
             "not called a frame rate. A newer host answers it; turning " &
             "hud.readUnityTime on gets a real frame count either way, where " &
             "the drain is Unity's thread."
      elif source == srcDrainFirings:
        warn "perf  the readout counts " & sourceName(source) &
             ": the host reports that " & mt.methodName & " runs more than " &
             "once a frame, so its firing count is not a frame count. The " &
             "number below is firings per second. Turning hud.readUnityTime " &
             "on gets a real frame count where the drain is Unity's thread."
      else:
        info "perf  the readout counts " & sourceName(source)

    if gLastHudMs == 0:
      gLastHudMs = now
      discard closeWindow(frames, source)
    elif now - gLastHudMs >= int64(gCfg.hudIntervalMs):
      gLastHudMs = now
      if gCfg.hudReadUnityTime and unityBound():
        discard unitySample()
      let w = closeWindow(frames, source)
      if w.ok:
        hudLine(w)
        publish(w)

  if gCfg.selfTest and not gSelfTestDone and gApplyDone and windows() >= 2:
    gSelfTestDone = true
    clientSelfTest()

  if not gApplyRequested and gTicks == 300 and gApplyRefusedWhy.len > 0:
    warn "perf  nothing has been applied: " & gApplyRefusedWhy &
         " (set general.requireMainThread to false to write anyway, and " &
         "read the warning that comes with it)"

  Ok

proc onUnload(): Status =
  ## Unload is the one place where "restore everything" and "never crash the
  ## game" pull in opposite directions. Both are satisfiable, and the way they
  ## were reconciled before was not: the restore was queued onto the main thread
  ## and `onUnload` returned immediately, after which the host's
  ## `dropModRegistrations` removed the queued callback and freed the library.
  ## So the queued restore was **dropped**, reliably, and the log line said
  ## "queued a restore" as though something had been arranged.
  ##
  ## It is queued and then *waited on* now. `awaitRestore` says why blocking the
  ## host's thread here is safe and why it cannot wait on itself, and
  ## `restoreNowOrSayWhyNot` covers the three shapes the answer can take: put
  ## back on the game's thread, put back from this thread because that is where
  ## it was applied from, or **still applied** — which is logged as an error
  ## naming every setting rather than as a warning about a possibility.
  ##
  ## Two things reduce how often the wait is what saves it. A manager-driven
  ## unload is restored a whole tick earlier, from the
  ## `aowlspt.host.mods.unload` subscription; and `emit("aowl.perf.restore", "")`
  ## remains the way to revert deliberately, with an answer that is true when it
  ## is read.
  # Before anything else: stop asking for another frame. `everyMain` re-arms
  # from inside the library's own trampoline, so an unload that did not clear
  # the repeat marker would leave one more callback queued into a host that is
  # about to free this library. The host drops a departing mod's queued
  # callbacks, so this is belt as well as braces — but the belt is
  # `stopMainRepeats` and the braces are in a file this mod does not own.
  stopPump()
  if histCount() > 0:
    let p99 = percentile(99000'i64)
    info "perf  frame times over the last epoch: " & $histCount() &
         " frames, p99 " & milli(p99.us) & " ms, worst " &
         milli(histMaxUs()) & " ms, " & $histHitches() & " over " &
         $(hitchUs() div 1000'i64) & " ms"
  if gCfg.restoreOnUnload and appliedCount() > 0:
    restoreNowOrSayWhyNot("unloading")
  elif appliedCount() > 0:
    warn "perf  general.restoreOnUnload is false, so " & $appliedCount() &
         " setting(s) are being left applied on purpose; they will persist " &
         "until the game exits"
  info ModName & " unloaded after " & $gTicks & " ticks and " &
       $windows() & " measured window(s)"
  Ok

exportMod(
  guid = ModGuid,
  name = ModName,
  author = ModAuthor,
  version = ModVersion,
  sptRange = "*",
  sides = {sideClient, sideSim},
  onLoad = onLoad,
  onUpdate = onUpdate,
  onUnload = onUnload)
