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

# --------------------------------------------------------------- per URL
#
# The totals above say the server spent 420 ms in `store_set`. They cannot say
# *which endpoint* spent it, and that is the question every optimisation in
# this pass turned out to need: `/client/items` and
# `/client/game/profile/items/moving` have nothing in common except that they
# are both requests, and a mix that contains both reports a mean belonging to
# neither. Splitting them was previously done with arithmetic -- take the
# aggregate, subtract a run with a different mix, divide -- which is an
# estimate wearing a measurement's clothes.
#
# So a request is tagged with its URL on the way in and every phase it accounts
# for lands in that URL's row as well as in the total. The class is a
# **thread-local index**, not a string: `perfAdd` is called twelve times a
# request from sixteen workers and must not hash anything.
#
# Slot 0 is "not attributed" and is what a thread that never called `perfBegin`
# gets, because a thread-local integer starts at zero and silently charging
# that thread's work to whichever URL happens to be first is exactly the kind
# of quiet wrong answer this module exists to replace. Classes are therefore
# 1-based, and the table is only ever appended to -- it is walked under the
# same lock `perfAdd` already takes, and it never shrinks, so an index handed
# out on one request is still that URL's index on every later one.

const ClassMax = 32

var gClsUrl: array[ClassMax, string]
var gClsUs: array[ClassMax, array[PhaseCount, int64]]
var gClsN: array[ClassMax, int64]
var gClsCount = 0
var gClsOverflow = 0

var gCls {.threadvar.}: int

proc perfEnable*() =
  gPerfOn = true

proc perfOn*(): bool = gPerfOn

proc perfNow*(): int64 =
  ## Zero when profiling is off, so a caller can time unconditionally and pay
  ## nothing: `perfAdd` of a span that started at zero is discarded.
  if gPerfOn: cPerfNow() else: 0'i64

proc perfBegin*(url: string) =
  ## Tag this thread's next phases with `url`. Called once, from dispatch, as
  ## soon as the request line has been parsed.
  ##
  ## The query string is cut off: `/client/items?x=1` and `/client/items` are
  ## one endpoint, and a server that reports them as two has a table of
  ## one-request rows rather than a profile.
  if not gPerfOn:
    return
  var key = ""
  var i0 = 0
  while i0 < url.len and url[i0] != '?':
    key.add url[i0]
    inc i0
  cLock()
  var found = 0
  for i in 1 ..< gClsCount + 1:
    if gClsUrl[i] == key:
      found = i
      break
  if found == 0:
    if gClsCount + 1 < ClassMax:
      inc gClsCount
      gClsUrl[gClsCount] = key
      gClsN[gClsCount] = 0'i64
      found = gClsCount
    else:
      # Everything past the table's capacity is one row rather than none, so
      # the per-URL columns still add up to the totals.
      inc gClsOverflow
      found = ClassMax - 1
      gClsUrl[found] = "(other)"
  gClsN[found] = gClsN[found] + 1'i64
  cUnlock()
  gCls = found

proc perfAdd*(phase: int; since: int64) =
  if not gPerfOn or since == 0'i64:
    return
  let d = cPerfNow() - since
  let c = gCls
  cLock()
  gUs[phase] = gUs[phase] + d
  gN[phase] = gN[phase] + 1'i64
  if c > 0 and c < ClassMax:
    gClsUs[c][phase] = gClsUs[c][phase] + d
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

  if gClsCount == 0:
    return
  result.add ""
  result.add "  per endpoint, mean microseconds a request (route excludes its children)"
  var hdr = "  url"
  while hdr.len < 42: hdr.add ' '
  hdr.add "    n"
  for i in 0 ..< PhaseCount:
    if gN[i] == 0'i64:
      continue
    var h = PhaseNames[i]
    var t = ""
    for ch in h:
      if ch != ' ': t.add ch
    while t.len < 10: t = " " & t
    hdr.add t
  result.add hdr
  for c in 1 ..< gClsCount + 1:
    if gClsN[c] == 0'i64:
      continue
    var row = "  " & gClsUrl[c]
    while row.len < 42: row.add ' '
    var n = $gClsN[c]
    while n.len < 5: n = " " & n
    row.add n
    for i in 0 ..< PhaseCount:
      if gN[i] == 0'i64:
        continue
      var v = gClsUs[c][i]
      # `route` is printed net of the calls it contains, because the gross
      # figure repeats every host call in two columns and the number anyone
      # reads this table for is the mod's own share.
      if i == PhaseRoute:
        for k in PhaseDbGet ..< PhaseCount:
          v = v - gClsUs[c][k]
      var t = $(v div gClsN[c])
      while t.len < 10: t = " " & t
      row.add t
    result.add row
  if gClsOverflow > 0:
    result.add "  " & $gClsOverflow & " requests to URLs past the " &
               $(ClassMax - 1) & " the table holds are in `(other)`"

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
