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

proc callAs(session, path, body: string): Response =
  ## A request carrying a session this suite chose rather than the one every
  ## other call here shares.
  ##
  ## The launcher's whole claim is that a profile can be bound to a token
  ## *before* a client exists, and that the token is the profile's own id -- so
  ## proving it means asking as that id, from a caller that never selected
  ## anything.
  result = request(gPort, path, body, session)

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

proc idBefore(body: string; at: int): string =
  ## The `_id` of the object containing the position `at` -- the nearest
  ## `"_id":"` scanning *backwards*.
  ##
  ## `idOfTemplate` does the same walk from a template; this does it from any
  ## marker, which is what a check needs when the thing it can recognise a row
  ## by is not the row's template. A flea row is recognised by its seller, and
  ## the seller's nickname sits inside `user`, well after the row's own `_id`
  ## and well before the next row's -- so reading forward would find the id of
  ## the row after the one being looked for.
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

proc idOfQuestIn(body: string; index: int): string =
  ## The id of the n-th generated quest in an `activityPeriods` body.
  ##
  ## Read off `questStatus.qid` rather than off the quest's own `_id`, and that
  ## is not arbitrary: a generated quest carries a rouble reward, the reward
  ## carries a real item document, and that document has an `_id` of its own.
  ## Counting `_id` would find the money.
  result = ""
  var at = 0
  var seen = 0
  while true:
    let mark = findFrom(body, "\"qid\":\"", at)
    if mark < 0:
      return ""
    if seen == index:
      var k = mark + 7
      result = ""
      while k < body.len and body[k] != '"':
        result.add body[k]
        inc k
      return result
    inc seen
    at = mark + 7

proc idsOfTemplate(body, tpl: string): seq[string] =
  ## Every item id carrying this template, in document order.
  ##
  ## `idOfTemplate` answers with the first, which is right when there is one of
  ## something and wrong when a check needs to name three separate items -- a
  ## barter costing three of a template the player holds as three items of one
  ## each cannot be paid for by naming the same id three times.
  result = @[]
  var i = 0
  while true:
    let at = findFrom(body, "\"_tpl\":\"" & tpl & "\"", i)
    if at < 0:
      return
    var k = at
    while k > 0:
      if k + 7 < body.len and body.substr(k, k + 6) == "\"_id\":\"":
        var m = k + 7
        var id = ""
        while m < body.len and body[m] != '"':
          id.add body[m]
          inc m
        result.add id
        break
      dec k
    i = at + 8

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

proc skillOf(listBody, id: string): string =
  ## One skill's progress as the text the server wrote. `endurance` above
  ## truncates, which is right for the raid checks and wrong here: a workout
  ## grants a fraction of a point and a truncating read calls that zero.
  let at = find(listBody, "\"Id\":\"" & id & "\"")
  if at < 0:
    return ""
  var i = findFrom(listBody, "\"Progress\":", at)
  if i < 0:
    return ""
  i = i + len("\"Progress\":")
  result = ""
  while i < listBody.len and listBody[i] != ',' and listBody[i] != '}':
    result.add listBody[i]
    inc i

proc skillMoved(before, after: string): bool =
  ## Whether a skill's progress went up. Compared as text and as a truncated
  ## number, because either alone misses a case: a grant under one point moves
  ## the text and not the number, and a grant of exactly nothing moves neither.
  if before == after:
    return false
  result = true

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

proc profileOf(listBody, uid: string): string =
  ## One profile document, cut out of a `profile/list` response.
  ##
  ## Needed for counting as much as for posting: the list holds the PMC *and*
  ## the scav, and the scav's item list is the PMC's stash spliced in at read
  ## time -- so every stash item appears twice in the response and a count over
  ## the whole body reports two of everything.
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
  result = listBody.substr(at, i)

proc raidProfile(listBody, uid: string): string =
  ## The profile out of a `profile/list` response, with its experience changed,
  ## as the client would hand it back after a raid. Cut out of the response text
  ## rather than rebuilt: the point of the check downstream is that the server
  ## accepts the client's own document, not a tidy one this test made up.
  var doc = profileOf(listBody, uid)
  if doc.len == 0:
    return ""
  let expAt = find(doc, "\"Experience\":")
  if expAt < 0:
    return doc
  var j = expAt + len("\"Experience\":")
  var k = j
  while k < doc.len and doc[k] != ',' and doc[k] != '}':
    inc k
  result = doc.substr(0, j - 1) & "1234" & doc.substr(k)

proc withVictims(profileDoc, victimsJson: string): string =
  ## The profile with its `Stats.Eft.Victims` array replaced.
  ##
  ## Replaced inside the document the client hands back, rather than passed
  ## beside it: `questcond.killCredit` reads the victim list out of the profile
  ## the raid was played with, and a test that handed the server a tidy list of
  ## its own would prove nothing about the document the client actually sends.
  let key = "\"Victims\":["
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
    inc i
  # `i` is one past the closing bracket; the replacement carries its own.
  result = profileDoc.substr(0, at + key.len - 2) & victimsJson &
           profileDoc.substr(i)

proc questStatus(listBody, uid, qid: string): string =
  ## One quest's status out of a `profile/list` response. The entry is written
  ## `qid` first and `status` second, so reading forward from the id finds this
  ## quest's status and not the next one's.
  let doc = profileOf(listBody, uid)
  let at = find(doc, "\"qid\":\"" & qid & "\"")
  if at < 0:
    return ""
  result = textAt(doc, at, "status")

proc rowOf(listBody, dialogId: string): int =
  ## Where one `/client/mail/dialog/list` row starts, or -1.
  ##
  ## Found by the row's own `_id`, which is the *sender*: the message nested
  ## inside the row carries an `_id` of its own, so anything that scanned for
  ## the next `"_id"` would land inside the wrong object.
  result = find(listBody, "\"_id\":\"" & dialogId & "\"")

proc flagAt(body: string; start: int; key: string): int =
  ## `"key":true` / `"key":false` at or after `start`: 1, 0, or -1 for absent.
  ## `numberAt` reads neither, and a check that cannot tell a false from a
  ## missing member is a check that passes against a route that answers
  ## nothing.
  if start < 0:
    return -1
  let at = findFrom(body, "\"" & key & "\":", start)
  if at < 0:
    return -1
  let i = at + key.len + 3
  if i + 4 <= body.len and body.substr(i, i + 3) == "true":
    return 1
  if i + 5 <= body.len and body.substr(i, i + 4) == "false":
    return 0
  result = -1

proc objectAt(body: string; start: int): string =
  ## The `{...}` beginning at `start`, brace-matched and string-aware. The one
  ## primitive the readers below share: a JSON object cut out of a response
  ## without parsing the rest of it, so a check can be made against exactly the
  ## sub-document it is about rather than against a body that also mentions the
  ## same key somewhere else.
  if start < 0 or start >= body.len or body[start] != '{':
    return ""
  var depth = 0
  var i = start
  var inString = false
  while i < body.len:
    let c = body[i]
    if inString:
      if c == '\\': inc i
      elif c == '"': inString = false
    elif c == '"': inString = true
    elif c == '{': inc depth
    elif c == '}':
      dec depth
      if depth == 0:
        return body.substr(start, i)
    inc i
  result = ""

proc memberObject(body, key: string): string =
  ## The object value of `"key":{...}`, or "" when the key is not there or does
  ## not hold an object.
  let at = find(body, "\"" & key & "\":{")
  if at < 0:
    return ""
  result = objectAt(body, at + key.len + 3)

proc traderEntry(profileDoc, traderId: string): string =
  ## One trader's `TradersInfo` entry out of a profile document.
  ##
  ## Read out of `TradersInfo` rather than out of the whole document, because
  ## the trader id appears elsewhere in a profile -- an insured item names it,
  ## and so does a mail message -- and a check that found one of those would be
  ## reading a number that is not the standing.
  let info = memberObject(profileDoc, "TradersInfo")
  if info.len == 0:
    return ""
  result = memberObject(info, traderId)

proc withoutItem(profileDoc, itemId: string): string =
  ## The profile with one item taken out of `Inventory.items`, as the client
  ## would hand it back after a raid it did not bring that item out of. The
  ## comma before or after it goes with it, so the result is still an array the
  ## server can parse -- a test that produced invalid JSON here would be
  ## measuring the parser rather than the insurance.
  let at = find(profileDoc, "{\"_id\":\"" & itemId & "\"")
  if at < 0:
    return ""
  let obj = objectAt(profileDoc, at)
  if obj.len == 0:
    return ""
  var first = at
  var last = at + obj.len - 1
  if first > 0 and profileDoc[first - 1] == ',':
    dec first
  elif last + 1 < profileDoc.len and profileDoc[last + 1] == ',':
    inc last
  result = profileDoc.substr(0, first - 1) & profileDoc.substr(last + 1)

proc withPartHealth(profileDoc, part: string; current: int): string =
  ## The profile with one body part's `Current` health changed -- a raid the
  ## player came out of hurt. Edited in the text the server itself produced so
  ## that everything else about the document is byte-for-byte what it was.
  let partAt = find(profileDoc, "\"" & part & "\":{")
  if partAt < 0:
    return ""
  let currentAt = findFrom(profileDoc, "\"Current\":", partAt)
  if currentAt < 0:
    return ""
  var j = currentAt + len("\"Current\":")
  var k = j
  while k < profileDoc.len and profileDoc[k] != ',' and profileDoc[k] != '}':
    inc k
  result = profileDoc.substr(0, j - 1) & $current & profileDoc.substr(k)

proc withPartEffects(profileDoc, part, effectsJson: string): string =
  ## The profile with an `Effects` map written onto one body part -- a raid the
  ## player came out of with a fracture.
  ##
  ## There is no route on this server that *gives* a player an effect: the
  ## client applies them during a raid and hands the profile back with them on
  ## it, exactly as it does damage. So this is how a trader treatment gets
  ## something to treat, and it is the same route `withPartHealth` uses for the
  ## same reason -- the server's own document, one member added.
  let partAt = find(profileDoc, "\"" & part & "\":{")
  if partAt < 0:
    return ""
  let cut = partAt + part.len + 4
  result = profileDoc.substr(0, cut - 1) & "\"Effects\":" & effectsJson & "," &
           profileDoc.substr(cut)

proc effectsOf(profileDoc, part: string): string =
  ## One body part's `Effects` map as text, or "" when it has none.
  ##
  ## Cut out of the part's own object rather than searched for in the whole
  ## document, because `Effects` is optional: a search forward from a part that
  ## has none finds the next part that does, and a check written against that
  ## reads one leg's fracture as the other's.
  result = memberObject(memberObject(profileDoc, part), "Effects")

proc scavProductsOf(profileDoc, recipeId: string): seq[string] =
  ## The templates a running scav case rolled, off `sptScavProducts`.
  ##
  ## Read from the production record rather than from what landed in the stash,
  ## because the whole point of the rule is that the roll happens at *start*:
  ## reading it from the stash could not tell a case rolled at start from one
  ## rolled at collection.
  result = @[]
  let at = find(profileDoc, "\"" & recipeId & "\":{")
  if at < 0:
    return
  let key = findFrom(profileDoc, "\"sptScavProducts\":[", at)
  if key < 0:
    return
  var i = key + len("\"sptScavProducts\":[")
  while i < profileDoc.len and profileDoc[i] != ']':
    if profileDoc[i] == '"':
      var tpl = ""
      inc i
      while i < profileDoc.len and profileDoc[i] != '"':
        tpl.add profileDoc[i]
        inc i
      result.add tpl
    inc i

proc withExtraItems(profileDoc, itemsJson: string): string =
  ## The profile with more items in `Inventory.items` -- gear the player walked
  ## out of a raid with.
  ##
  ## This is how the repair and marker checks below get something to work on,
  ## and it is deliberately not "add an offer to the fixture's assort": an
  ## assort entry becomes a flea offer, and the flea checks in this file pin
  ## counts that an extra offer would move. It is also the honest route --
  ## bringing an item home from a raid is exactly how a player gets one.
  ##
  ## `itemsJson` is inserted at the *front* of the array, without a trailing
  ## comma when the array is empty, which it never is on a real profile.
  let key = "\"items\":["
  let at = find(profileDoc, key)
  if at < 0:
    return ""
  let start = at + key.len
  var body = itemsJson
  if start < profileDoc.len and profileDoc[start] != ']':
    body = body & ","
  result = profileDoc.substr(0, start - 1) & body & profileDoc.substr(start)

proc withNumber(profileDoc, key: string; value: int): string =
  ## The profile with the first `"key":<number>` replaced. Used for `Level`,
  ## which no route on this server moves and an achievement condition reads.
  let at = find(profileDoc, "\"" & key & "\":")
  if at < 0:
    return ""
  var j = at + key.len + 3
  var k = j
  while k < profileDoc.len and profileDoc[k] != ',' and profileDoc[k] != '}':
    inc k
  result = profileDoc.substr(0, j - 1) & $value & profileDoc.substr(k)

proc itemSlice(profileDoc, itemId: string): string =
  ## One item's own text out of a profile, bounded by the next item's `_id`.
  ##
  ## Bounded for the same reason `stackOf` is: read forward without a limit and
  ## an item that does not carry the key being looked for reports the value
  ## belonging to some later item, which reads as a repair that worked and is
  ## the exact mistake these checks exist to catch.
  let at = find(profileDoc, "\"_id\":\"" & itemId & "\"")
  if at < 0:
    return ""
  var stop = findFrom(profileDoc, "\"_id\":\"", at + 7)
  if stop < 0:
    stop = profileDoc.len
  result = profileDoc.substr(at, stop - 1)

proc updNumber(profileDoc, itemId, key: string): int =
  ## A number out of one item, -1 when that item does not carry the key.
  let slice = itemSlice(profileDoc, itemId)
  if slice.len == 0:
    return -1
  result = numberAt(slice, 0, key)

proc roublesIn(profileDoc: string): int =
  ## Every rouble in the stash, across however many stacks they are in.
  ##
  ## Summed rather than read off one stack, because `spendCurrency` picks the
  ## stacks itself -- smallest first -- so "the stack the run started with went
  ## down by 2000" is a check that passes or fails on which stack was chosen
  ## rather than on what was charged.
  result = 0
  let ids = idsOfTemplate(profileDoc, "5449016a4bdc2d6f028b456f")
  for id in ids:
    let n = stackOf(profileDoc, id)
    if n > 0:
      result = result + n

proc rawNumberAt(body: string; start: int; key: string): string =
  ## The number at `"key":` as the text the server actually wrote.
  ##
  ## `numberAt` truncates at the decimal point, which is right for a stack count
  ## and useless for a standing of 0.02 -- it reads that as zero, which passes
  ## against a server that moved nothing. This reads the token, so a check can
  ## compare it exactly and a failure prints what was really there.
  let at = findFrom(body, "\"" & key & "\":", start)
  if at < 0:
    return ""
  var i = at + key.len + 3
  result = ""
  while i < body.len and body[i] != ',' and body[i] != '}' and body[i] != ']':
    result.add body[i]
    inc i

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

proc waitForSelfCheck(tries: int): string =
  ## `/aowlspt/tarkov/selfcheck`, once it answers. "" when it never does.
  ##
  ## Polled **before** `waitForBackend`, and that ordering is the whole reason
  ## this exists. The mod runs its own arithmetic at load and refuses to serve
  ## when any of it does not hold -- and this is the one route it registers on
  ## both paths, deliberately outside `/client/`. Waiting on
  ## `/client/game/config` first would time out on exactly the case this is for
  ## and kill the run at "the backend never answered", which reads the same as
  ## a wrong port, a mod that was never selected, or a cold disk.
  ##
  ## So: wait for the route that always exists, assert what it says as an
  ## ordinary check, and only then wait for the game to be there. A build that
  ## fails its own arithmetic produces one red line naming the failing check
  ## instead of a suite with nothing to talk to.
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

  # -- the fresh-root check, asked of the disk, before the server starts ----
  #
  # There is a second half of this below -- "no profiles on a fresh install",
  # asked of `/client/game/profile/list` -- and it is not enough on its own.
  # It was the only guard for a long time, and this is the hole it left.
  #
  # The store is a directory of files, one per subject: `profile.<id>`, and
  # beside it `market.<id>`, `mail.<id>`, `insurance.<id>`, `builds.<id>`,
  # `repeat.<id>`, `scav.<id>` and the server's own `ids.run`. Delete the
  # profiles alone -- which is what a half-finished cleanup, an interrupted
  # `rm -rf`, or a file still held open by a backend nobody killed leaves
  # behind -- and the profile list answers `[]` quite truthfully. The guard
  # below passes, the run proceeds, and thirteen checks then fail describing
  # the *previous* run: the flea's offer counts include the last run's
  # generated offers, the hideout's crafts are already finished, the insurance
  # cover has already matured and been paid, and the traders' return lines have
  # already been rotated past. Measured, not imagined: deleting `profile.*` and
  # `sessions` from a completed run and leaving the other seven files produces
  # exactly that set of thirteen, and every one of them reads like a bug in
  # whatever the reader last changed.
  #
  # So the question is asked of the store itself, and asked before the backend
  # has had a chance to create `ids.run` in it. A root that has been run
  # against is not fresh no matter what the profile list says.
  let storeDir = joinPath(root, "store")
  if exists(storeDir):
    var storeFiles: seq[string] = @[]
    var storeDirs: seq[string] = @[]
    collectEntries(storeDir, storeFiles, storeDirs)
    if storeFiles.len > 0:
      err "this root already has a store in it; emutest needs an empty one"
      note "delete " & storeDir & " and run again -- all of it, not the " &
           "profiles alone: every check after the boot sequence assumes a " &
           "world this run made"
      note $storeFiles.len & " files are still there, e.g. " &
           baseName(storeFiles[0])
      return 1

  discard cNetStartup()

  heading "Starting"
  var proc1 = startBackend(backend, root)
  if proc1 == 0'u64:
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

  # The cheapest check in this file, and the first one, for the reason
  # `waitForSelfCheck` sets out at length: it is the only route a mod that
  # refused to load still answers, so asking it before anything else turns
  # "nothing in this suite could talk to a server" into one red line naming the
  # arithmetic that did not hold. Today's empty `hideout.customisation` table
  # would have shown up here.
  let selfcheck = waitForSelfCheck(60)
  check("the mod's own arithmetic held at load",
        selfcheck.len > 0 and find(selfcheck, "\"ok\":true") >= 0 and
        find(selfcheck, "\"failures\":[]") >= 0,
        (if selfcheck.len == 0: "/aowlspt/tarkov/selfcheck never answered"
         else: selfcheck))

  if not waitForBackend(60):
    err "the backend never answered /client/game/config"
    cSpawnKill(proc1)
    return 1
  ok "the backend is serving on " & $gPort

  # -- the launcher, before there is anything to launch ----------------------
  #
  # These have to answer at the one moment nothing else here can be asked
  # anything: no profile, no session, no token. That is the state a person is
  # in the first time they install this, and it is the state the launcher has
  # to be able to describe.
  heading "The launcher, on an empty store"
  let ping0 = call("/aowlspt/tarkov/launcher/ping", "")
  check("the launcher can tell there is a server here",
        ping0.ok and ping0.contains("\"ok\":true") and
        ping0.contains("\"server\":\"aowlspt\""), ping0.body)
  check("and that it has nothing to play yet",
        ping0.contains("\"profiles\":0"), ping0.body)
  let empty0 = call("/aowlspt/tarkov/launcher/profiles", "")
  check("an empty profile list is an answer rather than a failure",
        empty0.ok and empty0.contains("\"ok\":true") and
        empty0.contains("\"profiles\":[]"), empty0.body)
  let nobody = call("/aowlspt/tarkov/launcher/profile/select",
                    "{\"id\":\"cccccccccccccccccccccccc\"}")
  check("selecting a profile that is not there is refused, not bound",
        nobody.ok and nobody.contains("\"ok\":false"), nobody.body)
  let tooShort = call("/aowlspt/tarkov/launcher/profile/create",
                      "{\"nickname\":\"ab\",\"side\":\"Usec\"}")
  check("and a nickname the client would refuse is refused here first",
        tooShort.ok and tooShort.contains("\"ok\":false"), tooShort.body)
  check("nothing was created by either refusal",
        call("/aowlspt/tarkov/launcher/ping", "").contains("\"profiles\":0"),
        call("/aowlspt/tarkov/launcher/profiles", "").body)

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
    "{\"data\":[{\"Action\":\"Split\",\"splitItem\":\"" & moneyId &
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

  heading "Nothing may contain itself"
  # Three requests that each destroyed a profile from one ordinary-looking body,
  # `err:0`, no warning. They are here rather than at the end because everything
  # after this point is checked against a stash that has to still exist.
  #
  # Every check asserts the refusal *and* the state. A server that answered
  # "refused" and wrote the parent anyway would pass a check that only read the
  # message, and that is the exact shape of the bug.
  let selfMove = call("/client/game/profile/items/moving",
    "{\"data\":[{\"Action\":\"Move\",\"item\":\"" & moneyId &
    "\",\"to\":{\"id\":\"" & moneyId & "\",\"container\":\"hideout\"}}]," &
    "\"tm\":2}")
  check("moving an item into itself is refused",
        selfMove.contains("inside itself"), selfMove.body)
  check("and its parent is untouched",
        find(profileOf(call("/client/game/profile/list", "").body, uid),
             "\"parentId\":\"" & moneyId & "\"") < 0,
        "the item is its own parent")

  # The one that cannot be undone. The client draws the stash by walking
  # `parentId` down from the root, so a root inside its own subtree is a stash
  # that draws nothing -- and the drag that would fix it has to reach an item
  # the client can no longer see.
  let stashId = jsonText(profileOf(call("/client/game/profile/list", "").body,
                                   uid), "stash")
  check("the test found the stash", stashId.len == 24, stashId)
  let rootIntoChild = call("/client/game/profile/items/moving",
    "{\"data\":[{\"Action\":\"Move\",\"item\":\"" & stashId &
    "\",\"to\":{\"id\":\"" & moneyId & "\",\"container\":\"main\"}}],\"tm\":2}")
  check("moving the stash into something the stash holds is refused",
        rootIntoChild.contains("inside itself"), rootIntoChild.body)
  let stillRooted = profileOf(call("/client/game/profile/list", "").body, uid)
  check("and the stash still has no parent",
        find(stillRooted, "\"_id\":\"" & stashId & "\",\"_tpl\"") >= 0 and
        find(stillRooted, "\"_id\":\"" & stashId & "\",\"parentId\"") < 0,
        "the stash gained a parent")

  # And the swap, which is two moves in one action and had the same hole.
  let selfSwap = call("/client/game/profile/items/moving",
    "{\"data\":[{\"Action\":\"Swap\",\"item\":\"" & stashId &
    "\",\"item2\":\"" & moneyId & "\"," &
    "\"to\":{\"id\":\"" & moneyId & "\",\"container\":\"main\"}," &
    "\"to2\":{\"id\":\"" & stashId & "\",\"container\":\"hideout\"}}],\"tm\":2}")
  check("a swap that would do the same is refused too",
        selfSwap.contains("inside itself"), selfSwap.body)
  check("and neither item moved",
        find(profileOf(call("/client/game/profile/list", "").body, uid),
             "\"_id\":\"" & stashId & "\",\"parentId\"") < 0,
        "the stash gained a parent")

  # And the hole the cycle check does not see, which is the same damage.
  #
  # A profile is built on five containers -- the stash, the equipment root, the
  # two quest containers and the sorting table -- and they are exactly the items
  # with **no parent**. Putting the stash inside the *equipment* root closes no
  # loop at all: `wouldCycle` walks up from the destination, lands on the
  # equipment root, finds no parent, and says the move is fine. The client draws the
  # stash by walking down from a root that is now somebody's child, and draws
  # nothing.
  #
  # `ApplyInventoryChanges` had this closed; plain `Move` and `Swap` did not.
  let equipmentId = jsonText(profileOf(call("/client/game/profile/list", "").body,
                                       uid), "equipment")
  check("the test found the equipment root", equipmentId.len == 24, equipmentId)
  let uproot = call("/client/game/profile/items/moving",
    "{\"data\":[{\"Action\":\"Move\",\"item\":\"" & stashId &
    "\",\"to\":{\"id\":\"" & equipmentId & "\",\"container\":\"main\"}}]," &
    "\"tm\":2}")
  check("moving the stash into another root container is refused",
        uproot.contains("this profile is built on"), uproot.body)
  let afterUproot = profileOf(call("/client/game/profile/list", "").body, uid)
  check("and the stash still has no parent",
        find(afterUproot, "\"_id\":\"" & stashId & "\",\"parentId\"") < 0,
        "the stash gained a parent")

  # The other direction, so the check is not passing because one particular id
  # happens to be special-cased.
  let uprootEq = call("/client/game/profile/items/moving",
    "{\"data\":[{\"Action\":\"Move\",\"item\":\"" & equipmentId &
    "\",\"to\":{\"id\":\"" & stashId & "\",\"container\":\"hideout\"}}]," &
    "\"tm\":2}")
  check("and so is moving the equipment root into the stash",
        uprootEq.contains("this profile is built on"), uprootEq.body)
  check("and the equipment root still has no parent",
        find(profileOf(call("/client/game/profile/list", "").body, uid),
             "\"_id\":\"" & equipmentId & "\",\"parentId\"") < 0,
        "the equipment root gained a parent")

  # And the swap, which is two moves in one action and had the same hole a
  # second time.
  let uprootSwap = call("/client/game/profile/items/moving",
    "{\"data\":[{\"Action\":\"Swap\",\"item\":\"" & stashId &
    "\",\"item2\":\"" & moneyId & "\"," &
    "\"to\":{\"id\":\"" & equipmentId & "\",\"container\":\"main\"}," &
    "\"to2\":{\"id\":\"" & stashId & "\",\"container\":\"hideout\"}}],\"tm\":2}")
  check("a swap that would uproot a container is refused too",
        uprootSwap.contains("this profile is built on"), uprootSwap.body)
  let afterSwap = profileOf(call("/client/game/profile/list", "").body, uid)
  check("and neither container moved",
        find(afterSwap, "\"_id\":\"" & stashId & "\",\"parentId\"") < 0 and
        find(afterSwap, "\"_id\":\"" & equipmentId & "\",\"parentId\"") < 0,
        "a container gained a parent")
  # The money was the other half of that swap, and a refused action must not
  # have applied half of itself.
  check("and the money is still where it was",
        stackOf(call("/client/game/profile/list", "").body, moneyId) > 0,
        "the swap moved the money anyway")

  # Listing the stash on the flea took it and everything under it out of the
  # profile: `Inventory.stash` came back naming an item that was no longer in
  # `items`, and every rouble went with it.
  let listRoot = call("/client/game/profile/items/moving",
    "{\"data\":[{\"Action\":\"RagFairAddOffer\",\"sellInOnePiece\":false," &
    "\"items\":[\"" & stashId & "\"],\"requirements\":[{\"_tpl\":" &
    "\"5449016a4bdc2d6f028b456f\",\"count\":1}]}],\"tm\":2}")
  check("listing the stash itself on the flea is refused",
        listRoot.contains("the inventory is built on"), listRoot.body)
  let intact = profileOf(call("/client/game/profile/list", "").body, uid)
  check("and the stash is still in the item list",
        find(intact, "\"_id\":\"" & stashId & "\"") >= 0,
        "Inventory.stash names an item that is gone")
  check("and the money is still in it",
        stackOf(call("/client/game/profile/list", "").body, moneyId) > 0,
        "the stash was emptied")

  # A quest the database has never heard of is accepted -- a server with no
  # quest table still has to let a client play -- but the player is told, rather
  # than getting `err:0` and wondering where the reward went.
  let unknownQuest = call("/client/game/profile/items/moving",
    "{\"data\":[{\"Action\":\"QuestAccept\"," &
    "\"qid\":\"dddddddddddddddddddddddd\"}],\"tm\":2}")
  check("accepting a quest this server has no template for says so",
        unknownQuest.contains("no template for it"), unknownQuest.body)

  heading "Trading"
  # An item the player holds exactly one of, kept for the handover check in the
  # quest section: clamping a claimed count to what the profile actually has
  # cannot be tested against a stack of half a million roubles.
  var smallStackId = ""
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
    # Two things at once, and the second is the one that was broken. The payout
    # has to be the handbook price, and it has to go into the rouble stack that
    # is already in the stash -- 475000 + 22000 in place. `giveItem` used to
    # open a *new* stack for every payout, purchase, craft output and mail
    # reward: a soak of 200 play cycles ended with 407 loose items in a stash
    # that started with five, and average request latency went 797 us to 105 ms
    # as the profile document grew with them. `"new":[]` is the half that pins
    # it -- checking only for 497000 passes against a server that also created
    # a second stack beside it.
    check("selling it back pays the handbook price",
          sold.ok and sold.contains("497000"), sold.body)
    check("and pays into the stack already there rather than opening a new one",
          find(sold.body, "\"new\":[]") >= 0, sold.body)

    # And the refusal: paying from a stack that does not hold enough must take
    # nothing at all, rather than taking what is there.
    let broke = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"TradingConfirm\",\"type\":\"buy_from_trader\"," &
      "\"tid\":\"54cb50c76803fa8b248b4571\",\"item_id\":\"aaaaaaaaaaaaaaaaaaaaaaa1\"," &
      "\"count\":1,\"scheme_items\":[{\"id\":\"" & moneyId &
      "\",\"count\":99999999}]}],\"tm\":2}")
    check("a payment larger than the stack is refused",
          broke.contains("not enough in that stack"), broke.body)

    # -- what the request is not allowed to decide ---------------------------
    #
    # Free money. `sell_to_trader` used to multiply the handbook price by the
    # count in the *request* without ever looking at the stack, so one water
    # bottle sold as five paid 75000 for a 15000 item, err:0, no warning. The
    # amount is checked as well as the refusal: a server that refuses and pays
    # anyway would pass a check that only read the message.
    let moneyBeforeFraud =
      stackOf(call("/client/game/profile/list", "").body, moneyId)
    let overSell = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"TradingConfirm\",\"type\":\"sell_to_trader\"," &
      "\"tid\":\"54cb50c76803fa8b248b4571\",\"items\":[{\"id\":\"" & moneyId &
      "\",\"count\":99999999}]}],\"tm\":2}")
    check("selling more of a stack than it holds is refused",
          overSell.contains("that stack holds"), overSell.body)
    let moneyAfterFraud =
      stackOf(call("/client/game/profile/list", "").body, moneyId)
    check("and pays nothing for it", moneyAfterFraud == moneyBeforeFraud,
          $moneyBeforeFraud & " became " & $moneyAfterFraud)

    # The buy side of the same rule. `takePayment` only ever checked that the
    # stacks named held what the request claimed they held -- it has no idea
    # what the thing being bought costs, so a body naming one rouble bought the
    # 25000-rouble rifle and delivered it.
    let cheat = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"TradingConfirm\",\"type\":\"buy_from_trader\"," &
      "\"tid\":\"54cb50c76803fa8b248b4571\",\"item_id\":\"aaaaaaaaaaaaaaaaaaaaaaa1\"," &
      "\"count\":1,\"scheme_items\":[{\"id\":\"" & moneyId &
      "\",\"count\":1}]}],\"tm\":2}")
    check("paying a rouble for a 25000-rouble offer is refused",
          cheat.contains("that offer costs 25000"), cheat.body)
    let afterCheat = call("/client/game/profile/list", "")
    check("and the item is not delivered",
          not afterCheat.contains("5644bd2b4bdc2d3b4c8b4572"),
          "the rifle is in the stash")

    # And the count is multiplied into the price rather than being free.
    let bulkCheat = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"TradingConfirm\",\"type\":\"buy_from_trader\"," &
      "\"tid\":\"54cb50c76803fa8b248b4571\",\"item_id\":\"aaaaaaaaaaaaaaaaaaaaaaa2\"," &
      "\"count\":3,\"scheme_items\":[{\"id\":\"" & moneyId &
      "\",\"count\":1200}]}],\"tm\":2}")
    check("buying three at the price of one is refused",
          bulkCheat.contains("that offer costs 3600"), bulkCheat.body)

    # -- StackMaxSize, the other half of the giveItem fix --------------------
    #
    # Three of a template whose `StackMaxSize` is 1 must arrive as three items.
    # `count` used to be written straight into `StackObjectsCount`, which makes
    # one item claiming to be three -- a stack over its own template's limit,
    # which the client will not render and `Merge` will not touch.
    let bulk = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"TradingConfirm\",\"type\":\"buy_from_trader\"," &
      "\"tid\":\"54cb50c76803fa8b248b4571\",\"item_id\":\"aaaaaaaaaaaaaaaaaaaaaaa2\"," &
      "\"count\":3,\"scheme_items\":[{\"id\":\"" & moneyId &
      "\",\"count\":3600}]}],\"tm\":2}")
    check("buying three of a stack-of-one item is accepted",
          bulk.ok and not bulk.contains("costs"), bulk.body)
    check("and arrives as three items, not one stack of three",
          countOf(bulk.body, "\"_tpl\":\"544fb45d4bdc2dee738b4568\"") == 3 and
          not bulk.contains("\"StackObjectsCount\":3}"), bulk.body)
    smallStackId = idOfTemplate(call("/client/game/profile/list", "").body,
                                "544fb45d4bdc2dee738b4568")
  else:
    note "no database fixture; skipping the trading checks"

  heading "Trader loyalty"
  # Loyalty is *derived*, not awarded: `TraderLoyaltyLevel` in the reference is
  # three requirements -- `minLevel`, `minSalesSum`, `minStanding` -- and the
  # profile's `TraderInfo` carries the three numbers they are checked against.
  # So the checks here are arithmetic on numbers this run put there itself.
  #
  # `expectedSales` is kept from here to the restart. Every later section that
  # trades adds to it, and the restart asserts the exact figure -- which is the
  # only way to tell a server that accumulates turnover from one that stores
  # whatever the last request happened to mention.
  var expectedSales = 0
  if haveFixture:
    # 25000 for the rifle, 22000 back for selling it, 3600 for three Salewas.
    # Turnover, not spend: `TraderInfo.salesSum` counts money that changed
    # hands in either direction, so the sale is added and not subtracted.
    expectedSales = 25000 + 22000 + 3600
    let afterTrading = profileOf(call("/client/game/profile/list", "").body, uid)
    let prapor = traderEntry(afterTrading, "54cb50c76803fa8b248b4571")
    check("the trader remembers what changed hands",
          jsonNumber(prapor, "salesSum") == expectedSales,
          "salesSum is " & $jsonNumber(prapor, "salesSum") & ", not " &
          $expectedSales)
    # The fixture's Prapor has three levels: LL2 wants 20000 of turnover and
    # nothing else, LL3 wants 40000 *and* 50 standing. The turnover is past
    # both; the standing is not, so the answer is 2. A server that took the
    # best-matching level anywhere in the array rather than every requirement
    # of one would say 3.
    check("and the loyalty level it earns is derived from them",
          jsonNumber(prapor, "loyaltyLevel") == 2,
          "loyaltyLevel is " & $jsonNumber(prapor, "loyaltyLevel") & ", not 2")

    # The gate. The fixture puts the barter behind LL3, which is unreachable,
    # so this is a purchase the client would have greyed out -- and one an
    # edited client would otherwise get for the price of a stale screen.
    let salewasBefore =
      countOf(profileOf(call("/client/game/profile/list", "").body, uid),
              "\"_tpl\":\"544fb45d4bdc2dee738b4568\"")
    # Paid for properly: three separate Salewas, which is exactly what the
    # barter asks for and what the purchase would go through on if the gate
    # were not there. A payment the server would refuse anyway proves nothing
    # about the gate.
    let salewaIds = idsOfTemplate(
      profileOf(call("/client/game/profile/list", "").body, uid),
      "544fb45d4bdc2dee738b4568")
    var barterPayment = ""
    for id in salewaIds:
      if barterPayment.len > 0: barterPayment.add ","
      barterPayment.add "{\"id\":\"" & id & "\",\"count\":1}"
    check("the player holds the three the barter costs", salewaIds.len == 3,
          $salewaIds.len & " Salewas")
    let gated = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"TradingConfirm\",\"type\":\"buy_from_trader\"," &
      "\"tid\":\"54cb50c76803fa8b248b4571\",\"item_id\":\"aaaaaaaaaaaaaaaaaaaaaaa3\"," &
      "\"count\":1,\"scheme_items\":[" & barterPayment & "]}],\"tm\":2}")
    check("an offer above the player's loyalty level is refused",
          gated.contains("needs loyalty level 3"), gated.body)
    let salewasAfter =
      countOf(profileOf(call("/client/game/profile/list", "").body, uid),
              "\"_tpl\":\"544fb45d4bdc2dee738b4568\"")
    # And refused before the payment, not after it. A gate checked after
    # `takePayment` takes the barter and hands back nothing.
    check("and the barter it would have cost is untouched",
          salewasAfter == salewasBefore,
          $salewasBefore & " Salewas became " & $salewasAfter)
    check("and nothing was delivered",
          not gated.contains("590c657e86f77412b013051d"), gated.body)

    # The two trader routes that were never served at all. `getTrader` is one
    # base where `traderSettings` is all of them, and `items/prices` is what
    # the trader screen divides by to draw its flea comparison -- a body
    # without a `prices` key is a division on a null.
    let one = call("/client/trading/api/getTrader/54cb50c76803fa8b248b4571", "")
    check("one trader can be asked for on its own",
          one.contains("Prapor") and one.contains("loyaltyLevels"), one.body)
    let noSuch = call("/client/trading/api/getTrader/cccccccccccccccccccccccc",
                      "")
    check("and a trader that does not exist is refused, not invented",
          not noSuch.contains("\"err\":0"), noSuch.body)
    let prices = call("/client/items/prices/54cb50c76803fa8b248b4571", "")
    check("item prices answer the three keys the screen reads",
          prices.contains("\"supplyNextTime\":") and
          prices.contains("\"prices\":{") and
          prices.contains("\"currencyCourses\":"), prices.body)
    check("and the prices are the handbook's",
          prices.contains("\"5644bd2b4bdc2d3b4c8b4572\":22000"), prices.body)
  else:
    note "no database fixture; skipping the loyalty checks"

  heading "The flea market"
  # Here rather than at the end, because the flea needs exactly what the trader
  # counter above needed and nothing more: a handbook to price offers off, a
  # trader whose stock becomes offers, a stash to put a purchase in and a stack
  # of roubles to pay with. Every filter check reads `offersOf` rather than the
  # whole body -- see the note there.
  if haveFixture:
    let page = call("/client/ragfair/find",
      "{\"page\":0,\"limit\":50,\"sortType\":5,\"sortDirection\":0}")
    check("a search returns offers", page.contains("\"offers\":[{"), page.body)
    check("and says how many matched",
          jsonNumber(page.body, "offersCount") > 5,
          $jsonNumber(page.body, "offersCount") & " offers")
    # Both halves of the list are on it.
    #
    # This is the check the flea's composition needed and did not have: the
    # traders' stock used to be poured into the list until the cap was spent
    # and the generated offers ran afterwards against a list that was already
    # full. On this fixture there is room for both and the fault was invisible;
    # against a real database the market was 600 rows of three traders' stock
    # and not one generated offer, so nothing that was not already on a trader
    # screen could be bought anywhere in the game.
    let mixed = call("/client/ragfair/find", "{\"page\":0,\"limit\":50}")
    let mixedRows = offersOf(mixed.body)
    check("the page carries trader stock and generated offers both",
          find(mixedRows, "\"memberType\":4") >= 0 and
          find(mixedRows, "\"memberType\":0") >= 0, mixedRows)

    # And a template *only* the handbook prices -- no trader has one at any
    # loyalty level, in any currency, in any barter -- is on it and can be
    # bought. That class of item is the whole of what fell off the flea, and it
    # is the class most hideout stage materials are in.
    const OnlyHandbook = "5710c24ad2720bc3458b45a3"
    let onlyRows = offersOf(call("/client/ragfair/find",
      "{\"page\":0,\"limit\":5,\"currency\":1,\"handbookId\":\"" &
      OnlyHandbook & "\"}").body)
    check("a template only the handbook prices is on the flea",
          find(onlyRows, "\"_tpl\":\"" & OnlyHandbook & "\"") >= 0 and
          find(onlyRows, "\"memberType\":0") >= 0, onlyRows)
    let onlyId = textAt(onlyRows, 0, "_id")
    let onlyCost = jsonNumber(onlyRows, "summaryCost")
    # Above the handbook's 350, because the handbook price is what a trader
    # pays you and no player sells for that.
    check("and priced over the handbook rather than at it",
          onlyId.len == 24 and onlyCost > 350, $onlyCost & " for " & onlyId)
    let onlyBefore = stackOf(call("/client/game/profile/list", "").body, moneyId)
    let onlyBought = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"RagFairBuyOffer\",\"offers\":[{\"id\":\"" &
      onlyId & "\",\"count\":1,\"items\":[{\"id\":\"" & moneyId &
      "\",\"count\":" & $onlyCost & "}]}]}],\"tm\":2}")
    check("and it can be bought there",
          onlyBought.ok and onlyBought.contains(OnlyHandbook), onlyBought.body)
    let afterBuy = call("/client/game/profile/list", "").body
    let onlyAfter = stackOf(afterBuy, moneyId)
    check("for exactly what its row asked",
          onlyBefore - onlyAfter == onlyCost,
          $onlyBefore & " - " & $onlyAfter & " != " & $onlyCost)
    # And the whole lot arrived. An offer sold in one piece is priced for its
    # whole stack, so handing over one of it for the price of three is the same
    # class of error as charging the wrong price, pointing the other way.
    let onlyQty = jsonNumber(onlyRows, "quantity")
    let onlyStack = stackOf(afterBuy, idOfTemplate(afterBuy, OnlyHandbook))
    check("and the whole lot it was priced for arrived",
          onlyStack == onlyQty, $onlyStack & " arrived of " & $onlyQty)

    # The offer is spent, and a fresh one takes its place.
    #
    # Both halves matter and they used to fight. The row has to *go*, or the
    # same offer can be bought until the market next rebuilds -- and an offer
    # sold in one piece goes whole rather than one at a time, which is what the
    # count above is the price of. But the flea also cannot answer "nobody
    # sells bolts" for the next twelve hours because somebody bought the only
    # three: a hideout stage that asks for ten of something is unbuildable
    # against a market that lists three and then forgets the item exists.
    let againRows = offersOf(call("/client/ragfair/find",
      "{\"page\":0,\"limit\":5,\"currency\":1,\"handbookId\":\"" &
      OnlyHandbook & "\"}").body)
    check("the offer that was bought is off the market",
          find(againRows, "\"_id\":\"" & onlyId & "\"") < 0, againRows)
    check("and the flea lists another rather than nothing",
          find(againRows, "\"_tpl\":\"" & OnlyHandbook & "\"") >= 0,
          againRows)

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
    let listed = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"RagFairAddOffer\",\"sellInOnePiece\":false," &
      "\"items\":[\"" & psoId & "\"],\"requirements\":[{\"_tpl\":\"" &
      "5449016a4bdc2d6f028b456f\",\"count\":999999}]}],\"tm\":2}")
    check("listing an item is accepted",
          listed.ok and not listed.contains("not here"), listed.body)
    let afterListing = call("/client/game/profile/list", "")
    check("and takes it out of the stash",
          not afterListing.contains(psoId), "still in the profile")

    # -- renewing it ---------------------------------------------------------
    #
    # `RagFairRenewOffer` was an unhandled action: the client's "extend" button
    # answered `err:0` and the offer expired on its original clock anyway.
    #
    # The offer is found by the seller's nickname rather than by template,
    # because the market also carries *generated* offers for the same template
    # and they are `memberType` 0 as well -- a row picked by template could be
    # somebody else's, and renewing it would move a number this run never set.
    #
    # Both figures come out of the database rather than out of this file: 12
    # hours is inside `globals.config.RagFair.maxRenewOfferTimeInHour` (48) and
    # 99 is not. The refusal has to *name* 48, because a server that refused
    # every renewal -- which is what `maxRenewHours` does when the field is
    # missing, on purpose -- would pass a check that only asserted "refused".
    let mine = offersOf(call("/client/ragfair/find",
      "{\"page\":0,\"limit\":50,\"offerOwnerType\":2}").body)
    let atMine = find(mine, "\"nickname\":\"AowlTest\"")
    let myOfferId = idBefore(mine, atMine)
    let endBefore = numberAt(mine, atMine, "endTime")
    check("the player's own listing is on the market they can search",
          myOfferId.len == 24 and endBefore > 0,
          "id " & myOfferId & ", endTime " & $endBefore)

    let renewed = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"RagFairRenewOffer\",\"offerId\":\"" &
      myOfferId & "\",\"renewalTime\":12}],\"tm\":2}")
    check("an offer can be renewed",
          renewed.ok and not renewed.contains("renew"), renewed.body)
    let mine2 = offersOf(call("/client/ragfair/find",
      "{\"page\":0,\"limit\":50,\"offerOwnerType\":2}").body)
    let atMine2 = find(mine2, "\"nickname\":\"AowlTest\"")
    let endAfter = numberAt(mine2, atMine2, "endTime")
    # Exactly twelve hours. "It went up" passes against a server that renewed
    # for whatever it felt like, and the hours-to-seconds conversion is the one
    # piece of arithmetic in the whole path.
    check("and its expiry moves by exactly the hours asked for",
          endAfter - endBefore == 43200,
          $endBefore & " -> " & $endAfter & ", which is " &
          $(endAfter - endBefore) & " and not 43200")

    let tooLong = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"RagFairRenewOffer\",\"offerId\":\"" &
      myOfferId & "\",\"renewalTime\":99}],\"tm\":2}")
    check("a renewal longer than the database allows is refused, naming 48",
          tooLong.contains("48") and tooLong.contains("99"), tooLong.body)
    let mine3 = offersOf(call("/client/ragfair/find",
      "{\"page\":0,\"limit\":50,\"offerOwnerType\":2}").body)
    check("and the refused renewal moved nothing",
          numberAt(mine3, find(mine3, "\"nickname\":\"AowlTest\""),
                   "endTime") == endAfter,
          "the expiry moved on a refusal")
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
    # What the request is not allowed to decide, in the quest half. The credit
    # used to be the count in the body as written, so one item with
    # `count: 999` finished a "hand over two" condition -- and paid its reward
    # -- while one item's worth left the stash. Two ways in: an id the profile
    # does not hold at all, and a count larger than the stack that does.
    let ghostHand = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"QuestHandover\",\"qid\":\"q_debut\"," &
      "\"conditionId\":\"c_hand_rifles\"," &
      "\"items\":[{\"id\":\"ffffffffffffffffffffffff\",\"count\":50}]}],\"tm\":2}")
    let afterGhost = call("/client/game/profile/list", "")
    check("a handover of an item the profile does not hold credits nothing",
          ghostHand.ok and
          numberAt(afterGhost.body, find(afterGhost.body, "\"c_hand_rifles\""),
                   "value") == 1,
          afterGhost.body)
    let overHand = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"QuestHandover\",\"qid\":\"q_debut\"," &
      "\"conditionId\":\"c_hand_rifles\",\"items\":[{\"id\":\"" & smallStackId &
      "\",\"count\":999}]}],\"tm\":2}")
    let afterOver = call("/client/game/profile/list", "")
    check("and one is credited by the stack, not by the count claimed",
          overHand.ok and
          numberAt(afterOver.body, find(afterOver.body, "\"c_hand_rifles\""),
                   "value") == 2,
          afterOver.body)

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

    let post = call("/client/mail/dialog/list", "")
    rewardMessage = textAt(post.body, find(post.body, "\"message\":"), "_id")
    rewardItem = idOfTemplate(post.body, "544fb45d4bdc2dee738b4568")
    check("and posts its item reward to the mailbox",
          rewardMessage.len == 24 and rewardItem.len > 0, post.body)
    check("with the badge that tells the player it is there",
          numberAt(post.body, 0, "attachmentsNew") == 1, post.body)

    # -- the shape of a message on the wire ----------------------------------
    #
    # `dialogView` and `getAllAttachments` built their `messages` array with
    # `add(string)`, which *quotes* what it is given. Both answered
    # `{"messages":["{\"_id\":\"...\"}"]}` -- an array of JSON strings where
    # the client expects an array of objects. It parses without complaint and
    # then renders an empty dialog and an empty collect-all screen, while the
    # inbox badge above says there is something to collect.
    #
    # So the assertion is the *shape*, not the presence of the id: a check for
    # `rewardMessage` alone passes against the double-encoded body, because the
    # id is in there either way -- inside a string.
    # The dialog id is the sender, and it is the first `_id` in the list body
    # -- read rather than hard-coded, because which trader posts the reward is
    # the fixture's business and not this check's.
    let dialogId = textAt(post.body, 0, "_id")
    let opened = call("/client/mail/dialog/view",
                      "{\"dialogId\":\"" & dialogId & "\"}")
    check("an opened dialog answers message objects, not strings",
          find(opened.body, "\"messages\":[{") >= 0 and
          find(opened.body, "\"messages\":[\"") < 0, opened.body)
    check("and the first of them carries a readable _id",
          find(opened.body, "\"messages\":[{\"_id\":\"") >= 0 and
          not opened.contains("\\\"_id\\\""), opened.body)

    let collect = call("/client/mail/dialog/getAllAttachments", "{}")
    check("collect-all answers message objects, not strings",
          find(collect.body, "\"messages\":[{") >= 0 and
          find(collect.body, "\"messages\":[\"") < 0, collect.body)
    check("and the message it lists still owns its attachment container",
          find(collect.body, "\"messages\":[{\"_id\":\"") >= 0 and
          collect.contains("\"items\":{\"stash\":\"") and
          not collect.contains("\\\"_id\\\""), collect.body)

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

    # -- what a craft is paid for out of, other than the stash ------------
    #
    # A `Resource` requirement comes out of the *area's own slots*: the water
    # collector's filter, the generator's fuel. One recipe in an imported table
    # has one, no fixture had one, and the craft used to start without touching
    # it -- the output landed and the filter was still full.
    let noFilter = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutSingleProductionStart\"," &
      "\"recipeId\":\"recipe-filtered\"}],\"tm\":2}")
    check("a craft needing a resource the area has none of is refused",
          noFilter.contains("resource"), noFilter.body)
    discard call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutPutItemsInAreaSlots\"," &
      "\"areaType\":10,\"items\":[{\"locationIndex\":0,\"item\":[" &
      "{\"_id\":\"filter-one\",\"_tpl\":\"5d1b385e86f774252167b98a\"," &
      "\"upd\":{\"Resource\":{\"Value\":100}}}]}]}],\"tm\":2}")
    let filtered = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutSingleProductionStart\"," &
      "\"recipeId\":\"recipe-filtered\"}],\"tm\":2}")
    check("and starts once the filter is in the area",
          filtered.ok and not filtered.contains("resource"), filtered.body)
    let slotAfter = call("/client/game/profile/list", "")
    check("and the filter came back with exactly what it paid",
          numberAt(slotAfter.body,
                   find(slotAfter.body, "5d1b385e86f774252167b98a"),
                   "Value") == 34,
          "Value is " & $numberAt(slotAfter.body,
            find(slotAfter.body, "5d1b385e86f774252167b98a"), "Value") &
          ", not 100 - 66")
    discard call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutTakeProduction\"," &
      "\"recipeId\":\"recipe-filtered\"}],\"tm\":2}")
    let spent = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutSingleProductionStart\"," &
      "\"recipeId\":\"recipe-filtered\"}],\"tm\":2}")
    check("and a second craft is refused on what is left of it",
          spent.contains("resource"), spent.body)

    # -- and what a quest unlocks -----------------------------------------
    #
    # Forty-three recipes in an imported table are gated on a finished quest,
    # and every one of them was craftable by a player who had never accepted
    # it: the production path resolved its requirements without a profile, so
    # `QuestComplete` had nothing to be read against and was permitted.
    let locked = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutSingleProductionStart\"," &
      "\"recipeId\":\"recipe-locked\"}],\"tm\":2}")
    check("a craft a quest unlocks is refused before the quest is done",
          locked.contains("q_never"), locked.body)
    let unlocked = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutSingleProductionStart\"," &
      "\"recipeId\":\"recipe-unlocked\"}],\"tm\":2}")
    check("and permitted once it is",
          unlocked.ok and not unlocked.contains("unlocked by finishing"),
          unlocked.body)
    discard call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutDeleteProductionCommand\"," &
      "\"recipeId\":\"recipe-unlocked\"}],\"tm\":2}")

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

    # Cancelling. The inputs are *not* returned -- that is the game's own rule
    # and the reason the action exists: a craft a player can back out of for
    # free is a free reservation on every material in the stash. Checked as an
    # exact difference, because "the record is gone" would pass against a
    # server that also handed the roubles back.
    let cancelPayBefore =
      stackOf(call("/client/game/profile/list", "").body, moneyId)
    let restarted = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutSingleProductionStart\"," &
      "\"recipeId\":\"recipe-quick\"}],\"tm\":2}")
    check("a collected craft can be started again",
          restarted.ok and not restarted.contains("already running"),
          restarted.body)
    let cancelled = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutDeleteProductionCommand\"," &
      "\"recipeId\":\"recipe-quick\"}],\"tm\":2}")
    check("and cancelled", cancelled.ok and
          not cancelled.contains("no craft"), cancelled.body)
    check("which clears the record",
          not call("/client/game/profile/list", "").contains("recipe-quick"),
          "recipe-quick is still in Hideout.Production")
    let cancelPayAfter =
      stackOf(call("/client/game/profile/list", "").body, moneyId)
    check("and does not hand the materials back",
          cancelPayBefore - cancelPayAfter == 3,
          $cancelPayBefore & " - " & $cancelPayAfter & " != 3")
    let cancelTwice = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutDeleteProductionCommand\"," &
      "\"recipeId\":\"recipe-quick\"}],\"tm\":2}")
    check("cancelling nothing is refused rather than answered `done`",
          cancelTwice.contains("no craft"), cancelTwice.body)

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
    # claims and only the second one matters to the player's stash. Counted in
    # the PMC's own document: the scav shares the stash, so the list carries
    # every stash item twice and a count over the whole response reads two of
    # everything.
    let mine = profileOf(call("/client/game/profile/list", "").body, uid)
    check("and there is still exactly one of it",
          countOf(mine, rewardItem) == 1,
          $countOf(mine, rewardItem) & " copies")
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
    "{\"results\":{\"result\":\"Survived\",\"profile\":" & played & "}}")
  check("the raid result is accepted", ended.ok and ended.contains("\"err\":0"),
        ended.body)
  discard expectIn("and the raid experience stuck",
                   "/client/game/profile/list", "", "\"Experience\":1234")

  discard expectIn("a raid result for another profile is refused",
                   "/client/match/local/end",
                   "{\"results\":{\"result\":\"Survived\",\"profile\":{\"_id\":" &
                   "\"cccccccccccccccccccccccc\"}}}", "different profile")

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
                    "{\"results\":{\"result\":\"Survived\",\"profile\":" & bigClaim & "}}")
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
                 "{\"results\":{\"result\":\"Survived\",\"profile\":" & claim & "}}")
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
               "{\"results\":{\"result\":\"Survived\",\"profile\":" & absurd & "}}")
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
    "{\"results\":{\"result\":\"Survived\",\"profile\":{\"_id\":\"" & scavId &
    "\",\"Inventory\":{\"equipment\":\"" & gearId & "\",\"items\":[" &
    "{\"_id\":\"" & gearId & "\",\"_tpl\":\"55d7217a4bdc2d86028b456d\"}," &
    "{\"_id\":\"5ca1a5a5a5a5a5a5a5a5a5a1\",\"_tpl\":\"5710c24ad2720bc3458b45a3\"," &
    "\"parentId\":\"" & gearId & "\",\"slotId\":\"FirstPrimaryWeapon\"}]}}}}")
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
    "{\"results\":{\"result\":\"Killed\",\"profile\":{\"_id\":\"" & scavId &
    "\",\"Inventory\":{\"equipment\":\"" & deadGear & "\",\"items\":[" &
    "{\"_id\":\"" & deadGear & "\",\"_tpl\":\"55d7217a4bdc2d86028b456d\"}," &
    "{\"_id\":\"5ca1a5a5a5a5a5a5a5a5a5a2\",\"_tpl\":\"590c657e86f77412b013051d\"," &
    "\"parentId\":\"" & deadGear & "\",\"slotId\":\"FirstPrimaryWeapon\"}]}}}}")
  check("a dead scav's raid result is accepted too", died.ok, died.body)
  check("and brings nothing home",
        not call("/client/game/profile/list", "").contains(
          "5ca1a5a5a5a5a5a5a5a5a5a2"), "the dead scav's gear arrived")

  # "Sell all to Fence" on the results screen. It is refused by name and that
  # is the whole feature: `match/local/end` above already moved everything the
  # scav survived with into the PMC stash, so there is nothing left in the scav
  # to sell -- and the scav's document is the PMC's stash spliced in, so a
  # server that took this literally would sell the player's entire stash.
  #
  # Both halves are asserted. A refusal that also changed the profile would
  # pass a check that only read the message, and that is the exact shape of the
  # bug this refuses to have. The profile is compared byte for byte, not by
  # rouble count: this claims a value, and a server taking dictation from it
  # would *add* money rather than remove any.
  let sellAllDoc = profileOf(call("/client/game/profile/list", "").body, uid)
  let stashBefore = memberObject(sellAllDoc, "Inventory")
  let fenceBefore = traderEntry(sellAllDoc, "579dc571d53a0658a154fbec")
  let soldAll = call("/client/game/profile/items/moving",
    "{\"data\":[{\"Action\":\"SellAllFromSavage\",\"totalValue\":250000}]," &
    "\"tm\":2}")
  check("selling the scav's run to Fence is refused, and says why",
        soldAll.contains("nothing left in the scav to sell") and
        soldAll.contains("sell it from the stash instead"), soldAll.body)
  check("and the number the client valued it at is repeated back, not paid",
        soldAll.contains("250000"), soldAll.body)
  let afterSellAll = profileOf(call("/client/game/profile/list", "").body, uid)
  check("and the stash is byte-identical afterwards",
        memberObject(afterSellAll, "Inventory") == stashBefore,
        "the refusal moved something in the inventory")
  check("and Fence bought nothing",
        traderEntry(afterSellAll, "579dc571d53a0658a154fbec") == fenceBefore,
        traderEntry(afterSellAll, "579dc571d53a0658a154fbec"))

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
    # And it is still there *after* it was emptied, which is the other half of
    # the mailbox bound. Collected messages are reclaimed -- one per dialog is
    # kept, the rest go, and without that the store grew 267 bytes per
    # withdrawn-and-collected offer for the life of the profile -- so the check
    # that matters here is that the pruning is not eating the record the player
    # is left with. `rewardCollected` proves it is the emptied one rather than
    # a second copy that was never redeemed.
    let inbox = expectIn("the inbox still carries the message the quest posted",
                         "/client/mail/dialog/list", "", rewardMessage)
    check("and it is the emptied one, kept rather than reclaimed",
          inbox.contains("\"rewardCollected\":true"), inbox.body)
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
    # And the shape the client actually sends: `items` is a list of the
    # player's **item ids**, not template ids. Reading them as templates found
    # nothing in the handbook and quoted nothing for every real request, which
    # renders as "insurance is free" on the screen that offers it. Keyed back
    # by the id that was asked about, so the client can match the answer to the
    # row it drew.
    if smallStackId.len == 24:
      let byId = call("/client/insurance/items/list/cost",
                      "{\"traders\":[\"54cb50c76803fa8b248b4571\"]," &
                      "\"items\":[\"" & smallStackId & "\"]}")
      check("and quotes for an item id, not just a template id",
            byId.contains("\"" & smallStackId & "\":110"), byId.body)
  else:
    check("with no handbook, insurance quotes nothing rather than zero",
          quote.ok and not quote.contains(":0}"), quote.body)

  heading "Buying insurance"
  # The other half of the quote above, and until now the missing half: the quote
  # screen worked, `Insure` was an unhandled action, and `InsuredItems` was
  # empty on every profile forever. Insurance was a price with nothing behind
  # it -- money never taken, nothing ever returned.
  #
  # Everything here is exact. The premium is 10% of the handbook price
  # (`insurancePercent` in the mod's config, 1100 for a Salewa, so 110), and a
  # check for "the stack got smaller" would pass against a server that charged
  # any number at all.
  var insuredId = ""
  # Kept past the restart, where the returns actually arrive.
  var therId = ""
  var fenceId = ""
  if haveFixture:
    let buyKit = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"TradingConfirm\",\"type\":\"buy_from_trader\"," &
      "\"tid\":\"54cb50c76803fa8b248b4571\",\"item_id\":\"aaaaaaaaaaaaaaaaaaaaaaa2\"," &
      "\"count\":1,\"scheme_items\":[{\"id\":\"" & moneyId &
      "\",\"count\":1200}]}],\"tm\":2}")
    check("a kit to insure can be bought", buyKit.ok and
          not buyKit.contains("costs"), buyKit.body)
    expectedSales = expectedSales + 1200
    let held = idsOfTemplate(
      profileOf(call("/client/game/profile/list", "").body, uid),
      "544fb45d4bdc2dee738b4568")
    if held.len > 0:
      insuredId = held[held.len - 1]

    let payBefore = stackOf(call("/client/game/profile/list", "").body, moneyId)
    let insured = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"Insure\"," &
      "\"tid\":\"54cb50c76803fa8b248b4571\",\"items\":[\"" & insuredId &
      "\"]}],\"tm\":2}")
    check("insuring an item is accepted",
          insured.ok and not insured.contains("no price is known"), insured.body)
    let payAfter = stackOf(call("/client/game/profile/list", "").body, moneyId)
    check("and costs exactly the premium that was quoted",
          payBefore - payAfter == 110,
          $payBefore & " - " & $payAfter & " != 110")
    let withCover = profileOf(call("/client/game/profile/list", "").body, uid)
    check("and the profile records who insured what",
          find(withCover, "\"itemId\":\"" & insuredId & "\"") >= 0,
          "InsuredItems does not name it")

    # The client re-sends its whole selection when the player adds one more
    # item to it. Charging again for what is already covered is the bug this
    # exists to stop, and it is invisible without the exact figure.
    let again = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"Insure\"," &
      "\"tid\":\"54cb50c76803fa8b248b4571\",\"items\":[\"" & insuredId &
      "\"]}],\"tm\":2}")
    check("insuring the same item twice is accepted", again.ok, again.body)
    let payTwice = stackOf(call("/client/game/profile/list", "").body, moneyId)
    check("and is not charged for twice", payTwice == payAfter,
          $payAfter & " became " & $payTwice)

    let ghost = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"Insure\"," &
      "\"tid\":\"54cb50c76803fa8b248b4571\"," &
      "\"items\":[\"cccccccccccccccccccccccc\"]}],\"tm\":2}")
    check("insuring something the player does not own is refused",
          ghost.contains("no such item"), ghost.body)
    let payGhost = stackOf(call("/client/game/profile/list", "").body, moneyId)
    check("and takes nothing for it", payGhost == payTwice,
          $payTwice & " became " & $payGhost)

    # -- two more kits, covered by two other traders -------------------------
    #
    # `InsuredItems` has always carried a `tid` and the queue always ignored
    # it: every return was posted from Prapor whatever the profile said. That
    # was invisible while the message was one hardcoded sentence and is a
    # visible lie now that it is the trader's own words, so what proves it is
    # three items covered by three different traders.
    #
    # The three are chosen for what the fixture says about each of them.
    # Prapor has `dialogue` with `{location}` in every line; the Therapist has
    # `dialogue` and no `base` at all, which is enough because `Insure` prices
    # off the handbook and never looks the trader up; Fence has a `base` and no
    # `dialogue`, which is the case that must still get the plain wording.
    #
    # Bought here rather than earlier because every rouble figure above is
    # exact, and a purchase in the middle of them would be measuring this.
    let buyTher = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"TradingConfirm\",\"type\":\"buy_from_trader\"," &
      "\"tid\":\"54cb50c76803fa8b248b4571\",\"item_id\":\"aaaaaaaaaaaaaaaaaaaaaaa2\"," &
      "\"count\":1,\"scheme_items\":[{\"id\":\"" & moneyId &
      "\",\"count\":1200}]}],\"tm\":2}")
    check("a second kit can be bought", buyTher.ok, buyTher.body)
    expectedSales = expectedSales + 1200
    var kits = idsOfTemplate(
      profileOf(call("/client/game/profile/list", "").body, uid),
      "544fb45d4bdc2dee738b4568")
    therId = (if kits.len > 0: kits[kits.len - 1] else: "")
    let therCover = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"Insure\"," &
      "\"tid\":\"54cb57776803fa99248b456e\",\"items\":[\"" & therId &
      "\"]}],\"tm\":2}")
    check("a trader with no base in the table can still insure",
          therCover.ok and not therCover.contains("no price is known"),
          therCover.body)

    let buyFence = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"TradingConfirm\",\"type\":\"buy_from_trader\"," &
      "\"tid\":\"54cb50c76803fa8b248b4571\",\"item_id\":\"aaaaaaaaaaaaaaaaaaaaaaa2\"," &
      "\"count\":1,\"scheme_items\":[{\"id\":\"" & moneyId &
      "\",\"count\":1200}]}],\"tm\":2}")
    check("a third kit can be bought", buyFence.ok, buyFence.body)
    expectedSales = expectedSales + 1200
    kits = idsOfTemplate(
      profileOf(call("/client/game/profile/list", "").body, uid),
      "544fb45d4bdc2dee738b4568")
    fenceId = (if kits.len > 0: kits[kits.len - 1] else: "")
    let fenceCover = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"Insure\"," &
      "\"tid\":\"579dc571d53a0658a154fbec\",\"items\":[\"" & fenceId &
      "\"]}],\"tm\":2}")
    check("and so can a trader the database gives no dialogue",
          fenceCover.ok, fenceCover.body)
    check("the three kits are three different items",
          insuredId.len == 24 and therId.len == 24 and fenceId.len == 24 and
          insuredId != therId and therId != fenceId and insuredId != fenceId,
          insuredId & " / " & therId & " / " & fenceId)

    # And now lose all three, in one raid. One rather than two on purpose:
    # nothing removes an id from `InsuredItems` when a return is queued, so an
    # item lost in the first raid is still "insured and not in the stash" for
    # the second and would be queued a second time. That is a real gap in the
    # emulator and not this file`s to work around -- one raid sidesteps it, and
    # the note above `fx_ther_found_unknown` in the fixture is why the
    # Therapist`s line is still exactly predictable without a second one.
    #
    # The raid **names a map**, which is what gives `{location}` a value. The
    # map is `bigmap`, and the fixture turns that into `Customs` through
    # `locations.bigmap.base.Name` and the locale table -- so a message reading
    # `Customs` is a message that went through both, rather than one echoing
    # what the client sent.
    let carried = call("/client/game/profile/list", "").body
    let lostIt = withoutItem(withoutItem(
      withoutItem(profileOf(carried, uid), insuredId), therId), fenceId)
    # Gone from `Inventory.items`, which is not the same as gone from the
    # document: the id is still in `InsuredItems`, and that is the whole point
    # -- it is what makes the item eligible for a return. A check for the bare
    # id would be reading the cover rather than the kit.
    check("the test could rebuild the profile without them",
          lostIt.len > 100 and
          find(lostIt, "{\"_id\":\"" & insuredId & "\"") < 0 and
          find(lostIt, "{\"_id\":\"" & therId & "\"") < 0 and
          find(lostIt, "{\"_id\":\"" & fenceId & "\"") < 0,
          $lostIt.len & " bytes")
    let died = call("/client/match/local/end",
      "{\"location\":\"bigmap\",\"results\":{\"result\":\"Killed\",\"profile\":" &
      lostIt & "}}")
    check("a raid the insured items did not come out of is accepted",
          died.ok and died.contains("\"err\":0"), died.body)
    check("and they really are gone from the stash",
          find(profileOf(call("/client/game/profile/list", "").body, uid),
               "{\"_id\":\"" & insuredId & "\"") < 0, "still there")

    # -- what each trader says the moment it is queued -----------------------
    #
    # `insuranceStart`, and this is where per-trader routing first shows. One
    # raid, three insuring traders, three separate dialogs -- the queue used to
    # post the lot from Prapor whatever the profile said.
    #
    # There is no wording of this server`s own for `insuranceStart`, so a
    # trader the database gives no lines says *nothing*. Fence is checked for
    # silence here rather than for a sentence, because inventing one would be
    # the bug.
    let prapStart = call("/client/mail/dialog/view",
      "{\"dialogId\":\"54cb50c76803fa8b248b4571\"}")
    check("the insuring trader says he has sent someone",
          prapStart.contains("Prapor here.") and
          (prapStart.contains("look for your kit") or
           prapStart.contains("on their way to")), prapStart.body)
    check("and the line names the map by its display name, not its key",
          prapStart.contains("Customs") and not prapStart.contains("bigmap"),
          prapStart.body)
    # No placeholder may reach the player. A line whose `{date}` could not be
    # filled has to be skipped, not sent with the braces still in it -- that is
    # what `say`'s completeness test is for, and it is invisible without this.
    check("and nothing in it is still an unfilled placeholder",
          not prapStart.contains("{location}") and
          not prapStart.contains("{date}") and
          not prapStart.contains("{time}") and
          not prapStart.contains("{nickname}"), prapStart.body)

    let therStart = call("/client/mail/dialog/view",
      "{\"dialogId\":\"54cb57776803fa99248b456e\"}")
    check("the second insuring trader has a dialog of her own",
          therStart.contains("Therapist speaking."), therStart.body)
    check("and hers is not filed under the first trader",
          not prapStart.contains("Therapist speaking."),
          "the Therapist's line went into Prapor's dialog")

    let fenceStart = call("/client/mail/dialog/view",
      "{\"dialogId\":\"579dc571d53a0658a154fbec\"}")
    check("a trader the database gives no lines says nothing at all",
          fenceStart.contains("\"messages\":[]"), fenceStart.body)

    # Not back yet: the return is due in `insuranceReturnHours`, and a trader
    # who posts it back immediately is a trader who makes dying free. The
    # restart below is what moves the clock past it.
    #
    # Asserted against the *return* wording rather than against the old literal
    # `recovered`. Prapor has dialogue now, so his return is his own words and
    # a check for the literal would pass against a server that posted the
    # return this second -- which is exactly the shape of check this file keeps
    # finding.
    let tooSoon = call("/client/mail/dialog/list", "")
    check("and none of the three comes back the same minute",
          not tooSoon.contains("dug your gear") and
          not tooSoon.contains("things back off") and
          not tooSoon.contains("your things are back") and
          not tooSoon.contains("Your things are back") and
          not tooSoon.contains("recovered"),
          "a return was posted immediately")
  else:
    note "no database fixture; skipping the insurance purchase checks"

  heading "Healing and eating"
  # Both used to be unhandled actions, and the failure was silent in the worst
  # way: the client applies a heal to its own copy the instant it is clicked, so
  # the player watches the leg go green and finds it broken again the next time
  # the server hands them a profile. The bandage was still in the stash too.
  if haveFixture:
    # Come out of a raid hurt. Everything else about the document is what the
    # server itself last wrote, so this is one number different.
    let sound = profileOf(call("/client/game/profile/list", "").body, uid)
    let hurt = withPartHealth(sound, "Head", 10)
    check("the test could rebuild a damaged profile",
          hurt.len > 100 and find(hurt, "\"Current\":10") >= 0,
          $hurt.len & " bytes")
    discard call("/client/match/local/end",
                 "{\"results\":{\"result\":\"Survived\",\"profile\":" & hurt & "}}")

    let buyKit2 = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"TradingConfirm\",\"type\":\"buy_from_trader\"," &
      "\"tid\":\"54cb50c76803fa8b248b4571\",\"item_id\":\"aaaaaaaaaaaaaaaaaaaaaaa2\"," &
      "\"count\":1,\"scheme_items\":[{\"id\":\"" & moneyId &
      "\",\"count\":1200}]}],\"tm\":2}")
    check("a medkit can be bought", buyKit2.ok and
          not buyKit2.contains("costs"), buyKit2.body)
    expectedSales = expectedSales + 1200
    let kits = idsOfTemplate(
      profileOf(call("/client/game/profile/list", "").body, uid),
      "544fb45d4bdc2dee738b4568")
    let kitId = if kits.len > 0: kits[kits.len - 1] else: ""

    # 25 missing of a 35-point head. The request asks for 9999, and the answer
    # is 25 -- bounded by the damage, not by the number in the body, exactly as
    # a trade's count is bounded by the stack.
    let healed = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"Heal\",\"item\":\"" & kitId &
      "\",\"part\":\"Head\",\"count\":9999}],\"tm\":2}")
    check("healing is accepted", healed.ok and
          not healed.contains("not a body part"), healed.body)
    let afterHeal = profileOf(call("/client/game/profile/list", "").body, uid)
    let headAt = find(afterHeal, "\"Head\":{")
    check("and the part is full, not over-healed",
          numberAt(afterHeal, headAt, "Current") == 35,
          "Head is " & $numberAt(afterHeal, headAt, "Current") & ", not 35")
    # And the kit paid for it. 400 charge, 25 spent, 375 left -- the exact
    # figure, because a kit that heals without being consumed is an unlimited
    # kit and "it still has some left" would pass against one.
    let kitAt = find(afterHeal, "\"_id\":\"" & kitId & "\"")
    check("and the kit is down by exactly what it healed",
          numberAt(afterHeal, kitAt, "HpResource") == 375,
          "HpResource is " & $numberAt(afterHeal, kitAt, "HpResource"))

    let notHurt = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"Heal\",\"item\":\"" & kitId &
      "\",\"part\":\"Head\",\"count\":10}],\"tm\":2}")
    check("healing a part that is not damaged is refused",
          notHurt.contains("not damaged"), notHurt.body)
    let noPart = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"Heal\",\"item\":\"" & kitId &
      "\",\"part\":\"Wing\",\"count\":10}],\"tm\":2}")
    check("and so is healing a part the client made up",
          noPart.contains("not a body part"), noPart.body)

    # Eating. The bottle is 60 units and worth 60 hydration in total, so ten
    # units are worth ten -- `value / MaxResource` per unit, which is the only
    # reading of the reference's two fields that makes a sip of a big bottle
    # worth less than the whole thing.
    let buyDrink = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"TradingConfirm\",\"type\":\"buy_from_trader\"," &
      "\"tid\":\"54cb50c76803fa8b248b4571\",\"item_id\":\"aaaaaaaaaaaaaaaaaaaaaaa6\"," &
      "\"count\":1,\"scheme_items\":[{\"id\":\"" & moneyId &
      "\",\"count\":500}]}],\"tm\":2}")
    check("a drink can be bought", buyDrink.ok and
          not buyDrink.contains("costs"), buyDrink.body)
    expectedSales = expectedSales + 500
    let bottles = idsOfTemplate(
      profileOf(call("/client/game/profile/list", "").body, uid),
      "5448ff904bdc2d6f028b456e")
    let bottleId = if bottles.len > 0: bottles[bottles.len - 1] else: ""

    # Thirsty first, so there is room for the drink to do something. Hydration
    # starts full on a fresh profile and a full bar would hide a wrong sum.
    let thirstyDoc = profileOf(call("/client/game/profile/list", "").body, uid)
    let hydrationAt = find(thirstyDoc, "\"Hydration\":{")
    var thirsty = ""
    if hydrationAt >= 0:
      let currentAt = findFrom(thirstyDoc, "\"Current\":", hydrationAt)
      var j = currentAt + len("\"Current\":")
      var k = j
      while k < thirstyDoc.len and thirstyDoc[k] != ',' and
            thirstyDoc[k] != '}':
        inc k
      thirsty = thirstyDoc.substr(0, j - 1) & "50" & thirstyDoc.substr(k)
    check("the test could make the profile thirsty", thirsty.len > 100,
          $thirsty.len & " bytes")
    discard call("/client/match/local/end",
                 "{\"results\":{\"result\":\"Survived\",\"profile\":" & thirsty & "}}")

    let drank = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"Eat\",\"item\":\"" & bottleId &
      "\",\"count\":10}],\"tm\":2}")
    check("drinking is accepted", drank.ok and
          not drank.contains("no size is known"), drank.body)
    let afterDrink = profileOf(call("/client/game/profile/list", "").body, uid)
    let hydAt = find(afterDrink, "\"Hydration\":{")
    check("and ten of sixty units are worth ten hydration",
          numberAt(afterDrink, hydAt, "Current") == 60,
          "Hydration is " & $numberAt(afterDrink, hydAt, "Current") &
          ", not 60")
    let bottleAt = find(afterDrink, "\"_id\":\"" & bottleId & "\"")
    check("and the bottle is down by exactly what was drunk",
          numberAt(afterDrink, bottleAt, "HpPercent") == 50,
          "HpPercent is " & $numberAt(afterDrink, bottleAt, "HpPercent"))

    let drainIt = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"Eat\",\"item\":\"" & bottleId &
      "\",\"count\":9999}],\"tm\":2}")
    check("finishing it is accepted", drainIt.ok, drainIt.body)
    check("and an empty bottle is gone rather than left at zero",
          not call("/client/game/profile/list", "").contains(bottleId),
          "the empty bottle is still in the stash")
  else:
    note "no database fixture; skipping the health checks"

  heading "Healing at a trader"
  # `RestoreHealth` -- the event a player reaches for after a bad raid, and the
  # one `docs/BACKLOG.md` recorded as blocked on "the treatment price table".
  # The table was in the database all along, under `globals.config.Health`, and
  # the fixture now carries it: 30 a hit point, 2 a point of energy, 3 a point
  # of hydration, 1000 a fracture, 400 a light bleed, and `Contusion` priced by
  # nothing at all.
  #
  # Every check below is an exact number of roubles rather than "money moved",
  # for the reason the repair checks give: a treatment that charges the wrong
  # amount is the same shape of bug as a trade that does, and only an exact
  # difference finds it. The three that are worth the rest put together are the
  # partial heal (a client asking for 200 on a leg missing 40 pays for 40), the
  # refusal that must take nothing, and Fence's `heal_price_coef` of 0 -- which
  # means "not named" and therefore full price, not free.
  if haveFixture:
    # Come out of a raid in five different states at once, so that one raid
    # sets up every treatment below. The client applies damage and effects
    # during the raid and hands the profile back with them on it; there is no
    # other route by which a profile acquires a fracture.
    let whole1 = profileOf(call("/client/game/profile/list", "").body, uid)
    var beaten = withPartHealth(whole1, "LeftLeg", 25)      # missing 40
    beaten = withPartHealth(beaten, "RightLeg", 55)         # missing 10
    beaten = withPartHealth(beaten, "Chest", 65)            # missing 20
    beaten = withPartHealth(beaten, "Stomach", 60)          # missing 10
    beaten = withPartHealth(beaten, "Energy", 90)           # missing 10
    beaten = withPartHealth(beaten, "Hydration", 60)        # missing 40
    beaten = withPartEffects(beaten, "RightLeg",
                             "{\"Contusion\":{\"Time\":-1}}")
    beaten = withPartEffects(beaten, "Chest",
      "{\"Fracture\":{\"Time\":-1},\"LightBleeding\":{\"Time\":-1}}")
    check("the test could rebuild a profile that needs treating",
          beaten.len > whole1.len and find(beaten, "Contusion") >= 0 and
          find(beaten, "\"Current\":25") >= 0, $beaten.len & " bytes")
    discard call("/client/match/local/end",
                 "{\"results\":{\"result\":\"Survived\",\"profile\":" & beaten & "}}")

    let hurtDoc = profileOf(call("/client/game/profile/list", "").body, uid)
    check("and the raid brought the fracture home with it",
          find(effectsOf(hurtDoc, "Chest"), "Fracture") >= 0,
          "Chest effects are " & effectsOf(hurtDoc, "Chest"))
    var purse = roublesIn(hurtDoc)
    check("the test could count the money", purse > 20000, $purse & " roubles")

    # -- the amount is the server's ----------------------------------------
    #
    # 40 points missing on the leg and 200 asked for. Priced at
    # `HealthPointPrice` 30 and Prapor's *level 2* `heal_price_coef` of 150 per
    # cent: 40 * 30 * 1.5 = 1800. Not 200 * 30 * 1.5 = 9000, which is what
    # believing the request's own figure costs; and not 1200, which is what
    # reading `loyaltyLevels[0]` -- whose coefficient the fixture sets to a
    # literal 0 -- would produce.
    let legged = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"RestoreHealth\",\"tid\":\"" &
      "54cb50c76803fa8b248b4571\",\"difference\":{\"BodyParts\":{" &
      "\"LeftLeg\":{\"Health\":200}}}}],\"tm\":2}")
    check("a treatment at a trader is accepted",
          legged.ok and not legged.contains("treatment:"), legged.body)
    var nowDoc = profileOf(call("/client/game/profile/list", "").body, uid)
    let legAt = find(nowDoc, "\"LeftLeg\":{")
    check("and the leg is whole, not over-healed",
          numberAt(nowDoc, legAt, "Current") == 65,
          "LeftLeg is " & $numberAt(nowDoc, legAt, "Current") & ", not 65")
    check("and it was priced for the 40 points that were missing, not the 200 asked for",
          purse - roublesIn(nowDoc) == 1800,
          "the treatment took " & $(purse - roublesIn(nowDoc)) &
          " roubles, not 1800")
    expectedSales = expectedSales + 1800
    purse = roublesIn(nowDoc)

    # -- an effect the table does not price ---------------------------------
    #
    # `Contusion` has no `RemovePrice`, so it is refused *by name* -- and the
    # ten hit points bundled into the same request go with it. A server that
    # dropped the effect and treated the leg anyway would charge for something
    # the player did not ask for on its own and would leave them concussed.
    let concussed = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"RestoreHealth\",\"tid\":\"" &
      "54cb50c76803fa8b248b4571\",\"difference\":{\"BodyParts\":{" &
      "\"RightLeg\":{\"Health\":10,\"Effects\":[\"Contusion\"]}}}}],\"tm\":2}")
    check("an effect the table does not price is refused by name",
          concussed.contains("does not treat Contusion"), concussed.body)
    nowDoc = profileOf(call("/client/game/profile/list", "").body, uid)
    check("and the refusal took no money at all",
          roublesIn(nowDoc) == purse,
          "a refused treatment moved " & $(purse - roublesIn(nowDoc)) &
          " roubles")
    let rightAt = find(nowDoc, "\"RightLeg\":{")
    check("and the hit points bundled with it were not treated either",
          numberAt(nowDoc, rightAt, "Current") == 55,
          "RightLeg is " & $numberAt(nowDoc, rightAt, "Current") & ", not 55")
    check("and the effect is still on the profile",
          find(effectsOf(nowDoc, "RightLeg"), "Contusion") >= 0,
          "RightLeg effects are " & effectsOf(nowDoc, "RightLeg"))

    # -- effects that are priced --------------------------------------------
    #
    # 20 points and two effects in one request, spelled `Difference` -- the
    # reference's own casing, which a database written from the reference
    # rather than from a dump would send. (600 + 1000 + 400) * 1.5 = 3000.
    # Exact, because effects added *instead of* the points rather than to them
    # is 2100, and either would pass "it cost something".
    let mended = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"RestoreHealth\",\"tid\":\"" &
      "54cb50c76803fa8b248b4571\",\"Difference\":{\"BodyParts\":{" &
      "\"Chest\":{\"Health\":20,\"Effects\":[\"Fracture\"," &
      "\"LightBleeding\"]}}}}],\"tm\":2}")
    check("a treatment naming two priced effects is accepted",
          mended.ok and not mended.contains("treatment:"), mended.body)
    nowDoc = profileOf(call("/client/game/profile/list", "").body, uid)
    let chestAt = find(nowDoc, "\"Chest\":{")
    check("and the chest is whole",
          numberAt(nowDoc, chestAt, "Current") == 85,
          "Chest is " & $numberAt(nowDoc, chestAt, "Current") & ", not 85")
    check("and both effects are off it",
          find(effectsOf(nowDoc, "Chest"), "Fracture") < 0 and
          find(effectsOf(nowDoc, "Chest"), "LightBleeding") < 0,
          "Chest effects are " & effectsOf(nowDoc, "Chest"))
    check("and the effects were charged on top of the points, not instead of them",
          purse - roublesIn(nowDoc) == 3000,
          "the treatment took " & $(purse - roublesIn(nowDoc)) &
          " roubles, not 3000")
    expectedSales = expectedSales + 3000
    purse = roublesIn(nowDoc)

    # An effect the *client* thinks is there and the server does not is already
    # in the state the player asked for, so there is nothing to bill: 10 points
    # at 30 and 150 per cent is 450, not 450 plus a light bleed's 600.
    let imagined = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"RestoreHealth\",\"tid\":\"" &
      "54cb50c76803fa8b248b4571\",\"difference\":{\"BodyParts\":{" &
      "\"Stomach\":{\"Health\":10,\"Effects\":[\"LightBleeding\"]}}}}]," &
      "\"tm\":2}")
    check("an effect the profile does not carry is accepted rather than refused",
          imagined.ok and not imagined.contains("treatment:"), imagined.body)
    nowDoc = profileOf(call("/client/game/profile/list", "").body, uid)
    check("and is not charged for",
          purse - roublesIn(nowDoc) == 450,
          "the treatment took " & $(purse - roublesIn(nowDoc)) &
          " roubles, not 450")
    expectedSales = expectedSales + 450
    purse = roublesIn(nowDoc)

    # -- a coefficient of zero ----------------------------------------------
    #
    # Fence's `heal_price_coef` is a literal 0, which is what every trader but
    # Therapist carries on every loyalty row in live data. It means "not
    # named". A server that used it as a multiplier would heal for nothing, and
    # free healing removes the whole system -- so 10 energy at 2 and 40
    # hydration at 3 is 140, at full price. 500 hydration is asked for and 40
    # is what is missing, which is the same bound as the leg -- and the two
    # rates are deliberately different, so a server that priced all three kinds
    # of point off `HealthPointPrice` could not land on this number either.
    let fed = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"RestoreHealth\",\"tid\":\"" &
      "579dc571d53a0658a154fbec\",\"difference\":{\"Energy\":10," &
      "\"Hydration\":500}}],\"tm\":2}")
    check("a treatment at a trader whose coefficient is zero is accepted",
          fed.ok and not fed.contains("treatment:"), fed.body)
    nowDoc = profileOf(call("/client/game/profile/list", "").body, uid)
    let energyAt = find(nowDoc, "\"Energy\":{")
    let hydAt2 = find(nowDoc, "\"Hydration\":{")
    check("and energy and hydration are full",
          numberAt(nowDoc, energyAt, "Current") == 100 and
          numberAt(nowDoc, hydAt2, "Current") == 100,
          "Energy " & $numberAt(nowDoc, energyAt, "Current") & ", Hydration " &
          $numberAt(nowDoc, hydAt2, "Current"))
    check("and a coefficient of zero charged full price rather than nothing",
          purse - roublesIn(nowDoc) == 140,
          "the treatment took " & $(purse - roublesIn(nowDoc)) &
          " roubles, not 140")
    purse = roublesIn(nowDoc)

    # -- the refusals -------------------------------------------------------
    let whole2 = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"RestoreHealth\",\"tid\":\"" &
      "54cb50c76803fa8b248b4571\",\"difference\":{\"BodyParts\":{" &
      "\"LeftLeg\":{\"Health\":40}}}}],\"tm\":2}")
    check("treating a profile that needs nothing is refused",
          whole2.contains("needs treating"), whole2.body)
    let madeUp = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"RestoreHealth\",\"tid\":\"" &
      "54cb50c76803fa8b248b4571\",\"difference\":{\"BodyParts\":{" &
      "\"Wing\":{\"Health\":10}}}}],\"tm\":2}")
    check("and so is a body part the client made up",
          madeUp.contains("not a body part"), madeUp.body)
    let noTrader = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"RestoreHealth\",\"tid\":\"" &
      "000000000000000000000000\",\"difference\":{\"BodyParts\":{" &
      "\"LeftLeg\":{\"Health\":10}}}}],\"tm\":2}")
    check("and a trader this server has never heard of",
          noTrader.contains("there is no trader"), noTrader.body)
    let noDiff = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"RestoreHealth\",\"tid\":\"" &
      "54cb50c76803fa8b248b4571\"}],\"tm\":2}")
    check("and a request that names nothing to treat",
          noDiff.contains("names nothing to treat"), noDiff.body)
    check("and none of the four refusals moved any money",
          roublesIn(profileOf(call("/client/game/profile/list", "").body,
                              uid)) == purse,
          "a refused treatment took money")
  else:
    note "no database fixture; skipping the trader treatment checks"

  heading "Repair and durability"
  # The largest gameplay system this server did not have. `Repair` and
  # `TraderRepair` were both unhandled actions, so `upd.Repairable` never moved:
  # a rifle wore out over a career and nothing could ever fix it.
  #
  # The gear these checks work on is handed to the profile the way a player
  # would actually get it -- carried out of a raid -- rather than added to the
  # fixture's assort, because an assort entry becomes a flea offer and the flea
  # checks above pin counts an extra offer would move.
  let gunId = "aa11repairgun00000000001"
  let armId = "aa11repairarm00000000001"
  let arm2Id = "aa11repairarm00000000002"
  let arm3Id = "aa11repairarm00000000003"
  let kitId = "aa11repairkit00000000001"
  let kit2Id = "aa11repairkit00000000002"
  let mapId = "aa11repairmap00000000001"
  let brickId = "aa11repairnil00000000001"
  var gearStash = ""
  if haveFixture:
    let beforeGear = profileOf(call("/client/game/profile/list", "").body, uid)
    gearStash = jsonText(beforeGear, "stash")
    check("the test could find the stash to put gear in",
          gearStash.len == 24, gearStash)
    let gear =
      "{\"_id\":\"" & gunId & "\",\"_tpl\":\"rrrrgun00000000000000001\"," &
      "\"parentId\":\"" & gearStash & "\",\"slotId\":\"hideout\"," &
      "\"location\":{\"x\":0,\"y\":10,\"r\":\"Horizontal\"}," &
      "\"upd\":{\"Repairable\":{\"Durability\":60,\"MaxDurability\":100}}}," &
      "{\"_id\":\"" & armId & "\",\"_tpl\":\"rrrrarm00000000000000001\"," &
      "\"parentId\":\"" & gearStash & "\",\"slotId\":\"hideout\"," &
      "\"location\":{\"x\":0,\"y\":13,\"r\":\"Horizontal\"}," &
      "\"upd\":{\"Repairable\":{\"Durability\":20,\"MaxDurability\":50}}}," &
      "{\"_id\":\"" & arm2Id & "\",\"_tpl\":\"rrrrarm00000000000000001\"," &
      "\"parentId\":\"" & gearStash & "\",\"slotId\":\"hideout\"," &
      "\"location\":{\"x\":4,\"y\":13,\"r\":\"Horizontal\"}," &
      "\"upd\":{\"Repairable\":{\"Durability\":10,\"MaxDurability\":50}}}," &
      "{\"_id\":\"" & arm3Id & "\",\"_tpl\":\"rrrrarm00000000000000002\"," &
      "\"parentId\":\"" & gearStash & "\",\"slotId\":\"hideout\"," &
      "\"location\":{\"x\":8,\"y\":13,\"r\":\"Horizontal\"}," &
      "\"upd\":{\"Repairable\":{\"Durability\":30,\"MaxDurability\":50}}}," &
      # No `upd` at all: a kit that has never been used starts from the
      # template's `MaxRepairResource`, exactly as an unused medkit starts from
      # `MaxHpResource`.
      "{\"_id\":\"" & kitId & "\",\"_tpl\":\"rrrrkit00000000000000001\"," &
      "\"parentId\":\"" & gearStash & "\",\"slotId\":\"hideout\"," &
      "\"location\":{\"x\":0,\"y\":17,\"r\":\"Horizontal\"}}," &
      "{\"_id\":\"" & kit2Id & "\",\"_tpl\":\"rrrrkit00000000000000001\"," &
      "\"parentId\":\"" & gearStash & "\",\"slotId\":\"hideout\"," &
      "\"location\":{\"x\":3,\"y\":17,\"r\":\"Horizontal\"}," &
      "\"upd\":{\"RepairKit\":{\"Resource\":20}}}," &
      "{\"_id\":\"" & mapId & "\",\"_tpl\":\"ppppmap00000000000000001\"," &
      "\"parentId\":\"" & gearStash & "\",\"slotId\":\"hideout\"," &
      "\"location\":{\"x\":6,\"y\":17,\"r\":\"Horizontal\"}}," &
      "{\"_id\":\"" & brickId & "\",\"_tpl\":\"nnnnnil00000000000000001\"," &
      "\"parentId\":\"" & gearStash & "\",\"slotId\":\"hideout\"," &
      "\"location\":{\"x\":8,\"y\":17,\"r\":\"Horizontal\"}}"
    let withGear = withExtraItems(beforeGear, gear)
    check("the test could hand the profile some gear",
          withGear.len > beforeGear.len and findFrom(withGear, gunId, 0) > 0,
          $withGear.len & " bytes")
    discard call("/client/match/local/end",
                 "{\"results\":{\"result\":\"Survived\",\"profile\":" & withGear & "}}")

    # **The client drives the wear.** This is the whole reason there is no
    # server-side degradation on the raid path: the raid result carries the
    # durability the raid left, and the server keeps it. A server that also
    # applied wear here would apply it twice, and the two are indistinguishable
    # in the document that arrives.
    let landed = profileOf(call("/client/game/profile/list", "").body, uid)
    check("the rifle came home with the durability the raid left on it",
          updNumber(landed, gunId, "Durability") == 60,
          "Durability is " & $updNumber(landed, gunId, "Durability"))

    let moneyBefore = roublesIn(landed)
    check("the test could count the money", moneyBefore > 3000,
          $moneyBefore & " roubles")

    # 40 points missing, asked for as 9999. Priced at the template's
    # `RepairCost` of 50 a point and the loyalty level's `repair_price_coef` of
    # 100 per cent: 2000 roubles, not 499950.
    let repaired = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"TraderRepair\",\"tid\":\"" &
      "54cb50c76803fa8b248b4571\",\"repairItems\":[{\"_id\":\"" & gunId &
      "\",\"count\":9999}]}],\"tm\":2}")
    check("a trader repair is accepted", repaired.ok and
          not repaired.contains("no durability"), repaired.body)
    let afterTrader = profileOf(call("/client/game/profile/list", "").body, uid)
    check("and the rifle is repaired to what it can now hold",
          updNumber(afterTrader, gunId, "Durability") == 99,
          "Durability is " & $updNumber(afterTrader, gunId, "Durability"))
    check("and the repair cost it a point of its maximum, permanently",
          updNumber(afterTrader, gunId, "MaxDurability") == 99,
          "MaxDurability is " & $updNumber(afterTrader, gunId, "MaxDurability"))
    check("and the price was the item's arithmetic, not the request's count",
          moneyBefore - roublesIn(afterTrader) == 2000,
          "the repair took " & $(moneyBefore - roublesIn(afterTrader)) &
          " roubles, not 2000")
    # Turnover, so the restart section's exact `salesSum` covers this too.
    expectedSales = expectedSales + 2000

    let notDamaged = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"TraderRepair\",\"tid\":\"" &
      "54cb50c76803fa8b248b4571\",\"repairItems\":[{\"_id\":\"" & gunId &
      "\",\"count\":10}]}],\"tm\":2}")
    check("repairing something that is not damaged is refused",
          notDamaged.contains("not damaged"), notDamaged.body)
    check("and it did not take the money anyway",
          roublesIn(profileOf(call("/client/game/profile/list", "").body,
                              uid)) == roublesIn(afterTrader),
          "money moved on a refused repair")

    let noPrice = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"TraderRepair\",\"tid\":\"" &
      "54cb50c76803fa8b248b4571\",\"repairItems\":[{\"_id\":\"" & brickId &
      "\",\"count\":10}]}],\"tm\":2}")
    check("and so is repairing something the database gives no durability",
          noPrice.contains("no durability is known"), noPrice.body)

    # The same item twice in one body would be planned twice off the same
    # starting durability: one repair, charged and applied twice.
    let twice = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"TraderRepair\",\"tid\":\"" &
      "54cb50c76803fa8b248b4571\",\"repairItems\":[{\"_id\":\"" & armId &
      "\",\"count\":5},{\"_id\":\"" & armId & "\",\"count\":5}]}],\"tm\":2}")
    check("naming the same item twice in one repair is refused",
          twice.contains("named twice"), twice.body)
    let untouched = profileOf(call("/client/game/profile/list", "").body, uid)
    check("and the plate was not repaired once either",
          updNumber(untouched, armId, "Durability") == 20,
          "Durability is " & $updNumber(untouched, armId, "Durability"))

    # A kit. 30 points missing on class 4 armour, at
    # `durabilityPointCostArmor * armorClass / armorClassDivisor` = 5*4/10 = 2
    # units of the kit's resource a point: 60 of 200 spent, 140 left.
    let kitRepair = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"Repair\",\"target\":\"" & armId &
      "\",\"repairKitsInfo\":[{\"_id\":\"" & kitId &
      "\",\"count\":9999}]}],\"tm\":2}")
    check("a repair with a kit is accepted", kitRepair.ok and
          not kitRepair.contains("no charge"), kitRepair.body)
    let afterKit = profileOf(call("/client/game/profile/list", "").body, uid)
    check("and the plate is repaired to what it can now hold",
          updNumber(afterKit, armId, "Durability") == 47,
          "Durability is " & $updNumber(afterKit, armId, "Durability"))
    check("and a kit repair costs more of the maximum than a trader's",
          updNumber(afterKit, armId, "MaxDurability") == 47,
          "MaxDurability is " & $updNumber(afterKit, armId, "MaxDurability"))
    check("and the kit paid two units a point for class 4 armour",
          updNumber(afterKit, kitId, "Resource") == 140,
          "Resource is " & $updNumber(afterKit, kitId, "Resource"))
    check("and a kit repair takes no money",
          roublesIn(afterKit) == roublesIn(afterTrader),
          "the kit repair charged " &
          $(roublesIn(afterTrader) - roublesIn(afterKit)) & " roubles")

    let kitTwice = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"Repair\",\"target\":\"" & arm2Id &
      "\",\"repairKitsInfo\":[{\"_id\":\"" & kit2Id &
      "\",\"count\":5},{\"_id\":\"" & kit2Id & "\",\"count\":5}]}],\"tm\":2}")
    check("naming the same kit twice in one repair is refused",
          kitTwice.contains("named twice"), kitTwice.body)
    check("and the kit still has everything it had",
          updNumber(profileOf(call("/client/game/profile/list", "").body, uid),
                    kit2Id, "Resource") == 20,
          "the kit was spent on a refused repair")

    # 40 points missing and a kit with 20 units in it, which at two units a
    # point buys ten. The repair is bounded by the kit, not by the damage and
    # not by the 9999 in the body.
    let bounded = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"Repair\",\"target\":\"" & arm2Id &
      "\",\"repairKitsInfo\":[{\"_id\":\"" & kit2Id &
      "\",\"count\":9999}]}],\"tm\":2}")
    check("a repair with a nearly-empty kit is accepted", bounded.ok,
          bounded.body)
    let afterBounded = profileOf(call("/client/game/profile/list", "").body,
                                 uid)
    check("and restores exactly what the kit could pay for",
          updNumber(afterBounded, arm2Id, "Durability") == 20,
          "Durability is " & $updNumber(afterBounded, arm2Id, "Durability"))
    check("and degrades the maximum by exactly that much times the rate",
          updNumber(afterBounded, arm2Id, "MaxDurability") == 49,
          "MaxDurability is " &
          $updNumber(afterBounded, arm2Id, "MaxDurability"))
    check("and a kit spent to nothing is gone rather than left at zero",
          not call("/client/game/profile/list", "").contains(kit2Id),
          "the empty kit is still in the stash")

    let itself = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"Repair\",\"target\":\"" & arm2Id &
      "\",\"repairKitsInfo\":[{\"_id\":\"" & arm2Id &
      "\",\"count\":5}]}],\"tm\":2}")
    check("and an item cannot repair itself",
          itself.contains("cannot repair itself"), itself.body)

    # `TraderRepair.ExcludedCategory` -- the half of a trader's repair refusals
    # that used to be unevaluated. It names **handbook categories**, and the
    # only reason it needs a walk is that a trader excludes a *branch*: the
    # plate's own handbook entry is filed under `5b47...b340`, and what Ragman
    # excludes is `5b47...b33e`, one level above it. A server that matched only
    # the entry's own category would refuse nothing on real data and would
    # still pass a check written against the leaf.
    let excluded = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"TraderRepair\",\"tid\":\"" &
      "5ac3b934156ae10c4430e83c\",\"repairItems\":[{\"_id\":\"" & arm3Id &
      "\",\"count\":10}]}],\"tm\":2}")
    check("a trader refuses a whole handbook category, not just a leaf",
          excluded.contains("does not repair"), excluded.body)
    let stillBroken = profileOf(call("/client/game/profile/list", "").body, uid)
    check("and the refused plate is untouched",
          updNumber(stillBroken, arm3Id, "Durability") == 30,
          "Durability is " & $updNumber(stillBroken, arm3Id, "Durability"))

    # And the exclusion is narrow. The carbine is filed in a different branch
    # of the same handbook, so the same trader gets as far as the arithmetic --
    # and refuses it for being undamaged, which is a different refusal
    # entirely. Without this pair, "refuses everything" passes the check above.
    let notExcluded = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"TraderRepair\",\"tid\":\"" &
      "5ac3b934156ae10c4430e83c\",\"repairItems\":[{\"_id\":\"" & gunId &
      "\",\"count\":10}]}],\"tm\":2}")
    check("and an item in another branch of the handbook is not refused for it",
          not notExcluded.contains("does not repair") and
          notExcluded.contains("not damaged"), notExcluded.body)

    # The same plate at a trader who excludes nothing, which is the check that
    # the refusal belongs to the trader rather than to the item.
    let allowedElsewhere = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"TraderRepair\",\"tid\":\"" &
      "54cb50c76803fa8b248b4571\",\"repairItems\":[{\"_id\":\"" & arm3Id &
      "\",\"count\":9999}]}],\"tm\":2}")
    check("and the trader who excludes nothing repairs the same plate",
          allowedElsewhere.ok and
          not allowedElsewhere.contains("does not repair"),
          allowedElsewhere.body)
    let mended = profileOf(call("/client/game/profile/list", "").body, uid)
    check("for exactly the 20 points it was missing",
          updNumber(mended, arm3Id, "Durability") == 49,
          "Durability is " & $updNumber(mended, arm3Id, "Durability"))
    # 20 points at the template's `RepairCost` of 100 and a `repair_price_coef`
    # of 100 per cent, which the restart section's exact `salesSum` covers.
    expectedSales = expectedSales + 2000
  else:
    note "no database fixture; skipping the repair checks"

  heading "Notes and map markers"
  if haveFixture:
    let added = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"AddNote\",\"note\":{\"Time\":123," &
      "\"Text\":\"Stash the ammo\"}}],\"tm\":2}")
    check("a note is accepted", added.ok and not added.contains("no note"),
          added.body)
    check("and it is on the profile",
          call("/client/game/profile/list", "").contains("Stash the ammo"),
          "the note is not in the profile")
    let edited = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"EditNote\",\"index\":0,\"note\":{\"Time\":124," &
      "\"Text\":\"Sell the ammo\"}}],\"tm\":2}")
    check("editing it is accepted", edited.ok, edited.body)
    let afterEdit = call("/client/game/profile/list", "")
    check("and it replaced the note rather than adding one",
          afterEdit.contains("Sell the ammo") and
          not afterEdit.contains("Stash the ammo"), "both notes are there")
    let badIndex = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"EditNote\",\"index\":5,\"note\":{\"Time\":1," &
      "\"Text\":\"Nowhere\"}}],\"tm\":2}")
    check("an index the list does not have is refused rather than clamped",
          badIndex.contains("there is no note 5") and
          not call("/client/game/profile/list", "").contains("Nowhere"),
          badIndex.body)
    let deleted = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"DeleteNote\",\"index\":0}],\"tm\":2}")
    check("deleting it is accepted", deleted.ok, deleted.body)
    check("and the note is gone",
          not call("/client/game/profile/list", "").contains("Sell the ammo"),
          "the note survived its own deletion")

    # Markers live on the *item*, not on the profile: a marker is drawn on one
    # particular paper map, and selling the map sells the marks on it.
    let marked = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"CreateMapMarker\",\"item\":\"" & mapId &
      "\",\"mapMarker\":{\"X\":10,\"Y\":20,\"Note\":\"Cache\"," &
      "\"Type\":\"pmc\"}}],\"tm\":2}")
    check("a map marker is accepted", marked.ok and
          not marked.contains("no such item"), marked.body)
    let markedDoc = profileOf(call("/client/game/profile/list", "").body, uid)
    check("and it is on the map rather than on the profile",
          findFrom(itemSlice(markedDoc, mapId), "\"Note\":\"Cache\"", 0) >= 0,
          itemSlice(markedDoc, mapId))
    let sameSpot = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"CreateMapMarker\",\"item\":\"" & mapId &
      "\",\"mapMarker\":{\"X\":10,\"Y\":20,\"Note\":\"Twice\"," &
      "\"Type\":\"pmc\"}}],\"tm\":2}")
    check("a second marker in the same cell is refused",
          sameSpot.contains("already a marker there"), sameSpot.body)
    let movedMarker = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"EditMapMarker\",\"item\":\"" & mapId &
      "\",\"X\":10,\"Y\":20,\"mapMarker\":{\"X\":11,\"Y\":21," &
      "\"Note\":\"Moved\",\"Type\":\"pmc\"}}],\"tm\":2}")
    check("editing a marker is accepted", movedMarker.ok, movedMarker.body)
    let movedDoc = profileOf(call("/client/game/profile/list", "").body, uid)
    check("and it moved the marker rather than adding a second one",
          findFrom(itemSlice(movedDoc, mapId), "\"Note\":\"Moved\"", 0) >= 0 and
          findFrom(itemSlice(movedDoc, mapId), "\"Note\":\"Cache\"", 0) < 0,
          itemSlice(movedDoc, mapId))
    discard call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"CreateMapMarker\",\"item\":\"" & mapId &
      "\",\"mapMarker\":{\"X\":1,\"Y\":1,\"Note\":\"Two\",\"Type\":\"pmc\"}}," &
      "{\"Action\":\"CreateMapMarker\",\"item\":\"" & mapId &
      "\",\"mapMarker\":{\"X\":2,\"Y\":2,\"Note\":\"Three\"," &
      "\"Type\":\"pmc\"}}],\"tm\":2}")
    let fourth = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"CreateMapMarker\",\"item\":\"" & mapId &
      "\",\"mapMarker\":{\"X\":3,\"Y\":3,\"Note\":\"Four\"," &
      "\"Type\":\"pmc\"}}],\"tm\":2}")
    check("the map's own `MaxMarkersCount` is the limit, and it is enforced",
          fourth.contains("holds 3 markers"), fourth.body)
    let removedMarker = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"DeleteMapMarker\",\"item\":\"" & mapId &
      "\",\"X\":11,\"Y\":21}],\"tm\":2}")
    check("deleting a marker is accepted", removedMarker.ok,
          removedMarker.body)
    check("and it is the one that went",
          findFrom(itemSlice(profileOf(
            call("/client/game/profile/list", "").body, uid), mapId),
            "\"Note\":\"Moved\"", 0) < 0, "the wrong marker was deleted")
    let noMap = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"CreateMapMarker\",\"item\":" &
      "\"aa11notmine00000000001x\",\"mapMarker\":{\"X\":1,\"Y\":1," &
      "\"Note\":\"Nowhere\",\"Type\":\"pmc\"}}],\"tm\":2}")
    check("a marker on an item the player does not own is refused",
          noMap.contains("no such item"), noMap.body)
  else:
    note "no database fixture; skipping the note and marker checks"

  heading "The client's own batch"
  # `ApplyInventoryChanges` hands back whole item documents and says "make it
  # look like this". The position is the client's to decide; the stack size, the
  # template and the durability are not, and an entry claiming one of those is
  # where a sort turns into free money.
  if haveFixture:
    let sorted1 = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"ApplyInventoryChanges\",\"changedItems\":[" &
      "{\"_id\":\"" & mapId & "\",\"_tpl\":\"ppppmap00000000000000001\"," &
      "\"parentId\":\"" & gearStash & "\",\"slotId\":\"hideout\"," &
      "\"location\":{\"x\":9,\"y\":0,\"r\":\"Horizontal\"}}]}],\"tm\":2}")
    check("a layout the client worked out is accepted", sorted1.ok and
          not sorted1.contains("no such item"), sorted1.body)
    let sortedDoc = profileOf(call("/client/game/profile/list", "").body, uid)
    check("and the item moved to where the client put it",
          updNumber(sortedDoc, mapId, "x") == 9,
          "x is " & $updNumber(sortedDoc, mapId, "x"))
    check("and the markers on it survived the sort",
          findFrom(itemSlice(sortedDoc, mapId), "\"Markers\"", 0) >= 0,
          "the layout pass dropped the map's markers")

    let moneyNow = roublesIn(sortedDoc)
    let fatStack = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"ApplyInventoryChanges\",\"changedItems\":[" &
      "{\"_id\":\"" & moneyId & "\",\"upd\":{\"StackObjectsCount\":99999999}}" &
      "]}],\"tm\":2}")
    check("a batch that would change a stack size is refused",
          fatStack.contains("would change the stack"), fatStack.body)
    check("and the money is exactly what it was",
          roublesIn(profileOf(call("/client/game/profile/list", "").body,
                              uid)) == moneyNow,
          "the batch changed the money")

    let loop = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"ApplyInventoryChanges\",\"changedItems\":[" &
      "{\"_id\":\"" & gearStash & "\",\"parentId\":\"" & mapId & "\"}]}]," &
      "\"tm\":2}")
    check("a batch that would put the stash inside what it holds is refused",
          loop.contains("inside itself"), loop.body)
    let intact = profileOf(call("/client/game/profile/list", "").body, uid)
    check("and the stash still has no parent",
          findFrom(itemSlice(intact, gearStash), "parentId", 0) < 0,
          itemSlice(intact, gearStash))

    # And the same damage by a route the cycle check cannot see: the stash into
    # the *equipment* root closes no loop and still leaves the client nothing to
    # draw, because the five containers a profile is built on are exactly the
    # items with no parent.
    let uprooted = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"ApplyInventoryChanges\",\"changedItems\":[" &
      "{\"_id\":\"" & gearStash & "\",\"parentId\":\"" &
      textAt(intact, 0, "equipment") & "\"}]}],\"tm\":2}")
    check("and so is one that reparents a container the profile is built on",
          uprooted.contains("does not go inside anything"), uprooted.body)
    check("and the stash still has no parent after that either",
          findFrom(itemSlice(profileOf(
            call("/client/game/profile/list", "").body, uid), gearStash),
            "parentId", 0) < 0, "the stash was given a parent")

    let batchDelete = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"ApplyInventoryChanges\",\"changedItems\":[]," &
      "\"deletedItems\":[{\"_id\":\"" & brickId & "\"}]}],\"tm\":2}")
    check("a batch may not delete anything",
          batchDelete.contains("does not delete items from a batch"),
          batchDelete.body)
    check("and the item it named is still there",
          call("/client/game/profile/list", "").contains(brickId),
          "the batch deleted it anyway")

    let ghost = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"ApplyInventoryChanges\",\"changedItems\":[" &
      "{\"_id\":\"aa11nothere0000000000001\",\"parentId\":\"" & gearStash &
      "\"}]}],\"tm\":2}")
    check("and a batch may not invent an item either",
          ghost.contains("no such item"), ghost.body)
  else:
    note "no database fixture; skipping the batch checks"

  heading "Achievements"
  # Listed forever, awarded never: `Statistic` answered an empty map and the
  # profile's `Achievements` was never written. The evaluator is the quest one,
  # so what is new here is the table it is pointed at and the rule about what
  # may not be awarded.
  if haveFixture:
    let beforeAch = call("/client/achievement/statistic", "")
    check("nothing has been achieved yet",
          not beforeAch.contains("ach_level_two"), beforeAch.body)
    let achDoc = profileOf(call("/client/game/profile/list", "").body, uid)
    let infoAt = find(achDoc, "\"Info\":")
    let expBefore = numberAt(achDoc, infoAt, "Experience")
    check("the test could read the experience", expBefore >= 0, $expBefore)
    let levelled = withNumber(achDoc, "Level", 2)
    check("the test could put the profile on level two",
          levelled.len > 100 and findFrom(levelled, "\"Level\":2", 0) > 0,
          $levelled.len & " bytes")
    discard call("/client/match/local/end",
                 "{\"results\":{\"result\":\"Survived\",\"profile\":" & levelled & "}}")
    let afterAch = profileOf(call("/client/game/profile/list", "").body, uid)
    check("the achievement whose condition is met and checkable is awarded",
          findFrom(afterAch, "ach_level_two", 0) > 0,
          "Achievements is " & memberObject(afterAch, "Achievements"))
    check("and its reward experience was paid, exactly once",
          numberAt(afterAch, find(afterAch, "\"Info\":"), "Experience") ==
            expBefore + 100,
          "experience is " &
          $numberAt(afterAch, find(afterAch, "\"Info\":"), "Experience") &
          ", not " & $(expBefore + 100))
    check("the one whose condition this server cannot evaluate is not awarded",
          findFrom(afterAch, "ach_unknowable", 0) < 0,
          "an unverifiable achievement was awarded")
    check("and neither is the one with no conditions at all",
          findFrom(afterAch, "ach_empty", 0) < 0,
          "an achievement with an empty condition group was awarded")
    let stat = call("/client/achievement/statistic", "")
    check("the statistic counts the profiles that hold it",
          stat.contains("\"ach_level_two\":1"), stat.body)

    # Again. An award that fires once per raid is an experience tap.
    let secondDoc = profileOf(call("/client/game/profile/list", "").body, uid)
    discard call("/client/match/local/end",
                 "{\"results\":{\"result\":\"Survived\",\"profile\":" & secondDoc & "}}")
    let afterSecond = profileOf(call("/client/game/profile/list", "").body, uid)
    check("a second raid does not award it again",
          numberAt(afterSecond, find(afterSecond, "\"Info\":"),
                   "Experience") == expBefore + 100,
          "experience is " &
          $numberAt(afterSecond, find(afterSecond, "\"Info\":"), "Experience"))
    check("and the statistic still counts one",
          call("/client/achievement/statistic", "").contains(
            "\"ach_level_two\":1"), "the count moved")
  else:
    note "no database fixture; skipping the achievement checks"

  heading "Fence and scav karma"
  # Two rates, and only one of them is this server's own.
  #
  # The reference gives Fence's requirement -- `TraderInfo.standing` against
  # `TraderLoyaltyLevel.MinStanding` -- and no figure for *surviving* a scav
  # run, so that one is a setting: 0.01 an extract and nothing for a death, and
  # the first two checks pin the configured number rather than a number this
  # file believes in.
  #
  # The **kills** are the game's own, and they were being thrown away.
  # `bots.types.<role>.experience.standingForKill` is in the database for all
  # 57 roles -- `assault` -0.04 at `normal`, `bear` +0.02 -- and nothing read
  # it back off the raid's own `Stats.Eft.Victims`. So killing scavs as a scav
  # was free and killing PMCs as a scav earned nothing, and the whole of
  # Fence's -7..+6 ladder ran off one invented constant counting extractions.
  # Everything below the second check is about that.
  #
  # The scav section above already ran one survived raid and one death, neither
  # carrying a victim list, so the standing before this section is one
  # extract's worth. That is the check that says a death costs nothing, and it
  # is worth more than two more raids here.
  if haveFixture:
    let karmaDoc = profileOf(call("/client/game/profile/list", "").body, uid)
    let fence = traderEntry(karmaDoc, "579dc571d53a0658a154fbec")
    check("the scav raids so far moved Fence's standing", fence.len > 0,
          "there is no Fence entry on the profile")
    check("by exactly one extract's worth -- the death cost nothing",
          rawNumberAt(fence, 0, "standing") == "0.01",
          "standing is " & rawNumberAt(fence, 0, "standing") & ", not 0.01")

    let karmaList = call("/client/game/profile/list", "")
    let karmaScav = jsonText(karmaList.body, "savage")
    let karmaGear = textAt(karmaList.body,
                           find(karmaList.body, "\"_id\":\"" & karmaScav & "\""),
                           "equipment")
    discard call("/client/match/local/end",
      "{\"results\":{\"result\":\"Survived\",\"profile\":{\"_id\":\"" & karmaScav &
      "\",\"Inventory\":{\"equipment\":\"" & karmaGear & "\",\"items\":[" &
      "{\"_id\":\"" & karmaGear &
      "\",\"_tpl\":\"55d7217a4bdc2d86028b456d\"}]}}}}")
    let karmaAfter = traderEntry(
      profileOf(call("/client/game/profile/list", "").body, uid),
      "579dc571d53a0658a154fbec")
    check("and another extract moves it by exactly the configured rate again",
          rawNumberAt(karmaAfter, 0, "standing") == "0.02",
          "standing is " & rawNumberAt(karmaAfter, 0, "standing") &
          ", not 0.02")

    # ---- and now the kills ------------------------------------------------
    #
    # The victims go into the profile the client hands back, in the member the
    # client puts them in -- `Stats.Eft.Victims` -- because that is the
    # document the claim is about. `endScavRaid` copies only *items* off it, so
    # if the karma pass did not read the victims here nothing else ever would.
    #
    # Every expected standing below is the arithmetic written out, so a wrong
    # one says which term is wrong rather than "not 0.02".

    # Two scavs, at the fixture's own `assault` rate of -0.04 at `normal`.
    # 0.02 + 0.01 extract - 0.08 = -0.05. A server that ignores the victim list
    # answers 0.03 here.
    let killList1 = call("/client/game/profile/list", "")
    let killScav1 = jsonText(killList1.body, "savage")
    let killGear1 = textAt(killList1.body,
                           find(killList1.body, "\"_id\":\"" & killScav1 & "\""),
                           "equipment")
    discard call("/client/match/local/end",
      "{\"results\":{\"result\":\"Survived\",\"profile\":{\"_id\":\"" & killScav1 &
      "\",\"Stats\":{\"Eft\":{\"Victims\":[" &
      "{\"Side\":\"Savage\",\"Role\":\"assault\",\"BodyPart\":\"Head\"}," &
      "{\"Side\":\"Savage\",\"Role\":\"assault\",\"BodyPart\":\"Chest\"}]}}," &
      "\"Inventory\":{\"equipment\":\"" & killGear1 & "\",\"items\":[" &
      "{\"_id\":\"" & killGear1 &
      "\",\"_tpl\":\"55d7217a4bdc2d86028b456d\"}]}}}}")
    let killed1 = traderEntry(
      profileOf(call("/client/game/profile/list", "").body, uid),
      "579dc571d53a0658a154fbec")
    check("killing scavs as a scav costs standing at the game's own rate",
          rawNumberAt(killed1, 0, "standing") == "-0.05",
          "standing is " & rawNumberAt(killed1, 0, "standing") &
          ", not -0.05 (0.02 + 0.01 extract - 2 x 0.04)")

    # One PMC, at `bear`'s +0.02, scaled by the fixture's
    # `PmcBotKillStandingMultiplier` of 3. -0.05 + 0.01 + 0.06 = 0.02. A server
    # that credits the kill and ignores the multiplier answers -0.02; one that
    # ignores PMC kills entirely answers -0.04. The join is on the report's own
    # `Side`, which is why the victim carries one.
    let killList2 = call("/client/game/profile/list", "")
    let killScav2 = jsonText(killList2.body, "savage")
    let killGear2 = textAt(killList2.body,
                           find(killList2.body, "\"_id\":\"" & killScav2 & "\""),
                           "equipment")
    discard call("/client/match/local/end",
      "{\"results\":{\"result\":\"Survived\",\"profile\":{\"_id\":\"" & killScav2 &
      "\",\"Stats\":{\"Eft\":{\"Victims\":[" &
      "{\"Side\":\"Bear\",\"Role\":\"bear\",\"BodyPart\":\"Head\"}]}}," &
      "\"Inventory\":{\"equipment\":\"" & killGear2 & "\",\"items\":[" &
      "{\"_id\":\"" & killGear2 &
      "\",\"_tpl\":\"55d7217a4bdc2d86028b456d\"}]}}}}")
    let killed2 = traderEntry(
      profileOf(call("/client/game/profile/list", "").body, uid),
      "579dc571d53a0658a154fbec")
    check("and killing a PMC as a scav earns it, at the multiplier the database gives",
          rawNumberAt(killed2, 0, "standing") == "0.02",
          "standing is " & rawNumberAt(killed2, 0, "standing") &
          ", not 0.02 (-0.05 + 0.01 extract + 3 x 0.02)")

    # A role the database prices at `easy` and not at `normal`, and a role it
    # does not carry at all. Both must earn nothing, so the standing moves by
    # the extract alone: 0.02 + 0.01 = 0.03. The fixture's `gifter` is -0.9 at
    # `easy` precisely so that a server which fell back to whichever column the
    # role happens to have cannot hide -- it would answer -0.87.
    let killList3 = call("/client/game/profile/list", "")
    let killScav3 = jsonText(killList3.body, "savage")
    let killGear3 = textAt(killList3.body,
                           find(killList3.body, "\"_id\":\"" & killScav3 & "\""),
                           "equipment")
    discard call("/client/match/local/end",
      "{\"results\":{\"result\":\"Survived\",\"profile\":{\"_id\":\"" & killScav3 &
      "\",\"Stats\":{\"Eft\":{\"Victims\":[" &
      "{\"Side\":\"Savage\",\"Role\":\"gifter\",\"BodyPart\":\"Head\"}," &
      "{\"Side\":\"Savage\",\"Role\":\"bossKilla\",\"BodyPart\":\"Head\"}]}}," &
      "\"Inventory\":{\"equipment\":\"" & killGear3 & "\",\"items\":[" &
      "{\"_id\":\"" & killGear3 &
      "\",\"_tpl\":\"55d7217a4bdc2d86028b456d\"}]}}}}")
    let killed3 = traderEntry(
      profileOf(call("/client/game/profile/list", "").body, uid),
      "579dc571d53a0658a154fbec")
    check("a role this database does not price at `normal` earns nothing rather than the wrong column",
          rawNumberAt(killed3, 0, "standing") == "0.03",
          "standing is " & rawNumberAt(killed3, 0, "standing") &
          ", not 0.03 (0.02 + 0.01 extract, both kills unpriced)")

    # And a death. The configured death figure is zero, so before this the raid
    # changed nothing at all; the kills are what makes a scav who murders the
    # map and then dies cost something. 0.03 + 0 - 0.04 = -0.01.
    let killList4 = call("/client/game/profile/list", "")
    let killScav4 = jsonText(killList4.body, "savage")
    let killGear4 = textAt(killList4.body,
                           find(killList4.body, "\"_id\":\"" & killScav4 & "\""),
                           "equipment")
    discard call("/client/match/local/end",
      "{\"results\":{\"result\":\"Killed\",\"profile\":{\"_id\":\"" & killScav4 &
      "\",\"Stats\":{\"Eft\":{\"Victims\":[" &
      "{\"Side\":\"Savage\",\"Role\":\"assault\",\"BodyPart\":\"Head\"}]}}," &
      "\"Inventory\":{\"equipment\":\"" & killGear4 & "\",\"items\":[" &
      "{\"_id\":\"" & killGear4 &
      "\",\"_tpl\":\"55d7217a4bdc2d86028b456d\"}]}}}}")
    let killed4 = traderEntry(
      profileOf(call("/client/game/profile/list", "").body, uid),
      "579dc571d53a0658a154fbec")
    check("a scav who kills and then dies is still charged for the kills",
          rawNumberAt(killed4, 0, "standing") == "-0.01",
          "standing is " & rawNumberAt(killed4, 0, "standing") &
          ", not -0.01 (0.03 + 0 for the death - 0.04)")
  else:
    note "no database fixture; skipping the scav karma checks"

  heading "What a hideout upgrade costs"
  # Two faults, both invisible on a fixture whose areas require nothing and
  # complete instantly, and both found by running against a real database. The
  # areas below exist so that this file can see them too: 20 is gated behind a
  # loyalty level nothing in this run reaches, 21 costs money and takes an hour,
  # and 22 is gated behind an area level nothing reaches.
  if haveFixture:
    let beforeUpgrade = profileOf(call("/client/game/profile/list", "").body,
                                  uid)
    let moneyBeforeUpgrade = roublesIn(beforeUpgrade)

    let notLoyal = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutUpgrade\",\"areaType\":20}],\"tm\":2}")
    check("an upgrade needing a loyalty level the player has not reached is refused",
          notLoyal.contains("loyalty level 3"), notLoyal.body)
    let notArea = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutUpgrade\",\"areaType\":22}],\"tm\":2}")
    check("and one needing an area level the player has not built",
          notArea.contains("level 5"), notArea.body)
    check("and neither of them was granted",
          not call("/client/game/profile/list", "").contains("\"type\":22"),
          "an area was created by a refused upgrade")

    # 1200 roubles and an hour. The money is the check that the requirements
    # are *taken* -- the whole hideout used to be free -- and the hour is the
    # check that the timer this server has always computed is now also read.
    let started = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutUpgrade\",\"areaType\":21}],\"tm\":2}")
    check("an upgrade the player can afford is accepted", started.ok and
          not started.contains("not enough"), started.body)
    let afterStart = profileOf(call("/client/game/profile/list", "").body, uid)
    check("and it took exactly the stage's materials",
          moneyBeforeUpgrade - roublesIn(afterStart) == 1200,
          "the upgrade took " & $(moneyBeforeUpgrade - roublesIn(afterStart)) &
          " roubles, not 1200")
    let tooSoon = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutUpgradeComplete\",\"areaType\":21}]," &
      "\"tm\":2}")
    check("and it cannot be completed before its construction time",
          tooSoon.contains("still under construction"), tooSoon.body)
    let stillZero = profileOf(call("/client/game/profile/list", "").body, uid)
    let area21 = find(stillZero, "\"type\":21")
    check("and the area is still at level zero",
          area21 >= 0 and numberAt(stillZero, area21, "level") == 0,
          "level is " & $numberAt(stillZero, area21, "level"))

    let restart = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutUpgrade\",\"areaType\":21}],\"tm\":2}")
    check("and a second start of the same upgrade is refused",
          restart.contains("already being upgraded"), restart.body)
    check("rather than charging for it twice",
          roublesIn(profileOf(call("/client/game/profile/list", "").body,
                              uid)) == roublesIn(afterStart),
          "the second start took the materials again")

    # -- what a stage may not refuse: nothing -----------------------------
    #
    # Area 23 is the shape every area in an imported hideout table has and no
    # other area here does: a stage asking for materials the stash owns none
    # of. It briefly *started* -- taking what the stash had, warning about the
    # rest and granting the level -- because against real data refusing it is a
    # hideout a fresh profile can never begin. It refuses again, and the answer
    # to a profile that cannot afford a stage is to go and get the materials;
    # `tools/realtest.nim` does exactly that against the real tables.
    let moneyBeforeShort = roublesIn(profileOf(
      call("/client/game/profile/list", "").body, uid))
    let short = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutUpgrade\",\"areaType\":23}],\"tm\":2}")
    check("a stage asking for materials the stash has none of is refused",
          short.contains("not enough 59e35de086f7741778269d84"), short.body)
    check("and took nothing for the ones it could have taken",
          roublesIn(profileOf(call("/client/game/profile/list", "").body,
                              uid)) == moneyBeforeShort,
          "a refused upgrade moved money")
    check("and the area it would have created is not there",
          not call("/client/game/profile/list", "").contains("\"type\":23"),
          "a refused upgrade created an area")
    let shortDone = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutUpgradeComplete\",\"areaType\":23}]," &
      "\"tm\":2}")
    check("and it cannot be completed either",
          shortDone.contains("not being upgraded"), shortDone.body)

    # The other half of the same rule, and the half area 21 does not cover: a
    # stage whose material is an ordinary item rather than money. The two screw
    # nuts are the ones the workbench crafted in the Production section.
    let beforeItems = profileOf(call("/client/game/profile/list", "").body, uid)
    check("the stash holds the two screw nuts that stage asks for",
          find(beforeItems, "59e35de086f7741778269d83") >= 0,
          "the craft output is not in the stash")
    let payItem = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutUpgrade\",\"areaType\":28}],\"tm\":2}")
    check("a stage whose material the stash does hold is accepted",
          payItem.ok and not payItem.contains("not enough"), payItem.body)
    let afterItems = profileOf(call("/client/game/profile/list", "").body, uid)
    check("and it took them, rather than only checking for them",
          find(afterItems, "59e35de086f7741778269d83") < 0,
          "the stage material is still in the stash")
    let itemDone = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutUpgradeComplete\",\"areaType\":28}]," &
      "\"tm\":2}")
    let atLevel = profileOf(call("/client/game/profile/list", "").body, uid)
    let area28 = find(atLevel, "\"type\":28")
    check("and the area reaches level one",
          itemDone.ok and area28 >= 0 and
          numberAt(atLevel, area28, "level") == 1,
          "level is " & $numberAt(atLevel, area28, "level"))

    # Currency is the other half, and it is still hard: a rouble stack carries
    # no state this server cannot see, so "you do not have that many" is a
    # statement it is entitled to make -- and the free-hideout bug was about
    # exactly this, an area stage worth 395,000 roubles that took none of them.
    let unaffordable = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutUpgrade\",\"areaType\":24}],\"tm\":2}")
    check("an upgrade priced in money the player does not have is refused",
          unaffordable.contains("not enough 5449016a4bdc2d6f028b456f"),
          unaffordable.body)
    check("and the area it would have created is not there",
          not call("/client/game/profile/list", "").contains("\"type\":24"),
          "a refused upgrade created an area")

    # The area's own `requirements`, beside `stages` rather than inside one.
    let ownReq = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutUpgrade\",\"areaType\":25}],\"tm\":2}")
    check("an area's own requirements gate it, not just its stage's",
          ownReq.contains("area 22 at level 6"), ownReq.body)
    let flagOff = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutUpgrade\",\"areaType\":26}],\"tm\":2}")
    check("and the same list with enableAreaRequirements off gates nothing",
          flagOff.ok and not flagOff.contains("area 22"), flagOff.body)

    let skillGate = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutUpgrade\",\"areaType\":27}],\"tm\":2}")
    check("a stage's Skill requirement is read rather than permitted",
          skillGate.contains("HideoutManagement at level 5"), skillGate.body)

    # And the end of the table is the end of the area. Area 3 was built to
    # level 1 above and the fixture describes no stage 2 of it -- neither does a
    # real table past level 3 -- so without this the level climbs for ever,
    # free and instant, and every level of it satisfies a recipe's `Area`
    # requirement.
    let pastEnd = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutUpgrade\",\"areaType\":3}],\"tm\":2}")
    check("an area cannot be upgraded past the last stage the database has",
          pastEnd.contains("no level 2"), pastEnd.body)
    let stillOne = profileOf(call("/client/game/profile/list", "").body, uid)
    let area3 = find(stillOne, "\"type\":3")
    check("and it is still at the level it reached",
          area3 >= 0 and numberAt(stillOne, area3, "level") == 1,
          "level is " & $numberAt(stillOne, area3, "level"))
  else:
    note "no database fixture; skipping the hideout requirement checks"

  heading "What a bot is wearing"
  # The generator read three fields out of `bots.types.<role>` and none of them
  # was `inventory`, so every bot in every raid spawned with exactly two items:
  # an empty equipment container and an empty stash. A mod shipping hundreds of
  # equipment ids had all of them land in the database and none reach a bot.
  if haveFixture:
    let dressed = call("/client/game/bot/generate",
      "{\"conditions\":[{\"Role\":\"assault\",\"Limit\":2," &
      "\"Difficulty\":\"normal\"}]}")
    check("bots are generated", dressed.ok, dressed.body)
    check("and they are wearing what the loadout table says",
          dressed.contains("\"slotId\":\"Headwear\"") and
          dressed.contains("bbbbhat00000000000000001"), dressed.body)
    check("and carrying a weapon from it",
          dressed.contains("\"slotId\":\"FirstPrimaryWeapon\"") and
          dressed.contains("wwwwgun00000000000000001"), dressed.body)
    # `mod_scope` is at 100 in the fixture's chances and `mod_muzzle` at 0. The
    # pair is the check: one proves the mod tree is walked at all, the other
    # proves a zero chance is a refusal rather than a default.
    check("with the mods the chance table says it should have",
          dressed.contains("\"slotId\":\"mod_scope\""), dressed.body)
    check("and none of the ones it says it should not",
          not dressed.contains("\"slotId\":\"mod_muzzle\""), dressed.body)
    # The magazine is a mod, and the rounds in it come from `inventory.Ammo`
    # keyed by the *weapon's* caliber, filled to the magazine's own capacity.
    check("and a magazine with the right calibre in it",
          dressed.contains("\"slotId\":\"mod_magazine\"") and
          dressed.contains("\"slotId\":\"cartridges\"") and
          dressed.contains("aaaaammo0000000000000001"), dressed.body)
    check("filled to exactly the magazine's capacity",
          countOf(dressed.body, "\"StackObjectsCount\":30") == 2,
          $countOf(dressed.body, "\"StackObjectsCount\":30") &
          " magazines held 30 rounds, not 2")
    # A slot the equipment chance table gives a zero to.
    check("and nothing in a slot the table gives a zero to",
          not dressed.contains("\"slotId\":\"Eyewear\""), dressed.body)
    # The same request twice: the generator is seeded from each bot's own id,
    # which is a counter, so a batch is reproducible within a run and two
    # batches are not the same bots.
    check("and the bot has a difficulty the request asked for",
          dressed.contains("\"BotDifficulty\":\"normal\""), dressed.body)

    # And what it is *carrying*, which is a second generator with its own two
    # tables: `inventory.items.<slot>` is a pool per container and
    # `generation.items.<kind>.weights` maps a **count** to how likely that
    # count is. A bot with a rig and nothing in it is a kill worth nothing,
    # which is the reason a raid's rewards were thinner than the real game's.
    #
    # The fixture makes all three answers exact: the rig has a 2x2 grid, one
    # 1x1 item in its pool, and a weight on a count of two.
    check("a bot is carrying what its loot table says",
          countOf(dressed.body, "lllloot00000000000000001") == 4,
          $countOf(dressed.body, "lllloot00000000000000001") &
          " loot items across two bots, not 4")
    # Two items in a 2x2 grid, each in its own cell and each naming the grid it
    # is in. An item written without a location, or two written into the same
    # cell, is drawn on top of what is there and cannot be picked up -- which
    # looks exactly like the bot never having had it.
    check("and each piece of it is in a real cell of the container's grid",
          countOf(dressed.body, "\"slotId\":\"main\",\"location\":{\"x\":0,\"y\":0") == 2 and
          countOf(dressed.body, "\"slotId\":\"main\",\"location\":{\"x\":1,\"y\":0") == 2,
          dressed.body)
    # The backpack's pool holds a 2x1 item and its grid is 1x1, so it fits in
    # neither orientation. The count says two; the container says none, and the
    # container wins -- because the alternative is a location that overlaps.
    check("and a container with no room for it gets none rather than an overlap",
          not dressed.contains("bbbbulk00000000000000001"), dressed.body)
    # Pockets with room in them and a weight on a count of zero. The pair with
    # the rig is the check: one proves the pool is drawn from at all, the other
    # proves a count of zero is a refusal rather than a default.
    check("and a count of zero puts nothing in a container that has room",
          countOf(dressed.body, "ppppockt0000000000000001") == 2 and
          not dressed.contains("\"slotId\":\"pocket1\""), dressed.body)

    let capped = call("/client/game/bot/limit?location=factory4_day", "")
    check("the bot limit comes from the map rather than a constant",
          capped.contains("\"data\":9"), capped.body)
    let unknownMap = call("/client/game/bot/limit?location=nowhere", "")
    check("and a map the database says nothing about gets the default",
          unknownMap.contains("\"data\":30"), unknownMap.body)

    let brains = call(
      "/client/game/bot/difficulty?type=assault&difficulty=hard", "")
    check("bot difficulty is the role's own, not one table for every bot",
          brains.contains("0.1") and
          not brains.contains("fallback brain settings"), brains.body)
    let coreBrains = call(
      "/client/game/bot/difficulty?type=assault&difficulty=nosuchlevel", "")
    check("and a difficulty the role does not have falls back to the core one",
          coreBrains.contains("fallback brain settings"), coreBrains.body)

    # ---- and what a bot *is*: its face, its voice, and its body ----------
    #
    # Everything above this point is about a bot's gear, and every check in it
    # was green while three defects shipped for months: every bot in every raid
    # wore the same four appearance ids, every bot got the literal 35/85 human
    # health regardless of role, and the voice was written to `Info.Voice` --
    # a member the client's own `BotBase` does not declare.
    #
    # None of the three was visible from here, and the reason was not the
    # checks. It was the fixture: `bots.types.assault.appearance` was four
    # *arrays* and the generator read four arrays, `health.BodyParts` was an
    # object the generator refuses whole, and there was no `bots.base` at all.
    # The fixture was written in the shape the code expected rather than the
    # shape the game ships, so it agreed with every bug. It now carries the
    # real shapes -- five weight maps, with a zero-weight entry and an all-zero
    # pool among them, two `BodyParts` variants with a real range in one part,
    # a `Temperature` range, and SPT's own `bots/base.json` -- and these are
    # the checks that shape makes possible.
    #
    # Twelve bots rather than two. Every defect below is a defect of
    # *sameness*, and a sample of one cannot see one.
    let dozen = call("/client/game/bot/generate",
      "{\"conditions\":[{\"Role\":\"assault\",\"Limit\":12," &
      "\"Difficulty\":\"normal\"}]}")
    let dozenCount = countOf(dozen.body, "55d7217a4bdc2d86028b456d")
    check("a dozen bots are generated", dozen.ok and dozenCount == 12,
          $dozenCount & " bots, not 12")
    # 1. The appearance tables are weight maps, and both weighted heads are
    #    drawn. The sum is asserted as well as the pair, because "both ids
    #    appear" would pass against a generator that also invented a third.
    let headA = countOf(dozen.body, "\"Head\":\"aaaahead0000000000000001\"")
    let headB = countOf(dozen.body, "\"Head\":\"aaaahead0000000000000002\"")
    check("and two of them are not wearing the same head",
          headA > 0 and headB > 0 and headA + headB == dozenCount,
          $headA & " in one head, " & $headB & " in the other, out of " &
          $dozenCount & " bots")
    # 2. A weight of zero means never, not rarely -- for a head and for a
    #    voice, because they are drawn by the same proc and only one of the
    #    five tables was ever read.
    check("and an id the role weights at zero is never worn or spoken",
          not dozen.contains("aaaahead0000000000000003") and
          not dozen.contains("eeeevoic0000000000000002"), dozen.body)
    # 3. A pool whose weights all sum to zero produces *nothing*, and the
    #    fallback is `bots.base`'s own foot. Element zero of a degenerate
    #    distribution is exactly how a map ends up in one pair of boots, so
    #    both halves are asserted: the fixture's ids are absent, and the
    #    base's is on every bot.
    check("and an all-zero pool falls back to bots.base, not to element zero",
          countOf(dozen.body, "\"Feet\":\"5cde9fb87d6c8b0474535da9\"") ==
            dozenCount and not dozen.contains("ccccfeet"),
          dozen.body)
    # 4. The fifth appearance table, and the one nothing ever read.
    #    `Customization.Voice` is `Nullable<MongoId>` on the client's own type.
    check("and the voice is the weighted table's, on Customization",
          countOf(dozen.body, "\"Voice\":\"eeeevoic0000000000000001\"") ==
            dozenCount,
          dozen.body)
    # 5. And *only* there. `Info.Voice` is not a member of `BotBase`, so a bot
    #    carrying two voices is a bot with one the client cannot read. Counted
    #    rather than searched for, because `Customization.Voice` is legitimate
    #    and a search for `"Voice"` would find it and call the bug fixed.
    check("and it is the only Voice on the bot; BotBase declares no other",
          countOf(dozen.body, "\"Voice\":") == dozenCount,
          $countOf(dozen.body, "\"Voice\":") & " Voice members across " &
          $dozenCount & " bots, not one each")
    # 6. `health.BodyParts` is a *list of variants*, drawn from, and rolled.
    #    33 and 44 are the two variants' heads and neither is 35, so a bot that
    #    fell back to the hardcoded human is not a bot that happened to match.
    let head33 = countOf(dozen.body, "\"Head\":{\"Health\":{\"Current\":33")
    let head44 = countOf(dozen.body, "\"Head\":{\"Health\":{\"Current\":44")
    check("and its head health came out of the two-variant table, both of them",
          head33 > 0 and head44 > 0 and head33 + head44 == dozenCount,
          $head33 & " at 33, " & $head44 & " at 44, out of " & $dozenCount &
          " bots -- 35 is the hardcoded human and is neither variant")
    # 7. And the table's own spelling does not reach the client, which reads
    #    `{Health: {Current, Maximum}}` and nothing else.
    # Both halves, and the second is the one that matters. The first bot's
    # `Health` alone is one draw out of two variants, so a `min` left on a part
    # in the *other* variant is invisible to it -- which is exactly what
    # happened the first time this was written. The batch-wide count is what
    # makes the claim about the table rather than about one bot.
    let botHealth = memberObject(dozen.body, "Health")
    check("and the table's {min, max} is nowhere under Health",
          botHealth.len > 0 and find(botHealth, "min") < 0 and
          countOf(dozen.body, "\"min\":") == 0 and
          countOf(dozen.body, "\"max\":") == 0,
          $countOf(dozen.body, "\"min\":") & " min and " &
          $countOf(dozen.body, "\"max\":") & " max across the batch: " &
          botHealth)
    # 8. The profile is `bots.base` with things written over it, and where the
    #    base file and the client's declared type disagree the type wins.
    #    `lockedMoveCommands` is a member only the base carries: nothing in the
    #    generator computes it, so its presence is the base having been opened.
    check("and the bot is built on bots.base, with the client's type winning",
          dozen.contains("\"lockedMoveCommands\":false") and
          countOf(dozen.body, "\"WishList\":{}") == dozenCount and
          not dozen.contains("\"WishList\":[]") and
          not dozen.contains("\"Encyclopedia\":null"), dozen.body)
  else:
    note "no database fixture; skipping the bot loadout checks"

  heading "The dailies"
  # Repeatable quests were the one item on the gap list deliberately left
  # rather than half-built, because the table they need was not among the
  # sections `aowl importdb` imported. It is now -- two of them,
  # `templates.repeatableQuests` and SPT's own `configs/quest.json` -- and the
  # fixture below carries the same two shapes a real install does.
  #
  # Every figure the checks assert is one the fixture *states*: two quests, a
  # `minExtracts` and `maxExtracts` both of 3, a reward spread of zero so that
  # 500 experience and 3000 roubles are paid exactly, and a change cost of
  # 7000. Nothing here is a number this test and the generator agreed on
  # between themselves.
  if haveFixture:
    let daily = call("/client/repeatalbeQuests/activityPeriods", "")
    check("the dailies are generated rather than answered as an empty list",
          daily.ok and daily.contains("\"name\":\"Daily\""), daily.body)
    check("and there are exactly the two the config asks for",
          countOf(daily.body, "\"sptRepatableGroupName\":\"Daily\"") == 2,
          $countOf(daily.body, "\"sptRepatableGroupName\":\"Daily\"") &
          " quests, not 2")
    check("and each is offered by the trader whose whitelist names the type",
          countOf(daily.body, "\"traderId\":\"54cb50c76803fa8b248b4571\"") >= 2,
          daily.body)
    # `minExtracts` and `maxExtracts` are both 3, so the count is not a draw.
    check("and each asks for exactly the extracts the level band names",
          countOf(daily.body, "\"value\":3,\"type\":\"Completion\"") == 2,
          daily.body)
    # The reward budget, at a spread of zero: the band's own figures, whole.
    check("and pays exactly the band's experience",
          countOf(daily.body, "\"type\":\"Experience\",\"value\":500") == 2,
          daily.body)
    check("and exactly the band's roubles, as a real stack of them",
          countOf(daily.body, "\"type\":\"Item\",\"value\":3000") == 2 and
          countOf(daily.body, "\"StackObjectsCount\":3000") == 2, daily.body)
    check("and the standing the band names, printed as a number and not a fraction",
          countOf(daily.body, "\"type\":\"TraderStanding\"") == 2 and
          daily.contains("\"value\":0.01"), daily.body)
    check("and that one free change is left",
          daily.contains("\"freeChanges\":1"), daily.body)

    # The set is *derived*, not stored: same profile, same day, same quests.
    # A server that generated a fresh set per request would hand the player a
    # different daily every time they opened the screen, and any progress on
    # yesterday's would be progress on a quest that no longer exists.
    let dailyAgain = call("/client/repeatalbeQuests/activityPeriods", "")
    check("and asking twice gives the same two quests, not two more",
          dailyAgain.body == daily.body, "the set changed between two reads")

    let firstDaily = idOfQuestIn(daily.body, 0)
    let secondDaily = idOfQuestIn(daily.body, 1)
    check("the test found both generated quest ids",
          firstDaily.len == 24 and secondDaily.len == 24 and
          firstDaily != secondDaily, firstDaily & " / " & secondDaily)

    # `changeRequirement` is the reference's `Dictionary<MongoId,
    # ChangeRequirement>` -- what rerolling *this* quest costs, keyed by the
    # quest. Both quests have to be in it, or the client draws a reroll button
    # with no price behind it. The price itself is pinned further down by a
    # reroll that actually pays it, which is a stronger claim than the number
    # appearing in a body.
    check("and every quest says what changing it would cost",
          daily.contains("\"changeRequirement\":{\"" & firstDaily & "\"") and
          daily.contains("\"changeStandingCost\":0},\"" & secondDaily & "\""),
          daily.body)

    # Accepting one goes through the ordinary quest pipeline -- the same
    # evaluator, the same counters, the same payout -- because the only
    # integration is that `questTemplate` falls back to the generator. The
    # check that says so is the refusal: a quest with no template is *accepted*
    # by this server with a warning saying so, and this one is not.
    let acceptDaily = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"QuestAccept\",\"qid\":\"" & firstDaily &
      "\"}],\"tm\":2}")
    check("a generated daily is accepted with its conditions intact",
          acceptDaily.ok and not acceptDaily.contains("no template for it"),
          acceptDaily.body)
    # And it cannot be handed in for its 3000 roubles without the three
    # extracts. This is the whole point of generating a condition rather than a
    # label: a daily that completes on request is 3000 roubles a click.
    let earlyFinish = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"QuestComplete\",\"qid\":\"" & firstDaily &
      "\"}],\"tm\":2}")
    check("and cannot be completed without doing it",
          earlyFinish.contains("CounterCreator 0 of 3"), earlyFinish.body)

    # A quest already accepted may not be rerolled: the player has progress on
    # it, and replacing it leaves `Quests` naming a template that will never be
    # generated again.
    let rerollAccepted = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"RepeatableQuestChange\",\"qid\":\"" &
      firstDaily & "\"}],\"tm\":2}")
    check("and a daily that has been accepted cannot be changed",
          rerollAccepted.contains("already been accepted"), rerollAccepted.body)

    let beforeReroll = roublesIn(profileOf(
      call("/client/game/profile/list", "").body, uid))
    let freeReroll = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"RepeatableQuestChange\",\"qid\":\"" &
      secondDaily & "\"}],\"tm\":2}")
    check("the first change of the day is free", freeReroll.ok and
          not freeReroll.contains("costs"), freeReroll.body)
    let afterFree = call("/client/repeatalbeQuests/activityPeriods", "")
    check("and it took no money",
          roublesIn(profileOf(call("/client/game/profile/list", "").body,
                              uid)) == beforeReroll,
          "the free change charged " &
          $(beforeReroll - roublesIn(profileOf(
             call("/client/game/profile/list", "").body, uid))) & " roubles")
    check("and there are no free changes left",
          afterFree.contains("\"freeChanges\":0"), afterFree.body)
    # The rerolled slot changed and the other one did not. "The set changed" is
    # the failure a check that only counted quests would pass against.
    check("and it changed exactly the quest it named",
          not afterFree.contains(secondDaily) and
          afterFree.contains(firstDaily), afterFree.body)

    let nextDaily = idOfQuestIn(afterFree.body, 1)
    let paidReroll = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"RepeatableQuestChange\",\"qid\":\"" &
      nextDaily & "\"}],\"tm\":2}")
    check("the next one is paid for", paidReroll.ok, paidReroll.body)
    check("and costs exactly the skeleton's own change cost, not the request's",
          beforeReroll - roublesIn(profileOf(
            call("/client/game/profile/list", "").body, uid)) == 7000,
          "the change took " &
          $(beforeReroll - roublesIn(profileOf(
             call("/client/game/profile/list", "").body, uid))) &
          " roubles, not 7000")

    let notMine = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"RepeatableQuestChange\",\"qid\":\"" &
      "cccccccccccccccccccccccc" & "\"}],\"tm\":2}")
    check("and a quest this profile does not have cannot be changed",
          notMine.contains("no repeatable quest of this profile"),
          notMine.body)
  else:
    note "no database fixture; skipping the repeatable quest checks"

  heading "The sky"
  # A constant with no database path behind it, which is a fine default and a
  # bad only answer: a weather mod had nowhere to write and could not register
  # the route itself, because the backend refuses a duplicate path.
  let sky = call("/client/weather", "")
  check("the weather answers", sky.ok and sky.contains("\"weather\":"),
        sky.body)
  if haveFixture:
    check("and it is the database's sky, not the built-in one",
          sky.contains("\"temp\":-14") and sky.contains("\"season\":3"),
          sky.body)
    check("with a timestamp that is now rather than whatever the table said",
          numberAt(sky.body, find(sky.body, "\"weather\":"),
                   "timestamp") > 1600000000,
          sky.body)

  heading "The menu's own state"
  # Wishlist, favourites, pins, the hotkey bar and saved builds. None of these
  # is worth a raid on its own; together they are most of what a player touches
  # between raids, and every one of them was either an unhandled action or a
  # route answering a shape the client cannot read.

  # `GetFriendListDataResponse` is an object of three lists. This answered `[]`,
  # which parses cleanly and then gives the messenger a null to index -- the
  # exact failure that is worse than a 404, because it lands later and
  # somewhere else.
  let friends = call("/client/friend/list", "")
  check("the friend list is an object with three lists in it",
        friends.contains("\"Friends\":[]") and
        friends.contains("\"Ignore\":[]") and
        friends.contains("\"InIgnoreList\":[]"), friends.body)
  let achieved = call("/client/achievement/statistic", "")
  check("achievement statistics answer `elements`, not a bare object",
        achieved.contains("\"elements\":"), achieved.body)
  let prestige = call("/client/prestige/list", "")
  check("the prestige list answers `elements`, not a bare array",
        prestige.contains("\"elements\":"), prestige.body)
  let chat = call("/client/chatServer/list", "")
  check("there is a chat server to connect to",
        chat.contains("\"Chats\":[]") and chat.contains("\"Regions\":[]"),
        chat.body)
  let mode = call("/client/game/mode", "")
  check("the game mode is answered", mode.contains("\"gameMode\":"), mode.body)
  let status = call("/client/profile/status", "")
  check("profile status lists both characters as free to play",
        countOf(status.body, "\"status\":\"Free\"") == 2, status.body)
  check("and names the profile this session is bound to",
        status.contains(uid), status.body)

  let wished = call("/client/game/profile/items/moving",
    "{\"data\":[{\"Action\":\"AddToWishList\"," &
    "\"items\":{\"5644bd2b4bdc2d3b4c8b4572\":2}}],\"tm\":2}")
  check("an item can be wished for", wished.ok, wished.body)
  let wishDoc = profileOf(call("/client/game/profile/list", "").body, uid)
  check("and it is on the list under the category it was filed in",
        find(memberObject(wishDoc, "WishList"),
             "\"5644bd2b4bdc2d3b4c8b4572\":2") >= 0,
        memberObject(wishDoc, "WishList"))
  let refiled = call("/client/game/profile/items/moving",
    "{\"data\":[{\"Action\":\"ChangeWishlistItemCategory\"," &
    "\"item\":\"5644bd2b4bdc2d3b4c8b4572\",\"category\":7}],\"tm\":2}")
  check("its category can be changed", refiled.ok, refiled.body)
  let refiledDoc = profileOf(call("/client/game/profile/list", "").body, uid)
  let refiledWish = memberObject(refiledDoc, "WishList")
  check("and the change is the category, not a second entry",
        find(refiledWish, "\"5644bd2b4bdc2d3b4c8b4572\":7") >= 0 and
        countOf(refiledWish, "5644bd2b4bdc2d3b4c8b4572") == 1, refiledWish)
  let unwished = call("/client/game/profile/items/moving",
    "{\"data\":[{\"Action\":\"RemoveFromWishList\"," &
    "\"items\":[\"5644bd2b4bdc2d3b4c8b4572\"]}],\"tm\":2}")
  check("and it can be taken off again", unwished.ok, unwished.body)
  check("and then it is not on the list",
        find(profileOf(call("/client/game/profile/list", "").body, uid),
             "\"5644bd2b4bdc2d3b4c8b4572\":7") < 0, "still wished for")
  let phantomWish = call("/client/game/profile/items/moving",
    "{\"data\":[{\"Action\":\"ChangeWishlistItemCategory\"," &
    "\"item\":\"5644bd2b4bdc2d3b4c8b4572\",\"category\":1}],\"tm\":2}")
  check("re-filing something that is not on the list is refused",
        phantomWish.contains("is not on it"), phantomWish.body)

  # Favourites and the hotkey bar name *items*, so both check that the item is
  # really the player's: a star or a hotkey pointing at nothing survives every
  # save until somebody notices.
  let starred = call("/client/game/profile/items/moving",
    "{\"data\":[{\"Action\":\"SetFavoriteItems\",\"items\":[\"" &
    moneyId & "\"]}],\"tm\":2}")
  check("an item can be favourited", starred.ok, starred.body)
  check("and the profile carries it",
        find(profileOf(call("/client/game/profile/list", "").body, uid),
             "\"favoriteItems\":[\"" & moneyId & "\"]") >= 0,
        "favoriteItems does not name it")
  let badStar = call("/client/game/profile/items/moving",
    "{\"data\":[{\"Action\":\"SetFavoriteItems\"," &
    "\"items\":[\"cccccccccccccccccccccccc\"]}],\"tm\":2}")
  check("favouriting something the player does not own is refused",
        badStar.contains("no such item"), badStar.body)
  check("and the favourites that were there are still there",
        find(profileOf(call("/client/game/profile/list", "").body, uid),
             "\"favoriteItems\":[\"" & moneyId & "\"]") >= 0,
        "the good favourite was dropped by the bad request")

  let bound = call("/client/game/profile/items/moving",
    "{\"data\":[{\"Action\":\"Bind\",\"item\":\"" & moneyId &
    "\",\"index\":\"3\"}],\"tm\":2}")
  check("an item can be bound to a hotkey", bound.ok, bound.body)
  check("and the panel names it in that slot",
        find(profileOf(call("/client/game/profile/list", "").body, uid),
             "\"fastPanel\":{\"3\":\"" & moneyId & "\"}") >= 0,
        "fastPanel does not name it")
  # Rebinding must *move* it. One item on two hotkeys is one item the client
  # draws in two places.
  let rebound = call("/client/game/profile/items/moving",
    "{\"data\":[{\"Action\":\"Bind\",\"item\":\"" & moneyId &
    "\",\"index\":\"5\"}],\"tm\":2}")
  check("rebinding it is accepted", rebound.ok, rebound.body)
  check("and moves it rather than leaving it on both",
        find(profileOf(call("/client/game/profile/list", "").body, uid),
             "\"fastPanel\":{\"5\":\"" & moneyId & "\"}") >= 0,
        "fastPanel is not just slot 5")
  let unbound = call("/client/game/profile/items/moving",
    "{\"data\":[{\"Action\":\"Unbind\",\"item\":\"" & moneyId &
    "\"}],\"tm\":2}")
  check("and it can be unbound", unbound.ok, unbound.body)
  check("leaving an empty panel",
        find(profileOf(call("/client/game/profile/list", "").body, uid),
             "\"fastPanel\":{}") >= 0, "fastPanel still has something on it")

  let pinned = call("/client/game/profile/items/moving",
    "{\"data\":[{\"Action\":\"PinLock\",\"Item\":\"" & moneyId &
    "\",\"State\":\"Pinned\"}],\"tm\":2}")
  check("an item can be pinned", pinned.contains("\"PinLockState\":\"Pinned\""),
        pinned.body)
  let badPin = call("/client/game/profile/items/moving",
    "{\"data\":[{\"Action\":\"PinLock\",\"Item\":\"" & moneyId &
    "\",\"State\":\"Welded\"}],\"tm\":2}")
  check("and a pin state the client made up is refused",
        badPin.contains("not a pin state"), badPin.body)

  # Builds. The list is three lists whether or not anything has been saved --
  # `{}` gave the presets screen three nulls to index.
  let noBuilds = call("/client/builds/list", "")
  check("the builds list is three lists even when empty",
        noBuilds.contains("\"equipmentBuilds\":[]") and
        noBuilds.contains("\"weaponBuilds\":[]") and
        noBuilds.contains("\"magazineBuilds\":[]"), noBuilds.body)
  let savedBuild = call("/client/builds/weapon/save",
    "{\"Id\":\"bbbbbbbbbbbbbbbbbbbbbbb1\",\"Name\":\"Cheap AK\"," &
    "\"Root\":\"rrrrrrrrrrrrrrrrrrrrrrr1\"," &
    "\"Items\":[{\"_id\":\"rrrrrrrrrrrrrrrrrrrrrrr1\"," &
    "\"_tpl\":\"5644bd2b4bdc2d3b4c8b4572\"}]}")
  check("a weapon build can be saved", savedBuild.ok, savedBuild.body)
  let listed1 = call("/client/builds/list", "")
  check("and it comes back under weaponBuilds",
        find(between(listed1.body, "\"weaponBuilds\":", "\"magazineBuilds\""),
             "Cheap AK") >= 0, listed1.body)
  # Saving under the same id replaces rather than adds. Re-saving a preset
  # after tweaking it must not leave two of it.
  let resaved = call("/client/builds/weapon/save",
    "{\"Id\":\"bbbbbbbbbbbbbbbbbbbbbbb1\",\"Name\":\"Dear AK\"," &
    "\"Root\":\"rrrrrrrrrrrrrrrrrrrrrrr1\",\"Items\":[]}")
  check("re-saving it is accepted", resaved.ok, resaved.body)
  let listed2 = call("/client/builds/list", "")
  check("and replaces it rather than adding a second",
        countOf(listed2.body, "\"Id\":\"bbbbbbbbbbbbbbbbbbbbbbb1\"") == 1 and
        listed2.contains("Dear AK") and not listed2.contains("Cheap AK"),
        listed2.body)
  let deleted = call("/client/builds/delete",
                     "{\"id\":\"bbbbbbbbbbbbbbbbbbbbbbb1\"}")
  check("a build can be deleted", deleted.ok and deleted.contains("\"err\":0"),
        deleted.body)
  let deletedTwice = call("/client/builds/delete",
                          "{\"id\":\"bbbbbbbbbbbbbbbbbbbbbbb1\"}")
  check("and deleting it again says so rather than answering `done`",
        deletedTwice.contains("no such build"), deletedTwice.body)
  # One kept for the restart: builds are the server's, not the profile's, and
  # the only way to tell a store from a cache is to switch the server off.
  let keptBuild = call("/client/builds/equipment/save",
    "{\"Id\":\"bbbbbbbbbbbbbbbbbbbbbbb2\",\"Name\":\"Raid kit\"," &
    "\"Root\":\"rrrrrrrrrrrrrrrrrrrrrrr2\",\"Items\":[]}")
  check("an equipment build can be saved", keptBuild.ok, keptBuild.body)

  heading "The scav case"
  # `HideoutScavCaseProductionStart` -- the one production action whose recipes
  # are a different table with a different shape. A scav recipe names no
  # `endProduct` at all: it names a *count per rarity*, and the pool it draws
  # from is a join on the item table's own `_props.RarityPvE` against the
  # handbook. The fixture now carries both halves -- two Rare templates, one
  # Superrare, and one Common that is a priced quest item.
  #
  # Which makes the Common pool empty for exactly one reason, and that is the
  # point of it: `scavcase-common` must be refused by name, and a server that
  # let quest items into the pool would start it instead.
  #
  # Placed at the end of the run because a case puts real items in the stash,
  # and every check above that counts what is in the stash counts something
  # else.
  const ScavRare1 = "5d1b371186f774253763a656"
  const ScavRare2 = "590c657e86f77412b013051d"
  const ScavSuperrare = "5648a7494bdc2d9d488b4583"
  const ScavQuestItem = "qqqquest0000000000000001"
  if haveFixture:
    var caseDoc = profileOf(call("/client/game/profile/list", "").body, uid)
    var casePurse = roublesIn(caseDoc)
    check("the test could count the money before the first case",
          casePurse > 15000, $casePurse & " roubles")

    # A scav recipe carries no `areaType`, so there is no `Area` requirement
    # for `resolveRequirements` to find and the gate has to be made by hand.
    # Without it a profile with no hideout at all could run scav cases.
    let unbuilt = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutScavCaseProductionStart\"," &
      "\"recipeId\":\"scavcase-rare\"}],\"tm\":2}")
    check("a scav case is refused before the area is built",
          unbuilt.contains("not built yet"), unbuilt.body)
    check("and the refusal took no roubles",
          roublesIn(profileOf(call("/client/game/profile/list", "").body,
                              uid)) == casePurse,
          "a refused scav case took money")

    discard call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutUpgrade\",\"areaType\":14}],\"tm\":2}")
    let builtCase = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutUpgradeComplete\",\"areaType\":14}]," &
      "\"tm\":2}")
    check("the scav case can be built", builtCase.ok and
          not builtCase.contains("not being upgraded"), builtCase.body)

    # The refusal that proves the pool is a join and not a guess. `Common` is
    # asked for, the only Common-rarity template in the database is a quest
    # item, and a case that produced nothing because there was nothing to put
    # in it would be a theft with a shrug attached -- so it is refused by the
    # name of the rarity, before the entry fee is taken.
    let noPool = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutScavCaseProductionStart\"," &
      "\"recipeId\":\"scavcase-common\"}],\"tm\":2}")
    check("a rarity with no eligible template is refused by name",
          noPool.contains("no Common items"), noPool.body)
    caseDoc = profileOf(call("/client/game/profile/list", "").body, uid)
    let prodRecord = memberObject(memberObject(caseDoc, "Hideout"),
                                  "Production")
    check("and no quest item is waiting in a production record",
          find(prodRecord, ScavQuestItem) < 0, prodRecord)
    check("and that refusal took no roubles either",
          roublesIn(caseDoc) == casePurse,
          "a refused scav case took " & $(casePurse - roublesIn(caseDoc)) &
          " roubles")
    check("and started nothing",
          not caseDoc.contains("scavcase-common"),
          "scavcase-common is in Hideout.Production")

    let noSuchCase = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutScavCaseProductionStart\"," &
      "\"recipeId\":\"recipe-quick\"}],\"tm\":2}")
    check("a craft recipe is not a scav case",
          noSuchCase.contains("no such scav case"), noSuchCase.body)

    # -- the case that runs --------------------------------------------------
    let rare1Before = idsOfTemplate(caseDoc, ScavRare1).len
    let rare2Before = idsOfTemplate(caseDoc, ScavRare2).len
    let superBefore = idsOfTemplate(caseDoc, ScavSuperrare).len
    let started = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutScavCaseProductionStart\"," &
      "\"recipeId\":\"scavcase-rare\"}],\"tm\":2}")
    caseDoc = profileOf(call("/client/game/profile/list", "").body, uid)
    # Asserted against the record rather than against `err:0`, because every
    # refusal on this path comes back inside a `warnings` list on an otherwise
    # successful envelope: a case that was refused answers `ok` too.
    check("a scav case the player can afford starts",
          started.ok and find(caseDoc, "\"sptIsScavCase\":true") >= 0,
          started.body)
    check("and consumes exactly its entry fee",
          casePurse - roublesIn(caseDoc) == 15000,
          "the case took " & $(casePurse - roublesIn(caseDoc)) &
          " roubles, not 15000")
    casePurse = roublesIn(caseDoc)

    # **Rolled at start, and written onto the record.** Rolling at collection
    # would let a player who did not like what came out restart the server and
    # collect again, which is a re-roll for free -- and it is not visible from
    # the stash afterwards, which is why this is read off `sptScavProducts`
    # while the case is still running.
    let rolled = scavProductsOf(caseDoc, "scavcase-rare")
    check("the case rolled its rewards at the moment it started",
          rolled.len == 2, $rolled.len & " products on the record")
    var badRarity = ""
    for tpl in rolled:
      if tpl != ScavRare1 and tpl != ScavRare2:
        badRarity = tpl
    check("and every one is a Rare template -- priced, real, and not a quest item",
          badRarity.len == 0,
          "the case rolled " & badRarity &
          ", which is not one of this database's Rare templates")
    # Starting it twice. A second start would be a second entry fee for one
    # case at best and a fresh roll over the top of the first at worst.
    let twiceCase = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutScavCaseProductionStart\"," &
      "\"recipeId\":\"scavcase-rare\"}],\"tm\":2}")
    check("starting the same scav case twice is refused",
          twiceCase.contains("already running"), twiceCase.body)
    caseDoc = profileOf(call("/client/game/profile/list", "").body, uid)
    check("and took no second entry fee", roublesIn(caseDoc) == casePurse,
          "a refused second start took " & $(casePurse - roublesIn(caseDoc)) &
          " roubles")
    var sameRoll = scavProductsOf(caseDoc, "scavcase-rare").len == rolled.len
    let rolledAgain = scavProductsOf(caseDoc, "scavcase-rare")
    for k in 0 ..< rolledAgain.len:
      if k >= rolled.len or rolledAgain[k] != rolled[k]:
        sameRoll = false
    check("and did not roll the case again over the top of the first",
          sameRoll, "the record's products changed on a refused start")

    # Collecting. What lands must be exactly what was rolled -- by template and
    # by count, because two of one and none of the other is the same document
    # length as one of each.
    var wantRare1 = 0
    var wantRare2 = 0
    for tpl in rolled:
      if tpl == ScavRare1: inc wantRare1
      elif tpl == ScavRare2: inc wantRare2
    let taken = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutTakeProduction\"," &
      "\"recipeId\":\"scavcase-rare\"}],\"tm\":2}")
    check("a finished scav case can be collected",
          taken.ok and not taken.contains("not finished") and
          not taken.contains("no room"), taken.body)
    caseDoc = profileOf(call("/client/game/profile/list", "").body, uid)
    check("and what lands is exactly what was rolled at the start",
          idsOfTemplate(caseDoc, ScavRare1).len - rare1Before == wantRare1 and
          idsOfTemplate(caseDoc, ScavRare2).len - rare2Before == wantRare2,
          $(idsOfTemplate(caseDoc, ScavRare1).len - rare1Before) & " and " &
          $(idsOfTemplate(caseDoc, ScavRare2).len - rare2Before) &
          " arrived, against a roll of " & $wantRare1 & " and " & $wantRare2)
    check("and the record is cleared", not caseDoc.contains("scavcase-rare"),
          "scavcase-rare is still in Hideout.Production")
    # The band the recipe zeroed. Asserted over what *landed*, because at the
    # moment the case starts the rolled ids are on the record and a check that
    # searched the profile for them would find them there and call it a hit.
    check("and the band the recipe zeroed produced nothing",
          idsOfTemplate(caseDoc, ScavSuperrare).len == superBefore,
          $(idsOfTemplate(caseDoc, ScavSuperrare).len - superBefore) &
          " Superrare item(s) came out of a case that asked for none")

    # The one that is free items if it is wrong, and it is worth more here than
    # for an ordinary craft: a case is several distinct templates, so a record
    # that survived collection would hand out a fresh handful every time.
    let takenTwice = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutTakeProduction\"," &
      "\"recipeId\":\"scavcase-rare\"}],\"tm\":2}")
    check("collecting a scav case a second time is refused",
          takenTwice.contains("nothing is being made"), takenTwice.body)
    check("and nothing arrived for it",
          idsOfTemplate(profileOf(call("/client/game/profile/list", "").body,
                                  uid), ScavRare1).len -
          rare1Before == wantRare1,
          "a second collection paid out again")
  else:
    note "no database fixture; skipping the scav case checks"

  heading "The gym"
  # `HideoutQuickTimeEvent`. The client plays the minigame and the server is
  # told how it went in one array of booleans, so the whole design question is
  # which parts of that array a server is entitled to act on -- and every
  # answer is in `hideout.qte`, which no fixture carried until now.
  #
  # The two refusals are worth more than the payout. A `results` array longer
  # than the entry's event list is a client claiming circles that do not exist,
  # and a `false` before the end is a client claiming a session that carried on
  # after the database says it ended -- `singleFailEffect.rewardsRange[].result`
  # is `"Exit"`, which is the data's rule and not this server's invention.
  if haveFixture:
    discard call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutUpgrade\",\"areaType\":29}],\"tm\":2}")
    let builtGym = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutUpgradeComplete\",\"areaType\":29}]," &
      "\"tm\":2}")
    check("the gym can be built", builtGym.ok and
          not builtGym.contains("not being upgraded"), builtGym.body)

    let noSuchGym = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutQuickTimeEvent\",\"id\":\"no-such-gym\"," &
      "\"results\":[true],\"timestamp\":0}],\"tm\":2}")
    check("a workout on an event this database does not describe is refused",
          noSuchGym.contains("describes no quick time event"), noSuchGym.body)

    var gymList = call("/client/game/profile/list", "").body
    let energyStart = numberAt(gymList, find(gymList, "\"Energy\":{"), "Current")
    let hydrationStart = numberAt(gymList, find(gymList, "\"Hydration\":{"),
                                  "Current")
    let enduranceStart = skillOf(gymList, "Endurance")
    let strengthStart = skillOf(gymList, "Strength")
    check("the test could read the gym's starting state",
          energyStart >= 30 and hydrationStart >= 30,
          "energy " & $energyStart & ", hydration " & $hydrationStart)

    # Five events in a gym that has four.
    let tooMany = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutQuickTimeEvent\",\"id\":\"gym-bench\"," &
      "\"results\":[true,true,true,true,true],\"timestamp\":0}],\"tm\":2}")
    check("a workout claiming more events than the gym has is refused",
          tooMany.contains("this gym has only 4"), tooMany.body)
    gymList = call("/client/game/profile/list", "").body
    check("and it cost no energy and wrote no skill",
          numberAt(gymList, find(gymList, "\"Energy\":{"), "Current") ==
            energyStart and
          skillOf(gymList, "Endurance") == enduranceStart and
          skillOf(gymList, "Strength") == strengthStart,
          "energy " & $numberAt(gymList, find(gymList, "\"Energy\":{"),
                                "Current") & ", Endurance " &
          skillOf(gymList, "Endurance") & ", Strength " &
          skillOf(gymList, "Strength"))

    # A miss in the middle. The database says a miss ends the session, so
    # anything after one is a workout that did not happen.
    let carriedOn = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutQuickTimeEvent\",\"id\":\"gym-bench\"," &
      "\"results\":[true,false,true],\"timestamp\":0}],\"tm\":2}")
    check("a workout that carries on after a missed event is refused",
          carriedOn.contains("ends the session"), carriedOn.body)
    gymList = call("/client/game/profile/list", "").body
    check("and that one took nothing either",
          numberAt(gymList, find(gymList, "\"Energy\":{"), "Current") ==
            energyStart and
          skillOf(gymList, "Strength") == strengthStart,
          "energy " & $numberAt(gymList, find(gymList, "\"Energy\":{"),
                                "Current") & ", Strength " &
          skillOf(gymList, "Strength"))

    # And a workout that did. Three hits of four: two energy and two hydration
    # a hit off `singleSuccessEffect`, and no finish bonus, because three of
    # four is walking away from the bench rather than finishing.
    #
    # A match start first, and it is not a formality: the gym pays out through
    # `addSkill`, so it shares `PointsEarnedDuringSession` with the raids above
    # -- and the Skills section spent Endurance's whole session allowance on an
    # absurd claim. Without clearing it the gym would correctly grant Endurance
    # nothing, and "both skills moved" would fail against a server doing exactly
    # what it should.
    discard call("/client/match/local/start", "{\"location\":\"factory4_day\"}")
    let workout = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutQuickTimeEvent\",\"id\":\"gym-bench\"," &
      "\"results\":[true,true,true],\"timestamp\":0}],\"tm\":2}")
    check("a workout of three hits is accepted",
          workout.ok and not workout.contains("gym: that workout") and
          not workout.contains("this gym has only"), workout.body)
    gymList = call("/client/game/profile/list", "").body
    let energyAfter = numberAt(gymList, find(gymList, "\"Energy\":{"), "Current")
    let hydrationAfter = numberAt(gymList, find(gymList, "\"Hydration\":{"),
                                  "Current")
    check("and costs exactly two energy and two hydration a hit",
          energyStart - energyAfter == 6 and
          hydrationStart - hydrationAfter == 6,
          "energy went down " & $(energyStart - energyAfter) &
          " and hydration " & $(hydrationStart - hydrationAfter) & ", not 6")
    # Both skills, not one of the two: the entry's `singleSuccessEffect` names
    # Endurance and Strength with identical weights and identical multiplier
    # tables, and paying only one of them is the reading this server rejected.
    check("and pays both the skills the entry names",
          skillMoved(enduranceStart, skillOf(gymList, "Endurance")) and
          skillMoved(strengthStart, skillOf(gymList, "Strength")),
          "Endurance " & enduranceStart & " -> " &
          skillOf(gymList, "Endurance") & ", Strength " & strengthStart &
          " -> " & skillOf(gymList, "Strength"))
    # And exactly what it pays, on the skill nothing else in this run touches.
    # Three hits at the entry's level-0 multiplier of 6 is a raw claim of 18,
    # and 18 on a skill at zero is 21.5 through the fixture's own curve -- the
    # `SkillFreshEffectiveness` of 1.5 the Skills section pins, applied to the
    # gym's gains by the same `addSkill` a raid's go through. A server that
    # counted four events, or read the multiplier for the wrong level, cannot
    # land on this number.
    check("and pays exactly three hits at the multiplier the entry names",
          skillOf(gymList, "Strength") == "21.5",
          "Strength is " & skillOf(gymList, "Strength") & ", not 21.5")
    # And the penalty it cannot apply is said out loud rather than dropped:
    # `GymArmTrauma` is a name this database uses once and defines nowhere.
    let missed = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutQuickTimeEvent\",\"id\":\"gym-bench\"," &
      "\"results\":[true,true,true,false],\"timestamp\":0}],\"tm\":2}")
    check("a workout ending on a miss is accepted and says what it could not apply",
          missed.ok and missed.contains("GymArmTrauma"), missed.body)

    # The requirement that stops the gym being an infinite source of Strength.
    # Energy is driven under the entry's floor the only way a profile's energy
    # moves: through a raid.
    let spent = profileOf(call("/client/game/profile/list", "").body, uid)
    let starved = withPartHealth(spent, "Energy", 20)
    check("the test could hand back a tired profile",
          starved.len > 100 and find(starved, "\"Current\":20") >= 0,
          $starved.len & " bytes")
    discard call("/client/match/local/end",
                 "{\"results\":{\"result\":\"Survived\",\"profile\":" & starved & "}}")
    let tiredList = call("/client/game/profile/list", "").body
    let tiredEndurance = skillOf(tiredList, "Endurance")
    let tired = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutQuickTimeEvent\",\"id\":\"gym-bench\"," &
      "\"results\":[true,true],\"timestamp\":0}],\"tm\":2}")
    check("a workout is refused when energy is under what the entry asks for",
          tired.contains("needs 30 energy"), tired.body)
    check("and the refusal granted nothing",
          skillOf(call("/client/game/profile/list", "").body, "Endurance") ==
            tiredEndurance,
          "a refused workout moved Endurance")
  else:
    note "no database fixture; skipping the gym checks"

  heading "Customisation"
  # `CustomizationSet`. Every id in it is checked against
  # `templates.customization` -- which no fixture carried, so the module
  # refused every request it was ever given here and none of its rules were
  # reachable. The refusals are what matter: what a player is wearing is not
  # something the client is allowed to assert, and a half-applied outfit is a
  # player who cannot tell what took.
  const AltHead = "cust_head_alt"
  const BearHead = "5cc084dd14c02e000b0550a3"
  if haveFixture:
    var lookDoc = profileOf(call("/client/game/profile/list", "").body, uid)
    let look0 = memberObject(lookDoc, "Customization")
    check("the profile is created wearing something",
          look0.len > 0 and find(look0, "\"Head\"") >= 0, look0)

    let unknownLook = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"CustomizationSet\",\"customizations\":[" &
      "{\"id\":\"no_such_look\",\"type\":\"head\",\"source\":\"default\"}]}]," &
      "\"tm\":2}")
    check("a customisation id the database does not have is refused, by name",
          unknownLook.contains("no customisation no_such_look"),
          unknownLook.body)
    lookDoc = profileOf(call("/client/game/profile/list", "").body, uid)
    check("and what the character is wearing is byte-identical afterwards",
          memberObject(lookDoc, "Customization") == look0,
          memberObject(lookDoc, "Customization"))

    let wrongPart = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"CustomizationSet\",\"customizations\":[" &
      "{\"id\":\"cust_feet_alt\",\"type\":\"head\"}]}],\"tm\":2}")
    check("a pair of feet is refused as a head",
          wrongPart.contains("cannot go in the Head slot"), wrongPart.body)
    lookDoc = profileOf(call("/client/game/profile/list", "").body, uid)
    check("and that changed nothing either",
          memberObject(lookDoc, "Customization") == look0,
          memberObject(lookDoc, "Customization"))

    let wrongSide = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"CustomizationSet\",\"customizations\":[" &
      "{\"id\":\"" & BearHead & "\",\"type\":\"head\"}]}],\"tm\":2}")
    check("and the other faction's head on a Usec profile, naming the side",
          wrongSide.contains("not available to Usec"), wrongSide.body)
    lookDoc = profileOf(call("/client/game/profile/list", "").body, uid)
    check("and that changed nothing either, still byte for byte",
          memberObject(lookDoc, "Customization") == look0,
          memberObject(lookDoc, "Customization"))

    # One option, two writes. A suite is an indirection: the entry names the
    # Body and the Hands that go with it, and a server that wrote the suite's
    # own id into `Body` would put a suite where a body part goes.
    let suite = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"CustomizationSet\",\"customizations\":[" &
      "{\"id\":\"cust_upper_alt\",\"type\":\"suite\"}]}],\"tm\":2}")
    check("an upper suite is accepted", suite.ok and
          not suite.contains("customisation:"), suite.body)
    lookDoc = profileOf(call("/client/game/profile/list", "").body, uid)
    let look1 = memberObject(lookDoc, "Customization")
    check("and one option changed both the Body and the Hands it names",
          jsonText(look1, "Body") == "cust_body_alt" and
          jsonText(look1, "Hands") == "cust_hands_alt", look1)

    # A voice writes the entry's *name*, which is what `Info.Voice` holds and
    # what a fresh profile is created with. Writing the id would be invisible
    # against the default, whose name and id are both "Usec_1"-shaped -- which
    # is why the fixture carries a second voice whose name and id differ.
    let voice = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"CustomizationSet\",\"customizations\":[" &
      "{\"id\":\"cust_voice_usec_2\",\"type\":\"voice\"}]}],\"tm\":2}")
    check("a voice is accepted", voice.ok and
          not voice.contains("customisation:"), voice.body)
    lookDoc = profileOf(call("/client/game/profile/list", "").body, uid)
    check("and Info.Voice is the entry's name rather than its id",
          jsonText(memberObject(lookDoc, "Info"), "Voice") == "Usec_2",
          "Info.Voice is " &
          jsonText(memberObject(lookDoc, "Info"), "Voice"))

    # ---- and the same thing through its own route ------------------------
    #
    # `/client/game/profile/voice/change` used to be bound to the stock "ok"
    # stub: it answered `{"status":"ok"}` and wrote nothing, so the voice
    # selector on the character screen appeared to work and did not, and the
    # coverage document recorded the route as "served". A refusal the client
    # swallows is the failure this server is written against; a *success* the
    # server invents is the same failure from the other side, and nothing in
    # the suite could see it because the response was correct.
    #
    # Which is why the check is on the profile and not on the answer. The
    # voice asked for here is deliberately not the one the `CustomizationSet`
    # above just wrote, so a route that writes nothing leaves "Usec_2" behind
    # and is caught.
    let voiceRoute = call("/client/game/profile/voice/change",
                          "{\"voice\":\"cust_voice_usec_1\"}")
    check("the voice route answers", voiceRoute.ok and
          not voiceRoute.contains("\"err\":1"), voiceRoute.body)
    lookDoc = profileOf(call("/client/game/profile/list", "").body, uid)
    check("and it actually wrote the voice, which it used to only claim",
          jsonText(memberObject(lookDoc, "Info"), "Voice") == "Usec_1",
          "Info.Voice is " &
          jsonText(memberObject(lookDoc, "Info"), "Voice") & ", not Usec_1")

    # And it is the same gate as the item-event door, not a second one with
    # its own opinions: the other faction's voice is refused by the sentence
    # `entryAllowed` writes, and nothing is written.
    let wrongVoice = call("/client/game/profile/voice/change",
                          "{\"voice\":\"cust_voice_bear_1\"}")
    check("a voice belonging to the other faction is refused, by name",
          wrongVoice.contains("not available to Usec"), wrongVoice.body)
    let notAVoice = call("/client/game/profile/voice/change",
                         "{\"voice\":\"cust_head_alt\"}")
    check("and a customisation that is not a voice is refused as one",
          notAVoice.contains("is not a voice"), notAVoice.body)
    lookDoc = profileOf(call("/client/game/profile/list", "").body, uid)
    check("and neither refusal changed the voice the player had",
          jsonText(memberObject(lookDoc, "Info"), "Voice") == "Usec_1",
          "Info.Voice is " &
          jsonText(memberObject(lookDoc, "Info"), "Voice"))

    # All or nothing. The first option is good and would be visible; the second
    # is the other faction's. Neither may be written.
    let look2 = memberObject(lookDoc, "Customization")
    let batch = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"CustomizationSet\",\"customizations\":[" &
      "{\"id\":\"" & AltHead & "\",\"type\":\"head\"}," &
      "{\"id\":\"" & BearHead & "\",\"type\":\"head\"}]}],\"tm\":2}")
    check("a batch whose second option is wrong is refused",
          batch.contains("not available to Usec"), batch.body)
    lookDoc = profileOf(call("/client/game/profile/list", "").body, uid)
    check("and the first option, which was fine, was not written either",
          memberObject(lookDoc, "Customization") == look2 and
          find(memberObject(lookDoc, "Customization"), AltHead) < 0,
          memberObject(lookDoc, "Customization"))
  else:
    note "no database fixture; skipping the customisation checks"

  heading "The hideout's wardrobe"
  # Floors, walls, ceilings, shooting-range targets, mannequin poses and the
  # range's score. All six landed on the strength of a load-time self-check
  # against literal tables, and none of them had ever been over the wire --
  # because no fixture carried a `hideout.customisation` block, a `Floor` node
  # or a `MannequinPose` node. It does now, and every check below is a request
  # the client sends.
  #
  # The order is the point. The score and the area-gated offer are both asked
  # for *before* area 12 is built and again after it reaches level 3, so the
  # refusals are real refusals rather than an area that happened to be missing.
  if haveFixture:
    # The list the screen is drawn from. It answered `[]` until the table was
    # read -- and `[]` is not merely empty, it is the wrong *kind*: the
    # reference DTO is an object of `globals` and `slots`, and a client handed
    # an array indexes a null. So the assertion is the shape and not the count.
    let offers = call("/client/hideout/customization/offer/list", "")
    check("the customisation offer list answers an object, not an array",
          offers.ok and offers.contains("\"data\":{") and
          not offers.contains("\"data\":[]"), offers.body)
    # Both keys, without asserting what follows the colon: this route sends the
    # database's own text back verbatim, so the whitespace in it is the
    # fixture's and not the server's. What the shape check above is for is the
    # object-versus-array question, and the ids below are what say the lists
    # are not empty.
    check("and it carries both of the lists the screen draws",
          offers.contains("\"globals\"") and offers.contains("\"slots\""),
          offers.body)
    # By `systemName` and **not** by offer id, and that is not a style choice.
    # This route sends the database's own text back verbatim, `_comment`
    # members and all -- and the fixture's comment on this block explains what
    # each entry is *by naming its id*. A check written against the ids passed
    # against a table whose `slots` list had been emptied to nothing, because
    # the id it was looking for was still there in the prose. Found by breaking
    # the fixture on purpose and watching this check stay green.
    check("with the fixture's own offers in it",
          offers.contains("Floor_Plain") and
          offers.contains("Target_Level3") and
          offers.contains("Poster_1"), offers.body)

    # -- before there is a shooting range ------------------------------------
    #
    # Area 12 is at level zero on a profile this run created, and both of these
    # have to be refused for it. Asked first, so that the acceptances further
    # down are the *change* and not a state that was always true.
    let noRange = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutRecordShootingRangePoints\"," &
      "\"points\":250}],\"tm\":2}")
    check("a shooting-range score is refused when there is no range",
          noRange.contains("no shooting range in your hideout"), noRange.body)

    let gatedEarly = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutCustomizationApplyCommand\"," &
      "\"offerId\":\"hc_mark\"}],\"tm\":2}")
    # The refusal names the area and the level it wants, both read off the
    # offer's own `HideoutArea` condition in the fixture. This is the one check
    # in the file that says conditions are evaluated out of the table rather
    # than compiled into the server: nothing here is spelled anywhere in the
    # mod.
    check("an offer gated on a hideout area is refused before it is built",
          gatedEarly.contains("hideout area 12") and
          gatedEarly.contains("3"), gatedEarly.body)

    # -- the unconditional offer ---------------------------------------------
    var decorDoc = profileOf(call("/client/game/profile/list", "").body, uid)
    let hideout0 = memberObject(decorDoc, "Hideout")
    check("a fresh profile's hideout is decorated with nothing",
          memberObject(hideout0, "Customization") == "{}",
          memberObject(hideout0, "Customization"))

    let laid = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutCustomizationApplyCommand\"," &
      "\"offerId\":\"hc_floor\"}],\"tm\":2}")
    check("an unconditional floor is accepted",
          laid.ok and not laid.contains("hideout customisation:"), laid.body)
    decorDoc = profileOf(call("/client/game/profile/list", "").body, uid)
    let decor1 = memberObject(memberObject(decorDoc, "Hideout"),
                              "Customization")
    # The key is asserted, not just the value. `Hideout.Customization` is a
    # `Dictionary<String, MongoId>` in the reference -- nothing declares what
    # to call the floor -- so the server derives it: the offer's `itemId`, the
    # entry that id names in `templates.customization`, that entry's `_parent`,
    # and *that* node's `_name`. Four hops, and the word `Floor` appears
    # nowhere in the offer. A check on the value alone would pass against a
    # server that wrote it under the offer's id, under its `type`, or under
    # anything else it liked.
    check("and it is written under the key the table derives, Floor",
          jsonText(decor1, "Floor") == "cust_floor_plain", decor1)

    # -- what must not be applied --------------------------------------------
    let noSuchOffer = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutCustomizationApplyCommand\"," &
      "\"offerId\":\"no_such_offer\"}],\"tm\":2}")
    check("an offer id the table does not have is refused, by name",
          noSuchOffer.contains("no_such_offer"), noSuchOffer.body)

    # A slot is a *place*, not a thing: the 47 real ones carry no `itemId` at
    # all, so the only way to answer is to choose a poster, and choosing one is
    # inventing content. The refusal has to say "slot", because "there is no
    # such offer" would send the player looking for a typo in an id that is
    # perfectly real.
    let slotApply = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutCustomizationApplyCommand\"," &
      "\"offerId\":\"hc_poster\"}],\"tm\":2}")
    check("a hideout slot is refused as a decoration, and says \"slot\"",
          slotApply.contains("slot"), slotApply.body)
    decorDoc = profileOf(call("/client/game/profile/list", "").body, uid)
    check("and none of the three refusals wrote anything",
          memberObject(memberObject(decorDoc, "Hideout"), "Customization") ==
          decor1,
          memberObject(memberObject(decorDoc, "Hideout"), "Customization"))

    # -- mannequin poses -----------------------------------------------------
    #
    # Two mannequins, two different poses, one request. Two *different* poses
    # on purpose: one id used twice would pass against a server that wrote the
    # last one it read into every slot.
    let posed = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutCustomizationSetMannequinPose\"," &
      "\"poses\":{\"mannequin_1\":\"cust_pose_standing\"," &
      "\"mannequin_2\":\"cust_pose_leaning\"}}],\"tm\":2}")
    check("two mannequin poses in one request are accepted",
          posed.ok and not posed.contains("mannequin pose:"), posed.body)
    decorDoc = profileOf(call("/client/game/profile/list", "").body, uid)
    let poses1 = memberObject(memberObject(decorDoc, "Hideout"),
                              "MannequinPoses")
    check("and both of them were written, each under its own mannequin",
          jsonText(poses1, "mannequin_1") == "cust_pose_standing" and
          jsonText(poses1, "mannequin_2") == "cust_pose_leaning", poses1)

    # All or nothing. The first pose is good and would be visible; the second
    # is a head, which is in the table and is not a pose. A half-posed row of
    # mannequins is a player who cannot tell what took.
    let mixedPose = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutCustomizationSetMannequinPose\"," &
      "\"poses\":{\"mannequin_3\":\"cust_pose_leaning\"," &
      "\"mannequin_4\":\"cust_head_alt\"}}],\"tm\":2}")
    check("a pose request naming a head is refused, saying it is not a pose",
          mixedPose.contains("not a mannequin pose"), mixedPose.body)
    decorDoc = profileOf(call("/client/game/profile/list", "").body, uid)
    check("and the good pose beside it was not written either",
          memberObject(memberObject(decorDoc, "Hideout"), "MannequinPoses") ==
          poses1,
          memberObject(memberObject(decorDoc, "Hideout"), "MannequinPoses"))

    # -- building the range --------------------------------------------------
    #
    # Three upgrades, because the offer's condition asks for level 3. The
    # fixture's area 12 is instant and free for exactly this reason: what is
    # being measured here is the condition, not the construction clock.
    #
    # The level reached is what is asserted, not that the six requests came
    # back. Every one of them answers `err:0` whether it was applied or refused
    # -- a refusal is a `warnings` entry inside a successful envelope -- so a
    # check on the response alone passes against an area that never moved.
    var refused = ""
    var lvl = 0
    while lvl < 3:
      let up = call("/client/game/profile/items/moving",
        "{\"data\":[{\"Action\":\"HideoutUpgrade\",\"areaType\":12}],\"tm\":2}")
      if up.contains("upgrade:") and refused.len == 0:
        refused = up.body
      let done = call("/client/game/profile/items/moving",
        "{\"data\":[{\"Action\":\"HideoutUpgradeComplete\"," &
        "\"areaType\":12}],\"tm\":2}")
      if done.contains("not being upgraded") and refused.len == 0:
        refused = done.body
      inc lvl
    let rangeHideout = memberObject(
      profileOf(call("/client/game/profile/list", "").body, uid), "Hideout")
    check("the shooting range really is at level 3",
          numberAt(rangeHideout, find(rangeHideout, "\"type\":12"),
                   "level") == 3,
          "area 12 is at level " &
          $numberAt(rangeHideout, find(rangeHideout, "\"type\":12"), "level") &
          (if refused.len > 0: "; first refusal: " & refused else: ""))

    # -- and the same two requests again -------------------------------------
    let gatedLate = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutCustomizationApplyCommand\"," &
      "\"offerId\":\"hc_mark\"}],\"tm\":2}")
    check("the same gated offer is accepted once the area is at level 3",
          gatedLate.ok and not gatedLate.contains("hideout customisation:"),
          gatedLate.body)
    decorDoc = profileOf(call("/client/game/profile/list", "").body, uid)
    let decor2 = memberObject(memberObject(decorDoc, "Hideout"),
                              "Customization")
    check("and it lands under its own derived key, beside the floor",
          jsonText(decor2, "ShootingRangeMark") == "cust_mark_target" and
          jsonText(decor2, "Floor") == "cust_floor_plain", decor2)

    let scored = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutRecordShootingRangePoints\"," &
      "\"points\":250}],\"tm\":2}")
    check("and a score is recorded once there is a range to score on",
          scored.ok and not scored.contains("shooting range:"), scored.body)
    decorDoc = profileOf(call("/client/game/profile/list", "").body, uid)
    check("with the number the client reported",
          numberAt(memberObject(decorDoc, "OverallCounters"),
                   find(memberObject(decorDoc, "OverallCounters"),
                        "ShootingRangePoints"), "Value") == 250,
          memberObject(decorDoc, "OverallCounters"))

    # The upsert, which is the half worth pinning. A counter appended rather
    # than replaced grows by one entry every time the player finishes a round,
    # and the client reads the *first* one it finds -- so the board freezes on
    # the first score ever recorded and the profile grows forever. Both the
    # count and the value are asserted: either alone misses one of the two
    # ways this goes wrong.
    let scoredAgain = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutRecordShootingRangePoints\"," &
      "\"points\":410}],\"tm\":2}")
    check("a second score is accepted too", scoredAgain.ok, scoredAgain.body)
    decorDoc = profileOf(call("/client/game/profile/list", "").body, uid)
    let counters = memberObject(decorDoc, "OverallCounters")
    check("and two rounds leave exactly one counter, not two",
          countOf(counters, "ShootingRangePoints") == 1,
          $countOf(counters, "ShootingRangePoints") &
          " ShootingRangePoints entries in " & counters)
    check("carrying the score from the second round",
          numberAt(counters, find(counters, "ShootingRangePoints"),
                   "Value") == 410, counters)

    # A negative score is the client asserting something no range can produce.
    let negative = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutRecordShootingRangePoints\"," &
      "\"points\":-5}],\"tm\":2}")
    check("a negative score is refused",
          negative.contains("is not a score this server will record"),
          negative.body)
    let stillCounters = memberObject(
      profileOf(call("/client/game/profile/list", "").body, uid),
      "OverallCounters")
    check("and it did not overwrite the score that was there",
          numberAt(stillCounters, find(stillCounters, "ShootingRangePoints"),
                   "Value") == 410, stillCounters)
  else:
    note "no database fixture; skipping the hideout wardrobe checks"

  # -- the part that only a restart can prove -------------------------------

  heading "A profile made before the game starts"

  # What a launcher does: create a character over HTTP with no client running,
  # and keep the token it is handed. Placed last of the sections that run
  # against the first server, so that the second profile it adds cannot change
  # what any earlier check reads out of a profile list.
  #
  # The voice in this body is a *Usec* voice on a Bear character, and it is
  # wrong on purpose. A launcher offers a voice picker, the table decides which
  # voices a side may have, and the question is what a server does when those
  # two disagree at the moment a character is being made: refusing the whole
  # profile would leave a person unable to create one at all, so the voice is
  # dropped and the side's default kept. The character below must exist and
  # must speak as `Bear_1`.
  let madeBody = call("/aowlspt/tarkov/launcher/profile/create",
                      "{\"nickname\":\"AowlLauncher\",\"side\":\"Bear\"," &
                      "\"voice\":\"cust_voice_usec_2\"}").body
  check("the launcher created a profile", find(madeBody, "\"ok\":true") >= 0,
        madeBody)
  let token = jsonText(madeBody, "token")
  check("and handed back a MongoId to put on the command line",
        token.len == 24, token)
  check("which is the profile's own id and not a third thing to keep in step",
        token.len == 24 and find(madeBody, "\"id\":\"" & token & "\"") >= 0,
        madeBody)
  check("the side the launcher asked for is the side the character got",
        find(madeBody, "\"side\":\"Bear\"") >= 0, madeBody)
  check("a voice the table will not give that side costs the voice, not the " &
        "profile",
        find(madeBody, "\"voice\":\"Bear_1\"") >= 0, madeBody)
  let taken = call("/aowlspt/tarkov/launcher/profile/create",
                   "{\"nickname\":\"AowlTest\",\"side\":\"Usec\"}")
  check("a nickname the client already took is refused to the launcher too",
        taken.ok and taken.contains("\"ok\":false"), taken.body)
  let listed = call("/aowlspt/tarkov/launcher/profiles", "")
  check("both characters are on the launcher's list",
        listed.contains("AowlLauncher") and listed.contains("AowlTest"),
        listed.body)
  # The other half, and the one that matters: a profile the launcher made has
  # to be a profile the *game* can see, not a second kind of record beside it.
  discard expectIn("and the game sees the launcher's character as a profile",
                   "/client/game/profile/list", "", "AowlLauncher")
  let reselect = call("/aowlspt/tarkov/launcher/profile/select",
                      "{\"id\":\"" & token & "\"}")
  check("selecting it again hands back the same token",
        reselect.ok and reselect.contains("\"ok\":true") and
        reselect.contains("\"token\":\"" & token & "\""), reselect.body)

  heading "Across a restart"

  # The last thing this server is told before it is switched off: the client is
  # playing in `xx`. There is no `locales.global.xx` in this database and there
  # never will be, which is the point -- the insurance returns are composed
  # *after* the restart, with nobody logged in, against whatever language the
  # profile last asked for. So every trader line delivered below goes through
  # the English fallback, and a fallback that answered nothing would leave
  # three empty messages in the inbox rather than an error anywhere.
  #
  # It is also the check that the language is remembered against the *profile*
  # and not against the session: this session does not survive the restart and
  # the sweep that delivers has no session at all.
  let oddLocale = call("/client/locale/xx", "")
  check("a locale this database does not have still answers",
        oddLocale.ok and oddLocale.contains("\"err\":0"), oddLocale.body)

  cSpawnKill(proc1)
  cSleepMs(400'i32)

  # The second server comes back up two days later. `epochBase` is what the
  # emulator adds its uptime to, so moving it forward is the only clock this
  # test has -- and it is the clock that matters, because three of the things
  # that must survive a restart are things that come *due* while the server is
  # off: a craft finishes, a flea offer expires, and an insurance return
  # matures. Watching any of them otherwise means a test that waits an hour,
  # and an hour is a test nobody runs.
  #
  # Two days rather than one, and the margin is the point. The insurance return
  # is due `insuranceReturnHours` -- 24 -- after the raid that lost the item,
  # and the raid happens *late* in a run whose uptime counts towards that
  # deadline, so a jump of exactly 24 hours lands within seconds of it and the
  # check passes or fails on how fast the machine is. It must also stay under
  # `mailKeepHours` (72), or the quest message the mail checks look for is
  # pruned before they get to it. 48 hours is comfortably inside both.
  #
  # It is still the same restart and the same store: what is on disk is
  # untouched, and everything the section already proves about it still holds.
  let configPath = root & "\\mods\\tarkov\\config.json"
  var configText = ""
  var movedClock = false
  #
  # `fleaMaxOffers` goes with it, down to two, and that is not a timing trick:
  # it is how the cap can be made to *bind* on a fixture small enough that it
  # otherwise never does. A cap that binds is the only way to ask the question
  # the real database answered badly -- can a search still find a template the
  # built pool has no row for -- and the answer has to be yes, because a cap on
  # the pool applied before the filter is a cap on the search.
  var cappedMarket = false
  if readTextFile(configPath, configText):
    var changed = retimed(configText, "epochBase", 1700172800)
    if changed.len > 0:
      let capped = retimed(changed, "fleaMaxOffers", 2)
      if capped.len > 0:
        changed = capped
        cappedMarket = true
    if changed.len > 0 and writeTextFile(configPath, changed).ok:
      movedClock = true
    else:
      cappedMarket = false
  if not movedClock:
    note "could not move epochBase in " & configPath &
         "; the checks that need a day to pass will be skipped"

  var proc2 = startBackend(backend, root)
  if proc2 == 0'u64:
    err "could not restart the backend"
    return 1
  if not waitForBackend(60):
    err "the backend did not come back up"
    cSpawnKill(proc2)
    return 1
  ok "restarted"

  # The token was minted by a server that no longer exists. Nothing re-selects
  # anything here and no launcher is run again -- which is the whole point: a
  # token that had to be re-issued after every backend restart would be a token
  # nobody could put on a shortcut.
  check("the launcher's character survived the restart",
        call("/aowlspt/tarkov/launcher/profiles", "")
          .contains("AowlLauncher"), "AowlLauncher is gone")
  let asToken = callAs(token, "/client/game/config", "")
  check("and the token still names it to a client that has selected nothing",
        asToken.ok and
        asToken.contains("\"activeProfileId\":\"" & token & "\""),
        asToken.body)
  let pingAfter = call("/aowlspt/tarkov/launcher/ping", "")
  check("and the launcher counts both characters on the second server",
        pingAfter.contains("\"profiles\":2"), pingAfter.body)
  let listAs = callAs(token, "/client/game/profile/list", "")
  check("and its profile list answers with that character",
        listAs.ok and listAs.contains("AowlLauncher"), listAs.body)

  # The same question of the second server. It loaded a config this run rewrote
  # and a store this run filled, and a self-check that held on the first boot
  # and not on the second is a fault in exactly one of those two.
  let selfcheck2 = call("/aowlspt/tarkov/selfcheck", "")
  check("and its arithmetic still holds after the restart",
        selfcheck2.ok and selfcheck2.contains("\"ok\":true") and
        selfcheck2.contains("\"failures\":[]"), selfcheck2.body)

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
    # And the other half of "time is derived, not counted": the hour the craft
    # needed passed while the server was switched off, so it is finished --
    # exactly once, however long it was off for. A server that ticked a counter
    # while it was running would come back with this craft still an hour from
    # done; one that counted elapsed time as output would hand over two days'
    # worth.
    let matured = call("/client/game/profile/items/moving",
      "{\"data\":[{\"Action\":\"HideoutTakeProduction\"," &
      "\"recipeId\":\"recipe-slow\"}],\"tm\":2}")
    if movedClock:
      check("and the hour it needed passed while the server was off",
            matured.ok and matured.contains("5448ff904bdc2d6f028b456e"),
            matured.body)
      let onceOnly = call("/client/game/profile/items/moving",
        "{\"data\":[{\"Action\":\"HideoutTakeProduction\"," &
        "\"recipeId\":\"recipe-slow\"}],\"tm\":2}")
      check("and two days of downtime are still worth one craft",
            onceOnly.contains("nothing is being made"), onceOnly.body)
    else:
      check("and it is still not finished",
            matured.contains("not finished"), matured.body)

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

  # The offer listed before the restart, priced far above what this market
  # pays so that it could only ever expire rather than sell. A day has passed,
  # so it is due -- and it comes back by post rather than being dropped,
  # because the post is the only way to give a player items when there is
  # nobody logged in to receive a diff.
  #
  # Settling happens at login as well as on a timer, for the same reason
  # insurance returns do: a server that was off when an offer came due must
  # still settle it, and a timer alone never does.
  if movedClock and haveFixture:
    discard call("/client/game/profile/select", "{\"uid\":\"" & uid & "\"}")
    let inbox = call("/client/mail/dialog/list", "")
    check("an expired offer comes back by mail",
          inbox.contains("expired"), inbox.body)
    check("with the item that was in it",
          inbox.contains("57ac965c24597706be5f975c"),
          "the message carries no items")

  # The cap is on the *pool*, and the search must not inherit it.
  #
  # With `fleaMaxOffers` at two, the built market is one trader row and one
  # generated one -- everything else the fixture prices and stocks is outside
  # it. A player searching for one of those by id is the client's "offers for
  # this item" button, and answering it out of a list that was truncated before
  # the filter ran tells the player nobody sells an item two traders do.
  if cappedMarket and haveFixture:
    let capped = call("/client/ragfair/find",
                      "{\"page\":0,\"limit\":50,\"offerOwnerType\":1}")
    check("the offer cap really does bound the built market",
          jsonNumber(capped.body, "offersCount") == 1,
          $jsonNumber(capped.body, "offersCount") & " trader offers at a cap of 2")
    # The second trader's only item, which one round of the round-robin at a cap
    # of two cannot have reached.
    let hunted = offersOf(call("/client/ragfair/find",
      "{\"page\":0,\"limit\":5,\"handbookId\":\"5648a7494bdc2d9d488b4583\"}").body)
    check("and a search still finds a trader offer outside it",
          find(hunted, "\"_tpl\":\"5648a7494bdc2d9d488b4583\"") >= 0 and
          find(hunted, "\"memberType\":4") >= 0, hunted)
    let hunted2 = offersOf(call("/client/ragfair/find",
      "{\"page\":0,\"limit\":5,\"handbookId\":\"5710c24ad2720bc3458b45a3\"}").body)
    check("and a generated offer for a template outside it too",
          find(hunted2, "\"_tpl\":\"5710c24ad2720bc3458b45a3\"") >= 0 and
          find(hunted2, "\"memberType\":0") >= 0, hunted2)

  # Turnover with a trader is state the same way a craft is, and the loyalty
  # level derived from it has to be re-derived off the stored number rather
  # than remembered from the session that earned it. The figure is exact and
  # this run built it: every purchase and sale above added to `expectedSales`.
  if haveFixture:
    let afterRestart = profileOf(call("/client/game/profile/list", "").body, uid)
    let prapor2 = traderEntry(afterRestart, "54cb50c76803fa8b248b4571")
    check("the trader's turnover survived the restart",
          jsonNumber(prapor2, "salesSum") == expectedSales,
          "salesSum is " & $jsonNumber(prapor2, "salesSum") & ", not " &
          $expectedSales)
    check("and so did the loyalty level it earns",
          jsonNumber(prapor2, "loyaltyLevel") == 2,
          "loyaltyLevel is " & $jsonNumber(prapor2, "loyaltyLevel"))

  # Builds are kept beside the profile rather than in it, precisely so that a
  # raid handing back the client's copy of the profile cannot overwrite them --
  # and one raid did hand back a copy, in the insurance section above.
  let survivingBuilds = call("/client/builds/list", "")
  check("the saved build survived the restart",
        survivingBuilds.contains("Raid kit"), survivingBuilds.body)
  check("and the build the run deleted did not come back",
        not survivingBuilds.contains("Dear AK"), survivingBuilds.body)

  # The insured kits lost in the raid above. A day has passed, which is exactly
  # `insuranceReturnHours`, so the traders post them back -- by mail, because
  # there was nobody logged in to hand a diff to when they came due.
  #
  # Three kits, three insuring traders, three different sentences, and each one
  # is a different question about `emu/dialogue`.
  if movedClock and haveFixture and insuredId.len > 0:
    discard call("/client/game/profile/select", "{\"uid\":\"" & uid & "\"}")
    let post = call("/client/mail/dialog/list", "")
    check("the insured kits came back once the cover matured",
          post.contains("544fb45d4bdc2dee738b4568"),
          "no return message carries a kit")

    # Prapor: his own words, in his own dialog, with the map named. Either of
    # his two `insuranceFound` lines is a correct answer -- the pick is a
    # function of a profile id this run did not choose -- so what is asserted
    # is what both have in common and what neither may contain. `recovered` is
    # named explicitly: it is the wording this server used for *everybody*
    # before it read the table, and a trader with lines who still sends it is
    # the regression this check exists for.
    let prapPost = call("/client/mail/dialog/view",
      "{\"dialogId\":\"54cb50c76803fa8b248b4571\"}")
    check("the first trader's return is his own line and not the old literal",
          prapPost.contains("Prapor here.") and
          not prapPost.contains("recovered") and
          (prapPost.contains("dug your gear out of") or
           prapPost.contains("things back off")), prapPost.body)
    check("and it still names the map, and still fills every placeholder",
          prapPost.contains("Customs") and
          not prapPost.contains("{location}") and
          not prapPost.contains("{date}") and
          not prapPost.contains("{time}"), prapPost.body)

    # The same dialog read twice, byte for byte. The line is picked from a seed
    # composed of the profile, the trader, the situation and the second the
    # raid ended -- every part of it in the store -- so a delivery that failed
    # to save and was retried has to compose the same sentence rather than a
    # new one. A message that changed between two reads is a message the player
    # watched rewrite itself.
    let prapAgain = call("/client/mail/dialog/view",
      "{\"dialogId\":\"54cb50c76803fa8b248b4571\"}")
    check("and reading the dialog again gives byte-identical text",
          prapAgain.body == prapPost.body, "the dialog changed between reads")

    # The Therapist: one exact sentence, and the two candidates ahead of it are
    # unusable on every run -- one has no locale entry and one carries a
    # placeholder this server has no value for. So this is the rotation, and it
    # is asserted as an equality rather than as a set.
    let therPost = call("/client/mail/dialog/view",
      "{\"dialogId\":\"54cb57776803fa99248b456e\"}")
    check("the second trader's return rotates past both unusable lines",
          therPost.contains(
            "Therapist speaking. Your things are back. " &
            "Do take better care of them.") and
          not therPost.contains("{nickname}") and
          not therPost.contains("fetched back off"), therPost.body)
    check("and it arrived in her dialog rather than in the first trader's",
          therPost.contains("544fb45d4bdc2dee738b4568") and
          not prapPost.contains("Therapist speaking."), therPost.body)

    # And Fence, who the database gives no `dialogue` at all: the plain
    # wording, unchanged. This is the fallback the whole module is built around
    # -- an empty message and a message reading "lost somewhere on {location}"
    # are both worse than a sentence a player can read -- and it is the one
    # place the old literal is still the right answer.
    let fencePost = call("/client/mail/dialog/view",
      "{\"dialogId\":\"579dc571d53a0658a154fbec\"}")
    check("a trader with no dialogue still sends the plain wording",
          fencePost.contains("Your insured gear was recovered."),
          fencePost.body)

    # The language. `/client/locale/xx` was asked for before the restart and
    # this database has no `locales.global.xx`, so every line above resolved
    # through the English fallback -- which is what the three checks that just
    # passed were reading. Asserted here so that a fallback that answered an
    # empty string, and a server that stored the locale id instead of the text,
    # are both visible: either would have left the messages above blank.
    check("a language this database has never heard of still delivers text",
          prapPost.contains("Prapor here.") and
          therPost.contains("Therapist speaking."),
          "a message came through empty in an unknown language")

    # Once. A return delivered and left in the queue is a kit the player gets
    # again every time the sweep runs. Counted on the trader's own sentence,
    # which is the only string that appears exactly once per return.
    discard call("/client/game/profile/select", "{\"uid\":\"" & uid & "\"}")
    let prapPost2 = call("/client/mail/dialog/view",
      "{\"dialogId\":\"54cb50c76803fa8b248b4571\"}")
    check("and only once",
          countOf(prapPost.body, "Prapor here.") == 2 and
          countOf(prapPost2.body, "Prapor here.") == 2,
          $countOf(prapPost.body, "Prapor here.") & " became " &
          $countOf(prapPost2.body, "Prapor here.") &
          ", and two is right: one start and one return")

  # =========================================================================
  heading "Kills credited from the raid's own victim list"
  # =========================================================================
  #
  # `questcond.killCredit` is the fallback for a kill counter the client did
  # not report, and it used to refuse a `Kills` condition whenever a
  # `distance`, `daytime`, `weapon` or equipment key was *present* -- which a
  # real `templates.quests` writes on almost every one of them with a neutral
  # value. `q_ratrun` in the fixture is that exact shape: eleven qualifier keys,
  # all of them empty or neutral. `q_marksman` restricts range for real, and
  # `q_nightowl` restricts time of day, which is the one this server still
  # cannot check.
  #
  # The victims go into the profile the client hands back, in the member the
  # client puts them in -- `Stats.Eft.Victims` -- rather than into a body this
  # test invented, because the whole claim is about the document the client
  # sends.
  if haveFixture:
    let killQuests = @["q_ratrun", "q_marksman", "q_nightowl"]
    for qid in killQuests:
      let taken = call("/client/game/profile/items/moving",
        "{\"data\":[{\"Action\":\"QuestAccept\",\"qid\":\"" & qid &
        "\"}],\"tm\":2}")
      check("the kill quest " & qid & " can be accepted",
            taken.ok and not taken.contains("cannot accept"), taken.body)

    discard call("/client/match/local/start", "{\"location\":\"bigmap\"}")
    let preRaid = call("/client/game/profile/list", "").body
    # Two scavs: one at 142 m, one at 11 m. Both count for the neutral
    # condition, only the first for the 100 m one, and neither for the
    # night-only one.
    let played = withVictims(raidProfile(preRaid, uid),
      "[{\"Side\":\"Savage\",\"Role\":\"assault\",\"BodyPart\":\"Head\"," &
      "\"Distance\":142.5,\"Location\":\"bigmap\",\"Time\":\"22:14:03\"}," &
      "{\"Side\":\"Savage\",\"Role\":\"assault\",\"BodyPart\":\"Chest\"," &
      "\"Distance\":11.25,\"Location\":\"bigmap\",\"Time\":\"22:15:40\"}]")
    check("the test could put victims in the profile the client hands back",
          countOf(played, "\"Distance\":") == 2, "victims not injected")
    let back = call("/client/match/local/end",
      "{\"location\":\"bigmap\",\"results\":{\"result\":\"Survived\",\"profile\":" &
      played & "}}")
    check("the raid with two scav kills in it is accepted", back.ok, back.body)

    let afterKills = call("/client/game/profile/list", "")
    let counters = afterKills.body
    # The counter, not the quest state: `advanceQuestsAfterRaid` writes the
    # count and then re-reads the group, so a check on the count is a check on
    # exactly the thing `killCredit` returned.
    let ratAt = find(counters, "\"c_ratrun\"")
    check("a kill condition whose distance and daytime keys are neutral is credited",
          ratAt >= 0 and numberAt(counters, ratAt, "value") == 2,
          "c_ratrun counter is " & $numberAt(counters, ratAt, "value") &
          ", not 2")
    let markAt = find(counters, "\"c_marksman\"")
    check("and a real range is checked against the victim's own Distance",
          markAt >= 0 and numberAt(counters, markAt, "value") == 1,
          "c_marksman counter is " & $numberAt(counters, markAt, "value") &
          ", not 1 -- only the 142 m kill is over 100 m")
    check("but a night-only condition is refused rather than guessed at",
          find(counters, "\"c_nightowl\"") < 0,
          "c_nightowl was credited from a report with no raid clock in it")

    # And the quests the counters belong to moved with them.
    check("the quest whose counter was met is ready to hand in",
          questStatus(counters, uid, "q_ratrun") == "AvailableForFinish",
          "q_ratrun is " & questStatus(counters, uid, "q_ratrun"))
    check("and the one that could not be checked is still started",
          questStatus(counters, uid, "q_nightowl") == "Started",
          "q_nightowl is " & questStatus(counters, uid, "q_nightowl"))

    # ---- the night-only condition, once the raid says what time it is -----
    #
    # The raid above went through `/client/match/local/start` with no
    # configuration behind it, so the server knew nothing about the clock and
    # `daytime` was refused. That is still the right answer and the check above
    # is still the one that says so.
    #
    # What was wrong was the *reason*: the refusal read `Victim.Time` and
    # distrusted it, and `Victim.Time` was never the input.
    # `RaidSettings.TimeAndWeatherSettings` carries `HourOfDay` and
    # `TimeFlowType`, the client posts them to `/client/raid/configuration`,
    # and this server parsed that body for the raid id and threw the rest away.
    # `WeatherHelper.IsNightTime(timeVariant, mapLocation)` in the reference
    # dump is the proof of method: the game decides night from what was
    # selected and which map, never from a victim's clock.
    #
    # `q_nightowl`'s window is 22 -> 10, twelve hours wide. Customs is 40
    # minutes of `EscapeTimeLimit`. The two raids below start at the **same
    # hour** and differ only in how fast the clock runs, which is the whole of
    # the arithmetic: an hour alone cannot answer this question and a span can.
    #
    #   09:00 at x8  ->  09:00..14:20, and the window closes at 10 -- straddled
    #   09:00 at x0  ->  09:00 flat, one hour inside the window -- credited
    #
    # The first raid sends no `timeFlowType` at all, which is the other claim:
    # a client that does not say gets the **ceiling** of the `TimeFlowType`
    # enum, x8, because a span that is too short is a kill credited that was
    # not earned. Read at x1 the same raid would span 09:00..09:40 and be
    # credited, so this check is what says the default is a ceiling and not a
    # guess.
    discard call("/client/raid/configuration",
      "{\"location\":\"bigmap\",\"timeVariant\":\"CURR\"," &
      "\"timeAndWeatherSettings\":{\"hourOfDay\":9}}")
    discard call("/client/match/local/start", "{\"location\":\"bigmap\"}")
    let dayPre1 = call("/client/game/profile/list", "").body
    let dayPlayed1 = withVictims(raidProfile(dayPre1, uid),
      "[{\"Side\":\"Savage\",\"Role\":\"assault\",\"BodyPart\":\"Head\"," &
      "\"Distance\":40.0,\"Location\":\"bigmap\"}]")
    discard call("/client/match/local/end",
      "{\"location\":\"bigmap\",\"results\":{\"result\":\"Survived\",\"profile\":" &
      dayPlayed1 & "}}")
    let dayAfter1 = call("/client/game/profile/list", "").body
    check("a raid that runs out of the window before it ends is still refused",
          find(dayAfter1, "\"c_nightowl\"") < 0,
          "c_nightowl was credited for a raid starting at 09:00 whose clock " &
          "reaches 14:20")

    # Same hour, and now the client says the clock does not move at all.
    discard call("/client/raid/configuration",
      "{\"location\":\"bigmap\",\"timeVariant\":\"CURR\"," &
      "\"timeAndWeatherSettings\":{\"hourOfDay\":9,\"timeFlowType\":\"x0\"}}")
    discard call("/client/match/local/start", "{\"location\":\"bigmap\"}")
    let dayPre2 = call("/client/game/profile/list", "").body
    let dayPlayed2 = withVictims(raidProfile(dayPre2, uid),
      "[{\"Side\":\"Savage\",\"Role\":\"assault\",\"BodyPart\":\"Head\"," &
      "\"Distance\":40.0,\"Location\":\"bigmap\"}]")
    discard call("/client/match/local/end",
      "{\"location\":\"bigmap\",\"results\":{\"result\":\"Survived\",\"profile\":" &
      dayPlayed2 & "}}")
    let dayAfter2 = call("/client/game/profile/list", "").body
    let nightAt = find(dayAfter2, "\"c_nightowl\"")
    check("but one whose whole span is inside the window is credited",
          nightAt >= 0 and numberAt(dayAfter2, nightAt, "value") == 1,
          "c_nightowl counter is " & $numberAt(dayAfter2, nightAt, "value") &
          ", not 1 -- the raid ran 09:00 to 09:00 inside a 22->10 window")
    check("and the night-only quest is ready to hand in",
          questStatus(dayAfter2, uid, "q_nightowl") == "AvailableForFinish",
          "q_nightowl is " & questStatus(dayAfter2, uid, "q_nightowl"))

  # =========================================================================
  heading "The inbox: read, pinned and removed"
  # =========================================================================
  #
  # All four of `read`, `pin`, `unpin` and `remove` were bound to the stock
  # `onNullData` stub, so the client's request was answered `null` and nothing
  # happened -- and `dialogList` hard-coded `"pinned": false` and `"new": 0`,
  # so there was nothing for them to change either. Every check below reads the
  # *next* `/client/mail/dialog/list` rather than the route's own answer, which
  # is what a check on a stub cannot do.
  let inbox0 = call("/client/mail/dialog/list", "")
  let dialogId = textAt(inbox0.body, 0, "_id")
  check("the run left at least one dialog in the inbox", dialogId.len > 0,
        inbox0.body)
  if dialogId.len > 0:
    let unreadBefore = numberAt(inbox0.body, rowOf(inbox0.body, dialogId),
                                "new")
    check("a delivered message is unread on the inbox",
          unreadBefore >= 1,
          "\"new\" is " & $unreadBefore & " on a dialog nobody has read")

    let readIt = call("/client/mail/dialog/read",
                      "{\"dialogs\":[\"" & dialogId & "\"]}")
    check("marking the dialog read is accepted", readIt.ok, readIt.body)
    let inbox1 = call("/client/mail/dialog/list", "")
    # Both halves: the count has to have been non-zero and it has to be zero
    # now. Either alone passes against the stub, which always answered zero.
    check("and the unread count clears on the next inbox",
          unreadBefore >= 1 and
          numberAt(inbox1.body, rowOf(inbox1.body, dialogId), "new") == 0,
          "\"new\" went " & $unreadBefore & " -> " &
          $numberAt(inbox1.body, rowOf(inbox1.body, dialogId), "new"))
    check("while the dialog itself is still there",
          rowOf(inbox1.body, dialogId) >= 0, inbox1.body)

    let pinIt = call("/client/mail/dialog/pin",
                     "{\"dialogId\":\"" & dialogId & "\"}")
    check("pinning the dialog is accepted", pinIt.ok, pinIt.body)
    let inbox2 = call("/client/mail/dialog/list", "")
    check("and the inbox reports it pinned",
          flagAt(inbox2.body, rowOf(inbox2.body, dialogId), "pinned") == 1,
          "\"pinned\" is still false after a pin")
    discard call("/client/mail/dialog/unpin",
                 "{\"dialogId\":\"" & dialogId & "\"}")
    let inbox3 = call("/client/mail/dialog/list", "")
    check("and unpinning it puts it back",
          flagAt(inbox2.body, rowOf(inbox2.body, dialogId), "pinned") == 1 and
          flagAt(inbox3.body, rowOf(inbox3.body, dialogId), "pinned") == 0,
          "\"pinned\" did not come back down")

    # Removal. Every message that still holds items is named first, because
    # the one thing this operation may not do is destroy them: the mailbox is
    # the only place an uncollected insurance return or quest reward exists.
    let heldBefore = call("/client/mail/dialog/getAllAttachments", "")
    var owedIds: seq[string] = @[]
    var scan = 0
    while true:
      let at = findFrom(heldBefore.body, "\"_id\":\"", scan)
      if at < 0: break
      owedIds.add textAt(heldBefore.body, at, "_id")
      scan = at + 7
    let removed = call("/client/mail/dialog/remove",
                       "{\"dialogId\":\"" & dialogId & "\"}")
    check("removing the dialog is accepted", removed.ok, removed.body)
    let inbox4 = call("/client/mail/dialog/list", "")
    check("and it is gone from the inbox",
          rowOf(inbox4.body, dialogId) < 0,
          "the removed dialog is still listed: " & inbox4.body)
    check("and it does not come back on the next request",
          rowOf(call("/client/mail/dialog/list", "").body, dialogId) < 0,
          "the removal did not stick")
    # The other dialogs are untouched -- a remove that emptied the whole
    # mailbox would pass the two checks above.
    check("while the rest of the inbox is untouched",
          countOf(inbox4.body, "\"attachmentsNew\"") ==
          countOf(inbox1.body, "\"attachmentsNew\"") - 1,
          $countOf(inbox1.body, "\"attachmentsNew\"") & " dialogs became " &
          $countOf(inbox4.body, "\"attachmentsNew\""))
    let heldAfter = call("/client/mail/dialog/getAllAttachments", "")
    var lost = ""
    for id in owedIds:
      if id.len > 0 and not heldAfter.contains(id):
        lost = id
    check("and nothing the player had not collected was destroyed with it",
          lost.len == 0, "message " & lost & " and its items are gone")

    let noId = call("/client/mail/dialog/remove", "{}")
    check("a remove naming no dialog removes nothing",
          noId.ok and
          countOf(call("/client/mail/dialog/list", "").body,
                  "\"attachmentsNew\"") ==
          countOf(inbox4.body, "\"attachmentsNew\""), noId.body)

  heading "transferItems: the box is not the cargo"
  # -- transferItems: the box is not the cargo ------------------------------
  #
  # REGRESSION. A human found a message from "Unknown" in the live client's
  # inbox holding one item called "Stash" with a missing icon. MEASURED in
  # `store\aowl.tarkov\mail.00000000000a00000000004f`: one attachment,
  # `_tpl 566abbc34bdc2d92178b4576` = "Standard stash 10x30", `_id` present in
  # no profile item list. `EFT.TransferItemsController` keys its containers by
  # profile id and hands back a `Stash`, so `transferItems` serialises the
  # container's OWN root alongside its contents, and `transferredItems` posted
  # the lot.
  #
  # The assertions are over the FINISHED payload the client is handed, and the
  # load-bearing one is negative: no stash template anywhere in the mail body.
  # The positive one is there to stop the negative passing by way of an empty
  # mailbox -- which is how a check of this shape usually rots.
  block transferBox:
    discard call("/client/match/local/start", "{\"location\":\"factory4_day\"}")
    let base = call("/client/game/profile/list", "").body
    let boxId = "d0d0d0d0d0d0d0d0d0d0d0d1"
    let cargoId = "d0d0d0d0d0d0d0d0d0d0d0d2"
    let cargoTpl = "590c657e86f77412b013051d"   # IFAK, an ordinary item
    let stashTpl = "566abbc34bdc2d92178b4576"   # Standard stash 10x30
    let handed = call("/client/match/local/end",
      "{\"results\":{\"result\":\"Survived\",\"profile\":" & raidProfile(base, uid) &
      "},\"transferItems\":{\"" & uid & "\":[" &
      "{\"_id\":\"" & boxId & "\",\"_tpl\":\"" & stashTpl & "\"}," &
      "{\"_id\":\"" & cargoId & "\",\"_tpl\":\"" & cargoTpl &
      "\",\"parentId\":\"" & boxId & "\",\"slotId\":\"hideout\"," &
      "\"location\":{\"x\":0,\"y\":0,\"r\":0}}]}}")
    check("a raid that handed items to a container is accepted",
          handed.ok and handed.contains("\"err\":0"), handed.body)

    let inbox = call("/client/mail/dialog/list", "")
    check("what was inside the transfer container is posted",
          inbox.contains(cargoId), inbox.body)
    check("and the container itself is NOT",
          not inbox.contains(stashTpl) and not inbox.contains(boxId),
          inbox.body)

    # And the same over `dialog/view`, because the inbox row carries only the
    # newest message while the dialog carries every one of them -- a stash
    # posted by an earlier raid would be invisible to the check above.
    # The system dialog, named rather than guessed at. `textAt(body, 0, "_id")`
    # reads the FIRST dialog in the inbox, which is whichever one an earlier
    # check happened to leave there -- it found the quest payout dialog and
    # asserted against a body that has nothing to do with this claim.
    # `emu/mail.SystemSenderId` is the id a message with no trader behind it is
    # posted from, and the BTR hand-over is exactly that.
    let view = call("/client/mail/dialog/view",
                    "{\"dialogId\":\"000000000000000000000001\"}")
    check("the opened dialog holds the cargo",
          view.contains(cargoId), view.body)
    check("and no message in it attaches a stash",
          not view.contains(stashTpl), view.body)
    check("the sender is one the client can name, not an empty id",
          not view.contains("\"uid\":\"\""), view.body)

    # The negative above is only worth anything if a stash template WOULD have
    # shown up in these bodies. `handed` carried one and the server dropped it;
    # this is the same claim from the other side -- the cargo the box held did
    # arrive, so the array was read and not merely ignored wholesale.
    check("the transfer array was read rather than skipped",
          view.contains(cargoTpl), view.body)

  if not keep:
    cSpawnKill(proc2)

  heading "Result"
  if gFailures > 0:
    err $gFailures & " of " & $gChecks & " failed"
    return 1
  ok "the emulator answered all " & $gChecks & " checks"
  result = 0

quit(main())
