## The runnable form of the by-value-convention experiment.
##
## This mod exists to be RUN, once, on a live client, and to leave a verdict in
## the host log. It is deliberately an `examples/` mod rather than a `mods/` one:
## it settles a question and then it has no further job.
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
## check that cannot fail -- CLAUDE.md 9b, the shape of every settings-screen
## defect.
##
## SAFETY
## ------
## `Vector3::Dot` and `Vector3::Cross` are pure arithmetic on two buffers this
## process owns. No game state is read or written, nothing is allocated, and
## there is no side effect for a wrong answer to damage. It needs no GameWorld,
## no camera and no raid -- and it never gates on `whenReady("EFT.GameWorld")`,
## which is fact #141, a check that cannot fail.
##
## Default OFF. Runs ONCE. Self-disables on any fault beyond the one the rival
## control expects.
##
## RUNNING IT
## ----------
##   python tools/hostcfg.py set callProof on
##   (restart the client)
##   python tools/hostlog.py grep "call-proof"
##
## The last line is the verdict and it is one of three:
##   `VERDICT by-value aggregates pass BY HIDDEN POINTER ...`   -> settled
##   `VERDICT FAILED ...`                                       -> build nothing on it
##   `VERDICT INCONCLUSIVE ...`                                 -> not settled; not a pass

import aowlspt
import aowlspt/callproof

const FlagKey = "callProof"
const RivalKey = "callProofRival"

proc flagOn(key: string; default: bool): bool =
  ## Read a host flag. A key the host does not carry reads as `default`, and
  ## the default is OFF -- an experiment that runs because a config read failed
  ## is exactly the silent arming this project has been bitten by.
  var text = ""
  let st = configGet(key, text)
  if st != Ok:
    return default
  result = (text == "true" or text == "\"true\"" or text == "1")

proc onLoad(): Status =
  if not flagOn(FlagKey, false):
    # Say so. A feature that declines silently is the worst outcome we produce,
    # and "nothing in the log" is indistinguishable from "the mod never loaded".
    info "call-proof: flag `" & FlagKey & "` is off; not running. " &
         "Turn it on with `python tools/hostcfg.py set " & FlagKey & " on`."
    return Ok

  # The rival control is the one check that deliberately provokes an access
  # violation, so it gets its own key -- on by DEFAULT, because without it the
  # experiment cannot fail and a passing result would mean nothing.
  let rival = flagOn(RivalKey, true)
  if not rival:
    warn "call-proof: the rival negative control is disabled, so a passing " &
         "result below is UNFALSIFIED and must be read as INCONCLUSIVE."

  let report = runCallProof(includeRival = rival)
  let lines = formatCallProof(report)
  var i = 0
  while i < lines.len and i < 32:
    if report.fails > 0'i32:
      warn lines[i]
    else:
      info lines[i]
    inc i
  Ok

exportMod(
  guid = "aowl.callproof",
  name = "Call Proof",
  author = "aowlspt",
  version = "1.0.0",
  sptRange = "~4.1.0",
  sides = {sideClient, sideSim},
  onLoad = onLoad)
