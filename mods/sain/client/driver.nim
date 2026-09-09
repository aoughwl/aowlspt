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
import aowlspt/fast
import ".." / core / vec
import ".." / core / types
import ".." / core / settings
import ".." / core / decide
import ".." / core / enemy
import ".." / core / search
import ".." / core / cover
import ".." / core / probe
import ".." / core / rng
import ".." / core / hearing
import ".." / core / suppress
import ".." / core / squad
import ".." / core / objective
import ".." / preset / preset
import bridge
import live
import coverprobe
import drivecalls
import mainthread

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
    ## The suppression accumulator. See `core/suppress.nim` for why the game's
    ## `IsUnderFire` bool is integrated here rather than used directly.
    sup: Suppression
    ## The identity of the enemy this bot had last tick. Compared against the
    ## pointer the game hands back so that the enemy's profile-id string -- the
    ## last allocation on the perception path -- is read once per enemy rather
    ## than once per tick.
    enemyKey: uint64
    ## `BotOwner.BotsGroup` as an identity, or 0 when that binding refused.
    groupKey: uint64
    ## Where this bot was on the previous decision, for the velocity estimate.
    ## Two subtractions rather than a second bound `Vector3` getter.
    prevPosition: Vec3
    lastHealth: float
    lastDamagedAt: float
    ## `BotOwner.AimingData` as an identity, cached.
    ##
    ## The aim postfix in `sain.nim` is handed the aim component as `this`, so
    ## attributing a reading to a bot means holding the component's address to
    ## compare against. It is derived with one bound call, and only when the
    ## table has no fresh reading under the address already held -- which in a
    ## raid where the hook is working is never. Zero means "not derived yet";
    ## it is not held across a detach, because `spawnBot` builds a fresh state.
    aimKey: uint64
    ## The last readiness this bot's aim component reported, and when.
    ##
    ## `aimAt` is a `perfCounter` reading taken on the *game's* thread inside
    ## the handler, which is why it is ticks rather than `gTimeSeconds`: the
    ## handler has no business reading this module's clock, and the two threads
    ## would race on it if it did.
    aimReady: bool
    aimAt: int64
    ## Damage told to us by the hook and not yet credited to the accumulator.
    ## Summed on the drain, spent on the next decision, cleared either way.
    pendingDamage: float
    ## WHO last shot this bot, and when, as the enemy table keys enemies: an
    ## `EFT.Player` address. Written only by `drainDamage`, and only after the
    ## candidate matched a player this mod already holds, so a foreign read
    ## cannot land here.
    lastShooterKey: uint64
    lastShotAt: float
    ## Per-raid census flags. One-shot per bot, so the counts they feed are
    ## DISTINCT BOTS rather than ticks -- "1,400 reads" across one bot and
    ## across forty are different facts and a tick count cannot separate them.
    everRead: bool
    everEnemy: bool
    everInCover: bool
    seesEnemy: bool
    inCombat: bool
    lastDecisionAt: float
    lastAppliedCombat: CombatDecision
    # Where the bot was last *told* to go, and when.
    #
    # Applying only on a decision change was right while every decision had at
    # most one destination -- the enemy. It stopped being right the moment
    # `decide.moveTargetFor` started producing a destination that moves *within*
    # a decision: a search advances through its phases, a flank recomputes its
    # arc as the bot travels, and a bot told once would walk to the first
    # waypoint and stop there for the rest of the search.
    lastAppliedMove: Vec3
    lastApplyAt: float
    ## Where the bot was when it last thought. Kept so the scheduler can band
    ## it by distance to the player without a game read for a bot it is about
    ## to decide not to tick -- which would defeat the whole point.
    lastPosition: Vec3
    ## When this bot's cover set was last sampled, and from where.
    ##
    ## Both are staleness tests rather than bookkeeping. Cover is geometry and
    ## geometry does not move, so a set stays good until the *bot* moves --
    ## which is why the position matters more than the clock here, and why a
    ## bot standing still is never re-sampled at all.
    coverAt: float
    coverFrom: Vec3
    alive: bool
    ## THE BEHAVIOURAL ACCEPTANCE WITNESS (§9b), and it is deliberately not a
    ## structural one. "The call returned true" is a property of our own write;
    ## the only thing that settles whether this mod drives a bot is whether the
    ## bot's position CHANGED after we told it to move, read back out of the
    ## game on a later tick.
    ##
    ## `witnessAt` is when an order that asked for locomotion was issued, or
    ## <= 0 when none is outstanding. `witnessFrom` is where the bot stood at
    ## that instant. Both come from readings this tick already took, so the
    ## witness costs no extra game call -- which matters, because an acceptance
    ## test that perturbs the thing it measures is not one.
    witnessAt: float
    witnessFrom: Vec3

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

## The human's previous position and the time it was taken, for the hearing
## model. This is the whole sensor: a player who moved eight metres in one
## second was sprinting, and sprinting is loud. `core/hearing.nim` says why
## deriving the sound beats waiting for an event this mod cannot subscribe to.
var gPlayerPrev = zeroVec()
var gPlayerSprint = false
var gPlayerSound = emptySound()

## The nearest grenade to the *raid*, sampled once per tick rather than once
## per bot. Distance to it is then per bot and free.
var gGrenadeAt = zeroVec()
var gGrenadeLive = false

## The ally table, rebuilt in place each tick. `gAlliesN` is how many entries
## are live; the sequence itself only ever grows, to the raid's high-water
## mark, so a steady-state tick allocates nothing.
var gAllies: seq[Ally] = @[]
var gAlliesN = 0

## Peak per-tick cost, in bots considered, for the stats line.
var gPeakConsidered = 0

## Whether a detour on the game's own death notification took.
##
## When it did, `tickBot` stops asking every bot every tick whether it is still
## alive -- which was two bound calls per bot per decision, and the largest
## single piece of per-bot game work this mod did that was not about deciding
## anything. When it did not, the poll stays, because the alternative is a mod
## that never notices a bot died.
var gDeathHooked = false

proc setDeathHooked*(v: bool) = gDeathHooked = v
proc deathHooked*(): bool = gDeathHooked

const DeathQueueSize = 64
  ## A fixed ring, because the alternative is allocating on the game's thread.
  ## Sixty-four deaths between two ticks is far past anything a raid produces;
  ## an overflow drops the oldest, and the health poll is not the fallback for
  ## that -- the *next* `liveOf` for that bot returns a null target, which is
  ## also death, half a second later.

## Written by the hook handler, drained by `tick`.
##
## **These are two different threads.** The handler runs on whichever thread
## called the game's method -- Unity's -- and `tick` runs on the host's own
## attached thread. What makes a plain array safe here is that the only shared
## mutable state is one write index and 64 aligned 64-bit words: an aligned
## 64-bit store is not torn on x64, the writer only ever moves the index
## forward, and the reader only ever consumes up to the index it read once. The
## worst outcome of losing the race is a death noticed one tick later, which is
## the same 16 ms the poll would have cost. Nothing here allocates, and nothing
## here calls back into the mod.
var gDeadRing: array[DeathQueueSize, uint64]
var gDeadWrite = 0
var gDeadRead = 0

proc noteDeath*(who: uint64) =
  ## Called from the death hook, on the game's thread, with the address of the
  ## player that died. Records and returns: identifying *which bot* that is
  ## means walking the bot table, and walking the bot table on the game's
  ## thread while the host's thread is compacting it is the one thing this
  ## queue exists to avoid.
  if who == 0'u64:
    return
  gDeadRing[gDeadWrite mod DeathQueueSize] = who
  gDeadWrite = gDeadWrite + 1

# ---------------------------------------------------------------------------
# The aim reading, and why it is a table rather than a queue
# ---------------------------------------------------------------------------
#
# `sain.nim` puts a typed postfix on the bot aim component's readiness getter.
# That method is called by the game once per bot per frame, which is the rate
# the whole typed path exists for -- and it is also the rate that rules out the
# shape `noteDeath` uses. A queue drained once per tick would take sixty
# entries per bot per second and the drain would be O(entries x bots); a death
# queue can be that shape because deaths per tick are almost always zero.
#
# So the reading is not queued, it is *stored*. A fixed, direct-mapped table
# keyed on the aim component's address: the handler computes one index, writes
# three aligned 64-bit words and returns. Nothing is scanned, nothing is
# allocated, and there is no drain at all.
#
# **Direct-mapped, with no probing, deliberately.** Two components that land on
# the same slot means one of them overwrites the other, and the loser reads no
# fresh entry for itself -- which `aimGateFor` treats as "no reading", and the
# bot shoots exactly as it does on a host with no hook at all. A probe sequence
# would trade that for a loop on the game's thread and a worse failure when it
# ran off the end. Failing open is the correct failure for a gate that can only
# ever *withhold* a shot.
#
# **Two threads, again.** The handler runs on whichever thread the game called
# the aim from; `tickBot` runs on the host's. The shared state is three aligned
# 64-bit words per slot, and an aligned 64-bit store is not torn on x64. A
# reader that catches a half-updated slot sees a key that does not match its
# own -- because the key is written last -- and treats it as no reading.

const AimSlots = 64
  ## A power of two so the index is a mask rather than a divide, and far more
  ## than the forty-odd bots a raid runs, so collisions are rare rather than
  ## structural.

var gAimAt: array[AimSlots, int64]      ## `perfCounter` ticks, game thread
var gAimReady: array[AimSlots, uint64]  ## 1 when the aim had settled
var gAimKey: array[AimSlots, uint64]    ## the component address; written last
var gAimHooked = false
var gAimGated = 0
  ## How many times a shot was withheld because the aim had not settled. The
  ## one number that says whether this sensor is doing anything.
var gAimNoted = 0
  ## How many times the postfix FIRED. Counted separately from `gAimGated`
  ## because the two answer different questions and collapsing them hid the
  ## interesting failure: a hook that arms and never fires -- which is exactly
  ## what the old postfix on `EFT.BotAimingData::get_IsReady` did, on a class
  ## nothing in the image ever returns -- looks identical, in `gAimGated`
  ## alone, to a hook that fires constantly and finds every bot already
  ## settled. `gAimNoted == 0` in a raid with bots is the falsifiable statement
  ## that the re-pointed hook is on the wrong address after all.
var gAimMatched = 0
  ## How many times a reading was FOUND under the address the two-hop walk
  ## produced. The third distinct number, and the one that settles whether the
  ## key matches: `gAimNoted > 0` with `gAimMatched == 0` means the postfix
  ## fires and the walk is keying on the wrong object, which is a different
  ## bug from either of the other two and used to be indistinguishable.
var gAimSaid = false
var gAimFirstKey = 0'u64
var gAimFirstReady = false

proc setAimHooked*(v: bool) = gAimHooked = v
proc aimHooked*(): bool = gAimHooked

func aimSlotOf(key: uint64): int =
  ## The low four bits of an object address are alignment and carry no
  ## information, so they are shifted out before the mask.
  int((key shr 4) and uint64(AimSlots - 1))

proc noteAim*(who: uint64; ready: bool) =
  ## Called from the aim postfix, on the game's thread, with the aim
  ## component's address and the readiness it just returned.
  ##
  ## Three stores and a return. It does not touch the bot table, does not call
  ## the game, does not allocate and does not log: everything that has to look
  ## at a bot happens on the host's thread, in `aimGateFor`.
  if who == 0'u64:
    return
  let i = aimSlotOf(who)
  gAimNoted = gAimNoted + 1
  if not gAimSaid:
    # The FIRST firing only, and stashed rather than logged: this runs on
    # whichever thread the game called the getter from, and the host's log is
    # not this proc's to touch. `aimAnnounce`, on the host's thread, prints it.
    gAimFirstKey = who
    gAimFirstReady = ready
  gAimAt[i] = perfCounter()
  gAimReady[i] = (if ready: 1'u64 else: 0'u64)
  # Last, and that order is load-bearing: a reader matches on the key, so the
  # key must never name a slot whose reading is still the previous component's.
  gAimKey[i] = who

const AimFreshNs = 300_000_000'i64
  ## How old a reading may be and still gate a shot: 300 ms.
  ##
  ## Long enough that a bot whose aim component was not asked for a few frames
  ## is not un-gated by a hitch, short enough that a bot whose component was
  ## replaced -- or whose slot was taken by a collision -- returns to the
  ## un-hooked behaviour within a fifth of a second rather than being silently
  ## stopped from shooting for the rest of the raid.

proc aimReadingFor(key: uint64; ready: var bool): bool =
  ## The stored reading for one aim component, if there is a fresh one.
  ##
  ## False means "no reading", which every caller must treat as "do not gate".
  ## That is the whole safety argument for this sensor: it is only ever
  ## consulted to *withhold* a shot the decision already ordered, so an absent
  ## reading leaves the mod behaving exactly as it does without the hook.
  ready = false
  if key == 0'u64 or not gAimHooked:
    return false
  let i = aimSlotOf(key)
  if gAimKey[i] != key:
    return false
  if nanosBetween(gAimAt[i], perfCounter()) > AimFreshNs:
    return false
  ready = gAimReady[i] != 0'u64
  gAimMatched = gAimMatched + 1
  result = true

proc aimHexU64(v: uint64): string =
  ## A local, capped hex formatter. Sixteen iterations, no allocation past the
  ## string itself, and it exists here rather than reaching into `live.nim`
  ## because `rvaHexs` there is unexported and widening its surface for one log
  ## line is a worse trade than fourteen lines of arithmetic.
  const D = "0123456789abcdef"
  if v == 0'u64:
    return "0"
  var n = v
  var buf = ""
  var guard = 0
  while n > 0'u64 and guard < 16:
    buf.add D[int(n and 15'u64)]
    n = n shr 4
    inc guard
  result = ""
  var i = buf.len - 1
  while i >= 0:
    result.add buf[i]
    dec i

proc aimAnnounce*() =
  ## The readback for the re-pointed aim postfix, once, on the HOST's thread.
  ##
  ## It asserts a property of the finished state rather than of our own write:
  ## that a reading exists, deposited by the game calling a method we did not
  ## call, carrying an address and a bool. It cannot fire if the postfix never
  ## fires, which is the failure the old hook had and could not report.
  if gAimSaid or gAimNoted <= 0:
    return
  gAimSaid = true
  info "sain: AIM POSTFIX FIRED -- " & $gAimNoted & " reading(s) so far. " &
       "First: aiming node 0x" & aimHexU64(gAimFirstKey) & " reported IsReady=" &
       (if gAimFirstReady: "true" else: "false") &
       ". This is the game calling Aiming::get_IsReady @0x1AD48C0 on its own " &
       "schedule; nothing here called it. A reading is only USED when the " &
       "two-hop walk BotOwner -> AimingManager -> CurrentAiming produces this " &
       "same address -- see the matched count in the status line, which is " &
       "the number that says the key lines up."

# ---------------------------------------------------------------------------
# Damage, told rather than inferred
# ---------------------------------------------------------------------------
#
# A ring, like the deaths, and for the same reason: a hit is an *event*, it
# happens rarely enough per tick that a queue is the cheap shape, and the
# matching it needs -- an address against every bot's -- is work that belongs
# on the host's thread rather than inside a method the game is in the middle
# of.
#
# The rate is worth stating precisely, because `README.md` used to get it
# wrong. Damage is not per bot per frame. It is per *hit*: zero on the
# overwhelming majority of ticks, and a burst of a dozen in the tick where a
# full-auto magazine goes into a squad. That distribution is exactly the one a
# JSON payload is worst at -- affordable on average, a spike precisely when the
# frame is already the busiest it will be all raid.

const DamageQueueSize = 64
  ## Overflowing drops the oldest, and the consequence is small and stated: a
  ## bot is suppressed by the hits that fit rather than by all of them, and the
  ## health delta in `feed` still accounts for the rest at the next decision.

var gDmgWho: array[DamageQueueSize, uint64]
var gDmgAmount: array[DamageQueueSize, float]
var gDmgShooter: array[DamageQueueSize, uint64]
  ## The CANDIDATE address of whoever produced the hit, walked out of the
  ## `DamageInfo` by `live.shooterFromDamageInfo`, or 0 when the walk refused.
  ## It is a candidate and not an identity: see that proc for why, and see
  ## `drainDamage` for the match that is allowed to reject it.
var gShotMatched = 0
var gShotUnmatched = 0
var gDmgWrite = 0
var gDmgRead = 0
var gDmgHooked = false
var gDmgEvents = 0

proc setDamageHooked*(v: bool) = gDmgHooked = v
proc damageHooked*(): bool = gDmgHooked

proc shotCounters*(matched, unmatched: var int) =
  ## How many queued shooter candidates were credited to a bot this mod is
  ## tracking, and how many matched nothing. THE SECOND NUMBER IS THE CHECK.
  ## `DamageInfo.Player` is declared as an interface and this build cannot ask
  ## a live object its type, so a wrong implementor would make the walk read a
  ## foreign field and answer a plausible address. Such an address matches no
  ## bot and lands in `unmatched`. A census where unmatched dwarfs matched is
  ## the signal that the walk is wrong -- which is a thing this instrument can
  ## say, unlike a bare "shots seen" count.
  matched = gShotMatched
  unmatched = gShotUnmatched

proc noteDamage*(who: uint64; amount: float; shooter: uint64 = 0'u64) =
  ## Called from the damage postfix, on the game's thread, with the victim's
  ## address and how much it lost -- or 0.0 when the method's declared shape
  ## carried no number this mod was willing to read.
  ##
  ## A zero-amount event is still recorded, and that is the point of accepting
  ## one: "this bot was hit, now" is most of what suppression wants, and it is
  ## exact. `drainDamage` turns it into the smallest step the accumulator has.
  if who == 0'u64:
    return
  gDmgWho[gDmgWrite mod DamageQueueSize] = who
  gDmgAmount[gDmgWrite mod DamageQueueSize] = amount
  gDmgShooter[gDmgWrite mod DamageQueueSize] = shooter
  gDmgWrite = gDmgWrite + 1

# ---------------------------------------------------------------------------
# Cover: sampled on Unity's thread, decided on this one
# ---------------------------------------------------------------------------
#
# The last sensor in this mod to be built, and the only one whose reading is
# taken by *calling the engine* rather than by reading a managed field. That
# one difference decides everything about its shape.
#
# **Why it cannot be read inline.** `Physics.Raycast` touches Unity's scene
# state, and doing that from a thread that is not the player loop is not a
# wrong number, it is a crash. `onMainThread` reaches the right thread now --
# the host detours a per-frame method and drains from inside it -- so the
# sample goes there and the *decision* stays here, where it has always been:
# `core/probe.nim` plans the sample and folds the answers back in, both as
# arithmetic over numbers, and `core/cover.nim` scores what comes out exactly
# as it already did.
#
# **The budget, stated and enforced.** One sample is in flight at a time, and
# one is posted at most every `CoverSampleIntervalMs`. That is the whole
# rationing, and its important property is what it is *not* proportional to:
#
#   * A sample is at most `RaysPerSample` raycasts plus at most
#     `ProbeCandidates` navmesh samples -- 16 and 8 with the constants
#     `core/probe.nim` holds, and fewer in the common case, because a candidate
#     whose chest ray is clear costs one ray and nothing else.
#   * At one sample per 100 ms that is at most 240 engine calls a second, which
#     is four a frame at 60 fps, landing in bursts of 24 on one frame in six.
#   * **None of those numbers contains the number of bots.** Forty bots cost
#     the same per frame as four; what they cost is refresh *latency*, exactly
#     as the decision budget in this file trades the same way. A bot's set is
#     re-sampled every `bots * 100 ms` in the worst case, and geometry does not
#     move in four seconds.
#
# **Why it is safe across the two threads.** The same argument as the aim
# table, and narrower. There is one job at a time; the host's thread writes the
# plan and then sets `gProbeBusy`, the game's thread writes the answers and
# then sets `gProbeDone`, and each flag is written *after* the data it
# describes. Neither side touches the bot table from the other's thread: the
# job knows nothing but eight rays.
#
# **Why it can be posted at all.** `mainthread.refreshMainThread` asks the host
# whether its drain has actually fired. Until it answers yes, no sample is ever
# posted and the cover decisions stay exactly as unreachable as they were --
# which is also what happens on a build where `Physics::Raycast` refused.

const
  CoverSampleIntervalMs = 100'i64
    ## The rate limit, and the entire frame budget of this sensor. See above
    ## for what it buys; the short version is that it is a rate rather than a
    ## per-bot cost, so it does not grow with the raid.
  CoverResampleMoved = 9.0
    ## Squared metres. A bot that has moved three metres since its set was
    ## sampled is asking about different geometry; one that has not is not.
  CoverResampleAfter = 6.0
    ## Seconds. The backstop for a bot that has not moved but whose world has
    ## -- a door, a car, a wall that came down.
  CoverJobTimeout = 2.0
    ## How long a posted sample may stay outstanding before it is abandoned.
    ##
    ## A drain that never runs would otherwise wedge this sensor for the
    ## session with no symptom but silence. Two seconds is far past any frame
    ## and the recovery is to post the next one.

var gProbePlan = emptyPlan()
var gProbeAnswers = emptyAnswers()
var gProbeBot = ""
var gProbeBusy = false
var gProbeDone = false
var gProbePostedAt = -999.0
var gProbeCursor = 0
var gProbeIngested = 0
var gProbeAbandoned = 0
var gProbeGatedOffThread = 0

## Driving: queued here, executed on Unity's thread.
##
## The counterpart of `coverJob` below and the last thing in this mod to move.
## `client/bridge.nim` carries the whole argument for why an order crosses
## threads through a fixed ring; what lives here is the two decisions the
## driver owns -- when a job is posted, and what happens on a host that never
## confirms a Unity thread.
##
## **One job per tick, not one per order.** A job costs a slot in the host's
## scheduler and a trip through `invoke_main`; an order costs a few bound
## calls. So the ring is filled by the whole tick's worth of bots and drained
## once, which makes the per-frame cost of driving proportional to the number
## of *frames* rather than to the number of bots -- the same property the
## decision budget has and for the same reason.
var gDriveJobs = 0
var gDriveGated = 0
var gDrivePosted = 0

# ---------------------------------------------------------------------------
# The acceptance witness: did a bot MOVE because we told it to?
# ---------------------------------------------------------------------------
#
# THREE OUTCOMES, NEVER TWO, and the third is the one this project keeps
# paying for. `gWitnessOrders` counts locomotion orders that were actually
# ISSUED to the game; `gWitnessMoved` counts the ones after which the bot's
# position changed by more than `WitnessMoved` within `WitnessWindow`; and
# `gWitnessStill` counts the ones whose window expired with the bot where it
# started.
#
# So `gWitnessOrders == 0` reads INCONCLUSIVE -- "we never drove" -- and can
# never read PASS. That distinction is the whole point: a raid where the flag
# was off, the drain never fired or no bot ever spawned looks exactly like a
# raid where every call was made and nothing moved, unless the two are counted
# apart. They are counted apart here.
#
# The falsifier is stated so the check can fail: if the driving calls do
# nothing -- a wrong calling convention, a stub, an order the game discards --
# every window expires and `gWitnessStill` equals `gWitnessOrders`, which
# prints FAIL. A bot that wanders on the game's own AI would have to move
# within two seconds of OUR order to fool this, so the verdict is stated as a
# rate rather than a bare yes, and a rate near the ambient one is not a pass.
const WitnessWindow = 2.0       ## seconds an order has to produce motion
const WitnessMoved = 0.25       ## squared metres; 0.5 m of travel

var gWitnessOrders = 0
var gWitnessMoved = 0
var gWitnessStill = 0
var gWitnessLost = 0            ## bot died or went unreadable inside the window

proc driveJob(payload: string): string =
  ## Everything queued, on Unity's thread. Two statements and no state of its
  ## own: `runDrives` owns the ring and the counters.
  discard runDrives(gTimeSeconds)
  result = ""

proc coverJob(payload: string): string =
  ## The whole of what runs on Unity's thread.
  ##
  ## Two statements: take the sample, then say it is taken. The order is
  ## load-bearing -- `gProbeDone` is what the host's thread reads to know the
  ## answers are complete, so it must be written after them.
  runSample(gProbePlan, gProbeAnswers)
  gProbeDone = true
  result = ""

## The human player, held the same way a bot is: one GC handle, resolved to a
## pointer once per tick. Everything in `decisionInterval` is keyed off distance
## to this position, so a stale one would mis-band every bot in the raid.
var gHumanHandle = 0'u32

proc setPreset*(p: Preset) =
  gPreset = p
  # The order ring, zeroed explicitly. Every field of a `DriveOrder` has zero
  # for its empty value, so the loader would leave it correct anyway -- and
  # `live.nim`'s note about a nimony `--app:lib` global is exactly the kind of
  # thing that is true until it is not.
  initDriveQueue()

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
    sup: newSuppression(), enemyKey: 0'u64, groupKey: 0'u64,
    prevPosition: zeroVec(), lastHealth: -1.0, lastDamagedAt: -9999.0,
    aimKey: 0'u64, aimReady: false, aimAt: 0'i64, pendingDamage: 0.0,
    lastShooterKey: 0'u64, lastShotAt: -1.0,
    everRead: false, everEnemy: false, everInCover: false,
    seesEnemy: false, inCombat: false,
    lastDecisionAt: 0.0, lastAppliedCombat: cdNone,
    lastAppliedMove: zeroVec(), lastApplyAt: -999.0,
    lastPosition: zeroVec(), coverAt: -999.0, coverFrom: zeroVec(),
    alive: true, witnessAt: -1.0, witnessFrom: zeroVec())
  if gPreset.logDecisions:
    debug "sain: " & id & " spawned as " & roleName(role) & "/" &
          personalityName(personality)

proc attachPointer*(id: string; player: Il2CppPtr) =
  ## Give a registered bot its IL2CPP handle **now**, from an address a hook
  ## just handed over.
  ##
  ## This is what ABI revision 3 bought. Before it, the spawn hook knew a bot
  ## had activated and could not turn its host `Handle` into the pointer the
  ## fast path needs, so it registered the bot by profile id and the 2 Hz world
  ## scan attached the handle up to half a second later -- half a second in
  ## which the bot existed, was decided about, and was decided about *from
  ## defaults*, because there was nothing to read it through. Now the handle is
  ## taken on the frame the bot spawns and its first decision reads the game.
  ##
  ## A GC handle rather than `pinHandle`: this mod already re-resolves the
  ## handle to an address once per tick (`liveOf`), which is the cheap half of
  ## what pinning buys, and pinning would hold every bot in a raid immovable
  ## for the session. `aowlspt.pinHandle` says as much at its own call site.
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

proc updatePlayerPosition(dt: float) =
  ## One handle lookup and two bound reads per tick, for the whole raid, rather
  ## than per bot. Everything the scheduler does with distance is keyed off
  ## this -- and so, now, is every bot's hearing.
  if gHumanHandle == 0'u32:
    return
  let p = target(gHumanHandle)
  if p == nil:
    # The human's `Player` was collected -- raid over, or a transition. Drop the
    # handle so the next scan takes a fresh one.
    drop(gHumanHandle)
    gHumanHandle = 0'u32
    return
  gPlayerPrev = gPlayerPosition
  gPlayerPosition = readVec(gB.pPosition, p)
  # The receiver for `mcSprint` is the PhysicalBase, not the MovementContext --
  # see the same change in `bridge.readSelf`. The key kept its name; the object
  # its offset is measured against did not.
  let ph = callObj(gB.pPhysical, p)
  if ph != nil:
    gPlayerSprint = callBoolOn(gB.mcSprint, ph, false)
  # The sound the human just made, derived rather than received. One
  # `motionSound` for the raid; every bot then asks `listen` whether it heard
  # it, which is arithmetic on the stack.
  gPlayerSound = motionSound(gPlayerPrev, gPlayerPosition, dt, gPlayerSprint,
                             gTimeSeconds, cast[uint64](p))

proc updateGrenades() =
  ## Sample the world's grenade list once per tick. Empty on essentially every
  ## tick of a raid, and an empty list is one bound `get_Count`.
  gGrenadeLive = false
  if not capable():
    return
  let world = worldObject()
  if world == nil:
    return
  var at = zeroVec()
  # 40 m is well past any avoid radius: the point is to find the nearest one
  # once, not to filter per bot, and the per-bot threshold is applied in the
  # ladder against `grenadeAvoidDistance`.
  if nearestGrenade(world, gPlayerPosition, 40.0, at):
    gGrenadeAt = at
    gGrenadeLive = true

proc rebuildAllies() =
  ## One pass over the bot table, into the shape `core/squad.nim` queries.
  ##
  ## In place: entries are overwritten rather than a new sequence built, so a
  ## steady-state raid allocates nothing here. The sequence grows once, to the
  ## raid's high-water mark of live bots.
  gAlliesN = 0
  var i = 0
  while i < gBots.len:
    let st = gBots[i]
    inc i
    if not st.alive:
      continue
    let a = Ally(key: hashSeed(st.handle.id, 0'u64), groupKey: st.groupKey,
                 role: st.handle.role, position: st.lastPosition,
                 health: st.lastHealth, alive: true,
                 seesEnemy: st.seesEnemy, inCombat: st.inCombat,
                 lastDamagedAt: st.lastDamagedAt)
    if gAlliesN < gAllies.len:
      gAllies[gAlliesN] = a
    else:
      gAllies.add a
    gAlliesN = gAlliesN + 1

proc setPlayerPosition*(p: Vec3) = gPlayerPosition = p

proc wantsCoverSample(st: BotState): bool =
  ## Whether this bot is worth a sample.
  ##
  ## Two gates, and both of them are about not spending engine calls on a bot
  ## that will not use the answer. A bot with no enemy is not going to cover;
  ## a bot whose set was taken from where it is standing already has the
  ## answer. `README.md` says what this misses: a bot that walks into a
  ## building without its decision being about cover keeps a set sampled
  ## outside it until it moves three metres, which it will.
  if not st.alive:
    return false
  let e = primaryView(st.enemies)
  if not e.valid:
    return false
  if gTimeSeconds - st.coverAt >= CoverResampleAfter:
    return true
  result = sqrDistance(st.lastPosition, st.coverFrom) > CoverResampleMoved

proc postCoverSample() =
  ## Pick the next bot that wants a sample and queue one, at the fixed rate.
  ##
  ## Round-robin from `gProbeCursor`, so a bot at the end of the table is not
  ## starved by the ones in front of it -- the same shape and the same reason
  ## as the decision budget above.
  if gProbeBusy or not probeReady():
    return
  if gTimeSeconds - gProbePostedAt < float(int(CoverSampleIntervalMs)) / 1000.0:
    return
  let mt = mainThread()
  if not mt.bound:
    # The host has not confirmed a Unity thread. Not an error and not a
    # refusal: the drain reports `bound` only once it has *fired*, so early in
    # a session this is "not yet". Counted, so the state line can tell "not
    # yet" from "never".
    gProbeGatedOffThread = gProbeGatedOffThread + 1
    return
  var scanned = 0
  while scanned < gBots.len:
    let i = gProbeCursor
    gProbeCursor = gProbeCursor + 1
    if gProbeCursor >= gBots.len:
      gProbeCursor = 0
    inc scanned
    var st = gBots[i]
    if not wantsCoverSample(st):
      continue
    let e = primaryView(st.enemies)
    # The ring is rotated by this bot's own stream so that two bots pinned in
    # the same corner do not propose the same eight points and then both run to
    # whichever scored highest.
    let plan = planProbe(st.lastPosition, e.position, st.settings,
                         int(nextFloat(st.rng) * 8.0) and 7)
    if not plan.valid:
      continue
    gBots[i] = st
    gProbePlan = plan
    gProbeAnswers = emptyAnswers()
    gProbeBot = st.handle.id
    gProbeDone = false
    # Last, and after the plan: the game's thread reads the plan and this is
    # what says the plan is there to read.
    gProbeBusy = true
    gProbePostedAt = gTimeSeconds
    if onMainThread(coverJob) != Ok:
      # The queue refused. Undo rather than wait for the timeout, so the next
      # tick tries again instead of losing two seconds to a job nobody took.
      gProbeBusy = false
    return

proc drainCoverSample() =
  ## Fold a finished sample into its bot's set, on the thread that owns the
  ## table.
  ##
  ## The bot is found by id rather than by index: it may have died between the
  ## post and the drain, and compacting the table moved everything after it.
  ## A sample whose bot is gone is dropped, which costs one wasted sample.
  if not gProbeBusy:
    return
  if not gProbeDone:
    if gTimeSeconds - gProbePostedAt > CoverJobTimeout:
      gProbeBusy = false
      gProbeAbandoned = gProbeAbandoned + 1
    return
  gProbeBusy = false
  gProbeDone = false
  let i = indexOfBot(gProbeBot)
  if i < 0:
    return
  var st = gBots[i]
  discard ingest(st.coverSet, gProbePlan, gProbeAnswers, st.settings,
                 gTimeSeconds)
  st.coverAt = gTimeSeconds
  st.coverFrom = gProbePlan.botPos
  gBots[i] = st
  gProbeIngested = gProbeIngested + 1

proc coverStats*(): string =
  ## What the sensor did, in the terms the budget above is stated in.
  if not probeReady():
    return "cover sampling off -- " & raycastWhy()
  result = "cover: " & $samplesTaken() & " samples, " & $raysCast() & " rays, " &
           $navSamples() & " navmesh queries, " & $gProbeIngested &
           " folded in, " & $gProbeAbandoned & " abandoned"
  let ns = sampleCostNs()
  if ns >= 0'i64:
    result = result & ", " & $ns & " ns a sample on the game's thread"
  else:
    result = result & ", nothing measured: no sample has been taken"
  if gProbeGatedOffThread > 0:
    result = result & "; " & $gProbeGatedOffThread &
             " posts held back while the host's main-thread drain had not " &
             "fired"

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

proc buildView(st: BotState; me: SelfView; heard: Heard): BotView =
  ## Flatten this bot's state into the record the core reads.
  ##
  ## Copies rather than references, and that is the design: the core cannot
  ## reach back into anything, which is what makes it testable and what would
  ## make it safe to run off the main thread.
  let e = primaryView(st.enemies)

  # The squad, from this mod's own table rather than from a binding. One pass
  # over the live bots; see `core/squad.nim` for why that is both cheaper and
  # more available than enumerating `BotsGroup`.
  let mine = Ally(key: hashSeed(st.handle.id, 0'u64), groupKey: st.groupKey,
                  role: st.handle.role, position: me.position,
                  health: me.healthNormalized, alive: true,
                  seesEnemy: st.seesEnemy, inCombat: st.inCombat,
                  lastDamagedAt: st.lastDamagedAt)
  let sq = squadViewFor(mine, gAllies, gAlliesN, st.settings, gTimeSeconds)

  # This bot's ordinal within its own squad, and it must be STABLE: the role
  # ring hands out one offset per index, so an index that changed with the
  # table's ordering would move a bot between the cover slot and the stagger
  # slot every tick and it would never arrive at either. Counting mates whose
  # key sorts below ours is stable because the keys are.
  var memberIndex = 0
  var mi = 0
  while mi < gAlliesN and mi < gAllies.len:
    let a = gAllies[mi]
    inc mi
    if sameSquad(mine, a, st.settings) and a.key < mine.key:
      inc memberIndex

  # The objective, resolved to THIS member's destination. Done here rather
  # than in `core/decide.nim` because the group pointer lives on this side;
  # `decide` reads the answer and is still the only thing that chooses whether
  # to act on it.
  var objRole = omConverge
  var objDest = zeroVec()
  let haveObjective = objectiveFor(st.groupKey, mine.key, memberIndex,
                                   sq.isLeader, me.position, st.settings,
                                   gTimeSeconds, objRole, objDest)

  # The grenade, from the raid-level sample. Distance is per bot and is two
  # subtractions.
  var gren = GrenadeThreat(active: false, position: zeroVec(),
                           distance: 999.0, secondsToDetonation: 0.0)
  if gGrenadeLive:
    let d = distance(me.position, gGrenadeAt)
    if d < st.settings.grenadeAvoidDistance * 2.0:
      gren = GrenadeThreat(active: true, position: gGrenadeAt, distance: d,
                           # No fuse is readable, and inventing one would make
                           # the avoid decision depend on a number this mod
                           # made up. The ladder only tests `active` and
                           # `distance`, so the fuse stays at zero and is not
                           # used by anything.
                           secondsToDetonation: 0.0)

  result = BotView(
    role: st.handle.role, personality: st.personality,
    difficulty: 0.5, timeNow: gTimeSeconds, me: me, enemy: e,
    enemyCount: liveCount(st.enemies), squad: sq,
    grenade: gren,
    lastSound: (if heard.audible: gPlayerSound.kind else: skNone),
    lastSoundPosition: heard.position,
    lastSoundDistance: heard.distance,
    timeSinceLastSound: (if heard.audible: gTimeSeconds - gPlayerSound.at
                         else: 999.0),
    hasSearchTarget: active(st.searchState),
    searchTarget: st.searchState.target, extractRequested: false,
    raidSeconds: gTimeSeconds, moveTarget: zeroVec(), hasMoveTarget: false,
    hasObjective: haveObjective, objectiveTarget: objDest)

const FiredAtUsWindow = 1.0
  ## How long a hit stays "this tick" for the enemy that landed it, in seconds.
  ##
  ## One second, and the number matters: the decision loop runs at
  ## `decisionHz`, so a bot decides every few hundred milliseconds and a window
  ## shorter than one decision interval would drop most hits between two
  ## decisions -- a signal that fires only when the timing happens to line up
  ## is worse than no signal. One second is long enough to survive a slow tick
  ## and short enough that a bot does not go on believing it is being shot at
  ## by an enemy that stopped.

var gFiredAtUsCredited = 0
var gBotsRead = 0
var gBotsWithEnemy = 0
var gBotsInCover = 0

# --- PER-DECISION-KIND ACCOUNTING.
#
# `stats()` counts decisions in total. A total tells a reader that the loop
# ran; it cannot tell them that the loop only ever produced `cdNone`, which is
# what a decision core with no sensor readings does and is indistinguishable in
# a total from a working one. So the kinds are counted separately and the
# census prints only the NON-ZERO ones, in order.
var gDecisionKind: array[int(high(CombatDecision)) + 1, int]

proc noteDecisionKind(d: CombatDecision) =
  let i = int(d)
  if i >= 0 and i < gDecisionKind.len:
    gDecisionKind[i] = gDecisionKind[i] + 1

proc decisionKindLine*(): string =
  ## Every combat decision this raid produced, by kind, with its count.
  ##
  ## The line names `cdNone` EXPLICITLY when it is the only kind seen, because
  ## "1,482 decisions" beside no behaviour is the single most misleading number
  ## this mod can print.
  var parts = ""
  var nonNone = 0
  var i = 0
  while i < gDecisionKind.len:
    if gDecisionKind[i] > 0:
      if parts.len > 0: parts.add ", "
      parts.add decisionName(CombatDecision(i)) & "=" & $gDecisionKind[i]
      if CombatDecision(i) != cdNone:
        nonNone = nonNone + gDecisionKind[i]
    inc i
  if parts.len == 0:
    return "sain DECISIONS: none -- the decision loop produced no decision at " &
           "all this raid. That is not 'bots decided to do nothing'; it is " &
           "the loop never running or never reaching a bot."
  result = "sain DECISIONS: " & parts & " -- " & $nonNone &
           " of them are something other than cdNone"
  if nonNone == 0:
    result = result & ". EVERY decision was cdNone, which is what the ladder " &
             "produces when no sensor reading reached it. Read the LEVEL 1 " &
             "census before reading this as bot behaviour."

proc firedAtUsCredited*(): int = gFiredAtUsCredited

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
  # The death poll, and the reason it is now behind a flag.
  #
  # This was unconditional: `get_HealthController` then `get_IsAlive`, two
  # bound calls per bot per decision, for a fact that changes once in a bot's
  # life. It was written that way because `hookArgs` reported a method's
  # declared arguments and not the instance it was called on, so a hook on
  # `Player::OnDead` fired knowing that *a* player died and not which one --
  # and one bound bool per bot was the honest answer to that.
  #
  # `thisPointer` answers it directly, so when the hook took, this goes away.
  # When it did not, the poll is still the only thing that cannot be wrong.
  # UNITY-DESTROYED IS CHECKED UNCONDITIONALLY, and before the flag-gated
  # health poll. It is one raw field read of `m_CachedPtr@0x10` -- no bound
  # call, no export -- and it is the only signal here that does not depend on
  # a hook having taken. With `gDeathHooked` on, the poll below is skipped
  # entirely, which left NOTHING evicting a bot from this table once the raid
  # started tearing it down: the strong GC handle kept the object readable, so
  # the bot went on being decided about and driven straight through
  # `BotOwner.Dispose`. Returning false here drops the handle on the spot.
  if l.ok and not unityAlive(l.player):
    return false
  if l.ok and not gDeathHooked and not isAlive(l.player):
    return false

  var me = readSelf(st.handle, l)

  # THE LEVEL 1 READ-BACK, counted here and nowhere else.
  #
  # `me.position` is the falsifier and it is chosen for one property: its
  # DEFAULT is the zero vector. `readSelf` fills every field with the value
  # that makes the decision core behave as though nothing were wrong -- full
  # health, a full magazine, a ready weapon -- so none of those can distinguish
  # "read from a live receiver" from "the read refused and you got the
  # default". A non-zero position cannot be produced by the default path, so it
  # is positive evidence that `EFT.Player::get_Position` @0x6F32C0 was called
  # on a real receiver and answered. `weaponReady` and `healthNormalized` are
  # deliberately NOT used for this and the verdict says why.
  if (not st.everRead) and l.ok and
     (me.position.x != 0.0 or me.position.y != 0.0 or me.position.z != 0.0):
    st.everRead = true
    gBotsRead = gBotsRead + 1

  # --- velocity, from the previous decision rather than from a second bound
  # `Vector3` getter. Two subtractions and a divide against a ~10 ns call plus
  # a second binding to keep working across a client update.
  if st.lastDecisionAt > 0.0 and dt > 0.0001:
    me.velocity = (me.position - st.prevPosition) * (1.0 / dt)
  st.prevPosition = me.position

  # --- suppression. `readSelf` leaves the raw `IsUnderFire` bool in
  # `suppressionLevel`; the accumulator turns it into a level with a time
  # constant, and returns the health delta on the way past.
  let underFire = me.suppressionLevel > 0.5
  let enemyLooking = primaryView(st.enemies).lookingAtUs

  # Hits the damage hook told us about since the last decision, handed to
  # `feed` rather than credited separately. `core/suppress.nim` says why that
  # distinction is not cosmetic: the two readings have to go through one rise
  # and one decay decision, or the same hit is worth different amounts
  # depending on which host the mod is running on.
  let told = st.pendingDamage
  st.pendingDamage = 0.0

  let damage = feed(st.sup, underFire, enemyLooking, me.healthNormalized,
                    st.settings, gTimeSeconds, dt, told)
  me.suppressionLevel = effectiveLevel(st.sup, st.settings)
  me.recentDamage = damage
  me.timeSinceDamaged = timeSinceDamaged(st.sup, gTimeSeconds)
  if damage > 0.0:
    st.lastDamagedAt = gTimeSeconds

  # --- settle any outstanding acceptance witness, BEFORE this tick can arm a
  # new one. `me.position` was read out of the live game a few lines up, so
  # this is the finished state rather than a property of our own write.
  if st.witnessAt > 0.0:
    let age = gTimeSeconds - st.witnessAt
    if sqrDistance(me.position, st.witnessFrom) > WitnessMoved:
      gWitnessMoved = gWitnessMoved + 1
      st.witnessAt = -1.0
    elif age >= WitnessWindow:
      gWitnessStill = gWitnessStill + 1
      st.witnessAt = -1.0

  st.lastDecisionAt = gTimeSeconds
  st.lastPosition = me.position
  st.lastHealth = me.healthNormalized
  st.groupKey = groupKeyOf(l)

  # --- hearing. The human's motion sound was derived once for the raid; this
  # asks whether *this* bot heard it, with its own acuity and its own
  # localisation error. `occluded` is approximated by "no line of sight to the
  # primary enemy", which is the only occlusion signal available without a
  # raycast this mod cannot make -- and is stated in `README.md` as such.
  var heard = nothingHeard()
  if gPlayerSound.kind != skNone:
    let occluded = not primaryView(st.enemies).visible
    heard = listen(gPlayerSound, me.position, st.settings, occluded,
                   gTimeSeconds, st.rng)

  # Perception. The game has already done the visibility work; this folds its
  # answer into the bot's own memory, which is what decays, forgets and ranks.
  if l.ok:
    var obs = observeEnemy(st.handle, l, gTimeSeconds)
    if obs.key != 0'u64:
      st.enemyKey = obs.key
      if not st.everEnemy:
        st.everEnemy = true
        gBotsWithEnemy = gBotsWithEnemy + 1
      # FIRED AT US, per enemy, for the first time since this field was
      # written. `core/enemy.nim` has read `firedAtUsThisTick` since it was
      # written and nothing ever set it, so `suppressingUs` was permanently
      # false and the ladder rung that keys on it was unreachable.
      #
      # It is credited ONLY when the shooter the damage hook walked out of the
      # DamageInfo is the SAME player this bot currently believes in. A hit by
      # somebody else does not become "this enemy fired at us" -- it stays a
      # suppression event with no attribution, which is what it was before.
      if st.lastShooterKey == obs.key and st.lastShotAt > 0.0 and
         gTimeSeconds - st.lastShotAt <= FiredAtUsWindow:
        obs.firedAtUsThisTick = true
        gFiredAtUsCredited = gFiredAtUsCredited + 1
      # A sound attributed to the *same* enemy the game has selected is folded
      # in as a hearing of them. One that belongs to somebody else is left for
      # the unattributed-sound branch of the ladder, which is what
      # `EHeardFromPeaceBehavior` is for.
      if heard.audible and gPlayerSound.key == obs.key:
        obs.heardThisTick = true
        obs.heard = heard
      observe(st.enemies, obs, me.position, me.lookDirection, st.settings,
              gTimeSeconds, dt, st.rng)

  # `forget` is cheap and compacting, and running it here rather than on its own
  # timer means a bot never scans entries it has already stopped believing in.
  forget(st.enemies, st.settings)
  discard choosePrimary(st.enemies, st.settings)

  let primary = primaryView(st.enemies)
  st.seesEnemy = primary.visible
  st.inCombat = primary.valid and primary.threatLevel > 0.15

  # --- cover, as an *input* to the ladder rather than as an afterthought.
  #
  # This is the half of the sample-then-decide split that runs here. The
  # sampler wrote points into this bot's set on some earlier tick, on Unity's
  # thread, knowing nothing about decisions; `choose` picked one at the end of
  # the last decision, knowing nothing about the engine. All this does is read
  # the answer, and it is what finally moves `inCoverStatus` off
  # `csFarFromCover`.
  #
  # `statusFor` has been written and unreachable since the first version of
  # this mod. It bands the distance to the chosen point exactly as SAIN's
  # `CoverStatus` does, and every rung of the ladder that reads
  # `me.inCoverStatus` -- the pinned-in-cover branch, the shift-cover check,
  # the hold-in-cover fallthrough -- has been comparing against a constant
  # until now.
  if st.coverSet.chosen >= 0 and st.coverSet.chosen < st.coverSet.points.len:
    let held = st.coverSet.points[st.coverSet.chosen]
    me.coverPosition = held.position
    me.hasCoverPoint = true
    me.coverPointDistance = distance(me.position, held.position)
    me.inCoverStatus = statusFor(me.coverPointDistance, st.settings)
    # THE COVER VERDICT'S ONE FACT. `csFarFromCover` is the initialiser in
    # `readSelf`, so it is exactly what a bot with no cover sensor reads
    # forever. Any OTHER value can only have come from `statusFor` running on a
    # chosen point that the sampler produced on Unity's thread, which means the
    # ray was cast and answered. This is the negative the brief asks for and it
    # is the only thing here that can fail.
    if me.inCoverStatus != csFarFromCover and not st.everInCover:
      st.everInCover = true
      gBotsInCover = gBotsInCover + 1

  var view = buildView(st, me, heard)
  let d = decide(st.ctx, view, st.settings)
  inc gDecisionsMade
  noteDecisionKind(d.combat)

  # The search state machine only advances while the decision is a search. SAIN
  # ticks its `SearchClass` regardless and guards inside; not entering at all is
  # cheaper and says the same thing.
  if d.combat == cdSearch:
    if not active(st.searchState):
      let e = view.enemy
      # The drift is the enemy's own estimated velocity now, rather than the
      # difference between two positions that are equal whenever the enemy is
      # visible -- which was every time this ran, so the drift was always zero
      # and the "push past in the direction they went" phase pushed nowhere.
      let side = (if nextFloat(st.rng) < 0.5: -1.0 else: 1.0)
      begin(st.searchState, me.position, e.position, e.velocity,
            gTimeSeconds, e.uncertainty, side)
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
  #
  # "A change" is now two things rather than one: a different decision, or the
  # same decision wanting the bot somewhere materially different. The second
  # clause is rate-limited and distance-limited together -- at least half a
  # second and at least two metres -- because a destination that drifts by
  # centimetres as the bot walks is not news, and re-issuing `GoToPoint` every
  # tick would both cost calls and interrupt the game's own pathing.
  const RestateAfter = 0.5
  const RestateMoved = 4.0        ## squared metres
  var restate = d.combat != st.lastAppliedCombat
  if (not restate) and d.hasMove:
    if gTimeSeconds - st.lastApplyAt >= RestateAfter and
       sqrDistance(d.moveTo, st.lastAppliedMove) > RestateMoved:
      restate = true
  if restate:
    var a = actuationFor(d, view)

    # The aim gate. The decision has ordered a shot; the game's own aim
    # component says whether the aim has settled, and a bot that fires before
    # it has is the spraying-from-the-hip behaviour SAIN exists to remove.
    #
    # It can only ever *withhold*. There is no branch here that makes a bot
    # shoot when the ladder did not ask it to, and a bot with no fresh reading
    # -- the hook refused, the component moved, the slot collided -- behaves
    # exactly as it did before this sensor existed. That asymmetry is what
    # makes a guessed member name safe to act on at all.
    if a.shoot and gAimHooked and l.ok and l.owner != nil:
      var ready = false
      var have = aimReadingFor(st.aimKey, ready)
      if not have:
        # No reading under the address held. Re-derive it and try once more.
        #
        # TWO bound calls, not one, and the second hop is the whole reason
        # this sensor works at all. The postfix in `sain.nim` is installed on
        # `Aiming::get_IsReady` @0x1AD48C0, so the address it deposits a
        # reading under is the CONCRETE AIMING NODE the game called that
        # getter on -- not the BotOwner and not the AimingManager. Keying on
        # the manager (which is what a single `boAiming` hop returns) could
        # therefore never match, and a key that can never match is a sensor
        # that reports nothing while looking wired: CLAUDE.md 9b.
        #
        # So: BotOwner -> AimingManager -> CurrentAiming, each hop refusing on
        # its own. `amCurrent`'s declared return is the interface IBotAiming,
        # and that is safe HERE and only here because the pointer is used as
        # an IDENTITY: nothing is ever called on it. When the current aiming
        # is the one implementor that is not an `Aiming` subclass, the postfix
        # never fires for it, `aimReadingFor` finds nothing, and the gate
        # withholds nothing -- the bot shoots exactly as it did before this
        # sensor existed. The failure mode is a MISSING reading, never a wrong
        # one.
        #
        # In a raid where the hook is working this runs once per bot and then
        # never again -- the aiming node changes only when the bot's aiming
        # TYPE changes, and a stale key simply reads as "no fresh reading".
        let am = callObj(gB.boAiming, l.owner)
        if am != nil:
          let ad = callObj(gB.amCurrent, am)
          if ad != nil:
            st.aimKey = cast[uint64](ad)
            have = aimReadingFor(st.aimKey, ready)
      if have and not ready:
        a.shoot = false
        gAimGated = gAimGated + 1

    # The one place a decision becomes a game call, and the one place this mod
    # chooses a thread for it.
    #
    # **Queued when the host has confirmed Unity's thread**, executed inside
    # `driveJob` on the next frame. The order costs 16 ms of latency, which for
    # a destination a bot walks to over several seconds is nothing, and it buys
    # the thing this mod could not previously claim: `GoToPoint` and
    # `LookToPoint` reaching Unity from the player loop rather than from a
    # worker.
    #
    # **Made inline when it has not**, which is exactly what this mod did
    # before the queue existed, and is a fallback rather than a preference. It
    # is here because the alternative is a host with no per-frame drain driving
    # no bots at all, and a bot that never moves is a worse answer than a call
    # whose legality has never been established either way. `config.json` can
    # turn it off -- `driveFromHostThread: false` -- and the state line says
    # which path the session took, counted, so a log is enough to tell them
    # apart afterwards.
    var told = true
    if mainThread().bound:
      if postDrive(st.handle, a, gTimeSeconds):
        gDrivePosted = gDrivePosted + 1
      else:
        # The ring was full, so this bot was *not* told. Saying it was would
        # latch `lastAppliedCombat` to a decision the game never heard and the
        # bot would stand on the old order until it changed its mind again.
        # Leaving the latch alone makes the next tick restate.
        told = false
      # `gCallsMade` is not advanced here. It counts calls *made*, and the
      # calls this order becomes are counted by `runDrives` on the thread that
      # makes them. Counting them twice would be the flattering answer.
    elif gPreset.driveFromHostThread:
      let made = applyTo(l, a)
      noteHostThreadDrive(made)
      gCallsMade = gCallsMade + made
    else:
      gDriveGated = gDriveGated + 1
    if told:
      st.lastAppliedCombat = d.combat
      st.lastAppliedMove = d.moveTo
      st.lastApplyAt = gTimeSeconds
      # THE WRITER LEDGER. Counted here and nowhere else, because here is where
      # a destination actually left this side. `oneWriterCheck` reads this
      # against `server/dispatch.nim`'s own count and FAILS if both are
      # non-zero while objectives are on.
      if a.hasMoveTarget:
        noteDestination(dwClient, gTimeSeconds)
      # ARM THE WITNESS, and only for an order that asked for LOCOMOTION. An
      # order that only steers the head or pulls a trigger must not be counted
      # as a movement order it never was -- that inflation is exactly the
      # "check that cannot fail" shape, because a bot walking on the game's own
      # AI would then score every look order as a success.
      #
      # AND ONLY WHEN THIS ACTUATOR IS THE ONE THAT WRITES LOCOMOTION. With
      # `clientDrivesLocomotion` off -- the default, because the server side
      # won the one-writer decision -- no locomotion call leaves this mod, so
      # arming here would count orders the game never heard and then score
      # them against motion the SERVER side caused. That is a check that
      # cannot fail, wearing the costume of one that can. The honest reading
      # in that configuration is INCONCLUSIVE, and the verdict says so and
      # names `server/drive.nim`'s own `driveCheck` as the instrument for the
      # path that is actually driving.
      if a.hasMoveTarget and clientLocomotion() and st.witnessAt <= 0.0:
        st.witnessAt = gTimeSeconds
        st.witnessFrom = me.position
        gWitnessOrders = gWitnessOrders + 1
    if gPreset.logDecisions:
      debug "sain: " & st.handle.id & " -> " & decisionName(d.combat) &
            " / " & squadDecisionName(d.squad) & " / " &
            selfActionName(d.self) & "  (" & reasonText(d.reason) & ")"

  gBots[index] = st
  result = true

const KnownPlayersCap = 128
  ## Rule 4. The bot table is bounded by `maxBotsPerTick` upstream and by the
  ## raid below that, but the cap is written here rather than assumed: a
  ## corrupt length must not turn this into an unbounded loop inside a frame.

var gKnown: array[KnownPlayersCap, uint64]
var gKnownLen = 0

proc knownPlayer(p: uint64): bool =
  ## Is this address one this mod already holds as a live player?
  ##
  ## THIS IS THE FALSIFIER for the shooter walk. `DamageInfo.Player` is an
  ## interface field, so a wrong implementor makes the walk read a foreign
  ## offset and answer a plausible, readable, entirely wrong address. Such an
  ## address is not in this set, so it is rejected and counted -- which is a
  ## check that CAN fail. Widening this to "any readable pointer" would make it
  ## a check that cannot.
  result = false
  if p == 0'u64:
    return
  var i = 0
  while i < gKnownLen:
    if gKnown[i] == p:
      return true
    inc i

proc refreshKnownPlayers() =
  ## One pass over the bot table, resolving each handle exactly once, before
  ## the damage drain reads it. Both a bot's OWN address and the address of the
  ## enemy it currently believes in are known players: a bot shooting another
  ## bot is the common case in an offline raid, and the human is reached
  ## through some bot's `enemyKey`.
  gKnownLen = 0
  var i = 0
  while i < gBots.len and gKnownLen < KnownPlayersCap - 1:
    let st = gBots[i]
    inc i
    if st.handle.gcPlayer != 0'u32:
      let p = target(st.handle.gcPlayer)
      if p != nil:
        gKnown[gKnownLen] = cast[uint64](p)
        gKnownLen = gKnownLen + 1
    if st.enemyKey != 0'u64 and gKnownLen < KnownPlayersCap:
      gKnown[gKnownLen] = st.enemyKey
      gKnownLen = gKnownLen + 1

proc drainDamage() =
  ## Turn the addresses the damage hook queued into suppression, once per tick,
  ## on the host's own thread where the bot table is safe to touch.
  ##
  ## Bots outer, events inner -- the reverse of `drainDeaths`, and the reason
  ## is the rate. A death queue holds at most one or two entries, so resolving
  ## every bot's handle once per entry costs nothing. A damage queue can hold a
  ## dozen in a bad tick, and `target` is a call into the runtime; walking the
  ## bots once and the queue once per bot resolves each handle exactly once
  ## however many hits landed.
  if gDmgRead >= gDmgWrite:
    return
  if gDmgWrite - gDmgRead > DamageQueueSize:
    # Overflowed: the oldest entries are gone. Skip to what is still there
    # rather than reading round the ring and crediting a stale address.
    gDmgRead = gDmgWrite - DamageQueueSize
  refreshKnownPlayers()
  let first = gDmgRead
  let last = gDmgWrite
  var i = 0
  while i < gBots.len:
    var st = gBots[i]
    if st.handle.gcPlayer != 0'u32:
      let p = target(st.handle.gcPlayer)
      if p != nil:
        let who = cast[uint64](p)
        var j = first
        while j < last:
          if gDmgWho[j mod DamageQueueSize] == who:
            let amount = gDmgAmount[j mod DamageQueueSize]
            # A hit with no readable amount is credited as the smallest step
            # the accumulator has rather than as nothing: the event is exact
            # even when the magnitude is not, and treating "hit for an unknown
            # amount" as "not hit" would be the one reading here that is
            # actually wrong.
            st.pendingDamage = st.pendingDamage +
                               (if amount > 0.0: amount else: 0.01)
            gDmgEvents = gDmgEvents + 1
            # WHO SHOT, credited only on a match against a player this mod is
            # already tracking -- see `shotCounters` for why the reject branch
            # is the whole value of this. `knownPlayer` answers off the bot
            # table and the current enemy keys, both of which are addresses
            # read on this same tick, so no stale pointer is compared.
            let sh = gDmgShooter[j mod DamageQueueSize]
            if sh != 0'u64:
              if knownPlayer(sh):
                st.lastShooterKey = sh
                st.lastShotAt = gTimeSeconds
                gShotMatched = gShotMatched + 1
              else:
                gShotUnmatched = gShotUnmatched + 1
          j = j + 1
        gBots[i] = st
    inc i
  gDmgRead = last

proc drainDeaths() =
  ## Turn the addresses the death hook queued into bots, once per tick, on the
  ## host's own thread where the bot table is safe to touch.
  ##
  ## Matching is by address: `liveOf` resolves each bot's GC handle to this
  ## frame's pointer anyway, and comparing two pointers is one instruction. It
  ## is O(deaths x bots), and deaths per tick is almost always zero.
  while gDeadRead < gDeadWrite:
    if gDeadWrite - gDeadRead > DeathQueueSize:
      # Overflowed: the oldest entries are gone. Skip to what is still there
      # rather than reading round the ring and matching a stale address.
      gDeadRead = gDeadWrite - DeathQueueSize
    let who = gDeadRing[gDeadRead mod DeathQueueSize]
    gDeadRead = gDeadRead + 1
    if who == 0'u64:
      continue
    var i = 0
    while i < gBots.len:
      let st = gBots[i]
      if st.handle.gcPlayer != 0'u32:
        let p = target(st.handle.gcPlayer)
        if p != nil and cast[uint64](p) == who:
          # Compact on the spot: `despawnBot` releases the handle, and the
          # cursor it fixes up is not in use here.
          let id = st.handle.id
          despawnBot(id)
          if gPreset.logDecisions:
            debug "sain: " & id & " died (told, not polled)"
          break
      inc i

proc tick*(elapsedMs: int64) =
  ## Called from `onUpdate`. Constant cost in the number of bots.
  var dt = float(int(elapsedMs)) / 1000.0
  if dt < 0.001: dt = 0.001
  gTimeSeconds = gTimeSeconds + dt
  updatePlayerPosition(dt)
  # The aim readback, on the HOST's thread and before the early return: a
  # postfix that fires while the bot table is momentarily empty is still
  # evidence the hook is live, and returning first would have hidden it.
  aimAnnounce()
  if gBots.len == 0:
    return
  # Three raid-level passes, once each per tick rather than once per bot. The
  # ally table is the expensive one and it is O(bots); the grenade sample is one
  # bound call when the list is empty, which is almost always.
  rebuildAllies()
  updateGrenades()
  drainDeaths()
  drainDamage()
  # The cover sample: fold in whatever Unity's thread finished, then queue at
  # most one more.
  #
  # The drain touches one bot. The post is O(bots) in the worst case -- a tick
  # where nobody wants a sample walks the whole table looking -- and that is
  # affordable for one reason worth stating rather than assuming: the rate
  # limit is checked *before* the walk, so the walk happens ten times a second
  # rather than sixty, and it is a comparison of two floats per bot with no
  # game call in it. `rebuildAllies` above is O(bots) every tick and costs
  # more.
  drainCoverSample()
  postCoverSample()
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
      # PHASE 2: the body becomes an objective.
      #
      # This is the ONE loot position on this build that is real. `db.json`'s
      # `staticContainers` are all (0,0,0) -- 7,092 of 7,092 rows, measured --
      # so a loot objective derived from them is a bot walking to world zero.
      # A corpse's position is a position this mod watched a live bot occupy
      # one tick ago, and it needs no binding at all to know it.
      #
      # `okHunt`, not `okLoot`, and the distinction is the honest one: nothing
      # on this build can OPEN a body. `LootableContainer.Interact` and the
      # inventory-move RVA are both unmeasured (`docs/SAIN_RVA.md`), and
      # resolving them by name is the call that kills the client. A bot sent
      # here walks to where somebody died and loiters, which is what the
      # config text says it does.
      if gPreset.base.huntLastKnown:
        discard addObjective(okHunt, gBots[i].lastPosition, 1.4,
                             hashSeed(gBots[i].handle.id, 0'u64), true)
      break
    inc considered
  if considered > gPeakConsidered:
    gPeakConsidered = considered
  if died.len > 0:
    despawnBot(died)
  # Last in the tick, after every bot that was going to change its mind has:
  # one job for the whole tick's orders. Posted only when there is something to
  # drain, so a raid in which nothing changed costs no scheduler slot at all.
  if drivePending() > 0 and mainThread().bound:
    if onMainThread(driveJob) == Ok:
      gDriveJobs = gDriveJobs + 1

proc scan*(nowMillis: int64) =
  ## The discovery half of the tick, kept separate so `onUpdate` can call it
  ## before `tick` and so the sim can skip it.
  ##
  ## The main-thread question is asked here rather than in `tick` for the same
  ## reason the world scan is: it is a host call at about a microsecond, its
  ## answer changes at most once in a session, and `refreshMainThread` is
  ## itself rate-limited to once every two seconds until it answers yes.
  ## Nothing posts a cover sample before it does.
  discard refreshMainThread(nowMillis)
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

proc driveVerdict*(): string =
  ## The §9b acceptance verdict, in the only terms that settle it: PASS / FAIL /
  ## INCONCLUSIVE, decided by whether bots MOVED, never by whether calls
  ## returned.
  ##
  ## The order of the branches is the argument. `orders == 0` is checked FIRST
  ## and is INCONCLUSIVE, because a run that never drove is not a run that
  ## drove and failed, and flattening those two together has cost this project
  ## whole sessions. Only once orders were genuinely issued does a settled
  ## window get to decide anything, and a run whose windows are all still open
  ## is inconclusive too -- "I could not look" is not a pass.
  let settled = gWitnessMoved + gWitnessStill
  let c = "counters: " & $gWitnessOrders & " locomotion orders issued, " &
          $gWitnessMoved & " moved >0.5 m within " & $WitnessWindow &
          " s, " & $gWitnessStill & " did not, " & $gWitnessLost &
          " lost (bot died or went unreadable inside the window)" &
          "; TEARDOWN GATE: " & $drivesAdmitted() & " drives admitted, " &
          $drivesRefusedDying() & " refused because dying (" &
          $drivesRefusedDestroyed() & " Unity-destroyed, " &
          $drivesRefusedDisposed() & " BotOwner not Active, " &
          $drivesRefusedDead() & " IsDead)"
  # THE GATE COUNTERS BELONG IN THIS LINE, not in a parallel verdict.
  #
  # `admitted` is the denominator the §9b assertion needs: a raid with zero
  # `Problem bot dispose` NREs and zero admitted drives proves nothing, because
  # nothing was driven. `refused` climbing at raid end is the gate working; it
  # climbing during a live raid means bots are being enumerated after they stop
  # being drivable and the census wants looking at.
  if gWitnessOrders == 0:
    var why = "Read the NOT DELIVERED and RVA-target lines above for why"
    if not clientLocomotion():
      why = "EXPECTED here: clientDrivesLocomotion is off, so the server " &
            "side owns locomotion by the one-writer decision and this " &
            "actuator withheld " & $sprintWithheld() & " sprint calls. The " &
            "instrument for the path that IS driving is server/drive.nim's " &
            "driveCheck, not this line"
    return "DRIVE ACCEPTANCE: INCONCLUSIVE -- WE NEVER DROVE. No locomotion " &
           "order left this actuator, so nothing about the driving calls " &
           "was tested. " & why & ". Do NOT read this as a failure of the " &
           "calls. " & c
  if settled == 0:
    return "DRIVE ACCEPTANCE: INCONCLUSIVE -- orders were issued but no " &
           "witness window has settled yet (the raid ended inside " &
           $WitnessWindow & " s of the first order). " & c
  if gWitnessMoved == 0:
    return "DRIVE ACCEPTANCE: FAIL -- every settled order left the bot where " &
           "it stood. The calls returned; the bots did not move. " & c
  result = "DRIVE ACCEPTANCE: PASS -- " & $gWitnessMoved & " of " & $settled &
           " settled orders were followed by real motion. Judge the RATE, " &
           "not the count: a rate near what idle bots do on the game's own " &
           "AI is not evidence we drove them. " & c

proc driveStats*(): string =
  ## Which thread drove, how much, and everything that did not get driven. The
  ## counters are separate on purpose: "queued" and "executed" differing by
  ## more than one tick's worth means the drain is not running, and that is not
  ## visible in a single total.
  if mainThread().bound:
    result = "driving on Unity's thread: " & $gDrivePosted &
             " orders queued, " & $driveRuns() & " drains in " & $gDriveJobs &
             " jobs, " & $driveCalls() & " game calls"
  elif gPreset.driveFromHostThread:
    result = "driving on the host's own thread (Unity's not confirmed): " &
             $driveHostThreadRuns() & " actuations, " & $driveCalls() &
             " game calls. That is what this mod did before the queue " &
             "existed and it has never been shown safe or unsafe"
  else:
    result = "not driving (Unity's thread not confirmed, " &
             "driveFromHostThread off): " & $gDriveGated &
             " actuations withheld. Bots decide and do not move"
  # The ring's own counters, on every path, because the two that matter are
  # failures rather than totals: a drop means the drain stopped running, and a
  # stale order means it ran too late to be worth running.
  result = result & " -- ring: " & $drivePending() & " pending, " &
           $driveDropped() & " dropped (full), " & $driveStale() &
           " stale, " & $driveGone() & " for bots that had died"
  let ns = driveCostNs()
  if ns >= 0'i64:
    result = result & ", " & $ns & " ns a drain"
  else:
    result = result & ", nothing measured: no drain has run"
  # WHAT WAS WANTED AND NOT DELIVERED, always, on every path. A total of game
  # calls that goes up looks like success even when the one call that moves a
  # bot is the one being dropped, so the two refusals are printed next to it
  # rather than inferred from its absence.
  result = result & " -- NOT DELIVERED: " & $moveTargetsDropped() &
           " destinations (GoToPoint needs 8-9 register slots; the shape " &
           "dispatcher tops out at 5 and refuses rather than spilling to the " &
           "stack -- route is aowlspt/botnav), " & $selfActionsRefused() &
           " medical self-actions (Nullable<int> is an 8-byte by-value " &
           "aggregate whose register-vs-pointer convention is unmeasured on " &
           "this build, and each takes a managed Action)"
  # THE ONE-WRITER LINE. The loser is proved inert rather than assumed to be:
  # a zero here next to a non-zero withheld count is the evidence.
  result = result & " -- one writer: locomotion belongs to " &
           (if clientLocomotion(): "THIS CLIENT ACTUATOR (clientDrivesLocomotion on)"
            else: "the SERVER side (server/drive.nim -> SetTargetMoveSpeed/botnav)") &
           "; client sprint calls issued " & $sprintIssued() & ", withheld " &
           $sprintWithheld()
  result = result & " -- RVA targets: " & driveWhy()
  if driveDisabled():
    result = result & " [SELF-DISABLED after " & $driveFaults() & " faults]"
  result = result & " -- " & driveVerdict()

proc levelOneVerdict*(alivePlayers: int): string =
  ## PASS / FAIL / INCONCLUSIVE for "did any bot's state come back off a live
  ## receiver this raid".
  ##
  ## `alivePlayers` is the count the arming probe read off
  ## `GameWorld.AllAlivePlayersList@0x1c8`, passed in rather than re-read, so
  ## the verdict and the probe cannot disagree about how many players existed.
  ##
  ## THREE OUTCOMES. FAIL is reserved for the case the brief names: players
  ## existed and this mod read none of them. "No players at all" is
  ## INCONCLUSIVE -- there was nothing to read, and calling that a pass is the
  ## check that cannot fail.
  let c = "bots attached " & $gAttached & ", bots the decision loop reached " &
          $gBots.len & ", alive players the world reported " & $alivePlayers &
          ", distinct bots whose POSITION came back non-zero " & $gBotsRead &
          ", distinct bots with a goal enemy " & $gBotsWithEnemy &
          ". NOT USED AS EVIDENCE: healthNormalized and weaponReady, whose " &
          "refusal defaults (1.0 and true) are indistinguishable from a " &
          "successful read -- hcBodyPart is a permanent stated refusal, so " &
          "every bot reads as unhurt whether or not anything was read"
  if alivePlayers <= 1:
    return "sain LEVEL 1 VERDICT: INCONCLUSIVE -- the world reported " &
           $alivePlayers & " alive player(s), so there was no bot to read. " &
           "This is not a pass. " & c
  if gBotsRead > 0:
    return "sain LEVEL 1 VERDICT: PASS -- " & $gBotsRead &
           " distinct bot(s) had state read back off a live receiver. " & c
  result = "sain LEVEL 1 VERDICT: FAIL -- the world reported " &
           $alivePlayers & " alive player(s) and NOT ONE bot had any state " &
           "read back off a live receiver. Read the LEVEL 1 census line " &
           "above this one: it names which members refused and why. " & c

proc coverVerdict*(): string =
  ## Did `inCoverStatus` ever take a value other than `csFarFromCover`.
  if gBotsInCover > 0:
    return "sain COVER VERDICT: PASS -- " & $gBotsInCover &
           " distinct bot(s) reached an inCoverStatus other than " &
           "csFarFromCover, which can only come from a cover point the " &
           "Unity-thread sampler produced, which means Physics::Raycast was " &
           "called and answered."
  if gBots.len == 0:
    return "sain COVER VERDICT: INCONCLUSIVE -- no bot was reached at all, " &
           "so the sampler was never asked for a point. Not a failure of the " &
           "raycast."
  result = "sain COVER VERDICT: FAIL -- " & $gBots.len & " bot(s) were " &
           "decided about and every one of them read csFarFromCover for the " &
           "whole raid. The ray itself is byte-verified at bind time (see " &
           "the `cover sensor -- ray:` line); what this says is that no " &
           "CHOSEN COVER POINT ever reached a bot, so look at the sample " &
           "counters in the status line -- points proposed, rays cast, " &
           "samples taken -- to see which half is empty."

proc firedAtUsVerdict*(): string =
  ## Did the per-enemy shot signal ever attribute a hit to the enemy a bot
  ## currently believes in.
  var matched = 0
  var unmatched = 0
  shotCounters(matched, unmatched)
  var asked = 0
  var walked = 0
  var refused = 0
  shooterCounters(asked, walked, refused)
  let c = "DamageInfo walks asked " & $asked & ", produced a candidate " &
          $walked & ", refused a guard " & $refused &
          "; candidates matching a player this mod holds " & $matched &
          ", matching nothing " & $unmatched &
          "; credited to the bot's CURRENT enemy " & $gFiredAtUsCredited
  if asked == 0:
    return "sain FIRED-AT-US VERDICT: INCONCLUSIVE -- the damage prefix never " &
           "fired, so no DamageInfo was ever walked. Nothing was hit, or the " &
           "hook did not arm; the `damage` clause of the status line says " &
           "which. " & c
  if walked == 0:
    return "sain FIRED-AT-US VERDICT: FAIL -- the hook fired " & $asked &
           " time(s) and the walk produced no candidate at all, so either " &
           "DamageInfo.Player was null on every hit or one of the two " &
           "offsets is wrong for the installed build. " & c
  if matched == 0:
    return "sain FIRED-AT-US VERDICT: FAIL -- " & $walked & " candidate " &
           "shooter address(es) were produced and NONE matched a player this " &
           "mod holds. That is the exact signature of the risk this walk " &
           "declares: DamageInfo.Player is an interface field, and a wrong " &
           "implementor makes +0x18 read a foreign offset and answer a " &
           "plausible address. Treat the offsets as unproven. " & c
  if gFiredAtUsCredited == 0:
    return "sain FIRED-AT-US VERDICT: INCONCLUSIVE -- " & $matched &
           " shooter(s) were identified as real players, but none was ever " &
           "the enemy the hit bot currently believed in, so no per-enemy " &
           "signal was set. The walk works; the attribution had nothing to " &
           "attribute to. " & c
  result = "sain FIRED-AT-US VERDICT: PASS -- " & $gFiredAtUsCredited &
           " hit(s) were attributed to the enemy the bot was already " &
           "tracking, which is the first time firedAtUsThisTick has ever " &
           "been set. " & c

proc stats*(): string =
  result = $gBots.len & " bots, " & $gDecisionsMade & " decisions, " &
           $gCallsMade & " game calls, " & $gAttached & " attached, " &
           $gDetached & " released, " & $gPeakConsidered &
           " bots in the busiest tick, death " &
           (if gDeathHooked: "hooked" else: "polled") &
           # Three numbers, not one. FIRED / MATCHED / WITHHELD separate the
           # three ways this sensor can be dead: never fired (the hook is on
           # the wrong address), fired but never matched (the two-hop walk
           # keys on the wrong object), matched but never withheld (it works
           # and every bot was already settled). One number could not tell
           # them apart, and the previous hook was dead in the FIRST way for
           # its whole life without that ever being visible.
           ", aim " & (if gAimHooked: "hooked (" & $gAimNoted & " fired, " &
                       $gAimMatched & " matched, " & $gAimGated &
                       " shots withheld)" else: "not hooked") &
           ", damage " & (if gDmgHooked: "hooked (" & $gDmgEvents &
                          " hits told)" else: "inferred from health") &
           ", " & coverStats() & ", " & driveStats()
