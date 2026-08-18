## The driver: who thinks, when — and who is even there.
##
## SAIN ticks every bot from `GameWorld.DoWorldTick`, every frame, and each
## sub-component decides internally whether it is due. That is thirty-odd
## virtual calls per bot per frame before any work happens, and the work that
## does happen is spread so thin that a frame spike lands wherever several
## timers coincide. The user's stated reason for this whole project is that bot
## AI was the expensive part; this file is where that is answered.
##
## Four decisions, all of them the point:
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
## **Discovery is amortised too.** Walking the world's alive-players list is the
## one piece of work whose cost is linear in the raid's population and cannot be
## made per-bot, so it runs at `ScanIntervalMs` rather than per frame, and it is
## the *reconciler* rather than the primary path — the spawn hook in `sain.nim`
## is what usually registers a bot first. A scan of thirty players is thirty
## bound `get_Item` calls plus one bound `get_IsAI` each, which is under a
## microsecond in total; doing it at 2 Hz rather than 60 is still worth it,
## because the profile-id string read on a *new* player is not.
##
## What this file deliberately does *not* do is spread one bot's work across
## ticks. A decision computed from half-stale state is a decision nobody can
## reason about, and the whole ladder for one bot is a few hundred nanoseconds
## once the reads are done — the reads are the cost, and they are what the
## budget rations.

import aowlspt
import aowlspt/il2cpp
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
import live

const
  ScanIntervalMs = 500'i64
    ## How often the world is walked for bots nobody has told us about. Half a
    ## second is a latency nobody can see on a bot that has just spawned and
    ## has not yet been given a decision, and it is 1/30th of the frames.

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
var gLastScanAt = 0'i64
var gAttached = 0
var gDetached = 0

## The human player, held the same way a bot is: one GC handle, resolved to a
## pointer once per tick. Everything in `decisionInterval` is keyed off distance
## to this position, so a stale one would mis-band every bot in the raid.
var gHumanHandle = 0'u32

proc setPreset*(p: Preset) = gPreset = p

proc indexOfBot(id: string): int =
  result = -1
  for i in 0 ..< gBots.len:
    if gBots[i].handle.id == id:
      return i

proc spawnBot*(id: string; spawnType: string; difficulty: float) =
  ## Register a bot. All of its per-raid setup happens here, once.
  ##
  ## This is the payoff for `preset.settingsFor` being a struct copy: a bot
  ## joining a raid in progress costs one copy and one pass of multiplies, not a
  ## config parse and a dictionary walk per settings category the way SAIN's
  ## `GetSAINSettings` does.
  ##
  ## No game pointer is taken here, and that is deliberate: this is called both
  ## from the spawn hook (which has a host handle the fast path cannot use) and
  ## from the sim (which has no game at all). `attachBot` is the separate step
  ## that gives the record its IL2CPP handle, and the scan does it.
  if indexOfBot(id) >= 0:
    return
  let role = roleFromSpawnType(spawnType)
  var r = newRng(hashSeed(id, 0x5A1'u64))
  let personality = personalityFor(gPreset, role, nextFloat(r))
  let s = settingsFor(gPreset, role, personality, difficulty)
  gBots.add BotState(
    handle: BotHandle(id: id, role: role, gcPlayer: 0'u32),
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
  ##
  ## The handle is released on the way past. Missing that is a leak rather than
  ## a crash -- the object stays pinned for the session -- which is exactly the
  ## kind of failure that never shows up until a long raid.
  var w = 0
  for r in 0 ..< gBots.len:
    if gBots[r].handle.id != id:
      if w != r:
        let keep = gBots[r]
        gBots[w] = keep
      inc w
    else:
      var dying = gBots[r]
      detach(dying.handle)
      gBots[r] = dying
      inc gDetached
  if w < gBots.len:
    shrink(gBots, w)
  if gCursor >= gBots.len:
    gCursor = 0

proc botCount*(): int = gBots.len

proc attachBot(id: string; player: Il2CppPtr) =
  ## Give a registered bot its IL2CPP handle.
  let i = indexOfBot(id)
  if i < 0:
    return
  var st = gBots[i]
  if st.handle.gcPlayer != 0'u32:
    return
  attach(st.handle, player)
  gBots[i] = st
  if st.handle.gcPlayer != 0'u32:
    inc gAttached

# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------

proc scanWorld(nowMillis: int64) =
  ## Reconcile the bot table against the world.
  ##
  ## Three jobs, one walk: find the human (for the distance banding), attach any
  ## bot that has no handle yet, and register any bot the spawn hook never told
  ## us about. Bots that have *died* are not detected here -- `AllAlivePlayersList`
  ## dropping a player is indistinguishable from a scan that ran while the list
  ## was being rebuilt, so death is decided per bot by reading its health
  ## controller in `tickBot`, which cannot be wrong about it.
  if nowMillis - gLastScanAt < ScanIntervalMs:
    return
  gLastScanAt = nowMillis
  if not capable():
    return
  let world = worldObject()
  if world == nil:
    return
  let list = alivePlayers(world)
  if list == nil:
    return
  let n = listLen(list)
  var i = 0
  while i < n:
    let p = listAt(list, i)
    inc i
    if p == nil:
      continue
    if not isAI(p):
      # The human. One handle, taken once; `hold` is not free and this list is
      # walked twice a second.
      if gHumanHandle == 0'u32:
        gHumanHandle = hold(p)
      continue
    # A bot. The profile-id read is the expensive part of this loop -- a bound
    # call plus a UTF-16 to UTF-8 copy -- so it happens once per player per
    # scan and never on the per-bot decision path.
    let id = profileIdOf(p)
    if id.len == 0:
      continue
    let at = indexOfBot(id)
    if at < 0:
      # The spawn hook never fired for this one, or fired before this mod was
      # listening. Registering it with a scav's settings is the safe default:
      # `roleFromSpawnType` says why, and the hook supplies the real role when
      # it does fire first.
      spawnBot(id, "", 0.5)
    attachBot(id, p)

proc updatePlayerPosition() =
  ## One handle lookup and one reflective `Vector3` read per tick, for the whole
  ## raid, rather than per bot. Everything the scheduler does with distance is
  ## keyed off this.
  if gHumanHandle == 0'u32:
    return
  let p = target(gHumanHandle)
  if p == nil:
    # The human's `Player` was collected -- raid over, or a transition. Drop the
    # handle so the next scan takes a fresh one.
    drop(gHumanHandle)
    gHumanHandle = 0'u32
    return
  gPlayerPosition = readVec(gB.pPosition, p)

proc setPlayerPosition*(p: Vec3) = gPlayerPosition = p

# ---------------------------------------------------------------------------
# One bot's tick
# ---------------------------------------------------------------------------

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

proc tickBot(index: int): bool =
  ## One bot's whole decision, start to finish. False when the bot has died and
  ## should be dropped from the table.
  var st = gBots[index]
  # How long since this bot last thought, which is what perception integrates
  # over. Clamped at both ends: the first tick after a spawn would otherwise
  # hand `observe` the whole raid so far as one step of accumulated contact,
  # and a bot that was out of budget for a second should not have a second's
  # worth of threat decay applied in one go either.
  var dt = gTimeSeconds - st.lastDecisionAt
  if dt < 0.016: dt = 0.016
  if dt > 1.0: dt = 1.0

  # This frame's pointers. One `gc_handle_get_target` plus two bound property
  # calls; every read below runs off them with no further indirection.
  let l = liveOf(st.handle)
  if l.ok and not isAlive(l.player):
    return false

  let me = readSelf(st.handle, l)
  st.lastDecisionAt = gTimeSeconds
  st.lastPosition = me.position

  # Perception. The game has already done the visibility work; this folds its
  # answer into the bot's own memory, which is what decays, forgets and ranks.
  if l.ok:
    let obs = observeEnemy(st.handle, l, gTimeSeconds)
    if obs.id.len > 0:
      observe(st.enemies, obs, me.position, me.lookDirection, st.settings,
              gTimeSeconds, dt)

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
  # told again every tick, and each telling is at best a bound call and at worst
  # a reflective one with a boxed Vector3 argument.
  if d.combat != st.lastAppliedCombat:
    let a = actuationFor(d, view)
    gCallsMade = gCallsMade + apply(st.handle, l, a)
    st.lastAppliedCombat = d.combat
    if gPreset.logDecisions:
      debug "sain: " & st.handle.id & " -> " & decisionName(d.combat) &
            " / " & squadDecisionName(d.squad) & " / " &
            selfActionName(d.self) & "  (" & d.reason & ")"

  gBots[index] = st
  result = true

proc tick*(elapsedMs: int64) =
  ## Called from `onUpdate`. Constant cost in the number of bots.
  gTimeSeconds = gTimeSeconds + float(int(elapsedMs)) / 1000.0
  updatePlayerPosition()
  if gBots.len == 0:
    return
  let budget = gPreset.base.maxBotsPerTick
  var considered = 0
  var scanned = 0
  var died = ""
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
    if not tickBot(i):
      # One death per tick is enough: `despawnBot` compacts the table, which
      # would invalidate the cursor and the index this loop is holding. The
      # rest are picked up on the next tick, which is 16 ms away.
      died = gBots[i].handle.id
      break
    inc considered
  if died.len > 0:
    despawnBot(died)

proc scan*(nowMillis: int64) =
  ## The discovery half of the tick, kept separate so `onUpdate` can call it
  ## before `tick` and so the sim can skip it.
  scanWorld(nowMillis)

proc releaseAll*() =
  ## Drop every handle this mod is holding. Called at unload; without it, a
  ## reload of the mod leaks one pinned object per bot plus the human.
  for i in 0 ..< gBots.len:
    var st = gBots[i]
    detach(st.handle)
    gBots[i] = st
  if gHumanHandle != 0'u32:
    drop(gHumanHandle)
    gHumanHandle = 0'u32

proc stats*(): string =
  result = $gBots.len & " bots, " & $gDecisionsMade & " decisions, " &
           $gCallsMade & " game calls, " & $gAttached & " attached, " &
           $gDetached & " released"
