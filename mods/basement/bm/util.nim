## bm/util — subprocess, files, hashing, time, text hygiene.
##
## The one place aowl.basement touches the outside world, and the only place
## that formats a float. Everything here is pure or a child process; nothing
## keeps world state.
##
## DECISIONS MADE HERE (the contract left them open):
##
## * **Floats are serialised at exactly 3 decimals** (`fmtF`). The world must
##   survive save -> load -> save byte-identically (DESIGN §9.2), and
##   `aowlspt/json`'s `asFloat` accumulates a fraction by repeated `*0.1`, so
##   `0.37` does not necessarily come back as the same double. A fixed 3-decimal
##   text form is *idempotent* under that round trip whatever the parser's last
##   bit does: the check is on the finished bytes, not on our own write. Every
##   float the world stores is quantised through `quant3` on the way in, so the
##   in-memory value and the document agree too.
## * **`wallMs` costs one PowerShell start-up, once per process.** There is no
##   `std/times` here (forbidden by the contract) and `nowMs()` is "ms since
##   host start", which is not a wall clock and resets every launch. So the
##   epoch is read once via `[DateTimeOffset]::UtcNow` and every later call is
##   that base plus the `nowMs()` delta. If PowerShell fails, `wallMs` returns
##   `nowMs()` and `wallMsIsReal()` says false -- it never invents an epoch and
##   calls it a wall clock.
## * **`stripTags` takes bracketed tags anywhere, not only on their own line.**
##   A tag is `[` + an UPPER_SNAKE word of >= 3 chars + (`]` or `: ... ]`).
##   That shape cannot collide with prose, and a model that puts `[ATTACK]` at
##   the end of a sentence is the common case; a line-only rule would have
##   spoken it.

import std/[strutils, osproc, syncio]
import std/dirs
import std/paths
import std/errorcodes/errorcodes
import std/private/oscommons
import aowlspt

type
  RunResult* = object
    code*: int
    output*: string
    failed*: bool     ## true when the process could not be started at all

proc runCmd*(command: string; input: string = ""): RunResult =
  ## Run a shell command, collecting stdout+stderr. `execCmdEx` raises, and in
  ## nimony that is not a style question: without the handler a missing exe
  ## tears down the worker instead of returning a value a route can report.
  var r = RunResult(code: -1, output: "", failed: true)
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
  ## A PowerShell single-quoted literal. Single quotes suppress every kind of
  ## expansion, so a path containing `$` stays a path.
  result = "'" & s.replace("'", "") & "'"

proc quoteArg*(s: string): string =
  result = "\"" & s.replace("\"", "") & "\""

proc spawnDetachedPs(exe, args: string): bool =
  ## `Start-Process` passes `bInheritHandles = FALSE`, which is the property
  ## that matters (see the block below `quoteArg` for the two mechanisms that
  ## do not have it and what each one cost). It buys that property with a whole
  ## PowerShell start-up: MEASURED 2026-09-07, 197-204 ms on an idle machine
  ## and 300-500 ms on the live sidecar. `spawnDetachedProc` gets the same
  ## property from a direct CreateProcessW, so this is now the FALLBACK and the
  ## `spawnMode = "powershell"` setting -- kept, because a working slow path is
  ## worth having when an FFI call is the thing under suspicion.
  let r = runCmd("powershell -NoProfile -NonInteractive -Command " &
                 "\"Start-Process -FilePath " & psQuote(exe) &
                 " -ArgumentList " & psQuote(args) &
                 " -WindowStyle Hidden\"")
  result = not r.failed

# CreateProcessW, called DIRECTLY, because both of the ready-made mechanisms
# fail the one property that matters and both failures were MEASURED here on
# 2026-09-07:
#
# * `cmd /c start /b "" <child>` is reached THROUGH `runCmd`, so the grandchild
#   inherits the pipe `runCmd` created for that very call and the parent's read
#   never sees EOF: a 10-second child blocked the parent for 10110 ms.
#   Redirecting the child's streams in the command line does not help
#   (10112 ms); neither does dropping `/b` for a new console (10218 ms). The
#   handle is inherited before the child performs any redirection of its own.
# * `std/osproc.startProcess` hardcodes `bInheritHandles = WINBOOL 1`. It is
#   fast (~1 ms) and it does NOT capture the caller's own runCmd pipe -- but it
#   hands the child every inheritable handle the PROCESS holds, including the
#   stdout pipe whoever launched US is reading. MEASURED: with this backend run
#   under `subprocess.run(capture_output=True)`, four detached whisper-server
#   children inherited the pipe and `tools/basement_check.py` hung FOREVER
#   after the simulator itself had already exited. That is the same bug as the
#   first one with no time limit on it.
#
# `bInheritHandles = FALSE` is the property, not the mechanism. PowerShell's
# `Start-Process` has it and costs 197-204 ms of PowerShell start-up; this
# costs a CreateProcessW. No STARTF_USESTDHANDLES, so the child is given no
# std handles at all -- curl writes its body to a file (`-o`) and never to a
# pipe, and a server we start logs to its own file.

type
  StartupInfoW = object
    cb: uint32
    lpReserved, lpDesktop, lpTitle: pointer
    dwX, dwY, dwXSize, dwYSize: uint32
    dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags: uint32
    wShowWindow, cbReserved2: uint16
    lpReserved2: pointer
    hStdInput, hStdOutput, hStdError: pointer

  ProcessInformation = object
    hProcess, hThread: pointer
    dwProcessId, dwThreadId: uint32

proc createProcessW(appName, cmdLine, procAttrs, threadAttrs: pointer;
                    inheritHandles: int32; creationFlags: uint32;
                    environment, currentDir, startupInfo,
                    procInfo: pointer): int32 {.
  stdcall, dynlib: "kernel32", importc: "CreateProcessW", sideEffect.}

proc closeHandleK(h: pointer): int32 {.
  stdcall, dynlib: "kernel32", importc: "CloseHandle", sideEffect.}

const
  CreateNoWindow = 0x08000000'u32
  DetachedProcess = 0x00000008'u32
    ## NOT USED, and deliberately kept named so nobody re-adds it. MEASURED
    ## 2026-09-07 with a ctypes CreateProcessW harness outside this mod, the
    ## same command line three times:
    ##   flags 0x08000008 (NO_WINDOW|DETACHED) -> rc=1, a pid, and powershell
    ##                                            NEVER RAN (no output file)
    ##   flags 0x00000008 (DETACHED alone)     -> rc=1, a pid, same silence
    ##   flags 0x08000000 (NO_WINDOW alone)    -> rc=1, the file appears
    ## A console host handed no console AND no std handles dies before it runs
    ## its script, and CreateProcessW still reports success -- which is why
    ## `pttStart` reported "the wrapper may not have started" for a day.
    ## `bInheritHandles = FALSE` is the property we actually need, and
    ## CREATE_NO_WINDOW keeps it while giving the child its own hidden console.

proc nilPtr(): pointer = cast[pointer](0)

proc toWide(s: string): seq[uint16] =
  ## UTF-16LE with a NUL terminator. Non-ASCII bytes are passed through as
  ## Latin-1 code units rather than decoded: every path this is used with comes
  ## from config.json, which the loader has already read as UTF-8, and a wrong
  ## GUESS at an encoding would produce a path that silently does not exist.
  result = @[]
  for ch in s: result.add uint16(uint8(ch))
  result.add 0'u16

proc spawnDetachedProc(exe, args: string): bool =
  ## The command line is `"<exe>" <args>` with `lpApplicationName` NULL, which
  ## is what every other caller here already builds, so quoting behaviour does
  ## not change with the mechanism.
  var ok = false
  try:
    var cmdline = quoteArg(exe) & (if args.len > 0: " " & args else: "")
    var wide = toWide(cmdline)
    # Zeroed field by field rather than `default(T)`: nimony rejects `default`
    # on these, and a partially-initialised STARTUPINFOW is a CreateProcess
    # that reads garbage for `dwFlags` and takes a handle we never set.
    var si = StartupInfoW(cb: uint32(sizeof(StartupInfoW)),
                          lpReserved: nilPtr(), lpDesktop: nilPtr(),
                          lpTitle: nilPtr(),
                          dwX: 0'u32, dwY: 0'u32, dwXSize: 0'u32,
                          dwYSize: 0'u32, dwXCountChars: 0'u32,
                          dwYCountChars: 0'u32, dwFillAttribute: 0'u32,
                          dwFlags: 0'u32, wShowWindow: 0'u16,
                          cbReserved2: 0'u16, lpReserved2: nilPtr(),
                          hStdInput: nilPtr(), hStdOutput: nilPtr(),
                          hStdError: nilPtr())
    var pi = ProcessInformation(hProcess: nilPtr(), hThread: nilPtr(),
                                dwProcessId: 0'u32, dwThreadId: 0'u32)
    let nilp = nilPtr()
    let rc = createProcessW(nilp, cast[pointer](addr wide[0]), nilp, nilp,
                            0'i32,                      # bInheritHandles FALSE
                            CreateNoWindow,   # NOT DetachedProcess: see above
                            nilp, nilp,
                            cast[pointer](addr si), cast[pointer](addr pi))
    if rc != 0'i32:
      # We never wait on it, so both handles are released at once; the child
      # keeps running. Leaking them would keep a zombie entry per sentence.
      discard closeHandleK(pi.hThread)
      discard closeHandleK(pi.hProcess)
      ok = true
  except:
    ok = false
  result = ok

var cSpawnMode: string = "process"
var gSpawnCalls: int = 0
var gSpawnFallbacks: int = 0
var gSpawnFailures: int = 0
var gSpawnLastMs: int64 = 0
var gSpawnNote: string = "no detached spawn yet"

proc spawnModeConfigure*(mode: string) =
  ## Anything other than the two known words is REFUSED and the note says so,
  ## rather than being taken as "the default" -- a typo in config.json must not
  ## read as a deliberate choice.
  if mode == "process" or mode == "powershell":
    cSpawnMode = mode
    gSpawnNote = "spawnMode = " & mode
  elif mode.len > 0:
    gSpawnNote = "spawnMode '" & mode & "' is not one of process|powershell; " &
                 "keeping " & cSpawnMode

proc spawnMode*(): string = cSpawnMode
proc spawnCalls*(): int = gSpawnCalls
proc spawnFallbacks*(): int = gSpawnFallbacks
proc spawnFailures*(): int = gSpawnFailures
proc spawnLastMs*(): int64 = gSpawnLastMs
proc spawnNote*(): string = gSpawnNote

proc spawnDetached*(exe, args: string): bool =
  ## Start `exe args` and return without waiting. The measured cost of THIS
  ## call is `spawnLastMs()`; `spawnNote()` says which mechanism produced it.
  let t0 = nowMs()
  gSpawnCalls = gSpawnCalls + 1
  var ok = false
  var how = ""
  if cSpawnMode == "process":
    ok = spawnDetachedProc(exe, args)
    how = "startProcess"
    if not ok:
      # A CreateProcess failure is nearly always a path PowerShell cannot fix
      # either, so the fallback is one attempt and it is COUNTED, never silent.
      gSpawnFallbacks = gSpawnFallbacks + 1
      ok = spawnDetachedPs(exe, args)
      how = "startProcess FAILED, fell back to Start-Process"
  else:
    ok = spawnDetachedPs(exe, args)
    how = "Start-Process"
  gSpawnLastMs = nowMs() - t0
  if not ok: gSpawnFailures = gSpawnFailures + 1
  gSpawnNote = how & ": " & (if ok: "started" else: "FAILED") & " " & exe &
               " in " & $gSpawnLastMs & " ms"
  result = ok

# ---------------------------------------------------------------------------
# Files
# ---------------------------------------------------------------------------

proc exists*(path: string): bool =
  if path.len == 0: return false
  result = fileExists(path)

proc readAll*(path: string): string =
  result = ""
  try:
    result = readFile(path)
  except:
    result = ""

proc listWavStems*(dir: string): seq[string] =
  ## The `<stem>` of every `<stem>.wav` directly under `dir`, sorted by the
  ## order the OS lists them; empty when the directory is missing (nimony's
  ## std/dirs has no dirExists -- walkDir with checkDir raises instead).
  result = @[]
  if dir.len == 0: return
  try:
    for entry in walkDir(path(dir), relative = true, checkDir = true):
      let n = $entry.path
      if n.len > 4 and (n.endsWith(".wav") or n.endsWith(".WAV")):
        result.add n[0 ..< n.len - 4]
  except:
    result = @[]

proc dirPresent*(dir: string): bool =
  if dir.len == 0: return false
  try:
    for entry in walkDir(path(dir), relative = true, checkDir = true):
      discard entry
    result = true
  except:
    result = false

proc removeIfPresent*(target: string): bool =
  ## True when the path is gone AFTERWARDS -- "it was not there" and "I deleted
  ## it" are the same finished state and the caller wants that, not the verb.
  ## False means something is still there that we could not remove.
  if target.len == 0: return true
  if not exists(target): return true
  try:
    discard tryRemoveFile(path(target))
  except:
    discard
  result = not exists(target)

proc writeAll*(path, content: string): bool =
  try:
    writeFile(path, content)
    result = true
  except:
    result = false

proc appendAll*(path, content: string): bool =
  let old = readAll(path)
  result = writeAll(path, old & content)

proc sizeOfFile*(path: string): int =
  ## -1 when missing, so "produced a 0-byte file" can be said out loud instead
  ## of being confused with "no file".
  if not exists(path): return -1
  result = readAll(path).len

proc joinPath*(a, b: string): string =
  if a.len == 0: return b
  if a.endsWith("/") or a.endsWith("\\"): result = a & b
  else: result = a & "/" & b

proc ensureDir*(dir: string): bool =
  ## Creates missing ANCESTORS too. `tryCreateFinalDir` makes exactly one
  ## level, so `<cache>/tts` fails when `<cache>` does not exist yet -- which
  ## is a real FAIL agent C hit, and it reads as "the cache is broken" rather
  ## than "one directory up is missing".
  if dir.len == 0: return false
  var prefix = ""
  var seg = ""
  var made = false
  var i = 0
  while i <= dir.len:
    var ch = '/'
    if i < dir.len: ch = dir[i]
    if i == dir.len or ch == '/' or ch == '\\':
      if seg.len > 0:
        if prefix.len > 0: prefix.add "/"
        prefix.add seg
        seg = ""
        # A bare drive letter ("C:") is not a directory anyone can create.
        if not (prefix.len == 2 and prefix[1] == ':'):
          try:
            let st = tryCreateFinalDir(path(prefix))
            made = (st == Success or st == NameExists)
          except:
            made = false
          if not made: return false
      elif i == 0:
        # A leading separator: keep it, so an absolute POSIX path stays one.
        prefix = ""
    else:
      seg.add ch
    i = i + 1
  result = made

proc trimSlash*(s: string): string =
  ## A base URL without its trailing separator, so `<base> & "/path"` cannot
  ## produce a double slash. One copy, in the one module both llm and speech
  ## already import -- it was briefly two, which is how a fix lands in one.
  result = s
  while result.len > 0 and (result[result.len-1] == '/' or
                            result[result.len-1] == '\\'):
    result = result[0 ..< result.len - 1]

proc baseName*(path: string): string =
  var i = path.len - 1
  while i >= 0 and path[i] != '/' and path[i] != '\\':
    i = i - 1
  result = path[i+1 ..< path.len]

# ---------------------------------------------------------------------------
# Time
# ---------------------------------------------------------------------------

var gWallBase: int64 = 0      ## epoch ms at the moment gWallAt was taken
var gWallAt: int64 = 0        ## nowMs() at that same moment
var gWallReal: bool = false
var gWallTried: bool = false

proc wallMsIsReal*(): bool = gWallReal

proc wallMs*(): int64 =
  ## Epoch milliseconds. One PowerShell start-up per process, then arithmetic.
  if not gWallTried:
    gWallTried = true
    let r = runCmd("powershell -NoProfile -NonInteractive -Command " &
                   "\"[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()\"")
    if not r.failed:
      var digits = ""
      for ch in r.output:
        if ch >= '0' and ch <= '9': digits.add ch
        elif digits.len > 0: break
      if digits.len >= 10:
        var v: int64 = 0
        for ch in digits:
          v = v * 10 + int64(ord(ch) - ord('0'))
        gWallBase = v
        gWallAt = nowMs()
        gWallReal = true
  if not gWallReal:
    return nowMs()
  result = gWallBase + (nowMs() - gWallAt)

# ---------------------------------------------------------------------------
# Hashing / formatting
# ---------------------------------------------------------------------------

proc fnv1a64*(s: string): uint64 =
  var h: uint64 = 0xcbf29ce484222325'u64
  for ch in s:
    h = h xor uint64(ord(ch))
    h = h * 0x100000001b3'u64
  result = h

proc hex64*(v: uint64): string =
  const hexd = "0123456789abcdef"
  result = ""
  var i = 0
  while i < 16:
    let nib = int((v shr uint64(60 - i*4)) and 0xF'u64)
    result.add hexd[nib]
    i = i + 1

proc quant3*(v: float): float =
  ## The value `fmtF` will print, as a float. Quantising on the way IN is what
  ## makes the in-memory world and the saved document agree.
  var neg = false
  var x = v
  if x < 0.0:
    neg = true
    x = -x
  var scaled = int64(x * 1000.0 + 0.5)
  result = float(scaled) / 1000.0
  if neg: result = -result

proc fmtF*(v: float): string =
  ## Fixed 3 decimals, no exponent, `-0.000` folded to `0.000`.
  var neg = false
  var x = v
  if x < 0.0:
    neg = true
    x = -x
  var scaled = int64(x * 1000.0 + 0.5)
  let whole = scaled div 1000
  let frac = scaled mod 1000
  var fs = $frac
  while fs.len < 3: fs = "0" & fs
  if scaled == 0: return "0.000"
  result = (if neg: "-" else: "") & $whole & "." & fs

# ---------------------------------------------------------------------------
# Text
# ---------------------------------------------------------------------------

proc isAlnum(ch: char): bool =
  (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
  (ch >= '0' and ch <= '9')

proc oneLine*(s: string): string =
  result = ""
  var lastSpace = true
  for ch in s:
    let c = (if ch == '\n' or ch == '\r' or ch == '\t': ' ' else: ch)
    if c == ' ':
      if not lastSpace: result.add ' '
      lastSpace = true
    else:
      result.add c
      lastSpace = false
  result = result.strip()

proc normalizeText*(s: string): string =
  ## lower, punctuation dropped, whitespace collapsed. Used for cache keys and
  ## keyword overlap; deliberately lossy and deliberately deterministic.
  var t = ""
  for ch in s:
    if isAlnum(ch): t.add ch
    elif ch == '\'': discard
    else: t.add ' '
  result = oneLine(t).toLowerAscii()

proc splitSentences*(s: string): seq[string] =
  ## `.` `!` `?` boundaries, punctuation kept, empties dropped. Trailing quotes
  ## and brackets ride with the sentence they close.
  result = @[]
  var cur = ""
  var i = 0
  while i < s.len:
    let ch = s[i]
    cur.add ch
    if ch == '.' or ch == '!' or ch == '?':
      # take any run of closing punctuation with it
      var k = i + 1
      while k < s.len and (s[k] == '"' or s[k] == '\'' or s[k] == ')' or
                           s[k] == ']' or s[k] == '.' or s[k] == '!' or
                           s[k] == '?'):
        cur.add s[k]
        k = k + 1
      let piece = cur.strip()
      if piece.len > 0: result.add piece
      cur = ""
      i = k
      continue
    i = i + 1
  let last = cur.strip()
  if last.len > 0: result.add last

proc looksLikeTag(s: string; startIdx: int; endIdx: int): bool =
  ## `s[startIdx]` is `[`, `s[endIdx]` is `]`. True when the head word is
  ## UPPER_SNAKE and at least 3 characters -- prose in square brackets is not.
  var i = startIdx + 1
  var n = 0
  while i < endIdx:
    let ch = s[i]
    if ch == ':': break
    if (ch >= 'A' and ch <= 'Z') or ch == '_':
      n = n + 1
      i = i + 1
    else:
      return false
  result = n >= 3

proc stripTags*(s: string; tags: var seq[string]): string =
  ## Removes `[TAG]` / `[TAG: …]` wherever they appear, appends each (without
  ## the brackets) to `tags`, and returns the remaining text with the spacing
  ## tidied. Anything bracketed that is not tag-shaped is left in the text.
  result = ""
  var i = 0
  while i < s.len:
    if s[i] == '[':
      var j = i + 1
      while j < s.len and s[j] != ']' and s[j] != '\n':
        j = j + 1
      if j < s.len and s[j] == ']' and looksLikeTag(s, i, j):
        tags.add s[i+1 ..< j].strip()
        i = j + 1
        continue
    result.add s[i]
    i = i + 1
  var lines: seq[string] = @[]
  for ln in result.split('\n'):
    let t = ln.strip()
    if t.len > 0: lines.add t
  result = ""
  var k = 0
  while k < lines.len:
    if k > 0: result.add "\n"
    result.add lines[k]
    k = k + 1

proc clampF*(v, lo, hi: float): float =
  if v < lo: return lo
  if v > hi: return hi
  result = v

proc clampI*(v, lo, hi: int): int =
  if v < lo: return lo
  if v > hi: return hi
  result = v

proc containsWord*(hay, needle: string): bool =
  ## Whole-word, case-insensitive. `containsWord("scavenger", "scav")` is FALSE
  ## -- substring matching is how a keyword classifier quietly fires on the
  ## wrong intent.
  if needle.len == 0: return false
  let h = " " & normalizeText(hay) & " "
  let n = " " & normalizeText(needle) & " "
  if n.len <= 2: return false
  result = h.contains(n)
