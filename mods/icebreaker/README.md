# aowl.icebreaker

The nuclear icebreaker **BOREAS**, locked in arctic ice — a map, delivered by
rebinding the dormant `suburbs` location slot. Ported from **ManimalIcebreaker**
by Manimal / danauraborealis. Upstream is MIT; the licence travels with the port
and its text is in `LICENSE.txt` beside this file.

```
aowl build-mod mods/icebreaker
aowl run mods/icebreaker               # the simulator self-test
```

Server-only. It never enters the game's process, binds no method and has no
per-frame path.

## Read this first, twice

**This is a map mod, and a map mod is mostly assets.** The scene bundle, the
scenes preset, the culling and acoustics bakes, the AI navmesh, five prop
bundles and about 16MB of authored loot are **not shipped here and cannot be** —
they are not code. Without them the slot resolves to a map the client has no
geometry for. What this mod is, is the half that makes the server and the client
agree the map exists, plus every table that can be authored without the scene
open.

**It is not a weather or season mod.** If you came looking for winter: see
"Arctic weather" below, where the refusal is spelled out.

**Nothing here has ever run against BSG's client.** The slot rebinding, the
scene handoff and the locale keys are upstream's design and this port's reading
of it.

## What the original did, feature by feature — and where this port stands

| # | Upstream feature | Status here |
|---|---|---|
| 1 | Rebind the `suburbs` slot: name, description, scene, time limits, player counts, map-dot coordinates, bot settings, banners | **Implemented,** 31 fields merged. |
| 2 | Point `Base.Scene` at the bundle + rcid | **Implemented.** This one field is the whole handoff to the client's bundle loader. |
| 3 | Rebrand the locale so the map dot stops saying SUBURBS | **Implemented,** and now data-driven: 16 keys from `data/locales.json`, written into every language the database carries. |
| 4 | The map's exit table | **Implemented — this was the largest gap.** See below. |
| 5 | The map's scav waves | **Implemented.** 11 waves, 34 bot slots. |
| 6 | Boss spawns | **Implemented,** shipped and off by default. |
| 7 | Alive-bot cap for the slot | **Implemented properly; the old version did nothing.** See below. |
| 8 | Scav raid timings for the slot | **Partly, and it now says so.** Cloned from `factory4_day` when that entry is there, from whatever other map the table carries when it is not, and skipped with a line at boot when the database has no `configs.location.scavRaidTimeSettings.maps` table at all — which is the case on the emulator *and* on the 39 MiB import this was checked against, so the clone had never once happened and had never said a word. |
| 9 | Loot table shape so a raid starts | **Implemented,** empty but structurally valid. |
| 9b | Announce the location so mods that decorate every map reach this one | **Implemented.** `aowlspt.locations.changed` after the writes flush, plus an answer to `aowlspt.locations.hello`. Without it a decorator that loads first — SAIN, setting every map's `BotLocationModifier` — silently skips this map, because the host's load order is a directory walk. `tools/allmods.nim` found exactly that. |
| 9c | *(new)* Declare the map's stock bot numbers so a population mod can scale it | **Implemented.** `mods/morebots` raises every map's cap and wave slots from a shipped stock baseline, never from the live values, because a live-value multiply compounds on every restart. Its baseline for `suburbs` is the dormant stub — `botMax: 0`, two placeholder waves — so without this the one map in the install that ignored the preset would have been this one. The `aowlspt.locations.changed` payload now carries a `population` object with this map's cap, per-zone limit and per-wave slot counts, checked by the self-test against the tables actually written. |
| 10 | Watch for crossings ("came back alive from the icebreaker") for the quest gates | **Implemented,** off `tarkov.raid.configured` / `tarkov.raid.ended` rather than by intercepting `/client/match/local/end`. |
| 11 | A `bundles.json` manifest so a client can say which bundle is missing | **Implemented,** served at `/icebreaker/bundles`. |
| 12 | **`SpawnPointParams`** — where a player and a bot may start | **Not shippable.** See below. This is the one gap that stops a raid. |
| 13 | **The authored loot tables** (`looseLoot.json`, `staticContainers.json`) | **Not shipped — 8MB of extracted coordinates.** Same reason as 12. |
| 14 | **The scene and prop bundles, navmesh, culling, acoustics, weather/sky tables** | **Not shipped — assets, not code.** |
| 15 | **Banner image routes** (`ImageRouter.AddRoute` serving `/files/banners/*` off disk) | **Impossible.** This ABI has no static-file route. The banner *entries* and captions are written; the pictures are the install's problem. A missing picture degrades to the default art, which is why the entries are still worth writing. |
| 16 | **Per-profile map locking** — recompute `Enabled`/`Locked` inside its own `/client/locations` router | **Impossible as designed; degraded honestly.** `/client/locations` belongs to `mods/tarkov` and the backend refuses a second registration of an exact route (`the route ... is already registered`). There is no route chaining and no output filter. The lock is therefore applied at the *database* level and is **global**: on or off for the install. The per-profile answer is still computed and served at `/icebreaker/state`. |
| 17 | **Quest-visibility gating** of `/client/quest/list` | **Impossible, same reason.** The gate *evaluation* is here and answers at `/icebreaker/state`; the filtering is not. |
| 18 | Fika coop paths | **Not applicable.** No Fika post-1.0. |
| 19 | tarkin's Climbable Ladders dependency (the ship's ladders) | **Out of scope.** A separate client mod. |

## The exits: what the slot actually ships

The `suburbs` stub is not a half-finished map. It is an empty record:

```
locations.suburbs.base.exits             []        <- no way out
locations.suburbs.base.SpawnPointParams  []        <- nowhere to start
locations.suburbs.base.BossLocationSpawn []
locations.suburbs.base.waves             2 stubs
locations.suburbs.base.BotMax            0
locations.suburbs.base.MaxBotPerZone     0
locations.suburbs.base.EscapeTimeLimit   0
```

Before this pass the mod set the time limit and left the rest. A raid on the
rebound slot was a raid you could not leave except by dying, with nobody on it,
and a bot cap of zero.

Three of those five are now shipped as data, and the line between what could be
authored and what could not is exactly one property: **whether the record
contains world coordinates.**

* An **exit** does not. It carries a name, a chance, an exfil timer and a time
  window; the geometry is a trigger in the scene and the record is matched to it
  by `Name`. `data/exits.json` — 3 exits, 2 closed to player scavs.
* A **wave** does not. It names a bot *zone* by string. `ZoneIcebreaker` is the
  zone upstream's own `openZones` declares, so a wave naming it is right by
  construction rather than by guesswork. `data/waves.json` — 11 waves, 34 bot
  slots, tuned for a 50-minute raid on a ship: fewer bodies than Shoreline, more
  pressure than Factory.
* A **boss spawn** does not, for the same reason. Same file, one record, off by
  default because a boss on a map with empty loot tables is a fight for nothing.
* A **`SpawnPointParams`** entry is nothing *but* coordinates — `Position`,
  `Rotation`, a collider radius, an `Infiltration` name, a `Sides` list. A stock
  map has between 14 (Labyrinth) and 458 (Streets) of them.

The exit and zone names are the names **upstream's own config already refers
to** (`ZoneIcebreaker` from `openZones`; Helicopter / Cellars / Gate 0 from
`exitLocaleKey` and `disabledScavExits`). This port did not choose them. If a
scene bundle turns out to disagree, the fix is a data file — `exitsFile` and
`wavesFile` are config keys and nothing in code knows the names.

## The bot cap: what was wrong

The old code wrote `configs.bot.maxBotCap.<slot>` and logged a shrug when that
failed. It always failed: a stock SPT 4.x database has **no top-level `configs`
object at all**, so the write had nowhere to land and the cap was never set on
any install, ever. The stub ships `BotMax: 0`, and a map with a cap of zero
spawns none of the waves above it.

It now writes `locations.<slot>.base.BotMax` and `.BotMaxPvE`, which is where
the client reads it and which `/client/locations` serves verbatim. The old path
is still written afterwards, because an install that *does* have a `configs`
object is not this mod's to break.

## Arctic weather, and why it is refused rather than shipped

There is a config key `arcticWeather`, it is off, and turning it on produces an
**explanation rather than an effect**. That is deliberate: a silent omission
teaches nobody anything, and a `winter: true` switch that does nothing is worse
than either.

The reason, exactly — and it is **not** the reason this document used to give.
It said there was no weather table in the database and that writing one would
write into a path nothing reads. `mods/tarkov`'s `emu/raid.nim` now reads
`weather` out of the database and falls back to its constant only when there is
none, so that half stopped being true and was re-checked rather than left
standing. What blocks this mod is the other half:

* The `weather` table is **one record for the whole install**, not one per
  location, and nothing in the `/client/weather` response is keyed by map.
  Writing a winter sky into it would put snow and a minus-thirty reading over
  Customs and Streets as well — a worse bug than a warm icebreaker, and one
  this mod would have caused everywhere else in the install.
* The backend **refuses a second registration of an exact route**, and there is
  no route chaining and no output filter, so this mod cannot answer
  `/client/weather` itself for its own map either.

Closing it needs the location id to reach the weather answer — either
`mods/tarkov` keying `weather` by map, or a route-chaining API — both of which
are somebody else's file. Until then the ship is locked in ice under an
18-degree cloudless sky, and this mod says so.

The same shape of refusal applies to the visual half generally: snow, ice
shaders, fog volumes and the sky itself are in the scene bundle and its weather
tables, which are assets.

## What it still cannot do, and why

* **A raid on this map will not start without `SpawnPointParams`.** That is the
  honest headline, and it now has a second consequence worth naming: a mod that
  writes spawns onto maps — `mods/blackdivision` puts a hunt squad on ten of
  them — refuses this slot for exactly that reason and says so, rather than
  writing a record that would be accepted and never fire. `spawnPointsFile` in `config.json` lets an install that has
  the scene supply the array, and nothing is invented in its place — an invented
  spawn point puts the player inside the hull or under the ice. Closing it takes
  the scene bundle and a pass over its `SpawnPointParams` objects; the result
  drops in at `locations.<slot>.base.SpawnPointParams` with no code change,
  because `dbWrite` merges.
* **The floor is empty.** Same refusal at 8MB. The written tables are empty and
  *valid*, which is the difference between a raid that starts with nothing on
  the floor and a raid that does not start.
* **Map locking and quest visibility are global, not per-profile.** Rows 16–17.
* **Banner images are not served.** Row 15.
* **`globalLootChanceModifier` multiplies an empty table.** 0.27 is upstream's
  number, tuned against its authored loot; on a stock install the answer is
  still empty.

## The self-test

`aowl run mods/icebreaker` builds every document offline and parses it back, and
checks the map tables rather than reporting that they parsed:

```
map tables: 3 exit(s) (2 closed to scavs), 11 wave(s) totalling 34 bot slot(s),
            1 boss spawn(s), 16 locale string(s)
```

* every exit has a name, a chance in 0..100, a non-zero exfiltration timer, all
  15 fields the client indexes, and no duplicate name;
* every wave names a role a **wave** may legally carry — a boss named in a wave
  is a wave the client drops without a word — and spawns into the zone this
  location declares, checked against `openZones`, because a wave pointed at a
  zone the scene has no `BotZone` for never spawns and nothing reports it;
* every boss record carries all 21 fields, **including the four whose
  almost-right spellings deserialise to nothing without a word**:
  `BossDifficult` is not `BossDifficulty`, `BossPlayer` is not `IsBossPlayer`,
  `RandomTimeSpawn` is not `IsRandomTimeSpawn`, `BossEscortDifficult` is not
  `BossEscortDifficulty` (140 of 140 records in a stock database agree);
* the exit list and the locale list are checked against each other **in both
  directions** — an exit with no locale prints its raw id at the player, and a
  locale entry for an exit that no longer exists hides the next rename;
* `DisabledScavExits` is built from the data as the comma-separated string the
  game actually wants, rather than restated in config where it could drift;
* the population baseline in the `aowlspt.locations.changed` payload is checked
  against the waves this mod actually writes, in both count and slot total — a
  baseline that disagrees with the map is worse than none, because the mod
  scaling from it would write numbers wrong by a constant factor with nothing
  to compare them against;
* the three refusals above are printed in full, with the reason and with what
  closing each would take, because the output is what somebody reads first.
