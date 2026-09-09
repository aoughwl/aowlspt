## Planning a cover sample, and reading its answers back.
##
## `core/cover.nim` scores cover points and has always been able to. What it
## has never had is *points*, because producing one means a raycast, and a
## raycast is a Unity call. This module is the half of that job which is
## arithmetic, and it is here rather than in `client/` for the same reason
## everything else in `core/` is: it can be checked against known geometry with
## no game anywhere near it, and the flicker failure that matters here -- a bot
## that re-picks its cover every tick -- is invisible from inside a raid and
## trivial to see from a test.
##
## ## The split
##
## Three steps, and only the middle one touches the engine:
##
##  1. **`planProbe`** turns a bot position and an enemy position into a fixed
##     set of candidate stances and, for each, the two rays that settle what
##     kind of cover it is. Pure. Runs on the host's thread, where the bot
##     table lives.
##  2. **The sample** casts those rays. `client/coverprobe.nim`, posted onto
##     Unity's thread through `onMainThread`, and it does nothing but read the
##     engine's answers into a plain array of bools -- no bot table, no
##     allocation, no logging.
##  3. **`ingest`** folds those answers into the bot's `CoverSet` on the next
##     tick, back on the host's thread. Pure again.
##
## The decision layer never waits for any of it. A bot whose sample has not
## come back yet decides from the set it already had, which is the same thing
## it does between samples anyway -- cover is geometry and geometry does not
## move.
##
## ## Two rays per candidate, and what they are asking
##
## SAIN's `CoverFinder` samples colliders with `Physics.OverlapSphere` and
## raycasts each one. `OverlapSphere` returns an array of managed objects,
## which is an allocation per sample and a second guessed binding; the two
## rays below answer the same question without either.
##
##  * **The chest ray**, from the candidate at chest height toward the enemy's
##    chest. If something stops it, the candidate breaks the enemy's line --
##    which is the whole of what `blocksEnemy` means.
##  * **The stand ray**, from the candidate at stand height toward the enemy at
##    stand height. If *that* is also stopped the obstruction is full height;
##    if it is not, the obstruction is somewhere between crouch and stand, and
##    the bot has to crouch to use it. That is exactly SAIN's hard/soft split,
##    and it falls out of one extra ray rather than out of a collider's bounds,
##    which would be a layout read on a type nobody has dumped.
##
## Both rays stop **short of the target**. A ray allowed to reach the enemy
## hits the enemy's own collider and reports "blocked" from every point on the
## map, which would make every candidate look like perfect cover -- the exact
## shape of failure that produces a plausible number rather than a refusal.
##
## ## What this cannot see, stated rather than approximated
##
##  * **Height.** A candidate is placed at the bot's own `y`. There is no
##    ground query here, so cover up a staircase or down a slope is not found;
##    the navmesh sample in `client/coverprobe.nim` rejects a candidate that is
##    not standable, which is the cheap half of the same question and is all
##    this asks for.
##  * **Anything between the bot and the candidate.** A candidate the bot
##    cannot reach is caught by `CoverPoint.pathFailures` after the fact, which
##    is `core/cover.nim`'s existing answer and is cheaper than a path query
##    per candidate per sample.

import vec
import types
import settings
import cover

const
  ProbeCandidates* = 8
    ## How many stances one sample considers.
    ##
    ## A power of two so the rotation below is a mask, and eight because the
    ## cost of a sample is `2 * ProbeCandidates` raycasts and that number is
    ## the entire frame budget of this sensor. Sixteen would find better cover
    ## and cost twice as much for a bot that is about to move anyway.
  RaysPerCandidate* = 2
  RaysPerSample* = ProbeCandidates * RaysPerCandidate

  ChestHeight* = 1.0
    ## Where a bot's centre of mass is, near enough. The chest ray is the one
    ## that decides `blocksEnemy`.
  ProbeStandHeight* = 1.55
    ## `cover.StandHeight`, restated here as the ray height rather than as the
    ## classification threshold, because they are the same number for a reason
    ## and a reader should be able to see that they are.
  NearRadius* = 5.0
  FarRadius* = 11.0
    ## Two radii, alternating around the ring. One radius finds a wall at one
    ## distance and nothing else; two costs nothing extra and spreads the
    ## candidates over the band a bot will actually sprint to.
  RayStopShort* = 0.5
    ## How far short of the target a ray stops. See the module comment: a ray
    ## that reaches the enemy hits the enemy.

  MergeDistance* = 1.25
    ## Two candidates this close are the *same* cover point.
    ##
    ## This is the hysteresis that matters, and it is here rather than in
    ## `choose`. A sample taken from a bot that has walked two metres produces
    ## eight positions none of which is exactly a position from the last
    ## sample, so an ingest that appended would replace the set every time and
    ## `CoverSet.chosen` -- an index -- would name a different place on every
    ## tick. Merging by proximity keeps a point's *identity* across samples, so
    ## the dwell timer in `cover.choose` has something to dwell on.
  ForgetSeconds* = 12.0
    ## How long a point survives without being re-observed. Long enough that a
    ## bot's set is not emptied by the sample that happened to face the other
    ## way; short enough that a point from the other end of a corridor is gone
    ## before the bot is told to run back to it.
  MaxCoverPoints* = 24
    ## The set's ceiling. `rescore` is O(points) and runs per decision, so this
    ## is what keeps that bounded no matter how long a bot lives.

  HardCoverHeight* = 1.8
    ## What a candidate whose stand ray was also blocked is recorded as. Not
    ## measured -- the rays answer a band, not a number -- so it is the middle
    ## of the band `cover.isHardCover` accepts, and `README.md` says so.
  SoftCoverHeight* = 1.0

## The ring, as a table rather than as trigonometry.
##
## `core/vec.nim` deliberately has no `sin`/`cos` and this does not add them:
## eight evenly spaced bearings are eight pairs of constants, exact, with no
## import and no rounding of an angle that was never a measurement.
const RingCos: array[8, float] = [
  1.0, 0.70710678, 0.0, -0.70710678, -1.0, -0.70710678, 0.0, 0.70710678]
const RingSin: array[8, float] = [
  0.0, 0.70710678, 1.0, 0.70710678, 0.0, -0.70710678, -1.0, -0.70710678]

type
  ProbeRay* = object
    ## One raycast, described in the terms the engine wants: a start, a
    ## direction and how far to look. The direction is normalised here so the
    ## sampler does not have to, because the sampler runs on the game's thread
    ## and everything that can be done off it is.
    origin*: Vec3
    direction*: Vec3
    maxDistance*: float

  ProbeCandidate* = object
    position*: Vec3
    chest*: ProbeRay
    stand*: ProbeRay

  ProbePlan* = object
    ## One sample's worth of work, complete before it is posted. Nothing in
    ## here is read back on the host's thread while the sampler is running, and
    ## nothing in it points at anything.
    valid*: bool
    botPos*: Vec3
    enemyPos*: Vec3
    count*: int
    candidates*: array[ProbeCandidates, ProbeCandidate]

  ProbeAnswer* = object
    ## What the engine said about one candidate.
    ##
    ## `standable` is true when the navmesh sample said there is ground here --
    ## **and also true when the navmesh binding refused**, because a sensor
    ## that is absent must not reject. A build with no `NavMesh` gets cover
    ## points chosen on the rays alone, which is worse and is not nothing.
    chestBlocked*: bool
    standBlocked*: bool
    standable*: bool

  ProbeAnswers* = array[ProbeCandidates, ProbeAnswer]

func zeroRay*(): ProbeRay =
  ProbeRay(origin: zeroVec(), direction: zeroVec(), maxDistance: 0.0)

func zeroCandidate*(): ProbeCandidate =
  ProbeCandidate(position: zeroVec(), chest: zeroRay(), stand: zeroRay())

func zeroAnswer*(): ProbeAnswer =
  ProbeAnswer(chestBlocked: false, standBlocked: false, standable: true)

proc emptyPlan*(): ProbePlan =
  let z = zeroCandidate()
  ProbePlan(valid: false, botPos: zeroVec(), enemyPos: zeroVec(), count: 0,
            candidates: [z, z, z, z, z, z, z, z])

proc emptyAnswers*(): ProbeAnswers =
  let z = zeroAnswer()
  result = [z, z, z, z, z, z, z, z]

func rayTo(origin, target: Vec3): ProbeRay =
  ## A ray aimed at a point and stopping short of it.
  let d = target - origin
  let m = magnitude(d)
  if m <= 0.001:
    return zeroRay()
  var reach = m - RayStopShort
  if reach < 0.1: reach = 0.1
  ProbeRay(origin: origin, direction: d * (1.0 / m), maxDistance: reach)

proc planProbe*(botPos, enemyPos: Vec3; s: Settings; rotate: int): ProbePlan =
  ## Where to look, and what to ask about each place.
  ##
  ## The ring is built in the bot's *local* frame -- forward is the bearing to
  ## the enemy, right is the horizontal perpendicular -- so candidate 4 is
  ## always directly away from the enemy and candidates 2 and 6 are always the
  ## flanks, whichever way the fight is pointing. Nothing weights them here:
  ## `cover.scorePoint` already knows whether this bot wants to break contact
  ## or to keep the fight, and encoding that twice would be two places to get
  ## it wrong.
  ##
  ## `rotate` turns the whole ring by a whole number of steps. It is the bot's
  ## own stream, so two bots sampling the same corner do not propose the same
  ## eight points and then both run to the one that scored best.
  result = emptyPlan()
  let toEnemy = flat(enemyPos - botPos)
  let span = magnitude(toEnemy)
  if span < 0.001:
    # No bearing means no frame to build the ring in. A sample with no enemy is
    # not refused for want of a sensor, it is simply not a question.
    return
  # Divided by the length already in hand rather than through `normalized`,
  # which would take the same square root a second time. Every square root in
  # here is a Newton loop -- see `core/vec.sqrt0` -- and this function runs
  # about thirty of them as it is.
  let fwd = toEnemy * (1.0 / span)
  let right = perpXZ(fwd)
  result.botPos = botPos
  result.enemyPos = enemyPos
  let far1 = clampf(FarRadius, NearRadius, s.maxCoverPathLength)
  let enemyChest = withY(enemyPos, enemyPos.y + ChestHeight)
  let enemyStand = withY(enemyPos, enemyPos.y + ProbeStandHeight)
  var i = 0
  while i < ProbeCandidates:
    let k = (i + rotate) and (ProbeCandidates - 1)
    let radius = (if (i and 1) == 0: NearRadius else: far1)
    let dir = fwd * RingCos[k] + right * RingSin[k]
    let at = botPos + dir * radius
    var c = zeroCandidate()
    c.position = at
    c.chest = rayTo(withY(at, at.y + ChestHeight), enemyChest)
    c.stand = rayTo(withY(at, at.y + ProbeStandHeight), enemyStand)
    result.candidates[i] = c
    inc i
  result.count = ProbeCandidates
  result.valid = true

func heightFrom*(a: ProbeAnswer): float =
  ## The obstruction's height band, as the one number `core/cover.nim` reads.
  ##
  ## Zero means "this candidate is not cover", which `cover.usable` rejects
  ## before scoring. Note the asymmetry: a stand ray blocked while the chest
  ## ray is clear is *not* cover -- an overhang a bot cannot get behind -- and
  ## reporting it as hard cover would send bots to stand under gantries.
  if not a.chestBlocked: return 0.0
  if a.standBlocked: return HardCoverHeight
  result = SoftCoverHeight

proc expire*(c: var CoverSet; now: float; ttl: float) =
  ## Drop points nobody has re-observed inside `ttl`.
  ##
  ## In place and with the same `chosen` fixup `prune` does, for the same
  ## reason: the chosen index names a slot, so compaction that did not move it
  ## would silently re-point a bot at a different piece of the world.
  ##
  ## The point the bot is *currently using* is exempt. It is by definition the
  ## place the bot is running to, and forgetting it mid-approach is the one way
  ## this could produce the oscillation the merge above exists to prevent.
  var w = 0
  for r in 0 ..< c.points.len:
    let keepIt = (r == c.chosen) or (now - c.points[r].lastCheck <= ttl)
    if keepIt:
      if w != r:
        let keep = c.points[r]
        c.points[w] = keep
        if c.chosen == r: c.chosen = w
      inc w
    elif c.chosen == r:
      c.chosen = -1
  if w < c.points.len:
    shrink(c.points, w)

proc indexNear(c: CoverSet; at: Vec3; within: float): int =
  ## The point already standing for this place, or -1.
  result = -1
  let lim = within * within
  var best = lim
  for i in 0 ..< c.points.len:
    let d = sqrDistance(c.points[i].position, at)
    if d <= best:
      best = d
      result = i

proc ingest*(c: var CoverSet; p: ProbePlan; a: ProbeAnswers; s: Settings;
             now: float): int =
  ## Fold one sample's answers into the set. Returns how many points the set
  ## holds afterwards.
  ##
  ## Three cases per candidate, and the middle one is the whole design:
  ##
  ##  * **Not standable** -- ignored entirely. The navmesh said there is no
  ##    ground there, so proposing it would be proposing a place the bot cannot
  ##    be.
  ##  * **Cover, and a point already stands for this place** -- that point is
  ##    *updated*, keeping its position and therefore its index. This is what
  ##    lets `cover.choose`'s dwell timer mean anything across samples.
  ##  * **Cover, and nothing stands for this place** -- appended, up to the
  ##    ceiling.
  ##
  ## A candidate that came back *without* cover also updates a point standing
  ## for that place, by clearing `blocksEnemy`. That is how a point the world
  ## has changed under -- a door opened, a car moved -- stops being chosen,
  ## and it is better than dropping the point outright, because dropping it
  ## would let the next sample re-add it and flicker.
  result = c.points.len
  if not p.valid:
    return
  var i = 0
  while i < p.count:
    let ans = a[i]
    let cand = p.candidates[i]
    inc i
    if not ans.standable:
      continue
    let h = heightFrom(ans)
    let at = indexNear(c, cand.position, MergeDistance)
    if at >= 0:
      var q = c.points[at]
      q.blocksEnemy = ans.chestBlocked
      if h > 0.0:
        q.height = h
      q.lastCheck = now
      q.distanceToBot = distance(p.botPos, q.position)
      q.distanceToEnemy = distance(p.enemyPos, q.position)
      c.points[at] = q
      continue
    if h <= 0.0:
      continue
    if c.points.len >= MaxCoverPoints:
      continue
    c.points.add CoverPoint(
      position: cand.position, height: h, blocksEnemy: ans.chestBlocked,
      lastCheck: now,
      distanceToBot: distance(p.botPos, cand.position),
      distanceToEnemy: distance(p.enemyPos, cand.position),
      score: 0.0, pathFailures: 0)
  expire(c, now, ForgetSeconds)
  prune(c, s)
  result = c.points.len
