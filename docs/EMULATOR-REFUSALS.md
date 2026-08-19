# Every refusal in `mods/tarkov`, and whether its reason still holds

`mods/tarkov/README.md` §3 lists the refusals and what each costs the player.
This document does the other half: it takes each one back to the database and
the reference dump and asks whether the sentence explaining it is still true.

The reason to do that at all is that three gaps were closed in one day, and all
three turned out to be *nobody had looked* rather than blocked. One said it
needed a table that was in the database the whole time. One refused quest kills
on the **presence** of a `distance` key when the victim report had carried the
distance all along — 191 of the 283 `Kills` sub-conditions carry no real
qualifier and every one of them was being refused. And `staticAmmo` was
documented as needing a consumer that could never have used it: an ammo box has
exactly one cartridge in its filter, and **magazines**, at 3 to 51 cartridges
each, were the real consumer.

So the rule this document was written under: **grep `build/db/db.json` before
believing any claim that a refusal is blocked on missing data.** It is 39.40 MiB
and it is right there. Six of the reasons below did not survive that.

## The sentence that stands over all of this

**Nothing in this repository has ever run against BSG's client.** Several
refusals here are conservative precisely because nobody has seen the client's
real behaviour — `Victim.Time`'s clock, `Victim.Weapon`'s spelling,
`heal_price_coef`'s direction, whether `warnings[].errmsg` is rendered at all.
Where that is the binding constraint it is said so, and the verdict is *blocked
on one raid* rather than *permanent*. Where it is **not** the binding constraint
— which is most of the interesting cases — the refusal is a decision this
process could have made on its own and did not.

## Counts

| Verdict | Rows |
|---|---:|
| **Permanent** — the data does not exist in `build/db/db.json`, in `reference/spt-4.1-surface.json`, or in this process at all | 24 |
| **Blocked on something nameable** — one importer row, one constant, or one raid | 6 |
| **Nobody has looked** — the thing the refusal says is missing is present, or the refusal was never written down | 6 |

Six reasons are wrong. Two of them are wrong in `mods/tarkov/README.md`, two in
a code comment, one in `docs/EMULATOR-COVERAGE.md`, and one is a route that
reports success and does nothing while no document says so.

> ## Five of the six are closed
>
> Sections 1, 3, 4, 6 and 7 below were acted on, and each carries a
> **Closed** note saying what was implemented and what is still refused.
> Section 2 (`OpenRandomLootContainer`) and section 5 (`weaponCaliber`) are
> untouched: the first needs an importer row and `tools/` is not this
> document's to edit, and the second still depends on how the live client
> spells `Victim.Weapon`.
>
> The rest of the document is left as it was written, so that the reasoning
> that was wrong stays readable next to what replaced it.

---

## The five that pay best, ranked

Ranked by player value per unit of work. This is the list to implement from.

### 1. Fence karma from scav kills — the game's own rate is in the database, unused

**What the player loses.** Every scav raid moves Fence's standing by exactly
`fenceKarmaOnScavExtract` (0.01) for walking out and `fenceKarmaOnScavDeath`
(0.0) for dying, and by nothing else. Killing scavs as a scav costs nothing;
killing PMCs as a scav earns nothing. Fence's stock, his prices
(`FenceSettings.Levels[].PriceModifier`) and his available exits all key off a
number that in this server only ever counts extractions. A player who murders
every scav on Customs and one who saves them get the same Fence.

**Why it is refused.** It is not refused, and it is not documented as a gap.
`mods/tarkov/emu/traders.nim:218-232` explains the two config constants as "a
scale that makes the number mean something, not a figure recovered from the
game", and `applyScavKarma` (`mods/tarkov/emu/traders.nim:249`) takes only
`survived`.

**Whether that reason is still true.** No. `bots.types.<role>.experience.standingForKill`
is present for **all 57 bot roles**, per difficulty, with the game's real
numbers:

```
assault   {"easy": -0.03, "normal": -0.04, "hard": -0.05}
bear      {"easy":  0.02, "normal":  0.02, "hard":  0.03}
```

Twelve roles sit at −0.05, ten at −0.2, twenty-one at 0.
`mods/tarkov/emu/bots.nim:871-879` already reads this exact path — it hands the
number to the *client* as `StandingForKill` on the generated bot. The join key is
`Stats.Eft.Victims[].Role`, which `emu/questcond` already walks. And there is no
client fallback on this path: `endScavRaid` (`mods/tarkov/emu/scav.nim:467`)
copies **only items** off the played scav — no `TradersInfo`, no stats — and
`mods/tarkov/emu/scav.nim:197` sets the scav's own `StandingForKill` to 0.0
before the raid. So whatever standing the client computed during a scav raid is
discarded by design, and nothing recomputes it.

Two further facts in the database that nobody has used:
`globals.config.FenceSettings.PmcBotKillStandingMultiplier` = 1 and
`paidExitStandingNumerator` = 0.2.

**Cost to close.** One pass over the victim list at the scav branch of
`onMatchEnd` (`mods/tarkov/tarkov.nim:1010`), joining `Role` to
`bots.types.<role>.experience.standingForKill.<difficulty>`. The difficulty is
the one unknown — the raid configuration carries `BotSettings` and this server
discards it (see §4 below); `normal` is the honest default, and a role whose
entry lacks the requested difficulty should refuse by name rather than pick one.

**Verdict: nobody has looked.**

> **Closed.** `emu/traders.scavKillKarma` reads `Stats.Eft.Victims` off the
> profile the client hands back at the scav branch of `onMatchEnd` and prices
> every victim at `bots.types.<role>.experience.standingForKill.normal`, with
> the role lower-cased for the lookup (the database keys `pmcbear`, the client
> spells `pmcBEAR`). PMC victims — the ones the report's own `Side` calls
> `Bear` or `Usec` — are scaled by `FenceSettings.PmcBotKillStandingMultiplier`,
> read rather than assumed. The whole raid's standing is written once, so
> `numText`'s 1/1,000,000 grid rounds once for twelve kills rather than twelve
> times. `emu/traders.fenceId()` now prefers `FenceSettings.FenceId` over the
> hard-coded constant, which closes §7 as a side effect.
>
> **Still refused, by name in the log:** a victim with no `Role`; a role
> `bots.types` does not carry; and a role that has no entry at the difficulty
> asked for. `normal` is the difficulty asked for, and it is a default rather
> than a fact — the raid report carries no per-victim difficulty,
> `RaidSettings.BotSettings` is `{IsScavWars, BotAmount}`, and
> `/client/match/local/start` answers `aiDifficulty: "AsOnline"`. It costs the
> player nothing on a real database, where all 57 roles carry `normal`; on one
> where a role does not, that role's kills move no standing and say so.
>
> **What happened to the invented constant.** `fenceKarmaOnScavExtract` stays
> at 0.01 and stays a setting. Its *justification* changed and the comment
> saying so was rewritten: it used to be the only input, so it alone had to make
> Fence's −7..+6 ladder reachable, and "a scale that makes the number mean
> something" was a real argument for it. It is not any more — BSG's per-kill
> numbers set the scale now, and 0.01 is worth a quarter of one `assault` kill.
> It was kept rather than zeroed for the same reason the death penalty is zero:
> **removing it takes something from the player and nothing in the data can be
> pointed at to justify the removal**, and no figure for surviving a scav run
> exists in `build/db/db.json` or in the dump at all. It is now the only
> invented number in Fence's karma, it is named as such in `emu/traders`, and
> `config.json` can set it to zero.
>
> `paidExitStandingNumerator` (0.2) is still unused: nothing in the raid report
> says which exit was taken or that it was paid for, so there is nothing to
> multiply.

### 2. `OpenRandomLootContainer` — a button that does nothing, with no reason written anywhere

**What the player loses.** New Year gifts (`new_year_gift_small`, `_medium`,
`_big`), `random_loot_container`, `pumpkin_rand_loot_container` and the three
Twitch-event containers sit in the stash and cannot be opened. Nine items, and
the action 404s.

**Why it is refused.** It is not. `docs/EMULATOR-COVERAGE.md:396` reads
`| OpenRandomLootContainer | **not served** |` — no reason column at all — and
`mods/tarkov/README.md` does not mention it.

**Whether that reason is still true.** There is no reason to test. Exactly one
thing is missing: the reward *pool*. The **counts** are already in the database —
`new_year_gift_small._props.Grids[0]._props` gives `minCount: 3, maxCount: 5,
maxWeight: 3` with `Filter: []` (anything) and an `ExcludedFilter` of the item
root. The pool lives in `InventoryConfig.RandomLootContainers`
(`Dictionary<MongoId, RewardDetails>` in the dump), i.e. SPT's
`configs/inventory.json`, which the importer does not bring. It already brings
`configs/quest.json`, so there is both a precedent and a place to put it.

**Cost to close.** One importer row and one item-event arm that rolls
`minCount..maxCount` out of a named pool.

**Verdict: blocked on a nameable importer row — and no document has ever said
so.** Which is why it is on this list rather than the one below.

### 3. `/client/game/profile/voice/change` — reports success, changes nothing

**What the player loses.** The voice selector on the character screen appears to
work and does not. `Info.Voice` is never written by this route. This is the
exact failure mode `mods/tarkov/README.md` §6.3 names as the one the server
exists to avoid, arrived at from the other side: not a refusal the client
swallows, but a success the server invents.

**Why it is refused.** `mods/tarkov/tarkov.nim:1493` binds the route to
`onOkStatus`, which returns `{"status":"ok"}` and nothing else.
`docs/EMULATOR-COVERAGE.md:203` records it as **"served"**, unqualified —
directly under `ChangeNickname`, which really does write
(`mods/tarkov/tarkov.nim:291-304`).

**Whether that reason is still true.** There is no stated reason. The dump gives
the whole contract: `ProfileChangeVoiceRequestData` has one property,
`MongoId Voice`, and `ProfileController.ChangeVoice` writes it. `emu/customise`
already has every piece — `entryAllowed`, the `Voice` branch check
(`mods/tarkov/emu/customise.nim:319-331`), and the rule that `Info.Voice` holds
the entry's `_name` and not its id.

**Cost to close.** About ten lines: parse `voice`, run it through
`planCustomisation`'s voice arm, save. Or — if the client turns out never to use
this route — change the coverage row to say so. That needs a raid; "served" as it
stands is a claim nobody checked.

**Verdict: nobody has looked.**

> **Closed.** The route is bound to `onVoiceChange`, which reads `voice` (and
> `Voice`, because the dump names the property that way and every other body
> this client sends is camel-cased), runs the id through
> `emu/customise.applyVoice` — the same `planCustomisation` voice arm the item
> event uses — and saves. So the id is checked against the table, against the
> `Voice` branch, against the profile's side and edition, and `Info.Voice`
> receives the entry's `_name` rather than its id, all by the code that already
> did those things. A refusal is now a refusal: the other faction's voice
> answers "not available to Usec" instead of `{"status":"ok"}`.
>
> **Still refused:** an id that is not plain (letters, digits, `_`, `-`, up to
> 64 characters) is refused before the lookup, because the id is about to be
> put inside a JSON literal and a quote in it would be a body this server wrote
> and did not mean.
>
> `docs/EMULATOR-COVERAGE.md:203` still records the route as "served", which is
> now true. That file is generated and was not edited here.

### 4. `daytime` on quest kills — the raid configuration establishes the clock, and this server throws it away

**What the player loses.** Twelve `Kills` sub-conditions across eight quests,
when and only when the client did not report its own counter: *Chumming*, *The
Tarkov Shooter — Part 5*, *Insomnia*, *The Survivalist Path — Eagle-Owl*,
*Thirsty — Hounds*, *Conservation Area*, *Illegal Logging* (four conditions) and
*Enough Drinks for That One* (two).

**Why it is refused.** `mods/tarkov/emu/questcond.nim:635`, reasoned at
`mods/tarkov/emu/questcond.nim:573-579`: "`Victim.Time` is a `String` and
nothing establishes which clock it is on … EFT runs its clock at seven times
real time with a per-raid offset, so a wall clock read as a raid clock
over-credits about half the time."

**Whether that reason is still true.** The premise is right and the conclusion
does not follow, because `Victim.Time` is the wrong input. Four things establish
the raid's clock without reading it at all:

* `RaidSettings.TimeVariant` is a `DateTimeEnum` of exactly `CURR` and `PAST` —
  the client's own day/night selector. This server already parses it, at
  `mods/tarkov/emu/raid.nim:278`, and then discards everything but the raid id
  (`mods/tarkov/tarkov.nim:948-956`).
* `GetRaidConfigurationRequestData` carries `prop Boolean IsNightRaid` outright.
* `RaidSettings.TimeAndWeatherSettings` carries `Nullable<Int32> HourOfDay` and
  a `TimeFlowType` enum of `x0, x0_14, x0_25, x0_5, x1, x2, x4, x8` — the start
  hour and the acceleration, posted by the client.
* `WeatherHelper.IsNightTime(DateTimeEnum timeVariant, String mapLocation)` in
  the dump is proof of method: SPT decides night from **timeVariant and map**,
  never from a victim's timestamp.

The acceleration is not even an external fact here: `emu/raid.weatherFrom`
*publishes* `acceleration` to the client in the weather response, so this server
is the authority on it. And the raid length is bounded per map by
`locations.<map>.base.EscapeTimeLimit` — present on all 19 maps; Customs 40,
`factory4_day` 20, `factory4_night` 25, and Factory encodes the time in the map
name.

Which gives a check that needs no victim clock and cannot over-credit: credit a
kill when the **entire** interval `[startHour, startHour + EscapeTimeLimit ×
acceleration]` lies inside the condition's window; refuse by name when the
window is straddled. Every window in this database is in-game night — 22→10,
21→4, 21→5, 21→6, 22→7 — and a night raid's whole span sits inside them.

**Cost to close.** Keep the parsed raid configuration per session instead of
dropping it — the parse already exists — plus a `daytimeMet` of about twenty
lines that answers only when the whole span is decided and refuses otherwise.

**Verdict: nobody has looked.** The refusal is not wrong to distrust
`Victim.Time`; it is wrong that `Victim.Time` is the only source.

> **Closed, and narrower than this section proposed.**
> `emu/questcond.daytimeVerdict` answers one of three things about a window:
> the raid's whole span is **inside** it (credit), **outside** it (a verified
> no, handled exactly as a wrong `Location` is), or **across its edge** (refused
> by name). `emu/raid.raidClock` builds the span and `tarkov.nim` keeps it in
> `gRaidClock` instead of dropping everything but the raid id.
>
> Three departures from the plan above, all in the direction of refusing more:
>
> * **Only `hourOfDay` is read.** `timeVariant` and `isNightRaid` say *which*
>   time was picked, not what it is, and neither can establish that a span sits
>   inside `22 -> 07`. A request carrying only those is refused rather than
>   turned into an hour by a rule invented here. `isRandomTime` refuses the
>   clock outright — it is the client saying the hour it sent is not the hour it
>   will play.
> * **The acceleration is not taken from the weather response.** This section
>   argued that `emu/raid.weatherFrom` publishes it, so this server is the
>   authority on it. It is, and the value it publishes is **0** — which would
>   collapse every raid to a single instant and credit almost everything. The
>   client's own `timeFlowType` is used when it sends one; when it does not, the
>   **ceiling of the `TimeFlowType` enum, x8**, is used, because a span read too
>   short is a kill credited that was not earned and every error a ceiling makes
>   is a refusal.
> * **A map whose `EscapeTimeLimit` is absent, zero, or longer than half a day
>   decides nothing.** `develop` at 60000 minutes and `hideout` at 99999 are
>   exactly that, and neither is a raid.
>
> Whether this closes anything for a real player is one raid's worth of unknown,
> and it is the honest size of the caveat: if the live client posts
> `timeVariant` alone, all twelve conditions stay refused and the refusal is
> correct. What is settled is that the *arithmetic* works and that the two real
> tables leave room for it — `tools/realtest` checks the narrowest window in
> `templates.quests` (7 hours, *The Survivalist Path — Eagle-Owl*, 21->4)
> against the longest playable map at the enum's ceiling (Streets, 50 minutes,
> 6 h 40), and the twenty minutes of margin between them is the whole reason
> the feature is not vacuous.

*The caveat that belongs to this repository: no raid has ever been run against
BSG's client, so which of `timeVariant`, `isNightRaid` and
`timeAndWeather.hourOfDay` the live client actually posts is a hypothesis. All
three are in the request DTO; the check should read whichever is present and
refuse when none is.*

### 5. `weaponCaliber` — every caliber the quests name maps cleanly onto the item table

**What the player loses.** Six `Kills` sub-conditions, all in one quest: *Gun
Connoisseur*. Fallback path only.

**Why it is refused.** `mods/tarkov/emu/questcond.nim:640`, reasoned at
`mods/tarkov/emu/questcond.nim:585`: "the report carries no caliber, and deriving
one from a weapon id needs the item table this module does not read."

**Whether that reason is still true.** Half of it. The report genuinely carries
no caliber. But the derivation is a one-hop lookup the database supports exactly:
`templates.items.<id>._props.ammoCaliber` is present on every weapon, and all six
of *Gun Connoisseur*'s strings resolve:

```
5.56x45   -> Caliber556x45NATO (35 items)    9x19      -> Caliber9x19PARA (28)
5.45x39   -> Caliber545x39 (19)              9x39      -> Caliber9x39 (13)
7.62x39   -> Caliber762x39 (22)              7.62x54 R -> Caliber762x54R (19)
```

"this module reads no database" is an architecture choice, not an absence — and
a real one worth keeping, since `emu/questcond` is pinned at load against
literal tables. But it should be stated as the constraint it is.

**Cost to close.** Pass a caliber-of-template lookup into `killCredit` from the
caller, which already has the database. Depends on the same unknown as the
`weapon` list — whether `Victim.Weapon` is a template id. One raid settles both.

**Verdict: nobody has looked** at the derivation; **blocked on one raid** for the
input.

---

## Sixth and seventh, cheapest of all: two reasons that are simply wrong

Neither costs a player anything today. Both should be corrected, because a wrong
reason in this repository is how a gap survives.

**`emu/repair` — "converting needs an exchange rate and there is none."**
`mods/tarkov/emu/repair.nim:473-477` says "the only rate in this database is the
handbook price of a currency item, which prices a *stack of notes* rather than an
exchange." Both halves are false.
`traders.<id>.base.repair.currency_coefficient` **is** the rate, and it sits next
to the currency it converts: 1 for every rouble trader, `0.00847457627118644`
(= 1/118) for Peacekeeper. And the handbook prices are per unit, not per stack —
RUB is `Price: 1`, USD `121`, EUR `134`, and 1/121 = 0.00826 agrees with the
trader's own coefficient to 2.5%. The refusal is unreachable in practice anyway:
Peacekeeper is the only non-rouble trader and his `repair.availability` is
`false`; only Prapor, Skier and Mechanic repair, all in roubles.
**Verdict: nobody has looked** — the cost to close is reading one field already
inside the trader base this module opens.

> **Closed.** `doTraderRepair` reads `repair.currency` and, when it is not
> roubles, `repair.currency_coefficient`, and charges that currency at that
> rate. A currency with no coefficient beside it is refused by name rather than
> billed in roubles — which would have taken 118 times the price the screen
> showed. It buys a player nothing today, exactly as this section says: the
> branch is unreachable on a real database. The wrong reason was the thing
> worth fixing, and a mod adding a trader who charges dollars is what would
> have found it the expensive way.

**`emu/traders` — "there is no 'is this the scav trader' flag on `TraderBase`."**
`mods/tarkov/emu/traders.nim:242-246` hard-codes Fence's id on that basis. There
is a flag, one level up: `globals.config.FenceSettings.FenceId` =
`"579dc571d53a0658a154fbec"`, the game's own statement of which trader Fence is.
**Verdict: nobody has looked.** Cosmetic — the hard-coded value is correct.

> **Closed.** `emu/traders.fenceId()` reads `FenceSettings.FenceId` and falls
> back to the constant, which stays: a database with no `globals.config` must
> still have karma. The comment claiming no such flag exists is gone.

---

## The rest, with verdicts

### Permanent — the data is not anywhere

Each row says where it was looked for.

| Refusal | What the player loses | Why, in the code's words | Where it was looked for | Verdict |
|---|---|---|---|---|
| **The gym minigame** (`emu/gym`) | a client that lies about fifteen circles is believed | "the circle shrinks in the client and the mouse is in the client" | not a data question — the input does not exist in this process | **permanent.** Bounded by economics, not verification: 2 energy and 2 hydration a hit against a 30-point floor |
| **`MusclePain`** (`emu/gym.nim:472`) | the workout is slightly cheaper than the game's, in the player's favour; a warning says so | the QTE names it and nothing defines it | `grep -o '"[A-Za-z]*MusclePain[A-Za-z]*"'` → `MildMusclePain` ×2, `MusclePain` ×1 (the QTE itself), `SevereMusclePain` ×2. `globals.config.Health.Effects` has 28 effects and no `MusclePain` | **permanent.** Two facts would have to be invented: which severity, and which body part |
| **`GymArmTrauma`** (same) | a missed circle ends the session but costs no injury | same | `grep -o 'GymArmTrauma' \| wc -l` → **1**, the QTE entry itself | **permanent** |
| **Poster and statuette slots** (`emu/decorate.nim:318-327`) | 47 of the hideout's 85 decoration entries do nothing | "a slot is a place, not a thing: 47 of them and not one carries an `itemId`" | the README says the missing fact is an `itemId` on the slot. The real one is worse and settles it: in `templates.customization` the `PosterSlot` node has **0 children** and `ItemSlot` has **0**, against `Floor` 13, `Wall` 13, `Ceiling` 11, `ShootingRangeMark` 10, `MannequinPose` 10. There is nothing in this database to put in a slot | **permanent** |
| **Cultist circle** (`CicleOfCultistProductionStart`) | the circle cannot be started | coverage: "imports as a single entry carrying nothing but an `_id`" | verified: `hideout.production.cultistRecipes` is `[{"_id": "66827062405f392b203a44cf"}]`, one key | **permanent** |
| **`weaponModsInclusive` / `Exclusive`** (`emu/questcond.nim:638`) | 14 sub-conditions across 12 quests, fallback only — *Test Drive* parts 1-6, *Silent Caliber*, *The Punisher — Part 2*, *Wet Job — Part 1*, *The Tarkov Shooter — Part 7*, *Hunting Trip*, *Connections Up North* | "the report carries nothing about what was bolted to the gun" | `Victim` in the dump has 13 members and none is about the weapon's mods | **permanent** |
| **`equipmentInclusive` / `Exclusive`** (`emu/questcond.nim:643`) | **nothing** | "what the player was wearing at the moment of the kill is not in the report in any form" | true — and the branch is **dead**: 0 of the 283 `Kills` sub-conditions in this database carry either key | **permanent, and unreachable** |
| **`enemyEquipment*` / `enemyHealthEffects`** (`emu/questcond.nim:646-648`) | 5 sub-conditions in 5 quests, fallback only — *The Invisible Hand*, *Enough Drinks for That One*, *The Price of Celebration*, *This Is My Party*, and *The Huntsman Path — Controller* (`Stun`) | "`Victim` carries no equipment and no effects" | confirmed against the dump's `Victim` | **permanent** |
| **Mannequin *slot key*** (`emu/decorate`) | a wrong key is a pose stored where the client never reads it | "there is no table of mannequins in this database" | confirmed: `MannequinPose` has 10 entries and every *pose* is validated against them; there is no mannequin *slot* table anywhere | **permanent**, and correctly scoped — the pose half is checked |
| **`RecordShootingRangePoints`** | the board shows whatever the client says | "nothing in the database reads the counter" | `grep -c ShootingRangePoints build/db/db.json` → **0** | **permanent** |
| **Durability put *up*** (README §4) | a cheating client is not caught | "the two are indistinguishable in the document that arrives" | no per-shot or per-raid wear callback in the dump, no wear action in `ItemEventActions` | **permanent** unless a pre-raid `upd` diff is written |
| **Trader standing from buying and selling** (README §5) | reputation only ever moves on quest rewards | "the reference gives the three requirements a loyalty level has and says nothing about what a purchase is worth" | verified: `loyaltyLevels[]` carries `minLevel`, `minSalesSum`, `minStanding` and no rate; `FenceSettings.Levels` (14 levels, 25 keys each) carries prices and exits and no standing rate. SPT's own rates live in `InRaidConfig` (`ScavExtractStandingGain`, `CarExtractBaseStandingGain`) — a server config, not BSG data | **permanent** from the game's data. Note the other half already works: `salesSum` **is** credited on every purchase (`emu/trading.nim:406`) and loyalty re-derives from it, so levels do advance |
| **Insurance on an item sold before the raid** | the entry is discharged with no message | "asking the same unanswerable question every raid is worse" | design | **permanent by design** |
| **`emu/ids` cannot read or write the run number** | the mod refuses to load | a duplicate id breaks the client's `parentId` walk | operational | **permanent by design**, and the right answer |
| **`emu/store` unreadable key** | a read-only path serves empty; a writing path refuses | "'nothing here' and 'unreadable' used to answer the same value" | operational | **permanent by design** |
| **`emu/selfchecks` failure** | only `/aowlspt/tarkov/selfcheck` is served | load-time arithmetic | operational | **permanent by design** |
| **`emu/health` unknown medkit or food template** | the heal is refused | "an unknown medkit healing for free is an infinite medkit" | correct | **permanent by design** |
| **`emu/health` missing `HealPrice` / `RemovePrice`** | treatment refused, naming the effect | "free healing is not the same answer as 'the price is not known'" | live values present and used — a hit point 30, `Fracture` 1000, `Intoxication` 42700 | **permanent by design**; unreachable on this database |
| **`emu/health` eighth body part** | refused rather than added | "a part the client cannot draw" | correct | **permanent by design** |
| **`emu/repair` template with no `RepairCost`** | refused, not repaired free | "'the database does not say' must not become an invented penalty on somebody's gear" | correct | **permanent by design** |
| **`emu/customise` unknown id, wrong body part, wrong faction, ungated edition** | refused by name | "this is a write the client asks for **by id**" | correct; the four empty-`Side` entries are mannequin dressing and cultist voices | **permanent by design** |
| **`emu/decorate` unknown condition kind** | refused, not waved through | "a gate nobody can evaluate is still a gate" | the four kinds used are `Block` 18, `Quest` 12, `Level` 3, `HideoutArea` 1 — all evaluated | **permanent by design**; unreachable on this database |
| **Short payments** (`emu/trading`, `emu/production`, `emu/hideout`) | nothing is taken | "there is no transaction to roll back, so the check has to come first" | design | **permanent by design** |
| **Degradations rather than errors** (`emu/bots` with no role data, `emu/templates` and `emu/traders` with no database, `emu/grid`'s 10×68 fallback, `emu/market` with no sources, `emu/mail`'s `remove`, `emu/numbers` below 5×10⁻⁷, the `emu/notes` / `emu/personal` / `emu/inventory` validation refusals, and `emu/repeatable`'s two change-cost guards) | each stated in README §3 | each stated there | `templates.repeatableQuests.templates` was checked against the two-currency guard: all four skeletons carry exactly one rouble entry (5000, 5000, 5000, 12000), so both `emu/repeatable` change-cost refusals are unreachable guards, and correctly so | **permanent by design** |

### Blocked on something nameable

| Refusal | What the player loses | What it is blocked on | Cost to close |
|---|---|---|---|
| **Clothing unlocks unenforced, and Ragman's clothing shop unserved** (`GetTraderSuits`, `CustomizationBuy`) | the whole clothing shop is a screen that cannot be opened; every wardrobe entry is free | `traders/<id>/{suits,bearsuits,usecsuits}.json` — **3 files, 0.16 MB** — which `aowl importdb` deliberately skips (`docs/IMPORTDB.md:117`). Verified absent: no trader in the database has a `suits` key | one importer row, one route, one item-event arm. The **largest player-visible screen** on this whole list |
| **`OpenRandomLootContainer`** | nine containers cannot be opened; see §2 above | `configs/inventory.json`'s `RandomLootContainers` | one importer row |
| **Weather is one constant sky** (`emu/raid.weatherFrom`) | every raid looks the same — 18 °C, no cloud, no rain, `season: 1` | `configs/weather.json` is a *generator's settings*, not a response: `weather.presetWeights.SUNNY.clouds = {"-1": 5, "-0.8": 2}` is a weight table. Verified: `db.configs` contains **only** `quest` | something that *renders* weather — a generator, not an importer row. The extension point already exists: write the whole response to the `weather` path |
| **The flea renewal fee** (`emu/market.renewOffer`) | renewals are free, which is more generous than the game | the **unit** of `globals.config.RagFair.renewPricePerHour` = `0.5`. Roubles per hour and percent-of-price per hour are four orders of magnitude apart on an ordinary offer. The dump gives the name and the type (`Single RenewPricePerHour`) and nothing else. Its neighbours do not settle it: `communityTax` 3 is plainly a percent, `offerPriorityCost` 6 is plainly a flat price | one fact. SPT's `RagfairController.ExtendOffer` is open source and would settle it in a minute; the surface dump carries no method bodies, which is the only reason this is still open. `maxRenewOfferTimeInHour` 48 **is** enforced |
| **`weapon` when the report spells a display name** (`emu/questcond.nim:698`) | 73 sub-conditions across 47 quests, fallback only — *Stirrup*, *The Punisher — Part 1*, *A Shooter Born in Heaven*, *Psycho Sniper*, *Grenadier*, *Hunting Trip*, *Fearless Beast* and forty more | `Victim.Weapon` is typed `String` in the dump and the condition's list is template ids | **one raid with one weapon-qualified quest accepted.** The largest single kill-qualifier population on the list, and the cheapest thing to learn |
| **`heal_price_coef`'s direction** (README §6.4) | at loyalty 3-4, treatment may be priced the wrong way round | Therapist's rises with loyalty (100 → 135) where a discount would fall; read inverted it contradicts `repair_price_coef`, whose direction Fence's 300 establishes | **one raid at loyalty 3.** At level 1 both readings give 100 and agree exactly |

### `SellAllFromSavage` — the design decision, examined

`mods/tarkov/emu/scav.nim:542, 569`.

**What the player loses.** One button on the post-scav-raid screen. Nothing
else: the loot is already in the PMC stash and the refusal says so.

**Why it is refused.** Not for want of data. The handbook prices are loaded,
Fence is in `traders` with his `PriceModifier` and his loyalty levels, and
`emu/mail` can pay roubles. What is missing is *the items*: `endScavRaid`
(`mods/tarkov/emu/scav.nim:467`) has already moved everything a surviving scav
carried into the PMC stash at `/client/match/local/end`, which the client posts
**before** it draws the screen the button is on.

**Is that a design decision worth keeping, or a bug?** Worth keeping, and it is
load-bearing rather than incidental. The scav document is the PMC's stash spliced
in at read time (`mods/tarkov/emu/scav.nim:279` builds it with an empty
`TradersInfo`; the inventory is the PMC's). There is exactly one copy of the
stash and therefore no way for the two to diverge — no duplication bug, no
question of which is authoritative, no reconciliation pass. "Sell everything in
the scav's inventory" against that document would sell the player's entire stash:
the *worst* available failure in a server whose README says there is no undo
anywhere in it.

The alternative — a real scav stash — buys one convenience and costs a second
inventory to keep consistent across raid end, insurance return, mail collection
and profile save. `docs/BACKLOG.md` Group F is the right home for it. Two things
would improve the current answer without changing the design: the refusal should
say *where the loot went* ("already in your stash — N items came home"), and
`TotalValue`, which is currently logged, should be quoted in that sentence so the
player sees the number the client just showed them.

**Verdict: permanent by design, and correctly so.** One caveat that belongs to
this repository: nobody has watched the real client draw that screen, so the
claim that `/client/match/local/end` always precedes it is a hypothesis — a
well-founded one, since the button is on the results screen and the results
screen is what the end call produces, but a hypothesis.

---

## Things refused in code that no document mentions

Three, in descending order of how much they matter. **The first two are
closed** — see the notes on §3 and §1 — and are left here as written, because
the point of the list is what the sweep found rather than what it now says.

1. **`/client/game/profile/voice/change` reports success and writes nothing**
   (`mods/tarkov/tarkov.nim:1493`), while `docs/EMULATOR-COVERAGE.md:203`
   documents it as "served". See §3 above. This is the most interesting kind:
   not an undocumented refusal but an undocumented *non*-refusal, in a server
   whose whole thesis is that a refusal must be visible.

2. **Scav-kill Fence karma is dropped on the floor**
   (`mods/tarkov/emu/scav.nim:197`, `mods/tarkov/emu/traders.nim:249`). Not
   listed as a refusal or as a gap anywhere. See §1 above.

3. **`equipmentInclusive` / `equipmentExclusive` is dead code**
   (`mods/tarkov/emu/questcond.nim:643`). It is listed in
   `mods/tarkov/README.md` §3 among the qualifiers that cost the player
   something. It costs nothing: no `Kills` sub-condition in this database carries
   either key. Harmless, but it inflates the apparent size of the kill-qualifier
   gap.

Two smaller notes from the same sweep, both in the server's favour:

* **Achievements are in better shape than the refusal implies.** All 53 have a
  non-empty finish group — the key is `availableForFinish`, lower case. Of their
  96 finish conditions, **92 are `CounterCreator`**, which
  `emu/questcond.isProgressKind` evaluates, and 4 are `Block`, which is the
  table saying "not obtainable". So the empty-group refusal is a guard that never
  fires, and almost every achievement is reachable.
* **The gym's stated unknown is smaller than the README says.**
  `mods/tarkov/README.md` §3 says of `GymEffectivity` that "nothing says whether
  it scales gain, chance or duration". Two of those three are named by the data:
  the QTE's `finishEffect` carries `time: 86400`, so the duration is stated, and
  `SevereMusclePain.TraumaChance` is 10 against `MildMusclePain`'s 0, so the
  chance is stated — which by elimination leaves `GymEffectivity` as the gain
  multiplier, and also explains what `GymArmTrauma` is for. The refusal still
  stands, on the two facts that really are absent: **which severity the workout
  applies, and which arm carries it.**

---

## Where each claim was checked

* `build/db/db.json`, 39.40 MiB — the tables `templates.{items, handbook,
  quests, repeatableQuests, customization, achievements, prestige}`,
  `globals.config`, `configs`, `locales`, `traders`, `hideout`, `locations`,
  `bots`.
* `reference/spt-4.1-surface.json`, 1,704 type entries — members only, no method
  bodies and no route strings, which is why three verdicts above end at "one
  raid" or "one open-source file".
* `mods/tarkov/emu/*.nim` and `mods/tarkov/tarkov.nim` — 193 `problems.add`
  sites, of which the great majority are ordinary validation ("no such item")
  rather than the epistemic refusals this document is about.
