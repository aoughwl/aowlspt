# Escape from Timbuktu: the procedural story and world layout

The pillar this file designs: **a seed produces a world.** Which factions exist,
who hates whom, where the story's key things are, who is holding them, what
"escape" means this run, and a quest graph that can actually be finished.

Everything below is labelled the way the rest of this repository labels things.
**Verified** means this session read it out of the tree or out of
`D:\Aowlspt\aowlspt\db.json` (41,313,127 bytes) and can name the file and line.
**Argument** means reasoning from data nobody has run against BSG's client.
**Unknown** means exactly that.

The short version, for a reader who stops here:

* The generator can build a story out of **quests, mail, traders, trader
  standing, loot placement, boss placement and deploy gating**. That is a real
  story and it is a large one.
* It **cannot** build geography. No new maps, no new edges between maps, no
  placement of anything at a coordinate. The reason is spelled out in
  [What is not reachable](#what-is-not-reachable) and it is not a matter of
  effort.
* Its vocabulary is **a harvest of the shipped database, never an invention.**
  That single rule is what makes generated content work in a client nobody here
  can test against.

---

## 1. What exists today

### 1.1 The seeded RNG, and what it actually guarantees

`mods/tarkov/emu/rand.nim` — 5.3 KB, no dependencies, and it is the only source
of randomness in the emulator by deliberate policy (its own module comment says
so, and `emu/ids.nim` explains why).

| proc | guarantee |
|---|---|
| `hashText(s)` | FNV-1a over the bytes. A seed is derived from the *text* of an id, not a parse of it |
| `seededRng(seed: string)` / `seededRng(seed: uint64)` | **never returns the zero state** — xorshift's fixed point, which would produce a world where every roll is identical |
| `nextU64` | xorshift64\*, period 2^64−1, multiply on the way out so the low bits are not a counter |
| `nextInt(r, bound)` | `[0, bound)`. **Returns 0 for `bound <= 1`**, which is a real answer for an empty pool and a trap for a caller that does not check. Modulo bias left in, ~2^-55 at these bounds |
| `nextFloat` | `[0,1)` from the top 53 bits |
| `chance(r, p)` | clamped, so `p >= 1.0` means always and `p <= 0.0` means never |
| `pickWeighted(r, weights)` | **returns −1** for an empty pool or all-zero weights. The docstring says why: spawning element zero of an empty distribution is how a map ends up carpeted in whatever sorts first |
| `mongoId(r)` | a 24-hex id **out of the seeded stream**, not `emu/ids.newId` — which is what makes a generated document a pure function of its seed |

The property that matters to this pillar: `Rng` is an **object, not a global**.
Two subsystems seeded from the same world seed do not interleave and do not
perturb each other. That is the precondition for domain-separated substreams,
which is what section 3.1 is built on.

### 1.2 The existing generator, which is the precedent

`mods/tarkov/emu/repeatable.nim` (42 KB) already does procedural quest
generation, in production, and it establishes every pattern this pillar should
copy:

* **Derive, do not store.** A set's quests are a pure function of
  `(profile id, set name, period)` where `period = now div resetTime`. There is
  no "today's dailies" record to write, migrate or lose (module comment, lines
  25–41). The only stored thing is a *choice the player made* — a reroll count —
  under `repeat.<profileId>`.
* **Domain-separated seeds.** `slotSeed(profileId, setName, period, slot, bump)`
  at repeatable.nim:670, then `seededRng(seed & ":pick")` at :712 for the type
  and trader draw and `seededRng(seed)` at :534 for the quest body. Two streams
  off one seed, separated by a suffix.
* **One integration seam, and it already exists.**
  `quests.questTemplate*(p: Profile; qid; nowSeconds)` at
  `mods/tarkov/emu/quests.nim:88-106` asks the database first
  (`dbRead("templates.quests." & qid)`, :83) and falls back to
  `repeatable.questTemplateFor` (:793). Everything downstream — accept,
  handover, complete, the condition evaluator, the reward payout — is the code
  that was already there and already tested. A generated quest is *an ordinary
  quest whose template happens to be computed*.
* **Where the data does not decide something, say so.** Four places in that file
  are marked *(unverified)* rather than having a rule invented and then read
  back as fact.

If this pillar produces one sentence of guidance for whoever implements it, it
is: **be `emu/repeatable.nim`, one size up.**

### 1.3 The condition vocabulary the emulator actually evaluates

`mods/tarkov/emu/questcond.nim`. `condKind` (:72) accepts **both** spellings —
flat `conditionType` and nested `_parent`+`_props` — so either will parse. The
shipped database uses `conditionType` on **0 of 2636** conditions carrying
`_parent`; the brief's assumption of `_parent` is a property of older SPT dumps,
not of this one.

**Fully evaluated, property-based** (`evaluate`, questcond.nim:337-416):

`Level` · `Quest` · `TraderLoyalty` · `TraderStanding` · `Skill`

**Evaluated as "a counter reached its value"** (`isProgressKind`,
questcond.nim:304-312 — this is the literal list):

`CounterCreator` · `HandoverItem` · `FindItem` · `LeaveItemAtLocation` ·
`PlaceBeacon` · `WeaponAssembly` · `VisitPlace` · `UseItem` · `HealthEffect` ·
`Shots` · `SellItemToTrader`

Of these, **only `CounterCreator` has a server-side derivation**
(`killCredit`, questcond.nim:680+). The other ten are satisfied only by the
client's own `TaskConditionCounters`, handed back in the raid result and merged
at quests.nim:588 with "larger wins". That distinction is the single most
important constraint on this pillar and section 4.2 is built on it.

**Counter sub-conditions the server can decide** (`killCredit` dispatch,
questcond.nim:697-755):

* `Kills` — against `Stats.Eft.Victims`, checking `target` (side: `""`/`Any`,
  `AnyPmc` → Usec|Bear, `Savage`, or a literal), `savageRole` vs `Victim.Role`,
  `bodyPart`, `distance` vs `Victim.Distance`, and `daytime` against the raid
  clock.
* `Location` — against the raid's map. A miss is **verified no**, credit 0.
* `ExitStatus` — against the raid's exit status. Same.
* **Anything else zeroes the credit** and is named in the warning
  (`"a " & k & " sub-condition"`, :752).

Qualifiers that are read and refused by name: `weaponModsInclusive/Exclusive`,
`weaponCaliber`, `equipmentInclusive/Exclusive`,
`enemyEquipmentInclusive/Exclusive`, `enemyHealthEffects`. A condition carrying
one of those credits **nothing**, deliberately — crediting a kill whose
qualifier could not be checked hands out progress that was not earned.

**Unknown condition kinds pass.** `isChecked` (:314) returns false and
`evaluate` returns **true** (:397-400), with `groupMet` counting them into an
`unchecked` out-param. So an invented condition type is not a wall, it is a
no-op — which is worse, because it silently makes a quest trivial. The generator
must never emit a kind outside the lists above.

**Rewards actually applied** (`grantRewardList`, quests.nim:220-267):
`Experience`, `TraderStanding` (with an explicit `target`, so **cross-trader
penalties work**), `Item` (re-id'd by `freshIds` at :140 and delivered as *mail
attachments*, never straight to the stash), `TraderUnlock`.
Read, named and **not applied**: `AssortmentUnlock`, `Skill`, `StashRows`,
`ProductionScheme` (:255-260). Reward buckets are `rewards.Started`,
`rewards.Success`, `rewards.Fail`.

**Statuses** (`statusCode`, questcond.nim:166-181): `Locked` 0,
`AvailableForStart` 1, `Started` 2, `AvailableForFinish` 3, `Success` 4,
`Fail` 5, `FailRestartable` 6, `MarkedAsFailed` 7, `Expired` 8,
`AvailableAfter` 9. Condition groups: `AvailableForStart`,
`AvailableForFinish`, `Fail`.

`unlockFollowUps` (quests.nim:176-218) walks the whole `templates.quests` table
on each completion and flips to `AvailableForStart` every quest whose
`AvailableForStart` group contains a `Quest` condition naming the one just
finished. **That is the DAG edge.** It is already implemented; the generator
does not need a graph runtime, it needs to emit `Quest` conditions.

### 1.4 The database, verified rather than trusted

Loaded from `D:\Aowlspt\aowlspt\db.json`, 9 top-level keys:
`templates`, `globals`, `settings`, `configs`, `locales`, `traders`, `hideout`,
`locations`, `bots`.

| the brief's claim | verified | path |
|---|---|---|
| 558 quests | **558** ✓ | `templates.quests`, keyed by quest `_id` |
| 4673 item templates | **4673** ✓ | `templates.items` |
| 19 maps | **19** ✓ | `locations`, keyed by SPT directory name |
| 12 traders | **12** ✓ | `traders` |

All four numbers are right. Alongside them: `templates.handbook.Items` 4288,
`templates.handbook.Categories` 87, `locales.global.en` 31,550 strings,
`bots.types` 57 roles, `templates.achievements` 53, `hideout.areas` 28,
5790 trader assort items.

**Quest shape.** Keyed by quest id, **not** by trader — the trader is the
`traderId` field. Per-trader counts: Mechanic 105, Jaeger 78, Prapor 77,
Skier 70, Ragman 58, Therapist 57, Peacekeeper 52, Fence 16, caretaker 15,
БТР 15, Arena 15, **Storyteller 0**. `side` is `Pmc` on all 558 — there are no
scav-side quests to imitate. `location` is `"any"` on 281 and a map `_Id`
otherwise.

2636 conditions: `AvailableForFinish` 1606, `AvailableForStart` 972, `Fail` 58.
The top ten by type: `Quest` (start) 736, `CounterCreator` 609, `HandoverItem`
413, `FindItem` 269, `Level` (start) 224, `LeaveItemAtLocation` 149,
`PlaceBeacon` 96, `Quest` (fail) 38, `WeaponAssembly` 32, `CounterCreator`
(fail) 17.

918 counter sub-conditions: `Kills` 283, `VisitPlace` 212, `Location` 208,
`ExitStatus` 109, `InZone` 32, `Equipment` 26, `ExitName` 12, `LaunchFlare` 8,
`ArenaGameMode` 7, `ArenaMatchPlace` 7, `HealthEffect` 5, `Shots` 3,
`HealthBuff` 2, `UseItem` 1, `UnderArtilleryFire` 1, `Time` 1,
`ArenaPlayerInTeamPlace` 1. (283 `Kills` is the same figure
`questcond.killCredit`'s own comment quotes, so that comment was measured
against this database.)

**Rewards across all 558**, `Success` bucket: `Item` 1472, `TraderStanding`
532, `Experience` 508, `AssortmentUnlock` 231, `Skill` 83, `ProductionScheme`
31, `CustomizationDirect` 11, `Achievement` 10, `NotificationPopup` 3,
`TraderUnlock` 2, `TraderStandingRestore` 1, `Pockets` 1, `WebPromoCode` 1.
`Started`: `Item` 81, `ProductionScheme` 6, `AssortmentUnlock` 5.
`Fail`: `TraderStanding` 12.

**The traders.** Twelve, and one of them is a gift:

| id | nickname | assort | loyalty lvls | quests | dialogue |
|---|---|---:|---:|---:|---|
| 54cb50c76803fa8b248b4571 | Prapor | 951 | 4 | 77 | yes |
| 54cb57776803fa99248b456e | Therapist | 85 | 4 | 57 | yes |
| 579dc571d53a0658a154fbec | Fence | 0 | 2 | 16 | yes |
| 58330581ace78e27b8b10cee | Skier | 663 | 4 | 70 | — |
| 5935c25fb3acc3127c3d8cd9 | Peacekeeper | 1286 | 4 | 52 | — (USD) |
| 5a7c2eca46aef81a7ca2145d | Mechanic | 1079 | 4 | 105 | — |
| 5ac3b934156ae10c4430e83c | Ragman | 440 | 4 | 58 | — |
| 5c0647fdd443bc2504c2d371 | Jaeger | 579 | 4 | 78 | — |
| 638f541a29ffd1183d187f57 | caretaker | 0 | 1 | 15 | — |
| 656f0f98d80a697f855d34b1 | БТР | 0 | 1 | 15 | yes |
| 6617beeaa9cfa777ca915b7c | Arena | 707 | 4 | 15 | — |
| **6864e812f9fe664cb8b8e152** | **Storyteller** | **0** | **1** | **0** | — |

BSG ship a trader called **Storyteller** with no stock, no quests, one loyalty
level and `unlockedByDefault: false`. It is an empty narrative slot in the
shipped data. Section 3.6 uses it.

**Item vocabulary.** All 4673 templates carry exactly `_id`, `_name`, `_parent`,
`_props`, `_type` (+`_proto` on 4245). `_type` is `Item` on 4553 and `Node` on
120 — the Nodes are the class taxonomy and **are not spawnable**. Every template
chains to one root, `54009119af1c881c07000029`. Two orthogonal trees:

* the **`_parent` class tree** — 115 distinct parents, 13 classes directly under
  the root (CompoundItem 3356, StackableItem 430, BarterItem 299, Key 244,
  Info 138, Meds 49, FoodDrink 45, Flyer 40, SpecItem 25, Knife 25,
  ThrowWeap 14, Map 7);
* the **handbook tree** — `templates.handbook.Categories` (87) under 14 roots.
  Weapon parts & mods 1992, Gear 551, Ammo 412, an unnamed root 343, Barter
  items 274, Keys 228, Weapons 196, **Task items 149**, Medication 42,
  Provisions 42, Info items 33, Special equipment 17, Maps 6, Money 3.

**Task items, 149 of them, under handbook root `5b619f1a86f77450a702a6f3`, is
the MacGuffin pool.** They already look like plot objects, they already have
models and locale strings, and their `_props.QuestItem` marks them as
undroppable and unsellable.

**Locales are writable narrative surface.** `locales.global.en` holds 31,550
strings. Item names are `"<templateId> Name"` / `" ShortName"` /
`" Description"`; quest strings are lower-case suffixes — `"<questId> name"`,
`" description"`, `" successMessageText"`, `" failMessageText"`,
`" acceptPlayerMessage"`, `" declinePlayerMessage"`, `" completePlayerMessage"`.
A quest record's `name` field literally *is* the locale key. Only `en` is
imported by default; `emu/templates.locale`, `emu/dialogue.localeLine` and
`emu/market` all fall back to English *by name*, so English is the floor rather
than one language among seventeen (`docs/IMPORTDB.md`, the `--locales ru`
finding).

**Locations.** 19 keys; 14 have exits, 5 do not (`hideout`, `privatearea`,
`suburbs`, `terminal`, `town`). 13 carry loot tables. `base` has ~100 fields.
Per map, the numbers that matter to this pillar:

```
map            _Id                       exits transits boss waves spawnpts
bigmap         56f40101d2720b2a4d8b45d6    11     4       12    18    318
factory4_day   55f2d3fd4bdc2d5f408b4567     5     3        6     8    145
factory4_night 59fc81d786f774390775787e     5     3        6     8    145
interchange    5714dbc024597771384a510d     6     3        8     9    252
laboratory     5b0fc42d86f7744a585f9105     7     1       20     0    170
labyrinth      6733700029c367a3d40b02af     1     4       10     4     14
lighthouse     5704e4dad2720bb55b8b4567     7     3       19    13    250
rezervbase     5704e5fad2720bc05b8b4567     6     3       11    15    208
sandbox        653e6760052c01c1c805532f     5     2        0     6    232
sandbox_high   65b8d6f5cdde2479cb2a3125     5     2        8     5    233
shoreline      5704e554d2720bac5b8b456e    10     3       14    28    312
tarkovstreets  5714dc692459777137212e12    12     3       14    13    458
woods          5704e3c2d2720bac5b8b4567     9     4       12    16    368
develop        56db0b3bd2720bb0678b4567     6     0        0     3     11
hideout/privatearea/suburbs/terminal/town   0     0        0   0-2      0-3
```

An **exit record** carries 19 fields and **no world coordinates**:
`Chance, ChancePVE, Count, CountPVE, EntryPoints, EventAvailable,
ExfiltrationTime, ExfiltrationTimePVE, ExfiltrationType, Id, MaxTime, MaxTimePVE,
MinTime, MinTimePVE, Name, PassageRequirement, PlayersCount, PlayersCountPVE,
RequirementTip`. `Name` is the identity and the locale key; the geometry is a
trigger in the scene, matched by name. `mods/icebreaker/data/exits.json` is the
proof that this is authorable.

**Boss and wave records also carry no coordinates.** They name a *bot zone by
string*:

```json
{"BossName":"exUsec","BossChance":35,"BossDifficult":"normal",
 "BossEscortAmount":"2,3,3,4","BossEscortType":"exUsec","BossZone":"ZoneIcebreaker",
 "Delay":0,"Time":-1,"SpawnMode":["regular","pve"], ...}
```

Boss names in use across the 19 maps: `pmcUSEC` 35, `pmcBEAR` 33, `pmcBot` 20,
`tagillaHelperAgro` 8, `exUsec` 8, `sectantPriest` 5, `gifter` 5,
`bossKnight` 4, `bossPartisan` 4, `arenaFighterEvent` 2, `bossTagilla` 2,
`bossKolontay` 2, and one each of `bossBully`, `bossKilla`, `bossTagillaAgro`,
`bossKillaAgro`, `bossZryachiy`, `crazyAssaultEvent`, `bossGluhar`,
`peacemaker`, `bossSanitar`, `bossBoar`, `bossBoarSniper`, `bossKojaniy`.
`bots.types` has 57 roles behind them.

Zone strings are **per map** and must be drawn from that map's own tables. Eleven
maps declare usable ones (`bigmap` 16, `shoreline` 14, `tarkovstreets` 13,
`interchange`/`lighthouse` 10, `woods` 8, `rezervbase` 6, `laboratory` 2,
`factory4_day`/`labyrinth`/`sandbox_high` 1). Eight declare none.

### 1.5 `mods/pathtotarkov`, read rather than assumed

The brief calls it "a mod that already connects maps". **It does not connect
maps. It restricts where you may deploy.** The distinction matters:

* **Post-1.0 the game ships the graph itself.** Every `locations.<key>.base`
  carries a `transits` array, and `globals.config.TransitSettings.active` is
  `true` in this database. PTT reads BSG's table and **never invents an edge**
  (`mods/pathtotarkov/ptt/graph.nim`, module comment).
* Edges resolve by `target`, which is the destination's **`_Id`**, never by the
  `location` display string — `RezervBase`, `factory4_day` and `Interchange` all
  appear in the same table. Resolving by `target` resolves **38 of 38** edges.
* **The mechanism is one boolean.** `locations.<key>.base.Locked` — the map you
  stand on and everything one transit away go `false`, everything else `true`,
  recomputed after each raid. That is the whole game-facing surface.
* **That the client acts on `Locked` is an argument, not an observation.** PTT's
  own README says so in bold. The evidence is that BSG ship `Locked: true` on
  exactly `hideout`, `privatearea`, `suburbs`, `terminal` and `town` — which are
  exactly the entries you cannot deploy to, `terminal` included, which ships
  `Enabled: true` and is still unreachable. **Nothing here has ever run against
  BSG's client.**
* The graph is **directed and not strongly connected**: nothing targets
  `sandbox` (a source — hence the default `startAt`), `terminal` has no outgoing
  transit (a sink), `laboratory` has exactly one way out (`tarkovstreets`).
  `graph.nim` exports `sinks`, `sources` and `strandedFrom` so a mod can say
  that before it locks anything.
* From Customs with the shipped settings the open set is five of nineteen.
* **What PTT cannot do, and why:** `tarkov.raid.ended` carries only
  `{"profile": id}` — not the location, not the exit taken, not whether you
  survived. PTT recovers the location by pairing it with `tarkov.raid.configured`
  on the profile id. The exit and the outcome are simply lost. It also cannot
  refuse a raid onto a locked map, because `/client/match/local/start` belongs to
  `mods/tarkov` and **the backend refuses a second registration of an exact
  route**.

Two claims in that README are now stale and this pillar should not inherit them:

1. **"There is no `dbKeys(path)`."** There is: `aowl/src/aowlspt/server.nim:337`,
   with `dbKeysReady()` at :320 and `dbKeysOrRead` at :380 for hosts that lack
   it. "Which maps does this database have" no longer costs a 13.5 MB read.
2. **"in a database that persists"** — the shared database does **not** persist.
   `backend/aowlbackend.nim:1619-1628` loads `db.json` from disk at start;
   `dbLoad` appears once, at :1624, and nothing anywhere writes it back
   (`dbText*()` in `backend/jsondb.nim:535` is never called by the backend).
   Every `dbWrite` a mod makes lives in memory for one process lifetime.
   That weakens PTT's uninstall argument — but it is *load-bearing good news*
   for this pillar, and section 6 is built on it.

### 1.6 What a mod may write, and where the seams are

* `dbWrite(path, patch)` — `aowl/src/aowlspt/server.nim:486`, over
  `dbWritePath` at :458, which **merges** (never replaces) and **creates a path
  the database has never held**, wrapping one segment at a time. `dbPatch` alone
  refuses a missing path; `dbWrite` is the call that adds a table.
  Backend self-check: *"a mod can create a database path that was not there"*
  (`docs/BACKEND.md:439`).
* There is **no delete.** A merge cannot remove a member.
* `save`/`load`/`savedKeys` — a per-mod private store under
  `store/<mod-guid>/`. `load` answers a `Stored` whose **`missing` flag has
  teeth**: `ok:false, missing:true` is genuinely nothing there,
  `ok:false, missing:false` is a value that exists and could not be read.
  `mods/tarkov/emu/store.nim` is the whole argument, and it is the one this
  pillar must obey: *reading wrong is a screen, writing wrong is a player's
  account.*
* Routes are registered once and cannot be chained or filtered.
  `/client/quest/list` belongs to `mods/tarkov` (`tarkov.nim:630`, serving
  `templates.nim:42` = `dbRead("templates.quests")` **verbatim**).
  `mods/icebreaker`'s features 16 and 17 are both "impossible, same reason".
* Events: `onEvent` / `broadcast`, synchronous, in subscription order, to
  everyone but the emitter. `tarkov.raid.configured` and `tarkov.raid.ended`
  exist. `aowlspt.locations.hello` / `aowlspt.locations.changed` is the map
  announcement protocol `mods/icebreaker` publishes and PTT consumes.
* Mail: `emu/mail.deliver(profileId, sender, text, kind, nowSeconds,
  attachments)` at mail.nim:303. Kinds are the client's own numbering —
  `mkUserMessage` 1, `mkNpcTrader` 2, `mkAuction` 3, `mkSystem` 4,
  `mkInsuranceReturn` 5, `mkQuestStart` 10, `mkQuestFail` 11,
  `mkQuestSuccess` 12. Attachments are re-parented onto a minted container and
  redeemed by an ordinary inventory move. **`deliver` is internal to
  `mods/tarkov`; no event or route exposes it to another mod.** That is the
  single biggest argument in section 2.
* Traders: base and assort are `dbRead` per request and uncached
  (`emu/traders.nim:29`, :56), so a `dbWrite` changes what the next request
  serves. Per-profile standing is fully mutable — `addStanding` (:173),
  `addSalesSum` (:189), `putTraderEntry` (:125). **Loyalty is derived, never
  awarded** (`loyaltyLevelFor`, :132-161, floor of 1): writing
  `TradersInfo.<id>.loyaltyLevel` is pointless, the next standing change
  recomputes it.
* **`traders.<id>.questassort` is imported and read by nothing.**
  `grep questassort mods/tarkov/` returns empty, and `AssortmentUnlock` is in
  the "read, named and not applied" list. **A quest cannot unlock trader stock
  today.** Section 8 names it as work.

---

## 2. Where the generator has to live

This is the first thing to settle, because it decides everything else.

`emu/mail.deliver` is not reachable from another mod. `/client/quest/list`
cannot be re-registered. `mods/tarkov` owns the profile, and PTT's README states
the rule plainly: *a second mod editing another mod's profile documents behind
its back is how a save gets corrupted.* A story is mail, quests and profile
state.

**Recommendation: the generator is `mods/tarkov/emu/story.nim`**, sitting beside
`emu/repeatable.nim` and reached through the same seam
(`quests.questTemplate(p, qid, now)`, quests.nim:88-106). It is a *content*
module by the definition `docs/EMULATOR.md` closes with — "those are content,
and they belong in mods, including in this one".

**This is the owner's decision, not mine**, and the alternative is real: a
separate `mods/timbuktu` plus four additions to `mods/tarkov`, each one line:

1. `tarkov.mail.send` as a subscribed event (payload: profile, sender, kind,
   text, attachments) — closes the mail gap.
2. `location`, `exit` and `survived` on the `tarkov.raid.ended` broadcast —
   PTT asks for the first two already, and this pillar needs the third.
3. A template-provider hook on `questTemplate`, so the fallback chain is not
   hard-coded to `repeatable.questTemplateFor`.
4. `tarkov.quest.completed` / `tarkov.quest.failed` broadcasts.

Those four are worth building even if the generator lives in-tree, because they
are the difference between "aowlspt is a mod system" and "aowlspt is one big
mod". But they are a prerequisite for the out-of-tree option and not for the
in-tree one.

---

## 3. The generator

### 3.1 The seed and what is reproducible from it

One value: **`worldSeed`, a 24-hex string.** Held in the story module's own
store under `story.world` (per install — the database this writes into is global
anyway, and this is a single-player game; per-profile is section 8's open
question).

Everything else is derived. Substreams are domain-separated exactly the way
`repeatable.slotSeed` does it — a suffix, not a counter:

```
seededRng(worldSeed & ":factions")
seededRng(worldSeed & ":faction:" & $i & ":home")
seededRng(worldSeed & ":plan")
seededRng(worldSeed & ":quest:" & stepId)
seededRng(worldSeed & ":quest:" & stepId & ":text")
seededRng(worldSeed & ":loot:" & mapKey)
```

Because `Rng` is a value (rand.nim:24) and `seededRng` never returns the zero
state, two substreams are independent and neither can degenerate. Because
`mongoId(r)` draws from the stream, **every generated quest id, condition id and
counter id is a function of the seed alone** — which is what makes the same
world rebuild byte-for-byte on the next server start, which is what section 6
requires.

Reproducible from `worldSeed` + a pinned `db.json` + a pinned generator version:

* the faction set and the hostility matrix
* every key location binding
* every holder binding
* the escape schema and its parameters
* the entire quest graph: ids, conditions, rewards, locale strings
* every database write the story makes

Not reproducible, and deliberately: the player's choices. Those live in the
persistence pillar's store and in the profile.

### 3.2 The vocabulary rule

**The generator may only name things it harvested from the shipped database.**
This is the rule that makes generated content survive contact with a client
nobody here can test against, and it is not a style preference — every failure
mode in `mods/icebreaker`'s gap table is a case of naming something the scene
does not have.

At load, `story.nim` builds a **vocabulary index** by walking `templates.quests`
once (the same walk `unlockFollowUps` already does at quests.nim:184) plus
`locations.*.base` via `dbKeys`:

| vocabulary | harvested from | size on this db |
|---|---|---|
| kill targets | `savageRole` values in the 283 shipped `Kills` sub-conditions, ∩ `bots.types` | 57 roles, 24 of them boss-grade |
| map ids | `locations.<k>.base._Id` | 19, 13 playable |
| bot zones per map | `base.BossLocationSpawn[].BossZone`, `base.waves[].SpawnPoints`, `base.OpenZones` | 11 maps have them |
| exit names per map | `base.exits[].Name` | 11 on Customs … 12 on Streets |
| `VisitPlace` / `InZone` targets | the 212+32 targets in shipped quests, **verbatim** | reuse only, never invent |
| MacGuffins | handbook root `5b619f1a86f77450a702a6f3` "Task items" | 149 |
| barter/handover items | handbook "Barter items" 274, "Keys" 228 | 502 |
| traders | `traders.*` | 12 |
| container templates | `locations.<k>.staticLoot` keys | 27 on Customs |
| transit edges | `base.transits[].target` → `_Id` | 38, 38/38 resolvable |

If a pool comes back empty, `pickWeighted` returns −1 and `nextInt` returns 0 —
so **every draw must check for an empty pool and the generator must refuse to
build a world rather than fill a slot with element zero.** That is rand.nim's
own warning, applied.

### 3.3 What a world is

```
World
  seed          : string
  generatorVer  : int
  factions      : seq[Faction]          # 3..5
  hostility     : matrix[float]         # -1 .. +1, antisymmetric-ish
  keySites      : seq[Site]             # 5..9
  holdings      : seq[Holding]          # MacGuffin -> holder
  escape        : EscapeSchema
  plan          : seq[Step]             # the quest DAG, topologically ordered
  scars         : seq[Scar]             # from the persistence pillar, replayed
```

**A faction is a role binding, not a person.** Four slots, all drawn from the
harvest:

```
Faction
  face     : traderId           # the one you talk to
  muscle   : bossRole           # what its people are, in a raid
  home     : mapKey             # where it is strong
  reach    : seq[mapKey]        # home + everything one transit away
  temper   : enum {mercantile, zealot, military, scavenger}
```

The face is what makes a faction *legible* — the player meets a faction by
trading with it. The muscle is what makes it *felt* — you meet it again when its
boss role spawns on its maps. Nothing else about a faction is expressible, and
pretending otherwise is how this design would fail.

**Hostility is three mechanisms, all of them real:**

1. **Coupled standing.** A quest for faction A pays `TraderStanding` positive to
   A's face and negative to B's face in the same `rewards.Success` array.
   `grantRewardList` honours an explicit `target` (quests.nim:239), so this
   works today with no new code. Because `loyaltyLevelFor` derives loyalty with a
   floor of 1 (traders.nim:132-161), a hated trader still sells his level-1
   stock — hostility is felt as price and access, never as a locked door. That
   is a solvability guard the emulator gives away for free.
2. **Territory.** A faction's `muscle` role gets a `BossLocationSpawn` entry
   written into each map in its `home`, at a `BossZone` drawn from that map's own
   zone strings, with `BossChance` scaled by how contested the map is. Two
   hostile factions sharing a map is a map where both spawn.
3. **Stock.** A faction's face gets a `dbWrite` into `traders.<id>.assort`
   reflecting what it controls. (See section 8 — the *conditional* form of this,
   `questassort`, is not implemented.)

**A site is a (map, anchor) pair** where the anchor is a zone name, an exit name
or a container template — never a coordinate. A **holding** binds a MacGuffin
template to a holder, and there are exactly four holder kinds the database can
express: a trader's assort, a boss's escort loot, a map's `staticForced`
container, and another player-completable quest's reward.

### 3.4 The planner, and why not a grammar

**A grammar is the wrong tool and a planner is the right one.** The argument, in
full, because this is the decision the rest of the pillar hangs on:

A story grammar — nonterminals, rewrite rules, `QUEST → FETCH | KILL | ESCORT`,
expand until terminal — is excellent at producing *shape*. It is structurally
incapable of producing *solvability*. A grammar's derivation is a tree over
symbols; whether the resulting quest chain can be finished is a property of the
*world state* at each step, which the derivation does not model. You would
generate, then verify, then reject and retry — and rejection sampling over a
space where most derivations are unsolvable has no bound on its running time,
which is exactly the failure `rand.nextInt`'s docstring refuses to accept
elsewhere in this codebase.

A **regression planner over typed operators** inverts that. You start from the
goal — the escape condition — and repeatedly choose an operator whose *effect*
achieves an open precondition. Every operator you add is added *because* it
establishes something the plan already needs. When the last open precondition is
satisfied by the initial state, you are done, and **the plan is solvable by
construction** because that is what the algorithm's termination condition means.
No verification pass, no rejection loop.

The operator set is small and fixed — a dozen or so — and each maps onto exactly
one emittable condition group:

| operator | precondition | effect | emits |
|---|---|---|---|
| `Acquire(item, from=trader)` | standing/loyalty with the trader | `has(item)` | `TraderLoyalty` start, `HandoverItem` finish |
| `Acquire(item, from=map)` | map is reachable | `has(item)` | `FindItem` finish, `CounterCreator{Location}` |
| `Acquire(item, from=boss)` | map is reachable | `has(item)` | `CounterCreator{Kills, savageRole}` + `HandoverItem` |
| `Deliver(item, to=trader)` | `has(item)` | `favour(trader)`, `knows(fact)` | `HandoverItem` |
| `Earn(standing, trader, n)` | — | `standing(trader) >= n` | `TraderStanding` finish |
| `Prove(level n)` | — | `level >= n` | `Level` start |
| `Survive(map, exit)` | map is reachable | `knows(route)` | `CounterCreator{Location, ExitStatus, ExitName}` |
| `Eliminate(role, map)` | map is reachable | `role weakened` | `CounterCreator{Kills, savageRole, Location}` |
| `Recover(item, site)` | map is reachable | `has(item)` | `FindItem` / `LeaveItemAtLocation` |
| `Witness(place)` | map is reachable | `knows(fact)` | `CounterCreator{VisitPlace}` — **harvested target only** |
| `Escape(schema)` | the schema's own set | **win** | the escape quest |

`map is reachable` is a **real** precondition and it is checked against PTT's
graph: reachability from `startAt` over BSG's 38 transits, honouring that the
graph is directed and has sinks and sources. A step on `terminal` is a step the
plan may never contain.

The grammar does not disappear — it moves to where it belongs. Once the plan
exists, a **surface grammar** names it: which faction each step is *about*, what
the mail says, what the quest is called. That layer can be as loose as you like
because it cannot make the plan unsolvable. Structure from the planner, flavour
from the grammar, and the two never negotiate.

### 3.5 Emitting the plan

A topological order of the plan is a linear chain (or a shallow DAG — see 4.4)
of quests, written as:

```
dbWrite("templates.quests." & questId, <the quest record>)
dbWrite("locales.global.en", { "<questId> name": ..., "<questId> description": ...,
                               "<questId> successMessageText": ..., ... })
```

`dbWrite` creates the path (`server.nim:458`) and `/client/quest/list` serves
`templates.quests` verbatim (`templates.nim:42`), so **a generated quest written
into the database appears in the client's quest log like any other.** That is the
mechanism, and it is the one thing this pillar needs from the host that it
already has.

The record must carry the 22 fields all 558 shipped quests carry — `_id`,
`QuestName`, `name`, `description`, `note`, `image`, `type`, `side` (`Pmc`, the
only value in this database), `location`, `traderId`, `status`, `conditions`,
`rewards`, `instantComplete`, `isKey`, `restartable`, `secretQuest`,
`canShowNotificationsInGame`, `startedMessageText`, `successMessageText`,
`failMessageText`, `changeQuestMessageText` — copied in shape from a real one
rather than invented, because the client parses this and nothing here can test it.

Dependency edges are `Quest` conditions in `AvailableForStart`, which
`unlockFollowUps` (quests.nim:176) already walks and flips. `Fail` conditions are
how a branch closes.

### 3.6 The escape

"Escape" is the run's win condition and it is **drawn from the seed, from a small
set of schemas**, each of which reduces to conditions the emulator evaluates:

* **The Convoy** — assemble *n* MacGuffins from *n* distinct factions, hand them
  to one face at loyalty *L*, then survive out of a named exit on a named map.
  Emits `HandoverItem` ×n + `TraderLoyalty` + `CounterCreator{Location,
  ExitStatus, ExitName}`.
* **The Ledger** — one MacGuffin held by a boss role. Emits
  `CounterCreator{Kills, savageRole, Location}` then `HandoverItem`.
* **The Debt** — reach standing *s* with a faction that starts hostile, which
  forces the plan through the other factions' branches first. Emits
  `TraderStanding` with an unusual threshold.
* **The Long Walk** — traverse a specific chain of transits, verified against the
  graph, ending on a map that is a sink. Emits a chain of
  `CounterCreator{Location, ExitStatus}` steps.
* **The Storyteller** — the trader BSG ship empty is the one who knows the way
  out; his stock, his loyalty ladder and his dialogue are entirely ours to write
  because the database ships none. Emits `TraderUnlock` (which *is* applied,
  quests.nim:247) then a `TraderLoyalty` ladder.

Every schema's terminal condition must be one the **server** can decide — a
`HandoverItem`, a `TraderLoyalty`, or a `CounterCreator` whose sub-conditions are
`Kills`/`Location`/`ExitStatus` only. Never a client-counted kind. Section 4.2
says why.

---

## 4. Solvability and non-degeneracy

Six invariants. Each is checkable offline, against `db.json`, with no host and
no game — the way `tests/pttguard` checks PTT's 62 assertions. **A world that
fails any of them is not shipped to the player; the generator refuses and says
which invariant failed.** Refusing loudly is the house style and it is right
here: a story you cannot finish is worse than no story.

### 4.1 Reachability

Every map a step names must be reachable from `startAt` over the transit graph,
under whatever hop rule the deploy gating uses. Computed with PTT's own
`graph.nim` primitives (`sinks`, `sources`, `strandedFrom`). Because the graph is
directed and not strongly connected, this is not a formality: a plan that puts
step 4 on `laboratory` and step 5 on `woods` is a plan that strands the player,
since Labs' only exit is Streets and nothing leads to Woods from there.

### 4.2 Every condition is one the server can decide

The emulator evaluates eleven progress kinds but **derives progress for only
one**: `CounterCreator`, via `killCredit`. The other ten are satisfied purely by
the client's own `TaskConditionCounters` (quests.nim:588, "the client's copy is
the only place this raid's counters exist").

That splits the vocabulary into three tiers, and the invariant is about the
**critical path**:

* **Tier 1 — server-decidable, safe anywhere.** `Level`, `Quest`,
  `TraderLoyalty`, `TraderStanding`, `Skill`, `HandoverItem` (credited by the
  server's own handover path, quests.nim:458-493), and `CounterCreator` whose
  sub-conditions are only `Kills`, `Location`, `ExitStatus`.
* **Tier 2 — client-counted, but against names the database supplies.**
  `FindItem`, `LeaveItemAtLocation`, `SellItemToTrader`, and `ExitName` /
  `InZone` / `VisitPlace` sub-conditions **whose targets were harvested verbatim
  from shipped quests**. These probably work. Nobody here can prove it.
* **Tier 3 — never emitted.** `PlaceBeacon`, `WeaponAssembly`, `UseItem`,
  `HealthEffect`, `Shots`, `GlobalVariableValue`, `HideoutArea`, `LaunchFlare`,
  `UnderArtilleryFire`, `Equipment`, `HealthBuff`, `Time`, and every `Arena*`
  kind. Also: any `Kills` sub-condition carrying `weaponCaliber`,
  `weaponMods*`, `equipment*`, `enemyEquipment*` or `enemyHealthEffects` —
  `killCredit` refuses the whole counter when one is present, by design.

**The invariant: every step on the critical path is Tier 1.** Tier 2 may appear
only on optional branches, where a step that silently never completes costs the
player a side reward and not the run.

And the reason unknown kinds are *more* dangerous than refused ones:
`evaluate` returns **true** for a kind it does not recognise
(questcond.nim:397). An invented condition does not block the quest, it makes it
free. A generator that guesses a condition name produces a story you win by
accident.

### 4.3 Non-degeneracy

Four numeric floors on the *plan*, not on the output:

* **Depth ≥ D.** The longest chain of `Quest` preconditions from the escape back
  to the initial state. `D` is the run's length knob.
* **No step satisfied at t=0.** Every operator's precondition must be false in
  the initial state (a fresh profile, level 1, base standing) unless the plan put
  it there. This is what stops a generated escape you can complete before
  leaving the hideout — and it is checkable, because the initial state is a
  fixed document.
* **Breadth ≥ B distinct traders and ≥ M distinct maps.** A story that happens
  entirely at Prapor on Customs is technically a story.
* **No duplicate operator instances.** Two steps that are the same
  `(operator, item, holder)` triple are one step told twice.

The failure these floors exist to catch is a plan whose regression terminated on
its first move because the goal's precondition was already true. That is the
trivially-instant win, and it is a *planner* bug, caught by a *planner*
assertion, before a single quest record is written.

### 4.4 The two-achiever invariant

**Every node on the critical path has at least two independent achievers, and at
least one of them routes through no killable actor.**

This is the invariant that makes section 5 possible, and it costs the planner
one thing: when regression chooses an operator to achieve an open precondition,
it chooses *two*, and emits both as sibling quests whose `Quest` conditions both
feed the same successor. The successor's `AvailableForStart` group names them
with a `status` list that either satisfies — which is expressible, because a
`Quest` condition's `status` is an array of status codes
(questcond.nim:355-369) and the group is met if any listed code matches.

Cost: the graph is roughly twice the size. Benefit: no single world event can
make the run unwinnable, which is the difference between a persistent story and
a save you have to abandon.

### 4.5 The trader floor

No step may depend on a trader being *unlocked* if the story can lock him. The
emulator applies `TraderUnlock` (quests.nim:247) but has no revoke, and
`loyaltyLevelFor` floors loyalty at 1 — so a trader who exists can always be
traded with. The generator must not build a gate the world can close behind the
player. Storyteller is the exception and is always the *last* unlock, never a
precondition for anything but the ending.

### 4.6 The pool floors

Every draw checks that its pool is non-empty before drawing. `nextInt(r, 0)`
returns 0 and `pickWeighted` returns −1; a generator that does not check turns
an empty pool into "the first item in the table", which on `templates.items` is
a `Node` that cannot be spawned at all.

---

## 5. When the player kills someone who matters

The honest starting point: **the game has no persistent NPCs.** Bosses respawn
per raid at a `BossChance`. There is no death to observe, no body to persist and
no dialogue tree to close. A design that promises "kill the warlord and the
warlord is gone" is promising something the client does not model.

What *is* observable, and it is enough:

1. **A kill of a named role.** The raid result carries
   `Stats.Eft.Victims[].Role`, and `killCredit` matches it against `savageRole`
   (questcond.nim:723). So "the player killed `bossKolontay` on `rezervbase`" is
   a fact the server can establish, either through a planted counter or by
   reading the victim list directly at raid end.
2. **A quest failed.** The `Fail` condition group already exists and the
   emulator checks it *before* `AvailableForFinish` — quests.nim:637-647, whose
   comment says exactly this case: *"a Fail group that is met is almost always
   'you killed the person you were told to protect' and finishing it anyway would
   pay for it."*
3. **Standing crossing a threshold.** `TraderStanding` conditions in a `Fail`
   group; there are 2 in the shipped 558.

So the mechanism is:

**A scar is an append-only record of an irreversible world event.** It is the
only thing besides the seed that the story pillar persists. On observing (1),
(2) or (3), the story appends `Scar{kind, subject, mapKey, atTick}` and
immediately applies its *soft* consequences: standing shifts, a mail from the
faction that noticed, the boss's `BossChance` dropped on its home maps. Its
*hard* consequences — a branch closing, a faction's stock changing — are applied
by re-deriving the world with the scar list as an input, which happens anyway on
the next server start (section 6).

`World = f(seed, generatorVersion, db, scars)`. The scars are the only part of
that tuple the player writes, and they are append-only, so the derivation is
still a pure function and still reproducible: a support request that names a seed
and a scar log regenerates the exact world.

**Because of 4.4, no scar can make a run unwinnable.** The killed actor's
achiever closes; the sibling achiever, which routes through items and traders
only, stays open. What the player loses is the *shorter* path, some standing and
whatever that branch's rewards were. What they gain is a world that visibly
reacted, which is the whole point.

The failure mode to design against explicitly: a player who kills *everyone*.
Since every critical node has an item-and-trader achiever and traders cannot be
removed, a maximally murderous run converges on the longest, most expensive path
to the same escape. That is a legitimate playstyle with a legitimate cost, and it
is a better answer than a soft-lock.

---

## 6. Regeneration, and what happens to a live save

This is the question the brief asks last and it turns out to have a comfortable
answer, for one reason nobody planned:

**The shared database does not persist.** `backend/aowlbackend.nim:1619-1628`
loads `db.json` at start; `dbLoad` is called once, at :1624; nothing writes it
back. Every `dbWrite` lives for one process lifetime.

Three consequences, all good:

1. **The generator must re-emit the entire world on every server start**, from
   the seed. That is not a burden, it is a forcing function: it makes
   reproducibility a thing you cannot forget to implement, because forgetting it
   means the world changes when the player restarts the server.
2. **`dbWrite`'s inability to delete stops mattering.** A merge cannot remove a
   member, so a world that could accumulate would accumulate forever. It cannot
   accumulate; the slate is `db.json` every time.
3. **A "regeneration" is just a different seed.** There is no migration to write.

What *does* persist is the profile (owned by `mods/tarkov`) and the story's own
store keys. So the real question is: **what happens to a profile that references
quest ids the current generator no longer produces?**

The emulator already answers it, and the answer is designed rather than
accidental. A quest in the profile's `Quests` array whose template cannot be
found is handled at quests.nim:431-434 and described at repeatable.nim:803-808:
it *completes with whatever rewards the missing template does not name, and says
so.* The alternative — a player stranded on a quest that no longer exists — was
considered and rejected. So a generator change degrades to "the old chapter
closes itself, quietly, with a log line", which is survivable.

That is not licence to change the generator casually. The policy:

* **`story.seed` is written once and never rewritten.** Same discipline as PTT's
  baseline and `emu/ids`' run number: `load` is checked for `missing` before
  anything is created, and *present-and-unreadable disables the story and says
  where the store's history copy is*. Creating a fresh seed over an unreadable
  one silently replaces the player's world with a different one — the exact shape
  of bug `emu/store.nim` exists to prevent.
* **`story.generatorVersion` is written beside it**, and a mismatch on load is a
  **decision, never a default**. Two honest options, and the mod refuses to start
  the story until one is chosen in config: keep the old world (which requires the
  old generator to still be compiled in — so generator versions are additive and
  never deleted), or start a new one (which is a new seed and an explicit
  acknowledgement that the current chapter ends).
* **Migrating a quest graph across generator versions is refused outright.**
  There is no honest way to map a plan produced by one operator set onto a plan
  produced by another, and a half-migrated story is a story with an unreachable
  objective — which is the thing section 4 exists to make impossible.
* **Scars survive every version.** They are `{kind, subject, mapKey, atTick}` and
  carry no reference to a plan. A new generator replays them as inputs.

---

## 7. Coherence with the persistence pillar

`docs/timbuktu/PERSISTENCE.md` is being written by another agent. The contract
this pillar assumes, stated so it can be argued with:

**Ownership.** Story owns store keys under `story.*` in its own mod store.
Persistence owns everything else. Neither reads the other's keys directly.

| key | written by | shape | rewritten? |
|---|---|---|---|
| `story.seed` | story, once | 24-hex | **never** |
| `story.version` | story | int | on an acknowledged regeneration |
| `story.scars` | story | append-only array | append only |
| `story.cache.<n>` | story | derived, versioned | freely; may be deleted at any time |

**Direction of dependency: story → persistence, never the reverse.** The story
tells the world where things are; the world remembers where the player put
things. A physical chest containing a MacGuffin is persistence's record; that the
MacGuffin *matters* is story's.

**The one place they must agree** is the initial placement of story items. The
story decides "MacGuffin *m* starts in container *c* on map *k*"; persistence
owns that container's contents from the moment the player first opens it. So:
story writes initial placement **only into the database** (`staticForced` on the
map's `staticContainers`), which is regenerated from `db.json` every boot;
persistence writes into its own store the moment a player touches something. If
both are present, **persistence wins**, always — otherwise a restart would
respawn a MacGuffin the player already carried home.

**Events, rather than shared state:**

* story emits `timbuktu.story.worldReady` after its database writes flush, with
  the seed, the version and the site list — the same shape as
  `aowlspt.locations.changed`, and for the same reason: a mod that loads later
  needs to be told.
* story emits `timbuktu.story.scar` when one is recorded.
* story subscribes to `tarkov.raid.ended` (and needs the `survived`/`exit`
  fields section 2 asks for).
* story answers `timbuktu.story.hello` for a mod that loaded first.

**Neither pillar writes the player's profile.** That belongs to `mods/tarkov`,
and if the story lives inside `mods/tarkov` it writes it through the existing
`Profile` helpers under the existing write-guard (`tarkov.nim:571-584` — the
"another request changed this profile while this one was working" check), not
around them.

---

## 8. What is not reachable

Stated plainly, because designing around a wall is cheaper than walking into it.

**New maps: no.** `mods/icebreaker` is the proof and it is a careful one. It
ships 12 of 19 upstream features by rebinding the dormant `suburbs` slot — name,
scene pointer, locale, exits, waves, boss spawns, bot caps. It cannot ship
**`SpawnPointParams`**, and its README states the consequence: *"A raid on this
map will not start without `SpawnPointParams`."* The line between authorable and
not is exactly one property — **whether the record contains world coordinates.**
An exit record does not (19 fields, geometry is a scene trigger matched by
`Name`). A wave does not (it names a zone by string). A boss spawn does not. A
`SpawnPointParams` entry is *nothing but* coordinates — `Position`, `Rotation`,
a collider radius, an `Infiltration` name, a `Sides` list — and stock maps carry
between 14 (Labyrinth) and 458 (Streets) of them. Plus a scene bundle, a navmesh,
culling and acoustics bakes, and ~8 MB of extracted loot coordinates, none of
which is code.

**New edges between maps: no.** A transit needs a trigger in the scene, the same
as an exfil. BSG's 38 are what exist. PTT's design principle — *read BSG's graph
and never invent an edge* — is not caution, it is the only correct behaviour.

**Placing anything at a coordinate: no.** Not an NPC, not an object, not a
marker. The finest granularity available is a **bot zone**, by name, on the 11
maps that declare zone names.

**Persistent NPC death: no.** See section 5.

**New item art or new item behaviour: no.** 4673 templates, 4553 of them
spawnable. A "new" object is an existing template renamed through
`locales.global.en."<tpl> Name"` — and that renames it *everywhere*, in the flea,
in the handbook, in every other quest. Hence the Task-items pool: 149 templates
that already read as plot objects and are largely unreferenced by anything the
player will notice.

**Named-NPC dialogue trees: essentially no.** `emu/dialogue.say` resolves lines
from `traders.<id>.dialogue.<key>` through the player's locale, and **only 4 of
12 traders ship a `dialogue` block** (Prapor, Therapist, Fence, БТР). The
placeholders the server can fill are exactly `{location}`, `{date}`, `{time}`;
any other placeholder, or an empty substitution, sets `complete = false` and the
line is rejected rather than sent half-rendered. So NPC voice is **mail**, not
dialogue, and mail is a real channel: eight message kinds, arbitrary sender,
arbitrary text, item attachments.

**Gating trader stock on a quest: not today.**
`traders.<id>.questassort` is imported and read by nothing — `grep questassort
mods/tarkov/` returns empty — and `AssortmentUnlock` is in the "read, named and
not applied" list at quests.nim:255. The generator can change an assort *at
world-build time* with `dbWrite`; it cannot make a shop item appear when a quest
completes. Section 9 lists the work.

**Client-side anything: possible, but out of scope and untested.** The brief says
"no BepInEx, no Harmony", which is true, and then infers that the client is
closed, which is **not**. `docs/IL2CPP.md` documents a working native host:
`GameAssembly.dll` exports 242 IL2CPP runtime functions by name, unmangled, and
`host/Aowlspt.Host.Il2Cpp` calls them directly — `resolve`/`call` on any type and
method, field reads and writes, x64 inline detours with up to four typed
arguments, postfix patches, and a typed patch path at 23–37 ns a firing. What is
*not* reachable is `global-metadata.dat`, which BSG ship encrypted and which the
host deliberately does not touch: everything goes in through the runtime's own
front door. So a story HUD is buildable. It is not this pillar's to build, and
every client-side claim in this repository is an argument rather than an
observation.

**And the largest unknown, restated so it is not lost:** *nothing in
`mods/pathtotarkov` has ever run against BSG's client.* If the client does not
act on `base.Locked`, the deploy gating this design assumes does not exist, and
the story's map layout becomes advisory. PTT is built to notice —
`tarkov.raid.configured` on a locked map logs *"the raid is on <map>, which this
mod has locked"* — and this pillar should subscribe to the same signal and
degrade to "the story tells you where to go" rather than "the world stops you".

---

## 9. What would have to be built first

Ordered by what unblocks the most.

1. **`mods/tarkov/emu/story.nim`, the world model and the harvest** — the
   vocabulary index of section 3.2, built from `dbKeys` + one walk of
   `templates.quests`, with a self-check that prints every pool's size. Nothing
   else can be trusted until the pools are known to be non-empty on a real
   import. Runnable with no host, against `db.json`, like `emu/loot.selfCheck`.
2. **`tests/storyguard`** — the offline checker, modelled on `tests/pttguard`
   (62 assertions, no host, no backend). It takes a seed and asserts the six
   invariants of section 4 over the generated plan. **Every check paired with its
   opposite**, and at least two deliberate mutations run against it before it is
   believed — pttguard's own discipline, and the reason it caught the
   `rememberBaseline` bug.
3. **The planner** — operators, regression, the two-achiever emission. Pure, no
   host, testable in isolation. This is the piece with real algorithmic content
   and it should be written and tested before a single quest record exists.
4. **The emitter** — plan → `templates.quests` records + locale keys, shaped
   field-for-field against a real shipped quest. The riskiest piece, because the
   client parses it and nothing here can check.
5. **The four `mods/tarkov` API additions** of section 2 —
   `location`/`exit`/`survived` on `tarkov.raid.ended`, `tarkov.mail.send`,
   `tarkov.quest.completed`, and a template-provider hook. Each is small; PTT
   already asks for two of them; they are what decides whether this pillar can
   live outside `mods/tarkov`.
6. **The scar recorder** and the persistence contract of section 7, agreed with
   whoever writes `PERSISTENCE.md` before either side writes a store key.
7. **`questassort` / `AssortmentUnlock`** — the one missing content mechanism
   that the story genuinely wants: a faction's stock changing because of
   something the player did.
8. **The surface grammar** — names, mail, flavour. Last, deliberately. It is the
   part that can be rewritten freely because it cannot make a world unsolvable,
   and building it first is how a project ends up with beautiful prose attached
   to an unfinishable quest chain.

---

## 10. Decisions that are the owner's, not this document's

1. **In-tree or out-of-tree.** `emu/story.nim` inside `mods/tarkov` works today.
   `mods/timbuktu` needs the four API additions first. Section 2.
2. **Does escaping end the run?** "Persistent single-player RPG" and "the idea is
   identical to Tarkov" pull in opposite directions. If escaping ends the run,
   this is a roguelike and the seed rolls; if it opens a chapter, the generator
   needs a notion of an *act*, and section 6's regeneration policy becomes a
   per-act thing rather than a per-install one. Everything in section 3.6 is
   written for the first reading and would need revisiting for the second.
3. **What happens to the 558 shipped quests.** Three options: leave them as
   ambient side work (cheapest, and they clash tonally); re-skin them by
   overwriting their locale strings (medium, and it is 558 × 7 strings); or
   suppress them by overwriting each `conditions.AvailableForStart` with an
   unmeetable `Level`. The third is **unverified** — whether `dbPatch`'s merge
   replaces a nested array member wholesale has not been tested, and it should be
   before anyone plans around it.
4. **Per-install or per-profile world.** Database writes are global, so
   per-install is far simpler and is right for single-player. Per-profile would
   need the whole story served through per-profile computation rather than
   through `templates.quests`, which the `/client/quest/list` ownership rule
   makes hard.
5. **The numbers.** Faction count (3–5), plan depth `D`, breadth floors `B` and
   `M`, and how many MacGuffins the escape wants. These are the difficulty dial
   and they belong to whoever plays it.
6. **Whether Tier 2 conditions may appear at all.** The safe answer is critical
   path Tier 1 only. The braver answer is that a Tier 2 step on the critical path
   is acceptable because the shipped game uses 212 `VisitPlace` sub-conditions
   and they demonstrably work — but "they work in a shipped quest" and "they work
   in a quest we wrote, in a client nobody here has tested against" are two
   different claims, and only a raid can settle it.

---

## 11. Corrections to the brief

Recorded because a wrong premise carried forward is worse than a missing one.

1. **The four counts are all correct** — 558 quests, 4673 item templates, 19
   maps, 12 traders, verified against `D:\Aowlspt\aowlspt\db.json`.
2. **`mods/pathtotarkov` does not connect maps.** The post-1.0 client connects
   them itself, through `base.transits` and `globals.config.TransitSettings`.
   PTT *restricts* which of BSG's 38 edges you may deploy across, by writing one
   boolean, and its own README says the client acting on that boolean has never
   been observed.
3. **"IL2CPP, no BepInEx, no Harmony" does not mean the client is closed.**
   `docs/IL2CPP.md` documents 242 exported runtime functions and a working
   native patch path. What is closed is the encrypted metadata, which the host
   deliberately routes around rather than through. The things that *are*
   genuinely unreachable are geometry, coordinates and assets — and those are
   unreachable for a different reason than the brief gives.
4. **The database uses `conditionType`, not `_parent`** — 0 of 2636 conditions
   carry `_parent`. The emulator's `condKind` accepts both, so this affects what
   the generator should *read*, not what it may emit.
5. **Shared-database writes do not persist** across a server restart, contrary to
   `mods/pathtotarkov/README.md`'s "in a database that persists". PTT's
   uninstall-safety argument is weaker than it states — though its baseline
   record is still right for a hot reload within one process.
6. **`dbKeys` exists** (`aowl/src/aowlspt/server.nim:337`), contrary to PTT's
   "What the API could not express" item 2.
7. **There are twelve traders and one of them is called Storyteller** — zero
   quests, zero assort, one loyalty level, `unlockedByDefault: false`. BSG
   shipped an empty narrative slot. It would be strange not to use it.
