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

# ---------------------------------------------------------------------------
# Asking the backend whether it is ready
# ---------------------------------------------------------------------------
#
# This used to be `Sleep(1200)` and a liveness check, and a fixed sleep is wrong
# at both ends of the range it is trying to cover. On a machine where the
# backend is up in 600 ms it wastes half a second of every launch. On the
# machine this was measured on it was **fifty-two seconds short**: the default
# mod set against an imported database took 54 s to answer, so the client came
# up, asked for `/client/game/config`, got nothing, and sat at the menu with
# neither log saying why. No constant fixes that, because what is being waited
# for is not a duration -- it is an event, and the event is observable.
#
# It is observable *exactly*, as it happens. `aowlspt-backend` calls
# `aowl_net_serve` only after `loadAll` returns, so the listening socket does
# not exist until every mod has finished loading. A successful connect is
# therefore not an approximation of readiness; it is readiness. The GET on top
# of it is the second half of the same question -- listening is not answering,
# and a server that has bound the port but cannot route is a state worth
# telling apart from one that can.
#
# ## Why winsock is loaded at run time
#
# `aowl build` builds this file with `buildTool`, which passes the ABI include
# path and both source trees and does **not** pass `-lws2_32`. That rule lives
# in `tools/aowl.nim`, which this file does not own, and a change there would
# have to be made for every tool built by the same rule. `GetProcAddress` costs
# eight lookups once per launch and needs nothing from the build.
#
# The declarations come from `<windows.h>`, which has already pulled in
# `winsock.h` by the time this compiles. `aowlspt_net.h` is deliberately *not*
# included: it includes `winsock2.h`, and winsock2 after windows.h is the
# redefinition mess every Windows codebase meets once. Winsock 1.1 has a TCP
# connect, which is all of what is wanted here.

{.emit: """
typedef SOCKET (WINAPI *aowl_fn_socket)(int, int, int);
typedef int (WINAPI *aowl_fn_connect)(SOCKET, const struct sockaddr*, int);
typedef int (WINAPI *aowl_fn_send)(SOCKET, const char*, int, int);
typedef int (WINAPI *aowl_fn_recv)(SOCKET, char*, int, int);
typedef int (WINAPI *aowl_fn_closesocket)(SOCKET);
typedef int (WINAPI *aowl_fn_setsockopt)(SOCKET, int, int, const char*, int);
typedef int (WINAPI *aowl_fn_wsastartup)(WORD, LPWSADATA);
typedef u_short (WINAPI *aowl_fn_htons)(u_short);
typedef u_long (WINAPI *aowl_fn_htonl)(u_long);

static HMODULE aowl_ws = NULL;
static aowl_fn_socket      aowl_p_socket;
static aowl_fn_connect     aowl_p_connect;
static aowl_fn_send        aowl_p_send;
static aowl_fn_recv        aowl_p_recv;
static aowl_fn_closesocket aowl_p_closesocket;
static aowl_fn_setsockopt  aowl_p_setsockopt;
static aowl_fn_htons       aowl_p_htons;
static aowl_fn_htonl       aowl_p_htonl;

/* Resolved once. Returns 0 when winsock is not there at all, which is not a
 * state a Windows machine reaches -- but a probe that cannot tell "no answer"
 * from "no sockets" would report a working backend as broken. */
static int aowl_ws_ready(void) {
  aowl_fn_wsastartup startup;
  WSADATA wsa;
  if (aowl_ws != NULL) return 1;
  aowl_ws = LoadLibraryA("ws2_32.dll");
  if (aowl_ws == NULL) return 0;
  startup            = (aowl_fn_wsastartup)(void*)GetProcAddress(aowl_ws, "WSAStartup");
  aowl_p_socket      = (aowl_fn_socket)(void*)GetProcAddress(aowl_ws, "socket");
  aowl_p_connect     = (aowl_fn_connect)(void*)GetProcAddress(aowl_ws, "connect");
  aowl_p_send        = (aowl_fn_send)(void*)GetProcAddress(aowl_ws, "send");
  aowl_p_recv        = (aowl_fn_recv)(void*)GetProcAddress(aowl_ws, "recv");
  aowl_p_closesocket = (aowl_fn_closesocket)(void*)GetProcAddress(aowl_ws, "closesocket");
  aowl_p_setsockopt  = (aowl_fn_setsockopt)(void*)GetProcAddress(aowl_ws, "setsockopt");
  aowl_p_htons       = (aowl_fn_htons)(void*)GetProcAddress(aowl_ws, "htons");
  aowl_p_htonl       = (aowl_fn_htonl)(void*)GetProcAddress(aowl_ws, "htonl");
  if (startup == NULL || aowl_p_socket == NULL || aowl_p_connect == NULL ||
      aowl_p_send == NULL || aowl_p_recv == NULL ||
      aowl_p_closesocket == NULL || aowl_p_setsockopt == NULL ||
      aowl_p_htons == NULL || aowl_p_htonl == NULL) {
    aowl_ws = NULL;
    return 0;
  }
  if (startup(MAKEWORD(2, 2), &wsa) != 0) {
    aowl_ws = NULL;
    return 0;
  }
  return 1;
}

/* 0  nothing is listening on the port yet
 * 1  connected, and an HTTP response came back
 * -1 winsock could not be loaded, so this cannot be asked at all
 *
 * The session cookie is a well-formed 24-character id because the backend
 * refuses a malformed one before any route sees it. It does not have to name a
 * real profile: what is being established is that the server parses a request
 * and answers, and any status line proves that. Matching on `HTTP/` rather than
 * on the body, because the body comes back zlib-framed and inflating it here
 * would mean linking zlib for one comparison. */
static int aowl_backend_answers(int32_t port) {
  SOCKET s;
  struct sockaddr_in a;
  const char *req;
  char buf[64];
  int n;
  DWORD t;
  if (!aowl_ws_ready()) return -1;
  s = aowl_p_socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (s == INVALID_SOCKET) return 0;
  memset(&a, 0, sizeof(a));
  a.sin_family = AF_INET;
  a.sin_port = aowl_p_htons((unsigned short)port);
  a.sin_addr.s_addr = aowl_p_htonl(INADDR_LOOPBACK);
  if (aowl_p_connect(s, (struct sockaddr*)&a, (int)sizeof(a)) == SOCKET_ERROR) {
    aowl_p_closesocket(s);
    return 0;
  }
  /* Bounded, because a backend mid-flush holds the database lock and a probe
   * that blocks for ever on it would hang the launcher rather than the poll. */
  t = 3000;
  aowl_p_setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char*)&t, sizeof(t));
  req = "GET /aowlspt/status HTTP/1.1\r\n"
        "Host: 127.0.0.1\r\n"
        "Cookie: PHPSESSID=000000000000000000000001\r\n"
        "Content-Length: 0\r\n"
        "Connection: close\r\n\r\n";
  if (aowl_p_send(s, req, (int)strlen(req), 0) == SOCKET_ERROR) {
    aowl_p_closesocket(s);
    return 0;
  }
  memset(buf, 0, sizeof(buf));
  n = aowl_p_recv(s, buf, (int)sizeof(buf) - 1, 0);
  aowl_p_closesocket(s);
  if (n <= 0) return 0;
  return (strstr(buf, "HTTP/") != NULL) ? 1 : 0;
}

static int64_t aowl_launch_now_ms(void) {
  return (int64_t)GetTickCount64();
}
""".}

proc cBackendAnswers(port: int32): int32 {.
  importc: "aowl_backend_answers", nodecl.}
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
  --backend-wait N
                 seconds to wait for the backend to answer before starting the
                 client (default 300, 0 to not wait at all)
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
    backendWait: int
    help: bool

proc parseArgs(): Options =
  result = Options(root: "", exeName: "EscapeFromTarkov.exe", extraArgs: "",
                   wait: false, force: false, noBackend: false, port: 6969,
                   backendWait: 300, help: false)
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
    if o.noBackend:
      line "  would start   no backend (--no-backend was given)"
      let already = cBackendAnswers(int32(o.port))
      if already == 1'i32:
        line "  would find    a backend already answering on 127.0.0.1:" &
             $o.port
      elif already == 0'i32:
        line "  would find    nothing answering on 127.0.0.1:" & $o.port &
             " -- start one by hand first"
    elif fileExists(be):
      line "  would start   " & be & " --port " & $o.port
      if o.backendWait > 0:
        line "  would wait    until it answers on 127.0.0.1:" & $o.port &
             ", up to " & $o.backendWait & "s"
      else:
        line "  would wait    not at all (--backend-wait 0)"
    else:
      # Said rather than left out. A dry run that silently omits the backend
      # line reads as "the backend is not part of this", when what it means is
      # "there is no backend in this install" -- and the real launch would go
      # on to start a client with nothing to talk to.
      warn "  no backend at " & be & "; the client would start alone"
    line "  would start   " & exePath
    line "  would inject  " & hostDll
    line "  nothing was started."
    return 0

  # The backend goes up first. The client tries to reach it as soon as it
  # starts, so starting them the other way round is a race the client loses.
  var backendProc = 0'u64
  let backendExe = joinPath(root, "aowlspt\\aowlspt-backend.exe")
  if o.noBackend:
    # Asked, not assumed, and not waited on. `--no-backend` means this launcher
    # is not responsible for the server -- so it says what is there and starts
    # the client either way, which is the whole point of the flag.
    heading "Backend"
    if cBackendAnswers(int32(o.port)) == 1'i32:
      ok "a backend is already answering on 127.0.0.1:" & $o.port
    else:
      warn "nothing is answering on 127.0.0.1:" & $o.port &
           " and --no-backend was given, so none will be started. The client " &
           "will have no server to talk to unless one comes up on its own."
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

      # Wait for an *answer*, not for a duration.
      #
      # The client asks for `/client/game/config` almost as soon as it is
      # resumed, and a client that asks before the server can answer sits at
      # the menu with nothing in either log to say why. What that costs is not
      # a constant: the backend reads a 41 MB database and then loads every mod
      # in the install, and how long a mod takes to load is the mod's business.
      # So this polls the port until something answers, and checks the process
      # is still there on every pass -- "not answering yet" and "died on the
      # way up" look identical from outside, and only one of them is worth
      # waiting for.
      if o.backendWait <= 0:
        note "not waiting for the backend (--backend-wait 0); the client may " &
             "come up before the server can answer it"
      else:
        line "  waiting for the backend to answer on 127.0.0.1:" & $o.port &
             " (up to " & $o.backendWait & "s)"
        let began = cNowMs()
        var answered = false
        var died = false
        var probeBroken = false
        var lastNote = 0'i64
        while true:
          let waitedMs = cNowMs() - began
          if waitedMs >= int64(o.backendWait) * 1000'i64:
            break
          # Asked before the liveness check on purpose. If the backend this
          # launcher started lost a race for the port to one somebody else had
          # already started, the process is gone and the port answers -- and
          # the client cares about the port. An answer wins over a corpse.
          let r = cBackendAnswers(int32(o.port))
          if r == 1'i32:
            answered = true
            break
          if r < 0'i32:
            probeBroken = true
            break
          if cSpawnAlive(backendProc) == 0'i32:
            died = true
            break
          # Said out loud rather than left as a silent pause. A launcher that
          # prints one line and then stops for ten seconds reads as a hang, and
          # the person watching it has no way to tell that from one.
          if waitedMs - lastNote >= 5000'i64:
            lastNote = waitedMs
            line "  still loading -- " & $int(waitedMs div 1000'i64) &
                 "s so far. The backend reads the database and loads every " &
                 "installed mod before it opens the port."
          cSleepMs(200'i32)

        if died:
          err "the backend exited while starting; see " &
              joinPath(root, "aowlspt\\aowlspt-backend.log")
          return 1
        if probeBroken:
          warn "could not open a socket to ask the backend anything, so " &
               "whether it is ready could not be checked. Starting the " &
               "client anyway."
        elif answered:
          ok "backend answered after " & $int(cNowMs() - began) & " ms"
        else:
          warn "the backend has not answered after " & $o.backendWait &
               "s and is still running. Starting the client anyway -- it may " &
               "reach the menu before the server does."
          note "see " & joinPath(root, "aowlspt\\aowlspt-backend.log") &
               " for what it is doing, or raise --backend-wait"

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
