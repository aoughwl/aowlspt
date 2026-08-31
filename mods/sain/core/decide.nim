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
import vision
import flank

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
    ## Not again before, for the flank. A flank whose side is re-decided every
    ## tick is a bot walking on the spot between two waypoints.
    nextFlankAt*: Cooldown
    ## When this bot first committed to a frontal engagement with its current
    ## enemy. The flank check reads it: a fight that has been going nowhere for
    ## `flankAfterStalledSeconds` is a fight worth changing the angle of, and
    ## without this the bot has no way to know a fight is going nowhere.
    engagedSince*: float
    ## Latched. Extracting is the one decision that should not be reconsidered
    ## when a health pack brings the bot back over a threshold: it left for
    ## three reasons at once and one of them improving is not a reason to walk
    ## back into the raid.
    extracting*: Toggle
    ## Which way this bot flanks, drawn once per flank rather than per tick.
    flankSideHeld*: float

func newContext*(jitter: float): DecideContext =
  DecideContext(previous: emptyDecision(), lastChangeAt: 0.0,
                holdGroundUntil: 0.0, nextShiftAt: newCooldown(),
                nextDistantShotAt: newCooldown(), endDistantShotAt: 0.0,
                unfreezeAt: 0.0, dogFight: newToggle(false),
                runningToCover: newToggle(false), jitter: jitter,
                nextFlankAt: newCooldown(), engagedSince: 0.0,
                extracting: newToggle(false), flankSideHeld: 1.0)

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
  # Above Retreat and below RunAway: a bot that has decided to leave the raid
  # should not be talked out of it by a squad order or by cover looking
  # attractive, but a knife in the face still outranks it.
  of cdExtract: 78
  of cdRetreat: 70
  of cdSeekCover: 60
  of cdStandAndShoot: 55
  of cdThrowGrenade: 50
  of cdRushEnemy: 45
  # Just under a rush and over a shift: changing the angle is a bigger
  # commitment than changing the cover point and a smaller one than charging.
  of cdFlank: 42
  of cdShiftCover: 40
  of cdCreepOnEnemy: 35
  of cdShootDistantEnemy: 30
  of cdHoldInCover: 25
  of cdMoveToEngage: 20
  of cdFreeze: 15
  of cdSearch: 10
  # Below search, above nothing. An objective is what a bot does when it has
  # run out of reasons to do anything else, and ANY other rung must be able to
  # interrupt it -- a bot that walked to a crate through a firefight is the
  # failure this ordering prevents.
  of cdMoveToObjective: 5
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
  # The longest hold in the table, and the reason is the whole point of the
  # decision: a flank that is abandoned halfway is a bot that walked into the
  # open for nothing. SAIN's equivalent commitment is the BigBrain action's own
  # lifetime, which is why it does not need a number here.
  of cdFlank: 5.0
  of cdExtract: 8.0
  of cdFreeze: 1.0
  of cdHoldInCover: 1.5
  of cdThrowGrenade: 1.0
  # The longest hold in the table by a wide margin, and for the opposite
  # reason to the flank's: an objective is tens or hundreds of metres away, and
  # re-issuing a destination every 100 ms is how a bot ends up standing still
  # while its navmesh agent restarts. The hold is a re-DECIDE interval, not a
  # commitment -- urgency 5 means anything at all still interrupts it.
  of cdMoveToObjective: 6.0
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
  # Surround is the one order whose meaning is geometric rather than a
  # destination, and it now has a decision that expresses it. Before `cdFlank`
  # existed this mapped to `MoveToEngage`, which turned "surround him" into
  # "everybody walk at him from where you are" -- the opposite of the order.
  of sdSurround: cdFlank
  of sdHelp, sdRegroup, sdPushSuppressedEnemy: cdMoveToEngage
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

func shallFlank(b: BotView; s: Settings; ctx: DecideContext): bool =
  ## Work an angle instead of pushing the one that is not working.
  ##
  ## SAIN reaches a flank by comparing navmesh path lengths to points its cover
  ## finder produced on the far side of the enemy. Neither the navmesh nor the
  ## cover finder is reachable here, so the condition is stated in terms of
  ## what *is*: the bot knows roughly where the enemy is, cannot currently
  ## shoot them, has been trying for a while, and is healthy enough that the
  ## walk is worth taking.
  ##
  ## The last clause is the one that makes it behaviour rather than noise. A
  ## bot that flanks the instant it loses sight is a bot that never holds an
  ## angle; `engagedSince` is what makes it flank because the fight has
  ## *stalled*.
  if not s.canFlank: return false
  let e = b.enemy
  if not (e.valid and e.alive): return false
  if b.me.healthNormalized < s.flankMinHealth: return false
  if e.threatLevel < 0.35: return false
  # A shot available is not a fight that has stalled.
  if e.visible and e.canShoot: return false
  # ...but a total loss of the enemy is a search, not a flank. The bot has to
  # still have some idea where they are.
  if not (stillTracking(e, s) or e.timeSinceSeen < 15.0): return false
  if e.pathDistance < s.flankMinDistance: return false
  if e.pathDistance > s.flankMaxDistance: return false
  if not ready(ctx.nextFlankAt, b.timeNow): return false
  result = b.timeNow - ctx.engagedSince > s.flankAfterStalledSeconds

func shallExtract(b: BotView; s: Settings; ctx: DecideContext): bool =
  ## SAIN: `ExtractDecisionClass`. Hurt, dry, and late enough in the raid that
  ## leaving is a plan rather than a rout.
  ##
  ## Latched by the caller through `ctx.extracting`, because all three inputs
  ## are things a single first-aid kit can flip back and a bot that turns round
  ## at the exit is worse than one that never left.
  if ctx.extracting.value:
    return true
  if b.extractRequested:
    return true
  if b.raidSeconds < s.extractMinRaidSeconds:
    return false
  if b.me.healthNormalized >= s.extractHealthThreshold:
    return false
  # Dry: not merely a low magazine but nothing left to fill it with.
  if b.me.hasAmmoToReload and magazineRatio(b.me) > s.extractAmmoRatio:
    return false
  result = true

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
                  reason: var DecisionReason): CombatDecision =
  ## The solo fight, as SAIN's `EnemyDecisionClass.GetDecision` ladder.
  ## First check that fires wins.
  let me = b.me
  let e = b.enemy

  # -- reflexes, above the ladder ------------------------------------------
  if b.grenade.active and b.grenade.distance < s.grenadeAvoidDistance:
    reason = drGrenadeIncoming
    return cdAvoidGrenade

  # SAIN's step 0: no weapon, no bullets, or mid-reload -> Retreat.
  if not me.weaponReady:
    if e.valid and e.distance < s.meleeDistance:
      reason = drNoWeaponInReach
      return cdMeleeAttack
    if e.valid and e.threatLevel > 0.0:
      reason = drWeaponNotReady
      return cdRetreat

  # -- no enemy at all -------------------------------------------------------
  if not e.valid or not e.alive or e.threatLevel <= 0.0:
    if b.hasSearchTarget and s.willSearchForEnemy:
      reason = drNoContactSearchHeld
      return cdSearch
    if b.timeSinceLastSound < 1.0 and b.lastSound != skNone:
      # SAIN: `EHeardFromPeaceBehavior`. A noise with no owner means different
      # things to different personalities, and this is where that shows.
      case s.heardFromPeace
      of hfCharge:
        reason = drUnattributedSoundCharge
        return cdMoveToEngage
      of hfSearchNow:
        reason = drUnattributedSoundSearch
        return cdSearch
      of hfFreeze:
        reason = drUnattributedSoundFreeze
        return cdFreeze
      of hfNone:
        discard
    reason = drNothingToDo
    return cdNone

  # -- dogfight, latched -----------------------------------------------------
  updateDogFight(ctx, b, s)
  if ctx.dogFight.value:
    reason = drDogFight
    return cdDogFight

  if e.distance <= s.meleeDistance and not me.weaponReady:
    reason = drMeleeRange
    return cdMeleeAttack

  # -- leaving ---------------------------------------------------------------
  # Above the health checks rather than below them: a bot that is hurt *and*
  # out of ammunition has nothing to gain from running to cover it cannot shoot
  # from, and SAIN puts its extract layer above the combat layer for the same
  # reason.
  if shallExtract(b, s, ctx):
    reason = drExtracting
    return cdExtract

  # -- badly hurt ------------------------------------------------------------
  if me.healthNormalized < s.runAwayHealthThreshold:
    reason = drHealthBelowRunAway
    return cdRunAway

  if me.healthNormalized < s.fightBackHealthThreshold and
     me.inCoverStatus != csInCover:
    reason = drHurtAndExposed
    return cdRetreat

  # -- pinned ----------------------------------------------------------------
  if me.suppressionLevel >= s.suppressionPinnedLevel and
     me.inCoverStatus == csInCover:
    reason = drPinnedInCover
    return cdHoldInCover
  if me.suppressionLevel >= s.suppressionSeekCoverLevel and
     me.inCoverStatus != csInCover:
    reason = drSuppressedInOpen
    return cdSeekCover

  # -- seen, but not yet noticed ---------------------------------------------
  #
  # The rung this port exists to add. The engine's raycast has reached the
  # enemy, but this bot's own acquisition (`core/vision.nim`) has not yet
  # crossed its engage threshold, or has and the reaction delay has not
  # elapsed. Vanilla and the previous version of this file treated the raycast
  # as the bot's own knowledge and fired on the frame it succeeded.
  #
  # What the bot does in the meantime is not "nothing": it is exactly what a
  # person does in the half second before they have processed what they are
  # looking at, which is to keep whatever posture they already had. In cover,
  # stay; in the open, start moving to some.
  if e.visible and e.alive and not e.canShoot and
     e.distance <= s.engageDistance * s.standAndShootMaxRatio:
    reason = drNotYetAcquired
    return (if me.inCoverStatus == csInCover: cdHoldInCover else: cdSeekCover)

  # -- stand and shoot -------------------------------------------------------
  if shallStandAndShoot(b, s, ctx):
    reason = drHoldingGroundWithShot
    return cdStandAndShoot

  # -- distant target, on its own cooldown -----------------------------------
  if e.visible and e.canShoot and e.distance > s.maxPointFireDistance and
     me.healthNormalized > s.fightBackHealthThreshold:
    if b.timeNow < ctx.endDistantShotAt:
      reason = drDistantTargetHeld
      return cdShootDistantEnemy
    if ready(ctx.nextDistantShotAt, b.timeNow):
      reason = drDistantTarget
      return cdShootDistantEnemy

  # -- rush ------------------------------------------------------------------
  if shallRush(b, s):
    reason = drEnemyVulnerable
    return cdRushEnemy

  # -- flank -----------------------------------------------------------------
  if shallFlank(b, s, ctx):
    reason = drFlankStale
    return cdFlank

  # -- search ----------------------------------------------------------------
  if s.willSearchForEnemy and not e.visible and
     e.timeSinceSeen > s.timeBeforeSearch:
    reason = drLostContactPastSearchDelay
    return cdSearch

  # -- freeze ----------------------------------------------------------------
  if shallFreeze(b, s):
    reason = drFrozenListening
    return cdFreeze

  # -- shift cover -----------------------------------------------------------
  if shallShiftCover(b, s, ctx):
    reason = drCoverStale
    return cdShiftCover

  # -- creep -----------------------------------------------------------------
  if e.timeSinceSeen > 2.0 and e.threatLevel > 0.3 and
     e.pathDistance < s.creepMaxDistance and not e.suppressingUs and
     s.sneaky:
    reason = drUnawareEnemyNearby
    return cdCreepOnEnemy

  # -- known but out of range ------------------------------------------------
  if e.pathDistance > s.engageDistance:
    reason = drKnownOutOfRange
    return cdMoveToEngage

  # -- SAIN's fallback -------------------------------------------------------
  if me.inCoverStatus == csInCover:
    reason = drInCoverWaiting
    return cdHoldInCover
  reason = drNoBetterOptionSeekCover
  result = cdSeekCover

# ---------------------------------------------------------------------------
# Where the decision sends the bot
# ---------------------------------------------------------------------------

func fighting*(b: BotView): bool =
  ## Whether this bot has anything at all to be busy with.
  ##
  ## Read ONLY by the objective rung, and stated as a broad negative on
  ## purpose: nav commands are ignored by the game mid-fight anyway, so an
  ## objective issued to a bot in contact is a call that does nothing and
  ## still counts as a destination write. The rung declines instead.
  b.enemy.valid or b.enemyCount > 0 or b.grenade.active or
    b.hasSearchTarget or b.extractRequested

func objectiveLayer*(b: BotView; s: Settings; combat: CombatDecision;
                     selfAct: SelfAction): bool =
  ## The lowest rung: "idle intent".
  ##
  ## It fires only when every other rung declined -- no self-care, no combat
  ## decision at all -- and only when the driver actually handed this bot a
  ## destination derived from its squad's ONE objective. Four independent
  ## conditions, all of which must hold, so the failure mode of this layer is
  ## that a bot stands still, never that it walks away from a fight.
  if not s.objectivesEnabled:
    return false
  if selfAct != saNone or combat != cdNone:
    return false
  if fighting(b):
    return false
  result = b.hasObjective

func engaging(d: CombatDecision): bool =
  ## Whether this decision is the bot *pressing a frontal engagement*. Read by
  ## the flank timer: the clock that decides a fight has stalled has to start
  ## when the fight starts, and this is the definition of "started".
  case d
  of cdStandAndShoot, cdShootDistantEnemy, cdMoveToEngage, cdHoldInCover,
     cdRushEnemy, cdDogFight: true
  else: false

proc moveTargetFor*(ctx: var DecideContext; d: CombatDecision; b: BotView;
                    s: Settings; target: var Vec3): bool =
  ## Where a decision wants the bot, as a point in the world.
  ##
  ## Separated from the ladder because the ladder answers *what* and this
  ## answers *where*, and separated from the actuator because only the ladder's
  ## reasons make the geometry decidable -- a retreat and a flank both move the
  ## bot away from the enemy's bearing and they are not the same shape.
  ##
  ## Pure except for the flank side, which is latched into the context so that
  ## a flank keeps going the way it started. That single piece of state is why
  ## this takes `var` rather than being a `func`.
  let me = b.me
  let e = b.enemy
  target = zeroVec()
  case d
  of cdAvoidGrenade:
    if not b.grenade.active: return false
    target = avoidTarget(me.position, b.grenade.position, s)
    return true
  of cdSeekCover:
    if me.hasCoverPoint:
      target = me.coverPosition
      return true
    # No cover set -- the usual case on a build where the cover sensor refused,
    # which is every build so far. Falling back to "away from the enemy" is
    # what a bot with no cover to run to should do, and it is honest: the
    # README says the cover *points* are missing, not the cover *behaviour*.
    if not e.valid: return false
    target = retreatTarget(me.position, e.position, 14.0)
    return true
  of cdShiftCover:
    if me.hasCoverPoint:
      target = me.coverPosition
      return true
    if not b.squad.haveMate: return false
    target = spreadTarget(me.position, b.squad.nearestMatePosition,
                          s.squadSpreadMinDistance)
    return true
  of cdRetreat:
    if not e.valid: return false
    target = withdrawTarget(me.position, e.position, me.coverPosition,
                            me.hasCoverPoint, 18.0)
    return true
  of cdRunAway:
    if not e.valid: return false
    target = retreatTarget(me.position, e.position, 45.0)
    return true
  of cdExtract:
    # No exfiltration point is reachable from here (see `README.md`), so the
    # destination is "away from everything this bot knows about", which is the
    # observable half of extracting and is stated as exactly that.
    if e.valid:
      let threats = [e.position]
      target = extractDirection(me.position, threats)
    else:
      target = vec3(me.position.x + 60.0, me.position.y, me.position.z)
    return true
  of cdFlank:
    if not e.valid: return false
    if ready(ctx.nextFlankAt, b.timeNow):
      # The side is chosen once, when the flank begins, and held for the whole
      # cooldown. Re-choosing it per tick is the failure this cooldown exists
      # to prevent: the bot crosses the bearing, the "which side am I on" test
      # flips, and it crosses back.
      ctx.flankSideHeld = flankSide(me.position, e.position,
                                    b.squad.nearestMatePosition,
                                    b.squad.haveMate)
      arm(ctx.nextFlankAt, b.timeNow, s.flankCooldown)
    target = flankTarget(me.position, e.position, ctx.flankSideHeld, s)
    return true
  of cdRushEnemy, cdMeleeAttack:
    if not e.valid: return false
    target = e.position
    return true
  of cdMoveToEngage:
    if not e.valid: return false
    # Close to the edge of the bot's own effective range rather than onto the
    # enemy: a bot that walks all the way in has thrown away the weapon it was
    # moving to use.
    target = towards(me.position, e.position,
                     clampf(e.pathDistance - s.engageDistance * 0.8,
                            0.0, 500.0))
    return true
  of cdCreepOnEnemy:
    if not e.valid: return false
    target = creepTarget(me.position, e.position, s)
    return true
  of cdSearch:
    if not b.hasSearchTarget: return false
    target = b.searchTarget
    return true
  of cdMoveToObjective:
    # Already resolved to THIS member's destination by `objectiveFor`, which
    # ran in the driver where the group pointer is. Nothing is derived here:
    # deriving it twice is how the two writers disagreed in the first place.
    if not b.hasObjective: return false
    target = b.objectiveTarget
    return true
  of cdStandAndShoot, cdShootDistantEnemy, cdThrowGrenade, cdDogFight,
     cdFreeze, cdHoldInCover, cdNone:
    return false

# ---------------------------------------------------------------------------
# The arbiter
# ---------------------------------------------------------------------------

proc decide*(ctx: var DecideContext; b: BotView; s: Settings): Decision =
  ## One pass of the cascade, in SAIN's order, with the hold rule applied.
  var reason = drNone
  var combat = cdNone
  var squadAct = sdNone
  let selfAct = selfLayer(b, s)

  if selfAct != saNone:
    # SAIN emits `(SeekCover, None, selfAction)`: a bot doing something to
    # itself wants to be behind something while it does it.
    combat = cdSeekCover
    reason = drSelfAction
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
        reason = drSquadOrder

    # The new lowest rung, BELOW squad. Reached only when everything above it
    # declined, which is what makes `decide` the single chooser of a
    # destination: there is now no path by which a bot is sent somewhere
    # without this function having said so.
    if objectiveLayer(b, s, combat, selfAct):
      combat = cdMoveToObjective
      reason = drSquadObjective

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
  var moveTo = zeroVec()
  let hasMove = moveTargetFor(ctx, combat, b, s, moveTo)
  result = Decision(combat: combat, squad: squadAct, self: selfAct,
                    reason: reason, holdUntil: b.timeNow + hold,
                    moveTo: moveTo, hasMove: hasMove)

  # Extracting latches on entry rather than being re-derived: `shallExtract`
  # reads the toggle back, so this is the only place it is ever set.
  if combat == cdExtract:
    discard set(ctx.extracting, true, b.timeNow)

  if combat != prev.combat:
    ctx.lastChangeAt = b.timeNow

    # The stall clock for the flank. It starts when a frontal engagement
    # starts and is *not* restarted while one continues, which is the whole
    # point -- a fight that has been running for eight seconds is a fight the
    # bot should consider approaching differently.
    if engaging(combat) and not engaging(prev.combat):
      ctx.engagedSince = b.timeNow
    elif not (engaging(combat) or combat == cdFlank):
      # Contact broken off for a reason that is not a flank: the next
      # engagement is a fresh one and gets its full patience back.
      ctx.engagedSince = b.timeNow
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
