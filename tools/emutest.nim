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
  discard expectIn("no profiles on a fresh install",
                   "/client/game/profile/list", "", "\"data\":[]")

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
