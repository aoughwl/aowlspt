## aowl -- the one command that builds, tests and installs this repo.
##
##     aowl build                 everything: hosts, installer, examples
##     aowl build-mod PATH        one nimony mod -> a native .dll
##     aowl build-hosts           the simulator and the .NET tools
##     aowl build-installer       aowlspt-install.exe
##     aowl test                  every gate
##     aowl run PATH              build a mod, then run it in the simulator
##     aowl payload               assemble installer/payload from what is built
##     aowl clean
##
## This replaces the PowerShell scripts that used to live here. It is not a
## translation of them: the point is that the repo has one toolchain rather than
## two, and that the thing which builds a nimony mod is itself a nimony program.
##
## What it mostly encodes is two environment facts that are miserable to
## rediscover:
##
##  * msys2's ucrt64 bin directory must precede Git-for-Windows' /mingw64/bin on
##    PATH. Otherwise gcc's cc1 loads libgcc/libgmp/zlib/zstd out of Git's
##    mingw64 and dies with no diagnostic whatsoever.
##  * The linker must be lld. nimony's niflink passes -fuse-ld=lld on Windows
##    deliberately: ld.bfd lays out PE TLS in a way the loader mishandles, and
##    nimony's runtime uses native TLS. Without it the link fails with
##    "collect2: cannot find 'ld'".

import std/[strutils, syncio, cmdline, envvars, osproc]
import aowlsptinstall/[winfs, log]

const Usage = """
aowl -- build, test and install aowlspt

  build              hosts, installer and every example
  build-mod PATH     compile one nimony mod into a native library
  build-hosts        aowlspt-sim (nimony) and the .NET tools left
  build-installer    aowlspt-install.exe
  test               every gate
  doctor             check the toolchain before it wastes your afternoon
  run PATH           build a mod and run it in the simulator
  payload            assemble installer/payload from what is built
  release            a versioned, verifiable artifact; --mod NAME for one mod
  importdb           build the emulator's db.json from an SPT install
                     (--from D:\SPT; --help for the rest)
  clean              remove build output

Options
  --debug            build with debug info and no optimisation
  --nimony PATH      nimony checkout (default: %USERPROFILE%\nimony)
  --ucrt64 PATH      msys2 ucrt64 bin (default: C:\msys64\ucrt64\bin)
  -v, --verbose      show every command
  -h, --help         this
"""

type
  Env = object
    repo: string
    nimony: string
    ucrt64: string
    debugBuild: bool
    verbose: bool

var failures = 0

proc repoRoot(): string =
  ## The repo is the parent of the directory holding this source. Derived
  ## rather than configured so that `aowl` works from any working directory.
  let here = absolutePathOf(".")
  var cur = here
  while cur.len > 0:
    if isDirectory(joinPath(cur, "abi")) and
       fileExists(joinPath(cur, "abi\\aowlspt_abi.h")):
      return cur
    let up = parentOf(cur)
    if up.len == 0 or up == cur:
      break
    cur = up
  result = here

proc run(e: Env; what, command: string; workingDir = ""): bool =
  ## Every external command goes through here so that failures are counted and
  ## reported once, at the end, rather than scattered through the output.
  ##
  ## `workingDir` is not a convenience. nimony writes its `nimcache` relative to
  ## the working directory, so a mod compiled from the repo root leaves its
  ## intermediate output -- and, for a `--app:lib` build, the library itself --
  ## in the repo root rather than beside the mod.
  if e.verbose:
    detail command
  var code = -1
  var output = ""
  try:
    let (o, c) = execCmdEx(command, workingDir = workingDir)
    output = o
    code = c
  except:
    err what & ": could not start the command"
    inc failures
    return false
  if code == 0:
    ok what
    if e.verbose and output.len > 0:
      for l in splitLines(output):
        if l.len > 0:
          detail l
    result = true
  else:
    err what & " (exit " & $code & ")"
    for l in splitLines(output):
      if l.len > 0:
        line "        " & l
    inc failures
    result = false

proc quoted(s: string): string =
  result = "\"" & s & "\""

proc prepareEnv(e: Env) =
  ## Prepend ucrt64 and nimony's bin to PATH for every child process. See the
  ## module comment for why the order is not negotiable.
  let existing = getEnv("PATH", "")
  var head = ""
  if isDirectory(e.ucrt64):
    head = e.ucrt64
  else:
    warn e.ucrt64 & " not found; gcc may resolve to the wrong mingw"
  let nimonyBin = joinPath(e.nimony, "bin")
  if isDirectory(nimonyBin):
    if head.len > 0: head.add ";"
    head.add nimonyBin
  if head.len > 0:
    try:
      putEnv("PATH", head & ";" & existing)
    except:
      warn "could not set PATH; gcc and the linker may not be found"

proc nimonyExe(e: Env): string =
  result = joinPath(e.nimony, "bin\\nimony.exe")

# --------------------------------------------------------------- mods

proc sourceOf(modPath: string): string =
  ## A mod directory holds `<name>.nim`; a path to a `.nim` is taken as is.
  if fileExists(modPath) and modPath.endsWith(".nim"):
    return modPath
  if not isDirectory(modPath):
    return ""
  let stem = baseName(modPath)
  let guess = joinPath(modPath, stem & ".nim")
  if fileExists(guess):
    return guess
  var files: seq[string] = @[]
  var dirs: seq[string] = @[]
  collectEntries(modPath, files, dirs)
  var found = ""
  var count = 0
  for f in files:
    if f.endsWith(".nim") and find(f, "\\") < 0:
      found = joinPath(modPath, f)
      inc count
  if count == 1:
    result = found
  else:
    result = ""

proc placeLibrary(dir, stem, outPath: string): bool

proc buildMod(e: Env; modPathIn: string): bool =
  let modPath = absolutePathOf(modPathIn)
  let source = sourceOf(modPath)
  if source.len == 0:
    err "no single .nim source in " & modPath
    inc failures
    return false

  let dir = parentOf(source)
  var stem = baseName(source)
  stem = stem.substr(0, stem.len - 5)   # drop ".nim"
  let binDir = joinPath(dir, "bin")
  discard ensureDir(binDir)
  let outPath = joinPath(binDir, stem & ".dll")
  # Removed before the compile, not after. `placeLibrary` treats an existing
  # output as "nimony honoured -o:" and returns early -- so a leftover from the
  # previous build satisfies that check and the new code is never copied out of
  # nimcache. The compile reports success and the stale binary ships.
  discard removeFileAt(outPath)

  var cmd = quoted(nimonyExe(e))
  cmd.add " c --app:lib"
  # Mods get the ABI include path too.
  #
  # They did not, and the consequence was invisible until someone tried: a mod
  # cannot `import aowlspt/il2cpp` or `aowlspt/fast` without it, because those
  # reach the runtime through the C shims in `abi/`. So the fast path -- the
  # whole reason a native mod beats the C# it replaces -- was unreachable from
  # the one place it was for.
  cmd.add abiInclude(e)
  if e.debugBuild:
    cmd.add " -d:debug"
  cmd.add " -p:" & quoted(joinPath(e.repo, "aowl\\src"))
  cmd.add " -p:" & quoted(joinPath(e.nimony, "src\\lib"))
  cmd.add " -o:" & quoted(outPath)
  cmd.add " " & quoted(source)
  if not run(e, "mod " & stem, cmd, dir):
    # One retry with the cache cleared.
    #
    # nimony's incremental cache does not always survive a source file being
    # added to a mod: the build fails at the link step with an undefined string
    # literal, which reads like a code error and is not one. A developer who
    # does not know that loses an hour to it; the tool knows it, so it clears
    # the cache and tries again, and only a second failure is real.
    let cache = joinPath(dir, "nimcache")
    if not isDirectory(cache):
      return false
    note "retrying " & stem & " with a cleared build cache"
    discard winfs.removeTree(cache)
    dec failures
    if not run(e, "mod " & stem & " (retry)", cmd, dir):
      return false

  result = placeLibrary(dir, stem, outPath)

proc placeLibrary(dir, stem, outPath: string): bool =
  # `-o:` does not reach a `--app:lib` build. nimony writes the shared library
  # into `nimcache/<hash>/` and leaves it there, so the last step of building a
  # library is finding it and putting it where the loader looks. Without this
  # the compile reports success and the library is simply absent, which is a
  # much worse failure than a compile error.
  if fileExists(outPath):
    return true

  let cache = joinPath(dir, "nimcache")
  var files: seq[string] = @[]
  var dirs: seq[string] = @[]
  collectEntries(cache, files, dirs)

  var newest = ""
  var newestSize = -1'i64
  for f in files:
    if baseName(f) != stem & ".dll":
      continue
    let full = joinPath(cache, f)
    let sz = fileSizeOf(full)
    if sz > newestSize:
      newestSize = sz
      newest = full

  if newest.len == 0:
    err stem & ": compiled, but no " & stem & ".dll under " & cache
    inc failures
    return false

  let copied = copyFileAt(newest, outPath)
  if not copied.ok:
    err stem & ": could not place the library (error " & $copied.err & ")"
    inc failures
    return false
  detail newest & " -> " & outPath
  result = true

# --------------------------------------------------------------- hosts

proc simExe(e: Env): string =
  ## One place that knows where the simulator lands, because three callers ask.
  result = joinPath(e.repo, "host\\Aowlspt.Sim\\bin\\aowlspt-sim.exe")

proc buildHosts(e: Env): bool =
  ## The simulator. It used to be C# -- the last C# host in the repo -- and it
  ## is a nimony host now, built out of the same `host/common` loader the
  ## backend and the client host use. It wants three source trees the other
  ## tools do not: `host/common` for the loader, the store and the JSON path
  ## reader, and `backend` for `jsondb`, so that `--db` and `db_patch` mean
  ## here exactly what they mean on the server.
  let dir = joinPath(e.repo, "host\\Aowlspt.Sim")
  let source = joinPath(dir, "aowlsim.nim")
  if not fileExists(source):
    err "no aowlsim.nim under " & dir
    inc failures
    return false
  discard ensureDir(joinPath(dir, "bin"))
  let outPath = simExe(e)
  discard removeFileAt(outPath)

  var cmd = quoted(nimonyExe(e))
  cmd.add " c"
  cmd.add abiInclude(e)
  if e.debugBuild:
    cmd.add " -d:debug"
  cmd.add " -p:" & quoted(joinPath(e.repo, "host\\common"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "backend"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "installer\\src"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "aowl\\src"))
  cmd.add " -o:" & quoted(outPath)
  cmd.add " " & quoted(source)
  result = run(e, "aowlspt-sim", cmd, dir)

proc buildDotnetTools(e: Env): bool =
  ## What is left of the .NET side: `tools/SptReflect`, which reads SPT's
  ## assemblies with `MetadataLoadContext` and is the only thing that
  ## regenerates `reference/`. It stays C# because the thing it does is read
  ## .NET metadata, and it stays in the gate so that it keeps compiling.
  let sln = joinPath(e.repo, "aowlspt.sln")
  if not fileExists(sln):
    err "no aowlspt.sln at " & e.repo
    inc failures
    return false
  let config = if e.debugBuild: "Debug" else: "Release"
  result = run(e, "the .NET tools (" & config & ")",
               "dotnet build " & quoted(sln) & " -c " & config & " --nologo -v q")

# --------------------------------------------------------------- il2cpp

proc abiInclude(e: Env): string =
  ## The nimony hosts and tools `#include` the C shims in `abi/`.
  result = " --passC:-I" & joinPath(e.repo, "abi")

proc buildIl2CppHost(e: Env): bool =
  let dir = joinPath(e.repo, "host\\Aowlspt.Host.Il2Cpp")
  let source = joinPath(dir, "aowlhost.nim")
  if not fileExists(source):
    err "no aowlhost.nim under " & dir
    inc failures
    return false
  let binDir = joinPath(dir, "bin")
  discard ensureDir(binDir)
  let outPath = joinPath(binDir, "aowlspt-host-il2cpp.dll")
  discard removeFileAt(outPath)

  var cmd = quoted(nimonyExe(e))
  cmd.add " c --app:lib"
  cmd.add abiInclude(e)
  if e.debugBuild:
    cmd.add " -d:debug"
  cmd.add " -p:" & quoted(joinPath(e.repo, "aowl\\src"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "installer\\src"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "host\\common"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "host\\Aowlspt.Overlay"))
  cmd.add " -o:" & quoted(outPath)
  cmd.add " " & quoted(source)
  if not run(e, "aowlspt-host-il2cpp", cmd, dir):
    return false
  result = placeLibrary(dir, "aowlhost", outPath)

proc buildOverlayTests(e: Env): bool =
  ## The overlay's four test binaries. This used to be
  ## `host/Aowlspt.Overlay/build.ps1`; it is here now because the repo has one
  ## toolchain, not two.
  ##
  ## They are built beside their sources rather than into `installer\build`:
  ## `overlayhost.exe` writes screenshots into `tests\overlayhost\shots` and
  ## reads nothing else, and none of the three ships.
  ##
  ##  * `overlayhost.exe` -- a D3D11 application that stands in for Tarkov.
  ##    Links d3d11/dxgi/user32 because *it* renders; the overlay itself does
  ##    not, which is what `linkprobe.exe` is for.
  ##  * `linkprobe.exe` -- the same header with **no** graphics library on the
  ##    command line. If a future edit grows a direct call to an imported
  ##    function this stops linking, and the injected host would have gained a
  ##    load-time dependency that fails silently mid-startup.
  ##  * `overlaynimtest.exe` -- the nimony side of the boundary.
  ##
  ## `-Wno-unused-function`: the header is header-only, so a translation unit
  ## that uses part of it carries the rest as unreferenced statics.
  let dir = joinPath(e.repo, "tests\\overlayhost")
  if not fileExists(joinPath(dir, "overlayhost.c")):
    err "no overlayhost.c under " & dir
    inc failures
    return false
  let inc = quoted(joinPath(e.repo, "abi"))
  discard ensureDir(joinPath(dir, "shots"))

  var okAll = run(e, "overlayhost",
    "gcc -O1 -g -Wno-unused-function -I" & inc & " " &
    quoted(joinPath(dir, "overlayhost.c")) & " -o " &
    quoted(joinPath(dir, "overlayhost.exe")) & " -ld3d11 -ldxgi -luser32", dir)

  # The JSON reader on its own, against captured manager bodies: no device, no
  # sockets, no window. It is where a parser bug is *legible* -- through the
  # rendered panel the same bug is a blank column in a bitmap.
  if not run(e, "the overlay reads the manager's JSON",
    "gcc -O1 -Wno-unused-function -I" & inc & " " &
    quoted(joinPath(dir, "jsontest.c")) & " -o " &
    quoted(joinPath(dir, "jsontest.exe")), dir):
    okAll = false
  elif not run(e, "overlay json checks", quoted(joinPath(dir, "jsontest.exe")), dir):
    okAll = false

  if not run(e, "overlay header needs no extra link library",
    "gcc -O1 -Wno-unused-function -I" & inc & " " &
    quoted(joinPath(dir, "linkprobe.c")) & " -o " &
    quoted(joinPath(dir, "linkprobe.exe")), dir):
    okAll = false

  var cmd = quoted(nimonyExe(e))
  cmd.add " c"
  cmd.add abiInclude(e)
  cmd.add " -p:" & quoted(joinPath(e.repo, "host\\Aowlspt.Overlay"))
  cmd.add " -o:" & quoted(joinPath(dir, "overlaynimtest.exe"))
  cmd.add " " & quoted(joinPath(dir, "overlaynimtest.nim"))
  if not run(e, "overlaynimtest", cmd, dir):
    okAll = false
  result = okAll

proc buildBackend(e: Env): bool =
  ## The backend links winsock and zlib; nothing else in the repo does, which
  ## is why it has its own build rather than going through `buildTool`.
  let dir = joinPath(e.repo, "backend")
  let binDir = joinPath(dir, "bin")
  discard ensureDir(binDir)
  let outPath = joinPath(binDir, "aowlspt-backend.exe")
  discard removeFileAt(outPath)

  var cmd = quoted(nimonyExe(e))
  cmd.add " c"
  cmd.add abiInclude(e)
  cmd.add " --passL:-lws2_32 --passL:-lz"
  if e.debugBuild:
    cmd.add " -d:debug"
  cmd.add " -p:" & quoted(dir)
  cmd.add " -p:" & quoted(joinPath(e.repo, "host\\common"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "installer\\src"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "aowl\\src"))
  cmd.add " -o:" & quoted(outPath)
  cmd.add " " & quoted(joinPath(dir, "aowlbackend.nim"))
  result = run(e, "aowlspt-backend", cmd, dir)

proc buildProbe(e: Env): bool =
  let outDir = joinPath(e.repo, "installer\\build")
  discard ensureDir(outDir)
  var cmd = quoted(nimonyExe(e))
  cmd.add " c"
  cmd.add abiInclude(e)
  cmd.add " --passL:-lws2_32 --passL:-lz"
  cmd.add " -p:" & quoted(joinPath(e.repo, "backend"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "installer\\src"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "aowl\\src"))
  cmd.add " -o:" & quoted(joinPath(outDir, "aowlprobe.exe"))
  cmd.add " " & quoted(joinPath(e.repo, "tools\\aowlprobe.nim"))
  result = run(e, "aowlprobe", cmd, e.repo)

proc buildPerfBench(e: Env): bool =
  ## The client-side benchmark. It wants two things `buildTool` does not give:
  ## the fast path's bench fixture (compiled methods with real signatures, which
  ## the stand-in runtime does not carry), and the host's own `invoke` for the
  ## boxed path it measures against.
  let outDir = joinPath(e.repo, "installer\\build")
  discard ensureDir(outDir)
  var cmd = quoted(nimonyExe(e))
  cmd.add " c"
  cmd.add abiInclude(e)
  cmd.add " --passC:-DAOWLSPT_FAST_BENCH"
  cmd.add " -p:" & quoted(joinPath(e.repo, "installer\\src"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "aowl\\src"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "host\\Aowlspt.Host.Il2Cpp"))
  cmd.add " -o:" & quoted(joinPath(outDir, "perfbench.exe"))
  cmd.add " " & quoted(joinPath(e.repo, "tools\\perfbench.nim"))
  result = run(e, "perfbench", cmd, e.repo)

proc buildSoak(e: Env): bool =
  ## `soak`: the emulator over a long session. Same shape as `emutest` -- it
  ## speaks the client's wire protocol, so it wants `wire.nim` out of the
  ## backend and the same two libraries.
  let outDir = joinPath(e.repo, "installer\\build")
  discard ensureDir(outDir)
  var cmd = quoted(nimonyExe(e))
  cmd.add " c"
  cmd.add abiInclude(e)
  cmd.add " --passL:-lws2_32 --passL:-lz"
  cmd.add " -p:" & quoted(joinPath(e.repo, "backend"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "installer\\src"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "aowl\\src"))
  cmd.add " -o:" & quoted(joinPath(outDir, "soak.exe"))
  cmd.add " " & quoted(joinPath(e.repo, "tools\\soak.nim"))
  result = run(e, "soak", cmd, e.repo)

proc buildEmuTest(e: Env): bool =
  ## Same shape as the probe: it speaks the client's wire protocol, so it wants
  ## `wire.nim` out of the backend and the same two libraries.
  let outDir = joinPath(e.repo, "installer\\build")
  discard ensureDir(outDir)
  var cmd = quoted(nimonyExe(e))
  cmd.add " c"
  cmd.add abiInclude(e)
  cmd.add " --passL:-lws2_32 --passL:-lz"
  cmd.add " -p:" & quoted(joinPath(e.repo, "backend"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "installer\\src"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "aowl\\src"))
  cmd.add " -o:" & quoted(joinPath(outDir, "emutest.exe"))
  cmd.add " " & quoted(joinPath(e.repo, "tools\\emutest.nim"))
  result = run(e, "emutest", cmd, e.repo)

proc buildRealTest(e: Env): bool =
  ## `realtest`: the emulator against an *imported* database rather than the
  ## fixture. Same shape as `emutest` -- it speaks the client's wire protocol,
  ## so it wants `wire.nim` out of the backend and the same two libraries.
  let outDir = joinPath(e.repo, "installer\\build")
  discard ensureDir(outDir)
  var cmd = quoted(nimonyExe(e))
  cmd.add " c"
  cmd.add abiInclude(e)
  cmd.add " --passL:-lws2_32 --passL:-lz"
  cmd.add " -p:" & quoted(joinPath(e.repo, "backend"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "installer\\src"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "aowl\\src"))
  cmd.add " -o:" & quoted(joinPath(outDir, "realtest.exe"))
  cmd.add " " & quoted(joinPath(e.repo, "tools\\realtest.nim"))
  result = run(e, "realtest", cmd, e.repo)

proc buildStoreCrash(e: Env): bool =
  ## `storecrash`: kills a process in the middle of a store write. It links the
  ## store itself rather than driving a server, so it wants `host\\common` on
  ## the path -- and none of the network libraries, because it never opens a
  ## socket.
  let outDir = joinPath(e.repo, "installer\\build")
  discard ensureDir(outDir)
  var cmd = quoted(nimonyExe(e))
  cmd.add " c"
  cmd.add abiInclude(e)
  cmd.add " -p:" & quoted(joinPath(e.repo, "host\\common"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "installer\\src"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "aowl\\src"))
  cmd.add " -o:" & quoted(joinPath(outDir, "storecrash.exe"))
  cmd.add " " & quoted(joinPath(e.repo, "tools\\storecrash.nim"))
  result = run(e, "storecrash", cmd, e.repo)

proc buildFuzzWire(e: Env): bool =
  ## `fuzzwire`: the same wire, driven with input a client would never send.
  ## Same shape as `emutest` -- it speaks the protocol through `wire.nim`, and
  ## below it, so it wants the backend on the path and the same two libraries.
  let outDir = joinPath(e.repo, "installer\\build")
  discard ensureDir(outDir)
  var cmd = quoted(nimonyExe(e))
  cmd.add " c"
  cmd.add abiInclude(e)
  cmd.add " --passL:-lws2_32 --passL:-lz"
  cmd.add " -p:" & quoted(joinPath(e.repo, "backend"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "installer\\src"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "aowl\\src"))
  cmd.add " -o:" & quoted(joinPath(outDir, "fuzzwire.exe"))
  cmd.add " " & quoted(joinPath(e.repo, "tools\\fuzzwire.nim"))
  result = run(e, "fuzzwire", cmd, e.repo)

proc buildWsTest(e: Env): bool =
  ## `wstest`: the notifier websocket, end to end. Same shape as `fuzzwire` --
  ## it speaks the protocol below `wire.nim`, so it wants the backend on the
  ## path and the same two libraries.
  let outDir = joinPath(e.repo, "installer\\build")
  discard ensureDir(outDir)
  var cmd = quoted(nimonyExe(e))
  cmd.add " c"
  cmd.add abiInclude(e)
  cmd.add " --passL:-lws2_32 --passL:-lz"
  cmd.add " -p:" & quoted(joinPath(e.repo, "backend"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "installer\\src"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "aowl\\src"))
  cmd.add " -o:" & quoted(joinPath(outDir, "wstest.exe"))
  cmd.add " " & quoted(joinPath(e.repo, "tools\\wstest.nim"))
  result = run(e, "wstest", cmd, e.repo)

proc buildLiveCtl(e: Env): bool =
  ## `livectl`: enables and disables mods on a running backend and checks that
  ## the routes follow. Same shape as `emutest` -- it drives the server over the
  ## real wire, so it wants `wire.nim` out of the backend and the same two
  ## libraries.
  let outDir = joinPath(e.repo, "installer\\build")
  discard ensureDir(outDir)
  var cmd = quoted(nimonyExe(e))
  cmd.add " c"
  cmd.add abiInclude(e)
  cmd.add " --passL:-lws2_32 --passL:-lz"
  cmd.add " -p:" & quoted(joinPath(e.repo, "backend"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "installer\\src"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "aowl\\src"))
  cmd.add " -o:" & quoted(joinPath(outDir, "livectl.exe"))
  cmd.add " " & quoted(joinPath(e.repo, "tools\\livectl.nim"))
  result = run(e, "livectl", cmd, e.repo)

proc buildOvSync(e: Env): bool =
  ## `ovsync`: the *client* half of live mod control, over the real worker
  ## thread out of `abi/aowlspt_overlay.h`. It wants more paths than any other
  ## gate here because it is the only program that holds all three pieces at
  ## once -- `wire.nim` to drive the manager, `modcontrol.nim` to read what
  ## comes back, and `aowloverlay.nim` to be the thing that fetches it.
  let outDir = joinPath(e.repo, "installer\\build")
  discard ensureDir(outDir)
  var cmd = quoted(nimonyExe(e))
  cmd.add " c"
  cmd.add abiInclude(e)
  cmd.add " --passL:-lws2_32 --passL:-lz"
  cmd.add " -p:" & quoted(joinPath(e.repo, "backend"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "host\\common"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "host\\Aowlspt.Overlay"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "installer\\src"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "aowl\\src"))
  cmd.add " -o:" & quoted(joinPath(outDir, "ovsync.exe"))
  cmd.add " " & quoted(joinPath(e.repo, "tests\\ovsync\\ovsync.nim"))
  result = run(e, "ovsync", cmd, e.repo)

proc buildAllMods(e: Env): bool =
  ## `allmods`: every mod the registry names, in one backend at once. Same
  ## shape as `emutest` -- it drives the server over the real wire, so it wants
  ## `wire.nim` out of the backend and the same two libraries. It stages its own
  ## roots out of the checkout rather than being handed one, because it needs a
  ## dozen of them: a baseline, a pair and a solo run per mod, and the all-mods
  ## run every one of those is compared against.
  let outDir = joinPath(e.repo, "installer\\build")
  discard ensureDir(outDir)
  var cmd = quoted(nimonyExe(e))
  cmd.add " c"
  cmd.add abiInclude(e)
  cmd.add " --passL:-lws2_32 --passL:-lz"
  cmd.add " -p:" & quoted(joinPath(e.repo, "backend"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "installer\\src"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "aowl\\src"))
  cmd.add " -o:" & quoted(joinPath(outDir, "allmods.exe"))
  cmd.add " " & quoted(joinPath(e.repo, "tools\\allmods.nim"))
  result = run(e, "allmods", cmd, e.repo)

proc buildModResolve(e: Env): bool =
  ## `modresolve`: the mod manager's rules, with no server under them. Same
  ## shape as `emutest` minus the network -- it imports `mods\manager\mgr`
  ## directly and never opens a socket, which is what lets it be exhaustive:
  ## every verdict, every cycle, and every shape of damaged selection file, in
  ## a few milliseconds and with nothing to stage.
  let outDir = joinPath(e.repo, "installer\\build")
  discard ensureDir(outDir)
  var cmd = quoted(nimonyExe(e))
  cmd.add " c"
  cmd.add abiInclude(e)
  cmd.add " -p:" & quoted(joinPath(e.repo, "mods\\manager\\mgr"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "installer\\src"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "aowl\\src"))
  cmd.add " -o:" & quoted(joinPath(outDir, "modresolve.exe"))
  cmd.add " " & quoted(joinPath(e.repo, "tools\\modresolve.nim"))
  result = run(e, "modresolve", cmd, e.repo)

proc buildBench(e: Env): bool =
  ## `benchbackend`: the load generator. Same shape as `emutest` -- it drives
  ## the backend over the real wire, so it wants `wire.nim` out of the backend
  ## and the same two libraries. It is built here rather than by hand because a
  ## performance number that takes a remembered command line to reproduce is a
  ## number that stops being reproduced.
  let outDir = joinPath(e.repo, "installer\\build")
  discard ensureDir(outDir)
  var cmd = quoted(nimonyExe(e))
  cmd.add " c"
  cmd.add abiInclude(e)
  cmd.add " --passL:-lws2_32 --passL:-lz"
  cmd.add " -p:" & quoted(joinPath(e.repo, "backend"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "installer\\src"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "aowl\\src"))
  cmd.add " -o:" & quoted(joinPath(outDir, "benchbackend.exe"))
  cmd.add " " & quoted(joinPath(e.repo, "tools\\benchbackend.nim"))
  result = run(e, "benchbackend", cmd, e.repo)

proc buildVerifyInstall(e: Env): bool =
  ## `aowlspt-verify`: points at an installed tree, checks it is coherent, then
  ## starts its backend on a spare port and drives it over the wire. Same shape
  ## as `emutest` because it speaks the same protocol.
  let outDir = joinPath(e.repo, "installer\\build")
  discard ensureDir(outDir)
  var cmd = quoted(nimonyExe(e))
  cmd.add " c"
  cmd.add abiInclude(e)
  cmd.add " --passL:-lws2_32 --passL:-lz"
  cmd.add " -p:" & quoted(joinPath(e.repo, "backend"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "installer\\src"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "aowl\\src"))
  cmd.add " -o:" & quoted(joinPath(outDir, "aowlspt-verify.exe"))
  cmd.add " " & quoted(joinPath(e.repo, "tools\\verifyinstall.nim"))
  result = run(e, "aowlspt-verify", cmd, e.repo)

proc buildFirstRun(e: Env): bool =
  ## `firstrun`: the whole first-run path in order -- a synthetic vanilla
  ## client, payload, install, importdb, verify, the client's boot sequence,
  ## live mod control, and a restart with the profile still in it. Same shape
  ## as `emutest` because the last four steps are over the same wire.
  ##
  ## Built here, and deliberately **not** run by `aowl test`: a full walk takes
  ## about three minutes, most of it the real mod set loading a 39 MiB database,
  ## and a gate that costs three minutes on every run is a gate somebody
  ## comments out. Run it by hand before a release, and after any change to the
  ## installer, the payload or the database step:
  ##
  ##     installer\build\firstrun.exe --scratch C:\scratch\firstrun
  ##
  ## It exits 0 with an explanation when there is no SPT install to import a
  ## database from, which is most machines.
  let outDir = joinPath(e.repo, "installer\\build")
  discard ensureDir(outDir)
  var cmd = quoted(nimonyExe(e))
  cmd.add " c"
  cmd.add abiInclude(e)
  cmd.add " --passL:-lws2_32 --passL:-lz"
  cmd.add " -p:" & quoted(joinPath(e.repo, "backend"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "installer\\src"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "aowl\\src"))
  cmd.add " -o:" & quoted(joinPath(outDir, "firstrun.exe"))
  cmd.add " " & quoted(joinPath(e.repo, "tools\\firstrun.nim"))
  result = run(e, "firstrun", cmd, e.repo)

proc buildTool(e: Env; source, exeName, label: string): bool =
  ## The nimony command-line tools. All of them want the ABI include path and
  ## both source trees; keeping that in one place stops them drifting apart.
  let outDir = joinPath(e.repo, "installer\\build")
  discard ensureDir(outDir)
  var cmd = quoted(nimonyExe(e))
  cmd.add " c"
  cmd.add abiInclude(e)
  if e.debugBuild:
    cmd.add " -d:debug"
  cmd.add " -p:" & quoted(joinPath(e.repo, "installer\\src"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "aowl\\src"))
  cmd.add " -o:" & quoted(joinPath(outDir, exeName))
  cmd.add " " & quoted(joinPath(e.repo, source))
  result = run(e, label, cmd, e.repo)

# --------------------------------------------------------------- installer

proc buildInstaller(e: Env): bool =
  let dir = joinPath(e.repo, "installer")
  discard ensureDir(joinPath(dir, "build"))
  var cmd = quoted(nimonyExe(e))
  cmd.add " c"
  if e.debugBuild:
    cmd.add " -d:debug"
  cmd.add " -p:" & quoted(joinPath(dir, "src"))
  cmd.add " -o:" & quoted(joinPath(dir, "build\\aowlspt-install.exe"))
  cmd.add " " & quoted(joinPath(dir, "src\\aowlsptinstall.nim"))
  result = run(e, "aowlspt-install", cmd)

proc buildInstallerTests(e: Env): bool =
  let dir = joinPath(e.repo, "installer")
  discard ensureDir(joinPath(dir, "build"))
  var cmd = quoted(nimonyExe(e))
  cmd.add " c -p:" & quoted(joinPath(dir, "src"))
  cmd.add " -o:" & quoted(joinPath(dir, "build\\test-installer.exe"))
  cmd.add " " & quoted(joinPath(dir, "tests\\test_installer.nim"))
  result = run(e, "installer tests (compile)", cmd)

# --------------------------------------------------------------- examples

proc exampleDirs(e: Env): seq[string] =
  result = @[]
  let examples = joinPath(e.repo, "examples")
  if not isDirectory(examples):
    return
  var files: seq[string] = @[]
  var dirs: seq[string] = @[]
  collectEntries(examples, files, dirs)
  for d in dirs:
    if find(d, "\\") >= 0:
      continue
    if d == "bin" or d == "nimcache":
      continue
    result.add joinPath(examples, d)

proc modDirs(e: Env): seq[string] =
  ## Every mod under `mods/`. Separate from `examples/` because these are real
  ## mods rather than teaching material -- the emulator, and the ports -- and
  ## because `aowl build` should not quietly stop covering them the moment one
  ## more appears.
  result = @[]
  let root = joinPath(e.repo, "mods")
  if not isDirectory(root):
    return
  var files: seq[string] = @[]
  var dirs: seq[string] = @[]
  collectEntries(root, files, dirs)
  for d in dirs:
    if find(d, "\\") >= 0:
      continue
    if d == "bin" or d == "nimcache":
      continue
    result.add joinPath(root, d)

# --------------------------------------------------------------- commands

proc abiStamp(e: Env): string =
  ## A fingerprint of the C shims in `abi/`: a rolling hash of each header's
  ## contents. Contents rather than timestamps, because a checkout or a revert
  ## restores an old header with a new time, and hashing is the version that
  ## says "the same bytes as last build" rather than "touched since".
  var files: seq[string] = @[]
  var dirs: seq[string] = @[]
  let abiDir = joinPath(e.repo, "abi")
  collectEntries(abiDir, files, dirs)
  var total = 0
  var count = 0
  for f in files:
    if not f.endsWith(".h"): continue
    var text = ""
    if not readTextFile(joinPath(abiDir, f), text):
      continue
    inc count
    var h = 5381
    for ch in f:
      h = ((h * 33) + ord(ch)) and 0x3FFFFFFF
    for ch in text:
      h = ((h * 33) + ord(ch)) and 0x3FFFFFFF
    # Summed rather than combined in order: `collectEntries` does not promise
    # one, and a stamp that changes when the directory is walked differently
    # would drop every cache for nothing.
    total = (total + h) and 0x3FFFFFFF
  result = $count & ":" & $total

proc dropStaleCaches(e: Env) =
  ## nimony tracks its own sources and knows nothing about a `#include` reached
  ## through `--passC:-I`. Edit a header in `abi/` and every build reports
  ## success while linking the object files compiled against the old one -- which
  ## is how a mod ends up talking to a host API two fields shorter than it
  ## thinks, with no error anywhere. So the headers are fingerprinted, and a
  ## change throws the caches away.
  let stampPath = joinPath(joinPath(e.repo, "installer"), "build\\.abistamp")
  let now = abiStamp(e)
  var was = ""
  discard readTextFile(stampPath, was)
  if was == now:
    return
  var roots: seq[string] = @[e.repo,
                             joinPath(e.repo, "backend"),
                             joinPath(e.repo, "host\\Aowlspt.Host.Il2Cpp"),
                             joinPath(e.repo, "installer"),
                             joinPath(e.repo, "mods\\tarkov")]
  let mods = exampleDirs(e)
  for m in mods:
    roots.add m
  var dropped = 0
  for r in roots:
    let cache = joinPath(r, "nimcache")
    if isDirectory(cache):
      discard winfs.removeTree(cache)
      inc dropped
  if was.len > 0 and dropped > 0:
    note "the ABI headers changed; dropped " & $dropped & " build cache(s)"
  discard ensureDir(joinPath(joinPath(e.repo, "installer"), "build"))
  discard writeTextFile(stampPath, now)

proc cmdBuild(e: Env): int =
  dropStaleCaches(e)
  heading "Simulator"
  discard buildHosts(e)
  discard buildDotnetTools(e)
  heading "Host (IL2CPP, native)"
  discard buildIl2CppHost(e)
  discard buildOverlayTests(e)
  heading "Backend"
  discard buildBackend(e)
  discard buildProbe(e)
  discard buildEmuTest(e)
  discard buildRealTest(e)
  discard buildSoak(e)
  discard buildBench(e)
  discard buildVerifyInstall(e)
  discard buildFirstRun(e)
  discard buildPerfBench(e)
  heading "Tools"
  discard buildInstaller(e)
  discard buildTool(e, "tools\\aowllaunch.nim", "aowlspt-launch.exe",
                    "aowlspt-launch")
  discard buildTool(e, "tools\\il2cppprobe.nim", "il2cppprobe.exe",
                    "il2cppprobe")
  discard buildTool(e, "tools\\hostharness.nim", "hostharness.exe",
                    "hostharness")
  heading "Examples"
  let mods = exampleDirs(e)
  for m in mods:
    discard buildMod(e, m)
  heading "Mods"
  let real = modDirs(e)
  for m in real:
    discard buildMod(e, m)
  result = if failures > 0: 1 else: 0

proc report(what: string; ok1: bool; detail: string; problems: var int) =
  ## A free proc with the counter passed in, rather than a nested one closing
  ## over it: nimony will not let a nested proc touch its enclosing scope's
  ## variables without being made a closure.
  if ok1:
    ok what
  else:
    err what & ": " & detail
    inc problems

proc cmdDoctor(e: Env): int =
  ## Checks the toolchain before it can waste anyone's afternoon.
  ##
  ## Every item here is something that has actually gone wrong and cost real
  ## time, and each failed in a way that pointed somewhere else: a build that
  ## dies with no diagnostic, a link that cannot find a symbol in the file it is
  ## reading, a mod that talks to a struct two fields shorter than it thinks.
  ## A check that has never caught anything does not belong in this list.
  heading "Toolchain"
  var problems = 0
  let nimony = nimonyExe(e)
  report("nimony", fileExists(nimony), "not at " & nimony, problems)

  let ucrt = joinPath(e.ucrt64, "gcc.exe")
  report("ucrt64 gcc", fileExists(ucrt), "not at " & ucrt, problems)

  # The ordering trap. gcc finds cc1 and its libraries relative to PATH, so a
  # Git-for-Windows mingw64 ahead of ucrt64 gives a cc1 that loads the wrong
  # libgcc and dies with **no message at all** -- the build simply stops.
  let pathVar = getEnv("PATH", "")
  var ucrtAt = find(toLowerAscii(pathVar), toLowerAscii(e.ucrt64))
  var gitAt = find(toLowerAscii(pathVar), "git" & chr(92) & "mingw64")
  if gitAt < 0:
    gitAt = find(toLowerAscii(pathVar), "git/mingw64")
  if gitAt >= 0 and (ucrtAt < 0 or ucrtAt > gitAt):
    err "PATH has Git's mingw64 ahead of ucrt64"
    note "gcc then loads the wrong cc1 and dies with no diagnostic at all"
    inc problems
  else:
    ok "PATH order (ucrt64 before any Git mingw64)"

  let lld = joinPath(e.ucrt64, "ld.lld.exe")
  report("lld", fileExists(lld),
         "nimony passes -fuse-ld=lld on Windows and the link will fail without it",
         problems)

  report("the ABI headers", isDirectory(joinPath(e.repo, "abi")),
         "no abi/ directory under " & e.repo, problems)

  # The stale-cache trap, checked rather than assumed: if the recorded header
  # fingerprint does not match the headers, the next build would link against
  # the old ones. `dropStaleCaches` fixes it -- this says so before it bites.
  let stampPath = joinPath(joinPath(e.repo, "installer"), "build\\.abistamp")
  var was = ""
  discard readTextFile(stampPath, was)
  if was.len > 0 and was != abiStamp(e):
    warn "the C headers changed since the last build; caches will be dropped"
  else:
    ok "build caches match the headers"

  heading "Result"
  if problems > 0:
    err $problems & " problem(s)"
    return 1
  ok "the toolchain is fit to build with"
  result = 0

proc cmdTest(e: Env): int =
  dropStaleCaches(e)
  heading "ABI layout (C)"
  let testsDir = joinPath(e.repo, "tests")
  let cExe = joinPath(testsDir, "abi_layout_c.exe")
  if run(e, "compile abi_layout.c",
         "gcc -I" & quoted(joinPath(e.repo, "abi")) & " -o " & quoted(cExe) &
         " " & quoted(joinPath(testsDir, "abi_layout.c"))):
    discard run(e, "abi_layout (C)", quoted(cExe))

  heading "ABI layout (nimony)"
  let nimExe = joinPath(testsDir, "abi_layout_nim.exe")
  var cmd = quoted(nimonyExe(e))
  cmd.add " c -p:" & quoted(joinPath(e.repo, "aowl\\src"))
  cmd.add " -o:" & quoted(nimExe) & " "
  cmd.add quoted(joinPath(testsDir, "abi_layout.nim"))
  if run(e, "compile abi_layout.nim", cmd):
    discard run(e, "abi_layout (nimony)", quoted(nimExe))

  heading "Simulator"
  discard buildHosts(e)
  discard buildDotnetTools(e)

  heading "Installer"
  if buildInstallerTests(e):
    discard run(e, "installer tests",
                quoted(joinPath(e.repo, "installer\\build\\test-installer.exe")))

  heading "Detour engine"
  let detourExe = joinPath(testsDir, "detour_test.exe")
  if run(e, "compile detour_test.c",
         "gcc -I" & quoted(joinPath(e.repo, "abi")) & " -O1 -o " &
         quoted(detourExe) & " " &
         quoted(joinPath(testsDir, "detour_test.c"))):
    discard run(e, "detour_test", quoted(detourExe))

  # And the same engine with the patch moving underneath the callers. Six
  # threads call a patched function while another installs and removes the
  # patch, and it asserts on the **answers**: a vectored handler turns an
  # access violation into a counted, classified number instead of a dead
  # process, and every worker checks every return against what the function
  # must produce.
  #
  # Before the trampoline was retired rather than freed, this reported 1726
  # faults inside unmapped memory and 328 calls answered with a zero the method
  # never returns -- five runs out of five. `detour_test` above passed
  # throughout: it installs, fires and removes in one thread, which is the one
  # arrangement in which freeing a trampoline is safe.
  let raceExe = joinPath(testsDir, "detour_race.exe")
  if run(e, "compile detour_race.c",
         "gcc -I" & quoted(joinPath(e.repo, "abi")) & " -O1 -o " &
         quoted(raceExe) & " " &
         quoted(joinPath(testsDir, "detour_race.c"))):
    discard run(e, "a patch installed and removed under live callers never " &
                   "answers wrongly", quoted(raceExe))
    # And the same run again with the test's own park switched off, so the
    # engine is alone with the fourteen-byte prologue write. That write is not
    # atomic -- a thread entering the function while it is going in executes
    # half of one instruction and half of another -- and `aowl_hook_arm` and
    # `aowl_hook_remove` now suspend every other thread in the process across
    # it, retry until nobody is standing in the bytes, and fall back to the
    # unparked write rather than ever spinning forever.
    #
    # This mode asserts the prologue fault count is zero, which the first mode
    # cannot: there the test parks the workers itself and would report zero
    # whatever the engine did. Built against the engine before the park went
    # in, it reports 368 prologue faults and fails; with the park, none over
    # ~14000 install/remove cycles against the control's 20000 -- same order,
    # which is what makes the zero worth having. Threads are found with
    # `ntdll!NtGetNextThread`; the `CreateToolhelp32Snapshot` fallback costs two
    # milliseconds a park and got the same run 52 cycles, so the mode also
    # checks that it raced.
    discard run(e, "the engine's own park keeps live callers out of the " &
                   "prologue it rewrites", quoted(raceExe) & " --engine-park")

  heading "IL2CPP host"
  let haveHost = buildIl2CppHost(e)
  discard buildTool(e, "tools\\aowllaunch.nim", "aowlspt-launch.exe",
                    "aowlspt-launch")
  discard buildTool(e, "tools\\il2cppprobe.nim", "il2cppprobe.exe",
                    "il2cppprobe")
  let haveHarness = buildTool(e, "tools\\hostharness.nim", "hostharness.exe",
                              "hostharness")

  # The host is exercised for real: staged into a scratch directory with a mod
  # beside it, then both loaded directly and injected into a live process.
  # Neither run has an IL2CPP runtime in it, which is the point -- the host has
  # to notice and carry on rather than take the process down.
  if haveHost and haveHarness:
    let stage = joinPath(e.repo, "installer\\build\\hoststage")
    discard winfs.removeTree(stage)
    discard ensureDir(joinPath(stage, "mods\\clientprobe"))
    discard copyFileAt(
      joinPath(e.repo, "host\\Aowlspt.Host.Il2Cpp\\bin\\aowlspt-host-il2cpp.dll"),
      joinPath(stage, "aowlspt-host-il2cpp.dll"))
    if buildMod(e, joinPath(e.repo, "examples\\clientprobe")):
      discard copyFileAt(
        joinPath(e.repo, "examples\\clientprobe\\bin\\clientprobe.dll"),
        joinPath(stage, "mods\\clientprobe\\clientprobe.dll"))
    # Seconds, not minutes: there is no game coming.
    discard writeTextFile(joinPath(stage, "aowlspt-host.json"),
                          "{\n  \"waitForRuntimeMs\": 2000\n}\n")

    let harness = quoted(joinPath(e.repo, "installer\\build\\hostharness.exe"))
    discard run(e, "host loads and runs a mod",
                harness & " " & quoted(stage) & " --seconds 10")
    discard run(e, "host survives injection into a live process",
                harness & " " & quoted(stage) & " --inject " &
                quoted(joinPath(e.repo, "installer\\build\\hostharness.exe")) &
                " --seconds 10")

    # And now against a runtime. The real IL2CPP cannot be started outside the
    # game, so a stand-in implementing the same C ABI is built and the host is
    # pointed at it — which is what exercises resolve, call and patch for real.
    # `tests/mockil2cpp` sets out what that does and does not establish.
    heading "Against a live runtime"
    let mockDir = joinPath(e.repo, "tests\\mockil2cpp")
    let mockDll = joinPath(mockDir, "GameAssembly.dll")
    if run(e, "build the stand-in runtime",
           "gcc -shared -O1 -o " & quoted(mockDll) & " " &
           quoted(joinPath(mockDir, "mockil2cpp.c"))):
      discard ensureDir(joinPath(stage, "mods\\highlevel"))
      if buildMod(e, joinPath(e.repo, "examples\\highlevel")):
        discard copyFileAt(
          joinPath(e.repo, "examples\\highlevel\\bin\\highlevel.dll"),
          joinPath(stage, "mods\\highlevel\\highlevel.dll"))
      discard run(e, "resolve, call and patch against a runtime",
                  harness & " " & quoted(stage) & " --runtime " &
                  quoted(mockDll) & " --seconds 8")

      # And the host's own half of a frame, which `perfbench` cannot see: it
      # never loads the host, so until this existed the per-frame cost of the
      # drain had never been timed at all. This runs *inside* a frame, on the
      # drain thread, out of a detoured per-frame method.
      #
      # Three of its lines are assertions rather than timings, and they are the
      # reason it belongs in the gate rather than in a notebook. The dispatch
      # count catches the failure that would otherwise make every row look
      # wonderful -- a drain that discards the queue instead of running it
      # benchmarks beautifully. The allocation count is the actual regression
      # guard: the drain reuses one buffer and allocates nothing per frame, and
      # against the shape it replaced this line reads 40000 and fails.
      discard run(e, "the host's own per-frame cost, and the drain allocating " &
                     "nothing to pay it",
                  harness & " " & quoted(stage) & " --runtime " &
                  quoted(mockDll) & " --frame-bench 20000")

      # The fast path, measured rather than asserted. It runs in the gate
      # because a performance claim that is not re-checked is a performance
      # claim that quietly stops being true.
      if buildPerfBench(e):
        discard run(e, "the fast path is measurably faster",
                    quoted(joinPath(e.repo, "installer\\build\\perfbench.exe")) &
                    " --runtime " & quoted(mockDll))

      # And the same host under churn. Everything above proves it can do a
      # thing once; this proves it can stop doing it -- a mod loaded and
      # unloaded, detours installed and removed past the size of the slot pool,
      # handles taken and given back, and every host table sampled as it goes
      # and judged on its *trend*. A leak is a slope, and the failures it finds
      # are the ones that end a raid rather than a launch.
      #
      # Its own stage, with clientprobe and nothing else in it: `highlevel`
      # patches almost every compiled method the mock has, and the churn run
      # needs three of them for itself.
      #
      # A hundred and twenty rounds, which is about five seconds on top of the
      # boot and the stall check. That is enough to prove every trend is flat
      # and not enough to be a claim about a session; the run says so itself in
      # its last line, and `--churn 2000` is what to type when it matters.
      let churnStage = joinPath(e.repo, "installer\\build\\churnstage")
      discard winfs.removeTree(churnStage)
      discard ensureDir(joinPath(churnStage, "mods\\clientprobe"))
      discard copyFileAt(
        joinPath(e.repo,
                 "host\\Aowlspt.Host.Il2Cpp\\bin\\aowlspt-host-il2cpp.dll"),
        joinPath(churnStage, "aowlspt-host-il2cpp.dll"))
      discard copyFileAt(
        joinPath(e.repo, "examples\\clientprobe\\bin\\clientprobe.dll"),
        joinPath(churnStage, "mods\\clientprobe\\clientprobe.dll"))
      discard writeTextFile(joinPath(churnStage, "aowlspt-host.json"),
                            "{\n  \"waitForRuntimeMs\": 2000\n}\n")
      discard run(e, "nothing the host holds grows with the cycle count",
                  harness & " " & quoted(churnStage) & " --runtime " &
                  quoted(mockDll) & " --churn 120")

  # The mod manager's rules, with nothing under them. Nothing is staged and
  # nothing is started: `modresolve` imports the manager's own `mgr` modules
  # and drives the resolver over registries it builds in memory -- every
  # verdict, every kind of cycle, every shape of damaged selection file -- so
  # it can be exhaustive where `livectl`, which needs a backend and three
  # built mods, is necessarily a scenario. It runs before anything is started,
  # because a resolver failure explains a `livectl` failure and not the other
  # way round, and because a test that needs no process is a test people run.
  heading "The mod manager's rules"
  if buildModResolve(e):
    discard run(e, "the resolver, the manifest reader and the selection " &
                   "store answer for every case",
                quoted(joinPath(e.repo, "installer\\build\\modresolve.exe")))

  # And what the manager refuses to *write down*, which is a different
  # question from what it resolves. Its worst failure was resolving nothing out
  # of a broken input and then recording that as the player's selection: the
  # next start loaded one mod out of ten, silently. A three-byte UTF-8 BOM on
  # `config.json` was enough, and Notepad writes one by default.
  #
  # Every check in here is a **pair** -- the input that must be refused and the
  # nearest input that must not be -- so a guard answering "" for everything,
  # or a sentence for everything, fails rather than passing quietly. Six
  # deliberate mutations of the guards were run against it and none escaped.
  let mgrGuardExe = joinPath(e.repo, "installer\\build\\mgrguard.exe")
  var mgCmd = quoted(nimonyExe(e))
  mgCmd.add " c"
  mgCmd.add abiInclude(e)
  mgCmd.add " -p:" & quoted(joinPath(e.repo, "mods\\manager\\mgr"))
  mgCmd.add " -p:" & quoted(joinPath(e.repo, "installer\\src"))
  mgCmd.add " -p:" & quoted(joinPath(e.repo, "aowl\\src"))
  mgCmd.add " -o:" & quoted(mgrGuardExe)
  mgCmd.add " " & quoted(joinPath(e.repo, "tests\\mgrguard\\mgrguard.nim"))
  if run(e, "mgrguard builds", mgCmd, e.repo):
    discard run(e, "the manager will not write a selection it resolved out of " &
                   "a broken input", quoted(mgrGuardExe))

  # And the other half of live control: what the **client** host says came of a
  # request. It drives `modcontrol`'s ledger directly -- no host, no runtime, no
  # server -- because the outcomes that matter are the ones a stage cannot
  # produce on demand: a mod with no teardown against one whose unload failed,
  # a library whose guid is not the guid asked for, and a row the backend has
  # stopped naming.
  #
  # The rule it exists to protect: there is no encoding for "no answer yet". A
  # guid with no record is unknown, and unknown may never be read as "off". A
  # truncated report, an old host and a host that has not polled all converge
  # on absence, so absence has to stay meaningless.
  let modReportExe = joinPath(e.repo, "installer\\build\\modreport.exe")
  var mrCmd = quoted(nimonyExe(e))
  mrCmd.add " c"
  mrCmd.add abiInclude(e)
  mrCmd.add " -p:" & quoted(joinPath(e.repo, "host\\common"))
  mrCmd.add " -p:" & quoted(joinPath(e.repo, "installer\\src"))
  mrCmd.add " -p:" & quoted(joinPath(e.repo, "aowl\\src"))
  mrCmd.add " -o:" & quoted(modReportExe)
  mrCmd.add " " & quoted(joinPath(e.repo, "tests\\modreport\\modreport.nim"))
  if run(e, "modreport builds", mrCmd, e.repo):
    discard run(e, "the client host's outcome report says what happened and " &
                   "never says it twice", quoted(modReportExe))

  # The reading half of the same protocol. Two programs, two gates: `modreport`
  # proves the host produces the wire and `modclient` proves the manager reads
  # it, and neither can cover for the other being wrong.
  #
  # What it is really guarding is the absence rule. There is no encoding for
  # "no answer yet" -- a row the rotation has not reached, a host that has not
  # polled, a process that has been replaced all arrive as *nothing* -- and the
  # manager may never render that as "off". Six of its checks fail the moment
  # absence is read as a negative, which is exactly the collapse this project
  # keeps shipping.
  let modClientExe = joinPath(e.repo, "installer\\build\\modclient.exe")
  var mcCmd = quoted(nimonyExe(e))
  mcCmd.add " c"
  mcCmd.add abiInclude(e)
  mcCmd.add " -p:" & quoted(joinPath(e.repo, "mods\\manager\\mgr"))
  mcCmd.add " -p:" & quoted(joinPath(e.repo, "installer\\src"))
  mcCmd.add " -p:" & quoted(joinPath(e.repo, "aowl\\src"))
  mcCmd.add " -o:" & quoted(modClientExe)
  mcCmd.add " " & quoted(joinPath(e.repo, "tests\\modclient\\modclient.nim"))
  if run(e, "modclient builds", mcCmd, e.repo):
    discard run(e, "the manager reads that report and never reads silence " &
                   "as a no", quoted(modClientExe))

  # And what a host does with a mod whose `on_update` fails, which for a long
  # time was nothing at all. `tickMods` was three lines that discarded the
  # status, so a mod failing on every frame of a raid did it in silence, with
  # nothing anywhere naming it -- while `docs/DEBUGGING.md` told a player to
  # search the log for `faulted, mod disabled`, a string that appeared nowhere
  # in the tree.
  #
  # Three fixture mods rather than one, and each is load-bearing: a mod that
  # fails every tick (the subject -- no mod in this repository returns anything
  # but `Ok`, which is exactly why the omission survived), a bystander loaded
  # *after* it that must be ticked all the same, and a flaky one that fails 150
  # times without ever failing twice in a row and must never be disabled. The
  # last is the threshold check: a count of total failures rather than
  # consecutive ones takes a working mod off the tick partway through a
  # session, and it was also what caught a log line written once per *run* of
  # failures -- a line every fourth frame, which is the flood this was meant to
  # avoid.
  #
  # Four mutations of `tickMods` were run against it: the honouring removed
  # (9 of 22 red), the threshold cut to 1 (5), the reset on success removed
  # (5), and the disable done by setting the draining flag instead (1 -- the
  # over-correction check, and the one that says a faulted mod's routes still
  # answer).
  #
  # Built with its working directory set to the fixture directory so its
  # nimcache lands beside it, and the fixtures go through `buildMod` rather
  # than a hand-rolled command because `-o:` does not reach an `--app:lib`
  # build: `placeLibrary` is what moves the DLL out of nimcache into `bin/`.
  var tickFaultMods = true
  for fixture in ["faultmod", "goodmod", "flakymod"]:
    if not buildMod(e, joinPath(e.repo, "tests\\tickfault\\" & fixture)):
      tickFaultMods = false
  if tickFaultMods:
    let tickFaultExe = joinPath(e.repo, "installer\\build\\tickfault.exe")
    var tfCmd = quoted(nimonyExe(e))
    tfCmd.add " c"
    tfCmd.add abiInclude(e)
    tfCmd.add " -p:" & quoted(joinPath(e.repo, "host\\common"))
    tfCmd.add " -p:" & quoted(joinPath(e.repo, "installer\\src"))
    tfCmd.add " -p:" & quoted(joinPath(e.repo, "aowl\\src"))
    tfCmd.add " -o:" & quoted(tickFaultExe)
    tfCmd.add " " & quoted(joinPath(e.repo, "tests\\tickfault\\tickfault.nim"))
    if run(e, "tickfault builds", tfCmd, joinPath(e.repo, "tests\\tickfault")):
      discard run(e, "a mod that fails every tick is named, dropped from the " &
                     "tick and left otherwise alone",
                  quoted(tickFaultExe) & " " &
                  quoted(joinPath(e.repo, "tests\\tickfault")))

  heading "Backend"
  let haveBackend = buildBackend(e)
  discard buildProbe(e)
  if haveBackend:
    # The backend is driven for real: a scratch install with a mod and a
    # database, then every route called over the wire — zlib framing included,
    # which is the part a plain HTTP client cannot check.
    let bstage = joinPath(e.repo, "installer\\build\\backendstage")
    discard winfs.removeTree(bstage)
    discard ensureDir(joinPath(bstage, "mods\\gameserver"))
    if buildMod(e, joinPath(e.repo, "examples\\gameserver")):
      discard copyFileAt(
        joinPath(e.repo, "examples\\gameserver\\bin\\gameserver.dll"),
        joinPath(bstage, "mods\\gameserver\\gameserver.dll"))
      discard copyFileAt(
        joinPath(e.repo, "examples\\gameserver\\config.json"),
        joinPath(bstage, "mods\\gameserver\\config.json"))
    discard writeTextFile(joinPath(bstage, "db.json"),
      "{\n" &
      "  \"templates\": { \"items\": {\n" &
      "    \"5447a9cd4bdc2dbd208b4567\": {\n" &
      "      \"_id\": \"5447a9cd4bdc2dbd208b4567\",\n" &
      "      \"_props\": { \"Name\": \"M4A1\", \"Weight\": 0.38 }\n" &
      "    }\n" &
      "  } }\n" &
      "}\n")
    # A port of its own, so a backend the developer already has running does
    # not make this fail — or worse, pass against the wrong server.
    discard run(e, "backend serves every route over the wire",
                quoted(joinPath(e.repo, "backend\\bin\\aowlspt-backend.exe")) &
                " --root " & quoted(bstage) & " --port 6974 --selftest")

    # And the database under concurrent readers and writers, which nothing else
    # here can see. Every other backend gate drives one connection at a time,
    # so a reader copying 12.5 MB out of a buffer a patch is reallocating
    # underneath it survives all of them -- the answer is wrong or the process
    # is gone, and neither shows up in a sequential run.
    #
    # It asserts on **answers**, not on survival: values nothing patches must
    # come back byte-identical, a patched value must be the old text or the new
    # one and never a splice of both, and a path that exists must never report
    # missing. Surviving a race proves nothing; a 404 for an item template is
    # what the player would actually see.
    let dbRaceExe = joinPath(e.repo, "backend\\bin\\dbrace.exe")
    var drCmd = quoted(nimonyExe(e))
    drCmd.add " c"
    drCmd.add abiInclude(e)
    drCmd.add " --passL:-lws2_32 --passL:-lz"
    drCmd.add " -p:" & quoted(joinPath(e.repo, "backend"))
    drCmd.add " -p:" & quoted(joinPath(e.repo, "installer\\src"))
    drCmd.add " -p:" & quoted(joinPath(e.repo, "aowl\\src"))
    drCmd.add " -o:" & quoted(dbRaceExe)
    drCmd.add " " & quoted(joinPath(e.repo, "backend\\dbrace.nim"))
    if run(e, "dbrace builds", drCmd, e.repo):
      discard run(e, "concurrent readers and writers on one database never " &
                     "see a wrong answer",
                  quoted(dbRaceExe) & " --readers 16 --writers 4 --seconds 8")

    # And the client that lies about how long its body is. `fuzzwire` covers
    # hostile *requests*; this covers hostile **framing**, which is a different
    # failure: when the framer and the parser agree on a wrong length, nothing
    # inside the server notices anything at all.
    #
    # It found a request-smuggling primitive. `Content-Length: 5abc` was read
    # as far as it parsed and the rest discarded -- by both sides identically
    # -- so the value was zero, the body was not consumed, and the bytes the
    # client sent as a body began the *next* request on the connection. One
    # keep-alive connection carrying `5abc` + `hello` + a well-formed request
    # came back with two answers, the second a 400 for a request line made out
    # of the first one's body. `-1`, `+5` and `0x10` gave two 200s.
    #
    # So the assertion that matters is not "did it survive" but **how many
    # answers came back**, counted by parsing each response's own
    # `Content-Length` out of the stream. 14 of its 102 checks fail against the
    # code as it was.
    let frameLenExe = joinPath(e.repo, "backend\\bin\\framelen.exe")
    var flCmd = quoted(nimonyExe(e))
    flCmd.add " c"
    flCmd.add abiInclude(e)
    flCmd.add " --passL:-lws2_32 --passL:-lz"
    flCmd.add " -p:" & quoted(joinPath(e.repo, "backend"))
    flCmd.add " -p:" & quoted(joinPath(e.repo, "installer\\src"))
    flCmd.add " -p:" & quoted(joinPath(e.repo, "aowl\\src"))
    flCmd.add " -o:" & quoted(frameLenExe)
    flCmd.add " " & quoted(joinPath(e.repo, "backend\\framelen.nim"))
    if run(e, "framelen builds", flCmd, e.repo):
      # The emulator has to be in the stage. `framelen` decides the server is
      # up by asking `/client/game/config` -- an ordinary request, because a
      # framing test that cannot ask an ordinary question cannot tell a refused
      # frame from a dead server. With no mod staged, nothing answers that
      # route and the run reports "the backend never came up" about a backend
      # that came up perfectly.
      let flStage = joinPath(e.repo, "installer\\build\\framestage")
      discard winfs.removeTree(flStage)
      discard ensureDir(joinPath(flStage, "mods\\tarkov"))
      discard copyFileAt(joinPath(e.repo, "tests\\fixtures\\emu-full.json"),
                         joinPath(flStage, "db.json"))
      discard copyFileAt(
        joinPath(e.repo, "mods\\tarkov\\bin\\tarkov.dll"),
        joinPath(flStage, "mods\\tarkov\\tarkov.dll"))
      if fileExists(joinPath(e.repo, "mods\\tarkov\\config.json")):
        discard copyFileAt(
          joinPath(e.repo, "mods\\tarkov\\config.json"),
          joinPath(flStage, "mods\\tarkov\\config.json"))
      discard run(e, "a lying Content-Length cannot smuggle a second request",
                  quoted(frameLenExe) & " --root " & quoted(flStage) &
                  " --backend " & quoted(joinPath(e.repo,
                    "backend\\bin\\aowlspt-backend.exe")) &
                  " --port 6983")

    # And the mod taken away while workers are inside it. This is the shape no
    # socket-driven gate can see: `matchRoute` copies a route out under the
    # registration lock and lets go -- deliberately, because a handler may
    # register a route and holding the lock across the call would wait on
    # itself -- so from that point a worker carries a function pointer into a
    # library with nothing holding it open. `livectl` toggles mods *between*
    # requests, so its unloads never overlap a handler.
    #
    # Unguarded, this faults 16 workers out of 16 at 0xc0000005 inside the
    # freed image, five runs out of five. It also catches the quieter half: a
    # late call landing in the *next* incarnation at the same base address
    # never faults at all, so every reply carries a generation and a stale
    # answer is counted rather than passing as a good one.
    let raceModDll = joinPath(e.repo, "backend\\bin\\racemod.dll")
    let modRaceExe = joinPath(e.repo, "backend\\bin\\modrace.exe")
    if run(e, "compile racemod.c",
           "gcc -O1 -shared -I" & quoted(joinPath(e.repo, "abi")) & " -o " &
           quoted(raceModDll) & " " &
           quoted(joinPath(e.repo, "backend\\racemod.c"))):
      var mrcCmd = quoted(nimonyExe(e))
      mrcCmd.add " c"
      mrcCmd.add abiInclude(e)
      mrcCmd.add " --passL:-lws2_32 --passL:-lz"
      mrcCmd.add " -p:" & quoted(joinPath(e.repo, "backend"))
      mrcCmd.add " -p:" & quoted(joinPath(e.repo, "host\\common"))
      mrcCmd.add " -p:" & quoted(joinPath(e.repo, "installer\\src"))
      mrcCmd.add " -p:" & quoted(joinPath(e.repo, "aowl\\src"))
      mrcCmd.add " -o:" & quoted(modRaceExe)
      mrcCmd.add " " & quoted(joinPath(e.repo, "backend\\modrace.nim"))
      if run(e, "modrace builds", mrcCmd, e.repo):
        discard run(e, "a mod unloaded under live callers never answers from " &
                       "a freed library", quoted(modRaceExe) &
                    " --cycles 24 --workers 16")

    # And the SDK's own scheduler table, which every mod links and which no
    # host can protect. `claimTick`/`releaseTick` run on whatever thread a mod's
    # handler runs on; `tickTrampoline` runs on the host's drain thread. One
    # scheduling thread against one draining thread -- which is exactly the
    # client host's shape, `on_update` plus the game thread -- died inside two
    # seconds on a seq bounds assertion; two or more corrupted the heap.
    #
    # The quiet failure is the one to keep in mind: two claims handed the same
    # slot means one mod callback runs twice and another never runs at all. A
    # timer that silently stopped, not a crash.
    let tickRaceExe = joinPath(e.repo, "installer\\build\\tickrace.exe")
    var trCmd = quoted(nimonyExe(e))
    trCmd.add " c"
    trCmd.add abiInclude(e)
    trCmd.add " -p:" & quoted(joinPath(e.repo, "installer\\src"))
    trCmd.add " -p:" & quoted(joinPath(e.repo, "aowl\\src"))
    trCmd.add " -o:" & quoted(tickRaceExe)
    trCmd.add " " & quoted(joinPath(e.repo, "tests\\tickrace.nim"))
    if run(e, "tickrace builds", trCmd, e.repo):
      discard run(e, "the scheduler hands out no slot twice and loses no " &
                     "callback", quoted(tickRaceExe) &
                  " --sched 8 --drains 4 --seconds 4")

    # And the SDK's *registration* tables, which are the same shape one table
    # over: `seq.add handler` then `toCookie(len - 1)` is check-then-act, so two
    # threads both read the second index and `/a` is served by `/b`'s handler
    # while `/a`'s is unreachable. A wrong answer with no log line.
    #
    # "Register during on_load only" would have made a lock unnecessary and is
    # **not true of this repository**: `examples/clientprobe` patches from
    # `on_update` after waiting for EFT's assemblies, and `examples/lesson` arms
    # nine hooks on the first tick its types resolve. A type that does not exist
    # yet cannot be hooked at load. So the tables are filled to capacity once
    # and never move -- a lock pair is 25-27 ns against a 21.8 ns typed prefix
    # and would more than double the path.
    let regRaceExe = joinPath(e.repo, "installer\\build\\regrace.exe")
    var rrCmd = quoted(nimonyExe(e))
    rrCmd.add " c"
    rrCmd.add abiInclude(e)
    rrCmd.add " -p:" & quoted(joinPath(e.repo, "installer\\src"))
    rrCmd.add " -p:" & quoted(joinPath(e.repo, "aowl\\src"))
    rrCmd.add " -o:" & quoted(regRaceExe)
    rrCmd.add " " & quoted(joinPath(e.repo, "tests\\regrace.nim"))
    if run(e, "regrace builds", rrCmd, e.repo):
      discard run(e, "every registration is reached by the handler it named",
                  quoted(regRaceExe))

    # And the emulator, driven the way the client drives it: the boot sequence
    # in order, then a restart to prove the profile store is a store rather
    # than a cache.
    let estage = joinPath(e.repo, "installer\\build\\emustage")
    discard winfs.removeTree(estage)
    discard ensureDir(joinPath(estage, "mods\\tarkov"))
    discard buildEmuTest(e)
    if buildMod(e, joinPath(e.repo, "mods\\tarkov")):
      discard copyFileAt(
        joinPath(e.repo, "mods\\tarkov\\bin\\tarkov.dll"),
        joinPath(estage, "mods\\tarkov\\tarkov.dll"))
      if fileExists(joinPath(e.repo, "mods\\tarkov\\config.json")):
        discard copyFileAt(
          joinPath(e.repo, "mods\\tarkov\\config.json"),
          joinPath(estage, "mods\\tarkov\\config.json"))
      # A database with a trader, an assort, a handbook price and a stash grid
      # in it. Without one the emulator answers out of its fallbacks, which is a
      # path worth testing and not the only one -- buying something requires a
      # trader who has it and a price to pay. `emu-full.json` is that plus what
      # the flea, the hideout, the loot tables and the quests need, in one
      # database, because the checks for those cross into each other.
      discard copyFileAt(
        joinPath(e.repo, "tests\\fixtures\\emu-full.json"),
        joinPath(estage, "db.json"))
      let emutest = joinPath(e.repo, "installer\\build\\emutest.exe")
      if fileExists(emutest):
        discard run(e, "the emulator boots a client",
                    quoted(emutest) & " --root " & quoted(estage) &
                    " --backend " & quoted(joinPath(e.repo,
                      "backend\\bin\\aowlspt-backend.exe")) &
                    " --port 6975")

    # And the same emulator against a *real* database, when there is one.
    #
    # Everything above this point runs on `tests/fixtures/emu-full.json`, and
    # every check in `emutest` and `soak` names an id out of it -- which is what
    # makes them exact and what makes them silent about the tables a player
    # actually plays on. `realtest` discovers its ids from the answers instead:
    # whichever trader has the cheapest rouble offer, whichever quest has no
    # prerequisite, whichever map the locations table lists first. It asserts
    # shape and cross-reference rather than identity, and it prints what it
    # exercised.
    #
    # It is skipped -- plainly, with the command that produces one -- when there
    # is no imported database, because building one needs an SPT install that
    # most machines running this do not have.
    heading "Real data"
    let realDb = joinPath(e.repo, "build\\db\\db.json")
    if not fileExists(realDb):
      note "skipped: no imported database at " & realDb
      note "  produce one with:  aowl importdb --from D:\\SPT"
    else:
      let rstage = joinPath(e.repo, "installer\\build\\realstage")
      discard winfs.removeTree(rstage)
      discard ensureDir(joinPath(rstage, "mods\\tarkov"))
      if buildRealTest(e) and buildMod(e, joinPath(e.repo, "mods\\tarkov")):
        discard copyFileAt(
          joinPath(e.repo, "mods\\tarkov\\bin\\tarkov.dll"),
          joinPath(rstage, "mods\\tarkov\\tarkov.dll"))
        if fileExists(joinPath(e.repo, "mods\\tarkov\\config.json")):
          discard copyFileAt(
            joinPath(e.repo, "mods\\tarkov\\config.json"),
            joinPath(rstage, "mods\\tarkov\\config.json"))
        discard run(e, "the emulator serves a real database",
                    quoted(joinPath(e.repo, "installer\\build\\realtest.exe")) &
                    " --root " & quoted(rstage) &
                    " --db " & quoted(realDb) &
                    " --backend " & quoted(joinPath(e.repo,
                      "backend\\bin\\aowlspt-backend.exe")) &
                    " --port 6978")

    # And the same server driven by a client that is lying. `emutest` proves it
    # is right when it is asked politely; this proves it cannot be crashed,
    # wedged, or made to leave a profile the next request cannot read. Its own
    # stage, because half of what it does is deliberately corrupt a profile and
    # the emulator's checks all assume a clean one.
    #
    # A crash here is a crash of the whole server from one request, so it runs
    # in the gate rather than by hand: the last one was ninety bytes of
    # `Content-Length`.
    heading "Hostile input"
    let fstage = joinPath(e.repo, "installer\\build\\fuzzstage")
    discard winfs.removeTree(fstage)
    discard ensureDir(joinPath(fstage, "mods\\tarkov"))
    if buildFuzzWire(e) and buildMod(e, joinPath(e.repo, "mods\\tarkov")):
      discard copyFileAt(
        joinPath(e.repo, "mods\\tarkov\\bin\\tarkov.dll"),
        joinPath(fstage, "mods\\tarkov\\tarkov.dll"))
      if fileExists(joinPath(e.repo, "mods\\tarkov\\config.json")):
        discard copyFileAt(
          joinPath(e.repo, "mods\\tarkov\\config.json"),
          joinPath(fstage, "mods\\tarkov\\config.json"))
      discard copyFileAt(
        joinPath(e.repo, "tests\\fixtures\\emu-full.json"),
        joinPath(fstage, "db.json"))
      discard run(e, "the server survives a hostile client",
                  quoted(joinPath(e.repo, "installer\\build\\fuzzwire.exe")) &
                  " --root " & quoted(fstage) &
                  " --backend " & quoted(joinPath(e.repo,
                    "backend\\bin\\aowlspt-backend.exe")) &
                  " --port 6977")

    # And the connection that is *held*. `fuzzwire` proves no request can wedge
    # the server; this proves the notifier websocket -- the handshake, a
    # notification provoked through the game's own routes and asserted frame by
    # frame, every refusal, a client that vanishes without closing, and a
    # hundred idle sockets held open while ordinary requests are timed behind
    # them. Its own stage and its own port, because a hundred long-lived
    # sockets in the fuzz stage would change what those request checks measure.
    heading "The notifier websocket"
    let wstage = joinPath(e.repo, "installer\\build\\wsstage")
    discard winfs.removeTree(wstage)
    discard ensureDir(joinPath(wstage, "mods\\tarkov"))
    if buildWsTest(e) and buildMod(e, joinPath(e.repo, "mods\\tarkov")):
      discard copyFileAt(
        joinPath(e.repo, "mods\\tarkov\\bin\\tarkov.dll"),
        joinPath(wstage, "mods\\tarkov\\tarkov.dll"))
      if fileExists(joinPath(e.repo, "mods\\tarkov\\config.json")):
        discard copyFileAt(
          joinPath(e.repo, "mods\\tarkov\\config.json"),
          joinPath(wstage, "mods\\tarkov\\config.json"))
      discard copyFileAt(
        joinPath(e.repo, "tests\\fixtures\\emu-full.json"),
        joinPath(wstage, "db.json"))
      discard run(e, "the notifier websocket holds and pushes",
                  quoted(joinPath(e.repo, "installer\\build\\wstest.exe")) &
                  " --root " & quoted(wstage) &
                  " --backend " & quoted(joinPath(e.repo,
                    "backend\\bin\\aowlspt-backend.exe")) &
                  " --port 6982")

      # And the failure `wstest` cannot see, because it is not about the
      # websocket at all: one notifier client that stops reading used to stop
      # **the whole HTTP server**. Every pong, close and refusal the poller
      # sends went through a blocking enter on the one registry lock, and the
      # holder that matters is a worker inside `send`. `AOWL_WS_SEND_MS` does
      # not bound that -- its deadline is per stall and resets on every byte the
      # peer accepts -- so a peer that reads slowly holds it open indefinitely.
      # A poller asleep on that lock is not in `WSAPoll`: no accepts, no reads
      # on any connection, no deadlines. Measured against the engine as it was:
      # one ordinary request in a two-second window, and it never got an answer.
      #
      # `tests/ws_stall.c` plays the nimony side itself and runs the real
      # server, pushing 4 MB frames at a client that will not read while
      # ordinary requests are timed straight through the middle. Against the
      # pre-fix header it reports 14 checks and 2 failures, deterministically.
      # It compiles against both, so it can be pointed at an older header to
      # see it fail.
      #
      # Note the peer must genuinely not read: a *reading* peer defeats the
      # stall entirely, because Windows grows the receive buffer and swallows
      # tens of megabytes without ever blocking the sender. That is written up
      # in the file, and it is why the harness is 400 lines rather than 40.
      block:
        let wsStallExe = joinPath(e.repo, "tests\\ws_stall.exe")
        if run(e, "compile ws_stall.c",
               "gcc -O1 -I" & quoted(joinPath(e.repo, "abi")) &
               " -o " & quoted(wsStallExe) &
               " " & quoted(joinPath(e.repo, "tests\\ws_stall.c")) &
               " -lws2_32 -lz", e.repo):
          discard run(e, "one websocket client that stops reading cannot stop " &
                         "the server",
                      quoted(wsStallExe) & " --port 6984")

      # And the same emulator over a long session: 24 closed loops of ordinary
      # play, each ending where it started, so every check is an equality
      # rather than a trend. It found the three bugs a single-pass test cannot
      # see -- a payout that opened a new stack every time, a sale that trusted
      # the client's `count`, and a mailbox that grew for the life of a profile.
      #
      # Its own stage, because every equality it checks is against a baseline
      # it establishes on its first cycle, and a store left behind by `emutest`
      # makes that baseline somebody else's.
      let sstage = joinPath(e.repo, "installer\\build\\soakstage")
      discard winfs.removeTree(sstage)
      discard ensureDir(joinPath(sstage, "mods\\tarkov"))
      discard copyFileAt(
        joinPath(e.repo, "mods\\tarkov\\bin\\tarkov.dll"),
        joinPath(sstage, "mods\\tarkov\\tarkov.dll"))
      if fileExists(joinPath(e.repo, "mods\\tarkov\\config.json")):
        discard copyFileAt(
          joinPath(e.repo, "mods\\tarkov\\config.json"),
          joinPath(sstage, "mods\\tarkov\\config.json"))
      discard copyFileAt(
        joinPath(e.repo, "tests\\fixtures\\emu-full.json"),
        joinPath(sstage, "db.json"))
      let soak = joinPath(e.repo, "installer\\build\\soak.exe")
      if fileExists(soak):
        discard run(e, "the emulator survives a long session",
                    quoted(soak) & " --root " & quoted(sstage) &
                    " --backend " & quoted(joinPath(e.repo,
                      "backend\\bin\\aowlspt-backend.exe")) &
                    " --port 6976 --cycles 24")

      # And how fast it is, because a performance number that is not
      # re-measured stops being true and nothing announces it. `benchbackend`
      # drives the client's own mix -- the big static tables, a profile read, a
      # keepalive, and a burst of inventory moves -- over real sockets and real
      # zlib framing, and `--floor` fails the build under a rate.
      #
      # The floor is set well under what this machine does, and is a check
      # against a regression of *kind* rather than a benchmark of the hardware:
      # a per-byte copy reintroduced, a compressed-body cache that has stopped
      # hitting, a store that has gone back to opening a file per read. Each of
      # those halves the number or worse. A slower machine should still clear
      # it; a machine that cannot is better off being told.
      #
      # A small database and few rounds, because this runs on every `aowl test`
      # and the shape of the curve is what PERF-SERVER.md is for.
      #
      # The floor was 800 and is 500, because the premise under it changed: a
      # store write used to be an in-place overwrite through an open handle,
      # about 20 us, and is now a durable commit -- a temporary file renamed
      # over the key -- at about a millisecond, which is what makes a profile
      # survive the server being killed (docs/BACKEND.md, "What survives a
      # crash"). `items/moving`, the write-heavy endpoint, went from 0.44 ms to
      # about 1.1, and the whole mix from ~1500 requests a second to ~800.
      # Leaving the floor at 800 makes this fail on a busy machine and pass on
      # a quiet one, which is a gate nobody trusts. At 500 it still catches
      # every regression of kind named above -- each of those halves the number
      # or worse -- and it is still six times what a game client asks for
      # across a whole session.
      let benchstage = joinPath(e.repo, "installer\\build\\benchstage")
      let bench = joinPath(e.repo, "installer\\build\\benchbackend.exe")
      if buildBench(e) and fileExists(bench):
        discard run(e, "the backend still serves at speed",
                    quoted(bench) & " --root " & quoted(benchstage) &
                    " --backend " & quoted(joinPath(e.repo,
                      "backend\\bin\\aowlspt-backend.exe")) &
                    " --mod " & quoted(joinPath(e.repo,
                      "mods\\tarkov\\bin\\tarkov.dll")) &
                    " --config " & quoted(joinPath(e.repo,
                      "mods\\tarkov\\config.json")) &
                    " --port 6977 --items 1000 --rounds 6 --warmup 2" &
                    " --moves 15 --keepalive --floor 500" &
                    " --label \"aowl test\"")

    # And the mod manager, driven the way the panel drives it: a mod switched
    # off and back on while the server is answering requests. Its own stage,
    # because the fixture is a three-mod registry and a selection store, and
    # sharing `emustage` would have each test's leftovers decide the other's
    # starting state.
    heading "Live mod control"
    let lstage = joinPath(e.repo, "installer\\build\\livectlstage")
    discard winfs.removeTree(lstage)
    discard ensureDir(joinPath(lstage, "mods\\manager"))
    discard ensureDir(joinPath(lstage, "mods\\tarkov"))
    discard ensureDir(joinPath(lstage, "mods\\gameserver"))
    let haveLiveCtl = buildLiveCtl(e)
    let haveManager = buildMod(e, joinPath(e.repo, "mods\\manager"))
    let haveEmu = buildMod(e, joinPath(e.repo, "mods\\tarkov"))
    let haveExample = buildMod(e, joinPath(e.repo, "examples\\gameserver"))
    if haveLiveCtl and haveManager and haveEmu and haveExample:
      discard copyFileAt(
        joinPath(e.repo, "mods\\manager\\bin\\manager.dll"),
        joinPath(lstage, "mods\\manager\\manager.dll"))
      discard copyFileAt(
        joinPath(e.repo, "mods\\tarkov\\bin\\tarkov.dll"),
        joinPath(lstage, "mods\\tarkov\\tarkov.dll"))
      if fileExists(joinPath(e.repo, "mods\\tarkov\\config.json")):
        discard copyFileAt(
          joinPath(e.repo, "mods\\tarkov\\config.json"),
          joinPath(lstage, "mods\\tarkov\\config.json"))
      discard copyFileAt(
        joinPath(e.repo, "examples\\gameserver\\bin\\gameserver.dll"),
        joinPath(lstage, "mods\\gameserver\\gameserver.dll"))
      # The registry and the manager's own config are written by the tool
      # itself: they are its fixture, and the checks it makes name the mods and
      # the list in them.
      discard run(e, "a mod can be disabled and enabled while the server runs",
                  quoted(joinPath(e.repo, "installer\\build\\livectl.exe")) &
                  " --root " & quoted(lstage) &
                  " --backend " & quoted(joinPath(e.repo,
                    "backend\\bin\\aowlspt-backend.exe")) &
                  " --port 6979")

    # And the half of the same feature that runs in the *game*. Everything
    # above this line stays inside the backend's process: `livectl` drives the
    # manager over a socket it opens itself, and `modreport`/`modclient` write
    # out one end of the client wire and read it with the other. None of them
    # ever asks whether the poll the client host actually makes arrives.
    #
    # This one does, with the real worker thread: `aowl_ov_start` creates it,
    # `aowl_ov_sync_start` points it at the client route, and what the checks
    # read is `modcontrol.parseDesired` over whatever `aowl_ov_sync_take` hands
    # back. A mod is toggled through the manager's own route and the assertion
    # is that the new answer turns up in the parsed set on the client side --
    # then the other direction, with `reportPath`'s query string carried up by
    # the same worker and read back out of the manager's ledger.
    #
    # Its own root, staged by the tool itself rather than here: it is the one
    # gate that must be runnable against a directory that did not exist a
    # second ago, and the registry it needs -- one client-only mod, so that the
    # client resolution and the panel's differ by construction -- is its
    # fixture and not this file's business.
    if haveManager and buildOvSync(e):
      discard run(e, "the client host's poll reaches the backend and the " &
                     "answer comes back into what it will act on",
                  quoted(joinPath(e.repo, "installer\\build\\ovsync.exe")) &
                  " --root " & quoted(joinPath(e.repo,
                    "installer\\build\\ovsyncstage")) &
                  " --backend " & quoted(joinPath(e.repo,
                    "backend\\bin\\aowlspt-backend.exe")) &
                  " --manager " & quoted(joinPath(e.repo,
                    "mods\\manager\\bin\\manager.dll")) &
                  " --port 7057")

    # And every mod in the registry, in one backend, which is the configuration
    # a player installs and the one nothing above this line has ever run.
    #
    # Every other gate here loads one mod, or three chosen to make a point. The
    # failures this one is for all need a second mod to exist: a route the
    # router refuses because another mod already has it (and `serve` is
    # `discard`ed everywhere, so nobody is told), a `dbWrite` another mod
    # overwrites, and a load order the registry states and the loader does not
    # read. It stages its own roots -- a baseline, a pair and a solo run for
    # each mod, then all of them together -- so that every route it names has an
    # owner and every database leaf it names has an author, measured rather than
    # written down here.
    heading "Every mod at once"
    if buildAllMods(e):
      var built = true
      for m in modDirs(e):
        if not buildMod(e, m):
          built = false
      if built:
        discard run(e, "every mod in the registry loads into one backend",
                    quoted(joinPath(e.repo, "installer\\build\\allmods.exe")) &
                    " --repo " & quoted(e.repo) &
                    " --stage " & quoted(joinPath(e.repo,
                      "installer\\build\\allmodsstage")) &
                    " --backend " & quoted(joinPath(e.repo,
                      "backend\\bin\\aowlspt-backend.exe")) &
                    " --db " & quoted(joinPath(e.repo, "build\\db\\db.json")) &
                    " --port 6980")

  # A player's profile is the only thing here that cannot be rebuilt, so the
  # claim that a store write survives a crash is tested by causing one:
  # `storecrash` writes into the store from a child process and kills it with
  # `TerminateProcess` at jittered points, then reads the store back and
  # demands a whole value. It reports how many of those kills landed inside a
  # commit, so "no torn values" means "none at timings that demonstrably reach
  # the window" rather than "none observed".
  #
  # Its default twelve rounds a phase, not the sixty a coverage claim wants:
  # this runs on every `aowl test`, on a machine somebody is using for
  # something else, and fifteen seconds of silent work is what that is worth.
  # The tool prints the longer command when it has been run the short way. Its
  # children are spawned without consoles, and it cleans its own stage up.
  heading "The store under a crash"
  let cstage = joinPath(e.repo, "installer\\build\\crashstage")
  discard winfs.removeTree(cstage)
  if buildStoreCrash(e):
    discard run(e, "a store write survives the process being killed",
                quoted(joinPath(e.repo, "installer\\build\\storecrash.exe")) &
                " --root " & quoted(cstage))

  # And the other half of the same property, which `storecrash` cannot see: a
  # reader that is *running* while the commit happens. `storecrash` kills a
  # writer and then reads; this holds a handle open across somebody else's
  # commits and demands two things at once -- that every read is one whole
  # value, and that the reader **keeps up**. The second is what makes it a
  # check rather than a tautology: a handle that never sees anything change is
  # trivially never torn, and against the store as it was that is exactly what
  # happened. Two of its nine checks fail there -- "the file never changed" and
  # "the held handle answered 1 distinct value" -- because the rename left the
  # reader following an unlinked file forever.
  #
  # Its own control, in the same run: the same loop over an in-place write,
  # which tears. If that phase ever stops tearing, the harness has stopped
  # reaching the window and the green above it means nothing.
  block:
    let sgStage = joinPath(e.repo, "installer\\build\\storeguardstage")
    discard winfs.removeTree(sgStage)
    discard ensureDir(sgStage)
    let sgExe = joinPath(e.repo, "installer\\build\\storeguard.exe")
    var sgCmd = quoted(nimonyExe(e))
    sgCmd.add " c"
    sgCmd.add abiInclude(e)
    sgCmd.add " -p:" & quoted(joinPath(e.repo, "host\\common"))
    sgCmd.add " -p:" & quoted(joinPath(e.repo, "installer\\src"))
    sgCmd.add " -p:" & quoted(joinPath(e.repo, "aowl\\src"))
    sgCmd.add " -o:" & quoted(sgExe)
    sgCmd.add " " & quoted(joinPath(e.repo, "tests\\storeperf\\storeguard.nim"))
    if run(e, "storeguard builds", sgCmd, e.repo):
      discard run(e, "a reader holding the key open across a commit sees " &
                     "whole values, and sees the new ones",
                  quoted(sgExe) & " --root " & quoted(sgStage))

  heading "Examples through the simulator"
  let sim = simExe(e)
  let mods = exampleDirs(e)
  for m in mods:
    if buildMod(e, m) and fileExists(sim):
      discard run(e, "sim " & baseName(m),
                  quoted(sim) & " " & quoted(m) & " --side sim --ticks 3")

  # Two claims the loop above cannot make, because all it knows is whether a run
  # exited zero -- and a mod that does nothing exits zero. That is not
  # hypothetical: `examples/gameserver` guarded on `side() != sideServer` and so
  # registered no routes and wrote nothing under the simulator, and this loop
  # reported ok for it for as long as it has existed.
  #
  # The first claim is that the envelope reaches the wire. `--route` drives two
  # handlers and the bodies are read, so a `/client/*` route that quietly went
  # back to `done(o).text` is caught here rather than by a client nobody has.
  #
  # The second is a run that must **fail**. `examples/strictconfig` against a
  # config.json that does not parse has to apply nothing, name the fault, and
  # take the simulator's exit status down with it -- a mod logging at error
  # level is how a sim run reports failure, and a refusal is exactly that. So it
  # cannot go through `run`, which counts a non-zero exit as a gate failure:
  # what is asserted is that the run *does* fail, and for the stated reason. A
  # run that failed to load, or failed a self-check, would also exit non-zero
  # and would prove nothing.
  #
  # It runs from a stage because the broken document has to be named
  # `config.json` to be read as one, and a broken `config.json` sitting in the
  # example directory is what the loop above would have run.
  heading "The two examples that teach a failure"
  block:
    let env = joinPath(e.repo, "examples\\envelope")
    if buildMod(e, env) and fileExists(sim):
      var cmd = quoted(sim) & " " & quoted(env) & " --side sim --ticks 1"
      cmd.add " --route /client/aowlspt/envelope/status"
      cmd.add " --route /client/aowlspt/envelope/bare"
      var code = -1
      var output = ""
      try:
        let (o, c) = execCmdEx(cmd, workingDir = e.repo)
        output = o
        code = c
      except:
        output = ""
      let wrapped = find(output,
        "/client/aowlspt/envelope/status -> {\"err\":0,\"errmsg\":null,\"data\":") >= 0
      let bare = find(output,
        "/client/aowlspt/envelope/bare -> {\"ok\":true") >= 0
      if code == 0 and wrapped and bare:
        ok "a /client/* route answers in the envelope, and the bare one still " &
           "shows what the mistake looks like"
      else:
        err "the envelope example's routes did not answer as it claims " &
            "(exit " & $code & ", envelope=" & $wrapped & ", bare=" & $bare & ")"
        for l in splitLines(output):
          if l.len > 0:
            line "        " & l
        inc failures

  block:
    let src = joinPath(e.repo, "examples\\strictconfig")
    let stage = joinPath(e.repo, "installer\\build\\strictconfig-broken")
    discard winfs.removeTree(stage)
    discard ensureDir(stage)
    if not buildMod(e, src) or not fileExists(sim):
      err "examples/strictconfig did not build, or there is no simulator; " &
          "the refusal cannot be checked"
      inc failures
    else:
      discard copyFileAt(joinPath(src, "bin\\strictconfig.dll"),
                         joinPath(stage, "strictconfig.dll"))
      discard copyFileAt(joinPath(src, "broken-config.json"),
                         joinPath(stage, "config.json"))
      let cmd = quoted(sim) & " " & quoted(stage) & " --side sim --ticks 3"
      var code = -1
      var output = ""
      try:
        let (o, c) = execCmdEx(cmd, workingDir = e.repo)
        output = o
        code = c
      except:
        output = ""
      let refused = find(output, "refused: no setting was applied") >= 0
      let named = find(output, "did not parse: there is a trailing comma") >= 0
      let clean = find(output, "0 self-check failure(s)") >= 0
      if code != 0 and refused and named and clean:
        ok "a config.json that does not parse is refused rather than defaulted"
      else:
        err "examples/strictconfig did not refuse a broken config (exit " &
            $code & ", refused=" & $refused & ", the fault was named=" & $named &
            ", self-checks clean=" & $clean & ")"
        for l in splitLines(output):
          if l.len > 0:
            line "        " & l
        inc failures

  # And the real mods. They are the reason the pipeline exists, so "it still
  # builds" is not the bar -- each one has to load through the ABI and survive a
  # few ticks. Several carry their own self-tests and run them here.
  heading "Mods through the simulator"
  let realMods = modDirs(e)
  for m in realMods:
    if buildMod(e, m) and fileExists(sim):
      discard run(e, "sim " & baseName(m),
                  quoted(sim) & " " & quoted(m) & " --side sim --ticks 3")

  # The registry is the only file that claims to know every mod that exists,
  # and until now nothing checked the claim. Both halves of getting it wrong
  # are silent: a mod that is built and loaded but absent from `mods.json`
  # cannot be enabled or disabled by anything, and an entry whose `id` is not
  # the guid the mod exports puts a second, dead row on the in-game panel
  # instead of correcting itself. The manager cannot detect either -- it
  # reports honestly on what it was told, and being told something false is not
  # a state it can see -- so the check has to live out here, against the source
  # tree, reading each guid out of the mod's own `exportMod` call.
  #
  # It runs after the mods have been through the simulator because those are
  # the expensive checks and this is the cheap one; a build that gets this far
  # and fails here has a manifest problem and nothing else, which is worth
  # being able to read off the last line.
  heading "The mod registry against the mods"
  block:
    let outDir = joinPath(e.repo, "installer\\build")
    discard ensureDir(outDir)
    var cmd = quoted(nimonyExe(e))
    cmd.add " c"
    cmd.add abiInclude(e)
    cmd.add " -p:" & quoted(joinPath(e.repo, "installer\\src"))
    cmd.add " -p:" & quoted(joinPath(e.repo, "aowl\\src"))
    cmd.add " -o:" & quoted(joinPath(outDir, "aowl-regcheck.exe"))
    cmd.add " " & quoted(joinPath(e.repo, "tools\\regcheck.nim"))
    if run(e, "aowl-regcheck builds", cmd, e.repo):
      discard run(e, "every mod has a true registry entry",
                  quoted(joinPath(outDir, "aowl-regcheck.exe")) &
                  " --repo " & quoted(e.repo))

  # And the same argument one level up, for a document rather than a manifest.
  # `docs/EMULATOR-COVERAGE.md` used to be rebuilt by hand from four shell
  # commands plus a three-bucket split joined by hand on top of them, and the
  # failure mode was the worst kind: the table does not become obviously wrong,
  # it becomes quietly out of date while still reading as measured. Two of the
  # four numbers had drifted the last time anybody re-ran them.
  #
  # `tools/coverage.nim` derives all of it -- the four sweeps in nimony by
  # reading the files, and the split from `docs/coverage-rows.json` joined
  # against `mods/tarkov/tarkov.nim` -- and `--check` writes nothing and fails
  # if the document on disk is not what it would write. It also cross-checks the
  # rows against the code in both directions, which is the half that earns its
  # place here: a row claiming a route nothing registers, and a registered route
  # no row mentions, are both errors, and the first run of it found eleven
  # operations the hand join had wrong.
  #
  # Cheap, and last, for the same reason as the registry check: a build that
  # gets this far and fails here has a stale document and nothing else.
  heading "The coverage document against the emulator"
  block:
    let outDir = joinPath(e.repo, "installer\\build")
    discard ensureDir(outDir)
    var cmd = quoted(nimonyExe(e))
    cmd.add " c"
    cmd.add abiInclude(e)
    cmd.add " -p:" & quoted(joinPath(e.repo, "installer\\src"))
    cmd.add " -p:" & quoted(joinPath(e.repo, "aowl\\src"))
    cmd.add " -o:" & quoted(joinPath(outDir, "coverage.exe"))
    cmd.add " " & quoted(joinPath(e.repo, "tools\\coverage.nim"))
    if run(e, "aowl-coverage builds", cmd, e.repo):
      discard run(e, "docs/EMULATOR-COVERAGE.md is what the code says it is",
                  quoted(joinPath(outDir, "coverage.exe")) &
                  " --repo " & quoted(e.repo) & " --check")

  heading "Result"
  if failures > 0:
    err $failures & " failed"
    result = 1
  else:
    ok "everything passed"
    result = 0

proc cmdRun(e: Env; modPath: string; simArgs: string = ""): int =
  ## `aowl run <mod>` — build it and run it under the simulator.
  ##
  ## **The simulator's output is printed, always.** It used to go through
  ## `run`, which captures output and prints it only when the command fails or
  ## `-v` is given -- so on a successful run every line the simulator wrote was
  ## discarded. That is the wrong way round for this command in particular: the
  ## simulator's whole job is to narrate what a mod did, and an audit of it
  ## added a dozen warnings ("this config did not parse", "nothing in memory
  ## crosses a reload", "an installed host would have excluded this mod") that
  ## were invisible through the one command anybody types. A mod's own
  ## self-check output was going the same way.
  ##
  ## Anything after the mod path is handed to the simulator unchanged, so
  ## `--watch`, `--db`, `--stubs`, `--route` and `--ticks` are reachable
  ## without knowing where the binary lives.
  if not buildMod(e, modPath):
    return 1
  let sim = simExe(e)
  if not fileExists(sim):
    err "aowlspt-sim is not built. Run: aowl build-hosts"
    return 1
  var cmd = quoted(sim) & " " & quoted(absolutePathOf(modPath))
  if find(simArgs, "--side") < 0:
    cmd.add " --side sim"
  if simArgs.len > 0:
    cmd.add " " & simArgs
  if e.verbose:
    detail cmd
  var code = -1
  try:
    code = execCmd(cmd)
  except:
    err "sim: could not start " & sim
    inc failures
    return 1
  if code != 0:
    err "sim exited " & $code
    inc failures
  else:
    ok "sim"
  result = if failures > 0: 1 else: 0

proc cmdPayload(e: Env): int =
  ## Assembles `installer/payload/aowlspt` out of what has been built, so that
  ## `aowlspt-install` has something to install. Only the `aowlspt/` part: a
  ## runtime and a mod loader are not this repo's to produce, and inventing a
  ## directory for them would suggest otherwise.
  let payload = joinPath(e.repo, "installer\\payload")
  let dest = joinPath(payload, "aowlspt")
  # Counted from here rather than from zero: `failures` is a process-wide tally
  # and one command must not report another's.
  let failuresAtEntry = failures
  heading "Payload"

  discard winfs.removeTree(dest)
  discard ensureDir(dest)

  # No `server/` or `client/` here any more. Both were .NET hosts for a
  # pre-1.0 SPT -- a Mono BepInEx plugin and a mod for SPT's own C# server --
  # and neither can load into a post-1.0 install: the client is IL2CPP and the
  # server is `aowlspt-backend`, both staged below.
  var copied = 0

  # The real mods only: the emulator and the ports, which are the reason
  # someone installs this at all.
  #
  # `examples/` is deliberately **not** staged. Those mods load and act --
  # `Backend Example` writes into `templates.items` -- and they exist to be read
  # and run out of the repo, not to turn up in somebody's game because they
  # happened to sit in the same tree. `aowl run <example>` runs one.
  var mods: seq[string] = @[]
  let realMods = modDirs(e)
  for m in realMods:
    mods.add m
  for m in mods:
    let bin = joinPath(m, "bin")
    if not isDirectory(bin):
      continue
    var files: seq[string] = @[]
    var dirs: seq[string] = @[]
    collectEntries(bin, files, dirs)
    for f in files:
      let to1 = joinPath(joinPath(joinPath(dest, "mods"), baseName(m)), f)
      if copyFileAt(joinPath(bin, f), to1).ok:
        inc copied
    # A mod's `data/` goes with it. Some mods *are* their data -- a faction is
    # bot templates, loadouts and locale -- and a payload that carries the
    # library without them installs a mod that loads and does nothing.
    let dataDir = joinPath(m, "data")
    if isDirectory(dataDir):
      var dataFiles: seq[string] = @[]
      var dataDirs: seq[string] = @[]
      collectEntries(dataDir, dataFiles, dataDirs)
      for f in dataFiles:
        let to2 = joinPath(joinPath(joinPath(joinPath(dest, "mods"),
                                             baseName(m)), "data"), f)
        if copyFileAt(joinPath(dataDir, f), to2).ok:
          inc copied

    let cfg = joinPath(m, "config.json")
    if fileExists(cfg):
      discard copyFileAt(cfg,
        joinPath(joinPath(joinPath(dest, "mods"), baseName(m)), "config.json"))
    if not fileExists(joinPath(bin, baseName(m) & ".dll")):
      # A failure, not a warning. A first-run walk found the shape: `aowl build`
      # exits 1 on a mod that would not compile, `aowl payload` then stages that
      # mod's `config.json` and `data/` without its library and exits **0**, and
      # four commands later `aowlspt-verify` is the first thing to say anything.
      # A payload that installs a directory nothing loads is not a payload.
      err "mod " & baseName(m) & " has no library; its config and data would " &
          "install as a directory nothing loads. Build it first: the payload " &
          "is only as good as the build under it."
      inc failures
    say "mod " & baseName(m) & " -> " & joinPath(dest, "mods")

  # The registry: without it the mod manager loads, finds nothing to manage,
  # and says so only in a log nobody reads until something has already gone
  # wrong. It rides in under `aowlspt/`, which is where the installer looks
  # first.
  let reg = joinPath(e.repo, "registry\\mods.json")
  if fileExists(reg):
    if copyFileAt(reg, joinPath(joinPath(dest, "registry"), "mods.json")).ok:
      inc copied
      say "registry -> " & joinPath(dest, "registry\\mods.json")
  else:
    warn "no registry/mods.json; the mod manager will have nothing to manage"

  # The post-1.0 client host and the launcher that puts it in the game. These
  # go at the top of `aowlspt/` rather than under a side directory, because
  # they are what the player runs and what the launcher looks for by path.
  let il2cppHost = joinPath(e.repo,
    "host\\Aowlspt.Host.Il2Cpp\\bin\\aowlspt-host-il2cpp.dll")
  if fileExists(il2cppHost):
    if copyFileAt(il2cppHost, joinPath(dest, "aowlspt-host-il2cpp.dll")).ok:
      inc copied
      say "IL2CPP client host -> " & joinPath(dest, "aowlspt-host-il2cpp.dll")
  else:
    # A refusal, for the same reason a library-less mod is one, and a bigger
    # one: a payload without the client host installs a game with nothing in
    # it. This warned and exited 0 until an install walk found that `aowl
    # payload` was the only step that would not say no -- `aowl release` and
    # `aowlspt-verify` both catch it later, so the release path was safe, but
    # a payload staged by hand and installed straight was not.
    err "the IL2CPP client host is not built; a post-1.0 payload without it " &
        "installs a client that loads nothing. Build it first."
    inc failures

  # The backend goes in the payload too: it is half the pipeline, and an
  # install without it has mods that can serve routes and nothing listening.
  let backend = joinPath(e.repo, "backend\\bin\\aowlspt-backend.exe")
  if fileExists(backend):
    if copyFileAt(backend, joinPath(dest, "aowlspt-backend.exe")).ok:
      inc copied
      say "backend -> " & joinPath(dest, "aowlspt-backend.exe")
  else:
    err "the backend is not built; the install would have mods that serve " &
        "routes and nothing listening. Build it first."
    inc failures

  let launcher = joinPath(e.repo, "installer\\build\\aowlspt-launch.exe")
  if fileExists(launcher):
    if copyFileAt(launcher, joinPath(dest, "aowlspt-launch.exe")).ok:
      inc copied
      say "launcher -> " & joinPath(dest, "aowlspt-launch.exe")
  else:
    err "aowlspt-launch is not built; there would be no way to start the " &
        "game. Build it first."
    inc failures

  # A default the player can edit, rather than a value compiled into the host.
  let hostCfg = joinPath(dest, "aowlspt-host.json")
  if not fileExists(hostCfg):
    discard writeTextFile(hostCfg,
      "{\n" &
      "  \"//\": \"How long to wait for the game to bring IL2CPP up.\",\n" &
      "  \"waitForRuntimeMs\": 120000,\n" &
      "\n" &
      "  \"//backendPort\": \"The aowlspt backend, so the overlay and the " &
      "in-game mod manager can reach it. 0 means do not try, and the game " &
      "still runs -- the overlay then shows only what the host itself " &
      "knows.\",\n" &
      "  \"backendPort\": 0,\n" &
      "\n" &
      "  \"//modSyncMs\": \"How often to ask the backend which client mods " &
      "should be running, so a mod switched off in the manager is switched " &
      "off in the game without a restart. 0 turns it off, and it needs " &
      "backendPort.\",\n" &
      "  \"modSyncMs\": 3000\n" &
      "}\n")

  let staged = failures - failuresAtEntry
  if staged > 0:
    # Deliberately not counted as "mods": the same tally now carries the three
    # binaries above, and a message that says "2 mod(s)" when one of them is
    # the backend sends the reader to look at the wrong thing.
    err $staged & " missing piece(s) above; this payload is not installable"
    return 1

  ok $copied & " files staged in " & dest
  if not fileExists(joinPath(payload, "payload.json")):
    warn "there is still no payload.json here -- copy payload.json.template " &
         "and fill in the version this was built against"
  result = 0

proc cmdRelease(e: Env; extra: seq[string]): int =
  ## `aowl release` -- builds `tools/release.nim` and hands it this repo plus
  ## whatever else was typed. Every gate, every refusal and the archive format
  ## live over there and nothing about them is duplicated here: a release gate
  ## that lives in two files is a release gate with two answers.
  let outDir = joinPath(e.repo, "installer\\build")
  discard ensureDir(outDir)
  var cmd = quoted(nimonyExe(e))
  cmd.add " c"
  cmd.add abiInclude(e)
  cmd.add " -p:" & quoted(joinPath(e.repo, "installer\\src"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "aowl\\src"))
  cmd.add " -o:" & quoted(joinPath(outDir, "aowl-release.exe"))
  cmd.add " " & quoted(joinPath(e.repo, "tools\\release.nim"))
  if not run(e, "aowl-release builds", cmd, e.repo):
    return 1
  var invocation = quoted(joinPath(outDir, "aowl-release.exe"))
  invocation.add " --repo " & quoted(e.repo)
  for a in extra:
    invocation.add " " & quoted(a)
  var code = -1
  try:
    let (o, c) = execCmdEx(invocation, workingDir = e.repo)
    for l in splitLines(o):
      echo l
    code = c
  except:
    err "could not start aowl-release"
    return 1
  result = code

proc cmdImportDb(e: Env; extra: seq[string]): int =
  ## `aowl importdb` -- builds `tools/importdb.nim` and hands it this repo plus
  ## whatever else was typed. Same shape as `release`: the flags, the refusals
  ## and the conversion itself live over there, because a rule about somebody's
  ## SPT install that exists in two files is a rule with two answers.
  let outDir = joinPath(e.repo, "installer\\build")
  discard ensureDir(outDir)
  var cmd = quoted(nimonyExe(e))
  cmd.add " c"
  cmd.add abiInclude(e)
  cmd.add " -p:" & quoted(joinPath(e.repo, "installer\\src"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "aowl\\src"))
  cmd.add " -o:" & quoted(joinPath(outDir, "aowl-importdb.exe"))
  cmd.add " " & quoted(joinPath(e.repo, "tools\\importdb.nim"))
  if not run(e, "aowl-importdb builds", cmd, e.repo):
    return 1
  var invocation = quoted(joinPath(outDir, "aowl-importdb.exe"))
  invocation.add " --repo " & quoted(e.repo)
  for a in extra:
    invocation.add " " & quoted(a)
  var code = -1
  try:
    let (o, c) = execCmdEx(invocation, workingDir = e.repo)
    for l in splitLines(o):
      echo l
    code = c
  except:
    err "could not start aowl-importdb"
    return 1
  result = code

proc cmdClean(e: Env): int =
  heading "Clean"
  var targets: seq[string] = @[joinPath(e.repo, "installer\\build")]
  let mods = exampleDirs(e)
  for m in mods:
    targets.add joinPath(m, "bin")
    targets.add joinPath(m, "nimcache")
  targets.add joinPath(e.repo, "tests\\nimcache")
  # `aowl` lives in one of the directories it is being asked to remove, and
  # Windows will not delete a running image. That is not a failure worth
  # reporting as one -- the rest of the tree still gets cleaned, and the one
  # file left behind is the one you are standing on.
  # `paramStr(0)` is the running image's path; it is what `os.getAppFilename`
  # returns on Windows, without dragging in `std/os` and its posix imports.
  let self = absolutePathOf(paramStr(0))
  for t in targets:
    if not exists(t):
      continue
    say "remove " & t
    let r = winfs.removeTree(t)
    if not r.ok:
      if isUnder(self, t):
        note "  left " & baseName(self) & " in place; it is running"
      else:
        warn "  could not remove " & t & " (error " & $r.err & ")"
  ok "clean"
  result = 0

# --------------------------------------------------------------- main

proc main(): int =
  var e = Env(repo: "", nimony: "", ucrt64: "C:\\msys64\\ucrt64\\bin",
              debugBuild: false, verbose: false)
  e.repo = repoRoot()
  e.nimony = joinPath(getEnv("USERPROFILE", "C:\\"), "nimony")

  var command = ""
  var arg = ""
  var extra: seq[string] = @[]
  var i = 1
  let n = paramCount()
  var help = false
  while i <= n:
    let a = paramStr(i)
    # `release` parses its own options -- `--mod`, `--out`, `--check-only`.
    # Forwarding everything after the verb verbatim keeps this parser from
    # having to learn a second command's flags, and keeps them from drifting.
    if command == "release" or command == "importdb":
      extra.add a
    elif a == "--debug":
      e.debugBuild = true
    elif a == "--nimony":
      inc i
      if i <= n: e.nimony = paramStr(i)
    elif a == "--ucrt64":
      inc i
      if i <= n: e.ucrt64 = paramStr(i)
    elif a == "--verbose" or a == "-v":
      e.verbose = true
      setVerbosity vVerbose
    elif a == "--help" or a == "-h":
      help = true
    elif a.startsWith("-"):
      err "unknown option: " & a
      return 1
    elif command.len == 0:
      command = a
    else:
      arg = a
    inc i

  if help or command.len == 0:
    echo Usage
    return (if help: 0 else: 1)

  if not fileExists(nimonyExe(e)):
    fatal "nimony not found at " & nimonyExe(e) & " (pass --nimony PATH)"
  prepareEnv(e)

  note "repo    " & e.repo
  note "nimony  " & e.nimony

  case command
  of "build": result = cmdBuild(e)
  of "build-mod":
    if arg.len == 0:
      fatal "build-mod needs a path"
    result = if buildMod(e, arg): 0 else: 1
  of "build-hosts":
    let sim = buildHosts(e)
    let net = buildDotnetTools(e)
    result = if sim and net: 0 else: 1
  of "build-installer": result = if buildInstaller(e): 0 else: 1
  of "test": result = cmdTest(e)
  of "doctor": result = cmdDoctor(e)
  of "run":
    if arg.len == 0:
      fatal "run needs a path"
    # Everything after the mod path goes to the simulator untouched, so
    # `aowl run mods\sain --watch` and `--db`/`--stubs`/`--route`/`--ticks`
    # work without knowing where the binary is. `extra` already excludes
    # `aowl`'s own flags.
    var simArgs = ""
    for a in extra:
      if a == arg: continue
      if simArgs.len > 0: simArgs.add " "
      simArgs.add quoted(a)
    result = cmdRun(e, arg, simArgs)
  of "payload": result = cmdPayload(e)
  of "release": result = cmdRelease(e, extra)
  of "importdb": result = cmdImportDb(e, extra)
  of "clean": result = cmdClean(e)
  else:
    err "unknown command: " & command
    echo Usage
    result = 1

quit(main())
