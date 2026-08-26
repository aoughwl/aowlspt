## livectl -- turn a mod off and on again while the server is serving.
##
##     livectl --root <stage> --port 6979 --backend <aowlspt-backend.exe>
##
## `emutest` proves the game; this proves the *mod manager*. It stages a root
## with three mods in it -- the manager, the Tarkov emulator and the example
## game server -- starts the backend on a spare port, and then drives
## `/aowlspt/mods/...` the way a player clicking a switch in the panel does:
## disable, apply, enable, apply.
##
## What is actually being asserted, and why each one is phrased the way it is.
##
## **Control is present, not deferred.** The manager degrades honestly when no
## host answers its probe: every change is "recorded; takes effect on restart".
## That state passes any check that only reads `"ok":true` out of an apply, so
## the first thing here is `"control":"present"` -- and it is checked for the
## exact word, because both of the other two (`unknown`, `absent`) mean the
## feature under test is not running.
##
## **A route that is gone is gone from the router.** The backend answers an
## unrouted URL with `{"err":"no route","url":"..."}`. A mod whose handler is
## still in the table but whose library has been freed does not answer that --
## it crashes, or it answers something. So every "the mod is gone" check reads
## `no route` specifically rather than "the request failed" or "the body no
## longer says what it used to", either of which a half-unloaded host passes.
##
## **A reloaded mod is a new instance.** `examples/gameserver` counts the
## requests it has served in a module-level `hits`. Three calls before the
## unload, and the first call after the reload must answer `1`. A host that
## kept the library mapped and simply re-registered its routes answers `4`, and
## every other check in this file passes against it.
##
## **Nothing happened is checked by counting log lines, not by asking.** The
## idempotent cases -- apply twice, enable what is enabled, disable what is not
## loaded -- all answer `ok` whether or not the host did something behind it. So
## what they assert is that the host log still carries exactly one
## ` loaded Game Server` and one ` unloaded Game Server`: a second load, a
## second unload or a reload nobody asked for shows up there and nowhere else.
## The leading space is load-bearing -- `unloaded X` contains `loaded X`.
##
## **Unloading one mod is not unloading the mods next to it.** The emulator is
## staged alongside and every stage of the run re-checks that
## `/client/game/version/validate` still answers. `dropModRegistrations` walks
## one flat table of routes filtering on a mod index; getting that filter
## backwards takes out everything *except* the mod being unloaded, and a test
## with one mod in it cannot see the difference.
##
## The fixture -- the registry and the manager's config -- is written by this
## tool into the root it is given, rather than copied from the repository's
## own `registry/mods.json`. The checks below name three mods and one list and
## would become quietly meaningless if somebody edited the real registry, which
## is a document about what ships and not a test fixture.

import std/[strutils, syncio, cmdline]
import aowlsptinstall/[winfs, log]
import wire

{.emit: """#include <stdlib.h>""".}
{.emit: """#include <string.h>""".}
{.emit: """#include "aowlspt_shim.h" """.}
{.emit: """#include "aowlspt_net.h" """.}
{.emit: """#include "aowlspt_inject.h" """.}

{.emit: """
/* The same loopback connect `wire.nim` makes, written out again here because
 * `{.emit.}` is module-scoped: `aowl_wire_connect` is compiled into wire's
 * translation unit and is not declared in this one, so calling it produces an
 * implicit-declaration error naming a function this file never wrote. Given a
 * different name so the two can never be mistaken for each other.
 *
 * It exists because the checks at the bottom of this file need two requests in
 * the server at the same moment, and `request` sends and then reads. */
static uint64_t aowl_livectl_connect(int32_t port) {
  SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (s == INVALID_SOCKET) return 0;
  struct sockaddr_in a;
  memset(&a, 0, sizeof(a));
  a.sin_family = AF_INET;
  a.sin_port = htons((unsigned short)port);
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (connect(s, (struct sockaddr*)&a, sizeof(a)) == SOCKET_ERROR) {
    closesocket(s);
    return 0;
  }
  DWORD t = 15000;
  setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char*)&t, sizeof(t));
  return (uint64_t)s;
}
""".}

proc cRawConnect(port: int32): uint64 {.
  importc: "aowl_livectl_connect", nodecl.}

proc cSpawn(exe, workDir, cmdLine: cstring): uint64 {.
  importc: "aowl_spawn", nodecl.}
proc cSpawnKill(h: uint64) {.importc: "aowl_spawn_kill", nodecl.}
proc cSleepMs(ms: int32) {.importc: "aowl_sys_sleep", nodecl.}

const
  Usage = """
livectl -- enable and disable mods on a running server

  livectl --root PATH --backend PATH [--port N]

  --root PATH      the scratch install (mods/manager, mods/tarkov,
                   mods/gameserver); the registry and the manager's config
                   are written into it by this tool
  --backend PATH   aowlspt-backend.exe
  --port N         port to serve on (default 6979)
  --keep           leave the backend running at the end
  -h, --help       this
"""
  Session = "aaaaaaaaaaaaaaaaaaaaaaaa"

  ManagerId = "aowl.manager"
  TarkovId = "aowl.tarkov"
  ServerId = "aowl.gameserver"
  ## The mod this run switches off and on. The example game server rather than
  ## the emulator: it is the one with a request counter on a route, which is
  ## the only cheap way to tell a reloaded mod from a mod that was never
  ## unloaded.

  ServerName = "Game Server"     ## as `exportMod` names it, and as the log does
  TarkovName = "Singleplayer"
  ManagerName = "Mod Manager"    ## `mgr`'s own `ModName`

  # A registry of exactly the three mods staged beside it. Written here rather
  # than copied from the repository so that the counts and ids the checks below
  # assert on are this file's business and cannot be changed from elsewhere.
  RegistryDoc = """{
  "schema": "aowlspt.registry/1",
  "registry": {
    "id": "aowl.registry.livectl",
    "name": "livectl fixture registry",
    "description": "Three mods and one list, written by tools/livectl.nim. Not a shipping registry."
  },
  "mods": [
    {
      "id": "aowl.manager",
      "name": "Mod Manager",
      "author": "aowlspt",
      "version": "1.0.0",
      "description": "The thing under test.",
      "pipeline": ">=0.1.0",
      "sides": ["server", "sim"],
      "source": { "kind": "intree", "path": "mods/manager", "url": null },
      "artifact": { "dir": "manager", "library": "manager.dll" },
      "upstream": null,
      "license": "see repository",
      "download": null,
      "requires": [],
      "conflicts": [],
      "provides": ["aowl.capability.modmanager"],
      "loadAfter": [],
      "tags": ["core", "manager"]
    },
    {
      "id": "aowl.tarkov",
      "name": "Singleplayer",
      "author": "aowlspt",
      "version": "0.1.0",
      "description": "The mod that must keep serving while another one is taken out.",
      "pipeline": ">=0.1.0",
      "sides": ["server", "sim"],
      "source": { "kind": "intree", "path": "mods/tarkov", "url": null },
      "artifact": { "dir": "tarkov", "library": "tarkov.dll" },
      "upstream": null,
      "license": "see repository",
      "download": null,
      "requires": [],
      "conflicts": [],
      "provides": ["aowl.capability.gameserver"],
      "loadAfter": [],
      "tags": ["server"]
    },
    {
      "id": "aowl.gameserver",
      "name": "Game Server",
      "author": "aowlspt",
      "version": "0.1.0",
      "description": "The mod this run switches off and on. It counts the requests it has served, which is how a reload is told from a mod that never left.",
      "pipeline": ">=0.1.0",
      "sides": ["server", "sim"],
      "source": { "kind": "intree", "path": "examples/gameserver", "url": null },
      "artifact": { "dir": "gameserver", "library": "gameserver.dll" },
      "upstream": null,
      "license": "see repository",
      "download": null,
      "requires": [],
      "conflicts": [],
      "provides": [],
      "loadAfter": [],
      "tags": ["example"]
    }
  ],
  "lists": [
    {
      "id": "aowl.list.livectl",
      "name": "livectl",
      "author": "aowlspt",
      "version": "1.0.0",
      "description": "All three, on.",
      "inherits": [],
      "entries": [
        { "id": "aowl.manager", "enabled": true },
        { "id": "aowl.tarkov", "enabled": true },
        { "id": "aowl.gameserver", "enabled": true }
      ]
    }
  ]
}
"""

  ManagerConfig = """{
  "registryPath": "",
  "activeLists": ["aowl.list.livectl"],
  "controlProbeMs": 750,
  "writeSelectionFile": true,
  "registryFetchEnabled": true,
  "registryFetchOnStart": false,
  "registryUrl": "REGISTRY_FETCH_SOURCE"
}
"""
  ## The fetch is on, and pointed at a **file**. `mgr/httpfetch.nim` reads a
  ## plain path on the calling thread, so the adopt happens exactly where this
  ## tool asks for it -- which is what turns "a registry refresh finished in the
  ## middle of an apply" from something to wait for into something to cause. The
  ## URL is substituted at staging time, because it has to be an absolute path
  ## into whatever root this run was given. Nothing is fetched until a route
  ## asks: `registryFetchOnStart` is false.

  # The same three mods, so that adopting it changes what the manager says
  # about itself and nothing about what resolves. `registry.name` is the only
  # visible difference, and it is how the checks tell which document is in
  # effect. A `revision` so the rollback rule has something to compare.
  FetchedRegistryDoc = """{
  "schema": "aowlspt.registry/1",
  "registry": {
    "id": "aowl.registry.livectl",
    "name": "livectl fetched registry",
    "revision": 2,
    "description": "The same three mods, fetched from a file by tools/livectl.nim."
  },
  "mods": [
    {
      "id": "aowl.manager",
      "name": "Mod Manager",
      "author": "aowlspt",
      "version": "1.0.0",
      "description": "The thing under test.",
      "pipeline": ">=0.1.0",
      "sides": ["server", "sim"],
      "source": { "kind": "intree", "path": "mods/manager", "url": null },
      "artifact": { "dir": "manager", "library": "manager.dll" },
      "upstream": null,
      "license": "see repository",
      "download": null,
      "requires": [],
      "conflicts": [],
      "provides": ["aowl.capability.modmanager"],
      "loadAfter": [],
      "tags": ["core", "manager"]
    },
    {
      "id": "aowl.tarkov",
      "name": "Singleplayer",
      "author": "aowlspt",
      "version": "0.1.0",
      "description": "The mod that must keep serving while another one is taken out.",
      "pipeline": ">=0.1.0",
      "sides": ["server", "sim"],
      "source": { "kind": "intree", "path": "mods/tarkov", "url": null },
      "artifact": { "dir": "tarkov", "library": "tarkov.dll" },
      "upstream": null,
      "license": "see repository",
      "download": null,
      "requires": [],
      "conflicts": [],
      "provides": ["aowl.capability.gameserver"],
      "loadAfter": [],
      "tags": ["server"]
    },
    {
      "id": "aowl.gameserver",
      "name": "Game Server",
      "author": "aowlspt",
      "version": "0.1.0",
      "description": "The mod this run switches off and on.",
      "pipeline": ">=0.1.0",
      "sides": ["server", "sim"],
      "source": { "kind": "intree", "path": "examples/gameserver", "url": null },
      "artifact": { "dir": "gameserver", "library": "gameserver.dll" },
      "upstream": null,
      "license": "see repository",
      "download": null,
      "requires": [],
      "conflicts": [],
      "provides": [],
      "loadAfter": [],
      "tags": ["example"]
    }
  ],
  "lists": [
    {
      "id": "aowl.list.livectl",
      "name": "livectl",
      "author": "aowlspt",
      "version": "1.0.0",
      "description": "All three, on.",
      "inherits": [],
      "entries": [
        { "id": "aowl.manager", "enabled": true },
        { "id": "aowl.tarkov", "enabled": true },
        { "id": "aowl.gameserver", "enabled": true }
      ]
    }
  ]
}
"""

var gFailures = 0
var gChecks = 0
var gPort = 6979
var gRoot = ""

proc check(what: string; condition: bool; detail = "") =
  inc gChecks
  if condition:
    ok what
  else:
    err what & (if detail.len > 0: ": " & detail else: "")
    inc gFailures

proc call(path, body: string): Response =
  result = request(gPort, path, body, Session)

proc findFrom(haystack, needle: string; start: int): int =
  ## `find`, from an offset. The two-argument `find` is all there is, and the
  ## readers below want "the value belonging to *this* row" out of a document
  ## whose rows all use the same key names.
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

proc jsonText(body, key: string): string = textAt(body, 0, key)

proc numberAt(body: string; start: int; key: string): int =
  ## `"key":123` at or after `start`. -1 when the key is not there, which is
  ## distinct from 0 -- and has to be, because 0 is the value several of the
  ## fields below are asserted to have.
  let at = findFrom(body, "\"" & key & "\":", start)
  if at < 0:
    return -1
  var i = at + key.len + 3
  var v = 0
  var any = false
  while i < body.len and body[i] >= '0' and body[i] <= '9':
    v = v * 10 + (ord(body[i]) - ord('0'))
    any = true
    inc i
  if not any:
    return -1
  result = v

proc jsonNumber(body, key: string): int = numberAt(body, 0, key)

proc flagAt(body: string; start: int; key: string): string =
  ## `"key":true` / `"key":false` / `"key":null` at or after `start`, as the
  ## word itself. Returned as text rather than as a bool so that "the key was
  ## not there at all" and "the key said false" stay different answers -- the
  ## panel writes `null` for "no host has said", and reading that as `false`
  ## would turn the manager's honesty into a passing check.
  let at = findFrom(body, "\"" & key & "\":", start)
  if at < 0:
    return ""
  var i = at + key.len + 3
  result = ""
  while i < body.len and ((body[i] >= 'a' and body[i] <= 'z')):
    result.add body[i]
    inc i

proc countOf(haystack, needle: string): int =
  result = 0
  var i = 0
  while i < haystack.len:
    let at = find(haystack.substr(i), needle)
    if at < 0:
      return
    inc result
    i = i + at + needle.len

proc hostLog(): string =
  ## The backend's log for this run. Opened fresh at every start, so a count
  ## over it is a count of what this run did.
  result = ""
  discard readTextFile(joinPath(gRoot, "aowlspt-backend.log"), result)

proc loadedCount(name: string): int =
  ## How many times the host has said it loaded this mod. The leading space is
  ## the whole reason this is a proc: `unloaded Game Server` contains
  ## `loaded Game Server`, so the obvious count is the sum of both and never
  ## goes down.
  result = countOf(hostLog(), " loaded " & name)

proc unloadedCount(name: string): int =
  result = countOf(hostLog(), " unloaded " & name)

# ---------------------------------------------------------------------------
# Staging and starting
# ---------------------------------------------------------------------------

proc stageFixture(): bool =
  ## The registry and the manager's config, into the root. The mod libraries
  ## are put there by whoever built them -- `aowl test` -- and their absence is
  ## reported here by name rather than by whatever the manager says three
  ## checks later.
  result = true
  let mods = joinPath(gRoot, "mods")
  var missing = ""
  if not fileExists(joinPath(mods, "manager\\manager.dll")):
    missing.add " mods\\manager\\manager.dll"
  if not fileExists(joinPath(mods, "tarkov\\tarkov.dll")):
    missing.add " mods\\tarkov\\tarkov.dll"
  if not fileExists(joinPath(mods, "gameserver\\gameserver.dll")):
    missing.add " mods\\gameserver\\gameserver.dll"
  if missing.len > 0:
    err "the stage is missing:" & missing
    return false
  discard ensureDir(joinPath(gRoot, "registry"))
  if not writeTextFile(joinPath(gRoot, "registry\\mods.json"), RegistryDoc).ok:
    err "could not write the fixture registry"
    return false
  # The document a refresh fetches, and the path in the config that names it.
  # Written with forward slashes: it goes into a JSON string, and a Windows
  # path with backslashes in one is an escape sequence rather than a path.
  let fetched = joinPath(gRoot, "registry\\fetched.json")
  if not writeTextFile(fetched, FetchedRegistryDoc).ok:
    err "could not write the fetchable registry"
    return false
  var source = ""
  for ch in fetched:
    if ch == '\\': source.add '/' else: source.add ch
  var config = ""
  var i = 0
  while i < ManagerConfig.len:
    if i + 22 <= ManagerConfig.len and
       ManagerConfig.substr(i, i + 21) == "REGISTRY_FETCH_SOURCE\"":
      config.add source
      config.add '"'
      i = i + 22
    else:
      config.add ManagerConfig[i]
      inc i
  if not writeTextFile(joinPath(mods, "manager\\config.json"), config).ok:
    err "could not write the manager's config"
    return false

proc startBackend(exe: string): uint64 =
  var e = exe
  var w = gRoot
  var c = "\"" & exe & "\" --root \"" & gRoot & "\" --port " & $gPort
  result = cSpawn(toCString(e), toCString(w), toCString(c))

proc waitForManager(tries: int): bool =
  ## Polled rather than slept: the backend has to bind a port, load three mods
  ## and parse a registry first, and a fixed sleep is either short on a cold
  ## disk or wasted on a warm one. The manager's own status route is the thing
  ## polled, because that is the first route this test needs and a backend that
  ## is listening without it is not ready.
  var i = 0
  while i < tries:
    let r = call("/aowlspt/mods", "")
    if r.ok and r.contains("\"registryName\""):
      return true
    cSleepMs(200'i32)
    inc i
  result = false

proc waitForControl(tries: int): string =
  ## The control state, once it stops being `unknown`. The manager answers
  ## `unknown` until either the host replies or its own probe timer expires, so
  ## reading the field once would be reading a race.
  var i = 0
  result = "unknown"
  while i < tries:
    let r = call("/aowlspt/mods", "")
    if r.ok:
      let s = jsonText(r.body, "control")
      if s.len > 0 and s != "unknown":
        return s
    cSleepMs(100'i32)
    inc i

proc waitForLogLine(needle: string; tries: int): bool =
  ## The apply is asynchronous by design -- the host queues the unload and does
  ## it off the emitting stack, one tick later -- so the deed is done some
  ## milliseconds after the reply. Waited for in the *log* rather than by
  ## polling the mod's own route, because the mod under test counts the
  ## requests it serves and a poll would be adding to the number the instance
  ## check further down asserts on.
  result = false
  var i = 0
  while i < tries:
    if find(hostLog(), needle) >= 0:
      return true
    cSleepMs(100'i32)
    inc i

proc waitUntilServed(path, marker: string; tries: int): Response =
  ## One call per turn, and the first one that answers is the one handed back:
  ## the mod counts the requests it serves, so a poll that called twice per
  ## turn would be the reason its counter is not 1.
  result = call(path, "")
  var i = 0
  while i < tries:
    if result.ok and result.contains(marker):
      return result
    cSleepMs(100'i32)
    result = call(path, "")
    inc i

proc between(body, opener, closer: string): string =
  ## What lies between the first `opener` and the next `closer`. Used to lift
  ## `"activeLists":[...]` and `"order":[...]` out whole, so that "the
  ## selection did not change" can be one string comparison rather than a walk.
  let at = find(body, opener)
  if at < 0:
    return ""
  var i = at + opener.len
  result = ""
  while i < body.len and body[i] != closer[0]:
    result.add body[i]
    inc i

proc arrayIsEmptyAt(body, opener: string): bool =
  ## Whether `opener` is in `body` *and* the array it opens is empty.
  ##
  ## `between` answers "" for two different things: "the array is empty" and
  ## "this document has no such key in it". Two checks in this file assert
  ## emptiness -- that selecting no lists empties `activeLists`, and that a
  ## damaged selection does not fall back to the config's defaults -- and
  ## written against `between` alone both of them pass when the key is not there
  ## at all: a renamed field, a route that answered something else, a body that
  ## never arrived. The presence of the key is the precondition, so it is
  ## asserted rather than assumed.
  result = find(body, opener) >= 0 and between(body, opener, "]").len == 0

proc reportsArray(body, opener: string): string =
  ## For the failure line: which of the two it was.
  if find(body, opener) < 0:
    result = "there is no " & opener & " in the answer at all"
  else:
    result = opener & between(body, opener, "]") & "]"

proc selectionFingerprint(): string =
  ## Everything a hostile request must not be able to change: which lists are
  ## active, and what the resolution makes of them.
  ##
  ## Read back off the server rather than off the store file, because the store
  ## file is held open by the running backend and because what is being claimed
  ## is what the *manager* believes -- a route that changed the selection in
  ## memory and failed to write it is exactly as bad as one that wrote it.
  let status = call("/aowlspt/mods", "")
  let listing = call("/aowlspt/mods/list", "")
  result = between(status.body, "\"activeLists\":[", "]") & " || " &
           between(listing.body, "\"order\":[", "]")

proc panelFieldOf(guid, key: string): string =
  ## One field of one panel row, as the word itself.
  let r = call("/aowlspt/mods/panel", "")
  if not r.ok:
    return ""
  let at = find(r.body, "\"guid\":\"" & guid & "\"")
  if at < 0:
    return ""
  result = flagAt(r.body, at, key)

proc waitForLive(guid, want: string; tries: int): string =
  ## What the manager's panel says about one mod, once it says something. The
  ## row's `live` is updated when the host's `result` arrives, which is after
  ## the apply answered.
  var i = 0
  result = ""
  while i < tries:
    let r = call("/aowlspt/mods/panel", "")
    if r.ok:
      let at = find(r.body, "\"guid\":\"" & guid & "\"")
      if at >= 0:
        result = flagAt(r.body, at, "live")
        if result == want:
          return result
    cSleepMs(100'i32)
    inc i

# ---------------------------------------------------------------------------
# Hostile input
# ---------------------------------------------------------------------------
#
# Two claims per case, and the second is the one that matters. A route that
# answers `{"ok":false}` and has already written an override is a route that
# refused in the reply and accepted on disk -- which is worse than accepting,
# because nothing in the answer says the selection moved. So every hostile call
# is bracketed by a fingerprint of the whole selection, and both halves have to
# hold.

proc refuses(what, path, body: string) =
  let before = selectionFingerprint()
  let r = call(path, body)
  check(what & " is refused, with a reason",
        r.ok and r.contains("\"ok\":false") and r.contains("\"error\":\""),
        r.body)
  let after = selectionFingerprint()
  check(what & " changes nothing", after == before,
        "the selection went from " & before & " to " & after)

proc survives(what, path, body: string) =
  ## For the routes that have nothing to refuse -- a read, or an apply that
  ## ignores the body. The claim is only that the server is still there and the
  ## selection did not move.
  let before = selectionFingerprint()
  let r = call(path, body)
  check(what & " is answered rather than crashed into", r.ok, r.error)
  let after = selectionFingerprint()
  check(what & " changes nothing", after == before,
        "the selection went from " & before & " to " & after)

proc bigId(n: int): string =
  result = ""
  var i = 0
  while i < n:
    result.add "a"
    inc i

# ---------------------------------------------------------------------------
# Two requests at once
# ---------------------------------------------------------------------------
#
# `request` in `wire.nim` sends and then reads, so a hundred of them in a row
# never put two requests in the server at the same time -- and the bug being
# checked for here only exists while two of them are. So these two split it:
# `openRequest` connects and sends, `drain` reads the answer and throws it
# away. Send both, then read both, and the second request is in the backend's
# hands before the first has answered.
#
# The answers are discarded on purpose. What a racing request *replies* is not
# the claim -- both replies are legal, and which one wins is a race by
# definition. The claim is what is true afterwards: the selection has to be one
# of the outcomes somebody asked for, and every view of it has to agree with
# every other. A mixture is what an unguarded read produces, and a mixture is
# what nothing else here would ever notice.

proc openRequest(path, body: string): uint64 =
  let sock = cRawConnect(int32(gPort))
  if sock == 0'u64:
    return 0'u64
  var req = (if body.len > 0: "POST " else: "GET ") & path & " HTTP/1.1\r\n"
  req.add "Host: 127.0.0.1:" & $gPort & "\r\n"
  req.add "Cookie: PHPSESSID=" & Session & "\r\n"
  # Uncompressed: the server sniffs zlib framing rather than requiring it, and
  # a plain body keeps this helper to twenty lines.
  req.add "Content-Length: " & $body.len & "\r\n"
  req.add "Connection: close\r\n\r\n"
  var head = toBytes(req)
  if cSend(sock, cast[WirePtr](addr head[0]), int32(req.len)) < 0'i32:
    cClose(sock)
    return 0'u64
  if body.len > 0:
    var payload = toBytes(body)
    if cSend(sock, cast[WirePtr](addr payload[0]), int32(body.len)) < 0'i32:
      cClose(sock)
      return 0'u64
  result = sock

proc drain(sock: uint64): int =
  ## Bytes read to end of stream. Zero means the server closed without saying
  ## anything, which is what a deadlocked or crashed worker looks like from
  ## here and is the failure these checks would otherwise miss.
  if sock == 0'u64:
    return 0
  var buf = newSeq[byte](65536)
  var have = 0
  while true:
    let m = cRecv(sock, cast[WirePtr](addr buf[0]), int32(buf.len))
    if m <= 0'i32:
      break
    have = have + int(m)
  cClose(sock)
  result = have

proc bothAtOnce(pathA, bodyA, pathB, bodyB: string): bool =
  let a = openRequest(pathA, bodyA)
  let b = openRequest(pathB, bodyB)
  let gotA = drain(a)
  let gotB = drain(b)
  result = gotA > 0 and gotB > 0

proc orderOf(): string =
  result = between(call("/aowlspt/mods/list", "").body, "\"order\":[", "]")

proc orderHas(guid: string): bool =
  result = find(orderOf(), "\"" & guid & "\"") >= 0

proc rowCount(body: string): int =
  result = countOf(body, "\"guid\":\"")

# ---------------------------------------------------------------------------

proc main(): int =
  var backend = ""
  var keep = false
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

  # Absolute, before anything uses it.
  #
  # The child is started **with its working directory set to the root** and
  # `--root` on its command line. A relative root is then resolved twice: the
  # backend joins it to its own new cwd and lands in `<root>/<root>`. That was
  # live -- `installer/build/gate-fuzzstage/installer/build/gate-fuzzstage/`
  # exists on disk, with the log and the store in it, while the stage's own top
  # level has neither -- and it is silent, because the server starts perfectly
  # well in the wrong place.
  # Guarded, because `absolutePathOf("")` answers the current directory, and a
  # run with no `--root` would then quietly point at wherever it was started.
  if gRoot.len > 0:
    gRoot = absolutePathOf(gRoot)

  if gRoot.len == 0 or backend.len == 0:
    echo Usage
    return 1
  if not fileExists(backend):
    err "no backend at " & backend
    return 1

  discard cNetStartup()

  heading "Staging"
  if not stageFixture():
    return 1
  # A selection left over from a previous run is a different test: the manager
  # reads its overrides out of its own store and would start with the mod
  # already switched off, which turns the first half of this file into checks
  # about nothing. Refused rather than deleted -- a tool that quietly clears
  # state it did not create is one you cannot debug with.
  if fileExists(joinPath(gRoot, "store\\aowl.manager\\selection")):
    err "this root already carries a saved selection; livectl needs a fresh one"
    note "delete " & gRoot & "\\store and run again"
    return 1
  ok "registry, config and three mods are in " & gRoot

  heading "Starting"
  var backendProc = startBackend(backend)
  if backendProc == 0'u64:
    err "could not start the backend"
    # The spawn takes `root` as its working directory, so a root that does not
    # exist yet fails here -- and "could not start the backend" then names the
    # backend, which is fine, while the thing that is wrong is the argument two
    # flags to the left. Every other caller of this suite stages the root
    # first, so it went years without being said out loud.
    if not exists(gRoot):
      note "there is no directory at " & gRoot & " -- the spawn takes the " &
           "root as its working directory, so it fails before the backend " &
           "runs. Create it (and stage the mod and the database into it) " &
           "first; `aowl test` does that for you"
    elif not fileExists(backend):
      note "there is no file at " & backend & "; build it with `aowl build`"
    return 1
  if not waitForManager(60):
    err "the manager never answered /aowlspt/mods"
    cSpawnKill(backendProc)
    return 1
  ok "the backend is serving on " & $gPort

  let status = call("/aowlspt/mods", "")
  check("the manager read the fixture registry",
        status.contains("\"ok\":true") and jsonNumber(status.body, "mods") == 3,
        status.body)

  heading "Live control"
  # The check the rest of the file rests on. `absent` and `unknown` are the two
  # states the manager reports when nothing answers its probe, and in both of
  # them every apply below would answer `ok` and change nothing -- so this is
  # asserted against the exact word rather than against "not absent".
  let state = waitForControl(60)
  check("the host answers the control probe with control present",
        state == "present", "the manager says " & state)
  check("and says so as a capability, not as a hope",
        call("/aowlspt/mods", "").contains("\"liveChanges\":true"),
        call("/aowlspt/mods", "").body)
  check("and the host log records which host answered",
        find(hostLog(), "manager: live mod control is available") >= 0,
        "no such line in the host log")
  # The positive half of the manager's own name in the log.
  #
  # Three checks further down assert `unloadedCount("Mod Manager") == 0` -- the
  # manager was never taken out -- and a count of a string that this log never
  # writes is zero whatever the host did. `Game Server` and `Singleplayer`
  # are each anchored by a check that counts *up* to a known number; the
  # manager's name had no such anchor, so its three protection checks rested on
  # a spelling nothing here confirmed. This confirms it.
  check("the host log names the manager the way this file counts it",
        loadedCount(ManagerName) == 1,
        $loadedCount(ManagerName) & " ` loaded " & ManagerName & "` line(s) " &
        "in the log; the manager-protection checks below count the same " &
        "string, and a name this log does not use makes all of them pass")
  if state != "present":
    err "there is no live mod control on this host; nothing below can be tested"
    cSpawnKill(backendProc)
    return 1

  heading "All three are serving"
  let boot = call("/aowlspt/status", "")
  check("the mod that will be unloaded answers its route",
        boot.ok and boot.contains("\"mod\":\"aowl.gameserver\""), boot.body)
  # Counted deliberately, and read back, because the number is the instance
  # test further down: a mod that is reloaded starts at one again, and a mod
  # that never left carries on from three.
  discard call("/aowlspt/status", "")
  let third = call("/aowlspt/status", "")
  check("and it is counting the requests it serves",
        jsonNumber(third.body, "hits") == 3,
        "hits " & $jsonNumber(third.body, "hits") & " after three calls")
  let itemRoute = call("/aowlspt/item/5447a9cd4bdc2dbd208b4567", "")
  # Its prefix route as well as its exact one. They live in the same table but
  # are matched by different code, and an unload that dropped one kind and left
  # the other is a live crash rather than a failing check.
  check("its prefix route is served by the mod, not by the router's fallback",
        itemRoute.ok and not itemRoute.contains("no route"), itemRoute.body)
  let emu = call("/client/game/version/validate",
                 "{\"version\":{\"major\":\"1.1.0\"}}")
  check("the emulator beside it answers too",
        emu.ok and emu.contains("isvalid"), emu.body)
  check("and both are in the load order the registry resolved",
        call("/aowlspt/mods/list", "").contains("\"order\":[\"" & ManagerId &
             "\",\"" & TarkovId & "\",\"" & ServerId & "\"]"),
        call("/aowlspt/mods/list", "").body)

  heading "Disabling a mod on the running server"
  let disabled = call("/aowlspt/mods/disable/" & ServerId, "")
  check("the switch is accepted", disabled.ok and
        disabled.contains("\"ok\":true"), disabled.body)
  let applied = call("/aowlspt/mods/apply", "")
  # `deferred:0` is the assertion, not `ok:true`. A host with no live control
  # answers every apply `ok:true` with a deferral per mod and a note saying it
  # takes effect on restart -- which is the exact failure this file exists to
  # catch, and it is invisible to a check on `ok`.
  check("apply asks the host to do it now rather than at the next restart",
        applied.ok and jsonNumber(applied.body, "deferred") == 0 and
        not applied.contains("\"outcome\":\"deferred\"") and
        not applied.contains("\"outcome\":\"refused\""), applied.body)
  check("and the apply names the mod and the action",
        find(applied.body, "\"id\":\"" & ServerId & "\"") >= 0 and
        applied.contains("\"action\":\"unload\""), applied.body)
  check("and nothing is left pending a restart",
        applied.contains("\"restartRequired\":false"), applied.body)

  check("the host takes it out within a tick of the request",
        waitForLogLine(" unloaded " & ServerName, 50),
        "no unload line in the host log")
  check("exactly once",
        unloadedCount(ServerName) == 1,
        $unloadedCount(ServerName) & " unload lines for " & ServerName)
  # The mod's own `on_unload` ran, and it ran while the mod was still itself:
  # the number is the four requests it served above, read out of its own
  # module-level counter. A host that freed the library first and called
  # nothing writes no such line, and one that called `on_unload` after
  # tearing the mod down cannot report the count.
  check("and the mod's own on_unload ran, with its state still intact",
        find(hostLog(), "gameserver unloading after 4 requests") >= 0,
        "no `gameserver unloading after 4 requests` in the host log")

  # `no route` specifically. A mod that was freed without its routes being
  # dropped does not answer this -- it answers something, or it takes the
  # process down -- and "the request failed" would pass against a server that
  # had simply died, which is the opposite of what is being claimed.
  let gone = call("/aowlspt/status", "")
  check("its route is gone from the router",
        gone.ok and gone.contains("\"err\":\"no route\"") and
        gone.contains("/aowlspt/status"), gone.body)
  let goneItem = call("/aowlspt/item/5447a9cd4bdc2dbd208b4567", "")
  check("and so is its prefix route",
        goneItem.ok and goneItem.contains("no route"), goneItem.body)

  # The other half, and the one a single-mod test cannot see: taking one mod
  # out must not take out the mod next to it.
  let stillThere = call("/client/game/version/validate",
                        "{\"version\":{\"major\":\"1.1.0\"}}")
  check("the emulator's routes are untouched",
        stillThere.ok and stillThere.contains("isvalid"), stillThere.body)
  check("and the manager is still serving its own",
        call("/aowlspt/mods", "").contains("\"registryName\""),
        call("/aowlspt/mods", "").body)
  check("the panel reports the mod as not live",
        waitForLive(ServerId, "false", 30) == "false",
        "the panel says live=" & waitForLive(ServerId, "false", 1))

  heading "Doing it again changes nothing"
  # Three idempotent cases, and each one is checked by counting log lines
  # rather than by reading the reply: all three answer `ok` whether or not the
  # host did anything, so the reply cannot tell them apart from a host that
  # unloaded a mod twice or loaded a second copy.
  let applyTwice = call("/aowlspt/mods/apply", "")
  check("applying an unchanged selection is accepted",
        applyTwice.ok and jsonNumber(applyTwice.body, "deferred") == 0 and
        not applyTwice.contains("\"outcome\":\"refused\""), applyTwice.body)
  cSleepMs(400'i32)
  check("and does not unload anything a second time",
        unloadedCount(ServerName) == 1 and unloadedCount(TarkovName) == 0,
        $unloadedCount(ServerName) & " / " & $unloadedCount(TarkovName))
  check("nor reload a mod that was already loaded",
        loadedCount(TarkovName) == 1,
        $loadedCount(TarkovName) & " load lines for " & TarkovName)

  let offAgain = call("/aowlspt/mods/disable/" & ServerId, "")
  check("disabling a mod that is not loaded is accepted",
        offAgain.ok and offAgain.contains("\"ok\":true"), offAgain.body)
  let applyOffAgain = call("/aowlspt/mods/apply", "")
  check("and applying it reports no deferral and no refusal",
        applyOffAgain.ok and jsonNumber(applyOffAgain.body, "deferred") == 0 and
        not applyOffAgain.contains("\"outcome\":\"refused\""),
        applyOffAgain.body)
  cSleepMs(400'i32)
  check("and the host did not try to unload it again",
        unloadedCount(ServerName) == 1,
        $unloadedCount(ServerName) & " unload lines")
  check("and its route is still gone rather than briefly back",
        call("/aowlspt/status", "").contains("no route"),
        call("/aowlspt/status", "").body)

  let onAlready = call("/aowlspt/mods/enable/" & TarkovId, "")
  check("enabling a mod that is already enabled is accepted",
        onAlready.ok and onAlready.contains("\"ok\":true"), onAlready.body)
  let applyOnAlready = call("/aowlspt/mods/apply", "")
  check("and applying it defers nothing",
        applyOnAlready.ok and
        jsonNumber(applyOnAlready.body, "deferred") == 0, applyOnAlready.body)
  cSleepMs(400'i32)
  check("and the host did not load a second copy of it",
        loadedCount(TarkovName) == 1 and unloadedCount(TarkovName) == 0,
        $loadedCount(TarkovName) & " loads, " & $unloadedCount(TarkovName) &
        " unloads")
  check("and it is still answering",
        call("/client/game/version/validate",
             "{\"version\":{\"major\":\"1.1.0\"}}").contains("isvalid"),
        "the emulator stopped answering")

  heading "Putting it back"
  let enabled = call("/aowlspt/mods/enable/" & ServerId, "")
  check("the switch is accepted", enabled.ok and
        enabled.contains("\"ok\":true"), enabled.body)
  let applyBack = call("/aowlspt/mods/apply", "")
  check("apply asks the host to load it now",
        applyBack.ok and jsonNumber(applyBack.body, "deferred") == 0 and
        not applyBack.contains("\"outcome\":\"refused\""), applyBack.body)

  let back = waitUntilServed("/aowlspt/status", "aowl.gameserver", 50)
  check("its route answers again",
        back.ok and back.contains("\"mod\":\"aowl.gameserver\""), back.body)
  # The claim that makes "disable, then enable" mean what the person clicking
  # the switch thinks it means. The mod counted three requests before it was
  # taken out; this is the first request the new instance has seen, so it must
  # say one. A host that never actually freed the library -- or that kept the
  # mod's globals alive across a reload -- answers four, and passes every other
  # check in this file.
  check("and it is a fresh instance: its on_load ran again",
        jsonNumber(back.body, "hits") == 1,
        "hits " & $jsonNumber(back.body, "hits") & " on the first request " &
        "after the reload; 4 would mean the old instance never left")
  check("its prefix route came back with it",
        not call("/aowlspt/item/5447a9cd4bdc2dbd208b4567", "").contains("no route"),
        call("/aowlspt/item/5447a9cd4bdc2dbd208b4567", "").body)
  check("the host log records exactly one reload, not a stream of them",
        loadedCount(ServerName) == 2 and unloadedCount(ServerName) == 1,
        $loadedCount(ServerName) & " loads, " & $unloadedCount(ServerName) &
        " unloads for " & ServerName)
  check("the panel reports it as live again",
        waitForLive(ServerId, "true", 30) == "true",
        "the panel says live=" & waitForLive(ServerId, "true", 1))
  check("and the emulator never stopped answering through any of it",
        call("/client/game/version/validate",
             "{\"version\":{\"major\":\"1.1.0\"}}").contains("isvalid"),
        "the emulator stopped answering")

  # -------------------------------------------------------------------------
  heading "The manager cannot be switched off from inside the game"
  # It was possible until today and it bricked a test install: the routes go
  # with the mod, so nothing running can undo it, and the selection on disk
  # survives a restart still saying "off". Checked from all three directions --
  # the two routes that could do it, and the apply that would carry it out --
  # because a rule enforced in two doors out of three is a rule with a door.
  let toggleOff = call("/aowlspt/mods/toggle/" & ManagerId,
                       "{\"enabled\":false}")
  check("the panel's own toggle refuses to switch the manager off",
        toggleOff.ok and toggleOff.contains("\"ok\":false"), toggleOff.body)
  check("and says why, rather than just no",
        find(toggleOff.body, "Remove it from the install") >= 0,
        toggleOff.body)
  let disableManager = call("/aowlspt/mods/disable/" & ManagerId, "")
  check("and so does /disable", disableManager.ok and
        disableManager.contains("\"ok\":false"), disableManager.body)
  check("the panel marks the row as protected, so it can be drawn unswitchable",
        panelFieldOf(ManagerId, "protected") == "true",
        "protected=" & panelFieldOf(ManagerId, "protected"))
  check("and marks the ordinary rows as not protected",
        panelFieldOf(ServerId, "protected") == "false",
        "protected=" & panelFieldOf(ServerId, "protected"))
  check("the manager is still enabled after both attempts",
        panelFieldOf(ManagerId, "enabled") == "true",
        "enabled=" & panelFieldOf(ManagerId, "enabled"))
  let applyAfterRefusal = call("/aowlspt/mods/apply", "")
  check("an apply after them asks for nothing about the manager",
        applyAfterRefusal.ok and
        find(applyAfterRefusal.body, "\"id\":\"" & ManagerId &
             "\",\"action\":\"unload\"") < 0, applyAfterRefusal.body)
  cSleepMs(400'i32)
  check("and the host never unloaded it",
        unloadedCount(ManagerName) == 0,
        $unloadedCount(ManagerName) & " unload lines for the manager")
  check("the manager is still answering, which is the only proof that counts",
        call("/aowlspt/mods", "").contains("\"registryName\""),
        "the manager stopped answering")

  # -------------------------------------------------------------------------
  heading "Hostile input on every route that takes an id"
  # Six shapes of bad id, against each route that acts on one: nothing, an
  # empty document, a document of the wrong shape, an id the registry does not
  # have, four kilobytes of id, and ids carrying the characters that break
  # whatever reads them next -- quotes, backslashes, a NUL, and a byte that is
  # not UTF-8. Each has to come back with a reason and leave the selection
  # exactly as it was.
  # The fingerprint first, because every `refuses` and `survives` below makes
  # its second claim -- "changes nothing" -- by comparing this string before and
  # after. It is two `between` reads of two routes, and `between` answers ""
  # for a key it cannot find, so a fingerprint that reads nothing at all is a
  # constant: sixty-odd "changes nothing" checks would then compare "" with ""
  # and pass without the selection ever having been looked at. It has to carry
  # the list this run selected and the mods that list resolves to.
  let fingerprintNow = selectionFingerprint()
  check("the selection can be read back, so `changes nothing` is a real claim",
        find(fingerprintNow, "aowl.list.livectl") >= 0 and
        find(fingerprintNow, ServerId) >= 0 and
        find(fingerprintNow, TarkovId) >= 0,
        "the fingerprint of the whole selection is \"" & fingerprintNow & "\"")

  let huge = bigId(4096)
  let quoteId = "a\"b"
  let slashId = "a\\b"
  let nulId = "a" & $chr(0) & "b"
  let rawId = "a" & $chr(255) & "b"

  refuses("enable with no id at all", "/aowlspt/mods/enable/", "")
  refuses("enable with an empty document", "/aowlspt/mods/enable/", "{}")
  refuses("enable with an id that is an object",
          "/aowlspt/mods/enable/", "{\"id\":{\"nested\":true}}")
  refuses("enable with an id that is a number",
          "/aowlspt/mods/enable/", "{\"id\":7}")
  refuses("enable with an id nothing defines",
          "/aowlspt/mods/enable/no.such.mod", "")
  refuses("enable with four kilobytes of id", "/aowlspt/mods/enable/" & huge, "")
  refuses("enable with quotes in the id", "/aowlspt/mods/enable/",
          "{\"id\":\"" & quoteId & "\"}")
  refuses("enable with a backslash in the id", "/aowlspt/mods/enable/",
          "{\"id\":\"" & slashId & "\"}")
  refuses("enable with a NUL in the id", "/aowlspt/mods/enable/",
          "{\"id\":\"" & nulId & "\"}")
  refuses("enable with a byte that is not UTF-8", "/aowlspt/mods/enable/",
          "{\"id\":\"" & rawId & "\"}")

  # `disable` is the one that did *not* look its id up. Every one of these used
  # to be written into the player's selection store as an override on a mod
  # that does not exist, permanently, one per attempt.
  refuses("disable with no id at all", "/aowlspt/mods/disable/", "")
  refuses("disable with an empty document", "/aowlspt/mods/disable/", "{}")
  refuses("disable with an id nothing defines",
          "/aowlspt/mods/disable/no.such.mod", "")
  refuses("disable with four kilobytes of id",
          "/aowlspt/mods/disable/" & huge, "")
  refuses("disable with a NUL in the id", "/aowlspt/mods/disable/",
          "{\"id\":\"" & nulId & "\"}")
  refuses("disable with a byte that is not UTF-8", "/aowlspt/mods/disable/",
          "{\"id\":\"" & rawId & "\"}")

  refuses("clear with no id at all", "/aowlspt/mods/clear/", "")
  refuses("clear with an id nothing defines",
          "/aowlspt/mods/clear/no.such.mod", "")
  refuses("clear with a NUL in the id", "/aowlspt/mods/clear/",
          "{\"id\":\"" & nulId & "\"}")

  refuses("toggle with no id at all", "/aowlspt/mods/toggle/", "")
  refuses("toggle with an empty document", "/aowlspt/mods/toggle", "{}")
  refuses("toggle with an id nothing defines",
          "/aowlspt/mods/toggle/no.such.mod", "{\"enabled\":true}")
  refuses("toggle with four kilobytes of id",
          "/aowlspt/mods/toggle/" & huge, "{\"enabled\":true}")
  refuses("toggle with a NUL in the id", "/aowlspt/mods/toggle",
          "{\"id\":\"" & nulId & "\",\"enabled\":false}")

  refuses("describe with no id at all", "/aowlspt/mods/describe/", "")
  refuses("describe with an id nothing defines",
          "/aowlspt/mods/describe/no.such.mod", "")
  refuses("describe with a byte that is not UTF-8", "/aowlspt/mods/describe/",
          "{\"id\":\"" & rawId & "\"}")

  refuses("selecting a list nothing defines",
          "/aowlspt/mods/select/no.such.list", "")
  refuses("selecting a list with quotes in its id",
          "/aowlspt/mods/select/" & quoteId, "")

  heading "Hostile input on the routes that take a document"
  # The empty array is the one shape here that is *not* hostile: somebody who
  # sends `{"lists":[]}` means "no lists", and it is honoured. Everything else
  # that reads as empty -- a string, an object, an array of numbers -- used to
  # be honoured the same way and silently emptied the selection.
  refuses("select with no body at all", "/aowlspt/mods/select", "")
  refuses("select with an empty document", "/aowlspt/mods/select", "{}")
  refuses("select with lists as a string",
          "/aowlspt/mods/select", "{\"lists\":\"aowl.list.livectl\"}")
  refuses("select with lists as an object",
          "/aowlspt/mods/select", "{\"lists\":{\"a\":1}}")
  refuses("select with lists as an array of numbers",
          "/aowlspt/mods/select", "{\"lists\":[1,2,3]}")
  refuses("select with an empty id in the array",
          "/aowlspt/mods/select", "{\"lists\":[\"\"]}")
  refuses("select with a list nothing defines",
          "/aowlspt/mods/select", "{\"lists\":[\"no.such.list\"]}")
  refuses("select where one of several lists is bad -- all or nothing",
          "/aowlspt/mods/select",
          "{\"lists\":[\"aowl.list.livectl\",\"no.such.list\"]}")
  refuses("select with a NUL in a list id", "/aowlspt/mods/select",
          "{\"lists\":[\"" & nulId & "\"]}")

  refuses("a local list with a NUL in its id", "/aowlspt/mods/lists/local",
          "{\"id\":\"" & nulId & "\"}")
  refuses("a local list with four kilobytes of id",
          "/aowlspt/mods/lists/local", "{\"id\":\"" & huge & "\"}")
  refuses("a local list whose entries are not an array",
          "/aowlspt/mods/lists/local",
          "{\"id\":\"my.list\",\"entries\":\"aowl.tarkov\"}")
  refuses("a local list with an entry that is a path rather than an id",
          "/aowlspt/mods/lists/local",
          "{\"id\":\"my.list\",\"entries\":[{\"id\":\"../../etc/passwd\"}]}")
  refuses("a local list with an entry that has no id at all",
          "/aowlspt/mods/lists/local",
          "{\"id\":\"my.list\",\"entries\":[{\"enabled\":true}]}")
  refuses("a local list inheriting something that is not a list id",
          "/aowlspt/mods/lists/local",
          "{\"id\":\"my.list\",\"inherits\":[\"" & nulId & "\"]}")
  refuses("deleting a local list that does not exist",
          "/aowlspt/mods/lists/local/delete/no.such.list", "")
  refuses("deleting a local list with a NUL in its id",
          "/aowlspt/mods/lists/local/delete/",
          "{\"id\":\"" & nulId & "\"}")

  heading "Hostile input on the routes that only read"
  survives("the panel with a body that is not JSON",
           "/aowlspt/mods/panel", "not json at all")
  survives("the list route with a truncated document",
           "/aowlspt/mods/list", "{\"lists\":[")
  survives("the client route with an empty document",
           "/aowlspt/mods/client", "{}")
  survives("the client route with a version that is not a version",
           "/aowlspt/mods/client/" & bigId(200), "")
  survives("conflicts with four kilobytes of body",
           "/aowlspt/mods/conflicts", huge)
  survives("apply with a hostile body", "/aowlspt/mods/apply",
           "{\"id\":\"" & nulId & "\"}")
  survives("reload with a hostile body", "/aowlspt/mods/reload",
           "{\"registry\":\"../../etc\"}")
  survives("the registry status route with a hostile body",
           "/aowlspt/mods/registry", "{\"force\":\"yes\"}")
  survives("a fetch nobody configured", "/aowlspt/mods/registry/fetch", "{}")
  survives("a revert with nothing adopted", "/aowlspt/mods/registry/revert", "")

  check("and everything is still serving after all of it",
        call("/aowlspt/mods", "").contains("\"registryName\"") and
        call("/client/game/version/validate",
             "{\"version\":{\"major\":\"1.1.0\"}}").contains("isvalid"),
        "something stopped answering")

  heading "An empty array is a selection, and is honoured"
  # The other half of the rule above: `{"lists":[]}` is a person saying
  # "nothing", and it has to work, or the refusals would just be a route that
  # does not work.
  let emptied = call("/aowlspt/mods/select", "{\"lists\":[]}")
  check("selecting no lists at all is accepted",
        emptied.ok and emptied.contains("\"ok\":true"), emptied.body)
  let emptied2 = call("/aowlspt/mods", "").body
  check("and takes effect", arrayIsEmptyAt(emptied2, "\"activeLists\":["),
        reportsArray(emptied2, "\"activeLists\":["))
  let restored = call("/aowlspt/mods/select", "{\"lists\":[\"aowl.list.livectl\"]}")
  check("and naming the list again puts it back",
        restored.ok and restored.contains("aowl.list.livectl"), restored.body)

  # -------------------------------------------------------------------------
  heading "Two requests at once"
  # Routes run on the backend's worker pool and it takes no lock for a mod --
  # deliberately, because it can only serialise what it can see, which is a
  # session id. So the manager guards its own state, and this is where that is
  # checked: two requests genuinely in flight at the same moment, repeatedly,
  # and then the question that matters -- is what is left one of the outcomes
  # somebody asked for, or a mixture of two.
  var pairsAnswered = 0
  var i2 = 0
  while i2 < 12:
    if bothAtOnce("/aowlspt/mods/toggle/" & ServerId, "{\"enabled\":false}",
                  "/aowlspt/mods/toggle/" & ServerId, "{\"enabled\":true}"):
      inc pairsAnswered
    inc i2
  check("twelve pairs of simultaneous toggles all answered",
        pairsAnswered == 12, $pairsAnswered & " of 12 answered")
  check("the manager is still serving after them",
        call("/aowlspt/mods", "").contains("\"registryName\""),
        "the manager stopped answering")

  # The invariant. Two toggles of one mod may finish in either order, so both
  # "in the order" and "not in the order" are correct; what may not happen is
  # the panel and the resolution disagreeing, which is what a row assembled
  # while the resolution was being replaced looks like.
  let settledOrder = orderHas(ServerId)
  let settledPanel = panelFieldOf(ServerId, "enabled")
  check("the panel and the load order agree about what the selection is",
        (settledOrder and settledPanel == "true") or
        ((not settledOrder) and settledPanel == "false"),
        "the order says " & $settledOrder & " and the panel says " &
        settledPanel)
  check("and the panel still has exactly the three mods in it",
        rowCount(call("/aowlspt/mods/panel", "").body) == 3,
        $rowCount(call("/aowlspt/mods/panel", "").body) & " rows")

  # Two different mods at once. The failure this one is shaped for is a lost
  # update: both requests read the selection, both write it back, and one of
  # the two changes is gone with nothing saying so.
  discard call("/aowlspt/mods/enable/" & ServerId, "")
  var i3 = 0
  while i3 < 8:
    discard bothAtOnce("/aowlspt/mods/disable/" & ServerId, "",
                       "/aowlspt/mods/enable/" & TarkovId, "")
    discard bothAtOnce("/aowlspt/mods/enable/" & ServerId, "",
                       "/aowlspt/mods/clear/" & TarkovId, "")
    inc i3
  check("neither of two changes to different mods is lost",
        orderHas(ServerId) and orderHas(TarkovId),
        "the order is " & orderOf())
  check("and the emulator never stopped answering through it",
        call("/client/game/version/validate",
             "{\"version\":{\"major\":\"1.1.0\"}}").contains("isvalid"),
        "the emulator stopped answering")

  # A toggle against an apply. The apply talks to the host -- every load and
  # unload in it is an event the host answers on the same thread -- so this is
  # the pair most likely to be inside the mod at the same time, and it is the
  # one that used to be able to make the host's picture and the manager's
  # differ permanently.
  var i4 = 0
  while i4 < 6:
    discard bothAtOnce("/aowlspt/mods/apply", "",
                       "/aowlspt/mods/toggle/" & ServerId,
                       "{\"enabled\":false}")
    discard bothAtOnce("/aowlspt/mods/apply", "",
                       "/aowlspt/mods/toggle/" & ServerId,
                       "{\"enabled\":true}")
    inc i4
  # Settle: state the whole desired set once, with nothing else in flight, and
  # give the host its tick to answer.
  discard call("/aowlspt/mods/enable/" & ServerId, "")
  let settleApply = call("/aowlspt/mods/apply", "")
  check("a quiet apply after the storm is accepted and defers nothing",
        settleApply.ok and jsonNumber(settleApply.body, "deferred") == 0 and
        not settleApply.contains("\"outcome\":\"refused\""), settleApply.body)
  check("what the host is running is what the selection says",
        waitForLive(ServerId, "true", 40) == "true",
        "the panel says live=" & waitForLive(ServerId, "true", 1))
  check("and its route is answering, which is the fact behind that flag",
        waitUntilServed("/aowlspt/status", "aowl.gameserver", 40).contains(
          "aowl.gameserver"),
        "the mod is not answering after the concurrent applies")
  check("the emulator was never touched by any of it",
        loadedCount(TarkovName) == 1 and unloadedCount(TarkovName) == 0,
        $loadedCount(TarkovName) & " loads, " & $unloadedCount(TarkovName) &
        " unloads for " & TarkovName)

  # Reading while a change is in flight. The apply is left unanswered on its
  # own socket and the panel is polled underneath it: every one of those bodies
  # has to be a whole panel, not a row count that changes mid-document.
  let slowApply = openRequest("/aowlspt/mods/apply", "")
  var wholeBodies = 0
  var i5 = 0
  while i5 < 10:
    let p = call("/aowlspt/mods/panel", "")
    if p.ok and p.contains("\"ok\":true") and rowCount(p.body) == 3 and
       p.contains("\"summary\""):
      inc wholeBodies
    inc i5
  discard drain(slowApply)
  check("every panel read during an apply is a whole panel",
        wholeBodies == 10, $wholeBodies & " of 10 were complete")

  # And the client route, which is the one whose answer another *process* acts
  # on: a short or mixed body there is mods coming out of the running game.
  let slowApply2 = openRequest("/aowlspt/mods/apply", "")
  var wholeClient = 0
  var i6 = 0
  while i6 < 10:
    let c = call("/aowlspt/mods/client", "")
    if c.ok and c.contains("\"complete\":true") and
       jsonNumber(c.body, "count") == 3:
      inc wholeClient
    inc i6
  discard drain(slowApply2)
  check("and every client-set read during one is complete and counted",
        wholeClient == 10, $wholeClient & " of 10 were complete")

  heading "A registry refresh landing on an apply"
  # The fetch source is a file, so the adopt happens on the calling thread and
  # lands exactly where it is asked to rather than whenever a network gets
  # round to it. That makes "a refresh finished in the middle of an apply" a
  # thing this test can *cause* rather than wait for.
  var i7 = 0
  var fetchesAnswered = 0
  while i7 < 6:
    if bothAtOnce("/aowlspt/mods/registry/fetch", "",
                  "/aowlspt/mods/apply", ""):
      inc fetchesAnswered
    inc i7
  check("six fetches racing six applies all answered", fetchesAnswered == 6,
        $fetchesAnswered & " of 6")
  let afterFetch = call("/aowlspt/mods/registry", "")
  check("the fetched registry was adopted",
        afterFetch.contains("\"state\":\"adopted\""), afterFetch.body)
  let afterStatus = call("/aowlspt/mods", "")
  check("and it is the one in effect",
        afterStatus.contains("livectl fetched registry"), afterStatus.body)
  check("with all three mods still in it",
        jsonNumber(afterStatus.body, "mods") == 3, afterStatus.body)
  check("the load order survived the swap",
        orderHas(ServerId) and orderHas(TarkovId) and orderHas(ManagerId),
        "the order is " & orderOf())
  let settleAfterFetch = call("/aowlspt/mods/apply", "")
  check("and an apply against the adopted registry defers nothing",
        settleAfterFetch.ok and
        jsonNumber(settleAfterFetch.body, "deferred") == 0 and
        not settleAfterFetch.contains("\"outcome\":\"refused\""),
        settleAfterFetch.body)
  check("everything is still answering",
        call("/aowlspt/mods", "").contains("\"registryName\"") and
        call("/client/game/version/validate",
             "{\"version\":{\"major\":\"1.1.0\"}}").contains("isvalid") and
        waitUntilServed("/aowlspt/status", "aowl.gameserver", 40).contains(
          "aowl.gameserver"),
        "something stopped answering after the refresh")
  let reverted = call("/aowlspt/mods/registry/revert", "")
  check("and the adopted copy can be thrown away again",
        reverted.ok and reverted.contains("\"reverted\":true"), reverted.body)
  check("which puts the fixture registry back",
        call("/aowlspt/mods", "").contains("livectl fixture registry"),
        call("/aowlspt/mods", "").body)

  # -------------------------------------------------------------------------
  # Everything below restarts the backend, because what it is checking is what
  # the manager does with a selection file it did not write. There is no route
  # that produces one of those, which is the point: they arrive by a hand
  # edit, a half-finished write, or a disk that lost some bytes.
  let storePath = joinPath(gRoot, "store\\aowl.manager\\selection")

  heading "A hand-edited selection that says the manager is off"
  cSpawnKill(backendProc)
  cSleepMs(600'i32)
  var goodSelection = ""
  discard readTextFile(storePath, goodSelection)
  check("the manager did persist a selection to edit",
        goodSelection.len > 0, "nothing at " & storePath)
  discard writeTextFile(storePath,
    "{\"lists\":[\"aowl.list.livectl\"]," &
    "\"overrides\":[{\"id\":\"aowl.manager\",\"enabled\":false}," &
    "{\"id\":\"aowl.gameserver\",\"enabled\":false}],\"local\":[]}")
  backendProc = startBackend(backend)
  if backendProc == 0'u64:
    err "could not restart the backend"
    return 1
  check("the manager still answers with its own selection saying it is off",
        waitForManager(200), "no answer from /aowlspt/mods after the restart")
  check("and the row is still protected",
        panelFieldOf(ManagerId, "protected") == "true",
        "protected=" & panelFieldOf(ManagerId, "protected"))
  let contradiction = call("/aowlspt/mods", "")
  check("and the disagreement is said out loud rather than left on the row",
        find(contradiction.body, "protected and is still running") >= 0,
        contradiction.body)
  # The apply is what would carry the "manager off" out to the host, if
  # anything were willing to. The mod beside it *is* switched off by the same
  # document, which is what makes this a check on the protection rather than on
  # the manager having ignored the file.
  let applyEdited = call("/aowlspt/mods/apply", "")
  check("an apply against that selection is accepted",
        applyEdited.ok and applyEdited.contains("\"ok\":true"),
        applyEdited.body)
  check("and it does not ask the host to unload the manager",
        find(applyEdited.body, "\"id\":\"" & ManagerId &
             "\",\"action\":\"unload\"") < 0, applyEdited.body)
  check("the mod beside it was unloaded, so the file was honoured otherwise",
        waitForLogLine(" unloaded " & ServerName, 50),
        "no unload line for " & ServerName)
  check("and its route is gone",
        call("/aowlspt/status", "").contains("no route"),
        call("/aowlspt/status", "").body)
  cSleepMs(400'i32)
  check("and the host was never asked to unload the manager",
        unloadedCount(ManagerName) == 0,
        $unloadedCount(ManagerName) & " unload lines for the manager")
  let recovered = call("/aowlspt/mods/enable/" & ManagerId, "")
  check("switching it back on is allowed and is the way out",
        recovered.ok and recovered.contains("\"ok\":true"), recovered.body)
  check("and the disagreement goes with it",
        find(call("/aowlspt/mods", "").body, "protected and is still running") < 0,
        call("/aowlspt/mods", "").body)

  heading "A selection file that cannot be read"
  # The failure this whole section exists for: a manager that reads a damaged
  # selection as "nothing selected" and then saves that over it. The file is
  # compared byte for byte at the end, because "it refused" and "it refused and
  # then wrote anyway" answer identically on every route.
  cSpawnKill(backendProc)
  cSleepMs(600'i32)
  let damaged = "{\"lists\":[\"aowl.list.livectl\",\"my.raid"
  discard writeTextFile(storePath, damaged)
  backendProc = startBackend(backend)
  if backendProc == 0'u64:
    err "could not restart the backend"
    return 1
  check("the manager still starts and still answers",
        waitForManager(200), "no answer from /aowlspt/mods after the restart")
  let broken = call("/aowlspt/mods", "")
  check("and says the selection is not usable",
        broken.contains("\"selectionOk\":false"), broken.body)
  check("with a reason that names what is wrong with it",
        find(broken.body, "not one complete JSON object") >= 0, broken.body)
  check("it did not fall back to the config's defaults",
        arrayIsEmptyAt(broken.body, "\"activeLists\":["),
        reportsArray(broken.body, "\"activeLists\":["))
  check("and the log says so where somebody will see it",
        find(hostLog(), "no selection is in effect") >= 0 or
        find(hostLog(), "no mods are selected this run") >= 0,
        "nothing in the host log about the selection")
  let refusedChange = call("/aowlspt/mods/enable/" & TarkovId, "")
  check("a change is refused rather than taken and lost",
        refusedChange.ok and refusedChange.contains("\"ok\":false"),
        refusedChange.body)
  let refusedSelect = call("/aowlspt/mods/select",
                           "{\"lists\":[\"aowl.list.livectl\"]}")
  check("and so is choosing a list", refusedSelect.ok and
        refusedSelect.contains("\"ok\":false"), refusedSelect.body)
  let refusedLocal = call("/aowlspt/mods/lists/local",
                          "{\"id\":\"my.list\",\"entries\":[]}")
  check("and so is saving one of your own lists, which lives in the same file",
        refusedLocal.ok and refusedLocal.contains("\"ok\":false"),
        refusedLocal.body)
  discard call("/aowlspt/mods/apply", "")
  discard call("/aowlspt/mods/reload", "")
  cSpawnKill(backendProc)
  cSleepMs(600'i32)
  var afterAll = ""
  discard readTextFile(storePath, afterAll)
  check("and the file is exactly as it was left, byte for byte",
        afterAll == damaged,
        "it is now " & $afterAll.len & " bytes, was " & $damaged.len)

  heading "Missing is not the same as unreadable"
  # The distinction `Stored.missing` exists for. With no file at all, seeding
  # from `config.json` is right and is what a first run needs; with a file it
  # could not read, seeding is how a setup gets overwritten. Same code path,
  # opposite correct answers, so both are checked.
  discard removeFileAt(storePath)
  backendProc = startBackend(backend)
  if backendProc == 0'u64:
    err "could not restart the backend"
    return 1
  check("with no stored selection the manager starts and answers",
        waitForManager(200), "no answer from /aowlspt/mods after the restart")
  let fresh = call("/aowlspt/mods", "")
  check("it seeds the config's default lists",
        find(fresh.body, "aowl.list.livectl") >= 0, fresh.body)
  check("and reports the selection as usable",
        fresh.contains("\"selectionOk\":true"), fresh.body)
  let firstChange = call("/aowlspt/mods/disable/" & ServerId, "")
  check("a change is taken again",
        firstChange.ok and firstChange.contains("\"ok\":true"),
        firstChange.body)
  check("and says it reached the disk",
        firstChange.contains("\"persisted\":true"), firstChange.body)

  if not keep:
    cSpawnKill(backendProc)

  heading "Result"
  if gFailures > 0:
    err $gFailures & " of " & $gChecks & " failed"
    return 1
  ok "live mod control answered all " & $gChecks & " checks"
  result = 0

quit(main())
