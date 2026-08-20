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
import core/vec
import core/types
import core/probe
import core/sig
import core/selftest
import preset/preset
import core/settings
import client/bridge
import client/driver
import client/live
import client/coverprobe
import server/serverside

var gWorld = whenReady("EFT.GameWorld")
var gPreset: Preset
var gProbedAt = 0'i64
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
const SpawnHookCandidates: array[3, string] = [
  "EFT.BotsController::AddActivePLayer",
  "EFT.BotSpawner::AddPlayer",
  "EFT.BotsController::AddActivePlayer"]

## The methods that might tell us a player died.
##
## `OnDead` is an instance method on the player that died, which is exactly the
## shape that was unreachable before ABI revision 3: the payload named the
## arguments and not the instance, so the handler learned that *a* player had
## died. `thisPointer` is the whole difference, and it is why the death poll in
## `client/driver.nim` can now be turned off.
const DeathHookCandidates: array[3, string] = [
  "EFT.Player::OnDead",
  "EFT.Player::Kill",
  "EFT.Player::OnBeenKilledByAggressor"]

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
const AimHookCandidates: array[3, string] = [
  "EFT.AimDataClass::get_IsReady",
  "EFT.BotAimingData::get_IsReady",
  "EFT.BotOwner::get_AimingIsReady"]

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
  noteDamage(who, amount)
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
  var tried = 0
  var j = 0
  while j < AimHookCandidates.len:
    let name = AimHookCandidates[j]
    inc j
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

  var i = 0
  var spawnOk = false
  while i < SpawnHookCandidates.len:
    let name = SpawnHookCandidates[i]
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
  armAimHook()
  armDamageHook()

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
  result = r.failed + runCostReport(s)

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

proc onLoad(): Status =
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
    info "sain: client half loaded; waiting for the game world"
  else:
    discard
  Ok

proc onUpdate(elapsedMs: int64): Status =
  if not gPreset.enabled or side() != sideClient:
    return Ok

  if gWorld.ready():
    # The world exists. Bind everything and say what took, before doing
    # anything that assumes an answer. This is the first tick on which
    # `bindMethod` can succeed -- `docs/PERF.md` is explicit that binding in
    # `onLoad` correctly refuses, because the game's assemblies are not up.
    discard probe()
    announce()
    installHooks()

  let now = nowMs()
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
  Ok

proc onUnload(): Status =
  if side() == sideClient:
    # Order matters: the stats line names how many handles were released, and
    # `releaseAll` is what makes that number true.
    releaseAll()
    info "sain: " & stats()
  Ok

exportMod(guid = "aowl.sain", name = "SAIN", author = "aowlspt port of SAIN " &
          "by Solarint and ArchangelWTF", version = "0.1.0",
          sptRange = "*", sides = {sideClient, sideServer, sideSim},
          onLoad = onLoad, onUpdate = onUpdate, onUnload = onUnload)
