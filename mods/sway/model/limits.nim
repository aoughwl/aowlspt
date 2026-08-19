## The range each tunable is allowed to hold, and what happens outside it.
##
## The previous revision of `tuning.nim` said this, and it was wrong:
##
##     Ranges from the C# `AcceptableValueRange` are recorded in the comments
##     rather than enforced. A JSON config has no slider to constrain, and
##     silently clamping a number a user typed is worse than letting them see
##     what it does.
##
## The second half of that sentence is true and the conclusion does not follow.
## A slider constrained the C#; a JSON file constrains nothing, so the numbers
## that were merely *documented* under BepInEx are now the numbers a text editor
## can hold. `inertia.dampingRatio: 0` is a spring with no damping at all, and
## `inertia.naturalFrequencyHz: 400` steps a second-order system far past what
## its substep cap can integrate: both diverge, and divergence reaches the game
## as a NaN written into a spring that never comes back out.
##
## So: clamped, and **said out loud**, which is the part the old comment was
## right to want. Every value outside its range is reported by name with the
## number the player wrote and the number they got. Nothing is silently
## corrected and nothing is silently obeyed.
##
## The ranges are the documented ones, unchanged, and that is a *result* rather
## than an omission. `model/characterise.nim` sweeps each of them outwards from
## the shipped value until the model stops being bounded, and every allowed
## range turned out to sit well inside its stability edge -- the tightest margin
## on any tunable is a factor of two and most are a factor of four. The
## `inertia.dampingRatio: 0` and `naturalFrequencyHz: 400` cases above do
## diverge, but only far outside anything the config documents: the oscillator's
## substep cap holds it together to about 47 Hz against an allowed 12.
##
## So what the clamp is actually protecting against is not divergence. It is
## magnitude: `masterIntensity` is stable to 20 and produces an unusable weapon
## above about 3, and a value typed into a JSON file has nothing between it and
## the springs. The sweep prints both edges on every run -- where the model stops
## being stable, and where its output starts hitting the ceiling -- so a range
## that stops being true fails the self-test rather than quietly ageing.
##
## The tables themselves are checked rather than trusted. 131 names, 131 lows,
## 131 highs and two 131-arm case statements have to agree with each other and
## with the field order in `Tuning`, and nothing in the compiler checks that: a
## transposed pair of case arms compiles, and its only symptom is a config key
## that silently sets a different setting. `characterise.limiterChecks` rules
## that out — the round trip, the cross-talk, every default inside its own
## range, and what `sanitise` does with a NaN, an infinity and 131 values at
## once — offline, on every run.
##
## This file is pure arithmetic over a `Tuning`. It runs once, at load.

import vec
import fmt
import tuning

const ParamCount* = 131

const ParamName*: array[ParamCount, string] = [
  "masterIntensity",
  "adsMaster",
  "hipMaster",
  "globalTimeScale",
  "outputSmoothing",
  "outputCeiling",
  "respAmplitude",
  "respRateRest",
  "respRateExhausted",
  "respInhaleFraction",
  "respExhaleFraction",
  "respPauseFraction",
  "respWaveformSharpness",
  "respPitch",
  "respYaw",
  "respRoll",
  "respAds",
  "respHip",
  "respHoldSuppression",
  "respHoldReboundGain",
  "respHoldReboundDecay",
  "respOxygenInfluence",
  "respIrregularity",
  "heartAmplitude",
  "heartRateRest",
  "heartRateMax",
  "heartRateRise",
  "heartRateFall",
  "heartSystolicSharpness",
  "heartDicroticStrength",
  "heartDicroticDelay",
  "heartPitch",
  "heartYaw",
  "heartRoll",
  "heartAds",
  "heartHip",
  "heartExertionGain",
  "tremorAmplitude",
  "tremorFrequency",
  "tremorFrequencySpread",
  "tremorOctaves",
  "tremorFatigueGain",
  "tremorLoadGain",
  "tremorPitch",
  "tremorYaw",
  "tremorRoll",
  "tremorAds",
  "tremorHip",
  "driftAmplitude",
  "driftFrequency",
  "driftPitch",
  "driftYaw",
  "driftRoll",
  "driftAds",
  "driftHip",
  "driftMoveGain",
  "inertiaStrength",
  "inertiaFrequency",
  "inertiaDamping",
  "inertiaMassCoupling",
  "inertiaRollCoupling",
  "inertiaMaxDeflection",
  "inertiaAds",
  "inertiaHip",
  "inertiaMoveGain",
  "inertiaTurnClamp",
  "inertiaInputSmoothing",
  "ergoHalfPoint",
  "ergoCurve",
  "ergoFloor",
  "ergoCeiling",
  "weightInfluence",
  "weightReference",
  "recoilStatInfluence",
  "standMultiplier",
  "crouchMultiplier",
  "proneMultiplier",
  "mountedMultiplier",
  "bipodMultiplier",
  "leanMultiplier",
  "sprintMultiplier",
  "poseLevelInfluence",
  "supportBlendSpeed",
  "staminaInfluence",
  "oxygenInfluence",
  "handsStaminaInfluence",
  "exhaustedMultiplier",
  "holdFatigueRate",
  "holdFatigueDecay",
  "holdFatigueMax",
  "armFractureMultiplier",
  "armBlackedMultiplier",
  "tremorInjuryGain",
  "shotGain",
  "shotDecay",
  "shotMaxAccumulation",
  "shotHeartRateKick",
  "cameraCoupling",
  "cameraRespShare",
  "cameraHeartShare",
  "cameraTremorShare",
  "cameraDriftShare",
  "cameraInertiaShare",
  "driveGain",
  "handsRotDamping",
  "handsRotReturnSpeed",
  "handsRotAccelerationMax",
  "handsRotInputIntensity",
  "handsRotSoftness",
  "handsPosDamping",
  "handsPosReturnSpeed",
  "cameraRotDamping",
  "cameraRotReturnSpeed",
  "vanillaBreathIntensity",
  "vanillaBreathFrequency",
  "vanillaBreathShake",
  "vanillaBreathHipPenalty",
  "vanillaBreathCameraSens",
  "vanillaBreathTremorAmplitude",
  "vanillaBreathTremorHardness",
  "vanillaMotionIntensity",
  "vanillaMotionSwayX",
  "vanillaMotionSwayY",
  "vanillaMotionSwayZ",
  "vanillaMotionInputClamp",
  "vanillaWalkIntensity",
  "vanillaWalkStepFrequency",
  "vanillaHandShakeIntensity",
  "vanillaForceIntensity",
  "vanillaAimSwayScale",
  "vanillaSwayFalloff",]

const ParamLo*: array[ParamCount, float] = [
  0.0,
  0.0,
  0.0,
  0.1,
  0.0,
  0.2,
  0.0,
  4.0,
  4.0,
  0.05,
  0.05,
  0.0,
  0.0,
  -3.0,
  -3.0,
  -3.0,
  0.0,
  0.0,
  0.0,
  1.0,
  0.05,
  0.0,
  0.0,
  0.0,
  30.0,
  60.0,
  0.05,
  0.02,
  1.0,
  0.0,
  0.05,
  -3.0,
  -3.0,
  -3.0,
  0.0,
  0.0,
  0.0,
  0.0,
  1.0,
  0.0,
  1.0,
  0.0,
  0.0,
  -3.0,
  -3.0,
  -3.0,
  0.0,
  0.0,
  0.0,
  0.02,
  -3.0,
  -3.0,
  -3.0,
  0.0,
  0.0,
  0.0,
  0.0,
  0.2,
  0.05,
  0.0,
  -2.0,
  0.1,
  0.0,
  0.0,
  0.0,
  10.0,
  0.0,
  5.0,
  0.2,
  0.05,
  1.0,
  0.0,
  0.5,
  0.0,
  0.0,
  0.0,
  0.0,
  0.0,
  0.0,
  0.5,
  0.0,
  0.0,
  0.5,
  0.0,
  0.0,
  0.0,
  1.0,
  0.0,
  0.01,
  0.0,
  1.0,
  1.0,
  0.0,
  0.0,
  0.05,
  0.0,
  0.0,
  0.0,
  0.0,
  0.0,
  0.0,
  0.0,
  0.0,
  0.1,
  0.0,
  0.1,
  0.1,
  0.0,
  0.0,
  0.0,
  0.1,
  0.0,
  0.1,
  0.0,
  0.1,
  0.0,
  0.0,
  0.0,
  0.0,
  0.1,
  0.0,
  0.0,
  0.0,
  0.0,
  0.1,
  0.0,
  0.1,
  0.0,
  0.0,
  0.0,
  0.1,]

const ParamHi*: array[ParamCount, float] = [
  5.0,
  5.0,
  5.0,
  4.0,
  60.0,
  20.0,
  5.0,
  40.0,
  80.0,
  0.9,
  0.9,
  0.7,
  3.0,
  3.0,
  3.0,
  3.0,
  3.0,
  3.0,
  1.0,
  4.0,
  3.0,
  3.0,
  1.0,
  5.0,
  120.0,
  220.0,
  5.0,
  5.0,
  24.0,
  1.0,
  0.9,
  3.0,
  3.0,
  3.0,
  3.0,
  3.0,
  5.0,
  5.0,
  30.0,
  1.0,
  6.0,
  8.0,
  6.0,
  3.0,
  3.0,
  3.0,
  3.0,
  3.0,
  5.0,
  3.0,
  3.0,
  3.0,
  3.0,
  3.0,
  3.0,
  6.0,
  5.0,
  12.0,
  2.0,
  3.0,
  2.0,
  30.0,
  3.0,
  3.0,
  5.0,
  5000.0,
  60.0,
  150.0,
  4.0,
  1.0,
  6.0,
  4.0,
  15.0,
  3.0,
  3.0,
  3.0,
  3.0,
  3.0,
  3.0,
  3.0,
  4.0,
  3.0,
  30.0,
  5.0,
  5.0,
  5.0,
  5.0,
  1.0,
  3.0,
  3.0,
  8.0,
  8.0,
  8.0,
  1.0,
  6.0,
  4.0,
  20.0,
  2.0,
  3.0,
  3.0,
  3.0,
  3.0,
  3.0,
  4.0,
  1.0,
  60.0,
  200.0,
  5.0,
  5.0,
  1.0,
  60.0,
  1.0,
  60.0,
  5.0,
  5.0,
  5.0,
  5.0,
  5.0,
  5.0,
  5.0,
  5.0,
  5.0,
  5.0,
  5.0,
  5.0,
  5.0,
  5.0,
  5.0,
  5.0,
  5.0,
  5.0,]

const ParamSwept*: array[ParamCount, bool] = [
  true,
  true,
  false,
  true,
  true,
  true,
  true,
  false,
  true,
  false,
  false,
  false,
  true,
  false,
  false,
  false,
  false,
  false,
  false,
  false,
  false,
  false,
  false,
  true,
  false,
  false,
  false,
  false,
  true,
  false,
  false,
  false,
  false,
  false,
  false,
  false,
  true,
  true,
  true,
  false,
  true,
  true,
  false,
  false,
  false,
  false,
  false,
  false,
  true,
  true,
  false,
  false,
  false,
  false,
  false,
  true,
  true,
  true,
  true,
  true,
  false,
  true,
  false,
  false,
  false,
  true,
  true,
  false,
  false,
  false,
  true,
  true,
  false,
  false,
  false,
  false,
  false,
  false,
  false,
  false,
  false,
  false,
  true,
  true,
  false,
  false,
  true,
  false,
  false,
  true,
  true,
  false,
  true,
  true,
  false,
  true,
  false,
  true,
  false,
  false,
  false,
  false,
  false,
  true,
  false,
  false,
  false,
  false,
  false,
  false,
  false,
  false,
  false,
  false,
  false,
  false,
  false,
  false,
  false,
  false,
  false,
  false,
  false,
  false,
  false,
  false,
  false,
  false,
  false,
  false,
  false,]

proc paramGet*(t: Tuning; i: int): float =
  ## One tunable by index, as a float. The index is `ParamName`'s.
  case i
  of 0: result = t.masterIntensity
  of 1: result = t.adsMaster
  of 2: result = t.hipMaster
  of 3: result = t.globalTimeScale
  of 4: result = t.outputSmoothing
  of 5: result = t.outputCeiling
  of 6: result = t.respAmplitude
  of 7: result = t.respRateRest
  of 8: result = t.respRateExhausted
  of 9: result = t.respInhaleFraction
  of 10: result = t.respExhaleFraction
  of 11: result = t.respPauseFraction
  of 12: result = t.respWaveformSharpness
  of 13: result = t.respPitch
  of 14: result = t.respYaw
  of 15: result = t.respRoll
  of 16: result = t.respAds
  of 17: result = t.respHip
  of 18: result = t.respHoldSuppression
  of 19: result = t.respHoldReboundGain
  of 20: result = t.respHoldReboundDecay
  of 21: result = t.respOxygenInfluence
  of 22: result = t.respIrregularity
  of 23: result = t.heartAmplitude
  of 24: result = t.heartRateRest
  of 25: result = t.heartRateMax
  of 26: result = t.heartRateRise
  of 27: result = t.heartRateFall
  of 28: result = t.heartSystolicSharpness
  of 29: result = t.heartDicroticStrength
  of 30: result = t.heartDicroticDelay
  of 31: result = t.heartPitch
  of 32: result = t.heartYaw
  of 33: result = t.heartRoll
  of 34: result = t.heartAds
  of 35: result = t.heartHip
  of 36: result = t.heartExertionGain
  of 37: result = t.tremorAmplitude
  of 38: result = t.tremorFrequency
  of 39: result = t.tremorFrequencySpread
  of 40: result = float(t.tremorOctaves)
  of 41: result = t.tremorFatigueGain
  of 42: result = t.tremorLoadGain
  of 43: result = t.tremorPitch
  of 44: result = t.tremorYaw
  of 45: result = t.tremorRoll
  of 46: result = t.tremorAds
  of 47: result = t.tremorHip
  of 48: result = t.driftAmplitude
  of 49: result = t.driftFrequency
  of 50: result = t.driftPitch
  of 51: result = t.driftYaw
  of 52: result = t.driftRoll
  of 53: result = t.driftAds
  of 54: result = t.driftHip
  of 55: result = t.driftMoveGain
  of 56: result = t.inertiaStrength
  of 57: result = t.inertiaFrequency
  of 58: result = t.inertiaDamping
  of 59: result = t.inertiaMassCoupling
  of 60: result = t.inertiaRollCoupling
  of 61: result = t.inertiaMaxDeflection
  of 62: result = t.inertiaAds
  of 63: result = t.inertiaHip
  of 64: result = t.inertiaMoveGain
  of 65: result = t.inertiaTurnClamp
  of 66: result = t.inertiaInputSmoothing
  of 67: result = t.ergoHalfPoint
  of 68: result = t.ergoCurve
  of 69: result = t.ergoFloor
  of 70: result = t.ergoCeiling
  of 71: result = t.weightInfluence
  of 72: result = t.weightReference
  of 73: result = t.recoilStatInfluence
  of 74: result = t.standMultiplier
  of 75: result = t.crouchMultiplier
  of 76: result = t.proneMultiplier
  of 77: result = t.mountedMultiplier
  of 78: result = t.bipodMultiplier
  of 79: result = t.leanMultiplier
  of 80: result = t.sprintMultiplier
  of 81: result = t.poseLevelInfluence
  of 82: result = t.supportBlendSpeed
  of 83: result = t.staminaInfluence
  of 84: result = t.oxygenInfluence
  of 85: result = t.handsStaminaInfluence
  of 86: result = t.exhaustedMultiplier
  of 87: result = t.holdFatigueRate
  of 88: result = t.holdFatigueDecay
  of 89: result = t.holdFatigueMax
  of 90: result = t.armFractureMultiplier
  of 91: result = t.armBlackedMultiplier
  of 92: result = t.tremorInjuryGain
  of 93: result = t.shotGain
  of 94: result = t.shotDecay
  of 95: result = t.shotMaxAccumulation
  of 96: result = t.shotHeartRateKick
  of 97: result = t.cameraCoupling
  of 98: result = t.cameraRespShare
  of 99: result = t.cameraHeartShare
  of 100: result = t.cameraTremorShare
  of 101: result = t.cameraDriftShare
  of 102: result = t.cameraInertiaShare
  of 103: result = t.driveGain
  of 104: result = t.handsRotDamping
  of 105: result = t.handsRotReturnSpeed
  of 106: result = t.handsRotAccelerationMax
  of 107: result = t.handsRotInputIntensity
  of 108: result = t.handsRotSoftness
  of 109: result = t.handsPosDamping
  of 110: result = t.handsPosReturnSpeed
  of 111: result = t.cameraRotDamping
  of 112: result = t.cameraRotReturnSpeed
  of 113: result = t.vanillaBreathIntensity
  of 114: result = t.vanillaBreathFrequency
  of 115: result = t.vanillaBreathShake
  of 116: result = t.vanillaBreathHipPenalty
  of 117: result = t.vanillaBreathCameraSens
  of 118: result = t.vanillaBreathTremorAmplitude
  of 119: result = t.vanillaBreathTremorHardness
  of 120: result = t.vanillaMotionIntensity
  of 121: result = t.vanillaMotionSwayX
  of 122: result = t.vanillaMotionSwayY
  of 123: result = t.vanillaMotionSwayZ
  of 124: result = t.vanillaMotionInputClamp
  of 125: result = t.vanillaWalkIntensity
  of 126: result = t.vanillaWalkStepFrequency
  of 127: result = t.vanillaHandShakeIntensity
  of 128: result = t.vanillaForceIntensity
  of 129: result = t.vanillaAimSwayScale
  of 130: result = t.vanillaSwayFalloff
  else: result = 0.0

proc paramSet*(t: var Tuning; i: int; v: float) =
  ## The inverse. An int-valued tunable is rounded rather than truncated.
  case i
  of 0: t.masterIntensity = v
  of 1: t.adsMaster = v
  of 2: t.hipMaster = v
  of 3: t.globalTimeScale = v
  of 4: t.outputSmoothing = v
  of 5: t.outputCeiling = v
  of 6: t.respAmplitude = v
  of 7: t.respRateRest = v
  of 8: t.respRateExhausted = v
  of 9: t.respInhaleFraction = v
  of 10: t.respExhaleFraction = v
  of 11: t.respPauseFraction = v
  of 12: t.respWaveformSharpness = v
  of 13: t.respPitch = v
  of 14: t.respYaw = v
  of 15: t.respRoll = v
  of 16: t.respAds = v
  of 17: t.respHip = v
  of 18: t.respHoldSuppression = v
  of 19: t.respHoldReboundGain = v
  of 20: t.respHoldReboundDecay = v
  of 21: t.respOxygenInfluence = v
  of 22: t.respIrregularity = v
  of 23: t.heartAmplitude = v
  of 24: t.heartRateRest = v
  of 25: t.heartRateMax = v
  of 26: t.heartRateRise = v
  of 27: t.heartRateFall = v
  of 28: t.heartSystolicSharpness = v
  of 29: t.heartDicroticStrength = v
  of 30: t.heartDicroticDelay = v
  of 31: t.heartPitch = v
  of 32: t.heartYaw = v
  of 33: t.heartRoll = v
  of 34: t.heartAds = v
  of 35: t.heartHip = v
  of 36: t.heartExertionGain = v
  of 37: t.tremorAmplitude = v
  of 38: t.tremorFrequency = v
  of 39: t.tremorFrequencySpread = v
  of 40: t.tremorOctaves = int(v + 0.5)
  of 41: t.tremorFatigueGain = v
  of 42: t.tremorLoadGain = v
  of 43: t.tremorPitch = v
  of 44: t.tremorYaw = v
  of 45: t.tremorRoll = v
  of 46: t.tremorAds = v
  of 47: t.tremorHip = v
  of 48: t.driftAmplitude = v
  of 49: t.driftFrequency = v
  of 50: t.driftPitch = v
  of 51: t.driftYaw = v
  of 52: t.driftRoll = v
  of 53: t.driftAds = v
  of 54: t.driftHip = v
  of 55: t.driftMoveGain = v
  of 56: t.inertiaStrength = v
  of 57: t.inertiaFrequency = v
  of 58: t.inertiaDamping = v
  of 59: t.inertiaMassCoupling = v
  of 60: t.inertiaRollCoupling = v
  of 61: t.inertiaMaxDeflection = v
  of 62: t.inertiaAds = v
  of 63: t.inertiaHip = v
  of 64: t.inertiaMoveGain = v
  of 65: t.inertiaTurnClamp = v
  of 66: t.inertiaInputSmoothing = v
  of 67: t.ergoHalfPoint = v
  of 68: t.ergoCurve = v
  of 69: t.ergoFloor = v
  of 70: t.ergoCeiling = v
  of 71: t.weightInfluence = v
  of 72: t.weightReference = v
  of 73: t.recoilStatInfluence = v
  of 74: t.standMultiplier = v
  of 75: t.crouchMultiplier = v
  of 76: t.proneMultiplier = v
  of 77: t.mountedMultiplier = v
  of 78: t.bipodMultiplier = v
  of 79: t.leanMultiplier = v
  of 80: t.sprintMultiplier = v
  of 81: t.poseLevelInfluence = v
  of 82: t.supportBlendSpeed = v
  of 83: t.staminaInfluence = v
  of 84: t.oxygenInfluence = v
  of 85: t.handsStaminaInfluence = v
  of 86: t.exhaustedMultiplier = v
  of 87: t.holdFatigueRate = v
  of 88: t.holdFatigueDecay = v
  of 89: t.holdFatigueMax = v
  of 90: t.armFractureMultiplier = v
  of 91: t.armBlackedMultiplier = v
  of 92: t.tremorInjuryGain = v
  of 93: t.shotGain = v
  of 94: t.shotDecay = v
  of 95: t.shotMaxAccumulation = v
  of 96: t.shotHeartRateKick = v
  of 97: t.cameraCoupling = v
  of 98: t.cameraRespShare = v
  of 99: t.cameraHeartShare = v
  of 100: t.cameraTremorShare = v
  of 101: t.cameraDriftShare = v
  of 102: t.cameraInertiaShare = v
  of 103: t.driveGain = v
  of 104: t.handsRotDamping = v
  of 105: t.handsRotReturnSpeed = v
  of 106: t.handsRotAccelerationMax = v
  of 107: t.handsRotInputIntensity = v
  of 108: t.handsRotSoftness = v
  of 109: t.handsPosDamping = v
  of 110: t.handsPosReturnSpeed = v
  of 111: t.cameraRotDamping = v
  of 112: t.cameraRotReturnSpeed = v
  of 113: t.vanillaBreathIntensity = v
  of 114: t.vanillaBreathFrequency = v
  of 115: t.vanillaBreathShake = v
  of 116: t.vanillaBreathHipPenalty = v
  of 117: t.vanillaBreathCameraSens = v
  of 118: t.vanillaBreathTremorAmplitude = v
  of 119: t.vanillaBreathTremorHardness = v
  of 120: t.vanillaMotionIntensity = v
  of 121: t.vanillaMotionSwayX = v
  of 122: t.vanillaMotionSwayY = v
  of 123: t.vanillaMotionSwayZ = v
  of 124: t.vanillaMotionInputClamp = v
  of 125: t.vanillaWalkIntensity = v
  of 126: t.vanillaWalkStepFrequency = v
  of 127: t.vanillaHandShakeIntensity = v
  of 128: t.vanillaForceIntensity = v
  of 129: t.vanillaAimSwayScale = v
  of 130: t.vanillaSwayFalloff = v
  else: discard

# ---------------------------------------------------------------------------
# Clamping
# ---------------------------------------------------------------------------

proc sanitise*(t: var Tuning; msgs: var seq[string]; maxMsgs = 12): int =
  ## Brings every tunable inside its range and returns how many had to move.
  ##
  ## A non-finite value -- which is what a JSON `1e999`, or a key holding a
  ## string, can leave behind -- is put back to the shipped default rather than
  ## to the nearest bound, because there is no nearest bound to a NaN and the
  ## default is the only value known to be sane.
  ##
  ## Called once, after the config is read and the preset applied. Not on the
  ## per-frame path and it allocates: `msgs` is a handful of strings, once.
  result = 0
  var shipped = defaultTuning()
  for i in 0 ..< ParamCount:
    let v = paramGet(t, i)
    let lo = ParamLo[i]
    let hi = ParamHi[i]
    var w = v
    var why = ""
    if not isFinite(v):
      w = paramGet(shipped, i)
      why = " is not a number; the shipped default "
    elif v < lo:
      w = lo
      why = " is below its safe range; "
    elif v > hi:
      w = hi
      why = " is above its safe range; "
    if why.len > 0:
      inc result
      paramSet(t, i, w)
      if msgs.len < maxMsgs:
        msgs.add ParamName[i] & " = " & fmtNum(v) & why & fmtNum(w) &
                 " was used instead (safe range " & fmtNum(lo) & " .. " &
                 fmtNum(hi) & ")"
  if result > msgs.len and msgs.len >= maxMsgs:
    msgs.add "... and " & $(result - msgs.len) & " more"
