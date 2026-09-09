## SAIN, ported to aowlspt as a from-scratch rewrite in nimony.
##
##     aowl build-mod mods/sain
##     aowl run mods/sain
##
## SAIN (Solarint, maintained by ArchangelWTF) replaces Tarkov's bot AI:
## layered decisions, per-bot personalities, real cover use, searching that
## looks like searching, and squads that behave like squads. This is a port of
## that **design**, not of that code — 64,000 lines of C# built on BepInEx,
## Harmony and BigBrain cannot be transliterated onto a post-1.0 IL2CPP client
## that has none of the three.
##
## ## Layout
##
##     core/       the decision model. Pure nimony, no game calls at all.
##       vec       vectors, and the small amount of geometry needed
##       toggle    `Toggle` / `Cooldown` -- SAIN's hysteresis primitive
##       types     the decision enums and the records a tick reads
##       settings  every threshold, resolved per personality at spawn
##       enemy     perception: seen/heard timers, last known place, threat
##       hearing   audibility, derived from motion rather than received
##       vision    acquisition, the reaction delay, last-known uncertainty
##       suppress  a bool integrated into a level with two thresholds
##       squad     a squad view queried out of this mod's own bot table
##       cover     scoring cover points; the raycast stays in the sampler
##       probe     planning a cover sample, and folding its answers back in
##       flank     where a decision sends the bot
##       search    the search state machine
##       decide    the arbiter: SAIN's 10 Hz priority cascade
##       rng       a deterministic per-bot stream
##       selftest  124 checks that need no Tarkov to run
##     preset/     config.json -> a resolved Settings per bot role
##     client/     the only files that know Tarkov exists
##       live      the IL2CPP runtime, held directly; every binding
##       bridge    reading and driving a bot; the capability probe
##       coverprobe  two Unity statics, and the sample that runs on Unity's thread
##       mainthread  whether onMainThread is really Unity's thread, asked
##       driver    who thinks, when: the budget, discovery, the raid passes
##     server/     brain forcing, per-map difficulty, the preset route
##
## ## What runs where
##
## One binary, three sides, chosen by `side()`:
##
##  * **server** -- forces the bot brain tables SAIN needs, neutralises BSG's
##    per-map difficulty skew, serves the resolved preset on `/sain/preset`.
##  * **client** -- probes what the IL2CPP host can reach, then drives bots.
##  * **sim** -- runs the decision core's scenario tests and reports.
##
## ## What is honestly not here
##
## **`README.md` is the map**: every feature of SAIN, against whether it is
## implemented here, blocked on a sensor this mod cannot reach, or out of reach
## post-1.0 for good. It also carries the measured cost, the test coverage and
## every remaining refusal. Read it before expecting bots to behave differently
## in a raid, and read it rather than this comment when the two disagree.
##
## The one thing that cannot be repeated too often: **nothing here has been run
## against Tarkov**. Every EFT member name in `client/live.nim` is a name from
## the pre-1.0 C# surface, and post-1.0 is a different build; a wrong one
## refuses its binding, logs why, and falls back to a default. The binding
## report `announce()` prints once is the only thing that says which.

import aowlspt
import aowlspt/game
import aowlspt/json
import aowlspt/fast
import aowlspt/il2cpp
import aowlspt/fixture # where a self-test's runtime path may come from
import aowlspt/server   # `serve` -- the settings route this mod registers
import aowlspt/settings # the F12 settings schema this mod declares
import core/vec
import core/types
import core/probe
import core/sig
import core/selftest
import core/objective
import preset/preset
import core/settings
import client/bridge
import client/driver
import client/live
import client/rvatable  # AimIsReadySpec, SainRvaScope
import client/coverprobe
import client/mainthread
import server/serverside
import server/dispatch

var gWorld = whenReady("EFT.GameWorld")
var gDeferNoted = false
var gPreset: Preset
var gProbedAt = 0'i64

# --- THE PER-RAID CENSUS, and WHEN it is emitted.
#
# Twice, and both times for a reason:
#
#  1. `CensusAtMs` after the mod first reaches capFull. A coordinator running
#     one raid per level needs the verdicts while the raid is still up, because
#     a raid that is exited by killing the client never reaches an unload path
#     at all -- which is how every previous "we will report it at the end"
#     instrument produced nothing.
#  2. On the transition OUT of capFull, and on unload. That is the complete
#     raid, and its numbers supersede the first emission rather than repeat it;
#     each is labelled with which it is.
#
# It is NOT emitted per tick. The census walks the 45-member table and builds
# strings; that is a reporting cost, not a frame cost, and rule 7 is explicit
# that nothing in an update path may allocate per frame.
const CensusAtMs = 60_000'i64
  ## One minute into a raid. Long enough that bots have spawned, been scanned,
  ## been decided about and had a chance to be shot at; short enough that a
  ## coordinator does not have to keep a raid alive to get an answer.
var gCensusAt = 0'i64
var gCensusEarlyDone = false
var gCensusFinalDone = false
var gWasFull = false

proc emitCensus(label: string) =
  ## The lines a coordinator greps for after a raid. Every one of them is a
  ## statement about the FINISHED STATE -- what bound, what was ordered, what
  ## came back -- and not about what this mod attempted.
  info "sain CENSUS (" & label & ") -- sainRvaTableDriveLevel = " &
       rvaLevelName(rvaDriveLevel())
  info levelCensusLine("reads")
  info levelOneVerdict(aliveCount())
  info coverVerdict()
  info firedAtUsVerdict()
  if rvaDriveLevel() >= RvaLevelAim:
    info levelCensusLine("aim")
  else:
    info "sain LEVEL 2: not censused -- sainRvaTableDriveLevel is " &
         rvaLevelName(rvaDriveLevel()) & " and the aim route needs " &
         rvaLevelName(RvaLevelAim) & ". This is a refusal by configuration."
  if rvaDriveLevel() >= RvaLevelDrive:
    info levelCensusLine("drive")
  else:
    info "sain LEVEL 3: not censused -- sainRvaTableDriveLevel is " &
         rvaLevelName(rvaDriveLevel()) & " and the drive calls need " &
         rvaLevelName(RvaLevelDrive) & ". This is a refusal by configuration."
  info decisionKindLine()
  let dk = driveKindLines()
  var i = 0
  while i < dk.len:
    info dk[i]
    inc i
var gHooked = false

## The methods that might carry a newly activated bot as an argument.
##
## One name would be a guess; a short list tried in order is the same guess with
## the failures visible. The first that patches wins and the rest are not tried,
## because two hooks on the same event would register every bot twice -- which
## `spawnBot` would absorb, but silently, and a silent absorption of a wrong
## assumption is how a mod ends up with nobody able to say what it is doing.
##
## Every candidate takes the bot (or its `IPlayer`) as its **first declared
## argument**. That used to be a hard requirement rather than a preference,
## because a hook could not turn what it was called *on* into anything usable.
## It is now only a preference -- `thisPointer` reaches the instance too -- but
## the argument is still the better place to read from here: `AddActivePLayer`
## is called on the controller and carries the bot, so the argument is the bot
## and the instance is the controller.
##
## BY RVA, NOT BY NAME, and that is the whole of why this mod can install a
## detour at all on this build.
##
## Asking the host to patch `"EFT.BotsController::AddActivePLayer"` makes the
## host resolve that name through the IL2CPP C API, and fact #35 says by-name
## resolution returns a NON-NIL handle into UNMAPPED memory. The host then
## patched at that address. MEASURED: that call was the last line this mod ever
## logged before the client died at 9.250s. It is the same root cause as
## `get_Instance`, one layer out -- on this build every by-name route is fatal
## the moment it is USED, and a patch is a use.
##
## The host's own drains already take the other route (`patch-by-RVA
## EFT.TarkovApplication::Update ... il2cpp+0x977b10` in the boot log), and the
## grammar is open to mods through the same `target` string:
##
##     Type::Method@0xRVA/<shape>[!<hex prologue>]
##
## `<shape>` is `i`/`s` (instance/static), one letter per DECLARED argument,
## then `>` and the return letter. It is REQUIRED: there is no MethodInfo
## behind an RVA, so the host cannot derive the frame and refuses to guess it.
##
## `!<hex>` is REQUIRED HERE TOO, by this mod rather than by the host. Without
## it `aowl_pro_verify` returns 1 having compared nothing, and the boot log says
## so -- "NO prologue signature was declared, so NOTHING was byte-compared".
## That is a check that cannot fail (CLAUDE.md 9b), and on a detour it is a
## write with unbounded blast radius. The bytes come from `il2cpp_resolve.py
## bytes <RVA> 16` against GameAssembly.dll ON DISK, and the host compares them
## against its STARTUP SNAPSHOT (`abi/aowlspt_prologue.h`) rather than live
## memory -- so a second feature verifying a function a first feature already
## detoured reads the original bytes, not a trampoline.
##
## MEASURED, `il2cpp_resolve.py type 6489 --shared`:
##   void AddActivePLayer(Player player)   rid=41021  RVA=0x254ce30  NOT shared
##   prologue 48 83 79 28 00 74 0C 48 8B 49 28 45 33 C0 E9 9D
##
## Shape `io>x`: instance, one reference argument (`Player`), void return.
##
## EXPECT THIS ONE TO BE REFUSED, and that is a real answer rather than a
## failure. Those 16 bytes contain a short branch (`74 0C`) at byte 5 and a
## near jump (`E9`) at byte 14 -- relative branches inside the region a detour
## must relocate, which is exactly the "prologue holding a relative branch"
## case the fallback note below was written for. The world scan still finds
## every bot, half a second later and without a spawn type.
##
## The two alternates this ladder used to carry are GONE rather than left as
## by-name entries. `EFT.BotSpawner::AddPlayer` and the `AddActivePlayer`
## spelling were never measured, and an unmeasured name is not a fallback on
## this build -- it is the fatal path wearing a fallback's clothes.
const SpawnHookCandidates: array[1, string] = [
  "EFT.BotsController::AddActivePLayer@0x254ce30/io>x" &
  "!4883792800740C488B49284533C0E99D"]

## The methods that might tell us a player died.
##
## `OnDead` is an instance method on the player that died, which is exactly the
## shape that was unreachable before ABI revision 3: the payload named the
## arguments and not the instance, so the handler learned that *a* player had
## died. `thisPointer` is the whole difference, and it is why the death poll in
## `client/driver.nim` can now be turned off.
##
## BY RVA for the same measured reason as the spawn ladder above.
##
## MEASURED, `il2cpp_resolve.py type 7013 --shared`:
##   void OnDead(EDamageType damageType)  rid=42620  RVA=0x732c30  NOT shared
##   prologue 48 89 5C 24 10 48 89 4C 24 08 56 57 41 54 41 56
##
## Shape `ii>x`: instance, one integer argument (an enum is an `Int32` in a
## register), void return.
##
## This prologue is a plain register-save sequence with no relative branch in
## it, so unlike the spawn target it is a shape a detour can relocate.
##
## `Kill` and `OnBeenKilledByAggressor` are dropped for the same reason the
## spawn alternates are: they resolve (they are real -- rid 42618 and others in
## the same dump) but they were never byte-measured, and shipping an unverified
## RVA would be the blind write rule 8 forbids. Adding either back is one
## `il2cpp_resolve.py bytes` call away.
const DeathHookCandidates: array[1, string] = [
  "EFT.Player::OnDead@0x732c30/ii>x" &
  "!48895C241048894C2408565741544156"]

proc onBotAdded(target, payload: string): HookResult =
  ## Fired by a detour on the game's own bot activation, **with the bot**.
  ##
  ## Two things happen here and they are separated on purpose.
  ##
  ## The **identity** -- profile id and spawn type -- is read on the host's
  ## boxed path, four or five calls at about a microsecond each. That is the
  ## right trade for something that happens once per bot per raid, and the
  ## spawn type in particular is an enum whose `ToString` is the stable answer
  ## across a client renumbering.
  ##
  ## The **address** goes through `pointerOf`, which is 9 ns against the 1068
  ## the boxed read of the same thing costs, and it is the reason this proc
  ## changed at all. Before ABI revision 3 there was no route from a host
  ## `Handle` to the raw pointer `aowlspt/fast` needs, so this registered the
  ## bot by id and left it to the 2 Hz world scan to find the object again --
  ## up to half a second during which the bot was being decided about from
  ## defaults, because there was nothing to read it through. Now the GC handle
  ## is taken on the frame the bot spawns.
  let argsRaw = memberRaw(payload, "args")
  if argsRaw.len == 0:
    return carryOn()
  let arr = whole(argsRaw)
  let first = at(arr, 0)
  if not exists(first):
    return carryOn()
  var cr = CallResult(ok: true, raw: raw(first), error: "")
  let who = asObject(cr)
  if not who.ok:
    return carryOn()

  let id = asText(who.get("ProfileId"))
  var role = ""
  let prof = who.child("Profile")
  if prof.ok:
    let inf = prof.child("Info")
    if inf.ok:
      let cfg = inf.child("Settings")
      if cfg.ok:
        let r = cfg.child("Role")
        if r.ok:
          # `Role` is a `WildSpawnType`, an enum. The host hands a boxed enum
          # back as an object rather than a number, and `ToString` on it is the
          # member name -- which is exactly what `roleFromSpawnType` wants and
          # is stable across the ordinal renumbering that a client update does.
          role = asText(r.invoke("ToString"))
          release(r)
        release(cfg)
      release(inf)
    release(prof)

  if id.len > 0:
    # -1 difficulty means "the preset decides"; the game's own `BotDifficulty`
    # is a second enum read and the preset's per-role difficulty is what SAIN
    # actually tunes against.
    spawnBot(id, role, -1.0)

    # And the address, while the handler is still running -- which is the only
    # time it is valid. `attachPointer` turns it into this mod's own IL2CPP GC
    # handle immediately, so nothing outlives the handler except a handle the
    # collector knows about.
    #
    # A refusal here is not a failure: the world scan is still the reconciler
    # and will attach the bot on its next pass, exactly as it did before. What
    # is *not* done is guessing -- if the argument turns out to be a
    # `BotOwner` rather than a player, `profileIdOf` on it refuses and comes
    # back empty, and the pointer is dropped rather than attached to the wrong
    # object.
    let h = handleIn(raw(first))
    if h != 0'u64:
      var addr1 = 0'u64
      if pointerOf(h, addr1) == Ok and addr1 != 0'u64:
        let p = cast[Il2CppPtr](addr1)
        if profileIdOf(p) == id:
          attachPointer(id, p)
        elif gPreset.logDecisions:
          debug "sain: the spawn hook's argument is not the bot's Player; " &
                "leaving the attach to the world scan"

  release(who)
  carryOn()

proc onPlayerDead(target, payload: string): HookResult =
  ## Fired on the player that died, **by the player that died**.
  ##
  ## This is the hook that could not be written before ABI revision 3.
  ## `hookArgs` reported a method's declared arguments and not the instance it
  ## was called on, so a detour here fired knowing that a player had died and
  ## not which one -- which is no use at all, and is why `client/driver.nim`
  ## polled `HealthController.IsAlive` for every bot on every decision instead.
  ##
  ## The handler does as little as it can. It takes the address, queues it, and
  ## returns: it runs on the game's thread, and the bot table it would have to
  ## walk is owned by the host's. `driver.drainDeaths` does the matching one
  ## tick later, on the right thread, at a cost of one pointer compare per bot
  ## on the rare ticks where anything died at all.
  let who = thisPointer(payload)
  if who != 0'u64:
    noteDeath(who)
  carryOn()
# `Owner::Member` split, so a candidate can be written once as the string the
# host's `patch` wants and still be asked about through the runtime, which
# wants the two halves. Two procs rather than a tuple because nimony's tuple
# ergonomics buy nothing here and a name says what each half is.

proc ownerOf(target: string): string =
  result = target
  var i = 0
  while i + 1 < target.len:
    if target[i] == ':' and target[i + 1] == ':':
      return target.substr(0, i - 1)
    inc i

proc memberOf(target: string): string =
  result = target
  var i = 0
  while i + 1 < target.len:
    if target[i] == ':' and target[i + 1] == ':':
      return target.substr(i + 2, target.len - 1)
    inc i

## The methods that might carry a bot's aim result.
##
## The first of the two postfixes `README.md` names, and it is first because it
## is the one that fires per bot per frame -- the rate the whole typed path
## exists for.
##
## **What it is for.** The game's own aim component knows whether a bot's aim
## has settled on its target. SAIN reads `BotOwner.AimingData.IsReady` and uses
## it to stop a bot firing before the aim has converged, which is the difference
## between a bot that shoots and a bot that sprays from the hip the instant it
## has a line. This port had no route to it: a bound call per bot per frame is
## the wrong shape for a fact the game recomputes every frame anyway, and a JSON
## postfix at ~443 ns per bot per frame is 1.06 ms a frame at forty bots, which
## is six percent of a 60 fps budget for one bool.
##
## The typed postfix is that same bool for two register reads, and `this` --
## the aim component's own address -- comes out of RCX rather than out of a GC
## handle the host took out and gave back per firing.
##
## Three names, tried in order, each checked against the runtime before
## anything is done with it. `AimDataClass` is the spelling SAIN's own C# uses;
## the other two are the shapes a post-1.0 rename would plausibly take. All
## three may be wrong, in which case all three refuse with the reason in the
## log and every bot shoots exactly as it does today -- see the gate in
## `client/driver.nim` for why that is the only failure this sensor has.
##
## MEASURED OFFLINE, so that "all three may be wrong" stops being a guess:
## `tools/il2cpp_resolve.py <GameAssembly.dll> <metadata.dec> find
## AimDataClass` returns NOTHING on this build. `EFT.AimDataClass` is not a
## type here at all, so the first candidate can only ever be refused and this
## says so rather than letting it fall through as if it had merely not matched.
const AimHookCandidates: array[3, string] = [
  "EFT.AimDataClass::get_IsReady",
  "EFT.BotAimingData::get_IsReady",
  "EFT.BotOwner::get_AimingIsReady"]

const AimCandidateNotes: array[3, string] = [
  "EFT.AimDataClass does not exist on this build -- measured offline with " &
    "tools/il2cpp_resolve.py find, which returns no such type. This is SAIN's " &
    "own C# spelling and it did not survive post-1.0",
  "",
  ""]

## The methods that might carry a damage event.
##
## The second candidate, and the one whose rate `README.md` got wrong. Damage
## is not per bot per frame: it is per *hit*, which is zero on almost every
## tick of a raid and a dozen in the tick a full-auto magazine goes into a
## squad. That distribution is the worst possible one for a JSON payload --
## affordable on average, and a spike exactly when the frame is already the
## busiest it will be.
##
## **What it is for.** `core/suppress.nim` integrates `IsUnderFire` over time
## and steps the accumulator for every health drop, and the health drop is
## inferred from two samples taken at the *decision* rate. On an eight-bot
## budget a thirty-bot raid samples each bot every four ticks, so a burst and
## the flinch it should cause can be 400 ms apart, and two hits with a
## regeneration between them net out to less than either. Being told each hit
## as it lands removes both errors, and `feed`'s `told` parameter is where it
## goes -- through the same rise as the health delta, so that a threshold in
## `settings.nim` means one thing whichever reading a host can produce.
##
## `this` is the victim, which is what makes this usable at all: the address in
## RCX is matched against the bot table exactly the way the death hook's is.
## Nothing is read out of a `DamageInfo` -- see `onPlayerDamagedTyped`.
const DamageHookCandidates: array[3, string] = [
  "EFT.Player::ApplyDamageInfo",
  "EFT.Player::ApplyShot",
  "EFT.ActiveHealthController::ApplyDamage"]

# The measured cost of each, in the mod, on this client's own clock.
#
# `docs/PERF.md`'s figures are a stand-in runtime on somebody else's machine.
# This mod's whole argument for converting these two hooks is a number, and a
# number that is not re-measured where it is being claimed is a number that
# quietly stops being true. `mods/classicmovement` reports `tiltCostNs` the
# same way and for the same reason.
const HookCostSamples = 512
  ## How many firings are timed before the measurement stops. Two `perfCounter`
  ## calls are about forty nanoseconds, which is the same order as the work
  ## being measured, so measuring forever would be paying for a number nobody
  ## reads twice.

var gAimHookNs = 0'i64
var gAimHookSamples = 0
var gAimHookState = "not attempted"
var gDamageHookNs = 0'i64
var gDamageHookSamples = 0
var gDamageHookState = "not attempted"
var gDamageTyped = false
var gDamageInfoArg = -1
  ## Which declared parameter carries the `EFT.Ballistics.DamageInfo`, or -1
  ## for a shape whose layout this mod has not measured.
  ##
  ## SET IN EXACTLY ONE PLACE, the by-RVA arm below, and never by the by-name
  ## path. The offsets in `live.shooterFromDamageInfo` were measured for THIS
  ## signature on THIS build; reading them out of some other method's argument
  ## because it happened to be called DamageInfo would be a foreign read that
  ## answers rather than faults.
var gDamageAmountArg = -1
  ## Which declared parameter carries the damage, or -1 for a shape that has
  ## none. Settled once, in `armDamageHook`, out of the runtime's own metadata
  ## -- see `onPlayerDamagedTyped` for why it is not asked per firing.

proc aimHookCostNs(): int64 =
  if gAimHookSamples <= 0: return -1'i64
  result = gAimHookNs div int64(gAimHookSamples)

proc damageHookCostNs(): int64 =
  if gDamageHookSamples <= 0: return -1'i64
  result = gDamageHookNs div int64(gDamageHookSamples)

proc onBotAimTyped(f: PatchFrame): TypedResult =
  ## The aim result, out of the registers the detour already saved.
  ##
  ## Six operations: read the clock, read `this`, read the return, hash an
  ## address, three stores, read the clock. Nothing allocates, nothing calls
  ## back into the host, and nothing here touches the bot table -- this runs on
  ## whichever thread the game called the aim from, and the table belongs to
  ## the host's. `driver.noteAim` is the whole handler body for that reason.
  ##
  ## It **watches**. `frameContinue()` rather than a replacement, and that is a
  ## decision rather than a limitation: the typed frame would let this rewrite
  ## the readiness for 37 ns, and SAIN's C# does modulate bot aim by
  ## personality. Rewriting a gate this port has never seen fire, on a method
  ## whose name is a guess, would be inventing behaviour rather than porting
  ## it. The capability is there; the knowledge is not.
  let measuring = gAimHookSamples < HookCostSamples
  var t0 = 0'i64
  if measuring: t0 = perfCounter()
  let who = f.selfPointer()
  if who == 0'u64:
    # A static method, or an expired frame. Either way there is no component to
    # attribute the reading to, and a reading attributed to nobody is worse
    # than no reading -- it would sit in a slot some other component hashes to.
    return frameContinue()
  var ok = false
  let ready = f.resultInt(ok)
  if not ok:
    # The declared return is not an integer kind, or this is a prefix frame and
    # the original has not run. `armAimHook` checked the signature against the
    # runtime before arming, so this is the belt to that braces.
    return frameContinue()
  noteAim(who, ready != 0'i64)
  if measuring:
    gAimHookNs = gAimHookNs + nanosBetween(t0, perfCounter())
    gAimHookSamples = gAimHookSamples + 1
  frameContinue()

proc onPlayerDamagedTyped(f: PatchFrame): TypedResult =
  ## A hit, at the moment it lands, on the player that took it.
  ##
  ## **The amount is taken by declared kind, never by position** -- and *which*
  ## position that is was settled once, at registration, by `armDamageHook`
  ## reading the method's declared parameter types. The kind table would answer
  ## it per firing too, and cheaply, but every `kindOf` across the ABI is an
  ## ordinary cross-module call rather than an inlined load, so scanning four
  ## parameters cost about thirty nanoseconds a hit more than reading the one
  ## index that matters. That is the same lesson the typed path itself is
  ## built on -- ask the shape once -- applied one level up. The first float
  ## parameter is the amount on every shape this hook accepts; a shape with
  ## none is still a usable event, with an amount of zero, which `drainDamage`
  ## credits as the smallest step the accumulator has.
  ##
  ## **Nothing is read out of the `DamageInfo`.** It is a value type wider than
  ## a register, so it arrives as `akBigValue` -- a pointer to a copy whose
  ## layout the host cannot read, and which this mod would have to know field
  ## offsets on a build nobody has dumped to make sense of. The kind table says
  ## so outright rather than letting an `argPointer` read produce a plausible
  ## address, and that refusal is why the aggressor is still not known here.
  ## `README.md`'s `firedAtUsThisTick` row is unchanged by this hook.
  ##
  ## It watches. A typed postfix could replace the damage for 37 ns, and this
  ## mod has no setting that asks it to; SAIN's damage scaling is a server-side
  ## difficulty concern that `server/serverside.nim` already expresses as a
  ## database write.
  let measuring = gDamageHookSamples < HookCostSamples
  var t0 = 0'i64
  if measuring: t0 = perfCounter()
  let who = f.selfPointer()
  if who == 0'u64:
    return frameContinue()
  var amount = 0.0
  if gDamageAmountArg >= 0:
    var ok = false
    let v = f.argFloat(gDamageAmountArg, ok)
    if ok and v > 0.0:
      amount = v
  # WHO SHOT, when the frame carries a DamageInfo this mod knows the shape of.
  #
  # `gDamageInfoArg` is -1 on every by-name shape, so this is inert unless the
  # hook armed by RVA on the one signature whose DamageInfo is measured. The
  # walk itself is guarded and reports its own refusals; nothing is credited
  # here, only queued, and `driver.drainDamage` is where a candidate has to
  # match a player this mod already holds before it becomes an attribution.
  var shooter = 0'u64
  if gDamageInfoArg >= 0:
    var pok = false
    let di = f.argPointer(gDamageInfoArg, pok)
    if pok:
      shooter = shooterFromDamageInfo(di)
  noteDamage(who, amount, shooter)
  if measuring:
    gDamageHookNs = gDamageHookNs + nanosBetween(t0, perfCounter())
    gDamageHookSamples = gDamageHookSamples + 1
  frameContinue()

proc onPlayerDamaged(target, payload: string): HookResult =
  ## The JSON fallback for the damage hook, on a host older than revision 4.
  ##
  ## It exists for the reason `armDamageHook` gives: a hit is an event rather
  ## than a per-frame cost, so 1.6 us times zero-on-most-ticks is a real price
  ## and not a disqualifying one. It reads exactly what the typed form reads --
  ## the instance, and the first number in the argument list -- and it is
  ## slower by forty-fold because the host had to build that description out of
  ## registers it already had.
  let who = thisPointer(payload)
  if who == 0'u64:
    return keepResult()
  var amount = 0.0
  if gDamageAmountArg >= 0:
    let argsRaw = memberRaw(payload, "args")
    if argsRaw.len > 0:
      let a = at(whole(argsRaw), gDamageAmountArg)
      if exists(a):
        let r = CallResult(ok: true, raw: raw(a), error: "")
        let v = r.asFloat(0.0)
        if v > 0.0:
          amount = v
  noteDamage(who, amount)
  keepResult()

proc armAimHook() =
  ## The aim postfix, typed or not at all.
  ##
  ## **Not at all**, and that is the one place this differs from
  ## `mods/classicmovement`, which falls back to the JSON form on an older
  ## host. The reason is the rate. A JSON postfix that only watches a return
  ## value is ~443 ns; this method is called once per bot per frame, so forty
  ## bots at 60 fps is 1.06 ms a frame -- six percent of the budget, for a bool
  ## whose entire use is to withhold a shot the bot would otherwise take a
  ## fraction of a second early. That was this mod's stated objection to
  ## postfix hooks before the typed path existed and it is still the correct
  ## answer on a host that does not have one. So: the typed form, or the
  ## sensor stays absent and says why.
  if not typedPatchesReady():
    gAimHookState = "refused: this host has no typed patch frame (it is ABI " &
                    "revision " & $hostApiSize() & " bytes of HostApi, and " &
                    "the frame wants revision 4). The JSON postfix that " &
                    "would work here is ~443 ns per bot per frame, which is " &
                    "1.06 ms a frame at forty bots -- a frame tax for one " &
                    "bool, so the sensor stays off rather than being paid for"
    return
  # AND BEFORE ANY OF THAT: this ladder's first act on every candidate is
  # `signatureOf`, which is the by-name resolution that killed the client in
  # `bindProbe` a tenth of a second earlier. Refused up front, with the real
  # reason, because the loop below would otherwise fall through all three
  # candidates and report "none of them exists on this build" -- which is not
  # what happened and would send the next reader hunting for renamed types.
  # --- THE RVA ROUTE, TRIED FIRST, and it is the only one that can work on
  # this build.
  #
  # The three name candidates below are kept, unchanged, as the record of what
  # was tried and why it failed -- but every one of them goes through
  # `signatureOf`, which is the by-name resolution that kills the client here,
  # so the whole ladder is refused a few lines down and always was. The
  # measured history: `EFT.AimDataClass` does not exist on this build;
  # `EFT.BotAimingData` exists as a TYPE but nothing in the image ever returns
  # one, so a hook on it could never have fired; `EFT.BotOwner::
  # get_AimingIsReady` does not exist. That is a sensor that was dead in three
  # different ways and reported "armed" in none of them.
  #
  # An `@0x` spec needs no class lookup and no MethodInfo: the host's
  # `parseRvaSpec` carries the frame shape (`i>i` -- instance, no declared
  # arguments, integer/bool return) and the 16 prologue bytes after `!`, and
  # `resolveByRva` checks the module base, that the address is committed
  # executable memory with 16 whole bytes in one region, that it is inside
  # GameAssembly's `il2cpp` PE section, and that those bytes match the STARTUP
  # SNAPSHOT rather than live memory -- so another feature's trampoline cannot
  # make a correct address self-reject. Four gates, none of them ours to
  # reimplement, and a refusal that names the gate that failed.
  #
  # `Aiming::get_IsReady` @0x1AD48C0 is UNIQUE (owners=1), so this is not a
  # detour on a folded address, and no other RVA anywhere in this repo names
  # it, so it is not a second detour on an already-detoured function.
  if rvaTableOn() and rvaDriveLevel() >= RvaLevelAim:
    info "sain: aim postfix -- installing by VERIFIED STATIC RVA: " &
         AimIsReadySpec
    if hookReturnTyped(AimIsReadySpec, onBotAimTyped) == Ok:
      setAimHooked(true)
      # The bind-time READBACK. It states what was AUDITED about this one
      # detour rather than that the install call returned Ok -- "Ok" is the
      # host agreeing with itself, which is the check that cannot fail
      # (CLAUDE.md 9b). Every clause below was measured OFFLINE against the
      # shipped image on 2026-09-02 and is recorded in docs/AOWL_FACTS.md:
      # `il2cpp_resolve.py shared 0x1AD48C0` = UNIQUE owners=1; `bytes
      # 0x1AD48C0` = the 16 bytes in AimIsReadySpec, byte for byte; the four
      # instructions covering the host's 14-byte jump end exactly on 16, so
      # nothing is split; the only relative operand is the disp32 of `cmp
      # byte [rip+0x55eb0bb], 0` at +0x06, which is a class-init guard the
      # host's `aowl_copy_relocated` rewrites (a relative BRANCH would be
      # refused outright, and there is none); and disassembly to the first
      # `ret` finds in-function branch targets only at +0x3B and +0x62, so
      # nothing jumps back into the bytes the jump overwrites.
      info "sain: aim postfix BOUND at 0x1AD48C0 Aiming::get_IsReady " &
           "(UNIQUE owners=1, 16/16 prologue bytes verified, 4 whole " &
           "instructions ending exactly on the 16-byte boundary so none is " &
           "split, no relative branch, one RIP-relative disp32 at +0x06 " &
           "which the host relocates, no in-function branch target below " &
           "+0x10). ARITY 0 INSTANCE: RCX=this and RDX=MethodInfo* only, so " &
           "the thunk's fifth-and-later STACK arguments -- which it does not " &
           "forward -- cannot apply here. The handler allocates nothing and " &
           "runs to three array stores. BOUND IS NOT FIRED: the driver " &
           "status line's fired/matched/withheld triple is the only thing " &
           "that settles that"
      gAimHookState = "armed by static RVA on Aiming::get_IsReady @0x1AD48C0 " &
                      "(UNIQUE, 16/16 prologue bytes verified by the host " &
                      "against its startup snapshot), withholding a shot " &
                      "until the game says the aim has settled. Whether it " &
                      "FIRES is a separate question and is reported " &
                      "separately: see the fired/matched/withheld counts in " &
                      "the driver status line, and the one-shot AIM POSTFIX " &
                      "FIRED line. Armed is not fired"
      return
    gAimHookState = "refused: the by-RVA install of " & AimIsReadySpec &
                    " did not take -- " & lastError() &
                    ". The host names the gate that failed (module base, code " &
                    "page, il2cpp section, or the prologue byte-compare " &
                    "against its startup snapshot). A prologue mismatch here " &
                    "means the installed GameAssembly.dll is not " &
                    SainRvaScope & " and every RVA in client/rvatable.nim " &
                    "must be re-derived. Bots shoot when the ladder says so"
    return
  elif rvaTableOn():
    gAimHookState = "refused: sainRvaTableDriveLevel is " &
                    rvaLevelName(rvaDriveLevel()) & " and the aim route needs " &
                    rvaLevelName(RvaLevelAim) &
                    ". Nothing was patched. This is a refusal by " &
                    "configuration, not a measurement"
    return

  if reflectionRefused():
    gAimHookState = "refused: " & ReflectionRefusal &
                    " Every candidate below is checked with signatureOf " &
                    "before it is patched, so none can be checked and none " &
                    "is patched. Bots shoot when the decision ladder says " &
                    "so, exactly as they did before this sensor existed. The " &
                    "RVA route above is the way past this and it needs " &
                    "sainRvaTable on at drive level " & $RvaLevelAim &
                    " or higher"
    return
  var tried = 0
  var j = 0
  while j < AimHookCandidates.len:
    let name = AimHookCandidates[j]
    let note = AimCandidateNotes[j]
    inc j
    if note.len > 0:
      # Named, not skipped silently. An offline measurement that a type is
      # absent is a real answer and belongs in the log beside the refusal.
      info "sain: aim postfix -- skipping " & name & ": " & note
      continue
    var params: seq[string] = @[]
    var ret = ""
    if not signatureOf(ownerOf(name), memberOf(name), -1, params, ret):
      continue
    tried = tried + 1
    if params.len != 0:
      gAimHookState = "refused: " & name & " is " & describeSig(params, ret) &
                      ", and a readiness getter should take none; the name " &
                      "has probably resolved to something else"
      continue
    if ret != "System.Boolean":
      # Refused here as well as by the host, so that the message names *this
      # mod's* assumption rather than the engine's constraint. Reading a
      # reference return as an integer would answer an address, and an address
      # is nonzero -- which is "the aim is ready" every single frame.
      gAimHookState = "refused: " & name & " is " & describeSig(params, ret) &
                      ", and this reads a bool"
      continue
    info "sain: aim postfix -- attempting the typed detour on " & name
    if hookReturnTyped(name, onBotAimTyped) == Ok:
      setAimHooked(true)
      gAimHookState = "armed on the typed path on " & name &
                      ", withholding a shot until the game says the aim has " &
                      "settled"
      info "sain: bot aim result hooked on " & name & " (typed frame)"
      return
    gAimHookState = "refused: " & lastError()
  if tried == 0:
    gAimHookState = "refused: none of the " & $AimHookCandidates.len &
                    " candidate aim members exists on this build; bots " &
                    "shoot when the ladder says so, exactly as before"

proc armDamageHookByRva(): bool =
  ## The damage prefix on a VERIFIED STATIC ADDRESS.
  ##
  ## This is the route past the refusal the by-name path below states: every
  ## candidate there is checked with `signatureOf` first, `signatureOf` is the
  ## token-gated by-name path, so on this build NOTHING arms and the hook has
  ## never fired in a raid. An `@0x` spec resolves no name at all.
  ##
  ## PREFIX, not postfix, and the slot count is why it is allowed to be either:
  ## `EFT.Player::OnHealthApplyDamage(EBodyPart, float, DamageInfo)` is 4
  ## register slots including `this`, so no argument of it lives on the
  ## caller's stack and the >4-slot postfix hazard cannot apply. It is bound as
  ## a prefix anyway because the handler reads and never writes, and a prefix
  ## has no return value it could get wrong.
  ##
  ## Level 1. Nothing about it changes the game's state: it reads three
  ## registers, walks two guarded field hops, and appends to a fixed ring.
  result = false
  if not (rvaTableOn() and rvaDriveLevel() >= RvaLevelReads):
    gDamageHookState = "refused: the by-RVA damage prefix needs sainRvaTable " &
      "on at sainRvaTableDriveLevel >= " & $RvaLevelReads & "; it is " &
      (if rvaTableOn(): "on at " & rvaLevelName(rvaDriveLevel()) else: "OFF") &
      ". This is a refusal by configuration, not a measurement"
    return
  if not typedPatchesReady():
    gDamageHookState = "refused: the typed frame needs host ABI revision 4 " &
      "and this host reports " & $hostApiSize() & " bytes of HostApi. There " &
      "is no JSON fallback for this route: the JSON payload cannot carry a " &
      "pointer to a by-value DamageInfo copy, which is the whole argument " &
      "this hook exists to read"
    return
  info "sain: damage prefix -- installing by VERIFIED STATIC RVA: " &
       DamageShooterSpec
  if hookTyped(DamageShooterSpec, onPlayerDamagedTyped) != Ok:
    gDamageHookState = "refused: the by-RVA install of " & DamageShooterSpec &
      " did not take -- " & lastError() & ". The host names the gate that " &
      "failed (module base, code page, il2cpp section, or the prologue " &
      "byte-compare against its startup snapshot). A prologue mismatch means " &
      "the installed GameAssembly.dll is not " & SainRvaScope
    return
  setDamageHooked(true)
  gDamageTyped = true
  # THE ARGUMENT INDICES, from the DECLARED signature in the spec's own shape
  # letters (`iifV`), not guessed and not searched for at run time: argument 0
  # is EBodyPart, 1 is the float damage, 2 is the DamageInfo.
  gDamageAmountArg = 1
  gDamageInfoArg = 2
  gDamageHookState = "armed by static RVA on EFT.Player::OnHealthApplyDamage " &
    "@0x7395E0 (UNIQUE owners=1, 16/16 prologue bytes verified by the host " &
    "against its startup snapshot, 4 register slots so no argument is on the " &
    "caller's stack), telling suppression each hit as it lands AND walking " &
    "DamageInfo.Player@0x60 -> PlayerBridge._player@0x18 for the shooter. " &
    "ARMED IS NOT FIRED and a walk is not an identification: the FIRED-AT-US " &
    "VERDICT line in the census is the only thing that settles either, and it " &
    "counts candidates that matched NOTHING as the falsifier"
  info "sain: damage prefix BOUND at 0x7395E0 EFT.Player::OnHealthApplyDamage"
  result = true

proc armDamageHook() =
  ## The damage postfix, typed where the host has it and JSON where it does
  ## not.
  ##
  ## **Unlike the aim hook, this one does fall back**, and the difference is
  ## the rate rather than a change of mind. A hit is an event: zero on almost
  ## every tick, a burst of a dozen on the worst one. 1615 ns times zero is
  ## nothing, so the JSON form is affordable in the steady state and is a spike
  ## only in the tick where a magazine lands -- which is a real cost and not a
  ## disqualifying one, in the way that a per-bot-per-frame payload is. Which
  ## form armed is in the state line, because the two are forty-fold apart and
  ## "armed" alone would hide that.
  ##
  ## The same up-front refusal as `armAimHook`, for the same measured reason:
  ## every candidate here is checked with `signatureOf` first, and `signatureOf`
  ## is the by-name path that takes the client down on this build.
  ##
  ## THE BY-RVA PREFIX IS TRIED FIRST and returns on success. What follows is
  ## not a fallback for it: it is the pre-RVA path, and on this build it cannot
  ## arm at all, because every candidate is checked with `signatureOf` first.
  ## When the RVA table is on, the by-name ladder is not even entered -- there
  ## is nothing to gain from walking a ladder whose every rung is a refusal,
  ## and entering it would overwrite the by-RVA refusal reason with a vaguer
  ## one.
  if armDamageHookByRva():
    return
  if rvaTableOn():
    return
  if reflectionRefused():
    gDamageHookState = "refused: " & ReflectionRefusal &
                       " Suppression keeps inferring hits from the health " &
                       "delta between two decisions, which is up to four " &
                       "ticks late and nets two hits against a regeneration " &
                       "-- degraded, and it is what this mod did before the " &
                       "hook existed"
    return
  var tried = 0
  var j = 0
  while j < DamageHookCandidates.len:
    let name = DamageHookCandidates[j]
    inc j
    var params: seq[string] = @[]
    var ret = ""
    if not signatureOf(ownerOf(name), memberOf(name), -1, params, ret):
      continue
    tried = tried + 1
    # Which parameter is the amount, decided here rather than per firing. The
    # declared types are what the frame's kinds are built from, so reading them
    # here and reading `kindOf` there would answer the same question twice.
    gDamageAmountArg = -1
    var q = 0
    while q < params.len:
      if params[q] == "System.Single" or params[q] == "System.Double":
        gDamageAmountArg = q
        break
      inc q
    info "sain: damage postfix -- attempting a detour on " & name
    if typedPatchesReady() and
       hookReturnTyped(name, onPlayerDamagedTyped) == Ok:
      setDamageHooked(true)
      gDamageTyped = true
      gDamageHookState = "armed on the typed path on " & name & " " &
                         describeSig(params, ret) &
                         ", telling suppression each hit as it lands"
      info "sain: damage hooked on " & name & " (typed frame)"
      return
    if hookReturn(name, onPlayerDamaged, withArgs = true) == Ok:
      setDamageHooked(true)
      gDamageHookState = "armed on the JSON path on " & name & " " &
                         describeSig(params, ret) & " (this host is ABI " &
                         "revision " & $hostApiSize() & " bytes of HostApi, " &
                         "and the typed frame wants revision 4), at about " &
                         "1.6 us a hit rather than 37 ns"
      info "sain: damage hooked on " & name & " (JSON payload)"
      return
    gDamageHookState = "refused: " & lastError()
  if tried == 0:
    gDamageHookState = "refused: none of the " & $DamageHookCandidates.len &
                       " candidate damage members exists on this build; " &
                       "suppression keeps inferring hits from the health " &
                       "delta between two decisions, which is up to four " &
                       "ticks late and nets two hits against a regeneration"

proc reportHookCost(label, state: string; ns: int64; samples: int) =
  ## The measured price of one firing, beside the path that produced it.
  ##
  ## Both halves, always. `docs/PERF.md` puts a typed postfix at ~25 ns and a
  ## JSON one at 443-1615, and a log that says only "armed" cannot be used to
  ## tell which of those a raid actually paid.
  info "sain: " & label & " -- " & state
  if ns >= 0'i64:
    info "sain:   measured " & $ns & " ns per firing over " & $samples &
         " of them, on this client's own clock -- docs/PERF.md's numbers are " &
         "from a stand-in runtime and are not this"
  elif state.len >= 5 and state.substr(0, 4) == "armed":
    info "sain:   nothing measured: the method never fired on this build, so " &
         "there was nothing to time"

proc installHooks() =
  ## Being told beats asking. A detour on activation costs nothing between
  ## spawns; polling the world for new bots costs the same every frame forever
  ## -- which is why the scan in `driver.nim` runs at 2 Hz and is a reconciler
  ## rather than the primary path.
  ##
  ## The same argument now applies to death, and it applies harder: the death
  ## poll was not 2 Hz, it was two bound calls per bot per decision, for a fact
  ## that changes exactly once in a bot's life.
  if gHooked:
    return
  gHooked = true

  # BOTH DETOURS ARE REFUSED ON THIS BUILD, and the reason is measured rather
  # than cautious. MEASURED: `installHooks -- attempting the bot-activation
  # detour on EFT.BotsController::AddActivePLayer` was the last line this mod
  # ever logged before the client died at 9.250s. Patching BY NAME makes the
  # host resolve the name through the IL2CPP C API, which on this build hands
  # back a non-nil pointer into unmapped memory (fact #35) -- and the host then
  # patches THERE. A patch is a use, and on this build every by-name route is
  # fatal the moment it is used.
  #
  # The RVAs are measured and are in the two `const` arrays above, prologue
  # bytes and all, ready for the host's patch-by-RVA grammar. They are NOT
  # installed, and there are two independent reasons -- either alone is enough:
  #
  # 1. THE HOST REFUSES THE JSON PATCH ABI FOR AN RVA SPEC, by design.
  #    `aowlhost.nim` (~4040): "An RVA patch has NO MethodInfo, and every JSON
  #    firing path needs one ... So the JSON ABI is refused here rather than
  #    installed and quietly handing a handler an empty payload." Both hooks
  #    below use `hookArgs`, which IS the JSON ABI. The typed ABI --
  #    `hookTyped` / `hookReturnTyped` -- does accept an RVA spec, so this is a
  #    handler rewrite, not a missing host facility.
  #
  # 2. THE HANDLERS COULD NOT DO THEIR JOB EVEN THEN. `onBotAdded` reads the
  #    bot's identity with `who.get("ProfileId")` and `r.invoke("ToString")` --
  #    boxed by-name member access, the same dead path. A typed RVA detour
  #    would install, fire, and register every bot with an EMPTY id. That is a
  #    live code patch bought for nothing, which is worse than no patch.
  #
  # WHAT UNBLOCKS IT, measured here so the next pass does not re-derive it:
  # a bot's profile id is reachable with no reflection at all, in two hops of
  # measured static field offsets --
  #
  #     EFT.Player.<Profile>k__BackingField   inst @0x9c0  -> EFT.Profile
  #     EFT.Profile.Id                        inst @0x10   -> System.String
  #     System.String._stringLength @0x10, _firstChar @0x14
  #
  # (the last pair being `il2cpp_resolve.py`'s own self-check, so it is the
  # most-verified offset in the codebase). With those, `onBotAdded` becomes a
  # typed prefix that reads `f.argPointer(0)` and walks three offsets, and both
  # detours can go live by RVA. That is the next step, and it is a real one --
  # not a workaround.
  warn "sain: BOTH detours are refused on this build. The RVAs are measured " &
       "and byte-verified in the source (AddActivePLayer 0x254ce30, OnDead " &
       "0x732c30, neither shared), but patching by NAME is what killed the " &
       "client here and the host refuses the JSON patch ABI behind an RVA " &
       "spec -- so these need typed handlers, and the identity read inside " &
       "onBotAdded needs the measured field walk noted in the source " &
       "(Player.Profile@0x9c0 -> Profile.Id@0x10). Bot discovery falls back " &
       "to the 2 Hz world scan, which cannot read a spawn type; death falls " &
       "back to the per-bot health poll"
  # --- THE AIM POSTFIX IS ARMED HERE, ABOVE THE BLANKET REFUSAL, AND ON
  # PURPOSE.
  #
  # The refusal above is real and is unchanged: it covers the SPAWN and DEATH
  # detours, which use `hookArgs` (the JSON patch ABI) on a NAME, and both
  # halves of that are fatal or refused on this build. Neither half applies to
  # the aim postfix any more. `armAimHook` now installs through
  # `hookReturnTyped` with an `@0x` spec -- the typed ABI, which the host
  # accepts for an RVA, at an address that needs no class lookup -- so it
  # touches neither the by-name path nor the JSON path.
  #
  # THIS LINE IS THE WHOLE FIX FOR A SENSOR THAT WAS DEAD THREE TIMES OVER.
  # `armAimHook` used to be called BELOW the `return` a few lines down, so it
  # never ran at all; before that it would have been refused by
  # `reflectionRefused()`; and before THAT its three name candidates were a
  # type that does not exist, a type nothing ever returns, and a name that
  # does not exist. Each layer hid the one under it, and `gAimHookState` said
  # "refused: not attempted" while the driver's `gAimGated` sat at 0 --
  # indistinguishable from a working sensor with nothing to withhold. The
  # driver now reports FIRED / MATCHED / WITHHELD separately so those cannot
  # be confused again.
  #
  # It still refuses itself unless `sainRvaTable` is on AND
  # `sainRvaTableDriveLevel` is at least 2, and it still says which.
  info "sain: installHooks -- arming the aim postfix (the by-RVA route needs " &
       "neither by-name resolution nor the JSON patch ABI, so the blanket " &
       "refusal below does not cover it)"
  armAimHook()
  reportHookCost("bot aim result", gAimHookState, aimHookCostNs(),
                 gAimHookSamples)
  gDamageHookState = "refused: not attempted -- installHooks declines the " &
                     "JSON-ABI detours on this build, and the damage postfix " &
                     "has not been converted to an @0x spec the way the aim " &
                     "postfix has. Suppression keeps inferring hits from the " &
                     "health delta between two decisions"
  if true:
    return

  var i = 0
  var spawnOk = false
  while i < SpawnHookCandidates.len:
    let name = SpawnHookCandidates[i]
    # Before, not after. `hookArgs` WRITES a detour into game code; if the
    # process does not survive the write, the only line that can name which
    # candidate did it is one printed first.
    info "sain: installHooks -- attempting the bot-activation detour on " & name
    if hookArgs(name, onBotAdded) == Ok:
      info "sain: bot activation hooked on " & name
      spawnOk = true
      break
    inc i
  if not spawnOk:
    # Not fatal, and worth naming: some methods cannot be detoured (a prologue
    # holding a relative branch, or one shorter than the jump), and a method
    # that does not exist under any of these names cannot be either. Without
    # the hook the mod still finds every bot -- the world scan is what makes
    # that true -- but it finds them up to half a second late and without their
    # spawn type, which means scav settings for a PMC.
    warn "sain: no bot-activation hook took (last error: " & lastError() &
         "); falling back to the world scan, which cannot read a spawn type"

  if not livePointersReady():
    # Revision 2 or a host with no managed heap. The death hook would fire and
    # `thisPointer` would answer zero every time, which is a hook that costs a
    # payload per death and identifies nobody -- strictly worse than the poll.
    # So it is not installed, and the poll stays.
    warn "sain: this host cannot turn a hook's instance into an address " &
         "(it is older than ABI revision 3, or has no managed heap); death " &
         "stays on the per-bot poll, which costs two bound calls per bot " &
         "per decision"
    return

  var j = 0
  var deathOk = false
  while j < DeathHookCandidates.len:
    let name = DeathHookCandidates[j]
    info "sain: installHooks -- attempting the death detour on " & name
    if hookArgs(name, onPlayerDead) == Ok:
      info "sain: death hooked on " & name &
           "; the per-bot health poll is off"
      setDeathHooked(true)
      deathOk = true
      break
    inc j
  if not deathOk:
    warn "sain: no death hook took (last error: " & lastError() &
         "); keeping the per-bot health poll, which cannot be wrong about a " &
         "death but costs two bound calls per bot per decision"

  # The two postfixes. Both were declined outright while a postfix meant a
  # JSON payload -- see `README.md` section 5 -- and both are here now because
  # the typed frame made the objection a number rather than a principle. They
  # are armed in the order `README.md` names them.
  info "sain: installHooks -- arming the aim postfix"
  armAimHook()
  info "sain: installHooks -- arming the damage postfix"
  armDamageHook()
  info "sain: installHooks -- both postfixes returned"

  reportHookCost("bot aim result", gAimHookState, aimHookCostNs(),
                 gAimHookSamples)
  reportHookCost("damage", gDamageHookState, damageHookCostNs(),
                 gDamageHookSamples)

const
  BenchIterations = 20000
    ## Enough that the clock's own resolution is far below the answer, and
    ## small enough that the self-test stays instant.
  SamplerIterations = 20000
    ## Same order as `BenchIterations`, for the same reason: the clock's
    ## resolution has to be far below the answer.
  SamplesPerSecond = 10
    ## The rate `client/driver.nim` enforces, restated here because every
    ## per-frame figure printed below is this number and the measured cost of
    ## one sample, and a reader should be able to check the arithmetic without
    ## opening another file.
  BudgetNsPerSample = 20000
    ## The regression gate for the *pure* half of the cover sensor.
    ##
    ## About five times the measured cost, which is a tighter ratio than the
    ## decision gate's forty, and deliberately: this is a bounded loop of
    ## floating-point arithmetic with no dispatch and no data-dependent
    ## branching in it, so it varies far less between machines than a cascade
    ## of comparisons does. Five times still catches what a gate is for -- an
    ## allocation in the ingest, a scan that grew a factor of ten, a square
    ## root put back on a path that had one removed.
    ##
    ## Most of what it *does* cost is square roots. One sample takes about
    ## thirty, sixteen of them building the rays and the rest measuring
    ## distances, and `core/vec.sqrt0` is a Newton loop rather than a hardware
    ## instruction. That was six microseconds before the seeding fix recorded
    ## in `vec.nim`; the same fix is why the decision cost moved too.
  BudgetNsPerDecision = 1500
    ## The regression gate.
    ##
    ## Deliberately loose -- about **forty** times the measured cost, 1500 ns
    ## against the 35 ns/bot/decision the cost report prints on this machine --
    ## because this runs on whatever machine someone happens to build on, and a
    ## gate tight enough to be a benchmark is a gate that fails for reasons
    ## that are not the code. This said "around twenty times" while the
    ## decision cost was 37-39 ns and the budget was already 1500, so it was
    ## never right; the seeding fix in `vec.nim` that took the cost to 35 only
    ## widened it further. What it catches is the failure that matters: a decision
    ## path that starts allocating, or hits the game, or grows a loop over
    ## every bot. Those are factor-of-ten regressions, not five-percent ones.
    ## The *number* is printed every run regardless, which is what makes a
    ## five-percent regression visible to a person reading two logs.

proc runCostReport(s: Settings): int =
  ## What a decision costs, measured rather than claimed.
  ##
  ## `docs/PERF.md` asks for exactly this discipline about the fast path and it
  ## applies at least as much to the decision core: this mod exists because bot
  ## AI was the expensive part, and a mod that replaces it without saying what
  ## its own replacement costs has not answered the question it was written
  ## for.
  ##
  ## The clock is `fast.perfCounter`, the same one the bindings report their
  ## own cost on, because `nowMs()` has three orders of magnitude too little
  ## resolution for a sub-microsecond loop.
  let t0 = perfCounter()
  let sum = benchDecisions(BenchIterations)
  let ns = nanosBetween(t0, perfCounter())
  let per = ns div int64(BenchIterations)

  # What that means at the rates this mod actually runs at. The budget is
  # `maxBotsPerTick` decisions per frame regardless of how many bots are in the
  # raid -- that is the whole point of the round-robin in `driver.nim` -- so the
  # per-frame figure does not grow with the population and the second line says
  # what the population costs instead, which is latency.
  let perFrame = per * int64(s.maxBotsPerTick)
  let fullRaid = per * 30'i64
  info "sain: decision cost " & $per & " ns/bot/decision (" &
       $BenchIterations & " decisions in " & $(ns div 1000'i64) & " us)"
  info "sain:   " & $perFrame & " ns/frame at the budget of " &
       $s.maxBotsPerTick & " bots/tick -- constant in the raid's population"
  info "sain:   " & $fullRaid & " ns to reconsider all 30 bots of a full " &
       "raid, spread over " & $((30 + s.maxBotsPerTick - 1) div
                                s.maxBotsPerTick) & " frames"
  if sum == 0:
    # Impossible for a real run, and the one thing that would make the number
    # meaningless: an optimiser that deleted the loop.
    error "sain: the decision benchmark computed nothing; the number above " &
          "is not a measurement"
    return 1
  if per > int64(BudgetNsPerDecision):
    error "sain: a decision costs " & $per & " ns, over the " &
          $BudgetNsPerDecision & " ns budget -- something on the decision " &
          "path is allocating, calling the game, or scanning every bot"
    return 1

  # --- the cover sampler, measured separately, because it is a different
  # shape of cost and reporting it inside the decision figure would be the
  # flattering answer rather than the true one.
  #
  # What is timed here is the half that runs on *this* thread: planning eight
  # candidates and folding eight answers back into a bot's set. The raycasts
  # are the other half, they run on Unity's thread, and there is no honest way
  # to time one against a runtime that has no `UnityEngine.Physics` -- so this
  # says what it measured and `client/coverprobe.nim` measures the rest on the
  # game's own clock, in a raid, or reports that it never fired.
  let st0 = perfCounter()
  let ssum = benchSampler(SamplerIterations)
  let sns = nanosBetween(st0, perfCounter())
  let sper = sns div int64(SamplerIterations)
  # Every figure below is `sper` and the enforced rate, and the two are
  # printed separately because they answer different questions: the spike is
  # what a frame pays when a sample lands, and the average is what the raid
  # pays. A mod that reported only the average would be hiding the spike, and
  # a spike is what a player feels.
  let framesBetween = 60 div SamplesPerSecond
  info "sain: cover sample (plan + ingest) " & $sper & " ns, pure, on the " &
       "host's thread (" & $SamplerIterations & " samples in " &
       $(sns div 1000'i64) & " us)"
  info "sain:   " & $SamplesPerSecond & " samples/s for the whole raid, so " &
       "one frame in " & $framesBetween & " at 60 fps pays " & $sper &
       " ns and the rest pay nothing -- " &
       $(sper div int64(framesBetween)) & " ns/frame averaged"
  info "sain:   that is " & $((sper * 1000'i64) div 16667'i64) &
       " parts in a million of a 16.67 ms frame on the frame it lands, and " &
       "the same at forty bots as at eight: the rate is fixed and the " &
       "population buys refresh latency instead -- a bot's set is re-sampled " &
       "every " & $(40 div SamplesPerSecond) & " s in a forty-bot raid where " &
       "every bot wants cover at once"
  info "sain:   the raycasts are the other half and are not in that number: " &
       "at most " & $RaysPerSample & " rays and " & $ProbeCandidates &
       " navmesh queries a sample, so at most " &
       $(SamplesPerSecond * (RaysPerSample + ProbeCandidates)) &
       " engine calls a second however many bots are in the raid. Nothing " &
       "here has ever timed one: this runtime has no UnityEngine.Physics"
  if ssum == 0:
    error "sain: the cover sampler benchmark computed nothing; the number " &
          "above is not a measurement"
    return 1
  if sper > int64(BudgetNsPerSample):
    error "sain: a cover sample costs " & $sper & " ns, over the " &
          $BudgetNsPerSample & " ns budget -- something in plan or ingest " &
          "is allocating or scanning without a bound"
    return 1
  result = 0

proc runBindingSelfTest(): int =
  ## The client half, against a stand-in runtime.
  ##
  ## `core/` can be proved on a laptop; `client/live.nim` cannot, because its
  ## whole content is names from a build nobody here has seen. What *can* be
  ## proved offline is the thing that actually matters about it: that a name
  ## which is wrong produces a **refusal carrying a reason**, on no path, with
  ## no crash -- rather than a silent zero that the decision core would then
  ## treat as data.
  ##
  ## `tests/mockil2cpp` is a runtime implementing the same C API over a small
  ## type universe that has almost none of EFT's members. That makes it the
  ## ideal adversary here: nearly every binding in the table *should* refuse
  ## against it, and the assertion is that they all refuse the same honest way.
  ## Set `selfTestRuntime` in `config.json` to its `GameAssembly.dll`.
  var configured = ""
  discard configGet("selfTestRuntime", configured)
  let wanted = selfTestRuntime(configured)
  if wanted.refusal.len > 0:
    warn "sain: " & wanted.refusal
  let runtimePath = wanted.path

  var bad = 0

  # The Win64 hidden-pointer rule, exhaustively, with no runtime involved at
  # all. This is the predicate that decides whether the shaped path is taken
  # for a `Vector3`, and it is the sharpest assertion in the mod; both of its
  # branches are shown to work here rather than only on a machine with Tarkov.
  var sz = 1
  while sz <= 24:
    let want = (sz != 1 and sz != 2 and sz != 4 and sz != 8 and sz <= 16)
    if shapedSizeAccepted(sz) != want:
      error "sain: the shaped-call size rule is wrong about " & $sz & " bytes"
      inc bad
    inc sz
  if shapedSizeAccepted(0) or shapedSizeAccepted(-4):
    error "sain: the shaped-call size rule accepted a nonsensical size"
    inc bad
  if bad == 0:
    success "sain: the Win64 hidden-pointer rule accepts 3, 5, 6, 7 and " &
            "9..16 bytes and refuses 1, 2, 4, 8 and past 16 -- so a Vector3 " &
            "takes the shaped path and a float does not"

  var opened = false
  if runtimePath.len > 0:
    opened = openLiveAt(runtimePath, "aowl-sain-selftest")
    if not opened:
      warn "sain: selfTestRuntime " & runtimePath & " could not be loaded"
  if not opened:
    opened = openLive()
  if not opened:
    info "sain: no IL2CPP runtime in this process -- aowlspt-sim is a " &
         "managed host and GameAssembly.dll is not loaded, so every binding " &
         "would refuse for that reason, which is the correct answer here. " &
         "Set AOWLSPT_SELFTEST_RUNTIME, or \"selfTestRuntime\" in " &
         "config.json, to an ABSOLUTE path to a GameAssembly.dll " &
         "(tests/mockil2cpp builds one) for a real binding report offline."
    return bad

  bindAll()
  # Touch the world entry points so the lazy members downstream of them are
  # actually attempted rather than counted as never-used.
  let world = worldObject()
  if world == nil:
    warn "sain: the stand-in runtime has no GameWorld instance; only the " &
         "refusal path is being exercised"
  else:
    discard alivePlayers(world)
    discard grenadeList(world)

    # --- the positive half.
    #
    # The stand-in has no `AllAlivePlayersList`, so the walk this mod uses in a
    # raid stops at the world. What it does have is a `Player` reachable by
    # another name, and reaching it is enough to put the two paths that matter
    # through a live object: a plain bound call, and the *shaped* one.
    #
    # The shaped call is the point. `tryShaped` asserts a Win64 calling
    # convention through `fast.bindRaw`, and a wrong slot count there does not
    # crash -- it reads an uninitialised register and hands the game a
    # plausible number. Until the stand-in grew a `Vector3`, nothing exercised
    # it anywhere but in a raid. Now the mod reads a position it can check
    # against a value it knows.
    var mainPlayer = lazy("get_MainPlayer")
    let p1 = callObj(mainPlayer, world)
    if p1 == nil:
      warn "sain: no player object on the stand-in runtime; the shaped-call " &
           "path was not exercised"
    else:
      if isAI(p1):
        success "sain: a bound bool call against a live object answered"
      else:
        error "sain: a bound bool call against a live object gave the wrong " &
              "answer"
        inc bad
      # --- what the death poll cost, measured rather than quoted.
      #
      # `runCostReport` measures the *decision*, which never touched the game
      # and therefore does not move when a game read is removed -- saying so is
      # more useful than implying otherwise. What the death hook removed is two
      # bound calls per bot per decision: `get_HealthController` and
      # `get_IsAlive`. `get_IsAI` on the stand-in is exactly the second of those
      # shapes -- an instance method, no arguments, returning a bool -- so
      # timing it here measures the thing that was removed, on this machine, on
      # the same runtime, in the same run that prints the decision cost.
      const PollIterations = 200000
      let pt0 = perfCounter()
      var hits = 0
      var k = 0
      while k < PollIterations:
        if isAI(p1): inc hits
        inc k
      let pollNs = nanosBetween(pt0, perfCounter())
      let perCall = pollNs div int64(PollIterations)
      if hits != PollIterations:
        error "sain: the bound bool call answered false " &
              $(PollIterations - hits) & " times in " & $PollIterations &
              " -- the return register is not carrying a bool, so the " &
              "number above is timing the wrong thing"
        inc bad
      else:
        info "sain: a bound bool call costs " & $perCall & " ns here; the " &
             "death poll was two of them per bot per decision, so hooking " &
             "death removes about " & $(perCall * 2'i64) & " ns/bot and " &
             $(perCall * 2'i64 * int64(gPreset.base.maxBotsPerTick)) &
             " ns/frame at the budget of " & $gPreset.base.maxBotsPerTick &
             " bots/tick"

      let pos = readVec(gB.pPosition, p1)
      # The stand-in's own position, which it exports a setter for. Any three
      # distinct non-zero numbers would do; what is being checked is that all
      # three arrived, in order, through a call whose shape this mod asserted.
      if pos.x > 12.4 and pos.x < 12.6 and pos.y > 3.2 and pos.y < 3.3 and
         pos.z < -4.7 and pos.z > -4.8:
        success "sain: a Vector3 came back through the shaped call intact (" &
                $pos.x & ", " & $pos.y & ", " & $pos.z & ")"
      else:
        error "sain: the Vector3 read came back as (" & $pos.x & ", " &
              $pos.y & ", " & $pos.z & ") -- the asserted slot shape is wrong"
        inc bad

      # --- the declared-signature gate, wired, against a live class.
      #
      # `core/selftest.nim` proves the *rule* over synthetic signatures. This
      # proves that `live.resolveOn` actually consults it, which is a separate
      # claim and the one that fails silently: a gate nobody calls refuses
      # nothing and every "does it refuse?" test still passes.
      #
      # **Pointing it at `GoToPoint` would prove nothing**, because the
      # stand-in has no such member and the binding would refuse for want of
      # the name. That is this project's most common bug species and it is
      # avoided here by pointing the gate at members the stand-in *does*
      # carry, in both directions, one per shape. Two of them are the exact
      # traps the gate was written for: `Scale(System.Single)` gated as
      # `Sprint(bool)` is a float where a bool goes, and `Damage(System.Single)`
      # gated as `GoToPoint(Vector3)` is the arity match with the wrong first
      # parameter that `il2cpp_class_get_method_from_name` hands back.
      var gPass = withGate(lazy("get_IsAI"), dsNoArgs)
      if (not ensure(gPass, p1)) or gPass.gateRefused:
        error "sain: the gate refused a no-argument method that declares no " &
              "arguments -- " & gPass.why
        inc bad
      var gBoolPass = withGate(lazyAs("SetFlag", [fkBool], fkBool), dsOneBool)
      if (not ensure(gBoolPass, p1)) or gBoolPass.gateRefused:
        error "sain: the gate refused SetFlag(System.Boolean), which is " &
              "exactly the shape Mover.Sprint is called with -- " & gBoolPass.why
        inc bad
      if bad == 0:
        success "sain: the signature gate passes the two shapes that match " &
                "-- a no-argument void and a one-bool setter, resolved " &
                "against a live class"

      # The three refusals, each named with the signature the runtime reported.
      var gVecBad = withGate(lazy("Damage", 1'i32), dsVectorFirst)
      if ensure(gVecBad, p1) or not gVecBad.gateRefused or
         gVecBad.why.len == 0:
        error "sain: a gated GoToPoint-shaped call resolved onto " &
              "Damage(System.Single). The arity matched and the first " &
              "parameter is not a Vector3, so the gate is not wired into " &
              "resolveOn -- which is the whole failure it exists to prevent"
        inc bad
      else:
        success "sain: " & gVecBad.why
      var gBoolBad = withGate(lazyAs("Scale", [fkBool], fkBool), dsOneBool)
      if ensure(gBoolBad, p1) or not gBoolBad.gateRefused or
         gBoolBad.why.len == 0:
        error "sain: a gated Sprint-shaped call resolved onto " &
              "Scale(System.Single). The stated kinds said bool and the " &
              "runtime says float, and nothing caught it -- which is the " &
              "state Mover.Sprint was in before this gate existed"
        inc bad
      else:
        success "sain: " & gBoolBad.why
      var gArgBad = withGate(lazy("Scale", 1'i32), dsNoArgs)
      if ensure(gArgBad, p1) or not gArgBad.gateRefused or
         gArgBad.why.len == 0:
        error "sain: a gated no-argument call resolved onto a method that " &
              "declares one, and callVoidOn would have passed it nothing"
        inc bad
      else:
        success "sain: " & gArgBad.why
  report()

  # --- the cover sensor, against a runtime that has none of it.
  #
  # This is the only thing about `client/coverprobe.nim` that can be proved
  # offline, and it is the thing worth proving: that two Unity names which do
  # not exist here refuse **by name, carrying a reason, on no path**, rather
  # than half-binding and then calling something with the right arity. The
  # stand-in has no `UnityEngine.Physics` and no `UnityEngine.AI.NavMesh`, so
  # the expected answer is two refusals and no sample ever taken -- and a
  # positive result here would mean the check was not testing anything.
  bindProbe()
  info "sain: " & probeState()
  if raycastReady():
    error "sain: the stand-in runtime has no UnityEngine.Physics, so a " &
          "bound raycast here means the resolution accepted something it " &
          "should have refused"
    inc bad
  elif raycastWhy().len == 0 or samplesTaken() != 0:
    error "sain: the cover sensor refused without a reason, or took a " &
          "sample it could not have taken"
    inc bad
  else:
    success "sain: the cover sensor refuses by name with a reason, and takes " &
            "no sample -- which is every build so far, including this one"

  let t = tally()
  # Four numbers rather than three, because "missing" and "refused" are
  # different facts about the client and want different reactions. A missing
  # member means this build does not have that name; a refused one means it
  # has the name and the signature is not the one this mod calls it with,
  # which is the driving gate and is a thing to go and look at.
  info "sain: bindings -- " & $t.fast & " fast, " & $t.shaped & " shaped, " &
       $t.boxed & " boxed, " & $t.missing & " missing, " & $t.refused &
       " refused on signature"
  info "sain:   value-type header calibrated at " & $headerCalibration() &
       " bytes"
  if t.shaped == 0 and world != nil:
    warn "sain: no binding took the shaped path, so the Win64 assertion in " &
         "tryShaped was not exercised against this runtime"

  if t.silent > 0:
    error "sain: " & $t.silent & " binding(s) refused without saying why -- " &
          "a silent refusal is a mod that quietly does nothing"
    inc bad
  else:
    success "sain: every refused binding carries a reason"
  result = bad

proc runSelfTest(s: Settings): int =
  ## The decision core, exercised end to end. Runs on the simulator, and on any
  ## side when `logDecisions` is on -- a mod that can prove its own logic in the
  ## host it is loaded into is worth the microseconds.
  let r = selftest.run()
  for line in r.lines:
    info line
  if r.failed == 0:
    success "sain: decision core, " & $r.passed & " checks passed"
  else:
    error "sain: decision core, " & $r.failed & " of " &
          $(r.passed + r.failed) & " checks FAILED"
  # The ORBIT dispatcher's arithmetic, exercised at the same moment: the
  # square root it uses for every distance, and the personality draw. The draw
  # is checked for BOTH stability (one bot id must not change personality
  # between censuses) and spread (200 ids must not all draw the same one) --
  # the second is the negative, and it is the one a hash that ignored its input
  # would fail while looking perfectly deterministic.
  var dispatchFails: seq[string] = @[]
  if not selfCheckDispatch(dispatchFails):
    for line in dispatchFails:
      error "sain: " & line
  else:
    success "sain: flanking dispatcher arithmetic, " &
            "distance and personality draw both check out"
  # The RVA TABLE's own self-check, run here so a table edit fails a --fast
  # selftest rather than a raid. Everything it asserts is decidable without a
  # client and every assertion is a negative: a mutating row reachable below
  # level 3, a prologue too short to be sixteen bytes, a patch spec with no
  # prologue at all, or a spec shape that no longer matches the argument
  # indices sain.nim reads by hand.
  var rvaFails: seq[string] = @[]
  if not rvaSelfCheck(rvaFails):
    for line in rvaFails:
      error "sain: RVA TABLE SELF-CHECK FAILED -- " & line
  else:
    success "sain: RVA table self-check passed -- no mutating row is " &
            "reachable below level 3, every row carries a full 16-byte " &
            "prologue, both patch-by-RVA specs carry one to compare, and " &
            "DamageShooterSpec's declared shape still matches the argument " &
            "indices the damage handler reads"
  result = r.failed + dispatchFails.len + rvaFails.len + runCostReport(s)

proc runDriveQueueSelfTest(): int =
  ## The order ring between the two threads, exercised on one.
  ##
  ## What can be proved here is the *mechanics* -- that an order posted is an
  ## order drained, that a full ring drops rather than overwrites, that an old
  ## order is discarded rather than executed, and that a handle which answers
  ## null is counted as a dead bot rather than followed. What cannot be proved
  ## here is that the calls at the end of it reach Unity, because there is no
  ## Unity; `driveStats()` says so in those words in a raid.
  ##
  ## **The assertions are on the counters, not on the calls**, and that is
  ## deliberate. With no runtime bound, every handle resolves to null and no
  ## driving call is made -- so "no calls were made" would pass whether or not
  ## the drain ran at all, which is this project's most common bug and not a
  ## test. What is asserted instead is that the drain *reached* every order and
  ## classified it: `driveGone` counts orders whose bot could not be resolved,
  ## and it can only be incremented by code that walked the ring.
  var bad = 0
  initDriveQueue()
  let before = driveGone()

  var h = BotHandle(id: "queue-test", role: brPmc, gcPlayer: 1'u32)
  var a = Actuation(sprint: true, moveTo: vec3(1.0, 2.0, 3.0),
                    hasMoveTarget: true, lookAt: vec3(4.0, 5.0, 6.0),
                    hasLookTarget: true, shoot: false, selfAct: saNone)

  # A handle of zero is not a bot. Posting one would put an order in the ring
  # that the drain can only throw away.
  var none = BotHandle(id: "unattached", role: brScav, gcPlayer: 0'u32)
  if postDrive(none, a, 1.0):
    error "sain: the drive queue accepted an order for an unattached bot"
    inc bad

  var posted = 0
  var i = 0
  while i < 40:
    # Forty into a ring of thirty-two: the last eight must be refused rather
    # than overwrite slots the drain has not reached.
    if postDrive(h, a, 1.0):
      posted = posted + 1
    inc i
  if posted != 32 or drivePending() != 32:
    error "sain: the drive ring took " & $posted & " of 40 orders and holds " &
          $drivePending() & "; it is sized at 32 and must drop the rest"
    inc bad
  if driveDropped() != 8:
    error "sain: the drive ring dropped " & $driveDropped() &
          " orders where 8 were refused -- a drop that is not counted is a " &
          "bot that silently stopped being driven"
    inc bad

  # The drain, at a time close enough to the post that nothing is stale. Every
  # handle answers null here, so every order must land in `driveGone` -- which
  # is the assertion that the loop reached all thirty-two of them.
  discard runDrives(1.05)
  if drivePending() != 0:
    error "sain: the drive drain left " & $drivePending() & " orders queued"
    inc bad
  if driveGone() - before != 32:
    error "sain: the drain classified " & $(driveGone() - before) &
          " of 32 orders as belonging to a bot it could not resolve; the " &
          "rest were never walked"
    inc bad

  # Staleness. An order posted a second before it is drained is about where a
  # bot was a second ago, and executing it would steer bots to where their
  # enemies used to be.
  let staleBefore = driveStale()
  let goneBefore = driveGone()
  discard postDrive(h, a, 10.0)
  discard runDrives(11.0)
  if driveStale() - staleBefore != 1 or driveGone() - goneBefore != 0:
    error "sain: an order a second old was executed rather than dropped"
    inc bad

  if bad == 0:
    success "sain: the drive ring holds 32, drops the 33rd with a count, " &
            "walks every order it holds, and discards one older than 350 ms " &
            "-- the mechanics of crossing to Unity's thread, proved without " &
            "a Unity"
  # --- what the queue costs, on the side that can be measured.
  #
  # Two halves, and only one of them is measurable here. The *post* is pure --
  # a bounds check and a struct store into a fixed array -- and runs on the
  # decision thread, which is the one this mod budgets. The *drain* resolves a
  # GC handle per order and then makes the driving calls, and against a
  # stand-in with no bots every handle answers null, so what is timed below is
  # the ring's own cost with the calls taken out of it. Quoting that as the
  # cost of driving would be the flattering answer; it is quoted as what it is.
  const PostIterations = 20000
  initDriveQueue()
  let pt0 = perfCounter()
  var accepted = 0
  var k = 0
  while k < PostIterations:
    if postDrive(h, a, 1.0):
      accepted = accepted + 1
    else:
      # The ring fills after 32; draining it here keeps the loop measuring a
      # post rather than a refusal. The drain's own cost is excluded by
      # measuring it separately below.
      discard runDrives(1.0)
    inc k
  let postNs = nanosBetween(pt0, perfCounter())
  if accepted == 0:
    error "sain: the drive-post benchmark posted nothing; the number below " &
          "is not a measurement"
    inc bad
  else:
    info "sain: an actuation costs " & $(postNs div int64(PostIterations)) &
         " ns to queue on the decision thread, including the drains the " &
         "loop had to run to keep the ring from filling. It is paid only " &
         "when a decision changes, not per bot per tick"
  # And put the counters back, so the state line printed at the end of the
  # session describes the session rather than this benchmark.
  let drainNs = driveCostNs()
  initDriveQueue()
  info "sain:   the drain is the other half and is not in that number: " &
       $drainNs & " ns for a ring of up to 32 against a runtime where every " &
       "handle answers null, so the five driving calls at the end of it have " &
       "never been made and their cost is not measured"
  info "sain: " & driveStats()
  result = bad

proc sainSchema(): seq[Setting] =
  ## Every key this mod reads out of `config.json`, declared as a control.
  ##
  ## The `global`, `roles` and `server` blocks are nested documents, so their
  ## members are declared by DOTTED PATH -- `global.engageDistance`,
  ## `roles.scav.willSearchForEnemy`. That is what `locatePath` in the host's
  ## config merge already walks, both to read the current value back and to
  ## splice an edit in place. It only works for a path that EXISTS on disk: a
  ## missing one would be created as a flat top-level key with a dot in its
  ## name, which `loadPreset` never looks at -- a control that appears to save
  ## and does nothing. `config.json` therefore now carries the full uniform set
  ## for all four roles, with the values each role was already inheriting from
  ## `global`, so behaviour is byte-for-byte what it was and every declared
  ## path resolves.
  ##
  ## THE BAR FOR `implemented = true`, and it is the whole point of this proc:
  ## a tester who changes the setting can SEE the game differ. Not parsed, not
  ## folded into a struct, not reaching a decision -- SEEN.
  ##
  ## Five rows clear that bar:
  ##
  ##   enabled      gates `startServer` (brains, modifiers, the drive) and the
  ##                client half entirely.
  ##   difficulty   `server/drive.nim` turns it into `BotMover.MoveSpeed` and
  ##                sends it to every bot over `aowlspt/botnav`, which resolves
  ##                no name at run time. Measured live: every bot in a raid took
  ##                the commanded speed.
  ##   logDecisions gates the per-census drive line naming that speed.
  ##   server.patchBrains, server.neutraliseLocationModifiers
  ##                both write the served database on server start.
  ##
  ## THIRTY-FOUR DO NOT, and every one says why in its own description. The
  ## reason is nearly always the same single fact, and it is worth stating once
  ## here in full rather than trusting a reader to infer it from a description:
  ##
  ##   `client/bridge.nim` deliberately stops arming at `capReadOnly`. Step 7
  ##   of its probe REFUSES, because everything past a list read needs
  ##   `il2cpp_object_get_class` on a receiver, and a by-name entry point on
  ##   this build returns a plausible RANDOM handle that kills the client on
  ##   the first dereference. `onUpdate` consequently returns before `scan`
  ##   and `tick` on every frame, so `client/driver.nim` NEVER TICKS and the
  ##   `core/decide.nim` cascade never reaches a live bot.
  ##
  ## So every knob whose only consumer is that cascade or that driver --
  ## the whole of `global` and the whole of `roles` -- is read, resolved into a
  ## `Settings`, and then not acted on. The cover knobs
  ## (`coverMinEnemyDistance`, `maxCoverPathLength`, `canShiftCoverPosition`)
  ## are inert twice over: the cover sensor is separately OFF, because sampling
  ## cover needs `UnityEngine.Physics::Raycast` resolved by name.
  ##
  ## Do not flip any of these to make the page look fuller. The page is meant
  ## to be honest about how much of this mod currently reaches the game; a
  ## control that lies is worse than an absent one. Each becomes true when the
  ## driver ticks against real bots and somebody watches a raid, not before.
  ##
  ## Two SECTIONS of this page are NOT declared here. `Bot AI > Population`
  ## and `Bot AI > Waypoints` are declared by the mods that own them and
  ## proxied in -- see `childGuids` below.
  ##
  ## The spawn-population rows (`Bot AI > Population`) are NOT declared here.
  ## They belong to the population half of this mod, a separately loaded binary
  ## (guid `aowl.morebots`, hidden from the player mod list) which owns the
  ## database write and the in-client bot count. It declares its rows with
  ## `inIndex = false`, so it claims no nav entry of its own, and THIS page
  ## proxies them: `mergedPage` asks it for its rows over `SettingsPageQuery`
  ## and appends them, and a write to a key this mod does not declare is
  ## forwarded over `SettingsApplyQuery` rather than persisted here. One
  ## visible mod, one page tree, exactly ONE owner per value -- a row that
  ## rendered here and also persisted here would be two sources of truth and
  ## would drift.
  result = @[
    boolSetting("enabled", "Enable Bot AI", true,
                category = "General",
                description = "From SAIN (Solarint, maintained by ArchangelWTF), rewritten from scratch for aowlspt. Master switch for the whole Bot AI mod (bot brains, spawn tuning and the raid drive). Off means the mod loads and does nothing.",
                implemented = true),
    enumSetting("difficulty", "Difficulty", "default",
                @["easy", "lessdifficult", "default", "harderpmcs",
                  "veryhard", "deathwish"],
                category = "General",
                description = "From SAIN (Solarint, maintained by ArchangelWTF), rewritten from scratch for aowlspt. Scales how fast every bot moves, from 0.49 at easy to 1.0 at deathwish. Measured live: every bot in a raid took the commanded speed. Needs `botNav` on in aowlspt-host.json.",
                implemented = true),
    stringSetting("forcePersonality", "Force personality", "",
                  category = "General",
                  description = "From SAIN (Solarint, maintained by ArchangelWTF), rewritten from scratch for aowlspt. Force every bot to one personality (rat, gigachad, chad, coward, ...). It does reach bots -- it picks the coverage roll and the sprint rule behind the goTo orders -- but nobody has yet watched two raids and confirmed the difference is visible, so it stays greyed until somebody has.",
                  implemented = false),
    floatSetting("global.engageDistance", "Engage distance (m)", 70.0,
                 lo = 5.0, hi = 300.0, step = 5.0,
                 category = "Global", subcategory = "Combat",
                 description = "From SAIN (Solarint, maintained by ArchangelWTF), rewritten from scratch for aowlspt. How far away a bot will still commit to a fight instead of holding or searching. READ into the preset and then into a decision the cascade computes, but on this build the decision cannot reach a bot: the client half stops arming at read-only by construction, so the driver never ticks. The cause is NOT il2cpp_object_get_class -- that export is intact and ungated (it is `mov rax,[rcx]; ret`). It is that every hop past the alive-players list goes through LazyCall's BY-NAME binding (il2cpp_class_from_name / il2cpp_class_get_method_from_name), which on this build are token-gated exports: called without the token they return a plausible RANDOM handle and the client dies on the first dereference. Changing this cannot change what you see in a raid.",
                 implemented = false),
    floatSetting("global.timeBeforeSearch", "Time before search (s)", 40.0,
                 lo = 1.0, hi = 180.0, step = 1.0,
                 category = "Global", subcategory = "Combat",
                 description = "From SAIN (Solarint, maintained by ArchangelWTF), rewritten from scratch for aowlspt. Seconds a bot waits after losing sight of an enemy before it goes looking. READ into the preset and then into a decision the cascade computes, but on this build the decision cannot reach a bot: the client half stops arming at read-only by construction, so the driver never ticks. The cause is NOT il2cpp_object_get_class -- that export is intact and ungated (it is `mov rax,[rcx]; ret`). It is that every hop past the alive-players list goes through LazyCall's BY-NAME binding (il2cpp_class_from_name / il2cpp_class_get_method_from_name), which on this build are token-gated exports: called without the token they return a plausible RANDOM handle and the client dies on the first dereference. Changing this cannot change what you see in a raid.",
                 implemented = false),
    floatSetting("global.holdGroundBaseTime", "Hold ground time (s)", 1.0,
                 lo = 0.0, hi = 15.0, step = 0.5,
                 category = "Global", subcategory = "Combat",
                 description = "From SAIN (Solarint, maintained by ArchangelWTF), rewritten from scratch for aowlspt. How long a bot stands its ground when first contacted, before choosing to push or fall back. READ into the preset and then into a decision the cascade computes, but on this build the decision cannot reach a bot: the client half stops arming at read-only by construction, so the driver never ticks. The cause is NOT il2cpp_object_get_class -- that export is intact and ungated (it is `mov rax,[rcx]; ret`). It is that every hop past the alive-players list goes through LazyCall's BY-NAME binding (il2cpp_class_from_name / il2cpp_class_get_method_from_name), which on this build are token-gated exports: called without the token they return a plausible RANDOM handle and the client dies on the first dereference. Changing this cannot change what you see in a raid.",
                 implemented = false),
    floatSetting("global.fightBackHealthThreshold", "Fight back above health", 0.55,
                 lo = 0.0, hi = 1.0, step = 0.05,
                 category = "Global", subcategory = "Combat",
                 description = "From SAIN (Solarint, maintained by ArchangelWTF), rewritten from scratch for aowlspt. Fraction of health above which a bot is willing to trade fire rather than break contact. READ into the preset and then into a decision the cascade computes, but on this build the decision cannot reach a bot: the client half stops arming at read-only by construction, so the driver never ticks. The cause is NOT il2cpp_object_get_class -- that export is intact and ungated (it is `mov rax,[rcx]; ret`). It is that every hop past the alive-players list goes through LazyCall's BY-NAME binding (il2cpp_class_from_name / il2cpp_class_get_method_from_name), which on this build are token-gated exports: called without the token they return a plausible RANDOM handle and the client dies on the first dereference. Changing this cannot change what you see in a raid.",
                 implemented = false),
    floatSetting("global.runAwayHealthThreshold", "Run away below health", 0.28,
                 lo = 0.0, hi = 1.0, step = 0.01,
                 category = "Global", subcategory = "Combat",
                 description = "From SAIN (Solarint, maintained by ArchangelWTF), rewritten from scratch for aowlspt. Fraction of health below which a bot disengages and runs. READ into the preset and then into a decision the cascade computes, but on this build the decision cannot reach a bot: the client half stops arming at read-only by construction, so the driver never ticks. The cause is NOT il2cpp_object_get_class -- that export is intact and ungated (it is `mov rax,[rcx]; ret`). It is that every hop past the alive-players list goes through LazyCall's BY-NAME binding (il2cpp_class_from_name / il2cpp_class_get_method_from_name), which on this build are token-gated exports: called without the token they return a plausible RANDOM handle and the client dies on the first dereference. Changing this cannot change what you see in a raid.",
                 implemented = false),
    floatSetting("global.coverMinEnemyDistance", "Cover: min enemy distance (m)", 8.0,
                 lo = 0.0, hi = 50.0, step = 1.0,
                 category = "Global", subcategory = "Cover",
                 description = "From SAIN (Solarint, maintained by ArchangelWTF), rewritten from scratch for aowlspt. A cover point closer to the enemy than this is rejected. Cover knob. Doubly inert: the cover sensor itself is OFF -- sampling cover needs UnityEngine.Physics::Raycast resolved BY NAME, which is fatal on this build -- so this feeds a cover decision that is never taken, in a driver that never ticks.",
                 implemented = false),
    floatSetting("global.maxCoverPathLength", "Cover: max path length (m)", 60.0,
                 lo = 5.0, hi = 200.0, step = 5.0,
                 category = "Global", subcategory = "Cover",
                 description = "From SAIN (Solarint, maintained by ArchangelWTF), rewritten from scratch for aowlspt. How far a bot will walk to reach cover before giving up on the point. Cover knob. Doubly inert: the cover sensor itself is OFF -- sampling cover needs UnityEngine.Physics::Raycast resolved BY NAME, which is fatal on this build -- so this feeds a cover decision that is never taken, in a driver that never ticks.",
                 implemented = false),
    floatSetting("global.decisionHz", "Decision rate (Hz)", 10.0,
                 lo = 1.0, hi = 30.0, step = 1.0,
                 category = "Global", subcategory = "Performance",
                 description = "From SAIN (Solarint, maintained by ArchangelWTF), rewritten from scratch for aowlspt. How often each bot re-decides. READ into the preset and then into a decision the cascade computes, but on this build the decision cannot reach a bot: the client half stops arming at read-only by construction, so the driver never ticks. The cause is NOT il2cpp_object_get_class -- that export is intact and ungated (it is `mov rax,[rcx]; ret`). It is that every hop past the alive-players list goes through LazyCall's BY-NAME binding (il2cpp_class_from_name / il2cpp_class_get_method_from_name), which on this build are token-gated exports: called without the token they return a plausible RANDOM handle and the client dies on the first dereference. Changing this cannot change what you see in a raid.",
                 implemented = false),
    intSetting("global.maxBotsPerTick", "Bots considered per tick", 8,
               lo = 1, hi = 64, step = 1,
               category = "Global", subcategory = "Performance",
               description = "From SAIN (Solarint, maintained by ArchangelWTF), rewritten from scratch for aowlspt. The per-frame budget: how many bots the driver thinks about each tick, round-robin. READ into the preset and then into a decision the cascade computes, but on this build the decision cannot reach a bot: the client half stops arming at read-only by construction, so the driver never ticks. The cause is NOT il2cpp_object_get_class -- that export is intact and ungated (it is `mov rax,[rcx]; ret`). It is that every hop past the alive-players list goes through LazyCall's BY-NAME binding (il2cpp_class_from_name / il2cpp_class_get_method_from_name), which on this build are token-gated exports: called without the token they return a plausible RANDOM handle and the client dies on the first dereference. Changing this cannot change what you see in a raid.",
               implemented = false),
    floatSetting("global.farFromPlayerDistance", "Far-from-player distance (m)", 150.0,
                 lo = 10.0, hi = 600.0, step = 10.0,
                 category = "Global", subcategory = "Performance",
                 description = "From SAIN (Solarint, maintained by ArchangelWTF), rewritten from scratch for aowlspt. Beyond this distance from you a bot decides less often, to save frame time. READ into the preset and then into a decision the cascade computes, but on this build the decision cannot reach a bot: the client half stops arming at read-only by construction, so the driver never ticks. The cause is NOT il2cpp_object_get_class -- that export is intact and ungated (it is `mov rax,[rcx]; ret`). It is that every hop past the alive-players list goes through LazyCall's BY-NAME binding (il2cpp_class_from_name / il2cpp_class_get_method_from_name), which on this build are token-gated exports: called without the token they return a plausible RANDOM handle and the client dies on the first dereference. Changing this cannot change what you see in a raid.",
                 implemented = false),
    enumSetting("roles.pmc.difficulty", "PMC: difficulty", "inherit",
                @["inherit", "easy", "lessdifficult", "default",
                  "harderpmcs", "veryhard", "deathwish"],
                category = "Roles", subcategory = "PMC",
                description = "From SAIN (Solarint, maintained by ArchangelWTF), rewritten from scratch for aowlspt. Difficulty band for PMCs ONLY, overriding the global one. `inherit` leaves them on the global band. This reaches bots the same way the global Difficulty does -- the bot census carries each bot's WildSpawnType, so the mod can address a MoveSpeed at that bot by id over `aowlspt/botnav` -- with no new RVA and no by-name lookup. Set two roles to opposite ends and the difference is visible in one raid. Needs `botNav` on in aowlspt-host.json.",
                implemented = true),
    floatSetting("roles.pmc.engageDistance", "PMC: engage distance (m)", 90.0,
                 lo = 5.0, hi = 300.0, step = 5.0,
                 category = "Roles", subcategory = "PMC",
                 description = "From SAIN (Solarint, maintained by ArchangelWTF), rewritten from scratch for aowlspt. Overrides the global engage distance for pmc bots only. READ into the preset and then into a decision the cascade computes, but on this build the decision cannot reach a bot: the client half stops arming at read-only by construction, so the driver never ticks. The cause is NOT il2cpp_object_get_class -- that export is intact and ungated (it is `mov rax,[rcx]; ret`). It is that every hop past the alive-players list goes through LazyCall's BY-NAME binding (il2cpp_class_from_name / il2cpp_class_get_method_from_name), which on this build are token-gated exports: called without the token they return a plausible RANDOM handle and the client dies on the first dereference. Changing this cannot change what you see in a raid.",
                 implemented = false),
    floatSetting("roles.pmc.timeBeforeSearch", "PMC: time before search (s)", 25.0,
                 lo = 1.0, hi = 180.0, step = 1.0,
                 category = "Roles", subcategory = "PMC",
                 description = "From SAIN (Solarint, maintained by ArchangelWTF), rewritten from scratch for aowlspt. Overrides the global search delay for pmc bots only. READ into the preset and then into a decision the cascade computes, but on this build the decision cannot reach a bot: the client half stops arming at read-only by construction, so the driver never ticks. The cause is NOT il2cpp_object_get_class -- that export is intact and ungated (it is `mov rax,[rcx]; ret`). It is that every hop past the alive-players list goes through LazyCall's BY-NAME binding (il2cpp_class_from_name / il2cpp_class_get_method_from_name), which on this build are token-gated exports: called without the token they return a plausible RANDOM handle and the client dies on the first dereference. Changing this cannot change what you see in a raid.",
                 implemented = false),
    boolSetting("roles.pmc.willSearchForEnemy", "PMC: will search for enemy", true,
                category = "Roles", subcategory = "PMC",
                description = "From SAIN (Solarint, maintained by ArchangelWTF), rewritten from scratch for aowlspt. Whether pmc bots hunt a lost enemy at all, or hold where they are. READ into the preset and then into a decision the cascade computes, but on this build the decision cannot reach a bot: the client half stops arming at read-only by construction, so the driver never ticks. The cause is NOT il2cpp_object_get_class -- that export is intact and ungated (it is `mov rax,[rcx]; ret`). It is that every hop past the alive-players list goes through LazyCall's BY-NAME binding (il2cpp_class_from_name / il2cpp_class_get_method_from_name), which on this build are token-gated exports: called without the token they return a plausible RANDOM handle and the client dies on the first dereference. Changing this cannot change what you see in a raid.",
                implemented = false),
    floatSetting("roles.pmc.runAwayHealthThreshold", "PMC: run away below health", 0.28,
                 lo = 0.0, hi = 1.0, step = 0.01,
                 category = "Roles", subcategory = "PMC",
                 description = "From SAIN (Solarint, maintained by ArchangelWTF), rewritten from scratch for aowlspt. Overrides the global flee threshold for pmc bots only. READ into the preset and then into a decision the cascade computes, but on this build the decision cannot reach a bot: the client half stops arming at read-only by construction, so the driver never ticks. The cause is NOT il2cpp_object_get_class -- that export is intact and ungated (it is `mov rax,[rcx]; ret`). It is that every hop past the alive-players list goes through LazyCall's BY-NAME binding (il2cpp_class_from_name / il2cpp_class_get_method_from_name), which on this build are token-gated exports: called without the token they return a plausible RANDOM handle and the client dies on the first dereference. Changing this cannot change what you see in a raid.",
                 implemented = false),
    boolSetting("roles.pmc.canShiftCoverPosition", "PMC: may shift cover", true,
                category = "Roles", subcategory = "PMC",
                description = "From SAIN (Solarint, maintained by ArchangelWTF), rewritten from scratch for aowlspt. Whether pmc bots reposition between cover points under fire. Cover knob. Doubly inert: the cover sensor itself is OFF -- sampling cover needs UnityEngine.Physics::Raycast resolved BY NAME, which is fatal on this build -- so this feeds a cover decision that is never taken, in a driver that never ticks.",
                implemented = false),
    enumSetting("roles.scav.difficulty", "Scav: difficulty", "inherit",
                @["inherit", "easy", "lessdifficult", "default",
                  "harderpmcs", "veryhard", "deathwish"],
                category = "Roles", subcategory = "Scav",
                description = "From SAIN (Solarint, maintained by ArchangelWTF), rewritten from scratch for aowlspt. Difficulty band for scavs ONLY, overriding the global one. `inherit` leaves them on the global band. This reaches bots the same way the global Difficulty does -- the bot census carries each bot's WildSpawnType, so the mod can address a MoveSpeed at that bot by id over `aowlspt/botnav` -- with no new RVA and no by-name lookup. Set two roles to opposite ends and the difference is visible in one raid. Needs `botNav` on in aowlspt-host.json.",
                implemented = true),
    floatSetting("roles.scav.engageDistance", "Scav: engage distance (m)", 50.0,
                 lo = 5.0, hi = 300.0, step = 5.0,
                 category = "Roles", subcategory = "Scav",
                 description = "From SAIN (Solarint, maintained by ArchangelWTF), rewritten from scratch for aowlspt. Overrides the global engage distance for scav bots only. READ into the preset and then into a decision the cascade computes, but on this build the decision cannot reach a bot: the client half stops arming at read-only by construction, so the driver never ticks. The cause is NOT il2cpp_object_get_class -- that export is intact and ungated (it is `mov rax,[rcx]; ret`). It is that every hop past the alive-players list goes through LazyCall's BY-NAME binding (il2cpp_class_from_name / il2cpp_class_get_method_from_name), which on this build are token-gated exports: called without the token they return a plausible RANDOM handle and the client dies on the first dereference. Changing this cannot change what you see in a raid.",
                 implemented = false),
    floatSetting("roles.scav.timeBeforeSearch", "Scav: time before search (s)", 60.0,
                 lo = 1.0, hi = 180.0, step = 1.0,
                 category = "Roles", subcategory = "Scav",
                 description = "From SAIN (Solarint, maintained by ArchangelWTF), rewritten from scratch for aowlspt. Overrides the global search delay for scav bots only. READ into the preset and then into a decision the cascade computes, but on this build the decision cannot reach a bot: the client half stops arming at read-only by construction, so the driver never ticks. The cause is NOT il2cpp_object_get_class -- that export is intact and ungated (it is `mov rax,[rcx]; ret`). It is that every hop past the alive-players list goes through LazyCall's BY-NAME binding (il2cpp_class_from_name / il2cpp_class_get_method_from_name), which on this build are token-gated exports: called without the token they return a plausible RANDOM handle and the client dies on the first dereference. Changing this cannot change what you see in a raid.",
                 implemented = false),
    boolSetting("roles.scav.willSearchForEnemy", "Scav: will search for enemy", false,
                category = "Roles", subcategory = "Scav",
                description = "From SAIN (Solarint, maintained by ArchangelWTF), rewritten from scratch for aowlspt. Whether scav bots hunt a lost enemy at all, or hold where they are. READ into the preset and then into a decision the cascade computes, but on this build the decision cannot reach a bot: the client half stops arming at read-only by construction, so the driver never ticks. The cause is NOT il2cpp_object_get_class -- that export is intact and ungated (it is `mov rax,[rcx]; ret`). It is that every hop past the alive-players list goes through LazyCall's BY-NAME binding (il2cpp_class_from_name / il2cpp_class_get_method_from_name), which on this build are token-gated exports: called without the token they return a plausible RANDOM handle and the client dies on the first dereference. Changing this cannot change what you see in a raid.",
                implemented = false),
    floatSetting("roles.scav.runAwayHealthThreshold", "Scav: run away below health", 0.28,
                 lo = 0.0, hi = 1.0, step = 0.01,
                 category = "Roles", subcategory = "Scav",
                 description = "From SAIN (Solarint, maintained by ArchangelWTF), rewritten from scratch for aowlspt. Overrides the global flee threshold for scav bots only. READ into the preset and then into a decision the cascade computes, but on this build the decision cannot reach a bot: the client half stops arming at read-only by construction, so the driver never ticks. The cause is NOT il2cpp_object_get_class -- that export is intact and ungated (it is `mov rax,[rcx]; ret`). It is that every hop past the alive-players list goes through LazyCall's BY-NAME binding (il2cpp_class_from_name / il2cpp_class_get_method_from_name), which on this build are token-gated exports: called without the token they return a plausible RANDOM handle and the client dies on the first dereference. Changing this cannot change what you see in a raid.",
                 implemented = false),
    boolSetting("roles.scav.canShiftCoverPosition", "Scav: may shift cover", true,
                category = "Roles", subcategory = "Scav",
                description = "From SAIN (Solarint, maintained by ArchangelWTF), rewritten from scratch for aowlspt. Whether scav bots reposition between cover points under fire. Cover knob. Doubly inert: the cover sensor itself is OFF -- sampling cover needs UnityEngine.Physics::Raycast resolved BY NAME, which is fatal on this build -- so this feeds a cover decision that is never taken, in a driver that never ticks.",
                implemented = false),
    enumSetting("roles.boss.difficulty", "Boss: difficulty", "inherit",
                @["inherit", "easy", "lessdifficult", "default",
                  "harderpmcs", "veryhard", "deathwish"],
                category = "Roles", subcategory = "Boss",
                description = "From SAIN (Solarint, maintained by ArchangelWTF), rewritten from scratch for aowlspt. Difficulty band for bosses ONLY, overriding the global one. `inherit` leaves them on the global band. This reaches bots the same way the global Difficulty does -- the bot census carries each bot's WildSpawnType, so the mod can address a MoveSpeed at that bot by id over `aowlspt/botnav` -- with no new RVA and no by-name lookup. Set two roles to opposite ends and the difference is visible in one raid. Needs `botNav` on in aowlspt-host.json.",
                implemented = true),
    floatSetting("roles.boss.engageDistance", "Boss: engage distance (m)", 110.0,
                 lo = 5.0, hi = 300.0, step = 5.0,
                 category = "Roles", subcategory = "Boss",
                 description = "From SAIN (Solarint, maintained by ArchangelWTF), rewritten from scratch for aowlspt. Overrides the global engage distance for boss bots only. READ into the preset and then into a decision the cascade computes, but on this build the decision cannot reach a bot: the client half stops arming at read-only by construction, so the driver never ticks. The cause is NOT il2cpp_object_get_class -- that export is intact and ungated (it is `mov rax,[rcx]; ret`). It is that every hop past the alive-players list goes through LazyCall's BY-NAME binding (il2cpp_class_from_name / il2cpp_class_get_method_from_name), which on this build are token-gated exports: called without the token they return a plausible RANDOM handle and the client dies on the first dereference. Changing this cannot change what you see in a raid.",
                 implemented = false),
    floatSetting("roles.boss.timeBeforeSearch", "Boss: time before search (s)", 5.0,
                 lo = 1.0, hi = 180.0, step = 1.0,
                 category = "Roles", subcategory = "Boss",
                 description = "From SAIN (Solarint, maintained by ArchangelWTF), rewritten from scratch for aowlspt. Overrides the global search delay for boss bots only. READ into the preset and then into a decision the cascade computes, but on this build the decision cannot reach a bot: the client half stops arming at read-only by construction, so the driver never ticks. The cause is NOT il2cpp_object_get_class -- that export is intact and ungated (it is `mov rax,[rcx]; ret`). It is that every hop past the alive-players list goes through LazyCall's BY-NAME binding (il2cpp_class_from_name / il2cpp_class_get_method_from_name), which on this build are token-gated exports: called without the token they return a plausible RANDOM handle and the client dies on the first dereference. Changing this cannot change what you see in a raid.",
                 implemented = false),
    boolSetting("roles.boss.willSearchForEnemy", "Boss: will search for enemy", true,
                category = "Roles", subcategory = "Boss",
                description = "From SAIN (Solarint, maintained by ArchangelWTF), rewritten from scratch for aowlspt. Whether boss bots hunt a lost enemy at all, or hold where they are. READ into the preset and then into a decision the cascade computes, but on this build the decision cannot reach a bot: the client half stops arming at read-only by construction, so the driver never ticks. The cause is NOT il2cpp_object_get_class -- that export is intact and ungated (it is `mov rax,[rcx]; ret`). It is that every hop past the alive-players list goes through LazyCall's BY-NAME binding (il2cpp_class_from_name / il2cpp_class_get_method_from_name), which on this build are token-gated exports: called without the token they return a plausible RANDOM handle and the client dies on the first dereference. Changing this cannot change what you see in a raid.",
                implemented = false),
    floatSetting("roles.boss.runAwayHealthThreshold", "Boss: run away below health", 0.1,
                 lo = 0.0, hi = 1.0, step = 0.01,
                 category = "Roles", subcategory = "Boss",
                 description = "From SAIN (Solarint, maintained by ArchangelWTF), rewritten from scratch for aowlspt. Overrides the global flee threshold for boss bots only. READ into the preset and then into a decision the cascade computes, but on this build the decision cannot reach a bot: the client half stops arming at read-only by construction, so the driver never ticks. The cause is NOT il2cpp_object_get_class -- that export is intact and ungated (it is `mov rax,[rcx]; ret`). It is that every hop past the alive-players list goes through LazyCall's BY-NAME binding (il2cpp_class_from_name / il2cpp_class_get_method_from_name), which on this build are token-gated exports: called without the token they return a plausible RANDOM handle and the client dies on the first dereference. Changing this cannot change what you see in a raid.",
                 implemented = false),
    boolSetting("roles.boss.canShiftCoverPosition", "Boss: may shift cover", true,
                category = "Roles", subcategory = "Boss",
                description = "From SAIN (Solarint, maintained by ArchangelWTF), rewritten from scratch for aowlspt. Whether boss bots reposition between cover points under fire. Cover knob. Doubly inert: the cover sensor itself is OFF -- sampling cover needs UnityEngine.Physics::Raycast resolved BY NAME, which is fatal on this build -- so this feeds a cover decision that is never taken, in a driver that never ticks.",
                implemented = false),
    enumSetting("roles.zombie.difficulty", "Zombie: difficulty", "inherit",
                @["inherit", "easy", "lessdifficult", "default",
                  "harderpmcs", "veryhard", "deathwish"],
                category = "Roles", subcategory = "Zombie",
                description = "From SAIN (Solarint, maintained by ArchangelWTF), rewritten from scratch for aowlspt. Difficulty band for the infected ONLY, overriding the global one. `inherit` leaves them on the global band. This reaches bots the same way the global Difficulty does -- the bot census carries each bot's WildSpawnType, so the mod can address a MoveSpeed at that bot by id over `aowlspt/botnav` -- with no new RVA and no by-name lookup. Set two roles to opposite ends and the difference is visible in one raid. Needs `botNav` on in aowlspt-host.json.",
                implemented = true),
    floatSetting("roles.zombie.engageDistance", "Zombie: engage distance (m)", 200.0,
                 lo = 5.0, hi = 300.0, step = 5.0,
                 category = "Roles", subcategory = "Zombie",
                 description = "From SAIN (Solarint, maintained by ArchangelWTF), rewritten from scratch for aowlspt. Overrides the global engage distance for zombie bots only. READ into the preset and then into a decision the cascade computes, but on this build the decision cannot reach a bot: the client half stops arming at read-only by construction, so the driver never ticks. The cause is NOT il2cpp_object_get_class -- that export is intact and ungated (it is `mov rax,[rcx]; ret`). It is that every hop past the alive-players list goes through LazyCall's BY-NAME binding (il2cpp_class_from_name / il2cpp_class_get_method_from_name), which on this build are token-gated exports: called without the token they return a plausible RANDOM handle and the client dies on the first dereference. Changing this cannot change what you see in a raid.",
                 implemented = false),
    floatSetting("roles.zombie.timeBeforeSearch", "Zombie: time before search (s)", 1.0,
                 lo = 1.0, hi = 180.0, step = 1.0,
                 category = "Roles", subcategory = "Zombie",
                 description = "From SAIN (Solarint, maintained by ArchangelWTF), rewritten from scratch for aowlspt. Overrides the global search delay for zombie bots only. READ into the preset and then into a decision the cascade computes, but on this build the decision cannot reach a bot: the client half stops arming at read-only by construction, so the driver never ticks. The cause is NOT il2cpp_object_get_class -- that export is intact and ungated (it is `mov rax,[rcx]; ret`). It is that every hop past the alive-players list goes through LazyCall's BY-NAME binding (il2cpp_class_from_name / il2cpp_class_get_method_from_name), which on this build are token-gated exports: called without the token they return a plausible RANDOM handle and the client dies on the first dereference. Changing this cannot change what you see in a raid.",
                 implemented = false),
    boolSetting("roles.zombie.willSearchForEnemy", "Zombie: will search for enemy", true,
                category = "Roles", subcategory = "Zombie",
                description = "From SAIN (Solarint, maintained by ArchangelWTF), rewritten from scratch for aowlspt. Whether zombie bots hunt a lost enemy at all, or hold where they are. READ into the preset and then into a decision the cascade computes, but on this build the decision cannot reach a bot: the client half stops arming at read-only by construction, so the driver never ticks. The cause is NOT il2cpp_object_get_class -- that export is intact and ungated (it is `mov rax,[rcx]; ret`). It is that every hop past the alive-players list goes through LazyCall's BY-NAME binding (il2cpp_class_from_name / il2cpp_class_get_method_from_name), which on this build are token-gated exports: called without the token they return a plausible RANDOM handle and the client dies on the first dereference. Changing this cannot change what you see in a raid.",
                implemented = false),
    floatSetting("roles.zombie.runAwayHealthThreshold", "Zombie: run away below health", 0.0,
                 lo = 0.0, hi = 1.0, step = 0.01,
                 category = "Roles", subcategory = "Zombie",
                 description = "From SAIN (Solarint, maintained by ArchangelWTF), rewritten from scratch for aowlspt. Overrides the global flee threshold for zombie bots only. READ into the preset and then into a decision the cascade computes, but on this build the decision cannot reach a bot: the client half stops arming at read-only by construction, so the driver never ticks. The cause is NOT il2cpp_object_get_class -- that export is intact and ungated (it is `mov rax,[rcx]; ret`). It is that every hop past the alive-players list goes through LazyCall's BY-NAME binding (il2cpp_class_from_name / il2cpp_class_get_method_from_name), which on this build are token-gated exports: called without the token they return a plausible RANDOM handle and the client dies on the first dereference. Changing this cannot change what you see in a raid.",
                 implemented = false),
    boolSetting("roles.zombie.canShiftCoverPosition", "Zombie: may shift cover", false,
                category = "Roles", subcategory = "Zombie",
                description = "From SAIN (Solarint, maintained by ArchangelWTF), rewritten from scratch for aowlspt. Whether zombie bots reposition between cover points under fire. Cover knob. Doubly inert: the cover sensor itself is OFF -- sampling cover needs UnityEngine.Physics::Raycast resolved BY NAME, which is fatal on this build -- so this feeds a cover decision that is never taken, in a driver that never ticks.",
                implemented = false),
    boolSetting("server.patchBrains", "Patch bot brains", true,
                category = "Server", subcategory = "Database",
                description = "From SAIN (Solarint, maintained by ArchangelWTF), rewritten from scratch for aowlspt. Rewrite the server's brain-assignment tables so bots use the brain this mod drives. Runs on every server start and the edit is visible in the served database.",
                implemented = true),
    boolSetting("server.neutraliseLocationModifiers", "Neutralise location modifiers", true,
                category = "Server", subcategory = "Database",
                description = "From SAIN (Solarint, maintained by ArchangelWTF), rewritten from scratch for aowlspt. Set every map's BotLocationModifier to 1, so the stock per-map accuracy, vision and scatter multipliers stop distorting bot behaviour. Applied to every location the database carries, including ones that announce themselves later.",
                implemented = true),
    boolSetting("logDecisions", "Log decisions", false,
                category = "Advanced", subcategory = "Diagnostics",
                description = "From SAIN (Solarint, maintained by ArchangelWTF), rewritten from scratch for aowlspt. Log every drive command: the speed sent, how many bots were tracked and how many were seen to move.",
                implemented = true),
    boolSetting("driveFromHostThread", "Drive from host thread", true,
                category = "Advanced", subcategory = "Diagnostics",
                description = "From SAIN (Solarint, maintained by ArchangelWTF), rewritten from scratch for aowlspt. Governs the by-NAME client driving path. That path is fatal on this build and is never taken; real driving goes over aowlspt/botnav instead, so this switch changes nothing.",
                implemented = false),
    boolSetting("allowIl2cppReflection", "Allow IL2CPP reflection", false,
                category = "Advanced", subcategory = "Diagnostics",
                description = "From SAIN (Solarint, maintained by ArchangelWTF), rewritten from scratch for aowlspt. A re-measurement switch, not a feature. Turning it on lets this mod resolve game types BY NAME, which on this build returns a plausible random handle and kills the client on first use. Deliberately left un-editable so nobody flips it by accident.",
                implemented = false),
    boolSetting("sainRvaTable", "Bind members from the RVA table", false,
                category = "Advanced", subcategory = "Diagnostics",
                description = "From SAIN (Solarint, maintained by ArchangelWTF), rewritten from scratch for aowlspt. Binds 36 of SAIN's members from the table in client/rvatable.nim -- 27 direct calls at static RVAs and 9 guarded field reads -- derived offline with tools/il2cpp_resolve.py and byte-verified 16/16 before any call, instead of resolving them by name; by-name resolution is the token-gated path that returns a random non-zero handle and kills the client. The other 21 members SAIN asks for are REFUSED by name in the log (absent from the image, wrong arity, wrong owner, a shared RVA with hundreds of owners, an instantiated generic whose layout is not reachable offline, or an interface receiver that cannot be identified on a live object) and are never retried reflectively. THIS FLAG ALONE BINDS NOTHING: how much of the table may bind is sainRvaTableDriveLevel, which defaults to 0 OBSERVER. This does NOT make bots fight: the movement, sprint, stop and shoot calls are all in the refused set. Default OFF.",
                implemented = true),
    intSetting("sainRvaTableDriveLevel", "RVA table drive level (0-3)", 0,
               lo = 0, hi = 3, step = 1,
               category = "Advanced", subcategory = "Diagnostics",
               description = "How much of the RVA table above is allowed to bind. Ignored unless sainRvaTable is on. 0 OBSERVER: nothing binds; every keyed member refuses at bind time and says what level it needed, so a raid at 0 is a dry run of the refusals with no calls into the game at all. 1 READS: every bound member is an arity-0 getter or a guarded field read, and the field mechanism has no invoke path, so nothing at this level can change the game's state. 2 AIM: adds the two-hop walk BotOwner -> AimingManager -> CurrentAiming and a POSTFIX on Aiming::get_IsReady @0x1AD48C0 (UNIQUE, prologue verified by the host against its startup snapshot). The postfix watches and never rewrites; the gate it feeds can only WITHHOLD a shot the decision ladder already ordered, so a missing reading behaves exactly like no sensor. 3 DRIVE: adds the only two calls in the table that make a bot act -- BotSteering::LookToPoint and BotReload::TryReload. Every other drive member SAIN asks for (GoToPoint, Sprint, Stop, Shoot, and all three medical applies) is a stated refusal, so level 3 is two calls and not a combat brain. Raise it one notch per raid. Default 0.",
               implemented = true),

    # Bot AI > Loadout. These knobs are declared and owned here; the generation
    # they govern lives in the server's own bot generator. `richnessMultiplier`
    # is wired end to end and changes what a killed bot drops; the tier and
    # min/max rows are the config SCHEMA for a fuller loadout system that the
    # generator does not read yet, and each says so and stays greyed until it
    # does -- a control that renders and does nothing is worse than an absent one.
    floatSetting("botLoot.richnessMultiplier", "Loot richness", 1.0,
                 lo = 0.0, hi = 5.0, step = 0.1,
                 category = "Loadout", subcategory = "Loot",
                 description = "Global multiplier on how much loose loot a generated bot carries in its pockets, rig and backpack. 1.0 is stock (what the weight tables say), 2.0 is a bot stuffed with valuables, 0.0 sends it out empty-handed. LIVE on this build: the server's own bot generator reads it, so a scav you kill after changing it drops more or less. Takes effect on the next server start, when the value is published to the generator.",
                 implemented = true, appliesOn = "restart"),
    boolSetting("botLoot.realisticLoot", "Realistic loot", true,
                category = "Loadout", subcategory = "Loot",
                description = "SCHEMA ONLY -- not yet read by the generator. Intended toggle between realistic loot (weighted like the live game) and a generous everyone-carries-valuables mode. Declared so the config key exists for a later pass; greyed until the generator reads it.",
                implemented = false),
    enumSetting("botLoot.weaponTier", "Weapon tier", "role",
                @["role", "low", "mid", "high", "meta"],
                category = "Loadout", subcategory = "Gear",
                description = "SCHEMA ONLY -- not yet read by the generator. Intended per-bot weapon quality: `role` uses the database's own per-role weapon pool (current behaviour); the others would bias the pick toward cheaper or higher-end guns. Declared so the key exists; greyed until wired.",
                implemented = false, appliesOn = "restart"),
    enumSetting("botLoot.ammoTier", "Ammo tier", "role",
                @["role", "low", "mid", "high", "meta"],
                category = "Loadout", subcategory = "Gear",
                description = "SCHEMA ONLY -- not yet read by the generator. Intended per-bot ammo penetration tier. `role` keeps the database's own ammo weighting. Declared so the key exists; greyed until wired.",
                implemented = false, appliesOn = "restart"),
    enumSetting("botLoot.armorTier", "Armor tier", "role",
                @["role", "low", "mid", "high", "meta"],
                category = "Loadout", subcategory = "Gear",
                description = "SCHEMA ONLY -- not yet read by the generator. Intended per-bot armor class bias. `role` keeps the database's own armor weighting. The required-slot fix means whatever armor is chosen is now built complete; the tier that PICKS it is future work. Declared so the key exists; greyed until wired.",
                implemented = false, appliesOn = "restart"),
    intSetting("botLoot.pocketLootMin", "Pocket loot min", 0,
               lo = 0, hi = 6, step = 1,
               category = "Loadout", subcategory = "Quantity",
               description = "SCHEMA ONLY -- not yet read by the generator. Intended floor on pocket loot count, independent of the richness multiplier. Declared so the key exists; greyed until wired.",
               implemented = false, appliesOn = "restart"),
    intSetting("botLoot.pocketLootMax", "Pocket loot max", 4,
               lo = 0, hi = 12, step = 1,
               category = "Loadout", subcategory = "Quantity",
               description = "SCHEMA ONLY -- not yet read by the generator. Intended ceiling on pocket loot count. Declared so the key exists; greyed until wired.",
               implemented = false, appliesOn = "restart"),
    intSetting("botLoot.rigLootMin", "Rig loot min", 0,
               lo = 0, hi = 10, step = 1,
               category = "Loadout", subcategory = "Quantity",
               description = "SCHEMA ONLY -- not yet read by the generator. Intended floor on tactical-rig loot count. Declared so the key exists; greyed until wired.",
               implemented = false, appliesOn = "restart"),
    intSetting("botLoot.rigLootMax", "Rig loot max", 6,
               lo = 0, hi = 16, step = 1,
               category = "Loadout", subcategory = "Quantity",
               description = "SCHEMA ONLY -- not yet read by the generator. Intended ceiling on tactical-rig loot count. Declared so the key exists; greyed until wired.",
               implemented = false, appliesOn = "restart"),
    intSetting("botLoot.backpackLootMin", "Backpack loot min", 0,
               lo = 0, hi = 12, step = 1,
               category = "Loadout", subcategory = "Quantity",
               description = "SCHEMA ONLY -- not yet read by the generator. Intended floor on backpack loot count. Declared so the key exists; greyed until wired.",
               implemented = false, appliesOn = "restart"),
    intSetting("botLoot.backpackLootMax", "Backpack loot max", 6,
               lo = 0, hi = 20, step = 1,
               category = "Loadout", subcategory = "Quantity",
               description = "SCHEMA ONLY -- not yet read by the generator. Intended ceiling on backpack loot count. Declared so the key exists; greyed until wired.",
               implemented = false, appliesOn = "restart")]

# ---------------------------------------------------------------------------
# The child mods' rows, proxied into this page
# ---------------------------------------------------------------------------

proc childGuids(): seq[string] =
  ## The INTERNAL guids of the mods whose rows render inside this page, in the
  ## order their sections appear. None of these is user-visible anywhere: each
  ## is hidden from the mod list, declares its schema with `inIndex = false`
  ## so it claims no nav entry of its own, and has its rows proxied here --
  ## `aowl.morebots` as `Bot AI > Population`, `aowl.waypoints` as
  ## `Bot AI > Waypoints`. Do NOT rename one: the registry, the selection
  ## store, their routes and deploy verification all key off these exact
  ## strings, and `registry/mods.json` records the same tree declaratively as
  ## `"parent": "aowl.sain"`.
  ##
  ## Adding a child is this list plus `inIndex = false` in that mod, and
  ## nothing else. The child keeps its guid, its routes and its own
  ## `config.json`, and it stays the ONE owner of its values: this page
  ## renders them and forwards a write back to it. A row that rendered here
  ## and also persisted here would be two sources of truth and would drift.
  result = @["aowl.morebots", "aowl.waypoints"]

var gChildRows: seq[string] = @[]    ## rows each child last announced, by slot
var gChildKeys: seq[string] = @[]    ## every key any child carries...
var gChildOwner: seq[string] = @[]   ## ...and the guid that owns it, parallel
var gChildSubscribed = false

proc childIndex(guid: string): int =
  result = -1
  let gs = childGuids()
  for i in 0 ..< gs.len:
    if gs[i] == guid: return i

proc rebuildChildKeys() =
  ## Recompute the key -> owner table from every slot. Rebuilt whole rather
  ## than appended to, so a child that re-announces a SHORTER schema does not
  ## leave a stale key behind pointing at it.
  gChildKeys = @[]
  gChildOwner = @[]
  let gs = childGuids()
  for i in 0 ..< gChildRows.len:
    if gChildRows[i].len <= 1: continue
    let rows = parseArray(gChildRows[i])
    for ri in 0 ..< rows.len:
      let k = field(at(rows, ri), "key").asText("")
      if k.len > 0:
        gChildKeys.add k
        gChildOwner.add gs[i]

proc onChildRows(guid, rowsText: string) =
  let i = childIndex(guid)
  if i < 0: return
  while gChildRows.len < childGuids().len: gChildRows.add ""
  gChildRows[i] = rowsText
  rebuildChildKeys()

proc onChildPage(payload: string): string =
  onChildRows(field(payload, "guid").asText(""), field(payload, "rows").raw())
  result = ""

proc onChildApplied(payload: string): string =
  onChildRows(field(payload, "guid").asText(""), field(payload, "rows").raw())
  result = ""

proc childSubscribe() =
  if gChildSubscribed: return
  discard on(SettingsPageAnnounce, onChildPage)
  discard on(SettingsApplyAnnounce, onChildApplied)
  gChildSubscribed = true

proc refreshChildRows() =
  ## Ask every child for its rows. The broadcast is SYNCHRONOUS --
  ## `deliverEvent` calls every subscriber before `emit` returns -- so a slot
  ## is current when this returns, or stays EMPTY, which means that child is
  ## not loaded. Empty is reported as an ABSENT section, never as an empty
  ## one: "I could not look" is not "there is nothing there".
  childSubscribe()
  gChildRows = @[]
  let gs = childGuids()
  for i in 0 ..< gs.len: gChildRows.add ""
  rebuildChildKeys()
  for g in gs:
    discard emit(SettingsPageQuery, g)

proc ownsKey(key: string): bool =
  result = false
  # Bound to a local first: iterating the call directly borrows from a
  # temporary, which the compiler refuses.
  let mine = declaredSettings()
  for st in mine:
    if st.key == key: return true

proc childOwnerOf(key: string): string =
  ## The guid that owns a proxied key, or "" if no child claims it.
  result = ""
  for i in 0 ..< gChildKeys.len:
    if gChildKeys[i] == key: return gChildOwner[i]

proc mergedPage(): string =
  ## This mod's rows followed by every child's, in section order, as ONE array.
  refreshChildRows()
  var outList = parseArray(schemaJson(declaredSettings()).text)
  for i in 0 ..< gChildRows.len:
    if gChildRows[i].len <= 1: continue
    let sub = parseArray(gChildRows[i])
    for ri in 0 ..< sub.len:
      outList.add at(sub, ri).raw()
  result = outList.text()

proc forwardToChild(body: string; isReset: bool): bool =
  ## True if the edit named a proxied row and was handed to its OWNER. A key
  ## this mod declares always wins, so a proxy can never shadow a local row;
  ## an unknown key is refused here and falls through to the normal local
  ## path, which reports it properly.
  result = false
  let k = field(body, "key").asText("")
  if k.len == 0 or ownsKey(k): return false
  childSubscribe()
  if gChildKeys.len == 0: refreshChildRows()
  let owner = childOwnerOf(k)
  if owner.len == 0: return false
  var q = "{\"guid\":\"" & owner & "\",\"key\":\"" & k & "\""
  if isReset:
    q = q & ",\"reset\":true}"
  else:
    q = q & ",\"value\":" & field(body, "value").raw() & "}"
  discard emit(SettingsApplyQuery, q)
  result = true

proc onSainSettings(url, body, session: string): string =
  ## GET serves the schema; a POST body persists one edit into config.json. SAIN
  ## reads its settings inline, so the write is saved and applied at the next
  ## load rather than made live here.
  var st = Ok
  if body.len > 0 and not forwardToChild(body, false):
    st = applySettingFromBody(body)
  if st != Ok:
    return declaredSchemaReply(st).text
  result = mergedPage()

proc onSainSettingsReset(url, body, session: string): string =
  var st = Ok
  if not forwardToChild(body, true):
    st = resetFromBody(body)
  if st != Ok:
    return declaredSchemaReply(st).text
  result = mergedPage()

const ReloadProbe = 1
  ## THE PROOF THAT A RELOAD RELOADED ANYTHING. Bump this by one, rebuild, press
  ## reload, and the line below must show the new number.
  ##
  ## It exists because "it reloaded" and "nothing happened" otherwise produce
  ## identical evidence: no crash, a mod still listed, and a host log that says
  ## an unload and a load both succeeded -- all of which are equally true if the
  ## old library was quietly left in place. A value that only changes when the
  ## source changes is the one thing in the loop that cannot be faked by the
  ## machinery under test.
  ##
  ## Deliberately a hand-edited const rather than a build timestamp: the step
  ## being verified is "change code, press reload, see the change", and a stamp
  ## that moves on every rebuild would also move when nothing was edited.

proc declareSainSettings(): int =
  ## Declare the schema AND prove, on this machine on every load, the two
  ## properties the 2026-09-02 03:00 client crash turned on. Returns the number
  ## of FAILED checks; 0 is a pass.
  ##
  ## That crash died in `toJson` <- `schemaJson` <- `onPageQuery` <-
  ## `eventTrampoline`, on a host thread, reading
  ## `gDeclared.data[20].optionsUrl.more_0` == 0xdfdfdfdfdfdfdfdf -- mimalloc's
  ## MI_DEBUG_FREED fill, so the published schema buffer had been FREED. The
  ## index was in range and the pointer arithmetic was exact, which rules out
  ## the two explanations that look right from the source: an out-of-range walk
  ## and an uninitialised field.
  ##
  ## THIS RUNS BEFORE THE GAME EXISTS and needs nothing from it, which is the
  ## point: the failure it guards is a race that only shows up one boot in
  ## three, and a check that can only run in the failing window is not a check.
  ## Both halves can genuinely fail -- comment out the `gPublished` guard in
  ## `aowlspt/settings` and the second one reports FAIL on the next load.
  result = 0

  # 1. BEFORE ANYTHING IS PUBLISHED. The schema path must REFUSE with a reason
  #    and must not fault. `declaredSchemaJson` is the same walk `onPageQuery`
  #    does, so calling it here is the pre-publish path under test, not a proxy
  #    for it.
  let whyBefore = schemaPublishReason()
  let rowsBefore = declaredSchemaJson().text
  if whyBefore.len == 0:
    error "sain: publish-once selftest FAIL -- schemaPublishReason() was " &
          "EMPTY before declareSettings, i.e. it reported the schema ready " &
          "when nothing had been published"
    inc result
  if rowsBefore != "[]":
    error "sain: publish-once selftest FAIL -- the pre-publish schema walk " &
          "returned " & $rowsBefore.len & " bytes instead of an empty array"
    inc result

  declareSettings(sainSchema())

  # 2. AFTER. Ready, with rows.
  let whyAfter = schemaPublishReason()
  let n = declaredSettings().len
  if whyAfter.len > 0:
    error "sain: publish-once selftest FAIL -- after declareSettings the " &
          "schema still refuses: " & whyAfter
    inc result
  if n == 0:
    error "sain: publish-once selftest FAIL -- declareSettings published 0 rows"
    inc result

  # 3. THE REFUSAL, EXERCISED FOR REAL. A second declaration must not replace
  #    the schema, because replacing it frees the seq a reader on another
  #    thread may be walking. Asserted on the FINISHED STATE -- the row count
  #    afterwards -- not on the call returning.
  # The canary is an EMPTY schema, deliberately: a row would be a declared
  # setting with no key in config.json, which is exactly the "control that
  # renders and resolves to nothing" the mods build audit fails on -- it
  # caught this on the first build.
  var canary: seq[Setting] = @[]
  declareSettings(canary)
  if declaredSettings().len != n:
    error "sain: publish-once selftest FAIL -- a second declareSettings " &
          "REPLACED the schema (" & $n & " rows became " &
          $declaredSettings().len & "). That is the use-after-free this " &
          "guard exists to make unrepresentable. Re-declaring to recover."
    inc result
    declareSettings(sainSchema())
  if result == 0:
    info "sain: settings publish-once selftest PASS -- the schema refused " &
         "with a reason before it was published, published " & $n & " rows, " &
         "and refused a second declaration without dropping any of them"

proc onLoad(): Status =
  info "sain: ReloadProbe=" & $ReloadProbe & " -- if this number did not change " &
       "after you edited it and reloaded, the reload did NOT take"
  discard declareSainSettings()
  discard serve("/aowlspt/settings/aowl.sain", onSainSettings)
  discard serve("/aowlspt/settings/aowl.sain/reset", onSainSettingsReset)
  gPreset = loadPreset()
  if not gPreset.enabled:
    warn "sain: disabled in config.json"
    return Ok

  case side()
  of sideServer:
    startServer(gPreset)
  of sideSim:
    if runSelfTest(gPreset.base) > 0:
      return ErrGeneric
    if runBindingSelfTest() > 0:
      return ErrGeneric
    # Drive the whole pipeline once with no game attached: register a handful of
    # bots and tick them. This is what proves the driver's budget, its
    # round-robin cursor and the per-bot state plumbing outside a raid -- the
    # decision core has its own tests, and this is the layer above them.
    setPreset(gPreset)
    if runDriveQueueSelfTest() > 0:
      return ErrGeneric
    spawnBot("sim-pmc", "pmcUSEC", 0.7)
    spawnBot("sim-scav", "assault", 0.3)
    spawnBot("sim-boss", "bossKilla", 1.0)
    var i = 0
    while i < 20:
      tick(100'i64)
      inc i
    info "sain: " & stats()
    despawnBot("sim-scav")
    if botCount() != 2:
      error "sain: despawn did not compact the bot table"
      return ErrGeneric
    success "sain: driver pipeline exercised without a game attached"
  of sideClient:
    setPreset(gPreset)
    # Before anything can resolve a name. `live.nim` refuses by-name
    # resolution unless this says otherwise, and it must be told at load
    # rather than at arming time, because arming is where the fault was.
    setAllowReflection(gPreset.allowIl2cppReflection)
    setClientLocomotion(gPreset.clientDrivesLocomotion)
    # THE ONE-WRITER DECISION, made once, at load, in one place.
    #
    # `objectivesEnabled` does not merely add a behaviour: it MOVES the
    # destination writer from `server/dispatch.nim` to the client decide
    # ladder. Setting it here rather than at arming time means there is no
    # window in which a census arrives and both paths believe they own the
    # channel.
    setObjectivesOwnDestinations(gPreset.base.objectivesEnabled)
    if gPreset.base.objectivesEnabled:
      info "sain: objectives are ON. server/dispatch will issue NO " &
           "destination this session; core/decide.nim is the single writer. " &
           "/aowlspt/sain/status carries `oneWriter`, which FAILS -- not " &
           "merely stays quiet -- if the dispatch path is ever measured " &
           "issuing one anyway"
    # Same reason, same moment: the RVA table decides what `ensure` does, so it
    # must be set before the first member is touched rather than at arming.
    setRvaTable(gPreset.rvaTable)
    setRvaDriveLevel(gPreset.rvaDriveLevel)
    if gPreset.allowIl2cppReflection:
      warn "sain: allowIl2cppReflection is ON. On this build that is a " &
           "known process-killer, and the mechanism is measured rather than " &
           "guessed (docs/IL2CPP_EXPORTS.md): il2cpp_class_from_name is one " &
           "of 40 TOKEN-GATED exports. It takes a trailing 32-byte token the " &
           "stock signature does not have, and when it does not match -- " &
           "always, here -- it returns a uniform random non-zero uint64 " &
           "rather than failing. The nil check passes, the checks after it " &
           "pass, and the first real dereference takes the client down. This " &
           "is a re-measurement switch, not a feature switch"
    # EAGER, at load, and deliberately not inside `report()`: a refusal for a
    # member no bot ever reaches would otherwise print as `unused`.
    rvaReport()
    info "sain: client half loaded; waiting for the game world"
  else:
    discard
  Ok

proc onUpdate(elapsedMs: int64): Status =
  if not gPreset.enabled or side() != sideClient:
    return Ok

  let now = nowMs()

  # THE UNITY-THREAD GATE, and it is the first thing here because everything
  # below it touches the runtime.
  #
  # `whenReady("EFT.GameWorld")` does NOT mean a world exists. It means the
  # TYPE resolves, and the type resolves as soon as the client's metadata is
  # up -- which is at host boot, with no raid anywhere. MEASURED, on the fov
  # crash run, from `aowlspt-host.log`: `HOST RUNNING` at 0:00:01.328,
  # `FOV Fix: the game world is up` at 0:00:01.375, seven types resolved, then
  # the process was gone -- run length 1.375s, and the boot table's
  # `Unity thread live` row never filled in. On a run with none of those mods
  # enabled the same row is confirmed at 14.469s. So the block below used to
  # run about thirteen seconds before Unity's thread existed, from the host's
  # own worker, and that window is the only thing the surviving mods do not
  # enter. This is section 9b of CLAUDE.md exactly: a readiness check that
  # could not fail.
  #
  # `mainThread().bound` is the check that can. The host sets it only once its
  # per-frame drain has ACTUALLY FIRED -- installed is not fired -- so it is
  # positive evidence of Unity's thread rather than of our own optimism. Until
  # it is true this mod binds nothing, hooks nothing and reads nothing; it
  # costs one `call` every two seconds (`refreshMainThread` rate-limits
  # itself) and it says so once.
  let mt = refreshMainThread(now)
  if not mt.bound:
    if not gDeferNoted and mt.asked:
      gDeferNoted = true
      info "sain: " & mainThreadNote() &
           " -- deferring every binding, hook and read until it has. " &
           "Nothing is bound and nothing is driven, and this line is the " &
           "reason. `EFT.GameWorld` is deliberately NOT probed yet: the type " &
           "resolves at host boot with no raid anywhere, so probing it here " &
           "would spend `ready()`'s one-shot on the wrong tick."
    return Ok

  if gWorld.ready():
    # The world exists. Bind everything and say what took, before doing
    # anything that assumes an answer. This is the first tick on which
    # `bindMethod` can succeed -- `docs/PERF.md` is explicit that binding in
    # `onLoad` correctly refuses, because the game's assemblies are not up.
    # THIS IS THE TICK THE CRASH LANDS ON, so it is traced from the outside as
    # well as from the inside. MEASURED, `D:\Aowlspt\hostlogs\sain-crash.log`:
    # the drain came up at 8.032s, the client was gone by 8.141s, and this mod
    # produced no line at all in between -- because the first line it used to
    # produce came from `announce`, below all three calls.
    info "sain: the Unity-thread gate has opened and EFT.GameWorld resolves; " &
         "arming now -- probe, then announce, then installHooks"
    discard probe()
    info "sain: probe returned"
    announce()
    info "sain: announce returned"
    installHooks()
    info "sain: installHooks returned; arming complete"

  # The capFull EDGE, both ways, before anything else reads the capability.
  if capability() == capFull and not gWasFull:
    gWasFull = true
    gCensusAt = now + CensusAtMs
  elif capability() != capFull and gWasFull:
    gWasFull = false
    if not gCensusFinalDone:
      gCensusFinalDone = true
      emitCensus("raid ended -- capability fell back to " &
                 (if capability() == capReadOnly: "capReadOnly" else: "capNone"))

  if capability() != capFull:
    # Re-probe occasionally rather than every frame: the answer only changes
    # when the game loads a raid, and `resolve` walks every loaded assembly.
    # Between raids this is the whole per-frame cost of the mod.
    if now - gProbedAt > 2000'i64:
      gProbedAt = now
      discard probe()
    return Ok

  # Discovery first, then decisions: a bot registered by the hook this frame
  # gets its handle before it is asked to think, so its first decision reads
  # the game rather than the defaults.
  scan(now)
  tick(elapsedMs)

  if (not gCensusEarlyDone) and gCensusAt > 0'i64 and now >= gCensusAt:
    gCensusEarlyDone = true
    emitCensus("one minute in -- the raid is still running, so these numbers " &
               "are a floor and the raid-ended census supersedes them")
  Ok

proc onUnload(): Status =
  if side() == sideServer:
    stopServer()
  if side() == sideClient:
    # Order matters: the stats line names how many handles were released, and
    # `releaseAll` is what makes that number true.
    if gWasFull and not gCensusFinalDone:
      gCensusFinalDone = true
      emitCensus("unload")
    releaseAll()
    info "sain: " & stats()
  Ok

## `mfHotReloadable` is claimed on the strength of the audit, not on optimism,
## and the four things it asserts are each checkable:
##
##  * **Detours** -- registered through `patch`, so `dropModRegistrations`
##    removes them and bumps the slot generation before `FreeLibrary`.
##  * **Callbacks** -- subscriptions and queued main-thread work, dropped under
##    the host's lock by the same teardown.
##  * **Threads** -- none. `createThread` has no hits in this mod.
##  * **GC handles** -- the one real hazard. `onUnload` calls `releaseAll()`,
##    and as of the handle-ownership change the host frees any it missed and
##    logs the count. That count should be 0 for this mod; a non-zero one is a
##    bug in `releaseAll`, not in the host.
##
## What it does NOT assert is that state survives: no host calls
## `stateSave`/`stateLoad` yet, so a reload restarts this mod's bot table from
## empty and it re-attaches on its next scan.
exportMod(guid = "aowl.sain", name = "Bot AI", author = "aowlspt", version = "0.1.0",
          sptRange = "*", sides = {sideClient, sideServer, sideSim},
          flags = {mfHotReloadable},
          onLoad = onLoad, onUpdate = onUpdate, onUnload = onUnload)
