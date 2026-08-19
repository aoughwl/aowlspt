## Search: where a bot goes when it has lost the enemy.
##
## This is the part of SAIN people notice most — bots that clear a room instead
## of sprinting in a straight line at your last known position — and it is
## almost entirely bookkeeping rather than engine work, which makes it the part
## that ports best.
##
## The model is SAIN's: a search is a *state machine* over a last-known place,
## not a single destination. The bot moves toward the place, and once it arrives
## it does not simply stop — it advances through a small sequence of
## progressively wider guesses about where the enemy went, and gives up when the
## sequence runs out. Each step is a destination the client layer resolves onto
## the navmesh.
##
## Nothing here allocates per tick and nothing here calls the game.

import vec
import types
import settings
import flank

type
  SearchPhase* = enum
    spIdle             ## nothing to look for
    spMoveToLastKnown  ## head to where they were
    spLookAround       ## arrived; scan from here
    spAdvancePast      ## push through, past the point, in the same direction
    spFlankGuess       ## try the obvious flank
    ## The widest guess: a point on the far side of the uncertainty circle. A
    ## search that has failed three narrower guesses is looking for someone who
    ## moved, and how far they could have moved is exactly what `uncertainty`
    ## has been accumulating since contact was lost. SAIN reaches something
    ## similar by asking its cover finder for points around the last known
    ## place; this asks the arithmetic instead.
    spSweepWide
    spGiveUp

  SearchState* = object
    phase*: SearchPhase
    target*: Vec3
    origin*: Vec3          ## where the search started, for the flank guess
    startedAt*: float
    phaseStartedAt*: float
    ## The direction the enemy was last known to be travelling. SAIN gets this
    ## from consecutive known-places; one vector is enough to make the difference
    ## between a bot that searches forward and one that searches where you were.
    drift*: Vec3
    arrived*: bool
    progressStalled*: bool
    lastDistance*: float
    ## How far the last known place could be wrong by, at the moment the search
    ## started. Carried rather than recomputed so that a search does not widen
    ## under its own feet while the bot walks -- the radius that matters is the
    ## one at the moment contact was lost, plus what has elapsed since.
    radius*: float
    ## Which way the wide sweep goes. Drawn once per search from the bot's own
    ## stream by the caller, so two bots searching the same room take opposite
    ## halves of it.
    side*: float

func newSearch*(): SearchState =
  SearchState(phase: spIdle, target: zeroVec(), origin: zeroVec(),
              startedAt: 0.0, phaseStartedAt: 0.0, drift: zeroVec(),
              arrived: false, progressStalled: false, lastDistance: 0.0,
              radius: 6.0, side: 1.0)

func active*(s: SearchState): bool =
  s.phase != spIdle and s.phase != spGiveUp

proc begin*(st: var SearchState; from1: Vec3; lastKnown: Vec3; drift: Vec3;
            now: float; radius: float = 6.0; side: float = 1.0) =
  ## Start, or restart, a search at a place.
  ##
  ## Restarting is the common case: every fresh sound or glimpse moves the
  ## last-known place, and a search that ignored the update would keep clearing
  ## a room the enemy has already left.
  st.phase = spMoveToLastKnown
  st.origin = from1
  st.target = lastKnown
  st.drift = drift
  st.startedAt = now
  st.phaseStartedAt = now
  st.arrived = false
  st.progressStalled = false
  st.lastDistance = distance(from1, lastKnown)
  # Floored rather than taken raw: a search whose radius is zero has no wide
  # phase at all, and the phase exists precisely for the case where the bot has
  # been wrong three times already.
  st.radius = clampf(radius, 6.0, 60.0)
  st.side = (if side >= 0.0: 1.0 else: -1.0)

proc cancel*(st: var SearchState) =
  st.phase = spIdle
  st.arrived = false

func nextPhase*(p: SearchPhase): SearchPhase =
  case p
  of spIdle: spIdle
  of spMoveToLastKnown: spLookAround
  of spLookAround: spAdvancePast
  of spAdvancePast: spFlankGuess
  of spFlankGuess: spSweepWide
  of spSweepWide: spGiveUp
  of spGiveUp: spGiveUp

func targetFor*(st: SearchState; botPos: Vec3): Vec3 =
  ## The destination for the phase the search has just entered.
  ##
  ## Deliberately not random. A random point near the last known place is what
  ## makes bots in most mods look like they are wandering; a guess that follows
  ## the enemy's own direction of travel looks like a search even when it is
  ## wrong, which is the entire trick.
  case st.phase
  of spAdvancePast:
    let dir = (if sqrMagnitude(st.drift) > 0.01: normalized(st.drift)
               else: normalized(flat(st.target - st.origin)))
    # As far past the point as the enemy could plausibly have got, rather than
    # a fixed twelve metres. Someone lost thirty seconds ago is a long way
    # further on than someone lost three seconds ago, and walking twelve metres
    # in both cases is what makes a search look scripted.
    result = st.target + dir * clampf(st.radius, 8.0, 30.0)
  of spFlankGuess:
    # Ninety degrees off the approach, on the side the bot is already nearer to,
    # so the flank does not cross the open ground it just crossed.
    let approach = normalized(flat(st.target - st.origin))
    let left = vec3(-approach.z, 0.0, approach.x)
    let toBot = flat(botPos - st.target)
    let side = (if dot(left, toBot) >= 0.0: left else: left * -1.0)
    result = st.target + side * clampf(st.radius * 0.6, 8.0, 20.0)
  of spSweepWide:
    result = searchWideTarget(st.target, st.origin, st.radius, st.side)
  else:
    result = st.target

proc advance*(st: var SearchState; botPos: Vec3; s: Settings; now: float) =
  ## Move the state machine on. Called at the decision rate, not per frame.
  if st.phase == spIdle or st.phase == spGiveUp:
    return

  if now - st.startedAt > s.searchGiveUpSeconds:
    st.phase = spGiveUp
    return

  let d = distance(botPos, st.target)

  # Stall detection. A bot whose distance to the target has not fallen in five
  # seconds is not searching, it is stuck on geometry, and the honest response
  # is to move the search on rather than to keep asking the navmesh. SAIN's
  # equivalent is its unstuck logic, which fires far later and looks worse.
  if now - st.phaseStartedAt > 5.0:
    st.progressStalled = d > st.lastDistance - 1.0
    st.lastDistance = d
    st.phaseStartedAt = now
    if st.progressStalled:
      st.phase = nextPhase(st.phase)
      st.target = targetFor(st, botPos)
      return

  const ArriveRadius = 2.5
  if d <= ArriveRadius:
    st.arrived = true
    case st.phase
    of spMoveToLastKnown:
      st.phase = spLookAround
      st.phaseStartedAt = now
    of spLookAround:
      # A short pause with eyes on the room, then push.
      if now - st.phaseStartedAt > 2.5:
        st.phase = spAdvancePast
        st.target = targetFor(st, botPos)
        st.phaseStartedAt = now
    of spAdvancePast:
      st.phase = spFlankGuess
      st.target = targetFor(st, botPos)
      st.phaseStartedAt = now
    of spFlankGuess:
      st.phase = spSweepWide
      st.target = targetFor(st, botPos)
      st.phaseStartedAt = now
    of spSweepWide:
      st.phase = spGiveUp
    else:
      discard
  else:
    st.arrived = false

func phaseName*(p: SearchPhase): string =
  case p
  of spIdle: "Idle"
  of spMoveToLastKnown: "MoveToLastKnown"
  of spLookAround: "LookAround"
  of spAdvancePast: "AdvancePast"
  of spFlankGuess: "FlankGuess"
  of spSweepWide: "SweepWide"
  of spGiveUp: "GiveUp"
