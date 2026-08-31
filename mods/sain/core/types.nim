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
    # Added by this port rather than lifted: SAIN reaches a flank through its
    # navmesh path comparison (`EnemyPath.CanSeeLastCorner` and the flank
    # points its cover finder produces), which needs geometry this mod cannot
    # query. What it *can* do is the arc: a waypoint off the bearing to the
    # enemy, converging. Same behaviour, no navmesh.
    cdFlank
    # SAIN's `ExtractDecisionClass`. The *decision* is expressible here; the
    # destination is not, because exfiltration points come off a controller
    # this mod has no binding for. See `README.md`.
    cdExtract
    # The lowest rung there is: "idle intent". Added by this port, from
    # docs/BOT_AI_OBJECTIVES.md. It is the ONLY decision that fires with no
    # enemy, no noise and no self-care outstanding, and it exists so that
    # `decide` is the SINGLE chooser of a destination -- before it, the server
    # dispatcher issued a second GoToPoint for the same bot and the later call
    # won. Its urgency is below `cdSearch`, so anything at all outranks it.
    cdMoveToObjective

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

  Faction* = enum
    ## Who shoots whom, coarsely. Not read from the game: derived from the
    ## bot's role, because the only use it has here is deciding which nearby
    ## bots count as *this* bot's squad, and for that the role is enough.
    facScav, facPmc, facBoss, facInfected

  DecisionReason* = enum
    ## Which rung of the ladder fired.
    ##
    ## This was a `string` built at the point of the check, and building it was
    ## the only allocation left on the per-decision path -- `"grenade at " &
    ## $distance & "m"` allocates twice per tick per bot for a line nobody
    ## reads unless `logDecisions` is on. An enum costs a byte, says exactly
    ## the same thing, and `reasonText` turns it into the same log line for the
    ## one caller that wants one.
    drNone
    drGrenadeIncoming
    drNoWeaponInReach
    drWeaponNotReady
    drNoContactSearchHeld
    drUnattributedSoundCharge
    drUnattributedSoundSearch
    drUnattributedSoundFreeze
    drNothingToDo
    drDogFight
    drMeleeRange
    drHealthBelowRunAway
    drHurtAndExposed
    drPinnedInCover
    drSuppressedInOpen
    drNotYetAcquired
    drHoldingGroundWithShot
    drDistantTargetHeld
    drDistantTarget
    drEnemyVulnerable
    drFlankStale
    drLostContactPastSearchDelay
    drFrozenListening
    drCoverStale
    drUnawareEnemyNearby
    drKnownOutOfRange
    drInCoverWaiting
    drNoBetterOptionSeekCover
    drSelfAction
    drSquadOrder
    drExtracting
    drSquadObjective

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
  of cdFlank: "Flank"
  of cdExtract: "Extract"
  of cdMoveToObjective: "MoveToObjective"

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

func reasonText*(r: DecisionReason): string =
  ## For the log only. Never called on the decision path.
  case r
  of drNone: "no reason recorded"
  of drGrenadeIncoming: "a grenade is inside the avoid radius"
  of drNoWeaponInReach: "no weapon, enemy in reach"
  of drWeaponNotReady: "weapon not ready"
  of drNoContactSearchHeld: "no contact, search target held"
  of drUnattributedSoundCharge: "charging an unattributed sound"
  of drUnattributedSoundSearch: "searching an unattributed sound"
  of drUnattributedSoundFreeze: "freezing at an unattributed sound"
  of drNothingToDo: "nothing to do"
  of drDogFight: "dogfight"
  of drMeleeRange: "melee range"
  of drHealthBelowRunAway: "health below the run-away threshold"
  of drHurtAndExposed: "hurt and exposed"
  of drPinnedInCover: "pinned in cover"
  of drSuppressedInOpen: "suppressed in the open"
  of drNotYetAcquired: "seen, but not yet acquired"
  of drHoldingGroundWithShot: "holding ground with a shot"
  of drDistantTargetHeld: "still engaging a distant target"
  of drDistantTarget: "distant target"
  of drEnemyVulnerable: "enemy vulnerable and close"
  of drFlankStale: "frontal assault is not working; flanking"
  of drLostContactPastSearchDelay: "lost contact for longer than the search delay"
  of drFrozenListening: "frozen, listening"
  of drCoverStale: "cover has gone stale"
  of drUnawareEnemyNearby: "unaware enemy nearby"
  of drKnownOutOfRange: "known but out of range"
  of drInCoverWaiting: "in cover, waiting"
  of drNoBetterOptionSeekCover: "no better option: seek cover"
  of drSelfAction: "a self action needs doing"
  of drSquadOrder: "the squad said so"
  of drExtracting: "hurt, dry and out of reasons to stay"
  of drSquadObjective: "nothing to fight; the squad has somewhere to be"

func factionOf*(r: BotRole): Faction =
  case r
  of brPmc, brRaider: facPmc
  of brBoss, brGoon, brFollower: facBoss
  of brZombie: facInfected
  of brScav, brPlayerScav: facScav

func hostile*(a, b: Faction): bool =
  ## The infected are hostile to everything including each other; everything
  ## else is hostile to a different faction and friendly to its own. Coarse on
  ## purpose: the only thing this decides is whose position counts as a
  ## squadmate's, and being wrong about a scav's opinion of a boss costs a
  ## slightly wider squad rather than a wrong decision.
  if a == facInfected or b == facInfected: return true
  result = a != b

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
    ## The identity the table is keyed on.
    ##
    ## `id` is the profile id, which is a managed string: reading one per bot
    ## per tick is a UTF-16 to UTF-8 conversion and an allocation on the hot
    ## path. The *pointer* to the enemy's `Player` is already in hand, is
    ## stable for as long as the object lives, and compares in one instruction.
    ## So the key is the pointer and `id` is filled once, when the entry is
    ## created, for the log. In the pure tests the key is any distinct number.
    key*: uint64
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

    # -- The acquisition model. See `core/vision.nim`.
    #
    # How well this bot has *acquired* the enemy, 0..1, as distinct from
    # whether the engine's raycast reached them. The game answers "is there a
    # clear line"; SAIN's `EnemyVision` answers "and has this bot noticed",
    # which is a different question with a time constant on it, and it is the
    # single biggest difference between a bot that feels human and one that
    # snaps onto you the frame you step out.
    awareness*: float
    ## Absolute time before which this bot may not act on the contact. Set once
    ## when awareness first crosses the engage threshold; this is the reaction
    ## delay, and it is where difficulty is actually felt.
    reactionUntil*: float
    ## How far the last known place could be wrong by now, in metres. Grows
    ## with time since contact at an assumed walking speed, and is what makes a
    ## search widen instead of pointing at a stale dot.
    uncertainty*: float
    ## Estimated velocity, from consecutive observations. Feeds the search's
    ## "push past in the direction they went" phase.
    velocity*: Vec3
    ## How loud the last thing this bot heard from them was, 0..1 relative to
    ## its own hearing range. Distinguishes a sprint two rooms away from a
    ## footstep on the other side of a wall.
    heardLoudness*: float

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
    ## Where the cover point the bot is using (or heading for) actually is.
    ## The ladder needs it to answer "retreat to *where*", and until it existed
    ## a retreating bot was sent away from the enemy on a bearing with no
    ## regard for whether there was anything behind it.
    coverPosition*: Vec3
    hasCoverPoint*: bool
    suppressionLevel*: float   ## 0..1, how pinned this bot feels
    isSprinting*: bool
    position*: Vec3
    lookDirection*: Vec3
    ## Metres per second, from consecutive positions. Not read from the game --
    ## `MovementContext` exposes a velocity but binding a second `Vector3`
    ## getter to learn something two subtractions already give is the wrong
    ## trade. Used by the flank and spread geometry and by the stall detector.
    velocity*: Vec3
    ## Seconds since this bot's health last fell. Derived here rather than
    ## read: a health delta is the only damage signal this mod has, and it is a
    ## reliable one.
    timeSinceDamaged*: float
    ## How much health was lost in the last second, as a fraction. Feeds the
    ## suppression accumulator -- being hit is the strongest suppressor there
    ## is and the only one that needs no new binding.
    recentDamage*: float

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
    ## Where the nearest squadmate is. Read by the flank, which sends two bots
    ## of the same squad round opposite sides -- the cheapest squad tactic in
    ## the mod, and it falls out of one position and a dot product.
    nearestMatePosition*: Vec3
    haveMate*: bool

  GrenadeThreat* = object
    active*: bool
    position*: Vec3
    distance*: float
    secondsToDetonation*: float

  BotView* = object
    ## Everything one decision tick reads. Assembled once, read many times.
    ##
    ## No `id` field. It was a `string`, copied out of the bot's record into a
    ## fresh `BotView` on every decision -- a heap copy per bot per tick for
    ## something only the debug log reads, and the log has the record in hand
    ## anyway. The rule this file follows is that nothing on the per-decision
    ## path owns memory.
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
    ## Seconds since the raid started, as this bot has observed them. Used only
    ## by the extract check, which is the one decision that is about the clock
    ## rather than about the fight.
    raidSeconds*: float
    ## Where the bot would go if it acted on this decision. Computed by the
    ## ladder's geometry helpers rather than by the actuator, so that a test
    ## can assert a bot flanks *to the correct side* and not merely that it
    ## chose to flank.
    moveTarget*: Vec3
    hasMoveTarget*: bool
    ## The squad's shared objective, already resolved to THIS member's own
    ## destination by `core/objective.objectiveFor`. Filled by the driver
    ## before `decide` runs, because only the driver knows the bot's group
    ## pointer; read by the lowest cascade rung and by nothing else.
    ##
    ## `false` is the ordinary case and is not a failure: objectives are off by
    ## default, the catalog may be empty, and a bot in a fight is not given
    ## one at all.
    hasObjective*: bool
    objectiveTarget*: Vec3

  Decision* = object
    ## The answer. Three simultaneous channels, exactly as SAIN has it: a bot
    ## reloads (self) while falling back (combat) because its squad told it to
    ## (squad), and collapsing that into one enum is what makes bot AI look
    ## stupid at the seams.
    combat*: CombatDecision
    squad*: SquadDecision
    self*: SelfAction
    reason*: DecisionReason    ## which check fired; for the log, not the game
    holdUntil*: float          ## do not re-decide before this time
    ## Where this decision wants the bot to go, when it wants it anywhere. The
    ## ladder computes it because only the ladder knows *why*; the actuator
    ## would have to re-derive the reason to compute it.
    moveTo*: Vec3
    hasMove*: bool

func emptyDecision*(): Decision =
  Decision(combat: cdNone, squad: sdNone, self: saNone, reason: drNone,
           holdUntil: 0.0, moveTo: zeroVec(), hasMove: false)

func emptyEnemy*(): EnemyView =
  EnemyView(key: 0'u64, valid: false, isPlayer: false, alive: false,
            position: zeroVec(), realPosition: zeroVec(), visible: false,
            canShoot: false, heardRecently: false, timeSinceSeen: 9999.0,
            timeSinceHeard: 9999.0, seenTotal: 0.0, distance: 9999.0,
            pathDistance: 9999.0, band: pdNoEnemy, inFieldOfView: false,
            lookingAtUs: false, isSuppressed: false, suppressingUs: false,
            threatLevel: 0.0, awareness: 0.0, reactionUntil: 0.0,
            uncertainty: 0.0, velocity: zeroVec(), heardLoudness: 0.0)
