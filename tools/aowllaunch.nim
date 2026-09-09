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
## which profile to play, starts the game, and shows both logs live.
##
## It does that on TWO screens, in ONE console and ONE process, one after the
## other. Nothing is spawned for the second one:
##
##   SCREEN 1 -- the launcher (`launcherRows`). The launch-progress region with
##     its ticks filling in, and a panel listing this install's profiles: which
##     one is about to be played, and -- on a first run, when there are none --
##     how to create one. Painted in the scrollback by `waitForBackend` and
##     `watchClient`.
##   SCREEN 2 -- the live logs (`logViewRows`). The launch collapsed to one
##     summary line and both log panes side by side, full screen, keys live.
##     `runLogView` paints this, and the launcher swaps to it once the client
##     is up.
##
## A revision in between fused the two into a single frame -- progress on top,
## both panes below, all the time. That is what this undoes, and it is worth
## writing down why, because the fused frame was not obviously wrong: it spent
## half of a small window on a client pane that was still showing the PREVIOUS
## session's log, and it left the profile panel nowhere to live. The two views
## want the whole window at different moments, and they get it.
##
## The swap is marked by `handoffRow` -- one line saying the launch is done and
## the logs are taking the screen -- so it is an event the player watched
## happen rather than a frame that silently became a different frame.
##
## `pickProfile` still takes the console to itself, because it is a prompt and
## a prompt needs the cursor; screen 1 is left settled in the scrollback above
## it.
##
## Each of those phases has one rule in common.
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
## The other rule is that every phase degrades, and SAYS SO WHEN IT DOES.
## `aowlterm` decides whether this is a VT console, a console without VT, or not
## a console at all; the two layout functions decide whether the window can
## hold their screen. A launcher whose output is being redirected into a file for somebody
## to read on Discord must produce a file with no escape codes in it, and a
## launcher in an 80x10 window must produce something legible in an 80x10
## window. What it must never do is quietly become a different view: below the
## minimum, the layout refuses and hands back a reason, the phase prints that
## reason, and the plain interleaved `streamLogs` takes over. A skipped region
## that reads as a rendered one is the failure this whole file is written
## against. `tests/tuilayout.nim` renders the grid at five window sizes and
## checks it, so none of that depends on somebody launching the game to look.

import std/[strutils, syncio, cmdline, envvars]
import aowlsptinstall/[winfs, log, eft]
import "../host/common/jsonpath"
import aowlterm
import aowllayout
import aowlsession
import aowlui
import aowldlss

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
                 and binds it, so the TUI is the only place you are ever
                 asked. The in-game character-select is answered by the HOST
                 (see --auto-enter).
  --auto-enter   drive the in-game character-select screen from the launcher,
                 over the live-inspector file channel. OFF by default: the
                 host answers that screen natively every boot (modeskip.nim,
                 flag uxSkipModeScreen in aowlspt-host.json), so this is
                 redundant, and it is not free -- it writes an `allow write`
                 probe batch that calls into game code and it owns the single
                 inspector command file while it does. Use it to debug the
                 selector, or on a build with uxSkipModeScreen off.
  --no-auto-enter
                 accepted and ignored -- it now asks for the default. Kept so
                 existing scripts and shortcuts keep working.
  --low-render   (alias: --headless) run the client CHEAP, not headless. It
                 appends Unity's own player switches to the game's command
                 line: -screen-width/-screen-height (default 1280x720),
                 -screen-fullscreen 0 and -popupwindow. Use --render-size WxH
                 to choose the size.
                 WHAT IT DOES NOT DO: it is NOT headless. The renderer still
                 runs, the window is still there and still on screen, there is
                 no frame-rate cap, and nothing about the host's overlays
                 changes. It does not pass -batchmode/-nographics -- see
                 --nographics-anyway. For a run with NO game client at all,
                 that is `python tools\headless.py`, which exercises the
                 backend and the emulator and never starts Tarkov.
  --render-size WxH
                 the size --low-render asks for (default 1280x720)
  --nographics-anyway
                 also pass -batchmode -nographics. UNVERIFIED AND EXPECTED TO
                 FAIL: this UnityPlayer.dll does contain both switches, but
                 nothing here has ever booted this client with them, the whole
                 aowlspt host drives the game through its UI, and BattlEye sits
                 in front of the player's own argument handling. It is here so
                 the experiment can be run deliberately, not so it can be run
                 by accident. Requires --low-render.
  --modbuild PATH
                 the mod builder to run at startup (an .exe, or a .py run
                 with an interpreter). Default: aowlspt\aowlspt-modbuild.exe
                 if present, else aowlspt\tools\modbuild.py run with the
                 install's bundled interpreter or python on PATH.
  --no-mod-build do not compile the mods folder at startup. The host then
                 loads whatever .dll files are already there.
  --rebuild-mods ignore the build cache and recompile every mod. Slow (a cold
                 build of all mods is minutes); for proving a rebuild works.
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

Mod arguments
  Any --option this launcher does not own is FORWARDED to the game as
  `-aowl.<name>=<value>`, and each forward is printed as it is decided:

      aowlspt-launch --raid Woods          ->  -aowl.raid=Woods
      aowlspt-launch --raid="Ground Zero"  ->  -aowl.raid="Ground Zero"
      aowlspt-launch --raiddebug           ->  -aowl.raiddebug=true

  The host parses those once at startup and any mod reads them through
  `aowlspt/args`. A `-aowl.*` name no loaded mod declared is WARNED about in
  aowlspt-host.log, so a misspelling announces itself instead of doing
  nothing. Which arguments exist is documented by each mod's README and, when
  it lists them, by registry/mods.json -- `--help` prints that list below.
  A launcher option written in a form this launcher does not accept
  (--root=D:\path) is REFUSED rather than forwarded. `--dry-run` prints the
  final client command line, forwarded tokens included.

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
    forwarded: seq[string]
      ## `--<name>[=<value>]` options this launcher does not own, already
      ## rendered as `-aowl.<name>=<value>` tokens for the game's command line.
      ## Folded into `extraArgs` at the end of `parseArgs`, so the dry run and
      ## the real launch read the ONE field and cannot drift.
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
    pick: bool
      ## `--pick`: restore the launcher's own TUI profile picker. Off by
      ## default -- the TUI is now the ONLY place a profile is chosen (see
      ## `--no-auto-enter`); the in-game character-select is auto-pressed
      ## rather than shown to a human.
    autoEnter: bool
      ## `--auto-enter`: drive the in-game character-select from HERE, through
      ## the live-inspector file channel. OFF by default since 2026-09-02, and
      ## the default flip is the point:
      ##
      ## The HOST already answers that screen natively every boot
      ## (`modeskip.nim`, flag `uxSkipModeScreen`; the host log says `skip mode
      ## screen: Submit called for profile ...` at ~26s). So this path was
      ## redundant -- and not free. Measured on a normal boot it wrote eight
      ## `roots` polls and then a 58-command batch carrying `allow write` and
      ## 29 `call name:get_activeInHierarchy` into `aowlspt-inspect.txt` within
      ## the first 22s, i.e. it called into game code unprompted, delayed any
      ## other tool's batch on that single-writer channel, and left the whole
      ## probe batch sitting in the command file for the next boot to find.
      ##
      ## Keep it for debugging the selector itself, or for a build where
      ## `uxSkipModeScreen` is off.
    noAutoEnter: bool
      ## `--no-auto-enter`: ACCEPTED AND IGNORED, on purpose. It was the escape
      ## hatch from the old default and it is now what happens anyway, so
      ## anything that still passes it -- scripts, shortcuts, `harness.py`
      ## invocations -- keeps working and gets exactly what it asked for. It is
      ## recorded rather than dropped only so the verdict file can say the flag
      ## was seen.
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
    lowRender: bool
      ## `--low-render` / `--headless`. Deliberately NOT called `headless`
      ## internally: it does not make the client headless, it makes it small
      ## and windowed. A name that overstates what a flag does is how a mode
      ## that silently degrades gets shipped.
    renderW: int
    renderH: int
    noGraphics: bool
      ## `--nographics-anyway`: pass `-batchmode -nographics` too. Never on by
      ## default and never implied by `--low-render`.
    modBuild: string
      ## `--modbuild PATH`: an explicit builder, `.exe` or `.py`. Empty means
      ## the resolution order in `resolveModBuilder`.
    noModBuild: bool
    modBuildForce: bool
    readyProbe: bool
      ## `--ready-probe`: answer "is the backend ready on this port, right now"
      ## and exit, starting nothing. It exists so that the readiness RULE can be
      ## falsified from outside this process -- see `tools/test_startup_race.py`,
      ## whose negative control is a `aowlspt-backend.log` containing
      ## `listening on` with nothing at all on the port. That case must exit 3.
    help: bool

const LauncherOptions = [
  "root", "exe", "args", "profile", "new", "side", "tail", "tail-title",
  "modbuild", "no-mod-build", "rebuild-mods", "pick", "auto-enter",
  "no-auto-enter", "low-render", "headless", "nographics-anyway",
  "render-size", "wait", "no-backend", "no-logs", "logs", "client-window",
  "plain", "ascii", "port", "allow-port-mismatch", "backend-wait",
  "ready-probe", "dry-run", "force", "help"]
  ## Every long option this launcher owns, WITHOUT the leading dashes. Used
  ## only to refuse the ambiguous `--<ownoption>=<value>` spelling; the real
  ## parse is still the `if` chain below, so a new option added there and
  ## forgotten here is refused as a MOD argument rather than misparsed --
  ## `tools/test_cmdargs.py` fails on exactly that drift.

proc isLauncherOption(name: string): bool =
  for o in LauncherOptions:
    if o == name: return true
  false

proc validArgName(name: string): bool =
  ## What may follow `-aowl.`: a name a host-side table can key on and a log
  ## line can print unambiguously.
  if name.len == 0 or name.len > 64: return false
  for c in name:
    if not ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '.' or c == '_' or c == '-'):
      return false
  true

proc modArgsFromRegistry(root: string): seq[string] =
  ## Best-effort listing of mod arguments for `--help`, read from
  ## `registry/mods.json`'s optional per-mod `args: [{name, description,
  ## example}]`. READ-ONLY and advisory: the registry is not the authority on
  ## what a mod understands (the mod's own `declareArgs` is, and the host
  ## audits it at boot), so a missing or unreadable registry is reported as
  ## "could not look", never as "this build has no mod arguments".
  result = @[]
  var path = ""
  var cands: seq[string] = @[]
  if root.len > 0: cands.add joinPath(root, "registry\\mods.json")
  cands.add "registry\\mods.json"
  for cand in cands:
    if exists(cand):
      path = cand
      break
  if path.len == 0:
    result.add "  (no registry/mods.json found next to " &
               (if root.len > 0: root else: "this launcher") &
               ", so no mod arguments could be listed -- that is 'could not " &
               "look', not 'there are none')"
    return
  var text = ""
  if not readTextFile(path, text):
    result.add "  (" & path & " could not be read, so no mod arguments could " &
               "be listed -- that is 'could not look', not 'there are none')"
    return
  # A deliberately small scanner: find each `"args"` array and pull the
  # `"name"`/`"description"` pairs inside it. It never fails a launch; the
  # worst case is a shorter list.
  var i = 0
  while true:
    let at = text.find("\"args\"", i)
    if at < 0: break
    let open = text.find('[', at)
    let close = if open >= 0: text.find(']', open) else: -1
    if open < 0 or close < 0: break
    var j = open
    while j < close:
      let na = text.find("\"name\"", j)
      if na < 0 or na > close: break
      var k = text.find('"', text.find(':', na) + 1)
      var e = if k >= 0: text.find('"', k + 1) else: -1
      if k < 0 or e < 0 or e > close: break
      let nm = text.substr(k + 1, e - 1)
      var desc = ""
      let da = text.find("\"description\"", e)
      if da >= 0 and da < close:
        let k2 = text.find('"', text.find(':', da) + 1)
        let e2 = if k2 >= 0: text.find('"', k2 + 1) else: -1
        if k2 >= 0 and e2 >= 0 and e2 < close: desc = text.substr(k2 + 1, e2 - 1)
      result.add "  --" & nm & "  " & desc
      j = e + 1
    i = close + 1
  if result.len == 0:
    result.add "  (no mod in registry/mods.json declares an `args` list; a " &
               "mod's README is the other place to look)"

proc parseArgs(): Options =
  result = Options(root: "", exeName: "EscapeFromTarkov.exe", extraArgs: "", forwarded: @[],
                   wait: false, force: false, noBackend: false, noLogs: false,
                   logsOnly: false,
                   clientWindow: false, plain: false, ascii: false,
                   profileId: "", newProfile: "", side: "Usec",
                   pick: false, port: 0,
                   portGiven: false, allowPortMismatch: false,
                   backendWait: 300, tailPath: "", tailTitle: "log",
                   lowRender: false, renderW: 1280, renderH: 720,
                   noGraphics: false,
                   modBuild: "", noModBuild: false, modBuildForce: false,
                   readyProbe: false, help: false)
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
    elif a == "--modbuild":
      inc i
      if i <= n: result.modBuild = paramStr(i)
    elif a == "--no-mod-build":
      result.noModBuild = true
    elif a == "--rebuild-mods":
      result.modBuildForce = true
    elif a == "--pick":
      result.pick = true
    elif a == "--auto-enter":
      result.autoEnter = true
    elif a == "--no-auto-enter":
      # A no-op compatibility flag, NOT an error: it asks for the default.
      result.noAutoEnter = true
    elif a == "--low-render" or a == "--headless":
      result.lowRender = true
    elif a == "--nographics-anyway":
      result.noGraphics = true
    elif a == "--render-size":
      inc i
      if i <= n:
        let s = paramStr(i)
        var w = 0
        var h = 0
        var seenX = false
        var anyW = false
        var anyH = false
        for ch in s:
          if ch == 'x' or ch == 'X':
            seenX = true
          elif ch >= '0' and ch <= '9':
            let d = ord(ch) - ord('0')
            if seenX:
              h = h * 10 + d
              anyH = true
            else:
              w = w * 10 + d
              anyW = true
          else:
            fatal "--render-size wants WIDTHxHEIGHT, e.g. 1280x720, not: " & s
        if not (anyW and anyH and seenX):
          fatal "--render-size wants WIDTHxHEIGHT, e.g. 1280x720, not: " & s
        if w < 320 or h < 240:
          fatal "--render-size " & s & " is smaller than 320x240. The client " &
                "has not been observed to survive that, and a size it " &
                "silently clamps is a setting that lies."
        result.renderW = w
        result.renderH = h
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
    elif a == "--ready-probe":
      result.readyProbe = true
    elif a == "--dry-run" or a == "-n":
      setDryRun true
    elif a == "--force":
      result.force = true
    elif a == "--help" or a == "-h":
      result.help = true
    elif a.startsWith("--"):
      # ---------------------------------------------------------------
      # MOD ARGUMENT FORWARDING.
      #
      # An option this launcher does not own is not an error any more: it is
      # a MOD's argument, and it is forwarded to the game verbatim as
      # `-aowl.<name>=<value>`. `--raid=Woods` and `--raid Woods` and a bare
      # `--raiddebug` all work; the host parses the `-aowl.*` tokens once at
      # startup and any mod reads them through `aowlspt/args`.
      #
      # It is announced, every time, on the line it is decided. A silent
      # forward would turn a typo into a launch that looks perfect and does
      # nothing, which is exactly the failure this whole path exists to make
      # impossible: the host warns at the other end about any `-aowl.*`
      # token no loaded mod declared, and this line is the first half of
      # that trail.
      var nm = a.substr(2, a.len - 1)
      var val = ""
      var haveVal = false
      let eq = nm.find('=')
      if eq >= 0:
        val = nm.substr(eq + 1, nm.len - 1)
        nm = nm.substr(0, eq - 1)
        haveVal = true
      # THE AMBIGUOUS CASE, REFUSED RATHER THAN GUESSED. A launcher option
      # written in a form this launcher does not accept (`--root=D:\x`) has
      # fallen through to here. Forwarding it would put the user's ROOT on
      # the game's command line as a mod argument and start the launcher in
      # the wrong directory, silently. It is named instead.
      if isLauncherOption(nm):
        fatal "--" & nm & " is one of THIS LAUNCHER's own options, but " &
              "written as `--" & nm & "=...`, which it does not accept. It " &
              "was NOT forwarded to the game as a mod argument, because " &
              "that would silently change what --" & nm & " means. Write it " &
              "as `--" & nm & " <value>`. Nothing was started."
      if not validArgName(nm):
        fatal "unknown option: " & a & " -- it is not one of this " &
              "launcher's options, and `" & nm & "` is not a usable mod " &
              "argument name either (letters, digits, `.`, `_` and `-` " &
              "only, and it may not be empty). Nothing was started."
      if not haveVal:
        # `--name value`: only when the next token is not itself an option.
        # A bare `--name` at the end of the line, or followed by another
        # `-...`, is a FLAG and forwards as the string "true".
        if i + 1 <= n and not paramStr(i + 1).startsWith("-"):
          inc i
          val = paramStr(i)
        else:
          val = "true"
      let tok = "-aowl." & nm & "=" & (if val.contains(' ') or val.len == 0:
                                         "\"" & val & "\"" else: val)
      result.forwarded.add tok
      echo "forwarding " & a & (if haveVal: "" else: " " & val) &
           " to the game as " & tok
    elif a.startsWith("-"):
      fatal "unknown option: " & a & " -- single-dash options all belong to " &
            "this launcher, so an unknown one is a typo, not a mod " &
            "argument. Mod arguments are forwarded from the LONG form: " &
            "`--" & a.substr(1, a.len - 1) & "=<value>`. Nothing was started."
    elif result.root.len == 0:
      result.root = a
    inc i

  # --------------------------------------------------------------------
  # `--low-render` is nothing but a spelling of `--args`. It is folded in
  # HERE, once, so that `--dry-run` prints the very command line a real
  # launch would use: the dry run and the launch read the same field, and
  # cannot drift into disagreeing about what was passed. Ours go FIRST so an
  # explicit `--args` the user typed lands after them and wins.
  if result.noGraphics and not result.lowRender:
    fatal "--nographics-anyway only means anything with --low-render, and it " &
          "is expected to fail even then. Nothing was started."
  if result.lowRender:
    var pre = "-screen-width " & $result.renderW &
              " -screen-height " & $result.renderH &
              " -screen-fullscreen 0 -popupwindow"
    if result.noGraphics:
      pre.add " -batchmode -nographics"
    if result.extraArgs.len > 0:
      result.extraArgs = pre & " " & result.extraArgs
    else:
      result.extraArgs = pre

  # MOD ARGUMENTS LAST, for the same reason `--low-render` goes first: the
  # user's explicit `--args` string is the most specific thing they typed, and
  # nothing this launcher synthesises should sit after it. `-aowl.*` tokens are
  # order-independent to the host's parser, so nothing is lost by that choice.
  if result.forwarded.len > 0:
    var post = ""
    for t in result.forwarded:
      if post.len > 0: post.add " "
      post.add t
    if result.extraArgs.len > 0:
      result.extraArgs = result.extraArgs & " " & post
    else:
      result.extraArgs = post

# ---------------------------------------------------------------------------
# Small formatting
# ---------------------------------------------------------------------------

proc sizeText(bytes: int64): string =
  if bytes <= 0'i64: return "0 B"
  if bytes < 1024'i64: return $int(bytes) & " B"
  if bytes < 1048576'i64: return $int(bytes div 1024'i64) & " KB"
  let mb10 = int(bytes div 104858'i64)
  result = $(mb10 div 10) & "." & $(mb10 mod 10) & " MB"

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
# One screen
# ---------------------------------------------------------------------------
#
# Two screens, drawn by `launcherRows` and `logViewRows` in `aowllayout`, in
# one console and in this one process. What each phase paints:
#
#   boot     SCREEN 1: the backend's steps + the profile panel, in the
#            scrollback. The panel says "read once the server answers" here,
#            because the list genuinely has not been read yet.
#   client   SCREEN 1: the client's steps  + the profile panel, now populated,
#            with the bound profile marked.
#   run      SCREEN 2: ONE summary line + both panes, full screen, keys live.
#
# The two `Tail`s are created ONCE, in `main`, and threaded through all three.
# Before this they were opened three times -- `waitForBackend` opened the
# backend log, `watchClient` opened the host log, and `runLogView` opened both
# again from offset zero -- which meant the log view re-read and re-parsed
# everything the boot view had already read, and the boot view could not show
# the client's log at all because it did not have it. Sharing them is not an
# optimisation; it is what makes one screen possible.

type
  Logs = object
    server: Tail
    client: Tail
    clientStarted: bool
      ## False until the client process has been created and the injected host
      ## has had the chance to truncate its log. While it is false the client
      ## pane is showing the PREVIOUS session's file, and the pane title says
      ## so -- an old log presented as a live one is the kind of confidently
      ## wrong answer this launcher exists to avoid.
    serverFresh: bool
      ## True once `rotateServerLog` has proved the backend log on disk is not
      ## the previous run's. While it is FALSE, nothing in the server log may be
      ## treated as evidence about this run -- see `rotateServerLog` for the
      ## measured failure that rule comes from.

proc newLogs(root: string): Logs =
  result = Logs(server: newTail(joinPath(root, "aowlspt\\aowlspt-backend.log")),
                client: newTail(joinPath(root, "aowlspt\\aowlspt-host.log")),
                clientStarted: false, serverFresh: false)

proc rotateServerLog(root: string; l: var Logs): bool =
  ## Move the previous run's backend log out of the way, BEFORE the backend is
  ## spawned, and start following an empty path.
  ##
  ## THIS IS THE STARTUP RACE, and it is a defect in this file, not in the
  ## backend. `waitForBackend` in TLS mode decides the server is up by finding
  ## `listening on` in `aowlspt-backend.log`. That file is the PREVIOUS run's
  ## until the new backend truncates it, roughly 40 ms after spawn -- and
  ## `logs` is created ~300 lines earlier, during preflight, so the first
  ## `pumpBoth` inside `waitForBackend` reads the whole stale file from offset
  ## zero. `aowl_tail_read` cannot save this: it detects a truncation by
  ## `size < offset` or by a change in `creationTime ^ fileIndex`, and on the
  ## FIRST read the offset is 0 (so the size test cannot fire) while
  ## `CREATE_ALWAYS` over an existing file KEEPS both the creation time and the
  ## MFT index (so the stamp test cannot fire either). The stale `listening on`
  ## is therefore ingested as this run's.
  ##
  ## MEASURED 2026-09-01: backend spawned 22:48:25, client spawned 22:48:27,
  ## the real `listening on` written at 0:00:05.9 -- the client was started
  ## nearly four seconds before anything was listening, its NATIVE pre-
  ## `il2cpp_init` version check found no server, and it drew
  ## `Unable to check the client version`. No client log folder is ever created
  ## on that path, which is why it looked like a crash with no evidence.
  ##
  ## Returns true when the log path is now genuinely absent. False is not fatal
  ## -- `waitForBackend` still has the TCP probe, which cannot be stale -- but
  ## it IS reported, because a rotation that quietly did nothing would put the
  ## bug straight back.
  let path = joinPath(root, "aowlspt\\aowlspt-backend.log")
  if not fileExists(path):
    l.server = newTail(path)
    l.serverFresh = true
    return true
  # Kept rather than deleted: it is the evidence for whatever went wrong last
  # time, and this is the only moment anything is in a position to save it.
  discard copyFileAt(path, path & ".prev", overwrite = true)
  discard removeFileAt(path)
  result = not fileExists(path)
  # A fresh `Tail`, unconditionally. Even when the remove failed, the offset
  # must not carry over from a file this launcher has not read.
  l.server = newTail(path)
  l.serverFresh = result

proc pumpBoth(l: var Logs) =
  discard l.server.pump()
  discard l.client.pump()

type
  Phase = enum
    phBoot, phClient, phRun

  Screen = object
    ## Everything the unified screen draws, as data. Filled by the phase that
    ## owns the moment; the drawing code has no opinion about which phase it is
    ## in beyond which progress rows to build.
    phase: Phase
    boot: BootState
    host: HostState
    answered: bool
    alive: bool
    tlsMode: bool
    port: int
    pid: int
    who: string
    srvText: string
    srvCol: int
    cliText: string
    cliCol: int
    summaryKind: int
    summaryText: string
    # --- screen 1's profile panel -------------------------------------------
    profilesKnown: bool
      ## False until the backend has been asked. It is NOT the same as "there
      ## are none": during the boot wait the list has not been read yet, and a
      ## panel that offered to create a profile at that moment would be
      ## offering it because it had not looked, which is the create affordance
      ## appearing for an install that already has six characters.
    enterState: int
      ## The auto-enter wait's verdict (`EwWaiting` .. `EwTimedOut`). Screen 1
      ## grows a fifth step from it, because that wait used to be a completely
      ## invisible 270 seconds sitting behind a settled, frozen panel.
    enterWaitedMs: int64
    enterDetail: string
      ## What the wait is actually OBSERVING, from `enterWaitDetail`. A clock
      ## alone made "the menu is up, watching for the selector" and "every poll
      ## has gone unanswered" render identically.
    profiles: seq[Profile]
    chosenId: string
      ## The profile the launcher bound, so the panel can mark WHICH row is the
      ## one being played rather than leaving the player to infer it.
    canCreate: bool
      ## Whether the backend's launcher routes are actually reachable. The
      ## create affordance is drawn only when it can be honoured -- an offer
      ## the launcher would then refuse is worse than no offer.
    profileNote: string

proc newScreen(): Screen =
  result = Screen(phase: phBoot,
                  boot: BootState(portFree: false, dbBytes: 0'i64,
                                  dbLoaded: false, modsTotal: 0,
                                  modsTotalKnown: false, modsLoaded: 0,
                                  lastLoaded: "", listening: false, errors: 0,
                                  lastError: ""),
                  host: HostState(wroteAnything: false, guardAnswered: false,
                                  runtimeUp: false, running: false,
                                  modsLoaded: 0, errors: 0, lastError: ""),
                  answered: false, alive: true, tlsMode: false, port: 0,
                  pid: 0, who: "", srvText: "", srvCol: ColDim,
                  cliText: "", cliCol: ColDim, summaryKind: MarkPending,
                  summaryText: "", profilesKnown: false,
                  enterState: EwWaiting, enterWaitedMs: 0'i64,
                  enterDetail: "", profiles: @[],
                  chosenId: "", canCreate: false, profileNote: "")

proc bootSteps(s: Screen; width: int): seq[Row] =
  let b = s.boot
  result = @[]
  result.add stepRow((if b.portFree: MarkDone else: MarkActive),
                     "port " & $s.port,
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
                     (if b.listening: "127.0.0.1:" & $s.port &
                        (if s.tlsMode: " (TLS)" else: "") else: ""), width)
  # In TLS mode the launcher cannot probe HTTPS, so readiness *is* the backend's
  # own "listening" line rather than a request coming back -- and the label says
  # which, so a green tick never claims more than was actually observed.
  result.add stepRow((if s.answered: MarkDone
                      elif b.listening: MarkActive
                      else: MarkPending),
                     (if s.tlsMode: "ready" else: "answering"),
                     (if s.answered:
                        (if s.tlsMode: "the backend logged it is listening on TLS"
                         else: "/aowlspt/tarkov/selfcheck came back")
                      else: ""), width)
  if b.errors > 0:
    result.add stepRow(MarkFailed, $b.errors & " error(s)", b.lastError, width)

proc clientSteps(s: Screen; width: int): seq[Row] =
  let h = s.host
  result = @[]
  result.add stepRow(MarkDone, "process", "pid " & $s.pid & ", host injected",
                     width)
  result.add stepRow((if not s.alive: MarkFailed
                      elif h.wroteAnything: MarkDone else: MarkActive),
                     "host log",
                     (if not s.alive: "the client exited"
                      elif h.wroteAnything: "writing"
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
  # THE FIFTH STEP. Only once the host is running, because that is when the
  # auto-enter wait starts -- and before this row existed that wait was up to
  # 270 seconds behind a frozen panel with nothing to look at. A step that says
  # what is being waited for, with a clock that moves, is the difference
  # between a bounded wait and an apparent hang.
  if h.running:
    result.add stepRow(
      (case s.enterState
       of EwSelectorUp: MarkActive
       of EwPassed: MarkDone
       of EwClientGone: MarkFailed
       of EwTimedOut: MarkFailed
       of EwNoChannel: MarkFailed
       else: MarkActive),
      "character select",
      # Built by `enterWaitDetail` from what the wait observed, not from a
      # clock. One source, so the row and the verdict cannot disagree.
      (if s.enterDetail.len > 0: s.enterDetail
       else: "waiting for it (" & secsText(s.enterWaitedMs) & ")"), width)
  if h.errors > 0:
    result.add stepRow(MarkFailed, $h.errors & " error(s)", h.lastError, width)

proc screenSteps(s: Screen; width: int): seq[Row] =
  case s.phase
  of phBoot: bootSteps(s, width)
  of phClient: clientSteps(s, width)
  of phRun: @[stepRow(s.summaryKind, "launch", s.summaryText, width)]

proc progressText(s: Screen; kind: var int): string =
  ## The whole progress region in one PLAIN sentence, and the mark that goes in
  ## front of it. Plain because this same text is what a redirected launcher
  ## writes into a file, where an escape sequence is not colour, it is noise --
  ## and because one routine deciding it means the collapsed line on screen and
  ## the line in the file can never drift apart and say two different things.
  ##
  ## Every branch is a sentence the backend or the host WROTE. Nothing here is
  ## derived from how long it has been.
  case s.phase
  of phBoot:
    let b = s.boot
    kind = MarkActive
    result = "starting"
    if s.answered:
      kind = MarkDone
      result = "ready on 127.0.0.1:" & $s.port &
               (if s.tlsMode: " (TLS)" else: "")
    elif b.listening: result = "listening, waiting for it to answer"
    elif b.modsTotalKnown:
      result = "loading mods, " & $b.modsLoaded & " of " & $b.modsTotal
    elif b.dbLoaded: result = "database read, reading the load order"
    elif b.portFree: result = "port " & $s.port & " claimed"
    if b.errors > 0:
      kind = MarkFailed
      result = result & " -- " & $b.errors & " error(s): " & b.lastError
  of phClient:
    let h = s.host
    kind = MarkActive
    result = "waiting for the host's first log line"
    if not s.alive:
      kind = MarkFailed
      result = "the client exited while starting"
    elif h.running:
      kind = MarkDone
      result = "host running, " & $h.modsLoaded & " client mod(s) loaded"
    elif h.runtimeUp: result = "IL2CPP up, host binding"
    elif h.wroteAnything: result = "host started, waiting for the runtime"
    if h.errors > 0 and kind != MarkFailed:
      kind = MarkFailed
      result = result & " -- " & $h.errors & " error(s): " & h.lastError
  of phRun:
    kind = s.summaryKind
    result = s.summaryText

proc progressName(s: Screen): string =
  case s.phase
  of phBoot: "server"
  of phClient: "client"
  of phRun: "launch"

proc screenSummary(s: Screen; width: int): Row =
  ## The progress region collapsed to one line. Still a fact that was observed
  ## -- the count the backend logged, the line the host wrote -- never a
  ## percentage of an elapsed time.
  var kind = MarkActive
  let what = progressText(s, kind)
  result = stepRow(kind, progressName(s), what, width)

proc screenHeader(s: Screen; w: int; elapsed: int64): Row =
  # Column 2, like every other row on both screens: `stepRow`, `handoffRow` and
  # the box interiors all start their text there. It was column 1 here, which
  # left the header a column adrift from the ticks directly under it.
  result = newRow()
  result.put "  "
  result.putIn ColWhite, "aowlspt"
  # EVERY field from here is conditional on fitting.
  #
  # This header is four fixed-width columns and three separators: 2 + 7 + 2 + 1
  # + 1 + 26 = 39 before the SECOND column has even started, so at a 40-column
  # window it ran off the end. A row wider than the console does not get
  # clipped -- it WRAPS, the frame is then one row taller than the window, and
  # the whole thing scrolls up by a line every repaint. That is the "formatting
  # issue" a narrow terminal actually sees, and the layout cannot catch it
  # because the header arrives already built.
  #
  # Fields are dropped right to left, least important first: the clock, then
  # the client state, then the server state, then the profile. `aowlspt` is
  # always there, so the row is never empty.
  # ONE SOURCE. This label used to be `case s.phase` alone, so screen 1 in the
  # client phase always read "starting the client" -- including next to its own
  # "client up" in the very next column, and above four ticked steps. The
  # player saw a header contradicting itself. The phase says which set of
  # things is being reported; the STATE says how far along they are, and both
  # the label and the step marks now read the same state.
  let label =
    case s.phase
    of phBoot: (if s.answered: "server ready" else: "starting the server")
    of phClient:
      if not s.alive: "the client exited"
      elif s.host.running:
        # Past "starting": the host is up and the only thing left is the
        # character-select wait, so say which of those two it is.
        (case s.enterState
         of EwWaiting: "waiting for character select"
         of EwSelectorUp: "entering the game"
         of EwNoChannel: "the inspector is not answering"
         of EwTimedOut: "character select not seen"
         else: (if s.who.len > 0: s.who else: "in game"))
      elif s.host.runtimeUp: "binding the host"
      else: "starting the client"
    of phRun: (if s.who.len > 0: s.who else: "no profile")
  var labelW = 26
  var srvW = 30
  var cliW = 22
  # 2 + 7, then " | " + field, three times, then two spaces before the clock.
  let need = 9 + (3 + labelW) + (3 + srvW) + (3 + cliW) + 2 + 6
  if need > w:
    # Squeeze the columns before dropping any of them: a narrow header that
    # still says all four things beats a wide one that says two.
    labelW = 14
    srvW = 16
    cliW = 14
  if result.width + 3 + labelW <= w:
    result.put "  "
    result.putIn ColDim, bxV()
    result.put " "
    result.putIn (if s.phase == phRun and s.who.len > 0: ColCyan else: ColDim),
                 fit(label, labelW)
  if result.width + 3 + srvW <= w:
    result.put " "
    result.putIn ColDim, bxV()
    result.put " "
    result.putIn s.srvCol, fit(s.srvText, srvW)
  if result.width + 3 + cliW <= w:
    result.put " "
    result.putIn ColDim, bxV()
    result.put " "
    result.putIn s.cliCol, fit(s.cliText, cliW)
  # Guarded rather than padded blindly: `padTo` cannot shorten, so a header that
  # has already run past `w - 10` would otherwise have the clock appended past
  # the right-hand edge and shear the frame.
  if result.width <= w - 10:
    result.padTo w - 10
    result.putIn ColDim, secsText(elapsed)

proc paneTitles(l: Logs; scrollS, scrollC: int; srv, cli: var string) =
  srv = "server  " & $l.server.lines.len & " lines" &
        (if scrollS > 0: "  back " & $scrollS else: "")
  if l.clientStarted:
    cli = "client  " & $l.client.lines.len & " lines" &
          (if scrollC > 0: "  back " & $scrollC else: "")
  else:
    cli = "client  not started yet -- last session's log"

proc profileLabel(p: Profile): string =
  result = (if p.nickname.len > 0: p.nickname else: "(no nickname)")
  var bits = ""
  if p.side.len > 0: bits = p.side
  if p.level > 0:
    if bits.len > 0: bits.add " "
    bits.add "level " & $p.level
  if bits.len > 0: result.add "  " & bits

proc profilePanel(s: Screen; width: int; rows, empty: var seq[Row];
                  title: var string) =
  ## Screen 1's panel, as data. THREE states, never two -- because "we have not
  ## looked yet" and "there are none" are different facts and the second one is
  ## the one that offers to create a profile. Collapsing them would put the
  ## create affordance in front of a player who already has characters, during
  ## the second or two before the list is read.
  rows = @[]
  empty = @[]
  let innerW = width - 6
  if not s.profilesKnown:
    title = "profiles"
    var r = newRow()
    r.put "  "
    r.putIn ColDim, fit("read once the server answers", innerW)
    rows.add r
    return

  if s.profiles.len == 0:
    # FIRST RUN. Not an empty box: the way forward, in words.
    title = "profiles -- none yet"
    var a = newRow()
    a.put "  "
    a.putIn ColYellow, fit("this install has no profiles yet", innerW)
    empty.add a
    var b = newRow()
    b.put "  "
    if s.canCreate:
      b.putIn ColDefault, fit("a character is created here before the game " &
                              "starts -- the launcher asked for a nickname " &
                              "and a side", innerW)
    else:
      # Say WHY rather than offer something that would then be refused.
      b.putIn ColRed, fit("and the backend's launcher routes are not " &
                          "reachable, so one cannot be created from here",
                          innerW)
    empty.add b
    if s.profileNote.len > 0:
      var c = newRow()
      c.put "  "
      c.putIn ColDim, fit(s.profileNote, innerW)
      empty.add c
    return

  title = "profiles -- " & $s.profiles.len
  for i in 0 ..< s.profiles.len:
    let p = s.profiles[i]
    var r = newRow()
    r.put "  "
    # The bound profile is MARKED. Without it the panel lists what exists and
    # says nothing about which one the game is about to start on, which is the
    # single thing the player is looking for.
    let mine = s.chosenId.len > 0 and p.id == s.chosenId
    r.putIn (if mine: ColGreen else: ColDim),
            (if mine: markGlyph(MarkActive) else: "  ")
    r.put " "
    r.putIn (if mine: ColCyan else: ColDefault),
            fit(profileLabel(p), (if innerW > 40: 34 else: 18))
    r.padTo (if innerW > 40: 40 else: 24)
    let room = width - r.width - 3
    if room > 8:
      r.putIn ColDim, fit((if mine: "playing this one -- " & p.id else: p.id),
                          room)
    rows.add r
  if s.profileNote.len > 0:
    var n = newRow()
    n.put "  "
    n.putIn ColDim, fit(s.profileNote, innerW)
    rows.add n

proc paintPhase(panel: var Panel; logs: var Logs; s: Screen;
                elapsed: int64): bool =
  ## SCREEN 1, repainted in place in the SCROLLBACK rather than on the alternate
  ## screen. That is deliberate and different from the live log view: what is
  ## immediately above this block is the preflight report about the player's
  ## install, which is the thing they will be asked to paste when something is
  ## wrong with it. The alternate screen would take it away and give it back;
  ## repainting in place leaves it, and leaves the finished progress behind in
  ## the scrollback too.
  ##
  ## `logs` is still pumped by the callers around this -- the tails are opened
  ## once, in `newLogs`, and stay open across both screens -- but screen 1 does
  ## not DRAW them. It draws the launch progress and the profile panel, and
  ## screen 2 gets the logs a moment later with the whole window to itself.
  ##
  ## Returns false when the screen cannot hold the block; the caller then writes
  ## its plain one-line-per-change progress instead. It never draws a bent frame
  ## and never silently drops a region.
  if termMode() != tmFull: return false
  var w = 0
  var h = 0
  termSize(w, h)
  if w <= 0: w = 100
  if h <= 0: h = 25
  if w > 160: w = 160
  # `Panel` repaints by walking the cursor up over its own last paint, so a
  # block as tall as the window scrolls and the paint then climbs the screen a
  # line per frame. Three rows are kept back, and the block is capped so a very
  # tall console does not hand the whole thing over to the boot view.
  var ph = h - 3
  if ph > 26: ph = 26
  let dw = w - 1
  var prof: seq[Row] = @[]
  var empty: seq[Row] = @[]
  var title = "profiles"
  profilePanel(s, dw, prof, empty, title)
  let lay = launcherRows(dw, ph, screenHeader(s, dw, elapsed),
                         screenSteps(s, dw), screenSummary(s, dw),
                         title, prof, empty, newRow())
  if not lay.renderable: return false
  # `usedRows`, not `rows.len`. The layout always returns a full window's worth
  # so a full-screen caller has every row; this one repaints a BLOCK in the
  # scrollback, and painting the trailing filler would push a screenful of
  # blank lines into the transcript on every tick -- and, worse, would make the
  # block taller than `fitsInWindow` needs it to be, which is what turns a
  # repaint into a paint that walks up the screen.
  var used: seq[Row] = @[]
  for i in 0 ..< lay.usedRows:
    used.add lay.rows[i]
  if not fitsInWindow(used.len): return false
  panel.paint used
  result = true

proc waitForBackend(port: int; tls: bool; backendProc: uint64;
                    limitSecs: int; logs: var Logs;
                    died, answered, probeBroken: var bool;
                    waitedMs: var int64) =
  ## Poll until the backend is ready, showing its own progress -- and both logs
  ## -- while it does.
  ##
  ## READINESS IS A SOCKET, NOT A SENTENCE. In plain mode it is a request coming
  ## back -- an answer beats a corpse, a dead process is not waited for. In TLS
  ## mode the launcher cannot open a TLS request, so it used to accept the
  ## backend's own `listening on ...` line in the log INSTEAD. That is the bug
  ## in `rotateServerLog`: the log on disk is the previous run's until the new
  ## backend truncates it, and this loop's first pump reads it whole. The
  ## launcher then declared the server ready ~2 s in and started the client
  ## nearly four seconds before anything was listening.
  ##
  ## So TLS readiness is now BOTH, and the socket is the one that can refuse:
  ##
  ##   * `aowlsession.connects(port)` -- a real TCP connect, closed at once. A
  ##     bind without a listen (which is what the backend holds for the first
  ##     seconds of startup) refuses it, so a success means `listen(2)` has
  ##     happened. Nothing about it can be stale.
  ##   * the `listening on` line, but ONLY when `logs.serverFresh` says the file
  ##     is this run's. When the rotation failed the line is ignored entirely
  ##     and the connect stands alone.
  ##
  ## `waitedMs` comes back with how long that took, so the launcher can say the
  ## measured number rather than "the backend is ready".
  died = false
  answered = false
  probeBroken = false
  var s = newScreen()
  s.phase = phBoot
  s.port = port
  s.tlsMode = tls
  s.srvText = "server starting"
  s.srvCol = ColYellow
  s.cliText = "client not started"
  s.cliCol = ColDim
  let began = cNowMs()
  var panel = newPanel()
  var painting = termMode() == tmFull
  var saidDegraded = false
  var lastNote = 0'i64
  var lastPaint = -1000'i64

  while true:
    let waited = cNowMs() - began
    if limitSecs > 0 and waited >= int64(limitSecs) * 1000'i64:
      break
    # BOTH logs, not just the backend's. The client pane is showing the previous
    # session at this point and its title says so, but the tail has to be kept
    # current from here so that the moment the injected host truncates the file
    # the pane empties and refills with this run.
    pumpBoth(logs)
    if tls:
      # The socket first, and on its own terms. `connects` sends nothing, so it
      # costs a loopback SYN against a TLS listener rather than the 15 s
      # receive timeout `answers` would pay there.
      let c = connects(port)
      if c < 0:
        probeBroken = true
      else:
        # The log line is a CORROBORATION, never the whole verdict, and only
        # when the file is known to be this run's. `serverFresh` false means the
        # previous log could not be moved aside, in which case anything in it
        # may predate this process by a whole session.
        let b = scanBoot(logs.server)
        let said = logs.serverFresh and b.listening
        if c == 1 and (said or not logs.serverFresh):
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

    s.boot = scanBoot(logs.server)
    s.answered = answered
    if answered:
      s.srvText = "server ready"
      s.srvCol = ColGreen
    elif died:
      s.srvText = "server exited"
      s.srvCol = ColRed

    if painting:
      if waited - lastPaint >= 100'i64 or answered or died or probeBroken:
        lastPaint = waited
        if not paintPhase(panel, logs, s, waited):
          # Said out loud, once. A view that quietly becomes a different view is
          # the failure this file is written against: the reader would see plain
          # lines and have no way to tell whether the launcher chose them or the
          # fancy view had crashed.
          painting = false
          if not saidDegraded:
            saidDegraded = true
            warn "this window cannot hold the launch view and both log " &
                 "panes at once; reporting progress as plain lines instead"
            flushOut()
    if not painting:
      # The redirected case, and the too-small case. The only useful thing to
      # write is a line whenever something changed.
      if waited - lastNote >= 5000'i64:
        lastNote = waited
        var kind = MarkActive
        line "  " & secsText(waited) & " -- " & progressText(s, kind)
        flushOut()

    if answered or died or probeBroken:
      break
    if interrupted():
      break
    sleepMs 120

  waitedMs = cNowMs() - began

  if painting:
    # One last paint so the finished state is what is left in the scrollback,
    # then let ordinary output carry on underneath it.
    pumpBoth(logs)
    s.boot = scanBoot(logs.server)
    s.answered = answered
    discard paintPhase(panel, logs, s, cNowMs() - began)
    panel.settle()

# ---------------------------------------------------------------------------
# Choosing a profile
# ---------------------------------------------------------------------------

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

proc createProfileChecked(port: int; root, nickname, side: string;
                          made: var Profile): string =
  ## `createProfile`, and then the check that makes its answer mean something.
  ## Returns "" only when a profile provably exists afterwards.
  ##
  ## A backend started against a missing or empty database comes up perfectly:
  ## it claims its port, loads all sixteen mods, and answers 200 on every route
  ## while serving nothing at all. Against that install `create` returns a
  ## well-formed `{"ok":true,"token":...}` and the launcher would print
  ## "created" for a character that does not exist -- and the player would find
  ## out at the game's login screen, a long way from here.
  ##
  ## So the server's answer is NOT the evidence. The finished state is: ask for
  ## the profile list again and require the new id to be IN it. That is a check
  ## that can fail, which is the entire reason it is worth writing; "the route
  ## said ok" is a check that cannot.
  let e = createProfile(port, nickname, side, made)
  if e.len > 0: return e
  if made.id.len == 0:
    return "the profile-create route reported success and named no profile"
  let after = listProfiles(port, root)
  if after.error.len > 0:
    return "the profile was created, but the list could not be read back to " &
           "confirm it, so whether it exists is UNKNOWN: " & after.error
  if after.source != psRoute:
    return "the profile was created, but the list read back came off disk " &
           "rather than from the backend, so it cannot confirm it. Whether " &
           "the profile exists is UNKNOWN."
  for p in after.items:
    if p.id == made.id:
      # The row the LIST serves wins over the one `create` echoed: it is the
      # one every later request will be answered from.
      if p.nickname.len > 0: made.nickname = p.nickname
      if p.side.len > 0: made.side = p.side
      if p.level > 0: made.level = p.level
      return ""
  result = "the backend answered 200 with a token for \"" & nickname &
           "\", but the profile list it serves does NOT contain " & made.id &
           ", so NOTHING was created. A backend running against a missing or " &
           "empty database behaves exactly like this -- it answers everywhere " &
           "and stores nothing. Check aowlspt-backend.log, and check that " &
           "db.json is where the backend expects it."

proc firstRunCreate(port: int; root: string; list: ProfileList;
                    chosen: var Profile; reason: var string): bool =
  ## The FIRST-RUN path: this install has no profiles, so offer to make one.
  ##
  ## This is not the profile prompt that was deliberately removed. That prompt
  ## was removed because it DUPLICATED the game's own character-select screen --
  ## the player chose in the console and then chose again in the game. With
  ## zero profiles there is nothing to duplicate: the game's screen has no slot
  ## to offer, and the alternative here is to launch with no `-token`, which is
  ## the launcher's one remaining dead end. So this asks only in the case where
  ## nobody was going to be asked anything at all, and it never runs when the
  ## install already has a character.
  reason = ""
  if list.source != psRoute or port <= 0:
    reason = "there are no profiles and the backend's launcher routes are " &
             "not reachable, so one cannot be created from here"
    return false
  if not stdinIsConsole():
    # A scripted launch is not somewhere to invent a character name.
    reason = "there are no profiles and input is not a terminal, so there is " &
             "nobody to ask for a nickname. Pass --new <name> to create one"
    return false

  echo ""
  sayColoured ColWhite, "  No profiles yet"
  sayColoured ColDim,
    "  this install has no characters. One is created here, before the " &
    "game starts."
  while true:
    var answer = ""
    if not readAnswer("create one now? [Y/n]", answer):
      reason = "input ended before a profile was created"
      return false
    if answer == "n" or answer == "N":
      reason = "you chose not to create a profile"
      return false
    if answer.len == 0 or answer == "y" or answer == "Y": break
  while true:
    var nick = ""
    if not readAnswer("nickname:", nick):
      reason = "input ended before a nickname was given"
      return false
    if nick.len < 3:
      err "a nickname needs at least three characters"
      continue
    var sideAnswer = ""
    if not readAnswer("side? [Usec/Bear]", sideAnswer):
      reason = "input ended before a side was chosen"
      return false
    var side = "Usec"
    if toLowerAscii(sideAnswer) == "bear" or toLowerAscii(sideAnswer) == "b":
      side = "Bear"
    var made = Profile(id: "", token: "", nickname: "", side: "", level: 0,
                       edition: "", lastPlayed: 0)
    let e = createProfileChecked(port, root, nick, side, made)
    if e.len > 0:
      err e
      # Retrying a nickname clash is worth it; retrying an empty database is
      # not, and the player is told which of the two this was.
      continue
    chosen = made
    ok "created " & profileLabel(made) & " (" & made.id &
       ") -- confirmed present in the backend's profile list"
    return true

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

  var list = listProfiles(port, root)
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
    let err = createProfileChecked(port, root, o.newProfile, o.side, made)
    if err.len > 0:
      reason = err
      return false
    chosen = made
    ok "created " & profileLabel(made) & " (" & made.id &
       ") -- confirmed present in the backend's profile list"
    return true

  drawProfiles(list)
  if list.source == psStore:
    sayColoured ColDim,
      "  this list came off disk, so `new` is not available here"

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
      prompt.add "  (n = new, q = quit)"
    else:
      prompt.add "  (q = quit)"
    var answer = ""
    if not readAnswer(prompt, answer):
      reason = "input ended before a profile was chosen"
      return false
    if answer == "q" or answer == "Q":
      reason = "you chose to quit"
      return false
    if (answer == "n" or answer == "N") and list.source == psRoute:
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
      let e = createProfileChecked(port, root, nick, side, made)
      if e.len > 0:
        err e
        continue
      chosen = made
      ok "created " & profileLabel(made) & " (" & made.id &
         ") -- confirmed present in the backend's profile list"
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

proc watchClient(launch: LaunchPtr; logs: var Logs; who: string;
                 profiles: seq[Profile]; chosenId: string;
                 limitMs: int64; exited: var bool) =
  ## Until the host says it is running, or the client dies, or the time is up.
  ## Whichever happens, the last thing painted is what actually happened.
  ##
  ## This is still SCREEN 1: the client's progress steps above the profile
  ## panel, with the profile that was bound marked in it. `logs` is pumped
  ## every tick so that screen 2 -- which takes over the moment this returns --
  ## opens with the whole history already read, rather than re-opening the
  ## files and re-parsing from zero.
  exited = false
  var s = newScreen()
  s.phase = phClient
  s.who = who
  s.profilesKnown = true
  s.profiles = profiles
  s.chosenId = chosenId
  s.pid = int(cLaunchPid(launch))
  s.srvText = "server up"
  s.srvCol = ColGreen
  let began = cNowMs()
  var panel = newPanel()
  var painting = termMode() == tmFull
  var saidDegraded = false
  var lastNote = 0'i64

  while true:
    let waited = cNowMs() - began
    pumpBoth(logs)
    s.host = scanHost(logs.client)
    let alive = cLaunchAlive(launch) != 0'i32
    s.alive = alive
    s.cliText = (if alive: "client up" else: "client exited")
    s.cliCol = (if alive: ColGreen else: ColRed)
    if not alive: exited = true
    if painting:
      if not paintPhase(panel, logs, s, waited):
        painting = false
        if not saidDegraded:
          saidDegraded = true
          warn "this window cannot hold the launch view and the profile " &
               "panel; reporting progress as plain lines instead"
          flushOut()
    if not painting:
      if waited - lastNote >= 5000'i64:
        lastNote = waited
        var kind = MarkActive
        line "  " & secsText(waited) & " -- " & progressText(s, kind)
        flushOut()
    if s.host.running or exited or waited >= limitMs:
      if painting:
        discard paintPhase(panel, logs, s, waited)
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

proc streamLogs(logs: var Logs; backendProc: uint64;
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
    pumpBoth(logs)
    # Both tails may have been read for minutes already by the boot and client
    # phases -- they are the SAME tails. Starting from zero here is what makes
    # the handover seamless rather than a replay: the counters begin at whatever
    # has not been printed to this stream yet.
    if seenServer > logs.server.lines.len: seenServer = 0
    if seenClient > logs.client.lines.len: seenClient = 0
    while seenServer < logs.server.lines.len:
      let l = logs.server.lines[seenServer]
      inc seenServer
      sayColoured levelOf(l.level), streamText("server", l)
    while seenClient < logs.client.lines.len:
      let l = logs.client.lines[seenClient]
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

proc runLogView(who: string; backendProc: uint64; launch: LaunchPtr;
                owned: bool; logs: var Logs;
                summaryKind: int; summaryText: string; detached: var bool) =
  ## The same one screen the boot and client phases painted, now full screen and
  ## with the keys live: the launch collapsed to its one summary line at the
  ## top, both panes underneath. Runs until `q` or `d` or Ctrl+C, or until both
  ## processes are gone. `detached` says which: on `d` the backend is left
  ## running.
  detached = false

  var w = 0
  var h = 0
  termSize(w, h)
  if termMode() != tmFull or not stdinIsConsole() or
     w < MinCols + 1 or h < MinRows:
    if termMode() == tmFull and stdinIsConsole():
      warn "the window is " & $w & "x" & $h & ", which is too small for the " &
           "split view; falling back to one line per entry"
    streamLogs(logs, backendProc, launch, stdinIsConsole(), owned)
    return

  var s = newScreen()
  s.phase = phRun
  s.who = who
  s.summaryKind = summaryKind
  s.summaryText = summaryText

  var focus = 0        ## 0 server, 1 client
  var solo = false
  var paused = false
  var confirmQuit = false
  var scrollServer = 0
  var scrollClient = 0
  var bodyH = 3
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
    let dw = w - 1
    pumpBoth(logs)
    if not paused:
      scrollServer = 0
      scrollClient = 0

    let clientAlive = launch != nil and cLaunchAlive(launch) != 0'i32
    # Through the watchdog when owned: this poll is what restarts a dead backend.
    let backendAlive = wdBackendAlive(backendProc, owned, clientAlive)

    if gWd.givenUp:
      s.srvCol = ColRed
      s.srvText = "SERVER DOWN"
    elif not backendAlive:
      s.srvCol = ColRed
      s.srvText = "server down"
    elif gWd.active and gWd.restarts > 0:
      s.srvCol = ColYellow
      s.srvText = "server up (restarted x" & $gWd.restarts & ")"
    else:
      s.srvCol = ColGreen
      s.srvText = "server up"
    s.cliCol = (if clientAlive: ColGreen else: ColRed)
    s.cliText = (if clientAlive: "client up" else: "client exited")

    var help = newRow()
    help.put "  "
    if gWd.givenUp:
      # The hard, user-facing error. The backend is gone for good and the game
      # cannot reach its server; say so loudly and say what to do, rather than
      # leave the player staring at a frozen game.
      help.putIn ColRed, fit(
        "BACKEND DOWN -- the game cannot reach its server on 127.0.0.1:" &
        $gWd.port & " and auto-restart gave up. See the server pane / " &
        "aowlspt-backend.log. Press q to quit and relaunch.", dw - 2)
    elif confirmQuit:
      help.putIn ColYellow, fit(
        "the game is still running and will lose its server -- q again to " &
        "stop it anyway, d to leave everything running, any other key to stay",
        dw - 2)
    else:
      # `fit` rather than a bare string: at 40 columns the full reminder is
      # nearly twice the width of the window, and a status line that wraps
      # scrolls the whole frame by a row every frame.
      help.putIn ColDim, fit("q quit   d detach   tab swap   f full   space " &
                             (if paused: "follow" else: "pause") &
                             "   pgup/pgdn scroll", dw - 2)
      if paused and help.width + 9 < dw:
        help.put "   "
        help.putIn ColYellow, "paused"

    var srv = ""
    var cli = ""
    paneTitles(logs, scrollServer, scrollClient, srv, cli)
    let lay = logViewRows(dw, h, screenHeader(s, dw, cNowMs() - began),
                          screenSummary(s, dw),
                          logs.server, logs.client, srv, cli,
                          focus, scrollServer, scrollClient, solo, help)
    if not lay.renderable:
      # Resized under us into something that cannot hold the view. Leave
      # cleanly rather than draw a broken frame, and say which it was.
      rawMode false
      leaveFullScreen()
      warn lay.note
      streamLogs(logs, backendProc, launch, true, owned)
      return
    bodyH = lay.bodyH

    var f = newFrame(w, h)
    for r in lay.rows:
      f.addRow r
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
        if focus == 0: scrollServer = logs.server.lines.len
        else: scrollClient = logs.client.lines.len
      elif k == KeyEnd:
        paused = false
        scrollServer = 0
        scrollClient = 0
      else:
        confirmQuit = false
    if acted:
      # Clamp after the fact rather than in every branch above.
      if scrollServer > logs.server.lines.len: scrollServer = logs.server.lines.len
      if scrollClient > logs.client.lines.len: scrollClient = logs.client.lines.len

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

# ---------------------------------------------------------------------------
# Compiling the mods folder at startup
# ---------------------------------------------------------------------------
#
# THE REQUIREMENT: the user's mods folder ships as SOURCE and is compiled on
# startup, cached so an unchanged folder costs about a second.
#
# `tools/modbuild.py` is the compile-and-cache half and
# `host/Aowlspt.Host.Il2Cpp/modload.nim` is the in-game screen half. Until now
# NOTHING JOINED THEM. A grep of this file for `modbuild` returned zero hits,
# so on a real launch the file the host renders was only ever written by hand
# or by `tools/modloadsim.py`, the synthetic driver. The host side is verified
# live; this side had never run at all.
#
# What happens now, in order:
#
#   1. the screen file is written SYNCHRONOUSLY, here, in its "queued" state,
#      BEFORE the client process exists. That is not cosmetic. The file
#      survives a reboot, so LAST session's `MODS READY` is sitting in it, and
#      the host acts on that word: it would release the mods and dismiss the
#      step for a build that has not started. Overwriting it first is what
#      makes that race unlosable rather than merely unlikely.
#   2. the builder is spawned quiet and is NOT waited for. The host defers
#      loading mods until the file says READY (`modLoadReleaseMods`), so the
#      compile OVERLAPS the client's own 10-60s startup instead of being added
#      to it. That overlap is the whole reason the loading step exists.
#   3. if no builder can be found, the file is written with the "not built"
#      state -- which still carries `MODS READY`, so the host stops waiting,
#      and says on its other two lines that nothing was rebuilt. The launcher
#      warns with the full reason. A silent skip would leave the host waiting
#      out its entire defer deadline for a build nobody started.
#
# ## The Python gap, stated plainly rather than papered over
#
# `modbuild.py` is Python, and `tools/toolchain.py` packs gcc, lld and nimony
# but NOT an interpreter. On a machine with no Python this resolves nothing and
# takes path 3 above: it launches, it says so, and it compiles nothing. That is
# a real hole in the public-install story, it is NOT fixed here, and it is why
# the resolution order below has a slot for a native `aowlspt-modbuild.exe` and
# a slot for an interpreter bundled in the install's own toolchain. Being loud
# about the hole beats a launcher that quietly never compiles anything.

const
  # The three-line format lives in `tools/modloadfmt.py`, which is the ONE
  # renderer the two Python writers share. This writer cannot import it, so
  # these literals are asserted against it by `tools/test_modloadfmt.py` --
  # a format that drifts silently is a loading screen that lies.
  MlQueued0 = "Loading mods..."
  MlQueued1 = "Mods 0 of ?"
  MlQueued2 = "starting the compiler"
  MlNotBuilt0 = "MODS READY"
  MlNotBuilt1 = "Mods not rebuilt"

type
  ModBuilder = object
    exe: string
      ## Empty when none was found; `why` then says what was looked for.
    args: string
    source: string
    why: string

proc modScreenPath(root: string): string =
  joinPath(root, "aowlspt\\aowlspt-modload.txt")

proc modProgressPath(root: string): string =
  joinPath(root, "aowlspt\\aowlspt-modbuild.jsonl")

proc mlWriteScreen(path, l0, l1, l2: string) =
  ## Exactly three lines, LF. `writeTextFile` replaces the whole file; the host
  ## reads it from another process every poll, and half a line on a loading
  ## screen reads as corruption rather than as progress. Both calls below
  ## happen before the client process exists, so the brief window in which
  ## `writeTextFile` has removed the old file and not yet written the new one
  ## is not observable by anything.
  discard writeTextFile(path, l0 & "\n" & l1 & "\n" & l2 & "\n")

proc quoteArg(s: string): string =
  "\"" & s & "\""

proc lookOnPath(exeName: string): string =
  ## The first `exeName` on PATH, or "". `CreateProcessA` is given an explicit
  ## application name, so it does NOT search PATH itself -- an unresolved name
  ## would simply fail to start with no useful error, which is the failure this
  ## avoids by finding out here and saying so.
  result = ""
  let p = getEnv("PATH", "")
  var cur = ""
  var i = 0
  while i <= p.len:
    let atEnd = i == p.len
    var ch = ';'
    if not atEnd: ch = p[i]
    if ch == ';':
      if cur.len > 0:
        var d = cur
        # PATH entries are allowed to be quoted, and a quoted one joined
        # straight onto a file name produces a path that exists nowhere.
        if d.len >= 2 and d[0] == '"' and d[d.len - 1] == '"':
          d = d.substr(1, d.len - 2)
        let cand = joinPath(d, exeName)
        if fileExists(cand):
          return cand
      cur = ""
    else:
      cur.add ch
    inc i

proc resolveModBuilder(root, override: string): ModBuilder =
  ## Four ways to find a builder, most specific first. Every one of them is
  ## reported by name in `source`, because two machines silently compiling with
  ## different tools is the class of problem that cannot be debugged afterwards.
  result = ModBuilder(exe: "", args: "", source: "", why: "")
  let inst = joinPath(root, "aowlspt")
  let mods = joinPath(inst, "mods")
  let screen = modScreenPath(root)
  let prog = modProgressPath(root)

  var script = ""
  if override.len > 0:
    if endsWith(toLowerAscii(override), ".exe"):
      if not fileExists(override):
        result.why = "--modbuild " & override & " does not exist"
        return
      result.exe = override
      result.source = "--modbuild (a native builder)"
      result.args = ""
    else:
      if not fileExists(override):
        result.why = "--modbuild " & override & " does not exist"
        return
      script = override
  else:
    # A native builder, if one is ever produced. Preferred because it needs no
    # interpreter at all, which is the gap described above.
    let native = joinPath(inst, "aowlspt-modbuild.exe")
    if fileExists(native):
      result.exe = native
      result.source = "the install's own aowlspt-modbuild.exe"
      result.args = ""
    else:
      script = joinPath(inst, "tools\\modbuild.py")
      if not fileExists(script):
        result.why = "no aowlspt-modbuild.exe and no tools\\modbuild.py in " &
                     inst & ", and no --modbuild was given"
        return

  if result.exe.len == 0:
    # A script needs an interpreter: the install's bundled one first, then
    # whatever is on PATH. A developer machine has the second; a player's
    # machine currently has NEITHER, and that is the gap.
    let bundled = joinPath(inst, "toolchain\\python\\python.exe")
    if fileExists(bundled):
      result.exe = bundled
      result.source = "the install's bundled interpreter + " & script
    else:
      let onPath = lookOnPath("python.exe")
      if onPath.len > 0:
        result.exe = onPath
        result.source = "python on PATH (" & onPath & ") + " & script
      else:
        result.why = "found " & script & " but no interpreter to run it " &
                     "with: there is no toolchain\\python\\python.exe in " &
                     inst & " and no python.exe on PATH. tools\\toolchain.py " &
                     "packs gcc, lld and nimony but NOT an interpreter, so " &
                     "this is expected on a machine that has never had " &
                     "Python -- and it means the mods folder is NOT compiled."
        return
    result.args = quoteArg(script) & " "

  result.args = result.args & "--mods " & quoteArg(mods) &
                " --install " & quoteArg(inst) &
                " --screen " & quoteArg(screen) &
                " --progress " & quoteArg(prog)

proc modBuildCommand(b: ModBuilder): string =
  result = quoteArg(b.exe)
  if b.args.len > 0:
    result = result & " " & b.args

proc startModBuild(root: string; b: ModBuilder; force: bool): uint64 =
  ## Write the opening state, then spawn. In that order, always: see (1) above.
  result = 0'u64
  let screen = modScreenPath(root)
  mlWriteScreen(screen, MlQueued0, MlQueued1, MlQueued2)
  var cmd = modBuildCommand(b)
  if force: cmd = cmd & " --force"
  var e = b.exe
  var w = joinPath(root, "aowlspt")
  result = cSpawnQuiet(toCString(e), toCString(w), toCString(cmd))

proc modBuildDeclined(root, why: string) =
  ## No builder. Say so on the screen the player is looking at AND in the
  ## console, and let the host get on with loading what is already on disk.
  mlWriteScreen(modScreenPath(root), MlNotBuilt0, MlNotBuilt1,
                "no compiler in this install")
  warn "the mods folder was NOT compiled: " & why
  note "the host will load whatever .dll files are already under " &
       joinPath(root, "aowlspt\\mods") & ". Nothing claims a build happened."

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
    echo ""
    echo "Mod arguments this build's registry knows about:"
    for line in modArgsFromRegistry(o.root):
      echo line
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

  # The two logs are opened ONCE, here, and every phase below shares them: the
  # backend wait, the client wait and the live view. Opening them per phase was
  # what made the launch view single-source -- the boot view had only the
  # backend's log in hand and so could not show the client's, which is the whole
  # reason there used to be two screens.
  var logs = newLogs(root)

  # `--ready-probe`: answer "is a backend ready on this port, right now" and
  # exit. BEFORE the install preflight on purpose -- the probe reads a log and
  # opens a socket, and refusing it because the scratch tree has no
  # EscapeFromTarkov.exe in it would make the readiness rule untestable
  # anywhere except a full install.
  #
  # It answers with the same two facts `waitForBackend` decides on, and gives
  # the SOCKET the casting vote, so the case this whole change is about -- a
  # stale `aowlspt-backend.log` from the previous run saying `listening on`
  # while nothing is listening -- comes back NOT READY.
  # `tools/test_startup_race.py` drives exactly that, and drives the positive
  # control too: the same stale log WITH a real listener must come back READY,
  # or the check would be one that cannot fail.
  if o.readyProbe:
    let probePort = if o.portGiven: o.port else: 443
    heading "Readiness probe"
    discard logs.server.pump()
    let b = scanBoot(logs.server)
    let tcp = connects(probePort)
    line "  log says listening   " & (if b.listening: "yes" else: "no")
    line "  tcp accepts          " &
         (if tcp == 1: "yes" elif tcp == 0: "no" else: "cannot ask")
    if tcp < 0:
      warn "INCONCLUSIVE: winsock could not be loaded, so nothing was " &
           "probed. That is not a pass."
      return 4
    if tcp == 1:
      ok "READY: 127.0.0.1:" & $probePort & " accepted a connection"
      return 0
    err "NOT READY: nothing accepted a connection on 127.0.0.1:" &
        $probePort &
        (if b.listening:
           ", and the `listening on` line in the backend log is therefore " &
           "from an EARLIER run"
         else: "")
    return 3

  let exePath = joinPath(root, o.exeName)
  let hostDll = joinPath(root, "aowlspt\\aowlspt-host-il2cpp.dll")

  banner(root)

  if o.logsOnly:
    # Before every check below it, on purpose. `--logs` is what somebody runs
    # when a session is already going wrong, and refusing to show them the logs
    # because the install looks odd would withhold the one thing that says why.
    var detachedOnly = false
    # Attached, not launched: the progress line says exactly that rather than
    # claiming a launch this process did not perform.
    logs.clientStarted = true
    runLogView("", 0'u64, nil, false, logs, MarkPending,
               "attached to a session this launcher did not start", detachedOnly)
    termShutdown()
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
    # THE MOD BUILD, reported with the exact command a real launch would run.
    # The dry run and the launch call `resolveModBuilder` and
    # `modBuildCommand` -- the same two procs -- so what is printed here
    # cannot drift from what is executed. A dry run that describes a
    # different command from the one that runs is worse than no dry run.
    if o.noModBuild:
      line "  would build   no mods (--no-mod-build); the host loads the " &
           ".dll files already under aowlspt\\mods"
    else:
      let db = resolveModBuilder(root, o.modBuild)
      if db.exe.len == 0:
        line "  would build   NOTHING -- " & db.why
        line "  would write   " & modScreenPath(root) & "  (\"" &
             MlNotBuilt0 & "\" / \"" & MlNotBuilt1 & "\", so the host stops " &
             "waiting and nothing claims a build happened)"
      else:
        line "  would build   the mods folder via " & db.source
        line "  would run     " & modBuildCommand(db) &
             (if o.modBuildForce: " --force" else: "")
        line "  would write   " & modScreenPath(root) & "  (\"" &
             MlQueued0 & "\" first, then the builder's own progress, ending " &
             "in \"MODS READY\")"
    let dExplicit = o.profileId.len > 0 or o.newProfile.len > 0
    let dAuto = not o.pick and not dExplicit
    # The profile routes go to the CONTROL port, never to `port`. In a dry run
    # nothing has been started, so this ordinarily reports no control port --
    # which is the truth about this moment, not a failure.
    var dWhyCtl = ""
    let dCtl = controlPort(root, dWhyCtl)
    line "  control port  " & (if dCtl > 0: $dCtl else: "none") & " -- " & dWhyCtl
    if dAuto:
      line "  would ask     nothing"
      let l = listProfiles(dCtl, root)
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
    else:
      let l = listProfiles(dCtl, root)
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
    # THE AUTO-ENTER DECISION, from the same `o.autoEnter` the real run
    # branches on, so the plan cannot describe a different launcher from the
    # one that executes. It is here because the traffic it decides is not
    # local to the launcher: it is writes into the ONE inspector command file
    # that every other tool shares.
    if o.autoEnter:
      line "  would enter   character-select itself (--auto-enter): " &
           "read-only roots/children polls on aowlspt-inspect.txt until the " &
           "screen exists, then an `allow write` batch to confirm it is up " &
           "and one to press it. The command file is blanked afterwards."
    else:
      line "  would enter   nothing, and would write NOTHING to " &
           "aowlspt-inspect.txt -- the host answers character-select " &
           "natively (uxSkipModeScreen, modeskip.nim). Pass --auto-enter to " &
           "drive it from the launcher instead."
    line "  nothing was started."
    return 0

  # --- the mod build ---------------------------------------------------------
  #
  # Started HERE, before the backend, because it is the longest-running thing
  # in the launch and it blocks nothing: it compiles into the mods folder while
  # the backend boots and the client loads, and the host holds mod loading
  # until it reports READY. Started after the client instead, it would be
  # serialised behind a 10-60s startup for no reason.
  var modBuildProc = 0'u64
  block:
    heading "Mods"
    if o.noModBuild:
      note "--no-mod-build: the mods folder will NOT be compiled. The host " &
           "loads the .dll files already under " &
           joinPath(root, "aowlspt\\mods") & "."
      # The stale-READY hazard applies here too: last session's marker is
      # still in the file and the host would act on it. Say the true thing
      # instead of leaving the old one to be read as this run's.
      mlWriteScreen(modScreenPath(root), MlNotBuilt0, MlNotBuilt1,
                    "--no-mod-build was given")
    else:
      let b = resolveModBuilder(root, o.modBuild)
      if b.exe.len == 0:
        modBuildDeclined(root, b.why)
      else:
        line "  " & b.source
        modBuildProc = startModBuild(root, b, o.modBuildForce)
        if modBuildProc == 0'u64:
          # CreateProcess refused. Not a warning that scrolls past: the screen
          # file currently says "Loading mods..." and would sit there until the
          # host's deadline, so it is corrected to the truth immediately.
          modBuildDeclined(root, "the builder could not be started: " &
                                 modBuildCommand(b))
        else:
          # Not `ok`, and not "built". All that is known is that a process
          # started. What it did is reported by the file it writes and by its
          # own progress log -- claiming more here would be the same mistake
          # the backend spawn line documents just below.
          line "  spawned the mod build; it writes " & modScreenPath(root) &
               " and the game shows it as a loading step"

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
      # BEFORE the spawn, not after. See `rotateServerLog`: after the spawn
      # there is a window in which the file on disk is still the last run's and
      # this launcher is already reading it for the word `listening`.
      let rotated = rotateServerLog(root, logs)
      if not rotated:
        warn "could not move the previous " &
             joinPath(root, "aowlspt\\aowlspt-backend.log") &
             " aside, so nothing in it can be trusted to be from this run. " &
             "Readiness will be decided by a TCP connect alone."
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
        var waitedMs = 0'i64
        waitForBackend(port, https, backendProc, o.backendWait, logs,
                       died, answered, probeBroken, waitedMs)
        if died:
          err "the backend exited while starting; see " &
              joinPath(root, "aowlspt\\aowlspt-backend.log")
          return 1
        if probeBroken:
          warn "could not open a socket to ask the backend anything, so " &
               "whether it is ready could not be checked. Starting the " &
               "client anyway."
        elif answered:
          # The MEASURED wait, in the line, every launch. A launcher that says
          # "ready" without it cannot be told apart from one that believed a
          # stale log -- which is exactly what it was doing.
          if https:
            ok "the backend accepted a TCP connection on 127.0.0.1:" & $port &
               " after " & $waitedMs & " ms" &
               (if logs.serverFresh: " (and this run's log says listening)"
                else: " (its log could not be rotated, so only the socket was " &
                      "trusted)")
          else:
            ok "the backend is answering on 127.0.0.1:" & $port & " after " &
               $waitedMs & " ms"
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
  let autoSelect = not o.pick and not explicitProfile
  heading "Profile"
  # The launcher's own routes go to the CONTROL port, which is the backend's
  # plain-HTTP listener -- never to `port`, which in a real launch is TLS on 443
  # and which this plain-only HTTP client cannot speak to at all. That is not a
  # timeout and not a race: connecting to the TLS port succeeds and then loses
  # the connection, every time, because the server is waiting for a ClientHello
  # this client will never send. The port is not guessed; the backend publishes
  # the one it actually bound and `controlPort` probes it before believing it.
  var whyCtl = ""
  let ctlPort = controlPort(root, whyCtl)
  if ctlPort > 0:
    line "  " & whyCtl
  else:
    # Said ONCE, here, before anything is offered -- so that what follows never
    # advertises a thing it will then refuse. The profile list still works off
    # the store on disk; creating one does not.
    warn whyCtl
    note "so profiles are read from the store on disk and none can be " &
         "created from here. Every launcher route (list, create, select) " &
         "needs that plain-HTTP port."
  var chosen = Profile(id: "", token: "", nickname: "", side: "", level: 0,
                       edition: "", lastPlayed: 0)
  var haveChoice = false
  var viaRoute = false
  var why = ""
  # Carried into screen 1 so its panel lists what this install actually holds,
  # with the bound one marked. Empty is a legitimate value and means the panel
  # draws the first-run text rather than an empty box.
  var knownProfiles: seq[Profile] = @[]
  if autoSelect:
    let list = listProfiles(ctlPort, root)
    viaRoute = list.source == psRoute
    knownProfiles = list.items
    if list.error.len > 0:
      # Not fatal: a backend with no profile route and no store on disk is an
      # install with nothing to select, which is the first-run case.
      warn list.error
      note "nothing to select, so the client starts with no -token and the " &
           "game's own character-creation flow runs"
    elif list.items.len == 0:
      # FIRST RUN. Everything else in this branch deliberately does not ask --
      # the in-game selector is the one place a profile is chosen. But with no
      # profiles there is no in-game selector to defer to and nothing to bind,
      # and launching tokenless is the dead end this case always was. So this
      # is the one case that asks.
      if list.note.len > 0: warn list.note
      var reason = ""
      if firstRunCreate(ctlPort, root, list, chosen, reason):
        haveChoice = true
        viaRoute = true
        knownProfiles = @[chosen]
      else:
        note reason & ", so the client starts with no -token and the game's " &
             "own character-creation flow runs"
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
    if pickProfile(o, ctlPort, root, chosen, why, viaRoute):
      haveChoice = true
    else:
      err "no profile to play: " & why
      note "the client needs a -token to log in, and a made-up one is a " &
           "session the server has never heard of -- the game would reach the " &
           "menu and stay there. Pass --profile <id>, or --new <name> to " &
           "create one."
      if backendProc != 0'u64:
        cSpawnKill(backendProc)
        line "  backend stopped"
      return 1

  # `--pick`/`--profile`/`--new` do not hand back the list they worked from, so
  # screen 1's panel shows the profile that was actually bound rather than
  # nothing. One true row beats a list this code would have to guess at.
  if knownProfiles.len == 0 and haveChoice:
    knownProfiles = @[chosen]

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
      let se = selectProfile(ctlPort, chosen.id, bound)
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
  if o.lowRender:
    note "--low-render: asking the client for a " & $o.renderW & "x" &
         $o.renderH & " window (-screen-width/-screen-height, " &
         "-screen-fullscreen 0, -popupwindow). This is NOT headless -- the " &
         "renderer runs, the window is visible, and there is no frame cap."
    if o.noGraphics:
      warn "--nographics-anyway: also passing -batchmode -nographics. This " &
           "has never been observed to boot this client. If the game exits " &
           "immediately or never reaches the menu, that is why."
  # THE DLSS STEP, and it MUST be here -- before the process exists.
  # `nvngx_dlss.dll` is opened by the client and is listed IsCritical in the
  # consistency manifest, and OptiScaler reads its ini at attach; neither can
  # be changed once the game is running. `tools/aowldlss.nim` says what it did,
  # or says plainly that it was skipped, and never aborts the launch.
  dlssPreLaunch(root)

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
  # From here the client pane is this run's log: the injected host truncates the
  # file as it opens it, and `Tail.pump` clears its lines when it sees the
  # reset. Before this point the pane holds the PREVIOUS session and its title
  # says so.
  logs.clientStarted = true

  if cLaunchResume(launch) == 0'i32:
    err "could not resume the client (error " & $int(cLaunchError(launch)) & ")"
    cLaunchKill(launch)
    cLaunchClose(launch)
    cLaunchFree(launch)
    if backendProc != 0'u64: cSpawnKill(backendProc)
    return 1
  ok "client resumed"

  # THE BOOT VERDICT. Read-only, against the process that now exists: the
  # nvngx_dlss.dll it actually LOADED and the OptiScaler keys actually on disk,
  # each compared with the aowl.dlss config. INCONCLUSIVE is printed as itself
  # -- NGX loads the DLL lazily, so a client still booting legitimately has no
  # such module yet, and that is not a pass.
  dlssVerdict(root, int(cLaunchPid(launch)))

  let hostLog = joinPath(root, "aowlspt\\aowlspt-host.log")
  line ""
  var clientExited = false
  # Bounded, and the bound is not a deadline for the game -- it is how long
  # this view waits before handing over to the log view, which shows the same
  # thing with more room. A cold IL2CPP launch is minutes.
  watchClient(launch, logs, who, knownProfiles, chosen.id, 90000'i64,
              clientExited)

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
    " haveChoice=" & $haveChoice &
    " autoEnter=" & $o.autoEnter & " noAutoEnter(no-op)=" & $o.noAutoEnter &
    " profile=" & chosen.id
  discard writeTextFile(verdictPath, entryLine & "\n")

  if clientExited:
    warn "the client exited while starting; see " & hostLog
    discard writeTextFile(verdictPath,
      entryLine & "\nauto-enter verdict: SKIPPED -- client exited while " &
      "starting\n")
  elif haveChoice and not o.autoEnter:
    # THE DEFAULT since 2026-09-02, and it is a default flip, not a removal.
    #
    # Nothing is skipped here: the host answers the character/mode screen
    # natively on every boot (`modeskip.nim`, gated by `uxSkipModeScreen` in
    # `aowlspt-host.json`; the host log line is `skip mode screen: Submit
    # called for profile ...`, measured at ~26s). Doing the same job a second
    # time from out here cost a burst of inspector traffic -- eight `roots`
    # polls and a 58-command `allow write` batch with 29 `call
    # name:get_activeInHierarchy` in it, inside the first 22s -- on a channel
    # that has exactly one command file and one writer at a time.
    #
    # Said in ONE line, on stdout and in the verdict file, because "the
    # launcher did nothing" and "the launcher decided not to" look identical
    # from outside otherwise.
    let msg = "auto-enter verdict: OFF (default) -- the host answers " &
      "character-select natively (uxSkipModeScreen, modeskip.nim); pass " &
      "--auto-enter to drive it from the launcher instead"
    note msg
    discard writeTextFile(verdictPath, entryLine & "\n" & msg & "\n")
  elif haveChoice and o.autoEnter:
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
    # The tag goes into every sentinel this process writes
    # (`aowl-batch-launch<pid>-<ms>-<n>`), which is the only part of a batch
    # the host echoes into its log -- so a boot-time batch is now a grep, not
    # an investigation.
    var u = initUi(joinPath(root, "aowlspt"), 20000, true, "launch")
    var waitTries = 0
    var screenUp = false
    var waitErr = ""
    let waitStart = cNowMs()
    discard writeTextFile(verdictPath,
      entryLine & "\nauto-enter: before screen-wait loop\n")
    # FOURTH, and the one a player actually hit: this loop used to look at
    # exactly one thing -- a `CharacterSelectionScreen` with `active == triYes`
    # -- and so it could not tell "not there yet" from "gone, because the human
    # clicked through it and is in a raid". In a raid the `Menu UI` scene root
    # does not exist at all, so the screen it was waiting for could never come
    # back and the loop burned the whole 270s. Meanwhile `watchClient` had
    # already called `panel.settle()`, so screen 1 was frozen in the scrollback
    # with its clock stopped at 1.3s and nothing on screen said what was going
    # on. The player was playing; the launcher looked hung.
    #
    # `ScreenSet.rootPresent` is exactly this signal and the library returns it
    # deliberately -- see its comment in `tools/aowlui.nim`: the absence of the
    # root "is not an error -- it is the single most reliable IN-RAID signal we
    # have". It was being ignored. The whole decision now lives in
    # `enterWaitVerdict`, which is pure and therefore actually testable
    # (`tests/tuilayout.nim`); this loop only gathers what it observes.
    #
    # The wait also PAINTS now. A bounded wait that shows nothing is
    # indistinguishable from a hang for as long as it lasts, and 270s of that
    # is what the player saw.
    # FIFTH, and this is why the screen still looked frozen after the last fix:
    # one iteration of this loop could BLOCK for over a minute.
    #
    # `screens()` is `roots` + `children` + `actives`, and each of those goes
    # through `runBatch`, which retries a dropped batch THREE times at the
    # pinned `Ui.timeoutMs`. At the 20s pin that is up to 60s for the `roots`
    # call alone, during which this loop is inside a single call: it does not
    # tick, does not re-evaluate and does not repaint. That is exactly the
    # reported symptom -- the step read `waiting for it (0.0s)` and then, with
    # no frame in between, `waiting for it (1m 08s)`. Painting once per
    # iteration is worth nothing when an iteration lasts 66 seconds.
    #
    # So the POLL gets a short pin of its own. A poll that gets no answer is
    # supposed to be cheap; the outer loop is what provides the patience, and
    # it can only do that if it actually gets to run. The press below still
    # uses the long pinned timeout, because by then the screen is confirmed up
    # and the click is worth waiting for.
    #
    # Also relevant, and worth saying plainly: `runBatchOnce` writes the WHOLE
    # command file with no locking or ownership of any kind, so any other tool
    # driving the inspector at the same time silently overwrites this batch and
    # vice versa. That cannot corrupt an answer -- each batch waits on its own
    # unique sentinel, so a clobbered batch times out rather than returning
    # someone else's result -- but it does make polls fail, and under a short
    # pin that now shows up on screen as "N unanswered" instead of as a stall.
    u.timeoutMs = 4000
    u.timeoutPinned = true
    var ew = EnterWait(sawMenuRoot: false, menuRootPresent: false,
                       sawSelector: false, selectorActive: false,
                       otherScreenActive: false, clientAlive: true,
                       elapsedMs: 0'i64, polls: 0, answered: 0,
                       interactive: termMode() == tmFull and stdinIsConsole())
    var verdict = EwWaiting
    var verdictWhy = ""
    var waitPanel = newPanel()
    var waitPainting = termMode() == tmFull
    var ws = newScreen()
    ws.phase = phClient
    ws.who = who
    ws.profilesKnown = true
    ws.profiles = knownProfiles
    ws.chosenId = chosen.id
    ws.pid = int(cLaunchPid(launch))
    ws.srvText = "server up"
    ws.srvCol = ColGreen
    pumpBoth(logs)
    var hostRunning = scanHost(logs.client).running
    while screenFor(hostRunning, ew.clientAlive, verdict) == ScreenLauncher:
      var ss = default(ScreenSet)
      var active = triUnknown
      ew.selectorActive = false
      ew.otherScreenActive = false
      inc ew.polls
      # TWO STAGES, split by what each is ALLOWED to do to the client.
      #
      # Stage 1 is READ-ONLY -- `roots` + `children`, no `allow write`, no call
      # into game code -- and it answers the question that is asked on almost
      # every iteration: is the `Menu UI` root there, and is there a node
      # called `CharacterSelectionScreen` under it. That is the whole of the
      # cold-boot minute.
      #
      # Stage 2 asks whether that node is ACTIVE, and it cannot be read-only:
      # `activeInHierarchy` is only reachable through `call
      # name:get_activeInHierarchy`, and the host gates every `call` behind
      # `allow write` (inspect.nim: reads are read-only "and `call` is
      # therefore gated by the same `allow write`"). So the write batch is not
      # gone -- it is no longer issued on polls where there is nothing to
      # confirm, which is what made this loop arm writes 29 calls at a time
      # while the client was still loading.
      var polled = false
      var selectorSeen = false
      if screens(u, "Menu UI", ss, false):
        polled = true
        ew.menuRootPresent = ss.rootPresent
        if ss.rootPresent: ew.sawMenuRoot = true
        for sc in ss.screens:
          if sc.name == "CharacterSelectionScreen":
            ew.sawSelector = true
            selectorSeen = true
      else:
        # A poll that got no answer says nothing either way, so it must not
        # move `menuRootPresent`: reading a dropped batch as "the root is gone"
        # would call a raid on a channel hiccup.
        waitErr = u.lastErr
      if polled and selectorSeen:
        var sa = default(ScreenSet)
        if screens(u, "Menu UI", sa, true):
          for sc in sa.screens:
            if sc.name == "CharacterSelectionScreen":
              active = sc.active
              if sc.active == triYes: ew.selectorActive = true
            elif sc.active == triYes:
              ew.otherScreenActive = true
        else:
          # Stage 2 dropped: `active` stays `triUnknown` and both actives stay
          # false, so this poll is inconclusive rather than a negative. It must
          # not read as "the selector is closed and something else is up",
          # which is one of the two EwPassed signals.
          waitErr = u.lastErr
      if polled: inc ew.answered
      ew.clientAlive = cLaunchAlive(launch) != 0'i32
      ew.elapsedMs = cNowMs() - waitStart
      verdict = enterWaitVerdict(ew, verdictWhy)
      discard writeTextFile(verdictPath,
        entryLine & "\nauto-enter: wait iter " & $waitTries & " elapsed=" &
        $ew.elapsedMs & "ms active=" & $active &
        " sawMenuRoot=" & $ew.sawMenuRoot &
        " menuRootPresent=" & $ew.menuRootPresent &
        " verdict=" & $verdict & " why=" & verdictWhy &
        " err=" & waitErr & "\n")
      # Keep screen 1 alive while we wait, so the clock moves and the step
      # says what is being waited for.
      pumpBoth(logs)
      ws.host = scanHost(logs.client)
      hostRunning = ws.host.running
      if waitPainting:
        ws.alive = ew.clientAlive
        ws.cliText = (if ew.clientAlive: "client up" else: "client exited")
        ws.cliCol = (if ew.clientAlive: ColGreen else: ColRed)
        ws.enterState = verdict
        ws.enterWaitedMs = ew.elapsedMs
        ws.enterDetail = enterWaitDetail(ew, verdict)
        if not paintPhase(waitPanel, logs, ws, ew.elapsedMs):
          waitPainting = false
      if not enterWaitDone(verdict):
        cSleepMs 3000
        inc waitTries
    screenUp = (verdict == EwSelectorUp)
    if waitPainting: waitPanel.settle()
    discard writeTextFile(verdictPath,
      entryLine & "\nauto-enter: after screen-wait loop, verdict=" & $verdict &
      " why=" & verdictWhy & " screenUp=" & $screenUp &
      " waitTries=" & $waitTries & " waitErr=" & waitErr & "\n")
    if verdict == EwPassed or verdict == EwClientGone:
      # NOT a failure, and it must not be reported as one: the player got
      # themselves past character select, which is the thing auto-enter exists
      # to do. Say so and hand straight over to the logs.
      note "auto-enter skipped -- " & verdictWhy
      flushOut()
    elif not screenUp:
      # The reason comes from the verdict rather than being restated here, so
      # the message cannot claim "never became active within 270s" for a wait
      # that actually stopped after 20s, or for one that never observed
      # anything at all. Stating a cause the code did not establish is the
      # confidently-wrong diagnostic rule 6 is about.
      let msg = "auto-enter verdict: INCONCLUSIVE -- " & verdictWhy &
        (if waitErr.len > 0: " Last channel error: " & waitErr else: "")
      warn msg
      discard writeTextFile(verdictPath, entryLine & "\n" & msg & "\n")
      note "left at whatever screen is actually up; check liveInspector is " &
           "on in aowlspt-host.json, or drop --auto-enter to silence this"
    else:
      ok "character-select is up (waited " & secsText(ew.elapsedMs) &
         ") -- matching now"
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
        note "left at the manual selector; drop --auto-enter to silence " &
             "this warning next time"

    # DO NOT LEAVE THE BATCH IN THE FILE. On every exit from this block --
    # passed, pressed, timed out, no channel -- because the file is what the
    # NEXT boot's host reads first, and until this existed that was this
    # loop's last probe batch, `allow write` and 29 calls into game code
    # included, queued at a client nobody had asked anything.
    #
    # A busy lock is reported, not retried: another writer's batch is in that
    # file and clobbering it is the collision the lock exists to prevent.
    if not releaseChannel(u):
      note "the inspector command file was left as it was -- " & u.lastErr

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
    # The launch, collapsed to the one line SCREEN 2 keeps at the top while the
    # panes take the rest. Read back out of the host's own log rather than
    # remembered from the phase that painted it, so it states what is true now
    # and not what was true when that phase returned.
    let endHost = scanHost(logs.client)
    var sumKind = MarkDone
    var sumText = "server on 127.0.0.1:" & $port
    if clientExited:
      sumKind = MarkFailed
      sumText = "the client exited while starting -- see the client pane"
    elif endHost.running:
      sumText = "host running, " & $endHost.modsLoaded &
                " client mod(s) loaded; server on 127.0.0.1:" & $port
    else:
      sumKind = MarkActive
      sumText = "client started; the host has not reported running yet"
    # THE HANDOFF. Screen 1 is finished; screen 2 takes the window. Printed
    # into the scrollback, immediately under the last launcher frame, so the
    # swap is a line the player can point at afterwards -- and so a launcher
    # that is redirected to a file, or too small for either view, still records
    # that the phase changed and why.
    var hw = 0
    var hh = 0
    termSize(hw, hh)
    if hw <= 0: hw = 80
    if hw > 160: hw = 160
    echo ""
    echo handoffRow(hw - 1,
                    (if clientExited:
                       "launch finished with the client gone -- the logs take " &
                       "the screen now"
                     else:
                       "launch complete -- the logs take the screen now " &
                       "(q quit, d detach)")).text
    flushOut()
    runLogView(who, backendProc, launch, true, logs, sumKind, sumText, detached)
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
  termShutdown()
  result = 0

quit(main())
