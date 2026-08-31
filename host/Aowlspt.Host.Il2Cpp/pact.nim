## pact.nim -- IN-RAID ACTUATION OF THE LOCAL PLAYER.
##
## The user's brief, verbatim: "the ui automation should be next level and
## include the player inventory/walking/looking/firing/changing weapons/etc ...
## testing should be 100% automated, i shouldn't have to unload the magazine and
## reload the ammo for something to trigger for you to observe".
##
## This file is the ACTUATION half of that: the primitives a declarative test
## script calls. It does not parse scripts, mint gear or decide what to test --
## a separate layer does that and calls `pactPost` below.
##
## Every RVA, every calling shape, every field offset and every REFUSAL is
## derived and justified in `abi/aowlspt_pact.h`. Read that header first; this
## file deliberately does not repeat it. The three things worth restating here,
## because they shape the code rather than the table:
##
##   1. THE BOT DRIVE PATH DOES NOT TRANSFER. `mods/sain/client/drivecalls.nim`
##      drives a `BotOwner` through BotMover/BotSteering/ShootData. The local
##      player is an `EFT.Player` and holds none of those; handing one of the
##      five bot-receiver RVAs an `EFT.Player*` is type confusion that no
##      pointer guard can see. Only the two UnityEngine statics in that file
##      (NavMesh::SamplePosition, Physics::Raycast) are receiver-agnostic and
##      may be shared unchanged. The fold-together the user wants is a shared
##      VERB VOCABULARY over two backends, not a shared call table.
##   2. THE COMMAND CHANNEL IS THE BIG ONE. One byte-verified call --
##      `GamePlayerOwner::TranslateCommand(ECommand)` -- covers reload, weapon
##      swap, inventory, fire-mode and 84 other verbs through the game's own
##      input funnel, with `CanTranslateCommand` as a pre-check that can say no.
##   3. THE MAGAZINE CASE IS REAL AND CLOSED-LOOP. `pactMagCycle` unloads the
##      magazine in the weapon and loads the same ammunition back, driving
##      `LoadMagazineProcess` -- which is what `mods/ammoloading` hooks and
##      what a human previously had to do by hand.
##
## ---------------------------------------------------------------------------
## THE EIGHT RULES, AND WHERE EACH ONE LIVES
## ---------------------------------------------------------------------------
##
## 1. 16-byte prologue byte-verify before any call: `aowl_pact_fn` in the C
##    header, against the STARTUP SNAPSHOT (`aowl_pro_verify`), never live
##    memory. It additionally refuses `C2 00 00` and `B0 01 C3` BY SHAPE,
##    because a stub compares equal to itself and the snapshot check cannot
##    catch it.
## 2. VirtualQuery on every hop: `pactOk` wraps `cIsReadable` and is called on
##    each pointer separately -- `a->b->c` is three checks here, not one.
## 3. ONE `aowl_p_p_seh` for the whole body: `cPactTickGuarded`. NOTHING in this
##    file opens a second guard, because that guard is not re-entrant and a
##    nested inner guard DISARMS the outer one. This is why the public API is a
##    QUEUE rather than a set of direct-call procs: `pactPost` touches no game
##    memory at all and therefore cannot fault, and every instruction that does
##    touch game memory executes inside the single guarded drain body.
## 4. Capped iteration: the queue is a fixed 32-slot ring, the magazine state
##    machine has a frame deadline on every waiting step, and at most
##    `PactMaxPerTick` queue entries are executed per frame.
## 5. Flag-gated, DEFAULT OFF: `playerActuation`. Nothing binds, nothing is
##    verified and no detour is installed unless it is on.
## 6. Self-disable after N faults: `PactMaxFaults` = 8, whole-file budget,
##    because a wrong calling convention would not fault on only one channel.
## 7. No per-frame managed allocation: nothing here allocates managed memory.
##    The one managed value that crosses the boundary is the `Task<IResult>` the
##    two inventory calls return, which the game already owns and which the C
##    thunk discards without inspecting.
## 8. Never blind-write: every actuation is preceded by a validated receiver and
##    followed by a READBACK. See below.
##
## ---------------------------------------------------------------------------
## ACCEPTANCE (CLAUDE.md 9b) -- WHY THE COUNTERS ARE SHAPED THIS WAY
## ---------------------------------------------------------------------------
##
## "Asked to move and then logged that we asked" is a check that cannot fail.
## Every actuation class here therefore carries THREE counters, and a scripted
## run prints all three:
##
##   *Asked   -- the queue entry was executed and the call was made
##   *Took    -- a READBACK of the FINISHED STATE showed the intended change
##   *NoEffect-- the call was made and the readback did NOT change
##
## plus a fourth, `pactNeverIssued`, for entries that were dropped before the
## call (no player, no firearm, the game said CanTranslateCommand=false). Those
## four are mutually exclusive and they do not sum to anything convenient on
## purpose: a run in which nothing was issued reports INCONCLUSIVE, never PASS.
##
## The readbacks are properties of the finished state, not of our own write:
##   movement -> `Player::get_Position` sampled before and `PactSettleFrames`
##               later; the counter is metres actually travelled.
##   sprint   -> `Player::get_IsSprintEnabled`
##   aim      -> `FirearmController::get_IsAiming`
##   magazine -> `Magazine::get_Count`, polled, against the count captured
##               BEFORE the unload. This is the strongest one available: it is a
##               number the game maintains and that we never write.
##
## ---------------------------------------------------------------------------
## THREAD
## ---------------------------------------------------------------------------
##
## `pactPost` is safe from any thread: it writes only into this module's own
## ring buffer and reads no game memory.
##
## `pactDrainTick` MUST be, and is, called only from the host's
## `TarkovApplication::Update` main-thread drain. Everything that calls into
## IL2CPP happens there. The single exception is the capture detour on
## `GamePlayerOwner::LateUpdate`, which by construction already runs on Unity's
## thread and which does nothing but store one register value.

{.emit: """#include "aowlspt_pact.h" """.}

# ---- the byte-verified target table (abi/aowlspt_pact.h) ----
proc cPactFn(i: int32): Il2CppPtr {.importc: "aowl_pact_fn", nodecl.}
proc cPactName(i: int32): cstring {.importc: "aowl_pact_name", nodecl.}
proc cPactRva(i: int32): uint32 {.importc: "aowl_pact_rva", nodecl.}
proc cPactTargetCount(): int32 {.importc: "aowl_pact_target_count", nodecl.}
proc cPactOkCount(): int32 {.importc: "aowl_pact_ok_count", nodecl.}
proc cPactBadCount(): int32 {.importc: "aowl_pact_bad_count", nodecl.}
proc cPactReason(): int32 {.importc: "aowl_pact_reason", nodecl.}
proc cPactReasonText(): cstring {.importc: "aowl_pact_reason_text", nodecl.}
proc cPactModuleReady(): int32 {.importc: "aowl_pact_module_ready", nodecl.}
proc cPactWaitCount(): int32 {.importc: "aowl_pact_wait_count", nodecl.}

# ---- the thunks, one per measured calling shape ----
proc cPactVP(fn, self: Il2CppPtr): int32 {.importc: "aowl_pact_v_p", nodecl.}
proc cPactBP(fn, self: Il2CppPtr): int32 {.importc: "aowl_pact_b_p", nodecl.}
proc cPactPP(fn, self: Il2CppPtr): Il2CppPtr {.importc: "aowl_pact_p_p", nodecl.}
proc cPactIP(fn, self: Il2CppPtr): int32 {.importc: "aowl_pact_i_p", nodecl.}
proc cPactVPB(fn, self: Il2CppPtr; b: int32): int32 {.
  importc: "aowl_pact_v_pb", nodecl.}
proc cPactVPF(fn, self: Il2CppPtr; v: float64): int32 {.
  importc: "aowl_pact_v_pf", nodecl.}
proc cPactVPU(fn, self: Il2CppPtr; x, y: float64): int32 {.
  importc: "aowl_pact_v_pu", nodecl.}
proc cPactVPUB(fn, self: Il2CppPtr; x, y: float64; flag: int32): int32 {.
  importc: "aowl_pact_v_pub", nodecl.}
proc cPactIPI(fn, self: Il2CppPtr; a: int32): int32 {.
  importc: "aowl_pact_i_pi", nodecl.}
proc cPactGetV3(fn, self: Il2CppPtr): int32 {.
  importc: "aowl_pact_get_v3", nodecl.}
proc cPactV3x(): float64 {.importc: "aowl_pact_v3x", nodecl.}
proc cPactV3y(): float64 {.importc: "aowl_pact_v3y", nodecl.}
proc cPactV3z(): float64 {.importc: "aowl_pact_v3z", nodecl.}
proc cPactLookAt(fn, self: Il2CppPtr;
                 tx, ty, tz, px, py, pz, h: float64): int32 {.
  importc: "aowl_pact_lookat", nodecl.}
proc cPactLookX(): float64 {.importc: "aowl_pact_look_x", nodecl.}
proc cPactLookY(): float64 {.importc: "aowl_pact_look_y", nodecl.}
proc cPactLoadMag(fn, self, ammo, mag: Il2CppPtr;
                  count, ignoreRestrictions: int32): int32 {.
  importc: "aowl_pact_load_mag", nodecl.}
proc cPactUnloadMag(fn, self, mag: Il2CppPtr; equipBlocked: int32): int32 {.
  importc: "aowl_pact_unload_mag", nodecl.}

# ---- measured field offsets (abi/aowlspt_pact.h) ----
proc cPactOffMainPlayer(): int32 {.importc: "aowl_pact_off_gw_mainplayer", nodecl.}
proc cPactOffIsYou(): int32 {.importc: "aowl_pact_off_pl_isyou", nodecl.}
proc cPactOffAiData(): int32 {.importc: "aowl_pact_off_pl_aidata", nodecl.}
proc cPactOffMoveCtx(): int32 {.importc: "aowl_pact_off_pl_movectx", nodecl.}

# The SEH/VEH guard thunk. ONE per body, never nested. `aowl_p_p_seh` arms a
# vectored exception handler plus setjmp, calls the body, and returns nil rather
# than letting an access violation reach the game.
{.emit: """
extern void* aowl_pact_tick_body(void* a);
static void* aowl_pact_tick_guarded(void* a) {
    return aowl_p_p_seh((void*)aowl_pact_tick_body, a);
}
""".}
proc cPactTickGuarded(a: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_pact_tick_guarded", nodecl.}

const
  # Target indices -- MUST match the AOWL_PACT_* #defines in abi/aowlspt_pact.h.
  # `pactIndicesOk` compares the NAME the C table actually holds at each index
  # against the name this code believes is there, at boot, once. That check
  # exists because the identical class of bug once handed
  # `Transform::set_localPosition` a NULL Vector3 pointer through a perfectly
  # valid, byte-verified function and faulted inside the call. Here the same
  # slip would hand `Player::Rotate`'s (Vector2, bool) shape to
  # `Player::get_Position`'s sret shape.
  PactTGetPos      = 0'i32   ## EFT.Player::get_Position
  PactTMove        = 1'i32   ## EFT.Player::Move
  PactTRotate      = 2'i32   ## EFT.Player::Rotate
  PactTJump        = 3'i32   ## EFT.Player::Jump
  PactTChangePose  = 4'i32   ## EFT.Player::ChangePose
  PactTToggleProne = 5'i32   ## EFT.Player::ToggleProne
  PactTEnaSprint   = 6'i32   ## EFT.Player::EnableSprint
  PactTTogSprint   = 7'i32   ## EFT.Player::ToggleSprint
  PactTGetSprint   = 8'i32   ## EFT.Player::get_IsSprintEnabled
  PactTLean        = 9'i32   ## EFT.Player::ToggleLean
  PactTIsYou       = 10'i32  ## EFT.Player::get_IsYourPlayer
  PactTIsAI        = 11'i32  ## EFT.Player::get_IsAI
  PactTHasFirearm  = 12'i32  ## EFT.Player::HasFirearmInHands
  PactTGetHands    = 13'i32  ## EFT.Player::get_HandsController
  PactTGetInvCtrl  = 14'i32  ## EFT.Player::get_InventoryController
  PactTSetTrigger  = 15'i32  ## FirearmController::SetTriggerPressed
  PactTToggleAim   = 16'i32  ## FirearmController::ToggleAim
  PactTSetAiming   = 17'i32  ## FirearmController::set_IsAiming
  PactTGetAiming   = 18'i32  ## FirearmController::get_IsAiming
  PactTFireMode    = 19'i32  ## FirearmController::ChangeFireMode
  PactTCheckAmmo   = 20'i32  ## FirearmController::CheckAmmo
  PactTGetItem     = 21'i32  ## FirearmController::get_Item
  PactTTranslate   = 22'i32  ## EFT.GamePlayerOwner::TranslateCommand
  PactTCanTrans    = 23'i32  ## EFT.GamePlayerOwner::CanTranslateCommand
  PactTMyPlayer    = 24'i32  ## EFT.GamePlayerOwner::get_MyPlayer
  PactTLoadMag     = 25'i32  ## PlayerInventoryController::LoadMagazine
  PactTUnloadMag   = 26'i32  ## PlayerInventoryController::UnloadMagazine
  PactTCurMag      = 27'i32  ## EFT.InventoryLogic.Weapon::GetCurrentMagazine
  PactTMagCount    = 28'i32  ## EFT.InventoryLogic.Magazine::get_Count
  PactTFirstAmmo   = 29'i32  ## EFT.InventoryLogic.Magazine::FirstRealAmmo
  PactTLookAtDir   = 30'i32  ## EFT.MovementContext::CalculateLookAtDirection

  PactMaxFaults = 8
    ## Rule 6, whole-FILE budget rather than per-channel. A wrong calling
    ## convention or a stale offset after a client update would not confine
    ## itself to one channel, so a per-channel budget would let seven of eight
    ## channels keep faulting while the eighth reported healthy.

  PactQueueCap = 32
    ## Rule 4. A fixed ring; `pactPost` REFUSES and counts an overflow rather
    ## than growing, so a runaway script layer cannot make this module allocate.
  PactMaxPerTick = 4
    ## At most four queue entries per frame. Actuation is inherently temporal --
    ## draining the whole queue in one frame would collapse a movement script
    ## into a single frame of input and produce a "nothing moved" verdict for a
    ## reason that has nothing to do with the primitives.

  PactSettleFrames = 30'i64
    ## ~0.5s at 60fps. How long after a movement command the position readback
    ## is taken. Chosen to be long enough that a real step is unambiguous and
    ## short enough that a script does not stall.
  PactMagDeadline = 180'i64
    ## ~3s. The poll deadline for each async inventory step. Exceeding it is
    ## reported as ISSUED-BUT-NEVER-COMPLETED, which is a distinct outcome from
    ## both success and never-issued.
  PactMinMoveM = 0.35
    ## Metres. Below this a position change is indistinguishable from the
    ## idle sway/settle the game applies on its own, so it is NOT counted as
    ## movement. A threshold that counted noise would be a check that cannot
    ## fail.

  # Queue verbs.
  PvMove     = 1'i32
  PvRotate   = 2'i32
  PvLookAt   = 3'i32
  PvJump     = 4'i32
  PvPose     = 5'i32
  PvProne    = 6'i32
  PvSprint   = 7'i32
  PvLean     = 8'i32
  PvFire     = 9'i32
  PvAim      = 10'i32
  PvFireMode = 11'i32
  PvCommand  = 12'i32
  PvMagCycle = 13'i32
  PvWait     = 14'i32

  # ECommand ordinals a script is most likely to want, mirrored from the C
  # header so a caller in this file does not have to reach across.
  PactCmdReload      = 16'i32
  PactCmdQuickReload = 19'i32
  PactCmdSelPrimary1 = 41'i32
  PactCmdSelPrimary2 = 42'i32
  PactCmdSelSecond   = 43'i32
  PactCmdInventory   = 37'i32

type
  PactCmd = object
    verb: int32
    a, b, c: float64
    i: int32
    frames: int32     ## how long a HELD verb is held

var gPactOn = false            ## flag `playerActuation` -- default OFF
var gPactBindState = 0'i32     ## 0 untried, 1 deferred (retryable), 2 settled
var gPactBindTries = 0'i64
var gPactBindSaidWait = false
var gPactIndicesOk = -1'i32    ## -1 not checked, 1 ok, 0 MISMATCH
var gPactFaults = 0
var gPactTicks = 0'i64
var gPactWhy = "not attempted"

## The receiver chain. Every one is re-validated every tick; none is trusted
## across frames on the strength of having been valid once. Unity fake null is
## the reason: a destroyed object stays READABLE with `m_CachedPtr` zeroed and
## dies on the next internal call, so readability is not liveness.
var gPactYou: Il2CppPtr = nil      ## the local EFT.Player
var gPactYouKlass = 0'u64          ## pinned on first acquisition
var gPactOwner: Il2CppPtr = nil    ## the captured EFT.GamePlayerOwner
var gPactOwnerKlass = 0'u64
var gPactOwnerFires = 0'i64
var gPactOwnerTries = 0'i64
var gPactOwnerAgrees = -1'i32      ## -1 unknown, 1 get_MyPlayer == our player

## The queue.
var gPactQ: array[PactQueueCap, PactCmd]
var gPactQHead = 0
var gPactQTail = 0
var gPactQCount = 0
var gPactQDropped = 0'i64

## Held input state. `Player::Move` is an INPUT, not a command: it must be
## re-asserted every frame for as long as the player should be walking. `Fire`
## and `Aim` are latches and are not re-asserted.
var gPactHoldX = 0.0
var gPactHoldY = 0.0
var gPactHoldFrames = 0'i32
var gPactWaitFrames = 0'i32

## Movement readback.
var gPactMoveMark = false
var gPactMarkX = 0.0
var gPactMarkY = 0.0
var gPactMarkZ = 0.0
var gPactMarkAt = 0'i64
var gPactLastMoveM = 0.0

## The counters. Four mutually exclusive outcomes, per CLAUDE.md 9b.
var gPactAsked = 0'i64        ## a call was actually made
var gPactTook = 0'i64         ## a readback confirmed the finished state
var gPactNoEffect = 0'i64     ## the call was made and the readback did not move
var gPactNeverIssued = 0'i64  ## dropped before the call, with a stated reason
var gPactLastRefusal = ""

## The magazine state machine.
var gMagStep = 0'i32
var gMagAt = 0'i64
var gMagMag: Il2CppPtr = nil
var gMagAmmo: Il2CppPtr = nil
var gMagInv: Il2CppPtr = nil
var gMagN0 = -1'i32
var gMagCycles = 0'i64
var gMagOk = 0'i64
var gMagFailed = 0'i64
var gMagWhy = "never run"

proc pactDisabled*(): bool = gPactFaults >= PactMaxFaults

proc pactOk(p: Il2CppPtr; size: int32): bool =
  ## Rule 2. Every hop, separately. `bdSanePtr` rejects the low and the
  ## obviously-bogus address ranges before `cIsReadable` is asked, because a
  ## VirtualQuery on a small integer is a wasted syscall that can still return
  ## a committed page in a pathological process.
  if p == nil: return false
  if not bdSanePtr(p): return false
  cIsReadable(p, size) != 0'i32

proc pactFn(i: int32): Il2CppPtr =
  ## Bind one target. Byte-verified against the startup snapshot AND refused by
  ## shape if it is the universal empty stub; see the C header.
  cPactFn(i)

# ---------------------------------------------------------------------------
# Boot-time integrity: the index/name agreement
# ---------------------------------------------------------------------------

proc pactCheckIndices(): bool =
  ## Compare, once, the name the C table holds at each index against the name
  ## the constants above claim is there. A positional table and a set of named
  ## constants that drift apart is not a compile error and is not visible in a
  ## log; it is a call through the wrong shape. `tools/idxbind.py` enforces the
  ## same agreement at BUILD time from the source text -- this is the runtime
  ## half, and the two are deliberately independent so a change that fools one
  ## still has to fool the other.
  if gPactIndicesOk >= 0'i32: return gPactIndicesOk == 1'i32
  # A flat, ordered list rather than a nested closure: the position in this
  # array IS the target index, so a row inserted in the C table without a
  # matching row here shifts every later name and the check trips.
  let expect = [
    "EFT.Player::get_Position",
    "EFT.Player::Move",
    "EFT.Player::Rotate",
    "EFT.Player::Jump",
    "EFT.Player::ChangePose",
    "EFT.Player::ToggleProne",
    "EFT.Player::EnableSprint",
    "EFT.Player::ToggleSprint",
    "EFT.Player::get_IsSprintEnabled",
    "EFT.Player::ToggleLean",
    "EFT.Player::get_IsYourPlayer",
    "EFT.Player::get_IsAI",
    "EFT.Player::HasFirearmInHands",
    "EFT.Player::get_HandsController",
    "EFT.Player::get_InventoryController",
    "FirearmController::SetTriggerPressed",
    "FirearmController::ToggleAim",
    "FirearmController::set_IsAiming",
    "FirearmController::get_IsAiming",
    "FirearmController::ChangeFireMode",
    "FirearmController::CheckAmmo",
    "FirearmController::get_Item",
    "EFT.GamePlayerOwner::TranslateCommand",
    "EFT.GamePlayerOwner::CanTranslateCommand",
    "EFT.GamePlayerOwner::get_MyPlayer",
    "PlayerInventoryController::LoadMagazine",
    "PlayerInventoryController::UnloadMagazine",
    "EFT.InventoryLogic.Weapon::GetCurrentMagazine",
    "EFT.InventoryLogic.Magazine::get_Count",
    "EFT.InventoryLogic.Magazine::FirstRealAmmo",
    "EFT.MovementContext::CalculateLookAtDirection"]
  var ok = true
  var bad = ""
  var i = 0
  while i < expect.len and i < int(cPactTargetCount()):
    let got = readCString(cPactName(int32(i)))
    if got != expect[i]:
      ok = false
      if bad.len == 0:
        bad = "index " & $i & " is \"" & got & "\" but this code calls it \"" &
              expect[i] & "\""
    i = i + 1
  if int(cPactTargetCount()) != expect.len:
    ok = false
    if bad.len == 0:
        bad = "the C table has " & $int(cPactTargetCount()) &
            " rows, this code names " & $expect.len
  gPactIndicesOk = (if ok: 1'i32 else: 0'i32)
  if not ok:
    warn "pact: TARGET INDEX/NAME MISMATCH -- " & bad &
         ". Every actuation is REFUSED. This is a defect in " &
         "abi/aowlspt_pact.h or in this file's constants, NOT a wrong RVA " &
         "and NOT a client change."
  ok

# ---------------------------------------------------------------------------
# The receiver chain
# ---------------------------------------------------------------------------

proc pactAcquireYou(): bool =
  ## The local player, re-derived every tick from the borrowed GameWorld and
  ## re-validated in full. NEVER cached across frames on the strength of one
  ## success.
  ##
  ## The order of the checks is deliberate and each one CAN fail:
  ##   readable            -- VirtualQuery, the cheapest and weakest
  ##   Unity-alive         -- `m_CachedPtr` non-zero; a destroyed UnityEngine
  ##                          object stays readable and dies on the next
  ##                          internal call, so readability is NOT liveness
  ##   klass pinned        -- the klass word must equal the one seen first; a
  ##                          change means the pointer is a DIFFERENT type now,
  ##                          which is the type-confusion case that beats both
  ##                          guards above
  ##   IsYourPlayer        -- a PURE byte read at +0xB89 compiled as
  ##                          `movzx eax,[rcx+0xB89]; ret`, so it cannot
  ##                          dispatch anywhere and cannot fault on any object
  ##                          this large. It is the first call made, on purpose.
  ##   AIData == nil       -- the local player must not be AI-driven. Raw field
  ##                          read, no call.
  gPactYou = nil
  let gw = gDuGameWorld
  if not pactOk(gw, cPactOffMainPlayer() + 8'i32): return false
  let you = cReadPtrAt(gw, cPactOffMainPlayer())
  if not pactOk(you, 0xB90'i32): return false
  if not iUnityAlive(you): return false
  let k = iKlassOf(you)
  if k == 0'u64: return false
  if gPactYouKlass == 0'u64:
    gPactYouKlass = k
  elif gPactYouKlass != k:
    gPactLastRefusal = "the MainPlayer klass word changed (0x" &
      hexOf(gPactYouKlass) & " -> 0x" & hexOf(k) &
      "); the pointer is a different type now, refusing"
    return false
  # AIData: a raw read, no call. Non-null means this is a bot, and a bot is
  # never the receiver for anything in this file.
  if not pactOk(you, cPactOffAiData() + 8'i32): return false
  if cReadPtrAt(you, cPactOffAiData()) != nil: return false
  let fnIsYou = pactFn(PactTIsYou)
  if fnIsYou == nil: return false
  if cPactBP(fnIsYou, you) != 1'i32: return false
  gPactYou = you
  true

proc pactHands(): Il2CppPtr =
  ## The FirearmController, and ONLY when the game itself says a firearm is in
  ## hands. `get_HandsController` returns the ABSTRACT base; if the player holds
  ## a knife or nothing, calling `FirearmController::get_Item` on that pointer
  ## reads a FirearmController field offset off an unrelated object. That is
  ## type confusion, which `cIsReadable` cannot see and a null check passes.
  ## `HasFirearmInHands()` is the game's own answer and there is NO path in this
  ## file that reaches a FirearmController row without it.
  if gPactYou == nil: return nil
  let fnHas = pactFn(PactTHasFirearm)
  if fnHas == nil: return nil
  if cPactBP(fnHas, gPactYou) != 1'i32:
    gPactLastRefusal = "HasFirearmInHands() is false -- no FirearmController " &
      "call is safe on this hands controller"
    return nil
  let fnHands = pactFn(PactTGetHands)
  if fnHands == nil: return nil
  let hc = cPactPP(fnHands, gPactYou)
  if not pactOk(hc, 0x200'i32): return nil
  if not iUnityAlive(hc): return nil
  hc

proc pactPos(px, py, pz: var float64): bool =
  ## `Player::get_Position`, sret. Rejects NaN and absurd magnitudes in the C
  ## thunk, so a half-torn-down transform cannot feed a plausible-looking number
  ## into a movement verdict.
  px = 0.0; py = 0.0; pz = 0.0
  if gPactYou == nil: return false
  let fn = pactFn(PactTGetPos)
  if fn == nil: return false
  if cPactGetV3(fn, gPactYou) != 1'i32: return false
  px = cPactV3x(); py = cPactV3y(); pz = cPactV3z()
  true

# ---------------------------------------------------------------------------
# The GamePlayerOwner capture detour
# ---------------------------------------------------------------------------

{.emit: """
extern void* aowl_pact_owner_body(void* a);
static void* aowl_pact_owner_guarded(void* a) {
    return aowl_p_p_seh((void*)aowl_pact_owner_body, a);
}
""".}
proc cPactOwnerGuarded(a: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_pact_owner_guarded", nodecl.}

proc pactOwnerBody(regs: Il2CppPtr): Il2CppPtr {.
    exportc: "aowl_pact_owner_body", cdecl.} =
  ## The whole body of the read-only capture detour on
  ## `EFT.GamePlayerOwner::LateUpdate` @0xB29130 (unique, owners=1, real body).
  ##
  ## It stores ONE register and returns. It writes no game state, calls nothing,
  ## allocates nothing and iterates over nothing, which is why a capture detour
  ## is the right instrument here and a `GetComponent` by name is not: on this
  ## build the by-name export is token-gated and its failure mode is a uniform
  ## random NON-ZERO pointer, so a nil check passes and the first dereference
  ## kills the client.
  ##
  ## The pointer is only VALIDATED here, never used; every use is on the drain,
  ## inside the drain's own guard, after `pactOwnerAgrees` has corroborated it
  ## against the player we already trust.
  let raw = cRegsInt(regs, 0'i32)
  if raw == 0'u64: return cast[Il2CppPtr](1)
  let p = cast[Il2CppPtr](raw)
  if not pactOk(p, 0x100'i32): return cast[Il2CppPtr](1)
  let k = iKlassOf(p)
  if k == 0'u64: return cast[Il2CppPtr](1)
  if gPactOwnerKlass == 0'u64:
    gPactOwnerKlass = k
  elif gPactOwnerKlass != k:
    # LateUpdate is unique to GamePlayerOwner, so this cannot legitimately
    # happen. If it does, the capture is abandoned rather than trusted.
    gPactOwner = nil
    return cast[Il2CppPtr](1)
  gPactOwner = p
  gPactOwnerFires = gPactOwnerFires + 1
  cast[Il2CppPtr](1)

proc pactOwnerFired(regs: Il2CppPtr) =
  if cPactOwnerGuarded(regs) == nil:
    gPactFaults = gPactFaults + 1

# The detour target is declared separately from the call table because it is the
# only address in this feature that is WRITTEN to rather than called, and mixing
# the two in one table is how a `NEVER DETOUR` note gets ignored.
{.emit: """
typedef struct { const char* name; uint32_t rva; const unsigned char sig[16]; } AowlPactHook;
static const AowlPactHook aowl_pact_hook = {
    /* EFT.GamePlayerOwner::LateUpdate @0xB29130, rid=55167, UNIQUE owners=1.
     * 48 89 5C 24 08  mov [rsp+8], rbx
     * 57              push rdi
     * 48 83 EC 40     sub rsp, 0x40
     * 48 8B D9        mov rbx, rcx      <- `this` is the GamePlayerOwner
     * 48 8B 89 ..     mov rcx, [rcx+..]
     * The first three instructions are a clean whole-instruction steal for the
     * trampoline: no RIP-relative operand and no branch. */
    "EFT.GamePlayerOwner::LateUpdate", 0xB29130u,
    { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x40,0x48,0x8B,0xD9,
      0x48,0x8B,0x89 }
};
static void* aowl_pact_hook_fn(void) {
    HMODULE ga; unsigned char* p; MEMORY_BASIC_INFORMATION mbi;
    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) return NULL;
    p = (unsigned char*)ga + aowl_pact_hook.rva;
    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return NULL;
    if (mbi.State != MEM_COMMIT) return NULL;
    if (!(mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)))
        return NULL;
    if (!aowl_pro_verify(aowl_pact_hook.rva, aowl_pact_hook.sig, 16)) return NULL;
    if (p[0] == 0xC2 && p[1] == 0x00 && p[2] == 0x00) return NULL;
    return (void*)p;
}
static const char* aowl_pact_hook_name(void) { return aowl_pact_hook.name; }
""".}
proc cPactHookFn(): Il2CppPtr {.importc: "aowl_pact_hook_fn", nodecl.}
proc cPactHookName(): cstring {.importc: "aowl_pact_hook_name", nodecl.}

proc pactBindOwnerAt(verbose: bool): bool =
  if gPactOwnerSlot >= 0: return true
  if not gReady or gDisableDrain: return false
  let fn = cPactHookFn()
  if fn == nil:
    if verbose:
      info "pact: GamePlayerOwner::LateUpdate did not verify against the " &
           "startup snapshot; the ECommand channel is UNAVAILABLE (reload, " &
           "weapon swap and inventory verbs are REFUSED). Movement, look, " &
           "fire, aim and the magazine cycle are unaffected -- they do not " &
           "use this receiver."
    return false
  let spec = readCString(cPactHookName())
  # KIND 22, and the number is load-bearing. `attachDrain`'s `kind` is what
  # selects WHICH slot global the claimed slot index is written into, and
  # `patchFired` dispatches by comparing the firing index against those globals.
  # This was written as `5` first -- botdiag's kind, copied along with the shape
  # of the call -- which would have overwritten `gBotDiagSlot` and routed every
  # `GameWorld::RegisterPlayer` fire into pact's owner-capture body while
  # botdiag silently stopped receiving any. It fails SILENTLY in both features
  # at once, which is why the number is called out here rather than left to be
  # read off the argument list.
  # NOTE the absence of an assignment here. `attachDrain` writes the claimed
  # slot index into `gPactOwnerSlot` ITSELF, keyed off `kind`. An assignment on
  # this line would overwrite a real slot index with a made-up one and
  # `patchFired` would then dispatch the wrong firing to this handler.
  if attachDrain(spec, fn, cast[Il2CppMethod](0), false, verbose, 22'i32):
    okLog "pact: read-only capture detour armed on " & spec &
          " -- it records the GamePlayerOwner receiver and does nothing else. " &
          "The ECommand channel is available once it has fired."
    return true
  false

# ---------------------------------------------------------------------------
# The queue. `pactPost` touches NO game memory and therefore cannot fault, which
# is what lets a caller on any thread and inside any guard use it safely.
# ---------------------------------------------------------------------------

proc pactPost*(verb: int32; a, b, c: float64; i: int32; frames: int32): bool =
  ## Enqueue one actuation. Returns false and counts a drop if the ring is full
  ## -- it never grows and never blocks.
  if not gPactOn: return false
  if pactDisabled(): return false
  if gPactQCount >= PactQueueCap:
    gPactQDropped = gPactQDropped + 1
    return false
  gPactQ[gPactQTail] = PactCmd(verb: verb, a: a, b: b, c: c, i: i,
                               frames: frames)
  gPactQTail = (gPactQTail + 1) mod PactQueueCap
  gPactQCount = gPactQCount + 1
  true

# Convenience posters. These are the vocabulary the declarative script layer
# calls; they are thin on purpose so that layer never has to know a verb code.
proc pactMove*(x, y: float64; frames: int32): bool =
  ## Walk. `x` is strafe (-1 left, +1 right), `y` is forward (-1 back, +1
  ## forward), in the game's own normalised input units -- the same Vector2
  ## `Player::Move` receives from the input tree. Held for `frames` frames,
  ## because Move is an INPUT and must be re-asserted every frame.
  pactPost(PvMove, x, y, 0.0, 0'i32, frames)
proc pactRotate*(dx, dy: float64): bool =
  ## Look by a delta, in the game's own rotation units (x yaw, y pitch).
  pactPost(PvRotate, dx, dy, 0.0, 0'i32, 0'i32)
proc pactLookAt*(x, y, z: float64): bool =
  ## Look toward a world point, using the game's OWN conversion
  ## (`MovementContext::CalculateLookAtDirection`) rather than trigonometry of
  ## ours, so the units cannot disagree with the game's.
  pactPost(PvLookAt, x, y, z, 0'i32, 0'i32)
proc pactJump*(): bool = pactPost(PvJump, 0.0, 0.0, 0.0, 0'i32, 0'i32)
proc pactPose*(delta: float64): bool =
  ## Crouch/stand. Negative lowers, positive raises.
  pactPost(PvPose, delta, 0.0, 0.0, 0'i32, 0'i32)
proc pactProne*(): bool = pactPost(PvProne, 0.0, 0.0, 0.0, 0'i32, 0'i32)
proc pactSprint*(on: bool): bool =
  pactPost(PvSprint, 0.0, 0.0, 0.0, (if on: 1'i32 else: 0'i32), 0'i32)
proc pactLean*(dir: float64): bool =
  pactPost(PvLean, dir, 0.0, 0.0, 0'i32, 0'i32)
proc pactFire*(on: bool): bool =
  ## Hold or release the trigger. This is a LATCH, not an edge: a script that
  ## posts `pactFire(true)` and never posts `pactFire(false)` leaves the trigger
  ## down.
  pactPost(PvFire, 0.0, 0.0, 0.0, (if on: 1'i32 else: 0'i32), 0'i32)
proc pactAim*(on: bool): bool =
  pactPost(PvAim, 0.0, 0.0, 0.0, (if on: 1'i32 else: 0'i32), 0'i32)
proc pactFireMode*(mode: int32): bool =
  pactPost(PvFireMode, 0.0, 0.0, 0.0, mode, 0'i32)
proc pactCommand*(cmd: int32): bool =
  ## Issue one `ECommand` through the game's own input funnel. This is the verb
  ## that covers reload (16), quick reload (19), weapon select (41/42/43),
  ## inventory (37) and 84 others.
  pactPost(PvCommand, 0.0, 0.0, 0.0, cmd, 0'i32)
proc pactMagCycle*(): bool =
  ## THE USER'S OWN EXAMPLE. Unload the magazine in the weapon and load the same
  ## ammunition back into it, so a magazine-loading feature can be observed with
  ## nobody at the keyboard.
  pactPost(PvMagCycle, 0.0, 0.0, 0.0, 0'i32, 0'i32)
proc pactWait*(frames: int32): bool =
  pactPost(PvWait, 0.0, 0.0, 0.0, 0'i32, frames)

# ---------------------------------------------------------------------------
# The magazine cycle
# ---------------------------------------------------------------------------

proc magCount(): int32 =
  ## `Magazine::get_Count`. -1 means "could not ask", which is a THIRD outcome
  ## and is never collapsed into 0 -- a magazine legitimately holds 0 rounds and
  ## a poll that cannot tell the difference is a check that cannot fail.
  if gMagMag == nil: return -1'i32
  if not pactOk(gMagMag, 0xB0'i32): return -1'i32
  let fn = pactFn(PactTMagCount)
  if fn == nil: return -1'i32
  cPactIP(fn, gMagMag)

proc magFail(why: string) =
  gMagStep = 0'i32
  gMagFailed = gMagFailed + 1
  gMagWhy = why
  gMagMag = nil; gMagAmmo = nil; gMagInv = nil; gMagN0 = -1'i32
  warn "pact magcycle: " & why

proc magBegin() =
  ## Step 1: reach a type-correct Magazine and Ammo from the live player, with
  ## every hop validated. NO inventory-grid walk is involved; see section 4 of
  ## abi/aowlspt_pact.h for why this chain is the one chosen.
  gMagMag = nil; gMagAmmo = nil; gMagInv = nil; gMagN0 = -1'i32
  let hc = pactHands()
  if hc == nil:
    magFail("no firearm in hands (HasFirearmInHands() said false, or the " &
            "hands controller did not validate). NEVER ISSUED.")
    return
  let fnItem = pactFn(PactTGetItem)
  if fnItem == nil: magFail("FirearmController::get_Item did not verify"); return
  let wp = cPactPP(fnItem, hc)
  if not pactOk(wp, 0xC0'i32):
    magFail("the Weapon from get_Item did not validate. NEVER ISSUED."); return
  let fnMag = pactFn(PactTCurMag)
  if fnMag == nil: magFail("Weapon::GetCurrentMagazine did not verify"); return
  let mg = cPactPP(fnMag, wp)
  if not pactOk(mg, 0xB0'i32):
    magFail("no magazine in the weapon (GetCurrentMagazine returned nothing " &
            "usable). NEVER ISSUED."); return
  gMagMag = mg
  let n0 = magCount()
  if n0 <= 0'i32:
    magFail("the magazine reads " & $n0 & " rounds; there is nothing to " &
            "unload, so nothing was issued. Load the magazine once and " &
            "re-run. NEVER ISSUED.")
    return
  gMagN0 = n0
  let fnAmmo = pactFn(PactTFirstAmmo)
  if fnAmmo == nil: magFail("Magazine::FirstRealAmmo did not verify"); return
  let am = cPactPP(fnAmmo, gMagMag)
  if not pactOk(am, 0x80'i32):
    magFail("FirstRealAmmo() gave nothing usable. NEVER ISSUED."); return
  gMagAmmo = am
  let fnInv = pactFn(PactTGetInvCtrl)
  if fnInv == nil: magFail("Player::get_InventoryController did not verify"); return
  let inv = cPactPP(fnInv, gPactYou)
  if not pactOk(inv, 0x100'i32):
    magFail("the InventoryController did not validate. NEVER ISSUED."); return
  gMagInv = inv
  gMagCycles = gMagCycles + 1
  gMagStep = 2'i32
  gMagAt = gPactTicks
  okLog "pact magcycle: captured magazine with " & $n0 & " rounds; unloading."

proc magTick() =
  ## The state machine. Every WAITING step has a frame deadline, and exceeding
  ## it is reported as ISSUED-BUT-NEVER-COMPLETED, which is deliberately a
  ## different outcome from both success and never-issued.
  case gMagStep
  of 2'i32:
    let fn = pactFn(PactTUnloadMag)
    if fn == nil: magFail("UnloadMagazine did not verify"); return
    if cPactUnloadMag(fn, gMagInv, gMagMag, 0'i32) != 1'i32:
      magFail("UnloadMagazine refused at the thunk (a null argument). " &
              "NEVER ISSUED."); return
    gPactAsked = gPactAsked + 1
    gMagStep = 3'i32
    gMagAt = gPactTicks
  of 3'i32:
    let n = magCount()
    if n == 0'i32:
      # THE READBACK. The count is a number the game maintains and we never
      # write, so this is a property of the finished state, not of our call.
      gPactTook = gPactTook + 1
      gMagStep = 4'i32
      gMagAt = gPactTicks
    elif (gPactTicks - gMagAt) > PactMagDeadline:
      gPactNoEffect = gPactNoEffect + 1
      magFail("UnloadMagazine WAS ISSUED but Magazine.Count is still " & $n &
              " after " & $PactMagDeadline & " frames. This is not 'never " &
              "issued' -- the call was made and the game did not act.")
  of 4'i32:
    # Re-validate the Ammo pointer. The unload MOVED the ammunition to another
    # container; the managed object identity is expected to survive that, but
    # that is INFERRED, not measured, so it is re-checked here rather than
    # trusted. A stale pointer refuses loudly instead of being passed in.
    if not pactOk(gMagAmmo, 0x80'i32):
      magFail("the Ammo pointer did not survive the unload. The identity of " &
              "the ammunition across an inventory move was INFERRED, not " &
              "measured; this is that inference failing, and it refuses " &
              "rather than passing a stale pointer into LoadMagazine.")
      return
    if not pactOk(gMagMag, 0xB0'i32):
      magFail("the Magazine pointer did not survive the unload."); return
    let fn = pactFn(PactTLoadMag)
    if fn == nil: magFail("LoadMagazine did not verify"); return
    if cPactLoadMag(fn, gMagInv, gMagAmmo, gMagMag, gMagN0, 0'i32) != 1'i32:
      magFail("LoadMagazine refused at the thunk. NEVER ISSUED."); return
    gPactAsked = gPactAsked + 1
    gMagStep = 5'i32
    gMagAt = gPactTicks
  of 5'i32:
    let n = magCount()
    if n >= gMagN0:
      gPactTook = gPactTook + 1
      gMagOk = gMagOk + 1
      gMagWhy = "unloaded " & $gMagN0 & " rounds and loaded them back; " &
                "Magazine.Count returned to " & $n
      okLog "pact magcycle: COMPLETE -- " & gMagWhy &
            ". LoadMagazineProcess ran with nobody at the keyboard."
      gMagStep = 0'i32
      gMagMag = nil; gMagAmmo = nil; gMagInv = nil
    elif (gPactTicks - gMagAt) > PactMagDeadline:
      gPactNoEffect = gPactNoEffect + 1
      magFail("LoadMagazine WAS ISSUED but Magazine.Count is " & $n &
              " of an expected " & $gMagN0 & " after " & $PactMagDeadline &
              " frames. The call was made; the game did not finish it. " &
              "A partial load is reported as a FAILURE here on purpose -- " &
              "'some rounds went in' is not the state that was asked for.")
  else:
    discard

# ---------------------------------------------------------------------------
# Executing one queue entry
# ---------------------------------------------------------------------------

proc pactNever(why: string) =
  gPactNeverIssued = gPactNeverIssued + 1
  gPactLastRefusal = why

proc pactExec(c: PactCmd) =
  case c.verb
  of PvMove:
    # Held: recorded here, re-asserted every frame by pactApplyHeld.
    gPactHoldX = c.a
    gPactHoldY = c.b
    gPactHoldFrames = (if c.frames > 0'i32: c.frames else: 1'i32)
    # Mark the position so the readback measures metres actually travelled.
    # Explicitly zeroed: nimony will not pass a `var` out-parameter it cannot
    # prove initialised, and that rule is worth keeping -- the values are only
    # meaningful when `pactPos` returned true.
    var x = 0.0
    var y = 0.0
    var z = 0.0
    if pactPos(x, y, z):
      gPactMarkX = x; gPactMarkY = y; gPactMarkZ = z
      gPactMarkAt = gPactTicks
      gPactMoveMark = true
    else:
      gPactMoveMark = false
  of PvRotate:
    let fn = pactFn(PactTRotate)
    if fn == nil or gPactYou == nil:
      pactNever("Rotate: no verified target or no player"); return
    # `ignoreClamp = false`: the game's own pitch clamp stays in force, so a
    # script cannot drive the head through the floor.
    if cPactVPUB(fn, gPactYou, c.a, c.b, 0'i32) == 1'i32:
      gPactAsked = gPactAsked + 1
    else: pactNever("Rotate: the thunk rejected the arguments (NaN or absurd)")
  of PvLookAt:
    let fnL = pactFn(PactTLookAtDir)
    let fnR = pactFn(PactTRotate)
    if fnL == nil or fnR == nil or gPactYou == nil:
      pactNever("LookAt: no verified target or no player"); return
    if not pactOk(gPactYou, cPactOffMoveCtx() + 8'i32):
      pactNever("LookAt: the player is not readable at MovementContext"); return
    let mc = cReadPtrAt(gPactYou, cPactOffMoveCtx())
    if not pactOk(mc, 0x400'i32):
      pactNever("LookAt: the MovementContext did not validate"); return
    var px = 0.0
    var py = 0.0
    var pz = 0.0
    if not pactPos(px, py, pz):
      pactNever("LookAt: get_Position refused (NaN or absurd)"); return
    if cPactLookAt(fnL, mc, c.a, c.b, c.c, px, py, pz, 0.0) != 1'i32:
      pactNever("LookAt: CalculateLookAtDirection returned an unusable " &
                "Vector2"); return
    if cPactVPUB(fnR, gPactYou, cPactLookX(), cPactLookY(), 0'i32) == 1'i32:
      gPactAsked = gPactAsked + 1
    else: pactNever("LookAt: Rotate rejected the computed delta")
  of PvJump:
    let fn = pactFn(PactTJump)
    if fn == nil or gPactYou == nil: pactNever("Jump: unavailable"); return
    if cPactVP(fn, gPactYou) == 1'i32: gPactAsked = gPactAsked + 1
    else: pactNever("Jump: the thunk refused")
  of PvPose:
    let fn = pactFn(PactTChangePose)
    if fn == nil or gPactYou == nil: pactNever("ChangePose: unavailable"); return
    if cPactVPF(fn, gPactYou, c.a) == 1'i32: gPactAsked = gPactAsked + 1
    else: pactNever("ChangePose: the thunk refused the delta")
  of PvProne:
    let fn = pactFn(PactTToggleProne)
    if fn == nil or gPactYou == nil: pactNever("ToggleProne: unavailable"); return
    if cPactVP(fn, gPactYou) == 1'i32: gPactAsked = gPactAsked + 1
    else: pactNever("ToggleProne: the thunk refused")
  of PvSprint:
    let fn = pactFn(PactTEnaSprint)
    let fnG = pactFn(PactTGetSprint)
    if fn == nil or gPactYou == nil: pactNever("EnableSprint: unavailable"); return
    if cPactVPB(fn, gPactYou, c.i) != 1'i32:
      pactNever("EnableSprint: the thunk refused"); return
    gPactAsked = gPactAsked + 1
    # THE READBACK, immediately: `get_IsSprintEnabled` is the game's own state,
    # not an echo of the write.
    if fnG != nil:
      let got = cPactBP(fnG, gPactYou)
      if got == c.i: gPactTook = gPactTook + 1
      elif got >= 0'i32: gPactNoEffect = gPactNoEffect + 1
  of PvLean:
    let fn = pactFn(PactTLean)
    if fn == nil or gPactYou == nil: pactNever("ToggleLean: unavailable"); return
    if cPactVPF(fn, gPactYou, c.a) == 1'i32: gPactAsked = gPactAsked + 1
    else: pactNever("ToggleLean: the thunk refused")
  of PvFire:
    let hc = pactHands()
    if hc == nil:
      pactNever("Fire: " & gPactLastRefusal); return
    let fn = pactFn(PactTSetTrigger)
    if fn == nil: pactNever("SetTriggerPressed did not verify"); return
    if cPactVPB(fn, hc, c.i) == 1'i32: gPactAsked = gPactAsked + 1
    else: pactNever("Fire: the thunk refused")
  of PvAim:
    let hc = pactHands()
    if hc == nil: pactNever("Aim: " & gPactLastRefusal); return
    let fn = pactFn(PactTSetAiming)
    let fnG = pactFn(PactTGetAiming)
    if fn == nil: pactNever("set_IsAiming did not verify"); return
    if cPactVPB(fn, hc, c.i) != 1'i32:
      pactNever("Aim: the thunk refused"); return
    gPactAsked = gPactAsked + 1
    if fnG != nil:
      let got = cPactBP(fnG, hc)
      if got == c.i: gPactTook = gPactTook + 1
      elif got >= 0'i32: gPactNoEffect = gPactNoEffect + 1
  of PvFireMode:
    let hc = pactHands()
    if hc == nil: pactNever("FireMode: " & gPactLastRefusal); return
    let fn = pactFn(PactTFireMode)
    if fn == nil: pactNever("ChangeFireMode did not verify"); return
    let r = cPactIPI(fn, hc, c.i)
    if r < 0'i32: pactNever("ChangeFireMode: could not ask")
    else:
      gPactAsked = gPactAsked + 1
      # The method returns bool: the game's own verdict on whether the weapon
      # accepted that mode.
      if r != 0'i32: gPactTook = gPactTook + 1
      else: gPactNoEffect = gPactNoEffect + 1
  of PvCommand:
    if gPactOwner == nil:
      pactNever("ECommand " & $c.i & ": the GamePlayerOwner has not been " &
                "captured yet. This is INCONCLUSIVE, not a refusal about the " &
                "build -- the capture detour on LateUpdate has fired " &
                $gPactOwnerFires & " times.")
      return
    if not pactOk(gPactOwner, 0x100'i32):
      pactNever("ECommand " & $c.i & ": the captured owner no longer validates")
      return
    if gPactOwnerAgrees != 1'i32:
      pactNever("ECommand " & $c.i & ": the captured owner's get_MyPlayer " &
                "does not name the player we validated; refusing rather than " &
                "driving an unknown receiver.")
      return
    let fnCan = pactFn(PactTCanTrans)
    let fnT = pactFn(PactTTranslate)
    if fnT == nil: pactNever("TranslateCommand did not verify"); return
    if fnCan != nil:
      let can = cPactIPI(fnCan, gPactOwner, c.i)
      if can == 0'i32:
        # The GAME said no. That is a real, falsifiable answer and it is
        # reported as such rather than as our own failure.
        pactNever("ECommand " & $c.i & ": the game's own " &
                  "CanTranslateCommand returned false -- it would not accept " &
                  "this command right now.")
        return
    let r = cPactIPI(fnT, gPactOwner, c.i)
    if r < 0'i32: pactNever("ECommand " & $c.i & ": could not ask")
    else:
      gPactAsked = gPactAsked + 1
      # ETranslateResult: 0 is this build's "did nothing" ordinal by position in
      # the enum. It is treated as NO EFFECT rather than success, which is the
      # conservative reading; a script that needs certainty about a reload
      # should follow the command with a Magazine.Count readback.
      if r != 0'i32: gPactTook = gPactTook + 1
      else: gPactNoEffect = gPactNoEffect + 1
  of PvMagCycle:
    if gMagStep != 0'i32:
      pactNever("magcycle: one is already running"); return
    magBegin()
  of PvWait:
    gPactWaitFrames = (if c.frames > 0'i32: c.frames else: 1'i32)
  else:
    pactNever("unknown verb " & $c.verb)

proc pactApplyHeld() =
  ## `Player::Move` is an INPUT and dies the moment it stops being asserted, so
  ## it is re-issued every frame for the requested duration. Nothing else here
  ## is re-asserted.
  if gPactHoldFrames <= 0'i32: return
  let fn = pactFn(PactTMove)
  if fn == nil or gPactYou == nil:
    gPactHoldFrames = 0'i32
    pactNever("Move: no verified target or no player")
    return
  if cPactVPU(fn, gPactYou, gPactHoldX, gPactHoldY) == 1'i32:
    gPactAsked = gPactAsked + 1
  gPactHoldFrames = gPactHoldFrames - 1'i32

proc pactCheckMoved() =
  ## THE MOVEMENT READBACK. Not "we called Move" -- metres of world position
  ## actually travelled since the mark, measured with the game's own
  ## `get_Position`. Below `PactMinMoveM` the change is indistinguishable from
  ## idle settle and is counted as NO EFFECT, because a threshold that counted
  ## noise would be a check that cannot fail.
  if not gPactMoveMark: return
  if (gPactTicks - gPactMarkAt) < PactSettleFrames: return
  gPactMoveMark = false
  var x = 0.0
  var y = 0.0
  var z = 0.0
  if not pactPos(x, y, z):
    # Could not look. THIRD OUTCOME: neither took nor no-effect.
    gPactLastRefusal = "movement readback INCONCLUSIVE: get_Position refused"
    return
  let dx = x - gPactMarkX
  let dy = y - gPactMarkY
  let dz = z - gPactMarkZ
  let d2 = dx * dx + dy * dy + dz * dz
  gPactLastMoveM = d2
  if d2 >= (PactMinMoveM * PactMinMoveM): gPactTook = gPactTook + 1
  else: gPactNoEffect = gPactNoEffect + 1

# ---------------------------------------------------------------------------
# The drain body -- ONE guard, the whole body inside it
# ---------------------------------------------------------------------------

proc pactTickBody(a: Il2CppPtr): Il2CppPtr {.
    exportc: "aowl_pact_tick_body", cdecl.} =
  # Rule 3: this is the only guarded region in the feature and NOTHING below
  # opens another. `rpDeployed()` is a CACHED verdict read, not an evaluation,
  # for exactly that reason.
  if not rpDeployed():
    # Not in a raid. Held input is dropped rather than carried across the
    # boundary, and the magazine machine is abandoned rather than resumed
    # against a world that no longer exists.
    gPactHoldFrames = 0'i32
    gPactMoveMark = false
    if gMagStep != 0'i32:
      magFail("the raid phase stopped reading DEPLOYED mid-cycle")
    return cast[Il2CppPtr](1)

  if not pactAcquireYou():
    gPactHoldFrames = 0'i32
    return cast[Il2CppPtr](1)

  # Corroborate the captured GamePlayerOwner ONCE, against the player we have
  # independently validated. A capture that names a different player is not
  # trusted, and the check CAN fail, which is the point.
  if gPactOwner != nil and gPactOwnerAgrees != 1'i32:
    let fn = pactFn(PactTMyPlayer)
    if fn != nil and pactOk(gPactOwner, 0x100'i32):
      let mine = cPactPP(fn, gPactOwner)
      if mine == gPactYou:
        gPactOwnerAgrees = 1'i32
        okLog "pact: the captured GamePlayerOwner's get_MyPlayer is " &
              "pointer-identical to GameWorld.MainPlayer. The ECommand " &
              "channel is CORROBORATED and available."
      else:
        gPactOwnerAgrees = 0'i32
        warn "pact: the captured GamePlayerOwner names a DIFFERENT player " &
             "than GameWorld.MainPlayer. Every ECommand is REFUSED. This is " &
             "the corroboration failing, not the detour."

  pactCheckMoved()
  pactApplyHeld()
  magTick()

  if gPactWaitFrames > 0'i32:
    gPactWaitFrames = gPactWaitFrames - 1'i32
    return cast[Il2CppPtr](1)
  # Rule 4: a hard cap on entries per frame, and the held/mag machines block
  # further dequeues so a script's steps cannot overlap into nonsense.
  if gPactHoldFrames > 0'i32 or gMagStep != 0'i32:
    return cast[Il2CppPtr](1)
  var n = 0
  while n < PactMaxPerTick and gPactQCount > 0:
    let c = gPactQ[gPactQHead]
    gPactQHead = (gPactQHead + 1) mod PactQueueCap
    gPactQCount = gPactQCount - 1
    pactExec(c)
    n = n + 1
    if gPactHoldFrames > 0'i32 or gMagStep != 0'i32 or gPactWaitFrames > 0'i32:
      break
  cast[Il2CppPtr](1)

proc pactDrainTick*() =
  ## Rides the existing `TarkovApplication::Update` drain. Installs no detour of
  ## its own (the only detour this feature owns is the LateUpdate capture).
  if not gPactOn: return
  if pactDisabled(): return
  gPactTicks = gPactTicks + 1
  if gPactIndicesOk < 0'i32:
    if not pactCheckIndices(): return
  elif gPactIndicesOk == 0'i32:
    return
  if gPactBindState != 2'i32:
    gPactBindTries = gPactBindTries + 1
    if cPactModuleReady() != 0'i32:
      # One resolve of one row is enough to settle whether the table matches
      # this build; every other row is verified individually at its own use.
      if pactFn(PactTMove) != nil:
        gPactBindState = 2'i32
        okLog "pact: armed. " & $cPactOkCount() & " of " &
              $cPactTargetCount() & " targets verified against the startup " &
              "snapshot, " & $cPactBadCount() & " rejected."
      elif cPactReason() == 5'i32 or cPactReason() == 7'i32:
        gPactBindState = 2'i32
        gPactWhy = readCString(cPactReasonText())
        warn "pact: REFUSED on this build -- " & gPactWhy &
             ". No actuation will be attempted."
    if gPactBindState != 2'i32 and gPactBindTries >= 600 and
       not gPactBindSaidWait:
      gPactBindSaidWait = true
      warn "pact: still UNBOUND after " & $gPactBindTries & " drain frames (" &
           $cPactWaitCount() & " resolves found no module). This is " &
           "INCONCLUSIVE, not failed: nothing has been verified and nothing " &
           "will be called. Last reason " & $cPactReason() & ": " &
           $cPactReasonText() &
           (if cPactReason() == 8'i32:
              " <- THIS ONE IS ACTIONABLE: it is a capacity problem in THIS " &
              "repo, not a client change."
            else: "")
    if gPactBindState != 2'i32: return
  # The capture detour is retried until it takes, not attempted once. The first
  # attempt can legitimately fail because `gReady`/`gDisableDrain` are not yet
  # in the state `attachDrain` requires, and giving up on that would be a
  # permanent refusal produced by a transient condition -- a fact about WHEN we
  # asked, latched as a fact about the build. `verbose` is true only on the
  # first attempt so the log says it once.
  if gPactOwnerSlot < 0 and gPactOwnerTries < 600'i64:
    gPactOwnerTries = gPactOwnerTries + 1
    discard pactBindOwnerAt(gPactOwnerTries == 1'i64)
    if gPactOwnerTries == 600'i64 and gPactOwnerSlot < 0:
      warn "pact: the GamePlayerOwner capture detour never attached after " &
           "600 drain frames. The ECommand channel (reload, weapon swap, " &
           "inventory) is UNAVAILABLE. Movement, look, fire, aim and the " &
           "magazine cycle are unaffected -- they do not use that receiver."
  if cPactTickGuarded(nil) == nil:
    gPactFaults = gPactFaults + 1
    if pactDisabled():
      warn "pact: SELF-DISABLED after " & $gPactFaults & " faults (budget " &
           $PactMaxFaults & "). Every actuation is refused for the rest of " &
           "this process. The fault budget is whole-file on purpose: a wrong " &
           "calling convention would not confine itself to one channel."

proc pactBind*() =
  ## Read the flag at boot. Nothing is verified and no detour is installed here;
  ## `pactDrainTick` does the work on the main thread, where GameAssembly.dll is
  ## mapped by construction.
  gPactOn = readBoolKey("playerActuation")
  if not gPactOn:
    return
  info "pact: playerActuation is ON. In-raid actuation of the LOCAL PLAYER " &
       "(walk/look/fire/aim/pose/lean, the ECommand channel, and the " &
       "magazine unload+load cycle). It binds on the main-thread drain and " &
       "does nothing at all outside a DEPLOYED raid."

proc pactStatus*(): string =
  ## Every leg separately falsifiable. THE COUNTER LINE a scripted run prints.
  ## Read it as: asked/took/noeffect/never are FOUR OUTCOMES, not two, and a run
  ## with asked=0 is INCONCLUSIVE -- it is not a pass and it is not a failure.
  if not gPactOn:
    return "pact OFF (flag playerActuation)"
  if pactDisabled():
    return "pact SELF-DISABLED after " & $gPactFaults & " faults"
  if gPactIndicesOk == 0'i32:
    return "pact REFUSED: target index/name mismatch"
  if gPactBindState != 2'i32:
    return "pact INCONCLUSIVE: not bound yet (" & $gPactBindTries &
           " drain frames, reason " & $cPactReasonText() & ")"
  result = "pact armed=" & $cPactOkCount() & "/" & $cPactTargetCount() &
    " rejected=" & $cPactBadCount() &
    " raid=" & (if rpDeployed(): "DEPLOYED" else: "no") &
    " player=" & (if gPactYou != nil: "ok" else: "none") &
    " owner=" & (if gPactOwner == nil: "not captured"
                 elif gPactOwnerAgrees == 1'i32: "corroborated"
                 else: "captured but NOT corroborated") &
    " | asked=" & $gPactAsked & " took=" & $gPactTook &
    " noeffect=" & $gPactNoEffect & " never=" & $gPactNeverIssued &
    " qdrop=" & $gPactQDropped &
    " | magcycles=" & $gMagCycles & " magok=" & $gMagOk &
    " magfail=" & $gMagFailed & " (" & gMagWhy & ")"
  if gPactLastRefusal.len > 0:
    result = result & " | last refusal: " & gPactLastRefusal
