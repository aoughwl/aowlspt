## manifest.nim — the name→replacement table the swap hook reads.
##
## The pipeline (`pipeline/build_pack.py`) emits `data/manifest.json`: a curated,
## quality-tiered list of `{name, file, map, cat, tier, conf}` records, sorted by
## `name` (the lowercased Unity texture asset name the game asks for). This
## module reads it once at load and answers `lookup(name)` on the swap path.
##
## Nothing here touches the runtime. A manifest that fails to read leaves the
## table empty, and an empty table makes every lookup miss — which is the mod's
## whole safe-by-default posture expressed in one data structure: no manifest,
## no swaps, stock textures.

import std/syncio
import aowlspt
import aowlspt/json

type
  Entry* = object
    name*: string   ## lowercased Unity texture name — the lookup key
    file*: string   ## replacement image path, relative to the pack root
    map*: string    ## "albedo" | "normal" | "roughness" | "ao" | ...
    cat*: string    ## ambientcg category (Metal, Wood, …)
    tier*: string   ## "2K" | "4K"
    conf*: float    ## match confidence 0..1

var gEntries: seq[Entry] = @[]
var gSorted = true
var gPackRoot = ""

proc packRoot*(): string = gPackRoot
proc entryCount*(): int = gEntries.len

# Field accessors rather than one that returns the whole `Entry` by value:
# returning a struct out of a seq index is the one shape nimony would not infer
# here (it reads back as `auto`), and every accessor in this codebase that
# reaches into a `seq` returns a field, not the record. So do the same.
proc entryName*(i: int): string =
  result = gEntries[i].name
proc entryFile*(i: int): string =
  result = gEntries[i].file
proc entryMap*(i: int): string =
  result = gEntries[i].map
proc entryCat*(i: int): string =
  result = gEntries[i].cat
proc entryTier*(i: int): string =
  result = gEntries[i].tier
proc entryConf*(i: int): float =
  result = gEntries[i].conf

proc lowerAscii(s: string): string =
  ## A local lowercaser rather than std/strutils, kept dependency-free and
  ## ASCII-only on purpose: texture names are ASCII, and the pipeline lowercased
  ## the keys with Python's `.lower()`, which for ASCII is the same mapping.
  result = newString(s.len)
  for i in 0 ..< s.len:
    let c = s[i]
    if c >= 'A' and c <= 'Z':
      result[i] = chr(ord(c) + 32)
    else:
      result[i] = c

proc readWholeFile(path: string; into: var string): bool =
  ## Non-raising read (the `open` bool overload and `readLine` do not raise).
  ## The manifest is one record per line, so the `\n` rejoin is exact for the
  ## JSON parser.
  var f: File
  if not open(f, path, fmRead):
    return false
  into = ""
  var line = ""
  var first = true
  while readLine(f, line):
    if not first: into.add "\n"
    into.add line
    first = false
  close(f)
  result = true

proc mapMul*(map: string): float =
  ## A rough per-map VRAM weight. A colour map is the baseline; a single-channel
  ## roughness/AO the game may still keep as RGBA, so this is deliberately
  ## conservative (1.0) rather than 0.25 — the budget should under-promise.
  1.0

proc loadManifest*(path, packRootDir: string): bool =
  ## Reads and parses the manifest. Returns false (and leaves the table empty)
  ## on any failure, which is the safe outcome: the swap path then never fires.
  gEntries = @[]
  gSorted = true
  gPackRoot = packRootDir
  var text = ""
  if not readWholeFile(path, text) or text.len == 0:
    return false
  let root = whole(text)
  if not root.exists:
    return false
  let arr = field(root, "entries")
  if not arr.isArray:
    return false
  let items = each(arr)
  var prev = ""
  for it in items:
    var e = Entry(
      name: lowerAscii(asText(child(it, "name"), "")),
      file: asText(child(it, "file"), ""),
      map:  asText(child(it, "map"), ""),
      cat:  asText(child(it, "cat"), ""),
      tier: asText(child(it, "tier"), ""),
      conf: asFloat(child(it, "conf"), 0.0))
    if e.name.len == 0 or e.file.len == 0:
      continue
    if e.name < prev:
      gSorted = false
    prev = e.name
    gEntries.add e
  result = gEntries.len > 0

proc lookup*(name: string): int =
  ## The index of the replacement for `name`, or -1. Binary search when the
  ## manifest arrived sorted (it always does from the pipeline); linear as a
  ## correctness fallback if some hand-edit broke the ordering.
  let key = lowerAscii(name)
  if gEntries.len == 0:
    return -1
  if not gSorted:
    for i in 0 ..< gEntries.len:
      if gEntries[i].name == key:
        return i
    return -1
  var lo = 0
  var hi = gEntries.len - 1
  while lo <= hi:
    let mid = (lo + hi) div 2
    let n = gEntries[mid].name
    if n == key:
      return mid
    elif n < key:
      lo = mid + 1
    else:
      hi = mid - 1
  result = -1

proc resolvedPath*(i: int): string =
  ## The absolute path to entry i's replacement image on disk.
  if gPackRoot.len == 0:
    result = gEntries[i].file
  else:
    result = gPackRoot & "/" & gEntries[i].file
