## The decision core: one arbiter, three outputs, no game calls.
##
## SAIN's `BotDecisionManager.getDecision()` is a **priority cascade, not a
## utility score**: it runs at 10 Hz, the first predicate that matches wins, and
## it emits all three outputs — `ECombatDecision`, `ESquadDecision`,
## `ESelfActionType` — at once. A separate BigBrain layer turns that triple into
## a behaviour object, and tears the object down whenever the triple changes.
##
## This module is the cascade. The order below is SAIN's own, and the order is
## the design: moving a check up or down changes the bot, so it is written as
## one readable ladder rather than spread over five classes.
##
##     1  no enemy                     -> all None (or search / freeze)
##     2  a self action is needed      -> (SeekCover, None, action)
##     3  no weapon, enemy in reach    -> MeleeAttack
##     4  dogfight is active           -> DogFight
##     5  already running to cover     -> SeekCover  (continuation)
##     6  the squad wants something    -> (None, squad, None)
##     7  the solo combat ladder       -> (combat, None, None)
##
## Everything reads only the `BotView` it was handed. That is what makes the
## scenario tests in `selftest.nim` possible, and it is the property that lets
## the whole thing move off the main thread later: there is nothing in here that
## has to be on it.
##
## ## Hysteresis
##
## The detail most easily lost in a port. SAIN hangs a timer off nearly every
## check — `_nextShootDistTargetTime`, `TimeForNewShift`, `ChangeDecisionTime`,
## and a `ToggleEvent` on every boolean — because a cascade evaluated fresh at
## 10 Hz oscillates at every boundary. A bot at exactly the retreat health
## flickers between `Retreat` and `StandAndShoot` five times a second and does
## neither.
##
## Rather than scatter the same mechanism through twenty checks, this port
## states it once: `decide` takes the previous decision and a hold time, and a
## decision in progress survives unless something *strictly more urgent* fires.
## The per-check enter/exit pairs SAIN needs (`DOGFIGHT_..._START` vs `..._END`)
## are still here where they carry real behaviour, not merely anti-flicker.

import vec
import types
import settings
import toggle

type
  DecideContext* = object
    ## Carried between ticks. The only mutable state the core owns.
    previous*: Decision
    lastChangeAt*: float
    holdGroundUntil*: float
    ## SAIN: `TimeForNewShift` / `ShiftResetTimer`.
    nextShiftAt*: Cooldown
    ## SAIN: `_nextShootDistTargetTime` / `_endShootDistTargetTime`.
    nextDistantShotAt*: Cooldown
    endDistantShotAt*: float
    ## SAIN: `TimeToUnfreeze`.
    unfreezeAt*: float
    ## SAIN's dogfight is a latched state with separate start and end
    ## thresholds, not a per-tick distance test. Latching it here is what stops
    ## a bot at exactly ten metres flipping in and out of a knife fight.
    dogFight*: Toggle
    ## SAIN: `RunningToCover`, which gates `ContinueMoveToCover`.
    runningToCover*: Toggle
    ## A per-bot jitter drawn once at spawn from the bot's id. SAIN rolls
    ## `Random(0.66, 1.33)` at each use; drawing once per bot costs nothing per
    ## tick and still keeps two bots off the same threshold on the same frame.
    jitter*: float

func newContext*(jitter: float): DecideContext =
  DecideContext(previous: emptyDecision(), lastChangeAt: 0.0,
                holdGroundUntil: 0.0, nextShiftAt: newCooldown(),
                nextDistantShotAt: newCooldown(), endDistantShotAt: 0.0,
                unfreezeAt: 0.0, dogFight: newToggle(false),
                runningToCover: newToggle(false), jitter: jitter)

# ---------------------------------------------------------------------------
# Urgency
# ---------------------------------------------------------------------------

func urgency*(d: CombatDecision): int =
  ## How badly a decision wants to interrupt whatever is running.
  ##
  ## This is the ordering the C# encodes implicitly, by the sequence of its
  ## `if` statements across four files. Making it a number lets the hold rule be
  ## stated once, in one place, instead of as a timer per check.
  case d
  of cdAvoidGrenade: 100
  of cdMeleeAttack: 90
  of cdDogFight: 85
  of cdRunAway: 80
  of cdRetreat: 70
  of cdSeekCover: 60
  of cdStandAndShoot: 55
  of cdThrowGrenade: 50
  of cdRushEnemy: 45
  of cdShiftCover: 40
  of cdCreepOnEnemy: 35
  of cdShootDistantEnemy: 30
  of cdHoldInCover: 25
  of cdMoveToEngage: 20
  of cdFreeze: 15
  of cdSearch: 10
  of cdNone: 0

func holdTimeFor*(d: CombatDecision; s: Settings): float =
  ## How long each decision is worth committing to.
  ##
  ## Reactive decisions get almost none — a grenade landing must be able to
  ## interrupt itself when a second one lands. Committed movement gets the most,
  ## because a bot that changes its mind halfway to cover dies in the open, and
  ## that specific failure is most of what "bad bot AI" looks like from the
  ## player's side.
  case d
  of cdAvoidGrenade: 0.2
  of cdSeekCover: 2.5
  of cdShiftCover: s.shiftCoverResetTime * 0.25
  of cdRetreat, cdRunAway: 3.0
  of cdRushEnemy, cdCreepOnEnemy: 2.0
  of cdSearch: 4.0
  of cdFreeze: 1.0
  of cdHoldInCover: 1.5
  of cdThrowGrenade: 1.0
  else: 0.5

func magazineRatio*(me: SelfView): float =
  if me.magazineSize > 0: float(me.ammoInMagazine) / float(me.magazineSize)
  else: 1.0

# ---------------------------------------------------------------------------
# Layer 1: self actions
# ---------------------------------------------------------------------------

func shallReload(b: BotView; s: Settings): bool =
  ## SAIN: `CheckReloadRatiosCanReload` plus `CheckReloadByAmmoRemaining`.
  ##
  ## The original walks every known enemy and requires all of them to pass a
  ## table keyed on `EPathDistance` and `TimeSinceSeen`. That table is one bot's
  ## worth of branching per enemy per check; the primary enemy is the only one
  ## whose answer differs in practice, because the table is monotone — an enemy
  ## closer or seen more recently than the primary would already be the primary.
  ## Checking one instead of all is the same answer for a fraction of the work,
  ## and it is stated here rather than left as an accident.
  let me = b.me
  if not me.hasAmmoToReload: return false
  let ratio = magazineRatio(me)
  if ratio >= s.reloadNeverAboveRatio: return false
  let e = b.enemy
  if not e.valid or e.threatLevel <= 0.0:
    return ratio < s.reloadNoEnemyRatio
  # Hard block: seen within the last two seconds. Reloading in front of someone
  # who is looking at you is how a bot dies holding a magazine.
  if e.visible or e.timeSinceSeen < 2.0:
    return ratio <= s.reloadInCombatAmmoRatio
  # Otherwise the further away and the longer since they were seen, the more
  # magazine a bot will tolerate topping up.
  case e.band
  of pdVeryClose: result = ratio <= 0.25 and e.timeSinceSeen > 2.0
  of pdClose: result = ratio <= 0.5 and e.timeSinceSeen > 2.0
  of pdMid: result = ratio <= 0.66 and e.timeSinceSeen > 4.0
  of pdFar, pdVeryFar: result = ratio < s.reloadNoEnemyRatio and
                                e.timeSinceSeen > 2.0
  of pdNoEnemy: result = ratio < s.reloadNoEnemyRatio

func selfLayer*(b: BotView; s: Settings): SelfAction =
  ## What the bot must do to itself before it can usefully do anything else.
  ##
  ## SAIN's order, which is by what kills a bot soonest: an empty gun beats a
  ## wound, and both beat being merely hurt. `ShootData.Shooting` suppresses the
  ## whole layer in the original; here the equivalent is that a bot with a shot
  ## available and a usable magazine never reaches the heal checks.
  let me = b.me

  # A heavy bleed is a timer running to zero and nothing else matters.
  if me.hasHeavyBleed and me.canHeal:
    return saFirstAid

  if shallReload(b, s):
    return saReload

  # Everything below wants a lull. SAIN's `AtPeace` / `RunningToCover` test is
  # approximated by: in cover, and nobody visible.
  let safeEnough = me.inCoverStatus == csInCover and not b.enemy.visible
  if not safeEnough:
    return saNone

  if me.hasFracture and me.canDoSurgery and
     me.healthNormalized < s.surgeryHealthThreshold:
    return saSurgery
  if me.canHeal and (me.hasLightBleed or
                     me.healthNormalized < s.healHealthThreshold):
    return saFirstAid
  if me.canUseStims and me.healthNormalized < s.stimsHealthThreshold:
    return saStims
  result = saNone

# ---------------------------------------------------------------------------
# Layer 2: squad
# ---------------------------------------------------------------------------

func squadLayer*(b: BotView; s: Settings): SquadDecision =
  ## What the squad wants.
  ##
  ## SAIN gates the whole class on being in a group with a live leader, then
  ## bails out entirely if this bot's own enemy is visible or was seen within
  ## ten seconds — a bot in its own fight takes no orders. Both are kept.
  let sq = b.squad
  if sq.memberCount <= 1 or not sq.leaderAlive:
    return sdNone

  # PushSuppressedEnemy is checked *before* the own-fight bail-out in SAIN,
  # because it is the one order that is about this bot's own enemy.
  if b.enemy.valid and b.enemy.isSuppressed and
     s.canRushEnemyReloadHeal and
     magazineRatio(b.me) >= s.rushLowAmmoRatio and
     b.me.healthNormalized > s.fightBackHealthThreshold and
     b.enemy.pathDistance < s.engageDistance:
    return sdPushSuppressedEnemy

  if b.enemy.visible or b.enemy.timeSinceSeen < s.myEnemySeenRecentTime:
    return sdNone

  # Someone is down. Helping outranks this bot's own approach, which is the
  # whole point of a squad and the thing vanilla lacks.
  if sq.mateNeedsHelp and sq.nearestMateDistance <= s.helpStartDistance:
    return sdHelp

  # A squad that is losing leaves together. Bounding is the version with
  # covering fire and needs at least three bodies to be worth the name.
  if b.me.healthNormalized < s.runAwayHealthThreshold and sq.aliveCount >= 2:
    return (if sq.aliveCount >= 3: sdBoundingRetreat else: sdRetreat)

  # Out of earshot of the radio: a bot with no earpiece takes no orders from a
  # squadmate it cannot hear. SAIN's `HasRadioComms` check, kept because losing
  # it is what makes a scav pack behave like one organism.
  let inRadioRange = sq.nearestMateDistance <= s.radioCommsMaxDistance

  if sq.squadSeesEnemy and inRadioRange:
    if b.enemy.valid and not b.enemy.visible and
       sq.nearestMateDistance <= s.suppressFriendStartDistance and
       magazineRatio(b.me) >= 0.5:
      return sdSuppress
    if sq.aliveCount >= 3 and b.enemy.valid and
       b.enemy.pathDistance < s.engageDistance:
      return sdSurround
    return sdHoldPositions

  # Scattered squad, no contact: close up.
  if not sq.squadSeesEnemy and not sq.isLeader and
     sq.leaderDistance > s.regroupStartNoEnemy:
    return sdRegroup

  # Standing on each other is how a squad dies to one grenade.
  if sq.nearestMateDistance < s.squadSpreadMinDistance:
    return sdSpreadOut

  # Nobody has contact but a squadmate is searching for the same enemy.
  if not sq.squadSeesEnemy and sq.mateInCombat and b.enemy.valid and
     b.enemy.threatLevel > 0.2 and s.willSearchForEnemy:
    return sdGroupSearch

  result = sdNone

func combatFor*(sd: SquadDecision): CombatDecision =
  ## What a squad decision means for this bot's own actions.
  ##
  ## SAIN keeps these separate — the squad decision selects a BigBrain *action*
  ## directly, and the combat decision stays `None`. This port has no action
  ## objects, so the mapping is made explicit here, in one place, rather than
  ## branched on inside every consumer.
  case sd
  of sdHelp, sdRegroup, sdSurround, sdPushSuppressedEnemy: cdMoveToEngage
  of sdRetreat, sdBoundingRetreat: cdRetreat
  of sdSuppress: cdStandAndShoot
  of sdHoldPositions: cdHoldInCover
  of sdSearch, sdGroupSearch: cdSearch
  of sdSpreadOut: cdShiftCover
  of sdNone: cdNone

# ---------------------------------------------------------------------------
# Layer 3: the solo combat ladder
# ---------------------------------------------------------------------------

proc updateDogFight(ctx: var DecideContext; b: BotView; s: Settings) =
  ## SAIN: `DogFightDecisionClass.ShallDogfightEnemy` /
  ## `shallClearDogfightTarget` — a latched state with different enter and exit
  ## thresholds, so ten metres does not become a flicker boundary.
  let e = b.enemy
  if ctx.dogFight.value:
    let clear = (not e.valid) or
                e.pathDistance > s.dogFightPathEnd or
                ((not e.visible) and e.timeSinceSeen > s.dogFightSeenEnd)
    discard set(ctx.dogFight, not clear, b.timeNow)
  else:
    let start = e.valid and e.alive and
                e.pathDistance <= s.dogFightPathStart and
                (e.timeSinceSeen < s.dogFightSeenStart or e.suppressingUs)
    discard set(ctx.dogFight, start, b.timeNow)

func shallStandAndShoot(b: BotView; s: Settings; ctx: DecideContext): bool =
  ## SAIN: `shallStandAndShoot`. Visible, shootable, in range, and either the
  ## enemy is not looking at us or we have not been exposed for longer than the
  ## hold-ground delay.
  let e = b.enemy
  if not (e.visible and e.canShoot): return false
  if e.distance > s.engageDistance * s.standAndShootMaxRatio: return false
  if not e.lookingAtUs: return true       ## they have not noticed us yet
  # They are looking at us. SAIN keeps standing only while the exposure has
  # been short: `visibleFor < holdGround` continue, beyond it break off.
  result = b.timeNow < ctx.holdGroundUntil

func shallRush(b: BotView; s: Settings): bool =
  ## SAIN: `shallRushEnemy`. Not low on ammo, in range, and the enemy is doing
  ## something that makes them worth charging — reloading, healing, prone, or
  ## nearly dead. A personality that cannot rush never gets here.
  if not s.canRushEnemyReloadHeal: return false
  let e = b.enemy
  let me = b.me
  if me.healthNormalized < s.fightBackHealthThreshold: return false
  if magazineRatio(me) < s.rushLowAmmoRatio: return false
  let reach = (if me.stamina > 0.2: s.rushMaxPathDistanceSprint
               else: s.rushMaxPathDistance)
  if e.pathDistance > reach: return false
  result = e.isSuppressed or (not e.lookingAtUs) or e.threatLevel < 0.6

func shallFreeze(b: BotView; s: Settings): bool =
  ## SAIN: the Freeze check — a personality that freezes when it hears something
  ## while at peace, indoors, having never recently seen the source.
  if s.heardFromPeace != hfFreeze: return false
  let e = b.enemy
  if e.visible: return false
  if e.timeSinceSeen < s.freezeMinTimeSinceSeen and e.seenTotal > 0.0:
    return false
  if e.timeSinceHeard > s.freezeMaxTimeSinceHeard: return false
  result = e.distance <= s.freezeMaxDistance

func shallShiftCover(b: BotView; s: Settings; ctx: DecideContext): bool =
  ## SAIN: the ShiftCover check. Needs a personality that shifts, a cover point
  ## in use, and either a stale sighting or a stale last-known place.
  if not s.canShiftCoverPosition: return false
  if b.me.inCoverStatus != csInCover: return false
  if b.me.suppressionLevel >= s.suppressionSeekCoverLevel: return false
  if not ready(ctx.nextShiftAt, b.timeNow): return false
  if b.timeNow - ctx.lastChangeAt < s.shiftCoverChangeDecisionTime: return false
  let e = b.enemy
  if not e.valid:
    return b.timeNow - ctx.lastChangeAt > s.shiftCoverNoEnemyResetTime
  if e.visible: return false
  result = e.timeSinceSeen > s.shiftCoverTimeSinceSeen

proc combatLayer*(ctx: var DecideContext; b: BotView; s: Settings;
                  reason: var string): CombatDecision =
  ## The solo fight, as SAIN's `EnemyDecisionClass.GetDecision` ladder.
  ## First check that fires wins.
  let me = b.me
  let e = b.enemy

  # -- reflexes, above the ladder ------------------------------------------
  if b.grenade.active and b.grenade.distance < s.grenadeAvoidDistance:
    reason = "grenade at " & $b.grenade.distance & "m"
    return cdAvoidGrenade

  # SAIN's step 0: no weapon, no bullets, or mid-reload -> Retreat.
  if not me.weaponReady:
    if e.valid and e.distance < s.meleeDistance:
      reason = "no weapon, enemy in reach"
      return cdMeleeAttack
    if e.valid and e.threatLevel > 0.0:
      reason = "weapon not ready"
      return cdRetreat

  # -- no enemy at all -------------------------------------------------------
  if not e.valid or not e.alive or e.threatLevel <= 0.0:
    if b.hasSearchTarget and s.willSearchForEnemy:
      reason = "no contact, search target held"
      return cdSearch
    if b.timeSinceLastSound < 1.0 and b.lastSound != skNone:
      # SAIN: `EHeardFromPeaceBehavior`. A noise with no owner means different
      # things to different personalities, and this is where that shows.
      case s.heardFromPeace
      of hfCharge:
        reason = "charging an unattributed sound"
        return cdMoveToEngage
      of hfSearchNow:
        reason = "searching an unattributed sound"
        return cdSearch
      of hfFreeze:
        reason = "freezing at an unattributed sound"
        return cdFreeze
      of hfNone:
        discard
    reason = "nothing to do"
    return cdNone

  # -- dogfight, latched -----------------------------------------------------
  updateDogFight(ctx, b, s)
  if ctx.dogFight.value:
    reason = "dogfight"
    return cdDogFight

  if e.distance <= s.meleeDistance and not me.weaponReady:
    reason = "melee range"
    return cdMeleeAttack

  # -- badly hurt ------------------------------------------------------------
  if me.healthNormalized < s.runAwayHealthThreshold:
    reason = "health below the run-away threshold"
    return cdRunAway

  if me.healthNormalized < s.fightBackHealthThreshold and
     me.inCoverStatus != csInCover:
    reason = "hurt and exposed"
    return cdRetreat

  # -- pinned ----------------------------------------------------------------
  if me.suppressionLevel >= s.suppressionPinnedLevel and
     me.inCoverStatus == csInCover:
    reason = "pinned in cover"
    return cdHoldInCover
  if me.suppressionLevel >= s.suppressionSeekCoverLevel and
     me.inCoverStatus != csInCover:
    reason = "suppressed in the open"
    return cdSeekCover

  # -- stand and shoot -------------------------------------------------------
  if shallStandAndShoot(b, s, ctx):
    reason = "holding ground with a shot"
    return cdStandAndShoot

  # -- distant target, on its own cooldown -----------------------------------
  if e.visible and e.canShoot and e.distance > s.maxPointFireDistance and
     me.healthNormalized > s.fightBackHealthThreshold:
    if b.timeNow < ctx.endDistantShotAt:
      reason = "still engaging a distant target"
      return cdShootDistantEnemy
    if ready(ctx.nextDistantShotAt, b.timeNow):
      reason = "distant target"
      return cdShootDistantEnemy

  # -- rush ------------------------------------------------------------------
  if shallRush(b, s):
    reason = "enemy vulnerable and close"
    return cdRushEnemy

  # -- search ----------------------------------------------------------------
  if s.willSearchForEnemy and not e.visible and
     e.timeSinceSeen > s.timeBeforeSearch:
    reason = "lost contact for longer than the search delay"
    return cdSearch

  # -- freeze ----------------------------------------------------------------
  if shallFreeze(b, s):
    reason = "frozen, listening"
    return cdFreeze

  # -- shift cover -----------------------------------------------------------
  if shallShiftCover(b, s, ctx):
    reason = "cover has gone stale"
    return cdShiftCover

  # -- creep -----------------------------------------------------------------
  if e.timeSinceSeen > 2.0 and e.threatLevel > 0.3 and
     e.pathDistance < s.creepMaxDistance and not e.suppressingUs and
     s.sneaky:
    reason = "unaware enemy nearby"
    return cdCreepOnEnemy

  # -- known but out of range ------------------------------------------------
  if e.pathDistance > s.engageDistance:
    reason = "known but out of range"
    return cdMoveToEngage

  # -- SAIN's fallback -------------------------------------------------------
  if me.inCoverStatus == csInCover:
    reason = "in cover, waiting"
    return cdHoldInCover
  reason = "no better option: seek cover"
  result = cdSeekCover

# ---------------------------------------------------------------------------
# The arbiter
# ---------------------------------------------------------------------------

proc decide*(ctx: var DecideContext; b: BotView; s: Settings): Decision =
  ## One pass of the cascade, in SAIN's order, with the hold rule applied.
  var reason = ""
  var combat = cdNone
  var squadAct = sdNone
  let selfAct = selfLayer(b, s)

  if selfAct != saNone:
    # SAIN emits `(SeekCover, None, selfAction)`: a bot doing something to
    # itself wants to be behind something while it does it.
    combat = cdSeekCover
    reason = "self action: " & selfActionName(selfAct)
  else:
    combat = combatLayer(ctx, b, s, reason)

    # A squad order replaces the solo decision, but only when the solo one is
    # not a reflex: no plan survives a grenade, and a bot being knifed cannot
    # go and regroup. SAIN gets this by checking DogFight before the squad
    # class and letting the AvoidThreat layer outrank the squad layer.
    if urgency(combat) < urgency(cdRunAway):
      squadAct = squadLayer(b, s)
      let squadCombat = combatFor(squadAct)
      if squadCombat != cdNone and urgency(squadCombat) >= urgency(combat):
        combat = squadCombat
        reason = "squad: " & squadDecisionName(squadAct)

  # The hold rule. A held decision survives unless the new one is strictly more
  # urgent -- note `<=`, not `<`: an equal-urgency alternative is not a reason
  # to abandon something already in progress.
  let prev = ctx.previous
  if b.timeNow < prev.holdUntil and prev.combat != cdNone:
    if urgency(combat) <= urgency(prev.combat):
      var held = prev
      held.self = selfAct        ## self-care is never held back
      held.squad = squadAct
      ctx.previous = held
      return held

  let hold = holdTimeFor(combat, s) * (0.85 + 0.3 * ctx.jitter)
  result = Decision(combat: combat, squad: squadAct, self: selfAct,
                    reason: reason, holdUntil: b.timeNow + hold)

  if combat != prev.combat:
    ctx.lastChangeAt = b.timeNow
    discard set(ctx.runningToCover,
                combat == cdSeekCover or combat == cdRetreat or
                combat == cdRunAway, b.timeNow)

    # Entering cover starts the patience clock `shallStandAndShoot` and
    # `cdHoldInCover` read. Set here rather than inside the ladder so the ladder
    # stays a function of its inputs alone.
    if combat == cdSeekCover or combat == cdHoldInCover or
       combat == cdStandAndShoot:
      ctx.holdGroundUntil = b.timeNow +
        s.holdGroundBaseTime *
        (s.holdGroundMinRandom +
         (s.holdGroundMaxRandom - s.holdGroundMinRandom) * ctx.jitter)

    if combat == cdShiftCover:
      arm(ctx.nextShiftAt, b.timeNow, s.shiftCoverResetTime)

    if combat == cdShootDistantEnemy:
      # SAIN: `timeAdd = 6 * Random(0.75, 1.25)`; stay for a third of it, then
      # do not re-enter until the whole window has passed.
      let window = 6.0 * (0.75 + 0.5 * ctx.jitter)
      ctx.endDistantShotAt = b.timeNow + window / 3.0
      arm(ctx.nextDistantShotAt, b.timeNow, window)

  ctx.previous = result
