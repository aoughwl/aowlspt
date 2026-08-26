## aowlspt-launch -- start Tarkov with the aowlspt host inside it.
##
##     aowlspt-launch                     from inside an aowlspt install
##     aowlspt-launch --root D:\Aowlspt
##     aowlspt-launch --root D:\Aowlspt --dry-run
##
## The install `aowlspt-install` builds is a normal Tarkov install with an
## `aowlspt/` directory beside the executable. This starts the executable
## suspended, loads `aowlspt/aowlspt-host-il2cpp.dll` into it, and resumes --
## so the game comes up with the host already running and nothing in the
## install pretending to be a Windows component. `aowlspt_inject.h` has the
## mechanism and the reasoning.
##
## It refuses to launch a client the host cannot work in, and says why, rather
## than starting a game that will quietly have no mods in it.
##
## ---------------------------------------------------------------------------
## This is the front end
## ---------------------------------------------------------------------------
##
## There is no GUI launcher and there is not going to be one, so the console is
## the whole of the interface: it checks the install, starts the server, asks
## which profile to play, starts the game, and then becomes a live view of the
## two logs. Those four phases are `bootView`, `pickProfile`, `clientView` and
## `runLogView` below, and each of them has one rule in common.
##
## **Nothing on the screen advances on a timer.** Every mark that fills in is a
## fact that was observed: the port answered, the backend's own log said
## `listening on 127.0.0.1:6970`, the log said `3 mod(s) selected` and then said
## `loaded` three times, `CreateProcess` returned, the injected host wrote
## `host running`. A spinner that turns while nothing happens is worse than no
## spinner, because it is a claim -- and the failure this launcher exists to
## make legible is precisely "it looks like it is working and it is not". Where
## something cannot be known, the screen says so and shows the last log line
## instead of inventing a percentage.
##
## The other rule is that all four phases degrade. `aowlterm` decides whether
## this is a VT console, a console without VT, or not a console at all; the
## views ask it and take one of three paths. A launcher whose output is being
## redirected into a file for somebody to read on Discord must produce a file
## with no escape codes in it, and a launcher in an 80x10 window must produce
## something legible in an 80x10 window. Both are checked in `runLogView`.

import std/[strutils, syncio, cmdline]
import aowlsptinstall/[winfs, log, eft]
import "../host/common/jsonpath"
import aowlterm
import aowlsession
import aowlui

{.emit: """#include <stdlib.h>""".}
{.emit: """#include <string.h>""".}
{.emit: """#include "aowlspt_shim.h" """.}
{.emit: """#include "aowlspt_inject.h" """.}

{.emit: """
static int64_t aowl_launch_now_ms(void) {
  return (int64_t)GetTickCount64();
}
""".}

proc cNowMs(): int64 {.importc: "aowl_launch_now_ms", nodecl.}

type LaunchPtr = nil pointer

proc cLaunchNew(): LaunchPtr {.importc: "aowl_launch_new", nodecl.}
proc cLaunchFree(p: LaunchPtr) {.importc: "aowl_launch_free", nodecl.}
proc cLaunchStart(p: LaunchPtr; exe, workDir, cmdLine: cstring): int32 {.
  importc: "aowl_launch_start", nodecl.}
proc cLaunchInject(p: LaunchPtr; dll: cstring): int32 {.
  importc: "aowl_launch_inject", nodecl.}
proc cLaunchResume(p: LaunchPtr): int32 {.importc: "aowl_launch_resume", nodecl.}
proc cLaunchKill(p: LaunchPtr) {.importc: "aowl_launch_kill", nodecl.}
proc cLaunchClose(p: LaunchPtr) {.importc: "aowl_launch_close", nodecl.}
proc cLaunchPid(p: LaunchPtr): uint32 {.importc: "aowl_launch_pid", nodecl.}
proc cLaunchError(p: LaunchPtr): uint32 {.importc: "aowl_launch_error", nodecl.}
proc cLaunchAlive(p: LaunchPtr): int32 {.importc: "aowl_launch_alive", nodecl.}
proc cLaunchWait(p: LaunchPtr; ms: int32): int32 {.
  importc: "aowl_launch_wait", nodecl.}
proc cSpawn(exe, workDir, cmdLine: cstring): uint64 {.
  importc: "aowl_spawn", nodecl.}
proc cSpawnQuiet(exe, workDir, cmdLine: cstring): uint64 {.
  importc: "aowl_spawn_quiet", nodecl.}
proc cSpawnAlive(h: uint64): int32 {.importc: "aowl_spawn_alive", nodecl.}
proc cSpawnKill(h: uint64) {.importc: "aowl_spawn_kill", nodecl.}
proc cSleepMs(ms: int32) {.importc: "aowl_sys_sleep", nodecl.}

# ---------------------------------------------------------------------------
# Which port the client will actually talk to
# ---------------------------------------------------------------------------
#
# The launcher does not get to choose this. `aowlspt/backend.json` is what the
# **client** reads -- the installer writes it, naming the backend it installed,
# and the game asks that url for everything. So the port this launcher starts a
# backend on is not a preference of the launcher's: it is a fact about the
# install, and reading it from anywhere else is how the two came to disagree.
#
# What that cost, on a real playtest: an install whose `backend.json` said 6970,
# and a launcher whose default was a *hardcoded* 6969. It started its backend on
# 6969, told the player so, and the client went to 6970. On that machine 6969 is
# a stock SPT server, so the launcher's backend sat there unused while the whole
# session talked to somebody else's server. Nothing said so.
#
# `--port N` is therefore checked rather than obeyed. A port that disagrees with
# `backend.json` is refused outright, because there is no reading of it that
# ends well: it starts a server the client will not use, and leaves the client
# talking to whatever else happens to hold the port it does use. Saying so and
# stopping is the only honest answer. `--allow-port-mismatch` is the way to mean
# it anyway -- a separate flag rather than `--force`, which is about the client
# being the wrong runtime and would be given for entirely unrelated reasons.
#
# The scheme also decides the transport. A post-1.0 client talks HTTPS on a
# hardcoded 443, so `https://` in `backend.json` means the backend is started
# with `--tls` and the client is handed an https url; `http://` is plain, for
# development and the tests. Both the port and the scheme come from that one
# url, parsed once in `aowlsession.parseBackendUrl` -- the same reader the rest
# of this uses, so the launcher and the file cannot come to disagree about
# either. That parser also fixes the "last run of digits" rule that read the
# `1` out of `https://127.0.0.1/` and called it a port.

proc backendJsonPath(root: string): string =
  joinPath(root, "aowlspt\\backend.json")

const Usage = """
aowlspt-launch -- start Tarkov with the aowlspt host inside it

  aowlspt-launch [--root PATH] [options]

Options
  --root PATH    the aowlspt install (default: the directory this exe is in)
  --exe NAME     executable to start (default: EscapeFromTarkov.exe)
  --args "..."   extra command line for the game, appended to the one this
                 builds from backend.json and the chosen profile
  --profile ID   bind this profile id server-side before launch (the game's
                 own character-select still shows, this just pre-selects)
  --new NAME     create a profile called NAME and bind it before launch
  --side SIDE    Usec or Bear, for --new (default Usec)
  --pick         show the launcher's own profile picker before starting the
                 game. OFF by default: the launcher picks a profile without
                 asking -- the one you played last, else the most recent --
                 binds it, and (see --no-auto-enter) presses the matching
                 in-game character-select slot for you, so the TUI is the
                 only place you are ever asked.
  --no-auto-enter
                 do not auto-press the in-game character-select screen after
                 a profile was bound. The client still shows it, exactly as
                 before this feature; use this if the auto-press ever picks
                 the wrong slot, or to debug the selector itself.
  --no-profile   start the client with no -token, so it logs in on its own.
                 The backend binds no session for a tokenless client, so this
                 is the first-run/character-creation path only -- it cannot
                 reach an existing character.
  --wait         stay open until the game exits
  --no-backend   do not start the backend server
  --no-logs      do not show the live log view; exit once the game is up
  --logs         start nothing: open the log view on this install's two logs.
                 For watching a session somebody else started -- `q` closes
                 this window and stops nothing.
  --client-window
                 open a second console window for the client log as well
  --port N       backend port. Normally read from backend.json's backendUrl --
                 the one the client talks to. An explicit :PORT in that url
                 wins; otherwise the default is by scheme: 443 for https, 6969
                 for http. A --port that disagrees is refused rather than
                 obeyed, and in TLS mode a --port other than 443 is warned
                 about, because the client hardcodes 443.
  --allow-port-mismatch
                 start the backend on a --port backend.json disagrees with
                 anyway. The client will still use backend.json's port.
  --backend-wait N
                 seconds to wait for the backend to answer before starting the
                 client (default 300, 0 to not wait at all)
  --plain        no cursor movement, no colour, no repainting: one line per
                 thing that happened. Redirected output is always this.
  --ascii        box drawing in ASCII, for a console font with no line glyphs
  --dry-run      report what would happen and start nothing
  --force        launch even if the client looks wrong for this host
  -h, --help     this

Transport is read from backend.json's backendUrl: https:// starts the backend
with --tls (HTTPS, what a real post-1.0 client needs) and hands the client an
https url; http:// is plain, for development and the tests.

Inside the log view
  q  stop the backend and quit      d  detach, leaving everything running
  tab  swap the focused pane        f  give the focused pane the whole window
  space  pause following            pgup/pgdn, up/down, home/end  scroll
"""

type
  Options = object
    root: string
    exeName: string
    extraArgs: string
    wait: bool
    force: bool
    noBackend: bool
    noLogs: bool
    logsOnly: bool
    clientWindow: bool
    plain: bool
    ascii: bool
    profileId: string
    newProfile: string
    side: string
    noProfile: bool
    pick: bool
      ## `--pick`: restore the launcher's own TUI profile picker. Off by
      ## default -- the TUI is now the ONLY place a profile is chosen (see
      ## `--no-auto-enter`); the in-game character-select is auto-pressed
      ## rather than shown to a human.
    noAutoEnter: bool
      ## `--no-auto-enter`: the escape hatch. Restores the old behaviour --
      ## the client boots with a bound token but still stops at its own
      ## character-select screen for a human to click through, exactly as
      ## before this feature existed.
    port: int
      ## Only meaningful when `portGiven`. The port actually used is resolved
      ## in `main`, once `root` is known and `backend.json` can be read.
    portGiven: bool
    allowPortMismatch: bool
    backendWait: int
    tailPath: string
      ## `--tail`: this process is a second console window showing one log.
      ## Not in the usage text because nobody types it; see `--client-window`.
    tailTitle: string
    help: bool

proc parseArgs(): Options =
  result = Options(root: "", exeName: "EscapeFromTarkov.exe", extraArgs: "",
                   wait: false, force: false, noBackend: false, noLogs: false,
                   logsOnly: false,
                   clientWindow: false, plain: false, ascii: false,
                   profileId: "", newProfile: "", side: "Usec",
                   noProfile: false, pick: false, port: 0,
                   portGiven: false, allowPortMismatch: false,
                   backendWait: 300, tailPath: "", tailTitle: "log",
                   help: false)
  var i = 1
  let n = paramCount()
  while i <= n:
    let a = paramStr(i)
    if a == "--root":
      inc i
      if i <= n: result.root = paramStr(i)
    elif a == "--exe":
      inc i
      if i <= n: result.exeName = paramStr(i)
    elif a == "--args":
      inc i
      if i <= n: result.extraArgs = paramStr(i)
    elif a == "--profile":
      inc i
      if i <= n: result.profileId = paramStr(i)
    elif a == "--new":
      inc i
      if i <= n: result.newProfile = paramStr(i)
    elif a == "--side":
      inc i
      if i <= n: result.side = paramStr(i)
    elif a == "--tail":
      inc i
      if i <= n: result.tailPath = paramStr(i)
    elif a == "--tail-title":
      inc i
      if i <= n: result.tailTitle = paramStr(i)
    elif a == "--no-profile":
      result.noProfile = true
    elif a == "--pick":
      result.pick = true
    elif a == "--no-auto-enter":
      result.noAutoEnter = true
    elif a == "--wait":
      result.wait = true
    elif a == "--no-backend":
      result.noBackend = true
    elif a == "--no-logs":
      result.noLogs = true
    elif a == "--logs":
      result.logsOnly = true
    elif a == "--client-window":
      result.clientWindow = true
    elif a == "--plain":
      result.plain = true
    elif a == "--ascii":
      result.ascii = true
    elif a == "--port":
      inc i
      if i <= n:
        var v = 0
        var any = false
        for ch in paramStr(i):
          if ch >= '0' and ch <= '9':
            v = v * 10 + (ord(ch) - ord('0'))
            any = true
        if any:
          result.port = v
          result.portGiven = true
    elif a == "--allow-port-mismatch":
      result.allowPortMismatch = true
    elif a == "--backend-wait":
      inc i
      if i <= n:
        var v = 0
        var any = false
        for ch in paramStr(i):
          if ch >= '0' and ch <= '9':
            v = v * 10 + (ord(ch) - ord('0'))
            any = true
        if any: result.backendWait = v
    elif a == "--dry-run" or a == "-n":
      setDryRun true
    elif a == "--force":
      result.force = true
    elif a == "--help" or a == "-h":
      result.help = true
    elif a.startsWith("-"):
      fatal "unknown option: " & a
    elif result.root.len == 0:
      result.root = a
    inc i

# ---------------------------------------------------------------------------
# Small formatting
# ---------------------------------------------------------------------------

proc secsText(ms: int64): string =
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

proc sizeText(bytes: int64): string =
  if bytes <= 0'i64: return "0 B"
  if bytes < 1024'i64: return $int(bytes) & " B"
  if bytes < 1048576'i64: return $int(bytes div 1024'i64) & " KB"
  let mb10 = int(bytes div 104858'i64)
  result = $(mb10 div 10) & "." & $(mb10 mod 10) & " MB"

const
  MarkDone = 0
  MarkActive = 1
  MarkPending = 2
  MarkFailed = 3

proc markGlyph(kind: int): string =
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

proc markColour(kind: int): int =
  case kind
  of MarkDone: ColGreen
  of MarkActive: ColCyan
  of MarkFailed: ColRed
  else: ColDim

proc stepRow(kind: int; name, detail: string; width: int): Row =
  result = newRow()
  result.put "  "
  result.putIn markColour(kind), markGlyph(kind)
  result.put " "
  result.putIn (if kind == MarkPending: ColDim else: ColDefault), name
  result.padTo 20
  let room = width - result.width - 2
  if room > 4 and detail.len > 0:
    result.putIn (if kind == MarkFailed: ColRed else: ColDim), fit(detail, room)

proc logRow(l: LogLine; width: int): Row =
  result = newRow()
  result.put "  "
  if l.stamp.len > 0:
    result.putIn ColDim, fit(l.stamp, 9)
    result.padTo 12
  let name = levelName(l.level)
  if name.len > 0:
    result.putIn levelOf(l.level), name
  result.padTo (if l.stamp.len > 0: 18 else: 8)
  let room = width - result.width - 1
  if room > 4:
    result.putIn (if l.level == lvError: ColRed else: ColDefault),
                 fit(l.text, room)

# ---------------------------------------------------------------------------
# What the backend's own log says about how far it has got
# ---------------------------------------------------------------------------
#
# Every field here is read out of a sentence the backend wrote about itself.
# Nothing is inferred from elapsed time, and the two numbers that make a
# progress bar -- how many mods are being loaded and how many have loaded --
# both come from the log rather than from counting DLLs on disk. Counting the
# files would have been easy and would have been wrong: an install with eleven
# mod libraries and three selected loads three, and a bar that filled to 3/11
# and stopped would read as a hang.

type
  BootState = object
    portFree: bool
    dbBytes: int64
    dbLoaded: bool
    modsTotal: int
    modsTotalKnown: bool
    modsLoaded: int
    lastLoaded: string
    listening: bool
    errors: int
    lastError: string

proc numberBefore(text, phrase: string): int =
  ## The number immediately in front of `phrase`, as in `3 mod(s) selected`.
  result = 0
  let at = find(text, phrase)
  if at <= 0: return
  var i = at - 1
  while i >= 0 and text[i] == ' ': dec i
  var digits = ""
  while i >= 0 and text[i] >= '0' and text[i] <= '9':
    digits = $text[i] & digits
    dec i
  for ch in digits:
    result = result * 10 + (ord(ch) - ord('0'))

proc scanBoot(t: Tail): BootState =
  result = BootState(portFree: false, dbBytes: 0'i64, dbLoaded: false,
                     modsTotal: 0, modsTotalKnown: false, modsLoaded: 0,
                     lastLoaded: "", listening: false, errors: 0,
                     lastError: "")
  for l in t.lines:
    let s = l.text
    if l.level == lvError:
      inc result.errors
      result.lastError = s
    if startsWith(s, "port ") and find(s, "is free") > 0:
      result.portFree = true
    elif startsWith(s, "database loaded from"):
      result.dbLoaded = true
      let open = find(s, "(")
      if open > 0:
        var v = 0'i64
        var i = open + 1
        while i < s.len and s[i] >= '0' and s[i] <= '9':
          v = v * 10'i64 + int64(ord(s[i]) - ord('0'))
          inc i
        result.dbBytes = v
    elif find(s, "mod(s) selected") > 0:
      result.modsTotal = numberBefore(s, "mod(s) selected")
      result.modsTotalKnown = true
    elif startsWith(s, "loaded ") and l.level == lvOk:
      inc result.modsLoaded
      result.lastLoaded = s.substr(len("loaded "))
    elif startsWith(s, "listening on"):
      result.listening = true

# ---------------------------------------------------------------------------
# What the injected host's log says
# ---------------------------------------------------------------------------

type
  HostState = object
    wroteAnything: bool
    guardAnswered: bool
    runtimeUp: bool
    running: bool
    modsLoaded: int
    errors: int
    lastError: string

proc scanHost(t: Tail): HostState =
  result = HostState(wroteAnything: t.lines.len > 0, guardAnswered: false,
                     runtimeUp: false, running: false, modsLoaded: 0,
                     errors: 0, lastError: "")
  for l in t.lines:
    let s = l.text
    if l.level == lvError:
      inc result.errors
      result.lastError = s
    if find(s, "BattlEye") > 0 and find(s, "guard") > 0:
      result.guardAnswered = true
    elif find(s, "IL2CPP is up after") >= 0 or
         find(s, "IL2CPP runtime bound") >= 0:
      result.runtimeUp = true
    elif startsWith(s, "host running"):
      result.running = true
    elif startsWith(s, "loaded ") and l.level == lvOk:
      inc result.modsLoaded

# ---------------------------------------------------------------------------
# The boot view
# ---------------------------------------------------------------------------

proc bootRows(b: BootState; answered: bool; elapsed: int64; port: int;
              tls: bool; t: Tail; width, logRows: int): seq[Row] =
  result = @[]
  var head = newRow()
  head.put "  "
  head.putIn ColWhite, "starting the server"
  head.padTo width - 10
  head.putIn ColDim, secsText(elapsed)
  result.add head
  result.add newRow()

  result.add stepRow((if b.portFree: MarkDone else: MarkActive),
                     "port " & $port,
                     (if b.portFree: "claimed" else: "asking for it"), width)

  let dbMark =
    if b.dbLoaded: MarkDone
    elif b.portFree: MarkActive
    else: MarkPending
  result.add stepRow(dbMark, "database",
                     (if b.dbLoaded: sizeText(b.dbBytes) & " read" else: ""),
                     width)

  var modMark = MarkPending
  if b.dbLoaded: modMark = MarkActive
  if b.modsTotalKnown and b.modsLoaded >= b.modsTotal and b.modsTotal > 0:
    modMark = MarkDone
  var modDetail = ""
  if b.modsTotalKnown:
    let barWidth = 14
    var filled = 0
    if b.modsTotal > 0:
      filled = (b.modsLoaded * barWidth) div b.modsTotal
    modDetail = bar(filled, barWidth) & "  " & $b.modsLoaded & " of " &
                $b.modsTotal
    if b.lastLoaded.len > 0 and modMark == MarkActive:
      modDetail.add "   " & b.lastLoaded
  elif b.dbLoaded:
    # The count is not knowable yet, and a bar drawn against a guess is the one
    # thing this view will not do.
    modDetail = "reading the load order"
  result.add stepRow(modMark, "mods", modDetail, width)

  result.add stepRow((if b.listening: MarkDone
                      elif modMark == MarkDone: MarkActive
                      else: MarkPending),
                     "listening",
                     (if b.listening: "127.0.0.1:" & $port &
                        (if tls: " (TLS)" else: "") else: ""), width)
  # In TLS mode the launcher cannot probe HTTPS, so readiness *is* the backend's
  # own "listening" line rather than a request coming back -- and the label says
  # which, so a green tick never claims more than was actually observed.
  result.add stepRow((if answered: MarkDone
                      elif b.listening: MarkActive
                      else: MarkPending),
                     (if tls: "ready" else: "answering"),
                     (if answered:
                        (if tls: "the backend logged it is listening on TLS"
                         else: "/aowlspt/tarkov/selfcheck came back")
                      else: ""), width)
  if b.errors > 0:
    result.add stepRow(MarkFailed, $b.errors & " error(s)", b.lastError, width)

  if logRows > 0:
    result.add newRow()
    var sep = newRow()
    sep.put "  "
    sep.putIn ColDim, rule(width - 4)
    result.add sep
    var first = t.lines.len - logRows
    if first < 0: first = 0
    for i in first ..< t.lines.len:
      result.add logRow(t.lines[i], width)
    var pad = logRows - (t.lines.len - first)
    while pad > 0:
      result.add newRow()
      dec pad

proc waitForBackend(root: string; port: int; tls: bool; backendProc: uint64;
                    limitSecs: int; logPath: string;
                    died, answered, probeBroken: var bool) =
  ## Poll until the backend is ready, showing its own progress while it does.
  ##
  ## "Ready" is observed two different ways, because the launcher speaks plain
  ## HTTP and cannot open a TLS request. In plain mode readiness is a request
  ## coming back -- an answer beats a corpse, a dead process is not waited for.
  ## In TLS mode it is the backend's own `listening on ...` line in the log,
  ## which it writes only after `aowl_net_serve_tls` binds -- the same event,
  ## reported by the process that owns it rather than probed from outside.
  died = false
  answered = false
  probeBroken = false
  var tail = newTail(logPath)
  let began = cNowMs()
  var panel = newPanel()
  var w = 0
  var h = 0
  termSize(w, h)
  if w <= 0: w = 100
  if w > 120: w = 120
  var logRows = 6
  if not fitsInWindow(9 + logRows + 2):
    logRows = 0
  let painting = fitsInWindow(11) and termMode() == tmFull
  var lastNote = 0'i64
  var lastPaint = -1000'i64

  while true:
    let waited = cNowMs() - began
    if limitSecs > 0 and waited >= int64(limitSecs) * 1000'i64:
      break
    discard tail.pump()
    if tls:
      # Cannot probe HTTPS, so the log is the signal. The `listening` line is
      # written after the TLS bind, so it means exactly what an answered request
      # would in plain mode -- with the process-alive check still underneath, so
      # a backend that died before it logged anything is not waited for.
      let b = scanBoot(tail)
      if b.listening:
        answered = true
      elif backendProc != 0'u64 and cSpawnAlive(backendProc) == 0'i32:
        died = true
    else:
      # Asked before the liveness check on purpose. If the backend this launcher
      # started lost a race for the port to one somebody else had already
      # started, the process is gone and the port answers -- and the client
      # cares about the port. An answer wins over a corpse.
      let r = answers(port)
      if r == 1:
        answered = true
      elif r < 0:
        probeBroken = true
      elif backendProc != 0'u64 and cSpawnAlive(backendProc) == 0'i32:
        died = true

    if painting:
      if waited - lastPaint >= 100'i64 or answered or died or probeBroken:
        lastPaint = waited
        let b = scanBoot(tail)
        panel.paint bootRows(b, answered, waited, port, tls, tail, w, logRows)
    else:
      # No repainting here: this is the redirected case, and the only useful
      # thing to write into a file is a line whenever something changed.
      if waited - lastNote >= 5000'i64:
        lastNote = waited
        let b = scanBoot(tail)
        var what = "starting"
        if b.listening:
          what = (if tls: "listening on TLS -- ready" else:
                  "listening, waiting for it to answer")
        elif b.modsTotalKnown:
          what = "loading mods, " & $b.modsLoaded & " of " & $b.modsTotal
        elif b.dbLoaded: what = "database read, reading the load order"
        line "  " & secsText(waited) & " -- " & what
        flushOut()

    if answered or died or probeBroken:
      break
    if interrupted():
      break
    sleepMs 120

  if painting:
    # One last paint so the finished state is what is left in the scrollback,
    # then let ordinary output carry on underneath it.
    discard tail.pump()
    let b = scanBoot(tail)
    panel.paint bootRows(b, answered, cNowMs() - began, port, tls, tail, w, logRows)
    panel.settle()

# ---------------------------------------------------------------------------
# Choosing a profile
# ---------------------------------------------------------------------------

proc profileLabel(p: Profile): string =
  result = (if p.nickname.len > 0: p.nickname else: "(no nickname)")
  var bits = ""
  if p.side.len > 0: bits = p.side
  if p.level > 0:
    if bits.len > 0: bits.add " "
    bits.add "level " & $p.level
  if bits.len > 0: result.add "  " & bits

proc drawProfiles(list: ProfileList) =
  ## Printed rather than painted: this stays in the scrollback, and the answer
  ## the player types has to stay next to the list they typed it from.
  let n = list.items.len
  echo ""
  sayColoured ColWhite, "  Profiles"
  sayColoured ColDim, "  " & rule(52)
  if n == 0:
    sayColoured ColDim, "  there are none yet"
  for i in 0 ..< n:
    var r = newRow()
    r.put "   "
    r.putIn ColCyan, $(i + 1)
    r.put "  "
    r.putIn ColDefault, profileLabel(list.items[i])
    r.padTo 44
    r.putIn ColDim, list.items[i].id
    echo r.text
  sayColoured ColDim, "  " & rule(52)

proc readAnswer(prompt: string; into: var string): bool =
  ## False at end of input. `stdin` may be a file -- a launcher driven from a
  ## script is a reasonable thing to be -- and the difference between "typed
  ## nothing" and "there is nobody there" decides whether a default is taken or
  ## the launcher stops.
  var r = newRow()
  r.put "  "
  r.putIn ColCyan, prompt
  r.put " "
  echo ""
  write(stdout, r.text)
  flushFile(stdout)
  into = ""
  result = readLine(stdin, into)
  into = strip(into)

proc listProfilesWaiting(port: int; root: string): ProfileList =
  ## `listProfiles`, but it does not accept a dropped connection as the answer.
  ##
  ## MEASURED: the launcher starts the backend and asks for this list almost
  ## immediately. The backend accepts the TCP connection before its TLS
  ## listener can serve it, so the first attempt reports "connected to
  ## 127.0.0.1:443 and then lost the connection" and the list silently
  ## degrades to the on-disk store for the WHOLE session. That is not a
  ## cosmetic warning: the store path cannot create a character, so the picker
  ## offers `0 = new character` and then refuses it, for a backend that was
  ## healthy and merely a few hundred milliseconds late. (Confirmed after one
  ## such failure that both :80 and :443 answered 200.)
  ##
  ## Only a TRANSPORT failure is retried. A 404, or any non-200, is a real
  ## answer from a live server -- retrying a definite negative only makes a
  ## fast failure slow.
  const Retries = 6
  const RetryMs = 400'i32
  result = listProfiles(port, root)
  var tries = 1
  while result.source != psRoute and result.error.len == 0 and tries < Retries:
    cSleepMs(RetryMs)
    result = listProfiles(port, root)
    inc tries
  if result.source == psRoute and tries > 1:
    let waited = (tries - 1) * int(RetryMs)
    if result.note.len > 0: result.note.add "; "
    result.note.add "the profile-list route needed " & $tries &
                    " attempts (" & $waited & "ms) before the backend " &
                    "answered -- it accepts the connection before it can serve"

proc pickProfile(o: Options; port: int; root: string;
                 chosen: var Profile; reason: var string;
                 viaRoute: var bool): bool =
  ## True when there is a profile to start the game with. `reason` says why not
  ## when there is not -- and it is always a sentence about *this* install
  ## rather than "no profile found". `viaRoute` says whether the profiles came
  ## from the backend (so the caller can `select` on it) or off disk (so it
  ## cannot).
  reason = ""
  viaRoute = false
  chosen = Profile(id: "", token: "", nickname: "", side: "", level: 0,
                   edition: "", lastPlayed: 0)

  var list = listProfilesWaiting(port, root)
  viaRoute = list.source == psRoute
  if list.error.len > 0:
    reason = list.error
    return false
  if list.note.len > 0:
    warn list.note

  # `--profile` is matched against the list rather than trusted, so that a
  # mistyped id fails here with the list in front of the player instead of at
  # the game's login screen with nothing to go on.
  if o.profileId.len > 0:
    for p in list.items:
      if p.id == o.profileId:
        chosen = p
        ok "profile " & profileLabel(p) & " (" & p.id & ")"
        return true
    reason = "no profile with id " & o.profileId & " in this install"
    return false

  if o.newProfile.len > 0:
    if list.source == psStore:
      reason = "a profile cannot be created without the backend's launcher " &
               "routes; this list came off disk because it has none"
      return false
    var made = Profile(id: "", token: "", nickname: "", side: "", level: 0,
                       edition: "", lastPlayed: 0)
    let err = createProfile(port, o.newProfile, o.side, made)
    if err.len > 0:
      reason = err
      return false
    chosen = made
    ok "created " & profileLabel(made) & " (" & made.id & ")"
    return true

  drawProfiles(list)
  if list.source == psStore:
    sayColoured ColDim,
      "  this list came off disk, so creating a character is not available " &
      "here -- the backend's launcher routes are what create one, and this " &
      "list was read from the store because it could not reach them"

  # Not a console: no picker. One profile is unambiguous and is taken with a
  # line saying so; more than one is not, and guessing which character somebody
  # meant to play is not a guess worth making.
  if not stdinIsConsole():
    if list.items.len == 1:
      chosen = list.items[0]
      ok "one profile in this install, so it was taken without asking: " &
         profileLabel(chosen)
      return true
    reason = "input is not a terminal, so there is nobody to ask which of " &
             $list.items.len & " profiles to play. Pass --profile <id>."
    return false

  while true:
    var prompt = "play which?"
    if list.items.len > 0:
      prompt = "play which? [1-" & $list.items.len & "]"
    if list.source == psRoute:
      # `0` is an alias for `n`. The list is numbered from 1, so a player who
      # has just read it reaches for a number, not a letter -- asked for by
      # name the first time somebody used this picker.
      prompt.add "  (0 or n = new character, q = quit)"
    else:
      prompt.add "  (q = quit)"
    var answer = ""
    if not readAnswer(prompt, answer):
      reason = "input ended before a profile was chosen"
      return false
    if answer == "q" or answer == "Q":
      reason = "you chose to quit"
      return false
    if (answer == "n" or answer == "N" or answer == "0") and
       list.source != psRoute:
      # Falling through to "that is not one of the choices" is a LIE here: it
      # IS one of the choices, it just cannot be served right now. The player
      # asked to create a character and deserves the actual reason.
      err "creating a character needs the backend's launcher routes, and " &
          "this list was read from " & joinPath(root, "aowlspt") & "\\store" &
          " because those routes could not be reached. Start the backend " &
          "(or re-run without --no-backend) and try again."
      continue
    if (answer == "n" or answer == "N" or answer == "0") and
       list.source == psRoute:
      var nick = ""
      if not readAnswer("nickname:", nick): return false
      if nick.len < 3:
        err "a nickname needs at least three characters"
        continue
      var sideAnswer = ""
      if not readAnswer("side? [Usec/Bear]", sideAnswer): return false
      var side = "Usec"
      if toLowerAscii(sideAnswer) == "bear" or toLowerAscii(sideAnswer) == "b":
        side = "Bear"
      var made = Profile(id: "", token: "", nickname: "", side: "", level: 0,
                         edition: "", lastPlayed: 0)
      let e = createProfile(port, nick, side, made)
      if e.len > 0:
        err e
        continue
      chosen = made
      ok "created " & profileLabel(made) & " (" & made.id & ")"
      return true
    if answer.len == 0 and list.items.len == 1:
      chosen = list.items[0]
      return true
    var idx = 0
    var any = false
    for ch in answer:
      if ch >= '0' and ch <= '9':
        idx = idx * 10 + (ord(ch) - ord('0'))
        any = true
      else:
        any = false
        break
    if any and idx >= 1 and idx <= list.items.len:
      chosen = list.items[idx - 1]
      ok "playing " & profileLabel(chosen) & " (" & chosen.id & ")"
      return true
    # A 24-character id typed straight in, for a list too long to count down.
    for p in list.items:
      if p.id == answer:
        chosen = p
        return true
    err "that is not one of the choices"

# ---------------------------------------------------------------------------
# The client view
# ---------------------------------------------------------------------------

proc clientRows(h: HostState; alive: bool; elapsed: int64; pid: int;
                t: Tail; width, logRows: int): seq[Row] =
  result = @[]
  var head = newRow()
  head.put "  "
  head.putIn ColWhite, "starting the client"
  head.padTo width - 10
  head.putIn ColDim, secsText(elapsed)
  result.add head
  result.add newRow()
  result.add stepRow(MarkDone, "process", "pid " & $pid & ", host injected",
                     width)
  result.add stepRow((if not alive: MarkFailed
                      elif h.wroteAnything: MarkDone else: MarkActive),
                     "host log",
                     (if not alive: "the client exited"
                      elif h.wroteAnything: $t.lines.len & " lines"
                      else: "waiting for the first line"), width)
  result.add stepRow((if h.runtimeUp: MarkDone
                      elif h.wroteAnything: MarkActive else: MarkPending),
                     "IL2CPP runtime",
                     (if h.runtimeUp: "up" else:
                        "the game brings this up on its own; a cold launch " &
                        "takes a while"), width)
  result.add stepRow((if h.running: MarkDone
                      elif h.runtimeUp: MarkActive else: MarkPending),
                     "host",
                     (if h.running: $h.modsLoaded & " client mod(s) loaded"
                      else: ""), width)
  if h.errors > 0:
    result.add stepRow(MarkFailed, $h.errors & " error(s)", h.lastError, width)
  if logRows > 0:
    result.add newRow()
    var sep = newRow()
    sep.put "  "
    sep.putIn ColDim, rule(width - 4)
    result.add sep
    var first = t.lines.len - logRows
    if first < 0: first = 0
    for i in first ..< t.lines.len:
      result.add logRow(t.lines[i], width)
    var pad = logRows - (t.lines.len - first)
    while pad > 0:
      result.add newRow()
      dec pad

proc watchClient(launch: LaunchPtr; hostLog: string; limitMs: int64;
                 exited: var bool) =
  ## Until the host says it is running, or the client dies, or the time is up.
  ## Whichever happens, the last thing painted is what actually happened.
  exited = false
  var tail = newTail(hostLog)
  let began = cNowMs()
  var panel = newPanel()
  var w = 0
  var h = 0
  termSize(w, h)
  if w <= 0: w = 100
  if w > 120: w = 120
  var logRows = 6
  if not fitsInWindow(8 + logRows + 2): logRows = 0
  let painting = fitsInWindow(10) and termMode() == tmFull
  var lastNote = 0'i64
  let pid = int(cLaunchPid(launch))

  while true:
    let waited = cNowMs() - began
    discard tail.pump()
    let st = scanHost(tail)
    let alive = cLaunchAlive(launch) != 0'i32
    if not alive: exited = true
    if painting:
      panel.paint clientRows(st, alive, waited, pid, tail, w, logRows)
    elif waited - lastNote >= 5000'i64:
      lastNote = waited
      var what = "waiting for the host's first log line"
      if st.running: what = "host running"
      elif st.runtimeUp: what = "IL2CPP up, host binding"
      elif st.wroteAnything: what = "host started, waiting for the runtime"
      line "  " & secsText(waited) & " -- " & what
      flushOut()
    if st.running or exited or waited >= limitMs:
      if painting:
        panel.paint clientRows(st, alive, waited, pid, tail, w, logRows)
        panel.settle()
      return
    if interrupted():
      if painting: panel.settle()
      return
    sleepMs 120

# ---------------------------------------------------------------------------
# The backend watchdog
# ---------------------------------------------------------------------------
#
# A backend death used to be a silent hang: the process the launcher started on
# 127.0.0.1:443 would vanish -- a native fault in the C net engine, a fast-fail
# on a corrupt heap -- and the game, which reaches that server for everything,
# would simply stop making progress with nothing on screen to say why. "It
# crashed again", with no crash anyone could see.
#
# The watchdog makes that self-healing. Once the backend is started, the run
# loops below poll it (every `WdCheckMs`) for as long as the game is alive; if it
# has died, they respawn it with *exactly* the command line it was started with
# and carry on, so the game only ever sees the server blink and reconnect. The
# backend truncates its own log on each boot and the tail follows the reset, so
# the log view stays coherent across a restart.
#
# It is bounded, on purpose. A backend that dies the instant it comes up would,
# without a bound, be fork-bombed forever. So a restart streak that does not stay
# up for `WdStableMs` is counted, and after `WdMaxRapid` rapid deaths the
# watchdog gives up and flips `givenUp` -- which the views turn into a loud,
# unmistakable "BACKEND DOWN" the player actually sees, rather than one more
# silent stall. A backend that had been healthy for a while resets the streak, so
# one crash after an hour of play is not held against it.

type
  Watchdog = object
    exe, workDir, cmdLine, logPath: string
    port: int
    active: bool        ## true once we own a backend to keep alive
    handle: uint64      ## current process handle, 0 when none/dead
    restarts: int       ## how many times it has been respawned
    fails: int          ## consecutive rapid deaths (reset once it stays up)
    lastStartMs: int64
    lastCheckMs: int64
    givenUp: bool       ## bound hit: stop restarting, surface a hard error

const
  WdCheckMs = 2000'i64    ## how often the run loops poll for a death
  WdStableMs = 20000'i64  ## up this long => the rapid-death streak is forgiven
  WdMaxRapid = 5          ## give up after this many rapid deaths in a row

var gWd = Watchdog(exe: "", workDir: "", cmdLine: "", logPath: "", port: 0,
                   active: false, handle: 0'u64, restarts: 0, fails: 0,
                   lastStartMs: 0'i64, lastCheckMs: 0'i64, givenUp: false)

proc wdArm(exe, workDir, cmdLine, logPath: string; port: int; handle: uint64) =
  ## Remember what the backend was started as, so the watchdog can restart it
  ## byte-for-byte. Called once, right after the initial spawn.
  gWd.exe = exe
  gWd.workDir = workDir
  gWd.cmdLine = cmdLine
  gWd.logPath = logPath
  gWd.port = port
  gWd.handle = handle
  gWd.active = true
  gWd.lastStartMs = cNowMs()
  gWd.lastCheckMs = cNowMs()

proc wdAlive(): bool =
  gWd.handle != 0'u64 and cSpawnAlive(gWd.handle) != 0'i32

proc wdPoll(clientAlive: bool): bool =
  ## Keep the owned backend alive while the game runs; return its current
  ## aliveness. Rate-limited to `WdCheckMs` -- between polls it just reports the
  ## live handle, so the header stays honest without hammering the check.
  if not gWd.active or gWd.givenUp:
    return wdAlive()
  let now = cNowMs()
  if now - gWd.lastCheckMs < WdCheckMs:
    return wdAlive()
  gWd.lastCheckMs = now
  if gWd.handle != 0'u64 and cSpawnAlive(gWd.handle) != 0'i32:
    return true
  # The backend is gone.
  if not clientAlive:
    # No game left to serve, so do not resurrect a server nobody is talking to:
    # let it stay down and let the caller's "both gone" exit fire.
    return false
  let lived = now - gWd.lastStartMs
  if lived >= WdStableMs:
    gWd.fails = 0   # it had been healthy; treat this as a fresh incident
  inc gWd.fails
  if gWd.fails > WdMaxRapid:
    gWd.givenUp = true
    err "BACKEND DOWN -- aowlspt-backend died " & $gWd.fails & " times in " &
        "quick succession and will not be restarted again. The game cannot " &
        "reach its server on 127.0.0.1:" & $gWd.port & "."
    note "see " & gWd.logPath & " (and any aowlspt-backend.log.fatal beside " &
         "it) for why. Quit with q, fix it, then relaunch."
    return false
  # Restart with exactly the command line it was started with.
  var e = gWd.exe
  var w = gWd.workDir
  var c = gWd.cmdLine
  let h = cSpawnQuiet(toCString(e), toCString(w), toCString(c))
  gWd.handle = h
  gWd.lastStartMs = now
  inc gWd.restarts
  if h == 0'u64:
    err "backend died -- restart #" & $gWd.restarts &
        " could not be spawned (CreateProcess failed)"
    return false
  warn "backend died -- restarting (restart #" & $gWd.restarts &
       ", on 127.0.0.1:" & $gWd.port & ")"
  return true

proc wdBackendAlive(backendProc: uint64; owned, clientAlive: bool): bool =
  ## The single place the run loops ask "is the server up?". When this launcher
  ## owns the backend the answer runs through the watchdog (which may restart it
  ## as a side effect); otherwise it is a plain liveness check on the handle it
  ## was given -- `--logs` attaches to somebody else's server and never restarts.
  if owned and gWd.active:
    wdPoll(clientAlive)
  else:
    backendProc != 0'u64 and cSpawnAlive(backendProc) != 0'i32

proc wdCurrentHandle(backendProc: uint64): uint64 =
  ## The handle to kill/probe now -- the watchdog's, if it has been restarting,
  ## else the original.
  if gWd.active: gWd.handle else: backendProc

# ---------------------------------------------------------------------------
# The live log view
# ---------------------------------------------------------------------------
#
# ## One window, split, rather than two windows
#
# The obvious alternative -- give the client its own console -- was tried on
# paper and loses on four counts, and `--client-window` exists so that anyone
# who disagrees can have it without arguing.
#
#  1. **The client has no console to give.** It is a Unity GUI process started
#     suspended and injected; it writes a *file*, and nothing it does goes to a
#     handle anybody could inherit. A second window would therefore be a second
#     copy of this launcher tailing that file (which is exactly what
#     `--client-window` starts). It is a whole extra process to make one pane
#     into one window.
#  2. **The question is nearly always a comparison.** "The client asked for
#     `/client/game/config` and the server said what?" Answering that in two
#     windows means alt-tabbing between two scroll positions and matching
#     timestamps by eye. Side by side, with both clocks in view, it is one
#     glance -- and both logs stamp every line with milliseconds since *their
#     own* start, so the comparison is one the reader has to make and the layout
#     should help with.
#  3. **A second window can be closed on its own**, and a player who closes it
#     has silently lost half of their instrumentation with nothing to say so.
#     Worse, closing a console window kills the process in it; if that process
#     were the one holding the backend, closing the "client log" window would
#     stop the server.
#  4. **The game is fullscreen.** Both windows are behind it either way, so the
#     supposed benefit of a separate window -- putting it on a second monitor --
#     applies equally to the single one, which can be moved to a second monitor
#     as a whole.
#
# What the split does give up is width, and that is a real cost on an 80-column
# console. `f` answers it: one keystroke gives the focused pane the whole
# window, and another gives it back. That is the benefit of a dedicated window
# without any of the four costs above.

proc borderCell(title: string; n: int; focused: bool): Row =
  ## Exactly `n` columns of horizontal rule with a title sunk into it. Exactly,
  ## because it is one segment of a border that has to meet the next one.
  result = newRow()
  let h = bxH()
  result.putIn ColDim, h
  if n > 3:
    result.putIn (if focused: ColWhite else: ColDim), fit(" " & title & " ", n - 2)
  while result.width < n:
    result.putIn ColDim, h

proc drawPane(t: Tail; scroll, rows, width: int; into: var seq[Row]) =
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
  for i in first ..< last:
    var r = newRow()
    let l = t.lines[i]
    if l.stamp.len > 0:
      r.putIn ColDim, fit(l.stamp, 8)
      r.padTo 9
    let nm = levelName(l.level)
    if nm.len > 0:
      r.putIn levelOf(l.level), nm
    r.padTo (if l.stamp.len > 0: 15 else: 6)
    let room = width - r.width
    if room > 2:
      r.putIn (if l.level == lvError: ColRed
               elif l.level == lvWarn: ColYellow
               else: ColDefault), fit(l.text, room)
    into.add r
  while into.len < rows:
    into.add newRow()

proc padded(s: string; n: int): string =
  result = s
  while result.len < n: result.add ' '

proc streamText(tag: string; l: LogLine): string =
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

proc streamLogs(server, client: var Tail; backendProc: uint64;
                launch: LaunchPtr; keys, owned: bool) =
  ## The view for a console that cannot be painted, and for output that is not
  ## a console at all. Same two logs, one line each as they arrive, tagged with
  ## which side said it -- so a redirected launcher produces a file that is
  ## worth reading rather than a file full of `ESC[2J`.
  line ""
  heading "Logs"
  note "server and client, interleaved as they arrive"
  note (if owned: "Ctrl+C stops the backend and quits"
        else: "Ctrl+C quits; this stops nothing")
  flushOut()
  var seenServer = 0
  var seenClient = 0
  while true:
    discard server.pump()
    discard client.pump()
    while seenServer < server.lines.len:
      let l = server.lines[seenServer]
      inc seenServer
      sayColoured levelOf(l.level), streamText("server", l)
    while seenClient < client.lines.len:
      let l = client.lines[seenClient]
      inc seenClient
      sayColoured levelOf(l.level), streamText("client", l)
    if interrupted():
      return
    if keys:
      let k = pollKey()
      if k == ord('q') or k == ord('Q'): return
    if owned:
      # Only when this launcher started them. `--logs` attaches to somebody
      # else's session, and "there is nothing running" is a state to sit in and
      # report, not a reason to close the window somebody opened to watch for
      # the thing starting.
      let clientAlive = launch != nil and cLaunchAlive(launch) != 0'i32
      # The watchdog runs here too: a redirected/plain session keeps a
      # self-healing backend exactly as the painted view does, and prints its
      # restart lines inline where they are readable in the file.
      let backendUp = wdBackendAlive(backendProc, owned, clientAlive)
      if (not clientAlive) and (not backendUp):
        line "  both the client and the backend have exited"
        return
    sleepMs 250

proc runLogView(root: string; who: string; backendProc: uint64;
                launch: LaunchPtr; owned: bool; detached: var bool) =
  ## Two panes, live, until `q` or `d` or Ctrl+C, or until both processes are
  ## gone. `detached` says which: on `d` the backend is left running.
  detached = false
  var server = newTail(joinPath(root, "aowlspt\\aowlspt-backend.log"))
  var client = newTail(joinPath(root, "aowlspt\\aowlspt-host.log"))

  var w = 0
  var h = 0
  termSize(w, h)
  if termMode() != tmFull or not stdinIsConsole() or w < 40 or h < 12:
    if termMode() == tmFull and stdinIsConsole():
      warn "the window is " & $w & "x" & $h & ", which is too small for the " &
           "split view; falling back to one line per entry"
    streamLogs(server, client, backendProc, launch, stdinIsConsole(), owned)
    return

  var focus = 0        ## 0 server, 1 client
  var solo = false
  var paused = false
  var confirmQuit = false
  var scrollServer = 0
  var scrollClient = 0
  enterFullScreen()
  rawMode true
  drainKeys()
  let began = cNowMs()

  while true:
    termSize(w, h)
    if w <= 0: w = 80
    if h <= 0: h = 25
    # One column short of the window, deliberately. A glyph written into the
    # last cell of a line leaves the console in the deferred-wrap state, and
    # what happens next is host-specific: conhost and Windows Terminal cancel it
    # on the carriage return that follows, and some wrap first and scroll the
    # whole frame by a line every frame. Giving up one column costs nothing and
    # makes the frame the same everywhere.
    w = w - 1
    discard server.pump()
    discard client.pump()
    if not paused:
      scrollServer = 0
      scrollClient = 0

    let bodyH = h - 5
    if bodyH < 3 or w < 40:
      # Resized under us into something that cannot hold the view. Leave
      # cleanly rather than draw a broken frame.
      rawMode false
      leaveFullScreen()
      warn "the window became too small for the split view"
      streamLogs(server, client, backendProc, launch, true, owned)
      return

    let clientAlive = launch != nil and cLaunchAlive(launch) != 0'i32
    # Through the watchdog when owned: this poll is what restarts a dead backend.
    let backendAlive = wdBackendAlive(backendProc, owned, clientAlive)

    var f = newFrame(w, h)

    # Header
    var head = newRow()
    head.put " "
    head.putIn ColWhite, "aowlspt"
    head.put "  "
    head.putIn ColDim, bxV()
    head.put " "
    head.putIn (if who.len > 0: ColCyan else: ColDim),
               (if who.len > 0: who elif owned: "no profile" else: "attached")
    head.put " "
    head.putIn ColDim, bxV()
    head.put " "
    var srvCol = ColGreen
    var srvText = "server up"
    if gWd.givenUp:
      srvCol = ColRed
      srvText = "SERVER DOWN"
    elif not backendAlive:
      srvCol = ColRed
      srvText = "server down"
    elif gWd.active and gWd.restarts > 0:
      srvCol = ColYellow
      srvText = "server up (restarted x" & $gWd.restarts & ")"
    head.putIn srvCol, srvText
    head.put " "
    head.putIn ColDim, bxV()
    head.put " "
    head.putIn (if clientAlive: ColGreen else: ColRed),
               (if clientAlive: "client up" else: "client exited")
    head.padTo w - 10
    head.putIn ColDim, secsText(cNowMs() - began)
    f.addRow head

    # Panes.
    #
    # The arithmetic is written out rather than fudged with `padTo`, because a
    # frame whose columns are one out looks like a rendering bug and is
    # actually an off-by-one that will drift with the window width. Split:
    #   1 + (leftW+2) + 1 + (rightW+2) + 1 == w
    # Solo:
    #   1 + (soloW+2) + 1 == w
    var leftW = 0
    var rightW = 0
    if solo:
      leftW = w - 4
    else:
      leftW = (w - 7) div 2
      rightW = (w - 7) - leftW

    let serverTitle = "server  " & $server.lines.len & " lines" &
                      (if scrollServer > 0: "  back " & $scrollServer else: "")
    let clientTitle = "client  " & $client.lines.len & " lines" &
                      (if scrollClient > 0: "  back " & $scrollClient else: "")

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
    f.addRow top

    var leftRows: seq[Row] = @[]
    var rightRows: seq[Row] = @[]
    if solo:
      if focus == 0: drawPane(server, scrollServer, bodyH, leftW, leftRows)
      else: drawPane(client, scrollClient, bodyH, leftW, leftRows)
    else:
      drawPane(server, scrollServer, bodyH, leftW, leftRows)
      drawPane(client, scrollClient, bodyH, rightW, rightRows)

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
      f.addRow r

    var bottom = newRow()
    bottom.putIn ColDim, bxBL()
    if solo:
      bottom.putIn ColDim, rule(leftW + 2)
    else:
      bottom.putIn ColDim, rule(leftW + 2)
      bottom.putIn ColDim, bxTU()
      bottom.putIn ColDim, rule(rightW + 2)
    bottom.putIn ColDim, bxBR()
    f.addRow bottom

    var help = newRow()
    help.put " "
    if gWd.givenUp:
      # The hard, user-facing error. The backend is gone for good and the game
      # cannot reach its server; say so loudly and say what to do, rather than
      # leave the player staring at a frozen game.
      help.putIn ColRed,
        "BACKEND DOWN -- the game cannot reach its server on 127.0.0.1:" &
        $gWd.port & " and auto-restart gave up. See the server pane / " &
        "aowlspt-backend.log. Press q to quit and relaunch."
    elif confirmQuit:
      help.putIn ColYellow,
        "the game is still running and will lose its server -- q again to " &
        "stop it anyway, d to leave everything running, any other key to stay"
    else:
      help.putIn ColDim, "q quit   d detach   tab swap   f full   space " &
                         (if paused: "follow" else: "pause") &
                         "   pgup/pgdn scroll"
      if paused:
        help.put "   "
        help.putIn ColYellow, "paused"
    f.addRow help
    endFrame(f)

    # Keys
    var acted = false
    while true:
      let k = pollKey()
      if k == 0: break
      acted = true
      if k == ord('q') or k == ord('Q'):
        if clientAlive and not confirmQuit:
          confirmQuit = true
        else:
          rawMode false
          leaveFullScreen()
          return
      elif k == ord('d') or k == ord('D'):
        rawMode false
        leaveFullScreen()
        detached = true
        return
      elif k == 9:  # tab
        focus = 1 - focus
        confirmQuit = false
      elif k == ord('f') or k == ord('F'):
        solo = not solo
        confirmQuit = false
      elif k == ord(' '):
        paused = not paused
        confirmQuit = false
      elif k == KeyPageUp or k == KeyUp:
        paused = true
        let step = (if k == KeyUp: 1 else: bodyH - 1)
        if focus == 0: scrollServer = scrollServer + step
        else: scrollClient = scrollClient + step
        confirmQuit = false
      elif k == KeyPageDown or k == KeyDown:
        let step = (if k == KeyDown: 1 else: bodyH - 1)
        if focus == 0:
          scrollServer = scrollServer - step
          if scrollServer < 0: scrollServer = 0
        else:
          scrollClient = scrollClient - step
          if scrollClient < 0: scrollClient = 0
        confirmQuit = false
      elif k == KeyHome:
        paused = true
        if focus == 0: scrollServer = server.lines.len
        else: scrollClient = client.lines.len
      elif k == KeyEnd:
        paused = false
        scrollServer = 0
        scrollClient = 0
      else:
        confirmQuit = false
    if acted:
      # Clamp after the fact rather than in every branch above.
      if scrollServer > server.lines.len: scrollServer = server.lines.len
      if scrollClient > client.lines.len: scrollClient = client.lines.len

    if interrupted():
      clearInterrupt()
      if clientAlive and not confirmQuit:
        confirmQuit = true
      else:
        rawMode false
        leaveFullScreen()
        return
    if owned and not clientAlive and not backendAlive:
      rawMode false
      leaveFullScreen()
      line "  both the client and the backend have exited"
      return
    sleepMs 100

proc runTailWindow(path, title: string) =
  ## `--tail`: this process is the second console `--client-window` opened. One
  ## log, full width, and nothing else -- it starts nothing and stops nothing,
  ## so closing this window costs only the window.
  discard termStart()
  var t = newTail(path)
  var seen = 0
  sayColoured ColWhite, "  " & title
  sayColoured ColDim, "  " & path
  sayColoured ColDim, "  this window only shows the log. Closing it stops nothing."
  echo ""
  while true:
    discard t.pump()
    while seen < t.lines.len:
      let l = t.lines[seen]
      inc seen
      var r = newRow()
      if l.stamp.len > 0:
        r.putIn ColDim, l.stamp
        r.padTo 12
      let nm = levelName(l.level)
      if nm.len > 0: r.putIn levelOf(l.level), nm
      r.padTo 19
      r.putIn (if l.level == lvError: ColRed else: ColDefault), l.text
      echo r.text
    if interrupted(): return
    sleepMs 250

# ---------------------------------------------------------------------------

proc banner(root: string) =
  if termMode() != tmFull: return
  echo ""
  var r = newRow()
  r.put "  "
  r.putIn ColCyan, "aowlspt"
  r.put "  "
  r.putIn ColDim, "launch"
  echo r.text

proc main(): int =
  let o = parseArgs()
  if o.help:
    echo Usage
    return 0

  discard termStart()
  if o.plain: forcePlain()
  if o.ascii: forceAscii()

  if o.tailPath.len > 0:
    runTailWindow(o.tailPath, o.tailTitle)
    return 0

  var root = o.root
  if root.len == 0:
    # Launched from inside the install, which is the normal case: the exe sits
    # in `aowlspt/` and the game is one level up.
    let here = parentOf(absolutePathOf(paramStr(0)))
    if fileExists(joinPath(here, o.exeName)):
      root = here
    elif fileExists(joinPath(parentOf(here), o.exeName)):
      root = parentOf(here)
    else:
      root = here
  root = absolutePathOf(root)

  let exePath = joinPath(root, o.exeName)
  let hostDll = joinPath(root, "aowlspt\\aowlspt-host-il2cpp.dll")

  banner(root)

  if o.logsOnly:
    # Before every check below it, on purpose. `--logs` is what somebody runs
    # when a session is already going wrong, and refusing to show them the logs
    # because the install looks odd would withhold the one thing that says why.
    var detachedOnly = false
    runLogView(root, "", 0'u64, nil, false, detachedOnly)
    termRestore()
    return 0

  heading "Install"
  if not fileExists(exePath):
    err "no " & o.exeName & " in " & root
    return 1

  let install = identify(root)
  let lines = eft.describe(install)
  for l in lines:
    line "  " & l

  heading "Host"
  line "  " & hostDll
  if not fileExists(hostDll):
    err "the client host is not installed here"
    note "install a payload containing aowlspt/, or build one with `aowl payload`"
    return 1
  let modsDir = joinPath(root, "aowlspt\\mods")
  if isDirectory(modsDir):
    var files: seq[string] = @[]
    var dirs: seq[string] = @[]
    collectEntries(modsDir, files, dirs)
    var count = 0
    for f in files:
      if endsWith(toLowerAscii(f), ".dll"):
        inc count
    line "  " & $count & " mod libraries under aowlspt\\mods"
  else:
    warn "no aowlspt\\mods directory; the host will load nothing"

  # This host talks to IL2CPP. Launching it into a Mono client would not crash
  # -- it would sit there reporting no runtime forever, which is worse, because
  # it looks like it is working.
  if install.backend != bkIl2Cpp:
    if o.force:
      warn "this client is " & $install.backend &
           "; the host expects IL2CPP. Continuing because --force was given."
    else:
      err "this client is " & $install.backend & ", not IL2CPP"
      note "aowlspt-host-il2cpp drives the IL2CPP C API and has nothing to " &
           "bind to in a Mono client. Use the BepInEx host there, or pass " &
           "--force if you know what you are doing."
      return 1

  # Resolved here rather than at parse time: it is a property of the install,
  # and which install this is has only just been worked out.
  heading "Backend URL"
  let cfgPath = backendJsonPath(root)
  let cfg = readBackendConfig(root)
  # The scheme is the transport. https -> the backend serves TLS and the client
  # is handed an https url; http -> plain, for development and the tests. When
  # backend.json names no url at all, the honest default for a real install is
  # TLS on 443 -- but it is a guess, and it says so.
  var https = cfg.https
  var port = cfg.port
  if not cfg.found:
    https = true
    port = TlsPort
    warn "no backendUrl in " & cfgPath & "; assuming https://127.0.0.1/ " &
         "(TLS on 443), which is what a real post-1.0 client needs. Set " &
         "backendUrl if this install is meant for plain HTTP."
  if o.portGiven:
    if cfg.found and cfg.port != o.port:
      if o.allowPortMismatch:
        warn "--port " & $o.port & " disagrees with " & cfgPath & " (" &
             cfg.url & "), which resolves to port " & $cfg.port & ". " &
             "Continuing because --allow-port-mismatch was given: the backend " &
             "will bind " & $o.port & " and the client will still use " &
             $cfg.port & "."
      else:
        err "--port " & $o.port & " disagrees with " & cfgPath
        note cfgPath & " (" & cfg.url & ") resolves to port " & $cfg.port &
             ", and the client reads that file, not this flag. Starting a " &
             "backend on " & $o.port & " would leave the game talking to " &
             "whatever else holds " & $cfg.port & " -- on a machine with a " &
             "stock SPT server, that is the stock server."
        note "change backendUrl in " & cfgPath & " to use port " & $o.port &
             ", or pass --allow-port-mismatch if a backend on " & $o.port &
             " is what you want regardless."
        return 1
    port = o.port
  # For https the client's port is not negotiable: it talks to 443 whatever the
  # url or this flag says, because its own url regex stops at the first colon.
  # A --port other than 443 in TLS mode binds the backend somewhere the real
  # client will never look, so it is worth one line either way.
  if https and o.portGiven and o.port != TlsPort:
    warn "--port " & $o.port & " has no effect on a real post-1.0 client in " &
         "TLS mode: it talks HTTPS on a hardcoded 443 and ignores any port in " &
         "the url. The backend will bind " & $port & ", but the client will " &
         "look for 443."

  let scheme = (if https: "https" else: "http")
  if o.portGiven:
    line "  " & scheme & ", port " & $port & " (--port)"
  elif cfg.found:
    line "  " & scheme & ", port " & $port & " (from " & cfgPath &
         ", which is what the client reads)"
  else:
    line "  " & scheme & ", port " & $port & " (assumed)"
  if https:
    line "  TLS: the backend will serve HTTPS and the client will be handed " &
         "an https url"

  var backendUrl = cfg.url
  if backendUrl.len == 0:
    backendUrl = "https://127.0.0.1/"
    warn "no backendUrl in " & cfgPath & "; the client will be told " &
         backendUrl & ", which is a guess"

  if dryRun():
    heading "Dry run"
    let be = joinPath(root, "aowlspt\\aowlspt-backend.exe")
    if o.noBackend:
      line "  would start   no backend (--no-backend was given)"
      if https:
        line "  would find    a backend on 127.0.0.1:" & $port & " over TLS " &
             "-- the launcher speaks plain HTTP and cannot probe HTTPS, so " &
             "this is not checked"
      else:
        let already = answers(port)
        if already == 1:
          line "  would find    a backend already answering on 127.0.0.1:" & $port
        elif already == 0:
          line "  would find    nothing answering on 127.0.0.1:" & $port &
               " -- start one by hand first"
    elif fileExists(be):
      line "  would start   " & be & " --port " & $port &
           (if https: " --tls" else: "")
      if o.backendWait > 0:
        if https:
          line "  would wait    until it logs it is listening on TLS, up to " &
               $o.backendWait & "s"
        else:
          line "  would wait    until it answers on 127.0.0.1:" & $port &
               ", up to " & $o.backendWait & "s"
      else:
        line "  would wait    not at all (--backend-wait 0)"
    else:
      # Said rather than left out. A dry run that silently omits the backend
      # line reads as "the backend is not part of this", when what it means is
      # "there is no backend in this install" -- and the real launch would go
      # on to start a client with nothing to talk to.
      warn "  no backend at " & be & "; the client would start alone"
    let dExplicit = o.profileId.len > 0 or o.newProfile.len > 0
    let dAuto = not o.noProfile and not o.pick and not dExplicit
    if o.noProfile:
      line "  would ask     nothing about profiles, and bind none (--no-profile)"
    elif dAuto:
      line "  would ask     nothing"
      let l = listProfiles(port, root)
      if l.error.len > 0:
        line "  would play    nothing -- " & l.error & " -- so no -token"
      else:
        var dChosen = Profile(id: "", token: "", nickname: "", side: "",
                              level: 0, edition: "", lastPlayed: 0)
        var dWhy = ""
        if autoProfile(l, readLastProfile(root), dChosen, dWhy):
          line "  would play    " & profileLabel(dChosen) & " (" & dChosen.id &
               ") -- " & dWhy & ", bound with -token before launch"
        else:
          line "  would play    nothing -- " & dWhy & " -- so no -token, and " &
               "the game's own character creation runs"
    elif o.profileId.len > 0:
      line "  would play    " & o.profileId & " (--profile)"
    elif o.newProfile.len > 0:
      line "  would create  " & o.newProfile & " (--new) and play it"
    elif https:
      line "  would ask     which profile, read from the store on disk -- the " &
           "launcher cannot use the backend's profile routes over TLS"
    else:
      let l = listProfiles(port, root)
      if l.error.len > 0:
        line "  would ask     which profile, but: " & l.error
      else:
        line "  would ask     which of " & $l.items.len & " profile(s) to play"
        if l.note.len > 0:
          note l.note
    line "  would start   " & exePath
    line "  would pass    " &
         clientCommandLine(backendUrl, "<the chosen profile>", o.extraArgs)
    line "  would inject  " & hostDll
    line "  nothing was started."
    return 0

  # The backend goes up first. The client tries to reach it as soon as it
  # starts, so starting them the other way round is a race the client loses --
  # and the profile list has to be asked for before the client is started at
  # all, because the answer goes on its command line.
  var backendProc = 0'u64
  let backendExe = joinPath(root, "aowlspt\\aowlspt-backend.exe")

  # `db.json` is the one required post-install step with an external
  # dependency, and skipping it fails SILENTLY: measured on a root with no
  # database, the backend starts, loads every mod, creates profiles and
  # answers 200 on every route -- but `/client/items`, `/client/globals` and
  # `/client/customization` all come back as a structurally valid, EMPTY
  # `data` (33-byte bodies). Every signal a tester can see says healthy and
  # the game has no items in it. The backend now warns, but it warns into its
  # own log; this is the screen a person is actually looking at, so it has to
  # be said here too. A warning, not a refusal -- an empty database is a
  # legitimate state to boot into while importing, and the launcher does not
  # get to decide otherwise.
  block:
    let dbPath = joinPath(root, "aowlspt\\db.json")
    if not fileExists(dbPath):
      heading "Database"
      warn "there is no db.json at " & dbPath & ". The server will start and " &
           "answer everything, but the game will have NO ITEMS in it: " &
           "/client/items, /client/globals and /client/customization all " &
           "return empty. Run aowl-importdb.exe against a Tarkov or SPT " &
           "install to produce it, then start again."

  if o.noBackend:
    # Asked, not assumed, and not waited on. `--no-backend` means this launcher
    # is not responsible for the server -- so it says what is there and starts
    # the client either way, which is the whole point of the flag.
    heading "Backend"
    if https:
      note "a backend on 127.0.0.1:" & $port & " over TLS was assumed but not " &
           "probed: the launcher speaks plain HTTP and --no-backend was given, " &
           "so none will be started. The client will have no server unless one " &
           "is already up on TLS."
    elif answers(port) == 1:
      ok "a backend is already answering on 127.0.0.1:" & $port
    else:
      warn "nothing is answering on 127.0.0.1:" & $port &
           " and --no-backend was given, so none will be started. The client " &
           "will have no server to talk to unless one comes up on its own."
  else:
    heading "Backend"
    if not fileExists(backendExe):
      warn "no backend at " & backendExe & "; starting the client alone"
    else:
      var be = backendExe
      var bd = joinPath(root, "aowlspt")
      # `--port` is passed even in TLS mode (443, or the explicit url port), and
      # `--tls` makes the backend terminate HTTPS on it with its self-signed
      # cert -- which is what a real post-1.0 client needs.
      var bc = "\"" & backendExe & "\" --root \"" & bd & "\" --port " & $port
      # Quiet, not `aowl_spawn`. The backend used to be given a console of its
      # own, which is a second window nobody asked for and which duplicates,
      # badly, the pane it now has in the log view -- and closing that window
      # killed the server. Its log file is the same text and outlives the run.
      if https: bc.add " --tls"
      backendProc = cSpawnQuiet(toCString(be), toCString(bd), toCString(bc))
      if backendProc == 0'u64:
        err "could not start the backend"
        return 1
      # Arm the watchdog with exactly these spawn arguments. From here on, if the
      # backend dies while the game is alive, the run loops restart it from this
      # -- the player never sees the crash, only a brief "server restarting".
      wdArm(be, bd, bc, joinPath(root, "aowlspt\\aowlspt-backend.log"), port,
            backendProc)
      # Not `ok`, and not "started". All that is known here is that
      # `CreateProcess` returned a handle: the backend may already have exited
      # on a bad database, a held port or a mod that throws on load. It printed
      # `ok backend started on port N` for a process that was **already dead**,
      # and then sat waiting five minutes for it. The next step is the one that
      # can say "started", because it asks the port.
      line "  spawned " & backendExe & "; --port " & $port &
           (if https: " --tls" else: "")

      # Wait for an *answer*, not for a duration. See `waitForBackend`: what is
      # being waited for is an event, and the event is observable exactly as it
      # happens -- the backend calls `aowl_net_serve` only after every mod has
      # finished loading, so a successful request is not an approximation of
      # readiness, it is readiness.
      if o.backendWait <= 0:
        note "not waiting for the backend (--backend-wait 0); the client may " &
             "come up before the server can answer it"
      else:
        line ""
        var died = false
        var answered = false
        var probeBroken = false
        waitForBackend(root, port, https, backendProc, o.backendWait,
                       joinPath(root, "aowlspt\\aowlspt-backend.log"),
                       died, answered, probeBroken)
        if died:
          err "the backend exited while starting; see " &
              joinPath(root, "aowlspt\\aowlspt-backend.log")
          return 1
        if probeBroken:
          warn "could not open a socket to ask the backend anything, so " &
               "whether it is ready could not be checked. Starting the " &
               "client anyway."
        elif answered:
          if https:
            ok "the backend is listening on 127.0.0.1:" & $port & " over TLS"
          else:
            ok "the backend is answering on 127.0.0.1:" & $port
        else:
          warn "the backend has not answered after " & $o.backendWait &
               "s and is still running. Starting the client anyway -- it may " &
               "reach the menu before the server does."
          note "see " & joinPath(root, "aowlspt\\aowlspt-backend.log") &
               " for what it is doing, or raise --backend-wait"

  # --- the profile -----------------------------------------------------------
  var token = ""
  var who = ""
  # The game has its own character-select screen (served by the tarkov mod's
  # `/v2/client/game/profiles/` and `/client/game/profile/select`), and it shows
  # on every boot regardless of the -token. A launcher picker on top of it is
  # the same choice made twice -- the redundant second selector a player hits.
  # So by default the launcher does NOT ask.
  #
  # **It does still bind.** Not asking is not the same as not selecting, and an
  # earlier attempt at this conflated the two: it defaulted to the no-token boot
  # path, and the client failed with "Client not authenticated". The reason is
  # in the emulator, and it is not subtle. `-token=<id>` is the *only* thing
  # that gives the client a `PHPSESSID` cookie (`clientCommandLine`, and
  # `aowlbackend.parseHead` reads the session from that cookie and nowhere
  # else). With no token the backend sees an empty session on every request --
  # the live log said exactly that, `client/metadata HIT: body.len=49
  # session=` -- and `tarkov.currentProfile` maps an empty session to no
  # profile: `profileFor("")` is "", and its only fallback fires when the
  # install holds exactly one profile *and* the session id is non-empty (it has
  # to be, since the fallback works by `bindSession`ing it). So every
  # `/client/` route answers "no profile on this session" and the client stops
  # at authentication, before the character-select screen it was supposed to
  # reach. The in-game screen cannot rescue this either: `onProfilesV2` fills
  # the one "regular" slot from the first readable profile and `break`s, so it
  # is not a multi-profile chooser to begin with.
  #
  # What the player actually wanted was one selector, not zero sessions. So the
  # default auto-selects -- silently, from what is on record -- and pre-binds it
  # through the same `selectProfile` call the interactive picker uses, so the
  # bound-session path is identical whether or not anybody was asked. Zero
  # profiles is the one case that still boots with no token: there is nothing to
  # bind, and the game's own character-creation flow is the intended first run.
  let explicitProfile = o.profileId.len > 0 or o.newProfile.len > 0
  let autoSelect = not o.noProfile and not o.pick and not explicitProfile
  heading "Profile"
  if https and not o.noProfile:
    # The launcher's own HTTP client is plain-only, so over TLS it cannot ask
    # the backend for the profile list or create/select one; it reads the
    # store on disk instead. Said once, here, so the store-source note that
    # follows is not a surprise.
    note "over TLS the launcher reads profiles from the store on disk: it " &
         "speaks plain HTTP and cannot reach the backend's profile routes. " &
         "Creating a profile from here needs a plain-HTTP (http://) backend."
  var chosen = Profile(id: "", token: "", nickname: "", side: "", level: 0,
                       edition: "", lastPlayed: 0)
  var haveChoice = false
  var viaRoute = false
  var why = ""
  if o.noProfile:
    note "--no-profile: the client is started with no -token and will log " &
         "in on its own. The backend binds no session for it, so this is the " &
         "first-run/character-creation path, not a way into an existing " &
         "character."
  elif autoSelect:
    let list = listProfilesWaiting(port, root)
    viaRoute = list.source == psRoute
    if list.error.len > 0:
      # Not fatal: a backend with no profile route and no store on disk is an
      # install with nothing to select, which is the first-run case.
      warn list.error
      note "nothing to select, so the client starts with no -token and the " &
           "game's own character-creation flow runs"
    else:
      if list.note.len > 0: warn list.note
      var reason = ""
      if autoProfile(list, readLastProfile(root), chosen, reason):
        haveChoice = true
        ok "playing " & profileLabel(chosen) & " (" & chosen.id & ") -- " &
           reason & "; pass --pick to choose, or --profile <id>"
      else:
        note reason & ", so the client starts with no -token and the game's " &
             "own character-creation flow runs"
  else:
    if pickProfile(o, port, root, chosen, why, viaRoute):
      haveChoice = true
    else:
      err "no profile to play: " & why
      note "the client needs a -token to log in, and a made-up one is a " &
           "session the server has never heard of -- the game would reach the " &
           "menu and stay there. Pass --profile <id>, or --new <name> to " &
           "create one, or --no-profile to start the client without one."
      if backendProc != 0'u64:
        cSpawnKill(backendProc)
        line "  backend stopped"
      return 1

  # One binding path for both ways of arriving at a profile. Rebind the session
  # to it before the client arrives on it -- for an auto-selected profile as
  # much as a listed or a freshly made one. The token to launch with is whatever
  # `select` hands back, not the id the launcher held.
  if haveChoice:
    token = chosen.token
    who = profileLabel(chosen)
    if viaRoute:
      var bound = Profile(id: "", token: "", nickname: "", side: "",
                          level: 0, edition: "", lastPlayed: 0)
      let se = selectProfile(port, chosen.id, bound)
      if se.len > 0:
        err "could not select the profile on the server: " & se
        note "the client would arrive on a session the server has not bound " &
             "to this profile, and sit at the menu. This is a backend fault, " &
             "not a launcher one -- see aowlspt-backend.log."
        if backendProc != 0'u64:
          cSpawnKill(backendProc)
          line "  backend stopped"
        return 1
      token = bound.token
      if bound.nickname.len > 0: who = profileLabel(bound)
    if token.len == 0:
      # Belt and braces. A chosen profile whose token came back empty would
      # launch a client with no cookie and fail as "Client not authenticated" at
      # the game's own login -- far from here, and looking like a client bug.
      err "the profile was chosen but there is no token to launch with"
      if backendProc != 0'u64:
        cSpawnKill(backendProc)
        line "  backend stopped"
      return 1
    # Remembered *after* the bind succeeded, so a profile that could not be
    # selected does not become the one the next boot prefers.
    noteLastProfile(root, chosen.id)

    # TELL THE HOST WHICH PROFILE THIS IS. `-token` carries the SESSION to the
    # client; it does not carry the profile id, and the host has no route from
    # one to the other. The `uxSkipModeScreen` feature matches this id against
    # each slot the game's own selection screen shows, so without it the host
    # cannot answer that screen and the user sees the thing they asked never to
    # see. Written after the bind succeeded, for the same reason as above.
    if not noteLaunchProfileId(root, chosen.id):
      warn "could not write launchProfileId into aowlspt-host.json. If " &
           "uxSkipModeScreen is on, the host will not know which profile " &
           "to select and the character/mode selection screen WILL appear. " &
           "The launch itself is unaffected."

  if not haveChoice:
    # NO PROFILE WAS BOUND. Clear `launchProfileId` rather than leaving the
    # previous boot's id in place: a stale id would have the host select a
    # profile this session is not bound to, which is a worse failure than
    # showing the selection screen. `uxSkipModeScreen` then declines loudly at
    # host boot and says the launcher bound nothing, which is the truth.
    if not noteLaunchProfileId(root, ""):
      warn "could not clear launchProfileId in aowlspt-host.json. No " &
           "profile was bound this launch, so a leftover id there could have " &
           "the host select the wrong profile."

  heading "Launching"
  let cmdLine = clientCommandLine(backendUrl, token, o.extraArgs)
  # Whole, not fitted. It is long, and it is the one line somebody will be
  # asked to paste when the client comes up talking to the wrong server.
  line "  " & cmdLine

  let launch = cLaunchNew()
  if launch == nil:
    err "out of memory"
    if backendProc != 0'u64: cSpawnKill(backendProc)
    return 1

  var e = exePath
  var w = root
  var cmd = cmdLine
  if cLaunchStart(launch, toCString(e), toCString(w), toCString(cmd)) == 0'i32:
    err "could not start " & exePath & " (error " & $int(cLaunchError(launch)) & ")"
    cLaunchFree(launch)
    if backendProc != 0'u64: cSpawnKill(backendProc)
    return 1
  ok "started suspended, pid " & $int(cLaunchPid(launch))

  var d = hostDll
  if cLaunchInject(launch, toCString(d)) == 0'i32:
    err "could not inject the host (error " & $int(cLaunchError(launch)) & ")"
    # A game running without its host is worse than no game: the player would
    # be in a raid before noticing. Take it down rather than resume it.
    err "terminating the client rather than leaving it running without mods"
    cLaunchKill(launch)
    cLaunchClose(launch)
    cLaunchFree(launch)
    if backendProc != 0'u64: cSpawnKill(backendProc)
    return 1
  ok "host injected"

  if cLaunchResume(launch) == 0'i32:
    err "could not resume the client (error " & $int(cLaunchError(launch)) & ")"
    cLaunchKill(launch)
    cLaunchClose(launch)
    cLaunchFree(launch)
    if backendProc != 0'u64: cSpawnKill(backendProc)
    return 1
  ok "client resumed"

  let hostLog = joinPath(root, "aowlspt\\aowlspt-host.log")
  line ""
  var clientExited = false
  # Bounded, and the bound is not a deadline for the game -- it is how long
  # this view waits before handing over to the log view, which shows the same
  # thing with more room. A cold IL2CPP launch is minutes.
  watchClient(launch, hostLog, 90000'i64, clientExited)

  # UNCONDITIONAL, before any gate. A verdict that never appears could mean
  # "the walk failed" or "this routine was never entered" -- and those look
  # identical from outside unless entry itself is logged. Written every run,
  # regardless of which branch runs next.
  let verdictPath = joinPath(root, "aowlspt\\aowlspt-autoenter.log")
  # `writeTextFile` OVERWRITES, there is no append helper -- so every write
  # below carries this entry line along with it, on purpose. Losing "how did
  # we get here" every time a later line replaced it is what made the last
  # live run's single surviving line ambiguous.
  let entryLine = "auto-enter: entered, clientExited=" & $clientExited &
    " haveChoice=" & $haveChoice & " noProfile=" & $o.noProfile &
    " noAutoEnter=" & $o.noAutoEnter & " profile=" & chosen.id
  discard writeTextFile(verdictPath, entryLine & "\n")

  if clientExited:
    warn "the client exited while starting; see " & hostLog
    discard writeTextFile(verdictPath,
      entryLine & "\nauto-enter verdict: SKIPPED -- client exited while " &
      "starting\n")
  elif haveChoice and not o.noProfile and not o.noAutoEnter:
    # The client's own character-select screen shows on every boot
    # regardless of `-token` -- that is measured, not assumed (see the
    # "Profile" heading above: `onProfilesV2` always renders a slot, and
    # `RunCharacterSelectionFlow` is a client-side flow the wire cannot skip).
    # So the TUI choice above still has to be re-asserted on screen, and doing
    # that here -- unattended, the instant the screen exists -- is what makes
    # the TUI the ONLY place a human is asked.
    #
    # This calls `aowlui` DIRECTLY, in-process -- NOT `tools/entergame.py`.
    # A first version shelled out to that Python script and it never fired on
    # a real install: there is no source checkout and no Python next to
    # `EscapeFromTarkov.exe`, so it silently hit its own "missing" fallback
    # every time. `aowlui`/`aowluicmd` are the Nim port of the same channel
    # (write `aowlspt-inspect.txt`, read `aowlspt-inspect-out.txt`) and are
    # already linked into this build via `aowl.nim` -- so this ships.
    #
    # Every measured rule `entergame.py` encoded is preserved because this
    # calls the SAME primitives, not a reimplementation:
    #  * `clickText(..., rootName = "Menu UI", exact = true)` matches by the
    #    DISPLAYED title, never the object name (`CharacterSlotView_pvp`
    #    displays "PvE" -- this backend's `onProfilesV2` only ever fills the
    #    "regular" slot, whose title is "PvE", so that is the fixed target).
    #  * Searching is scoped to the LIVE `Menu UI` root, so the inactive
    #    `Login UI` copy of `CharacterSelectionScreen` (fact #94) is never
    #    the one queried.
    #  * `clickText`'s `buttonFor` walk prefers `DefaultUIButton` first and
    #    actuates via its `OnClick` UnityEvent, never
    #    `ButtonFeedback::OnPointerClick` (fact #5: plays the sound, presses
    #    nothing).
    #  * The retry loop below tolerates the placeholder "New Text" window
    #    before localisation lands, by simply not having matched "PvE" yet.
    #
    # After pressing, the close is ASSERTED, not assumed (rule 9b): `expect`
    # is `xkNoScreen` on `CharacterSelectionScreen` under the live `Menu UI`
    # root, so PASS means that specific screen was observed to go inactive,
    # not "something was pressed".
    # The verdict is written HERE, in one place, on every exit from this
    # block -- not only at the end of the happy path. `ok`/`warn`/`note` go
    # to this process's own stdout only, which `tools/harness.py run` (and
    # anything else that launches this headless) swallows entirely: a run
    # driven that way showed no verdict line ANYWHERE, indistinguishable
    # from never having run. So every verdict also lands in a small,
    # single-purpose file next to the host log that survives regardless of
    # how this exe was invoked. (`verdictPath` was already written once,
    # unconditionally, right after `watchClient` returns -- see above.)

    # MEASURED (two bugs, not one):
    #  1. An earlier version started matching at t=+1.3s, right after
    #     `watchClient` returns -- long before the selector can possibly be
    #     up (60-90s on a cold IL2CPP boot). Fixed by waiting for the LIVE
    #     `CharacterSelectionScreen` under `Menu UI` to actually be ACTIVE
    #     first.
    #  2. That fix then made things WORSE: the wait loop's `screens()` polls
    #     were made with `initUi(root, 60000, true)` -- a PINNED 60s
    #     timeout, and `runBatch` itself retries a dropped batch 3 times
    #     internally. One early poll, issued before the client's main
    #     thread is even pumping frames yet, could therefore burn up to
    #     3 x 60s = 180s **inside a single iteration** of what was meant to
    #     be a light, fast, repeated check -- consuming the whole intended
    #     150s wait budget on ONE poll, which reads exactly like "dropped
    #     a batch; retry 1/2, retry 2/2" and then silence. The wait-phase
    #     poll below therefore uses a SHORT, unpinned timeout of its own
    #     (5s) so a poll that gets no answer yet is cheap and the outer
    #     loop actually gets to retry on its own 3s cadence; only the final
    #     click, once the screen is confirmed up, uses the longer pinned
    #     timeout.
    # FOUND (this is the actual bug, not a tuning problem): `runBatch`'s
    # timeout logic is `if t <= 0 or u.timeoutPinned: t = u.timeoutMs` --
    # meaning an UNPINNED `Ui.timeoutMs` is only a FLOOR the call can raise,
    # never a ceiling the caller enforces. `roots()`/`children()`/`actives()`
    # (which `screens()` calls) each pass their OWN hardcoded suggestion
    # (60000/40000/60000ms) as `runBatch`'s `timeoutMs` argument, and since
    # my previous `initUi(root, 5000, false)` left `timeoutPinned = false`,
    # every one of those suggestions WON over my 5s, each retried 3x
    # internally -- so a single `screens()` call could legitimately block
    # for minutes, exactly matching "one 'before' line, no 'after', ~280s
    # gone". `pinned = true` is what actually forces `Ui.timeoutMs` to win.
    #
    # SECOND BUG, found the same way: `initUi`'s `live` argument must be the
    # INSTALL directory that actually holds `aowlspt-inspect.txt` and
    # `aowlspt-host.log` (`D:\Aowlspt\aowlspt`) -- but this launcher's own
    # `root` is one level ABOVE that (`D:\Aowlspt`, where
    # `EscapeFromTarkov.exe` sits; see `hostLog = joinPath(root,
    # "aowlspt\\aowlspt-host.log")` above). Passing `root` straight to
    # `initUi` pointed every read/write at `D:\Aowlspt\aowlspt-inspect.txt`
    # -- a file the host never looks at -- so no batch could ever be
    # answered, independent of any timeout. `joinPath(root, "aowlspt")` is
    # the fix.
    #
    # THIRD: 5s was measured as too aggressive for this channel -- a
    # healthy `EFT.UI.PreloaderUI::Update`-drained batch routinely takes
    # 10-30s, so 5s was timing out a live channel and reading it as "no
    # screen". Raised to 20s per attempt (still pinned, still a real
    # ceiling), and the wall-clock wait bound raised to 270s to match (the
    # client legitimately takes 90s+ to reach the selector).
    var u = initUi(joinPath(root, "aowlspt"), 20000, true)
    var waitTries = 0
    var screenUp = false
    var waitErr = ""
    let waitStart = cNowMs()
    discard writeTextFile(verdictPath,
      entryLine & "\nauto-enter: before screen-wait loop\n")
    # The bound is WALL-CLOCK, not "N attempts", so a call that runs long
    # despite the pin still cannot keep this looping past 270s.
    while cNowMs() - waitStart < 270000'i64 and not screenUp:
      var ss = default(ScreenSet)
      var active = triUnknown
      if screens(u, "Menu UI", ss):
        for sc in ss.screens:
          if sc.name == "CharacterSelectionScreen":
            active = sc.active
            if sc.active == triYes: screenUp = true
      else:
        waitErr = u.lastErr
      discard writeTextFile(verdictPath,
        entryLine & "\nauto-enter: wait iter " & $waitTries & " elapsed=" &
        $(cNowMs() - waitStart) & "ms active=" & $active &
        " err=" & waitErr & "\n")
      if not screenUp:
        cSleepMs 3000
        inc waitTries
    discard writeTextFile(verdictPath,
      entryLine & "\nauto-enter: after screen-wait loop, screenUp=" &
      $screenUp & " waitTries=" & $waitTries & " waitErr=" & waitErr & "\n")
    if not screenUp:
      let msg = "auto-enter verdict: INCONCLUSIVE -- " &
        "CharacterSelectionScreen under Menu UI never became active " &
        "within 270s. " & waitErr
      warn msg
      discard writeTextFile(verdictPath, entryLine & "\n" & msg & "\n")
      note "left at whatever screen is actually up; check liveInspector is " &
           "on in aowlspt-host.json, or pass --no-auto-enter to silence this"
    else:
      ok "character-select is up (waited " & $(waitTries * 3) & "s) -- matching now"
      u.timeoutMs = 60000
      u.timeoutPinned = true
      var pressed = false
      var lastMsg = ""
      var tries = 0
      while tries < 10 and not pressed:
        let expect = Expect(kind: xkNoScreen, name: "CharacterSelectionScreen",
                            root: "Menu UI")
        let r = clickText(u, "PvE", "Menu UI", true, "", expect, 4000, true)
        lastMsg = r.msg
        if r.ok:
          pressed = true
        elif lastMsg.contains("liveInspector"):
          break
        else:
          cSleepMs 3000
        inc tries
      if pressed:
        let msg = "auto-enter verdict: PASS (verified closed) -- " & lastMsg
        ok msg
        discard writeTextFile(verdictPath, entryLine & "\n" & msg & "\n")
      else:
        let msg = "auto-enter verdict: FAIL (screen still up, or a " &
          "candidate could not be pressed, after " & $tries & " attempt(s)) " &
          "-- " & lastMsg
        warn msg
        discard writeTextFile(verdictPath, entryLine & "\n" & msg & "\n")
        note "left at the manual selector; pass --no-auto-enter to silence " &
             "this warning next time"

  if o.clientWindow:
    # The second window, for anyone who wants it. It is another copy of this
    # executable in `--tail` mode: it starts nothing, holds nothing, and
    # closing it costs only the window.
    var selfExe = absolutePathOf(paramStr(0))
    var selfDir = parentOf(selfExe)
    var tailCmd = "\"" & selfExe & "\" --tail \"" & hostLog &
                  "\" --tail-title \"client -- aowlspt-host.log\""
    if cSpawn(toCString(selfExe), toCString(selfDir), toCString(tailCmd)) == 0'u64:
      warn "could not open a second window for the client log"

  if o.noLogs:
    line "  the server writes " & joinPath(root, "aowlspt\\aowlspt-backend.log")
    line "  the host writes   " & hostLog
    if o.wait:
      heading "Waiting"
      # Wait on the client, but keep the watchdog turning so the backend is
      # still restarted under `--no-logs --wait` -- the same self-healing the
      # log view gives, without the view.
      while cLaunchAlive(launch) != 0'i32:
        discard wdPoll(true)
        if gWd.givenUp:
          err "BACKEND DOWN -- auto-restart gave up; the game has no server " &
              "on 127.0.0.1:" & $port & ". See " &
              joinPath(root, "aowlspt\\aowlspt-backend.log")
          break
        cSleepMs 500
      discard cLaunchWait(launch, -1'i32)
      line "  the client exited"
      let h = wdCurrentHandle(backendProc)
      if h != 0'u64:
        cSpawnKill(h)
        line "  backend stopped"
  else:
    var detached = false
    runLogView(root, who, backendProc, launch, true, detached)
    if detached:
      line ""
      ok "detached: the game and the backend are still running"
      note "the logs are at " & joinPath(root, "aowlspt\\aowlspt-backend.log") &
           " and " & hostLog
    else:
      let h = wdCurrentHandle(backendProc)
      if h != 0'u64 and cSpawnAlive(h) != 0'i32:
        cSpawnKill(h)
        line "  backend stopped"
      if cLaunchAlive(launch) != 0'i32:
        note "the game is still running. It has no server now -- close it, or " &
             "start the launcher again with --no-backend once one is up."

  cLaunchClose(launch)
  cLaunchFree(launch)
  termRestore()
  result = 0

quit(main())
