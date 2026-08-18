## Every number the sway model uses.
##
## In the BepInEx original this was ~150 `ConfigEntry<T>` statics bound into the
## F12 menu. Here it is one record, and the record is the only way the model is
## configured: nothing in `model/` reads a file, a host, or a global the game
## owns. That is what lets `aowlspt-sim` tick the whole thing.
##
## The field order is the C# section order, which is the signal-chain order:
## sources first, then the modifiers that scale them, then the raw BSG values
## the mod writes on top. Keeping that order means a number you see on screen
## can be traced down this file in the direction the signal actually travels.
##
## Ranges from the C# `AcceptableValueRange` are recorded in the comments rather
## than enforced. A JSON config has no slider to constrain, and silently
## clamping a number a user typed is worse than letting them see what it does —
## but the sane band is still worth writing down.

type
  Preset* = enum
    ## `psCustom` is not in the C# enum. It is what "the config.json is the
    ## truth, leave it alone" is called here, and it is the default: the C#
    ## applied a preset only when you ticked a box in the F12 menu, and a JSON
    ## file has no box to tick.
    psCustom, psVanilla, psArcade, psRealistic, psHardcore, psCinematic,
    psMarksman

  Tuning* = object
    # ================= 00 General =====================================
    enabled*: bool                  ## Master switch. Off means stock EFT behaviour.
    preset*: Preset                 ## Applied over the file's values at load; psCustom leaves them alone.
    masterIntensity*: float         ## 0..5. Scales every sway source at once. The one knob to turn if you only turn one.
    adsMaster*: float               ## 0..5. Extra scale applied while aiming down sights.
    hipMaster*: float               ## 0..5. Extra scale applied while hipfiring.
    globalTimeScale*: float         ## 0.1..4. Speeds up or slows every oscillator. Below 1 drowsy, above 1 jittery.
    keepVanillaSway*: bool          ## Leave BSG's own sway running underneath.
    outputSmoothing*: float         ## 0..60 Hz. Low-pass on everything the model produces, before the springs.
                                    ## The anti-jitter knob: lower is smoother and eventually mushy, higher lets
                                    ## sharp detail like the pulse spike and the tremor through. 0 disables it.

    # ================= 01 Respiration =================================
    respEnabled*: bool              ## Chest movement from breathing. The slow, dominant wander.
    respAmplitude*: float           ## 0..5. Size of the breathing arc.
    respRateRest*: float            ## 4..40 bpm. Breaths per minute with full stamina; 12-16 is a calm adult.
    respRateExhausted*: float       ## 4..80 bpm. Breaths per minute at zero stamina.
    respInhaleFraction*: float      ## 0.05..0.9. Share of the cycle breathing in. Real breathing runs about 1:2 in to out.
    respExhaleFraction*: float      ## 0.05..0.9. Share of the cycle breathing out.
    respPauseFraction*: float       ## 0..0.7. Still moment at the bottom. This is the window a real shooter fires in.
    respWaveformSharpness*: float   ## 0..3. 0 is a plain sine, 1 the asymmetric in-out-hold shape, higher exaggerates it.
    respPitch*: float               ## -3..3. Vertical share. Breathing is mostly vertical.
    respYaw*: float                 ## -3..3. Horizontal share.
    respRoll*: float                ## -3..3. Cant share.
    respAds*: float                 ## 0..3. Shouldering the stock damps the chest, it does not stop it.
    respHip*: float                 ## 0..3. Nothing braces the weapon at the hip.
    respHoldSuppression*: float     ## 0..1. What is left of the arc while holding breath. 0 freezes it completely.
    respHoldReboundGain*: float     ## 1..4. How hard breathing overshoots after a held breath is released.
    respHoldReboundDecay*: float    ## 0.05..3 per second. How fast that overshoot settles.
    respOxygenInfluence*: float     ## 0..3. How much low oxygen drives rate and amplitude up.
    respIrregularity*: float        ## 0..1. Breath-to-breath variation. Zero is metronomic and reads as fake.

    # ================= 02 Cardiac =====================================
    heartEnabled*: bool             ## Heartbeat pushed through the rifle. Small, sharp, the thing people notice through a scope.
    heartAmplitude*: float          ## 0..5. Size of the pulse kick.
    heartRateRest*: float           ## 30..120 bpm. Heart rate with full stamina.
    heartRateMax*: float            ## 60..220 bpm. Heart rate when spent.
    heartRateRise*: float           ## 0.05..5 per second. How fast the heart climbs under exertion.
    heartRateFall*: float           ## 0.02..5 per second. How fast it comes back down. Slower than it climbs, as in life.
    heartSystolicSharpness*: float  ## 1..24. Higher makes each beat a tighter spike instead of a soft swell.
    heartDicroticStrength*: float   ## 0..1. The smaller second bump of each beat, from the aortic valve closing.
                                    ## Subtle, but it is why a heartbeat does not read as a sine.
    heartDicroticDelay*: float      ## 0.05..0.9. Where in the beat that second bump lands.
    heartPitch*: float              ## -3..3. Vertical share.
    heartYaw*: float                ## -3..3. Horizontal share.
    heartRoll*: float               ## -3..3. Cant share.
    heartAds*: float                ## 0..3. A shouldered rifle transmits the pulse better, and the sight magnifies it.
    heartHip*: float                ## 0..3. Barely readable from the hip.
    heartExertionGain*: float       ## 0..5. Extra pulse amplitude when the heart is racing.

    # ================= 03 Physiological tremor ========================
    tremorEnabled*: bool            ## The 8-12 Hz shimmer every human hand has. Never still, never repeating.
    tremorAmplitude*: float         ## 0..5. Size of the shimmer.
    tremorFrequency*: float         ## 1..30 Hz. Physiological tremor sits around 8-12 Hz.
    tremorFrequencySpread*: float   ## 0..1. Detunes the layers so the tremor never locks into a pattern.
    tremorOctaves*: int             ## 1..6. How many detuned noise layers to stack. More costs a little CPU.
    tremorFatigueGain*: float       ## 0..8. How much a spent shooter shakes compared to a fresh one.
    tremorLoadGain*: float          ## 0..6. How much a heavy, unwieldy weapon adds.
    tremorPitch*: float             ## -3..3. Vertical share.
    tremorYaw*: float               ## -3..3. Horizontal share.
    tremorRoll*: float              ## -3..3. Cant share.
    tremorAds*: float               ## 0..3. Longer sight radius makes the same wobble far more visible.
    tremorHip*: float               ## 0..3. Hard to see without sights.

    # ================= 04 Postural drift ==============================
    driftEnabled*: bool             ## Standing balance drift. Sub-hertz, wide, and why a rested shooter still cannot hold a dot still.
    driftAmplitude*: float          ## 0..5. Size of the wander.
    driftFrequency*: float          ## 0.02..3 Hz. Body sway lives around 0.2-0.5 Hz.
    driftPitch*: float              ## -3..3. Vertical share.
    driftYaw*: float                ## -3..3. Horizontal share. Balance drift is wider than it is tall.
    driftRoll*: float               ## -3..3. Cant share.
    driftAds*: float                ## 0..3. A tighter stance trims it a little.
    driftHip*: float                ## 0..3. Unchanged from the hip.
    driftMoveGain*: float           ## 0..6. Extra drift while walking, on top of BSG's own step bob.

    # ================= 05 Weapon inertia ==============================
    inertiaEnabled*: bool           ## Weapon mass fighting your turn. The muzzle lags going in and overshoots coming out.
    inertiaStrength*: float         ## 0..5. How far the weapon trails the aim.
    inertiaFrequency*: float        ## 0.2..12 Hz. Stiffness of the arms holding the weapon. Lower is looser and swingier.
    inertiaDamping*: float          ## 0.05..2. Below 1 overshoots and settles, 1 stops dead. Around 0.6 is what arms do.
    inertiaMassCoupling*: float     ## 0..3. How much weapon weight slows the response. Makes an RSASS feel unlike a PP-19.
    inertiaRollCoupling*: float     ## -2..2. How much a horizontal turn cants the weapon.
    inertiaMaxDeflection*: float    ## 0.1..30 degrees. Hard ceiling, so a flick cannot throw the gun off screen.
    inertiaAds*: float              ## 0..3. The shoulder absorbs most of it once the stock is planted.
    inertiaHip*: float              ## 0..3. Nothing to absorb it at the hip.
    inertiaMoveGain*: float         ## 0..5. Inertia from the body accelerating, not just from turning.
    inertiaTurnClamp*: float        ## 10..5000 deg/s. Turn rate beyond which inertia stops growing. Keeps mouse flicks sane.
    inertiaInputSmoothing*: float   ## 0..60 Hz. Low-pass on the measured turn rate before it drives the oscillator.
                                    ## Turn rate is a per-frame difference, so it carries the frame timing's own noise;
                                    ## without this the weapon twitches on a jitter in the frame clock rather than on
                                    ## your hand. 0 disables it.

    # ================= 06 Weapon handling =============================
    ergoHalfPoint*: float           ## 5..150. Ergonomics value at which sway sits halfway between floor and ceiling.
    ergoCurve*: float               ## 0.2..4. Above 1 punishes bad ergonomics harder, below 1 flattens the difference.
    ergoFloor*: float               ## 0.05..1. Least sway a perfectly ergonomic weapon can reach.
    ergoCeiling*: float             ## 1..6. Most sway an awful weapon can reach.
    weightInfluence*: float         ## 0..4. How much raw weapon weight feeds tremor and inertia.
    weightReference*: float         ## 0.5..15 kg. Weight treated as neutral. Heavier adds, lighter subtracts.
    recoilStatInfluence*: float     ## 0..3. How much the weapon's recoil stat leaks into sway.

    # ================= 07 Stance and support ==========================
    standMultiplier*: float         ## 0..3. Baseline.
    crouchMultiplier*: float        ## 0..3. A lower centre of mass steadies things.
    proneMultiplier*: float         ## 0..3. Ground contact removes most postural sway.
    mountedMultiplier*: float       ## 0..3. Resting on cover. Breathing still gets through.
    bipodMultiplier*: float         ## 0..3. The steadiest a shooter gets.
    leanMultiplier*: float          ## 0.5..3. Extra sway at full lean. Holding a lean is genuinely harder.
    sprintMultiplier*: float        ## 0..4. Applies during the sprint-out recovery window.
    poseLevelInfluence*: float      ## 0..3. How smoothly the stance multipliers blend across crouch height.
    supportBlendSpeed*: float       ## 0.5..30 per second. How fast support states fade in and out. Prevents snapping.

    # ================= 08 Stamina and fatigue =========================
    fatigueEnabled*: bool           ## Let stamina and oxygen drive sway.
    staminaInfluence*: float        ## 0..5. How much empty stamina amplifies everything.
    oxygenInfluence*: float         ## 0..5. How much oxygen debt amplifies everything.
    handsStaminaInfluence*: float   ## 0..5. Arm stamina drains while aiming a heavy weapon; this is how much that shows.
    exhaustedMultiplier*: float     ## 1..5. Applied on top once stamina bottoms out.
    holdFatigueRate*: float         ## 0..1 per second. How fast holding an aim builds fatigue.
    holdFatigueDecay*: float        ## 0.01..3 per second. How fast it drains once you lower the weapon.
    holdFatigueMax*: float          ## 0..3. Most extra sway sustained aiming can add.

    # ================= 09 Injury ======================================
    injuryEnabled*: bool            ## Let arm damage affect the hold.
    armFractureMultiplier*: float   ## 1..8. A broken arm cannot hold a rifle steady.
    armBlackedMultiplier*: float    ## 1..8. Destroyed limb, no fracture.
    tremorInjuryGain*: float        ## 0..8. Injury feeds tremor harder than it feeds the slow sources.

    # ================= 10 Shot disturbance ============================
    shotEnabled*: bool              ## Let firing disturb the hold beyond recoil itself.
    shotGain*: float                ## 0..1. Sway added by each shot.
    shotDecay*: float               ## 0.05..6 per second. How fast that settles.
    shotMaxAccumulation*: float     ## 0..4. Most a long burst can stack up.
    shotHeartRateKick*: float       ## 0..20 bpm per shot. Firefights raise your pulse.

    # ================= 11 Camera coupling =============================
    cameraCoupling*: float          ## 0..2. How much sway moves the view instead of only the weapon.
                                    ## 0 keeps the crosshair still and moves the gun, 1 moves your head with it.
    cameraRespShare*: float         ## 0..3. Breathing's share of camera coupling.
    cameraHeartShare*: float        ## 0..3. Pulse's share.
    cameraTremorShare*: float       ## 0..3. Tremor's share. Keep this low or the view buzzes.
    cameraDriftShare*: float        ## 0..3. Postural drift's share.
    cameraInertiaShare*: float      ## 0..3. Inertia's share.

    # ================= 12 Springs (advanced) ==========================
    driveGain*: float               ## 0.1..60. See `DriveGainProvenance` below before touching this.
    springOverride*: bool           ## Take over BSG's spring constants. Off leaves them exactly as shipped.
    handsRotDamping*: float         ## 0..1. Higher settles the weapon faster.
    handsRotReturnSpeed*: float     ## 0.1..60. How hard the weapon is pulled back to centre.
    handsRotAccelerationMax*: float ## 0.1..200. Ceiling on a single frame's impulse.
    handsRotInputIntensity*: float  ## 0..5. Scales everything entering the spring.
    handsRotSoftness*: float        ## 0..5. How gently the spring meets its travel limits.
    handsPosDamping*: float         ## 0..1. Same, for positional movement.
    handsPosReturnSpeed*: float     ## 0.1..60. Same, for positional movement.
    cameraRotDamping*: float        ## 0..1. Damping on the view spring.
    cameraRotReturnSpeed*: float    ## 0.1..60. Return speed on the view spring.

    # ================= 13 Vanilla effectors (advanced) ================
    vanillaOverride*: bool          ## Rewrite BSG's own effector parameters every frame. The deep end. Off means untouched.
    vanillaBreathIntensity*: float  ## 0..5. Scales BreathEffector.Intensity.
    vanillaBreathFrequency*: float  ## 0.1..5. Scales the vanilla breathing rate.
    vanillaBreathShake*: float      ## 0..5. Scales the shake term inside the breath effector.
    vanillaBreathHipPenalty*: float ## 0..5. Scales the extra breath sway applied at the hip.
    vanillaBreathCameraSens*: float ## 0..5. How much vanilla breathing moves the camera.
    vanillaBreathTremorOn*: bool    ## BSG's own tremor. Off if you would rather only run this mod's.
    vanillaBreathTremorAmplitude*: float ## 0..5. Scales BSG tremor size.
    vanillaBreathTremorHardness*: float  ## 0.1..5. Scales BSG tremor sharpness.
    vanillaMotionIntensity*: float  ## 0..5. Scales MotionEffector.Intensity, which is BSG's own inertia.
    vanillaMotionSwayX*: float      ## 0..5. Scales MotionEffector.SwayFactors.x.
    vanillaMotionSwayY*: float      ## 0..5. Scales MotionEffector.SwayFactors.y.
    vanillaMotionSwayZ*: float      ## 0..5. Scales MotionEffector.SwayFactors.z.
    vanillaMotionInputClamp*: float ## 0.1..5. Scales the clamp on mouse input feeding vanilla inertia.
    vanillaWalkIntensity*: float    ## 0..5. Scales WalkEffector.Intensity.
    vanillaWalkStepFrequency*: float ## 0.1..5. Scales the step cadence of the walk bob.
    vanillaHandShakeIntensity*: float ## 0..5. Scales the low-stamina hand shake effector.
    vanillaForceIntensity*: float   ## 0..5. Scales explosion and impact shake.
    vanillaAimSwayScale*: float     ## 0..5. Scales the PWA aim sway envelope, min and max together.
    vanillaSwayFalloff*: float      ## 0.1..5. Scales how quickly aim sway decays.

    # ================= 99 Debug =======================================
    debugOverlay*: bool             ## Periodic readout of every live value the model is using.
    debugIntervalMs*: int           ## How often that readout is written. The BepInEx build drew it every frame
                                    ## with OnGUI; a native client mod has no GUI to draw into, so it logs instead
                                    ## and needs a rate.
    verboseLogging*: bool           ## Chatty console output. Useful when a value is not doing what you expect.

const DriveGainProvenance* = """
Drive Gain converts the model's output in *degrees* into the impulse BSG's
rotation springs expect from AddAcceleration. It is the calibration between the
physics and the game, not a taste setting.

The shipped value of 8 was derived analytically -- from the spring's return
speed and damping, solving for the steady-state deflection a given acceleration
produces -- and has NEVER BEEN PLAYTESTED. It is the one number in this mod
that is a calculation rather than a measurement, and it is the first thing to
suspect if the whole mod feels uniformly too strong or too weak while the
individual sources look right relative to each other.

If it does feel wrong: change Master Intensity first. Only come here if the
weapon feels like it is fighting the spring rather than riding it.
"""

template defaultTuning*(): Tuning =
  ## The shipped defaults, as an object literal.
  ##
  ## A template rather than a proc, and that is load-bearing: in a nimony
  ## `--app:lib` build a global initialised by a *call* is never initialised —
  ## literal initialisers are constant-folded, anything needing runtime
  ## evaluation is skipped and the global is left zeroed. `var t =
  ## defaultTuning()` expands to the literal at the declaration and survives.
  ##
  ## These are the post-migration values. The BepInEx build carried a
  ## `SettingsMigration` that rewrote a handful of entries — camera coupling and
  ## the fast sources, which the first release sent far too much of into the
  ## view — but only where the user had not changed them. That mechanism existed
  ## because BepInEx writes a default into a .cfg once and never again. It has
  ## no equivalent here and needs none: `config.json` ships with the mod, so a
  ## retune reaches everyone who has not edited the file, and edits a user made
  ## are theirs to carry forward.
  Tuning(
    enabled: true, preset: psCustom, masterIntensity: 1.0, adsMaster: 1.0,
    hipMaster: 1.0, globalTimeScale: 1.0, keepVanillaSway: true,
    outputSmoothing: 12.0,

    respEnabled: true, respAmplitude: 1.0, respRateRest: 14.0,
    respRateExhausted: 32.0, respInhaleFraction: 0.35,
    respExhaleFraction: 0.45, respPauseFraction: 0.20,
    respWaveformSharpness: 1.0, respPitch: 1.0, respYaw: 0.38, respRoll: 0.22,
    respAds: 0.7, respHip: 1.15, respHoldSuppression: 0.12,
    respHoldReboundGain: 1.8, respHoldReboundDecay: 0.45,
    respOxygenInfluence: 1.0, respIrregularity: 0.15,

    heartEnabled: true, heartAmplitude: 0.8, heartRateRest: 65.0,
    heartRateMax: 165.0, heartRateRise: 0.9, heartRateFall: 0.25,
    heartSystolicSharpness: 4.5, heartDicroticStrength: 0.35,
    heartDicroticDelay: 0.34, heartPitch: 1.0, heartYaw: 0.32,
    heartRoll: 0.14, heartAds: 1.25, heartHip: 0.5, heartExertionGain: 1.6,

    tremorEnabled: true, tremorAmplitude: 0.45, tremorFrequency: 9.5,
    tremorFrequencySpread: 0.35, tremorOctaves: 2, tremorFatigueGain: 2.2,
    tremorLoadGain: 1.2, tremorPitch: 1.0, tremorYaw: 0.95, tremorRoll: 0.45,
    tremorAds: 1.05, tremorHip: 0.75,

    driftEnabled: true, driftAmplitude: 0.7, driftFrequency: 0.28,
    driftPitch: 0.7, driftYaw: 1.0, driftRoll: 0.3, driftAds: 0.85,
    driftHip: 1.0, driftMoveGain: 1.5,

    inertiaEnabled: true, inertiaStrength: 1.0, inertiaFrequency: 2.6,
    inertiaDamping: 0.62, inertiaMassCoupling: 1.0, inertiaRollCoupling: 0.45,
    inertiaMaxDeflection: 4.5, inertiaAds: 0.5, inertiaHip: 1.2,
    inertiaMoveGain: 1.0, inertiaTurnClamp: 900.0, inertiaInputSmoothing: 9.0,

    ergoHalfPoint: 55.0, ergoCurve: 1.15, ergoFloor: 0.55, ergoCeiling: 2.1,
    weightInfluence: 1.0, weightReference: 3.6, recoilStatInfluence: 0.35,

    standMultiplier: 1.0, crouchMultiplier: 0.78, proneMultiplier: 0.42,
    mountedMultiplier: 0.22, bipodMultiplier: 0.15, leanMultiplier: 1.25,
    sprintMultiplier: 1.4, poseLevelInfluence: 1.0, supportBlendSpeed: 7.0,

    fatigueEnabled: true, staminaInfluence: 1.3, oxygenInfluence: 1.0,
    handsStaminaInfluence: 1.1, exhaustedMultiplier: 1.9,
    holdFatigueRate: 0.09, holdFatigueDecay: 0.35, holdFatigueMax: 0.8,

    injuryEnabled: true, armFractureMultiplier: 2.4,
    armBlackedMultiplier: 1.7, tremorInjuryGain: 2.2,

    shotEnabled: true, shotGain: 0.12, shotDecay: 1.1,
    shotMaxAccumulation: 0.9, shotHeartRateKick: 1.5,

    cameraCoupling: 0.10, cameraRespShare: 0.75, cameraHeartShare: 0.45,
    cameraTremorShare: 0.04, cameraDriftShare: 0.45, cameraInertiaShare: 0.12,

    driveGain: 8.0, springOverride: false, handsRotDamping: 0.55,
    handsRotReturnSpeed: 7.0, handsRotAccelerationMax: 12.0,
    handsRotInputIntensity: 1.0, handsRotSoftness: 1.0, handsPosDamping: 0.55,
    handsPosReturnSpeed: 7.0, cameraRotDamping: 0.6,
    cameraRotReturnSpeed: 8.0,

    vanillaOverride: false, vanillaBreathIntensity: 1.0,
    vanillaBreathFrequency: 1.0, vanillaBreathShake: 1.0,
    vanillaBreathHipPenalty: 1.0, vanillaBreathCameraSens: 1.0,
    vanillaBreathTremorOn: true, vanillaBreathTremorAmplitude: 1.0,
    vanillaBreathTremorHardness: 1.0, vanillaMotionIntensity: 1.0,
    vanillaMotionSwayX: 1.0, vanillaMotionSwayY: 1.0, vanillaMotionSwayZ: 1.0,
    vanillaMotionInputClamp: 1.0, vanillaWalkIntensity: 1.0,
    vanillaWalkStepFrequency: 1.0, vanillaHandShakeIntensity: 1.0,
    vanillaForceIntensity: 1.0, vanillaAimSwayScale: 1.0,
    vanillaSwayFalloff: 1.0,

    debugOverlay: false, debugIntervalMs: 1000, verboseLogging: false)

# ---------------------------------------------------------------------------
# Presets
# ---------------------------------------------------------------------------
#
# A preset writes over the entries it names and leaves everything else as the
# user left it, so it is a starting point rather than a reset. Every one of
# them starts from `realistic`, which is the tuned baseline, and then diverges.

proc presetFromText*(s: string): Preset =
  case s
  of "vanilla": psVanilla
  of "arcade": psArcade
  of "realistic": psRealistic
  of "hardcore": psHardcore
  of "cinematic": psCinematic
  of "marksman": psMarksman
  else: psCustom

proc presetName*(p: Preset): string =
  case p
  of psCustom: "custom"
  of psVanilla: "vanilla"
  of psArcade: "arcade"
  of psRealistic: "realistic"
  of psHardcore: "hardcore"
  of psCinematic: "cinematic"
  of psMarksman: "marksman"

proc realistic(t: var Tuning) =
  ## The tuned default. Numbers taken from how a body actually behaves.
  t.masterIntensity = 1.0
  t.globalTimeScale = 1.0
  t.outputSmoothing = 12.0
  t.adsMaster = 1.0
  t.hipMaster = 1.0
  t.keepVanillaSway = true
  t.respEnabled = true
  t.respAmplitude = 1.0
  t.respRateRest = 14.0
  t.respWaveformSharpness = 1.0
  t.respIrregularity = 0.15
  t.heartEnabled = true
  t.heartAmplitude = 0.8
  t.heartSystolicSharpness = 4.5
  t.heartDicroticStrength = 0.35
  t.tremorEnabled = true
  t.tremorAmplitude = 0.45
  t.tremorFrequency = 9.5
  t.driftEnabled = true
  t.driftAmplitude = 0.7
  t.inertiaEnabled = true
  t.inertiaStrength = 1.0
  t.inertiaDamping = 0.62
  t.inertiaFrequency = 2.6
  t.fatigueEnabled = true
  t.injuryEnabled = true
  t.shotEnabled = true
  t.cameraCoupling = 0.10

proc vanilla(t: var Tuning) =
  ## Everything this mod adds is switched off. Stock EFT.
  t.respEnabled = false
  t.heartEnabled = false
  t.tremorEnabled = false
  t.driftEnabled = false
  t.inertiaEnabled = false
  t.shotEnabled = false
  t.springOverride = false
  t.vanillaOverride = false
  t.cameraCoupling = 0.0

proc arcade(t: var Tuning) =
  ## Readable and forgiving. Sway you notice but never fight.
  t.masterIntensity = 0.45
  t.outputSmoothing = 9.0
  t.respAmplitude = 0.6
  t.heartAmplitude = 0.3
  t.tremorAmplitude = 0.25
  t.driftAmplitude = 0.4
  t.inertiaStrength = 0.55
  t.inertiaDamping = 0.95      # settles fast, barely overshoots
  t.tremorFatigueGain = 0.8
  t.staminaInfluence = 0.5
  t.oxygenInfluence = 0.4
  t.exhaustedMultiplier = 1.25
  t.armFractureMultiplier = 1.4
  t.armBlackedMultiplier = 1.2
  t.cameraCoupling = 0.05
  t.shotGain = 0.05

proc hardcore(t: var Tuning) =
  ## Realistic with the leash off. Fatigue and injury bite hard.
  t.masterIntensity = 1.45
  t.respAmplitude = 1.3
  t.respRateExhausted = 38.0
  t.heartAmplitude = 1.15
  t.heartExertionGain = 2.4
  t.tremorAmplitude = 0.75
  t.tremorFatigueGain = 3.4
  t.driftAmplitude = 0.95
  t.inertiaStrength = 1.5
  t.inertiaDamping = 0.45      # swings further, takes longer to settle
  t.staminaInfluence = 2.0
  t.oxygenInfluence = 1.6
  t.exhaustedMultiplier = 2.6
  t.holdFatigueRate = 0.16
  t.armFractureMultiplier = 3.2
  t.armBlackedMultiplier = 2.2
  t.shotGain = 0.2
  t.cameraCoupling = 0.2

proc cinematic(t: var Tuning) =
  ## Oversized and slow. Built to look good on video, not to shoot well.
  t.masterIntensity = 1.9
  t.globalTimeScale = 0.75     # everything slower and more legible
  t.outputSmoothing = 7.0      # deliberately soft, this one is for the camera
  t.respAmplitude = 2.1
  t.respWaveformSharpness = 0.4
  t.heartAmplitude = 1.4
  t.tremorAmplitude = 0.3      # fine shake reads as noise on camera
  t.driftAmplitude = 1.4
  t.inertiaStrength = 2.2
  t.inertiaFrequency = 1.6
  t.inertiaDamping = 0.4
  t.inertiaMaxDeflection = 9.0
  t.cameraCoupling = 0.45

proc marksman(t: var Tuning) =
  ## Slow sources kept, because they are what you time a shot around. Fast
  ## sources trimmed, because at magnification they are just noise.
  t.respAmplitude = 1.1
  t.respPauseFraction = 0.28     # longer natural firing window
  t.respHoldSuppression = 0.05   # holding breath really works
  t.heartAmplitude = 1.05
  t.heartAds = 1.5
  t.tremorAmplitude = 0.35
  t.tremorAds = 0.9
  t.driftAmplitude = 0.65
  t.inertiaAds = 0.35
  t.mountedMultiplier = 0.15
  t.bipodMultiplier = 0.08
  t.proneMultiplier = 0.3
  t.cameraCoupling = 0.08

proc applyPreset*(t: var Tuning; p: Preset) =
  if p == psCustom:
    return
  realistic(t)
  case p
  of psVanilla: vanilla(t)
  of psArcade: arcade(t)
  of psHardcore: hardcore(t)
  of psCinematic: cinematic(t)
  of psMarksman: marksman(t)
  else: discard
