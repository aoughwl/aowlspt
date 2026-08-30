# natraid.nim -- NATIVE RAID ENTRY. No UI clicking at all.
#
# WHY THIS EXISTS
# ---------------
# `autoraid.nim` drives the main menu by FINDING and PRESSING GameObjects. It
# reaches the character/side-select screen and stalls there: that screen's
# control is not reliably pressable, and a press that returns success and does
# nothing is exactly the false positive this repo keeps paying for (fact #72).
#
# This feature never touches a GameObject. It calls the game's own commit path
# at byte-verified static RVAs, from the `TarkovApplication::Update` drain we
# already ride.
#
# THE ROUTE -- offline-measured, NOT re-derived here
# -------------------------------------------------
# Instrument: `tools/il2cpp_resolve.py` (type 7933 EFT.TarkovApplication, type
# 8022 EFT.MatchmakerOperation, `shared`, `bytes`, `enum`) and `tools/fldoff.py`
# (`fields EFT.RaidSettings`), whose System.String self-check
# (`_stringLength@0x10`, `_firstChar@0x14`) PASSED before any offset below was
# trusted.
#
#   EFT.TarkovApplication::get_CurrentRaidSettings  @0x691340  SHARED, 36 owners
#   EFT.TarkovApplication::get_MatchmakerOperation  @0x977360  UNIQUE
#   EFT.MatchmakerOperation::OnReadyPressed         @0xA312E0  UNIQUE
#
# `get_CurrentRaidSettings` is SHARED. This file CALLS it and DETOURS NOTHING,
# and a call at a shared RVA is correct code for the receiver you pass; the
# 36-owner blast radius is a property of PATCHING it, which never happens here.
#
#   EFT.RaidSettings         Side @0x20 (ESideType: Pmc=0 Savage=1 Random=2)
#                      LocationId @0x30 (string)
#                        RaidMode @0x44 (ERaidMode: Online=0 Local=1 Coop=2
#                                        Narrate=3)
#                    IsPveOffline @0xa0 (bool)
#               _selectedLocation @0xa8 (Location)
#   EFT.MatchmakerOperation
#                   _raidSettings @0x40   _offlineRaidSettings @0x48
#                   _readyPressed @0x60
#     <MatchmakerPlayersController>k__BackingField @0xa0
#
# THE OFFLINE GATE. `<OnReadyToStartMatchingAsync>d__195::MoveNext` @0x9CC7B0
# branches on `RaidSettings.RaidMode == 1` (Local) to LocalGameMatching; else it
# takes NetworkGameMatching, which is what produced the "One or more errors (A
# task was canceled)" aborts (facts #246/#263). So the gate is RaidMode, NOT
# `IsPveOffline`.
#
# TWO STAGES, TWO FLAGS
# ---------------------
#   `uxNativeRaid`      STAGE 1, read-only. Reports the seven prerequisites as
#                       PASS / FAIL / INCONCLUSIVE and writes nothing, calls
#                       nothing but two getters.
#   `uxNativeRaidDrive` STAGE 2. Requires STAGE 1's verdict to be PREREQS-PASS
#                       in the SAME session, then writes Side=Pmc(0) and
#                       RaidMode=Local(1) and calls `OnReadyPressed()`.
#
# The brief asked for one flag. This is two on purpose and it is strictly more
# conservative: the probe has to be independently runnable and independently
# useful (it answers the four open unknowns in ONE launch), and a probe that
# could only run by also arming the write is not a probe. Both DEFAULT OFF.
#
# SAFETY (CLAUDE.md section 5, every item)
#   * Every target is 16-byte prologue-verified inside `aowl_nr_fn` against the
#     STARTUP SNAPSHOT (`abi/aowlspt_prologue.h`), never against live memory --
#     so this can never verify another feature's trampoline and self-reject.
#   * VirtualQuery on EVERY hop, via `aowl_nr_read_*` / `nrOk`; the one write
#     goes through `aowl_nr_write_i32_checked`, which reads, compares, checks
#     the page is WRITABLE, writes and reads back.
#   * ONE `aowl_p_p_seh` around the whole tick body (`cNrTickGuarded`). It is
#     not re-entrant and nothing here opens a second one.
#   * No loops over game collections at all; the step machine is bounded by a
#     tick budget and a wall clock.
#   * Flag-gated, DEFAULT OFF; self-disables after `NrMaxFaults` faults and on
#     a step timeout, with a logged reason.
#   * No detour is installed: this rides the existing drain.
#   * No per-frame managed allocation -- it makes NO call into the game except
#     inside a rate-limited probe report or the one-shot drive.

{.emit: """
extern void* aowl_nr_tick_body(void* a);
static void* aowl_nr_tick_guarded(void* a) {
    return aowl_p_p_seh((void*)aowl_nr_tick_body, a);
}
""".}
proc cNrTickGuarded(a: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_nr_tick_guarded", nodecl.}

proc cNrFn(i: int32): Il2CppPtr {.importc: "aowl_nr_fn", nodecl.}
proc cNrName(i: int32): cstring {.importc: "aowl_nr_name", nodecl.}
proc cNrRva(i: int32): uint32 {.importc: "aowl_nr_rva", nodecl.}
proc cNrWhyOf(i: int32): int32 {.importc: "aowl_nr_why_of", nodecl.}
proc cNrWhyText(w: int32): cstring {.importc: "aowl_nr_why_text", nodecl.}
proc cNrTargetCount(): int32 {.importc: "aowl_nr_target_count", nodecl.}
proc cNrCallGetter(fn, self: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_nr_call_getter", nodecl.}
proc cNrCallVoid(fn, self: Il2CppPtr) {.importc: "aowl_nr_call_void", nodecl.}
proc cNrReadI32(base: Il2CppPtr; off: int32; outv: ptr int32): int32 {.
  importc: "aowl_nr_read_i32", nodecl.}
proc cNrReadU8(base: Il2CppPtr; off: int32; outv: ptr int32): int32 {.
  importc: "aowl_nr_read_u8", nodecl.}
proc cNrReadPtr(base: Il2CppPtr; off: int32): Il2CppPtr {.
  importc: "aowl_nr_read_ptr", nodecl.}
proc cNrWriteI32Checked(base: Il2CppPtr; off, v: int32): int32 {.
  importc: "aowl_nr_write_i32_checked", nodecl.}

# ---- target indices, in step with `abi/aowlspt_natraid.h` ----
const
  NrTGetRaidSettings = 0'i32
  NrTGetMatchmakerOp = 1'i32
  NrTOnReadyPressed  = 2'i32

# ---- field offsets (measured; see the header comment) ----
const
  NrRsSide          = 0x20'i32
  NrRsLocationId    = 0x30'i32
  NrRsRaidMode      = 0x44'i32
  NrRsIsPveOffline  = 0xa0'i32
  NrRsSelectedLoc   = 0xa8'i32
  NrMoRaidSettings  = 0x40'i32
  NrMoOfflineRs     = 0x48'i32
  NrMoReadyPressed  = 0x60'i32
  NrMoPlayersCtrl   = 0xa0'i32

const
  NrSidePmc      = 0'i32
  NrRaidModeLocal = 1'i32

# ---- bounds ----
const
  NrWarmupMs     = 8000'u64     ## nothing is up before this; make no call.
  NrTickFrames   = 60           ## ~1 s at 60 fps between probe attempts.
  NrReportMs     = 15000'u64    ## min gap between two IDENTICAL probe reports.
  NrMaxReports   = 16           ## bounded: never a report per second forever.
  NrProbeWindowMs = 300000'u64  ## after 5 min of probing, stop and say so.
  NrDriveSettleMs = 1500'u64    ## gap between the writes and OnReadyPressed.
  NrMaxFaults    = 3

# ---- step ids ----
const
  NrWait   = 0
  NrProbe  = 1
  NrArmed  = 2   ## prerequisites passed; STAGE 2 may write+press
  NrDone   = 3
  NrIdle   = 4   ## probe-only mode, prerequisites reported, nothing more to do
  NrFailed = 5

# ---- state ----
var gNrOn = false                  ## `uxNativeRaid`  -- STAGE 1. DEFAULT OFF.
var gNrDrive = false               ## `uxNativeRaidDrive` -- STAGE 2. DEFAULT OFF.
var gNrOff = false                 ## self-disabled
var gNrFaults = 0
var gNrStep = NrWait
var gNrT0 = 0'u64
var gNrFrames = 0
var gNrApp: Il2CppPtr = nil        ## the drain's RCX: the TarkovApplication
var gNrReports = 0
var gNrLastReportMs = 0'u64
var gNrLastSig = ""                ## report de-dup: only log when it CHANGED
var gNrArmedMs = 0'u64
var gNrPressed = false
var gNrBoundLogged = false

proc nrFail(why: string) =
  gNrOff = true
  gNrStep = NrFailed
  warn "nativeRaid: " & why & " -- switching itself off for this session and " &
       "touching nothing further. This is a REFUSAL, not a success."

proc nrHex(p: Il2CppPtr): string =
  if p == nil: "null" else: "0x" & hexOf(cast[uint64](p))

proc nrSideName(v: int32): string =
  case v
  of 0: "Pmc"
  of 1: "Savage"
  of 2: "Random"
  else: "OUT-OF-RANGE"

proc nrRaidModeName(v: int32): string =
  case v
  of 0: "Online"
  of 1: "Local"
  of 2: "Coop"
  of 3: "Narrate"
  else: "OUT-OF-RANGE"

proc nrReadStr(p: Il2CppPtr): string =
  ## A `System.String` by its FIXED runtime layout -- length int32 @+0x10,
  ## UTF-16 chars inline @+0x14 -- with NO reflection, every read
  ## VirtualQuery-guarded. A slot that is not a String yields "" rather than
  ## a plausible fabrication: the length is range-checked and any non-ASCII or
  ## embedded NUL aborts the decode.
  result = ""
  if p == nil or cIsReadable(p, 0x14'i32) == 0'i32:
    return
  let n = cReadI32At(cast[Il2CppPtr](cast[uint64](p) + 0x10'u64))
  if n <= 0'i32 or n > 64'i32:
    return
  let chars = cast[Il2CppPtr](cast[uint64](p) + 0x14'u64)
  if cIsReadable(chars, int32(n) * 2'i32) == 0'i32:
    return
  for i in 0 ..< int(n):
    let c = cWordAt(chars, uint64(i))
    if c == 0'u16 or c < 0x20'u16 or c > 0x7E'u16:
      return ""
    result.add char(c)

proc nrLogTargets() =
  ## State, ONCE, which targets verified and -- when one did not -- WHICH of the
  ## distinct reasons applies. "GameAssembly.dll is not loaded yet" and "the
  ## bytes do not match this build" must never read the same in the log.
  if gNrBoundLogged: return
  gNrBoundLogged = true
  var ok = 0
  for i in 0 ..< int(cNrTargetCount()):
    let fn = cNrFn(int32(i))
    let w = cNrWhyOf(int32(i))
    var tail = ""
    if fn != nil:
      inc ok
      tail = " VERIFIED (16-byte prologue vs the STARTUP SNAPSHOT) at " & nrHex(fn)
    else:
      tail = " REFUSED: " & $cNrWhyText(w)
    info "nativeRaid TARGET " & $cNrName(int32(i)) & " @0x" &
         hexOf(uint64(cNrRva(int32(i)))) & tail
  info "nativeRaid TARGETS " & $ok & " of " & $int(cNrTargetCount()) &
       " verified against the startup prologue snapshot"

# ---------------------------------------------------------------------------
# STAGE 1 -- THE PROBE. Read-only. Three outcomes per item, never two.
# ---------------------------------------------------------------------------
proc nrProbe(): bool =
  ## Logs the seven-item report and returns TRUE only when every prerequisite
  ## for STAGE 2 is satisfied. Returning false is NOT the same as a FAIL
  ## verdict: an unverified target or an unreadable pointer is INCONCLUSIVE and
  ## the report says so.
  result = false
  let app = gNrApp
  var appOk = app != nil and cIsReadable(app, 0x100'i32) != 0'i32

  let fnRs = cNrFn(NrTGetRaidSettings)
  let fnMo = cNrFn(NrTGetMatchmakerOp)

  var rs: Il2CppPtr = nil
  var mo: Il2CppPtr = nil
  if appOk and fnRs != nil: rs = cNrCallGetter(fnRs, app)
  if appOk and fnMo != nil: mo = cNrCallGetter(fnMo, app)
  if rs != nil and cIsReadable(rs, 0xb8'i32) == 0'i32: rs = nil
  if mo != nil and cIsReadable(mo, 0xb0'i32) == 0'i32: mo = nil

  var side = 0'i32
  var mode = 0'i32
  var pve = 0'i32
  var ready = 0'i32
  var sideOk = false
  var modeOk = false
  var pveOk = false
  var readyOk = false
  if rs != nil:
    sideOk = cNrReadI32(rs, NrRsSide, addr side) != 0'i32
    modeOk = cNrReadI32(rs, NrRsRaidMode, addr mode) != 0'i32
    pveOk  = cNrReadU8(rs, NrRsIsPveOffline, addr pve) != 0'i32
  var loc: Il2CppPtr = nil
  var locId = ""
  var ctrl: Il2CppPtr = nil
  var moRs: Il2CppPtr = nil
  var moOffRs: Il2CppPtr = nil
  if rs != nil:
    loc = cNrReadPtr(rs, NrRsSelectedLoc)
    locId = nrReadStr(cNrReadPtr(rs, NrRsLocationId))
  if mo != nil:
    ctrl = cNrReadPtr(mo, NrMoPlayersCtrl)
    moRs = cNrReadPtr(mo, NrMoRaidSettings)
    moOffRs = cNrReadPtr(mo, NrMoOfflineRs)
    readyOk = cNrReadU8(mo, NrMoReadyPressed, addr ready) != 0'i32

  # De-duplicate: the drain ticks forever and the interesting thing is a
  # CHANGE. The signature is every value the report prints.
  var sideTxt = "?"
  var modeTxt = "?"
  var readyTxt = "?"
  if sideOk: sideTxt = $side
  if modeOk: modeTxt = $mode
  if readyOk: readyTxt = $ready
  let sig = nrHex(app) & "|" & nrHex(rs) & "|" & nrHex(mo) & "|" & sideTxt &
            "|" & modeTxt & "|" & nrHex(loc) & "|" & locId & "|" &
            nrHex(ctrl) & "|" & readyTxt
  let now = cNowMs()
  let quiet = sig == gNrLastSig and now - gNrLastReportMs < NrReportMs

  let prereq = appOk and fnRs != nil and fnMo != nil and rs != nil and
               mo != nil and ctrl != nil and loc != nil and sideOk and modeOk
  result = prereq

  if quiet or gNrReports >= NrMaxReports:
    return
  gNrLastSig = sig
  gNrLastReportMs = now
  inc gNrReports

  info "nativeRaid PROBE #" & $gNrReports & " BEGIN (read-only; nothing was " &
       "written and nothing was pressed)"

  var s = ""
  # a) the instance
  if appOk:
    s = "PASS ptr=" & nrHex(app) &
        " (RCX of the TarkovApplication::Update drain we ride)"
  elif app == nil:
    s = "INCONCLUSIVE -- the drain has not handed us an instance yet"
  else:
    s = "FAIL -- the drain's RCX " & nrHex(app) & " is not readable"
  info "nativeRaid PROBE a) TarkovApplication instance: " & s

  # b) get_MatchmakerOperation
  if fnMo == nil:
    s = "INCONCLUSIVE -- the target did not verify: " &
        $cNrWhyText(cNrWhyOf(NrTGetMatchmakerOp))
  elif not appOk:
    s = "INCONCLUSIVE -- no usable TarkovApplication to call it on"
  elif mo == nil:
    s = "FAIL -- returned null or an unreadable pointer"
  else:
    s = "PASS ptr=" & nrHex(mo)
  info "nativeRaid PROBE b) get_MatchmakerOperation() -> MatchmakerOperation: " & s

  # c) get_CurrentRaidSettings
  if fnRs == nil:
    s = "INCONCLUSIVE -- the target did not verify: " &
        $cNrWhyText(cNrWhyOf(NrTGetRaidSettings))
  elif not appOk:
    s = "INCONCLUSIVE -- no usable TarkovApplication to call it on"
  elif rs == nil:
    s = "FAIL -- returned null or an unreadable pointer"
  else:
    s = "PASS ptr=" & nrHex(rs) &
        " (CALLED, never detoured -- that RVA is SHARED by 36 methods)"
  info "nativeRaid PROBE c) get_CurrentRaidSettings() -> RaidSettings: " & s

  # d) Side
  if rs == nil:
    s = "INCONCLUSIVE -- no RaidSettings"
  elif not sideOk:
    s = "INCONCLUSIVE -- the slot is not readable"
  elif side == NrSidePmc:
    s = "PASS value=0 (Pmc) -- already what STAGE 2 wants"
  else:
    s = "PASS value=" & $side & " (" & nrSideName(side) &
        ") -- STAGE 2 would write 0 (Pmc)"
  info "nativeRaid PROBE d) RaidSettings+0x20 Side: " & s

  # e) RaidMode -- THE OFFLINE GATE
  if rs == nil:
    s = "INCONCLUSIVE -- no RaidSettings"
  elif not modeOk:
    s = "INCONCLUSIVE -- the slot is not readable"
  elif mode == NrRaidModeLocal:
    s = "PASS value=1 (Local) -- ALREADY the offline gate; STAGE 2 would " &
        "write nothing here"
  else:
    s = "PASS value=" & $mode & " (" & nrRaidModeName(mode) &
        ") -- NOT Local(1); STAGE 2 would write 1 to keep the raid OFFLINE"
  info "nativeRaid PROBE e) RaidSettings+0x44 RaidMode: " & s

  # f) _selectedLocation
  if rs == nil:
    s = "INCONCLUSIVE -- no RaidSettings"
  elif loc == nil:
    s = "FAIL null -- no map is selected. This host will NOT construct a " &
        "Location; STAGE 2 refuses rather than guessing one into existence"
  else:
    s = "PASS ptr=" & nrHex(loc)
  info "nativeRaid PROBE f) RaidSettings+0xa8 _selectedLocation: " & s

  # f2) LocationId, the human-readable half of f)
  if rs == nil:
    s = "INCONCLUSIVE -- no RaidSettings"
  elif locId.len == 0:
    s = "INCONCLUSIVE -- null, empty, or not a plain ASCII System.String there"
  else:
    s = "PASS \"" & locId & "\""
  info "nativeRaid PROBE f2) RaidSettings+0x30 LocationId: " & s

  # g) MatchmakerPlayersController
  if mo == nil:
    s = "INCONCLUSIVE -- no MatchmakerOperation"
  elif ctrl == nil:
    s = "FAIL null -- Ready()'s state machine NREs on this"
  else:
    s = "PASS ptr=" & nrHex(ctrl)
  info "nativeRaid PROBE g) MatchmakerOperation+0xa0 " &
       "MatchmakerPlayersController: " & s

  # Extra evidence, cheap and load-bearing for the next session.
  if not pveOk:
    s = "INCONCLUSIVE"
  else:
    s = "PASS value=" & $pve &
        " (NOT the offline gate -- RaidMode is; recorded for comparison)"
  info "nativeRaid PROBE h) RaidSettings+0xa0 IsPveOffline: " & s

  if not readyOk:
    s = "INCONCLUSIVE"
  else:
    s = "PASS value=" & $ready
  info "nativeRaid PROBE i) MatchmakerOperation+0x60 _readyPressed: " & s

  if rs != nil and moRs == rs:
    s = "the operation uses THE SAME RaidSettings object"
  elif rs != nil and moOffRs == rs:
    s = "CurrentRaidSettings IS the operation's OFFLINE RaidSettings"
  else:
    s = "they are DIFFERENT objects; a write to CurrentRaidSettings may not " &
        "be the one Ready() reads"
  info "nativeRaid PROBE j) MatchmakerOperation._raidSettings@0x40=" &
       nrHex(moRs) & " _offlineRaidSettings@0x48=" & nrHex(moOffRs) &
       " vs CurrentRaidSettings=" & nrHex(rs) & " -- " & s

  if prereq:
    s = "PREREQS-PASS -- every prerequisite for a native READY is satisfied"
    if gNrDrive:
      s = s & " and uxNativeRaidDrive is ON, so STAGE 2 will arm"
    else:
      s = s & " (uxNativeRaidDrive is OFF, so nothing will be driven)"
  elif not appOk or fnRs == nil or fnMo == nil:
    s = "INCONCLUSIVE -- could not look (no instance, or a target that did " &
        "not verify); this is NOT a pass"
  else:
    s = "PREREQS-FAIL -- see the FAIL line(s) above"
  info "nativeRaid PROBE VERDICT: " & s
  info "nativeRaid PROBE #" & $gNrReports & " END"

# ---------------------------------------------------------------------------
# STAGE 2 -- DRIVE. One shot, then hands off forever.
# ---------------------------------------------------------------------------
proc nrWriteText(r: int32): string =
  ## The THREE outcomes of `aowl_nr_write_i32_checked`, named apart. "already
  ## correct" and "written and read back" are both successes but they are not
  ## the same observation, and a refusal must never read as either.
  case r
  of 2: "already correct, nothing written"
  of 1: "WRITTEN and read back"
  else: "REFUSED (unreadable, unwritable, or the store did not stick)"

proc nrDrive() =
  let app = gNrApp
  if app == nil or cIsReadable(app, 0x100'i32) == 0'i32:
    nrFail("STAGE 2: the TarkovApplication instance stopped being readable")
    return
  let fnRs = cNrFn(NrTGetRaidSettings)
  let fnMo = cNrFn(NrTGetMatchmakerOp)
  let fnRp = cNrFn(NrTOnReadyPressed)
  if fnRs == nil or fnMo == nil or fnRp == nil:
    nrFail("STAGE 2: a target that verified during the probe no longer " &
           "verifies (OnReadyPressed: " & $cNrWhyText(cNrWhyOf(NrTOnReadyPressed)) &
           ")")
    return
  let rs = cNrCallGetter(fnRs, app)
  let mo = cNrCallGetter(fnMo, app)
  if rs == nil or cIsReadable(rs, 0xb8'i32) == 0'i32 or
     mo == nil or cIsReadable(mo, 0xb0'i32) == 0'i32:
    nrFail("STAGE 2: RaidSettings or MatchmakerOperation went null between " &
           "the probe and the drive")
    return
  # RE-CHECK the prerequisites at the moment of writing, not only at the moment
  # of deciding. A check that ran a second ago is not a check.
  if cNrReadPtr(rs, NrRsSelectedLoc) == nil:
    nrFail("STAGE 2: RaidSettings._selectedLocation@0xa8 is null at the " &
           "moment of the write -- no map is selected and this host does not " &
           "construct a Location")
    return
  if cNrReadPtr(mo, NrMoPlayersCtrl) == nil:
    nrFail("STAGE 2: MatchmakerPlayersController@0xa0 is null at the moment " &
           "of the write -- Ready() would NRE")
    return

  let wSide = cNrWriteI32Checked(rs, NrRsSide, NrSidePmc)
  let wMode = cNrWriteI32Checked(rs, NrRsRaidMode, NrRaidModeLocal)
  info "nativeRaid DRIVE Side@0x20 -> 0 (Pmc): " & nrWriteText(wSide)
  info "nativeRaid DRIVE RaidMode@0x44 -> 1 (Local, the OFFLINE gate in " &
       "<OnReadyToStartMatchingAsync>d__195::MoveNext): " & nrWriteText(wMode)
  if wSide == 0'i32 or wMode == 0'i32:
    nrFail("STAGE 2: a required field write did not take; NOT pressing READY " &
           "-- calling OnReadyPressed with RaidMode still Online is what " &
           "produced the cancelled-task aborts")
    return

  # Assert the FINISHED STATE, not our own write: re-read both slots fresh.
  var back = 0'i32
  if cNrReadI32(rs, NrRsRaidMode, addr back) == 0'i32 or back != NrRaidModeLocal:
    nrFail("STAGE 2: RaidSettings.RaidMode does not read Local(1) after the " &
           "write (reads " & $back & ") -- refusing to press READY")
    return

  gNrPressed = true
  gNrStep = NrDone
  okLog "nativeRaid DRIVE calling EFT.MatchmakerOperation::OnReadyPressed() " &
        "@0xA312E0 on " & nrHex(mo) & " (instance, zero args, NULL MethodInfo* " &
        "-- not a shared generic). After this the feature is HANDS-OFF for the " &
        "rest of the session."
  cNrCallVoid(fnRp, mo)
  var rp = 0'i32
  if cNrReadU8(mo, NrMoReadyPressed, addr rp) != 0'i32:
    okLog "nativeRaid DRIVE read-back MatchmakerOperation._readyPressed@0x60=" &
          $rp & " -- 1 means the game's own handler ran. This is EVIDENCE the " &
          "call took, NOT proof a raid loads; only a live launch settles that."
  else:
    warn "nativeRaid DRIVE: OnReadyPressed returned but _readyPressed@0x60 " &
         "was not readable -- INCONCLUSIVE, not a failure."

# ---------------------------------------------------------------------------
proc nrTickBody(a: Il2CppPtr): Il2CppPtr {.exportc: "aowl_nr_tick_body", cdecl.} =
  ## Returns a non-nil sentinel on clean completion; the guard returns nil on a
  ## fault. At most ONE probe or ONE drive per call.
  result = cast[Il2CppPtr](1)
  discard a
  if gNrStep == NrDone or gNrStep == NrFailed or gNrStep == NrIdle: return
  nrLogTargets()
  let now = cNowMs()

  if gNrStep == NrWait or gNrStep == NrProbe:
    gNrStep = NrProbe
    let ready = nrProbe()
    if ready:
      if not gNrDrive:
        gNrStep = NrIdle
        okLog "nativeRaid: prerequisites are satisfied, but " &
              "`uxNativeRaidDrive` is OFF, so nothing was written and READY " &
              "was not pressed. Turn that flag on to arm STAGE 2."
        return
      gNrStep = NrArmed
      gNrArmedMs = now
      okLog "nativeRaid: prerequisites satisfied and uxNativeRaidDrive is ON " &
            "-- STAGE 2 arms in " & $int(NrDriveSettleMs) & " ms."
      return
    if now - gNrT0 > NrProbeWindowMs:
      nrFail("the prerequisites never all became satisfiable within " &
             $int(NrProbeWindowMs div 1000'u64) & " s of probing (read the " &
             "PROBE reports above: the last one names which item was FAIL or " &
             "INCONCLUSIVE)")
    return

  if gNrStep == NrArmed:
    if now - gNrArmedMs < NrDriveSettleMs: return
    nrDrive()
    return

proc nativeRaidDrainTick(regs: Il2CppPtr) =
  ## Rides the `EFT.TarkovApplication::Update` drain (slot alias, NO second
  ## detour -- a second detour on one function overwrites the first's
  ## trampoline). Cheap when idle: off, self-disabled, done, or inside the
  ## warm-up it is a handful of integer compares and makes NO call into the
  ## game.
  ##
  ## `regs` is the detour's saved argument block; RCX on this anchor is the
  ## `TarkovApplication` itself, which is exactly the receiver both getters
  ## need. That is the "existing machinery" for obtaining the instance -- the
  ## same register the live inspector reads on this anchor, and deliberately not
  ## a singleton walk.
  if not gNrOn or gNrOff: return
  if gNrStep == NrDone or gNrStep == NrFailed or gNrStep == NrIdle: return
  if gNrT0 == 0'u64: gNrT0 = cNowMs()
  if cNowMs() - gNrT0 < NrWarmupMs: return
  if regs != nil:
    let selfPtr = cRegsInt(regs, 0'i32)
    if selfPtr != 0'u64:
      gNrApp = cast[Il2CppPtr](selfPtr)
  inc gNrFrames
  if gNrFrames < NrTickFrames: return
  gNrFrames = 0
  if cNrTickGuarded(nil) == nil:
    inc gNrFaults
    warn "nativeRaid: the guarded tick body faulted (" & $gNrFaults & " of " &
         $NrMaxFaults & ")"
    if gNrFaults >= NrMaxFaults:
      nrFail("too many faults")
