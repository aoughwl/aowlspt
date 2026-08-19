## Perception: what a bot knows about who is trying to kill it.
##
## SAIN's `SAINEnemy` is a component per enemy per bot, each with its own
## `EnemyVision`, `EnemyPath`, `EnemyKnownPlaces` and `EnemyStatus` sub-objects,
## each updating on its own timer. For 30 bots with a dozen potential enemies
## each that is several hundred live objects being ticked, and it is the single
## most expensive thing SAIN does.
##
## The port keeps the *model* — last known place, seen/heard timers, a decaying
## threat level, banded distance — and drops the object graph. One bot's whole
## enemy table is a `seq[EnemyView]` of plain values, updated in one pass. No
## allocation after the table reaches its steady size, no pointer chasing, and
## the expensive part (a line-of-sight raycast) is on its own budget rather than
## running for every enemy every frame.
##
## Nothing here calls the game. `observe` is handed what the client layer
## already read; that is the whole interface.

import vec
import types
import settings
import vision
import hearing
import rng

type
  Observation* = object
    ## One tick's raw truth about one enemy, as the client layer read it.
    ## `sawThisTick` is the result of the game's own visibility test — this
    ## module decides what it *means*, not whether it happened.
    ## The identity. A pointer on the client side, any distinct number in a
    ## test. `id` is only carried when the caller knows the entry is new --
    ## reading a managed string per enemy per tick was the last allocation on
    ## the perception path and it bought nothing, because the key already
    ## answers every question the table asks.
    key*: uint64
    alive*: bool
    isPlayer*: bool
    position*: Vec3
    sawThisTick*: bool
    heardThisTick*: bool
    firedAtUsThisTick*: bool
    ## The enemy's own facing, against us. Read from the game once per tick,
    ## not derived here: only the client layer can see their forward vector.
    lookingAtUsThisTick*: bool
    pathDistance*: float       ## negative when the client did not compute one
    ## What the bot made of a sound from this enemy this tick, if any. Built by
    ## `hearing.listen` in the caller, because only the caller knows where the
    ## sound was and whether the line was clear.
    heard*: Heard

  EnemyTable* = object
    ## Every enemy this bot has met, most recent first after `promote`.
    items*: seq[EnemyView]
    primary*: int              ## index of the current enemy, or -1

func newEnemyTable*(): EnemyTable =
  EnemyTable(items: @[], primary: -1)

func bandFor*(distance: float): PathDistance =
  ## The banding SAIN calls `EPathDistance`. Thresholds are its own.
  if distance >= 9000.0: pdNoEnemy
  elif distance <= 8.0: pdVeryClose
  elif distance <= 16.0: pdClose
  elif distance <= 32.0: pdMid
  elif distance <= 64.0: pdFar
  else: pdVeryFar

func indexOf*(t: EnemyTable; key: uint64): int =
  ## Linear, on an integer. The table is a handful of entries per bot and a
  ## hash would cost more in setup than it saves in a scan of six -- and this
  ## used to compare *strings*, which is a memcmp per entry per tick for a
  ## question one integer compare answers.
  result = -1
  for i in 0 ..< t.items.len:
    if t.items[i].key == key:
      return i

proc observe*(t: var EnemyTable; obs: Observation; me: Vec3; look: Vec3;
              s: Settings; now: float; dt: float; r1: var Rng) =
  ## Fold one observation into the table.
  ##
  ## `r1` is the bot's own stream, used for the reaction-delay draw in
  ## `vision.updateAwareness`. Passing it in rather than owning one keeps this
  ## module deterministic from the caller's seat, which is what the scenario
  ## tests replay against.
  var idx = indexOf(t, obs.key)
  if idx < 0:
    if not obs.alive:
      return                   # do not create an entry for a corpse
    var e = emptyEnemy()
    e.key = obs.key
    e.valid = true
    t.items.add e
    idx = t.items.len - 1

  # A `var` alias would be neater; nimony does not give one over a seq element
  # without borrowing rules this file would rather not fight, so the entry is
  # copied out, edited and written back. It is 200 bytes of stack.
  var e = t.items[idx]
  e.alive = obs.alive
  e.isPlayer = obs.isPlayer
  e.valid = true

  let dSqr = sqrDistance(me, obs.position)
  e.distance = sqrt0(dSqr)
  e.pathDistance = (if obs.pathDistance >= 0.0: obs.pathDistance else: e.distance)
  e.band = bandFor(e.pathDistance)

  if obs.sawThisTick:
    # Velocity first, from the *previous* real position, before it is
    # overwritten. Two subtractions and a divide, and it is what the search's
    # "push past in the direction they went" phase and the acquisition model's
    # motion factor both read. SAIN gets the same number from a
    # `Vector3.Distance` between consecutive `EnemyPlace` records.
    if e.visible and dt > 0.0001:
      e.velocity = (obs.position - e.realPosition) * (1.0 / dt)
    e.visible = true
    e.timeSinceSeen = 0.0
    e.seenTotal = e.seenTotal + dt
    e.position = obs.position          # last known == actual while seen
    e.realPosition = obs.position
    # Seeing someone is the strongest evidence there is; threat goes to full
    # rather than accumulating, so a bot that rounds a corner onto an enemy
    # reacts on the first tick instead of ramping over half a second.
    e.threatLevel = 1.0
  else:
    e.visible = false
    e.timeSinceSeen = e.timeSinceSeen + dt
    if e.timeSinceSeen > s.visionSeenTimeout:
      # Contact is stale: the accumulated seen-time no longer counts towards
      # "I have a good read on this enemy".
      e.seenTotal = 0.0

  if obs.heardThisTick:
    e.timeSinceHeard = 0.0
    e.heardRecently = true
    e.heardLoudness = obs.heard.loudness
    if not obs.sawThisTick:
      # A heard enemy updates the *last known place* but not the real one. That
      # distinction is the reason bots in SAIN search a room rather than
      # tracking through walls, and losing it is the classic aimbot bug.
      #
      # It is `obs.heard.position` rather than `obs.position` for the same
      # reason one layer down: the heard position is where the bot *thinks* the
      # sound came from, complete with the localisation error `hearing.listen`
      # put on it. Using the true position here would make the whole hearing
      # model decorative.
      e.position = (if obs.heard.audible: obs.heard.position else: obs.position)
      # A sound is evidence that the last known place is fresher than it was,
      # so the uncertainty radius collapses towards the localisation error
      # rather than to zero.
      e.uncertainty = clampf(obs.heard.distance * s.hearingPositionError,
                             1.0, e.uncertainty)
    let bump = threatBump(obs.heard, skFootStep)
    e.threatLevel = clampf(e.threatLevel + (if bump > 0.0: bump else: 0.35),
                           0.0, 1.0)
  else:
    e.timeSinceHeard = e.timeSinceHeard + dt
    e.heardRecently = e.timeSinceHeard < s.heardTimeout

  e.lookingAtUs = obs.lookingAtUsThisTick
  e.suppressingUs = obs.firedAtUsThisTick
  if obs.firedAtUsThisTick:
    e.threatLevel = 1.0

  # Decay. Linear rather than exponential: a bot's memory should run out at a
  # predictable time so the tuning number means something.
  if not (obs.sawThisTick or obs.heardThisTick or obs.firedAtUsThisTick):
    e.threatLevel = clampf(e.threatLevel - s.threatDecayPerSecond * dt, 0.0, 1.0)

  let dir = obs.position - me
  e.inFieldOfView = angleCos(look, dir) >= s.fieldOfViewCos

  # --- acquisition. This is the line that separates this port from vanilla:
  # `canShoot` used to be "the engine's raycast reached them and a tenth of a
  # second has passed", which is a bot that snaps onto you the frame you clear
  # a doorway. Now it is "this bot has noticed, and has had time to react".
  updateAwareness(e, s, look, me, now, dt, r1)
  decayUncertainty(e, s, dt)
  e.canShoot = mayEngage(e, s, now)

  t.items[idx] = e

proc forget*(t: var EnemyTable; s: Settings) =
  ## Drop enemies nobody has any reason to remember.
  ##
  ## Compacting in place rather than rebuilding: a fresh `seq` per bot per tick
  ## is exactly the per-frame allocation this port exists to remove.
  var w = 0
  for r in 0 ..< t.items.len:
    let e = t.items[r]
    let stale = e.timeSinceSeen > s.forgetEnemySeconds and
                e.timeSinceHeard > s.forgetEnemySeconds
    if e.alive and not stale:
      if w != r:
        t.items[w] = e
      inc w
  if w < t.items.len:
    shrink(t.items, w)
  if t.primary >= t.items.len:
    t.primary = -1

func score(e: EnemyView; s: Settings): float =
  ## How much this enemy deserves the bot's attention.
  ##
  ## Visible beats remembered, close beats far, and someone shooting at us beats
  ## both. SAIN picks its `ActiveEnemy` through a chain of special cases; a
  ## single score is easier to reason about and produces the same ordering in
  ## every case worth having.
  if not e.alive or not e.valid:
    return -1.0
  var v = e.threatLevel * 100.0
  if e.visible: v = v + 200.0
  # An acquired enemy outranks one that is merely in line of sight but has not
  # been noticed yet, which is what keeps a bot fighting the man it is already
  # fighting when a second one steps into view behind him.
  v = v + e.awareness * 60.0
  if e.suppressingUs: v = v + 150.0
  if e.isPlayer: v = v + 40.0        ## the human is the point of the raid
  if e.inFieldOfView: v = v + 25.0
  # Proximity, bounded so that a distant visible enemy still outranks a close
  # forgotten one.
  v = v + clampf(120.0 - e.pathDistance, 0.0, 120.0)
  result = v

proc choosePrimary*(t: var EnemyTable; s: Settings): int =
  ## Pick the enemy the decision core will act on. Hysteresis is applied by the
  ## caller through `holdUntil`; switching target every tick between two equally
  ## scored enemies is how a bot ends up shooting at neither.
  var best = -1
  var bestScore = 0.0
  for i in 0 ..< t.items.len:
    let sc = score(t.items[i], s)
    if sc > bestScore:
      bestScore = sc
      best = i
  t.primary = best
  result = best

func primaryView*(t: EnemyTable): EnemyView =
  if t.primary < 0 or t.primary >= t.items.len:
    return emptyEnemy()
  result = t.items[t.primary]

func liveCount*(t: EnemyTable): int =
  result = 0
  for i in 0 ..< t.items.len:
    if t.items[i].alive and t.items[i].threatLevel > 0.0:
      inc result
