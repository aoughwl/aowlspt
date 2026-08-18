## Every number the decision core compares against, in one place.
##
## SAIN's own config is a reflection-driven tree — `GlobalSettingsClass` with
## thirteen categories, a `SAINSettingsGroupClass` per bot type per difficulty,
## a `PersonalitySettingsClass` per personality, all decorated with attributes
## that drive two separate settings editors. That machinery exists to build
## GUIs. What actually reaches a decision is a few dozen numbers, and those are
## what is here.
##
## Two structural decisions, both deliberate, both performance:
##
## **One flat record, resolved once.** The C# reads a threshold through a
## property chain (`Bot.Info.FileSettings.Mind.HoldGroundBaseTime`, or
## `Bot.Info.Personality.Behavior.General.DOGFIGHT_PATH_DIST_START`) at the
## point of use — inside a check, inside a cascade that runs at 10 Hz, per bot.
## Here the whole record is a value stored per bot, so a threshold comparison
## is one field load. With 30 bots at 10 Hz that removes on the order of tens
## of thousands of pointer hops a second.
##
## **Personality is baked in, not consulted.** SAIN multiplies a base threshold
## by `AggressionMultiplier` where it is used. `resolvedFor` does the multiply
## once, when the bot spawns, and the ladder reads plain numbers.
##
## Where a constant came straight out of SAIN it is named after its C# original
## in the comment, so the two can be diffed.

import types

type
  Settings* = object
    # -- Timing ------------------------------------------------------------
    decisionHz*: float             ## SAIN: DECISION_FREQUENCY = 1/10

    # -- Mind --------------------------------------------------------------
    holdGroundBaseTime*: float     ## SAIN: HoldGroundBaseTime, 1.0
    holdGroundMinRandom*: float    ## SAIN: 0.66
    holdGroundMaxRandom*: float    ## SAIN: 1.5
    fightBackHealthThreshold*: float
    runAwayHealthThreshold*: float
    timeBeforeSearch*: float       ## SAIN: Search.SearchBaseTime, 40
    searchGiveUpSeconds*: float
    engageDistance*: float         ## effective weapon distance, in metres
    maxPointFireDistance*: float   ## SAIN: Shoot.MaxPointFireDistance
    standAndShootMaxRatio*: float  ## SAIN rejects beyond 1.25x engage distance

    # -- Dogfight (SAIN: Personality.General.DOGFIGHT_*) -------------------
    dogFightPathStart*: float      ## 10
    dogFightPathEnd*: float        ## 15
    dogFightSeenStart*: float      ## 1
    dogFightSeenEnd*: float        ## 8

    # -- Rush (SAIN: RushEnemyMaxPathDistance / ...Sprint / LowAmmoRatio) --
    rushMaxPathDistance*: float    ## 10
    rushMaxPathDistanceSprint*: float ## 20
    rushLowAmmoRatio*: float       ## 0.5

    # -- Freeze (SAIN: FREEZE_*) ------------------------------------------
    freezeMaxDistance*: float      ## 70
    freezeMinTimeSinceSeen*: float ## 240
    freezeMaxTimeSinceHeard*: float ## 80
    freezeMinSeconds*: float       ## SAIN rolls Random(10,120)/aggression
    freezeMaxSeconds*: float

    meleeDistance*: float
    creepMaxDistance*: float

    # -- Perception --------------------------------------------------------
    forgetEnemySeconds*: float     ## SAIN: TimeBeforeSearch + Random(20,60)
    lastKnownHardLimit*: float     ## SAIN: LAST_KNOWN_TIME_UPDATE_UPPER_LIMIT
    heardTimeout*: float
    visionSeenTimeout*: float
    fieldOfViewCos*: float
    threatDecayPerSecond*: float
    minSeenTimeToEngage*: float
    enemySniperDistance*: float    ## SAIN: ENEMYSNIPER_DISTANCE, 85
    enemySniperDistanceEnd*: float ## SAIN: 75

    # -- Cover (SAIN: General.Cover.*) ------------------------------------
    coverMinEnemyDistance*: float  ## 8
    maxCoverPathLength*: float     ## 60
    coverMinHeight*: float         ## 0.75
    coverInRangeDistance*: float   ## DIST_COVER_INCOVER, 1.25
    coverStayDistance*: float      ## DIST_COVER_INCOVER_STAY, 1.5
    coverCloseDistance*: float     ## 10
    coverMidDistance*: float       ## 20
    shiftCoverChangeDecisionTime*: float ## 6
    shiftCoverTimeSinceSeen*: float      ## 30
    shiftCoverTimeSinceCreated*: float   ## 30
    shiftCoverNoEnemyResetTime*: float   ## 10
    shiftCoverResetTime*: float          ## 10

    # -- Self care ---------------------------------------------------------
    healHealthThreshold*: float
    surgeryHealthThreshold*: float
    stimsHealthThreshold*: float
    reloadNeverAboveRatio*: float  ## SAIN: ratio >= 0.8 never reloads
    reloadNoEnemyRatio*: float     ## SAIN: no enemy, reload below 0.7
    reloadEnemySearchingRatio*: float ## SAIN: enemy searching, below 0.2
    reloadInCombatAmmoRatio*: float
    healCheckInterval*: float      ## SAIN: 2s, 0.2s when shot recently

    # -- Grenades ----------------------------------------------------------
    grenadeAvoidDistance*: float
    grenadeThrowMinDistance*: float
    grenadeThrowMaxDistance*: float
    grenadeChance*: float

    # -- Squad (SAIN: SquadDecisionClass fields) --------------------------
    radioCommsMaxDistance*: float  ## sqrt(SquaDecision_RadioCom_MaxDistSq 1200)
    myEnemySeenRecentTime*: float  ## 10
    suppressFriendStartDistance*: float  ## 30
    suppressFriendEndDistance*: float    ## 50
    helpStartDistance*: float            ## 30
    helpEndDistance*: float              ## 45
    helpFriendSeenRecentTime*: float     ## 8
    regroupStartNoEnemy*: float          ## 125
    regroupEndNoEnemy*: float            ## 50
    regroupStartEnemy*: float            ## 50
    regroupEndEnemy*: float              ## 15
    squadSpreadMinDistance*: float

    # -- Suppression -------------------------------------------------------
    suppressionSeekCoverLevel*: float
    suppressionPinnedLevel*: float
    suppressionDecayPerSecond*: float    ## SAIN: SUP_DECAY_AMOUNT/SUP_DECAY_FREQ

    # -- Personality behaviour flags, baked in by `resolvedFor` -----------
    canShiftCoverPosition*: bool
    canRushEnemyReloadHeal*: bool
    willSearchForEnemy*: bool
    willSearchFromAudio*: bool
    heardFromPeace*: HeardFromPeace
    sneaky*: bool
    aggressionMultiplier*: float

    # -- Scheduling (this port's own; SAIN has no equivalent) -------------
    farFromPlayerDistance*: float
    maxBotsPerTick*: int

  HeardFromPeace* = enum
    ## SAIN: `EHeardFromPeaceBehavior`. What a bot does about a noise made while
    ## it had no enemy at all — the input that separates a Rat freezing in a
    ## corner from a GigaChad charging the sound.
    hfNone, hfFreeze, hfSearchNow, hfCharge

func defaultSettings*(): Settings =
  ## SAIN's shipped values where they are plain constants, and a judgement call
  ## where SAIN derives them from a curve this port does not reproduce.
  Settings(
    decisionHz: 10.0,

    holdGroundBaseTime: 1.0,
    holdGroundMinRandom: 0.66,
    holdGroundMaxRandom: 1.5,
    fightBackHealthThreshold: 0.55,
    runAwayHealthThreshold: 0.28,
    timeBeforeSearch: 40.0,
    searchGiveUpSeconds: 90.0,
    engageDistance: 70.0,
    maxPointFireDistance: 100.0,
    standAndShootMaxRatio: 1.25,

    dogFightPathStart: 10.0,
    dogFightPathEnd: 15.0,
    dogFightSeenStart: 1.0,
    dogFightSeenEnd: 8.0,

    rushMaxPathDistance: 10.0,
    rushMaxPathDistanceSprint: 20.0,
    rushLowAmmoRatio: 0.5,

    freezeMaxDistance: 70.0,
    freezeMinTimeSinceSeen: 240.0,
    freezeMaxTimeSinceHeard: 80.0,
    freezeMinSeconds: 10.0,
    freezeMaxSeconds: 120.0,

    meleeDistance: 2.5,
    creepMaxDistance: 45.0,

    forgetEnemySeconds: 80.0,
    lastKnownHardLimit: 400.0,
    heardTimeout: 8.0,
    visionSeenTimeout: 4.0,
    fieldOfViewCos: 0.34,
    threatDecayPerSecond: 0.12,
    minSeenTimeToEngage: 0.12,
    enemySniperDistance: 85.0,
    enemySniperDistanceEnd: 75.0,

    coverMinEnemyDistance: 8.0,
    maxCoverPathLength: 60.0,
    coverMinHeight: 0.75,
    coverInRangeDistance: 1.25,
    coverStayDistance: 1.5,
    coverCloseDistance: 10.0,
    coverMidDistance: 20.0,
    shiftCoverChangeDecisionTime: 6.0,
    shiftCoverTimeSinceSeen: 30.0,
    shiftCoverTimeSinceCreated: 30.0,
    shiftCoverNoEnemyResetTime: 10.0,
    shiftCoverResetTime: 10.0,

    healHealthThreshold: 0.65,
    surgeryHealthThreshold: 0.4,
    stimsHealthThreshold: 0.5,
    reloadNeverAboveRatio: 0.8,
    reloadNoEnemyRatio: 0.7,
    reloadEnemySearchingRatio: 0.2,
    reloadInCombatAmmoRatio: 0.1,
    healCheckInterval: 2.0,

    grenadeAvoidDistance: 12.0,
    grenadeThrowMinDistance: 12.0,
    grenadeThrowMaxDistance: 45.0,
    grenadeChance: 0.25,

    radioCommsMaxDistance: 34.6,
    myEnemySeenRecentTime: 10.0,
    suppressFriendStartDistance: 30.0,
    suppressFriendEndDistance: 50.0,
    helpStartDistance: 30.0,
    helpEndDistance: 45.0,
    helpFriendSeenRecentTime: 8.0,
    regroupStartNoEnemy: 125.0,
    regroupEndNoEnemy: 50.0,
    regroupStartEnemy: 50.0,
    regroupEndEnemy: 15.0,
    squadSpreadMinDistance: 4.0,

    suppressionSeekCoverLevel: 0.35,
    suppressionPinnedLevel: 0.75,
    suppressionDecayPerSecond: 1.0,

    canShiftCoverPosition: true,
    canRushEnemyReloadHeal: true,
    willSearchForEnemy: true,
    willSearchFromAudio: true,
    heardFromPeace: hfNone,
    sneaky: false,
    aggressionMultiplier: 1.0,

    farFromPlayerDistance: 150.0,
    maxBotsPerTick: 8)

# ---------------------------------------------------------------------------
# Personality
# ---------------------------------------------------------------------------

type
  PersonalityTraits* = object
    ## SAIN's `PersonalitySettingsClass.Behavior`, reduced to what changes an
    ## outcome. The C# has five sub-groups and ~40 fields; the ones below are
    ## the ones a decision actually reads. Talk and taunt settings are not here
    ## because this port does not drive the voice lines — see the README note in
    ## `sain.nim` about what is and is not implemented.
    aggression*: float          ## SAIN: AggressionMultiplier
    courage*: float             ## disengage thresholds; SAIN spreads this over
                                ## SuppressionResistance and the health checks
    patience*: float            ## scales hold/search/shift times
    grenadeAffinity*: float
    coverAffinity*: float
    canShiftCover*: bool        ## SAIN: Cover.CanShiftCoverPosition
    canRushReloadHeal*: bool    ## SAIN: Rush.CanRushEnemyReloadHeal
    willSearch*: bool           ## SAIN: Search.WillSearchForEnemy
    willSearchFromAudio*: bool  ## SAIN: Search.WillSearchFromAudio
    heardFromPeace*: HeardFromPeace
    sneaky*: bool               ## SAIN: Search.Sneaky
    searchBaseTime*: float      ## SAIN: Search.SearchBaseTime

func traitsFor*(p: Personality): PersonalityTraits =
  case p
  of pWreckless:
    PersonalityTraits(aggression: 1.9, courage: 1.8, patience: 0.35,
                      grenadeAffinity: 1.4, coverAffinity: 0.2,
                      canShiftCover: false, canRushReloadHeal: true,
                      willSearch: true, willSearchFromAudio: true,
                      heardFromPeace: hfCharge, sneaky: false,
                      searchBaseTime: 5.0)
  of pGigaChad:
    PersonalityTraits(aggression: 1.6, courage: 1.6, patience: 0.6,
                      grenadeAffinity: 1.2, coverAffinity: 0.6,
                      canShiftCover: true, canRushReloadHeal: true,
                      willSearch: true, willSearchFromAudio: true,
                      heardFromPeace: hfCharge, sneaky: false,
                      searchBaseTime: 15.0)
  of pChad:
    PersonalityTraits(aggression: 1.3, courage: 1.25, patience: 0.8,
                      grenadeAffinity: 1.1, coverAffinity: 0.85,
                      canShiftCover: true, canRushReloadHeal: true,
                      willSearch: true, willSearchFromAudio: true,
                      heardFromPeace: hfSearchNow, sneaky: false,
                      searchBaseTime: 25.0)
  of pSnappingTurtle:
    ## Holds cover, then lunges. High aggression *and* high cover affinity is
    ## not a contradiction: the whole character is that it does both.
    PersonalityTraits(aggression: 1.35, courage: 1.1, patience: 1.5,
                      grenadeAffinity: 0.9, coverAffinity: 1.5,
                      canShiftCover: true, canRushReloadHeal: true,
                      willSearch: true, willSearchFromAudio: false,
                      heardFromPeace: hfFreeze, sneaky: true,
                      searchBaseTime: 60.0)
  of pRat:
    PersonalityTraits(aggression: 0.55, courage: 0.8, patience: 2.2,
                      grenadeAffinity: 0.6, coverAffinity: 1.6,
                      canShiftCover: false, canRushReloadHeal: false,
                      willSearch: false, willSearchFromAudio: false,
                      heardFromPeace: hfFreeze, sneaky: true,
                      searchBaseTime: 120.0)
  of pTimmy:
    PersonalityTraits(aggression: 0.7, courage: 0.6, patience: 0.7,
                      grenadeAffinity: 0.4, coverAffinity: 1.1,
                      canShiftCover: false, canRushReloadHeal: false,
                      willSearch: true, willSearchFromAudio: true,
                      heardFromPeace: hfFreeze, sneaky: false,
                      searchBaseTime: 45.0)
  of pCoward:
    PersonalityTraits(aggression: 0.35, courage: 0.35, patience: 1.4,
                      grenadeAffinity: 0.5, coverAffinity: 1.8,
                      canShiftCover: true, canRushReloadHeal: false,
                      willSearch: false, willSearchFromAudio: false,
                      heardFromPeace: hfFreeze, sneaky: true,
                      searchBaseTime: 90.0)
  of pNormal, pNone:
    PersonalityTraits(aggression: 1.0, courage: 1.0, patience: 1.0,
                      grenadeAffinity: 1.0, coverAffinity: 1.0,
                      canShiftCover: true, canRushReloadHeal: true,
                      willSearch: true, willSearchFromAudio: true,
                      heardFromPeace: hfNone, sneaky: false,
                      searchBaseTime: 40.0)

func resolvedFor*(base: Settings; p: Personality; difficulty: float): Settings =
  ## Bake personality and difficulty into a per-bot copy.
  ##
  ## Called once when a bot spawns. Everything downstream compares against a
  ## plain number: no multiply, no branch on personality, no property chain.
  let t = traitsFor(p)
  # Difficulty moves the same dials, more gently: an "impossible" Coward is
  # still a coward, just a more competent one.
  let d = 0.85 + 0.3 * difficulty
  result = base
  result.aggressionMultiplier = t.aggression
  result.engageDistance = base.engageDistance * t.aggression
  result.rushMaxPathDistance = base.rushMaxPathDistance * t.aggression
  result.rushMaxPathDistanceSprint =
    base.rushMaxPathDistanceSprint * t.aggression
  result.creepMaxDistance = base.creepMaxDistance * t.aggression
  result.dogFightPathStart = base.dogFightPathStart * t.aggression
  result.dogFightPathEnd = base.dogFightPathEnd * t.aggression

  # Courage is inverted here on purpose: a braver bot retreats at a *lower*
  # health, so the threshold goes down as courage goes up.
  result.fightBackHealthThreshold = base.fightBackHealthThreshold / t.courage
  result.runAwayHealthThreshold = base.runAwayHealthThreshold / t.courage
  result.suppressionSeekCoverLevel = base.suppressionSeekCoverLevel * t.courage
  result.suppressionPinnedLevel = base.suppressionPinnedLevel * t.courage

  result.holdGroundBaseTime = base.holdGroundBaseTime * t.patience
  result.searchGiveUpSeconds = base.searchGiveUpSeconds * t.patience
  result.shiftCoverResetTime = base.shiftCoverResetTime * t.patience

  # SAIN divides the search delay by the aggression multiplier rather than
  # multiplying by patience; keeping its form matters because an aggressive
  # personality is meant to search *sooner*, not merely more often.
  result.timeBeforeSearch = t.searchBaseTime / t.aggression

  result.grenadeChance = base.grenadeChance * t.grenadeAffinity
  result.maxCoverPathLength = base.maxCoverPathLength * t.coverAffinity

  result.canShiftCoverPosition = t.canShiftCover
  result.canRushEnemyReloadHeal = t.canRushReloadHeal
  result.willSearchForEnemy = t.willSearch
  result.willSearchFromAudio = t.willSearchFromAudio
  result.heardFromPeace = t.heardFromPeace
  result.sneaky = t.sneaky

  # SAIN: ForgetEnemyTime = TimeBeforeSearch + Random(20,60). The midpoint is
  # taken here and the per-bot jitter applied by the caller, so this function
  # stays deterministic and therefore testable.
  result.forgetEnemySeconds = result.timeBeforeSearch + 40.0

  # Difficulty sharpens perception rather than behaviour.
  result.minSeenTimeToEngage = base.minSeenTimeToEngage / d
  result.visionSeenTimeout = base.visionSeenTimeout * d

func rolePersonalityBias*(role: BotRole): Personality =
  ## The personality a bot gets when nothing names one.
  ##
  ## SAIN's fallback is "PMCs 33% Chad, everyone else Normal", after a chain of
  ## forced/nickname/boss lookups. Defaulting everything to Normal throws away
  ## the one piece of information the spawn already carries, so the role is used
  ## instead; the config can still force any of them.
  case role
  of brBoss, brGoon: pGigaChad
  of brRaider: pChad
  of brFollower: pNormal
  of brZombie: pWreckless
  of brScav: pRat
  of brPlayerScav: pNormal
  of brPmc: pChad
