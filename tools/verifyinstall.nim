## aowlspt-verify -- check that an aowlspt install is complete, and that it
## actually serves.
##
##     aowlspt-verify                          from inside an install
##     aowlspt-verify --root D:\Aowlspt
##     aowlspt-verify --root D:\Aowlspt --offline    do not start anything
##     aowlspt-verify --root D:\Aowlspt --port 6978
##
## This is what `tools/aowlspt-verify-live.ps1` was, moved across the 1.0 line
## and into nimony.
##
## That script proved the server host worked inside a **real SPT server**: it
## copied SPT_Runtime and SPT_Data into a sandbox, deployed the host with
## `aowlspt-deploy.ps1`, started `SPT.Server.exe`, and grepped its log. Every one
## of those pieces is gone. SPT's server targets `0.16.9.40743`, a pre-1.0
## client, and building on it is the one thing this project refuses to do; the
## backend is ours now, and the two PowerShell scripts it drove were replaced by
## `aowl`. What survived is the *shape* of the check, which was the valuable
## part: stand up the real server, over the real wire, and ask it things.
##
## So the sandbox is gone too, and that is the biggest change. There is nothing
## to copy 800 MB out of -- the thing being verified is an install
## `aowlspt-install` already built, whose entire reason for existing is that it
## is separate from the install BSG's launcher maintains. Verifying it in place
## is verifying the real artifact.
##
## `installer/build/aowlspt-install.exe verify` is a different check and both
## are worth having: that one asks whether the files the installer wrote are
## still where it left them, from the uninstall manifest. This one asks whether
## what is there adds up to a working install -- a host, a launcher, a backend, a
## registry, and mods that are libraries rather than empty directories -- and
## then starts the backend and talks to it.
##
## **It writes only inside `<root>\aowlspt`**, and only what the backend itself
## writes when it runs: its log and its mod store. It never touches the vanilla
## install the target was mirrored from, and it refuses to start anything when
## `<root>\aowlspt\aowlspt-backend.exe` is not there -- which is the same as
## saying it will not run against somebody else's game directory.

import std/[strutils, syncio, cmdline]
import aowlsptinstall/[winfs, log, eft, journal, registry]
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
aowlspt-verify -- check an aowlspt install is complete, and that it serves

  aowlspt-verify [--root PATH] [options]

  --root PATH    the install to check (default: the directory this exe is in,
                 or the one above it when this exe sits in aowlspt\)
  --offline      check the files and stop; start nothing
  --staged       the root is a staged payload, not an install: no client here
  --port N       port for the live check (default 6978, not the play port)
  --keep         leave the backend running at the end
  -q, --quiet    findings only
  -h, --help     this
"""
  Session = "aaaaaaaaaaaaaaaaaaaaaaaa"

proc printLines(lines: seq[string]; indent: string = "") =
  for l in lines:
    line indent & l

proc head(s: string; n: int): string =
  ## The first `n` characters, for putting a response body in an error message.
  ## `substr` past the end is not something to find out about from a crash in a
  ## diagnostic.
  if s.len <= n:
    result = s
  else:
    result = s.substr(0, n - 1) & " ..."

proc unquoted(s: string): string =
  ## One id out of a JSON array written as text: brackets, quotes and spaces
  ## off. Hand-rolled rather than reached for in `strutils`, because the only
  ## input is a value this program read out of a config it also knows the shape
  ## of, and a parser would be more machinery than the job.
  result = ""
  for ch in s:
    if ch == '[' or ch == ']' or ch == '"' or ch <= ' ':
      # Anything at or below a space is whitespace here; the value came
      # out of a config file and may be wrapped over lines.
      continue
    result.add ch

proc numberOf(body, key: string): int =
  ## `"key":123`, or -1 when the key is not there. -1 rather than 0 because 0 is
  ## a value the fields below legitimately have, and "the field said zero" and
  ## "there is no such field" are the two answers this file must not confuse.
  let k = "\"" & key & "\":"
  let at = find(body, k)
  if at < 0:
    return -1
  var i = at + k.len
  var v = 0
  var any = false
  while i < body.len and body[i] >= '0' and body[i] <= '9':
    v = v * 10 + (ord(body[i]) - ord('0'))
    any = true
    inc i
  if not any:
    return -1
  result = v

proc textOf(body, key: string): string =
  ## `"key":"value"`, or "" when there is no such key. The caller has to know
  ## which it got, so it asks `hasKey` first.
  let k = "\"" & key & "\":\""
  let at = find(body, k)
  if at < 0:
    return ""
  var i = at + k.len
  result = ""
  while i < body.len and body[i] != '"':
    result.add body[i]
    inc i

proc hasKey(body, key: string): bool =
  result = find(body, "\"" & key & "\":") >= 0

proc idsOf(arrayText: string): seq[string] =
  ## The ids in `["a","b"]`, split on commas.
  result = @[]
  var cur = ""
  for ch in arrayText:
    if ch == ',':
      let id = unquoted(cur)
      if id.len > 0: result.add id
      cur = ""
    else:
      cur.add ch
  let last = unquoted(cur)
  if last.len > 0: result.add last

var gStaged = false
## Whether the live half actually ran. The final line of this program used to
## say "this install is complete and serves" whatever happened -- including
## after `--offline`, which starts nothing, and after the skip below, which
## starts nothing either. A tool that reports a server answering when it never
## opened a socket is the exact failure it exists to catch, so the claim is now
## made only by the code that earned it.
var gServed = false
var gFailures = 0
var gWarnings = 0
var gChecks = 0

proc check(what: string; condition: bool; detail = "") =
  inc gChecks
  if condition:
    ok what
  else:
    err what & (if detail.len > 0: ": " & detail else: "")
    inc gFailures

proc soft(what: string; condition: bool; detail = "") =
  ## A finding that is worth saying and is not a failure. The distinction is
  ## the whole usefulness of this tool: an install missing a mod's `data/` is
  ## broken, an install with no `db.json` is merely running on the emulator's
  ## fallbacks, and reporting both as "FAIL" would train people to ignore it.
  inc gChecks
  if condition:
    ok what
  else:
    warn what & (if detail.len > 0: ": " & detail else: "")
    inc gWarnings

# --------------------------------------------------------------- the tree

type ModEntry = object
  name: string
  hasLibrary: bool
  hasConfig: bool
  dataFiles: int

proc modsIn(modsDir: string): seq[ModEntry] =
  ## One entry per directory under `mods/`. A mod is a directory holding
  ## `<name>.dll`; anything else there is reported rather than skipped, because
  ## the failure this is looking for is a directory that *looks* installed --
  ## a config, a `data/` tree -- with no library in it to read them.
  result = @[]
  if not isDirectory(modsDir):
    return
  var files: seq[string] = @[]
  var dirs: seq[string] = @[]
  collectEntries(modsDir, files, dirs)
  for d in dirs:
    # Top-level only; `data/` and its subdirectories come back in this list too.
    if find(d, "\\") >= 0:
      continue
    let here = joinPath(modsDir, d)
    var mine: seq[string] = @[]
    var minedirs: seq[string] = @[]
    collectEntries(here, mine, minedirs)
    var e = ModEntry(name: d, hasLibrary: false, hasConfig: false, dataFiles: 0)
    for f in mine:
      let lower = toLowerAscii(f)
      if lower == toLowerAscii(d) & ".dll":
        # Non-empty, for the same reason the four binaries above are measured
        # rather than looked up: an empty `<name>.dll` is a directory that
        # reads as installed to every check that only asks whether the name is
        # there, and loads as nothing.
        e.hasLibrary = fileSizeOf(joinPath(here, f)) > 0'i64
      elif lower == "config.json":
        e.hasConfig = true
      elif lower.startsWith("data\\"):
        inc e.dataFiles
    result.add e

proc checkTree(root: string; modsOut: var seq[ModEntry]): bool =
  ## Everything a person can be told before anything is started. Returns
  ## whether the install is complete enough for the live check to mean
  ## anything.
  let aowl = joinPath(root, "aowlspt")

  heading "Client"
  let install = identify(root)
  printLines(eft.describe(install), "  ")
  if gStaged:
    # `--staged`: the root is a payload `aowl payload` assembled, not an
    # install. Everything below about the client is the one thing a payload
    # legitimately does not have, and demanding it would mean `aowl release`
    # having to reimplement the rest of this file to check a staged tree. Only
    # this check is turned off; the mods, the registry and the four binaries
    # are checked exactly as they are against a real install.
    note "staged payload: there is no client here, and none is expected"
  else:
    check("there is a Tarkov client here", install.exists,
          "no EscapeFromTarkov.exe in " & root)
  if install.exists:
    # The refusal the whole project is arranged around, restated where somebody
    # is looking at a finished install: a pre-1.0 client is not one this host
    # can be put into, and finding that out here beats finding it out from a
    # game that starts with no mods in it.
    check("it is post-1.0", isPostOneZero(install.version),
          $install.version & " is a pre-1.0 client")
    check("it is IL2CPP", install.backend == bkIl2Cpp,
          "the client is " & $install.backend &
          "; aowlspt-host-il2cpp has nothing to bind to under Mono")
    soft("BattlEye was left behind", not install.hasBattlEye,
         "BattlEye is present in a modded install; it is anti-cheat for the " &
         "live service and has no business here")

  heading "Install"
  let j = journal.load(root)
  if j.paths.len > 0:
    line "  installed from " & j.source
    line "  payload        " & j.payload
    line "  tarkov         " & j.tarkovVersion
    line "  mode           " & j.mode
    # Which release this is. `aowl release` takes the number out of `VERSION`
    # and writes it into the archive's `payload.json`; the installer copies it
    # here. An install with no number in its manifest was made either by an
    # installer older than that chain or by hand out of a staging directory --
    # both are real, neither is a broken install, and both are worth knowing
    # before anyone tries to reproduce a bug against "the latest".
    soft("this install says which release it is", j.payloadVersion.len > 0,
         "no `aowlspt` line in " & JournalName & "; it was installed from a " &
         "payload whose payload.json carried no \"version\", so nothing here " &
         "records which build this is")
    if j.payloadVersion.len > 0:
      line "  aowlspt        " & j.payloadVersion
    if known(install.version) and j.tarkovVersion.len > 0 and
       $install.version != j.tarkovVersion:
      # Not a failure: the client can be re-mirrored from an updated source
      # without reinstalling the payload, and that is a legitimate state. It is
      # also how a mod ends up patched against offsets that moved.
      soft("the client is the one this was installed against", false,
           "installed against " & j.tarkovVersion & ", the client here is " &
           $install.version)
  else:
    soft("there is an uninstall manifest", false,
         "no " & JournalName & " here; `aowlspt-install uninstall` will " &
         "refuse to run, and nothing knows what this install is made of")

  heading "aowlspt"
  if isDirectory(aowl):
    check("aowlspt\\ exists", true)
  elif toLowerAscii(baseName(root)) == "aowlspt" and
       fileExists(joinPath(root, "aowlspt-backend.exe")):
    # The doubled path, diagnosed rather than printed. `--root` wants the
    # *install* -- the directory holding `EscapeFromTarkov.exe` -- and the
    # commonest way to get it wrong is to name the `aowlspt` directory inside
    # it, because that is where the binaries a person is looking at actually
    # live. What came out of that was "<...>\\aowlspt\\aowlspt is not a
    # directory": a path nothing ever meant to exist, describing a mistake
    # made one level up. The install is right here, so say so.
    check("aowlspt\\ exists", false,
          "--root names the aowlspt directory itself. It wants the install " &
          "around it: --root " & parentOf(root))
  else:
    check("aowlspt\\ exists", false, aowl & " is not a directory")
  if not isDirectory(aowl):
    return false

  # The four files that are the install. Each one is named with what its
  # absence costs, because "missing aowlspt-host-il2cpp.dll" is only actionable
  # to somebody who already knows what it does.
  # `fileSizeOf` rather than `fileExists`, and that is the whole point of this
  # paragraph. A copy that ran out of disk, a link that was broken and never
  # rewritten, an antivirus that quarantined the contents and left the name --
  # all of them leave a zero-length file, and `fileExists` says yes to every
  # one. A check that a build failure can satisfy by leaving an empty file
  # behind is a check that reports on nothing.
  check("the client host is installed",
        fileSizeOf(joinPath(aowl, "aowlspt-host-il2cpp.dll")) > 0'i64,
        "without it the game starts with no mods in it (a zero-length file " &
        "here counts as absent: it is a name, not a library)")
  check("the launcher is installed",
        fileSizeOf(joinPath(aowl, "aowlspt-launch.exe")) > 0'i64,
        "without it there is no way to start the game with the host inside it")
  check("the backend is installed",
        fileSizeOf(joinPath(aowl, "aowlspt-backend.exe")) > 0'i64,
        "without it the client has nothing to talk to")
  soft("the host has a config", fileExists(joinPath(aowl, "aowlspt-host.json")),
       "the host will use its built-in wait for IL2CPP")
  soft("the client knows where the backend is",
       fileExists(joinPath(aowl, "backend.json")),
       "aowlspt-install writes this from the payload's backendUrl")

  # The database, which this tool used to cite as its example of a soft finding
  # and then never look for.
  #
  # A first-run walk found the consequence: the documented install path ends at
  # a server that passes every check here and has no items in it. No payload
  # carries a `db.json` -- it is BSG's data by way of SPT's, produced locally --
  # so its absence is not a broken install. It is the difference between a
  # server that runs and a server you can play, and a tool that reports the
  # first while a player is looking for the second is the wrong tool.
  #
  # Size matters as much as presence: a real import is tens of megabytes, and a
  # few kilobytes here means a fixture or a half-written file rather than a
  # database.
  let dbPath = joinPath(aowl, "db.json")
  let dbBytes = fileSizeOf(dbPath)
  # The instruction names both spellings of the importer on purpose. It is one
  # program under two names -- `aowl importdb` in the repository,
  # `aowl-importdb.exe` beside the installer in a release archive -- and a
  # person reading this on a finished install has, more often than not, only
  # ever had the second one.
  soft("the game's data is installed", dbBytes > 0,
       "there is no " & dbPath & ", so the emulator answers out of its own " &
       "fallbacks: it will serve, and the client will find no items, no " &
       "traders and no quests. Produce one with `install\\aowl-importdb.exe` " &
       "from the release archive, or `aowl importdb` from the repository: " &
       "--from <your SPT install> --out " & aowl)
  if dbBytes > 0:
    soft("and it is a real database, not a fixture",
         dbBytes > 4_000_000,
         "it is " & $(dbBytes div 1024) & " KiB; a real import is tens of " &
         "megabytes, so this is a test fixture or a half-written file")

  heading "Mods"
  let modsDir = joinPath(aowl, "mods")
  check("there is a mods directory", isDirectory(modsDir),
        "the host and the backend will both load nothing")
  modsOut = modsIn(modsDir)
  check("there are mods installed", modsOut.len > 0,
        "there is nothing under " & modsDir & "; the backend will come up " &
        "with no emulator in it and answer nothing the client asks")
  for m in modsOut:
    var suffix = ""
    if m.hasConfig: suffix.add "  config"
    if m.dataFiles > 0: suffix.add "  " & $m.dataFiles & " data file(s)"
    # The failure this exists for. `aowl payload` stages a mod's `config.json`
    # and `data/` whether or not the library beside them got built, so a mod
    # whose build failed installs as a directory full of settings that nothing
    # reads -- and the host, which loads by scanning for `.dll`, says nothing
    # at all about it.
    check("mod " & m.name & " has its library" & suffix, m.hasLibrary,
          "there is no usable " & m.name & ".dll in this directory -- it is " &
          "missing, or it is there and empty -- so nothing here loads and " &
          "nothing says so")

  heading "Registry"
  let regPath = joinPath(root, RegistryRelPath)
  let haveRegistry = fileExists(regPath)
  soft("the mod registry is installed", haveRegistry,
       "no " & RegistryRelPath & "; the mod manager will find nothing to " &
       "manage and say so in the backend log")
  if haveRegistry:
    var regText = ""
    if readTextFile(regPath, regText):
      printLines(describeRegistry(regText), "  ")
      check("the registry declares a schema this build knows",
            schemaOf(regText) == "aowlspt.registry/1",
            "schema is \"" & schemaOf(regText) & "\"")

      # Cross-check: a registry naming a mod that is not installed is not an
      # error -- the registry lists everything that exists, not everything you
      # chose -- but it is exactly what somebody is looking for when a list
      # resolves to fewer mods than they expected.
      var absent = 0
      for m in modsOut:
        if m.hasLibrary and find(regText, "\"" & m.name & "\"") < 0:
          inc absent
      if absent > 0:
        note $absent & " installed mod(s) are not named in the registry; the " &
             "manager cannot enable or disable those"

  heading "Selection"
  let cfgPath = joinPath(root, ManagerConfigRelPath)
  if fileExists(cfgPath):
    var cfgText = ""
    if readTextFile(cfgPath, cfgText):
      let active = activeListsOf(cfgText)
      if active.len > 0 and active != "[]":
        line "  a fresh run starts with " & active
        if haveRegistry:
          var regText = ""
          if readTextFile(regPath, regText):
            # An active list the registry does not define resolves to nothing,
            # and the player gets an install with every mod off and no reason
            # given anywhere.
            var bad = ""
            let ids = idsOf(active)
            for id in ids:
              if not hasList(regText, id):
                if bad.len > 0: bad.add ", "
                bad.add id
            check("every default list is in the registry", bad.len == 0,
                  bad & " is named as a default and is not in the registry")
      else:
        note "no default list; the manager starts with everything off until " &
             "somebody chooses"
    line "  (the manager stores your own choice separately, and stops " &
         "consulting this file after the first change)"
  else:
    soft("the mod manager is installed", false,
         "no " & ManagerConfigRelPath & "; there is nothing managing the mod " &
         "list on this install")

  result = gFailures == 0

# --------------------------------------------------------------- live

var gPort = 6978

proc call(path, body: string): Response =
  result = request(gPort, path, body, Session)

proc portIsTaken(): bool =
  ## Whether something is already listening on the port about to be used.
  ##
  ## `request` reports a refused connection with a message that names it; any
  ## other outcome -- a reply, a timeout, a protocol error -- means something
  ## accepted the socket, and that something is not the server this run is
  ## about to start.
  ##
  ## This is here because of a real hour spent the wrong way. Another backend
  ## on this machine already owned the port; the one started here failed to
  ## take it and logged `listening on 127.0.0.1:<port>` anyway, so the log said
  ## the server was up and this program said it never answered. Both halves
  ## were reporting honestly about different processes, and the person in the
  ## middle has an install that works being told it does not. Asking first
  ## turns twenty seconds of silence and a wrong conclusion into one sentence.
  let r = call("/client/game/config", "")
  result = find(r.error, "could not connect") < 0

proc waitForBackend(tries: int): bool =
  ## Polls a real endpoint rather than sleeping a fixed time. The backend has to
  ## bind a port and load every mod before it can answer, and how long that
  ## takes is a property of the install being verified -- which is the thing
  ## this tool does not get to assume anything about.
  var i = 0
  while i < tries:
    let r = call("/client/game/config", "")
    if r.ok and r.contains("\"err\":0"):
      return true
    cSleepMs(200'i32)
    inc i
  result = false

proc checkLive(root: string; keep: bool) =
  let aowl = joinPath(root, "aowlspt")
  let exe = joinPath(aowl, "aowlspt-backend.exe")

  heading "Starting the backend"
  line "  " & exe
  line "  root " & aowl & ", port " & $gPort
  # A port of its own, and not the play port. A backend the player already has
  # running would otherwise make this fail -- or, far worse, pass, against a
  # server that is not the one being verified.
  # Winsock has to be initialised in *this* process before any of `wire`'s
  # sockets will do anything. Without it every request fails to connect, the
  # poll below runs its full twenty seconds, and the report says the backend
  # never answered -- against a backend that came up fine and logged
  # "listening" while this was deciding it had not. That is a diagnostic tool
  # producing a false accusation, which is worse than producing nothing.
  if cNetStartup() == 0'i32:
    check("winsock is available", false, "error " & $int(cNetLastError()))
    return

  if portIsTaken():
    check("nothing else is already on port " & $gPort, false,
          "something is answering on 127.0.0.1:" & $gPort & " already. " &
          "Starting a second backend there would test whichever one the " &
          "socket reached, which is not this install. Pass --port with a " &
          "free one.")
    return
  ok "port " & $gPort & " is free"
  inc gChecks

  var e = exe
  var w = aowl
  var cmd = "\"" & exe & "\" --root \"" & aowl & "\" --port " & $gPort
  let proc1 = cSpawn(toCString(e), toCString(w), toCString(cmd))
  if proc1 == 0'u64:
    check("the backend starts", false, "could not spawn " & exe)
    return

  if not waitForBackend(100):
    check("the backend answers", false,
          "no answer on 127.0.0.1:" & $gPort & " after 20s; see " &
          joinPath(aowl, "aowlspt-backend.log"))
    cSpawnKill(proc1)
    return
  ok "the backend is up"

  heading "Over the wire"
  # These four are the client's first four questions, in the order it asks
  # them, and between them they cover the whole stack: the socket, the zlib
  # framing in both directions, the route table, the envelope the client reads
  # `err` out of, and a mod -- the emulator -- answering. A server that gets
  # any one of them wrong is a server the client bounces off with a 200 on both
  # sides and nothing in either log.
  block:
    let r = call("/client/game/config", "")
    check("the emulator serves /client/game/config",
          r.ok and r.contains("\"err\":0"), r.error & head(r.body, 120))
  block:
    let r = call("/client/game/version/validate",
                 "{\"version\":{\"major\":\"1.1.0.46777\"}}")
    check("a request body survives the round trip",
          r.ok and r.contains("\"err\":0"), r.error)
  block:
    let r = call("/client/game/profile/list", "")
    check("the profile store answers", r.ok and r.contains("\"err\":0"),
          r.error)
  block:
    let r = call("/nope/not/a/route", "")
    # A 404 that arrives is a working server; a 404 that does not arrive is a
    # server that stopped reading the socket.
    check("an unknown route is refused rather than hung", r.ok, r.error)

  heading "The mod manager"
  block:
    let r = call("/aowlspt/mods", "")
    if not r.ok or not r.contains("\"ok\":true"):
      soft("the mod manager is loaded", false,
           "no answer on /aowlspt/mods; nothing is managing the mod list")
    else:
      ok "the mod manager is loaded"
      inc gChecks
      # This is the one that catches the failure this whole tool was written
      # for: an install that is complete except that the registry never got
      # into it. The manager loads either way and says so only in its log.
      #
      # Both of these used to be written as `not r.contains("<the bad value>")`,
      # and a check phrased that way is satisfied by every answer that does not
      # contain the string -- including one with no such field in it at all. A
      # renamed field, a shorter status document, an answer from something else
      # on the port: all of them pass, and pass silently, which is the exact
      # shape of failure this tool exists to catch in an install. So each one
      # now asserts the field is *there* and says what it says.
      check("the status names a registry",
            hasKey(r.body, "registry") and textOf(r.body, "registry").len > 0,
            "the manager is running with no registry: registry=\"" &
            textOf(r.body, "registry") & "\"" &
            (if hasKey(r.body, "registry"): ""
             else: " (there is no `registry` field in its answer at all)"))
      let resolved = numberOf(r.body, "loaded")
      check("it resolved something", resolved > 0,
            (if resolved < 0:
               "there is no `loaded` count in the manager's answer, so " &
               "nothing here knows whether anything resolved"
             else:
               "the manager resolved " & $resolved & " mods, so the active " &
               "list names nothing that is installed"))
      ok "  " & head(r.body, 400)

  gServed = true
  if keep:
    heading "Left running"
    line "  pid is still alive on port " & $gPort & "; kill it yourself"
  else:
    cSpawnKill(proc1)
    if cSpawnAlive(proc1) == 0'i32:
      ok "the backend was stopped"

# --------------------------------------------------------------- main

proc main(): int =
  var root = ""
  var offline = false
  var keep = false
  var i = 1
  let n = paramCount()
  while i <= n:
    let a = paramStr(i)
    if a == "--root":
      inc i
      if i <= n: root = paramStr(i)
    elif a == "--offline":
      offline = true
    elif a == "--staged":
      gStaged = true
    elif a == "--keep":
      keep = true
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
    elif a == "--quiet" or a == "-q":
      setVerbosity vQuiet
    elif a == "--help" or a == "-h":
      echo Usage
      return 0
    elif a.startsWith("-"):
      fatal "unknown option: " & a
    elif root.len == 0:
      root = a
    inc i

  if root.len == 0:
    # Run from inside the install, which is the normal case: this exe sits in
    # `aowlspt\` beside the backend, and the client is one level up. The same
    # rule `aowlspt-launch` uses, for the same reason.
    let here = parentOf(absolutePathOf(paramStr(0)))
    if isDirectory(joinPath(here, "aowlspt")):
      root = here
    elif toLowerAscii(baseName(here)) == "aowlspt":
      # This exe is *in* `aowlspt\`, so the install is the directory above --
      # whether or not there is a client in it. Testing for
      # `EscapeFromTarkov.exe` first was the older rule and it had a hole: a
      # staged payload has no client, so the test failed and the root fell
      # through to `aowlspt\` itself, and every check after that ran against
      # a doubled `aowlspt` inside it. A doubled directory is not a state to
      # report on, it is a wrong answer that looks like a finding.
      root = parentOf(here)
    else:
      root = here
  root = absolutePathOf(root)

  heading "aowlspt-verify"
  line "  " & root

  var mods: seq[ModEntry] = @[]
  let complete = checkTree(root, mods)

  if not offline:
    if not fileExists(joinPath(root, "aowlspt\\aowlspt-backend.exe")):
      # Starting things is the part of this tool that writes, and it writes
      # into `<root>\aowlspt`. Refusing when the backend is not there is not
      # only about having nothing to start: it is what keeps this from ever
      # running -- and logging, and creating a store -- inside a directory that
      # is somebody's game rather than an install this project built.
      note "no backend here; nothing to start"
    elif not complete:
      note "skipping the live check: the install is not complete enough for " &
           "its result to mean anything"
    else:
      checkLive(root, keep)

  heading "Result"
  line "  " & $gChecks & " checks"
  if gWarnings > 0:
    line "  " & $gWarnings & " warning(s)"
  if gFailures > 0:
    err $gFailures & " failed"
    return 1
  if gServed:
    ok "this install is complete and serves"
  elif gStaged:
    ok "this staged payload has everything an install needs in it"
    note "nothing was started: a payload is not an install, and there is no " &
         "client here to serve one"
  else:
    ok "the files of this install are all present"
    note "nothing was started, so nothing here says the server answers. " &
         "Run without --offline for that."
  result = 0

quit(main())
