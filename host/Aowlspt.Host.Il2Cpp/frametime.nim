## THE FRAME METER -- a frame-interval instrument that depends on NOTHING under
## test. The C half, the rationale and the honesty rules are in
## `abi/aowlspt_frametime.h`; this file is only the flag, the formatter and the
## throttled emit.
##
## WHAT IT HOOKS: one call, `ftTick()`, as the FIRST statement of the
## `i == gDrainSlot` branch of `patchFired` -- the host's own
## `EFT.TarkovApplication::Update` drain. That drain is bound by the bridge, not
## by any feature flag, and it ticks menu and raid alike. No detour is installed,
## no name is resolved, nothing in the game is called or dereferenced.
##
## WHY IT SURVIVES EVERY FEATURE BEING OFF: it reads one flag, `frameMeter`, and
## nothing else. It does not consult `rpPhase()` (the raid-phase latch is driven
## from the ESP path), it does not need the maps HUD to have drawn, and it does
## not need a canvas, a camera or a world. With all 27 optional features off it
## still prints a number, which is the entire point.
##
## NO GUARD, deliberately: see the header. Its working set is its own statics
## plus QueryPerformanceCounter, so there is nothing for an `aowl_p_p_seh` to
## catch, and that guard is not re-entrant.

proc cFtTick() {.importc: "aowl_ft_tick", nodecl.}
proc cFtSetEnabled(on: int32) {.importc: "aowl_ft_set_enabled", nodecl.}
proc cFtEnabled(): int32 {.importc: "aowl_ft_enabled", nodecl.}
proc cFtSamples(): int64 {.importc: "aowl_ft_samples", nodecl.}
proc cFtTicksSeen(): int64 {.importc: "aowl_ft_ticks_seen", nodecl.}
proc cFtDropped(): int64 {.importc: "aowl_ft_dropped", nodecl.}
proc cFtMeanNs(): int64 {.importc: "aowl_ft_mean_ns", nodecl.}
proc cFtP50Ns(): int64 {.importc: "aowl_ft_p50_ns", nodecl.}
proc cFtP95Ns(): int64 {.importc: "aowl_ft_p95_ns", nodecl.}
proc cFtMaxNs(): int64 {.importc: "aowl_ft_max_ns", nodecl.}
proc cFtMinNs(): int64 {.importc: "aowl_ft_min_ns", nodecl.}
proc cFtHist(i: int32): int64 {.importc: "aowl_ft_hist", nodecl.}
proc cFtOvf(): int64 {.importc: "aowl_ft_ovf", nodecl.}
proc cFtRecent(): int64 {.importc: "aowl_ft_recent", nodecl.}
proc cFtRMeanNs(): int64 {.importc: "aowl_ft_r_mean_ns", nodecl.}
proc cFtRP50Ns(): int64 {.importc: "aowl_ft_r_p50_ns", nodecl.}
proc cFtRP95Ns(): int64 {.importc: "aowl_ft_r_p95_ns", nodecl.}
proc cFtRMaxNs(): int64 {.importc: "aowl_ft_r_max_ns", nodecl.}
proc cFtRSamples(): int64 {.importc: "aowl_ft_r_samples", nodecl.}
proc cFtPctSat(): int64 {.importc: "aowl_ft_pct_sat", nodecl.}
proc cFtTopEdge(): int64 {.importc: "aowl_ft_top_edge", nodecl.}
proc cFtBins(): int32 {.importc: "aowl_ft_bins", nodecl.}
proc cFtEdge(i: int32): int64 {.importc: "aowl_ft_edge", nodecl.}
proc cFtMinSamples(): int64 {.importc: "aowl_ft_min_samples", nodecl.}
proc cFtRingSize(): int32 {.importc: "aowl_ft_ring_size", nodecl.}

var gFtOn = false
var gFtAt = 0'u64
var gFtPeriodMs = 5000'u64

proc ftMs(ns: int64): string =
  ## ONE unit, everywhere, always spelled. `n/a` for "no samples" -- never a
  ## number, because a zero here reads as "instantaneous" and means "unmeasured".
  if ns < 0: return "n/a"
  $(ns div 1000000) & "." & $((ns mod 1000000) div 100000) & "ms"

proc ftFps(ns: int64): string =
  ## The same measurement in the unit the complaint was made in. Derived from
  ## the interval, never sampled separately, so the two cannot disagree.
  if ns <= 0: return "n/a"
  let hundredths = 100000000000'i64 div ns
  $(hundredths div 100) & "." & $((hundredths mod 100) div 10) & "fps"

proc ftPct(v: int64; what: string): string =
  ## THE ONE PLACE A PERCENTILE MAY BE PRINTED, and it refuses to render the
  ## saturation marker as a duration. The predecessor meter printed INT64_MAX
  ## /1000 as a "p95"; a sentinel dressed as a measurement is a confidently
  ## wrong diagnostic, which this project treats as worse than none.
  if v == cFtPctSat():
    ">= " & ftMs(cFtTopEdge()) & " (histogram SATURATED at the top edge -- " &
      "the " & what & " cannot be placed; treat it as a LOWER BOUND, not a " &
      "measurement)"
  elif v < 0: "n/a"
  else: "<= " & ftMs(v) & " (" & ftFps(v) & ")"

proc ftHistText(): string =
  ## Lifetime histogram, bins with a zero count omitted so the line stays
  ## readable, plus the overflow counter ALWAYS printed -- including when it is
  ## zero, because "nothing fell off the end" is the fact that licenses reading
  ## the percentiles as real.
  var s = ""
  var i = 0'i32
  var prev = 0'i64
  while i < cFtBins():
    let c = cFtHist(i)
    if c > 0:
      if s.len > 0: s = s & " "
      s = s & "(" & ftMs(prev) & "," & ftMs(cFtEdge(i)) & "]=" & $c
    prev = cFtEdge(i)
    inc i
  if s.len == 0: s = "empty"
  s & "  >" & ftMs(cFtTopEdge()) & "=" & $cFtOvf()

proc ftLine(): string =
  ## THREE OUTCOMES, never two. Below `cFtMinSamples()` intervals the verdict is
  ## INCONCLUSIVE -- "not enough samples" is not a pass. There is deliberately NO
  ## budget and NO PASS/FAIL on the frame rate itself: what counts as acceptable
  ## is the human's call, not the meter's, so this reports and does not judge.
  let n = cFtSamples()
  let rn = cFtRecent()          # rebuilds the recent window; must precede r*
  var s = "frameMeter: "
  if n < cFtMinSamples():
    s = s & "INCONCLUSIVE -- " & $n & " interval(s) is below the " &
        $cFtMinSamples() & "-sample threshold, so no distribution is " &
        "reported. (" & $cFtTicksSeen() & " drain tick(s) seen"
    if cFtDropped() > 0:
      s = s & ", " & $cFtDropped() & " interval(s) refused as absurd"
    return s & ".) This is NOT a pass; it means I could not look yet."
  s = s & "LIFETIME n=" & $n & " mean=" & ftMs(cFtMeanNs()) & " (" &
      ftFps(cFtMeanNs()) & ") p50" & ftPct(cFtP50Ns(), "median") & " p95" &
      ftPct(cFtP95Ns(), "95th") & " min=" & ftMs(cFtMinNs()) & " max=" &
      ftMs(cFtMaxNs())
  # THE RECENT WINDOW is the reason this meter is usable during a raid at all:
  # the lifetime figure folds the ~27ms menu frames in with the ~110ms raid
  # frames and reports neither.
  if rn > 0:
    s = s & ". RECENT (last " & $rn & " of " & $cFtRingSize() &
        ") mean=" & ftMs(cFtRMeanNs()) & " (" & ftFps(cFtRMeanNs()) &
        ") p50" & ftPct(cFtRP50Ns(), "median") & " p95" &
        ftPct(cFtRP95Ns(), "95th") & " max=" & ftMs(cFtRMaxNs()) &
        (if rn < cFtMinSamples():
           " [window below the " & $cFtMinSamples() &
           "-sample threshold: INCONCLUSIVE on its own]"
         else: "")
  s = s & ". hist " & ftHistText()
  if cFtDropped() > 0:
    s = s & ". dropped=" & $cFtDropped() &
        " (interval negative or >10s -- counted, never silently discarded)"
  # SAY WHAT IT CANNOT DO, in the line itself. See the header: the only
  # feature-free menu/raid signals on this build are the raid-phase latch (fed
  # by the ESP path -- the very dependency this meter exists to escape) and
  # PreloaderUI::Update (menu-only, but every rider slot on it is flag-gated,
  # so with all features off it never fires).
  s & ". NOTE: this meter does NOT distinguish MENU from IN-RAID -- it reports " &
    "one distribution over every TarkovApplication::Update tick. Read RECENT " &
    "at a known moment, or compare a menu-only run against a raid run."

proc ftTick() =
  ## Called ONCE per Update drain, first, before mainDrain and every rider.
  ## Cost when off: one boolean compare. Cost when on: one QPC read, one 64-bit
  ## divide, ~20 integer ops -- tens of nanoseconds against a 110ms frame. No
  ## allocation, managed or otherwise, on this path.
  if not gFtOn: return
  cFtTick()
  let now = cNowMs()
  if (now - gFtAt) > gFtPeriodMs:
    gFtAt = now
    okLog ftLine()

proc ftConfigure() =
  ## Read at config load, like every other flag. Default OFF per the host's
  ## standing rule -- but it is safe to leave ON permanently, and that is the
  ## point of it: it costs far less than one frame and depends on no other
  ## feature, so the bisection experiment can run with everything else disabled.
  gFtOn = readBoolKey("frameMeter")
  cFtSetEnabled(if gFtOn: 1'i32 else: 0'i32)
  if gFtOn:
    info "frameMeter is set: the frame-interval meter rides the existing " &
         "TarkovApplication::Update drain (gDrainSlot) as its FIRST statement. " &
         "It installs no detour, resolves no name and calls nothing in the " &
         "game -- one QueryPerformanceCounter read and integer math per frame. " &
         "It depends on NO other feature: not raidphase, not natEsp, not the " &
         "maps HUD. It prints mean/p50/p95/max, a histogram and the sample " &
         "count every " & $(gFtPeriodMs div 1000'u64) & "s, over a LIFETIME " &
         "window and a RECENT window of the last " & $cFtRingSize() &
         " intervals. Below " & $cFtMinSamples() & " samples it reports " &
         "INCONCLUSIVE rather than a number. It does NOT distinguish menu " &
         "from raid and says so on every line."
