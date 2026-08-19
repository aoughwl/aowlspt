## Per-phase timing for the backend. Off unless `--perf` is passed.
##
## The point of this module is to make "where does a request's time go" a
## measurement rather than an argument. A round-trip number from
## `benchbackend` says how long an answer took; it cannot say whether that was
## zlib, the database, the profile store, or the socket, and every
## optimisation that follows from a guess about which is a guess.
##
## Phases are accumulated per name in microseconds, with a count, and printed
## once at exit. Nested phases are deliberately allowed and overlap: `route`
## contains `db_get`, `store_set` and the rest, so the difference between
## `route` and the sum of its children is the mod's own work. That is the
## number the whole exercise is after.
##
## When `--perf` is off this costs one predictable branch per call site and
## nothing else -- no clock read, no lock. It is left in the tree rather than
## deleted because the next person to make a performance claim about this
## server needs the same instrument, and rewriting it is how the claim ends up
## resting on intuition again.

{.emit: """#include <stdint.h>""".}
{.emit: """#include "aowlspt_lock.h" """.}

{.emit: """
/* QPC, as everywhere else here: a database lookup answers in single-digit
 * microseconds and a millisecond clock reports that as zero. */
static int64_t aowl_perf_qpc_us(void) {
  LARGE_INTEGER v, f;
  QueryPerformanceCounter(&v);
  QueryPerformanceFrequency(&f);
  return (int64_t)((v.QuadPart / f.QuadPart) * 1000000LL +
                   ((v.QuadPart % f.QuadPart) * 1000000LL) / f.QuadPart);
}
""".}

proc cPerfNow(): int64 {.importc: "aowl_perf_qpc_us", nodecl.}
proc cLock() {.importc: "aowl_lock", nodecl.}
proc cUnlock() {.importc: "aowl_unlock", nodecl.}

const
  PhaseInflate* = 0
  PhaseMatch* = 1
  PhaseRoute* = 2
  PhaseDeflate* = 3
  PhaseSend* = 4
  PhaseDbGet* = 5
  PhaseDbPatch* = 6
  PhaseStoreGet* = 7
  PhaseStoreSet* = 8
  PhaseStoreList* = 9
  PhaseLog* = 10
  PhaseCount = 11

const PhaseNames: array[PhaseCount, string] = [
  "inflate", "match", "route", "deflate", "send",
  "  db_get", "  db_patch", "  store_get", "  store_set", "  store_list",
  "  log"]

var gPerfOn = false
var gUs: array[PhaseCount, int64]
var gN: array[PhaseCount, int64]

proc perfEnable*() =
  gPerfOn = true

proc perfOn*(): bool = gPerfOn

proc perfNow*(): int64 =
  ## Zero when profiling is off, so a caller can time unconditionally and pay
  ## nothing: `perfAdd` of a span that started at zero is discarded.
  if gPerfOn: cPerfNow() else: 0'i64

proc perfAdd*(phase: int; since: int64) =
  if not gPerfOn or since == 0'i64:
    return
  let d = cPerfNow() - since
  cLock()
  gUs[phase] = gUs[phase] + d
  gN[phase] = gN[phase] + 1'i64
  cUnlock()

proc usText(us: int64): string =
  let whole = us div 1000'i64
  var f = $(us mod 1000'i64)
  while f.len < 3: f = "0" & f
  result = $whole & "." & f

proc perfReport*(requests: int): seq[string] =
  ## One line per phase: total milliseconds, calls, and mean microseconds.
  ## Returned rather than printed so the caller decides where it goes.
  result = @[]
  if not gPerfOn:
    return
  result.add "  phase          total ms     calls     mean us"
  for i in 0 ..< PhaseCount:
    if gN[i] == 0'i64:
      continue
    var row = PhaseNames[i]
    while row.len < 15: row.add ' '
    var t = usText(gUs[i])
    while t.len < 10: t = " " & t
    row.add t
    var c = $gN[i]
    while c.len < 10: c = " " & c
    row.add c
    var m = $(gUs[i] div gN[i])
    while m.len < 12: m = " " & m
    row.add m
    result.add row
  result.add "  " & $requests & " requests; `route` includes the indented rows"

proc perfCacheLine*(hits, misses, skipped: int): string =
  ## The compressed-body cache's hit rate.
  ##
  ## The whole design rests on the static tables being asked for repeatedly and
  ## the answer being the same bytes every time. That is an assumption about
  ## the client, and an assumption about the client is a thing to print rather
  ## than a thing to believe -- a cache that has quietly stopped hitting looks
  ## exactly like a cache that is working, from inside the server.
  result = "  zcache " & $hits & " hits, " & $misses & " misses, " &
           $skipped & " bodies under the size it caches"
