## tuilayout -- the launcher's TWO screens, rendered into a buffer and checked
## as a CHARACTER GRID, with no console, no game and no launcher.
##
## ## Why this test exists
##
## `tools/aowllaunch.nim` shows two screens, in one console, one after the
## other: `launcherRows` (the launch progress and the profile panel) and then,
## once the client is up, `logViewRows` (the two log panes). A revision in
## between fused them into a single frame, and undoing that is a layout change
## -- which is the class of change that fails by being *one column out*. A frame
## whose right-hand border lands in the last cell puts the console into the
## deferred-wrap state; on some hosts the next carriage return cancels it and on
## others the row wraps and the whole frame scrolls up by a line, every frame.
## It looks like a rendering glitch and it is arithmetic that drifts with the
## window width, so it shows up on one player's terminal and not on ours.
##
## The other thing it exists to hold down is the SEPARATION. "Two screens" is
## easy to claim and easy to lose: one stray call and the profile panel is
## drawn above two log panes again, which is precisely what was rejected. So
## `notFused` below asserts it structurally, on the grid -- the launcher frame's
## top border has TWO corners and the split log frame's has THREE, because the
## split one carries a junction between the panes. A fused frame fails that
## count, and it fails it without anybody having to notice it by eye.
##
## ## What it asserts, and what it deliberately does not
##
## It asserts on the FINISHED GRID -- the strings the layout actually produced
## -- never on the inputs it was handed. Concretely, at each size:
##
##   * no row is wider than the window (the off-by-one above);
##   * the frame is exactly as many rows as the window has;
##   * both pane borders are present, and in the split case the top border
##     carries BOTH pane titles and a `bxTD` junction between them, so a run
##     that quietly drew one pane cannot pass;
##   * the progress region is present, and the step text is really in the grid;
##   * lines from BOTH logs appear in the body of screen 2 at the same time;
##   * screen 1 lists the profiles it was given, ALL of them, and marks nothing
##     it was not told to mark;
##   * with an empty profile list screen 1 draws the CREATE path -- real words
##     about what to do next -- and not an empty box, which is the first-run
##     dead end this release is fixing;
##   * neither screen carries the other's furniture (see `notFused`);
##   * below the minimum size each layout REFUSES (`renderable == false`) and
##     carries a reason, rather than returning a bent frame.
##
## The assertions are negative wherever they can be: "no row exceeds w", "no
## body row is missing its right border". A negative can be falsified by a real
## defect; `assert lay.rows.len > 0` cannot fail for any input worth testing.
##
## Colour and box-drawing are pinned with `forcePlain()` and `forceAscii()` so
## the grid is plain ASCII and a match against it means what it says. That is
## not a workaround: `putIn` emits escapes only under `tmFull`, and a test that
## searched for a title inside `ESC[37m server ESC[0m` would be testing the
## escape codes rather than the layout.

import std/[syncio, strutils]
import aowlterm
import aowllayout

var failures = 0
var checks = 0

proc check(ok: bool; what: string) =
  inc checks
  if not ok:
    inc failures
    echo "FAIL  " & what
  else:
    echo "ok    " & what

proc has(rows: seq[Row]; needle: string): bool =
  result = false
  for r in rows:
    if find(r.text, needle) >= 0: return true

proc rowIndexOf(rows: seq[Row]; needle: string): int =
  result = -1
  for i in 0 ..< rows.len:
    if find(rows[i].text, needle) >= 0: return i

proc widest(rows: seq[Row]): int =
  result = 0
  for r in rows:
    let c = colsOf(r.text)
    if c > result: result = c

proc lastIndexOf(rows: seq[Row]; needle: string): int =
  result = -1
  for i in 0 ..< rows.len:
    if find(rows[i].text, needle) >= 0: result = i

proc firstInk(s: string): int =
  ## The column of the first character that is not a space. -1 for a blank row.
  ## `forcePlain()` is in force, so there are no escapes to skip.
  result = -1
  for i in 0 ..< s.len:
    if s[i] != ' ': return i

proc alignedAtTwo(rows: seq[Row]; label: string): bool =
  ## THE COLUMN CHECK. Every row the layout produces starts its text in column
  ## 2 -- or column 0 if it is a box edge, whose vertical/corner IS the text.
  ##
  ## Before this, `screenHeader` and the status line started in column 1 while
  ## `stepRow` started in column 2, so the top of the frame was one column left
  ## of the ticks under it and one column left of the box under those. Nobody
  ## reports that as a bug; they report "formatting issues" and "it sucks".
  ##
  ## A positive column assertion rather than "looks tidy": it fails for a single
  ## added or removed leading space, anywhere.
  result = true
  for i in 0 ..< rows.len:
    let t = rows[i].text
    let c = firstInk(t)
    if c < 0: continue                      # blank filler row
    if c == 0: continue                     # a box edge: '+' or '|'
    # Column 5 is the step NAME column: `stepRow` writes a two-cell marker at
    # column 2 and a space, so a PENDING step -- whose marker is deliberately
    # blank -- has its first ink at 5 while its name is in the same column as
    # every other step's. Two legal columns, and nothing else: this still fails
    # for the header at column 1, which is what it was written for.
    if c == 5 and i > 0: continue
    if c != 2:
      result = false
      echo "      MISALIGNED " & label & " row " & $i & " first ink at col " &
           $c & ": |" & t & "|"

# ---------------------------------------------------------------------------
# Two logs with content that cannot be confused for each other
# ---------------------------------------------------------------------------
#
# The pane bodies are the assertion that matters most, and a body full of blank
# padding would satisfy "the panes are there" without showing a single line. So
# both tails are filled with lines carrying a marker that appears nowhere else
# in the frame, and the test looks for BOTH markers in the SAME grid.

proc fakeTail(marker: string; n: int): Tail =
  result = newTail("(test)")
  for i in 0 ..< n:
    result.lines.add parseLine("[" & $(i * 37) & "ms] info  " & marker & $i)

proc buildHelp(w: int): Row =
  result = newRow()
  result.put "  "
  result.putIn ColDim, fit("q quit   d detach   tab swap   f full   space " &
                           "pause   pgup/pgdn scroll", w - 3)

proc buildHeader(w: int): Row =
  ## The same shape, and the same right-to-left dropping, as `screenHeader` in
  ## the launcher. It has to be: this row arrives at the layout already built,
  ## so the layout's "no row wider than w" check is only meaningful if the test
  ## feeds it a header built the way the launcher builds one. A test header that
  ## always fit would have hidden the 41-column header at a 40-column window.
  result = newRow()
  result.put "  "
  result.putIn ColWhite, "aowlspt"
  var labelW = 26
  var srvW = 30
  var cliW = 22
  if 9 + (3 + labelW) + (3 + srvW) + (3 + cliW) + 2 + 6 > w:
    labelW = 14
    srvW = 16
    cliW = 14
  if result.width + 3 + labelW <= w:
    result.put "  "
    result.putIn ColDim, bxV()
    result.put " "
    result.putIn ColCyan, fit("Bear", labelW)
  if result.width + 3 + srvW <= w:
    result.put " "
    result.putIn ColDim, bxV()
    result.put " "
    result.putIn ColGreen, fit("server up", srvW)
  if result.width + 3 + cliW <= w:
    result.put " "
    result.putIn ColDim, bxV()
    result.put " "
    result.putIn ColGreen, fit("client up", cliW)
  if result.width <= w - 10:
    result.padTo w - 10
    result.putIn ColDim, secsText(12345'i64)

proc buildSteps(w: int): seq[Row] =
  result = @[]
  result.add stepRow(MarkDone, "port 6970", "claimed", w)
  result.add stepRow(MarkDone, "database", "41.2 MB read", w)
  result.add stepRow(MarkActive, "mods", "STEPMODS 2 of 3", w)
  result.add stepRow(MarkPending, "listening", "", w)
  result.add stepRow(MarkPending, "answering", "", w)

proc runSize(w, h: int; expectRenderable: bool; label: string) =
  var srv = fakeTail("SRVLINE", 40)
  var cli = fakeTail("CLILINE", 40)
  let lay = logViewRows(w, h, buildHeader(w),
                        stepRow(MarkDone, "launch", "SUMMARYLINE ready", w),
                        srv, cli, "SRVPANE 40", "CLIPANE 40",
                        0, 0, 0, false, buildHelp(w))

  echo ""
  echo "--- " & label & "  (w=" & $w & " h=" & $h & ") ---"
  if not expectRenderable:
    check(not lay.renderable, label & ": REFUSES to draw")
    check(lay.note.len > 0, label & ": says why it refused")
    check(lay.rows.len == 0, label & ": returns no rows at all")
    if lay.note.len > 0: echo "      note: " & lay.note
    return

  check(lay.renderable, label & ": renders")
  if not lay.renderable:
    echo "      note: " & lay.note
    return

  # The grid itself.
  for r in lay.rows:
    echo "|" & r.text & "|"

  check(lay.rows.len == h, label & ": exactly " & $h & " rows (got " &
        $lay.rows.len & ")")
  check(widest(lay.rows) <= w, label & ": no row wider than " & $w &
        " (widest " & $widest(lay.rows) & ")")

  # Both pane borders, and the junction that proves there are two of them.
  let top = rowIndexOf(lay.rows, "SRVPANE")
  check(top >= 0, label & ": the server pane title is drawn")
  check(top >= 0 and find(lay.rows[top].text, "CLIPANE") >= 0,
        label & ": BOTH pane titles are on the same border row")
  check(top >= 0 and lay.rows[top].text[0] == '+',
        label & ": the top border starts with a corner")
  let bottom = lay.rows.len - 2
  check(lay.rows[bottom].text[0] == '+' and
        lay.rows[bottom].text[lay.rows[bottom].text.len - 1] == '+',
        label & ": the bottom border is a full rule with both corners")

  # Every body row carries both verticals -- a pane that vanished would leave a
  # short row that still looked plausible on its own.
  var bodyOk = true
  for i in (top + 1) ..< bottom:
    let t = lay.rows[i].text
    if t.len == 0 or t[0] != '|' or t[t.len - 1] != '|': bodyOk = false
  check(bodyOk, label & ": every body row is bounded by both outer verticals")

  # THE COMPLAINT. "i can still see those checkboxes for the il2cpp and the
  # other few items when we are side by side."
  #
  # Screen 2 must carry the ONE summary line and not one row of the launch
  # progress region -- at EVERY size, not only at the small ones where it used
  # to fold. Three independent negatives, because the step rows could come back
  # by their text, by their glyph, or by a leftover row of the region:
  #
  #   * no step's detail text ("STEPMODS", from the mods step) is in the grid;
  #   * no row outside the panes carries a tick or an arrow marker;
  #   * the summary line is present, and it is row 1.
  #
  # `buildSteps` is still constructed above and deliberately NOT passed: the
  # falsifiability proof for this check is to hand those rows back to
  # `logViewRows` and watch all three go red.
  check(has(lay.rows, "SUMMARYLINE"),
        label & ": the launch is one summary line")
  check(rowIndexOf(lay.rows, "SUMMARYLINE") == 1,
        label & ": ...and it is the row under the header, not buried in a " &
        "progress region")
  check(not has(lay.rows, "STEPMODS"),
        label & ": NO progress step text on the split screen")
  var strayMark = -1
  for i in 0 ..< lay.rows.len:
    let t = lay.rows[i].text
    if t.len > 0 and (t[0] == '+' or t[0] == '|'): continue   # the panes
    if i == 1: continue                                       # the summary
    if find(t, "ok ") == 2 or find(t, ">> ") == 2 or find(t, "!! ") == 2:
      strayMark = i
  check(strayMark < 0,
        label & ": no stray checkbox row above the panes (row " &
        $strayMark & ")")
  check(lay.bodyH >= MinBody,
        label & ": the body is at least MinBody=" & $MinBody & " lines (got " &
        $lay.bodyH & ")")
  check(alignedAtTwo(lay.rows, label),
        label & ": every row starts its text in column 2")
  check(has(lay.rows, "SRVLINE"), label & ": the server log is on screen")
  check(has(lay.rows, "CLILINE"), label & ": the client log is on screen")
  echo "      bodyH=" & $lay.bodyH & " maxWidth=" & $lay.maxWidth

proc runSolo(w, h: int) =
  ## `f` -- one pane, full width. The arithmetic is different (no junction), so
  ## a frame that is correct split can still be one column out solo.
  var srv = fakeTail("SRVLINE", 40)
  var cli = fakeTail("CLILINE", 40)
  let lay = logViewRows(w, h, buildHeader(w),
                        stepRow(MarkDone, "launch", "SUMMARYLINE ready", w),
                        srv, cli, "SRVPANE 40", "CLIPANE 40",
                        0, 0, 0, true, buildHelp(w))
  echo ""
  echo "--- solo (f)  (w=" & $w & " h=" & $h & ") ---"
  check(lay.renderable, "solo: renders")
  if not lay.renderable: return
  for r in lay.rows: echo "|" & r.text & "|"
  check(lay.rows.len == h, "solo: exactly " & $h & " rows")
  check(widest(lay.rows) <= w, "solo: no row wider than " & $w &
        " (widest " & $widest(lay.rows) & ")")
  check(has(lay.rows, "SRVLINE"), "solo: the focused pane is drawn")
  check(not has(lay.rows, "CLILINE"),
        "solo: the unfocused pane is NOT drawn (that is what solo means)")

# ---------------------------------------------------------------------------
# Screen 1 -- the launcher
# ---------------------------------------------------------------------------

proc countCh(s: string; ch: char): int =
  result = 0
  for c in s:
    if c == ch: inc result

proc buildProfiles(n, w: int): seq[Row] =
  ## `n` profile rows, each carrying a marker that appears nowhere else in the
  ## frame, so "the panel is drawn" cannot pass on blank padding.
  result = @[]
  for i in 0 ..< n:
    var r = newRow()
    r.put "  "
    r.putIn (if i == 0: ColGreen else: ColDim), (if i == 0: ">>" else: "  ")
    r.put " "
    r.putIn ColCyan, fit("PROFROW" & $i, (if w > 46: 34 else: 18))
    result.add r

proc buildEmpty(w: int): seq[Row] =
  ## What the panel shows on a FIRST RUN. Two real sentences, because "there
  ## are none" without a way forward is the dead end being fixed.
  result = @[]
  var a = newRow()
  a.put "  "
  a.putIn ColYellow, fit("CREATEHINT no profiles yet", w - 6)
  result.add a
  var b = newRow()
  b.put "  "
  b.putIn ColDefault, fit("CREATESTEP nickname and side, before the game " &
                          "starts", w - 6)
  result.add b

proc runLauncher(w, h, nProfiles: int; expectRenderable: bool; label: string) =
  let profiles = buildProfiles(nProfiles, w)
  let lay = launcherRows(w, h, buildHeader(w), buildSteps(w),
                         stepRow(MarkActive, "launch", "SUMMARYLINE starting", w),
                         "PANELTITLE profiles", profiles, buildEmpty(w),
                         buildHelp(w))
  echo ""
  echo "--- screen1 " & label & "  (w=" & $w & " h=" & $h & " profiles=" &
       $nProfiles & ") ---"
  if not expectRenderable:
    check(not lay.renderable, label & ": REFUSES to draw")
    check(lay.note.len > 0, label & ": says why it refused")
    check(lay.rows.len == 0, label & ": returns no rows at all")
    if lay.note.len > 0: echo "      note: " & lay.note
    return

  check(lay.renderable, label & ": renders")
  if not lay.renderable:
    echo "      note: " & lay.note
    return
  for r in lay.rows: echo "|" & r.text & "|"

  check(lay.rows.len == h, label & ": exactly " & $h & " rows (got " &
        $lay.rows.len & ")")
  check(widest(lay.rows) <= w, label & ": no row wider than " & $w &
        " (widest " & $widest(lay.rows) & ")")

  let top = rowIndexOf(lay.rows, "PANELTITLE")
  check(top >= 0, label & ": the panel title is drawn")
  check(top >= 0 and lay.rows[top].text[0] == '+',
        label & ": the panel top border starts with a corner")
  # FOUND BY SCANNING, not by assuming it is the second-to-last row. The box no
  # longer reaches the bottom of the window -- it is sized to its contents and
  # the slack is blank rows underneath -- and a test that indexed `len - 2`
  # would have gone green on a border that had stopped closing entirely.
  let bottom = lastIndexOf(lay.rows, "+-")
  check(bottom > top, label & ": the panel closes below its title")
  check(bottom > top and lay.rows[bottom].text[0] == '+' and
        lay.rows[bottom].text[lay.rows[bottom].text.len - 1] == '+',
        label & ": the panel bottom border is a full rule with both corners")
  check(bottom > top and
        colsOf(lay.rows[bottom].text) == colsOf(lay.rows[top].text),
        label & ": the bottom border is exactly as wide as the top one")
  var bodyOk = true
  if top >= 0 and bottom > top:
    for i in (top + 1) ..< bottom:
      let t = lay.rows[i].text
      if t.len == 0 or t[0] != '|' or t[t.len - 1] != '|': bodyOk = false
  check(bodyOk, label & ": every panel row is bounded by both verticals")

  # THE HALF-DRAWN BOX. At 120x30 with six profiles the panel used to be
  # twenty-one rows tall: six names and FIFTEEN empty rows inside the border.
  # At 200x50 it was thirty-five. The box is now sized to its contents, so at
  # most one blank row is left inside it (breathing space), and whatever the
  # window has left over is blank space BELOW the box, where it reads as space
  # rather than as a box nobody finished filling.
  #
  # Counted on the grid between the two borders, so it fails on the real defect
  # and cannot be satisfied by a field the layout reports about itself.
  var blanksInside = 0
  if top >= 0 and bottom > top:
    for i in (top + 1) ..< bottom:
      let t = lay.rows[i].text
      if firstInk(t) == 0 and t.len > 2:
        var inkAfter = false
        for j in 1 ..< (t.len - 1):
          if t[j] != ' ': inkAfter = true
        if not inkAfter: inc blanksInside
  check(blanksInside <= 1,
        label & ": at most one blank row inside the panel (got " &
        $blanksInside & ")")
  check(alignedAtTwo(lay.rows, label),
        label & ": every row starts its text in column 2")

  # No gap between the box and the keys. The slack the box gives back belongs
  # at the BOTTOM of the window, not between two things that have to read as
  # one block -- the first attempt at the shrinking box put it in the middle
  # and marooned the status line fourteen rows below the panel.
  check(bottom > top and bottom + 1 < lay.rows.len and
        firstInk(lay.rows[bottom + 1].text) == 2,
        label & ": the status line is the row immediately under the panel")
  check(lay.usedRows > 0 and lay.usedRows == bottom + 2,
        label & ": usedRows (" & $lay.usedRows & ") ends at the status line")
  var trailingBlank = true
  for i in lay.usedRows ..< lay.rows.len:
    if firstInk(lay.rows[i].text) >= 0: trailingBlank = false
  check(trailingBlank,
        label & ": everything after usedRows is genuinely blank")

  # The progress region.
  if lay.collapsedSteps:
    check(has(lay.rows, "SUMMARYLINE"),
          label & ": the progress region collapsed to its summary line")
    check(lay.note.len > 0, label & ": says on screen that it collapsed")
    echo "      note: " & lay.note
  else:
    check(has(lay.rows, "STEPMODS"),
          label & ": the progress steps are drawn in full")
  check(lay.stepsShown > 0, label & ": a progress region is present")

  # The panel's CONTENT -- the part that a frame of blank padding would fail.
  if nProfiles == 0:
    check(lay.emptyPath, label & ": reports it drew the first-run path")
    check(has(lay.rows, "CREATEHINT"),
          label & ": an empty install renders the CREATE path...")
    check(has(lay.rows, "CREATESTEP"),
          label & ": ...including what actually happens next")
    check(not has(lay.rows, "PROFROW"),
          label & ": and lists no profiles, because there are none")
  else:
    check(not lay.emptyPath,
          label & ": does NOT take the first-run path when profiles exist")
    check(not has(lay.rows, "CREATEHINT"),
          label & ": does NOT offer to create when profiles exist")
    # EVERY profile, or an explicit count of how many were hidden. A panel that
    # silently shows four of six is a chooser lying about what there is.
    var seen = 0
    for i in 0 ..< nProfiles:
      if has(lay.rows, "PROFROW" & $i): inc seen
    check(seen == lay.listed,
          label & ": " & $seen & " profile rows on screen, and it reports " &
          $lay.listed)
    check(seen + lay.hidden == nProfiles,
          label & ": " & $seen & " shown + " & $lay.hidden & " declared " &
          "hidden == " & $nProfiles & " given")
    if lay.hidden > 0:
      check(lay.note.len > 0, label & ": says on screen that rows were hidden")
  echo "      stepsShown=" & $lay.stepsShown & " bodyH=" & $lay.bodyH &
       " listed=" & $lay.listed & " hidden=" & $lay.hidden &
       " emptyPath=" & $lay.emptyPath & " maxWidth=" & $lay.maxWidth

proc notFused(w, h: int) =
  ## THE REGRESSION THIS RELEASE IS ABOUT.
  ##
  ## The rejected revision drew the progress region, the profile panel and both
  ## log panes in ONE frame. Two screens is not something to take on trust, so
  ## it is checked on the grid, both ways round and structurally:
  ##
  ##   * the launcher frame must not contain a single log line from either tail,
  ##     and its panel border must have exactly TWO corners -- a fused frame
  ##     would carry the pane junction and have three;
  ##   * the log frame must not contain a profile row or the create hint.
  ##
  ## Both are negatives. A fused frame fails them; neither can pass by accident.
  echo ""
  echo "--- not fused  (w=" & $w & " h=" & $h & ") ---"
  var srv = fakeTail("SRVLINE", 40)
  var cli = fakeTail("CLILINE", 40)

  let one = launcherRows(w, h, buildHeader(w), buildSteps(w),
                         stepRow(MarkActive, "launch", "SUMMARYLINE starting", w),
                         "PANELTITLE profiles", buildProfiles(3, w),
                         buildEmpty(w), buildHelp(w))
  let two = logViewRows(w, h, buildHeader(w),
                        stepRow(MarkDone, "launch", "SUMMARYLINE ready", w),
                        srv, cli, "SRVPANE 40", "CLIPANE 40",
                        0, 0, 0, false, buildHelp(w))
  check(one.renderable and two.renderable, "not fused: both screens render")
  if not (one.renderable and two.renderable): return

  check(not has(one.rows, "SRVLINE"),
        "not fused: screen 1 carries NO server log line")
  check(not has(one.rows, "CLILINE"),
        "not fused: screen 1 carries NO client log line")
  check(not has(one.rows, "SRVPANE") and not has(one.rows, "CLIPANE"),
        "not fused: screen 1 carries NEITHER pane title")

  check(not has(two.rows, "PROFROW"),
        "not fused: screen 2 carries NO profile row")
  check(not has(two.rows, "CREATEHINT"),
        "not fused: screen 2 carries NO create affordance")
  check(not has(two.rows, "PANELTITLE"),
        "not fused: screen 2 carries NO profile panel title")

  # Structural, not marker-based: the number of corners on the top border is a
  # property of how many boxes are on the row.
  let t1 = rowIndexOf(one.rows, "PANELTITLE")
  let t2 = rowIndexOf(two.rows, "SRVPANE")
  check(t1 >= 0 and countCh(one.rows[t1].text, '+') == 2,
        "not fused: screen 1's top border has exactly 2 corners (one box), " &
        "got " & (if t1 >= 0: $countCh(one.rows[t1].text, '+') else: "no row"))
  check(t2 >= 0 and countCh(two.rows[t2].text, '+') == 3,
        "not fused: screen 2's top border has exactly 3 (two boxes + the " &
        "junction), got " &
        (if t2 >= 0: $countCh(two.rows[t2].text, '+') else: "no row"))

proc handoff(w: int) =
  ## The line that marks the swap. It is the only thing standing between "the
  ## screen changed" and "the screen changed and I know why", so it has to
  ## actually carry its message and actually fit.
  echo ""
  echo "--- handoff  (w=" & $w & ") ---"
  let r = handoffRow(w, "HANDOFFTEXT launch complete -- the logs take the screen")
  echo "|" & r.text & "|"
  check(find(r.text, "HANDOFFTEXT") >= 0, "handoff: carries its message")
  check(colsOf(r.text) <= w, "handoff: fits in " & $w & " columns (got " &
        $colsOf(r.text) & ")")

proc leakProof(w, h: int) =
  ## FALSIFIABILITY, executed rather than asserted in a comment.
  ##
  ## The check that screen 2 carries no progress steps is only worth having if
  ## it can go red. So this reintroduces the leak by hand -- it builds exactly
  ## the frame the old `logViewRows` built, header then the five step rows then
  ## the panes -- and runs the SAME three predicates over it. They must all say
  ## "leak present". If they do not, the checks above are decoration.
  echo ""
  echo "--- leak proof: the OLD fused frame, checked by the NEW predicates" &
       "  (w=" & $w & " h=" & $h & ") ---"
  var srv = fakeTail("SRVLINE", 40)
  var cli = fakeTail("CLILINE", 40)
  let good = logViewRows(w, h, buildHeader(w),
                         stepRow(MarkDone, "launch", "SUMMARYLINE ready", w),
                         srv, cli, "SRVPANE 40", "CLIPANE 40",
                         0, 0, 0, false, buildHelp(w))
  if not good.renderable: return

  # The leaky frame: the header, then the steps where the summary line is, then
  # the rest of the real frame untouched.
  var leaky: seq[Row] = @[]
  leaky.add good.rows[0]
  for r in buildSteps(w): leaky.add r
  for i in 2 ..< good.rows.len: leaky.add good.rows[i]
  for r in leaky: echo "|" & r.text & "|"

  check(has(leaky, "STEPMODS"),
        "leak proof: the step-text predicate SEES the reintroduced leak")
  var stray = -1
  for i in 0 ..< leaky.len:
    let t = leaky[i].text
    if t.len > 0 and (t[0] == '+' or t[0] == '|'): continue
    if i == 1: continue
    if find(t, "ok ") == 2 or find(t, ">> ") == 2 or find(t, "!! ") == 2:
      stray = i
  check(stray >= 0,
        "leak proof: the stray-checkbox predicate SEES it too (row " &
        $stray & ")")
  check(rowIndexOf(leaky, "SUMMARYLINE") != 1,
        "leak proof: and the summary line is no longer row 1")
  check(not has(good.rows, "STEPMODS") and
        rowIndexOf(good.rows, "SUMMARYLINE") == 1,
        "leak proof: while the REAL frame passes all three")

proc stepColumns(w: int) =
  ## THE COLLISION. `character selectwaiting for it (1m 08s)` -- the step name
  ## ran straight into its own detail with no space between them.
  ##
  ## Asserted the way the brief asks: every row's detail must begin at the SAME
  ## column, and no name may run into it, with a name long enough to overflow
  ## the column. The overlong names are the point -- the four names the launcher
  ## happened to use at wide widths all fit, which is why this shipped, and why
  ## a test using only those names would pass against the broken version.
  echo ""
  echo "--- step columns  (w=" & $w & ") ---"
  let names = @["process", "host log", "IL2CPP runtime", "host",
                "character select",
                "a preposterously long step name that cannot possibly fit"]
  var detailCols: seq[int] = @[]
  var collided = false
  for n in names:
    let r = stepRow(MarkActive, n, "DETAILMARK", w)
    echo "|" & r.text & "|"
    let c = find(r.text, "DETAILMARK")
    detailCols.add c
    # The character immediately before the detail must be a space. That is the
    # collision, stated as a property rather than as a column number.
    if c > 0 and r.text[c - 1] != ' ': collided = true
  check(not collided,
        "steps: no name runs into its own detail (w=" & $w & ")")
  var sameCol = true
  var colsText = ""
  for c in detailCols:
    if c != detailCols[0]: sameCol = false
    if colsText.len > 0: colsText.add ","
    colsText.add $c
  check(sameCol,
        "steps: every detail begins at the same column (w=" & $w & ", got " &
        colsText & ")")
  # ALL-OR-NOTHING, stated separately, because "every detail is at the same
  # column" is satisfied vacuously when there is no detail on any row -- which
  # is exactly what happens at w=24, where `stepRow` correctly drops it for
  # want of room. A check that passes on `-1,-1,-1,-1,-1,-1` is not evidence
  # about column alignment, so the two cases are now distinguished and the
  # column identity is asserted only where a detail was actually drawn.
  if detailCols[0] < 0:
    var allDropped = true
    for c in detailCols:
      if c >= 0: allDropped = false
    check(allDropped,
          "steps: at w=" & $w & " there is no room for a detail, and it is " &
          "dropped on EVERY row rather than some")
    echo "      (no detail column at this width -- correctly dropped)"
  else:
    check(detailCols[0] == stepDetailCol(w),
          "steps: ...which is the DERIVED column " & $stepDetailCol(w))
  check(stepDetailCol(w) > StepNameCol + stepNameW(w),
        "steps: the detail column is strictly past the widest possible name " &
        "(" & $StepNameCol & "+" & $stepNameW(w) & " < " & $stepDetailCol(w) &
        ") -- the arithmetic that failed")
  # A pending step's marker is blank, and it must not shift the columns.
  let p = stepRow(MarkPending, "character select", "DETAILMARK", w)
  check(find(p.text, "DETAILMARK") == detailCols[0],
        "steps: a PENDING row's detail is in the same column too")
  check(colsOf(p.text) <= w,
        "steps: and an overlong name never widens the row past " & $w)

proc oldVerdict(w: EnterWait; reason: var string): int =
  ## THE BEHAVIOUR THAT SHIPPED, reproduced exactly, so the new checks can be
  ## shown to go red against it.
  ##
  ## The old wait loop looked at one thing: is there a screen named
  ## `CharacterSelectionScreen` with `active == triYes`? It never consulted
  ## `ScreenSet.rootPresent`. Everything else was the 270s wall-clock bound.
  reason = ""
  if w.selectorActive:
    reason = "character select is up"
    return EwSelectorUp
  if w.elapsedMs >= EnterWaitLimitMs:
    reason = "timed out"
    return EwTimedOut
  result = EwWaiting

proc inRaid(elapsedMs: int64): EnterWait =
  ## THE STATE THE PLAYER WAS ACTUALLY IN.
  ##
  ## Client alive, host running, they clicked through character select
  ## themselves and are in a raid -- so the `Menu UI` scene root is gone. The
  ## selector WAS seen earlier in the run, which is what makes this different
  ## from a cold client that has not reached the menu yet.
  result = EnterWait(sawMenuRoot: true, menuRootPresent: false,
                     sawSelector: true, selectorActive: false,
                     otherScreenActive: false, clientAlive: true,
                     elapsedMs: elapsedMs)

proc transition(w, h: int) =
  ## THE REGRESSION THE 274 GRID CHECKS COULD NOT SEE.
  ##
  ## Every check up to here asks "does this screen render correctly". None of
  ## them can ask "is this the right screen to be on", and that is exactly what
  ## broke in front of a player: the launcher rendered screen 1 perfectly, for
  ## four and a half minutes, while they were in a raid.
  ##
  ## The falsifiable assertion, per the brief: given a live client with all its
  ## steps satisfied, the produced screen must be the LOG VIEW. It is asserted
  ## on the produced GRID, not just on the verdict integer -- the frame we end
  ## up with must carry the panes and must NOT carry the profile panel.
  echo ""
  echo "--- transition  (w=" & $w & " h=" & $h & ") ---"

  # 1. The reported state, decided the OLD way: still waiting => screen 1.
  var oldWhy = ""
  let oldV = oldVerdict(inRaid(2000'i64), oldWhy)
  check(oldV == EwWaiting,
        "transition: the SHIPPED logic says 'keep waiting' while the player " &
        "is in a raid (this is the bug)")
  check(screenFor(true, true, oldV) == ScreenLauncher,
        "transition: ...and therefore stays on the LAUNCHER -- the red case")

  # 2. The same state, decided the new way: past it => log view.
  var why = ""
  let v = enterWaitVerdict(inRaid(2000'i64), why)
  check(v == EwPassed,
        "transition: the missing Menu UI root is read as 'already past " &
        "character select' (got " & $v & ")")
  check(why.len > 0, "transition: and it SAYS why: " & why)
  echo "      reason: " & why
  check(enterWaitDone(v), "transition: which is a terminal verdict")
  check(screenFor(true, true, v) == ScreenLogView,
        "transition: so the screen is the LOG VIEW")

  # 3. THE GRID. Not the integer -- the frame the player would be looking at.
  var srv = fakeTail("SRVLINE", 40)
  var cli = fakeTail("CLILINE", 40)
  if screenFor(true, true, v) == ScreenLogView:
    let lay = logViewRows(w, h, buildHeader(w),
                          stepRow(MarkDone, "launch", "SUMMARYLINE ready", w),
                          srv, cli, "SRVPANE 40", "CLIPANE 40",
                          0, 0, 0, false, buildHelp(w))
    check(lay.renderable, "transition: the log view renders")
    check(has(lay.rows, "SRVLINE") and has(lay.rows, "CLILINE"),
          "transition: and the frame in front of the player has BOTH logs")
    check(not has(lay.rows, "PROFROW") and not has(lay.rows, "PANELTITLE"),
          "transition: and NOT the profile panel they were stuck on")

  # 4. The bound is still there, and still announces itself. A wait that gives
  #    up silently is the same defect wearing a timer.
  var toWhy = ""
  var late = inRaid(0'i64)
  late.sawMenuRoot = false     # never reached the menu at all
  late.sawSelector = false
  late.menuRootPresent = false
  late.elapsedMs = EnterWaitLimitMs
  let toV = enterWaitVerdict(late, toWhy)
  check(toV == EwTimedOut, "transition: a client that never gets there times out")
  check(toWhy.len > 0, "transition: and the timeout states a reason: " & toWhy)
  check(screenFor(true, true, toV) == ScreenLogView,
        "transition: a timeout hands off to the logs rather than sitting there")

  # 5. THE COLD-BOOT CASE MUST STILL WAIT. This is what makes the fix a fix
  #    rather than a shortcut: "no Menu UI root" before the menu has EVER been
  #    seen is a client that has not got there yet, not one in a raid. Without
  #    the `sawMenuRoot` latch this would abandon auto-enter one poll after
  #    launch, on every single launch.
  var cold = EnterWait(sawMenuRoot: false, menuRootPresent: false,
                       sawSelector: false, selectorActive: false,
                       otherScreenActive: false, clientAlive: true,
                       elapsedMs: 4000'i64)
  var coldWhy = ""
  check(enterWaitVerdict(cold, coldWhy) == EwWaiting,
        "transition: a cold client that has not loaded the menu KEEPS waiting")
  check(screenFor(true, true, enterWaitVerdict(cold, coldWhy)) ==
        ScreenLauncher,
        "transition: ...and stays on the launcher, which is correct there")

  # 6. A dead client is not a raid. Checked before any screen reasoning,
  #    because a client that has exited has no Menu UI root either and would
  #    otherwise be reported as "in a raid".
  var dead = inRaid(2000'i64)
  dead.clientAlive = false
  var deadWhy = ""
  let deadV = enterWaitVerdict(dead, deadWhy)
  check(deadV == EwClientGone,
        "transition: an exited client is EwClientGone, not EwPassed")
  check(screenFor(true, false, deadV) == ScreenLogView,
        "transition: and it still hands off, so the logs can say what died")

  # 7. And the ordinary happy path is untouched.
  var up = EnterWait(sawMenuRoot: true, menuRootPresent: true,
                     sawSelector: true, selectorActive: true,
                     otherScreenActive: false, clientAlive: true,
                     elapsedMs: 30000'i64)
  var upWhy = ""
  check(enterWaitVerdict(up, upWhy) == EwSelectorUp,
        "transition: character select actually being up still means PRESS IT")

  # 8. NO STATE SITS ON THE LAUNCHER FOREVER. Swept rather than argued: over
  #    every combination of the observable flags, any state at the wall-clock
  #    bound must be terminal. This is the property the whole bug violated.
  var stuck = 0
  for a in 0 ..< 64:
    var e = EnterWait(sawMenuRoot: (a and 1) != 0,
                      menuRootPresent: (a and 2) != 0,
                      sawSelector: (a and 4) != 0,
                      selectorActive: (a and 8) != 0,
                      otherScreenActive: (a and 16) != 0,
                      clientAlive: (a and 32) != 0,
                      elapsedMs: EnterWaitLimitMs)
    var r = ""
    if not enterWaitDone(enterWaitVerdict(e, r)): inc stuck
    if r.len == 0 and enterWaitDone(enterWaitVerdict(e, r)): inc stuck
  check(stuck == 0,
        "transition: of 64 observable states, " & $stuck & " could still be " &
        "on the launcher at the time bound (must be 0), and every terminal " &
        "one carries a reason")

  # 9. A CHANNEL THAT NEVER ANSWERS. The player was sitting AT character select
  #    for 66 seconds while the wait reported nothing but a clock. Whatever the
  #    cause -- liveInspector off, or another tool overwriting the command file,
  #    which nothing arbitrates -- a wait learning nothing must say so and hand
  #    off, not keep counting.
  var silent = EnterWait(sawMenuRoot: false, menuRootPresent: false,
                         sawSelector: false, selectorActive: false,
                         otherScreenActive: false, clientAlive: true,
                         elapsedMs: 9000'i64, polls: EwNoChannelPolls,
                         answered: 0, interactive: true)
  var silentWhy = ""
  let silentV = enterWaitVerdict(silent, silentWhy)
  check(silentV == EwNoChannel,
        "transition: polls that all go unanswered are EwNoChannel, not " &
        "'still waiting' (got " & $silentV & ")")
  check(screenFor(true, true, silentV) == ScreenLogView,
        "transition: ...and hand off rather than sitting there")
  echo "      reason: " & silentWhy
  # One dropped poll is routine and must NOT trip it.
  var blip = silent
  blip.polls = 1
  var blipWhy = ""
  check(enterWaitVerdict(blip, blipWhy) == EwWaiting,
        "transition: a single dropped poll is routine and keeps waiting")
  # A channel that IS answering never trips it, however long it takes.
  var slow = silent
  slow.polls = 20
  slow.answered = 20
  slow.sawMenuRoot = true
  slow.menuRootPresent = true
  var slowWhy = ""
  check(enterWaitVerdict(slow, slowWhy) == EwWaiting,
        "transition: an answering channel keeps waiting, however many polls")

  # 10. THE DETAIL NAMES WHAT IT SAW. A clock alone made "menu up, watching"
  #     and "nothing has answered" render identically -- the same blind spot
  #     one level down. Two distinct states must produce two distinct strings.
  let dSilent = enterWaitDetail(silent, silentV)
  let dSlow = enterWaitDetail(slow, EwWaiting)
  echo "      detail(silent): " & dSilent
  echo "      detail(slow):   " & dSlow
  check(dSilent != dSlow,
        "transition: a silent channel and a live one do NOT render the same")
  check(dSlow.contains("menu root: yes") and dSlow.contains("poll"),
        "transition: the live detail names the menu root and the poll count")
  check(dSilent.contains("no answer"),
        "transition: the silent detail says the inspector is not answering")

  # 11. THE HUMAN-PRESENT BOUND. 60s+ of an apparently frozen screen is what
  #     the player called weird. When someone is watching, the wait gives up
  #     quickly and hands them the logs -- they can press the button in a
  #     second. Headless, where auto-enter is the only way in and nobody is
  #     looking at a screen, the long bound stays.
  check(enterWaitLimitMs(true) < enterWaitLimitMs(false),
        "transition: an interactive launcher gives up sooner than a headless one")
  check(enterWaitLimitMs(true) <= 30000'i64,
        "transition: ...and gives up within 30s (got " &
        $(enterWaitLimitMs(true) div 1000'i64) & "s)")
  var human = EnterWait(sawMenuRoot: true, menuRootPresent: true,
                        sawSelector: false, selectorActive: false,
                        otherScreenActive: false, clientAlive: true,
                        elapsedMs: 25000'i64, polls: 8, answered: 8,
                        interactive: true)
  var humanWhy = ""
  check(enterWaitVerdict(human, humanWhy) == EwTimedOut,
        "transition: 25s with a human watching is over the bound")
  check(screenFor(true, true, enterWaitVerdict(human, humanWhy)) ==
        ScreenLogView,
        "transition: so they get the logs")
  var headless = human
  headless.interactive = false
  var headWhy = ""
  check(enterWaitVerdict(headless, headWhy) == EwWaiting,
        "transition: the SAME 25s headless keeps waiting -- a cold boot " &
        "legitimately takes 90s+ and nobody is looking at a screen")

proc main(): int =
  # Pin the rendering so the grid is plain ASCII and a match means what it says.
  discard termStart()
  forcePlain()
  forceAscii()

  runSize(200, 50, true, "200x50")
  runSize(120, 30, true, "120x30")
  runSize(80, 24, true, "80x24")
  runSize(40, 12, true, "40x12")
  runSize(39, 11, false, "39x11")
  # One row below the minimum with the full window width: the height ladder has
  # to refuse on its own, not only as a side effect of a narrow window.
  runSize(120, 11, false, "120x11")
  runSolo(80, 24)

  # Screen 1, at the same ladder of sizes.
  runLauncher(200, 50, 6, true, "200x50")
  runLauncher(120, 30, 6, true, "120x30")
  runLauncher(80, 24, 6, true, "80x24")
  runLauncher(40, 12, 6, true, "40x12")
  runLauncher(39, 11, 6, false, "39x11")
  runLauncher(120, 11, 6, false, "120x11")
  # FIRST RUN, at a comfortable size and at the smallest one that renders.
  runLauncher(120, 30, 0, true, "120x30 first-run")
  runLauncher(40, 12, 0, true, "40x12 first-run")
  # More profiles than the panel can hold: it must SAY how many it hid rather
  # than quietly showing the first few.
  runLauncher(80, 24, 40, true, "80x24 overflow")

  # Screen 1 at a tall window with a SHORT list -- the size at which the panel
  # used to be a border round thirty-five blank rows.
  runLauncher(200, 50, 2, true, "200x50 short list")

  notFused(120, 30)
  notFused(80, 24)
  leakProof(120, 30)
  leakProof(80, 24)
  transition(120, 30)
  # Both sides of the `width > 24` split: the narrow column is where
  # `IL2CPP runtime` -- a name the launcher really uses -- was already
  # colliding before `character select` ever existed.
  stepColumns(120)
  stepColumns(80)
  stepColumns(24)
  handoff(119)
  handoff(39)

  echo ""
  if failures == 0:
    echo "PASS  " & $checks & " checks"
    result = 0
  else:
    echo "FAIL  " & $failures & " of " & $checks & " checks"
    result = 1

quit(main())
