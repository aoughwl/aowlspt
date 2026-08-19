# Importing a real database

The emulator answers the client out of `<root>\db.json`. Every database it had
been tested against was a hand-written fixture of a few dozen entries, which is
enough for a test and not enough for a person: a real client wants tens of
thousands of item templates, the handbook, twelve traders and their assorts,
558 quests, the hideout, nineteen locations and their loot, globals, settings
and the locales.

`aowl importdb` builds that from an SPT installation you already have.

Two names, one program. In the repository it is a subcommand,
`installer\build\aowl.exe importdb`; a release archive has no `aowl.exe`, so
the same importer ships beside the installer as `install\aowl-importdb.exe`
and takes exactly the flags below. Everything on this page applies to both.

```
installer\build\aowl.exe importdb --from D:\SPT
```

One second later there is a 39.4 MiB `build\db\db.json`, and a backend started
against it serves the real game's tables.

**What comes out is BSG's data by way of SPT's.** It is not committed to this
repository, it is not in a release, and `build/db/` is in `.gitignore`. The
tooling exists so that each person produces it locally, from their own install,
on demand. Nothing else about it is a distribution decision that anybody gets
to make.

**The importer never writes into the SPT install.** It is opened read-only, and
every path the program writes to is put through one refusal, `refusesWrite`,
before anything is opened:

```
error refusing to write inside the source install
        --out D:\SPT\out\db.json
        is under D:\SPT
        This importer reads an SPT installation and never writes to one: the
        source is somebody's game, and an import is a command that gets re-run.
        Point --out outside it.
```

**"Every path" is new, and it is why this paragraph is worth reading twice.**
Until 2026-08-19 the refusal was three lines at the `--out` site, and this page
and the tool's own header both stated the guarantee in general terms. The
program writes to *two* paths. `--report` was not checked:

```
aowl-importdb --from D:\SPT --report D:\SPT\report.md --survey
  ...
  ok    289 files, 671.48 MiB total, of which 548.10 MiB is loose loot
  ok    report -> D:\SPT\report.md          <- 18,711 bytes, in the game install
```

That is the shape this repository keeps finding: **a check that passes because
the thing it checks is not the thing that happens.** The refusal was real, it
was tested, and it guarded one of the two ways out. The same command now exits
1 and creates nothing, and `--report` is validated before the survey walks a
single directory -- `--survey` returns before the `--out` check is ever
reached, so a refusal placed with `--out` would still not have covered it.

## The survey

`aowl importdb --from D:\SPT --survey` walks the source and prints every file,
its size and its top-level shape, writing the same as markdown with `--report`.
Run it against your own install rather than trusting the table below; this is
what one SPT 4.x install (`D:\SPT`, surveyed 2026-08-19; `globals.json`
dated 2026-08-06, `templates/items.json` 2026-08-16) holds.

**289 files, 671 MiB, of which 548 MiB is loose loot.**

| group | files | on disk | minified | what it becomes |
|---|---:|---:|---:|---|
| `templates/items.json` | 1 | 19.6 MB | 12.2 MB | `templates.items` — 4,673 templates |
| `templates/handbook.json` | 1 | 0.5 MB | 0.4 MB | `templates.handbook` — 4,288 priced entries |
| `templates/quests.json` | 1 | 5.8 MB | 3.5 MB | `templates.quests` — 558 quests |
| `templates/customization.json` | 1 | 0.5 MB | 0.4 MB | `templates.customization` — 728 suites |
| `templates/achievements.json` | 1 | 0.2 MB | 0.1 MB | `templates.achievements` — 53 |
| `templates/prestige.json` | 1 | 0.08 MB | 0.03 MB | `templates.prestige` — **unwrapped**, see below |
| `templates/repeatableQuests.json` | 1 | 0.02 MB | 0.01 MB | `templates.repeatableQuests` — 4 quest types |
| `../configs/quest.json` | 1 | 0.09 MB | — | `configs.quest.repeatableQuests` — 3 sets; **not from `database/`**, see below |
| `globals.json` | 1 | 1.1 MB | 0.7 MB | `globals` |
| `settings.json` | 1 | 0.8 MB | 0.3 MB | `settings` |
| `hideout/*.json` | 6 | 0.5 MB | 0.3 MB | `hideout.areas` (**merged**, see below), `.production`, `.settings`, `.qte`, `.customisation` |
| `locales/` (en) | 3 | 3.0 MB | 2.8 MB | `locales.global.en`, `locales.menu.en` (**unwrapped**), `locales.languages` |
| `traders/*/` | 39 of 44 | 2.11 MB | 1.4 MB | `traders.<id>.base` / `.assort` / `.questassort` / `.dialogue` — 12 traders, 5,790 assort items. Only 4 traders ship a `dialogue.json`; it is the insurance-message locale ids `emu/dialogue` reads, not chat lines |
| `bots/` | 59 | 8.5 MB | 5.9 MB | `bots.core`, `bots.base`, `bots.types.<role>` — 57 roles |
| `locations/*/base.json` | 19 | 6.7 MB | 1.4 MB | `locations.<name>.base` |
| `locations/*/staticLoot.json` | 13 | 12.1 MB | 7.7 MB | `locations.<name>.staticLoot` |
| `locations/*/staticContainers.json` | 13 | 5.9 MB | 3.3 MB | `locations.<name>.staticContainers` |
| `locations/*/staticAmmo.json` | 13 | 0.2 MB | 0.2 MB | `locations.<name>.staticAmmo` |
| **`locations/*/looseLoot.json`** | 13 | **575 MB** | **575 MB** | `locations.<name>.looseLoot` — **opt-in**, see below |
| everything else | 114 | 61.67 MB | — | **not imported** — itemised below, so that it is a list and not an etcetera |

Everything except loose loot, minified, is **41 MB**. Loose loot is already
minified where it sits, so there is no squeezing it: `bigmap/looseLoot.json` is
42 MB before and after.

### The last row, itemised

An earlier version of that row read *"`templates/dialogue.json`, `prices.json`,
`profiles.json`, `character.json`, `locationServices.json`,
`defaultEquipmentPresets.json`, `match/`, `locales/{server,web,menu-other}` --
~9 MB -- not imported, the emulator has no route that reads them."* Eight file
groups the install also holds were in the etcetera at the end of it, and a row
that ends in an etcetera is a row nobody can re-check. Every file the survey
finds and the importer leaves behind:

| file | files | on disk | is there a route that reads it |
|---|---:|---:|---|
| `locations/*/looseLoot.json` | 13 | 574.72 MB | **yes** — `emu/loot` reads `locations.<map>.looseLoot`. Opt-in per map, `--loose`; see *Size, measured* |
| `locales/global/*` other than `en` | 16 | 50.39 MB | **yes** — `emu/templates` reads `locales.global.<lang>`. Opt-in, `--locales` |
| `templates/dialogue.json` | 1 | 6.26 MB | no. SPT's chat-command templates, `{elements:[...]}`. The trader lines the emulator *does* use are `traders/<id>/dialogue.json`, which is imported |
| `templates/profiles.json` | 1 | 1.95 MB | no. `emu/profile` builds a profile from its own defaults |
| `locales/server/*` | 27 | 1.78 MB | no |
| `locations/*/statics.json` | 13 | 0.69 MB | no. New in this SPT build; `emu/loot` reads `staticLoot` and `staticContainers`, which are separate files |
| `traders/5ac3…e83c/{suits,bearsuits,usecsuits}.json` | 3 | 0.16 MB | no — and `emu/customise` names this as the reason every wardrobe entry is wearable on this server |
| `templates/prices.json` | 1 | 0.10 MB | no. The flea is priced off the handbook, deliberately; a second price source would be a second answer |
| `templates/defaultEquipmentPresets.json` | 1 | 0.09 MB | no |
| `locations/*/allExtracts.json` | 13 | 0.08 MB | no |
| `templates/archivedQuests.json` | 1 | 0.06 MB | no |
| `templates/customAchievements.json` | 1 | 0.04 MB | no. `emu/achievements` reads `templates.achievements` only |
| `locales/menu/*` other than `en` | 15 | 0.03 MB | **yes**, with `--locales` |
| `templates/character.json` | 1 | 0.014 MB | no |
| `locales/web/en.json` | 1 | 0.014 MB | no |
| `templates/locationServices.json` | 1 | 0.006 MB | no |
| `templates/customisationStorage.json` | 1 | 0.004 MB | no. `emu/decorate` reads `hideout.customisation`, which is imported |
| `traders/*/services.json` | 2 | 0.001 MB | no |
| `match/metrics.json` | 1 | 0.0008 MB | no |
| `server.json` | 1 | 0.00004 MB | no |

**11.3 MB** of that is not behind a flag at all; the other 50.4 MB is the
sixteen languages `--locales` does not ask for. Derive the same partition from
your own install with

```
installer\build\aowl.exe importdb --from D:\SPT --survey --report C:\tmp\survey.md
```

and compare it against the `Tables the emulator reads` section of an import
report, which lists what the produced database actually contains.

## What converts cleanly, and what does not

Almost all of it is a **splice**, not a translation — SPT's on-disk layout and
the paths `mods/tarkov` reads with `dbRead` line up nearly key for key. Four
places do not, and in every one of them the *importer* bends rather than the
emulator, because the emulator's shapes are pinned by 150+ tests and by other
people's work in that directory:

1. **`templates/prestige.json` is `{elements:[...]}`.** `onPrestigeList` wraps
   whatever it finds in `{elements: ...}` itself, so what goes into the
   database is the array. Importing the object gives the prestige screen an
   object where it enumerates a list.
2. **`locales/menu/en.json` is `{menu:{...}}`.** `/client/menu/locale/<lang>`
   returns `locales.menu.<lang>` verbatim, so the wrapper comes off here or
   every menu string is one level too deep.
3. **`hideout/customAreas.json` is a second area file.** SPT's server merges it
   into `areas` at load; the emulator reads `hideout.areas` and nothing else,
   so the importer merges the two arrays. Without it the Cultist Circle (area
   type 21) is an area seventeen recipes produce into and the hideout has never
   heard of — which is exactly what the self-check reported before this was
   added.
4. **The repeatable-quest config is not in `database/` at all.** It is
   `SPT_Data/configs/quest.json`, a sibling of the database directory, and it
   is the only thing this importer reads from outside `database/`. The reason
   it has to be read is that repeatable quests are split across the two:
   `templates/repeatableQuests.json` has the quest *skeletons* (the conditions,
   and `changeCost` — what a reroll costs) and the Completion target pool
   banded by player level, and `configs/quest.json` has everything that decides
   how many quests there are and what they pay — the `Daily` / `Weekly` /
   `Daily_Savage` sets, `resetTime`, `numQuests`, `minPlayerLevel`,
   `rewardScaling` and the per-trader `traderWhitelist`. A generator built on
   only the first half would have to invent the reward budget, which is exactly
   the kind of number nobody can check afterwards.

   Only the `repeatableQuests` member of that file is taken. The rest of it —
   `eventQuests`, `locationIdMap`, the profile black and white lists — is SPT's
   own machinery with no route here that reads it, and the rule this importer
   follows is that a table nothing reads does not get imported. It lands at
   `configs.quest.repeatableQuests`, which is the path it came from, so the two
   halves stay recognisable as one file's contents rather than becoming a
   private name.

   A missing `configs/quest.json` is a **warning, not a failure**. The import
   still produces a database; `activityPeriods` answers an empty list, exactly
   as it did before either section existed.
5. **Locations are keyed by directory name**, not by `base._Id`. That is what
   the client sends as `locationId` to `/client/location/getLocalloot` and what
   `emu/raid.locationBase` looks up. `_Id` is carried inside the value, so
   nothing is lost; if the client turns out to want the map list keyed by `_Id`
   as well, that is an emulator-side decision and not a reason to duplicate
   6.7 MB of map descriptions.

**`staticAmmo` is read now, and this note used to point at the wrong consumer.**
It said the table was imported and unused because "`expandAmmoBox` picks a
cartridge from the box template's own filter instead". `expandAmmoBox` is not
where it belongs and never was: **every one of the 213 ammo-box templates in
`build/db/db.json` has exactly one cartridge in its `StackSlots` filter**, so
the box's own filter is not a choice and a weighted pick over it would change
nothing.

```
# filter sizes over templates.items in build/db/db.json
ammo boxes  (StackSlots[]._props.filters[0].Filter):  1 -> 213   (all of them)
magazines   (Cartridges[]._props.filters[0].Filter):  1 -> 3, 4 -> 9, 5 -> 13,
                                                      8 -> 29, 9 -> 51, 13 -> 33, …
```

Magazines are the choice, and `emu/loot` had carried "magazines are not filled;
doing it properly means resolving the weapon's caliber to `loot.staticAmmo`" as
a stated gap since it was written. That is what reads it: `emu/loot.fillMagazine`
loads every magazine a weapon preset puts on the floor with a cartridge drawn
from `locations.<map>.staticAmmo`, weighted by the map's own
`relativeProbability`, intersected with the magazine's `Cartridges` filter and
restricted to the weapon's `_props.ammoCaliber` bucket. Over `globals.ItemPresets`
against `bigmap`'s table, **263 of the 264 presets with a magazine resolve to a
cartridge**; the one that does not is a `Caliber9x18PMM` weapon that map's table
has no bucket for, and its magazine is left empty rather than filled with a
guess. `realtest` asserts the loaded magazines over real maps.

Nothing in the imported set is now named as not expressible. The row that used
to be — `staticAmmo` — is the one above, and the reason it sat unread for so
long is worth keeping: the note said which function would consume it, that
function was the wrong one, and nobody checked the filter sizes that would have
said so in one line.

## Tables the emulator reads

"A table nothing reads does not get imported" is the rule this importer
follows, and the difficulty with it is that the *emulator* decides what nothing
reads, on its own schedule, in another directory. Five tables grew a route in
`mods/tarkov` inside one day — `hideout.customisation`, `hideout.qte`,
`templates.customization`, `globals.config.Health`, `globals.config.RagFair` —
and `docs/BACKLOG.md` was still carrying "the emulator has no route that reads
them" for tables in that neighbourhood, because the sentence was being
re-derived from the previous copy of itself rather than from the data. Its own
`RestoreHealth` row records the same mistake going the other way: filed as
blocked on an importer change, for a table (`globals.config.Health`) that had
been in the database all along.

A table that is read and not imported **does not error anywhere.** `dbRead`
answers "not there", every reader in `mods/tarkov` treats that as "this
database does not have it" and falls back, and the client gets an empty screen
with `err: 0` on the wire. The fixture suites stay green because the fixture
has the table; only somebody looking at a real import would see it.

So the self-check now asserts it. `checkReadPaths` in `tools/importdb.nim`
carries the inventory of the 29 database paths `mods/tarkov` reads with a
literal spelling, and resolves each of them against the document about to be
written:

```
ok    database paths mods/tarkov reads: 29 present, 0 absent
      weather        read by emu/raid and deliberately not imported: ...
```

Each entry names the module that reads it, so an absence reads as
`hideout.qte is absent, and emu/gym reads it` rather than as a path. Paths in a
section the run deselected (`--only`, `--skip`) are counted separately and are
not a finding; a path missing from a section that *was* selected is one, and
`--strict` turns it into a non-zero exit. Regenerate the inventory with the
`grep` line in the comment above the table when `mods/tarkov` grows a route.

**The check was falsified before it was trusted**, which is the only way a
check of this kind is worth anything — a self-check that has never been seen to
fail is a self-check nobody has tested. Against a source directory holding a
copy of `hideout/` with one file removed:

```
> aowl-importdb --from <copy> --only hideout,globals --strict
ok    database paths mods/tarkov reads: 11 present, 0 absent, 18 in sections this run left out
exit 0

> del <copy>\database\hideout\qte.json
> aowl-importdb --from <copy> --only hideout,globals --strict
warn  hideout.qte is absent, and emu/gym reads it
warn  database paths mods/tarkov reads: 10 present, 1 absent, 18 in sections this run left out
error 1 check(s) failed
exit 1
```

The first run also demonstrates the other half: eighteen paths were absent
because the run asked for two sections, and none of them was reported as a
problem.

It caught something on its first outing, too. **`--locales ru` alone produces a
database the emulator cannot fully serve**, and nothing said so before:

```
> aowl-importdb --from D:\SPT --only locales --locales ru --strict
warn  locales.global.en is absent, and emu/templates, emu/dialogue, emu/market reads it
warn  locales.menu.en is absent, and emu/templates reads it
exit 1
```

`emu/templates.locale`, `emu/dialogue.localeLine` and `emu/market` all fall
back to English *by name* — `dbRead("locales.global.en." & id)` — when the
requested language has no entry, so English is not one language among the
seventeen here, it is the floor. `--locales ru` on its own removes the floor.
`--locales ru,en` is the spelling that works, and the check is now the thing
that says so rather than a player wondering why the flea shows template ids.

### The one path that is read and stays unimported

`emu/raid.weather` reads `weather`, and the importer does not fill it. That is
deliberate and it is written down here so it is not filed as a missing import a
fifth time.

The emulator expects that path to hold the **response**: `{season,
acceleration, weather: {cloud, wind_speed, wind_direction, rain, fog, temp,
pressure, ...}}`, spliced out with only `timestamp`, `time` and `date` filled
in at request time. SPT's `configs/weather.json` is not that. It is the
generator's settings — `presetWeights.SUNNY.clouds` is a weight table mapping a
cloud value to how often it should be rolled, `windGustiness` is a `{min, max}`
band. Splicing it in would answer the client with weight tables where it reads
a forecast, and with none of the members it actually looks for: strictly worse
than the dull-but-complete constant `emu/raid` falls back to today. Turning
those weights into a forecast is a generator, and a generator that invents
numbers is not what a splice tool should grow.

The path exists so that a weather mod has somewhere to write — it cannot
register `/client/weather` itself, because the backend refuses a second
registration of a path — so leaving it empty is also leaving it available.

## The self-check

"It produced a file" is not "the emulator can serve it", so the importer
asserts the invariants the emulator's own code depends on, over the data it is
about to hand over. Against the install above:

```
ok    handbook entries naming a real template: 4288 checked, 0 dangling
ok    assort items naming a real template: 5790 checked, 0 dangling
ok    quest conditions naming a real template: 17320 checked, 0 dangling
ok    quest references to another quest: 781 checked, 0 dangling
ok    quest references to a trader: 583 checked, 0 dangling
ok    hideout recipe items naming a real template: 938 checked, 0 dangling
ok    hideout recipes whose area exists: 220 checked, 0 dangling
ok    repeatable quest types naming a real trader: 4 checked, 0 dangling
ok    repeatable reroll costs naming a real template: 4 checked, 0 dangling
ok    repeatable target pools naming a real template: 223 checked, 0 dangling
ok    repeatable quest sets naming a real trader: 16 checked, 0 dangling
      templates with a localised name: 4642 of 4673
```

The four repeatable rows are the same invariants as the quest rows above them:
a skeleton naming a trader that is not there is a daily nobody can hand in, a
`changeCost` naming a template that is not there is a reroll that cannot be
paid for, and a target pool naming templates that are not there is a "find 7 of
X" for an X the client cannot draw.

One thing is deliberately **not** checked, and it would report 100+ dangling
references if it were: `traderWhitelist.rewardBaseWhitelist` in the config.
Those are item **base class** ids — `543be6564bdc2df4348b4568` is the money
class, not an item — so measuring them against the template table would fill
this section with noise and teach the reader to skip it.

A dangling reference is reported with a count and an example rather than
aborting the import — real data has some, and a tool that refuses 39 MB over
three unreachable quest targets is a tool nobody runs twice. `--strict` inverts
that for a run that wants a gate. The last line is informational: 31 templates
have no `<id> Name` in the English locale and render as their id, which is ugly
and not broken.

## Size, measured

The reason loose loot is opt-in is not a guess. Measured on the development
machine with `benchbackend`, one connection kept alive, the same request mix:

| | 5 MiB generated (3,000 templates) | 39.35 MiB imported (the real thing) |
|---|---:|---:|
| backend boot to first answer | 60 ms | **637 ms** |
| `/client/items` body | 4.25 MiB | **12.49 MiB** |
| `/client/items` round trip | 14.6 ms | **93.6 ms** |
| `/client/items` server-side (ttfb) | 6.7 ms | **30.1 ms** |
| `/client/locale/en` | 3.6 ms | 16.8 ms |
| `/client/handbook/templates` | 1.1 ms | 4.9 ms |
| `/client/game/profile/list` | 0.72 ms | 0.84 ms |
| `/client/game/keepalive` | 0.17 ms | 0.24 ms |
| `db_get` mean, over the run | 206 µs | **1,511 µs** |

Read the bottom of that table before the top. **The requests that are not a
giant static table cost the same on both** — a keepalive is 0.24 ms against
39 MB and 0.17 ms against 5 MB, and a profile read is 0.84 against 0.72. What
grows is the tables themselves, roughly with their size, because the cost is
deflating and sending 12 MiB. The client fetches those once per session and
then issues thousands of small requests, so a whole-mix "requests per second"
against a real database is a number about `/client/items`, not about the
server: the same mix reports 2,954 req/s at 5 MiB and 28 req/s at 39 MiB purely
because eight of every sixteen requests in it are the biggest table in the game.

### Why loose loot is opt-in, measured rather than extrapolated

This section used to give the reason as *"it is held as one text document,
indexed by byte offset, and `dbWrite` replaces the whole thing"*, and to reach
615 MB by extrapolation. **Both halves of that need retiring.** `dbWrite` no
longer replaces the whole document — the splice happens in place against an
index held in anchor coordinates, and `db_patch` against this 41 MB database
went from 171 ms to 6.1 ms (`docs/PERF-SERVER.md`). And the sizes below are
measurements, not extrapolations.

The three databases, produced and then actually served:

```
aowl-importdb --from D:\SPT                --out <scratch>\a\db.json
aowl-importdb --from D:\SPT --loose factory4_day --out <scratch>\b\db.json
aowl-importdb --from D:\SPT --loose all --no-check --out <scratch>\c\db.json
realtest --root <stage> --db <scratch>\*\db.json --backend aowlspt-backend.exe
```

| | default | `--loose factory4_day` | `--loose all` |
|---|---:|---:|---:|
| `db.json` | 39.40 MiB | 48.26 MiB | **587.49 MiB** (616,032,908 bytes) |
| import wall clock | 0.73 s | 0.79 s | 11.76 s |
| backend boot to first answer | 517 ms | 522 ms | **2,741 ms** |
| `/client/locations` body | 12,524,609 | 21,816,893 | **587,244,352** |
| `/client/locations` round trip | 247 ms | 395 ms | **10,786 ms** |
| backend working set, at rest | 104.9 MiB | — | **653.3 MiB** |
| … after serving items, globals, locale, locations | 202.5 MiB | — | **1,362.8 MiB** |
| `realtest` | **144** checks, 1 skipped | 134 checks, 1 skipped *(not re-run)* | 134 checks, 1 skipped *(not re-run)* |

Working set with `Start-Process … -PassThru` and `$p.WorkingSet64` after a
`/client/game/keepalive` answered and again after the four bodies above; the
65/110 MiB figures this page used to give were taken before the anchor-index
work and no longer describe the backend.

**The shape stays: loose loot is opt-in per map.** The reason is now a
different one, and it is a single route. `/client/locations` answers with the
whole `locations` subtree spliced in verbatim —

```nim
proc onLocations(url, body, session: string): string =
  let v = dbRead("locations")
  ...
  put(o, "locations", if v.ok: raw(v.raw) else: emptyObject())
```

— so importing loose loot does not merely make the database larger, it makes
**one response** larger, by the whole of it. 12.5 MB becomes 560 MiB and 247 ms
becomes 10.8 s, on a request the client makes to draw the map list. Nothing
fails: `realtest` passes all 134 checks against the 587 MiB database, the
backend boots in 2.7 s and answers everything. It is simply a ten-second,
half-gigabyte answer, out of a 1.3 GB process, for a screen that lists nineteen
maps.

Two consequences worth stating in the order they matter:

1. **The per-map flag is still right**, because the cost is per map and the
   player only raids one. `--loose factory4_day` is 8.9 MiB of database and
   148 ms on that one route — a fair price for one map's real floor.
2. **If loose loot ever wants to be the default, the fix is in the emulator,
   not here**: `/client/locations` would have to answer the map *descriptions*
   without their loot, and let `/client/location/getLocalloot` — which already
   asks per map — be the only route that touches `looseLoot`. That is
   `mods/tarkov`'s call to make, and until it is made this flag is not the
   thing standing in the way of anything.

Loose loot is also the only part of the game's data the emulator can serve
without: `emu/loot` generates the floor from the static containers and static
loot when a map has no `looseLoot`, and Customs generates 227 KB of floor loot
in under a second that way.

## What emutest and soak say about it

Both were run against a stage built from the imported database. Both are
**written against `tests/fixtures/emu-full.json`, and it shows** — which is a
statement about what those tools are for, not a defect in the import:

- **`soak` refuses to start and says so**: `this database has no craft to run:
  no such recipe: recipe-quick` / `soak needs tests/fixtures/emu-full.json
  staged as db.json`. It accepts quest `q_debut`, raids map `testmap` and runs
  craft `recipe-quick` — three ids that exist only in the fixture. soak is a
  long-session *invariant* test over known data, and pointing it at real data
  is a category error. It was not modified.
- **`emutest`** completes, and a third of its checks fail against real data.
  The counts in an earlier draft of this page (94 of 227 real, 77 of 235
  fixture) were taken during a window when the emulator was red for unrelated
  reasons; it has since gone green against the fixture at 372 checks, so treat
  those two numbers as a snapshot of that afternoon rather than as a property
  of the import. **The shape of the result is what matters and has not
  changed:** the failures that are specific to real data are every one of them
  a fixture-pinned identity — `emutest` buys `item_id:
  aaaaaaaaaaaaaaaaaaaaaaa1` from Prapor, filters the flea for the fixture's
  scope, accepts the fixture's quests, and raids `testmap`. None of those exist
  in a real database, and no test was changed to make them pass.

  The right tool against real data is `tools/realtest.nim`, which discovers
  every id at run time and asserts shapes and relationships instead — see
  `docs/ARCHITECTURE.md`. It found four genuine hideout bugs the fixture could
  not, which is the argument for having both.

  Against the database this page describes, on 2026-08-19:

  ```
  realtest --root <stage> --db <scratch>\db.json
           --backend backend\bin\aowlspt-backend.exe --port 6997

  ok    the emulator answered all 144 checks against real data (1 skipped)
        39 MiB database, boot to first answer 513 ms
        4673 templates, 4288 handbook entries, 31550 locale strings
        12 traders, 5790 assort items, 431 offers priced in roubles at loyalty 1
        558 quests, 2636 conditions, 220 recipes, 28 hideout areas
        19 maps, 1700 loot items over 3 of them
  ```

  The one skip is a real scav case's reward roll: level 1 of area 14 takes
  288,000 seconds to build, so the run cannot get to it.

That is precisely why the importer carries its own self-check: the existing
gates cannot tell a good import from a bad one, and the counts above can.

What *was* verified positively, over the real wire, against the imported
database:

```
/client/game/config                                             615 bytes
/client/globals                                              693,199
/client/handbook/templates                                   377,270
/client/locale/en          "5449016a4bdc2d6f028b456f Name":"Roubles"
/client/languages                                                340
/client/locations          locations.bigmap.base, real                12,524,609
/client/hideout/areas                                         93,401
/client/hideout/production/recipes                           156,376
/client/quest/list         "QuestName":"Debut", "Background Check"   3,477,277
/client/achievement/list                                     104,998
/client/customization                                        375,423
/client/trading/api/getTraderAssort/54cb…4571   Prapor's real stock    209,447
/client/trading/api/traderSettings                           100,859
/client/settings                                             345,392
/client/items                                             12,786,497
/client/game/profile/create              → {"uid":"00000000003e000000000001"}
/client/location/getLocalloot bigmap     → 232,863 bytes of floor loot
```

One thing had to be fixed to get that far: **`aowlprobe` had a fixed 256 KiB
receive buffer**, so against a real database `/client/items` arrived truncated
and the only diagnosis it offered was `the response body would not inflate` —
from the one tool a person reaches for when they want to know what the server
said. The buffer grows now.

## The command line

```
aowl importdb --from PATH [--out PATH] [options]

  --from PATH      an SPT install (D:\SPT), or its SPT_Data\database directory.
                   The database is looked for at SPT_Runtime\SPT_Data\database,
                   SPT_Data\database, database, and the path itself, rather than
                   assumed -- SPT has moved it before.
  --out PATH       where db.json goes; a directory or a path ending in .json.
                   Default <repo>\build\db\db.json. Refused if inside --from.
  --only LIST      sections, instead of all of them: items handbook quests
                   repeatable customization achievements prestige globals
                   settings locales traders hideout locations bots
  --skip LIST      sections to leave out of the default set
  --maps LIST      which locations (default: all)
  --loose LIST     maps whose looseLoot to include: none (default), all, or
                   names. Roughly 9-42 MB per map.
  --locales LIST   languages (default: en; "all" for all seventeen, +46 MiB).
                   Whatever is asked for, include en: three modules fall back
                   to locales.global.en by name.
  --pretty         do not minify
  --no-check       skip the self-check
  --strict         exit non-zero on a dangling reference
  --survey         walk the source and print an inventory; write nothing
  --report PATH    write the survey or the import report as markdown. Refused
                   if inside --from, on the same check as --out.
```

Documented subsets, so that a smaller database is a choice somebody made and
can reproduce rather than a truncation nobody notices:

| | | |
|---|---:|---|
| `--only items,handbook,traders` | 13.94 MiB | 14,613,799 bytes |
| default (everything but loose loot) | 39.40 MiB | 41,313,127 bytes |
| `--loose factory4_day` | 48.26 MiB | 50,605,449 bytes |
| `--locales all` | 85.56 MiB | 89,714,716 bytes, +46.16 MiB over the default |
| `--loose all` | 587.49 MiB | 616,032,908 bytes |

Each row is one run of `aowl-importdb --from D:\SPT <flags> --out <scratch>`
against the install surveyed above; the byte counts are what the tool prints.

## From an SPT install to a server with real data

```
installer\build\aowl.exe build
installer\build\aowl.exe importdb --from D:\SPT --out C:\Aowlspt

copy mods\tarkov\bin\tarkov.dll  C:\Aowlspt\mods\tarkov\
copy mods\tarkov\config.json     C:\Aowlspt\mods\tarkov\

backend\bin\aowlspt-backend.exe --root C:\Aowlspt --port 6969
```

`--out C:\Aowlspt` writes `C:\Aowlspt\db.json`, which is where
`aowlspt-backend --root C:\Aowlspt` looks for it. Check it with:

```
installer\build\aowlprobe.exe http://127.0.0.1:6969/client/locale/en
```

and expect to see `"Roubles"` rather than an empty table.

### Against an install, the path is one directory deeper

The recipe above is a scratch server: a directory you made, with `mods\tarkov`
directly under it. An **installed** tree is not shaped like that. `aowlspt-install`
puts everything under `<target>\aowlspt`, and that is what the backend is given
as its root, so the database has to go there too:

```
installer\build\aowl.exe importdb --from D:\SPT --out D:\Aowlspt\aowlspt
```

Following this page and `INSTALL.md` literally without that adjustment writes a
39 MiB file to `D:\Aowlspt\db.json` -- one directory above where anything looks
for it. The server then starts, passes every check `aowlspt-verify` makes, and
serves a client with no items, no traders and no quests in it. `aowlspt-verify`
reports the missing database as a finding for exactly this reason.
