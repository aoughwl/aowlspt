# Loot configuration

**The file you edit is `mods/tarkov/config.json`** (in the live install:
`D:\Aowlspt\aowlspt\mods\tarkov\config.json`). Every key below is also a row on
the in-game **Loot** page, and editing it there writes the same file.

Before this there were four loot knobs: `lootEnabled`, `staticLootMultiplier`,
`looseLootMultiplier`, `maxLootItems`. They are all still here, unchanged in
meaning, with 24 more around them.

**Every default is the behaviour the emulator already had.** Changing nothing
changes nothing: `emu/loot.selfCheck` asserts that each new field's default is
the constant the generator used to hardcode, and that the pool-shaping code is
*skipped* at defaults rather than run with neutral numbers.

Settings are read at load and applied to the loot generated for the **next
raid**. Nothing here can change a raid already in progress.

---

## The screen

The Loot page is seven sections, in this order:

| section | what it is for |
|---|---|
| Loot/Presets | one-click presets, and the live summary line |
| Loot/Global | the master switch and the multipliers that act on everything |
| Loot/Containers | crates, safes, jackets, weapon boxes |
| Loot/Loose | what is on the floor and on shelves |
| Loot/Item mix | which items the pools favour |
| Loot/Money & stacks | how large a spawned stack is |
| Loot/Per-map | overrides for one map |

### Presets

`lootPreset` — `custom` (default), `vanilla`, `scarce`, `richer`, `goblin`.

It is a **button, not a mode**: picking one writes the knobs below it and then
gets out of the way, so you can fine-tune afterwards without the preset undoing
you. Every preset writes *every* knob it cares about, so picking the same preset
twice always lands in the same place. `vanilla` is the way back from any
experiment — it is exactly `defaultLootConfig()`.

| preset | what it does |
|---|---|
| vanilla | every loot knob back to its shipped default |
| scarce | global 0.5, fill 0.7, value bias −0.5, stacks capped at half |
| richer | global 1.5, fill 1.3, stacks use the item's own declared range |
| goblin | global 3.0, fill 2.0, container cap 128, value bias +0.8, own stack range |

`lootSummary` is **written by the server**, not by you: one sentence describing
what the current configuration will actually do, recomputed from the same
`lootConfig()` object the generator reads. If the summary and your reading of
the sliders disagree, the generator agrees with the summary.

---

## Every knob

Range and default; "controls" names the code that reads it.

### Global

| key | default | range | controls |
|---|---|---|---|
| `lootEnabled` | `true` | bool | master switch. Off serves an empty floor and says so in the log |
| `lootGlobalMultiplier` | `1.0` | 0–10 | multiplies **both** passes, on top of their own multipliers |
| `staticLootMultiplier` | `1.0` | 0–10 | container spawn chance **and** fill |
| `looseLootMultiplier` | `1.0` | 0–10 | probability of every loose spawn point |
| `maxLootItems` | `20000` | 0–200000 | hard ceiling on items in one raid |
| `lootStaticBudgetShare` | `0.5` | 0–1 | share of that ceiling offered to containers before the loose pass runs; the unspent part is handed on |

### Containers

| key | default | range | controls |
|---|---|---|---|
| `staticLootEnabled` | `true` | bool | run the container pass at all |
| `containerSpawnChanceMultiplier` | `1.0` | 0–10 | **how many** crates exist (their `probability`). `IsAlwaysSpawn` containers ignore it, as they ignore every chance |
| `containerFillMultiplier` | `1.0` | 0–10 | **how full** each crate is (the drawn item count) |
| `containerMaxItems` | `64` | 1–512 | per-container cap after the fill multiplier. The container's own grid is still the real limit |
| `containerTypeChances` | `""` | `tpl=mult,…` | per container **template** spawn multiplier, e.g. `578f87b7245977356274f2cd=2` |

### Loose

| key | default | range | controls |
|---|---|---|---|
| `looseLootEnabled` | `true` | bool | run the loose pass at all |
| `lootForcedSpawns` | `true` | bool | `spawnpointsForced` — quest items and keys, which ignore probability. **Turning this off can make a quest uncompletable** |
| `looseLootPointLimit` | `0` | 0–100000 | at most this many non-forced loose points may spawn. 0 is no limit. Changes the ceiling, not the odds |

### Item mix

All of these reweight a **pool** before anything is drawn from it — they change
the mix, never how many things spawn. At their defaults none of this code runs.

| key | default | range | controls |
|---|---|---|---|
| `lootValueBias` | `0.0` | −2–2 | reweights by handbook price. >0 favours expensive, <0 cheap. Bounded at 20× the pivot so one absurd price cannot swallow a pool |
| `lootValuePivot` | `20000` | 1–1000000 | the price at which the bias has no effect |
| `lootMinHandbookPrice` | `0` | 0–1000000 | remove pool entries cheaper than this. 0 is off |
| `lootMaxHandbookPrice` | `0` | 0–10000000 | remove pool entries dearer than this. 0 is off |
| `lootRarityCommon` | `1.0` | 0–10 | weight for `_props.RarityPvE` (or `_props.Rarity`) = Common |
| `lootRarityRare` | `1.0` | 0–10 | … Rare |
| `lootRaritySuperrare` | `1.0` | 0–10 | … Superrare. 0 removes them entirely |
| `lootCategoryWeights` | `""` | `id=mult,…` | `id` is a template id **or any base class on its `_parent` chain**, so one entry covers a family. Walked up to 12 hops, cycle-safe |

Three things worth knowing:

* An item the **handbook does not list** is left unweighted and is never removed
  by the price gates. "The handbook has no row for it" and "it is worth nothing"
  are different facts and only one is a reason to delete an item from the game.
* A loose spawn point whose candidates are **all** gated away spawns *nothing*.
  It does not fall back to its first candidate — that was a measured bug during
  development and there is a self-check against it.
* An item generated as a **child** — cartridges in a magazine, rounds in an ammo
  box, mods on a preset weapon — is not a pool draw and is deliberately not
  gated. Zeroing "ammo" does not produce unloaded weapons.

Base class ids people usually want (money `543be5dd4bdc2deb348b4569`, ammo
`5485a8684bdc2da71d8b4567`, meds `543be5664bdc2dd4348b4569`, keys
`543be5e94bdc2df1348b4568`, barter `5448eb774bdc2d0a728b4567`) are
**SPT-community-known and were not verified against this install's database.**
Check the `loot: … pool shaping applied` line the server logs, which reports how
many pool entries the weights actually touched — a knob that matched nothing
says so rather than reading as broken.

### Money and stacks

| key | default | range | controls |
|---|---|---|---|
| `lootStackRandomRange` | `false` | bool | see below |
| `lootStackMultiplier` | `1.0` | 0–10 | scales the rolled stack count. Never below 1 or above the item's `StackMaxSize` |
| `lootStackMaxFraction` | `1.0` | 0–1 | caps every stack at this fraction of `StackMaxSize`. `0.05` on a 500,000-limit rouble stack caps it at 25,000 |

`lootStackRandomRange` **off** (the shipped behaviour) rolls a stack uniformly
over `1..StackMaxSize`. For currency that limit is far larger than anything the
game itself spawns, which is why world money can look absurd. **On** uses the
template's own `_props.StackMinRandom..StackMaxRandom` where it declares them —
the *same* discriminator `emu/bots.randomStackCount` already uses for scav
money, read rather than duplicated. On stock data that is currency and loose
ammunition and nothing else; everything else behaves identically either way.

### Per-map

| key | default | range | controls |
|---|---|---|---|
| `lootPerMapMultipliers` | `""` | `map=mult,…` | extra multiplier on **both** passes for that map only |

The name must be the **database location key** (`bigmap`, `woods`,
`factory4_day`, `rezervbase`), not the client-side Id, because the generator is
handed the already-resolved key. A map set to `0` serves an empty floor and the
server names this setting in the log when it does.

---

## Malformed input

The three `name=value` settings drop a malformed pair and keep the rest; a
dropped pair is **absent**, never present as zero (zero would mean "delete this
map's loot"). How many pairs survived is stated in the summary line.

## When a map comes back empty

`emu/loot.lootFor` names the reason, once per raid, read off the finished state:
`lootEnabled` off, `maxLootItems` zero, both passes disabled,
`lootGlobalMultiplier` zero, this map set to zero in `lootPerMapMultipliers`, the
map id not resolving to a database location, or the location genuinely carrying
no tables. An empty floor is a valid answer and it always says which of those it
was.

## Checking your work

`GET http://127.0.0.1:<control-port>/aowlspt/tarkov/selfcheck` returns
`{"ok":true,"failures":[]}` when the loot generator's own arithmetic holds. It
runs at load and the server refuses to start if it does not.
