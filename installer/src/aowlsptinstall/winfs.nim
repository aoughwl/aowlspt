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

# `Handle` is re-exported for the held-handle facility at the bottom of this
# module: a caller that keeps a file open has to be able to name what it is
# keeping open.
export fileExists, dirExists, symlinkExists, Handle

type
  FsResult* = object
    ok*: bool
    err*: int32   ## GetLastError() when `ok` is false, 0 otherwise

const
  ErrAlreadyExists* = 183'i32
  ErrPathNotFound* = 3'i32
  ErrAccessDenied* = 5'i32
  ErrNotSameDevice* = 17'i32
  ErrSharingViolation* = 32'i32

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
  ## Every text file this project reads comes through here, and **a UTF-8 BOM
  ## is dropped**, which is not a nicety.
  ##
  ## Notepad writes one by default, and so does PowerShell's
  ## `Set-Content -Encoding utf8`. Three bytes, `EF BB BF`, invisible in every
  ## editor -- and every JSON reader here scans from byte zero, so the document
  ## does not parse and the caller sees an empty or missing value rather than
  ## an error about encoding.
  ##
  ## What that cost, before this line existed: a BOM on a mod manager's
  ## `config.json` made its `activeLists` read as empty, so nothing resolved,
  ## so it wrote a selection file naming **only itself** -- and the next start
  ## loaded one mod out of ten, silently, with no error anywhere. The manager
  ## is built to refuse that state loudly; it could not, because it could not
  ## tell "the config named no lists" from "the config did not parse". A
  ## `regcheck` run on a BOM'd registry answered "it did not parse, or the top
  ## level is not an object", which is at least loud but still names the wrong
  ## cause.
  ##
  ## Fixed here rather than in each reader because there are three config
  ## readers alone (backend, client host, simulator) and the same hazard is on
  ## the registry, the selection file and the database. A reader that wants the
  ## exact bytes should not be using a proc called `readTextFile`.
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
  if result and into.len >= 3 and
     into[0] == '\xEF' and into[1] == '\xBB' and into[2] == '\xBF':
    into = into.substr(3, into.len - 1)

# ------------------------------------------------- files held open
#
# A file that is opened, read or written, and closed again on every touch, when
# the process does that thousands of times to the same file.
#
# The cost of `CreateFileW` is not the directory lookup. On a machine with
# real-time antivirus -- which is to say, on a player's machine -- opening a
# file that has been *modified* since it was last opened makes the scanner read
# and scan it before the handle comes back. Measured here on a 3 KB file: 35 us
# to open and read it when nothing has changed, 890 us when the previous
# operation wrote it. The backend's profile store does exactly that, read after
# write, once per inventory move.
#
# Keeping the handle open removes the open, and with it the rescan: the same
# read costs 3 us and the write 19 us. Nothing else changes -- every read still
# goes to the file through the operating system's cache, so another process
# writing the same file is seen exactly as it is now. That is the reason this
# is a held handle rather than an in-memory copy of the contents: a cache of
# the bytes would be faster still and would be wrong, because the client host
# and the backend run at the same time against one store.

proc openHeld*(p: string; create: bool): Handle =
  ## A handle to keep. Read and write access, and shared every way -- read,
  ## write and delete -- because the other host may want any of those while
  ## this one holds the file, and a handle that made them fail would turn a
  ## shared store into an intermittent error on whichever side asked second.
  ##
  ## What a held handle follows is the *file*, not the path. Another process
  ## rewriting the contents in place is seen; another process replacing the
  ## file at that path is not -- this handle stays on the old one.
  ##
  ## That last part is not academic any more: the store commits by renaming a
  ## temporary over the key, which is exactly such a replacement. It handles it
  ## in the only two ways that work -- the handle it wrote the temporary with
  ## *becomes* the key's handle after the rename, and any handle it had for the
  ## key before is closed before the rename, because Windows will not replace a
  ## file this process still has open. See `modstore.commitNow`.
  let w = toWide(p)
  result = createFileW(w.toWideCString, GENERIC_READ or GENERIC_WRITE,
                       FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,
                       nil, (if create: OPEN_ALWAYS else: OPEN_EXISTING),
                       FILE_ATTRIBUTE_NORMAL, Handle(0))

proc heldValid*(h: Handle): bool =
  result = h != INVALID_HANDLE_VALUE and h != Handle(0)

proc heldClose*(h: Handle) =
  if heldValid(h):
    discard closeHandle(h)

proc heldRead*(h: Handle; into: var string): bool =
  ## The whole file, from the beginning, however the pointer was left.
  into = ""
  if not heldValid(h):
    return false
  # `lpDistanceToMoveHigh` is not optional in these bindings, so the move is
  # the 64-bit form with a zero high word rather than the 32-bit one.
  var hi: LONG = 0'i32
  discard setFilePointer(h, 0'i32, addr hi, FILE_BEGIN)
  var high32: DWORD = 0'u32
  let low32 = getFileSize(h, addr high32)
  if high32 != DWORD(0) or low32 == DWORD(0xFFFFFFFF'u32):
    return false
  let size = int(low32)
  if size == 0:
    return true
  let dest = beginStore(into, size)
  var got = 0'i32
  let okRead = readFile(h, dest, int32(size), addr got, nil)
  endStore(into)
  if okRead == WINBOOL(0) or int(got) != size:
    into = ""
    return false
  result = true

proc heldWrite*(h: Handle; content: string): bool =
  ## Overwrites from the beginning and truncates to what was written, which is
  ## what `CREATE_ALWAYS` would have done -- without the create.
  if not heldValid(h):
    return false
  # `lpDistanceToMoveHigh` is not optional in these bindings, so the move is
  # the 64-bit form with a zero high word rather than the 32-bit one.
  var hi: LONG = 0'i32
  discard setFilePointer(h, 0'i32, addr hi, FILE_BEGIN)
  var put = 0'i32
  if content.len > 0:
    if writeFile(h, readRawData(content), int32(content.len), addr put,
                 nil) == WINBOOL(0):
      return false
    if int(put) != content.len:
      return false
  result = setEndOfFile(h) != WINBOOL(0)

# ------------------------------------------------- durable replacement
#
# What `heldWrite` above does is overwrite a file in place. That is fast and it
# is *not* a commit: between the first byte landing and `setEndOfFile`
# returning, the file on disk is neither the old value nor the new one, and a
# process killed in that window leaves it that way for good. For a store whose
# only contents are player profiles, that is the one failure that cannot be
# repaired afterwards.
#
# The three calls below are what makes a write a commit instead:
#
#  * `flushHeld` -- `FlushFileBuffers`, so the bytes are on the medium before
#    anything points at them. Windows guarantees the *rename* is atomic
#    (a directory entry replacement, journalled on NTFS); it does not
#    guarantee the file's data was written first. Without the flush, a power
#    cut can leave the new name pointing at a file whose contents never made
#    it -- the rename is metadata and metadata is journalled ahead of data.
#  * `replaceFileAt` -- `MoveFileExW` with `MOVEFILE_REPLACE_EXISTING`. A
#    reader opening the destination sees either the whole old file or the
#    whole new one; there is no instant at which it sees a mixture.
#    `MOVEFILE_WRITE_THROUGH` makes the call wait for the directory change
#    itself to reach the disk, so a crash *after* it returns cannot undo it.
#  * the retry -- the replace fails if some other process holds the
#    destination open without `FILE_SHARE_DELETE`, and on a player's machine
#    that other process is a virus scanner holding it for a few milliseconds
#    after the last write. Retrying briefly turns a sporadic lost save into a
#    slightly slower one. It is a small fixed number of attempts, not a loop:
#    a destination held open indefinitely is an error the caller must see.

proc flushFileBuffers(hFile: Handle): WINBOOL {.
  importc: "FlushFileBuffers", stdcall, dynlib: "kernel32", sideEffect.}

proc getCurrentProcessId(): int32 {.
  importc: "GetCurrentProcessId", stdcall, dynlib: "kernel32", sideEffect.}

proc lastFsError*(): int32 =
  ## `GetLastError`, for a caller that wants the code in its own message.
  result = getLastError()

proc heldFlush*(h: Handle): bool =
  ## The written bytes, on the medium. Not the same as "written": `WriteFile`
  ## returning means the cache has them.
  if not heldValid(h):
    return false
  result = flushFileBuffers(h) != WINBOOL(0)

proc replaceFileAt*(src, dst: string): FsResult =
  ## `src` becomes `dst`, atomically, replacing whatever was there.
  ##
  ## Both paths must be on the same volume -- they are, because the caller puts
  ## its temporary file in a subdirectory of the destination's own directory.
  ## `MoveFileExW` would silently fall back to a copy across volumes only with
  ## `MOVEFILE_COPY_ALLOWED`, which is deliberately not passed: a copy is not
  ## atomic and a silent one would be the bug this whole proc exists to stop.
  let ws = toWide(src)
  let wd = toWide(dst)
  let flags = MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH
  var attempt = 0
  while attempt < 6:
    if moveFileExW(ws.toWideCString, wd.toWideCString, flags) != WINBOOL(0):
      return good()
    let e = getLastError()
    if e != ErrAccessDenied and e != ErrSharingViolation:
      return FsResult(ok: false, err: e)
    inc attempt
    sleep(DWORD(2))
  result = bad()

proc processId*(): int =
  ## This process's id, for the store's lock file. A number a player can find
  ## in Task Manager is the whole point of putting it there.
  result = int(getCurrentProcessId())

proc openExclusive*(p: string): Handle =
  ## A file this process holds and no second process can take.
  ##
  ## Shared for reading so the process that loses can read the pid inside and
  ## say who has it; shared for nothing else, so a second writer fails at the
  ## open. `FILE_FLAG_DELETE_ON_CLOSE` is what makes it a lock rather than a
  ## litter: the kernel closes the handle however the process ends --
  ## including `TerminateProcess` and including a bugcheck -- so there is no
  ## such thing as a stale lock left behind by a crash, and therefore no
  ## "delete this file to continue" step for a player to get wrong.
  let w = toWide(p)
  result = createFileW(w.toWideCString, GENERIC_READ or GENERIC_WRITE,
                       FILE_SHARE_READ, nil, CREATE_ALWAYS,
                       FILE_ATTRIBUTE_NORMAL or FILE_FLAG_DELETE_ON_CLOSE,
                       Handle(0))

proc readShared*(p: string; into: var string): bool =
  ## Read a file that another process holds open for writing. `readTextFile`
  ## goes through `open`, which asks for sharing this cannot get; this asks for
  ## exactly what the holder allows.
  into = ""
  let w = toWide(p)
  let h = createFileW(w.toWideCString, GENERIC_READ,
                      FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,
                      nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, Handle(0))
  if not heldValid(h):
    return false
  result = heldRead(h, into)
  heldClose(h)

proc nowMs*(): int64 =
  ## Wall clock in milliseconds. Used only to space out the store's history
  ## snapshots, so it wants to be cheap and monotonic-enough rather than exact.
  var ft = default(FILETIME)
  getSystemTimeAsFileTime(ft)
  let ticks = (uint64(ft.dwHighDateTime) shl 32) or uint64(ft.dwLowDateTime)
  result = int64(ticks div 10_000'u64)

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
