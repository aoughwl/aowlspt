## nelogpol -- natesp's LOG-EMISSION POLICY, and nothing else.
##
## Pure: string and integer in, an enum out. No game memory, no il2cpp call, no
## host call, no global state of its own. It lives in its own file, exactly like
## `mods/maps/diagfilter.nim`, for exactly the same reason: the check that
## matters -- "a real FAIL still surfaces after the quieting" -- has to be
## runnable OFFLINE, and `natesp.nim` cannot be linked outside the host.
## `tests/natesplog.nim` drives the procs below with synthetic ticks.
##
## WHY THIS EXISTS. MEASURED at the main menu on integ-beta9: natesp emitted the
## full `natesp VERDICT INCONCLUSIVE -- canvas REFUSED -- no live GameWorld ...`
## block -- ~3,000 characters -- every 5 seconds, forever, plus a FLICKER METER
## line every second something transitioned. A ten-minute menu session is
## therefore ~120 copies of one sentence, ~360 KB, in the file that `run.py`,
## `hostlog.py`, `triage.py` and the MCP health check all read, and which
## CLAUDE.md 8 already calls a measured token bomb.
##
## WHAT THIS IS NOT. It is NOT a correctness change and it suppresses no
## MEASUREMENT. Every string natesp built before, it still builds, verbatim --
## "I could not look; that is NOT a pass" included. This code only decides when
## to REPEAT one. A not-PASS verdict is never collapsed into an all-clear and is
## never silenced outright: it is re-announced on its own line, at `warn`, on a
## schedule no signature can stop.
##
## THE ONE TRAP THIS FILE IS BUILT AGAINST is the one `diagfilter.nim` records:
## a change-detector that compares text carrying live counters is ALWAYS
## unequal, so it is an unconditional timer wearing a change-detector's comment.
## The signatures below are therefore built from the STATE (verdict class,
## refusal reason, phase, origin) with every count reduced to none/one/many --
## never from the rendered text.

type
  NeEmit* = enum
    ## What the caller should print this cycle. Four outcomes, not two: "say
    ## nothing" and "say the short form" are different answers, and folding
    ## them together is how a FAIL goes quiet.
    neQuiet        ## nothing new; print nothing
    neFull         ## the whole block, verbatim -- first cycle, or something moved
    neNotPass      ## ONE short line: a not-PASS verdict is still standing
    neHeartbeat    ## ONE short line: all-PASS, unchanged, the timer is alive

  NeGate* = object
    ## The change-detector's whole state. Deliberately plain data so a test can
    ## construct one, step it a thousand times, and assert on the transcript.
    sig*: string     ## signature of the last FULLY emitted block
    seen*: bool      ## has anything ever been emitted through this gate
    quiet*: int64    ## consecutive cycles the signature has not moved
    cycles*: int64   ## cycles stepped, including the ones that printed nothing

const
  NeVerdictBadEvery* = 12'i64
    ## Cycles between re-announcements of a STANDING not-PASS verdict. The
    ## verdict cycle is 5 s, so this is 60 s -- one line a minute for as long as
    ## the fault lasts, against the old ~3,000 characters every 5 s.
  NeVerdictBeatEvery* = 60'i64
    ## Cycles between all-PASS heartbeats: 5 minutes. Pure silence here would be
    ## indistinguishable from a dead timer, which is the same "I could not look
    ## reads as a pass" failure the verdict itself exists to prevent.
  NeFlickerEvery* = 60'i64
    ## The flicker meter runs on a 1 s timer and reports only when something
    ## transitioned, so this is 60 s of a CONTINUING, UNCHANGED flicker. A
    ## flicker whose shape changes reprints immediately.

proc newNeGate*(): NeGate =
  ## An explicitly zeroed gate. `var g: NeGate` is refused by nimony ("cannot
  ## prove that g has been initialized"), and a half-initialised change detector
  ## is exactly the kind of thing that would read as "nothing has changed".
  result = NeGate(sig: "", seen: false, quiet: 0'i64, cycles: 0'i64)

proc neCountClass*(n: int): string =
  ## none / one / many. The whole point of the signature: `contacts=7` becoming
  ## `contacts=8` is not news, `contacts=0` becoming `contacts=1` is.
  if n <= 0: "0"
  elif n == 1: "1"
  else: "n"

proc neFlag*(b: bool): string =
  if b: "1" else: "0"

proc neVerdictSig*(verdict, why, state, origin, phase: int;
                   contacts, placed, onScreen, built: int;
                   seeded, measured: bool): string =
  ## "What is the verdict block CURRENTLY SAYING", with the counters taken out.
  ##
  ## Built from the STATE FIELDS, not from the rendered line, so it cannot
  ## accidentally key on a microsecond mean or a tick count and thereby never
  ## match. Everything that changes the MEANING of the block is in here:
  ## the verdict class, the refusal reason (`why` -- this is what makes
  ## "no live GameWorld" -> "no canvas" reprint in full), the discovery state,
  ## which canvas we are parented to, the raid phase, whether seeding ever
  ## completed, whether a readback has ever been measured, and the none/one/many
  ## class of each of the four counts.
  result = "v" & $verdict & ";w" & $why & ";s" & $state & ";o" & $origin &
           ";p" & $phase &
           ";c" & neCountClass(contacts) &
           ";l" & neCountClass(placed) &
           ";n" & neCountClass(onScreen) &
           ";b" & neCountClass(built) &
           ";d" & neFlag(seeded) & ";m" & neFlag(measured)

proc neFlickerSig*(gateEdges, teardowns, censusDrop, boxOff, boxOn: int;
                   reasonMask: string; state, origin: int;
                   canvasActive: bool): string =
  ## The SHAPE of the flicker, not its size. Which of the five transition
  ## classes fired at all, which gate reasons fired, and the state and ancestor
  ## they fired in. Twelve teardowns and thirteen teardowns are the same news;
  ## a teardown that becomes a census drop is not.
  result = "g" & neFlag(gateEdges > 0) & ";t" & neFlag(teardowns > 0) &
           ";x" & neFlag(censusDrop > 0) & ";f" & neFlag(boxOff > 0) &
           ";o" & neFlag(boxOn > 0) & ";r" & reasonMask &
           ";s" & $state & ";c" & $origin & ";a" & neFlag(canvasActive)

proc neGateStep*(g: var NeGate; verbose: bool; sig: string; bad: bool;
                 badEvery, beatEvery: int64): NeEmit =
  ## ONE cycle of the policy. Call it once per would-be emission; it returns
  ## what to print and updates `g`.
  ##
  ## The rules, in the order they are applied:
  ##
  ##   1. `verbose` restores the OLD BEHAVIOUR BYTE FOR BYTE -- the full block
  ##      on every single cycle. It is the escape hatch, default OFF, and it is
  ##      checked first so nothing below can weaken it.
  ##   2. The FIRST cycle always prints in full, so a session that is broken
  ##      from the very start still gets a whole report rather than a summary of
  ##      a block nobody has seen.
  ##   3. A signature CHANGE prints in full, because context matters exactly
  ##      when something has just moved.
  ##   4. Otherwise, if the verdict is NOT PASS, it is re-announced as one short
  ##      line every `badEvery` cycles, for as long as it lasts. It is never
  ##      collapsed into a heartbeat and never suppressed outright.
  ##   5. Otherwise -- all-PASS and unchanged -- one heartbeat every
  ##      `beatEvery` cycles. It is a statement that the instrument is still
  ##      running, not a verdict.
  ##
  ## Note that (4) and (5) are mutually exclusive by construction: a not-PASS
  ## cycle can never take the heartbeat branch, so "all-PASS, unchanged" can
  ## never be printed over a standing FAIL.
  inc g.cycles
  if verbose:
    g.sig = sig
    g.seen = true
    g.quiet = 0'i64
    return neFull
  if (not g.seen) or sig != g.sig:
    g.sig = sig
    g.seen = true
    g.quiet = 0'i64
    return neFull
  inc g.quiet
  if bad:
    if badEvery > 0'i64 and (g.quiet mod badEvery) == 0'i64:
      return neNotPass
    return neQuiet
  if beatEvery > 0'i64 and (g.quiet mod beatEvery) == 0'i64:
    return neHeartbeat
  neQuiet
