## mapsdiag -- replay REAL captured maps-diag blocks through the SHIPPED log
## filter and assert that quieting the noise did not also quiet the signal.
##
## ## The check that had to be falsifiable
##
## The change under test makes `onDiagTick` stop re-printing a ~19-line block
## every two seconds. The obvious way to get that number down is to print less,
## and the obvious way to get it wrong is to print less of the thing that
## mattered. CLAUDE.md 9b: assert a property of the FINISHED STATE, prefer a
## NEGATIVE, and never write a check that cannot fail.
##
## So this test does not ask "did the line count go down" alone -- that check
## cannot fail, because deleting the block passes it. It asserts, against 110
## consecutive blocks captured from a real 220-second session
## (`tests/fixtures/mapsdiag-blocks.txt`, taken verbatim out of
## `aowlspt-botnav-on.log`):
##
##   1. EVERY not-PASS verdict present anywhere in the corpus is named in the
##      output. The corpus really contains `art: FAIL` and four INCONCLUSIVE
##      lines; if the filter swallowed any of them this fails.
##   2. Every not-PASS verdict is named WITHIN 30 emitted cycles of the first
##      block that carried it -- i.e. a FAIL can never go more than 60 s
##      unannounced, no matter how long it persists.
##   3. The repeated all-PASS content DID collapse: the emitted line count is a
##      small fraction of the input.
##
## (1) and (2) are the negatives. They fail if the filter is too aggressive.
## (3) fails if it is not aggressive enough. A change that satisfies only one
## of them is rejected, which is the point -- "quieter" and "still honest" have
## to be asserted against each other.
##
## The corpus path can be overridden on argv, so the same binary can be pointed
## at a full session log's blocks without editing anything.

import std/syncio
import std/os

import diagfilter

const Sep = "===BLOCK==="

var checks = 0
var failures = 0

proc check(name: string; ok: bool; detail: string) =
  inc checks
  if ok:
    echo "  ok    " & name
  else:
    inc failures
    echo "  FAIL  " & name & " -- " & detail

proc readAllText(path: string; into: var string): bool =
  into = ""
  var f: File
  if not open(f, path, fmRead):
    return false
  result = false
  try:
    try:
      into = readAll(f)
      result = true
    except:
      result = false
  finally:
    close(f)

proc splitBlocks(text: string): seq[string] =
  ## Split on the `===BLOCK===` marker line. Hand-rolled: `std/strutils.split`
  ## is not in nimony's subset.
  result = @[]
  var cur = ""
  var i = 0
  while i < text.len:
    var e = i
    while e < text.len and text[e] != '\n':
      inc e
    var line = ""
    var k = i
    while k < e:
      if text[k] != '\r':
        line.add text[k]
      inc k
    if line == Sep:
      result.add cur
      cur = ""
    else:
      cur.add line
      cur.add "\n"
    i = e + 1
  if cur.len > 0:
    result.add cur

proc countLines(s: string): int =
  result = 0
  var i = 0
  while i < s.len:
    if s[i] == '\n':
      inc result
    inc i
  if s.len > 0 and s[s.len - 1] != '\n':
    inc result

proc contains(hay, needle: string): bool =
  if needle.len == 0:
    return true
  if needle.len > hay.len:
    return false
  var i = 0
  while i + needle.len <= hay.len:
    var j = 0
    var same = true
    while j < needle.len:
      if hay[i + j] != needle[j]:
        same = false
        break
      inc j
    if same:
      return true
    inc i
  result = false

proc scanNotPass(blk: string; into: var seq[string]) =
  ## What the corpus CONTAINS, parsed INDEPENDENTLY of `diagfilter`.
  ##
  ## This proc exists because the first version of this test did not have it,
  ## and that version was a check that could not fail -- exactly the defect
  ## CLAUDE.md 9b names. It built its list of "verdicts that must survive" by
  ## calling `diagNotPass`, the very proc under test. A mutation run proved it:
  ## `diagNotPass` was stubbed to `return ""`, the expected-verdict list came
  ## back EMPTY, all seventeen survival assertions silently disappeared, and the
  ## suite reported `PASS 2 checks` against a filter that swallowed every
  ## failure in the corpus.
  ##
  ## So the expectation is derived here, from the raw text, by different code:
  ## a line whose first token after the colon is FAIL or INCONCLUSIVE. And
  ## `main` asserts a FLOOR on how many it found, so an expectation list that
  ## collapses to nothing is itself a FAIL rather than a vacuous pass.
  var i = 0
  while i < blk.len:
    var e = i
    while e < blk.len and blk[e] != '\n':
      inc e
    var c = -1
    var k = i
    while k < e:
      if blk[k] == ':':
        c = k
        break
      inc k
    if c >= 0:
      var v = c + 1
      while v < e and (blk[v] == ' ' or blk[v] == '\t'):
        inc v
      var tok = ""
      var t = v
      while t < e and blk[t] != ' ' and blk[t] != '\r':
        tok.add blk[t]
        inc t
      if tok == "FAIL" or tok == "INCONCLUSIVE":
        var lab = ""
        var m = i
        while m < c:
          if blk[m] != ' ' and blk[m] != '\t' and blk[m] != '\r':
            lab.add blk[m]
          inc m
        let key = lab & ":" & tok
        var seen = false
        for x in into:
          if x == key:
            seen = true
        if not seen:
          into.add key
    i = e + 1

proc has(xs: seq[string]; s: string): bool =
  for x in xs:
    if x == s:
      return true
  result = false

proc emitName(e: DiagEmit): string =
  ## `$` on an enum is not relied on here; the name is spelled out so a failure
  ## message names the outcome instead of printing an ordinal.
  case e
  of DeNone: "DeNone"
  of DeBlock: "DeBlock (full block)"
  of DeStill: "DeStill (STILL NOT-PASS warn)"
  of DeHeartbeat: "DeHeartbeat"

# ---------------------------------------------------------------------------
# THE `draw` VERDICT AND THE REPEAT POLICY.
#
# Both were live defects, MEASURED at the MAIN MENU on 2026-09-02:
#   `warn Maps: diag NOT-PASS: ... draw:FAIL ...` on every boot, then
#   `STILL NOT-PASS after N unchanged cycle(s)` every 60 s forever.
# Every other line in that block correctly read INCONCLUSIVE; only `draw` said
# FAIL, on a state -- no raid, so nothing to draw -- in which no input could
# have made it say anything else. CLAUDE.md 9b.
#
# These checks are written the way that section demands: each asserts the
# FINISHED verdict string, and each is paired with the input that produces the
# OPPOSITE verdict, so neither can pass vacuously. In particular the FAIL is
# asserted to still be REACHABLE -- a fix that merely deleted the FAIL branch
# would pass the "menu is INCONCLUSIVE" check and fail this one.
# ---------------------------------------------------------------------------

proc verdictOf(line: string): string =
  ## The bare verdict word at the head of a diag line. Uses the SHIPPED parser
  ## (`diagNotPass` over a synthetic one-line block) rather than a `startsWith`
  ## written here, so a line the real filter would classify differently cannot
  ## quietly pass this suite.
  let tagged = diagNotPass("  draw : " & line & "\n")
  if tagged == "draw:" & DiagFail: return DiagFail
  if tagged == "draw:" & DiagIncon: return DiagIncon
  if tagged.len == 0: return DiagPass
  "?" & tagged

const MenuWhy = "world live and a pose read, but the local player is NOT in " &
                "the live AllAlivePlayersList"

proc drawVerdictChecks() =
  echo ""
  echo "the `draw` verdict -- the menu FAIL"

  # THE DEFECT, exactly as measured: HUD on, region armed, the callback
  # dispatched thousands of times at the menu, zero draws, no raid.
  let menu = drawVerdict(true, true, 4000'i64, 0'i64, 0'i64, 0'i64, 0'i64,
                         false, MenuWhy)
  check("armed + dispatched + 0 draws + NO RAID reads INCONCLUSIVE",
        verdictOf(menu) == DiagIncon,
        "read " & verdictOf(menu) & " at the main menu: " & menu)
  check("and it names the raid gate as the reason, not a draw failure",
        contains(menu, "the raid gate is CLOSED") and contains(menu, MenuWhy),
        "the reason given was: " & menu)
  check("and it says in words that this is not a defect",
        contains(menu, "not in a raid: a zero draw count here is not a defect"),
        menu)

  # THE POSITIVE CONTROL FOR THE NEGATIVE. Same numbers, gate OPEN. If this
  # does not fail, the fix removed the check instead of gating it.
  let raid = drawVerdict(true, true, 4000'i64, 0'i64, 0'i64, 0'i64, 0'i64,
                         true, "active raid")
  check("the SAME zero-draw state with the raid gate OPEN still reads FAIL",
        verdictOf(raid) == DiagFail,
        "read " & verdictOf(raid) & " in a live raid with 0 draws -- the FAIL " &
        "is no longer reachable, so the check can no longer fail: " & raid)
  check("and the FAIL still points at `positions` as the thing to read next",
        contains(raid, "positions"), raid)

  # An unarmed region is its OWN reason. Before this it was folded into the
  # same FAIL, which blamed the mod for a host flag being off.
  let unarmed = drawVerdict(true, false, 0'i64, 0'i64, 0'i64, 0'i64, 0'i64,
                            true, "active raid")
  check("registered but NOT armed reads INCONCLUSIVE naming sharedRegion",
        verdictOf(unarmed) == DiagIncon and contains(unarmed, "sharedRegion"),
        unarmed)
  let noHud = drawVerdict(false, false, 0'i64, 0'i64, 0'i64, 0'i64, 0'i64,
                          false, MenuWhy)
  check("no HUD registered reads INCONCLUSIVE",
        verdictOf(noHud) == DiagIncon, noHud)
  let neverRan = drawVerdict(true, true, 0'i64, 0'i64, 0'i64, 0'i64, 0'i64,
                             true, "active raid")
  check("armed in a raid but never once dispatched reads INCONCLUSIVE",
        verdictOf(neverRan) == DiagIncon, neverRan)

  # A PASS is earned by primitives, and it is KEPT after the raid ends -- the
  # gate must not decay a real measurement back into "I could not look".
  let drew = drawVerdict(true, true, 4000'i64, 3900'i64, 12'i64, 0'i64, 0'i64,
                         true, "active raid")
  check("drawing 3900 frames with 12 blips in a raid reads PASS",
        verdictOf(drew) == DiagPass, drew)
  let afterRaid = drawVerdict(true, true, 9000'i64, 3900'i64, 12'i64, 0'i64,
                              0'i64, false, MenuWhy)
  check("that PASS SURVIVES the raid ending -- it does not decay to INCONCLUSIVE",
        verdictOf(afterRaid) == DiagPass,
        "after extract the earned PASS became " & verdictOf(afterRaid) &
        ", so a session that demonstrably worked reports that it could not " &
        "look: " & afterRaid)
  let ring = drawVerdict(true, true, 4000'i64, 3900'i64, 0'i64, 0'i64, 0'i64,
                         true, "active raid")
  check("drawn with ZERO blips is a PASS that says the ring is empty",
        verdictOf(ring) == DiagPass and contains(ring, "0 blip"), ring)

  # The two countable clauses are appended in every branch, including the new
  # INCONCLUSIVE one -- an overlay open at the menu is still worth counting.
  let masked = drawVerdict(true, true, 4000'i64, 0'i64, 0'i64, 77'i64, 5'i64,
                           false, MenuWhy)
  check("the masked/gated dispatch counts survive on the INCONCLUSIVE branch",
        contains(masked, "77 dispatch(es) SKIPPED") and
        contains(masked, "5 dispatch(es) GATED OFF"), masked)

proc repeatPolicyChecks() =
  echo ""
  echo "the STILL NOT-PASS repeat schedule -- raid vs menu"

  const Sig = "draw=INCONCLUSIVE;phase=MENU;"

  # 1. AT THE MENU: announced once when it appears, then once per PHASE.
  var st = DiagRepeatState(sig: "", quiet: 0'i64, lastPhase: -1, announced: false)
  var first = diagStep(st, Sig, true, false, 1)
  check("the first menu cycle prints the FULL block (nothing is suppressed)",
        first == DeBlock, "emitted " & emitName(first) & " on the very first cycle")
  var stills = 0
  var i = 0
  while i < 600:            # 600 cycles == 20 minutes at the menu
    if diagStep(st, Sig, true, false, 1) == DeStill: inc stills
    inc i
  check("20 minutes of an UNCHANGED menu not-PASS re-announces ZERO times",
        stills == 0,
        "it warned " & $stills & " more time(s) after the full block -- the " &
        "old schedule warned 20")

  # 2. and a PHASE CHANGE breaks the silence, on the cycle it happens.
  let onPhase = diagStep(st, Sig, true, false, 2)   # MENU -> LOADING
  check("a host phase change re-announces the standing not-PASS immediately",
        onPhase == DeStill, "emitted " & emitName(onPhase) & " on the phase transition")
  var afterPhase = 0
  i = 0
  while i < 200:
    if diagStep(st, Sig, true, false, 2) == DeStill: inc afterPhase
    inc i
  check("and then goes quiet again within the new phase",
        afterPhase == 0, "warned " & $afterPhase & " more time(s) in one phase")

  # 3. IN A RAID the schedule is UNCHANGED: every 30 cycles, forever. This is
  #    the control for the whole change -- quieting the menu must not quiet the
  #    raid, which is the only place a standing FAIL is real news.
  var rs = DiagRepeatState(sig: "", quiet: 0'i64, lastPhase: -1, announced: false)
  discard diagStep(rs, Sig, true, true, 3)
  var raidStills = 0
  var longestGap = 0
  var gap = 0
  i = 0
  while i < 600:
    gap = gap + 1
    if diagStep(rs, Sig, true, true, 3) == DeStill:
      inc raidStills
      if gap > longestGap: longestGap = gap
      gap = 0
    inc i
  check("600 raid cycles with a standing FAIL warn 20 times (every 60s)",
        raidStills == 20, "warned " & $raidStills & " time(s)")
  check("and no raid cycle ever goes more than 60s unannounced",
        longestGap <= 30 and longestGap > 0,
        "the longest silence was " & $longestGap & " cycle(s) (" &
        $(longestGap * 2) & "s)")

  # 4. AN ALL-PASS BLOCK still heartbeats, in a raid AND at the menu -- silence
  #    must never be the same thing as health.
  var hs = DiagRepeatState(sig: "", quiet: 0'i64, lastPhase: -1, announced: false)
  discard diagStep(hs, "draw=PASS;", false, false, 1)
  var beats = 0
  i = 0
  while i < 600:
    if diagStep(hs, "draw=PASS;", false, false, 1) == DeHeartbeat: inc beats
    inc i
  check("an all-PASS menu block still heartbeats (4 times in 20 minutes)",
        beats == 4, "beat " & $beats & " time(s) -- a silent instrument is " &
        "indistinguishable from a dead one")

  # 5. AND THE THING THE QUIETING MUST NOT DO: a verdict that MOVES still
  #    re-prints in full on the cycle it moves, menu or not.
  var ms = DiagRepeatState(sig: "", quiet: 0'i64, lastPhase: -1, announced: false)
  discard diagStep(ms, Sig, true, false, 1)
  i = 0
  while i < 100:
    discard diagStep(ms, Sig, true, false, 1)
    inc i
  let moved = diagStep(ms, "draw=FAIL;phase=MENU;", true, false, 1)
  check("a CHANGED verdict re-prints the full block even after 100 quiet cycles",
        moved == DeBlock,
        "emitted " & emitName(moved) & " -- the quieting is suppressing real news")

proc main(): int =
  var path = "tests\\fixtures\\mapsdiag-blocks.txt"
  var i = 1
  while i < paramCount() + 1:
    path = paramStr(i)
    inc i

  var text = ""
  if not readAllText(path, text):
    # THREE OUTCOMES. Not being able to read the corpus is INCONCLUSIVE, and it
    # exits non-zero, because "I could not look" must never read as a pass.
    echo "INCONCLUSIVE  could not read the corpus at " & path
    echo "              Nothing was replayed and nothing is proven."
    return 2

  let blocks = splitBlocks(text)
  if blocks.len < 10:
    echo "INCONCLUSIVE  the corpus at " & path & " held only " & $blocks.len &
         " block(s); this test needs a real session to say anything."
    return 2

  # --- what the corpus actually contains, established BEFORE any filtering ---
  var wanted: seq[string] = @[]      # every distinct `label:VERDICT` not-PASS
  var firstSeen: seq[int] = @[]      # the block index it first appeared at
  var inputLines = 0
  var bi = 0
  while bi < blocks.len:
    inputLines = inputLines + countLines(blocks[bi])
    # INDEPENDENT of diagfilter -- see `scanNotPass`. Deriving the expectation
    # from the code under test is what made this suite unfalsifiable once.
    let before = wanted.len
    scanNotPass(blocks[bi], wanted)
    var n = before
    while n < wanted.len:
      firstSeen.add bi
      inc n
    inc bi

  echo "corpus: " & $blocks.len & " block(s), " & $inputLines & " line(s), " &
       $wanted.len & " distinct not-PASS verdict(s)"
  var w = 0
  while w < wanted.len:
    echo "        not-PASS present in the input: " & wanted[w] &
         " (first at block " & $firstSeen[w] & ")"
    inc w

  # --- replay through the SHIPPED policy, exactly as onDiagTick applies it ---
  #
  # This mirrors the branch structure in `mods/maps/maps.nim onDiagTick`. It is
  # a mirror, and that is a real limitation stated plainly: it proves the
  # FILTER (diagfilter.nim, the shipped code) and the POLICY SHAPE, not the
  # literal statements in maps.nim.
  var emitted = ""            # everything the log would have received
  var emittedLines = 0
  var announcedAt: seq[int] = @[]   # block index at which each `wanted` was named
  var wi = 0
  while wi < wanted.len:
    announcedAt.add -1
    inc wi

  # The replay drives the SHIPPED policy proc (`diagStep`), not a copy of it.
  # It used to re-implement the `mod 30` / `mod 150` ladder here, which meant
  # the corpus could keep passing while the shipped schedule drifted away from
  # it. The corpus is a RAID session, so it is replayed with the raid gate OPEN
  # -- that is the schedule this section is about. The menu schedule is asserted
  # separately, in `repeatPolicyChecks`.
  var st = DiagRepeatState(sig: "", quiet: 0'i64, lastPhase: -1, announced: false)
  bi = 0
  while bi < blocks.len:
    let blk = blocks[bi]
    let sig = diagSignature(blk)
    let bad = diagNotPass(blk)
    var emit = ""
    case diagStep(st, sig, bad.len > 0, true, 3)
    of DeBlock:
      emit = blk
      if bad.len > 0:
        emit.add "warn maps: diag NOT-PASS: " & bad & "\n"
    of DeStill:
      emit = "warn maps: diag STILL NOT-PASS after " & $st.quiet &
             " unchanged cycle(s): " & bad & "\n"
    of DeHeartbeat:
      emit = "info maps: diag all-PASS, unchanged for " & $st.quiet & " cycle(s)\n"
    of DeNone:
      discard
    if emit.len > 0:
      emitted.add emit
      emittedLines = emittedLines + countLines(emit)
      var q = 0
      while q < wanted.len:
        if announcedAt[q] < 0 and contains(emit, wanted[q]):
          announcedAt[q] = bi
        inc q
    inc bi

  echo ""
  echo "emitted: " & $emittedLines & " line(s) from " & $inputLines &
       " line(s) of input"

  # --- 0. THE FLOOR. Without this, an empty expectation list makes every
  #        assertion below disappear and the suite reports PASS having proved
  #        nothing. That is not hypothetical: it is what this test did before
  #        `scanNotPass` existed, and a mutation run is what exposed it.
  check("the corpus really contains failures to be tested against",
        wanted.len >= 5,
        "only " & $wanted.len & " not-PASS verdict(s) were found in " &
        $blocks.len & " block(s). Either the corpus is not a real session or " &
        "the scanner is broken -- either way NOTHING below is proven and this " &
        "result is INCONCLUSIVE, not a pass")
  var sawFail = false
  var q = 0
  while q < wanted.len:
    if contains(wanted[q], ":FAIL"):
      sawFail = true
    inc q
  check("the corpus contains at least one hard FAIL, not only INCONCLUSIVE",
        sawFail,
        "no `:FAIL` verdict in the corpus; the strongest case -- a real " &
        "failure surviving the filter -- is UNTESTED here")

  # --- 1. THE NEGATIVE: nothing that failed was swallowed ---
  q = 0
  while q < wanted.len:
    check("the not-PASS verdict " & wanted[q] & " survives the filtering",
          announcedAt[q] >= 0,
          "it appears in the input and NEVER appears in the output -- the " &
          "filter is hiding a failure, which is worse than the noise it removed")
    inc q

  # --- 2. and it surfaced promptly, not once at the very end ---
  q = 0
  while q < wanted.len:
    if announcedAt[q] >= 0:
      let lag = announcedAt[q] - firstSeen[q]
      check(wanted[q] & " is named within 30 cycles of first appearing",
            lag >= 0 and lag <= 30,
            "first seen at block " & $firstSeen[q] & ", first named at block " &
            $announcedAt[q] & " -- a lag of " & $lag & " cycles (" &
            $(lag * 2) & "s)")
    inc q

  # --- 3. and the repeated PASS content really did collapse ---
  check("the repeated block collapsed to under a fifth of the input",
        emittedLines * 5 < inputLines,
        "emitted " & $emittedLines & " of " & $inputLines &
        " line(s); the filter is not actually quieting anything")

  # --- and the guard against the opposite failure: it must not go silent ---
  check("the output is not empty",
        emittedLines > 0,
        "nothing at all was emitted -- a silent instrument is not a quiet one")

  drawVerdictChecks()
  repeatPolicyChecks()

  echo ""
  if failures == 0:
    echo "PASS  " & $checks & " checks: every not-PASS verdict in the corpus " &
         "survives, promptly, while the repeated PASS block collapses from " &
         $inputLines & " to " & $emittedLines & " line(s)"
    result = 0
  else:
    echo "FAIL  " & $failures & " of " & $checks & " checks"
    result = 1

quit(main())
