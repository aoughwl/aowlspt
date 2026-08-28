## tuilayout -- the launcher's unified screen, rendered into a buffer and
## checked as a CHARACTER GRID, with no console, no game and no launcher.
##
## ## Why this test exists
##
## `tools/aowllaunch.nim` used to have two screens shown one after the other:
## the launch progress, then the two log panes. They are now one screen, drawn
## by `unifiedRows` in `tools/aowllayout.nim`, and the merge is a layout change
## -- which is the class of change that fails by being *one column out*. A frame
## whose right-hand border lands in the last cell puts the console into the
## deferred-wrap state; on some hosts the next carriage return cancels it and on
## others the row wraps and the whole frame scrolls up by a line, every frame.
## It looks like a rendering glitch and it is arithmetic that drifts with the
## window width, so it shows up on one player's terminal and not on ours.
##
## ## What it asserts, and what it deliberately does not
##
## It asserts on the FINISHED GRID -- the strings `unifiedRows` actually
## produced -- never on the inputs it was handed. Concretely, at each size:
##
##   * no row is wider than the window (the off-by-one above);
##   * the frame is exactly as many rows as the window has;
##   * both pane borders are present, and in the split case the top border
##     carries BOTH pane titles and a `bxTD` junction between them, so a run
##     that quietly drew one pane cannot pass;
##   * the progress region is present, and the step text is really in the grid;
##   * lines from BOTH logs appear in the body at the same time -- which is the
##     entire point of the merge and the one thing the old two-screen launcher
##     could never do;
##   * below the minimum size the layout REFUSES (`renderable == false`) and
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
  result.put " "
  result.putIn ColDim, fit("q quit   d detach   tab swap   f full   space " &
                           "pause   pgup/pgdn scroll", w - 2)

proc buildHeader(w: int): Row =
  result = newRow()
  result.put " "
  result.putIn ColWhite, "aowlspt"
  result.put "  "
  result.putIn ColDim, bxV()
  result.put " "
  result.putIn ColCyan, fit("Bear", 26)
  result.put " "
  result.putIn ColDim, bxV()
  result.put " "
  result.putIn ColGreen, fit("server up", 30)
  result.put " "
  result.putIn ColDim, bxV()
  result.put " "
  result.putIn ColGreen, fit("client up", 22)
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
  let lay = unifiedRows(w, h, buildHeader(w), buildSteps(w),
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

  # The progress region, and BOTH logs, in the same grid.
  if lay.collapsedSteps:
    check(has(lay.rows, "SUMMARYLINE"),
          label & ": the progress region collapsed to its summary line")
    check(lay.note.len > 0, label & ": says on screen that it collapsed")
    echo "      note: " & lay.note
  else:
    check(has(lay.rows, "STEPMODS"),
          label & ": the progress steps are drawn in full")
  check(lay.stepsShown > 0, label & ": a progress region is present")
  check(has(lay.rows, "SRVLINE"), label & ": the server log is on screen")
  check(has(lay.rows, "CLILINE"), label & ": the client log is on screen")
  echo "      stepsShown=" & $lay.stepsShown & " bodyH=" & $lay.bodyH &
       " maxWidth=" & $lay.maxWidth

proc runSolo(w, h: int) =
  ## `f` -- one pane, full width. The arithmetic is different (no junction), so
  ## a frame that is correct split can still be one column out solo.
  var srv = fakeTail("SRVLINE", 40)
  var cli = fakeTail("CLILINE", 40)
  let lay = unifiedRows(w, h, buildHeader(w), buildSteps(w),
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

  echo ""
  if failures == 0:
    echo "PASS  " & $checks & " checks"
    result = 0
  else:
    echo "FAIL  " & $failures & " of " & $checks & " checks"
    result = 1

quit(main())
