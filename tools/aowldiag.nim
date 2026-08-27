## aowldiag -- when the client does not come up, say WHY.
##
## The launcher used to end a failed launch with one line: "the client exited
## while starting; see aowlspt-host.log". That is a pointer, not a diagnosis,
## and the run it was written for cost many minutes of hand-reading three logs
## in two directories to find a mod that had refused to load.
##
## ---------------------------------------------------------------------------
## The predicate: what counts as "failed"
## ---------------------------------------------------------------------------
##
## NOT a timeout. This client legitimately takes more than sixty seconds to
## reach profile-select, and once it is there it waits for a human forever --
## so "N seconds and nothing on screen" is indistinguishable from a perfectly
## healthy launch, and a launcher that cried failure on that would be wrong on
## every good run. Two signals, and they are reported differently:
##
##   CONFIRMED -- the client PROCESS EXITED before `host running`. Unambiguous,
##     and fast: today's real failure had the host log reach `host running` at
##     1.750s and the process gone at 1.781s. Process exit fires in under two
##     seconds; no timeout would have helped, and no timeout was needed.
##
##   SUSPECTED -- the process is alive but the host's own boot ladder has not
##     advanced a rung for a long interval. That is evidence, not proof: an
##     idle game and a hung game look the same from out here. It is printed as
##     a suspicion, in those words, and never as a cause.
##
## ---------------------------------------------------------------------------
## The diagnosis: ranked, and never invented
## ---------------------------------------------------------------------------
##
## Three sources, most-likely first, each producing findings that carry the
## LOG LINE they were derived from -- so the reader can disagree with us:
##
##   1. `aowlspt-backend.log` -- a mod that refused to load. This is today's
##      exact case and the reason this file exists: `mods/tarkov`'s self-check
##      found `data/post1/globalsgaps.json` missing, logged `this build fails
##      its own arithmetic; refusing to serve`, and registered ONLY its
##      selfcheck route. What the player SAW was "unable to check client
##      version" -- a message pointing nowhere near the cause.
##   2. `aowlspt-host.log` -- errors, and the last boot rung reached.
##      `il2cpp_init returned 0` means the runtime never came up at all.
##   3. The client's own log directory under `<root>\Logs\` -- but ONLY a
##      directory that was not there before this launch. A stale directory from
##      a previous run presented as this run's evidence is exactly the trap
##      that makes a confident diagnosis wrong, so the set is SNAPSHOTTED
##      before the client is resumed and diffed afterwards.
##
## If nothing matches, this says so. "The logs show no known cause" is a true
## and useful answer; a confidently wrong cause is worse than no answer, and
## costs the reader more than silence would have.

import std/strutils
import aowlsptinstall/[winfs, log]
import aowlterm

# ---------------------------------------------------------------------------
# What a diagnosis is
# ---------------------------------------------------------------------------

type
  Confidence* = enum
    cfConfirmed   ## the process exited: this is a fact
    cfSuspected   ## the ladder stalled: this is a suspicion

  Finding* = object
    title*: string     ## the cause, in one line
    evidence*: string  ## the log line it was read out of, verbatim
    source*: string    ## which file that line came from

  LaunchSnapshot* = object
    ## Taken BEFORE the client is resumed. Its only job is to make "this run's
    ## client log" a decidable question instead of a guess about timestamps.
    logDirs*: seq[string]
    taken*: bool       ## false when the Logs directory could not be listed --
                       ## which makes every later client-log claim inconclusive
                       ## rather than false.

proc newFinding(title, evidence, source: string): Finding =
  result = Finding(title: title, evidence: evidence, source: source)

# ---------------------------------------------------------------------------
# The snapshot
# ---------------------------------------------------------------------------

proc clientLogsDir*(root: string): string =
  joinPath(root, "Logs")

proc topLevelDirs(p: string): seq[string] =
  result = @[]
  if not exists(p): return
  var files: seq[string] = @[]
  var dirs: seq[string] = @[]
  collectEntries(p, files, dirs)
  for d in dirs:
    if find(d, "\\") < 0 and find(d, "/") < 0:
      result.add d

proc snapshotBefore*(root: string): LaunchSnapshot =
  ## Every client log directory that exists right now. Anything that appears
  ## after this is, by construction, this run's.
  let dir = clientLogsDir(root)
  result = LaunchSnapshot(logDirs: @[], taken: exists(dir))
  if result.taken:
    result.logDirs = topLevelDirs(dir)

proc newClientLogDir*(root: string; before: LaunchSnapshot): string =
  ## "" when there is none, or when we could not tell.
  result = ""
  if not before.taken: return
  for d in topLevelDirs(clientLogsDir(root)):
    var seen = false
    for old in before.logDirs:
      if toLowerAscii(old) == toLowerAscii(d): seen = true
    if not seen:
      # Newest wins if several appeared; the names sort chronologically
      # (`log_2026.08.27_12-22-39_...`), so a plain string compare is the
      # right order here and not a coincidence worth relying on elsewhere.
      if d > result: result = d

# ---------------------------------------------------------------------------
# The host's boot ladder
# ---------------------------------------------------------------------------

type
  Ladder* = object
    rung*: int         ## 0 = nothing written at all
    name*: string      ## what that rung is called
    initReturnedZero*: bool
    errors*: int
    lastError*: string
    modsLoaded*: int

const LadderTop* = 8

proc rungName*(n: int): string =
  case n
  of 0: "nothing yet"
  of 1: "battleye answered"
  of 2: "il2cpp_init returned"
  of 3: "il2cpp up"
  of 4: "il2cpp bound"
  of 5: "mods loaded"
  of 6: "overlay ready"
  of 7: "HOST RUNNING"
  else: "Unity thread live"

proc scanLadder*(t: Tail): Ladder =
  ## The rungs are matched on the substrings the host actually writes -- read
  ## out of a live `aowlspt-host.log`, not guessed from the source.
  result = Ladder(rung: 0, name: rungName(0), initReturnedZero: false,
                  errors: 0, lastError: "", modsLoaded: 0)
  var top = 0
  for l in t.lines:
    let s = l.text
    if l.level == lvError:
      inc result.errors
      result.lastError = s
    var r = 0
    if find(s, "BattlEye service guard is answered") >= 0: r = 1
    elif find(s, "il2cpp_init returned") >= 0:
      r = 2
      if find(s, "il2cpp_init returned 0") >= 0:
        result.initReturnedZero = true
    elif find(s, "IL2CPP is up after") >= 0: r = 3
    elif find(s, "IL2CPP runtime bound") >= 0: r = 4
    elif startsWith(s, "loaded ") and l.level == lvOk:
      r = 5
      inc result.modsLoaded
    elif find(s, "overlay ready") >= 0: r = 6
    elif startsWith(s, "host running"): r = 7
    elif find(s, "runs on Unity's main thread") >= 0 or
         find(s, "the main-thread drain is firing") >= 0: r = 8
    if r > top: top = r
  result.rung = top
  result.name = rungName(top)

# ---------------------------------------------------------------------------
# Source 1: the backend log -- a mod that refused
# ---------------------------------------------------------------------------

proc modFromRoutePath(s: string): string =
  ## `/aowlspt/tarkov/selfcheck` -> `tarkov`. "" when the line has no such
  ## path; guessing a name from prose is how a diagnosis becomes fiction.
  result = ""
  let at = find(s, "/aowlspt/")
  if at < 0: return
  let rest = s.substr(at + len("/aowlspt/"))
  var name = ""
  for ch in rest:
    if ch == '/' or ch == ' ' or ch == '?' or ch == ',' or ch == '"': break
    name.add ch
  if name.len > 0 and name != "mods": result = name

proc backendFindings(root: string): seq[Finding] =
  result = @[]
  let path = joinPath(root, "aowlspt\\aowlspt-backend.log")
  if not exists(path): return
  var t = newTail(path, 4000)
  discard t.pump()
  if t.lines.len == 0: return

  # `on_load returned an error` is the one line that NAMES the mod, so it is
  # searched first and its name is reused to attribute the unattributed
  # `refusing to serve` line below.
  var namedMod = ""
  var refusedLine = ""
  var refusedAt = -1
  var onLoadLine = ""
  var selfCheckLine = ""
  var noRouteLine = ""
  var noRouteCount = 0
  var i = 0
  for l in t.lines:
    let s = l.text
    if find(s, "on_load returned an error") >= 0:
      onLoadLine = s
      let colon = find(s, ":")
      if colon > 0: namedMod = s.substr(0, colon - 1)
    if find(s, "refusing to serve") >= 0 and refusedAt < 0:
      refusedLine = s
      refusedAt = i
    if startsWith(s, "self-check:") and selfCheckLine.len == 0:
      selfCheckLine = s
    if startsWith(s, "no route for"):
      inc noRouteCount
      if noRouteLine.len == 0: noRouteLine = s
    inc i

  if refusedAt >= 0:
    # Attribute it. The refusal line itself carries no mod name, but the line
    # after it names the route the mod DID register, and that path's first
    # segment is the mod. Fall back to the named `on_load` mod, and if neither
    # is there, say the log did not name it rather than picking one.
    var who = ""
    var j = refusedAt
    while j < t.lines.len and j < refusedAt + 4 and who.len == 0:
      who = modFromRoutePath(t.lines[j].text)
      inc j
    if who.len == 0: who = namedMod
    let subject =
      if who.len > 0: "the `" & who & "` mod"
      else: "a backend mod (the log does not name it)"
    result.add newFinding(
      subject & " REFUSED TO LOAD, so the backend answers almost nothing. " &
      "That is why the client gave up -- the message it shows (e.g. \"unable " &
      "to check client version\") names the symptom, not this.",
      refusedLine, "aowlspt-backend.log")
    if selfCheckLine.len > 0:
      result.add newFinding(
        "what the mod's own self-check found (a missing or malformed data " &
        "file under mods\\" & (if who.len > 0: who else: "<mod>") &
        "\\data is the usual reason)",
        selfCheckLine, "aowlspt-backend.log")
  elif onLoadLine.len > 0:
    result.add newFinding(
      "a backend mod's on_load failed; it is loaded but is not serving what " &
      "it should",
      onLoadLine, "aowlspt-backend.log")

  if noRouteCount > 0 and result.len == 0:
    # On its own this is weak -- an unmodded route 404s for many reasons -- so
    # it is only offered when nothing stronger was found.
    result.add newFinding(
      $noRouteCount & " request(s) hit the backend with no mod serving them. " &
      "Either the mod that owns that route is not selected, or it did not load.",
      noRouteLine, "aowlspt-backend.log")

# ---------------------------------------------------------------------------
# Source 2: the host log
# ---------------------------------------------------------------------------

proc hostFindings(lad: Ladder): seq[Finding] =
  result = @[]
  if lad.rung == 0:
    result.add newFinding(
      "the host wrote NOTHING to its log. It was injected but never got as " &
      "far as its first line -- suspect the DLL itself, or the client dying " &
      "before it ran.", "(the host log is empty or absent)", "aowlspt-host.log")
    return
  if lad.initReturnedZero:
    result.add newFinding(
      "IL2CPP never came up: `il2cpp_init` returned 0. Nothing the host does " &
      "afterwards can work, and the client is expected to die.",
      "il2cpp_init returned 0", "aowlspt-host.log")
  if lad.errors > 0:
    result.add newFinding(
      $lad.errors & " error(s) in the host log; the last one is below",
      lad.lastError, "aowlspt-host.log")
  result.add newFinding(
    "the host's boot ladder stopped at rung " & $lad.rung & "/" & $LadderTop &
    " (" & lad.name & ")" &
    (if lad.rung < LadderTop: ", so it never reached `" &
        rungName(lad.rung + 1) & "`" else: ""),
    "(last rung observed in aowlspt-host.log)", "aowlspt-host.log")

# ---------------------------------------------------------------------------
# Source 3: the client's own logs -- only this run's
# ---------------------------------------------------------------------------

proc clientLogFindings(root: string; before: LaunchSnapshot): seq[Finding] =
  result = @[]
  if not before.taken:
    result.add newFinding(
      "INCONCLUSIVE: " & clientLogsDir(root) & " could not be listed before " &
      "the launch, so no client log directory can be attributed to this run. " &
      "Not reading one is the right answer here -- an older run's directory " &
      "would look exactly like this run's.",
      "(no pre-launch snapshot)", clientLogsDir(root))
    return
  let fresh = newClientLogDir(root, before)
  if fresh.len == 0:
    result.add newFinding(
      "the client wrote NO log directory of its own this run -- it died " &
      "before Unity opened one. Every directory under Logs\\ predates this " &
      "launch and none of them is evidence about it.",
      "(no new directory under Logs\\)", clientLogsDir(root))
    return
  let dir = joinPath(clientLogsDir(root), fresh)
  var worst = ""
  var files: seq[string] = @[]
  var dirs: seq[string] = @[]
  collectEntries(dir, files, dirs)
  for f in files:
    let lower = toLowerAscii(f)
    if find(lower, "application") >= 0 or find(lower, "output") >= 0:
      var text = ""
      if readTextFile(joinPath(dir, f), text):
        for raw in splitLines(text):
          let s = strip(raw)
          if s.len == 0: continue
          if find(s, "Exception") >= 0 or find(s, "|Error|") >= 0 or
             startsWith(s, "Error") or find(s, "Fatal") >= 0:
            worst = f & ": " & s
            break
      if worst.len > 0: break
  if worst.len > 0:
    result.add newFinding(
      "the client's own log for THIS run has an error in it",
      worst, dir)
  else:
    result.add newFinding(
      "this run's client log directory exists but has no line matching a " &
      "known error shape -- read it by hand",
      "(no Exception/Error/Fatal line found)", dir)

# ---------------------------------------------------------------------------
# Putting it together
# ---------------------------------------------------------------------------

proc diagnose*(root: string; before: LaunchSnapshot; lad: Ladder): seq[Finding] =
  ## Ranked: a refusing mod, then the host, then the client's own log. The
  ## caller prints the first as the top candidate and the rest as where to
  ## look next.
  result = @[]
  for f in backendFindings(root): result.add f
  for f in hostFindings(lad): result.add f
  for f in clientLogFindings(root, before): result.add f

proc reportLaunchFailure*(root: string; before: LaunchSnapshot; lad: Ladder;
                          conf: Confidence; headline: string) =
  ## The whole point of this file. Loud, ranked, and honest about which of the
  ## three outcomes this is.
  heading (if conf == cfConfirmed: "The client did not start"
           else: "The client may be stuck")
  if conf == cfConfirmed:
    err headline
  else:
    warn "SUSPECTED, not confirmed -- the process is still alive. " & headline
    warn "An idle client waiting for a human looks exactly like this. " &
         "Nothing below is asserted as the cause."

  let findings = diagnose(root, before, lad)
  if findings.len == 0:
    warn "the logs show no known cause. That is the honest answer -- " &
         "nothing here matched a failure this launcher knows how to name."
  else:
    line ""
    line "  MOST LIKELY CAUSE"
    line "    " & findings[0].title
    line "    evidence (" & findings[0].source & "):"
    line "      " & findings[0].evidence
    if findings.len > 1:
      line ""
      line "  ALSO SEEN"
      var n = 0
      for i in 1 ..< findings.len:
        if n >= 4: break
        line "    - " & findings[i].title
        line "      " & findings[i].evidence
        inc n

  line ""
  line "  WHERE TO LOOK"
  line "    " & joinPath(root, "aowlspt\\aowlspt-backend.log") & "   (mods refusing to load)"
  line "    " & joinPath(root, "aowlspt\\aowlspt-host.log") & "      (the boot ladder, stopped at " & lad.name & ")"
  let fresh = newClientLogDir(root, before)
  if fresh.len > 0:
    line "    " & joinPath(clientLogsDir(root), fresh) & "  (the client's own log FOR THIS RUN)"
  else:
    line "    " & clientLogsDir(root) & "  -- no directory here belongs to this run; do not read one as if it did"

# ---------------------------------------------------------------------------
# The preflight: mod DATA that never got deployed
# ---------------------------------------------------------------------------
#
# `deploy.py` ships DLLs and executables. It does NOT ship the JSON and binary
# data those mods read, so a mod whose data file is missing from the install
# builds clean, deploys clean, verifies clean -- and then refuses to serve at
# runtime, which is the failure this whole file exists to explain. Catching it
# BEFORE the launch costs one directory walk.
#
# This is only possible when a repo checkout is reachable. On a player's
# install there is none, and the preflight says so once and stands down rather
# than reporting "nothing missing", which would be a check that cannot fail.

proc findRepoRoot*(start: string): string =
  ## Walk up looking for the two things only this repo has together. "" when
  ## there is no checkout here -- the normal case on a real install.
  result = ""
  var dir = absolutePathOf(start)
  var hops = 0
  while dir.len > 0 and hops < 12:
    if exists(joinPath(dir, "tools\\aowllaunch.nim")) and
       isDirectory(joinPath(dir, "mods")):
      return dir
    let up = parentOf(dir)
    if up == dir or up.len == 0: return
    dir = up
    inc hops

proc modDataPreflight*(root, repoRoot: string; missing: var seq[string]): bool =
  ## `false` means the check could not be made (no repo) -- which is NOT a
  ## pass. `missing` holds `<mod>\data\<rel>` for every data file the repo has
  ## and the install does not, for mods the install actually has.
  missing = @[]
  if repoRoot.len == 0: return false
  let repoMods = joinPath(repoRoot, "mods")
  let liveMods = joinPath(root, "aowlspt\\mods")
  if not isDirectory(repoMods) or not isDirectory(liveMods): return false
  var rf: seq[string] = @[]
  var rd: seq[string] = @[]
  collectEntries(repoMods, rf, rd)
  for rel in rf:
    # `<mod>\data\...` only. Anything else in the repo (source, tests) is not
    # deployed on purpose and must not be reported as missing.
    let slash = find(rel, "\\")
    if slash <= 0: continue
    let modName = rel.substr(0, slash - 1)
    let rest = rel.substr(slash + 1)
    if not startsWith(toLowerAscii(rest), "data\\"): continue
    if not isDirectory(joinPath(liveMods, modName)): continue
    # Two exclusions, both measured against the live install rather than
    # guessed. Without them this reports 751 "missing" files and is useless:
    #  * `data\capture\` -- 690 of those 751. Recorded wire captures, a
    #    development fixture that is deliberately never deployed.
    #  * `.md` -- documentation. `tarkov\data\post1\README.md` is not a
    #    thing the mod reads at runtime and its absence breaks nothing.
    # A warning nobody can read is a warning nobody reads.
    let lowRest = toLowerAscii(rest)
    if find(lowRest, "\\capture\\") >= 0: continue
    if endsWith(lowRest, ".md"): continue
    if not exists(joinPath(liveMods, rel)):
      missing.add rel
  result = true

proc runModDataPreflight*(root: string) =
  ## Called from the launcher just before the client starts. Warns; never
  ## refuses -- a missing data file is usually fatal to one mod, not to the
  ## launch, and being told beats being stopped.
  let repo = findRepoRoot(absolutePathOf("."))
  var missing: seq[string] = @[]
  if not modDataPreflight(root, repo, missing):
    note "mod-data preflight SKIPPED: no repo checkout next to this launcher " &
         "to compare the install against. This is not a pass."
    return
  if missing.len == 0:
    ok "mod data: every data file in " & joinPath(repo, "mods") &
       " is present in the install"
    return
  warn "mod data: " & $missing.len & " file(s) the repo has are MISSING from " &
       "the install. deploy.py ships DLLs, not mod data -- this is exactly " &
       "the shape of failure that makes a mod refuse to serve at runtime:"
  var n = 0
  for m in missing:
    if n >= 8:
      warn "  ... and " & $(missing.len - 8) & " more"
      break
    warn "  " & m
    inc n
