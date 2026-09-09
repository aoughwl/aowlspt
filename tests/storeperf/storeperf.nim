## storeperf -- decompose what one `store_set` costs.
##
##     storeperf --root PATH [--iters 200] [--size BYTES]
##
## `tools/storecrash --bench` prices the *shapes* a commit could have. This
## prices the steps of the shape it has: the create of the temporary, the
## write into it, the optional flush, the rename over the key, and the closes
## either side of it -- plus the same rename with `MOVEFILE_WRITE_THROUGH`
## taken off, which is the one flag in the sequence whose cost and whose
## guarantee are not the same thing.
##
## Everything is timed inside C around one system call at a time, because the
## cheapest step here is twenty microseconds and anything coarser reports the
## interesting ones as zero.

import std/[strutils, syncio, cmdline]
import aowlsptinstall/[winfs, log]
import modstore

{.emit: """#include <stdlib.h>""".}
{.emit: """#include <string.h>""".}
{.emit: """#include <stdint.h>""".}
{.emit: """#include <windows.h>""".}

{.emit: """
static int64_t sp_us(void) {
  LARGE_INTEGER v, f;
  QueryPerformanceCounter(&v);
  QueryPerformanceFrequency(&f);
  return (int64_t)((v.QuadPart / f.QuadPart) * 1000000LL +
                   ((v.QuadPart % f.QuadPart) * 1000000LL) / f.QuadPart);
}

/* One commit, exactly as `modstore.atomicPut` does it, with every step timed
 * separately. parts[]: 0 create, 1 write, 2 flush, 3 rename, 4 close. */
int sp_commit(const char* tmp, const char* dst, const char* buf, int len,
              int writeThrough, int doFlush, int keepOpen, int64_t* parts) {
  int64_t t0, t1;
  DWORD put = 0;
  DWORD flags = MOVEFILE_REPLACE_EXISTING;
  HANDLE h;
  if (writeThrough) flags |= MOVEFILE_WRITE_THROUGH;
  t0 = sp_us();
  h = CreateFileA(tmp, GENERIC_READ | GENERIC_WRITE,
                  FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                  NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
  t1 = sp_us(); parts[0] += t1 - t0; t0 = t1;
  if (h == INVALID_HANDLE_VALUE) return 0;
  SetFilePointer(h, 0, NULL, FILE_BEGIN);
  if (!WriteFile(h, buf, (DWORD)len, &put, NULL)) { CloseHandle(h); return 0; }
  SetEndOfFile(h);
  t1 = sp_us(); parts[1] += t1 - t0; t0 = t1;
  if (doFlush) FlushFileBuffers(h);
  t1 = sp_us(); parts[2] += t1 - t0; t0 = t1;
  if (!MoveFileExA(tmp, dst, flags)) { CloseHandle(h); return 0; }
  t1 = sp_us(); parts[3] += t1 - t0; t0 = t1;
  if (!keepOpen) CloseHandle(h);
  t1 = sp_us(); parts[4] += t1 - t0;
  return 1;
}

/* The same, but the destination is replaced with ReplaceFileA, which moves the
 * old file aside to `bak` instead of deleting it. parts[]: 0 create,
 * 1 write + close, 3 replace. */
int sp_replace(const char* tmp, const char* dst, const char* bak,
               const char* buf, int len, int64_t* parts) {
  int64_t t0, t1;
  DWORD put = 0;
  HANDLE h;
  t0 = sp_us();
  h = CreateFileA(tmp, GENERIC_READ | GENERIC_WRITE,
                  FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                  NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
  t1 = sp_us(); parts[0] += t1 - t0; t0 = t1;
  if (h == INVALID_HANDLE_VALUE) return 0;
  SetFilePointer(h, 0, NULL, FILE_BEGIN);
  if (!WriteFile(h, buf, (DWORD)len, &put, NULL)) { CloseHandle(h); return 0; }
  SetEndOfFile(h);
  CloseHandle(h);
  t1 = sp_us(); parts[1] += t1 - t0; t0 = t1;
  if (!ReplaceFileA(dst, tmp, bak, REPLACEFILE_IGNORE_MERGE_ERRORS, NULL, NULL))
    return 0;
  t1 = sp_us(); parts[3] += t1 - t0;
  return 1;
}

/* One commit with the steps that might be cheaper, selectable:
 *   opt 1  create the temporary with FILE_ATTRIBUTE_TEMPORARY
 *   opt 2  rename through the handle (SetFileInformationByHandle) rather than
 *          by path (MoveFileEx), so the source is never reopened
 *   opt 4  MOVEFILE_WRITE_THROUGH
 * parts[]: 0 create, 1 write, 3 rename, 4 close. */
int sp_commit2(const char* tmp, const char* dst, const char* buf, int len,
               int opts, int64_t* parts) {
  int64_t t0, t1;
  DWORD put = 0;
  DWORD attr = (opts & 1) ? FILE_ATTRIBUTE_TEMPORARY : FILE_ATTRIBUTE_NORMAL;
  HANDLE h;
  static int sp_seq = 0;
  char tmpbuf[512];
  if (opts & 8) {
    /* A name this process has never used before, so the create cannot land on
     * a directory slot a scanner is still finishing with. */
    sprintf(tmpbuf, "%s.%d", tmp, sp_seq++);
    tmp = tmpbuf;
  }
  t0 = sp_us();
  h = CreateFileA(tmp, GENERIC_READ | GENERIC_WRITE | DELETE,
                  FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                  NULL, OPEN_ALWAYS, attr, NULL);
  t1 = sp_us(); parts[0] += t1 - t0; t0 = t1;
  if (h == INVALID_HANDLE_VALUE) return 0;
  SetFilePointer(h, 0, NULL, FILE_BEGIN);
  if (!WriteFile(h, buf, (DWORD)len, &put, NULL)) { CloseHandle(h); return 0; }
  SetEndOfFile(h);
  t1 = sp_us(); parts[1] += t1 - t0; t0 = t1;
  if (opts & 2) {
    /* FILE_RENAME_INFO with a trailing wide name. */
    char blob[1024];
    FILE_RENAME_INFO* ri = (FILE_RENAME_INFO*)blob;
    WCHAR wide[400];
    int n = MultiByteToWideChar(CP_ACP, 0, dst, -1, wide, 400);
    memset(blob, 0, sizeof(blob));
    ri->ReplaceIfExists = TRUE;
    ri->RootDirectory = NULL;
    ri->FileNameLength = (DWORD)((n - 1) * 2);
    memcpy(ri->FileName, wide, (size_t)n * 2);
    if (!SetFileInformationByHandle(h, FileRenameInfo, blob,
                                    (DWORD)(sizeof(FILE_RENAME_INFO) + n * 2))) {
      CloseHandle(h); return 0;
    }
  } else {
    DWORD flags = MOVEFILE_REPLACE_EXISTING;
    if (opts & 4) flags |= MOVEFILE_WRITE_THROUGH;
    if (!MoveFileExA(tmp, dst, flags)) { CloseHandle(h); return 0; }
  }
  t1 = sp_us(); parts[3] += t1 - t0; t0 = t1;
  CloseHandle(h);
  t1 = sp_us(); parts[4] += t1 - t0;
  return 1;
}

/* In place through a held handle: the floor, and not a commit. The handle
 * lives in C so that nimony never has to name a `HANDLE`. */
static HANDLE sp_held = NULL;

int sp_open(const char* p) {
  sp_held = CreateFileA(p, GENERIC_READ | GENERIC_WRITE,
                        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                        NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
  return sp_held != INVALID_HANDLE_VALUE;
}

int sp_inplace(const char* buf, int len, int doFlush) {
  DWORD put = 0;
  SetFilePointer(sp_held, 0, NULL, FILE_BEGIN);
  if (!WriteFile(sp_held, buf, (DWORD)len, &put, NULL)) return 0;
  if (!SetEndOfFile(sp_held)) return 0;
  if (doFlush) FlushFileBuffers(sp_held);
  return 1;
}

void sp_close(void) {
  if (sp_held && sp_held != INVALID_HANDLE_VALUE) CloseHandle(sp_held);
  sp_held = NULL;
}
""".}

proc cUs(): int64 {.importc: "sp_us", nodecl.}
proc cCommit(tmp, dst, buf: cstring; len, wt, fl, keep: int32;
             parts: ptr int64): int32 {.importc: "sp_commit", nodecl.}
proc cReplace(tmp, dst, bak, buf: cstring; len: int32;
              parts: ptr int64): int32 {.importc: "sp_replace", nodecl.}
proc cCommit2(tmp, dst, buf: cstring; len, opts: int32;
              parts: ptr int64): int32 {.importc: "sp_commit2", nodecl.}
proc cInPlace(buf: cstring; len, fl: int32): int32 {.
  importc: "sp_inplace", nodecl.}
proc cOpen(p: cstring): int32 {.importc: "sp_open", nodecl.}
proc cClose() {.importc: "sp_close", nodecl.}

const
  Usage = """
storeperf -- decompose one store_set

  storeperf --root PATH [--iters N] [--size BYTES]
"""
  Guid = "aowl.storeperf"

proc digitsOf(s: string; fallback: int): int =
  var v = 0
  var any = false
  for ch in s:
    if ch >= '0' and ch <= '9':
      v = v * 10 + (ord(ch) - ord('0'))
      any = true
  result = (if any: v else: fallback)

proc pad(s: string; n: int): string =
  result = s
  while result.len < n: result.add ' '

proc row(name: string; totalUs: int64; iters: int) =
  line "  " & pad(name, 38) & pad($(totalUs div int64(iters)), 6) & " us"

proc valueOf(size: int): string =
  var v = ""
  var i = 0
  while v.len < size:
    v.add "{\"k" & $i & "\":\""
    for j in 0 ..< 40: v.add 'x'
    v.add "\"},"
    inc i
  result = v.substr(0, size - 1)

proc runSize(root: string; size, iters: int) =
  var v = valueOf(size)
  storeInit(root)
  let dir = joinPath(storeRoot(), Guid)
  discard ensureDir(joinPath(dir, ".hist"))
  heading "value " & $v.len & " bytes, " & $iters & " writes each"

  # 1. The floor: in place through a held handle. Not a commit.
  var ip = joinPath(dir, "bench.inplace")
  discard cOpen(toCString(ip))
  discard cInPlace(toCString(v), int32(v.len), 0'i32)
  var t0 = cUs()
  for i in 0 ..< iters:
    discard cInPlace(toCString(v), int32(v.len), 0'i32)
  row("in place, held handle (not a commit)", cUs() - t0, iters)
  cClose()

  # 2. The commit as the store does it, step by step.
  var parts: array[8, int64]
  var tmp = joinPath(dir, ".hist\\bench.tmp")
  var dst = joinPath(dir, "bench.commit")
  for i in 0 ..< 8: parts[i] = 0'i64
  t0 = cUs()
  for i in 0 ..< iters:
    discard cCommit(toCString(tmp), toCString(dst), toCString(v), int32(v.len),
                    1'i32, 0'i32, 0'i32, addr parts[0])
  let totWt = cUs() - t0
  line "  commit, MOVEFILE_WRITE_THROUGH (today):"
  row("    create temporary", parts[0], iters)
  row("    write", parts[1], iters)
  row("    MoveFileEx over the key", parts[3], iters)
  row("    close", parts[4], iters)
  row("    = total", totWt, iters)

  for i in 0 ..< 8: parts[i] = 0'i64
  t0 = cUs()
  for i in 0 ..< iters:
    discard cCommit(toCString(tmp), toCString(dst), toCString(v), int32(v.len),
                    0'i32, 0'i32, 0'i32, addr parts[0])
  let totNoWt = cUs() - t0
  line "  commit, no MOVEFILE_WRITE_THROUGH:"
  row("    create temporary", parts[0], iters)
  row("    write", parts[1], iters)
  row("    MoveFileEx over the key", parts[3], iters)
  row("    = total", totNoWt, iters)

  for i in 0 ..< 8: parts[i] = 0'i64
  t0 = cUs()
  for i in 0 ..< iters:
    discard cCommit(toCString(tmp), toCString(dst), toCString(v), int32(v.len),
                    1'i32, 1'i32, 0'i32, addr parts[0])
  let totFlush = cUs() - t0
  line "  commit, with FlushFileBuffers:"
  row("    flush", parts[2], iters)
  row("    = total", totFlush, iters)

  # 3. ReplaceFile, which moves the old file aside instead of deleting it.
  for i in 0 ..< 8: parts[i] = 0'i64
  var bak = joinPath(dir, ".hist\\bench.bak")
  t0 = cUs()
  var repOk = 0
  for i in 0 ..< iters:
    if cReplace(toCString(tmp), toCString(dst), toCString(bak), toCString(v),
                int32(v.len), addr parts[0]) != 0'i32: inc repOk
  let totRep = cUs() - t0
  line "  ReplaceFileA (" & $repOk & " of " & $iters & " ok):"
  row("    create temporary", parts[0], iters)
  row("    write + close", parts[1], iters)
  row("    ReplaceFile", parts[3], iters)
  row("    = total", totRep, iters)

  # 3b. The variants worth pricing before anything is changed for good.
  var same = joinPath(dir, "bench.tmp2")
  var names: seq[string] = @["no WT, by path", "no WT, TEMPORARY attr",
                             "no WT, rename by handle",
                             "no WT, TEMPORARY + by handle",
                             "no WT, by handle, unused temp name"]
  var opts: seq[int32] = @[0'i32, 1'i32, 2'i32, 3'i32, 10'i32]
  for k in 0 ..< names.len:
    for i in 0 ..< 8: parts[i] = 0'i64
    var okc = 0
    t0 = cUs()
    for i in 0 ..< iters:
      if cCommit2(toCString(tmp), toCString(dst), toCString(v), int32(v.len),
                  opts[k], addr parts[0]) != 0'i32: inc okc
    let tot = cUs() - t0
    line "  " & names[k] & " (" & $okc & " of " & $iters & " ok):"
    row("    create / write / rename", parts[0] div int64(iters), 1)
    row("      write", parts[1], iters)
    row("      rename", parts[3], iters)
    row("    = total", tot, iters)
  # And with the temporary in the key's own directory rather than under .hist.
  for i in 0 ..< 8: parts[i] = 0'i64
  t0 = cUs()
  for i in 0 ..< iters:
    discard cCommit2(toCString(same), toCString(dst), toCString(v),
                     int32(v.len), 0'i32, addr parts[0])
  row("no WT, temporary beside the key", cUs() - t0, iters)

  # 4. And what a request actually pays, through the store.
  var error = ""
  storeFlushOnWrite(false)
  discard storeWrite(Guid, "bench.store", v, error)
  var c0 = 0
  storeCommitStats(c0)
  t0 = cUs()
  for i in 0 ..< iters:
    if not storeWrite(Guid, "bench.store", v, error):
      err "storeWrite failed: " & error
      break
  let totStore = cUs() - t0
  var c1 = 0
  storeCommitStats(c1)
  row("storeWrite (what a request pays)", totStore, iters)
  line "    commits: " & $(c1 - c0) & " for " & $iters & " writes"

  # 5. The .hist ring, per write, by forcing every write to snapshot.
  #    `storeWrite` snapshots at most once per key per five minutes, so the
  #    steady-state cost is zero; this is what one snapshot costs when it
  #    happens, so the amortised figure can be stated rather than assumed.
  for i in 0 ..< 8: parts[i] = 0'i64
  var hp = joinPath(dir, ".hist\\bench.store.1")
  t0 = cUs()
  for i in 0 ..< iters:
    discard cCommit(toCString(tmp), toCString(hp), toCString(v), int32(v.len),
                    1'i32, 0'i32, 0'i32, addr parts[0])
  row("one .hist generation, when due", cUs() - t0, iters)
  storeClose()

proc main(): int =
  var root = ""
  var iters = 200
  var sizes: seq[int] = @[]
  var i = 1
  while i <= paramCount():
    let a = paramStr(i)
    if a == "--root":
      inc i
      if i <= paramCount(): root = paramStr(i)
    elif a == "--iters":
      inc i
      if i <= paramCount(): iters = digitsOf(paramStr(i), iters)
    elif a == "--size":
      inc i
      if i <= paramCount(): sizes.add digitsOf(paramStr(i), 0)
    elif a == "-h" or a == "--help":
      echo Usage
      return 0
    inc i
  if root.len == 0:
    err "storeperf needs --root"
    return 2
  if sizes.len == 0:
    sizes = @[3000, 16000, 84024]
  discard removeTree(root)
  discard ensureDir(root)
  for s in sizes:
    runSize(root, s, iters)
  result = 0

when isMainModule:
  quit(main())
