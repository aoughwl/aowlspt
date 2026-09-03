# botai.nim -- BOT AI ACTIVATION RESCUE. `include`d into `aowlhost.nim` (NOT a
# separate module) so it shares that file's guarded raw primitives, `cRegsInt`,
# logging (`okLog`/`info`), `hexOf`, `attachDrain`, the VEH/SEH guard and the
# host-thread id -- the exact discipline `botcap.nim` and the botdiag census use.
#
# It performs ONE Unity-thread bool field poke per bot that releases the gate
# keeping our offline scavs frozen at their spawn:
#
#   EFT.BotOwner::UpdateManual (0x81B7C0) only promotes a bot from
#   `_botState == 1` (PreActivated) to `_botState == 2` (Active, brain running)
#   when `BotOwner.WeaponManager.IsReady` is true:
#
#     +0x81C440  cmp dword [BotOwner+0x30], 1   ; PreActivated?
#     +0x81C44A  mov rax, [BotOwner+0x308]      ; WeaponManager
#     +0x81C45A  cmp byte [rax+0x80], 0 ; je    ; IsReady? no -> return
#     +0x81C65F  call BotOwner::Activate (0x818F50) -> `_botState = 2`
#
#   `IsReady` is only ever set by BotWeaponManager::UpdateFirearmsController,
#   reached only from BotWeaponSelector::OnWeaponTaken -- the completion callback
#   of the weapon change PreActivate starts with `TakeMainWeapon`. When that
#   change never completes the bot is pinned in state 1 forever: it stands still,
#   never thinks, and its hands still hold the default Scabbard (knife) while the
#   primary stays slung on its back. One gate, and it explains BOTH halves of the
#   symptom. The full RE, with byte-verified accessors, is in
#   `abi/aowlspt_botai.h`.
#
# From a kind=12 detour on `EFT.BotOwner::PreActivate` (once per bot, RCX = the
# BotOwner, Unity thread) this writes `[WeaponManager+0x80] = 1`. It does NOT call
# Activate, does NOT touch `_botState`, and does NOT suppress the original: the
# game's own UpdateManual still does its NavMesh check and its own Activate() on
# its own schedule. All this removes is the weapon-readiness veto. On a bot whose
# weapon change WOULD have completed the poke is a no-op in effect (OnWeaponTaken
# writes the same byte the same value a frame or two later).
#
# Flag-gated `botAiActivate`, default-off. Every hop is VirtualQuery-guarded and
# the whole body runs under the VEH/SEH guard, so a fault during bot activation
# can never reach the game.
#
# Self-verifying: the log line per bot carries the BotOwner pointer, the observed
# `_botState`, and IsReady BEFORE the write. If those lines never appear during a
# raid, `PreActivate` is not running for our bots at all and the break is upstream
# (BotCreatorClient::ActivationFaze, 0x1E0FDB0) -- which is exactly the other half
# of the question this answers.

# ---- offsets + target accessors from abi/aowlspt_botai.h (single source of truth) ----
proc cBaOffBotState(): int32 {.importc: "aowl_ba_off_botstate", nodecl.}
proc cBaOffWeaponMgr(): int32 {.importc: "aowl_ba_off_weaponmgr", nodecl.}
proc cBaOffIsReady(): int32 {.importc: "aowl_ba_off_isready", nodecl.}
proc cBotAiTargetAt(i: int32): Il2CppPtr {.importc: "aowl_botai_target_at", nodecl.}
proc cBotAiTargetName(i: int32): Il2CppPtr {.importc: "aowl_botai_target_name", nodecl.}
proc cBotAiTargetCount(): int32 {.importc: "aowl_botai_target_count", nodecl.}
proc cBaReadI32(p: Il2CppPtr; off: int32; ok: var int32): int32 {.
  importc: "aowl_botai_read_i32", nodecl.}
proc cBaReadPtr(p: Il2CppPtr; off: int32; ok: var int32): Il2CppPtr {.
  importc: "aowl_botai_read_ptr", nodecl.}
proc cBaReadU8(p: Il2CppPtr; off: int32; ok: var int32): int32 {.
  importc: "aowl_botai_read_u8", nodecl.}
proc cBaWriteU8(p: Il2CppPtr; off: int32; value: int32): int32 {.
  importc: "aowl_botai_write_u8", nodecl.}

# The slot/flag/counter globals (gBotAiSlot / gBotAi / gBotAiPokes / gBotAiFires)
# are declared in aowlhost.nim beside the other detour slots.

proc baSanePtr(p: Il2CppPtr): bool =
  ## Cheap plausibility gate before any probe: a real IL2CPP object pointer lives
  ## in canonical user-space, above the null page and below the non-canonical
  ## hole. Rejects a small integer or kernel address mistaken for the BotOwner.
  let v = cast[uint64](p)
  result = v >= 0x10000'u64 and v < 0x00007FFFFFFFFFFF'u64

proc botAiBodyImpl(a: Il2CppPtr): Il2CppPtr {.
    exportc: "aowl_botai_body", cdecl.} =
  ## The ENTIRE PreActivate field-poke body, run under the VEH/SEH guard
  ## (`aowl_botai_body_guarded`) so ANY fault -- including a guarded read of a
  ## valid-looking pointer whose slot is unmapped -- is trapped and bot activation
  ## survives. `a` is the detour `regs`. RCX = the live BotOwner. Returns a
  ## non-nil sentinel on clean completion; the C guard returns nil if it faulted.
  ## Writes exactly one byte (WeaponManager.IsReady -> 1), and only when
  ## everything checks out.
  let regs = a
  gBotAiFires = gBotAiFires + 1
  let tid = int(cThreadId())
  if tid == int(gHostThreadId):
    okLog "botai: PreActivate fired on the HOST thread (unexpected; not Unity's)" &
          " -- skipping the poke to stay safe"
    return cast[Il2CppPtr](1)
  let ownerRaw = cRegsInt(regs, 0'i32)          # RCX = BotOwner (this)
  let owner = cast[Il2CppPtr](ownerRaw)
  if not baSanePtr(owner):
    if gBotAiFires <= 8:
      okLog "botai: BotOwner=0x" & hexOf(ownerRaw) &
            " is not a sane pointer -- skipping (no write)"
    return cast[Il2CppPtr](1)

  # _botState BEFORE the original runs: 0 here on a healthy path (PreActivate
  # sets it to 1 on its way out). Read-only, purely for the log line.
  var okState = 0'i32
  let state = cBaReadI32(owner, cBaOffBotState(), okState)

  var okMgr = 0'i32
  let mgr = cBaReadPtr(owner, cBaOffWeaponMgr(), okMgr)
  if okMgr == 0'i32 or not baSanePtr(mgr):
    # BotOwner.WeaponManager is written by EFT.BotOwner::Create, which runs
    # before PreActivate -- so this should never happen. If it does, we say so
    # and touch nothing.
    if gBotAiFires <= 8:
      okLog "botai: BotOwner=0x" & hexOf(ownerRaw) & " has no readable " &
            "WeaponManager at +0x" & hexOf(uint64(cBaOffWeaponMgr())) &
            " -- skipping (no write)"
    return cast[Il2CppPtr](1)

  var okReady = 0'i32
  let before = cBaReadU8(mgr, cBaOffIsReady(), okReady)
  if okReady == 0'i32:
    if gBotAiFires <= 8:
      okLog "botai: WeaponManager+0x" & hexOf(uint64(cBaOffIsReady())) &
            " (IsReady) not readable -- skipping (no write)"
    return cast[Il2CppPtr](1)
  if before != 0'i32:
    # Already ready. Nothing to do; the game will activate this bot by itself.
    return cast[Il2CppPtr](1)

  # THE TYPED STORE (INTERACTION-LAYER-MAP M3/M6). `mgr` was read out of
  # `BotOwner.WeaponManager`, a field the metadata declares
  # `BotWeaponManager` -- so its type is a fact about the layout, not a guess
  # about the contents, which is what makes admitting its klass legitimate.
  # `baSanePtr` + VirtualQuery, the previous guards, cannot fail on the GC heap.
  discard frAdmit("botai", frBaIsReady(), mgr)
  if frStoreU8("botai", frBaIsReady(), mgr, 1'u8):
    gBotAiPokes = gBotAiPokes + 1
    if gBotAiPokes <= 12 or (gBotAiPokes mod 25) == 0:
      okLog "botai: BotOwner=0x" & hexOf(ownerRaw) & " state=" &
            (if okState != 0'i32: $int(state) else: "?") &
            " WeaponManager.IsReady false -> true (activation gate released; " &
            "poke #" & $gBotAiPokes & ")"
  else:
    if gBotAiFires <= 8:
      okLog "botai: WeaponManager.IsReady slot not safely writable -- left in " &
            "place (no write)"
  return cast[Il2CppPtr](1)

# The VEH/SEH guard thunk. `aowl_p_p_seh` (abi/aowlspt_shim.h) arms a vectored
# exception handler + setjmp, calls the body, and returns nil instead of letting
# an access violation propagate -- the exact mechanism botcap, botdiag and the
# settings probe use. A botai fault must NEVER reach the game.
{.emit: """
extern void* aowl_botai_body(void* a);
static void* aowl_botai_body_guarded(void* a) {
    return aowl_p_p_seh((void*)aowl_botai_body, a);
}
""".}
proc cBotAiBodyGuarded(a: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_botai_body_guarded", nodecl.}

proc botAiPreActivateFired(regs: Il2CppPtr) =
  ## Fired from the kind=12 detour on `EFT.BotOwner::PreActivate`, on the Unity
  ## main thread, once per bot. Runs the whole poke under the VEH/SEH guard: if
  ## anything faults, the guard traps it, we log the catch, and execution returns
  ## cleanly to the game so bot activation cannot be crashed by the rescue.
  if cBotAiBodyGuarded(regs) == nil:
    okLog "botai: fault caught, skipped -- the VEH guard kept bot activation alive"

proc bindBotAi(verbose: bool): bool =
  ## Installs the kind=12 detour on `EFT.BotOwner::PreActivate` from the verified
  ## static target in `aowlspt_botai.h`. Opt-in (`botAiActivate`); binds nothing
  ## on a build whose prologue does not match. BotOwners exist only inside a raid,
  ## so the detour is installed now and simply never fires until bots activate.
  if gBotAiSlot >= 0:
    return true
  if not gReady or gDisableDrain:
    return false
  let count = cBotAiTargetCount()
  for i in 0 ..< int(count):
    let fn = cBotAiTargetAt(int32(i))
    if fn == nil:
      if verbose:
        info "botai target " & $i & " did not verify on this build"
      continue
    let spec = readCString(cBotAiTargetName(int32(i)))
    if attachDrain(spec, fn, cast[Il2CppMethod](0), false, verbose, 12'i32):
      okLog "botai (bot AI activation rescue) armed on " & spec &
            "; enter an offline raid to release BotWeaponManager.IsReady per bot"
      return true
  result = false
