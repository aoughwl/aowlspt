## dbrace -- the database under concurrent readers and a writer.
##
##     dbrace [--readers 8] [--writers 2] [--seconds 3] [--items 4000]
##
## Every other gate in this repo drives the backend one request at a time.
## `benchbackend` reuses a single connection; `emutest`, `soak` and `fuzzwire`
## are one client each. That is the right shape for asking whether an answer is
## correct, and it is exactly the wrong shape for asking whether two answers can
## be produced at once -- which is the question `jsondb.nim` had left open, and
## a question a game server answers sixteen threads at a time.
##
## So this is the missing shape: readers and writers on the document at the same
## time, in one process, with no sockets in the way.
##
## **What it checks is not "did it crash".** A crash is the loudest way this
## fails and not the likeliest; the likeliest is a reader handed a byte range
## out of the middle of a value some other thread has just rewritten, which is a
## perfectly well-formed answer about the wrong item. So every read is of a
## value the test knows the exact text of, and the check is equality:
##
##   * `stable.a` .. `stable.d` are never patched by anyone. A reader that gets
##     anything but their known text has been handed somebody else's bytes.
##   * `items.<id>.name` *is* patched, and a reader may legitimately see either
##     the old text or the new. Anything that is neither is a torn read.
##   * A path that exists must never be reported as missing. This is the one the
##     old global `gRestart` flag broke: two readers sharing one restart flag
##     lose each other's retries, and a lost retry is a 404 for an item that is
##     right there.
##
## Run against a `jsondb.nim` with the document lock taken out -- the copy in
## the report is four lines different -- it fails inside a second, usually by
## access violation and otherwise on the equality. Run against this one it does
## not, which is the only evidence worth having that the lock is doing anything.

import std/[strutils, cmdline, syncio]
import jsondb

{.emit: """#include <windows.h>""".}
{.emit: """#include <stdint.h>""".}

{.emit: """
/* The counters have to be atomic even in a test whose whole subject is what is
 * not: a mismatch counted with `++` from eight threads is a mismatch count that
 * can read zero. */
static LONG64 aowl_race_reads   = 0;
static LONG64 aowl_race_writes  = 0;
static LONG64 aowl_race_torn    = 0;
static LONG64 aowl_race_missing = 0;
static LONG   aowl_race_stop    = 0;

static void    aowl_race_bump_read(void)    { InterlockedIncrement64(&aowl_race_reads); }
static void    aowl_race_bump_write(void)   { InterlockedIncrement64(&aowl_race_writes); }
static void    aowl_race_bump_torn(void)    { InterlockedIncrement64(&aowl_race_torn); }
static void    aowl_race_bump_missing(void) { InterlockedIncrement64(&aowl_race_missing); }
static int64_t aowl_race_get_reads(void)    { return (int64_t)InterlockedCompareExchange64(&aowl_race_reads, 0, 0); }
static int64_t aowl_race_get_writes(void)   { return (int64_t)InterlockedCompareExchange64(&aowl_race_writes, 0, 0); }
static int64_t aowl_race_get_torn(void)     { return (int64_t)InterlockedCompareExchange64(&aowl_race_torn, 0, 0); }
static int64_t aowl_race_get_missing(void)  { return (int64_t)InterlockedCompareExchange64(&aowl_race_missing, 0, 0); }
static int32_t aowl_race_running(void)      { return InterlockedCompareExchange(&aowl_race_stop, 0, 0) ? 0 : 1; }
static void    aowl_race_halt(void)         { InterlockedExchange(&aowl_race_stop, 1); }

/* nimony emits the definitions of these below this block, so they are declared
 * here rather than assumed. */
int32_t aowl_race_reader(int32_t which);
int32_t aowl_race_writer(int32_t which);

static DWORD WINAPI aowl_race_reader_thunk(LPVOID p) {
    return (DWORD)aowl_race_reader((int32_t)(intptr_t)p);
}
static DWORD WINAPI aowl_race_writer_thunk(LPVOID p) {
    return (DWORD)aowl_race_writer((int32_t)(intptr_t)p);
}

/* Readers and writers are started interleaved rather than all-readers-then-all-
 * writers. Started in blocks, the writers reliably arrive after the readers
 * have already indexed everything they touch, and the window this exists to hit
 * -- a splice landing in the middle of a `substr` -- is at its narrowest. */
#define AOWL_RACE_MAX 64
static HANDLE aowl_race_threads[AOWL_RACE_MAX];
static int32_t aowl_race_n = 0;

static void aowl_race_start(int32_t readers, int32_t writers) {
    int32_t r = 0, w = 0;
    aowl_race_n = 0;
    while ((r < readers || w < writers) && aowl_race_n < AOWL_RACE_MAX) {
        if (r < readers) {
            aowl_race_threads[aowl_race_n++] =
                CreateThread(NULL, 0, aowl_race_reader_thunk, (LPVOID)(intptr_t)r, 0, NULL);
            r++;
        }
        if (w < writers && aowl_race_n < AOWL_RACE_MAX) {
            aowl_race_threads[aowl_race_n++] =
                CreateThread(NULL, 0, aowl_race_writer_thunk, (LPVOID)(intptr_t)w, 0, NULL);
            w++;
        }
    }
}

static void aowl_race_join(int32_t ms) {
    Sleep((DWORD)ms);
    aowl_race_halt();
    for (int32_t i = 0; i < aowl_race_n; i++) {
        if (aowl_race_threads[i] != NULL) {
            WaitForSingleObject(aowl_race_threads[i], 10000);
            CloseHandle(aowl_race_threads[i]);
        }
    }
}
""".}

proc cBumpRead() {.importc: "aowl_race_bump_read", nodecl.}
proc cBumpWrite() {.importc: "aowl_race_bump_write", nodecl.}
proc cBumpTorn() {.importc: "aowl_race_bump_torn", nodecl.}
proc cBumpMissing() {.importc: "aowl_race_bump_missing", nodecl.}
proc cReads(): int64 {.importc: "aowl_race_get_reads", nodecl.}
proc cWrites(): int64 {.importc: "aowl_race_get_writes", nodecl.}
proc cTorn(): int64 {.importc: "aowl_race_get_torn", nodecl.}
proc cMissing(): int64 {.importc: "aowl_race_get_missing", nodecl.}
proc cRunning(): int32 {.importc: "aowl_race_running", nodecl.}
proc cStart(readers, writers: int32) {.importc: "aowl_race_start", nodecl.}
proc cJoin(ms: int32) {.importc: "aowl_race_join", nodecl.}

const
  Usage = """
dbrace -- the database under concurrent readers and a writer

  dbrace [options]

  --readers N   reader threads (default 8)
  --writers N   writer threads (default 2)
  --seconds N   how long to run (default 3)
  --items N     item templates in the generated database (default 4000)
  -h, --help    this
"""

  # Four members nobody patches, with text distinctive enough that a wrong
  # answer is obviously wrong rather than plausibly right.
  StableA = "\"the first value, which nothing ever writes to\""
  StableB = "1234567890"
  StableC = "[1,2,3,4,5,6,7,8,9,10]"
  StableD = "{\"nested\":{\"deeper\":\"and deeper still, so the walk has depth\"}}"

var gItems = 4000

proc intOf(s: string; fallback: int): int =
  ## `parseInt` raises, and a test binary whose argument parsing can throw is a
  ## test binary that reports a bad flag as a crash.
  result = 0
  var any = false
  for ch in s:
    if ch >= chr(48) and ch <= chr(57):
      result = result * 10 + (ord(ch) - 48)
      any = true
    else:
      return fallback
  if not any: return fallback

proc itemId(i: int): string =
  ## Fixed width, so no id is a prefix of another.
  result = "item"
  var n = $i
  while n.len < 6:
    n = "0" & n
  result.add n

proc buildDoc(): string =
  ## A document with the shape the real one has: one very large object of
  ## uniform members, reached through a couple of levels, plus the stable
  ## corner. Large enough that the `substr` answering a whole-table read is a
  ## real copy rather than a rounding error.
  result = "{\"stable\":{\"a\":" & StableA & ",\"b\":" & StableB &
           ",\"c\":" & StableC & ",\"d\":" & StableD & "},\"templates\":{\"items\":{"
  for i in 0 ..< gItems:
    if i > 0: result.add ","
    result.add "\"" & itemId(i) & "\":{\"name\":\"original\",\"_props\":{" &
               "\"Weight\":1.5,\"Width\":1,\"Height\":1,\"StackMaxSize\":1," &
               "\"Description\":\"padding so the document is worth copying\"}}"
  result.add "}}}"

proc checkStable(): bool =
  ## Every one of the four, every pass. A reader that gets a wrong answer here
  ## has been handed bytes belonging to something else.
  result = true
  var v = ""
  if not dbGetPath("stable.a", v):
    cBumpMissing()
    return false
  if v != StableA:
    cBumpTorn()
    result = false
  if not dbGetPath("stable.b", v):
    cBumpMissing()
    return false
  if v != StableB:
    cBumpTorn()
    result = false
  if not dbGetPath("stable.c", v):
    cBumpMissing()
    return false
  if v != StableC:
    cBumpTorn()
    result = false
  if not dbGetPath("stable.d", v):
    cBumpMissing()
    return false
  if v != StableD:
    cBumpTorn()
    result = false

proc looksLikeName(v: string): bool =
  ## A name is either the original or something a writer put there. Anything
  ## else -- a fragment, a value with a brace in it, an empty string -- is a
  ## read that overlapped a splice.
  if v == "\"original\"":
    return true
  if v.len < 3 or v[0] != '"' or v[v.len - 1] != '"':
    return false
  result = v.startsWith("\"w")

proc raceReader(which: int32): int32 {.exportc: "aowl_race_reader", cdecl.} =
  ## One reader. It does the two things the game does -- read a whole table,
  ## and read one field of one item -- and checks the corner nobody writes to
  ## in between, because that is the check that catches a wrong answer rather
  ## than only a crash.
  var spin = int(which) * 37
  while cRunning() != 0'i32:
    discard checkStable()

    # One field of one item, the shape `items/moving` reads.
    spin = (spin * 1103515245 + 12345) and 0x7FFFFFFF
    let id = itemId(spin mod gItems)
    var v = ""
    if not dbGetPath("templates.items." & id & ".name", v):
      # The path is in the document from the first byte and no writer ever
      # removes it, so missing is always wrong.
      cBumpMissing()
    elif not looksLikeName(v):
      cBumpTorn()

    var w = ""
    if not dbGetPath("templates.items." & id & "._props.Width", w):
      cBumpMissing()
    elif w != "1":
      cBumpTorn()

    # And the whole table, which is the multi-megabyte `substr` that
    # `/client/items` is: the copy long enough for a splice to land inside it.
    var all = ""
    if not dbGetPath("templates.items", all):
      cBumpMissing()
    elif all.len < 16 or all[0] != '{' or all[all.len - 1] != '}':
      cBumpTorn()
    cBumpRead()
  result = 0'i32

proc raceWriter(which: int32): int32 {.exportc: "aowl_race_writer", cdecl.} =
  ## One writer. Two kinds of patch, because they fail differently: one that
  ## fits where it is (a splice, no allocation) and one that grows the document
  ## past its capacity (a reallocation, which is what turns a torn read into a
  ## use-after-free).
  var n = int(which) * 1000
  while cRunning() != 0'i32:
    inc n
    let id = itemId((n * 7919) mod gItems)
    var err = ""
    var pad = ""
    # Growing and shrinking in turn, so the buffer is reallocated repeatedly
    # rather than growing once and then never again.
    let width = 1 + (n mod 64)
    var k = 0
    while k < width:
      pad.add "x"
      inc k
    discard dbPatchPath("templates.items." & id,
                        "{\"name\":\"w" & $which & "-" & $n & "-" & pad & "\"}",
                        err)
    cBumpWrite()
  result = 0'i32

proc main(): int =
  var readers = 8
  var writers = 2
  var seconds = 3
  var i = 1
  while i <= paramCount():
    let a = paramStr(i)
    if a == "--readers" and i < paramCount():
      inc i
      readers = intOf(paramStr(i), readers)
    elif a == "--writers" and i < paramCount():
      inc i
      writers = intOf(paramStr(i), writers)
    elif a == "--seconds" and i < paramCount():
      inc i
      seconds = intOf(paramStr(i), seconds)
    elif a == "--items" and i < paramCount():
      inc i
      gItems = intOf(paramStr(i), gItems)
    elif a == "--help" or a == "-h":
      echo Usage
      return 0
    else:
      echo "unknown option: " & a
      return 1
    inc i

  if readers < 1: readers = 1
  if writers < 0: writers = 0
  if seconds < 1: seconds = 1

  echo "dbrace"
  echo "------"
  let doc = buildDoc()
  dbLoad(doc)
  echo "  document  " & $(doc.len div 1024) & " KiB, " & $gItems & " items"
  echo "  threads   " & $readers & " readers, " & $writers & " writers"
  echo "  duration  " & $seconds & " s"
  echo ""

  # One pass single-threaded first. A test whose checks are wrong passes
  # concurrently for the wrong reason, and this is the cheapest way to know
  # they are right before anything is racing.
  if not checkStable():
    echo "error the stable values do not read back before any thread starts"
    return 1
  echo "ok    the stable values read back single-threaded"

  cStart(int32(readers), int32(writers))
  cJoin(int32(seconds * 1000))

  let reads = cReads()
  let writes = cWrites()
  let torn = cTorn()
  let missing = cMissing()

  echo ""
  echo "Result"
  echo "------"
  echo "  reads     " & $reads & " passes (" & $(reads * 4) & " values)"
  echo "  writes    " & $writes
  if torn == 0 and missing == 0:
    echo "ok    no torn read and no path lost across " & $reads &
         " concurrent read passes against " & $writes & " writes"
    return 0
  if torn > 0:
    echo "error " & $torn & " reads answered with text that was never in the document"
  if missing > 0:
    echo "error " & $missing & " reads reported a path that is there as missing"
  result = 1

quit(main())
