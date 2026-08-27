# aowl.tarkov — the game server

This is a Tarkov **server**, written from scratch in nimony, that the real
Escape from Tarkov client talks to over the real wire. Profiles, the stash,
traders, the flea market, quests, the hideout, raids, insurance, the scav, mail.

```
aowl build-mod mods/tarkov
```

It is a **mod**, not part of the backend. It imports `aowlspt`,
`aowlspt/server` and `aowlspt/json` — the same public imports any other mod has
— and reaches the host through nothing else. That constraint is the point of the thing: if a game
server needed a private door into the host, the plugin API would not be enough
to write one with, and everyone else's mods would hit the same wall one endpoint
later. Every gap found while writing it was closed in the API rather than worked
around here.

|  | measured |
|---|---:|
| modules | 37 under `emu/` plus `tarkov.nim` |
| lines | 21,500 |
| routes registered | 95 — 94 in `/client/`, 1 in `/aowlspt/` |
| item-event action arms | 152 |

```
wc -l mods/tarkov/tarkov.nim mods/tarkov/emu/*.nim | tail -1
grep -oE 'serve(Prefix)?\("[^"]+"' mods/tarkov/tarkov.nim | wc -l
grep -rn 'of "' mods/tarkov/emu/*.nim | wc -l
```

---

## 1. What it is, and what it is not

**It is not SPT.** It shares SPT's *database shape* — `aowl importdb` reads an
SPT install and produces `build/db/db.json` — and it shares nothing else. No
TypeScript, no C#, no dependency injection container, no route registry, no mod
loader of SPT's. Every route below was written against the reference dump and
answers out of this repository's own JSON layer.

**The spec, such as it is, is `reference/spt-4.1-surface.json`.** It is a
metadata dump of SPT 4.1: types and members, no method bodies and **no route
strings**. So it establishes shapes exactly and URLs not at all.

Two consequences run through everything below. **Every one of the 94 client
paths this mod registers is a well-known client path, not one derived from the
dump** — the dump cannot supply one. Where not even a well-known path could be
established, `docs/EMULATOR-COVERAGE.md` marks the row *(url unverified)*
rather than guessing silently; there are 12 such rows and all 12 are operations
this server does not serve anyway. And **every enum the client sends on the wire
is matched by member *name***, because the dump carries names and not values —
10 places in this mod carry an *(unverified)* marker for exactly that reason
(`grep -rn 'unverified' mods/tarkov/`).

**It is not privileged and it is not required.** Other mods write into the same
database (`mods/morebots`, `mods/icebreaker`, `mods/blackdivision` all write
`locations.<map>.base`), and `/client/locations` sends `base` out byte for byte
so that everything they write arrives.

### Read this first

**Nothing in this project has ever run against BSG's client.** Not one request
in this README has been answered to the real game. Everything below was
established one of three ways, and the three are not equally strong:

| how | what it establishes | what it cannot |
|---|---|---|
| the reference dump | the **shape** of every request and response DTO, property by property | any URL, any enum *value*, any arithmetic — a metadata dump has no method bodies |
| `build/db/db.json` (39.40 MiB, 4,673 item templates, 558 quests, 5,790 assort items, 12 traders, 19 maps) | what the game's own data actually says | what the client *does* with it |
| the four suites (`emutest`, `realtest`, `soak`, `fuzzwire`) | that this server is self-consistent and does not fall over | that the client agrees with any of it |

Section 6 is the list of things a single real raid would settle that none of the
three can.

---

## 2. What it answers

**`docs/EMULATOR-COVERAGE.md` is authoritative for this and this README does not
restate it.** It is derived by re-running four commands over
`reference/spt-4.1-surface.txt` and over this mod, and it carries the split
operation by operation with a reason on every row.

The four derivation commands reproduce, run 2026-08-19:

| command | count |
|---|---:|
| the `Callbacks` sweep over `reference/spt-4.1-surface.txt` | **226** methods |
| the `ItemEventActions` sweep over the same file | **55** fields |
| `grep -oE 'serve(Prefix)?\("[^"]+"' mods/tarkov/tarkov.nim` | **99** routes |
| `grep -rn 'of "' mods/tarkov/emu/*.nim` | **152** arms |

Of the 226 callbacks, 15 are SPT's own plumbing (the launcher, mod bundles, the
mod loader) and are not client requests. That leaves **211 client-facing
operations**, split:

| | operations |
|---|---:|
| served, and shaped against the reference DTO | 129 |
| served, deliberately empty or flattened | 21 |
| not served | 61 |

**That split is generated, not a hand join.** `tools/coverage.nim` writes it out
of `docs/coverage-rows.json` — one row per callback method — and out of
`mods/tarkov/tarkov.nim` itself, and `aowl test` fails if the three numbers are
not what the code says. It was a hand join moved by delta until 2026-08-19, and
this paragraph used to say so and to carry the argument for building the
generator as `docs/BACKLOG.md` B11; B11 is closed. The figures here were
127 / 24 / 60, the last of five hand-joined passes. Read the numbers as measured
and the per-row reasons as exact.

**The distinction that matters is not served/absent.** A route answering
`{"err":0,"data":null}` where a populated object belongs does not fail at the
request — it fails three screens later, on a null the client dereferenced
because the server said everything was fine. That is why `emu/builds` ships
three empty lists rather than `{}`, and why the coverage doc has a *was
mis-shaped* marker at all.

### Before the game starts

Five of those 99 routes are not the client's at all. `/aowlspt/tarkov/selfcheck`
is one (§7); the other four are the **launcher's**, and they exist because of a
gap the coverage table cannot show: the client is handed its session on the
command line as `-token=<24 hex>` and carries it as `Cookie: PHPSESSID=<token>`
from its first request onwards, so *which profile is being played* has to be
decided before any `/client/` route is called. Every one of those routes already
needs the answer.

| route | body | answers |
|---|---|---|
| `/aowlspt/tarkov/launcher/ping` | — | `{"ok":true,"server","version","edition","defaultSide","profiles":N}` |
| `/aowlspt/tarkov/launcher/profiles` | — | `{"ok":true,"profiles":[...]}` |
| `/aowlspt/tarkov/launcher/profile/create` | `{"nickname","side","voice","edition"}` | `{"ok":true,"token":"<24 hex>","profile":{...}}` |
| `/aowlspt/tarkov/launcher/profile/select` | `{"id":"<24 hex>"}` | `{"ok":true,"token":"<24 hex>","profile":{...}}` |

Three things about that table are load-bearing.

**The token is the profile id.** Not a third identifier mapped onto one: create
and select both bind the session to itself, and `emu/sessions` persists the
binding — so a token minted before the first launch is still the profile the
client is playing after the server has been restarted under it, with nothing
re-selected. `emutest` proves exactly that across its restart.

**These are not `/launcher/*`.** SPT has a launcher API and this is not it. Its
4.1 shape is `LauncherV2Callbacks` in `reference/spt-4.1-surface.txt`, keyed on
a **username** with no counterpart here, and that dump carries no route urls at
all — so the paths would be guesses. Wearing another server's url with a
different body underneath invites a caller that speaks the real protocol and
fails on the third field. Nothing in this tree speaks SPT's launcher API, and
SPT's own launcher wants a great deal more from a server than profiles before it
will drive one, so compatibility here would be a claim rather than a feature.

**A caller must send `Accept-Encoding: identity`.** The backend zlib-deflates
every response by default because that is what the game expects and does not say
so in a header; a launcher that omits the header gets a body starting `78 9c`.
Request bodies may be plain — `inflateBody` passes through anything that does
not look framed — so a launcher needs no zlib at all in either direction.

**A gap's stated reason is the part to distrust.** Seven operations this project
recorded as "blocked on data the importer does not bring" were closed by
grepping `build/db/db.json` for the table they claimed to need and finding it
already there. None needed an importer row. Before scheduling anything in the
*not served* column, grep the database first.

---

## 3. Every refusal, and what it costs the player

This server **refuses rather than invents**. When it cannot establish something,
it says so by name and the player is told, instead of a plausible number going
into a document a career is stored in.

Refusals surface as `warnings[].errmsg` inside an `err:0` envelope, built by
`itemEventResponse` in `tarkov.nim`. A refused action is a sentence the player
can act on, not an item that slides back with no explanation. Note the envelope:
a refusal is **not** a transport error, so anything asserting on `err` will read
a refused hideout upgrade as a success — a real defect that once let a test pass
with the area deleted from the fixture entirely.

### The five worth reading in full

**`SellAllFromSavage` — refused by this server's own design, not by missing
data.** `emu/scav.refuseSellAll`. Everything the operation needs is loaded: the
handbook prices, Fence's `PriceModifier` and his loyalty levels, and an
`emu/mail` that can pay roubles. What is missing is *the items*. `endScavRaid`
has already moved everything a surviving scav carried into the PMC stash at
`/client/match/local/end`, which the client posts **before** it draws the screen
the button is on. And that is not an accident to undo here: the scav has no
stash of its own by design — the scav document is the PMC's stash spliced in at
read time, so there is exactly one copy and it cannot diverge. "Sell everything
in the scav's inventory" against the document this server serves would sell the
player's whole stash. Its one member, `TotalValue`, is the client's arithmetic
and is logged rather than paid. **Cost:** one lost convenience — the loot is
already home and the player is told so.

**The gym — the server does not adjudicate the minigame, and does not pretend
to.** `emu/gym`. The circle shrinks in the client and the mouse is in the
client; whether any individual circle was hit is not checkable in this process
and is never checked. What *is* checked, all of it from `hideout.qte` rather
than from a constant: the gym exists (area 23 at level 1), the requirements the
entry carries (30 energy, 30 hydration, no `Fracture` on either arm), that
`results` is not longer than the fifteen events defined, and that a `false`
appears only as the **last** element — because `singleFailEffect` carries
`result: "Exit"`, which is the database saying one miss ends the session.
**Cost:** a client that lies about hitting fifteen circles is believed about
those fifteen booleans. What bounds it is not verification but economics: at
2 energy and 2 hydration a hit, a full run costs 30 to 32 of each against a
30-point floor, so the gym cannot be run indefinitely without food and water.

**`MusclePain` and `GymArmTrauma` — named by the QTE entry and defined nowhere
else in the database.** Verified:

```
grep -o '"[A-Za-z]*MusclePain[A-Za-z]*"' build/db/db.json | sort | uniq -c
#       2 "MildMusclePain"     (globals.config.Health.Effects, and a locale)
#       1 "MusclePain"         (hideout.qte, results.finishEffect)
#       2 "SevereMusclePain"
grep -o 'GymArmTrauma' build/db/db.json | wc -l      # 1 — the same entry
```

`globals.config.Health.Effects` defines `MildMusclePain` and `SevereMusclePain`
and nothing called `MusclePain`. Applying one would mean inventing two facts —
which effect it becomes, and which body part carries it. Neither is applied.
**Cost:** the workout is slightly cheaper than the real game's, in the player's
favour, and a warning on the response says so rather than hiding it.
(`MildMusclePain.GymEffectivity` is 0.5 and the severe one's is 1.0. That is
plainly about this feature and is not used, because nothing says whether it
scales gain, chance or duration, and the mild-is-half ordering rules out the
obvious guess.)

**The flea renewal fee — one unannotated number whose unit differs by four
orders of magnitude.** `emu/market.renewOffer`. The database has exactly one
number about it:

```
grep -o '"renewPricePerHour":[^,}]*' build/db/db.json   # 0.5
grep -o '"maxRenewOfferTimeInHour":[^,}]*' build/db/db.json   # 48
# both at globals.config.RagFair
```

Nothing in the database or the reference dump says whether `0.5` is **roubles
per hour** or **a percentage of the asking price per hour**. On an ordinary
offer those two readings are four orders of magnitude apart, and picking one
would be inventing a price rather than reading one. Everything the database
*does* decide is enforced: the offer must be the player's, must not have
expired, and may not be extended past 48 hours at a time. **Cost:** renewals are
free on this server, which is more generous than the game. It is consistent —
this market takes no listing fee either, so a renewal fee would be the only
money it ever took from a seller.

**Weather — a mod extension point, and a deliberate refusal to import SPT's
file.** `emu/raid.weatherFrom`. Write the **whole rendered response** to the
database path `weather` and it is what the client gets; only `timestamp`, `time`
and `date` are filled in here, because those have to be *now* and cannot live in
a static table. Nothing else is averaged, clamped or second-guessed.

```nim
dbWrite("weather", """{"season": 3, "acceleration": 0,
                       "weather": {"temp": -14, "cloud": 0.8, "rain": 2,
                                   "rain_intensity": 0.4, "wind_speed": 6,
                                   "fog": 0.3}}""")
```

It is a database path rather than a route because the backend correctly refuses
a second registration of `/client/weather`, so a mod shipping arctic weather had
nowhere at all to put it. And it is **not** SPT's `configs/weather.json`, which
`aowl importdb` deliberately does not bring: that file is the *generator's
settings*, not a rendered response. Its top level is `acceleration`, then
`weather.presetWeights.SUNNY.clouds = {"-1": 5, "-0.8": 2}` — a weight table
something rolls against. Importing it would put weights where a response goes
and the client would read a weight as a temperature. **Cost:** without a mod,
every raid gets one dull sky (18°C, no cloud, no rain, `season: 1`). The
fallback is the shipped answer until something *renders* weather.

### The rest, by module

| Refusal | Consequence for the player |
|---|---|
| **`emu/ids`** — the run number cannot be read from or written to the store | **The mod refuses to load.** A server that cannot guarantee an id issued after a restart differs from one an earlier run issued will hand two objects the same id, and the client draws the stash by walking `parentId` from the root — so it stops being able to draw it at all. Refusing to start is the honest answer. |
| **`emu/store`** — a key exists and cannot be read (sharing violation, disk error) | A **read-only** path serves empty and logs it. A path about to **write** refuses. "Nothing here" and "unreadable" used to answer the same value, and the recovery for the first — start empty and write — destroys the second: a mailbox holding a quest reward becomes an empty one, silently. |
| **`emu/selfchecks`** — any load-time arithmetic check fails | The mod serves **only** `/aowlspt/tarkov/selfcheck` and every `/client/` route 404s. See section 7. |
| **`emu/health`** — a medkit or food template the database does not have | The heal is refused. An unknown medkit healing for free is an infinite medkit, and on a server with no item table that is every medkit there is. |
| **`emu/health`** — no `globals.config.Health.HealPrice`; an effect with no `RemovePrice` | Treatment at Therapist is refused, naming the effect. Free healing is not the same answer as "the price is not known". (Live values: a hit point 30, energy 0, hydration 0; `Fracture` 1000, `LightBleeding` 400, `HeavyBleeding` 1200, `BreakPart` 1000, `Intoxication` 42700.) |
| **`emu/health`** — a body part that is not one of the client's seven | Refused rather than added. An eighth part is one the client cannot draw. |
| **`emu/repair`** — a template with no `RepairCost` | Refused, not repaired free. A template with no degradation rate degrades by **nothing**: "the database does not say" must not become an invented penalty on somebody's gear. |
| **`emu/repair`** — a repair at a trader whose `currency` is not roubles and whose `repair.currency_coefficient` is absent or zero | Refused by name, saying which currency and that no rate converts it. **This row used to say converting needs an exchange rate that does not exist, and charged roubles. Both halves were wrong**: `traders.<id>.base.repair.currency_coefficient` *is* the rate — 1 for every rouble trader, `0.00847457627118644` (= 1/118) for Peacekeeper — and the handbook prices are per note, not per stack (RUB 1, USD 121, EUR 134; 1/121 agrees with the coefficient to 2.5%). The conversion is done now. Nothing on a real database reaches it: Peacekeeper is the only non-rouble repairer and his `repair.availability` is `false`, so only Prapor, Skier and Mechanic repair and all three charge roubles at a coefficient of 1. |
| **`emu/customise`** — an id the table lacks, of the wrong body part, of the other faction, or gated on an edition the profile does not have | Refused by name. This is a write the client asks for **by id**, so believing it lets anything on this port put any 24-character string in a field the client then renders. An entry with an *empty* `_props.Side` is refused too — the four in this database are mannequin dressing and cultist voices. |
| **`emu/customise`** — whether the player has *unlocked* a suit | **Not checked.** Unlocks live in `CustomisationUnlocks`, filled by `BuyCustomisation` from `trader/<id>/suits.json`, which the importer does not bring. More permissive than the game; a stated gap. |
| **`emu/decorate`** — one of the 47 `hideout.customisation.slots` | Refused by name. A slot has no `itemId` — there is nothing to write, and inventing one puts an arbitrary poster on the wall. Poster and statuette slots stay empty here. |
| **`emu/decorate`** — a condition kind the evaluator does not know | Refused, not waved through. A gate nobody can evaluate is still a gate. (The four kinds this database uses on its 38 globals: `Block` 18, `Quest` 12, `Level` 3, `HideoutArea` 1.) |
| **`emu/decorate`** — a mannequin *slot key* | **Cannot be checked and is stored as sent.** There is no table of mannequins in this database. A wrong key is a pose recorded under a slot the client never reads — visible, harmless, indistinguishable here from a correct one. |
| **`emu/decorate`** — `RecordShootingRangePoints` | The number is **entirely the client's word**. There is no shooting range in this process: no target, no bullet, no hit. What is checked is that the player has area 12 and that the number is not negative. Stored as sent rather than as a running maximum, because nothing in the database reads the counter (`grep -c ShootingRangePoints build/db/db.json` → 0) so its only consumer is the client's own board, and showing a higher number than the client just displayed would be inventing a score. |
| **`emu/questcond`** — a `Kills` condition qualified on `weaponCaliber`, the weapon-mod lists, either equipment list, or on `daytime` when the raid's own clock does not settle it | The kill is **not credited** from the raid's victim list, and the refusal now **names the clause** in the log so a player whose quest will not finish knows which one stopped it. Crediting a kill whose qualifier could not be checked hands out progress nobody earned. The client's own counter still counts, through `mergeCounters`. **`distance` is no longer among these** — the reference dump's `Victim` carries one per kill and it is now evaluated; nor is `daytime` unconditionally — the raid configuration's `hourOfDay`, `timeFlowType` and the map's `EscapeTimeLimit` give the raid's whole possible span, and a window that contains all of it credits, one that contains none of it is a verified *no*, and only a window the span crosses is refused by name (a raid this server was told nothing about is one of those); nor is the mere *presence* of a `distance`/`daytime` key, which is how a real `templates.quests` writes 191 of its 283 `Kills` sub-conditions with neutral values (`>= 0`, `0..0`) and which used to refuse all of them. A `weapon` list is credited when the report spells the weapon as a template id and refused by name when it spells it as a display name; nothing here can map one to the other, because this module reads no database. |
| **`emu/questcond`** — a condition kind the evaluator does not know | Reported as *unchecked*, not as failed and not as passed. `isChecked` says which is which. Failing strands a player forever; passing is a free reward; naming it is the only honest third option. |
| **`emu/quests`** — a quest whose template the loaded database does not have | The one place the rule bends: it completes with whatever rewards the template does not name, because the alternative is a player stranded on a quest the server cannot describe. Logged, not silent. |
| **`emu/achievements`** — any condition in the finish group could not be evaluated, or the finish group is **empty** | Not awarded. An empty group makes "every condition is met" trivially true, which would award the entire table on the first raid a player finished. |
| **`emu/notes`** — an index the note list does not have | Refused rather than clamped. Clamping edits the wrong note. A marker on an item the player does not own is refused: it is a write into nothing that succeeds. |
| **`emu/personal`** — a `PinOrLockItem` state that is not `Free`/`Locked`/`Pinned` | Refused rather than stored. |
| **`emu/insurance`** — an item sold, or otherwise gone from the stash without a raid | The `InsuredItems` entry is left behind at the sale and **discharged with no message** at the end of the next raid. An entry whose item the pre-raid profile does not hold cannot be posted back by anybody, and asking the same unanswerable question every raid is worse. |
| **`emu/dialogue`** — a trader with no list for a situation, a locale id that resolves to nothing, or a line whose placeholders cannot all be filled | Falls back to the plain sentence. An empty message and one reading "lost somewhere on {location}" are both worse. (Real data: Prapor 7 lists, Therapist 7, Fence 1, the BTR driver 1 — `traders.<id>.dialogue`.) |
| **`emu/trading`, `emu/production`, `emu/hideout`** — any part of a payment or a requirement is short | **Nothing is taken.** The whole requirement is resolved to (stack, amount) pairs and every one verified before a single item moves. There is no transaction to roll back, so the check has to come first. `resolveRequirements` is shared between a craft and a hideout stage; neither has a laxer copy. |
| **`emu/bots`** — no `bots.types.<role>` data | A raid still starts, populated by bots wearing nothing. A strange raid and a working one, and far better than a client that cannot enter one. |
| **`emu/templates`, `emu/traders`** — no database at all | Every table answers with a valid **empty** table. The client renders an empty flea market and reaches the menu. A server that only works against a full live dump cannot be started for the first time. |
| **`emu/grid`** — no stash template | Falls back to 10×68, the standard-edition stash. A server with no item table still has to be able to hand somebody a gun. |
| **`emu/mail`** — `remove` on a dialog holding uncollected items | The row goes off the inbox and every message of that sender that holds **nothing** is deleted outright; a message that still holds items is kept, off the inbox and still on the collect-all screen, and a warning says how many. The mailbox is the only place an uncollected insurance return or quest reward exists and there is no undo anywhere in this server, so a mis-click may not destroy them. A new message from the same sender is believed to put the dialog back, which is the client's own behaviour and is one of the things a raid would settle — nothing here has run against BSG's client. (`read`, `pin`, `unpin` and `remove` were all four stock `null` stubs until now, and `dialogList` answered `"pinned": false` and `"new": 0` whatever the mailbox held.) |
| **`emu/market`** — every source is missing | Degrades to an empty market rather than to an error. |
| **`emu/numbers`** — a gain smaller than 5×10⁻⁷ | Rounds to nothing. Every rate in this server is a hundredth or larger, four orders of magnitude clear, and a rate that small is one no player could observe. Named rather than hidden. |

---

## 4. What is *not* refused, and is trusted

Stated here because each looks like an oversight and is a decision.

* **The raid result.** `/client/match/local/end` carries the profile the client
  played with, and this server saves that document. Health, inventory,
  everything picked up. There is no other source — the raid happens entirely on
  the player's machine.
* **Durability, in the direction of wear.** Nothing here reduces it and there is
  no route that would: the reference has no per-shot, per-hit or per-raid wear
  callback, and no wear action in `ItemEventActions`. A rifle that finished a
  raid at 71/100 arrives with 71 already written. The obvious design — apply a
  percentage at raid end — would apply it *on top of* what the client already
  applied, and the two are indistinguishable in the document that arrives. **A
  client that hands back durability put *up* is not caught.** Closing that means
  diffing every item's `upd` against the pre-raid profile.
* **Skill gains, as a *delta* and not as a number.** The difference between the
  skills that went in and the ones that came out is the raid's claim about how
  much work was done, which is fair. It is then run through the game's own
  progression curve — fresh-point bonus, fatigue integrated point by point, a
  hard per-raid cap — which the server *does* own. A client claiming a thousand
  points of Endurance gets the same answer as one claiming a hundred.
* **The gym's booleans.** See section 3.
* **The shooting range's score.** See section 3.

---

## 5. Gaps

Operation-by-operation, `docs/EMULATOR-COVERAGE.md`. What follows is the set
that is *this mod's* rather than an absent route, and each row names the
consequence rather than the missing feature.

| Gap | What it costs | What would close it |
|---|---|---|
| Renewals on the flea are free | more generous than the game | one fact: the unit of `renewPricePerHour`. Not derivable from the database or the dump. |
| Two gym effects are never applied | the workout is slightly cheap; a warning says so | a definition of `MusclePain` and `GymArmTrauma`, which this database does not contain |
| Weather is one constant sky unless a mod writes `weather` | every raid looks the same | something that *renders* weather from `configs/weather.json`'s weights — a generator, not an importer row |
| Clothing and mannequin-pose unlocks are not enforced | every entry the table has is wearable | `trader/<id>/suits.json`, which `aowl importdb` does not bring |
| Trader **standing** moves on quest rewards, and Fence's also on a finished scav raid — by the game's own `standingForKill` for every victim in it, plus one configured figure for walking out | buying and selling do not build reputation | the reference gives the three requirements a loyalty level has and says nothing about what a purchase is worth in standing. A rate invented here is a number nobody can check. **The scav side of this row is no longer invented.** `bots.types.<role>.experience.standingForKill` is in the database for all 57 roles at BSG's own numbers (`assault` −0.04 at `normal`, `bear` +0.02, twelve roles at −0.05, ten at −0.2) and is now read back off the raid's `Stats.Eft.Victims`, scaled for PMC victims by `globals.config.FenceSettings.PmcBotKillStandingMultiplier`. A role the database does not price at `normal` earns nothing and is named in the log rather than priced off another difficulty column. What is still invented is `fenceKarmaOnScavExtract` (0.01) alone — no figure for *surviving* a scav run exists in the database or the dump — and it can be set to zero in `config.json` to leave the game's numbers running on their own. |
| Poster and statuette slots stay empty | 47 of the hideout's 85 decoration entries do nothing | an `itemId` on a slot entry, which the table does not carry |
| `SellAllFromSavage` is refused | one lost convenience | a scav stash separate from the PMC's — a design change, not a fix. `docs/BACKLOG.md` Group F. |
| `/client/locations` cannot list a map added after the first request | none in practice — mods patch maps at load, before any request | a key-enumeration call in the plugin ABI. `abi/aowlspt_abi.h` has `db_get` for a dotted path and no sibling that lists an object's members, so the map names can only come from reading `locations` whole — which is the 560 MiB read this route exists to stop doing. It is therefore done once and cached. |
| A profile edited outside the server is believed | — | nothing; this is single-player |

---

## 6. What a raid would be the first to disprove

Ordered by how cheaply one real session would settle it.

1. **All 94 route paths at once.** None of them came from the dump — the dump
   has no route strings — so every one is a well-known client path and every one
   is a hypothesis. A wrong path is a 404 the client does without, and a path
   the client asks for that nothing here serves is also a 404. **Both are
   visible in one session with the backend log open**, which makes this the
   highest-value hour in the whole document: it confirms 94 guesses and
   enumerates the real unserved surface in the same pass, rather than against a
   hand-joined coverage table.
2. **The wire spellings of the item-event actions.** The dump carries
   `ItemEventActions`' member *names* and not their values, so every arm in
   `emu/*` matches on the name and that is a hypothesis. A wrong one is an
   action that falls through to "unknown action" with the item sliding back.
   The same doubt covers `HideoutEventActions`, `PinLockState`, and the `type`
   strings `emu/customise` dispatches on.
3. **Whether the client renders `warnings[].errmsg` at all.** Every refusal in
   section 3 reaches the player through that array inside an `err:0` envelope.
   If the client swallows it, every one of those carefully worded sentences is
   an item that silently does not move — which is the failure mode this server
   was written to avoid, arrived at by another route.
4. **`heal_price_coef`'s direction.** Therapist's rises with loyalty
   (100 → 135) where a discount would fall. Read directly it agrees with
   `repair_price_coef`, whose direction *is* established by Fence's 300; read
   inverted, one member would mean the opposite of its neighbour. At loyalty
   level 1 both readings give 100 and agree exactly, which is where most
   treatment happens — so the disagreement only shows at level 3 or 4.
5. **Whether the gym pays both skills or one.** `singleSuccessEffect.
   rewardsRange` has two entries, `Endurance` and `Strength`, each
   `weight: 1`. A `weight` elsewhere in this database means a weighted *pick*
   (a scav case reward is chosen that way). Both are paid here, because the gym
   trains both and the entries differ in nothing but `skillId`. One raid's worth
   of workouts settles it.
6. **`ShootingRangePoints`.** The counter key is the well-known client one and
   the dump carries the request DTO, not the key. If it is wrong the board
   reads zero forever and nothing else breaks.
7. **The bot batch's shape and its cost.** `/client/game/bot/generate` builds
   the largest single body this server produces, at the worst possible moment —
   the player is watching a loading screen. It is written for that (tables read
   once per batch, the item table touched twice per weapon rather than walked)
   and no measurement of it against a real client exists.
8. **Whether a generated bot is *wearing* what the database says.** Three
   details in the loadout reader were guessed wrong on the first attempt and are
   worth knowing if a faction's gear ever stops arriving: the chance tables are
   **three** (`chances.equipment`, `chances.weaponMods`,
   `chances.equipmentMods`) and not one `chances.mods`; a mod slot name appears
   in **either casing** in stock data, so an exact-key lookup silently misses;
   and a weight of zero means *never*, so a pool summing to zero must produce
   nothing rather than element zero — which is how every scav on a map ends up
   in the same hat.
9. **Which members of `RaidSettings` the client actually posts, and how
   `Victim.Weapon` is spelled.** `Victim.Time` is no longer among these, and
   the reason it is not is the correction worth recording: it was never the
   right input. `daytime` is now decided from the **raid configuration** —
   `TimeAndWeatherSettings.HourOfDay` for the start hour, `TimeFlowType` for
   how fast the clock runs, and the map's own `EscapeTimeLimit` for how long it
   can run — and a kill is credited only when that whole span lies inside the
   window, refused when it crosses the edge, and treated as a verified *no*
   when it lies entirely outside. `WeatherHelper.IsNightTime(timeVariant,
   mapLocation)` in the dump is the proof of method: the game decides night
   from what was selected and which map, never from a victim's clock. What one
   raid would settle is which of `hourOfDay`, `isNightRaid` and `timeVariant`
   the live client sends — only the first can establish an hour, and a request
   carrying only the other two is refused rather than turned into one by a rule
   invented here. `Weapon` is typed `String` while a quest's `weapon` list is
   template ids: `killCredit` credits it when the report puts a 24-character id
   there and refuses by name when it does not, so **one raid with one
   weapon-qualified quest accepted settles that one either way**. Both refusals
   cost only the fallback path — the client reports its own counter for these
   and `mergeCounters` takes it first.
10. **Whether a loaded magazine should be full.** `emu/loot.fillMagazine` fills
   to the magazine's `_max_count`, because that is the only round count
   anything in the database states: neither `globals.config` nor the reference
   dump carries a fill fraction, and any other number would be invented here.
   The real game spawns partly-loaded magazines, so this is generous in the
   player's favour by a bounded amount and one raid says by how much.

---

## 7. The self-check gate

```
GET /aowlspt/tarkov/selfcheck   ->  {"ok":true,"failures":[]}
```

Deliberately outside `/client/`, deliberately **not** in the client's
`{err, errmsg, data}` envelope, and never sent to the client. It exists so that
a tool, a gate or a person can tell *"this mod refused to load, and here is
which check failed"* apart from *"nothing is listening"* — which are the same
404 otherwise.

**It is registered before the gate decides whether there will be any other
routes**, so it answers on both paths: `{"ok":true,"failures":[]}` when the
arithmetic held, and `{"ok":false,"failures":[...]}` naming every check that did
not when the mod refused to serve. On a failure it is the only route this mod
registered and every `/client/` path 404s.

### What runs at load

`emu/selfchecks.selfCheckFailures` collects from thirteen modules, all before
the first request:

```
loot  market  questcond  skills  health  production  gym
customise  decorate  dialogue  insurance  raid  bots
```

Four of those (`loot`, `market`, `questcond`, `skills`) existed already and
**nothing called any of them** — checks that read like coverage in a review and
were none, which is worse than no check because they were counted as one.

Each is over code with no database, no host and no profile in it: the flea's
filter and sort, the loot generator over a fixture it carries, the quest
condition evaluator over literals, the skill curve, the treatment price, the
scav case roll, the whole of the gym's arithmetic against a literal QTE entry,
the customisation validator, the hideout-decoration planner, the calendar behind
`{date}`/`{time}`, a closed loop of insurance over a sequence of raids, the
`/client/locations` map-list builder, and the bot loadout reader.

That is exactly the code the wire suites cannot reach precisely, because
everything they see has been through a route, a JSON encoder and the wire.
`emutest` can tell that a search came back sorted; only `market.selfCheck` can
tell that a category tree with a cycle in it terminates.

Three of the thirteen are worth calling out as the *shape* of check that catches
the worst bugs — the ones where the test and the defect agreed:

* **`raid.selfCheckRaid`** asserts on what a route does **not** send.
  `/client/locations` used to splice the whole `locations` subtree in verbatim:
  correct, and 560 MiB on a database imported with loose loot, to draw a list of
  19 maps. No request the client makes says "and nothing else came back", so
  nothing on the wire could see it. The check runs the map-list builder over a
  fixture that deliberately carries `looseLoot` and asserts it is absent.
* **`bots.selfCheckBots`** exists because the *fixture* was wrong. Three defects
  in `emu/bots` — appearance weight maps read as lists, health variants read as
  an object, `bots.base` imported and never opened — were invisible on the wire
  because `tests/fixtures/emu-full.json` was written in the shape the code
  expected rather than the shape the game ships. The fixture agreed with the
  bug. A check carrying its own tables in the real shape is the only kind that
  could have caught them.
* **`customise.selfCheckCustomisation`** runs the ids a new profile is created
  with through the same validator a `CustomizationSet` goes through. Seven of
  the eight defaults were wrong, four naming the wrong body part outright — and
  nothing failed, because the client resolves them against its own bundles, so
  the symptom reads as a mod problem.

### The rule about what belongs here

**A fatal load-time gate belongs over this mod's own arithmetic and never over
somebody's data.**

A defect in the flea's sort or the skill curve is a defect in pure arithmetic
that no input can work around, and refusing to serve is the honest answer to it
— a curve that pays the wrong number is not something to run a season on and
find out about later.

A defect in *data* is not that. The emulator is pointed at whatever database the
user has: dumps of different vintages spell conditions differently, carry
`staticLoot` in different places, and have entries nothing points at and
pointers to entries that are not there. **A server is not allowed to fall over
on any of that**, which is why every table in `emu/templates` has an empty
fallback and why the gate refuses to grow database assertions.

**`tools/realtest.nim` is where database-shaped assertions live.** It runs
against whatever `aowl importdb` produced, asserts nothing about identity —
every id it uses is discovered at runtime from the server's own answers — and
skips rather than fails when there is no imported database, because a red gate
meaning "you did not run a tool that reads a game you may not own" is a gate
people learn to ignore.

The two exceptions in `emu/selfchecks` prove the rule by how narrowly they are
drawn: `selfCheckCustomisation` and `selfCheckDecorate` each have a
data-conditional half that runs **only** when the loaded database carries the
table, is skipped entirely otherwise, and checks an *invariant between two
tables this mod joins* rather than the contents of either.

### Cost

A few milliseconds of the first load. The loot generator over its own small
fixture is the expensive one — three passes over a document of a dozen items.

### The other four suites

`emutest` (against `tests/fixtures/emu-full.json`), `realtest` (against an
imported database), `soak` and `fuzzwire`, all run by `aowl test`. Their check
counts move every pass and are recorded, with the command that produced them, in
`docs/EMULATOR-COVERAGE.md` — **not here**, because a count copied into a second
document is a count that goes stale in one of them.

---

## 8. Layout

```
tarkov.nim         the routes, the envelope, the item-event batch, the load gate
emu/
  ids             MongoIds; the run number, persisted before any id is issued
  numbers         the one place this server prints a float
  rand            xorshift64*, seeded per raid; the only variation in the server
  store           "nothing here" vs "unreadable", and why they must not be one
  sessions        PHPSESSID -> profile, persisted
  profile         the profile document, held as JSON text and merged
  templates       the static tables, each with an empty fallback
  grid            first-fit placement into a stash grid
  selfchecks      the load-time gate; thirteen modules' pure arithmetic

  traders         base and assort
  trading         buying and selling; money is stacks, not a balance
  market          the flea: the built offer list, the search, the player's own
  inventory       the item-moving diff — created, changed, deleted
  personal        insurance, wishlist, favourites, pins, hotkeys
  redeem          taking an item out of a message (a Move with fromOwner)
  mail            dialogs and messages; bounded, and the only home for rewards
  dialogue        what a trader actually says, out of traders.<id>.dialogue
  notify          notifyPush (ABI revision 5), falling back to the poll
  notes           notes and map markers

  quests          state, payout, and the guards on both transitions
  questcond       the condition evaluator: pure over JSON text
  repeatable      the dailies, the weekly, the scav's; derived, not stored
  achievements    the quest machinery over a different table

  hideout         areas and the levels built; upgrades are two steps
  production      crafts; time derived from a timestamp, never counted
  decorate        the hideout's wardrobe and the shooting range's score
  gym             the QTE minigame, and what a server may believe about it
  customise       heads, suites, dog tags, voices
  builds          weapon, equipment and magazine presets — three lists, always

  raid            the map list, the raid config, the sky, and the exit
  loot            what is on the floor: static containers, static loot, loose
  bots            /client/game/bot/generate — a bot is a profile with a Role
  scav            the second character; the PMC's stash, spliced not copied
  insurance       the premium now, the return a day later, across a restart
  health          Heal, Eat, and RestoreHealth at a trader
  repair          Repair and TraderRepair; the client owns the wear
  skills          the raid's delta, run through the game's own curve
```

Settings are `mods/tarkov/config.json`; every key is documented in the module
that reads it.

Related documents: `docs/EMULATOR.md` (what it does),
`docs/EMULATOR-COVERAGE.md` (what it does not — authoritative),
`docs/IMPORTDB.md` (where the database comes from), `docs/BACKLOG.md`.


---

## ORBIT

[ORBIT](https://github.com/Chazut/ORBIT) is an SPT bot-AI mod: bots pursue
objectives -- loot zones, PvP hotspots, quest markers -- instead of patrolling.
Its logic is reimplemented here, split across two mods. This file is the
HIGH-LEVEL half.

### Licence

**ORBIT is MIT** (`LICENSE` at its repository root; the README credits Phobos's
advection-field architecture, also MIT, with explicit permission). MIT is
compatible with this repository and copying with attribution would have been
allowed.

**Nothing was copied.** ORBIT is C# built on BepInEx, BigBrain and Waypoints;
none of those exist on post-1.0 IL2CPP Tarkov and none of that code would
compile or run here. The LOGIC was reimplemented in nimony from the README and
the repository's own description of its subsystems. Attribution is in this file
and in `emu/orbit.nim`'s header.

### The split

ORBIT's README says it "operates entirely client-side ... there is no server
component". We cannot have that half: there is no BepInEx, and every by-NAME
IL2CPP route is fatal the moment it is USED (facts #143/#144/#145). So each
concept is routed to whichever side of aowlspt can actually express it.

| ORBIT concept | lands in | expressible here? |
|---|---|---|
| cell grid over the map | `mods/tarkov/emu/orbit.nim` | YES -- rebuilt from `db.json` instead of from a scene scan |
| PvP hotspots | `mods/tarkov/emu/orbit.nim` | YES -- `SpawnPointParams` with `Categories` containing `Player` |
| roam anchors | `mods/tarkov/emu/orbit.nim` | YES -- `Categories` containing `Bot`. Not an ORBIT concept; it replaces the loot layer below |
| loot zones / density | `mods/tarkov/emu/orbit.nim` | **NO.** Every `staticContainers[*].template.Position` in this `db.json` is `(0,0,0)`. Measured; see the header. The reader is written and produces nothing |
| personality distribution | `mods/tarkov/emu/orbit.nim` (policy) -> `mods/sain/server/dispatch.nim` (draw) | YES |
| coverage roll (skip a POI) | policy here, rolled per bot in `dispatch.nim` | YES |
| loot value gates (rub/slot) | policy here | PARTIAL -- carried, but with no loot layer and no inventory verb they gate nothing today |
| primary anchor + splinter targets | `dispatch.nim` | YES |
| squad leash / cohesion | `dispatch.nim` | YES -- over census positions, not a real squad id |
| extract policy (when) | `emu/orbit.nim` | YES |
| extract destination (where) | -- | **NO.** `base.exits[*]` carries `Name`, `EntryPoints`, `ExfiltrationTime` and no position |
| quest-marker objectives | -- | **NO.** Quest conditions name zones, not coordinates |
| looting, gear swap, search animations | -- | **NO.** `aowlspt/botnav` has `GoToPoint`, `SetTargetMoveSpeed`, `stop`. There is no inventory verb |
| door breach | -- | **NO.** No door interaction verb |
| bot waves / population | already `emu/raid.nim` | pre-existing; ORBIT does not touch waves |

### Routes and checks

* `GET /aowlspt/tarkov/orbit/plan` -- the plan for the running raid, plus
  `orbitCheck()`'s PASS/FAIL/INCONCLUSIVE verdict. (Registered under
  `/aowlspt/tarkov/`: a route at `/aowlspt/orbit/plan` 404s on a running
  backend while `/aowlspt/tarkov/launcher/ping` beside it answers, so that
  namespace does not reach a mod on this host.)
* `selfCheckOrbit` runs at load and REFUSES the load on failure, like every
  other check in `emu/selfchecks.nim`.

Measured offline, backend on a scratch root against the live 41 MB `db.json`:

```
bigmap        PASS  18 anchors, spread 899m x 354m
woods         PASS  18 anchors, spread 1075m x 1211m
laboratory    PASS  14 anchors, spread 164m x 227m
tarkovstreets PASS  18 anchors, spread 452m x 486m
```

Every one of those verdicts also carries `NO LOOT LAYER`, and that is the point
of the check: the FIRST version of it passed with six anchors and no loot layer
at all, because it did not count loot anchors separately. A plausible plan with
a whole subsystem missing is exactly the failure CLAUDE.md 9b is about.
