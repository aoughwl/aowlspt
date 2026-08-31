## THE DRAIN PROFILER -- the flag, the row names, the ranking and the throttled
## emit. The C half, the rationale and the honesty rules are in
## `abi/aowlspt_drainprof.h`.
##
## WHAT IT HOOKS: nothing new. A pair of QPC reads around call sites that
## already exist in `patchFired`'s two drain branches, plus one pair around
## `cInvokeCallback` in `runDue` for the per-mod breakdown of `mainDrain`. No
## detour, no name resolved, nothing in the game called or dereferenced.
##
## IT OPENS NO GUARD, and that is the point of where the brackets sit: several
## riders (`natEspDrainTick`, `camDrainTick`, `cwDrainTick`, `rpDrainTick`) open
## their own single `aowl_p_p_seh` internally, and that guard is NOT re-entrant.
## Every bracket here is strictly OUTSIDE the bracketed rider's guard.
##
## UNITS: every printed number is MICROSECONDS with `us` attached. There is no
## unitless duration in this file's output.

proc cDpNow(): int64 {.importc: "aowl_dp_now", nodecl.}
proc cDpAdd(slot: int32; t0: int64) {.importc: "aowl_dp_add", nodecl.}
proc cDpFrame() {.importc: "aowl_dp_frame", nodecl.}
proc cDpControlBody() {.importc: "aowl_dp_control_body", nodecl.}
proc cDpSetEnabled(on: int32) {.importc: "aowl_dp_set_enabled", nodecl.}
proc cDpEnabled(): int32 {.importc: "aowl_dp_enabled", nodecl.}
proc cDpModSlot(modIndex: int32): int32 {.importc: "aowl_dp_mod_slot", nodecl.}
proc cDpNs(i: int32): int64 {.importc: "aowl_dp_ns", nodecl.}
proc cDpCalls(i: int32): int64 {.importc: "aowl_dp_calls", nodecl.}
proc cDpMax(i: int32): int64 {.importc: "aowl_dp_max", nodecl.}
proc cDpFrames(): int64 {.importc: "aowl_dp_frames", nodecl.}
proc cDpFrameNs(): int64 {.importc: "aowl_dp_frame_ns", nodecl.}
proc cDpDropped(): int64 {.importc: "aowl_dp_dropped", nodecl.}
proc cDpOverhead(): int64 {.importc: "aowl_dp_overhead", nodecl.}
proc cDpTop(): int32 {.importc: "aowl_dp_top", nodecl.}
proc cDpSlots(): int32 {.importc: "aowl_dp_slots", nodecl.}
proc cDpMod0(): int32 {.importc: "aowl_dp_mod0", nodecl.}
proc cDpModOther(): int32 {.importc: "aowl_dp_modother", nodecl.}
proc cDpCtrl(): int32 {.importc: "aowl_dp_ctrl", nodecl.}
proc cDpCtrlIters(): int32 {.importc: "aowl_dp_ctrl_iters", nodecl.}
proc cDpMinFrames(): int64 {.importc: "aowl_dp_min_frames", nodecl.}
proc cDpCal(): int32 {.importc: "aowl_dp_cal", nodecl.}
proc cDpAccountedNs(): int64 {.importc: "aowl_dp_accounted_ns", nodecl.}

## The slot numbers, in ONE place. They must stay in lockstep with the
## `AOWL_DP_*` defines in `abi/aowlspt_drainprof.h` and with `DpNames` below;
## the bracket call sites in `patchFired` use these names and never a literal.
const
  DpFt        = 0'i32
  DpMain      = 1'i32
  DpInspect   = 2'i32
  DpModeSkip  = 3'i32
  DpUiState   = 4'i32
  DpCursor    = 5'i32
  DpSplRebr   = 6'i32
  DpAutoRaid  = 7'i32
  DpNatRaid   = 8'i32
  DpRaidPhase = 9'i32
  DpCam       = 10'i32
  DpNatEsp    = 11'i32
  DpCw        = 12'i32
  DpRDrain    = 13'i32
  DpRCursor   = 14'i32
  DpRCam      = 15'i32

var gDpOn = false
var gDpAt = 0'u64
var gDpPeriodMs = 5000'u64

const DpNames: array[17, string] = [
  "ftTick",             # 0
  "mainDrain",          # 1  -- includes ALL mod callbacks via runDue
  "inspectDrain",       # 2
  "modeSkipDrain",      # 3
  "uiStateDrain",       # 4
  "cursorFreeDrain",    # 5
  "splRebrandDrain",    # 6
  "autoRaidDrain",      # 7
  "nativeRaidDrain",    # 8
  "rpDrain",            # 9
  "camDrain",           # 10
  "natEspDrain",        # 11
  "cwDrain",            # 12
  "renderDrain",        # 13
  "cursorFreeRender",   # 14
  "camRender",          # 15
  "CONTROL(512 adds)"]  # 16

proc dpName(i: int32): string =
  ## Never invents a label. A nested row says which modIndex it is, and the
  ## overflow row says plainly that it is a bucket of several.
  if i >= 0'i32 and i < 17'i32: return DpNames[int(i)]
  if i == cDpModOther(): return "mod[OTHER: every modIndex outside the direct range, POOLED]"
  return "mod[" & $(int(i) - int(cDpMod0())) & "]"

proc dpUsPer(nsTotal, frames: int64): string =
  ## ONE unit, always spelled: microseconds PER FRAME, to one decimal. `n/a` for
  ## "no frames" -- never a number, because a zero here reads as "free" and
  ## means "unmeasured".
  if frames <= 0: return "n/a"
  let tenths = (nsTotal * 10'i64) div (frames * 1000'i64)
  $(tenths div 10) & "." & $(tenths mod 10) & "us"

proc dpUs(ns: int64): string =
  if ns < 0: return "n/a"
  let tenths = (ns * 10'i64) div 1000'i64
  $(tenths div 10) & "." & $(tenths mod 10) & "us"

proc dpPctOf(part, whole: int64): string =
  if whole <= 0: return "n/a"
  let t = (part * 1000'i64) div whole
  $(t div 10) & "." & $(t mod 10) & "%"

proc dpControl() =
  ## The positive control, run through its own bracket, in the same tick, on the
  ## same clock as every other row. Without it "the meter is lying" cannot be
  ## ruled out.
  if not gDpOn: return
  let t = cDpNow()
  cDpControlBody()
  cDpAdd(cDpCtrl(), t)

proc dpLine(): string =
  ## THREE OUTCOMES, never two. Below `cDpMinFrames()` bracketed frames the
  ## verdict is INCONCLUSIVE; "not enough frames" is not a pass. There is no
  ## budget and no PASS/FAIL on any row: this reports and does not judge.
  let frames = cDpFrames()
  var s = "drainProf: "
  if frames < cDpMinFrames():
    s = s & "INCONCLUSIVE -- " & $frames & " bracketed frame(s) is below the " &
        $cDpMinFrames() & "-frame threshold, so no ranking is reported."
    if cDpDropped() > 0:
      s = s & " (" & $cDpDropped() & " interval(s) refused as absurd.)"
    return s & " This is NOT a pass; it means I could not look yet."

  let total = cDpFrameNs()
  let acc = cDpAccountedNs()

  # THE CONTROL FIRST, because every row below it is void if it is wrong.
  let ctrl = cDpCtrl()
  let ctrlPer = cDpNs(ctrl)
  s = s & "CONTROL " & $cDpCtrlIters() & " integer adds = " &
      dpUsPer(ctrlPer, cDpCalls(ctrl)) & "/call over " & $cDpCalls(ctrl) &
      " call(s) (expected: sub-microsecond, order 0.1-1.0us. If this reads " &
      "0.0us or reads MILLISECONDS the clock or the bracket is broken and " &
      "EVERY row below is VOID). "

  s = s & "frame=" & dpUsPer(total, frames) & " over " & $frames &
      " frame(s). RANKED per-frame cost, us:"

  # Selection sort over the top-level rows only. 17 elements, once every 5s,
  # off the per-frame path entirely.
  let top = int(cDpTop())
  var order: seq[int32] = @[]
  var used: seq[bool] = @[]
  for i in 0 ..< top:
    order.add int32(i)
    used.add false
  var out2: seq[int32] = @[]
  for k in 0 ..< top:
    var best = -1
    var bestNs = -1'i64
    for i in 0 ..< top:
      if not used[i] and cDpNs(int32(i)) > bestNs:
        bestNs = cDpNs(int32(i)); best = i
    if best < 0: break
    used[best] = true
    out2.add int32(best)

  var silent = ""
  for idx in out2:
    let n = cDpNs(idx)
    let c = cDpCalls(idx)
    if c == 0:
      if silent.len > 0: silent = silent & ", "
      silent = silent & dpName(idx)
    else:
      s = s & " " & dpName(idx) & "=" & dpUsPer(n, frames) & "/frame (" &
          dpPctOf(n, total) & " of frame, " & $c & " call(s), max " &
          dpUs(cDpMax(idx)) & ")"
  if silent.len > 0:
    s = s & ". NEVER CALLED (0 calls, not 'free'): " & silent

  # THE BREAKDOWN OF mainDrain. Nested inside row 1, so it is stated as a
  # breakdown and is NEVER added to the top-level sum.
  var modTxt = ""
  var m = cDpMod0()
  while m < cDpSlots():
    if cDpCalls(m) > 0:
      if modTxt.len > 0: modTxt = modTxt & " "
      modTxt = modTxt & dpName(m) & "=" & dpUsPer(cDpNs(m), frames) &
               "/frame (" & $cDpCalls(m) & " cb, max " & dpUs(cDpMax(m)) & ")"
    m = m + 1'i32
  if modTxt.len > 0:
    s = s & ". INSIDE mainDrain (a BREAKDOWN of it, NOT extra cost -- do not " &
        "add these to the sum): " & modTxt
  else:
    s = s & ". INSIDE mainDrain: no mod callback ran in this window"

  # THE ARITHMETIC, said out loud whichever way it lands.
  let unex = total - acc
  s = s & ". accounted=" & dpUsPer(acc, frames) & " of " &
      dpUsPer(total, frames) & " (" & dpPctOf(acc, total) & ")"
  if unex > 0:
    s = s & "; " & dpPctOf(unex, total) & " (" & dpUsPer(unex, frames) &
        "/frame) is OUTSIDE every bracket and is UNEXPLAINED -- it is not " &
        "host rider code, it is the game's own Update plus everything else in " &
        "the frame"
  else:
    s = s & "; the brackets sum to AT OR ABOVE the frame interval, which is " &
        "IMPOSSIBLE for disjoint brackets -- treat this line as BROKEN, not " &
        "as a result"

  # THE INSTRUMENT'S OWN SHARE, measured at enable time, never asserted.
  var calls = 0'i64
  var i2 = 0'i32
  while i2 < cDpSlots():
    calls = calls + cDpCalls(i2)
    i2 = i2 + 1'i32
  if cDpOverhead() >= 0:
    let mine = cDpOverhead() * calls
    s = s & ". METER OVERHEAD " & $cDpOverhead() & "ns per bracket pair " &
        "(measured over " & $cDpCal() & " empty pairs at enable), x " & $calls &
        " pair(s) = " & dpUsPer(mine, frames) & "/frame = " &
        dpPctOf(mine, total) & " of the frame"
  else:
    s = s & ". METER OVERHEAD: NOT MEASURED (calibration failed) -- the " &
        "instrument's share of its own reading is UNKNOWN"
  if cDpDropped() > 0:
    s = s & ". dropped=" & $cDpDropped() &
        " (interval negative or >10s -- counted, never silently discarded)"
  s & ". NOTE: this does NOT distinguish MENU from IN-RAID; read it beside the " &
    "raid-phase line in the same log."

proc dpReport() =
  ## Called last in the update drain branch, after every rider. Throttled.
  if not gDpOn: return
  let now = cNowMs()
  if (now - gDpAt) > gDpPeriodMs:
    gDpAt = now
    okLog dpLine()
    # The DECOMPOSITION of the splRebrandDrain row, emitted in the same window
    # and on the same clock, so the row and its phases can never be read from
    # two different runs. `splProfLines` lives in `splrebrand.nim`, which is
    # `include`d before this file.
    var splLines = splProfLines()
    var li = 0
    while li < splLines.len:
      okLog splLines[li]
      li = li + 1

proc dpConfigure() =
  gDpOn = readBoolKey("drainProfiler")
  cDpSetEnabled(if gDpOn: 1'i32 else: 0'i32)
  if gDpOn:
    info "drainProfiler is set: every rider on the TarkovApplication::Update " &
         "drain and on the render drain is bracketed with QueryPerformance" &
         "Counter, OUTSIDE each rider's own aowl_p_p_seh (that guard is not " &
         "re-entrant). It installs no detour, resolves no name and calls " &
         "nothing in the game. It ranks the riders by total cost and prints " &
         "one line every " & $(gDpPeriodMs div 1000'u64) & "s, in " &
         "MICROSECONDS PER FRAME, with an accounted-for percentage against a " &
         "frame interval it measures itself on the same clock. It carries a " &
         "POSITIVE CONTROL of " & $cDpCtrlIters() & " integer adds through " &
         "the same bracket -- expected order 0.1-1.0us; 0.0us or milliseconds " &
         "means the meter is lying and the line is void. Below " &
         $cDpMinFrames() & " frames it reports INCONCLUSIVE rather than a " &
         "number. The per-mod rows are a BREAKDOWN of mainDrain, not extra " &
         "cost."
