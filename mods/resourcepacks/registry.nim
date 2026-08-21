## registry.nim — scan the packs directory, resolve the enabled stack into one
## flattened override map, and feed it to the two existing render paths.
##
## The registry is an ORCHESTRATOR, not a second renderer. It never hooks
## anything and owns no Present. It produces two artifacts and hands each to
## machinery that already exists:
##
##   1. a flattened texture manifest, in the exact `{ "entries": [...] }` shape
##      the texture mod's `manifest.nim::loadManifest` reads, written to a file
##      the texture mod is pointed at. `file` fields are ABSOLUTE, and the
##      texture mod is configured with `packRoot=""`, so its `resolvedPath`
##      returns each path verbatim. That is the whole texture integration — the
##      swap hook, the byte-verify, the VRAM budget and the swapMode ladder all
##      stay in the texture mod, unchanged.
##
##   2. a merged grade params object, in the graphics mod's flat-key format,
##      pushed through the existing `aowlspt.host::gfx_apply` host call — the
##      same driven-mode Present the graphics mod already owns. No second hook.
##
## STACK ORDER: the enabled list is ordered low→high priority. Index 0 is the
## base; each later pack overrides earlier ones on a conflicting texture name or
## grade key — exactly like Minecraft's pack list, top of the applied list
## winning. The flatten walks the order and last-writer-wins per key.

import std/syncio
import aowlspt
import aowlspt/json
import packmanifest

# ---------------------------------------------------------------------------
# Filesystem: list sub-directories, test a path. nimony has no dir API, so this
# is a tiny Win32 shim, the same emit discipline the texture mod uses for its
# byte-copy. Lengths are passed explicitly rather than relying on nim strings
# being NUL-terminated.
# ---------------------------------------------------------------------------

{.emit: """
#include <windows.h>
#include <string.h>
#include <stdio.h>
static int aowl_rp_list_subdirs(const char* dir, int dirLen,
                                char* out, int cap) {
  char pat[1024];
  WIN32_FIND_DATAA fd;
  HANDLE h;
  int used = 0;
  if (!dir || !out || cap <= 1 || dirLen <= 0 || dirLen > 1000) return 0;
  memcpy(pat, dir, (size_t)dirLen);
  pat[dirLen] = '\\'; pat[dirLen+1] = '*'; pat[dirLen+2] = 0;
  h = FindFirstFileA(pat, &fd);
  if (h == INVALID_HANDLE_VALUE) return 0;
  do {
    if (!(fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) continue;
    if (fd.cFileName[0]=='.' && (fd.cFileName[1]==0 ||
        (fd.cFileName[1]=='.' && fd.cFileName[2]==0))) continue;
    {
      int n = (int)strlen(fd.cFileName);
      if (used + n + 1 >= cap) break;
      memcpy(out+used, fd.cFileName, (size_t)n);
      used += n;
      out[used++] = '\n';
    }
  } while (FindNextFileA(h, &fd));
  FindClose(h);
  out[used] = 0;
  return used;
}
static int aowl_rp_exists(const char* p, int pLen) {
  char buf[1024];
  DWORD a;
  if (!p || pLen <= 0 || pLen > 1000) return 0;
  memcpy(buf, p, (size_t)pLen);
  buf[pLen] = 0;
  a = GetFileAttributesA(buf);
  return (a != INVALID_FILE_ATTRIBUTES) ? 1 : 0;
}
""".}

proc listSubdirsC(dir: pointer; dirLen: int32; outp: pointer;
                  cap: int32): int32 {.importc: "aowl_rp_list_subdirs", nodecl.}
proc pathExistsC(p: pointer; pLen: int32): int32 {.
  importc: "aowl_rp_exists", nodecl.}

proc dataPtr(s: string): pointer = cast[pointer](slice(s).data)

proc listSubdirs*(dir: string): seq[string] =
  ## The immediate sub-directory names of `dir`, in the order the filesystem
  ## returns them. Empty on any failure (a missing packs dir is not an error —
  ## it just means no packs).
  result = @[]
  if dir.len == 0:
    return
  var buf = newString(65536)
  let used = listSubdirsC(dataPtr(dir), int32(dir.len), dataPtr(buf),
                          int32(buf.len))
  if used <= 0:
    return
  var cur = ""
  for i in 0 ..< int(used):
    let c = buf[i]
    if c == '\n':
      if cur.len > 0: result.add cur
      cur = ""
    else:
      cur.add c
  if cur.len > 0: result.add cur

proc pathExists*(p: string): bool =
  if p.len == 0: return false
  result = pathExistsC(dataPtr(p), int32(p.len)) != 0'i32

# ---------------------------------------------------------------------------
# Scanning
# ---------------------------------------------------------------------------

var gScanned: seq[Pack] = @[]

proc packCount*(): int = gScanned.len
proc packId*(i: int): string = gScanned[i].id
proc packName*(i: int): string = gScanned[i].name
proc packVersion*(i: int): string = gScanned[i].version
proc packAuthor*(i: int): string = gScanned[i].author
proc packDescription*(i: int): string = gScanned[i].description
proc packValid*(i: int): bool = gScanned[i].valid
proc packError*(i: int): string = gScanned[i].error
proc packHasTextures*(i: int): bool = gScanned[i].hasTextures
proc packHasGrade*(i: int): bool = gScanned[i].hasGrade

proc indexOfId*(id: string): int =
  for i in 0 ..< gScanned.len:
    if gScanned[i].id == id: return i
  result = -1

proc scanPacks*(packsDir: string): int =
  ## Discover every pack folder under `packsDir` and parse its manifest. Both
  ## valid and invalid packs are kept (so the settings page can show *why* a
  ## pack is greyed out); only valid ones are ever flattened. Returns the count.
  gScanned = @[]
  for name in listSubdirs(packsDir):
    let root = packsDir & "/" & name
    gScanned.add parsePack(name, root)
  result = gScanned.len

# ---------------------------------------------------------------------------
# Resolving the enabled stack
# ---------------------------------------------------------------------------
#
# The flatten is last-writer-wins over the enabled order. A texture name or a
# grade key set by a later (higher-priority) pack replaces the same key from an
# earlier one. Missing texture files are dropped per-entry with the pack still
# counted — the same fail-soft the texture mod applies to a missing image.

type
  Resolved* = object
    texNames*: seq[string]
    texFiles*: seq[string]   ## absolute paths
    texMaps*: seq[string]
    texCats*: seq[string]
    texTiers*: seq[string]
    texConfs*: seq[float]
    gradeKeys*: seq[string]
    gradeVals*: seq[string]
    missingFiles*: int
    contributingTexPacks*: int
    contributingGradePacks*: int

proc newResolved(): Resolved =
  Resolved(texNames: @[], texFiles: @[], texMaps: @[], texCats: @[],
           texTiers: @[], texConfs: @[], gradeKeys: @[], gradeVals: @[],
           missingFiles: 0, contributingTexPacks: 0, contributingGradePacks: 0)

proc texIndexOf(r: Resolved; name: string): int =
  for i in 0 ..< r.texNames.len:
    if r.texNames[i] == name: return i
  result = -1

proc gradeIndexOf(r: Resolved; key: string): int =
  for i in 0 ..< r.gradeKeys.len:
    if r.gradeKeys[i] == key: return i
  result = -1

proc resolveStack*(order: seq[string]): Resolved =
  ## `order` is the enabled pack ids, low→high priority. Walk it in order so a
  ## later pack's write lands last and wins.
  result = newResolved()
  for id in order:
    let idx = indexOfId(id)
    if idx < 0 or not gScanned[idx].valid:
      continue
    let root = gScanned[idx].root
    var contributedTex = false
    for t in 0 ..< gScanned[idx].textures.len:
      let ov = gScanned[idx].textures[t]
      let abs = root & "/" & ov.file
      if not pathExists(abs):
        result.missingFiles = result.missingFiles + 1
        continue
      contributedTex = true
      let existing = texIndexOf(result, ov.name)
      if existing >= 0:
        result.texFiles[existing] = abs
        result.texMaps[existing] = ov.map
        result.texCats[existing] = ov.cat
        result.texTiers[existing] = ov.tier
        result.texConfs[existing] = ov.conf
      else:
        result.texNames.add ov.name
        result.texFiles.add abs
        result.texMaps.add ov.map
        result.texCats.add ov.cat
        result.texTiers.add ov.tier
        result.texConfs.add ov.conf
    if contributedTex:
      result.contributingTexPacks = result.contributingTexPacks + 1

    var contributedGrade = false
    for g in 0 ..< gScanned[idx].gradeKeys.len:
      let k = gScanned[idx].gradeKeys[g]
      let v = gScanned[idx].gradeVals[g]
      contributedGrade = true
      let existing = gradeIndexOf(result, k)
      if existing >= 0:
        result.gradeVals[existing] = v
      else:
        result.gradeKeys.add k
        result.gradeVals.add v
    if contributedGrade:
      result.contributingGradePacks = result.contributingGradePacks + 1

proc resolvedTexCount*(r: Resolved): int = r.texNames.len
proc resolvedGradeCount*(r: Resolved): int = r.gradeKeys.len

# ---------------------------------------------------------------------------
# Emitting into the existing texture path
# ---------------------------------------------------------------------------

proc jsonEscape(s: string): string =
  result = ""
  for ch in s:
    case ch
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    else: result.add ch

proc texManifestJson*(r: Resolved): string =
  ## The flattened manifest in the texture mod's own format: an object with an
  ## `entries` array of `{name,file,map,cat,tier,conf}`, sorted by name (the
  ## texture mod binary-searches a sorted manifest, with a linear fallback).
  ## `file` is absolute, so the texture mod's `packRoot` must be "".
  # insertion sort on a small array of indices — the enabled set is tens of
  # entries, not thousands, so simplicity beats cleverness here.
  var idxs: seq[int] = @[]
  for i in 0 ..< r.texNames.len: idxs.add i
  for a in 1 ..< idxs.len:
    let key = idxs[a]
    var b = a - 1
    while b >= 0 and r.texNames[idxs[b]] > r.texNames[key]:
      let moved = idxs[b]
      idxs[b + 1] = moved
      dec b
    idxs[b + 1] = key
  result = "{\"entries\":["
  for n in 0 ..< idxs.len:
    let i = idxs[n]
    if n > 0: result.add ","
    result.add "{\"name\":\"" & jsonEscape(r.texNames[i]) &
      "\",\"file\":\"" & jsonEscape(r.texFiles[i]) &
      "\",\"map\":\"" & jsonEscape(r.texMaps[i]) &
      "\",\"cat\":\"" & jsonEscape(r.texCats[i]) &
      "\",\"tier\":\"" & jsonEscape(r.texTiers[i]) &
      "\",\"conf\":" & $r.texConfs[i] & "}"
  result.add "]}"

proc writeTextFile*(path, content: string): bool =
  var f: File
  if not open(f, path, fmWrite):
    return false
  write(f, content)
  close(f)
  result = true

# ---------------------------------------------------------------------------
# Emitting into the existing graphics path
# ---------------------------------------------------------------------------

proc gradeParamsJson*(r: Resolved; enabled: bool): string =
  ## The compact flat object `gfx_apply` parses. Only the keys the stack set are
  ## written on top of `enabled`; every key the native module does not receive
  ## keeps its current value, so a pack that sets only `contrast` nudges nothing
  ## else. Bools/ints/floats go out as their raw JSON tokens (the pack authored
  ## them in the graphics mod's own numeric convention: bools as 0/1).
  result = "{\"enabled\":" & (if enabled: "1" else: "0")
  for i in 0 ..< r.gradeKeys.len:
    result.add ",\"" & jsonEscape(r.gradeKeys[i]) & "\":" & r.gradeVals[i]
  result.add "}"
