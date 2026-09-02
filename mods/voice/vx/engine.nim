## vx/engine — the one place this mod touches the outside world.
##
## Every external dependency (whisper, piper, llama.cpp, curl, the recorder) is
## reached the same way: resolve a path, **probe** it, then run it as a child
## process. Nothing is dynamically linked into the backend, so a broken engine is
## a bad HTTP response rather than a dead backend.
##
## The probe is not decoration. The brief for this mod was explicit: *do not
## assume a model file exists; detect and report clearly if missing rather than
## failing obscurely*. So every engine resolves the exact absolute path it would
## use and reports it, present or not, on `/aowlspt/voice/status`. A missing
## model reads `missing: D:\...\ggml-base.en.bin` and the pipeline degrades with
## a note; it never silently produces nothing and calls it success.

import std/[strutils, osproc, syncio]
import std/private/oscommons
import aowlspt

type
  Probe* = object
    ## What one external dependency resolved to, and whether it is really there.
    slot*: string      ## "stt", "llm", "tts", "rec", "curl"
    id*: string        ## the engine id chosen by config, e.g. "whisper-server"
    path*: string      ## the exact absolute path (or command) that would run
    extra*: string     ## a second required file, usually the model
    ok*: bool
    note*: string

proc exists*(p: string): bool =
  ## `fileExists` with an empty path treated as absent rather than as an error.
  if p.len == 0: return false
  result = fileExists(p)

proc probeOf*(slot, id, path, extra: string): Probe =
  ## Build a probe by checking both files. An engine with no files (`builtin`,
  ## `none`, `sapi`) passes `""` for both and is reported ok.
  var r = Probe(slot: slot, id: id, path: path, extra: extra, ok: true, note: "")
  if path.len > 0 and not exists(path):
    r.ok = false
    r.note = "missing: " & path
  elif extra.len > 0 and not exists(extra):
    r.ok = false
    r.note = "missing: " & extra
  else:
    r.note = (if path.len > 0: "ok: " & path else: "ok (no external file)")
  result = r

# ---------------------------------------------------------------------------
# Running things
# ---------------------------------------------------------------------------

type
  RunResult* = object
    output*: string
    code*: int
    failed*: bool   ## true when the process could not be started at all

proc runCmd*(command: string; input: string = ""): RunResult =
  ## Run a shell command, optionally writing `input` to its stdin, and collect
  ## stdout+stderr. `osproc.execCmdEx` is `{.raises.}`, so the try/except is
  ## mandatory in nimony, not defensive style -- and it is also the thing that
  ## turns "the exe is not there" into a value instead of a torn-down worker.
  var r = RunResult(output: "", code: -1, failed: true)
  try:
    let (o, c) = execCmdEx(command, input = input)
    r.output = o
    r.code = c
    r.failed = false
  except:
    r.output = ""
    r.code = -1
    r.failed = true
  result = r

proc psQuote*(s: string): string =
  ## A PowerShell single-quoted literal, nested inside the double-quoted
  ## `-Command` argument. Single quotes suppress every kind of PowerShell
  ## expansion, so a path with a `$` in it is a path and not a variable.
  result = "'" & s.replace("'", "") & "'"

proc spawnDetached*(exe, args: string): bool =
  ## Start a long-lived helper (whisper-server) and do not wait for it.
  ##
  ## It goes through PowerShell's `Start-Process`, and that indirection is
  ## load-bearing rather than decoration.
  ##
  ## `CreateProcess` -- which is what `startProcess` and `cmd /c start` both end
  ## up calling with handle inheritance on -- gives the child a duplicate of
  ## every inheritable handle we hold, our stdout pipe included. whisper-server
  ## then lives for the rest of the session holding the write end of a pipe it
  ## will never write to, and **the read end never sees EOF**. Measured, twice:
  ## the route returned its answer and then the process hung at exit, and a
  ## caller reading our output waited forever.
  ##
  ## `Start-Process` passes `bInheritHandles = FALSE`, so nothing of ours
  ## crosses into the server. It costs about half a second of PowerShell
  ## start-up, once per backend lifetime, which is the right trade for a hang.
  ##
  ## There is deliberately no supervision beyond this -- see DESIGN.md §5; this
  ## returns whether the launcher was accepted, nothing more.
  let r = runCmd("powershell -NoProfile -NonInteractive -Command " &
                 "\"Start-Process -FilePath " & psQuote(exe) &
                 " -ArgumentList " & psQuote(args) &
                 " -WindowStyle Hidden\"")
  result = not r.failed

proc quoteArg*(s: string): string =
  ## Windows command-line quoting for a path. Paths here come from config and
  ## from our own temp-name builder, never from request bodies -- but quote
  ## anyway, because a config path with a space is normal and silently building
  ## a broken command line is exactly the obscure failure this mod must not have.
  result = "\"" & s.replace("\"", "") & "\""

# ---------------------------------------------------------------------------
# Files
# ---------------------------------------------------------------------------

proc readAll*(path: string): string =
  result = ""
  try:
    result = readFile(path)
  except:
    result = ""

proc writeAll*(path, content: string): bool =
  try:
    writeFile(path, content)
    result = true
  except:
    result = false

proc sizeOfFile*(path: string): int =
  ## Byte size, or -1. Used to say "piper produced a 0-byte wav" out loud rather
  ## than handing back a path to silence.
  if not exists(path): return -1
  result = readAll(path).len

proc joinPath*(a, b: string): string =
  if a.len == 0: return b
  if a.endsWith("/") or a.endsWith("\\"): result = a & b
  else: result = a & "/" & b

# ---------------------------------------------------------------------------
# Text hygiene
# ---------------------------------------------------------------------------

proc stripBrackets*(s: string): string =
  ## whisper.cpp emits `[_BEG_]`, `[BLANK_AUDIO]`, `[MUSIC]` and friends inline.
  ## EFMB stripped them with a regex; nimony has no regex, and a scanner is
  ## clearer anyway.
  result = ""
  var depth = 0
  for ch in s:
    if ch == '[': depth = depth + 1
    elif ch == ']':
      if depth > 0: depth = depth - 1
    elif depth == 0:
      result.add ch

proc collapseSpace*(s: string): string =
  result = ""
  var lastWasSpace = true
  for ch in s:
    let c = (if ch == '\n' or ch == '\r' or ch == '\t': ' ' else: ch)
    if c == ' ':
      if not lastWasSpace: result.add ' '
      lastWasSpace = true
    else:
      result.add c
      lastWasSpace = false
  result = result.strip()

proc oneLine*(s: string): string =
  result = collapseSpace(stripBrackets(s))
