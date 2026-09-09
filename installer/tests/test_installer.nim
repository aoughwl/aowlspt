## Tests for aowlspt-install.
##
##     nimony c -p:../src -o:../build/test-installer.exe test_installer.nim
##     ../build/test-installer.exe
##
## The refusal matrix (`compat`) is tested against constructed values rather
## than against real installs, because the cases worth testing are the ones a
## developer cannot produce on demand: a client that reports no version, an
## IL2CPP payload aimed at a Mono client, a pre-1.0 payload aimed at a post-1.0
## client. Waiting for a machine that has one of those is not testing.
##
## The filesystem layer is tested against a real temporary directory, because
## the whole reason it exists is that Win32 behaves in ways a mock would not:
## hard links across volumes, read-only attributes, deleting a non-empty tree.
##
## The last test runs against whatever real Tarkov install this machine has, if
## any, and only ever reads it.

import std/[strutils, syncio, envvars]
import aowlsptinstall/[winfs, eft, payload, compat, plan, journal, log,
                       registry]

var passed = 0
var failed = 0

proc check(name: string; cond: bool) =
  if cond:
    inc passed
    echo "ok    " & name
  else:
    inc failed
    echo "FAIL  " & name

proc checkEq(name, got, want: string) =
  if got == want:
    inc passed
    echo "ok    " & name
  else:
    inc failed
    echo "FAIL  " & name
    echo "        got  [" & got & "]"
    echo "        want [" & want & "]"

# --------------------------------------------------------------- fixtures

proc tempRoot(): string =
  var base = getEnv("TEMP", "")
  if base.len == 0:
    base = getEnv("TMP", "")
  if base.len == 0:
    base = "C:\\Windows\\Temp"
  result = joinPath(base, "aowlspt-install-tests")

proc anInstall(version: string; backend: Backend; flavour: Flavour): EftInstall =
  ## A plausible `EftInstall` without needing a game on disk.
  result = EftInstall(root: "X:\\Tarkov", exists: true, flavour: flavour,
                      backend: backend, version: parseVersion(version),
                      consistencyVersion: parseVersion(""),
                      unityVersion: "", buildGuid: "",
                      hasBepInEx: flavour != flVanilla,
                      hasDoorstop: flavour != flVanilla,
                      hasSptRuntime: flavour == flSpt,
                      hasBattlEye: flavour == flVanilla,
                      sptCompatibleVersion: parseVersion(""), notes: @[])

proc aPayload(version: string; backend: Backend; kind: PayloadKind): Payload =
  result = Payload(root: "X:\\payload", valid: true, kind: kind,
                   name: "test", version: "1", targetTarkov: parseVersion(version),
                   targetBackend: backend, backendUrl: "https://127.0.0.1:6969",
                   hasRuntime: kind == plFull, hasClient: kind == plFull,
                   hasAowlspt: true, problems: @[])

proc worstOf(v: Verdict): Severity =
  result = sevOk
  for f in v.findings:
    if f.severity > result:
      result = f.severity

# --------------------------------------------------------------- paths

proc testPaths() =
  echo "\npath arithmetic"
  checkEq("joinPath", joinPath("C:/a", "/b/c"), "C:\\a\\b\\c")
  checkEq("joinPath empty tail", joinPath("C:/a", ""), "C:\\a")
  checkEq("parentOf", parentOf("C:/a/b/c"), "C:\\a\\b")
  checkEq("parentOf trailing sep", parentOf("C:/a/b/"), "C:\\a")
  checkEq("baseName", baseName("C:/a/b/c"), "c")
  checkEq("baseName trailing sep", baseName("C:/a/b/"), "b")
  checkEq("driveOf", driveOf("d:/games"), "D")
  checkEq("driveOf UNC", driveOf("\\\\server\\share"), "")
  check("sameVolume", sameVolume("D:/a", "d:/b/c"))
  check("not sameVolume", not sameVolume("C:/a", "D:/a"))
  check("isUnder", isUnder("C:/a/b", "C:/a"))
  check("isUnder self", isUnder("C:/a", "C:/a"))
  # The prefix trap: "C:\Tarkov2" starts with "C:\Tarkov" as a string but is
  # not inside it. Getting this wrong would let the installer refuse a valid
  # target, or worse, accept one it should refuse.
  check("isUnder is not startsWith", not isUnder("C:/Tarkov2", "C:/Tarkov"))

# --------------------------------------------------------------- versions

proc testVersions() =
  echo "\nversions"
  checkEq("parse", $parseVersion("1.1.0.46777"), "1.1.0.46777")
  checkEq("parse trailing junk", $parseVersion("0.16.9.40743-beta"), "0.16.9.40743")
  checkEq("parse empty", $parseVersion(""), "unknown")
  check("unknown is not known", not known(parseVersion("")))
  check("equal", compare(parseVersion("1.1.0"), parseVersion("1.1.0")) == 0)
  # A missing component counts as zero, so these are the same version.
  check("short equals padded",
        compare(parseVersion("1.1"), parseVersion("1.1.0")) == 0)
  check("less", compare(parseVersion("0.16.9"), parseVersion("1.0.0")) < 0)
  check("greater", compare(parseVersion("1.1.0.46777"),
                           parseVersion("1.1.0.46776")) > 0)
  # Numeric, not lexicographic: "9" < "16" as numbers, the other way as text.
  check("numeric not lexicographic",
        compare(parseVersion("0.9.0"), parseVersion("0.16.0")) < 0)
  check("post 1.0", isPostOneZero(parseVersion("1.0.0")))
  check("pre 1.0", not isPostOneZero(parseVersion("0.16.9.40743")))
  check("unknown is not post 1.0", not isPostOneZero(parseVersion("")))

proc testScalar() =
  echo "\nscalar extraction"
  let doc = "{\"Version\":\"1.1.0.1.46777\",\"Entries\":[{\"Path\":\"x\"}]}"
  checkEq("string value", scalarAfterKey(doc, "Version"), "1.1.0.1.46777")
  checkEq("missing key", scalarAfterKey(doc, "Nope"), "")
  let cfg = "{\n  \"projectName\": \"SPT\",\n  \"port\": 6969\n}"
  checkEq("spaced value", scalarAfterKey(cfg, "projectName"), "SPT")
  checkEq("numeric value", scalarAfterKey(cfg, "port"), "6969")

# --------------------------------------------------------------- compat

proc testCompat() =
  echo "\nthe refusal matrix"

  # The rule the whole program is built around.
  block:
    let v = evaluate(anInstall("1.1.0.46777", bkIl2Cpp, flVanilla),
                     aPayload("0.16.9.40743", bkMono, plFull), false)
    check("pre-1.0 payload onto post-1.0 client is refused", not v.allowed)
    check("...and is not forcible", not v.forcible)
    check("...at refusal severity", worstOf(v) == sevRefuse)

  block:
    let v = evaluate(anInstall("1.1.0.46777", bkIl2Cpp, flVanilla),
                     aPayload("0.16.9.40743", bkMono, plFull), true)
    check("--force does not unlock the 1.0 boundary", not v.allowed)

  # Same-major mismatches are the ones a person may reasonably overrule.
  block:
    let v = evaluate(anInstall("1.1.0.46777", bkIl2Cpp, flVanilla),
                     aPayload("1.1.0.46776", bkIl2Cpp, plFull), false)
    check("older same-major payload blocks", not v.allowed)
    check("...but is forcible", v.forcible)
  block:
    let v = evaluate(anInstall("1.1.0.46777", bkIl2Cpp, flVanilla),
                     aPayload("1.1.0.46776", bkIl2Cpp, plFull), true)
    check("...and --force unlocks it", v.allowed)

  block:
    let v = evaluate(anInstall("1.1.0.46777", bkIl2Cpp, flVanilla),
                     aPayload("1.2.0.50000", bkIl2Cpp, plFull), false)
    check("payload newer than client blocks", not v.allowed)

  # No flag can make a Mono plugin load into an IL2CPP process.
  block:
    let v = evaluate(anInstall("1.1.0.46777", bkIl2Cpp, flVanilla),
                     aPayload("1.1.0.46777", bkMono, plFull), true)
    check("backend mismatch is refused even with --force", not v.allowed)
    check("...and is not forcible", not v.forcible)

  block:
    let v = evaluate(anInstall("1.1.0.46777", bkIl2Cpp, flVanilla),
                     aPayload("1.1.0.46777", bkIl2Cpp, plFull), false)
    check("matching payload is allowed", v.allowed)

  # An SPT source is a bad base for a full install and a fine base for an
  # overlay; the difference is whether a client is being copied.
  block:
    let v = evaluate(anInstall("1.1.0.46777", bkIl2Cpp, flSpt),
                     aPayload("1.1.0.46777", bkIl2Cpp, plFull), false)
    check("full install from an SPT source blocks", not v.allowed)
  block:
    let v = evaluate(anInstall("1.1.0.46777", bkIl2Cpp, flSpt),
                     aPayload("1.1.0.46777", bkIl2Cpp, plModsOnly), false, false)
    check("overlay onto an SPT install is allowed", v.allowed)

  block:
    var bad = aPayload("1.1.0.46777", bkIl2Cpp, plFull)
    bad.valid = false
    bad.problems = @["no payload.json"]
    let v = evaluate(anInstall("1.1.0.46777", bkIl2Cpp, flVanilla), bad, true)
    check("an invalid payload is refused", not v.allowed)

  block:
    var unknownVersion = anInstall("", bkIl2Cpp, flVanilla)
    let v = evaluate(unknownVersion, aPayload("1.1.0.46777", bkIl2Cpp, plFull),
                     true)
    check("a client with no readable version is refused", not v.allowed)

  block:
    let v = evaluate(anInstall("1.1.0.46777", bkUnknown, flVanilla),
                     aPayload("1.1.0.46777", bkIl2Cpp, plFull), true)
    check("an unrecognised client layout is refused", not v.allowed)

# --------------------------------------------------------------- filesystem

proc testFilesystem() =
  echo "\nfilesystem"
  let root = joinPath(tempRoot(), "fs")
  discard winfs.removeTree(root)

  let deep = joinPath(root, "a\\b\\c\\d")
  check("ensureDir creates a chain", ensureDir(deep).ok)
  check("...and it is a directory", isDirectory(deep))

  let f1 = joinPath(deep, "one.txt")
  check("writeTextFile", writeTextFile(f1, "hello").ok)
  var back = ""
  check("readTextFile", readTextFile(f1, back))
  checkEq("round trip", back, "hello")
  check("fileSizeOf", fileSizeOf(f1) == 5'i64)

  let f2 = joinPath(root, "copy\\two.txt")
  check("copyFileAt creates parents", copyFileAt(f1, f2).ok)
  check("...and the copy exists", fileExists(f2))

  let f3 = joinPath(root, "link\\three.txt")
  let linked = hardLinkAt(f1, f3)
  check("hardLinkAt", linked.ok)
  if linked.ok:
    # A hard link is the same file, which is exactly why the installer never
    # writes through one.
    check("...and the link has the same size", fileSizeOf(f3) == 5'i64)

  # Overwriting must replace rather than write through, or a mirrored install
  # would corrupt the install it was mirrored from.
  check("overwrite a link", writeTextFile(f3, "different").ok)
  var original = ""
  discard readTextFile(f1, original)
  checkEq("the original is untouched", original, "hello")

  var files: seq[string] = @[]
  var dirs: seq[string] = @[]
  collectEntries(root, files, dirs)
  check("collectEntries finds every file", files.len == 3)
  check("collectEntries finds every directory", dirs.len == 6)

  var relOk = true
  for f in files:
    if f.len > 1 and f[1] == ':':
      relOk = false
  check("collectEntries yields relative paths", relOk)

  check("removeTree removes a populated tree", winfs.removeTree(root).ok)
  check("...and it is gone", not exists(root))
  check("removeTree on a missing path is not an error",
        winfs.removeTree(root).ok)

# --------------------------------------------------------------- journal

proc testJournal() =
  echo "\njournal"
  let root = joinPath(tempRoot(), "journal")
  discard winfs.removeTree(root)
  discard ensureDir(root)

  var j = newJournal(root, "D:\\Games\\Tarkov", "D:\\payload", "1.1.0.46777",
                     "0.1.0", "", "full")
  j.paths.add joinPath(root, "aowlspt")
  j.paths.add joinPath(root, "BepInEx")
  check("save", journal.save(j).ok)
  check("hasJournal", hasJournal(root))

  let back = journal.load(root)
  checkEq("source survives", back.source, "D:\\Games\\Tarkov")
  checkEq("payload survives", back.payload, "D:\\payload")
  checkEq("version survives", back.tarkovVersion, "1.1.0.46777")
  # The aowlspt release, not the client's version. These are two different
  # numbers on the same line of the report and swapping them would be invisible
  # in any test that only looked at one, so both are asserted here.
  checkEq("the release survives", back.payloadVersion, "0.1.0")
  checkEq("mode survives", back.mode, "full")
  check("paths survive", back.paths.len == 2)
  checkEq("first path survives", back.paths[0], joinPath(root, "aowlspt"))

  let missing = journal.load(joinPath(tempRoot(), "nothing-here"))
  check("a missing journal loads as empty", missing.paths.len == 0)

  # An install made before the release number was recorded. The field is
  # absent, not wrong, and `aowlspt-verify` says so as a warning rather than a
  # failure -- so the loader has to distinguish "no line" from "empty line" and
  # not invent a version for it.
  var old = newJournal(root, "D:\\Games\\Tarkov", "D:\\payload",
                       "1.1.0.46777", "", "", "full")
  old.paths.add joinPath(root, "aowlspt")
  check("a journal with no release saves", journal.save(old).ok)
  let readBack = journal.load(root)
  checkEq("and comes back with none rather than a guess",
          readBack.payloadVersion, "")
  checkEq("while the rest of it is intact", readBack.tarkovVersion,
          "1.1.0.46777")

  discard winfs.removeTree(root)

# --------------------------------------------------------------- plan

proc testPlan() =
  echo "\nplan and apply"
  let root = joinPath(tempRoot(), "plan")
  discard winfs.removeTree(root)

  let src = joinPath(root, "src")
  let dst = joinPath(root, "dst")
  discard ensureDir(joinPath(src, "keep\\inner"))
  discard ensureDir(joinPath(src, "BattlEye"))
  discard writeTextFile(joinPath(src, "root.txt"), "r")
  discard writeTextFile(joinPath(src, "keep\\inner\\deep.txt"), "d")
  discard writeTextFile(joinPath(src, "BattlEye\\be.dll"), "b")

  var p = newPlan(dst, true)
  mirrorTree(p, src, dst, "the client", @["BattlEye"], @["root.txt"])
  writeFile(p, joinPath(dst, "aowlspt\\backend.json"), "{}", "config")

  setDryRun true
  let dryStats = apply(p, true)
  check("a dry run writes nothing", not exists(dst))
  check("...and reports nothing done",
        dryStats.filesCopied + dryStats.filesLinked + dryStats.filesWritten == 0)
  setDryRun false

  let stats = apply(p, true)
  check("apply has no failures", stats.failures == 0)
  check("the excluded tree is absent", not exists(joinPath(dst, "BattlEye")))
  check("an included file is present", exists(joinPath(dst, "root.txt")))
  check("a deep included file is present",
        exists(joinPath(dst, "keep\\inner\\deep.txt")))
  check("the written file is present",
        exists(joinPath(dst, "aowlspt\\backend.json")))
  check("two files were reproduced",
        stats.filesLinked + stats.filesCopied == 2)
  # The property the "hot file" list exists for. `root.txt` was named hot, so
  # it must be a copy: something writing through it in the target must not
  # reach the source. This is checked by doing exactly that, because the only
  # convincing test of "is this a separate file" is to write to one of them.
  check("a hot file was copied, not linked",
        writeTextFile(joinPath(dst, "root.txt"), "clobbered").ok)
  var srcRoot = ""
  discard readTextFile(joinPath(src, "root.txt"), srcRoot)
  checkEq("...so the source is untouched", srcRoot, "r")

  # And the converse: a linked file is the same bytes, which is exactly why
  # the hot list has to exist.
  var srcDeep = ""
  discard readTextFile(joinPath(src, "keep\\inner\\deep.txt"), srcDeep)
  checkEq("a linked file still reads correctly", srcDeep, "d")

  # A whole-target plan claims the target and nothing narrower, so that
  # uninstall removes an install rather than picking at it.
  check("a whole-target plan records just the target", stats.created.len == 1)
  checkEq("...and it is the target", stats.created[0], absolutePathOf(dst))

  # An overlay plan records the entries it added, so uninstall leaves the
  # client alone.
  var q = newPlan(dst, false)
  copyTree(q, joinPath(src, "keep"), joinPath(dst, "aowlspt"), "mods")
  let overlayStats = apply(q, false)
  check("an overlay plan has no failures", overlayStats.failures == 0)
  var recordedTarget = false
  for c in overlayStats.created:
    if c == absolutePathOf(dst):
      recordedTarget = true
  check("an overlay plan does not claim the target", not recordedTarget)

  discard winfs.removeTree(root)

# --------------------------------------------------------------- payload

proc testPayload() =
  echo "\npayload"
  let root = joinPath(tempRoot(), "payload")
  discard winfs.removeTree(root)

  let missing = payload.load(joinPath(root, "nope"))
  check("a missing payload is invalid", not missing.valid)

  discard ensureDir(joinPath(root, "good\\aowlspt"))
  discard writeTextFile(joinPath(root, "good\\payload.json"),
    "{\n  \"name\": \"t\",\n  \"targetTarkovVersion\": \"1.1.0.46777\",\n" &
    "  \"targetBackend\": \"il2cpp\",\n  \"backendUrl\": \"https://x\"\n}\n")
  discard writeTextFile(joinPath(root, "good\\aowlspt\\m.dll"), "x")
  let good = payload.load(joinPath(root, "good"))
  check("a well-formed payload is valid", good.valid)
  check("...is recognised as mods-only", good.kind == plModsOnly)
  check("...has its version", $good.targetTarkov == "1.1.0.46777")
  check("...has its backend", good.targetBackend == bkIl2Cpp)
  checkEq("...has its backend url", good.backendUrl, "https://x")

  # A payload that does not say what it was built for cannot be checked, and an
  # unchecked install is the failure this program exists to prevent.
  discard ensureDir(joinPath(root, "vague\\aowlspt"))
  discard writeTextFile(joinPath(root, "vague\\payload.json"),
                        "{\n  \"name\": \"t\"\n}\n")
  let vague = payload.load(joinPath(root, "vague"))
  check("a payload with no target version is invalid", not vague.valid)

  # The break the `kind` key exists to close. A post-1.0 payload has no
  # `runtime/` and no `client/` -- the host is injected at start-up and the
  # server is a mod -- so the old inference read it as an overlay, and an
  # overlay never mirrors the client. `install --source <vanilla> --target
  # <new>` then produced a target holding `aowlspt/` and no game at all, and
  # reported success.
  check("a mods-only payload is an overlay unless it says otherwise",
        good.kind == plModsOnly)
  discard ensureDir(joinPath(root, "post10\\aowlspt"))
  discard writeTextFile(joinPath(root, "post10\\aowlspt\\m.dll"), "x")
  discard writeTextFile(joinPath(root, "post10\\payload.json"),
    "{\n  \"name\": \"t\",\n  \"targetTarkovVersion\": \"1.1.0.46777\",\n" &
    "  \"targetBackend\": \"il2cpp\",\n  \"kind\": \"full\"\n}\n")
  let post10 = payload.load(joinPath(root, "post10"))
  check("...and is a full install when it does", post10.kind == plFull)
  check("...which is still a valid payload", post10.valid)

  discard ensureDir(joinPath(root, "badkind\\aowlspt"))
  discard writeTextFile(joinPath(root, "badkind\\aowlspt\\m.dll"), "x")
  discard writeTextFile(joinPath(root, "badkind\\payload.json"),
    "{\n  \"name\": \"t\",\n  \"targetTarkovVersion\": \"1.1.0.46777\",\n" &
    "  \"targetBackend\": \"il2cpp\",\n  \"kind\": \"sideways\"\n}\n")
  let badkind = payload.load(joinPath(root, "badkind"))
  check("a payload declaring a kind nobody knows is invalid", not badkind.valid)

  discard ensureDir(joinPath(root, "empty"))
  discard writeTextFile(joinPath(root, "empty\\payload.json"),
    "{\n  \"name\": \"t\",\n  \"targetTarkovVersion\": \"1.1.0\",\n" &
    "  \"targetBackend\": \"mono\"\n}\n")
  let empty = payload.load(joinPath(root, "empty"))
  check("a payload with nothing in it is invalid", not empty.valid)

  discard winfs.removeTree(root)


# --------------------------------------------------------------- registry

proc testRegistry() =
  echo "\nregistry and the default selection"

  # The shipped manager config, near enough. The documentation key sits
  # immediately above the real one and contains the same word: patching that
  # one instead would turn a doc string into a JSON array, leave `activeLists`
  # untouched, and produce a config that reads as configured and is not.
  let cfg = "{\n" &
            "  \"//activeLists\": \"The lists active on a fresh install.\",\n" &
            "  \"activeLists\": [\"aowl.list.core\"],\n" &
            "  \"controlProbeMs\": 750\n}\n"
  let patched = patchActiveLists(cfg, "aowl.list.raidnight")
  check("the active list is replaced",
        find(patched, "\"activeLists\": [\"aowl.list.raidnight\"]") >= 0)
  check("...and the documentation key above it is not",
        find(patched, "\"//activeLists\": \"The lists active on a fresh install.\"") >= 0)
  check("...and the settings after it survive",
        find(patched, "\"controlProbeMs\": 750") >= 0)
  checkEq("the value can be read back", activeListsOf(patched),
          "[\"aowl.list.raidnight\"]")

  # A config without the key in the shape expected is left alone rather than
  # having a second `activeLists` appended: two keys of the same name resolve to
  # whichever one the parser reaches last, which is a config that behaves
  # differently from how it reads.
  checkEq("a config with no activeLists is not patched",
          patchActiveLists("{\n  \"controlProbeMs\": 750\n}\n", "x"), "")
  checkEq("a config whose activeLists is not an array is not patched",
          patchActiveLists("{\"activeLists\": \"core\"}", "x"), "")

  let reg = "{\"schema\":\"aowlspt.registry/1\"," &
            "\"mods\":[{\"id\":\"a\",\"requires\":[{\"id\":\"b\"}]," &
            "\"artifact\":{\"dir\":\"a\"}}," &
            "{\"id\":\"b\",\"artifact\":{\"dir\":\"b\"}}]," &
            "\"lists\":[{\"id\":\"aowl.list.core\",\"entries\":[{\"id\":\"a\"}]}]}"
  checkEq("the schema is read", schemaOf(reg), "aowlspt.registry/1")
  # Counted off `artifact` and `entries` rather than off `id`: this document has
  # five `"id"` keys, two mods and one list.
  var counted = ""
  let described = describeRegistry(reg)
  for l in described:
    if l.startsWith("contains"):
      counted = l
  checkEq("mods and lists are counted, not ids", counted,
          "contains  2 mods, 1 lists")
  check("a list that is there is found", hasList(reg, "aowl.list.core"))
  check("a list that is not is not", not hasList(reg, "aowl.list.nope"))

  let root = joinPath(tempRoot(), "registry")
  discard winfs.removeTree(root)
  discard ensureDir(root)
  checkEq("a payload with no registry has none", registryIn(root), "")
  discard writeTextFile(joinPath(root, "registry\\mods.json"), reg)
  checkEq("the top-level one is found", registryIn(root),
          joinPath(root, "registry\\mods.json"))
  discard writeTextFile(joinPath(root, "aowlspt\\registry\\mods.json"), reg)
  checkEq("the one inside aowlspt/ wins", registryIn(root),
          joinPath(root, "aowlspt\\registry\\mods.json"))
  checkEq("--registry naming a directory finds mods.json in it",
          resolveRegistry(root, joinPath(root, "registry")),
          joinPath(root, "registry\\mods.json"))
  checkEq("--registry naming the file uses it",
          resolveRegistry(root, joinPath(root, "registry\\mods.json")),
          joinPath(root, "registry\\mods.json"))
  # An explicit path that is not there must not fall back to the payload's.
  # Installing a registry other than the one that was asked for is how somebody
  # spends an evening debugging a mod list they are not running.
  checkEq("--registry naming nothing does not fall back",
          resolveRegistry(root, joinPath(root, "nope")), "")

  discard winfs.removeTree(root)

# --------------------------------------------------------------- live

proc testLive() =
  echo "\nthis machine (read only)"
  let roots = discover()
  if roots.len == 0:
    echo "      no Tarkov install found; skipping"
    return
  for r in roots:
    let i = identify(r)
    check("identified " & r, i.exists)
    check("  version is readable", known(i.version))
    check("  backend is recognised", i.backend != bkUnknown)
    if i.backend == bkIl2Cpp:
      check("  IL2CPP implies post-1.0 in practice", isPostOneZero(i.version))

proc main() =
  setVerbosity vQuiet
  testPaths()
  testVersions()
  testScalar()
  testCompat()
  testFilesystem()
  testJournal()
  testPlan()
  testPayload()
  testRegistry()
  testLive()

  echo ""
  echo $passed & " passed, " & $failed & " failed"
  if failed > 0:
    quit(1)

main()
