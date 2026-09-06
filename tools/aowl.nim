## aowl -- the one command that builds, tests and installs this repo.
##
##     aowl script PATH.nim       build and run one automation script
##                                (0 PASS, 1 FAIL, 2 INCONCLUSIVE)
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
import aowluicmd

const Usage = """
aowl -- build, test and install aowlspt

  build              hosts, installer and every example (~25 compiles, slow)
  build TARGET       just one: host backend sim launch installer emutest
                     verify probe mods examples deploy
                     `deploy` = every artifact tools\deploy.json ships,
                     read from that file so the two can never drift
  build mod NAME     ONE mod under mods\, through the same buildMod path
                     `build mods` uses -- same audits, one compile
  build mods A,B     several by name; `build mods` with no list is all of them
  build test NAME    ONE tests\NAME.nim -> installer\build\NAME.exe, with the
                     flags `aowl test` compiles it with (same proc, so the
                     two cannot drift). Compiles it; does not run it.
  bootstrap          rebuild aowl.exe ITSELF -- `build` never does, and a
                     worktree with no aowl.exe or a stale one runs old code
                     while reporting ok
  worktree-init      make a FRESH git worktree buildable: installer\build,
                     seed .cache\global-metadata.dec.dat from a sibling
                     checkout, then bootstrap. From NO aowl.exe at all:
                     powershell -ExecutionPolicy Bypass -File tools\bootstrap.ps1
  selfcheck PATH     run a mod's selfCheckFailures() OUT OF PROCESS -- no
                     backend, no install, no running game
  build-mod PATH     compile one nimony mod into a native library
  build-hosts        aowlspt-sim (nimony) and the .NET tools left
  build-installer    aowlspt-install.exe
  test               every gate; --mod NAME for ONE mod's core/selftest alone
                     (exit 0 pass, 1 fail, 3 INCONCLUSIVE -- no such suite)
  doctor             check the toolchain before it wastes your afternoon
  run PATH           build a mod and run it in the simulator
  payload            assemble installer/payload from what is built
  payload-public     the same payload, but the mods folder holds SOURCE and
                     carries modbuild.py, abi/ and aowl/src so an install can
                     compile it at startup. Add the toolchain with
                     `python tools	oolchain.py`.
  release            a versioned, verifiable artifact; --mod NAME for one mod
  importdb           build the emulator's db.json from an SPT install
                     (--from D:\SPT; --help for the rest)
  ui SUBCMD          drive the LIVE client's UI by the text a person SEES --
                     `aowl ui help` for the verbs. Talks to a running game
                     through the inspector channel; compiles nothing.
  script PATH        build and RUN one automation script (tools\autoscript).
                     LAUNCHES THE GAME. Exit code is the verdict: 0 PASS,
                     1 FAIL, 2 INCONCLUSIVE -- 2 is never folded into 1.
                     `--build-only` compiles it and does not run it.
  raid               enter an offline raid: `aowl raid --map factory`
  clean              remove build output

Options
  --debug            build with debug info and no optimisation
  --allow-stale-driver
                     build even though aowl.exe was not built from this
                     worktree's tools\aowl.nim. Normally that REFUSES (exit
                     4), because a build step defined on the current source
                     then goes silently unexercised -- it has bitten three
                     agents. The fix is `python tools\buildlock.py bootstrap`.
  --no-lock          allow `build` OUTSIDE tools\buildlock.py. Normally
                     `build` refuses unless AOWL_BUILDLOCK is set, because
                     two builds in ONE checkout corrupt each other and an
                     unlocked build is invisible to the lock. For bootstrap
                     and CI.
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
    oneMod: string
      ## `test --mod NAME`: run only that mod's `core/selftest`. Empty means the
      ## whole suite, which is the default and stays the default.
    allowStaleDriver: bool
      ## `--allow-stale-driver`: build with an aowl.exe that was not built from
      ## this worktree's `tools/aowl.nim`. Default false, and the default is a
      ## REFUSAL rather than a warning -- see `refuseIfStaleDriver`.

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

const mimallocFlags* = " --passC:-DMI_BUILD_RELEASE --passC:-DMI_DEBUG=0"
  ## Build the VENDORED mimalloc (nimony `lib/std/system/mimalloc.nim` compiles
  ## `vendor/mimalloc/src/static.c`) with its debug machinery OFF, in EVERY
  ## aowlspt binary.
  ##
  ## MEASURED 2026-09-03, WER dump EscapeFromTarkov.exe.636.dmp read with cdb:
  ## the client died in `ucrtbase!abort` called from the HOST DLL, and the
  ## string argument on the stack (`da 00007ffb3dfd1373`) was mimalloc's
  ## `"corrupted thread-free list."` -- `vendor/mimalloc/src/page.c:205`,
  ## reached from `mi_malloc` on the ops thread. The abort itself is
  ## `mi_error_default` in `src/options.c:543`, whose `abort()` for `EFAULT`
  ## is compiled in ONLY under `#if (MI_DEBUG>0)`. nimony leaves `MI_DEBUG` at
  ## 2 unless `MI_BUILD_RELEASE` or `NDEBUG` is defined (`types.h:69-75`), and
  ## aowl never passed `-d:release`, so every shipped DLL carried it --
  ## confirmed by `markers.py --string "mimalloc: assertion failed"` finding
  ## the literal PRESENT in the deployed host DLL and in `sain.dll`.
  ##
  ## With MI_DEBUG=0 the SAME corruption check still runs and still refuses to
  ## free the suspect list; it just returns instead of killing the process
  ## (the thread-free blocks leak). That is the honest trade: a real heap bug
  ## now surfaces later and less precisely. `MI_SECURE` (types.h:55-63) would
  ## restore the abort and is deliberately NOT enabled.
  ##
  ## `--passC` reaches the `{.compile.}` TU (same `cc` invocation), and
  ## nimony keys `nimcache_static/` objects on the cc command line, so this
  ## produces a fresh object rather than reusing the assert-laden one.
  ## Kept identical in `tools/modbuild.py:compile_cmd`.

proc nimonyExe(e: Env): string =
  result = joinPath(e.nimony, "bin\\nimony.exe")

proc armSelfTestFixture(e: Env): bool =
  ## Point the mods' `--side sim` binding self-tests at the stand-in runtime,
  ## for every child process this run starts.
  ##
  ## They used to be pointed at it by `selfTestRuntime` in each mod's own
  ## `config.json`, holding the repository-relative path
  ## `tests/mockil2cpp/GameAssembly.dll`. That is a development fixture living
  ## in a file `aowl payload` copies verbatim into the installer payload and
  ## from there into a player's game, and what it steers is a `LoadLibrary` of
  ## a second `GameAssembly.dll`. It fired on nothing only because the relative
  ## path resolved to nothing outside a checkout -- safe by accident.
  ##
  ## So the fixture is set by the harness that owns it, in the environment, and
  ## as an absolute path; the committed configs carry the key empty.
  ## `aowlspt/fixture` is the other half: a mod refuses a relative path
  ## outright, so a fixture cannot steer a real client however a `config.json`
  ## reaches one.
  let mock = joinPath(e.repo, "tests\\mockil2cpp\\GameAssembly.dll")
  if not fileExists(mock):
    return false
  try:
    putEnv("AOWLSPT_SELFTEST_RUNTIME", mock)
  except:
    warn "could not set AOWLSPT_SELFTEST_RUNTIME; the offline binding " &
         "reports will run against the process instead of the stand-in runtime"
    return false
  result = true

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

var gSkippedSymTab = false
var gSkippedNameIndex = false
var gSkipHadGameAsm = false

proc metaCachePath(e: Env): string =
  result = joinPath(e.repo, ".cache\\global-metadata.dec.dat")

proc reportSkippedGates(e: Env): int =
  ## The defect this exists for: both IL2CPP gates decline politely, mid-build,
  ## in a wall of otherwise-green output, and an agent shipped a build without
  ## noticing. A skipped check must never read as a pass -- so the verdict is
  ## repeated LAST, where the eye lands, and it is fatal when the skip was
  ## avoidable.
  ##
  ## Avoidable is a measurable thing, not a judgement call: if
  ## `GameAssembly.dll` is on this machine and `.cache\global-metadata.dec.dat`
  ## is not, the only thing missing is a per-worktree file that
  ## `aowl worktree-init` copies in seconds. That is a REFUSAL. If the game
  ## itself is absent the machine simply cannot run these gates, and refusing
  ## would make the repo unbuildable off the game box -- so that is a loud
  ## summary and exit 0.
  if not (gSkippedSymTab or gSkippedNameIndex):
    return 0
  if gSkipHadGameAsm:
    err "IL2CPP GATES SKIPPED -- this build is NOT verified against GameAssembly.dll"
    if gSkippedSymTab:
      note "  * abi\\aowlspt_symtab.h was NOT checked for staleness"
    if gSkippedNameIndex:
      note "  * no aowlspt-names.idx was emitted; by-name resolution is unavailable"
    note "cause: there is no " & metaCachePath(e)
    note "it is gitignored and NOT shared between worktrees. Fix, one command:"
    note "  aowl worktree-init      (copies it from a sibling checkout)"
    note "or decrypt it with tools\\metablob.py. Refusing rather than letting " &
         "a skipped gate read as a pass."
    return 1
  warn "IL2CPP GATES SKIPPED -- no GameAssembly.dll on this machine"
  if gSkippedSymTab:
    note "  * abi\\aowlspt_symtab.h was NOT checked for staleness (INCONCLUSIVE, not a pass)"
  if gSkippedNameIndex:
    note "  * no aowlspt-names.idx was emitted"
  note "this artifact is fine to compile with and NOT fit to deploy to the " &
       "live client until both are run on the game box."
  return 0

var gSymTabRan = false

proc symTab(e: Env): bool =
  ## Regenerate `abi/aowlspt_symtab.h` + `.nim` from `abi/aowlspt_symbols.txt`,
  ## then CHECK that nothing in `abi/`, `host/` or `mods/` references a symbol
  ## the generator rejected.
  ##
  ## This runs BEFORE anything that `#include`s the header, and it is the point
  ## where a by-name IL2CPP resolve stops being a silent client death and
  ## becomes a build error. A runtime name lookup goes through a TOKEN-GATED
  ## il2cpp export: called with the stock signature it does not fail, it
  ## returns a plausible random value, and nothing distinguishes that from
  ## success until something dereferences it -- at which point the client is
  ## gone, with a log byte-identical to a healthy run. There is no runtime
  ## check that catches it, so the resolve is done here instead.
  ##
  ## Three outcomes, each said out loud:
  ##   * inputs present -> regenerate AND check; either failing FAILS THE BUILD.
  ##   * inputs absent, header present -> NOT CHECKED, and it says so. A stale
  ##     header cannot be detected without the DLL to compare against, so this
  ##     is an INCONCLUSIVE, never a pass.
  ##   * inputs absent, no header -> anything that includes it will fail to
  ##     compile, which is the correct and loud outcome.
  ##
  ## The staleness story lives in the header itself: it records the image key
  ## and SHA-256 of the GameAssembly.dll every RVA came from, and `check`
  ## refuses on a mismatch. A Tarkov update therefore fails the build rather
  ## than shipping wrong-but-mapped addresses.
  if gSymTabRan:
    return true
  let gen = joinPath(e.repo, "tools\\il2cpp_symtab.py")
  let manifest = joinPath(e.repo, "abi\\aowlspt_symbols.txt")
  if not fileExists(gen) or not fileExists(manifest):
    return true
  let outH = joinPath(e.repo, "abi\\aowlspt_symtab.h")
  let outNim = joinPath(e.repo, "abi\\aowlspt_symtab.nim")
  var gameasm = getEnv("AOWLSPT_GAMEASM", "")
  if gameasm.len == 0:
    # THE INSTALL THE HOST RUNS AGAINST, not the retail copy. MEASURED
    # 2026-09-05 16:04: the retail D:/Games/Tarkov updated itself to 1.1.0.46911
    # while D:/Aowlspt (what the client boots) stayed 46777; every gate below then
    # read a different binary from the one the committed header describes and
    # refused a build whose sources had not changed. tools/gamepaths.py is the
    # same rule for the Python tools; AOWLSPT_GAMEASM overrides both.
    gameasm = "D:\\Aowlspt\\GameAssembly.dll"
    if not fileExists(gameasm):
      gameasm = "D:\\Games\\Tarkov\\GameAssembly.dll"
  let meta = joinPath(e.repo, ".cache\\global-metadata.dec.dat")

  if fileExists(gameasm) and fileExists(meta):
    gSymTabRan = true
    # ORDER MATTERS, and the first version of this got it wrong. `gen` then
    # `check` puts the staleness gate and the prologue gate AFTER the step that
    # rewrites the header from this same DLL -- so neither could ever fail,
    # whatever GameAssembly.dll was on disk. A gate that cannot fail is not a
    # gate. `verify-header` runs FIRST, against the header as committed, which
    # is where a Tarkov update, a hand-edited header or a stale commit is
    # genuinely detectable.
    if not run(e, "the committed symbol table still matches GameAssembly.dll",
               "python " & quoted(gen) & " verify-header " & quoted(gameasm) &
               " " & quoted(meta) & " " & quoted(manifest) & " " & quoted(outH),
               e.repo):
      note "the RVAs in abi\\aowlspt_symtab.h do not describe the " &
           "GameAssembly.dll on this machine. Regenerating would paper over " &
           "that; every consumer of a moved RVA needs looking at first. To " &
           "regenerate deliberately: python tools\\il2cpp_symtab.py gen ..."
      return false
    if not run(e, "the compile-time symbol table",
               "python " & quoted(gen) & " gen " & quoted(gameasm) & " " &
               quoted(meta) & " " & quoted(manifest) & " " & quoted(outH) &
               " " & quoted(outNim), e.repo):
      return false
    return run(e, "no source references a rejected or shared IL2CPP symbol",
               "python " & quoted(gen) & " check " & quoted(gameasm) & " " &
               quoted(meta) & " " & quoted(manifest) & " " & quoted(outH),
               e.repo)

  gSymTabRan = true
  gSkippedSymTab = true
  gSkipHadGameAsm = fileExists(gameasm)
  if fileExists(outH):
    note "abi\\aowlspt_symtab.h is present but " &
         (if fileExists(gameasm): "there is no .cache\\global-metadata.dec.dat"
          else: "there is no GameAssembly.dll at " & gameasm) &
         ", so it was NOT CHECKED for staleness here. That is inconclusive, " &
         "not a pass: run `python tools\\il2cpp_symtab.py check` on a machine " &
         "with the game installed before trusting a build for the live client."
    return true
  note "no abi\\aowlspt_symtab.h and no inputs to generate one. Anything " &
       "that includes it will fail to compile, which is the intended and " &
       "loud outcome -- set AOWLSPT_GAMEASM and decrypt the metadata with " &
       "tools/metablob.py."
  return true

var gIdxBindRan = false

proc idxBind(e: Env): bool =
  ## Build gate for POSITIONAL INDEX BINDINGS into the C managed-target tables
  ## in abi/. `il2cpp_symtab.py` proves each row's RVA is the method the row
  ## NAMES, and whether that RVA is shared. It cannot prove that index 19 in a
  ## .nim file means row 19 in the .h file -- and on 2026-08-24 it did not: a
  ## row inserted mid-table made `DuGetParent` resolve to
  ## `Transform::set_localPosition`, a byte-verified, non-shared, entirely
  ## valid function OF THE WRONG SHAPE, which faulted inside Unity on a
  ## receiver that had passed every liveness gate.
  ##
  ## This runs as a GATE, not a survey: an abi/ target array that is not
  ## registered in tools/idxbind.py fails the build, so a new table cannot be
  ## added unguarded, and INCONCLUSIVE (exit 2) is a failure too -- a checker
  ## that could not look has not passed.
  if gIdxBindRan:
    return true
  let tool = joinPath(e.repo, "tools\\idxbind.py")
  if not fileExists(tool):
    note "tools\\idxbind.py is not present on this branch, so no positional " &
         "index binding was checked. That is inconclusive, not a pass."
    gIdxBindRan = true
    return true
  gIdxBindRan = true
  return run(e, "every positional index into a C target table binds the row " &
             "its caller names",
             "python " & quoted(tool), e.repo)

var gSettingsBackedRan = false

proc settingsBacked(e: Env): bool =
  ## Build gate for the "renders but resolves to nothing" class.
  ##
  ## A mod declares a row with `intSetting("progressionPlayerLevel", ...)`. If
  ## that key has no entry in the mod's own `config.json`, the control still
  ## draws -- `Setting.toJson` falls back to `defaultJson` when the read fails
  ## -- and the mod's `asInt(setting(k), default)` still returns its default.
  ## Nothing anywhere says so. That is how three progression settings shipped
  ## declared, wired to real code, and unreachable.
  ##
  ## `tools/settingscheck.py` asserts the FINISHED STATE (the union of what the
  ## schema declares against what the file holds), not a property of anything
  ## it wrote, so deleting one key from any config.json turns it red naming the
  ## key and the mod. Exit 2 -- a schema it could not parse -- is INCONCLUSIVE
  ## and fails the build too: "I could not look" is not a pass.
  ##
  ## Runs once per invocation rather than once per mod: it already walks every
  ## mod, and `aowl build mods` would otherwise run it fifteen times.
  if gSettingsBackedRan:
    return true
  let tool = joinPath(e.repo, "tools\\settingscheck.py")
  if not fileExists(tool):
    note "tools\\settingscheck.py is not present on this branch, so no " &
         "declared setting was checked for a config.json key. That is " &
         "inconclusive, not a pass."
    gSettingsBackedRan = true
    return true
  gSettingsBackedRan = true
  return run(e, "every declared setting resolves to a key in its mod's " &
             "config.json",
             "python " & quoted(tool), e.repo)

var gNoEscapesRan = false

proc noEscapingImports(e: Env): bool =
  ## Build gate for the "compiles here and in no install" class.
  ##
  ## MEASURED 2026-09-02: `mods/manager` could not be compiled from a public
  ## payload. nimony died inside its own error renderer --
  ## `nifcursors.nim(149, 3) c.p != nil and c.rem > 0 [AssertionDefect]` --
  ## so the real error was never printed, and six builds agreed on the crash
  ## and on nothing else. The cause was one line, `mgr/refresh.nim`'s
  ## `import "../../../registry/validate"`: `aowl payload` stages `mods/`,
  ## `tools/`, `abi/` and `aowl/src`, and nothing else, so that file exists
  ## only in this checkout.
  ##
  ## A clean-nimcache rebuild does NOT catch this and that was measured too:
  ## with the cache deleted, `aowl build-mod mods\manager` built the broken
  ## source in 30s, because the import resolves fine when the compile happens
  ## inside the repo. So the gate asserts the payload-shape property directly,
  ## as a negative -- no file a mod ships resolves outside its own folder --
  ## which is falsifiable, unlike a rebuild whose input never varies in the
  ## dimension that breaks. Intra-mod `..` stays legal: the check resolves the
  ## literal and asks whether the result is still under the mod root.
  if gNoEscapesRan:
    return true
  let tool = joinPath(e.repo, "tools\\modbuild.py")
  if not fileExists(tool):
    note "tools\\modbuild.py is not present on this branch, so no mod was " &
         "checked for an import that escapes its own folder. That is " &
         "inconclusive, not a pass."
    gNoEscapesRan = true
    return true
  gNoEscapesRan = true
  return run(e, "no mod imports a file outside its own folder",
             "python " & quoted(tool) & " --audit-imports", e.repo)

proc buildMod(e: Env; modPathIn: string): bool =
  let modPath = absolutePathOf(modPathIn)
  let source = sourceOf(modPath)
  if source.len == 0:
    err "no single .nim source in " & modPath
    inc failures
    return false

  if not symTab(e):
    return false
  if not idxBind(e):
    return false
  if not settingsBacked(e):
    return false
  if not noEscapingImports(e):
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
  cmd.add " c --app:lib" & mimallocFlags
  # Mods get the ABI include path too.
  #
  # They did not, and the consequence was invisible until someone tried: a mod
  # cannot `import aowlspt/il2cpp` or `aowlspt/fast` without it, because those
  # reach the runtime through the C shims in `abi/`. So the fast path -- the
  # whole reason a native mod beats the C# it replaces -- was unreachable from
  # the one place it was for.
  cmd.add abiInclude(e)
  # ...and the mod's OWN directory, so a mod may keep private C headers beside
  # its Nim rather than pushing them into `abi/`.
  #
  # The generated C lands in `nimcache/`, not next to the source, so a plain
  # `#include "foo.h"` in an `{.emit.}` block resolves relative to nimcache and
  # fails -- which is why the only previous way to share C between a mod's own
  # files was to add to `abi/`, a surface every other mod and the host also
  # compile against. `mods/maps/sp/mapmath.h` is the first user: pure geometry
  # that belongs to one mod and that a shared header has no business carrying.
  # Include it as "sp/mapmath.h" -- the path is the mod root.
  cmd.add " --passC:-I" & quoted(dir)
  if e.debugBuild:
    cmd.add " -d:debug"
  cmd.add " -p:" & quoted(joinPath(e.repo, "aowl\\src"))
  # `abi/` as a NIM path, not only as a C include path.
  #
  # `abi/aowlspt_symtab.nim` is generated beside its own header and is the Nim
  # view of the same table. `mods/sain` needs it, and the only way to reach it
  # was a checkout-relative import -- `import ".." / ".." / ".." / abi /
  # aowlspt_symtab` -- which resolves inside the repo and NOWHERE ELSE.
  # Measured 2026-09-01, building a mods folder in a fresh install:
  # `client/drivecalls.nim(88, 1) Error: file not found: <install>\toolchain\abi`.
  # Since aowlspt ships mods as SOURCE, a mod that only compiles inside our
  # checkout is not a mod anybody else can build.
  #
  # Kept in step with `compile_cmd` in `tools/modbuild.py`, which is the same
  # command line for the same reason: two compile paths that drift produce
  # binaries differing for reasons nobody can see.
  cmd.add " -p:" & quoted(joinPath(e.repo, "abi"))
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
  cmd.add " c" & mimallocFlags
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

proc nameIndex(e: Env, binDir: string): bool =
  ## Regenerate `aowlspt-names.idx` beside the host DLL, and -- the part that
  ## matters -- REFUSE to leave a stale one lying there.
  ##
  ## The index is name -> code RVA, frozen from one GameAssembly.dll. A stale
  ## entry is not a missing function, it is a WRONG-BUT-MAPPED one, which is
  ## exactly the corruption the host's safety rules exist to prevent. The host
  ## checks the build stamp at load and refuses the whole file on mismatch, but
  ## that is the last line, not the first: an index that silently drifts is
  ## worse than no index, so the drift is caught HERE, at build time, where it
  ## is cheap.
  ##
  ## Three outcomes, and each says which one it took:
  ##   * inputs present  -> regenerate; a failure FAILS THE BUILD, because the
  ##     inputs were there and generation had no business failing.
  ##   * inputs absent, index present -> `check` it against whatever
  ##     GameAssembly.dll is here; a mismatch FAILS THE BUILD.
  ##   * inputs absent, no index -> say so and carry on. The host feature is
  ##     flag-gated default OFF and refuses cleanly with a reason when the file
  ##     is missing, so a machine without Tarkov installed can still build.
  let gen = joinPath(e.repo, "tools\\il2cpp_nameindex.py")
  if not fileExists(gen):
    return true
  let idx = joinPath(binDir, "aowlspt-names.idx")
  var gameasm = getEnv("AOWLSPT_GAMEASM", "")
  if gameasm.len == 0:
    # THE INSTALL THE HOST RUNS AGAINST, not the retail copy. MEASURED
    # 2026-09-05 16:04: the retail D:/Games/Tarkov updated itself to 1.1.0.46911
    # while D:/Aowlspt (what the client boots) stayed 46777; every gate below then
    # read a different binary from the one the committed header describes and
    # refused a build whose sources had not changed. tools/gamepaths.py is the
    # same rule for the Python tools; AOWLSPT_GAMEASM overrides both.
    gameasm = "D:\\Aowlspt\\GameAssembly.dll"
    if not fileExists(gameasm):
      gameasm = "D:\\Games\\Tarkov\\GameAssembly.dll"
  let meta = joinPath(e.repo, ".cache\\global-metadata.dec.dat")

  if fileExists(gameasm) and fileExists(meta):
    return run(e, "the name->RVA index",
               "python " & quoted(gen) & " gen " & quoted(gameasm) & " " &
               quoted(meta) & " " & quoted(idx), e.repo)

  if fileExists(idx):
    if fileExists(gameasm):
      return run(e, "the name->RVA index still matches GameAssembly.dll",
                 "python " & quoted(gen) & " check " & quoted(gameasm) & " " &
                 quoted(idx), e.repo)
    note "aowlspt-names.idx is present but GameAssembly.dll is not, so it " &
         "could NOT be checked for staleness here. The host verifies the " &
         "build stamp at load and refuses the whole index on mismatch."
    return true

  gSkippedNameIndex = true
  if fileExists(gameasm):
    gSkipHadGameAsm = true
  note "no aowlspt-names.idx generated: " &
       (if fileExists(gameasm): "no .cache\\global-metadata.dec.dat (decrypt " &
                                "it with tools/metablob.py)"
        else: "no GameAssembly.dll at " & gameasm & " (set AOWLSPT_GAMEASM)") &
       ". By-name method resolution will be unavailable; the nameIndex flag " &
       "is default-OFF and declines with a reason, so nothing else changes."
  return true

proc buildIl2CppHost(e: Env): bool =
  let dir = joinPath(e.repo, "host\\Aowlspt.Host.Il2Cpp")
  let source = joinPath(dir, "aowlhost.nim")
  if not fileExists(source):
    err "no aowlhost.nim under " & dir
    inc failures
    return false
  if not symTab(e):
    return false
  if not idxBind(e):
    return false
  let binDir = joinPath(dir, "bin")
  discard ensureDir(binDir)
  let outPath = joinPath(binDir, "aowlspt-host-il2cpp.dll")
  discard removeFileAt(outPath)

  var cmd = quoted(nimonyExe(e))
  cmd.add " c --app:lib" & mimallocFlags
  cmd.add abiInclude(e)
  if e.debugBuild:
    cmd.add " -d:debug"
  cmd.add " -p:" & quoted(joinPath(e.repo, "aowl\\src"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "installer\\src"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "host\\common"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "host\\Aowlspt.Overlay"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "host\\Aowlspt.Graphics"))
  cmd.add " -o:" & quoted(outPath)
  cmd.add " " & quoted(source)
  if not run(e, "aowlspt-host-il2cpp", cmd, dir):
    return false
  if not nameIndex(e, binDir):
    return false
  result = placeLibrary(dir, "aowlhost", outPath)

proc buildMapTiles(e: Env): bool =
  ## `mods/maps`' SVG map art -> BC1 tiles + a binary manifest, via
  ## `tools/maptiles.py`. The output is COMMITTED (it is 18 MiB of art that
  ## changes only when the calibration does), so this is not part of a normal
  ## edit loop and is deliberately NOT run by bare `aowl build` -- a full
  ## rasterise is ~4 minutes and nothing about a host change invalidates it.
  ##
  ## It runs `verify` first. That is the whole point of having a target: a
  ## human who changed a calibration JSON gets told the shipped tiles no longer
  ## match it, instead of finding out from a misplaced building in a raid.
  let py = joinPath(e.repo, "tools\\maptiles.py")
  if not fileExists(py):
    err "no tools\\maptiles.py under " & e.repo
    inc failures
    return false
  if not run(e, "maptiles selftest", "python " & quoted(py) & " selftest",
             e.repo):
    return false
  if not run(e, "maptiles build", "python " & quoted(py) & " build", e.repo):
    return false
  result = run(e, "maptiles verify", "python " & quoted(py) & " verify", e.repo)

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

  # The LOGS screen: the facet rule, the ring, the split-line reader, and --
  # the part that cannot be argued about -- that `logFilt` is EXACTLY the set
  # of held lines the predicate passes, over the whole cross product of the
  # four filters. Built -O2 rather than -O1 because it also MEASURES the
  # per-frame rebuild and asserts a ceiling on it.
  if not run(e, "the overlay's logs screen",
    "gcc -O2 -Wno-unused-function -I" & inc & " " &
    quoted(joinPath(dir, "logstest.c")) & " -o " &
    quoted(joinPath(dir, "logstest.exe")), dir):
    okAll = false
  elif not run(e, "overlay logs checks", quoted(joinPath(dir, "logstest.exe")), dir):
    okAll = false

  # The F3 widgets' RENDER path: the region command shape crossing into the
  # rasteriser. The widgets used to be cloned TextMeshPro labels in the game's
  # canvas, which had NO offline check at all -- that is how the same feature
  # failed six times, the last three of them with a walk that succeeded and
  # rendered nothing. This is the check that approach could never have.
  if not run(e, "the F3 widgets' render path",
    "gcc -O2 -Wno-unused-function -I" & inc & " " &
    quoted(joinPath(dir, "f3test.c")) & " -o " &
    quoted(joinPath(dir, "f3test.exe")), dir):
    okAll = false
  elif not run(e, "F3 render checks", quoted(joinPath(dir, "f3test.exe")), dir):
    okAll = false

  # The maps overlay's GEOMETRY: the top-down projection behind the in-game map
  # and the radar, the screen-edge clamp behind the directional indicators, and
  # the pocketmap tile selection. All of it is pure arithmetic over its
  # arguments, so all of it is checkable with no client -- which matters more
  # here than almost anywhere, because a mirrored map, a radar off by a factor
  # of two, and an indicator pointing at the reflection of a contact behind the
  # camera all look completely plausible on screen. Each of those three is a
  # case in this file.
  if not run(e, "the maps overlay geometry",
    "gcc -O2 -Wall -Wno-unused-function -I" & inc & " " &
    quoted(joinPath(dir, "mapstest.c")) & " -o " &
    quoted(joinPath(dir, "mapstest.exe")) & " -lm", dir):
    okAll = false
  elif not run(e, "maps geometry checks",
               quoted(joinPath(dir, "mapstest.exe")), dir):
    okAll = false

  # The NATIVE UI layer's pure logic: the renderability predicate, the polled
  # hit test, the component-slot verdict machine, the ownership table and the
  # string-intern refusals. It belongs offline for exactly the reason the F3
  # widgets do -- the failure it guards against is an element that is created
  # successfully, reports success at every step, and renders nothing. A 0x0
  # rect is that failure, and here it is one assertion instead of a build,
  # deploy, launch and a human looking at the screen.
  if not run(e, "the native UI layer's logic",
    "gcc -O2 -Wall -Wno-unused-function -I" & inc & " " &
    quoted(joinPath(dir, "nativeuitest.c")) & " -o " &
    quoted(joinPath(dir, "nativeuitest.exe")), dir):
    okAll = false
  elif not run(e, "native UI checks",
               quoted(joinPath(dir, "nativeuitest.exe")), dir):
    okAll = false

  # The BACKEND-AGNOSTIC widget core (abi/aowlspt_ui.h): layout arithmetic, the
  # tab-selection state machine, the polled hit-test/dispatch, and config
  # binding. It sits ABOVE the overlay/native backend split and is pure state,
  # so all of it -- the whole shared core of the unified UI framework -- is
  # checkable here. Half the cases assert a negative and `falsify()` feeds the
  # predicates wrong values, so a check replaced by `return 1` turns this red.
  if not run(e, "the unified UI widget core",
    "gcc -O2 -Wall -Wno-unused-function -I" & inc & " " &
    quoted(joinPath(dir, "uitest.c")) & " -o " &
    quoted(joinPath(dir, "uitest.exe")) & " -lm", dir):
    okAll = false
  elif not run(e, "unified UI widget-core checks",
               quoted(joinPath(dir, "uitest.exe")), dir):
    okAll = false

  # THE OVERLAY CURSOR-FREE DECISION. `abi/aowlspt_cursor.h` splits so that the
  # whole decision -- the ref count that is a level rather than a counter, the
  # save/restore edges, the re-assert hold, the unwind-on-disable -- is pure
  # arithmetic compiled here with AOWL_CUR_PURE and asserted OFFLINE. It belongs
  # offline for the reason the F3 widgets do, and for one more: the failure it
  # guards against is a cursor left FREED in a raid after our code stopped
  # running, which no amount of looking at a working session would ever reveal.
  if not run(e, "the overlay cursor-free decision",
    "gcc -O2 -Wall -Wextra -Wno-unused-function -I" & inc & " " &
    quoted(joinPath(dir, "cursortest.c")) & " -o " &
    quoted(joinPath(dir, "cursortest.exe")), dir):
    okAll = false
  elif not run(e, "overlay cursor checks",
               quoted(joinPath(dir, "cursortest.exe")), dir):
    okAll = false

  if not run(e, "overlay header needs no extra link library",
    "gcc -O1 -Wno-unused-function -I" & inc & " " &
    quoted(joinPath(dir, "linkprobe.c")) & " -o " &
    quoted(joinPath(dir, "linkprobe.exe")), dir):
    okAll = false

  var cmd = quoted(nimonyExe(e))
  cmd.add " c" & mimallocFlags
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
  cmd.add " c" & mimallocFlags
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
  cmd.add " c" & mimallocFlags
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
  cmd.add " c" & mimallocFlags
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
  cmd.add " c" & mimallocFlags
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
  cmd.add " c" & mimallocFlags
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
  cmd.add " c" & mimallocFlags
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
  cmd.add " c" & mimallocFlags
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
  cmd.add " c" & mimallocFlags
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
  cmd.add " c" & mimallocFlags
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
  cmd.add " c" & mimallocFlags
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
  cmd.add " c" & mimallocFlags
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
  cmd.add " c" & mimallocFlags
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
  cmd.add " c" & mimallocFlags
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
  cmd.add " c" & mimallocFlags
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
  cmd.add " c" & mimallocFlags
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
  cmd.add " c" & mimallocFlags
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
  cmd.add " c" & mimallocFlags
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
  cmd.add " c" & mimallocFlags
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
  cmd.add " c" & mimallocFlags & " -p:" & quoted(joinPath(dir, "src"))
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

# ------------------------------------------------------- the deploy set

proc deploySrcPaths(e: Env): seq[string] =
  ## Every `src` path named by `tools/deploy.json`, in file order.
  ##
  ## DERIVED, never duplicated. `python tools\deploy.py check` verifies exactly
  ## this list; the build that precedes it must therefore cover exactly this
  ## list. Until 2026-08-27 it did not: the `deploy` target built four things
  ## while the checker verified sixteen, so ten mods reached a beta only if
  ## somebody separately remembered `aowl build mods`. A second hand-written
  ## list here would just be the same bug with a shorter fuse -- so there is
  ## no list here, only a reader.
  result = @[]
  var text = ""
  if not readTextFile(joinPath(e.repo, "tools\\deploy.json"), text):
    err "cannot read tools\\deploy.json, so the deploy target cannot know " &
        "what to build. Refusing to build a guess."
    inc failures
    return
  var i = 0
  while i < text.len:
    var j = i
    while j < text.len and text[j] != '\n':
      inc j
    var line = text.substr(i, j - 1)
    i = j + 1
    line = strip(line)
    if not startsWith(line, "\"src\""):
      continue
    let c = find(line, ':')
    if c < 0:
      continue
    var v = strip(line.substr(c + 1, line.len - 1))
    if endsWith(v, ","):
      v = strip(v.substr(0, v.len - 2))
    if v.len < 2 or v[0] != '"' or v[v.len - 1] != '"':
      err "tools\\deploy.json: could not read a src value from: " & line
      inc failures
      continue
    result.add v.substr(1, v.len - 2)

proc buildDeploySet(e: Env): int =
  ## Build every artifact `deploy.py check` will look at.
  ##
  ## An entry this cannot map to a build step is a LOUD failure, not a skip.
  ## That is the whole safety property: adding an artifact to deploy.json can
  ## no longer quietly leave it unbuilt, and the fix is to teach this proc how
  ## to build it -- never to delete the entry from deploy.json.
  let srcs = deploySrcPaths(e)
  if srcs.len == 0:
    err "tools\\deploy.json named no artifacts. That is not a deploy build."
    inc failures
    return 1
  var builtHost = false
  var builtBackend = false
  var builtLaunch = false
  var mods = 0
  for s in srcs:
    let p = normSep(s)
    if startsWith(p, "host\\Aowlspt.Host.Il2Cpp\\bin\\"):
      # The host DLL and both name-index files all come out of one build.
      if not builtHost:
        builtHost = true
        discard buildIl2CppHost(e)
    elif startsWith(p, "backend\\bin\\"):
      if not builtBackend:
        builtBackend = true
        discard buildBackend(e)
    elif p == "installer\\build\\aowlspt-launch.exe":
      if not builtLaunch:
        builtLaunch = true
        discard buildTool(e, "tools\\aowllaunch.nim", "aowlspt-launch.exe",
                          "aowlspt-launch")
    elif endsWith(p, ".dll") and find(p, "\\bin\\") > 0:
      let cut = find(p, "\\bin\\")
      inc mods
      discard buildMod(e, joinPath(e.repo, p.substr(0, cut - 1)))
    elif find(p, "\\bin\\") < 0 and not startsWith(p, "installer\\build\\") and
         (fileExists(joinPath(e.repo, p)) or isDirectory(joinPath(e.repo, p))):
      # Checked-in data that is SHIPPED but not BUILT -- `registry\mods.json`
      # is the first of these. It is deliberately not silent: the condition
      # requires the file to exist in the repo right now, so a typo'd or
      # deleted path still falls through to the loud error below rather than
      # being waved past as "probably data".
      #
      # A shipped data artifact may also be a DIRECTORY (`mods\tarkov\data`,
      # `mods\maps\data`, ...). The original condition tested `fileExists`
      # only, so every directory entry fell through to the loud error and
      # failed the whole `build deploy` target -- the file-only case was the
      # only one exercised when this was written. `isDirectory` is the same
      # existence test for the other kind: a typo'd path is neither a file nor
      # a directory and still reaches the error below.
      note "deploy set: " & s & " is checked-in data, nothing to build"
    else:
      err "tools\\deploy.json ships '" & s & "' and this build target does " &
          "not know how to build it."
      note "teach buildDeploySet in tools\\aowl.nim how -- do NOT delete the " &
           "entry from deploy.json to make this quiet."
      inc failures
  note "deploy set: " & $srcs.len & " artifact(s) named by deploy.json, " &
       $mods & " of them mods"
  result = if failures > 0: 1 else: 0

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

proc textStamp(path: string): string =
  ## A content hash of one file, in the same djb2 shape `abiStamp` uses and for
  ## the same reason: a checkout or a revert restores old bytes with a new
  ## timestamp, so "the same bytes as last time" is the question worth asking,
  ## not "touched since".
  var text = ""
  if not readTextFile(path, text):
    return ""
  var h = 5381
  for ch in text:
    h = ((h * 33) + ord(ch)) and 0x3FFFFFFF
  result = $h

proc driverStampPath(e: Env): string =
  result = joinPath(e.repo, "installer\\build\\.aowlstamp")

proc driverSource(e: Env): string =
  result = joinPath(e.repo, "tools\\aowl.nim")

proc staleDriverReason(e: Env): string =
  ## The trap this exists for, which has cost real time more than once:
  ##
  ## **`aowl build` does not build `aowl.exe`.** Nothing does -- there is no
  ## target for it anywhere, and `installer/build/` is gitignored. So a fresh
  ## worktree has *no* driver at all, and a worktree whose `aowl.exe` was
  ## copied in from somewhere else has a driver from a different commit. Edit
  ## `tools/aowl.nim` -- add a target, change a copy step, fix a staging bug --
  ## run `aowl build`, and every one of the sixteen mods reports `ok` while the
  ## change you made did not run. The build is a success and the edit did not
  ## ship. Nothing anywhere says so.
  ##
  ## `aowl bootstrap` is the fix; this is the detector. It returns the REASON,
  ## empty when the driver beside this source is the driver that was built from
  ## it. `refuseIfStaleDriver` turns a reason into an exit code -- this used to
  ## only warn, and a warning printed above four minutes of `ok` lines is a
  ## warning nobody reads.
  ##
  ## An empty stamp for the SOURCE (unreadable `tools/aowl.nim`) returns "" --
  ## that is "I could not look", and it must not read as either verdict; it is
  ## the one case where nothing is asserted, and the driver source is missing
  ## only in a payload-shaped tree that is not building anyway.
  result = ""
  let exe = joinPath(e.repo, "installer\\build\\aowl.exe")
  let now = textStamp(driverSource(e))
  if now.len == 0:
    return ""
  var was = ""
  discard readTextFile(driverStampPath(e), was)
  if not fileExists(exe):
    return "there is no installer\\build\\aowl.exe in this worktree, so the " &
           "driver running this build was not built from this source"
  if was == now:
    return ""
  # Three states, not two. Collapsing the middle one is what made this warning
  # fire on EVERY invocation in a fresh worktree and trained people to ignore
  # it -- and a warning that always fires is worth less than no warning, since
  # the case it exists for looks identical.
  #
  # `.aowlstamp` lives in the gitignored `installer\build\`, so a worktree
  # whose driver was COPIED in from another checkout has an aowl.exe and no
  # stamp at all. That is a real hazard (CLAUDE.md 3: the copy runs the OTHER
  # checkout's aowl.nim), so it still warns -- but it is a different fault with
  # a different fix, and it now says which one it is.
  if was.len == 0:
    return "installer\\build\\aowl.exe has NO build stamp beside it -- it was " &
           "not built from this worktree's tools\\aowl.nim, most likely copied " &
           "in from another checkout, in which case it runs THAT checkout's " &
           "driver and any build step added on this branch goes silently " &
           "unexercised"
  result = "tools\\aowl.nim has changed since aowl.exe was last built -- this " &
           "build would run the OLD driver, and your change to it is not in it"

proc refuseIfStaleDriver(e: Env): int =
  ## REFUSE, do not warn. CLAUDE.md section 3: "a build step defined on your
  ## branch goes SILENTLY UNEXERCISED -- this has bitten three agents." The
  ## detector was already correct and already printed; what it could not do was
  ## stop the build, so the evidence scrolled past and the build reported ok.
  ##
  ## Exit 4, the same code `build` outside the lock uses, because it is the
  ## same kind of fault: the command did nothing, and it must not be mistaken
  ## for a compile failure (1) by anything reading the exit code.
  let why = staleDriverReason(e)
  if why.len == 0:
    return 0
  if e.allowStaleDriver:
    warn why
    note "continuing anyway: --allow-stale-driver was passed. Anything you " &
         "changed in tools\\aowl.nim is NOT in this build."
    return 0
  err "REFUSED: " & why
  note "run `python tools\\buildlock.py bootstrap` (it takes the same lock), " &
       "then build again"
  note "pass --allow-stale-driver to build with the driver you have anyway"
  result = 4

proc seedCache(e: Env): bool =
  ## `.cache\global-metadata.dec.dat` is gitignored, so it is NOT shared between
  ## worktrees -- and without it both IL2CPP build gates decline. It is the same
  ## bytes in every checkout (it is derived from the installed game, not from
  ## the branch), so copying it in is safe and is the whole of "worktree setup".
  ##
  ## Candidates are named, never enumerated: a recursive scan of a Projects
  ## directory is slow and can pick up something unrelated. Whatever it uses,
  ## it says.
  let dst = metaCachePath(e)
  if fileExists(dst):
    ok "metadata cache present (" & dst & ")"
    return true
  var candidates: seq[string] = @[]
  let fromEnv = getEnv("AOWLSPT_METADATA", "")
  if fromEnv.len > 0:
    candidates.add fromEnv
  var cur = parentOf(e.repo)
  var hops = 0
  while cur.len > 0 and hops < 4:
    candidates.add joinPath(cur, "aowlspt\\.cache\\global-metadata.dec.dat")
    let up = parentOf(cur)
    if up.len == 0 or up == cur:
      break
    cur = up
    inc hops
  for c in candidates:
    if c == dst:
      continue
    if not fileExists(c):
      continue
    discard ensureDir(joinPath(e.repo, ".cache"))
    let r = copyFileAt(c, dst)
    if r.ok:
      ok "seeded .cache\\global-metadata.dec.dat from " & c
      return true
    warn "could not copy " & c & " (error " & $r.err & ")"
  warn "no .cache\\global-metadata.dec.dat, and none found to copy"
  note "looked for a sibling checkout's copy; set AOWLSPT_METADATA to point at " &
       "one, or decrypt it with tools\\metablob.py"
  note "without it `aowl build host` cannot check the symbol table and emits " &
       "no name index -- it will say so and refuse"
  result = false

proc cmdBootstrap(e: Env): int =
  ## Rebuild `aowl.exe` itself.
  ##
  ## The running image cannot be overwritten, but it can be *renamed* -- so the
  ## new driver is compiled beside it and then swapped in by two renames, which
  ## works whether or not this process is the one being replaced.
  let outDir = joinPath(e.repo, "installer\\build")
  discard ensureDir(outDir)
  let exe = joinPath(outDir, "aowl.exe")
  let nextExe = joinPath(outDir, "aowl-next.exe")
  let oldExe = joinPath(outDir, "aowl.exe.old")
  discard removeFileAt(nextExe)

  var cmd = quoted(nimonyExe(e))
  cmd.add " c" & mimallocFlags
  cmd.add abiInclude(e)
  cmd.add " -p:" & quoted(joinPath(e.repo, "installer\\src"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "aowl\\src"))
  cmd.add " -o:" & quoted(nextExe)
  cmd.add " " & quoted(driverSource(e))
  if not run(e, "aowl.exe", cmd, e.repo):
    return 1
  if not fileExists(nextExe):
    err "the compile reported success but produced no aowl-next.exe"
    return 1

  if fileExists(exe):
    discard removeFileAt(oldExe)
    let moved = replaceFileAt(exe, oldExe)
    if not moved.ok:
      err "could not move the running aowl.exe aside (error " & $moved.err & ")"
      note "the new driver is at " & nextExe & "; rename it by hand"
      return 1
  let placed = replaceFileAt(nextExe, exe)
  if not placed.ok:
    err "could not put the new aowl.exe in place (error " & $placed.err & ")"
    return 1
  discard writeTextFile(driverStampPath(e), textStamp(driverSource(e)))
  discard seedCache(e)
  ok "aowl.exe rebuilt"
  note "the copy that is running is still the old one; the next invocation is new"
  result = 0

proc escapeForNim(p: string): string =
  ## A Windows path inside a generated Nim string literal. Every backslash is
  ## doubled; without this `C:\Users\...\tarkov` ends up containing a tab and a
  ## form feed and the generated file does not compile, or worse, compiles.
  result = ""
  for ch in p:
    if ch == chr(92):
      result.add chr(92)
      result.add chr(92)
    else:
      result.add ch

proc cmdSelfCheck(e: Env; modPath: string): int =
  ## Run a mod's `selfCheckFailures()` OUT OF PROCESS.
  ##
  ## Before this, reading a load-time self-check meant standing up a whole
  ## backend -- impossible while a human is playing -- so one agent wrote a
  ## throwaway `tools/bosscheck.nim` to get at it and another hit the same wall
  ## with `emutest.exe`, which wants a full install. The checks themselves need
  ## none of that: they are arithmetic over tables in `emu/selfchecks`, with no
  ## database, no host and no profile, which is the whole reason they are the
  ## ones that run at load.
  ##
  ## So this generates a four-line main that imports that module, compiles it
  ## with nimony, and runs it. `mods\tarkov\emu\selfchecks.nim` is the
  ## convention; a mod without one is told so rather than reported as passing,
  ## because "there was nothing to check" and "everything checked out" are not
  ## the same answer.
  var dir = modPath
  if not isDirectory(dir):
    dir = joinPath(e.repo, modPath)
  if not isDirectory(dir):
    err "no such mod directory: " & modPath
    return 1
  let checks = joinPath(dir, "emu\\selfchecks.nim")
  if not fileExists(checks):
    err "no emu\\selfchecks.nim under " & dir
    note "there is nothing to run here. That is INCONCLUSIVE, not a pass."
    return 1

  let outDir = joinPath(e.repo, "installer\\build")
  discard ensureDir(outDir)
  let shim = joinPath(outDir, "selfcheck_main.nim")
  let exe = joinPath(outDir, "selfcheck.exe")
  discard removeFileAt(exe)
  # A host MUST be bound before the checks run. `modDir()` comes from the host
  # info block and is `""` without one, so `data/post1/*.json` resolves to
  # `/data/post1/...` and three checks report "is not installed" -- a FALSE
  # FAIL, and a self-check tool that invents failures is worse than no tool.
  # `aowl_hostapi_new` in abi/aowlspt_shim.h is exactly the stub needed: it
  # takes modDir and dataDir as strings.
  var src = "import std/syncio\n"
  src.add "import aowlspt\n"
  src.add "import emu/selfchecks\n"
  src.add "{.emit: \"\"\"#include <stdint.h>\"\"\".}\n"
  src.add "{.emit: \"\"\"#include <stdlib.h>\"\"\".}\n"
  src.add "{.emit: \"\"\"#include <string.h>\"\"\".}\n"
  src.add "{.emit: \"\"\"#include \"aowlspt_abi.h\" \"\"\".}\n"
  src.add "{.emit: \"\"\"#include \"aowlspt_shim.h\" \"\"\".}\n"
  # aowlspt_shim.h's host block forwards every callback to an `aowlspt_nim_*`
  # symbol that the SIMULATOR provides. None of them is reachable from a check
  # that touches no route, no database and no game -- but the linker still
  # wants all eighteen, so they are stubbed here. Each refuses (`-1`) rather
  # than returning a plausible zero: if a check ever does reach one, it must
  # fail loudly and not quietly read an empty answer as a real one. `log` is
  # the exception and really prints, because the checks warn through it.
  src.add "{.emit: \"\"\"\n"
  src.add "#include <stdio.h>\n"
  src.add "void aowlspt_nim_log(void* c, int32_t lv, void* m, int32_t n)" &
          " { (void)c; (void)lv; fprintf(stderr, \"    host: %.*s\\n\", (int)n, (const char*)m); }\n"
  src.add "void aowlspt_nim_last_error(void* c, void* p, void* n)" &
          " { (void)c; *(void**)p = 0; *(int32_t*)n = 0; }\n"
  src.add "int32_t aowlspt_nim_config_get(void* c, void* k, int32_t kl, void* p, void* n) { return -1; }\n"
  src.add "int32_t aowlspt_nim_config_set(void* c, void* k, int32_t kl, void* v, int32_t vl) { return -1; }\n"
  src.add "int32_t aowlspt_nim_call(void* c, void* t, int32_t tl, void* a, int32_t al, void* p, void* n) { return -1; }\n"
  src.add "int32_t aowlspt_nim_resolve(void* c, void* t, int32_t tl, void* h) { return -1; }\n"
  src.add "void aowlspt_nim_handle_release(void* c, uint64_t h) { (void)c; (void)h; }\n"
  src.add "int32_t aowlspt_nim_event_emit(void* c, void* nm, int32_t nl, void* p, int32_t pl) { return -1; }\n"
  src.add "int64_t aowlspt_nim_now_ms(void* c) { (void)c; return 0; }\n"
  src.add "int32_t aowlspt_nim_invoke_main(void* c, void* cb, void* u) { return -1; }\n"
  src.add "int32_t aowlspt_nim_schedule(void* c, int32_t d, void* cb, void* u) { return -1; }\n"
  src.add "int32_t aowlspt_nim_event_subscribe(void* c, void* nm, int32_t nl, void* h, void* u) { return -1; }\n"
  src.add "int32_t aowlspt_nim_patch(void* c, void* t, int32_t tl, int32_t k, void* h, void* u) { return -1; }\n"
  src.add "int32_t aowlspt_nim_db_get(void* c, void* p, int32_t pl, void* op, void* on) { return -1; }\n"
  src.add "int32_t aowlspt_nim_db_patch(void* c, void* p, int32_t pl, void* v, int32_t vl) { return -1; }\n"
  src.add "int32_t aowlspt_nim_route_register(void* c, void* u, int32_t ul, int32_t k, void* h, void* us) { return -1; }\n"
  src.add "int32_t aowlspt_nim_store_get(void* c, void* k, int32_t kl, void* op, void* on) { return -1; }\n"
  src.add "int32_t aowlspt_nim_store_set(void* c, void* k, int32_t kl, void* v, int32_t vl) { return -1; }\n"
  src.add "int32_t aowlspt_nim_store_list(void* c, void* p, int32_t pl, void* op, void* on) { return -1; }\n"
  src.add "\"\"\".}\n"
  src.add "proc cHostNew(ctx: pointer; side: int32; hostName, hostVersion, " &
          "sptVersion, gameVersion, modDir, dataDir: cstring): pointer " &
          "{.importc: \"aowl_hostapi_new\", nodecl.}\n"
  src.add "var api: ModApi\n"
  src.add "let hostPtr = cHostNew(cast[pointer](0), 3, \"aowl selfcheck\", " &
          "\"0\", \"0\", \"0\", \"" & escapeForNim(dir) & "\", \"" &
          escapeForNim(joinPath(e.repo, "mods")) & "\")\n"
  src.add "if bindHost(cast[ptr HostApi](hostPtr), addr api) != Ok:\n"
  src.add "  echo \"FAIL could not bind the stub host; modDir would be empty " &
          "and every data-file check would report a false failure\"\n"
  src.add "  quit(2)\n"
  src.add "let fails = selfCheckFailures()\n"
  src.add "for f in fails:\n"
  src.add "  echo \"FAIL \" & f\n"
  src.add "echo \"selfcheck failures: \" & $(fails.len)\n"
  src.add "quit(if fails.len > 0: 1 else: 0)\n"
  let w = writeTextFile(shim, src)
  if not w.ok:
    err "could not write " & shim & " (error " & $w.err & ")"
    return 1

  var cmd = quoted(nimonyExe(e))
  cmd.add " c" & mimallocFlags
  cmd.add abiInclude(e)
  cmd.add " -p:" & quoted(dir)
  cmd.add " -p:" & quoted(joinPath(e.repo, "aowl\\src"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "installer\\src"))
  cmd.add " -p:" & quoted(joinPath(e.nimony, "src\\lib"))
  cmd.add " -o:" & quoted(exe)
  cmd.add " " & quoted(shim)
  if not run(e, "the self-check harness for " & baseName(dir), cmd, e.repo):
    return 1
  if not fileExists(exe):
    err "the compile reported success but produced no selfcheck.exe"
    return 1
  # The exit code is the verdict; the failures print themselves.
  if not run(e, baseName(dir) & " self-checks", quoted(exe), e.repo):
    return 1
  result = 0

proc cmdLootHash(e: Env; extra: seq[string]): int =
  ## `aowl loothash` -- the deterministic generate-and-hash instrument for loot.
  ##
  ## It exists because there was no way to CHECK "defaults reproduce current
  ## behaviour"; it was only ever argued from control flow, which is not a
  ## measurement of output. Same seed, defaults on, before and after a change:
  ## the digest must be identical. Then move one knob: the digest must MOVE. A
  ## check whose failing input you cannot name is not a check, so the second
  ## half is the one that makes the first half mean anything.
  ##
  ## Built with the same stub host `selfcheck` uses -- `config_get` refuses, so
  ## every setting reads its default and the run cannot be perturbed by whatever
  ## happens to be in someone's `config.json`. That is the point: this is a
  ## measurement of the CODE at defaults, not of an installation.
  let modDir = joinPath(e.repo, "mods\\tarkov")
  if not isDirectory(modDir):
    err "no mods\\tarkov in this checkout"
    return 1
  let outDir = joinPath(e.repo, "installer\\build")
  discard ensureDir(outDir)
  let exe = joinPath(outDir, "loothash.exe")
  var cmd = quoted(nimonyExe(e))
  cmd.add " c" & mimallocFlags
  cmd.add abiInclude(e)
  cmd.add " -p:" & quoted(modDir)
  cmd.add " -p:" & quoted(joinPath(e.repo, "aowl\\src"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "installer\\src"))
  cmd.add " -p:" & quoted(joinPath(e.nimony, "src\\lib"))
  cmd.add " -o:" & quoted(exe)
  cmd.add " " & quoted(joinPath(e.repo, "tools\\loothash_main.nim"))
  if not run(e, "the loot hash instrument", cmd, e.repo):
    return 1
  if not fileExists(exe):
    err "the compile reported success but produced no loothash.exe"
    return 1
  var invocation = quoted(exe)
  for a in extra:
    invocation.add " " & quoted(a)
  var code = -1
  try:
    let (o, c) = execCmdEx(invocation, workingDir = e.repo)
    for l in splitLines(o):
      echo l
    code = c
  except:
    err "loothash.exe could not be run"
    return 1
  result = code

proc cmdWorktreeInit(e: Env): int =
  ## Everything a FRESH `git worktree add` needs before it can build, in one
  ## command, because the worktree-per-agent rule (CLAUDE.md 3) makes this a
  ## per-agent ritual and three agents in one night each rediscovered it by
  ## hand.
  ##
  ## Note what this does NOT need: an existing `aowl.exe`. If you are reading
  ## this you already have one. From nothing at all the entry point is
  ## `powershell -File tools\bootstrap.ps1`, which runs the same nimony command
  ## `cmdBootstrap` does.
  heading "Worktree setup"
  discard ensureDir(joinPath(e.repo, "installer\\build"))
  ok "installer\\build exists"
  discard seedCache(e)
  result = cmdBootstrap(e)

proc commaParts(spec: string): seq[string] =
  ## `a,b , c` -> @["a", "b", "c"]. Hand-rolled: this file is nimony, and the
  ## `split`/`sequtils` surface it would otherwise reach for is not in use
  ## anywhere else here.
  result = @[]
  var cur = ""
  var i = 0
  while i < spec.len:
    if spec[i] == ',':
      let p = strip(cur)
      if p.len > 0:
        result.add p
      cur = ""
    else:
      cur.add spec[i]
    inc i
  let last = strip(cur)
  if last.len > 0:
    result.add last

proc modNameOf(raw: string): string =
  ## Accept `maps`, `mods\maps` and `mods/maps` for the same mod. An agent that
  ## has just typed `aowl build-mod mods\maps` will type the path here too, and
  ## refusing it by name would be a refusal that is technically right and
  ## useless.
  var s = raw
  if s.startsWith("mods\\") or s.startsWith("mods/"):
    s = s.substr(5, s.len - 1)
  while s.len > 0 and (s[s.len - 1] == '\\' or s[s.len - 1] == '/'):
    s = s.substr(0, s.len - 2)
  result = s

proc buildNamedMods(e: Env; spec: string): int =
  ## `aowl build mod maps` / `aowl build mods maps,tarkov`.
  ##
  ## MEASURED 2026-09-02: there was no way to rebuild ONE mod under the build
  ## lock. `tools/buildlock.py` can only exec `aowl <target>`, `build-mod` is a
  ## separate verb rather than a target, and so a one-mod change cost either a
  ## full `build mods` (all of them) or a hand-run nimony/modbuild -- the
  ## unserialised path CLAUDE.md section 3 exists to forbid. Agents took both.
  ##
  ## It goes through `buildMod`, the SAME proc `build mods` calls per mod, so
  ## the escaping-import audit, the declared-setting-keys audit, the symbol
  ## table and index gates, the cleared-cache retry and `placeLibrary` all still
  ## run. A second compile path for "just one mod" would be two builds that
  ## differ for reasons nobody can see.
  ##
  ## Every name is resolved BEFORE anything is compiled: a typo in the second
  ## of two names must not cost the first one's build, and it must not be
  ## discovered four minutes in.
  let names = commaParts(spec)
  if names.len == 0:
    err "`build mod` needs a mod name, e.g. `aowl build mod maps`"
    return 1
  var dirs: seq[string] = @[]
  var bad = 0
  for raw in names:
    let name = modNameOf(raw)
    var found = ""
    for m in modDirs(e):
      if baseName(m) == name:
        found = m
    if found.len == 0:
      err "no such mod: " & name & " (looked for " &
          joinPath(joinPath(e.repo, "mods"), name) & ")"
      inc bad
    else:
      dirs.add found
  if bad > 0:
    var known = ""
    for m in modDirs(e):
      if known.len > 0:
        known.add " "
      known.add baseName(m)
    note "mods here: " & known
    return 1
  for d in dirs:
    discard buildMod(e, d)
  result = if failures > 0: 1 else: 0

const TestTargets = "tickrace regrace mapsdiag natesplog tuilayout bsgwiretest"

proc testExePath(e: Env; name: string): string =
  result = joinPath(e.repo, "installer\\build\\" & name & ".exe")

proc testBuildCmd(e: Env; name: string; outExe: string): string =
  ## THE one place a `tests\<name>.nim` compile line is written.
  ##
  ## `aowl test` calls this and so does `aowl build test <name>`, which is the
  ## whole point: the per-test flags used to be six near-identical inline
  ## blocks, so the only way to build one test alone was the 18-minute `aowl
  ## test` or hand-typing nimony's line from memory -- and an agent did exactly
  ## that on 2026-09-02. A hand-copied line drifts from the gate's line, and a
  ## test that passes under different flags than the gate uses has proved
  ## nothing about the gate.
  ##
  ## Returns "" for a name that `aowl test` does not compile. That is a
  ## REFUSAL, not a default: inventing a plausible `-p:` set here would build a
  ## different binary from the one the suite runs.
  var cmd = quoted(nimonyExe(e))
  cmd.add " c" & mimallocFlags
  cmd.add abiInclude(e)
  case name
  of "tickrace", "regrace":
    cmd.add " -p:" & quoted(joinPath(e.repo, "installer\\src"))
    cmd.add " -p:" & quoted(joinPath(e.repo, "aowl\\src"))
  of "mapsdiag":
    cmd.add " -p:" & quoted(joinPath(e.repo, "mods\\maps"))
  of "natesplog":
    cmd.add " -p:" & quoted(joinPath(e.repo, "host\\Aowlspt.Host.Il2Cpp"))
  of "tuilayout":
    cmd.add " -p:" & quoted(joinPath(e.repo, "installer\\src"))
    cmd.add " -p:" & quoted(joinPath(e.repo, "aowl\\src"))
    cmd.add " -p:" & quoted(joinPath(e.repo, "tools"))
  of "bsgwiretest":
    cmd.add " --passL:-lws2_32 --passL:-lz"
    cmd.add " -p:" & quoted(joinPath(e.repo, "installer\\src"))
    cmd.add " -p:" & quoted(joinPath(e.repo, "aowl\\src"))
    cmd.add " -p:" & quoted(joinPath(e.repo, "backend"))
  else:
    return ""
  cmd.add " -o:" & quoted(outExe)
  cmd.add " " & quoted(joinPath(e.repo, "tests\\" & name & ".nim"))
  result = cmd

proc cmdBuildTest(e: Env; name: string): int =
  ## Build ONE test binary. Does not run it -- `aowl test` runs the suite, and
  ## a build target that also ran things would make `build` mean two things.
  let exe = testExePath(e, name)
  let cmd = testBuildCmd(e, name, exe)
  if cmd.len == 0:
    err "no such test target: " & name
    if fileExists(joinPath(e.repo, "tests\\" & name & ".nim")):
      note "tests\\" & name & ".nim EXISTS, but `aowl test` does not compile " &
           "it, so there are no flags to copy. Add it to testBuildCmd with " &
           "the -p: paths it needs; guessing them here would build a " &
           "different binary from any gate."
    note "test targets: " & TestTargets
    return 1
  # Removed first, so that a compile which fails cannot leave the PREVIOUS
  # binary sitting there looking like a fresh one -- the same trap `buildMod`
  # documents for mod .dlls.
  discard removeFileAt(exe)
  if not run(e, "test " & name & " builds", cmd, e.repo):
    return 1
  if not fileExists(exe):
    err "nimony reported success but " & exe & " is not there"
    inc failures
    return 1
  ok "built " & exe
  result = 0

proc cmdBuildOne(e: Env; target: string; name: string): int =
  ## One named target, for the loop that dominates a working day: change one
  ## file, rebuild the one thing that contains it.
  ##
  ## `aowl build` runs about twenty-five compiles in series and is the right
  ## command exactly once -- before a release, or after an ABI header changes.
  ## For everything else it is dead time, and the measurement is stark: the
  ## host DLL alone is a fraction of a full build, and a rebuild with nothing
  ## changed is a fraction of a second, because nimony's incremental cache is
  ## very good. What was missing was a way to *ask* for one target.
  ##
  ## `name` is the SECOND positional -- `build mod maps`, `build mods a,b`,
  ## `build test mapsdiag`. Empty for every other target.
  let stale = refuseIfStaleDriver(e)
  if stale != 0:
    return stale
  dropStaleCaches(e)
  case target
  of "host", "il2cpp":
    result = if buildIl2CppHost(e): 0 else: 1
  of "backend":
    result = if buildBackend(e): 0 else: 1
  of "sim":
    result = if buildHosts(e): 0 else: 1
  of "launch", "launcher":
    result = if buildTool(e, "tools\\aowllaunch.nim", "aowlspt-launch.exe",
                          "aowlspt-launch"): 0 else: 1
  of "installer":
    result = if buildInstaller(e): 0 else: 1
  of "emutest":
    result = if buildEmuTest(e): 0 else: 1
  of "verify":
    result = if buildVerifyInstall(e): 0 else: 1
  of "probe":
    result = if buildProbe(e): 0 else: 1
  of "overlaytests", "overlay":
    # These offline checks existed but had NO named target: `buildOverlayTests`
    # was reachable only from the bare `aowl build`, which is 18 minutes cold.
    # So the cheapest, fastest checks in the repo -- the ones whose whole point
    # is that they need no client and no deploy -- were the most expensive to
    # run, and the temptation was to skip them. They take seconds this way.
    result = if buildOverlayTests(e): 0 else: 1
  of "realtest":
    # `buildRealTest` was reachable only from the bare `aowl build`, which is
    # 18 minutes cold -- so the harness that asserts against a real imported
    # database was the most expensive thing in the repo to compile, and an
    # edit to it went unchecked until somebody paid that.
    result = if buildRealTest(e): 0 else: 1
  of "settings", "settingscheck":
    # The cheapest gate in the repo, given its own name so it can be run
    # without compiling a mod -- the same reasoning as `overlaytests`.
    result = if settingsBacked(e): 0 else: 1
  of "maptiles", "tiles":
    result = if buildMapTiles(e): 0 else: 1
  of "mods":
    # `build mods` with no list is still every mod -- unchanged. With a list it
    # is exactly those.
    if name.len > 0:
      result = buildNamedMods(e, name)
    else:
      for m in modDirs(e):
        discard buildMod(e, m)
      result = if failures > 0: 1 else: 0
  of "mod":
    if name.len == 0:
      err "`build mod` needs a name, e.g. `aowl build mod maps`"
      note "`aowl build mods` (plural, no name) builds every mod"
      result = 1
    else:
      result = buildNamedMods(e, name)
  of "test", "tests":
    if name.len == 0:
      err "`build test` needs a name, e.g. `aowl build test mapsdiag`"
      note "test targets: " & TestTargets
      note "`aowl test` (no `build`) runs the whole suite"
      result = 1
    else:
      result = cmdBuildTest(e, name)
  of "examples":
    for m in exampleDirs(e):
      discard buildMod(e, m)
    result = if failures > 0: 1 else: 0
  of "deploy":
    # Everything a live install takes -- read off tools\deploy.json, which is
    # the same file `python tools\deploy.py check` verifies against.
    result = buildDeploySet(e)
  else:
    err "unknown build target: " & target
    note "targets: host backend sim launch installer emutest verify probe " &
         "settings realtest maptiles mods examples deploy"
    note "one mod: `aowl build mod maps`; several: `aowl build mods maps,tarkov`"
    note "one test: `aowl build test NAME` -- " & TestTargets
    note "or a mod path, with `aowl build-mod mods\\tarkov`"
    result = 1
  if reportSkippedGates(e) != 0:
    result = 1

proc cmdBuild(e: Env): int =
  let stale = refuseIfStaleDriver(e)
  if stale != 0:
    return stale
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
  let gates = reportSkippedGates(e)
  result = if failures > 0 or gates != 0: 1 else: 0

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

proc stageTarkovData(e: Env; dest: string) =
  ## The tarkov mod's `data/` into a test stage, beside its library.
  ##
  ## Not optional decoration. The emulator refuses to start a raid without
  ## `data/post1/serversettings.json` and answers seven menu routes out of
  ## that directory, so a stage with the library and not the data is a server
  ## that loads and then refuses -- which reads as a code failure and is a
  ## packaging one. Every stage that copies `tarkov.dll` calls this, because
  ## the one that did not was the one that failed.
  ##
  ## `data/capture` is skipped. It is a recording of the real backend kept to
  ## check this server against, not anything the server serves, and it is tens
  ## of megabytes -- most of it regenerated rather than stored.
  let src = joinPath(e.repo, "mods\\tarkov\\data")
  if not isDirectory(src):
    return
  var files: seq[string] = @[]
  var dirs: seq[string] = @[]
  collectEntries(src, files, dirs)
  for f in files:
    if startsWith(normSep(f), "capture\\"):
      continue
    discard copyFileAt(joinPath(src, f),
      joinPath(joinPath(dest, "mods\\tarkov\\data"), f))

proc cmdTestOneMod(e: Env; name: string): int =
  ## `aowl test --mod NAME` -- run ONE mod's `core/selftest` and nothing else.
  ##
  ## THE MEASURED PROBLEM THIS SOLVES. `aowl test` ran for forty minutes with
  ## its output buffered and emitted nothing, and `modclient.exe` takes no
  ## `--mod` flag at all (it never did -- it is the manager's report reader and
  ## has no notion of choosing a mod), so it runs the manager suite whatever you
  ## pass it. There was no way to get a two-second verdict on one mod's own
  ## logic, and "I could not look" was being reported as a pass.
  ##
  ## It works because `core/` is PURE by construction: `selftest.run()` builds
  ## its inputs by hand and touches no game, no Unity and no IL2CPP. So a
  ## seventeen-line main is a complete harness, and this generates one rather
  ## than asking every mod to carry a duplicate of it.
  ##
  ## THREE OUTCOMES, and the third is why this is not just a shell alias:
  ##   0  every check passed
  ##   1  a check FAILED, or the harness would not compile
  ##   3  INCONCLUSIVE -- there is no such mod, or it has no `core/selftest.nim`.
  ##      Nothing was run, and that must not exit 0. A missing suite reported as
  ##      a pass is the check that cannot fail, in the tool that exists to stop
  ##      exactly that.
  let core = joinPath(e.repo, "mods\\" & name & "\\core")
  let suite = joinPath(core, "selftest.nim")
  if not isDirectory(joinPath(e.repo, "mods\\" & name)):
    err "there is no mods\\" & name & " in this checkout. INCONCLUSIVE: " &
        "nothing was run."
    return 3
  if not fileExists(suite):
    err "mods\\" & name & " has no core\\selftest.nim, so it has no " &
        "self-contained suite to run. INCONCLUSIVE: nothing was run. (A mod's " &
        "pure decision logic belongs in core/; this verb cannot test a mod " &
        "whose logic only exists inside a live client.)"
    return 3
  # PER MOD, and the working directory below is this same directory. MEASURED
  # 2026-09-04: with one shared directory, nimony's `nimcache` (which it writes
  # relative to the WORKING directory -- see `run`) was shared by every mod's
  # harness, and the .nif index of the previous mod's modules survived into the
  # next build. `aowl test --mod sain` then `--mod maps` failed with
  # `cannot open: nimcache\vec4ymjhj.s.nif` (sain's `vec`), and the reverse
  # order failed on `plagncxy51.s.nif` (maps' `place`) -- exit 1, reading
  # exactly like a failing suite. Order-dependence in a verdict tool is the
  # confidently-wrong answer this verb exists to prevent, so the caches cannot
  # be allowed to touch.
  let outDir = joinPath(joinPath(e.repo, "installer\\build\\modselftest"), name)
  discard ensureDir(outDir)
  discard ensureDir(joinPath(outDir, "nimcache"))
  let mainNim = joinPath(outDir, name & "_selftest.nim")
  # Generated, not committed: the harness must follow whatever `core/selftest`
  # is on the branch being tested, and a committed copy per mod would be one
  # more thing to forget to update.
  var src = "## GENERATED by `aowl test --mod " & name & "`. Do not edit.\n"
  src.add "import std/syncio\n"
  src.add "import selftest\n"
  src.add "let r = run()\n"
  src.add "for line in r.lines: echo line\n"
  src.add "if r.failed == 0:\n"
  src.add "  echo \"PASS -- \" & $r.passed & \" checks\"\n"
  src.add "  quit(0)\n"
  src.add "else:\n"
  src.add "  echo \"FAIL -- \" & $r.failed & \" of \" & " &
          "$(r.passed + r.failed) & \" checks\"\n"
  src.add "  quit(1)\n"
  let w = writeTextFile(mainNim, src)
  if not w.ok:
    err "could not write " & mainNim & " (error " & $w.err & ")"
    return 3
  let exe = joinPath(outDir, name & "_selftest.exe")
  var cmd = quoted(nimonyExe(e))
  cmd.add " c" & mimallocFlags
  cmd.add abiInclude(e)
  cmd.add " -p:" & quoted(core)
  cmd.add " -p:" & quoted(joinPath(e.repo, "aowl\\src"))
  cmd.add " -o:" & quoted(exe)
  cmd.add " " & quoted(mainNim)
  heading "mods\\" & name & "\\core\\selftest"
  if not run(e, name & " selftest builds", cmd, outDir):
    return 1
  # NOT through `run()`. `run` discards a successful command's output unless
  # --verbose, which is precisely the behaviour that made `aowl test` emit
  # nothing for forty minutes: "ok <name>" is not a verdict, it is the absence
  # of a non-zero exit. This verb exists to produce a NUMBER, so the summary
  # line and every failing check are printed unconditionally.
  var out2 = ""
  var code = -1
  try:
    let (o, c) = execCmdEx(quoted(exe), workingDir = e.repo)
    out2 = o
    code = c
  except:
    err "could not start " & exe
    return 1
  for l in splitLines(out2):
    if l.len == 0: continue
    if l.startsWith("PASS -- ") or l.startsWith("FAIL -- "):
      note l
    elif l.startsWith("FAIL") or e.verbose:
      line "        " & l
  if code != 0:
    err name & " decision core FAILED (exit " & $code & ")"
    inc failures
    return 1
  ok name & " decision core"
  result = 0

proc cmdTest(e: Env): int =
  if e.oneMod.len > 0:
    return cmdTestOneMod(e, e.oneMod)
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
  cmd.add " c" & mimallocFlags & " -p:" & quoted(joinPath(e.repo, "aowl\\src"))
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

  heading "Shared per-frame region"
  # The MUTATION PROOF for `abi/aowlspt_region.h`. It does not check that the
  # dispatcher runs -- it deliberately registers a participant that faults, one
  # that overruns its budget, and one that calls the dispatcher from inside a
  # live guard, then asserts on the FINISHED STATE: that nobody ORDERED AFTER
  # the faulting participant lost a frame, that the faulting one is disabled by
  # name, that the overrunning one is reported and throttled, and that nesting
  # is refused. It then runs the identical harness with nothing misbehaving, so
  # every one of those checks is shown to be capable of failing.
  let regionExe = joinPath(testsDir, "region_test.exe")
  if run(e, "compile region_test.c",
         "gcc -I" & quoted(joinPath(e.repo, "abi")) & " -O1 -o " &
         quoted(regionExe) & " " &
         quoted(joinPath(testsDir, "region_test.c"))):
    discard run(e, "one mod faulting in the shared region never costs another " &
                   "mod a frame", quoted(regionExe))

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
      stageTarkovData(e, flStage)
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
    let tickRaceExe = testExePath(e, "tickrace")
    let trCmd = testBuildCmd(e, "tickrace", tickRaceExe)
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
    let regRaceExe = testExePath(e, "regrace")
    let rrCmd = testBuildCmd(e, "regrace", regRaceExe)
    if run(e, "regrace builds", rrCmd, e.repo):
      discard run(e, "every registration is reached by the handler it named",
                  quoted(regRaceExe))

    # And the launcher's screen, as a character grid.
    #
    # `tools/aowllaunch.nim` shows TWO screens, in one console, one after the
    # other: the launcher (progress + the profile panel) and then the two log
    # panes. That is a layout change -- the class of change that fails by being
    # one column out, which looks like a rendering glitch on somebody else's
    # terminal and is arithmetic that drifts with the window width.
    # `tools/aowllayout.nim` is the pure half of it, so both frames are rendered
    # into a buffer here at the same ladder of window sizes and checked as the
    # grid they produced: no row wider than the window, both pane borders
    # present on screen 2, every profile (or an honest count of the hidden ones)
    # on screen 1, the CREATE path rather than an empty box when the install has
    # no profiles, and a deliberate REFUSAL below the minimum size rather than a
    # bent frame.
    #
    # It also holds down the separation itself. The two screens were briefly
    # fused into one frame and that was rejected, so `notFused` asserts on the
    # grid that neither screen carries the other's furniture -- structurally,
    # by counting the corners on the top border, so it cannot pass by accident.
    # THE DIAG LOG FILTER. The maps diag block was 40.3% of one 761 s host log
    # (10,192 of 25,289 lines) because its change-detection compared text that
    # carried live counters and so was always unequal. The filter that replaced
    # it is gated here on the OPPOSITE risk: that quieting the noise also
    # quieted the signal. It replays 110 blocks captured verbatim from a real
    # session -- containing a real `art: FAIL` -- and asserts every not-PASS
    # verdict still surfaces, promptly, while the repeated PASS collapses.
    # Mutating `diagNotPass` to return "" makes it fail with 17 named FAILs.
    let mdExe = testExePath(e, "mapsdiag")
    let mdCmd = testBuildCmd(e, "mapsdiag", mdExe)
    if run(e, "mapsdiag builds", mdCmd, e.repo):
      discard run(e, "quieting the maps diag block did not also quiet any " &
                     "FAIL or INCONCLUSIVE verdict in it", quoted(mdExe))

    # THE SAME GATE FOR natesp'S VERDICT BLOCK. MEASURED at the main menu: the
    # ~3,000-character `natesp VERDICT INCONCLUSIVE` block was written every 5 s
    # forever -- hundreds of kilobytes of "I could not look" in the one file
    # every tool in this repo reads. `host/Aowlspt.Host.Il2Cpp/nelogpol.nim` is
    # the pure half of the replacement, and this drives the SHIPPED `neGateStep`
    # over synthetic tick sequences: a standing not-PASS must still be named
    # within 60 s forever and can never be reported as a heartbeat, every change
    # of verdict/reason/phase/canvas must re-print in full, an all-PASS must
    # still heartbeat, and `natespVerbose` must restore the firehose exactly.
    # Mutating the not-PASS branch to return `neQuiet` makes it fail with
    # "went 599 cycles (2995s) unannounced".
    let nlExe = testExePath(e, "natesplog")
    let nlCmd = testBuildCmd(e, "natesplog", nlExe)
    if run(e, "natesplog builds", nlCmd, e.repo):
      discard run(e, "quieting the natesp verdict block did not also quiet " &
                     "any not-PASS verdict, and natespVerbose still restores " &
                     "the firehose", quoted(nlExe))

    let tuiExe = testExePath(e, "tuilayout")
    let tlCmd = testBuildCmd(e, "tuilayout", tuiExe)
    if run(e, "tuilayout builds", tlCmd, e.repo):
      discard run(e, "both launcher screens fit every window they agree to " &
                     "draw in, and neither draws the other", quoted(tuiExe))

    # And the wire format the post-1.0 client actually speaks, against bodies
    # it actually sent.
    #
    # This gate exists because the failure it covers is silent. A post-1.0
    # client wraps every request body in a length-keyed byte shuffle; the
    # server did not unwrap it, so bodies arrived as noise with a 200 and no
    # warning, and every route that ignores its body kept working. The client
    # reached the character-selection screen against a server that had never
    # read a single thing it was sent.
    #
    # It runs against `mods/tarkov/data/capture/raid1`, 149 real bodies from a
    # live session, rather than against round-tripped synthetic ones -- a
    # synthetic round trip through our own `bsgShuffle` passed against the
    # broken server too, because it never touched the decision about *when* to
    # unwrap. One of those 149 is why: seq 458's shuffled form happens to open
    # with a valid zlib header, so a server that trusts the header reads it as
    # a plain stream, fails, and gives up.
    let wireExe = testExePath(e, "bsgwiretest")
    let bwCmd = testBuildCmd(e, "bsgwiretest", wireExe)
    if run(e, "bsgwiretest builds", bwCmd, e.repo):
      discard run(e, "every captured request body decodes the way the server " &
                     "decodes it", quoted(wireExe) & " " & quoted(e.repo))

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
      stageTarkovData(e, estage)
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
        stageTarkovData(e, rstage)
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
      stageTarkovData(e, fstage)
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
      stageTarkovData(e, wstage)
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
      stageTarkovData(e, sstage)
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
      stageTarkovData(e, lstage)
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
  # The stand-in runtime, in the environment, for the self-tests that want one.
  # See `armSelfTestFixture`: this is the fixture the mods' `config.json` used
  # to carry as a repository-relative path, which is a development path in a
  # file that ships into a player's install.
  let armed = armSelfTestFixture(e)
  if not armed:
    warn "no stand-in runtime at tests\\mockil2cpp\\GameAssembly.dll; the " &
         "offline binding reports below run against the process"
  let realMods = modDirs(e)
  for m in realMods:
    if buildMod(e, m) and fileExists(sim):
      discard run(e, "sim " & baseName(m),
                  quoted(sim) & " " & quoted(m) & " --side sim --ticks 3")

  # And the assertion that the fixture actually reached one of them.
  #
  # Without this the environment is exactly the shape of bug this change was
  # made to remove: if `AOWLSPT_SELFTEST_RUNTIME` stopped being read, or
  # stopped being inherited by the simulator, every self-test above would still
  # pass -- they warn and fall back to the process, which is a legitimate
  # answer -- and the binding coverage would be gone with nothing saying so.
  # So one of them is run again with its output read, and the line that only
  # appears when a runtime was loaded and started is required.
  if armed and fileExists(sim):
    let fovDir = joinPath(e.repo, "mods\\fov")
    var report = ""
    var code = -1
    try:
      let (o, c) = execCmdEx(quoted(sim) & " " & quoted(fovDir) &
                             " --side sim --ticks 3", workingDir = e.repo)
      report = o
      code = c
    except:
      report = ""
    if code == 0 and find(report, "bound and started") >= 0:
      ok "the offline binding reports ran against the stand-in runtime"
    else:
      err "the stand-in runtime was set in AOWLSPT_SELFTEST_RUNTIME but no " &
          "self-test bound it (exit " & $code & "); the binding reports above " &
          "are against the process and prove less than they look like they do"
      inc failures

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
    cmd.add " c" & mimallocFlags
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
    cmd.add " c" & mimallocFlags
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

proc buildScript(e: Env; scriptPath: string; exeOut: var string): bool =
  ## `aowl script <path.nim>` -- compile ONE automation script.
  ##
  ## An automation script is an ordinary nimony program that imports
  ## `tools/autoscript`. Same shape as `emutest`: it opens sockets to the
  ## backend's plain-HTTP control port and spawns processes, so it wants
  ## `installer\src` (winfs, the spawn shim) and `tools` (autoscript,
  ## aowlsession) on the path, and links winsock.
  ##
  ## It is compiled through `aowl` and never by hand: a raw `nimony` invocation
  ## outside the paths this sets up **exits 0 and writes nothing**, and a green
  ## exit code with no artifact is the worst failure this build has.
  let outDir = joinPath(e.repo, "installer\\build\\scripts")
  discard ensureDir(outDir)
  let src = absolutePathOf(scriptPath)
  if not fileExists(src):
    err "no such script: " & src
    return false
  var stem = baseName(src)
  if stem.len > 4 and stem.substr(stem.len - 4) == ".nim":
    stem = stem.substr(0, stem.len - 5)
  exeOut = joinPath(outDir, stem & ".exe")
  var cmd = quoted(nimonyExe(e))
  cmd.add " c" & mimallocFlags
  cmd.add abiInclude(e)
  cmd.add " --passL:-lws2_32"
  cmd.add " -p:" & quoted(joinPath(e.repo, "installer\\src"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "aowl\\src"))
  cmd.add " -p:" & quoted(joinPath(e.repo, "tools"))
  cmd.add " -p:" & quoted(parentOf(src))
  cmd.add " -o:" & quoted(exeOut)
  cmd.add " " & quoted(src)
  result = run(e, "script " & stem, cmd, e.repo)

proc cmdScript(e: Env; scriptPath: string; scriptArgs: string): int =
  ## Build the script and RUN it, printing everything it says.
  ##
  ## The script's own exit code is passed straight through, because it IS the
  ## verdict: 0 PASS, 1 FAIL, 2 INCONCLUSIVE. Collapsing 2 into 1 would report a
  ## run that could not look as a run that looked and found a fault, and those
  ## are different and differently actionable facts.
  var exe = ""
  if not buildScript(e, scriptPath, exe):
    return 2
  if not fileExists(exe):
    err "the script compiled and produced no binary at " & exe &
        " -- that is the silent-nimony failure; do not trust the exit code"
    return 2
  var cmd = quoted(exe)
  if scriptArgs.len > 0:
    cmd.add " " & scriptArgs
  var code = -1
  try:
    code = execCmd(cmd)
  except:
    err "script: could not start " & exe
    return 2
  if code == 0:
    ok "script PASS"
  elif code == 1:
    err "script FAIL"
  else:
    note "script INCONCLUSIVE (exit " & $code & ") -- the question was not asked"
  result = code

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
  # A mod's `--side sim` self-test can ask for a runtime to bind against. The
  # stand-in one lives in the repository, so it is this command's business to
  # hand it over rather than the mod's config's -- see `armSelfTestFixture`.
  discard armSelfTestFixture(e)
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

proc stageTree(src, dst: string; exts: seq[string]; skipDirs: seq[string];
               copied: var int): int =
  ## Copy `src` into `dst`, keeping only files whose extension is in `exts`
  ## (empty = every file) and never descending into a directory whose FIRST
  ## path component is in `skipDirs`. Returns how many files were staged.
  ##
  ## The skip list is matched on the leading component, not by substring: a mod
  ## with a source directory called `binding` must not be dropped because the
  ## rule was really about `bin`.
  result = 0
  if not isDirectory(src): return
  var files: seq[string] = @[]
  var dirs: seq[string] = @[]
  collectEntries(src, files, dirs)
  for f in files:
    let rel = normSep(f)
    var head = rel
    let slash = find(rel, "\\")
    if slash > 0: head = rel.substr(0, slash - 1)
    var skip = false
    for s in skipDirs:
      # Any component, not just the first: `mgr\nimcache\x.nif` must go too.
      if head == s or find(rel, s & "\\") >= 0:
        skip = true
    if skip: continue
    if exts.len > 0:
      var wanted = false
      let low = toLowerAscii(rel)
      for x in exts:
        if endsWith(low, x): wanted = true
      if not wanted: continue
    if copyFileAt(joinPath(src, f), joinPath(dst, f)).ok:
      inc result
      inc copied

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
        # `data/capture` is a recording of the real backend, kept to check this
        # server against. It is not anything the server serves, and it is tens of
        # megabytes -- most of it regenerated rather than stored, so a payload
        # built on one machine would carry it and one built on another would not.
        # Skipped by name rather than by size, because "large" is not the reason.
        if startsWith(normSep(f), "capture\\"):
          continue
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
      "  \"modSyncMs\": 3000,\n" &
      "\n" &
      "  \"//botDiag\": \"READ-ONLY diagnostic. When true, a detour on " &
      "EFT.GameWorld.RegisterPlayer logs each bot/player registration and " &
      "enumerates the registered list (nickname, side/role, alive-state, " &
      "position) during an offline raid, to answer whether AI bots are " &
      "actually spawned (but maybe frozen) or truly absent. It never writes " &
      "game state, renders, or affects gameplay. Default false.\",\n" &
      "  \"botDiag\": false,\n" &
      "\n" &
      "  \"//botNav\": \"Native bot navigation API. When true, a detour on " &
      "EFT.BotOwner.UpdateManual (once per live bot per frame) keeps a live bot " &
      "registry -- id, role, difficulty, position, alive-state -- and services " &
      "nav commands sent by a mod over the existing modSyncMs poll ('bot 7, go " &
      "to x,y,z'). A command is a direct call to EFT.BotOwner.GoToPoint, whose " &
      "return value says whether the point was reachable. UNLIKE botDiag this " &
      "CALLS INTO and WRITES TO game objects: every pointer the callee would " &
      "dereference is VirtualQuery-walked first, the whole tick runs under the " &
      "VEH/SEH guard, commands are re-issued on a 500ms throttle rather than " &
      "per frame, and the feature self-disables after 8 trapped faults. " &
      "Default false.\",\n" &
      "  \"botNav\": false,\n" &
      "\n" &
      "  \"//uxMenuModeText\": \"When true, the main menu's BOTTOM-RIGHT " &
      "corner label (stock: 'PVE ZONE') is set by the host instead. It " &
      "defaults to the logged-in character's name, and any mod can override " &
      "it with aowlspt/menutext.setMenuModeText. The host does this by " &
      "CALLING the game's own EFT.UI.PreloaderUI.SetGameModeText at its " &
      "verified static RVA -- not by poking a TextMeshPro field -- and binds " &
      "nothing at all on a build whose prologue does not match. It needs " &
      "backendPort + modSyncMs (the text rides that poll), and it refuses to " &
      "arm while debugUi/debugEsp are on, because those drain the same " &
      "PreloaderUI.Update function. Default false until proven live.\",\n" &
      "  \"uxMenuModeText\": false,\n" &
      "\n" &
      "  \"//hostHttp\": \"The host's ONLY outbound HTTP client, exposed to mods as the GENERIC verb aowlspt.host::http (plus http_poll). When true a mod may ask the host to fetch a URL; the request runs on a host WORKER THREAD -- never the Unity main thread and never inside a detour -- and the completion is delivered as the mod event host.http.done, emitted from the host's own tick rather than from that worker. Every host must be in hostHttpAllow, https is refused by name, and a body over hostHttpMaxBody is REFUSED rather than truncated. With this false the verb still ANSWERS, with why = flag hostHttp is off. Default false.\",\n" &
      "  \"hostHttp\": false,\n" &
      "\n" &
      "  \"//hostHttpAllow\": \"The hosts aowlspt.host::http may dial. An EMPTY array refuses everything; the key being ABSENT means the default shown here. Loopback only is the intended setting -- the thing on the other end is aowlspt-backend.\",\n" &
      "  \"hostHttpAllow\": [\"127.0.0.1\", \"localhost\"],\n" &
      "\n" &
      "  \"//hostHttpMaxInflight\": \"How many requests may be in flight at once. Each holds one worker thread inside the game process, so this is a real resource and not a formality. Over it, submit is REFUSED with a reason. Clamped to 8.\",\n" &
      "  \"hostHttpMaxInflight\": 4,\n" &
      "\n" &
      "  \"//hostHttpMaxBody\": \"Byte cap on BOTH the request body and the response body. Over it the request is REFUSED, never truncated: a prefix of a JSON document is worse than no document, because every reader rejects it as a schema error and the size never appears anywhere. Clamped to 1 MiB.\",\n" &
      "  \"hostHttpMaxBody\": 1048576,\n" &
      "\n" &
      "  \"//hostPlayWav\": \"Lets a mod play a PCM .wav through the generic verb aowlspt.host::play_wav (winmm PlaySoundW, async). NON-SPATIAL: the sound has no position, no distance falloff and no relation to the game's audio listener, and the volume argument is IGNORED -- winmm's only volume knob moves the whole OUTPUT DEVICE, i.e. the game's own volume, and leaves it moved. Real per-sound volume and position need a Unity AudioSource driven at byte-verified RVAs; see docs/VOICE_RVA.md. Default false.\",\n" &
      "  \"hostPlayWav\": false,\n" &
      "\n" &
      "  \"//hostPlayWavRoots\": \"The directory roots a play_wav path must sit under. Environment variables are expanded. A path containing .. anywhere is refused outright rather than resolved, because a prefix check that can be walked out of is a check that cannot fail. An EMPTY array refuses everything; the key being ABSENT means the default shown here.\",\n" &
      "  \"hostPlayWavRoots\": [\"%TEMP%\", \"D:\\\\Aowlspt\"]\n" &
      "}\n")

  let staged = failures - failuresAtEntry
  if staged > 0:
    # Deliberately not counted as "mods": the same tally now carries the three
    # binaries above, and a message that says "2 mod(s)" when one of them is
    # the backend sends the reader to look at the wrong thing.
    err $staged & " missing piece(s) above; this payload is not installable"
    return 1

  ok $copied & " files staged in " & dest

  # `payload.json` is gitignored, so it exists on the machine this was
  # developed on and NOWHERE else -- a release cut from a fresh clone or a
  # fresh worktree has only the template. This used to be a warning, and a
  # warning is exactly wrong here: `aowl payload` said "ok, N files staged"
  # and exited 0 while `aowlspt-install.exe` could not run at all, because it
  # reads `targetTarkovVersion`, `targetBackend` and `kind` out of that file.
  # A payload that cannot be installed is not a payload, which is the same
  # argument the missing-host check above already makes.
  if not fileExists(joinPath(payload, "payload.json")):
    err "there is no payload.json in " & payload & " -- it is gitignored, so " &
        "a fresh clone or worktree never has one. Copy payload.json.template " &
        "next to it and fill in the client version this was built against; " &
        "aowlspt-install.exe reads targetTarkovVersion, targetBackend and " &
        "kind out of it and cannot run without them"
    return 1
  result = 0

proc cmdPayloadPublic(e: Env; extra: seq[string]): int =
  ## `aowl payload-public` -- a payload whose mods folder holds SOURCE.
  ##
  ## ## What this is for, and why `payload` could not be it
  ##
  ## The stated requirement is: *"always package with aowlspt our nimony build
  ## so that the users mods folder is always uncompiled, on startup its
  ## compiled (we cache if same file)"*. Two thirds of that existed and were
  ## never joined up:
  ##
  ##   * `tools/modbuild.py` compiles a mods folder from source, with a content
  ##     cache, and writes the in-game loading step;
  ##   * `tools/toolchain.py` packs gcc, lld, nimony and (since 2026-09-01) a
  ##     Python interpreter into `<install>/toolchain/`;
  ##   * and `aowl payload` staged **prebuilt `.dll` files** -- measured, no
  ##     `.nim` sources, no `tools/`, no `abi/`, no `aowl/src`, no toolchain.
  ##
  ## So an installed aowlspt was a bag of binaries: a player who edited a mod
  ## had no path from the edit to the game loading it. This is the payload that
  ## ships the other shape.
  ##
  ## ## It runs `payload` FIRST, on purpose
  ##
  ## Everything that is genuinely a binary -- the client host, the backend, the
  ## registry, each mod's `data/` and `config.json` -- is staged by the normal
  ## `payload`, and this adds to that rather than restating it. Two staging
  ## routines that drift is how a payload comes to be missing a piece nobody
  ## notices until an install is already broken.
  ##
  ## It also means the ordinary payload's gate still applies: it FAILS if a mod
  ## has no library. That gate is worth keeping here even though the libraries
  ## are then replaced by sources, because it means we only ever ship source we
  ## have just watched compile.
  ##
  ## ## What it adds
  ##
  ##   aowlspt\mods\<mod>\**        the SOURCE (.nim/.h/.c/.json/.cfg)
  ##   aowlspt\tools\modbuild.py    the compiler driver
  ##   aowlspt\tools\modloadfmt.py  the loading-step renderer it imports
  ##   aowlspt\abi\                 headers AND aowlspt_symtab.nim (-I and -p)
  ##   aowlspt\aowl\src\            the aowlspt Nim library every mod imports
  ##
  ## and it REMOVES each mod's staged `.dll`, because shipping both would let a
  ## stale binary load while the source beside it says something else -- the
  ## exact "a failure that looks like a success" shape this repo keeps hitting.
  ##
  ## The toolchain itself is NOT staged here. It is 842 MB, it is built by a
  ## different tool with its own manifest and hash verification, and copying it
  ## through a second, unverified path would throw away the guarantee that
  ## `toolchain.py install` exists to give. Install it into the payload (or the
  ## finished install) with:
  ##
  ##     python tools\toolchain.py pack    --out build\toolchain
  ##     python tools\toolchain.py install --from build\toolchain --install <install>\aowlspt
  ##
  ## `payload-public` says so at the end rather than leaving it implied.
  ## ## `--sources-only`
  ##
  ## Stages the SOURCE side and skips the ordinary payload entirely. The result
  ## is NOT installable and must never be shipped: it has no client host, no
  ## backend, no registry and no mod data. It exists because the source staging
  ## has to be verifiable on a checkout where the binaries are not built --
  ## which, in a repo where several agents are editing `host/` at once, is most
  ## of the time. A `NOT-INSTALLABLE.txt` is written into the payload so the
  ## directory itself says what it is, rather than relying on whoever produced
  ## it to remember.
  var sourcesOnly = false
  for a in extra:
    if a == "--sources-only":
      sourcesOnly = true
    elif startsWith(a, "-"):
      err "unknown option for payload-public: " & a
      return 1

  let failuresAtEntry = failures
  if not sourcesOnly:
    let rc = cmdPayload(e)
    if rc != 0:
      err "the ordinary payload failed, so there is nothing to add sources to"
      note "to verify the SOURCE staging alone on a checkout whose binaries " &
           "are not built, use `aowl payload-public --sources-only`. What it " &
           "produces is deliberately not installable and says so."
      return rc

  let dest = joinPath(e.repo, "installer\\payload\\aowlspt")
  heading "Payload (public: mods as SOURCE)"
  var copied = 0

  let srcExts = @[".nim", ".h", ".c", ".cpp", ".json", ".cfg"]
  let skipDirs = @["nimcache", "bin", ".git", "__pycache__"]

  let realMods = modDirs(e)
  for m in realMods:
    let name = baseName(m)
    let modDst = joinPath(joinPath(dest, "mods"), name)
    let n = stageTree(m, modDst, srcExts, skipDirs, copied)
    # The staged library goes. A mods folder that holds BOTH a source tree and
    # yesterday's binary is a folder where the game can load code nobody can
    # see, and modbuild would rebuild it anyway on the first launch.
    var files: seq[string] = @[]
    var dirs: seq[string] = @[]
    collectEntries(modDst, files, dirs)
    var dropped = 0
    for f in files:
      if endsWith(toLowerAscii(f), ".dll"):
        if removeFileAt(joinPath(modDst, f)).ok: inc dropped
    say "mod " & name & " -> " & $n & " source file(s) staged, " &
        $dropped & " prebuilt library(ies) removed"

  # The compiler driver. Only these two: `modbuild.py` imports `modloadfmt`
  # and nothing else of ours, which is checked by `tools/test_modloadfmt.py`.
  let toolsDst = joinPath(dest, "tools")
  discard ensureDir(toolsDst)
  var toolsN = 0
  for t in ["modbuild.py", "modloadfmt.py"]:
    let s = joinPath(e.repo, "tools\\" & t)
    if fileExists(s):
      if copyFileAt(s, joinPath(toolsDst, t)).ok:
        inc toolsN
        inc copied
    else:
      err "tools\\" & t & " is missing; the install would have sources and " &
          "nothing to compile them with"
      inc failures
  say "tools -> " & $toolsN & " file(s) (" & toolsDst & ")"

  # The two search paths every mod compile needs. `abi` is BOTH a C include
  # directory and a nim path (`abi/aowlspt_symtab.nim`); `aowl/src` is the
  # library every mod imports.
  let abiN = stageTree(joinPath(e.repo, "abi"), joinPath(dest, "abi"),
                       @[".h", ".nim", ".c"], @[], copied)
  say "abi -> " & $abiN & " file(s)"
  let libN = stageTree(joinPath(e.repo, "aowl\\src"),
                       joinPath(dest, "aowl\\src"), @[".nim"], @[], copied)
  say "aowl\\src -> " & $libN & " file(s)"

  if abiN == 0 or libN == 0:
    err "abi/ or aowl/src staged NOTHING. Every mod compiles against both, so " &
        "this payload would install a mods folder that cannot be built."
    inc failures

  line ""
  line "  The TOOLCHAIN is not in this payload. Add it with:"
  line "    python tools\\toolchain.py pack    --out build\\toolchain"
  line "    python tools\\toolchain.py install --from build\\toolchain " &
       "--install <install>\\aowlspt"
  line "  It is 842 MB with its own manifest and per-file SHA-256 check, and " &
       "copying it through a second unverified path would throw that away."

  let mine = failures - failuresAtEntry
  if mine > 0:
    err $mine & " problem(s) staging the public payload"
    return 1
  if sourcesOnly:
    # The directory says what it is. A half payload that looks like a whole
    # one is exactly the artifact somebody installs by accident.
    let nl = "\n"
    discard writeTextFile(joinPath(dest, "NOT-INSTALLABLE.txt"),
      "This payload was staged with: aowl payload-public --sources-only" & nl &
      "It contains the mod SOURCES, tools, abi and aowl/src ONLY." & nl &
      "There is NO client host, NO backend, NO registry and NO mod data." & nl &
      "DO NOT INSTALL IT. Run `aowl payload-public` (no flag) for a real one." &
      nl)
    warn "--sources-only: this payload is NOT installable. It has no " &
         "client host, no backend, no registry and no mod data. " &
         "NOT-INSTALLABLE.txt in the payload says the same."
  ok "public payload staged: " & $copied & " file(s) added as SOURCE"
  result = 0

proc cmdRelease(e: Env; extra: seq[string]): int =
  ## `aowl release` -- builds `tools/release.nim` and hands it this repo plus
  ## whatever else was typed. Every gate, every refusal and the archive format
  ## live over there and nothing about them is duplicated here: a release gate
  ## that lives in two files is a release gate with two answers.
  let outDir = joinPath(e.repo, "installer\\build")
  discard ensureDir(outDir)
  var cmd = quoted(nimonyExe(e))
  cmd.add " c" & mimallocFlags
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
  cmd.add " c" & mimallocFlags
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
              debugBuild: false, verbose: false, oneMod: "",
              allowStaleDriver: false)
  e.repo = repoRoot()
  e.nimony = joinPath(getEnv("USERPROFILE", "C:\\"), "nimony")

  var command = ""
  var arg = ""
  var arg2 = ""
  var extra: seq[string] = @[]
  var i = 1
  let n = paramCount()
  var help = false
  var noLock = false
  while i <= n:
    let a = paramStr(i)
    # `release` parses its own options -- `--mod`, `--out`, `--check-only`.
    # Forwarding everything after the verb verbatim keeps this parser from
    # having to learn a second command's flags, and keeps them from drifting.
    if command == "release" or command == "importdb" or
       command == "ui" or command == "raid" or command == "script" or
       command == "loothash" or command == "payload-public":
      # `script` joins this list because an automation script takes its OWN
      # arguments, and `aowl` must not eat them. `--build-only` is read out of
      # `extra` by the `script` branch below. `loothash` likewise parses its
      # own `--seed` / `--count`.
      extra.add a
    elif a == "--debug":
      e.debugBuild = true
    elif a == "--no-lock":
      noLock = true
    elif a == "--allow-stale-driver":
      e.allowStaleDriver = true
    elif a == "--nimony":
      inc i
      if i <= n: e.nimony = paramStr(i)
    elif a == "--ucrt64":
      inc i
      if i <= n: e.ucrt64 = paramStr(i)
    elif a == "--mod":
      # `test --mod NAME` runs ONE mod's `core/selftest` and nothing else.
      # Parsed HERE rather than by adding `test` to the forward-verbatim list
      # above, because `test` already accepts `--verbose`/`--debug` and
      # forwarding would silently swallow them -- a flag that stops working is
      # exactly the kind of quiet regression this parser's comment warns about.
      inc i
      if i <= n: e.oneMod = paramStr(i)
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
    elif arg.len == 0:
      arg = a
    else:
      # The SECOND positional. It used to overwrite `arg` silently, so
      # `aowl build mods maps` was read as `build maps` -- an unknown target,
      # or worse a valid one. `build mod NAME` / `build test NAME` need it.
      if arg2.len == 0:
        arg2 = a
      else:
        extra.add a
    inc i

  if help or command.len == 0:
    echo Usage
    return (if help: 0 else: 1)

  # Two builds in ONE checkout corrupt each other -- CLAUDE.md section 3, and
  # measured twice. `tools/buildlock.py` makes that impossible for anything
  # that goes through it, but an unlocked build leaves no trace at all: the
  # lock reads FREE while a hand-typed `aowl.exe build host` is halfway through
  # the same nimcache. That happened on 2026-09-01 and corrupted it twice.
  #
  # So the child, not the lock, is where this has to fail closed. buildlock.py
  # exports AOWL_BUILDLOCK=<its pid>; its absence means nobody is serialising
  # this build. `--no-lock` is the deliberate way out (bootstrap, CI), and
  # `bootstrap` itself is exempt because it is how a worktree gets an aowl.exe
  # in the first place -- run it through the lock anyway when one exists:
  # `python tools\buildlock.py bootstrap`.
  if command == "build" and not noLock and getEnv("AOWL_BUILDLOCK", "").len == 0:
    err "REFUSED: build outside tools/buildlock.py -- run `python tools/buildlock.py build <target>`"
    note "two builds in ONE checkout corrupt each other; separate git " &
         "worktrees are safe and do not contend"
    note "pass --no-lock if you really mean to build unserialised"
    return 4

  # `ui` and `raid` drive a RUNNING game through the inspector's text channel.
  # They compile nothing, so demanding a toolchain checkout -- and printing
  # two lines about it -- would only be a way to fail on a machine that is
  # perfectly able to do the job.
  if command != "ui" and command != "raid":
    if not fileExists(nimonyExe(e)):
      fatal "nimony not found at " & nimonyExe(e) & " (pass --nimony PATH)"
    prepareEnv(e)

    note "repo    " & e.repo
    note "nimony  " & e.nimony

  case command
  of "build":
    if arg.len == 0:
      result = cmdBuild(e)
    else:
      result = cmdBuildOne(e, arg, arg2)
  of "bootstrap": result = cmdBootstrap(e)
  of "worktree-init": result = cmdWorktreeInit(e)
  of "selfcheck":
    if arg.len == 0:
      fatal "selfcheck needs a mod path, e.g. `aowl selfcheck mods\\tarkov`"
    result = cmdSelfCheck(e, arg)
  of "loothash": result = cmdLootHash(e, extra)
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
  of "script":
    # `script` forwards ALL its arguments verbatim (a script takes its own), so
    # the generic parser leaves `arg` empty and the path is the first non-flag
    # token in `extra`.
    var path = arg
    if path.len == 0:
      for a in extra:
        if path.len == 0 and not a.startsWith("-"):
          path = a
    if path.len == 0:
      fatal "script needs a path to a .nim automation script " &
            "(try: aowl script scripts\\woods_pmc_m4.nim)"
    # `--build-only` COMPILES the script and does not run it.
    #
    # It exists because running an automation script LAUNCHES THE GAME, and
    # there was previously no way to ask "does this script compile?" without
    # doing that. Type-checking a script by launching a raid is a very expensive
    # syntax check, and in a subagent or a CI job it is not available at all.
    var sArgs = ""
    var buildOnly = false
    for a in extra:
      if a == path: continue
      if a == "--build-only":
        buildOnly = true
        continue
      if sArgs.len > 0: sArgs.add " "
      sArgs.add quoted(a)
    if buildOnly:
      var exe = ""
      if not buildScript(e, path, exe):
        result = 2
      elif not fileExists(exe):
        # The silent-nimony failure, stated as such. A green exit code with no
        # artifact is the worst outcome this build produces, so it is never
        # reported as a pass.
        err "the script compiled and produced no binary at " & exe &
            " -- that is the silent-nimony failure; do not trust the exit code"
        result = 2
      else:
        ok "script compiled: " & exe & " (NOT RUN -- --build-only)"
        result = 0
    else:
      result = cmdScript(e, path, sArgs)
  of "payload": result = cmdPayload(e)
  of "payload-public": result = cmdPayloadPublic(e, extra)
  of "release": result = cmdRelease(e, extra)
  of "importdb": result = cmdImportDb(e, extra)
  of "clean": result = cmdClean(e)
  of "ui": result = cmdUi(e.repo, extra)
  of "raid": result = cmdRaid(extra)
  else:
    err "unknown command: " & command
    echo Usage
    result = 1

quit(main())
