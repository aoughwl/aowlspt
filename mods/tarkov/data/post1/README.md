# post-1.0 static tables

Routes the post-1.0 client asks for that have **no pre-1.0 equivalent**, so
there is nothing in the SPT-derived `build/db/db.json` to build them from.
These are BSG's own answers, taken verbatim from a capture of a real session
and stored as the bare `data` member of the response — the envelope is added
by the route.

Read by `emu/post1.nim`. Regenerate from a capture with `tools/bsgwire.py`.

| file | route | seq | bytes |
|---|---|---|---|
| `mainquests.json` | `GET /client/quest/getMainQuestsList` | 073 | 424 |
| `mainquestnotes.json` | `GET /client/quest/getMainQuestNotesList` | 074 | 97,260 |
| `variablegroups.json` | `GET /client/variable/group` | 075 | 12,115 |
| `tapes.json` | `GET /client/tape/list` | 077 | 8,966 |
| `subtitletracks.json` | `GET /client/subtitle-track/list` | 078 | 11,867 |
| `questchains.json` | `POST /client/quest/chains` | 146 | 6,243 |
| `metricsconfig.json` | `POST /client/getMetricsConfig` | 154 | 341 |
| `serversettings.json` | the `serverSettings` of `POST /client/match/local/start` | 158 | 3,927 |
| `locationpaths.json` | the `paths` of `GET /client/locations` | 134 | 1,670 |
| `customizationstorage.json` | `POST /client/customization/storage` | 086 | 3,397 |
| `defaultequipmentpresets.json` | the `equipmentBuilds` of `POST /client/builds/list` | 123 | 57,428 |

Source capture: `mods/tarkov/data/capture/raid1`, a full session against the
live backend on 2026-08-20, client build 1.1.0.1.46777.

`customizationstorage.json` is the 49 `source: "default"` entries a fresh
account owns. The captured response also carries 13 `source: "preorder"`
entries, which depend on the game edition and are **not** stored here. Nothing
in this server grows this list as a player unlocks things, so it is the
starting wardrobe permanently -- a smaller lie than the object-shaped answer it
replaces, and still one.

`defaultequipmentpresets.json` is the twelve `BuildType: "Standard"` loadouts
(Papasha, Hunter, Shotgunner, Scout, Fighter, Guard, Gunslinger, Sharpshooter,
Operator, Marksman, Raider, Robber; 352 items between them) that the real
backend returns to every profile. They are a constant of the install, never
stored under a profile's builds key, and merged in after the player's own by
`emu/builds.withDefaultEquipment`.

They are load-bearing, not decoration. `EquipmentBuildsScreen.Show` calls
`Enumerable.First` on `equipmentBuilds`; with the list empty it throws
`InvalidOperationException: Sequence contains no elements` inside `Show`, and
the kits screen opens and closes in the same frame. Our answer was valid JSON,
correctly typed and complete on every key -- and empty, which no shape check
can see.

`locationpaths.json` is the transit graph -- 18 edges over 10 maps. It is used
only when the database has none, which today is always: SPT keeps the graph in
`database/locations/base.json` and `aowl importdb` does not import it, so
`locations.paths` is `[]` on every database this repository produces. Importing
it properly replaces this with no other change.

`serversettings.json` is the odd one: it is not a whole response but the
`serverSettings` member of one, because the rest of that response is the map
and the map is built from the database. It holds `TraderServerSettings` (the
eight trader services) and `BTRServerSettings` (fifteen tuned numbers for the
armoured transport). Both are static game config. Taken from a **tutorial**
raid, the only `match/local/start` in the capture -- almost certainly identical
for other modes, but that is reasoning rather than evidence.

## Not here, and why

* `/client/dialogue` — the same kind of static table, and 13 MB decoded. Too
  large to check in beside these; it needs its own decision.
* `/client/tutor-game/profile` — looks static, but the body is a profile. It
  belongs to the profile store, not to a table.

## What these are and are not

They are **one build's** data. Nothing here is derived or synthesised, so a
Tarkov update invalidates all of it at once and silently — the client will
happily render a stale chapter list. When the game updates, recapture.
