## Console output for the installer.
##
## An installer is read by someone who is about to let a program rewrite a
## 40 GB game directory, so every line it prints is either a fact about their
## machine or an action it is going to take. There is no progress spinner and
## no decoration: `--dry-run` output and real output differ only in whether the
## work happened, which is what makes the dry run worth reading.

import std/[syncio, strutils]
import tui

type
  Verbosity* = enum
    vQuiet    ## errors only
    vNormal   ## the default: steps and results
    vVerbose  ## every file touched

var
  gVerbosity = vNormal
  gDryRun = false
  gErrors = 0
  gWarnings = 0

# --------------------------------------------------------------- boxed mode
#
# `heading` is the only seam in this module, and that is what makes a boxed
# front end possible without touching a single call site elsewhere: when boxing
# is on, output between one `heading` and the next is BUFFERED, and the buffer
# is drawn as a finished box the moment the next heading (or `endSection`)
# arrives. That ordering is why the box can have the right width and a bottom
# border at all -- you cannot draw a border around lines you have not seen.
#
# Boxing is OFF by default. `aowlsptinstall.nim` turns it on only after asking
# `aowlterm` whether there is a VT console wide enough, so a redirected run, a
# pipe, a dumb terminal, a 30-column window and `--plain` all keep the plain
# line output that every other path in this file has always produced.

var
  gBoxed = false
  gBoxWidth = tui.DefaultBoxWidth
  gGlyphs = tui.asciiGlyphs()
  gColour = false
  gSecOpen = false
  gSecTitle = ""
  gSecLines: seq[string] = @[]

proc boxed*(): bool =
  result = gBoxed

proc endSection*() =
  ## Flush whatever section is open. Safe to call when none is, and safe to
  ## call twice -- every exit path calls it, and an installer that quits with a
  ## half-drawn box has told the reader nothing about how it ended.
  if not gSecOpen:
    return
  gSecOpen = false
  let title = gSecTitle
  var body = gSecLines
  gSecTitle = ""
  gSecLines = @[]
  if body.len == 0:
    body.add ""
  var style = tui.bsPlain
  for b in body:
    if b.startsWith("error") or b.startsWith("MISSING"):
      style = tui.bsBad
  echo ""
  let lines = tui.boxLines(gGlyphs, title, body, gBoxWidth, style, gColour)
  for l in lines:
    echo l

proc setBoxed*(on: bool; width: int; ascii, colour: bool) =
  ## Called once, from `main`, with answers that came from the terminal rather
  ## than from a guess.
  endSection()
  gBoxed = on
  gBoxWidth = tui.clampWidth(width)
  gGlyphs = tui.glyphsFor(ascii)
  gColour = colour

proc emitLine(msg: string) =
  ## Every line in this module goes through here. Boxed, it is captured;
  ## unboxed, it is the `echo` it always was.
  if gBoxed and gSecOpen:
    gSecLines.add msg
  else:
    echo msg

proc setVerbosity*(v: Verbosity) =
  gVerbosity = v

proc setDryRun*(on: bool) =
  gDryRun = on

proc dryRun*(): bool =
  result = gDryRun

proc verbosity*(): Verbosity =
  result = gVerbosity

proc errorCount*(): int =
  result = gErrors

proc warningCount*(): int =
  result = gWarnings

# ---------------------------------------------------------------------------

proc emit(tag, msg: string) =
  ## Every line is `tag  message`, tag padded to a fixed width, so a terminal
  ## full of them reads as a column rather than as prose.
  var line = tag
  while line.len < 6:
    line.add ' '
  line.add msg
  emitLine line

proc say*(msg: string) =
  ## An ordinary step.
  if gVerbosity >= vNormal:
    if gDryRun:
      emit "would", msg
    else:
      emit "", msg

proc note*(msg: string) =
  ## A fact discovered about the machine. Not an action, so it is not prefixed
  ## with `would` even in a dry run.
  if gVerbosity >= vNormal:
    emit "", msg

proc ok*(msg: string) =
  if gVerbosity >= vNormal:
    emit "ok", msg

proc detail*(msg: string) =
  if gVerbosity >= vVerbose:
    emit "", "  " & msg

proc warn*(msg: string) =
  inc gWarnings
  emit "warn", msg

proc err*(msg: string) =
  inc gErrors
  emit "error", msg

proc fatal*(msg: string) =
  ## Refuse to continue. Used for every precondition that, if ignored, would
  ## leave the user with a half-patched install — which is worse than no
  ## install at all, because it looks like it should work.
  emit "error", msg
  # Flush the open box first: a `quit` that leaves a section buffered discards
  # exactly the lines that explain why it quit.
  endSection()
  quit(1)

proc line*(msg: string) =
  ## A plain line of report output. Goes through here rather than to `echo`
  ## directly so that `--quiet` actually means quiet.
  if gVerbosity >= vNormal:
    emitLine msg

proc heading*(msg: string) =
  if gVerbosity >= vNormal:
    if gBoxed:
      endSection()
      gSecOpen = true
      gSecTitle = msg
      gSecLines = @[]
      return
    echo ""
    echo msg
    var rule = ""
    for i in 0 ..< msg.len:
      rule.add '-'
    echo rule

proc banner*(title: string; body: seq[string]; good: bool) =
  ## A standalone box that is not a section: the opening title card and the
  ## closing verdict. Degrades to the same plain lines the installer has always
  ## printed, so nothing here is only readable on a good terminal.
  if gVerbosity >= vNormal:
    endSection()
    if not gBoxed:
      echo ""
      echo title
      for b in body:
        echo "  " & b
      return
    echo ""
    let style = (if good: tui.bsGood else: tui.bsBad)
    let lines = tui.boxLines(gGlyphs, title, body, gBoxWidth, style, gColour)
    for l in lines:
      echo l

var gProgressPainted = false

proc progressStep*(i, n: int; what: string) =
  ## One step of the install, drawn in place when there is a VT console to draw
  ## on and printed as an ordinary line when there is not.
  ##
  ## In place rather than on the alternate screen, and for the same reason the
  ## launcher paints its boot block in place: what is left behind in the
  ## scrollback afterwards is the transcript a tester will be asked to paste.
  ## `--verbose` and `--dry-run` also fall through to plain lines, because in
  ## both of those the per-step text IS the output and overwriting it would
  ## throw away the thing that was asked for.
  if gVerbosity < vNormal:
    return
  if not (gBoxed and gColour) or gVerbosity >= vVerbose or gDryRun:
    say what
    return
  let inner = gBoxWidth - 4
  var barCells = inner div 3
  if barCells < 8: barCells = 8
  var row = tui.progressLine(i, n, barCells, gGlyphs.h == "-")
  row.add "  "
  row.add tui.fitCols(what, inner - tui.colsOf(row))
  var s = ""
  if gProgressPainted:
    s.add "\e[1A"
  gProgressPainted = true
  s.add "\r" & row & "\e[K\n"
  write stdout, s
  flushFile stdout

proc endProgress*() =
  ## Stop repainting; anything printed afterwards goes beneath the last frame
  ## rather than over it.
  gProgressPainted = false

proc refusal*(title: string; body: seq[string]) =
  ## A refusal is always a box of its own and always counts as an error, so
  ## that no path can decline quietly. There is no variant of this that prints
  ## nothing: `--quiet` suppresses steps, not the reason a run stopped.
  inc gErrors
  endSection()
  if not gBoxed:
    echo ""
    echo title
    for b in body:
      echo "  " & b
    return
  echo ""
  let lines = tui.boxLines(gGlyphs, title, body, gBoxWidth, tui.bsBad, gColour)
  for l in lines:
    echo l
