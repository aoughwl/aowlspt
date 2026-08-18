## The whole model, in one object, driven once per frame.
##
## The signal chain is deliberately linear and in one place, so that any number
## you see in the readout can be traced back to exactly one config entry:
##
##   sources -> per-source ADS/hip weights -> handling -> fatigue -> injury ->
##   support/stance -> shot disturbance -> master -> springs
##
## `tick` is the entire public surface, and it takes no game object: a state
## record in, two vectors out. That is what makes the model runnable under
## `aowlspt-sim`, and it is the reason this file is in `model/` rather than
## next to the code that talks to EFT.

import vec
import filters
import tuning
import state
import sources

type
  SwayOutput* = object
    ## What one frame of the model produced, in degrees.
    hands*: Vec3
    camera*: Vec3
    multiplier*: float     ## The global multiplier that frame, for the readout.

  SwayDirector* = object
    breath*: Respiration
    heart*: Cardiac
    shake*: Tremor
    drift*: PosturalDrift
    inertia*: WeaponInertia

    holdFatigue*: float
    shotCharge*: float

    handsFilter*: OnePole
    cameraFilter*: OnePole

    last*: SwayOutput

template newDirector*(): SwayDirector =
  ## A template, not a proc: a global initialised by a call is left zeroed in a
  ## nimony `--app:lib` build. See `tuning.defaultTuning`.
  SwayDirector(
    breath: newRespiration(),
    heart: newCardiac(),
    shake: newTremor(),
    drift: newPosturalDrift(),
    inertia: newWeaponInertia(),
    holdFatigue: 0.0,
    shotCharge: 0.0,
    handsFilter: OnePole(state: Vec3(x: 0.0, y: 0.0, z: 0.0), primed: false),
    cameraFilter: OnePole(state: Vec3(x: 0.0, y: 0.0, z: 0.0), primed: false),
    last: SwayOutput(hands: Vec3(x: 0.0, y: 0.0, z: 0.0),
                     camera: Vec3(x: 0.0, y: 0.0, z: 0.0),
                     multiplier: 1.0))

proc onWeaponChanged*(d: var SwayDirector) =
  ## A new weapon means a stale inertia state to throw away, and a smoothing
  ## filter primed on the old weapon's output.
  reset(d.inertia)
  reset(d.handsFilter)
  reset(d.cameraFilter)

proc onShot*(d: var SwayDirector; t: Tuning) =
  if not t.shotEnabled:
    return
  d.shotCharge = fmin(d.shotCharge + t.shotGain, t.shotMaxAccumulation)
  addShotKick(d.heart, t.shotHeartRateKick)

proc globalMultiplier(d: var SwayDirector; s: ShooterState; t: Tuning;
                      dt: float): float =
  var m = t.masterIntensity

  m = m * (if s.isAiming: t.adsMaster else: t.hipMaster)
  m = m * s.supportFactor

  if t.fatigueEnabled:
    # Holding an aim is work. It builds while the weapon is up and drains once
    # it comes down, which is why you cannot solve a long overwatch by simply
    # never lowering the rifle.
    let target = (if s.isAiming: t.holdFatigueMax else: 0.0)
    let rate = (if s.isAiming: t.holdFatigueRate else: t.holdFatigueDecay)
    d.holdFatigue = moveTowards(d.holdFatigue, target, rate * dt)
    m = m * (1.0 + d.holdFatigue)

    if s.exhausted:
      m = m * t.exhaustedMultiplier

  if t.injuryEnabled:
    if s.armFractured: m = m * t.armFractureMultiplier
    if s.armBlacked: m = m * t.armBlackedMultiplier

  d.shotCharge = fmax(0.0, d.shotCharge - dt * t.shotDecay)
  m = m * (1.0 + d.shotCharge)

  result = m

proc tick*(d: var SwayDirector; s: var ShooterState; t: Tuning;
           dtIn: float): SwayOutput =
  ## One frame. `s` is updated in place — `derive` fills in its three derived
  ## fields — and the result is the degrees of rotation to hand the springs.
  ##
  ## Call `drive` on `d.inertia` before this, with the frame's view angles.

  # A hitch or an alt-tab must not be allowed to integrate a spring across half
  # a second of missing time.
  let dt = clampf(dtIn, 0.0005, 0.05)

  if not t.enabled:
    d.last = SwayOutput(hands: Zero3, camera: Zero3, multiplier: 1.0)
    return d.last

  derive(s, t, dt)

  let resp = evaluate(d.breath, s, t, dt)
  let heart = evaluate(d.heart, s, t, dt)
  let tremor = evaluate(d.shake, s, t, dt)
  let drift = evaluate(d.drift, s, t, dt)
  let inertia = evaluate(d.inertia, s, t, dt)

  let global = globalMultiplier(d, s, t, dt)

  # Handling scales the sources the shooter's grip actually governs. Inertia is
  # excluded because weapon mass already shapes it inside the oscillator, and
  # scaling it twice makes heavy guns unusable.
  let handling = s.handlingFactor

  var handsSum = resp * handling +
                 heart * handling +
                 tremor * handling +
                 drift +
                 inertia
  handsSum = handsSum * global

  # The camera takes a configurable share of each source. Sending everything to
  # the weapon alone looks fake, and sending everything to the camera makes the
  # game unplayable, so it is per-source.
  let cc = t.cameraCoupling
  var cameraSum = Zero3
  if cc > 0.0:
    cameraSum = (resp * (t.cameraRespShare * handling) +
                 heart * (t.cameraHeartShare * handling) +
                 tremor * (t.cameraTremorShare * handling) +
                 drift * t.cameraDriftShare +
                 inertia * t.cameraInertiaShare) * (cc * global)

  # One low-pass across the summed output rather than one per source. Filtering
  # the sum keeps the sources in phase with each other; the per-source
  # alternative would smear them apart in time and the breathing would stop
  # lining up with the pulse riding on it.
  let cutoff = t.outputSmoothing
  handsSum = filter(d.handsFilter, handsSum, dt, cutoff)
  cameraSum = filter(d.cameraFilter, cameraSum, dt, cutoff)

  d.last = SwayOutput(hands: handsSum, camera: cameraSum, multiplier: global)
  result = d.last

proc springImpulse*(v: Vec3; t: Tuning; dt: float): Vec3 =
  ## Model output in degrees -> the acceleration BSG's rotation springs expect.
  ##
  ## The springs are stepped on the physics clock while the model runs on the
  ## render clock, so the impulse is normalised to a 60 Hz frame. Without this
  ## the whole mod would be twice as strong at 120 fps.
  ##
  ## `driveGain` is the other half of the conversion, and the one number in
  ## this mod that has never been verified against the running game — see
  ## `tuning.DriveGainProvenance`.
  v * (clampf(dt, 0.0005, 0.05) * 60.0 * t.driveGain)
