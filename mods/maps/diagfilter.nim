## The diag-block log filter, on its own module so it can be TESTED.
##
## It lives outside `maps.nim` because the check that actually matters -- "a
## real FAIL still surfaces after the filtering" -- has to be runnable against
## real captured text, and `maps.nim` cannot be linked outside the host. Every
## proc here is pure: string in, string out. No game memory, no host call, no
## global state.
##
## WHY THIS EXISTS AT ALL. `onDiagTick` documented itself as printing "on any
## CHANGE", and it compared the whole assembled block against the previous
## whole block. That block carries live counters -- `ticks=`, `published=`,
## frame counts, microsecond means -- which move on every single tick. So the
## comparison was ALWAYS unequal and the change-detection suppressed nothing:
## it was an unconditional timer wearing a change-detector's comment. MEASURED
## on one 761 s session (`aowlspt-botnav-on.log`): 370 blocks emitted against
## 380 ticks elapsed -- 97% -- and 10,192 of that log's 25,289 lines (40.3%)
## were this one block repeating.
##
## The replacement compares a SIGNATURE of the VERDICTS, not the text.

const DiagPass* = "PASS"
const DiagFail* = "FAIL"
const DiagIncon* = "INCONCLUSIVE"

proc isDigitCh(c: char): bool =
  c >= '0' and c <= '9'

proc lineEndAt(text: string; i: int): int =
  ## Index of the '\n' ending the line that starts at `i`, or `text.len`.
  result = i
  while result < text.len and text[result] != '\n':
    inc result

proc labelOf(text: string; i, colon: int): string =
  ## The line's label -- everything before the colon, whitespace squeezed out --
  ## so `  drawGate     : PASS ...` yields `drawGate`.
  result = ""
  var k = i
  while k < colon:
    if text[k] != ' ' and text[k] != '\r' and text[k] != '\t':
      result.add text[k]
    inc k

proc colonOf(text: string; i, e: int): int =
  ## Index of the first ':' on [i, e), or -1. A line with no colon is prose
  ## (the `maps diag:` header's continuation lines, a wrapped reason) and
  ## contributes nothing to the signature.
  result = -1
  var c = i
  while c < e:
    if text[c] == ':':
      return c
    inc c

proc firstToken(text: string; c, e: int): string =
  ## The first whitespace-delimited token after the colon at `c`.
  result = ""
  var v = c + 1
  while v < e and (text[v] == ' ' or text[v] == '\t'):
    inc v
  var t = v
  while t < e and text[t] != ' ' and text[t] != '\r':
    result.add text[t]
    inc t

proc diagSignature*(text: string): string =
  ## A stable key for "what the block is CURRENTLY SAYING", with the counters
  ## taken out of it. Two blocks with the same signature are the same news.
  ##
  ##   * a PASS line contributes its label and the bare word PASS. A PASS whose
  ##     frame count advanced is not new information.
  ##   * a FAIL or INCONCLUSIVE line contributes its WHOLE line with digits
  ##     removed. The class holding steady while the REASON changes IS new
  ##     information and must re-emit; the digits inside that reason are not.
  ##     This is deliberately the least aggressive case: when something is
  ##     wrong, err towards saying so again.
  ##   * any other line contributes its label, plus its first token when that
  ##     token is neither numeric nor a `key=value` counter. That is what makes
  ##     a host PHASE TRANSITION re-print the block, while
  ##     `feed : ticks=N published=N` does not.
  ##
  ## What this does NOT do is suppress anything. It only decides when to
  ## REPEAT. Every not-PASS line is surfaced separately by `diagNotPass`, on a
  ## schedule no signature can silence.
  result = ""
  var i = 0
  while i < text.len:
    let e = lineEndAt(text, i)
    let c = colonOf(text, i, e)
    if c >= 0:
      let lab = labelOf(text, i, c)
      let tok = firstToken(text, c, e)
      if tok == DiagPass:
        result.add lab & "=PASS;"
      elif tok == DiagFail or tok == DiagIncon:
        result.add lab & "="
        var k = c + 1
        while k < e:
          if not isDigitCh(text[k]):
            result.add text[k]
          inc k
        result.add ";"
      else:
        var numeric = tok.len > 0
        var hasEq = false
        var k = 0
        while k < tok.len:
          let ch = tok[k]
          if not isDigitCh(ch) and ch != '.' and ch != '-' and ch != '+':
            numeric = false
          if ch == '=':
            hasEq = true
          inc k
        if numeric or hasEq:
          result.add lab & ";"
        else:
          result.add lab & "=" & tok & ";"
    i = e + 1

proc diagNotPass*(text: string): string =
  ## `label:VERDICT` for every line reading FAIL or INCONCLUSIVE, in order.
  ## Empty string means every labelled line read PASS.
  ##
  ## This exists because of exactly the failure the complaint describes: the
  ## pasted sample carried `art: FAIL` and `classFilter: INCONCLUSIVE` buried
  ## inside eighteen lines of PASS, re-emitted every two seconds, and neither
  ## was visible. A verdict nobody can find is not a verdict.
  result = ""
  var i = 0
  while i < text.len:
    let e = lineEndAt(text, i)
    let c = colonOf(text, i, e)
    if c >= 0:
      let tok = firstToken(text, c, e)
      if tok == DiagFail or tok == DiagIncon:
        if result.len > 0:
          result.add ", "
        result.add labelOf(text, i, c) & ":" & tok
    i = e + 1
