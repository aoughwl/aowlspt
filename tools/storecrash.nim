## storecrash -- kill a process in the middle of a store write and see what is
## left on disk.
##
##     storecrash --root <scratch> [--rounds 60] [--verbose]
##
## It spawns its children without consoles, writes nothing outside `--root`,
## and removes that directory again unless something failed -- a failed run
## keeps its evidence and says where it is.
##
## The store holds the only thing in this project that cannot be rebuilt: a
## player's profile. Every other file is generated, downloaded or compiled. So
## the claim "a write is atomic" is worth exactly as much as the test behind
## it, and a test that mocks the crash proves nothing about the window it
## claims to cover -- the whole question is whether the process can die *inside*
## the write.
##
## So it dies inside the write. A child process writes values into the store in
## a tight loop; the parent lets it run for a jittered interval and calls
## `TerminateProcess` on it (`aowl_spawn_kill`, the same one `emutest` uses).
## Then the parent -- a different process, with no handles and no memory of what
## the child was doing -- reads the store back and demands the file be one whole
## value: the old one or the new one, byte for byte, never a mixture.
##
## ## Establishing that the window is actually hit
##
## A run of forty kills that never lands in a write would pass and would mean
## nothing, so the run measures its own coverage two ways and asserts on the
## direct one.
##
##   * **Directly.** A commit writes a temporary and renames it over the key,
##     so the rename is what removes the temporary. A temporary still sitting
##     there after the kill is proof that this kill happened inside a write.
##     That count is asserted: a run where no kill reached the window fails.
##   * **Against the old code.** `--child-unsafe` writes the way the store used
##     to -- in place through a held handle, then truncate -- and the parent
##     counts how many of the same kills left a torn file. It is reported
##     rather than asserted, because `TerminateProcess` cannot interrupt a
##     single `WriteFile` (the thread finishes the system call before it dies),
##     so the old code's *visible* window under a process kill was only the gap
##     between writing the bytes and truncating to them: a few per cent of
##     kills, which is real but too small to gate on. The larger exposure that
##     shape had -- a power cut, a full disk, a partial write -- is not
##     reachable from a test that kills a process.
##
## Two phases run: the old in-place write, and the store as it is. The store
## commits every write before `storeWrite` returns, so there is no third state
## to test -- nothing is ever waiting in memory for a later moment.
##
## The commit it tests is the one the store does: a temporary file, written and
## renamed over the key.
##
## Values are self-describing: each carries its own index at the front and at
## the back and a body of a repeated character chosen by that index, at one of
## two sizes -- four kilobytes and eighty-four, which is where a real profile
## starts and where two hundred raids leave it. Any mixture of two of them
## fails the comparison, including one whose length happens to match.

import std/[strutils, syncio, cmdline]
import aowlsptinstall/[winfs, log]
import modstore

{.emit: """#include <stdlib.h>""".}
{.emit: """#include <string.h>""".}
{.emit: """#include "aowlspt_shim.h" """.}
{.emit: """#include "aowlspt_inject.h" """.}

{.emit: """
/* QPC, as everywhere else here: the cheapest of the write shapes below is
 * twenty microseconds and a millisecond clock reports that as zero. */
static int64_t aowl_crash_qpc_us(void) {
  LARGE_INTEGER v, f;
  QueryPerformanceCounter(&v);
  QueryPerformanceFrequency(&f);
  return (int64_t)((v.QuadPart / f.QuadPart) * 1000000LL +
                   ((v.QuadPart % f.QuadPart) * 1000000LL) / f.QuadPart);
}
""".}

proc cNowUs(): int64 {.importc: "aowl_crash_qpc_us", nodecl.}

proc cSpawn(exe, workDir, cmdLine: cstring): uint64 {.
  importc: "aowl_spawn_quiet", nodecl.}
proc cSpawnKill(h: uint64) {.importc: "aowl_spawn_kill", nodecl.}
proc cSleepMs(ms: int32) {.importc: "aowl_sys_sleep", nodecl.}

const
  Usage = """
storecrash -- kill a process mid-write and check the store survived

  storecrash --root PATH [--rounds N]

  --root PATH      a scratch directory. Created, used, and removed again
                   unless something failed -- a failed run keeps its evidence
                   and says where it is.
  --rounds N       kills per phase (default 12; 60 is what a coverage claim
                   wants, and takes about a minute)
  --verbose        every check, rather than a line per phase
  --unsafe-only    only the control run (the old in-place write)
  --safe-only      only the real run
  --bench          what each write shape costs, and nothing else
  -h, --help       this

  internal: --child, --child-unsafe, --lockchild
"""
  Guid = "aowl.storecrash"
  Key = "profile.crashtest"
  ValueCount = 4
    ## Distinct values the child cycles through.

type
  HeldFile = object
    ## One open file, and the reason this is a type rather than a bare
    ## `Handle`: a `Handle` only used as a local does not pull `WinDef.h` into
    ## this translation unit, and the extern declarations that name it then
    ## have no type to refer to. A field of a declared type does.
    h*: Handle

var gFailures = 0
var gChecks = 0
var gVerbose = false

proc check(what: string; condition: bool; detail = "") =
  ## Quiet when it passes. This runs in `aowl test` on a machine somebody is
  ## using for something else, and thirty lines of `ok` is thirty lines nobody
  ## reads; a failure still says everything it knows.
  inc gChecks
  if condition:
    if gVerbose:
      ok what
  else:
    err what & (if detail.len > 0: ": " & detail else: "")
    inc gFailures

proc note(text: string) =
  if gVerbose:
    line text

# --------------------------------------------------------------- values

proc valueFor(n: int): string =
  ## Self-describing, and a different length either side of every write, so a
  ## write that stopped halfway cannot look like a whole one.
  let fill = char(ord('A') + (n mod 26))
  let size = if (n mod 2) == 0: 4096 else: 84000
  result = "{\"n\":" & $n & ",\"pad\":\""
  for i in 0 ..< size:
    result.add fill
  result.add "\",\"end\":" & $n & "}"

proc indexIn(text: string): int =
  ## The `n` a value claims to be, or -1.
  const Head = "{\"n\":"
  if text.len < Head.len + 1:
    return -1
  if text.substr(0, Head.len - 1) != Head:
    return -1
  var i = Head.len
  var v = 0
  var any = false
  while i < text.len and text[i] >= '0' and text[i] <= '9':
    v = v * 10 + (ord(text[i]) - ord('0'))
    any = true
    inc i
  if not any:
    return -1
  result = v

proc whole(text: string): bool =
  ## Whether `text` is exactly some `valueFor(n)`. Byte for byte: a torn write
  ## that leaves a plausible prefix and the tail of the value before it is the
  ## failure this whole tool exists to catch, and it is only visible in the
  ## bytes.
  let n = indexIn(text)
  if n < 0:
    return false
  result = text == valueFor(n)

# --------------------------------------------------------------- the child

proc childLoop(root: string; unsafe: bool): int =
  ## Writes for as long as it is allowed to live. There is no exit path: the
  ## parent's `TerminateProcess` is the exit path, which is the point.
  storeInit(root)
  let path = joinPath(joinPath(storeRoot(), Guid), Key)
  discard ensureDir(parentOf(path))
  var held = HeldFile(h: Handle(0))
  if unsafe:
    # The store as it was: one handle kept open, overwritten from byte zero,
    # truncated to the new length. Reproduced here rather than kept in the
    # store behind a flag, so the unsafe path exists only inside the test that
    # measures it.
    held = HeldFile(h: openHeld(path, true))
    if not heldValid(held.h):
      return 1
  # Four values, built once and cycled. Building an eighty-four kilobyte
  # string costs more than writing it, and a loop that spends most of its time
  # in the generator is a loop the kill mostly lands *outside* -- which would
  # understate the control's tear rate and with it the coverage the safe run
  # can claim. Four is enough that no two consecutive writes share a length or
  # a fill character.
  var values: seq[string] = @[]
  for k in 0 ..< ValueCount:
    values.add valueFor(k)
  var n = 0
  while true:
    if unsafe:
      if not heldWrite(held.h, values[n]):
        return 1
    else:
      var error = ""
      if not storeWrite(Guid, Key, values[n], error):
        # A failed write is written down where the parent will find it. It
        # matters more than it looks: a child that dies on its second write
        # leaves a store holding one whole value, and every wholeness check
        # afterwards passes against a file nothing is writing any more. That is
        # how a test stays green through a bug that broke every second write.
        discard writeTextFile(joinPath(root, "childerror.txt"), error)
        return 1
    n = (n + 1) mod ValueCount
  result = 0

# --------------------------------------------------------------- the parent

var gSeed = 0'i64

proc jitterMs(): int32 =
  ## A spread of kill points. The child's loop is far shorter than a
  ## millisecond, so what this varies is not *where* in one write the kill
  ## lands -- nothing at this resolution could -- but that the run is not
  ## sampling one phase of some accidental rhythm between the writer and the
  ## filesystem.
  gSeed = gSeed * 6364136223846793005'i64 + 1442695040888963407'i64
  let r = int((gSeed shr 33) and 0x7FFFFFFF'i64)
  result = int32(120 + (r mod 400))

proc storeFile(root: string): string =
  result = joinPath(joinPath(joinPath(root, "store"), Guid), Key)

proc readRaw(path: string; into: var string): bool =
  ## Read whatever is there, sharing with anything -- the point is to look at
  ## the bytes a crashed writer left, not to take the file away from anyone.
  result = readShared(path, into)

var gInside = 0
  ## Kills that demonstrably landed between the start of a store write and its
  ## commit. See `runMode`.
var gSeen: seq[int] = @[]
  ## Which values were found on disk across a run. More than one of them is the
  ## evidence that writes after the first are reaching the disk at all.

const
  ModeThrough = 0   ## the store as it is: every write commits before it returns
  ModeUnsafe = 1    ## the in-place write the store used to do

proc runMode(exe, root: string; rounds: int; mode: int): int =
  ## Returns how many of `rounds` kills left a torn file.
  gInside = 0
  gSeen = @[]
  let unsafe = mode == ModeUnsafe
  var arg = "--child"
  if unsafe:
    arg = "--child-unsafe"
  discard removeFileAt(joinPath(root, "childerror.txt"))
  var torn = 0
  var i = 0
  while i < rounds:
    var e = exe
    var w = root
    var c = "\"" & exe & "\" " & arg & " --root \"" & root & "\""
    let h = cSpawn(toCString(e), toCString(w), toCString(c))
    if h == 0'u64:
      err "could not start the child"
      inc gFailures
      return torn
    cSleepMs(jitterMs())
    cSpawnKill(h)
    # The kernel has closed the child's handles by the time `TerminateProcess`
    # returns to a parent that then opens the file, but the store's own
    # directory entry may still be settling behind a rename that was in
    # flight. A short pause here is not part of the guarantee being tested --
    # it is there so the parent is not the one racing.
    cSleepMs(30'i32)

    # Where the kill landed, measured rather than assumed.
    #
    # The safe write opens a temporary, fills it, and renames it over the key.
    # The rename is what removes the temporary, so a temporary still sitting
    # there is proof that this kill happened *inside* a write -- after it
    # began and before it committed. That is the window the whole guarantee is
    # about, and it is the number that makes "no torn values" mean something:
    # without it a clean run could just as well be forty kills that all landed
    # between writes.
    if not unsafe:
      let hist = joinPath(joinPath(joinPath(root, "store"), Guid), ".hist")
      if exists(joinPath(hist, Key & ".tmp")):
        inc gInside

    var text = ""
    let path = storeFile(root)
    if not readRaw(path, text):
      # Nothing at all is only allowed before the child's first write ever
      # completed, and after round one there has always been one.
      if i > 0:
        err "round " & $(i + 1) & ": the store file could not be read at all"
        inc gFailures
      inc i
      continue
    if not whole(text):
      inc torn
      if not unsafe:
        var head = text.substr(0, 40)
        err "round " & $(i + 1) & ": torn value, " & $text.len &
            " bytes, starts " & head
        inc gFailures
    else:
      let n = indexIn(text)
      var known = false
      for s in gSeen:
        if s == n: known = true
      if not known:
        gSeen.add n
    inc i

  # A child that could not write said so. Without this the run is a check on a
  # file nothing has written since round one, which passes for all the wrong
  # reasons.
  var childError = ""
  if readRaw(joinPath(root, "childerror.txt"), childError):
    err "a write failed in the child: " & strip(childError)
    inc gFailures
  result = torn

proc checkHistory(root: string) =
  ## Every generation the ring kept must itself be a whole value: a history
  ## that can be torn is a history nobody can use at the moment they need it.
  let hist = joinPath(joinPath(joinPath(root, "store"), Guid), ".hist")
  if not isDirectory(hist):
    check "the history directory exists", false, hist
    return
  var files: seq[string] = @[]
  var dirs: seq[string] = @[]
  collectEntries(hist, files, dirs)
  var generations = 0
  var bad = 0
  for f in files:
    let name = baseName(f)
    if name.endsWith(".tmp") or name.endsWith(".tmpgen"):
      continue
    var text = ""
    if not readRaw(joinPath(hist, f), text):
      inc bad
      continue
    if not whole(text):
      inc bad
    else:
      inc generations
  check "the store kept previous generations", generations > 0,
        $generations & " under " & hist
  check "every generation is a whole value", bad == 0, $bad & " were not"

proc checkNotListed(root: string) =
  ## And the history must not look like data. `savedKeys` walks the mod's
  ## directory, and a generation reported as a key is a profile id the
  ## emulator would try to load.
  storeInit(root)
  let keys = storeKeys(Guid, "")
  storeClose()
  check "the history is not reported as keys",
        keys == "[\"" & Key & "\"]", keys

proc checkLock(exe, root: string) =
  ## Two backends on one store. The claim is taken here, in the parent, and a
  ## child is asked to take the same one.
  storeInit(root)
  var holder = ""
  var error = ""
  if not storeLock("crashtest", holder, error):
    check "the parent could claim the store", false, error
    return
  let marker = joinPath(root, "lockresult.txt")
  discard removeFileAt(marker)
  var e = exe
  var w = root
  var c = "\"" & exe & "\" --lockchild --root \"" & root & "\""
  let h = cSpawn(toCString(e), toCString(w), toCString(c))
  if h == 0'u64:
    check "the lock child started", false
    storeUnlock()
    return
  var waited = 0
  while waited < 5000 and not fileExists(marker):
    cSleepMs(50'i32)
    waited = waited + 50
  var text = ""
  discard readRaw(marker, text)
  check "a second host is refused the store", strip(text) == "refused",
        "the child said " & strip(text)
  cSpawnKill(h)
  storeUnlock()

  # And once the holder is gone the store is free again -- no file to delete,
  # no pid to reap.
  storeInit(root)
  var holder2 = ""
  var error2 = ""
  let regained = storeLock("crashtest", holder2, error2)
  check "the claim is released when the holder ends", regained, error2
  storeUnlock()

proc lockChild(root: string): int =
  storeInit(root)
  var holder = ""
  var error = ""
  let got = storeLock("crashtest", holder, error)
  let marker = joinPath(root, "lockresult.txt")
  if got:
    discard writeTextFile(marker, "taken")
    storeUnlock()
  else:
    discard writeTextFile(marker, "refused")
  result = 0

proc benchWrites(root: string; iterations: int) =
  ## What each write shape costs, on the document size the emulator actually
  ## has. Measured rather than asserted, and printed as one table so the number
  ## that made the case for the design can be re-checked against the design.
  storeInit(root)
  discard removeTree(storeRoot())
  let v = valueFor(1)                     # the 84 KB one
  let dir = joinPath(storeRoot(), Guid)
  discard ensureDir(dir)
  heading "What a write costs"
  line "  value  " & $v.len & " bytes, " & $iterations & " writes each"

  # In place, through a held handle: what the store did before, and what is not
  # a commit. The floor for everything below.
  let inPlace = joinPath(dir, "bench.inplace")
  var held = HeldFile(h: openHeld(inPlace, true))
  var t0 = cNowUs()
  for i in 0 ..< iterations:
    discard heldWrite(held.h, v)
  var us = cNowUs() - t0
  line "  in place, held handle        " & $(us div int64(iterations)) & " us"
  heldClose(held.h)

  # Create, write, rename: the commit when there is no spare ready. Spelled out
  # here rather than driven through the store, because the store only takes
  # this path on the first write of a key and the point is to price it.
  let slowTmp = joinPath(dir, "bench.slowtmp")
  let slowDst = joinPath(dir, "bench.slow")
  t0 = cNowUs()
  for i in 0 ..< iterations:
    let h2 = openHeld(slowTmp, true)
    discard heldWrite(h2, v)
    heldClose(h2)
    discard replaceFileAt(slowTmp, slowDst)
  us = cNowUs() - t0
  line "  create + write + rename      " & $(us div int64(iterations)) & " us"

  # The rename on its own, with no file creation anywhere near it: two names,
  # swapped back and forth. This is the part of a commit that cannot be
  # removed, and the reason a spare is worth keeping.
  let ping = joinPath(dir, "bench.ping")
  let pong = joinPath(dir, "bench.pong")
  discard writeTextFile(ping, v)
  discard removeFileAt(pong)
  t0 = cNowUs()
  for i in 0 ..< iterations:
    discard replaceFileAt(ping, pong)
    discard replaceFileAt(pong, ping)
  us = cNowUs() - t0
  line "    of which the rename alone  " & $(us div int64(iterations * 2)) &
       " us"

  # And the store as it is, driven through `storeWrite`. This is what a request
  # pays, and it should track the create-write-rename line above it.
  storeFlushOnWrite(false)
  var error = ""
  discard storeWrite(Guid, "bench.store", v, error)
  t0 = cNowUs()
  for i in 0 ..< iterations:
    discard storeWrite(Guid, "bench.store", v, error)
  us = cNowUs() - t0
  line "  a commit (what a request pays)  " & $(us div int64(iterations)) &
       " us"

  # With the flush, which is what `--store-flush` turns on.
  storeFlushOnWrite(true)
  t0 = cNowUs()
  for i in 0 ..< iterations:
    discard storeWrite(Guid, "bench.store", v, error)
  us = cNowUs() - t0
  line "  with --store-flush           " & $(us div int64(iterations)) & " us"
  storeFlushOnWrite(false)
  storeClose()

proc main(): int =
  var root = ""
  var rounds = 12
  var child = false
  var childUnsafe = false
  var lockchild = false
  var safeOnly = false
  var unsafeOnly = false
  var bench = false
  var i = 1
  let n = paramCount()
  while i <= n:
    let a = paramStr(i)
    if a == "--root":
      inc i
      if i <= n: root = paramStr(i)
    elif a == "--rounds":
      inc i
      if i <= n:
        var v = 0
        var any = false
        for ch in paramStr(i):
          if ch >= '0' and ch <= '9':
            v = v * 10 + (ord(ch) - ord('0'))
            any = true
        if any: rounds = v
    elif a == "--child":
      child = true
    elif a == "--child-unsafe":
      childUnsafe = true
    elif a == "--lockchild":
      lockchild = true
    elif a == "--safe-only":
      safeOnly = true
    elif a == "--unsafe-only":
      unsafeOnly = true
    elif a == "--bench":
      bench = true
    elif a == "--verbose" or a == "-v":
      gVerbose = true
    elif a == "--help" or a == "-h":
      echo Usage
      return 0
    else:
      echo "unknown option: " & a
      return 1
    inc i

  if root.len == 0:
    echo Usage
    return 1
  root = absolutePathOf(root)

  if child:
    return childLoop(root, false)
  if childUnsafe:
    return childLoop(root, true)
  if lockchild:
    return lockChild(root)

  # One scratch directory, made here and taken away again at the end. It holds
  # the store, the child's error marker and the lock-test marker, and nothing
  # is written anywhere else -- the child processes are given this root and the
  # store is a subdirectory of it.
  discard removeTree(root)
  discard ensureDir(root)
  gSeed = nowMs()
  if bench:
    benchWrites(root, 200)
    discard removeTree(root)
    return 0
  let exe = absolutePathOf(paramStr(0))

  heading "storecrash"

  var hitRate = -1
  if not safeOnly:
    let torn = runMode(exe, root, rounds, ModeUnsafe)
    hitRate = torn
    # Reported, not asserted. `TerminateProcess` cannot interrupt a single
    # `WriteFile` -- the thread finishes the system call before it dies -- so
    # the old code's visible tear window was only the gap between writing the
    # bytes and truncating to them: a few per cent of kills, which is real and
    # too small to gate on. The coverage that *is* asserted is the direct one
    # below.
    line "  in place (the old write): " & $torn & " of " & $rounds &
         " kills left a torn file"

  if not unsafeOnly:
    # A fresh store for the real run: the control deliberately left torn files
    # behind, and a run that started from one would be testing recovery rather
    # than atomicity.
    discard removeTree(joinPath(root, "store"))
    let torn = runMode(exe, root, rounds, ModeThrough)
    check "a killed write leaves a whole value", torn == 0, $torn & " did not"
    check "the kills reach the window", gInside > 0,
          "not one kill landed inside a commit -- this proves nothing"
    # Several writes of the *same* key, which is the case that matters and the
    # one a bug survived: the held handle for a key blocks the rename that
    # replaces it, so the second write of a key failed while the first
    # succeeded. More than one distinct value across the run is the evidence
    # that writes are still reaching the disk after the first.
    check "the same key can be written again and again", gSeen.len > 1,
          "only " & $gSeen.len & " distinct value(s) ever reached the disk"
    checkHistory(root)
    checkNotListed(root)
    checkLock(exe, root)
    line "  the store as it is:       " & $torn & " of " & $rounds &
         " torn, " & $gInside & " kills landed inside a commit"

  if gFailures > 0:
    err $gFailures & " of " & $gChecks & " checks failed; the run is left in " &
        root
    return 1
  if gChecks == 0:
    # `--unsafe-only` runs the control phase, and the control phase asserts
    # nothing on purpose: `TerminateProcess` cannot interrupt a single
    # `WriteFile`, so the old code's visible tear rate is a few per cent and is
    # reported rather than gated on. That means a `--unsafe-only` run makes no
    # checks at all -- and it used to finish by printing "0 checks over 12 kills
    # a phase -- no killed write left a torn value", which is a claim about the
    # store as it is, made by a run that never exercised it. A run that
    # establishes nothing says so.
    warn "this run made no checks. The control phase is measured and " &
         "reported, never asserted, so nothing here says anything about the " &
         "store as it is: run without --unsafe-only for that."
    discard removeTree(root)
    return 0
  ok $gChecks & " checks over " & $rounds &
     " kills a phase -- no killed write left a torn value"
  if rounds < 60:
    line "  (--rounds 60 is what a coverage claim wants; it takes about a" &
         " minute)"
  discard removeTree(root)
  result = 0

quit(main())
