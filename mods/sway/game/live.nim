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
## Vector3, and the shape of a call
## ---------------------------------------------------------------------------
##
## `Spring.AddAcceleration(Vector3)` is the target, and a `Vector3` is neither
## a register class nor a handle:
##
## * **`bindMethod` refuses it, correctly.** `classifyType` will not classify a
##   value type, because a value type wider than eight bytes is not passed in a
##   register at all.
## * **The host's boxed path cannot build one.** `invoke.nim` binds a
##   non-primitive parameter only from a `{"handle":n}`, and a mod has no way to
##   allocate a boxed `UnityEngine.Vector3` and get a handle to it.
##
## What closes the gap is `bindRaw`: a method bound by its **native slot shape**
## rather than by its signature. Win64 passes anything larger than eight bytes
## and not a power of two by hidden pointer, and returns it the same way — the
## caller allocates the space, passes its address, and the callee writes through
## it. So:
##
##     void AddAcceleration(Vector3 v)   is really
##     void AddAcceleration(void* this, void* v, MethodInfo*)
##
##     Vector3 Transform::get_eulerAngles()   is really
##     void*   get_eulerAngles(void* sret, void* this, MethodInfo*)
##
## Every slot in both is a plain pointer, which the existing trampoline table
## already passes. This file states those two shapes and nothing else. Both
## assertions are written out at their call sites, because a wrong one is a call
## into the game with the arguments in the wrong registers rather than an error.
##
## An earlier revision of this file used `il2cpp_runtime_invoke` with a pointer
## to the unboxed struct — the documented contract, and correct, but a few
## hundred nanoseconds and a generic dispatch per call on a path that runs twice
## a frame. The shaped call is about ten.
##
## Two other routes, for the record: there is no float-per-axis overload of
## `AddAcceleration`, and there is no field on `Spring` to write instead —
## `AddAcceleration` clamps against `AccelerationMax` on the way in, so writing
## the accumulator directly would skip the clamp this mod also configures.
##
## Everything else — every scalar, every bool, every step of the object chain —
## is on the ordinary fast path.

import aowlspt
import aowlspt/il2cpp
import aowlspt/fast
import ".." / model/vec
import ".." / model/tuning
import ".." / model/state
import ".." / model/spring
import ".." / model/fmt
import binding

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
var gWorldStatic: StaticFieldBinding
                                 ## fallback: a static field holding the world
var gRootTried = false
var gRootWhy = ""

proc staticFieldOfType*(rt: Il2Cpp; owner, declared: string;
                        outName: var string): StaticFieldBinding =
  ## The **static** field of `owner` whose declared type is `declared`, bound.
  ##
  ## Split out of `bindRoot` for one reason: `bindRoot`'s use of it can never
  ## run anywhere this project can execute. `EFT.GameWorld::get_Instance`
  ## exists on the stand-in and on every build of the game anyone has looked
  ## at, so the fallback below it is dead code in every environment that has a
  ## runtime at all — and dead code that nothing has run is dead code that has
  ## never been shown to work. `probeStaticRoot` calls this against a type the
  ## stand-in *does* have a static field on, so the walk-then-bind path itself
  ## has been executed by the time the fallback needs it.
  ##
  ## The walk is by declared type because the *name* is what is unknown: a
  ## hand-rolled singleton may be `Instance`, `_instance` or anything else, and
  ## what identifies it is that it is static and holds one of its own class.
  ## `bindStaticField` takes a name, so the walk supplies it.
  outName = ""
  result = StaticFieldBinding(ok: false, why: "no such type: " & owner,
                              target: owner, base: nullPtr(), offset: 0'i32,
                              kind: fkNone, bindNs: 0'i64)
  let cls = findClass(rt, owner)
  if cls == nil:
    return
  result.why = owner & " has no static field declared " & declared
  var iter: Il2CppIter = nullPtr()
  while true:
    let f = nextField(rt, cls, iter)
    if f == nil:
      break
    if not fieldIsStatic(rt, f):
      continue
    if typeName(rt, fieldType(rt, f)) != declared:
      continue
    outName = fieldName(rt, f)
    result = bindStaticField(rt, owner, outName)
    if result.ok:
      return
    # Named, found, and refused. That is a different answer from "there is no
    # such field" and sends the reader somewhere else, so it is kept rather
    # than folded into the not-found message on the way out.
    return

proc bindRoot(): bool =
  if gWorldInstance.ok or gWorldStatic.ok:
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
  # GameWorld itself. That is what a hand-rolled singleton looks like.
  #
  # **The walk stays; the read does not.** `bindStaticField` binds a static
  # field *by name*, and the name is exactly what is not known here — the whole
  # reason this fallback exists is that BSG might have called it `_instance` or
  # `Instance` or anything else, and what identifies it is its declared type.
  # So the field list is still walked to find out what it is called, and then
  # the answer is handed to `bindStaticField` rather than turned into a
  # pointer here.
  #
  # That hand-off is not ceremony. What this file used to do instead was build
  # a `FieldBinding` literal with `ok: true` and read it with `readPtr(fb,
  # staticBlock)` — an **instance** reader pointed at a class's static data.
  # It worked, and it is precisely the confusion `StaticFieldBinding` was added
  # to make impossible: the two offset spaces overlap completely, and getting
  # it wrong produces a number rather than a refusal. Two more things come with
  # the real binding and neither was here before:
  #
  # * `il2cpp_runtime_class_init` runs before the block is read. A class whose
  #   static constructor has not run has a static block that exists and is
  #   zero, so the old code's answer for "GameWorld is not initialised yet" was
  #   a null world pointer indistinguishable from "no raid in progress" — this
  #   mod's quietest possible failure.
  # * a runtime that does not export `il2cpp_field_get_flags` is refused with a
  #   reason instead of being asked for an offset it cannot qualify.
  if findClass(gRt, "EFT.GameWorld") == nil:
    gRootTried = true
    gRootWhy = "EFT.GameWorld does not resolve (" & gWorldInstance.why & ")"
    return false
  var sawCandidate = ""
  gWorldStatic = staticFieldOfType(gRt, "EFT.GameWorld", "EFT.GameWorld",
                                   sawCandidate)
  if gWorldStatic.ok:
    info "sway  root: static EFT.GameWorld::" & sawCandidate &
         " (" & gWorldStatic.why & ")"
    return true
  if sawCandidate.len > 0:
    warn "sway  EFT.GameWorld::" & sawCandidate & " looks like the " &
         "singleton but would not bind: " & gWorldStatic.why

  # Both refused. Say so once, with both reasons, and stop trying: this is a
  # build difference, not a timing one — the class resolved, the member did not.
  gRootTried = true
  gRootWhy = "no way to reach the GameWorld singleton: " &
             gWorldInstance.why &
             (if sawCandidate.len > 0:
                ", and EFT.GameWorld::" & sawCandidate &
                " would not bind as a static field (" & gWorldStatic.why & ")"
              else:
                ", and EFT.GameWorld has no static field of its own type") &
             ". Everything downstream of the shooter is unreachable."
  warn "sway  " & gRootWhy
  result = false

proc worldPtr(): Il2CppPtr =
  result = nullPtr()
  if gWorldInstance.ok:
    var a = noArgs()
    result = callPtr(gWorldInstance, nullPtr(), a)
  elif gWorldStatic.ok:
    # One load from an address settled at bind time. No object argument exists
    # on this overload, which is the point: there is nothing here that could be
    # handed a player pointer by accident.
    result = readPtr(gWorldStatic)

var gStaticProbed = false
var gStaticProbeFailed = false

proc probeStaticRoot*() =
  ## Gives `staticFieldOfType` a subject, once, on whatever runtime is present.
  ##
  ## `bindRoot`'s use of it is unreachable in practice: `get_Instance` answers
  ## first on the stand-in and on every build of the game that has been looked
  ## at, so the fallback underneath it would never run and would never be shown
  ## to work. A path that only executes on the day everything else has already
  ## broken is a path nobody wants to be reading for the first time then.
  ##
  ## So the same walk-and-bind is run here against a **different** target: a
  ## static `System.Int32` on `EFT.Player`, which the stand-in has and BSG's
  ## client may or may not. Where it is absent this says so and asserts
  ## nothing; where it is present, three things are checked, and each is a
  ## failure this mod's root binding could have.
  if gStaticProbed:
    return
  gStaticProbed = true
  var name = ""
  let sf = staticFieldOfType(gRt, "EFT.Player", "System.Int32", name)
  if name.len == 0:
    info "sway  static-field probe: this runtime has no static System.Int32 " &
         "on EFT.Player, so the walk-and-bind the GameWorld fallback uses " &
         "has NOT been exercised here. That fallback is unchecked on this " &
         "build; it is not being reported as working."
    return

  if not sf.ok:
    error "sway  static-field probe: EFT.Player::" & name & " is a static " &
          "Int32 by the runtime's own account and bindStaticField refused " &
          "it: " & sf.why
    gStaticProbeFailed = true
    return

  # The value. Zero is the answer a static block gives when its class's static
  # constructor has not run, and running it is exactly what `bindStaticField`
  # adds over the offset arithmetic this file used to do -- so a zero here is
  # either that regression or a field genuinely initialised to zero, and both
  # are worth a line rather than silence.
  let v = readInt(sf)
  if v == 0'i64:
    error "sway  static-field probe: EFT.Player::" & name & " read 0. Either " &
          "the class's static constructor did not run before the block was " &
          "read, or the base address is wrong; both make a null GameWorld " &
          "indistinguishable from no raid in progress."
    gStaticProbeFailed = true

  # And the refusal in the other direction. The binding this replaced was a
  # `FieldBinding` literal pointed at a static block; if `bindField` were to
  # hand back an offset for a static field, that mistake would be one line
  # away again.
  let inst = bindField(gRt, "EFT.Player", name)
  if inst.ok:
    error "sway  static-field probe: bindField accepted the static field " &
          name & ", so an instance read of it would answer whatever an " &
          "object happens to hold at that offset"
    gStaticProbeFailed = true

  if not gStaticProbeFailed:
    success "sway  static-field probe: EFT.Player::" & name &
            " bound static, read " & $v & " with no object, and the " &
            "instance binder refused it — the walk the GameWorld fallback " &
            "uses works on this runtime"

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
var bVelocity: Binding         ## Player::get_Velocity, shaped

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
var sCameraTransform: Slot
var bEulerAngles: Binding      ## UnityEngine.Transform::get_eulerAngles, shaped
var gEulerTried = false

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

  # `Velocity` is a `Vector3` property, and a value-type *return* is not a
  # register class either. Same shape as the actuator, one slot further along:
  #
  #     Vector3 get_Velocity()   is really
  #     void*   get_Velocity(void* sret, void* this, MethodInfo*)
  #
  # — the caller allocates twelve bytes, hands over its address as an invisible
  # first argument, and the callee writes through it. Two slots, no floats, and
  # the return is the same pointer we passed. This is the number the BepInEx
  # original read (`player.Velocity`), reached by name rather than by guessing
  # at a backing field.
  let cls = objectClass(gRt, p)
  bVelocity = bindRaw(gRt, cls, t, "get_Velocity", 0, 2, 0'u32, fkPtr)
  if bVelocity.ok:
    debug "sway  bound " & bVelocity.why & " (Vector3 by sret)"

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
  sCameraTransform = bindSlot(gRt, t, "CameraTransform")
  report("HandsContainer::HandsRotation", sHandsRotation)
  report("HandsContainer::CameraRotation", sCameraRotation)
  report("HandsContainer::CameraTransform", sCameraTransform)

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

  # The two vector inputs, as **fallbacks**.
  #
  # Both are read from named properties now — `Transform::get_eulerAngles` and
  # `Player::get_Velocity`, shaped calls with an sret buffer, which is what the
  # BepInEx original read. These backing fields are what this mod used when a
  # `Vector3` return was unreachable at all, and they are kept for a build where
  # the property is gone: a scan for a vector field with the right name and
  # shape. Only reached if the shaped call did not bind, and the name it settled
  # on is logged either way — a wrong match would drive the inertia oscillator
  # off the wrong number, and that must be visible in the log rather than only
  # in the feel.
  var found = ""
  vRotation = findVecFieldNamed(gRt, t, "rotation", 2, found)
  if vRotation.ok:
    debug "sway  view-angle fallback: " & t & "::" & found & " (Vector2)"
  vVelocity = findVecFieldNamed(gRt, t, "velocity", 3, found)
  if vVelocity.ok:
    debug "sway  velocity fallback: " & t & "::" & found & " (Vector3)"

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
  if not sWeapon.bound():
    # Bound against the object, not a name. `Player.FirearmController` is a
    # nested class, and a nested class's qualified name is not a name
    # `findClass` accepts — so the named path would find nothing here and the
    # whole weapon group would read its defaults forever.
    sWeapon = bindSlotOn(gRt, controller, "Weapon", fkPtr)
    if not sWeapon.bound():
      debug "sway  no weapon on this controller: " & sWeapon.why
  if weapon == nil:
    # The controller bound, but there is nothing in the shooter's hands this
    # frame. Not an error and not final: try again next frame.
    return
  gWeaponSlots = true
  let wt = typeNameOf(gRt, weapon)
  # Same reasoning as the controller, plus one more: these four are declared on
  # base classes of the concrete weapon type, and `bindSlotOn` walks the base
  # chain from the object rather than trusting one name to reach all of them.
  sErgonomics = bindSlotOn(gRt, weapon, "ErgonomicsTotal", fkF32)
  sTotalWeight = bindSlotOn(gRt, weapon, "TotalWeight", fkF32)
  sWeight = bindSlotOn(gRt, weapon, "Weight", fkF32)
  sRecoilTotal = bindSlotOn(gRt, weapon, "RecoilTotal", fkF32)
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

var bAddAccel: Binding         ## Spring::AddAcceleration, shaped
var gSpringTried = false
var gSpringWhy = ""
var gActuated = false

proc bindSpringMethod(spring: Il2CppPtr) =
  if bAddAccel.ok or gSpringTried or spring == nil:
    return
  gSpringTried = true
  let cls = objectClass(gRt, spring)
  if cls == nil:
    gSpringWhy = "the spring object has no class"
    warn "sway  " & gSpringWhy
    return
  let name = typeNameOf(gRt, spring)

  # The shape, stated: `void AddAcceleration(Vector3)` on an instance is
  #
  #     RCX = this,  RDX = &value,  R8 = MethodInfo*
  #
  # — two slots this call fills, neither of them a float, and nothing returned.
  # A `Vector3` is twelve bytes, which is larger than eight and not a power of
  # two, so Win64 passes it by hidden pointer to a caller-allocated temporary
  # rather than in a register. That is the whole assertion, and it is the reason
  # `bindMethod` refuses this method: the shape differs from the signature.
  #
  # `declaredArgc` is 1 because that is how IL2CPP looks the method up — by name
  # and by the arity C# declared, not by the arity the machine sees.
  bAddAccel = bindRaw(gRt, cls, name, "AddAcceleration", 1, 2, 0'u32, fkVoid)
  if not bAddAccel.ok:
    gSpringWhy = bAddAccel.why &
      ". Nothing this mod computes can reach the weapon."
    warn "sway  " & gSpringWhy
    return
  info "sway  actuator: " & bAddAccel.why

proc addAcceleration(spring: Il2CppPtr; v: Vec3) =
  ## The one call that moves the weapon. Roughly ten nanoseconds.
  ##
  ## No exception out-parameter, and that is a real difference from the
  ## reflective call this replaced: a shaped call is a direct call to the
  ## compiled function, so a managed throw would not come back as a written
  ## pointer. `AddAcceleration` accumulates a vector and clamps it — it has
  ## nothing to throw — but that is a property of this method rather than of the
  ## mechanism, and it is why the mechanism is not used for anything else here.
  if not bAddAccel.ok or spring == nil:
    return
  var value = Vector3F(x: float32(v.x), y: float32(v.y), z: float32(v.z))
  var a = shaped()
  a.addSlotPtr(spring)                          # this
  a.addSlotPtr(cast[Il2CppPtr](addr value))     # the Vector3, by hidden pointer
  callShapedVoid(bAddAccel, a)

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

proc readVec3Ret(b: Binding; self: Il2CppPtr; out1: var Vector3F): bool =
  ## Calls a method that returns a `Vector3`, into a buffer we own.
  ##
  ## The shape is the one `bindRaw` was bound with: slot 0 is the caller's
  ## twelve bytes, slot 1 is `this`. The callee writes through slot 0 and
  ## returns that same address, so the returned pointer is checked against the
  ## one handed over — if a build ever returned something else, that is the
  ## assertion failing, and it is better to notice than to read the buffer
  ## anyway.
  out1 = Vector3F(x: 0.0'f32, y: 0.0'f32, z: 0.0'f32)
  if not b.ok or self == nil:
    return false
  var a = shaped()
  a.addSlotPtr(cast[Il2CppPtr](addr out1))   # sret: our twelve bytes
  a.addSlotPtr(self)                         # this
  result = callShapedPtr(b, a) == cast[Il2CppPtr](addr out1)

proc bindEuler(tf: Il2CppPtr) =
  if bEulerAngles.ok or gEulerTried or tf == nil:
    return
  gEulerTried = true
  let cls = objectClass(gRt, tf)
  if cls == nil:
    return
  bEulerAngles = bindRaw(gRt, cls, typeNameOf(gRt, tf), "get_eulerAngles",
                         0, 2, 0'u32, fkPtr)
  if bEulerAngles.ok:
    info "sway  view angles from " & bEulerAngles.why & " (Vector3 by sret)"
  else:
    warn "sway  " & bEulerAngles.why

proc viewAngles*(yaw, pitch: var float): bool =
  ## This frame's view angles, in degrees. The inertia oscillator is driven
  ## from where the view actually ended up rather than from raw mouse input, so
  ## sensitivity changes, controllers and any other mod that moves the view all
  ## feed it the same way.
  ##
  ## Read off the camera transform's `eulerAngles`, which is exactly what the
  ## BepInEx original read. That was unreachable when this file was written —
  ## a `Vector3` return is not a register class — and `bindRaw` is what makes it
  ## a two-slot call with an sret buffer. The `MovementContext` backing field is
  ## kept as the fallback for a build where the transform cannot be reached.
  yaw = 0.0
  pitch = 0.0
  let tf = sCameraTransform.getP(pContainer)
  if tf != nil:
    bindEuler(tf)
    var e = Vector3F(x: 0.0'f32, y: 0.0'f32, z: 0.0'f32)
    if readVec3Ret(bEulerAngles, tf, e):
      # Unity's euler order: x is pitch, y is yaw. The C# read the same two.
      yaw = float(e.y)
      pitch = float(e.x)
      return true

  if not vRotation.ok:
    return false
  let mc = sMovement.getP(pPlayer)
  if mc == nil:
    return false
  yaw = vRotation.getX(mc)
  pitch = vRotation.getY(mc)
  result = true

proc bodyVelocity*(): Vec3 =
  ## The body's velocity, for the half of inertia that comes from the shooter
  ## accelerating rather than turning. `Player::get_Velocity` first — the named
  ## property the original read — and the scanned field only if that is gone.
  result = Zero3
  var v = Vector3F(x: 0.0'f32, y: 0.0'f32, z: 0.0'f32)
  if readVec3Ret(bVelocity, pPlayer, v):
    return vec3(float(v.x), float(v.y), float(v.z))
  if not vVelocity.ok:
    return
  let mc = sMovement.getP(pPlayer)
  if mc == nil:
    return
  result = vec3(vVelocity.getX(mc), vVelocity.getY(mc), vVelocity.getZ(mc))

# ---------------------------------------------------------------------------
# The frame
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# The calibration
# ---------------------------------------------------------------------------
#
# `driveGain` used to be an absolute constant with a paragraph of apology
# attached. It is a trim now, and the calibration it trims is derived from the
# spring's own `ReturnSpeed` — a number the game holds and this file already
# captures, because section 12 needs the original to put back.
#
# So the conversion from the model's degrees to the game's acceleration is read
# off the game wherever the game can be read, and falls back to this mod's
# shipped guess at BSG's value where it cannot. Which of the two happened is in
# the log, once, because a calibration derived from a default is a different
# claim from one derived from a measurement.

var gCalSaid = false

proc springCalOf(returnSpeed, damping, accelMax: float; measured: bool;
                 t: Tuning): SpringCal =
  var r = returnSpeed
  var d = damping
  var a = accelMax
  var m = measured
  if r <= 0.01:
    # Not bound, or bound to something that is not a spring constant. The
    # shipped value is a guess and is marked as one.
    r = ShippedReturnSpeed
    d = ShippedDamping
    a = ShippedAccelMax
    m = false
  result = calibration(r, d, a, t.springAccelPerFrame, m)

proc handsCal*(t: Tuning): SpringCal =
  ## The hands rotation spring, as the calibration sees it.
  ##
  ## When `springOverride` is on, this mod is *writing* those constants every
  ## frame, so the config's values are the live ones and the captured originals
  ## are not. Getting that backwards would mis-calibrate by exactly the ratio
  ## the player asked to change the spring by.
  if t.springOverride:
    return springCalOf(t.handsRotReturnSpeed, t.handsRotDamping,
                       t.handsRotAccelerationMax, gCaptured, t)
  if gCaptured:
    return springCalOf(gKnobOrig[KnHandsRotReturn], gKnobOrig[KnHandsRotDamping],
                       gKnobOrig[KnHandsRotAccelMax], true, t)
  result = springCalOf(0.0, 0.0, 0.0, false, t)

proc cameraCal*(t: Tuning): SpringCal =
  ## The view spring. Its own return speed, which is not the weapon's — the
  ## config ships 8 against the hands' 7 — and no acceleration clamp modelled,
  ## because this mod does not know what the camera spring's is.
  if t.springOverride:
    return springCalOf(t.cameraRotReturnSpeed, t.cameraRotDamping, 0.0,
                       gCaptured, t)
  if gCaptured:
    return springCalOf(gKnobOrig[KnCamRotReturn], gKnobOrig[KnCamRotDamping],
                       0.0, true, t)
  result = springCalOf(0.0, 0.0, 0.0, false, t)

var gHandsCal = defaultCal()
var gCameraCal = defaultCal()

proc refreshCalibration*(t: Tuning) =
  ## Recompute both calibrations, once a frame, into globals.
  ##
  ## Cached rather than computed at each of the two call sites, because
  ## `handsCal` takes the whole `Tuning` and that is a kilobyte of record: the
  ## work itself is four loads and a clamp, and the copy would be most of the
  ## cost. Nothing here allocates.
  gHandsCal = handsCal(t)
  gCameraCal = cameraCal(t)

proc handsCalNow*(): SpringCal = gHandsCal
proc cameraCalNow*(): SpringCal = gCameraCal

proc reportCalibration*(t: Tuning) =
  ## Said once, the first frame the springs can be read.
  if gCalSaid or not gCaptured:
    return
  gCalSaid = true
  let c = handsCal(t)
  if c.measured:
    success "sway  calibration read off the live spring: ReturnSpeed " &
            fmtNum(c.returnSpeed) & ", Damping " & fmtNum(c.damping) &
            ", AccelerationMax " & fmtNum(c.accelMax) &
            " — one degree of model output is " & fmtNum(t.driveGain) &
            " degrees of weapon rotation"
  else:
    warn "sway  the spring's own constants could not be read; calibrating " &
         "against this mod's shipped guess of ReturnSpeed " &
         fmtNum(c.returnSpeed) & ". The drive is derived, but from a default"

proc onWeaponChanged*() =
  ## Rebind the weapon-dependent half and re-capture BSG's defaults.
  ##
  ## The *type-level* bindings — offsets and function pointers — belong to the
  ## class and survive; only the hands controller's class can genuinely change,
  ## which is why that is the one group cleared here.
  gWeaponSlots = false
  sWeapon = noSlot()          # forget the old controller's class
  gCaptured = false

proc reachFrame*(): bool =
  ## The cheap half of the frame: reach the game and find this frame's objects.
  ##
  ## Split from the rest because of what the caller does in between. A detour on
  ## `LerpCamera` fires for *an* animator, and the local player is not the only
  ## thing in a raid that has one — so the handler compares the `this` it was
  ## given against the animator this walk found, and returns for anything else.
  ## That comparison needs the walk and nothing after it: binding knobs and
  ## writing thirty override values for a bot's animator would be wrong as well
  ## as expensive.
  ##
  ## False means "not in a raid, or the chain is broken".
  if not gRuntimeOk:
    return false
  if not bindRoot():
    return false
  result = walk()

proc localAnimator*(): uint64 =
  ## The address of *this* player's `ProceduralWeaponAnimation`, as found by the
  ## walk that just ran. Compared against a hook's `this` and then forgotten:
  ## the collector moves objects, so it is only meaningful inside the frame that
  ## produced it.
  result = cast[uint64](pPwa)

proc finishFrame*(t: Tuning) =
  ## The rest: bind whatever is newly reachable, and put BSG's own numbers where
  ## the config says they go. Only ever called for the local player's animator.
  if t.vanillaOverride:
    walkTremorRandoms()
  bindSpringMethod(pHandsRot)
  for i in 0 ..< OwCount:
    bindKnobsFor(i)
  captureOriginals()
  applyOverrides(t)
  refreshCalibration(t)

proc beginFrame*(t: Tuning): bool =
  ## Both halves, for a caller that cannot tell one animator from another.
  if not reachFrame():
    return false
  finishFrame(t)
  result = true

proc actuate*(hands, camera: Vec3; t: Tuning) =
  ## Model output in degrees -> the game's rotation springs.
  ##
  ## The impulse itself is computed by `model/director.springImpulse`, which is
  ## in `model/` because it is arithmetic; this is only the push.
  ##
  ## ------------------------------------------------------------------------
  ## What the calibration now rests on
  ## ------------------------------------------------------------------------
  ## `springImpulse` multiplies by the spring's own `ReturnSpeed` — read off
  ## `HandsRotation` a few lines above, or this mod's shipped guess at it when
  ## the field cannot be reached — and then by `driveGain`, which is a
  ## dimensionless trim whose default of 1 means "one degree of model output is
  ## one degree of weapon rotation".
  ##
  ## That is a derivation rather than the constant it replaced, and it is still
  ## not a measurement: it assumes BSG's `Spring` integrates
  ## `velocity += acceleration * dt` rather than `velocity += acceleration`.
  ## The two differ by a factor of sixty at 60 fps, `springAccelPerFrame` is the
  ## one boolean that switches between them, and `model/spring.nim` sets out the
  ## dimensional argument for the default. The failure mode is not subtle: wrong
  ## one way this mod does nothing visible, wrong the other it pins the weapon
  ## against the spring's own acceleration clamp every frame.
  if not bAddAccel.ok:
    return
  if pHandsRot != nil and sqrMagnitude(hands) > 0.0:
    addAcceleration(pHandsRot, hands)
  if pCamRot != nil and sqrMagnitude(camera) > 0.0:
    addAcceleration(pCamRot, camera)
  if not gActuated:
    gActuated = true
    let c = handsCal(t)
    success "sway  the model is now driving the weapon springs"
    info "sway  drive: degrees x ReturnSpeed " & fmtNum(c.returnSpeed) &
         (if c.measured: " (read off the spring)" else: " (shipped guess)") &
         " x driveGain " & fmtNum(t.driveGain) &
         (if c.perFrameAccel: ", per-frame acceleration form"
          else: ", per-second acceleration form") &
         ". Nothing here has been seen against BSG's client."
    # All three of the spring's constants, once, and what they imply. The
    # simulator prints the same quantities off the shipped guesses; this is the
    # line that says what they actually are, and it is the only place the two
    # can be compared. `model/characterise.nim` computes the rest from these.
    let step = 1.0 / 60.0
    var soft = c
    soft.dampingPerSecond = true
    info "sway  spring: ReturnSpeed " & fmtNum(c.returnSpeed) & ", Damping " &
         fmtNum(c.damping) & ", AccelerationMax " & fmtNum(c.accelMax) &
         (if c.measured: " (all three read off the live spring)"
          else: " (all three are this mod's shipped guesses)")
    info "sway  spring: resonates at " & fmtNum(naturalFreqHz(c)) &
         " Hz, holds at most " & fmtNum(saturation(c, step)) &
         " deg, and settles in " & fmtNum(stepResponse(c, step, 90.0).settle) &
         " s if Damping is a per-frame fraction or " &
         fmtNum(stepResponse(soft, step, 90.0).settle) &
         " s if it is a per-second rate. Which of the two BSG wrote is not " &
         "measured; one raid settles it."

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
