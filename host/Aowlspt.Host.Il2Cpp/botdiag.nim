# botdiag.nim -- READ-ONLY GameWorld bot/player census. `include`d into
# `aowlhost.nim` (NOT a separate module) so it shares that file's guarded raw-read
# primitives (`cIsReadable`/`cReadPtrAt`/`cReadI32At`/`cWordAt`), `cRegsInt`,
# logging (`okLog`/`info`), `hexOf`, `attachDrain`, and the host-thread id --
# exactly the discipline the version brand and the Phase 1 settings probe use.
#
# It answers one debugging question during an offline raid: are AI bots actually
# spawned into the live `EFT.GameWorld` (registered + positioned) or truly
# absent? It NEVER writes game state, never renders, never affects gameplay. From
# a read-only kind=5 detour on `EFT.GameWorld::RegisterPlayer` (Unity thread,
# RCX = the live GameWorld, RDX = the IPlayer being registered) it logs the
# incoming player and, throttled, enumerates the whole registered list: total
# count, how many are you vs AI, and each AI's role / alive-state / position.
# Every hop is `cIsReadable`-guarded (a VirtualQuery, never a faulting deref);
# an unreadable hop is a skip + log, never a crash. Flag-gated `botDiag`,
# default-off. The offsets live in `abi/aowlspt_botdiag.h` and this log is their
# live validation. See the delivery note for the resolved offsets/RVAs.

# ---- offsets from abi/aowlspt_botdiag.h (single source of truth) ----
proc cBdOffAliveList(): int32 {.importc: "aowl_bd_off_gw_alivelist", nodecl.}
proc cBdOffRegPlayers(): int32 {.importc: "aowl_bd_off_gw_regplayers", nodecl.}
proc cBdOffMainPlayer(): int32 {.importc: "aowl_bd_off_gw_mainplayer", nodecl.}
proc cBdOffListItems(): int32 {.importc: "aowl_bd_off_list_items", nodecl.}
proc cBdOffListSize(): int32 {.importc: "aowl_bd_off_list_size", nodecl.}
proc cBdOffArrElems(): int32 {.importc: "aowl_bd_off_arr_elems", nodecl.}
proc cBdOffPlMoveCtx(): int32 {.importc: "aowl_bd_off_pl_movectx", nodecl.}
proc cBdOffPlProfile(): int32 {.importc: "aowl_bd_off_pl_profile", nodecl.}
proc cBdOffPlAiData(): int32 {.importc: "aowl_bd_off_pl_aidata", nodecl.}
proc cBdOffPlIsYou(): int32 {.importc: "aowl_bd_off_pl_isyou", nodecl.}
proc cBdOffMcPrevPos(): int32 {.importc: "aowl_bd_off_mc_prevpos", nodecl.}
proc cBdOffProfInfo(): int32 {.importc: "aowl_bd_off_prof_info", nodecl.}
proc cBdOffInfoNickname(): int32 {.importc: "aowl_bd_off_info_nickname", nodecl.}
proc cBdOffInfoSide(): int32 {.importc: "aowl_bd_off_info_side", nodecl.}
proc cBdOffInfoSettings(): int32 {.importc: "aowl_bd_off_info_settings", nodecl.}
proc cBdOffSetRole(): int32 {.importc: "aowl_bd_off_set_role", nodecl.}

# ---- target accessors from abi/aowlspt_botdiag.h ----
proc cBotDiagTargetAt(i: int32): Il2CppPtr {.importc: "aowl_botdiag_target_at", nodecl.}
proc cBotDiagTargetName(i: int32): Il2CppPtr {.importc: "aowl_botdiag_target_name", nodecl.}
proc cBotDiagTargetCount(): int32 {.importc: "aowl_botdiag_target_count", nodecl.}

# Read a single `float32` at a pointer (low 32 bits), as a float. Backed by the
# shim's `aowl_read_f32`. Used only for the Vector3 position components.
proc cReadF32At(p: Il2CppPtr): float64 {.importc: "aowl_read_f32", nodecl.}

# The slot/flag/counter globals (gBotDiagSlot / gBotDiag / gBotDiagFires) are
# declared in aowlhost.nim beside the other detour slots.

## Cap the players read per enumerate so a corrupt `_size` cannot spin the walk.
const cBdMaxPlayers = 64
## Cap the nickname length decoded from a String.
const cBdMaxNick = 64

proc bdPtrAdd(p: Il2CppPtr; off: int32): Il2CppPtr =
  ## `p + off` as an Il2CppPtr, for reading a scalar field at an offset with
  ## `cReadI32At`/`cReadF32At` (which read at the pointer they are given).
  cast[Il2CppPtr](cast[uint64](p) + uint64(off))

proc bdSanePtr(p: Il2CppPtr): bool =
  ## Cheap plausibility gate: a real IL2CPP object pointer lives in canonical
  ## user-space, well above the null page and below the non-canonical hole. A
  ## mapped-but-garbage field can still point somewhere absurd (a small integer
  ## mistaken for a pointer, a kernel address); this rejects those BEFORE the
  ## VirtualQuery so we never even probe a nonsense address. Not proof of
  ## validity -- the SEH guard around the whole body is that -- just a first cull.
  let v = cast[uint64](p)
  result = v >= 0x10000'u64 and v < 0x00007FFFFFFFFFFF'u64

proc bdOk(p: Il2CppPtr; size: int32): bool =
  ## One gate for every pointer hop: non-null, in a plausible user-space range,
  ## AND page-readable for `size` bytes (VirtualQuery, never a faulting deref).
  ## Even so, a valid-looking pointer to an invalid NEXT pointer can still fault
  ## on the following hop's deref -- that residual risk is why the entire botdiag
  ## body runs under the VEH/SEH guard (`aowl_botdiag_body_guarded`).
  result = p != nil and bdSanePtr(p) and cIsReadableC(p, size) != 0'i32

proc bdReadString(p: Il2CppPtr): string =
  ## Decode a `System.String` at `p` by its FIXED IL2CPP layout (length int32 at
  ## +0x10, UTF-16 chars inline at +0x14), no reflection. Every read guarded, so
  ## a non-String slot yields "". BMP only; non-ASCII becomes '?'.
  result = ""
  if not bdOk(p, 0x14'i32):
    return
  let n = cReadI32At(bdPtrAdd(p, 0x10'i32))
  if n <= 0'i32 or n > int32(cBdMaxNick):
    return
  let chars = bdPtrAdd(p, 0x14'i32)
  if cIsReadableC(chars, n * 2'i32) == 0'i32:
    return
  for i in 0 ..< int(n):
    let c = cWordAt(chars, uint64(i))
    if c == 0'u16:
      break
    if c >= 0x20'u16 and c <= 0x7E'u16:
      result.add char(c)
    else:
      result.add '?'

proc bdSideName(side: int32): string =
  ## EPlayerSide is a small stable enum; name the well-known values, else number.
  case side
  of 0: "None"
  of 1: "Usec"
  of 2: "Bear"
  of 4: "Savage"
  else: "side" & $int(side)

proc bdReadNickname(player: Il2CppPtr): string =
  ## player.Profile(+0x9C0) -> Info(+0x48) -> Nickname(+0x10) String. Guarded.
  if not bdOk(player, cBdOffPlProfile() + 8'i32):
    return ""
  let profile = cReadPtrAt(player, cBdOffPlProfile())
  if not bdOk(profile, cBdOffProfInfo() + 8'i32):
    return ""
  let info = cReadPtrAt(profile, cBdOffProfInfo())
  if not bdOk(info, cBdOffInfoNickname() + 8'i32):
    return ""
  result = bdReadString(cReadPtrAt(info, cBdOffInfoNickname()))

proc bdReadSideRole(player: Il2CppPtr; side, role: var int32) =
  ## player.Profile -> Info -> Side(+0x48 int32) and Info -> Settings(+0x78) ->
  ## Role(+0x10 int32). Leaves the out params at a sentinel if unreadable.
  side = -1'i32
  role = -1'i32
  if not bdOk(player, cBdOffPlProfile() + 8'i32):
    return
  let profile = cReadPtrAt(player, cBdOffPlProfile())
  if not bdOk(profile, cBdOffProfInfo() + 8'i32):
    return
  let info = cReadPtrAt(profile, cBdOffProfInfo())
  if not bdOk(info, cBdOffInfoSettings() + 8'i32):
    return
  if cIsReadableC(bdPtrAdd(info, cBdOffInfoSide()), 4'i32) != 0'i32:
    side = cReadI32At(bdPtrAdd(info, cBdOffInfoSide()))
  let settings = cReadPtrAt(info, cBdOffInfoSettings())
  if settings != nil and bdSanePtr(settings) and
     cIsReadableC(bdPtrAdd(settings, cBdOffSetRole()), 4'i32) != 0'i32:
    role = cReadI32At(bdPtrAdd(settings, cBdOffSetRole()))

proc bdReadPos(player: Il2CppPtr; ok: var bool): string =
  ## player.MovementContext(+0x60) -> PreviousPosition(+0x370) Vector3, formatted
  ## "(x, y, z)". `ok` is false (and result "?") if any hop is unreadable.
  ok = false
  result = "?"
  if not bdOk(player, cBdOffPlMoveCtx() + 8'i32):
    return
  let mc = cReadPtrAt(player, cBdOffPlMoveCtx())
  if not bdSanePtr(mc) or mc == nil or
     cIsReadableC(bdPtrAdd(mc, cBdOffMcPrevPos()), 12'i32) == 0'i32:
    return
  let x = cReadF32At(bdPtrAdd(mc, cBdOffMcPrevPos()))
  let y = cReadF32At(bdPtrAdd(mc, cBdOffMcPrevPos() + 4'i32))
  let z = cReadF32At(bdPtrAdd(mc, cBdOffMcPrevPos() + 8'i32))
  ok = true
  result = "(" & formatFloat(x, ffDecimal, 2) & ", " &
                 formatFloat(y, ffDecimal, 2) & ", " &
                 formatFloat(z, ffDecimal, 2) & ")"

proc bdIsYou(player: Il2CppPtr): bool =
  ## player.IsYourPlayer (+0xB89 bool). False if unreadable.
  if not bdSanePtr(player) or player == nil or
     cIsReadableC(bdPtrAdd(player, cBdOffPlIsYou()), 1'i32) == 0'i32:
    return false
  result = (cReadI32At(bdPtrAdd(player, cBdOffPlIsYou())) and 0xFF'i32) != 0'i32

proc bdIsAI(player: Il2CppPtr): bool =
  ## player.AIData (+0xA00) non-null => AI-controlled. False if unreadable.
  if not bdOk(player, cBdOffPlAiData() + 8'i32):
    return false
  result = cReadPtrAt(player, cBdOffPlAiData()) != nil

proc bdCollectAlive(gw: Il2CppPtr): seq[uint64] =
  ## Snapshot the pointers in GameWorld.AllAlivePlayersList (+0x1C8), capped, so a
  ## registered player's alive-state is a membership test with no per-player call.
  result = @[]
  if not bdOk(gw, cBdOffAliveList() + 8'i32):
    return
  let lst = cReadPtrAt(gw, cBdOffAliveList())
  if not bdOk(lst, cBdOffListSize() + 4'i32):
    return
  let arr = cReadPtrAt(lst, cBdOffListItems())
  let size = cReadI32At(bdPtrAdd(lst, cBdOffListSize()))
  if not bdSanePtr(arr) or arr == nil or size <= 0'i32:
    return
  let n = (if size > int32(cBdMaxPlayers): int32(cBdMaxPlayers) else: size)
  for i in 0 ..< int(n):
    let slot = bdPtrAdd(arr, cBdOffArrElems() + int32(i) * 8'i32)
    if cIsReadableC(slot, 8'i32) == 0'i32:
      continue
    let pl = cReadPtrAt(slot, 0'i32)
    if pl != nil and bdSanePtr(pl):
      result.add cast[uint64](pl)

proc bdDescribePlayer(player: Il2CppPtr; alive: seq[uint64]): string =
  ## One-line description of a player: nickname, side, role, you/AI, alive, pos.
  ## Pure reads, all guarded.
  let nick = bdReadNickname(player)
  var side = 0'i32
  var role = 0'i32
  bdReadSideRole(player, side, role)
  var posOk = false
  let pos = bdReadPos(player, posOk)
  let you = bdIsYou(player)
  let ai = bdIsAI(player)
  var isAlive = false
  let key = cast[uint64](player)
  for k in alive:
    if k == key: isAlive = true
  result = "nick='" & nick & "' " & bdSideName(side) &
           " role=" & $int(role) &
           (if you: " YOU" elif ai: " AI" else: " (human?)") &
           " alive=" & (if isAlive: "true" else: "false") &
           " pos=" & pos

proc bdEnumerate(gw: Il2CppPtr; reason: string) =
  ## Walk GameWorld.RegisteredPlayers (+0x1D0) and log the full census: total,
  ## you vs AI, and each entry. Read-only, capped, every hop guarded.
  if not bdOk(gw, cBdOffRegPlayers() + 8'i32):
    okLog "botdiag: GameWorld=0x" & hexOf(cast[uint64](gw)) &
          " not readable for RegisteredPlayers -- skipping (" & reason & ")"
    return
  let lst = cReadPtrAt(gw, cBdOffRegPlayers())
  if not bdOk(lst, cBdOffListSize() + 4'i32):
    okLog "botdiag: RegisteredPlayers list null/unreadable (" & reason & ")"
    return
  let arr = cReadPtrAt(lst, cBdOffListItems())
  let size = cReadI32At(bdPtrAdd(lst, cBdOffListSize()))
  if not bdSanePtr(arr) or arr == nil or size <= 0'i32:
    okLog "botdiag: GameWorld has 0 registered players (size=" & $int(size) &
          ", " & reason & ") -- bots are ABSENT so far"
    return
  let alive = bdCollectAlive(gw)
  let n = (if size > int32(cBdMaxPlayers): int32(cBdMaxPlayers) else: size)
  var youCount = 0
  var aiCount = 0
  var shown = 0
  var lines: seq[string] = @[]
  for i in 0 ..< int(n):
    let slot = bdPtrAdd(arr, cBdOffArrElems() + int32(i) * 8'i32)
    if cIsReadableC(slot, 8'i32) == 0'i32:
      continue
    let pl = cReadPtrAt(slot, 0'i32)
    if pl == nil or not bdSanePtr(pl):
      continue
    if bdIsYou(pl):
      inc youCount
    elif bdIsAI(pl):
      inc aiCount
    lines.add "botdiag:   [" & $i & "] " & bdDescribePlayer(pl, alive)
    inc shown
  okLog "botdiag: GameWorld has " & $int(size) & " registered players -- " &
        $youCount & " you, " & $aiCount & " AI" &
        (if n < size: " (enumerate capped to " & $int(n) & ")" else: "") &
        " [" & reason & "]"
  for ln in lines:
    okLog ln
  okLog "botdiag: census done -- " & $shown & " entries logged, " &
        $alive.len & " in AllAlivePlayersList. Read-only, nothing written."

## When the one-shot full census may run: NOT on the first few registrations
## (the just-spawned player and the list itself can still be mid-construction --
## reading Profile/Info/Nickname off a half-built IPlayer is the prime raid-entry
## crash), but once enough have fired that the list has settled. Runs exactly
## once (guarded by `gBotDiagCensusDone`).
const cBdCensusAfter = 8

proc botDiagBodyImpl(a: Il2CppPtr): Il2CppPtr {.
    exportc: "aowl_botdiag_body", cdecl.} =
  ## The ENTIRE RegisterPlayer diagnostic body, run under the VEH/SEH guard
  ## (`aowl_botdiag_body_guarded`) so ANY fault inside -- including a guarded read
  ## of a valid-looking pointer to an INVALID next pointer, which `cIsReadable`
  ## cannot catch -- is trapped and the raid load survives. `a` is the detour
  ## `regs`. Returns a non-nil sentinel on clean completion; the C guard returns
  ## nil if it faulted, and the caller logs the catch. Writes nothing.
  ##
  ## Per-call work is deliberately MINIMAL: only the incoming player's single-hop
  ## AI/you flags plus running counts. The expensive whole-list walk (which reads
  ## every registered player's Profile chain, the fault-prone part) is a ONE-SHOT
  ## deferred until the list has settled -- never per-registration on the hot path.
  let regs = a
  let tid = int(cThreadId())
  let onHost = (tid == int(gHostThreadId))
  let gwRaw = cRegsInt(regs, 0'i32)          # RCX = GameWorld (this)
  let plRaw = cRegsInt(regs, 1'i32)          # RDX = IPlayer being registered
  inc gBotDiagFires
  if gBotDiagFires == 1:
    okLog "botdiag: first RegisterPlayer fired on thread " & $tid &
          " (host thread " & $int(gHostThreadId) & ")" &
          (if onHost: " -- host thread (unexpected)" else: " -- Unity thread")
  if onHost:
    return cast[Il2CppPtr](1)
  let gw = cast[Il2CppPtr](gwRaw)
  let incoming = cast[Il2CppPtr](plRaw)
  # Minimal per-call line: single-hop AI/you flags only. No Profile/Info/Nickname
  # or list enumeration here -- those are the reads that fault on a partially
  # constructed player during load, so they are kept off the per-registration path.
  if incoming != nil and bdSanePtr(incoming):
    let ai = bdIsAI(incoming)
    let you = bdIsYou(incoming)
    okLog "botdiag: RegisterPlayer #" & $gBotDiagFires & " incoming 0x" &
          hexOf(plRaw) &
          (if you: " YOU" elif ai: " AI" else: " (human?)")
  else:
    okLog "botdiag: RegisterPlayer #" & $gBotDiagFires & " incoming 0x" &
          hexOf(plRaw) & " not a sane pointer -- skipped"
  # The full census runs EXACTLY ONCE, after the list has had a few
  # registrations to stabilise -- never on the fragile first spawn, never per
  # call. Still shows how many bots are registered vs you, with roles/positions.
  if not gBotDiagCensusDone and gBotDiagFires >= cBdCensusAfter:
    gBotDiagCensusDone = true
    bdEnumerate(gw, "one-shot census at registration #" & $gBotDiagFires)
  return cast[Il2CppPtr](1)

# The VEH/SEH guard thunk. `aowl_p_p_seh` (abi/aowlspt_shim.h) arms a vectored
# exception handler + setjmp, calls the body, and returns nil instead of letting
# an access violation propagate -- the exact mechanism the settings-probe P2..P5
# steps use. A botdiag fault must NEVER reach the game, so the whole body goes
# through here.
{.emit: """
extern void* aowl_botdiag_body(void* a);
static void* aowl_botdiag_body_guarded(void* a) {
    return aowl_p_p_seh((void*)aowl_botdiag_body, a);
}
""".}
proc cBotDiagBodyGuarded(a: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_botdiag_body_guarded", nodecl.}

proc botDiagRegisterFired(regs: Il2CppPtr) =
  ## Fired from the read-only kind=5 detour on `EFT.GameWorld::RegisterPlayer`,
  ## on the Unity main thread. Runs the whole diagnostic body under the VEH/SEH
  ## guard: if anything inside faults, the guard traps it, we log the catch, and
  ## execution returns cleanly to the game so raid entry cannot be crashed by the
  ## diagnostic.
  # Hand the live GameWorld to the debug overlay before anything else. botdiag
  # and the overlay both want `RegisterPlayer`, and only one detour can own a
  # function -- so when botdiag has it, botdiag is the one that feeds the cache
  # and `bindDebugEspWorld` installs nothing. One register read, no walk, and it
  # happens whether or not the census body below faults.
  if int(cThreadId()) != int(gHostThreadId):
    let gwRaw = cRegsInt(regs, 0'i32)
    if gwRaw != 0'u64:
      duNoteGameWorld(cast[Il2CppPtr](gwRaw))
  if cBotDiagBodyGuarded(regs) == nil:
    okLog "botdiag: fault caught, skipped -- the VEH guard kept raid entry alive"

proc bindBotDiag(verbose: bool): bool =
  ## Installs the read-only kind=5 detour on `EFT.GameWorld::RegisterPlayer` from
  ## the verified static target in `aowlspt_botdiag.h`. Opt-in (`botDiag`); binds
  ## nothing on a build whose prologue does not match. GameWorld is raid-only, so
  ## the detour is installed now and simply never fires until a raid starts.
  if gBotDiagSlot >= 0:
    return true
  if not gReady or gDisableDrain:
    return false
  let count = cBotDiagTargetCount()
  for i in 0 ..< int(count):
    let fn = cBotDiagTargetAt(int32(i))
    if fn == nil:
      if verbose:
        info "botdiag target " & $i & " did not verify on this build"
      continue
    let spec = readCString(cBotDiagTargetName(int32(i)))
    if attachDrain(spec, fn, cast[Il2CppMethod](0), false, verbose, 5'i32):
      okLog "botdiag (read-only bot/player census) armed on " & spec &
            "; enter an offline raid to log each spawn + the registered list"
      return true
  result = false
