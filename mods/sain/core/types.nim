## The vocabulary of the decision core.
##
## Everything a bot decides is one of these three enums, and everything it
## decides *from* is one of the records below. That split is the whole reason
## this directory exists: `core/` never calls the game, so the decision model
## can be driven from a table of numbers and checked, which is not true of any
## line of the C# this was ported from.
##
## The enum names are SAIN's own (`ECombatDecision`, `ESquadDecision`,
## `ESelfActionType`, `EPersonality`, `CoverStatus`) so that anyone holding the
## original open can follow along.

import vec

type
  CombatDecision* = enum
    ## What the bot is doing about the enemy in front of it. One at a time:
    ## SAIN's combat layer is a priority list, not a blend.
    cdNone
    cdRetreat            ## break contact, hurt or outgunned
    cdSearch             ## no live contact; go and find them
    cdRunAway            ## full flight, not a fighting withdrawal
    cdDogFight           ## enemy inside knife range; no cover, just shoot
    cdSeekCover          ## move to a cover point
    cdStandAndShoot      ## hold this spot and fire
    cdThrowGrenade
    cdShiftCover         ## reposition between cover points
    cdRushEnemy          ## close the distance aggressively
    cdMoveToEngage       ## enemy known but out of usable range
    cdShootDistantEnemy  ## fire at a target too far to approach
    cdAvoidGrenade
    cdFreeze             ## heard something, hold still and listen
    cdCreepOnEnemy       ## slow flank on an unaware enemy
    cdMeleeAttack
    cdHoldInCover        ## in cover, enemy not visible, wait them out

  SquadDecision* = enum
    ## What the squad wants this bot to do. Runs *above* the combat decision:
    ## a squad decision that fires overrides the solo one.
    sdNone
    sdSurround
    sdRetreat
    sdSuppress
    sdPushSuppressedEnemy
    sdBoundingRetreat
    sdRegroup
    sdSpreadOut
    sdHoldPositions
    sdHelp
    sdSearch
    sdGroupSearch

  SelfAction* = enum
    ## What the bot needs to do to itself. Highest priority of the three: a bot
    ## with an empty magazine has no useful combat decision to take.
    saNone
    saReload
    saFirstAid
    saStims
    saSurgery

  Personality* = enum
    ## SAIN's personalities, which are the dial that makes two bots with the
    ## same inputs behave differently. Each one is a set of multipliers over the
    ## thresholds rather than a separate code path.
    pNone
    pWreckless
    pSnappingTurtle
    pGigaChad
    pChad
    pRat
    pTimmy
    pCoward
    pNormal

  CoverStatus* = enum
    csNone
    csFarFromCover
    csMidRangeToCover
    csCloseToCover
    csInCover

  PathDistance* = enum
    ## Banded distance-to-enemy. Bands rather than metres because every use is a
    ## comparison and banding once per tick removes the same comparison from a
    ## dozen decision checks.
    pdNoEnemy
    pdVeryClose
    pdClose
    pdMid
    pdFar
    pdVeryFar

  BotRole* = enum
    ## Coarse bot class. SAIN keys its per-bot-type settings off the full BSG
    ## `WildSpawnType`; this is the grouping the decision core actually reads.
    brScav
    brPmc
    brRaider
    brBoss
    brFollower
    brGoon
    brZombie
    brPlayerScav

  SoundKind* = enum
    skNone, skFootStep, skSprint, skShot, skSuppressedShot, skGrenadePin,
    skExplosion, skDoor, skLooting, skReload, skPain, skHeal, skConversation,
    skBulletImpact

func personalityFromText*(s: string): Personality =
  case s
  of "Wreckless": pWreckless
  of "SnappingTurtle": pSnappingTurtle
  of "GigaChad": pGigaChad
  of "Chad": pChad
  of "Rat": pRat
  of "Timmy": pTimmy
  of "Coward": pCoward
  of "Normal": pNormal
  else: pNone

func personalityName*(p: Personality): string =
  case p
  of pWreckless: "Wreckless"
  of pSnappingTurtle: "SnappingTurtle"
  of pGigaChad: "GigaChad"
  of pChad: "Chad"
  of pRat: "Rat"
  of pTimmy: "Timmy"
  of pCoward: "Coward"
  of pNormal: "Normal"
  of pNone: "None"

func decisionName*(d: CombatDecision): string =
  case d
  of cdNone: "None"
  of cdRetreat: "Retreat"
  of cdSearch: "Search"
  of cdRunAway: "RunAway"
  of cdDogFight: "DogFight"
  of cdSeekCover: "SeekCover"
  of cdStandAndShoot: "StandAndShoot"
  of cdThrowGrenade: "ThrowGrenade"
  of cdShiftCover: "ShiftCover"
  of cdRushEnemy: "RushEnemy"
  of cdMoveToEngage: "MoveToEngage"
  of cdShootDistantEnemy: "ShootDistantEnemy"
  of cdAvoidGrenade: "AvoidGrenade"
  of cdFreeze: "Freeze"
  of cdCreepOnEnemy: "CreepOnEnemy"
  of cdMeleeAttack: "MeleeAttack"
  of cdHoldInCover: "HoldInCover"

func squadDecisionName*(d: SquadDecision): string =
  case d
  of sdNone: "None"
  of sdSurround: "Surround"
  of sdRetreat: "Retreat"
  of sdSuppress: "Suppress"
  of sdPushSuppressedEnemy: "PushSuppressedEnemy"
  of sdBoundingRetreat: "BoundingRetreat"
  of sdRegroup: "Regroup"
  of sdSpreadOut: "SpreadOut"
  of sdHoldPositions: "HoldPositions"
  of sdHelp: "Help"
  of sdSearch: "Search"
  of sdGroupSearch: "GroupSearch"

func selfActionName*(a: SelfAction): string =
  case a
  of saNone: "None"
  of saReload: "Reload"
  of saFirstAid: "FirstAid"
  of saStims: "Stims"
  of saSurgery: "Surgery"

# ---------------------------------------------------------------------------
# What the bot knows
# ---------------------------------------------------------------------------

type
  EnemyView* = object
    ## One enemy, as this bot understands it.
    ##
    ## Note what is *not* here: no game object, no transform, no component. The
    ## client layer flattens the game's view into this once per tick and the
    ## decision core sees nothing else. That is what makes the core testable,
    ## and it is also the performance shape the port wanted -- one pass of reads
    ## per bot instead of a property fetch inside every threshold check.
    id*: string
    valid*: bool
    isPlayer*: bool            ## the human
    alive*: bool
    position*: Vec3            ## last known, not necessarily current
    realPosition*: Vec3        ## true position; only meaningful when visible
    visible*: bool
    canShoot*: bool            ## visible *and* a clear firing line
    heardRecently*: bool
    timeSinceSeen*: float      ## seconds; large when never seen
    timeSinceHeard*: float
    seenTotal*: float          ## seconds of accumulated visual contact
    distance*: float           ## metres, straight line
    pathDistance*: float       ## metres along the navmesh, when known
    band*: PathDistance
    inFieldOfView*: bool       ## they are inside *our* view cone
    ## They are looking at *us*. SAIN reads this off `EnemyStatus.EnemyLookAtMe`
    ## (a dot product against the enemy's forward vector) and it is not the same
    ## question as `inFieldOfView` -- conflating the two is what makes a bot
    ## stand in the open trading shots with someone who has not noticed it.
    lookingAtUs*: bool
    isSuppressed*: bool        ## we are putting fire on them
    suppressingUs*: bool       ## they are putting fire on us
    threatLevel*: float        ## 0..1, decayed; see enemy.nim

  SelfView* = object
    ## The bot's own condition.
    healthNormalized*: float   ## 1.0 = untouched
    energy*: float
    hydration*: float
    stamina*: float
    hasHeavyBleed*: bool
    hasLightBleed*: bool
    hasFracture*: bool
    canHeal*: bool
    canUseStims*: bool
    canDoSurgery*: bool
    ammoInMagazine*: int
    magazineSize*: int
    hasAmmoToReload*: bool
    weaponReady*: bool
    inCoverStatus*: CoverStatus
    coverPointDistance*: float
    suppressionLevel*: float   ## 0..1, how pinned this bot feels
    isSprinting*: bool
    position*: Vec3
    lookDirection*: Vec3

  SquadView* = object
    ## The squad, from this bot's seat in it.
    memberCount*: int
    aliveCount*: int
    isLeader*: bool
    leaderAlive*: bool
    leaderDistance*: float
    nearestMateDistance*: float
    mateNeedsHelp*: bool       ## a squadmate is down or badly hurt
    mateInCombat*: bool
    squadSeesEnemy*: bool
    memberTookDamageRecently*: bool

  GrenadeThreat* = object
    active*: bool
    position*: Vec3
    distance*: float
    secondsToDetonation*: float

  BotView* = object
    ## Everything one decision tick reads. Assembled once, read many times.
    id*: string
    role*: BotRole
    personality*: Personality
    difficulty*: float         ## 0..1; easy..impossible
    timeNow*: float            ## seconds since raid start
    me*: SelfView
    enemy*: EnemyView          ## the current primary enemy
    enemyCount*: int
    squad*: SquadView
    grenade*: GrenadeThreat
    lastSound*: SoundKind
    lastSoundPosition*: Vec3
    lastSoundDistance*: float
    timeSinceLastSound*: float
    hasSearchTarget*: bool
    searchTarget*: Vec3
    extractRequested*: bool

  Decision* = object
    ## The answer. Three simultaneous channels, exactly as SAIN has it: a bot
    ## reloads (self) while falling back (combat) because its squad told it to
    ## (squad), and collapsing that into one enum is what makes bot AI look
    ## stupid at the seams.
    combat*: CombatDecision
    squad*: SquadDecision
    self*: SelfAction
    reason*: string            ## which check fired; for the log, not the game
    holdUntil*: float          ## do not re-decide before this time

func emptyDecision*(): Decision =
  Decision(combat: cdNone, squad: sdNone, self: saNone, reason: "",
           holdUntil: 0.0)

func emptyEnemy*(): EnemyView =
  EnemyView(id: "", valid: false, isPlayer: false, alive: false,
            position: zeroVec(), realPosition: zeroVec(), visible: false,
            canShoot: false, heardRecently: false, timeSinceSeen: 9999.0,
            timeSinceHeard: 9999.0, seenTotal: 0.0, distance: 9999.0,
            pathDistance: 9999.0, band: pdNoEnemy, inFieldOfView: false,
            lookingAtUs: false, isSuppressed: false, suppressingUs: false, threatLevel: 0.0)
