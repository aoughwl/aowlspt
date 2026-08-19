## Where a decision actually sends the bot.
##
## Every decision in `decide.nim` that moves the bot needs a destination, and
## until now every one of them either used the enemy's position or nothing at
## all. That is why the previous version could seek cover and shift cover and
## retreat and produce, in all three cases, a bot walking towards the thing
## shooting at it: `actuationFor` had one position to hand and used it.
##
## The geometry here is deliberately not navmesh-aware, because a navmesh query
## is a Unity call this mod cannot make from its thread. Every function returns
## a *point in the world*, and the game's own `Mover.GoToPoint` does the
## pathing -- which it is going to do anyway, and which is where the "is that
## point reachable" question belongs. A point in a wall costs a failed path,
## which `cover.markPathFailure` already counts and drops.
##
## ## The flank
##
## SAIN flanks by asking its cover finder for a point on the far side of the
## enemy and comparing navmesh path lengths. Without the navmesh, the honest
## version is the arc: step off the direct bearing by a fixed radius, on a
## chosen side, and converge on the enemy from there. A bot doing that looks
## like it is flanking, arrives from an angle the player is not watching, and
## -- the part that matters -- does not stand in the doorway trading shots.
##
## Which side is not random. It is:
##
##  1. the side the bot is already displaced towards, so the flank does not
##     re-cross the ground it just crossed, and
##  2. away from the nearest squadmate, so two bots of the same squad go
##     opposite ways instead of both going left.
##
## That second rule is why this file takes a squadmate position at all, and it
## is the cheapest squad tactics in the mod: two bots, no communication, and a
## pincer falls out of the geometry.
##
## Nothing here allocates and nothing here calls the game.

import vec
import types
import settings

func flankSide*(botPos, enemyPos, mate: Vec3; haveMate: bool): float =
  ## +1 for the left-hand perpendicular, -1 for the right.
  ##
  ## Returns a float rather than a bool because every caller multiplies by it,
  ## and because a caller that wants a straight approach can pass the result
  ## through and get one by using zero.
  let bearing = normalized(flat(enemyPos - botPos))
  let left = perpXZ(bearing)
  # Where the bot already is, relative to the line. `dot` positive means the
  # bot is on the left of the enemy's bearing, so the left flank is the shorter
  # one.
  var side = (if dot(left, flat(botPos - enemyPos)) >= 0.0: 1.0 else: -1.0)
  if haveMate:
    let mateSide = (if dot(left, flat(mate - enemyPos)) >= 0.0: 1.0 else: -1.0)
    if mateSide == side:
      # A squadmate is already working this side. Take the other one -- the
      # pincer is worth more than the shorter walk.
      side = -side
  result = side

func flankTarget*(botPos, enemyPos: Vec3; side: float; s: Settings): Vec3 =
  ## The waypoint. Off the bearing by `flankArcRadius`, and part of the way
  ## along it, so the bot closes while it swings rather than orbiting.
  let toEnemy = flat(enemyPos - botPos)
  let d = magnitude(toEnemy)
  if d <= 0.001:
    return enemyPos
  let bearing = toEnemy * (1.0 / d)
  let left = perpXZ(bearing)
  # Two thirds of the way in, then out to the side. Closing further than that
  # before the swing puts the bot in the open at the range the enemy is best
  # at; closing less makes the arc so wide the bot arrives after the fight.
  let along = botPos + bearing * (d * 0.66)
  result = along + left * (side * s.flankArcRadius)

func retreatTarget*(botPos, enemyPos: Vec3; metres: float): Vec3 =
  ## Directly away, which is what a break-in-contact is. Not a flank with a
  ## negative radius: the difference is that this deliberately does not
  ## converge.
  away(botPos, enemyPos, metres)

func withdrawTarget*(botPos, enemyPos, coverPos: Vec3; haveCover: bool;
                     metres: float): Vec3 =
  ## A fighting withdrawal: towards cover if there is any, away from the enemy
  ## if there is not. The two are different behaviours and collapsing them is
  ## how a bot ends up retreating into the open because the cover set was empty.
  if haveCover:
    return coverPos
  result = away(botPos, enemyPos, metres)

func spreadTarget*(botPos, matePos: Vec3; minDistance: float): Vec3 =
  ## Step apart. One grenade should not be able to kill a squad, and this is
  ## the whole of SAIN's `SpreadOut` reduced to the move it produces.
  let d = flatDistance(botPos, matePos)
  if d >= minDistance:
    return botPos
  result = away(botPos, matePos, minDistance - d + 1.0)

func avoidTarget*(botPos, grenadePos: Vec3; s: Settings): Vec3 =
  ## Out of the blast. Straight away and a little further than the avoid
  ## radius, because arriving exactly at the edge of a radius is arriving
  ## inside it by the time the fragment gets there.
  away(botPos, grenadePos, s.grenadeAvoidDistance * 1.3)

func creepTarget*(botPos, enemyPos: Vec3; s: Settings): Vec3 =
  ## A slow approach that stops short. A creeping bot that walks all the way in
  ## is a bot that has stopped creeping.
  towards(botPos, enemyPos,
          clampf(distance(botPos, enemyPos) - 8.0, 0.0, 25.0))

func searchWideTarget*(centre, from1: Vec3; radius: float; side: float): Vec3 =
  ## A point on the far side of the uncertainty circle, on a chosen side. The
  ## widest guess a search makes before it gives up.
  let inbound = normalized(flat(centre - from1))
  if sqrMagnitude(inbound) < 0.0001:
    return centre
  let left = perpXZ(inbound)
  result = centre + inbound * (radius * 0.5) + left * (side * radius)

func extractDirection*(botPos: Vec3; threats: openArray[Vec3]): Vec3 =
  ## Where to go when the answer is "away from all of this".
  ##
  ## SAIN sends an extracting bot to an exfiltration point. This mod has no
  ## binding for the exfiltration controller (`README.md` says so), so the
  ## fallback is the direction that maximises distance from every threat the
  ## bot knows about -- the sum of the unit vectors away from each. It is not
  ## an extract. It is a bot leaving, which is the observable half of one, and
  ## it is honest about being that.
  var acc = zeroVec()
  var i = 0
  while i < threats.len:
    let d = flat(botPos - threats[i])
    let m = magnitude(d)
    if m > 0.001:
      acc = acc + d * (1.0 / m)
    inc i
  if sqrMagnitude(acc) < 0.0001:
    return vec3(botPos.x + 60.0, botPos.y, botPos.z)
  result = botPos + normalized(acc) * 60.0
