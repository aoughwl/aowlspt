## Cover: which piece of the world is worth standing behind.
##
## SAIN's `CoverFinder` runs a coroutine per bot that samples colliders around
## the bot, raycasts each candidate against the enemy, and scores the survivors.
## It is correct and it is the second most expensive thing SAIN does — the
## sampling and the raycasts are engine work that cannot be made cheaper by
## rewriting the language around them.
##
## What *can* be made cheaper is everything either side of the raycast, and that
## is what this module is:
##
##  * **Scoring is pure.** Candidates arrive as positions with a height and a
##    "was it blocked" flag the client layer already obtained. Ranking them
##    involves no engine call at all, so it can run for every candidate every
##    time without the cost that implies in the original.
##  * **The expensive test is rationed.** `needsRecheck` says when a point's
##    line-of-sight result has gone stale, so the client layer raycasts a few
##    points per tick instead of all of them. A cover point that was good 200ms
##    ago and whose enemy has moved two metres is still good.
##  * **The set is kept, not rebuilt.** Points persist across ticks and are
##    re-scored against the enemy's new position; SAIN rebuilds far more often
##    than the world changes.
##
## **Where the points come from is `core/probe.nim`**, and it did not exist
## until recently. Everything in this file has been written, tested and
## unreachable since the first version of the mod, for the single reason that
## nothing produced a `CoverPoint`: a candidate needs a raycast, a raycast is a
## Unity call, and there was no legal thread to make one from. There is now.
## `probe.planProbe` says where to look, `client/coverprobe.nim` casts the rays
## from inside an `onMainThread` job, and `probe.ingest` merges the answers
## into a `CoverSet` -- keeping each point's *identity* across samples, which
## is what makes the dwell hysteresis in `choose` below mean anything at all.
## Nothing in this file changed to make that work, which is the part worth
## noticing.

import vec
import types
import settings

type
  CoverPoint* = object
    position*: Vec3
    ## Height of the obstruction in metres. Below `standHeight` a bot has to
    ## crouch to use it, which is what separates SAIN's hard cover from soft.
    height*: float
    ## Set by the client layer's raycast: is the enemy's line to this point
    ## blocked? Stale until `lastCheck` is refreshed.
    blocksEnemy*: bool
    lastCheck*: float
    ## Distance from the bot when the point was found. Kept so a point can be
    ## re-ranked without recomputing, then refreshed lazily.
    distanceToBot*: float
    distanceToEnemy*: float
    score*: float
    ## How many times a bot tried to path here and failed. Three strikes and
    ## the point is dropped — SAIN's bots famously get stuck running at cover
    ## the navmesh will not take them to, and counting is cheaper than
    ## re-querying the navmesh to find out why.
    pathFailures*: int

  CoverSet* = object
    points*: seq[CoverPoint]
    chosen*: int               ## index of the point the bot is using, or -1
    chosenAt*: float           ## when it was chosen; feeds the shift timer
    lastRebuild*: float

const
  StandHeight* = 1.55
  ## SAIN: General.Cover.CoverMinHeight. Below this a collider is not cover
  ## at any pose, and the finder rejects it before it is ever scored.
  CrouchHeight* = 0.75

func newCoverSet*(): CoverSet =
  CoverSet(points: @[], chosen: -1, chosenAt: 0.0, lastRebuild: 0.0)

func isHardCover*(p: CoverPoint): bool = p.height >= StandHeight
func isSoftCover*(p: CoverPoint): bool =
  p.height >= CrouchHeight and p.height < StandHeight

func usable*(p: CoverPoint; s: Settings): bool =
  ## A point that fails any of these is not cover and never becomes cover, so
  ## it is rejected before scoring rather than scored to the bottom.
  if p.height < CrouchHeight: return false
  if p.pathFailures >= 3: return false
  if p.distanceToEnemy < s.coverMinEnemyDistance: return false
  if p.distanceToBot > s.maxCoverPathLength: return false
  result = true

func scorePoint*(p: CoverPoint; s: Settings; fromEnemy: bool): float =
  ## Higher is better. Blocked line of sight dominates everything, because a
  ## point that does not break the enemy's line is decoration.
  ##
  ## `fromEnemy` asks for a point that also lets the bot *leave* — used for a
  ## fighting withdrawal, where distance from the enemy outranks quality.
  if not usable(p, s):
    return -1.0
  var v = 0.0
  if p.blocksEnemy: v = v + 200.0
  if isHardCover(p): v = v + 60.0
  elif isSoftCover(p): v = v + 20.0
  # Close cover is better cover: every metre is a metre spent in the open.
  v = v + clampf(s.maxCoverPathLength - p.distanceToBot, 0.0,
                 s.maxCoverPathLength)
  if fromEnemy:
    v = v + clampf(p.distanceToEnemy, 0.0, 60.0) * 1.5
  else:
    # Otherwise a mild preference for staying in the fight rather than
    # retreating out of it: cover 60m behind is a rout, not a repositioning.
    v = v - clampf(p.distanceToEnemy - 40.0, 0.0, 60.0)
  v = v - float(p.pathFailures) * 40.0
  result = v

proc rescore*(c: var CoverSet; botPos, enemyPos: Vec3; s: Settings;
              fromEnemy: bool) =
  ## Re-rank every point against where things are now.
  ##
  ## Pure arithmetic over a small array: no engine call, no allocation. This is
  ## the operation the original could not afford to run often, and the reason it
  ## rebuilt its candidate set instead.
  for i in 0 ..< c.points.len:
    var p = c.points[i]
    p.distanceToBot = distance(botPos, p.position)
    p.distanceToEnemy = distance(enemyPos, p.position)
    p.score = scorePoint(p, s, fromEnemy)
    c.points[i] = p

proc best*(c: CoverSet): int =
  result = -1
  var bestScore = 0.0
  for i in 0 ..< c.points.len:
    if c.points[i].score > bestScore:
      bestScore = c.points[i].score
      result = i

proc needsRecheck*(c: CoverSet; index: int; now: float;
                   enemyMoved: float): bool =
  ## Whether a point's line-of-sight flag is worth spending a raycast on.
  ##
  ## Two triggers, and they are the amortisation: age, and how far the enemy
  ## has moved since the last check. A static enemy never invalidates anything;
  ## an enemy sprinting across the room invalidates everything at once, which is
  ## exactly when the extra cost is justified.
  if index < 0 or index >= c.points.len: return false
  let p = c.points[index]
  if now - p.lastCheck > 1.5: return true
  if enemyMoved > 4.0: return true
  result = false

proc statusFor*(distanceToCover: float; s: Settings): CoverStatus =
  if distanceToCover <= s.coverInRangeDistance: csInCover
  elif distanceToCover <= s.coverCloseDistance: csCloseToCover
  elif distanceToCover <= s.coverMidDistance: csMidRangeToCover
  else: csFarFromCover

proc choose*(c: var CoverSet; botPos, enemyPos: Vec3; s: Settings;
             now: float; fromEnemy: bool): bool =
  ## Pick a point, with dwell hysteresis.
  ##
  ## A bot that re-picks every tick oscillates between two near-equal points and
  ## spends the fight running back and forth in the open. `shiftCoverSeconds`
  ## is the minimum dwell, and a new point has to beat the held one by a margin
  ## rather than merely tie it.
  rescore(c, botPos, enemyPos, s, fromEnemy)
  let b = best(c)
  if b < 0:
    c.chosen = -1
    return false
  if c.chosen >= 0 and c.chosen < c.points.len:
    let held = c.points[c.chosen]
    if held.score > 0.0:
      if now - c.chosenAt < s.shiftCoverResetTime:
        return true
      if c.points[b].score < held.score * 1.25:
        return true
  c.chosen = b
  c.chosenAt = now
  result = true

proc markPathFailure*(c: var CoverSet; index: int) =
  if index < 0 or index >= c.points.len: return
  var p = c.points[index]
  p.pathFailures = p.pathFailures + 1
  c.points[index] = p

proc prune*(c: var CoverSet; s: Settings) =
  ## Drop points that will never be used again. In place, for the same reason
  ## `forget` in enemy.nim is in place.
  var w = 0
  for r in 0 ..< c.points.len:
    if c.points[r].pathFailures < 3 and c.points[r].height >= CrouchHeight:
      if w != r:
        # Through a temporary: nimony refuses `c.points[w] = c.points[r]`
        # because the mutable destination and the immutable source alias the
        # same seq, which is a real rule and a cheap one to satisfy.
        let keep = c.points[r]
        c.points[w] = keep
        if c.chosen == r: c.chosen = w
      inc w
    elif c.chosen == r:
      c.chosen = -1
  if w < c.points.len:
    shrink(c.points, w)
