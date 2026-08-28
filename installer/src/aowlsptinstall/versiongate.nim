## The hard version gate.
##
## aowlspt is built against ONE Tarkov build. The host DLL calls game code at
## byte-verified static RVAs; those RVAs move when BSG ships a new client, and
## a host that calls a moved address does not fail politely -- it takes the
## client down, or worse, reads a plausible wrong number. So the installer does
## not install onto a client it was not built for, and there is no override.
##
## This is deliberately NOT part of `compat.nim`. Everything in there is a
## verdict that `--force` can relax or that carries a "forcible" flag; this one
## cannot be relaxed by anything, and keeping it in its own module means nobody
## can add it to the forcible pile by accident.
##
## Where the required version comes from: `payload.json`'s
## `targetTarkovVersion`, already parsed into `Payload.targetTarkov`, and for
## `verify` the `tarkovVersion` recorded in the install journal. There is no
## constant in this file. A second copy of the number is a second thing to
## forget to update, and a gate that checks a stale constant is a gate that
## refuses correct installs -- which is how a hard block loses its credibility.
##
## The decision is pure so it can be tested without a game on disk, and it is
## tested BOTH ways round: a matching version must PROCEED and a mismatched one
## must REFUSE. A gate whose test only ever exercises the passing case is not a
## gate.

import eft

type
  Gate* = enum
    ## Ordered worst-last only for readability; nothing depends on the order.
    gProceed            ## the detected client is exactly the required build
    gNoRequirement      ## the payload did not say what it targets
    gUnknownDetected    ## no readable version on the client
    gMismatch           ## a readable version, and it is the wrong one

proc gateVersion*(required, detected: Version): Gate =
  ## Exact match, numerically. `compare` pads missing components with zero, so
  ## "1.1.0" and "1.1.0.0" are the same build -- they are, and treating them as
  ## different would refuse an install over a formatting difference.
  if not known(required):
    return gNoRequirement
  if not known(detected):
    return gUnknownDetected
  if compare(required, detected) == 0:
    return gProceed
  result = gMismatch

proc gateAllows*(g: Gate): bool =
  ## The single place that turns the decision into a yes or a no. Note that
  ## `gNoRequirement` and `gUnknownDetected` are NOT yes: an installer that
  ## cannot establish the version has not established that it is the right one,
  ## and "I could not look" is not a pass.
  result = g == gProceed

proc gateLines*(g: Gate; required, detected: Version;
                aowlsptVersion: string): seq[string] =
  ## What the person reads. Every branch names the required version, the
  ## detected version, and the one thing they can do about it -- because the
  ## person reading this is a beta tester whose first contact with the product
  ## is a refusal, and a refusal with no next step reads as a broken program.
  result = @[]
  case g
  of gProceed:
    result.add "required  " & $required
    result.add "detected  " & $detected
    result.add "ok        this client is the build aowlspt was made for"
  of gMismatch:
    result.add "required  " & $required
    result.add "detected  " & $detected
    result.add ""
    result.add "This build of aowlspt" &
      (if aowlsptVersion.len > 0: " (" & aowlsptVersion & ")" else: "") &
      " was made for Tarkov " & $required & " and only that build."
    result.add "Your client is " & $detected & "."
    result.add ""
    result.add "There is no way to override this and that is on purpose: the"
    result.add "host calls game code at fixed addresses that move between"
    result.add "builds, so installing onto a different client does not fail"
    result.add "cleanly -- it corrupts the run."
    result.add ""
    result.add "What to do: wait for the aowlspt build that targets " &
      $detected & ","
    result.add "or restore the Tarkov client to " & $required & "."
  of gUnknownDetected:
    result.add "required  " & $required
    result.add "detected  unreadable"
    result.add ""
    result.add "The version resource in EscapeFromTarkov.exe could not be read,"
    result.add "so the client cannot be shown to be " & $required & "."
    result.add "That is a refusal, not a pass: an unchecked version is exactly"
    result.add "the case this gate exists to stop."
    result.add ""
    result.add "What to do: point --source at the directory holding"
    result.add "EscapeFromTarkov.exe, and check the launcher has finished"
    result.add "updating it."
  of gNoRequirement:
    result.add "required  (the payload does not say)"
    result.add "detected  " & $detected
    result.add ""
    result.add "payload.json carries no \"targetTarkovVersion\", so there is"
    result.add "nothing to check this client against."
    result.add ""
    result.add "What to do: this payload is malformed -- download the release"
    result.add "archive again rather than installing from it."

# ---------------------------------------------------------------------------
# Where the beta stamp goes
# ---------------------------------------------------------------------------
#
# `docs/BETA_PROTECTION_DESIGN.md` covers a 7-day expiry for the free beta.
# NOTHING of it is implemented here. When it is, it belongs beside this gate
# and not inside it: a second pure `proc betaGate(now, stampedAt): Gate`-shaped
# decision in its own module, evaluated in `prepare` immediately after
# `gateVersion` and rendered through the same boxed refusal path. Keeping the
# two separate matters, because a tester who is refused wants to know WHICH of
# the two refused them, and a combined enum makes that message vague.
