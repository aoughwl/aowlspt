## What the model does, measured — with no game in the process.
##
## ---------------------------------------------------------------------------
## Why this is here
## ---------------------------------------------------------------------------
##
## Every number this mod produces used to rest on the same sentence: "it has
## never been playtested". That is true and it stays true — nothing in this mod
## has run against BSG's client — but it was being used to excuse a second thing
## it does not excuse. A spring system driven by known inputs can be
## *characterised*: driven with synthetic traces, its output bounded, its step
## response compared against the closed form of the oscillator it claims to be,
## and its whole parameter space swept for the values at which it stops being
## stable. None of that needs a raid. All of it was simply not being done.
##
## So this file drives the model — the real `tick`, the real sources, the real
## filters — through a set of stated scenarios, measures what comes out, and
## asserts *bounds* rather than shapes. A bound survives a retune of the
## physics; a golden trace does not, and would be edited to match the first
## time it failed.
##
## It ends at the weapon, not at the model's output: `model/spring.nim` carries
## BSG's rotation spring as arithmetic, so the chain measured here is degrees ->
## impulse -> spring -> degrees of weapon rotation, which is the thing a player
## actually sees. What is assumed about the spring is stated there and is one
## boolean wide.
##
## ---------------------------------------------------------------------------
## The units the assertions are in
## ---------------------------------------------------------------------------
##
## "Too much sway" is not a feeling if it is written as a distance. A 50 cm
## torso subtends
##
##     at  20 m:  1.43 degrees
##     at  50 m:  0.57 degrees
##     at 100 m:  0.29 degrees
##     at 300 m:  0.10 degrees
##
## so a *half*-width of 0.14 degrees is the amplitude at which the point of aim
## still stays on a chest at 100 m, and 0.7 degrees is where it stops staying on
## one at 20 m. Those two numbers are the whole playability scale, they come out
## of geometry rather than taste, and every bound below is quoted against them.
##
## ---------------------------------------------------------------------------
## What is in here
## ---------------------------------------------------------------------------
##
##     1.  the inertia oscillator, against its own closed form
##     2.  what a shooter sees: envelopes, frame rates, a jittered clock, a
##         burst, every preset
##     3.  the calibration: degrees -> impulse -> spring -> degrees
##     3b. the *spring's own* step response, both damping laws, against the
##         closed form — overshoot, rise, settling, saturation, and the clamp
##     3c. the limiter: the 131-entry tables in `model/limits.nim`, the two
##         case statements that have to agree with them, and what `sanitise`
##         does to a config that is out of range, infinite or not a number
##     4.  the sweep: where each tunable stops being stable
##     5.  the one-screen answer, which asserts nothing and is written for a
##         player with one raid's experience rather than for a gate
##
## 3b and 3c are the two that matter most for a thing nobody has played: a
## spring's step response and a limiter's clamp are arithmetic, so neither has
## any excuse to be unchecked, and between them they cover the two ways this mod
## can reach the game with a number that should never have got there.
##
## Nothing here allocates per tick. It allocates a handful of result records,
## once, on the simulator side; it is not on any frame's path.

import std/math
import vec
import fmt
import tuning
import limits
import state
import sources
import director
import spring

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------

type
  Check* = object
    ## One measured number and the band it had to be in.
    name*: string
    value*: float
    unit*: string
    lo*: float
    hi*: float
    banded*: bool        ## false: reported, not asserted
    ok*: bool

  ParamRange* = object
    ## Where one tunable stops being safe.
    name*: string
    docLo*: float
    docHi*: float
    stableLo*: float
    stableHi*: float
    clipLo*: float       ## and where the output starts hitting its ceiling
    clipHi*: float
    unbounded*: bool     ## the grid ran out before anything went wrong
    ok*: bool            ## the allowed range lies inside the stable one

  Report* = object
    checks*: seq[Check]
    ranges*: seq[ParamRange]
    failures*: int
    rangeFailures*: int
    summaryFrom*: int
      ## Where `summary` starts inside `checks`. Everything before it is a
      ## measurement with a band; everything from it on is the one-screen
      ## answer, which reads as an answer only if it is printed after the
      ## sweeps rather than in the middle of them.

proc report*(r: var Report; name: string; value: float; unit: string) =
  r.checks.add Check(name: name, value: value, unit: unit, lo: 0.0, hi: 0.0,
                     banded: false, ok: true)

proc assertBand*(r: var Report; name: string; value: float; unit: string;
                 lo, hi: float) =
  let good = isFinite(value) and value >= lo and value <= hi
  if not good:
    inc r.failures
  r.checks.add Check(name: name, value: value, unit: unit, lo: lo, hi: hi,
                     banded: true, ok: good)

const NoteUnit* = "|note|"
  ## A `Check` whose unit is this carries a sentence rather than a number: a
  ## heading, or a plain statement of something that has not been measured.
  ## `line` prints its name and nothing else.

proc note*(r: var Report; text: string) =
  ## A line of prose in the middle of a table of numbers. Not a measurement,
  ## never asserted, and it exists because "not measured" has to be printable in
  ## exactly those words next to the numbers that *were*.
  r.checks.add Check(name: text, value: 0.0, unit: NoteUnit, lo: 0.0, hi: 0.0,
                     banded: false, ok: true)

proc line*(c: Check): string =
  ## One result as a log line.
  if c.unit == NoteUnit:
    return c.name
  var s = pad(c.name, 42) & pad(fmtNum(c.value) & " " & c.unit, 18)
  if c.banded:
    s = s & (if c.ok: "ok    " else: "FAIL  ") &
        "[" & fmtNum(c.lo) & " .. " & fmtNum(c.hi) & "]"
  result = s

proc line*(p: ParamRange): string =
  ## One tunable's two edges. `stable` is where the model stops being bounded;
  ## `clean` is where it starts hitting its own output ceiling, which is not a
  ## failure but is the point past which the extra is thrown away.
  var st = "stable " & fmtNum(p.stableLo) & " .. " & fmtNum(p.stableHi)
  if p.unbounded:
    st = st & "+"      # the grid ran out before anything went wrong
  result = pad(p.name, 24) &
    pad("allowed " & fmtNum(p.docLo) & " .. " & fmtNum(p.docHi), 28) &
    pad(st, 34) &
    pad("clean to " & fmtNum(p.clipHi), 22) &
    (if p.ok: "ok" else: "FAIL — the allowed range leaves the stable one")

# ---------------------------------------------------------------------------
# Geometry, as constants
# ---------------------------------------------------------------------------

const
  TorsoHalfAt100m* = 0.143    ## degrees; aim still on a 50 cm chest at 100 m
  TorsoHalfAt20m* = 0.716     ## degrees; aim still on one at 20 m
  OffScreen* = 25.0           ## degrees; a rotation nobody would call sway

# ---------------------------------------------------------------------------
# Driving the model
# ---------------------------------------------------------------------------

type
  Trace* = object
    ## What one scenario produced.
    finite*: bool
    peak*: float          ## largest |hands| after the ceiling, degrees
    peakRaw*: float       ## largest |hands| before it — what the tuning asked for
    rms*: float
    mean*: Vec3           ## the DC term: does the point of aim walk off
    clippedFrames*: int
    peakSpring*: float    ## largest |weapon rotation| the spring actually reaches
    rmsSpring*: float
    peakImpulse*: float   ## largest single impulse handed to AddAcceleration
    impulseRate*: float   ## acceleration handed over per second of game time
    clampedImpulses*: int ## how often that impulse hit the spring's own clamp
    lateRms*: float       ## rms over the last tenth, for a divergence test
    earlyRms*: float      ## rms over the first half

  Drive* = object
    ## The synthetic input for one scenario.
    frames*: int
    dt*: float
    yawRate*: float       ## degrees per second
    pitchRate*: float
    turnSeconds*: float   ## the turn stops after this; negative means never
    turnFrom*: float      ## and does not start until this
    shotEvery*: float     ## seconds between shots; 0 for none
    jitter*: bool         ## vary dt frame to frame, as a real frame clock does

template steady*(nFrames: int; step: float): Drive =
  ## A scenario with no input at all: the shooter stands and aims.
  ##
  ## The parameters are named away from the fields they fill. A template that
  ## writes `Drive(frames: frames, ...)` has its *field* name substituted along
  ## with the value, and the error it produces names an object field rather than
  ## the template.
  Drive(frames: nFrames, dt: step, yawRate: 0.0, pitchRate: 0.0,
        turnSeconds: -1.0, turnFrom: 0.0, shotEvery: 0.0, jitter: false)

template turningAt*(nFrames: int; step, degPerSec: float): Drive =
  Drive(frames: nFrames, dt: step, yawRate: degPerSec, pitchRate: 0.0,
        turnSeconds: -1.0, turnFrom: 0.0, shotEvery: 0.0, jitter: false)

proc hash01(i: int): float =
  ## A deterministic pseudo-random in 0..1, for the dt jitter. The noise module
  ## has one; this is separate so that jittering the clock cannot perturb the
  ## sources' own noise streams and make two runs incomparable.
  var h: uint32 = cast[uint32](int32(i)) * 2654435761'u32 + 1013904223'u32
  h = (h xor (h shr 15'u32)) * 2246822519'u32
  h = h xor (h shr 13'u32)
  result = float(h) / float(high(uint32))

proc run*(t: Tuning; s0: ShooterState; cal: SpringCal; d: Drive): Trace =
  ## One scenario, start to finish. The whole chain: sources, director,
  ## ceiling, impulse, spring.
  var s = s0
  var dir = newDirector()
  reset(dir.heart, t)
  var sp = [newSpring(), newSpring(), newSpring()]

  var sum2 = 0.0
  var early2 = 0.0
  var late2 = 0.0
  var earlyN = 0
  var lateN = 0
  var acc = Zero3
  var yaw = 0.0
  var pitch = 0.0
  var clock = 0.0
  var nextShot = d.shotEvery
  let lateFrom = d.frames - (d.frames div 10)
  let earlyTo = d.frames div 2

  result = Trace(finite: true, peak: 0.0, peakRaw: 0.0, rms: 0.0, mean: Zero3,
                 clippedFrames: 0, peakSpring: 0.0, rmsSpring: 0.0,
                 peakImpulse: 0.0, impulseRate: 0.0, clampedImpulses: 0,
                 lateRms: 0.0, earlyRms: 0.0)

  var i = 0
  while i < d.frames:
    var dt = d.dt
    if d.jitter:
      # A real frame clock is not a metronome: a 60 fps average with occasional
      # 25 fps hitches is what the model is actually stepped on.
      dt = d.dt * (0.5 + 2.0 * hash01(i * 7919 + 13))
    clock = clock + dt

    var moving = true
    if d.turnSeconds >= 0.0 and clock > d.turnSeconds:
      moving = false
    if clock < d.turnFrom:
      moving = false
    if moving:
      yaw = yaw + d.yawRate * dt
      pitch = pitch + d.pitchRate * dt

    if d.shotEvery > 0.0 and clock >= nextShot:
      nextShot = nextShot + d.shotEvery
      onShot(dir, t)

    drive(dir.inertia, yaw, pitch, Zero3, s, t, dt)
    let o = tick(dir, s, t, dt)

    if not isFinite(o.hands) or not isFinite(o.raw):
      result.finite = false

    let m = magnitude(o.hands)
    let mr = magnitude(o.raw)
    if m > result.peak: result.peak = m
    if mr > result.peakRaw: result.peakRaw = mr
    if o.clipped: inc result.clippedFrames
    sum2 = sum2 + m * m
    if i < earlyTo:
      early2 = early2 + m * m
      inc earlyN
    if i >= lateFrom:
      late2 = late2 + m * m
      inc lateN
    acc = acc + o.hands

    # And into the game's spring, one per axis.
    let imp = springImpulse(o.hands, t, cal, dt)
    let mi = magnitude(imp)
    if mi > result.peakImpulse: result.peakImpulse = mi
    # Not divided by dt: under the per-second form the spring multiplies by dt
    # itself, so the acceleration this mod is asking for over a second is the
    # sum of the frame impulses times dt. This is the number that has to be the
    # same at 30 fps and at 240, and it is the mod's half of the chain.
    result.impulseRate = result.impulseRate + mi * dt
    if cal.accelMax > 0.0 and
       (fabs(imp.x) > cal.accelMax or fabs(imp.y) > cal.accelMax or
        fabs(imp.z) > cal.accelMax):
      inc result.clampedImpulses
    addAcceleration(sp[0], imp.x, cal.accelMax)
    addAcceleration(sp[1], imp.y, cal.accelMax)
    addAcceleration(sp[2], imp.z, cal.accelMax)
    for k in 0 ..< 3:
      step(sp[k], cal, dt)
    let w = vec3(sp[0].value, sp[1].value, sp[2].value)
    if not isFinite(w):
      result.finite = false
    let mw = magnitude(w)
    if mw > result.peakSpring: result.peakSpring = mw
    result.rmsSpring = result.rmsSpring + mw * mw

    inc i

  let n = fmax(1.0, float(d.frames))
  result.rms = sqrt(sum2 / n)
  result.impulseRate = result.impulseRate / fmax(0.001, float(d.frames) * d.dt)
  result.rmsSpring = sqrt(result.rmsSpring / n)
  result.mean = acc * (1.0 / n)
  result.earlyRms = sqrt(early2 / fmax(1.0, float(earlyN)))
  result.lateRms = sqrt(late2 / fmax(1.0, float(lateN)))

# ---------------------------------------------------------------------------
# The shooters
# ---------------------------------------------------------------------------

template rested*(): ShooterState =
  ## Fresh, standing, aiming a 3.5 kg 50-ergo rifle. The best case the model
  ## has, and the one whose sway has to still be small enough to shoot with.
  ShooterState(
    isAiming: true, isProne: false, isMounted: false, isBipod: false,
    isSprinting: false, holdingBreath: false, poseLevel: 1.0, lean: 0.0,
    moveSpeed: 0.0,
    stamina: 1.0, oxygen: 1.0, armStamina: 1.0, exhausted: false,
    armFractured: false, armBlacked: false, neuroTremor: false,
    ergonomics: 50.0, weightKg: 3.5, recoilStat: 100.0,
    exertion: 0.0, handlingFactor: 1.0, supportFactor: 1.0,
    supportSmoothed: 1.0)

template spent*(): ShooterState =
  ## Halfway through a sprint with a heavy rifle up. The self-test's old
  ## scenario, kept because it is the interesting middle of the range.
  ShooterState(
    isAiming: true, isProne: false, isMounted: false, isBipod: false,
    isSprinting: false, holdingBreath: false, poseLevel: 1.0, lean: 0.0,
    moveSpeed: 1.4,
    stamina: 0.35, oxygen: 0.55, armStamina: 0.6, exhausted: false,
    armFractured: false, armBlacked: false, neuroTremor: false,
    ergonomics: 38.0, weightKg: 5.2, recoilStat: 100.0,
    exertion: 0.0, handlingFactor: 1.0, supportFactor: 1.0,
    supportSmoothed: 1.0)

template wrecked*(): ShooterState =
  ## Every input at its worst at once: nothing left in the legs, lungs or arms,
  ## a broken and blacked arm, a stim's tremor, leaning out of a sprint with a
  ## 7 kg 20-ergo machine gun. Not a state the game produces often; it is
  ## exactly the state a bound has to hold for.
  ShooterState(
    isAiming: true, isProne: false, isMounted: false, isBipod: false,
    isSprinting: true, holdingBreath: false, poseLevel: 1.0, lean: 1.0,
    moveSpeed: 4.0,
    stamina: 0.0, oxygen: 0.0, armStamina: 0.0, exhausted: true,
    armFractured: true, armBlacked: true, neuroTremor: true,
    ergonomics: 20.0, weightKg: 7.0, recoilStat: 160.0,
    exertion: 0.0, handlingFactor: 1.0, supportFactor: 1.0,
    supportSmoothed: 1.0)

# ---------------------------------------------------------------------------
# 1. The oscillator, against its own closed form
# ---------------------------------------------------------------------------
#
# `WeaponInertia` claims to be a damped harmonic oscillator integrated
# semi-implicitly. That claim has a closed form, so it is checkable rather than
# merely assertable: for a step input a second-order system with damping ratio
# z overshoots by exp(-pi*z/sqrt(1-z^2)) and settles inside 2% in about
# 4/(z*omega) seconds. If the integrator, the substep cap or the mass coupling
# were wrong, the measured overshoot would not land on the analytic one — and
# that is a far sharper test than "the output looked reasonable".

# `analyticOvershoot` and `analyticSettle` are `model/spring.nim`'s, because a
# second-order system's closed form belongs beside the second-order system this
# mod has to reason about rather than beside the code that happens to measure
# one. The inertia oscillator and BSG's rotation spring are both second-order
# and both are checked against the same two functions.

proc inertiaStep*(r: var Report) =
  ## A turn that starts at t = 0 and never stops, so the oscillator's target is
  ## a constant and its approach to it is a textbook step response.
  var t = defaultTuning()
  # Everything except inertia off: this is a test of the oscillator, not of the
  # sum, and breathing riding on top would be measured as overshoot.
  t.respEnabled = false
  t.heartEnabled = false
  t.tremorEnabled = false
  t.driftEnabled = false
  t.outputSmoothing = 0.0
  t.inertiaInputSmoothing = 0.0     # the lag under test is the spring's own
  # And every slow multiplier off. Hold fatigue ramps to its ceiling over nine
  # seconds while aiming, which a step-response measurement reads as an
  # oscillator that never settles and never overshoots — it was measured as
  # exactly that before this line existed.
  t.fatigueEnabled = false
  t.injuryEnabled = false
  t.shotEnabled = false
  var s = rested()
  s.weightKg = t.weightReference    # mass ratio exactly 1, so f is t.inertiaFrequency

  let dt = 1.0 / 60.0
  let frames = 600
  var dir = newDirector()
  reset(dir.heart, t)
  var yaw = 0.0
  var peak = 0.0
  var final = 0.0
  var settleFrame = -1
  var trace: seq[float] = @[]
  var i = 0
  while i < frames:
    yaw = yaw + 180.0 * dt
    drive(dir.inertia, yaw, 0.0, Zero3, s, t, dt)
    let o = tick(dir, s, t, dt)
    let m = magnitude(o.hands)
    trace.add m
    if m > peak: peak = m
    inc i
  # The last tenth is the steady state.
  var tail = 0.0
  var n = 0
  for k in (frames - frames div 10) ..< frames:
    tail = tail + trace[k]
    inc n
  final = tail / fmax(1.0, float(n))

  # Settling: the last frame at which the trace was outside 2% of the steady
  # state, walked backwards.
  let band = 0.02 * final
  var k = frames - 1
  while k >= 0:
    if fabs(trace[k] - final) > band:
      settleFrame = k
      break
    dec k
  let settle = float(settleFrame + 1) * dt

  let overshoot = (if final > 0.0: peak / final - 1.0 else: 0.0)
  let predicted = analyticOvershoot(t.inertiaDamping)
  let omega = 2.0 * PI * t.inertiaFrequency
  # `analyticSettle` rather than 4/(zeta*omega): the tunable is allowed up to
  # 2.0, and past critical damping the settling time is set by the slow real
  # pole and starts getting *longer* again. The old form would have predicted
  # the opposite for any overdamped setting.
  let predictedSettle = analyticSettle(t.inertiaDamping, omega)

  report(r, "inertia steady deflection", final, "deg")
  # The band is wide because it is a *shape* check, not a value check: what is
  # asserted is that the integrated system has the overshoot the analytic one
  # has, to within the discretisation and the one-pole on the turn rate.
  assertBand(r, "inertia step overshoot", overshoot, "x",
             predicted - 0.05, predicted + 0.08)
  report(r, "  predicted overshoot", predicted, "x")
  assertBand(r, "inertia settling time", settle, "s",
             predictedSettle * 0.4, predictedSettle * 2.5)
  report(r, "  predicted settling", predictedSettle, "s")

proc flickResponse*(r: var Report) =
  ## A mouse flick: 1500 deg/s — well past the 900 deg/s clamp — for a fifth of
  ## a second, then nothing. What is asserted is that it stops: a sway model
  ## that rings after a flick is the single most complained-about failure mode
  ## such a mod has.
  var t = defaultTuning()
  t.respEnabled = false
  t.heartEnabled = false
  t.tremorEnabled = false
  t.driftEnabled = false
  t.outputSmoothing = 0.0
  t.fatigueEnabled = false
  t.injuryEnabled = false
  t.shotEnabled = false
  var s = rested()

  let dt = 1.0 / 60.0
  var dir = newDirector()
  reset(dir.heart, t)
  var yaw = 0.0
  var peak = 0.0
  var peakFrame = 0
  var crossings = 0
  var lastSign = 0
  var settleFrame = 0
  let frames = 600
  let flickUntil = 12          # 0.2 s
  var i = 0
  while i < frames:
    if i < flickUntil:
      yaw = yaw + 1500.0 * dt
    drive(dir.inertia, yaw, 0.0, Zero3, s, t, dt)
    let o = tick(dir, s, t, dt)
    let m = magnitude(o.hands)
    if m > peak:
      peak = m
      peakFrame = i
    if i > flickUntil:
      # Zero crossings of the yaw axis after the input stopped: each one is a
      # swing back through centre, and more than a couple is ringing.
      let sg = (if o.hands.y > 0.0001: 1 elif o.hands.y < -0.0001: -1 else: 0)
      if sg != 0 and lastSign != 0 and sg != lastSign:
        inc crossings
      if sg != 0: lastSign = sg
      if m > 0.02 * peak:
        settleFrame = i
    inc i

  assertBand(r, "flick peak deflection", peak, "deg",
             0.05, t.inertiaMaxDeflection + 0.001)
  assertBand(r, "flick swings after input", float(crossings), "",
             0.0, 4.0)
  assertBand(r, "flick decay to 2%", float(settleFrame - flickUntil) * dt, "s",
             0.05, 3.0)

# ---------------------------------------------------------------------------
# 2. What a shooter actually sees
# ---------------------------------------------------------------------------

proc envelopes*(r: var Report; cal: SpringCal) =
  ## Sixty seconds of each of the three shooters, standing still and aiming.
  ## Long enough for several breaths, a settled heart rate, the drift's own
  ## sub-hertz period and the full nine seconds of hold fatigue.
  ##
  ## Two different kinds of bound are asserted here and they are worth telling
  ## apart.
  ##
  ## *Regression bands* on the model's own degrees. The shipped per-source
  ## amplitudes are the BepInEx build's, ported constant for constant, and they
  ## are not independently defensible against any physiological figure — a
  ## rested shooter here wanders about six times as far as a real unsupported
  ## standing hold does. They are what that mod shipped and what its players
  ## tuned against, so what is asserted is that they have not *moved*: a retune
  ## that changes the feel has to change these numbers deliberately rather than
  ## by accident.
  ##
  ## *Playability bounds* on what the weapon actually does, which is the model's
  ## degrees through the game's spring. Those are geometry: the point of aim has
  ## to stay on a chest. They are checked under both damping laws, because the
  ## two are far apart and the mod has to be playable under whichever one BSG
  ## turns out to have written.
  let t = defaultTuning()
  let dt = 1.0 / 60.0
  let d = steady(3600, dt)
  var soft = cal                     # damping as a per-second rate: barely damped
  soft.dampingPerSecond = true

  let a = run(t, rested(), cal, d)
  let b = run(t, spent(), cal, d)
  let c = run(t, wrecked(), cal, d)
  let aSoft = run(t, rested(), soft, d)
  let bSoft = run(t, spent(), soft, d)

  # -- the model's own output, as a regression band ------------------------
  assertBand(r, "rested peak", a.peak, "deg", 0.55, 1.30)
  report(r, "  rested at 100 m", metresAt(a.peak, 100.0) * 100.0, "cm")
  report(r, "  a real standing hold is", TorsoHalfAt100m, "deg")
  assertBand(r, "rested rms", a.rms, "deg", 0.20, 0.55)
  assertBand(r, "rested never clips", float(a.clippedFrames), "frames",
             0.0, 0.0)

  assertBand(r, "spent peak", b.peak, "deg", 1.30, 2.60)
  report(r, "  spent at 100 m", metresAt(b.peak, 100.0) * 100.0, "cm")
  assertBand(r, "spent never clips", float(b.clippedFrames), "frames",
             0.0, 0.0)
  assertBand(r, "spent / rested", b.peak / fmax(0.001, a.peak), "x", 1.4, 3.5)

  # The worst case the game can produce: every multiplier at once. They compose
  # by multiplication and nothing compresses them, so the raw output is roughly
  # ninety times the rested case and the ceiling is what stands between that and
  # the weapon leaving the screen. It is doing its job here and it is doing it
  # continuously, which is worth knowing: in this state the output is a
  # constant-magnitude vector rather than a signal.
  assertBand(r, "wrecked peak", c.peak, "deg", b.peak, t.outputCeiling * 1.001)
  report(r, "  wrecked before the ceiling", c.peakRaw, "deg")
  report(r, "  wrecked / rested, uncapped", c.peakRaw / fmax(0.001, a.peak), "x")
  report(r, "  wrecked frames at the ceiling", float(c.clippedFrames), "of 3600")
  assertBand(r, "wrecked is capped", c.peak, "deg", 0.0, t.outputCeiling + 0.001)

  # -- what the weapon does, under both damping laws -----------------------
  report(r, "rested weapon, overdamped", a.peakSpring, "deg")
  report(r, "rested weapon, underdamped", aSoft.peakSpring, "deg")
  report(r, "  underdamped at 100 m", metresAt(aSoft.peakSpring, 100.0) * 100.0,
         "cm")
  assertBand(r, "rested weapon holds a chest at 50 m", a.peakSpring, "deg",
             0.02, 0.573)
  report(r, "  masterIntensity if underdamped",
         0.573 / fmax(0.001, aSoft.peakSpring), "x")
  report(r, "spent weapon, overdamped", b.peakSpring, "deg")
  report(r, "spent weapon, underdamped", bSoft.peakSpring, "deg")
  assertBand(r, "spent weapon holds a chest at 20 m", b.peakSpring, "deg",
             0.02, TorsoHalfAt20m)
  report(r, "  masterIntensity if underdamped",
         TorsoHalfAt20m / fmax(0.001, bSoft.peakSpring), "x")

  # The point of aim must not walk. Every oscillator here is centred — two of
  # them by an explicit DC blocker — so the mean over a minute is the test of
  # whether that centring works. A model that drifts is one that quietly aims
  # the weapon somewhere else, and no amount of tuning finds that.
  assertBand(r, "rested aim drift", magnitude(a.mean), "deg",
             0.0, TorsoHalfAt100m * 0.35)
  assertBand(r, "spent aim drift", magnitude(b.mean), "deg",
             0.0, TorsoHalfAt100m * 0.7)

proc frameRateIndependence*(r: var Report; cal: SpringCal) =
  ## The same thirty seconds at 30, 60, 144 and 240 fps.
  ##
  ## This is the property the old `* dt * 60` in `springImpulse` was for and did
  ## not deliver — at 120 fps it sent half the acceleration it sent at 60 — so
  ## it is the one the replacement has to be held to.
  ##
  ## What is measured is the mod's *own* half of the chain: the degrees the
  ## model produces, and the acceleration per second it asks the spring for.
  ## Deliberately not the modelled spring's output, which drifts by half across
  ## the same range for a reason that belongs to the spring and not to this mod:
  ## a velocity damped at 48 per second and integrated by splitting is being
  ## asked to take 33 ms steps at 30 fps, and that is a discretisation error in
  ## `model/spring.nim`'s stand-in — BSG's own will have its own, and this mod
  ## cannot fix either from outside. The spring figures are reported below so
  ## the size of that is visible rather than hidden.
  ##
  ## Two runs, with the tremor off and on. With it off, every source is well
  ## under a tenth of the lowest sampling rate and the chain has to be
  ## frame-rate independent to within rounding. With it on, a 9.5 Hz signal with
  ## two octaves above it is sampled at 30 Hz — under two samples per cycle at
  ## the top octave — and the spread that produces is aliasing, which no
  ## normalisation removes and which is a property of asking for a 10 Hz tremor
  ## on a 30 fps machine.
  let rates = [30.0, 60.0, 144.0, 240.0]

  var t = defaultTuning()
  t.tremorEnabled = false
  var rmsLo = 1.0e30
  var rmsHi = 0.0
  var accLo = 1.0e30
  var accHi = 0.0
  for i in 0 ..< 4:
    let dt = 1.0 / rates[i]
    let tr = run(t, spent(), cal, steady(floorToInt(30.0 * rates[i]), dt))
    if tr.rms < rmsLo: rmsLo = tr.rms
    if tr.rms > rmsHi: rmsHi = tr.rms
    if tr.impulseRate < accLo: accLo = tr.impulseRate
    if tr.impulseRate > accHi: accHi = tr.impulseRate
  assertBand(r, "model rms spread, no tremor",
             (if rmsLo > 0.0: (rmsHi / rmsLo - 1.0) * 100.0 else: 999.0), "%",
             0.0, 4.0)
  assertBand(r, "drive spread, no tremor",
             (if accLo > 0.0: (accHi / accLo - 1.0) * 100.0 else: 999.0), "%",
             0.0, 4.0)

  var t2 = defaultTuning()
  rmsLo = 1.0e30
  rmsHi = 0.0
  for i in 0 ..< 4:
    let dt = 1.0 / rates[i]
    let tr = run(t2, spent(), cal, steady(floorToInt(30.0 * rates[i]), dt))
    report(r, "  model rms at " & fmtNum(rates[i]) & " fps", tr.rms, "deg")
    report(r, "  weapon rms at " & fmtNum(rates[i]) & " fps", tr.rmsSpring,
           "deg")
    if tr.rms < rmsLo: rmsLo = tr.rms
    if tr.rms > rmsHi: rmsHi = tr.rms
  assertBand(r, "model rms spread, with tremor",
             (if rmsLo > 0.0: (rmsHi / rmsLo - 1.0) * 100.0 else: 999.0), "%",
             0.0, 25.0)

proc jitterRobustness*(r: var Report; cal: SpringCal) =
  ## The same thing on a frame clock that is not a metronome: dt between 8 and
  ## 50 ms, frame to frame. A model that is only stable at a fixed step is not
  ## stable.
  let t = defaultTuning()
  var d = steady(3600, 1.0 / 60.0)
  d.jitter = true
  let tr = run(t, spent(), cal, d)
  assertBand(r, "jittered clock, finite", (if tr.finite: 1.0 else: 0.0), "",
             1.0, 1.0)
  let smooth = run(t, spent(), cal, steady(3600, 1.0 / 60.0))
  let ratio = (if smooth.rms > 0.0: tr.rms / smooth.rms else: 99.0)
  assertBand(r, "jittered vs steady rms", ratio, "x", 0.6, 1.7)

proc burstResponse*(r: var Report; cal: SpringCal) =
  ## Thirty rounds at 600 rpm, then twelve seconds of nothing. The shot charge
  ## accumulates against a ceiling and decays; what is asserted is that it does
  ## come back down.
  var t = defaultTuning()
  # Hold fatigue off: it ramps for nine seconds after the weapon comes up and
  # would be measured here as a burst that never decays. What is under test is
  # the shot charge and the heart rate kick, which are the two things a burst
  # actually adds.
  t.fatigueEnabled = false
  let dt = 1.0 / 60.0
  var d = steady(1200, dt)
  d.shotEvery = 0.1
  d.turnSeconds = 0.0
  var s = spent()

  var dir = newDirector()
  reset(dir.heart, t)
  var peak = 0.0
  var tailPeak = 0.0
  var clock = 0.0
  var nextShot = 0.0
  var i = 0
  while i < 1200:
    clock = clock + dt
    if clock < 3.0 and clock >= nextShot:
      nextShot = nextShot + 0.1
      onShot(dir, t)
    drive(dir.inertia, 0.0, 0.0, Zero3, s, t, dt)
    let o = tick(dir, s, t, dt)
    let m = magnitude(o.hands)
    if clock < 3.5 and m > peak: peak = m
    if clock > 12.0 and m > tailPeak: tailPeak = m
    inc i
  report(r, "burst peak", peak, "deg")
  report(r, "  twelve seconds later", tailPeak, "deg")
  assertBand(r, "burst decays", (if peak > 0.0: tailPeak / peak else: 9.0), "x",
             0.0, 0.9)

proc presetSanity*(r: var Report; cal: SpringCal) =
  ## Every shipped preset, on the worst shooter, has to stay inside its own
  ## ceiling and stay finite. A preset is a config a player did not write and
  ## cannot see, so it is the one they are least able to diagnose.
  let dt = 1.0 / 60.0
  var d = steady(1800, dt)
  d.yawRate = 60.0
  let names = ["vanilla", "arcade", "realistic", "hardcore", "cinematic",
               "marksman"]
  var p = 0
  while p < 6:
    var t = defaultTuning()
    let pr = presetFromText(names[p])
    applyPreset(t, pr)
    let tr = run(t, wrecked(), cal, d)
    assertBand(r, "preset " & presetName(pr) & ", weapon", tr.peakSpring, "deg",
               0.0, OffScreen)
    assertBand(r, "preset " & presetName(pr) & ", finite",
               (if tr.finite: 1.0 else: 0.0), "", 1.0, 1.0)
    inc p

# ---------------------------------------------------------------------------
# 3. The calibration
# ---------------------------------------------------------------------------

proc calibration*(r: var Report) =
  ## What one degree of model output becomes, at the weapon.
  ##
  ## Three separable questions, and only the first is settled:
  ##
  ## 1. The drive gain. Settled: `impulse = degrees * ReturnSpeed` makes the
  ##    spring settle at exactly `degrees`, so the trim's honest default is 1.
  ## 2. Which acceleration form the spring uses. A factor of sixty, argued
  ##    dimensionally in `model/spring.nim`, one boolean to flip.
  ## 3. Which damping law it uses. Two orders of magnitude in the *transient*,
  ##    which at these frequencies is most of what a player sees. Not argued —
  ##    reported both ways, because there is no argument to make from here.
  let t = defaultTuning()
  let dt = 1.0 / 60.0
  var cal = defaultCal()

  assertBand(r, "unity drive gain, per second", unityDriveGain(cal, dt), "",
             0.999, 1.001)
  var alt = cal
  alt.perFrameAccel = true
  assertBand(r, "unity drive gain, per frame", unityDriveGain(alt, dt), "",
             0.999, 1.001)
  report(r, "  spring dc gain, per second", dcGain(cal, dt), "deg/accel")
  report(r, "  spring dc gain, per frame", dcGain(alt, dt), "deg/accel")
  report(r, "  the two forms differ by", dcGain(alt, dt) / dcGain(cal, dt), "x")

  # The spring's own dynamics. Its natural frequency lands between the postural
  # drift and the pulse, which is why the damping law matters as much as it
  # does: overdamped it attenuates everything the model sends, underdamped it
  # resonates in the middle of the model's band.
  var soft = cal
  soft.dampingPerSecond = true
  report(r, "spring natural frequency", naturalFreqHz(cal), "Hz")
  report(r, "  zeta, damping per frame", dampingRatio(cal, dt), "")
  report(r, "  zeta, damping per second", dampingRatio(soft, dt), "")

  # And what it does to each source's band, both ways. The pair of numbers on
  # each line is the honest width of what is known.
  let freqs = [0.23, 0.28, 0.42, 1.1, 9.5]
  let names = ["breath 0.23 Hz", "drift 0.28 Hz", "spring resonance 0.42 Hz",
               "pulse 1.1 Hz", "tremor 9.5 Hz"]
  for i in 0 ..< 5:
    report(r, "gain, " & names[i] & ", overdamped",
           springGain(cal, dt, freqs[i], t.driveGain), "deg/deg")
    report(r, "gain, " & names[i] & ", underdamped",
           springGain(soft, dt, freqs[i], t.driveGain), "deg/deg")

  # The old path, in the same units, so the change is legible: it multiplied
  # degrees by `dt * 60 * 8`, which under the per-second acceleration form is
  # 8/ReturnSpeed of the intended deflection at 60 fps and half that at 120.
  report(r, "old driveGain 8 at 30 fps",
         8.0 * (1.0 / 30.0) * 60.0 * dcGain(cal, 1.0 / 30.0), "deg/deg")
  report(r, "old driveGain 8 at 60 fps",
         8.0 * (1.0 / 60.0) * 60.0 * dcGain(cal, 1.0 / 60.0), "deg/deg")
  report(r, "old driveGain 8 at 120 fps",
         8.0 * (1.0 / 120.0) * 60.0 * dcGain(cal, 1.0 / 120.0), "deg/deg")

# ---------------------------------------------------------------------------
# 3b. The spring itself, against its own closed form
# ---------------------------------------------------------------------------
#
# `calibration` above measures where the spring *ends up*. This measures how it
# gets there, and checks the arithmetic in `model/spring.nim` against the
# textbook second-order system it claims to be — the same two closed forms the
# inertia oscillator is held to.
#
# The point is not that this spring is BSG's; it is that once the three numbers
# are read off the live spring, *these* are the numbers that follow from them.
# A player who says "the weapon takes about a second to settle" is then saying
# something comparable against a printed figure rather than against a shrug. The
# two candidate damping laws are half a minute apart here, which is why one raid
# settles the question and no amount of offline work does.

proc springCharacter*(r: var Report; cal: SpringCal) =
  ## The spring's step response, under both damping laws, measured against the
  ## closed form — and the clamp, which is the only thing between this mod and
  ## a weapon that has left the screen.
  let dt = 1.0 / 60.0
  var hard = cal                  # `Damping` as a per-frame fraction
  hard.dampingPerSecond = false
  var soft = cal                  # `Damping` as a rate in 1/s
  soft.dampingPerSecond = true
  let wn = sqrt(fmax(1.0e-9, cal.returnSpeed))

  # -- overdamped: zeta ~ 9, no overshoot, and a slow tail -------------------
  let zh = dampingRatio(hard, dt)
  let sh = stepResponse(hard, dt, 90.0)
  assertBand(r, "spring step finite, overdamped",
             (if sh.finite: 1.0 else: 0.0), "", 1.0, 1.0)
  # The steady state is the fixed point of `step`; `dcGain` is the closed form
  # of that fixed point. They are the same number or one of them is wrong.
  assertBand(r, "spring steady = dc gain, overdamped",
             sh.steady / fmax(1.0e-12, dcGain(hard, dt)), "x", 0.98, 1.02)
  assertBand(r, "spring overshoot, overdamped", sh.overshoot, "x",
             -0.001, analyticOvershoot(zh) + 0.02)
  report(r, "  predicted overshoot", analyticOvershoot(zh), "x")
  report(r, "spring settling, overdamped", sh.settle, "s")
  report(r, "  predicted settling", analyticSettle(zh, wn), "s")
  # A wide band, and it has to be: a velocity damped at 48 per second is being
  # integrated in 16 ms steps by a splitting integrator, so the discrete pole is
  # not the continuous one. What is asserted is the order of magnitude and the
  # sign of the effect, which is what a playtester can confirm or contradict.
  assertBand(r, "spring settling vs closed form, overdamped",
             sh.settle / fmax(0.001, analyticSettle(zh, wn)), "x", 0.3, 3.0)
  report(r, "spring rise to 90%, overdamped", sh.rise, "s")

  # -- underdamped: zeta ~ 0.1, a real overshoot, and ringing ---------------
  let zs = dampingRatio(soft, dt)
  let ss = stepResponse(soft, dt, 90.0)
  assertBand(r, "spring step finite, underdamped",
             (if ss.finite: 1.0 else: 0.0), "", 1.0, 1.0)
  assertBand(r, "spring steady = dc gain, underdamped",
             ss.steady / fmax(1.0e-12, dcGain(soft, dt)), "x", 0.98, 1.02)
  assertBand(r, "spring overshoot, underdamped", ss.overshoot, "x",
             analyticOvershoot(zs) - 0.08, analyticOvershoot(zs) + 0.08)
  report(r, "  predicted overshoot", analyticOvershoot(zs), "x")
  report(r, "spring settling, underdamped", ss.settle, "s")
  report(r, "  predicted settling", analyticSettle(zs, wn), "s")
  assertBand(r, "spring settling vs closed form, underdamped",
             ss.settle / fmax(0.001, analyticSettle(zs, wn)), "x", 0.5, 2.0)
  report(r, "spring rise to 90%, underdamped", ss.rise, "s")

  # The two laws, side by side, as one number: this is the size of the thing
  # one raid settles.
  report(r, "settling, the two laws differ by",
         fmax(sh.settle, ss.settle) / fmax(0.001, fmin(sh.settle, ss.settle)),
         "x")

  # -- the clamp ------------------------------------------------------------
  #
  # `AccelerationMax` clamps the accumulator rather than the deflection, so what
  # it actually buys is a deflection ceiling of accelMax * dcGain. That number
  # is the whole dimensional argument for the acceleration form, so it is
  # asserted here rather than only described in `model/spring.nim`.
  var s = newSpring()
  addAcceleration(s, 1.0e6, cal.accelMax)
  assertBand(r, "AddAcceleration clamps at AccelerationMax", s.accum, "",
             cal.accelMax - 1.0e-9, cal.accelMax + 1.0e-9)
  reset(s)
  addAcceleration(s, -1.0e6, cal.accelMax)
  assertBand(r, "  and clamps symmetrically", s.accum, "",
             -cal.accelMax - 1.0e-9, -cal.accelMax + 1.0e-9)
  reset(s)
  addAcceleration(s, 0.25 * cal.accelMax, cal.accelMax)
  addAcceleration(s, 0.25 * cal.accelMax, cal.accelMax)
  assertBand(r, "  and accumulates below it", s.accum, "",
             0.5 * cal.accelMax - 1.0e-9, 0.5 * cal.accelMax + 1.0e-9)
  var z = newSpring()
  z.value = 3.0
  z.velocity = 4.0
  z.accum = 5.0
  reset(z)
  assertBand(r, "  and `reset` empties it",
             fabs(z.value) + fabs(z.velocity) + fabs(z.accum), "", 0.0, 0.0)

  # Saturation: hold the accumulator at its clamp for a minute and see where the
  # spring ends up. It has to be `accelMax * dcGain` and nothing else, because
  # that is what a clamp on an accumulator means.
  var sat = newSpring()
  var i = 0
  let satN = floorToInt(60.0 / dt)
  while i < satN:
    addAcceleration(sat, 1.0e6, cal.accelMax)
    step(sat, cal, dt)
    inc i
  assertBand(r, "spring saturates at accelMax * dc gain", sat.value, "deg",
             saturation(cal, dt) * 0.98, saturation(cal, dt) * 1.02)
  report(r, "  most rotation this spring can hold", saturation(cal, dt), "deg")
  var alt = cal
  alt.perFrameAccel = true
  report(r, "  the same clamp under the per-frame form",
         saturation(alt, dt), "deg")
  # And that is the argument, as an assertion: a clamp constant is only
  # meaningful at the scale of the thing it clamps, and 103 degrees of weapon
  # rotation is not a scale weapon sway has.
  assertBand(r, "per-frame form would admit an off-screen weapon",
             saturation(alt, dt), "deg", OffScreen, 1.0e6)

# ---------------------------------------------------------------------------
# 3c. The limiter
# ---------------------------------------------------------------------------
#
# `model/limits.nim` is 131 names, 131 lows, 131 highs and two 131-arm case
# statements that all have to agree with each other and with the field order in
# `Tuning`. Nothing in the compiler checks that agreement: a transposed pair of
# case arms compiles, and its only symptom is a config key that silently sets a
# different setting. That is a whole class of bug that costs nothing to rule
# out, so it is ruled out here rather than left to a player to notice.

proc limiterChecks*(r: var Report) =
  ## The tables, the accessors and the clamp — all of it arithmetic, none of it
  ## needing a game.
  var badOrder = 0
  var outsideRange = 0
  var roundTripFails = 0
  var crossTalk = 0
  let shipped = defaultTuning()

  for i in 0 ..< ParamCount:
    if ParamLo[i] > ParamHi[i]:
      inc badOrder
    # The shipped default is the one value that must never need clamping: it is
    # what a NaN is put back to, so a default outside its own range would leave
    # `sanitise` unable to produce a legal tuning at all.
    let d = paramGet(shipped, i)
    if not isFinite(d) or d < ParamLo[i] or d > ParamHi[i]:
      inc outsideRange

    # `paramSet` then `paramGet` must be the identity on the value, and must
    # leave every *other* parameter alone. The second half is what catches a
    # duplicated or transposed case arm.
    var t = defaultTuning()
    let probe = ParamLo[i] + 0.375 * (ParamHi[i] - ParamLo[i])
    paramSet(t, i, probe)
    let got = paramGet(t, i)
    # Index 40 is `tremorOctaves`, an int, and is rounded on the way in.
    let tol = (if i == 40: 0.5001 else: 1.0e-9 + 1.0e-9 * fabs(probe))
    if not isFinite(got) or fabs(got - probe) > tol:
      inc roundTripFails
    for j in 0 ..< ParamCount:
      if j == i:
        continue
      if paramGet(t, j) != paramGet(shipped, j):
        inc crossTalk

  assertBand(r, "limits: every range is lo <= hi", float(badOrder), "bad",
             0.0, 0.0)
  assertBand(r, "limits: every default is inside its range",
             float(outsideRange), "bad", 0.0, 0.0)
  assertBand(r, "limits: paramSet/paramGet round-trip",
             float(roundTripFails), "bad", 0.0, 0.0)
  assertBand(r, "limits: paramSet touches nothing else", float(crossTalk),
             "bad", 0.0, 0.0)
  report(r, "limits: parameters covered", float(ParamCount), "")

  # The shipped tuning has to survive its own clamp untouched. If it does not,
  # every player sees a warning at load for a value they never typed.
  var clean = defaultTuning()
  var msgs: seq[string] = @[]
  assertBand(r, "limits: shipped defaults need no clamping",
             float(sanitise(clean, msgs)), "moved", 0.0, 0.0)
  assertBand(r, "  and produce no warnings", float(msgs.len), "lines", 0.0, 0.0)

  # Every preset too, for the same reason and with less excuse: a preset is a
  # config the player cannot see and did not write.
  var presetMoves = 0
  let presets = ["vanilla", "arcade", "realistic", "hardcore", "cinematic",
                 "marksman"]
  var k = 0
  while k < 6:
    var pt = defaultTuning()
    applyPreset(pt, presetFromText(presets[k]))
    var pm: seq[string] = @[]
    presetMoves = presetMoves + sanitise(pt, pm)
    inc k
  assertBand(r, "limits: no preset needs clamping", float(presetMoves),
             "moved", 0.0, 0.0)

  # -- the clamp itself, one case at a time ---------------------------------
  var over = defaultTuning()
  var m1: seq[string] = @[]
  over.masterIntensity = 1.0e6
  let n1 = sanitise(over, m1)
  assertBand(r, "clamp: above the range is pulled to the top",
             over.masterIntensity, "", ParamHi[0], ParamHi[0])
  assertBand(r, "  and is reported", float(n1), "moved", 1.0, 1.0)
  var named = 0.0
  if m1.len == 1 and m1[0].len > 15 and m1[0][0 ..< 15] == "masterIntensity":
    named = 1.0
  assertBand(r, "  by name", named, "", 1.0, 1.0)

  var under = defaultTuning()
  var m2: seq[string] = @[]
  under.globalTimeScale = -50.0
  discard sanitise(under, m2)
  assertBand(r, "clamp: below the range is pulled to the bottom",
             under.globalTimeScale, "", ParamLo[3], ParamLo[3])

  # A NaN has no nearest bound, so it goes back to the shipped default. This is
  # the case that actually protects the game: a NaN reaching `AddAcceleration`
  # poisons a spring that never comes back, and `1e999` in a JSON file is all it
  # takes to make one.
  var zero = 0.0
  var huge = 1.0e308
  var bad = defaultTuning()
  var m3: seq[string] = @[]
  bad.outputCeiling = zero / zero
  bad.driveGain = huge * huge
  bad.masterIntensity = -(huge * huge)
  discard sanitise(bad, m3)
  assertBand(r, "clamp: a NaN goes back to the shipped default",
             bad.outputCeiling, "", shipped.outputCeiling, shipped.outputCeiling)
  assertBand(r, "clamp: +inf goes back to the shipped default",
             bad.driveGain, "", shipped.driveGain, shipped.driveGain)
  assertBand(r, "clamp: -inf goes back to the shipped default",
             bad.masterIntensity, "", shipped.masterIntensity,
             shipped.masterIntensity)

  # And the whole point of the clamp: whatever is thrown at it, what comes out
  # is inside every range. Every parameter at once, at both infinities and at a
  # NaN.
  var wrong = defaultTuning()
  var w = 0
  while w < ParamCount:
    let mode = w mod 3
    if mode == 0:
      paramSet(wrong, w, huge * huge)
    elif mode == 1:
      paramSet(wrong, w, -1.0e9)
    else:
      paramSet(wrong, w, zero / zero)
    inc w
  var m4: seq[string] = @[]
  let moved = sanitise(wrong, m4)
  var stillBad = 0
  var q = 0
  while q < ParamCount:
    let v = paramGet(wrong, q)
    if not isFinite(v) or v < ParamLo[q] - 1.0e-9 or v > ParamHi[q] + 1.0e-9:
      inc stillBad
    inc q
  assertBand(r, "clamp: nothing survives it out of range", float(stillBad),
             "bad", 0.0, 0.0)
  assertBand(r, "clamp: and every one of them was reported", float(moved),
             "moved", float(ParamCount), float(ParamCount))
  # The message list is capped so that a wrecked config cannot fill the log, and
  # the cap has to say how much it swallowed rather than quietly dropping it.
  assertBand(r, "clamp: the warning list is capped", float(m4.len), "lines",
             1.0, 13.0)

  # A clamped tuning is not merely legal, it is *runnable*: the model has to
  # stay finite on it. That is the actual guarantee the clamp exists to give.
  let cal = defaultCal()
  let tr = run(wrong, wrecked(), cal, steady(600, 1.0 / 60.0))
  assertBand(r, "clamp: the model runs on what it produces",
             (if tr.finite: 1.0 else: 0.0), "", 1.0, 1.0)

# ---------------------------------------------------------------------------
# 4. The sweep
# ---------------------------------------------------------------------------
#
# For each tunable that can destabilise the model, walk a grid that runs from
# below its allowed range to well above it, and find the contiguous run of
# values around the shipped default that stays stable. Stable means: finite,
# not growing, and not past the point where the weapon has left the screen.
#
# The answer is what `model/limits.nim` is allowed to permit. Where the
# documented range reaches outside the stable one, that is a finding and the
# self-test says so by name.

const SweepSteps = 16

type
  Verdict = enum
    ## What one grid point of a sweep did.
    vStable,      ## bounded, settling, and the ceiling never had to act
    vClipping,    ## bounded and settling, but the output is against its ceiling
    vUnstable     ## not finite, or still growing after the input stopped

proc verdictAt(t0: Tuning; cal: SpringCal; idx: int; v: float): Verdict =
  ## One tunable set to one value, on a spent shooter who turns for four
  ## seconds, fires every second, and then stops — so the tail of the run is a
  ## system with no input left, which is where instability shows.
  var t = t0
  paramSet(t, idx, v)
  var d = steady(600, 1.0 / 60.0)
  d.yawRate = 90.0
  d.turnSeconds = 4.0
  d.shotEvery = 0.7
  let tr = run(t, spent(), cal, d)
  if not tr.finite:
    return vUnstable
  if tr.peakRaw > 1.0e6 or tr.peakSpring > OffScreen:
    return vUnstable
  # Growing rather than settling: the last tenth louder than the first half, on
  # a run whose input stopped two thirds of the way through.
  if tr.earlyRms > 1.0e-9 and tr.lateRms > tr.earlyRms * 3.0:
    return vUnstable
  if tr.clippedFrames > 0:
    return vClipping
  result = vStable

proc sweepOne*(cal: SpringCal; idx: int): ParamRange =
  ## Walk a grid from below the allowed range to well above it, and find the two
  ## edges that matter around the shipped value: where the model stops being
  ## *stable*, and where it starts hitting its own output ceiling.
  ##
  ## Outwards from the shipped value rather than across the whole grid, because
  ## a clamp can only express a contiguous interval — an island of stability
  ## past an unstable band is not a range this mod could permit even if one
  ## existed.
  let base = defaultTuning()
  let docLo = ParamLo[idx]
  let docHi = ParamHi[idx]
  let shipped = paramGet(base, idx)
  let span = fmax(0.001, docHi - docLo)
  let from1 = docLo - span * 0.5
  let to1 = docHi + span * 3.0
  var lo = shipped
  var hi = shipped
  var clipLo = shipped
  var clipHi = shipped
  var clipLoOpen = true
  var clipHiOpen = true

  # The grid passes exactly through the documented bound and then keeps going.
  # An evenly spaced grid between the shipped value and three ranges out lands
  # *near* the bound and not on it, and the difference showed up as
  # `globalTimeScale` reporting its lower edge at 0.109 against an allowed 0.1 —
  # a resolution artefact reported as a safety finding, which is the worst kind
  # of false positive a check like this can produce.
  let half = SweepSteps div 2
  var i = 0
  while i < SweepSteps:
    var up = 0.0
    if i < half:
      up = shipped + (docHi - shipped) * (float(i + 1) / float(half))
    else:
      up = docHi + (to1 - docHi) * (float(i - half + 1) / float(SweepSteps - half))
    let v = verdictAt(base, cal, idx, up)
    if v == vUnstable:
      break
    hi = up
    if v == vStable and clipHiOpen:
      clipHi = up
    else:
      clipHiOpen = false
    inc i
  i = 0
  while i < SweepSteps:
    var down = 0.0
    if i < half:
      down = shipped + (docLo - shipped) * (float(i + 1) / float(half))
    else:
      down = docLo + (from1 - docLo) * (float(i - half + 1) / float(SweepSteps - half))
    let v = verdictAt(base, cal, idx, down)
    if v == vUnstable:
      break
    lo = down
    if v == vStable and clipLoOpen:
      clipLo = down
    else:
      clipLoOpen = false
    inc i

  result = ParamRange(name: ParamName[idx], docLo: docLo, docHi: docHi,
                      stableLo: lo, stableHi: hi,
                      clipLo: clipLo, clipHi: clipHi,
                      unbounded: clipHiOpen and hi >= to1 - 1.0e-9,
                      ok: lo <= docLo + 1.0e-9 and hi >= docHi - 1.0e-9)

proc sweep*(r: var Report; cal: SpringCal) =
  ## Every tunable marked as stability-relevant in `model/limits.nim`.
  for i in 0 ..< ParamCount:
    if not ParamSwept[i]:
      continue
    let pr = sweepOne(cal, i)
    if not pr.ok:
      inc r.rangeFailures
    r.ranges.add pr

# ---------------------------------------------------------------------------
# 5. The one-screen answer
# ---------------------------------------------------------------------------
#
# Everything above is a check, and a check is only readable by someone who
# already knows what it is checking. This section is for the other reader: a
# player who has done one raid and wants to say which number is wrong.
#
# It asserts nothing. It prints, in one block, exactly the quantities a raid
# can contradict — how far the weapon moves standing still, how far it moves
# with nothing left, how long it takes to stop after a flick, and how far past
# the target it goes on the way. Every one of them is arithmetic over the
# constants in `config.json` and the three numbers read off the game's own
# spring, so every one of them is a claim rather than a feeling, and a player
# who says "it settles in about a second" has contradicted a printed 24.1.
#
# Where a number cannot be had from here it says **not measured**, in those
# words, rather than an estimate that reads like a measurement.

proc summary*(r: var Report; cal: SpringCal) =
  ## The whole model in twenty lines, in the units a raid can argue with.
  let t = defaultTuning()
  let dt = 1.0 / 60.0
  let d = steady(3600, dt)
  var hard = cal
  hard.dampingPerSecond = false
  var soft = cal
  soft.dampingPerSecond = true

  note(r, "-- the assumed spring --")
  let src = (if cal.measured: "(read off the live spring)"
             else: "(not measured: this mod's own shipped value)")
  report(r, "ReturnSpeed", cal.returnSpeed, src)
  report(r, "Damping", cal.damping, src)
  report(r, "AccelerationMax", cal.accelMax, src)
  note(r, "acceleration form: " &
       (if cal.perFrameAccel: "per frame" else: "per second") &
       " -- not measured; argued dimensionally in model/spring.nim")
  note(r, "damping law: not measured. Both are printed below, and they are " &
       "the largest unknown left in this mod.")

  # -- the spring's transient, both ways -----------------------------------
  let zh = dampingRatio(hard, dt)
  let zs = dampingRatio(soft, dt)
  let sh = stepResponse(hard, dt, 90.0)
  let ss = stepResponse(soft, dt, 90.0)
  note(r, "-- what the spring does with a step --")
  report(r, "natural frequency", naturalFreqHz(cal), "Hz")
  report(r, "if Damping is per frame:  zeta", zh, "(overdamped)")
  report(r, "  overshoot", sh.overshoot * 100.0, "%")
  report(r, "  time to 90% of the target", sh.rise, "s")
  report(r, "  settling time to 2%", sh.settle, "s")
  report(r, "if Damping is per second: zeta", zs, "(underdamped)")
  report(r, "  overshoot", ss.overshoot * 100.0, "%")
  report(r, "  time to 90% of the target", ss.rise, "s")
  report(r, "  settling time to 2%", ss.settle, "s")
  report(r, "the two differ, on rise, by",
         fmax(sh.rise, ss.rise) / fmax(0.001, fmin(sh.rise, ss.rise)), "x")
  report(r, "most rotation the spring can hold", saturation(cal, dt), "deg")

  # -- steady-state amplitude, at rest and at full exertion ----------------
  #
  # Sixty seconds standing and aiming: long enough for several breaths, a
  # settled heart rate and the drift's own sub-hertz period. `peak` is the
  # worst excursion in that minute and `rms` is what it looks like most of the
  # time; both are half-widths of the point of aim, so a player sees twice them
  # across a full cycle.
  let ar = run(t, rested(), hard, d)
  let sp = run(t, spent(), hard, d)
  let wr = run(t, wrecked(), hard, d)
  let arS = run(t, rested(), soft, d)
  let spS = run(t, spent(), soft, d)
  let wrS = run(t, wrecked(), soft, d)

  note(r, "-- steady state, sixty seconds aiming --")
  report(r, "model, rested:      peak", ar.peak, "deg")
  report(r, "  rms", ar.rms, "deg")
  report(r, "model, spent:       peak", sp.peak, "deg")
  report(r, "  rms", sp.rms, "deg")
  report(r, "model, full exertion: peak", wr.peak, "deg")
  report(r, "  rms", wr.rms, "deg")
  report(r, "  before the output ceiling", wr.peakRaw, "deg")

  report(r, "weapon, rested,  overdamped", ar.peakSpring, "deg")
  report(r, "  at 100 m", metresAt(ar.peakSpring, 100.0) * 100.0, "cm")
  report(r, "weapon, rested,  underdamped", arS.peakSpring, "deg")
  report(r, "  at 100 m", metresAt(arS.peakSpring, 100.0) * 100.0, "cm")
  report(r, "weapon, spent,   overdamped", sp.peakSpring, "deg")
  report(r, "  at 100 m", metresAt(sp.peakSpring, 100.0) * 100.0, "cm")
  report(r, "weapon, spent,   underdamped", spS.peakSpring, "deg")
  report(r, "  at 100 m", metresAt(spS.peakSpring, 100.0) * 100.0, "cm")
  report(r, "weapon, wrecked, overdamped", wr.peakSpring, "deg")
  report(r, "weapon, wrecked, underdamped", wrS.peakSpring, "deg")
  report(r, "  a 50 cm chest at 100 m is", TorsoHalfAt100m, "deg half-width")
  report(r, "  a 50 cm chest at 20 m is", TorsoHalfAt20m, "deg half-width")

  # -- and the one number a playtester is most likely to want to change ----
  #
  # `masterIntensity` scales every source at once. If the weapon swims, this is
  # what to turn, and these are the values at which the two states that matter
  # land exactly on a chest. They are not a recommendation: they are what the
  # arithmetic says under each of the two damping laws, and which of the two
  # applies is the thing that has not been measured.
  let mrOver = 0.573 / fmax(0.001, ar.peakSpring)      # rested, chest at 50 m
  let msOver = TorsoHalfAt20m / fmax(0.001, sp.peakSpring)
  let mrSoft = 0.573 / fmax(0.001, arS.peakSpring)
  let msSoft = TorsoHalfAt20m / fmax(0.001, spS.peakSpring)
  note(r, "-- masterIntensity, if the weapon swims --")
  report(r, "shipped", t.masterIntensity, "")
  report(r, "for a chest at 50 m rested, overdamped", mrOver, "x")
  report(r, "for a chest at 20 m spent, overdamped", msOver, "x")
  report(r, "for a chest at 50 m rested, underdamped", mrSoft, "x")
  report(r, "for a chest at 20 m spent, underdamped", msSoft, "x")
  report(r, "the binding one, overdamped", fmin(mrOver, msOver), "x")
  report(r, "the binding one, underdamped", fmin(mrSoft, msSoft), "x")

  # -- what a single raid would settle, as a list --------------------------
  #
  # Each of these is one observation long. None of them needs instrumentation,
  # a log, or a second run: they are things a shooter sees in the first minute
  # of a raid, and each one collapses a factor this file currently has to print
  # twice.
  note(r, "-- one raid settles, in this order --")
  note(r, "1. is anything visible at all? Nothing => " &
       "springs.accelerationPerFrame is the wrong way round.")
  note(r, "2. is the weapon pinned or snapping? => the same boolean, " &
       "the other way.")
  note(r, "3. does it ring after a flick? Rings for ~" & fmtNum(ss.settle) &
       " s => Damping is a per-second rate. Sluggish, ~" &
       fmtNum(sh.rise) & " s to follow at all => it is a per-frame fraction.")
  note(r, "4. does the weapon swim while standing still? => masterIntensity " &
       "becomes " & fmtNum(fmin(mrSoft, msSoft)) & " if underdamped, " &
       fmtNum(fmin(mrOver, msOver)) & " if overdamped.")
  note(r, "5. the first frame in a raid logs the live spring's own " &
       "ReturnSpeed, Damping and AccelerationMax. Those three replace the " &
       "shipped guesses and every number above is recomputed from them.")

# ---------------------------------------------------------------------------
# The whole thing
# ---------------------------------------------------------------------------

proc characterise*(cal: SpringCal; withSweep: bool): Report =
  ## Every measurement above, in one report. `withSweep` is separate because it
  ## is most of the runtime — roughly forty scenarios per tunable — and the
  ## bounded checks are the half worth running on every build.
  result = Report(checks: @[], ranges: @[], failures: 0, rangeFailures: 0,
                  summaryFrom: 0)
  calibration(result)
  springCharacter(result, cal)
  limiterChecks(result)
  inertiaStep(result)
  flickResponse(result)
  envelopes(result, cal)
  frameRateIndependence(result, cal)
  jitterRobustness(result, cal)
  burstResponse(result, cal)
  presetSanity(result, cal)
  if withSweep:
    sweep(result, cal)
  result.summaryFrom = result.checks.len
  summary(result, cal)
