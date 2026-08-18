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

type
  SearchPhase* = enum
    spIdle             ## nothing to look for
    spMoveToLastKnown  ## head to where they were
    spLookAround       ## arrived; scan from here
    spAdvancePast      ## push through, past the point, in the same direction
    spFlankGuess       ## try the obvious flank
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

func newSearch*(): SearchState =
  SearchState(phase: spIdle, target: zeroVec(), origin: zeroVec(),
              startedAt: 0.0, phaseStartedAt: 0.0, drift: zeroVec(),
              arrived: false, progressStalled: false, lastDistance: 0.0)

func active*(s: SearchState): bool =
  s.phase != spIdle and s.phase != spGiveUp

proc begin*(st: var SearchState; from1: Vec3; lastKnown: Vec3; drift: Vec3;
            now: float) =
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

proc cancel*(st: var SearchState) =
  st.phase = spIdle
  st.arrived = false

func nextPhase*(p: SearchPhase): SearchPhase =
  case p
  of spIdle: spIdle
  of spMoveToLastKnown: spLookAround
  of spLookAround: spAdvancePast
  of spAdvancePast: spFlankGuess
  of spFlankGuess: spGiveUp
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
    result = st.target + dir * 12.0
  of spFlankGuess:
    # Ninety degrees off the approach, on the side the bot is already nearer to,
    # so the flank does not cross the open ground it just crossed.
    let approach = normalized(flat(st.target - st.origin))
    let left = vec3(-approach.z, 0.0, approach.x)
    let toBot = flat(botPos - st.target)
    let side = (if dot(left, toBot) >= 0.0: left else: left * -1.0)
    result = st.target + side * 10.0
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
  of spGiveUp: "GiveUp"
