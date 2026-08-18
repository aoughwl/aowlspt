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

import std/[strutils, syncio, cmdline]
import aowlsptinstall/[winfs, log, eft]

{.emit: """#include <stdlib.h>""".}
{.emit: """#include <string.h>""".}
{.emit: """#include "aowlspt_shim.h" """.}
{.emit: """#include "aowlspt_inject.h" """.}

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
proc cSpawnAlive(h: uint64): int32 {.importc: "aowl_spawn_alive", nodecl.}
proc cSpawnKill(h: uint64) {.importc: "aowl_spawn_kill", nodecl.}
proc cSleepMs(ms: int32) {.importc: "aowl_sys_sleep", nodecl.}

const Usage = """
aowlspt-launch -- start Tarkov with the aowlspt host inside it

  aowlspt-launch [--root PATH] [options]

Options
  --root PATH    the aowlspt install (default: the directory this exe is in)
  --exe NAME     executable to start (default: EscapeFromTarkov.exe)
  --args "..."   extra command line for the game
  --wait         stay open until the game exits
  --no-backend   do not start the backend server
  --port N       backend port (default 6969)
  --dry-run      report what would happen and start nothing
  --force        launch even if the client looks wrong for this host
  -h, --help     this
"""

type
  Options = object
    root: string
    exeName: string
    extraArgs: string
    wait: bool
    force: bool
    noBackend: bool
    port: int
    help: bool

proc parseArgs(): Options =
  result = Options(root: "", exeName: "EscapeFromTarkov.exe", extraArgs: "",
                   wait: false, force: false, noBackend: false, port: 6969,
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
    elif a == "--wait":
      result.wait = true
    elif a == "--no-backend":
      result.noBackend = true
    elif a == "--port":
      inc i
      if i <= n:
        var v = 0
        var any = false
        for ch in paramStr(i):
          if ch >= '0' and ch <= '9':
            v = v * 10 + (ord(ch) - ord('0'))
            any = true
        if any: result.port = v
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

proc main(): int =
  let o = parseArgs()
  if o.help:
    echo Usage
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

  if dryRun():
    heading "Dry run"
    let be = joinPath(root, "aowlspt\\aowlspt-backend.exe")
    if not o.noBackend and fileExists(be):
      line "  would start   " & be & " --port " & $o.port
    line "  would start   " & exePath
    line "  would inject  " & hostDll
    line "  nothing was started."
    return 0

  # The backend goes up first. The client tries to reach it as soon as it
  # starts, so starting them the other way round is a race the client loses.
  var backendProc = 0'u64
  let backendExe = joinPath(root, "aowlspt\\aowlspt-backend.exe")
  if not o.noBackend:
    heading "Backend"
    if not fileExists(backendExe):
      warn "no backend at " & backendExe & "; starting the client alone"
    else:
      var be = backendExe
      var bd = joinPath(root, "aowlspt")
      var bc = "\"" & backendExe & "\" --root \"" & bd & "\" --port " & $o.port
      backendProc = cSpawn(toCString(be), toCString(bd), toCString(bc))
      if backendProc == 0'u64:
        err "could not start the backend"
        return 1
      ok "backend started on port " & $o.port
      # A backend that dies immediately (a port already in use, a broken mod)
      # would otherwise show up as a client that cannot connect.
      cSleepMs(1200'i32)
      if cSpawnAlive(backendProc) == 0'i32:
        err "the backend exited immediately; see " &
            joinPath(root, "aowlspt\aowlspt-backend.log")
        return 1
      ok "backend still up"

  heading "Launching"
  let launch = cLaunchNew()
  if launch == nil:
    err "out of memory"
    return 1

  var e = exePath
  var w = root
  var cmd = o.extraArgs
  if cLaunchStart(launch, toCString(e), toCString(w), toCString(cmd)) == 0'i32:
    err "could not start " & exePath & " (error " & $int(cLaunchError(launch)) & ")"
    cLaunchFree(launch)
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
    return 1
  ok "host injected"

  if cLaunchResume(launch) == 0'i32:
    err "could not resume the client (error " & $int(cLaunchError(launch)) & ")"
    cLaunchKill(launch)
    cLaunchClose(launch)
    cLaunchFree(launch)
    return 1
  ok "client resumed"

  line ""
  line "  The host writes " & joinPath(root, "aowlspt\\aowlspt-host.log") & "."
  line "  It waits for the game to bring IL2CPP up before it can resolve"
  line "  anything, which on a cold launch takes a while."

  if o.wait:
    heading "Waiting"
    discard cLaunchWait(launch, -1'i32)
    line "  the client exited"
    if backendProc != 0'u64:
      cSpawnKill(backendProc)
      line "  backend stopped"
  else:
    # A moment's grace so an immediate crash is reported here rather than
    # leaving the launcher claiming success.
    if cLaunchWait(launch, 3000'i32) == 1'i32:
      warn "the client exited within three seconds of starting"
      warn "check " & joinPath(root, "aowlspt\\aowlspt-host.log")

  cLaunchClose(launch)
  cLaunchFree(launch)
  result = 0

quit(main())
