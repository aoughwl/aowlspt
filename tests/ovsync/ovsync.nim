## ovsync -- the client half of live mod control, driven end to end.
##
##     ovsync --root <scratch> --backend <aowlspt-backend.exe>
##            --manager <manager.dll> [--port 7050] [--broken dead|nomanager]
##
## `livectl` proves the **server** half: a mod switched off and on again while
## the backend serves, 213 checks, none of which leave the backend's process.
## `modreport` and `modclient` prove both ends of the *wire*: the host builds a
## query string and the manager reads one, each with the other end written out
## by hand. What none of the three establishes is the thing in between -- that
## the query string this host builds actually **reaches** the backend, and that
## the backend's answer comes back into the client host's parsed state. That is
## `aowl_ov_sync_start` and the overlay's worker thread, and until this file it
## had been driven by hand only.
##
## So this is the round trip, with nothing stood in for:
##
##   * a real `aowlspt-backend.exe`, on its own root and its own port, with the
##     real `manager.dll` staged into it and a three-mod registry written here;
##   * the real worker thread out of `abi/aowlspt_overlay.h`, started through
##     `host/Aowlspt.Overlay/aowloverlay.nim` -- the same two lines the client
##     host uses, `overlayStart` then `overlaySyncStart`, and no HTTP client of
##     this program's own anywhere near the feed;
##   * the real reader, `host/common/modcontrol.nim`: `parseDesired` for what
##     came back and `reportPath` for what goes up next time.
##
## The one thing that is *not* the client host is the mod table underneath
## `applyDesired`: there is no game here, so `HostOps` says nothing is loaded
## and no library exists. That is deliberate rather than a shortcut -- the
## outcomes it produces (`noop` for the settled rows, `nofile` for a client mod
## whose dll is on the other machine) are real outcomes with real letters, and
## what is under test is whether they survive the trip to the manager, not
## whether `LoadLibrary` works. `modreport` already covers every other outcome.
##
## **What each check is really watching for**
##
## *The answer comes back.* A worker that never publishes and a worker that
## publishes rubbish look identical to a host that only checks "did I get a
## body": both leave `overlaySyncTake` empty most of the time by design. So the
## first body is waited for with a deadline and then *parsed*, and the parse is
## `parseDesired`, which refuses a 404, an error page and a truncated document.
##
## *It comes back uncompressed.* The backend zlib-deflates every response, and
## the worker drops any body starting `0x78` on the floor rather than hand the
## host half a decision. The overlay asks for `Accept-Encoding: identity`; the
## header's own comment says the backend ignores that. It does not any more
## (`backend/aowlbackend.nim:515`), and if it ever does again this feed stops
## dead with no error anywhere -- so the byte is checked here by name.
##
## *A change made on the server reaches the client's parsed state.* Not "a
## request happened" and not "the body changed": the mod is toggled through the
## manager's own route, a **new** body is waited for, and the assertion is on
## `DesiredMod.enabled` for that guid, on this side, after `parseDesired`. Both
## directions, because a feed that publishes once and then latches passes the
## off case alone.
##
## *And the query string goes the other way.* The last checks record outcomes
## through `applyDesired`, build the path with `reportPath`, hand **that** path
## to `aowl_ov_sync_start`, and then read `/aowlspt/mods/clientreport` to see
## the manager holding this process's session, sequence and outcome letters.
## This is the sentence in `docs/BACKLOG.md` -- "the query string reaches the
## backend" -- turned into an assertion.
##
## Wired into `aowl test` under "Live mod control", after `livectl`. To run it
## alone:
##
##   nimony c --passC:-I<repo>\abi --passL:-lws2_32 --passL:-lz
##            -p:<repo>\backend -p:<repo>\host\common
##            -p:<repo>\host\Aowlspt.Overlay -p:<repo>\installer\src
##            -p:<repo>\aowl\src -o:ovsync.exe ovsync.nim
##
## `--broken` is how this file proves it can fail. `dead` starts the overlay
## against a port nothing is listening on -- the backend is up, the manager is
## fine, and the *feed* is broken. `nomanager` stages the root without
## `manager.dll`, so the backend answers and the route does not exist. Neither
## is a mode anything but a person at a terminal should run.

import std/[strutils, syncio, cmdline]
import aowlsptinstall/[winfs, log]
import wire
import modcontrol
import aowloverlay

# `aowlspt_net.h` first, and that order is not taste: it pulls in `winsock2.h`,
# and every other header here pulls in `windows.h`, which defines the winsock 1
# names and makes the 2 header warn that it is too late.
{.emit: """#include "aowlspt_net.h" """.}
{.emit: """#include "aowlspt_shim.h" """.}
{.emit: """#include "aowlspt_inject.h" """.}
# `aowlspt_net.h` is here for one call, `cNetStartup`. `{.emit.}` is
# module-scoped, so importing `wire` brings the *procs* into scope and leaves
# their declarations in wire's translation unit; without this line the C
# compiler sees `aowl_net_startup()` with no prototype and the build fails
# naming a function this file never wrote.

proc cSpawn(exe, workDir, cmdLine: cstring): uint64 {.
  importc: "aowl_spawn", nodecl.}
proc cSpawnKill(h: uint64) {.importc: "aowl_spawn_kill", nodecl.}
proc cSleepMs(ms: int32) {.importc: "aowl_sys_sleep", nodecl.}

proc patchFired(slot: int32; regs: pointer): int32 {.
  exportc: "aowlspt_nim_patch_fired", cdecl.} =
  ## `aowlspt_detour.h` emits its thunk pool unconditionally and the thunks
  ## call these two, so any binary that includes the overlay has to define
  ## them. Unreachable here: the overlay's own detours are C functions with the
  ## right signature and never route through a thunk, and this program installs
  ## no hooks of its own.
  0'i32

proc patchReturned(slot: int32; regs: pointer): int32 {.
  exportc: "aowlspt_nim_patch_returned", cdecl.} =
  0'i32

const
  Usage = """
ovsync -- the client half of live mod control, over the real worker thread

  ovsync --root PATH --backend PATH --manager PATH [--port N]

  --root PATH      a scratch install of its own; the registry, the manager's
                   config and the manager dll are put there by this tool
  --backend PATH   aowlspt-backend.exe
  --manager PATH   manager.dll, as built into mods\manager\bin
  --port N         port to serve on (default 7057)
  --broken WHICH   the red case: `dead` points the worker at a closed port,
                   `nomanager` stages a root the manager is not in
  --keep           leave the backend running at the end
  -h, --help       this
"""

  Session = "0badc0de12345678"
    ## This process, as the client host names itself. Sixteen hex characters
    ## because that is `MaxSessionLen` in `mgr/clientreport.nim` and a
    ## seventeenth would be silently refused as "not a session".

  HttpSession = "aaaaaaaaaaaaaaaaaaaaaaaa"
    ## The cookie on the requests *this* tool makes to drive the manager. It
    ## has nothing to do with `Session` above, which travels in the query
    ## string of the worker's poll; the two are deliberately different so a
    ## check that passes by reading the wrong one cannot exist.

  ClientId = "aowl.ovsync.client"
  ManagerId = "aowl.manager"
  ServerId = "aowl.gameserver"
  ClientVersion = "0.1.0"
    ## The client host's own version, which the manager range-checks `pipeline`
    ## against. It rides in the path, which is why the base below has it.

  Base = "/aowlspt/mods/client/" & ClientVersion

  # Three mods and one list, written here rather than taken from
  # `registry/mods.json`, for the reason `livectl` gives: the counts and ids
  # below are this file's fixture and must not be changeable from a document
  # about what ships.
  #
  # The mod under test is `aowl.ovsync.client`, which is **client-only**. That
  # is the whole point of the route being tested: on the server's own
  # resolution it is `wrong-side` and reads as disabled, and a client host
  # obeying *that* answer would unload everything it has. The manager resolves
  # again with `client` as the side for this route, and this registry is shaped
  # so that the two answers differ -- one mod on each side of the line, so a
  # feed accidentally wired to `/panel` fails rather than passes.
  RegistryDoc = """{
  "schema": "aowlspt.registry/1",
  "registry": {
    "id": "aowl.registry.ovsync",
    "name": "ovsync fixture registry",
    "description": "Three mods and one list, written by tests/ovsync/ovsync.nim. Not a shipping registry."
  },
  "mods": [
    {
      "id": "aowl.manager",
      "name": "Mod Manager",
      "author": "aowlspt",
      "version": "1.0.0",
      "description": "The far end of the feed under test.",
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
      "id": "aowl.gameserver",
      "name": "Game Server",
      "author": "aowlspt",
      "version": "0.1.0",
      "description": "A server-side mod that must read as disabled on the client and never move.",
      "pipeline": ">=0.1.0",
      "sides": ["server"],
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
    },
    {
      "id": "aowl.ovsync.client",
      "name": "ovsync client mod",
      "author": "aowlspt",
      "version": "0.1.0",
      "description": "The mod this run switches off and on. Client-only, and installed on no machine: what is under test is whether the decision about it makes the round trip, not whether a dll loads.",
      "pipeline": ">=0.1.0",
      "sides": ["client"],
      "source": { "kind": "intree", "path": "tests/ovsync", "url": null },
      "artifact": { "dir": "ovclient", "library": "ovclient.dll" },
      "upstream": null,
      "license": "see repository",
      "download": null,
      "requires": [],
      "conflicts": [],
      "provides": [],
      "loadAfter": [],
      "tags": ["client"]
    }
  ],
  "lists": [
    {
      "id": "aowl.list.ovsync",
      "name": "ovsync",
      "author": "aowlspt",
      "version": "1.0.0",
      "description": "All three, on.",
      "inherits": [],
      "entries": [
        { "id": "aowl.manager", "enabled": true },
        { "id": "aowl.gameserver", "enabled": true },
        { "id": "aowl.ovsync.client", "enabled": true }
      ]
    }
  ]
}
"""

  ManagerConfig = """{
  "registryPath": "",
  "activeLists": ["aowl.list.ovsync"],
  "controlProbeMs": 750,
  "writeSelectionFile": true,
  "registryFetchEnabled": false,
  "registryFetchOnStart": false,
  "registryUrl": ""
}
"""

var gFailures = 0
var gChecks = 0
var gPort = 7057
var gRoot = ""

proc check(what: string; condition: bool; detail = "") =
  inc gChecks
  if condition:
    ok what
  else:
    err what & (if detail.len > 0: ": " & detail else: "")
    inc gFailures

proc call(path, body: string): Response =
  result = request(gPort, path, body, HttpSession)

proc jsonNumber(body, key: string): int =
  ## `"key":123`, or -1 when the key is not there -- which has to be distinct
  ## from 0, because 0 is a value some of the fields below legitimately have.
  let at = find(body, "\"" & key & "\":")
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

proc jsonText(body, key: string): string =
  let at = find(body, "\"" & key & "\":\"")
  if at < 0:
    return ""
  var i = at + key.len + 4
  result = ""
  while i < body.len and body[i] != '"':
    result.add body[i]
    inc i

proc rowOf(body, id: string): string =
  ## The `{...}` object in a `mods` array whose `"id"` or `"guid"` is `id`.
  ## Needed because every row uses the same key names, so a document-wide
  ## `find` for `"letter"` answers about whichever mod happens to be first.
  let at = find(body, "\"" & id & "\"")
  if at < 0:
    return ""
  var start = at
  while start > 0 and body[start] != '{':
    dec start
  var stop = at
  while stop < body.len and body[stop] != '}':
    inc stop
  if stop >= body.len:
    return ""
  result = body.substr(start, stop)

# ---------------------------------------------------------------------------
# The parsed set, as the client host holds it
# ---------------------------------------------------------------------------

proc rowFor(set1: seq[DesiredMod]; guid: string; into: var DesiredMod): bool =
  result = false
  for d in set1:
    if d.guid == guid:
      into = d
      return true

# A `HostOps` for a process with no mods in it.
#
# Every answer here is the truth about this program: nothing is loaded, nothing
# can be loaded, and the paths the backend names do not exist on this side. The
# outcomes that produces -- `noop` for a row already in the state the backend
# wants, `nofile` for a client mod whose dll lives on the other machine -- are
# the two a real client host produces most of the time, and they are what the
# report checks at the bottom assert on.
var gLog: seq[string] = @[]
proc opCount(): int = 0
proc opText(i: int): string = ""
proc opLive(i: int): bool = false
proc opFlags(i: int): uint32 = 0'u32
proc opIndex(guid: string): int = -1
proc opCanUnload(i: int): bool = false
proc opLoad(path: string): bool = false
proc opUnload(guid: string): string = "there is no mod table in this process"
proc opLog(m: string) = gLog.add m
proc opEmit(name, payload: string) = discard

# ---------------------------------------------------------------------------
# Staging and starting
# ---------------------------------------------------------------------------

proc stageFixture(managerDll: string; withManager: bool): bool =
  ## The root is built here, from nothing, every run. `livectl` is handed a
  ## root somebody else staged; this one stages its own, because it is meant to
  ## be runnable against a scratch directory that did not exist a second ago
  ## and because sharing a root with another gate would have each run's
  ## leftovers decide the other's starting state.
  result = true
  discard removeTree(gRoot)
  discard ensureDir(gRoot)
  discard ensureDir(joinPath(gRoot, "registry"))
  discard ensureDir(joinPath(gRoot, "mods\\manager"))
  # The client host's own mods directory: empty, and it stays empty. It is what
  # `applyDesired` resolves artifact paths against, and the client mod not
  # being in it is the fact the `nofile` outcome reports.
  discard ensureDir(joinPath(gRoot, "clientmods"))
  if withManager:
    if not fileExists(managerDll):
      err "no manager dll at " & managerDll
      return false
    if not copyFileAt(managerDll,
                      joinPath(gRoot, "mods\\manager\\manager.dll")).ok:
      err "could not stage manager.dll"
      return false
    if not writeTextFile(joinPath(gRoot, "mods\\manager\\config.json"),
                         ManagerConfig).ok:
      err "could not write the manager's config"
      return false
  if not writeTextFile(joinPath(gRoot, "registry\\mods.json"), RegistryDoc).ok:
    err "could not write the fixture registry"
    return false

proc startBackend(exe: string): uint64 =
  var e = exe
  var w = gRoot
  var c = "\"" & exe & "\" --root \"" & gRoot & "\" --port " & $gPort
  result = cSpawn(toCString(e), toCString(w), toCString(c))

proc waitForBackend(tries: int; needManager: bool): bool =
  ## Polled, not slept: the backend binds a port, loads a mod and parses a
  ## registry first. With no manager staged there is no `/aowlspt/mods` to
  ## wait for, so what is waited for instead is the backend answering *at all*
  ## -- `/aowlspt/status` with no mod behind it is a `no route`, which is a
  ## reply and proves the server is up.
  var i = 0
  while i < tries:
    let r = call((if needManager: "/aowlspt/mods" else: "/aowlspt/status"), "")
    if r.ok and ((not needManager) or r.contains("\"registryName\"")):
      return true
    cSleepMs(200'i32)
    inc i
  result = false

# ---------------------------------------------------------------------------
# The feed
# ---------------------------------------------------------------------------

proc takeWithin(ms: int): string =
  ## The next whole body the worker publishes, or "" if it does not publish one
  ## in time. Polled at 50 ms because that is the worker's own tick; the feed
  ## interval is 250, so a deadline under half a second is a flake and one over
  ## a few seconds is a hang being called a failure.
  result = ""
  var waited = 0
  while waited < ms:
    let body = overlaySyncTake()
    if body.len > 0:
      return body
    cSleepMs(50'i32)
    waited = waited + 50

proc parsedWithin(ms: int; set1: var seq[DesiredMod]; raw: var string;
                  error: var string): bool =
  ## One fresh body, parsed. The two are together because a body that arrives
  ## and does not parse is not "no answer yet" -- it is an answer this host
  ## must refuse, and the difference is what `error` carries.
  raw = takeWithin(ms)
  error = ""
  set1 = @[]
  if raw.len == 0:
    error = "the worker published no body"
    return false
  result = parseDesired(raw, set1, error)

proc waitForFlag(ms: int; guid: string; want: bool; raw: var string;
                 error: var string): bool =
  ## Bodies until one of them says `guid` is `want`, or the deadline.
  ##
  ## Waiting rather than reading once is not politeness about timing: the feed
  ## is a poll on a 250 ms timer and the toggle went in over a different
  ## socket, so the body in flight when the toggle landed is entitled to carry
  ## the old answer. What is being asserted is that the new one arrives, which
  ## is a statement about the worker and not about this program's patience.
  result = false
  error = ""
  var waited = 0
  while waited < ms:
    var set1: seq[DesiredMod] = @[]
    var err1 = ""
    var body = ""
    if parsedWithin(400, set1, body, err1):
      raw = body
      var row = DesiredMod(guid: "", enabled: false, dir: "", lib: "")
      if rowFor(set1, guid, row) and row.enabled == want:
        return true
    elif body.len > 0:
      # A body that arrived and would not parse is worth carrying out of here:
      # it is the difference between "the far end is quiet" and "the far end is
      # answering something this host refuses", and the second one is a failure
      # with a cause in it.
      error = err1
    waited = waited + 400
  if error.len == 0:
    error = "no body said " & guid & " is " &
            (if want: "enabled" else: "disabled")

# ---------------------------------------------------------------------------

proc main(): int =
  var backend = ""
  var managerDll = ""
  var broken = ""
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
    elif a == "--manager":
      inc i
      if i <= n: managerDll = paramStr(i)
    elif a == "--broken":
      inc i
      if i <= n: broken = paramStr(i)
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

  # Absolute before anything uses it: the child is started **with its working
  # directory set to the root** and `--root` on its command line, and a
  # relative root is then resolved twice -- once by this process and once by
  # the backend against its new cwd, which lands it in `<root>/<root>` and
  # works perfectly in the wrong place.
  if gRoot.len > 0:
    gRoot = absolutePathOf(gRoot)
  if gRoot.len == 0 or backend.len == 0 or managerDll.len == 0:
    echo Usage
    return 1
  if not fileExists(backend):
    err "no backend at " & backend
    return 1
  if broken.len > 0 and broken != "dead" and broken != "nomanager":
    err "--broken takes `dead` or `nomanager`, not " & broken
    return 1

  discard cNetStartup()

  heading "Staging"
  let withManager = broken != "nomanager"
  if not stageFixture(managerDll, withManager):
    return 1
  ok "a registry" & (if withManager: ", the manager's config and manager.dll"
                     else: " and no manager (--broken nomanager)") &
     " in " & gRoot

  heading "Starting"
  let backendProc = startBackend(backend)
  if backendProc == 0'u64:
    err "could not start the backend"
    return 1
  if not waitForBackend(80, withManager):
    err "the backend never answered on port " & $gPort
    cSpawnKill(backendProc)
    return 1
  ok "the backend is serving on " & $gPort

  if withManager:
    let status = call("/aowlspt/mods", "")
    check("the manager read the fixture registry, three mods and one list",
          status.contains("\"ok\":true") and jsonNumber(status.body, "mods") == 3,
          status.body)

  # -------------------------------------------------------------- the worker
  #
  # This is the part nothing else in the repository does. `overlayStart` with a
  # port is what creates the worker thread -- the same call the client host
  # makes out of `aowlspt_hostboot.h` -- and `overlaySyncStart` is what points
  # it at a route. Everything after this line is read back through
  # `overlaySyncTake`; this program never fetches the client set itself, which
  # is the only way the checks below say anything about the worker.
  heading "The worker"
  let feedPort = (if broken == "dead": gPort + 400 else: gPort)
  # `dead` is a port in the same private range with nothing bound to it. The
  # backend is up and the manager is fine; what is broken is the feed, which is
  # the one failure this gate exists to be able to see.
  let drew = overlayStart(VkF9, int32(feedPort))
  if not drew:
    # Not a failure. A console process with no swap chain cannot install the
    # Present detour, and the header is explicit that the worker runs anyway --
    # that is the property that lets a host which cannot draw still obey the
    # manager, and this program depends on it.
    note "the overlay cannot draw here (" & overlayStatus() &
         "), which is expected in a console process; the worker runs regardless"
  check("the overlay is started, so the worker thread exists",
        overlayRunning(), overlayStatus())

  reportSession(Session)
  controlInit("ovsync", ClientVersion, 2'i32, opEmit,
              HostOps(count: opCount, guidOf: opText, nameOf: opText,
                      versionOf: opText, pathOf: opText, liveOf: opLive,
                      flagsOf: opFlags, indexOf: opIndex,
                      canUnload: opCanUnload, load: opLoad, unload: opUnload,
                      log: opLog))
  overlaySyncStart(Base, 250'i32)

  var firstRaw = ""
  var firstErr = ""
  var want: seq[DesiredMod] = @[]
  let gotFirst = parsedWithin(8000, want, firstRaw, firstErr)
  check("the worker fetched the client set with no request from this thread",
        firstRaw.len > 0, firstErr)
  check("the body came back uncompressed, so the worker's " &
        "Accept-Encoding: identity was honoured",
        firstRaw.len > 0 and firstRaw[0] == '{',
        (if firstRaw.len > 0 and firstRaw[0] == '\x78':
           "it starts 0x78: the backend deflated it and the worker would have dropped it"
         else: "the body starts " & firstRaw.substr(0, 20)))
  check("and it parses as aowlspt.clientset/1 on the client side",
        gotFirst, firstErr)
  check("with a row for every mod in the registry", want.len == 3,
        $want.len & " rows")

  var clientRow = DesiredMod(guid: "", enabled: false, dir: "", lib: "")
  check("the client-only mod is enabled in the answer the client is given",
        rowFor(want, ClientId, clientRow) and clientRow.enabled,
        firstRaw)
  check("and it carries the artifact's relative location, never a path",
        clientRow.dir == "ovclient" and clientRow.lib == "ovclient.dll",
        clientRow.dir & " / " & clientRow.lib)
  var serverRow = DesiredMod(guid: "", enabled: false, dir: "", lib: "")
  check("the server-side mods are disabled in it, which is the client " &
        "resolution and not the panel's",
        rowFor(want, ServerId, serverRow) and not serverRow.enabled and
        rowFor(want, ManagerId, serverRow) and not serverRow.enabled,
        firstRaw)
  check("taking the same body twice yields nothing the second time",
        overlaySyncTake().len == 0,
        "the feed handed the same body out again")

  # ---------------------------------------------------------- the round trip
  heading "The round trip"
  let off = call("/aowlspt/mods/disable/" & ClientId, "")
  check("disabling the client mod through the manager's route is accepted",
        off.ok and off.contains("\"ok\":true"), off.body)
  var offRaw = ""
  var offErr = ""
  check("the change reaches the worker's parsed state on the client side",
        waitForFlag(8000, ClientId, false, offRaw, offErr), offErr)
  var afterOff: seq[DesiredMod] = @[]
  var parseErr = ""
  discard parseDesired(offRaw, afterOff, parseErr)
  check("and nothing else in the set moved with it",
        afterOff.len == 3 and rowFor(afterOff, ServerId, serverRow) and
        not serverRow.enabled, offRaw)

  let on = call("/aowlspt/mods/enable/" & ClientId, "")
  check("enabling it again is accepted", on.ok and on.contains("\"ok\":true"),
        on.body)
  var onRaw = ""
  var onErr = ""
  check("and the client side sees it enabled again, so the feed is not a " &
        "latch that fires once",
        waitForFlag(8000, ClientId, true, onRaw, onErr), onErr)

  # ------------------------------------------------- the query string upward
  #
  # The other direction of the same wire, and the sentence in `docs/BACKLOG.md`
  # this file exists to close. `applyDesired` records what became of each row,
  # `reportPath` puts it in a query string, and the *worker* carries it -- this
  # program does not send it. What is read back is the manager's own ledger.
  heading "The report the poll carries"
  var current: seq[DesiredMod] = @[]
  var curErr = ""
  discard parseDesired(onRaw, current, curErr)
  applyDesired(current, joinPath(gRoot, "clientmods"))
  let path = reportPath(Base)
  check("the host has something to report after applying the set",
        path.len > Base.len and find(path, "?hs=" & Session) >= 0, path)
  check("and the whole report fits the 191 characters the worker copies",
        path.len <= ReportMaxPath, $path.len & " characters: " & path)
  check("the client-only mod is reported as skipped because its library is " &
        "installed on the other machine",
        find(path, ClientId & "~+s~" & CodeNoFile) >= 0, path)

  overlaySyncStart(path, 250'i32)
  # Waited for in the manager, not slept for: the report is taken on the poll,
  # and the poll is on the worker's timer.
  var seen = ""
  var tries = 0
  while tries < 40:
    let r = call("/aowlspt/mods/clientreport", "")
    if r.ok and jsonText(r.body, "session") == Session:
      seen = r.body
      break
    cSleepMs(200'i32)
    inc tries
  check("the manager received the session the client host put in the " &
        "query string, so the string reached the backend",
        seen.len > 0 and jsonText(seen, "session") == Session,
        (if seen.len > 0: seen else: call("/aowlspt/mods/clientreport", "").body))
  check("and it says a client host is reporting",
        find(seen, "\"reporting\":true") >= 0, seen)
  check("with the sequence number this host stamped on it",
        jsonNumber(seen, "seq") == reportSeq(),
        "the manager holds " & $jsonNumber(seen, "seq") & ", the host sent " &
        $reportSeq())
  let mrow = rowOf(seen, ClientId)
  check("and the outcome the host recorded for the client-only mod, by letter",
        jsonText(mrow, "letter") == "s" and jsonText(mrow, "code") == CodeNoFile,
        mrow)
  check("the settled server-side rows arrive as noop, not as silence",
        jsonText(rowOf(seen, ManagerId), "letter") == "n", rowOf(seen, ManagerId))
  check("and the feed is still serving the set after all of it",
        takeWithin(4000).len > 0,
        "the worker stopped publishing once the path grew a query string")

  overlayStop()
  if not keep:
    cSpawnKill(backendProc)

  heading "Result"
  if gFailures > 0:
    err $gFailures & " of " & $gChecks & " failed"
    return 1
  ok "the client half of live mod control answered all " & $gChecks & " checks"
  result = 0

quit(main())
