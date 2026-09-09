# aowl.morebots -- the population half of Bot AI

**To the player this is not a mod.** It is hidden from the mod list
(`"internal": true`), it claims no settings page of its own, and its rows render
inside the Bot AI page tree as `Bot AI > Population`. The guid `aowl.morebots`,
this directory, `morebots.dll` and the `/morebotsapi/*` routes are INTERNAL
identifiers: the registry, the selection store and deploy verification all key
off them, so they are deliberately unchanged.

Two jobs in one binary, because upstream had them in one mod: it is **the
bot-type and faction API** other mods register against, and it is **the half
that raises how many bots a map runs**. Ported from the MoreBotsAPI mod by
TacticalToaster (upstream credit, not a name shown to a player).
Upstream is CC BY-NC-SA 4.0; the licence travels with the port and its text is
in `LICENSE` beside this file.

```
aowl build-mod mods/morebots
aowl run mods/morebots                 # the simulator self-test
```

`mods/blackdivision` is the first customer of the API half.

## Read this first

**Nothing here has ever run against BSG's client.** The server half is data
manipulation and HTTP and is checkable offline; `aowl run` checks it. The client
half is a read-only census whose every `EFT.` name is a hypothesis.

The client half is now two things: the **census**, which walks the alive-player list every few seconds and answers "how many are there right now", and the **death ledger** (`bots/deaths.nim`), which is hooked and answers "how many have there been". The census alone cannot see a bot that spawned and died between two scans, so a raid churning through sixty bots and one holding a steady twenty-two produce the same log. The ledger is read-only on every path — it returns `carryOn()` unconditionally, suppresses nothing and writes nothing — which is the only reason it is defensible to arm a hook against a target name nothing in this tree can verify. If the name is wrong the hook never arms and the ledger reads zero.

## What the original did, feature by feature — and where this port stands

| # | Upstream feature | Status here |
|---|---|---|
| 1 | Register a custom bot type: name, id, scav role, brain, boss/follower flags, excluded difficulties | **Implemented,** as the `morebots.type.register` event. |
| 2 | Write the type's template into `bots.types.<key>` | **Implemented,** merged so several mods can write sibling fields. |
| 3 | Write the type's config (preset batch, durability, item spawn limits, equipment filters, currency stacks) under `bots.config` | **Implemented.** |
| 4 | Loadout overlays merged onto an existing type | **Implemented** (`morebots.type.overlay`). |
| 5 | The faction graph: 21 named vanilla factions, nesting (`savage` → `scavbosses` → six more) | **Implemented,** verbatim, because mods are written against those names. |
| 6 | Hostility relations in both directions, as `ENEMY_BOT_TYPES` / `FRIENDLY` / `WARN` / `REVENGE` edits across all four difficulty blocks | **Implemented,** and idempotent where upstream's `AddRange` grew the same id on every load. |
| 7 | The `WildSpawnType` name→int table | **Implemented,** all 64 names decoded from ECMA-335 metadata in both `Assembly-CSharp.dll` and `SPTarkov.Server.Core.dll`, overridable from `config.json`. |
| 8 | Revenge counters, persisted per profile | **Implemented.** |
| 9 | Routes `/morebotsapi/{getfactions,getrevenges,updaterevenge,bottypes}` and `/singleplayer/settings/bot/difficulties` | **Implemented,** all five. |
| 10 | The DI-priority load ordering (`LoadFactions` before `LoadBots`) | **Replaced,** by a two-way `morebots.ready` / `morebots.hello` handshake, which does not depend on load order at all. |
| 11 | **`increaseBotCapAmount`** — raise every map's bot cap | **Reimplemented properly; the old version did nothing.** See below. |
| 12 | **Prepatcher:** `Utils.AddEnumValue` appends a field to `EFT.WildSpawnType` before the CLR loads it | **Impossible post-1.0.** IL2CPP: no managed assembly to rewrite, the enum is native constants with its switch tables already emitted, and nothing is loaded so there is no pre-load window. **New `WildSpawnType` values cannot reach the client.** |
| 13 | Nine Harmony patches (`BotsGroup::IsPlayerEnemy`, `BotGroupWarnData::ShallBossAttack`, `SuitableFollowersList`, `BaseStatisticsManager::OnDeath`, `StandartBotBrain::Activate`, …) | **One ported, the rest split three ways.** This row has been wrong twice and both corrections are kept. First it said `hookArgs` could not read declared arguments and `stopWith` could not override a return value; both can. Then it said **a hook is not told which instance it fired on** and rested eight refusals on that; it is false, and `bots/instance.nim` now proves it in the self-test. The payload is `{"this":{"handle":n,"type":"…"},"args":[…]}` — Harmony's `__instance` — and `thisHandle`/`thisPointer` read it, as `mods/classicmovement` does in shipped code (`mods/fov` only *discusses* `thisPointer`; it calls it nowhere, so citing both was itself half wrong). Per patch: **`BaseStatisticsManager::OnDeath` is ported**, read-only, as the death ledger in `bots/deaths.nim`. `IsPlayerEnemy` and `ShallBossAttack` are **expressible but absent** — naming *which* group means reading a member off it, every candidate name is a pre-1.0 guess, and server-side `ENEMY_BOT_TYPES` already does the job with a mechanism that has been tested. `SuitableFollowersList` never needed `this` at all: the list is an *argument*, and `bindOnObject` can call `Add`/`Remove` on a collection `findClass` cannot name — what is missing is upstream's filter rule, which nothing here records. `StandartBotBrain::Activate` is **genuinely impossible** and always was: it needs a *new managed type* with overridden virtuals, and IL2CPP has no runtime type definition. `TarkovApplication::Init` and `BotsController::Init` were always expressible and have nothing left to construct. That is seven; **the remaining two are named nowhere in this tree**, so two ninths of this row cannot be audited by anyone, including its author. |
| 14 | `HuntManager`, `BotHuntManager`, `HuntTargetLayer` and its three actions | **Impossible.** Unity `MonoBehaviour`s plus BigBrain custom layers; no BepInEx, no BigBrain, and `invoke_main` reaches the host's thread rather than Unity's. |
| 15 | SAIN interop (`AddSAINLayers`) | **Impossible, and already a stub upstream** in 2.0.3 — SAIN's `BigBrainHandler.BrainAssignment` API had been removed. |

## The bot cap: what was wrong and what replaced it

`increaseBotCapAmount` wrote `bots.config.maxBotCap`. **Nothing on this stack
reads that path.** A stock SPT 4.x database's `bots` object is `core`, `base`,
`types` — there is no `bots.config` at all — and `mods/tarkov` never looks
there. The feature was doing nothing, silently, on every install that set it.
It is kept, deprecated, and now logs a line saying so, because an install that
set it should not change behaviour without being told.

What replaced it is `population` in `config.json`, and it writes where the
client can actually see it: `locations.<map>.base`, which `/client/locations`
serves **verbatim**. Three fields per map:

* **`BotMax` / `BotMaxPvE`** — the alive-AI ceiling.
* **`MaxBotPerZone`** — the per-zone ceiling. This is the one people forget.
  The spawner will not put a fifth bot in a zone that allows four, so a raised
  `BotMax` with an unchanged per-zone limit is headroom that never gets used
  and the mod reads as broken.
* **`waves[].slots_min` / `slots_max`** — how many bots each scav wave brings.
  This is what actually changes how a raid feels; the cap only sets the ceiling.

### Why there is a shipped baseline

The obvious implementation — read `BotMax`, multiply, write back — is wrong in
the way that takes a month to notice. **The database persists.** Every server
start reads back what the last start wrote and multiplies it again. At 1.5x a
map at 30 goes 45, 68, 101, 152. Nothing errors, nothing logs, and the only
symptom is a server that gets slower every week.

So `data/vanilla.json` ships the numbers to scale *from*, read out of a stock
SPT 4.x database: **19 maps, 154 waves, 283 vanilla wave slots, 341 summed
alive-bot cap.** Applying a multiplier twice gives the same answer as applying
it once, and `preset: "vanilla"` is a real off switch because the mod still
knows what the numbers were. Both properties are asserted by the self-test
rather than claimed here.

Presets: `vanilla` (1.0x), `more` (1.35x cap and waves, 1.5x per-zone), `lots`
(1.75x / 2x), `horde` (2.5x / 3x, past the point where any of it is balanced),
or `custom` with the three multipliers written out. Off by default: a server
quietly running more AI than the player asked for is not a feature.

The three multipliers ship as `null`, which means "whatever the preset says",
and that is not cosmetic. A number written beside `preset` **wins over it** —
which is the behaviour anyone would want and is also a trap, because the file
used to ship `botCapMultiplier: 1.0`. Setting `preset: "horde"` then did
nothing at all: no warning, no log line, and no way to tell from the outside
that the switch was dead. Every preset check in the self-test passed the whole
time, because they all ran on a default config object and none of them touched
the file. There is now one that drives the shipped text with a preset in it,
which is the only version of the question a player ever asks.

### A map this mod has never seen stock

The baseline covers the nineteen slots a stock database ships, and that is a
hard limit rather than an oversight: scaling a modded map would mean scaling
from its *live* numbers, which is exactly the compounding bug above.

It **was** also a real gap, and `mods/icebreaker` was it. That mod rebinds the
dormant `suburbs` slot into a working map with eleven waves; the vanilla
baseline has that slot at `botMax: 0` with two stub waves, so the cap was
skipped for being zero and the wave array skipped for being a different length.
Install both, ask for `horde`, and eighteen maps got busier and the nineteenth
did not. **It is closed from the other side**: icebreaker's `populationBaseline`
puts that map's cap, per-zone limit and eleven wave slot pairs into every
announcement it makes, a donated entry wins over the shipped stub for the same
slot, and all nineteen scale. This paragraph read as an open gap until then.

The mod that owns the map is the only thing in the install that knows its stock
numbers — it ships them as data and rewrites them from that data on every boot
— so it is asked. `aowlspt.locations.changed`, already the contract between "a
mod that adds a location" and "a mod that decorates every location", may now
carry a `population` object shaped like an entry in `data/vanilla.json`:

```json
{"guid": "aowl.icebreaker", "locations": ["suburbs"],
 "population": {"suburbs": {"botMax": 40, "maxBotPerZone": 2,
                            "waves": [{"slotsMin": 2, "slotsMax": 4}, ...]}}}
```

A map announced with one is scaled from it, through the same arithmetic,
clamps and idempotence as a shipped one. A map announced **without** one is
named at boot with what it costs and what closing it takes — it is not
guessed at, and it is not silently skipped either. This mod subscribes to the
announcement and also emits `aowlspt.locations.hello`, so it does not matter
which of the two mods loads first.

Against a real database, `more` gives:

```
18 of 19 map(s) changed; alive-bot cap 341 -> 458 summed over every map,
wave slots 283 -> 371 over 154 wave(s) (80 rewritten)
```

Ceilings (`capCeiling`, `perZoneCeiling`, `waveSlotCeiling`) exist because a map
has a fixed number of spawn points, and asking for more bots than it has places
to put them gives half-built bots and stutter rather than more bots. A clamp is
logged, never silent — "I asked for 3x and got 1.9x" is a fact you need.

## What it still cannot do, and why

* **A custom `WildSpawnType` cannot reach the client.** The registry keeps and
  serves the mapping at `/morebotsapi/bottypes` so the data is not lost, but no
  shipped client reads it. The client-side census counts any role id at or above
  100 specifically so this claim is *tested* rather than repeated.
* ~~**`/client/game/bot/limit` cannot be changed.**~~ **It can now**, and the
  claim was accurate when written — the route answered a literal `30` for every
  map with no database path behind it, so this mod's 19 maps, 154 waves and
  summed cap of 341 landed in the database and none of it reached the client.
  `onBotLimit` asks the map: `locations.<map>.base.BotMaxPvE` first (this
  server is only ever PvE), then `BotMax`, and the constant answers only where
  the database says nothing. The map id is read from the query *and* the body,
  because the client has spelled it both ways across builds and reading it
  wrong is a silent fall back to the default.
* **The emulator does not read `waves` or `MaxBotPerZone`.** That is not a
  reason to skip writing them — `/client/locations` serves the whole `locations`
  table untouched, so the client receives every field written here, and the
  client is what spawns bots. This bullet used to name `BotMax` and "any
  difficulty table" among the unread and conclude that the *server-side* effect
  of this mod is zero: both are read on this stack now, `BotMax` by
  `/client/game/bot/limit` (see below) and the per-role difficulty tables by
  `/singleplayer/settings/bot/difficulties` through `emu/bots.difficultyOf`, so
  that conclusion no longer holds.
* **A map whose live `waves` array is a different length from the baseline is
  left entirely alone** and named as skipped: another mod owns it, and guessing
  which of their entries matches which of ours is a coin toss with a raid on
  the other side of it. Named rather than counted — "1 map was skipped" is not
  something a player can act on, and "suburbs kept stock wave slots while every
  other map went to 2.5x" is. The owning mod closes it by donating a baseline.
* **A hook now knows which object it fired on — and that is not the same as knowing which *bot*.** The payload carries `this` as a handle, an address and a **concrete runtime class name**, with no binding and no member name needed for any of the three. What it does not carry is identity: which group, which faction, which nickname. Reaching those means reading a member off the object, and every candidate member name here is a pre-1.0 hypothesis nothing in this tree can check. `this` moved several refusals from *inexpressible* to *unverifiable*; that is a real change and it is not the same as closing them. Two harder limits go with it: `this` is the receiver and never its owner, so a hook on a component cannot reach the entity holding it; and an instance method's **fourth declared argument is on the stack and is omitted from the payload entirely**, because `this` takes register position 0. Both are asserted in the self-test rather than described here.
* **No hunt behaviour, no per-group hostility override, no brain swapping.**
  Rows 12–15.

## The self-test

`aowl run mods/morebots` drives the whole registration surface with no backend —
a type registered, a faction defined, a relation applied, every route body built
and parsed back — and then checks the population data, which is the half that
can silently half-load:

```
population baseline: 19 map(s), 154 wave(s), 283 vanilla wave slot(s),
                     341 summed alive-bot cap
presets: vanilla is 1.0x on all three knobs, lots is 1.75x / 2.0x / 1.75x
the shipped config.json does not shadow its own preset: `horde` through the
                     real file gives 250% cap, 300% per-zone, 250% wave slots
the buffered fold matches a sequential merge byte for byte on four shapes
a hook IS told which object it fired on: handle, concrete runtime class, and
                     static-vs-absent kept apart; and a 4-argument instance
                     method reports 3 arguments and drops 1
an argument the host never reported does not read the same as one that is
                     fine: `not reported`, `no such parameter` and `the payload
                     disagrees with the signature` are three distinct answers
deaths: 5 payload(s) over 2 receiver class(es), grouped by concrete class,
                     with 2 firings carrying no receiver counted separately
deaths: the hook refuses offline for the runtime reason and names what it
                     costs — checked by reason, not merely by refusal
```

With a database attached (`aowlspt-sim <mod> --side sim --db <file>`) it also
asserts the two properties the shipped-baseline design exists for:

```
a `more` pass over a real database: 18 of 19 map(s) changed; cap 341 -> 458,
                                    wave slots 283 -> 371 over 154 wave(s)
and applying it a second time gave exactly the same numbers (458, 371)
and `preset: vanilla` puts every number back to stock (341, 283)
```

A read-modify-write scaler passes every other check in the file and fails the
second of those, and failing it is what makes a server slower every week for no
visible reason.

## What a boot costs, and what the buffer is for

`dbWrite` splices into one 39 MiB text document, and the cost of a call is
**the size of the object at the path** rather than the size of the database or
of the patch — about 3 ms for one `locations.<map>`, about 43 ms for
`bots.types`, about 114 ms for the whole `locations` table. The shallow write
is the expensive one, which is why `bots/pending.nim` groups two segments deep
and not one; both depths were measured and one is slower.

With `mods/blackdivision` attached this mod buffers its whole contribution and
writes it in two calls. That fold used to be a merge-one-at-a-time into a
growing accumulator and it cost **238 ms against the 81 ms of writing it was
saving**; it is a grouped one-pass fold now, and the self-test compares it byte
for byte against the sequential merge it replaced. The registration went from
363 buffered changes and 328 ms to 186 and 91 ms, and `blackdivision` finishes
loading in 520 ms rather than 766 ms on the real database.
