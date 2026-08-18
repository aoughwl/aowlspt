## aowl -- the one command that builds, tests and installs this repo.
##
##     aowl build                 everything: hosts, installer, examples
##     aowl build-mod PATH        one nimony mod -> a native .dll
##     aowl build-hosts           the .NET hosts and the simulator
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
  build-hosts        the .NET hosts and aowlspt-sim
  build-installer    aowlspt-install.exe
  test               every gate
  doctor             check the toolchain before it wastes your afternoon
  run PATH           build a mod and run it in the simulator
  payload            assemble installer/payload from what is built
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

proc buildHosts(e: Env): bool =
  let sln = joinPath(e.repo, "aowlspt.sln")
  if not fileExists(sln):
    err "no aowlspt.sln at " & e.repo
    inc failures
    return false
  let config = if e.debugBuild: "Debug" else: "Release"
  result = run(e, "hosts (" & config & ")",
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
  heading "Hosts (.NET)"
  discard buildHosts(e)
  heading "Host (IL2CPP, native)"
  discard buildIl2CppHost(e)
  heading "Backend"
  discard buildBackend(e)
  discard buildProbe(e)
  discard buildEmuTest(e)
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

  heading "Hosts"
  discard buildHosts(e)

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

      # The fast path, measured rather than asserted. It runs in the gate
      # because a performance claim that is not re-checked is a performance
      # claim that quietly stops being true.
      if buildPerfBench(e):
        discard run(e, "the fast path is measurably faster",
                    quoted(joinPath(e.repo, "installer\\build\\perfbench.exe")) &
                    " --runtime " & quoted(mockDll) & " --check")

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

  heading "Examples through the simulator"
  let sim = joinPath(e.repo,
    "host\\Aowlspt.Sim\\bin\\Release\\net10.0\\aowlspt-sim.exe")
  let mods = exampleDirs(e)
  for m in mods:
    if buildMod(e, m) and fileExists(sim):
      discard run(e, "sim " & baseName(m),
                  quoted(sim) & " " & quoted(m) & " --side sim --ticks 3")

  # And the real mods. They are the reason the pipeline exists, so "it still
  # builds" is not the bar -- each one has to load through the ABI and survive a
  # few ticks. Several carry their own self-tests and run them here.
  heading "Mods through the simulator"
  let realMods = modDirs(e)
  for m in realMods:
    if buildMod(e, m) and fileExists(sim):
      discard run(e, "sim " & baseName(m),
                  quoted(sim) & " " & quoted(m) & " --side sim --ticks 3")

  heading "Result"
  if failures > 0:
    err $failures & " failed"
    result = 1
  else:
    ok "everything passed"
    result = 0

proc cmdRun(e: Env; modPath: string): int =
  if not buildMod(e, modPath):
    return 1
  let sim = joinPath(e.repo,
    "host\\Aowlspt.Sim\\bin\\Release\\net10.0\\aowlspt-sim.exe")
  if not fileExists(sim):
    err "aowlspt-sim is not built. Run: aowl build-hosts"
    return 1
  discard run(e, "sim", quoted(sim) & " " & quoted(absolutePathOf(modPath)) &
                        " --side sim")
  result = if failures > 0: 1 else: 0

proc cmdPayload(e: Env): int =
  ## Assembles `installer/payload/aowlspt` out of what has been built, so that
  ## `aowlspt-install` has something to install. Only the `aowlspt/` part: a
  ## runtime and a mod loader are not this repo's to produce, and inventing a
  ## directory for them would suggest otherwise.
  let payload = joinPath(e.repo, "installer\\payload")
  let dest = joinPath(payload, "aowlspt")
  heading "Payload"

  discard winfs.removeTree(dest)
  discard ensureDir(dest)

  let serverHost = joinPath(e.repo,
    "host\\Aowlspt.Host.Server\\bin\\Release\\net10.0")
  let clientHost = joinPath(e.repo,
    "host\\Aowlspt.Host.Client\\bin\\Release\\netstandard2.1")

  var copied = 0
  for pair in [(serverHost, "server"), (clientHost, "client")]:
    let (from1, name) = pair
    if not isDirectory(from1):
      warn name & " host is not built; skipping"
      continue
    var files: seq[string] = @[]
    var dirs: seq[string] = @[]
    collectEntries(from1, files, dirs)
    for f in files:
      if copyFileAt(joinPath(from1, f), joinPath(joinPath(dest, name), f)).ok:
        inc copied
    say name & " host -> " & joinPath(dest, name)

  # Examples first, then the real mods -- the emulator and the ports, which are
  # the reason someone installs this at all.
  var mods = exampleDirs(e)
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
    say "mod " & baseName(m) & " -> " & joinPath(dest, "mods")

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
    warn "the IL2CPP client host is not built; a post-1.0 payload needs it"

  # The backend goes in the payload too: it is half the pipeline, and an
  # install without it has mods that can serve routes and nothing listening.
  let backend = joinPath(e.repo, "backend\\bin\\aowlspt-backend.exe")
  if fileExists(backend):
    if copyFileAt(backend, joinPath(dest, "aowlspt-backend.exe")).ok:
      inc copied
      say "backend -> " & joinPath(dest, "aowlspt-backend.exe")
  else:
    warn "the backend is not built; the install will have no server"

  let launcher = joinPath(e.repo, "installer\\build\\aowlspt-launch.exe")
  if fileExists(launcher):
    if copyFileAt(launcher, joinPath(dest, "aowlspt-launch.exe")).ok:
      inc copied
      say "launcher -> " & joinPath(dest, "aowlspt-launch.exe")
  else:
    warn "aowlspt-launch is not built; there will be no way to start the game"

  # A default the player can edit, rather than a value compiled into the host.
  let hostCfg = joinPath(dest, "aowlspt-host.json")
  if not fileExists(hostCfg):
    discard writeTextFile(hostCfg,
      "{\n" &
      "  \"//\": \"How long to wait for the game to bring IL2CPP up.\",\n" &
      "  \"waitForRuntimeMs\": 120000\n" &
      "}\n")

  ok $copied & " files staged in " & dest
  if not fileExists(joinPath(payload, "payload.json")):
    warn "there is still no payload.json here -- copy payload.json.template " &
         "and fill in the version this was built against"
  result = 0

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
  var i = 1
  let n = paramCount()
  var help = false
  while i <= n:
    let a = paramStr(i)
    if a == "--debug":
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
  of "build-hosts": result = if buildHosts(e): 0 else: 1
  of "build-installer": result = if buildInstaller(e): 0 else: 1
  of "test": result = cmdTest(e)
  of "doctor": result = cmdDoctor(e)
  of "run":
    if arg.len == 0:
      fatal "run needs a path"
    result = cmdRun(e, arg)
  of "payload": result = cmdPayload(e)
  of "clean": result = cmdClean(e)
  else:
    err "unknown command: " & command
    echo Usage
    result = 1

quit(main())
