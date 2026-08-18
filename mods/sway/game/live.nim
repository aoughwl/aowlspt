## The live game: sampling the shooter, and pushing the model into the springs.
##
## This is the only file in the mod that knows EFT exists. `model/**` is pure
## arithmetic over two records and must stay that way — the simulator ticks it
## with no game in the process, which is what makes a change to the physics
## checkable in a second instead of a raid.
##
## ---------------------------------------------------------------------------
## Why this does not go through `aowlspt/game`
## ---------------------------------------------------------------------------
##
## The comfortable API can now name a live object: `world.child("MainPlayer")`
## hands back a `GameObj` holding an IL2CPP GC handle, and calls on it work.
## That is the right tool for a mod that acts when something happens, and the
## wrong one here for two reasons that are both about *per frame*.
##
## 1. **Cost.** A boxed call is ~1200 ns and a boxed field read ~305 ns
##    (docs/PERF.md). This file makes roughly forty reads and a dozen calls per
##    rendered frame; on the boxed path that is 20-30 µs, which at 144 fps is
##    half a percent of the frame budget spent on JSON. On the fast path the
##    same work is a couple of microseconds.
##
## 2. **The pointer.** The fast path needs a raw object pointer, and a host
##    `Handle` cannot be turned into one from a mod — the handle table lives in
##    the host and the ABI exposes no way through it. So the walk from the world
##    to this player's springs is done here, with the mod's own `Il2Cpp`, and
##    re-done every frame from the root. That is not a workaround: the collector
##    moves objects, so a pointer cached across a frame boundary is a
##    use-after-free waiting for its moment, and re-walking is six loads.
##
## ---------------------------------------------------------------------------
## Which thread this runs on, and why it is not `onUpdate`
## ---------------------------------------------------------------------------
##
## `onUpdate` runs on the host's own attached thread. Writing into a spring from
## there would race the main thread integrating that same spring, and reading
## the shooter from there would sample a half-updated frame.
##
## So the whole per-frame path — sample, step, actuate — is called from the
## detour on `ProceduralWeaponAnimation::LerpCamera`, which runs on whatever
## thread calls it, and that is Unity's main thread. This is where the BepInEx
## original did it too.
##
## One difference from the original, stated because it is a real one: aowlspt's
## `patch` is an inline detour at the method's entry, and the host ignores the
## prefix/postfix distinction — every patch fires *before* the original body. The
## C# used a **postfix**, so it added this mod's impulse after BSG's own
## effectors had had their say. Here the impulse lands at the top of
## `LerpCamera` instead. `AddAcceleration` accumulates into the spring rather
## than setting it, so the difference is one frame of ordering against BSG's
## own contribution, not a different result — but it is a difference, and it
## has never been seen running.
##
## ---------------------------------------------------------------------------
## The Vector3 problem, and what is actually reachable
## ---------------------------------------------------------------------------
##
## `Spring.AddAcceleration(Vector3)` is the target and a `Vector3` argument is
## refused by both of aowlspt's paths:
##
## * **The fast path refuses it by design.** Win64 passes a 12-byte struct by a
##   hidden pointer, which is a different *call shape* rather than a different
##   register class, and `classifyType` will not classify a value type at all
##   (`docs/PERF.md`, "What is still slow, and why").
## * **The host's boxed path cannot build one.** `invoke.nim` binds a
##   non-primitive parameter only from a `{"handle":n}`, and there is no way for
##   a mod to allocate a boxed `UnityEngine.Vector3` and get a handle to it.
##
## What *is* reachable, and what this file does: `il2cpp_runtime_invoke` takes
## an array of pointers to arguments, and for a value type the pointer is to the
## **unboxed data** — a plain 12-byte struct on our own stack. That is the
## documented contract of the C API the whole host is built on, not an
## assumption about a calling convention. The `MethodInfo*` is resolved once, so
## per frame this is two `il2cpp_runtime_invoke` calls with nothing around them:
## no name lookup, no JSON, no boxing of the (void) return.
##
## Two other routes were considered and not taken:
##
## * **A float-per-axis overload.** There is none. `Spring` exposes
##   `AddAcceleration(Vector3)` and nothing narrower.
## * **`bindMethodAs(..., [fkPtr], fkVoid)` and passing `addr vec`.** This would
##   work — MSVC's x64 ABI passes a 12-byte struct as a pointer to a
##   caller-allocated temporary, so the register layout really is
##   `(this, &vec, MethodInfo*)`, three general-purpose slots, which the fast
##   path can express. It would also be ~10 ns instead of a few hundred. It was
##   not taken because it is an *assertion about a calling convention* aimed at
##   a method that moves the player's aim: if the assertion is ever wrong the
##   game reads a Vector3 out of whatever the register happened to hold. Two
##   calls a frame is not worth that. If profiling ever says otherwise, this is
##   the line to change, and it should be changed with a test that reads the
##   spring back.
##
## Everything else — every scalar, every bool, every step of the object chain —
## is on the fast path.

import aowlspt
import aowlspt/il2cpp
import aowlspt/fast
import ".." / model/vec
import ".." / model/tuning
import ".." / model/state
import binding

# `aowlspt/fast` reaches its C side through `importc ... nodecl`, so the
# declarations only exist in the translation unit that `#include`s the header.
# A module that calls `perfCounter` without this gets an implicit declaration
# and a link that happens to work on one compiler and not the next.
{.emit: """#include "aowlspt_fast.h" """.}

# ---------------------------------------------------------------------------
# The runtime
# ---------------------------------------------------------------------------
#
# Every one of these is declared bare and assigned from a proc. A global
# initialised by a *call* is silently left zeroed in a nimony `--app:lib`
# build, and a zeroed `Binding` has `ok = false`, so the failure would be a
# mod that never binds anything and never says why.

var gRt: Il2Cpp
var gOpened = false
var gRuntimeOk = false

proc openRuntime*(): bool =
  ## Binds `GameAssembly.dll`, which is already in this process. Cheap, and
  ## retried until it works: at mod load the runtime may not be up yet.
  if gRuntimeOk:
    return true
  gRt = openIl2Cpp()
  if not gRt.loaded:
    if not gOpened:
      gOpened = true
      warn "sway  GameAssembly.dll is not loaded in this process yet"
    return false
  let missing = missingEssential(gRt)
  if missing.len > 0:
    var names = ""
    for m in missing:
      if names.len > 0: names.add ", "
      names.add m
    warn "sway  the IL2CPP runtime is missing entry points this mod needs: " &
         names
    return false
  gRuntimeOk = true
  success "sway  bound the IL2CPP runtime directly (the host is not on the " &
          "per-frame path)"
  result = true

# ---------------------------------------------------------------------------
# The root
# ---------------------------------------------------------------------------
#
# Everything hangs off one static: the GameWorld singleton. Two spellings are
# tried, in order, and the one that answered is logged — because "the mod does
# nothing" and "the root is named something else on this build" look identical
# from the outside and only one of them is worth reporting as a bug.

var gWorldInstance: Binding      ## static EFT.GameWorld::get_Instance
var gWorldStaticOff: int32 = -1  ## fallback: a static field holding the world
var gWorldStaticData: Il2CppPtr
var gRootTried = false
var gRootWhy = ""

proc bindRoot(): bool =
  if gWorldInstance.ok or gWorldStaticOff >= 0'i32:
    return true
  if gRootTried:
    return false

  var noKinds: seq[FastKind] = @[]
  # `bindMethod` would infer the return type by name and `classifyType` handles
  # a reference fine, but stating it costs nothing and survives a build where
  # `findClass` cannot resolve the *declared* return type even though the
  # method is there.
  gWorldInstance = bindMethodAs(gRt, "EFT.GameWorld", "get_Instance",
                                noKinds, fkPtr)
  if gWorldInstance.ok and gWorldInstance.isStatic:
    info "sway  root: EFT.GameWorld::get_Instance"
    return true

  # Second spelling: a static field on GameWorld whose declared type is
  # GameWorld itself. That is what a hand-rolled singleton looks like, and it is
  # reachable because `il2cpp_class_get_static_field_data` gives the class's
  # static block and the field's offset is an offset into it.
  let cls = findClass(gRt, "EFT.GameWorld")
  if cls == nil:
    gRootTried = true
    gRootWhy = "EFT.GameWorld does not resolve (" & gWorldInstance.why & ")"
    return false
  let data = staticFieldData(gRt, cls)
  if data != nil:
    var iter: Il2CppIter = nullPtr()
    while true:
      let f = nextField(gRt, cls, iter)
      if f == nil:
        break
      if not fieldIsStatic(gRt, f):
        continue
      if typeName(gRt, fieldType(gRt, f)) != "EFT.GameWorld":
        continue
      gWorldStaticData = data
      gWorldStaticOff = int32(fieldOffset(gRt, f))
      info "sway  root: static EFT.GameWorld::" & fieldName(gRt, f)
      return true

  # Both refused. Say so once, with both reasons, and stop trying: this is a
  # build difference, not a timing one — the class resolved, the member did not.
  gRootTried = true
  gRootWhy = "no way to reach the GameWorld singleton: " &
             gWorldInstance.why &
             ", and EFT.GameWorld has no static field of its own type. " &
             "Everything downstream of the shooter is unreachable."
  warn "sway  " & gRootWhy
  result = false

proc worldPtr(): Il2CppPtr =
  result = nullPtr()
  if gWorldInstance.ok:
    var a = noArgs()
    result = callPtr(gWorldInstance, nullPtr(), a)
  elif gWorldStaticOff >= 0'i32 and gWorldStaticData != nil:
    # The static block is a plain allocation, so the field is at
    # `data + offset` and a FieldBinding reads it exactly like an instance one.
    let fb = FieldBinding(ok: true, why: "", target: "EFT.GameWorld static",
                          offset: gWorldStaticOff, kind: fkPtr, bindNs: 0'i64)
    result = readPtr(fb, gWorldStaticData)

# ---------------------------------------------------------------------------
# The object chain
# ---------------------------------------------------------------------------
#
# world -> player -> { ProceduralWeaponAnimation, Physical, MovementContext,
#                      HandsController -> Weapon, HealthController }
# pwa   -> HandsContainer -> { HandsRotation, HandsPosition, CameraRotation }
#
# Each of these is one `Slot`: a field load where BSG left a public field, a
# `get_X` call where they left a property. Bound against the *concrete* class of
# a live object, which is why binding is staged — a member on `Physical` cannot
# be bound until something has handed us a `Physical`.

var gWorldSlots = false
var sMainPlayer: Slot

var gPlayerSlots = false
var sPwa: Slot
var sPhysical: Slot
var sMovement: Slot
var sHands: Slot
var sHealth: Slot

var gPwaSlots = false
var sIsAiming: Slot
var sIsBipod: Slot
var sHandsContainer: Slot
var sBreath: Slot
var sMotion: Slot
var sWalk: Slot
var sForce: Slot
var sHandShake: Slot

var gContainerSlots = false
var sHandsRotation: Slot
var sHandsPosition: Slot
var sCameraRotation: Slot

var gPhysicalSlots = false
var sStamina: Slot
var sOxygen: Slot
var sHandsStamina: Slot
var sExhausted: Slot
var sHoldingBreath: Slot
var gStaminaSlots = false
var sNormalValue: Slot        ## bound on whatever class `Stamina` turned out to be

var gMovementSlots = false
var sIsProne: Slot
var sIsMounted: Slot
var sInMountState: Slot
var sIsSprinting: Slot
var sPoseLevel: Slot
var sTilt: Slot
var sMoveSpeed: Slot
var vRotation: VecSlot        ## the view angles, as a Vector2 field
var vVelocity: VecSlot        ## the body velocity, as a Vector3 field

var gHealthSlots = false
var bBodyPartDestroyed: Binding
var bBodyPartBroken: Binding

var gWeaponSlots = false      ## cleared on every weapon change
var sWeapon: Slot
var sErgonomics: Slot
var sTotalWeight: Slot
var sWeight: Slot
var sRecoilTotal: Slot

# BSG's EBodyPart, by ordinal. These are the one place this file asserts a
# number rather than reading it, because an enum's members are not in the C API
# — `classifyType` refuses enums for the same reason. A wrong ordinal here asks
# about the wrong limb: it cannot crash, and it is worth suspecting if a blacked
# arm never registers.
const BodyPartLeftArm = 3
const BodyPartRightArm = 4

proc bindWorld(world: Il2CppPtr) =
  if gWorldSlots or world == nil:
    return
  gWorldSlots = true
  let t = typeNameOf(gRt, world)
  sMainPlayer = bindSlot(gRt, t, "MainPlayer")
  report("GameWorld::MainPlayer", sMainPlayer)

proc bindPlayer(p: Il2CppPtr) =
  if gPlayerSlots or p == nil:
    return
  gPlayerSlots = true
  let t = typeNameOf(gRt, p)
  info "sway  the local player is a " & t
  sPwa = bindSlot(gRt, t, "ProceduralWeaponAnimation")
  sPhysical = bindSlot(gRt, t, "Physical")
  sMovement = bindSlot(gRt, t, "MovementContext")
  sHands = bindSlot(gRt, t, "HandsController")
  sHealth = bindSlot(gRt, t, "HealthController")
  report("Player::ProceduralWeaponAnimation", sPwa)
  report("Player::Physical", sPhysical)
  report("Player::MovementContext", sMovement)
  report("Player::HandsController", sHands)
  report("Player::HealthController", sHealth)

proc bindPwa(pwa: Il2CppPtr) =
  if gPwaSlots or pwa == nil:
    return
  gPwaSlots = true
  let t = typeNameOf(gRt, pwa)
  sIsAiming = bindSlot(gRt, t, "IsAiming")
  sIsBipod = bindSlot(gRt, t, "IsBipodUsed")
  sHandsContainer = bindSlot(gRt, t, "HandsContainer")
  sBreath = bindSlot(gRt, t, "Breath")
  sMotion = bindSlot(gRt, t, "MotionReact")
  sWalk = bindSlot(gRt, t, "Walk")
  sForce = bindSlot(gRt, t, "ForceReact")
  sHandShake = bindSlot(gRt, t, "HandShakeEffector")
  report("PWA::IsAiming", sIsAiming)
  report("PWA::IsBipodUsed", sIsBipod)
  report("PWA::HandsContainer", sHandsContainer)

proc bindContainer(hc: Il2CppPtr) =
  if gContainerSlots or hc == nil:
    return
  gContainerSlots = true
  let t = typeNameOf(gRt, hc)
  sHandsRotation = bindSlot(gRt, t, "HandsRotation")
  sHandsPosition = bindSlot(gRt, t, "HandsPosition")
  sCameraRotation = bindSlot(gRt, t, "CameraRotation")
  report("HandsContainer::HandsRotation", sHandsRotation)
  report("HandsContainer::CameraRotation", sCameraRotation)

proc bindPhysical(ph: Il2CppPtr) =
  if gPhysicalSlots or ph == nil:
    return
  gPhysicalSlots = true
  let t = typeNameOf(gRt, ph)
  sStamina = bindSlot(gRt, t, "Stamina")
  sOxygen = bindSlot(gRt, t, "Oxygen")
  sHandsStamina = bindSlot(gRt, t, "HandsStamina")
  sExhausted = bindSlot(gRt, t, "Exhausted")
  sHoldingBreath = bindSlot(gRt, t, "HoldingBreath")
  report("Physical::Stamina", sStamina)
  report("Physical::Oxygen", sOxygen)
  report("Physical::HandsStamina", sHandsStamina)
  report("Physical::Exhausted", sExhausted)
  report("Physical::HoldingBreath", sHoldingBreath)

proc bindStamina(st: Il2CppPtr) =
  ## `Physical.Stamina` is an object, not a number. All three of the meters
  ## share a class, so this binds once against whichever of them arrived first.
  if gStaminaSlots or st == nil:
    return
  gStaminaSlots = true
  let t = typeNameOf(gRt, st)
  sNormalValue = bindSlot(gRt, t, "NormalValue")
  report("Stamina::NormalValue", sNormalValue)

proc bindMovement(mc: Il2CppPtr) =
  if gMovementSlots or mc == nil:
    return
  gMovementSlots = true
  let t = typeNameOf(gRt, mc)
  sIsProne = bindSlot(gRt, t, "IsInPronePose")
  sIsMounted = bindSlot(gRt, t, "IsInMountedState")
  sInMountState = bindSlot(gRt, t, "InMountState")
  sIsSprinting = bindSlot(gRt, t, "IsSprintEnabled")
  sPoseLevel = bindSlot(gRt, t, "PoseLevel")
  sTilt = bindSlot(gRt, t, "Tilt")
  sMoveSpeed = bindSlot(gRt, t, "SmoothedCharacterMovementSpeed")
  report("MovementContext::PoseLevel", sPoseLevel)
  report("MovementContext::Tilt", sTilt)
  report("MovementContext::SmoothedCharacterMovementSpeed", sMoveSpeed)

  # The two inputs that are vectors. `Rotation` is a `Vector2` and `Velocity` a
  # `Vector3`, and a value-type *return* is unreachable on either path — so
  # these go through the backing field, found by scanning for a vector field
  # whose name looks right. The name it settled on is logged: a wrong match here
  # would drive the inertia oscillator off the wrong number, and that must be
  # visible in the log rather than only in the feel.
  var found = ""
  vRotation = findVecFieldNamed(gRt, t, "rotation", 2, found)
  if vRotation.ok:
    info "sway  view angles from " & t & "::" & found & " (Vector2)"
  else:
    warn "sway  no view-angle field on " & t & ": " & vRotation.why &
         ". Weapon inertia will be driven at rest — the oscillator stays " &
         "centred and every other source is unaffected."
  vVelocity = findVecFieldNamed(gRt, t, "velocity", 3, found)
  if vVelocity.ok:
    info "sway  body velocity from " & t & "::" & found & " (Vector3)"
  else:
    warn "sway  no velocity field on " & t & ": " & vVelocity.why &
         ". Inertia will not be driven by the body accelerating, only by " &
         "turning."

proc bindHealth(hcon: Il2CppPtr) =
  if gHealthSlots or hcon == nil:
    return
  gHealthSlots = true
  let t = typeNameOf(gRt, hcon)
  # `IsBodyPartDestroyed(EBodyPart)` — an enum argument, which `bindMethod`
  # refuses to classify (nothing in the C API says which integer width an enum
  # is). EBodyPart is a plain `int`-backed enum, so the register class is a
  # 32-bit integer and `bindMethodAs` is the way to say so.
  var kinds: seq[FastKind] = @[]
  kinds.add fkI32
  bBodyPartDestroyed = bindMethodAs(gRt, t, "IsBodyPartDestroyed", kinds,
                                    fkBool)
  if bBodyPartDestroyed.ok:
    debug "sway  bound " & bBodyPartDestroyed.why
  else:
    warn "sway  a blacked arm will not be noticed: " & bBodyPartDestroyed.why

  # A fracture, asked for directly.
  #
  # The BepInEx original could not do this: it took the whole
  # `EPhysicalCondition` mask out of the argument to
  # `PhysicalConditionUpdated`. That argument is still unreadable here — see
  # `sway.nim` on why this mod does not use `hookArgs` on that method — so the
  # health controller is asked about each arm instead. Where it answers, the
  # mask is not needed at all.
  bBodyPartBroken = bindMethodAs(gRt, t, "IsBodyPartBroken", kinds, fkBool)
  if not bBodyPartBroken.ok:
    warn "sway  an arm fracture will not be noticed: " & bBodyPartBroken.why

proc bindWeapon(controller, weapon: Il2CppPtr) =
  ## The one group that is rebound **per weapon change** rather than per
  ## session: the hands controller's class differs between a firearm, a knife
  ## and a grenade, and only one of those has a `Weapon` at all.
  if gWeaponSlots:
    return
  if controller == nil:
    return
  let ct = typeNameOf(gRt, controller)
  if not sWeapon.bound():
    sWeapon = bindSlot(gRt, ct, "Weapon")
  if weapon == nil:
    # The controller bound, but there is nothing in the shooter's hands this
    # frame. Not an error and not final: try again next frame.
    return
  gWeaponSlots = true
  let wt = typeNameOf(gRt, weapon)
  sErgonomics = bindSlot(gRt, wt, "ErgonomicsTotal")
  sTotalWeight = bindSlot(gRt, wt, "TotalWeight")
  sWeight = bindSlot(gRt, wt, "Weight")
  sRecoilTotal = bindSlot(gRt, wt, "RecoilTotal")
  info "sway  weapon: " & wt
  report("Weapon::ErgonomicsTotal", sErgonomics)
  report("Weapon::TotalWeight", sTotalWeight)
  report("Weapon::RecoilTotal", sRecoilTotal)

# ---------------------------------------------------------------------------
# Section 12 and 13: the overrides
# ---------------------------------------------------------------------------
#
# The BepInEx build wrote BSG's own spring constants and effector parameters
# every frame; the nimony port read the same tunables out of config.json and
# applied none of them, because every one is an instance-field write. They are
# applied here.
#
# Two rules carried over from the C#, both load-bearing:
#
# * **Every section-13 value is a multiplier against what the game shipped**,
#   captured once. Writing absolute numbers would break the moment BSG retune a
#   weapon class; re-reading the live value each frame would compound the scale
#   until the gun left the screen.
# * **The originals are re-captured on a weapon change**, because
#   `InitWeaponData` reinitialises the effectors from the new weapon's data —
#   so what is in them at that moment is BSG's, not ours.
#
# Section 12 (the springs) is different in kind: those are absolute values, not
# multipliers, because a damping ratio has no meaningful "scaled" version.
#
# The table is int-indexed rather than enum-indexed because nimony has neither
# enum-indexed arrays nor iteration over an enum type.

const
  OwHandsRot = 0
  OwHandsPos = 1
  OwCameraRot = 2
  OwBreath = 3
  OwMotion = 4
  OwWalk = 5
  OwHandShake = 6
  OwForce = 7
  OwPwa = 8
  OwTremorX = 9
  OwTremorY = 10
  OwTremorZ = 11
  OwCount = 12

const
  # -- section 12: absolute spring constants --------------------------------
  KnHandsRotDamping = 0
  KnHandsRotReturn = 1
  KnHandsRotAccelMax = 2
  KnHandsRotInput = 3
  KnHandsRotSoftness = 4
  KnHandsPosDamping = 5
  KnHandsPosReturn = 6
  KnCamRotDamping = 7
  KnCamRotReturn = 8
  KnSpringEnd = 9        ## knobs below this index are springs, above are vanilla
  # -- section 13: multipliers on captured originals ------------------------
  KnBreathIntensity = 9
  KnBreathIntensityField = 10
  KnBreathFrequency = 11
  KnBreathShake = 12
  KnBreathHipPenalty = 13
  KnBreathCameraSens = 14
  KnTremorXAmp = 15
  KnTremorXHard = 16
  KnTremorYAmp = 17
  KnTremorYHard = 18
  KnTremorZAmp = 19
  KnTremorZHard = 20
  KnMotionIntensity = 21
  KnMotionClamp = 22
  KnWalkIntensity = 23
  KnWalkStep = 24
  KnHandShake = 25
  KnForceIntensity = 26
  KnSwayFalloff = 27
  KnCount = 28

const KnobOwner: array[KnCount, int] = [
  OwHandsRot, OwHandsRot, OwHandsRot, OwHandsRot, OwHandsRot,
  OwHandsPos, OwHandsPos,
  OwCameraRot, OwCameraRot,
  OwBreath, OwBreath, OwBreath, OwBreath, OwBreath, OwBreath,
  OwTremorX, OwTremorX, OwTremorY, OwTremorY, OwTremorZ, OwTremorZ,
  OwMotion, OwMotion,
  OwWalk, OwWalk,
  OwHandShake,
  OwForce,
  OwPwa]

const KnobMember: array[KnCount, string] = [
  "Damping", "ReturnSpeed", "AccelerationMax", "InputIntensity", "Softness",
  "Damping", "ReturnSpeed",
  "Damping", "ReturnSpeed",
  # `Intensity` is the property and `_breathIntensity` its backing field; the
  # C# wrote both, because the property setter does not always reach the field
  # the effector actually reads.
  "Intensity", "_breathIntensity", "_breathFrequency", "_shakeIntensity",
  "HipPenalty", "_cameraSensetivity",
  "Amplitude", "Hardness", "Amplitude", "Hardness", "Amplitude", "Hardness",
  "Intensity", "RotationInputClamp",
  "Intensity", "StepFrequency",
  "_shakeIntensity",
  "Intensity",
  "SwayFalloff"]

var gOwner: array[OwCount, Il2CppPtr]     ## refreshed every frame
var gOwnerBound: array[OwCount, bool]
var gKnob: array[KnCount, Slot]
var gKnobOrig: array[KnCount, float]
var gTremorOn: Slot                       ## the one bool knob
var gTremorOnOrig = true
var vMotionSway: VecSlot
var vAimSwayMin: VecSlot
var vAimSwayMax: VecSlot
var gMotionSwayOrig = Zero3
var gAimMinOrig = Zero3
var gAimMaxOrig = Zero3
var gCaptured = false
var gAppliedOnce = false
var gOverrideReported = false

proc bindKnobsFor(owner: int) =
  ## Binds every knob living on one owner, the first frame that owner exists.
  if gOwnerBound[owner] or gOwner[owner] == nil:
    return
  gOwnerBound[owner] = true
  let t = typeNameOf(gRt, gOwner[owner])
  for i in 0 ..< KnCount:
    if KnobOwner[i] != owner:
      continue
    gKnob[i] = bindSlot(gRt, t, KnobMember[i], wantWrite = true)
    if not gKnob[i].writable():
      # Reported at debug, not warn: a build where BSG renamed one private
      # field should cost that one knob, and section 13 is off by default.
      debug "sway  override " & t & "::" & KnobMember[i] &
            " unavailable: " & gKnob[i].why
  if owner == OwBreath:
    gTremorOn = bindSlot(gRt, t, "TremorOn", wantWrite = true)
  elif owner == OwMotion:
    vMotionSway = bindVecField(gRt, t, "SwayFactors", 3)
  elif owner == OwPwa:
    vAimSwayMin = bindVecField(gRt, t, "AimSwayMin", 3)
    vAimSwayMax = bindVecField(gRt, t, "AimSwayMax", 3)

proc knobTarget(i: int; t: Tuning; orig: float): float =
  ## What knob `i` should hold. Below `KnSpringEnd` the config value is
  ## absolute; above it, it is a multiplier on what the game shipped.
  case i
  of KnHandsRotDamping: result = t.handsRotDamping
  of KnHandsRotReturn: result = t.handsRotReturnSpeed
  of KnHandsRotAccelMax: result = t.handsRotAccelerationMax
  of KnHandsRotInput: result = t.handsRotInputIntensity
  of KnHandsRotSoftness: result = t.handsRotSoftness
  of KnHandsPosDamping: result = t.handsPosDamping
  of KnHandsPosReturn: result = t.handsPosReturnSpeed
  of KnCamRotDamping: result = t.cameraRotDamping
  of KnCamRotReturn: result = t.cameraRotReturnSpeed
  of KnBreathIntensity: result = orig * t.vanillaBreathIntensity
  of KnBreathIntensityField: result = orig * t.vanillaBreathIntensity
  of KnBreathFrequency: result = orig * t.vanillaBreathFrequency
  of KnBreathShake: result = orig * t.vanillaBreathShake
  of KnBreathHipPenalty: result = orig * t.vanillaBreathHipPenalty
  of KnBreathCameraSens: result = orig * t.vanillaBreathCameraSens
  of KnTremorXAmp: result = orig * t.vanillaBreathTremorAmplitude
  of KnTremorXHard: result = orig * t.vanillaBreathTremorHardness
  of KnTremorYAmp: result = orig * t.vanillaBreathTremorAmplitude
  of KnTremorYHard: result = orig * t.vanillaBreathTremorHardness
  of KnTremorZAmp: result = orig * t.vanillaBreathTremorAmplitude
  of KnTremorZHard: result = orig * t.vanillaBreathTremorHardness
  of KnMotionIntensity: result = orig * t.vanillaMotionIntensity
  of KnMotionClamp: result = orig * t.vanillaMotionInputClamp
  of KnWalkIntensity: result = orig * t.vanillaWalkIntensity
  of KnWalkStep: result = orig * t.vanillaWalkStepFrequency
  of KnHandShake: result = orig * t.vanillaHandShakeIntensity
  of KnForceIntensity: result = orig * t.vanillaForceIntensity
  of KnSwayFalloff: result = orig * t.vanillaSwayFalloff
  else: result = orig

proc captureOriginals() =
  ## Reads BSG's own values, once per weapon.
  ##
  ## Anything not yet wired up (a null effector on the frame the weapon is
  ## being built) aborts the capture so it is retried, rather than recording a
  ## zero and then multiplying it forever.
  if gCaptured:
    return
  for i in 0 ..< KnCount:
    let o = gOwner[KnobOwner[i]]
    if o == nil:
      continue
    gKnobOrig[i] = gKnob[i].getF(o, gKnobOrig[i])
  if gOwner[OwBreath] != nil:
    gTremorOnOrig = gTremorOn.getB(gOwner[OwBreath], true)
  if gOwner[OwMotion] != nil and vMotionSway.ok:
    gMotionSwayOrig = vec3(vMotionSway.getX(gOwner[OwMotion]),
                           vMotionSway.getY(gOwner[OwMotion]),
                           vMotionSway.getZ(gOwner[OwMotion]))
  if gOwner[OwPwa] != nil:
    if vAimSwayMin.ok:
      gAimMinOrig = vec3(vAimSwayMin.getX(gOwner[OwPwa]),
                         vAimSwayMin.getY(gOwner[OwPwa]),
                         vAimSwayMin.getZ(gOwner[OwPwa]))
    if vAimSwayMax.ok:
      gAimMaxOrig = vec3(vAimSwayMax.getX(gOwner[OwPwa]),
                         vAimSwayMax.getY(gOwner[OwPwa]),
                         vAimSwayMax.getZ(gOwner[OwPwa]))
  # The springs are the group that must exist for any of this to be meaningful.
  if gOwner[OwHandsRot] != nil:
    gCaptured = true

proc applyOverrides(t: Tuning) =
  ## Section 12 and 13, every frame.
  ##
  ## Written every frame rather than once, and that is deliberate: BSG's own
  ## code writes these back — `InitWeaponData`, an aim change, a mounted state —
  ## so a one-shot write would hold for a few frames and then quietly stop.
  ## The cost is ~30 stores at two nanoseconds each.
  ##
  ## When a switch is off the *originals* are written back rather than nothing
  ## being written, so turning it off at runtime restores the game rather than
  ## leaving the last scaled value in place.
  if not gCaptured:
    return
  # Both switches ship off, and a mod that has never been asked to touch BSG's
  # numbers should not be writing to them thirty times a frame — even writing
  # back the value that is already there. The latch is what makes turning a
  # switch off at runtime still restore the game: once we have written, we
  # remain responsible for putting it back.
  let anyOn = t.springOverride or t.vanillaOverride
  if not anyOn and not gAppliedOnce:
    return
  if anyOn:
    gAppliedOnce = true

  for i in 0 ..< KnCount:
    if not gKnob[i].writable():
      continue
    let o = gOwner[KnobOwner[i]]
    if o == nil:
      continue
    let on = (if i < KnSpringEnd: t.springOverride else: t.vanillaOverride)
    gKnob[i].setF(o, (if on: knobTarget(i, t, gKnobOrig[i]) else: gKnobOrig[i]))

  let breath = gOwner[OwBreath]
  if breath != nil and gTremorOn.writable():
    gTremorOn.setB(breath, (if t.vanillaOverride:
                              gTremorOnOrig and t.vanillaBreathTremorOn
                            else: gTremorOnOrig))
  let motion = gOwner[OwMotion]
  if motion != nil and vMotionSway.ok:
    if t.vanillaOverride:
      vMotionSway.setXYZ(motion,
                         gMotionSwayOrig.x * t.vanillaMotionSwayX,
                         gMotionSwayOrig.y * t.vanillaMotionSwayY,
                         gMotionSwayOrig.z * t.vanillaMotionSwayZ)
    else:
      vMotionSway.setXYZ(motion, gMotionSwayOrig.x, gMotionSwayOrig.y,
                         gMotionSwayOrig.z)
  let pwa = gOwner[OwPwa]
  if pwa != nil:
    let a = (if t.vanillaOverride: t.vanillaAimSwayScale else: 1.0)
    if vAimSwayMin.ok:
      vAimSwayMin.setXYZ(pwa, gAimMinOrig.x * a, gAimMinOrig.y * a,
                         gAimMinOrig.z * a)
    if vAimSwayMax.ok:
      vAimSwayMax.setXYZ(pwa, gAimMaxOrig.x * a, gAimMaxOrig.y * a,
                         gAimMaxOrig.z * a)

  if not gOverrideReported and (t.springOverride or t.vanillaOverride):
    gOverrideReported = true
    var n = 0
    for i in 0 ..< KnCount:
      if gKnob[i].writable(): inc n
    success "sway  overriding BSG's own values: " & $n & " of " & $KnCount &
            " tunables bound (springs " &
            (if t.springOverride: "on" else: "off") & ", effectors " &
            (if t.vanillaOverride: "on" else: "off") & ")"

# ---------------------------------------------------------------------------
# Actuation
# ---------------------------------------------------------------------------

type
  Vector3F {.bycopy.} = object
    ## `UnityEngine.Vector3` exactly: three 32-bit floats, twelve bytes, no
    ## padding. `il2cpp_runtime_invoke` is handed a pointer to one of these,
    ## which is what it wants for a value-type argument. The model's own `Vec3`
    ## is three 64-bit floats and is deliberately not this type — `model/vec`
    ## must not know a game exists.
    x: float32
    y: float32
    z: float32

var gAddAccel: Il2CppMethod    ## Spring::AddAcceleration, resolved once
var gSpringTried = false
var gSpringWhy = ""
var gActuated = false

proc bindSpringMethod(spring: Il2CppPtr) =
  if gAddAccel != nil or gSpringTried or spring == nil:
    return
  gSpringTried = true
  let cls = objectClass(gRt, spring)
  if cls == nil:
    gSpringWhy = "the spring object has no class"
    warn "sway  " & gSpringWhy
    return
  let m = findMethod(gRt, cls, "AddAcceleration", 1)
  if m == nil:
    gSpringWhy = typeNameOf(gRt, spring) &
      " has no AddAcceleration taking one argument. Nothing this mod " &
      "computes can reach the weapon."
    warn "sway  " & gSpringWhy
    return
  gAddAccel = m
  info "sway  actuator: " & typeNameOf(gRt, spring) & "::AddAcceleration"

proc addAcceleration(spring: Il2CppPtr; v: Vec3) =
  ## The one call that moves the weapon.
  ##
  ## Not on the fast path, and the module header says at length why: a 12-byte
  ## value-type argument is a different call shape rather than a different
  ## register class. `il2cpp_runtime_invoke` takes a pointer to the unboxed
  ## value, which is the documented contract, and with the `MethodInfo*` already
  ## in hand it is a few hundred nanoseconds rather than the ~1200 of a call
  ## made by name through the host.
  if gAddAccel == nil or spring == nil:
    return
  var value = Vector3F(x: float32(v.x), y: float32(v.y), z: float32(v.z))
  # Initialised at the declaration rather than assigned into: nimony will not
  # take the address of an array it cannot prove was written.
  var argv: array[1, Il2CppPtr] = [cast[Il2CppPtr](addr value)]
  var exc: Il2CppException = nullPtr()
  discard invoke(gRt, gAddAccel, spring, cast[Il2CppPtr](addr argv[0]), exc)
  # A managed throw does not unwind through a C caller; it arrives as a written
  # pointer. Ignoring it would turn a broken actuation into a mod that looks
  # like it is working.
  if exc != nil and not gActuated:
    warn "sway  AddAcceleration threw on its first call; the weapon will " &
         "not move"

# ---------------------------------------------------------------------------
# Sampling
# ---------------------------------------------------------------------------

proc normalisedMeter(meter: Il2CppPtr): float =
  ## A stamina meter as 0..1. Anything unreadable answers 1 — the healthy end —
  ## so a member that moved in a game update costs that one signal rather than
  ## inventing a shooter who is dying.
  result = 1.0
  if meter == nil:
    return
  bindStamina(meter)
  if sNormalValue.bound():
    result = clamp01(sNormalValue.getF(meter, 1.0))

# One frame's pointers, filled by `walk` and used by the rest. Locals would be
# tidier; nimony has no closures over enclosing locals, so state that several
# top-level procs share has to be at module scope.
var pWorld: Il2CppPtr
var pPlayer: Il2CppPtr
var pPwa: Il2CppPtr
var pContainer: Il2CppPtr
var pHandsRot: Il2CppPtr
var pCamRot: Il2CppPtr

proc walk(): bool =
  ## World -> player -> animator -> springs, from the root, every frame.
  ##
  ## Six reads. Doing it again each frame rather than caching is what makes the
  ## raw pointers safe: the collector moves objects between frames and a stored
  ## pointer would be a use-after-free with no symptom until it had one.
  pWorld = nullPtr(); pPlayer = nullPtr(); pPwa = nullPtr()
  pContainer = nullPtr(); pHandsRot = nullPtr(); pCamRot = nullPtr()
  for i in 0 ..< OwCount:
    gOwner[i] = nullPtr()

  pWorld = worldPtr()
  if pWorld == nil:
    return false          # not in a raid. Not an error.
  bindWorld(pWorld)
  pPlayer = sMainPlayer.getP(pWorld)
  if pPlayer == nil:
    return false
  bindPlayer(pPlayer)
  pPwa = sPwa.getP(pPlayer)
  if pPwa == nil:
    return false
  bindPwa(pPwa)
  pContainer = sHandsContainer.getP(pPwa)
  if pContainer == nil:
    return false
  bindContainer(pContainer)
  pHandsRot = sHandsRotation.getP(pContainer)
  pCamRot = sCameraRotation.getP(pContainer)

  gOwner[OwPwa] = pPwa
  gOwner[OwHandsRot] = pHandsRot
  gOwner[OwCameraRot] = pCamRot
  gOwner[OwHandsPos] = sHandsPosition.getP(pContainer)
  gOwner[OwBreath] = sBreath.getP(pPwa)
  gOwner[OwMotion] = sMotion.getP(pPwa)
  gOwner[OwWalk] = sWalk.getP(pPwa)
  gOwner[OwForce] = sForce.getP(pPwa)
  gOwner[OwHandShake] = sHandShake.getP(pPwa)
  result = true

var sTremorX: Slot
var sTremorY: Slot
var sTremorZ: Slot
var gTremorRandomBound = false

proc walkTremorRandoms() =
  ## The three `Random`-shaped objects behind BSG's own tremor. Only reached
  ## when section 13 is on, because binding three more classes is not worth it
  ## for a switch that ships off.
  let breath = gOwner[OwBreath]
  if breath == nil:
    return
  if not gTremorRandomBound:
    gTremorRandomBound = true
    let t = typeNameOf(gRt, breath)
    sTremorX = bindSlot(gRt, t, "TremorXRandom")
    sTremorY = bindSlot(gRt, t, "TremorYRandom")
    sTremorZ = bindSlot(gRt, t, "TremorZRandom")
  gOwner[OwTremorX] = sTremorX.getP(breath)
  gOwner[OwTremorY] = sTremorY.getP(breath)
  gOwner[OwTremorZ] = sTremorZ.getP(breath)

proc sample*(s: var ShooterState) =
  ## Fills the raw half of `ShooterState` from the game. The derived half is
  ## `state.derive`, which is in `model/` and knows nothing about any of this.
  s.isAiming = sIsAiming.getB(pPwa, s.isAiming)
  s.isBipod = sIsBipod.getB(pPwa, false)

  let mc = sMovement.getP(pPlayer)
  if mc != nil:
    bindMovement(mc)
    s.isProne = sIsProne.getB(mc, false)
    # Two spellings of the same state, and the C# read both: a mounted weapon
    # and a mounted *player* are separate flags on this type.
    s.isMounted = sIsMounted.getB(mc, false) or sInMountState.getB(mc, false)
    s.isSprinting = sIsSprinting.getB(mc, false)
    s.poseLevel = clamp01(sPoseLevel.getF(mc, 1.0))
    s.lean = clampf(sTilt.getF(mc, 0.0), -1.0, 1.0)
    s.moveSpeed = fmax(0.0, sMoveSpeed.getF(mc, 0.0))

  let ph = sPhysical.getP(pPlayer)
  if ph != nil:
    bindPhysical(ph)
    s.stamina = normalisedMeter(sStamina.getP(ph))
    s.oxygen = normalisedMeter(sOxygen.getP(ph))
    s.armStamina = normalisedMeter(sHandsStamina.getP(ph))
    s.exhausted = sExhausted.getB(ph, s.stamina <= 0.02)
    s.holdingBreath = sHoldingBreath.getB(ph, false)

  let hc = sHands.getP(pPlayer)
  if hc != nil:
    let w = sWeapon.getP(hc)
    bindWeapon(hc, w)
    if w != nil:
      s.ergonomics = sErgonomics.getF(w, s.ergonomics)
      # `TotalWeight` includes mods and a loaded magazine, which is what the
      # shooter is actually holding up. `Weight` is the bare receiver and is
      # only the fallback.
      if sTotalWeight.bound():
        s.weightKg = sTotalWeight.getF(w, s.weightKg)
      else:
        s.weightKg = sWeight.getF(w, s.weightKg)
      s.recoilStat = sRecoilTotal.getF(w, s.recoilStat)

proc eitherArm(b: Binding; hcon: Il2CppPtr): bool =
  result = false
  if not b.ok or hcon == nil:
    return
  var l = argsI(int64(BodyPartLeftArm))
  if callBool(b, hcon, l):
    return true
  var r = argsI(int64(BodyPartRightArm))
  result = callBool(b, hcon, r)

proc sampleArmInjury*(fractured, blacked: var bool): bool =
  ## Whether either arm is broken or destroyed, asked of the health controller.
  ##
  ## Returns false when the health controller could not be reached at all, so
  ## the caller can tell "no injury" from "no answer" — those scale sway by 1
  ## and by up to 2.4 respectively, and confusing them is a bad frame.
  fractured = false
  blacked = false
  let hcon = sHealth.getP(pPlayer)
  if hcon == nil:
    return false
  bindHealth(hcon)
  blacked = eitherArm(bBodyPartDestroyed, hcon)
  # The game flags an arm as damaged for both a fracture and a blacked limb;
  # if it is broken but not destroyed, the cause is a fracture.
  fractured = eitherArm(bBodyPartBroken, hcon) and not blacked
  result = bBodyPartDestroyed.ok or bBodyPartBroken.ok

proc viewAngles*(yaw, pitch: var float): bool =
  ## This frame's view angles, in degrees. The inertia oscillator is driven
  ## from where the view actually ended up rather than from raw mouse input, so
  ## sensitivity changes, controllers and any other mod that moves the view all
  ## feed it the same way.
  yaw = 0.0
  pitch = 0.0
  if not vRotation.ok:
    return false
  let mc = sMovement.getP(pPlayer)
  if mc == nil:
    return false
  yaw = vRotation.getX(mc)
  pitch = vRotation.getY(mc)
  result = true

proc bodyVelocity*(): Vec3 =
  result = Zero3
  if not vVelocity.ok:
    return
  let mc = sMovement.getP(pPlayer)
  if mc == nil:
    return
  result = vec3(vVelocity.getX(mc), vVelocity.getY(mc), vVelocity.getZ(mc))

# ---------------------------------------------------------------------------
# The frame
# ---------------------------------------------------------------------------

proc beginFrame*(t: Tuning): bool =
  ## Everything before the model runs: reach the game, bind whatever is newly
  ## reachable, and put BSG's own numbers where the config says they go.
  ##
  ## False means "not in a raid, or the chain is broken" — the caller does
  ## nothing that frame rather than stepping the model against stale state.
  if not gRuntimeOk:
    return false
  if not bindRoot():
    return false
  if not walk():
    return false
  if t.vanillaOverride:
    walkTremorRandoms()
  bindSpringMethod(pHandsRot)
  for i in 0 ..< OwCount:
    bindKnobsFor(i)
  captureOriginals()
  applyOverrides(t)
  result = true

proc onWeaponChanged*() =
  ## Rebind the weapon-dependent half and re-capture BSG's defaults.
  ##
  ## The *type-level* bindings — offsets and function pointers — belong to the
  ## class and survive; only the hands controller's class can genuinely change,
  ## which is why that is the one group cleared here.
  gWeaponSlots = false
  sWeapon = bindSlot(gRt, "", "Weapon")   # forget the old controller's class
  gCaptured = false

proc actuate*(hands, camera: Vec3; t: Tuning) =
  ## Model output in degrees -> the game's rotation springs.
  ##
  ## The impulse itself is computed by `model/director.springImpulse`, which is
  ## in `model/` because it is arithmetic; this is only the push.
  ##
  ## ------------------------------------------------------------------------
  ## `driveGain` — the one number here that has never been measured
  ## ------------------------------------------------------------------------
  ## `springImpulse` multiplies by `t.driveGain`, whose shipped value of 8 was
  ## derived analytically from the spring's return speed and damping and has
  ## NEVER BEEN PLAYTESTED. Until this file existed that did not matter, because
  ## nothing was pushed anywhere. It matters now: it is the entire calibration
  ## between the model's degrees and what the springs do with them. If the whole
  ## mod feels uniformly too strong or too weak while the sources look right
  ## relative to each other, this is the first suspect — see
  ## `tuning.DriveGainProvenance`.
  if gAddAccel == nil:
    return
  if pHandsRot != nil and sqrMagnitude(hands) > 0.0:
    addAcceleration(pHandsRot, hands)
  if pCamRot != nil and sqrMagnitude(camera) > 0.0:
    addAcceleration(pCamRot, camera)
  if not gActuated:
    gActuated = true
    success "sway  the model is now driving the weapon springs"
    warn "sway  Drive Gain is " & (if t.driveGain == 8.0:
           "the shipped 8.0, which was derived analytically and has never " &
           "been playtested against a running game"
         else:
           "set to a value other than the shipped default") &
         " — if the mod feels uniformly too strong or too weak, suspect it " &
         "before the per-source amplitudes"

proc actuating*(): bool = gActuated
proc rootWhy*(): string = gRootWhy
proc springWhy*(): string = gSpringWhy

proc frameDelta*(lastTicks: var int64): float =
  ## Seconds since this was last called, on `QueryPerformanceCounter`.
  ##
  ## `LerpCamera` is handed the frame's own `dt` and this mod does not read it
  ## (see `sway.nim`); the interval between two firings of a detour on it is
  ## that same delta, it costs about twenty nanoseconds, and the model clamps
  ## it to a sane band anyway. The first frame has nothing to measure against
  ## and answers 60 Hz.
  let now = perfCounter()
  result = 1.0 / 60.0
  if lastTicks != 0'i64:
    result = float(nanosBetween(lastTicks, now)) * 0.000000001
  lastTicks = now
