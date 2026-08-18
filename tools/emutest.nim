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
    # The barter in the fixture's assort must not be one of them: it has no
    # price, and an offer with no price is free at the top of every
    # cheapest-first search.
    check("the trader's barter is not on the flea",
          find(offersOf(page.body), "\"_tpl\":\"590c657e86f77412b013051d\"") < 0,
          offersOf(page.body))

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

  heading "A raid"
  discard expectIn("raid configuration is accepted",
                   "/client/raid/configuration",
                   "{\"location\":\"factory4_day\",\"timeVariant\":\"CURR\"," &
                   "\"raidMode\":\"Local\",\"side\":\"Pmc\"}", "\"err\":0")
  discard expectIn("the map hands over its loot",
                   "/client/location/getLocalloot",
                   "{\"locationId\":\"factory4_day\",\"variantId\":0}", "Loot")
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

  if not keep:
    cSpawnKill(proc2)

  heading "Result"
  if gFailures > 0:
    err $gFailures & " of " & $gChecks & " failed"
    return 1
  ok "the emulator answered all " & $gChecks & " checks"
  result = 0

quit(main())
