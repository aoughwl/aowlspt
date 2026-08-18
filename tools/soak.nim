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

proc between(body, opening, closing: string): string =
  ## The text between two markers. One array out of a response without parsing
  ## the rest of it -- the flea's rows have to be read apart from its category
  ## counts, which are counted before the filter is applied.
  let a = find(body, opening)
  if a < 0:
    return ""
  let start = a + opening.len
  let b = findFrom(body, closing, start)
  if b < 0:
    return ""
  result = body.substr(start, b - 1)

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

# ---------------------------------------------------------------- documents
#
# A soak run has to *write* profile documents, not only read them. The client
# hands the whole profile back at the end of a raid and the server takes it, so
# "came back from a raid with something" is expressed the way the client
# expresses it: the same document, with one item added. Anything else would be
# testing a path the game does not use.

proc hexDigit(v: int): char =
  const D = "0123456789abcdef"
  result = D[v and 15]

proc mkId(tag: string; n: int): string =
  ## A 24-character MongoId that is unique per (tag, n) and readable in a
  ## failure message. Readable matters: when a duplicate is reported as
  ## `loot0000000000000000001f` the reader knows immediately that it came from
  ## cycle 31's loot injection and not from the trader.
  result = tag
  var digits = ""
  var v = n
  var i = 0
  while i < 6:
    digits = $hexDigit(v) & digits
    v = v shr 4
    inc i
  while result.len + digits.len < 24:
    result.add "0"
  result.add digits
  if result.len > 24:
    result = result.substr(0, 23)

proc profileOf(listBody, uid: string): string =
  ## One profile object, cut whole out of a `profile/list` response.
  ##
  ## Cut rather than rebuilt, because the point of every raid below is that the
  ## server accepts the *client's own* document. A tidy document this tool made
  ## up would test a shape the client never sends.
  let at = find(listBody, "{\"_id\":\"" & uid & "\"")
  if at < 0:
    return ""
  result = spanFrom(listBody, at, '{', '}')

proc stashOf(profileDoc: string): string =
  let inv = find(profileDoc, "\"Inventory\":")
  if inv < 0:
    return ""
  result = textAt(profileDoc, inv, "stash")

proc withItem(profileDoc, itemJson: string): string =
  ## The profile with one more item at the head of `Inventory.items`.
  ##
  ## At the head rather than the tail so that the injected item is *not* the
  ## last thing in the array: a server that appends the client's items without
  ## reading them would still pass a check whose item happened to be last, and
  ## an off-by-one in the array walk shows up at the head far more often.
  let inv = find(profileDoc, "\"Inventory\":")
  if inv < 0:
    return profileDoc
  let at = findFrom(profileDoc, "\"items\":[", inv)
  if at < 0:
    return profileDoc
  let open = at + 8
  var tail = profileDoc.substr(open + 1)
  var sep = ""
  var k = 0
  while k < tail.len and (tail[k] == ' ' or tail[k] == '\n' or tail[k] == '\r' or
                          tail[k] == '\t'):
    inc k
  if k < tail.len and tail[k] != ']':
    sep = ","
  result = profileDoc.substr(0, open) & itemJson & sep & tail

proc shiftNumber(doc: string; fromAt: int; key: string; delta: int): string =
  ## `"key":n` at or after `fromAt`, rewritten as `n + delta`. "" is never
  ## returned: a document with no such key comes back unchanged, and the caller
  ## checks the effect rather than the edit.
  let at = findFrom(doc, "\"" & key & "\":", fromAt)
  if at < 0:
    return doc
  let start = at + key.len + 3
  var i = start
  var v = 0
  while i < doc.len and doc[i] >= '0' and doc[i] <= '9':
    v = v * 10 + (ord(doc[i]) - ord('0'))
    inc i
  if i == start:
    return doc
  result = doc.substr(0, start - 1) & $(v + delta) & doc.substr(i)

proc lootItem(id, tpl, stash: string; x, y: int): string =
  ## An item the way the client writes one it picked up: a real parent, a real
  ## slot and a real cell. Not a bare `{_id,_tpl}` -- the server places
  ## *its* gifts on a free cell and has every right to expect the client's to
  ## carry one, and an item with no position is an item that cannot be picked
  ## up again.
  result = "{\"_id\":\"" & id & "\",\"_tpl\":\"" & tpl &
           "\",\"parentId\":\"" & stash & "\",\"slotId\":\"hideout\"," &
           "\"location\":{\"x\":" & $x & ",\"y\":" & $y &
           ",\"r\":\"Horizontal\"}}"

# ------------------------------------------------------------------ metrics
#
# Three numbers per cycle and nothing else. A leak is a line that only goes up,
# and that is visible in a column of integers without any analysis; anything
# cleverer would be a statistic nobody trusts at three in the morning.

var mCycle: seq[int] = @[]
var mProfileBytes: seq[int] = @[]
var mStoreBytes: seq[int] = @[]
var mStoreFiles: seq[int] = @[]
var mItems: seq[int] = @[]
var mMoney: seq[int] = @[]
var mUsAvg: seq[int] = @[]
var mUsMax: seq[int] = @[]

var gUsSum = 0'i64
var gUsMax = 0'i64
var gUsCount = 0

proc timed(path, body: string): Response =
  result = call(path, body)
  if result.ok:
    gUsSum = gUsSum + result.ttfbUs
    if result.ttfbUs > gUsMax:
      gUsMax = result.ttfbUs
    inc gUsCount

proc resetTiming() =
  gUsSum = 0'i64
  gUsMax = 0'i64
  gUsCount = 0

# ----------------------------------------------------------------- the play
#
# One cycle is one session's worth of ordinary play, arranged so that it ends
# where it started. That is the whole design: a cycle that leaves the profile
# in a different state each time cannot distinguish "the game progressed" from
# "the server leaked", and every check below would have to be a trend rather
# than an equality. A closed loop turns all of them into equalities.

const
  Salewa = "544fb45d4bdc2dee738b4568"
  Water = "5448ff904bdc2d6f028b456e"
  Bolts = "59e35de086f7741778269d83"
  SalewaAssort = "aaaaaaaaaaaaaaaaaaaaaaa2"
  QuickRecipe = "recipe-quick"
  WorkbenchArea = 10
  ListPrice = 5000

proc profileList(): string =
  result = timed("/client/game/profile/list", "").body

proc itemsNow(): seq[Item] =
  result = parseItems(itemsArray(profileList()))

proc countOfId(items: seq[Item]; id: string): int =
  result = 0
  for it in items:
    if it.id == id:
      inc result

proc countOfTpl(items: seq[Item]; tpl: string): int =
  result = 0
  for it in items:
    if it.tpl == tpl:
      inc result

proc biggestRoubleStack(items: seq[Item]; id: var string): int =
  ## The fattest rouble stack, for paying out of. Named explicitly in every
  ## payment below rather than left to the server to choose, because that is
  ## what the client does -- the player drags a stack onto the price -- and a
  ## server that ignores the named stack and pays out of another one is the
  ## exact bug the money invariant is here for.
  result = 0
  id = ""
  for it in items:
    if it.tpl == Roubles and it.count > result:
      result = it.count
      id = it.id

proc moving(actions: string): Response =
  result = timed("/client/game/profile/items/moving",
                 "{\"data\":[" & actions & "],\"tm\":2,\"reload\":0}")

proc warned(r: Response; text: string): bool =
  ## A refusal on this endpoint is a warning inside a 200, not an error status.
  ## Checking `err != 0` would find nothing at all -- the batch always succeeds.
  result = r.contains(text)

var gUid = ""
var gStash = ""
var gBaselineItems = -1
var gNullGrowth = 0
var gRedeemCarried = 0

proc endRaid(doc: string; outcome: string): Response =
  result = timed("/client/match/local/end",
                 "{\"exit\":\"" & outcome & "\",\"profile\":" & doc & "}")

proc enterRaid() =
  ## The four requests the client makes on the way in. Sent every cycle rather
  ## than once, because a leak in the raid path is a leak per raid: the loot
  ## generator and the raid id are the things most likely to accumulate, and a
  ## soak that only entered one raid would never see it.
  discard timed("/client/raid/configuration",
    "{\"location\":\"testmap\",\"timeVariant\":\"CURR\"," &
    "\"raidMode\":\"Local\",\"side\":\"Pmc\",\"profileId\":\"" & gUid & "\"}")
  discard timed("/client/location/getLocalloot",
    "{\"locationId\":\"testmap\",\"variantId\":0}")
  discard timed("/client/weather", "")
  discard timed("/client/match/local/start", "{\"location\":\"testmap\"}")

proc nullRaid() =
  ## The control. A raid in which the client hands back exactly the document it
  ## was given must leave the profile exactly the size it was.
  ##
  ## This is the check that catches unbounded growth, and it is worth more than
  ## the item-count check beside it because it catches growth in the parts of
  ## the profile no test names: a `Stats` array that gains an entry per raid, a
  ## `TaskConditionCounters` that is appended to rather than replaced, a
  ## `Skills.Common` that gets a second copy of the same skill. All three are
  ## real shapes, all three are invisible in the response, and all three end as
  ## a profile the client takes a minute to load and then refuses.
  let before = profileList()
  let doc = profileOf(before, gUid)
  if doc.len < 100:
    check("the played profile could be cut out of the list", false,
          $doc.len & " bytes")
    return
  enterRaid()
  let r = endRaid(doc, "Survived")
  check("a raid that changed nothing is accepted", r.ok and r.contains("\"err\":0"),
        r.body)
  let after = profileOf(profileList(), gUid)
  let grew = after.len - doc.len
  gNullGrowth = gNullGrowth + (if grew > 0: grew else: 0)
  # 16 bytes of slack and not zero: the profile carries timestamps, and one
  # rolling over from nine digits to ten is a byte the server is entitled to.
  # Anything a leak does is orders of magnitude larger than that -- an appended
  # item is ~120 bytes, an appended counter ~60.
  check("a raid that changed nothing did not grow the profile", grew <= 16,
        $doc.len & " -> " & $after.len & " bytes (+" & $grew & ")")

proc lootRaid(cycle: int): string =
  ## Coming home with something. Returns the id of what was brought back, or ""
  ## when the raid was not accepted.
  let before = profileList()
  var doc = profileOf(before, gUid)
  if doc.len < 100:
    check("the played profile could be cut out of the list", false,
          $doc.len & " bytes")
    return ""
  let id = mkId("d00d", cycle)
  # The bottom-right corner of the stash. Deliberately the *last* cell a
  # first-fit scan would reach, so that a server which places its own gifts by
  # scanning from the top left has to actually read this item to avoid it --
  # an occupancy map built from a truncated item list would put the next gift
  # straight on top of it.
  doc = withItem(doc, lootItem(id, Water, gStash, 9, 66))
  enterRaid()
  let r = endRaid(doc, "Survived")
  check("a raid that brought something home is accepted",
        r.ok and r.contains("\"err\":0"), r.body)
  let items = itemsNow()
  # Exactly one, not "present". A raid-end path that merges the client's items
  # into the stored ones rather than replacing them gives two copies of every
  # item the client sent, and "present" passes against that perfectly.
  check("what was brought home is in the stash exactly once",
        countOfId(items, id) == 1,
        $countOfId(items, id) & " copies of " & id)
  result = id

proc sellTo(itemId: string; expectPaid: int; what: string) =
  ## Selling, and the money check on the way out.
  ##
  ## The exact amount, summed over every rouble stack in the profile. A server
  ## that pays by rewriting one stack to the new total and dropping the others
  ## passes "the player has more money than before" and has just destroyed the
  ## rest of it.
  let before = itemsNow()
  let had = moneyTotal(before)
  let r = moving("{\"Action\":\"TradingConfirm\",\"type\":\"sell_to_trader\"," &
    "\"tid\":\"" & Trader & "\",\"items\":[{\"id\":\"" & itemId &
    "\",\"count\":1,\"scheme_id\":0}]}")
  check("selling " & what & " is accepted", r.ok, r.body)
  let after = itemsNow()
  check("selling " & what & " paid exactly the handbook price",
        moneyTotal(after) - had == expectPaid,
        $had & " -> " & $moneyTotal(after) & ", expected +" & $expectPaid)
  check("and the sold " & what & " left the stash",
        countOfId(after, itemId) == 0, itemId & " is still there")

proc buySalewa(): string =
  ## Buying, and the money check on the way in. Returns the id of what arrived.
  let before = itemsNow()
  let had = moneyTotal(before)
  var payFrom = ""
  discard biggestRoubleStack(before, payFrom)
  if payFrom.len == 0:
    check("there is money to buy with", false, "no rouble stack in the profile")
    return ""
  let r = moving("{\"Action\":\"TradingConfirm\",\"type\":\"buy_from_trader\"," &
    "\"tid\":\"" & Trader & "\",\"item_id\":\"" & SalewaAssort &
    "\",\"count\":1,\"scheme_id\":0,\"scheme_items\":[{\"id\":\"" & payFrom &
    "\",\"count\":1200}]}")
  check("buying from the trader is accepted", r.ok, r.body)
  let after = itemsNow()
  check("and it cost exactly what the assort asked",
        had - moneyTotal(after) == 1200,
        $had & " -> " & $moneyTotal(after) & ", expected -1200")
  check("and exactly one arrived", countOfTpl(after, Salewa) == 1,
        $countOfTpl(after, Salewa) & " of them")
  result = idOfTemplate(after, Salewa)

proc craft() =
  ## Start a craft, collect it, and try to collect it again.
  ##
  ## The second collection is the check worth having. A craft that can be
  ## collected twice is free items forever, it leaves no trace in any single
  ## response, and it is the exact failure a soak test exists to find -- the
  ## first collection is correct and the damage is what it left behind.
  let before = itemsNow()
  let had = moneyTotal(before)
  let started = moving("{\"Action\":\"HideoutSingleProductionStart\"," &
                       "\"recipeId\":\"" & QuickRecipe & "\"}")
  check("a craft can be started", started.ok and
        not warned(started, "already running") and
        not warned(started, "no such recipe"), started.body)
  let mid = itemsNow()
  # Three roubles, taken out of stacks. Small on purpose: a craft that took its
  # inputs out of the wrong stack, or took them twice, shows up as a difference
  # of exactly three or exactly six, and a big number would hide both in the
  # noise of the trades around it.
  check("starting it took exactly its inputs", had - moneyTotal(mid) == 3,
        $had & " -> " & $moneyTotal(mid) & ", expected -3")

  let took = moving("{\"Action\":\"HideoutTakeProduction\",\"recipeId\":\"" &
                    QuickRecipe & "\"}")
  check("and it can be collected", took.ok and
        not warned(took, "not finished") and
        not warned(took, "nothing is being made"), took.body)
  let after = itemsNow()
  check("the craft's output is in the stash", countOfTpl(after, Bolts) >= 1,
        "no " & Bolts & " after collecting")

  let again = moving("{\"Action\":\"HideoutTakeProduction\",\"recipeId\":\"" &
                     QuickRecipe & "\"}")
  check("a second collection is refused", warned(again, "nothing is being made"),
        again.body)
  let twice = itemsNow()
  # The refusal *and* the absence of a second output, because a refusal alone
  # passes against a server that both refused and paid out.
  check("and it produced nothing the second time",
        countOfTpl(twice, Bolts) == countOfTpl(after, Bolts),
        $countOfTpl(after, Bolts) & " -> " & $countOfTpl(twice, Bolts))

  # And thrown away, so the cycle ends where it began. Without this the bolts
  # accumulate, the item count climbs for a legitimate reason, and the
  # steady-state check below would have to be a trend instead of an equality --
  # which is exactly the kind of weakened assertion a soak test cannot afford.
  let boltId = idOfTemplate(twice, Bolts)
  if boltId.len > 0:
    let binned = moving("{\"Action\":\"Remove\",\"item\":\"" & boltId & "\"}")
    check("the output can be thrown away again", binned.ok, binned.body)
    check("and it is gone", countOfId(itemsNow(), boltId) == 0, boltId)

proc offerIdFor(price: int): string =
  ## This profile's own listing, found on the flea by the price it was listed
  ## at. Found rather than remembered, because the offer id is minted by the
  ## server and the client only ever learns it by searching -- and a soak test
  ## that kept its own copy would not notice a server that minted a different
  ## one from the one it stored.
  let r = timed("/client/ragfair/find",
    "{\"page\":0,\"limit\":50,\"handbookId\":\"" & Salewa &
    "\",\"priceFrom\":" & $(price - 1) & ",\"priceTo\":" & $(price + 1) & "}")
  let rows = between(r.body, "\"offers\":[", "\"offersCount\"")
  result = textAt(rows, 0, "_id")

proc fleaAndMail(salewaId: string) =
  ## List it, take it back down, and collect it out of the post.
  ##
  ## The round trip is the point. Listing takes the item out of the stash, and
  ## withdrawing puts it in the mailbox rather than back in the stash -- so a
  ## cycle that lists and withdraws touches the flea store, the mailbox store
  ## and the redemption path, and must end with the item back where it started
  ## and in the stash exactly once.
  if salewaId.len == 0:
    return
  let listed = moving("{\"Action\":\"RagFairAddOffer\",\"sellInOnePiece\":false," &
    "\"items\":[\"" & salewaId & "\"],\"requirements\":[{\"_tpl\":\"" &
    Roubles & "\",\"count\":" & $ListPrice & "}]}")
  check("listing on the flea is accepted",
        listed.ok and not warned(listed, "not here"), listed.body)
  # It has to *leave*. An item that is both listed and in the stash can be sold
  # twice, which is the duplication bug wearing a different hat.
  check("and the listed item left the stash",
        countOfId(itemsNow(), salewaId) == 0, salewaId & " is still in the stash")

  let offerId = offerIdFor(ListPrice)
  check("the listing is on the flea", offerId.len == 24, "offer id " & offerId)
  if offerId.len != 24:
    return

  let pulled = moving("{\"Action\":\"RagFairRemoveOffer\",\"offerId\":\"" &
                      offerId & "\"}")
  check("the listing can be taken down",
        pulled.ok and not warned(pulled, "no offer"), pulled.body)
  check("and the offer is off the flea", offerIdFor(ListPrice).len == 0,
        "it is still listed")

  # Out of the post and back into the stash, keeping its id.
  let post = timed("/client/mail/dialog/getAllAttachments", "")
  let msg = jsonText(post.body, "_id")
  check("the withdrawn item is in the post", msg.len > 0 and
        find(post.body, salewaId) >= 0, post.body)
  let took = moving("{\"Action\":\"Move\",\"item\":\"" & salewaId &
    "\",\"fromOwner\":{\"id\":\"" & msg & "\",\"type\":\"Mail\"}," &
    "\"to\":{\"id\":\"" & gStash & "\",\"container\":\"hideout\"}}")
  check("it can be collected out of the post", took.ok, took.body)
  let back = itemsNow()
  check("and it came back with the id it went out with",
        countOfId(back, salewaId) == 1,
        $countOfId(back, salewaId) & " copies of " & salewaId)

  # The replay. A retried batch, a client that sent it twice, a crash between
  # the two writes -- all of them look like this, and all of them must produce
  # one item. The refusal message is *not* what is checked: the emulator
  # answers a second redemption with success and a warning on purpose, so a
  # check on the message would pass against a server that also gave the item.
  let replay = moving("{\"Action\":\"Move\",\"item\":\"" & salewaId &
    "\",\"fromOwner\":{\"id\":\"" & msg & "\",\"type\":\"Mail\"}," &
    "\"to\":{\"id\":\"" & gStash & "\",\"container\":\"hideout\"}}")
  discard replay
  let twice = itemsNow()
  check("collecting the same reward twice gives one item",
        countOfId(twice, salewaId) == 1,
        $countOfId(twice, salewaId) & " copies of " & salewaId)
  if countOfId(twice, salewaId) == 1:
    inc gRedeemCarried

proc questAgain() =
  ## The same quest accepted every cycle. The first one takes; every one after
  ## it must be refused *and must not append a second entry* -- a quest array
  ## that gains a duplicate per accept is a profile that grows without bound
  ## and a quest whose conditions are evaluated twice.
  let r = moving("{\"Action\":\"QuestAccept\",\"qid\":\"q_debut\"}")
  discard r
  let doc = profileOf(profileList(), gUid)
  var n = 0
  var i = 0
  while true:
    let at = findFrom(doc, "\"qid\":\"q_debut\"", i)
    if at < 0: break
    inc n
    i = at + 10
  check("an accepted quest appears exactly once however often it is accepted",
        n == 1, $n & " entries for q_debut")

# ------------------------------------------------------------------- a cycle

proc pad(s: string; n: int): string =
  result = s
  while result.len < n:
    result.add " "

proc padLeft(s: string; n: int): string =
  result = s
  while result.len < n:
    result = " " & result

proc row(cycle, profileBytes, items, money, storeBytes, storeFiles,
         usAvg, usMax: int) =
  line "  " & padLeft($cycle, 5) & padLeft($profileBytes, 10) &
       padLeft($items, 7) & padLeft($money, 11) & padLeft($storeBytes, 10) &
       padLeft($storeFiles, 6) & padLeft($usAvg, 9) & padLeft($usMax, 9)

proc header() =
  line "  " & padLeft("cycle", 5) & padLeft("profile", 10) &
       padLeft("items", 7) & padLeft("money", 11) & padLeft("store", 10) &
       padLeft("files", 6) & padLeft("us avg", 9) & padLeft("us max", 9)

proc measure(cycle: int) =
  let doc = profileOf(profileList(), gUid)
  let items = parseItems(itemsArray(doc))
  var files = 0
  let bytes = storeSize(gRoot, files)
  mCycle.add cycle
  mProfileBytes.add doc.len
  mItems.add items.len
  mMoney.add moneyTotal(items)
  mStoreBytes.add int(bytes)
  mStoreFiles.add files
  let avg = if gUsCount > 0: int(gUsSum div int64(gUsCount)) else: 0
  mUsAvg.add avg
  mUsMax.add int(gUsMax)

proc runCycle(cycle: int) =
  gCycle = cycle
  resetTiming()

  nullRaid()
  let loot = lootRaid(cycle)
  if loot.len > 0:
    sellTo(loot, 15000, "what came home")
  craft()
  let salewa = buySalewa()
  fleaAndMail(salewa)
  questAgain()
  if salewa.len > 0:
    sellTo(salewa, 1100, "the medkit")

  let items = itemsNow()
  invariants(items)

  # The cycle closed. Every purchase was sold, every craft was thrown away and
  # every listing was withdrawn and collected, so the item count must be the
  # number it was after the first cycle. This is the strongest single check in
  # the tool: any path that leaves one item behind per cycle fails it on the
  # cycle after the one that introduced it, rather than on the day someone
  # notices their stash is full of ghosts.
  if gBaselineItems < 0:
    gBaselineItems = items.len
    note "steady state is " & $items.len & " items"
  else:
    check("the item count came back to its steady state",
          items.len == gBaselineItems,
          $gBaselineItems & " -> " & $items.len & ": " &
          firstFew(items, 12))
  measure(cycle)

# --------------------------------------------------------------------- main

proc waitForBackend(tries: int): bool =
  var i = 0
  while i < tries:
    let r = request(gPort, "/client/game/config", "", Session)
    if r.ok and r.contains("\"err\":0"):
      return true
    cSleepMs(200'i32)
    inc i
  result = false

proc startBackend(exe, root: string): uint64 =
  var e = exe
  var w = root
  var c = "\"" & exe & "\" --root \"" & root & "\" --port " & $gPort
  result = cSpawn(toCString(e), toCString(w), toCString(c))

proc parseIntArg(s: string; into: var int) =
  var v = 0
  var any = false
  for ch in s:
    if ch >= '0' and ch <= '9':
      v = v * 10 + (ord(ch) - ord('0'))
      any = true
  if any: into = v

proc trend(name: string; xs: seq[int]) =
  ## First, last and the biggest step. A leak is "last is much larger than
  ## first"; a *sawtooth* -- something that grows and is reclaimed -- has a
  ## large step and a small difference, and telling those two apart is the
  ## whole reason the step is printed next to the difference.
  if xs.len < 2:
    return
  var worst = 0
  var at = 0
  for i in 1 ..< xs.len:
    let d = xs[i] - xs[i - 1]
    if d > worst:
      worst = d
      at = i
  let total = xs[xs.len - 1] - xs[0]
  line "  " & pad(name, 16) & padLeft($xs[0], 10) & " -> " &
       padLeft($xs[xs.len - 1], 10) & "   net " & padLeft($total, 9) &
       "   worst step " & padLeft($worst, 8) & " at cycle " & $mCycle[at]

proc main(): int =
  var backend = ""
  var keep = false
  var cycles = 24
  var every = 4
  var i = 1
  let n = paramCount()
  while i <= n:
    let a = paramStr(i)
    if a == "--root":
      inc i
      if i <= n: gRoot = paramStr(i)
    elif a == "--backend":
      inc i
      if i <= n: backend = paramStr(i)
    elif a == "--port":
      inc i
      if i <= n: parseIntArg(paramStr(i), gPort)
    elif a == "--cycles":
      inc i
      if i <= n: parseIntArg(paramStr(i), cycles)
    elif a == "--every":
      inc i
      if i <= n: parseIntArg(paramStr(i), every)
    elif a == "--keep":
      keep = true
    elif a == "--help" or a == "-h":
      echo Usage
      return 0
    else:
      err "unknown option: " & a
      return 1
    inc i

  if gRoot.len == 0 or backend.len == 0:
    echo Usage
    return 1
  if not fileExists(backend):
    err "no backend at " & backend
    return 1
  if cycles < 1: cycles = 1
  if every < 1: every = 1

  discard cNetStartup()

  heading "Starting"
  let server = startBackend(backend, gRoot)
  if server == 0'u64:
    err "could not start the backend"
    return 1
  if not waitForBackend(60):
    err "the backend never answered /client/game/config"
    cSpawnKill(server)
    return 1
  ok "the backend is serving on " & $gPort

  # The same fresh-root guard `emutest` has, and it stops the run rather than
  # logging a failure. Every equality below is against a baseline this run
  # establishes; a root left over from a previous run makes the baseline
  # someone else's and every failure describes the wrong session.
  let fresh = request(gPort, "/client/game/profile/list", "", Session)
  if not fresh.ok or not fresh.contains("\"data\":[]"):
    err "this root already has profiles in it; soak needs an empty store"
    note "delete " & gRoot & "\\store and run again"
    cSpawnKill(server)
    return 1
  ok "the store is empty"

  heading "Setting up"
  let created = timed("/client/game/profile/create",
    "{\"nickname\":\"SoakRat\",\"side\":\"Usec\",\"headId\":\"x\"}")
  gUid = jsonText(created.body, "uid")
  if gUid.len != 24:
    err "the profile was not created: " & created.body
    cSpawnKill(server)
    return 1
  discard timed("/client/game/profile/select", "{\"uid\":\"" & gUid & "\"}")
  let doc0 = profileOf(profileList(), gUid)
  gStash = stashOf(doc0)
  if gStash.len != 24:
    err "the profile has no stash id: " & doc0.substr(0, 300)
    cSpawnKill(server)
    return 1
  ok "profile " & gUid & ", stash " & gStash

  # The workbench, so that a craft has somewhere to happen. Built once: the
  # cycle needs it every time and building it per cycle would be testing the
  # upgrade rather than the craft.
  discard moving("{\"Action\":\"HideoutUpgrade\",\"areaType\":" &
                 $WorkbenchArea & "}")
  discard moving("{\"Action\":\"HideoutUpgradeComplete\",\"areaType\":" &
                 $WorkbenchArea & "}")
  let probe = moving("{\"Action\":\"HideoutSingleProductionStart\"," &
                     "\"recipeId\":\"" & QuickRecipe & "\"}")
  if warned(probe, "no such recipe") or warned(probe, "not built"):
    err "this database has no craft to run: " & probe.body
    note "soak needs tests/fixtures/emu-full.json staged as db.json"
    cSpawnKill(server)
    return 1
  discard moving("{\"Action\":\"HideoutTakeProduction\",\"recipeId\":\"" &
                 QuickRecipe & "\"}")
  let boltId = idOfTemplate(itemsNow(), Bolts)
  if boltId.len > 0:
    discard moving("{\"Action\":\"Remove\",\"item\":\"" & boltId & "\"}")
  ok "the workbench is built and the craft runs"

  heading "Soaking"
  header()
  var c = 1
  while c <= cycles:
    runCycle(c)
    if c mod every == 0 or c == cycles or c == 1:
      let k = mCycle.len - 1
      row(mCycle[k], mProfileBytes[k], mItems[k], mMoney[k], mStoreBytes[k],
          mStoreFiles[k], mUsAvg[k], mUsMax[k])
    inc c

  heading "Over time"
  trend("profile bytes", mProfileBytes)
  trend("store bytes", mStoreBytes)
  trend("store files", mStoreFiles)
  trend("item count", mItems)
  trend("request us avg", mUsAvg)
  trend("request us max", mUsMax)
  note "null raids grew the profile by " & $gNullGrowth &
       " bytes in total over " & $cycles & " cycles"

  if not keep:
    cSpawnKill(server)

  heading "Result"
  if gFailures > 0:
    err $gFailures & " of " & $gChecks & " checks failed over " & $cycles &
        " cycles"
    return 1
  ok "the emulator held all " & $gChecks & " invariants over " & $cycles &
     " cycles"
  result = 0

quit(main())
