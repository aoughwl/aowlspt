## hostharness -- run the IL2CPP client host without launching Tarkov.
##
##     hostharness HOST-DIR [--seconds N]     load the host into this process
##     hostharness HOST-DIR --inject EXE      start EXE suspended and inject it
##     hostharness --sleep N                  be an injection target for N seconds
##
## `HOST-DIR` holds `aowlspt-host-il2cpp.dll` and a `mods/` directory.
##
## The first form loads the host the way any process would -- a plain
## `LoadLibrary`, which fires the constructor that starts the host thread. The
## second exercises the code the real launcher uses (`abi/aowlspt_inject.h`):
## `CreateProcess` suspended, `VirtualAllocEx` + `WriteProcessMemory`,
## `CreateRemoteThread` at `LoadLibraryA`, resume. Point it at this same
## executable with `--sleep` and the whole path is tested without a game.
##
## Between them these prove everything except the runtime itself:
##
##   the constructor fires and the host thread starts
##   the host finds its own directory and opens its log
##   it discovers mods, checks their ABI version, and calls describe/init
##   `AowlHostApi` survives the boundary: the mod logs through it
##   `on_load` and `on_update` run
##
## What they cannot prove is `resolve` and `call`, because there is no IL2CPP
## runtime in either process -- and that is the point of running them. The host
## is supposed to notice, say so, and keep going rather than take the process
## down. A run that ends in "the runtime did not come up" is the expected
## result here, not a failure.

import std/[strutils, syncio, cmdline]
import aowlsptinstall/[winfs, log]

{.emit: """
#include <windows.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
static void* aowl_harness_load(const char* p) {
  return (void*)LoadLibraryExA(p, NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
}
static uint32_t aowl_harness_error(void) { return (uint32_t)GetLastError(); }
static void aowl_harness_sleep(int32_t ms) { Sleep((DWORD)ms); }

/* A stand-in IL2CPP runtime, for exercising the host paths the real one
   cannot reach outside the game. Loaded before the host and started after it,
   so the host's "wait for the runtime" poll is exercised rather than skipped. */
static void* g_mockRt = NULL;
static int32_t aowl_rt_load(const char* p) {
  g_mockRt = (void*)LoadLibraryExA(p, NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
  return g_mockRt != NULL;
}
static int32_t aowl_rt_init(void) {
  if (!g_mockRt) return 0;
  void* f = (void*)GetProcAddress((HMODULE)g_mockRt, "il2cpp_init");
  if (!f) return 0;
  return ((void*(*)(const char*))f)("mock") != NULL;
}
static int32_t aowl_rt_tick_count(void) {
  if (!g_mockRt) return -1;
  void* f = (void*)GetProcAddress((HMODULE)g_mockRt, "mock_tick_count");
  if (!f) return -1;
  return ((int32_t(*)(void))f)();
}
""".}
{.emit: """#include "aowlspt_inject.h" """.}

proc harnessLoad(path: cstring): nil pointer {.
  importc: "aowl_harness_load", nodecl.}
proc harnessError(): uint32 {.importc: "aowl_harness_error", nodecl.}
proc harnessSleep(ms: int32) {.importc: "aowl_harness_sleep", nodecl.}
proc rtLoad(path: cstring): int32 {.importc: "aowl_rt_load", nodecl.}
proc rtInit(): int32 {.importc: "aowl_rt_init", nodecl.}
proc rtTickCount(): int32 {.importc: "aowl_rt_tick_count", nodecl.}

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
proc cLaunchWait(p: LaunchPtr; ms: int32): int32 {.
  importc: "aowl_launch_wait", nodecl.}

const Usage = """
hostharness -- run the IL2CPP client host outside the game

  hostharness HOST-DIR [--seconds N]     load the host into this process
  hostharness HOST-DIR --inject EXE      start EXE suspended and inject it
  hostharness HOST-DIR --runtime DLL     bring a mock IL2CPP runtime up too
  hostharness --sleep N                  be an injection target for N seconds

HOST-DIR holds aowlspt-host-il2cpp.dll and mods/.

--runtime loads a stand-in GameAssembly.dll before the host and starts it a
second later, so the host's wait-for-runtime poll runs for real and resolve
and call have something to resolve against.
"""

proc parseCount(s: string; into: var int): bool =
  var v = 0
  var any = false
  for ch in s:
    if ch >= '0' and ch <= '9':
      v = v * 10 + (ord(ch) - ord('0'))
      any = true
    else:
      return false
  if any: into = v
  result = any

proc checkLog(logPath: string; expectRuntime: bool = false): int =
  heading "Host log"
  var text = ""
  if not readTextFile(logPath, text):
    err "the host wrote no log at " & logPath
    err "that means its thread never ran -- the boot path is broken"
    return 1
  for l in splitLines(text):
    if l.len > 0:
      line "  " & l

  var started = false
  var loadedAMod = false
  var noticedNoRuntime = false
  var boundRuntime = false
  var resolved = 0
  var calledOk = false
  var patchFired = false
  var argsOk = false
  for l in splitLines(text):
    if find(l, "host running") >= 0:
      started = true
    if find(l, "loaded ") >= 0 and find(l, "aowl.") >= 0:
      loadedAMod = true
    if find(l, "did not come up") >= 0:
      noticedNoRuntime = true
    if find(l, "IL2CPP runtime bound") >= 0:
      boundRuntime = true
    if find(l, "resolved ") >= 0:
      inc resolved
    if find(l, "the game says Unity") >= 0 or find(l, "Unity 2022") >= 0:
      calledOk = true
    if find(l, "the hook fired on all") >= 0 or
       find(l, "the patch fired on all") >= 0:
      patchFired = true
    if find(l, "Add(17, 25) = 42") >= 0:
      argsOk = true

  heading "Result"
  if not started:
    err "the host never reached 'host running'"
    return 1
  ok "the host booted and reached its tick loop"
  if loadedAMod:
    ok "a mod was loaded through the ABI"
  else:
    warn "no mod was loaded -- expected only if mods/ is empty"

  if not expectRuntime:
    if noticedNoRuntime:
      ok "the missing IL2CPP runtime was reported, not crashed on"
    return 0

  # With a runtime present, silence is not success: the point of the run is
  # that resolve and call actually did something.
  if not boundRuntime:
    err "the host never bound the runtime"
    return 1
  ok "the host bound the runtime and attached a thread"
  if resolved < 3:
    err "only " & $resolved & " types resolved; expected at least 3"
    return 1
  ok $resolved & " types resolved by name through the runtime"
  if not calledOk:
    err "call never returned a value"
    return 1
  ok "a method was invoked and its string return marshalled back"
  if not argsOk:
    err "no call with arguments produced the expected value"
    return 1
  ok "arguments were bound by declared type and came back correct"
  if not patchFired:
    err "no patch fired"
    return 1
  ok "a compiled method was detoured and the patch fired"
  result = 0

proc runInjection(hostDll, logPath, target: string; seconds: int): int =
  ## The real launcher's path, against a target we control.
  heading "Injecting"
  line "  target  " & target
  if not fileExists(target):
    err "no such executable"
    return 1

  let launch = cLaunchNew()
  if launch == nil:
    err "out of memory"
    return 1

  var e = target
  var w = parentOf(target)
  # argv[0] first, the way CreateProcess expects a command line.
  var cmd = "\"" & target & "\" --sleep " & $seconds
  if cLaunchStart(launch, toCString(e), toCString(w), toCString(cmd)) == 0'i32:
    err "could not start it (error " & $int(cLaunchError(launch)) & ")"
    cLaunchFree(launch)
    return 1
  ok "started suspended, pid " & $int(cLaunchPid(launch))

  var d = hostDll
  if cLaunchInject(launch, toCString(d)) == 0'i32:
    err "injection failed (error " & $int(cLaunchError(launch)) & ")"
    cLaunchKill(launch)
    cLaunchClose(launch)
    cLaunchFree(launch)
    return 1
  ok "host injected into the target"

  if cLaunchResume(launch) == 0'i32:
    err "could not resume (error " & $int(cLaunchError(launch)) & ")"
    cLaunchKill(launch)
    cLaunchClose(launch)
    cLaunchFree(launch)
    return 1
  ok "target resumed"

  discard cLaunchWait(launch, int32((seconds + 5) * 1000))
  cLaunchClose(launch)
  cLaunchFree(launch)
  result = checkLog(logPath)

proc main(): int =
  var dir = ""
  var seconds = 8
  var injectTarget = ""
  var runtimeDll = ""
  var sleepFor = -1
  var i = 1
  let n = paramCount()
  while i <= n:
    let a = paramStr(i)
    if a == "--seconds":
      inc i
      if i <= n: discard parseCount(paramStr(i), seconds)
    elif a == "--inject":
      inc i
      if i <= n: injectTarget = paramStr(i)
    elif a == "--runtime":
      inc i
      if i <= n: runtimeDll = paramStr(i)
    elif a == "--sleep":
      inc i
      if i <= n: discard parseCount(paramStr(i), sleepFor)
    elif a == "--help" or a == "-h":
      echo Usage
      return 0
    elif dir.len == 0:
      dir = a
    inc i

  # Target mode: do nothing but stay alive long enough to be injected into.
  if sleepFor >= 0:
    harnessSleep(int32(sleepFor * 1000))
    return 0

  if dir.len == 0:
    echo Usage
    return 1

  let root = absolutePathOf(dir)
  let hostDll = joinPath(root, "aowlspt-host-il2cpp.dll")
  let logPath = joinPath(root, "aowlspt-host.log")

  heading "Harness"
  line "  host   " & hostDll
  if not fileExists(hostDll):
    err "no host DLL there"
    return 1

  let modsDir = joinPath(root, "mods")
  if isDirectory(modsDir):
    var files: seq[string] = @[]
    var dirs: seq[string] = @[]
    collectEntries(modsDir, files, dirs)
    var count = 0
    for f in files:
      if endsWith(toLowerAscii(f), ".dll"):
        inc count
        line "  mod    " & f
    if count == 0:
      warn "no mod libraries under " & modsDir
  else:
    warn "no mods directory at " & modsDir

  # A stale log would make a host that never started look like one that did.
  discard removeFileAt(logPath)

  if injectTarget.len > 0:
    return runInjection(hostDll, logPath, absolutePathOf(injectTarget), seconds)

  # The runtime goes in before the host, but stays un-started: the host must
  # find the module and then wait for a domain, which is the same window the
  # game has between process start and IL2CPP coming up.
  var haveRuntime = false
  if runtimeDll.len > 0:
    heading "Mock runtime"
    var r = absolutePathOf(runtimeDll)
    line "  " & r
    if not fileExists(r):
      err "no such runtime"
      return 1
    if rtLoad(toCString(r)) == 0'i32:
      err "could not load it (error " & $int(harnessError()) & ")"
      return 1
    ok "loaded, not yet started"
    haveRuntime = true

  heading "Loading"
  var p = hostDll
  let h = harnessLoad(toCString(p))
  if h == nil:
    err "LoadLibrary failed (error " & $int(harnessError()) & ")"
    return 1
  ok "host loaded; the constructor should have started its thread"

  if haveRuntime:
    harnessSleep(1500'i32)
    if rtInit() == 0'i32:
      err "the mock runtime would not start"
      return 1
    ok "mock runtime started; the host should pick it up on its next poll"

  line "  running for " & $seconds & "s"
  harnessSleep(int32(seconds * 1000))

  result = checkLog(logPath, haveRuntime)

quit(main())
