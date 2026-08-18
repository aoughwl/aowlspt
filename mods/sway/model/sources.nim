## The five physical sources of sway.
##
## Each one produces degrees of rotation as (pitch, yaw, roll) and knows
## nothing about the others. The C# expressed that with an `ISwaySource`
## interface; there is no interface here and none is needed — the director
## calls all five by name, which is what the C# did through the interface
## anyway, and a virtual call per source per frame bought nothing.
##
## Everything in this file is arithmetic on a `Tuning` and a `ShooterState`.
## No clock, no engine, no game.

import std/math
import vec
import noise
import filters
import tuning
import state

# =====================================================================
# 01 Respiration
# =====================================================================
#
# Breathing. The slowest and largest source, and the one a shooter times their
# trigger break against.
#
# The waveform is not a sine. A real breath rises quickly, falls more slowly,
# and then sits still for a moment at the bottom before the next one starts.
# That still moment is the whole point: it is the window you fire in, and a
# sine has no such window.

type
  Respiration* = object
    phase*: float
    cycleJitter*: float
    holdBlend*: float
    rebound*: float
    wasHolding*: bool
    clock*: float          ## Seconds of model time, only used to decorrelate the jitter.
    rateBpm*: float        ## The live rate, for the debug readout.
    dc*: DcBlocker

template newRespiration*(): Respiration =
  Respiration(phase: 0.0, cycleJitter: 1.0, holdBlend: 1.0, rebound: 0.0,
              wasHolding: false, clock: 0.0, rateBpm: 14.0,
              dc: DcBlocker(mean: 0.0, primed: false))

proc reset*(r: var Respiration) =
  r.phase = 0.0
  r.holdBlend = 1.0
  r.rebound = 0.0
  r.wasHolding = false
  reset(r.dc)

proc waveform(r: Respiration; t: Tuning; p: float): float =
  var ti = fmax(0.01, t.respInhaleFraction)
  var te = fmax(0.01, t.respExhaleFraction)
  let tp = fmax(0.0, t.respPauseFraction)
  let sum = ti + te + tp
  ti = ti / sum
  te = te / sum

  var shaped = 0.0
  if p < ti:
    # Inhale: brisk, muscular, accelerating out of the pause.
    let u = p / ti
    shaped = u * u * (3.0 - 2.0 * u)
  elif p < ti + te:
    # Exhale: passive elastic recoil of the chest wall, so it starts fast and
    # trails off rather than mirroring the inhale.
    let u = (p - ti) / te
    shaped = 1.0 - (1.0 - exp(-3.2 * u)) / (1.0 - exp(-3.2))
  else:
    shaped = 0.0

  let sine = 0.5 - 0.5 * cos(p * 2.0 * PI)
  let k = t.respWaveformSharpness

  if k <= 1.0:
    return sine + (shaped - sine) * clamp01(k)

  # Past 1 the shape gets pushed further from the sine, exaggerating the pause
  # without changing the period.
  let extra = clamp01(k - 1.0)
  result = lerpf(shaped, pow(shaped, 1.0 + extra * 1.5), extra)

proc evaluate*(r: var Respiration; s: ShooterState; t: Tuning;
               dt: float): Vec3 =
  if not t.respEnabled:
    return Zero3

  r.clock = r.clock + dt

  let oxyDebt = clamp01((1.0 - s.oxygen) * t.respOxygenInfluence)
  let drive = clamp01(fmax(s.exertion, oxyDebt))

  r.rateBpm = lerpf(t.respRateRest, t.respRateExhausted, drive) * r.cycleJitter

  let prev = r.phase
  r.phase = r.phase + (r.rateBpm / 60.0) * dt * t.globalTimeScale

  if r.phase >= 1.0:
    r.phase = r.phase - floor(r.phase)
    # Re-roll the jitter once per breath rather than per frame, so breaths
    # differ from each other instead of shimmering. The second term was
    # `Time.time` in the C#; the model has no engine clock, so it uses its own
    # accumulated seconds, which serves the same purpose of decorrelating one
    # breath's jitter from the next.
    let irr = t.respIrregularity
    r.cycleJitter = 1.0 + signed(prev * 13.37 + r.clock * 0.1, 4801) * irr * 0.35

  # Yaw and roll are not scaled copies of pitch. A chest expanding moves the
  # shoulders on a slightly later schedule than the sternum, so the off-axis
  # components lag by a fraction of a breath. Sampling the same waveform at a
  # small phase offset gives that, and keeps the motion an ellipse rather than
  # a straight diagonal line.
  var wPitch = waveform(r, t, r.phase)
  var wYaw = waveform(r, t, frac(r.phase + 0.09))
  var wRoll = waveform(r, t, frac(r.phase + 0.17))

  # One shared mean, so the three axes stay in step with each other while still
  # being individually centred.
  let mean = track(r.dc, wPitch, dt, 6.0)
  wPitch = wPitch - mean
  wYaw = wYaw - mean
  wRoll = wRoll - mean

  # Breath hold. The chest does not lock solid, it just gets very quiet, and
  # then pays for it when you let go.
  let holding = s.holdingBreath
  let holdTarget = (if holding: t.respHoldSuppression else: 1.0)
  r.holdBlend = lerpf(r.holdBlend, holdTarget, clamp01(dt * 8.0))

  if r.wasHolding and not holding:
    r.rebound = t.respHoldReboundGain - 1.0
  r.wasHolding = holding
  r.rebound = fmax(0.0, r.rebound - dt * t.respHoldReboundDecay)

  var amp = t.respAmplitude *
            r.holdBlend *
            (1.0 + r.rebound) *
            (1.0 + drive * 0.9) *
            0.55                      # degrees at amplitude 1

  amp = amp * (if s.isAiming: t.respAds else: t.respHip)

  result = vec3(wPitch * t.respPitch,
                wYaw * t.respYaw,
                wRoll * t.respRoll) * amp

# =====================================================================
# 02 Cardiac
# =====================================================================
#
# The heartbeat, transmitted through the chest and the support arm into the
# weapon. Tiny at rest and impossible to ignore through magnification after a
# sprint.
#
# The waveform is a sharp systolic spike followed by a smaller dicrotic bump
# where the aortic valve slams shut. That second bump is what stops a pulse
# reading as a sine wave to the eye.

type
  Cardiac* = object
    phase*: float
    bpm*: float
    shotKick*: float
    dc*: DcBlocker

template newCardiac*(): Cardiac =
  Cardiac(phase: 0.0, bpm: 65.0, shotKick: 0.0,
          dc: DcBlocker(mean: 0.0, primed: false))

proc reset*(c: var Cardiac; t: Tuning) =
  c.phase = 0.0
  c.bpm = t.heartRateRest
  c.shotKick = 0.0
  reset(c.dc)

proc addShotKick*(c: var Cardiac; bpm: float) =
  c.shotKick = fmin(c.shotKick + bpm, 60.0)

proc beat(c: Cardiac; t: Tuning; p: float): float =
  const systoleWidth = 0.30
  let k = t.heartSystolicSharpness

  var systole = 0.0
  if p < systoleWidth:
    systole = pow(sin(PI * p / systoleWidth), k)

  let d = t.heartDicroticDelay
  let dw = systoleWidth * 0.8
  var dicrotic = 0.0
  if p >= d and p < d + dw:
    dicrotic = pow(sin(PI * (p - d) / dw), k * 1.4) * t.heartDicroticStrength

  result = systole + dicrotic

proc evaluate*(c: var Cardiac; s: ShooterState; t: Tuning; dt: float): Vec3 =
  if not t.heartEnabled:
    return Zero3

  let target = lerpf(t.heartRateRest, t.heartRateMax, s.exertion) + c.shotKick

  # The heart climbs faster than it comes down, which is why you can sprint
  # into a fight and then wait a long time to settle.
  let speed = (if target > c.bpm: t.heartRateRise else: t.heartRateFall)
  c.bpm = lerpf(c.bpm, target, clamp01(dt * speed * 2.0))
  c.shotKick = fmax(0.0, c.shotKick - dt * 6.0)

  c.phase = c.phase + (c.bpm / 60.0) * dt * t.globalTimeScale
  c.phase = c.phase - floor(c.phase)

  var b = beat(c, t, c.phase)
  b = apply(c.dc, b, dt, 3.0)

  let exertionGain = 1.0 + s.exertion * t.heartExertionGain
  var amp = t.heartAmplitude * exertionGain * 0.085
  amp = amp * (if s.isAiming: t.heartAds else: t.heartHip)

  # A pulse arrives as one push, not as three independent wobbles, so all three
  # axes share the same waveform and differ only in weight.
  result = vec3(b * t.heartPitch, b * t.heartYaw, b * t.heartRoll) * amp

# =====================================================================
# 03 Physiological tremor
# =====================================================================
#
# The 8-12 Hz shimmer that every human hand has and no amount of training
# removes. Fatigue widens it, weapon weight widens it, and magnification makes
# it obvious.

type
  Tremor* = object
    clock*: float

template newTremor*(): Tremor = Tremor(clock: 0.0)

proc reset*(x: var Tremor) = x.clock = 0.0

proc evaluate*(x: var Tremor; s: ShooterState; t: Tuning; dt: float): Vec3 =
  if not t.tremorEnabled:
    return Zero3

  x.clock = x.clock + dt * t.globalTimeScale
  let f = t.tremorFrequency
  let oct = clampi(t.tremorOctaves, 1, 6)
  let spread = t.tremorFrequencySpread

  let nx = fractal(x.clock * f, 101, oct, spread)
  let ny = fractal(x.clock * f, 227, oct, spread)
  let nz = fractal(x.clock * f, 353, oct, spread)

  let fatigue = 1.0 + s.exertion * t.tremorFatigueGain

  let refW = fmax(0.1, t.weightReference)
  let load = 1.0 + fmax(0.0, (s.weightKg - refW) / refW) * t.tremorLoadGain

  var injury = 1.0
  if t.injuryEnabled:
    let g = t.tremorInjuryGain
    if s.armFractured: injury = injury + g * 0.6
    if s.armBlacked: injury = injury + g * 0.4
    if s.neuroTremor: injury = injury + g * 0.5

  var amp = t.tremorAmplitude * fatigue * load * injury * 0.06
  amp = amp * (if s.isAiming: t.tremorAds else: t.tremorHip)

  result = vec3(nx * t.tremorPitch, ny * t.tremorYaw, nz * t.tremorRoll) * amp

# =====================================================================
# 04 Postural drift
# =====================================================================
#
# The slow wander of a standing body correcting its own balance, well under
# 1 Hz. It is why a rested shooter with a light rifle still cannot pin a dot to
# a target, and it mostly disappears once you go prone or put the weapon on
# something.

type
  PosturalDrift* = object
    clock*: float

template newPosturalDrift*(): PosturalDrift = PosturalDrift(clock: 0.0)

proc reset*(d: var PosturalDrift) = d.clock = 0.0

proc evaluate*(d: var PosturalDrift; s: ShooterState; t: Tuning;
               dt: float): Vec3 =
  if not t.driftEnabled:
    return Zero3

  d.clock = d.clock + dt * t.globalTimeScale
  let f = t.driftFrequency

  let nx = fractal(d.clock * f, 1901, 2, 0.4)
  let ny = fractal(d.clock * f, 2903, 2, 0.4)
  let nz = fractal(d.clock * f, 3907, 2, 0.4)

  # Walking is a balance problem, so it feeds the same source.
  let move = 1.0 + clamp01(s.moveSpeed / 4.0) * t.driftMoveGain
  let fatigue = 1.0 + s.exertion * 0.8

  var amp = t.driftAmplitude * move * fatigue * 0.22
  amp = amp * (if s.isAiming: t.driftAds else: t.driftHip)

  result = vec3(nx * t.driftPitch, ny * t.driftYaw, nz * t.driftRoll) * amp

# =====================================================================
# 05 Weapon inertia
# =====================================================================
#
# The weapon is a mass on the end of two compliant arms, so it trails a turn
# going in and overshoots coming out.
#
# This is a real damped harmonic oscillator driven by the turn rate rather than
# a lerp-toward-zero, which is what gives the overshoot its shape: a heavy
# weapon does not just move less, it moves later and settles for longer, and
# the config exposes both halves of that separately.

type
  WeaponInertia* = object
    x*: Vec3               ## current deflection, degrees
    v*: Vec3               ## rate of change
    target*: Vec3
    lastYaw*: float
    lastPitch*: float
    lastVelocity*: Vec3
    primed*: bool
    yawRate*: OnePole1
    pitchRate*: OnePole1

template newWeaponInertia*(): WeaponInertia =
  WeaponInertia(x: Vec3(x: 0.0, y: 0.0, z: 0.0),
                v: Vec3(x: 0.0, y: 0.0, z: 0.0),
                target: Vec3(x: 0.0, y: 0.0, z: 0.0),
                lastYaw: 0.0, lastPitch: 0.0,
                lastVelocity: Vec3(x: 0.0, y: 0.0, z: 0.0),
                primed: false,
                yawRate: OnePole1(state: 0.0, primed: false),
                pitchRate: OnePole1(state: 0.0, primed: false))

proc reset*(w: var WeaponInertia) =
  w.x = Zero3
  w.v = Zero3
  w.target = Zero3
  w.primed = false
  reset(w.yawRate)
  reset(w.pitchRate)

proc drive*(w: var WeaponInertia; yawDeg, pitchDeg: float;
            playerVelocity: Vec3; s: ShooterState; t: Tuning; dt: float) =
  ## Feed the oscillator this frame's view angles and body velocity.
  ##
  ## The angles are taken from where the view actually ended up rather than
  ## from raw mouse input, so sensitivity changes, controllers and any mod that
  ## moves the view all feed inertia the same way.
  if not w.primed:
    w.lastYaw = yawDeg
    w.lastPitch = pitchDeg
    w.lastVelocity = playerVelocity
    w.primed = true
    return

  let clampDeg = t.inertiaTurnClamp
  let h = fmax(dt, 0.0001)

  var dYaw = deltaAngle(w.lastYaw, yawDeg) / h
  var dPitch = deltaAngle(w.lastPitch, pitchDeg) / h
  w.lastYaw = yawDeg
  w.lastPitch = pitchDeg

  dYaw = clampf(dYaw, -clampDeg, clampDeg)
  dPitch = clampf(dPitch, -clampDeg, clampDeg)

  # Turn rate is a difference between two frames, so it inherits the frame
  # clock's jitter on top of the actual hand movement. Left raw it makes the
  # weapon twitch when nothing moved, which reads as the mod being broken
  # rather than as the weapon being heavy.
  let inSmooth = t.inertiaInputSmoothing
  dYaw = filter(w.yawRate, dYaw, dt, inSmooth)
  dPitch = filter(w.pitchRate, dPitch, dt, inSmooth)

  var accel = (playerVelocity - w.lastVelocity) * (1.0 / h)
  w.lastVelocity = playerVelocity
  accel = clampMagnitude(accel, 40.0)

  # Heavier weapons take a larger impulse from the same turn, because the arms
  # have to fight more angular momentum.
  let refW = fmax(0.1, t.weightReference)
  let mass = 1.0 + fmax(-0.6, (s.weightKg - refW) / refW) * t.inertiaMassCoupling

  let gain = t.inertiaStrength * mass * 0.0016
  let moveGain = t.inertiaMoveGain * 0.004

  w.target = vec3(-dPitch * gain,
                  -dYaw * gain,
                  -dYaw * gain * t.inertiaRollCoupling)

  w.target = w.target + vec3(accel.y, 0.0, -accel.x) * moveGain

proc evaluate*(w: var WeaponInertia; s: ShooterState; t: Tuning;
               dt: float): Vec3 =
  if not t.inertiaEnabled:
    w.x = Zero3
    w.v = Zero3
    return Zero3

  # Stiffer arms mean a higher natural frequency; a heavy weapon on the same
  # arms lowers it, which is the whole reason a machine gun feels sluggish and
  # a pistol feels twitchy.
  let refW = fmax(0.1, t.weightReference)
  let massRatio = clampf(s.weightKg / refW, 0.35, 3.5)
  let f = t.inertiaFrequency / sqrt(massRatio)

  let omega = 2.0 * PI * fmax(0.05, f)
  let zeta = t.inertiaDamping

  # Semi-implicit integration, and a substep cap so a frame spike cannot make
  # the spring explode.
  let steps = clampi(ceilToInt(dt * omega / 0.4), 1, 8)
  let h = dt / float(steps)

  var i = 0
  while i < steps:
    let a = (w.target - w.x) * (omega * omega) - w.v * (2.0 * zeta * omega)
    w.v = w.v + a * h
    w.x = w.x + w.v * h
    inc i

  w.x = clampMagnitude(w.x, t.inertiaMaxDeflection)

  let ads = (if s.isAiming: t.inertiaAds else: t.inertiaHip)
  result = w.x * ads
