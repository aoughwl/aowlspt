# The pre-1.0 database against post-1.0's own tables

`mods/tarkov` serves a database imported from a **pre-1.0 SPT install**
([IMPORTDB.md](IMPORTDB.md)) to a **post-1.0 client** (build 1.1.0.1.46777).
That has always been the compromise, and until now nobody could say how large
it was, because the only post-1.0 copy of the data was inside BSG's servers.

On 2026-08-19 the real backend's responses were decrypted. `data/capture/raid1`
now holds one account's full menu session — 220 exchanges — with the bodies in
plaintext, and among them are the tables the emulator answers out of `db.json`.
So the question stops being an opinion.

**The headline: the SPT data is closer than expected, and nothing the emulator
reads has been taken away.** The gap is almost entirely *additive* — 1,154 item
templates, 6 traders, 5 maps and 8,545 English strings that post-1.0 has and
pre-1.0 does not — plus a large number of small numeric rebalances. There is no
schema break in items, locations, globals, traders, the handbook, customization
or settings. The one shape change that matters is in **quests**, and the one
table that is a real hole is **`locations.paths`**, which is empty for a reason
that predates all of this.

## What was compared, and against what

| table | route | capture file | decoded | what it is compared with |
|---|---|---|---:|---|
| items | `/client/items` | `responses/large/045.json` | 18.3 MB | `templates.items` |
| locale (en) | `/client/locale/en` | `large/043.json` | 2.8 MB | `locales.global.en` |
| locations | `/client/locations` | `large/134.json` | 1.7 MB | `locations.<name>.base` |
| globals | `/client/globals` | `large/084.json` | 913 KB | `globals` |
| customization | `/client/customization` | `large/046.json` | 587 KB | `templates.customization` |
| quests | `/client/quest/list` | `large/444.json` | 526 KB | `templates.quests` |
| handbook | `/client/handbook/templates` | `large/082.json` | 446 KB | `templates.handbook` |
| settings | `/client/settings` | `large/037.json` | 387 KB | `settings.config` |
| traders | `/client/trading/api/traderSettings` | `responses/071.json` | 39.7 KB | `traders.<id>.base` |
| one map, in full | `/client/match/local/start` | `responses/158.json` | 115 KB | `locations.sandbox.base` |
| dialogue | `/client/dialogue` | `large/076.json` | 13.3 MB | *nothing — SPT has no equivalent* |

The database side is `build/db/db.json`, 41,313,127 bytes, imported from
`D:\SPT` on 2026-08-19 — the same file [IMPORTDB.md](IMPORTDB.md) describes.
The route for each `seq` is `data/capture/raid1/manifest.json`; every number
below was produced by reading those two files, not by recall.

**`responses/158.json` is why this document does not repeat an easy mistake.**
`/client/locations` is a *trimmed* map list — it drops 23 fields that a map's
base actually has. Diffing only against it reports twenty-three fields as
"removed post-1.0", including `GlobalLootChanceModifier`, which `emu/loot`
reads. `/client/match/local/start` carries the same map's base in full, and all
23 are in it. The location comparison below is against the union of the two.

## 1. Items

```
SPT templates.items   4,673
BSG /client/items     5,827
```

| | count |
|---|---:|
| ids in both | **4,673** |
| in BSG, not in SPT (new post-1.0) | **1,154** |
| in SPT, not in BSG (removed) | **0** |
| of the 4,673 common, `_props` identical | **1** |
| `_props` differ only by post-1.0 boilerplate | **1,718** |
| `_props` differ substantively | **2,954** |

Not one pre-1.0 template was deleted. `_type` is unchanged on all 4,673;
`_parent` moved on exactly one (`67586b7e49c2fa592e0d8ed9`,
`item_barter_other_saladbox`, from `Other` to `Item`); `_name` on five.

### The boilerplate

Three properties account for the 1,718, and appear in almost every other diff
as well:

| property | items | direction |
|---|---:|---|
| `IsNotDeletableFromQuestStashAfterQuestComplete` | 4,672 | **new** in post-1.0 |
| `RagfairLevelToTrade` | 4,672 | **new** in post-1.0 |
| `DropSoundType` | 4,577 | **gone** in post-1.0 |
| `CategoryAnimationModId` | 2,044 | **new** in post-1.0 |

`DropSoundType` is **the only item property post-1.0 removed** — 461 distinct
property names in the SPT data, 493 in BSG's, and the SPT-only set has exactly
one member. Nothing in `mods/tarkov` reads it (§6).

### The substantive changes

Ranked by how many templates each touches, excluding the four above:

| property | items changed | what it is |
|---|---:|---|
| `Slots` | 1,240 | mounting points and their compatibility filters |
| `Ergonomics` | 1,052 | median \|Δ\| 3.0, max 45 |
| `Recoil` | 628 | median \|Δ\| 2.0, max 17 |
| `DiscardLimit` | 324 | median \|Δ\| 1, max 80,000 |
| `CanSellOnRagfair` | 272 | flea eligibility |
| `StackMaxSize` | 247 | median \|Δ\| 20, max 50 |
| `ConflictingItems` | 242 | |
| `RepairCost` | 230 | median \|Δ\| 190, max 859 |
| `WeaponAimSettings` | 177 | **new property**, weapons only |
| `AudioSettings` | 177 | **new property**, weapons only |
| `RicochetParams` | 174 | |
| `Velocity` | 155 | median \|Δ\| 3.34, max 53 |
| `Chambers` | 147 | |
| `Weight` | 144 | median \|Δ\| 0.20 kg, max 9.65 kg |
| `ItemSound` | 143 | |
| `Name` / `ShortName` / `Description` | 135 each | the untranslated key strings |
| `LoadUnloadModifier` | 135 | |
| `RarityPvE` | 130 | |
| `CheckTimeModifier` | 129 | |
| `MaskSize` / `FaceCoverMask` | 124 / 120 | **new**, face covers |

`Slots` is the largest number and the least alarming one. Of the 1,180
templates whose `Slots` array differs, **545 differ only by two new booleans**
BSG added to every slot object, `_isPatronSlot` and `_isPlateSlot`. Of the
remaining 635, **628 gain filter entries and 10 lose any** — that is post-1.0
declaring the 1,154 new attachments compatible with weapons that already
existed. It is not a restructuring; the slot object and the filter object have
identical key sets on both sides.

The one type change across 4,673 × ~460 properties is
`544fb37f4bdc2dee738b4567` (painkiller): `effects_health` went from
`{"Hydration":{"value":-19}}` to `[]`. Both shapes already coexist in both
datasets (SPT: 48 objects / 424 empty arrays; BSG: 52 / 460), and `emu/health`
reads it by path, so it degrades to "no effect" rather than to a crash.

### Change size, per template

| properties changed | templates |
|---|---:|
| 0 | 1 |
| 1–2 | 0 |
| 3–5 | 3,372 |
| 6–10 | 1,179 |
| 11–25 | 26 |
| 26+ | 95 |

The 3,372 in the 3–5 band are the boilerplate band. **The 95 at the top are all
`_type: Node`** — the abstract prototypes (`Weapon`, `Meds`, `AmmoBox`,
`SpecialWeapon`, `Equipment`) — and they are not a post-1.0 change at all:
SPT's export strips a Node's inherited defaults, so `SpecialWeapon` has 0
properties in SPT and 169 in BSG's. The client resolves prototypes from the
leaf, so this has never mattered; it is listed because it would otherwise look
like the worst regression in the table.

The single template that is byte-identical is `6050cac987d3f925bf016837`.

### The 1,154 new templates

1,148 are `Item`, 6 are `Node`. Grouped by parent:

| parent | new | | parent | new |
|---|---:|---|---|---:|
| `RandomLootContainer` | 319 | | `Barrel` | 25 |
| `Notes` | 82 | | `Vest` | 25 |
| `Handguard` | 74 | | `Headwear` | 24 |
| `Stock` | 46 | | `Keycard` | 18 |
| `Info` | 41 | | `Tapes` | 18 |
| `Mount` | 40 | | `Flyer` | 18 |
| `Other` | 37 | | `FlashHider` | 15 |
| `BuiltInInserts` | 32 | | `PistolGrip` | 15 |
| `Jewelry` | 28 | | `SpecItem` | 15 |

Representative examples, by `_name`:

```
68a63ac58e1fe612970728f2  barrel_ar15_colt_m16_std_508mm
68c294800f5ebd68290d6c20  barrel_nl545_cgnl_292mm_545x39
6a3cea4494a96a17e00c4b69  barrel_type20_howa_330mm_556x45
6a3cf2f17047a606b90f532e  charge_type20_howa_type20_std
6a1d4dae46b486ac34084778  charge_ar15_hk_extended_latch_charging_handle_ral8k
68124640c5fd00ec0a01a237  gas_block_mcx_sig_mcx_mid_piston
6a157b9e5ef5195441036c12  handguard_416_geissele_smr_hk_105_inch
682315bdf8d8f8681e0744b5  handguard_ak12_tactical_ideas_n4_ak12_mlok
6932aed9be542622170428b0  handguard_ar10_kac_sr25_urx_31_135_inch
67c542c126265106dd0697ab  handguard_m1895_marlin_mxlr_std
6812180dc20f5c52bc04d6cc  handguard_mcx_lancer_oem_gen1_12_inch_mlok
69f9f111df2c2358a904186f  handguard_qbz191_norinco_191_polymer_std
680f55788692125dc00a3354  handguard_mdr_blk_lbl_alx_20_inch_bipod_mlok_blk
6a16f3711c209e26040a5410  foregrip_all_dd_vfg
69d42490d91a53e51e0f940e  gladiator_s_level3_soft_armor_groin_front
69cf9696b96c8e8d3e002925  item_equipment_armor_redut_m_black_custom_bp03
68f263f099d2172e150d7ff8  item_equipment_head_cap_eft_coyote
6a31807f17005505b70d5827  Item_barter_info_finance
6a3182b72fd891345e047eef  Item_barter_info_user
68f25c64b2b53abd200b954f  Item_barter_tarko_prapor
68f25ce9b2b53abd200b9551  Item_barter_tarko_therapist
664b81bfa322b5b99a037a03  Completable            (Node)
69f071ae35c3b5e6dd00df07  VolumetricThrowWeapon  (Node)
```

Two whole categories are post-1.0 mechanics with no pre-1.0 template at all:
the Marlin lever-action, QBZ-191, Type 20 and NL-545 weapon families and their
furniture; and the `Notes` / `Tapes` / `Flyer` / `Info` readables (159
templates) that feed the new collectible-document system.

**None of the 1,154 has an English name in the SPT locale** — 0 of 1,154 have
an `<id> Name` key in `locales.global.en`. All but 6 have one in BSG's locale.
That is the mechanism behind the "31 templates render as their id" row in
[BACKLOG.md](BACKLOG.md), scaled up: importing the new items without the new
locale would produce 1,154 more of them.

## 2. Structural schema differences

### Items

| | |
|---|---:|
| distinct `_props` keys, SPT | 461 |
| distinct `_props` keys, BSG | 493 |
| SPT-only | **1** (`DropSoundType`) |
| BSG-only | 33 |
| type changes across all common props | **1** (`effects_health`, one item) |

Top-level item keys are identical on both sides (`_id`, `_name`, `_parent`,
`_props`, `_type`, `_proto`). Nested objects — slot objects, filter objects,
`Grids`, `Cartridges`, `StackSlots` — have identical key sets except that slot
and chamber objects gained `_isPatronSlot` and `_isPlateSlot`.

### Locations

Against `/client/locations` **plus** the full base in
`/client/match/local/start`:

| | |
|---|---:|
| SPT base field union | 106 |
| BSG base field union | 116 |
| **SPT-only (removed post-1.0)** | **0** |
| BSG-only (new post-1.0) | 10 |
| type changes | 0 |

New in post-1.0:

```
FixedLocationWeatherSettings   PasscodeLocationSettings
ForceOfflineRaidInPVE          ProfileProgressOptions
HiddenWhenLockedByQuest        SavageForceOfflineRaidInPVE
HighLevelLocationId            SavageForceOnlineRaidInPVE
LockedByQuest                  access
```

`LockedByQuest` / `HiddenWhenLockedByQuest` / `access` are the quest-gated map
mechanic (Labyrinth, Terminal); `HighLevelLocationId` is the
`Sandbox` → `Sandbox_high` pairing. The emulator serves whatever `base` holds,
so a client that reads these gets `undefined` and falls back — a missing
feature, not a wrong answer.

Values do move. On Woods: `EscapeTimeLimit` 40 → 35, `BotMax` 30 → 22,
`waves` 16 → 2 entries, `BossLocationSpawn` 12 → 4. `SpawnPointParams` is 368
on both sides.

### Globals

| | |
|---|---:|
| SPT `config` keys | 107 |
| BSG `config` keys | 119 |
| SPT-only, top level | **0** |
| BSG-only, top level | 12 |
| type changes | **0** |
| SPT-only, at any depth | **1** |

New top-level `config` members: `BattlePassUniversalDocument`,
`ExtensionsSettings`, `FinalConsequenceSettings`, `FinalMissionSettings`,
`GroupQuestSetting`, `KolotunSettings`, `MatchMakerEstimateSettings`,
`MaxMatchingTimeInSeconds`, `PasscodeSettings`, `SteamStatusSettings`,
`Tutorial`, `WishlistSettings`.

Walking the whole tree to depth 4 finds **64 deltas and exactly one of them is
a removal**: `config.RunddansSettings.initialFrozenDelaySec`. Nothing in
`mods/tarkov` reads it. The other 63 are additions — the new tear-gas health
effects, 27 new scav customization entries, `RagfairMinUserLevelByCategory`,
`QuestSettings.Chapters`, `exp.ExpByGameEditionMultiplier`, two new
`SkillsSettings.Throwing` fields, and camera-shake parameters on artillery.

`globals` also gained one top-level sibling,
`InventoryTarcoinMigrationProdAllowedAids`. `ItemPresets` went 399 → 460 (61
new, none removed); `bot_presets` 28 → 36.

### Quests

**`/client/quest/list` is not the quest database.** BSG's response carries 22
quests; SPT's `templates.quests` carries 558. Seven ids are in both. This
endpoint returns the quests *this account can currently see*, and the capture
is one account four hours old. Every count in the table below is therefore a
count about the shape, not about the corpus.

| | |
|---|---:|
| SPT quests | 558 |
| BSG quests, in this capture | 22 |
| in both | 7 |
| quest fields SPT-only | **1** (`QuestName`) |
| quest fields BSG-only | 9 |

BSG-only fields: `icon`, `inBufferZoneOnly`, `isStoryQuest`, **`localization`**,
`mailSettings`, `notDisplayedQuest`, `notes`, `rewardsInfo`, `tierAccessory`.

**`QuestName` → `localization` is the one real schema change in this
document.** Post-1.0 quests carry every language inline:

```json
"name":        "5d24b81486f77439c92d6ba8 name",
"localization": { "ch": { "5d24b81486f77439c92d6ba8 name": "熟人", ... }, ... }
```

where pre-1.0 carried a human-readable `QuestName` and left the client to look
the key up in `/client/locale/<lang>`. The keys are the same strings, so an
SPT-derived quest served with a populated locale table still resolves; what it
loses is the per-quest override. `emu/questcond.questName` already reads
`QuestName` with a `name` fallback (`mods/tarkov/emu/questcond.nim:849-852`),
so it survives either shape — which is luck, not design, and worth keeping.

Condition and reward vocabularies diverge, but with 22 quests on one side that
is a sampling artefact, not a schema finding. The one entry that is not:
`CompletableItem` is an `AvailableForFinish` condition type post-1.0 uses and
SPT's 558 quests never do; `LocationUnlock` and `TraderDialogueUnlock` are
reward types with no pre-1.0 occurrence.

### Traders, handbook, customization, settings

| table | SPT | BSG | new | removed | schema change |
|---|---:|---:|---:|---:|---|
| traders (`base`) | 12 | 18 | **6** | 0 | **none** — 33 fields, identical sets |
| handbook `Items` | 4,288 | 5,066 | 779 | 1 | none |
| handbook `Categories` | 87 | 90 | 3 | 0 | `+RagfairLevelToTrade` |
| customization | 728 | 969 | **241** | 0 | `+HiddenByDefault`, `+ProfileVersionsIgnoresSide`, `+ShopCustomizationUrl` |
| `settings.config` | 31 | 35 | 4 | 0 | none removed |
| locale `en` | 31,550 | 33,323 | **8,545** | — | n/a |

New settings keys: `CollectLoadTimeMetrics`, `KeepAliveStaticInterval`,
`LobbyConnectionPercentage`, `SteamSyncCooldownSeconds`.

774 of the 779 new handbook entries are the new item templates, so the two
tables agree with each other.

**Prices moved on 504 of the 4,287 common handbook entries (11.8%).** The flea
is priced off the handbook by deliberate choice ([IMPORTDB.md](IMPORTDB.md)),
so this is the emulator's economy being 12% wrong on one axis.

The locale is the sharpest number in the document. 24,778 keys are in both, and
**24,399 of them (98.5%) have identical text**. The gap is 8,545 keys the
post-1.0 client asks for that pre-1.0 has no string for, and 6,772 pre-1.0 keys
post-1.0 dropped.

Six new traders:

```
67f7af56c117b6140af2a607  Player Trader
688246518448b05efd61d461  Mr. Kerman
688246958448b05efd61d462  Воевода
68fe15910f29ba3fdbba9d54  Таран
68fe15990f29ba3fdbba9d55  Радиостанция
69e0d6cc77b63940375b9173  Ученый
```

All six are loyalty-level-1, `unlockedByDefault: false`. The emulator's 12 are
all present in BSG's 18 with the same 33-field base shape.

### `/client/dialogue` — a table with no pre-1.0 equivalent

13.3 MB, 140 elements, each `{Id, IsStart, MainVariable, Trader, SubTraders,
Lines, StartPoints, localization}`. This is post-1.0's branching trader
dialogue. SPT has no counterpart: its `traders/<id>/dialogue.json` (4 traders)
is the insurance-message locale ids `emu/dialogue` reads, and
`templates/dialogue.json` is SPT's own chat-command machinery, which the
importer does not read. `emu/post1.nim:17-21` already names this as
deliberately absent.

## 3. Locations, in detail

The client's own list is authoritative: `raid/configuration`
(`data/capture/raid1/requests/156.json`, `onlinePveRaidStates`) names **24
maps**, and `/client/locations` returns **exactly those 24**. The emulator's
database has **19**.

| BSG `Id` | `_Id` | in `db.json` | `Enabled` |
|---|---|---|---|
| bigmap | `56f40101d2720b2a4d8b45d6` | `bigmap` | true |
| develop | `56db0b3bd2720bb0678b4567` | `develop` | false |
| factory4_day | `55f2d3fd4bdc2d5f408b4567` | `factory4_day` | true |
| factory4_night | `59fc81d786f774390775787e` | `factory4_night` | false |
| hideout | `599319c986f7740dca3070a6` | `hideout` | false |
| Interchange | `5714dbc024597771384a510d` | `interchange` | true |
| **Labyrinth** | `6733700029c367a3d40b02af` | `labyrinth` | false |
| laboratory | `5b0fc42d86f7744a585f9105` | `laboratory` | true |
| **laboratory_dark** | `6a294a5b5eb5f9a1700417b7` | **absent** | true |
| Lighthouse | `5704e4dad2720bb55b8b4567` | `lighthouse` | true |
| **Lighthouse2** | `6167f1b7948c017d936e882b` | **absent** | false |
| **Icebreaker** | `69af492a4819ea4ba10a69c5` | **absent** | true |
| Private Area | `5704e64ad2720bb55b8b456e` | `privatearea` | false |
| RezervBase | `5704e5fad2720bc05b8b4567` | `rezervbase` | true |
| Sandbox | `653e6760052c01c1c805532f` | `sandbox` | true |
| **Sandbox_high** | `65b8d6f5cdde2479cb2a3125` | `sandbox_high` | true |
| **Sandbox_start** | `68236e8153654e8c1200798a` | **absent** | true |
| Shoreline | `5704e554d2720bac5b8b456e` | `shoreline` | true |
| **Suburbs** | `5714dc342459777137212e0b` | `suburbs` | false |
| TarkovStreets | `5714dc692459777137212e12` | `tarkovstreets` | true |
| **Terminal** | `65cc8f81a9aac3e77d0cfd3e` | **id mismatch** | false |
| **Terminal_ui** | `6925a2c38bdebd9e2302692e` | **absent** | true |
| Town | `5704e47ed2720bb35b8b4568` | `town` | false |
| Woods | `5704e3c2d2720bac5b8b4567` | `woods` | true |

Of the five names the brief flagged, **four are already in the database**:
`Labyrinth`, `Suburbs`, `Sandbox_high` and — nominally — `Terminal`. Only
`Icebreaker` is missing outright.

**`Terminal` is the interesting one.** `db.json` has a `terminal` directory
whose `base._Id` is `5704e5a4d2720bac5b8b4567`; post-1.0's Terminal is
`65cc8f81a9aac3e77d0cfd3e`. SPT's is a pre-1.0 placeholder that post-1.0
re-issued under a new id. `emu/raid.canonicalLocation` resolves by name *and*
by `_Id` (`mods/tarkov/emu/raid.nim:206-220`), so a client asking for
`Terminal` by name still lands; a client asking by the post-1.0 `_Id` finds
nothing and gets the empty-map fallback. Terminal is `Enabled: false` upstream,
so this has not been reachable.

Four maps have no pre-1.0 existence at all: `Icebreaker`, `Sandbox_start` (the
new tutorial — and the only map in the capture whose full base was observed),
`Terminal_ui` and `laboratory_dark`. `Lighthouse2` is a post-1.0 variant.
All four of the new ones are `Enabled: true`; `Lighthouse2` is not.

Every one of the 19 the emulator has is also in BSG's list, at the same `_Id`,
except Terminal. Nothing was dropped.

### `paths` is empty and BSG's has 18

BSG's `/client/locations` returns `{locations, paths}` with **18 transit
edges** — `{Source, Destination, Event}` with `_Id`s at both ends, e.g.
Sandbox → TarkovStreets, laboratory → TarkovStreets.

`emu/raid.locationsBody` reads `locations.paths` and falls back to `[]`
(`mods/tarkov/emu/raid.nim:188-189`), and the importer does not populate it —
SPT keeps the graph in `database/locations/base.json`, which
[IMPORTDB.md](IMPORTDB.md) lists as not imported. So the emulator ships an empty
transit graph today. **This is the one table in the capture that fills a hole
the emulator already knows it has**, and it is 18 objects.

## 4. Every property the emulator reads that post-1.0 no longer provides

This was the part of the exercise with immediate bug value, so it was done
mechanically rather than by eye. All 516 distinct string literals reached
through `field(...)`, `hasField(...)`, `sub(...)` and `dbRead(...)` in
`mods/tarkov/emu/*.nim` and `mods/tarkov/tarkov.nim` were extracted and
intersected against the key universe of `db.json` (44,252 distinct keys) and of
the entire capture (11,520 distinct keys across all 220 responses).

**The answer is: none.**

The removals post-1.0 actually made, in full, and what reads them:

| removed | table | read by `mods/tarkov`? |
|---|---|---|
| `DropSoundType` | item `_props`, 4,577 items | **no** — appears nowhere in `emu/` or `tarkov.nim` |
| `config.RunddansSettings.initialFrozenDelaySec` | globals | **no** |
| `QuestName` | quest | **yes**, `emu/questcond.nim:849` — but with a `name` fallback at `:852`, and post-1.0 supplies `name` |

Nothing else was removed anywhere: locations 0, traders 0, handbook items 0,
customization 0, settings 0, globals 0 at top level.

Two candidates were investigated and cleared, and both are worth recording
because each looked like a live bug for a while:

- **`emu/loot.nim:1020` — `b.field("GlobalLootChanceModifier")`**, read off the
  location base. It is absent from `/client/locations`, which is what made it
  look removed. It is present in the full base in
  `/client/match/local/start` (`responses/158.json`). **Not a bug.** Its sibling
  `GlobalContainerChanceModifier` at `:1019` is in both payloads.
- **`emu/health.nim:241` — `effects_health.<factor>.value`**, documented at
  `emu/health.nim:22`. Post-1.0 changed one item (painkiller) from object to
  empty array. Both shapes are present in both datasets; the read is by path
  and answers "absent" on the array form. **Not a bug**, but the only place in
  the codebase where a post-1.0 type change touches a live reader, so it is the
  one to re-check if more items follow.

A further 58 emulator field literals are in `db.json` and in no captured
response. **Every one of them is a table the real backend never sends a client**
— bot templates (`inventory`, `mods`, `chances`, `generation`, `appearance`,
`firstName` in `emu/bots.nim`), loose-loot distributions (`itemDistribution`,
`relativeProbability`, `probability` in `emu/loot.nim`), and the repeatable-quest
config (`resetTime`, `numQuests`, `rewardScaling`, `traderWhitelist`, the
`min*`/`max*` bands in `emu/repeatable.nim`). Their absence from the capture is
the expected absence of server-side machinery, not a schema change, and it is
the single most important constraint on §5.

## 5. Recommendation

**Layer, do not replace. And take five tables, not eleven.**

The comparison does not support a rewrite of the importer. The pre-1.0 database
is not stale in the way it was feared to be: no template was deleted, no field
the emulator reads was removed, the schema is additive in every table but
quests, and 98.5% of the shared locale strings are byte-identical. What the
capture buys is coverage of things that did not exist yet, and correction of
numbers that drifted.

Against that, the capture has two limits that no amount of care removes.

**It is one account's view.** These responses are not all database tables:

- **`/client/quest/list` is profile-specific.** 22 quests against SPT's 558.
  Taking it wholesale deletes 536 quests. It cannot be used as a quest source
  at all, only as evidence about quest *shape*.
- **`/client/dialogue` is trader-scoped** and its 140 elements are the trees
  this account has reached.
- **`/client/customization/storage`, `/client/game/profile/*`, `/client/mail/*`,
  `/client/hideout` progress and `/client/match/local/start`'s `profile` member**
  are per-account and are not tables.
- **`/client/items`, `/client/globals`, `/client/handbook/templates`,
  `/client/customization`, `/client/settings`, `/client/locale/en`,
  `/client/locations` and `/client/trading/api/traderSettings` are general.**
  Same bytes for every account.

**It is one moment.** Live-service data is re-tuned every patch. Anything taken
from it is pinned to 1.1.0.1.46777 and to the day it was captured, and there is
no mechanism to refresh it — the next capture is another decryption session.
SPT's database, whatever its age, gets updated by other people.

**And the capture is missing the half the emulator most depends on.** The 58
literals in §4 are the load-bearing ones: bot generation, loose loot, static
containers, static ammo, trader assorts, hideout recipes, repeatable-quest
budgets. The real backend computes those server-side and never sends them. A
database built from the capture would serve a client with 5,827 beautifully
current items and no bots, no floor loot and nothing to buy.

### What to take, and what it costs

**Safe wholesale — general tables, additive schema, no reader touches them in a
way post-1.0 broke:**

| table | change | effort |
|---|---|---|
| `locations.paths` | 18 edges, currently `[]` | **one line in the importer, or a `data/post1/` file.** `emu/raid` already reads the path. Highest value per byte in this document. |
| `locales.global.en` | +8,545 keys, merged under SPT's | small; a merge, not a replace — the 6,772 SPT-only keys stay |
| `globals` | 12 new `config` members, +61 `ItemPresets`, +8 `bot_presets` | small; drop `RunddansSettings.initialFrozenDelaySec` or keep it, nothing reads it |
| `settings.config` | 4 new keys | trivial |
| `templates.customization` | +241 suites | trivial; `emu/customise` makes everything wearable already |

**Take with care — overlay, and only where it is checkable:**

| table | change | effort |
|---|---|---|
| `templates.items` | +1,154 templates, ~2,954 rebalances | **this is the real work.** The 1,154 new templates are safe to add *only together with* their locale keys, their 774 handbook rows, and the 628 slot-filter updates that make existing weapons accept them — otherwise they are unnamed items nothing can mount. The 2,954 property rebalances are safe but invisible: nobody will notice Ergonomics moving by 3, and every one is a value the emulator does not verify. Do the additions; treat the rebalances as optional. |
| `templates.handbook` | +779 rows, 504 price changes | the 779 rows come with the items. The 504 prices are a live economy change and the flea reads them; take them or do not, but do not take half. |
| `traders.<id>.base` | +6 traders | **base only.** The capture has no assort for the six, so they would be traders with nothing to sell. Better as a known gap than as six empty shops. |
| `locations.<map>.base` | +5 maps, +10 fields | `Sandbox_start` is the only one whose full base was captured. `Icebreaker`, `Terminal_ui`, `laboratory_dark`, `Lighthouse2` appear only in the trimmed list — no `SpawnPointParams`, no `exits`, no `waves`. A map with no spawn points is not a map. **Do not import these**, and fix `terminal`'s `_Id` from `5704e5a4d2720bac5b8b4567` to `65cc8f81a9aac3e77d0cfd3e` instead, which is one value. |

**Must stay SPT-derived, permanently:**

`bots.*` · `locations.<map>.looseLoot` / `staticLoot` / `staticContainers` /
`staticAmmo` · `traders.<id>.assort` / `questassort` · `hideout.*` ·
`templates.quests` · `templates.repeatableQuests` · `configs.quest`.

The backend does not send any of them. There is nothing to import.

### What the importer change would look like

`tools/importdb.nim` reads a directory of SPT JSON and writes `db.json`. The
smallest change that delivers the safe set is a **second, optional source**:

```
aowl importdb --from D:\SPT --post1 mods\tarkov\data\capture\raid1
```

with a per-table merge policy rather than a global one — union for
`locales.global.en` and `globals.config`, append-if-absent for
`templates.items` and `templates.handbook.Items`, straight replace for
`locations.paths` and `settings.config`. `checkReadPaths`
(`tools/importdb.nim:669`) already asserts the 29 paths `mods/tarkov` reads
against the produced database, so a merge that drops a table fails loudly.

That is a day's work for `paths` + locale + globals + settings + customization,
and a second day for the item/handbook/slot-filter overlay, which needs its own
check: *every new template has a locale name, a handbook row, and appears in at
least one slot filter or is a root item*. Without that check the overlay is
1,154 items nobody can see or attach.

**But the honest first move is smaller than either.** `data/post1/` already
exists for exactly this — BSG's own answers, checked in per table, loaded by
`emu/post1.nim`. `locations.paths` is 18 objects and roughly 2 KB. It fills a
gap [BACKLOG.md](BACKLOG.md) already names, it needs no importer change at all,
and it is the one thing in 41 MB of decrypted data that the emulator is
currently answering wrongly rather than answering partially.

Everything else in this document is the pre-1.0 database being **more right
than anyone expected**, and it should be said plainly: one property removed,
one field renamed with a fallback already in place, and zero live bugs.
