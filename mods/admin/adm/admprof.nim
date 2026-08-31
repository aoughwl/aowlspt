## THE ADMIN PHASE PROFILER -- the nimony half. The C half, the rationale and
## the honesty rules are in `abi/aowlspt_admprof.h`.
##
## WHAT IT HOOKS: nothing new. Pairs of QueryPerformanceCounter reads around
## call sites that already exist in `onCamTick`, in `posSample` and inside
## `aowl_admin_pos_live`. No detour, no name resolved, nothing in the game
## called or dereferenced beyond what already ran, and every bracket sits
## strictly OUTSIDE any `aowl_p_p_seh` -- that guard is not re-entrant
## (CLAUDE.md 5).
##
## UNITS: every printed duration is MICROSECONDS with `us` attached, or
## NANOSECONDS with `ns` attached. There is no unitless duration in this file's
## output.
##
## THREE OUTCOMES, never two. Below `AP_MIN_TICKS` bracketed ticks the verdict
## is INCONCLUSIVE -- "I could not look yet" is not a pass (CLAUDE.md 9b).

import aowlspt

## THIS is the one translation unit that DEFINES the counters; every other
## includer gets prototypes only. Per-TU copies would be a meter measuring a
## fraction of itself.
{.emit: """
#define AOWL_ADMPROF_IMPL
#include "aowlspt_admprof.h"
""".}

proc apNow*(): int64 {.importc: "aowl_ap_now", nodecl.}
proc apAdd*(slot: int32; t0: int64) {.importc: "aowl_ap_add", nodecl.}
proc apTick*() {.importc: "aowl_ap_tick", nodecl.}
proc apControlBody() {.importc: "aowl_ap_control_body", nodecl.}
proc apSetEnabled*(on: int32) {.importc: "aowl_ap_set_enabled", nodecl.}
proc apEnabled*(): int32 {.importc: "aowl_ap_enabled", nodecl.}
proc apNs(i: int32): int64 {.importc: "aowl_ap_ns", nodecl.}
proc apCalls(i: int32): int64 {.importc: "aowl_ap_calls", nodecl.}
proc apMax(i: int32): int64 {.importc: "aowl_ap_max", nodecl.}
proc apTicks(): int64 {.importc: "aowl_ap_ticks", nodecl.}
proc apDropped(): int64 {.importc: "aowl_ap_dropped", nodecl.}
proc apOverhead(): int64 {.importc: "aowl_ap_overhead", nodecl.}
proc apCal(): int32 {.importc: "aowl_ap_cal", nodecl.}
proc apSlots(): int32 {.importc: "aowl_ap_slots", nodecl.}
proc apCtrlIters(): int32 {.importc: "aowl_ap_ctrl_iters", nodecl.}
proc apMinTicks(): int64 {.importc: "aowl_ap_min_ticks", nodecl.}

## The slot numbers, in ONE place, in lockstep with the `AP_*` defines in
## `abi/aowlspt_admprof.h` and with `ApNames` below. Call sites use these names
## and never a literal.
const
  ApWhole*   = 0'i32
  ApHotkey*  = 1'i32
  ApCam*     = 2'i32
  ApPos*     = 3'i32
  ApPArm*    = 4'i32
  ApPWorld*  = 5'i32
  ApPMe*     = 6'i32
  ApPLoop*   = 7'i32
  ApPCommit* = 8'i32
  ApPMove*   = 9'i32
  ApEFetch*  = 10'i32
  ApEAdd*    = 11'i32
  ApLH1*     = 12'i32
  ApLH2*     = 13'i32
  ApLH3*     = 14'i32
  ApLH4*     = 15'i32
  ApLH5*     = 16'i32
  ApLCall*   = 17'i32
  ApLTail*   = 18'i32
  ApLWhole*  = 19'i32
  ApCtrl*    = 20'i32

const ApNames: array[21, string] = [
  "WHOLE(onCamTick)",             # 0
  "hotkeyPoll",                   # 1
  "camSample(3 RVA calls)",       # 2
  "posSample",                    # 3
  "p.posArm(sticky)",             # 4
  "p.world+list+items",           # 5
  "p.localPlayer(posAdd)",        # 6
  "p.entityLoop",                 # 7
  "p.posCommit",                  # 8
  "p.moveSelfCheck",              # 9
  "e.fetchSlot(list read)",       # 10
  "e.posAdd",                     # 11
  "h1.bones(Pl+0xB40 ptr)",       # 12
  "h2.bodyXf(PB+0x178 ptr)",      # 13
  "h3.accumFlag(BT+0xA9 u8)",     # 14
  "h4.useImit(BT+0xA8 u8)",       # 15
  "h5.original(BT+0x10 ptr)",     # 16
  "l.rvaCall(0x6F32C0)",          # 17
  "l.tail(copy+classify)",        # 18
  "l.WHOLE(pos_live body)",       # 19
  "CONTROL(512 adds)"]            # 20

proc apName(i: int32): string =
  if i >= 0'i32 and i < 21'i32: return ApNames[int(i)]
  return "slot[" & $int(i) & ": UNNAMED]"

proc apUsPer(nsTotal, ticks: int64): string =
  ## ONE unit, always spelled: microseconds PER TICK, to one decimal. `n/a` for
  ## "no ticks" -- never a number, because a zero here reads as "free" and means
  ## "unmeasured".
  if ticks <= 0: return "n/a"
  let tenths = (nsTotal * 10'i64) div (ticks * 1000'i64)
  $(tenths div 10) & "." & $(tenths mod 10) & "us"

proc apUs(ns: int64): string =
  if ns < 0: return "n/a"
  let tenths = (ns * 10'i64) div 1000'i64
  $(tenths div 10) & "." & $(tenths mod 10) & "us"

proc apPctOf(part, whole: int64): string =
  if whole <= 0: return "n/a"
  let t = (part * 1000'i64) div whole
  $(t div 10) & "." & $(t mod 10) & "%"

proc apControl*() =
  ## The positive control, through its own bracket, in the same tick, on the
  ## same clock as every other row. Without it "the meter is lying" cannot be
  ## ruled out.
  if apEnabled() == 0'i32: return
  let t = apNow()
  apControlBody()
  apAdd(ApCtrl, t)

proc apLevel(lo, hi, whole: int32; label: string; ticks: int64): string =
  ## ONE decomposition level: its rows, then the arithmetic against its own
  ## parent, said out loud whichever way it lands. Rows that never ran are named
  ## SEPARATELY from cheap rows, because "0 calls" and "free" are different
  ## facts.
  let tot = apNs(whole)
  var s = " " & label & " (a BREAKDOWN of " & apName(whole) &
          "=" & apUsPer(tot, ticks) & "/tick, NOT extra cost):"
  var acc = 0'i64
  var silent = ""
  var i = lo
  while i <= hi:
    let c = apCalls(i)
    if c == 0:
      if silent.len > 0: silent = silent & ", "
      silent = silent & apName(i)
    else:
      acc = acc + apNs(i)
      s = s & " " & apName(i) & "=" & apUsPer(apNs(i), ticks) & "/tick (" &
          apPctOf(apNs(i), tot) & " of " & apName(whole) & ", " & $c &
          " call(s), max " & apUs(apMax(i)) & ")"
    i = i + 1'i32
  if silent.len > 0:
    s = s & ". NEVER CALLED (0 calls -- NOT 'free', NOT measured): " & silent
  let unex = tot - acc
  s = s & ". accounted=" & apUsPer(acc, ticks) & " of " & apUsPer(tot, ticks) &
      " (" & apPctOf(acc, tot) & ")"
  if tot <= 0:
    s = s & "; the parent bracket recorded NO time, so this level is VOID"
  elif unex > 0:
    s = s & "; " & apPctOf(unex, tot) & " (" & apUsPer(unex, ticks) &
        "/tick) is OUTSIDE every bracket at this level and is UNEXPLAINED"
  else:
    s = s & "; the phases sum to AT OR ABOVE their parent, which is IMPOSSIBLE " &
        "for disjoint brackets -- treat this level as BROKEN, not as a result"
  s

proc apPerCall(i: int32): string =
  ## THE TICK-COUNT-INDEPENDENT FIGURE, and the one a previous agent had to
  ## hand-compute from a log. "0 calls" is reported as NEVER RAN, never as 0ns.
  let c = apCalls(i)
  if c <= 0: return apName(i) & "=NEVER RAN (0 calls -- NOT 'free', NOT measured)"
  apName(i) & "=" & $(apNs(i) div c) & "ns/call over " & $c & " call(s)"

proc admProfLine*(): string =
  ## THREE OUTCOMES, never two.
  let ticks = apTicks()
  var s = "admin prof: "
  if ticks < apMinTicks():
    s = s & "INCONCLUSIVE -- " & $ticks & " bracketed tick(s) is below the " &
        $apMinTicks() & "-tick threshold, so no decomposition is reported."
    if apDropped() > 0:
      s = s & " (" & $apDropped() & " interval(s) refused as absurd.)"
    return s & " This is NOT a pass; it means I could not look yet."

  # THE CONTROL FIRST, because every row below it is void if it is wrong.
  let cc = apCalls(ApCtrl)
  s = s & "CONTROL " & $apCtrlIters() & " integer adds = " &
      apUsPer(apNs(ApCtrl), cc) & "/call over " & $cc &
      " call(s) (expected: sub-microsecond, order 0.1-1.0us. If this reads " &
      "0.0us or reads MILLISECONDS the clock or the bracket is broken and " &
      "EVERY row below is VOID). "

  s = s & apName(ApWhole) & "=" & apUsPer(apNs(ApWhole), ticks) & "/tick over " &
      $ticks & " tick(s), max " & apUs(apMax(ApWhole)) & "."
  s = s & apLevel(ApHotkey, ApPos, ApWhole, "L1 tick phases", ticks)
  s = s & "." & apLevel(ApPArm, ApPMove, ApPos, "L2 posSample phases", ticks)
  s = s & "." & apLevel(ApEFetch, ApEAdd, ApPLoop, "L3 per-slot phases", ticks)
  s = s & "." & apLevel(ApLH1, ApLTail, ApLWhole, "L4 inside pos_live", ticks)

  # THE CHECK THAT CAN FAIL. apLevel's own >=100% branch stays (it is the last
  # line of defence) but it fires only AFTER the arithmetic has been corrupted.
  # This asserts the PROPERTY that makes L4 sound -- every child bracket is
  # opened no more often than its parent -- so a future call site that opens a
  # child outside pos_live announces itself BY NAME. It is falsifiable: a wrong
  # parent (AP_E_ADD, which misses the local player's call) fails it.
  block:
    let pw = apCalls(ApLWhole)
    var bad = ""
    var j = ApLH1
    while j <= ApLTail:
      let c = apCalls(j)
      # A hop may run FEWER times than the whole (an early return
      # short-circuits it); running MORE times is the containment violation.
      if c > pw:
        if bad.len > 0: bad = bad & ", "
        bad = bad & apName(j) & "=" & $c
      j = j + 1'i32
    if pw <= 0:
      s = s & ". L4 CONTAINMENT: UNCHECKED -- " & apName(ApLWhole) &
          " recorded 0 call(s), so nothing was enclosed and the level above " &
          "is VOID, not cheap"
    elif bad.len > 0:
      s = s & ". L4 CONTAINMENT VIOLATED -- " & apName(ApLWhole) & "=" & $pw &
          " call(s) but " & bad & " ran MORE OFTEN, so a child bracket is " &
          "opened OUTSIDE the parent. The L4 level above is BROKEN, not a result"
    else:
      s = s & ". L4 containment OK (" & apName(ApLWhole) & "=" & $pw &
          " call(s); no hop exceeds it)"

  # THE SAME CHECK ONE LEVEL UP, for the reason L4's parent had to be changed at
  # all: pos_live is reached from TWO call sites (the local player at L2 and
  # each entity at L3), so ApLWhole must equal their sum. If it does not, a
  # third call site exists and the decomposition is incomplete.
  block:
    let expect = apCalls(ApPMe) + apCalls(ApEAdd)
    let got = apCalls(ApLWhole)
    if got == 0 and expect == 0:
      s = s & ". CALL-SITE ACCOUNTING: UNCHECKED -- pos_live was NEVER CALLED " &
          "(0 calls at both sites), which is NOT 'cheap'"
    elif got == expect:
      s = s & ". call-site accounting OK (" & apName(ApLWhole) & "=" & $got &
          " = p.localPlayer " & $apCalls(ApPMe) & " + e.posAdd " & $apCalls(ApEAdd) & ")"
    else:
      s = s & ". CALL-SITE ACCOUNTING FAILED -- " & apName(ApLWhole) & "=" &
          $got & " but the two known sites account for " & $expect &
          " (p.localPlayer " & $apCalls(ApPMe) & " + e.posAdd " &
          $apCalls(ApEAdd) & "). A THIRD call site into pos_live exists, so " &
          "the L4 level is not exhaustive"

  # THE NUMBERS THIS BUILD EXISTS FOR: per-CALL, on the same clock, in the same
  # ticks. us/tick is not comparable across runs -- it divides by ticks that
  # include MENU ticks. Nobody should have to redo this arithmetic from a log.
  s = s & ". PER-CALL (ns/call, the tick-count-independent figure): " &
      apPerCall(ApWhole) & "; " & apPerCall(ApCam) & "; " &
      apPerCall(ApHotkey) & "; " & apPerCall(ApPos) & "; " &
      apPerCall(ApLWhole) & "; " & apPerCall(ApEFetch)
  s = s & ". PER-HOP (ns/call, each hop of the guarded walk, in walk order -- " &
      "NEVER averaged into one number, because a hop that ran 500 times and " &
      "one that ran 80000 times are not comparable): "
  var walkSum = 0'i64
  var hopsRan = 0
  var k = ApLH1
  while k <= ApLH5:
    if k != ApLH1: s = s & "; "
    let c = apCalls(k)
    if c <= 0:
      s = s & apName(k) & "=NEVER RAN (0 calls -- NOT 'free', NOT measured)"
    else:
      walkSum = walkSum + apNs(k)
      hopsRan = hopsRan + 1
      s = s & apName(k) & "=" & $(apNs(k) div c) & "ns over " & $c &
          " call(s), max " & apUs(apMax(k))
    k = k + 1'i32
  block:
    let pw = apCalls(ApLWhole)
    if hopsRan == 0:
      s = s & ". WALK TOTAL: NOT MEASURED -- no hop bracket ever ran"
    elif pw <= 0:
      s = s & ". WALK TOTAL: INCONCLUSIVE -- " & apName(ApLWhole) &
          " recorded 0 call(s), so there is nothing to divide by"
    else:
      s = s & ". WALK TOTAL (the five hops summed, per " & apName(ApLWhole) &
          " call) = " & $(walkSum div pw) & "ns"
      if hopsRan < 5:
        s = s & " -- but only " & $hopsRan & " of 5 hops ever ran, so this " &
            "total is a FLOOR, not the walk cost"

  # THE INSTRUMENT'S OWN SHARE, measured at enable time, never asserted.
  var calls = 0'i64
  var i = 0'i32
  while i < apSlots():
    calls = calls + apCalls(i)
    i = i + 1'i32
  if apOverhead() >= 0:
    let mine = apOverhead() * calls
    s = s & ". METER OVERHEAD " & $apOverhead() & "ns per bracket pair " &
        "(measured over " & $apCal() & " empty pairs at enable), x " & $calls &
        " pair(s) = " & apUsPer(mine, ticks) & "/tick = " &
        apPctOf(mine, apNs(ApWhole)) & " of " & apName(ApWhole)
  else:
    s = s & ". METER OVERHEAD: NOT MEASURED (calibration failed) -- the " &
        "instrument's share of its own reading is UNKNOWN"
  if apDropped() > 0:
    s = s & ". dropped=" & $apDropped() &
        " (interval negative or >10s -- counted, never silently discarded)"
  s & ". NOTE: CUMULATIVE since the profiler was enabled; it does NOT " &
    "distinguish MENU ticks from IN-RAID ticks, and with the ESP toggle OFF " &
    "the tick returns after hotkeyPoll -- read it beside the admin diag block " &
    "in the same log."
