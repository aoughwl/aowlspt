## aowllayout -- the launcher's screens, as pure functions of their inputs.
##
## ## Two screens, one terminal, one after the other
##
## The launcher shows **two** views, in sequence, in the SAME console and the
## SAME process. Nothing is spawned for the second one and the two are never on
## screen together:
##
##   1. `launcherRows` -- the LAUNCHER. A header, the launch-progress region
##      (the ticks filling in as the backend claims its port, reads its
##      database, loads its mods and starts answering), and a panel listing the
##      profiles in this install with the affordance to play one or create a
##      new one. This is what a player looks at while the game is starting.
##   2. `logViewRows` -- the LIVE LOG view. The launch collapsed to a single
##      summary line and the two log panes, server and client, side by side.
##      The launcher swaps to this once the client is up.
##
## An earlier revision fused the two into one frame -- progress region on top,
## both panes below it, all the time -- and that is what this split undoes. The
## fused frame spent half a small window on panes nobody was reading yet and
## left the profile panel nowhere to go. `handoffRow` draws the one line that
## marks the swap, so the transition is something the player SEES rather than a
## region quietly collapsing under them.
##
## Neither function draws the other's furniture, and that is asserted rather
## than intended: `tests/tuilayout.nim` checks that a `launcherRows` frame does
## not contain the two-pane junction and that a `logViewRows` frame does not
## contain the profile panel. A fused frame fails both.
##
## ## Why the layout is a function and not a method on a view
##
## Because a function that returns `seq[Row]` can be rendered into a buffer by a
## test, with no console, no game and no launcher. `tests/tuilayout.nim` renders
## both views at 200x50, 120x30, 80x24, 40x12 and 39x11 and asserts on the
## resulting character grid -- that both pane borders are there, that no row is
## wider than the window, that the progress region and the profile panel are
## really populated, and that below the minimum each layout **refuses** rather
## than drawing something bent.
##
## That last part is the point. The failure this replaces is a frame that is one
## column out: it looks like a rendering glitch and is actually arithmetic that
## will drift with the window width. A test that asserts on the finished grid
## catches it; a test that asserts the layout was "called with" w=80 cannot.

import aowlterm

# ---------------------------------------------------------------------------
# Small formatting
# ---------------------------------------------------------------------------

proc secsText*(ms: int64): string =
  ## `4.2s`, `1m 04s`. Tenths below a minute because that is the range in which
  ## a difference of a tenth is something the reader is watching for.
  if ms < 0'i64: return "0.0s"
  if ms < 60000'i64:
    let tenths = int(ms div 100'i64)
    return $(tenths div 10) & "." & $(tenths mod 10) & "s"
  let secs = int(ms div 1000'i64)
  let m = secs div 60
  let s = secs mod 60
  result = $m & "m " & (if s < 10: "0" else: "") & $s & "s"

const
  MarkDone* = 0
  MarkActive* = 1
  MarkPending* = 2
  MarkFailed* = 3

proc markGlyph*(kind: int): string =
  if termAscii():
    case kind
    of MarkDone: "ok"
    of MarkActive: ">>"
    of MarkFailed: "!!"
    else: "  "
  else:
    case kind
    of MarkDone: "✔ "
    of MarkActive: "▸ "
    of MarkFailed: "✖ "
    else: "  "

proc markColour*(kind: int): int =
  case kind
  of MarkDone: ColGreen
  of MarkActive: ColCyan
  of MarkFailed: ColRed
  else: ColDim

proc stepRow*(kind: int; name, detail: string; width: int): Row =
  ## One progress line. Bounded by `width` by construction: the name column is
  ## fixed and the detail is `fit` into whatever is left, so this can never be
  ## the row that makes the frame overflow.
  result = newRow()
  result.put "  "
  result.putIn markColour(kind), markGlyph(kind)
  result.put " "
  result.putIn (if kind == MarkPending: ColDim else: ColDefault),
               fit(name, (if width > 24: 17 else: 12))
  result.padTo (if width > 24: 20 else: 15)
  let room = width - result.width - 2
  if room > 4 and detail.len > 0:
    result.putIn (if kind == MarkFailed: ColRed else: ColDim), fit(detail, room)

proc padded*(s: string; n: int): string =
  result = s
  while result.len < n: result.add ' '

proc streamText*(tag: string; l: LogLine): string =
  ## `server  [985ms] warn   the message`.
  ##
  ## The level is written out rather than being carried by the colour alone.
  ## This is the form that ends up in a redirected file, where there is no
  ## colour -- and a warning that reads exactly like an ordinary line is a
  ## warning nobody will find in three hundred lines of boot log. Built by
  ## padding a plain string rather than through `Row`, because `Row` may hold
  ## escapes and this line must be able to promise it holds none.
  result = padded(tag, 8)
  if l.stamp.len > 0:
    result = padded(result & "[" & l.stamp & "]", 8 + 11)
  else:
    result = padded(result, 8 + 11)
  let nm = levelName(l.level)
  if nm.len > 0: result.add nm
  result = padded(result, 8 + 11 + 6)
  result.add l.text

# ---------------------------------------------------------------------------
# The panes
# ---------------------------------------------------------------------------

proc borderCell*(title: string; n: int; focused: bool): Row =
  ## Exactly `n` columns of horizontal rule with a title sunk into it. Exactly,
  ## because it is one segment of a border that has to meet the next one.
  result = newRow()
  let h = bxH()
  result.putIn ColDim, h
  if n > 3:
    result.putIn (if focused: ColWhite else: ColDim), fit(" " & title & " ", n - 2)
  while result.width < n:
    result.putIn ColDim, h

proc drawPane*(t: Tail; scroll, rows, width: int; into: var seq[Row]) =
  ## `rows` lines of `t`, ending `scroll` lines from the newest. Padded to
  ## exactly `rows` so that the caller's loop does not have to know how many
  ## lines there were -- an empty pane is an empty pane, not a short frame.
  into = @[]
  let n = t.lines.len
  var last = n - scroll
  if last > n: last = n
  if last < 0: last = 0
  var first = last - rows
  if first < 0: first = 0
  # The two prefix columns are dropped, widest first, as the pane narrows.
  # A pane 16 columns wide spent all 16 on a timestamp and a level name and had
  # nothing left for the message -- so the split view at 80 columns, which is
  # where a player most needs it, showed two columns of clocks and no log. The
  # thresholds are the prefix plus enough room for a message worth reading.
  let wantStamp = width >= 30
  let wantLevel = width >= 20
  for i in first ..< last:
    var r = newRow()
    let l = t.lines[i]
    if wantStamp and l.stamp.len > 0:
      r.putIn ColDim, fit(l.stamp, 8)
      r.padTo 9
    if wantLevel:
      let nm = levelName(l.level)
      if nm.len > 0:
        r.putIn levelOf(l.level), nm
      r.padTo (if wantStamp and l.stamp.len > 0: 15 else: 6)
    let room = width - r.width
    if room > 2:
      r.putIn (if l.level == lvError: ColRed
               elif l.level == lvWarn: ColYellow
               else: ColDefault), fit(l.text, room)
    into.add r
  while into.len < rows:
    into.add newRow()

# ---------------------------------------------------------------------------
# Screen 2 -- the live log view
# ---------------------------------------------------------------------------

const
  MinCols* = 40
    ## Below this the split cannot hold a timestamp column on each side, and
    ## the caller must take the interleaved one-line-per-entry path instead.
  MinRows* = 12
  MinBody* = 5
    ## Fewer than five log lines per pane is not a log view, it is a teaser.
    ##
    ## This is no longer a THRESHOLD -- it is a GUARANTEE. `logViewRows` spends
    ## a fixed five rows on chrome (header, the one summary line, the two pane
    ## borders and the status line), so at `MinRows` the body is `12 - 6 = 6`
    ## and every larger window has more. There is therefore no size at which a
    ## degrade branch could fire, and one is not written: a branch that cannot
    ## fire is dead code that reads as a working degrade path, which is the bug
    ## this constant was given the value 5 to fix in the first place.
    ##
    ## `tests/tuilayout.nim` asserts `bodyH >= MinBody` at exactly `MinRows`, on
    ## the produced layout. That check goes red if anyone lowers `MinRows` or
    ## adds a row of chrome, which is the only way this guarantee can be lost.

type
  LogViewLayout* = object
    rows*: seq[Row]
    renderable*: bool
      ## false means the caller must fall back to `streamLogs`. `note` says why,
      ## and the caller is expected to print it: a view that silently becomes a
      ## different view is the failure mode this whole file is written against.
    bodyH*: int
    maxWidth*: int
      ## The widest row actually produced. The caller does not need it; the test
      ## asserts it against `w`, which is the only way to catch a frame that is
      ## one column out before a player sees it shear.
    note*: string

proc logViewRows*(w, h: int; header: Row; summary: Row;
                  server, client: var Tail;
                  serverTitle, clientTitle: string;
                  focus, scrollS, scrollC: int; solo: bool;
                  help: Row): LogViewLayout =
  ## SCREEN 2. Header, the launch summary, both panes, status -- exactly `h`
  ## rows, none wider than `w`, or `renderable = false` and a reason.
  ##
  ## This screen draws no profile panel and NO PROGRESS STEPS. It cannot: it is
  ## not given them. That is the fix for the defect the player actually
  ## reported -- "i can still see those checkboxes for the il2cpp and the other
  ## few items when we are side by side".
  ##
  ## The steps were never leaking out of the scrollback (the log view takes the
  ## alternate screen, so the scrollback is hidden while it runs). They were
  ## being drawn INSIDE this frame. The old signature took `steps` and folded
  ## them to `summary` only when the window was too short to hold both -- which
  ## at 120x30 it never is, so the five ticked boxes sat above the panes for the
  ## whole session while this docstring claimed the launch was "collapsed to one
  ## line". The parameter is gone rather than the branch reordered, because a
  ## screen that is not handed the rows cannot regress into drawing them.
  ##
  ## `w` is the drawing width and callers pass one column fewer than the console
  ## has. A glyph written into the last cell leaves the console in the
  ## deferred-wrap state and what happens next is host-specific: some hosts
  ## cancel it on the following carriage return and some wrap first and scroll
  ## the whole frame by a line, every frame. Giving up one column costs nothing.
  result = LogViewLayout(rows: @[], renderable: false,
                         bodyH: 0, maxWidth: 0, note: "")
  if w < MinCols or h < MinRows:
    result.note = "the window is " & $w & "x" & $h & ", which is too small " &
                  "for the split view; falling back to one line per entry"
    return

  # Five rows of chrome and no negotiation: header, the one summary line, the
  # two pane borders, the status line. Everything else is body. See `MinBody`
  # for why there is no degrade branch here any more.
  result.renderable = true
  result.bodyH = h - 5
  let bodyH = result.bodyH

  result.rows.add header
  result.rows.add summary

  # The pane arithmetic is written out rather than fudged with `padTo`, because
  # a frame whose columns are one out looks like a rendering bug and is actually
  # an off-by-one that drifts with the window width.
  #   split:  1 + (leftW+2) + 1 + (rightW+2) + 1 == w
  #   solo:   1 + (leftW+2) + 1                  == w
  var leftW = 0
  var rightW = 0
  if solo:
    leftW = w - 4
  else:
    leftW = (w - 7) div 2
    rightW = (w - 7) - leftW

  var top = newRow()
  top.putIn ColDim, bxTL()
  if solo:
    top.putRow borderCell((if focus == 0: serverTitle else: clientTitle),
                          leftW + 2, true)
  else:
    top.putRow borderCell(serverTitle, leftW + 2, focus == 0)
    top.putIn ColDim, bxTD()
    top.putRow borderCell(clientTitle, rightW + 2, focus == 1)
  top.putIn ColDim, bxTR()
  result.rows.add top

  var leftRows: seq[Row] = @[]
  var rightRows: seq[Row] = @[]
  if solo:
    if focus == 0: drawPane(server, scrollS, bodyH, leftW, leftRows)
    else: drawPane(client, scrollC, bodyH, leftW, leftRows)
  else:
    drawPane(server, scrollS, bodyH, leftW, leftRows)
    drawPane(client, scrollC, bodyH, rightW, rightRows)

  for i in 0 ..< bodyH:
    var r = newRow()
    r.putIn ColDim, bxV()
    r.put " "
    r.putRow leftRows[i]
    r.padTo 2 + leftW
    if not solo:
      r.put " "
      r.putIn ColDim, bxV()
      r.put " "
      r.putRow rightRows[i]
    r.padTo w - 1
    r.putIn ColDim, bxV()
    result.rows.add r

  var bottom = newRow()
  bottom.putIn ColDim, bxBL()
  bottom.putIn ColDim, rule(leftW + 2)
  if not solo:
    bottom.putIn ColDim, bxTU()
    bottom.putIn ColDim, rule(rightW + 2)
  bottom.putIn ColDim, bxBR()
  result.rows.add bottom

  # The status line is the key reminder, and only that. It used to share the
  # row with a degradation note -- and at 40 columns the note WON, so the
  # smallest window was the one that told the player "launch progress collapsed
  # to one line" instead of telling them which key quits. There is no longer a
  # collapse to report: this screen never draws the progress region at any size,
  # so the note it was announcing does not exist.
  result.rows.add help

  for r in result.rows:
    if r.width > result.maxWidth: result.maxWidth = r.width

# ---------------------------------------------------------------------------
# Screen 1 -- the launcher
# ---------------------------------------------------------------------------

const
  MinPick* = 4
    ## Fewer than four lines in the profile panel is not a list of profiles, it
    ## is a hint that there might be some. Below this the progress region folds
    ## to its summary line to give the panel room, exactly as `MinBody` does for
    ## the log panes -- and for the same reason: a panel squeezed to one row
    ## would show the first profile and silently hide the rest, which is a
    ## chooser that lies about what there is to choose.
    ##
    ## FOUR, not three, and the difference is the whole value of the constant.
    ## The panel gets `h - 4 - steps` rows and the boot phase has five steps, so
    ## at the smallest window this layout will draw at all (`MinRows` = 12) the
    ## panel has 12 - 4 - 5 = 3. A threshold of 3 is therefore satisfied at
    ## every size that renders, the collapse never fires, and the branch below
    ## is DEAD CODE that looks like a working degrade path. That is exactly the
    ## bug `MinBody` had at 3, found by rendering the grid rather than by
    ## reading this file, and `tests/tuilayout.nim` now asserts the collapse
    ## really happens at 12 rows so it cannot come back.

type
  LauncherLayout* = object
    rows*: seq[Row]
    renderable*: bool
      ## false means the caller must fall back to printing plainly. `note` says
      ## why, and the caller is expected to print it.
    stepsShown*: int
    collapsedSteps*: bool
    bodyH*: int
    listed*: int
      ## How many profile rows actually reached the grid. The caller does not
      ## need it; the test asserts it against what it passed in, which is how a
      ## panel that dropped the tail of the list gets caught.
    hidden*: int
      ## Profiles that did not fit. Never silently zero when rows were dropped:
      ## the status line says so, because a list that is quietly short is a
      ## chooser offering fewer characters than the player owns.
    emptyPath*: bool
      ## True when the panel drew the CREATE path instead of a list, i.e. this
      ## install has no profiles yet. The first-run case is a distinct rendering
      ## and not an empty box, and this is the flag a test can assert on.
    usedRows*: int
      ## How many of `rows` carry anything. `rows` is always exactly `h` long,
      ## because a full-screen caller needs every row; a caller repainting a
      ## BLOCK in the scrollback (`paintPhase`) wants only this many, or it
      ## writes a screenful of blank lines into the transcript on every tick.
    maxWidth*: int
    note*: string

proc launcherRows*(w, h: int; header: Row; steps: seq[Row]; summary: Row;
                   panelTitle: string; profiles: seq[Row]; empty: seq[Row];
                   help: Row): LauncherLayout =
  ## SCREEN 1. Header, the launch-progress region, one full-width panel holding
  ## the profiles (or the create path when there are none), and a status line --
  ## exactly `h` rows, none wider than `w`, or `renderable = false` and a
  ## reason.
  ##
  ## This screen draws NO log panes. That is the whole point of it: while the
  ## backend is still coming up there is nothing in the client log but the last
  ## session's, and a pane showing a stale log next to a live one is the
  ## confidently-wrong answer the launcher exists to avoid. The logs get the
  ## whole window a moment later, in `logViewRows`.
  ##
  ## `empty` is drawn INSTEAD of `profiles` when `profiles` is empty. It is not
  ## optional and it is not decoration: "this install has no profiles" is the
  ## first-run case the launcher must answer with a way forward, and an empty
  ## box is a dead end. When both are empty the panel says so in as many words
  ## rather than rendering nothing.
  result = LauncherLayout(rows: @[], renderable: false, stepsShown: 0,
                          collapsedSteps: false, bodyH: 0, listed: 0,
                          hidden: 0, emptyPath: false, usedRows: 0,
                          maxWidth: 0, note: "")
  if w < MinCols or h < MinRows:
    result.note = "the window is " & $w & "x" & $h & ", which is too small " &
                  "for the launcher panel; falling back to plain lines"
    return

  # Header, the two panel borders and the status line are not negotiable.
  let avail = h - 4
  var shown = steps.len
  var collapsed = false
  if avail - shown < MinPick and shown > 1:
    shown = 1
    collapsed = true
    result.note = "launch progress collapsed to one line -- the window is " &
                  "only " & $h & " rows"
  if avail - shown < MinPick:
    result.note = "the window is " & $w & "x" & $h & ", which cannot hold " &
                  "the profile panel; falling back to plain lines"
    return

  result.renderable = true
  result.stepsShown = shown
  result.collapsedSteps = collapsed
  result.bodyH = avail - shown
  let bodyH = result.bodyH

  result.rows.add header
  if collapsed:
    result.rows.add summary
  else:
    for i in 0 ..< shown:
      result.rows.add steps[i]

  # One full-width panel: 1 + (innerW + 2) + 1 == w, written out rather than
  # fudged with `padTo`, for the same reason the pane arithmetic is.
  let innerW = w - 4

  var top = newRow()
  top.putIn ColDim, bxTL()
  top.putRow borderCell(panelTitle, innerW + 2, true)
  top.putIn ColDim, bxTR()
  result.rows.add top

  # What goes in the panel. The empty case is a DIFFERENT rendering, not a
  # shorter one.
  var content: seq[Row] = @[]
  if profiles.len > 0:
    for r in profiles: content.add r
  else:
    result.emptyPath = true
    if empty.len > 0:
      for r in empty: content.add r
    else:
      # The caller offered neither a list nor a way forward. Say that, rather
      # than draw a blank box the player would read as "still loading".
      var r = newRow()
      r.putIn ColYellow, fit("no profiles, and no way to create one was " &
                             "offered here", innerW)
      content.add r

  result.listed = content.len
  if result.listed > bodyH:
    result.hidden = result.listed - bodyH
    result.listed = bodyH
    let more = $result.hidden & " more not shown -- the window is only " &
               $h & " rows"
    if result.note.len > 0: result.note = result.note & "; " & more
    else: result.note = more

  # THE BOX IS SIZED TO WHAT IS IN IT, not to the window.
  #
  # It used to be `bodyH` rows tall unconditionally, so an install with six
  # profiles got a box with six rows of names and FIFTEEN blank rows under them
  # at 120x30 -- thirty-five at 200x50. That is not a panel with room to grow,
  # it is a frame that looks half-drawn, and it is the largest single thing
  # wrong with this screen by area. One trailing row is kept as breathing space;
  # the rest of the window is left blank BELOW the box, where empty space reads
  # as empty space instead of as a box someone forgot to fill.
  # `listed + 1`, and no `MinPick` floor. `MinPick` still decides whether the
  # progress region has to fold to make room -- that is a question about the
  # WINDOW -- but it has no business padding the box out past its contents,
  # which is a question about the LIST. A three-row floor over a one-row list is
  # two blank rows inside a border, i.e. the defect in miniature.
  var panelH = result.listed + 1
  if panelH > bodyH: panelH = bodyH
  if panelH < 1: panelH = 1

  for i in 0 ..< panelH:
    var r = newRow()
    r.putIn ColDim, bxV()
    r.put " "
    if i < result.listed:
      r.putRow content[i]
    r.padTo w - 1
    r.putIn ColDim, bxV()
    result.rows.add r

  var bottom = newRow()
  bottom.putIn ColDim, bxBL()
  bottom.putIn ColDim, rule(innerW + 2)
  bottom.putIn ColDim, bxBR()
  result.rows.add bottom

  # Same precedence as screen 2: the degradation note wins over the key
  # reminder when there is not room for both.
  var status = newRow()
  if result.note.len > 0 and w - help.width - 2 < 24:
    # Two spaces, not one: every other row this file produces starts its text
    # in column 2 (see `stepRow`, `handoffRow`, and the box interior, which is
    # a vertical plus one space). A single space here put the status line one
    # column left of everything above it -- small, and exactly the kind of
    # small that reads as "this was thrown together".
    status.put "  "
    status.putIn ColYellow, fit(result.note, w - 2)
  else:
    status.putRow help
    if result.note.len > 0:
      status.put "  "
      status.putIn ColYellow, fit(result.note, w - status.width - 1)
  result.rows.add status

  # The window still owes exactly `h` rows, and the slack the box gave back is
  # spent HERE, below everything.
  #
  # It was briefly spent between the box and the status line instead, which was
  # a straight trade of one ugly frame for another: the keys ended up marooned
  # at the bottom of a window whose content stopped fourteen rows above them.
  # Everything the screen has to say is now in one block at the top, in reading
  # order, and the empty part of the window is simply empty.
  result.usedRows = result.rows.len
  for i in 0 ..< (bodyH - panelH):
    result.rows.add newRow()

  for r in result.rows:
    if r.width > result.maxWidth: result.maxWidth = r.width

# ---------------------------------------------------------------------------
# The handoff between them
# ---------------------------------------------------------------------------

proc handoffRow*(w: int; what: string): Row =
  ## The single line that marks screen 1 giving way to screen 2.
  ##
  ## It exists so the swap is an event the player watched happen rather than a
  ## frame that silently became a different frame. The previous revision had no
  ## such moment -- the progress region just collapsed and the panes grew -- and
  ## "the screen changed and I do not know what I did" is a bug report nobody
  ## can act on. Bounded by `w` by construction, like every other row here.
  result = newRow()
  result.put "  "
  result.putIn ColGreen, markGlyph(MarkDone)
  result.put " "
  let room = w - result.width - 2
  if room > 4:
    result.putIn ColWhite, fit(what, room)
