# Waypoints

Bot patrol geometry for ten maps, served from the backend, plus the portable
part of upstream's patrol pacing tweak.

A port of [DrakiaXYZ's SPT-Waypoints](https://github.com/DrakiaXYZ/SPT-Waypoints)
(MIT, © 2023 DrakiaXYZ; the patrol points themselves were contributed by
Solarint). `LICENSE.txt` is upstream's, verbatim.

---

## What upstream actually is — read this before deciding what a port means

Upstream is two halves, and which half you look at depends on the tag.

* **1.3.4** shipped `Waypoints/Solarint/<map>.json` — 87 zones, 197 patrols,
  **8556 points** across ten maps — and injected them client-side into
  `BotZone.PatrolWays` via a Harmony patch and a `PatrolWay` subclass. It also
  carried a tiny SPT **server** mod (`ServerMod/src/mod.ts`) that retuned
  `bots.types.*.difficulty.*.Patrol`.
* **1.9.0 (master today)** has **dropped the JSON points entirely**. What it
  ships now is `<map>-navmesh.bundle` — Unity `NavMeshData` AssetBundles, about
  50 MB a release — loaded with `AssetBundle.LoadFromFile` and installed with
  `NavMesh.RemoveAllNavMeshData` / `NavMesh.AddNavMeshData`, plus door-link and
  exfil-door fixes and a `FindPath` override.

So "the data half" is unambiguous: it is the **1.3.4 point set**. The navmesh
bundles are not portable and are **out of scope**, not omitted — they are engine
assets built against a different Unity version, and installing one needs
`AssetBundle.LoadFromFile` plus two `UnityEngine.AI.NavMesh` statics called from
a mod, which is exactly the byte-verified call-by-RVA path that no mod on this
build has.

## Map identifiers: no translation was needed

Measured against the loaded `db.json`: `locations` has 19 keys, and all ten
upstream file names are among them **exactly** — `bigmap`, `factory4_day`,
`factory4_night`, `interchange`, `laboratory`, `lighthouse`, `rezervbase`,
`shoreline`, `tarkovstreets`, `woods`. Nothing was renamed or mapped.

Three of this database's locations have **no** upstream data and are reported
that way on `/waypoints/maps` under `noData`: `sandbox`, `sandbox_high`,
`labyrinth`. They postdate 1.3.4. (`develop`, `hideout`, `privatearea`,
`suburbs`, `terminal`, `town` are not raid maps.)

## The data: `aowlspt.waypoints/1`

`tools/import_spt.py` converts upstream's shape into
`data/<map>.json`. **1.99 MB of upstream JSON becomes 233 KB with all 8556
points intact**, because measurement over the whole corpus showed four fields
are constant and can be hoisted to document level:

| field | measured across all 8556 points / 197 patrols |
|---|---|
| nested `waypoints` | `null` everywhere — the recursion is never used |
| `patrolPointType` | always `checkPoint` |
| `canUseByBoss` | always `true` |
| `patrolType` | always `patrolling` |

`shallSit` is true for 127 points and is kept, as an index list per patrol.
Coordinates are rounded to 3 dp — half a millimetre, well under the metre-scale
rounding the only live consumer applies anyway. The importer **fails loudly**
rather than dropping anything if a future source file violates one of those four
assumptions.

```json
{"schema":"aowlspt.waypoints/1","map":"bigmap","space":"unity-world",
 "units":"metres","pointType":"checkPoint","bossUsable":true,
 "source":{"mod":"SPT-Waypoints","version":"1.3.4","author":"DrakiaXYZ",
           "points":"Solarint","license":"MIT","url":"..."},
 "counts":{"zones":12,"patrols":36,"points":2408},
 "zones":[{"zone":"ZoneScavBase","patrols":[
   {"name":"Mainbase","patrolType":"patrolling","maxPersons":4,"blockRoles":0,
    "points":[[210.248,1.731,-118.974], ...],"sit":[3,7]}]}]}
```

### The consumption contract

* **Routes** (server side, plain HTTP on the backend):

  | route | answer |
  |---|---|
  | `GET /waypoints/status` | what loaded, what was tuned, what was skipped |
  | `GET /waypoints/maps` | per-map `{zones,patrols,points,loaded}` + `noData` |
  | `GET /waypoints/points/<map>` | that map's document, verbatim |

  A map with no data answers `{"err":...,"reason":...}` naming the reason, not a
  bare 404 and not an empty document.

* **Coordinate space**: `unity-world`, metres, y up — the same frame
  `EFT.BotOwner::GoToPoint` takes, so a point goes into `aowlspt/botnav`'s
  `sendBotTo(id, x, y, z)` with **no transform**.
* **Ordering**: `points` is the patrol's traversal order, as upstream authored
  it. Patrols are emitted in sorted zone/patrol-name order so two conversions of
  the same input are byte-identical.
* **`maxPersons` / `blockRoles`** are carried through unchanged. Upstream's
  `blockRoles` is a `WildSpawnType` bitmask and is `0` for 176 of 197 patrols and
  `2` for the other 21; it is passed on raw rather than decoded, because the
  enum's members move between builds.
* **Versioning**: `schema` is checked at load. A document whose schema is not
  `aowlspt.waypoints/1` is **refused, not served**, and the refusal is logged.

## The patrol tuning — and the three keys post-1.0 dropped

Upstream's server mod sets six things. **Measured against this database, three
of them name keys that do not exist**: `GO_TO_NEXT_POINT_DELTA`,
`GO_TO_NEXT_POINT_DELTA_RESERV_WAY` and `USE_CHACHE_WAYS` are pre-1.0 SPT names.
A fourth, `SPRINT_BETWEEN_CACHED_POINTS`, exists at `easy`/`normal`/`hard` and
is **absent at `impossible`** for both PMC roles.

So this mod probes every key with `dbRead` before writing it, writes only the
ones that are really there, and reports the rest on `/waypoints/status` with the
count of role/difficulty blocks each was missing from — `absentIn: 2, of: 8` is
a very different statement from `absentIn: 8, of: 8`, and a bare key name would
have conflated them. Writing a key nothing reads would make the tuning look
complete when it is not.

What lands, on all 8 `bear`/`usec` × `easy`/`normal`/`hard`/`impossible` blocks:
`Patrol.LOOK_TIME_BASE` 12 → **3**, `Patrol.RESERVE_TIME_STAY` → **12**,
`Mind.CAN_STAND_BY` true → **false**, and `Patrol.SPRINT_BETWEEN_CACHED_POINTS`
100 → **400** on the six blocks that have it. **30 keys, one `dbWrite`** — a
patch splices into the whole loaded database, so 30 separate writes would cost
30 × 41 MB at boot.

Set `patrolTuning: false` in `config.json` to leave BSG's pacing alone; the
points are served either way.

## What this buys today, honestly

**The tuning half is live now.** It reaches the client on
`/client/game/bot/difficulty`, which is a route the client really reads, and it
needs no host flag and no RVA path. That is verified below.

**The point data is ready and inert until a consumer is wired to it.** Nothing
in the client consumes it automatically: upstream's injection point needs
Harmony and reflection, and post-1.0 IL2CPP has neither.

There is, however, **one live consumption path already in this repo** —
`aowlspt/botnav`. `sendBotTo(id, x, y, z)` reaches `EFT.BotOwner::GoToPoint`
through the client host and answers back a real `NavMeshPathStatus`, so a patrol
is a sequence of `sendBotTo` calls advanced on arrival, and a point that cannot
be reached says so (`navStatus == 2`) instead of failing silently. That is
strictly better placed than SAIN's cover and navmesh sensors, which **refuse** on
this build. But be clear about what it is not:

* it is **advisory** — the bot's brain re-targets and will argue, which is why
  commands carry `holdMs` and are re-issued every 500 ms;
* it is gated on `botNav` in `aowlspt-host.json`, which ships **`false`**;
* its census is **partial and rotating** (191-char budget) and positions are
  rounded to whole metres;
* it does not give a bot a `PatrolWay`. It tells a bot where to walk.

**What would have to land for this data to be worth more than it is now:** a
byte-verified call-by-RVA path usable from a mod, plus a settled argument
convention for by-value `Vector3` — the same two things SAIN's cover sensor is
blocked on. With those, the honest upgrade is not upstream's navmesh injection
(still out of reach) but a mod that owns patrol assignment directly.

**This has not been run against a live raid.** `/waypoints/status` reports what
was loaded and written, which is a different claim.

## Verifying it

Start a backend standalone, out of tree, then:

```
python mods/waypoints/tools/verify.py --base http://127.0.0.1:6971
```

Five checks, three outcomes each (PASS / FAIL / **INCONCLUSIVE**; "I could not
look" is never a pass). The important ones assert against something that is not
this mod's own output:

1. every map document parses **strictly** (`json.loads`, not a substring test);
2. every served coordinate is compared against **DrakiaXYZ's original 1.3.4
   files fetched from GitHub** — same count, same order, within 0.6 mm;
3. the negative: no NaN, no infinity, nothing beyond ±2000 m, no empty patrol;
4. the tuning is read back off **`/client/game/bot/difficulty`** — the route the
   client reads — for all eight blocks, not off this mod's status page;
5. each key the status page calls skipped is counted against those same eight
   payloads and must be absent from **exactly** as many as it claims.

Measured 2026-08-26 against a two-mod backend (`aowl.tarkov` + `aowl.waypoints`)
on `--port 6971`: **14 PASS, 0 FAIL, 0 INCONCLUSIVE**, 8556 points matched.

Re-fetch the upstream sources and regenerate `data/` with:

```
mkdir raw && for m in bigmap factory4_day factory4_night interchange laboratory \
    lighthouse rezervbase shoreline tarkovstreets woods; do
  curl -sfL -o raw/$m.json \
    https://raw.githubusercontent.com/DrakiaXYZ/SPT-Waypoints/1.3.4/Waypoints/Solarint/$m.json
done
python tools/import_spt.py raw data
```
