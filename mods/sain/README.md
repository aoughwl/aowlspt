# Bot AI -- the bot behaviour mod, rewritten in nimony for post-1.0 Tarkov

**Bot AI** is what this mod is called everywhere a player sees it: the F12
page, the mod manager entry, the log. The directory, the guid (`aowl.sain`)
and the routes keep their original spelling because they are identities on the
wire, not names on a screen.

It replaces Tarkov's stock bot AI: layered decisions, per-bot personalities,
real cover use, searching that looks like searching, and squads that behave
like squads. The spawn-population expansion is part of Bot AI too, rather than
a separate mod: its rows render under `Bot AI > Population` and its binary
(`mods/morebots`, guid `aowl.morebots`) is hidden from the player mod list.

The design is a from-scratch rewrite of the one SAIN (Solarint, maintained by
ArchangelWTF) established -- ~64,000 lines of C# built on BepInEx, Harmony and
BigBrain. That attribution is why the name still appears below: this file
describes what was ported and what was not, and naming the prior art is
provenance rather than branding.

Post-1.0 Tarkov has none of those three. This is therefore a rewrite of SAIN's
**design** against a native mod ABI, not a translation of its code — and the
first job of this file is to be precise about which parts of that design
survived the move, which are waiting on a sensor, and which are gone for good.

**Nothing here has ever run against BSG's client.** Every `EFT.` name in
`client/live.nim` comes from the pre-1.0 C# surface; post-1.0 is a different
build and some of them will be wrong. A wrong one produces a refused binding
with a reason in the log and a defaulted value — never a wrong number. The
binding report `announce()` prints once is the only thing to read before
drawing any conclusion about behaviour in a raid.

---

## 1. The map: what this design does, and what of it is reachable here

Four columns' worth of judgement, in three groups.

### Expressible today — and implemented

| SAIN feature | How it is reached here |
|---|---|
| **Layered decision-making** — self-care above squad above solo combat, one priority cascade at 10 Hz emitting three simultaneous outputs | `core/decide.nim`. Same shape, same order, same three enums. The one structural change is that hysteresis is stated *once* (urgency + a hold time) instead of as a timer per check. |
| **Per-bot personality** — eight personalities as multipliers over every threshold | `core/settings.nim`. Resolved into a flat struct **once at spawn**; the ladder then compares plain numbers. SAIN reads `Bot.Info.Personality.Behavior.X` inside each check. |
| **Difficulty presets** | One scalar through `resolvedFor`, plus per-setting overrides in `config.json`. Difficulty now moves perception rather than behaviour: acquisition rate and reaction delay, and with them hearing acuity and both seen-time thresholds. This used to say two dials; `resolvedFor` moves five settings. |
| **Search behaviour** — a state machine over a last-known place, not a destination | `core/search.nim`. Six phases: go to the place, look around, push past in the direction they went, guess the flank, sweep the uncertainty circle, give up. Stall detection moves it on when the navmesh will not. |
| **Last-known-position decay** | `EnemyView.uncertainty`, grown at an assumed walking pace since contact was lost and collapsed to zero on sight. It is what makes the search widen with age instead of pointing confidently at a stale dot. |
| **Suppression** — an accumulator with two thresholds, not a flag | `core/suppress.nim`. See below: the *sensor* is a bool, the model is ours — plus, where the damage hook takes, an exact per-hit step through `feed`'s `told` parameter. |
| **Aim discipline** — a bot does not fire until its aim has converged | A typed postfix on the game's own aim-readiness getter, read per bot per frame and used in `client/driver.nim` to withhold a shot the ladder ordered. It can only ever withhold; see section 5. |
| **Audibility** — sound kinds with ranges, attenuation, and imprecise localisation | `core/hearing.nim`. See below: the *events* are derived, not received. |
| **Visibility / acquisition** — the difference between a clear line and a bot that has noticed | `core/vision.nim`. See below. |
| **Flanking** | `core/flank.nim` + `cdFlank`. See below. |
| **Squad decisions** — help, regroup, spread out, hold, suppress, surround, bounding retreat | `core/squad.nim` + `squadLayer`. See below. |
| **Cover *usage*** — scoring, dwell hysteresis, path-failure counting, in/near/far banding | `core/cover.nim`, fully implemented and tested, and no longer unreachable: `core/probe.nim` plans a sample and folds its answers into a `CoverSet`, `client/coverprobe.nim` casts the rays for it on Unity's thread. Whether a *raid* produces points depends on two names and one host fact, all three asked rather than assumed — see the sensor table below. |
| **Extraction** | `cdExtract`, latched. The decision is expressible; the destination is not. See the refusals. |
| **Grenade avoidance** | `cdAvoidGrenade`, fed by a world-level grenade sample. Three guessed names — the only place in the mod where a decision depends on a guess it cannot work around. |
| **Brain forcing and per-map difficulty skew** (SAIN's server mod) | `server/serverside.nim`; both are database writes. The skew works, and this cell used to call both of them working: **the brain forcing reaches nothing here.** Neither the emulator's database nor the 39 MiB import carries a top-level `configs` object, it is SPT's own bot generator that reads those paths, and there is not one on this server — the mod says so in the log. The skew is neutralised on every location including the ones a mod that loads *after* this one creates — a sweep at load plus an `aowlspt.locations.changed` subscription and an `aowlspt.locations.hello` handshake, because the host's load order is a directory walk and a fix that depended on it would break the next time somebody added a mod. `/sain/status` reports which maps were actually reached. |

Five of those are worth explaining, because in each case SAIN gets the input
from a subscription or a patch that does not exist post-1.0, and this port gets
the same behaviour from arithmetic on numbers it can already read. That is the
central bet of the rewrite: **a model that is ours and merely actuates through
a few reliable calls will survive a client patch that a model leaning on twenty
guessed member names will not.**

**Hearing.** SAIN subscribes to `Player.OnMakingShot` and BSG's audio events. A
native mod cannot hand a managed delegate to a C# event and there is no Harmony
to patch the raise site — so the honest port of that file is "nothing", and the
previous version of this mod indeed hard-coded `heardThisTick = false`, which
made every decision downstream of it dead. But a footstep is not private
information: it is a *consequence* of a position changing over time, and this
mod already reads the player's position every tick for its own scheduler. So
`hearing.motionSound` derives the sound, `hearing.listen` decides whether a
given bot heard it — with its own acuity and its own localisation error — and
the last-known place, the search, the freeze and the `EHeardFromPeaceBehavior`
personality split all come alive. What it cannot derive is a sound with no
observable cause in this mod's view: doors, looting, a bot's own gunfire heard
by a third bot. Those stay silent, which decays to "no contact" — the correct
behaviour for a sense that is absent rather than lying.

**Acquisition.** The engine answers "is there a clear line", and treating that
answer as the bot's own knowledge is the single most common way bot AI is made
unfair: the frame you clear a doorway, thirty bots know. `core/vision.nim`
separates them. Awareness ramps at a rate set by distance, angle off centre,
whether the target is moving or sprinting, and difficulty; crossing the engage
threshold starts a one-shot reaction delay; losing the line bleeds awareness
away slowly. Two thresholds, never allowed to meet. `mayEngage` replaces the
raw `visible` flag throughout the ladder, and there is a rung —
`drNotYetAcquired` — for the half second in which a bot has been seen and has
not yet processed it.

**Suppression.** The game exposes `BotMemory.IsUnderFire`, a bool. Mapping true
to 1.0 (what this mod used to do) makes both thresholds in `settings.nim`
meaningless: a bot is never merely suppressed, only pinned, and it un-pins on
the frame the flag clears. `core/suppress.nim` integrates the bool over time,
adds a step for every hit, and holds the pinned state for a minimum dwell.

**Where the "every hit" comes from has changed, and the old sentence was
weaker than it read.** It said a health drop is "the only damage signal
available, and an exact one". The signal is exact; the *reading* of it was not.
A health drop is inferred from two samples taken at the decision rate, and on
an eight-bot budget a thirty-bot raid samples each bot every four ticks — so a
burst and the flinch it should cause could be 400 ms apart, and two hits with a
regeneration between them netted out to less than either. The damage postfix in
section 5 removes both errors by being told each hit as it lands; `feed`'s
`told` parameter is where it goes, folded into the *same* rise as the health
delta so that the numbers in `settings.nim` mean one thing on either host. It
was a separate `feedHit` first, and the self-test caught what that cost: `feed`
skips its decay on any tick where something raised the level, so a hit credited
outside it was worth one decay step less than the same hit inferred from
health. The
delta is still there, still credited for whatever the hook did not account for,
and is still the whole reading on a build where none of the candidate damage
methods exists.

The one thing it does not model is a near miss that hit nobody, which genuinely
needs the projectile callback; bots here are therefore slightly less
suppressible than SAIN's.

**Squads.** SAIN enumerates `BotOwner.BotsGroup`. Doing that here means five
guessed member names on a class nobody has seen, and the previous version
instead left `SquadView` a stub of one member — which made all twelve
`SquadDecision` values unreachable. But **this mod already tracks every bot in
the raid**, with a position, a role, a health reading and a current enemy,
because that is what the scheduler needs. So the squad view is a query over
that table. One binding improves it and it is the cheapest possible one: the
*pointer* of `BotsGroup`, compared for equality and never dereferenced, which
partitions the table into real BSG groups. If even that refuses, the fallback
is "same faction, within `squadCohesionRadius`" — not the same thing as a BSG
group, and this file does not pretend it is, but it is the quantity every one
of those decisions is actually asking about.

**Flanking.** SAIN flanks by comparing navmesh path lengths to points its cover
finder produced. Neither is reachable. The arc is: step off the bearing by a
fixed radius on a chosen side and converge. The side is (a) the side the bot is
already displaced towards, so the flank does not re-cross the ground it just
crossed, and (b) *away from the nearest squadmate*, so two bots of a squad go
opposite ways. That second rule is the cheapest squad tactic in the mod — a
pincer that falls out of one dot product with no communication at all. The side
is latched for a cooldown, because a flank that re-decides its side each tick is
a bot walking on the spot.

### Blocked on a sensor the mod cannot reach yet

These decisions are implemented and tested and simply never fire, because the
input that would trigger them is always at its default. Each is a missing
*sensor*, not a missing behaviour — the day the sensor lands, the behaviour is
already there.

**Cover points used to be the first row of this table and are not any more.**
The sensor is built; whether it produces anything in a raid now depends on two
Unity names and one host fact rather than on a capability nobody had. That is a
different kind of unknown and it has its own section below rather than a row
here. What has not changed is that no build has yet answered any of the three
in the affirmative, so the four cover decisions have still never fired — see
"The cover sensor, which is the one that moved".

| What | Why it is blocked | What would unblock it |
|---|---|---|
| **Bleeds and fractures** (`saSurgery`, and `saFirstAid` for a light bleed) | Reading them means walking the health controller's effect collection, which is a generic instantiation `findClass` cannot name and of which no instance is ever in hand to bind from. | An ABI or `fast` facility for reaching a generic instantiation from a field rather than from an instance. Guessing "bleeding" from a falling health value was considered and rejected: it would fire the first-aid ladder on the wrong cause. |
| **`EnemyStatus.EnemyLookAtMe`** (`lookingAtUs`, which gates `shallStandAndShoot` and feeds suppression) | Needs the enemy's own forward vector tested against us — a second `Vector3` read per enemy per tick, on a member whose name is a guess. | Cheap to add if the name proves right; deliberately not guessed at yet, because a wrong guess here silently makes bots stand in the open. |
| **`firedAtUsThisTick`** per enemy | `IsUnderFire` is per bot, not per enemy, so the mod knows it is being shot at but not by whom. | **Still blocked, and the damage hook does not unblock it** — worth saying, because it looks as though it should. The hook knows the victim exactly (`this`), and the aggressor is inside the `DamageInfo`, which is a value type wider than a register: the typed frame reports it as `akBigValue`, an address of a copy whose layout the host cannot read. Reaching the aggressor means field offsets on a struct nobody has dumped, which is the guess this mod does not make. So: an enemy-level flag from the game, or the projectile callback. Suppression works off the per-bot flag and now off exact hits; only enemy *ranking* loses a little. |
| **A real path distance** | `pathDistance` falls back to straight-line distance. A navmesh path query is a Unity call. | **Not the same one-line change the cover row turned out to be, and this row used to imply it was.** The thread is no longer the blocker — `client/coverprobe.nim` runs on Unity's now — but `NavMesh.CalculatePath` needs a `NavMeshPath` *object*, which means constructing a managed instance from a native mod and then reading a corner array out of it. That is a different kind of bet from calling a static with value arguments, which is all the cover sampler does, and it is not made. Every band comparison still reads `pathDistance` and still gets a straight line. |
| **Extraction destination** | Exfiltration points come off a controller with no binding here. | A binding for it. Meanwhile `cdExtract` fires correctly and moves the bot away from every threat it knows about — the observable half of extracting, and named as exactly that in `flank.extractDirection`. |
| **Grenade fuse** | `secondsToDetonation` is always 0. The ladder only reads `active` and `distance`, so nothing depends on it. | A binding, or nothing: the decision does not need it. |

### The cover sensor, which is the one that moved

Four decisions — `cdSeekCover`, `cdShiftCover`, `cdHoldInCover`, and every rung
that reads `inCoverStatus` — were written, tested by the checks below, and had
never fired in any build, because nothing produced a cover position to move to.
That is no longer structural. It is now a question about two names and one host
fact, and all three are asked rather than assumed.

**The split, which is the design.** A raycast must run on Unity's thread; a
decision must not depend on when one comes back. So:

| | where | thread |
|---|---|---|
| plan eight candidate stances and the two rays that settle each | `core/probe.planProbe` | the host's |
| cast the rays, sample the navmesh, write bools into an array | `client/coverprobe.runSample`, inside an `onMainThread` job | **Unity's** |
| merge the answers into the bot's `CoverSet` | `core/probe.ingest` | the host's, next tick |
| score, band, choose with dwell hysteresis | `core/cover.nim`, unchanged | the host's, per decision |

The decision layer never waits for a sample and never learns that one is in
flight. It reads the set it has, which between samples is what it did anyway —
cover is geometry and geometry does not move.

**Two rays per candidate, not a collider query.** SAIN's `CoverFinder` calls
`Physics.OverlapSphere` and raycasts each collider it returns; that is a
managed array per sample and a second guessed shape. The chest ray asks "does
this place break the enemy's line", which is the whole of `blocksEnemy`. The
stand ray asks "and is the thing that stopped it full height", which is SAIN's
hard/soft split — obtained from one extra ray rather than from a collider's
bounds, which would be a layout read on a type nobody has dumped. An
obstruction that stops the stand ray and not the chest ray is an overhang and
is **not** cover; reading it as cover is how bots end up standing under
gantries.

Both rays stop half a metre short of the target. A ray allowed to reach the
enemy hits the enemy's own collider and reports "blocked" from every point on
the map — a plausible number rather than a refusal, which is the failure shape
this whole file is arranged against.

**What refuses, and what each refusal costs.**

| | if it refuses |
|---|---|
| `UnityEngine.Physics::Raycast(Vector3, Vector3, System.Single) -> Boolean` | there is no cover sensor. The set stays empty, `inCoverStatus` stays `csFarFromCover`, and the four decisions are exactly as unreachable as they were — `moveTargetFor` goes on substituting "away from the enemy" for "to cover". |
| `UnityEngine.AI.NavMesh::SamplePosition(Vector3, out NavMeshHit, Single, Int32) -> Boolean` | the sensor still works, on the rays alone. Candidates are no longer filtered by whether a bot can stand there, so a bot can be sent at a place inside a wall — where `CoverPoint.pathFailures` catches it after three tries, which is the existing answer to exactly this and is worse than not going. |

The name check is **exact and is the point**. `il2cpp_class_get_method_from_name`
matches on name and arity, and `UnityEngine.Physics` carries three
three-argument `Raycast` overloads. Resolving one of the others and calling it
with a `Vector3` where it wants a `Ray` does not crash: it reads adjacent stack
and answers a plausible bool. So the declared parameter types are read out of
the runtime's metadata and compared, and a mismatch refuses **by name, with the
signature the runtime reported**. What that costs is stated too: the C API
reachable from here cannot enumerate overloads, so "the first three-argument
`Raycast` is not the one meant" is a refusal rather than a search. On a build
where the overload order differs, this sensor is off and says so.

**Nothing is read out of a `NavMeshHit`.** The `out` parameter is a buffer this
mod hands over, sized by asking the runtime how big the struct is, zeroed, and
never read — only the method's `bool` return is used. Reading
`NavMeshHit.position` would mean a field offset inside a value type, which is
the same refusal `sain.nim` makes about `DamageInfo`. The consequence is small
and stated: a candidate is accepted where it was proposed rather than snapped
to the nearest navmesh point.

**The third thing that has to be true is the thread**, and the host answers it
outright. `call("aowlspt.host::main_thread")` reports whether the drain hook
has *actually fired*, not whether it was installed, and `client/mainthread.nim`
is that question cached and rate-limited. Until it answers yes, **no sample is
ever posted** — the counter for how many posts were held back is in the stats
line, so "not yet" and "never" are distinguishable. `perFrame` is read as a
tri-state, absent meaning unknown rather than false, for the reason
`mods/perf` gives: a drain that fires many times a frame is still the right
thread, and its firing count is still not a frame rate.

**And `bridge.apply` has now moved onto it too.** That paragraph used to end
here saying the five driving calls were still made from the host's thread and
that the row stayed open. It is the next section.

### The driving calls, which is the row that was open

SAIN decides and then has to make the bot *do* it. Five calls carry every
decision in the ladder into the game: `Mover.GoToPoint`, `Mover.Sprint`,
`Steering.LookToPoint`, `ShootData.Shoot`, and the four self-actions on the
medicine and weapon components — `Reload.TryReload`,
`FirstAid.TryApplyToCurrentPart`, `Stimulators.TryApply` and
`SurgicalKit.TryApplyToCurrentPart`, which the table below has always listed as
four. Two things were wrong with them and they were
wrong in different ways.

**The first was that nothing checked what they were.** `GoToPoint` is resolved
by *arity* — one argument, then two, three, four, five, six, whichever the
build has — and `il2cpp_class_get_method_from_name` matches on name and arity
and nothing else. That is exactly the trap the cover sensor refuses on for
`Physics::Raycast`, and until now the calls that drive were the one place in
the mod it was not guarded. `Sprint` was worse: `lazyAs("Sprint", [fkBool],
fkVoid)` *stated* the signature, and `resolveOn` skips the runtime's declared
types entirely when the caller supplies kinds — so on a build where `Sprint`
takes a float, a bool went into a general-purpose register and the speed was
read out of whatever was in XMM. Neither failure crashes. Both drive the bot.

`core/sig.nim` is the rule and `live.resolveOn` is where it is applied, before
anything is bound:

| call | what must be declared | if it is not |
|---|---|---|
| `Mover.GoToPoint(Vector3, ...)` | first parameter exactly `UnityEngine.Vector3`; no trailing `double`, by-reference parameter, or second by-pointer value type | the bot is never told where to go. It still decides, still searches, still picks cover — and stands still while it does |
| `Steering.LookToPoint(Vector3, ...)` | the same | the bot never turns to face anything |
| `Mover.Sprint(Boolean)` | exactly one parameter, exactly `System.Boolean` | the bot moves at whatever speed the game last set: every sprint is a walk and every walk after a sprint keeps sprinting |
| `ShootData.Shoot()`, `Mover.Stop()` | no parameters at all | that action is never performed; the ladder is unchanged |
| `Reload.TryReload()`, `FirstAid.TryApplyToCurrentPart()`, `Stimulators.TryApply()`, `SurgicalKit.TryApplyToCurrentPart()` | no parameters at all | that self-action never happens; the decision still fires |

The **return** type is deliberately not gated, and that is a decision rather
than an omission: every one of these call sites discards what comes back, and
`resolveOn` already drops a member whose return it cannot classify onto
`il2cpp_runtime_invoke`, which boxes correctly whatever it is. Gating the
return would refuse builds that work.

Half the rule is arithmetic over strings and half is a measurement. What
`core/sig.nim` can decide from a declared *name* — a wrong first parameter, a
wrong arity, a `double`, a by-reference parameter, a second Unity value type --
it decides, and that half is proved by twenty checks with no runtime involved.
What it cannot is whether some EFT struct in a trailing slot is wide enough to
travel by hidden pointer; `live.byPointerSize` measures that against the
runtime and refuses on the same terms. A refusal names the member, quotes the
signature the runtime reported, and says what the bot does instead.

**The second was the thread, and it is the row `README.md` has carried
longest.** `Mover.GoToPoint` ends in a `NavMeshAgent`; `Steering.LookToPoint`
ends in writing a `Transform`. Unity checks the calling thread across most of
that surface, so this was never "unknown, probably fine" — it was a known
hazard that had never been executed, and those two read identically in a log.

`client/bridge.nim` now queues an order instead. The shape is the cover
sampler's, with three differences that all come from this being a *command*
rather than a sample:

| | cover sample | driving order |
|---|---|---|
| in flight | one, rationed to 10 a second for the raid | up to 32, one job per tick draining all of them |
| addressed by | a bot id, matched after the fact | the bot's IL2CPP GC handle, resolved on the game's thread |
| when it is late | nothing: geometry does not move | dropped past 350 ms. A destination is about where the bot *was*, and a backed-up queue would steer bots at where their enemies used to be |

One producer (the host's thread, in `driver.tickBot`), one consumer (Unity's,
in `driveJob`). The producer writes a slot and *then* advances the write index;
the consumer reads strictly below it and then advances the read index; neither
index is written by both. A full ring **drops and counts** rather than blocking
the decision thread, and a dropped order deliberately does not latch
`lastAppliedCombat` — so the bot is restated next tick instead of standing on
an order the game never heard.

**What happens when the host has no drain is a switch, not an assumption.**
`driveFromHostThread` in `config.json`, default **true**, makes the five calls
inline from the host's thread exactly as this mod did before the queue existed.
The safe direction is off — and off means bots decide and never move, which on
a host that predates the per-frame drain is the whole mod doing nothing
visible. The default is therefore the old behaviour rather than the safe one,
and `driveStats()` says which path a session actually took, counted, so a log
is enough to tell them apart afterwards.

**What is still not claimed.** That the calls reach Unity correctly. Nothing in
this repo has ever executed one. What has changed is that they are now made
from the thread Unity requires *when the host can confirm one*, that they are
made only against a signature the runtime agreed to, and that every other
outcome is named and counted rather than silent.

#### What a raid would be the first to disprove

This section is the newest thing in the file and therefore the least tested by
anything real. It covers the two sensors that call the engine — the cover
sampler and, now, the driving calls — in descending order of how likely a raid
is to embarrass them:

1. **The driving calls are refused by their own gate.** Everything a decision
   *does* now runs through `core/sig.checkDrive`, and every one of the nine
   members it guards is a name from the pre-1.0 C# surface. A build whose
   one-argument `GoToPoint` takes something other than a `Vector3`, or whose
   `Sprint` takes a float, produces a bot that thinks correctly and stands
   still — named in the log by member, with the signature the runtime
   reported and the consequence spelled out. That is the designed outcome and
   not the hoped-for one, and it is first on this list because it is the
   newest and because it is the whole visible behaviour of the mod.
2. **The calls reach Unity's thread and still do not work.** The queue puts
   them on the right thread when the host confirms one; it says nothing about
   whether `GoToPoint` on a live `BotOwner.Mover` moves a post-1.0 bot at all.
   BSG may drive movement through something this mod has never heard of. The
   symptom would be a log full of successful calls and bots that ignore them,
   and there is no way to tell that from here.
3. **The host's drain never fires, and the default takes the old path.**
   `driveFromHostThread` defaults to true, so on such a host the five calls
   are made from the host's own thread — which is what this mod always did
   and has never been shown safe. If Unity throws, it throws there. Setting it
   false is the safe answer and produces bots that do not move; the state line
   says which happened.
4. **The overload check refuses on BSG's build.** Everything above is
   conditional on `UnityEngine.Physics::Raycast`'s three-argument form being
   the `(origin, direction, maxDistance)` one, and on the runtime handing that
   one back first. If it does not, the log says so by name and the mod behaves
   exactly as it did before any of this — which is the outcome this design is
   arranged to make survivable, not the outcome it is betting on.
5. **The rays are cast against the wrong layers.** The three-argument overload
   uses Unity's `DefaultRaycastLayers`, so anything BSG puts on an excluded
   layer is invisible to it and anything on a trigger or a foliage layer stops
   it. A four-argument form with a layer mask exists and is *not* used, because
   picking a mask means knowing EFT's layer numbering, which nobody here does.
   The symptom would be cover points where there is only a bush, or none where
   there is a wall, and there is no way to tell those apart from here.
6. **Candidates are placed at the bot's own height.** There is no ground query
   in a sample, so a candidate on a slope or up a stair is proposed at the
   wrong `y` and the navmesh filter — if it bound — rejects it. In a
   multi-storey building this sensor finds less cover than there is. It never
   finds cover that is not there, which is the direction that matters.
7. **The engine cost is an estimate.** No raycast has ever been cast by this
   mod. The 240-calls-a-second ceiling is enforced; what one of those calls
   costs on BSG's client is not known, and the arithmetic in section 2 says so
   rather than quoting a stand-in's number as though it were this one.
8. **Only the primary enemy is sampled against.** A bot fighting two people
   gets cover from one of them. SAIN's finder has the same property and for the
   same reason; the difference is that this file says so.

### Out of reach post-1.0, and not coming back

| What | Why |
|---|---|
| **BigBrain layers** | A BepInEx library that inserts layers into BSG's brain. There is no BepInEx. This port has no counterpart and needs none: the cascade emits an enum triple and `actuationFor` turns it into intent, with no action objects to build or tear down. |
| **Harmony patches** (all ~90 of them) | No Harmony, and no general substitute. What the host offers is a native detour, and the sentence here used to add "which covers the one case this mod needs — bot activation". That undercounted, and by more each time the ABI grew: this mod now runs four detours — bot activation and death on `hookArgs`, and the two postfixes of section 5 on the typed frame. Four of ninety is still not a port of SAIN's patch set, and the ones that remain out are out for the reasons in the other rows of this table rather than for want of a detour. |
| **The F6 settings GUI and the Blazor preset editor** | Both are C# UI. Reproducing them would be writing a GUI, not porting bot AI. The resolved preset is served as JSON on `/sain/preset` instead, which is what the editor was reading. |
| **Voice lines and taunts** | Needs the voice API on the main thread, and is cosmetic. |
| **Per-limb aiming and the scatter model** | Rewrites BSG's aiming component wholesale, which needs to run inside the aim update on the main thread. |
| **Door breaching** | Interaction API on the main thread. |
| **Bot-vs-bot hearing** | The hearing model derives sound from motion, and the mod only samples the *human's* motion each tick. Sampling every bot's would make the raid-level pass O(bots) in positions read from the game rather than from the mod's own cache. Reachable in principle, deliberately not done: it would double the per-tick game reads to make bots hear each other, which no player observes. |

---

## 2. Cost

Measured every run by the self-test, on the same clock (`fast.perfCounter`) the
bindings report their own binding cost on. It moves by a few nanoseconds between
runs (35 on three consecutive runs here, 37-43 before the `sqrt0` fix below);
it is printed whether or not it is within budget — so a regression is visible in a diff of two logs even when it
does not trip the gate.

```
sain: decision cost 35 ns/bot/decision (20000 decisions in 709 us)
sain:   280 ns/frame at the budget of 8 bots/tick -- constant in the raid's population
sain:   1050 ns to reconsider all 30 bots of a full raid, spread over 4 frames
sain: cover sample (plan + ingest) 3525 ns, pure, on the host's thread
sain:   10 samples/s for the whole raid, so one frame in 6 at 60 fps pays 3525 ns
        and the rest pay nothing -- 587 ns/frame averaged
sain:   that is 211 parts in a million of a 16.67 ms frame on the frame it lands,
        and the same at forty bots as at eight
sain: a bound bool call costs 13 ns here; the death poll was two of them per bot
      per decision, so hooking death removes about 26 ns/bot and 208 ns/frame at
      the budget of 8 bots/tick
```

**The decision figure moved down, and not because the decision changed.**
It was 37-39 ns and is 35, and the cause is one function: `core/vec.sqrt0` ran
twenty-four Newton iterations where six reach the limit of a double. It did
that because its seed came from a doubling loop entered only when `v > 1`, so a
small input started a factor of `1/sqrt(v)` away, overshot on the first step and
then converged *linearly* for a dozen steps before the quadratic part began.
Twenty-four was honest cover for that and the cover was the wrong fix.
Bracketing the seed from both sides puts it within a factor of two of the
answer for every input, which bounds the initial relative error at 1, and eight
steps is then margin rather than need. The cover sampler is what found it —
thirty square roots a sample made it six microseconds — and every distance in
the mod got cheaper on the way past.

**The first number did not move when the death poll was removed, and it should
not have.** It measures the decision — pure logic over a struct, no game calls
in it at all — so a game read leaving the per-bot path cannot show up in it.
Reporting it as though it had would be the more flattering answer and the wrong
one.

What *did* move is measured separately, on the same runtime, in the same run.
The stand-in carries an instance method with no arguments returning a bool —
the exact shape of `get_IsAlive` — so timing 200,000 of them measures the thing
that was removed on this machine. **14 ns**, not the 3.47 ns `docs/PERF.md`
quotes for a raw bound call (this said 6.25, which is not a figure in that file), because the mod's path is `LazyCall.callBoolOn`:
an `il2cpp_object_get_class` and a pointer compare to confirm the binding still
matches this object's class, and then the call. That is the honest per-call
figure for this mod, and quoting the raw one would understate what was saved.

So: the death poll was 28 ns per bot per decision against ~40 ns for the entire
decision. **It cost about two thirds of what deciding cost**, for a fact that
changes once in a bot's life, and it is gone on any host at ABI revision 3.

### What the cover sampler costs, and what it is not allowed to cost

Two halves, measured separately, because only one of them can be measured here
at all.

**The pure half** — planning eight candidates and folding eight answers back
into a bot's set — is about 3500 ns (3470-3745 observed over three runs), on
the host's thread, gated at 20000 ns by `BudgetNsPerSample`. That ratio is five rather than the decision gate's forty,
and deliberately: this is a bounded loop of floating-point arithmetic with no
dispatch and no data-dependent branching, so it varies far less between
machines than a cascade of comparisons does. Five still catches what a gate is
for — an allocation in the ingest, a scan that grew tenfold, a square root put
back on a path one was taken off.

**The rate is the budget, and the rate contains no bot count.** One sample is
in flight at a time and one is posted at most every 100 ms, for the *raid*.
That is the whole rationing, and its important property is what it is not
proportional to:

* one sample is at most 16 raycasts and 8 navmesh queries — and fewer in the
  common case, because a candidate whose chest ray is clear costs one ray and
  nothing else;
* at ten samples a second that is at most 240 engine calls a second, four a
  frame at 60 fps, arriving in bursts of 24 on one frame in six;
* **at forty bots those numbers are identical.** What a larger raid buys is
  refresh *latency* — a bot's set is re-sampled every four seconds in a
  forty-bot raid where every bot wants cover at once, against 800 ms at eight
  — which is the same trade the decision budget makes and is invisible for the
  same reason: geometry does not move in four seconds.

So: **211 parts in a million of a frame on the frame a sample lands, at eight
bots or at forty**, for the half that can be measured.

**The engine half has never been measured and this file will not pretend
otherwise.** `tests/mockil2cpp`'s `UnityEngine.Physics` carries two read-only
property getters and no `Raycast` at any arity — this used to say it had no
`UnityEngine.Physics` at all — so no raycast has ever been cast by this mod, and `client/coverprobe.nim`'s cost line says
"nothing measured: no sample has been taken" rather than quoting somebody
else's number. What can be said is the shape: the call goes through
`il2cpp_runtime_invoke` rather than a bound trampoline, because a static taking
two `Vector3`s by hidden pointer is not a shape `aowlspt/fast` expresses and
this mod does not assert a convention for a static it has never called. At the
boxed path's own measured ~1 µs plus whatever the engine's ray costs, 24 calls
is tens of microseconds on the frame a sample lands. That is an estimate, it is
labelled as one, and it is the first thing a raid would either confirm or
disprove.

### What driving costs, and the half of it that is not measured

Same split as the cover sampler and for the same reason: one half is pure and
one half is the engine.

```
sain: an actuation costs 11 ns to queue on the decision thread
sain:   the drain is the other half: 174 ns for a ring of up to 32 orders
        against a runtime where every handle answers null, so the five driving
        calls at the end of it have never been made and their cost is not
        measured
```

**11 ns is paid per *decision change*, not per bot per tick.** `tickBot` only
actuates when the combat decision changed or the destination moved more than
two metres after half a second, which in a working raid is a handful of orders
a second across every bot. Eleven nanoseconds times that is not a number worth
a second line.

**174 ns is the ring, not the driving.** Every handle in that measurement
resolves to null, because the stand-in has no bots, so what was timed is the
walk and the handle lookups with the five calls taken out. Quoting it as the
cost of driving would be the flattering answer. What a raid adds is one
`gc_handle_get_target` and two bound property calls per order to re-derive the
components, plus the calls themselves — and **that has never been measured**,
in those words, for the same reason no raycast has.

**The decision figure did not move, and should not have.** The gate runs once
per class at bind time and the post is outside the decision itself. 35 ns
before this work and 35 ns after, on three runs each.

Three things the *decision* number depends on, all of them enforced rather than
hoped for:

* **The per-frame cost is constant in the raid's population.** `driver.nim`
  considers `maxBotsPerTick` bots per tick in round-robin order. Thirty bots at
  a budget of eight means every bot is reconsidered within four ticks. A raid
  that spawns a second squad costs more *latency*, which is invisible and
  recoverable; it does not cost a frame spike.
* **Nothing on the per-decision path allocates.** This was not true until
  recently and the difference was 40% of the cost: `Decision.reason` was a
  `string` built by concatenation at the point of the check, `BotView.id` was a
  string copied out of the bot's record every tick, and `EnemyView.id` was a
  managed string read from the game every tick and copied again on every
  `primaryView`. All three are gone — the reason is an enum, and enemies are
  keyed on the pointer. `benchDecisions` is the check: the loop rotates through
  five bot states that between them reach the reflexes, the self layer, the
  squad layer and the deep end of the solo ladder.
* **The budget catches the failure that matters.** `BudgetNsPerDecision` is
  1500 ns, roughly forty times the measured cost, because this runs on whatever
  machine someone builds on and a gate tight enough to be a benchmark fails for
  reasons that are not the code. What it catches is a decision path that starts
  allocating, calls the game, or grows a loop over every bot — factor-of-ten
  regressions, not five-percent ones.

The reads are the real cost and they are what the budget rations. One bot's
decision is one `gc_handle_get_target`, two bound property calls to re-derive
its components, and roughly a dozen bound reads — see `client/bridge.nim` for
why one GC handle per bot beats eight.

### What the two postfixes cost

Both are timed **in the mod**, inside their own handlers, on `fast.perfCounter`
— the same clock everything else here is timed on — and both print the figure
next to the path that produced it, because a typed frame and a JSON payload are
forty-fold apart and a log that says only "armed" cannot be used afterwards to
say which a raid paid for.

```
sain: bot aim result -- armed by static RVA on Aiming::get_IsReady @0x1AD48C0, ...
sain:   measured 31 ns per firing over 512 of them, on this client's own clock
sain: damage -- armed on the typed path on EFT.Player::ApplyDamageInfo(...), ...
sain:   measured 31 ns per firing over 512 of them, on this client's own clock
```

**Against the stand-in neither line ever appears**, and that is worth being
plain about. `tests/mockil2cpp` has none of the six candidate method names, so
both hooks refuse — by name, with the reason, on no path — and both cost lines
say "nothing measured: the method never fired on this build". That is the same
position `mods/classicmovement`'s `tiltCostNs` is in.

What was measured, on this machine, is `onPlayerDamagedTyped` itself, driven
2000 times from inside this mod's own DLL against a stand-in method of the same
shape (an instance method taking one `System.Single`): **31 ns a firing**, with
the original still running — which is what a watching postfix has to do and
what separates it from a prefix that answered instead.

It was 79 ns first, and the difference is the one design note worth carrying
out of this. The handler originally scanned the frame's kinds per firing to
find the float parameter. Every frame accessor across the ABI is an ordinary
call rather than an inlined load (`docs/PERF.md` says why), so four `kindOf`
calls cost about thirty nanoseconds — more than the rest of the handler put
together. `armDamageHook` now settles which parameter carries the amount once,
out of the declared types it is already reading to check the signature, and the
handler reads that one index. Ask the shape once: the same rule the typed path
is built on, one level up.

The mechanism underneath both is measured by `tools/perfbench.nim` against the
stand-in (median of three, same machine):

| operation | ns/op | vs its JSON form |
|---|---:|---:|
| bound call, unpatched | 3.2 | — |
| postfix hook, JSON result and arguments | 1370 | — |
| **postfix hook, typed frame** | **25.6** | 53× |
| postfix hook, JSON + replacement | 1806 | — |
| **postfix hook, typed frame + replacement** | **38.2** | 47× |

Re-derived on 2026-08-19 by running `perfbench` here three times rather than by
copying a figure out of another document, which is how the numbers this table
used to carry (1132 and 1583) came to disagree with `docs/PERF.md`'s (1102 and
1525) with neither being wrong. **The two JSON rows are the only ones that
move.** Across the three runs they spanned 1318–1393 and 1797–1820 while the
typed rows held 25.15–25.74 and 37.50–38.28 — a JSON firing is two allocator
round trips and costs whatever the heap costs that minute, and a typed firing
allocates nothing. So quote the typed rows to two figures and the JSON rows as
"about 1.4 and 1.8 microseconds"; the ratio is the durable part, and it is
between forty and fifty times either way.

Add roughly ten to twenty nanoseconds for a handler crossing into a mod DLL,
where each frame accessor is an ordinary call rather than an inlined load —
`docs/PERF.md` explains why, and it is why the expected in-mod figures above
are in the forties rather than the twenties.

What that buys, at the rates these two actually fire:

* **The aim result is per bot per frame.** Forty bots at 60 fps is 2400
  firings a second: ~1.06 ms a frame on the JSON path against ~4 µs on the
  typed one. Six percent of a 60 fps budget for one bool, against a rounding
  error. That is why this hook is typed *or absent* — see section 5.
* **Damage is per hit**, not per bot per frame, and section 5 used to say
  otherwise. Zero on nearly every tick, and a dozen in the tick a magazine
  goes into a squad. 1.6 µs times zero is nothing; the cost is entirely a
  spike, arriving exactly when the frame is already the busiest it will be all
  raid. So that hook does fall back to the JSON payload on an older host, and
  says in its state line that it did.

Raid-level work, once per tick rather than once per bot: the ally table (O(live
bots), rebuilt in place into a sequence that only ever grows), the grenade
sample (one bound `get_Count` when the list is empty, which is nearly always),
and the human's position and derived footstep. The world scan that reconciles
the bot table runs at 2 Hz and is a reconciler — the spawn hook usually gets
there first.

---

## 3. Testing

`aowl run mods/sain` runs everything below with no game attached.

**124 checks over the decision layer**, in three kinds:

1. **Scenarios** — one `BotView` built by hand, one `decide`, one assertion.
2. **Model checks** — hearing, vision and suppression are functions of numbers
   *over time*, so they are driven over a sequence of ticks and the trajectory
   is asserted: that awareness rises with a line of sight and bleeds without
   one, that a sprint at 200 m is not heard while one at 20 m is, that a
   distant sound is localised worse than a near one, that suppression decays,
   that a Rat hears what a Wreckless misses.
3. **Flicker checks** — the ones a live test cannot do at all. A decision
   system that alternates between two states every tick is the classic bot-AI
   failure and it is *invisible* in a raid: the bot looks twitchy and nobody
   can say why. Each check sweeps one input back and forth across a threshold
   with noise on it for 400 decisions and counts how many times the decision
   changed. A cascade with working hysteresis changes a handful of times; one
   without changes on nearly every tick. Health, distance across the dogfight
   boundary, suppression across both of its thresholds, a bot sitting exactly
   on the dogfight latch, and a bot whose situation does not change at all.

Coverage by area: 22 ladder scenarios (including both new rungs and the
reason-text completeness check), 3 extract, 8 flank, 9 hearing, 14 vision,
10 suppression (three of them about the damage hook: that a hit told by it moves
the accumulator by exactly as much as the same hit inferred from health, that a
hit with no readable magnitude still registers, and that an empty damage event
is not a hit), 6 squad, 6 perception, 7 search, 3 cover scoring, 11 cover
sampling, 5 flicker, **20 driving signatures**. (These used to read 20 / 6 / 7 /
12 / 9 / 6 and summed to 114 against a stated total of 124; the total was the
right number and the breakdown had fallen behind it.)

**The twenty new ones are the driving-signature gate, both branches.** A gate
that refuses everything passes every "does it refuse?" assertion ever written,
and a gate that accepts everything passes every "does the real signature work?"
one — so each of the three shapes is asserted to accept exactly what
`bridge.apply` calls it with *and* to refuse each way it could plausibly be
wrong: the wrong first parameter, the wrong arity, a trailing `double`, a
by-reference parameter, a second `Vector3`, a `Quaternion`. Every refusal is
additionally asserted to carry a non-empty reason, because a refusal with no
reason is the failure mode the whole binding layer is written against. No
runtime is involved in any of them.

**The eleven new ones are the cover sampler, against synthetic geometry.** The
world they run in is a set of vertical cylinders, each with a height that says
which of the two rays it is tall enough to stop; a ray is blocked when its
ground track passes within a cylinder's radius. That is not an attempt at a
physics engine, it is a set of known answers, and it is enough to assert every
claim the sampler makes:

* the ring surrounds the bot at the two radii it is supposed to, and **no ray
  can reach the enemy** — the failure that would make every candidate on the
  map report as cover;
* an open field yields *no* points rather than bad ones, which is also the
  shape of a build where the raycast refused;
* a full-height cylinder becomes hard cover, the same cylinder waist-high
  becomes soft cover and **not** hard, and an overhang — stand ray blocked,
  chest ray clear — becomes nothing at all;
* a candidate the navmesh refuses is never proposed, and a build where the
  navmesh binding refused rejects nothing, which is what every other check
  above is implicitly asserting;
* forty samples of the same corner do not grow the point set, because every
  candidate merges into the point already standing for that place;
* a point nobody re-observes is forgotten and the point the bot is *using* is
  not — forgetting that one mid-approach is precisely how this could produce
  the oscillation the merge exists to prevent.

**And the two that matter, which are a pair.** A bot standing between two
equal-quality pillars, sampled 200 times while it jitters by centimetres and
the ring rotates, must not re-pick: every sample proposes eight *new*
positions, none of them exactly a position from the sample before, so an ingest
that appended rather than merged would hand `choose` a fresh set each tick and
the bot would spend the fight running back and forth in the open. The check
counts *material* changes — the chosen point moving further than the merge
distance — and asserts at most three in 200 samples. The other half is the
opposite failure and is just as wrong: when one of the two pillars stops
blocking, the bot **must** let go and take the other. A hysteresis that never
releases is what a merge-in-place ingest could easily have produced, and
without the second check the first one would have passed for it.

**The typed frame is classified against the stand-in, and until recently was
not.** The kinds a typed hook reads by are computed once at registration, out
of `il2cpp_method_get_param` and the host's `shapeOfType` — which goes through
`il2cpp_class_from_il2cpp_type`. The mock spelled that entry point
`il2cpp_class_from_type`, which is not the name `GameAssembly.dll` exports, so
every host path that classifies a declared type silently answered "the runtime
could not name a class for it" — and a test written to prove such a path passed,
because the refusal had the same shape as a pass. It answers the exported name
now. Both hooks in section 5 depend on that: `akBigValue` for a `DamageInfo`
and `akFloat` for a damage amount are classifications, and against the old mock
neither could have been made at all.

**The binding half** is exercised against `tests/mockil2cpp`, a runtime
implementing the same C API over a small type universe. `aowl test` and `aowl
run` build it and hand it over in `AOWLSPT_SELFTEST_RUNTIME`; `selfTestRuntime`
in `config.json` does the same for a runtime of your own, as an **absolute**
path only — that key ships into installs, so a relative one is refused. Three
things are checked there, and they are the three that matter about a file whose
whole content is names from a build nobody has seen:

* **A wrong name refuses, carrying a reason, on no path, without crashing.**
  The stand-in has almost none of EFT's members, which makes it the ideal
  adversary: the assertion is that every refusal is honest, and `tally().silent`
  must be zero.
* **The Win64 hidden-pointer rule**, exhaustively, both branches, with no
  runtime involved — so a `Vector3` provably takes the shaped path and a
  `float` provably does not.
* **The shaped call itself, end to end.** `tryShaped` asserts a calling
  convention through `fast.bindRaw`, and a wrong slot count there does not
  crash: it reads an uninitialised register and hands the game a plausible
  number. The stand-in now carries a `UnityEngine.Vector3` and a
  `EFT.Player::get_Position` with a real compiled function of the real shape,
  so the mod reads a position it can check against a value it knows. It also
  carries a `System.Double`, which is half of how `headerBytes` calibrates the
  runtime's value-type size convention — without it the calibration silently
  fell back to a constant that is right for `GameAssembly.dll` and wrong for
  the stand-in, and every shaped binding was refused for a bad size while the
  log claimed the shape had been checked.

**And the gate is proved *wired*, which is a separate claim from the rule.**
`core/selftest.nim` proves that `checkDrive` decides correctly; nothing there
proves that `live.resolveOn` ever calls it, and a gate nobody calls refuses
nothing while every refusal test still passes. Pointing it at `GoToPoint`
against the stand-in would prove exactly that — the binding would refuse for
want of the *name*, which is this project's most common bug species wearing a
new hat. So it is pointed at members the stand-in already carries, one per
shape, in both directions, and two of them are the exact traps the gate was
written for:

* `EFT.Player::SetFlag(System.Boolean)` gated as `Sprint(bool)` **binds** —
  the shape that must work.
* `EFT.Player::Scale(System.Single)` gated as `Sprint(bool)` **refuses**: a
  float where a bool goes, which is the state `Mover.Sprint` was in before this
  gate existed.
* `EFT.Player::Damage(System.Single)` gated as `GoToPoint(Vector3)`
  **refuses**: the arity matches and the first parameter does not, which is
  precisely what `il2cpp_class_get_method_from_name` hands back.
* `Scale` gated as a no-argument call **refuses**, and `get_IsAI` gated as one
  binds.

Nothing was added to `tests/mockil2cpp` for any of that; it already carried
every signature needed to make both branches real.

**And the order ring is exercised, on the counters rather than on the calls.**
With no runtime bound every handle resolves to null and no driving call is
made — so "no calls were made" would pass whether or not the drain ran at all.
What is asserted instead is that the drain *reached and classified* every
order: thirty-two posted, thirty-two counted as belonging to a bot that could
not be resolved, and that counter can only be advanced by code that walked the
ring. Plus that the thirty-third post is refused and counted rather than
overwriting a slot, that an order a second old is dropped as stale rather than
executed, and that a bot with no handle is never queued at all.

Additions to `tests/mockil2cpp` are appended to the end of `g_playerMethods`
and to the class arrays, whose lengths are computed by `MOCK_N`; no existing
row moved and no existing behaviour changed. `perfbench --check` still passes.

One of those additions found a bug in the stand-in itself, and it is worth
recording how. `get_IsAI` was first added with `native` left NULL, which is how
most of the mock's rows are written — and for those, `methodPointer` is the
*invoker*, taking `(obj, void** params)` and returning a boxed value. That is
harmless for `il2cpp_runtime_invoke` and wrong for a bound call: the trampoline
expects a bool in the return register and gets the address of a box, whose low
byte is nonzero fifteen times in sixteen because the allocator aligns. Calling
it once passes. The timing loop above calls it 200,000 times and found 6.25% of
them false. The row now carries a real compiled function, like `get_Position`
does, so the bound-call path is measuring a bool rather than a pointer.

---

## 4. Every refusal that remains

In the log, once, from `report()`. In the code, as a defaulted value chosen so
that the decision core behaves as though the thing it could not read is not a
problem — full health, a full magazine, a ready weapon, no suppression. A bot
whose magazine count cannot be read should not spend the raid reloading.

| Refusal | Consequence |
|---|---|
| Any `EFT.` member name that post-1.0 renamed | That one read defaults; every other read is unaffected. Named in the binding report as `MISSING` with the class it was looked for on. |
| `GameWorld.Grenades` (three guessed names: the getter, the list, the position) | `cdAvoidGrenade` never fires. Everything else is unaffected — the sample is raid-level and costs one refused call per tick. |
| `BotOwner.BotsGroup` | Squads fall back to faction + proximity. Every squad decision still works. |
| `BotOwner.AimingManager` / `AimingManager.CurrentAiming` (identity only) | Either hop refusing leaves the aim postfix's readings unattributable, so the aim gate never engages and bots shoot when the ladder says so — which is what they did before the hook existed. |
| Any of the three candidate aim members, or the three candidate damage members | Named individually in the log with the signature the runtime reported. The aim gate stays off; suppression falls back to the health delta. Both are stated in the effect's own state line rather than inferred from silence. |
| `UnityEngine.Physics::Raycast` — **now attempted**, by exact signature | No cover points. The cover *logic* runs on an empty set and the ladder falls through to the rungs below it; `moveTargetFor` substitutes "away from the enemy" for "to cover" — which is what it does on every build so far, because `tests/mockil2cpp`'s `UnityEngine.Physics` has no `Raycast` at any arity and BSG's client has never been asked. The refusal names the signature the runtime reported. |
| `UnityEngine.AI.NavMesh::SamplePosition` — **now attempted**, by exact signature | Cover points are still produced, on the rays alone, and are no longer filtered by whether a bot can stand where one was proposed. A bot can then be sent at a place inside a wall, where `pathFailures` drops the point after three tries. Worse than having it; better than having no cover. |
| `NavMesh::CalculatePath` — still not attempted | `pathDistance` stays a straight line. This needs a managed `NavMeshPath` instance constructed from a native mod and a corner array read back out of it, which is a different bet from calling a static with value arguments. |
| Unity's main thread not confirmed by the host | **No cover sample is ever posted.** Not a refusal and not an error: `call("aowlspt.host::main_thread")` reports `bound` only once the drain has actually fired, so early in a session this is "not yet". The posts held back are counted in the stats line so that "not yet" and "never" can be told apart. |
| The health controller's effect collection — not attempted at all | No bleeds, no fractures. `saSurgery` never fires; `saFirstAid` fires on health only. |
| The exfiltration controller — not attempted at all | `cdExtract` moves away from known threats instead of to an exit. |
| Any driving call whose declared signature is not the one this mod calls it with | **Now checked, by exact declared parameter type.** Named in the log as `REFUSED` with the signature the runtime reported and the consequence in plain words. That one channel is not driven at all — no call is made rather than a wrong one — and every other channel is unaffected: a refused `Sprint` still leaves a bot that walks to cover, a refused `GoToPoint` leaves a bot that turns and shoots and does not move. |
| Unity's main thread, for the *driving* calls | **This row was open and is now closed as far as it can be without the client.** The orders are queued on the host's thread and executed inside `onMainThread`, so on a host whose per-frame drain has fired the five calls are made from Unity's own thread. What is *not* claimed is that they then work: nothing in this repo has ever executed one, and no line here should be read as saying otherwise. |
| The host's per-frame drain never fires, and `driveFromHostThread` is true | The five calls are made from the host's thread, which is what this mod did before the queue existed and has never been shown safe or unsafe. It is the **default**, because the alternative is bots that decide and never move — and the state line says which path the session took, counted, so a log distinguishes them. |
| The host's per-frame drain never fires, and `driveFromHostThread` is false | No bot is driven. Withheld actuations are counted and the state line says so in those words. The safe direction, and the visibly broken one. |
| The order ring is full (32 outstanding) | The order is dropped and counted, and `lastAppliedCombat` is deliberately *not* latched, so the next tick restates rather than leaving the bot standing on an order the game never heard. A ring this deep filling means the drain is not running. |
| An order older than 350 ms at drain time | Dropped and counted. A destination is about where the bot was when the decision was made; executing a second-old order steers bots at where their enemies used to be. |
| A host older than ABI revision 4 | The aim postfix is not installed at all, and says so with the arithmetic: a JSON postfix at ~443 ns per bot per frame is 1.06 ms a frame at forty bots, which is a frame tax for one bool. The damage postfix falls back to the JSON payload, because a hit is an event rather than a per-frame cost. |
| A host older than ABI revision 3, or one with no managed heap | Both of the conversions in section 5's first half fall back to what this mod did before it: the death poll stays on (two bound calls per bot per decision) and the spawn hook registers by id while the world scan attaches the handle up to 500 ms later. `livePointersReady()` is checked before the death hook is installed at all, because a hook whose `thisPointer` always answers zero costs a payload per death and identifies nobody — strictly worse than the poll. |
| None of `Player::OnDead` / `Kill` / `OnBeenKilledByAggressor` patches | The same fallback, named in the log with `lastError()`. |

---

## 5. What ABI revisions 3 and 4 changed here

`pointerOf` / `thisPointer` turn a hook's handle into an `Il2CppPtr` in 9 ns,
against ~1068 ns for the boxed property read they replace. Both of the things
this mod had written as local workarounds are gone.

(On the typed path this step does not exist at all: `selfPointer` is the
register the method was entered with, and no handle is taken out to describe
it. The revision-3 route below is what the two `hookArgs` hooks still use, and
what the damage hook's JSON fallback uses.)

**Death is hooked, not polled.** `hookArgs` used to report a method's declared
arguments and not the instance it was called on, so a detour on `Player::OnDead`
fired knowing that *a* player had died and not which one — no use at all, which
is why `tickBot` asked every bot on every decision whether it was still alive.
That was two bound calls (`get_HealthController`, then `get_IsAlive`) per bot
per decision, for a fact that changes once in a bot's life. `thisPointer`
identifies the corpse directly.

The handler does as little as it can: takes the address, queues it in a
fixed-size ring, returns. It runs on the game's thread and the bot table is
owned by the host's, so `drainDeaths` does the matching one tick later on the
right thread — a pointer compare per bot on the rare ticks where anything died.
The ring is safe across those two threads for a narrow and stated reason: the
only shared mutable state is one write index and 64 aligned 64-bit words, an
aligned 64-bit store is not torn on x64, and losing the race costs one tick —
the same 16 ms the poll would have cost anyway.

**The spawn hook attaches immediately.** It used to register a bot by profile
id and leave the 2 Hz world scan to find the object again: up to half a second
in which the bot existed, was decided about, and was decided about *from
defaults*, because there was nothing to read it through. Now `pointerOf` on the
hook's first argument gives the address while the handler is still running, and
`attachPointer` turns it into this mod's own IL2CPP GC handle on the spot.

Two deliberate choices there. It **verifies before it attaches** — if
`profileIdOf` on that pointer does not match the id the boxed read produced,
the argument was a `BotOwner` rather than a `Player`, and the pointer is
dropped for the world scan to redo rather than attached to the wrong object.
And it takes a **GC handle, not `pinHandle`**: this mod already re-resolves the
handle to an address once per tick in `liveOf`, which is the cheap half of what
pinning buys, and pinning would hold every bot in a raid immovable for the
session. The identity read (profile id, spawn type) stays on the boxed path,
because it happens once per bot per raid and the spawn type is an enum whose
`ToString` is the answer that survives a client renumbering.

While fixing the spawn hook I found it had been reading the wrong shape: it
parsed the whole payload as an array, when a `hookArgs` payload is an object
(`{"this":…,"args":[…]}`). `at(payload, 0)` on an object does not exist, so the
handler returned `carryOn()` every time and every bot was in fact being
registered by the world scan — with no spawn type, which means scav settings
for a PMC. It now reads `memberRaw(payload, "args")`.

### Revision 4: the two postfixes, and what the old refusal got right

This section used to end: *"Postfix hooks (`hookReturn`) are not used, and that
is a cost decision rather than an oversight: 418 ns for a watching postfix,
2245 ns with arguments and a replacement, because the payload crosses as JSON.
The two places a postfix would be natural here — reading a bot's aim result,
intercepting damage — both fire per bot per frame, which is exactly the rate at
which a JSON payload is a frame tax. If the typed, allocation-free postfix path
lands, those are the candidates in that order."*

It landed. Both are converted, in that order. The refusal was right about the
mechanism and wrong about one fact, and both halves are worth keeping.

**Right about the cost.** A postfix's price was never the thunk — that is a
`call`, a `ret` and a register save, single-digit nanoseconds. It was the
payload: a JSON string the host builds per firing, a GC handle per reference
argument, a copy into this mod's heap, a parse, and on a replacement a float
formatted to text and parsed back. `hookReturnTyped` hands over the registers
the thunk already saved plus the declared kind of every slot, computed once at
registration. Measured on this machine, median of three: **25 ns watching and
38 ns with a replacement, against about 1400 and 1800** for the same hooks as
JSON — the JSON figures were 1132 and 1583 when this was written and are
whatever the allocator is doing on the day, which is the point rather than a
caveat.
Nothing is built, nothing is copied, nothing is freed.

**Wrong about the rate — but only for one of the two.** "Both fire per bot per
frame" is true of the aim result and false of damage. Damage fires per *hit*:
zero on nearly every tick of a raid, and a burst of a dozen in the tick a
magazine goes into a squad. That distinction is what makes the two hooks arm
differently, and it is why the correction matters rather than being a pedantry.

**The aim result — typed, or not at all.** A postfix on the bot aim
component's readiness getter, per bot per frame, watching. The bool it returns
is the game's own answer to "has this bot's aim converged", and
`client/driver.nim` uses it to withhold a shot the ladder already ordered — the
difference between a bot that shoots and one that sprays the instant it has a
line. On a host older than revision 4 this is **not installed**, and the state
line carries the arithmetic: 443 ns per bot per frame is 1.06 ms a frame at
forty bots, six percent of the budget for one bool. That is the original
objection, and on a revision-3 host it is still correct, so it is still the
answer. `mods/classicmovement` falls back to JSON in the same position and is
right to; the difference is entirely the rate.

The gate is built so that a wrong guess costs nothing. It can only ever
*withhold* a shot, never order one; a bot with no fresh reading — the hook
refused, the aim component moved, two components collided in the fixed table —
behaves exactly as it did before this sensor existed. The postfix is installed **by verified static RVA**, not by name:
`Aiming::get_IsReady@0x1AD48C0` (UNIQUE, owners=1), through the host's typed
patch ABI, which needs no class lookup and no `MethodInfo`. The host checks the
module base, that the address is committed executable memory, that it is inside
GameAssembly's `il2cpp` PE section, and that its first sixteen bytes match its
own **startup snapshot** — so another feature's trampoline cannot make a correct
address self-reject.

The three *name* candidates that preceded it are kept in the source as the
record of a sensor that was dead in three different ways at once and reported
none of them: `EFT.AimDataClass` is not a type on this build, `EFT.BotAimingData`
is a type nothing in the image ever returns, and `EFT.BotOwner::get_AimingIsReady`
does not exist — and `armAimHook` was in any case never reached, because
`installHooks` returned above it.

Attribution is by the aiming node's own address, out of `this`, matched against
the two-hop walk `BotOwner → AimingManager → CurrentAiming` — held as an
identity and never dereferenced, exactly as `BotsGroup` is. `CurrentAiming` is
declared to return the interface `IBotAiming`, and that is safe only because
nothing is ever called on the result: every `AimingToXxx` node inherits the one
UNIQUE `Aiming::get_IsReady` body, while `UnderbarrelLauncherBotAiming` declares
its own at a different address, so when *it* is current the postfix simply never
fires, no reading is stored, and nothing is gated. The wrong-type case costs a
**missing** reading, never a wrong one.

The driver reports **fired / matched / withheld** as three separate numbers,
because they distinguish the three ways this sensor can be dead — the hook is on
the wrong address, the walk keys on the wrong object, or it works and every bot
was already settled — and one number could not tell them apart.

The reading is stored in a fixed direct-mapped table rather than queued. A
queue is right for deaths, which are two per tick at worst; at sixty entries
per bot per second the drain would be O(entries × bots). The handler computes
one index, writes three aligned 64-bit words and returns — no scan, no
allocation, no drain, and nothing that touches the bot table from the game's
thread.

**Damage — typed where the host has it, JSON where it does not.** A postfix on
the player damage method, watching, with `this` as the victim. It is queued in
a fixed ring and drained on the host's thread, the same shape and for the same
reasons as the death hook. What it buys is in section 1: `core/suppress.nim`
stops inferring hits from a health delta sampled at the decision rate — up to
four ticks late, and netting two hits against a regeneration — and is told each
one as it lands.

The amount is taken **by declared kind, not by position**: the first parameter
the host classified as a float. That is what the kind table is for, and it is
the difference between reading the damage and reading a body-part enum as one.
A shape with no float parameter still produces a usable event with no
magnitude, which is credited as the accumulator's smallest step — "this bot was
hit, now" is most of what suppression wants and it is exact.

**Nothing is read out of the `DamageInfo`,** and that is the one thing the
typed frame refuses rather than answers. It is a value type wider than a
register, so it arrives as `akBigValue`: an address of a copy whose layout the
host cannot read. Making sense of it means field offsets on a struct nobody has
dumped. So the aggressor is still unknown, and the `firedAtUsThisTick` row in
section 1 is unchanged by this hook — which looks like it should have been
unblocked and was not.

**Neither hook replaces anything, and that is a choice with the capability
sitting right there.** A typed postfix can rewrite the result for 38 ns, and
SAIN's C# does modulate bot aim by personality. Rewriting a gate this port has
never seen fire, on a method whose name is a guess, would be inventing
behaviour rather than porting it. Damage scaling is a difficulty concern that
`server/serverside.nim` already expresses as a database write. The capability
is there; the knowledge is not, and the two are different problems.

**Both are timed in the mod and both print the path they took.** See section 2
for the figures and for the honest note that against the stand-in neither has
ever produced one, because the stand-in has none of the six candidate names.

---

## 6. Layout

```
core/       the decision model. Pure nimony, no game calls at all.
  vec       vectors and the geometry the model needs
  toggle    Toggle / Cooldown -- the hysteresis primitive
  types     the decision enums and the records a tick reads
  settings  every threshold, resolved per personality at spawn
  enemy     perception: the enemy table, threat, forgetting
  hearing   audibility, derived from motion rather than received
  vision    acquisition, reaction delay, last-known uncertainty
  suppress  a bool integrated into a level with two thresholds
  squad     a squad view queried out of this mod's own bot table
  cover     scoring cover points; the raycast stays in the sampler
  probe     planning a cover sample, and folding its answers back in
  flank     where a decision sends the bot
  search    the search state machine
  decide    the arbiter: SAIN's priority cascade
  rng       a deterministic per-bot stream
  sig       the declared-signature rules for the driving calls
  selftest  124 checks that need no Tarkov to run
preset/     config.json -> a resolved Settings per bot role
client/     the only files that know Tarkov exists
  live      the IL2CPP runtime, held directly; every binding
  bridge    reading a bot; the order ring that drives one on Unity's thread
  coverprobe  the two Unity statics, and the sample that runs on Unity's thread
  mainthread  whether onMainThread is really Unity's thread, asked of the host
  driver    who thinks, when: the budget, discovery, the raid-level passes
server/     brain forcing, per-map difficulty, the preset route
```

## What actually reaches a bot (and the two-band test that proves it)

One thing does: **`difficulty` -> `BotMover.MoveSpeed`**, via `server/drive.nim`.
It resolves no IL2CPP name at run time and binds no RVA of its own. It rides
`aowlspt/botnav`, whose host side is the already byte-verified kind=15 detour on
`EFT.BotOwner::UpdateManual` @0x81B7C0. **Zero new RVAs.**

Requires `botNav` ON in `aowlspt-host.json` (default off). Without it nothing
moves and `/sain/status` says so at `driveCheck`.

`driveCheck` asserts a property of the live census, never of our own write:
*no bot this mod commands is frozen*. Falsified by a speed that reaches the
mover but is wrong -- every bot parks, and it returns FAIL. Three outcomes:

* `INCONCLUSIVE` -- no census, or fewer than 3 repeat sightings. We could not
  look. This is not a pass.
* `FAIL` -- 3+ repeat sightings and not one bot changed position.
* `PASS` -- the channel is live and nothing is parked. It does **not** prove the
  band changed anything.

**The two-band comparison is what settles that**, because bots move on their own
and one run cannot separate our speed from their brain:

1. `botNav` on. `difficulty` = `easy`. Enter an offline raid with bots.
2. `curl localhost:6969/sain/status` -> record `driveCheck` and the commanded
   `MoveSpeed` from `drive` (expect 0.49).
3. Set `difficulty` = `deathwish`, restart, same map. Expect 1.0.
4. Bots must be visibly faster in step 3. If they are not, the setting does not
   bite and `difficulty` should go back to `implemented = false`.

Still `implemented = false`, and why: **`forcePersonality`** is read and changes
`core/decide.nim`, but nothing the core decides reaches a bot -- reading a value
is not implementing a setting. **`driveFromHostThread`** governs
`client/live.nim`, the by-NAME path, which is fatal when used on this build
(facts #143/#144/#145) and is not used.


---

## ORBIT dispatch -- the low-level half

`server/dispatch.nim` turns the plan `mods/tarkov` broadcasts on
`tarkov.orbit.plan` into a per-bot `goTo` over `aowlspt/botnav`. See
`mods/tarkov/README.md` for ORBIT's licence (MIT, reimplemented not copied) and
the full concept map.

**This is the second verb this mod has ever had.** Before it, the whole channel
out of SAIN was `difficulty` -> `BotMover.MoveSpeed` for every bot at once.
Everything `core/decide.nim` computes -- cover scoring, dwell hysteresis, path
failure counting, banding, personality -- had nowhere to go. A per-bot
DESTINATION now does.

Zero new RVAs, same three `botnav` already rides. Nothing here resolves a name.

**One command set.** `dispatch.nim` never calls `sendBotCommands`; `drive.nim`
does, once, with the MoveSpeed row plus up to 12 `goTo` rows. `botnav` is
last-writer-wins, so a second send would silently drop the difficulty band.

### What it does

* personality drawn per bot id from the plan's distribution (stable for the
  raid), or forced by `forcePersonality`
* coverage roll per (bot, anchor) -- a bot that declines an anchor keeps
  declining it, so it does not oscillate across the map
* leader takes the primary anchor, followers take splinters within
  `splinterM`, and a follower past `leashM` is sent to the leader instead
* `navStatus == 2` (no path) blacklists that anchor FOR THAT BOT and picks
  another; it is never retried, because the navmesh will not change its mind
* arrival at an anchor releases it and takes the next, so a bot tours the map

### Check

`dispatchCheck()` on `/sain/status`. The negative asserted: *of every bot
addressed and measured twice, at least one got materially closer to the point
it was sent to.* A wrong coordinate makes `gMeasured` climb while `gProgressed`
stays 0, and it returns FAIL. Reading back the order we sent could not.

### The live test -- NOT YET RUN

Everything above is INCONCLUSIVE for behaviour. What has been proved offline is
only that the plan is built and DELIVERED: with `aowl.sain` and `aowl.tarkov`
both loaded on a scratch backend, a Customs raid configuration produced

```
dispatch : dispatch: 18 anchors on 'bigmap', 0 orders, 0 bots, personality drawn from the plan
check    : INCONCLUSIVE: a plan with 18 anchors is loaded for 'bigmap' but no
           order has been issued. Either no census has arrived (no raid, or
           `botNav` off in aowlspt-host.json) or every anchor was declined -- 0 were
```

To settle it:

1. `botNav` ON in `aowlspt-host.json` (default off).
2. Enter an offline Customs raid with bots.
3. `GET /sain/status` -- `dispatchCheck` must read PASS, not INCONCLUSIVE.
   INCONCLUSIVE means the census never arrived; that is a botNav or raid
   problem, not a dispatcher one, and the line says which.
4. For `forcePersonality`: run steps 1-3 twice, `rat` then `gigachad`, and
   compare the `declined by a coverage roll` counts. Same number both runs
   means the setting is not reaching the roll.

---

## The live raid test for each capability (2026-08-26)

Nothing below has run in a client. Every one of these is written so that a
WRONG calling convention trips it, because a wrong convention does not fault —
it returns a plausible number. "The call came back" is not a result.

Flags, default OFF, staged in `config.json` **next to the DLL** (a default in
source is not a value; the log prints each one as actually read).

**PASS / FAIL / INCONCLUSIVE, never two outcomes.** A refusal, a bot that never
spawned, an unreadable pointer, a `find` that STOPPED EARLY — all INCONCLUSIVE.

### 0. Verification only, no calls. Run this first, alone.

Boot to the main menu with the mod loaded and nothing else changed.

* Expect in `aowlspt-host.log`: seven `sain drive: ... VERIFIED` lines, one per
  target, each naming its RVA and `1 owner`.
* **Falsifier:** any `REFUSED` line. A prologue mismatch here means the game
  build moved and every RVA below is stale — stop, do not run 1–4.
* This step calls nothing, so a crash here would be a bug in verification
  itself.

### 1. `Physics::Raycast` — the convention proof

Stand a bot in the open, then against a wall. Read `probeState()`.

* PASS is not "it returned true". PASS is that `chestBlocked` **changes**
  between the two positions and changes in the right direction.
* **Falsifier:** a constant answer. If the two Vector3s are not arriving as
  pointers, or `maxDistance` is not in XMM2, the ray is cast from garbage and
  answers the same thing everywhere. A sensor that always says "blocked" and a
  sensor that always says "clear" are both this failure.
* Second falsifier, cheaper: cast a ray of length 0.01 straight down from a
  bot's own position. It must report blocked. Straight up in the open must
  report clear.

### 2. `NavMesh::SamplePosition` — the out-buffer proof

Sample a point on known floor, then a point 200 m in the air.

* PASS: floor answers `true` with `hitDist` small and the returned position
  within ~1 m of the input; air answers `false`.
* **Falsifier:** `hitDist` is huge, negative, or NaN, or the returned position
  is nowhere near the query. That says the 36-byte layout is wrong, and it
  would happen silently — the bool alone cannot catch it, which is exactly why
  the position is read back and checked rather than discarded as the old boxed
  path did.

### 3. `BotSteering::LookToPoint` — the one that is visible

One bot, one fixed world point, `hasLookTarget` only.

* PASS: the bot's head/weapon tracks that point as you move around it.
* **Falsifier:** the bot snaps to a fixed absurd direction, or its aim does not
  respond to the point changing. That is the Vector3 arriving as three
  registers instead of one pointer.

### 4. `BotMover::Sprint` and `ShootData::Shoot`

* Sprint PASS: `MovementContext.IsSprintEnabled` reads back **true** after
  `setSprint(mover, true)` and false after `false` — read it, do not infer it.
  **Falsifier:** it does not change, or it changes for `false` as well.
* Shoot PASS: the bot's own returned bool agrees with an audible shot.
  **Falsifier:** the call returns true and nothing fires — that is the shared-
  RVA / wrong-receiver shape, and it is why `ShootData::Shoot` was required to
  be a 1-owner symbol.

## BLOCKED: the destination

`BotMover::GoToPoint(Vector3, bool, float, bool, bool, bool, bool)` @0x1A2EE00
needs 8 register slots including `this`; `EFT.BotOwner::GoToPoint(...)`
@0x81CB40 needs 9. `AOWL_FAST_MAX_SLOTS` is **5** — Win64 spills everything past
the fourth argument to the **stack**, and the shape dispatcher does not express
a stack argument. `callrva` refuses rather than spilling, which is the right
behaviour and not something to work around inside this mod.

Both symbols are therefore **deliberately absent** from
`abi/aowlspt_symbols.txt`, with the reason written there, so nobody adds a
symbol that compiles into a call that can never be staged.

So today a bot steers, sprints and stops, and does not walk anywhere. That is
counted, not silent: `driveStats()` prints `NOT DELIVERED: N destinations`.

**The route out already exists and is not this mod's to build alone.**
`abi/aowlspt_botnav.h` carries a hand-written, byte-verified 8-argument thunk
for `EFT.BotOwner::GoToPoint` @0x81CB40, reachable from a mod as
`aowlspt/botnav.goTo` / `sendBotTo`. It is keyed by the **host census's bot
ID**; this mod walks to a `Player*` of its own. Mapping one to the other is the
next piece of work. The alternative — teaching the shape dispatcher to spill to
the stack — is a change to shared infrastructure (`abi/aowlspt_fast.h`) and
belongs to whoever owns it, not here.

## BLOCKED: the three medical self-actions

Measured offline: they do not exist at arity zero, which is how this mod used to
bind them.

    void BotFirstAid::TryApplyToCurrentPart(Nullable<int>, Action)            @0x1A20740
    void BotStimulators::TryApply(bool, Nullable<int>, Action<bool>)          @0x1A245E0
    void BotSurgicalKit::ApplyToCurrentPart(Action)                           @0x1A252F0

Two independent blocks. `Nullable<int>` is an **8-byte** by-value aggregate, and
8 bytes is precisely the size Win64 passes **in** the register rather than by
pointer — a case not measured on this build, which `callrva.addAggregate`
refuses by name. And each takes a managed `Action`; passing null bets that the
callee null-checks before invoking, and nothing has measured that it does.

Counted as `NOT DELIVERED: N medical self-actions`. `saReload` is unaffected and
still runs.
