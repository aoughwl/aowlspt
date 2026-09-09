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

# ---------------------------------------------------------------------------
# THE `draw` VERDICT. Pure, so the case that produced this code -- FAIL at the
# MAIN MENU -- is testable offline.
#
# MEASURED, every boot on 2026-09-02, at the main menu with no raid:
#   `warn Maps: diag NOT-PASS: ... draw:FAIL ...`
# and then `STILL NOT-PASS after N unchanged cycle(s)` every 60 s, forever.
#
# The old ladder read: HUD registered, callback invoked, `hudDrawn() == 0` ->
# FAIL, "This is the reason the radar is not on screen". At the menu the
# callback IS dispatched every frame and correctly draws nothing, because there
# is no raid. So the FAIL fired on a state that is not a defect, and -- worse --
# its negative was indistinguishable from "not in a raid" (CLAUDE.md 9b): there
# was no input at the menu for which that branch could have said anything else.
#
# The gate is now the raid lifecycle, and it is a real gate, not a suppression:
#   * `drawn > 0` still reports PASS regardless of the gate, so a raid that
#     drew and then ended keeps its earned PASS instead of decaying to
#     INCONCLUSIVE.
#   * `drawn == 0` with the gate OPEN is still a FAIL, with the same text. That
#     is the input that makes this check fail, and the offline suite feeds it.
# ---------------------------------------------------------------------------

proc drawVerdict*(hudOn, armed: bool; frames, drawn, blips, masked, gated: int64;
                  raidLive: bool; raidWhy: string): string =
  ## The `draw` line, from the FINISHED state: did primitives come out, and was
  ## anything ever meant to come out.
  if not hudOn:
    result = DiagIncon & "  no HUD registered, so no draw was possible"
  elif not armed:
    result = DiagIncon & "  registered, but the shared region is NOT armed " &
             "(host flag `sharedRegion`), so the renderer was never asked to " &
             "draw. Not a draw failure -- see `region` above"
  elif frames <= 0'i64:
    result = DiagIncon & "  the callback has never been invoked"
  elif drawn > 0'i64:
    if blips <= 0'i64:
      result = DiagPass & "  radar drawn on " & $drawn & " frame(s), but 0 " &
               "blip(s) -- the ring is on screen with nothing in it"
    else:
      result = DiagPass & "  drawn on " & $drawn & " frame(s), " & $blips &
               " blip(s)"
  elif not raidLive:
    # THE MENU CASE. Nothing was supposed to be drawn, so 0 draws is not
    # evidence of anything. Name the gate, and name what WOULD make it a FAIL.
    result = DiagIncon & "  the callback ran " & $frames & " time(s) and drew " &
             "nothing, but the raid gate is CLOSED (" & raidWhy & "), so " &
             "there was nothing to draw. " &
             "not in a raid: a zero draw count here is not a defect" &
             ". This reads FAIL only once the gate is OPEN and the callback " &
             "still submits no primitives"
  else:
    result = DiagFail & "  the callback ran " & $frames & " time(s) and drew " &
             "NOTHING every time, while the raid gate is OPEN. It returns " &
             "immediately because no local player position validated -- see " &
             "`positions` above. This is the reason the radar is not on screen"
  # Dispatches skipped because a blocking UI surface (F12/Settings, F6, F3) was
  # open. Its own countable clause so "hidden behind a panel" never reads as the
  # flicker failure. Zero when no panel was ever open.
  if masked > 0'i64:
    result = result & "; " & $masked & " dispatch(es) SKIPPED with an " &
             "overlay open (aowl_ui_overlay_mask != 0 -- map hidden behind a panel)"
  if gated > 0'i64:
    result = result & "; " & $gated & " dispatch(es) GATED OFF by the " &
             "master switch (enabled == 0 -- 0 primitives submitted, held frame " &
             "dropped)"

# ---------------------------------------------------------------------------
# THE REPEAT POLICY for the not-PASS re-announcement.
#
# In a raid, a standing FAIL must keep naming itself every 30 cycles (60 s) for
# as long as it lasts -- that is the whole point of the line and it is NOT
# changed here. Outside a raid, most of the block is legitimately INCONCLUSIVE
# ("I could not look" is the honest answer at the menu), and re-announcing that
# every 60 s forever is noise that says nothing new. So outside a raid it is
# announced ONCE PER PHASE: the full block already re-prints whenever any
# verdict moves, and the phase name is part of the signature, so a real change
# still surfaces immediately.
# ---------------------------------------------------------------------------

type
  DiagEmit* = enum
    DeNone        ## say nothing this cycle
    DeBlock       ## a verdict moved: print the whole block (+ the not-PASS line)
    DeStill       ## nothing moved and something is still not-PASS: re-announce
    DeHeartbeat   ## nothing moved and everything is PASS: liveness only

  DiagRepeatState* = object
    sig*: string          ## verdict signature at the last full print
    quiet*: int64         ## cycles since the last full print
    lastPhase*: int       ## host phase at the last not-PASS announcement
    announced*: bool      ## a not-PASS has been announced for `lastPhase`

proc diagStep*(st: var DiagRepeatState; sig: string; hasBad, raidLive: bool;
               phase: int): DiagEmit =
  ## One diag cycle. `st` carries everything; nothing else is consulted.
  if st.sig.len == 0 or sig != st.sig:
    st.sig = sig
    st.quiet = 0'i64
    st.lastPhase = phase
    st.announced = hasBad
    return DeBlock
  st.quiet = st.quiet + 1'i64
  if hasBad:
    if raidLive:
      # IN A RAID: unchanged. Every 60 s, forever.
      if (st.quiet mod 30'i64) == 0'i64:
        st.lastPhase = phase
        st.announced = true
        return DeStill
      return DeNone
    # OUTSIDE A RAID: once per phase, not once per minute.
    if (not st.announced) or phase != st.lastPhase:
      st.lastPhase = phase
      st.announced = true
      return DeStill
    return DeNone
  if (st.quiet mod 150'i64) == 0'i64:
    return DeHeartbeat
  DeNone
