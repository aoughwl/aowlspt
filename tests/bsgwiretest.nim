## bsgwiretest -- the post-1.0 request envelope, against real captured bytes.
##
##     bsgwiretest <repo root>
##
## What this defends is a bug that could not be seen from the inside, and that
## is the reason it is a gate rather than a note.
##
## A post-1.0 client does not put `zlib(json)` on the wire. It wraps it:
##
##     wire = shuffle_L( [int32 LE size][payload][junk] )
##
## `shuffle_L` is a Fisher-Yates permutation keyed by nothing but the buffer's
## own length, so either side can undo it -- obfuscation, not encryption. The
## server did not undo it. A shuffled body is not zlib-framed, so it took
## `inflateBody`'s pass-through branch and arrived at the route handler as
## noise, with a 200 and no warning. Every route that ignores its request body
## kept working, which is most of the menu; the client booted all the way to
## the character screen against a server that had never once read what it was
## sent. What broke was everything that mattered -- creating a profile, moving
## an item, ending a raid -- and it broke by quietly doing nothing.
##
## So the assertions here are deliberately not synthetic. Every case is a body
## the real BSG client actually put on the wire, checked in beside the JSON it
## is supposed to decode to (`mods/tarkov/data/capture/raid1/requests`, from a
## Fiddler capture of a full session against the live backend). A synthetic
## round-trip through this module's own `bsgShuffle` would have passed against
## the broken server too, because it never touched the server's decision about
## *when* to unwrap.

import std/[syncio, strutils, cmdline]
import aowlsptinstall/winfs
import wire

# `wire.nim` emits this include into its own translation unit; nimony compiles
# each module separately, so a caller of `cZlibInflate` needs it too or the C
# compiler sees an implicit declaration and truncates the pointer arguments.
{.emit: """#include "aowlspt_net.h" """.}

var gChecks = 0
var gFailures = 0

proc check(what: string; cond: bool; detail = "") =
  inc gChecks
  if cond:
    echo "  ok   " & what
  else:
    inc gFailures
    echo "  FAIL " & what & (if detail.len > 0: "  -- " & detail else: "")

proc commaJoin(xs: seq[string]): string =
  ## `std/strutils.join` is not in nimony's subset.
  result = ""
  for i in 0 ..< xs.len:
    if i > 0: result.add ","
    result.add xs[i]

proc readBytes(path: string; into: var string): bool =
  ## The exact bytes, which is what a wire body is.
  ##
  ## Deliberately not `winfs.readTextFile`: that one drops a UTF-8 BOM, and it
  ## says in its own documentation that a reader wanting exact bytes should not
  ## use it. A shuffled body is uniform over all 256 values, so one in sixteen
  ## million of them opens with `EF BB BF` -- rare enough never to be caught by
  ## hand and certain to be hit by a corpus that grows.
  into = ""
  var f: File
  if not open(f, path, fmRead):
    return false
  result = false
  try:
    try:
      into = readAll(f)
      result = true
    except:
      result = false
  finally:
    close(f)

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](if s.len > 0: s.len else: 1)
  if s.len > 0:
    copyMem(addr result[0], readRawData(s), s.len)

proc inflateAll(src: seq[byte]; start, len: int; into: var string): bool =
  ## Inflate a window, growing the destination rather than guessing once.
  into = ""
  if len <= 0:
    return false
  var cap = len * 16
  if cap < 4096: cap = 4096
  var dst = newSeq[byte](cap)
  var tries = 0
  while tries < 6:
    let n = cZlibInflate(
      cast[WirePtr](cast[uint](addr src[0]) + uint(start)), int32(len),
      cast[WirePtr](addr dst[0]), int32(dst.len))
    if n >= 0'i32:
      into = fromBytes(dst, int(n))
      return true
    dst = newSeq[byte](dst.len * 8)
    inc tries
  result = false

proc main(): int =
  let root = if paramCount() >= 1: paramStr(1) else: "."
  let dir = joinPath(root, "mods\\tarkov\\data\\capture\\raid1\\requests")
  let rawDir = joinPath(dir, "raw")
  if not isDirectory(rawDir):
    echo "no capture corpus at " & rawDir
    echo "  (the gate needs mods/tarkov/data/capture/raid1/requests/raw)"
    return 1

  echo "the envelope is its own inverse"
  # Every length either side of the 0xAAB table wrap, plus the lengths the
  # capture actually contains. An off-by-one in the table offset is invisible
  # at some lengths and not others, which is why this sweeps rather than spot
  # checks.
  var lengths: seq[int] = @[]
  for n in 1 ..< 300: lengths.add n
  lengths.add 0xAAA
  lengths.add 0xAAB
  lengths.add 0xAAC
  lengths.add 14800
  var inverseFails = 0
  var seed = 0x12345'u32
  for n in lengths:
    var a = newSeq[byte](n)
    for i in 0 ..< n:
      seed = seed * 1664525'u32 + 1013904223'u32
      a[i] = byte((seed shr 16) and 0xFF'u32)
    var b = newSeq[byte](n)
    for i in 0 ..< n: b[i] = a[i]
    bsgUnshuffle(b, n)
    bsgShuffle(b, n)
    for i in 0 ..< n:
      if a[i] != b[i]:
        inc inverseFails
        break
  check("shuffle undoes unshuffle at every one of " & $lengths.len &
        " lengths", inverseFails == 0, $inverseFails & " lengths disagreed")

  echo ""
  echo "every captured request body decodes to the JSON checked in beside it"
  var files: seq[string] = @[]
  var dirs: seq[string] = @[]
  collectEntries(rawDir, files, dirs)
  var decoded = 0
  var enveloped = 0
  var mismatched: seq[string] = @[]
  var notEnveloped: seq[string] = @[]
  for f in files:
    if not endsWith(f, ".bin"): continue
    # `collectEntries` yields paths relative to the root it walked.
    let stem = baseName(f).substr(0, baseName(f).len - 5)
    var wireText = ""
    if not readBytes(joinPath(rawDir, f), wireText):
      mismatched.add stem & "(unreadable)"
      continue
    var want = ""
    if not readBytes(joinPath(dir, stem & ".json"), want):
      mismatched.add stem & "(no json)"
      continue

    # The server's own decision tree, in the order `inflateBody` applies it.
    # Asserting the envelope alone would prove less than it looks: what has to
    # be right is *when* the server unwraps, and the bodies that decide that
    # are the ones that are not enveloped at all.
    var raw = bytesOf(wireText)
    let src = cast[WirePtr](addr raw[0])
    let looksFramed = cZlibFramed(src, int32(wireText.len)) != 0'i32
    var got = ""
    var ok = looksFramed and inflateAll(raw, 0, wireText.len, got)
    if not ok:
      var buf = bytesOf(wireText)
      var payloadLen = 0
      if bsgUnwrap(buf, wireText.len, payloadLen):
        inc enveloped
        ok = true
        if not inflateAll(buf, 4, payloadLen, got):
          got = bytesAt(buf, 4, payloadLen)
      else:
        notEnveloped.add stem
        if not looksFramed and inflateAll(raw, 0, wireText.len, got):
          ok = true
        else:
          got = wireText
    if got == want:
      inc decoded
    else:
      mismatched.add stem
  check("all " & $decoded & " of them", mismatched.len == 0,
        "mismatched: " & commaJoin(mismatched))
  check("the corpus is not empty", decoded > 140, $decoded & " decoded")
  # The two that are not enveloped are named rather than counted, because
  # "some bodies are plain" is the sort of claim that quietly absorbs a
  # regression: if the envelope stopped being recognised, every body would
  # fall into this bucket and a count-based check would still pass.
  # Named rather than counted. "Some bodies are plain" quietly absorbs a
  # regression: if the envelope stopped being recognised, every body would land
  # in this bucket and a count would still look reasonable. Seq 019 is
  # `/client/metadata`, which posts plain JSON.
  check("only /client/metadata is unenveloped",
        commaJoin(notEnveloped) == "019",
        "got: " & commaJoin(notEnveloped))
  check("the other " & $enveloped & " are enveloped",
        enveloped == decoded - 2, $enveloped & " enveloped of " & $decoded)
  # Seq 458 is the case that made the ordering matter: its shuffled body opens
  # with a valid zlib header by chance, so a server that trusts the header
  # inflates, fails, and gives up. It must still be read.
  check("a shuffled body whose header looks like zlib is still read",
        not contains(commaJoin(mismatched), "458"))

  echo ""
  echo "an unenveloped body is not mistaken for an enveloped one"
  # The guard that keeps this from being worse than the bug it fixes. A plain
  # zlib body -- what every tool in this repository and every pre-1.0 client
  # sends -- unshuffles to noise, and noise must not read as a size word. If it
  # did, the server would scramble bodies it used to understand.
  var falsePositives = 0
  var trials = 0
  seed = 0xC0FFEE'u32
  for n in [24, 40, 64, 128, 512, 2048]:
    for round in 0 ..< 400:
      var a = newSeq[byte](n)
      for i in 0 ..< n:
        seed = seed * 1664525'u32 + 1013904223'u32
        a[i] = byte((seed shr 16) and 0xFF'u32)
      var payloadLen = 0
      inc trials
      if bsgUnwrap(a, n, payloadLen):
        inc falsePositives
  # Noise leads with a plausible size word about once in a few hundred million;
  # over a few thousand trials the honest expectation is exactly zero.
  check("none of " & $trials & " random buffers unwrapped",
        falsePositives == 0, $falsePositives & " did")

  echo ""
  echo $gChecks & " checks, " & $gFailures & " failures"
  result = if gFailures == 0: 0 else: 1

when isMainModule:
  quit(main())
