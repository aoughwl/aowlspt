## The client bridge: reading a bot, and driving it.
##
## `core/` is pure, `preset/` reads a config file, `server/` talks to a
## database. This file and `live.nim` are the only two that know Tarkov exists,
## deliberately, because they are also the part most likely to break against a
## client update and the part that cannot be tested offline.
##
## ## What changed, and what that means
##
## This file used to say that per-bot state could not be reached at all: the
## host resolved types and called members, but a call returning a reference
## reported `{"type":"EFT.Player"}` and no handle, so there was no route from
## `GameWorld` to a `BotOwner`. That is gone. Two things replaced it:
##
##  * The host now hands back a live object for a reference return, which is
##    what makes the *spawn hook* useful -- see `sain.nim`.
##  * `aowlspt/fast` lets a mod bind a method or a field once and then call it
##    for ~10 ns, or read it for ~2 ns, against ~1000 ns for the host's boxed
##    path. `live.nim` is that binding layer.
##
## So the bridge now walks the graph itself: world -> alive players -> the
## bot's `Player` -> `AIData` -> `BotOwner` -> the components SAIN reads. What
## it *caches* is one IL2CPP GC handle per bot, on the `Player`, held for as
## long as the bot lives.
##
## **Why one handle rather than eight.** The obvious cache is a handle per
## component: player, owner, health, movement, weapon, memory, steering, mover.
## Eight handles means eight `il2cpp_gc_handle_get_target` calls per bot per
## tick to turn them back into pointers. Re-deriving the components from the
## `Player` pointer instead is six *bound property calls* -- ~10 ns each, no
## allocation, and always current, because a component the game replaced
## mid-raid is picked up rather than pinned. Fewer handles is both cheaper and
## more correct here, which does not happen often enough to pass up.
##
## ## Performance rules this file follows
##
##  1. **Bind once.** Every member goes through `live.LazyCall`, which resolves
##     on first use against the object's own class and then costs a pointer
##     compare. Binding is 3-9 us and happens once per class.
##  2. **Resolve the handle once per tick, not per read.** `liveOf` turns the
##     bot's GC handle into this frame's pointer once; `readSelf` and `apply`
##     both take the result.
##  3. **Read once per bot per decision, not per check.** `readSelf` does one
##     pass into a plain struct and the ladder then runs entirely on stack
##     memory. SAIN's C# reads a property inside each check.
##  4. **Prefer being told over asking.** The spawn hook in `sain.nim` costs
##     nothing between spawns; polling for new bots costs the same every frame
##     forever. The world scan in `driver.nim` is the reconciler, at 2 Hz, not
##     the primary path.
##
## ## What this file still cannot do, stated rather than approximated
##
##  * **It is not on Unity's main thread.** `onUpdate` runs on the host's own
##    attached thread. Reading managed fields from it is fine; issuing movement
##    and steering calls that end in Unity APIs is not something any host here
##    can currently make legal -- `invoke_main` queues onto the host's thread,
##    not Unity's, and says so in `docs/IL2CPP.md`. The driving calls below are
##    written and will run; whether the engine tolerates them from this thread
##    is the one thing that needs the game to answer, and no comment here should
##    be read as claiming it has been.
##  * **Cover points have no source.** `core/cover.nim` scores cover points; the
##    points come from raycasts this mod does not do, so `CoverSet` stays empty
##    and `inCoverStatus` stays `csFarFromCover`. The cover decisions therefore
##    never fire. That is a missing sensor, not a missing decision.
##  * **Bleeds, fractures and squads are not read.** Both need walking a generic
##    collection (`IEffect` lists, `BotsGroup` members), and a generic
##    instantiation is exactly what `findClass` cannot name. `List<T>` is
##    reachable only because an *instance* of it turns up in hand; an effect
##    list does not, because reaching it is itself the generic call.

import aowlspt
import aowlspt/game
import aowlspt/il2cpp
import ".." / core / vec
import ".." / core / types
import ".." / core / enemy
import live

# The type surface used for the *capability probe only*. Resolved on first use,
# because a type resolved at load time is a false negative: the game has not
# loaded its assemblies when a mod starts.
var GameWorld = gameType("EFT.GameWorld")

type
  Capability* = enum
    ## What this client build actually supports, discovered rather than assumed.
    capNone            ## the game is not up
    capReadOnly        ## the world exists but the bot graph cannot be walked
    capFull            ## bots can be read and driven

var gCapability = capNone
var gAnnounced = false
var gProbeNote = ""

proc capability*(): Capability = gCapability

proc probe*(): Capability =
  ## Ask the game two questions and classify the answers.
  ##
  ## The first is the host's: does `EFT.GameWorld` resolve at all? That is the
  ## cheap "is there a raid" test and it is the one thing worth asking every
  ## couple of seconds.
  ##
  ## The second is this mod's own: with the runtime bound directly, does
  ## `GameWorld.Instance` come back, and does its alive-players list have a
  ## length? Those two together are the whole of what the bot walk depends on.
  ## Anything past them degrades to a default rather than to nothing.
  if not available(GameWorld):
    gCapability = capNone
    gProbeNote = "EFT.GameWorld does not resolve"
    return gCapability
  if not openLive():
    gCapability = capReadOnly
    gProbeNote = "GameAssembly.dll is not bound in this process, so the fast " &
                 "path is unavailable"
    return gCapability
  bindAll()
  let world = worldObject()
  if world == nil:
    gCapability = capReadOnly
    gProbeNote = "GameWorld.Instance is null -- no raid is running, or " &
                 gB.worldWhy
    return gCapability
  let list = alivePlayers(world)
  if list == nil:
    gCapability = capReadOnly
    gProbeNote = "the alive-players list could not be read: " & gB.aliveWhy
    return gCapability
  gCapability = capFull
  gProbeNote = $listLen(list) & " players in the world"
  result = gCapability

proc announce*() =
  ## Say what this build can do, once, in terms someone reading a log can act
  ## on. A mod that quietly does half its job is worse than one that says which
  ## half.
  if gAnnounced:
    return
  gAnnounced = true
  case gCapability
  of capNone:
    info "sain: the game world is not up yet"
  of capReadOnly:
    warn "sain: the bot object graph cannot be walked -- " & gProbeNote &
         ". The decision core is running in observer mode; nothing is being " &
         "driven."
  of capFull:
    success "sain: driving bots (" & gProbeNote & ")"
  report()

proc capable*(): bool = gCapability == capFull

# ---------------------------------------------------------------------------
# A bot
# ---------------------------------------------------------------------------

type
  BotHandle* = object
    ## A bot, as this bridge addresses it.
    ##
    ## `id` is the profile id and is the key everything else uses: it survives a
    ## handle being released and it is what the decision core keys its per-bot
    ## state on. `gcPlayer` is this mod's own IL2CPP GC handle on the bot's
    ## `Player`, taken at attach and freed at detach.
    ##
    ## It is *not* a host `Handle`. The host's handle is an index into the
    ## host's table and there is no ABI entry point that turns one into the raw
    ## pointer the fast path needs, so the fast path has to start from a pointer
    ## this mod obtained itself. See the note at the top of `live.nim`.
    id*: string
    role*: BotRole
    gcPlayer*: uint32

  BotLive* = object
    ## One tick's pointers for one bot. Never stored: the collector moves
    ## objects, so these are good for this frame and no longer.
    ok*: bool
    player*: Il2CppPtr
    owner*: Il2CppPtr

func noBot*(): BotLive =
  BotLive(ok: false, player: cast[Il2CppPtr](0), owner: cast[Il2CppPtr](0))

func roleFromSpawnType*(name: string): BotRole =
  ## BSG's `WildSpawnType` has three dozen members; SAIN keys per-bot settings
  ## off all of them. The decision core reads a coarse grouping, so the mapping
  ## happens here, once, at spawn.
  if name.len == 0: return brScav
  case name
  of "pmcBEAR", "pmcUSEC", "pmcBot", "sptUsec", "sptBear": brPmc
  of "pmcBot_raider", "exUsec", "pmcBot_rogue": brRaider
  of "assault", "assaultGroup", "cursedAssault", "marksman": brScav
  of "playerScav": brPlayerScav
  of "followerBully", "followerKojaniy", "followerGluharAssault",
     "followerGluharSecurity", "followerGluharScout",
     "followerGluharSnipe", "followerSanitar", "followerTagilla",
     "followerBirdEye", "followerBigPipe": brFollower
  of "bossKnight", "followerBirdeye", "followerBigpipe": brGoon
  of "infectedAssault", "infectedPmc", "infectedCivil", "infectedLaborant",
     "infectedTagilla": brZombie
  else:
    # Everything left that starts with "boss" is a boss; an unknown spawn type
    # is a scav, which is the safe default because scav settings are the least
    # aggressive.
    if name.len >= 4 and name[0] == 'b' and name[1] == 'o' and
       name[2] == 's' and name[3] == 's': brBoss
    else: brScav

proc attach*(b: var BotHandle; player: Il2CppPtr) =
  ## Take the one handle this bot costs. Idempotent: re-attaching the same bot
  ## would leak the first handle, and a raid re-attaches on every scan.
  if b.gcPlayer != 0'u32:
    return
  b.gcPlayer = hold(player)

proc detach*(b: var BotHandle) =
  ## Give the handle back. Called when the bot dies or the raid ends; a handle
  ## kept past that pins a corpse for the session.
  if b.gcPlayer == 0'u32:
    return
  drop(b.gcPlayer)
  b.gcPlayer = 0'u32

proc liveOf*(b: BotHandle): BotLive =
  ## This frame's pointers.
  ##
  ## One `gc_handle_get_target` and two bound property calls. The `BotOwner` is
  ## re-derived rather than held for the reason in the module comment: two more
  ## handles would cost two more handle lookups per tick and pin an object the
  ## game may have replaced.
  result = noBot()
  if b.gcPlayer == 0'u32:
    return
  let p = target(b.gcPlayer)
  if p == nil:
    return
  result.player = p
  let ai = callObj(gB.pAIData, p)
  if ai != nil:
    result.owner = callObj(gB.aiBotOwner, ai)
  result.ok = true

proc profileIdOf*(player: Il2CppPtr): string =
  ## The bot's key. A managed string, copied out once at attach and never read
  ## again -- reading it per tick would put a UTF-16 to UTF-8 conversion on the
  ## hot path for a value that cannot change.
  result = ""
  if player == nil:
    return
  result = readManagedString(callObj(gB.pProfileId, player))

proc isAI*(player: Il2CppPtr): bool =
  ## Whether this is a bot rather than the human. One bound call returning a
  ## bool: the cheapest shape the fast path has.
  callBoolOn(gB.pIsAI, player, false)

proc isAlive*(player: Il2CppPtr): bool =
  ## Death detection.
  ##
  ## This is polled rather than hooked, and the reason is worth naming: the
  ## natural hook is `Player::OnDead`, but `hookArgs` reports a method's
  ## *declared* arguments and not the instance it was called on, so a death
  ## hook fires knowing that a player died and not which one. The host computes
  ## `this` (`thisOf` in its own `invoke.nim`) and does not surface it. Until it
  ## does, one bound bool read per bot per tick is the honest answer -- it costs
  ## about ten nanoseconds and it cannot be wrong.
  let hc = callObj(gB.pHealth, player)
  if hc == nil:
    return true
  callBoolOn(gB.hcAlive, hc, true)

# ---------------------------------------------------------------------------
# Reading a bot
# ---------------------------------------------------------------------------

const
  BodyPartCommon = 7'i32
    ## `EBodyPart.Common` -- the aggregate SAIN reads for "how hurt is this
    ## bot". The ordinal is the pre-1.0 one and is the single most likely
    ## number in this file to be wrong on a post-1.0 client; getting it wrong
    ## reads a different limb's health rather than garbage, and the binding
    ## report will not catch it. If bot health behaviour looks off, check this
    ## first.

proc readHealth(l: BotLive): float =
  ## Health as a fraction.
  ##
  ## `GetBodyPartHealth` takes an enum and returns a value struct, so it is
  ## refused by the fast path twice over: an enum argument has no register class
  ## the runtime will state, and a 12-byte struct return is a hidden-pointer
  ## call shape rather than a register class. `il2cpp_runtime_invoke` boxes the
  ## result and the two floats come out of the box by name, which needs no
  ## assumption about where the runtime puts a boxed value's payload.
  result = 1.0
  if l.player == nil:
    return
  let hc = callObj(gB.pHealth, l.player)
  if hc == nil:
    return
  let boxed = callIntArg(gB.hcBodyPart, hc, BodyPartCommon)
  if boxed == nil:
    return
  let maxv = readStructFloat(gB.vsMaximum, boxed, 0.0)
  if maxv <= 0.0:
    return
  result = clampf(readStructFloat(gB.vsCurrent, boxed, maxv) / maxv, 0.0, 1.0)

proc readStamina(l: BotLive): float =
  result = 1.0
  if l.player == nil:
    return
  let ph = callObj(gB.pPhysical, l.player)
  if ph == nil:
    return
  let st = callObj(gB.phStamina, ph)
  if st == nil:
    return
  result = clampf(callFloatOn(gB.stNormal, st, 1.0), 0.0, 1.0)

proc readSelf*(b: BotHandle; l: BotLive): SelfView =
  ## One pass of reads into a plain struct.
  ##
  ## Every default below is the value that makes the decision core behave as
  ## though the thing it could not read is not a problem: full health, a full
  ## magazine, a ready weapon, no suppression. That direction is deliberate. A
  ## bot whose magazine count cannot be read should not spend the raid
  ## reloading.
  result = SelfView(
    healthNormalized: 1.0, energy: 1.0, hydration: 1.0, stamina: 1.0,
    hasHeavyBleed: false, hasLightBleed: false, hasFracture: false,
    canHeal: false, canUseStims: false, canDoSurgery: false,
    ammoInMagazine: 30, magazineSize: 30, hasAmmoToReload: false,
    weaponReady: true, inCoverStatus: csFarFromCover, coverPointDistance: 99.0,
    suppressionLevel: 0.0, isSprinting: false, position: zeroVec(),
    lookDirection: vec3(1.0, 0.0, 0.0))
  if not l.ok:
    return

  # --- position and facing. Two reflective calls, and the only two managed
  # allocations this mod makes per bot per tick: a Vector3 return is boxed.
  result.position = readVec(gB.pPosition, l.player)
  result.lookDirection = readVec(gB.pLookDir, l.player)

  # --- condition
  result.healthNormalized = readHealth(l)
  result.stamina = readStamina(l)

  let mc = callObj(gB.pMovement, l.player)
  if mc != nil:
    result.isSprinting = callBoolOn(gB.mcSprint, mc, false)

  if l.owner == nil:
    return

  # --- suppression. `IsUnderFire` is a bool rather than a level, so it is
  # mapped to the ends of the range. SAIN's own suppression is an accumulator
  # over incoming rounds, which is a sensor this mod does not have -- the
  # thresholds in `settings` still work against 0 and 1, they just have no
  # middle.
  let mem = callObj(gB.boMemory, l.owner)
  if mem != nil:
    if callBoolOn(gB.memUnderFire, mem, false):
      result.suppressionLevel = 1.0

  # --- weapon
  let wm = callObj(gB.boWeapon, l.owner)
  if wm != nil:
    result.hasAmmoToReload = callBoolOn(gB.wmHaveBullets, wm, false)
    result.weaponReady = callBoolOn(gB.wmReady, wm, true)
    let rl = callObj(gB.wmReload, wm)
    if rl != nil:
      let n = callIntOn(gB.rlBullets, rl, -1)
      let m = callIntOn(gB.rlMaxBullets, rl, -1)
      if n >= 0 and m > 0:
        result.ammoInMagazine = n
        result.magazineSize = m

  # --- what the bot could do to itself
  let med = callObj(gB.boMedecine, l.owner)
  if med != nil:
    let fa = callObj(gB.medFirstAid, med)
    if fa != nil:
      result.canHeal = callBoolOn(gB.faHave, fa, false)
    let stim = callObj(gB.medStims, med)
    if stim != nil:
      result.canUseStims = callBoolOn(gB.stimHave, stim, false)
    let surg = callObj(gB.medSurgery, med)
    if surg != nil:
      result.canDoSurgery = callBoolOn(gB.surgHave, surg, false)

  # `hasHeavyBleed` / `hasLightBleed` / `hasFracture` stay false: reading them
  # means walking the health controller's effect collection, which is a generic
  # instantiation with no name `findClass` accepts and no instance in hand to
  # bind from. Stated rather than approximated -- guessing "bleeding" from a
  # falling health value would make the first-aid ladder fire on the wrong
  # cause.

proc observeEnemy*(b: BotHandle; l: BotLive; now: float): Observation =
  ## The bot's current goal enemy, as one `Observation` for `core/enemy`.
  ##
  ## The game has already done the expensive half -- the visibility raycast and
  ## the enemy selection -- so this reads its answer rather than repeating it.
  ## That is the sensing/logic split `docs/IL2CPP.md` recommends profiling
  ## before rewriting: the raycast is in the engine and costs what it costs.
  result = Observation(id: "", alive: false, isPlayer: false,
                       position: zeroVec(), sawThisTick: false,
                       heardThisTick: false, firedAtUsThisTick: false,
                       lookingAtUsThisTick: false, pathDistance: -1.0)
  if not l.ok or l.owner == nil:
    return
  let mem = callObj(gB.boMemory, l.owner)
  if mem == nil:
    return
  let goal = callObj(gB.memGoalEnemy, mem)
  if goal == nil:
    return
  let person = callObj(gB.enPerson, goal)
  if person == nil:
    return
  # The id is read per tick here, unlike the bot's own, because the goal enemy
  # can change between ticks and the enemy table is keyed on it. It is one
  # bound call plus a string copy; if it ever shows up in a profile the fix is
  # to key on the person *pointer* for the tick and only stringify on a change.
  result.id = readManagedString(callObj(gB.pProfileId, person))
  if result.id.len == 0:
    return
  result.alive = true
  result.isPlayer = not callBoolOn(gB.pIsAI, person, true)
  result.position = readVec(gB.enPosition, goal)
  result.sawThisTick = callBoolOn(gB.enVisible, goal, false)
  # `heardThisTick` and `firedAtUsThisTick` have no direct reads here: EFT's
  # sound events arrive through a listener the host cannot subscribe to from
  # native code, and `lookingAtUsThisTick` needs the enemy's own forward vector
  # against us, which is a second Vector3 read per enemy per tick. Left false
  # rather than derived: `core/enemy` treats "not heard" as decaying memory,
  # which is the correct behaviour for a sensor that is absent rather than
  # silent.

# ---------------------------------------------------------------------------
# Driving a bot
# ---------------------------------------------------------------------------

type
  Actuation* = object
    ## What the decision came out as, in terms the game understands. Built
    ## whether or not it can be applied, so that observer mode logs exactly what
    ## it would have done.
    sprint*: bool
    moveTo*: Vec3
    hasMoveTarget*: bool
    lookAt*: Vec3
    hasLookTarget*: bool
    shoot*: bool
    ## The self action, mapped to the game call that performs it.
    selfCall*: string

func actuationFor*(d: Decision; b: BotView): Actuation =
  ## Pure: the decision-to-intent mapping, with no game calls in it.
  ##
  ## SAIN spends thirty-odd BigBrain action classes on this, each with its own
  ## update loop. Most of them differ only in where the bot goes, how fast, and
  ## whether it is shooting, so the mapping is a function rather than a class
  ## hierarchy, and it is testable for the same reason `core/` is.
  var a = Actuation(sprint: false, moveTo: zeroVec(), hasMoveTarget: false,
                    lookAt: b.enemy.position, hasLookTarget: b.enemy.valid,
                    shoot: false, selfCall: "")
  case d.combat
  of cdStandAndShoot, cdShootDistantEnemy, cdDogFight:
    a.shoot = true
  of cdSeekCover, cdShiftCover, cdRetreat:
    a.sprint = d.combat != cdShiftCover
    a.hasMoveTarget = true
    a.shoot = d.combat == cdRetreat and b.enemy.visible
  of cdRunAway:
    a.sprint = true
    a.hasMoveTarget = true
    a.hasLookTarget = false
  of cdRushEnemy:
    a.sprint = true
    a.moveTo = b.enemy.position
    a.hasMoveTarget = true
    a.shoot = b.enemy.visible
  of cdMoveToEngage, cdCreepOnEnemy:
    a.sprint = d.combat == cdMoveToEngage
    a.moveTo = b.enemy.position
    a.hasMoveTarget = true
  of cdSearch:
    a.moveTo = b.searchTarget
    a.hasMoveTarget = b.hasSearchTarget
  of cdAvoidGrenade:
    a.sprint = true
    a.hasMoveTarget = true
    a.hasLookTarget = false
  of cdMeleeAttack:
    a.sprint = true
    a.moveTo = b.enemy.position
    a.hasMoveTarget = true
  of cdFreeze, cdHoldInCover, cdNone:
    discard
  of cdThrowGrenade:
    a.lookAt = b.enemy.position
    a.hasLookTarget = true

  case d.self
  of saReload: a.selfCall = "reload"
  of saFirstAid: a.selfCall = "firstaid"
  of saStims: a.selfCall = "stims"
  of saSurgery: a.selfCall = "surgery"
  of saNone: discard
  result = a

proc applySelf(l: BotLive; which: string): int =
  ## The self actions, each one bound call on a component two bound calls away.
  ## All three are no-argument voids, which is the one shape the fast path is
  ## unambiguously best at -- 6.5 ns measured, against ~1000 through the host.
  result = 0
  if l.owner == nil:
    return
  if which == "reload":
    let wm = callObj(gB.boWeapon, l.owner)
    if wm == nil: return
    let rl = callObj(gB.wmReload, wm)
    if rl == nil: return
    if callVoidOn(gB.rlTryReload, rl): result = 1
    return
  let med = callObj(gB.boMedecine, l.owner)
  if med == nil:
    return
  if which == "firstaid":
    let fa = callObj(gB.medFirstAid, med)
    if fa != nil and callVoidOn(gB.faApply, fa): result = 1
  elif which == "stims":
    let stim = callObj(gB.medStims, med)
    if stim != nil and callVoidOn(gB.stimApply, stim): result = 1
  elif which == "surgery":
    let surg = callObj(gB.medSurgery, med)
    if surg != nil and callVoidOn(gB.surgApply, surg): result = 1

proc apply*(b: BotHandle; l: BotLive; a: Actuation): int =
  ## Push an actuation into the game. Returns how many calls were made, which is
  ## what the driver budgets against.
  ##
  ## Nothing is called when the bot's decision has not changed -- that check
  ## lives in the driver, because it is the driver that holds the previous
  ## actuation. Here the rule is only: one call per thing that changed.
  ##
  ## Three of the five calls are on the fast path. The two that are not are the
  ## two that take a `Vector3`, which Win64 passes by hidden pointer -- a
  ## different call shape rather than a different register class, which is
  ## precisely what `aowlspt/fast` says it does not cover. Those go through
  ## `il2cpp_runtime_invoke` with the argument array built by hand; see
  ## `live.callVec`.
  if not capable() or not l.ok:
    return 0
  var calls = 0

  if a.selfCall.len > 0:
    calls = calls + applySelf(l, a.selfCall)

  if l.owner == nil:
    return calls

  if a.hasMoveTarget:
    let mover = callObj(gB.boMover, l.owner)
    if mover != nil:
      # `flag` is the first bool parameter of whichever `GoToPoint` overload
      # resolved, which on every version of this method is "slow down at the
      # end". A sprinting bot does not.
      if callVec(gB.mvGoTo, mover, a.moveTo, not a.sprint):
        inc calls
      if callBoolArg(gB.mvSprint, mover, a.sprint):
        inc calls

  if a.hasLookTarget:
    let st = callObj(gB.boSteering, l.owner)
    if st != nil and callVec(gB.stLookTo, st, a.lookAt, false):
      inc calls

  if a.shoot:
    let sd = callObj(gB.boShoot, l.owner)
    if sd != nil and callVoidOn(gB.sdShoot, sd):
      inc calls

  result = calls
