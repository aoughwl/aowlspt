## firstrun -- the whole path a person walks the first time, in order, against
## a scratch directory.
##
##     firstrun --scratch C:\scratch\firstrun
##     firstrun --scratch C:\scratch\firstrun --spt D:\SPT
##     firstrun --scratch C:\scratch\firstrun --source D:\Games\Tarkov --keep
##
## Every piece of this pipeline is tested in isolation and each of those tests
## is good: the installer's refusal matrix, an installed tree, the emulator
## against an imported database, a live mod-control test, a host driven against
## a stand-in IL2CPP runtime. Their counts are not quoted here, because a number
## copied into a comment goes stale the next time the suite grows and then
## misinforms with authority -- `docs/BACKLOG.md` carries them, re-measured.
## None of them runs the pieces **in order**, and the order is where a first
## run breaks:
##
##  * `aowl build` fails one mod and `aowl payload` stages that mod's config
##    anyway. That used to exit 0, and three commands later `aowlspt-verify`
##    was the first thing to say the directory had no library in it; `aowl
##    payload` now refuses instead. This still checks the staged tree, because
##    the seam is between two programs and only one of them has been fixed --
##    a payload assembled by an older `aowl`, or edited by hand, reaches here
##    the same way.
##  * `aowlspt-install` installs a complete, verifiable, *empty* server. The
##    database is a separate tool, documented in a separate file, and the
##    install is "complete" without it.
##  * `aowl importdb`'s own worked example writes `db.json` one directory above
##    where an installed backend looks for it.
##
## Each of those is a seam between two components that are individually right.
## This walks the seams:
##
##   1. a vanilla client         synthesised under the scratch root, or --source
##   2. aowl payload             staged, and every mod directory holds a library
##   3. payload.json             declares the client that is actually here
##   4. aowlspt-install plan     would proceed
##   5. aowlspt-install install  and the target holds what the plan named
##   6. aowl importdb            a real database, into the directory the backend
##                               reads -- skipped, cleanly, when there is no SPT
##   7. aowlspt-verify           complete, and it serves
##   8. the boot sequence        the client's own requests, against real data
##   9. live mod control         a mod off and on while the server answers
##  10. stop and restart         the profile is still there afterwards
##
## **It skips rather than fails when there is no SPT install to import from**,
## because most machines will not have one and a red gate that means "you do
## not own a game" is a gate people learn to ignore. Everything up to step 6 has
## still run and is still reported.
##
## **Nothing is written outside the scratch root.** The source install and the
## SPT install are opened read-only; a scratch root inside either is refused by
## path check, and so is an SPT install inside the scratch root. The only
## exception is the payload, which is read out of the repo and copied *into* the
## scratch root before a byte of it is touched -- so a mod staged without a
## library is dropped from this run's copy and never from `installer/payload`.

import std/[strutils, syncio, cmdline, osproc, envvars]
import aowlsptinstall/[winfs, log, eft]
import wire

{.emit: """#include <stdlib.h>""".}
{.emit: """#include <string.h>""".}
{.emit: """#include "aowlspt_shim.h" """.}
{.emit: """#include "aowlspt_net.h" """.}
{.emit: """#include "aowlspt_inject.h" """.}

proc cSpawn(exe, workDir, cmdLine: cstring): uint64 {.
  importc: "aowl_spawn", nodecl.}
proc cSpawnAlive(h: uint64): int32 {.importc: "aowl_spawn_alive", nodecl.}
proc cSpawnKill(h: uint64) {.importc: "aowl_spawn_kill", nodecl.}
proc cSleepMs(ms: int32) {.importc: "aowl_sys_sleep", nodecl.}

const
  Usage = """
firstrun -- walk the whole first-run path against a scratch directory

  firstrun --scratch DIR [options]

  --scratch DIR  where everything is created. Required. Nothing is written
                 anywhere else.
  --repo DIR     the repo (default: derived from this executable)
  --source DIR   a vanilla client to mirror (default: one is synthesised under
                 the scratch root with gcc and windres)
  --spt DIR      an SPT install to import the database from (default D:\SPT).
                 Read only. Absent means steps 6 onwards are skipped.
  --ucrt64 PATH  msys2 ucrt64 bin (default C:\msys64\ucrt64\bin)
  --port N       first port to use (default 6990; three are used)
  --boot-wait N  seconds to wait for the backend to answer (default 240 -- the
                 real mod set against a real database takes most of a minute)
  --build        run `aowl build` first, rather than requiring it to have run
  --keep         leave the scratch directory in place at the end
  -v, --verbose  print each command
  -h, --help     this
"""

  Session = "aaaaaaaaaaaaaaaaaaaaaaaa"

  ## Where a first boot stops being a wait and starts looking broken. Derived
  ## from measurement rather than picked. Cold boots of the default mod set
  ## against a 39 MiB imported database, store emptied first: 1.7 s and 2.7-2.9
  ## s on two development machines. This is about three times the slower of
  ## those. It was 10 s while the number it guarded was a warm restart, which
  ## is a threshold set against a different quantity than the one it names.
  ColdBootWarnMs = 8000

var gVerbose = false
var gUcrt64 = "C:\\msys64\\ucrt64\\bin"
var gChecks = 0
var gFailures = 0
var gPort = 6990

proc check(what: string; condition: bool; detail = "") =
  inc gChecks
  if condition:
    ok what
  else:
    err what & (if detail.len > 0: ": " & detail else: "")
    inc gFailures

proc runCmd(what, command: string; workingDir = ""; output: var string): bool =
  ## Every external command goes through here. The output is kept rather than
  ## printed, because a first-run walk that dumps forty thousand copied files
  ## into the terminal is a walk nobody reads to the end of.
  if gVerbose:
    detail command
  var code = -1
  output = ""
  try:
    let (o, c) = execCmdEx(command, workingDir = workingDir)
    output = o
    code = c
  except:
    err what & ": could not start the command"
    inc gFailures
    inc gChecks
    return false
  inc gChecks
  if code == 0:
    ok what
    result = true
  else:
    err what & " (exit " & $code & ")"
    for l in splitLines(output):
      if l.len > 0:
        line "        " & l
    inc gFailures
    result = false

proc quoted(s: string): string =
  result = "\"" & s & "\""

# ------------------------------------------------------------- small parsing

proc valueAfter(text, key: string; start = 0): string =
  ## The string value of `"key":"..."`, from `start`. Hand-rolled because the
  ## only input is a response this program just asked for and knows the shape
  ## of, and a JSON parser would be more machinery than the job.
  let needle = "\"" & key & "\":\""
  let at = find(text, needle, start)
  if at < 0:
    return ""
  var i = at + needle.len
  result = ""
  while i < text.len and text[i] != '"':
    if text[i] == '\\' and i + 1 < text.len:
      inc i
    result.add text[i]
    inc i

proc firstLoadedMod(panel: string): string =
  ## A guid the panel reports as loaded, unprotected and live -- something this
  ## run may turn off and on again without taking the mod manager or the
  ## emulator with it. Discovered rather than named: the mod set is the
  ## registry's business and it changes.
  var i = 0
  while true:
    let at = find(panel, "\"guid\":\"", i)
    if at < 0:
      return ""
    let guid = valueAfter(panel, "guid", at - 1)
    var stop = find(panel, "\"guid\":\"", at + 8)
    if stop < 0:
      stop = panel.len
    let entry = substr(panel, at, stop - 1)
    if find(entry, "\"protected\":true") < 0 and
       find(entry, "\"verdict\":\"loaded\"") >= 0 and
       find(entry, "\"live\":true") >= 0:
      return guid
    i = at + 8

proc verdictOf(panel, guid: string): string =
  let at = find(panel, "\"guid\":\"" & guid & "\"")
  if at < 0:
    return ""
  var stop = find(panel, "\"guid\":\"", at + 8)
  if stop < 0:
    stop = panel.len
  result = valueAfter(substr(panel, at, stop - 1), "verdict")

# ----------------------------------------------------------------- the wire

proc call(path, body: string): Response =
  result = request(gPort, path, body, Session)

proc portIsTaken(): bool =
  ## Whether something already owns the port this walk is about to use. See the
  ## same procedure in `tools/verifyinstall.nim` for what it cost to not ask:
  ## a foreign backend holding the port, ours failing to bind and logging
  ## `listening` regardless, and this program concluding the install was
  ## broken. A walk that can be wrong about the install is worse than a walk
  ## that refuses to start.
  let r = call("/client/game/config", "")
  result = find(r.error, "could not connect") < 0

proc waitForBackend(seconds: int): int =
  ## Milliseconds to the first answer, or -1. Polled rather than slept: how long
  ## a backend takes to come up is a property of the install being walked, and
  ## on a real database with the real mod set it is most of a minute.
  let began = nowMs()
  var waited = 0
  while waited < seconds * 1000:
    let r = call("/client/game/config", "")
    if r.ok and r.contains("\"err\":0"):
      return int(nowMs() - began)
    cSleepMs(250'i32)
    waited = int(nowMs() - began)
  result = -1

# ------------------------------------------------------- the vanilla client

const VersionRc = """
1 VERSIONINFO
FILEVERSION 1,1,0,46777
PRODUCTVERSION 1,1,0,46777
FILEOS 0x4
FILETYPE 0x1
{
 BLOCK "StringFileInfo"
 {
  BLOCK "040904b0"
  {
   VALUE "CompanyName", "Battlestate Games (synthetic fixture)"
   VALUE "FileDescription", "EscapeFromTarkov"
   VALUE "FileVersion", "1.1.0.46777"
   VALUE "ProductName", "EscapeFromTarkov"
   VALUE "ProductVersion", "1.1.0.46777"
  }
 }
 BLOCK "VarFileInfo" { VALUE "Translation", 0x409, 1200 }
}
"""

const FixtureMain = """
#include <stdio.h>
#include <windows.h>
int main(void) {
  printf("synthetic EscapeFromTarkov fixture; this is not a game\n");
  fflush(stdout);
  Sleep(12000);
  return 0;
}
"""

proc synthesiseClient(dir: string): bool =
  ## A vanilla post-1.0 install, made rather than found.
  ##
  ## The version is the one thing about a Tarkov directory that cannot be faked
  ## by copying a file in beside another: `eft.identify` reads it out of the
  ## executable's version resource. So the fixture carries a real one, compiled
  ## by windres into a real PE -- which is what makes every refusal downstream
  ## of it a refusal about a real fact.
  ##
  ## Everything else is shape: `GameAssembly.dll` plus
  ## `il2cpp_data\Metadata\global-metadata.dat` is what makes the backend read
  ## as IL2CPP rather than Mono, `boot.config` carries the build guid, and
  ## `ConsistencyInfo` and `BattlEye` are here precisely so that the installer
  ## can be seen leaving them behind.
  discard removeTree(dir)
  discard ensureDir(joinPath(dir, "EscapeFromTarkov_Data\\il2cpp_data\\Metadata"))
  discard ensureDir(joinPath(dir, "EscapeFromTarkov_Data\\Resources"))
  discard ensureDir(joinPath(dir, "EscapeFromTarkov_Data\\Plugins\\x86_64"))
  discard ensureDir(joinPath(dir, "EscapeFromTarkov_Data\\StreamingAssets\\Windows"))
  discard ensureDir(joinPath(dir, "BattlEye"))

  # By absolute path, not by name. `where windres` on a machine with msys2
  # installed answers `C:\msys64\usr\bin\windres.exe` first -- the MSYS build,
  # whose preprocessor cannot read a resource script and says only
  # "preprocessing failed". This is the same trap `aowl doctor` checks for with
  # Git-for-Windows' mingw64, one directory over.
  var windres = joinPath(gUcrt64, "windres.exe")
  if not fileExists(windres): windres = "windres"
  var gccExe = joinPath(gUcrt64, "gcc.exe")
  if not fileExists(gccExe): gccExe = "gcc"

  let rc = joinPath(dir, "ver.rc")
  let res = joinPath(dir, "ver.res")
  let src = joinPath(dir, "main.c")
  discard writeTextFile(rc, VersionRc)
  discard writeTextFile(src, FixtureMain)

  var out1 = ""
  if not runCmd("compile a version resource",
                quoted(windres) & " " & quoted(rc) & " -O coff -o " &
                quoted(res),
                dir, out1):
    note "windres comes with msys2's ucrt64 toolchain, the same one that"
    note "builds everything else here. `aowl doctor` checks for it."
    return false
  var out2 = ""
  if not runCmd("link a client carrying that resource",
                quoted(gccExe) & " -O1 -o " &
                quoted(joinPath(dir, "EscapeFromTarkov.exe")) &
                " " & quoted(src) & " " & quoted(res), dir, out2):
    return false

  discard removeFileAt(rc)
  discard removeFileAt(res)
  discard removeFileAt(src)

  discard writeTextFile(joinPath(dir, "EscapeFromTarkov_Data\\boot.config"),
    "build-guid=027f6efbac104c93993ac42b36d26826\n" &
    "scripting-runtime-version=latest\n")
  discard writeTextFile(joinPath(dir, "ConsistencyInfo"),
    "{\"Version\":\"1.1.0.1.46777\",\"Entries\":[" &
    "{\"Path\":\"EscapeFromTarkov.exe\"}]}\n")
  discard writeTextFile(joinPath(dir,
    "EscapeFromTarkov_Data\\il2cpp_data\\Metadata\\global-metadata.dat"),
    "synthetic il2cpp metadata\n")
  discard writeTextFile(joinPath(dir, "GameAssembly.dll"), "synthetic\n")
  discard writeTextFile(joinPath(dir, "UnityPlayer.dll"), "synthetic\n")
  discard writeTextFile(joinPath(dir, "baselib.dll"), "synthetic\n")
  discard writeTextFile(joinPath(dir, "EscapeFromTarkov_BE.exe"), "synthetic\n")
  discard writeTextFile(joinPath(dir, "BattlEye\\BEClient_x64.dll"), "synthetic\n")
  discard writeTextFile(joinPath(dir,
    "EscapeFromTarkov_Data\\globalgamemanagers"), "synthetic\n")
  discard writeTextFile(joinPath(dir,
    "EscapeFromTarkov_Data\\Resources\\unity_builtin_extra"), "synthetic\n")
  discard writeTextFile(joinPath(dir,
    "EscapeFromTarkov_Data\\Plugins\\x86_64\\nvngx.dll"), "synthetic\n")
  # A few asset bundles, so that the hard-linking half of the mirror is
  # exercised rather than only the copy half.
  var i = 1
  while i <= 8:
    discard writeTextFile(joinPath(dir,
      "EscapeFromTarkov_Data\\StreamingAssets\\Windows\\bundle" & $i &
      ".bundle"), "synthetic bundle " & $i & "\n")
    inc i
  result = true

# ---------------------------------------------------------------- the payload

proc stagePayload(repo, dest: string): bool =
  ## The repo's payload, copied into the scratch root before anything reads it.
  ##
  ## Copied rather than pointed at for two reasons, and the second is the real
  ## one. `payload.json` has to be patched to declare the client in front of us,
  ## and patching a file in the repo from a test is how a repo ends up with a
  ## dirty tree nobody can explain. And a mod that failed to build stages as a
  ## config directory with no library in it -- which this run reports as a
  ## failure and then drops from *its own copy*, so that the eight steps after
  ## it still run and still mean something.
  let src = joinPath(repo, "installer\\payload")
  if not isDirectory(src):
    err "no payload at " & src
    note "run `aowl build` then `aowl payload` first"
    return false
  discard removeTree(dest)
  discard ensureDir(dest)

  var files: seq[string] = @[]
  var dirs: seq[string] = @[]
  collectEntries(src, files, dirs)
  for d in dirs:
    discard ensureDir(joinPath(dest, d))
  var copied = 0
  var unreadable: seq[string] = @[]
  for f in files:
    if find(f, "nimcache") >= 0:
      continue
    if copyFileAt(joinPath(src, f), joinPath(dest, f)).ok:
      inc copied
    else:
      unreadable.add f
  line "  " & $copied & " file(s) staged into " & dest
  # A copy that failed used to be dropped on the floor: the count went up by
  # one less and nothing said which file, so a payload missing a mod library
  # because the file was locked read as a payload that never had one. The two
  # have different answers and the walk should not have to guess.
  if unreadable.len > 0:
    for f in unreadable:
      check("staged " & f, false, "could not be copied out of " & src)
    note "the payload in the repo is intact; these could not be read out of " &
         "it, which usually means something else has them open"
  result = copied > 0 and unreadable.len == 0

proc auditStagedMods(dest: string): int =
  ## Every mod directory in the staged payload has to hold a library. The one
  ## that does not is the failure this whole file exists to move earlier: `aowl
  ## build` said so and exited 1, `aowl payload` warned and exited 0, and
  ## nothing between here and `aowlspt-verify` looks again.
  ##
  ## Returns how many were dropped. Dropping is not a repair -- the failure is
  ## already recorded -- it is what lets the rest of the walk happen.
  result = 0
  let modsDir = joinPath(dest, "aowlspt\\mods")
  if not isDirectory(modsDir):
    check("the payload carries mods", false, "no " & modsDir)
    return
  var files: seq[string] = @[]
  var dirs: seq[string] = @[]
  collectEntries(modsDir, files, dirs)
  var total = 0
  for d in dirs:
    if find(d, "\\") >= 0:
      continue
    inc total
    let here = joinPath(modsDir, d)
    var mine: seq[string] = @[]
    var minedirs: seq[string] = @[]
    collectEntries(here, mine, minedirs)
    var hasLib = false
    for f in mine:
      if toLowerAscii(f) == toLowerAscii(d) & ".dll":
        hasLib = true
    if not hasLib:
      check("mod " & d & " was staged with its library", false,
            "no " & d & ".dll; `aowl build` failed this mod and `aowl " &
            "payload` staged its config anyway")
      discard removeTree(here)
      inc result
  check("the payload carries mods", total > 0)
  if result > 0:
    note $result & " library-less mod directory/directories dropped from " &
         "this run's copy so that the rest of the walk can happen; " &
         "installer\\payload was not touched"

proc patchPayloadVersion(dest, version: string): bool =
  ## `targetTarkovVersion` is the entire basis on which the installer decides
  ## whether these binaries can run on the client in front of it, and on a real
  ## first run it is edited by hand out of what `detect` printed. Doing it here
  ## is both the automation of that step and the check that the field is where
  ## the documentation says it is.
  let path = joinPath(dest, "payload.json")
  var text = ""
  if not readTextFile(path, text):
    err "could not read " & path
    return false
  let key = "\"targetTarkovVersion\""
  let at = find(text, key)
  if at < 0:
    err "no targetTarkovVersion in " & path
    return false
  let openq = find(text, "\"", find(text, ":", at) + 1)
  if openq < 0:
    err "malformed targetTarkovVersion in " & path
    return false
  var closeq = openq + 1
  while closeq < text.len and text[closeq] != '"':
    inc closeq
  let was = substr(text, openq + 1, closeq - 1)
  if was == version:
    line "  payload already declares " & version
    return true
  let patched = substr(text, 0, openq) & version & substr(text, closeq)
  if not writeTextFile(path, patched).ok:
    err "could not write " & path
    return false
  line "  payload declared " & was & "; set to " & version
  result = true

# -------------------------------------------------------------------- main

type Opts = object
  scratch: string
  repo: string
  source: string
  spt: string
  bootWait: int
  build: bool
  keep: bool
  help: bool

proc repoRootFrom(exe: string): string =
  var cur = parentOf(absolutePathOf(exe))
  while cur.len > 0:
    if isDirectory(joinPath(cur, "abi")) and
       fileExists(joinPath(cur, "abi\\aowlspt_abi.h")):
      return cur
    let up = parentOf(cur)
    if up.len == 0 or up == cur:
      break
    cur = up
  result = ""

proc parseInt2(s: string; into: var int): bool =
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

proc hasSptDatabase(fromPath: string): bool =
  ## The same four places `aowl importdb` looks, asked before it is run so that
  ## the skip is a sentence rather than an exit code.
  if fromPath.len == 0:
    return false
  let candidates = [
    joinPath(fromPath, "SPT_Runtime\\SPT_Data\\database"),
    joinPath(fromPath, "SPT_Data\\database"),
    joinPath(fromPath, "database"),
    fromPath]
  for c in candidates:
    if isDirectory(c) and fileExists(joinPath(c, "globals.json")):
      return true
  result = false

proc main(): int =
  var o = Opts(scratch: "", repo: "", source: "", spt: "D:\\SPT",
               bootWait: 240, build: false, keep: false, help: false)
  var i = 1
  let n = paramCount()
  while i <= n:
    let a = paramStr(i)
    if a == "--scratch":
      inc i
      if i <= n: o.scratch = paramStr(i)
    elif a == "--repo":
      inc i
      if i <= n: o.repo = paramStr(i)
    elif a == "--source":
      inc i
      if i <= n: o.source = paramStr(i)
    elif a == "--spt":
      inc i
      if i <= n: o.spt = paramStr(i)
    elif a == "--port":
      inc i
      if i <= n: discard parseInt2(paramStr(i), gPort)
    elif a == "--boot-wait":
      inc i
      if i <= n: discard parseInt2(paramStr(i), o.bootWait)
    elif a == "--ucrt64":
      inc i
      if i <= n: gUcrt64 = paramStr(i)
    elif a == "--build":
      o.build = true
    elif a == "--keep":
      o.keep = true
    elif a == "--verbose" or a == "-v":
      gVerbose = true
      setVerbosity vVerbose
    elif a == "--help" or a == "-h":
      o.help = true
    elif a.startsWith("-"):
      fatal "unknown option: " & a
    elif o.scratch.len == 0:
      o.scratch = a
    inc i

  if o.help:
    echo Usage
    return 0
  if o.scratch.len == 0:
    echo Usage
    err "firstrun writes only inside --scratch, so it needs one"
    return 1

  if o.repo.len == 0:
    o.repo = repoRootFrom(paramStr(0))
  if o.repo.len == 0 or not isDirectory(joinPath(o.repo, "abi")):
    fatal "could not find the repo; pass --repo PATH"
  o.repo = absolutePathOf(o.repo)
  o.scratch = absolutePathOf(o.scratch)
  if o.source.len > 0: o.source = absolutePathOf(o.source)
  if o.spt.len > 0 and isDirectory(o.spt): o.spt = absolutePathOf(o.spt)

  # The same PATH surgery `aowl` does, for the same reason: everything this
  # program shells out to has to find ucrt64's toolchain rather than MSYS's or
  # Git-for-Windows'. `aowl build` is one of those things.
  if isDirectory(gUcrt64):
    try:
      putEnv("PATH", gUcrt64 & ";" & getEnv("PATH", ""))
    except:
      warn "could not set PATH; the toolchain may resolve to the wrong mingw"

  heading "firstrun"
  line "  repo     " & o.repo
  line "  scratch  " & o.scratch

  # ------------------------------------------------------------ path safety
  #
  # Everything this program writes goes under `--scratch`, and the two
  # directories it reads are somebody's games. The checks are refusals rather
  # than warnings because each of them describes a run that would write into
  # one of those two directories, and there is no version of that which is what
  # the person meant.
  heading "Where this may write"
  if o.spt.len > 0 and isDirectory(o.spt):
    if isUnder(o.scratch, o.spt):
      fatal "the scratch root is inside the SPT install at " & o.spt &
            "; this program reads that install and never writes to one"
    if isUnder(o.spt, o.scratch):
      fatal "the SPT install is inside the scratch root; the scratch root is " &
            "removed at the end of a run"
  if o.source.len > 0 and isDirectory(o.source):
    if isUnder(o.scratch, o.source):
      fatal "the scratch root is inside --source; --source is the install " &
            "being mirrored and is only ever read"
    if isUnder(o.source, o.scratch):
      fatal "--source is inside the scratch root"
  if isUnder(o.repo, o.scratch):
    fatal "the repo is inside the scratch root"
  ok "everything written by this run goes under " & o.scratch
  if o.spt.len > 0:
    line "  " & o.spt & " is read-only here"
  if o.source.len > 0:
    line "  " & o.source & " is read-only here"

  let build = joinPath(o.repo, "installer\\build")
  let aowlExe = joinPath(build, "aowl.exe")
  let installExe = joinPath(build, "aowlspt-install.exe")
  let verifyExe = joinPath(build, "aowlspt-verify.exe")

  # ------------------------------------------------------------- 0. build
  heading "0. What this walks with"
  if o.build:
    var out0 = ""
    # Not a hard stop: `aowl build` exits 1 when any one mod fails, and the
    # whole point of the next step is that the pipeline does not currently
    # notice. Recording it and carrying on is what shows the seam.
    if not runCmd("aowl build", quoted(aowlExe) & " build", o.repo, out0):
      note "carrying on: the failure above is exactly what step 2 checks for"
  check("aowl is built", fileExists(aowlExe), "no " & aowlExe)
  check("aowlspt-install is built", fileExists(installExe), "no " & installExe)
  check("aowlspt-verify is built", fileExists(verifyExe),
        "no " & verifyExe & "; `aowl build` builds it")
  if gFailures > 0:
    heading "Result"
    err "run `aowl build` first"
    return 1

  discard ensureDir(o.scratch)
  let clientDir = (if o.source.len > 0: o.source
                   else: joinPath(o.scratch, "vanilla"))
  let payDir = joinPath(o.scratch, "payload")
  let target = joinPath(o.scratch, "target")
  let aowlDir = joinPath(target, "aowlspt")

  # ------------------------------------------------------------- 1. client
  heading "1. A vanilla client"
  if o.source.len > 0:
    line "  using " & clientDir & " (read only)"
  else:
    if not synthesiseClient(clientDir):
      heading "Result"
      err "could not build a client fixture, and no --source was given"
      return 1
  let install = identify(clientDir)
  for l in eft.describe(install):
    line "  " & l
  check("there is a client here", install.exists, "no EscapeFromTarkov.exe")
  check("it is post-1.0", install.exists and isPostOneZero(install.version),
        $install.version & " is not a post-1.0 client")
  check("it is IL2CPP", install.backend == bkIl2Cpp,
        "the client reads as " & $install.backend)
  if gFailures > 0:
    heading "Result"
    err "there is no usable client to install from"
    return 1
  let clientVersion = $install.version

  # ------------------------------------------------------------ 2. payload
  heading "2. The payload"
  if not stagePayload(o.repo, payDir):
    heading "Result"
    err "no payload to install"
    return 1
  discard auditStagedMods(payDir)
  check("the client host is in the payload",
        fileExists(joinPath(payDir, "aowlspt\\aowlspt-host-il2cpp.dll")),
        "the install would start the game with no mods in it")
  check("the backend is in the payload",
        fileExists(joinPath(payDir, "aowlspt\\aowlspt-backend.exe")),
        "the client would have nothing to talk to")
  check("the launcher is in the payload",
        fileExists(joinPath(payDir, "aowlspt\\aowlspt-launch.exe")))
  check("the registry is in the payload",
        fileExists(joinPath(payDir, "aowlspt\\registry\\mods.json")),
        "the mod manager would come up managing nothing")

  # ------------------------------------------------- 3. payload declaration
  heading "3. What the payload declares"
  if not patchPayloadVersion(payDir, clientVersion):
    heading "Result"
    err "the payload does not declare what it was built for"
    return 1
  ok "the payload declares " & clientVersion

  # --------------------------------------------------------------- 4. plan
  heading "4. Plan"
  var planOut = ""
  let planned = runCmd("aowlspt-install plan",
    quoted(installExe) & " plan --source " & quoted(clientDir) &
    " --target " & quoted(target) & " --payload " & quoted(payDir),
    o.repo, planOut)
  check("the plan would proceed", planned and
        find(planOut, "this would proceed") >= 0,
        "the installer objected; see the findings above")
  check("the plan mirrors a client", find(planOut, "mirror") >= 0,
        "no mirror step: this payload would install an aowlspt directory " &
        "with no game beside it")

  # ------------------------------------------------------------ 5. install
  heading "5. Install"
  var instOut = ""
  discard runCmd("aowlspt-install install",
    quoted(installExe) & " install --source " & quoted(clientDir) &
    " --target " & quoted(target) & " --payload " & quoted(payDir) & " --yes",
    o.repo, instOut)
  check("the client was mirrored",
        fileExists(joinPath(target, "EscapeFromTarkov.exe")))
  check("BattlEye was left behind",
        not isDirectory(joinPath(target, "BattlEye")),
        "BattlEye is anti-cheat for a service this client never talks to")
  check("the source was not written to",
        fileExists(joinPath(clientDir, "EscapeFromTarkov.exe")) and
        not isDirectory(joinPath(clientDir, "aowlspt")),
        "there is an aowlspt directory in the source install")
  check("the host is installed",
        fileExists(joinPath(aowlDir, "aowlspt-host-il2cpp.dll")))
  check("the backend is installed",
        fileExists(joinPath(aowlDir, "aowlspt-backend.exe")))
  check("the launcher is installed",
        fileExists(joinPath(aowlDir, "aowlspt-launch.exe")))
  check("the registry is installed",
        fileExists(joinPath(aowlDir, "registry\\mods.json")))
  check("the client knows where the backend is",
        fileExists(joinPath(aowlDir, "backend.json")))
  check("there is an uninstall manifest",
        fileExists(joinPath(target, "aowlspt-install.txt")),
        "`aowlspt-install uninstall` would refuse to run")

  # Stop here rather than three steps later. A payload assembled before `aowl
  # payload` learned to refuse one carries the host and the launcher and no
  # `aowlspt-backend.exe`; every check above reports that honestly and the walk
  # then carries on to step 8 and dies as *"could not spawn ...
  # aowlspt-backend.exe"* -- which is the symptom, printed three steps and two
  # minutes away from the cause, and is what a reader of that output blames on
  # the spawn. The binaries the rest of this walk *runs* are worth a gate of
  # their own; the checks above are the diagnosis and this is only the halt.
  if not fileExists(joinPath(aowlDir, "aowlspt-backend.exe")) or
     not fileExists(joinPath(aowlDir, "aowlspt-host-il2cpp.dll")):
    heading "Result"
    line "  " & $gChecks & " checks"
    err "the installed tree has no backend and/or no client host; steps 6-10 " &
        "run against those two binaries and there is nothing to run"
    note "this walk installs `installer\\payload`. `aowl payload` refuses to " &
         "assemble one without them, so a payload missing them was staged " &
         "before that refusal or edited by hand: run `aowl build` and then " &
         "`aowl payload`, and walk again."
    note "the scratch root was left at " & o.scratch & " to look at"
    return 1

  # ------------------------------------------------------------ 6. database
  #
  # The step INSTALL.md did not have. Everything above installs a complete,
  # verifiable server that answers every route out of the emulator's fallbacks
  # -- no items, no traders, no quests, no maps. This is what makes it a game.
  heading "6. A real database"
  var haveDb = false
  if not hasSptDatabase(o.spt):
    note "skipped: no SPT install at " & o.spt
    note "  pass --spt PATH, or install SPT somewhere and re-run."
    note "  Without it the server comes up on the emulator's fallbacks: it"
    note "  answers every route and the game has nothing in it."
    note "  The step is:  aowl importdb --from " & o.spt & " --out " & aowlDir
  else:
    var impOut = ""
    # `--out` is the directory the *backend* reads, which is `<target>\aowlspt`
    # and not `<target>`. Getting that wrong puts a 39 MiB file one directory
    # above where anything looks for it, and the server comes up on its
    # fallbacks with nothing anywhere saying why.
    if runCmd("aowl importdb",
              quoted(aowlExe) & " importdb --from " & quoted(o.spt) &
              " --out " & quoted(aowlDir), o.repo, impOut):
      let dbPath = joinPath(aowlDir, "db.json")
      let bytes = fileSizeOf(dbPath)
      check("the database landed where the backend reads it",
            fileExists(dbPath), "no " & dbPath)
      check("it is a real database rather than a fixture",
            bytes > 1048576'i64,
            $bytes & " bytes; a real import is tens of megabytes")
      if fileExists(dbPath) and bytes > 1048576'i64:
        line "  " & $(bytes div 1048576'i64) & " MiB at " & dbPath
        haveDb = true
      check("the import did not write into the SPT install",
            not fileExists(joinPath(o.spt, "db.json")),
            "there is a db.json in " & o.spt)

  # -------------------------------------------------------------- 7. verify
  heading "7. Verify"
  var verOut = ""
  let verified = runCmd("aowlspt-verify",
    quoted(verifyExe) & " --root " & quoted(target) & " --port " &
    $(gPort + 1), o.repo, verOut)
  check("the install is complete and serves", verified and
        find(verOut, "this install is complete and serves") >= 0,
        "aowlspt-verify is not happy with this install")

  if not haveDb:
    heading "Result"
    line "  " & $gChecks & " checks"
    if gFailures > 0:
      err $gFailures & " failed"
      # Left on disk deliberately: a failed walk is the one you want to open.
      note "the scratch root was left at " & o.scratch & " to look at"
      return 1
    ok "everything up to the database step passed"
    note "steps 8-10 need a database; see the skip above. This is exit 0 on"
    note "purpose: most machines have no SPT install to import from."
    if not o.keep:
      discard removeTree(o.scratch)
    return 0

  # ---------------------------------------------------- 8. the boot sequence
  heading "8. The client's boot sequence, against real data"
  if cNetStartup() == 0'i32:
    check("winsock is available", false, "error " & $int(cNetLastError()))
    return 1
  let backendExe = joinPath(aowlDir, "aowlspt-backend.exe")
  if portIsTaken():
    check("nothing else is already on port " & $gPort, false,
          "something is answering on 127.0.0.1:" & $gPort & " already; " &
          "everything below would be measured against it rather than against " &
          "this install. Pass --port with a free one.")
    heading "Result"
    err "the port this walk needs is in use"
    note "the scratch root was left at " & o.scratch
    return 1

  # Cold, on purpose, and this was wrong for as long as the number existed.
  #
  # Step 7 runs `aowlspt-verify`, which starts this same backend against this
  # same install -- so by the time the timing below happens, the mod store is
  # warm and every mod takes its "already done" path. The measurement was of a
  # *restart*, printed under the words "boot to first answer", and it was
  # insensitive to the thing it looked like it measured: across a change that
  # cut real first-boot time by 40% it moved from 2893 ms to 2882 ms. The same
  # install with the store cleared went 2854 ms to 1690 ms.
  #
  # A player's first start is the cold one, so that is what is timed. The
  # restart is timed too, in step 10, because both are worth knowing and
  # neither substitutes for the other.
  discard removeTree(joinPath(aowlDir, "store"))
  discard removeFileAt(joinPath(aowlDir, "mods\\aowlspt-selection.json"))
  discard removeFileAt(joinPath(aowlDir, "aowlspt-backend.log"))
  check("the store is empty before the boot is timed",
        not isDirectory(joinPath(aowlDir, "store")),
        "step 7 left one behind and it could not be removed; the number " &
        "below would be a restart wearing the word boot")
  var be = backendExe
  var bd = aowlDir
  var bc = "\"" & backendExe & "\" --root \"" & aowlDir & "\" --port " & $gPort
  var server = cSpawn(toCString(be), toCString(bd), toCString(bc))
  if server == 0'u64:
    check("the backend starts", false, "could not spawn " & backendExe)
    return 1
  let bootMs = waitForBackend(o.bootWait)
  check("the backend answers", bootMs >= 0,
        "no answer on 127.0.0.1:" & $gPort & " after " & $o.bootWait &
        "s; see " & joinPath(aowlDir, "aowlspt-backend.log"))
  if bootMs < 0:
    cSpawnKill(server)
    heading "Result"
    err "the server never came up"
    return 1
  line "  first boot, empty store, to first answer: " & $bootMs & " ms"
  if bootMs > ColdBootWarnMs:
    # Named rather than left in the timings, because a slow boot is felt as a
    # game that starts before its server can answer it.
    #
    # `aowlspt-launch` used to sleep 1.2 s and then start the client regardless,
    # which made any boot over that a guaranteed race; it now polls the backend
    # with a real request until it answers, so this is no longer a broken
    # first launch. It is still worth saying: the player watches it, and a boot
    # this long usually means a mod is doing work in `on_load` that belongs
    # somewhere else -- four of them were, and it cost 54 seconds.
    warn "the first boot took " & $(bootMs div 1000) & "s to answer, against " &
         "the 1.7-2.9 s measured on development machines. aowlspt-launch " &
         "will wait for it rather than racing it, but the player waits too, " &
         "and this is long enough to look broken."

  block:
    let r = call("/client/game/config", "")
    check("/client/game/config", r.ok and r.contains("\"err\":0"), r.error)
  block:
    let r = call("/client/game/version/validate",
                 "{\"version\":{\"major\":\"" & clientVersion & "\"}}")
    check("/client/game/version/validate accepts this client",
          r.ok and r.contains("\"err\":0"), r.error)
  block:
    let r = call("/client/items", "")
    check("/client/items is the real item table",
          r.ok and r.body.len > 1000000,
          $r.body.len & " bytes; a real table is over ten megabytes")
    if r.ok:
      line "  /client/items " & $(r.body.len div 1024) & " KiB"
  block:
    let r = call("/client/locale/en", "")
    # The one assertion in this file that names a value out of BSG's data, and
    # it is here because it is the difference this whole step is about: a
    # fallback locale answers with an empty table and `err:0`, and looks
    # exactly like a working server until you are in the menu reading item ids.
    check("/client/locale/en has the game's own strings",
          r.ok and r.contains("Roubles"),
          "no \"Roubles\" in the locale; this is a fallback, not real data")
  block:
    let r = call("/client/globals", "")
    check("/client/globals", r.ok and r.body.len > 10000, $r.body.len & " bytes")
  block:
    let r = call("/client/handbook/templates", "")
    check("/client/handbook/templates", r.ok and r.body.len > 10000,
          $r.body.len & " bytes")
  block:
    let r = call("/client/locations", "")
    check("/client/locations has real maps", r.ok and r.body.len > 100000,
          $r.body.len & " bytes")
  block:
    let r = call("/client/quest/list", "")
    check("/client/quest/list has real quests", r.ok and r.body.len > 100000,
          $r.body.len & " bytes")
  block:
    let r = call("/client/trading/api/traderSettings", "")
    check("/client/trading/api/traderSettings has real traders",
          r.ok and r.body.len > 10000, $r.body.len & " bytes")

  heading "A profile"
  var profileId = ""
  block:
    let r = call("/client/game/profile/create",
                 "{\"side\":\"Usec\",\"nickname\":\"firstrun\"," &
                 "\"headId\":\"\",\"voiceId\":\"\"}")
    check("a profile can be created", r.ok, r.error)
  block:
    let r = call("/client/game/profile/list", "")
    check("the profile store answers", r.ok and r.contains("\"err\":0"),
          r.error)
    profileId = valueAfter(r.body, "_id")
    check("there is a profile in it", profileId.len > 0,
          "the store came back empty after a create")
    if profileId.len > 0:
      line "  profile " & profileId

  # ---------------------------------------------------- 9. live mod control
  heading "9. A mod off and on while the server answers"
  var victim = ""
  block:
    let r = call("/aowlspt/mods", "")
    check("the mod manager is loaded", r.ok and r.contains("\"ok\":true"),
          r.error)
    check("it found the registry", r.ok and not r.contains("\"registry\":\"\""),
          "the manager is running with no registry")
    check("live control is available", r.ok and
          r.contains("\"control\":\"present\""),
          "changes would be saved and take effect on the next start")
  block:
    let r = call("/aowlspt/mods/panel", "")
    check("the panel answers", r.ok and r.contains("\"schema\""), r.error)
    if r.ok:
      victim = firstLoadedMod(r.body)
    check("there is a mod to switch off", victim.len > 0,
          "no unprotected, loaded, live mod on the panel")
  if victim.len > 0:
    line "  switching " & victim
    block:
      let r = call("/aowlspt/mods/disable/" & victim, "")
      check("it can be disabled", r.ok and r.contains("\"ok\":true"), r.error)
    block:
      # The disable is a decision; `/apply` is what performs it. That is the
      # part a person reading MODMANAGER.md has to notice, and the part a test
      # that only called `/disable` would pass without.
      let r = call("/aowlspt/mods/apply", "")
      check("the selection can be applied", r.ok and r.contains("\"ok\":true"),
            r.error)
    cSleepMs(1500'i32)
    block:
      let r = call("/aowlspt/mods/panel", "")
      check("the panel now reports it off",
            r.ok and verdictOf(r.body, victim) != "loaded",
            "still \"" & verdictOf(r.body, victim) & "\" after apply")
    block:
      # The manager's own route, not the emulator's. The mod this run picked is
      # whichever the panel listed first, and on the default list that is the
      # emulator -- whose routes are *supposed* to be gone once it is unloaded.
      # Asking a route the victim might own would make this check pass or fail
      # on which mod happened to be first, which is not a fact about the server.
      let r = call("/aowlspt/mods", "")
      check("the server still answers with a mod unloaded",
            r.ok and r.contains("\"ok\":true"), r.error)
    block:
      let r = call("/aowlspt/mods/enable/" & victim, "")
      check("it can be enabled again", r.ok and r.contains("\"ok\":true"),
            r.error)
    block:
      let r = call("/aowlspt/mods/apply", "")
      check("and applied again", r.ok and r.contains("\"ok\":true"), r.error)
    cSleepMs(1500'i32)
    block:
      let r = call("/aowlspt/mods/panel", "")
      check("the panel reports it loaded again",
            r.ok and verdictOf(r.body, victim) == "loaded",
            "\"" & verdictOf(r.body, victim) & "\" after re-enabling")
    block:
      # And the client's own first question answers again. A panel that says
      # "loaded" over a mod whose routes never came back is the one failure
      # mode a mod manager must not have.
      let r = call("/client/game/config", "")
      check("and the client's boot route answers again",
            r.ok and r.contains("\"err\":0"), r.error)

  # -------------------------------------------------- 10. stop, and restart
  #
  # There is no shutdown route and no console-control handler: stopping the
  # backend is `TerminateProcess`, which is what `aowlspt-launch --wait` does
  # too. That is safe by construction rather than by luck -- a store write is a
  # temporary file renamed over the key -- and this is the check that says so
  # about a real profile in a real install rather than about a fixture.
  heading "10. Stop, restart, and look for the profile"
  cSpawnKill(server)
  cSleepMs(1000'i32)
  check("the backend stopped", cSpawnAlive(server) == 0'i32,
        "it is still running")

  var be2 = backendExe
  var bd2 = aowlDir
  var bc2 = "\"" & backendExe & "\" --root \"" & aowlDir & "\" --port " & $gPort
  server = cSpawn(toCString(be2), toCString(bd2), toCString(bc2))
  check("it starts again", server != 0'u64, "could not respawn " & backendExe)
  if server != 0'u64:
    let again = waitForBackend(o.bootWait)
    check("and answers again", again >= 0,
          "no answer after " & $o.bootWait & "s")
    if again >= 0:
      # The other half of the pair. This one has a warm store behind it -- the
      # profile, the selection and everything the mods wrote on the boot above
      # -- so it is the number a player sees on every start after the first,
      # and it is the number this walk used to print as though it were the
      # first.
      #
      # How large the gap between the two is, is not settled. It has been
      # measured at better than 2x on one machine and at about 2% on another
      # (2721 ms cold against 2656 ms warm, same install, store emptied
      # between). Printing both and labelling them is what makes that an
      # observation rather than an argument; a single number could only ever be
      # one machine's answer wearing the other's name.
      line "  restart, warm store, to first answer: " & $again & " ms"
      if again >= 0 and bootMs >= 0:
        # Signed, and not dressed up. A negative number here means the store
        # bought nothing on this machine, which is a result and not an error.
        line "  first boot minus restart: " & $(bootMs - again) & " ms"
      let r = call("/client/game/profile/list", "")
      check("the profile survived the server being stopped",
            r.ok and profileId.len > 0 and r.contains(profileId),
            "profile " & profileId & " is not in the store any more")
      let p = call("/aowlspt/mods/panel", "")
      check("and so did the mod selection",
            p.ok and (victim.len == 0 or verdictOf(p.body, victim) == "loaded"),
            "the selection did not survive a restart")
    cSpawnKill(server)

  # ------------------------------------------------------------------ done
  #
  # A failed walk keeps its scratch root: the logs under `<target>\aowlspt` are
  # the only record of why, and removing them is removing the answer.
  if not o.keep and gFailures == 0:
    heading "Cleanup"
    cSleepMs(500'i32)
    let r = removeTree(o.scratch)
    if r.ok:
      ok "removed " & o.scratch
    else:
      warn "could not remove " & o.scratch & " (error " & $r.err & ")"
  else:
    heading "Left in place"
    line "  " & target

  heading "Result"
  line "  " & $gChecks & " checks"
  if gFailures > 0:
    err $gFailures & " failed"
    return 1
  ok "the whole first-run path works, from a vanilla client to a server " &
     "serving real data with mods being switched live"
  result = 0

quit(main())
