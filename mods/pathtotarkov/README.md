# Path To Tarkov, rewritten in nimony for post-1.0 Tarkov

The deploy screen is a teleporter: every map, always, from a menu. **Path To
Tarkov** is the mod that took that away and gave you a *place* instead — you are
standing somewhere, you may only go where that place connects to, and the map
you climb out onto is where you now are. It is one of the most-installed
server-side mods SPT ever had, and the reason is that it turns a map list into a
world.

This is that design, rewritten from scratch against `aowlspt`. Upstream is
TypeScript against SPT's server plus a BepInEx plugin against a pre-1.0 client;
neither exists here, so nothing was translated. What survived is the idea and
the shape of the rules.

```
aowl build-mod mods/pathtotarkov
host\Aowlspt.Sim\bin\aowlspt-sim.exe mods\pathtotarkov --side sim ^
    --db build\db\db.json                      # the self-test, on the real data
```

Server-only. It never enters the game's process, binds no method, and has no
per-frame path.

## Read this first

**Nothing here has ever run against BSG's client.** Not once. What this mod
does is read one table out of the database and write one field back into it, and
both halves are checkable offline — `aowlspt-sim --db build\db\db.json` checks
them, and `tests/pttguard` asserts on the numbers. What is *not* established by
any of that is the only thing that matters in a raid: that the client acts on
the field being written. That claim is an argument from the shipped data, and
the section [What a raid would be the first to disprove](#what-a-raid-would-be-the-first-to-disprove)
says exactly what would settle it.

Everything below is labelled. **Measured** means this build produced the number.
**From the database** means it was read out of `build/db/db.json`. **Argument**
means it is reasoning from data, not an observation of the game.

## The one thing this port does differently

Upstream had to **invent** the connections between maps. The pre-1.0 client had
no notion of one location leading to another, so PTT shipped a hand-written
table of exfil-name → destination and a client plugin to find out which exfil
you took.

Post-1.0 the game ships the table. Every `locations.<key>.base` carries a
`transits` array, and each entry names where it goes:

```json
{"id": 9, "location": "RezervBase", "name": "CUS_TRANSIT_9",
 "target": "5704e5fad2720bc05b8b4567", "active": true,
 "conditions": "CUS_TRANSIT_9_COND", "activateAfterSec": 60, "time": 20}
```

So this port **reads BSG's graph and never invents an edge**. The connections
cannot drift out of date with the client, because they *are* the client's. That
is also why this is a post-1.0 design rather than a port of a pre-1.0 one: the
mechanism upstream needed a client plugin for is now data.

`target` is the destination's `_Id`, and resolving by it is the whole trick.
`location` is a display-ish string that agrees with nothing in particular —
`RezervBase`, `factory4_day` and `Interchange` all appear in the same table —
so matching on it is how a mod ends up moving a player to a map they never
played. **From the database:** resolving by `target` resolves 38 of 38 edges.

## The mechanism, in one paragraph

`locations.<key>.base.Locked` is a boolean the database ships on every map. This
mod writes it: the map you stand on and everything one transit away are `false`,
everything else `true`, recomputed every time you come out of a raid. That is
the entire game-facing surface. No client half, no detour, no invented endpoint,
and no profile is touched by anything here.

**Argument (not observation):** that the client acts on `Locked` is inferred
from the shipped data — BSG ships `Locked: true` on exactly `hideout`,
`privatearea`, `suburbs`, `terminal` and `town`, which are exactly the entries
you cannot deploy to, including `terminal`, which ships `Enabled: true` and is
still unreachable. The field is therefore doing this job already, on this
database, for BSG. It is still an argument.

## The graph, as this database ships it

**From the database** (`build/db/db.json`, 41.3 MB, produced by
`aowl importdb` from a real SPT install), and asserted by `tests/pttguard`:

| | |
|---|---|
| maps | 19 |
| transits | 38 |
| edges that resolve to a map in the same table | 38 of 38 |
| transits BSG ships `active: false` | 4 (Ground Zero and Ground Zero 21+ → Labs, Shoreline→Terminal, an Interchange event loop) |
| `globals.config.TransitSettings.active` | `true` — the game's own transit system is switched on, which is what makes a graph worth locking by. The mod reads it and says so, and warns loudly if it is ever `false` |
| maps with **no way out** | `develop`, `hideout`, `privatearea`, `suburbs`, `terminal`, `town` |
| maps **nothing leads to** | `develop`, `factory4_night`, `hideout`, `privatearea`, `sandbox`, `suburbs`, `terminal`, `town` |

Two of those rows are the reason this mod has a stranding rule rather than a
tidy invariant:

* **the graph is directed and is not strongly connected.** Woods leads to
  Customs; Customs does not lead to Woods. Labs has exactly one way out
  (Streets).
* **nothing in the table leads to Ground Zero**, so it plays as a one-way front
  door — which is what makes it the default `startAt`.
* **`terminal` is a sink.** A player standing there under a strict graph could
  never move again. `freeRoamWhenStranded` exists for that, is on by default,
  and says why in the log when it fires.

From Customs, with the shipped settings, the open set is Customs, Reserve,
Factory, Interchange and Shoreline — five of nineteen.

## What survived, what did not

| upstream feature | here | what it costs you |
|---|---|---|
| you may only deploy to connected maps | **yes**, by `Locked` off BSG's transit table | — |
| the map you leave becomes where you are | **yes**, from `tarkov.raid.configured` + `tarkov.raid.ended` | — |
| **which exfil you took** decides where you end up | **no** | the raid-end event names a profile and nothing else, so this mod knows the map you played and not the door you left by. You arrive on the map you were on: right for a transit, wrong for an ordinary extract, where upstream would have moved you on. One field (`exit`, `location`) on `tarkov.raid.ended` would close it — see [What the API could not express](#what-the-api-could-not-express) |
| traders available only in your zone | **no** | the headline half of upstream's immersion is gone. Trader availability is per-profile and the profile belongs to `mods/tarkov`; a second mod editing another mod's profile documents behind its back is how a save gets corrupted |
| a stash per zone | **no** | same reason, and worse consequences if got wrong |
| dying sends you home | **no** | the raid-end event carries no outcome, so this mod cannot tell a survival from a death. `scavRaidsMove` is the one side-related setting it *can* honour, because the side is in the raid *configuration* |
| refusing a raid onto a locked map | **no** | `/client/match/local/start` belongs to `mods/tarkov` and a route may be registered once. If the client ignores `Locked` this mod cannot stop the raid; it warns after the fact instead, which is the line quoted below |
| offline "travel time" costing hours in-game | **no** | the game's own transits carry `time: 20` and `activateAfterSec: 60` and the client is what implements them. Reading BSG's numbers and re-implementing a competing clock server-side is a second source of truth about the same thing |

Two settings exist because of rows in that table rather than because someone
wanted a knob: `freeRoamWhenStranded` (the sink problem) and `allowTeleport` on
`/aowlspt/ptt/travel/<map>` (the only supported way out of a save that has got
stuck).

## What it is the first mod here to use

Read `docs/MODDING.md` and then the other ten mods, and this is what nothing had
touched:

| call | first use | why this mod needs it |
|---|---|---|
| `stateSave` / `stateLoad` + `mfHotReloadable` | **first in `mods/`** | a rebuild mid-session must not lose the baseline (below) or the raid in flight. Nothing else in the tree had claimed hot reload at all |
| `configFaulted()` | **first anywhere** | the docstring on it describes this mod: its defaults are decisions — a starting map, a hop count, a list of maps — and acting on them because the file failed to parse means locking fifteen maps the player never asked to have locked. A faulted config disables the mod loudly |
| `notifyReady()` | **first in `mods/`** | this cell used to say *first anywhere*; `examples/lesson` already probes it. Asked rather than assumed, and the answer is reported. `notifyPush` is used behind `notifyOnMove`, which is off, and the README says why below |
| `everyMs` | second call site in the tree | the reconcile pass. Nothing this mod serves is on the client's path, so there is no request to hang a periodic check off |

Beyond calls: it is the first mod to read `locations.*.base.transits` and
`globals.config.TransitSettings` at all, the first to write
`locations.*.base.Locked`, the first to **restore its database writes in
`onUnload`**, and the second consumer of the `aowlspt.locations.hello` /
`aowlspt.locations.changed` protocol `mods/icebreaker` publishes (it asks at
load, so a map another mod added joins the graph).

## The record that makes uninstalling safe

The one piece of state here that is not the player's game is the **baseline**:
what `Locked` said on every map *before this mod ever wrote one*. It is captured
exactly once per map and never updated, because after the first write the value
being read is this mod's own.

Lose it and the player cannot recover: uninstall, and every map this mod had
locked stays locked, in a database that persists, with no mod loaded to explain
it. So:

* `load` is checked for `missing` before anything is created. Missing means
  "new install"; present-and-unreadable disables the mod and says where the
  store's own history copy is. Creating a fresh baseline over an unreadable one
  would record this mod's writes as the world's original state.
* `onUnload` puts every map back. **Measured**, on the simulator with the real
  database: `put 11 map(s) back to the Locked they had before this mod ran`.
* the baseline crosses a hot reload in `stateSave`.

**From the database:** the baseline this mod captures on a stock import holds
`locked: true` for exactly `hideout`, `privatearea`, `suburbs`, `terminal` and
`town`, and `false` for the other fourteen.

## Notifications, and why the setting is off

`notifyOnMove` will almost certainly do nothing if you turn it on, and that is a
gap in the API rather than in the mod:

**`notifyPush` addresses a session; everything a mod can observe names a
profile; and there is no call that turns one into the other or enumerates live
sessions.** The session ids this mod can ever hold are the ones that arrive on
its own routes, which the game client never calls. So the setting is off, the
payload shape is this port's guess that no client has ever acknowledged, and the
move is `broadcast` to other mods regardless — which is the delivery that
actually works.

**Measured** on the simulator: `a push was refused as unsupported: this host has
no notifier`.

## What a raid would be the first to disprove

Everything below is a hypothesis this repository has no way to test.

1. **That the client hides a map with `Locked: true` on the deploy screen.**
   This is the whole mod. The disproof is a raid that starts on a map
   `/aowlspt/ptt/where` lists under `locked`. The mod is built to notice that
   one: `tarkov.raid.configured` on a locked map logs *"the raid is on <map>,
   which this mod has locked. Either the client does not act on Locked, or
   something else unlocked it."* If you see that line without having edited
   anything, the mechanism is wrong and the fix is a different field, not a
   different hop count.
2. **That a client which reads `Locked: false` on nineteen maps at login keeps
   reading it after the server changes it mid-session.** If the map list is
   cached at login, this mod is a per-restart mod and every move needs a
   relaunch to take effect. Nothing here can tell.
3. **That a transit in the client goes where the table says.** The graph is
   read, never exercised. If `target` is not the destination's `_Id` in the
   shipped client — only in the shipped database — the whole graph is
   plausible and wrong, and it would look exactly like this.
4. **That the raid the client configures names the map with a spelling this mod
   can normalise.** Four are handled (`bigmap`, `RezervBase`, the `_Id`,
   `ReserveBase`). A fifth would log *"a raid was configured on X, which is not
   a map this mod knows"* and move nobody, which is the safe way for it to be
   wrong.

## What the API could not express

Reported rather than worked around:

1. **`tarkov.raid.ended` carries only `{"profile": id}`.** Not the location, not
   the exit, not the outcome. This mod recovers the location by pairing the
   event with `tarkov.raid.configured` on the profile id — which works, and
   loses the exit and the outcome entirely. Those two are the difference
   between this port and upstream's travel rules. Adding `location`, `exit` and
   a survived flag to that broadcast costs one line in `mods/tarkov` and would
   close two rows of the gap table.
2. **There is no `dbKeys(path)`.** "Which maps does this database have" costs a
   read of the whole `locations` table — 13.5 MB on a stock import, and about
   560 MB on one imported with loose loot. So the shipped default is a
   hard-coded list of nineteen keys plus the announcement protocol, which is
   exactly the arrangement a key-listing call exists to avoid.
   `discoverMaps: "scan"` does it the honest way and prints what it cost.
3. **`notifyPush` is unaddressable from a third-party mod** — see above. A
   `sessionsFor(profileId)` or a `notifyProfile` on the host API would make the
   revision-5 facility reachable by mods that are not the game server.
4. **`aowl run <mod>` does not forward `--db`** despite its own docstring saying
   it forwards everything after the mod path; `aowl`'s option parser rejects the
   flag before `cmdRun` sees it. The commands above call `aowlspt-sim` directly
   for that reason. (`tools/` is not this mod's to edit.)

## Checks

**Build** — `installer\build\aowl.exe build-mod mods\pathtotarkov` → `ok mod
pathtotarkov`.

**The self-test**, against the real database, with locking on:

```
host\Aowlspt.Sim\bin\aowlspt-sim.exe <a copy of this mod with enabled:true> ^
    --side sim --db build\db\db.json --store <scratch>
```

produces, among other lines:

```
graph: 19 map(s), 38 transit(s), 0 of them naming a map this database does not have (31 ms to read)
the game's own transit system is on (globals.config.TransitSettings.active)
the world is set for sandbox: 11 map(s) written
a raid on tarkovstreets moved the player there
a raid ended by another profile moved nobody
a foreign unlock of bigmap was found by the reconcile pass and put back
the three routes answer, and travel to a map that is not there is refused while travel to one that is, is not
a push was refused as unsupported: this host has no notifier
state survives a reload: 19 baseline(s), position tarkovstreets
put 9 map(s) back to the Locked they had before this mod ran
```

**Against a real backend**, on a scratch root with the real 41.3 MB `db.json`:

```
GET /aowlspt/ptt/where
{"position":"sandbox","maps":19,"transits":38,"unresolved":0,"writes":11,
 "open":["sandbox","tarkovstreets"],
 "locked":["bigmap","factory4_day",...,"woods"],
 "lockedInDatabase":[... the eleven above plus BSG's five ...]}

GET /aowlspt/ptt/travel/bigmap
{"ok":false,"err":"bigmap is not reachable from sandbox; set allowTeleport to travel anywhere"}

GET /aowlspt/ptt/travel/tarkovstreets
{"position":"tarkovstreets","moves":1,"open":["tarkovstreets","sandbox_high","interchange","laboratory"], ...}
```

`lockedInDatabase` is read back out of the database rather than remembered, so
it is the check that the writes landed.

**The test** — `tests/pttguard`, 62 assertions against `build/db/db.json` with
no host and no backend:

```
nimony c -p:mods\pathtotarkov -p:aowl\src -o:installer\build\pttguard.exe ^
    tests\pttguard\pttguard.nim
installer\build\pttguard.exe [path\to\db.json]
```

Every check there is paired with its opposite, because the failure this
repository keeps producing is a check that passes because the thing it checks
never happened. Two deliberate mutations were run against it:

* making `resolve` match the first node instead of the `target` id → **8 checks
  red**, including "Customs connects to exactly four maps: 1".
* making `rememberBaseline` update an existing baseline instead of keeping it →
  **1 check red**, "and the first value is the one kept" — the exact mutation
  that would make uninstalling destructive.

Both were reverted; the file in the tree is the green one.

## Settings

`config.json` documents every key on the line above it. The four to know:

* **`enabled`** — off. Nothing is written until you turn it on. With it off the
  mod still reads the graph and prints how many maps it *would* lock, which is
  the thing to look at first.
* **`startAt`** — `sandbox` (Ground Zero). Nothing in BSG's table leads back to
  it.
* **`hops`** — 1 is Path To Tarkov as it plays. 2 barely moves from Ground Zero
  (5 of 19) but opens 10 of 19 from a hub like Customs — ten of the thirteen
  maps this mod ever locks, which is close to having it switched off. This used
  to say 2 opens most of the map list, which is only true from a hub.
* **`freeRoamWhenStranded`** — on. Do not turn it off without reading the sink
  row above.

## Attribution

The design is **Path To Tarkov**'s, from the SPT hub. This file deliberately
does not print an author's name: it could not be verified offline in this
session, and a confident wrong attribution is worse than a missing one. No
upstream code was read or translated for this port — the mechanism here is
BSG's transit table, which upstream predates — so there is no licence travelling
with it; if you know the author, the credit belongs at the top of this file.
