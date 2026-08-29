## realtest -- drive the Tarkov emulator against an *imported* database.
##
##     realtest --root <stage> --db build\db\db.json --backend <backend.exe>
##
## `emutest` and `soak` are written against `tests/fixtures/emu-full.json`, and
## they are pinned to it by identity: they buy `item_id
## aaaaaaaaaaaaaaaaaaaaaaa1` from Prapor, accept `q_debut`, run `recipe-quick`
## and raid `testmap`. That is the right shape for a fixture -- a known world
## makes an exact assertion possible -- and it is the reason neither of them can
## say anything about a real database, where none of those ids exist.
##
## This is the other test. It runs against whatever `aowl importdb` produced and
## **asserts nothing about identity**. Every id it uses is discovered at runtime
## out of the answers the server gives: the trader it buys from is whichever
## trader has the cheapest offer priced in roubles at loyalty level one, the
## quest it plays is whichever quest has no prerequisite and a handover
## condition naming something that trader sells, the map it raids is whichever
## map the locations table lists first. Point it at a database imported next
## year and it picks different ones.
##
## What is left when identity is taken away is *shape and relationship*, which
## is what real data can be wrong about and a fixture cannot:
##
## | | `emutest` (fixture) | `realtest` (imported) |
## |---|---|---|
## | asks | is this answer the one I wrote down | is this answer coherent with the rest of the database |
## | knows | every id in the world | no id until the server says it |
## | catches | a broken route | a route that is fine on 40 rows and wrong on 40,000 |
##
## Three properties of real data do the work here, and no fixture has any of
## them. It is **large** -- 4,673 templates, 5,790 assort items, 558 quests,
## 12.5 MiB down one route -- so anything quadratic, truncating or capped shows
## up as a wrong answer rather than a slow one. It is **cross-referential** --
## a quest names a trader who sells a template the handbook prices and the
## hideout crafts, and the emulator resolves all four independently -- so an
## invariant over the whole graph is a real test of code that only ever sees one
## node at a time. And it is **not tidy**: it was written by somebody else, it
## has entries nothing points at and pointers to entries that are not there, and
## a server is not allowed to fall over on either.
##
## It skips rather than fails when there is no imported database, because most
## machines will not have one and a red gate that means "you did not run a tool
## that reads a game you may not own" is a gate people learn to ignore.
##
## Numbers, not "ok". Every section prints what it exercised -- how many
## templates, traders, quests, offers, loot spots -- and the boot sequence
## prints its timings. A run that says "passed" while touching three rows of a
## 39 MiB database has told the reader nothing, and that is the failure mode
## this file is written against.

import std/[strutils, syncio, cmdline, sets, tables]
import aowlsptinstall/[winfs, log]
import wire

{.emit: """#include <stdlib.h>""".}
{.emit: """#include <string.h>""".}
{.emit: """#include "aowlspt_shim.h" """.}
{.emit: """#include "aowlspt_net.h" """.}
{.emit: """#include "aowlspt_inject.h" """.}

{.emit: """
/* A clock of this file's own. `wire.nim` has one, but its C definition lives in
 * that translation unit and nothing declares it here -- and a microsecond clock
 * is wanted, because the point of half the lines below is a number in
 * milliseconds. */
static int64_t aowl_real_qpc(void) {
  LARGE_INTEGER v; QueryPerformanceCounter(&v); return (int64_t)v.QuadPart;
}
static int64_t aowl_real_qpf(void) {
  LARGE_INTEGER v; QueryPerformanceFrequency(&v); return (int64_t)v.QuadPart;
}
""".}

proc cSpawn(exe, workDir, cmdLine: cstring): uint64 {.
  importc: "aowl_spawn", nodecl.}
proc cSpawnKill(h: uint64) {.importc: "aowl_spawn_kill", nodecl.}
proc cSleepMs(ms: int32) {.importc: "aowl_sys_sleep", nodecl.}
proc cQpc(): int64 {.importc: "aowl_real_qpc", nodecl.}
proc cQpf(): int64 {.importc: "aowl_real_qpf", nodecl.}

const
  Usage = """
realtest -- drive the Tarkov emulator against an imported database

  realtest --root PATH --backend PATH [--db PATH] [--port N]

  --root PATH      the scratch install (mods/, db.json); its store must be empty
  --backend PATH   aowlspt-backend.exe
  --db PATH        an imported database to stage as <root>\db.json. When it is
                   not there the whole run is skipped, not failed.
  --port N         port to serve on (default 6978)
  --maps N         how many maps to generate loot for (default 3)
  --keep           leave the backend running at the end
  -h, --help       this
"""
  Session = "aaaaaaaaaaaaaaaaaaaaaaaa"
  Roubles = "5449016a4bdc2d6f028b456f"
    ## The one id in this file that is written down rather than discovered, and
    ## it is here because it is not data: `giveItem`, the flea and the trader
    ## screen all name the rouble template directly, so a database where this is
    ## not the rouble is a database the emulator cannot serve at all. Every
    ## other id below comes off the wire.
  Dollars = "5696686a4bdc2da3298b456a"
  Euros = "569668774bdc2da2298b4568"

var gQpf = 1'i64

proc micros(): int64 =
  ## Microseconds since the machine started. Divided per reading rather than at
  ## the end so that a long run cannot overflow the multiply.
  let t = cQpc()
  result = (t div gQpf) * 1000000'i64 + ((t mod gQpf) * 1000000'i64) div gQpf

var gFailures = 0
var gChecks = 0
var gSkipped = 0
var gPort = 6978

proc check(what: string; condition: bool; detail = "") =
  inc gChecks
  if condition:
    ok what
  else:
    err what & (if detail.len > 0: ": " & detail else: "")
    inc gFailures

proc skip(what, why: string) =
  ## A check that could not run is reported, not omitted -- the same rule
  ## `emutest` follows. A discovery-driven test can legitimately fail to find
  ## what it needs in somebody else's database, and silence about that is
  ## indistinguishable from a pass.
  inc gChecks
  inc gSkipped
  note "skip  " & what & ": " & why

proc call(path, body: string): Response =
  result = request(gPort, path, body, Session)

# ---------------------------------------------------------------------------
# Reading a large JSON response
#
# `emutest` and `soak` read their bodies with `find(haystack.substr(i), needle)`
# -- a fresh copy of the remainder of the document per search. Against a fixture
# of a few kilobytes that is invisible. Against `/client/items` it is 12 MiB
# copied per lookup, and a sweep over the table is quadratic in the size of the
# largest thing the server sends: the same helper that costs microseconds there
# costs minutes here. So this file indexes instead of copying, and nothing below
# takes a substring of anything except the value it is about to return.
#
# It is a scanner rather than a parser, for the reason `tools/importdb.nim`
# gives: nothing here needs a value's meaning, only where it begins and ends.
# ---------------------------------------------------------------------------

proc findAt(hay, needle: string; start: int): int =
  ## `find`, from an offset, without copying the haystack.
  result = -1
  if needle.len == 0:
    return start
  var i = if start < 0: 0 else: start
  let last = hay.len - needle.len
  while i <= last:
    if hay[i] == needle[0]:
      var k = 1
      while k < needle.len and hay[i + k] == needle[k]:
        inc k
      if k == needle.len:
        return i
    inc i

proc countAt(hay, needle: string): int =
  result = 0
  var i = 0
  while true:
    let at = findAt(hay, needle, i)
    if at < 0:
      return
    inc result
    i = at + needle.len

proc skipWs(s: string; i: var int) =
  while i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\n' or
                       s[i] == '\r'):
    inc i

proc skipString(s: string; i: var int): bool =
  if i >= s.len or s[i] != '"':
    return false
  inc i
  while i < s.len:
    if s[i] == '\\':
      inc i, 2
      continue
    if s[i] == '"':
      inc i
      return true
    inc i
  result = false

proc skipValue(s: string; i: var int): bool =
  ## Leaves `i` one past a complete JSON value.
  skipWs(s, i)
  if i >= s.len:
    return false
  if s[i] == '"':
    return skipString(s, i)
  if s[i] == '{' or s[i] == '[':
    var depth = 0
    while i < s.len:
      let c = s[i]
      if c == '"':
        if not skipString(s, i):
          return false
        continue
      if c == '{' or c == '[':
        inc depth
      elif c == '}' or c == ']':
        dec depth
        if depth == 0:
          inc i
          return true
      inc i
    return false
  while i < s.len and s[i] != ',' and s[i] != '}' and s[i] != ']' and
        s[i] != ' ' and s[i] != '\n' and s[i] != '\r' and s[i] != '\t':
    inc i
  result = true

proc endOf(s: string; at: int): int =
  ## One past the value beginning at `at`, or `at` when it is not a value.
  var i = at
  if not skipValue(s, i):
    return at
  result = i

proc keyAt(s: string; at: int; text: var string): int =
  ## The unescaped-enough text of the string beginning at `at`, and the index
  ## one past it. Ids and member names in this database are plain ASCII; a
  ## backslash is copied through rather than decoded, which is right for a key
  ## used only for comparison.
  text = ""
  if at >= s.len or s[at] != '"':
    return at
  var i = at + 1
  while i < s.len and s[i] != '"':
    if s[i] == '\\' and i + 1 < s.len:
      text.add s[i + 1]
      inc i, 2
      continue
    text.add s[i]
    inc i
  result = i + 1

proc memberValue(s: string; objAt: int; key: string): int =
  ## The index of the value of `key` in the object beginning at `objAt`, or -1.
  ## One level only: a member named the same thing three objects down is a
  ## different member, and every wrong reading in a test like this one comes
  ## from a search that did not know that.
  if objAt < 0 or objAt >= s.len or s[objAt] != '{':
    return -1
  var i = objAt + 1
  while i < s.len:
    skipWs(s, i)
    if i < s.len and s[i] == '}':
      return -1
    var name = ""
    let afterKey = keyAt(s, i, name)
    if afterKey <= i:
      return -1
    i = afterKey
    skipWs(s, i)
    if i < s.len and s[i] == ':':
      inc i
    skipWs(s, i)
    if name == key:
      return i
    if not skipValue(s, i):
      return -1
    skipWs(s, i)
    if i < s.len and s[i] == ',':
      inc i
  result = -1

proc members(s: string; objAt: int; keys: var seq[string];
             vals: var seq[int]) =
  ## Every member of an object, as a key and the index of its value.
  keys = @[]
  vals = @[]
  if objAt < 0 or objAt >= s.len or s[objAt] != '{':
    return
  var i = objAt + 1
  while i < s.len:
    skipWs(s, i)
    if i < s.len and s[i] == '}':
      return
    var name = ""
    let afterKey = keyAt(s, i, name)
    if afterKey <= i:
      return
    i = afterKey
    skipWs(s, i)
    if i < s.len and s[i] == ':':
      inc i
    skipWs(s, i)
    keys.add name
    vals.add i
    if not skipValue(s, i):
      return
    skipWs(s, i)
    if i < s.len and s[i] == ',':
      inc i

proc elements(s: string; arrAt: int): seq[int] =
  ## The index of every element of the array beginning at `arrAt`.
  result = @[]
  if arrAt < 0 or arrAt >= s.len or s[arrAt] != '[':
    return
  var i = arrAt + 1
  while i < s.len:
    skipWs(s, i)
    if i < s.len and s[i] == ']':
      return
    result.add i
    if not skipValue(s, i):
      return
    skipWs(s, i)
    if i < s.len and s[i] == ',':
      inc i

proc textVal(s: string; at: int): string =
  ## The string value at `at`, or "" when it is not a string.
  result = ""
  if at < 0 or at >= s.len or s[at] != '"':
    return
  discard keyAt(s, at, result)

proc intVal(s: string; at: int): int =
  ## The number at `at`, truncated. `low(int)` is "not a number", because zero
  ## and -1 are both legitimate values of several of the fields below.
  if at < 0 or at >= s.len:
    return low(int)
  var i = at
  var neg = false
  if s[i] == '-':
    neg = true
    inc i
  var v = 0
  var any = false
  while i < s.len and s[i] >= '0' and s[i] <= '9':
    v = v * 10 + (ord(s[i]) - ord('0'))
    any = true
    inc i
  if not any:
    return low(int)
  result = if neg: -v else: v

proc textField(s: string; objAt: int; key: string): string =
  result = textVal(s, memberValue(s, objAt, key))

proc intField(s: string; objAt: int; key: string): int =
  result = intVal(s, memberValue(s, objAt, key))

proc dataAt(r: Response): int =
  ## The index of the `data` member of an envelope, or -1 -- which is also the
  ## answer for a body that is not an envelope at all, so a route that forgot
  ## `envelope` fails the check that reads it rather than silently returning
  ## nothing.
  result = memberValue(r.body, 0, "data")

proc why(r: Response): string =
  ## Why a request did not answer, when it did not: the transport error and the
  ## status line as well as the body. A check whose detail is an empty body says
  ## "something went wrong" and nothing else, which is the least useful thing a
  ## failing test can print.
  result = r.error
  if result.len > 0:
    result.add " "
  result.add r.status
  if r.body.len > 0:
    result.add " "
    result.add r.body.substr(0, (if r.body.len > 300: 300 else: r.body.len) - 1)

proc slice(s: string; at: int): string =
  ## One sub-document as text, for a failure message. Bounded: a slice of the
  ## item table in a log line is the same as no log line.
  if at < 0 or at >= s.len:
    return "(nothing)"
  var stop = endOf(s, at)
  if stop > at + 220:
    stop = at + 220
  result = s.substr(at, stop - 1)

proc slotKey(s: string; itemAt: int): string =
  ## The address a child item occupies inside its parent: parent, slot, and
  ## the position within that slot. Empty for a root item, which has no
  ## address to collide on.
  ##
  ## **An ABSENT `location` normalises to `0`, and that is the whole point.**
  ## The client defaults it, so two stacks that both omit it are two stacks at
  ## position 0 -- which is the `InventoryException` this check exists for. A
  ## key that treated "absent" as its own value would pass over the exact bug
  ## it was written to catch.
  ##
  ## The location is taken as RAW TEXT, not decoded, because the two shapes
  ## BSG uses are not interchangeable: a grid child carries the object
  ## `{"x":0,"y":0,"r":"Horizontal"}` and a `StackSlot` child carries the bare
  ## integer `0` (measured, capture/raid1/requests/204.json). Comparing the
  ## text compares the address the client will actually compute.
  let parent = textField(s, itemAt, "parentId")
  let slot = textField(s, itemAt, "slotId")
  if parent.len == 0 or slot.len == 0:
    return ""
  var loc = "0"
  let at = memberValue(s, itemAt, "location")
  if at >= 0:
    let stop = endOf(s, at)
    if stop > at:
      loc = s.substr(at, stop - 1)
  result = parent & "|" & slot & "|" & loc

# ---------------------------------------------------------------------------
# Footprints, the way the CLIENT computes them
# ---------------------------------------------------------------------------
#
# A weapon receiver is a 1x1 template. The gun is the receiver plus its mods,
# and a barrel, a stock or a scope each declares how far past the receiver it
# reaches (`ExtraSize{Up,Down,Left,Right}`, summed rather than maxed when the
# mod sets `ExtraSizeForceAdd`). The client computes that; the emulator's
# packer did not, so it reserved one cell for a five-cell rifle and the next
# item went on top of it:
#
#   "(x:0,y:0,r:Horizontal) in grid main in item barrel_cache ... is taken by
#    another item when trying to add item weapon_..."
#
# The index below is built ONCE from the imported database, because the check
# runs over every grid item on every map.

type
  TplSizes = object
    ids: seq[string]
    w: seq[int]
    h: seq[int]
    merges: seq[bool]
    eu: seq[int]
    ed: seq[int]
    el: seq[int]
    er: seq[int]
    forced: seq[bool]

proc buildTplSizes(db: string): TplSizes =
  result = TplSizes(ids: @[], w: @[], h: @[], merges: @[], eu: @[], ed: @[],
                    el: @[], er: @[], forced: @[])
  let tAt = memberValue(db, 0, "templates")
  if tAt < 0:
    return
  let iAt = memberValue(db, tAt, "items")
  if iAt < 0:
    return
  var keys: seq[string] = @[]
  var vals: seq[int] = @[]
  members(db, iAt, keys, vals)
  for k in 0 ..< keys.len:
    let pAt = memberValue(db, vals[k], "_props")
    if pAt < 0:
      continue
    var w = intField(db, pAt, "Width")
    var h = intField(db, pAt, "Height")
    if w == low(int): w = 1
    if h == low(int): h = 1
    if w < 1: w = 1
    if h < 1: h = 1
    var e = intField(db, pAt, "ExtraSizeUp")
    if e == low(int): e = 0
    result.eu.add e
    e = intField(db, pAt, "ExtraSizeDown")
    if e == low(int): e = 0
    result.ed.add e
    e = intField(db, pAt, "ExtraSizeLeft")
    if e == low(int): e = 0
    result.el.add e
    e = intField(db, pAt, "ExtraSizeRight")
    if e == low(int): e = 0
    result.er.add e
    let fAt = memberValue(db, pAt, "ExtraSizeForceAdd")
    result.forced.add(fAt >= 0 and fAt < db.len and db[fAt] == 't')
    let mAt = memberValue(db, pAt, "MergesWithChildren")
    result.merges.add(mAt >= 0 and mAt < db.len and db[mAt] == 't')
    result.ids.add keys[k]
    result.w.add w
    result.h.add h

proc indexOfTpl(t: TplSizes; tpl: string): int =
  result = -1
  if tpl.len == 0:
    return
  for i in 0 ..< t.ids.len:
    if t.ids[i] == tpl:
      return i

proc matchedOf(body: string): int =
  ## The spawner search route's `matched` count, read off the RAW body.
  ##
  ## Not through `dataAt`: MEASURED from a run against the real database, this
  ## route answers `{"options":[...],"matched":N}` with no `data` envelope
  ## around it, so `dataAt` returns -1 and every field read off it comes back
  ## as garbage -- `matched=-9223372036854775808`, which is what sent the first
  ## version of these checks red while the route was answering correctly.
  ## -1 for absent, which is distinguishable from a legitimate 0.
  result = -1
  let at = findAt(body, "\"matched\":", 0)
  if at < 0:
    return
  var i = at + 10
  skipWs(body, i)
  result = intVal(body, i)

type
  Collisions = object
    ## The two placement negatives, counted over one set of item documents.
    ##
    ## The same pair the loot section asserts over a raid floor, factored so
    ## the STASH can be held to them too. A spawn writes into the same grids
    ## the client will later render, and "the request returned ok" says
    ## nothing about whether what it wrote is renderable: the client throws
    ## `InventoryException` on a duplicate address and draws one item on top
    ## of another on an overlap, neither of which the server ever sees.
    slotDupes*: int       ## two children of one parent at one (slotId, location)
    cellOverlaps*: int    ## two items claiming one grid cell, mods included
    gridPlaced*: int      ## denominator: items actually placed into a grid
    grownPlaced*: int     ## of those, how many are bigger than their template
    slotSample*: string
    cellSample*: string

proc collisionsIn(body: string; items: seq[int]; t: TplSizes;
                  where: string): Collisions =
  ## Both negatives over `items`, with each footprint computed the way the
  ## CLIENT computes it -- template size grown by every descendant's
  ## `ExtraSize{Up,Down,Left,Right}`, summed when the mod sets
  ## `ExtraSizeForceAdd` and maxed when it does not.
  ##
  ## Read off the FINISHED documents rather than off whatever placed them, so
  ## this is not a placer compared against itself: it is falsifiable by any
  ## future writer into the same grids, including one that does not exist yet.
  result = Collisions(slotDupes: 0, cellOverlaps: 0, gridPlaced: 0,
                      grownPlaced: 0, slotSample: "", cellSample: "")
  var addrs = initHashSet[string]()
  for it in items:
    let k = slotKey(body, it)
    if k.len == 0:
      continue
    if contains(addrs, k):
      inc result.slotDupes
      if result.slotSample.len == 0:
        result.slotSample = where & " " & k & "  <- " &
                            textField(body, it, "_tpl")
    incl(addrs, k)

  var cells = initHashSet[string]()
  for it in items:
    let locAt = memberValue(body, it, "location")
    # A bare-integer `location` is a StackSlot address, not a grid cell; only
    # the object form `{"x":..,"y":..}` occupies area.
    if locAt < 0 or memberValue(body, locAt, "x") < 0:
      continue
    let tpl = textField(body, it, "_tpl")
    let ti = indexOfTpl(t, tpl)
    if ti < 0:
      continue
    var w = t.w[ti]
    var h = t.h[ti]
    let bareW = w
    let bareH = h
    if t.merges[ti]:
      var fam = initHashSet[string]()
      incl(fam, textField(body, it, "_id"))
      var hop = 0
      while hop < 4:
        for c in items:
          if contains(fam, textField(body, c, "parentId")):
            incl(fam, textField(body, c, "_id"))
        inc hop
      var mu = 0
      var md = 0
      var ml = 0
      var mr = 0
      var au = 0
      var ad = 0
      var al = 0
      var ar = 0
      for c in items:
        if c == it:
          continue
        if not contains(fam, textField(body, c, "_id")):
          continue
        let ci = indexOfTpl(t, textField(body, c, "_tpl"))
        if ci < 0:
          continue
        if t.forced[ci]:
          au = au + t.eu[ci]
          ad = ad + t.ed[ci]
          al = al + t.el[ci]
          ar = ar + t.er[ci]
        else:
          if t.eu[ci] > mu: mu = t.eu[ci]
          if t.ed[ci] > md: md = t.ed[ci]
          if t.el[ci] > ml: ml = t.el[ci]
          if t.er[ci] > mr: mr = t.er[ci]
      w = w + ml + mr + al + ar
      h = h + mu + md + au + ad
    if w < 1: w = 1
    if h < 1: h = 1
    if w != bareW or h != bareH:
      inc result.grownPlaced
    inc result.gridPlaced
    if textField(body, locAt, "r") == "Vertical":
      let sw = w
      w = h
      h = sw
    let grid = textField(body, it, "parentId") & "|" &
               textField(body, it, "slotId")
    let x0 = intField(body, locAt, "x")
    let y0 = intField(body, locAt, "y")
    var yy = y0
    while yy < y0 + h:
      var xx = x0
      while xx < x0 + w:
        let key = grid & "|" & $xx & "|" & $yy
        if contains(cells, key):
          inc result.cellOverlaps
          if result.cellSample.len == 0:
            result.cellSample = where & " " & key & " <- " & tpl &
                                " " & $w & "x" & $h
        incl(cells, key)
        inc xx
      inc yy

# ---------------------------------------------------------------------------
# Timing and size, reported rather than asserted
# ---------------------------------------------------------------------------

proc parentNameIn(body: string; keys: seq[string]; vals: seq[int];
                  id: string): string =
  ## The `_name` of the node a wardrobe entry hangs off, out of a
  ## `/client/customization` response already taken apart into `keys`/`vals`.
  ##
  ## Two lookups rather than one, and that is the whole point: the profile key
  ## a hideout decoration is written under is the *parent node's* name, so a
  ## check that read the entry's own `_name` would agree with the server on a
  ## table where they happen to match and disagree with it everywhere else.
  var i = 0
  while i < keys.len:
    if keys[i] == id:
      let parent = textField(body, vals[i], "_parent")
      if parent.len == 0:
        return ""
      var k = 0
      while k < keys.len:
        if keys[k] == parent:
          return textField(body, vals[k], "_name")
        inc k
      return ""
    inc i
  result = ""

var gSlowest = ""
var gSlowestUs = 0'i64
var gLargest = ""
var gLargestBytes = 0

proc timed(what, path, body: string): Response =
  ## One request, with its size and round trip printed. The point of this file
  ## is partly that these numbers exist at all: nobody can say whether 12 MiB
  ## down one route is a problem without knowing that it is 12 MiB.
  let began = micros()
  result = request(gPort, path, body, Session)
  let took = micros() - began
  if took > gSlowestUs:
    gSlowestUs = took
    gSlowest = path
  if result.body.len > gLargestBytes:
    gLargestBytes = result.body.len
    gLargest = path
  line "  " & what & ": " & $result.body.len & " bytes, " &
       $(took div 1000'i64) & " ms"

proc kib(n: int): string =
  result = $(n div 1024) & " KiB"

# ---------------------------------------------------------------------------
# The backend
# ---------------------------------------------------------------------------

proc waitForBackend(tries: int): bool =
  var i = 0
  while i < tries:
    let r = call("/client/game/config", "")
    if r.ok and r.contains("\"err\":0"):
      return true
    cSleepMs(200'i32)
    inc i
  result = false

proc waitForSelfCheck(tries: int): string =
  ## `/aowlspt/tarkov/selfcheck`, once it answers. "" when it never does.
  ##
  ## The one route a mod that refused to load still registers, which is what
  ## makes it worth waiting on before the game's own. See the caller.
  var i = 0
  while i < tries:
    let r = call("/aowlspt/tarkov/selfcheck", "")
    if r.ok and r.body.len > 0:
      return r.body
    cSleepMs(200'i32)
    inc i
  result = ""

proc startBackend(exe, root: string): uint64 =
  var e = exe
  var w = root
  var c = "\"" & exe & "\" --root \"" & root & "\" --port " & $gPort
  result = cSpawn(toCString(e), toCString(w), toCString(c))

# ---------------------------------------------------------------------------
# What the session needs, discovered
# ---------------------------------------------------------------------------

type
  Offer = object
    ## One thing a trader will sell for roubles at loyalty level one. Everything
    ## the session below buys is one of these, and which one it is depends on
    ## the database.
    trader: string
    root: string          ## the assort item id, which is what `item_id` names
    tpl: string
    price: int            ## roubles for one, out of the offer's own barter

proc findOffer(offers: seq[Offer]; tpl: string): int =
  result = -1
  var i = 0
  while i < offers.len:
    if offers[i].tpl == tpl:
      return i
    inc i

proc profileOf(listBody: string; uid: string): int =
  ## The index of one profile object in a `profile/list` response. The list
  ## holds the PMC and the scav, and the scav's item list is the PMC's stash
  ## spliced in at read time, so anything counted over the whole body is counted
  ## twice.
  let d = memberValue(listBody, 0, "data")
  let all = elements(listBody, d)
  for at in all:
    if textField(listBody, at, "_id") == uid:
      return at
  result = -1

proc moneyIn(body: string; profAt: int): int =
  ## Every rouble the profile holds, across stacks. A server that pays by
  ## rewriting one stack and dropping the others passes a single-stack check
  ## and has destroyed most of the player's money.
  result = 0
  let inv = memberValue(body, profAt, "Inventory")
  if inv < 0:
    return
  let items = elements(body, memberValue(body, inv, "items"))
  for it in items:
    if textField(body, it, "_tpl") != Roubles:
      continue
    let upd = memberValue(body, it, "upd")
    if upd < 0:
      inc result
      continue
    let n = intField(body, upd, "StackObjectsCount")
    result = result + (if n == low(int): 1 else: n)

proc firstMoneyId(body: string; profAt: int): string =
  result = ""
  let inv = memberValue(body, profAt, "Inventory")
  if inv < 0:
    return
  let items = elements(body, memberValue(body, inv, "items"))
  for it in items:
    if textField(body, it, "_tpl") == Roubles:
      return textField(body, it, "_id")

proc heldOf(body: string; profAt: int; tpl: string): seq[string] =
  ## Every item id the profile holds of one template, in document order.
  result = @[]
  let inv = memberValue(body, profAt, "Inventory")
  if inv < 0:
    return
  let items = elements(body, memberValue(body, inv, "items"))
  for it in items:
    if textField(body, it, "_tpl") == tpl:
      result.add textField(body, it, "_id")

proc unitsOf(body: string; profAt: int; tpl: string): int =
  ## How many *units* of one template the profile holds, which is not the same
  ## number as how many item documents it holds: `giveItem` merges a purchase
  ## into a stack that is already there, so counting documents says one after
  ## buying five of something stackable. Every check that asks "did what I
  ## bought arrive" has to count units or it is checking the merge.
  result = 0
  let inv = memberValue(body, profAt, "Inventory")
  if inv < 0:
    return
  for it in elements(body, memberValue(body, inv, "items")):
    if textField(body, it, "_tpl") != tpl:
      continue
    let upd = memberValue(body, it, "upd")
    var n = 1
    if upd >= 0:
      let held = intField(body, upd, "StackObjectsCount")
      if held > 0: n = held
    result = result + n

proc itemAt(body: string; profAt: int; id: string): int =
  result = -1
  let inv = memberValue(body, profAt, "Inventory")
  if inv < 0:
    return
  let items = elements(body, memberValue(body, inv, "items"))
  for it in items:
    if textField(body, it, "_id") == id:
      return it

proc boolField(s: string; objAt: int; key: string): bool =
  ## `"key":true` in the object at `objAt`. False for anything else, including
  ## a key that is not there -- which is what `enableAreaRequirements` means
  ## when it is absent.
  let at = memberValue(s, objAt, key)
  result = at >= 0 and at < s.len and s[at] == 't'

proc requiredSlotsOf(itemsBody: string; tplAt: int): seq[string] =
  ## The `_name` of every slot the item at `tplAt` declares `_required: true`.
  ##
  ## This is the source of truth the bot generator was NOT consulting: a weapon
  ## with a required receiver, barrel, pistol grip or gas block that comes out of
  ## generation with that slot empty is a non-functional gun -- the receiver-only
  ## scav a player pulled off a corpse. Read straight off `_props.Slots` in the
  ## served item table, so the check is against the same data the client parses.
  result = @[]
  let propsAt = memberValue(itemsBody, tplAt, "_props")
  if propsAt < 0:
    return
  let slotsAt = memberValue(itemsBody, propsAt, "Slots")
  if slotsAt < 0 or itemsBody[slotsAt] != '[':
    return
  for s in elements(itemsBody, slotsAt):
    if not boolField(itemsBody, s, "_required"):
      continue
    let nm = textField(itemsBody, s, "_name")
    if nm.len == 0:
      continue
    # Only a slot that SOMETHING can fill is a fair test of the generator. A
    # required slot whose own `filters[0].Filter` is empty cannot be filled from
    # any pool or fallback -- that is a database gap, not a generation bug, and
    # counting it would turn an unfixable datum into a permanent red.
    let filtersAt = memberValue(itemsBody, s, "filters")
    if filtersAt < 0 or itemsBody[filtersAt] != '[':
      continue
    let fe = elements(itemsBody, filtersAt)
    if fe.len == 0:
      continue
    let filterAt = memberValue(itemsBody, fe[0], "Filter")
    if filterAt < 0 or itemsBody[filterAt] != '[' or
       elements(itemsBody, filterAt).len == 0:
      continue
    result.add nm

proc propTextOf(itemsBody: string; tplAt: int; field: string): string =
  ## A text member of an item's `_props` -- `ammoCaliber` on a weapon,
  ## `Caliber` on a cartridge. "" when absent.
  let propsAt = memberValue(itemsBody, tplAt, "_props")
  if propsAt < 0:
    return ""
  result = textField(itemsBody, propsAt, field)

proc magFilterOf(itemsBody: string; tplAt: int): seq[string] =
  ## The ammo templates a magazine accepts:
  ## `_props.Cartridges[0]._props.filters[0].Filter`. Empty when the item is not
  ## a magazine or declares no cartridge filter -- which the caller reads as "not
  ## a magazine to check", not as "accepts nothing".
  result = @[]
  let propsAt = memberValue(itemsBody, tplAt, "_props")
  if propsAt < 0:
    return
  let cartsAt = memberValue(itemsBody, propsAt, "Cartridges")
  if cartsAt < 0 or itemsBody[cartsAt] != '[':
    return
  let ce = elements(itemsBody, cartsAt)
  if ce.len == 0:
    return
  let cpAt = memberValue(itemsBody, ce[0], "_props")
  if cpAt < 0:
    return
  let filtersAt = memberValue(itemsBody, cpAt, "filters")
  if filtersAt < 0 or itemsBody[filtersAt] != '[':
    return
  let fe = elements(itemsBody, filtersAt)
  if fe.len == 0:
    return
  let filterAt = memberValue(itemsBody, fe[0], "Filter")
  if filterAt < 0 or itemsBody[filterAt] != '[':
    return
  for a in elements(itemsBody, filterAt):
    let t = textVal(itemsBody, a)
    if t.len > 0:
      result.add t

# -- the map lock/unlock post-condition ------------------------------------
#
# Module level rather than nested inside the check block that uses them, for
# consistency with every other helper in this file.
#
# A note for whoever builds this by hand next, because it cost three wrong
# fixes here: `Response` comes from `backend/wire.nim`, so realtest needs
# `-p:<repo>\backend` on the nimony command line (see `buildRealTest` in
# tools/aowl.nim). Without it nimony does not say "cannot open wire" -- it
# aborts in its RENDERER with an AssertionDefect, "expected ')' but got:
# (else ... undeclared identifier: Response". That message points at whatever
# expression happened to mention the type and invites you to rewrite correct
# code. It is a missing import path, nothing else. Build with
# `aowl build verify` or copy the flags from `buildRealTest`; do not hand-roll
# the nimony invocation.

const TarkovSettings = "/aowlspt/settings/aowl.tarkov"

proc setTarkovSetting(key, valueJson: string): bool =
  ## One settings edit through the REAL route, so the persist path, the
  ## re-apply and the serve path are all inside the assertion.
  ##
  ## Was `setMapSetting`. It is not map-specific and never was -- it POSTs to
  ## `/aowlspt/settings/aowl.tarkov`, which is every setting the tarkov mod
  ## declares -- and the name is why the progression settings got a pure
  ## self-check instead of one that drives the real write path: this helper
  ## already existed and did not look applicable.
  let r: Response = call(TarkovSettings,
               "{\"key\":\"" & key & "\",\"value\":" & valueJson & "}")
  # A POST that did not persist answers `{"err":...,"rows":[...]}` rather than
  # the bare array the GET returns, so "did it save" is answerable here without
  # re-reading -- and re-reading our own write is what 9b forbids anyway.
  #
  var okCode = r.ok
  if okCode:
    okCode = findAt(r.body, "\"err\"", 0) < 0
  result = okCode

proc lockCensus(lk, un, mi: var int) =
  ## Locked / unlocked / unreadable, counted over EVERY map
  ## `/client/locations` actually serves.
  ##
  ## `mi` is the third outcome and it is not decoration: a map whose base
  ## carries no `Locked`, or carries one that is not a JSON bool, is neither
  ## locked nor unlocked. Folding it into either total would make one of them
  ## a lie, and a non-bool is the case the client's deserialiser THROWS on --
  ## the one most worth catching here rather than in a raid.
  lk = 0
  un = 0
  mi = 0
  let r: Response = call("/client/locations", "")
  var ks: seq[string] = @[]
  var vs: seq[int] = @[]
  members(r.body, memberValue(r.body, dataAt(r), "locations"), ks, vs)
  for i in 0 ..< vs.len:
    let at = memberValue(r.body, vs[i], "Locked")
    if at < 0 or at >= r.body.len:
      inc mi
    else:
      let c = r.body[at]
      if c == 't':
        inc lk
      elif c == 'f':
        inc un
      else:
        inc mi

proc hexId(n: int): string =
  ## A 24-character id, which is the only shape this server and its client
  ## accept. Derived from a counter rather than random so that a failing run
  ## names the same item twice.
  const digits = "0123456789abcdef"
  result = ""
  var v = n
  var i = 0
  while i < 24:
    result.add digits[v and 15]
    v = (v shr 4) + 7 * (i + 1)
    inc i

proc withItems(doc, itemsJson: string): string =
  ## The profile document with extra items spliced into `Inventory.items`.
  ##
  ## This is how loot comes home. `/client/match/local/end` takes the profile
  ## the client played the raid with -- that is the emulator's model and SPT's,
  ## and it is the only route by which an item that no trader sells enters a
  ## stash. Spliced into the server's own document rather than built fresh, for
  ## the same reason `withNumber` does it: the profile that goes back is the
  ## profile that came out, one thing different.
  if itemsJson.len == 0:
    return doc
  let inv = findAt(doc, "\"Inventory\":", 0)
  if inv < 0:
    return ""
  let at = findAt(doc, "\"items\":[", inv)
  if at < 0:
    return ""
  let cut = at + 9
  result = doc.substr(0, cut - 1) & itemsJson & "," & doc.substr(cut)

proc withVictims(doc, victimsJson: string): string =
  ## The profile document with its `Stats.Eft.Victims` array replaced.
  ##
  ## `questcond.killCredit` reads the victim list out of the profile the client
  ## hands back at `/client/match/local/end`, so that is where the kills have to
  ## go: a list passed beside the document would test a path the client never
  ## uses.
  let key = "\"Victims\":["
  let at = findAt(doc, key, 0)
  if at < 0:
    return ""
  var i = at + key.len
  var depth = 1
  var inString = false
  while i < doc.len and depth > 0:
    let c = doc[i]
    if inString:
      if c == '\\': inc i
      elif c == '"': inString = false
    elif c == '"': inString = true
    elif c == '[': inc depth
    elif c == ']': dec depth
    inc i
  result = doc.substr(0, at + key.len - 2) & victimsJson & doc.substr(i)

proc dialogRowOf(listBody: string; rows: seq[int];
                 dialogId: string): int =
  ## One `/client/mail/dialog/list` row, by its own `_id` -- the sender.
  ##
  ## Matched over the parsed elements rather than by searching the text: the
  ## row nests a *message* with an `_id` of its own, and a text scan lands on
  ## the member rather than on the object every reader here needs.
  result = -1
  for r in rows:
    if textField(listBody, r, "_id") == dialogId:
      return r

proc flagField(body: string; objAt: int; key: string): int =
  ## 1 for true, 0 for false, -1 for absent. `intField` reads neither, and a
  ## check that cannot tell false from missing is a check that passes against a
  ## route answering nothing at all.
  let at = memberValue(body, objAt, key)
  if at < 0 or at >= body.len:
    return -1
  if at + 4 <= body.len and body.substr(at, at + 3) == "true":
    return 1
  if at + 5 <= body.len and body.substr(at, at + 4) == "false":
    return 0
  result = -1

proc arrayLen(body: string; objAt: int; key: string): int =
  ## How many elements one array member has; 0 when it is absent or empty.
  result = elements(body, memberValue(body, objAt, key)).len

proc areaObject(body: string; areaList: seq[int]; ty: int): int =
  result = -1
  for a in areaList:
    if intField(body, a, "type") == ty:
      return a

proc gatherStage(body: string; reqsAt, ty, lv: int;
                 wantTpls: var seq[string]; wantNums: var seq[int];
                 subTys: var seq[int]; subLvs: var seq[int];
                 blocked: var string) =
  ## One requirement list, split into what can be bought, what has to be built
  ## first, and what cannot be done at all. Nothing is fetched here: this is
  ## the reading half, and the fetching half is in `main` where the wire is.
  for req in elements(body, reqsAt):
    let kind = textField(body, req, "type")
    if kind == "Area":
      var at2 = intField(body, req, "areaType")
      if at2 == low(int):
        at2 = 0
      var need = intField(body, req, "requiredLevel")
      if need == low(int) or need < 1:
        need = 1
      if at2 != ty:
        subTys.add at2
        subLvs.add need
    elif kind == "Item":
      let tpl = textField(body, req, "templateId")
      var c = intField(body, req, "count")
      if c == low(int) or c < 1:
        c = 1
      if tpl.len > 0:
        var at3 = -1
        var k = 0
        while k < wantTpls.len:
          if wantTpls[k] == tpl:
            at3 = k
          inc k
        if at3 < 0:
          wantTpls.add tpl
          wantNums.add c
        else:
          wantNums[at3] = wantNums[at3] + c
    elif kind == "TraderLoyalty":
      if blocked.len == 0:
        blocked = "level " & $lv & " of area " & $ty & " needs loyalty " &
                  $intField(body, req, "loyaltyLevel") & " with " &
                  textField(body, req, "traderId")
    elif kind == "Skill":
      if blocked.len == 0:
        blocked = "level " & $lv & " of area " & $ty & " needs " &
                  textField(body, req, "skillName") & " at level " &
                  $intField(body, req, "skillLevel")
    elif kind == "Resource":
      if blocked.len == 0:
        blocked = "level " & $lv & " of area " & $ty &
                  " is paid for out of its own slots"

proc planArea(body: string; areaList: seq[int]; ty, level, depth: int;
              planTys: var seq[int]; planLvs: var seq[int];
              wantTpls: var seq[string]; wantNums: var seq[int];
              blocked: var string) =
  ## Every upgrade that has to happen, in the order it has to happen in, for one
  ## area to reach one level -- and everything those upgrades cost.
  ##
  ## Discovered, like everything else in this file: the areas table says what a
  ## stage asks for, and a stage can ask for another area, which asks for
  ## another. A recipe that looks one upgrade away can be six, and the only way
  ## to find out is to walk it.
  if level < 1:
    return
  if depth > 8:
    if blocked.len == 0:
      blocked = "area " & $ty & " sits behind more areas than this walks"
    return
  var already = 0
  var i = 0
  while i < planTys.len:
    if planTys[i] == ty and planLvs[i] > already:
      already = planLvs[i]
    inc i
  if already >= level:
    return
  let aAt = areaObject(body, areaList, ty)
  if aAt < 0:
    if blocked.len == 0:
      blocked = "the areas table has no area " & $ty
    return
  var lv = already + 1
  while lv <= level:
    let st = memberValue(body, memberValue(body, aAt, "stages"), $lv)
    if st < 0:
      if blocked.len == 0:
        blocked = "area " & $ty & " has no level " & $lv
      return
    let secs = intField(body, st, "constructionTime")
    if secs > 0:
      # Honest rather than fatal: the stage is buildable, it just takes longer
      # than a test run. Reported as the reason the craft was not exercised.
      if blocked.len == 0:
        blocked = "level " & $lv & " of area " & $ty & " takes " & $secs &
                  " seconds to build"
      return
    var subTys: seq[int] = @[]
    var subLvs: seq[int] = @[]
    gatherStage(body, memberValue(body, st, "requirements"), ty, lv,
                wantTpls, wantNums, subTys, subLvs, blocked)
    if blocked.len > 0:
      return
    if boolField(body, aAt, "enableAreaRequirements"):
      # The list beside `stages` rather than inside one, and only when the flag
      # says the game applies it.
      gatherStage(body, memberValue(body, aAt, "requirements"), ty, lv,
                  wantTpls, wantNums, subTys, subLvs, blocked)
      if blocked.len > 0:
        return
    var k = 0
    while k < subTys.len:
      planArea(body, areaList, subTys[k], subLvs[k], depth + 1, planTys,
               planLvs, wantTpls, wantNums, blocked)
      if blocked.len > 0:
        return
      inc k
    # After its prerequisites, because that is the order the upgrades go in.
    planTys.add ty
    planLvs.add lv
    inc lv

proc withPartHealth(doc, part: string; value: int): string =
  ## The document with one body part's `Current` health changed. `withNumber`
  ## cannot do this: it replaces the *first* member of that name in the whole
  ## profile, and every part has a `Current`.
  let at = findAt(doc, "\"" & part & "\":{", 0)
  if at < 0:
    return ""
  let cur = findAt(doc, "\"Current\":", at)
  if cur < 0:
    return ""
  var j = cur + len("\"Current\":")
  var k = j
  while k < doc.len and doc[k] != ',' and doc[k] != '}':
    inc k
  result = doc.substr(0, j - 1) & $value & doc.substr(k)

proc withPartEffects(doc, part, effectsJson: string): string =
  ## The document with an `Effects` map written onto one body part.
  ##
  ## There is no route that gives a player an effect: the client applies them
  ## during a raid and hands the profile back carrying them. So this is the only
  ## way a treatment gets a fracture to treat, on real data as on a fixture.
  let at = findAt(doc, "\"" & part & "\":{", 0)
  if at < 0:
    return ""
  let cut = at + part.len + 4
  result = doc.substr(0, cut - 1) & "\"Effects\":" & effectsJson & "," &
           doc.substr(cut)

proc healCoefficient(body: string; levelAt: int): int =
  ## One loyalty row's heal coefficient, as a percentage, or -1 when the row
  ## does not name one. Both spellings, because the emulator reads both: the
  ## game's own dumps say `heal_price_coef` and the reference DTO says
  ## `HealPriceCoefficient`.
  var c = intField(body, levelAt, "heal_price_coef")
  if c == low(int):
    c = intField(body, levelAt, "HealPriceCoefficient")
  if c == low(int):
    return -1
  result = c

proc atCoefficient(total, percent: int): int =
  ## What the server charges: the table's total at a percentage, rounded up, and
  ## a percentage that is not a positive number read as 100 rather than as free.
  var p = percent
  if p <= 0:
    p = 100
  result = (total * p + 99) div 100

proc withNumber(doc: string; key: string; value: int): string =
  ## The document with the first `"key":<number>` replaced. Used to hand a raid
  ## result back the way the client does -- the server's own document, one field
  ## different -- rather than building a tidy one this test made up.
  let at = findAt(doc, "\"" & key & "\":", 0)
  if at < 0:
    return ""
  var j = at + key.len + 3
  var k = j
  while k < doc.len and doc[k] != ',' and doc[k] != '}':
    inc k
  result = doc.substr(0, j - 1) & $value & doc.substr(k)

proc main(): int =
  gQpf = cQpf()
  if gQpf <= 0'i64:
    gQpf = 1'i64
  var root = ""
  var backend = ""
  var dbPath = ""
  var keep = false
  var mapsToLoot = 3
  var i = 1
  let n = paramCount()
  while i <= n:
    let a = paramStr(i)
    if a == "--root":
      inc i
      if i <= n: root = paramStr(i)
    elif a == "--backend":
      inc i
      if i <= n: backend = paramStr(i)
    elif a == "--db":
      inc i
      if i <= n: dbPath = paramStr(i)
    elif a == "--port" or a == "--maps":
      let which = a
      inc i
      if i <= n:
        var v = 0
        var any = false
        for ch in paramStr(i):
          if ch >= '0' and ch <= '9':
            v = v * 10 + (ord(ch) - ord('0'))
            any = true
        if any:
          if which == "--port": gPort = v
          else: mapsToLoot = v
    elif a == "--keep":
      keep = true
    elif a == "--help" or a == "-h":
      echo Usage
      return 0
    else:
      err "unknown option: " & a
      return 1
    inc i

  if root.len == 0 or backend.len == 0:
    echo Usage
    return 1
  if not fileExists(backend):
    err "no backend at " & backend
    return 1

  # -- the skip, which is the ordinary case ---------------------------------
  #
  # Most machines have no imported database: producing one needs an SPT install,
  # and what it produces is somebody else's data that is not in this repository
  # and never will be. So the absence of one is not a failure, and the message
  # says what to run rather than what went wrong.
  let staged = joinPath(root, "db.json")
  if dbPath.len > 0:
    if not fileExists(dbPath):
      heading "Real data"
      note "skipped: there is no imported database at " & dbPath
      note "  produce one with:  aowl importdb --from D:\\SPT"
      note "  it reads an SPT install, never writes to one, and takes a second."
      return 0
    discard ensureDir(root)
    if not copyFileAt(dbPath, staged).ok:
      err "could not stage " & dbPath & " as " & staged
      return 1
  elif not fileExists(staged):
    heading "Real data"
    note "skipped: there is no database at " & staged & " and no --db to stage"
    note "  produce one with:  aowl importdb --from D:\\SPT --out " & root
    return 0

  let dbBytes = fileSizeOf(staged)
  discard cNetStartup()

  heading "Real data"
  note "database: " & staged & ", " & $(dbBytes div 1048576'i64) & " MiB"

  let bootBegan = micros()
  var server = startBackend(backend, root)
  if server == 0'u64:
    err "could not start the backend"
    # The spawn takes `root` as its working directory, so a root that does not
    # exist yet fails here -- and "could not start the backend" then names the
    # backend, which is fine, while the thing that is wrong is the argument two
    # flags to the left. Every other caller of this suite stages the root
    # first, so it went years without being said out loud.
    if not exists(root):
      note "there is no directory at " & root & " -- the spawn takes the " &
           "root as its working directory, so it fails before the backend " &
           "runs. Create it (and stage the mod and the database into it) " &
           "first; `aowl test` does that for you"
    elif not fileExists(backend):
      note "there is no file at " & backend & "; build it with `aowl build`"
    return 1

  # Asked before `/client/game/config`, and the order is the point.
  #
  # The mod runs its own arithmetic at load and refuses to serve when any of it
  # does not hold: the log names the failing check and then every game route
  # 404s. `waitForBackend` polls one of the routes that would be missing, so on
  # exactly that case it times out and the run dies at "the backend never
  # answered" -- which reads the same as a wrong port, a mod that was never
  # selected, or a 39 MiB import that is simply slow.
  #
  # `/aowlspt/tarkov/selfcheck` is registered on both paths and is deliberately
  # outside `/client/`, so waiting on it first turns a refusal into one red
  # line naming the arithmetic. It matters more here than in `emutest`: several
  # of those load checks walk the *real* tables, so this is the route that says
  # "this database has something in it this build cannot read".
  let selfcheck = waitForSelfCheck(300)
  check("the mod's own arithmetic held against this database",
        selfcheck.len > 0 and find(selfcheck, "\"ok\":true") >= 0 and
        find(selfcheck, "\"failures\":[]") >= 0,
        (if selfcheck.len == 0: "/aowlspt/tarkov/selfcheck never answered"
         else: selfcheck))

  if not waitForBackend(300):
    err "the backend never answered /client/game/config"
    cSpawnKill(server)
    return 1
  let bootUs = micros() - bootBegan
  ok "the backend loaded " & $(dbBytes div 1048576'i64) & " MiB and answered in " &
     $(bootUs div 1000'i64) & " ms"
  inc gChecks


  let fresh = call("/client/game/profile/list", "")
  if not fresh.ok or not fresh.contains("\"data\":[]"):
    err "this root already has profiles in it; realtest needs an empty store"
    note "delete " & root & "\\store and run again"
    cSpawnKill(server)
    return 1

  # =========================================================================
  heading "The tables the client boots on"
  # =========================================================================
  #
  # In the client's own order, and each answer is checked against the one
  # before it: the handbook against the item table, the locale against the item
  # table, the traders against both. Nothing here is compared to a value written
  # into this file.

  let itemsR = timed("items", "/client/items", "")
  # The first big answer, and the one everything below is checked against. A
  # server that cannot produce it is a run with no meaning, so it stops here
  # with the transport's own reason rather than reporting fifty derived
  # failures that all say "there were no templates".
  if not itemsR.ok or dataAt(itemsR) < 0:
    err "the server did not answer /client/items: " & why(itemsR)
    cSpawnKill(server)
    return 1
  check("the item table is an envelope with an object in it",
        itemsR.ok and dataAt(itemsR) >= 0 and
        itemsR.body[dataAt(itemsR)] == '{', itemsR.status)
  var templateIds = initHashSet[string]()
  var tplKeys: seq[string] = @[]
  var tplVals: seq[int] = @[]
  members(itemsR.body, dataAt(itemsR), tplKeys, tplVals)
  for k in tplKeys:
    incl(templateIds, k)
  check("the item table holds a real game's worth of templates",
        tplKeys.len > 1000, $tplKeys.len & " templates")
  line "  " & $tplKeys.len & " templates, " & kib(itemsR.body.len)

  # Each template is keyed by its own `_id`, carries `_props`, and its `_parent`
  # is another template in the same table. The client walks `_parent` to decide
  # what an item *is* -- a magazine, a weapon, a container -- so a parent that
  # is not in the table is an item with no behaviour.
  var keyMismatch = 0
  var noProps = 0
  var badParent = 0
  var parented = 0
  var sample = ""
  var t = 0
  while t < tplKeys.len:
    let at = tplVals[t]
    if textField(itemsR.body, at, "_id") != tplKeys[t]:
      inc keyMismatch
      if sample.len == 0: sample = tplKeys[t]
    if memberValue(itemsR.body, at, "_props") < 0:
      inc noProps
    let parent = textField(itemsR.body, at, "_parent")
    if parent.len > 0:
      inc parented
      if not contains(templateIds, parent):
        inc badParent
        if sample.len == 0: sample = tplKeys[t] & " -> " & parent
    inc t
  check("every template is filed under its own _id", keyMismatch == 0,
        $keyMismatch & " mismatched, e.g. " & sample)
  check("every template carries the _props the client reads", noProps == 0,
        $noProps & " without _props")
  check("every _parent names a template in the same table", badParent == 0,
        $badParent & " dangling, e.g. " & sample)
  line "  " & $parented & " templates name a parent"

  let localeR = timed("locale", "/client/locale/en", "")
  var localeKeys = initHashSet[string]()
  var lk: seq[string] = @[]
  var lv: seq[int] = @[]
  members(localeR.body, dataAt(localeR), lk, lv)
  for k in lk:
    incl(localeKeys, k)
  check("the locale answers a table of strings", lk.len > 100,
        $lk.len & " keys")
  var named = 0
  for id in tplKeys:
    if contains(localeKeys, id & " Name"):
      inc named
  # Not an equality. A template with no localised name renders as its id, which
  # is ugly and not broken, and the useful assertion is that the *join works at
  # all* -- a locale that answered a different key shape would name none of
  # them.
  check("the locale names the templates the item table has",
        named > (tplKeys.len * 9) div 10,
        $named & " of " & $tplKeys.len & " templates have a localised name")
  line "  " & $lk.len & " locale keys, " & $named & " of " & $tplKeys.len &
       " templates named"

  let hbR = timed("handbook", "/client/handbook/templates", "")
  let hbAt = dataAt(hbR)
  let hbItems = elements(hbR.body, memberValue(hbR.body, hbAt, "Items"))
  let hbCats = elements(hbR.body, memberValue(hbR.body, hbAt, "Categories"))
  var catIds = initHashSet[string]()
  for c in hbCats:
    incl(catIds, textField(hbR.body, c, "Id"))
  var pricedIds = initHashSet[string]()
  var hbDangling = 0
  var hbBadCat = 0
  var hbZero = 0
  var hbSample = ""
  for e in hbItems:
    let id = textField(hbR.body, e, "Id")
    let parent = textField(hbR.body, e, "ParentId")
    let price = intField(hbR.body, e, "Price")
    if not contains(templateIds, id):
      inc hbDangling
      if hbSample.len == 0: hbSample = id
    if parent.len > 0 and not contains(catIds, parent):
      inc hbBadCat
    if price <= 0:
      inc hbZero
    else:
      incl(pricedIds, id)
  check("every handbook entry prices a template the item table has",
        hbDangling == 0, $hbDangling & " dangling, e.g. " & hbSample)
  check("every handbook entry is filed under a category the handbook declares",
        hbBadCat == 0, $hbBadCat & " orphaned entries")
  line "  " & $hbItems.len & " priced entries in " & $hbCats.len &
       " categories, " & $hbZero & " priced at zero"

  # The rest of what the menu loads. Each of these is a table the importer had
  # to *reshape* rather than splice -- the prestige list is an array inside an
  # object on disk and a bare array here, the menu locale is a `{"menu":{...}}`
  # wrapper on disk and its contents here -- and a wrapper left on is a screen
  # that renders empty with `err:0` on the wire. Only an imported database has
  # the wrappers to get wrong.
  let globalsR = timed("globals", "/client/globals", "")
  check("globals answers a populated table",
        globalsR.ok and dataAt(globalsR) >= 0 and globalsR.body.len > 10000,
        $globalsR.body.len & " bytes")
  let settingsR = call("/client/settings", "")
  check("settings answers a populated table",
        settingsR.ok and settingsR.body.len > 1000, $settingsR.body.len)
  let customR = call("/client/customization", "")
  var customKeys: seq[string] = @[]
  var customVals: seq[int] = @[]
  members(customR.body, dataAt(customR), customKeys, customVals)
  check("customization answers the suites the character screen draws",
        customKeys.len > 10, $customKeys.len & " suites")
  let achieveR = call("/client/achievement/list", "")
  check("the achievement list answers `elements`",
        memberValue(achieveR.body, dataAt(achieveR), "elements") >= 0,
        achieveR.body.substr(0, (if achieveR.body.len > 160: 160
                                 else: achieveR.body.len) - 1))
  let prestigeR = call("/client/prestige/list", "")
  let prestigeAt = memberValue(prestigeR.body, dataAt(prestigeR), "elements")
  check("the prestige list answers `elements` holding a list, not an object",
        prestigeAt >= 0 and prestigeR.body[prestigeAt] == '[',
        prestigeR.body.substr(0, (if prestigeR.body.len > 160: 160
                                  else: prestigeR.body.len) - 1))
  let menuR = call("/client/menu/locale/en", "")
  var menuKeys: seq[string] = @[]
  var menuVals: seq[int] = @[]
  members(menuR.body, dataAt(menuR), menuKeys, menuVals)
  var menuWrapped = false
  for k in menuKeys:
    if k == "menu":
      menuWrapped = true
  # The wrapper is required, and this check used to assert the opposite.
  #
  # Pre-1.0 put the string map straight on `data`. Post-1.0 deserialises `data`
  # into `EFT.BackendMenuLocale`, whose only field is `menu`, and
  # `ConvertToLocale` then reads `this.menu` -- so a flat map leaves `menu`
  # null and the client null-refs, surfacing far away as a preloader-UI crash.
  # `onMenuLocale` wraps for that reason and says so.
  #
  # The strings are still checked, one level down, because "there is a `menu`
  # key" would pass on a wrapper round nothing -- which is the same bug in a
  # better disguise.
  var innerKeys: seq[string] = @[]
  var innerVals: seq[int] = @[]
  if menuWrapped:
    members(menuR.body, memberValue(menuR.body, dataAt(menuR), "menu"),
            innerKeys, innerVals)
  check("the menu locale answers its strings under the `menu` the client reads",
        menuWrapped and innerKeys.len > 5,
        "wrapper " & $menuWrapped & ", " & $innerKeys.len & " strings under it")
  let langR = call("/client/languages", "")
  check("the language list answers the languages the database has",
        langR.ok and langR.body.len > 20, langR.body)
  line "  globals " & kib(globalsR.body.len) & ", settings " &
       kib(settingsR.body.len) & ", " & $customKeys.len & " suites, " &
       $menuKeys.len & " menu strings"

  # =========================================================================
  heading "Traders, and what they will sell"
  # =========================================================================
  let tsR = timed("trader settings", "/client/trading/api/traderSettings", "")
  let traderList = elements(tsR.body, dataAt(tsR))
  var traderIds = initHashSet[string]()
  var traders: seq[string] = @[]
  for tr in traderList:
    let id = textField(tsR.body, tr, "_id")
    if id.len > 0:
      incl(traderIds, id)
      traders.add id
  check("the trader table has traders in it", traders.len > 0,
        $traders.len)

  var offers: seq[Offer] = @[]
  # Every template any trader stocks *at all* -- any loyalty level, any
  # currency, barter included. `offers` above is the narrower list of what one
  # can be bought for roubles at loyalty 1; this is the one that answers "is
  # there any trader screen this item is on", which is the question the flea
  # exists to answer no to.
  var assortTpls = initHashSet[string]()
  var assortItems = 0
  var assortDangling = 0
  var barterEntries = 0
  var barterUnpriced = 0
  var schemeOrphans = 0
  var loyaltyOrphans = 0
  var basesOk = 0
  var badSample = ""
  for tid in traders:
    let one = call("/client/trading/api/getTrader/" & tid, "")
    if one.ok and one.contains("\"nickname\"") and
       memberValue(one.body, dataAt(one), "loyaltyLevels") >= 0:
      inc basesOk
    let a = call("/client/trading/api/getTraderAssort/" & tid, "")
    let aAt = dataAt(a)
    let its = elements(a.body, memberValue(a.body, aAt, "items"))
    var rootIds = initHashSet[string]()
    for it in its:
      inc assortItems
      incl(rootIds, textField(a.body, it, "_id"))
      let tpl = textField(a.body, it, "_tpl")
      incl(assortTpls, tpl)
      if not contains(templateIds, tpl):
        inc assortDangling
        if badSample.len == 0: badSample = tid & " " & tpl
    var schemeKeys: seq[string] = @[]
    var schemeVals: seq[int] = @[]
    members(a.body, memberValue(a.body, aAt, "barter_scheme"), schemeKeys,
            schemeVals)
    var s = 0
    while s < schemeKeys.len:
      if not contains(rootIds, schemeKeys[s]):
        inc schemeOrphans
      let alternatives = elements(a.body, schemeVals[s])
      var first = true
      for alt in alternatives:
        let parts = elements(a.body, alt)
        var roubleCost = 0
        var onlyRoubles = parts.len == 1
        for p in parts:
          inc barterEntries
          let tpl = textField(a.body, p, "_tpl")
          let count = intField(a.body, p, "count")
          # A barter costs either money or a thing. A thing the handbook does
          # not price is a thing the player cannot value and the flea cannot
          # list -- and an offer whose price is unpriceable is the shape that
          # puts a free item at the top of every cheapest-first search.
          if tpl != Roubles and tpl != Dollars and tpl != Euros and
             not contains(pricedIds, tpl):
            inc barterUnpriced
            if badSample.len == 0: badSample = tid & " barter " & tpl
          if tpl == Roubles and count > 0:
            roubleCost = count
          else:
            onlyRoubles = false
        if first and onlyRoubles and roubleCost > 0 and
           contains(rootIds, schemeKeys[s]):
          # Loyalty gates the offer; only the ungated ones are of any use to a
          # profile that has never traded.
          let ll = intVal(a.body,
            memberValue(a.body, memberValue(a.body, aAt, "loyal_level_items"),
                        schemeKeys[s]))
          if ll == low(int) or ll <= 1:
            var o = Offer(trader: tid, root: schemeKeys[s], tpl: "",
                          price: roubleCost)
            for it in its:
              if textField(a.body, it, "_id") == schemeKeys[s]:
                o.tpl = textField(a.body, it, "_tpl")
                break
            if o.tpl.len > 0:
              offers.add o
        first = false
      inc s
    var llKeys: seq[string] = @[]
    var llVals: seq[int] = @[]
    members(a.body, memberValue(a.body, aAt, "loyal_level_items"), llKeys,
            llVals)
    for k in llKeys:
      if not contains(rootIds, k):
        inc loyaltyOrphans

  check("every assort item names a template the item table has",
        assortDangling == 0, $assortDangling & " dangling, e.g. " & badSample)
  check("every barter scheme belongs to an offer the trader is showing",
        schemeOrphans == 0, $schemeOrphans & " schemes with no item")
  check("every barter costs a currency or something the handbook prices",
        barterUnpriced == 0, $barterUnpriced & " unpriceable, e.g. " & badSample)
  check("every trader answers its own base with loyalty levels",
        basesOk == traders.len, $basesOk & " of " & $traders.len)
  line "  " & $traders.len & " traders, " & $assortItems & " assort items, " &
       $barterEntries & " barter entries, " & $offers.len &
       " buyable for roubles at loyalty 1"
  # Reported and not asserted: SPT's own data carries loyalty rows for offers
  # that are not in the assort. They gate nothing, and a test that failed on
  # them would be failing on somebody else's file rather than on this server.
  if loyaltyOrphans > 0:
    line "  " & $loyaltyOrphans &
         " loyalty rows name an offer the assort does not carry (source data)"

  # =========================================================================
  heading "Quests, against the traders and the templates"
  # =========================================================================
  let questsR = timed("quest list", "/client/quest/list", "")
  # An array of quest objects, each carrying its own `_id` -- not the id-keyed
  # object the database stores them in. That is what the real backend sends
  # (capture seq 130, 262, 444) and what `emu/templates.questList` now builds.
  #
  # `questKeys` and `questVals` keep their old meaning -- an id and an offset to
  # the quest object at that id -- so everything below this reads the same as it
  # did when the route answered an object.
  var questKeys: seq[string] = @[]
  var questVals: seq[int] = @[]
  for qAt in elements(questsR.body, dataAt(questsR)):
    let qid = textField(questsR.body, qAt, "_id")
    if qid.len > 0:
      questKeys.add qid
      questVals.add qAt
  var questIds = initHashSet[string]()
  for k in questKeys:
    incl(questIds, k)
  check("the quest table has the game's quests in it", questKeys.len > 10,
        $questKeys.len & " quests")

  # Every quest is a graph node: it belongs to a trader, it may require another
  # quest, and its conditions name templates. `emu/questcond` resolves all three
  # independently, so all three are checked here -- over the wire, which is a
  # different claim from the importer's own check over the file.
  var traderRefs = 0
  var traderMissing = 0
  var questRefs = 0
  var questMissing = 0
  var itemRefs = 0
  var itemMissing = 0
  var condCount = 0
  var qSample = ""
  # Discovered as they are found: a quest with no prerequisite, and one of those
  # with a handover condition naming something a trader will sell.
  var playQuest = ""
  var playCondition = ""
  var playTemplate = ""
  var playCount = 0
  # And one more, for the kill counter. `questcond.killCredit` used to refuse
  # any `Kills` condition that merely *carried* a `distance` or `daytime` key,
  # and a real `templates.quests` writes both on almost every one of them with a
  # neutral value -- so the quest looked for here is the ordinary case, not an
  # exotic one: kill N of something, no range, no time of day, no weapon list.
  # And one that posts something. The inbox checks below need a dialog to act
  # on, and the only thing in this session that reliably produces one out of
  # the database is a quest whose *Started* rewards carry items -- those go
  # through the post rather than into the stash. Discovered rather than named,
  # because which quests do that is somebody else's data.
  var mailQuest = ""
  var killQuest = ""
  var killCondition = ""
  var killSide = ""
  var killWhere = ""
  var killExit = ""
  var killTarget = 0
  var neutralKillConds = 0
  var qualifiedKillConds = 0
  # Every `daytime` window that restricts anything, as its width in minutes.
  # `emu/questcond.daytimeVerdict` credits a kill when the raid's whole possible
  # span sits inside the window, and the span is the map's `EscapeTimeLimit`
  # times the acceleration -- so whether the feature can ever fire on real data
  # is a relationship between two tables that no fixture has. The locations
  # section below is where the two meet.
  var dayWidths: seq[int] = @[]
  var dayNarrowest = ""
  var dayMinutes = -1
  var q = 0
  while q < questKeys.len:
    let qAt = questVals[q]
    let qid = questKeys[q]
    let trader = textField(questsR.body, qAt, "traderId")
    if trader.len > 0:
      inc traderRefs
      if not contains(traderIds, trader):
        inc traderMissing
        if qSample.len == 0: qSample = qid & " -> " & trader
    let conds = memberValue(questsR.body, qAt, "conditions")
    var groupKeys: seq[string] = @[]
    var groupVals: seq[int] = @[]
    members(questsR.body, conds, groupKeys, groupVals)
    var gated = false
    var handoverAt = -1
    var qKillCond = ""
    var qKillSide = ""
    var qKillWhere = ""
    var qKillExit = ""
    var qKillTarget = 0
    var g = 0
    while g < groupKeys.len:
      let group = elements(questsR.body, groupVals[g])
      for c in group:
        inc condCount
        var kind = textField(questsR.body, c, "conditionType")
        if kind.len == 0:
          kind = textField(questsR.body, c, "_parent")
        var bodyAt = memberValue(questsR.body, c, "_props")
        if bodyAt < 0:
          bodyAt = c
        let targetAt = memberValue(questsR.body, bodyAt, "target")
        var targets: seq[string] = @[]
        if targetAt >= 0:
          if questsR.body[targetAt] == '[':
            for e in elements(questsR.body, targetAt):
              targets.add textVal(questsR.body, e)
          else:
            targets.add textVal(questsR.body, targetAt)
        if kind == "Quest":
          for tgt in targets:
            inc questRefs
            if not contains(questIds, tgt):
              inc questMissing
              if qSample.len == 0: qSample = qid & " -> quest " & tgt
          if groupKeys[g] == "AvailableForStart":
            gated = true
        elif kind == "HandoverItem" or kind == "FindItem" or
             kind == "LeaveItemAtLocation" or kind == "PlaceBeacon" or
             kind == "SellItemToTrader" or kind == "WeaponAssembly":
          for tgt in targets:
            inc itemRefs
            if not contains(templateIds, tgt):
              inc itemMissing
              if qSample.len == 0: qSample = qid & " -> template " & tgt
          if kind == "HandoverItem" and groupKeys[g] == "AvailableForFinish":
            handoverAt = c
        elif kind == "CounterCreator" and
             groupKeys[g] == "AvailableForFinish":
          # Every `Kills` sub-condition of this counter, and whether this
          # server can check all of it. `plain` is the whole test: a neutral
          # `{">=", 0}` distance and a `{0, 0}` daytime restrict nothing, and
          # reading their presence as a restriction is the defect.
          let counterAt = memberValue(questsR.body, bodyAt, "counter")
          let subs = elements(questsR.body,
                              memberValue(questsR.body, counterAt,
                                          "conditions"))
          var sawKills = false
          var onlyKills = subs.len > 0
          var plain = true
          # The discriminator. A `Kills` condition that carries no `distance`
          # and no `daytime` member at all was credited by the old reading too,
          # so a check driven by one proves nothing. What the old reading
          # refused is a condition that carries them with *neutral* values --
          # `{">=", 0}` and `{0, 0}` -- which is how a real `templates.quests`
          # writes almost all of them.
          var carriesNeutral = false
          var killsSide = ""
          var killsWhere = ""
          var killsExit = ""
          for sc in subs:
            var sk = textField(questsR.body, sc, "conditionType")
            if sk.len == 0:
              sk = textField(questsR.body, sc, "_parent")
            var sb = memberValue(questsR.body, sc, "_props")
            if sb < 0:
              sb = sc
            if sk == "Location":
              # `killCredit` checks this against the raid's own map, so it is
              # not a qualifier it cannot see -- it is one it can. The map the
              # condition names is the map this test then raids.
              let locs = elements(questsR.body,
                                  memberValue(questsR.body, sb, "target"))
              if locs.len > 0:
                killsWhere = textVal(questsR.body, locs[0])
              continue
            if sk == "ExitStatus":
              let outs = elements(questsR.body,
                                  memberValue(questsR.body, sb, "status"))
              if outs.len > 0:
                killsExit = textVal(questsR.body, outs[0])
              continue
            if sk != "Kills":
              onlyKills = false
              continue
            sawKills = true
            let side = textField(questsR.body, sb, "target")
            if side != "Savage" and side != "Any" and side != "AnyPmc":
              plain = false
            killsSide = side
            if arrayLen(questsR.body, sb, "savageRole") > 0 or
               arrayLen(questsR.body, sb, "bodyPart") > 0 or
               arrayLen(questsR.body, sb, "weapon") > 0 or
               arrayLen(questsR.body, sb, "weaponModsInclusive") > 0 or
               arrayLen(questsR.body, sb, "weaponModsExclusive") > 0 or
               arrayLen(questsR.body, sb, "weaponCaliber") > 0 or
               arrayLen(questsR.body, sb, "enemyEquipmentInclusive") > 0 or
               arrayLen(questsR.body, sb, "enemyEquipmentExclusive") > 0 or
               arrayLen(questsR.body, sb, "enemyHealthEffects") > 0:
              plain = false
            let dAt = memberValue(questsR.body, sb, "distance")
            if dAt >= 0:
              carriesNeutral = true
              if textField(questsR.body, dAt, "compareMethod") != ">=" or
                 intField(questsR.body, dAt, "value") != 0:
                plain = false
            let tAt = memberValue(questsR.body, sb, "daytime")
            if tAt >= 0:
              carriesNeutral = true
              let dayFrom = intField(questsR.body, tAt, "from")
              let dayTo = intField(questsR.body, tAt, "to")
              if dayFrom != dayTo:
                plain = false
                # A real window, and the only ones in the database wrap
                # midnight: 22->10, 21->4, 21->5, 21->6, 22->7.
                var width = dayTo - dayFrom
                if width <= 0:
                  width = width + 24
                dayWidths.add width * 60
                if dayMinutes < 0 or width * 60 < dayMinutes:
                  dayMinutes = width * 60
                  dayNarrowest = qid & " " & $dayFrom & "->" & $dayTo
          if sawKills:
            if plain: inc neutralKillConds
            else: inc qualifiedKillConds
          if sawKills and onlyKills and plain and carriesNeutral and
             qKillCond.len == 0:
            qKillCond = textField(questsR.body, bodyAt, "id")
            qKillTarget = intField(questsR.body, bodyAt, "value")
            qKillSide = killsSide
            qKillWhere = killsWhere
            qKillExit = killsExit
        elif kind == "TraderLoyalty" or kind == "TraderStanding":
          for tgt in targets:
            inc traderRefs
            if not contains(traderIds, tgt):
              inc traderMissing
              if qSample.len == 0: qSample = qid & " -> trader " & tgt
        elif kind == "Level":
          # A level gate a fresh profile cannot pass is a gate all the same.
          if intField(questsR.body, bodyAt, "value") > 1:
            gated = true
      inc g
    if not gated and mailQuest.len == 0:
      let startedAt = memberValue(questsR.body,
        memberValue(questsR.body, qAt, "rewards"), "Started")
      for rw in elements(questsR.body, startedAt):
        if textField(questsR.body, rw, "type") == "Item" and
           arrayLen(questsR.body, rw, "items") > 0:
          mailQuest = qid
    if not gated and qKillCond.len > 0 and killQuest.len == 0 and
       qid != playQuest:
      killQuest = qid
      killCondition = qKillCond
      killSide = qKillSide
      killWhere = qKillWhere
      killExit = qKillExit
      killTarget = qKillTarget
    if not gated and handoverAt >= 0 and playQuest.len == 0:
      let want = intField(questsR.body, handoverAt, "value")
      if want >= 1 and want <= 5:
        let targetAt = memberValue(questsR.body, handoverAt, "target")
        var targets: seq[string] = @[]
        if targetAt >= 0 and questsR.body[targetAt] == '[':
          for e in elements(questsR.body, targetAt):
            targets.add textVal(questsR.body, e)
        elif targetAt >= 0:
          targets.add textVal(questsR.body, targetAt)
        for tgt in targets:
          let idx = findOffer(offers, tgt)
          if idx >= 0 and offers[idx].price * want < 200000:
            playQuest = qid
            playCondition = textField(questsR.body, handoverAt, "id")
            playTemplate = tgt
            playCount = want
            break
    inc q
  check("every quest belongs to a trader the trader table has",
        traderMissing == 0, $traderMissing & " dangling, e.g. " & qSample)
  check("every quest that requires another quest requires one that exists",
        questMissing == 0, $questMissing & " dangling, e.g. " & qSample)
  check("every quest condition naming an item names a real template",
        itemMissing == 0, $itemMissing & " dangling, e.g. " & qSample)
  # The census the refusal used to be argued from. It is printed rather than
  # asserted -- it is a fact about somebody's database, not about this server --
  # but it is the number that says how much of the game the old reading refused:
  # every one of the neutral ones.
  line "  " & $neutralKillConds & " kill counters with no qualifier this " &
       "server cannot check, " & $qualifiedKillConds & " with one"
  line "  " & $questKeys.len & " quests, " & $condCount & " conditions, " &
       $itemRefs & " template references, " & $questRefs &
       " quest references, " & $traderRefs & " trader references"

  # =========================================================================
  heading "The hideout, against the areas and the templates"
  # =========================================================================
  let areasR = timed("hideout areas", "/client/hideout/areas", "")
  let areaList = elements(areasR.body, dataAt(areasR))
  var areaTypes: seq[int] = @[]
  for a in areaList:
    let ty = intField(areasR.body, a, "type")
    if ty != low(int):
      areaTypes.add ty
  check("the hideout has areas", areaTypes.len > 0, $areaTypes.len)

  let recipesR = timed("hideout recipes", "/client/hideout/production/recipes",
                       "")
  # Two shapes are in circulation -- a bare array, and the object the reference
  # DTO describes with `recipes` beside `scavRecipes`. The emulator reads both,
  # so this reads both rather than pinning the one the fixture happens to use.
  var recipeArrayAt = dataAt(recipesR)
  if recipeArrayAt >= 0 and recipesR.body[recipeArrayAt] == '{':
    recipeArrayAt = memberValue(recipesR.body, recipeArrayAt, "recipes")
  let recipeList = elements(recipesR.body, recipeArrayAt)
  var recipeBadArea = 0
  var recipeBadTpl = 0
  var recipeInputs = 0
  var rSample = ""
  # And the one the session will run, discovered: a craft whose area can be
  # built, whose inputs a trader sells, and which finishes in this lifetime.
  var craftId = ""
  var craftArea = -1
  var craftLevel = 1
  var craftTemplates: seq[string] = @[]
  var craftCounts: seq[int] = @[]
  var craftCost = 0
  for r in recipeList:
    let area = intField(recipesR.body, r, "areaType")
    var known = false
    for ty in areaTypes:
      if ty == area:
        known = true
        break
    if not known:
      inc recipeBadArea
      if rSample.len == 0: rSample = textField(recipesR.body, r, "_id")
    let endProduct = textField(recipesR.body, r, "endProduct")
    if endProduct.len > 0 and not contains(templateIds, endProduct):
      inc recipeBadTpl
      if rSample.len == 0: rSample = endProduct
    var wantTpl: seq[string] = @[]
    var wantNum: seq[int] = @[]
    var cost = 0
    var buyable = true
    var needLevel = 1
    let reqs = elements(recipesR.body, memberValue(recipesR.body, r,
                                                   "requirements"))
    for q2 in reqs:
      let kind = textField(recipesR.body, q2, "type")
      let tpl = textField(recipesR.body, q2, "templateId")
      if tpl.len > 0:
        inc recipeInputs
        if not contains(templateIds, tpl):
          inc recipeBadTpl
          if rSample.len == 0: rSample = tpl
      if kind == "Area":
        let lvl = intField(recipesR.body, q2, "requiredLevel")
        if lvl > needLevel:
          needLevel = lvl
      elif kind == "Item" or kind == "Tool":
        var count = intField(recipesR.body, q2, "count")
        if count == low(int) or count < 1:
          count = 1
        let idx = findOffer(offers, tpl)
        if idx < 0:
          buyable = false
        else:
          wantTpl.add tpl
          wantNum.add count
          cost = cost + offers[idx].price * count
      elif kind == "Resource":
        # Fuel and filters are consumed out of an area's slots rather than out
        # of the stash; a craft that wants one is not one this session can set
        # up from a trader.
        buyable = false
      elif kind == "QuestComplete" or kind == "TraderLoyalty" or
           kind == "Skill":
        # Gates the server evaluates against the profile and this session
        # cannot reach: forty-three recipes in a real table are unlocked by a
        # finished quest. They used to be permitted, because production
        # resolved its requirements without a profile to read them against.
        buyable = false
    let continuous = memberValue(recipesR.body, r, "continuous")
    let isContinuous = continuous >= 0 and
                       findAt(recipesR.body, "true", continuous) == continuous
    # The cheapest qualifying recipe rather than the first, because the session
    # pays for this out of the same starting roubles it buys the quest's items
    # with, and "the first one in the table" is a budget that depends on what
    # order somebody else's file happens to be in.
    if buyable and not isContinuous and known and wantTpl.len > 0 and
       needLevel <= 2 and cost < 150000 and
       (craftId.len == 0 or cost < craftCost):
      craftId = textField(recipesR.body, r, "_id")
      craftArea = area
      craftLevel = needLevel
      craftTemplates = wantTpl
      craftCounts = wantNum
      craftCost = cost
  check("every recipe is made in an area the hideout has",
        recipeBadArea == 0, $recipeBadArea & " unknown areas, e.g. " & rSample)
  check("every recipe's inputs and output are real templates",
        recipeBadTpl == 0, $recipeBadTpl & " dangling, e.g. " & rSample)
  line "  " & $areaTypes.len & " areas, " & $recipeList.len & " recipes, " &
       $recipeInputs & " ingredient references"

  # =========================================================================
  heading "Locations, and the floor of a raid"
  # =========================================================================
  let locR = timed("locations", "/client/locations", "")
  var mapKeys: seq[string] = @[]
  var mapVals: seq[int] = @[]
  members(locR.body, memberValue(locR.body, dataAt(locR), "locations"),
          mapKeys, mapVals)
  # A real database has nineteen maps and this route is the client's whole menu,
  # so an empty list is a broken server rather than a small one. Stated as its
  # own check because the two below iterate `mapVals`: with no maps they compare
  # `0 == 0` and pass, and this route *has* returned zero maps in anger.
  check("the locations table lists maps", mapKeys.len >= 15,
        $mapKeys.len & " maps, and a real database carries 19")

  # The value is a `LocationBase` -- the map's `base` -- not the database's
  # wrapper around it. `LocationsGenerateAllResponse.Locations` is
  # `Dictionary<MongoId, LocationBase>` in the reference, and this route used to
  # splice the wrapper, which is how it came to be answering 12.5 MB by default
  # and 560 MiB with loose loot imported. The old form of this check looked for
  # `base._Id` and so encoded the shape that was wrong.
  var withId = 0
  var keyedById = 0
  for i in 0 ..< mapVals.len:
    let id = textVal(locR.body, memberValue(locR.body, mapVals[i], "_Id"))
    if id.len > 0:
      inc withId
      # And keyed by that id, not by the directory name the database uses.
      # `Paths` names both ends by `_Id`, so a transit graph is unreadable
      # against a list keyed any other way.
      if id == mapKeys[i]: inc keyedById
  check("every map is the base the client loads it from",
        withId == mapKeys.len, $withId & " of " & $mapKeys.len)
  check("and is keyed by its own _Id", keyedById == mapKeys.len,
        $keyedById & " of " & $mapKeys.len)

  # The loot tables must not be in here. Asserted on the body rather than on a
  # count, because this is the regression that matters: the wrapper carries
  # `looseLoot`, and on a `--loose all` import that is 560 MiB in one response.
  for absent in ["looseLoot", "staticContainers", "staticAmmo", "spawnpoints"]:
    check("the map list carries no " & absent,
          findAt(locR.body, "\"" & absent & "\"", 0) < 0,
          "it is in the body, which is what made this route 560 MiB")
  line "  " & $mapKeys.len & " maps, " & kib(locR.body.len) & " of map data"

  # -- PMCs are seeded into every offline raid -----------------------------
  #
  # fix(1). A stock offline raid served only `assault`/`Savage` waves, so the
  # client never asked `bot/generate` for a PMC and a Woods raid spawned ~40
  # scavs, the bosses, and zero PMCs. `tuneOfflineSpawns` now seeds
  # `pmcUSEC`/`pmcBEAR` waves, and `/client/locations` is the payload the client
  # builds its wave scenario from -- so the served `waves[]` are the finished
  # state to assert, not the generator's intent.
  #
  # The assertion is a NEGATIVE that can be falsified: no map that seeds scav
  # waves may be left with zero PMC waves. It fails the instant the PMC seeding
  # is dropped, and does not pass merely because the code ran. Woods is named
  # explicitly because that is the map the defect was observed on.
  var mapsWithPmc = 0
  var mapsWithScav = 0
  var pmcWavesTotal = 0
  var woodsPmc = -1
  for i in 0 ..< mapKeys.len:
    let wavesAt = memberValue(locR.body, mapVals[i], "waves")
    if wavesAt < 0 or locR.body[wavesAt] != '[':
      continue
    var pmc = 0
    var scav = 0
    for w in elements(locR.body, wavesAt):
      let wt = textField(locR.body, w, "WildSpawnType")
      if wt == "pmcUSEC" or wt == "pmcBEAR":
        inc pmc
      elif wt == "assault":
        inc scav
    if pmc > 0: inc mapsWithPmc
    if scav > 0: inc mapsWithScav
    pmcWavesTotal = pmcWavesTotal + pmc
    # The served map is keyed by `_Id` (a MongoId), so Woods is found by its
    # human `Id`/`Name` field, not the dict key -- fact #183, the same id split
    # `canonicalLocation` exists for.
    let mapId = textVal(locR.body, memberValue(locR.body, mapVals[i], "Id"))
    let mapName = textVal(locR.body, memberValue(locR.body, mapVals[i], "Name"))
    if mapKeys[i] == "Woods" or mapKeys[i] == "woods" or
       mapId == "Woods" or mapName == "Woods":
      woodsPmc = pmc
  check("every offline map that seeds scavs also seeds PMC waves",
        mapKeys.len > 0 and mapsWithScav > 0 and mapsWithPmc == mapsWithScav,
        $mapsWithPmc & " of " & $mapsWithScav &
        " scav-seeded maps also seed PMCs (" & $pmcWavesTotal & " PMC waves)")
  if woodsPmc < 0:
    skip("an offline Woods raid seeds PMC waves",
         "no Woods map in this database's locations table")
  else:
    check("an offline Woods raid seeds PMC waves", woodsPmc > 0,
          $woodsPmc & " pmcUSEC/pmcBEAR waves served for Woods")

  # -- the ORBIT loot-table census, over EVERY map -------------------------
  #
  # The bug this replaces was a live `warn` reading "0 of 429 static-container
  # rows parsed", which named a parser defect that does not exist: all 429
  # rows parse, and all 429 positions are (0,0,0) in db.json AND in the SPT
  # source. So the assertion is the NEGATIVE that can actually be falsified --
  # no map's loot tables fail to parse -- asked of ORBIT's OWN walker through
  # `/orbit/containers`, per map, with no raid running. Asking it of a
  # reimplementation of the walker here would be the self-comparison CLAUDE.md
  # 9b forbids.
  #
  # Falsifiability, verified by hand: change the reader's field name from
  # "template" to "templates" and `parseFailures` becomes 13 of 24 and this
  # goes red.
  var censusAsked = 0
  var parseFailures = 0
  var unresolved = 0
  var positionedMaps = 0
  var rowsTotal = 0
  var firstFail = ""
  for i in 0 ..< mapKeys.len:
    let cr = call("/aowlspt/tarkov/orbit/containers?map=" & mapKeys[i], "")
    if not cr.ok or cr.body.len == 0:
      continue
    inc censusAsked
    let verdict = textVal(cr.body, memberValue(cr.body, 0, "verdict"))
    let key = textVal(cr.body, memberValue(cr.body, 0, "key"))
    rowsTotal = rowsTotal + intVal(cr.body, memberValue(cr.body, 0, "rows"))
    if intVal(cr.body, memberValue(cr.body, 0, "positioned")) > 0:
      inc positionedMaps
    if key.len == 0:
      inc unresolved
    if verdict == "FAIL":
      inc parseFailures
      if firstFail.len == 0:
        firstFail = mapKeys[i] & ": " &
                    textVal(cr.body, memberValue(cr.body, 0, "why"))
  if censusAsked == 0:
    skip("the ORBIT loot-table census answers",
         "/aowlspt/tarkov/orbit/containers returned nothing for any of the " &
         $mapKeys.len & " maps -- INCONCLUSIVE, not a pass")
  else:
    check("every map answers the loot-table census",
          censusAsked == mapKeys.len,
          $censusAsked & " of " & $mapKeys.len & " answered")
    # The negative. A parse mismatch on ANY map fails the run.
    check("no map's loot tables fail to parse", parseFailures == 0,
          $parseFailures & " map(s) reported FAIL; first: " & firstFail)
    # And the id confusion that has failed silently four times: the census
    # reports the key it resolved to, so an unresolved id is visible rather
    # than reading as an empty map.
    check("every map id resolves to a database key", unresolved == 0,
          $unresolved & " of " & $censusAsked & " did not resolve")
    line "  census: " & $rowsTotal & " loot rows over " & $censusAsked &
         " maps, " & $positionedMaps &
         " with real coordinates (0 is expected without --loose)"

  # -- map lock / unlock ---------------------------------------------------
  #
  # The post-condition is asserted on the SERVED PAYLOAD, over EVERY map, and
  # it is phrased as a negative -- "no map reports unlocked" -- because that is
  # what can be falsified. Asking "is Woods locked?" cannot fail usefully: it
  # passes on a server that locked Woods and nothing else, and it passes on one
  # that locked everything by accident. Re-reading what we just wrote could not
  # fail at all, which is the shape CLAUDE.md 9b names.
  #
  # It also drives the setting through the real route rather than editing
  # config.json underneath the server, so the persist path, the re-apply and
  # the serve path are all in the loop.
  # SHAPE FIRST. Measured from BSG's own reply for this build
  # (data/post1/locations.json, capture seq 134): `Locked` is a plain JSON
  # bool on all 24 maps. An object or a string here does not degrade, it
  # throws in the client's deserialiser.
  var l0 = 0
  var u0 = 0
  var m0 = 0
  lockCensus(l0, u0, m0)
  check("every map carries Locked as a JSON bool",
        m0 == 0 and (l0 + u0) == mapKeys.len,
        $m0 & " map(s) with no bool Locked; " & $(l0 + u0) & " of " &
        $mapKeys.len & " readable")

  if not setTarkovSetting("mapsUnlockedByDefault", "false"):
    skip("locking every map is served to the client",
         "the settings POST did not persist, so nothing was changed to look at")
    skip("unlocking every map is served to the client", "same POST failure")
    skip("one map locked by its client-side Id spelling", "same POST failure")
  else:
    var l1 = 0
    var u1 = 0
    var m1 = 0
    lockCensus(l1, u1, m1)
    check("with the default OFF, NO map is served unlocked",
          u1 == 0 and m1 == 0 and l1 == mapKeys.len,
          $u1 & " map(s) still unlocked, " & $m1 & " unreadable, " & $l1 &
          " locked of " & $mapKeys.len)

    discard setTarkovSetting("mapsUnlockedByDefault", "true")
    var l2 = 0
    var u2 = 0
    var m2 = 0
    lockCensus(l2, u2, m2)
    check("with the default ON, NO map is served locked",
          l2 == 0 and m2 == 0 and u2 == mapKeys.len,
          $l2 & " map(s) still locked, " & $m2 & " unreadable, " & $u2 &
          " unlocked of " & $mapKeys.len)

    # THE NAME TRAP, as a check. "Woods" is the client-side `base.Id`; the
    # database key is `woods`. Facts #183/#185: only 4 of 19 maps spell the two
    # alike, and three earlier consumers of this distinction failed SILENTLY
    # with a wrong value. If `mapsLocked` did not go through
    # `canonicalLocation`, this locks nothing and the count stays 0 -- so the
    # check fails rather than passing quietly, which is the whole point of
    # asserting an exact count instead of ">= 0".
    discard setTarkovSetting("mapsLocked", "\"Woods\"")
    var l3 = 0
    var u3 = 0
    var m3 = 0
    lockCensus(l3, u3, m3)
    check("a map named by its client-side Id (\"Woods\") locks exactly one map",
          l3 == 1 and m3 == 0 and u3 == mapKeys.len - 1,
          $l3 & " locked (expected exactly 1), " & $u3 & " unlocked, " & $m3 &
          " unreadable -- 0 locked means the Id spelling did not resolve to " &
          "the database key, which is fact #183")

    # Put it back, so a run does not leave the install locked.
    discard setTarkovSetting("mapsLocked", "\"\"")
    var l4 = 0
    var u4 = 0
    var m4 = 0
    lockCensus(l4, u4, m4)
    check("clearing the lock list unlocks the map again",
          l4 == 0, $l4 & " map(s) still locked after clearing mapsLocked")

  # -- the two tables a `daytime` window is decided from -------------------
  #
  # `emu/questcond.daytimeVerdict` credits a night-only kill condition when the
  # raid's **whole possible span** lies inside the window, and refuses when it
  # crosses the edge. The span is this map's `EscapeTimeLimit` times the
  # acceleration, and when the client does not send one `emu/raid` uses the
  # ceiling of the `TimeFlowType` enum -- x8 -- because a span read too short is
  # a kill credited that was not earned.
  #
  # Which makes the whole feature contingent on a relationship between two
  # tables that no fixture has: **the narrowest quest window must be wider than
  # the longest map's fastest span**, or there is no start hour at all that
  # credits it and the twelve conditions are refused whatever this server does.
  # On a real import that is 7 hours (`The Survivalist Path - Eagle-Owl`, 21->4)
  # against Streets' 50 minutes at x8, which is 6 hours 40 -- twenty minutes of
  # margin, and worth knowing about rather than assuming.
  var longestRaid = 0
  var longestMap = ""
  for i in 0 ..< mapVals.len:
    let limit = intField(locR.body, mapVals[i], "EscapeTimeLimit")
    # `develop` at 60000 minutes and `hideout` at 99999 are not raids, and the
    # three maps at 0 are not playable. Half a day is the cut.
    if limit > 0 and limit <= 720 and limit > longestRaid:
      longestRaid = limit
      longestMap = mapKeys[i]
  check("the longest raid on any playable map is a raid, not a lobby",
        longestRaid > 0 and longestRaid <= 720,
        $longestRaid & " minutes on " & longestMap)
  if dayWidths.len == 0:
    skip("every night-only kill window is wider than the longest raid's clock",
         "no quest in this database restricts a kill by time of day")
  else:
    let widest = longestRaid * 8
    var undecidable = 0
    for w in dayWidths:
      if w <= widest:
        inc undecidable
    check("every night-only kill window is wider than the longest raid's clock",
          undecidable == 0,
          $undecidable & " of " & $dayWidths.len & " windows are no wider " &
          "than " & $widest & " minutes, so no start hour credits them; " &
          "narrowest is " & dayNarrowest)
    line "  " & $dayWidths.len & " time-of-day kill windows, narrowest " &
         $dayMinutes & " min (" & dayNarrowest & "), against " &
         $longestRaid & " min on " & longestMap & " -> " & $widest &
         " min at the TimeFlowType ceiling"

  # Loot, generated. This is the one place the emulator *makes* something out of
  # the database rather than handing a table back, so every item it invents is
  # checked against the table it invented it from.
  var lootMaps = 0
  var lootSpots = 0
  var lootItems = 0
  var lootDangling = 0
  var lootOrphans = 0
  var slotDupes = 0
  var slotDupeSample = ""
  var cellOverlaps = 0
  var cellOverlapSample = ""
  var gridPlaced = 0
  var grownPlaced = 0
  var sizeDb = ""
  discard readTextFile(staged, sizeDb)
  let tplSizes = buildTplSizes(sizeDb)
  sizeDb = ""
  var magsSeen = 0
  var magsLoaded = 0
  var magsEmptyLoad = 0
  var magSample = ""
  var lootSample = ""
  var m = 0
  while m < mapKeys.len and lootMaps < mapsToLoot:
    let name = mapKeys[m]
    let cfg = call("/client/raid/configuration",
                   "{\"location\":\"" & name & "\",\"timeVariant\":\"CURR\"," &
                   "\"raidMode\":\"Local\",\"side\":\"Pmc\"}")
    if not cfg.ok:
      inc m
      continue
    let floorBegan = micros()
    let floor1 = call("/client/location/getLocalloot",
                      "{\"locationId\":\"" & name & "\",\"variantId\":0}")
    let floorUs = micros() - floorBegan
    let lootAt = memberValue(floor1.body, dataAt(floor1), "Loot")
    if lootAt < 0:
      inc m
      continue
    var spots = 0
    var count = 0
    for spot in elements(floor1.body, lootAt):
      inc spots
      let inner = elements(floor1.body, memberValue(floor1.body, spot, "Items"))
      var ids = initHashSet[string]()
      for it in inner:
        incl(ids, textField(floor1.body, it, "_id"))
      # Magazines, and what is in them. `locations.<map>.staticAmmo` was
      # imported and read by nothing; `emu/loot.fillMagazine` now draws a
      # cartridge out of it for every magazine a weapon preset puts on the
      # floor. The claim is checked through *parentage* rather than by counting
      # cartridge templates, because the static pools spawn loose cartridges of
      # their own and a count would be green with the feature deleted.
      # NO TWO CHILDREN OF ONE PARENT MAY SHARE ONE (slotId, location).
      # Stated as a negative over the FINISHED payload rather than over any
      # particular generator: it is falsifiable, and it catches every future
      # variant -- ammo boxes, magazines, grids, presets alike.
      var addrs = initHashSet[string]()
      for it in inner:
        let k = slotKey(floor1.body, it)
        if k.len == 0:
          continue
        if contains(addrs, k):
          inc slotDupes
          if slotDupeSample.len == 0:
            slotDupeSample = name & " " & k & "  <- " &
                             textField(floor1.body, it, "_tpl")
        incl(addrs, k)
      # NO TWO ITEMS IN A GRID MAY OVERLAP, with each footprint computed the
      # way the CLIENT computes it. The weaker "same starting cell" claim above
      # is walked straight through by a 5x2 rifle reserved as 1x1: the two
      # weapons in the Woods `barrel_cache` had different origins and still
      # collided. Read off the FINISHED payload -- the children actually
      # emitted -- so it is not the generator compared against itself.
      var cells = initHashSet[string]()
      for it in inner:
        let locAt = memberValue(floor1.body, it, "location")
        if locAt < 0 or memberValue(floor1.body, locAt, "x") < 0:
          continue
        let tpl = textField(floor1.body, it, "_tpl")
        let ti = indexOfTpl(tplSizes, tpl)
        if ti < 0:
          continue
        var w = tplSizes.w[ti]
        var h = tplSizes.h[ti]
        let bareW = w
        let bareH = h
        if tplSizes.merges[ti]:
          # every descendant of this item, by parentage, capped at four hops
          var fam = initHashSet[string]()
          incl(fam, textField(floor1.body, it, "_id"))
          var hop = 0
          while hop < 4:
            for c in inner:
              if contains(fam, textField(floor1.body, c, "parentId")):
                incl(fam, textField(floor1.body, c, "_id"))
            inc hop
          var mu = 0
          var md = 0
          var ml = 0
          var mr = 0
          var au = 0
          var ad = 0
          var al = 0
          var ar = 0
          for c in inner:
            if c == it:
              continue
            if not contains(fam, textField(floor1.body, c, "_id")):
              continue
            let ci = indexOfTpl(tplSizes, textField(floor1.body, c, "_tpl"))
            if ci < 0:
              continue
            if tplSizes.forced[ci]:
              au = au + tplSizes.eu[ci]
              ad = ad + tplSizes.ed[ci]
              al = al + tplSizes.el[ci]
              ar = ar + tplSizes.er[ci]
            else:
              if tplSizes.eu[ci] > mu: mu = tplSizes.eu[ci]
              if tplSizes.ed[ci] > md: md = tplSizes.ed[ci]
              if tplSizes.el[ci] > ml: ml = tplSizes.el[ci]
              if tplSizes.er[ci] > mr: mr = tplSizes.er[ci]
          w = w + ml + mr + al + ar
          h = h + mu + md + au + ad
        if w < 1: w = 1
        if h < 1: h = 1
        if w != bareW or h != bareH:
          inc grownPlaced
        inc gridPlaced
        if textField(floor1.body, locAt, "r") == "Vertical":
          let t = w
          w = h
          h = t
        let grid = textField(floor1.body, it, "parentId") & "|" &
                   textField(floor1.body, it, "slotId")
        let x0 = intField(floor1.body, locAt, "x")
        let y0 = intField(floor1.body, locAt, "y")
        var yy = y0
        while yy < y0 + h:
          var xx = x0
          while xx < x0 + w:
            let key = grid & "|" & $xx & "|" & $yy
            if contains(cells, key):
              inc cellOverlaps
              if cellOverlapSample.len == 0:
                cellOverlapSample = name & " " & key & " <- " & tpl &
                                    " " & $w & "x" & $h
            incl(cells, key)
            inc xx
          inc yy
      var magIds = initHashSet[string]()
      for it in inner:
        if textField(floor1.body, it, "slotId") == "mod_magazine":
          incl(magIds, textField(floor1.body, it, "_id"))
      magsSeen = magsSeen + len(magIds)
      for it in inner:
        if not contains(magIds, textField(floor1.body, it, "parentId")):
          continue
        inc magsLoaded
        let rounds = intField(floor1.body,
                              memberValue(floor1.body, it, "upd"),
                              "StackObjectsCount")
        if rounds < 1:
          inc magsEmptyLoad
        if magSample.len == 0:
          magSample = name & ": " & textField(floor1.body, it, "_tpl") &
                      " x" & $rounds
      for it in inner:
        inc count
        let tpl = textField(floor1.body, it, "_tpl")
        if not contains(templateIds, tpl):
          inc lootDangling
          if lootSample.len == 0: lootSample = name & " " & tpl
        let parent = textField(floor1.body, it, "parentId")
        if parent.len > 0 and not contains(ids, parent):
          inc lootOrphans
          if lootSample.len == 0:
            lootSample = name & " " & textField(floor1.body, it, "_id") &
                         " -> " & parent
    lootSpots = lootSpots + spots
    lootItems = lootItems + count
    # A map with no loot tables does not count towards the number asked for.
    # Several of the nineteen are development maps with nothing in them, and
    # taking one of the three slots for `develop` means generating loot for one
    # real map instead of three.
    if count > 0:
      inc lootMaps
    line "  " & name & ": " & $spots & " spawn points, " & $count &
         " items, " & kib(floor1.body.len) & ", " & $(floorUs div 1000'i64) &
         " ms"
    inc m
  check("loot was generated from the database's own tables", lootItems > 0,
        $lootItems & " items over " & $lootMaps & " maps")
  # The magazines. `magsSeen` is the denominator and is asserted separately:
  # "no magazine was loaded" and "no weapon spawned at all" are different
  # answers and a single check cannot tell them apart.
  # The negative. `lootItems > 0` above is its denominator: zero items would
  # make this vacuously green, and the two claims are asserted separately for
  # that reason.
  check("no container puts two items at the same (slotId, location)",
        slotDupes == 0,
        $slotDupes & " colliding positions, first: " & slotDupeSample)
  # The footprint negative, and its denominator asserted separately: a run in
  # which no modded weapon was ever placed would satisfy the overlap claim
  # vacuously, which is the "check that cannot fail" this exists to avoid.
  check("weapons whose mods grow them past their template were placed",
        grownPlaced > 0,
        "of " & $gridPlaced & " grid-placed items, none was larger than its " &
        "own template -- the overlap check below proves nothing")
  check("no two items in a grid overlap, mod extensions included",
        cellOverlaps == 0,
        $cellOverlaps & " overlapping cells over " & $gridPlaced &
        " grid-placed items (" & $grownPlaced & " mod-grown), first: " &
        cellOverlapSample)
  check("weapon presets put magazines on the floor", magsSeen > 0,
        "no item on any of these maps is slotted mod_magazine")
  check("and the map's own `staticAmmo` table loads them", magsLoaded > 0,
        $magsSeen & " magazines and not one round in any of them")
  check("with a real round count in every loaded one", magsEmptyLoad == 0,
        $magsEmptyLoad & " magazines carry a cartridge with no stack count")
  if magsSeen > 0:
    line "  " & $magsLoaded & " of " & $magsSeen &
         " magazines loaded from staticAmmo, e.g. " & magSample
  check("every item the loot generator invented is a real template",
        lootDangling == 0, $lootDangling & " dangling, e.g. " & lootSample)
  # A mod on a weapon whose parent was left behind is an item the client cannot
  # draw and the player cannot pick up. It is the failure mode of expanding a
  # preset -- and a preset is exactly what a real database has and a fixture
  # has one of.
  check("every item it invented is attached to something in the same spawn",
        lootOrphans == 0, $lootOrphans & " orphans, e.g. " & lootSample)

  # =========================================================================
  heading "Bots, against the real role tables"
  # =========================================================================
  #
  # The database half of the bot generator, and it is here rather than in the
  # mod's own load gate deliberately. `emu/bots` carries a self-check over
  # literal tables -- pure arithmetic, which no input can work around, and a
  # server that fails it refuses to serve. The assertions below are about
  # *somebody else's data*: that every role writes its five appearance tables
  # as weight maps, that every health variant names all seven body parts, that
  # `bots/base.json` was imported at all. Every one of them is a claim a mod is
  # allowed to break, and a load-time refusal over a modded bot table would be
  # this server declining to start because a player installed something. So
  # they report here, against a real import, and refuse nothing.
  #
  # Three defects made this section worth writing, and all three shipped green:
  # every bot in every raid wore the same four appearance ids, every bot got
  # the literal 35/85 human health -- bosses included -- and the voice went to
  # `Info.Voice`, which is not a member of the client's `BotBase` at all.
  var botRoles = 0
  var botVariants = 0
  var botHeadKinds = 0
  var botRole = ""
  var dbText = ""
  if not readTextFile(staged, dbText):
    skip("every role's appearance tables", "could not read " & staged)
    skip("every role's health variants", "could not read " & staged)
    skip("bots.base", "could not read " & staged)
    skip("twenty bots are not all in one hat", "could not read " & staged)
  else:
    var rootAt = 0
    while rootAt < dbText.len and dbText[rootAt] != '{':
      inc rootAt
    let botsAt = memberValue(dbText, rootAt, "bots")
    var roleNames: seq[string] = @[]
    var roleVals: seq[int] = @[]
    members(dbText, memberValue(dbText, botsAt, "types"), roleNames, roleVals)
    botRoles = roleNames.len

    # 1. All five appearance tables, on every role, as objects.
    #
    # `pickFromPool` reads an array too, and that leniency is deliberate: the
    # failure mode of refusing one is not a refusal, it is the default id on
    # every bot on the map. So the array shape cannot be caught by anything the
    # server does with it -- it can only be caught by looking at what the
    # database actually says, which is what this does.
    var badApp = 0
    var badAppSample = ""
    var missingVoice = 0
    var i2 = 0
    while i2 < roleNames.len:
      let appAt = memberValue(dbText, roleVals[i2], "appearance")
      for table in ["head", "body", "feet", "hands", "voice"]:
        let at = memberValue(dbText, appAt, table)
        if at < 0:
          if table == "voice":
            inc missingVoice
          else:
            inc badApp
            if badAppSample.len == 0:
              badAppSample = roleNames[i2] & "." & table & " is absent"
        elif dbText[at] != '{':
          inc badApp
          if badAppSample.len == 0:
            badAppSample = roleNames[i2] & "." & table & " is " &
                           slice(dbText, at)
      inc i2
    check("every bot role writes all five appearance tables as weight maps",
          roleNames.len > 0 and badApp == 0 and missingVoice == 0,
          $badApp & " of " & $(roleNames.len * 5) & " tables are not objects" &
          (if badAppSample.len > 0: ", e.g. " & badAppSample else: "") &
          ", and " & $missingVoice & " roles carry no voice table")

    # 2. Every variant of every role's `BodyParts` names all seven parts.
    #
    # `bodyPartsOf` refuses a partial table *whole* and falls back to a
    # complete human, which is the right call -- half a body is a bot the
    # client will not spawn -- and it means a role missing a leg is not a crash
    # and not a log line. It is a boss with a scav's health, which is exactly
    # the defect this replaced and exactly what no route can be asked about.
    var badParts = 0
    var badPartsSample = ""
    var noHealth = 0
    i2 = 0
    while i2 < roleNames.len:
      let hAt = memberValue(dbText, roleVals[i2], "health")
      let bpAt = memberValue(dbText, hAt, "BodyParts")
      if bpAt < 0 or dbText[bpAt] != '[':
        inc noHealth
        if badPartsSample.len == 0:
          badPartsSample = roleNames[i2] & " has no BodyParts list"
      else:
        let variants = elements(dbText, bpAt)
        if variants.len == 0:
          inc noHealth
          if badPartsSample.len == 0:
            badPartsSample = roleNames[i2] & " has an empty BodyParts list"
        for v in variants:
          inc botVariants
          for part in ["Head", "Chest", "Stomach", "LeftArm", "RightArm",
                       "LeftLeg", "RightLeg"]:
            if memberValue(dbText, v, part) < 0:
              inc badParts
              if badPartsSample.len == 0:
                badPartsSample = roleNames[i2] & " has a variant with no " &
                                 part
      inc i2
    check("and every health variant of every role names all seven body parts",
          roleNames.len > 0 and noHealth == 0 and badParts == 0,
          $noHealth & " roles with no variant list and " & $badParts &
          " missing parts over " & $botVariants & " variants" &
          (if badPartsSample.len > 0: ", e.g. " & badPartsSample else: ""))

    # 3. `bots/base.json` -- 2 KB, imported, and for a long time never opened.
    #    `Customization.Voice` is the member that matters: it is a template id,
    #    it is `Nullable<MongoId>` on the client's own type, and it is where a
    #    voice lives. `Info.Voice`, where the voice used to be written, is not
    #    a member of anything.
    let baseAt = memberValue(dbText, botsAt, "base")
    let baseCust = memberValue(dbText, baseAt, "Customization")
    let baseVoice = textVal(dbText, memberValue(dbText, baseCust, "Voice"))
    check("bots.base is in the database, with a voice on its Customization",
          baseAt >= 0 and dbText[baseAt] == '{' and baseCust >= 0 and
          baseVoice.len > 0 and memberValue(dbText, baseAt, "Info") >= 0,
          (if baseAt < 0: "there is no bots.base in this database"
           else: "Customization.Voice is " & baseVoice))

    # 4. And a generated batch, over the wire, on whichever role the database
    #    gives the most heads to. Discovered rather than named, like every
    #    other id in this file: a database imported next year picks a different
    #    role and the check means the same thing.
    var bestHeads = 0
    i2 = 0
    while i2 < roleNames.len:
      let headAt = memberValue(dbText,
                     memberValue(dbText, roleVals[i2], "appearance"), "head")
      if headAt >= 0 and dbText[headAt] == '{':
        var headKeys: seq[string] = @[]
        var headVals: seq[int] = @[]
        members(dbText, headAt, headKeys, headVals)
        if headKeys.len > bestHeads:
          bestHeads = headKeys.len
          botRole = roleNames[i2]
      inc i2
    if botRole.len == 0 or bestHeads < 2:
      skip("twenty bots are not all wearing the same head",
           "no role in this database names two heads")
    else:
      let batch = timed("a batch of bots", "/client/game/bot/generate",
        "{\"conditions\":[{\"Role\":\"" & botRole &
        "\",\"Limit\":20,\"Difficulty\":\"normal\"}]}")
      let botList = elements(batch.body, dataAt(batch))
      check("a batch of twenty bots is generated off the real role tables",
            batch.ok and botList.len == 20,
            $botList.len & " bots for " & botRole & ": " & why(batch))
      var botHeads = initHashSet[string]()
      var noVoice = 0
      for b in botList:
        let cAt = memberValue(batch.body, b, "Customization")
        incl(botHeads,
             textVal(batch.body, memberValue(batch.body, cAt, "Head")))
        if textVal(batch.body, memberValue(batch.body, cAt, "Voice")).len == 0:
          inc noVoice
      botHeadKinds = botHeads.len
      # The one that would have caught the original defect on its own. A real
      # `head` table has a dozen entries in it, and one distinct head over
      # twenty draws is what a raid full of identical scavs looks like from
      # here.
      check("and twenty of them are not all wearing the same head",
            botList.len == 20 and botHeadKinds > 1 and noVoice == 0,
            $botHeadKinds & " distinct heads over " & $botList.len & " " &
            botRole & " bots drawn from " & $bestHeads & " weighted ids, and " &
            $noVoice & " of them have no voice")

  # =========================================================================
  heading "Generated bot weapons are COMPLETE weapons"
  # =========================================================================
  #
  # The receiver-only scav. A weapon is a root item plus a tree of mods parented
  # by (parentId, slotId); each item's template declares in `_props.Slots` which
  # of its slots are `_required`. A functional gun has every required slot on
  # every item in that tree filled -- the receiver, the barrel under it, the
  # pistol grip and gas block on the frame. The generator used to honour only the
  # per-slot CHANCE table, which lists `mod_pistol_grip` at 0 and `mod_stock` at
  # 48 on an AK, so it shipped guns missing parts a player then found on a corpse.
  #
  # The assertion is a NEGATIVE over the FINISHED loadout, not over the write:
  # across many bots and roles, ZERO items in any weapon tree have a fillable
  # required slot left empty. A single empty required slot turns it red, which is
  # exactly the state a player saw.
  block weaponCompleteness:
    # A tpl -> index into the served item table, built once.
    var tplIndex = initTable[string, int]()
    var ti = 0
    while ti < tplKeys.len:
      tplIndex[tplKeys[ti]] = tplVals[ti]
      inc ti

    var rolesTested = 0
    var weaponsChecked = 0
    var treesInconclusive = 0    # a tpl the served item table does not carry
    var violations = 0
    var firstViol = ""
    # fix(2): magazine/ammo coherence, asserted over the FINISHED loadout.
    var magsChecked = 0
    var magsNoAmmo = 0        # a mod_magazine with no loaded cartridge
    var magsWrongCaliber = 0  # loaded round's Caliber != the weapon's ammoCaliber
    var magsRejected = 0      # loaded round not in the magazine's own filter
    var firstMagViol = ""

    # A handful of roles, discovered from the database rather than named, so the
    # check survives an import that ships a different roster. Read from `dbText`
    # (the staged database, in outer scope) rather than the `roleNames` the
    # appearance block built inside its own `else:`.
    var rolesToTry: seq[string] = @[]
    if dbText.len > 0:
      var rootAt2 = 0
      while rootAt2 < dbText.len and dbText[rootAt2] != '{':
        inc rootAt2
      let typesAt = memberValue(dbText, memberValue(dbText, rootAt2, "bots"),
                                "types")
      if typesAt >= 0 and dbText[typesAt] == '{':
        var rNames: seq[string] = @[]
        var rVals: seq[int] = @[]
        members(dbText, typesAt, rNames, rVals)
        var rr = 0
        while rr < rNames.len and rolesToTry.len < 5:
          rolesToTry.add rNames[rr]
          inc rr

    for role in rolesToTry:
      let batch = call("/client/game/bot/generate",
        "{\"conditions\":[{\"Role\":\"" & role &
        "\",\"Limit\":8,\"Difficulty\":\"normal\"}]}")
      let bots = elements(batch.body, dataAt(batch))
      if not batch.ok or bots.len == 0:
        continue
      inc rolesTested
      for b in bots:
        let invAt = memberValue(batch.body, b, "Inventory")
        let itemsAt = memberValue(batch.body, invAt, "items")
        if itemsAt < 0 or batch.body[itemsAt] != '[':
          continue
        let items = elements(batch.body, itemsAt)
        # Group children by parentId, each as the lowercased set of slotIds it
        # fills. `slotId` on an equipment item is its equipment slot; on a mod it
        # is the mod slot it occupies -- exactly the `_name` a `_props.Slots`
        # entry carries, which is what the required-slot test matches against.
        var childSlots = initTable[string, HashSet[string]]()
        var roots: seq[int] = @[]
        for it in items:
          let parent = textField(batch.body, it, "parentId")
          let slot = textField(batch.body, it, "slotId")
          if parent.len > 0:
            var s0 = childSlots.getOrDefault(parent, initHashSet[string]())
            s0.incl toLowerAscii(slot)
            childSlots[parent] = s0
          if slot == "FirstPrimaryWeapon" or slot == "SecondPrimaryWeapon" or
             slot == "Holster":
            roots.add it
        # Walk each weapon tree, an explicit queue with a head index (nimony has
        # no `seq.pop`), depth-bounded like the generator itself.
        for root in roots:
          inc weaponsChecked
          var queue: seq[int] = @[root]
          var head = 0
          while head < queue.len and head < 400:
            let cur = queue[head]
            inc head
            let curId = textField(batch.body, cur, "_id")
            let curTpl = textField(batch.body, cur, "_tpl")
            let idx = tplIndex.getOrDefault(curTpl, -1)
            if idx < 0:
              inc treesInconclusive
            else:
              let req = requiredSlotsOf(itemsR.body, idx)
              let curSet = childSlots.getOrDefault(curId, initHashSet[string]())
              for slotName in req:
                if not curSet.contains(toLowerAscii(slotName)):
                  inc violations
                  if firstViol.len == 0:
                    firstViol = role & " " & curTpl & " missing required " &
                                slotName
              # Descend into this item's children.
              if curId.len > 0:
                for it in items:
                  if textField(batch.body, it, "parentId") == curId:
                    queue.add it

        # Magazine/ammo coherence over the same served items. A weapon with a
        # magazine must have a mag whose caliber matches the weapon and which
        # holds a round it accepts -- otherwise the client refuses the round and
        # the bot spawns with an empty gun. Built from an id->tpl map so a mag's
        # parent weapon can be named. Negatives, all falsifiable: no mag empty,
        # none holding a round its own filter omits, none whose round is the
        # wrong caliber for the weapon it hangs on.
        var idTpl = initTable[string, string]()
        var idParent = initTable[string, string]()
        for it in items:
          let iid = textField(batch.body, it, "_id")
          if iid.len > 0:
            idTpl[iid] = textField(batch.body, it, "_tpl")
            idParent[iid] = textField(batch.body, it, "parentId")
        for it in items:
          if toLowerAscii(textField(batch.body, it, "slotId")) != "mod_magazine":
            continue
          let magId = textField(batch.body, it, "_id")
          let magTpl = textField(batch.body, it, "_tpl")
          let weaponTpl = idTpl.getOrDefault(
            idParent.getOrDefault(magId, ""), "")
          let magIdx = tplIndex.getOrDefault(magTpl, -1)
          let wIdx = tplIndex.getOrDefault(weaponTpl, -1)
          if magIdx < 0 or wIdx < 0:
            continue    # not in the served item table -- inconclusive, skipped
          inc magsChecked
          let wCaliber = propTextOf(itemsR.body, wIdx, "ammoCaliber")
          let accepts = magFilterOf(itemsR.body, magIdx)
          # The loaded round: a child of the mag slotted `cartridges` with a
          # positive stack.
          var roundTpl = ""
          var stack = 0
          for c in items:
            if textField(batch.body, c, "parentId") == magId and
               toLowerAscii(textField(batch.body, c, "slotId")) == "cartridges":
              roundTpl = textField(batch.body, c, "_tpl")
              let updAt = memberValue(batch.body, c, "upd")
              if updAt >= 0:
                stack = intField(batch.body, updAt, "StackObjectsCount")
              break
          if roundTpl.len == 0 or stack <= 0:
            inc magsNoAmmo
            if firstMagViol.len == 0:
              firstMagViol = role & " " & magTpl & " on " & weaponTpl &
                             " holds no ammo"
            continue
          if accepts.len > 0 and not contains(accepts, roundTpl):
            inc magsRejected
            if firstMagViol.len == 0:
              firstMagViol = role & " mag " & magTpl & " loaded " & roundTpl &
                             ", not in its own filter"
          let rIdx = tplIndex.getOrDefault(roundTpl, -1)
          if rIdx >= 0 and wCaliber.len > 0:
            let rCaliber = propTextOf(itemsR.body, rIdx, "Caliber")
            if rCaliber.len > 0 and rCaliber != wCaliber:
              inc magsWrongCaliber
              if firstMagViol.len == 0:
                firstMagViol = role & " " & weaponTpl & " (" & wCaliber &
                               ") loaded " & rCaliber & " round " & roundTpl

    if rolesTested == 0 or weaponsChecked == 0:
      skip("every generated bot weapon fills its required mod slots",
           "no role produced a bot carrying a weapon in this database")
    else:
      check("every generated bot weapon fills its required mod slots",
            violations == 0,
            $violations & " empty required slot(s) over " & $weaponsChecked &
            " weapon trees on " & $rolesTested & " roles" &
            (if firstViol.len > 0: "; e.g. " & firstViol else: "") &
            (if treesInconclusive > 0:
               " (" & $treesInconclusive & " mod tpls not in item table, skipped)"
             else: ""))
      if magsChecked == 0:
        skip("every generated bot magazine holds matching ammo",
             "no weapon in any generated bot carried a magazine in the item " &
             "table -- INCONCLUSIVE, not a pass")
      else:
        check("every generated bot magazine holds ammo it accepts, of the " &
              "weapon's caliber",
              magsNoAmmo == 0 and magsRejected == 0 and magsWrongCaliber == 0,
              $magsNoAmmo & " empty, " & $magsRejected &
              " holding a rejected round, " & $magsWrongCaliber &
              " wrong-caliber, over " & $magsChecked & " magazines" &
              (if firstMagViol.len > 0: "; e.g. " & firstMagViol else: ""))

  # =========================================================================
  heading "A session, on the real tables"
  # =========================================================================
  let created = call("/client/game/profile/create",
                     "{\"nickname\":\"RealTest\",\"side\":\"Usec\",\"headId\":\"x\"}")
  let uid = textField(created.body, dataAt(created), "uid")
  # A stop rather than a check, for the same reason as `/client/items` above:
  # every one of the forty checks below is about a profile, and forty failures
  # that all mean "there is no profile" describe this line and nothing else.
  if uid.len != 24:
    err "the server did not create a profile: " & why(created)
    cSpawnKill(server)
    return 1
  ok "a profile was created against the real tables"
  inc gChecks
  discard call("/client/game/profile/select", "{\"uid\":\"" & uid & "\"}")

  var listR = call("/client/game/profile/list", "")
  var profAt = profileOf(listR.body, uid)
  check("the profile comes back in the list", profAt >= 0, "not in the list")

  # The stash, discovered rather than assumed. `Inventory.stash` names an item;
  # that item's template must be in the item table and must have a grid, or
  # there is nowhere to put anything and every purchase below is refused for a
  # reason that has nothing to do with the purchase.
  let invAt = memberValue(listR.body, profAt, "Inventory")
  let stashId = textField(listR.body, invAt, "stash")
  let stashAt = itemAt(listR.body, profAt, stashId)
  check("the profile's stash names an item the profile holds", stashAt >= 0,
        stashId)
  let stashTpl = textField(listR.body, stashAt, "_tpl")
  check("the stash's template is one the item table has",
        contains(templateIds, stashTpl), stashTpl)
  var cellsH = 0
  var cellsV = 0
  block:
    var idx = -1
    var k = 0
    while k < tplKeys.len:
      if tplKeys[k] == stashTpl:
        idx = tplVals[k]
        break
      inc k
    if idx >= 0:
      let grids = elements(itemsR.body,
                           memberValue(itemsR.body,
                                       memberValue(itemsR.body, idx, "_props"),
                                       "Grids"))
      if grids.len > 0:
        let props = memberValue(itemsR.body, grids[0], "_props")
        cellsH = intField(itemsR.body, props, "cellsH")
        cellsV = intField(itemsR.body, props, "cellsV")
  check("and that template has a grid with room in it",
        cellsH > 0 and cellsV > 0, $cellsH & "x" & $cellsV)
  line "  stash " & stashTpl & ": " & $cellsH & " by " & $cellsV & " cells"

  var moneyId = firstMoneyId(listR.body, profAt)
  check("the starting money is in the stash", moneyId.len == 24, moneyId)

  # -- buying, at the price the offer itself names --------------------------
  var bought = ""
  var boughtTpl = ""
  var boughtCost = 0
  var sellPrice = 0
  var pick = -1
  var cheapest = 0
  var o = 0
  while o < offers.len:
    # Cheap, but not so cheap the arithmetic cannot be seen, and priced by the
    # handbook so that selling it back has a defined answer.
    if offers[o].price > 500 and contains(pricedIds, offers[o].tpl) and
       (pick < 0 or offers[o].price < cheapest):
      pick = o
      cheapest = offers[o].price
    inc o
  if pick < 0:
    skip("a trader offer can be bought", "no trader sells anything for roubles")
  else:
    let offer = offers[pick]
    boughtTpl = offer.tpl
    boughtCost = offer.price
    for e in hbItems:
      if textField(hbR.body, e, "Id") == offer.tpl:
        sellPrice = intField(hbR.body, e, "Price")
        break
    let before = moneyIn(listR.body, profAt)
    let buy = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"TradingConfirm\",\"type\":\"buy_from_trader\"," &
      "\"tid\":\"" & offer.trader & "\",\"item_id\":\"" & offer.root &
      "\",\"count\":1,\"scheme_id\":0,\"scheme_items\":[{\"id\":\"" & moneyId &
      "\",\"count\":" & $offer.price & "}]}],\"tm\":2}")
    check("a real trader offer can be bought at the price its barter names",
          buy.ok and buy.contains(offer.tpl) and
          not buy.contains("that offer costs"), buy.body)
    listR = call("/client/game/profile/list", "")
    profAt = profileOf(listR.body, uid)
    let after = moneyIn(listR.body, profAt)
    check("and takes exactly that many roubles", before - after == offer.price,
          $before & " - " & $after & " != " & $offer.price)
    let held = heldOf(listR.body, profAt, offer.tpl)
    check("and the item arrives", held.len == 1, $held.len & " of it")
    if held.len > 0:
      bought = held[held.len - 1]
      let at = itemAt(listR.body, profAt, bought)
      check("in a cell of its own in the stash",
            memberValue(listR.body, at, "location") >= 0 and
            textField(listR.body, at, "parentId") == stashId,
            slice(listR.body, at))
    line "  bought " & offer.tpl & " from " & offer.trader & " for " &
         $offer.price & " roubles (handbook " & $sellPrice & ")"

    # The request does not get to do the arithmetic. Against a fixture the price
    # is one the test wrote; here it is the database's, and the refusal has to
    # name it.
    let cheat = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"TradingConfirm\",\"type\":\"buy_from_trader\"," &
      "\"tid\":\"" & offer.trader & "\",\"item_id\":\"" & offer.root &
      "\",\"count\":1,\"scheme_items\":[{\"id\":\"" & moneyId &
      "\",\"count\":1}]}],\"tm\":2}")
    check("paying one rouble for it is refused, at the price the data says",
          cheat.contains("that offer costs " & $offer.price), cheat.body)
    listR = call("/client/game/profile/list", "")
    profAt = profileOf(listR.body, uid)
    check("and nothing extra was delivered",
          heldOf(listR.body, profAt, offer.tpl).len == 1,
          $heldOf(listR.body, profAt, offer.tpl).len & " of it")

  # -- selling it back, at the handbook's price -----------------------------
  if bought.len == 24 and sellPrice > 0:
    let before = moneyIn(listR.body, profAt)
    let sell = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"TradingConfirm\",\"type\":\"sell_to_trader\"," &
      "\"tid\":\"" & offers[pick].trader & "\",\"items\":[{\"id\":\"" & bought &
      "\",\"count\":1,\"scheme_id\":0}]}],\"tm\":2}")
    check("selling it back is accepted", sell.ok and
          not sell.contains("no price is known"), sell.body)
    listR = call("/client/game/profile/list", "")
    profAt = profileOf(listR.body, uid)
    check("and pays exactly the handbook price the client was shown",
          moneyIn(listR.body, profAt) - before == sellPrice,
          $(moneyIn(listR.body, profAt) - before) & " != " & $sellPrice)
    # Turnover is state, and it is arithmetic on two numbers this run
    # discovered rather than on two numbers it wrote down.
    let info = memberValue(listR.body,
                           memberValue(listR.body, profAt, "TradersInfo"),
                           offers[pick].trader)
    check("and the trader's turnover is the sum of what changed hands",
          intField(listR.body, info, "salesSum") == boughtCost + sellPrice,
          $intField(listR.body, info, "salesSum") & " != " &
          $(boughtCost + sellPrice))
  else:
    skip("selling at the handbook price", "nothing bought to sell")

  # -- the flea, built off the real handbook and the real assorts -----------
  let fleaBegan = micros()
  let flea = call("/client/ragfair/find",
                  "{\"page\":0,\"limit\":50,\"sortType\":5,\"sortDirection\":0}")
  let fleaUs = micros() - fleaBegan
  let fleaAt = dataAt(flea)
  let rows = elements(flea.body, memberValue(flea.body, fleaAt, "offers"))
  check("the flea builds a page of offers out of the real tables",
        rows.len > 0, flea.body)
  var fleaDangling = 0
  var fleaFree = 0
  for row in rows:
    if intField(flea.body, row, "summaryCost") <= 0:
      inc fleaFree
    for it in elements(flea.body, memberValue(flea.body, row, "items")):
      if not contains(templateIds, textField(flea.body, it, "_tpl")):
        inc fleaDangling
  check("every offer on it is for a template the item table has",
        fleaDangling == 0, $fleaDangling & " dangling")
  # An offer with no price sorts to the top of every cheapest-first search and
  # is free. On a fixture there is one barter to get this wrong with; here there
  # are thousands.
  check("and no offer is priced at nothing", fleaFree == 0,
        $fleaFree & " free offers")
  line "  " & $intField(flea.body, fleaAt, "offersCount") &
       " offers matched, " & $rows.len & " on the page, " &
       $(fleaUs div 1000'i64) & " ms"

  # Both halves of the list are on it. This is the check the whole flea rework
  # came out of: the market used to be filled with trader stock until the cap
  # was spent, so against this database it was 600 rows of Prapor, Therapist and
  # Skier and not one generated offer -- and nothing said so.
  var fleaTraderRows = 0
  var fleaPlayerRows = 0
  for row in rows:
    if intField(flea.body, memberValue(flea.body, row, "user"),
                "memberType") == 4:
      inc fleaTraderRows
    else:
      inc fleaPlayerRows
  check("and the page carries both trader stock and generated offers",
        fleaTraderRows > 0 and fleaPlayerRows > 0,
        $fleaTraderRows & " trader row(s), " & $fleaPlayerRows & " player row(s)")

  # -- and the statement a player would make ---------------------------------
  #
  # A hideout stage material no trader sells, at any loyalty level, in any
  # currency, in any barter. Against this database those exist -- a bolt and a
  # screw nut are on nobody's screen -- and until the market's cap was shared
  # out they were on nobody's flea either, which made them raid-only: not this
  # game's economy, and said nowhere.
  var orphan = ""
  var orphanNeed = 0
  for a in areaList:
    if orphan.len > 0:
      break
    var sk2: seq[string] = @[]
    var sv2: seq[int] = @[]
    members(areasR.body, memberValue(areasR.body, a, "stages"), sk2, sv2)
    var s2 = 0
    while s2 < sk2.len and orphan.len == 0:
      for req in elements(areasR.body,
                          memberValue(areasR.body, sv2[s2], "requirements")):
        if textField(areasR.body, req, "type") != "Item":
          continue
        let tpl = textField(areasR.body, req, "templateId")
        if tpl.len == 0 or tpl == Roubles or contains(assortTpls, tpl):
          continue
        orphan = tpl
        orphanNeed = intField(areasR.body, req, "count")
        break
      inc s2
  if orphan.len == 0:
    skip("buying a hideout material no trader sells",
         "every material every hideout stage asks for is on a trader screen")
  else:
    let hunt = call("/client/ragfair/find",
      "{\"page\":0,\"limit\":10,\"sortType\":5,\"sortDirection\":0," &
      "\"handbookId\":\"" & orphan & "\"}")
    var orphanOffer = ""
    var orphanCost = 0
    var orphanUnits = 0
    for row in elements(hunt.body, memberValue(hunt.body, dataAt(hunt),
                                               "offers")):
      var isIt = false
      for it in elements(hunt.body, memberValue(hunt.body, row, "items")):
        if textField(hunt.body, it, "_tpl") == orphan:
          isIt = true
      if not isIt:
        continue
      orphanOffer = textField(hunt.body, row, "_id")
      orphanCost = intField(hunt.body, row, "summaryCost")
      # What one purchase delivers: the whole lot when the offer is sold in one
      # piece, one of it otherwise. The server's own rule, and the count this
      # then holds it to.
      orphanUnits = 1
      if boolField(hunt.body, row, "sellInOnePiece"):
        orphanUnits = intField(hunt.body, row, "quantity")
      break
    check("a hideout material no trader sells is on the flea",
          orphanOffer.len == 24 and orphanCost > 0,
          orphan & " (needed " & $orphanNeed & "): " & hunt.body)
    if orphanOffer.len == 24:
      listR = call("/client/game/profile/list", "")
      profAt = profileOf(listR.body, uid)
      let hadMoney = moneyIn(listR.body, profAt)
      let hadUnits = unitsOf(listR.body, profAt, orphan)
      let boughtOrphan = call("/client/game/profile/items/moving",
        "{\"data\":[{\"Action\":\"RagFairBuyOffer\",\"offers\":[{\"id\":\"" &
        orphanOffer & "\",\"count\":1,\"items\":[{\"id\":\"" & moneyId &
        "\",\"count\":" & $orphanCost & "}]}]}],\"tm\":2}")
      listR = call("/client/game/profile/list", "")
      profAt = profileOf(listR.body, uid)
      check("and buying it delivers exactly what the offer said",
            boughtOrphan.ok and
            unitsOf(listR.body, profAt, orphan) - hadUnits == orphanUnits,
            $(unitsOf(listR.body, profAt, orphan) - hadUnits) & " arrived, " &
            $orphanUnits & " expected: " & boughtOrphan.body)
      check("and costs exactly what the row was priced at",
            hadMoney - moneyIn(listR.body, profAt) == orphanCost,
            $(hadMoney - moneyIn(listR.body, profAt)) & " != " & $orphanCost)

  # Listing something real, and finding it again as the player's own.
  listR = call("/client/game/profile/list", "")
  profAt = profileOf(listR.body, uid)
  var toList = ""
  if pick >= 0:
    let buyAgain = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"TradingConfirm\",\"type\":\"buy_from_trader\"," &
      "\"tid\":\"" & offers[pick].trader & "\",\"item_id\":\"" &
      offers[pick].root & "\",\"count\":1,\"scheme_id\":0," &
      "\"scheme_items\":[{\"id\":\"" & moneyId & "\",\"count\":" &
      $offers[pick].price & "}]}],\"tm\":2}")
    if buyAgain.ok:
      listR = call("/client/game/profile/list", "")
      profAt = profileOf(listR.body, uid)
      let held = heldOf(listR.body, profAt, offers[pick].tpl)
      if held.len > 0:
        toList = held[held.len - 1]
  if toList.len == 24:
    let listed = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"RagFairAddOffer\",\"sellInOnePiece\":false," &
      "\"items\":[\"" & toList & "\"],\"requirements\":[{\"_tpl\":\"" &
      Roubles & "\",\"count\":999999}]}],\"tm\":2}")
    check("a real item can be listed on the flea", listed.ok and
          not listed.contains("not here"), listed.body)
    listR = call("/client/game/profile/list", "")
    profAt = profileOf(listR.body, uid)
    check("and it leaves the stash while it is listed",
          itemAt(listR.body, profAt, toList) < 0, "still in the stash")
    # Asked for by template. It used to be asked for as "every player offer,
    # cheapest first, first fifty" -- which found it only because the market
    # was 100% trader stock and the player's was the *only* player offer there
    # was. With the generated half of the market back, a listing priced at
    # 999999 is not on the first page of a cheapest-first search and never
    # should have been what this check depended on.
    let mine = call("/client/ragfair/find",
      "{\"page\":0,\"limit\":50,\"offerOwnerType\":2,\"sortType\":5," &
      "\"handbookId\":\"" & offers[pick].tpl & "\"}")
    let mineRows = elements(mine.body,
                            memberValue(mine.body, dataAt(mine), "offers"))
    var found = false
    for row in mineRows:
      for it in elements(mine.body, memberValue(mine.body, row, "items")):
        if textField(mine.body, it, "_id") == toList:
          found = true
    check("and the player's own offers carry it", found, mine.body)
  else:
    skip("listing a real item on the flea", "nothing to list")

  # -- a real quest ---------------------------------------------------------
  if playQuest.len == 0:
    skip("accepting and progressing a real quest",
         "no quest in this database has an ungated handover a trader supplies")
  else:
    let accepted = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"QuestAccept\",\"qid\":\"" & playQuest &
      "\"}],\"tm\":2}")
    check("a real quest with no prerequisite can be accepted",
          accepted.ok and not accepted.contains("cannot accept"), accepted.body)
    listR = call("/client/game/profile/list", "")
    profAt = profileOf(listR.body, uid)
    var started = false
    for qe in elements(listR.body, memberValue(listR.body, profAt, "Quests")):
      if textField(listR.body, qe, "qid") == playQuest and
         textField(listR.body, qe, "status") == "Started":
        started = true
    check("and the profile records it as started", started,
          slice(listR.body, memberValue(listR.body, profAt, "Quests")))

    # Buy exactly what it asks for, from the trader who has it.
    let idx = findOffer(offers, playTemplate)
    var handIds: seq[string] = @[]
    if idx >= 0:
      var k = 0
      while k < playCount:
        discard call("/client/game/profile/items/moving",
          "{\"data\":[{\"Action\":\"TradingConfirm\"," &
          "\"type\":\"buy_from_trader\",\"tid\":\"" & offers[idx].trader &
          "\",\"item_id\":\"" & offers[idx].root &
          "\",\"count\":1,\"scheme_id\":0,\"scheme_items\":[{\"id\":\"" &
          moneyId & "\",\"count\":" & $offers[idx].price & "}]}],\"tm\":2}")
        inc k
      listR = call("/client/game/profile/list", "")
      profAt = profileOf(listR.body, uid)
      handIds = heldOf(listR.body, profAt, playTemplate)
    check("the quest's own item can be bought from a trader who sells it",
          handIds.len >= playCount,
          $handIds.len & " of " & $playCount & " " & playTemplate)
    if handIds.len >= playCount:
      var payload = ""
      var k = 0
      while k < playCount:
        if payload.len > 0: payload.add ","
        payload.add "{\"id\":\"" & handIds[k] & "\",\"count\":1}"
        inc k
      let handed = call("/client/game/profile/items/moving",
        "{\"data\":[{\"Action\":\"QuestHandover\",\"qid\":\"" & playQuest &
        "\",\"conditionId\":\"" & playCondition & "\",\"items\":[" & payload &
        "]}],\"tm\":2}")
      check("handing them over is accepted", handed.ok, handed.body)
      listR = call("/client/game/profile/list", "")
      profAt = profileOf(listR.body, uid)
      let counter = memberValue(listR.body,
        memberValue(listR.body, profAt, "TaskConditionCounters"), playCondition)
      check("and the condition is credited by what the profile held",
            intField(listR.body, counter, "value") == playCount,
            "counter is " & $intField(listR.body, counter, "value") &
            ", not " & $playCount)
      check("and it is the quest's own condition that was credited",
            textField(listR.body, counter, "sourceId") == playQuest,
            slice(listR.body, counter))
      let done = call("/client/game/profile/items/moving",
        "{\"data\":[{\"Action\":\"QuestComplete\",\"qid\":\"" & playQuest &
        "\"}],\"tm\":2}")
      # A real quest has conditions this session cannot meet: kills with a
      # named weapon, a raid survived on a particular map, a level. So either
      # answer is right -- and what is checked is that a refusal *names the
      # condition it refused on*, out of that quest's own condition ids. "No"
      # with no reason sends a player to a wiki, and `err:0` with nothing said
      # is a quest paid out for nothing.
      var condIds: seq[string] = @[]
      var qi = 0
      while qi < questKeys.len:
        if questKeys[qi] == playQuest:
          var ck: seq[string] = @[]
          var cv: seq[int] = @[]
          members(questsR.body,
                  memberValue(questsR.body, questVals[qi], "conditions"),
                  ck, cv)
          var cg = 0
          while cg < ck.len:
            for c in elements(questsR.body, cv[cg]):
              let cid = textField(questsR.body, c, "id")
              if cid.len > 0:
                condIds.add cid
            inc cg
        inc qi
      var named = false
      for cid in condIds:
        if done.contains(cid):
          named = true
      check("completing it either succeeds or refuses naming its own condition",
            done.ok and (not done.contains("cannot complete") or named),
            $condIds.len & " conditions, none named in: " & done.body)
      line "  quest " & playQuest & ": handed over " & $playCount & " of " &
           playTemplate

  # -- the inbox: read, pinned, removed -------------------------------------
  #
  # `/client/mail/dialog/{read,pin,unpin,remove}` were all four bound to the
  # stock null stub, and `dialogList` answered `"pinned": false` and `"new": 0`
  # whatever the mailbox held. Everything below asserts on the *next* inbox
  # rather than on the routes' own answers, which is the only thing a stub
  # cannot survive.
  if mailQuest.len > 0 and mailQuest != playQuest:
    discard call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"QuestAccept\",\"qid\":\"" & mailQuest &
      "\"}],\"tm\":2}")
  let inboxR = call("/client/mail/dialog/list", "")
  let inboxRows = elements(inboxR.body, dataAt(inboxR))
  var firstDialog = ""
  if inboxRows.len > 0:
    firstDialog = textField(inboxR.body, inboxRows[0], "_id")
  if firstDialog.len == 0:
    skip("marking a real dialog read, pinned and removed",
         "no quest in this database posts anything at the moment it is " &
         "accepted, so this session has no dialog to act on")
  else:
    let row0 = dialogRowOf(inboxR.body, inboxRows, firstDialog)
    let unread0 = intField(inboxR.body, row0, "new")
    check("mail this session delivered is unread on the inbox", unread0 >= 1,
          "\"new\" is " & $unread0 & " on a dialog nobody has read")
    discard call("/client/mail/dialog/read",
                 "{\"dialogs\":[\"" & firstDialog & "\"]}")
    let inbox1R = call("/client/mail/dialog/list", "")
    check("and reading it clears the unread count",
          unread0 >= 1 and
          intField(inbox1R.body,
                   dialogRowOf(inbox1R.body, elements(inbox1R.body, dataAt(inbox1R)), firstDialog), "new") == 0,
          "\"new\" went " & $unread0 & " -> " &
          $intField(inbox1R.body,
                    dialogRowOf(inbox1R.body, elements(inbox1R.body, dataAt(inbox1R)), firstDialog), "new"))
    discard call("/client/mail/dialog/pin",
                 "{\"dialogId\":\"" & firstDialog & "\"}")
    let inbox2R = call("/client/mail/dialog/list", "")
    check("pinning it is reported on the next inbox",
          flagField(inbox2R.body,
                    dialogRowOf(inbox2R.body, elements(inbox2R.body, dataAt(inbox2R)), firstDialog), "pinned") == 1,
          slice(inbox2R.body, dialogRowOf(inbox2R.body, elements(inbox2R.body, dataAt(inbox2R)), firstDialog)))
    discard call("/client/mail/dialog/unpin",
                 "{\"dialogId\":\"" & firstDialog & "\"}")
    let inbox3R = call("/client/mail/dialog/list", "")
    check("and unpinning it puts it back",
          flagField(inbox3R.body,
                    dialogRowOf(inbox3R.body, elements(inbox3R.body, dataAt(inbox3R)), firstDialog), "pinned") == 0,
          slice(inbox3R.body, dialogRowOf(inbox3R.body, elements(inbox3R.body, dataAt(inbox3R)), firstDialog)))
    let owed = call("/client/mail/dialog/getAllAttachments", "")
    let owedCount = elements(owed.body,
                             memberValue(owed.body, dataAt(owed),
                                         "messages")).len
    let dialogsBefore = elements(inbox3R.body, dataAt(inbox3R)).len
    discard call("/client/mail/dialog/remove",
                 "{\"dialogId\":\"" & firstDialog & "\"}")
    let inbox4R = call("/client/mail/dialog/list", "")
    check("removing it takes the row off the inbox",
          dialogRowOf(inbox4R.body, elements(inbox4R.body, dataAt(inbox4R)), firstDialog) < 0,
          "the removed dialog is still listed")
    check("and takes exactly that one row",
          elements(inbox4R.body, dataAt(inbox4R)).len == dialogsBefore - 1,
          $dialogsBefore & " dialogs became " &
          $elements(inbox4R.body, dataAt(inbox4R)).len)
    # And the property that makes the delete safe: a message still holding
    # uncollected items is the only place those items exist, so it survives the
    # removal and stays on the collect-all screen.
    let owed2 = call("/client/mail/dialog/getAllAttachments", "")
    check("and destroys nothing the player had not collected",
          elements(owed2.body,
                   memberValue(owed2.body, dataAt(owed2),
                               "messages")).len == owedCount,
          $owedCount & " uncollected messages became " &
          $elements(owed2.body,
                    memberValue(owed2.body, dataAt(owed2), "messages")).len)

  # -- a real quest's kills, credited from the raid's victim list -----------
  #
  # The fallback path in `questcond.killCredit`: the client did not report a
  # counter for this quest (it has never seen it), so the server derives the
  # count from `Stats.Eft.Victims` in the profile the raid hands back. Against a
  # real `templates.quests` this used to credit nothing at all, because the
  # condition carries neutral `distance` and `daytime` keys and their presence
  # was read as a qualifier.
  if killQuest.len == 0:
    skip("crediting a real quest's kills from a raid's victim list",
         "no quest in this database has an ungated kill counter whose only " &
         "qualifiers are the neutral `distance` and `daytime` members")
  elif mapKeys.len == 0:
    skip("crediting a real quest's kills from a raid's victim list",
         "the locations table lists no map to raid")
  else:
    let tookKill = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"QuestAccept\",\"qid\":\"" & killQuest &
      "\"}],\"tm\":2}")
    check("a real kill quest with no prerequisite can be accepted",
          tookKill.ok and not tookKill.contains("cannot accept"),
          tookKill.body)
    # The map the condition names, if it names one. It is sent as the raid's
    # `location` exactly as the condition spells it, because that is the string
    # the client sends and the string `killCredit` compares against.
    let killMap = (if killWhere.len > 0: killWhere else: mapKeys[0])
    let killOut = (if killExit.len > 0: killExit else: "Survived")
    discard call("/client/match/local/start",
                 "{\"location\":\"" & mapKeys[0] & "\"}")
    listR = call("/client/game/profile/list", "")
    profAt = profileOf(listR.body, uid)
    let doc3 = listR.body.substr(profAt, endOf(listR.body, profAt) - 1)
    # Three kills, at three ranges, on the side the discovered condition asks
    # for -- `AnyPmc` and `Savage` are both common and a fixed side would make
    # this check pass or fail on which quest the database happened to offer.
    let vSide = (if killSide == "AnyPmc": "Usec" else: "Savage")
    let vRole = (if killSide == "AnyPmc": "pmcUSEC" else: "assault")
    let vHead = "{\"Side\":\"" & vSide & "\",\"Role\":\"" & vRole & "\","
    let fought = withVictims(doc3,
      "[" & vHead &
      "\"BodyPart\":\"Head\",\"Distance\":18.5,\"Time\":\"11:02:44\"}," &
      vHead &
      "\"BodyPart\":\"Chest\",\"Distance\":143.0,\"Time\":\"11:05:01\"}," &
      vHead &
      "\"BodyPart\":\"LeftArm\",\"Distance\":7.25,\"Time\":\"11:07:30\"}]")
    check("the profile the client hands back can carry a victim list",
          fought.len > doc3.len,
          "the profile has no Stats.Eft.Victims to put them in")
    let ended2 = call("/client/match/local/end",
      "{\"location\":\"" & killMap &
      "\",\"results\":{\"result\":\"" & killOut & "\",\"profile\":" & fought & "}}")
    check("the raid carrying three kills is accepted", ended2.ok,
          why(ended2))
    listR = call("/client/game/profile/list", "")
    profAt = profileOf(listR.body, uid)
    let killCounter = memberValue(listR.body,
      memberValue(listR.body, profAt, "TaskConditionCounters"), killCondition)
    check("and the quest's kill counter is credited from the victim list",
          intField(listR.body, killCounter, "value") == 3,
          "counter " & killCondition & " is " &
          $intField(listR.body, killCounter, "value") & ", not 3")
    check("and it names the quest the condition belongs to",
          textField(listR.body, killCounter, "sourceId") == killQuest,
          slice(listR.body, killCounter))
    line "  quest " & killQuest & ": three " & vSide & " kills on " &
         killMap & " credited to " & killCondition & " (target " &
         $killTarget & ")"

  # -- Fence's karma, at the rate the same server hands the client ----------
  #
  # `bots.types.<role>.experience.standingForKill` is in a real database for all
  # 57 roles, and `emu/bots` has always read it -- to put it on a generated bot
  # as `Info.Settings.StandingForKill`. Nothing read it back off the raid, so
  # killing scavs as a scav was free.
  #
  # The check joins the two routes rather than naming a number. `/client/game/
  # bot/generate` says what one `assault` at `normal` is worth; a scav raid then
  # reports killing exactly one, and Fence's standing must come back as that
  # same figure, character for character. Neither side is a literal here, so an
  # import that changes BSG's numbers moves both and the check still holds --
  # and a server that reads the wrong difficulty column, or the wrong role, or
  # nothing at all, moves only one of them.
  #
  # The raid is a **death** on purpose. `fenceKarmaOnScavDeath` is 0, so the
  # kills are the only term and the answer is the bot's own number with nothing
  # added to it; a survived raid would carry the configured extract figure too
  # and the check would be about this server's setting instead of about BSG's
  # data. A dying scav also brings nothing home, so the raid body needs no
  # inventory at all.
  let fenceCfg = memberValue(globalsR.body,
    memberValue(globalsR.body, dataAt(globalsR), "config"), "FenceSettings")
  let fenceReal = textField(globalsR.body, fenceCfg, "FenceId")
  check("globals names which trader is the scav trader",
        fenceReal.len == 24 and contains(traderIds, fenceReal),
        "FenceSettings.FenceId is \"" & fenceReal &
        "\", which is not a trader in this database")

  let botOne = call("/client/game/bot/generate",
    "{\"conditions\":[{\"Role\":\"assault\",\"Limit\":1," &
    "\"Difficulty\":\"normal\"}]}")
  let botOnes = elements(botOne.body, dataAt(botOne))
  var botRate = ""
  if botOnes.len > 0:
    let botSettings = memberValue(botOne.body,
      memberValue(botOne.body, botOnes[0], "Info"), "Settings")
    botRate = slice(botOne.body,
                    memberValue(botOne.body, botSettings, "StandingForKill"))
  check("a generated scav carries the standing the database prices it at",
        botRate.len > 0 and botRate != "0" and botRate != "0.0",
        "StandingForKill on a generated assault is \"" & botRate & "\"")

  if fenceReal.len != 24 or botRate.len == 0:
    skip("a scav who kills a scav is charged Fence's own rate for it",
         "the database gives no Fence id or no standingForKill for `assault`")
  else:
    listR = call("/client/game/profile/list", "")
    profAt = profileOf(listR.body, uid)
    let fenceBefore = slice(listR.body,
      memberValue(listR.body,
        memberValue(listR.body,
          memberValue(listR.body, profAt, "TradersInfo"), fenceReal),
        "standing"))
    let realScav = textField(listR.body, profAt, "savage")
    check("the profile carries a scav to play", realScav.len == 24, realScav)
    discard call("/client/match/local/end",
      "{\"results\":{\"result\":\"Killed\",\"profile\":{\"_id\":\"" & realScav &
      "\",\"Stats\":{\"Eft\":{\"Victims\":[" &
      "{\"Side\":\"Savage\",\"Role\":\"assault\",\"BodyPart\":\"Head\"}]}}}}}")
    listR = call("/client/game/profile/list", "")
    profAt = profileOf(listR.body, uid)
    let fenceAfter = slice(listR.body,
      memberValue(listR.body,
        memberValue(listR.body,
          memberValue(listR.body, profAt, "TradersInfo"), fenceReal),
        "standing"))
    # Zero before is what makes the comparison exact: nothing in this session
    # gives Fence standing, but a quest reward in somebody else's database
    # could, and a check that reads a sum as a rate would be a check that lies
    # about which number it is testing.
    #
    # `(nothing)` is zero and is the ordinary case here. `TradersInfo` on the
    # profile the client hands back after a raid is the *client's* copy, and it
    # carries entries only for traders the run has touched -- `addStanding`
    # creates Fence's the moment there is standing to put in it. No entry is
    # therefore "no standing", which is what the comparison needs.
    if fenceBefore != "0" and fenceBefore != "0.0" and
       fenceBefore != "(nothing)":
      skip("a scav who kills a scav is charged Fence's own rate for it",
           "this session had already moved Fence's standing to " &
           fenceBefore & " before any scav raid, so the raid's own term " &
           "cannot be read off the total")
    else:
      check("a scav who kills a scav is charged Fence's own rate for it",
            fenceAfter == botRate,
            "Fence's standing is " & fenceAfter & " and the same server " &
            "prices an `assault` kill at " & botRate)
      line "  one assault kill: Fence " & fenceBefore & " -> " & fenceAfter &
           ", the rate the bot route published"

  # -- the voice route, on a voice this database actually has ---------------
  #
  # `/client/game/profile/voice/change` answered `{"status":"ok"}` and wrote
  # nothing, which is the one failure this server's whole design is against:
  # not a refusal the client swallows but a success the server invented. The
  # voice is discovered out of `/client/customization` -- whichever entry hangs
  # off the `Voice` node, is allowed to this profile's side, and is not the one
  # the profile already has -- so the check says nothing about which voices the
  # game ships and everything about whether the route writes.
  var voiceId = ""
  var voiceName = ""
  var voiceCount = 0
  listR = call("/client/game/profile/list", "")
  profAt = profileOf(listR.body, uid)
  let voiceNow = textField(listR.body,
                           memberValue(listR.body, profAt, "Info"), "Voice")
  var vk = 0
  while vk < customKeys.len:
    if parentNameIn(customR.body, customKeys, customVals,
                    customKeys[vk]) == "Voice":
      let vProps = memberValue(customR.body, customVals[vk], "_props")
      var forSide = false
      for s in elements(customR.body, memberValue(customR.body, vProps, "Side")):
        if textVal(customR.body, s) == "Usec":
          forSide = true
      let vName = textField(customR.body, vProps, "Name")
      if forSide and vName.len > 0:
        inc voiceCount
        if voiceId.len == 0 and vName != voiceNow:
          voiceId = customKeys[vk]
          voiceName = vName
    inc vk
  if voiceId.len == 0:
    skip("the voice route writes the voice it says it wrote",
         "this database has no second Usec voice to change to; " &
         $voiceCount & " were found")
  else:
    let voiceReply = call("/client/game/profile/voice/change",
                          "{\"voice\":\"" & voiceId & "\"}")
    check("the voice route answers", voiceReply.ok, why(voiceReply))
    listR = call("/client/game/profile/list", "")
    profAt = profileOf(listR.body, uid)
    check("the voice route writes the voice it says it wrote",
          textField(listR.body, memberValue(listR.body, profAt, "Info"),
                    "Voice") == voiceName,
          "Info.Voice is \"" &
          textField(listR.body, memberValue(listR.body, profAt, "Info"),
                    "Voice") & "\", not \"" & voiceName & "\"")
    # And `Info.Voice` holds the entry's `_name`, not its id. On real data
    # those differ often enough that a server writing the id would look right
    # against a fixture and wrong against every player's profile.
    check("and it wrote the entry's name rather than its id",
          voiceName != voiceId,
          "this database's voice " & voiceId & " is named the same as its " &
          "id, so this check cannot tell the two apart")
    line "  voice " & voiceId & " -> Info.Voice \"" & voiceName & "\", one of " &
         $voiceCount & " Usec voices"

  # -- a real craft, and what it takes to get the hideout to make it --------
  #
  # The half of this that real data has and no fixture does is the *area*. A
  # recipe is made in an area, an area's stage asks for materials, and against
  # an imported table those materials are bolts and screw nuts rather than
  # money. A server that refused an upgrade the profile could not pay for in
  # full was briefly a server whose hideout could never be started -- and the
  # fix for that is here, not there: a session that cannot afford a stage goes
  # and gets the materials, the way a player does.
  #
  # Two routes, in that order, and both discovered: a trader who sells it, then
  # the flea. What neither has is reported by template id and taken out of a
  # raid -- which is not a shortcut but the route the loot tables describe, and
  # it is checked against them before it is used.
  if craftId.len == 0:
    skip("running a real hideout craft",
         "no recipe in this database has inputs a trader sells at loyalty 1 " &
         "and gates this session can pass")
  else:
    var planTys: seq[int] = @[]
    var planLvs: seq[int] = @[]
    var wantTpls: seq[string] = @[]
    var wantNums: seq[int] = @[]
    var blocked = ""
    planArea(areasR.body, areaList, craftArea, craftLevel, 0, planTys, planLvs,
             wantTpls, wantNums, blocked)
    check("the area a real recipe is made in can be walked to a plan",
          blocked.len == 0 or planTys.len > 0,
          "area " & $craftArea & ": " & blocked)

    # What the plan costs, sorted into how it can be got. Nothing is bought
    # yet: this is the reading half, and it is what the run reports.
    var buyTpls: seq[string] = @[]
    var buyNums: seq[int] = @[]
    var fleaTpls: seq[string] = @[]
    var fleaNums: seq[int] = @[]
    var raidTpls: seq[string] = @[]
    var raidNums: seq[int] = @[]
    var stageMoney = 0
    var k = 0
    while k < wantTpls.len:
      let tpl = wantTpls[k]
      if tpl == Roubles:
        stageMoney = stageMoney + wantNums[k]
      elif findOffer(offers, tpl) >= 0:
        buyTpls.add tpl
        buyNums.add wantNums[k]
      else:
        # The flea, asked for this template by id. `handbookId` holding an item
        # id rather than a category is how the client asks "offers for this
        # thing", and it is the only way to look one up: the market is built as
        # a pool and searched, not queried per template.
        let listed = call("/client/ragfair/find",
          "{\"page\":0,\"limit\":10,\"sortType\":5,\"sortDirection\":0," &
          "\"handbookId\":\"" & tpl & "\"}")
        let rows2 = elements(listed.body,
                             memberValue(listed.body, dataAt(listed), "offers"))
        var found = ""
        var price = 0
        for row in rows2:
          if textField(listed.body, row, "_id").len == 0:
            continue
          var mine = false
          for it in elements(listed.body, memberValue(listed.body, row,
                                                      "items")):
            if textField(listed.body, it, "_tpl") == tpl:
              mine = true
          if not mine:
            continue
          found = textField(listed.body, row, "_id")
          price = intField(listed.body, row, "summaryCost")
          break
        if found.len > 0:
          fleaTpls.add tpl
          fleaNums.add wantNums[k]
          discard price
        else:
          raidTpls.add tpl
          raidNums.add wantNums[k]
      inc k

    var raidNames = ""
    var r2 = 0
    while r2 < raidTpls.len:
      if raidNames.len > 0: raidNames.add ", "
      raidNames.add $raidNums[r2] & " x " & raidTpls[r2]
      inc r2
    line "  area " & $craftArea & " to level " & $craftLevel & ": " &
         $planTys.len & " upgrade(s), " & $stageMoney & " roubles, " &
         $buyTpls.len & " material(s) a trader sells, " & $fleaTpls.len &
         " on the flea, " & $raidTpls.len & " in neither" &
         (if raidNames.len > 0: " (" & raidNames & ")" else: "")

    # What no shop has must at least be *findable*, and the locations table is
    # what says so. A template that is in no assort, on no flea page and in no
    # loot table is genuinely unreachable, and saying that precisely is the
    # point of this check -- it is a statement about the database's economy,
    # not about the server.
    var unreachable = ""
    var r3 = 0
    while r3 < raidTpls.len:
      if findAt(locR.body, "\"" & raidTpls[r3] & "\"", 0) < 0:
        if unreachable.len > 0: unreachable.add ", "
        unreachable.add raidTpls[r3]
      inc r3
    check("every stage material no trader and no flea offer has is in the loot tables",
          unreachable.len == 0,
          "nothing in this database can produce " & unreachable)

    # -- acquiring it --------------------------------------------------------
    var acquired = true
    var b = 0
    while b < buyTpls.len:
      let idx = findOffer(offers, buyTpls[b])
      var got = 0
      while got < buyNums[b] and idx >= 0:
        discard call("/client/game/profile/items/moving",
          "{\"data\":[{\"Action\":\"TradingConfirm\"," &
          "\"type\":\"buy_from_trader\",\"tid\":\"" & offers[idx].trader &
          "\",\"item_id\":\"" & offers[idx].root &
          "\",\"count\":1,\"scheme_id\":0,\"scheme_items\":[{\"id\":\"" &
          moneyId & "\",\"count\":" & $offers[idx].price & "}]}],\"tm\":2}")
        inc got
      listR = call("/client/game/profile/list", "")
      profAt = profileOf(listR.body, uid)
      if unitsOf(listR.body, profAt, buyTpls[b]) < buyNums[b]:
        acquired = false
      inc b
    if buyTpls.len > 0:
      check("the stage materials a trader stocks can be bought outright",
            acquired, "not everything a trader sells arrived")
    else:
      skip("buying a stage material from a trader",
           "no trader in this database sells anything area " & $craftArea &
           " asks for")

    var fleaGot = true
    var f = 0
    while f < fleaTpls.len:
      # Bounded by what the stash actually holds rather than by how many times
      # this asked: an offer sold in one piece hands over its whole stack, so
      # counting purchases buys too much, and one that is not stackable arrives
      # as its own item, so counting item documents buys too little.
      var got = 0
      while got < fleaNums[f] and
            unitsOf(listR.body, profAt, fleaTpls[f]) < fleaNums[f]:
        let listed = call("/client/ragfair/find",
          "{\"page\":0,\"limit\":10,\"sortType\":5,\"sortDirection\":0," &
          "\"handbookId\":\"" & fleaTpls[f] & "\"}")
        var offerId = ""
        var cost = 0
        for row in elements(listed.body,
                            memberValue(listed.body, dataAt(listed), "offers")):
          var mine = false
          for it in elements(listed.body,
                             memberValue(listed.body, row, "items")):
            if textField(listed.body, it, "_tpl") == fleaTpls[f]:
              mine = true
          if not mine:
            continue
          offerId = textField(listed.body, row, "_id")
          cost = intField(listed.body, row, "summaryCost")
          break
        if offerId.len == 0:
          break
        discard call("/client/game/profile/items/moving",
          "{\"data\":[{\"Action\":\"RagFairBuyOffer\",\"offers\":[{" &
          "\"id\":\"" & offerId & "\",\"count\":1,\"items\":[{\"id\":\"" &
          moneyId & "\",\"count\":" & $cost & "}]}]}],\"tm\":2}")
        inc got
        listR = call("/client/game/profile/list", "")
        profAt = profileOf(listR.body, uid)
      if unitsOf(listR.body, profAt, fleaTpls[f]) < fleaNums[f]:
        fleaGot = false
      inc f
    if fleaTpls.len > 0:
      check("and the ones only the flea has can be bought there",
            fleaGot, "a flea purchase did not arrive")
    else:
      skip("buying a stage material on the flea",
           "everything area " & $craftArea &
           " asks for is either on a trader screen or in neither")

    # And what neither sells comes out of a raid, which is the route the loot
    # tables describe and the only one this server has for an item nobody
    # stocks. `/client/match/local/end` takes the profile the client played
    # with -- that is SPT's model and this emulator's -- so this is the client
    # doing what a client does, and it is checked on the way back in.
    #
    # When a shop has everything -- which is what the flea supplying the
    # materials it prices *means*, and it is the state this database is in now
    # that the market's cap is shared out -- the raid still runs, carrying one
    # of them. The route is the thing being checked and it must not stop being
    # checked the day the economy stops needing it; the extra copy is left in
    # the stash and the stage's own arithmetic below is a subtraction, so it
    # costs that check nothing.
    var carryTpls = raidTpls
    var carryNums = raidNums
    if carryTpls.len == 0:
      var w = 0
      while w < wantTpls.len:
        if wantTpls[w] != Roubles:
          carryTpls.add wantTpls[w]
          carryNums.add 1
          break
        inc w
    if carryTpls.len == 0:
      skip("bringing a stage material home from a raid",
           "area " & $craftArea & " asks for no materials at all")
    elif mapKeys.len == 0:
      skip("bringing a stage material home from a raid",
           "the locations table lists no map to raid")
    else:
      let map1 = mapKeys[0]
      discard call("/client/raid/configuration",
                   "{\"location\":\"" & map1 & "\",\"timeVariant\":\"CURR\"," &
                   "\"raidMode\":\"Local\",\"side\":\"Pmc\"}")
      discard call("/client/match/local/start",
                   "{\"location\":\"" & map1 & "\"}")
      listR = call("/client/game/profile/list", "")
      profAt = profileOf(listR.body, uid)
      # What the stash holds of each of them before the raid, so that what the
      # raid added is a subtraction rather than "there is some of it there" --
      # which is true already for anything that was bought above.
      var carryBefore: seq[int] = @[]
      var n0 = 0
      while n0 < carryTpls.len:
        carryBefore.add unitsOf(listR.body, profAt, carryTpls[n0])
        inc n0
      var picked = ""
      var n2 = 0
      while n2 < carryTpls.len:
        if picked.len > 0: picked.add ","
        picked.add "{\"_id\":\"" & hexId(4096 + n2 * 977) & "\",\"_tpl\":\"" &
                   carryTpls[n2] & "\",\"parentId\":\"" & stashId &
                   "\",\"slotId\":\"hideout\",\"location\":{\"x\":" & $n2 &
                   ",\"y\":39,\"r\":\"Horizontal\"},\"upd\":{" &
                   "\"StackObjectsCount\":" & $carryNums[n2] & "}}"
        inc n2
      let doc2 = listR.body.substr(profAt, endOf(listR.body, profAt) - 1)
      let carried = withItems(doc2, picked)
      check("a played profile can be handed back carrying what was found",
            carried.len > doc2.len, "the profile has no Inventory.items")
      let home = call("/client/match/local/end",
                      "{\"results\":{\"result\":\"Survived\",\"profile\":" & carried & "}}")
      listR = call("/client/game/profile/list", "")
      profAt = profileOf(listR.body, uid)
      var brought = true
      var n3 = 0
      while n3 < carryTpls.len:
        if unitsOf(listR.body, profAt, carryTpls[n3]) - carryBefore[n3] !=
           carryNums[n3]:
          brought = false
        inc n3
      check("and the raid brings home what was found in it",
            home.ok and brought, home.body)
      if raidNames.len > 0:
        line "  raided " & map1 & " for " & raidNames &
             ": no trader or flea offer in this database has either"
      else:
        line "  raided " & map1 & " for 1 x " & carryTpls[0] &
             ": every material this stage asks for is also on sale"

    # -- and now the upgrades, in the order the plan put them ---------------
    #
    # What the stash holds of each material first, so that what the upgrades
    # take can be subtracted rather than guessed at.
    listR = call("/client/game/profile/list", "")
    profAt = profileOf(listR.body, uid)
    var beforeUnits: seq[int] = @[]
    var m1 = 0
    while m1 < wantTpls.len:
      beforeUnits.add unitsOf(listR.body, profAt, wantTpls[m1])
      inc m1
    var built = true
    var u = 0
    var refusal = ""
    while u < planTys.len:
      let began = call("/client/game/profile/items/moving",
        "{\"data\":[{\"Action\":\"HideoutUpgrade\",\"areaType\":" &
        $planTys[u] & "}],\"tm\":2}")
      if began.contains("not enough") or began.contains("that needs"):
        built = false
        if refusal.len == 0:
          refusal = began.body.substr(0, (if began.body.len > 200: 200
                                          else: began.body.len) - 1)
      discard call("/client/game/profile/items/moving",
        "{\"data\":[{\"Action\":\"HideoutUpgradeComplete\",\"areaType\":" &
        $planTys[u] & "}],\"tm\":2}")
      inc u
    listR = call("/client/game/profile/list", "")
    profAt = profileOf(listR.body, uid)
    var reached = 0
    for a in elements(listR.body,
                      memberValue(listR.body,
                                  memberValue(listR.body, profAt, "Hideout"),
                                  "Areas")):
      if intField(listR.body, a, "type") == craftArea:
        reached = intField(listR.body, a, "level")
    check("the area a real recipe is made in is built once its materials are in the stash",
          built and reached >= craftLevel,
          "area " & $craftArea & " is at level " & $reached & " of " &
          $craftLevel & "; " & (if refusal.len > 0: refusal else: blocked))

    # And the materials were taken rather than checked for: the whole hideout
    # used to be free, and a stage that verifies and does not consume is the
    # same bug wearing a refusal.
    #
    # By the *drop*, over every material the plan named, rather than by "is
    # there any of it left". Where it came from is not the point and it used to
    # decide the check: this only looked at what a raid had brought, so the day
    # the flea started supplying these materials again the check stopped running
    # at all. A purchase can also deliver more than was asked for -- an offer
    # sold in one piece hands over its whole stack -- so what is left over is
    # not zero and is not meant to be. What must be exact is how much went.
    var wrongTake = ""
    var m2 = 0
    while m2 < wantTpls.len:
      if wantTpls[m2] != Roubles:
        let went = beforeUnits[m2] - unitsOf(listR.body, profAt, wantTpls[m2])
        if went != wantNums[m2]:
          if wrongTake.len > 0: wrongTake.add ", "
          wrongTake.add wantTpls[m2] & ": " & $went & " taken, " &
                        $wantNums[m2] & " asked for"
      inc m2
    if planTys.len > 0 and wantTpls.len > 0:
      check("and the stage took exactly the materials it asked for",
            built and wrongTake.len == 0, wrongTake)
    else:
      skip("a stage taking its materials", "this stage asks for none")

    var haveAll = true
    var k2 = 0
    while k2 < craftTemplates.len:
      let idx = findOffer(offers, craftTemplates[k2])
      var got = 0
      while got < craftCounts[k2] and idx >= 0:
        discard call("/client/game/profile/items/moving",
          "{\"data\":[{\"Action\":\"TradingConfirm\"," &
          "\"type\":\"buy_from_trader\",\"tid\":\"" & offers[idx].trader &
          "\",\"item_id\":\"" & offers[idx].root &
          "\",\"count\":1,\"scheme_id\":0,\"scheme_items\":[{\"id\":\"" &
          moneyId & "\",\"count\":" & $offers[idx].price & "}]}],\"tm\":2}")
        inc got
      listR = call("/client/game/profile/list", "")
      profAt = profileOf(listR.body, uid)
      if heldOf(listR.body, profAt, craftTemplates[k2]).len < craftCounts[k2]:
        haveAll = false
      inc k2
    check("its ingredients can be bought from the traders who stock them",
          haveAll, "not everything arrived")

    let before = moneyIn(listR.body, profAt)
    let start = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutSingleProductionStart\"," &
      "\"recipeId\":\"" & craftId & "\"}],\"tm\":2}")
    check("a real craft starts once its requirements are met",
          start.ok and not start.contains("not enough") and
          not start.contains("no such recipe"), start.body)
    listR = call("/client/game/profile/list", "")
    profAt = profileOf(listR.body, uid)
    let record = memberValue(listR.body,
      memberValue(listR.body,
                  memberValue(listR.body, profAt, "Hideout"), "Production"),
      craftId)
    check("and the profile records it with the clock the recipe named",
          record >= 0 and intField(listR.body, record, "StartTimestamp") > 0,
          slice(listR.body, record))
    check("and it consumed the ingredients rather than the money",
          moneyIn(listR.body, profAt) == before,
          $before & " became " & $moneyIn(listR.body, profAt))
    var consumed = true
    var c = 0
    while c < craftTemplates.len:
      if heldOf(listR.body, profAt, craftTemplates[c]).len >= craftCounts[c]:
        consumed = false
      inc c
    check("the ingredients left the stash", consumed,
          "a craft ingredient is still there")
    let early = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutTakeProduction\",\"recipeId\":\"" &
      craftId & "\"}],\"tm\":2}")
    check("and collecting it before the real production time has passed is refused",
          early.contains("not finished"), early.body)
    line "  craft " & craftId & " in area " & $craftArea & " (level " &
         $craftLevel & "), " & $craftTemplates.len & " ingredients, " &
         $craftCost & " roubles of stock"

  # -- what an area's own requirements are for ------------------------------
  #
  # Only real data has these: every stage of every area in the imported hideout
  # names materials, a trader loyalty level, other areas and a construction
  # time. The fixture's areas name none of them, so nothing until now has ever
  # asked whether they are enforced.
  var gatedArea = -1
  var gatedLevel = 0
  var gatedTime = 0
  var gatedWants = ""
  for a in areaList:
    let ty = intField(areasR.body, a, "type")
    if ty == craftArea or ty == low(int):
      continue
    let stages = memberValue(areasR.body, a, "stages")
    var sk: seq[string] = @[]
    var sv: seq[int] = @[]
    members(areasR.body, stages, sk, sv)
    var s = 0
    while s < sk.len:
      if sk[s] == "1":
        let time = intField(areasR.body, sv[s], "constructionTime")
        var wants = ""
        for req in elements(areasR.body,
                            memberValue(areasR.body, sv[s], "requirements")):
          if textField(areasR.body, req, "type") == "Item":
            wants = textField(areasR.body, req, "templateId")
        # Preferring one that also takes time to build: the two halves of a
        # requirement -- what it costs and how long it takes -- are enforced by
        # different code, and an area with both exercises both.
        if wants.len > 0 and (gatedArea < 0 or (gatedTime <= 0 and time > 0)):
          gatedArea = ty
          gatedLevel = 1
          gatedTime = time
          gatedWants = wants
      inc s
  if gatedArea < 0:
    skip("a hideout upgrade is gated by its own requirements",
         "no area in this database asks for materials")
  else:
    let held = heldOf(listR.body, profAt, gatedWants)
    let beganUpgrade = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutUpgrade\",\"areaType\":" & $gatedArea &
      "}],\"tm\":2}")
    let finishedUpgrade = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutUpgradeComplete\",\"areaType\":" &
      $gatedArea & "}],\"tm\":2}")
    listR = call("/client/game/profile/list", "")
    profAt = profileOf(listR.body, uid)
    var level = 0
    for a in elements(listR.body,
                      memberValue(listR.body,
                                  memberValue(listR.body, profAt, "Hideout"),
                                  "Areas")):
      if intField(listR.body, a, "type") == gatedArea:
        level = intField(listR.body, a, "level")
    check("an upgrade whose materials the player does not have is refused",
          held.len > 0 or level == 0,
          "area " & $gatedArea & " asks for " & gatedWants &
          ", the stash has none of it, and the area reached level " & $level &
          "; HideoutUpgrade answered " & beganUpgrade.body.substr(0,
            (if beganUpgrade.body.len > 160: 160 else: beganUpgrade.body.len) - 1) &
          " and HideoutUpgradeComplete answered " &
          finishedUpgrade.body.substr(0,
            (if finishedUpgrade.body.len > 160: 160
             else: finishedUpgrade.body.len) - 1))
    # And it says what it refused on. "No" with nothing named is a player at a
    # wiki, and it is also indistinguishable from a server that refused for a
    # reason it made up: this asks the refusal to quote a template id or an
    # area level out of the stage's own requirement list.
    if held.len == 0:
      check("and the refusal names what is missing",
            beganUpgrade.contains("not enough") or
            beganUpgrade.contains("that needs") or
            beganUpgrade.contains("has no level"),
            beganUpgrade.body.substr(0, (if beganUpgrade.body.len > 200: 200
                                         else: beganUpgrade.body.len) - 1))
      check("and no area was created by a refused upgrade",
            not listR.contains("\"type\":" & $gatedArea & ",\"level\":1"),
            "area " & $gatedArea & " is at level 1 after a refusal")
    else:
      skip("a refused upgrade naming what is missing",
           "the stash happens to hold what area " & $gatedArea & " asks for")
    if gatedTime > 0:
      check("and one whose construction time has not passed is not complete yet",
            level == 0,
            "level 1 of area " & $gatedArea & " takes " & $gatedTime &
            " seconds to build and was granted in the same request")
    else:
      skip("an upgrade waits out its construction time",
           "level 1 of area " & $gatedArea & " is instant in this database")

  # -- a raid on a real map -------------------------------------------------
  var raidMap = ""
  if mapKeys.len > 0:
    raidMap = mapKeys[0]
    let cfg = call("/client/raid/configuration",
                   "{\"location\":\"" & raidMap & "\",\"timeVariant\":\"CURR\"," &
                   "\"raidMode\":\"Local\",\"side\":\"Pmc\"}")
    check("a raid on a real map is configured", cfg.ok and
          cfg.contains("\"err\":0"), cfg.body)
    let weather = call("/client/weather", "")
    check("the weather answers for it", weather.contains("season"),
          weather.body)
    let started = call("/client/match/local/start",
                       "{\"location\":\"" & raidMap & "\"}")
    check("and the match starts", started.contains("serverId"), started.body)

    # Out of it with a changed profile, handed back the way the client hands it
    # back: the server's own document, one number different.
    listR = call("/client/game/profile/list", "")
    profAt = profileOf(listR.body, uid)
    let doc = listR.body.substr(profAt, endOf(listR.body, profAt) - 1)
    let played = withNumber(doc, "Experience", 4321)
    check("the played profile could be rebuilt", played.len > 1000,
          $played.len & " bytes")
    let endBegan = micros()
    let ended = call("/client/match/local/end",
                     "{\"results\":{\"result\":\"Survived\",\"profile\":" & played & "}}")
    let endUs = micros() - endBegan
    check("the raid result is accepted", ended.ok and
          ended.contains("\"err\":0"), ended.body)
    listR = call("/client/game/profile/list", "")
    profAt = profileOf(listR.body, uid)
    check("and the experience the raid claimed stuck",
          intField(listR.body,
                   memberValue(listR.body, profAt, "Info"), "Experience") == 4321,
          "Experience is " &
          $intField(listR.body, memberValue(listR.body, profAt, "Info"),
                    "Experience"))
    line "  raided " & raidMap & ", handed back " & kib(played.len) &
         " of profile in " & $(endUs div 1000'i64) & " ms"

  # -- and across a restart, four times ------------------------------------
  #
  # Everything above happens inside one server process, which is the one thing a
  # play session never is. What is asserted here is not that the profile
  # survives -- `emutest` proves that -- but that the ids a *later* server hands
  # out are not ids an earlier one already used. A generator seeded from
  # something that resets when the process does will, over a store that is
  # already full, write a second item carrying the stash's id; the client draws
  # the inventory by walking down from the stash, and an inventory whose root is
  # also a rifle is not one it can draw.
  #
  # Restarted several times, and the number of restarts is reported, for the
  # reason `storecrash` reports how many unprotected writes it managed to tear:
  # each restart is one sample of the generator, and "no reuse" only means
  # something alongside how many samples were taken. An id is checked two ways
  # -- against every id already in the profile, and against the *run marker*
  # every id issued before it carries, which is the half that catches a counter
  # rewound onto ids that are in the store but not in this profile.
  # =========================================================================
  heading "Healing at a trader, on the real price table"
  # =========================================================================
  # `emutest` prices a treatment against three numbers it wrote into a fixture.
  # This prices one against `globals.config.Health` as the game ships it, and
  # the whole point is that the expected figure is *computed from the answer*
  # rather than written down: whichever trader this database says heals, at
  # whatever coefficient its loyalty rows carry, for whatever the effect the
  # table happens to price costs.
  let cfgAt = memberValue(globalsR.body, dataAt(globalsR), "config")
  let healthAt = memberValue(globalsR.body, cfgAt, "Health")
  let priceAt = memberValue(globalsR.body, healthAt, "HealPrice")
  let pointPrice = intVal(globalsR.body,
                          memberValue(globalsR.body, priceAt,
                                      "HealthPointPrice"))
  check("the database prices a hit point",
        healthAt >= 0 and priceAt >= 0 and pointPrice != low(int) and
        pointPrice > 0,
        "globals.config.Health.HealPrice.HealthPointPrice is " &
        slice(globalsR.body, memberValue(globalsR.body, priceAt,
                                         "HealthPointPrice")))

  # Which effects a trader treats is not a list anybody wrote down: it is
  # exactly the effects the table gives a `RemovePrice`, and the ones it does
  # not are the ones a treatment must refuse by name.
  var effKeys: seq[string] = @[]
  var effVals: seq[int] = @[]
  members(globalsR.body, memberValue(globalsR.body, healthAt, "Effects"),
          effKeys, effVals)
  var pricedEffect = ""
  var pricedEffectCost = 0
  var unpricedEffect = ""
  var pricedEffects = 0
  var badEffectPrice = ""
  var e2 = 0
  while e2 < effKeys.len:
    let rp = memberValue(globalsR.body, effVals[e2], "RemovePrice")
    if rp < 0:
      if unpricedEffect.len == 0:
        unpricedEffect = effKeys[e2]
    else:
      let v = intVal(globalsR.body, rp)
      if v == low(int) or v < 0:
        if badEffectPrice.len == 0:
          badEffectPrice = effKeys[e2] & " = " & slice(globalsR.body, rp)
      else:
        inc pricedEffects
        if pricedEffect.len == 0:
          pricedEffect = effKeys[e2]
          pricedEffectCost = v
    inc e2
  check("every priced effect names a price a treatment can add up",
        badEffectPrice.len == 0, badEffectPrice)
  check("the table both prices some effects and leaves others unpriced",
        pricedEffects > 0 and unpricedEffect.len > 0,
        $pricedEffects & " priced of " & $effKeys.len & " effects, " &
        (if unpricedEffect.len > 0: "e.g. " & unpricedEffect & " unpriced"
         else: "all of them priced"))

  # The trader that heals, and one that does not name a coefficient at all --
  # both discovered, because which trader is Therapist is exactly the kind of
  # identity this file is not allowed to know.
  var healTrader = ""
  var healCoef = 0
  var flatTrader = ""
  var healRows = 0
  for tid in traders:
    let one = call("/client/trading/api/getTrader/" & tid, "")
    let levels = elements(one.body,
                          memberValue(one.body, dataAt(one), "loyaltyLevels"))
    if levels.len == 0:
      continue
    let c = healCoefficient(one.body, levels[0])
    if c > 0:
      inc healRows
      if healTrader.len == 0:
        healTrader = tid
        healCoef = c
    elif flatTrader.len == 0:
      flatTrader = tid
  line "  hit point " & $pointPrice & ", " & $pricedEffects & " of " &
       $effKeys.len & " effects priced, " & $healRows &
       " trader(s) name a heal coefficient at loyalty 1"

  # -- and now a treatment, on that table ----------------------------------
  listR = call("/client/game/profile/list", "")
  profAt = profileOf(listR.body, uid)
  var hurtPart = ""
  var hurtMax = 0
  block:
    var pKeys: seq[string] = @[]
    var pVals: seq[int] = @[]
    members(listR.body,
            memberValue(listR.body,
                        memberValue(listR.body, profAt, "Health"),
                        "BodyParts"), pKeys, pVals)
    var i2 = 0
    while i2 < pKeys.len:
      let m = intField(listR.body,
                       memberValue(listR.body, pVals[i2], "Health"), "Maximum")
      if m != low(int) and m >= 20 and hurtPart.len == 0:
        hurtPart = pKeys[i2]
        hurtMax = m
      inc i2
  check("the profile has a body part with room to be hurt in",
        hurtPart.len > 0 and hurtMax >= 20, hurtPart & " max " & $hurtMax)

  if healTrader.len == 0 or hurtPart.len == 0 or pointPrice <= 0:
    skip("a treatment priced off the real table",
         "no trader in this database names a heal coefficient at loyalty 1")
    skip("an unpriced effect refused by name", "the same")
    skip("a priced effect charged on top of the points", "the same")
    skip("a coefficient of zero charged at full price", "the same")
  else:
    # Five points and two effects: one the table prices and one it does not.
    var doc2 = listR.body.substr(profAt, endOf(listR.body, profAt) - 1)
    doc2 = withPartHealth(doc2, hurtPart, hurtMax - 5)
    var effects = "{\"" & pricedEffect & "\":{\"Time\":-1}"
    if unpricedEffect.len > 0:
      effects.add ",\"" & unpricedEffect & "\":{\"Time\":-1}"
    effects.add "}"
    doc2 = withPartEffects(doc2, hurtPart, effects)
    check("a played profile can be handed back hurt and with effects on it",
          doc2.len > 1000 and findAt(doc2, pricedEffect, 0) > 0,
          $doc2.len & " bytes")
    discard call("/client/match/local/end",
                 "{\"results\":{\"result\":\"Survived\",\"profile\":" & doc2 & "}}")
    listR = call("/client/game/profile/list", "")
    profAt = profileOf(listR.body, uid)
    var purse = moneyIn(listR.body, profAt)

    if unpricedEffect.len == 0:
      skip("an unpriced effect refused by name",
           "every effect in this database's table carries a RemovePrice")
    else:
      let refused = call("/client/game/profile/items/moving",
        "{\"data\":[{\"Action\":\"RestoreHealth\",\"tid\":\"" & healTrader &
        "\",\"difference\":{\"BodyParts\":{\"" & hurtPart &
        "\":{\"Health\":5,\"Effects\":[\"" & unpricedEffect &
        "\"]}}}}],\"tm\":2}")
      listR = call("/client/game/profile/list", "")
      profAt = profileOf(listR.body, uid)
      check("an effect this database does not price is refused, by its own name",
            refused.contains("does not treat " & unpricedEffect) and
            moneyIn(listR.body, profAt) == purse,
            refused.body.substr(0, (if refused.body.len > 240: 240
                                    else: refused.body.len) - 1))

    # The one the table prices, together with the five points -- and the price
    # is the table's own arithmetic at the trader's own coefficient, worked out
    # here from the numbers the server just handed over.
    let want = atCoefficient(5 * pointPrice + pricedEffectCost, healCoef)
    let treated = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"RestoreHealth\",\"tid\":\"" & healTrader &
      "\",\"difference\":{\"BodyParts\":{\"" & hurtPart &
      "\":{\"Health\":9999,\"Effects\":[\"" & pricedEffect &
      "\"]}}}}],\"tm\":2}")
    listR = call("/client/game/profile/list", "")
    profAt = profileOf(listR.body, uid)
    let took = purse - moneyIn(listR.body, profAt)
    let partAt2 = memberValue(listR.body,
                    memberValue(listR.body,
                      memberValue(listR.body,
                        memberValue(listR.body, profAt, "Health"),
                        "BodyParts"), hurtPart), "Health")
    check("a priced effect is charged on top of the points, at the table's own figures",
          treated.ok and took == want and
          intField(listR.body, partAt2, "Current") == hurtMax,
          "the treatment took " & $took & " roubles against " & $want &
          " (5 x " & $pointPrice & " + " & $pricedEffectCost & " at " &
          $healCoef & "%), and left the part at " &
          $intField(listR.body, partAt2, "Current") & " of " & $hurtMax)
    check("and the effect it was charged for is off the profile",
          findAt(slice(listR.body,
                       memberValue(listR.body,
                         memberValue(listR.body,
                           memberValue(listR.body, profAt, "Health"),
                           "BodyParts"), hurtPart)), pricedEffect, 0) < 0,
          slice(listR.body,
                memberValue(listR.body,
                  memberValue(listR.body,
                    memberValue(listR.body, profAt, "Health"),
                    "BodyParts"), hurtPart)))
    line "  treated " & hurtPart & " at " & healTrader & ": 5 points and " &
         pricedEffect & " for " & $took & " roubles at " & $healCoef & "%"

    # A trader whose loyalty row carries no coefficient, or carries a literal
    # zero -- which every trader but the one that heals does, in live data. Zero
    # means "not named", not "free", and a server that multiplied by it would
    # give the whole system away.
    if flatTrader.len == 0:
      skip("a coefficient of zero charged at full price",
           "every trader in this database names a heal coefficient")
    else:
      listR = call("/client/game/profile/list", "")
      profAt = profileOf(listR.body, uid)
      var doc3 = listR.body.substr(profAt, endOf(listR.body, profAt) - 1)
      doc3 = withPartHealth(doc3, hurtPart, hurtMax - 7)
      discard call("/client/match/local/end",
                   "{\"results\":{\"result\":\"Survived\",\"profile\":" & doc3 & "}}")
      listR = call("/client/game/profile/list", "")
      profAt = profileOf(listR.body, uid)
      let before2 = moneyIn(listR.body, profAt)
      let flat = call("/client/game/profile/items/moving",
        "{\"data\":[{\"Action\":\"RestoreHealth\",\"tid\":\"" & flatTrader &
        "\",\"difference\":{\"BodyParts\":{\"" & hurtPart &
        "\":{\"Health\":9999}}}}],\"tm\":2}")
      listR = call("/client/game/profile/list", "")
      profAt = profileOf(listR.body, uid)
      let took2 = before2 - moneyIn(listR.body, profAt)
      check("a trader with no heal coefficient charges full price rather than nothing",
            flat.ok and took2 == 7 * pointPrice and took2 > 0,
            "the treatment took " & $took2 & " roubles against " &
            $(7 * pointPrice))

  let noPart = call("/client/game/profile/items/moving",
    "{\"data\":[{\"Action\":\"RestoreHealth\",\"tid\":\"" &
    (if healTrader.len > 0: healTrader
     else: (if traders.len > 0: traders[0] else: "x")) &
    "\",\"difference\":{\"BodyParts\":{\"Wing\":{\"Health\":10}}}}],\"tm\":2}")
  check("a body part no real profile has is refused",
        noPart.contains("not a body part"),
        noPart.body.substr(0, (if noPart.body.len > 200: 200
                               else: noPart.body.len) - 1))

  # =========================================================================
  heading "The scav case, against the rarity pools"
  # =========================================================================
  # A scav recipe names no `endProduct`: it names a *count per rarity*, and the
  # pool behind each rarity is a join the server makes at run time between
  # `_props.RarityPvE`, the handbook's prices and `_props.QuestItem`. Only real
  # data can say whether that join has anything in it -- a fixture's three
  # rarity tags are three rows somebody wrote to make a test pass.
  let scavAt = memberValue(recipesR.body, dataAt(recipesR), "scavRecipes")
  let scavList = elements(recipesR.body, scavAt)
  check("the recipe table carries scav case recipes beside the crafts",
        scavAt >= 0 and scavList.len > 0,
        (if scavAt < 0: "there is no scavRecipes member"
         else: $scavList.len & " scav recipes"))

  let Rarities = @["Common", "Rare", "Superrare"]
  var scavIds = initHashSet[string]()
  var scavDupes = 0
  var scavNoId = 0
  var scavBadBand = ""
  var scavStrangeRarity = ""
  var scavEmpty = 0
  var scavBadTpl = ""
  var wantedRarity = @[false, false, false]
  for r in scavList:
    let id = textField(recipesR.body, r, "_id")
    if id.len == 0:
      inc scavNoId
    elif contains(scavIds, id):
      inc scavDupes
    else:
      incl(scavIds, id)
    var any = false
    var eKeys: seq[string] = @[]
    var eVals: seq[int] = @[]
    members(recipesR.body, memberValue(recipesR.body, r, "endProducts"),
            eKeys, eVals)
    var b = 0
    while b < eKeys.len:
      var known = -1
      var q = 0
      while q < 3:
        if eKeys[b] == Rarities[q]:
          known = q
        inc q
      if known < 0:
        if scavStrangeRarity.len == 0:
          scavStrangeRarity = id & " pays in " & eKeys[b]
      else:
        let lo = intField(recipesR.body, eVals[b], "min")
        let hi = intField(recipesR.body, eVals[b], "max")
        if lo == low(int) or hi == low(int) or lo < 0 or hi < lo:
          if scavBadBand.len == 0:
            scavBadBand = id & " " & eKeys[b] & " " &
                          slice(recipesR.body, eVals[b])
        elif hi > 0:
          any = true
          wantedRarity[known] = true
      inc b
    if not any:
      inc scavEmpty
    for req in elements(recipesR.body,
                        memberValue(recipesR.body, r, "requirements")):
      let tpl = textField(recipesR.body, req, "templateId")
      if tpl.len > 0 and not contains(templateIds, tpl):
        if scavBadTpl.len == 0:
          scavBadTpl = id & " asks for " & tpl
  check("every scav recipe has an id of its own", scavNoId == 0 and
        scavDupes == 0, $scavNoId & " with no id, " & $scavDupes & " repeated")
  check("every scav recipe pays in rarities the item table uses",
        scavStrangeRarity.len == 0, scavStrangeRarity)
  check("every band is a min and a max the roll can honour",
        scavBadBand.len == 0, scavBadBand)
  check("every scav recipe's entry fee names a real template",
        scavBadTpl.len == 0, scavBadTpl)
  check("and at least one of them pays out at all", scavEmpty < scavList.len,
        $scavEmpty & " of " & $scavList.len & " produce nothing")

  # The pools, built here exactly as `emu/production` builds them, so that the
  # assertion is "the database can answer what its own recipes ask for" rather
  # than "the server did not fall over".
  var poolSize = @[0, 0, 0]
  var rarityTagged = 0
  var droppedQuest = 0
  var droppedUnpriced = 0
  var t2 = 0
  while t2 < tplKeys.len:
    let props = memberValue(itemsR.body, tplVals[t2], "_props")
    let rarity = textField(itemsR.body, props, "RarityPvE")
    var known = -1
    var q = 0
    while q < 3:
      if rarity == Rarities[q]:
        known = q
      inc q
    if known >= 0:
      inc rarityTagged
      if boolField(itemsR.body, props, "QuestItem"):
        inc droppedQuest
      elif not contains(pricedIds, tplKeys[t2]):
        inc droppedUnpriced
      else:
        poolSize[known] = poolSize[known] + 1
    inc t2
  check("the item table tags templates with the rarities scav cases pay in",
        rarityTagged > 0, $rarityTagged & " templates carry _props.RarityPvE")
  var emptyWanted = ""
  var q2 = 0
  while q2 < 3:
    if wantedRarity[q2] and poolSize[q2] == 0:
      if emptyWanted.len == 0:
        emptyWanted = Rarities[q2]
    inc q2
  check("every rarity a real scav recipe asks for has items to put in the case",
        emptyWanted.len == 0,
        "no eligible template is " & emptyWanted)
  check("and the quest items among them are held back",
        droppedQuest > 0,
        $droppedQuest & " rarity-tagged templates are quest items")
  line "  " & $scavList.len & " scav recipes, " & $rarityTagged &
       " rarity-tagged templates -> pools of " & $poolSize[0] & "/" &
       $poolSize[1] & "/" & $poolSize[2] & " (" & $droppedQuest &
       " quest items and " & $droppedUnpriced & " unpriced held back)"

  # -- and one of them, run ------------------------------------------------
  #
  # `scavRecipes[0]`, whichever that is in this database, rather than an id
  # written down here.
  var scavId = ""
  if scavList.len > 0:
    scavId = textField(recipesR.body, scavList[0], "_id")
  if scavId.len == 0:
    skip("a real scav case is refused before its area is built",
         "this database has no scav recipes")
    skip("a real scav case rolls its rewards at the moment it starts",
         "this database has no scav recipes")
  else:
    let tooEarly = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutScavCaseProductionStart\"," &
      "\"recipeId\":\"" & scavId & "\"}],\"tm\":2}")
    check("a real scav case is refused before its area is built",
          tooEarly.contains("not built yet"),
          tooEarly.body.substr(0, (if tooEarly.body.len > 220: 220
                                   else: tooEarly.body.len) - 1))

    # The scav case is area 14 in the client's own numbering, which is what
    # `emu/production` reads it as -- and the areas table is walked for what
    # that level costs rather than assuming it is free.
    var casePlanTys: seq[int] = @[]
    var casePlanLvs: seq[int] = @[]
    var caseTpls: seq[string] = @[]
    var caseNums: seq[int] = @[]
    var caseBlocked = ""
    planArea(areasR.body, areaList, 14, 1, 0, casePlanTys, casePlanLvs,
             caseTpls, caseNums, caseBlocked)
    var caseAffordable = caseBlocked.len == 0 and casePlanTys.len > 0
    if caseAffordable:
      var k3 = 0
      while k3 < caseTpls.len:
        if caseTpls[k3] != Roubles and findOffer(offers, caseTpls[k3]) < 0:
          caseAffordable = false
        inc k3
    if not caseAffordable:
      skip("a real scav case rolls its rewards at the moment it starts",
           (if caseBlocked.len > 0: caseBlocked
            else: "no trader sells what the scav case's stage asks for"))
    else:
      var k4 = 0
      while k4 < caseTpls.len:
        if caseTpls[k4] != Roubles:
          let idx = findOffer(offers, caseTpls[k4])
          var got = 0
          while got < caseNums[k4] and idx >= 0:
            discard call("/client/game/profile/items/moving",
              "{\"data\":[{\"Action\":\"TradingConfirm\"," &
              "\"type\":\"buy_from_trader\",\"tid\":\"" & offers[idx].trader &
              "\",\"item_id\":\"" & offers[idx].root &
              "\",\"count\":1,\"scheme_id\":0,\"scheme_items\":[{\"id\":\"" &
              moneyId & "\",\"count\":" & $offers[idx].price & "}]}],\"tm\":2}")
            inc got
        inc k4
      var u2 = 0
      while u2 < casePlanTys.len:
        discard call("/client/game/profile/items/moving",
          "{\"data\":[{\"Action\":\"HideoutUpgrade\",\"areaType\":" &
          $casePlanTys[u2] & "}],\"tm\":2}")
        discard call("/client/game/profile/items/moving",
          "{\"data\":[{\"Action\":\"HideoutUpgradeComplete\",\"areaType\":" &
          $casePlanTys[u2] & "}],\"tm\":2}")
        inc u2
      listR = call("/client/game/profile/list", "")
      profAt = profileOf(listR.body, uid)
      var caseLevel = 0
      for a in elements(listR.body,
                        memberValue(listR.body,
                                    memberValue(listR.body, profAt, "Hideout"),
                                    "Areas")):
        if intField(listR.body, a, "type") == 14:
          caseLevel = intField(listR.body, a, "level")
      if caseLevel < 1:
        skip("a real scav case rolls its rewards at the moment it starts",
             "the scav case's stage would not build from what a trader sells")
      else:
        let ran = call("/client/game/profile/items/moving",
          "{\"data\":[{\"Action\":\"HideoutScavCaseProductionStart\"," &
          "\"recipeId\":\"" & scavId & "\"}],\"tm\":2}")
        listR = call("/client/game/profile/list", "")
        profAt = profileOf(listR.body, uid)
        let rec = memberValue(listR.body,
          memberValue(listR.body,
                      memberValue(listR.body, profAt, "Hideout"),
                      "Production"), scavId)
        let rolled = elements(listR.body,
                              memberValue(listR.body, rec, "sptScavProducts"))
        check("a real scav case rolls its rewards at the moment it starts",
              ran.ok and rec >= 0 and rolled.len > 0,
              ran.body.substr(0, (if ran.body.len > 220: 220
                                  else: ran.body.len) - 1))
        # Every one of them, against the same three rules the pool was built
        # from. This is the check a wrong join fails: a pool that forgot the
        # handbook hands out something no trader will buy, and a pool that
        # forgot `QuestItem` hands out something a quest can no longer make the
        # player find.
        var wrong = ""
        for pAt in rolled:
          let tpl = textVal(listR.body, pAt)
          if not contains(templateIds, tpl):
            if wrong.len == 0: wrong = tpl & " is not a template"
            continue
          if not contains(pricedIds, tpl):
            if wrong.len == 0: wrong = tpl & " has no handbook price"
          var idx2 = -1
          var m2 = 0
          while m2 < tplKeys.len:
            if tplKeys[m2] == tpl:
              idx2 = tplVals[m2]
              break
            inc m2
          let props2 = memberValue(itemsR.body, idx2, "_props")
          if boolField(itemsR.body, props2, "QuestItem"):
            if wrong.len == 0: wrong = tpl & " is a quest item"
          let rarity2 = textField(itemsR.body, props2, "RarityPvE")
          var asked = false
          var q3 = 0
          while q3 < 3:
            if rarity2 == Rarities[q3] and
               intField(recipesR.body,
                        memberValue(recipesR.body,
                          memberValue(recipesR.body, scavList[0],
                                      "endProducts"), Rarities[q3]),
                        "max") > 0:
              asked = true
            inc q3
          if not asked:
            if wrong.len == 0:
              wrong = tpl & " is " & rarity2 & ", which this recipe zeroed"
        check("and every reward is a real, priced, non-quest template of a rarity it asked for",
              wrong.len == 0, wrong)
        let twiceCase = call("/client/game/profile/items/moving",
          "{\"data\":[{\"Action\":\"HideoutScavCaseProductionStart\"," &
          "\"recipeId\":\"" & scavId & "\"}],\"tm\":2}")
        check("and starting the same case twice is refused",
              twiceCase.contains("already running"),
              twiceCase.body.substr(0, (if twiceCase.body.len > 220: 220
                                        else: twiceCase.body.len) - 1))
        let earlyCase = call("/client/game/profile/items/moving",
          "{\"data\":[{\"Action\":\"HideoutTakeProduction\",\"recipeId\":\"" &
          scavId & "\"}],\"tm\":2}")
        let caseTime = intField(recipesR.body, scavList[0], "productionTime")
        if caseTime > 0:
          check("and collecting it before the real production time has passed is refused",
                earlyCase.contains("not finished"),
                earlyCase.body.substr(0, (if earlyCase.body.len > 220: 220
                                          else: earlyCase.body.len) - 1))
        else:
          skip("collecting a scav case early",
               "this database's scav case is instant")
        line "  ran " & scavId & ": " & $rolled.len & " reward(s), " &
             $caseTime & "s"

  # =========================================================================
  heading "The gym and the wardrobe, against the real tables"
  # =========================================================================
  # Two tables the fixture now carries cut-down versions of. Everything the
  # gym and `CustomizationSet` do is read out of them at run time, so what a
  # real database can be wrong about is not the arithmetic -- `emutest` pins
  # that -- but the *joins*: a qte entry naming an area the hideout does not
  # have, a skill nothing else in the game knows, a customisation entry hanging
  # off a parent that is not there.
  let qteR = timed("gym", "/client/hideout/qte/list", "")
  let qteList = elements(qteR.body, dataAt(qteR))
  check("the gym table answers the entries the workout screen draws",
        qteR.ok and qteList.len > 0, $qteList.len & " entries")
  var qteBadArea = ""
  var qteNoEvents = ""
  var qteNoExit = ""
  var qteEvents = 0
  var qteSkills: seq[string] = @[]
  for q in qteList:
    let ty = intField(qteR.body, q, "area")
    var known = false
    for a in areaTypes:
      if a == ty:
        known = true
    if not known and qteBadArea.len == 0:
      qteBadArea = textField(qteR.body, q, "id") & " is played in area " & $ty
    let evs = elements(qteR.body, memberValue(qteR.body, q, "quickTimeEvents"))
    qteEvents = qteEvents + evs.len
    if evs.len == 0 and qteNoEvents.len == 0:
      qteNoEvents = textField(qteR.body, q, "id")
    let res = memberValue(qteR.body, q, "results")
    # `singleFailEffect.rewardsRange[].result == "Exit"` is the whole basis of
    # the rule that a missed circle ends the session. If a real table stopped
    # saying it, the server would stop enforcing it -- so it is asserted here
    # rather than assumed by a check written against the fixture.
    var exits = false
    for rr in elements(qteR.body,
                       memberValue(qteR.body,
                                   memberValue(qteR.body, res,
                                               "singleFailEffect"),
                                   "rewardsRange")):
      if textField(qteR.body, rr, "result") == "Exit":
        exits = true
    if not exits and qteNoExit.len == 0:
      qteNoExit = textField(qteR.body, q, "id")
    for rr in elements(qteR.body,
                       memberValue(qteR.body,
                                   memberValue(qteR.body, res,
                                               "singleSuccessEffect"),
                                   "rewardsRange")):
      if textField(qteR.body, rr, "type") != "Skill":
        continue
      let sid = textField(qteR.body, rr, "skillId")
      var seen = false
      for k in qteSkills:
        if k == sid:
          seen = true
      if not seen and sid.len > 0:
        qteSkills.add sid
  check("every gym entry is played in an area the hideout table has",
        qteBadArea.len == 0, qteBadArea)
  check("and defines the events that bound what a client may claim",
        qteNoEvents.len == 0, qteNoEvents & " defines none")
  check("and says that a missed event ends the session",
        qteNoExit.len == 0,
        qteNoExit & " has no Exit on its singleFailEffect")
  check("and pays out in skills, with a multiplier table to price them by",
        qteSkills.len > 0, $qteSkills.len & " skills")
  var qteJoined = ""
  for sid in qteSkills:
    if qteJoined.len > 0: qteJoined.add ", "
    qteJoined.add sid
  line "  " & $qteList.len & " gym entries, " & $qteEvents &
       " quick time events, paying " & qteJoined

  let wardrobeR = timed("customization", "/client/customization", "")
  var wKeys: seq[string] = @[]
  var wVals: seq[int] = @[]
  members(wardrobeR.body, dataAt(wardrobeR), wKeys, wVals)
  check("the wardrobe answers a table with entries in it", wKeys.len > 10,
        $wKeys.len & " entries")
  var wBadParent = ""
  var wNoSide = ""
  var wNodes = 0
  var wItems = 0
  var wSuiteDangling = ""
  var wIds = initHashSet[string]()
  for k in wKeys:
    incl(wIds, k)
  var w = 0
  while w < wKeys.len:
    let at = wVals[w]
    if at < 0 or wardrobeR.body[at] != '{':
      inc w
      continue
    let parent = textField(wardrobeR.body, at, "_parent")
    if parent.len > 0 and not contains(wIds, parent):
      if wBadParent.len == 0:
        wBadParent = wKeys[w] & " -> " & parent
    if textField(wardrobeR.body, at, "_type") == "Node":
      inc wNodes
    else:
      inc wItems
      let props = memberValue(wardrobeR.body, at, "_props")
      if memberValue(wardrobeR.body, props, "Side") < 0 and wNoSide.len == 0:
        wNoSide = wKeys[w]
      # A suite is an indirection: it names the Body, Hands or Feet that go
      # with it, and a suite naming an entry that is not there is one the
      # server has to refuse rather than half-apply.
      for prop in @["Body", "Hands", "Feet"]:
        let named = textField(wardrobeR.body, props, prop)
        if named.len > 0 and not contains(wIds, named):
          if wSuiteDangling.len == 0:
            wSuiteDangling = wKeys[w] & " names " & named & " as its " & prop
    inc w
  check("every wardrobe entry hangs off a node the table declares",
        wBadParent.len == 0, wBadParent)
  check("every wearable entry says which side may wear it",
        wNoSide.len == 0, wNoSide & " has no _props.Side")
  check("and every suite names parts the table has",
        wSuiteDangling.len == 0, wSuiteDangling)
  line "  " & $wNodes & " wardrobe categories over " & $wItems & " entries"

  # -- the hideout's own wardrobe, and the join under it ---------------------
  #
  # `hideout.customisation` was imported and populated all along and this route
  # answered `[]` until it was read -- wrong twice over, because the reference
  # DTO is an *object* of two lists and an array hands the client a null to
  # index.
  #
  # What only a real database can answer is the join. `Hideout.Customization`
  # is a map with no declared keys, so the key a decoration is written under is
  # derived: `itemId` -> the wardrobe entry it names -> that entry's `_parent`
  # -> that node's `_name`. Every step of that is checked here over the whole
  # table, because a single offer whose item is filed under the wrong node
  # writes a ceiling into the wall's field, and the symptom is a hideout that
  # renders wrongly with nothing in any log.
  #
  # The last check is the one that ages: a condition kind this server cannot
  # evaluate is *refused*, so a real table that grows a fifth kind turns some
  # number of decorations into things no player can obtain. That is a change
  # worth being told about rather than discovering in a screenshot.
  let hcR = timed("hideout customisation",
                  "/client/hideout/customization/offer/list", "")
  let hcData = dataAt(hcR)
  let hcGlobals = elements(hcR.body, memberValue(hcR.body, hcData, "globals"))
  let hcSlots = elements(hcR.body, memberValue(hcR.body, hcData, "slots"))
  check("the hideout customisation list answers an object of two lists",
        hcR.ok and hcData >= 0 and hcR.body[hcData] == '{' and
        hcGlobals.len > 0 and hcSlots.len > 0,
        $hcGlobals.len & " globals and " & $hcSlots.len & " slots")

  var hcNoItem = ""
  var hcUnknownItem = ""
  var hcUnplaced = ""
  var hcMismatch = ""
  var hcSlotWithItem = ""
  var hcSlotNoSlotId = ""
  var hcKinds: seq[string] = @[]
  var hcOddCondition = ""
  var hcBranches: seq[string] = @[]
  for g in hcGlobals:
    let name = textField(hcR.body, g, "systemName")
    let itemId = textField(hcR.body, g, "itemId")
    if itemId.len == 0:
      if hcNoItem.len == 0: hcNoItem = name
      continue
    if not contains(wIds, itemId):
      if hcUnknownItem.len == 0: hcUnknownItem = name & " -> " & itemId
      continue
    let branch = parentNameIn(wardrobeR.body, wKeys, wVals, itemId)
    if branch.len == 0:
      if hcUnplaced.len == 0: hcUnplaced = name & " -> " & itemId
      continue
    var seenBranch = false
    for b in hcBranches:
      if b == branch: seenBranch = true
    if not seenBranch: hcBranches.add branch
    let kind = textField(hcR.body, g, "type")
    let lowered = toLowerAscii(branch.substr(0, 0)) & branch.substr(1)
    if kind != lowered and hcMismatch.len == 0:
      hcMismatch = name & " calls itself a " & kind & " and names a " & lowered
    for c in elements(hcR.body, memberValue(hcR.body, g, "conditions")):
      let ct = textField(hcR.body, c, "conditionType")
      var known = false
      for k in hcKinds:
        if k == ct: known = true
      if not known and ct.len > 0: hcKinds.add ct
      if ct != "Block" and ct != "HideoutArea" and ct != "Level" and
         ct != "Quest" and hcOddCondition.len == 0:
        hcOddCondition = name & " is gated on a \"" & ct & "\" condition"
  for sl in hcSlots:
    if textField(hcR.body, sl, "itemId").len > 0 and hcSlotWithItem.len == 0:
      hcSlotWithItem = textField(hcR.body, sl, "systemName")
    if textField(hcR.body, sl, "slotId").len == 0 and hcSlotNoSlotId.len == 0:
      hcSlotNoSlotId = textField(hcR.body, sl, "systemName")

  check("every decoration on offer names an item", hcNoItem.len == 0, hcNoItem)
  check("and every one of those items is in the wardrobe table",
        hcUnknownItem.len == 0, hcUnknownItem)
  check("and every one of them hangs off a node, which is the profile key",
        hcUnplaced.len == 0, hcUnplaced)
  check("and each offer's type is its item's own branch, lowercased",
        hcMismatch.len == 0, hcMismatch)
  check("no slot carries an item, which is why applying one is refused",
        hcSlotWithItem.len == 0, hcSlotWithItem & " has an itemId")
  check("and every slot names the slot it is", hcSlotNoSlotId.len == 0,
        hcSlotNoSlotId & " has no slotId")
  check("and every condition on them is a kind this server can evaluate",
        hcOddCondition.len == 0, hcOddCondition)

  # And the pose node, which is a different join: `MannequinPose` is a branch
  # of the wardrobe table with no offer pointing at it at all -- poses are set
  # by id straight from the client, so the table is the only thing that can say
  # an id is a pose.
  var poseCount = 0
  var w2 = 0
  while w2 < wKeys.len:
    if textField(wardrobeR.body, wVals[w2], "_type") != "Node" and
       parentNameIn(wardrobeR.body, wKeys, wVals, wKeys[w2]) == "MannequinPose":
      inc poseCount
    inc w2
  check("the wardrobe has mannequin poses to set", poseCount > 0,
        $poseCount & " entries under MannequinPose")

  var branchList = ""
  for b in hcBranches:
    if branchList.len > 0: branchList.add ", "
    branchList.add b
  var kindList = ""
  for k in hcKinds:
    if kindList.len > 0: kindList.add ", "
    kindList.add k
  line "  " & $hcGlobals.len & " decorations (" & branchList & ") and " &
       $hcSlots.len & " slots, gated on " & kindList & "; " & $poseCount &
       " mannequin poses"

  heading "Across a restart, with the store already full"
  var restarts = 0
  var markers = initHashSet[string]()
  var everySeen = initHashSet[string]()
  var reused = 0
  var reusedSample = ""
  var rewound = 0
  var rewoundSample = ""
  var stashStillStash = true

  listR = call("/client/game/profile/list", "")
  profAt = profileOf(listR.body, uid)
  if profAt >= 0:
    incl(everySeen, uid)
    incl(markers, uid.substr(0, 11))
    for it in elements(listR.body,
                       memberValue(listR.body,
                                   memberValue(listR.body, profAt, "Inventory"),
                                   "items")):
      let id = textField(listR.body, it, "_id")
      if id.len == 24:
        incl(everySeen, id)
        incl(markers, id.substr(0, 11))

  var round2 = 0
  while round2 < 4:
    cSpawnKill(server)
    cSleepMs(300'i32)
    let reBegan = micros()
    server = startBackend(backend, root)
    if server == 0'u64:
      err "could not restart the backend"
      return 1
    if not waitForBackend(300):
      err "the backend did not come back up"
      cSpawnKill(server)
      return 1
    inc restarts
    if round2 == 0:
      line "  reloaded " & $(dbBytes div 1048576'i64) & " MiB in " &
           $((micros() - reBegan) div 1000'i64) & " ms"

    listR = call("/client/game/profile/list", "")
    profAt = profileOf(listR.body, uid)
    if profAt < 0:
      break
    if pick < 0:
      break
    moneyId = firstMoneyId(listR.body, profAt)
    discard call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"TradingConfirm\",\"type\":\"buy_from_trader\"," &
      "\"tid\":\"" & offers[pick].trader & "\",\"item_id\":\"" &
      offers[pick].root & "\",\"count\":1,\"scheme_id\":0," &
      "\"scheme_items\":[{\"id\":\"" & moneyId & "\",\"count\":" &
      $offers[pick].price & "}]}],\"tm\":2}")
    listR = call("/client/game/profile/list", "")
    profAt = profileOf(listR.body, uid)
    if profAt < 0:
      break
    for it in elements(listR.body,
                       memberValue(listR.body,
                                   memberValue(listR.body, profAt, "Inventory"),
                                   "items")):
      let id = textField(listR.body, it, "_id")
      if id.len != 24:
        continue
      if contains(everySeen, id):
        continue
      # Issued by the server that has just started.
      if contains(markers, id.substr(0, 11)):
        inc rewound
        if rewoundSample.len == 0:
          rewoundSample = id & " shares its run marker with ids issued before " &
                          "the restart, so its counter has been rewound over " &
                          "ids that are already in the store"
      incl(everySeen, id)
      incl(markers, id.substr(0, 11))
    # The stash, by name. The failure this whole section is about ends with the
    # stash's id belonging to something else, and that is worth saying in those
    # words rather than as a count.
    let stashNow = itemAt(listR.body, profAt, stashId)
    if stashNow < 0 or textField(listR.body, stashNow, "_tpl") != stashTpl:
      stashStillStash = false
    # And the plain duplicate sweep, over the whole item list.
    var thisRound = initHashSet[string]()
    for it in elements(listR.body,
                       memberValue(listR.body,
                                   memberValue(listR.body, profAt, "Inventory"),
                                   "items")):
      let id = textField(listR.body, it, "_id")
      if id.len == 24 and containsOrIncl(thisRound, id):
        inc reused
        if reusedSample.len == 0:
          reusedSample = id & " (" & textField(listR.body, it, "_tpl") & ")"
    inc round2

  listR = call("/client/game/profile/list", "")
  profAt = profileOf(listR.body, uid)
  check("the profile survives every restart", profAt >= 0, "gone")
  check("no id in it appears twice after " & $restarts & " restarts",
        reused == 0, $reused & " duplicated, e.g. " & reusedSample)
  check("and no id a later server issued was one an earlier one could have",
        rewound == 0, rewoundSample)
  check("and the stash is still the stash", stashStillStash,
        "the stash's id names something else now")
  line "  " & $restarts & " restarts over one store, " & $markers.len &
       " distinct id runs, " & $everySeen.len & " ids seen"

  # -- the kits screen: a valid, correctly typed, EMPTY answer is a crash ---
  #
  # `EFT.UI.EquipmentBuildsScreen.Show` calls `System.Linq.Enumerable.First`
  # on `equipmentBuilds`. An empty list throws `InvalidOperationException:
  # Sequence contains no elements` inside `Show`, so the screen opens and
  # closes in the same frame -- measured live in the client's own
  # `errors_000.log` at 2026-08-28 14:06:45, one line after the client logged
  # `_buildList empty` from `UpdateBuildList()`.
  #
  # Every check we already had passed on that response. It had all three
  # keys, both lists were arrays, nothing was mistyped, the envelope matched.
  # It was EMPTY, and emptiness is invisible to a shape check. So these
  # checks are about CONTENT, and each is stated as a negative that a real
  # regression can falsify.
  # -- the progression cheats, asserted on the SERVED PROFILE ---------------
  #
  # `emu/progression` already has a self-check, and it is pure: it exercises
  # the family filter and the exp-table arithmetic. Every one of those
  # assertions passed for the whole time the feature was UNREACHABLE, because
  # none of them touches a profile and none of them touches config.json. The
  # three keys were declared, wired and absent from the live
  # `mods/tarkov/config.json`, so `configGet` answered ErrNotFound, the rows
  # rendered at their schema defaults and the code below them never ran.
  #
  # So this asserts the finished state and nothing else: drive the setting
  # through the REAL settings route, then re-read `/client/game/profile/list`
  # and check the field THE CLIENT reads. For the level that is
  # `Info.Experience` -- the client derives the level it draws from the exp
  # table and does not trust `Info.Level` (see `emu/progression`'s header), so
  # a check on `Info.Level` alone is one this feature can pass while being
  # recomputed away on the client's first frame.
  #
  # The expected experience is recomputed HERE, from the exp table the server
  # itself served over `/client/globals`, rather than taken from the emulator.
  # A shared `xpForLevel` on both sides could only compare the code with
  # itself.
  heading "Progression"
  block progression:
    let expTableAt = memberValue(globalsR.body,
                       memberValue(globalsR.body,
                         memberValue(globalsR.body,
                           memberValue(globalsR.body, dataAt(globalsR),
                                       "config"), "exp"), "level"), "exp_table")
    let expRows = elements(globalsR.body, expTableAt)
    if expRows.len < 20:
      skip("a player level set on the settings page reaches the served profile",
           "globals.config.exp.level.exp_table has " & $expRows.len &
           " entries, so there is no table to compute an experience from -- " &
           "INCONCLUSIVE, not a pass")
      break progression

    # The floor to ask for. Deliberately not 1 (level 1 is zero experience, so
    # a server that wrote nothing at all would pass) and not the top of the
    # table (which clamps, and a clamp can hide an off-by-one).
    const WantLevel = 20
    var wantXp = 0
    var i = 0
    while i < expRows.len and i < WantLevel:
      wantXp = wantXp + intField(globalsR.body, expRows[i], "exp")
      inc i
    check("the exp table gives level " & $WantLevel & " a non-zero experience",
          wantXp > 0, $wantXp)

    let before = call("/client/game/profile/list", "")
    let beforeAt = profileOf(before.body, uid)
    let infoBefore = memberValue(before.body, beforeAt, "Info")
    let xpBefore = intField(before.body, infoBefore, "Experience")

    if not setTarkovSetting("progressionPlayerLevel", $WantLevel):
      skip("a player level set on the settings page reaches the served profile",
           "the settings POST for progressionPlayerLevel did not persist -- " &
           "that is the ORIGINAL bug (no such key in config.json), and it is " &
           "a failure of the write path, not of progression")
    else:
      let after = call("/client/game/profile/list", "")
      let afterAt = profileOf(after.body, uid)
      let infoAfter = memberValue(after.body, afterAt, "Info")
      let xpAfter = intField(after.body, infoAfter, "Experience")
      let lvlAfter = intField(after.body, infoAfter, "Level")
      # THE assertion. Not "config.json now has the key" and not "the POST
      # returned 200" -- both of those were true on the broken build.
      check("the field the client derives the level from carries it",
            xpAfter >= wantXp,
            "Info.Experience is " & $xpAfter & ", the table wants " &
            $wantXp & " for level " & $WantLevel & " (was " & $xpBefore &
            " before the edit)")
      check("and Info.Level agrees with it",
            lvlAfter >= WantLevel,
            "Info.Level is " & $lvlAfter)

      # The floor, stated as the negative that a ceiling-shaped bug fails:
      # lowering the setting must take nothing away.
      discard setTarkovSetting("progressionPlayerLevel", "1")
      let lowered = call("/client/game/profile/list", "")
      let loweredXp = intField(lowered.body,
                        memberValue(lowered.body,
                          profileOf(lowered.body, uid), "Info"), "Experience")
      check("lowering the setting takes no experience away (it is a floor)",
            loweredXp >= xpAfter,
            "Info.Experience went " & $xpAfter & " -> " & $loweredXp)
      discard setTarkovSetting("progressionPlayerLevel", "0")

    # Mastery. Per weapon FAMILY, and the threshold is the family's own
    # `Level2` out of `globals.config.Mastering` -- read here from the served
    # globals for the same reason the exp table is.
    let masteringAt = memberValue(globalsR.body,
                        memberValue(globalsR.body, dataAt(globalsR), "config"),
                        "Mastering")
    let famRows = elements(globalsR.body, masteringAt)
    if famRows.len == 0:
      skip("weapon mastery set on the settings page reaches the served profile",
           "globals.config.Mastering is empty, so no family has a threshold " &
           "to raise to -- INCONCLUSIVE, not a pass")
    elif not setTarkovSetting("progressionMasteryLevel", "2"):
      skip("weapon mastery set on the settings page reaches the served profile",
           "the settings POST for progressionMasteryLevel did not persist")
    else:
      let after = call("/client/game/profile/list", "")
      let afterAt = profileOf(after.body, uid)
      let mastering = elements(after.body,
                        memberValue(after.body,
                          memberValue(after.body, afterAt, "Skills"),
                          "Mastering"))
      # Every family in the table must be present on the profile at or above
      # its OWN Level2 -- a negative over the whole set, so a server that
      # raised one family and stopped fails, and one that wrote a single
      # constant into every family fails too (the thresholds differ: M4 is
      # 1600, SKS 200).
      var short = 0
      var missing = 0
      var firstShort = ""
      for f in famRows:
        let name = textField(globalsR.body, f, "Name")
        if name.len == 0:
          continue
        let want = intField(globalsR.body, f, "Level2")
        var found = -1
        for m in mastering:
          if textField(after.body, m, "Id") == name:
            found = intField(after.body, m, "Progress")
        if found < 0:
          inc missing
          if firstShort.len == 0: firstShort = name & " absent"
        elif found < want:
          inc short
          if firstShort.len == 0:
            firstShort = name & " at " & $found & ", wants " & $want
      check("no weapon family is served below its own level-2 threshold",
            short == 0 and missing == 0,
            $short & " below threshold, " & $missing &
            " absent, of " & $famRows.len & " families; first: " & firstShort)
      check("and the profile carries a mastery row per family",
            mastering.len >= famRows.len,
            $mastering.len & " rows for " & $famRows.len & " families")
      discard setTarkovSetting("progressionMasteryLevel", "0")

  heading "Saved builds"
  let blist = call("/client/builds/list", "")
  let blAt = dataAt(blist)
  let eqBuilds = elements(blist.body,
                          memberValue(blist.body, blAt, "equipmentBuilds"))
  check("the kits screen is never handed an empty equipment list",
        eqBuilds.len > 0,
        "equipmentBuilds is [] -- EquipmentBuildsScreen.Show() will throw")
  var stock = 0
  var husks = 0
  var danglingRoot = 0
  var unnamed = 0
  for b in eqBuilds:
    if textField(blist.body, b, "BuildType") == "Standard":
      inc stock
    if textField(blist.body, b, "Name").len == 0:
      inc unnamed
    let items = elements(blist.body, memberValue(blist.body, b, "Items"))
    if items.len == 0:
      inc husks
      continue
    let root = textField(blist.body, b, "Root")
    var rooted = false
    for it in items:
      if textField(blist.body, it, "_id") == root:
        rooted = true
    if not rooted:
      inc danglingRoot
  check("all twelve stock loadouts the real backend ships are among them",
        stock == 12, $stock & " of 12 carry BuildType=Standard")
  check("and not one of them is a named husk with no Items",
        husks == 0, $husks & " builds have an empty Items list")
  check("and every build's Root is the _id of one of its own Items",
        danglingRoot == 0, $danglingRoot & " builds point Root at nothing")
  check("and every build has a name to draw on the row",
        unnamed == 0, $unnamed & " builds have no Name")
  # The other two lists are legitimately empty on a fresh profile -- the
  # capture shows the real backend sending `[]` for both (seq 123) -- so
  # emptiness there is asserted as CORRECT rather than merely tolerated.
  let wpBuilds = elements(blist.body,
                          memberValue(blist.body, blAt, "weaponBuilds"))
  let mgBuilds = elements(blist.body,
                          memberValue(blist.body, blAt, "magazineBuilds"))
  check("a profile that saved nothing has no weapon or magazine builds",
        wpBuilds.len == 0 and mgBuilds.len == 0,
        $wpBuilds.len & " weapon, " & $mgBuilds.len & " magazine")

  # -------------------------------------------------------------------------
  # Install-constant content routes (emptygap.py's ranked HOLEs)
  # -------------------------------------------------------------------------
  #
  # Same failure class as builds/list: a structurally valid, correctly typed,
  # EMPTY object passes every shape/type audit and is still a hole, because BSG
  # ships the SAME content here to every account regardless of profile. Each
  # check below is a NEGATIVE about the finished served body -- "the member BSG
  # populates is not empty in ours" -- so it is falsified by reverting the fill
  # (move the data/post1 file aside and the count drops to 0). Weights match the
  # capture (raid1: seq 081/044/132/080).
  heading "Install-constant content routes"

  let bpass = call("/client/battle-pass/active", "")
  let bpAt = dataAt(bpass)
  let passes = elements(bpass.body, memberValue(bpass.body, bpAt, "battlePasses"))
  check("battle-pass/active carries at least one battle pass, not []",
        passes.len >= 1,
        $passes.len & " passes -- BSG ships one (seq 081); [] is a HOLE")

  let perks = call("/client/seasonal-perks/list", "")
  let spAt = dataAt(perks)
  let common = elements(perks.body, memberValue(perks.body, spAt, "common"))
  let personal = elements(perks.body, memberValue(perks.body, spAt, "personal"))
  check("seasonal-perks/list carries the common perk catalogue, not []",
        common.len >= 1,
        $common.len & " common perks -- BSG ships 6 (seq 044); [] is a HOLE")
  check("seasonal-perks/list carries the personal perk catalogue, not []",
        personal.len >= 1,
        $personal.len & " personal perks -- BSG ships 33 (seq 044); [] is a HOLE")

  let ending = call("/client/ending/list", "")
  let enAt = dataAt(ending)
  let elems = elements(ending.body, memberValue(ending.body, enAt, "elements"))
  check("ending/list carries the prestige-ending descriptors, not []",
        elems.len >= 1,
        $elems.len & " elements -- BSG ships 4 (seq 132); [] is a HOLE")

  let season = call("/client/season/active", "")
  let seAt = dataAt(season)
  let seasonObj = memberValue(season.body, seAt, "season")
  var seasonKeys: seq[string] = @[]
  var seasonVals: seq[int] = @[]
  if seasonObj >= 0 and seasonObj < season.body.len and
     season.body[seasonObj] == '{':
    members(season.body, seasonObj, seasonKeys, seasonVals)
  check("season/active carries a non-null season object, not {}",
        seasonKeys.len >= 1,
        "season is absent/null/empty -- {} makes data.season a null the client derefs")

  # -------------------------------------------------------------------------
  # The item spawner
  # -------------------------------------------------------------------------
  #
  # The F6 overlay and the settings page are two front ends onto ONE server
  # implementation: `searchItemsCounted` and `spawnInto` in
  # `mods/tarkov/emu/spawn.nim`, reached over the wire through the
  # `optionsUrl` search route and the momentary `spawnNow` row. Until now
  # nothing exercised either against real data, so "typing in the spawner
  # produces nothing" had no test that could have caught it at any layer.
  #
  # Identity-free, like the rest of this file: the template it spawns is
  # whichever one the profile already holds, so this works against a database
  # imported next year.
  heading "The item spawner"

  listR = call("/client/game/profile/list", "")
  var spProfAt = profileOf(listR.body, uid)
  var spTpl = ""
  if spProfAt >= 0:
    let invA = memberValue(listR.body, spProfAt, "Inventory")
    if invA >= 0:
      for it in elements(listR.body, memberValue(listR.body, invA, "items")):
        let c = textField(listR.body, it, "_tpl")
        # A template this run can also SIZE, so the overlap assertion below is
        # about a known footprint rather than a shrug.
        if c.len != 24 or indexOfTpl(tplSizes, c) < 0:
          continue
        # It must have a PARENT. The first item in the list is the inventory
        # root -- `55d7217a4bdc2d86028b456d`, "Default Inventory" -- which is a
        # real template and a nonsensical thing to spawn a second copy of: it
        # is the container everything else hangs off, not an item in a stash.
        # Requiring a parentId picks something that is genuinely IN the
        # inventory rather than being the inventory.
        if textField(listR.body, it, "parentId").len == 0:
          continue
        spTpl = c
        break

  if spTpl.len == 0:
    skip("the item spawner", "the profile holds no sizeable template to " &
         "spawn a second copy of; nothing was searched or spawned")
  else:
    const SpawnItems = TarkovSettings & "/items"

    # -- SEARCH ------------------------------------------------------------
    #
    # Three queries, because one cannot distinguish a working search from a
    # search that answers the same thing to everything. The id must be FOUND,
    # the nonsense must be MISSED, and the substring supplies a denominator:
    # if all three came back the same the search is broken whichever way.
    let byId = call(SpawnItems & "?q=" & spTpl & "&limit=50", "")
    let idFound = findAt(byId.body, "\"value\":\"" & spTpl & "\"", 0) >= 0
    check("searching the spawner for a known template id returns that item",
          byId.ok and idFound and matchedOf(byId.body) == 1,
          why(byId) & "; matched=" & $matchedOf(byId.body) & " for " & spTpl)

    # The negative, and the reason it is a separate check: an empty options
    # list with `matched: 0` is an ANSWER -- "no such item" -- and the route
    # must say it rather than erroring or, worse, answering ok with a list it
    # quietly truncated to nothing.
    let byJunk = call(SpawnItems &
                      "?q=zzqqxxnosuchitemzzqq&limit=50", "")
    check("and a nonsense query is an explicit no-match, not an error",
          byJunk.ok and matchedOf(byJunk.body) == 0 and
            findAt(byJunk.body, "\"options\":[]", 0) >= 0,
          why(byJunk) & "; matched=" & $matchedOf(byJunk.body))

    # The denominator. A name substring every real database has, searched by
    # NAME rather than by id so the locale scan -- the half the id path skips
    # entirely -- is inside an assertion too.
    # The term is taken from the LABEL the id search just returned, so it is
    # guaranteed to match at least that item in whatever database this is --
    # and it is a word rather than a letter. A one-character query was the
    # first version here and it is the wrong test twice over: it matches most
    # of the locale, so it asserts almost nothing, and counting `matched`
    # visits all ~40,000 entries calling `itemExists` on each.
    var nameTerm = ""
    let labAt = findAt(byId.body, "\"label\":\"", 0)
    if labAt >= 0:
      var k = labAt + 9
      while k < byId.body.len and byId.body[k] != '"' and nameTerm.len < 6:
        # Letters only: a label starting with a digit or punctuation makes a
        # poor substring and an escape would need decoding to be safe.
        let ch = byId.body[k]
        if (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z'):
          nameTerm.add ch
        elif nameTerm.len > 0:
          break
        inc k
    if nameTerm.len < 3:
      nameTerm = "bag"
    let byName = call(SpawnItems & "?q=" & nameTerm & "&limit=50", "")
    let nameMatched = matchedOf(byName.body)
    let nameOpts = countAt(byName.body, "\"value\":\"")
    check("and a name substring searches the locale, not just the id table",
          byName.ok and nameMatched > 0 and nameOpts > 0,
          why(byName) & "; q=\"" & nameTerm & "\" matched=" & $nameMatched &
          ", returned " & $nameOpts)
    # `matched` and the returned count are two different numbers, and the
    # route exists to keep them apart: collapsing them is how the fifty-first
    # match is reported as "no such item".
    check("and it reports how many it really matched, not how many it sent",
          nameMatched >= nameOpts,
          "matched=" & $nameMatched & " is fewer than the " & $nameOpts &
          " options it returned, so one of the two numbers is invented")

    # -- SPAWN -------------------------------------------------------------
    let unitsBefore = unitsOf(listR.body, spProfAt, spTpl)
    var armed = setTarkovSetting("spawnQuery", "\"" & spTpl & "\"")
    armed = armed and setTarkovSetting("spawnCount", "2")
    armed = armed and setTarkovSetting("spawnCondition", "100")
    check("the four spawn rows accept an edit through the real settings route",
          armed, "one of spawnQuery/spawnCount/spawnCondition did not persist")

    if not armed:
      skip("the stash spawn", "the spawn rows would not arm, so a spawn " &
           "would be testing the settings route rather than the spawner")
    else:
      let fired = setTarkovSetting("spawnNow", "true")
      check("and flipping `spawnNow` is accepted as an action", fired,
            "the momentary spawn row refused the POST")

      # THE FINISHED STATE. Not "the POST returned ok" -- the profile is read
      # back from the server and asked whether the items are THERE. Every
      # earlier version of this feature could have passed a check on its own
      # return value while putting nothing in the stash, which is exactly the
      # report this section was written for.
      listR = call("/client/game/profile/list", "")
      spProfAt = profileOf(listR.body, uid)
      let unitsAfter = unitsOf(listR.body, spProfAt, spTpl)
      # `spawnResult` is quoted verbatim in the failure. The spawner declines
      # in several distinguishable ways and each writes its own sentence there;
      # a check that said only "nothing arrived" would send the reader back to
      # the server to find out which one, which is the whole cost this row
      # exists to remove.
      let afterRows = call(TarkovSettings, "")
      var said = ""
      let rAt = findAt(afterRows.body, "\"spawnResult\"", 0)
      if rAt >= 0:
        let vAt = findAt(afterRows.body, "\"value\":", rAt)
        if vAt >= 0:
          said = slice(afterRows.body, vAt + 8)
      check("two of that item are now in the stash, read back off the profile",
            unitsAfter == unitsBefore + 2,
            "held " & $unitsBefore & " before and " & $unitsAfter &
            " after asking for 2 more of " & spTpl &
            (if unitsAfter == unitsBefore:
               " -- the spawn answered but placed NOTHING. spawnResult said: " &
               said
             else: ""))

      # Placement, over the WHOLE stash rather than over the items this spawn
      # created: a spawn that lands on top of something that was already there
      # is the failure, and looking only at what we wrote cannot see it.
      let invAfter = memberValue(listR.body, spProfAt, "Inventory")
      let stashItems = elements(listR.body,
                                memberValue(listR.body, invAfter, "items"))
      let col = collisionsIn(listR.body, stashItems, tplSizes, "stash")
      check("no two items in the stash share one (slotId, location)",
            col.slotDupes == 0,
            $col.slotDupes & " colliding addresses over " &
            $stashItems.len & " items, first: " & col.slotSample)
      check("and no two items in a stash grid overlap, mod extensions included",
            col.cellOverlaps == 0,
            $col.cellOverlaps & " overlapping cells over " &
            $col.gridPlaced & " grid-placed items (" & $col.grownPlaced &
            " mod-grown), first: " & col.cellSample)

      # The parent chain. An item with a `parentId` naming nothing is invisible
      # in the client -- it is in the payload and not in any container -- which
      # reads to the player as the spawn having silently failed.
      var ids = initHashSet[string]()
      for it in stashItems:
        incl(ids, textField(listR.body, it, "_id"))
      var orphans = 0
      var orphanSample = ""
      for it in stashItems:
        let par = textField(listR.body, it, "parentId")
        if par.len > 0 and not contains(ids, par):
          inc orphans
          if orphanSample.len == 0:
            orphanSample = textField(listR.body, it, "_id") & " -> " & par
      check("and every item in the stash hangs off something that is there",
            orphans == 0,
            $orphans & " orphaned items, first: " & orphanSample)

      line "  spawned 2 x " & spTpl & " into a stash of " & $stashItems.len &
           " items (" & $col.gridPlaced & " grid-placed, " &
           $col.grownPlaced & " mod-grown)"

    # -- THE REFUSALS ------------------------------------------------------
    #
    # Each distinct way to decline says which one it was. A spawner that
    # accepts input and produces nothing is the defect being fixed, so the
    # messages are asserted, not just the absence of a crash.
    discard setTarkovSetting("spawnQuery", "\"\"")
    discard setTarkovSetting("spawnNow", "true")
    let emptyRows = call(TarkovSettings, "")
    check("an empty query is refused in writing, not silently ignored",
          findAt(emptyRows.body, "type part of an item name", 0) >= 0,
          "spawnResult does not explain what an empty query did")

    discard setTarkovSetting("spawnQuery", "\"zzqqxxnosuchitemzzqq\"")
    discard setTarkovSetting("spawnNow", "true")
    let noneRows = call(TarkovSettings, "")
    check("and a query that matches nothing says so by name",
          findAt(noneRows.body, "no item matches", 0) >= 0,
          "spawnResult does not report the no-match")

    # -- IN A RAID ---------------------------------------------------------
    #
    # THE VERDICT ON IN-RAID SPAWNING, ASSERTED RATHER THAN ASSUMED.
    #
    # The client plays a raid holding its own copy of the profile and posts it
    # back at `/client/match/local/end`, where `onMatchEnd` REPLACES the stored
    # document with it. So a server-side spawn during a raid is written into a
    # profile that is about to be discarded: the player sees nothing in the
    # raid, nothing in the stash afterwards, and a 200 on the wire throughout.
    #
    # The spawner therefore refuses while a raid is running. This asserts BOTH
    # halves -- that it refuses and says why, and that it works again once the
    # raid ends -- because a guard that never lifts is the same defect wearing
    # the opposite sign.
    if raidMap.len == 0:
      skip("the in-raid spawn guard", "no map was raidable in this database")
    else:
      discard setTarkovSetting("spawnQuery", "\"" & spTpl & "\"")
      discard setTarkovSetting("spawnCount", "1")
      listR = call("/client/game/profile/list", "")
      let heldBeforeRaid = unitsOf(listR.body, profileOf(listR.body, uid), spTpl)

      let rStart = call("/client/match/local/start",
                        "{\"location\":\"" & raidMap & "\"}")
      check("a raid can be started to test the spawner's raid guard",
            rStart.contains("serverId"), rStart.body)

      discard setTarkovSetting("spawnNow", "true")
      let raidRows = call(TarkovSettings, "")
      check("the spawner refuses mid-raid and names the raid as the reason",
            findAt(raidRows.body, "a raid is in progress", 0) >= 0,
            "spawnResult does not mention the raid; a mid-raid spawn that " &
            "says nothing is silently discarded at extract")

      # The negative that makes the refusal mean something: it must not have
      # spawned anyway. A message alone would be satisfied by a guard that
      # complains and then does the write regardless.
      listR = call("/client/game/profile/list", "")
      check("and nothing was written into the profile while it refused",
            unitsOf(listR.body, profileOf(listR.body, uid), spTpl) ==
              heldBeforeRaid,
            "the mid-raid spawn refused in words and placed items anyway")

      discard call("/client/match/local/end",
                   "{\"serverId\":\"" & raidMap &
                   "\",\"results\":{\"result\":\"Left\"}}")

      # The guard LIFTS. Without this the whole feature could be "permanently
      # broken" and every check above would still be green.
      discard setTarkovSetting("spawnNow", "true")
      listR = call("/client/game/profile/list", "")
      check("and once the raid ends the spawner works again",
            unitsOf(listR.body, profileOf(listR.body, uid), spTpl) ==
              heldBeforeRaid + 1,
            "held " & $heldBeforeRaid & " before the raid and " &
            $unitsOf(listR.body, profileOf(listR.body, uid), spTpl) &
            " after it ended -- the raid guard never lifted")

  if not keep:
    cSpawnKill(server)

  heading "What was exercised"
  line "  " & $(dbBytes div 1048576'i64) & " MiB database, boot to first answer " &
       $(bootUs div 1000'i64) & " ms"
  line "  " & $tplKeys.len & " templates, " & $hbItems.len &
       " handbook entries, " & $lk.len & " locale strings"
  line "  " & $traders.len & " traders, " & $assortItems & " assort items, " &
       $offers.len & " offers priced in roubles at loyalty 1"
  line "  " & $questKeys.len & " quests, " & $condCount & " conditions, " &
       $recipeList.len & " recipes, " & $areaTypes.len & " hideout areas"
  line "  " & $mapKeys.len & " maps, " & $lootItems & " loot items over " &
       $lootMaps & " of them"
  line "  " & $botRoles & " bot roles, " & $botVariants & " health variants, " &
       $botHeadKinds & " distinct heads over 20 " &
       (if botRole.len > 0: botRole else: "bot") & " bots"
  line "  largest response: " & gLargest & ", " & kib(gLargestBytes)
  line "  slowest request: " & gSlowest & ", " & $(gSlowestUs div 1000'i64) &
       " ms"

  heading "Result"
  if gFailures > 0:
    err $gFailures & " of " & $gChecks & " checks failed (" & $gSkipped &
        " skipped)"
    return 1
  ok "the emulator answered all " & $gChecks & " checks against real data (" &
     $gSkipped & " skipped)"
  result = 0

quit(main())
