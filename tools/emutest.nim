## emutest -- drive the Tarkov emulator the way the client does.
##
##     emutest --root <stage> --port 6975 --backend <aowlspt-backend.exe>
##
## The backend's own `--selftest` proves the pipeline: sockets, framing,
## routing, the database. This proves the *game*: it walks the client's boot
## sequence in order -- config, profile list, create, select, start, the static
## tables -- and checks what came back, over the wire, zlib framing included.
##
## Two things here are worth more than the rest of the checks put together.
##
## **Order.** The client calls these endpoints in a fixed sequence and each one
## depends on the last. Testing them individually would pass with a server that
## cannot actually get a player into the menu.
##
## **The restart.** Halfway through, the backend is killed and started again
## with the same root. Everything after that point tests a server that has
## forgotten everything except what it wrote to disk -- which is the only way to
## tell a working profile store from a working in-memory cache.

import std/[strutils, syncio, cmdline]
import aowlsptinstall/[winfs, log]
import wire

{.emit: """#include <stdlib.h>""".}
{.emit: """#include <string.h>""".}
{.emit: """#include "aowlspt_shim.h" """.}
{.emit: """#include "aowlspt_net.h" """.}
{.emit: """#include "aowlspt_inject.h" """.}

proc cSpawn(exe, workDir, cmdLine: cstring): uint64 {.
  importc: "aowl_spawn", nodecl.}
proc cSpawnAlive(h: uint64): int32 {.importc: "aowl_spawn_alive", nodecl.}
proc cSpawnKill(h: uint64) {.importc: "aowl_spawn_kill", nodecl.}
proc cSleepMs(ms: int32) {.importc: "aowl_sys_sleep", nodecl.}

const
  Usage = """
emutest -- drive the Tarkov emulator over the wire

  emutest --root PATH --backend PATH [--port N]

  --root PATH      the scratch install (mods/, db.json)
  --backend PATH   aowlspt-backend.exe
  --port N         port to serve on (default 6975)
  --keep           leave the backend running at the end
  -h, --help       this
"""
  Session = "aaaaaaaaaaaaaaaaaaaaaaaa"

var gFailures = 0
var gChecks = 0
var gPort = 6975

proc check(what: string; condition: bool; detail = "") =
  inc gChecks
  if condition:
    ok what
  else:
    err what & (if detail.len > 0: ": " & detail else: "")
    inc gFailures

proc call(path, body: string): Response =
  result = request(gPort, path, body, Session)

proc expectIn(what, path, body, want: string): Response =
  let r = call(path, body)
  if not r.ok:
    check(what, false, r.error)
    return r
  check(what, r.contains(want), "expected " & want & " in " & r.body)
  result = r

proc jsonText(body, key: string): string =
  ## The value of `"key":"value"` out of a flat response. A full parser is
  ## available to mods; this tool wants one field out of one body and reads it
  ## the way a shell script would.
  let at = find(body, "\"" & key & "\":\"")
  if at < 0:
    return ""
  var i = at + key.len + 4
  result = ""
  while i < body.len and body[i] != '"':
    result.add body[i]
    inc i

proc idOfTemplate(body, tpl: string): string =
  ## The `_id` of the item carrying this `_tpl`. Found by scanning back from the
  ## template to the nearest `"_id"`, because an item's own id is the one before
  ## its template in the document -- reading forward would find the *next*
  ## item's id, which is exactly the bug this test exists to catch.
  let at = find(body, "\"_tpl\":\"" & tpl & "\"")
  if at < 0:
    return ""
  var i = at
  while i > 0:
    if i + 7 < body.len and body.substr(i, i + 6) == "\"_id\":\"":
      var k = i + 7
      result = ""
      while k < body.len and body[k] != '"':
        result.add body[k]
        inc k
      return result
    dec i
  result = ""

proc countOf(haystack, needle: string): int =
  result = 0
  var i = 0
  while i < haystack.len:
    let at = find(haystack.substr(i), needle)
    if at < 0:
      return
    inc result
    i = i + at + needle.len

proc findFrom(haystack, needle: string; start: int): int =
  ## `find`, from an offset. The two-argument `find` is all there is, and half
  ## the readers below need "the next one after this" -- a value belonging to
  ## one item in a list of items with identical key names.
  if start >= haystack.len:
    return -1
  let at = find(haystack.substr(start), needle)
  if at < 0:
    return -1
  result = start + at

proc textAt(body: string; start: int; key: string): string =
  ## `"key":"value"` at or after `start`.
  let at = findFrom(body, "\"" & key & "\":\"", start)
  if at < 0:
    return ""
  var i = at + key.len + 4
  result = ""
  while i < body.len and body[i] != '"':
    result.add body[i]
    inc i

proc numberAt(body: string; start: int; key: string): int =
  ## `"key":123` at or after `start`, truncated to an int. -1 when the key is
  ## not there -- distinct from zero, which several of the fields below are
  ## legitimately allowed to be.
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

proc stackOf(listBody, itemId: string): int =
  ## How many are in the stack with this id, out of a profile document.
  ##
  ## Bounded by the *next* item's `_id` rather than read forward without a
  ## limit: an item with no `upd` would otherwise report the count of whatever
  ## item comes after it, which reads as a stack that never changed and is
  ## exactly the mistake these money checks exist to catch. 1 is the answer for
  ## an item with no count, which is what the server means by it too.
  let at = find(listBody, "\"_id\":\"" & itemId & "\"")
  if at < 0:
    return -1
  var stop = findFrom(listBody, "\"_id\":\"", at + 7)
  if stop < 0:
    stop = listBody.len
  let slice = listBody.substr(at, stop - 1)
  let n = jsonNumber(slice, "StackObjectsCount")
  result = if n < 0: 1 else: n

proc between(body, opening, closing: string): string =
  ## The text between two markers, or "" when either is missing. Used to read
  ## one array out of a response without parsing the rest of it.
  let a = find(body, opening)
  if a < 0:
    return ""
  let start = a + opening.len
  let b = findFrom(body, closing, start)
  if b < 0:
    return ""
  result = body.substr(start, b - 1)

proc offersOf(body: string): string =
  ## Just the rows of a `/client/ragfair/find` response.
  ##
  ## Every check on a filter has to be made against this and not against the
  ## whole body, because the response also carries the *category counts* -- and
  ## those are counted before the category filter is applied, on purpose. A
  ## check for "the helmet is not in this category's results" that looked at the
  ## whole body would find the helmet in the counts and fail against a working
  ## filter.
  result = between(body, "\"offers\":[", "\"offersCount\"")

proc lootOf(body: string): string =
  ## The `Loot` array out of a `getLocalloot` response, without the timestamp
  ## that follows it -- two calls a second apart differ in `UnixDateTime` and
  ## are still the same floor.
  result = between(body, "\"Loot\":", "\"transitionParameters\"")

proc withCommon(profileDoc, entriesJson: string): string =
  ## The profile with its `Skills.Common` array replaced.
  ##
  ## Replaced rather than appended to: the server reads the client's skills as a
  ## *delta* against the stored ones, so a claim is one entry naming the new
  ## total. Appending a second entry for the same skill to an array that already
  ## has one would have the delta applied twice, which would make the test's own
  ## arithmetic wrong rather than the server's.
  let key = "\"Common\":["
  let at = find(profileDoc, key)
  if at < 0:
    return profileDoc
  var i = at + key.len
  var depth = 1
  var inString = false
  while i < profileDoc.len and depth > 0:
    let c = profileDoc[i]
    if inString:
      if c == '\\': inc i
      elif c == '"': inString = false
    elif c == '"': inString = true
    elif c == '[': inc depth
    elif c == ']': dec depth
    if depth == 0: break
    inc i
  if depth != 0:
    return profileDoc
  result = profileDoc.substr(0, at + key.len - 1) & entriesJson &
           profileDoc.substr(i)

proc endurance(listBody: string): int =
  ## The PMC's Endurance progress, truncated. The PMC is first in the profile
  ## list and the scav's skills are empty, so the first entry is the one.
  let at = find(listBody, "\"Id\":\"Endurance\"")
  if at < 0:
    return 0
  result = numberAt(listBody, at, "Progress")

proc retimed(config, key: string; value: int): string =
  ## The staged mod config with one number changed. "" when the key is not
  ## there, so the caller can say so rather than silently testing nothing.
  let at = find(config, "\"" & key & "\"")
  if at < 0:
    return ""
  let colon = findFrom(config, ":", at)
  if colon < 0:
    return ""
  var i = colon + 1
  while i < config.len and (config[i] == ' ' or config[i] == '\t'):
    inc i
  var j = i
  while j < config.len and config[j] != ',' and config[j] != '}' and
        config[j] != '\n':
    inc j
  result = config.substr(0, i - 1) & $value & config.substr(j)

proc raidProfile(listBody, uid: string): string =
  ## The profile out of a `profile/list` response, with its experience changed,
  ## as the client would hand it back after a raid. Cut out of the response text
  ## rather than rebuilt: the point of the check downstream is that the server
  ## accepts the client's own document, not a tidy one this test made up.
  let at = find(listBody, "{\"_id\":\"" & uid & "\"")
  if at < 0:
    return ""
  var depth = 0
  var i = at
  var inString = false
  while i < listBody.len:
    let c = listBody[i]
    if inString:
      if c == '\\':
        inc i
      elif c == '"':
        inString = false
    elif c == '"':
      inString = true
    elif c == '{':
      inc depth
    elif c == '}':
      dec depth
      if depth == 0:
        break
    inc i
  if depth != 0:
    return ""
  var doc = listBody.substr(at, i)
  let expAt = find(doc, "\"Experience\":")
  if expAt < 0:
    return doc
  var j = expAt + len("\"Experience\":")
  var k = j
  while k < doc.len and doc[k] != ',' and doc[k] != '}':
    inc k
  result = doc.substr(0, j - 1) & "1234" & doc.substr(k)

proc waitForBackend(tries: int): bool =
  ## The backend has to bind a port and load a mod before it can answer. Polling
  ## a real endpoint rather than sleeping a fixed time: a fixed sleep is either
  ## too short on a cold disk or wasted on a warm one.
  var i = 0
  while i < tries:
    let r = call("/client/game/config", "")
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

proc main(): int =
  var root = ""
  var backend = ""
  var keep = false
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
    elif a == "--port":
      inc i
      if i <= n:
        var v = 0
        var any = false
        for ch in paramStr(i):
          if ch >= '0' and ch <= '9':
            v = v * 10 + (ord(ch) - ord('0'))
            any = true
        if any: gPort = v
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

  discard cNetStartup()

  heading "Starting"
  var proc1 = startBackend(backend, root)
  if proc1 == 0'u64:
    err "could not start the backend"
    return 1
  if not waitForBackend(60):
    err "the backend never answered /client/game/config"
    cSpawnKill(proc1)
    return 1
  ok "the backend is serving on " & $gPort

  # -- the client's boot sequence, in order ---------------------------------

  heading "Boot"
  discard expectIn("game config", "/client/game/config", "", "\"err\":0")
  discard expectIn("version validate", "/client/game/version/validate",
                   "{\"version\":{\"major\":\"1.1.0\"}}", "isvalid")
  # Fresh-root check, and it stops the run rather than logging a failure.
  #
  # Every check after this one assumes an empty store: the nickname must be
  # free, the hideout area must be at level zero, the profile the raid section
  # hands back must be the one this run created. Run against a root left over
  # from a previous run and all of that fails in ways that describe the previous
  # run rather than this one -- five confusing failures instead of one
  # actionable line.
  let fresh = call("/client/game/profile/list", "")
  if not fresh.ok or not fresh.contains("\"data\":[]"):
    err "this root already has profiles in it; emutest needs an empty store"
    note "delete " & root & "\\store and run again"
    cSpawnKill(proc1)
    return 1
  ok "no profiles on a fresh install"
  inc gChecks

  heading "Creating a profile"
  let created = call("/client/game/profile/create",
                     "{\"nickname\":\"AowlTest\",\"side\":\"Usec\",\"headId\":\"x\"}")
  check("create returns a profile id", created.ok and created.contains("uid"),
        created.body)
  let uid = jsonText(created.body, "uid")
  check("the profile id is a MongoId", uid.len == 24, uid)

  discard expectIn("the duplicate nickname is refused",
                   "/client/game/profile/create",
                   "{\"nickname\":\"AowlTest\",\"side\":\"Bear\"}", "\"err\":255")

  discard expectIn("the profile is in the list", "/client/game/profile/list",
                   "", "AowlTest")
  discard expectIn("the profile has a stash", "/client/game/profile/list",
                   "", "\"stash\"")

  heading "Selecting and starting"
  discard expectIn("select binds the session", "/client/game/profile/select",
                   "{\"uid\":\"" & uid & "\"}", "\"status\":\"ok\"")
  discard expectIn("config now names the active profile",
                   "/client/game/config", "", uid)
  discard expectIn("game start", "/client/game/start", "", "utc_time")
  discard expectIn("keepalive", "/client/game/keepalive", "", "OK")

  heading "Static tables"
  discard expectIn("items", "/client/items", "", "\"err\":0")
  discard expectIn("globals", "/client/globals", "", "\"err\":0")
  discard expectIn("handbook", "/client/handbook/templates", "", "Categories")
  discard expectIn("languages", "/client/languages", "", "\"err\":0")
  discard expectIn("locale", "/client/locale/en", "", "\"err\":0")
  discard expectIn("settings", "/client/settings", "", "\"err\":0")
  discard expectIn("the menu's supporting endpoints answer",
                   "/client/mail/dialog/list", "", "\"data\":[]")

  heading "Traders"
  discard expectIn("trader settings", "/client/trading/api/traderSettings",
                   "", "\"err\":0")
  discard expectIn("an unknown trader gets an empty assort, not a 404",
                   "/client/trading/api/getTraderAssort/54cb50c76803fa8b248b4571",
                   "", "loyal_level_items")

  heading "Inventory"
  # The roubles a new profile starts with: found by template, because its id is
  # generated per profile and the test cannot know it in advance.
  let listBody = call("/client/game/profile/list", "").body
  let moneyId = idOfTemplate(listBody, "5449016a4bdc2d6f028b456f")
  check("the starting roubles are in the stash", moneyId.len == 24, moneyId)

  let splitId = "bbbbbbbbbbbbbbbbbbbbbbbb"
  let split = call("/client/game/profile/items/moving",
    "{\"data\":[{\"Action\":\"Split\",\"item\":\"" & moneyId &
    "\",\"newItem\":\"" & splitId & "\",\"count\":100000," &
    "\"container\":{\"id\":\"" & moneyId &
    "\",\"container\":\"hideout\",\"location\":{\"x\":2,\"y\":0," &
    "\"r\":\"Horizontal\"}}}],\"tm\":2,\"reload\":0}")
  check("split reports the new stack", split.ok and split.contains(splitId),
        split.body)
  check("split reports it under `new`",
        find(split.body, "\"new\":[{") >= 0, split.body)

  discard expectIn("the split stack is in the profile",
                   "/client/game/profile/list", "", splitId)

  let merged = call("/client/game/profile/items/moving",
    "{\"data\":[{\"Action\":\"Merge\",\"item\":\"" & splitId &
    "\",\"with\":\"" & moneyId & "\"}],\"tm\":2}")
  # The assertion is that the *deleted id* is in the response, not that a `del`
  # key exists: `del` is always there, so checking for it passes against a merge
  # that silently did nothing. It did, once.
  check("merge deletes the source",
        merged.ok and merged.contains("{\"_id\":\"" & splitId & "\"}"),
        merged.body)
  let afterMerge = call("/client/game/profile/list", "")
  check("and the split stack is gone from the profile",
        not afterMerge.contains(splitId), "still there")

  let examined = call("/client/game/profile/items/moving",
    "{\"data\":[{\"Action\":\"Examine\",\"item\":\"" & moneyId &
    "\"}],\"tm\":2}")
  check("examine succeeds", examined.ok and examined.contains("\"err\":0"),
        examined.body)
  discard expectIn("and the encyclopedia remembers it",
                   "/client/game/profile/list", "",
                   "5449016a4bdc2d6f028b456f\":true")

  let bogus = call("/client/game/profile/items/moving",
    "{\"data\":[{\"Action\":\"Move\",\"item\":\"ffffffffffffffffffffffff\"," &
    "\"to\":{\"id\":\"x\",\"container\":\"hideout\"}}],\"tm\":2}")
  check("a move of an item that is not there is a warning, not a 500",
        bogus.ok and bogus.contains("warnings") and bogus.contains("no such item"),
        bogus.body)

  heading "Trading"
  # These need the database fixture: a trader who has something, a price to pay
  # for it, and a handbook price to sell it back at. Skipped rather than failed
  # when the server was started without one, because the emulator answering out
  # of its fallbacks is a supported way to run it.
  let traders = call("/client/trading/api/traderSettings", "")
  let haveFixture = traders.contains("Prapor")
  if haveFixture:
    ok "the database's trader is there"
    inc gChecks
    discard expectIn("and so is the offer",
                     "/client/trading/api/getTraderAssort/54cb50c76803fa8b248b4571",
                     "", "aaaaaaaaaaaaaaaaaaaaaaa1")

    let bought = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"TradingConfirm\",\"type\":\"buy_from_trader\"," &
      "\"tid\":\"54cb50c76803fa8b248b4571\",\"item_id\":\"aaaaaaaaaaaaaaaaaaaaaaa1\"," &
      "\"count\":1,\"scheme_id\":0,\"scheme_items\":[{\"id\":\"" & moneyId &
      "\",\"count\":25000}]}],\"tm\":2}")
    check("buying takes the money and gives the item",
          bought.ok and bought.contains("5644bd2b4bdc2d3b4c8b4572"), bought.body)
    check("and the payment came out of the right stack",
          bought.contains("475000"), bought.body)
    check("and the new item was given a position in the stash",
          bought.contains("\"location\""), bought.body)

    let boughtId = idOfTemplate(call("/client/game/profile/list", "").body,
                                "5644bd2b4bdc2d3b4c8b4572")
    check("the bought item is in the profile", boughtId.len == 24, boughtId)

    let sold = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"TradingConfirm\",\"type\":\"sell_to_trader\"," &
      "\"tid\":\"54cb50c76803fa8b248b4571\",\"items\":[{\"id\":\"" & boughtId &
      "\",\"count\":1,\"scheme_id\":0}]}],\"tm\":2}")
    check("selling it back pays the handbook price",
          sold.ok and sold.contains("22000"), sold.body)

    # And the refusal: paying from a stack that does not hold enough must take
    # nothing at all, rather than taking what is there.
    let broke = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"TradingConfirm\",\"type\":\"buy_from_trader\"," &
      "\"tid\":\"54cb50c76803fa8b248b4571\",\"item_id\":\"aaaaaaaaaaaaaaaaaaaaaaa1\"," &
      "\"count\":1,\"scheme_items\":[{\"id\":\"" & moneyId &
      "\",\"count\":99999999}]}],\"tm\":2}")
    check("a payment larger than the stack is refused",
          broke.contains("not enough in that stack"), broke.body)
  else:
    note "no database fixture; skipping the trading checks"

  heading "The flea market"
  # Here rather than at the end, because the flea needs exactly what the trader
  # counter above needed and nothing more: a handbook to price offers off, a
  # trader whose stock becomes offers, a stash to put a purchase in and a stack
  # of roubles to pay with. Every filter check reads `offersOf` rather than the
  # whole body -- see the note there.
  var listedId = ""
  if haveFixture:
    let page = call("/client/ragfair/find",
      "{\"page\":0,\"limit\":50,\"sortType\":5,\"sortDirection\":0}")
    check("a search returns offers", page.contains("\"offers\":[{"), page.body)
    check("and says how many matched",
          jsonNumber(page.body, "offersCount") > 5,
          $jsonNumber(page.body, "offersCount") & " offers")
    # The barter in the fixture's assort must not be one of the trader's rows:
    # it has no price, and an offer with no price is free at the top of every
    # cheapest-first search. Asked with the owner filter set to traders,
    # because the handbook prices that template too and the *player* offer for
    # it is legitimate -- a check over the whole page would be reading the
    # wrong row and would fail against a working market.
    let fromTraders = call("/client/ragfair/find",
      "{\"page\":0,\"limit\":50,\"offerOwnerType\":1}")
    let traderRows = offersOf(fromTraders.body)
    check("the trader's priced stock is on the flea",
          find(traderRows, "\"_tpl\":\"5644bd2b4bdc2d3b4c8b4572\"") >= 0,
          traderRows)
    check("and the trader's barter is not",
          find(traderRows, "\"_tpl\":\"590c657e86f77412b013051d\"") < 0,
          traderRows)

    # The category box. Clicking the parent node has to show what is under it,
    # which is the whole reason the handbook tree is walked rather than matched.
    let cat = call("/client/ragfair/find",
      "{\"page\":0,\"limit\":50,\"handbookId\":\"5b47574386f77428ca22b33e\"}")
    let catRows = offersOf(cat.body)
    check("a category filter reaches offers two levels under it",
          find(catRows, "\"_tpl\":\"544fb45d4bdc2dee738b4568\"") >= 0, catRows)
    check("and leaves out what is in another category",
          find(catRows, "\"_tpl\":\"5648a7494bdc2d9d488b4583\"") < 0, catRows)

    let dear = call("/client/ragfair/find",
      "{\"page\":0,\"limit\":50,\"handbookId\":\"5b47574386f77428ca22b33e\"," &
      "\"priceFrom\":20000}")
    let dearRows = offersOf(dear.body)
    check("a price floor keeps the expensive offer",
          find(dearRows, "\"_tpl\":\"590c657e86f77412b013051d\"") >= 0, dearRows)
    check("and drops the cheap one",
          find(dearRows, "\"_tpl\":\"544fb45d4bdc2dee738b4568\"") < 0, dearRows)

    # One page of one row, sorted by price, in each direction. The weapons
    # category holds a 9,500 scope and a 22,000 rifle, so the two directions
    # must return different templates -- a sort that ignores `sortDirection`
    # returns the same row twice and looks like it worked.
    const Cheapest = "{\"page\":0,\"limit\":1,\"sortType\":5," &
      "\"sortDirection\":0,\"currency\":1," &
      "\"handbookId\":\"5b5f78b786f77447ed5636b1\"}"
    const Dearest = "{\"page\":0,\"limit\":1,\"sortType\":5," &
      "\"sortDirection\":1,\"currency\":1," &
      "\"handbookId\":\"5b5f78b786f77447ed5636b1\"}"
    let cheap = call("/client/ragfair/find", Cheapest)
    check("cheapest first is the scope",
          find(offersOf(cheap.body), "\"_tpl\":\"57ac965c24597706be5f975c\"") >= 0,
          offersOf(cheap.body))
    let dearest = call("/client/ragfair/find", Dearest)
    check("and the other direction is the rifle",
          find(offersOf(dearest.body), "\"_tpl\":\"5644bd2b4bdc2d3b4c8b4572\"") >= 0,
          offersOf(dearest.body))

    # Buying. The template id in the category box is how the client asks for
    # "offers for this exact item", so this is one row and its price can be
    # read rather than guessed -- the generated price carries a deterministic
    # wobble, and a test that hard-coded it would be testing the wobble.
    let one = call("/client/ragfair/find",
      "{\"page\":0,\"limit\":5,\"currency\":1," &
      "\"handbookId\":\"57ac965c24597706be5f975c\"}")
    let rows = offersOf(one.body)
    let offerId = textAt(rows, 0, "_id")
    let cost = jsonNumber(rows, "summaryCost")
    check("an exact template id in the category box finds its offer",
          offerId.len == 24 and cost > 0, rows)

    let moneyBefore = stackOf(call("/client/game/profile/list", "").body, moneyId)
    let bought = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"RagFairBuyOffer\",\"offers\":[{\"id\":\"" &
      offerId & "\",\"count\":1,\"items\":[{\"id\":\"" & moneyId &
      "\",\"count\":" & $cost & "}]}]}],\"tm\":2}")
    check("buying an offer gives the item",
          bought.ok and bought.contains("57ac965c24597706be5f975c"), bought.body)
    let moneyAfter = stackOf(call("/client/game/profile/list", "").body, moneyId)
    # The exact amount, not "less than before". A flea that charges the
    # handbook price rather than the price on the row it sold is a shop with
    # two prices, and only an exact check finds it.
    check("and takes exactly what the offer asked for",
          moneyBefore - moneyAfter == cost,
          $moneyBefore & " - " & $moneyAfter & " != " & $cost)

    let psoId = idOfTemplate(call("/client/game/profile/list", "").body,
                             "57ac965c24597706be5f975c")
    check("the bought item has a place in the stash", psoId.len == 24, psoId)

    # Listing it again. The items leave the stash and are held by the offer:
    # they have to leave, because an item that is both listed and in the stash
    # can be sold twice.
    listedId = psoId
    let listed = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"RagFairAddOffer\",\"sellInOnePiece\":false," &
      "\"items\":[\"" & psoId & "\"],\"requirements\":[{\"_tpl\":\"" &
      "5449016a4bdc2d6f028b456f\",\"count\":999999}]}],\"tm\":2}")
    check("listing an item is accepted",
          listed.ok and not listed.contains("not here"), listed.body)
    let afterListing = call("/client/game/profile/list", "")
    check("and takes it out of the stash",
          not afterListing.contains(psoId), "still in the profile")
  else:
    # The screen still has to open. A flea that fails its request with no
    # database is a menu the player cannot leave.
    let empty = call("/client/ragfair/find", "{\"page\":0,\"limit\":15}")
    check("with no database the flea answers an empty page",
          empty.ok and empty.contains("\"offers\":[]"), empty.body)

  heading "Quests and the hideout"
  # Both arrive down the same endpoint as the drags, and the emulator has to
  # tell them apart from an inventory action rather than trying to move an item
  # that is a quest id.
  let accepted = call("/client/game/profile/items/moving",
    "{\"data\":[{\"Action\":\"QuestAccept\",\"qid\":\"59c50c1686f7745fed3193bf\"}],\"tm\":2}")
  check("a quest can be accepted",
        accepted.ok and accepted.contains("\"err\":0"), accepted.body)
  discard expectIn("and the profile records it as started",
                   "/client/game/profile/list", "", "\"Started\"")

  let completed = call("/client/game/profile/items/moving",
    "{\"data\":[{\"Action\":\"QuestComplete\",\"qid\":\"59c50c1686f7745fed3193bf\"}],\"tm\":2}")
  check("and completed", completed.ok and completed.contains("\"err\":0"),
        completed.body)
  discard expectIn("which the profile records as a success",
                   "/client/game/profile/list", "", "\"Success\"")

  # The quests the database *does* have, and therefore has conditions for. The
  # pair above proves the state machine; these prove the guard on it, which is
  # the half that decides whether a quest can be paid out for nothing.
  var rewardMessage = ""
  var rewardItem = ""
  if haveFixture:
    let tooSoon = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"QuestAccept\",\"qid\":\"q_followup\"}],\"tm\":2}")
    check("a quest whose start conditions fail is refused",
          tooSoon.contains("cannot accept") and tooSoon.contains("q_debut"),
          tooSoon.body)
    let followupState = call("/client/game/profile/list", "")
    check("nor recorded at all",
          not followupState.contains("\"qid\":\"q_followup\""),
          "q_followup is in the Quests array")

    let debut = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"QuestAccept\",\"qid\":\"q_debut\"}],\"tm\":2}")
    check("a quest whose start conditions hold is accepted",
          debut.ok and not debut.contains("cannot accept"), debut.body)

    # The refusal that carries the weight. A completion that pays for nothing is
    # invisible; a refusal is visible, and it has to say *which* condition,
    # because "no" with no reason sends the player to a wiki.
    let unearned = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"QuestComplete\",\"qid\":\"q_debut\"}],\"tm\":2}")
    check("completing a quest whose finish conditions fail is refused",
          unearned.contains("cannot complete"), unearned.body)
    check("and the refusal names the condition",
          unearned.contains("c_kill_scavs") and unearned.contains("0 of 5"),
          unearned.body)

    # Handing over one of the two rifles the condition asks for. The old
    # behaviour credited the condition on the first item, which finished a
    # "hand over five" after one -- and the items are removed by the inventory
    # actions in the same batch either way, so the player was five items poorer
    # for nothing.
    let handOne = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"QuestHandover\",\"qid\":\"q_debut\"," &
      "\"conditionId\":\"c_hand_rifles\",\"items\":[{\"id\":\"" & moneyId &
      "\",\"count\":1}]}],\"tm\":2}")
    check("a handover is accepted", handOne.ok, handOne.body)
    let afterOne = call("/client/game/profile/list", "")
    let counted = numberAt(afterOne.body,
                           find(afterOne.body, "\"c_hand_rifles\""), "value")
    # Both halves, because either one alone passes against a broken server: a
    # handover that did nothing leaves the condition uncompleted too, and a
    # handover that completed it on the first item still counted to one.
    check("and counts rather than completing the condition",
          counted == 1 and not afterOne.contains("\"c_hand_rifles\"]"),
          "counter " & $counted & " in " & afterOne.body)
    let handTwo = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"QuestHandover\",\"qid\":\"q_debut\"," &
      "\"conditionId\":\"c_hand_rifles\",\"items\":[{\"id\":\"" & moneyId &
      "\",\"count\":1}]}],\"tm\":2}")
    check("the second handover is accepted", handTwo.ok, handTwo.body)
    discard expectIn("and completes the condition",
                     "/client/game/profile/list", "", "\"c_hand_rifles\"]")

    # And the whole of a payout: experience, and the item rewards through the
    # post rather than into a stash that may be full.
    let payout = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"QuestAccept\",\"qid\":\"q_reward\"}," &
      "{\"Action\":\"QuestHandover\",\"qid\":\"q_reward\"," &
      "\"conditionId\":\"c_reward_hand\",\"items\":[{\"id\":\"" & moneyId &
      "\",\"count\":1}]}," &
      "{\"Action\":\"QuestComplete\",\"qid\":\"q_reward\"}],\"tm\":2}")
    check("a quest whose conditions are met completes",
          payout.ok and not payout.contains("cannot complete"), payout.body)
    discard expectIn("and pays its experience",
                     "/client/game/profile/list", "", "\"Experience\":900")

    # Read off `dialog/list` rather than `dialog/getAllAttachments`: the
    # collect-all endpoint renders each message as an escaped *string* rather
    # than as an object (see the report accompanying these checks), so nothing
    # can be read out of it. The dialog list nests them properly and carries
    # the same message.
    let post = call("/client/mail/dialog/list", "")
    rewardMessage = textAt(post.body, find(post.body, "\"message\":"), "_id")
    rewardItem = idOfTemplate(post.body, "544fb45d4bdc2dee738b4568")
    check("and posts its item reward to the mailbox",
          rewardMessage.len == 24 and rewardItem.len > 0, post.body)
    check("with the badge that tells the player it is there",
          numberAt(post.body, 0, "attachmentsNew") == 1, post.body)

  let upgrade = call("/client/game/profile/items/moving",
    "{\"data\":[{\"Action\":\"HideoutUpgrade\",\"areaType\":3}],\"tm\":2}")
  check("a hideout area can be upgraded", upgrade.ok, upgrade.body)
  let finished = call("/client/game/profile/items/moving",
    "{\"data\":[{\"Action\":\"HideoutUpgradeComplete\",\"areaType\":3}],\"tm\":2}")
  check("and the upgrade completes", finished.ok, finished.body)
  discard expectIn("leaving the area at level 1",
                   "/client/game/profile/list", "", "\"level\":1")

  # The refusal that matters: a complete with no upgrade in progress is either a
  # replayed request or a client out of step, and granting it is a free level.
  let freeLevel = call("/client/game/profile/items/moving",
    "{\"data\":[{\"Action\":\"HideoutUpgradeComplete\",\"areaType\":3}],\"tm\":2}")
  check("a second complete is refused",
        freeLevel.contains("not being upgraded"), freeLevel.body)

  heading "Production"
  # Crafts, in the workbench the checks above have just proved can be built.
  # The recipes come out of the fixture and each one exists to provoke exactly
  # one answer: recipe-rich has materials the profile does not have,
  # recipe-bolts a tool it does not have, recipe-quick finishes at once, and
  # recipe-slow cannot finish inside a test run.
  var slowStarted = -1
  if haveFixture:
    discard call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutUpgrade\",\"areaType\":10}],\"tm\":2}")
    let bench = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutUpgradeComplete\",\"areaType\":10}],\"tm\":2}")
    check("the workbench can be built", bench.ok and
          not bench.contains("not being upgraded"), bench.body)

    let noMaterials = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutSingleProductionStart\"," &
      "\"recipeId\":\"recipe-rich\"}],\"tm\":2}")
    check("a craft with materials the player does not have is refused",
          noMaterials.contains("not enough"), noMaterials.body)
    let noTool = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutSingleProductionStart\"," &
      "\"recipeId\":\"recipe-bolts\"}],\"tm\":2}")
    check("and so is one whose tool is missing",
          noTool.contains("tool"), noTool.body)
    let untouched = call("/client/game/profile/list", "")
    check("a refused craft starts nothing",
          not untouched.contains("recipe-rich") and
          not untouched.contains("recipe-bolts"),
          "a refused recipe is in Hideout.Production")

    # Three roubles for two screw nuts. The exact arithmetic, because a craft
    # that charges the wrong amount -- or charges nothing -- is the same shape
    # of bug as a trade that does, and "the stack got smaller" would pass
    # against both.
    let payBefore = stackOf(call("/client/game/profile/list", "").body, moneyId)
    let started = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutSingleProductionStart\"," &
      "\"recipeId\":\"recipe-quick\"}],\"tm\":2}")
    check("a craft the player can afford starts",
          started.ok and not started.contains("not enough"), started.body)
    let payAfter = stackOf(call("/client/game/profile/list", "").body, moneyId)
    check("and consumes exactly its inputs", payBefore - payAfter == 3,
          $payBefore & " - " & $payAfter & " != 3")

    let collected = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutTakeProduction\"," &
      "\"recipeId\":\"recipe-quick\"}],\"tm\":2}")
    check("collecting a finished craft gives the product",
          collected.ok and collected.contains("59e35de086f7741778269d83"),
          collected.body)
    # The one that is free items if it is wrong. A record cleared on collection
    # is the only thing standing between a finished craft and an infinite one.
    let twice = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutTakeProduction\"," &
      "\"recipeId\":\"recipe-quick\"}],\"tm\":2}")
    check("collecting it a second time is refused",
          twice.contains("nothing is being made"), twice.body)

    let slow = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutSingleProductionStart\"," &
      "\"recipeId\":\"recipe-slow\"}],\"tm\":2}")
    check("a long craft starts", slow.ok and not slow.contains("not enough"),
          slow.body)
    let early = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutTakeProduction\"," &
      "\"recipeId\":\"recipe-slow\"}],\"tm\":2}")
    check("and collecting it before it is finished is refused",
          early.contains("not finished"), early.body)
    # Kept for the restart: a craft's clock is a timestamp, not a countdown, so
    # the number the server comes back with has to be the number it went down
    # with. See "Across a restart".
    let record = call("/client/game/profile/list", "")
    slowStarted = numberAt(record.body, find(record.body, "recipe-slow"),
                           "StartTimestamp")
    check("the craft records when it started", slowStarted > 0, $slowStarted)
  else:
    let noRecipe = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutSingleProductionStart\"," &
      "\"recipeId\":\"recipe-quick\"}],\"tm\":2}")
    check("with no recipe table a craft is refused, not crashed",
          noRecipe.ok and noRecipe.contains("no such recipe"), noRecipe.body)

  heading "Redeeming a reward"
  # The reward the quest above posted, dragged out of the message. The client
  # has no redeem endpoint: this is an ordinary `Move` with `fromOwner` naming
  # the message, which is why it is tested through the same endpoint as a drag.
  if rewardMessage.len == 24 and rewardItem.len > 0:
    let stashId = jsonText(listBody, "stash")
    let dragged = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"Move\",\"item\":\"" & rewardItem &
      "\",\"fromOwner\":{\"id\":\"" & rewardMessage & "\",\"type\":\"Mail\"}," &
      "\"to\":{\"id\":\"" & stashId & "\",\"container\":\"hideout\"}}],\"tm\":2}")
    check("a reward can be dragged out of a message",
          dragged.ok and dragged.contains(rewardItem), dragged.body)
    let held = call("/client/game/profile/list", "")
    check("and it is in the stash", held.contains(rewardItem), "not there")
    # A redeemed item with no position is drawn on top of whatever is in the
    # top-left cell and cannot be picked up, which looks exactly like never
    # having been given it. Read out of this item's own slice of the document,
    # because every other item in the stash has a location too.
    let placed = between(held.body, rewardItem, "\"_id\"")
    check("with a cell of its own", find(placed, "\"location\"") >= 0, placed)

    let again = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"Move\",\"item\":\"" & rewardItem &
      "\",\"fromOwner\":{\"id\":\"" & rewardMessage & "\",\"type\":\"Mail\"}," &
      "\"to\":{\"id\":\"" & stashId & "\",\"container\":\"hideout\"}}],\"tm\":2}")
    check("dragging it a second time says so rather than duplicating it",
          again.contains("already been collected"), again.body)
    # And the count, because "it said no" and "it did nothing" are different
    # claims and only the second one matters to the player's stash.
    check("and there is still exactly one of it",
          countOf(call("/client/game/profile/list", "").body, rewardItem) == 1,
          $countOf(call("/client/game/profile/list", "").body, rewardItem) &
          " copies")
  else:
    note "no quest reward in the post; skipping the redemption checks"

  heading "The floor of a raid"
  # Loot first, because the client asks for it before it starts the match, and
  # because the raid id it is seeded from is issued by `raid/configuration`.
  # The map here is the fixture's own: `factory4_day` below has no tables at
  # all, and both cases matter.
  if haveFixture:
    discard expectIn("a raid on a map with loot tables is configured",
                     "/client/raid/configuration",
                     "{\"location\":\"testmap\",\"timeVariant\":\"CURR\"," &
                     "\"raidMode\":\"Local\",\"side\":\"Pmc\"}", "\"err\":0")
    let floor1 = call("/client/location/getLocalloot",
                      "{\"locationId\":\"testmap\",\"variantId\":0}")
    let loot1 = lootOf(floor1.body)
    check("the map's loot tables put items on the floor",
          find(loot1, "\"_tpl\"") >= 0, floor1.body)
    check("including the container that is always there",
          find(loot1, "ccccbox00000000000000001") >= 0, loot1)
    # A weapon spawns as its preset or it is a floating receiver with no
    # magazine -- which the client draws, and which is not a gun.
    check("and a weapon comes with the mods its preset names",
          find(loot1, "mmmmmag00000000000000001") >= 0, loot1)

    let floor2 = call("/client/location/getLocalloot",
                      "{\"locationId\":\"testmap\",\"variantId\":0}")
    # The whole point of seeding from the raid id: the same raid is the same
    # floor, down to the item ids, so "the crate by the gas station was empty"
    # is a reproducible statement. An ambient RNG passes every other check in
    # this section and fails this one.
    check("the same raid id lays out the same floor",
          lootOf(floor2.body) == loot1,
          "two calls in one raid disagreed")

    discard call("/client/raid/configuration",
                 "{\"location\":\"testmap\",\"timeVariant\":\"CURR\"," &
                 "\"raidMode\":\"Local\",\"side\":\"Pmc\"}")
    let floor3 = call("/client/location/getLocalloot",
                      "{\"locationId\":\"testmap\",\"variantId\":0}")
    check("and a different raid id lays out a different one",
          lootOf(floor3.body) != loot1,
          "two raids produced identical loot")
  else:
    note "no database fixture; skipping the loot generation checks"

  heading "A raid"
  discard expectIn("raid configuration is accepted",
                   "/client/raid/configuration",
                   "{\"location\":\"factory4_day\",\"timeVariant\":\"CURR\"," &
                   "\"raidMode\":\"Local\",\"side\":\"Pmc\"}", "\"err\":0")
  let bare = expectIn("the map hands over its loot",
                      "/client/location/getLocalloot",
                      "{\"locationId\":\"factory4_day\",\"variantId\":0}", "Loot")
  # Nothing in the database describes this map. An empty floor loads and plays;
  # a request that fails is a client that cannot enter a raid at all, which is
  # what makes this the property the whole loot module is written around.
  check("a map with no tables gets an empty floor rather than an error",
        find(lootOf(bare.body), "\"_id\"") < 0, lootOf(bare.body))
  discard expectIn("weather", "/client/weather", "", "season")
  discard expectIn("the raid starts", "/client/match/local/start",
                   "{\"location\":\"factory4_day\"}", "serverId")

  # Coming out of a raid with a changed profile. The client hands back the whole
  # document, so this is also the check that the server does not lose the rest
  # of it while taking the part that changed.
  let before = call("/client/game/profile/list", "").body
  let played = raidProfile(before, uid)
  check("the test could rebuild the played profile", played.len > 100,
        $played.len & " bytes")
  let ended = call("/client/match/local/end",
    "{\"exit\":\"Survived\",\"profile\":" & played & "}")
  check("the raid result is accepted", ended.ok and ended.contains("\"err\":0"),
        ended.body)
  discard expectIn("and the raid experience stuck",
                   "/client/game/profile/list", "", "\"Experience\":1234")

  discard expectIn("a raid result for another profile is refused",
                   "/client/match/local/end",
                   "{\"exit\":\"Survived\",\"profile\":{\"_id\":" &
                   "\"cccccccccccccccccccccccc\"}}", "different profile")

  heading "Skills"
  # A raid result *is* a profile, so the server that believes its skill numbers
  # has skills that are whatever the client says they are. What is taken is the
  # delta, run through the game's curve -- and the curve is only worth having if
  # it is integrated, which is what these two claims measure.
  #
  # The claim is made by replacing `Skills.Common` in the profile the client
  # hands back. `match/local/start` resets the per-raid fatigue counter, so each
  # of the two experiments below starts from the same place.
  discard call("/client/match/local/start", "{\"location\":\"factory4_day\"}")
  let base0 = call("/client/game/profile/list", "").body
  let start0 = endurance(base0)
  let bigClaim = withCommon(raidProfile(base0, uid),
    "{\"Id\":\"Endurance\",\"Progress\":" & $(start0 + 60) &
    ",\"PointsEarnedDuringSession\":0,\"LastAccess\":0}")
  let bigEnd = call("/client/match/local/end",
                    "{\"exit\":\"Survived\",\"profile\":" & bigClaim & "}")
  check("a raid's skill claim is accepted", bigEnd.ok, bigEnd.body)
  let afterBig = endurance(call("/client/game/profile/list", "").body)
  check("and moves the skill", afterBig > start0,
        $start0 & " -> " & $afterBig)
  let big = afterBig - start0

  discard call("/client/match/local/start", "{\"location\":\"factory4_day\"}")
  var small = 0
  var round1 = 0
  while round1 < 6:
    let now1 = call("/client/game/profile/list", "").body
    let was = endurance(now1)
    let claim = withCommon(raidProfile(now1, uid),
      "{\"Id\":\"Endurance\",\"Progress\":" & $(was + 10) &
      ",\"PointsEarnedDuringSession\":0,\"LastAccess\":0}")
    discard call("/client/match/local/end",
                 "{\"exit\":\"Survived\",\"profile\":" & claim & "}")
    small = small + (endurance(call("/client/game/profile/list", "").body) - was)
    inc round1
  # The exploit shape, and the reason `grantedFor` integrates a point at a time:
  # fatigue is a function of what has been earned so far, so pricing a whole
  # claim at its cheapest rate makes one enormous claim strictly better than the
  # many small ones the game actually produces. Six tens must be worth at least
  # as much as one sixty.
  check("one large claim is not worth more than several small ones",
        big <= small, "60 in one raid granted " & $big &
        ", six claims of 10 granted " & $small)

  # And the backstop over the top of the curve. Fatigue only converges slowly,
  # so a large enough claim still crawls past it -- the per-raid cap is what
  # answers a client that reports a thousand points of Endurance.
  discard call("/client/match/local/start", "{\"location\":\"factory4_day\"}")
  let beforeAbsurd = call("/client/game/profile/list", "").body
  let was2 = endurance(beforeAbsurd)
  let absurd = withCommon(raidProfile(beforeAbsurd, uid),
    "{\"Id\":\"Endurance\",\"Progress\":" & $(was2 + 100000) &
    ",\"PointsEarnedDuringSession\":0,\"LastAccess\":0}")
  discard call("/client/match/local/end",
               "{\"exit\":\"Survived\",\"profile\":" & absurd & "}")
  let granted = endurance(call("/client/game/profile/list", "").body) - was2
  check("an absurd claim is capped rather than honoured",
        granted > 0 and granted <= 100,
        "a claim of 100000 granted " & $granted)

  heading "The scav"
  let withScav = call("/client/game/profile/list", "")
  let scavId = jsonText(withScav.body, "savage")
  check("the profile list carries the scav beside the PMC",
        scavId.len == 24 and withScav.contains("\"Side\":\"Savage\""),
        "savage " & scavId)
  let scavAt = find(withScav.body, "\"_id\":\"" & scavId & "\"")
  let gearId = textAt(withScav.body, scavAt, "equipment")
  check("and the scav has an equipment container to hang gear off",
        scavAt > 0 and gearId.len == 24, gearId)

  # Surviving. The gear on the scav's back becomes the player's, in real cells
  # of the real stash -- the scav's own document has no stash, so this is the
  # one join that makes a scav run worth playing.
  let brought = call("/client/match/local/end",
    "{\"exit\":\"Survived\",\"profile\":{\"_id\":\"" & scavId &
    "\",\"Inventory\":{\"equipment\":\"" & gearId & "\",\"items\":[" &
    "{\"_id\":\"" & gearId & "\",\"_tpl\":\"55d7217a4bdc2d86028b456d\"}," &
    "{\"_id\":\"5ca1a5a5a5a5a5a5a5a5a5a1\",\"_tpl\":\"5710c24ad2720bc3458b45a3\"," &
    "\"parentId\":\"" & gearId & "\",\"slotId\":\"FirstPrimaryWeapon\"}]}}}")
  check("a scav raid result is accepted", brought.ok and
        brought.contains("\"err\":0"), brought.body)
  let home = call("/client/game/profile/list", "")
  check("and what the scav was carrying is in the PMC's stash",
        home.contains("5ca1a5a5a5a5a5a5a5a5a5a1"), "nothing came home")
  check("the cooldown is set", numberAt(home.body,
        find(home.body, "\"SavageLockTime\""), "SavageLockTime") > 0,
        "SavageLockTime is still zero")

  # Dying. There is nothing to undo -- the scav's gear was never in the PMC
  # document -- so the check is that nothing arrived, which is the whole of the
  # rule.
  let deadScav = call("/client/game/profile/list", "")
  let deadGear = textAt(deadScav.body,
                        find(deadScav.body, "\"_id\":\"" & scavId & "\""),
                        "equipment")
  let died = call("/client/match/local/end",
    "{\"exit\":\"Killed\",\"profile\":{\"_id\":\"" & scavId &
    "\",\"Inventory\":{\"equipment\":\"" & deadGear & "\",\"items\":[" &
    "{\"_id\":\"" & deadGear & "\",\"_tpl\":\"55d7217a4bdc2d86028b456d\"}," &
    "{\"_id\":\"5ca1a5a5a5a5a5a5a5a5a5a2\",\"_tpl\":\"590c657e86f77412b013051d\"," &
    "\"parentId\":\"" & deadGear & "\",\"slotId\":\"FirstPrimaryWeapon\"}]}}}")
  check("a dead scav's raid result is accepted too", died.ok, died.body)
  check("and brings nothing home",
        not call("/client/game/profile/list", "").contains(
          "5ca1a5a5a5a5a5a5a5a5a5a2"), "the dead scav's gear arrived")

  heading "Bots"
  let bots = call("/client/game/bot/generate",
    "{\"conditions\":[{\"Role\":\"assault\",\"Limit\":3,\"Difficulty\":\"normal\"}]}")
  check("a batch of bots is generated", bots.ok and bots.contains("assault"),
        bots.body)
  # Three requested, three delivered. Counting the equipment template is the
  # cheap way to count bots without parsing: every bot has exactly one.
  check("three of them", countOf(bots.body, "55d7217a4bdc2d86028b456d") == 3,
        $countOf(bots.body, "55d7217a4bdc2d86028b456d") & " found")
  check("each one has a body to render",
        bots.contains("\"BodyParts\""), bots.body)

  let huge = call("/client/game/bot/generate",
    "{\"conditions\":[{\"Role\":\"assault\",\"Limit\":5000,\"Difficulty\":\"normal\"}]}")
  check("an absurd request is capped rather than honoured",
        huge.ok and countOf(huge.body, "55d7217a4bdc2d86028b456d") <= 64,
        $countOf(huge.body, "55d7217a4bdc2d86028b456d") & " bots")

  heading "Mail and insurance"
  # The inbox. Empty on a server with nothing to say -- which is what the boot
  # section already proved, before anything had been posted -- and by now it
  # holds the quest reward, so this is the same property from the other side:
  # a dialog with a message in it, rather than an error.
  if rewardMessage.len > 0:
    discard expectIn("the inbox carries the message the quest posted",
                     "/client/mail/dialog/list", "", rewardMessage)
  else:
    discard expectIn("an empty inbox is an empty list, not an error",
                     "/client/mail/dialog/list", "", "\"data\":[]")
  # Priced off the handbook, so it needs the fixture for the same reason trading
  # does. Without one the right answer is an empty quote, and checking for a
  # number there would be checking that the server invented a price.
  let quote = call("/client/insurance/items/list/cost",
                   "{\"traders\":[\"54cb50c76803fa8b248b4571\"]," &
                   "\"items\":[\"5644bd2b4bdc2d3b4c8b4572\"]}")
  if haveFixture:
    check("insurance quotes a premium from the handbook",
          quote.contains("2200"), quote.body)
  else:
    check("with no handbook, insurance quotes nothing rather than zero",
          quote.ok and not quote.contains(":0}"), quote.body)

  # -- the part that only a restart can prove -------------------------------

  heading "Across a restart"
  cSpawnKill(proc1)
  cSleepMs(400'i32)

  # The second server runs with the flea's offer lifetime set to zero. An offer
  # that has expired is the only way to watch one come back by post, and the
  # alternative is a test that waits twelve hours -- the emulator has no clock
  # to wind forward, so the config is what moves. Only offers listed *after*
  # this point are affected: an offer's expiry is written onto the record when
  # it is listed, so the one listed above is still live, which is what makes
  # this safe to do halfway through a run.
  let configPath = root & "\\mods\\tarkov\\config.json"
  var configText = ""
  var retimedFlea = false
  if readTextFile(configPath, configText):
    let changed = retimed(configText, "fleaOfferHours", 0)
    if changed.len > 0 and writeTextFile(configPath, changed).ok:
      retimedFlea = true
  if not retimedFlea:
    note "could not retime the flea in " & configPath &
         "; the expiry check will be skipped"

  var proc2 = startBackend(backend, root)
  if proc2 == 0'u64:
    err "could not restart the backend"
    return 1
  if not waitForBackend(60):
    err "the backend did not come back up"
    cSpawnKill(proc2)
    return 1
  ok "restarted"

  discard expectIn("the profile survived the restart",
                   "/client/game/profile/list", "", "AowlTest")
  discard expectIn("the session is still bound to it",
                   "/client/game/config", "", uid)
  discard expectIn("and the nickname is still taken",
                   "/client/game/profile/create",
                   "{\"nickname\":\"AowlTest\",\"side\":\"Bear\"}", "\"err\":255")

  # A craft is a timestamp, not a countdown. A server that stored "so many
  # seconds left" and ticked it while it was running would come back with the
  # craft either finished or restarted, and both are wrong in the player's
  # favour exactly once.
  if slowStarted > 0:
    let survived = call("/client/game/profile/list", "")
    check("the craft survived the restart",
          survived.contains("recipe-slow"), "recipe-slow is gone")
    check("with its clock intact",
          numberAt(survived.body, find(survived.body, "recipe-slow"),
                   "StartTimestamp") == slowStarted,
          "started at " & $slowStarted & ", now " &
          $numberAt(survived.body, find(survived.body, "recipe-slow"),
                    "StartTimestamp"))
    let stillEarly = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutTakeProduction\"," &
      "\"recipeId\":\"recipe-slow\"}],\"tm\":2}")
    check("and it is still not finished",
          stillEarly.contains("not finished"), stillEarly.body)

  # The redemption's other half. The identity check stops it being collected
  # twice; this is the ordering one -- a player who drags a reward out and finds
  # it gone after a restart has lost it, which is the failure the whole staged
  # commit exists to prevent.
  if rewardItem.len > 0:
    let kept = call("/client/game/profile/list", "")
    check("the redeemed reward is still in the stash",
          kept.contains(rewardItem), "gone after the restart")
    check("and it is not back in the mailbox as well",
          not call("/client/mail/dialog/list", "").contains(rewardItem),
          "the message still holds it")

  # An offer that has run out of time comes back by post rather than being
  # dropped, and posting it is the only way the player can be given items when
  # there is nobody logged in to receive a diff.
  if retimedFlea and rewardItem.len > 0:
    let listing = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"RagFairAddOffer\",\"sellInOnePiece\":false," &
      "\"items\":[\"" & rewardItem & "\"],\"requirements\":[{\"_tpl\":\"" &
      "5449016a4bdc2d6f028b456f\",\"count\":999999}]}],\"tm\":2}")
    check("an item can be listed on the retimed market",
          listing.ok and not listing.contains("not here"), listing.body)
    check("and it leaves the stash",
          not call("/client/game/profile/list", "").contains(rewardItem),
          "still in the profile")
    # Settling happens at login as well as on a timer, for the same reason
    # insurance returns do: a server that was off when an offer came due must
    # still settle it, and a timer alone never does.
    discard call("/client/game/profile/select", "{\"uid\":\"" & uid & "\"}")
    let inbox = call("/client/mail/dialog/list", "")
    check("an expired offer comes back by mail",
          inbox.contains("expired"), inbox.body)
    check("with the item that was in it",
          inbox.contains(rewardItem), "the message carries no items")

  if not keep:
    cSpawnKill(proc2)

  heading "Result"
  if gFailures > 0:
    err $gFailures & " of " & $gChecks & " failed"
    return 1
  ok "the emulator answered all " & $gChecks & " checks"
  result = 0

quit(main())
