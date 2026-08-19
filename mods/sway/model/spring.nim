## BSG's rotation spring, as arithmetic — and the calibration between the
## model's degrees and what that spring does with them.
##
## ---------------------------------------------------------------------------
## Why this file exists
## ---------------------------------------------------------------------------
##
## `AddAcceleration` is the only thing this mod pushes into the game, and the
## number it pushes is the model's output in degrees multiplied by one constant.
## That constant used to be `driveGain = 8`, "derived analytically" and never
## verified, and everything downstream of it — is the mod too strong, too weak,
## frame-rate dependent, or clamped away entirely — was unknowable without a
## raid.
##
## It is not unknowable. The spring is a two-state linear filter and its
## behaviour follows from three numbers the game already holds: `ReturnSpeed`,
## `Damping`, and `AccelerationMax`. This file states the spring, so that the
## calibration is a computation rather than a guess, and so that the whole
## question can be swept offline.
##
## Nothing here touches a game. It is in `model/` for the same reason
## everything else here is: `game/live.nim` reads the three numbers off the live
## spring and hands them over as a `SpringCal`, and the simulator hands over the
## shipped defaults instead.
##
## ---------------------------------------------------------------------------
## Two things are assumed, and they are worth different amounts
## ---------------------------------------------------------------------------
##
## The first decides the *calibration* and is argued below. The second decides
## the *transient*, is not arguable from here, and is the larger of the two at
## the frequencies this mod produces — see "the second assumption" further down.
## Neither has been seen against BSG's client.
##
## A Unity spring of this shape is written one of two ways, and BSG's source is
## not readable from here:
##
##     A. velocity += acceleration          ("per frame")
##     B. velocity += acceleration * dt     ("per second")
##
## Everything else about the spring — the return term, the damping, the
## integration of value — is the same in both. The two differ in the steady
## deflection one unit of acceleration buys:
##
##     A:  value = acceleration / (ReturnSpeed * dt)   ~ 8.6x at 60 fps, R = 7
##     B:  value = acceleration / ReturnSpeed          ~ 0.14x,           R = 7
##
## A factor of `1/dt`, which at 60 fps is sixty. So the choice is not a detail:
## it is the entire calibration, and picking the wrong one makes this mod either
## invisible or a catapult.
##
## **The evidence says B**, and it is dimensional rather than empirical. Under A
## a spring configured with `AccelerationMax = 12` would admit a single frame's
## impulse capable of a 103-degree weapon rotation, and BSG's own effectors —
## breathing, walk bob, recoil — would have to be feeding it accelerations of
## order 0.01 for the weapon to stay on screen. Under B the same clamp of 12
## admits 1.7 degrees, which is the scale weapon sway actually has. A clamp
## constant is only meaningful at the scale of the thing it clamps.
##
## That is an argument, not a measurement, so it is `springAccelPerFrame` in the
## config: one boolean, both branches frame-rate independent, and the self-test
## prints what each would produce. A playtester who sees nothing at all has one
## value to change rather than a search.
##
## ---------------------------------------------------------------------------
## What the calibration then is
## ---------------------------------------------------------------------------
##
##     impulse = degrees * ReturnSpeed * driveGain * (dt if form A else 1)
##
## which under either form makes the spring settle at exactly `degrees *
## driveGain` — so `driveGain` is a dimensionless trim around a calibration
## derived from the game's own `ReturnSpeed`, and its honest default is 1.
##
## `Damping` does not appear, and cannot: at the steady state the velocity is
## zero, and a term multiplying the velocity has nothing to act on. That is what
## makes the calibration the settled half of this file — it is true under either
## damping law.
##
## What damping decides is the transient, and this spring's natural frequency is
## sqrt(ReturnSpeed) = 0.42 Hz, which lands between the postural drift at
## 0.28 Hz and the pulse at 1.1 Hz. So the model's whole slow band sits on the
## spring's resonance, and how much of it arrives at the weapon depends entirely
## on how damped that resonance is: measured over the two candidate laws, the
## breathing band comes through at anywhere between 3% and 450%. That is the
## second assumption, it is a factor of a hundred, and it is the largest thing
## about this mod that a playtest would settle in one second and no amount of
## offline work can.

import std/math
import vec

type
  SpringCal* = object
    ## What the game's rotation spring is, as far as the calibration cares.
    returnSpeed*: float     ## the spring's own `ReturnSpeed`
    damping*: float         ## its `Damping`, for the transient only
    accelMax*: float        ## its `AccelerationMax`; 0 means "not known"
    perFrameAccel*: bool    ## form A above
    dampingPerSecond*: bool ## how `Damping` is applied; see `DampingLaw` below
    measured*: bool         ## true when these came off the live spring

  RotSpring* = object
    ## One axis of it. Three floats, exactly as the game has them.
    value*: float
    velocity*: float
    accum*: float

const
  ShippedReturnSpeed* = 7.0
    ## What this mod's own config carries for `handsRotationReturnSpeed`, used
    ## as the calibration base until the live spring can be read. It is a guess
    ## at BSG's value and it is the only place that guess is made — everything
    ## else derives from whatever number is actually here.
  ShippedDamping* = 0.55
  ShippedAccelMax* = 12.0

template defaultCal*(): SpringCal =
  ## The shipped assumption. A template rather than a proc for the reason every
  ## constructor in this mod is one — see `tuning.defaultTuning`.
  SpringCal(returnSpeed: ShippedReturnSpeed, damping: ShippedDamping,
            accelMax: ShippedAccelMax, perFrameAccel: false,
            dampingPerSecond: false, measured: false)

proc calibration*(returnSpeed, damping, accelMax: float;
                  perFrameAccel, measured: bool): SpringCal =
  SpringCal(returnSpeed: fmax(0.01, returnSpeed),
            damping: clampf(damping, 0.0, 0.999),
            accelMax: fmax(0.0, accelMax),
            perFrameAccel: perFrameAccel, dampingPerSecond: false,
            measured: measured)

proc impulseScale*(cal: SpringCal; dt: float): float =
  ## Degrees -> the number handed to `AddAcceleration`, before `driveGain`.
  ##
  ## Under form B this is frame-rate independent because the spring itself
  ## applies the `dt`; under form A it carries the `dt` here instead. Either
  ## way one degree of model output settles the spring at one degree, at any
  ## frame rate, which is the property the old `* dt * 60` was reaching for and
  ## only achieved under form A — while the gain it was paired with was
  ## computed for form B.
  let k = (if cal.perFrameAccel: clampf(dt, 0.0005, 0.05) else: 1.0)
  result = cal.returnSpeed * k

# ---------------------------------------------------------------------------
# The spring, stepped
# ---------------------------------------------------------------------------

template newSpring*(): RotSpring =
  RotSpring(value: 0.0, velocity: 0.0, accum: 0.0)

proc addAcceleration*(s: var RotSpring; a: float; accelMax: float) =
  ## What the game's method does: accumulate, and clamp on the way in. The
  ## clamp is why this mod cannot write the accumulator directly.
  var v = s.accum + a
  if accelMax > 0.0:
    v = clampf(v, -accelMax, accelMax)
  s.accum = v

proc step*(s: var RotSpring; cal: SpringCal; dt: float) =
  ## One frame of the spring.
  ##
  ## The per-frame damping is raised to `dt * 60` rather than applied once a
  ## frame, so that this stand-in is frame-rate independent and a measurement
  ## taken through it says something about the mod rather than about the step
  ## size. A literal `velocity *= 1 - Damping` — which is how such springs are
  ## usually written, BSG's included, most likely — is not, and would settle
  ## faster at higher frame rates.
  ##
  ## This is a splitting integrator either way: the return term is explicit, the
  ## damping is exact, and they are composed rather than solved together. At a
  ## damping rate of 48 per second that composition has real error at 30 fps,
  ## which is why `characterise.frameRateIndependence` measures the *mod's* half
  ## of the chain and reports the spring's separately. It does not touch the
  ## calibration, which is a steady state with no velocity in it.
  if cal.perFrameAccel:
    s.velocity = s.velocity + s.accum
  else:
    s.velocity = s.velocity + s.accum * dt
  s.accum = 0.0
  s.velocity = s.velocity - s.value * cal.returnSpeed * dt
  if cal.dampingPerSecond:
    s.velocity = s.velocity * exp(-cal.damping * dt)
  else:
    s.velocity = s.velocity * pow(fmax(0.001, 1.0 - cal.damping), dt * 60.0)
  s.value = s.value + s.velocity * dt

# ---------------------------------------------------------------------------
# The second assumption, and it is the bigger one
# ---------------------------------------------------------------------------
#
# `Damping` is a number between 0 and 1 whose only documented meaning in this
# mod's own config is "higher settles the weapon faster". Two laws fit that
# sentence and they are three orders of magnitude apart:
#
#     per frame:   velocity *= (1 - Damping)         each frame
#     per second:  velocity *= exp(-Damping * dt)    a rate, in 1/s
#
# At the shipped Damping of 0.55 the first removes 55% of the velocity every
# frame -- an effective rate of 48 per second -- and the second removes 55% per
# second. As damping ratios against this spring's own natural frequency of
# sqrt(ReturnSpeed) = 2.65 rad/s, that is zeta = 9.0 against zeta = 0.10:
# grossly overdamped against barely damped at all.
#
# It matters far more than the acceleration form does, because it decides what
# the spring does with the frequencies this mod actually produces. Overdamped,
# the spring's slow pole sits at 0.15 Hz and everything the model sends is
# attenuated to a few percent. Barely damped, its resonance sits at 0.42 Hz --
# directly between the postural drift at 0.28 Hz and the pulse at 1.1 Hz -- and
# the breathing band comes through amplified.
#
# Neither is knowable from here, and the characterisation reports both rather
# than picking one. This is the single largest unknown left in the mod and it is
# a playtest question: a shooter who fires one round knows within a second which
# of the two the game is doing.

proc naturalFreqHz*(cal: SpringCal): float =
  ## sqrt(ReturnSpeed), in hertz. Where this spring resonates, if it resonates.
  sqrt(fmax(0.0, cal.returnSpeed)) / (2.0 * PI)

proc dampingRatio*(cal: SpringCal; dt: float): float =
  ## The dimensionless zeta of the spring under whichever damping law is set.
  let wn = sqrt(fmax(1.0e-9, cal.returnSpeed))
  var rate = 0.0
  if cal.dampingPerSecond:
    rate = cal.damping
  else:
    rate = -ln(fmax(0.001, 1.0 - cal.damping)) / fmax(1.0e-6, dt)
  result = rate / (2.0 * wn)

proc reset*(s: var RotSpring) =
  s.value = 0.0
  s.velocity = 0.0
  s.accum = 0.0

# ---------------------------------------------------------------------------
# What the spring does to a signal
# ---------------------------------------------------------------------------

proc dcGain*(cal: SpringCal; dt: float): float =
  ## Degrees of spring deflection per unit of accumulated acceleration, at DC.
  ##
  ## The fixed point of `step` with a constant impulse: the velocity must be
  ## zero for the value to be constant, so the accumulated acceleration must
  ## exactly cancel the return term.
  if cal.perFrameAccel:
    result = 1.0 / fmax(1.0e-9, cal.returnSpeed * clampf(dt, 0.0005, 0.05))
  else:
    result = 1.0 / fmax(1.0e-9, cal.returnSpeed)

proc springGain*(cal: SpringCal; dt, freqHz, driveGain: float): float =
  ## The amplitude the spring settles into for one degree of model output at
  ## `freqHz`, driven exactly the way `springImpulse` drives it.
  ##
  ## Numerical rather than closed-form, because it is the *same* `step` the
  ## characterisation uses and a closed form would be a second thing that could
  ## be wrong. Ten seconds of settling, then one second of peak-finding.
  var s = newSpring()
  let scale = impulseScale(cal, dt) * driveGain
  let n = floorToInt(11.0 / dt)
  let settle = floorToInt(10.0 / dt)
  var peak = 0.0
  var i = 0
  var t = 0.0
  while i < n:
    let d = sin(2.0 * PI * freqHz * t)
    addAcceleration(s, d * scale, cal.accelMax)
    step(s, cal, dt)
    if i >= settle:
      let m = fabs(s.value)
      if m > peak:
        peak = m
    t = t + dt
    inc i
  result = peak

proc unityDriveGain*(cal: SpringCal; dt: float): float =
  ## The `driveGain` at which one degree of model output becomes one degree of
  ## spring deflection at DC. One, by construction, once `impulseScale` carries
  ## the `ReturnSpeed` — this is the check that it does.
  result = 1.0 / fmax(1.0e-9, dcGain(cal, dt) * impulseScale(cal, dt))

# ---------------------------------------------------------------------------
# Geometry
# ---------------------------------------------------------------------------
#
# A sway mod is only unplayable in units of "can you still hold the target".
# Degrees are converted here so the characterisation can assert against a
# distance rather than against a feeling.

proc metresAt*(deg, rangeM: float): float =
  ## Lateral displacement of the point of aim, at a range, for an angle.
  rangeM * tan(deg * PI / 180.0)

proc degreesFor*(metres, rangeM: float): float =
  ## The inverse: the angle that moves the aim by `metres` at `rangeM`.
  arctan(metres / fmax(0.01, rangeM)) * 180.0 / PI

# ---------------------------------------------------------------------------
# The spring against its own closed form
# ---------------------------------------------------------------------------
#
# Everything above states what the spring *is*. This states what it therefore
# *does*, in the two numbers a player can actually name after one raid: how far
# past the target it goes, and how long it takes to stop. Both follow from
# `ReturnSpeed` and `Damping` alone, both are arithmetic, and neither needed a
# game to find out — which is the whole claim `model/characterise.nim` is there
# to keep honest.
#
# The closed forms are the textbook ones for a second-order system
#
#     x'' + 2*zeta*wn*x' + wn^2*x = wn^2*u
#
# and they are stated here rather than in the characterisation because they are
# a property of the spring, not of the measurement. The characterisation's job
# is to drive `step` and check that the discrete integrator lands where these
# say it should; if it does not, one of the two is wrong and that is worth
# finding out before a raid rather than during one.

proc analyticOvershoot*(zeta: float): float =
  ## Peak overshoot of a unit step, as a fraction above the steady state.
  ## Zero at and above critical damping: an overdamped system never crosses its
  ## target, so there is nothing to overshoot by.
  if zeta >= 1.0:
    return 0.0
  let z = clampf(zeta, 0.0, 0.999)
  result = exp(-PI * z / sqrt(1.0 - z * z))

proc analyticSettle*(zeta, wn: float): float =
  ## Time for a unit step to stay inside 2% of its steady state, in seconds.
  ##
  ## Two regimes and they are genuinely different systems, which is exactly why
  ## the damping law matters so much here:
  ##
  ## * underdamped (zeta < 1): the envelope decays at `zeta * wn`, so 2% takes
  ##   the familiar `4 / (zeta * wn)`.
  ## * overdamped (zeta >= 1): there is no envelope, there are two real poles,
  ##   and the slow one at `wn * (zeta - sqrt(zeta^2 - 1))` is what is left at
  ##   the end. For large zeta that pole tends to `wn / (2*zeta)` — so *more*
  ##   damping settles *slower*, which is the counter-intuitive half of this and
  ##   the reason the overdamped candidate is not simply the safe one.
  let w = fmax(1.0e-9, wn)
  if zeta < 1.0:
    result = 4.0 / fmax(1.0e-9, clampf(zeta, 1.0e-6, 0.999) * w)
  else:
    let slow = w * (zeta - sqrt(fmax(0.0, zeta * zeta - 1.0)))
    result = 4.0 / fmax(1.0e-9, slow)

type
  StepResponse* = object
    ## What `step` actually does when handed a constant acceleration, measured
    ## rather than predicted. `spring.dcGain` says where it should end up;
    ## everything else here is the transient.
    steady*: float        ## measured tail value, degrees per unit acceleration
    peak*: float          ## largest value reached
    overshoot*: float     ## peak / steady - 1
    settle*: float        ## seconds until it stayed inside 2% of steady
    rise*: float          ## seconds to first reach 90% of steady
    finite*: bool

proc stepResponse*(cal: SpringCal; dt, seconds: float): StepResponse =
  ## Drive the spring with a constant unit acceleration from rest and watch it.
  ##
  ## `AccelerationMax` is deliberately not applied: this measures the spring's
  ## *linear* response, and the clamp is a separate, separately-checked thing.
  ## A unit drive is the right scale because the spring is linear — every number
  ## here is per unit of accumulated acceleration and scales exactly.
  let target = dcGain(cal, dt)
  let band = 0.02 * target
  var s = newSpring()
  let want = floorToInt(seconds / fmax(0.0001, dt))
  let n = (if want < 1: 1 else: want)
  var i = 0
  var t = 0.0
  var peak = 0.0
  var lastOut = 0.0
  var rise = -1.0
  var tailSum = 0.0
  var tailN = 0
  let tailFrom = n - (n div 10)
  var finite = true
  while i < n:
    addAcceleration(s, 1.0, 0.0)
    step(s, cal, dt)
    t = t + dt
    if not isFinite(s.value):
      finite = false
      break
    if s.value > peak:
      peak = s.value
    if rise < 0.0 and s.value >= 0.9 * target:
      rise = t
    if fabs(s.value - target) > band:
      lastOut = t
    if i >= tailFrom:
      tailSum = tailSum + s.value
      inc tailN
    inc i
  result = StepResponse(
    steady: tailSum / fmax(1.0, float(tailN)),
    peak: peak,
    overshoot: (if target > 0.0: peak / target - 1.0 else: 0.0),
    settle: lastOut,
    rise: (if rise < 0.0: seconds else: rise),
    finite: finite)

proc saturation*(cal: SpringCal; dt: float): float =
  ## The most deflection this spring can hold, in degrees, no matter what is
  ## pushed into it: `AccelerationMax` is a clamp on the accumulator, so the
  ## largest steady state is that clamp times the spring's DC gain.
  ##
  ## This is the dimensional argument at the top of this file written as one
  ## call. Under the per-second form the shipped clamp of 12 admits 1.7 degrees
  ## of weapon rotation; under the per-frame form the same clamp admits sixty
  ## times as much, which is a weapon that has left the screen. A clamp constant
  ## is only meaningful at the scale of the thing it clamps, and that is the
  ## whole of the evidence for the default.
  if cal.accelMax <= 0.0:
    return 0.0
  result = cal.accelMax * dcGain(cal, dt)
