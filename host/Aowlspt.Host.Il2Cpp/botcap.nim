# botcap.nim -- OFFLINE SCAV-CAP LIFT. `include`d into `aowlhost.nim` (NOT a
# separate module) so it shares that file's guarded raw primitives
# (`cIsReadable`/`cReadI32At`), `cRegsInt`, logging (`okLog`/`info`), `hexOf`,
# `attachDrain`, and the host-thread id -- the exact discipline the version-brand
# field write and the botdiag census use.
#
# It performs ONE Unity-thread int32 field poke that neutralises the offline bot
# cap: from a kind=6 detour on `EFT.BotSpawner::AddPlayer` (one-shot at raid init,
# RCX = the live BotSpawner) it writes `[BotSpawner+0xC0] = 0` (MaxBots=0 =
# UNLIMITED). CheckOnMax then never defers the scav wave pool, so the generated
# assault bots place. Flag-gated `unlimitedBots`, default-off. The offset/target
# live in `abi/aowlspt_botcap.h`. Every hop is guarded and the whole body runs
# under the VEH/SEH guard, so a fault during raid entry can never reach the game.
#
# Self-verifying (paired with botDiag=true): if scav RegisterPlayer counts climb
# past ~2 after the poke, MaxBots WAS the gate and this solves it; if they stay at
# ~2, the cap was not the bottleneck and the wave scheduler is the next target.

# ---- offset + target accessors from abi/aowlspt_botcap.h (single source of truth) ----
proc cBcOffMaxBots(): int32 {.importc: "aowl_bc_off_maxbots", nodecl.}
proc cBotCapTargetAt(i: int32): Il2CppPtr {.importc: "aowl_botcap_target_at", nodecl.}
proc cBotCapTargetName(i: int32): Il2CppPtr {.importc: "aowl_botcap_target_name", nodecl.}
proc cBotCapTargetCount(): int32 {.importc: "aowl_botcap_target_count", nodecl.}
proc cBcReadI32(p: Il2CppPtr; off: int32; ok: var int32): int32 {.
  importc: "aowl_botcap_read_i32", nodecl.}
proc cBcWriteI32(p: Il2CppPtr; off: int32; value: int32): int32 {.
  importc: "aowl_botcap_write_i32", nodecl.}

# The slot/flag/done globals (gBotCapSlot / gBotCap / gBotCapDone) are declared in
# aowlhost.nim beside the other detour slots.

proc bcSanePtr(p: Il2CppPtr): bool =
  ## Cheap plausibility gate before any probe: a real IL2CPP object pointer lives
  ## in canonical user-space, above the null page and below the non-canonical
  ## hole. Rejects a small integer or kernel address mistaken for the BotSpawner.
  let v = cast[uint64](p)
  result = v >= 0x10000'u64 and v < 0x00007FFFFFFFFFFF'u64

proc botCapBodyImpl(a: Il2CppPtr): Il2CppPtr {.
    exportc: "aowl_botcap_body", cdecl.} =
  ## The ENTIRE AddPlayer field-poke body, run under the VEH/SEH guard
  ## (`aowl_botcap_body_guarded`) so ANY fault -- including a guarded read/write of
  ## a valid-looking pointer whose slot is unmapped -- is trapped and raid entry
  ## survives. `a` is the detour `regs`. RCX = the live BotSpawner. Returns a
  ## non-nil sentinel on clean completion; the C guard returns nil if it faulted.
  ## Writes exactly one int32 (MaxBots -> 0) and only when everything checks out.
  let regs = a
  let tid = int(cThreadId())
  let onHost = (tid == int(gHostThreadId))
  # Fire the poke at most once: AddPlayer is one-shot per raid, but guard anyway.
  if gBotCapDone:
    return cast[Il2CppPtr](1)
  gBotCapDone = true
  if onHost:
    okLog "botcap: AddPlayer fired on the HOST thread (unexpected; not Unity's)" &
          " -- skipping the poke to stay safe"
    return cast[Il2CppPtr](1)
  let spRaw = cRegsInt(regs, 0'i32)          # RCX = BotSpawner (this)
  let sp = cast[Il2CppPtr](spRaw)
  if not bcSanePtr(sp):
    okLog "botcap: BotSpawner=0x" & hexOf(spRaw) &
          " is not a sane pointer -- skipping (no write)"
    return cast[Il2CppPtr](1)
  let off = cBcOffMaxBots()
  var ok = 0'i32
  let cur = cBcReadI32(sp, off, ok)
  if ok == 0'i32:
    okLog "botcap: BotSpawner+0x" & hexOf(uint64(off)) &
          " (MaxBots) not readable -- skipping (no write)"
    return cast[Il2CppPtr](1)
  if cur == 0'i32:
    okLog "botcap: BotSpawner.MaxBots already 0 (unlimited) -- nothing to do"
    return cast[Il2CppPtr](1)
  # THE TYPED STORE (INTERACTION-LAYER-MAP M3/M6). `bcSanePtr` is a canonical-
  # range test and `cBcReadI32` a VirtualQuery -- neither can fail on the
  # IL2CPP GC heap, so neither was ever a guard. `sp` is RCX of
  # `EFT.BotSpawner::AddPlayer`, so its type is a FACT, not a plausibility:
  # that is what makes admitting its klass here legitimate rather than
  # circular. Every later fire must present the SAME klass or be refused.
  discard frAdmit("botcap", frBcMaxBots(), sp)
  if frStoreI32("botcap", frBcMaxBots(), sp, 0'i32):
    okLog "botcap: BotSpawner.MaxBots was " & $int(cur) &
          ", set to 0 (unlimited) -- offline bot cap lifted"
  else:
    okLog "botcap: BotSpawner.MaxBots slot not safely writable (was " &
          $int(cur) & ") -- left in place (no write)"
  return cast[Il2CppPtr](1)

# The VEH/SEH guard thunk. `aowl_p_p_seh` (abi/aowlspt_shim.h) arms a vectored
# exception handler + setjmp, calls the body, and returns nil instead of letting
# an access violation propagate -- the exact mechanism botdiag and the settings
# probe use. A botcap fault must NEVER reach the game, so the whole body (the
# single field write included) goes through here.
{.emit: """
extern void* aowl_botcap_body(void* a);
static void* aowl_botcap_body_guarded(void* a) {
    return aowl_p_p_seh((void*)aowl_botcap_body, a);
}
""".}
proc cBotCapBodyGuarded(a: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_botcap_body_guarded", nodecl.}

proc botCapAddPlayerFired(regs: Il2CppPtr) =
  ## Fired from the kind=6 detour on `EFT.BotSpawner::AddPlayer`, on the Unity main
  ## thread at raid init. Runs the whole poke under the VEH/SEH guard: if anything
  ## faults, the guard traps it, we log the catch, and execution returns cleanly to
  ## the game so raid entry cannot be crashed by the cap lift.
  if cBotCapBodyGuarded(regs) == nil:
    okLog "botcap: fault caught, skipped -- the VEH guard kept raid entry alive"

proc bindBotCap(verbose: bool): bool =
  ## Installs the kind=6 detour on `EFT.BotSpawner::AddPlayer` from the verified
  ## static target in `aowlspt_botcap.h`. Opt-in (`unlimitedBots`); binds nothing
  ## on a build whose prologue does not match. BotSpawner exists only inside a
  ## raid, so the detour is installed now and simply never fires until an offline
  ## raid starts.
  if gBotCapSlot >= 0:
    return true
  if not gReady or gDisableDrain:
    return false
  let count = cBotCapTargetCount()
  for i in 0 ..< int(count):
    let fn = cBotCapTargetAt(int32(i))
    if fn == nil:
      if verbose:
        info "botcap target " & $i & " did not verify on this build"
      continue
    let spec = readCString(cBotCapTargetName(int32(i)))
    if attachDrain(spec, fn, cast[Il2CppMethod](0), false, verbose, 6'i32):
      okLog "botcap (offline bot-cap lift) armed on " & spec &
            "; enter an offline raid to poke BotSpawner.MaxBots=0 (unlimited)"
      return true
  result = false
