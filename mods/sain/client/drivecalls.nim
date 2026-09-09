## The driving calls, on byte-verified static RVAs.
##
## WHAT CHANGED AND WHY IT MATTERS
## ------------------------------
## Every call this mod used to make went through a NAME. `live.lazy("get_Mover")`
## asked the runtime to resolve a string, and fact #145 is that a by-name route
## on this build is fatal at the moment it is USED, not when it is resolved.
##
## The mechanism is now measured and the mod's own refusal strings were WRONG
## about it. It is not that "reflection is dead" or that handles point into
## unmapped memory -- that was the symptom. This is stock IL2CPP with a
## TOKEN-GATED export ABI: 38 of 241 exports take an undocumented trailing
## 32-byte token, `memcmp` it, and on a mismatch return a UNIFORM RANDOM
## NON-ZERO uint64 out of a per-thread MT19937-64. `il2cpp_object_get_class` is
## `mov rax,[rcx]; ret` and validates nothing. So a nil check PASSES and the
## first dereference kills the client, with a log byte-identical to a healthy
## run. See `docs/IL2CPP_EXPORTS.md`.
##
## Nothing in this file resolves a name at run time. Every address comes from
## `abi/aowlspt_symtab.nim`, generated OFFLINE by `tools/il2cpp_symtab.py` from
## `abi/aowlspt_symbols.txt`, which rejects a shared RVA, this build's universal
## `ret 0` stub, an RVA outside the `il2cpp` PE section, and an ambiguous
## overload -- as a BUILD failure, not a run-time one. A direct RVA call does
## not touch the export ABI at all, so the gates cannot reach it.
##
## THE COMPONENT HOPS ARE FIELDS, NOT GETTERS
## ------------------------------------------
## `EFT.BotOwner::get_Mover` @0x80F920 has FIVE owners and `get_Steering`
## @0x80D8E0 has THIRTEEN. Calling a shared RVA is correct code for the
## receiver -- but there is no need to call anything: the backing fields are
## measured, single, static offsets on a NON-generic type, which is exactly the
## toolkit that still works.
##
##   python tools\il2cpp_resolve.py <gameasm> <metadec> fields EFT.BotOwner
##     0x148  inst  <Steering>k__BackingField    BotSteering
##     0x280  inst  <ShootData>k__BackingField   ShootData
##     0x2c8  inst  <Medecine>k__BackingField    BotMedecine
##     0x3d0  inst  <Mover>k__BackingField       BotMover
##
## `<Mover>@0x3d0` has a second, independent confirmation that costs nothing:
## the first instruction of `EFT.BotOwner::StopMove` @0x81C970, recorded in the
## symbol table as its declared prologue, is
##
##     48 8B 81 D0 03 00 00      mov rax, [rcx+0x3D0]
##     48 85 C0                  test rax, rax
##
## i.e. the method itself loads the Mover from 0x3D0 and null-checks it. Two
## sources, one number. That is the standard this file holds every offset to.
##
## THE ARGUMENT CONVENTION IS MEASURED
## -----------------------------------
## A by-value `Vector3` is passed as a POINTER in the integer register for its
## slot. Read off `Vector3::Dot@0x5297BF0`, which does
## `movss xmm0,[rcx+4] / mulss xmm0,[rdx+4]` -- it DEREFERENCES RCX and RDX.
## `callrva.addVec3` stages exactly that and this file never restates it.
##
## CAVEAT, STATED BECAUSE IT IS NOT SETTLED: that evidence is OFFLINE. No live
## call has yet proven the convention in the running client. Every entry point
## here therefore refuses on a failed `verify` and reports `coFaulted`
## separately from `coRefused`; none of them substitutes a default for an
## answer it did not get. "The call returned without faulting" is not evidence
## the convention is right -- a wrong convention returns plausible garbage --
## so the live test for each capability is written out in `README.md` with the
## falsifier a wrong answer would trip.
##
## WHAT IS DELIBERATELY NOT HERE
## -----------------------------
## The DESTINATION call. `BotMover::GoToPoint(Vector3, bool, float, bool, bool,
## bool, bool)` @0x1A2EE00 needs 8 register slots including `this`, and
## `EFT.BotOwner::GoToPoint(...)` @0x81CB40 needs 9. `AOWL_FAST_MAX_SLOTS` is 5:
## Win64 puts everything past the fourth argument on the STACK, which the shape
## dispatcher does not express, and `callrva` refuses rather than spills. Both
## symbols are absent from `abi/aowlspt_symbols.txt` on purpose, with the reason
## written there, so nobody adds a symbol that compiles into a call that can
## never be staged.
##
## That is not a dead end: `abi/aowlspt_botnav.h` already carries a
## hand-written, byte-verified 8-argument thunk for `EFT.BotOwner::GoToPoint`
## @0x81CB40, reachable from a mod as `aowlspt/botnav.goTo` / `sendBotTo`.
## Routing this mod's movement through it needs the bot IDENTITY the host's
## census uses rather than the `Player*` this mod walks to, and that mapping is
## the next piece of work, named in `README.md` rather than half-built here.

import aowlspt
import aowlspt/il2cpp
import aowlspt/fast
import aowlspt/callrva
import aowlspt_symtab
import ".." / core / vec

# ---------------------------------------------------------------------------
# Measured field offsets on EFT.BotOwner
# ---------------------------------------------------------------------------

const
  BoSteeringOffset* = 0x148'i32
  BoShootDataOffset* = 0x280'i32
  BoMedecineOffset* = 0x2c8'i32
  BoMoverOffset* = 0x3d0'i32

  # --- THE TEARDOWN GATE. Measured 2026-08-31 with `tools/fldoff.py` against
  # the decrypted metadata, not inferred:
  #
  #   UnityEngine.Object.m_CachedPtr            IntPtr     @0x10
  #   EFT.BotOwner._botState                    EBotState  @0x30
  #   EFT.BotOwner.<IsDead>k__BackingField      bool       @0x431
  #   EFT.EBotState: NonActive=0 PreActive=1 Active=2 ActiveFail=3 Disposed=4
  #
  # Why these four exist at all: `bridge.runDrives` claimed "a dead bot's handle
  # answers null", and that is a CHECK THAT CANNOT FAIL (CLAUDE.md 9b). We hold
  # a STRONG il2cpp GC handle on the Player, so the managed object cannot be
  # collected and `gc_handle_get_target` answers non-null for the whole raid --
  # including long after `BotOwner.Dispose(withNulls:true)` has run. Readability
  # is not liveness; a strong handle guarantees readability forever.
  #
  # `m_CachedPtr == 0` IS Unity's own destroyed-object marker (the "fake null"
  # every `== null` operator in C# tests), so it is the one signal that is not
  # our invention. `_botState` is the game's own teardown state machine, and the
  # aiErrors line the user hit reads `state:Disposed` verbatim.
  UoCachedPtrOffset* = 0x10'i32
  BoBotStateOffset* = 0x30'i32
  BoIsDeadOffset* = 0x431'i32
  EBotStateActive* = 2'i32

  NavMeshHitBytes* = 36'i32
    ## MEASURED, not inferred. `Il2CppMetadataRegistration.typeDefinitionsSizes`
    ## entry for `UnityEngine.AI.NavMeshHit` reads
    ## `instance_size=52, native_size=36`. The native size IS the unboxed
    ## payload; 52 - 16 header = 36 agrees, and `UnityEngine.Vector3` in the
    ## same table reads `instance_size=28, native_size=12`, which is the
    ## control. An earlier note put 36 here by SUBTRACTING a header from boxed
    ## field offsets -- same number, but an inference; this is the measurement
    ## it was standing in for.
  NavHitPositionOff* = 0x00'i32
  NavHitNormalOff* = 0x0c'i32
  NavHitDistanceOff* = 0x18'i32
  NavHitMaskOff* = 0x1c'i32
  NavHitHitOff* = 0x20'i32

# ---------------------------------------------------------------------------
# Targets
# ---------------------------------------------------------------------------

proc hexOf(bs: openArray[uint8]): string =
  ## The generated table carries bytes; `rvaTarget` declares a hex string. One
  ## conversion here beats sixteen hand-typed bytes per target, and a
  ## hand-typed prologue is precisely the thing the generator exists to stop
  ## anyone writing.
  const digits = "0123456789abcdef"
  result = ""
  var i = 0
  while i < bs.len:
    if i > 0: result.add ' '
    result.add digits[int(bs[i] shr 4'u8)]
    result.add digits[int(bs[i] and 0x0F'u8)]
    inc i

# THE TARGETS ARE DECLARED BARE AND ASSIGNED INSIDE A PROC, and that is not a
# style choice -- it is the trap documented at `aowl/src/aowlspt/fast.nim:44`.
#
# In a nimony `--app:lib` build a global INITIALISED BY A CALL is silently left
# ZEROED. `var gDot = rvaTarget(...)` at module scope does not fail; it produces
# an all-zero object, so the target's RVA reads 0 and the first call refuses
# with `@0x0`. It fails safe, which is the reason nobody notices: the mod loads,
# the log says "refused", and the refusal names the wrong cause. This file was
# written that way and would have refused every driving call for a reason that
# had nothing to do with IL2CPP. Measured today by the call-proof mod's first
# live run, which hit exactly this.
#
# So: bare declarations here, one assignment site in `installTargets` below,
# called from `verifyAll`.

var gMoverSprint: RvaTarget
var gMoverStop: RvaTarget
var gSteeringLookTo: RvaTarget
var gShoot: RvaTarget
var gStopMove: RvaTarget
var gNavSample: RvaTarget
var gRaycast: RvaTarget

proc installTargets() =
  gMoverSprint = rvaTarget(
    AOWL_SYM_SAIN_MOVER_SPRINT_NAME & "(bool val, bool withDebugCallback)",
    AOWL_SYM_SAIN_MOVER_SPRINT,
    hexOf(AOWL_SYM_SAIN_MOVER_SPRINT_PROLOGUE),
    owners = int32(AOWL_SYM_SAIN_MOVER_SPRINT_OWNERS))

  gMoverStop = rvaTarget(
    AOWL_SYM_SAIN_MOVER_STOP_NAME & "()",
    AOWL_SYM_SAIN_MOVER_STOP,
    hexOf(AOWL_SYM_SAIN_MOVER_STOP_PROLOGUE),
    owners = int32(AOWL_SYM_SAIN_MOVER_STOP_OWNERS))

  gSteeringLookTo = rvaTarget(
    AOWL_SYM_SAIN_STEERING_LOOKTO_NAME & "(Vector3 point)",
    AOWL_SYM_SAIN_STEERING_LOOKTO,
    hexOf(AOWL_SYM_SAIN_STEERING_LOOKTO_PROLOGUE),
    owners = int32(AOWL_SYM_SAIN_STEERING_LOOKTO_OWNERS))

  gShoot = rvaTarget(
    AOWL_SYM_SAIN_SHOOTDATA_SHOOT_NAME & "() -> bool",
    AOWL_SYM_SAIN_SHOOTDATA_SHOOT,
    hexOf(AOWL_SYM_SAIN_SHOOTDATA_SHOOT_PROLOGUE),
    owners = int32(AOWL_SYM_SAIN_SHOOTDATA_SHOOT_OWNERS))

  gStopMove = rvaTarget(
    AOWL_SYM_SAIN_BOTOWNER_STOPMOVE_NAME & "()",
    AOWL_SYM_SAIN_BOTOWNER_STOPMOVE,
    hexOf(AOWL_SYM_SAIN_BOTOWNER_STOPMOVE_PROLOGUE),
    owners = int32(AOWL_SYM_SAIN_BOTOWNER_STOPMOVE_OWNERS))

  gNavSample = rvaTarget(
    AOWL_SYM_SAIN_NAVMESH_SAMPLE_NAME &
      "(Vector3 src, out NavMeshHit hit, float maxDistance, int areaMask) -> bool",
    AOWL_SYM_SAIN_NAVMESH_SAMPLE,
    hexOf(AOWL_SYM_SAIN_NAVMESH_SAMPLE_PROLOGUE),
    owners = int32(AOWL_SYM_SAIN_NAVMESH_SAMPLE_OWNERS))

  # `UnityEngine.Physics::Raycast(Vector3, Vector3, float)` is NOT in the
  # generated table and cannot be, which is a real gap in the tool rather than
  # a thing to route around silently. `abi/aowlspt_symbols.txt` names an
  # overload as `Type::Method/arity`, and this build has THREE arity-3
  # `Raycast` overloads:
  #   (Vector3,Vector3,float)      0x5328830   <- the one wanted
  #   (Vector3,Vector3,RaycastHit) 0x5328C30
  #   (Ray,float,int)              0x5328DD0
  # so `UnityEngine.Physics::Raycast/3` is REJECTED as ambiguous. That
  # rejection is correct -- picking one silently would be the bug -- but the
  # manifest has no way to disambiguate BY PARAMETER TYPE, so the only route
  # left is the one `callrva` documents for exactly this case: declare the RVA
  # and paste the prologue from
  #   python tools\il2cpp_resolve.py <gameasm> <metadec> bytes 0x5328830 16
  # which printed, on 2026-08-26, precisely the sixteen bytes below. The
  # rejected symbol is LEFT in the manifest, unreferenced, so the gap is
  # documented where the next person will look.
  gRaycast = rvaTarget(
    "UnityEngine.Physics::Raycast(Vector3 origin, Vector3 direction, float maxDistance) -> bool",
    0x5328830'u32,
    "48 89 5C 24 08 57 48 83 EC 70 80 3D 51 D9 DA 01",
    owners = 1'i32)

# ---------------------------------------------------------------------------
# Verification, once
# ---------------------------------------------------------------------------

type
  DriveState* = object
    tried*: bool
    sprintOk*, stopOk*, lookOk*, shootOk*, stopMoveOk*: bool
    navOk*, rayOk*: bool
    why*: string
    faults*: int
    disabled*: bool

var gS: DriveState

const MaxDriveFaults* = 8
  ## Rule 6. Eight faults across every driving channel and the whole file turns
  ## itself off for the rest of the process. It is a whole-file budget on
  ## purpose: a wrong calling convention would not fault on one channel.

proc noteOutcome(label: string; o: CallOutcome; ok: var bool) =
  if o.kind == coOk:
    ok = true
    info "sain drive: " & label & " VERIFIED -- " & o.why
  else:
    ok = false
    warn "sain drive: " & label & " REFUSED -- " & o.why
    gS.why = gS.why & label & ": " & o.why & "; "

# WHICH THREAD. Two different answers, and conflating them is how this mod died
# before.
#
#   VERIFICATION (`verifyAll`) reads code pages and compares bytes. It calls
#   nothing, patches nothing and touches no il2cpp export, so it is safe from
#   any thread and is run from the ordinary arming path.
#
#   EVERY CALL below it must run on UNITY's thread, reached through the host's
#   main-thread drain. `every()` is a deadline timer on a WORKER thread, so
#   merely gating on a flag is not enough -- the work has to be HANDED to
#   `onMainThread`, and `call("aowlspt.host::main_thread")` has to report
#   `bound`, which means the drain has actually FIRED rather than merely been
#   installed. `client/mainthread.nim` asks that question and `driver.nim` is
#   the only caller of both `runSample` and `applyTo`; both go through
#   `onMainThread`.
#
#   And never `whenReady("EFT.GameWorld")` as the gate (fact #141): it tests
#   type RESOLVABILITY, not whether a world exists, so it is a check that
#   cannot fail. The world is borrowed from the host's `aowl_host_gameworld` /
#   `_armed` exports instead. Fact #143 is the companion warning: this mod once
#   died at the instant such a gate OPENED, so surviving the gate is not the
#   same as surviving the first call -- which is why every entry point here
#   reports `coFaulted` separately and the file self-disables at a budget.

proc verifyAll*() =
  ## Byte-verify every target against the startup prologue snapshot. Reads code
  ## pages only; patches nothing; safe at bind time. Idempotent.
  if gS.tried: return
  gS.tried = true
  gS.why = ""
  installTargets()
  noteOutcome("BotMover::Sprint", verify(gMoverSprint), gS.sprintOk)
  noteOutcome("BotMover::Stop", verify(gMoverStop), gS.stopOk)
  noteOutcome("BotSteering::LookToPoint", verify(gSteeringLookTo), gS.lookOk)
  noteOutcome("ShootData::Shoot", verify(gShoot), gS.shootOk)
  noteOutcome("EFT.BotOwner::StopMove", verify(gStopMove), gS.stopMoveOk)
  noteOutcome("UnityEngine.AI.NavMesh::SamplePosition", verify(gNavSample), gS.navOk)
  noteOutcome("UnityEngine.Physics::Raycast", verify(gRaycast), gS.rayOk)
  if gS.why.len == 0:
    gS.why = "every declared prologue matched the startup snapshot"

proc driveWhy*(): string =
  if not gS.tried: "not verified yet"
  elif gS.disabled:
    "DISABLED after " & $gS.faults & " faults (budget " & $MaxDriveFaults & ")"
  else: gS.why

proc driveDisabled*(): bool = gS.disabled
proc driveFaults*(): int = gS.faults

proc canSprint*(): bool = gS.sprintOk and not gS.disabled
proc canStop*(): bool = gS.stopOk and not gS.disabled
proc canLook*(): bool = gS.lookOk and not gS.disabled
proc canShoot*(): bool = gS.shootOk and not gS.disabled
proc canStopMove*(): bool = gS.stopMoveOk and not gS.disabled
proc canSample*(): bool = gS.navOk and not gS.disabled
proc canRaycast*(): bool = gS.rayOk and not gS.disabled

proc account(label: string; o: CallOutcome): bool =
  ## One place decides what an outcome MEANS, so no caller can flatten
  ## refused/faulted/ok into a bool by accident.
  if o.kind == coOk:
    return true
  if o.kind == coFaulted:
    inc gS.faults
    warn "sain drive: " & label & " FAULTED -- " & o.why
    if gS.faults >= MaxDriveFaults and not gS.disabled:
      gS.disabled = true
      error "sain drive: DISABLED -- " & $gS.faults & " faults reached the " &
            "budget of " & $MaxDriveFaults & ". Every driving channel is off " &
            "for the rest of this process. This is rule 6, not a transient."
  else:
    warn "sain drive: " & label & " refused -- " & o.why
  result = false

# ---------------------------------------------------------------------------
# Component hops -- measured offsets, guarded reads, never a getter call
# ---------------------------------------------------------------------------

proc componentAt(owner: Il2CppPtr; off: int32; what: string): Il2CppPtr =
  result = cast[Il2CppPtr](0)
  if owner == nil: return
  var f = FieldBinding(ok: true, why: what & " (measured static offset)",
                       target: "EFT.BotOwner." & what, offset: off,
                       kind: fkPtr, bindNs: 0'i64)
  result = readPtr(f, owner)

# ---------------------------------------------------------------------------
# The teardown gate -- re-validated at CALL time, never at enumeration time
# ---------------------------------------------------------------------------

var gRefusedDestroyed = 0
var gRefusedDisposed = 0
var gRefusedDead = 0
var gDriveAdmitted = 0

proc drivesRefusedDestroyed*(): int = gRefusedDestroyed
proc drivesRefusedDisposed*(): int = gRefusedDisposed
proc drivesRefusedDead*(): int = gRefusedDead
proc drivesAdmitted*(): int = gDriveAdmitted

proc resetDriveGateCounters*() =
  gRefusedDestroyed = 0
  gRefusedDisposed = 0
  gRefusedDead = 0
  gDriveAdmitted = 0

proc unityAlive*(obj: Il2CppPtr): bool =
  ## Unity's own destroyed test, done the way C#'s `== null` operator does it:
  ## a managed `UnityEngine.Object` whose `m_CachedPtr` is zero has had its
  ## native half destroyed. It stays perfectly readable -- that is the entire
  ## trap -- and the next internal call through it throws
  ## `NullReferenceException` inside the engine, which is the exception the
  ## client's `errors_000.log` reported and which surfaced at
  ## `BotBoss.Dispose`.
  result = false
  if obj == nil: return
  var f = FieldBinding(ok: true, why: "UnityEngine.Object.m_CachedPtr@0x10",
                       target: "UnityEngine.Object.m_CachedPtr",
                       offset: UoCachedPtrOffset, kind: fkPtr, bindNs: 0'i64)
  result = readPtr(f, obj) != nil

proc botState*(owner: Il2CppPtr): int32 =
  ## `EFT.BotOwner._botState` @0x30. -1 when it could not be read at all, which
  ## is the THIRD outcome and must not be flattened into "not Active".
  result = -1'i32
  if owner == nil: return
  var f = FieldBinding(ok: true, why: "EFT.BotOwner._botState@0x30",
                       target: "EFT.BotOwner._botState",
                       offset: BoBotStateOffset, kind: fkI32, bindNs: 0'i64)
  result = readInt32(f, owner)

proc botIsDead*(owner: Il2CppPtr): bool =
  if owner == nil: return true
  var f = FieldBinding(ok: true, why: "EFT.BotOwner.<IsDead>@0x431",
                       target: "EFT.BotOwner.IsDead",
                       offset: BoIsDeadOffset, kind: fkBool, bindNs: 0'i64)
  result = readBool(f, owner)

proc drivable*(player: Il2CppPtr; owner: Il2CppPtr; why: var string): bool =
  ## THE one gate every driving call passes, evaluated on the thread and at the
  ## moment of the call rather than when the bot was enumerated.
  ##
  ## It is written so that it CAN fail, and each way it can fail is counted
  ## separately, because "drives refused" as one number cannot tell a raid that
  ## is ending from a bot that never existed.
  ##
  ## Order matters: the Player's native half is checked before the BotOwner is
  ## touched at all, so a destroyed Player never becomes a field read on a
  ## component the game has already nulled.
  result = false
  why = ""
  if player == nil:
    why = "player null"
    return
  if not unityAlive(player):
    why = "player DESTROYED (m_CachedPtr==0)"
    inc gRefusedDestroyed
    return
  if owner == nil:
    why = "owner null"
    inc gRefusedDisposed
    return
  if not unityAlive(owner):
    why = "BotOwner DESTROYED (m_CachedPtr==0)"
    inc gRefusedDestroyed
    return
  let s = botState(owner)
  if s != EBotStateActive:
    # 4 is Disposed, 3 ActiveFail, 0 NonActive, 1 PreActive, -1 unreadable.
    # Every one of them is a refusal: only Active is a bot the game is willing
    # to be driven through.
    why = "BotOwner._botState=" & $s & " (Active=2 required)"
    inc gRefusedDisposed
    return
  if botIsDead(owner):
    why = "BotOwner.IsDead"
    inc gRefusedDead
    return
  inc gDriveAdmitted
  why = "Active"
  result = true

proc moverOf*(owner: Il2CppPtr): Il2CppPtr =
  componentAt(owner, BoMoverOffset, "<Mover>k__BackingField@0x3d0")
proc steeringOf*(owner: Il2CppPtr): Il2CppPtr =
  componentAt(owner, BoSteeringOffset, "<Steering>k__BackingField@0x148")
proc shootDataOf*(owner: Il2CppPtr): Il2CppPtr =
  componentAt(owner, BoShootDataOffset, "<ShootData>k__BackingField@0x280")
proc medecineOf*(owner: Il2CppPtr): Il2CppPtr =
  componentAt(owner, BoMedecineOffset, "<Medecine>k__BackingField@0x2c8")

# ---------------------------------------------------------------------------
# The driving calls
# ---------------------------------------------------------------------------

proc lookToPoint*(steering: Il2CppPtr; p: Vec3): bool =
  ## `void BotSteering::LookToPoint(Vector3 point)` @0x1A3B690, 1 owner.
  ## Two slots: `this`, then the Vector3 as a pointer.
  result = false
  if steering == nil or not canLook(): return
  var a = callArgs()
  a.addPtr(steering)
  a.addVec3(p.x, p.y, p.z)
  result = account("LookToPoint", callVoid(gSteeringLookTo, a))

proc setSprint*(mover: Il2CppPtr; on: bool): bool =
  ## `void BotMover::Sprint(bool val, bool withDebugCallback)` @0x1A2D700.
  ## `withDebugCallback` is passed false: the true branch runs the game's own
  ## debug callback, which is not something a mod should be firing.
  result = false
  if mover == nil or not canSprint(): return
  var a = callArgs()
  a.addPtr(mover)
  a.addBool(on)
  a.addBool(false)
  result = account("Mover::Sprint", callVoid(gMoverSprint, a))

proc stopMoving*(mover: Il2CppPtr): bool =
  ## `void BotMover::Stop()` @0x1A2D600. One slot.
  result = false
  if mover == nil or not canStop(): return
  var a = callArgs()
  a.addPtr(mover)
  result = account("Mover::Stop", callVoid(gMoverStop, a))

proc stopMoveOwner*(owner: Il2CppPtr): bool =
  ## `void EFT.BotOwner::StopMove()` @0x81C970 -- the same intent one level up,
  ## and the one whose prologue independently confirms `<Mover>@0x3d0`.
  result = false
  if owner == nil or not canStopMove(): return
  var a = callArgs()
  a.addPtr(owner)
  result = account("BotOwner::StopMove", callVoid(gStopMove, a))

proc fireOnce*(shootData: Il2CppPtr): bool =
  ## `bool ShootData::Shoot()` @0x1AF7940. The RETURN is the game's own answer
  ## to "did that shot happen", and it is reported rather than discarded: a
  ## refused or faulted call answers false for a DIFFERENT reason, so the two
  ## are kept apart in the log even though both come back as false here.
  result = false
  if shootData == nil or not canShoot(): return
  var a = callArgs()
  a.addPtr(shootData)
  let o = callBool(gShoot, a)
  if not account("ShootData::Shoot", o): return
  result = o.asBool()

# ---------------------------------------------------------------------------
# The two sensors
# ---------------------------------------------------------------------------

proc raycastHits*(ox, oy, oz, dx, dy, dz, maxDist: float; ok: var bool): bool =
  ## `bool Physics::Raycast(Vector3 origin, Vector3 direction, float maxDistance)`
  ## @0x5328830, 1 owner. Three slots: two Vector3 pointers and a float in XMM2
  ## by POSITION.
  ##
  ## `ok` is the third outcome. A refusal or a fault is not "the ray missed" --
  ## flattening those two is how a cover sensor silently reports open ground
  ## everywhere. Callers must read `ok` before `result`.
  ok = false
  result = false
  if not canRaycast(): return
  var a = callArgs()
  a.addVec3(ox, oy, oz)
  a.addVec3(dx, dy, dz)
  a.addFloat(maxDist)
  let o = callBool(gRaycast, a)
  if not account("Physics::Raycast", o): return
  ok = true
  result = o.asBool()

proc navSample*(x, y, z: float; maxDist: float; areaMask: int32;
                hitX, hitY, hitZ, hitDist: var float; ok: var bool): bool =
  ## `bool NavMesh::SamplePosition(Vector3, out NavMeshHit, float, int)`
  ## @0x5238930, 1 owner. Five slots exactly, which is the whole budget:
  ## the Vector3 pointer, the 36-byte out buffer, the float in XMM2 and the
  ## mask in R9.
  ##
  ## The out buffer is sized from the MEASURED `native_size` of
  ## `UnityEngine.AI.NavMeshHit` (36), not from subtracting a header off boxed
  ## field offsets.
  ##
  ## `ok` again separates "no navmesh within maxDist" from "this sensor could
  ## not answer". A filter that cannot answer must not report unwalkable
  ## ground, and must not report walkable either.
  ok = false
  result = false
  hitX = 0.0; hitY = 0.0; hitZ = 0.0; hitDist = 0.0
  if not canSample(): return
  var a = callArgs()
  a.addVec3(x, y, z)
  let cell = a.addOut(NavMeshHitBytes)
  if cell < 0'i32:
    warn "sain drive: NavMesh::SamplePosition could not stage its 36-byte " &
         "out buffer; not called"
    return
  a.addFloat(maxDist)
  a.addInt(int64(areaMask))
  let o = callBool(gNavSample, a)
  if not account("NavMesh::SamplePosition", o): return
  var r0 = false
  var r1 = false
  var r2 = false
  var r3 = false
  hitX = outFloat(cell, NavHitPositionOff, r0)
  hitY = outFloat(cell, NavHitPositionOff + 4'i32, r1)
  hitZ = outFloat(cell, NavHitPositionOff + 8'i32, r2)
  hitDist = outFloat(cell, NavHitDistanceOff, r3)
  if not (r0 and r1 and r2 and r3):
    warn "sain drive: NavMesh::SamplePosition returned but its out buffer " &
         "could not be read back; treating the sample as UNANSWERED rather " &
         "than as a miss"
    return
  ok = true
  result = o.asBool()
