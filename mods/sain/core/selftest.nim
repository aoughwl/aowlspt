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

import vec
import types
import settings
import decide
import enemy
import search
import cover

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
    suppressionLevel: 0.0, isSprinting: false, position: zeroVec(),
    lookDirection: vec3(1.0, 0.0, 0.0))
  var sq = SquadView(
    memberCount: 1, aliveCount: 1, isLeader: true, leaderAlive: true,
    leaderDistance: 0.0, nearestMateDistance: 9999.0, mateNeedsHelp: false,
    mateInCombat: false, squadSeesEnemy: false, memberTookDamageRecently: false)
  BotView(id: "test", role: brPmc, personality: pNormal, difficulty: 0.5,
          timeNow: 100.0, me: me, enemy: emptyEnemy(), enemyCount: 0,
          squad: sq,
          grenade: GrenadeThreat(active: false, position: zeroVec(),
                                 distance: 999.0, secondsToDetonation: 0.0),
          lastSound: skNone, lastSoundPosition: zeroVec(),
          lastSoundDistance: 0.0, timeSinceLastSound: 999.0,
          hasSearchTarget: false, searchTarget: zeroVec(),
          extractRequested: false)

func visibleEnemyAt(d: float): EnemyView =
  var e = emptyEnemy()
  e.id = "enemy"
  e.valid = true
  e.alive = true
  e.isPlayer = true
  e.position = vec3(d, 0.0, 0.0)
  e.realPosition = e.position
  e.visible = true
  e.canShoot = true
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

proc run*(): TestReport =
  ## Everything, in one pass. Roughly ordered from the reflexes outward.
  var r = TestReport(lines: @[], passed: 0, failed: 0)
  let s = defaultSettings()

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

  block:
    # Nothing to fight and nothing to search: idle, not a fabricated action.
    var b = baseView()
    var ctx = newContext(0.5)
    let d = decide(ctx, b, s)
    check(r, "no enemy and no lead is None", d.combat == cdNone,
          decisionName(d.combat))

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

  block:
    var b = baseView()
    b.enemy = visibleEnemyAt(40.0)
    b.me.healthNormalized = 0.45
    var ctx = newContext(0.5)
    let d = decide(ctx, b, s)
    check(r, "a hurt bot in the open retreats", d.combat == cdRetreat,
          decisionName(d.combat))

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
    # Empty magazine, with ammo left: reload regardless of who is looking.
    var b = baseView()
    b.enemy = visibleEnemyAt(40.0)
    b.me.ammoInMagazine = 0
    var ctx = newContext(0.5)
    let d = decide(ctx, b, s)
    check(r, "an empty magazine reloads even under fire",
          d.self == saReload, selfActionName(d.self))

  block:
    # A half-full magazine does not, while an enemy is visible.
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
    b.me.healthNormalized = 0.56      ## just back above the threshold
    let second = decide(ctx, b, s)
    check(r, "a retreat is not abandoned the tick health ticks back up",
          second.combat == first.combat, decisionName(second.combat))

  block:
    # ...but a grenade still interrupts it.
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
    b.enemy = visibleEnemyAt(90.0)
    b.enemy.visible = false
    b.enemy.canShoot = false
    # A bot whose own enemy was seen in the last ten seconds takes no orders --
    # SAIN's own bail-out, so the scenario has to be past it.
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
    # Perception: hearing an enemy moves the last known place but not the truth.
    var t = newEnemyTable()
    let s2 = defaultSettings()
    observe(t, Observation(id: "e", alive: true, isPlayer: true,
                           position: vec3(10.0, 0.0, 0.0), sawThisTick: true,
                           heardThisTick: false, firedAtUsThisTick: false,
                           lookingAtUsThisTick: false, pathDistance: 10.0),
            zeroVec(), vec3(1.0, 0.0, 0.0), s2, 0.0, 0.1)
    observe(t, Observation(id: "e", alive: true, isPlayer: true,
                           position: vec3(25.0, 0.0, 0.0), sawThisTick: false,
                           heardThisTick: true, firedAtUsThisTick: false,
                           lookingAtUsThisTick: false, pathDistance: 25.0),
            zeroVec(), vec3(1.0, 0.0, 0.0), s2, 1.0, 1.0)
    let e = t.items[0]
    check(r, "a heard enemy updates the last known place",
          e.position.x == 25.0, $e.position.x)
    check(r, "a heard enemy is not visible", not e.visible,
          $e.visible)

  block:
    # Threat decays to nothing and the enemy is forgotten.
    var t = newEnemyTable()
    var s3 = defaultSettings()
    s3.forgetEnemySeconds = 5.0
    observe(t, Observation(id: "e", alive: true, isPlayer: false,
                           position: vec3(10.0, 0.0, 0.0), sawThisTick: true,
                           heardThisTick: false, firedAtUsThisTick: false,
                           lookingAtUsThisTick: false, pathDistance: 10.0),
            zeroVec(), vec3(1.0, 0.0, 0.0), s3, 0.0, 0.1)
    var i = 0
    while i < 10:
      observe(t, Observation(id: "e", alive: true, isPlayer: false,
                             position: vec3(10.0, 0.0, 0.0),
                             sawThisTick: false, heardThisTick: false,
                             firedAtUsThisTick: false,
                             lookingAtUsThisTick: false, pathDistance: 10.0),
              zeroVec(), vec3(1.0, 0.0, 0.0), s3, float(i) + 1.0, 1.0)
      inc i
    forget(t, s3)
    check(r, "an enemy neither seen nor heard is forgotten",
          t.items.len == 0, $t.items.len)

  block:
    # Search advances through its phases and eventually gives up.
    var st = newSearch()
    let s4 = defaultSettings()
    begin(st, zeroVec(), vec3(20.0, 0.0, 0.0), vec3(1.0, 0.0, 0.0), 0.0)
    check(r, "a search begins by moving to the last known place",
          st.phase == spMoveToLastKnown, phaseName(st.phase))
    advance(st, vec3(19.0, 0.0, 0.0), s4, 1.0)
    check(r, "arriving switches the search to looking around",
          st.phase == spLookAround, phaseName(st.phase))
    advance(st, vec3(19.0, 0.0, 0.0), s4, 4.0)
    check(r, "the search then pushes past the point",
          st.phase == spAdvancePast, phaseName(st.phase))
    advance(st, vec3(19.0, 0.0, 0.0), s4, 200.0)
    check(r, "a search that runs out of time gives up",
          st.phase == spGiveUp, phaseName(st.phase))

  block:
    # Cover: a point that does not break line of sight loses to one that does.
    var c = newCoverSet()
    let s5 = defaultSettings()
    c.points.add CoverPoint(position: vec3(5.0, 0.0, 0.0), height: 1.8,
                            blocksEnemy: false, lastCheck: 0.0,
                            distanceToBot: 5.0, distanceToEnemy: 40.0,
                            score: 0.0, pathFailures: 0)
    c.points.add CoverPoint(position: vec3(8.0, 0.0, 0.0), height: 1.0,
                            blocksEnemy: true, lastCheck: 0.0,
                            distanceToBot: 8.0, distanceToEnemy: 40.0,
                            score: 0.0, pathFailures: 0)
    discard choose(c, zeroVec(), vec3(45.0, 0.0, 0.0), s5, 0.0, false)
    check(r, "soft cover that blocks beats hard cover that does not",
          c.chosen == 1, $c.chosen)

  block:
    # A point the bot could never path to is dropped rather than retried.
    var c = newCoverSet()
    let s6 = defaultSettings()
    c.points.add CoverPoint(position: vec3(5.0, 0.0, 0.0), height: 1.8,
                            blocksEnemy: true, lastCheck: 0.0,
                            distanceToBot: 5.0, distanceToEnemy: 40.0,
                            score: 0.0, pathFailures: 0)
    markPathFailure(c, 0)
    markPathFailure(c, 0)
    markPathFailure(c, 0)
    prune(c, s6)
    check(r, "cover the navmesh will not reach is dropped",
          c.points.len == 0, $c.points.len)

  block:
    # Cover closer to the enemy than the minimum is refused outright.
    let s7 = defaultSettings()
    let p = CoverPoint(position: vec3(1.0, 0.0, 0.0), height: 1.8,
                       blocksEnemy: true, lastCheck: 0.0, distanceToBot: 1.0,
                       distanceToEnemy: 2.0, score: 0.0, pathFailures: 0)
    check(r, "a cover point on top of the enemy is not cover",
          not usable(p, s7), "usable")

  result = r
