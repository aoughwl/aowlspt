## `config.json` -> `Tuning`.
##
## The BepInEx original bound ~150 `ConfigEntry<T>` into the F12 menu, one per
## number. There is no F12 menu here, so the same numbers live in `config.json`
## grouped into the sections the C# used, and this file is the one place that
## knows the mapping from a JSON path to a field.
##
## Every read falls back to the shipped default. A config file missing a whole
## section, or a key with a typo in it, costs that one setting and nothing else
## — which matters more here than it did under BepInEx, where the framework
## would have written the key back for you.

import aowlspt
import aowlspt/json
import ".." / model/tuning

type
  ConfigDoc* = object
    ## The whole config, fetched once. Fetching per key would be 150 round
    ## trips through the host for a document the host already has parsed.
    text*: string
    ok*: bool
    missing*: int    ## keys that were not in the file, so a mod can say so once

proc loadConfigDoc*(): ConfigDoc =
  var raw = ""
  let empty = ""
  if configGet(empty, raw) == Ok and raw.len > 0:
    result = ConfigDoc(text: raw, ok: true, missing: 0)
  else:
    result = ConfigDoc(text: "", ok: false, missing: 0)

proc num(d: var ConfigDoc; path: string; default: float): float =
  if not d.ok:
    return default
  let j = field(d.text, path)
  if not j.exists:
    inc d.missing
    return default
  result = asFloat(j, default)

proc flag(d: var ConfigDoc; path: string; default: bool): bool =
  if not d.ok:
    return default
  let j = field(d.text, path)
  if not j.exists:
    inc d.missing
    return default
  result = asBool(j, default)

proc count(d: var ConfigDoc; path: string; default: int): int =
  if not d.ok:
    return default
  let j = field(d.text, path)
  if not j.exists:
    inc d.missing
    return default
  result = asInt(j, default)

proc text(d: var ConfigDoc; path: string; default: string): string =
  if not d.ok:
    return default
  let j = field(d.text, path)
  if not j.exists:
    inc d.missing
    return default
  result = asText(j, default)

proc readTuning*(d: var ConfigDoc; t: var Tuning) =
  ## Overwrites `t` from the document, field by field, in section order.
  ##
  ## The `preset` key is read but applied last, by the caller, because a preset
  ## overwrites the values read here and doing it in the middle would make the
  ## order of the reads matter.

  # ---- 00 general ---------------------------------------------------
  t.enabled = flag(d, "general.enabled", t.enabled)
  t.preset = presetFromText(text(d, "general.preset", presetName(t.preset)))
  t.masterIntensity = num(d, "general.masterIntensity", t.masterIntensity)
  t.adsMaster = num(d, "general.adsMultiplier", t.adsMaster)
  t.hipMaster = num(d, "general.hipfireMultiplier", t.hipMaster)
  t.globalTimeScale = num(d, "general.rateMultiplier", t.globalTimeScale)
  t.keepVanillaSway = flag(d, "general.keepVanillaSway", t.keepVanillaSway)
  t.outputSmoothing = num(d, "general.outputSmoothingHz", t.outputSmoothing)

  # ---- 01 respiration -----------------------------------------------
  t.respEnabled = flag(d, "respiration.enabled", t.respEnabled)
  t.respAmplitude = num(d, "respiration.amplitude", t.respAmplitude)
  t.respRateRest = num(d, "respiration.rateRestedBpm", t.respRateRest)
  t.respRateExhausted = num(d, "respiration.rateExhaustedBpm", t.respRateExhausted)
  t.respInhaleFraction = num(d, "respiration.inhaleFraction", t.respInhaleFraction)
  t.respExhaleFraction = num(d, "respiration.exhaleFraction", t.respExhaleFraction)
  t.respPauseFraction = num(d, "respiration.endExpiratoryPause", t.respPauseFraction)
  t.respWaveformSharpness = num(d, "respiration.waveformSharpness", t.respWaveformSharpness)
  t.respPitch = num(d, "respiration.pitchWeight", t.respPitch)
  t.respYaw = num(d, "respiration.yawWeight", t.respYaw)
  t.respRoll = num(d, "respiration.rollWeight", t.respRoll)
  t.respAds = num(d, "respiration.adsMultiplier", t.respAds)
  t.respHip = num(d, "respiration.hipfireMultiplier", t.respHip)
  t.respHoldSuppression = num(d, "respiration.breathHoldSuppression", t.respHoldSuppression)
  t.respHoldReboundGain = num(d, "respiration.holdReboundGain", t.respHoldReboundGain)
  t.respHoldReboundDecay = num(d, "respiration.holdReboundDecay", t.respHoldReboundDecay)
  t.respOxygenInfluence = num(d, "respiration.oxygenInfluence", t.respOxygenInfluence)
  t.respIrregularity = num(d, "respiration.irregularity", t.respIrregularity)

  # ---- 02 cardiac ----------------------------------------------------
  t.heartEnabled = flag(d, "cardiac.enabled", t.heartEnabled)
  t.heartAmplitude = num(d, "cardiac.amplitude", t.heartAmplitude)
  t.heartRateRest = num(d, "cardiac.restingBpm", t.heartRateRest)
  t.heartRateMax = num(d, "cardiac.maxBpm", t.heartRateMax)
  t.heartRateRise = num(d, "cardiac.rateRiseSpeed", t.heartRateRise)
  t.heartRateFall = num(d, "cardiac.rateFallSpeed", t.heartRateFall)
  t.heartSystolicSharpness = num(d, "cardiac.systolicSharpness", t.heartSystolicSharpness)
  t.heartDicroticStrength = num(d, "cardiac.dicroticNotch", t.heartDicroticStrength)
  t.heartDicroticDelay = num(d, "cardiac.dicroticDelay", t.heartDicroticDelay)
  t.heartPitch = num(d, "cardiac.pitchWeight", t.heartPitch)
  t.heartYaw = num(d, "cardiac.yawWeight", t.heartYaw)
  t.heartRoll = num(d, "cardiac.rollWeight", t.heartRoll)
  t.heartAds = num(d, "cardiac.adsMultiplier", t.heartAds)
  t.heartHip = num(d, "cardiac.hipfireMultiplier", t.heartHip)
  t.heartExertionGain = num(d, "cardiac.exertionAmplitudeGain", t.heartExertionGain)

  # ---- 03 tremor -----------------------------------------------------
  t.tremorEnabled = flag(d, "tremor.enabled", t.tremorEnabled)
  t.tremorAmplitude = num(d, "tremor.amplitude", t.tremorAmplitude)
  t.tremorFrequency = num(d, "tremor.centreFrequencyHz", t.tremorFrequency)
  t.tremorFrequencySpread = num(d, "tremor.frequencySpread", t.tremorFrequencySpread)
  t.tremorOctaves = count(d, "tremor.octaves", t.tremorOctaves)
  t.tremorFatigueGain = num(d, "tremor.fatigueGain", t.tremorFatigueGain)
  t.tremorLoadGain = num(d, "tremor.weaponLoadGain", t.tremorLoadGain)
  t.tremorPitch = num(d, "tremor.pitchWeight", t.tremorPitch)
  t.tremorYaw = num(d, "tremor.yawWeight", t.tremorYaw)
  t.tremorRoll = num(d, "tremor.rollWeight", t.tremorRoll)
  t.tremorAds = num(d, "tremor.adsMultiplier", t.tremorAds)
  t.tremorHip = num(d, "tremor.hipfireMultiplier", t.tremorHip)

  # ---- 04 postural drift ---------------------------------------------
  t.driftEnabled = flag(d, "drift.enabled", t.driftEnabled)
  t.driftAmplitude = num(d, "drift.amplitude", t.driftAmplitude)
  t.driftFrequency = num(d, "drift.frequencyHz", t.driftFrequency)
  t.driftPitch = num(d, "drift.pitchWeight", t.driftPitch)
  t.driftYaw = num(d, "drift.yawWeight", t.driftYaw)
  t.driftRoll = num(d, "drift.rollWeight", t.driftRoll)
  t.driftAds = num(d, "drift.adsMultiplier", t.driftAds)
  t.driftHip = num(d, "drift.hipfireMultiplier", t.driftHip)
  t.driftMoveGain = num(d, "drift.movementGain", t.driftMoveGain)

  # ---- 05 weapon inertia ----------------------------------------------
  t.inertiaEnabled = flag(d, "inertia.enabled", t.inertiaEnabled)
  t.inertiaStrength = num(d, "inertia.strength", t.inertiaStrength)
  t.inertiaFrequency = num(d, "inertia.naturalFrequencyHz", t.inertiaFrequency)
  t.inertiaDamping = num(d, "inertia.dampingRatio", t.inertiaDamping)
  t.inertiaMassCoupling = num(d, "inertia.massCoupling", t.inertiaMassCoupling)
  t.inertiaRollCoupling = num(d, "inertia.rollCoupling", t.inertiaRollCoupling)
  t.inertiaMaxDeflection = num(d, "inertia.maxDeflection", t.inertiaMaxDeflection)
  t.inertiaAds = num(d, "inertia.adsMultiplier", t.inertiaAds)
  t.inertiaHip = num(d, "inertia.hipfireMultiplier", t.inertiaHip)
  t.inertiaMoveGain = num(d, "inertia.movementGain", t.inertiaMoveGain)
  t.inertiaTurnClamp = num(d, "inertia.turnRateClamp", t.inertiaTurnClamp)
  t.inertiaInputSmoothing = num(d, "inertia.inputSmoothingHz", t.inertiaInputSmoothing)

  # ---- 06 weapon handling ---------------------------------------------
  t.ergoHalfPoint = num(d, "handling.ergonomicsHalfPoint", t.ergoHalfPoint)
  t.ergoCurve = num(d, "handling.ergonomicsCurve", t.ergoCurve)
  t.ergoFloor = num(d, "handling.ergonomicsFloor", t.ergoFloor)
  t.ergoCeiling = num(d, "handling.ergonomicsCeiling", t.ergoCeiling)
  t.weightInfluence = num(d, "handling.weightInfluence", t.weightInfluence)
  t.weightReference = num(d, "handling.referenceWeightKg", t.weightReference)
  t.recoilStatInfluence = num(d, "handling.recoilStatInfluence", t.recoilStatInfluence)

  # ---- 07 stance and support ------------------------------------------
  t.standMultiplier = num(d, "stance.standing", t.standMultiplier)
  t.crouchMultiplier = num(d, "stance.crouched", t.crouchMultiplier)
  t.proneMultiplier = num(d, "stance.prone", t.proneMultiplier)
  t.mountedMultiplier = num(d, "stance.mounted", t.mountedMultiplier)
  t.bipodMultiplier = num(d, "stance.bipodDeployed", t.bipodMultiplier)
  t.leanMultiplier = num(d, "stance.leaningPenalty", t.leanMultiplier)
  t.sprintMultiplier = num(d, "stance.sprinting", t.sprintMultiplier)
  t.poseLevelInfluence = num(d, "stance.poseLevelInfluence", t.poseLevelInfluence)
  t.supportBlendSpeed = num(d, "stance.supportBlendSpeed", t.supportBlendSpeed)

  # ---- 08 stamina and fatigue ------------------------------------------
  t.fatigueEnabled = flag(d, "fatigue.enabled", t.fatigueEnabled)
  t.staminaInfluence = num(d, "fatigue.staminaInfluence", t.staminaInfluence)
  t.oxygenInfluence = num(d, "fatigue.oxygenInfluence", t.oxygenInfluence)
  t.handsStaminaInfluence = num(d, "fatigue.armStaminaInfluence", t.handsStaminaInfluence)
  t.exhaustedMultiplier = num(d, "fatigue.exhaustedMultiplier", t.exhaustedMultiplier)
  t.holdFatigueRate = num(d, "fatigue.sustainedAimRate", t.holdFatigueRate)
  t.holdFatigueDecay = num(d, "fatigue.sustainedAimRecovery", t.holdFatigueDecay)
  t.holdFatigueMax = num(d, "fatigue.sustainedAimCeiling", t.holdFatigueMax)

  # ---- 09 injury --------------------------------------------------------
  t.injuryEnabled = flag(d, "injury.enabled", t.injuryEnabled)
  t.armFractureMultiplier = num(d, "injury.fracturedArm", t.armFractureMultiplier)
  t.armBlackedMultiplier = num(d, "injury.blackedArm", t.armBlackedMultiplier)
  t.tremorInjuryGain = num(d, "injury.injuryTremorGain", t.tremorInjuryGain)

  # ---- 10 shot disturbance ----------------------------------------------
  t.shotEnabled = flag(d, "shot.enabled", t.shotEnabled)
  t.shotGain = num(d, "shot.perShotGain", t.shotGain)
  t.shotDecay = num(d, "shot.decay", t.shotDecay)
  t.shotMaxAccumulation = num(d, "shot.ceiling", t.shotMaxAccumulation)
  t.shotHeartRateKick = num(d, "shot.heartRateKick", t.shotHeartRateKick)

  # ---- 11 camera coupling ------------------------------------------------
  t.cameraCoupling = num(d, "camera.masterCameraCoupling", t.cameraCoupling)
  t.cameraRespShare = num(d, "camera.respirationShare", t.cameraRespShare)
  t.cameraHeartShare = num(d, "camera.cardiacShare", t.cameraHeartShare)
  t.cameraTremorShare = num(d, "camera.tremorShare", t.cameraTremorShare)
  t.cameraDriftShare = num(d, "camera.driftShare", t.cameraDriftShare)
  t.cameraInertiaShare = num(d, "camera.inertiaShare", t.cameraInertiaShare)

  # ---- 12 springs ---------------------------------------------------------
  t.driveGain = num(d, "springs.driveGain", t.driveGain)
  t.springOverride = flag(d, "springs.overrideSprings", t.springOverride)
  t.handsRotDamping = num(d, "springs.handsRotationDamping", t.handsRotDamping)
  t.handsRotReturnSpeed = num(d, "springs.handsRotationReturnSpeed", t.handsRotReturnSpeed)
  t.handsRotAccelerationMax = num(d, "springs.handsRotationAccelerationMax", t.handsRotAccelerationMax)
  t.handsRotInputIntensity = num(d, "springs.handsRotationInputIntensity", t.handsRotInputIntensity)
  t.handsRotSoftness = num(d, "springs.handsRotationSoftness", t.handsRotSoftness)
  t.handsPosDamping = num(d, "springs.handsPositionDamping", t.handsPosDamping)
  t.handsPosReturnSpeed = num(d, "springs.handsPositionReturnSpeed", t.handsPosReturnSpeed)
  t.cameraRotDamping = num(d, "springs.cameraRotationDamping", t.cameraRotDamping)
  t.cameraRotReturnSpeed = num(d, "springs.cameraRotationReturnSpeed", t.cameraRotReturnSpeed)

  # ---- 13 vanilla effectors -------------------------------------------------
  t.vanillaOverride = flag(d, "vanilla.overrideVanillaEffectors", t.vanillaOverride)
  t.vanillaBreathIntensity = num(d, "vanilla.breathIntensity", t.vanillaBreathIntensity)
  t.vanillaBreathFrequency = num(d, "vanilla.breathFrequency", t.vanillaBreathFrequency)
  t.vanillaBreathShake = num(d, "vanilla.breathShake", t.vanillaBreathShake)
  t.vanillaBreathHipPenalty = num(d, "vanilla.breathHipPenalty", t.vanillaBreathHipPenalty)
  t.vanillaBreathCameraSens = num(d, "vanilla.breathCameraSensitivity", t.vanillaBreathCameraSens)
  t.vanillaBreathTremorOn = flag(d, "vanilla.vanillaTremorEnabled", t.vanillaBreathTremorOn)
  t.vanillaBreathTremorAmplitude = num(d, "vanilla.vanillaTremorAmplitude", t.vanillaBreathTremorAmplitude)
  t.vanillaBreathTremorHardness = num(d, "vanilla.vanillaTremorHardness", t.vanillaBreathTremorHardness)
  t.vanillaMotionIntensity = num(d, "vanilla.motionIntensity", t.vanillaMotionIntensity)
  t.vanillaMotionSwayX = num(d, "vanilla.motionSwayFactorX", t.vanillaMotionSwayX)
  t.vanillaMotionSwayY = num(d, "vanilla.motionSwayFactorY", t.vanillaMotionSwayY)
  t.vanillaMotionSwayZ = num(d, "vanilla.motionSwayFactorZ", t.vanillaMotionSwayZ)
  t.vanillaMotionInputClamp = num(d, "vanilla.motionInputClamp", t.vanillaMotionInputClamp)
  t.vanillaWalkIntensity = num(d, "vanilla.walkBobIntensity", t.vanillaWalkIntensity)
  t.vanillaWalkStepFrequency = num(d, "vanilla.walkStepFrequency", t.vanillaWalkStepFrequency)
  t.vanillaHandShakeIntensity = num(d, "vanilla.handShakeIntensity", t.vanillaHandShakeIntensity)
  t.vanillaForceIntensity = num(d, "vanilla.forceEffectorIntensity", t.vanillaForceIntensity)
  t.vanillaAimSwayScale = num(d, "vanilla.aimSwayScale", t.vanillaAimSwayScale)
  t.vanillaSwayFalloff = num(d, "vanilla.swayFalloff", t.vanillaSwayFalloff)

  # ---- 99 debug ---------------------------------------------------------------
  t.debugOverlay = flag(d, "debug.overlay", t.debugOverlay)
  t.debugIntervalMs = count(d, "debug.overlayIntervalMs", t.debugIntervalMs)
  t.verboseLogging = flag(d, "debug.verboseLogging", t.verboseLogging)

  # A preset overwrites what was just read. `psCustom` — the default — leaves
  # the file's own numbers alone, which is what someone who edited the file
  # expects to happen.
  applyPreset(t, t.preset)
