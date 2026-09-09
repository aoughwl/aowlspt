## `aowl release` -- one versioned, verifiable artifact out of a tree that has
## already been built.
##
##     aowl-release                     the bundle: payload + installer + manifest
##     aowl-release --mod sway          one mod, as an overlay payload zip
##     aowl-release --check-only        every gate, and write nothing
##     aowl-release --out D:\drop       somewhere other than <repo>\dist
##
## `aowl payload` stages what was built. This turns that staging into something
## a person can be handed: a zip whose name says which version it is, a
## manifest saying what is in it and what each file hashes to, and a changelog
## generated out of the registry rather than remembered.
##
## ## Where the version lives
##
## In `VERSION` at the top of the repo. One line, no syntax, no parser.
##
## The alternatives were all worse. `installer/payload/payload.json` already
## carries a `version`, but that document is *edited per client* --
## `targetTarkovVersion` changes whenever the game does -- so the release
## number would live inside a file people hand-edit for an unrelated reason.
## `registry/mods.json` versions *mods*, not the bundle, and its schema has no
## field for one. A constant in this source would mean rebuilding the tool to
## cut a release, and would put the number somewhere the docs and the installer
## cannot read.
##
## So `VERSION` is the source and every other appearance is *derived*: the
## archive's name, the manifest header, the changelog title, and the `version`
## field of the payload.json that goes into the archive -- which is patched
## member-wise as the release is built, so the number cannot be typed twice and
## cannot disagree with itself.
##
## ## Reproducibility
##
## Two runs from the same tree produce byte-identical archives. That is bought
## with four decisions:
##
##  * entries are **stored**, not deflated. A deflate stream is a property of
##    whichever zlib the machine linked, so a compressed archive would be
##    reproducible only against itself. The payload is ~10 MB; the compression
##    was not worth making the guarantee conditional.
##  * every entry carries the **same fixed DOS timestamp** (1980-01-01) rather
##    than the source file's mtime, which changes on every rebuild.
##  * entries are **sorted by name**, so directory enumeration order cannot
##    reach the output.
##  * nothing inside the archive records when it was built. The date is in the
##    *file name* and in the sidecar `.sha256`, both outside the hashed bytes.
##
## The consequence worth stating: the same tree released on two different days
## gives two files with different names and identical contents.
##
## One input is not the tree, and it is worth naming rather than discovering:
## `CHANGELOG.md` carries an "Against <previous release>" section built from the
## `MODS.tsv` of the newest earlier release **staged in the same `--out`
## directory**. So the same tree released into an empty directory and into one
## with history produces two different archives. That is the intended
## behaviour -- a changelog with nothing to compare against should not invent a
## comparison -- but it means "reproducible" is a statement about a tree *and*
## an output directory, not about a tree alone.
##
## ## What it refuses
##
## Everything, before it writes anything. The failure this exists to prevent is
## the one `installer/payload/README.md` documents -- an install that lands
## looking complete and loads nothing, because a mod directory holds a config
## and no library, or the registry never went in. That failure is silent in the
## game and in both logs. A release is the last point at which it can be made
## impossible rather than documented.

import std/[strutils, syncio, cmdline, osproc]
import aowlsptinstall/[winfs, log]
import aowlspt/json

{.emit: """#include <time.h>""".}
proc cTime(p: pointer): int64 {.importc: "time", nodecl.}

const
  Usage = """
aowl-release -- a versioned, verifiable artifact from a built tree

  aowl-release [options]

  --repo PATH        the repository (default: found from this exe or cwd)
  --out DIR          where the artifact goes (default: <repo>\dist)
  --mod NAME         package one mod instead of the whole bundle; NAME may be
                     the registry id or the mod's directory
  --check-only       run every gate and write nothing
  --date YYYY-MM-DD  the date in the file name (default: today, UTC)
  -q, --quiet        findings only
  -h, --help         this
"""
  HexDigits = "0123456789abcdef"
  Discord = "https://discord.gg/nxa3W7w4rJ"

# ------------------------------------------------------------------- crc32

var crcTable: seq[uint32] = @[]

proc crcInit() =
  crcTable = @[]
  var i = 0
  while i < 256:
    var c = uint32(i)
    var k = 0
    while k < 8:
      if (c and 1'u32) != 0'u32:
        c = 0xEDB88320'u32 xor (c shr 1'u32)
      else:
        c = c shr 1'u32
      inc k
    crcTable.add c
    inc i

proc crc32(s: string): uint32 =
  var c = 0xFFFFFFFF'u32
  for ch in s:
    let idx = int((c xor uint32(ord(ch))) and 0xFF'u32)
    c = crcTable[idx] xor (c shr 8'u32)
  result = c xor 0xFFFFFFFF'u32

# ------------------------------------------------------------------- sha256

const ShaK: array[64, uint32] = [
  0x428a2f98'u32, 0x71374491'u32, 0xb5c0fbcf'u32, 0xe9b5dba5'u32,
  0x3956c25b'u32, 0x59f111f1'u32, 0x923f82a4'u32, 0xab1c5ed5'u32,
  0xd807aa98'u32, 0x12835b01'u32, 0x243185be'u32, 0x550c7dc3'u32,
  0x72be5d74'u32, 0x80deb1fe'u32, 0x9bdc06a7'u32, 0xc19bf174'u32,
  0xe49b69c1'u32, 0xefbe4786'u32, 0x0fc19dc6'u32, 0x240ca1cc'u32,
  0x2de92c6f'u32, 0x4a7484aa'u32, 0x5cb0a9dc'u32, 0x76f988da'u32,
  0x983e5152'u32, 0xa831c66d'u32, 0xb00327c8'u32, 0xbf597fc7'u32,
  0xc6e00bf3'u32, 0xd5a79147'u32, 0x06ca6351'u32, 0x14292967'u32,
  0x27b70a85'u32, 0x2e1b2138'u32, 0x4d2c6dfc'u32, 0x53380d13'u32,
  0x650a7354'u32, 0x766a0abb'u32, 0x81c2c92e'u32, 0x92722c85'u32,
  0xa2bfe8a1'u32, 0xa81a664b'u32, 0xc24b8b70'u32, 0xc76c51a3'u32,
  0xd192e819'u32, 0xd6990624'u32, 0xf40e3585'u32, 0x106aa070'u32,
  0x19a4c116'u32, 0x1e376c08'u32, 0x2748774c'u32, 0x34b0bcb5'u32,
  0x391c0cb3'u32, 0x4ed8aa4a'u32, 0x5b9cca4f'u32, 0x682e6ff3'u32,
  0x748f82ee'u32, 0x78a5636f'u32, 0x84c87814'u32, 0x8cc70208'u32,
  0x90befffa'u32, 0xa4506ceb'u32, 0xbef9a3f7'u32, 0xc67178f2'u32]

proc rotr32(x: uint32; n: uint32): uint32 =
  result = (x shr n) or (x shl (32'u32 - n))

proc sha256Hex(data: string): string =
  ## SHA-256, written out here rather than reached for: nothing in this tree
  ## hashes anything cryptographically yet, and a manifest whose hashes come
  ## from a dependency stops being checkable the day the dependency is not
  ## installed.
  var h: array[8, uint32] = [
    0x6a09e667'u32, 0xbb67ae85'u32, 0x3c6ef372'u32, 0xa54ff53a'u32,
    0x510e527f'u32, 0x9b05688c'u32, 0x1f83d9ab'u32, 0x5be0cd19'u32]
  var msg = data
  let bitLen = uint64(data.len) * 8'u64
  msg.add char(0x80)
  while (msg.len mod 64) != 56:
    msg.add char(0)
  var b = 7
  while b >= 0:
    msg.add char(int((bitLen shr (uint64(b) * 8'u64)) and 0xFF'u64))
    dec b
  # A seq rather than an array: nimony will not take an uninitialised array,
  # and sixty-four zeroes written once per call is not the cost in here.
  var w: seq[uint32] = @[]
  var z = 0
  while z < 64:
    w.add 0'u32
    inc z
  var pos = 0
  while pos < msg.len:
    var t = 0
    while t < 16:
      let o = pos + t * 4
      w[t] = (uint32(ord(msg[o])) shl 24'u32) or
             (uint32(ord(msg[o + 1])) shl 16'u32) or
             (uint32(ord(msg[o + 2])) shl 8'u32) or
             uint32(ord(msg[o + 3]))
      inc t
    t = 16
    while t < 64:
      let x = w[t - 15]
      let y = w[t - 2]
      let s0 = rotr32(x, 7'u32) xor rotr32(x, 18'u32) xor (x shr 3'u32)
      let s1 = rotr32(y, 17'u32) xor rotr32(y, 19'u32) xor (y shr 10'u32)
      w[t] = w[t - 16] + s0 + w[t - 7] + s1
      inc t
    var a = h[0]
    var bb = h[1]
    var cc = h[2]
    var dd = h[3]
    var ee = h[4]
    var ff = h[5]
    var gg = h[6]
    var hh = h[7]
    t = 0
    while t < 64:
      let e1 = rotr32(ee, 6'u32) xor rotr32(ee, 11'u32) xor rotr32(ee, 25'u32)
      let chx = (ee and ff) xor ((not ee) and gg)
      let t1 = hh + e1 + chx + ShaK[t] + w[t]
      let e0 = rotr32(a, 2'u32) xor rotr32(a, 13'u32) xor rotr32(a, 22'u32)
      let mj = (a and bb) xor (a and cc) xor (bb and cc)
      let t2 = e0 + mj
      hh = gg
      gg = ff
      ff = ee
      ee = dd + t1
      dd = cc
      cc = bb
      bb = a
      a = t1 + t2
      inc t
    h[0] = h[0] + a
    h[1] = h[1] + bb
    h[2] = h[2] + cc
    h[3] = h[3] + dd
    h[4] = h[4] + ee
    h[5] = h[5] + ff
    h[6] = h[6] + gg
    h[7] = h[7] + hh
    pos = pos + 64
  result = ""
  var i = 0
  while i < 8:
    var s = 28
    while s >= 0:
      let nib = int((h[i] shr uint32(s)) and 0xF'u32)
      result.add HexDigits[nib]
      s = s - 4
    inc i

# ------------------------------------------------------------------- the zip
#
# Store-only, fixed timestamps, sorted names. See the module comment for why.

type
  ZipEntry = object
    name: string   ## the path inside the archive, forward slashes
    data: string

proc le16(v: int): string =
  result = ""
  result.add char(v and 0xFF)
  result.add char((v shr 8) and 0xFF)

proc le32(v: uint32): string =
  result = ""
  result.add char(int(v and 0xFF'u32))
  result.add char(int((v shr 8'u32) and 0xFF'u32))
  result.add char(int((v shr 16'u32) and 0xFF'u32))
  result.add char(int((v shr 24'u32) and 0xFF'u32))

proc rd16(s: string; i: int): int =
  if i < 0 or i + 1 >= s.len:
    return -1
  result = ord(s[i]) or (ord(s[i + 1]) shl 8)

proc rd32(s: string; i: int): int =
  if i < 0 or i + 3 >= s.len:
    return -1
  result = ord(s[i]) or (ord(s[i + 1]) shl 8) or (ord(s[i + 2]) shl 16) or
           (ord(s[i + 3]) shl 24)

const
  DosTime = 0        ## 00:00:00
  DosDate = 33       ## 1980-01-01: ((1980-1980) shl 9) or (1 shl 5) or 1
  ZipMax = 2000000000

proc zipBytes(entries: seq[ZipEntry]): string =
  var body = ""
  var central = ""
  var offset = 0
  var count = 0
  for e in entries:
    let crc = crc32(e.data)
    let n = e.data.len
    var lh = "PK"
    lh.add char(3)
    lh.add char(4)
    lh.add le16(20)          # version needed
    lh.add le16(0)           # flags
    lh.add le16(0)           # method 0: stored
    lh.add le16(DosTime)
    lh.add le16(DosDate)
    lh.add le32(crc)
    lh.add le32(uint32(n))
    lh.add le32(uint32(n))
    lh.add le16(e.name.len)
    lh.add le16(0)           # no extra field: it is where mtimes hide
    lh.add e.name
    var cd = "PK"
    cd.add char(1)
    cd.add char(2)
    cd.add le16(20)          # version made by
    cd.add le16(20)          # version needed
    cd.add le16(0)
    cd.add le16(0)
    cd.add le16(DosTime)
    cd.add le16(DosDate)
    cd.add le32(crc)
    cd.add le32(uint32(n))
    cd.add le32(uint32(n))
    cd.add le16(e.name.len)
    cd.add le16(0)           # extra
    cd.add le16(0)           # comment
    cd.add le16(0)           # disk
    cd.add le16(0)           # internal attributes
    cd.add le32(0'u32)       # external attributes
    cd.add le32(uint32(offset))
    cd.add e.name
    body.add lh
    body.add e.data
    central.add cd
    offset = offset + lh.len + n
    inc count
  var eocd = "PK"
  eocd.add char(5)
  eocd.add char(6)
  eocd.add le16(0)
  eocd.add le16(0)
  eocd.add le16(count)
  eocd.add le16(count)
  eocd.add le32(uint32(central.len))
  eocd.add le32(uint32(offset))
  eocd.add le16(0)
  result = body
  result.add central
  result.add eocd

proc zipRead(archive: string; out1: var seq[ZipEntry]; why: var string): bool =
  ## Reads an archive back the way any other unzipper would: end of central
  ## directory, central records, then the local header each one points at --
  ## and checks the stored CRC against the bytes it just read.
  ##
  ## This exists so the shape check runs against the *file* rather than against
  ## the seq the writer was handed. A writer that drops an entry, mangles a
  ## name or truncates a member is a bug no check reading the writer's own
  ## input can see.
  out1 = @[]
  why = ""
  if archive.len < 22:
    why = "shorter than an empty archive"
    return false
  var e = archive.len - 22
  var found = -1
  while e >= 0:
    if archive[e] == 'P' and archive[e + 1] == 'K' and
       ord(archive[e + 2]) == 5 and ord(archive[e + 3]) == 6:
      found = e
      break
    dec e
  if found < 0:
    why = "no end-of-central-directory record"
    return false
  let count = rd16(archive, found + 10)
  let cdSize = rd32(archive, found + 12)
  let cdOff = rd32(archive, found + 16)
  if count < 0 or cdSize < 0 or cdOff < 0 or cdOff + cdSize > archive.len:
    why = "the central directory is not inside the file"
    return false
  var p = cdOff
  var seen = 0
  while seen < count:
    if p + 46 > archive.len:
      why = "central record " & $seen & " runs off the end"
      return false
    if not (archive[p] == 'P' and archive[p + 1] == 'K' and
            ord(archive[p + 2]) == 1 and ord(archive[p + 3]) == 2):
      why = "central record " & $seen & " has no signature"
      return false
    let meth = rd16(archive, p + 10)
    let crc = rd32(archive, p + 16)
    let csize = rd32(archive, p + 20)
    let usize = rd32(archive, p + 24)
    let nameLen = rd16(archive, p + 28)
    let extraLen = rd16(archive, p + 30)
    let cmtLen = rd16(archive, p + 32)
    let lho = rd32(archive, p + 42)
    if nameLen < 0 or p + 46 + nameLen > archive.len:
      why = "central record " & $seen & " has an unreadable name"
      return false
    let name = archive.substr(p + 46, p + 46 + nameLen - 1)
    if meth != 0:
      why = name & " is not stored (method " & $meth & ")"
      return false
    if csize != usize:
      why = name & " claims to be compressed"
      return false
    if lho < 0 or lho + 30 > archive.len:
      why = name & " points outside the file"
      return false
    let lNameLen = rd16(archive, lho + 26)
    let lExtraLen = rd16(archive, lho + 28)
    if lNameLen < 0 or lExtraLen < 0:
      why = name & " has an unreadable local header"
      return false
    let dataAt = lho + 30 + lNameLen + lExtraLen
    if dataAt + usize > archive.len:
      why = name & "'s data runs off the end"
      return false
    var item = ZipEntry(name: name, data: "")
    if usize > 0:
      item.data = archive.substr(dataAt, dataAt + usize - 1)
    if int(crc32(item.data)) != crc:
      why = name & " does not match its own CRC"
      return false
    out1.add item
    p = p + 46 + nameLen + extraLen + cmtLen
    inc seen
  result = true

# ------------------------------------------------------------------- helpers

proc readBytes(p: string; into: var string): bool =
  ## Every read in this program goes through here. `winfs` has had more than
  ## one whole-file reader over this file's lifetime; a release that hashes
  ## bytes cannot afford to find out from a wrong hash which one it got.
  ## `readTextFile` opens binary and returns the file's length in a string, so
  ## a `.dll` survives it -- which the manifest's hashes prove on every run.
  result = readTextFile(p, into)

proc qq(s: string): string = "\"" & s & "\""

proc slashed(p: string): string =
  result = ""
  for ch in p:
    if ch == '\\': result.add '/'
    else: result.add ch

proc two(n: int): string =
  if n < 10: result = "0" & $n
  else: result = $n

proc todayUtc(): string =
  ## Days since the epoch turned into a civil date. No `std/times`: this is
  ## eight lines of arithmetic and one libc call, and it is the only thing in
  ## the program allowed to know what day it is.
  let secs = cTime(cast[pointer](0))
  let z = int(secs div 86400'i64) + 719468
  var era = z div 146097
  if z < 0: era = (z - 146096) div 146097
  let doe = z - era * 146097
  let yoe = (doe - doe div 1460 + doe div 36524 - doe div 146096) div 365
  var y = yoe + era * 400
  let doy = doe - (365 * yoe + yoe div 4 - yoe div 100)
  let mp = (5 * doy + 2) div 153
  let d = doy - (153 * mp + 2) div 5 + 1
  var m = mp + 3
  if mp >= 10: m = mp - 9
  if m <= 2: y = y + 1
  result = $y & "-" & two(m) & "-" & two(d)

proc addSorted(entries: var seq[ZipEntry]; e: ZipEntry) =
  ## Insertion by name. A few dozen entries, and it keeps the ordering
  ## guarantee in the same place as the thing it orders.
  var i = entries.len
  entries.add e
  while i > 0 and entries[i - 1].name > e.name:
    entries[i] = entries[i - 1]
    dec i
  entries[i] = e

proc findEntry(entries: seq[ZipEntry]; name: string): int =
  result = -1
  var i = 0
  while i < entries.len:
    if entries[i].name == name:
      return i
    inc i

var gRefusals = 0

proc refuse(what, detail: string) =
  err what & ": " & detail
  inc gRefusals

proc require1(what: string; condition: bool; detail: string) =
  if condition:
    ok what
  else:
    refuse(what, detail)

# ------------------------------------------------------------------- registry

type
  RegMod = object
    id: string
    name: string
    version: string
    author: string
    license: string
    artDir: string
    artLib: string
    srcKind: string
    srcPath: string

  RegList = object
    id: string
    name: string
    inherits: seq[string]
    members: seq[string]

proc readRegistry(text: string; mods: var seq[RegMod];
                  lists: var seq[RegList]) =
  mods = @[]
  lists = @[]
  let modsNode = json.field(text, "mods")
  let modItems = each(modsNode)
  for m in modItems:
    var r = RegMod(id: "", name: "", version: "", author: "", license: "",
                   artDir: "", artLib: "", srcKind: "", srcPath: "")
    r.id = asText(child(m, "id"))
    r.name = asText(child(m, "name"))
    r.version = asText(child(m, "version"))
    r.author = asText(child(m, "author"))
    r.license = asText(child(m, "license"))
    if r.license == "null" or r.license.len == 0:
      r.license = "unstated"
    r.srcKind = asText(field(m, "source.kind"))
    r.srcPath = asText(field(m, "source.path"))
    r.artDir = asText(field(m, "artifact.dir"))
    r.artLib = asText(field(m, "artifact.library"))
    mods.add r
  let listsNode = json.field(text, "lists")
  let listItems = each(listsNode)
  for l in listItems:
    var r = RegList(id: "", name: "", inherits: @[], members: @[])
    r.id = asText(child(l, "id"))
    r.name = asText(child(l, "name"))
    let inh = each(child(l, "inherits"))
    for h in inh:
      r.inherits.add asText(h)
    # `entries`, not `mods`: the schema calls a list's members entries, and a
    # changelog that reads the wrong key does not fail -- it prints a list with
    # nothing in it, which is exactly the kind of quiet lie this file exists to
    # not produce.
    let entries = each(child(l, "entries"))
    for en in entries:
      var id = asText(child(en, "id"))
      if not asBool(child(en, "enabled"), false):
        id.add " (off)"
      r.members.add id
    lists.add r

proc readVersion(repo: string; into: var string): bool =
  ## The one place the release number lives. The first line that is neither
  ## blank nor a comment; nothing else is syntax.
  into = ""
  var text = ""
  if not readBytes(joinPath(repo, "VERSION"), text):
    return false
  for l in splitLines(text):
    let t = strip(l)
    if t.len == 0 or t[0] == '#':
      continue
    into = t
    return true
  result = false

proc looksVersion(v: string): bool =
  ## `1.2.3`, or `1.2.3-rc1`. Checked because the number becomes a file name
  ## and a directory name, and a stray quote or slash in it is a release that
  ## cannot be written and does not say why.
  if v.len == 0 or v.len > 40:
    return false
  var digits = 0
  var dots = 0
  for ch in v:
    if ch >= '0' and ch <= '9': inc digits
    elif ch == '.': inc dots
    elif ch == '-' or ch == '_' or (ch >= 'a' and ch <= 'z') or
         (ch >= 'A' and ch <= 'Z'): discard
    else: return false
  result = digits > 0 and dots >= 1

proc addTree(entries: var seq[ZipEntry]; srcRoot, prefix: string;
             skipped: var int): bool =
  ## Every file under `srcRoot`, at `prefix` inside the archive.
  if not isDirectory(srcRoot):
    return false
  var files: seq[string] = @[]
  var dirs: seq[string] = @[]
  collectEntries(srcRoot, files, dirs)
  result = true
  for f in files:
    let lower = toLowerAscii(f)
    # Nothing that is build residue. A `.pdb` or a `.lib` beside a mod is not
    # fatal, but it is bytes a player downloads and a thing a reviewer has to
    # ask about, and both are avoidable.
    if lower.endsWith(".pdb") or lower.endsWith(".lib") or
       lower.endsWith(".exp") or lower.endsWith(".obj") or
       find(lower, "nimcache\\") >= 0:
      inc skipped
      continue
    var data = ""
    if not readBytes(joinPath(srcRoot, f), data):
      return false
    entries.addSorted ZipEntry(name: prefix & slashed(f), data: data)

proc addFile(entries: var seq[ZipEntry]; src, name: string): bool =
  var data = ""
  if not readBytes(src, data):
    return false
  entries.addSorted ZipEntry(name: name, data: data)
  result = true

proc runTool(exe, args: string; output: var string): int =
  output = ""
  var code = -1
  try:
    let (o, c) = execCmdEx(qq(exe) & " " & args)
    output = o
    code = c
  except:
    output = "could not start " & exe
    code = -1
  result = code

# ------------------------------------------------------------------- gates

type Ctx = object
  repo: string
  outDir: string
  payloadDir: string
  buildDir: string
  version: string
  date: string
  regText: string
  payloadText: string
  mods: seq[RegMod]
  lists: seq[RegList]

proc gates(c: var Ctx): bool =
  ## Everything that has to be true before a single byte is written. Ordered
  ## cheapest first, and every one names the failure it prevents rather than
  ## the file it happened to look at.
  heading "Gates"

  # 1. the version, from the one place it lives.
  var v = ""
  require1("VERSION says what this release is", readVersion(c.repo, v),
           "no readable " & joinPath(c.repo, "VERSION") &
           "; the release number lives there and nowhere else")
  if v.len > 0:
    require1("the version is a version", looksVersion(v),
             qq(v) & " is not something to name a file after")
  c.version = v

  # 2. the payload manifest, and the fields the installer refuses without.
  let pj = joinPath(c.payloadDir, "payload.json")
  require1("there is a payload.json", fileExists(pj),
           "no " & pj & "; aowlspt-install will not install a payload that " &
           "does not say what it was built for")
  if fileExists(pj):
    discard readBytes(pj, c.payloadText)
    let tv = asText(json.field(c.payloadText, "targetTarkovVersion"))
    let tb = asText(json.field(c.payloadText, "targetBackend"))
    let kind = asText(json.field(c.payloadText, "kind"))
    require1("payload.json declares targetTarkovVersion", tv.len > 0,
             "the installer refuses a payload that will not say which client " &
             "its binaries were built against")
    require1("payload.json declares targetBackend",
             tb == "mono" or tb == "il2cpp",
             qq(tb) & " is neither mono nor il2cpp")
    require1("payload.json declares a kind",
             kind == "full" or kind == "overlay",
             qq(kind) & " is neither; leaving it to be inferred is what " &
             "produced a target holding aowlspt\\ and no game at all")

  # 3. the four files that are the install, and the tools that check them.
  let a = joinPath(c.payloadDir, "aowlspt")
  require1("the IL2CPP client host is staged",
           fileExists(joinPath(a, "aowlspt-host-il2cpp.dll")),
           "without it the game starts with no mods in it")
  require1("the launcher is staged",
           fileExists(joinPath(a, "aowlspt-launch.exe")),
           "without it there is no way to start the game with the host inside")
  require1("the backend is staged",
           fileExists(joinPath(a, "aowlspt-backend.exe")),
           "without it the client has nothing to talk to")
  require1("the registry is staged",
           fileExists(joinPath(a, "registry\\mods.json")),
           "the mod manager would come up managing nothing, and say so only " &
           "in a log nobody reads until something is already wrong")
  require1("the installer is built",
           fileExists(joinPath(c.buildDir, "aowlspt-install.exe")),
           "a release with no installer in it is a pile of files and a guess " &
           "about where they go")
  require1("aowlspt-verify is built",
           fileExists(joinPath(c.buildDir, "aowlspt-verify.exe")),
           "run `aowl build`")
  require1("aowl-regcheck is built",
           fileExists(joinPath(c.buildDir, "aowl-regcheck.exe")),
           "run `aowl build`")

  # 4. every mod the registry names has a library staged beside its config.
  #    This is the failure installer/payload/README.md documents: a mod whose
  #    build failed stages as a directory full of settings nothing reads, and
  #    the host, which loads by scanning for .dll, says nothing at all.
  if not readBytes(joinPath(c.repo, "registry\\mods.json"), c.regText):
    refuse("the registry is readable", "no registry\\mods.json in " & c.repo)
  else:
    readRegistry(c.regText, c.mods, c.lists)
    require1("the registry declares a schema this build knows",
             asText(json.field(c.regText, "schema")) == "aowlspt.registry/1",
             qq(asText(json.field(c.regText, "schema"))) & " is not it")
    for m in c.mods:
      if m.srcKind != "intree":
        continue
      let dir = joinPath(joinPath(a, "mods"), m.artDir)
      let lib = joinPath(dir, m.artLib)
      require1(m.id & " has a library staged", fileExists(lib),
               "the registry names it and " & lib & " is not there, so it " &
               "would install as a directory nothing loads")
      # The host and aowlspt-verify both find a mod's library by its
      # directory's own name. A library called anything else is present,
      # ignored, and unreported.
      require1(m.id & "'s library is named after its directory",
               toLowerAscii(m.artLib) == toLowerAscii(m.artDir) & ".dll",
               m.artLib & " in mods\\" & m.artDir &
               " is not what the loader scans for")

  if gRefusals > 0:
    return false

  # 5. the registry against the mods that exist. The one check that reads each
  #    mod's own `exportMod` rather than the manifest's claim about it.
  var out1 = ""
  let rc = runTool(joinPath(c.buildDir, "aowl-regcheck.exe"),
                   "--repo " & qq(c.repo) & " -q", out1)
  if rc == 0 and find(out1, "error") < 0:
    ok "aowl-regcheck passes"
  else:
    refuse("aowl-regcheck passes",
           "the registry and the mods in this tree disagree, and shipping " &
           "cannot settle it")
    for l in splitLines(out1):
      if find(l, "error") >= 0:
        line "        " & l

  # 6. the staged tree, through the same verifier a player runs against a
  #    finished install. `--staged` turns off only the checks that need a game.
  var out2 = ""
  let vc = runTool(joinPath(c.buildDir, "aowlspt-verify.exe"),
                   "--offline --staged --root " & qq(c.payloadDir) & " -q",
                   out2)
  if vc == 0:
    ok "aowlspt-verify --offline passes against the staged tree"
  else:
    refuse("aowlspt-verify --offline passes against the staged tree",
           "the payload does not add up to an install")
    for l in splitLines(out2):
      if find(l, "error") >= 0:
        line "        " & l

  result = gRefusals == 0

# ------------------------------------------------------------------- manifest

proc manifestText(title: string; entries: seq[ZipEntry]): string =
  ## Every file in the archive, its SHA-256 and its size, sorted. Not the
  ## manifest itself: a document cannot carry its own hash, which is what the
  ## sidecar `.sha256` beside the archive is for.
  result = "# " & title & "\n"
  result.add "# sha256  bytes  path\n"
  result.add "# the archive's own hash is in the .sha256 file beside it\n"
  for e in entries:
    result.add sha256Hex(e.data)
    result.add "  "
    result.add $e.data.len
    result.add "  "
    result.add e.name
    result.add "\n"

proc modsTsv(mods: seq[RegMod]): string =
  ## id, version, library -- the machine-readable half of the changelog, and
  ## what the next release diffs against.
  result = ""
  for m in mods:
    result.add m.id & "\t" & m.version & "\t" & m.artDir & "/" & m.artLib & "\n"

proc previousMods(outDir, thisDir: string; fromDir: var string): seq[string] =
  ## The `MODS.tsv` of the newest earlier release staged in the same output
  ## directory. There is no git history here to read, and there is no need for
  ## one: a previous release left its own machine-readable list behind.
  result = @[]
  fromDir = ""
  if not isDirectory(outDir):
    return
  var files: seq[string] = @[]
  var dirs: seq[string] = @[]
  collectEntries(outDir, files, dirs)
  var best = ""
  for d in dirs:
    if find(d, "\\") >= 0:
      continue
    if not d.startsWith("aowlspt-"):
      continue
    if d == thisDir:
      continue
    if not fileExists(joinPath(joinPath(outDir, d), "MODS.tsv")):
      continue
    if d > best:
      best = d
  if best.len == 0:
    return
  var text = ""
  if not readBytes(joinPath(joinPath(outDir, best), "MODS.tsv"), text):
    return
  fromDir = best
  for l in splitLines(text):
    if l.len > 0:
      result.add l

proc fieldOf(line1: string; n: int): string =
  var i = 0
  var cur = ""
  var col = 0
  while i < line1.len:
    if line1[i] == '\t':
      if col == n: return cur
      cur = ""
      inc col
    else:
      cur.add line1[i]
    inc i
  if col == n: return cur
  result = ""

proc changelogText(c: Ctx; prev: seq[string]; prevFrom: string): string =
  ## Generated, every line of it, out of `registry/mods.json`, the staged
  ## payload and the previous release's own `MODS.tsv`. There is nothing here
  ## for anyone to remember to update, which is the only kind of changelog that
  ## cannot lie.
  result = "# aowlspt " & c.version & "\n\n"
  result.add "Everything below is generated from `registry/mods.json` and the\n"
  result.add "staged payload by `aowl release`. If a line here is wrong, the\n"
  result.add "tree is wrong.\n\n"
  result.add "News, early builds and support: " & Discord & "\n\n"
  let tv = asText(json.field(c.payloadText, "targetTarkovVersion"))
  let tb = asText(json.field(c.payloadText, "targetBackend"))
  let kind = asText(json.field(c.payloadText, "kind"))
  result.add "Built against Tarkov **" & tv & "** (" & tb & "), install kind `" &
             kind & "`.\n\n"
  result.add "## Mods\n\n"
  result.add "| id | version | library | license |\n"
  result.add "|---|---|---|---|\n"
  for m in c.mods:
    result.add "| " & m.id & " | " & m.version & " | " & m.artDir & "/" &
               m.artLib & " | " & m.license & " |\n"
  result.add "\n## Lists\n\n"
  for l in c.lists:
    result.add "- **" & l.id & "** -- " & l.name & ": "
    for h in l.inherits:
      result.add "inherits " & h & "; "
    var first = true
    for id in l.members:
      if not first: result.add ", "
      result.add id
      first = false
    result.add "\n"
  if prev.len > 0:
    result.add "\n## Against " & prevFrom & "\n\n"
    var changes = 0
    for m in c.mods:
      var was = ""
      var seen = false
      for p in prev:
        if fieldOf(p, 0) == m.id:
          was = fieldOf(p, 1)
          seen = true
      if not seen:
        result.add "- added **" & m.id & "** " & m.version & "\n"
        inc changes
      elif was != m.version:
        result.add "- **" & m.id & "** " & was & " -> " & m.version & "\n"
        inc changes
    for p in prev:
      let id = fieldOf(p, 0)
      var still = false
      for m in c.mods:
        if m.id == id: still = true
      if not still:
        result.add "- removed **" & id & "** (was " & fieldOf(p, 1) & ")\n"
        inc changes
    if changes == 0:
      result.add "- no mod changed version\n"
  result.add "\n## Verifying what you downloaded\n\n"
  result.add "```\n"
  result.add "certutil -hashfile <the .zip> SHA256\n"
  result.add "```\n"
  result.add "and compare it with the `.sha256` beside it. `MANIFEST.sha256`\n"
  result.add "inside the archive carries the same hash for every file in it.\n"

# ------------------------------------------------------------------- writing

proc writeOut(c: Ctx; stageDir: string; entries: seq[ZipEntry];
              stripPrefix: string): bool =
  ## The staging directory and the archive come from the same seq, so they
  ## cannot disagree about what a release contains.
  discard winfs.removeTree(stageDir)
  if not ensureDir(stageDir).ok:
    refuse("the output directory can be made", stageDir)
    return false
  for e in entries:
    var rel = e.name
    if stripPrefix.len > 0 and rel.startsWith(stripPrefix):
      rel = rel.substr(stripPrefix.len, rel.len - 1)
    var native = ""
    for ch in rel:
      if ch == '/': native.add '\\'
      else: native.add ch
    if not writeTextFile(joinPath(stageDir, native), e.data).ok:
      refuse("staging " & rel, "could not be written under " & stageDir)
      return false
  result = true

proc shapeCheck(zipPath: string; expect: seq[string]; underPrefix: string;
                forbidRoot: bool): bool =
  ## Opens the file that was just written and checks the shape *there*.
  ##
  ## SPT 4.x is the cautionary case: a server mod one directory too high does
  ## not error, it is simply never loaded, and the only symptom is a mod that
  ## does nothing. This project's own shape has the same property -- the host
  ## loads by scanning `aowlspt\mods\<name>` for `<name>.dll`, so a library at
  ## the wrong depth or under the wrong name is ignored in silence. Checking
  ## the written archive rather than the code that wrote it is the difference
  ## between testing the layout and testing the intention.
  heading "The archive, read back"
  var archive = ""
  if not readBytes(zipPath, archive):
    refuse("the archive can be read back", zipPath)
    return false
  var entries: seq[ZipEntry] = @[]
  var why = ""
  if not zipRead(archive, entries, why):
    refuse("the archive is a readable zip", why)
    return false
  ok $entries.len & " entries, every CRC checked against its own bytes"

  for name in expect:
    require1(name & " is in the archive", findEntry(entries, name) >= 0,
             "the shape rule this project installs by")

  var bad = 0
  for e in entries:
    if find(e.name, "\\") >= 0 or find(e.name, "../") >= 0 or
       e.name.startsWith("/") or find(e.name, ":") >= 0:
      err "  " & e.name & " is not a relative forward-slash path"
      inc bad
    let lower = toLowerAscii(e.name)
    if lower.endsWith(".pdb") or lower.endsWith(".lib") or
       lower.endsWith(".exp"):
      err "  " & e.name & " is build residue"
      inc bad
    if underPrefix.len > 0 and not e.name.startsWith(underPrefix):
      err "  " & e.name & " is outside " & underPrefix
      inc bad
  require1("every entry is a relative path with nothing build-shaped in it",
           bad == 0, $bad & " entries are not")

  if forbidRoot:
    # The wrong-depth trap, stated as a check -- and asked about the right
    # root. A `mods/` directory that is not under `aowlspt/` is read by
    # nothing: the installer copies `aowlspt/` and the host scans
    # `<target>\aowlspt\mods`.
    #
    # This used to test `e.name.startsWith("mods/")` against the raw entry
    # name, which for the bundle can never be true: every entry in it begins
    # `aowlspt-<version>/`. The check therefore passed on every release ever
    # cut, because the thing it looked for was unreachable -- which is worse
    # than not having the check, since the report said it had run. So the
    # prefix the archive actually uses comes off first, and the search having
    # found nothing to judge is itself a refusal.
    var stray = 0
    var mods = 0
    for e in entries:
      var rest = e.name
      if underPrefix.len > 0 and rest.startsWith(underPrefix):
        rest = rest.substr(underPrefix.len, rest.len - 1)
      if rest.startsWith("aowlspt/mods/") or
         rest.startsWith("payload/aowlspt/mods/"):
        inc mods
      elif rest.startsWith("mods/"):
        err "  " & e.name & " is where nothing reads mods\\"
        inc stray
    require1("no mod directory sits where nothing reads it", stray == 0,
             $stray & " entries would be silently ignored")
    require1("there are mods for that rule to have been about", mods > 0,
             "nothing in this archive is under aowlspt/mods/, so the depth " &
             "rule above judged an empty set and an install made from it " &
             "would load no mods at all")

  # The manifest, against the archive it describes.
  var mi = -1
  for i in 0 ..< entries.len:
    if entries[i].name.endsWith("MANIFEST.sha256"):
      mi = i
  if mi < 0:
    refuse("the archive carries a manifest", "no MANIFEST.sha256 in it")
    return false
  var listed = 0
  var wrong = 0
  for l in splitLines(entries[mi].data):
    if l.len == 0 or l[0] == '#':
      continue
    var parts: seq[string] = @[]
    var cur = ""
    for ch in l:
      if ch == ' ':
        if cur.len > 0: parts.add cur
        cur = ""
      else:
        cur.add ch
    if cur.len > 0: parts.add cur
    if parts.len < 3:
      continue
    inc listed
    let idx = findEntry(entries, parts[2])
    if idx < 0:
      err "  " & parts[2] & " is in the manifest and not in the archive"
      inc wrong
    elif sha256Hex(entries[idx].data) != parts[0]:
      err "  " & parts[2] & " does not hash to what the manifest says"
      inc wrong
  require1("every manifest line matches a file in the archive",
           wrong == 0 and listed > 0,
           $wrong & " mismatched, " & $listed & " listed")
  require1("the manifest accounts for every entry but itself",
           listed == entries.len - 1,
           $listed & " listed against " & $(entries.len - 1) & " entries")
  result = gRefusals == 0

proc guardOut(dir: string): bool =
  ## Two places this must never write. `D:\SPT` is the SPT install the earlier
  ## mods are tested against, and an install directory is not an output
  ## directory: dropping a release into one is how a tree ends up with a
  ## half-extracted archive in it that nothing removes.
  let low = toLowerAscii(absolutePathOf(dir))
  if low.startsWith("d:\\spt"):
    refuse("the output directory is not an install",
           dir & " is the SPT install; this program does not write there")
    return false
  if fileExists(joinPath(dir, "EscapeFromTarkov.exe")):
    refuse("the output directory is not a game directory",
           dir & " holds EscapeFromTarkov.exe")
    return false
  result = true

# ------------------------------------------------------------------- bundle

proc buildBundle(c: Ctx; checkOnly: bool): int =
  let prefix = "aowlspt-" & c.version & "/"
  let stageName = "aowlspt-" & c.version
  var entries: seq[ZipEntry] = @[]
  var skipped = 0

  heading "Assembling"
  if not addTree(entries, joinPath(c.payloadDir, "aowlspt"),
                 prefix & "payload/aowlspt/", skipped):
    refuse("the staged payload can be read", joinPath(c.payloadDir, "aowlspt"))
    return 1

  # payload.json, with its `version` taken from VERSION. Member-wise, so every
  # field this program does not know about goes back out byte for byte.
  var doc = parseObject(c.payloadText)
  let declared = asText(json.field(c.payloadText, "version"))
  setText(doc, "version", c.version)
  entries.addSorted ZipEntry(name: prefix & "payload/payload.json",
                             data: text(doc) & "\n")
  if declared != c.version:
    note "payload.json said version " & qq(declared) & "; the copy in the " &
         "archive says " & qq(c.version) & ", which is what VERSION says"

  discard addFile(entries, joinPath(c.payloadDir, "README.md"),
                  prefix & "payload/README.md")
  # The one document a person opens after extracting, so its presence is a
  # gate rather than a `discard`. An archive that ships an installer and no
  # instructions is a directory of executables.
  require1("INSTALL.md is in the archive",
           addFile(entries, joinPath(c.repo, "docs\\INSTALL.md"),
                   prefix & "INSTALL.md"),
           "no docs\\INSTALL.md in " & c.repo)

  # The tools a person needs on the other end: the installer, the verifier that
  # tells them whether it worked, and the probe that talks to the backend.
  # `aowl-importdb.exe` is in this list because INSTALL.md calls the database
  # step not optional and it is: an install without one answers every route out
  # of the emulator's fallbacks and has no items, traders or quests in it.
  # Until this went in, the only tool that could produce one lived in the repo,
  # so the archive documented a mandatory step it did not ship the tool for.
  let tools = ["aowlspt-install.exe", "aowlspt-verify.exe",
               "aowl-importdb.exe", "aowlprobe.exe"]
  var absent = ""
  for t in tools:
    if not addFile(entries, joinPath(c.buildDir, t), prefix & "install/" & t):
      if absent.len > 0: absent.add ", "
      absent.add t
  # Named rather than counted. "at least two of the tools" is satisfied by the
  # wrong two, and the two that matter are not interchangeable with the two
  # that are merely useful.
  require1("every tool the archive documents is in it", absent.len == 0,
           "could not read " & absent & " from " & c.buildDir &
           "; `aowl build` builds them")

  entries.addSorted ZipEntry(name: prefix & "VERSION",
                             data: c.version & "\n")
  entries.addSorted ZipEntry(name: prefix & "MODS.tsv", data: modsTsv(c.mods))
  var prevFrom = ""
  let prev = previousMods(c.outDir, stageName, prevFrom)
  entries.addSorted ZipEntry(name: prefix & "CHANGELOG.md",
                             data: changelogText(c, prev, prevFrom))
  entries.addSorted ZipEntry(name: prefix & "MANIFEST.sha256",
                             data: manifestText("aowlspt " & c.version,
                                                entries))
  if skipped > 0:
    note $skipped & " build-residue file(s) left out of the archive"

  var bytes = 0
  for e in entries:
    bytes = bytes + e.data.len
  ok $entries.len & " entries, " & $(bytes div 1024) & " KiB"
  if bytes > ZipMax:
    refuse("the archive fits in a zip without zip64",
           $bytes & " bytes is more than this writer will emit")
    return 1

  # "Everything, before it writes anything" is this program's stated contract,
  # and assembling is where the last of it happens: a tool that could not be
  # read, an INSTALL.md that is not there. Without this the run went on to
  # write a zip and a .sha256, failed the shape check against the file it had
  # just written, and exited 1 -- leaving a broken archive on disk with a hash
  # beside it, which is exactly the artifact somebody uploads by mistake.
  if gRefusals > 0:
    heading "Result"
    err $gRefusals & " refusal(s); nothing was written"
    return 1

  if checkOnly:
    heading "Result"
    ok "every gate passed; nothing written (--check-only)"
    return 0

  let zipName = "aowlspt-" & c.version & "-" & c.date & ".zip"
  let zipPath = joinPath(c.outDir, zipName)
  let stageDir = joinPath(c.outDir, stageName)

  heading "Writing"
  if not writeOut(c, stageDir, entries, prefix):
    return 1
  say "staged  " & stageDir
  let archive = zipBytes(entries)
  if not writeTextFile(zipPath, archive).ok:
    refuse("the archive can be written", zipPath)
    return 1
  say "archive " & zipPath
  let digest = sha256Hex(archive)
  discard writeTextFile(zipPath & ".sha256", digest & "  " & zipName & "\n")
  say "sha256  " & digest

  var want: seq[string] = @[]
  want.add prefix & "payload/payload.json"
  want.add prefix & "payload/aowlspt/aowlspt-host-il2cpp.dll"
  want.add prefix & "payload/aowlspt/aowlspt-launch.exe"
  want.add prefix & "payload/aowlspt/aowlspt-backend.exe"
  want.add prefix & "payload/aowlspt/registry/mods.json"
  want.add prefix & "install/aowlspt-install.exe"
  want.add prefix & "install/aowlspt-verify.exe"
  want.add prefix & "install/aowl-importdb.exe"
  want.add prefix & "INSTALL.md"
  want.add prefix & "CHANGELOG.md"
  want.add prefix & "VERSION"
  if not shapeCheck(zipPath, want, prefix, true):
    return 1

  heading "Result"
  line "  " & zipPath
  line "  " & digest
  line "  install with: install\\aowlspt-install.exe install --source " &
       "<vanilla> --target <new> --payload payload"
  ok "aowlspt " & c.version & " is a release"
  result = 0

# ------------------------------------------------------------------- one mod

proc buildModPackage(c: Ctx; wanted: string; checkOnly: bool): int =
  ## One mod, shaped as an **overlay payload**: a `payload.json` saying
  ## `"kind": "overlay"` at the root and `aowlspt/mods/<dir>/` beside it, which
  ## is what `aowlspt-install install --overlay --payload <extracted>` reads.
  ##
  ## The shape is the whole point. SPT 4.x taught this the expensive way: a
  ## server mod at `user/mods/` instead of `SPT_Runtime/user/mods/` produces no
  ## error at all, the mod simply never loads. Here the equivalent mistakes are
  ## `mods/<dir>/` at the root of the archive (nothing reads it) and a library
  ## not named after its directory (the host scans for `<dir>.dll` and finds
  ## nothing). Both are checked against the written file, below.
  var m = RegMod(id: "", name: "", version: "", author: "", license: "",
                 artDir: "", artLib: "", srcKind: "", srcPath: "")
  var found = false
  let lw = toLowerAscii(wanted)
  for r in c.mods:
    if toLowerAscii(r.id) == lw or toLowerAscii(r.artDir) == lw:
      m = r
      found = true
  if not found:
    refuse("the registry knows a mod called " & qq(wanted),
           "no entry whose id or artifact directory is that; " &
           "registry/mods.json names them all")
    return 1
  heading "Mod"
  line "  " & m.id & "  " & m.version & "  (" & m.name & ")"
  line "  library " & m.artDir & "/" & m.artLib
  line "  licence " & m.license

  let src = joinPath(joinPath(joinPath(c.payloadDir, "aowlspt"), "mods"),
                     m.artDir)
  require1("the mod is staged", isDirectory(src),
           src & " is not there; run `aowl build` then `aowl payload`")
  require1("the library is staged", fileExists(joinPath(src, m.artLib)),
           "a mod directory with no library in it installs as settings " &
           "nothing reads, and nothing says so")
  if gRefusals > 0:
    return 1

  var entries: seq[ZipEntry] = @[]
  var skipped = 0
  if not addTree(entries, src, "aowlspt/mods/" & m.artDir & "/", skipped):
    refuse("the mod's files can be read", src)
    return 1

  # An overlay payload of its own, carrying the same client declaration the
  # bundle does -- the installer refuses a payload that will not say.
  var doc = newDoc()
  setText(doc, "name", m.name)
  setText(doc, "version", m.version)
  setText(doc, "targetTarkovVersion",
          asText(json.field(c.payloadText, "targetTarkovVersion")))
  setText(doc, "targetBackend",
          asText(json.field(c.payloadText, "targetBackend")))
  setText(doc, "kind", "overlay")
  entries.addSorted ZipEntry(name: "payload.json", data: text(doc) & "\n")

  var readme = "# " & m.name & " " & m.version & "\n\n"
  readme.add "News, early builds and support: " & Discord & "\n\n"
  readme.add "An aowlspt **overlay payload**. It adds one mod to an install " &
             "that already\nexists; it never mirrors a client.\n\n"
  readme.add "```\naowlspt-install install --overlay --target <your install> " &
             "--payload .\n```\n\n"
  # Where that program comes from. An overlay zip carries a mod and nothing
  # else, so a person who has only ever downloaded one of these has no
  # installer -- and "run aowlspt-install" is not an instruction until they
  # know where it is.
  readme.add "`aowlspt-install.exe` is in the `install\\` directory of the " &
             "main aowlspt\narchive; an overlay adds to an install that one " &
             "already made.\n\n"
  readme.add "Built against Tarkov " &
             asText(json.field(c.payloadText, "targetTarkovVersion")) & " (" &
             asText(json.field(c.payloadText, "targetBackend")) & ").\n"
  readme.add "Registry id `" & m.id & "`, licence " & m.license & ", by " &
             m.author & ".\n\n"
  readme.add "`MANIFEST.sha256` lists every file here with its SHA-256.\n"
  entries.addSorted ZipEntry(name: "README.md", data: readme)
  entries.addSorted ZipEntry(name: "MANIFEST.sha256",
                             data: manifestText(m.id & " " & m.version,
                                                entries))
  if skipped > 0:
    note $skipped & " build-residue file(s) left out of the archive"

  if checkOnly:
    heading "Result"
    ok "every gate passed; nothing written (--check-only)"
    return 0

  let zipName = "aowlspt-" & m.artDir & "-" & m.version & ".zip"
  let zipPath = joinPath(c.outDir, zipName)
  let stageDir = joinPath(c.outDir, "aowlspt-" & m.artDir & "-" & m.version)

  heading "Writing"
  if not writeOut(c, stageDir, entries, ""):
    return 1
  say "staged  " & stageDir
  let archive = zipBytes(entries)
  if not writeTextFile(zipPath, archive).ok:
    refuse("the archive can be written", zipPath)
    return 1
  say "archive " & zipPath
  let digest = sha256Hex(archive)
  discard writeTextFile(zipPath & ".sha256", digest & "  " & zipName & "\n")
  say "sha256  " & digest

  var want: seq[string] = @[]
  want.add "payload.json"
  want.add "README.md"
  want.add "aowlspt/mods/" & m.artDir & "/" & m.artLib
  if not shapeCheck(zipPath, want, "", true):
    return 1

  # The two rules that fail silently, asserted against the file rather than
  # against the code that wrote it.
  var archive2 = ""
  discard readBytes(zipPath, archive2)
  var back: seq[ZipEntry] = @[]
  var why = ""
  discard zipRead(archive2, back, why)
  var outside = 0
  for e in back:
    if e.name == "payload.json" or e.name == "README.md" or
       e.name == "MANIFEST.sha256":
      continue
    if not e.name.startsWith("aowlspt/mods/" & m.artDir & "/"):
      err "  " & e.name & " is not under aowlspt/mods/" & m.artDir
      inc outside
  require1("every file lands under aowlspt\\mods\\" & m.artDir, outside == 0,
           $outside & " would extract somewhere nothing reads")
  require1("the library is named after its directory",
           toLowerAscii(m.artLib) == toLowerAscii(m.artDir) & ".dll",
           m.artLib & " is not what the host scans for")
  if gRefusals > 0:
    return 1

  heading "Result"
  line "  " & zipPath
  line "  " & digest
  ok m.id & " " & m.version & " is packaged"
  result = 0

# ------------------------------------------------------------------- main

proc repoRoot(): string =
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

proc main(): int =
  crcInit()
  var repo = ""
  var outDir = ""
  var modName = ""
  var date = ""
  var checkOnly = false
  var i = 1
  let n = paramCount()
  while i <= n:
    let a = paramStr(i)
    if a == "--repo":
      inc i
      if i <= n: repo = paramStr(i)
    elif a == "--out":
      inc i
      if i <= n: outDir = paramStr(i)
    elif a == "--mod":
      inc i
      if i <= n: modName = paramStr(i)
    elif a == "--date":
      inc i
      if i <= n: date = paramStr(i)
    elif a == "--check-only":
      checkOnly = true
    elif a == "--quiet" or a == "-q":
      setVerbosity vQuiet
    elif a == "--help" or a == "-h":
      echo Usage
      return 0
    elif a == "--verbose" or a == "-v" or a == "--debug":
      discard   # accepted so `aowl release -v` is not an error
    elif a.startsWith("-"):
      fatal "unknown option: " & a
    elif modName.len == 0:
      modName = a
    inc i

  if repo.len == 0:
    repo = repoRoot()
  repo = absolutePathOf(repo)
  if outDir.len == 0:
    outDir = joinPath(repo, "dist")
  outDir = absolutePathOf(outDir)
  if date.len == 0:
    date = todayUtc()

  heading "aowl release"
  line "  repo   " & repo
  line "  out    " & outDir

  var c = Ctx(repo: repo, outDir: outDir,
              payloadDir: joinPath(repo, "installer\\payload"),
              buildDir: joinPath(repo, "installer\\build"),
              version: "", date: date, regText: "", payloadText: "",
              mods: @[], lists: @[])

  if not guardOut(outDir):
    return 1
  if not gates(c):
    heading "Result"
    err $gRefusals & " refusal(s); nothing was written"
    note "a release that installs into a directory nothing loads is the " &
         "failure this refuses to package"
    return 1

  if not checkOnly:
    if not ensureDir(outDir).ok:
      err "could not make " & outDir
      return 1

  if modName.len > 0:
    result = buildModPackage(c, modName, checkOnly)
  else:
    result = buildBundle(c, checkOnly)
  if gRefusals > 0 and result == 0:
    result = 1

quit(main())
