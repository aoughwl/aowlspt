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
import spring

type
  SwayOutput* = object
    ## What one frame of the model produced, in degrees.
    hands*: Vec3
    camera*: Vec3
    multiplier*: float     ## The global multiplier that frame, for the readout.
    raw*: Vec3             ## `hands` before the output ceiling. What the tuning asked for.
    clipped*: bool         ## Whether the ceiling had to act this frame.

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
                     multiplier: 1.0,
                     raw: Vec3(x: 0.0, y: 0.0, z: 0.0),
                     clipped: false))

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
    d.last = SwayOutput(hands: Zero3, camera: Zero3, multiplier: 1.0,
                        raw: Zero3, clipped: false)
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

  # The ceiling, last, on the sum.
  #
  # Every source has its own amplitude and several have their own limits, and
  # none of that bounds the *product*: master intensity, the ADS master, the
  # stance multiplier, hold fatigue, the exhausted multiplier, a fracture, a
  # blacked arm and a burst's shot charge all multiply, and a config a player
  # can edit will eventually be edited into a weapon that leaves the screen.
  # This is the one number that cannot be multiplied past.
  #
  # Applied to the sum rather than per source, and by `clampMagnitude` rather
  # than per axis, so a clipped frame still points where the unclipped one did.
  # The camera takes the same ceiling scaled by its coupling, because a view
  # that is thrown around is worse than a weapon that is.
  let ceiling = fmax(0.05, t.outputCeiling)
  let rawHands = handsSum
  let m2 = sqrMagnitude(handsSum)
  var clipped = false
  if m2 > ceiling * ceiling:
    clipped = true
    handsSum = clampMagnitude(handsSum, ceiling)
  let camCeiling = fmax(0.01, ceiling * fmax(0.05, t.cameraCoupling))
  if sqrMagnitude(cameraSum) > camCeiling * camCeiling:
    clipped = true
    cameraSum = clampMagnitude(cameraSum, camCeiling)

  # A non-finite value can only arrive from a tuning that is itself non-finite —
  # every operation above is a product or a sum of bounded terms otherwise — but
  # it would reach `AddAcceleration` and put a NaN into the game's spring, which
  # never comes back out. Refusing the frame is the only safe answer.
  if not isFinite(handsSum) or not isFinite(cameraSum):
    d.last = SwayOutput(hands: Zero3, camera: Zero3, multiplier: global,
                        raw: Zero3, clipped: true)
    reset(d.handsFilter)
    reset(d.cameraFilter)
    reset(d.inertia)
    return d.last

  d.last = SwayOutput(hands: handsSum, camera: cameraSum, multiplier: global,
                      raw: rawHands, clipped: clipped)
  result = d.last

proc springImpulse*(v: Vec3; t: Tuning; cal: SpringCal; dt: float): Vec3 =
  ## Model output in degrees -> the acceleration BSG's rotation springs expect.
  ##
  ## The whole conversion is `degrees * ReturnSpeed * driveGain`, plus a `dt`
  ## if the spring accumulates raw acceleration rather than acceleration per
  ## second. Under either form the spring settles at `degrees * driveGain`, at
  ## any frame rate — which is what the old `* dt * 60` was reaching for and did
  ## not achieve, because the gain it was paired with had been computed for the
  ## other form. `model/spring.nim` is the derivation and
  ## `tuning.DriveGainProvenance` is the short version.
  ##
  ## `cal` comes off the live spring where `game/live.nim` can read it and off
  ## this mod's own shipped defaults where it cannot. Nothing in this file knows
  ## which.
  v * (impulseScale(cal, dt) * t.driveGain)
