## The per-mod key/value store behind `store_get` / `store_set` / `store_list`.
##
## Shared by both hosts, because a mod that keeps state must keep it the same
## way on either side of the pipeline. One file per key under
##
##     <root>/store/<mod-guid>/<key>
##
## A mod could open files itself. Then every mod invents its own layout inside
## the install, and neither the host nor the player can move, back up or clear
## one mod's data without knowing that mod. Routing it through the ABI costs a
## function call and buys a single answer to "where does this mod's data live".
##
## Keys are flat and restricted to `[A-Za-z0-9._-]`. A key outside that set is
## **refused, not sanitised**: mapping `a/b` and `a.b` onto one file would be a
## data-loss bug that only shows up with two keys that look nothing alike. The
## same rule stops `..\..\` from ever being a key.
##
## ## What this promises about a value
##
## What is in here is a player's profile, which is the only thing in this
## project that cannot be rebuilt from something else. So, in order of how much
## each one costs when it is missing:
##
##  * **A value is never half-written.** A commit writes a temporary file and
##    renames it over the key; a reader sees the whole old value or the whole
##    new one and never a mixture, whatever happens to this process in between.
##    `tools/storecrash.nim` kills a process mid-write to check it rather than
##    to assert it, and `tests/storeperf/storeguard.nim` checks the other side
##    of the same claim: what a reader in a *different* process sees while the
##    commit happens, which is not the same question and had a different
##    answer -- see `renameHeld` and `stillNamed`.
##  * **"Never written" and "unreadable" are different answers.** See
##    `storeReadInto`. A caller that treats them alike creates a new character
##    over a save that was probably still recoverable.
##  * **There is history.** A bounded ring of previous versions under `.hist`,
##    which is what a *bad* value is recovered from -- atomicity is no help
##    there, since the store commits a bad value perfectly.
##  * **One host side per store.** See `storeLock`.
##  * **A write is committed before `storeWrite` returns.** Nothing is held in
##    memory waiting for a later moment, so there is no window in which a
##    process that dies loses a save it has already reported as made, and no
##    host has to remember to flush anything.

import std/strutils
import std/windows/winlean
import std/widestrs
import aowlsptinstall/winfs

# The store is touched from every worker thread, so the handle table below is
# guarded. `aowlspt_lock.h` rather than `aowlspt_net.h`: this needs a critical
# section and has no business acquiring winsock and zlib to get one -- see the
# comment at the top of that header.
{.emit: """#include "aowlspt_lock.h" """.}

proc cLock() {.importc: "aowl_lock", nodecl.}
proc cUnlock() {.importc: "aowl_unlock", nodecl.}

var gStoreRoot = ""

# Directories this process has already created, so a write does not ask the
# filesystem whether its own directory exists on every call. This caches a
# fact about *this* process's actions, not the content of any file: nothing
# another process does can make "I created this directory" wrong in a way that
# matters, because the worst case is that the directory was deleted underneath
# us and the write fails -- which the caller already handles.
#
# Caching the values themselves would be the obvious next step and is
# deliberately not taken. The client host and the backend run at the same time
# against the same `<root>/store`, so a value one of them cached is a value the
# other can invalidate, and there is no cheap way for either to find out.
var gMadeDirs: seq[string] = @[]

# ------------------------------------------------------------ history
#
# One bad write is not supposed to be terminal. A migration that got a field
# wrong, a mod that wrote nonsense, a disk that returned it -- none of those
# are crashes, so atomicity does not help with any of them: the store commits
# the bad value perfectly. What helps is having the value from before.
#
# So a bounded ring of previous versions, in a subdirectory of the mod's own
# store directory. Bounded twice over: `BackupGenerations` files per key, and
# at most one written per key per `BackupIntervalMs`, so the cost is amortised
# to nothing on the request path and the disk cost is (generations x size)
# rather than a log that grows for the life of a profile.
#
# The directory name begins with a dot, which `validKey` refuses, so it can
# never collide with a key -- and `storeKeys` skips it besides.

const
  HistDir = ".hist"
  BackupGenerations = 3
  BackupIntervalMs = 300_000'i64   ## five minutes
  BackupTrackMax = 4096
    ## Keys tracked for scheduling. A mod is free to have more; the only
    ## consequence of forgetting one is a snapshot taken sooner than it had
    ## to be.

type
  KeyState = object
    ## What this process remembers about one key: when it last snapshotted it
    ## into the history, and when it last committed it. Both are schedules
    ## rather than facts about the data, so losing the lot -- which the bound
    ## below does -- costs a snapshot taken early and a commit done at once.
    path: string
    lastBackupMs: int64

var gKeys: seq[KeyState] = @[]

# Whether a commit forces its bytes to the medium before the rename. Off by
# default; `storeFlushOnWrite` and the long comment in `atomicPut` say what
# that does and does not change.
var gFlushOnWrite = false


# ------------------------------------------------------------ open handles
#
# The backend reads a player's profile and writes it back on every inventory
# move. Opening the file each time is the expensive part of that, and not for
# the reason it looks like: real-time antivirus rescans a file on open when it
# has been modified since the last one, so the read that follows a write costs
# 890 us against 35 us for a read of something unchanged. Measured on this
# machine, on the 3 KB document the emulator actually stores.
#
# So the handle is kept. A read then costs 3 us and a write 19 us, and nothing
# about what is stored changes: the bytes still live in the file and still go
# through the operating system's cache. An in-memory copy of the values would
# be faster again and would be wrong -- the two hosts run at the same time
# against one `<root>/store`, and neither can be told when the other has
# written.
#
# **That argument used to end "so the client host reading the same store sees
# exactly what it sees today", and for a while that was false.** It was true
# while a write was an in-place overwrite: the file kept its identity and a
# held handle saw every change to it. It stopped being true when the write
# became a commit, because a commit gives the *name* to a different file and a
# handle follows the file. A reader holding the key was then holding a file
# that had been unlinked, and answered every later read with a value that had
# been overwritten -- for as long as the handle lived, which is until the LRU
# below evicted it. That is exactly the in-memory cache this comment says the
# module must not have, arrived at by accident.
#
# `stillNamed` is what makes the sentence true again: one handle-only syscall
# per read, no open, and a handle whose file has lost its last name is dropped
# and reopened. `tests/storeperf/storeguard` is the check, and it fails against
# the code as it was.
#
# Bounded, and least-recently-used: a mod is free to have ten thousand keys and
# a host is not free to have ten thousand handles.
const HeldMax = 32

type
  Held = object
    path: string
    h: Handle
    stamp: int64

var gHeld: seq[Held] = @[]
var gHeldStamp = 0'i64

proc stillNamed(h: Handle): bool =
  ## Whether the file this handle is on still has a name.
  ##
  ## This is the other half of the commit, and without it the handle cache is
  ## the value cache the comment above says it deliberately is not. A commit
  ## replaces the file at the key's path, and a handle follows the *file*, not
  ## the name -- so the moment the other host commits to a key this process is
  ## holding, this process's handle is on a file that has been unlinked, and
  ## every read of that key afterwards answers with a value that was true once.
  ## Not stale by a race: stale for as long as the handle lives, which is until
  ## the LRU gets round to it.
  ##
  ## An unlinked file has no links, and `GetFileInformationByHandle` says so
  ## without opening anything -- which is the point, because an open is the
  ## 890 us the handle cache exists to avoid. It costs about a microsecond
  ## against a 17 us read.
  var info: BY_HANDLE_FILE_INFORMATION = default(BY_HANDLE_FILE_INFORMATION)
  if getFileInformationByHandle(h, addr info) == WINBOOL(0):
    # No answer is not evidence of a deleted file, but it is evidence that
    # this handle is not worth keeping.
    return false
  result = info.nNumberOfLinks > DWORD(0)

proc heldFor(path: string; create: bool): Handle =
  ## Caller holds the lock. `create` distinguishes a write (which may be the
  ## first) from a read (which must not bring a file into existence -- a `load`
  ## of a key that was never saved has to keep answering "no").
  inc gHeldStamp
  for i in 0 ..< gHeld.len:
    if gHeld[i].path == path:
      if not stillNamed(gHeld[i].h):
        # Somebody else committed to this key. Drop the handle and open the
        # file that has the name now; the caller gets what the store says
        # rather than what it said.
        heldClose(gHeld[i].h)
        gHeld.del i
        break
      gHeld[i].stamp = gHeldStamp
      return gHeld[i].h
  let h = openHeld(path, create)
  if not heldValid(h):
    return h
  if gHeld.len >= HeldMax:
    var slot = 0
    for i in 1 ..< gHeld.len:
      if gHeld[i].stamp < gHeld[slot].stamp:
        slot = i
    heldClose(gHeld[slot].h)
    gHeld[slot] = Held(path: path, h: h, stamp: gHeldStamp)
  else:
    gHeld.add Held(path: path, h: h, stamp: gHeldStamp)
  result = h

proc heldDrop(path: string) =
  ## Caller holds the lock. Used when an operation on a held handle fails:
  ## whatever went wrong, the next attempt should start from a fresh open
  ## rather than inherit it.
  for i in 0 ..< gHeld.len:
    if gHeld[i].path == path:
      heldClose(gHeld[i].h)
      gHeld.del i
      return

proc heldAdopt(path: string; h: Handle) =
  ## Caller holds the lock. A handle to a file that has just *become* `path` --
  ## it was opened under the temporary name and renamed onto the destination
  ## while this process held it open.
  ##
  ## That is why the write below does not have to give the read-after-write
  ## optimisation back to get atomicity. A Win32 handle follows the file, not
  ## the name: after the rename this handle is a handle to the store file, so
  ## the next read is served without an open and without the antivirus rescan
  ## that an open after a write pays. The old handle for `path` -- if there was
  ## one -- is now a handle to a file that no longer has a name, so it goes.
  for i in 0 ..< gHeld.len:
    if gHeld[i].path == path:
      heldClose(gHeld[i].h)
      gHeld.del i
      break
  inc gHeldStamp
  if gHeld.len >= HeldMax:
    var slot = 0
    for i in 1 ..< gHeld.len:
      if gHeld[i].stamp < gHeld[slot].stamp:
        slot = i
    heldClose(gHeld[slot].h)
    gHeld[slot] = Held(path: path, h: h, stamp: gHeldStamp)
  else:
    gHeld.add Held(path: path, h: h, stamp: gHeldStamp)

proc storeClose*() =
  ## Every handle, released. For a host shutting down, and for a test that
  ## wants the store on disk with nothing holding it.
  ##
  ## Nothing is committed here because nothing is ever waiting to be: a write
  ## is on disk before `storeWrite` returns. What goes is the handles.
  cLock()
  for e in gHeld:
    heldClose(e.h)
  gHeld = @[]
  cUnlock()

proc storeInit*(root: string) =
  ## `root` is the host's own directory -- the store goes in `store/` beneath it.
  gStoreRoot = joinPath(root, "store")

proc storeRoot*(): string = gStoreRoot

# ------------------------------------------------------------- one writer
#
# Two backends started on the same root both hold a profile, both read it, and
# both write it back -- and whichever writes second wins, silently, with the
# other's raid in it undone. It is not a hypothetical: a launcher that does not
# notice the server it started last time is still running produces exactly
# this, and the only symptom a player sees is progress that comes and goes.
#
# So the store is claimed. Not with a pid file that has to be checked, aged and
# cleaned up -- a pid file left by a crash locks a player out of their own game
# and the fix is a file they have to be told to delete. A held handle with
# `FILE_FLAG_DELETE_ON_CLOSE` cannot go stale: the kernel releases it however
# the process ends, `TerminateProcess` included.
#
# Named per host side, because the client host and the backend are *meant* to
# run at the same time against one `<root>/store`. What must not happen twice
# is one side.

var gLockHandle = Handle(0)
var gLockPath = ""

proc storeLock*(side: string; holder: var string; error: var string): bool =
  ## Claim `<root>/store` for this host side. `holder` is what the process that
  ## already has it wrote about itself, when it can be read.
  holder = ""
  error = ""
  if gStoreRoot.len == 0:
    error = "the store is not initialised"
    return false
  let mk = ensureDir(gStoreRoot)
  if not mk.ok:
    error = "could not create " & gStoreRoot & " (error " & $int(mk.err) & ")"
    return false
  let path = joinPath(gStoreRoot, ".lock-" & side)
  let h = openExclusive(path)
  if not heldValid(h):
    let e = lastFsError()
    var text = ""
    if readShared(path, text):
      holder = text
    error = "another " & side & " is already using this store (error " &
            $int(e) & ")"
    return false
  gLockHandle = h
  gLockPath = path
  # Who has it, for the message the loser prints. Best effort: failing to write
  # the note does not make the claim any less exclusive.
  discard heldWrite(h, "pid " & $processId() & "\n")
  discard heldFlush(h)
  result = true

proc storeUnlock*() =
  ## Ordinary shutdown. A crash does not need this -- that is the point of
  ## `FILE_FLAG_DELETE_ON_CLOSE`.
  if heldValid(gLockHandle):
    heldClose(gLockHandle)
    gLockHandle = Handle(0)
    gLockPath = ""

proc validKey*(key: string): bool =
  ## Flat, and nothing that can escape the directory. Also bounded: a key long
  ## enough to overflow MAX_PATH would fail at the filesystem with an error
  ## nobody can act on.
  if key.len == 0 or key.len > 180:
    return false
  for ch in key:
    let isLower = ch >= 'a' and ch <= 'z'
    let isUpper = ch >= 'A' and ch <= 'Z'
    let isDigit = ch >= '0' and ch <= '9'
    if not (isLower or isUpper or isDigit or ch == '.' or ch == '_' or
            ch == '-'):
      return false
  # A leading dot would make the file hidden on some tools' view of the
  # directory, and `.` / `..` are not keys.
  if key[0] == '.':
    return false
  result = true

proc guidDir(guid: string): string =
  ## The guid is a mod's own identifier and reaches here from its `describe`, so
  ## it is checked exactly as a key is -- a mod cannot pick a guid that puts its
  ## store somewhere else.
  var safe = ""
  for ch in guid:
    let isLower = ch >= 'a' and ch <= 'z'
    let isUpper = ch >= 'A' and ch <= 'Z'
    let isDigit = ch >= '0' and ch <= '9'
    if isLower or isUpper or isDigit or ch == '.' or ch == '_' or ch == '-':
      safe.add ch
    else:
      safe.add '_'
  if safe.len == 0 or safe[0] == '.':
    safe = "unnamed"
  result = joinPath(gStoreRoot, safe)

const
  ReadOk* = 0
    ## The value is in `into`.
  ReadMissing* = 1
    ## There is no such key. First run, a profile that was never created --
    ## normal, and the caller may go ahead and make one.
  ReadFailed* = 2
    ## The key is *there* and could not be read.
  ReadBadArg* = 3
    ## The key or the store itself is wrong; nothing was looked at.

proc storeReadInto*(guid, key: string; into: var string;
                    error: var string): int =
  ## The three-way answer. `storeRead` below is the two-way one, kept because
  ## both hosts call it, but every caller that can act on the difference should
  ## use this instead.
  ##
  ## The difference is the whole point. "No profile yet" and "your profile is
  ## on disk and I cannot read it" arrive at the same `false` in a boolean API,
  ## and a caller that treats them alike answers the second with a brand new
  ## character -- over the top of a save that was probably still recoverable.
  ## That is the failure that costs a player something they cannot get back, so
  ## it gets a return value of its own rather than a string a caller has to
  ## parse to notice.
  into = ""
  error = ""
  if gStoreRoot.len == 0:
    error = "the store is not initialised"
    return ReadBadArg
  if not validKey(key):
    error = "not a valid store key: " & key
    return ReadBadArg
  let path = joinPath(guidDir(guid), key)
  cLock()
  let h = heldFor(path, false)
  var got = false
  if heldValid(h):
    got = heldRead(h, into)
    if not got:
      heldDrop(path)
  cUnlock()
  if got:
    return ReadOk
  # No `exists` probe on the way in: a missing file and an unreadable one
  # both fail the open, so the probe only ever bought a better message for
  # the second case. It is recovered here instead, on the path where a
  # syscall costs nothing because the request has already failed.
  into = ""
  if exists(path):
    error = "could not read " & path & " (error " & $int(lastFsError()) &
            "); a previous version may be under " &
            joinPath(guidDir(guid), HistDir)
    return ReadFailed
  error = "no stored value for " & key
  result = ReadMissing

proc storeRead*(guid, key: string; into: var string; error: var string): bool =
  result = storeReadInto(guid, key, into, error) == ReadOk

# ------------------------------------------------ committing, in two steps
#
# A commit is: write a temporary, then make it be the key. The second step is
# a rename, and there are two ways to ask for one. They are the same kernel
# operation -- `MoveFileExW` is a wrapper over `FileRenameInformation` -- and
# they differ in what they cost and in one flag.
#
#  * **By path**, `winfs.replaceFileAt`: `MoveFileExW` opens the source by
#    name to get a handle with `DELETE` on it, renames, and closes. This
#    process has just written that file and already holds a handle to it, so
#    the open is one this module has already paid for once.
#  * **By handle**, `renameHeld` below: `SetFileInformationByHandle` with
#    `FileRenameInfo` on the handle the value was written through. No second
#    open of the source, and nothing else about the operation changes.
#
# Measured on this machine, 3 KB value, 300 commits each (`tests/storeperf`):
# 225 us by path against 175 us by handle. Small, and free.
#
# ## `MOVEFILE_WRITE_THROUGH` is the interesting one, and it was wrong
#
# `winfs.replaceFileAt` passes `MOVEFILE_WRITE_THROUGH`, which makes the call
# wait until the *directory change* is on the disk. It costs 225 us of a
# 460 us commit -- half of it -- and what it buys depends entirely on whether
# the file's **data** was flushed first, which by default it is not:
# `gFlushOnWrite` is off.
#
# So the pairing that was in force -- data not flushed, rename forced to the
# platter -- is the one combination that has no defensible reading. It pushes
# the *name* of the new value out to disk ahead of the bytes that name points
# at, which is precisely the ordering a power cut turns into a key file full
# of nothing. Forcing the metadata out sooner cannot make that safer; it can
# only make the window it needs easier to hit.
#
# The flag therefore follows the flush, and is not a knob of its own:
#
#   `storeFlushOnWrite(false)` (default)  no flush, no write-through. A power
#       cut may cost the last write. Nothing about atomicity changes: a
#       process killed at any point still leaves the whole old value or the
#       whole new one, because that comes from the rename being one
#       filesystem operation and from the page cache outliving the process.
#   `storeFlushOnWrite(true)`             `FlushFileBuffers` and then
#       `MOVEFILE_WRITE_THROUGH`, in that order, which is the only order in
#       which the second flag means anything: the bytes are on the medium
#       before the name that points at them is.
#
# Nothing here is a durability switch with a new default. The switch already
# existed and its default has not moved; what changed is that the off position
# no longer pays 225 us for a guarantee the on position is the only one that
# can actually make.

const
  DeleteAccess = 0x00010000'u32
    ## `DELETE`, which `winlean` does not name. A handle needs it to be
    ## renamed through, and this module's temporary files are the only files
    ## it opens that way.
  FileRenameInfoClass = 3'i32
    ## `FileRenameInfo` in `FILE_INFO_BY_HANDLE_CLASS`.
  FileRenameInfoExClass = 22'i32
    ## `FileRenameInfoEx`, which takes flags where `FileRenameInfo` takes a
    ## `BOOLEAN`. The two structures are otherwise the same shape, so one
    ## buffer serves both.
  RenamePosixReplace = 0x00000003'u32
    ## `FILE_RENAME_FLAG_REPLACE_IF_EXISTS or FILE_RENAME_FLAG_POSIX_SEMANTICS`.
    ## The second flag is the one that matters and is explained at
    ## `renameHeld`: without it a commit fails outright whenever the *other*
    ## host has the key open.
  RenameBufBytes = 2048
    ## Enough for the header and a fully qualified path of about a thousand
    ## wide characters. A path longer than that falls back to the by-path
    ## rename rather than being refused -- see `renameHeld`.

proc setFileInformationByHandle(hFile: Handle; infoClass: int32;
                                info: pointer; size: DWORD): WINBOOL {.
  importc: "SetFileInformationByHandle", stdcall, dynlib: "kernel32",
  sideEffect.}

proc toWide(s: string): WideCStringObj =
  ## `newWideCString` takes its argument by `var`, so the string has to be
  ## bound to a local for the buffer to outlive the call. Same reasoning as
  ## `winfs.toWide`, which is private to that module.
  var t = s
  result = newWideCString(t)

proc fullyQualified(p: string): bool =
  ## `FileRenameInfo` with a null `RootDirectory` requires a fully qualified
  ## destination. A store rooted at a relative path would otherwise be renamed
  ## somewhere surprising, so it takes the by-path route instead, where the
  ## resolution against the current directory is Win32's own.
  if p.len >= 2 and p[1] == ':':
    return true
  if p.len >= 2 and p[0] == '\\' and p[1] == '\\':
    return true
  result = false

proc renameHeld(h: Handle; dst: string; posix: bool): bool =
  ## `h`'s file becomes `dst`, replacing whatever is there. The handle follows
  ## the file, so afterwards it is a handle to `dst` -- exactly as it is after
  ## `replaceFileAt`, which is what `heldAdopt` relies on.
  ##
  ## False means "not done, and nothing was changed"; the caller falls back to
  ## the by-path rename, which is the same operation asked for the other way.
  ##
  ## ## `posix`, and the bug it is here for
  ##
  ## A rename that replaces an existing file refuses -- `ERROR_ACCESS_DENIED`,
  ## and no amount of retrying helps -- while **any other process has the
  ## destination open**, `FILE_SHARE_DELETE` or not. That is the classic
  ## Win32 rule and `MoveFileExW` obeys it.
  ##
  ## This module keeps files open. So the moment the client host has read a
  ## key, every commit the backend makes to that key fails, for as long as the
  ## reader's handle lives -- and the two hosts running at once against one
  ## `<root>/store` is what this module is *for*. `tests/storeperf/storeguard`
  ## reproduces it in two lines of output: the writer's first commit succeeds,
  ## the reader opens the key, and nothing the writer does afterwards reaches
  ## the disk. It has been that way since the write became a commit.
  ##
  ## `FileRenameInfoEx` with `FILE_RENAME_FLAG_POSIX_SEMANTICS` is the rule
  ## lifted: the destination is unlinked rather than required to be unopened,
  ## exactly as `rename(2)` has always behaved, and existing handles to it stay
  ## valid on a file that no longer has a name. Windows 10 1809 and NTFS; where
  ## it is refused the caller falls back, and the fallback is what the store
  ## did before.
  if not heldValid(h) or not fullyQualified(dst):
    return false
  var w = toWide(dst)
  let n = w.len
  if 20 + (n + 1) * 2 > RenameBufBytes:
    return false
  var buf: array[RenameBufBytes, byte] = default(array[RenameBufBytes, byte])
  # FILE_RENAME_INFO, x64 layout: BOOLEAN ReplaceIfExists at 0, HANDLE
  # RootDirectory at 8 (left null), DWORD FileNameLength at 16, and the name
  # itself from 20. `FileNameLength` is in bytes and excludes the terminator,
  # which is nevertheless written because the kernel is happier with it there.
  # `FILE_RENAME_INFORMATION_EX` is the same layout with a `DWORD Flags` where
  # the `BOOLEAN` is, so only the first four bytes and the class differ.
  if posix:
    buf[0] = byte(RenamePosixReplace and 0xFF'u32)
    buf[1] = byte((RenamePosixReplace shr 8) and 0xFF'u32)
    buf[2] = byte((RenamePosixReplace shr 16) and 0xFF'u32)
    buf[3] = byte((RenamePosixReplace shr 24) and 0xFF'u32)
  else:
    buf[0] = 1'u8
  let nameBytes = uint32(n * 2)
  buf[16] = byte(nameBytes and 0xFF'u32)
  buf[17] = byte((nameBytes shr 8) and 0xFF'u32)
  buf[18] = byte((nameBytes shr 16) and 0xFF'u32)
  buf[19] = byte((nameBytes shr 24) and 0xFF'u32)
  for i in 0 ..< n:
    let u = cast[uint16](w[i])
    buf[20 + i * 2] = byte(u and 0xFF'u16)
    buf[21 + i * 2] = byte((u shr 8) and 0xFF'u16)
  let size = DWORD(20 + n * 2 + 2)
  # The same retry `replaceFileAt` carries, and for the same reason: a
  # destination another process holds open without `FILE_SHARE_DELETE` --
  # on a player's machine, a virus scanner that has it for a few milliseconds
  # after the last write -- refuses the replace. A small fixed number of
  # attempts, not a loop.
  let cls = (if posix: FileRenameInfoExClass else: FileRenameInfoClass)
  var attempt = 0
  while attempt < 6:
    if setFileInformationByHandle(h, cls, addr buf[0], size) != WINBOOL(0):
      return true
    let e = getLastError()
    if e != 5'i32 and e != 32'i32:   # ACCESS_DENIED, SHARING_VIOLATION
      return false
    if posix:
      # POSIX semantics do not fail on an open destination, so an
      # `ACCESS_DENIED` here is a filesystem that will not do this at all --
      # not a conflict that waiting clears. Retrying it would spend twelve
      # milliseconds per write on every commit of a store on such a volume.
      return false
    inc attempt
    sleep(DWORD(2))
  result = false

proc openTemp(p: string): Handle =
  ## `winfs.openHeld(p, true)` plus `DELETE`, which is what lets `renameHeld`
  ## put this handle's file at the key's path without opening it again.
  ## Shared every way, as `openHeld` is and for the same reason.
  let w = toWide(p)
  result = createFileW(w.toWideCString,
                       GENERIC_READ or GENERIC_WRITE or DeleteAccess,
                       FILE_SHARE_READ or FILE_SHARE_WRITE or
                       FILE_SHARE_DELETE,
                       nil, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, Handle(0))

proc atomicPut(tmp, dst, value: string; keep: bool; kept: var Handle;
               error: var string): bool =
  ## `value` becomes the whole contents of `dst`, or `dst` is untouched.
  ##
  ## Write into a file nothing is reading, then rename it over the
  ## destination -- and, if this store is running durable, force the bytes to
  ## the medium in between. Every step is ordinary Win32; what makes it a
  ## commit is the order. See `replaceFileAt` in `winfs` for what each call
  ## guarantees and, more usefully, what it does not, and the note above
  ## `renameHeld` for why the rename is asked for through the handle rather
  ## than by path and why `MOVEFILE_WRITE_THROUGH` now follows the flush.
  ##
  ## With `keep`, the handle comes back in `kept` and is now a handle to `dst`
  ## -- see `heldAdopt`.
  kept = Handle(0)
  let h = openTemp(tmp)
  if not heldValid(h):
    error = "could not open " & tmp & " (error " & $int(lastFsError()) & ")"
    return false
  if not heldWrite(h, value):
    heldClose(h)
    discard removeFileAt(tmp)
    error = "could not write " & tmp & " (error " & $int(lastFsError()) & ")"
    return false
  # The flush is the expensive step by an order of magnitude -- 3.4 ms of a
  # 4.1 ms write on this machine -- and it is **not** what makes the write
  # atomic. The rename is. What `FlushFileBuffers` adds is power-loss
  # protection: without it, a machine that loses power can come back with the
  # rename applied and the file's contents not yet on the platter, losing the
  # last write. With it, that cannot happen.
  #
  # So it is off unless asked for. Neither setting can produce a truncated or
  # mixed document -- that property comes from the rename and is not
  # negotiable. The choice here is only between "a power cut may cost the last
  # write" and "a power cut costs nothing, and every write costs four
  # milliseconds".
  if gFlushOnWrite:
    if not heldFlush(h):
      heldClose(h)
      discard removeFileAt(tmp)
      error = "could not flush " & tmp & " (error " & $int(lastFsError()) & ")"
      return false
    # Only here does `MOVEFILE_WRITE_THROUGH` mean anything, and
    # `replaceFileAt` is the call that passes it. See the note above
    # `renameHeld`: forcing the directory entry to the platter is a guarantee
    # about the *name*, and a name is worth forcing out only once the bytes it
    # points at have been. If it is refused because the other host has the key
    # open, the POSIX rename below is tried rather than the write being lost:
    # a commit that reaches the disk without its directory entry forced is
    # worth more than one that does not happen.
    let mv = replaceFileAt(tmp, dst)
    if not mv.ok and not renameHeld(h, dst, true):
      heldClose(h)
      discard removeFileAt(tmp)
      error = "could not replace " & dst & " (error " & $int(mv.err) & ")"
      return false
  elif not renameHeld(h, dst, true):
    # The fallbacks, in the order of how much they give up. The classic rename
    # through the handle first -- same call, no POSIX semantics, so it is
    # refused if the other host holds the key -- and then the by-path
    # `MOVEFILE_REPLACE_EXISTING`, which is what the store did before and
    # covers the cases `renameHeld` declines outright: a store rooted at a
    # relative path, or a path too long for its buffer.
    if not renameHeld(h, dst, false):
      let mv = replaceFileAt(tmp, dst)
      if not mv.ok:
        heldClose(h)
        discard removeFileAt(tmp)
        error = "could not replace " & dst & " (error " & $int(mv.err) & ")"
        return false
  if keep:
    kept = h
  else:
    heldClose(h)
  result = true

proc keyStateFor(path: string): int =
  ## Caller holds the lock. The index of this key's state, adding it if it is
  ## new. Never fails: a full table is emptied rather than grown, which costs a
  ## snapshot taken sooner than it had to be.
  for i in 0 ..< gKeys.len:
    if gKeys[i].path == path:
      return i
  if gKeys.len >= BackupTrackMax:
    gKeys = @[]
  gKeys.add KeyState(path: path, lastBackupMs: 0'i64)
  result = gKeys.len - 1

proc backupDue(path: string; now: int64): bool =
  ## Caller holds the lock. True at most once per `BackupIntervalMs` per key,
  ## and always on this process's first write of a key -- so a server that is
  ## started, plays one raid and is closed still leaves a generation behind.
  let i = keyStateFor(path)
  if gKeys[i].lastBackupMs != 0'i64 and
     now - gKeys[i].lastBackupMs < BackupIntervalMs:
    return false
  gKeys[i].lastBackupMs = now
  result = true

proc backupSlot(now: int64): int =
  ## Which generation this snapshot replaces, taken from the clock rather than
  ## from a counter this process keeps.
  ##
  ## A counter is reset by every restart, and a server that is started and
  ## stopped between raids -- which is every server -- would then write
  ## generation one over and over and never fill the other two. Off the clock,
  ## the ring holds the last `BackupGenerations` intervals in which anything
  ## was written, whether that was one session or thirty.
  result = int((now div BackupIntervalMs) mod int64(BackupGenerations)) + 1

# --------------------------------------------------------------- committing
#
# A commit is a rename, and a rename needs a file to rename, so every commit
# creates one. That is the expensive half and it was worth trying to remove:
# keeping one empty file per key open under `.hist/<key>.spare`, writing the
# value into it through the handle, and renaming that over the key, so the
# create happens after the answer rather than inside the request.
#
# It was tried, measured, and taken out again, because the create is not where
# the time goes. On the 84 KB document the emulator has after two hundred
# raids, on this machine:
#
#     create an empty file, close it                    164 us
#     create + write 84 KB + close                      516 us
#     create + write + rename over the key             1013 us
#     spare + rename + make the next spare             1351 us
#     rename two files nothing has written               311 us
#
# The last line is the one that misled me first time round: a rename is cheap
# *when the file has not just been written*. Renaming a file this process has
# filled with 84 KB costs several hundred microseconds however that file came
# to exist, because a real-time virus scanner inspects the contents on the way
# past. Pre-creating removes 164 us of a millisecond and adds a second file to
# reason about, and end to end -- through `benchbackend`, which is the only
# measurement that decides anything -- it was inside the noise.
#
# So: create, write, rename. One shape, one temporary, no second file per key
# to keep in step, and the commit costs what a rename of a freshly written file
# costs. `storeCommitStats` counts commits so the rate is a number rather than
# an impression.

var gCommits = 0

proc storeCommitStats*(commits: var int) =
  ## Commits made. For a test, and for anyone pricing a change to this file.
  commits = gCommits

proc commitNow(dir, key, value: string; error: var string): bool =
  ## Caller holds the lock. The commit itself: `value` becomes the whole
  ## contents of `<dir>/<key>`, or that file is exactly as it was.
  ##
  ## Not written in place. It used to be -- through a handle that stayed open,
  ## overwriting from byte zero and truncating -- and that is fast and is not a
  ## commit: a process killed between the first byte and `setEndOfFile` leaves
  ## the file as a mixture of the old value and the new one, which for a
  ## profile is the one loss nothing afterwards can repair. `atomicPut` writes
  ## a temporary and renames it over the key, so a reader sees the whole old
  ## value or the whole new one and never a mixture.
  let hist = joinPath(dir, HistDir)
  let path = joinPath(dir, key)
  let tmp = joinPath(hist, key & ".tmp")
  inc gCommits

  # The held handle for this key goes **before** the rename, not after it.
  #
  # This is the one place where the two things this module wants are in direct
  # tension. The handle cache exists so a read after a write does not pay for
  # an open (and the antivirus rescan behind it); the commit works by replacing
  # the file at the key path. `MoveFileExW` with `MOVEFILE_REPLACE_EXISTING`
  # will not replace a destination this process still holds open -- it fails
  # with error 5 -- and because the cache is empty on the first write of a key,
  # the failure begins on the *second* write and reads as intermittent. It is
  # not: without this line every second write of every key fails.
  #
  # The optimisation survives anyway: the handle that wrote the temporary is
  # adopted below and, after the rename, is a handle to the key's own file.
  heldDrop(path)

  var kept = Handle(0)
  if not atomicPut(tmp, path, value, true, kept, error):
    return false
  heldAdopt(path, kept)

  # A generation, on a schedule. Off the request path in the sense that
  # matters: at one snapshot per key per five minutes, a raid's worth of
  # inventory moves pays for it once. Written the same atomic way, because a
  # history that can itself be torn is a history nobody can trust at the moment
  # they come to use it.
  let now = nowMs()
  if backupDue(path, now):
    let histPath = joinPath(hist, key & "." & $backupSlot(now))
    var ignored = Handle(0)
    var histError = ""
    if not atomicPut(joinPath(hist, key & ".tmpgen"), histPath, value,
                     false, ignored, histError):
      # Not a failure of the write: the value is committed. Reported anyway,
      # because a store quietly running without the history the documentation
      # promises should not be a silent state.
      error = "value written, but the history copy failed: " & histError
  result = true

proc storeFlushOnWrite*(on: bool) =
  ## Whether every commit forces its bytes to the medium before the rename,
  ## and -- because the two are only meaningful together -- whether the rename
  ## itself waits for the directory entry to reach the disk.
  ##
  ## Off by default: see `atomicPut` and the note above `renameHeld`.
  ## Atomicity does not depend on either, in either position. What this
  ## chooses is whether a *power cut* may cost the last write.
  gFlushOnWrite = on

proc storeWrite*(guid, key, value: string; error: var string): bool =
  ## Committed before this returns. There is no queue, nothing held in memory,
  ## and nothing a host has to remember to flush: when this answers true, the
  ## value is the whole contents of the key's file.
  ##
  ## It did hold writes briefly and commit them together for a while, because a
  ## commit costs about a millisecond and the emulator writes the whole profile
  ## document on every inventory drag. That bought throughput and cost the one
  ## thing this file exists to protect: a process killed outright lost a save
  ## it had already reported as made. The queue is gone and the millisecond is
  ## paid -- see the note above `commitNow` for what was tried to make it
  ## cheaper and why it did not work.
  error = ""
  if gStoreRoot.len == 0:
    error = "the store is not initialised"
    return false
  if not validKey(key):
    error = "not a valid store key: " & key
    return false
  let dir = guidDir(guid)
  let hist = joinPath(dir, HistDir)
  # `gMadeDirs` is walked and appended to **under the lock**, and it used to be
  # neither.
  #
  # It reads as bookkeeping -- a list of directories this process has already
  # created -- and it is a `seq`, which is the whole problem. Sixteen workers
  # serve `store_set` at once, a `seq` that grows reallocates, and a thread
  # appending the first key of one mod while another walks the list for a
  # different mod drops the buffer the walker is standing in. That is the same
  # use-after-free the backend found in `gRoutes` and the database document,
  # one table over, and it is the more dangerous shape of it: the window opens
  # only on the *first* write of each new directory, so it is invisible in
  # every steady-state test and waits for the moment a second mod starts
  # writing while the first is busy.
  #
  # The lock was already being taken two lines below for the commit, so the
  # cost of moving it up is one `ensureDir` syscall inside the critical section
  # -- once per directory per process, on a path that is about to spend a
  # millisecond renaming a file -- and, in the steady state, a walk of a list
  # with as many entries as the host has mods.
  cLock()
  var made = false
  for d in gMadeDirs:
    if d == hist:
      made = true
  var mkErr = 0
  var mkOk = true
  if not made:
    # One `ensureDir` makes both: `.hist` is under `dir`.
    let mk = ensureDir(hist)
    mkOk = mk.ok
    mkErr = int(mk.err)
    if mkOk:
      gMadeDirs.add hist
  var wrote = false
  if mkOk:
    wrote = commitNow(dir, key, value, error)
  cUnlock()
  if not mkOk:
    error = "could not create " & hist & " (error " & $mkErr & ")"
    return false
  result = wrote

proc storeHistoryDir*(guid: string): string =
  ## Where the generations for a mod live, for a message that has to tell
  ## somebody where to look.
  result = joinPath(guidDir(guid), HistDir)

proc storeKeys*(guid, prefix: string): string =
  ## A JSON array of the keys under `prefix`. An empty store is `[]`, not an
  ## error: "no profiles yet" is a normal state for a mod to be started in.
  var out1 = "["
  let dir = guidDir(guid)
  if isDirectory(dir):
    var files: seq[string] = @[]
    var dirs: seq[string] = @[]
    collectEntries(dir, files, dirs)
    var first = true
    for f in files:
      # `collectEntries` recurses, and there is a subdirectory under here now:
      # `.hist`, holding the previous generations of every key. A path with a
      # separator in it is one of those, and reporting `profile.<id>.2` as a
      # key would hand the emulator two more profiles per real one -- each of
      # them an id it would then try to load. Skipped by shape rather than by
      # name, so anything else that ever lands in a subdirectory is skipped
      # too.
      if find(f, "\\") >= 0:
        continue
      let name = baseName(f)
      # Nothing a mod could have stored: `validKey` refuses a leading dot.
      if name.len == 0 or name[0] == '.':
        continue
      if prefix.len > 0:
        if name.len < prefix.len or name.substr(0, prefix.len - 1) != prefix:
          continue
      if not first: out1.add ","
      first = false
      out1.add "\"" & name & "\""
  out1.add "]"
  result = out1
