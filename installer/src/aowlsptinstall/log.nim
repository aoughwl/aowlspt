## Console output for the installer.
##
## An installer is read by someone who is about to let a program rewrite a
## 40 GB game directory, so every line it prints is either a fact about their
## machine or an action it is going to take. There is no progress spinner and
## no decoration: `--dry-run` output and real output differ only in whether the
## work happened, which is what makes the dry run worth reading.

import std/[syncio, strutils]

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
  echo line

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
  quit(1)

proc line*(msg: string) =
  ## A plain line of report output. Goes through here rather than to `echo`
  ## directly so that `--quiet` actually means quiet.
  if gVerbosity >= vNormal:
    echo msg

proc heading*(msg: string) =
  if gVerbosity >= vNormal:
    echo ""
    echo msg
    var rule = ""
    for i in 0 ..< msg.len:
      rule.add '-'
    echo rule
