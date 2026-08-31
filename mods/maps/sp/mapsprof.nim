## THE MAPS PHASE PROFILER -- the Nim half. The C half, the rationale and the
## honesty rules are in `sp/mapsprof.h`.
##
## WHAT IT HOOKS: nothing new. Pairs of QueryPerformanceCounter reads around
## call sites that already exist in `onMainTick` and in `collectInner`. No
## detour, no name resolved, nothing in the game called or dereferenced, and
## every bracket sits strictly OUTSIDE any `aowl_p_p_seh` -- that guard is not
## re-entrant (CLAUDE.md 5).
##
## UNITS: every printed number is MICROSECONDS with `us` attached. There is no
## unitless duration in this file's output.
##
## THREE OUTCOMES, never two. Below `MP_MIN_TICKS` bracketed ticks the verdict
## is INCONCLUSIVE -- "I could not look yet" is not a pass (CLAUDE.md 9b).

import aowlspt

## THIS is the one translation unit that DEFINES the counters; every other
## includer gets prototypes only. See the comment on AOWL_MAPSPROF_IMPL in the
## header for why per-TU copies would be a meter measuring a third of itself.
{.emit: """
#define AOWL_MAPSPROF_IMPL
#include "sp/mapsprof.h"
""".}

proc mpNow*(): int64 {.importc: "aowl_mp_now", nodecl.}
proc mpAdd*(slot: int32; t0: int64) {.importc: "aowl_mp_add", nodecl.}
proc mpTick*() {.importc: "aowl_mp_tick", nodecl.}
proc mpControlBody() {.importc: "aowl_mp_control_body", nodecl.}
proc mpSetEnabled*(on: int32) {.importc: "aowl_mp_set_enabled", nodecl.}
proc mpEnabled*(): int32 {.importc: "aowl_mp_enabled", nodecl.}
proc mpNs(i: int32): int64 {.importc: "aowl_mp_ns", nodecl.}
proc mpCalls(i: int32): int64 {.importc: "aowl_mp_calls", nodecl.}
proc mpMax(i: int32): int64 {.importc: "aowl_mp_max", nodecl.}
proc mpTicks(): int64 {.importc: "aowl_mp_ticks", nodecl.}
proc mpDropped(): int64 {.importc: "aowl_mp_dropped", nodecl.}
proc mpOverhead(): int64 {.importc: "aowl_mp_overhead", nodecl.}
proc mpCal(): int32 {.importc: "aowl_mp_cal", nodecl.}
proc mpSlots(): int32 {.importc: "aowl_mp_slots", nodecl.}
proc mpCtrlIters(): int32 {.importc: "aowl_mp_ctrl_iters", nodecl.}
proc mpMinTicks(): int64 {.importc: "aowl_mp_min_ticks", nodecl.}

## The slot numbers, in ONE place, in lockstep with the `MP_*` defines in
## `sp/mapsprof.h` and with `MpNames` below. Call sites use these names and
## never a literal.
const
  MpWhole*   = 0'i32
  MpLock*    = 1'i32
  MpCollect* = 2'i32
  MpPublish* = 3'i32
  MpFsPoll*  = 4'i32
  MpArt*     = 5'i32
  MpCPre*    = 6'i32
  MpCLoc*    = 7'i32
  MpCLocal*  = 8'i32
  MpCList*   = 9'i32
  MpCEnts*   = 10'i32
  MpEFetch*  = 11'i32
  MpEPos*    = 12'i32
  MpEAi*     = 13'i32
  MpECls*    = 14'i32
  MpEId*     = 15'i32
  MpEStore*  = 16'i32
  MpPWalk*   = 17'i32
  MpPCall*   = 18'i32
  MpPTail*   = 19'i32
  MpCtrl*    = 20'i32

const MpNames: array[21, string] = [
  "WHOLE(onMainTick)",     # 0
  "lockMod",               # 1
  "collect",               # 2
  "hudPublish",            # 3
  "fsKeyPoll",             # 4
  "artTick",               # 5
  "c.pre(gwState+world)",  # 6
  "c.locationId(string)",  # 7
  "c.localPlayer",         # 8
  "c.listHead",            # 9
  "c.entityLoop",          # 10
  "e.fetchSlot(list read)",# 11
  "e.posOf(RVA call)",     # 12
  "e.aiDataRead",          # 13
  "e.classOf(+cacheProbe)",# 14
  "e.idTailOf(cache MISS only)", # 15
  "e.storeEnt",            # 16
  "p.walk(5 guarded hops)",# 17
  "p.rvaCall(0x6F32C0)",   # 18
  "p.tail(copy+classify)", # 19
  "CONTROL(512 adds)"]     # 20

proc mpName(i: int32): string =
  if i >= 0'i32 and i < 21'i32: return MpNames[int(i)]
  return "slot[" & $int(i) & ": UNNAMED]"

proc mpUsPer(nsTotal, ticks: int64): string =
  ## ONE unit, always spelled: microseconds PER TICK, to one decimal. `n/a` for
  ## "no ticks" -- never a number, because a zero here reads as "free" and means
  ## "unmeasured".
  if ticks <= 0: return "n/a"
  let tenths = (nsTotal * 10'i64) div (ticks * 1000'i64)
  $(tenths div 10) & "." & $(tenths mod 10) & "us"

proc mpUs(ns: int64): string =
  if ns < 0: return "n/a"
  let tenths = (ns * 10'i64) div 1000'i64
  $(tenths div 10) & "." & $(tenths mod 10) & "us"

proc mpPctOf(part, whole: int64): string =
  if whole <= 0: return "n/a"
  let t = (part * 1000'i64) div whole
  $(t div 10) & "." & $(t mod 10) & "%"

proc mpControl*() =
  ## The positive control, run through its own bracket, in the same tick, on the
  ## same clock as every other row. Without it "the meter is lying" cannot be
  ## ruled out.
  if mpEnabled() == 0'i32: return
  let t = mpNow()
  mpControlBody()
  mpAdd(MpCtrl, t)

proc mpLevel(lo, hi, whole: int32; label: string; ticks: int64): string =
  ## ONE decomposition level: its rows, then the arithmetic against its own
  ## whole, said out loud whichever way it lands. Rows that never ran are named
  ## separately from cheap rows, because "0 calls" and "free" are different
  ## facts and confusing them cost four bisect runs.
  let tot = mpNs(whole)
  var s = " " & label & " (a BREAKDOWN of " & mpName(whole) &
          "=" & mpUsPer(tot, ticks) & "/tick, NOT extra cost):"
  var acc = 0'i64
  var silent = ""
  var i = lo
  while i <= hi:
    let c = mpCalls(i)
    if c == 0:
      if silent.len > 0: silent = silent & ", "
      silent = silent & mpName(i)
    else:
      acc = acc + mpNs(i)
      s = s & " " & mpName(i) & "=" & mpUsPer(mpNs(i), ticks) & "/tick (" &
          mpPctOf(mpNs(i), tot) & " of " & mpName(whole) & ", " & $c &
          " call(s), max " & mpUs(mpMax(i)) & ")"
    i = i + 1'i32
  if silent.len > 0:
    s = s & ". NEVER CALLED (0 calls -- NOT 'free', NOT measured): " & silent
  let unex = tot - acc
  s = s & ". accounted=" & mpUsPer(acc, ticks) & " of " & mpUsPer(tot, ticks) &
      " (" & mpPctOf(acc, tot) & ")"
  if tot <= 0:
    s = s & "; the parent bracket recorded NO time, so this level is VOID"
  elif unex > 0:
    s = s & "; " & mpPctOf(unex, tot) & " (" & mpUsPer(unex, ticks) &
        "/tick) is OUTSIDE every bracket at this level and is UNEXPLAINED"
  else:
    s = s & "; the phases sum to AT OR ABOVE their parent, which is IMPOSSIBLE " &
        "for disjoint brackets -- treat this level as BROKEN, not as a result"
  s

proc mapsProfLine*(): string =
  ## THREE OUTCOMES, never two.
  let ticks = mpTicks()
  var s = "maps prof: "
  if ticks < mpMinTicks():
    s = s & "INCONCLUSIVE -- " & $ticks & " bracketed tick(s) is below the " &
        $mpMinTicks() & "-tick threshold, so no decomposition is reported."
    if mpDropped() > 0:
      s = s & " (" & $mpDropped() & " interval(s) refused as absurd.)"
    return s & " This is NOT a pass; it means I could not look yet."

  # THE CONTROL FIRST, because every row below it is void if it is wrong.
  let cc = mpCalls(MpCtrl)
  s = s & "CONTROL " & $mpCtrlIters() & " integer adds = " &
      mpUsPer(mpNs(MpCtrl), cc) & "/call over " & $cc &
      " call(s) (expected: sub-microsecond, order 0.1-1.0us. If this reads " &
      "0.0us or reads MILLISECONDS the clock or the bracket is broken and " &
      "EVERY row below is VOID). "

  s = s & mpName(MpWhole) & "=" & mpUsPer(mpNs(MpWhole), ticks) & "/tick over " &
      $ticks & " tick(s), max " & mpUs(mpMax(MpWhole)) & "."
  s = s & mpLevel(MpLock, MpArt, MpWhole, "L1 tick phases", ticks)
  s = s & "." & mpLevel(MpCPre, MpCEnts, MpCollect, "L2 collect phases", ticks)
  s = s & "." & mpLevel(MpEFetch, MpEStore, MpCEnts, "L3 per-entity phases", ticks)
  s = s & "." & mpLevel(MpPWalk, MpPTail, MpEPos, "L4 inside posOf", ticks)
  # THE ONE NUMBER THIS LEVEL EXISTS FOR: a per-CALL cost, not a per-tick share.
  # us/tick is not comparable across runs -- it divides by ticks that include
  # MENU ticks, and the collect-to-tick ratio differs between runs. Two rows
  # printed per-call, on the same clock, in the same ticks, so "the position
  # read is expensive" can be checked against "a guarded hop is cheap" without
  # anyone having to redo this arithmetic from a log.
  let posCalls = mpCalls(MpEPos)
  let aiCalls = mpCalls(MpEAi)
  if posCalls > 0 and aiCalls > 0:
    s = s & ". PER-CALL (ns/call, the tick-count-independent figure): " &
        mpName(MpEPos) & "=" & $(mpNs(MpEPos) div posCalls) & "ns over " &
        $posCalls & " call(s); " & mpName(MpPCall) & "=" &
        (if mpCalls(MpPCall) > 0: $(mpNs(MpPCall) div mpCalls(MpPCall)) & "ns"
         else: "NEVER CALLED") & "; " & mpName(MpPWalk) & "=" &
        (if mpCalls(MpPWalk) > 0: $(mpNs(MpPWalk) div mpCalls(MpPWalk)) & "ns"
         else: "NEVER CALLED") & "; " & mpName(MpEAi) & "=" &
        $(mpNs(MpEAi) div aiCalls) & "ns (ONE guarded hop -- the reference " &
        "cost of the cached readability guard, for scale)"

  # THE INSTRUMENT'S OWN SHARE, measured at enable time, never asserted.
  var calls = 0'i64
  var i = 0'i32
  while i < mpSlots():
    calls = calls + mpCalls(i)
    i = i + 1'i32
  if mpOverhead() >= 0:
    let mine = mpOverhead() * calls
    s = s & ". METER OVERHEAD " & $mpOverhead() & "ns per bracket pair " &
        "(measured over " & $mpCal() & " empty pairs at enable), x " & $calls &
        " pair(s) = " & mpUsPer(mine, ticks) & "/tick = " &
        mpPctOf(mine, mpNs(MpWhole)) & " of " & mpName(MpWhole)
  else:
    s = s & ". METER OVERHEAD: NOT MEASURED (calibration failed) -- the " &
        "instrument's share of its own reading is UNKNOWN"
  if mpDropped() > 0:
    s = s & ". dropped=" & $mpDropped() &
        " (interval negative or >10s -- counted, never silently discarded)"
  s & ". NOTE: this is CUMULATIVE since the profiler was enabled and does NOT " &
    "distinguish MENU ticks from IN-RAID ticks; read it beside the maps diag " &
    "block in the same log."
