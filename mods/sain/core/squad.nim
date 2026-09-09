## The squad, assembled from what this mod already knows about every bot.
##
## ## Why this is not a binding
##
## SAIN's squad layer reads `BotOwner.BotsGroup` and enumerates its members:
## who is alive, who is in contact, who is hurt, who the leader is. Enumerating
## that group needs a handful of member names on a class whose post-1.0 shape
## nobody here has seen, and the previous version of this mod therefore left
## `SquadView` a hard-coded stub of one member -- which made every one of the
## twelve `SquadDecision` values unreachable. Half the decision enum was dead.
##
## The observation that fixes it is that **this mod already tracks every bot in
## the raid**. It has to: the driver holds a record per bot with a position, a
## role, a health reading and its current enemy, because that is what the
## budget schedules against. A squad view is a query over that table, and it
## needs no binding at all.
##
## One binding does improve it, and it is the cheapest possible one: the
## *identity* of `BotOwner.BotsGroup`. Not any member of it -- just the pointer,
## compared for equality. Two bots whose group pointer matches are in the same
## BSG group, and that is the whole of what is needed to partition the table
## correctly. If the getter refuses, `groupKey` is zero for everyone and the
## fallback below takes over: same faction, within `squadCohesionRadius`.
##
## The fallback is not the same thing as a BSG group and this file does not
## pretend it is. It is "the friendlies near me", which for every decision in
## `squadLayer` -- help a wounded mate, spread out, hold, regroup, suppress --
## is the quantity actually being asked about. A scav that helps a scav it did
## not spawn with is behaving better than one that ignores it.
##
## ## Cost
##
## One pass over the bot table per bot that is *thinking this tick*, which the
## driver's budget already bounds at eight. Thirty bots in the raid makes 240
## squared-distance comparisons per tick, no square roots on the reject path,
## and no allocation: the result is a `SquadView` by value.

import vec
import types
import settings

type
  Ally* = object
    ## One bot, as the squad query sees it. Filled from the driver's own
    ## per-bot record -- no game call is made to build one.
    key*: uint64            ## the bot's identity, as `EnemyView.key`
    ## `BotOwner.BotsGroup` as a bare pointer, or 0 when that binding refused.
    ## Compared for equality and never dereferenced.
    groupKey*: uint64
    role*: BotRole
    position*: Vec3
    health*: float          ## normalised
    alive*: bool
    ## This bot has an enemy it can currently see.
    seesEnemy*: bool
    ## This bot has an enemy at all, seen recently or not.
    inCombat*: bool
    ## When this bot last lost health. Feeds `memberTookDamageRecently`, which
    ## is what turns a squad's head when one of them is shot from a direction
    ## nobody was watching.
    lastDamagedAt*: float

func noAlly*(): Ally =
  Ally(key: 0'u64, groupKey: 0'u64, role: brScav, position: zeroVec(),
       health: 1.0, alive: false, seesEnemy: false, inCombat: false,
       lastDamagedAt: -9999.0)

func leaderRank*(r: BotRole): int =
  ## Who gives orders when the game will not say.
  ##
  ## A boss outranks its followers, a raider outranks a scav, and everything
  ## outranks nothing. Ties are broken by key below, so the answer is stable
  ## across ticks -- a squad whose leader changes every tick regroups on a
  ## different bot every tick and never arrives.
  case r
  of brBoss: 5
  of brGoon: 4
  of brRaider: 3
  of brPmc: 2
  of brFollower: 1
  of brScav, brPlayerScav, brZombie: 0

func sameSquad*(me, other: Ally; s: Settings): bool =
  ## The partition. Group identity when it is readable, faction and proximity
  ## when it is not.
  if me.key == other.key:
    return false
  if not other.alive:
    return false
  if me.groupKey != 0'u64 and other.groupKey != 0'u64:
    return me.groupKey == other.groupKey
  if hostile(factionOf(me.role), factionOf(other.role)):
    return false
  # Squared, so the reject path -- which is most of the table -- never takes a
  # square root.
  let r = s.squadCohesionRadius
  result = sqrDistance(me.position, other.position) <= r * r

proc squadViewFor*(me: Ally; allies: openArray[Ally]; count: int;
                   s: Settings; now: float): SquadView =
  ## One pass. Everything `squadLayer` reads, and nothing it does not.
  ##
  ## `count` bounds the scan rather than `allies.len`, because the caller keeps
  ## one array for the whole raid and only the first `count` entries are live.
  ## Re-slicing would mean a fresh sequence per bot per tick, which is exactly
  ## the per-frame allocation this port exists to remove.
  result = SquadView(
    memberCount: 1, aliveCount: 1, isLeader: true, leaderAlive: true,
    leaderDistance: 0.0, nearestMateDistance: 9999.0, mateNeedsHelp: false,
    mateInCombat: false, squadSeesEnemy: false,
    memberTookDamageRecently: false, nearestMatePosition: zeroVec(),
    haveMate: false)
  if not me.alive:
    return

  var bestRank = leaderRank(me.role)
  var bestKey = me.key
  var leaderPos = me.position
  var nearestSqr = 9999.0 * 9999.0
  var nearestPos = me.position
  var haveMate = false
  var n = count
  if n > allies.len: n = allies.len
  var i = 0
  while i < n:
    let a = allies[i]
    inc i
    if not sameSquad(me, a, s):
      continue
    result.memberCount = result.memberCount + 1
    result.aliveCount = result.aliveCount + 1
    let dSqr = sqrDistance(me.position, a.position)
    if dSqr < nearestSqr:
      nearestSqr = dSqr
      nearestPos = a.position
      haveMate = true
    if a.seesEnemy:
      result.squadSeesEnemy = true
    if a.inCombat:
      result.mateInCombat = true
    if now - a.lastDamagedAt < 8.0:
      result.memberTookDamageRecently = true
    # "Needs help" is a mate who is badly hurt, near enough to reach, and in
    # trouble rather than merely scratched. SAIN reads a `BotOwner` death or a
    # `IsInCombat` flag; a health fraction is the same signal and is already in
    # hand.
    if a.health < 0.35 and a.inCombat:
      result.mateNeedsHelp = true
    let rank = leaderRank(a.role)
    # `>` then a key tie-break, in that order, so the answer does not depend on
    # the order the driver happens to hold the table in.
    if rank > bestRank or (rank == bestRank and a.key > bestKey):
      bestRank = rank
      bestKey = a.key
      leaderPos = a.position

  if haveMate:
    result.nearestMateDistance = sqrt0(nearestSqr)
    result.nearestMatePosition = nearestPos
    result.haveMate = true
  result.isLeader = bestKey == me.key
  result.leaderAlive = true
  result.leaderDistance = (if result.isLeader: 0.0
                           else: distance(me.position, leaderPos))
