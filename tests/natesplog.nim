## natesplog -- drive natesp's SHIPPED log-emission policy with synthetic ticks
## and assert that quieting the menu firehose did not also quiet the signal.
##
## ## The check that had to be falsifiable
##
## The change under test stops natesp re-printing a ~3,000-character
## `natesp VERDICT INCONCLUSIVE ...` block every 5 seconds at the main menu.
## The obvious way to get that number down is to print less, and the obvious way
## to get it wrong is to print less of the thing that mattered. CLAUDE.md 9b:
## assert a property of the FINISHED STATE, prefer a NEGATIVE, and never write a
## check that cannot fail.
##
## So this does not assert "the line count went down" alone -- that check cannot
## fail, because deleting every emit passes it. It steps the real `neGateStep`
## over synthetic tick sequences and asserts, together:
##
##   1. A STANDING not-PASS verdict is announced, by name, within 12 cycles
##      (60 s) of every cycle -- forever, over a 600-cycle run. It can never go
##      quiet, and it can never be reported as a heartbeat.
##   2. A CHANGE of verdict class, refusal reason, raid phase, canvas origin or
##      any count crossing zero re-prints the FULL block on the very next cycle.
##   3. An all-PASS run still emits a heartbeat, so silence is never
##      indistinguishable from a dead timer.
##   4. The repeated content DID collapse: a 600-cycle unchanged run emits far
##      fewer than 600 blocks.
##   5. `natespVerbose` restores the firehose exactly: 600 full blocks from 600
##      cycles.
##
## (1)-(3) and (5) are the negatives -- they fail if the policy is too
## aggressive. (4) fails if it is not aggressive enough. A change that satisfies
## only one side is rejected, which is the point.
##
## Mutating `neGateStep` to return `neQuiet` for the `bad` branch makes (1) fail
## with a named gap; mutating it to always return `neFull` makes (4) fail.

import std/syncio

import nelogpol

var checks = 0
var failures = 0

proc check(name: string; ok: bool; detail: string) =
  inc checks
  if ok:
    echo "  ok    " & name
  else:
    inc failures
    echo "  FAIL  " & name & " -- " & detail

# The measured sizes of the two forms, from the live strings in natesp.nim.
const FullBlockChars = 3000
const ShortLineChars = 260

proc reportBytes(name: string; fulls, shorts, cyclesPerMinute: int) =
  ## Not an assertion -- the number the report quotes. Stated here rather than
  ## estimated by hand so it moves when the policy does.
  let bytes = fulls * FullBlockChars + shorts * ShortLineChars
  echo "        " & name & ": " & $fulls & " full + " & $shorts &
       " short over the run = " & $bytes & " bytes"
  discard cyclesPerMinute

type Run = object
  fulls: int
  shorts: int
  beats: int
  quiets: int
  maxGap: int      ## longest run of consecutive cycles that printed NOTHING

proc step(g: var NeGate; r: var Run; gap: var int; verbose: bool;
          sig: string; bad: bool) =
  case neGateStep(g, verbose, sig, bad, NeVerdictBadEvery, NeVerdictBeatEvery)
  of neFull:
    inc r.fulls
    gap = 0
  of neNotPass:
    inc r.shorts
    gap = 0
  of neHeartbeat:
    inc r.beats
    gap = 0
  of neQuiet:
    inc r.quiets
    inc gap
    if gap > r.maxGap: r.maxGap = gap

# ---------------------------------------------------------------------------
# The signatures the live host would produce, built through the SHIPPED
# `neVerdictSig` so a change to it is caught here.
# ---------------------------------------------------------------------------

# INCONCLUSIVE at the main menu: no canvas, nothing built, no contacts, the
# readback never measured. This is the exact state that produced the firehose.
let sigMenu = neVerdictSig(0, 4, 0, 0, 0, 0, 0, 0, 0, false, false)
# The same menu state but the refusal reason moved (no GameWorld -> no canvas).
let sigMenu2 = neVerdictSig(0, 8, 0, 0, 0, 0, 0, 0, 0, false, false)
# The raid phase moved to DEPLOYED; everything else identical.
let sigPhase = neVerdictSig(0, 4, 0, 0, 3, 0, 0, 0, 0, false, false)
# A count crossed zero: one contact now exists.
let sigContact = neVerdictSig(0, 4, 0, 0, 0, 1, 0, 0, 0, false, false)
# PASS in a raid: boxes read back on screen.
let sigPass = neVerdictSig(2, 0, 3, 1, 3, 5, 5, 5, 64, true, true)
# The same PASS with more contacts -- NOT news, must not reprint.
let sigPassMore = neVerdictSig(2, 0, 3, 1, 3, 9, 9, 9, 64, true, true)

echo "natesplog -- natesp log-emission policy, synthetic ticks"

# --- 1 + 4: a standing INCONCLUSIVE, 600 cycles (50 minutes at 5 s) ---------
block:
  var g = newNeGate()
  var r = Run(fulls: 0, shorts: 0, beats: 0, quiets: 0, maxGap: 0)
  var gap = 0
  var i = 0
  while i < 600:
    step(g, r, gap, false, sigMenu, true)
    inc i
  check("a standing INCONCLUSIVE is never silenced",
        r.shorts > 0, "no short re-announcement in 600 cycles")
  check("a standing INCONCLUSIVE is announced at least once per 60s",
        r.maxGap < int(NeVerdictBadEvery),
        "went " & $r.maxGap & " cycles (" & $(r.maxGap * 5) & "s) unannounced")
  check("a not-PASS is NEVER reported as an all-PASS heartbeat",
        r.beats == 0, $r.beats & " heartbeat(s) printed over a not-PASS")
  check("the full block was printed exactly once for an unchanged state",
        r.fulls == 1, $r.fulls & " full blocks")
  check("the repeated block collapsed",
        r.fulls + r.shorts < 60,
        $(r.fulls + r.shorts) & " emissions from 600 cycles")
  reportBytes("standing INCONCLUSIVE, 600 cycles (3000s)", r.fulls, r.shorts, 12)

# --- 5: natespVerbose restores the firehose byte for byte -------------------
block:
  var g = newNeGate()
  var r = Run(fulls: 0, shorts: 0, beats: 0, quiets: 0, maxGap: 0)
  var gap = 0
  var i = 0
  while i < 600:
    step(g, r, gap, true, sigMenu, true)
    inc i
  check("natespVerbose prints the full block on every single cycle",
        r.fulls == 600 and r.shorts == 0 and r.quiets == 0,
        "fulls=" & $r.fulls & " shorts=" & $r.shorts & " quiets=" & $r.quiets)
  reportBytes("natespVerbose, 600 cycles (3000s)", r.fulls, r.shorts, 12)

# --- 2: every kind of change re-prints IN FULL, on the very next cycle ------
proc changeReprints(name: string; a, b: string): void =
  var g = newNeGate()
  var r = Run(fulls: 0, shorts: 0, beats: 0, quiets: 0, maxGap: 0)
  var gap = 0
  var i = 0
  while i < 40:                       # settle into the quiet state
    step(g, r, gap, false, a, true)
    inc i
  let before = r.fulls
  step(g, r, gap, false, b, true)     # the change
  check(name, r.fulls == before + 1,
        "the change did not re-print the full block")

changeReprints("a change of REFUSAL REASON re-prints in full", sigMenu, sigMenu2)
changeReprints("a change of RAID PHASE re-prints in full", sigMenu, sigPhase)
changeReprints("a count crossing ZERO re-prints in full", sigMenu, sigContact)
changeReprints("INCONCLUSIVE -> PASS re-prints in full", sigMenu, sigPass)
changeReprints("PASS -> INCONCLUSIVE re-prints in full", sigPass, sigMenu)

# --- the other half of (2): a COUNTER moving is NOT a change ----------------
block:
  var g = newNeGate()
  var r = Run(fulls: 0, shorts: 0, beats: 0, quiets: 0, maxGap: 0)
  var gap = 0
  var i = 0
  while i < 40:
    step(g, r, gap, false, sigPass, false)
    inc i
  let before = r.fulls
  var k = 0
  while k < 40:
    step(g, r, gap, false, sigPassMore, false)
    inc k
  check("a PASS whose contact count merely grew does NOT re-print",
        r.fulls == before,
        "counters in the signature -- the change detector is an " &
        "unconditional timer again")

# --- 3: an all-PASS run still heartbeats -----------------------------------
block:
  var g = newNeGate()
  var r = Run(fulls: 0, shorts: 0, beats: 0, quiets: 0, maxGap: 0)
  var gap = 0
  var i = 0
  while i < 600:
    step(g, r, gap, false, sigPass, false)
    inc i
  check("an unchanged all-PASS still heartbeats, so silence is never a " &
        "dead timer", r.beats > 0, "no heartbeat in 600 cycles")
  check("an all-PASS heartbeat comes at least every 5 minutes",
        r.maxGap < int(NeVerdictBeatEvery),
        "went " & $r.maxGap & " cycles (" & $(r.maxGap * 5) & "s) silent")
  check("an all-PASS is never announced as a not-PASS",
        r.shorts == 0, $r.shorts & " not-PASS line(s) over an all-PASS run")
  reportBytes("all-PASS, 600 cycles (3000s)", r.fulls, r.shorts + r.beats, 12)

# --- the flicker signature: shape, not size --------------------------------
block:
  let a = neFlickerSig(3, 0, 0, 5, 5, "8,", 3, 1, true)
  let b = neFlickerSig(9, 0, 0, 17, 17, "8,", 3, 1, true)
  let c = neFlickerSig(3, 1, 0, 5, 5, "8,", 3, 1, true)
  let d = neFlickerSig(3, 0, 0, 5, 5, "8,11,", 3, 1, true)
  check("a flicker of the same shape but bigger counts is the same news",
        a == b, "the flicker meter would print every second again")
  check("a flicker that gains a TEARDOWN is new news", a != c, "teardown hidden")
  check("a flicker that gains a GATE REASON is new news", a != d,
        "a new refusal reason would be hidden behind an older one")

echo ""
echo $checks & " check(s), " & $failures & " failure(s)"
if failures > 0:
  quit(1)
