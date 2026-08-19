## storeguard -- what one process sees while another commits to the same key.
##
##     storeguard --root PATH [--seconds 4] [--verbose]
##
## `tools/storecrash` answers "can a process die inside a write and leave a
## mixture". This answers the other half, which nothing was asking: **while a
## writer commits, what does a reader in a different process get?**
##
## It matters because the commit is a rename, and a rename does not change the
## file a handle is already holding -- it gives the *name* to a different file.
## The store keeps handles open (that is most of why a read costs 17 us rather
## than 890), so a reader that opened the key before a writer replaced it holds
## a handle to a file that no longer has a name, and every later read of that
## key answers with a value that was true once and is not any more.
##
## Two phases, and the second exists to prove the first can fail.
##
##   * **committed writes.** A child process writes values through
##     `storeWrite`; this process reads the same key through `storeReadInto`
##     -- the same held-handle path a host uses -- and demands two things of
##     every read: that it is exactly one whole value, and that the sequence
##     of values it sees actually *moves*. A reader that keeps answering `n=2`
##     while the writer is on `n=900` has not torn anything; it has stopped
##     being a reader.
##   * **in-place writes.** The same run against the write the store did
##     before it committed: one handle, overwritten from byte zero and
##     truncated. A held handle follows that file, so this reader sees every
##     write -- and sees them half-done. The torn reads it finds are what says
##     the wholeness check in phase one is a check and not a formality.
##
## And the history: `.hist` must hold at most `BackupGenerations` files for a
## key, every one of them a whole value, and none of them must show up as a
## key.
##
## Values are `storecrash`'s: self-describing, two lengths, a fill character
## that changes with the index, so no mixture of two of them can pass for one.

import std/[strutils, syncio, cmdline]
import aowlsptinstall/[winfs, log]
import modstore

{.emit: """#include <stdlib.h>""".}
{.emit: """#include <string.h>""".}
{.emit: """#include "aowlspt_shim.h" """.}
{.emit: """#include "aowlspt_inject.h" """.}

proc cSpawn(exe, workDir, cmdLine: cstring): uint64 {.
  importc: "aowl_spawn_quiet", nodecl.}
proc cSpawnKill(h: uint64) {.importc: "aowl_spawn_kill", nodecl.}
proc cSleepMs(ms: int32) {.importc: "aowl_sys_sleep", nodecl.}

{.emit: """
static int64_t sg_ms(void) {
  LARGE_INTEGER v, f;
  QueryPerformanceCounter(&v);
  QueryPerformanceFrequency(&f);
  return (int64_t)((v.QuadPart * 1000LL) / f.QuadPart);
}
""".}

proc cMs(): int64 {.importc: "sg_ms", nodecl.}

const
  Usage = """
storeguard -- what a reader in another process sees while a writer commits

  storeguard --root PATH [--seconds N] [--verbose]

  --root PATH      a scratch directory, created and used
  --seconds N      how long each phase reads for (default 4)
  --verbose        every check rather than a line per phase
  -h, --help       this

  internal: --child, --child-unsafe
"""
  Guid = "aowl.storeguard"
  Key = "profile.guardtest"
  ValueCount = 4
  BackupGenerations = 3
    ## What `modstore` promises. Named again here rather than exported,
    ## because a test that reads the constant it is checking checks nothing.

type
  HeldFile = object
    ## A `Handle` that only ever lives in a local does not pull `WinDef.h`
    ## into this translation unit; a field of a declared type does. Same
    ## reason as `tools/storecrash`.
    h*: Handle

var gFailures = 0
var gChecks = 0
var gVerbose = false

proc check(what: string; condition: bool; detail = "") =
  inc gChecks
  if condition:
    if gVerbose: ok what
  else:
    err what & (if detail.len > 0: ": " & detail else: "")
    inc gFailures

proc note(text: string) =
  if gVerbose: line text

# --------------------------------------------------------------- values

proc valueFor(n: int): string =
  let fill = char(ord('A') + (n mod 26))
  let size = if (n mod 2) == 0: 4096 else: 84000
  result = "{\"n\":" & $n & ",\"pad\":\""
  for i in 0 ..< size:
    result.add fill
  result.add "\",\"end\":" & $n & "}"

proc indexIn(text: string): int =
  const Head = "{\"n\":"
  if text.len < Head.len + 1: return -1
  if text.substr(0, Head.len - 1) != Head: return -1
  var i = Head.len
  var v = 0
  var any = false
  while i < text.len and text[i] >= '0' and text[i] <= '9':
    v = v * 10 + (ord(text[i]) - ord('0'))
    any = true
    inc i
  if not any: return -1
  result = v

proc whole(text: string): bool =
  let n = indexIn(text)
  if n < 0: return false
  result = text == valueFor(n)

# --------------------------------------------------------------- the child

proc childLoop(root: string; unsafe: bool): int =
  ## Writes until the parent kills it. Cycles `ValueCount` values so that no
  ## two consecutive writes share a length or a fill character.
  storeInit(root)
  let path = joinPath(joinPath(storeRoot(), Guid), Key)
  discard ensureDir(joinPath(joinPath(storeRoot(), Guid), ".hist"))
  var held = HeldFile(h: Handle(0))
  if unsafe:
    held = HeldFile(h: openHeld(path, true))
    if not heldValid(held.h): return 1
  var values: seq[string] = @[]
  for k in 0 ..< ValueCount:
    values.add valueFor(k)
  var n = 0
  while true:
    if unsafe:
      if not heldWrite(held.h, values[n]): return 1
    else:
      var error = ""
      if not storeWrite(Guid, Key, values[n], error):
        discard writeTextFile(joinPath(root, "childerror.txt"), error)
        return 1
    n = (n + 1) mod ValueCount
    # A pause the length of one commit, so the reader is not simply starved of
    # the lock -- the two processes share a store, not a mutex, but a writer
    # spinning flat out is a different experiment from a writer working.
    cSleepMs(1'i32)
  result = 0

# --------------------------------------------------------------- the parent

type
  Seen = object
    reads: int
    torn: int
    distinctIdx: int
    firstTorn: string

proc readPhase(root: string; seconds: int; held: var Seen; fresh: var Seen) =
  ## Reads the key two ways at once for `seconds`:
  ##   `held`  -- `storeReadInto`, the path a host takes, which keeps the
  ##              handle it opened
  ##   `fresh` -- `readShared`, a new open every time, which is what the file
  ##              actually says
  ## Two counters rather than one because the difference between them *is* the
  ## finding: if the file has moved on and the held handle has not, only the
  ## second one notices.
  held = Seen(reads: 0, torn: 0, distinctIdx: 0, firstTorn: "")
  fresh = Seen(reads: 0, torn: 0, distinctIdx: 0, firstTorn: "")
  var heldSeen: seq[int] = @[]
  var freshSeen: seq[int] = @[]
  let path = joinPath(joinPath(joinPath(root, "store"), Guid), Key)
  let deadline = cMs() + int64(seconds) * 1000'i64
  while cMs() < deadline:
    var v = ""
    var e = ""
    if storeReadInto(Guid, Key, v, e) == ReadOk:
      inc held.reads
      if not whole(v):
        inc held.torn
        if held.firstTorn.len == 0:
          held.firstTorn = "length " & $v.len & ", claims n=" & $indexIn(v)
      else:
        let n = indexIn(v)
        var known = false
        for k in heldSeen:
          if k == n: known = true
        if not known: heldSeen.add n
    var w = ""
    if readShared(path, w) and w.len > 0:
      inc fresh.reads
      if not whole(w):
        inc fresh.torn
        if fresh.firstTorn.len == 0:
          fresh.firstTorn = "length " & $w.len & ", claims n=" & $indexIn(w)
      else:
        let n = indexIn(w)
        var known = false
        for k in freshSeen:
          if k == n: known = true
        if not known: freshSeen.add n
  held.distinctIdx = heldSeen.len
  fresh.distinctIdx = freshSeen.len

proc historyCheck(root: string) =
  ## The ring: at most `BackupGenerations` files for the key, each a whole
  ## value, and none of them visible as a key.
  let dir = joinPath(joinPath(root, "store"), Guid)
  let hist = joinPath(dir, ".hist")
  var files: seq[string] = @[]
  var dirs: seq[string] = @[]
  if isDirectory(hist):
    collectEntries(hist, files, dirs)
  var gens = 0
  var badGen = ""
  for f in files:
    let name = baseName(f)
    if name.len <= Key.len or name.substr(0, Key.len - 1) != Key:
      continue
    let suffix = name.substr(Key.len, name.len - 1)
    if suffix == ".tmp" or suffix == ".tmpgen":
      continue
    inc gens
    var text = ""
    if not readShared(joinPath(hist, name), text) or not whole(text):
      badGen = name
  check("the history holds at most " & $BackupGenerations & " generations",
        gens <= BackupGenerations, $gens & " under " & hist)
  check("every generation is a whole value", badGen.len == 0, badGen)
  note "  " & $gens & " generation(s) under " & hist

  let keys = storeKeys(Guid, "")
  check("the history is not reported as keys",
        find(keys, ".hist") < 0 and find(keys, ".tmp") < 0, keys)
  check("the key itself is reported", find(keys, Key) >= 0, keys)

proc runPhase(exe, root: string; seconds: int; unsafe: bool):
    tuple[held, fresh: Seen] =
  var arg = "--child"
  if unsafe: arg = "--child-unsafe"
  var e2 = exe
  var w2 = root
  var c2 = "\"" & exe & "\" " & arg & " --root \"" & root & "\""
  let child = cSpawn(toCString(e2), toCString(w2), toCString(c2))
  # Let the writer get past its first value, so a reader that opens the key
  # before it exists is not counted as a reader that lost sight of it.
  cSleepMs(300'i32)
  # This process reads through the store too, so it has to be pointed at the
  # same root the child was given -- and pointed at it *after* the child has
  # made the key, so the first `heldFor` is an open of a file that exists.
  storeInit(root)
  var held = Seen(reads: 0, torn: 0, distinctIdx: 0, firstTorn: "")
  var fresh = Seen(reads: 0, torn: 0, distinctIdx: 0, firstTorn: "")
  readPhase(root, seconds, held, fresh)
  cSpawnKill(child)
  cSleepMs(200'i32)
  storeClose()
  result = (held: held, fresh: fresh)

proc digitsOf(s: string; fallback: int): int =
  var v = 0
  var any = false
  for ch in s:
    if ch >= '0' and ch <= '9':
      v = v * 10 + (ord(ch) - ord('0'))
      any = true
  result = (if any: v else: fallback)

proc main(): int =
  var root = ""
  var seconds = 4
  var child = false
  var unsafe = false
  var i = 1
  let n = paramCount()
  while i <= n:
    let a = paramStr(i)
    if a == "--root":
      inc i
      if i <= n: root = paramStr(i)
    elif a == "--seconds":
      inc i
      if i <= n: seconds = digitsOf(paramStr(i), seconds)
    elif a == "--child":
      child = true
    elif a == "--child-unsafe":
      child = true
      unsafe = true
    elif a == "--verbose" or a == "-v":
      gVerbose = true
      setVerbosity vVerbose
    elif a == "-h" or a == "--help":
      echo Usage
      return 0
    inc i
  if root.len == 0:
    err "storeguard needs --root"
    return 2
  if child:
    return childLoop(root, unsafe)

  let exe = paramStr(0)
  discard removeTree(root)
  discard ensureDir(root)
  storeInit(root)

  heading "storeguard"

  # ---- phase one: the store as it is
  let safeRoot = joinPath(root, "committed")
  discard ensureDir(safeRoot)
  let a = runPhase(exe, safeRoot, seconds, false)
  line "  committed writes: " & $a.held.reads & " reads through the held " &
       "handle, " & $a.held.torn & " torn, " & $a.held.distinctIdx &
       " distinct value(s); the file itself moved through " &
       $a.fresh.distinctIdx
  check("a committed write is never seen half-done (held handle)",
        a.held.torn == 0, a.held.firstTorn)
  check("a committed write is never seen half-done (fresh open)",
        a.fresh.torn == 0, a.fresh.firstTorn)
  check("the writer was actually writing", a.fresh.distinctIdx > 1,
        "the file never changed; the child may have died -- see " &
        joinPath(safeRoot, "childerror.txt"))
  check("a reader keeps up with a committed write",
        a.held.distinctIdx > 1,
        "the held handle answered " & $a.held.distinctIdx &
        " distinct value(s) while the file moved through " &
        $a.fresh.distinctIdx & " -- the handle is on a file the rename " &
        "unnamed, so this reader is answering with a value that no longer " &
        "exists")
  storeInit(safeRoot)
  historyCheck(safeRoot)
  storeClose()

  # ---- phase two: the control
  let unsafeRoot = joinPath(root, "inplace")
  discard ensureDir(unsafeRoot)
  storeInit(unsafeRoot)
  let b = runPhase(exe, unsafeRoot, seconds, true)
  line "  in-place writes:  " & $b.held.reads & " reads, " & $b.held.torn &
       " torn (" & $b.fresh.torn & " on a fresh open)"
  check("the in-place write is seen half-done, so the check can fail",
        b.held.torn > 0 or b.fresh.torn > 0,
        "no torn read in " & $seconds & "s; raise --seconds")

  if gFailures > 0:
    err $gFailures & " of " & $gChecks & " checks failed"
    note "evidence left under " & root
    return 1
  ok $gChecks & " checks over two phases of " & $seconds & "s"
  discard removeTree(root)
  result = 0

when isMainModule:
  quit(main())
