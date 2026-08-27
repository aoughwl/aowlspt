## Does the launcher's failure diagnosis say the right thing -- and, more
## importantly, does it SHUT UP when it has nothing to say?
##
## This builds a synthetic install tree in a temp directory and runs the real
## `aowldiag` against it. No client is started, nothing under D:\Aowlspt is
## touched, and every case below is one that has actually happened or one that
## would make the feature worse than nothing if it fired wrongly.
##
## Every assertion here is about the FINISHED VERDICT, not about our own
## write: the negative cases (a healthy install must produce no mod finding; a
## stale Logs directory must never be presented as this run's) are the ones
## that can fail, and they are the point.

import std/[strutils, syncio]
import aowlsptinstall/winfs
import aowlterm
import aowldiag

var failures = 0
var checks = 0

proc check(what: string; cond: bool) =
  inc checks
  if cond:
    echo "  PASS  " & what
  else:
    echo "  FAIL  " & what
    inc failures

proc anyTitleHas(fs: seq[Finding]; sub: string): bool =
  result = false
  for f in fs:
    if find(f.title, sub) >= 0: result = true

proc anyEvidenceHas(fs: seq[Finding]; sub: string): bool =
  result = false
  for f in fs:
    if find(f.evidence, sub) >= 0: result = true

proc anyOf(xs: seq[string]; sub: string): bool =
  result = false
  for x in xs:
    if find(x, sub) >= 0: result = true

proc writeLog(p, content: string) =
  discard ensureDir(parentOf(p))
  discard writeTextFile(p, content)

proc ladderOf(p: string): Ladder =
  var t = newTail(p, 4000)
  discard t.pump()
  result = scanLadder(t)

# The host log of a launch that got all the way to `host running` and then had
# the process vanish -- which is today's real failure, verbatim in shape.
const HostLogRan = """aowlspt-host-il2cpp 0.1.0
directory X

[0:00:00.000] ok     BSG's BattlEye service guard is answered from inside the process
[0:00:01.047] ok     il2cpp_init returned 1 after 900ms
[0:00:01.047] ok     IL2CPP is up after 900ms
[0:00:01.047] ok     IL2CPP runtime bound, all essential entry points present
[0:00:01.078] ok     loaded Admin Menu (aowl.admin) v1.0.0
[0:00:01.188] ok     overlay ready (F12 opens settings)
[0:00:01.750] ok     host running
"""

const HostLogNoRuntime = """aowlspt-host-il2cpp 0.1.0

[0:00:00.000] ok     BSG's BattlEye service guard is answered from inside the process
[0:00:30.000] error  il2cpp_init returned 0 after 30000ms
"""

# What `mods/tarkov` actually writes when its self-check fails.
const BackendRefused = """aowlspt-backend 0.1.0

[0:00:00.000] ok     port 443 is free
[0:00:00.062] info   database loaded from db.json (42393671 bytes)
[0:00:00.100] info   3 mod(s) selected
[0:00:00.200] error  self-check: globals gaps: data/post1/globalsgaps.json is missing
[0:00:00.200] error  this build fails its own arithmetic; refusing to serve
[0:00:00.200] error  the reason is readable at /aowlspt/tarkov/selfcheck, which is the only route this mod registered
[0:00:00.300] ok     listening on 127.0.0.1:443
"""

const BackendHealthy = """aowlspt-backend 0.1.0

[0:00:00.000] ok     port 443 is free
[0:00:00.100] info   3 mod(s) selected
[0:00:00.200] ok     loaded tarkov
[0:00:00.300] ok     listening on 127.0.0.1:443
"""

proc main() =
  let tmp = joinPath(joinPath(absolutePathOf("."), "nimcache"), "launchdiagtest")
  discard removeTree(tmp)
  discard ensureDir(joinPath(tmp, "aowlspt"))
  discard ensureDir(joinPath(tmp, "Logs\\log_2026.01.01_00-00-00_old"))

  let backendLog = joinPath(tmp, "aowlspt\\aowlspt-backend.log")
  let hostLog = joinPath(tmp, "aowlspt\\aowlspt-host.log")

  # -------------------------------------------------------------------------
  echo "case 1: today's failure -- a mod refused to serve"
  writeLog(backendLog, BackendRefused)
  writeLog(hostLog, HostLogRan)
  let before1 = snapshotBefore(tmp)
  check "the stale Logs directory was snapshotted, so it can be excluded",
    before1.taken and before1.logDirs.len == 1
  let lad1 = ladderOf(hostLog)
  check "the ladder is read as reaching HOST RUNNING (rung 7)", lad1.rung == 7
  let d1 = diagnose(tmp, before1, lad1)
  check "there is a diagnosis at all", d1.len > 0
  check "the TOP finding is the refusing mod, not the host, not the client log",
    find(d1[0].evidence, "refusing to serve") >= 0
  check "and it names `tarkov` -- attributed from the route it registered",
    find(d1[0].title, "tarkov") >= 0
  check "the self-check line that says WHICH file is missing is carried too",
    anyEvidenceHas(d1, "globalsgaps.json")
  check "the missing data file is pointed at mods\\tarkov\\data",
    anyTitleHas(d1, "mods\\tarkov\\data")

  # -------------------------------------------------------------------------
  echo "case 2: the stale-Logs trap (fact #142)"
  check "no NEW client log directory is claimed for this run",
    newClientLogDir(tmp, before1) == ""
  check "and the report SAYS so rather than reading the old one",
    anyTitleHas(d1, "NO log directory of its own")
  discard ensureDir(joinPath(tmp, "Logs\\log_2026.08.27_12-00-00_new"))
  check "a directory that appears AFTER the snapshot is this run's",
    newClientLogDir(tmp, before1) == "log_2026.08.27_12-00-00_new"
  check "and the one that was there before is still not",
    newClientLogDir(tmp, snapshotBefore(tmp)) == ""

  # -------------------------------------------------------------------------
  echo "case 3: a healthy backend must NOT be blamed"
  writeLog(backendLog, BackendHealthy)
  let d3 = diagnose(tmp, snapshotBefore(tmp), lad1)
  check "no mod is accused when no mod refused",
    not anyTitleHas(d3, "REFUSED TO LOAD")
  check "no on_load failure is invented either",
    not anyEvidenceHas(d3, "on_load returned an error")
  check "the report still says where the ladder stopped, which is true",
    anyTitleHas(d3, "boot ladder")

  # -------------------------------------------------------------------------
  echo "case 4: the runtime never came up"
  writeLog(hostLog, HostLogNoRuntime)
  let lad4 = ladderOf(hostLog)
  check "il2cpp_init returning 0 is recognised", lad4.initReturnedZero
  let d4 = diagnose(tmp, snapshotBefore(tmp), lad4)
  check "and it is stated as the cause",
    anyTitleHas(d4, "IL2CPP never came up")

  # -------------------------------------------------------------------------
  echo "case 5: nothing to go on"
  discard removeFileAt(backendLog)
  discard writeTextFile(hostLog, "")
  let lad5 = ladderOf(hostLog)
  let d5 = diagnose(tmp, snapshotBefore(tmp), lad5)
  check "an empty host log is reported as an empty host log",
    anyTitleHas(d5, "wrote NOTHING")
  check "and no mod is named when there is no backend log to name one from",
    not anyTitleHas(d5, "REFUSED TO LOAD")

  # -------------------------------------------------------------------------
  echo "case 6: the mod-data preflight"
  var missing: seq[string] = @[]
  check "with no repo it reports UNABLE, not a pass",
    not modDataPreflight(tmp, "", missing)

  # A synthetic repo/install pair. `tarkov` exists in both, so its data is
  # compared; `notinstalled` exists only in the repo, so it must be ignored --
  # a mod the player does not have is not a missing file.
  let repo = joinPath(tmp, "repo")
  writeLog(joinPath(repo, "mods\\tarkov\\data\\post1\\globalsgaps.json"), "{}")
  writeLog(joinPath(repo, "mods\\tarkov\\data\\post1\\present.json"), "{}")
  writeLog(joinPath(repo, "mods\\tarkov\\data\\capture\\raid1\\body.bin"), "x")
  writeLog(joinPath(repo, "mods\\tarkov\\data\\post1\\README.md"), "x")
  writeLog(joinPath(repo, "mods\\tarkov\\tarkov.nim"), "not data")
  writeLog(joinPath(repo, "mods\\notinstalled\\data\\thing.json"), "{}")
  discard ensureDir(joinPath(tmp, "aowlspt\\mods\\tarkov"))
  writeLog(joinPath(tmp, "aowlspt\\mods\\tarkov\\data\\post1\\present.json"), "{}")
  check "the comparison could be made at all", modDataPreflight(tmp, repo, missing)
  check "TODAY'S BUG: the missing data file is named",
    missing.len == 1 and find(missing[0], "globalsgaps.json") >= 0
  check "  ...and the file that IS deployed is not reported",
    not anyOf(missing, "present.json")
  check "  ...nor the capture fixture, which is never deployed on purpose",
    not anyOf(missing, "body.bin")
  check "  ...nor documentation",
    not anyOf(missing, "README.md")
  check "  ...nor source, which is not data",
    not anyOf(missing, "tarkov.nim")
  check "  ...nor a mod the install does not have at all",
    not anyOf(missing, "notinstalled")

  discard removeTree(tmp)
  echo ""
  if failures == 0:
    echo "launchdiag: " & $checks & " checks, all PASS"
  else:
    echo "launchdiag: " & $failures & " of " & $checks & " FAILED"
    quit 1

main()
