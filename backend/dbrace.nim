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
##   * A **key list** must describe the object as it is. `dbKeysPath` answers
##     out of a names table that lives beside the member table and has to be
##     invalidated in the same three places, and a miss there does not look
##     like a torn read at all: it is a well-formed list of names describing
##     the object as it was before somebody's patch. So it is counted apart
##     from `torn`, and the check that pins it is in the **writer** -- a
##     thread adds a member nobody has ever added and then, in program order,
##     asks that object for its keys. No window, no interleaving, no argument:
##     an answer without that name is a stale table.
##
## The contract those key lists answer to is checked first and single-threaded
## -- `checkKeysContract`, one row per line of the table at the end of
## `docs/API-GAPS.md`'s gap 2, and the row that matters most is that an object
## with no members answers `[]` while an absent path is refused.
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

/* A held read, probed through the raw pointer `dbHoldPath` hands back.
 *
 * `hostDbGet` no longer copies the value into a nimony string before handing
 * it to the host: it takes the document's own bytes and copies once, with the
 * read lock held for the length of that copy. The pointer is therefore into
 * `gDoc`'s live buffer, and what would go wrong is precisely what this file
 * exists to catch -- a splice moving those bytes, or a growth freeing the page
 * they are on, while the copy is in progress.
 *
 * So this touches one byte per 4 KB page across the whole value, which is what
 * turns a freed buffer into an access violation here rather than into a
 * plausible-looking answer somewhere else, and returns whether the value still
 * begins `{` and ends `}`. A `templates.items` that does not is a range out of
 * the middle of the document. */
static LONG64 aowl_race_held = 0;
static void    aowl_race_bump_held(void) { InterlockedIncrement64(&aowl_race_held); }
static int64_t aowl_race_get_held(void)  { return (int64_t)InterlockedCompareExchange64(&aowl_race_held, 0, 0); }

/* Key enumeration, counted separately from the reads.
 *
 * `aowl_race_keys` is how many key lists were answered and `aowl_race_stale`
 * is how many of them were wrong -- which is a different failure from a torn
 * read and has to be counted apart from one, because it is the failure a torn
 * read cannot produce: a *well-formed* list of names that describes the object
 * as it was before somebody's patch. The names table is a second thing to
 * invalidate, and `docs/API-GAPS.md` says in as many words that a miss there
 * is "the exact failure mode the anchor-coordinate design exists to refuse".
 *
 * Atomic for the same reason everything else here is: a count of wrong
 * answers, incremented with `++` from twenty threads, can read zero. */
static LONG64 aowl_race_keys  = 0;
static LONG64 aowl_race_stale = 0;
static void    aowl_race_bump_keys(void)  { InterlockedIncrement64(&aowl_race_keys); }
static void    aowl_race_bump_stale(void) { InterlockedIncrement64(&aowl_race_stale); }
static int64_t aowl_race_get_keys(void)   { return (int64_t)InterlockedCompareExchange64(&aowl_race_keys, 0, 0); }
static int64_t aowl_race_get_stale(void)  { return (int64_t)InterlockedCompareExchange64(&aowl_race_stale, 0, 0); }

static int32_t aowl_race_probe(const char* p, int32_t n) {
    if (p == 0 || n < 2) return 0;
    volatile int32_t acc = 0;
    for (int32_t i = 0; i < n; i += 4096) acc += (unsigned char)p[i];
    acc += (unsigned char)p[n - 1];
    return (p[0] == '{' && p[n - 1] == '}') ? 1 : 0;
}

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
proc cBumpHeld() {.importc: "aowl_race_bump_held", nodecl.}
proc cGetHeld(): int64 {.importc: "aowl_race_get_held", nodecl.}
proc cBumpKeys() {.importc: "aowl_race_bump_keys", nodecl.}
proc cBumpStale() {.importc: "aowl_race_bump_stale", nodecl.}
proc cGetKeys(): int64 {.importc: "aowl_race_get_keys", nodecl.}
proc cGetStale(): int64 {.importc: "aowl_race_get_stale", nodecl.}
proc cRaceProbe(p: pointer; n: int32): int32 {.importc: "aowl_race_probe", nodecl.}
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

  # The key list of `stable`, which nobody ever patches and which therefore has
  # exactly one right answer for the whole run. The document's own spelling and
  # its own order: `dbKeysPath` promises document order and promises nothing
  # about it surviving a patch, and this object is never patched.
  StableKeys = "[\"a\",\"b\",\"c\",\"d\"]"

  # The corner the contract is checked in. Every case in the table at the end
  # of `docs/API-GAPS.md`'s gap 2 has a member here:
  #
  #   * `keys.empty`  -- an object with no members. Answers `[]` and **not**
  #     `ErrNotFound`, which is the distinction the whole contract turns on.
  #   * `keys.list`   -- an array. Refused, and not answered `["0","1",...]`.
  #   * `keys.number` -- a scalar. Refused with the same reason.
  #   * `keys.odd`    -- names with a dot, a space and an escaped quote in
  #     them, because the answer is supposed to be the document's own spelling
  #     of a name and not a re-escaping of it. A caller has to be able to hand
  #     the name straight back to `db_get`.
  #   * `keys.churn`  -- the one writers add members to. See `raceWriter`.
  KeysCorner = "\"keys\":{\"empty\":{},\"list\":[1,2,3,4]," &
               "\"number\":42,\"odd\":{\"a.b\":1,\"with space\":2," &
               "\"quo\\\"te\":3},\"churn\":{\"base\":0}}"
  OddKeys = "[\"a.b\",\"with space\",\"quo\\\"te\"]"

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
           ",\"c\":" & StableC & ",\"d\":" & StableD & "}," & KeysCorner &
           ",\"templates\":{\"items\":{"
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

# --------------------------------------------------------- the keys contract
#
# `docs/API-GAPS.md`, gap 2, ends with a table of the answers a caller needs,
# and the reason it is a table rather than a sentence is that two of the rows
# look alike and are not: **absent** and **an object with no members**. A
# wrapper that folds those together lets a mod create a table over the top of
# one it failed to read, which is a data-loss bug that presents as a mod that
# "did not load properly".
#
# So each row is checked here, single-threaded, before any thread starts --
# the same reason `checkStable` runs once before `cStart`: a test whose checks
# are wrong passes concurrently for the wrong reason. Each of these fails
# against the code as it was, because against the code as it was `dbKeysPath`
# does not exist at all; what each one is really pinning is the answer, and
# the comment on each says which mistake would produce a different one.

proc keysAre(path, want: string; what: string): bool =
  var got = ""
  var why = 0
  if not dbKeysPath(path, got, why):
    echo "error " & what & ": refused (" & $why & "), wanted " & want
    return false
  if got != want:
    echo "error " & what & ": " & got & ", wanted " & want
    return false
  echo "ok    " & what
  result = true

proc keysRefused(path: string; wantWhy: int; what: string): bool =
  var got = ""
  var why = 0
  if dbKeysPath(path, got, why):
    echo "error " & what & ": answered " & got
    return false
  if why != wantWhy:
    echo "error " & what & ": refused with " & $why & ", wanted " & $wantWhy
    return false
  echo "ok    " & what
  result = true

proc checkKeysContract(): int =
  ## The number of contract rows that failed. Zero is the only passing answer.
  result = 0

  # An object answers its member names, in document order.
  if not keysAre("stable", StableKeys,
                 "an object answers its member names, in document order"):
    inc result

  # An empty object answers `[]` -- and this is the line that fails if
  # `dbKeysPath` folds "no members" into "no such path", which is the mistake
  # the whole contract exists to prevent.
  if not keysAre("keys.empty", "[]",
                 "an object with no members answers [] and not a refusal"):
    inc result

  # An absent path is NotFound, and it is a *different* answer from the line
  # above. Fails if the two are ever collapsed into one status.
  if not keysRefused("keys.nosuchthing", KeysNoSuchPath,
                     "an absent path is not found, distinctly from an " &
                     "empty object"):
    inc result

  # An array is BadArg. Fails if `dbKeysPath` ever answers `["0","1",...]`,
  # which for a hundred thousand elements is a 700 KB reply to a question
  # whose real form is "how long is it".
  if not keysRefused("keys.list", KeysNotAnObject,
                     "an array is refused as bad argument, not answered " &
                     "with indices"):
    inc result

  # A scalar is BadArg, with the same reason.
  if not keysRefused("keys.number", KeysNotAnObject,
                     "a scalar is refused with the same reason as an array"):
    inc result

  # The names are the document's own spelling. Fails if anything re-escapes
  # them, because a caller has to be able to hand a name straight back to
  # `db_get` and a re-escaped one names a member that is not there.
  if not keysAre("keys.odd", OddKeys,
                 "a name with a dot, a space and an escaped quote comes " &
                 "back spelled as the document spells it"):
    inc result

  # And the sigil that carries all of this over `db_get` without an ABI entry.
  var rest = "unset"
  if not dbKeysRequest(KeysSigil & "locations", rest) or rest != "locations":
    echo "error the sigil splits off the path it is asking about: " & rest
    inc result
  else:
    echo "ok    the sigil splits off the path it is asking about"
  rest = "unset"
  if dbKeysRequest("locations", rest) or rest.len != 0:
    echo "error an ordinary path is not a key request: " & rest
    inc result
  else:
    echo "ok    an ordinary path is not a key request"
  # The capability probe. `"?keys "` with nothing after it is a key request
  # with an empty path -- which a host that implements this refuses as a bad
  # argument and a host that does not reports as a missing root member. That
  # difference is the whole of how a mod asks "can you do this", and it is why
  # this returns true with an empty `rest` rather than false.
  rest = "unset"
  if not dbKeysRequest(KeysSigil, rest) or rest.len != 0:
    echo "error the bare sigil is a request with an empty path: " & rest
    inc result
  else:
    echo "ok    the bare sigil is a request with an empty path"

proc looksLikeName(v: string): bool =
  ## A name is either the original or something a writer put there. Anything
  ## else -- a fragment, a value with a brace in it, an empty string -- is a
  ## read that overlapped a splice.
  if v == "\"original\"":
    return true
  if v.len < 3 or v[0] != '"' or v[v.len - 1] != '"':
    return false
  result = v.startsWith("\"w")

proc nameAt(arrayText: string; index: int): string =
  ## The `index`-th name out of a `["a","b"]` answer, wrapping. Only ever
  ## called on names this test wrote, all of which are plain ASCII, so this
  ## does not decode escapes and does not need to.
  result = ""
  var starts: seq[int] = @[]
  var stops: seq[int] = @[]
  var i = 0
  var inStr = false
  var from1 = 0
  while i < arrayText.len:
    let c = arrayText[i]
    if inStr:
      if c == '"':
        inStr = false
        starts.add from1
        stops.add i
    elif c == '"':
      inStr = true
      from1 = i + 1
    inc i
  if starts.len == 0:
    return ""
  let k = index mod starts.len
  result = arrayText.substr(starts[k], stops[k] - 1)

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

    # And the same table again through `dbHoldPath`, which is the path
    # `hostDbGet` actually takes: no nimony string in the middle, the document's
    # own bytes read under the read lock and released after. It is a different
    # hazard from the `substr` above even though it is the same lock -- the
    # copy there is made by code that owns the buffer it writes into, and the
    # copy here is made by the host allocator through a pointer this thread was
    # handed. If the lock is doing less than it claims, this is where a splice
    # lands in the middle of somebody else's read.
    var at = cast[pointer](0)
    var held = 0
    if not dbHoldPath("templates.items", at, held):
      cBumpMissing()
    else:
      let shape = cRaceProbe(at, int32(held))
      dbRelease()
      if shape == 0'i32:
        cBumpTorn()
      else:
        cBumpHeld()

    # ---------------------------------------------------------- the key lists
    #
    # The names table is shared state under the same document lock as
    # everything above, and it is a *second* thing to invalidate: every place
    # that drops a member table has to drop the matching names, and a miss
    # there is stale names against a re-anchored document. That failure does
    # not look like a torn read. It looks like a perfectly well-formed list of
    # member names describing the object as it was before somebody's patch,
    # which is why it is counted separately from `torn`.
    var why = 0

    # An object nobody patches has exactly one right key list for the whole
    # run, and this is the equality that says so. It is the `checkStable` of
    # key enumeration: an answer that is not this one came from somewhere else.
    var sk = ""
    if not dbKeysPath("stable", sk, why):
      cBumpMissing()
    elif sk != StableKeys:
      cBumpStale()
    else:
      cBumpKeys()

    # The object writers add members to. Nothing ever *removes* a member, so
    # every name it hands back must resolve as a path right now -- a name that
    # does not is one this reader was given after the text behind it moved.
    var ck = ""
    if not dbKeysPath("keys.churn", ck, why):
      cBumpMissing()
    else:
      cBumpKeys()
      let name = nameAt(ck, spin)
      if name.len > 0:
        var probe = ""
        if not dbGetPath("keys.churn." & name, probe):
          cBumpStale()

    # And the big table's key list, every sixteenth pass rather than every
    # pass: four thousand names is a 50 KB answer, which is the right order of
    # magnitude to be worth checking under a splice and the wrong one to copy
    # seventy thousand times in eight seconds. Its members are patched
    # constantly and its *membership* never changes, so the first and last
    # names are an equality even while every value in it is moving.
    if (spin and 15) == 0:
      var bk = ""
      if not dbKeysPath("templates.items", bk, why):
        cBumpMissing()
      elif not startsWith(bk, "[\"" & itemId(0) & "\",") or
           not endsWith(bk, ",\"" & itemId(gItems - 1) & "\"]"):
        cBumpStale()
      else:
        cBumpKeys()

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

    # ------------------------------------------- the invalidation check
    #
    # This is the one that cannot give a false positive and cannot be argued
    # away, and it is why the check lives in the *writer*.
    #
    # A member is added to `keys.churn` that has never existed, and then this
    # same thread asks for that object's keys. The patch happened before the
    # read, in one thread, in program order -- so there is no window and no
    # interleaving to reason about. If the answer does not contain the name
    # this thread has just written, the names table handed back what it
    # remembered instead of what is there, and that is the whole failure mode
    # in one line.
    #
    # Every 128th write rather than every write, for a reason worth writing
    # down: nothing here ever removes a member, so `keys.churn` only grows,
    # and a new member per write would make it twenty thousand names long and
    # turn this check into the thing the test spends its time on.
    if (n and 127) == 0:
      let fresh = "w" & $which & "_" & $n
      var e2 = ""
      if dbPatchPath("keys.churn", "{\"" & fresh & "\":1}", e2):
        var ck = ""
        var why = 0
        if not dbKeysPath("keys.churn", ck, why):
          cBumpMissing()
        elif find(ck, "\"" & fresh & "\"") < 0:
          cBumpStale()
        else:
          cBumpKeys()
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

  let contract = checkKeysContract()
  if contract > 0:
    echo ""
    echo "error " & $contract & " rows of the key-enumeration contract are wrong"
    return 1
  echo ""

  cStart(int32(readers), int32(writers))
  cJoin(int32(seconds * 1000))

  let reads = cReads()
  let writes = cWrites()
  let torn = cTorn()
  let missing = cMissing()

  echo ""
  echo "Result"
  echo "------"
  echo "  reads     " & $reads & " passes (" & $(reads * 5) & " values)"
  echo "  held      " & $cGetHeld() & " of those read the table through " &
       "`dbHoldPath`, the pointer `hostDbGet` copies from"
  echo "  writes    " & $writes
  let keys = cGetKeys()
  let stale = cGetStale()
  echo "  keys      " & $keys & " key lists answered, including one per " &
       "writer that asked for the object it had just added a member to"
  if torn == 0 and missing == 0 and stale == 0:
    echo "ok    no torn read, no path lost and no stale key list across " &
         $reads & " concurrent read passes against " & $writes & " writes"
    return 0
  if torn > 0:
    echo "error " & $torn & " reads answered with text that was never in the document"
  if missing > 0:
    echo "error " & $missing & " reads reported a path that is there as missing"
  if stale > 0:
    echo "error " & $stale & " key lists described the object as it was " &
         "before a patch, not as it is"
  result = 1

quit(main())
