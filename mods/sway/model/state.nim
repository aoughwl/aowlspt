## Everything the model needs to know about the shooter this frame.
##
## In the C# this was one class that both *read* the game and *derived* from
## what it read. Here those are split: the fields below are plain data that
## somebody fills in — the game layer from EFT, `aowlspt-sim` from a script —
## and `derive` turns them into the three numbers the sources actually scale by.
##
## The split is not tidiness. It is what makes the model testable: a state
## record with `stamina = 0.1` and `isAiming = true` produces exactly the sway
## a spent shooter aiming produces, with no game in the process.

import std/math
import vec
import tuning

type
  ShooterState* = object
    # -- raw inputs ---------------------------------------------------
    isAiming*: bool
    isProne*: bool
    isMounted*: bool
    isBipod*: bool
    isSprinting*: bool
    holdingBreath*: bool
    poseLevel*: float        ## 0 fully crouched .. 1 standing
    lean*: float             ## -1 .. 1
    moveSpeed*: float        ## m/s, smoothed by the game

    # -- physiology ---------------------------------------------------
    stamina*: float          ## 1 fresh .. 0 spent
    oxygen*: float
    armStamina*: float
    exhausted*: bool

    # -- injury -------------------------------------------------------
    armFractured*: bool
    armBlacked*: bool
    neuroTremor*: bool       ## the Tremor physical condition, from stims and shock

    # -- weapon -------------------------------------------------------
    ergonomics*: float
    weightKg*: float
    recoilStat*: float

    # -- derived ------------------------------------------------------
    exertion*: float         ## 0 fresh .. 1 wrecked. The single number most sources scale by.
    handlingFactor*: float   ## Ergonomics and weight folded into one multiplier.
    supportFactor*: float    ## How much the weapon is held up rather than resting. 1 unsupported .. 0 bipod.
    supportSmoothed*: float  ## The state behind supportFactor. Not for reading.

template freshState*(): ShooterState =
  ## A rested shooter standing up with a mid-weight rifle. Also the fallback
  ## when the game cannot be read: every physiological field is at its healthy
  ## end, so a failed read costs that one signal rather than inventing a
  ## shooter who is dying.
  ##
  ## A template for the same reason `defaultTuning` is one — see there.
  ShooterState(
    isAiming: false, isProne: false, isMounted: false, isBipod: false,
    isSprinting: false, holdingBreath: false, poseLevel: 1.0, lean: 0.0,
    moveSpeed: 0.0,
    stamina: 1.0, oxygen: 1.0, armStamina: 1.0, exhausted: false,
    armFractured: false, armBlacked: false, neuroTremor: false,
    ergonomics: 50.0, weightKg: 3.5, recoilStat: 100.0,
    exertion: 0.0, handlingFactor: 1.0, supportFactor: 1.0,
    supportSmoothed: 1.0)

# ---------------------------------------------------------------------------
# The physical condition mask
# ---------------------------------------------------------------------------
#
# EFT hands this to the weapon animator rather than exposing it on the player,
# so the game layer takes a copy on the way past and gives it to us here. The
# bit values are BSG's EPhysicalCondition.

const
  PcLeftArmDamaged* = 1
  PcRightArmDamaged* = 2
  PcTremor* = 4

proc applyCondition*(s: var ShooterState; mask: int; blacked: bool;
                     injuryEnabled: bool) =
  ## Decodes the condition mask into the three injury flags.
  s.armFractured = false
  s.armBlacked = false
  s.neuroTremor = false
  if not injuryEnabled:
    return
  let leftDamaged = (mask and PcLeftArmDamaged) != 0
  let rightDamaged = (mask and PcRightArmDamaged) != 0
  s.neuroTremor = (mask and PcTremor) != 0
  s.armBlacked = blacked
  # The game flags an arm as damaged for both a fracture and a blacked limb.
  # If it is damaged but not destroyed, the cause is a fracture.
  s.armFractured = (leftDamaged or rightDamaged) and not blacked

# ---------------------------------------------------------------------------
# Derivation
# ---------------------------------------------------------------------------

proc computeHandling(s: ShooterState; t: Tuning): float =
  # Ergonomics maps onto a bounded curve rather than a bare divide, so a
  # 90-ergo pistol cannot drive sway to zero and a 20-ergo machine gun cannot
  # drive it to infinity.
  let half = fmax(1.0, t.ergoHalfPoint)
  let curve = t.ergoCurve
  let floorV = t.ergoFloor
  let ceilV = fmax(floorV + 0.01, t.ergoCeiling)

  let e = fmax(0.0, s.ergonomics)
  let hp = pow(half, curve)
  let ep = pow(e, curve)
  let denom = hp + ep
  let tt = (if denom > 0.0: hp / denom else: 1.0)
  let ergo = lerpf(floorV, ceilV, tt)

  # Weight on top: a heavy weapon is harder to hold still even when it is
  # ergonomically pleasant.
  let refW = fmax(0.1, t.weightReference)
  let wDelta = (s.weightKg - refW) / refW
  let weight = 1.0 + wDelta * t.weightInfluence * 0.4

  let recoil = 1.0 + (s.recoilStat / 100.0 - 1.0) * t.recoilStatInfluence * 0.25

  result = clampf(ergo * weight * recoil, 0.05, 8.0)

proc computeSupport(s: var ShooterState; t: Tuning; dt: float): float =
  var target = 0.0

  if s.isBipod:
    target = t.bipodMultiplier
  elif s.isMounted:
    target = t.mountedMultiplier
  elif s.isProne:
    target = t.proneMultiplier
  else:
    # Between standing and crouched, blend by how low the player actually is
    # rather than snapping at the pose change.
    let influence = clamp01(t.poseLevelInfluence)
    let posture = lerpf(1.0, s.poseLevel, influence)
    target = lerpf(t.crouchMultiplier, t.standMultiplier, posture)

  # Leaning is unsupported no matter what else is true.
  let leanAbs = (if s.lean < 0.0: -s.lean else: s.lean)
  target = target * lerpf(1.0, t.leanMultiplier, leanAbs)

  if s.isSprinting:
    target = target * t.sprintMultiplier

  let blend = clamp01(dt * t.supportBlendSpeed)
  s.supportSmoothed = s.supportSmoothed + (target - s.supportSmoothed) * blend
  result = s.supportSmoothed

proc derive*(s: var ShooterState; t: Tuning; dt: float) =
  ## Turns the raw fields into `exertion`, `handlingFactor` and
  ## `supportFactor`. Call once per frame, after the raw fields are filled in
  ## and before any source is evaluated.
  s.poseLevel = clamp01(s.poseLevel)
  s.lean = clampf(s.lean, -1.0, 1.0)
  s.moveSpeed = fmax(0.0, s.moveSpeed)
  s.stamina = clamp01(s.stamina)
  s.oxygen = clamp01(s.oxygen)
  s.armStamina = clamp01(s.armStamina)

  # Exertion blends the three drains a body actually has. Stamina is the legs,
  # oxygen is the lungs, arm stamina is what holding a rifle up costs you
  # specifically.
  let stam = 1.0 - s.stamina
  let oxy = 1.0 - s.oxygen
  let arms = 1.0 - s.armStamina

  let wStam = t.staminaInfluence
  let wOxy = t.oxygenInfluence
  let wArms = t.handsStaminaInfluence
  let wSum = wStam + wOxy + wArms

  s.exertion =
    if wSum > 0.0001:
      clamp01((stam * wStam + oxy * wOxy + arms * wArms) / wSum)
    else:
      0.0

  if not t.fatigueEnabled:
    s.exertion = 0.0

  s.handlingFactor = computeHandling(s, t)
  s.supportFactor = computeSupport(s, t, dt)
