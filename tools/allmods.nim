## allmods -- every mod in the registry, in one backend, at once.
##
##     allmods --repo <checkout> --stage <dir> --backend <aowlspt-backend.exe>
##             [--port 6980] [--db build\db\db.json]
##
## Every other gate in this repository runs one mod, or three chosen to make a
## point. This one runs **the configuration a player actually installs**: every
## mod the registry names, staged into one root, loaded by one host, serving one
## router over one database. That configuration has a whole class of failures in
## it that no single-mod test can see, because every one of them needs a second
## mod to exist:
##
## * **A refused route.** `hostRouteRegister` returns `ErrGeneric` for a url that
##   is already registered, and every mod in this tree registers its routes with
##   `discard serve(...)`. So the second mod to want a path does not serve, does
##   not log, and does not fail -- it is simply not there, and the player sees a
##   feature that "does nothing" on a server that reports no error at all.
## * **A lost database write.** `dbWrite` merges, which is what lets two mods
##   edit sibling fields of one object. Two mods editing *the same* field is a
##   different thing, and the winner is load order -- which is directory
##   enumeration order, not the `loadAfter` the registry states.
## * **A nested event delivery.** Events are synchronous. A mod that emits from
##   inside a handler for an event another mod emitted from *its* handler is a
##   call chain nobody wrote down.
##
## ## How it establishes what it reports
##
## Nothing here is a hardcoded list of routes or database paths -- a list like
## that is out of date the day a mod grows a feature, and it is exactly the kind
## of test that passes while the thing it names has moved. Instead the tool
## **measures the same install twice**:
##
##  1. a **baseline** run with the emulator alone;
##  2. a **pair** run per server-side mod: the emulator and that mod;
##  3. the **all** run: everything the registry names.
##
## A route in a pair run and not in the all run was refused, and both mods are
## named because the pair says who wanted it and the all run's load window says
## who got it. A database leaf a pair added, or changed away from the baseline,
## and that the all run does not have, is a write another mod overwrote -- and
## the report prints the path, both values, and which one survived.
##
## The cost numbers are measured the same way: boot with one mod against boot
## with ten, and the backend's own CPU time over an idle window, which is what
## ten `on_update`s on a 50 ms tick actually costs.
##
## Finally the whole thing runs again against an imported database when there is
## one, because a mod's assumption about a table it did not write is a thing
## only real data can be wrong about. It skips, plainly, when there is not.

import std/[strutils, syncio, cmdline]
import aowlsptinstall/[winfs, log]
import wire

{.emit: """#include <stdlib.h>""".}
{.emit: """#include <string.h>""".}
{.emit: """#include "aowlspt_shim.h" """.}
{.emit: """#include "aowlspt_net.h" """.}
{.emit: """#include "aowlspt_inject.h" """.}

{.emit: """
/* Two clocks of this file's own, for the reason `realtest.nim` gives: the ones
 * in `wire.nim` are defined in that translation unit and nothing declares them
 * here. */
static int64_t aowl_am_qpc(void) {
  LARGE_INTEGER v; QueryPerformanceCounter(&v); return (int64_t)v.QuadPart;
}
static int64_t aowl_am_qpf(void) {
  LARGE_INTEGER v; QueryPerformanceFrequency(&v); return (int64_t)v.QuadPart;
}

/* The backend's own CPU time, kernel plus user, in microseconds.
 *
 * This is the only honest way to price a tick from outside the process. The
 * serve loop sleeps 50 ms and then runs every live mod's `on_update`; request
 * latency cannot see that cost at all, because requests are answered on worker
 * threads. What a tick costs shows up as CPU burned by a server nobody is
 * talking to, and that is what this reads. */
static int64_t aowl_am_cpu_us(uint64_t handle) {
  FILETIME c, e, k, u;
  ULARGE_INTEGER ku, uu;
  if (!handle) return -1;
  if (!GetProcessTimes((HANDLE)(uintptr_t)handle, &c, &e, &k, &u)) return -1;
  ku.LowPart = k.dwLowDateTime;  ku.HighPart = k.dwHighDateTime;
  uu.LowPart = u.dwLowDateTime;  uu.HighPart = u.dwHighDateTime;
  return (int64_t)((ku.QuadPart + uu.QuadPart) / 10ULL);
}
""".}

proc cSpawnQuiet(exe, workDir, cmdLine: cstring): uint64 {.
  importc: "aowl_spawn_quiet", nodecl.}
proc cSpawnAlive(h: uint64): int32 {.importc: "aowl_spawn_alive", nodecl.}
proc cSpawnKill(h: uint64) {.importc: "aowl_spawn_kill", nodecl.}
proc cSleepMs(ms: int32) {.importc: "aowl_sys_sleep", nodecl.}
proc cQpc(): int64 {.importc: "aowl_am_qpc", nodecl.}
proc cQpf(): int64 {.importc: "aowl_am_qpf", nodecl.}
proc cCpuUs(h: uint64): int64 {.importc: "aowl_am_cpu_us", nodecl.}

const
  Usage = """
allmods -- every registry mod in one backend at once

  allmods --repo PATH --stage PATH --backend PATH [--port N] [--db PATH]

  --repo PATH      the checkout: registry\mods.json and mods\*\bin\*.dll
  --stage PATH     a scratch directory; every run gets a root under it
  --backend PATH   aowlspt-backend.exe
  --port N         port to serve on (default 6980)
  --db PATH        an imported database for the second half of the run. When it
                   is not there that half is skipped, not failed.
  --idle N         seconds of idle to price a tick over (default 3)
  --quick          the all-mods run only: no baseline, no pairs, no diffs
  -h, --help       this
"""
  Session = "aaaaaaaaaaaaaaaaaaaaaaaa"
  MaxLeaves = 200000
    ## The cap on a database subtree diff. `/client/locations` off an imported
    ## database is megabytes; walking it is linear, but a report of a hundred
    ## thousand differing leaves is not a report. The walk stops and says so.

var gQpf = 1'i64
var gPort = 6980
var gFailures = 0
var gChecks = 0
var gSkipped = 0
var gIdleSecs = 3

proc micros(): int64 =
  let t = cQpc()
  result = (t div gQpf) * 1000000'i64 + ((t mod gQpf) * 1000000'i64) div gQpf

proc check(what: string; condition: bool; detail = "") =
  inc gChecks
  if condition:
    ok what
  else:
    err what & (if detail.len > 0: ": " & detail else: "")
    inc gFailures

proc skip(what, why: string) =
  inc gChecks
  inc gSkipped
  note "skip  " & what & ": " & why

proc call(path, body: string): Response =
  result = request(gPort, path, body, Session)

# ---------------------------------------------------------------------------
# Small helpers over seqs of strings
# ---------------------------------------------------------------------------

proc has(s: seq[string]; x: string): bool =
  result = false
  for v in s:
    if v == x:
      return true

proc indexOfIn(s: seq[string]; x: string): int =
  result = -1
  for i in 0 ..< s.len:
    if s[i] == x:
      return i

# ---------------------------------------------------------------------------
# A JSON scanner
#
# The same one `tools/realtest.nim` and `tools/importdb.nim` carry, and for the
# same reason: nothing here needs a value's meaning, only where it begins and
# ends, and an index into the body beats a substring of it when the body is a
# megabyte of locations.
# ---------------------------------------------------------------------------

proc findAt(hay, needle: string; start: int): int =
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

proc keyAt(s: string; at: int; text: var string): int =
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
  ## The index of `key`'s value in the object at `objAt`, one level only.
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
  result = ""
  if at < 0 or at >= s.len or s[at] != '"':
    return
  discard keyAt(s, at, result)

proc rawVal(s: string; at: int): string =
  ## A value as written, whatever kind it is. Truncated: the report prints it.
  result = ""
  if at < 0 or at >= s.len:
    return
  var i = at
  if not skipValue(s, i):
    return
  var stop = i
  if stop - at > 120:
    stop = at + 120
  result = s.substr(at, stop - 1)
  if stop < i:
    result.add "..."

# ---------------------------------------------------------------------------
# The registry
# ---------------------------------------------------------------------------

type
  ModEntry = object
    id: string
    name: string
    dir: string        ## artifact directory under mods\
    lib: string        ## artifact library file name
    srcPath: string    ## source path in the checkout, e.g. mods\morebots
    sides: string      ## as written, for the report
    loadAfter: string  ## as written
    serverSide: bool
    built: bool
    dll: string        ## absolute path to the built library, when there is one

var gMods: seq[ModEntry] = @[]

proc readRegistry(repo: string): bool =
  let path = joinPath(joinPath(repo, "registry"), "mods.json")
  var text = ""
  if not readTextFile(path, text):
    err "could not read " & path
    return false
  var root = 0
  skipWs(text, root)
  let modsAt = memberValue(text, root, "mods")
  if modsAt < 0:
    err path & " has no `mods` array"
    return false
  for at in elements(text, modsAt):
    var m = ModEntry(id: "", name: "", dir: "", lib: "", srcPath: "",
                     sides: "", loadAfter: "", serverSide: false,
                     built: false, dll: "")
    m.id = textVal(text, memberValue(text, at, "id"))
    m.name = textVal(text, memberValue(text, at, "name"))
    let src = memberValue(text, at, "source")
    if src >= 0:
      m.srcPath = textVal(text, memberValue(text, src, "path"))
    let art = memberValue(text, at, "artifact")
    if art >= 0:
      m.dir = textVal(text, memberValue(text, art, "dir"))
      m.lib = textVal(text, memberValue(text, art, "library"))
    let sidesAt = memberValue(text, at, "sides")
    if sidesAt >= 0:
      for e in elements(text, sidesAt):
        let s = textVal(text, e)
        if m.sides.len > 0: m.sides.add ","
        m.sides.add s
        if s == "server": m.serverSide = true
    let afterAt = memberValue(text, at, "loadAfter")
    if afterAt >= 0:
      for e in elements(text, afterAt):
        if m.loadAfter.len > 0: m.loadAfter.add ","
        m.loadAfter.add textVal(text, e)
    if m.id.len > 0:
      gMods.add m
  result = gMods.len > 0

# ---------------------------------------------------------------------------
# Staging
# ---------------------------------------------------------------------------

proc copyTree(src, dst: string): int =
  ## Every file under `src`, into `dst`, directories created as needed.
  result = 0
  if not isDirectory(src):
    return
  var files: seq[string] = @[]
  var dirs: seq[string] = @[]
  collectEntries(src, files, dirs)
  discard ensureDir(dst)
  for d in dirs:
    discard ensureDir(joinPath(dst, d))
  for f in files:
    if copyFileAt(joinPath(src, f), joinPath(dst, f)).ok:
      inc result

proc stageOne(repo, root: string; m: ModEntry): bool =
  ## One mod's artifact into `<root>\mods\<dir>`, the way an install has it:
  ## the library, its `config.json`, and its `data\` beside them.
  if not m.built:
    return false
  let into = joinPath(joinPath(root, "mods"), m.dir)
  discard ensureDir(into)
  # Three attempts. A mod library is a file somebody else may be writing --
  # `aowl build-mod` in another window, or another gate in the same suite -- and
  # a copy that lost that race is worth retrying rather than reporting as a mod
  # that could not be staged.
  var tries = 0
  var copied = false
  while tries < 3:
    if copyFileAt(m.dll, joinPath(into, m.lib)).ok:
      copied = true
      break
    cSleepMs(400'i32)
    inc tries
  if not copied:
    return false
  let srcDir = joinPath(repo, m.srcPath)
  let cfg = joinPath(srcDir, "config.json")
  if fileExists(cfg):
    discard copyFileAt(cfg, joinPath(into, "config.json"))
  discard copyTree(joinPath(srcDir, "data"), joinPath(into, "data"))
  result = true

proc patchActive(text: string): string =
  ## The staged manager's `activeLists`, set to a list that names every mod
  ## there is. Done to the *stage's* copy and never to the tree's: the default
  ## is `aowl.list.core`, and a manager resolving two mods while ten are serving
  ## is a fact this tool reports rather than one it wants to provoke in every
  ## other check.
  let at = findAt(text, "\"activeLists\"", 0)
  if at < 0:
    return text
  let open = findAt(text, "[", at)
  if open < 0:
    return text
  let close = findAt(text, "]", open)
  if close < 0:
    return text
  result = text.substr(0, open) & "\"aowl.list.raidnight\"" &
           text.substr(close, text.len - 1)

proc stage(repo, root, dbSrc: string; which: seq[int]): bool =
  ## A fresh root with the named mods in it. `which` indexes `gMods`.
  discard removeTree(root)
  discard ensureDir(root)
  discard ensureDir(joinPath(root, "mods"))
  for i in which:
    if not stageOne(repo, root, gMods[i]):
      err "could not stage " & gMods[i].id
      return false
  # The registry, where the manager looks for it: `<modsRoot>\..\registry`.
  let regDir = joinPath(root, "registry")
  discard ensureDir(regDir)
  discard copyFileAt(joinPath(joinPath(repo, "registry"), "mods.json"),
                     joinPath(regDir, "mods.json"))
  # The manager's staged config, pointed at a list that names everything.
  let mgrCfg = joinPath(joinPath(joinPath(root, "mods"), "manager"),
                        "config.json")
  if fileExists(mgrCfg):
    var text = ""
    if readTextFile(mgrCfg, text):
      discard writeTextFile(mgrCfg, patchActive(text))
  if dbSrc.len > 0:
    if not copyFileAt(dbSrc, joinPath(root, "db.json")).ok:
      err "could not stage the database " & dbSrc
      return false
  result = true

# ---------------------------------------------------------------------------
# Running the backend, and reading what it wrote down
# ---------------------------------------------------------------------------

type
  LoadedMod = object
    name: string
    guid: string
    version: string
    atMs: int
    routes: seq[string]
    subs: seq[string]
    notes: seq[string]   ## lines the host logged inside this mod's load window

  RunResult = object
    ok: bool
    bootMs: int64        ## spawn to "listening", wall clock
    listenMs: int        ## the host's own clock at "listening"
    mods: seq[LoadedMod]
    skippedNames: seq[string]
    skippedWhy: seq[string]
    errors: seq[string]
    warnings: seq[string]
    routes: seq[string]      ## every route, in registration order
    routeOwner: seq[string]  ## the mod whose load window registered it
    log: string

proc logMessage(line: string; level: var string; atMs: var int): string =
  ## `[123ms] ok     the message` -> ("ok", 123, "the message").
  level = ""
  atMs = -1
  result = ""
  if line.len < 4 or line[0] != '[':
    return
  let close = findAt(line, "ms] ", 0)
  if close < 0:
    return
  var v = 0
  var any = false
  for i in 1 ..< close:
    if line[i] >= '0' and line[i] <= '9':
      v = v * 10 + (ord(line[i]) - ord('0'))
      any = true
  if any:
    atMs = v
  var i = close + 4
  # The level is padded to five, then two spaces.
  if i + 7 > line.len:
    return
  level = strip(line.substr(i, i + 4))
  result = line.substr(i + 7, line.len - 1)

proc parenGuid(msg: string; name: var string; guid: var string;
               version: var string): bool =
  ## `loaded Morebots (aowl.morebots) v1.0.0 by ...`
  name = ""
  guid = ""
  version = ""
  if not msg.startsWith("loaded "):
    return false
  let open = findAt(msg, " (", 0)
  if open < 0:
    return false
  let close = findAt(msg, ")", open)
  if close < 0:
    return false
  name = msg.substr(7, open - 1)
  guid = msg.substr(open + 2, close - 1)
  let v = findAt(msg, " v", close)
  if v >= 0:
    var i = v + 2
    while i < msg.len and msg[i] != ' ':
      version.add msg[i]
      inc i
  result = true

proc parseLog(text: string; r: var RunResult) =
  r.mods = @[]
  r.skippedNames = @[]
  r.skippedWhy = @[]
  r.errors = @[]
  r.warnings = @[]
  r.routes = @[]
  r.routeOwner = @[]
  r.listenMs = -1
  var pendingRoutes: seq[string] = @[]
  var pendingSubs: seq[string] = @[]
  var pendingNotes: seq[string] = @[]
  for raw in splitLines(text):
    if raw.len == 0:
      continue
    var level = ""
    var atMs = -1
    let msg = logMessage(raw, level, atMs)
    if msg.len == 0:
      continue
    if msg.startsWith("route "):
      var u = msg.substr(6, msg.len - 1)
      let px = findAt(u, " (prefix)", 0)
      if px >= 0:
        u = u.substr(0, px - 1) & "*"
      pendingRoutes.add u
      continue
    if msg.startsWith("subscribed to "):
      pendingSubs.add msg.substr(14, msg.len - 1)
      continue
    if msg.startsWith("listening on "):
      r.listenMs = atMs
      continue
    var name = ""
    var guid = ""
    var version = ""
    if parenGuid(msg, name, guid, version):
      var m = LoadedMod(name: name, guid: guid, version: version, atMs: atMs,
                        routes: @[], subs: @[], notes: @[])
      for u in pendingRoutes:
        m.routes.add u
        r.routes.add u
        r.routeOwner.add guid
      for s in pendingSubs:
        m.subs.add s
      for n in pendingNotes:
        m.notes.add n
      pendingRoutes = @[]
      pendingSubs = @[]
      pendingNotes = @[]
      r.mods.add m
      continue
    let sk = findAt(msg, " does not support the ", 0)
    if sk >= 0:
      r.skippedNames.add msg.substr(0, sk - 1)
      r.skippedWhy.add msg.substr(sk + 1, msg.len - 1)
      continue
    if level == "error":
      r.errors.add msg
    elif level == "warn":
      r.warnings.add msg
    else:
      pendingNotes.add msg

proc logPathOf(root: string): string =
  result = joinPath(root, "aowlspt-backend.log")

proc startBackend(exe, root: string): uint64 =
  var e = exe
  var w = root
  var c = "\"" & exe & "\" --root \"" & root & "\" --port " & $gPort
  result = cSpawnQuiet(toCString(e), toCString(w), toCString(c))

proc waitForListening(root: string; tries: int; text: var string): bool =
  ## The log, not a route. A stage whose only mods are client-side registers no
  ## routes at all, and a readiness probe that asks for one would time out on a
  ## host that came up perfectly.
  var i = 0
  while i < tries:
    text = ""
    if readTextFile(logPathOf(root), text):
      # `://127.0.0.1:` rather than `listening on 127.0.0.1:`: the
      # backend writes the scheme into that line and has done since it
      # learned to serve TLS, so the old pattern never matched and this
      # gate reported a healthy server as one that never came up.
      if findAt(text, "://127.0.0.1:", 0) >= 0:
        # One more read a moment later: `loaded` lines for the last mod and the
        # `listening` line are written from the same thread in order, so this
        # is only about the file's tail reaching disk.
        cSleepMs(30'i32)
        discard readTextFile(logPathOf(root), text)
        return true
    cSleepMs(25'i32)
    inc i
  result = false

proc runBackend(exe, root: string; handle: var uint64;
                tries = 1200): RunResult =
  result = RunResult(ok: false, bootMs: 0, listenMs: -1, mods: @[],
                     skippedNames: @[], skippedWhy: @[], errors: @[],
                     warnings: @[], routes: @[], routeOwner: @[], log: "")
  # The old log goes before the new backend starts, and this is load-bearing
  # for any root booted more than once. `waitForListening` decides the server
  # is up by finding `listening` in the log -- and a log left over from the
  # previous boot already contains that word. The wait then returns against a
  # file the new backend has not finished rewriting, and the run is described
  # by whatever tail happened to be on disk at that instant.
  #
  # It is not a hang or a crash; it is a short read. The second boot of the
  # all-mods root reported four loaded mods where the log on disk plainly
  # showed seven, and every load-order check involving the missing three
  # quietly stopped running -- they are skipped, not failed, when a mod is not
  # in the list. A green result meaning "that check no longer happens" is the
  # failure this file exists to catch, so it must not be how this file works.
  discard removeFileAt(logPathOf(root))

  let began = micros()
  handle = startBackend(exe, root)
  if handle == 0'u64:
    result.errors.add "could not start the backend"
    return
  var text = ""
  if not waitForListening(root, tries, text):
    result.errors.add "the backend never reached `listening` in " &
                      $(tries div 40) & " s"
    var partial = ""
    discard readTextFile(logPathOf(root), partial)
    let lines = splitLines(partial)
    var from1 = lines.len - 6
    if from1 < 0: from1 = 0
    for i in from1 ..< lines.len:
      if lines[i].len > 0:
        result.errors.add "  ..." & lines[i]
    cSpawnKill(handle)
    handle = 0'u64
    return
  result.bootMs = (micros() - began) div 1000'i64
  result.log = text
  parseLog(text, result)
  result.ok = true

proc stopBackend(handle: var uint64) =
  if handle != 0'u64:
    cSpawnKill(handle)
    handle = 0'u64

# ---------------------------------------------------------------------------
# A database subtree, as a set of leaf paths and values
# ---------------------------------------------------------------------------

type
  Leaves = object
    paths: seq[string]
    vals: seq[string]
    truncated: bool

proc addLeaf(l: var Leaves; path, value: string) =
  # An empty object at the root of a probe has no path, and recording it as one
  # makes an object that later gained members look like a deleted write. It is
  # the absence of a contribution, not one.
  if path.len == 0:
    return
  if l.paths.len >= MaxLeaves:
    l.truncated = true
    return
  l.paths.add path
  l.vals.add value

proc walkLeaves(s: string; at: int; prefix: string; l: var Leaves) =
  ## Every scalar under `at`, by path. Arrays are recorded whole, as one leaf:
  ## `dbWrite` replaces an array rather than merging into it, so an array is one
  ## value as far as a conflict is concerned, and walking into one produces
  ## index paths that mean nothing across two runs.
  if at < 0 or at >= s.len:
    return
  if l.truncated:
    return
  if s[at] == '{':
    var keys: seq[string] = @[]
    var vals: seq[int] = @[]
    members(s, at, keys, vals)
    if keys.len == 0:
      addLeaf(l, prefix, "{}")
      return
    for i in 0 ..< keys.len:
      let p = if prefix.len == 0: keys[i] else: prefix & "." & keys[i]
      walkLeaves(s, vals[i], p, l)
    return
  addLeaf(l, prefix, rawVal(s, at))

proc leavesOf(body, member: string): Leaves =
  ## The leaves of one member of a response envelope. Tarkov's routes answer
  ## `{"err":0,"errmsg":null,"data":{...}}`, so `data` is where everything is.
  result = Leaves(paths: @[], vals: @[], truncated: false)
  var root = 0
  skipWs(body, root)
  var at = memberValue(body, root, "data")
  if at < 0:
    at = root
  if member.len > 0:
    let inner = memberValue(body, at, member)
    if inner < 0:
      return
    at = inner
  walkLeaves(body, at, "", result)

proc valueOf(l: Leaves; path: string): string =
  result = ""
  let i = indexOfIn(l.paths, path)
  if i >= 0:
    result = l.vals[i]

proc hasPath(l: Leaves; path: string): bool =
  result = indexOfIn(l.paths, path) >= 0

# ---------------------------------------------------------------------------
# What a run contributed to the database
# ---------------------------------------------------------------------------

type
  Probe = object
    label: string
    path: string
    member: string

const
  Probes: array[6, Probe] = [
    ## Every database table this tool can read back **through a route**, which
    ## is the only door it has. `locations`, `locales.global.en` and `globals`
    ## come out of the emulator; `bots.types` and the faction table come out of
    ## morebots' own routes, and without those two the whole `bots.*` subtree --
    ## which is most of what three of these mods write -- would be invisible to
    ## this gate. `configs.*` still is, and that is stated in the report rather
    ## than papered over.
    Probe(label: "locations", path: "/client/locations", member: "locations"),
    Probe(label: "locale en", path: "/client/locale/en", member: ""),
    Probe(label: "globals", path: "/client/globals", member: ""),
    Probe(label: "bots.types", path: "/morebotsapi/bottypes", member: ""),
    Probe(label: "factions", path: "/morebotsapi/getfactions", member: ""),
    Probe(label: "difficulties", path: "/singleplayer/settings/bot/difficulties",
          member: "")]

var gUnstable: seq[string] = @[]
var gUnstableOwner: seq[string] = @[]
var gBaseLeaves: seq[Leaves] = @[]
var gAllLeaves: seq[Leaves] = @[]

proc leafCount(ls: seq[Leaves]): int =
  ## How much database was read back at all. Every database claim this tool
  ## makes is a set difference over these leaves, and a set difference over two
  ## empty sets is zero differences -- which reads exactly like "nothing was
  ## overwritten". So the size of the input is asserted before its differences
  ## are believed.
  result = 0
  for l in ls:
    result = result + l.paths.len

proc probesRead(ls: seq[Leaves]): int =
  ## How many of the six probes answered with anything.
  result = 0
  for l in ls:
    if l.paths.len > 0:
      inc result

proc namedEmptyProbes(ls: seq[Leaves]): string =
  result = ""
  for p in 0 ..< Probes.len:
    if p >= ls.len or ls[p].paths.len == 0:
      if result.len > 0: result.add ", "
      result.add Probes[p].label

proc probeAll(into: var seq[Leaves]) =
  into = @[]
  for p in Probes:
    let r = call(p.path, "")
    # A route no mod in this stage registered answers `{"err":"no route"}`, and
    # reading that as two database leaves called `err` and `url` would credit
    # whichever mod brought the route with a contribution it never made.
    if r.ok and not r.contains("\"err\":\"no route\""):
      into.add leavesOf(r.body, p.member)
    else:
      into.add Leaves(paths: @[], vals: @[], truncated: false)

# ---------------------------------------------------------------------------
# The boot sequence, shallow
# ---------------------------------------------------------------------------

proc expectIn(what, path, body, want: string): bool =
  let r = call(path, body)
  if not r.ok:
    check(what, false, r.error)
    return false
  if not r.contains(want):
    var seen = r.body
    if seen.len > 160: seen = seen.substr(0, 159) & "..."
    check(what, false, "expected " & want & ", got " & seen)
    return false
  check(what, true)
  result = true

proc jsonText(body, key: string): string =
  ## One string member, anywhere in the body. Enough for a uid.
  result = ""
  let k = "\"" & key & "\":\""
  let at = findAt(body, k, 0)
  if at < 0:
    return
  var i = at + k.len
  while i < body.len and body[i] != '"':
    result.add body[i]
    inc i

proc bootSequence(label: string) =
  ## The client's boot sequence, driven the way `emutest` drives it and no
  ## deeper: this is an integration test, not a second emulator suite. What it
  ## establishes is that ten mods in one router did not break the sequence a
  ## player's client walks before it can show a menu.
  heading "The client boots (" & label & ")"
  discard expectIn("game config", "/client/game/config", "", "\"err\":0")
  discard expectIn("version validate", "/client/game/version/validate",
                   "{\"version\":{\"major\":\"1.1.0\"}}", "isvalid")
  let fresh = call("/client/game/profile/list", "")
  if not fresh.ok or not fresh.contains("\"data\":[]"):
    check("a fresh store", false, "this root already has profiles in it")
    # Ten checks follow this line and none of them will run. Said here, because
    # a section that stops after its first check looks identical in the summary
    # to a section that passed ten.
    note "  the rest of the boot sequence (create, select, start, items, " &
         "globals, handbook, locale, settings, locations, traders) did not " &
         "run at all"
    return
  check("a fresh store", true)
  let created = call("/client/game/profile/create",
                     "{\"nickname\":\"AowlAll\",\"side\":\"Usec\",\"headId\":\"x\"}")
  let uid = jsonText(created.body, "uid")
  check("create returns a profile id", uid.len == 24, created.body)
  discard expectIn("select binds the session", "/client/game/profile/select",
                   "{\"uid\":\"" & uid & "\"}", "\"status\":\"ok\"")
  discard expectIn("config names the active profile", "/client/game/config",
                   "", uid)
  discard expectIn("game start", "/client/game/start", "", "utc_time")
  discard expectIn("keepalive", "/client/game/keepalive", "", "OK")
  discard expectIn("items", "/client/items", "", "\"err\":0")
  discard expectIn("globals", "/client/globals", "", "\"err\":0")
  discard expectIn("handbook", "/client/handbook/templates", "", "Categories")
  discard expectIn("locale", "/client/locale/en", "", "\"err\":0")
  discard expectIn("settings", "/client/settings", "", "\"err\":0")
  discard expectIn("locations", "/client/locations", "", "\"err\":0")
  discard expectIn("trader settings", "/client/trading/api/traderSettings",
                   "", "\"err\":0")

# ---------------------------------------------------------------------------
# Cost
# ---------------------------------------------------------------------------

var gLastIdleCpuUs = -1'i64
  ## The window's whole CPU delta, kept beside the per-tick figure: the clock
  ## behind `GetProcessTimes` moves in 15.6 ms steps, so a per-tick number in
  ## single microseconds is a division of a small integer and the reader is
  ## entitled to see the integer.

proc idleCpuUsPerTick(handle: uint64; secs: int): int64 =
  ## CPU burned by a server nobody is talking to, divided by the ticks that
  ## happened in the window. The serve loop sleeps 50 ms a turn, so the tick
  ## count is the window over 50 -- and what the number prices is `tickMods`
  ## plus `runTimers` plus `drain`, which is exactly what a mod's `on_update`
  ## costs a player per frame of server time.
  result = -1
  gLastIdleCpuUs = -1'i64
  let before = cCpuUs(handle)
  if before < 0'i64:
    return
  var left = secs * 1000
  while left > 0:
    cSleepMs(200'i32)
    left = left - 200
  let after = cCpuUs(handle)
  if after < 0'i64:
    return
  gLastIdleCpuUs = after - before
  let ticks = int64(secs) * 1000'i64 div 50'i64
  if ticks <= 0'i64:
    return
  result = (after - before) div ticks

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

proc reportLoad(r: RunResult; expectServer: seq[string]) =
  heading "What loaded"
  var prev = 0
  for m in r.mods:
    line "  loaded  " & m.guid & " v" & m.version & " (" & m.name & ") at " &
         $m.atMs & "ms (+" & $(m.atMs - prev) & "ms), " & $m.routes.len &
         " route(s), " & $m.subs.len & " subscription(s)"
    prev = m.atMs
  for i in 0 ..< r.skippedNames.len:
    line "  skipped " & r.skippedNames[i] & " -- " & r.skippedWhy[i]
  for e in r.errors:
    line "  error   " & e
  var loadedGuids: seq[string] = @[]
  for m in r.mods:
    loadedGuids.add m.guid
  for id in expectServer:
    if not has(loadedGuids, id):
      check("the registry's " & id & " loaded", false,
            "it is not in the host's mod table; see the log")
    else:
      check("the registry's " & id & " loaded", true)

proc reportEvents(r: RunResult) =
  ## Who listens to what, and the one thing about a synchronous event channel
  ## that only a multi-mod run can show: a mod doing its work inside *another*
  ## mod's `on_load`.
  ##
  ## The host writes every line of every mod's log through one file, in order,
  ## and a mod's `loaded` line comes after its `on_load` returns. So a line
  ## another mod wrote sitting inside this mod's load window is not a formatting
  ## curiosity -- it is a call stack: `loadMod -> on_load -> emit ->
  ## deliverEvent -> the other mod's handler`.
  heading "Events"
  var names: seq[string] = @[]
  var counts: seq[int] = @[]
  for a in 0 ..< r.mods.len:
    if r.mods[a].subs.len == 0:
      continue
    # `subList`, not `subs`: a local with the same name as the field it is
    # built from makes nimony's C backend emit the local's mangled name in
    # place of the field's, and the error names a member of the struct that
    # does not exist.
    var subList = ""
    for b in 0 ..< r.mods[a].subs.len:
      let sname = r.mods[a].subs[b]
      if subList.len > 0: subList.add ", "
      subList.add sname
      let at = indexOfIn(names, sname)
      if at < 0:
        names.add sname
        counts.add 1
      else:
        counts[at] = counts[at] + 1
    line "  " & r.mods[a].guid & " subscribes to " & subList
  for i in 0 ..< names.len:
    if counts[i] > 1:
      line "  " & $counts[i] & " mods subscribe to " & names[i] &
           " -- one emit runs all of them, in subscription order, on the " &
           "emitter's stack"
  var tags: seq[string] = @[]
  var tagGuid: seq[string] = @[]
  for a in 0 ..< r.mods.len:
    var tag = ""
    for ch in toLowerAscii(r.mods[a].name):
      if ch != ' ' and ch != '-':
        tag.add ch
    tags.add tag
    tagGuid.add r.mods[a].guid
  # Flattened first, walked second. Two indexed loops over the same seq of
  # objects with a third inside them made nimony's C backend emit two locals
  # with one name; one pass that copies the lines out avoids the shape entirely.
  var windowOf: seq[string] = @[]
  var noteText: seq[string] = @[]
  for a in 0 ..< r.mods.len:
    for b in 0 ..< r.mods[a].notes.len:
      windowOf.add r.mods[a].guid
      noteText.add r.mods[a].notes[b]
  var nested = 0
  for x in 0 ..< noteText.len:
    let low = toLowerAscii(noteText[x])
    var owner = ""
    for t in 0 ..< tags.len:
      if tagGuid[t] == windowOf[x]:
        continue
      # The line must *begin* with the other mod's name. Matching a guid
      # anywhere in the text instead reports the manager's own numbered list of
      # what it resolved as six nested deliveries, which is a false positive
      # with a very convincing shape.
      if tags[t].len > 3 and findAt(low, tags[t], 0) == 0:
        owner = tagGuid[t]
    if owner.len == 0:
      continue
    inc nested
    line "  inside " & windowOf[x] & "'s on_load, " & owner & " logged:"
    line "    " & noteText[x]
  if nested > 0:
    line "  " & $nested & " line(s) written by a mod other than the one being " &
         "loaded: a synchronous event delivered into a handler that emitted again"

const Mutators: array[19, string] = [
  "create", "logout", "reload", "apply", "toggle", "enable", "disable",
  "clear", "select", "regenerate", "change", "save", "delete", "remove",
  "moving", "fetch", "revert", "send", "update"]

proc mutating(url: string): bool =
  ## A route this tool must not drive: it would change the thing the checks
  ## around it are reading. Named by verb rather than by a list of urls,
  ## because the list of urls is the thing that goes stale.
  result = false
  for v in Mutators:
    if findAt(url, v, 0) >= 0:
      return true
  if url == "/client/match/local/end" or url == "/client/match/exit":
    return true

proc ownerOf(r: RunResult; url: string): string =
  let i = indexOfIn(r.routes, url)
  if i < 0:
    return ""
  result = r.routeOwner[i]

proc main(): int =
  var repo = ""
  var stageRoot = ""
  var backend = ""
  var realDb = ""
  var quick = false
  var i = 1
  let n = paramCount()
  while i <= n:
    let a = paramStr(i)
    if a == "--repo":
      inc i
      if i <= n: repo = paramStr(i)
    elif a == "--stage":
      inc i
      if i <= n: stageRoot = paramStr(i)
    elif a == "--backend":
      inc i
      if i <= n: backend = paramStr(i)
    elif a == "--db":
      inc i
      if i <= n: realDb = paramStr(i)
    elif a == "--idle":
      inc i
      if i <= n:
        var v = 0
        var any = false
        for ch in paramStr(i):
          if ch >= '0' and ch <= '9':
            v = v * 10 + (ord(ch) - ord('0'))
            any = true
        if any: gIdleSecs = v
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
    elif a == "--quick":
      quick = true
    elif a == "--help" or a == "-h":
      echo Usage
      return 0
    else:
      err "unknown option: " & a
      return 1
    inc i

  if repo.len == 0 or stageRoot.len == 0 or backend.len == 0:
    echo Usage
    return 1

  # Every path is made absolute here, and it is not tidiness. `startBackend`
  # hands the root to a child process started in a *different* working
  # directory, so a relative `--stage` is joined to that child's cwd and the
  # server comes up in `<stage>/<stage>` -- perfectly, silently, in the wrong
  # place. The tell is a doubled path on disk: `allmodsstage/all/installer/
  # build/allmodsstage/all/aowlspt-backend.log` was there, with the log and the
  # store in it, while the stage's own top level had neither.
  #
  # That matters more here than anywhere else, because this tool boots the same
  # root twice on purpose. The second boot is only a second boot if it lands
  # where the first one wrote its selection; a doubled root makes every boot a
  # first boot, and the load-order checks then compare the directory walk
  # against the manager's resolution and fail for a reason that has nothing to
  # do with either. `fuzzwire`, `livectl` and `soak` all carry this same
  # guard, for the same reason.
  #
  # Guarded on non-empty: `absolutePathOf("")` answers the current directory.
  if repo.len > 0: repo = absolutePathOf(repo)
  if stageRoot.len > 0: stageRoot = absolutePathOf(stageRoot)
  if backend.len > 0: backend = absolutePathOf(backend)
  if realDb.len > 0: realDb = absolutePathOf(realDb)

  if not fileExists(backend):
    err "no backend at " & backend
    return 1
  gQpf = cQpf()
  if gQpf <= 0'i64: gQpf = 1'i64
  discard cNetStartup()

  # -- the registry, and what of it is actually on disk ---------------------

  heading "The registry"
  if not readRegistry(repo):
    return 1
  var serverIds: seq[string] = @[]
  var allIdx: seq[int] = @[]
  var tarkovIdx = -1
  var missing = 0
  for k in 0 ..< gMods.len:
    let dll = joinPath(joinPath(joinPath(repo, gMods[k].srcPath), "bin"),
                       gMods[k].lib)
    gMods[k].built = fileExists(dll)
    gMods[k].dll = dll
    if gMods[k].built:
      allIdx.add k
      if gMods[k].serverSide:
        serverIds.add gMods[k].id
      if gMods[k].id == "aowl.tarkov":
        tarkovIdx = k
    else:
      inc missing
    line "  " & (if gMods[k].built: "built  " else: "MISSING") & " " &
         gMods[k].id & "  sides=" & gMods[k].sides &
         (if gMods[k].loadAfter.len > 0: "  loadAfter=" & gMods[k].loadAfter
          else: "") & "  " & gMods[k].srcPath
  check("every mod the registry names is built", missing == 0,
        $missing & " have no library under mods\\*\\bin; a mod that is not " &
        "built cannot be reported as loaded or not loaded")
  if tarkovIdx < 0:
    err "aowl.tarkov is not built; there is no server to drive"
    return 1
  line "  " & $gMods.len & " mod(s), " & $allIdx.len & " built, " &
       $serverIds.len & " of them server-side"

  var handle = 0'u64
  var baseRoutes: seq[string] = @[]
  var pairIdx: seq[int] = @[]
  var pairRoutes: seq[string] = @[]     ## flattened, aligned with pairOwner
  var pairOwner: seq[string] = @[]
  var pairLeafPath: seq[string] = @[]   ## "<probe>|<path>"
  var pairLeafVal: seq[string] = @[]
  var pairLeafOwner: seq[string] = @[]
  var baseBootMs = 0'i64
  var baseTickUs = -1'i64
  var baseIdleUs = -1'i64
  let fixture = joinPath(joinPath(joinPath(repo, "tests"), "fixtures"),
                         "emu-full.json")

  if not quick:
    # -- the emulator alone: the baseline every later diff is against --------
    heading "Baseline: the emulator alone"
    let broot = joinPath(stageRoot, "base")
    var one: seq[int] = @[tarkovIdx]
    if not stage(repo, broot, fixture, one):
      return 1
    let br = runBackend(backend, broot, handle)
    if not br.ok:
      err "the baseline run did not come up"
      for e in br.errors: line "  " & e
      return 1
    baseBootMs = br.bootMs
    baseRoutes = br.routes
    line "  " & $br.mods.len & " mod, " & $br.routes.len & " route(s), up in " &
         $br.bootMs & " ms"
    probeAll(gBaseLeaves)
    # The baseline is the left-hand side of every route and database difference
    # this tool reports. An empty baseline does not make those differences fail:
    # it makes them *zero*, and zero differences is what a clean run looks like.
    check("the baseline registered routes to compare against",
          baseRoutes.len > 0,
          "the emulator alone registered none, so no route can be found " &
          "missing later")
    check("and the baseline read some database back through its routes",
          leafCount(gBaseLeaves) > 0,
          "all " & $Probes.len & " probes came back empty (" &
          namedEmptyProbes(gBaseLeaves) & "), so every `lost write` and " &
          "`overwritten` check below is a difference between two empty sets")
    if probesRead(gBaseLeaves) < Probes.len:
      note "the emulator alone answers " & $probesRead(gBaseLeaves) & " of " &
           $Probes.len & " probes; nothing is compared on the others: " &
           namedEmptyProbes(gBaseLeaves)
    baseTickUs = idleCpuUsPerTick(handle, gIdleSecs)
    baseIdleUs = gLastIdleCpuUs
    stopBackend(handle)

    # -- each mod beside the emulator ---------------------------------------
    #
    # This is where a route's owner and a database write's author are
    # established, and it is established by measurement rather than by a list
    # written down here that would be wrong the day a mod grows a feature.
    heading "Each mod, alone with the emulator"
    for k in allIdx:
      if k == tarkovIdx:
        continue
      if not gMods[k].serverSide:
        line "  " & gMods[k].id & ": client-side only, nothing to pair"
        continue
      var which: seq[int] = @[tarkovIdx, k]
      # A mod the registry says must load after another needs that other one
      # present, or the pair measures a mod that did nothing.
      if gMods[k].loadAfter.len > 0:
        for j in allIdx:
          if j != k and j != tarkovIdx and
             findAt(gMods[k].loadAfter, gMods[j].id, 0) >= 0:
            which.add j
      let proot = joinPath(stageRoot, "pair-" & gMods[k].dir)
      if not stage(repo, proot, fixture, which):
        # `continue` alone here was the quietest hole in this file. A mod whose
        # pair run never happened contributes no routes and no database leaves,
        # so every collision and lost-write check about it compares against an
        # empty contribution and finds nothing wrong -- and `stage` reports its
        # failure with `err`, which prints a line and does not count. The mod is
        # simply absent from the analysis, and the summary says "0 failed".
        check("the pair stage for " & gMods[k].id & " could be built", false,
              "no routes or database writes of its own were measured, so " &
              "nothing below can find any of them missing")
        continue
      var h2 = 0'u64
      let pr = runBackend(backend, proot, h2)
      if not pr.ok:
        # Same hole, one step further in: a pair that does not boot measures
        # nothing, and printing that with `line` left the run green.
        check("the pair run for " & gMods[k].id & " came up", false,
              "it never reached `listening`, so this mod's routes and " &
              "database writes were never measured and nothing below can " &
              "report them as refused or overwritten")
        for e in pr.errors: line "    " & e
        stopBackend(h2)
        continue
      # The database, while the pair is still up. It has to be read before the
      # backend is stopped, and the backend has to be stopped before the solo
      # run below can have the port -- which is the whole reason this is the
      # order it is. See the solo run's comment.
      var probes: seq[Leaves] = @[]
      probeAll(probes)
      stopBackend(h2)

      # The mod on its own, with no emulator under it. This is the run that can
      # see a collision *with the emulator*: paired with it, a mod whose route
      # the emulator already owns registers 94+n-1 routes and looks exactly like
      # a mod with one route fewer than it has. Alone, it registers what it
      # meant to.
      #
      # **It runs after the pair's backend has been stopped, and that is a fix.**
      # It used to be started while the pair backend was still holding the port,
      # so it never bound one: every solo run in every run of this tool ended
      # `error port <n> is already in use`, `sr.ok` was false, and `soloRoutes`
      # was empty. The two loops below that read `soloRoutes` -- the one that
      # reports a route the emulator and this mod both want, and the one that
      # reports a route the mod registers alone and not in a pair -- have
      # therefore never examined anything. Both report by iteration, so an empty
      # list produces no findings and no failure, and the tool has been claiming
      # "no route was refused as a duplicate" over a comparison it never made.
      let sroot = joinPath(stageRoot, "solo-" & gMods[k].dir)
      var soloWhich: seq[int] = @[k]
      for j in which:
        if j != tarkovIdx and j != k:
          soloWhich.add j
      var soloRoutes: seq[string] = @[]
      var soloRan = false
      if stage(repo, sroot, fixture, soloWhich):
        var h4 = 0'u64
        let sr = runBackend(backend, sroot, h4)
        if sr.ok:
          soloRan = true
          for u in sr.routes:
            if not has(soloRoutes, u):
              soloRoutes.add u
        else:
          for e in sr.errors: line "    solo: " & e
        stopBackend(h4)
      check("the solo run for " & gMods[k].id & " came up",
            soloRan,
            "no run of this mod without the emulator, so a route it shares " &
            "with the emulator cannot be seen from here at all")
      var added = 0
      var clashed = 0
      for u in soloRoutes:
        if has(baseRoutes, u):
          inc clashed
          err "route collision: " & u & " -- both aowl.tarkov and " &
              gMods[k].id & " register it; whichever loads second does not " &
              "serve, and neither of them is told"
          inc gFailures
          inc gChecks
        if not has(pairRoutes, u) and not has(baseRoutes, u):
          pairRoutes.add u
          pairOwner.add gMods[k].id
          inc added
      # Anything the pair registered that the solo run did not is a route the
      # mod only asks for when the emulator is there; credit it too.
      for u in pr.routes:
        if not has(baseRoutes, u) and not has(pairRoutes, u):
          pairRoutes.add u
          pairOwner.add gMods[k].id
          inc added
      for u in soloRoutes:
        if not has(pr.routes, u) and not has(baseRoutes, u):
          err "route lost in a pair: " & u & " -- " & gMods[k].id &
              " registers it alone and not beside aowl.tarkov"
          inc gFailures
          inc gChecks
      # The same stage a second time, and only the leaves that came out the
      # same both times are treated as this mod's contribution.
      #
      # This is not caution, it is a correctness fix that a first version of
      # this tool needed: `mods/blackdivision` seeds its generator from the
      # clock and re-rolls its boss spawns on every load, so the *same* mod
      # alone writes a different `BossLocationSpawn` array on two consecutive
      # runs. Diffing one run against another reports that as a conflict with
      # whoever loaded next, which is a lie with a very convincing shape. What
      # is unstable is reported as unstable instead.
      discard removeTree(joinPath(proot, "store"))
      var h3 = 0'u64
      let pr2 = runBackend(backend, proot, h3)
      var probes2: seq[Leaves] = @[]
      if pr2.ok:
        probeAll(probes2)
      stopBackend(h3)

      var wrote = 0
      var unstable = 0
      for p in 0 ..< probes.len:
        if p >= gBaseLeaves.len:
          continue
        for x in 0 ..< probes[p].paths.len:
          let path = probes[p].paths[x]
          let value = probes[p].vals[x]
          if hasPath(gBaseLeaves[p], path) and
             valueOf(gBaseLeaves[p], path) == value:
            continue
          if pr2.ok and p < probes2.len:
            if not hasPath(probes2[p], path) or valueOf(probes2[p], path) != value:
              inc unstable
              gUnstable.add Probes[p].label & "|" & path
              gUnstableOwner.add gMods[k].id
              continue
          # Attributed to the first mod that produced it. A pair run stages a
          # mod's `loadAfter` dependency beside it, so without this the
          # dependent would be credited with everything its dependency wrote.
          var seen = false
          for y in 0 ..< pairLeafPath.len:
            if pairLeafPath[y] == Probes[p].label & "|" & path and
               pairLeafVal[y] == value:
              seen = true
          if seen:
            continue
          pairLeafPath.add Probes[p].label & "|" & path
          pairLeafVal.add value
          pairLeafOwner.add gMods[k].id
          inc wrote
      line "  " & gMods[k].id & ": up in " & $pr.bootMs & " ms, " & $added &
           " new route(s)" &
           (if clashed > 0: " (" & $clashed & " colliding with the emulator)"
            else: "") & ", " & $wrote & " stable database leaf/leaves of its " &
           "own, " & $unstable & " that differ between two runs of itself"
      if pr.errors.len > 0:
        for e in pr.errors:
          line "    error " & e
      pairIdx.add k

  # -- everything at once ---------------------------------------------------

  heading "Every mod at once"
  let aroot = joinPath(stageRoot, "all")
  if not stage(repo, aroot, fixture, allIdx):
    return 1
  var ar = runBackend(backend, aroot, handle)
  if not ar.ok:
    err "the all-mods run did not come up"
    for e in ar.errors: line "  " & e
    return 1
  line "  up in " & $ar.bootMs & " ms with " & $allIdx.len & " staged"
  reportLoad(ar, serverIds)

  # The order the host actually loaded them in, against the order the registry
  # asks for.
  #
  # **This has to be the second boot, and that is the whole subtlety.** The
  # host reads `aowlspt-selection.json` to decide what loads and in what order,
  # and the manager writes that file during its own `on_load` -- so on a root
  # that has never been run, there is nothing to read and `loadAll` correctly
  # falls back to walking the directory. `stage()` wipes the root, which means
  # every run of this tool was measuring a first-ever boot and asserting the
  # walk order against the manager's resolution. Those two agree only by
  # accident. The checks could not pass, and for a while that was read as the
  # host ignoring `loadAfter`.
  #
  # So: boot, let the manager write its resolution, stop, and boot again on the
  # same root. The second boot is also the honest one to measure -- a player's
  # first launch is the only launch that has no selection, and every launch
  # after it is this.
  heading "Load order"
  var firstOrder = ""
  for m in ar.mods:
    if firstOrder.len > 0: firstOrder.add " -> "
    firstOrder.add m.guid
  line "  first boot (no selection yet, so a directory walk): " & firstOrder

  stopBackend(handle)
  let second = runBackend(backend, aroot, handle)
  if not second.ok:
    err "the all-mods root did not come up a second time"
    for e in second.errors: line "  " & e
    return 1
  ar = second

  var order = ""
  for m in ar.mods:
    if order.len > 0: order.add " -> "
    order.add m.guid
  line "  second boot (the selection the manager wrote): " & order
  check("a second boot loads something", ar.mods.len > 0,
        "the selection file was read and nothing came up -- an empty or " &
        "unmatched selection must fall back to loading everything, never to " &
        "loading nothing")
  if order != firstOrder:
    line "  the two differ, which is the selection being honoured"
  # Every `loadAfter` the registry declares, and how many of them this run was
  # actually in a position to check.
  #
  # The three `continue`s below are each correct on their own -- a constraint
  # naming a mod that is not loaded cannot be checked -- and together they are
  # how this section can report on nothing at all. A boot that came up with four
  # of seven mods (a short log read, a selection that resolved to less than it
  # should) makes every constraint involving the other three vanish, and the
  # heading still prints, and the summary still says zero failed. So the
  # constraints are counted, the ones that could not be checked are named, and a
  # registry that declares constraints none of which could be checked is a
  # failure rather than a quiet nothing.
  var declared = 0
  var checkedPairs = 0
  var uncheckable = ""
  for k in allIdx:
    if gMods[k].loadAfter.len == 0:
      continue
    var loadedIds: seq[string] = @[]
    for m in ar.mods:
      loadedIds.add m.guid
    let mine = indexOfIn(loadedIds, gMods[k].id)
    for j in allIdx:
      if findAt(gMods[k].loadAfter, gMods[j].id, 0) < 0:
        continue
      inc declared
      let theirs = indexOfIn(loadedIds, gMods[j].id)
      if mine < 0 or theirs < 0:
        if uncheckable.len > 0: uncheckable.add ", "
        uncheckable.add gMods[k].id & " after " & gMods[j].id & " (" &
          (if mine < 0 and theirs < 0: "neither is loaded"
           elif mine < 0: gMods[k].id & " is not loaded"
           else: gMods[j].id & " is not loaded") & ")"
        continue
      inc checkedPairs
      check(gMods[k].id & " loads after " & gMods[j].id & ", as the registry " &
            "asks", theirs < mine,
            "it loaded at position " & $mine & " and " & gMods[j].id &
            " at position " & $theirs)
  if uncheckable.len > 0:
    note $(declared - checkedPairs) & " of " & $declared & " declared " &
         "`loadAfter` constraints could not be checked: " & uncheckable
  if declared > 0:
    check("the registry's load-order constraints were actually checked",
          checkedPairs > 0,
          "the registry declares " & $declared & " of them and this boot " &
          "loaded the mods for none; nothing here says anything about load " &
          "order")
  else:
    note "no mod in this registry declares `loadAfter`, so there is no load " &
         "order to check beyond the manager's own resolution below"

  # What the manager resolved, against what the host actually did. These are two
  # different programs answering the same question, and the manager is the one a
  # player reads.
  let listed = call("/aowlspt/mods/list", "")
  if not listed.ok or listed.contains("\"err\":\"no route\""):
    skip("the manager's order is the host's order",
         "the manager is not serving in this stage")
  else:
    var mroot = 0
    skipWs(listed.body, mroot)
    let orderAt = memberValue(listed.body, mroot, "order")
    var resolved: seq[string] = @[]
    for e in elements(listed.body, orderAt):
      resolved.add textVal(listed.body, e)
    # The order has to be *there*. `memberValue` answers -1 for a key it cannot
    # find and `elements` answers @[] for -1, so a renamed field, a shorter
    # answer or a manager that resolved nothing all produce an empty list -- and
    # the pairwise comparison below over an empty list finds zero inversions and
    # passes. This is the same route the panel reads, so an empty order is a
    # finding in its own right.
    check("the manager answered with a load order to compare",
          resolved.len > 0,
          "no `order` array in /aowlspt/mods/list, or it is empty: " &
          listed.body.substr(0, (if listed.body.len > 200: 200
                                 else: listed.body.len - 1)))
    var mtext = ""
    for id in resolved:
      if mtext.len > 0: mtext.add " -> "
      mtext.add id
    line "  the manager resolves: " & mtext
    let status = call("/aowlspt/mods", "")
    if status.ok:
      var sroot = 0
      skipWs(status.body, sroot)
      line "  the manager reports: " &
           textVal(status.body, memberValue(status.body, sroot, "summary"))
      line "  live control: " &
           textVal(status.body, memberValue(status.body, sroot, "control"))
    var loadedIds2: seq[string] = @[]
    for m in ar.mods:
      loadedIds2.add m.guid
    # Every pair, not a running maximum: what matters is which mod came up
    # before which, and a single out-of-place entry otherwise reports every mod
    # after it as wrong too.
    var outOfOrder = 0
    for a in 0 ..< resolved.len:
      for b in (a + 1) ..< resolved.len:
        let pa = indexOfIn(loadedIds2, resolved[a])
        let pb = indexOfIn(loadedIds2, resolved[b])
        if pa < 0 or pb < 0:
          continue
        if pa > pb:
          inc outOfOrder
          line "    the manager puts " & resolved[a] & " before " &
               resolved[b] & "; the host loaded them the other way round"
    check("the order the manager computes is the order the host loaded",
          outOfOrder == 0,
          $outOfOrder & " pair(s) are inverted. The manager resolves an order " &
          "and writes it to aowlspt-selection.json; `modhost.loadAll` loads " &
          "whatever `collectEntries` hands back, which is a directory walk")

  reportEvents(ar)

  # -- routes ---------------------------------------------------------------

  heading "Routes"
  line "  " & $ar.routes.len & " registered, " & $baseRoutes.len &
       " of them the emulator's"
  var dupes = 0
  if not quick:
    for x in 0 ..< pairRoutes.len:
      let u = pairRoutes[x]
      if has(ar.routes, u):
        continue
      inc dupes
      err "route refused: " & u & " -- " & pairOwner[x] &
          " registers it alone, and it is not in the router with everything " &
          "loaded"
      let winner = ownerOf(ar, u)
      if winner.len > 0:
        line "    the load window that did register it: " & winner
      inc gFailures
      inc gChecks
    for u in baseRoutes:
      if has(ar.routes, u):
        continue
      inc dupes
      err "route refused: " & u & " -- aowl.tarkov registers it alone and it " &
          "is not in the router with everything loaded"
      inc gFailures
      inc gChecks
    # What the loops above had to look at. Both of them iterate a list built by
    # the pair runs, and both report by *absence* -- a route that is in the list
    # and not in the all run. An empty list has no absences in it, so with no
    # pair runs behind it "no route was refused as a duplicate" is a sentence
    # about nothing, and it is the sentence somebody reads to decide that ten
    # mods share a router safely.
    check("there were pair-run routes to look for in the all-mods router",
          pairRoutes.len > 0 or baseRoutes.len > 0,
          "neither the baseline nor any pair run registered a route, so " &
          "nothing could be found missing")
    line "  " & $pairRoutes.len & " route(s) from pair runs and " &
         $baseRoutes.len & " from the emulator were looked for here"
    check("no route was refused as a duplicate", dupes == 0,
          $dupes & " route(s) went missing between one mod and ten")
  else:
    skip("route collisions", "--quick: there are no pair runs to compare")

  # -- the database ---------------------------------------------------------

  heading "The database, after everyone has written"
  probeAll(gAllLeaves)
  if quick:
    skip("each mod's contribution survives", "--quick")
  else:
    # Both sides of the comparison, said out loud and asserted, before any
    # conclusion is drawn from their difference. `lost` and `conflicts` are
    # counts of things *found* in `pairLeafPath`; with no pair contributions
    # collected they are zero, and zero is what a database where nothing was
    # overwritten looks like. The two are told apart here and nowhere else.
    line "  " & $pairLeafPath.len & " database leaf/leaves were attributed to " &
         "a mod by the pair runs; the all-mods run reads " &
         $leafCount(gAllLeaves) & " across " & $probesRead(gAllLeaves) &
         " of " & $Probes.len & " probes"
    check("the pair runs attributed some database writes to somebody",
          pairLeafPath.len > 0,
          "no mod was seen to write anything of its own, so `lost write` and " &
          "`overwritten` below are conclusions drawn from an empty list")
    check("and the all-mods run can be read back to compare against",
          leafCount(gAllLeaves) > 0,
          "all " & $Probes.len & " probes came back empty (" &
          namedEmptyProbes(gAllLeaves) & ")")
    var lost = 0
    var conflicts = 0
    for x in 0 ..< pairLeafPath.len:
      let bar = findAt(pairLeafPath[x], "|", 0)
      let label = pairLeafPath[x].substr(0, bar - 1)
      let path = pairLeafPath[x].substr(bar + 1, pairLeafPath[x].len - 1)
      var p = -1
      for q in 0 ..< Probes.len:
        if Probes[q].label == label: p = q
      if p < 0 or p >= gAllLeaves.len:
        continue
      let now = valueOf(gAllLeaves[p], path)
      if not hasPath(gAllLeaves[p], path):
        inc lost
        err "lost write: " & label & " " & path & " -- " & pairLeafOwner[x] &
            " writes " & pairLeafVal[x] & " when it is alone; with every mod " &
            "loaded the path is not there at all"
        inc gFailures
        inc gChecks
        continue
      if now == pairLeafVal[x]:
        continue
      # Somebody else's value is at this path. Who else wrote it?
      var other = ""
      for y in 0 ..< pairLeafPath.len:
        if y == x or pairLeafPath[y] != pairLeafPath[x]:
          continue
        if pairLeafOwner[y] != pairLeafOwner[x]:
          other = pairLeafOwner[y] & " writes " & pairLeafVal[y] & "; "
      if other.len == 0:
        # One writer and a different value. That is not an overwrite -- an
        # overwrite needs a second writer -- so it is reported and not failed.
        # `mods/blackdivision` re-rolls its boss spawns from a clock seed, and
        # two runs of it agreeing is luck rather than determinism, so this
        # branch is reached by a mod that is simply not reproducible.
        note "differs, and no other mod writes it: " & label & " " & path
        line "    " & pairLeafOwner[x] & " wrote " & pairLeafVal[x] &
             " in its own run"
        line "    with everything loaded: " & now
        continue
      inc conflicts
      err "overwritten: " & label & " " & path
      line "    " & pairLeafOwner[x] & " writes " & pairLeafVal[x]
      line "    " & other
      line "    what survives with everything loaded: " & now
      inc gFailures
      inc gChecks
    check("every mod's database contribution survives the others",
          lost == 0 and conflicts == 0,
          $lost & " lost, " & $conflicts & " overwritten")
    # And the conflict a pairwise diff structurally cannot see.
    #
    # A mod that writes one field on *every* map -- SAIN's `BotLocationModifier`
    # is the case that motivated this -- writes it on the maps that exist when
    # its `on_load` runs. A map another mod creates later does not get one, and
    # no diff of "what this mod wrote alone" against "what is there at the end"
    # can notice, because alone the mod never saw that map at all. What can
    # notice is the shape: a field that is on every location in the pair run and
    # missing from a location in the all run.
    var covFields: seq[string] = @[]
    var covOwner: seq[string] = @[]
    var baseMaps: seq[string] = @[]
    if gBaseLeaves.len > 0:
      for pth in gBaseLeaves[0].paths:
        let dot = findAt(pth, ".", 0)
        if dot > 0 and not has(baseMaps, pth.substr(0, dot - 1)):
          baseMaps.add pth.substr(0, dot - 1)
    var allMaps: seq[string] = @[]
    if gAllLeaves.len > 0:
      for pth in gAllLeaves[0].paths:
        let dot = findAt(pth, ".", 0)
        if dot > 0 and not has(allMaps, pth.substr(0, dot - 1)):
          allMaps.add pth.substr(0, dot - 1)
    # Every `<map>.base.<field>` a mod wrote, as (owner, field, map).
    var wf: seq[string] = @[]     ## owner & "|" & field
    var wm: seq[string] = @[]     ## the map it was written on
    for x in 0 ..< pairLeafPath.len:
      if not pairLeafPath[x].startsWith("locations|"):
        continue
      let rest = pairLeafPath[x].substr(10, pairLeafPath[x].len - 1)
      let dot = findAt(rest, ".base.", 0)
      if dot <= 0:
        continue
      let mapId = rest.substr(0, dot - 1)
      var field = rest.substr(dot + 6, rest.len - 1)
      let cut = findAt(field, ".", 0)
      if cut > 0:
        field = field.substr(0, cut - 1)
      let key = pairLeafOwner[x] & "|" & field
      var seen = false
      for y in 0 ..< wf.len:
        if wf[y] == key and wm[y] == mapId: seen = true
      if not seen:
        wf.add key
        wm.add mapId
    var gaps = 0
    for x in 0 ..< wf.len:
      var covered = 0
      for y in 0 ..< wf.len:
        if wf[y] == wf[x] and has(baseMaps, wm[y]):
          inc covered
      # Only a field the mod put on *every* map it could see. A field it wrote
      # on some maps and not others is a choice, not a gap.
      if baseMaps.len == 0 or covered < baseMaps.len:
        continue
      let bar = findAt(wf[x], "|", 0)
      let owner = wf[x].substr(0, bar - 1)
      let field = wf[x].substr(bar + 1, wf[x].len - 1)
      var already = false
      for y in 0 ..< covFields.len:
        if covFields[y] == field and covOwner[y] == owner: already = true
      if already:
        continue
      covFields.add field
      covOwner.add owner
      for mapId in allMaps:
        var found = false
        for pth in gAllLeaves[0].paths:
          if pth.startsWith(mapId & ".base." & field):
            found = true
        if found:
          continue
        inc gaps
        err "missing on a map it never saw: " & owner & " writes " & field &
            " on every location that exists when it loads, and locations." &
            mapId & " has none"
        line "    " & mapId & " is created by a mod that loaded after " &
             owner & "; nothing re-runs the earlier mod"
        inc gFailures
        inc gChecks
    # The inputs to that one, for the same reason. `covered < baseMaps.len`
    # skips a field the mod did not put on every map, and `baseMaps.len == 0`
    # skips everything -- so a `locations` probe that answered nothing turns
    # this into "gaps == 0", which is what a clean run looks like. The counts
    # are printed and the empty case is a stated skip rather than a pass.
    if baseMaps.len == 0:
      skip("a per-location field is on every location, whoever made it",
           "the baseline `locations` probe returned no maps, so there is no " &
           "per-map field to look for. Nothing here checked coverage")
    elif covFields.len == 0:
      skip("a per-location field is on every location, whoever made it",
           "no mod writes a `<map>.base.<field>` on all " & $baseMaps.len &
           " baseline map(s), so there is no coverage claim to test")
    else:
      line "  " & $covFields.len & " field(s) written on every one of the " &
           $baseMaps.len & " baseline map(s), checked against " &
           $allMaps.len & " map(s) in the all-mods run"
      check("a per-location field is on every location, whoever made it",
            gaps == 0, $gaps & " location(s) are missing one")

    if gUnstable.len > 0:
      line "  " & $gUnstable.len & " database leaf/leaves are not stable " &
           "across two runs of the same mod alone, and are excluded from the " &
           "comparison above:"
      var shown = 0
      for x in 0 ..< gUnstable.len:
        if shown >= 6:
          line "    ... and " & $(gUnstable.len - shown) & " more"
          break
        line "    " & gUnstableOwner[x] & "  " & gUnstable[x]
        inc shown
    for p in 0 ..< gAllLeaves.len:
      if gAllLeaves[p].truncated:
        note "the " & Probes[p].label & " diff hit the leaf cap (" &
             $MaxLeaves & ") and is partial"

  # -- the client still boots ----------------------------------------------

  bootSequence("fixture, ten mods")

  # -- and every route in the table asked over the wire ---------------------
  #
  # After the boot sequence, never before: a route that changes something would
  # change it under the sequence's feet. The mutating ones are left alone for
  # the same reason -- this gate is about a router with ten mods in it, and
  # driving the manager's own switches is what `livectl` is for.
  heading "Every route answers"
  var unanswered = 0
  var untouched = 0
  var driven = 0
  for u in ar.routes:
    if u.endsWith("*") or mutating(u):
      inc untouched
      continue
    inc driven
    let r = call(u, "")
    if not r.ok or r.contains("\"err\":\"no route\""):
      inc unanswered
      line "    silent route " & u & ": " &
           (if r.ok: r.body.substr(0, 90) else: r.error)
  # How many were asked, before what they answered. `unanswered == 0` is true of
  # a sweep over an empty route table, and an empty route table is precisely
  # what a short read of the log produces -- the failure this file's own comment
  # about `waitForListening` describes. A run with ten mods in it that drove no
  # routes has established nothing, and it should not be able to say so quietly.
  check("there were routes to drive", driven > 0,
        "the route table read out of the log has " & $ar.routes.len &
        " entries and none of them is an exact, read-only route; this sweep " &
        "asked the server nothing")
  check("every exact, read-only route answers over the wire", unanswered == 0,
        $unanswered & " of " & $driven & " did not")
  line "  " & $driven & " driven, " & $untouched &
       " prefix or state-changing route(s) not driven here"

  # -- cost -----------------------------------------------------------------

  heading "Cost"
  let allTickUs = idleCpuUsPerTick(handle, gIdleSecs)
  let allIdleUs = gLastIdleCpuUs
  if quick:
    line "  boot with " & $ar.mods.len & " mods: " & $ar.bootMs & " ms"
  else:
    line "  boot, one mod (the emulator):  " & $baseBootMs & " ms"
    line "  boot, " & $ar.mods.len & " mods loaded:        " & $ar.bootMs & " ms"
    line "  the host's own clock at `listening`: " & $ar.listenMs & " ms"
    line "  idle CPU over " & $gIdleSecs & " s, one mod:      " &
         (if baseIdleUs < 0'i64: "unavailable"
          else: $baseIdleUs & " us = " & $baseTickUs & " us per 50 ms tick")
  line "  idle CPU over " & $gIdleSecs & " s, " & $ar.mods.len & " mods:   " &
       (if allIdleUs < 0'i64: "unavailable"
        else: $allIdleUs & " us = " & $allTickUs & " us per 50 ms tick")
  if allIdleUs == 0'i64 or baseIdleUs == 0'i64:
    let ticks = int64(gIdleSecs) * 1000'i64 div 50'i64
    line "  a zero there is the clock, not the server: GetProcessTimes moves " &
         "in 15.6 ms steps, so it means under " & $(15625'i64 div ticks) &
         " us a tick"
  var routeMs = 0'i64
  let began2 = micros()
  var reqs = 0
  while reqs < 200:
    discard call("/client/game/keepalive", "")
    inc reqs
  routeMs = (micros() - began2) div 1000'i64
  line "  200 keepalives with everything loaded: " & $routeMs & " ms (" &
       $((micros() - began2) div 200'i64) & " us each)"

  stopBackend(handle)

  # -- and again against a real database ------------------------------------

  heading "Real data"
  if realDb.len == 0 or not fileExists(realDb):
    note "skipped: there is no imported database at " &
         (if realDb.len > 0: realDb else: "build\\db\\db.json")
    note "  produce one with:  aowl importdb --from D:\\SPT"
    note "  it reads an SPT install, never writes to one, and takes a second."
  else:
    let rroot = joinPath(stageRoot, "real")
    note "database: " & realDb & ", " &
         $(fileSizeOf(realDb) div 1048576'i64) & " MiB"
    if not stage(repo, rroot, realDb, allIdx):
      return 1
    var h3 = 0'u64
    # Ten minutes of patience, not thirty seconds. A real database is 39 MiB
    # and two of these mods walk the bot tables at load; the fixture boot is a
    # second and this one is not, which is a number this gate is here to
    # report rather than a timeout to trip over.
    let rr = runBackend(backend, rroot, h3, 24000)
    if not rr.ok:
      err "the all-mods run over a real database did not come up"
      for e in rr.errors: line "  " & e
      stopBackend(h3)
    else:
      line "  up in " & $rr.bootMs & " ms with " & $allIdx.len & " staged"
      reportLoad(rr, serverIds)
      var missingRoutes = 0
      for u in ar.routes:
        if not has(rr.routes, u):
          inc missingRoutes
          err "route " & u & " is registered against the fixture and not " &
              "against real data"
      check("the same routes are registered against real data",
            missingRoutes == 0, $missingRoutes & " differ")
      for e in rr.errors:
        line "  error " & e
      for w in rr.warnings:
        line "  warn  " & w
      check("no mod failed against real data", rr.errors.len == 0,
            $rr.errors.len & " error line(s) in the host log")
      bootSequence("real data, ten mods")
      let realTick = idleCpuUsPerTick(h3, gIdleSecs)
      line "  idle CPU per 50 ms tick, real data: " &
           (if realTick < 0'i64: "unavailable" else: $realTick & " us")
      stopBackend(h3)

  heading "Summary"
  line "  " & $gChecks & " check(s), " & $gFailures & " failed, " &
       $gSkipped & " skipped"
  if gFailures == 0:
    ok "every mod in the registry ran together"
    return 0
  err $gFailures & " integration failure(s) -- see the lines above"
  result = 1

quit(main())
