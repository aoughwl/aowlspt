## Scenario tests for the decision core.
##
## This file is the reason `core/` refuses to call the game. Every check below
## builds a `BotView` by hand, runs the ladder, and asserts which decision came
## out — no Tarkov, no Unity, no IL2CPP, no raid. SAIN has no equivalent and
## could not easily have one: its decisions read live components off a live bot.
##
## Pure, like everything else here: `run` returns lines and the caller decides
## what to do with them. That keeps the tests runnable from the simulator, from
## the server side, and from a future host that has neither.
##
## ## The three kinds of check here
##
##  1. **A scenario.** One `BotView`, one `decide`, one assertion about the
##     answer. Most of the file.
##  2. **A model check.** The hearing, vision and suppression models are
##     functions of numbers over time, so they are driven over a sequence of
##     ticks and the *trajectory* is asserted -- that awareness rises with a
##     line of sight, that suppression decays without one, that a sound at
##     200 m is not heard. A single-tick assertion cannot see any of that.
##  3. **A flicker check**, and this is the one a live test cannot do at all.
##     A decision system that alternates between two states every tick is the
##     classic bot-AI failure and it is *invisible* in a raid: the bot looks
##     twitchy and nobody can say why. Here the input is swept across a
##     threshold with noise on it and the number of decision changes is
##     counted. A ladder with working hysteresis changes a handful of times; one
##     without changes on nearly every tick. `flickerChecks` is that.

import vec
import types
import settings
import decide
import enemy
import search
import cover
import probe
import rng
import hearing
import vision
import suppress
import squad
import objective
import flank
import sig

type
  TestReport* = object
    lines*: seq[string]
    passed*: int
    failed*: int

proc check(r: var TestReport; name: string; ok: bool; got: string) =
  if ok:
    r.passed = r.passed + 1
    r.lines.add "ok    " & name
  else:
    r.failed = r.failed + 1
    r.lines.add "FAIL  " & name & " (got " & got & ")"

func near(a, b, tol: float): bool =
  let d = a - b
  result = (if d < 0.0: -d else: d) <= tol

func baseView(): BotView =
  ## A healthy PMC, armed, in the open, with no enemy. Every scenario starts
  ## here and changes exactly the fields it is about, so a test says what it
  ## tests rather than restating a bot.
  var me = SelfView(
    healthNormalized: 1.0, energy: 1.0, hydration: 1.0, stamina: 1.0,
    hasHeavyBleed: false, hasLightBleed: false, hasFracture: false,
    canHeal: true, canUseStims: true, canDoSurgery: true,
    ammoInMagazine: 30, magazineSize: 30, hasAmmoToReload: true,
    weaponReady: true, inCoverStatus: csFarFromCover, coverPointDistance: 20.0,
    coverPosition: zeroVec(), hasCoverPoint: false,
    suppressionLevel: 0.0, isSprinting: false, position: zeroVec(),
    lookDirection: vec3(1.0, 0.0, 0.0), velocity: zeroVec(),
    timeSinceDamaged: 9999.0, recentDamage: 0.0)
  var sq = SquadView(
    memberCount: 1, aliveCount: 1, isLeader: true, leaderAlive: true,
    leaderDistance: 0.0, nearestMateDistance: 9999.0, mateNeedsHelp: false,
    mateInCombat: false, squadSeesEnemy: false, memberTookDamageRecently: false,
    nearestMatePosition: zeroVec(), haveMate: false)
  BotView(role: brPmc, personality: pNormal, difficulty: 0.5,
          timeNow: 100.0, me: me, enemy: emptyEnemy(), enemyCount: 0,
          squad: sq,
          grenade: GrenadeThreat(active: false, position: zeroVec(),
                                 distance: 999.0, secondsToDetonation: 0.0),
          lastSound: skNone, lastSoundPosition: zeroVec(),
          lastSoundDistance: 0.0, timeSinceLastSound: 999.0,
          hasSearchTarget: false, searchTarget: zeroVec(),
          extractRequested: false, raidSeconds: 60.0, moveTarget: zeroVec(),
          hasMoveTarget: false)

func visibleEnemyAt(d: float): EnemyView =
  ## An enemy this bot has *acquired*: seen, noticed, and past its reaction
  ## delay. `awareness` and `canShoot` are set together on purpose -- since
  ## `core/vision.nim` exists, a test that sets one without the other is
  ## describing a bot that cannot happen.
  var e = emptyEnemy()
  e.key = 1'u64
  e.valid = true
  e.alive = true
  e.isPlayer = true
  e.position = vec3(d, 0.0, 0.0)
  e.realPosition = e.position
  e.visible = true
  e.canShoot = true
  e.awareness = 1.0
  e.reactionUntil = 0.0
  e.timeSinceSeen = 0.0
  e.timeSinceHeard = 0.0
  e.seenTotal = 1.0
  e.distance = d
  e.pathDistance = d
  e.band = bandFor(d)
  e.inFieldOfView = true
  e.lookingAtUs = false
  e.threatLevel = 1.0
  result = e

func observationOf(key: uint64; at: Vec3; saw, heardIt: bool;
                   dist: float): Observation =
  Observation(key: key, alive: true, isPlayer: true, position: at,
              sawThisTick: saw, heardThisTick: heardIt,
              firedAtUsThisTick: false, lookingAtUsThisTick: false,
              pathDistance: dist, heard: nothingHeard())

# ---------------------------------------------------------------------------
# The flicker harness
# ---------------------------------------------------------------------------

proc sweepChanges(s: Settings; lo, hi: float; ticks: int;
                  what: int): int =
  ## Drive the ladder for `ticks` decisions while sweeping one input back and
  ## forth across a threshold, with a little noise on it, and count how many
  ## times the combat decision changed.
  ##
  ## `what` selects the input: 0 health, 1 enemy distance, 2 suppression. Three
  ## separate procs would read better and would also mean three copies of the
  ## loop; the thresholds being swept are the three that a real fight actually
  ## sits on top of, which is why these three.
  ##
  ## The point is not the exact count. It is that a system with hysteresis
  ## produces a number in the low tens over four hundred ticks and a system
  ## without produces one in the hundreds, and no amount of watching a bot in a
  ## raid will tell the two apart.
  var b = baseView()
  b.enemy = visibleEnemyAt(30.0)
  var ctx = newContext(0.5)
  var r1 = newRng(0x51A1'u64)
  var last = cdNone
  var changes = 0
  var i = 0
  while i < ticks:
    let t = float(i) / float(ticks)
    # A triangle wave across the range, plus noise: a monotone ramp would cross
    # the threshold once and prove nothing.
    let u = (if t < 0.5: t * 2.0 else: 2.0 - t * 2.0)
    let v = lo + (hi - lo) * u + rangeF(r1, -0.02, 0.02) * (hi - lo)
    case what
    of 0: b.me.healthNormalized = clampf(v, 0.01, 1.0)
    of 1:
      b.enemy.distance = v
      b.enemy.pathDistance = v
      b.enemy.band = bandFor(v)
      b.enemy.position = vec3(v, 0.0, 0.0)
      b.enemy.realPosition = b.enemy.position
    else: b.me.suppressionLevel = clampf(v, 0.0, 1.0)
    b.timeNow = b.timeNow + 0.1
    let d = decide(ctx, b, s)
    if d.combat != last:
      inc changes
      last = d.combat
    inc i
  result = changes

# ---------------------------------------------------------------------------
# The cost harness
# ---------------------------------------------------------------------------

proc benchDecisions*(iterations: int): int =
  ## Run the full cascade `iterations` times and return a checksum.
  ##
  ## The checksum exists so the optimiser cannot delete the work; the caller
  ## brackets this with `fast.perfCounter` and divides. It is here rather than
  ## in the caller because the *inputs* have to be representative -- a bot with
  ## no enemy exits the ladder on its second rung and would measure nothing.
  ## So the loop rotates through five states that between them reach the
  ## reflexes, the self layer, the squad layer and the deep end of the solo
  ## ladder.
  ##
  ## Nothing in the loop allocates. That is the claim the number is only
  ## meaningful alongside, and it is why `Decision.reason` is an enum.
  let s = defaultSettings()
  var ctx = newContext(0.5)
  var b = baseView()
  var sum = 0
  var i = 0
  while i < iterations:
    let phase = i mod 5
    case phase
    of 0:
      b.enemy = visibleEnemyAt(30.0)
      b.me.healthNormalized = 1.0
      b.me.suppressionLevel = 0.0
      b.grenade = GrenadeThreat(active: false, position: zeroVec(),
                                distance: 999.0, secondsToDetonation: 0.0)
    of 1:
      b.enemy = visibleEnemyAt(90.0)
      b.enemy.visible = false
      b.enemy.canShoot = false
      b.enemy.timeSinceSeen = 30.0
      b.squad.memberCount = 4
      b.squad.aliveCount = 4
      b.squad.isLeader = false
      b.squad.leaderDistance = 140.0
      b.squad.nearestMateDistance = 20.0
      b.squad.haveMate = true
    of 2:
      b.me.healthNormalized = 0.45
      b.me.ammoInMagazine = 4
    of 3:
      b.me.suppressionLevel = 0.9
      b.me.inCoverStatus = csInCover
    else:
      b.grenade = GrenadeThreat(active: true, position: vec3(2.0, 0.0, 0.0),
                                distance: 3.0, secondsToDetonation: 1.0)
    b.timeNow = b.timeNow + 0.1
    let d = decide(ctx, b, s)
    sum = sum + ord(d.combat) + ord(d.squad) + ord(d.self)
    inc i
  result = sum

# ---------------------------------------------------------------------------
# The checks
# ---------------------------------------------------------------------------

proc ladderChecks(r: var TestReport; s: Settings) =
  block:
    # A grenade outranks a fight the bot is winning.
    var b = baseView()
    b.enemy = visibleEnemyAt(20.0)
    b.grenade = GrenadeThreat(active: true, position: vec3(1.0, 0.0, 0.0),
                              distance: 3.0, secondsToDetonation: 1.5)
    var ctx = newContext(0.5)
    let d = decide(ctx, b, s)
    check(r, "a grenade interrupts a winning fight",
          d.combat == cdAvoidGrenade, decisionName(d.combat))
    check(r, "avoiding a grenade moves away from it",
          d.hasMove and d.moveTo.x < 0.0, $d.moveTo.x)

  block:
    var b = baseView()
    var ctx = newContext(0.5)
    let d = decide(ctx, b, s)
    check(r, "no enemy and no lead is None", d.combat == cdNone,
          decisionName(d.combat))
    check(r, "a decision with nowhere to go says so", not d.hasMove,
          $d.hasMove)

  block:
    var b = baseView()
    b.enemy = visibleEnemyAt(6.0)
    var ctx = newContext(0.5)
    let d = decide(ctx, b, s)
    check(r, "an enemy inside dogfight range is a dogfight",
          d.combat == cdDogFight, decisionName(d.combat))

  block:
    var b = baseView()
    b.enemy = visibleEnemyAt(40.0)
    b.me.healthNormalized = 0.15
    var ctx = newContext(0.5)
    let d = decide(ctx, b, s)
    check(r, "a nearly dead bot runs", d.combat == cdRunAway,
          decisionName(d.combat))
    check(r, "running away moves away from the enemy",
          d.hasMove and d.moveTo.x < 0.0, $d.moveTo.x)

  block:
    var b = baseView()
    b.enemy = visibleEnemyAt(40.0)
    b.me.healthNormalized = 0.45
    var ctx = newContext(0.5)
    let d = decide(ctx, b, s)
    check(r, "a hurt bot in the open retreats", d.combat == cdRetreat,
          decisionName(d.combat))

  block:
    # ...and retreats *to cover* when it has some, rather than merely backwards.
    var b = baseView()
    b.enemy = visibleEnemyAt(40.0)
    b.me.healthNormalized = 0.45
    b.me.hasCoverPoint = true
    b.me.coverPosition = vec3(0.0, 0.0, 7.0)
    var ctx = newContext(0.5)
    let d = decide(ctx, b, s)
    check(r, "a retreat with cover available goes to the cover",
          d.hasMove and near(d.moveTo.z, 7.0, 0.001), $d.moveTo.z)

  block:
    var b = baseView()
    b.enemy = visibleEnemyAt(40.0)
    b.me.inCoverStatus = csInCover
    var ctx = newContext(0.5)
    let d = decide(ctx, b, s)
    check(r, "a healthy bot in cover with a shot fires",
          d.combat == cdStandAndShoot, decisionName(d.combat))

  block:
    var b = baseView()
    b.enemy = visibleEnemyAt(200.0)
    var ctx = newContext(0.5)
    let d = decide(ctx, b, s)
    check(r, "a very distant visible enemy is a distant shot",
          d.combat == cdShootDistantEnemy, decisionName(d.combat))

  block:
    # The rung this port added: line of sight without acquisition.
    var b = baseView()
    b.enemy = visibleEnemyAt(30.0)
    b.enemy.canShoot = false          ## seen by the engine, not yet noticed
    b.enemy.awareness = 0.2
    var ctx = newContext(0.5)
    let d = decide(ctx, b, s)
    check(r, "an unacquired enemy in the open sends the bot to cover",
          d.combat == cdSeekCover and d.reason == drNotYetAcquired,
          decisionName(d.combat))

  block:
    var b = baseView()
    b.enemy = visibleEnemyAt(30.0)
    b.enemy.canShoot = false
    b.enemy.awareness = 0.2
    b.me.inCoverStatus = csInCover
    var ctx = newContext(0.5)
    let d = decide(ctx, b, s)
    check(r, "an unacquired enemy while in cover keeps the bot in it",
          d.combat == cdHoldInCover and d.reason == drNotYetAcquired,
          decisionName(d.combat))

  block:
    # Empty magazine, with ammo left: reload regardless of who is looking.
    var b = baseView()
    b.enemy = visibleEnemyAt(40.0)
    b.me.ammoInMagazine = 0
    var ctx = newContext(0.5)
    let d = decide(ctx, b, s)
    check(r, "an empty magazine reloads even under fire",
          d.self == saReload, selfActionName(d.self))

  block:
    var b = baseView()
    b.enemy = visibleEnemyAt(40.0)
    b.me.ammoInMagazine = 10
    var ctx = newContext(0.5)
    let d = decide(ctx, b, s)
    check(r, "a partial magazine is not reloaded in contact",
          d.self == saNone, selfActionName(d.self))

  block:
    var b = baseView()
    b.me.hasHeavyBleed = true
    var ctx = newContext(0.5)
    let d = decide(ctx, b, s)
    check(r, "a heavy bleed is treated immediately", d.self == saFirstAid,
          selfActionName(d.self))

  block:
    # Hysteresis: a decision in progress is not abandoned for an equal one.
    var b = baseView()
    b.enemy = visibleEnemyAt(40.0)
    b.me.healthNormalized = 0.45
    var ctx = newContext(0.5)
    let first = decide(ctx, b, s)
    b.timeNow = b.timeNow + 0.2
    b.me.healthNormalized = 0.56
    let second = decide(ctx, b, s)
    check(r, "a retreat is not abandoned the tick health ticks back up",
          second.combat == first.combat, decisionName(second.combat))

  block:
    var b = baseView()
    b.enemy = visibleEnemyAt(40.0)
    b.me.healthNormalized = 0.45
    var ctx = newContext(0.5)
    discard decide(ctx, b, s)
    b.timeNow = b.timeNow + 0.2
    b.grenade = GrenadeThreat(active: true, position: zeroVec(),
                              distance: 4.0, secondsToDetonation: 1.0)
    let d = decide(ctx, b, s)
    check(r, "a held decision still yields to a grenade",
          d.combat == cdAvoidGrenade, decisionName(d.combat))

  block:
    # Squad: a mate down outranks this bot's own approach.
    var b = baseView()
    b.squad.memberCount = 3
    b.squad.aliveCount = 3
    b.squad.isLeader = false
    b.squad.mateNeedsHelp = true
    b.squad.nearestMateDistance = 20.0
    b.squad.haveMate = true
    b.enemy = visibleEnemyAt(90.0)
    b.enemy.visible = false
    b.enemy.canShoot = false
    b.enemy.timeSinceSeen = 30.0
    b.enemy.threatLevel = 0.5
    var ctx = newContext(0.5)
    let d = decide(ctx, b, s)
    check(r, "a downed squadmate produces a Help order", d.squad == sdHelp,
          squadDecisionName(d.squad))

  block:
    var b = baseView()
    b.squad.memberCount = 4
    b.squad.aliveCount = 4
    b.squad.isLeader = false
    b.squad.leaderDistance = 140.0
    b.squad.nearestMateDistance = 60.0
    b.squad.haveMate = true
    var ctx = newContext(0.5)
    let d = decide(ctx, b, s)
    check(r, "a scattered squad out of contact regroups",
          d.squad == sdRegroup, squadDecisionName(d.squad))

  block:
    # Personality: the same inputs, two personalities, two answers.
    var b = baseView()
    b.enemy = visibleEnemyAt(25.0)
    let chad = resolvedFor(s, pGigaChad, 0.5)
    let coward = resolvedFor(s, pCoward, 0.5)
    b.me.healthNormalized = 0.5
    var c1 = newContext(0.5)
    var c2 = newContext(0.5)
    let dc = decide(c1, b, chad)
    let dw = decide(c2, b, coward)
    check(r, "a GigaChad and a Coward differ at the same health",
          dc.combat != dw.combat,
          decisionName(dc.combat) & "/" & decisionName(dw.combat))

  block:
    # Every reason has text. A `drNone` leaking into a log line that says
    # nothing is the failure this replaces a string with an enum to avoid.
    var bad = 0
    var i = ord(drNone)
    while i <= ord(drExtracting):
      if reasonText(DecisionReason(i)).len == 0:
        inc bad
      inc i
    check(r, "every decision reason has a log line", bad == 0, $bad)

proc extractChecks(r: var TestReport; s: Settings) =
  block:
    var b = baseView()
    b.raidSeconds = 900.0
    b.me.healthNormalized = 0.2
    b.me.ammoInMagazine = 1
    b.me.hasAmmoToReload = false
    b.enemy = visibleEnemyAt(60.0)
    var ctx = newContext(0.5)
    let d = decide(ctx, b, s)
    check(r, "hurt, dry and late in the raid is an extract",
          d.combat == cdExtract, decisionName(d.combat))

  block:
    # ...and it latches: a first-aid kit is not a reason to walk back in.
    var b = baseView()
    b.raidSeconds = 900.0
    b.me.healthNormalized = 0.2
    b.me.ammoInMagazine = 1
    b.me.hasAmmoToReload = false
    b.enemy = visibleEnemyAt(60.0)
    var ctx = newContext(0.5)
    discard decide(ctx, b, s)
    b.timeNow = b.timeNow + 20.0
    b.me.healthNormalized = 1.0
    b.me.ammoInMagazine = 30
    b.me.hasAmmoToReload = true
    let d = decide(ctx, b, s)
    check(r, "an extract is not abandoned when the bot heals",
          d.combat == cdExtract, decisionName(d.combat))

  block:
    # Early in the raid the same bot fights instead.
    var b = baseView()
    b.raidSeconds = 30.0
    b.me.healthNormalized = 0.2
    b.me.ammoInMagazine = 1
    b.me.hasAmmoToReload = false
    b.enemy = visibleEnemyAt(60.0)
    var ctx = newContext(0.5)
    let d = decide(ctx, b, s)
    check(r, "the same bot early in a raid does not extract",
          d.combat != cdExtract, decisionName(d.combat))

proc flankChecks(r: var TestReport; s: Settings) =
  block:
    # The geometry: the waypoint is off the bearing, not on it.
    let t = flankTarget(zeroVec(), vec3(40.0, 0.0, 0.0), 1.0, s)
    check(r, "a flank waypoint leaves the direct line",
          t.z > 5.0 and t.x > 10.0 and t.x < 40.0,
          $t.x & "," & $t.z)

  block:
    # Two bots of a squad go opposite ways.
    let enemyPos = vec3(40.0, 0.0, 0.0)
    let a = vec3(0.0, 0.0, 5.0)
    let mate = vec3(0.0, 0.0, 8.0)
    let sideAlone = flankSide(a, enemyPos, zeroVec(), false)
    let sideWithMate = flankSide(a, enemyPos, mate, true)
    check(r, "a bot flanks the side it is already on when alone",
          sideAlone > 0.0 or sideAlone < 0.0, $sideAlone)
    check(r, "two squadmates on the same side flank opposite ways",
          sideWithMate == -sideAlone, $sideWithMate)

  block:
    # The decision: not before the fight has stalled, and yes after.
    var b = baseView()
    b.enemy = visibleEnemyAt(30.0)
    b.enemy.visible = false
    b.enemy.canShoot = false
    b.enemy.awareness = 0.9
    b.enemy.timeSinceSeen = 3.0
    var ctx = newContext(0.5)
    ctx.engagedSince = b.timeNow          ## the fight just started
    let early = decide(ctx, b, s)
    check(r, "a bot does not flank a fight it has only just joined",
          early.combat != cdFlank, decisionName(early.combat))

    var ctx2 = newContext(0.5)
    ctx2.engagedSince = b.timeNow - 30.0  ## it has been going nowhere
    let late = decide(ctx2, b, s)
    check(r, "a stalled fight is worth changing the angle of",
          late.combat == cdFlank, decisionName(late.combat))
    check(r, "a flank has somewhere to be", late.hasMove, $late.hasMove)

  block:
    # The side is held for the cooldown rather than re-decided per tick, which
    # is the specific failure a flank without a latch produces: the bot crosses
    # the bearing, the "which side am I on" test flips, and it crosses back.
    var b = baseView()
    b.enemy = visibleEnemyAt(30.0)
    b.enemy.visible = false
    b.enemy.canShoot = false
    b.enemy.awareness = 0.9
    b.enemy.timeSinceSeen = 3.0
    b.me.position = vec3(0.0, 0.0, 6.0)
    var ctx = newContext(0.5)
    ctx.engagedSince = b.timeNow - 30.0
    let first = decide(ctx, b, s)
    let heldSide = ctx.flankSideHeld
    # Move the bot across to the other side of the bearing.
    b.me.position = vec3(0.0, 0.0, -6.0)
    b.timeNow = b.timeNow + 0.5
    discard decide(ctx, b, s)
    check(r, "a flank keeps its side when the bot crosses the bearing",
          ctx.flankSideHeld == heldSide and first.combat == cdFlank,
          $ctx.flankSideHeld)

  block:
    # A Coward is given every reason to flank and does not.
    let coward = resolvedFor(s, pCoward, 0.5)
    var b = baseView()
    b.enemy = visibleEnemyAt(30.0)
    b.enemy.visible = false
    b.enemy.canShoot = false
    b.enemy.awareness = 0.9
    b.enemy.timeSinceSeen = 3.0
    var ctx = newContext(0.5)
    ctx.engagedSince = b.timeNow - 30.0
    let d = decide(ctx, b, coward)
    check(r, "a personality that cannot flank never does",
          d.combat != cdFlank, decisionName(d.combat))

proc hearingChecks(r: var TestReport; s: Settings) =
  var r1 = newRng(7'u64)

  block:
    let still1 = motionSound(zeroVec(), vec3(0.02, 0.0, 0.0), 0.1, false,
                             0.0, 9'u64)
    check(r, "something that has not moved makes no sound",
          still1.kind == skNone, soundName(still1.kind))
    let walk = motionSound(zeroVec(), vec3(0.15, 0.0, 0.0), 0.1, false,
                           0.0, 9'u64)
    check(r, "a walk is a footstep", walk.kind == skFootStep,
          soundName(walk.kind))
    let run = motionSound(zeroVec(), vec3(0.6, 0.0, 0.0), 0.1, false,
                          0.0, 9'u64)
    check(r, "six metres a second is a sprint whether or not the flag says so",
          run.kind == skSprint, soundName(run.kind))

  block:
    let e = SoundEvent(kind: skSprint, position: vec3(20.0, 0.0, 0.0),
                       key: 9'u64, at: 0.0, intensity: 1.0)
    let near1 = listen(e, zeroVec(), s, false, 0.5, r1)
    check(r, "a sprint twenty metres away is heard", near1.audible,
          $near1.audible)
    let e2 = SoundEvent(kind: skSprint, position: vec3(200.0, 0.0, 0.0),
                        key: 9'u64, at: 0.0, intensity: 1.0)
    let far1 = listen(e2, zeroVec(), s, false, 0.5, r1)
    check(r, "a sprint two hundred metres away is not", not far1.audible,
          $far1.audible)

  block:
    # Occlusion. Same sound, same distance, a wall in the way.
    let e = SoundEvent(kind: skFootStep, position: vec3(16.0, 0.0, 0.0),
                       key: 9'u64, at: 0.0, intensity: 1.0)
    let open1 = listen(e, zeroVec(), s, false, 0.5, r1)
    let blocked = listen(e, zeroVec(), s, true, 0.5, r1)
    check(r, "a footstep through a wall carries less far",
          open1.audible and not blocked.audible,
          $open1.audible & "/" & $blocked.audible)

  block:
    # Localisation. A shot at range is a bearing, not a place.
    let close1 = SoundEvent(kind: skShot, position: vec3(6.0, 0.0, 0.0),
                            key: 9'u64, at: 0.0, intensity: 1.0)
    let distant = SoundEvent(kind: skShot, position: vec3(160.0, 0.0, 0.0),
                             key: 9'u64, at: 0.0, intensity: 1.0)
    let hc = listen(close1, zeroVec(), s, false, 0.5, r1)
    let hd = listen(distant, zeroVec(), s, false, 0.5, r1)
    let errClose = distance(hc.position, close1.position)
    let errFar = distance(hd.position, distant.position)
    check(r, "a nearby sound is localised better than a distant one",
          hc.audible and hd.audible and errFar > errClose,
          $errClose & " vs " & $errFar)

  block:
    # A sound older than the memory window is not heard at all.
    let e = SoundEvent(kind: skShot, position: vec3(10.0, 0.0, 0.0),
                       key: 9'u64, at: 0.0, intensity: 1.0)
    let stale = listen(e, zeroVec(), s, false, s.soundMemorySeconds + 5.0, r1)
    check(r, "a sound outside the memory window is forgotten",
          not stale.audible, $stale.audible)

  block:
    # Acuity is the dial personality moves. A Rat hears what a Wreckless does
    # not, from the same place.
    let rat = resolvedFor(s, pRat, 0.5)
    let wreck = resolvedFor(s, pWreckless, 0.5)
    let e = SoundEvent(kind: skFootStep, position: vec3(25.0, 0.0, 0.0),
                       key: 9'u64, at: 0.0, intensity: 1.0)
    let hr = listen(e, zeroVec(), rat, false, 0.5, r1)
    let hw = listen(e, zeroVec(), wreck, false, 0.5, r1)
    check(r, "a Rat hears a footstep a Wreckless misses",
          hr.audible and not hw.audible,
          $hr.audible & "/" & $hw.audible)

proc visionChecks(r: var TestReport; s: Settings) =
  block:
    # Acquisition takes time, and the first tick of line of sight is not a shot.
    var t = newEnemyTable()
    var r1 = newRng(3'u64)
    observe(t, observationOf(1'u64, vec3(60.0, 0.0, 0.0), true, false, 60.0),
            zeroVec(), vec3(1.0, 0.0, 0.0), s, 0.0, 0.1, r1)
    check(r, "the first tick of line of sight is not a shot",
          not t.items[0].canShoot, $t.items[0].awareness)
    var i = 0
    while i < 40:
      observe(t, observationOf(1'u64, vec3(60.0, 0.0, 0.0), true, false, 60.0),
              zeroVec(), vec3(1.0, 0.0, 0.0), s, 0.1 * float(i) + 0.1, 0.1, r1)
      inc i
    check(r, "a bot with four seconds of line of sight has acquired",
          t.items[0].canShoot, $t.items[0].awareness)

  block:
    # Distance changes how long it takes.
    let near1 = gainRate(10.0, 1.0, false, false, s)
    let far1 = gainRate(150.0, 1.0, false, false, s)
    check(r, "a close target is acquired faster than a distant one",
          near1 > far1 * 2.0, $near1 & " vs " & $far1)
    let ahead = gainRate(40.0, 1.0, false, false, s)
    let edge = gainRate(40.0, 0.0, false, false, s)
    check(r, "a target dead ahead is acquired faster than one at the edge",
          ahead > edge, $ahead & " vs " & $edge)
    let still1 = gainRate(40.0, 1.0, false, false, s)
    let running = gainRate(40.0, 1.0, true, true, s)
    check(r, "a sprinting target is acquired fastest of all",
          running > still1, $running & " vs " & $still1)

  block:
    # The reaction delay is real: awareness can be full and the bot still not
    # allowed to act, for as long as the delay lasts.
    var e = visibleEnemyAt(30.0)
    e.reactionUntil = 105.0
    check(r, "a bot that has just noticed you may not shoot yet",
          not mayEngage(e, s, 100.0), "engaged")
    check(r, "...and may once the reaction delay has passed",
          mayEngage(e, s, 106.0), "not engaged")

  block:
    # Difficulty is felt here more than anywhere.
    let easy = resolvedFor(s, pNormal, 0.0)
    let hard = resolvedFor(s, pNormal, 1.0)
    check(r, "a harder bot reacts sooner",
          hard.reactionTimeBase < easy.reactionTimeBase,
          $hard.reactionTimeBase & " vs " & $easy.reactionTimeBase)
    check(r, "a harder bot acquires faster",
          hard.sightGainPerSecond > easy.sightGainPerSecond,
          $hard.sightGainPerSecond)

  block:
    # The two thresholds are always apart, for every personality. A pair that
    # meets is a single threshold with two names and flickers.
    var bad = 0
    var i = ord(pNone)
    while i <= ord(pNormal):
      let rs = resolvedFor(s, Personality(i), 0.5)
      if rs.dropAwareness >= rs.engageAwareness:
        inc bad
      inc i
    check(r, "the acquire and drop thresholds never meet", bad == 0, $bad)

  block:
    # Memory of a face outlasts the face. Awareness bleeds rather than snapping.
    var e = visibleEnemyAt(30.0)
    e.visible = false
    var r1 = newRng(5'u64)
    updateAwareness(e, s, vec3(1.0, 0.0, 0.0), zeroVec(), 100.0, 0.1, r1)
    check(r, "losing sight does not lose the enemy",
          e.awareness > s.engageAwareness, $e.awareness)
    var i = 0
    while i < 20:
      updateAwareness(e, s, vec3(1.0, 0.0, 0.0), zeroVec(), 100.0, 0.5, r1)
      inc i
    check(r, "...but two minutes of nothing does", e.awareness <= 0.001,
          $e.awareness)

  block:
    # Uncertainty grows while contact is lost and collapses when it returns.
    var e = visibleEnemyAt(30.0)
    e.visible = false
    var i = 0
    while i < 10:
      decayUncertainty(e, s, 0.5)
      inc i
    check(r, "the last known place gets less certain with time",
          e.uncertainty > 8.0, $e.uncertainty)
    e.visible = true
    decayUncertainty(e, s, 0.1)
    check(r, "seeing them again makes it certain", e.uncertainty == 0.0,
          $e.uncertainty)

proc suppressionChecks(r: var TestReport; s: Settings) =
  block:
    # A moment of fire is a flinch, not a pin.
    var sup = newSuppression()
    discard feed(sup, true, false, 1.0, s, 0.0, 0.1)
    check(r, "one tick of incoming fire does not pin a bot",
          not sup.pinned.value and sup.level > 0.0, $sup.level)

  block:
    # Sustained fire is.
    var sup = newSuppression()
    var i = 0
    while i < 12:
      discard feed(sup, true, false, 1.0, s, float(i) * 0.1, 0.1)
      inc i
    check(r, "a second of sustained fire pins a bot", sup.pinned.value,
          $sup.level)

  block:
    # And it stays pinned for the minimum dwell after the shooting stops --
    # the specific anti-flicker rule, tested rather than asserted.
    var sup = newSuppression()
    var i = 0
    while i < 12:
      discard feed(sup, true, false, 1.0, s, float(i) * 0.1, 0.1)
      inc i
    discard feed(sup, false, false, 1.0, s, 1.3, 0.1)
    check(r, "a bot does not stand up the frame the shooting pauses",
          sup.pinned.value, $sup.level)
    var t = 1.4
    while t < 6.0:
      discard feed(sup, false, false, 1.0, s, t, 0.1)
      t = t + 0.1
    check(r, "...and does stand up once it has been quiet a while",
          not sup.pinned.value, $sup.level)

  block:
    # Being hit is the strongest suppressor and needs no binding to detect.
    var sup = newSuppression()
    discard feed(sup, false, false, 1.0, s, 0.0, 0.1)
    let before = sup.level
    let dmg = feed(sup, false, false, 0.7, s, 0.1, 0.1)
    check(r, "taking a hit suppresses and reports the damage",
          sup.level > before and near(dmg, 0.3, 0.001),
          $sup.level & "/" & $dmg)

  block:
    # And the same hit, told rather than inferred, moves the accumulator by
    # the same amount. That equality is the whole reason the told amount is a
    # parameter of `feed` rather than a second entry point: a bot on a host
    # with the damage hook and a bot on one without must be tuned by the same
    # numbers in `settings.nim`, or every threshold there means two things.
    # This check is what caught it when it was not true -- see the note on
    # `feed` in `core/suppress.nim`.
    var told = newSuppression()
    var inferred = newSuppression()
    discard feed(told, false, false, 1.0, s, 0.0, 0.1)
    discard feed(inferred, false, false, 1.0, s, 0.0, 0.1)
    discard feed(told, false, false, 1.0, s, 0.1, 0.1, 0.3)
    discard feed(inferred, false, false, 0.7, s, 0.1, 0.1)
    check(r, "a hit told by the damage hook suppresses exactly as much as " &
             "the same hit inferred from health",
          near(told.level, inferred.level, 0.0001),
          $told.level & " told / " & $inferred.level & " inferred")

  block:
    # A hit with no readable magnitude still registers. `drainDamage` credits
    # the smallest step there is for a method whose declared shape carried no
    # float, and the point of accepting it is that "hit, now" is exact even
    # when "how much" is not.
    var sup = newSuppression()
    discard feed(sup, false, false, 1.0, s, 0.0, 0.1)
    let before = sup.level
    discard feed(sup, false, false, 1.0, s, 0.1, 0.1, 0.01)
    check(r, "a hit with no readable amount still suppresses and stamps the " &
             "time",
          sup.level > before and near(timeSinceDamaged(sup, 0.1), 0.0, 0.001),
          $sup.level & " from " & $before)

  block:
    # And zero is not a hit. `noteDamage` records an event with an amount of
    # zero, and it is `drainDamage` that decides what a zero means -- so the
    # accumulator itself must not move on one, or a method whose shape this
    # mod misread would suppress every bot it fired for.
    var sup = newSuppression()
    var i = 0
    while i < 6:
      discard feed(sup, true, false, 1.0, s, float(i) * 0.1, 0.1)
      inc i
    let before = sup.level
    let quiet = feed(sup, false, false, 1.0, s, 0.6, 0.1, 0.0)
    check(r, "an empty damage event is not a hit",
          near(quiet, 0.0, 0.000001) and sup.level < before,
          $quiet & " reported, level " & $sup.level & " from " & $before)

  block:
    # Courage resists it: the same fire pins a Coward and not a GigaChad.
    let coward = resolvedFor(s, pCoward, 0.5)
    let chad = resolvedFor(s, pGigaChad, 0.5)
    var sc = newSuppression()
    var sg = newSuppression()
    var i = 0
    while i < 5:
      discard feed(sc, true, false, 1.0, coward, float(i) * 0.1, 0.1)
      discard feed(sg, true, false, 1.0, chad, float(i) * 0.1, 0.1)
      inc i
    check(r, "the same burst pins a Coward and not a GigaChad",
          sc.pinned.value and not sg.pinned.value,
          $sc.level & "/" & $sg.level)

  block:
    # The level decays with nothing happening.
    var sup = newSuppression()
    var i = 0
    while i < 8:
      discard feed(sup, true, false, 1.0, s, float(i) * 0.1, 0.1)
      inc i
    let peak = sup.level
    var t = 1.0
    while t < 4.0:
      discard feed(sup, false, false, 1.0, s, t, 0.1)
      t = t + 0.1
    check(r, "suppression decays when nothing is happening",
          sup.level < peak, $sup.level & " from " & $peak)

func ally(key: uint64; group: uint64; role: BotRole; at: Vec3): Ally =
  Ally(key: key, groupKey: group, role: role, position: at, health: 1.0,
       alive: true, seesEnemy: false, inCombat: false, lastDamagedAt: -999.0)

proc squadChecks(r: var TestReport; s: Settings) =
  block:
    var mates: seq[Ally] = @[]
    mates.add ally(2'u64, 0'u64, brScav, vec3(10.0, 0.0, 0.0))
    mates.add ally(3'u64, 0'u64, brScav, vec3(200.0, 0.0, 0.0))
    let me = ally(1'u64, 0'u64, brScav, zeroVec())
    let v = squadViewFor(me, mates, mates.len, s, 0.0)
    check(r, "a nearby scav is a squadmate and a distant one is not",
          v.memberCount == 2 and near(v.nearestMateDistance, 10.0, 0.01),
          $v.memberCount & "/" & $v.nearestMateDistance)

  block:
    var mates: seq[Ally] = @[]
    mates.add ally(2'u64, 0'u64, brPmc, vec3(10.0, 0.0, 0.0))
    let me = ally(1'u64, 0'u64, brScav, zeroVec())
    let v = squadViewFor(me, mates, mates.len, s, 0.0)
    check(r, "a PMC standing next to a scav is not its squadmate",
          v.memberCount == 1, $v.memberCount)

  block:
    # The group identity, when the binding took, beats proximity in both
    # directions.
    var mates: seq[Ally] = @[]
    mates.add ally(2'u64, 77'u64, brScav, vec3(300.0, 0.0, 0.0))
    mates.add ally(3'u64, 88'u64, brScav, vec3(4.0, 0.0, 0.0))
    let me = ally(1'u64, 77'u64, brScav, zeroVec())
    let v = squadViewFor(me, mates, mates.len, s, 0.0)
    check(r, "a real group beats proximity in both directions",
          v.memberCount == 2 and v.nearestMateDistance > 200.0,
          $v.memberCount & "/" & $v.nearestMateDistance)

  block:
    # The leader is the highest rank, and stable.
    var mates: seq[Ally] = @[]
    mates.add ally(2'u64, 0'u64, brBoss, vec3(10.0, 0.0, 0.0))
    mates.add ally(3'u64, 0'u64, brFollower, vec3(12.0, 0.0, 0.0))
    let me = ally(1'u64, 0'u64, brFollower, zeroVec())
    let v = squadViewFor(me, mates, mates.len, s, 0.0)
    check(r, "a follower defers to the boss standing next to it",
          (not v.isLeader) and near(v.leaderDistance, 10.0, 0.01),
          $v.isLeader & "/" & $v.leaderDistance)

  block:
    # A hurt mate in a fight is a call for help; a hurt mate at peace is not.
    var mates: seq[Ally] = @[]
    var hurt = ally(2'u64, 0'u64, brScav, vec3(10.0, 0.0, 0.0))
    hurt.health = 0.2
    mates.add hurt
    let me = ally(1'u64, 0'u64, brScav, zeroVec())
    let quiet = squadViewFor(me, mates, mates.len, s, 0.0)
    var fighting = mates[0]
    fighting.inCombat = true
    mates[0] = fighting
    let loud = squadViewFor(me, mates, mates.len, s, 0.0)
    check(r, "a hurt mate in a fight is a call for help and one at peace is not",
          (not quiet.mateNeedsHelp) and loud.mateNeedsHelp,
          $quiet.mateNeedsHelp & "/" & $loud.mateNeedsHelp)

  block:
    # A dead bot in the table is nobody's squadmate.
    var mates: seq[Ally] = @[]
    var dead = ally(2'u64, 0'u64, brScav, vec3(5.0, 0.0, 0.0))
    dead.alive = false
    mates.add dead
    let me = ally(1'u64, 0'u64, brScav, zeroVec())
    let v = squadViewFor(me, mates, mates.len, s, 0.0)
    check(r, "a corpse is not a squadmate", v.memberCount == 1,
          $v.memberCount)

proc perceptionChecks(r: var TestReport; s: Settings) =
  block:
    var t = newEnemyTable()
    var r1 = newRng(11'u64)
    observe(t, observationOf(1'u64, vec3(10.0, 0.0, 0.0), true, false, 10.0),
            zeroVec(), vec3(1.0, 0.0, 0.0), s, 0.0, 0.1, r1)
    var o = observationOf(1'u64, vec3(25.0, 0.0, 0.0), false, true, 25.0)
    o.heard = Heard(audible: true, position: vec3(25.0, 0.0, 0.0),
                    loudness: 0.5, distance: 25.0)
    observe(t, o, zeroVec(), vec3(1.0, 0.0, 0.0), s, 1.0, 1.0, r1)
    let e = t.items[0]
    check(r, "a heard enemy updates the last known place",
          near(e.position.x, 25.0, 0.001), $e.position.x)
    check(r, "a heard enemy is not visible", not e.visible, $e.visible)
    check(r, "the true position is not updated by hearing",
          near(e.realPosition.x, 10.0, 0.001), $e.realPosition.x)

  block:
    var t = newEnemyTable()
    var r1 = newRng(13'u64)
    var s3 = defaultSettings()
    s3.forgetEnemySeconds = 5.0
    observe(t, observationOf(1'u64, vec3(10.0, 0.0, 0.0), true, false, 10.0),
            zeroVec(), vec3(1.0, 0.0, 0.0), s3, 0.0, 0.1, r1)
    var i = 0
    while i < 10:
      observe(t, observationOf(1'u64, vec3(10.0, 0.0, 0.0), false, false, 10.0),
              zeroVec(), vec3(1.0, 0.0, 0.0), s3, float(i) + 1.0, 1.0, r1)
      inc i
    forget(t, s3)
    check(r, "an enemy neither seen nor heard is forgotten",
          t.items.len == 0, $t.items.len)

  block:
    # The velocity estimate, which the search's push-past phase reads.
    var t = newEnemyTable()
    var r1 = newRng(17'u64)
    observe(t, observationOf(1'u64, vec3(10.0, 0.0, 0.0), true, false, 10.0),
            zeroVec(), vec3(1.0, 0.0, 0.0), s, 0.0, 0.1, r1)
    observe(t, observationOf(1'u64, vec3(10.5, 0.0, 0.0), true, false, 10.0),
            zeroVec(), vec3(1.0, 0.0, 0.0), s, 0.1, 0.1, r1)
    check(r, "an enemy's velocity is estimated from consecutive sightings",
          near(t.items[0].velocity.x, 5.0, 0.1), $t.items[0].velocity.x)

  block:
    # Two enemies, and the one that matters wins.
    var t = newEnemyTable()
    var r1 = newRng(19'u64)
    observe(t, observationOf(1'u64, vec3(80.0, 0.0, 0.0), true, false, 80.0),
            zeroVec(), vec3(1.0, 0.0, 0.0), s, 0.0, 0.1, r1)
    var o2 = observationOf(2'u64, vec3(12.0, 0.0, 0.0), true, false, 12.0)
    o2.firedAtUsThisTick = true
    observe(t, o2, zeroVec(), vec3(1.0, 0.0, 0.0), s, 0.0, 0.1, r1)
    let pick = choosePrimary(t, s)
    check(r, "the enemy shooting at us outranks the one that is not",
          pick >= 0 and t.items[pick].key == 2'u64,
          $pick)

proc searchChecks(r: var TestReport; s: Settings) =
  block:
    var st = newSearch()
    begin(st, zeroVec(), vec3(20.0, 0.0, 0.0), vec3(1.0, 0.0, 0.0), 0.0)
    check(r, "a search begins by moving to the last known place",
          st.phase == spMoveToLastKnown, phaseName(st.phase))
    advance(st, vec3(19.0, 0.0, 0.0), s, 1.0)
    check(r, "arriving switches the search to looking around",
          st.phase == spLookAround, phaseName(st.phase))
    advance(st, vec3(19.0, 0.0, 0.0), s, 4.0)
    check(r, "the search then pushes past the point",
          st.phase == spAdvancePast, phaseName(st.phase))
    advance(st, vec3(19.0, 0.0, 0.0), s, 200.0)
    check(r, "a search that runs out of time gives up",
          st.phase == spGiveUp, phaseName(st.phase))

  block:
    # Every phase in order, and the wide sweep is reached rather than skipped.
    var st = newSearch()
    begin(st, zeroVec(), vec3(20.0, 0.0, 0.0), vec3(1.0, 0.0, 0.0), 0.0,
          24.0, 1.0)
    var seen = 0
    var t = 1.0
    var guard = 0
    while guard < 400 and st.phase != spGiveUp:
      # Through a local: `advance` takes the state mutably and the position
      # immutably, and handing it `st.target` directly aliases the two.
      let here = st.target
      advance(st, here, s, t)
      if st.phase == spSweepWide:
        seen = 1
      t = t + 0.5
      inc guard
    check(r, "a search reaches the wide sweep before giving up", seen == 1,
          phaseName(st.phase))

  block:
    # A wider uncertainty pushes further past the point. This is what makes a
    # search of a thirty-second-old contact look different from a three-second
    # one, and it was a fixed twelve metres before.
    var narrow = newSearch()
    begin(narrow, zeroVec(), vec3(20.0, 0.0, 0.0), vec3(1.0, 0.0, 0.0), 0.0,
          6.0, 1.0)
    narrow.phase = spAdvancePast
    let tn = targetFor(narrow, zeroVec())
    var wide = newSearch()
    begin(wide, zeroVec(), vec3(20.0, 0.0, 0.0), vec3(1.0, 0.0, 0.0), 0.0,
          40.0, 1.0)
    wide.phase = spAdvancePast
    let tw = targetFor(wide, zeroVec())
    check(r, "an older contact is searched over a wider area",
          tw.x > tn.x + 5.0, $tn.x & " vs " & $tw.x)

  block:
    # A bot that is not getting closer moves the search on rather than pushing
    # into the geometry that stopped it.
    var st = newSearch()
    begin(st, zeroVec(), vec3(40.0, 0.0, 0.0), zeroVec(), 0.0)
    # Six seconds in and the bot has moved twenty centimetres: it is not
    # searching, it is stuck on geometry, and the honest response is to move
    # the search on rather than keep asking the navmesh for the same path.
    advance(st, vec3(0.2, 0.0, 0.0), s, 6.0)
    check(r, "a stalled search advances rather than pushing into a wall",
          st.phase != spMoveToLastKnown, phaseName(st.phase))

proc coverChecks(r: var TestReport; s: Settings) =
  block:
    var c = newCoverSet()
    c.points.add CoverPoint(position: vec3(5.0, 0.0, 0.0), height: 1.8,
                            blocksEnemy: false, lastCheck: 0.0,
                            distanceToBot: 5.0, distanceToEnemy: 40.0,
                            score: 0.0, pathFailures: 0)
    c.points.add CoverPoint(position: vec3(8.0, 0.0, 0.0), height: 1.0,
                            blocksEnemy: true, lastCheck: 0.0,
                            distanceToBot: 8.0, distanceToEnemy: 40.0,
                            score: 0.0, pathFailures: 0)
    discard choose(c, zeroVec(), vec3(45.0, 0.0, 0.0), s, 0.0, false)
    check(r, "soft cover that blocks beats hard cover that does not",
          c.chosen == 1, $c.chosen)

  block:
    var c = newCoverSet()
    c.points.add CoverPoint(position: vec3(5.0, 0.0, 0.0), height: 1.8,
                            blocksEnemy: true, lastCheck: 0.0,
                            distanceToBot: 5.0, distanceToEnemy: 40.0,
                            score: 0.0, pathFailures: 0)
    markPathFailure(c, 0)
    markPathFailure(c, 0)
    markPathFailure(c, 0)
    prune(c, s)
    check(r, "cover the navmesh will not reach is dropped",
          c.points.len == 0, $c.points.len)

  block:
    let p = CoverPoint(position: vec3(1.0, 0.0, 0.0), height: 1.8,
                       blocksEnemy: true, lastCheck: 0.0, distanceToBot: 1.0,
                       distanceToEnemy: 2.0, score: 0.0, pathFailures: 0)
    check(r, "a cover point on top of the enemy is not cover",
          not usable(p, s), "usable")

# ---------------------------------------------------------------------------
# The cover sampler
# ---------------------------------------------------------------------------
#
# The sampler is the newest thing in `core/` and it is the piece whose failure
# mode is hardest to see in a raid, so it gets the most synthetic geometry.
#
# The world below is made of pillars. A ray is blocked when the segment from
# its origin to `origin + direction * maxDistance` passes within `radius` of a
# pillar's axis -- an infinite vertical cylinder whose `top` says which rays it
# is tall enough to stop, so a candidate can be made hard cover or soft cover
# on demand. That is enough to answer every question below and it is the whole
# model: nothing here is trying to be a physics engine, it is trying to be a
# set of known answers.

type
  Pillar = object
    at: Vec3
    radius: float
    ## How high this pillar reaches. A pillar at or above `ProbeStandHeight`
    ## stops both rays and is hard cover; one that stops below it stops the
    ## chest ray only and is soft.
    top: float

func segmentNearAxis(o, d: Vec3; maxd: float; p: Pillar): bool =
  ## Whether a segment passes within `p.radius` of a vertical axis.
  ##
  ## Two dimensions on purpose: the pillar is a cylinder, so its height decides
  ## *which* rays it stops rather than whether the ground track meets it.
  ## Closest approach of a point to a segment, clamped to the segment -- the
  ## textbook form, written out because `core/vec.nim` has no line primitives
  ## and one test is not a reason to add one.
  let a = flat(o)
  let b = flat(o + d * maxd)
  let ab = b - a
  let denom = sqrMagnitude(ab)
  var t = 0.0
  if denom > 0.000001:
    t = clampf(dot(flat(p.at) - a, ab) / denom, 0.0, 1.0)
  let closest = a + ab * t
  result = flatDistance(closest, p.at) <= p.radius

func rayBlocked(r: ProbeRay; height: float; pillars: openArray[Pillar]): bool =
  result = false
  if r.maxDistance <= 0.0:
    return
  for i in 0 ..< pillars.len:
    if pillars[i].top >= height and
       segmentNearAxis(r.origin, r.direction, r.maxDistance, pillars[i]):
      return true

proc answerFrom(p: ProbePlan; pillars: openArray[Pillar]): ProbeAnswers =
  ## Play the sampler's part: what `client/coverprobe.nim` would have written
  ## back if the engine had answered out of this synthetic world.
  result = emptyAnswers()
  var i = 0
  while i < p.count:
    var a = zeroAnswer()
    a.chestBlocked = rayBlocked(p.candidates[i].chest, ChestHeight, pillars)
    if a.chestBlocked:
      a.standBlocked = rayBlocked(p.candidates[i].stand, ProbeStandHeight,
                                  pillars)
    a.standable = true
    result[i] = a
    inc i

proc probeChecks(r: var TestReport; s: Settings) =
  let noPillars: array[1, Pillar] = [
    Pillar(at: vec3(0.0, 0.0, 500.0), radius: 0.1, top: 0.0)]

  block:
    # The ring surrounds the bot, and every ray stops short of the enemy. Both
    # are properties of the plan alone and neither needs a world.
    let p = planProbe(zeroVec(), vec3(40.0, 0.0, 0.0), s, 0)
    var allWithin = p.valid and p.count == ProbeCandidates
    var behind = 0
    var reachesEnemy = false
    var i = 0
    while i < p.count:
      let c = p.candidates[i]
      let d = flatDistance(zeroVec(), c.position)
      if d > FarRadius + 0.001 or d < NearRadius - 0.001:
        allWithin = false
      if c.position.x < -0.001:
        inc behind
      # The chest ray must not be able to touch the enemy itself, or every
      # candidate on the map reports as cover.
      if c.chest.maxDistance >= distance(c.chest.origin,
                                         vec3(40.0, ChestHeight, 0.0)):
        reachesEnemy = true
      inc i
    check(r, "a cover plan rings the bot without reaching the enemy",
          allWithin and behind >= 2 and not reachesEnemy,
          $behind & " behind, reaches=" & $reachesEnemy)

  block:
    # No enemy, no bearing, no plan. A sample with nothing to hide from is not
    # a refusal, it is not a question.
    let p = planProbe(zeroVec(), zeroVec(), s, 0)
    check(r, "a plan with no bearing to an enemy is not made", not p.valid,
          "valid")

  block:
    # An open field: every ray reaches, nothing is cover, the set stays empty.
    # This is also the shape of a build where the raycast refused, and the
    # assertion is that it produces no points rather than bad ones.
    var c = newCoverSet()
    let p = planProbe(zeroVec(), vec3(40.0, 0.0, 0.0), s, 0)
    let a = answerFrom(p, noPillars)
    discard ingest(c, p, a, s, 10.0)
    check(r, "an open field yields no cover points", c.points.len == 0,
          $c.points.len)

  block:
    # One full-height pillar between a candidate and the enemy: both rays stop,
    # so the point is hard cover.
    var c = newCoverSet()
    let p = planProbe(zeroVec(), vec3(40.0, 0.0, 0.0), s, 0)
    # Candidate 4 of an unrotated ring is directly away from the enemy, so a
    # pillar just enemy-side of it breaks that candidate's line.
    let behind = p.candidates[4].position
    let wall: array[1, Pillar] = [
      Pillar(at: vec3(behind.x + 1.5, 0.0, behind.z), radius: 1.2, top: 3.0)]
    let a = answerFrom(p, wall)
    discard ingest(c, p, a, s, 10.0)
    var hard = 0
    for i in 0 ..< c.points.len:
      if isHardCover(c.points[i]): inc hard
    check(r, "a full-height obstruction becomes hard cover",
          c.points.len >= 1 and hard >= 1,
          $c.points.len & " points, " & $hard & " hard")

  block:
    # The same pillar, waist high. The chest ray stops and the stand ray does
    # not, which is exactly SAIN's soft cover -- and telling those two apart is
    # the only reason the second ray exists.
    var c = newCoverSet()
    let p = planProbe(zeroVec(), vec3(40.0, 0.0, 0.0), s, 0)
    let behind = p.candidates[4].position
    let low: array[1, Pillar] = [
      Pillar(at: vec3(behind.x + 1.5, 0.0, behind.z), radius: 1.2, top: 1.2)]
    let a = answerFrom(p, low)
    discard ingest(c, p, a, s, 10.0)
    var soft = 0
    var hard = 0
    for i in 0 ..< c.points.len:
      if isSoftCover(c.points[i]): inc soft
      if isHardCover(c.points[i]): inc hard
    check(r, "a waist-high obstruction becomes soft cover, not hard",
          soft >= 1 and hard == 0, $soft & " soft, " & $hard & " hard")

  block:
    # An overhang: the stand ray is stopped and the chest ray is not. Reading
    # that as cover would send bots to stand under gantries, so it is not.
    var a = zeroAnswer()
    a.chestBlocked = false
    a.standBlocked = true
    check(r, "an obstruction above head height is not cover",
          heightFrom(a) <= 0.0, $heightFrom(a))

  block:
    # The navmesh filter. A candidate the navmesh refuses is dropped whatever
    # the rays said. (The other direction is asserted by every check above: a
    # build where the navmesh binding refused reports every candidate
    # standable, which is what `answerFrom` does, and nothing is rejected.)
    var c = newCoverSet()
    let p = planProbe(zeroVec(), vec3(40.0, 0.0, 0.0), s, 0)
    let behind = p.candidates[4].position
    let wall: array[1, Pillar] = [
      Pillar(at: vec3(behind.x + 1.5, 0.0, behind.z), radius: 1.2, top: 3.0)]
    var a = answerFrom(p, wall)
    var i = 0
    while i < ProbeCandidates:
      a[i].standable = false
      inc i
    discard ingest(c, p, a, s, 10.0)
    check(r, "cover the navmesh will not stand on is never proposed",
          c.points.len == 0, $c.points.len)

  block:
    # A point nobody re-observes is forgotten, and the one the bot is using is
    # not -- forgetting that one mid-approach is how this could produce the
    # oscillation the merge exists to prevent.
    var c = newCoverSet()
    c.points.add CoverPoint(position: vec3(5.0, 0.0, 0.0), height: 1.8,
                            blocksEnemy: true, lastCheck: 0.0,
                            distanceToBot: 5.0, distanceToEnemy: 40.0,
                            score: 0.0, pathFailures: 0)
    c.points.add CoverPoint(position: vec3(-5.0, 0.0, 0.0), height: 1.8,
                            blocksEnemy: true, lastCheck: 0.0,
                            distanceToBot: 5.0, distanceToEnemy: 45.0,
                            score: 0.0, pathFailures: 0)
    c.chosen = 1
    expire(c, ForgetSeconds + 1.0, ForgetSeconds)
    check(r, "a stale cover point is forgotten and the held one is kept",
          c.points.len == 1 and c.chosen == 0 and c.points[0].position.x < 0.0,
          $c.points.len & " points, chosen " & $c.chosen)

  block:
    # Re-sampling the same corner over and over must not grow the set: every
    # candidate merges into the point that already stands for that place.
    var c = newCoverSet()
    let wall: array[1, Pillar] = [
      Pillar(at: vec3(-6.5, 0.0, 0.0), radius: 1.5, top: 3.0)]
    var t = 0.0
    var i = 0
    while i < 40:
      let p = planProbe(zeroVec(), vec3(40.0, 0.0, 0.0), s, i and 7)
      let a = answerFrom(p, wall)
      t = t + 0.5
      discard ingest(c, p, a, s, t)
      inc i
    check(r, "re-sampling the same geometry does not grow the point set",
          c.points.len > 0 and c.points.len <= MaxCoverPoints,
          $c.points.len & " points after 40 samples")

  block:
    # **The flicker check, and the reason the sampler is in `core/` at all.**
    #
    # Two pillars of equal quality on opposite sides of the bot, sampled every
    # tick while the bot jitters by a few centimetres and the ring rotates.
    # Every sample proposes eight *new* positions, none of them exactly a
    # position from the sample before, so an ingest that appended rather than
    # merged would hand `choose` a fresh set each time and the bot would spend
    # the fight running between two near-equal points in the open. That failure
    # is invisible in a raid -- the bot looks twitchy and nobody can say why --
    # and it is trivial to see here.
    #
    # The count is of *material* changes: the chosen point moving further than
    # the merge distance. Moving within it is the same piece of the world.
    let pair: array[2, Pillar] = [
      Pillar(at: vec3(0.0, 0.0, 6.5), radius: 1.5, top: 3.0),
      Pillar(at: vec3(0.0, 0.0, -6.5), radius: 1.5, top: 3.0)]
    var c = newCoverSet()
    var rr = newRng(77'u64)
    var last = zeroVec()
    var haveLast = false
    var changes = 0
    var t = 0.0
    var i = 0
    while i < 200:
      t = t + 0.1
      let me = vec3(rangeF(rr, -0.15, 0.15), 0.0, rangeF(rr, -0.15, 0.15))
      let p = planProbe(me, vec3(40.0, 0.0, 0.0), s, i and 7)
      let a = answerFrom(p, pair)
      discard ingest(c, p, a, s, t)
      if choose(c, me, vec3(40.0, 0.0, 0.0), s, t, false) and c.chosen >= 0:
        let at = c.points[c.chosen].position
        if haveLast and flatDistance(at, last) > MergeDistance:
          inc changes
        last = at
        haveLast = true
      inc i
    check(r, "a bot between two equal covers does not re-pick every tick",
          haveLast and changes <= 3,
          $changes & " material changes in 200 samples")

  block:
    # And the other half of the same question: when the world genuinely changes
    # -- the held cover stops blocking -- the bot must actually let go. A
    # hysteresis that never releases is the opposite failure and is just as
    # wrong, and a merge-in-place ingest is exactly the design that could have
    # produced it.
    let pair: array[2, Pillar] = [
      Pillar(at: vec3(0.0, 0.0, 6.5), radius: 1.5, top: 3.0),
      Pillar(at: vec3(0.0, 0.0, -6.5), radius: 1.5, top: 3.0)]
    let one: array[1, Pillar] = [
      Pillar(at: vec3(0.0, 0.0, -6.5), radius: 1.5, top: 3.0)]
    var c = newCoverSet()
    var t = 0.0
    var i = 0
    while i < 10:
      t = t + 0.1
      let p = planProbe(zeroVec(), vec3(40.0, 0.0, 0.0), s, 0)
      discard ingest(c, p, answerFrom(p, pair), s, t)
      discard choose(c, zeroVec(), vec3(40.0, 0.0, 0.0), s, t, false)
      inc i
    var held = zeroVec()
    if c.chosen >= 0: held = c.points[c.chosen].position
    # Well past the dwell, and now only one of the two pillars is there.
    i = 0
    while i < 10:
      t = t + s.shiftCoverResetTime
      let p = planProbe(zeroVec(), vec3(40.0, 0.0, 0.0), s, 0)
      discard ingest(c, p, answerFrom(p, one), s, t)
      discard choose(c, zeroVec(), vec3(40.0, 0.0, 0.0), s, t, false)
      inc i
    var now1 = zeroVec()
    if c.chosen >= 0: now1 = c.points[c.chosen].position
    check(r, "cover that stopped blocking is given up",
          c.chosen >= 0 and held.z > 0.0 and now1.z < 0.0,
          "held z=" & $held.z & ", now z=" & $now1.z)

proc benchSampler*(iterations: int): int =
  ## Plan a sample and fold its answers in, `iterations` times, returning a
  ## checksum so the optimiser cannot delete the work.
  ##
  ## This is the *pure* half of the cover sensor, which is the half that runs
  ## on the host's thread and is therefore the half that has to sit inside this
  ## mod's frame budget. The engine half is what it is and is measured on the
  ## game's own clock in `client/coverprobe.nim`; there is no honest way to
  ## time a raycast against a runtime that does not have one.
  let s = defaultSettings()
  let pillars: array[2, Pillar] = [
    Pillar(at: vec3(0.0, 0.0, 6.5), radius: 1.5, top: 3.0),
    Pillar(at: vec3(0.0, 0.0, -6.5), radius: 1.5, top: 3.0)]
  var c = newCoverSet()
  var sum = 0
  var t = 0.0
  var i = 0
  while i < iterations:
    t = t + 0.1
    let p = planProbe(vec3(float(i mod 3), 0.0, 0.0), vec3(40.0, 0.0, 0.0), s,
                      i and 7)
    let a = answerFrom(p, pillars)
    sum = sum + ingest(c, p, a, s, t)
    inc i
  result = sum

proc flickerChecks(r: var TestReport; s: Settings) =
  ## The checks a live test cannot do.
  ##
  ## Four hundred decisions each, sweeping an input across a threshold with
  ## noise on it. The bound is generous -- the claim is not "this exact number"
  ## but "not one change per tick", which is what a cascade with no hysteresis
  ## produces and which is invisible from inside a raid.
  block:
    let n = sweepChanges(s, 0.15, 0.85, 400, 0)
    check(r, "sweeping health across the retreat threshold does not oscillate",
          n < 40, $n & " changes in 400 ticks")

  block:
    let n = sweepChanges(s, 4.0, 30.0, 400, 1)
    check(r, "sweeping distance across the dogfight threshold does not oscillate",
          n < 40, $n & " changes in 400 ticks")

  block:
    let n = sweepChanges(s, 0.0, 1.0, 400, 2)
    check(r, "sweeping suppression across both thresholds does not oscillate",
          n < 40, $n & " changes in 400 ticks")

  block:
    # A steady state produces no changes at all after the first.
    var b = baseView()
    b.enemy = visibleEnemyAt(30.0)
    b.me.inCoverStatus = csInCover
    var ctx = newContext(0.5)
    var last = cdNone
    var changes = 0
    var i = 0
    while i < 200:
      b.timeNow = b.timeNow + 0.1
      let d = decide(ctx, b, s)
      if d.combat != last:
        inc changes
        last = d.combat
      inc i
    check(r, "a bot whose situation does not change does not change its mind",
          changes <= 2, $changes)

  block:
    # And the dogfight latch specifically: exactly at the start threshold,
    # jittering by centimetres.
    var b = baseView()
    b.enemy = visibleEnemyAt(s.dogFightPathStart)
    var ctx = newContext(0.5)
    var r1 = newRng(23'u64)
    var last = cdNone
    var changes = 0
    var i = 0
    while i < 200:
      let d0 = s.dogFightPathStart + rangeF(r1, -0.1, 0.1)
      b.enemy.distance = d0
      b.enemy.pathDistance = d0
      b.timeNow = b.timeNow + 0.1
      let d = decide(ctx, b, s)
      if d.combat != last:
        inc changes
        last = d.combat
      inc i
    check(r, "a bot sitting exactly on the dogfight boundary does not flicker",
          changes <= 3, $changes)

proc accepts(r: var TestReport; name: string; shape: DriveShape;
             params: openArray[string]; ret: string) =
  var w = ""
  check(r, name, checkDrive(shape, params, ret, w), "refused: " & w)

proc refuses(r: var TestReport; name: string; shape: DriveShape;
             params: openArray[string]; ret: string) =
  ## A refusal is only a pass when it *carries a reason*. A gate that returned
  ## false with an empty `why` would satisfy every "does it refuse?" assertion
  ## ever written and would be exactly the silent failure this mod is arranged
  ## against, so the reason is half of what is asserted here.
  var w = ""
  let ok = checkDrive(shape, params, ret, w)
  check(r, name, (not ok) and w.len > 0,
        (if ok: "accepted" else: "refused with no reason"))

proc driveSignatureChecks(r: var TestReport) =
  ## The declared-signature gate, both branches, with no runtime involved.
  ##
  ## This is the same kind of check as the Win64 size rule in `sain.nim` and it
  ## is here for the same reason: the predicate decides whether a driving call
  ## is made at all, a wrong answer in either direction is silent, and it can
  ## be proved on a laptop while the thing it guards can only be proved in a
  ## raid.
  ##
  ## **Both branches, and the negative one is the point.** A gate that refuses
  ## everything passes every "does it refuse?" test ever written, and a gate
  ## that accepts everything passes every "does the real signature work?" test.
  ## So each shape is asserted to accept exactly the signature this mod calls
  ## it with and to refuse each way it could plausibly be wrong, and every
  ## refusal is asserted to carry a non-empty reason -- a refusal with no
  ## reason is the failure mode the whole binding layer is written against.
  # --- the shape a decision drives a bot with: (Vector3, ...).
  let v3 = "UnityEngine.Vector3"
  accepts(r, "sig: GoToPoint(Vector3) is accepted",
          dsVectorFirst, [v3], "System.Void")
  accepts(r, "sig: GoToPoint(Vector3, bool) is accepted -- the long " &
          "overloads are what argcAlts walks to",
          dsVectorFirst, [v3, "System.Boolean"], "System.Void")
  accepts(r, "sig: GoToPoint(Vector3, float, bool, int) is accepted",
          dsVectorFirst,
          [v3, "System.Single", "System.Boolean", "System.Int32"],
          "System.Void")
  accepts(r, "sig: a struct return does not refuse a driving call -- every " &
          "call site discards it and the reflective path boxes it correctly",
          dsVectorFirst, [v3], "EFT.SomeStruct")

  # The overload trap this gate exists for: same arity, different first
  # parameter. `il2cpp_class_get_method_from_name` hands one of these back and
  # calling it with the address of a Vector3 answers plausibly rather than
  # failing.
  refuses(r, "sig: GoToPoint(float) is refused -- the arity matches and the " &
          "type does not", dsVectorFirst, ["System.Single"], "System.Void")
  refuses(r, "sig: GoToPoint(Object) is refused",
          dsVectorFirst, ["System.Object"], "System.Void")
  refuses(r, "sig: GoToPoint() is refused -- nothing to put a destination in",
          dsVectorFirst, [], "System.Void")
  refuses(r, "sig: a second Vector3 is refused -- one buffer per call",
          dsVectorFirst, [v3, v3], "System.Void")
  refuses(r, "sig: a trailing double is refused -- not a slot the shaped " &
          "trampolines carry", dsVectorFirst, [v3, "System.Double"],
          "System.Void")
  refuses(r, "sig: a by-reference trailing argument is refused -- the callee " &
          "would write into this mod's own stack frame",
          dsVectorFirst, [v3, "UnityEngine.RaycastHit&"], "System.Void")
  refuses(r, "sig: a Quaternion trailing argument is refused",
          dsVectorFirst, [v3, "UnityEngine.Quaternion"], "System.Void")

  # --- Sprint(bool). This one was *stated* rather than checked until now:
  # `lazyAs` put a bool in a general-purpose register on the strength of this
  # mod's own word for the signature, and `resolveOn` skips the runtime's
  # declared types entirely when the caller supplies kinds.
  accepts(r, "sig: Sprint(bool) is accepted",
          dsOneBool, ["System.Boolean"], "System.Void")
  refuses(r, "sig: Sprint(float) is refused -- a bool travels in a GP " &
          "register and a float is read out of XMM",
          dsOneBool, ["System.Single"], "System.Void")
  refuses(r, "sig: Sprint() is refused", dsOneBool, [], "System.Void")
  refuses(r, "sig: Sprint(bool, float) is refused",
          dsOneBool, ["System.Boolean", "System.Single"], "System.Void")

  # --- the no-argument calls: Shoot, Stop, TryReload and the three
  # self-actions. `callVoidOn` hands over a null argument array, so "found at
  # arity zero" has to mean "declares no parameters".
  accepts(r, "sig: Shoot() is accepted", dsNoArgs, [], "System.Void")
  accepts(r, "sig: TryReload() returning bool is accepted -- the return is " &
          "discarded and is deliberately not gated",
          dsNoArgs, [], "System.Boolean")
  refuses(r, "sig: Shoot(bool) is refused -- callVoidOn passes no arguments",
          dsNoArgs, ["System.Boolean"], "System.Void")
  refuses(r, "sig: TryApply(Item) is refused",
          dsNoArgs, ["EFT.InventoryLogic.Item"], "System.Void")

  # --- every shape says what a bot does when it refuses. A refusal a player
  # cannot act on may as well be silence, and this is the only mechanical way
  # to assert that rule holds for all three.
  check(r, "sig: every shape carries a consequence a player could act on",
        consequenceOf(dsNoArgs).len > 20 and
        consequenceOf(dsVectorFirst).len > 20 and
        consequenceOf(dsOneBool).len > 20,
        "a consequence string is missing")

proc objectiveChecks(r: var TestReport) =
  ## The squad-objective properties, from `core/objective.selfCheckObjective`.
  ##
  ## Written there rather than here because the assigner's tables are module
  ## state and a check that cannot see them cannot assert on the finished
  ## state -- only on its own inputs, which under CLAUDE.md 9b is not a check.
  ## Each failure it reports becomes one failed line here, and a run with none
  ## reports the single property it established rather than nothing at all.
  var problems: seq[string] = @[]
  let ok = selfCheckObjective(problems)
  var i = 0
  while i < problems.len:
    check(r, "objective/" & $i, false, problems[i])
    inc i
  check(r, "objective: one squad shares one objective, two squads do not " &
        "collapse onto one, the origin is refused, and oneWriterCheck FAILS " &
        "when the retired writer fires", ok, "see the lines above")

proc run*(): TestReport =
  ## Everything, in one pass. Roughly ordered from the reflexes outward.
  var r = TestReport(lines: @[], passed: 0, failed: 0)
  let s = defaultSettings()
  ladderChecks(r, s)
  extractChecks(r, s)
  flankChecks(r, s)
  hearingChecks(r, s)
  visionChecks(r, s)
  suppressionChecks(r, s)
  squadChecks(r, s)
  perceptionChecks(r, s)
  searchChecks(r, s)
  coverChecks(r, s)
  probeChecks(r, s)
  flickerChecks(r, s)
  driveSignatureChecks(r)
  objectiveChecks(r)
  result = r
