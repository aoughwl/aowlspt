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

  var last = ""
  var quiet = 0
  bi = 0
  while bi < blocks.len:
    let blk = blocks[bi]
    let sig = diagSignature(blk)
    let bad = diagNotPass(blk)
    var emit = ""
    if last.len == 0 or sig != last:
      last = sig
      quiet = 0
      emit = blk
      if bad.len > 0:
        emit.add "warn maps: diag NOT-PASS: " & bad & "\n"
    else:
      inc quiet
      if bad.len > 0:
        if (quiet mod 30) == 0:
          emit = "warn maps: diag STILL NOT-PASS after " & $quiet &
                " unchanged cycle(s): " & bad & "\n"
      elif (quiet mod 150) == 0:
        emit = "info maps: diag all-PASS, unchanged for " & $quiet & " cycle(s)\n"
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
