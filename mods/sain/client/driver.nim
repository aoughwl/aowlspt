## The driver: who thinks, when.
##
## SAIN ticks every bot from `GameWorld.DoWorldTick`, every frame, and each
## sub-component decides internally whether it is due. That is thirty-odd
## virtual calls per bot per frame before any work happens, and the work that
## does happen is spread so thin that a frame spike lands wherever several
## timers coincide. The user's stated reason for this whole project is that bot
## AI was the expensive part; this file is where that is answered.
##
## Three decisions, all of them the point:
##
## **A fixed budget per tick.** `maxBotsPerTick` bots are considered each tick,
## in round-robin order. Thirty bots at a budget of eight means every bot is
## reconsidered within four ticks, and — this is the part that matters — the
## per-frame cost is *constant* in the number of bots. A raid that spawns a
## second squad does not cost more per frame, it costs more latency, which is
## invisible and recoverable in a way that a frame spike is not.
##
## **Distance-scaled rates.** A bot 200 metres away with nobody near it is
## reconsidered at a fraction of the rate of one in the player's fight. SAIN has
## `SAINAILimit` for the same purpose and applies it to vision and hearing; here
## it is applied to the decision itself, which is the expensive part.
##
## **Nothing is read that is not used.** A bot whose decision is not due this
## tick is not read from the game at all. In SAIN a sleeping bot still ticks its
## always-update components.
##
## What this file deliberately does *not* do is spread one bot's work across
## ticks. A decision computed from half-stale state is a decision nobody can
## reason about, and the whole ladder for one bot is a few hundred nanoseconds
## once the reads are done — the reads are the cost, and they are what the
## budget rations.

import aowlspt
import ".." / core / vec
import ".." / core / types
import ".." / core / settings
import ".." / core / decide
import ".." / core / enemy
import ".." / core / search
import ".." / core / cover
import ".." / core / rng
import ".." / preset / preset
import bridge

type
  BotState = object
    ## Everything the mod keeps for one bot. One allocation at spawn, none
    ## afterwards: the seqs inside grow to their steady size in the first few
    ## seconds and are compacted in place from then on.
    handle: BotHandle
    settings: Settings
    personality: Personality
    ctx: DecideContext
    enemies: EnemyTable
    searchState: SearchState
    coverSet: CoverSet
    rng: Rng
    lastDecisionAt: float
    lastAppliedCombat: CombatDecision
    ## Where the bot was when it last thought. Kept so the scheduler can band
    ## it by distance to the player without a game read for a bot it is about
    ## to decide not to tick -- which would defeat the whole point.
    lastPosition: Vec3
    alive: bool

var gBots: seq[BotState] = @[]
var gPreset: Preset
var gCursor = 0
var gTimeSeconds = 0.0
var gPlayerPosition = zeroVec()
var gDecisionsMade = 0
var gCallsMade = 0

proc setPreset*(p: Preset) = gPreset = p

proc indexOfBot(id: string): int =
  result = -1
  for i in 0 ..< gBots.len:
    if gBots[i].handle.id == id:
      return i

proc spawnBot*(id: string; handle: Handle; spawnType: string;
               difficulty: float) =
  ## Register a bot. All of its per-raid setup happens here, once.
  ##
  ## This is the payoff for `preset.settingsFor` being a struct copy: a bot
  ## joining a raid in progress costs one copy and one pass of multiplies, not a
  ## config parse and a dictionary walk per settings category the way SAIN's
  ## `GetSAINSettings` does.
  if indexOfBot(id) >= 0:
    return
  let role = roleFromSpawnType(spawnType)
  var r = newRng(hashSeed(id, 0x5A1'u64))
  let personality = personalityFor(gPreset, role, nextFloat(r))
  let s = settingsFor(gPreset, role, personality, difficulty)
  gBots.add BotState(
    handle: BotHandle(id: id, handle: handle, role: role),
    settings: s, personality: personality,
    ctx: newContext(nextFloat(r)),
    enemies: newEnemyTable(), searchState: newSearch(),
    coverSet: newCoverSet(), rng: r,
    lastDecisionAt: 0.0, lastAppliedCombat: cdNone,
    lastPosition: zeroVec(), alive: true)
  if gPreset.logDecisions:
    debug "sain: " & id & " spawned as " & roleName(role) & "/" &
          personalityName(personality)

proc despawnBot*(id: string) =
  ## Compact in place. A raid that spawns and kills a few hundred bots would
  ## otherwise leave the table growing all raid, and every scan of it paying
  ## for the dead.
  var w = 0
  for r in 0 ..< gBots.len:
    if gBots[r].handle.id != id:
      if w != r:
        let keep = gBots[r]
        gBots[w] = keep
      inc w
  if w < gBots.len:
    shrink(gBots, w)
  if gCursor >= gBots.len:
    gCursor = 0

proc botCount*(): int = gBots.len

proc decisionInterval(s: Settings; distanceToPlayer: float): float =
  ## How long until this bot is due again.
  ##
  ## SAIN's decision rate is a flat 10 Hz for every bot in the raid. Ten hertz
  ## is right for the bot the player is fighting and absurd for one on the other
  ## side of the map, and the difference is most of the cost.
  let base = 1.0 / s.decisionHz
  if distanceToPlayer > s.farFromPlayerDistance * 2.0:
    result = base * 10.0
  elif distanceToPlayer > s.farFromPlayerDistance:
    result = base * 4.0
  else:
    result = base

proc buildView(st: BotState; me: SelfView): BotView =
  ## Flatten this bot's state into the record the core reads.
  ##
  ## Copies rather than references, and that is the design: the core cannot
  ## reach back into anything, which is what makes it testable and what would
  ## make it safe to run off the main thread.
  let e = primaryView(st.enemies)
  var sq = SquadView(
    memberCount: 1, aliveCount: 1, isLeader: true, leaderAlive: true,
    leaderDistance: 0.0, nearestMateDistance: 9999.0, mateNeedsHelp: false,
    mateInCombat: false, squadSeesEnemy: false,
    memberTookDamageRecently: false)
  result = BotView(
    id: st.handle.id, role: st.handle.role, personality: st.personality,
    difficulty: 0.5, timeNow: gTimeSeconds, me: me, enemy: e,
    enemyCount: liveCount(st.enemies), squad: sq,
    grenade: GrenadeThreat(active: false, position: zeroVec(),
                           distance: 999.0, secondsToDetonation: 0.0),
    lastSound: skNone, lastSoundPosition: zeroVec(), lastSoundDistance: 0.0,
    timeSinceLastSound: 999.0,
    hasSearchTarget: active(st.searchState),
    searchTarget: st.searchState.target, extractRequested: false)

proc tickBot(index: int) =
  ## One bot's whole decision, start to finish.
  var st = gBots[index]
  let me = readSelf(st.handle)
  st.lastDecisionAt = gTimeSeconds
  st.lastPosition = me.position

  # Perception first: the ladder reads the enemy table, so it has to be current.
  # `forget` is cheap and compacting, and running it here rather than on its own
  # timer means a bot never scans entries it has already stopped believing in.
  forget(st.enemies, st.settings)
  discard choosePrimary(st.enemies, st.settings)

  var view = buildView(st, me)
  let d = decide(st.ctx, view, st.settings)
  inc gDecisionsMade

  # The search state machine only advances while the decision is a search. SAIN
  # ticks its `SearchClass` regardless and guards inside; not entering at all is
  # cheaper and says the same thing.
  if d.combat == cdSearch:
    if not active(st.searchState):
      let e = view.enemy
      begin(st.searchState, me.position, e.position,
            e.realPosition - e.position, gTimeSeconds)
    advance(st.searchState, me.position, st.settings, gTimeSeconds)
  elif active(st.searchState):
    cancel(st.searchState)

  # Cover is only re-ranked when the decision is about cover. This is the
  # amortisation that matters most: `rescore` is O(points) arithmetic and SAIN
  # runs its equivalent on a 10 Hz coroutine per bot whether or not the bot is
  # doing anything with cover.
  if d.combat == cdSeekCover or d.combat == cdShiftCover or
     d.combat == cdHoldInCover or d.combat == cdRetreat:
    discard choose(st.coverSet, me.position, view.enemy.position,
                   st.settings, gTimeSeconds,
                   d.combat == cdRetreat or d.combat == cdRunAway)

  # Only act on a change. A bot already sprinting to cover does not need to be
  # told again every tick, and each telling is an IL2CPP invoke.
  if d.combat != st.lastAppliedCombat:
    let a = actuationFor(d, view)
    gCallsMade = gCallsMade + apply(st.handle, a)
    st.lastAppliedCombat = d.combat
    if gPreset.logDecisions:
      debug "sain: " & st.handle.id & " -> " & decisionName(d.combat) &
            " / " & squadDecisionName(d.squad) & " / " &
            selfActionName(d.self) & "  (" & d.reason & ")"

  gBots[index] = st

proc tick*(elapsedMs: int64) =
  ## Called from `onUpdate`. Constant cost in the number of bots.
  gTimeSeconds = gTimeSeconds + float(int(elapsedMs)) / 1000.0
  if gBots.len == 0:
    return
  let budget = gPreset.base.maxBotsPerTick
  var considered = 0
  var scanned = 0
  # Round-robin from where the last tick stopped, so no bot is starved by the
  # ones ahead of it in the table.
  while scanned < gBots.len and considered < budget:
    let i = gCursor
    gCursor = gCursor + 1
    if gCursor >= gBots.len:
      gCursor = 0
    inc scanned
    let st = gBots[i]
    if not st.alive:
      continue
    let dist = distance(st.lastPosition, gPlayerPosition)
    let due = gTimeSeconds - st.lastDecisionAt >=
              decisionInterval(st.settings, dist)
    if not due:
      continue
    tickBot(i)
    inc considered

proc setPlayerPosition*(p: Vec3) = gPlayerPosition = p

proc stats*(): string =
  result = $gBots.len & " bots, " & $gDecisionsMade & " decisions, " &
           $gCallsMade & " game calls"
