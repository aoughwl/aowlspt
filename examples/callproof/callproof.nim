## The runnable form of the by-value-convention experiment.
##
## This mod exists to be RUN, once, on a live client, and to leave a verdict in
## the host log. It settles a question and then it has no further job.
##
## WHAT IT PROVES, AND WHY THE ANSWER CANNOT BE FAKED
## --------------------------------------------------
## `aowlspt/callproof` calls `UnityEngine.Vector3::Dot((1,2,3),(4,5,6))` and
## requires exactly 32.0, and `Vector3::Cross((1,2,3),(4,5,6))` and requires
## exactly (-3,6,-3). Every input and output is exactly representable in
## binary32, so those are equalities and not tolerances, and `Cross`
## anti-commutes so a swapped-argument implementation returns the NEGATION
## rather than something merely wrong-looking.
##
## It then runs the SAME `Dot` call under the RIVAL convention and requires that
## that one does NOT return 32.0. Without that control the experiment would be
## "I called it the way I believe is right and got what I expected", which is a
## check that cannot fail -- CLAUDE.md 9b.
##
## TWO DEFECTS THE FIRST LIVE RUN FOUND, AND WHAT THEY COST
## --------------------------------------------------------
## 1. The targets were `var g = rvaTarget(...)` at MODULE SCOPE. In a nimony
##    `--app:lib` build a global initialised by a CALL is silently left zeroed
##    -- rule 1 of `aowlspt/fast`, broken here anyway. The client reported
##    `@0x0: no prologue was declared`, which was true and was not the cause:
##    the entire object was zero, name included, which is why that log line
##    began with a blank. Targets are now declared bare and assigned in
##    `initTargets`, and every run prints the module base beside the resolved
##    address so a zero can never be ambiguous again.
##
## 2. It ran from `onLoad`, at 0:00:01.000 -- THIRTEEN SECONDS before the Unity
##    thread was live at 0:00:14.219. `onLoad` is the host's own thread, and
##    making a managed call there is what killed the FOV mod at 8.375s. The
##    experiment refused for an unrelated reason, so nothing broke; that was
##    luck, not design. It now holds until the host confirms its main-thread
##    drain has FIRED.
##
##    The gate is `call("aowlspt.host::main_thread")` reporting `bound`, polled
##    from `every`. It is explicitly NOT `whenReady("EFT.GameWorld")` -- fact
##    #141, a check that CANNOT FAIL: it goes true at host boot with no raid,
##    and it let three mods arm before the world existed.
##
## SAFETY
## ------
## `Vector3::Dot` and `Vector3::Cross` are pure arithmetic on two buffers this
## process owns. No game state is read or written, nothing is allocated, and
## there is no side effect for a wrong answer to damage. It needs no GameWorld,
## no camera and no raid -- only a live Unity thread, to be honest about where
## it ran.
##
## Default OFF. Runs ONCE. Self-disables on any fault beyond the one the rival
## control expects.
##
## RUNNING IT -- THE CONFIG SOURCE, MEASURED
## -----------------------------------------
## `configGet` is documented in `aowl/src/aowlspt.nim` as "this mod's config".
## It reads the DEPLOYED mod's own `config.json` -- NOT `aowlspt-host.json`.
## An earlier version of this file said to use `tools/hostcfg.py set callProof
## on`; that was WRONG, and `hostcfg.py` was right to refuse the key, because
## `hostcfg` manages HOST flags and this is a MOD setting. Two different files,
## two different readers.
##
## So, in the deployed install, `mods/callproof/config.json`:
##
##     { "callProof": true, "callProofRival": true }
##
## Then: `python tools/hostlog.py grep "call-proof"`.
##
## The verdict line is one of three:
##   `VERDICT by-value aggregates pass BY HIDDEN POINTER ...`   -> settled
##   `VERDICT FAILED ...`                                       -> build nothing on it
##   `VERDICT INCONCLUSIVE ...`                                 -> not settled; not a pass

import aowlspt
import aowlspt/server   # `setting` -- configGet with a typed reader on top
import aowlspt/json     # reading the host's main-thread report
import aowlspt/callproof

const FlagKey = "callProof"
const RivalKey = "callProofRival"

const
  DeferPollMs = 500
    ## How often to ask the host. The answer changes at most once per run.
  DeferGiveUpMs = 180_000'i64
    ## After this, report INCONCLUSIVE rather than run anyway. A surviving run
    ## confirmed the drain at 14.219s, so three minutes is not a tight bound --
    ## it is the point at which "it is coming" stops being credible.

var gRival = true
var gWaitedMs = 0'i64
var gDone = false

proc cfgBool(key: string; default: bool): bool =
  ## `setting` is `configGet` with a typed reader over it, and it reads THIS
  ## MOD'S `config.json`. A missing key returns `default`, and every default
  ## here is the safe direction.
  setting(key).asBool(default)

proc drainBound(): bool =
  ## Whether the host's main-thread drain has FIRED on Unity's thread.
  ##
  ## The host answers this before it checks whether the runtime is up, so it is
  ## meaningful even with no game -- which is exactly what makes it usable as a
  ## gate, and what `whenReady("EFT.GameWorld")` is not: that one goes true at
  ## host boot with no raid and cannot fail (fact #141).
  var raw = ""
  let empty = "[]"
  if call("aowlspt.host::main_thread", empty, raw) != Ok:
    return false
  if raw.len == 0:
    return false
  result = asBool(field(raw, "bound"), false)

proc runOnMain(payload: string): string =
  ## The experiment itself, ON the host's main thread.
  ##
  ## `every` repeats against a DEADLINE on a worker; `onMainThread` reaches the
  ## thread the host drains on. The polling gate below runs on the former and
  ## hands the actual calls to the latter, because "this ran where a managed
  ## call is legal" is the whole claim and a timer thread is not evidence for
  ## it. Dot and Cross are pure arithmetic, so off-thread would probably have
  ## survived -- "probably survived" is exactly the reasoning that killed the
  ## FOV mod at 8.375s.
  result = ""
  let report = runCallProof(includeRival = gRival)
  let lines = formatCallProof(report)
  var i = 0
  while i < lines.len and i < 32:
    if report.fails > 0'i32:
      warn lines[i]
    else:
      info lines[i]
    inc i

proc runNow() =
  if gDone: return
  gDone = true
  if onMainThread(runOnMain) != Ok:
    warn "call-proof: VERDICT INCONCLUSIVE -- onMainThread refused, so the " &
         "experiment could not be run where a managed call is legal. It was " &
         "NOT run off-thread instead."

proc poll(payload: string): string =
  ## Held until the drain fires. Says WHY it is still waiting rather than
  ## sitting silent, because "nothing in the log" is indistinguishable from
  ## "the mod never loaded".
  result = ""
  if gDone: return
  gWaitedMs = gWaitedMs + int64(DeferPollMs)
  if drainBound():
    info "call-proof: the host's main-thread drain has fired after " &
         $gWaitedMs & "ms; running the experiment now"
    runNow()
    return
  if gWaitedMs >= DeferGiveUpMs:
    gDone = true
    warn "call-proof: VERDICT INCONCLUSIVE -- aowlspt.host::main_thread never " &
         "reported `bound` in " & $gWaitedMs & "ms, so the experiment was " &
         "NEVER RUN. Nothing was called and nothing is proved. Not a pass."
    return
  if gWaitedMs == 5000'i64 or gWaitedMs == 30000'i64:
    info "call-proof: still holding at " & $gWaitedMs &
         "ms -- waiting for the host's main-thread drain, NOT for a GameWorld"

proc onLoad(): Status =
  if not cfgBool(FlagKey, false):
    info "call-proof: `callProof` is off in this mod's config.json; not " &
         "running. Set it true in mods/callproof/config.json -- NOT in " &
         "aowlspt-host.json, which a different mechanism reads."
    return Ok

  gRival = cfgBool(RivalKey, true)
  if not gRival:
    warn "call-proof: the rival negative control is disabled, so a passing " &
         "result would be UNFALSIFIED and must be read as INCONCLUSIVE."

  # NOT run here. `onLoad` is the host's own thread, ~13s before Unity's is
  # live. Everything below defers.
  info "call-proof: armed, deferring until the host's main-thread drain fires " &
       "(polling aowlspt.host::main_thread every " & $DeferPollMs & "ms)"
  discard every(DeferPollMs, poll)
  Ok

exportMod(
  guid = "aowl.callproof",
  name = "Call Proof",
  author = "aowlspt",
  version = "1.0.0",
  sptRange = "~4.1.0",
  sides = {sideClient, sideSim},
  onLoad = onLoad)
