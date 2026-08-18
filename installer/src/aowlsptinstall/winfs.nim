## The filesystem operations an installer needs and nimony's stdlib does not
## have: copy, hard link, recursive walk, recursive remove.
##
## Everything here is Win32 rather than libc, for two reasons that matter at
## this scale. A Tarkov install is ~40 GB across tens of thousands of files, so
## `CopyFileW` (which the kernel can service without the bytes ever entering
## this process) beats a read/write loop by a wide margin. And `CreateHardLinkW`
## lets a whole install be "copied" in seconds and zero bytes when source and
## destination share a volume -- which is the normal case, and is the difference
## between an installer you run and one you schedule.

import std/[dirs, paths, syncio, strutils, algorithm]
import std/private/oscommons
import std/windows/winlean
import std/widestrs

export fileExists, dirExists, symlinkExists

type
  FsResult* = object
    ok*: bool
    err*: int32   ## GetLastError() when `ok` is false, 0 otherwise

const
  ErrAlreadyExists* = 183'i32
  ErrPathNotFound* = 3'i32
  ErrAccessDenied* = 5'i32
  ErrNotSameDevice* = 17'i32

proc good(): FsResult =
  result = FsResult(ok: true, err: 0'i32)

proc bad(): FsResult =
  result = FsResult(ok: false, err: getLastError())

proc toWide(s: string): WideCStringObj =
  ## `newWideCString` takes its argument by `var`, and a WideCStringObj built
  ## from a temporary would have its buffer freed before the Win32 call reads
  ## it. Binding through a local `var` is what keeps the bytes alive.
  var t = s
  result = newWideCString(t)

# --------------------------------------------------------------- paths

proc normSep*(p: string): string =
  ## Win32 accepts both separators, but paths here get compared, joined and
  ## printed, so they are normalised once on the way in.
  result = ""
  for ch in p:
    if ch == '/':
      result.add '\\'
    else:
      result.add ch

proc joinPath*(a, b: string): string =
  if a.len == 0:
    result = normSep(b)
  elif b.len == 0:
    result = normSep(a)
  else:
    result = normSep(a)
    if result[result.len - 1] != '\\':
      result.add '\\'
    let tail = normSep(b)
    var start = 0
    while start < tail.len and tail[start] == '\\':
      inc start
    result.add tail.substr(start)

proc parentOf*(p: string): string =
  let q = normSep(p)
  var i = q.len - 1
  while i >= 0 and q[i] == '\\':
    dec i
  while i >= 0 and q[i] != '\\':
    dec i
  if i <= 0:
    result = ""
  else:
    result = q.substr(0, i - 1)

proc baseName*(p: string): string =
  let q = normSep(p)
  var i = q.len - 1
  while i >= 0 and q[i] == '\\':
    dec i
  let last = i
  while i >= 0 and q[i] != '\\':
    dec i
  if last < 0:
    result = ""
  else:
    result = q.substr(i + 1, last)

proc driveOf*(p: string): string =
  ## The volume a path lives on, as an upper-case drive letter. Used to decide
  ## whether hard linking is even possible; UNC shares and NT paths return ""
  ## on purpose so the caller falls back to copying.
  let q = normSep(p)
  if q.len >= 2 and q[1] == ':':
    result = toUpperAscii($q[0])
  else:
    result = ""

proc sameVolume*(a, b: string): bool =
  let da = driveOf(a)
  let db = driveOf(b)
  result = da.len > 0 and da == db

proc absolutePathOf*(p: string): string =
  ## Resolves `.`, `..` and relative paths against the current directory,
  ## because every path the installer records in its journal must still name
  ## the same directory when uninstall runs later from somewhere else.
  let w = toWide(p)
  var part = cast[WideCString](0)
  let n = getFullPathNameW(w.toWideCString, 0'i32, cast[WideCString](0), part)
  if n <= 0'i32:
    result = normSep(p)
    return
  # The first call with a null buffer returns the required length; ask again
  # with a real one. Two calls avoid guessing at MAX_PATH, which a Tarkov
  # install's StreamingAssets tree comfortably exceeds.
  var buf = newString(int(n) + 1)
  var wide = newWideCString(buf)
  let n2 = getFullPathNameW(w.toWideCString, n + 1'i32, wide.toWideCString, part)
  if n2 <= 0'i32:
    result = normSep(p)
  else:
    result = $wide

proc isUnder*(child, parent: string): bool =
  ## Whether `child` is `parent` or lives inside it. The installer uses this to
  ## refuse to write a destination that sits inside the source install, which
  ## would otherwise recurse forever through its own output.
  let c = toLowerAscii(absolutePathOf(child))
  let p = toLowerAscii(absolutePathOf(parent))
  if c == p:
    return true
  if c.len <= p.len:
    return false
  result = c.substr(0, p.len - 1) == p and c[p.len] == '\\'

# --------------------------------------------------------------- attributes

proc attributesOf*(p: string): int32 =
  let w = toWide(p)
  result = getFileAttributesW(w.toWideCString)

proc exists*(p: string): bool =
  result = attributesOf(p) != -1'i32

proc isDirectory*(p: string): bool =
  let a = attributesOf(p)
  result = a != -1'i32 and (a.uint32 and FILE_ATTRIBUTE_DIRECTORY) != 0'u32

proc clearReadOnly*(p: string): bool =
  ## A game install ships read-only files and `DeleteFileW` refuses those. The
  ## installer clears the bit rather than failing, but only on paths it has
  ## already decided to remove.
  let a = attributesOf(p)
  if a == -1'i32:
    return false
  if (a.uint32 and FILE_ATTRIBUTE_READONLY) == 0'u32:
    return true
  let w = toWide(p)
  let cleared = int32(a.uint32 and (not FILE_ATTRIBUTE_READONLY))
  result = setFileAttributesW(w.toWideCString, cleared) != WINBOOL(0)

# --------------------------------------------------------------- directories

proc createDirOne(p: string): FsResult =
  let w = toWide(p)
  if createDirectoryW(w.toWideCString) != 0'i32:
    result = good()
  else:
    let e = getLastError()
    if e == ErrAlreadyExists:
      result = good()
    else:
      result = FsResult(ok: false, err: e)

proc ensureDir*(p: string): FsResult =
  ## `mkdir -p`. Walks up collecting what is missing, then creates downward, so
  ## a destination six levels deep does not need the caller to build the chain.
  let full = normSep(p)
  if full.len == 0:
    return good()
  if isDirectory(full):
    return good()

  var parts: seq[string] = @[]
  var cur = full
  while cur.len > 0 and not isDirectory(cur):
    parts.add cur
    let up = parentOf(cur)
    if up.len == 0 or up == cur:
      break
    cur = up

  # `parts` came out deepest-first; create shallowest-first.
  var i = parts.len - 1
  while i >= 0:
    let r = createDirOne(parts[i])
    if not r.ok:
      return r
    dec i
  result = good()

# --------------------------------------------------------------- files

proc removeFileAt*(p: string): FsResult =
  if not exists(p):
    return good()
  discard clearReadOnly(p)
  let w = toWide(p)
  if deleteFileW(w.toWideCString) != WINBOOL(0):
    result = good()
  else:
    result = bad()

proc copyFileAt*(src, dst: string; overwrite = true): FsResult =
  ## Overwriting is the default because the installer is idempotent by design:
  ## running it twice must converge on the same install, not fail halfway.
  ##
  ## The existing destination is *deleted* rather than overwritten, and that is
  ## not a detail. `CopyFileW` opens the destination with CREATE_ALWAYS, which
  ## truncates the file that is already there -- and if that file is a hard
  ## link into a mirrored install, truncating it truncates the original. An
  ## installer that corrupts the game directory it copied from is worse than
  ## one that does not run, so the link is broken first and every write lands
  ## on a file of its own.
  let parent = parentOf(dst)
  if parent.len > 0:
    let mk = ensureDir(parent)
    if not mk.ok:
      return mk
  if overwrite and exists(dst):
    let rm = removeFileAt(dst)
    if not rm.ok:
      return rm
  let a = toWide(src)
  let b = toWide(dst)
  let failIfExists = if overwrite: WINBOOL(0) else: WINBOOL(1)
  if copyFileW(a.toWideCString, b.toWideCString, failIfExists) != WINBOOL(0):
    result = good()
  else:
    result = bad()

proc hardLinkAt*(src, dst: string): FsResult =
  ## Reports failure rather than silently falling back, so the caller can
  ## decide. A link that cannot be made on one file usually means the strategy
  ## is wrong for this pair of directories (different volume, FAT32, a network
  ## share), and learning that on file one is much better than on file 30 000.
  let parent = parentOf(dst)
  if parent.len > 0:
    let mk = ensureDir(parent)
    if not mk.ok:
      return mk
  if exists(dst):
    let rm = removeFileAt(dst)
    if not rm.ok:
      return rm
  let a = toWide(dst)
  let b = toWide(src)
  if createHardLinkW(a.toWideCString, b.toWideCString, cast[pointer](0)) != 0'i32:
    result = good()
  else:
    result = bad()

proc fileSizeOf*(p: string): int64 =
  ## -1 when the size cannot be read. Taken from the directory entry rather than
  ## by opening the file, so it works on files the game has locked.
  result = -1'i64
  var data = default(WIN32_FIND_DATA)
  let w = toWide(p)
  let h = findFirstFileW(w.toWideCString, data)
  if h == INVALID_HANDLE_VALUE:
    return
  discard findClose(h)
  let high64 = uint64(uint32(data.nFileSizeHigh)) shl 32
  result = int64(high64 or uint64(uint32(data.nFileSizeLow)))

# --------------------------------------------------------------- walking

proc collectEntries*(root: string; files: var seq[string]; dirs: var seq[string]) =
  ## Depth-first walk collecting paths relative to `root`. The recursion is an
  ## explicit stack rather than a recursive iterator (nimony has none), and the
  ## caller gets the whole list up front -- which it wants anyway, since it
  ## reports the file count before doing any work.
  let base = normSep(root)
  var stack: seq[string] = @[base]
  while stack.len > 0:
    let dir = stack[stack.len - 1]
    shrink(stack, stack.len - 1)
    try:
      for (kind, entry) in walkDir(path(dir)):
        let full = normSep($entry)
        var rel = full
        if full.len > base.len + 1 and toLowerAscii(full.substr(0, base.len - 1)) == toLowerAscii(base):
          rel = full.substr(base.len + 1)
        if kind == pcDir or kind == pcLinkToDir:
          dirs.add rel
          stack.add full
        else:
          files.add rel
    except:
      # A directory that cannot be opened is not fatal to the walk; the caller
      # notices via the file count it expected.
      discard

proc byLengthDesc(a, b: string): int =
  result = b.len - a.len

proc removeTree*(p: string): FsResult =
  ## Recursive delete: files first, then directories deepest-first, because
  ## `RemoveDirectoryW` only removes empty ones. Sorting by path length
  ## descending is a valid deepest-first order, since a child path is always
  ## longer than its parent.
  if not exists(p):
    return good()
  if not isDirectory(p):
    return removeFileAt(p)

  var files: seq[string] = @[]
  var dirs: seq[string] = @[]
  collectEntries(p, files, dirs)

  for rel in files:
    let r = removeFileAt(joinPath(p, rel))
    if not r.ok:
      return r

  sort(dirs, byLengthDesc)

  for rel in dirs:
    let full = joinPath(p, rel)
    discard clearReadOnly(full)
    let w = toWide(full)
    if removeDirectoryW(w.toWideCString) == 0'i32:
      let e = getLastError()
      if e != ErrPathNotFound:
        return FsResult(ok: false, err: e)

  discard clearReadOnly(p)
  let w = toWide(p)
  if removeDirectoryW(w.toWideCString) != 0'i32:
    result = good()
  else:
    let e = getLastError()
    if e == ErrPathNotFound:
      result = good()
    else:
      result = FsResult(ok: false, err: e)

# --------------------------------------------------------------- text

proc readTextFile*(p: string; into: var string): bool =
  into = ""
  var f: File
  if not open(f, p, fmRead):
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

proc writeTextFile*(p, content: string): FsResult =
  ## As with `copyFileAt`, an existing destination is removed rather than
  ## opened: opening it for writing would write through a hard link into the
  ## install this one was mirrored from.
  let parent = parentOf(p)
  if parent.len > 0:
    let mk = ensureDir(parent)
    if not mk.ok:
      return mk
  if exists(p):
    let rm = removeFileAt(p)
    if not rm.ok:
      return rm
  if tryWriteFile(p, content):
    result = good()
  else:
    result = bad()
