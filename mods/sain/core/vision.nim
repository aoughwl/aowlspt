## Acquisition: the difference between a clear line and a bot that has noticed.
##
## The game answers one question -- is there an unobstructed line from this bot
## to that enemy -- and answers it with a raycast, which is engine work this mod
## should read rather than repeat. What the game does *not* answer is whether
## the bot has noticed, and using the raycast's answer as though it were the
## bot's is the single most common way bot AI is made unfair: the frame you
## clear a doorway, thirty bots know where you are.
##
## SAIN separates the two. `EnemyVision` accumulates a `VisibleStartTime`, gates
## on `EnemySeenTime`, and BSG's own `GainSight` coefficient slows the ramp with
## distance and angle. This file is that model, as one accumulator with two
## thresholds and a reaction delay:
##
##     line of sight  ->  awareness ramps up at a rate set by
##                        distance, angle off centre, the enemy's own motion
##                        and difficulty
##     awareness >= engage  ->  a reaction timer starts, once
##     timer expired        ->  the bot may shoot
##     no line of sight     ->  awareness bleeds away, slowly
##     awareness <= drop    ->  not acquired any more
##
## Two thresholds rather than one, because a single threshold at exactly the
## boundary is a bot that acquires and un-acquires five times a second, and the
## whole hysteresis argument in `toggle.nim` applies here more sharply than
## anywhere else in the mod.
##
## Everything is arithmetic on numbers the client layer already reads. Nothing
## here allocates and nothing here calls the game.

import vec
import types
import settings
import rng

func gainRate*(distance: float; angleCos: float; enemyMoving: bool;
               enemySprinting: bool; s: Settings): float =
  ## Awareness per second, for a bot with an unobstructed line.
  ##
  ## Four factors, multiplied, each of them a thing a human notices:
  ##
  ##  * **Distance.** Linear falloff to `sightMaxDistance`, floored so that a
  ##    target at the limit is acquired eventually rather than never.
  ##  * **Angle.** Straight ahead is fast; the edge of the cone is slow. The
  ##    input is a cosine because every other angle test in this mod is, and
  ##    an `acos` here would be the only trigonometry on the path.
  ##  * **Motion.** A moving target is easier to see and a sprinting one is
  ##    much easier. This is the mechanic that rewards a player for slowing
  ##    down, and it is missing from vanilla entirely.
  ##  * **Difficulty**, already folded into `sightGainPerSecond` at spawn.
  if distance >= s.sightMaxDistance:
    return 0.0
  let near = clampf(1.0 - distance / s.sightMaxDistance, 0.08, 1.0)
  # Remap the cosine so that dead ahead is 1 and the edge of the field of view
  # is a fifth. Behind the bot the raycast may still succeed -- the game's own
  # visibility test is not a cone -- and the answer there has to be "barely",
  # not "not at all", because a bot does eventually notice someone standing
  # behind it.
  let ahead = clampf((angleCos + 0.2) / 1.2, 0.05, 1.0)
  var motion = 1.0
  if enemySprinting: motion = 1.9
  elif enemyMoving: motion = 1.35
  result = s.sightGainPerSecond * near * ahead * motion

proc updateAwareness*(e: var EnemyView; s: Settings; lookDir: Vec3;
                      mePos: Vec3; now: float; dt: float; r1: var Rng) =
  ## Fold one tick of line-of-sight into the acquisition state.
  ##
  ## Called from `enemy.observe`, which is the only place that knows whether
  ## the engine's raycast succeeded this tick.
  if e.visible:
    let dir = e.realPosition - mePos
    let ang = angleCos(lookDir, dir)
    let moving = sqrMagnitude(e.velocity) > 0.36        ## 0.6 m/s
    let sprinting = sqrMagnitude(e.velocity) > 11.56    ## 3.4 m/s
    let g = gainRate(e.distance, ang, moving, sprinting, s)
    let before = e.awareness
    e.awareness = clampf(e.awareness + g * dt, 0.0, 1.0)
    if before < s.engageAwareness and e.awareness >= s.engageAwareness:
      # The crossing, which happens once per acquisition rather than per tick.
      # The delay is drawn here so that two bots looking at the same doorway do
      # not fire on the same frame -- SAIN rolls its equivalent per shot; once
      # per acquisition is both cheaper and more like a person.
      let jitter = rangeF(r1, 0.0, s.reactionTimeSpread)
      e.reactionUntil = now + s.reactionTimeBase + jitter
  else:
    # Memory of a face fades much more slowly than the face disappears. This is
    # why a bot that has been fighting you keeps fighting you around a corner
    # instead of forgetting between two frames.
    e.awareness = clampf(e.awareness - s.sightLossPerSecond * dt, 0.0, 1.0)
    if e.awareness <= s.dropAwareness:
      # Fully dropped: the next sighting pays the reaction delay again.
      e.reactionUntil = 0.0

func acquired*(e: EnemyView; s: Settings): bool =
  ## Has this bot noticed, with hysteresis? Above the engage threshold it is
  ## acquired; between the two thresholds it stays whatever it was, which is
  ## carried in `awareness` itself rather than in a second flag.
  e.awareness >= s.engageAwareness

func mayEngage*(e: EnemyView; s: Settings; now: float): bool =
  ## Acquired *and* past the reaction delay. This is the predicate the combat
  ## ladder uses in place of the raw `visible` flag, and swapping one for the
  ## other is most of what makes these bots feel different from vanilla's.
  if not e.visible:
    return false
  if e.awareness < s.engageAwareness:
    return false
  result = now >= e.reactionUntil

func stillTracking*(e: EnemyView; s: Settings): bool =
  ## Between the two thresholds with no line of sight: the bot has lost sight
  ## but has not lost the plot. Search and flank read this; `mayEngage` does
  ## not, because a bot should not shoot at a memory.
  e.awareness > s.dropAwareness

proc decayUncertainty*(e: var EnemyView; s: Settings; dt: float) =
  ## How far the last known place could be wrong by now.
  ##
  ## Grows at a walking pace while contact is lost and collapses to nothing the
  ## moment the enemy is seen. SAIN keeps a list of `EnemyPlace` records with
  ## their own ages; one radius carries the same information for every use this
  ## mod has, and it is what makes the search widen with time instead of
  ## walking to a stale point with false confidence.
  if e.visible:
    e.uncertainty = 0.0
    return
  const AssumedSpeed = 2.4      ## m/s: a person moving with some care
  e.uncertainty = clampf(e.uncertainty + AssumedSpeed * dt, 0.0, 60.0)
