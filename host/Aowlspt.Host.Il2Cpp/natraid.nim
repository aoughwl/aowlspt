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
#   `uxNativeRaid`      STAGE 1, the PROBE. It is NOT read-only, and the log
#                       must never say it is. It writes no game field and
#                       presses no GameObject, but it CALLS into game code:
#                       `get_CurrentRaidSettings` (byte-verified pure) and, at
#                       most NrMaxLocTries times, a Location lookup. It reports
#                       the prerequisites as PASS / FAIL / INCONCLUSIVE.
#   `uxNativeRaidDrive` STAGE 2. Requires STAGE 1's verdict to be PREREQS-PASS
#                       in the SAME readiness generation, then writes Side=Pmc(0)
#                       and RaidMode=Local(1) INTO
#                       `MatchmakerOperation._raidSettings@0x40` and calls
#                       `OnReadyPressed()`.
#
# BOTH STAGES ARE GATED ON READINESS AND REFUSE, LOUDLY, IF IT NEVER ARRIVES.
# `get_MatchmakerOperation`@0x977360 is NEVER CALLED -- see the READINESS block
# further down for the disassembly and for the crash that rule exists for.
#
# PURITY OF EVERY CALL THIS FILE MAKES -- classified from the DISASSEMBLY
# (capstone over the `il2cpp` section), not from the fact that C# calls them
# properties. Measured 2026-08-30.
#
#   get_CurrentRaidSettings @0x691340  PURE READ. The entire body is
#       `48 8B 81 D8 00 00 00 C3` = `mov rax,[rcx+0xd8]; ret`, i.e.
#       `TarkovApplication._raidSettings`. SHARED by 36 methods -- irrelevant,
#       we call it and never patch it. SAFE AT ANY TIME. Still CALLED.
#   get_MatchmakerOperation @0x977360  CONSTRUCTS + ALLOCATES + DISPOSES.
#       UNIQUE. NEVER CALLED ANY MORE. See READINESS.
#   TryGetLocation          @0x2345770 PURE LOOKUP, NO managed allocation --
#       it makes no call to the object-new thunk 0x5D9E20 anywhere in its body;
#       its only writes are to the caller's out-parameter. Null-guards its
#       inputs, raises via 0x5D2530 only on paths we do not take. CALLED, capped.
#   set_SelectedLocation    @0x6D7FF0  WRITES, NO allocation, NO dispatch. Two
#       stores under the GC write barrier: `[this+0xa8]=value` then
#       `[this+0x30]=value.Id@0x28`. That barrier is exactly why we call it
#       instead of storing 0xa8 by hand. STAGE 2 ONLY.
#   TryGetLocationById      @0x987350  ALLOCATES. At 0x987401 it calls the
#       object-new thunk 0x5D9E20 and initialises `[rax+0x10]` -- a per-call
#       managed allocation (a lookup closure). It also NREs on `this+0x30`.
#       FALLBACK ONLY, gated on `this+0x30` non-null and capped at
#       NrMaxLocTries for the whole session, so it is never per-frame.
#   OnReadyPressed          @0xA312E0  THE COMMIT. Reads `[this+0x40]` (Side
#       @0x20, RaidMode@0x44) and tail-calls the Ready() state machine. STAGE 2
#       ONLY, once, behind PREREQS-PASS.
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
proc cNrTryGetLocation(fn, locSettings, idStr: Il2CppPtr;
                       outp: ptr Il2CppPtr): int32 {.
  importc: "aowl_nr_try_get_location", nodecl.}
proc cNrTryGetLocationById(fn, self, idStr: Il2CppPtr;
                           outp: ptr Il2CppPtr): int32 {.
  importc: "aowl_nr_try_get_location_by_id", nodecl.}
proc cNrSetSelectedLocation(fn, self, loc: Il2CppPtr) {.
  importc: "aowl_nr_set_selected_location", nodecl.}
proc cNrString(s: cstring): Il2CppPtr {.importc: "aowl_nr_string", nodecl.}
proc cNrStringExportOk(): int32 {.importc: "aowl_nr_string_export_ok", nodecl.}

# ---- target indices, in step with `abi/aowlspt_natraid.h` ----
const
  NrTGetRaidSettings = 0'i32
  NrTGetMatchmakerOp = 1'i32
  NrTOnReadyPressed  = 2'i32
  NrTTryGetLocation  = 3'i32
  NrTSetSelectedLoc  = 4'i32
  NrTTryGetLocById   = 5'i32

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
  NrMpcReadyDep     = 0x110'i32
    ## MEASURED 2026-08-31 by disassembling `EFT.<Ready>d__40::MoveNext`
    ## @0xA32E30 (capstone over the `il2cpp` section of GameAssembly.dll). The
    ## SECOND-level hop the handler makes and the host never checked:
    ##   00a33159  mov rax, [rdi+0xa0]      <- MatchmakerPlayersController
    ##   00a33160  test rax,rax / je 0xa33cde   -> NullReferenceException
    ##   00a33169  mov rax, [rax+0x110]
    ##   00a33173  test rax,rax / je 0xa33cd9   -> NullReferenceException
    ##   00a33179..00a33197  eight stores INTO that object
    ## `rdi` is `<>4__this` (statemachine+0x20) and is provably the
    ## MatchmakerOperation, because 0xa3300c/0xa33016 read and write
    ## `[rdi+0x60]` == `_readyPressed`. The host already null-checks +0xa0; it
    ## did NOT check +0x110, and 0xa33cd9 is inside the try whose catch logs
    ## "Error while starting matching: Object reference not set to an instance
    ## of an object." -- exactly the client error measured on the 17:20:40 run.
    ## The field NAME is NOT stated: 0x110 is inherited, and neither
    ## `fldoff.py fields` nor `Resolver.all_fields_ex` walks base types (both
    ## return only MatchmakerPlayersController's own 8 fields, first at 0x148).
    ## So this offset is used ONLY as a null/readability check, never
    ## interpreted, never written.
  # The location route. Every one of these came from
  # `il2cpp_resolve.py ... fields <Type>` -- none is guessed.
  NrRsLocSettings   = 0xb0'i32   ## RaidSettings._locationSettings (INITONLY)
  NrLsLocations     = 0x10'i32   ## JsonType.LocationSettings.locations
                                 ##   Dictionary<string,Location>. We NEVER read
                                 ##   INTO it -- the instantiated generic layout
                                 ##   is not reachable offline (every
                                 ##   Il2CppGenericClass.cached_class in the file
                                 ##   is null), so guessing `_entries` would be a
                                 ##   fabricated offset. It is only null-checked
                                 ##   and handed to the game's own lookup.
  NrLocUnderId      = 0x20'i32   ## Location._Id   -- the mongo id
  NrLocId           = 0x28'i32   ## Location.Id    -- "Woods"; the field
                                 ##   set_SelectedLocation copies into LocationId
  NrLocEnabled      = 0x30'i32   ## Location.Enabled (bool)

  # ---- THE READINESS ROUTE. Measured 2026-08-30 by disassembling
  # `EFT.TarkovApplication::get_MatchmakerOperation` @0x977360 (capstone over the
  # `il2cpp` section of GameAssembly.dll) and naming every offset it touches with
  # `tools/fldoff.py fields EFT.TarkovApplication` / `fields
  # EFT.MainMenuShowOperation`. See the READINESS block in the header comment.
  NrTaSession       = 0x30'i32   ## a base-class field the CONSTRUCT path
                                 ##   dereferences (interface dispatch) and NREs
                                 ##   on. Metadata gives no name for it -- it is
                                 ##   below TarkovApplication's own first field
                                 ##   (0xb8) -- so it is only ever NULL-CHECKED,
                                 ##   never interpreted.
  NrTaRaidSettings  = 0xd8'i32   ## TarkovApplication._raidSettings. This IS what
                                 ##   get_CurrentRaidSettings@0x691340 returns:
                                 ##   its whole body is
                                 ##   `48 8B 81 D8 00 00 00 C3`.
  NrTaLocalMmOp     = 0x100'i32  ## TarkovApplication._localMatchmakerOperation
  NrTaMenuOp        = 0x128'i32  ## TarkovApplication._menuOperation
                                 ##   (EFT.MainMenuShowOperation)
  NrMmsoMatchmaker  = 0x118'i32  ## MainMenuShowOperation
                                 ##   .<Matchmaker>k__BackingField

const
  NrSidePmc      = 0'i32
  NrRaidModeLocal = 1'i32
  ## Woods. The dictionary KEY (= Location._Id) and the Location.Id that the
  ## finished-state assert demands, both measured on the payload our own backend
  ## serves (mods/tarkov/data/post1/locations.json, via tools/bigjson.py).
  NrWoodsKey     = "5704e3c2d2720bac5b8b4567"
  NrWoodsId      = "Woods"
  ## the same two literals as `cstring`, for `il2cpp_string_new`. They are
  ## SEPARATE consts and not conversions because Nimony only converts a literal;
  ## keep the four in step -- the pair below is what actually reaches the game.
  NrWoodsKeyC    = cstring"5704e3c2d2720bac5b8b4567"
  NrWoodsIdC     = cstring"Woods"

# ---- bounds ----
const
  NrWarmupMs     = 8000'u64     ## nothing is up before this; make no call.
  NrTickFrames   = 6            ## ~100 ms at 60 fps between readiness checks.
    ## Was 60 (~1 s). MEASURED on the 2026-08-30 live run: the main menu was
    ## rebuilt at 0:00:46.234 ("hide seasons: the banner came back after a menu
    ## rebuild"), readiness read non-null at 0:00:46.469, and the drive landed at
    ## 0:00:48.953 -- so the whole window in which the player looked at a menu he
    ## never touches was 2.75 s, ALL of it ours: 1500 ms of NrDriveSettleMs plus
    ## ~984 ms of this divisor. Nothing before 46 s is menu time (the client is
    ## loading, and the one human-blocking screen is already auto-submitted 15 ms
    ## after it appears -- "skip mode screen: Submit called ... after 15ms").
    ## A tick that is not ready is a handful of integer compares and two guarded
    ## pointer reads and makes NO call, so 10 Hz costs nothing; the WAITING line
    ## is de-duped by reason, so it does not spam either.
  NrReportMs     = 15000'u64    ## min gap between two IDENTICAL probe reports.
  NrMaxReports   = 16           ## bounded: never a report per second forever.
  NrProbeWindowMs = 300000'u64  ## after 5 min of probing, stop and say so.
  NrDriveSettleMs = 250'u64     ## gap between the probe VERDICT and the drive.
    ## Was 1500 ms, and that number carried NO structural load: `nrDrive` does
    ## not trust the probe's verdict at all. It re-reads the matchmaker graph,
    ## re-reads MatchmakerOperation._raidSettings@0x40, re-checks
    ## _selectedLocation@0xa8 and MatchmakerPlayersController@0xa0, and asserts
    ## the FINISHED STATE of the offline gate object before it presses -- every
    ## one of those refuses rather than pressing. Waiting longer therefore buys
    ## no safety it does not already have; it only lengthens the menu the player
    ## stares at. 250 ms is kept (not 0) purely so the drive does not land on the
    ## same frame the menu is still rebuilding, and if the graph is swapped
    ## during it the generation check disarms and re-probes.
  NrMaxDriveAttempts = 5        ## capped: at most 5 presses, EVER, per session.
    ## The 250 ms settle above makes the drive land ~2.1 s earlier in boot than
    ## the old 1500 ms did, and that is a RACE, measured: two live runs of the
    ## SAME build, one pressed at 0:00:48.953 and read back
    ## `_readyPressed@0x60=1` (LocalGameMatching x4, raid loaded), the other
    ## pressed at 0:00:42.734 and read back 0 -- no LocalGameMatching, no
    ## geometry, the client sat at the menu. Every prerequisite, the write-backs
    ## and the offline-gate finished-state assert all PASSED on the failing run,
    ## so the predicate is not what is wrong: the game was simply not yet
    ## willing to run the handler. `_readyPressed == 0` after the call is
    ## therefore treated as "the press DID NOT TAKE", not as a curiosity, and
    ## the drive re-arms and RE-VALIDATES EVERYTHING from scratch instead of
    ## going hands-off. The fast path stays fast; the slow boot still gets in.
  NrRetryDelaysMs: array[NrMaxDriveAttempts, uint64] =
    [250'u64, 500'u64, 1000'u64, 1500'u64, 2000'u64]
    ## Growing back-off, indexed by (attempts already made - 1): a failed first
    ## press waits 250 ms, a failed second 500 ms, and so on. The last entry is
    ## never consumed, because attempt 5 gives up instead of re-arming. Worst
    ## case added menu time is 250 + 500 + 1000 + 1500 = 3.25 s before the loud
    ## give-up -- bounded and stated, not open-ended.
  NrMaxDefers    = 40           ## capped: at most 40 x 250 ms = 10 s of waiting
                                ## for the Ready() prerequisite chain to fill in
                                ## before the drive gives up LOUDLY. A deferral
                                ## presses NOTHING, so it cannot NRE the client.
  NrDeferMs      = 250'u64
  NrMaxFaults    = 3
  NrMaxLocTries  = 12           ## capped: never retry the lookup forever.

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
var gNrSettleMs = NrDriveSettleMs  ## the CURRENT arm's delay; grows per retry.
var gNrAttempts = 0                ## presses actually made this session, capped.
var gNrLastRp = -1                 ## last `_readyPressed@0x60` read-back, or -1.
var gNrPressed = false
var gNrDefers = 0                  ## presses REFUSED because a prerequisite the
                                   ## game's own handler dereferences was still
                                   ## null. Capped by NrMaxDefers; a deferral
                                   ## does NOT consume a press attempt.
var gNrBoundLogged = false
## The location resolve. `gNrLoc` is set ONLY by a resolve that both returned a
## Location and read back Id == "Woods"; it is never set from a guess, and there
## is no code path that writes a pointer here that was not proved.
var gNrLoc: Il2CppPtr = nil
var gNrLocVia = ""                 ## which route produced it, for the log
var gNrLocTries = 0
var gNrLocWhy = ""                 ## why the last attempt did not produce one
## Readiness. `gNrReadyGen` counts false->true TRANSITIONS of "the matchmaker
## graph exists"; the probe and the drive each run AT MOST ONCE per generation.
var gNrReadySince = 0'u64
var gNrReadyGen = 0
var gNrProbedGen = -1
var gNrDrivenGen = -1
var gNrLastReadyWhy = ""           ## de-dup for the WAITING line

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

proc nrSame(a, b: Il2CppPtr): string =
  ## Never print two pointers without saying whether they are the same object.
  ## Three outcomes, not two: a null on either side is INCONCLUSIVE, not
  ## "different".
  if a == nil or b == nil: "INCONCLUSIVE (one of them is null)"
  elif a == b: "SAME object"
  else: "DIFFERENT objects"

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

# ---------------------------------------------------------------------------
# READINESS. THE GATE THAT WAS MISSING, AND THE CRASH IT EXISTS FOR.
#
# On 2026-08-30 18:14 this feature KILLED the client 12 s after start with
#   NullReferenceException
#     EFT.InventoryLogic.OfflineInventoryController..ctor (IClientSession)
#     EFT.TarkovApplication.get_MatchmakerOperation ()
# (instrument: the client's own errors log,
#  D:/Aowlspt/Logs/log_2026.08.30_18-14-16_1.1.0.1.46777). No `nativeRaid PROBE`
# line was ever written, so it died inside the probe's FIRST call.
#
# `get_MatchmakerOperation` is NOT a getter. Disassembled (@0x977360) it is:
#
#   if (_menuOperation != null && _menuOperation.Matchmaker != null) {
#       if (_localMatchmakerOperation != null) <dispose>(_localMatchmakerOperation);
#       _localMatchmakerOperation = null;                    // + GC write barrier
#       return _menuOperation.Matchmaker;                    // 0x977479..0x977490
#   }
#   if (_localMatchmakerOperation != null) return it;        // 0x977495..0x977498
#   // 0x97749E onward -- THE CONSTRUCT PATH:
#   //   r8 = this+0x30 ; null => raise NRE (0x5D2530)
#   //   new OfflineHealthController / OfflineInventoryController(session...)
#   //   new MatchmakerOperation(..., this->_raidSettings@0xd8, ...)  @0x180A2D440
#   //   _localMatchmakerOperation = it                       // + GC write barrier
#
# The construct path allocates on the managed heap and NREs before the session
# graph is up. Earlier probe-only runs fired at 0:00:43.7 -- after the session
# existed -- so the IDENTICAL call returned a pointer and reported PASS. Safe
# late, fatal early: which is exactly why "it passed last time" is not evidence.
#
# So this host NEVER CALLS IT AGAIN. `nrMatchmaker` reproduces the two
# NON-constructing branches with plain VirtualQuery-guarded pointer reads. If
# neither branch holds, the object does not exist yet and we WAIT -- we do not
# ask the game to build it.
#
# The corroborating clue we under-weighted: probe step j) saw
# `_raidSettings@0x40` and `_offlineRaidSettings@0x48` as the same object on one
# run and different on another. That was the lazy graph being built at different
# times, not noise.
# ---------------------------------------------------------------------------
proc nrMatchmaker(app: Il2CppPtr; why: var string): Il2CppPtr =
  ## The MatchmakerOperation, or nil -- WITHOUT calling
  ## `get_MatchmakerOperation`. Mirrors that method's two non-constructing
  ## branches, in its own order, using guarded reads only. Never constructs,
  ## never allocates, never disposes, writes nothing.
  result = nil
  why = ""
  if app == nil or cIsReadable(app, 0x130'i32) == 0'i32:
    why = "no readable TarkovApplication instance"
    return
  let menuOp = cNrReadPtr(app, NrTaMenuOp)
  if menuOp != nil and cIsReadable(menuOp, 0x120'i32) != 0'i32:
    let mm = cNrReadPtr(menuOp, NrMmsoMatchmaker)
    if mm != nil and cIsReadable(mm, 0xb0'i32) != 0'i32:
      why = "_menuOperation@0x128=" & nrHex(menuOp) & " .Matchmaker@0x118"
      return mm
  let localMm = cNrReadPtr(app, NrTaLocalMmOp)
  if localMm != nil and cIsReadable(localMm, 0xb0'i32) != 0'i32:
    why = "_localMatchmakerOperation@0x100 (already built by the client)"
    return localMm
  why = "_menuOperation@0x128=" & nrHex(menuOp) &
        " has no .Matchmaker@0x118 yet and _localMatchmakerOperation@0x100=" &
        nrHex(localMm) & " -- the client has not built the matchmaker graph. " &
        "Calling get_MatchmakerOperation() here is what killed the client on " &
        "2026-08-30: it would CONSTRUCT the graph and NRE inside " &
        "OfflineInventoryController..ctor. WAITING instead."

proc nrSessionUp(app: Il2CppPtr): bool =
  ## The one dereference in the construct path we cannot otherwise account for.
  ## Not sufficient for readiness on its own and never used as such -- it is
  ## reported alongside `nrMatchmaker` so the log can distinguish "no session
  ## yet" from "session up, matchmaker not built yet".
  if app == nil or cIsReadable(app, 0x40'i32) == 0'i32: return false
  cNrReadPtr(app, NrTaSession) != nil

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
# THE LOCATION RESOLVE.
#
# It CALLS into the game (a dictionary lookup) rather than reading one, so it is
# not strictly read-only -- but it constructs nothing, stores nothing into any
# game object, and both entry points are pure lookups whose out-parameter is the
# only thing they write. Full reasoning, with the disassembly it rests on, is in
# the header comment of `abi/aowlspt_natraid.h`.
#
# It is idempotent and capped: once `gNrLoc` is set it never calls again, and it
# gives up after NrMaxLocTries attempts rather than probing forever.
# ---------------------------------------------------------------------------
proc nrLocAccept(loc: Il2CppPtr; via: string): bool =
  ## The FINISHED-STATE assert. A resolve returning *an* object proves nothing;
  ## comparing the result against the id we asked for would be a check that
  ## cannot fail. So: read the Location's OWN `Id`@0x28 back as a String and
  ## demand it says "Woods". Anything else -- unreadable, empty, a different
  ## map -- is a refusal, and the pointer is discarded.
  result = false
  if loc == nil: return
  if cIsReadable(loc, 0x48'i32) == 0'i32:
    gNrLocWhy = via & " returned " & nrHex(loc) & " but it is not readable"
    return
  let id = nrReadStr(cNrReadPtr(loc, NrLocId))
  if id.len == 0:
    gNrLocWhy = via & " returned " & nrHex(loc) &
                " but Location.Id@0x28 is null/empty/not a plain ASCII String"
    return
  if id != NrWoodsId:
    gNrLocWhy = via & " returned a Location whose Id@0x28 reads \"" & id &
                "\", not \"" & NrWoodsId & "\" -- DISCARDED"
    return
  gNrLoc = loc
  gNrLocVia = via
  gNrLocWhy = ""
  result = true

proc nrResolveWoods(rs: Il2CppPtr; app: Il2CppPtr) =
  ## Best-effort. Sets `gNrLoc` only on a fully verified hit; otherwise leaves
  ## it nil and puts the reason in `gNrLocWhy`.
  if gNrLoc != nil: return
  if gNrLocTries >= NrMaxLocTries:
    gNrLocWhy = "gave up after " & $NrMaxLocTries & " attempts"
    return
  inc gNrLocTries

  # ---- ROUTE A (primary): LocationLevelVariants::TryGetLocation, keyed by the
  # mongo id, with a LocationSettings WE validated. Every input is ours to
  # check and the callee null-guards all four of them anyway.
  let fnTgl = cNrFn(NrTTryGetLocation)
  var ls: Il2CppPtr = nil
  var dict: Il2CppPtr = nil
  if rs != nil:
    ls = cNrReadPtr(rs, NrRsLocSettings)
    if ls != nil and cIsReadable(ls, 0x20'i32) != 0'i32:
      dict = cNrReadPtr(ls, NrLsLocations)
      if dict != nil and cIsReadable(dict, 0x20'i32) == 0'i32:
        dict = nil
    else:
      ls = nil
  let keyStr = cNrString(NrWoodsKeyC)

  if fnTgl == nil:
    gNrLocWhy = "TryGetLocation did not verify: " &
                $cNrWhyText(cNrWhyOf(NrTTryGetLocation))
  elif ls == nil:
    gNrLocWhy = "RaidSettings._locationSettings@0xb0 is null or unreadable"
  elif dict == nil:
    gNrLocWhy = "LocationSettings.locations@0x10 is null or unreadable -- " &
                "/client/locations has not been consumed yet"
  elif keyStr == nil:
    gNrLocWhy = "il2cpp_string_new could not make the id string"
  else:
    var got: Il2CppPtr = nil
    if cNrTryGetLocation(fnTgl, ls, keyStr, addr got) != 0'i32:
      if nrLocAccept(got, "TryGetLocation(_locationSettings, \"" &
                          NrWoodsKey & "\")"):
        return
    else:
      gNrLocWhy = "TryGetLocation(_locationSettings, \"" & NrWoodsKey &
                  "\") returned false -- no such key in the served locations"

  # ---- ROUTE B (fallback): TarkovApplication::TryGetLocationById, keyed by
  # "Woods". Only attempted when `this+0x30` is non-null, because that is the
  # one dereference in its body we cannot otherwise account for (it is a
  # base-class field this build's metadata gives no offset for) and it NREs on
  # null rather than returning false.
  let fnById = cNrFn(NrTTryGetLocById)
  let idStr = cNrString(NrWoodsIdC)
  if fnById == nil or app == nil or idStr == nil: return
  if cIsReadable(app, 0x100'i32) == 0'i32: return
  if cNrReadPtr(app, 0x30'i32) == nil:
    gNrLocWhy = gNrLocWhy &
      "; the fallback TryGetLocationById was NOT attempted because " &
      "TarkovApplication+0x30 is null and it would NRE on it"
    return
  var got2: Il2CppPtr = nil
  if cNrTryGetLocationById(fnById, app, idStr, addr got2) != 0'i32:
    if nrLocAccept(got2, "TryGetLocationById(\"" & NrWoodsId & "\")"):
      return
  else:
    gNrLocWhy = gNrLocWhy &
      "; the fallback TryGetLocationById(\"" & NrWoodsId & "\") also " &
      "returned false"

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
  var moWhy = ""
  # `get_CurrentRaidSettings`@0x691340 is byte-verified to be the WHOLE of
  # `48 8B 81 D8 00 00 00 C3` -- `mov rax,[rcx+0xd8]; ret`. That is a pure read
  # of `_raidSettings@0xd8` and nothing else, so calling it is provably free of
  # side effects. `get_MatchmakerOperation` is NOT called at all any more; see
  # the READINESS block above.
  if appOk and fnRs != nil: rs = cNrCallGetter(fnRs, app)
  if appOk: mo = nrMatchmaker(app, moWhy)
  if rs != nil and cIsReadable(rs, 0xb8'i32) == 0'i32: rs = nil
  let sessionUp = nrSessionUp(app)

  var side = 0'i32
  var mode = 0'i32
  var pve = 0'i32
  var ready = 0'i32
  var sideOk = false
  var modeOk = false
  var pveOk = false
  var readyOk = false
  var loc: Il2CppPtr = nil
  var locId = ""
  var ctrl: Il2CppPtr = nil
  var moRs: Il2CppPtr = nil
  var moOffRs: Il2CppPtr = nil
  if mo != nil:
    ctrl = cNrReadPtr(mo, NrMoPlayersCtrl)
    moRs = cNrReadPtr(mo, NrMoRaidSettings)
    moOffRs = cNrReadPtr(mo, NrMoOfflineRs)
    readyOk = cNrReadU8(mo, NrMoReadyPressed, addr ready) != 0'i32
  if moRs != nil and cIsReadable(moRs, 0xb8'i32) == 0'i32: moRs = nil

  ## THE TARGET OBJECT. Every RaidSettings item below, and every STAGE 2 write,
  ## is about `MatchmakerOperation._raidSettings@0x40` -- the object
  ## `<Ready>d__40::MoveNext`@0xA32E30 actually reads (see j). We fall back to
  ## `get_CurrentRaidSettings()` ONLY so the probe still has something to report
  ## before the matchmaker exists; STAGE 2 refuses unless @0x40 is in hand.
  let tgt = (if moRs != nil: moRs else: rs)

  if tgt != nil:
    sideOk = cNrReadI32(tgt, NrRsSide, addr side) != 0'i32
    modeOk = cNrReadI32(tgt, NrRsRaidMode, addr mode) != 0'i32
    pveOk  = cNrReadU8(tgt, NrRsIsPveOffline, addr pve) != 0'i32
    loc = cNrReadPtr(tgt, NrRsSelectedLoc)
    locId = nrReadStr(cNrReadPtr(tgt, NrRsLocationId))

  # The location route. Read the two hops first (cheap, guarded), then attempt
  # the resolve -- at most NrMaxLocTries times for the whole session, and never
  # again once it has succeeded.
  var ls: Il2CppPtr = nil
  var dict: Il2CppPtr = nil
  if tgt != nil:
    ls = cNrReadPtr(tgt, NrRsLocSettings)
    if ls != nil and cIsReadable(ls, 0x20'i32) != 0'i32:
      dict = cNrReadPtr(ls, NrLsLocations)
    elif ls != nil:
      ls = nil
  if tgt != nil: nrResolveWoods(tgt, app)
  var woodsEnabled = -1'i32
  var woodsUnderId = ""
  if gNrLoc != nil:
    discard cNrReadU8(gNrLoc, NrLocEnabled, addr woodsEnabled)
    woodsUnderId = nrReadStr(cNrReadPtr(gNrLoc, NrLocUnderId))
  ## The location STAGE 2 would install: whatever is already selected, else the
  ## one we resolved and verified. Never anything else.
  let useLoc = (if loc != nil: loc else: gNrLoc)

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
            nrHex(ctrl) & "|" & readyTxt & "|" & nrHex(ls) & "|" &
            nrHex(dict) & "|" & nrHex(gNrLoc) & "|" & gNrLocWhy & "|" &
            (if sessionUp: "S1" else: "S0")
  let now = cNowMs()
  let quiet = sig == gNrLastSig and now - gNrLastReportMs < NrReportMs

  let fnSet = cNrFn(NrTSetSelectedLoc)
  ## PREREQS. `moRs != nil` is now REQUIRED, not `rs != nil`: STAGE 2 writes the
  ## object Ready() reads or it writes nothing at all.
  let prereq = appOk and fnRs != nil and mo != nil and moRs != nil and
               ctrl != nil and useLoc != nil and
               (loc != nil or fnSet != nil) and sideOk and modeOk
  result = prereq
  discard fnMo  ## verified for the record only; this host never CALLS it.

  if quiet or gNrReports >= NrMaxReports:
    return
  gNrLastSig = sig
  gNrLastReportMs = now
  inc gNrReports

  # ACCURACY. The old banner said "read-only; nothing was written and nothing
  # was pressed" and called the probe READ-ONLY. That was FALSE and it is the
  # exact class of confidently-wrong message CLAUDE.md sections 6 and 10 name.
  # The probe writes no game field and presses no GameObject, but it DOES call
  # into game code, and one of those calls used to construct an object graph and
  # killed the client. Say what it really does and what it really requires.
  info "nativeRaid PROBE #" & $gNrReports & " BEGIN. This probe WRITES NO GAME " &
       "FIELD and PRESSES NO GameObject, but it is NOT read-only: it CALLS " &
       "get_CurrentRaidSettings@0x691340 (byte-verified to be the whole of " &
       "`mov rax,[rcx+0xd8]; ret`, so a pure field read) and, at most " &
       $int(NrMaxLocTries) & " times per session, a Location LOOKUP. It " &
       "REQUIRES that the matchmaker graph ALREADY EXISTS -- it reads the " &
       "MatchmakerOperation out of the object graph and never calls " &
       "get_MatchmakerOperation@0x977360, which CONSTRUCTS it and NREs early."

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

  # a2) the session field the construct path NREs on
  if not appOk:
    s = "INCONCLUSIVE -- no usable TarkovApplication"
  elif sessionUp:
    s = "PASS non-null (the field get_MatchmakerOperation's CONSTRUCT path " &
        "dereferences; reported for diagnosis only, never as readiness)"
  else:
    s = "null -- the session graph is not up"
  info "nativeRaid PROBE a2) TarkovApplication+0x30 session: " & s

  # b) the MatchmakerOperation, obtained WITHOUT calling the constructing getter
  if not appOk:
    s = "INCONCLUSIVE -- no usable TarkovApplication to read from"
  elif mo == nil:
    s = "NOT-READY -- " & moWhy
  else:
    s = "PASS ptr=" & nrHex(mo) & " read from " & moWhy
  info "nativeRaid PROBE b) MatchmakerOperation (READ from the object graph; " &
       "get_MatchmakerOperation@0x977360 is NEVER called -- it CONSTRUCTS): " & s

  # c) get_CurrentRaidSettings
  if fnRs == nil:
    s = "INCONCLUSIVE -- the target did not verify: " &
        $cNrWhyText(cNrWhyOf(NrTGetRaidSettings))
  elif not appOk:
    s = "INCONCLUSIVE -- no usable TarkovApplication to call it on"
  elif tgt == nil:
    s = "FAIL -- returned null or an unreadable pointer"
  else:
    s = "PASS ptr=" & nrHex(rs) &
        " (CALLED, never detoured -- that RVA is SHARED by 36 methods)"
  info "nativeRaid PROBE c) get_CurrentRaidSettings() -> RaidSettings: " & s

  # d) Side
  if tgt == nil:
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
  if tgt == nil:
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
  if tgt == nil:
    s = "INCONCLUSIVE -- no RaidSettings"
  elif loc == nil:
    s = "null -- no map is selected by the UI. This host will NOT construct a " &
        "Location; it tries to RESOLVE one the client already built (see n), " &
        "and refuses if it cannot"
  else:
    s = "PASS ptr=" & nrHex(loc)
  info "nativeRaid PROBE f) RaidSettings+0xa8 _selectedLocation: " & s

  # f2) LocationId, the human-readable half of f)
  if tgt == nil:
    s = "INCONCLUSIVE -- no RaidSettings"
  elif locId.len == 0:
    s = "INCONCLUSIVE -- null, empty, or not a plain ASCII System.String there"
  else:
    s = "PASS \"" & locId & "\""
  info "nativeRaid PROBE f2) RaidSettings+0x30 LocationId: " & s

  # ---- the location route (k..n) -------------------------------------------
  # k) the registry the client built from /client/locations
  if tgt == nil:
    s = "INCONCLUSIVE -- no RaidSettings"
  elif ls == nil:
    s = "FAIL null or unreadable -- the RaidSettings was constructed without " &
        "one; there is nothing to look a map up in"
  else:
    s = "PASS ptr=" & nrHex(ls)
  info "nativeRaid PROBE k) RaidSettings+0xb0 _locationSettings: " & s

  # l) the dictionary itself. NEVER read into -- see the offset comment.
  if ls == nil:
    s = "INCONCLUSIVE -- no LocationSettings"
  elif dict == nil:
    s = "FAIL null -- /client/locations has not been deserialised into this " &
        "client yet"
  else:
    s = "PASS ptr=" & nrHex(dict) & " (Dictionary<string,Location>; this host " &
        "NEVER reads its internals -- the instantiated generic layout is not " &
        "reachable offline -- it only hands it to the game's own lookup)"
  info "nativeRaid PROBE l) LocationSettings+0x10 locations: " & s

  # m) the id string
  if cNrString(NrWoodsKeyC) == nil:
    if cNrStringExportOk() == 0'i32:
      s = "FAIL -- il2cpp_string_new could not be resolved from GameAssembly.dll"
    else:
      s = "FAIL -- il2cpp_string_new returned null for \"" & NrWoodsKey & "\""
  else:
    s = "PASS -- \"" & NrWoodsKey & "\" (Woods) interned once, then reused; " &
        "no per-frame managed allocation"
  info "nativeRaid PROBE m) il2cpp_string_new(Woods mongo id): " & s

  # n) the resolve, and the finished-state assert on it
  if gNrLoc != nil:
    s = "PASS ptr=" & nrHex(gNrLoc) & " via " & gNrLocVia &
        " -- VERIFIED by reading the Location's OWN Id@0x28 back as \"" &
        NrWoodsId & "\" (_Id@0x20=\"" & woodsUnderId & "\", Enabled@0x30=" &
        $woodsEnabled & ")"
  elif tgt == nil:
    s = "INCONCLUSIVE -- no RaidSettings to look it up from"
  elif gNrLocTries == 0:
    s = "INCONCLUSIVE -- not attempted yet"
  else:
    s = "FAIL after " & $gNrLocTries & " attempt(s): " & gNrLocWhy &
        " -- STAGE 2 will REFUSE rather than construct a Location or write a " &
        "guessed pointer"
  info "nativeRaid PROBE n) resolve WOODS Location: " & s

  # n2) what STAGE 2 would actually install
  if loc != nil:
    s = "the ALREADY-SELECTED Location " & nrHex(loc) &
        " -- STAGE 2 would leave _selectedLocation alone"
  elif gNrLoc != nil and fnSet != nil:
    s = "the resolved Woods Location " & nrHex(gNrLoc) &
        ", installed by CALLING RaidSettings::set_SelectedLocation@0x6D7FF0 " &
        "(UNIQUE), which also sets LocationId@0x30 from Id@0x28 under the GC " &
        "write barrier -- a raw store into 0xa8 would skip that barrier"
  elif gNrLoc != nil:
    s = "INCONCLUSIVE -- a Woods Location is in hand but " &
        "set_SelectedLocation did not verify: " &
        $cNrWhyText(cNrWhyOf(NrTSetSelectedLoc))
  else:
    s = "NOTHING -- no map is selected and none could be resolved; STAGE 2 " &
        "REFUSES"
  info "nativeRaid PROBE n2) _selectedLocation STAGE 2 would install: " & s

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

  # j) SETTLED 2026-08-30 by disassembling
  # `EFT.MatchmakerOperation::<Ready>d__40::MoveNext` @0xA32E30: the state
  # machine reads its `<>4__this` at +0x40 (`_raidSettings`) in eleven places --
  # `Side@0x20` at 0xA33336/0xA3361B/0xA33671, `RaidMode@0x44` at
  # 0xA33378/0xA33566/0xA335A3/0xA336D9 (and WRITES 1 there at 0xA336B1), and
  # `_selectedLocation@0xa8` at 0xA3333D/0xA3362D/0xA3366A. `+0x48`
  # (`_offlineRaidSettings`) is touched only at 0xA336E8/0xA33704, inside the
  # RaidMode==Online branch. `OnReadyPressed`@0xA312E0 likewise gates on
  # `[this+0x40]+0x20` and `[this+0x40]+0x44` (0xA31377..0xA31398).
  # So the object that matters is `MatchmakerOperation._raidSettings@0x40`, and
  # that -- NOT `get_CurrentRaidSettings()` -- is what STAGE 2 targets.
  if moRs == nil:
    s = "STAGE 2 would REFUSE: there is no object for Ready() to read"
  elif rs != nil and moRs == rs:
    s = "they are THE SAME object here, so the distinction does not bite " &
        "this run -- STAGE 2 still targets @0x40 explicitly"
  else:
    s = "they are DIFFERENT objects. STAGE 2 writes @0x40, the one Ready() " &
        "reads, and never CurrentRaidSettings"
  info "nativeRaid PROBE j) Ready() consumes MatchmakerOperation." &
       "_raidSettings@0x40=" & nrHex(moRs) & " (_offlineRaidSettings@0x48=" &
       nrHex(moOffRs) & " is only read in the RaidMode==Online branch; " &
       "TarkovApplication CurrentRaidSettings=" & nrHex(rs) & ") -- " & s

  # k) THE OFFLINE GATE. `<OnReadyToStartMatchingAsync>d__195::MoveNext`@0x9CC7B0
  # branches at 0x9CCB97 on `[[rbx+0xd8]+0x44] == 1`, and rbx is PROVED to be the
  # TarkovApplication by 0x9CCB81 `inc dword [rbx+0x1e4]`
  # (<CurrentTotalRaidNum>k__BackingField). Print all four references side by
  # side with their RaidMode, so ONE read-only run settles which object is which
  # instead of a rebuild per question. `forceOfflinePractice` is a UI-toggle
  # mechanism and does NOT apply to the native path, which bypasses the UI.
  let taRsP = cNrReadPtr(app, NrTaRaidSettings)
  var kMode = -1'i32
  discard cNrReadI32(taRsP, NrRsRaidMode, addr kMode)
  var kModeMo = -1'i32
  discard cNrReadI32(moRs, NrRsRaidMode, addr kModeMo)
  var kModeOff = -1'i32
  discard cNrReadI32(moOffRs, NrRsRaidMode, addr kModeOff)
  info "nativeRaid PROBE k) OFFLINE GATE @0x9CCB87 reads TarkovApplication." &
       "_raidSettings@0xd8=" & nrHex(taRsP) & " RaidMode=" & $kMode & "(" &
       nrRaidModeName(kMode) & "); get_CurrentRaidSettings()=" & nrHex(rs) &
       " [" & nrSame(taRsP, rs) & "]; MatchmakerOperation._raidSettings@0x40=" &
       nrHex(moRs) & " RaidMode=" & $kModeMo & " [vs gate: " &
       nrSame(taRsP, moRs) & "]; MatchmakerOperation._offlineRaidSettings@0x48=" &
       nrHex(moOffRs) & " RaidMode=" & $kModeOff & " [vs gate: " &
       nrSame(taRsP, moOffRs) & "]"

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

proc nrIsRaidSettings(p, refRs: Il2CppPtr; why: var string): bool =
  ## POSITIVE identification before ANY write, per CLAUDE.md rule 8. Three
  ## independent things must hold; a failure REFUSES with a reason and writes
  ## nothing. `refRs` is the object STAGE 2 has already written and read back
  ## `LocationId == "Woods"` from, so its `Il2CppClass*` at +0x0 is a KNOWN-GOOD
  ## RaidSettings klass -- comparing headers is a raw pointer compare and needs
  ## no reflection export (all of which are token-gated on this build).
  if p == nil:
    why = "it is null"
    return false
  if refRs == nil or cIsReadable(refRs, 0xb8'i32) == 0'i32:
    why = "there is no readable reference RaidSettings to compare a klass against"
    return false
  if cIsReadable(p, 0xb8'i32) == 0'i32:
    why = "it is not readable for 0xb8 bytes"
    return false
  let k = cNrReadPtr(p, 0'i32)
  let kr = cNrReadPtr(refRs, 0'i32)
  if k == nil or kr == nil:
    why = "the Il2CppClass* in the object header at +0x0 did not read"
    return false
  if k != kr:
    why = "its klass " & nrHex(k) & " differs from the known-good RaidSettings " &
          "klass " & nrHex(kr) & " -- this is NOT a RaidSettings"
    return false
  var v = 0'i32
  if cNrReadI32(p, NrRsSide, addr v) == 0'i32 or v < 0'i32 or v > 2'i32:
    why = "Side@0x20 reads " & $v & ", outside the 0..2 the enum allows"
    return false
  if cNrReadI32(p, NrRsRaidMode, addr v) == 0'i32 or v < 0'i32 or v > 3'i32:
    why = "RaidMode@0x44 reads " & $v & ", outside the 0..3 the enum allows"
    return false
  why = "klass " & nrHex(k) & " matches, Side and RaidMode both in range"
  true

proc nrApplyOffline(p, refRs, app: Il2CppPtr; label: string) =
  ## Install Pmc(0) / Local(1) / the resolved Woods Location into ONE FURTHER
  ## RaidSettings object. Not fatal: the primary object is already written and
  ## verified, so a refusal here is logged and the caller's own finished-state
  ## assert decides whether READY may be pressed.
  var why = ""
  if not nrIsRaidSettings(p, refRs, why):
    warn "nativeRaid DRIVE GATE: REFUSING to write " & label & "=" & nrHex(p) &
         " -- " & why & ". Nothing was written to it."
    return
  if cNrReadPtr(p, NrRsSelectedLoc) == nil:
    # The primary object may already have had a selection, in which case
    # `gNrLoc` was never resolved. Resolve from THIS object's own
    # `_locationSettings@0xb0`; the resolve sets `gNrLoc` only after reading
    # back Id == "Woods", and is a no-op if one is already in hand.
    if gNrLoc == nil:
      nrResolveWoods(p, app)
    let fnSet = cNrFn(NrTSetSelectedLoc)
    if gNrLoc == nil or fnSet == nil:
      warn "nativeRaid DRIVE GATE " & label & "=" & nrHex(p) &
           " has _selectedLocation@0xa8 null and no verified " &
           "set_SelectedLocation route to fill it -- leaving 0xa8 alone rather " &
           "than storing a pointer by hand"
    else:
      # Through the SETTER, never a raw store: 0xa8 is a managed reference and
      # the setter also writes LocationId@0x30 under the GC write barrier.
      cNrSetSelectedLocation(fnSet, p, gNrLoc)
  let wSide = cNrWriteI32Checked(p, NrRsSide, NrSidePmc)
  let wMode = cNrWriteI32Checked(p, NrRsRaidMode, NrRaidModeLocal)
  # Assert the FINISHED STATE of the object, re-read fresh -- not our own write.
  var back = -1'i32
  discard cNrReadI32(p, NrRsRaidMode, addr back)
  let bid = nrReadStr(cNrReadPtr(p, NrRsLocationId))
  okLog "nativeRaid DRIVE GATE " & label & "=" & nrHex(p) & " IDENTIFIED (" &
        why & "): Side@0x20 " & nrWriteText(wSide) & "; RaidMode@0x44 " &
        nrWriteText(wMode) & " -- READ BACK RaidMode@0x44=" & $back & " (" &
        nrRaidModeName(back) & "), _selectedLocation@0xa8=" &
        nrHex(cNrReadPtr(p, NrRsSelectedLoc)) & ", LocationId@0x30=\"" & bid &
        "\" -- read from the live object"

proc nrDrive() =
  let app = gNrApp
  if app == nil or cIsReadable(app, 0x100'i32) == 0'i32:
    nrFail("STAGE 2: the TarkovApplication instance stopped being readable")
    return
  let fnRp = cNrFn(NrTOnReadyPressed)
  if fnRp == nil:
    nrFail("STAGE 2: a target that verified during the probe no longer " &
           "verifies (OnReadyPressed: " & $cNrWhyText(cNrWhyOf(NrTOnReadyPressed)) &
           ")")
    return
  ## Re-establish READINESS at the moment of writing -- by READING the graph,
  ## never by calling `get_MatchmakerOperation`, which constructs.
  var moWhy = ""
  let mo = nrMatchmaker(app, moWhy)
  if mo == nil:
    nrFail("STAGE 2: the matchmaker graph is no longer readable (" & moWhy & ")")
    return
  ## THE OBJECT `Ready()` READS. Settled by disassembling
  ## `<Ready>d__40::MoveNext`@0xA32E30: it reads `<>4__this+0x40`
  ## (`_raidSettings`) for Side@0x20, RaidMode@0x44 and _selectedLocation@0xa8,
  ## and `OnReadyPressed`@0xA312E0 gates on the same object. So STAGE 2 writes
  ## THAT, not `get_CurrentRaidSettings()` -- the two can be different objects.
  let rs = cNrReadPtr(mo, NrMoRaidSettings)
  if rs == nil or cIsReadable(rs, 0xb8'i32) == 0'i32:
    nrFail("STAGE 2: MatchmakerOperation._raidSettings@0x40 is null or " &
           "unreadable. That is the ONLY object Ready() reads; this host does " &
           "not write hopefully into CurrentRaidSettings and press anyway")
    return
  # RE-CHECK the prerequisites at the moment of writing, not only at the moment
  # of deciding. A check that ran a second ago is not a check.
  if cNrReadPtr(rs, NrRsSelectedLoc) == nil:
    # Nothing is selected. Install the Location the probe resolved -- but only
    # if it was resolved AND passed the Id=="Woods" read-back. There is no
    # branch here that installs anything else.
    nrResolveWoods(rs, app)
    let fnSet = cNrFn(NrTSetSelectedLoc)
    if gNrLoc == nil:
      nrFail("STAGE 2: RaidSettings._selectedLocation@0xa8 is null and no " &
             "Woods Location could be resolved (" & gNrLocWhy & "). This host " &
             "does NOT construct a Location and does NOT write a guessed " &
             "pointer into 0xa8 -- a wrong pointer there kills the client")
      return
    if fnSet == nil:
      nrFail("STAGE 2: a Woods Location is in hand but " &
             "RaidSettings::set_SelectedLocation@0x6D7FF0 did not verify: " &
             $cNrWhyText(cNrWhyOf(NrTSetSelectedLoc)) &
             " -- refusing to store 0xa8 by hand, because the setter also " &
             "writes LocationId@0x30 under the GC write barrier")
      return
    okLog "nativeRaid DRIVE calling EFT.RaidSettings::set_SelectedLocation() " &
          "@0x6D7FF0 with the resolved Woods Location " & nrHex(gNrLoc) &
          " (via " & gNrLocVia & "; instance, one arg, NULL MethodInfo* -- " &
          "UNIQUE, not a shared generic)"
    cNrSetSelectedLocation(fnSet, rs, gNrLoc)
    # Assert the FINISHED STATE, not the call: re-read BOTH slots the setter is
    # supposed to have written, from the object, fresh.
    let back = cNrReadPtr(rs, NrRsSelectedLoc)
    let backId = nrReadStr(cNrReadPtr(rs, NrRsLocationId))
    if back == nil:
      nrFail("STAGE 2: set_SelectedLocation returned but " &
             "_selectedLocation@0xa8 still reads null -- the store did not take")
      return
    if backId != NrWoodsId:
      nrFail("STAGE 2: _selectedLocation@0xa8 is now " & nrHex(back) &
             " but LocationId@0x30 reads \"" & backId & "\", not \"" &
             NrWoodsId & "\" -- refusing to press READY on a half-applied " &
             "selection")
      return
    okLog "nativeRaid DRIVE _selectedLocation@0xa8=" & nrHex(back) &
          " and LocationId@0x30=\"" & backId & "\" -- read back from the live " &
          "object, not from our own write"
  let mpc = cNrReadPtr(mo, NrMoPlayersCtrl)
  if mpc == nil:
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

  # -------------------------------------------------------------------------
  # THE OFFLINE GATE IS IN A DIFFERENT STATE MACHINE. Measured 2026-08-30 by
  # disassembling `EFT.TarkovApplication::<OnReadyToStartMatchingAsync>d__195::
  # MoveNext` @0x9CC7B0 (capstone over the `il2cpp` section of
  # GameAssembly.dll):
  #   009ccb35  mov  rbx, [rdi+0x28]     <- the state machine's `<>4__this`
  #   009ccb81  inc  dword [rbx+0x1e4]   <- TarkovApplication
  #                                         .<CurrentTotalRaidNum>k__Backing-
  #                                         Field@0x1e4  == THE PROOF rbx is a
  #                                         TarkovApplication
  #   009ccb87  mov  rax, [rbx+0xd8]     <- TarkovApplication._raidSettings@0xd8
  #   009ccb97  cmp  dword [rax+0x44], 1
  #             je  -> LocalGameMatching   0x984170   (OFFLINE)
  #             else-> NetworkGameMatching 0x984360   (ONLINE)
  # rbx also feeds +0x128 (_menuOperation) and +0xb0, both TarkovApplication
  # fields per `fldoff.py fields EFT.TarkovApplication`, so the identification
  # is over-determined, not inferred from one offset.
  # So the gate reads `TarkovApplication._raidSettings@0xd8` -- the SAME slot
  # `get_CurrentRaidSettings`@0x691340 returns (its whole body is
  # `48 8B 81 D8 00 00 00 C3`) -- which need NOT be
  # `MatchmakerOperation._raidSettings@0x40` that `<Ready>d__40` reads. On the
  # 2026-08-30 live run we wrote only @0x40, and the client took
  # NetworkGameMatching (`NetworkGameMatching` x8, zero `Geometry`/
  # `LocationLoaded` in output_000.log). So write EVERY RaidSettings the commit
  # path can read -- each POSITIVELY IDENTIFIED first, never blind-written.
  # NOTE: the `forceOfflinePractice` flag does NOT cover this path. It is a
  # UI-toggle mechanism, and the native drive bypasses the UI entirely; do not
  # assume it makes any of the writes below redundant.
  let taRs = cNrReadPtr(app, NrTaRaidSettings)
  let moOffRs = cNrReadPtr(mo, NrMoOfflineRs)
  info "nativeRaid DRIVE GATE the RaidSettings references, side by side: " &
       "TarkovApplication._raidSettings@0xd8=" & nrHex(taRs) &
       " (THE OFFLINE GATE, and what get_CurrentRaidSettings@0x691340 returns)" &
       "; MatchmakerOperation._raidSettings@0x40=" & nrHex(rs) &
       " (what <Ready>d__40 reads); MatchmakerOperation._offlineRaidSettings" &
       "@0x48=" & nrHex(moOffRs) & " -- gate vs Ready: " & nrSame(taRs, rs) &
       "; gate vs offline: " & nrSame(taRs, moOffRs) & "; Ready vs offline: " &
       nrSame(rs, moOffRs)
  if taRs != nil and taRs != rs:
    nrApplyOffline(taRs, rs, app,
      "TarkovApplication._raidSettings@0xd8 (THE OFFLINE GATE)")
  if moOffRs != nil and moOffRs != rs and moOffRs != taRs:
    nrApplyOffline(moOffRs, rs, app,
      "MatchmakerOperation._offlineRaidSettings@0x48")

  # FINISHED-STATE ASSERT ON THE GATE ITSELF, and it can fail: if the object
  # `<OnReadyToStartMatchingAsync>d__195` will read does not hold Local(1) at
  # this instant, pressing READY reproduces the ONLINE run exactly.
  var gateMode = -1'i32
  if taRs == nil:
    nrFail("STAGE 2: TarkovApplication._raidSettings@0xd8 is null. That is the " &
           "object the offline gate at 0x9CCB87 dereferences; pressing READY " &
           "would either NRE there or take NetworkGameMatching. Refusing.")
    return
  if cNrReadI32(taRs, NrRsRaidMode, addr gateMode) == 0'i32 or
     gateMode != NrRaidModeLocal:
    nrFail("STAGE 2: the OFFLINE GATE object " &
           "TarkovApplication._raidSettings@0xd8=" & nrHex(taRs) &
           " does not read RaidMode Local(1) -- it reads " & $gateMode & " (" &
           nrRaidModeName(gateMode) & "). The gate at 0x9CCB97 compares THIS " &
           "field, so pressing READY now would take NetworkGameMatching " &
           "exactly as the 2026-08-30 live run did. Refusing to press.")
    return
  okLog "nativeRaid DRIVE GATE finished-state assert PASSES: the object the " &
        "offline gate reads (" & nrHex(taRs) & ") holds RaidMode@0x44=" &
        $gateMode & " (Local) and Ready()'s object (" & nrHex(rs) &
        ") holds Local too -- 0x9CCB97 should take LocalGameMatching@0x984170"

  # ---- THE PRESS. At most one per attempt, at most NrMaxDriveAttempts per
  # session. Everything above this line has just been re-read and re-asserted
  # from the live objects, so a retry is a FULL re-validation, not a replay.
  # -------------------------------------------------------------------------
  # THE PREREQUISITE THE HANDLER ITSELF DEREFERENCES, checked on the OBJECT WE
  # ARE ABOUT TO PRESS, in this frame, with nothing between this and the call.
  #
  # WHY THIS EXISTS. Measured on the live run whose client log is
  # `log_2026.08.31_17-20-40`: press attempt 1 produced
  #   17:21:21.055 Error|errors|Error while starting matching: Object reference
  #                not set to an instance of an object.
  #                EFT.<Ready>d__40:MoveNext() / MatchmakerOperation:Ready()
  #                / MatchmakerOperation:OnReadyPressed()
  # and the host then read `_readyPressed@0x60 == 0` and re-armed; attempt 2,
  # 282 ms later, took LocalGameMatching. So the handler DID run and threw.
  # Disassembly of `<Ready>d__40::MoveNext`@0xA32E30 gives four NRE sites in
  # that caught region: 0xa33ce8 (`<>4__this` null -- excluded, we pressed a
  # readable object), 0xa33ce3 (`+0xa0` null -- excluded, checked above), and
  # 0xa33cde / 0xa33cd9, which are `[mo+0xa0]` and `[[mo+0xa0]+0x110]`. By
  # elimination the throw was the +0x110 hop. That is a NARROWING, not a proof:
  # the body continues past 0xa331b9 and may hold further NRE sites this host
  # has not read. Stated as such rather than overclaimed.
  var readyDep: Il2CppPtr = nil
  if cIsReadable(mpc, NrMpcReadyDep + 8'i32) != 0'i32:
    readyDep = cNrReadPtr(mpc, NrMpcReadyDep)
  if readyDep == nil:
    inc gNrDefers
    if gNrDefers > NrMaxDefers:
      nrFail("STAGE 2 REFUSED THE PRESS " & $NrMaxDefers & " times and gives " &
             "up: MatchmakerPlayersController@0xa0=" & nrHex(mpc) &
             " +0x110 is still null. `<Ready>d__40::MoveNext` dereferences " &
             "that slot unconditionally at 0xa33169 and throws " &
             "NullReferenceException at 0xa33cd9 if it is null -- which is " &
             "exactly the client error measured at 17:21:21.055 on the " &
             "2026-08-31 run. NOT pressing. A refusal is the correct outcome " &
             "here; an NRE inside the client is not")
      return
    gNrSettleMs = NrDeferMs
    gNrArmedMs = cNowMs()
    gNrStep = NrArmed
    warn "nativeRaid DRIVE REFUSING TO PRESS (deferral " & $gNrDefers & "/" &
         $NrMaxDefers & ", no attempt consumed): the object " &
         "MatchmakerOperation@0xa0 -> MatchmakerPlayersController=" &
         nrHex(mpc) & " has +0x110 null or unreadable. `<Ready>d__40::" &
         "MoveNext` loads it at 0xa33169 and throws NRE at 0xa33cd9 when it " &
         "is null. Re-checking in " & $NrDeferMs & "ms; the whole drive " &
         "re-validates from scratch"
    return
  # RE-READ THE MATCHMAKER ONE LAST TIME AND REFUSE IF IT MOVED. `nrMatchmaker`
  # has TWO sources -- `_menuOperation@0x128 .Matchmaker@0x118` preferred,
  # `_localMatchmakerOperation@0x100` as fallback -- and they were MEASURED to
  # be different objects on the 2026-08-31 run (probe read 0x20edf56f840 from
  # the fallback at 0:00:44.687; the drive read 0x20edf16da80 from the
  # preferred source at 0:00:45.515). Everything above validated `mo`; if the
  # graph swapped underneath us between the gate assert and here, START OVER
  # rather than press an object we did not validate.
  var moWhy2 = ""
  let mo2 = nrMatchmaker(app, moWhy2)
  if mo2 != mo:
    gNrSettleMs = NrDeferMs
    gNrArmedMs = cNowMs()
    gNrStep = NrArmed
    warn "nativeRaid DRIVE REFUSING TO PRESS (no attempt consumed): the " &
         "MatchmakerOperation changed between the gate assert and the press " &
         "-- validated " & nrHex(mo) & ", now reads " & nrHex(mo2) & " (" &
         moWhy2 & "). Starting the whole drive over rather than pressing an " &
         "object that was never validated"
    return
  inc gNrAttempts
  okLog "nativeRaid DRIVE attempt " & $gNrAttempts & "/" & $NrMaxDriveAttempts &
        ": calling EFT.MatchmakerOperation::OnReadyPressed() @0xA312E0 on " &
        nrHex(mo) & " (instance, zero args, NULL MethodInfo* -- not a shared " &
        "generic)."
  cNrCallVoid(fnRp, mo)
  var rp = 0'i32
  if cNrReadU8(mo, NrMoReadyPressed, addr rp) == 0'i32:
    gNrLastRp = -1
    nrFail("STAGE 2 attempt " & $gNrAttempts & ": OnReadyPressed returned but " &
           "MatchmakerOperation._readyPressed@0x60 was not readable. That is " &
           "INCONCLUSIVE, not a pass -- this host will not retry a press when " &
           "it cannot read whether the last one took")
    return
  gNrLastRp = rp
  if rp == 0'i32:
    # THE PRESS DID NOT TAKE. Measured failure mode, not a curiosity.
    if gNrAttempts >= NrMaxDriveAttempts:
      nrFail("STAGE 2 GAVE UP: all " & $NrMaxDriveAttempts & " attempts to " &
             "press READY were made and NONE took -- the last read-back of " &
             "MatchmakerOperation._readyPressed@0x60 was " & $gNrLastRp &
             ". That read-back is INCONCLUSIVE about whether the handler ran " &
             "(MoveNext sets +0x60=1 at 0xa33016 and the catch can roll it " &
             "back), so read the client's errors_000.log to tell " &
             "\"never started\" from \"ran and threw\". Every " &
             "prerequisite, both field write-backs and the offline-gate " &
             "finished-state assert PASSED before each press, so this is not " &
             "a bad predicate: the client is refusing the press at this point " &
             "in boot. FAIL -- no raid was entered and nothing further will " &
             "be pressed")
      return
    let waitMs = NrRetryDelaysMs[gNrAttempts - 1]
    gNrSettleMs = waitMs
    gNrArmedMs = cNowMs()
    gNrStep = NrArmed
    warn "nativeRaid DRIVE attempt " & $gNrAttempts & "/" &
         $NrMaxDriveAttempts & ": _readyPressed=0 after press -- INCONCLUSIVE, " &
         "and specifically NOT the same thing as \"the handler did not run\", " &
         "which is what this line used to claim. MEASURED: " &
         "`<Ready>d__40::MoveNext`@0xA32E30 writes `[this+0x60]=1` at " &
         "0xa33016, BEFORE every NRE site in its caught region, so a 0 " &
         "read-back means the handler ran and ROLLED BACK at least as often " &
         "as it means the handler never started. On the 2026-08-31 run this " &
         "exact read-back of 0 accompanied a client-side " &
         "\"Error while starting matching: Object reference not set to an " &
         "instance of an object\" at 17:21:21.055 -- i.e. the handler ran and " &
         "threw. CHECK THE CLIENT'S OWN errors_000.log before believing any " &
         "story about this. Re-arming in " & $int(waitMs) & "ms. The next attempt " &
         "re-reads the matchmaker operation, re-checks the RaidSettings " &
         "identities and re-asserts RaidMode@0x44=Local(1) on the gate object " &
         "from scratch; nothing from this attempt is assumed to survive."
    return

  # ---- THE MENU-VISIBLE WINDOW, as a MEASURED number rather than a felt one.
  # Reference point: the readiness TRANSITION (`gNrReadySince`) -- the first tick
  # on which the matchmaker graph read non-null. That graph is built BY the main
  # menu, so it is the closest in-feature proxy for "the menu is on screen"; on
  # the 2026-08-30 run it trailed the menu rebuild by 235 ms (menu rebuild
  # 0:00:46.234, readiness 0:00:46.469). The number below is therefore a slight
  # UNDER-estimate of what the player sees, and is stated as such.
  if gNrReadySince == 0'u64:
    warn "nativeRaid MENU-VISIBLE WINDOW: INCONCLUSIVE -- the readiness " &
         "timestamp was not set, so the window could not be measured. This is " &
         "not a pass."
  else:
    let winMs = cNowMs() - gNrReadySince
    var verdict = "INCONCLUSIVE"
    if winMs < 800'u64: verdict = "PASS"
    elif winMs >= 2484'u64: verdict = "FAIL"
    okLog "nativeRaid MENU-VISIBLE WINDOW: " & $int(winMs) & " ms from the " &
          "readiness transition to the SUCCESSFUL OnReadyPressed (attempt " &
          $gNrAttempts & " of " & $NrMaxDriveAttempts &
          "; retries are INSIDE this number, so it never understates entry) -- " &
          verdict &
          ". Baseline before this change: 2484 ms (readiness 0:00:46.469, " &
          "drive 0:00:48.953 on the 2026-08-30 live run), of which 1500 ms was " &
          "NrDriveSettleMs and ~984 ms was the 60-frame tick divisor. PASS is " &
          "under 800 ms, FAIL is at or above the 2484 ms baseline, anything " &
          "between is INCONCLUSIVE. Add ~235 ms to compare against the frame " &
          "the menu itself was rebuilt."

  gNrPressed = true
  gNrStep = NrDone
  okLog "nativeRaid DRIVE read-back MatchmakerOperation._readyPressed@0x60=" &
        $rp & " on attempt " & $gNrAttempts & " of " & $NrMaxDriveAttempts &
        " -- 1 means the game's own handler ran. This is EVIDENCE the call " &
        "took, NOT proof a raid loads; only a live launch settles that. The " &
        "feature is HANDS-OFF for the rest of the session."

# ---------------------------------------------------------------------------
proc nrTickBody(a: Il2CppPtr): Il2CppPtr {.exportc: "aowl_nr_tick_body", cdecl.} =
  ## Returns a non-nil sentinel on clean completion; the guard returns nil on a
  ## fault. At most ONE probe or ONE drive per call.
  result = cast[Il2CppPtr](1)
  discard a
  if gNrStep == NrDone or gNrStep == NrFailed or gNrStep == NrIdle: return
  nrLogTargets()
  let now = cNowMs()

  # ---- THE READINESS GATE. Nothing below this touches the game until the
  # matchmaker graph EXISTS, established by guarded reads only. Before it does,
  # the tick is integer compares plus two pointer reads and makes NO call.
  var readyWhy = ""
  let mmNow = nrMatchmaker(gNrApp, readyWhy)
  if mmNow == nil:
    # Not ready. Say so -- once, and again only when the reason CHANGES -- and
    # never call anyway.
    if readyWhy != gNrLastReadyWhy:
      gNrLastReadyWhy = readyWhy
      info "nativeRaid WAITING for readiness (nothing called, nothing " &
           "written): " & readyWhy
    if now - gNrT0 > NrProbeWindowMs:
      nrFail("readiness was never established within " &
             $int(NrProbeWindowMs div 1000'u64) & " s: " & readyWhy &
             ". REFUSING -- this host does not call " &
             "get_MatchmakerOperation@0x977360 to force the graph into " &
             "existence, because doing so NREs inside " &
             "OfflineInventoryController..ctor and kills the client")
    gNrReadySince = 0'u64
    return
  if gNrReadySince == 0'u64:
    # A false -> true readiness TRANSITION. One generation, one probe, one drive.
    gNrReadySince = now
    inc gNrReadyGen
    # A new generation is a new matchmaker graph: the attempt budget and the
    # back-off both start over, and the previous generation's read-back says
    # nothing about this one.
    gNrAttempts = 0
    gNrLastRp = -1
    gNrSettleMs = NrDriveSettleMs
    okLog "nativeRaid READY (generation " & $gNrReadyGen & "): " & readyWhy &
          " -- the matchmaker graph already exists, so no call of ours can " &
          "construct it. Probing at most once for this generation."

  if gNrStep == NrWait or gNrStep == NrProbe:
    gNrStep = NrProbe
    gNrProbedGen = gNrReadyGen
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
      gNrSettleMs = NrDriveSettleMs
      okLog "nativeRaid: prerequisites satisfied and uxNativeRaidDrive is ON " &
            "-- STAGE 2 arms in " & $int(gNrSettleMs) & " ms."
      return
    if now - gNrT0 > NrProbeWindowMs:
      nrFail("the prerequisites never all became satisfiable within " &
             $int(NrProbeWindowMs div 1000'u64) & " s of probing (read the " &
             "PROBE reports above: the last one names which item was FAIL or " &
             "INCONCLUSIVE)")
    return

  if gNrStep == NrArmed:
    if now - gNrArmedMs < gNrSettleMs: return
    # AT MOST ONCE PER READINESS TRANSITION. If readiness dropped and came back
    # while armed, this generation has not been probed, so disarm rather than
    # drive on a stale verdict.
    if gNrProbedGen != gNrReadyGen:
      gNrStep = NrProbe
      warn "nativeRaid: readiness changed between arming and driving " &
           "(probed generation " & $gNrProbedGen & ", current " & $gNrReadyGen &
           ") -- DISARMING and re-probing rather than driving on a stale verdict"
      return
    # The per-generation guard is now bounded by the ATTEMPT budget rather than
    # by "once", because a press whose read-back is 0 did not happen as far as
    # the game is concerned. It is still a hard cap: NrMaxDriveAttempts and no
    # more, and `nrDrive` itself refuses loudly on the last one.
    if gNrDrivenGen == gNrReadyGen and gNrAttempts >= NrMaxDriveAttempts:
      gNrStep = NrIdle
      warn "nativeRaid: STAGE 2 has already used all " &
           $NrMaxDriveAttempts & " press attempts for readiness generation " &
           $gNrReadyGen & " (last _readyPressed read-back " & $gNrLastRp &
           ") -- refusing to run it again"
      return
    gNrDrivenGen = gNrReadyGen
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
