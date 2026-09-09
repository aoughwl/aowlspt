## modreport -- the client host's outcome report, driven without a host.
##
## `host/common/modcontrol.nim` grew a way for the *client* host to say what
## actually happened to a mod, because until it did the manager's `live` and
## `restart` verdicts for anything on the client side were the server's guess:
## it knew what it had asked for and never learned whether it worked.
##
## The report rides the query string of the poll the client host already makes,
## so the only two ways to exercise it are a running game or this: the module
## driven directly, with a `HostOps` standing in for a loader, so that every
## outcome -- including the ones a stage cannot produce on demand, like a host
## with no teardown or a library announcing the wrong guid -- is asserted rather
## than reasoned about.
##
## What this does **not** establish: that the path reaches the backend. That is
## `aowl_ov_sync_start` and the overlay's worker thread, and this used to add
## that the half "has no gate of its own". **It has one now**: `tests/ovsync`,
## 24 checks, which starts a real backend with the manager on it, starts the
## real worker out of `abi/aowlspt_overlay.h`, toggles a mod through the
## manager's route and asserts the new answer arrives in `parseDesired`'s
## output -- then carries `reportPath`'s query string up the same worker and
## finds it again in the manager's ledger.
##
## The division of labour is still worth keeping straight, because it is why
## both files exist. This one writes one end of the wire and reads it with the
## other, so it can be exhaustive about **shapes** cheaply and with no ports.
## `ovsync` is expensive and is exhaustive about nothing -- it establishes the
## single fact no amount of shape-checking here can: that the string this file
## builds arrives.
##
## Wired into `aowl test` under "The mod manager's rules". To run it alone:
##
##   nimony c --passC:-I<repo>\abi -p:<repo>\host\common
##            -p:<repo>\installer\src -p:<repo>\aowl\src
##            -o:modreport.exe modreport.nim
##
## Those two paths held a literal BEL byte until now: a backslash was eaten
## when this file was written, and `\a` is how it survives. A build line in a
## comment exists to be pasted, so it is worth pasting once after writing it.
##
## Drives modcontrol's outcome ledger directly: no host, no runtime, no server.
import std/[strutils, syncio]
import aowlsptinstall/winfs
import modcontrol

# A file that certainly exists, wherever this is run from.
#
# The load path asks exactly one thing of a library path -- that `fileExists`
# says yes -- so the test needs a real file and nothing more. It used to point
# at its own source (`dir: ".", lib: "modreport.nim"`), which is true only when
# the run happens to start in `tests/modreport`. Run from the repo root, as the
# gate does, three checks failed for a reason that had nothing to do with what
# they test. A test that depends on the caller's working directory is a test
# that reports on the caller.
const ProbeName = "modreport.probe"
discard writeTextFile(ProbeName, "not a library, and does not need to be" & "\n")

var fails = 0
proc check(what: string; cond: bool) =
  if cond:
    echo "ok   ", what
  else:
    echo "FAIL ", what
    fails = fails + 1

# --- a HostOps that pretends nothing is loaded and refuses everything --------
var gLive: seq[string] = @[]
var gPaths: seq[string] = @[]
var gNextGuid = ""
var gLog: seq[string] = @[]
var gCanUnload = true
var gLoadOk = true

proc opCount(): int = gLive.len
proc opGuid(i: int): string = (if i >= 0 and i < gLive.len: gLive[i] else: "")
proc opText(i: int): string = ""
proc opPath(i: int): string = (if i >= 0 and i < gPaths.len: gPaths[i] else: "")
proc opLive(i: int): bool = i >= 0 and i < gLive.len
proc opFlags(i: int): uint32 = 0'u32
proc opIndex(guid: string): int =
  result = -1
  for i in 0 ..< gLive.len:
    if gLive[i] == guid: return i
proc opCanUnload(i: int): bool = gCanUnload
proc opLoad(path: string): bool =
  if not gLoadOk:
    return false
  gLive.add gNextGuid
  gPaths.add path
  result = true
proc opUnload(guid: string): string = "this host will not"
proc opLog(m: string) = gLog.add m
proc opEmit(name, payload: string) = discard

controlInit("test", "0.1.0", 1'i32, opEmit,
            HostOps(count: opCount, guidOf: opGuid, nameOf: opText,
                    versionOf: opText, pathOf: opPath, liveOf: opLive,
                    flagsOf: opFlags, indexOf: opIndex,
                    canUnload: opCanUnload, load: opLoad, unload: opUnload,
                    log: opLog))

const Base = "/aowlspt/mods/client/0.1.0"

# --- nothing said yet -------------------------------------------------------
check("with no session, the path is the bare route",
      reportPath(Base) == Base)
reportSession("deadbeef")
check("with a session but no rows, the path is still the bare route",
      reportPath(Base) == Base)
check("the sequence starts at zero", reportSeq() == 0)

# --- a settled mod ----------------------------------------------------------
gLive = @["aowl.one"]
var want: seq[DesiredMod] = @[]
want.add DesiredMod(guid: "aowl.one", enabled: true, dir: "one", lib: "one.dll")
applyDesired(want, "C:\nowhere")
check("a settled mod is reported as a noop",
      reportPath(Base) == Base & "?hs=deadbeef&sq=1&r=aowl.one~+n")
check("the sequence moved once", reportSeq() == 1)

# --- and saying it again is not news ----------------------------------------
let before = reportSeq()
applyDesired(want, "C:\nowhere")
check("re-stating the same set does not move the sequence",
      reportSeq() == before)
check("the path is unchanged", reportPath(Base) == Base &
      "?hs=deadbeef&sq=1&r=aowl.one~+n")

# --- a mod the registry has no artifact for ---------------------------------
want.add DesiredMod(guid: "aowl.two", enabled: true, dir: "", lib: "")
applyDesired(want, "C:\nowhere")
check("a mod with no artifact is skipped, not attempted",
      reportPath(Base) == Base &
      "?hs=deadbeef&sq=2&r=aowl.one~+n!aowl.two~+s~noartifact")

# --- a mod whose library is not installed on this side ----------------------
want.add DesiredMod(guid: "aowl.three", enabled: true, dir: "three",
                    lib: "three.dll")
applyDesired(want, "C:\nowhere")
check("a mod whose library is missing on this side is skipped",
      reportPath(Base) == Base & "?hs=deadbeef&sq=3&r=aowl.one~+n" &
      "!aowl.two~+s~noartifact!aowl.three~+s~nofile")

# --- an unload this host refuses --------------------------------------------
want = @[]
want.add DesiredMod(guid: "aowl.one", enabled: false, dir: "one",
                    lib: "one.dll")
applyDesired(want, "C:\nowhere")
check("the rows for guids the backend stopped naming are dropped",
      reportPath(Base) == Base & "?hs=deadbeef&sq=5&r=aowl.one~+n")
drain()
check("a refused unload is deferred, and the reason is the unload itself",
      reportPath(Base) == Base & "?hs=deadbeef&sq=6&r=aowl.one~-d~unloadfailed")

# --- the same, on a host that cannot unload at all --------------------------
gCanUnload = false
want = @[]
want.add DesiredMod(guid: "aowl.four", enabled: false, dir: "", lib: "")
gLive = @["aowl.four"]
applyDesired(want, "C:\nowhere")
drain()
check("a host with no teardown says so rather than blaming the mod",
      reportPath(Base) == Base & "?hs=deadbeef&sq=8&r=aowl.four~-d~noteardown")

# --- "not attempted" and "no answer yet" are not the same -------------------
check("a guid that was never named appears nowhere in the report",
      find(reportPath(Base), "aowl.two") < 0)

# --- a load that works, and a load of the wrong library ---------------------
#
# The "library" is this test's own source file, because the only thing the load
# path asks of it is that `fileExists` says yes -- the loader itself is the
# `HostOps` above.
gCanUnload = true
gLive = @[]
gPaths = @[]
gNextGuid = "aowl.five"
want = @[]
want.add DesiredMod(guid: "aowl.five", enabled: true, dir: ".",
                    lib: ProbeName)
applyDesired(want, ".")
drain()
check("a load that worked is reported as done",
      find(reportPath(Base), "aowl.five~+k") >= 0)

# And the same mod, one poll later, once the state has settled.
applyDesired(want, ".")
check("a done load decays to a settled noop rather than staying news",
      find(reportPath(Base), "aowl.five~+n") >= 0)

gNextGuid = "aowl.impostor"
want = @[]
want.add DesiredMod(guid: "aowl.six", enabled: true, dir: ".",
                    lib: ProbeName)
applyDesired(want, ".")
drain()
check("a library announcing another guid is refused, and named as such",
      find(reportPath(Base), "aowl.six~+r~wrongguid") >= 0)

# --- the budget -------------------------------------------------------------
gLive = @[]
want = @[]
var many = 0
while many < 20:
  want.add DesiredMod(guid: "aowl.longishmodname" & $many, enabled: false,
                      dir: "", lib: "")
  many = many + 1
applyDesired(want, "C:\nowhere")
var seen: seq[string] = @[]
var round = 0
var everTruncated = false
while round < 8:
  let p = reportPath(Base)
  check("no path ever exceeds what the feed can carry", p.len <= 191)
  if reportPending(): everTruncated = true
  for g in want:
    if find(p, g.guid & "~") >= 0:
      var already = false
      for s in seen:
        if s == g.guid: already = true
      if not already: seen.add g.guid
  round = round + 1
check("a report too long for one path says so", everTruncated)
check("every row is said within a few rotations, none starved",
      seen.len == 20)
check("truncation is flagged on the wire",
      find(reportPath(Base), "&more=1") >= 0)

discard removeFileAt(ProbeName)

if fails == 0:
  echo "all checks passed"
else:
  echo $fails & " checks failed"
