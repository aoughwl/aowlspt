## soak -- drive the Tarkov emulator through a long session and check the
## invariants that a single request cannot break.
##
##     soak --root <stage> --port 6976 --backend <aowlspt-backend.exe> --cycles 40
##
## `emutest` proves the emulator answers. This proves it keeps answering *the
## same profile* after a hundred raids. The two are complementary and neither
## replaces the other:
##
## | | `emutest` | `soak` |
## |---|---|---|
## | asks | did this request answer correctly | is the world still consistent |
## | fails on | a wrong response | a right response that left damage behind |
## | catches | a broken endpoint | duplication, orphans, leaks, lost money |
##
## The bugs that matter in a game server are almost never "the endpoint
## returned the wrong field". They are "the endpoint returned exactly the right
## field and also left a second copy of the item in the stash", and no single
## response is wrong enough to see that. It takes the *next* request to notice,
## and often the hundredth.
##
## So every check here is an assertion about the profile or the store as a
## whole, made after a cycle of ordinary play, and phrased so that it can only
## fail when something is actually broken. Five of them:
##
## **No item id appears twice.** The single worst class of bug in an inventory
## server and the cheapest one to check. A duplicated id is an item the player
## can sell twice, and it is also a profile the client renders as one item that
## behaves like two.
##
## **No orphans.** Every item's `parentId` names something in the same list (or
## the item is the stash root and has none). An orphan is not a cosmetic
## problem: the client walks the tree from the stash down, so an item whose
## parent is missing either vanishes or takes the load with it.
##
## **Money is conserved.** A trade moves an exact amount out of the currency
## stacks and no stack ever goes negative. Checked as an exact difference, not
## as "less than before" -- a server that charges the handbook price instead of
## the price it quoted still charges *less than before*.
##
## **The profile does not grow when nothing happens.** A raid that changes
## nothing is the control: the document must come back the same size. A profile
## that gains bytes per raid is a profile that eventually stops loading, and it
## is invisible until it is fatal.
##
## **The store does not grow without bound.** Mail, insurance and flea keys are
## created as they are needed and must be reclaimed as they are consumed. The
## store is a directory of files, so this is a file count and a byte count and
## there is nothing to interpret.
##
## A soak failure has to say which cycle and what the profile looked like at the
## time, because "invariant broken" with no context is a bug report nobody can
## act on. Every failure below carries the cycle number, the request that
## preceded it and a slice of the offending document.

import std/[strutils, syncio, cmdline, sets]
import aowlsptinstall/[winfs, log]
import wire

{.emit: """#include <stdlib.h>""".}
{.emit: """#include <string.h>""".}
{.emit: """#include "aowlspt_shim.h" """.}
{.emit: """#include "aowlspt_net.h" """.}
{.emit: """#include "aowlspt_inject.h" """.}

proc cSpawn(exe, workDir, cmdLine: cstring): uint64 {.
  importc: "aowl_spawn", nodecl.}
proc cSpawnKill(h: uint64) {.importc: "aowl_spawn_kill", nodecl.}
proc cSleepMs(ms: int32) {.importc: "aowl_sys_sleep", nodecl.}

const
  Usage = """
soak -- long-session invariant test for the Tarkov emulator

  soak --root PATH --backend PATH [--port N] [--cycles N]

  --root PATH      the scratch install (mods/, db.json); its store must be empty
  --backend PATH   aowlspt-backend.exe
  --port N         port to serve on (default 6976)
  --cycles N       how many play cycles to run (default 24)
  --every N        print a metrics row every N cycles (default 4)
  --keep           leave the backend running at the end
  -h, --help       this
"""
  Session = "aaaaaaaaaaaaaaaaaaaaaaaa"
  Roubles = "5449016a4bdc2d6f028b456f"
  Trader = "54cb50c76803fa8b248b4571"
  Assort = "aaaaaaaaaaaaaaaaaaaaaaa1"
  Rifle = "5644bd2b4bdc2d3b4c8b4572"

var gFailures = 0
var gChecks = 0
var gPort = 6976
var gRoot = ""
var gCycle = 0
var gLastRequest = ""

proc check(what: string; condition: bool; detail = "") =
  ## Every failure is stamped with the cycle and the request that preceded it.
  ## A soak test that says "duplicate id" and nothing else has told the reader
  ## that there is a bug and nothing about where to look for it.
  inc gChecks
  if condition:
    return
  err "cycle " & $gCycle & ": " & what
  if gLastRequest.len > 0:
    note "  after: " & gLastRequest
  if detail.len > 0:
    note "  " & detail
  inc gFailures

proc pass(what: string) =
  inc gChecks
  ok what

proc call(path, body: string): Response =
  gLastRequest = path & " " & (if body.len > 220: body.substr(0, 220) & "..."
                               else: body)
  result = request(gPort, path, body, Session)

# ------------------------------------------------------------------ reading
#
# The same shell-script-grade readers `emutest` uses, for the same reason: this
# tool wants a handful of fields out of a document whose full parse is
# available to mods and not to a test binary. Where a reader here differs from
# `emutest`'s it is because a soak run reads the *whole* item list rather than
# one field, and the difference is called out at the reader.

proc findFrom(haystack, needle: string; start: int): int =
  if start >= haystack.len:
    return -1
  let at = find(haystack.substr(start), needle)
  if at < 0:
    return -1
  result = start + at

proc textAt(body: string; start: int; key: string): string =
  let at = findFrom(body, "\"" & key & "\":\"", start)
  if at < 0:
    return ""
  var i = at + key.len + 4
  result = ""
  while i < body.len and body[i] != '"':
    result.add body[i]
    inc i

proc jsonText(body, key: string): string = textAt(body, 0, key)

proc numberAt(body: string; start: int; key: string): int =
  let at = findFrom(body, "\"" & key & "\":", start)
  if at < 0:
    return -1
  var i = at + key.len + 3
  var neg = false
  if i < body.len and body[i] == '-':
    neg = true
    inc i
  var v = 0
  var any = false
  while i < body.len and body[i] >= '0' and body[i] <= '9':
    v = v * 10 + (ord(body[i]) - ord('0'))
    any = true
    inc i
  if not any:
    return -1
  result = if neg: -v else: v

proc jsonNumber(body, key: string): int = numberAt(body, 0, key)

proc spanFrom(body: string; start: int; opening, closing: char): string =
  ## The balanced `{...}` or `[...]` beginning at `start`, string-aware.
  ##
  ## String-aware matters more here than anywhere else in this file: item names
  ## and locale strings in a real database contain braces and brackets, and a
  ## naive depth counter cuts the item list short at the first one. A truncated
  ## item list makes every item after the cut look like an orphan -- which is a
  ## soak failure that describes the reader rather than the server.
  if start < 0 or start >= body.len:
    return ""
  var depth = 0
  var i = start
  var inString = false
  while i < body.len:
    let c = body[i]
    if inString:
      if c == '\\':
        inc i
      elif c == '"':
        inString = false
    elif c == '"':
      inString = true
    elif c == opening:
      inc depth
    elif c == closing:
      dec depth
      if depth == 0:
        return body.substr(start, i)
    inc i
  result = ""

type
  Item = object
    id: string
    parent: string
    tpl: string
    slot: string
    count: int

proc itemsArray(profileDoc: string): string =
  ## The text of `Inventory.items`, brackets included.
  ##
  ## Anchored at `"Inventory"` rather than at the first `"items":[` in the
  ## document: a profile also carries `Hideout.Production` items, mail
  ## attachments and quest reward items, and a check that swept all of them
  ## would report a "duplicate" every time the same item appeared in two places
  ## it is legitimately allowed to appear in.
  let inv = find(profileDoc, "\"Inventory\":")
  if inv < 0:
    return ""
  let at = findFrom(profileDoc, "\"items\":[", inv)
  if at < 0:
    return ""
  result = spanFrom(profileDoc, at + 8, '[', ']')

proc parseItems(arrayText: string): seq[Item] =
  ## Every top-level object of the item array. Depth-aware rather than split on
  ## `},{`: an item with an `upd` or a `location` has nested objects, and
  ## splitting on the punctuation would make one item out of two.
  result = @[]
  if arrayText.len < 2:
    return
  var i = 1
  while i < arrayText.len:
    while i < arrayText.len and (arrayText[i] == ',' or arrayText[i] == ' ' or
                                 arrayText[i] == '\n' or arrayText[i] == '\r' or
                                 arrayText[i] == '\t'):
      inc i
    if i >= arrayText.len or arrayText[i] != '{':
      break
    let one = spanFrom(arrayText, i, '{', '}')
    if one.len == 0:
      break
    var it = Item(id: jsonText(one, "_id"), parent: jsonText(one, "parentId"),
                  tpl: jsonText(one, "_tpl"), slot: jsonText(one, "slotId"),
                  count: 1)
    let n = jsonNumber(one, "StackObjectsCount")
    if n >= 0:
      it.count = n
    result.add it
    i = i + one.len

proc moneyTotal(items: seq[Item]): int =
  ## Every rouble in the profile, added up across stacks.
  ##
  ## Across stacks and not "the stack we know about", because that is the whole
  ## point: a server that pays 25,000 by rewriting one stack to 475,000 and
  ## dropping the other two passes a single-stack check and has just destroyed
  ## most of the player's money.
  result = 0
  for it in items:
    if it.tpl == Roubles:
      result = result + it.count

proc idOfTemplate(items: seq[Item]; tpl: string): string =
  result = ""
  for it in items:
    if it.tpl == tpl:
      return it.id

proc firstFew(items: seq[Item]; n: int): string =
  ## A readable slice of the item list for a failure message. Ids and templates
  ## only -- the whole document is megabytes and pasting it into a log is the
  ## same as pasting nothing.
  result = ""
  var i = 0
  for it in items:
    if i >= n:
      break
    if i > 0:
      result.add ", "
    result.add it.id & "/" & it.tpl
    inc i

# ---------------------------------------------------------------- the store
#
# The store is a directory of files, one per key, so "is the store leaking" is
# a file count and a byte count. Nothing here parses a key: the point is the
# shape of the curve, and a reader that understood the keys would only be able
# to check the leaks it already knew about.

proc storeSize(root: string; files: var int): int64 =
  result = 0'i64
  files = 0
  let dir = joinPath(root, "store")
  if not exists(dir):
    return
  var fs: seq[string] = @[]
  var ds: seq[string] = @[]
  collectEntries(dir, fs, ds)
  for f in fs:
    let n = fileSizeOf(joinPath(dir, f))
    if n > 0'i64:
      result = result + n
    inc files

# ------------------------------------------------------------- invariants
#
# Each of these runs after every cycle. They are deliberately cheap: an
# invariant that costs a second per cycle is one nobody runs for a hundred
# cycles, and an invariant nobody runs is not an invariant.

proc checkNoDuplicates(items: seq[Item]) =
  ## No id twice. Reported with *both* copies' templates, because the same id on
  ## two different templates is a different bug from the same id on two copies
  ## of one item -- the first is an id generator that collided, the second is a
  ## give-item path that ran twice.
  var seen = initHashSet[string]()
  var dupes = ""
  var n = 0
  for it in items:
    if it.id.len == 0:
      continue
    if containsOrIncl(seen, it.id):
      if n < 5:
        if n > 0: dupes.add ", "
        dupes.add it.id & " (" & it.tpl & ")"
      inc n
  check("no item id appears twice", n == 0,
        $n & " duplicated: " & dupes)

proc checkNoOrphans(items: seq[Item]) =
  ## Every parentId names an item in the same list. The stash root and the
  ## equipment roots legitimately have no parent, so an absent parent passes;
  ## a parent that is *named and missing* is the failure.
  var ids = initHashSet[string]()
  for it in items:
    if it.id.len > 0:
      incl(ids, it.id)
  var orphans = ""
  var n = 0
  for it in items:
    if it.parent.len == 0:
      continue
    if not contains(ids, it.parent):
      if n < 5:
        if n > 0: orphans.add ", "
        orphans.add it.id & " -> missing parent " & it.parent &
                    " (slot " & it.slot & ")"
      inc n
  check("no item has a parent that is not in the list", n == 0,
        $n & " orphaned: " & orphans)

proc checkNoNegativeStacks(items: seq[Item]) =
  ## A stack of -3 roubles is money created out of nothing on the next merge,
  ## and it is the shape a "take payment" bug leaves behind when it subtracts
  ## from the wrong stack. The client shows it as a stack of zero, so a player
  ## never reports it.
  var bad = ""
  var n = 0
  for it in items:
    if it.count < 0:
      if n < 5:
        if n > 0: bad.add ", "
        bad.add it.id & " (" & it.tpl & ") = " & $it.count
      inc n
  check("no stack holds a negative count", n == 0, $n & " negative: " & bad)

proc invariants(items: seq[Item]) =
  checkNoDuplicates(items)
  checkNoOrphans(items)
  checkNoNegativeStacks(items)
