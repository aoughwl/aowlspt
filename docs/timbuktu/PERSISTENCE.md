# Escape from Timbuktu — the world/session persistence pillar

The pillar this document designs is the one that makes the world *the same
world* when you come back: containers and their contents, doors, placed
structures, NPCs and what they own, dropped items, corpses, and the map state
each of those lives on.

Everything below is either a fact checked against a file in this repository —
named, with the proc or the constant — or it is marked as an open question.
Where the brief and the repository disagree, the repository wins and the
disagreement is written down.

**The sentence that governs the whole document, and it is not mine:**

> **Nothing in this repository has ever run against BSG's client.**
> — `docs/ARCHITECTURE.md:9`, `docs/API-GAPS.md:11`, `docs/BACKLOG.md:201`

So this pillar splits cleanly in two, and the split is not a matter of taste.
The **server half** is designed here against code that exists and has been
measured. The **client half** — anything that needs to know what happened
inside a raid — is a set of open questions, because the type names it would
have to call are guesses. Section 3 says which is which.

---

## 1. What exists today and can be reused

### 1.1 The store — `host/common/modstore.nim`

`<root>/store/<mod-guid>/<key>`, one file per key, shared by both hosts. What
it already promises, and what a world save can therefore stop worrying about:

* **A value is never half-written.** `commitNow` (`:756`) writes a temporary
  into `.hist/<key>.tmp` and renames it over the key through `atomicPut`
  (`:609`). A reader sees the whole old value or the whole new one.
  `tools/storecrash.nim` kills a process mid-write to check it.
* **A write is committed before `storeWrite` returns** (`:815`). No queue, no
  write-behind, nothing a host must remember to flush. The doc comment records
  that a queue *was* tried and removed, because "a process killed outright lost
  a save it had already reported as made".
* **"Never written" and "unreadable" are different answers.**
  `storeReadInto` (`:374`) → `Stored.missing` in `aowl/src/aowlspt/server.nim:687`
  → `emu/store.readKey(key, usable)`. The doctrine at the top of
  `mods/tarkov/emu/store.nim` is the one this pillar must inherit wholesale: a
  read-only path may take the empty answer, a path that is about to **write**
  must refuse. A world save has exactly the same shape of bug available to it,
  one table over.
* **Cross-host reads are honest.** `stillNamed` (`:160`) drops a held handle
  whose file has lost its name, so the client host and the backend running at
  once against one `<root>/store` do not serve each other stale bytes.
  `renameHeld` (`:516`) with `FILE_RENAME_FLAG_POSIX_SEMANTICS` is what lets a
  commit land while the other side holds the key open.
  `tests/storeperf/storeguard.nim` fails 2 of 9 against the code as it was.

What the store does **not** give, and both matter here:

* **No cross-key atomicity.** Two keys written in sequence can be torn by a
  kill between them. Section 2.5 is entirely about this.
* **No delete.** The ABI has `store_get` / `store_set` / `store_list`
  (`abi/aowlspt_abi.h:445-447`) and nothing else. A key can be emptied, never
  removed. Any design that mints keys dynamically mints them for the life of
  the save. This is the single biggest constraint on the shape below.

Bounds worth knowing before choosing a key layout, all from
`host/common/modstore.nim`:

| constant | value | consequence for a world |
|---|---|---|
| `BackupGenerations` | 3 | on-disk cost is up to 4x the live bytes |
| `BackupIntervalMs` | 300_000 | one history snapshot per key per five minutes |
| `BackupTrackMax` | 4096 | past 4096 tracked keys `gKeys` is emptied wholesale and snapshots come early |
| `HeldMax` | 32 | the open-handle LRU; a hot set larger than 32 pays an open per read, and an open after a write is the ~890 µs antivirus rescan the cache exists to avoid |

`storeKeys` (`:889`) uses `collectEntries`, which **recurses**, then filters out
anything with a path separator. So enumerating keys walks `.hist` too: the cost
of `savedKeys` is O(live keys × up to 4). It must not be on a request path.

### 1.2 Identity that already survives a restart — `mods/tarkov/emu/ids.nim`

This is the most directly reusable thing in the repository for this pillar, and
it was built for exactly the failure a persistent world would otherwise hit.

`initIds()` (`:97`) reads the run number from the store key `ids.run`, advances
it by one, and **writes it back before a single id is handed out**. `newId()`
(`:139`) is `hex(run,12) & hex(counter,12)`. The invariant it states:

> **An id issued after a restart can never be one an earlier run could have
> issued.**

A load that cannot establish the run number refuses to start the mod. That is
already the correct answer for a world save: a server that cannot guarantee a
fresh id is a server that will collide a newly-placed chest with a chest placed
three sessions ago.

So: **every created world entity gets its identity from `newId()`, and needs no
new mechanism.** Authored entities are a different problem — see 2.3.

### 1.3 Determinism in loot generation — `mods/tarkov/emu/loot.nim`

`generateLoot(d, cfg, locationId, raidId)` (`:999`) is pure in everything except
the database handle:

> "the same database, config, map and raid id give the same string. `raidId` is
> the seed and it is the only source of variation"

`seededRng(raidId & "|" & locationId)` is the entire entropy source; there is no
ambient RNG anywhere in the module. `emu/raid.localLoot` (`:235`) passes the
raid id, falling back to the map name when there is none.

This is worth more than it looks. It means **a map's floor is already a pure
function of a seed**, so a persistent world does not have to store a map — it
stores a seed and a delta. Section 2.4.

The call chain is short and entirely ours: `/client/location/getLocalloot` →
`onLocalLoot` (`mods/tarkov/tarkov.nim:991`) → `localLoot(loc, nowSeconds(),
gRaidId)` → `lootFor(name, seed)` → `generateLoot`. Changing where the seed
comes from is a change to one argument.

### 1.4 Per-concern key prefixes — the emulator's own precedent

The emulator already partitions a player's state across keys rather than one
document, and the reasons it gives are the reasons a world should:

| key | source | why it is not in the profile |
|---|---|---|
| `profile.<id>` | `emu/profile.nim:30` | — |
| `scav.<pmc id>` | `emu/scav.nim:37` | the PMC stash is spliced in at read time |
| `mail.<id>` | `emu/mail.nim:56` | bounded independently by `mailKeepHours` |
| `maildlg.<id>` | `emu/mail.nim:265` | per-dialog read/pin state |
| `market.<id>` | `emu/market.nim:61` | |
| `insurance.<id>` | `emu/insurance.nim:53` | the pending-return queue |
| `builds.<id>` | `emu/builds.nim:33` | **because `/client/match/local/end` replaces the profile wholesale** |
| `repeat.<id>` | `emu/repeatable.nim:105` | "Nothing is stored that can be derived" |
| `lang.<id>` | `emu/dialogue.nim:314` | |
| `sessions` | `emu/sessions.nim:18` | read on every request |
| `ids.run` | `emu/ids.nim:48` | must be readable before any profile is |

The `builds.<id>` row is the important one and it is a warning aimed straight at
this pillar: **the client hands back a whole profile document at raid end and
the emulator installs it verbatim** (`onMatchEnd`, `mods/tarkov/tarkov.nim:1016`:
`var updated = Profile(id: p.id, text: raw(played), ok: true)`). Anything the
server knows that the client does not must live outside the profile or it is
destroyed once per raid. World state is the largest such thing there will ever
be.

Key syntax permits this shape directly: `validKey` (`modstore.nim:327`) accepts
`[A-Za-z0-9._-]`, so `world.w1.map.bigmap.a` is one flat, legal key.

### 1.5 Serialisation that already exists — and its exact boundary

`aowl_session_lock` (`abi/aowlspt_net.h:513-598`, called at
`backend/aowlbackend.nim:934`) serialises request handling **per session id**,
across the whole callback, with 128 slots and a 10 s give-up that answers 503.

For a single-player game this is stronger than it sounds. `mods/tarkov` says of
itself "this server plays one player" (`gRaidId`, `tarkov.nim:88`), so in
practice *every `/client/...` route for the player runs one at a time*. A world
mutation applied on a request thread is therefore already safe against other
request threads.

It is **not** safe against timers. `everyMs` handlers fire from the serve loop
(`backend/aowlbackend.nim:1675`: "`hostSchedule` runs on whatever thread a route
handler is on"), which is not a session and takes no session lock. That is the
one real race in this pillar and section 2.5 names what to do about it.

Note also what the session lock is *not*: it is keyed on the session id, not the
profile id. `emu/profile`'s `saveIfUnchanged` / `profileVersion`
(`emu/profile.nim:436-459`, 64 hashed slots) exists because of that, and its own
comment says plainly: "**This narrows the window; it does not close it.**
Closing it means the host serialising item-event handling per profile, which is
a change in `backend/`."

### 1.6 Things that look reusable and are not

* **`state_save` / `state_load`.** They are in the header
  (`abi/aowlspt_abi.h:649-650`), in `exportMod`
  (`aowl/src/aowlspt.nim:1448`), and **no host calls either of them**
  (`docs/ARCHITECTURE.md`). A `--watch` reload starts a mod from zero. Do not
  build a world on them without first making a host call them.
* **`notify_push`.** Not present in the client host at all — `AowlHostApi.size`
  stops at the revision-4 boundary because there is no notifier socket in the
  game process (`docs/IL2CPP.md:100`). A client-side world reporter cannot push
  to the backend.
* **`route_register` / `db_get` / `db_patch` on the client host.**
  `ErrUnsupported`. A client mod cannot serve or read the database.
* **`emu/notify`'s queue.** In memory and "deliberately not persisted"
  (`emu/notify.nim:33`).

---

## 2. The model

### 2.1 What a world is

A **world** is one playthrough: a save slot holding everything that is not owned
by a player profile. Maps, containers, doors, structures, NPCs, dropped things,
corpses, story state, and the world clock.

A world is created once, given a **world seed** at creation, and never
regenerated. Its identity is a `newId()` taken at creation and never reused
(`emu/ids.nim` gives that for free). Profiles are *bound* to a world; the
profile document is untouched by this pillar and keeps its existing key,
protocol and commit rules.

That separation is deliberate and follows the `builds.<id>` precedent in 1.4: at
`/client/match/local/end` the client hands back a profile document that
overwrites `profile.<id>` in full. A world stored inside the profile would be
deleted by the client, once per raid, silently.

### 2.2 What a session is

A **session** is one contiguous run of the backend process serving one world. It
begins when the store lock is claimed (`storeLock("backend", …)`,
`modstore.nim:289`, `FILE_FLAG_DELETE_ON_CLOSE`, one backend per store) and ends
when the process ends, however it ends.

Sessions already have a durable, monotonic number: `ids.run`. **Reuse it as the
world's epoch counter.** It is advanced and written before any id is issued, it
cannot go backwards, it refuses rather than guesses, and it is already the thing
that makes ids from two runs disjoint. A world does not need a second one.

The player-facing session (`PHPSESSID` → profile) is `emu/sessions.nim` and is
unchanged. The two are different objects that unfortunately share a word; this
document says **run** for the process-lifetime one wherever it might be unclear.

### 2.3 Entities and how identity stays stable

Two classes, and the whole correctness of the pillar is in telling them apart.

**Authored entities** exist because the database says so: a static container on
Customs, a door, a loose-loot spawn point. Their identity must be derived from
the database, never minted, because a minted id is different on the next boot
and the world would then contain two of everything.

The database supplies part of this and not all of it.
`emu/loot.staticContainers` (`:778`) reads `tmpl.field("Id")` into `spawnId` and
uses it to look up `staticForced` — so **static container spawn points do carry
a stable authored `Id`**, and that is the identity to use. But the same proc
then mints the runtime container with `let containerId = mongoId(r)` — a
*seeded* id, reproducible from `(raidId, locationId)` and therefore **not**
stable across raids as things currently stand. Making it stable is 2.4.

For loose-loot points and for doors I have **not** established that a stable
authored key exists. Loose loot is read by `looseSpawn` (`:886`) out of
`locations.<map>.looseLoot`; whether each point carries an id in this
repository's imported database is a thing to check against `build/db/db.json`
before designing on it, and I have not checked it. Doors do not appear in the
server-side data at all — see 3.1.

The identity for an authored entity is therefore
`(<mapKey>, <authored id or a hash of the authored transform>)`, and that pair
is what the delta in 2.4 is keyed on. Where no authored id exists, the entity
class cannot be persisted authored-side and must be treated as regenerated.

**Created entities** exist because something in the world made them: a chest the
player placed, an item dropped on the floor, a corpse, an NPC with a name.
Identity is `newId()`. Nothing further is needed — 1.2.

### 2.4 The save format: seed plus delta, one shard per map

The naive save is a snapshot of every map. On the imported database three maps
alone produce 1,826 loot items (`emu/loot.nim:999` comment), and a map's
`looseLoot` subtree reaches 560 MiB across the table
(`emu/raid.nim:52-56`). A snapshot-based world save is not affordable and does
not need to be.

Instead, and directly out of 1.3:

```
world.<wid>.meta                    the manifest: schema, epoch, slot map,
                                    world seed, bound profiles, world clock
world.<wid>.map.<mapKey>.<slot>     per-map delta + that map's generation seed
world.<wid>.npc.<bucket>.<slot>     named NPCs: position, inventory, standing,
                                    liveness, relationships
world.<wid>.story.<slot>            the procedural story state
```

`<slot>` is `a` or `b`. Section 2.5 says why.

A **map shard** holds, for one map:

* `seed` — fixed at world creation. This replaces `gRaidId` as the argument to
  `generateLoot`, which is the one-line change described in 1.3. The map's
  untouched floor is then the same floor every time you walk onto it, for the
  life of the world, and costs about a hundred bytes to store.
* `taken` — authored entity keys whose contents have diverged: a crate that was
  looted, a point whose item is gone.
* `contents` — for containers that hold something other than what the seed says:
  the item array, in the same shape `emu/inventory` already edits
  (`_id`, `_tpl`, `parentId`, `slotId`, `location`), placed by `emu/grid`
  (`findSpace` / `markOccupied`, `emu/grid.nim`) so nothing overlaps.
* `placed` — structures the player built, with their transforms.
* `dropped`, `corpses` — created entities with a world-clock timestamp.
* `doors` — open/locked state, **if** 3.1 resolves.

The property this buys: **an untouched world is the size of its seeds, and the
save grows only with what the player changed.** That is the only growth model
that survives a long playthrough, and it falls out of a determinism guarantee
that already exists and is already tested.

One shard per map, not one document, because a boundary commit then writes only
the maps that changed. Nineteen maps is nineteen keys, well inside the 4096 of
`BackupTrackMax` and the 32 of `HeldMax` for the working set.

**NPC bucketing is a bound, not an optimisation.** There is no delete in the
store (1.1), so a key-per-NPC world can never shed a key: an NPC who dies in
chapter one costs a file, a `.hist` ring and a slot in `gKeys` for the rest of
the playthrough. So named NPCs are bucketed into a fixed, small number of shards
(hash of the NPC id modulo, say, 16), and that number is fixed at schema time.
Anonymous scavs are not persisted at all — they are regenerated by
`/client/game/bot/generate` → `emu/bots`, which is where persistent NPCs get
*injected*, not where they get stored.

Format is JSON text, edited member-wise through `aowlspt/json`, for the reason
`emu/profile.nim:11-17` gives about the profile: a typed model has to name every
field to avoid dropping one, and the day the schema grows a field a typed model
silently deletes it from every save it touches. Text plus a merge keeps what it
does not know about. That property is also half of the migration story (2.7).

### 2.5 Commit granularity, and the crash-consistency story

**Rule one: nothing in this pillar commits on an interaction path.**

The owner's open decision (`docs/BACKLOG.md`, Group G1) is that the profile is
committed on every inventory drag. The measured cost after the 2026-08-19 work:
`store_set` 476 µs, `items/moving` 0.90 ms, throughput 961 req/s. A persistent
world touched the same way — a commit per door, per crate, per dropped magazine
— would be that same decision taken again, worse, and without anybody deciding
it. So the world does not do it.

**World state accumulates in memory and commits at boundaries.** The boundaries:

1. `/client/match/local/end` — `onMatchEnd`, `tarkov.nim:1016`.
2. A map transit, when there is one — see 3.2.
3. `/client/game/logout` — `onLogout`, `tarkov.nim:183`.
4. The existing minute timer — `everyMs(60000, sweep)`, `tarkov.nim:1725`. A
   world commit rides the sweep that is already there rather than adding a
   second cadence.

At one boundary per raid, six commits of a few kilobytes is single-digit
milliseconds against a raid. That is affordable in a way per-interaction is not.

**Crash consistency needs more than the store gives.** The store's atomicity is
per key (1.1). A boundary that writes four map shards and then a manifest can be
killed after the second, leaving a world whose manifest and shards disagree.

The answer that needs nothing new in the host is a **two-slot shard with the
manifest as the commit point**:

* every shard exists as `…​.a` and `…​.b`;
* `world.<wid>.meta` names, per shard, which slot is live, alongside the epoch;
* a boundary writes every dirty shard into its **non-live** slot, then commits
  `meta` — one key, one atomic rename, `commitNow` (`modstore.nim:756`);
* a kill before the `meta` write leaves every live slot exactly as it was. The
  half-written non-live slots are garbage that the next boundary overwrites.

The commit point of the whole world is therefore one `storeWrite` of one key,
which is the strongest guarantee available on this store and is the same
guarantee the profile already has.

Costs, stated honestly: 2x the world's disk for the slots (on top of the up-to-3
`.hist` generations), a `meta` document that must name every shard and is
rewritten at every boundary, and a hard requirement that shard count stays
small — which 2.4 already imposes for a different reason.

The alternative is a journal key replayed at load. It halves the disk and adds
an append-only key that nothing can truncate, because there is no delete. I do
not recommend it for that reason, but it is a real option and the owner should
see it.

**The race that is left, and it is real.** Boundaries 1–3 run under the session
lock (1.5). Boundary 4 does not: `everyMs` fires from the serve loop, which
takes no session lock. So a timer-driven world commit can read a dirty set that
a request thread is halfway through mutating. Three ways out, none free:

* Drop boundary 4. The world then commits at raid end and logout only, and a
  hard kill mid-raid loses the raid — which is what the game loses anyway.
  **This is what I would do first**, because it removes the race instead of
  guarding it.
* Make the timer only *request* a commit — set a flag that the next
  session-locked route performs. Correct, and it means a player who walks away
  from the menu never commits.
* Serialise in `backend/`. That is the change `emu/profile.nim:414-418` already
  says is needed for the profile and that nobody has made. It is not a mod
  change and it is not this pillar's to make alone.

There is also the emulator's own narrowed-not-closed window
(`saveIfUnchanged`, 1.5). A world shard read-modify-written from two threads has
exactly that bug. The world needs the same counter discipline — and it needs it
in a fixed array, not a `seq`, for the reason `emu/profile.nim:406-413` gives:
a `seq` that reallocates while another thread walks it is a crash, and there is
no lock in the mod API, and there should not be one.

### 2.6 What bounds the save

| class | bound | mechanism |
|---|---|---|
| map floors | seeds only | 2.4 — a pure function of a seed, not stored |
| looted containers | O(containers the player opened) | one key per diverged container |
| container contents | O(what the player stored) | this is the player's stash and must not be bounded |
| placed structures | O(what the player built) | must not be bounded |
| dropped items | **bounded by TTL** | world-clock expiry, swept on the existing minute timer |
| corpses | **bounded by TTL** | same |
| named NPCs | bounded by design | a fixed roster; anonymous bots regenerate |
| story state | bounded by design | a state machine, not a log |
| dead keys | **not bounded** | there is no delete; see 4.1 |

The floor of a long playthrough is therefore the player's own possessions, which
is the same order as the profile is today: `modstore.nim` measures the emulator's
profile at 3 KB new and **84 KB after two hundred raids**. A world whose stored
items are of that order is a save in the low hundreds of kilobytes, times two for
slots, times up to three for history.

Two growth traps already documented in this repo that apply verbatim:

* `emu/numbers.numText` rounds to six decimals because "the profile is read and
  written whole on every request, so a value that gains digits every time it is
  added to is a document that grows and a request that slows, forever". Any
  float in a world shard — a transform, a rotation, a durability — must go
  through the same rounding.
* `mail.<id>` grew 267 bytes per withdrawn-and-collected offer, monotonically,
  for the life of the profile (`docs/EMULATOR-REFUSALS.md`). The general shape:
  a per-event record with no expiry rule is unbounded whatever it holds. Every
  list in a world shard needs a stated expiry rule at the moment it is added,
  not the moment it is noticed.

### 2.7 Migration

`world.<wid>.meta` carries `schema`, an integer.

* **A world whose schema is newer than the build refuses to load**, by name, and
  the build says so and stops. Not read-only, not partially applied, not
  "best effort". This is the same doctrine as `initIds()` refusing to issue an
  id it cannot guarantee (`emu/ids.nim:97`) and as `emu/selfchecks` refusing to
  serve a build that fails its own arithmetic.
* **A world whose schema is older is migrated into the non-live slots**, shard
  by shard, and the migration's commit point is the `meta` write — exactly the
  boundary protocol of 2.5. A migration killed halfway leaves the old world
  intact and openable by the old build. The two-slot layout pays for itself a
  second time here, which is most of why I chose it over a journal.
* **Unknown members are preserved**, because shards are text and edits are
  member-wise (2.4). A shard written by a newer minor build and read by an older
  one loses nothing.
* **No pre-migration copy**, because there is no delete: a `world.<wid>-pre7.*`
  snapshot would be permanent garbage. The recovery for a bad migration is the
  store's own `.hist` ring (`<root>/store/aowl.tarkov/.hist/<key>.1..3`), which
  is bounded by time rather than by version and is therefore *a* safety net and
  not *the* safety net. Say so to the player; do not pretend otherwise.

---

## 3. The open questions and the refusals

### 3.1 Tarkov destroys world state at raid end. What has to be intercepted?

Split it, because the two halves have completely different answers.

**What the server can see today.** Every one of these is a route already
registered in `mods/tarkov/tarkov.nim` and handled by code in this repo:

| moment | route | handler | what it gives a world |
|---|---|---|---|
| the map's floor | `/client/location/getLocalloot` | `onLocalLoot` `:991` → `localLoot` → `generateLoot` | **the world can seed a map**. This is the hook 2.4 is built on. |
| who spawns | `/client/game/bot/generate` | `onBotGenerate` → `emu/bots` | **persistent NPCs can be injected**: a bot is a profile with `Info.Settings.Role` set, and the server builds it |
| the raid's id and clock | `/client/raid/configuration` | `onRaidConfiguration` `:981` | the per-raid identity, and `broadcast("tarkov.raid.configured", …)` |
| entering | `/client/match/local/start` | `onMatchStart` `:996` | |
| leaving | `/client/match/local/end` | `onMatchEnd` `:1016` | the profile the player came out with, and the exit status |

**What the server cannot see, and this is the crux of the entire pillar.**

The raid runs entirely on the client. The only thing the client tells the server
about it is the profile document it came out with and how it left. Therefore:

> **The server can know what left the map. It cannot know what stayed on it.**

The server can derive "this crate is empty now" only by inference — the items
that were in it are now in the profile — and it cannot derive *at all* which
door you unlocked, what you dropped on the floor, where a corpse fell, or which
crate you opened and found nothing in. `docs/EMULATOR-REFUSALS.md` says the
matching thing about exits: "the exit points themselves come out of the client's
own bundles and the server is never asked which ones opened".

So there are two possible worlds, and the owner picks:

* **A server-only world.** Persists seeds, container contents inferred from
  profile deltas, placed structures declared through routes, NPC state the
  server owns, and story state. Doors, dropped items, corpses and in-raid
  interactions **do not persist**. This is entirely buildable today against code
  that exists. It is a real game and it is not the brief's game.
* **A world with a client reporter.** A client-side mod reads the in-raid world
  and writes a report; the server picks it up. Everything below is why that is
  currently an open question and not a design.

**Is a client reporter reachable?** Partly, and the unknown part is the part
that matters.

What is established. The client host can `resolve` any type and `call` any
method by name, patch compiled methods prefix/postfix/typed, turn a handle into
a pointer (`handle_pointer`, revision 3), and it has `store_get` / `store_set` /
`store_list` (revision 2) — `docs/IL2CPP.md`. And the channel to the backend
already exists and is already tested: the two hosts are *meant* to share one
`<root>/store`, and `stillNamed` / `renameHeld` /
`tests/storeperf/storeguard.nim` exist specifically to make that honest (1.1).
A client mod writing `world.<wid>.report.<n>` and the backend reading it at the
next boundary needs no new ABI.

What is **not** established, and I will not pretend otherwise:

* **Whether the types exist under those names.** `reference/` holds only the
  **SPT 4.x server** surface (`reference/README.md`: "Read it as documentation
  of the game's backend"). There is no dump of the post-1.0 client's IL2CPP type
  surface anywhere in this repository. Every `EFT.*` name in this tree —
  `EFT.GameWorld` in `mods/sain/client/live.nim:1114`, `mods/fov`,
  `mods/classicmovement`, `mods/blackdivision` — is inherited from pre-1.0
  knowledge and has never been resolved against BSG's client. `docs/IL2CPP.md:513`
  is explicit: "**None of this has been seen against BSG's client.**"
* **Whether `EFT.GameWorld` exposes an enumerable collection of lootable
  containers, doors, or loose items at all.** `mods/sain` binds
  `get_Instance` and `get_AllAlivePlayersList` and nothing else of this kind. I
  found no code in this repository that touches a container, a door or a world
  item.
* **Whether such a collection could be walked at raid end.** A postfix on a
  raid-teardown method is the obvious shape, and `docs/IL2CPP.md` records two
  standing postfix refusals — stack arguments past the fourth register slot, and
  struct returns — either of which could rule out the specific method needed.
* **Whether writing world state back at raid start is possible at all.** Placing
  the player's chest into the level means constructing game objects, not reading
  them, and nothing in this repository has ever constructed one.

**Verdict: the client half of this pillar is an open question, not a design.**
It is blocked on one artefact — a dump of the post-1.0 client's IL2CPP types —
and the honest thing is to get that artefact before designing anything that
names a client type. 4.2.

### 3.2 The raid-end body: a discrepancy in this repo, already known

`onMatchEnd` reads `field(body, "exit")` and `field(body, "profile")` at the top
level (`tarkov.nim:1016` onward). The SPT 4.x model
(`reference/spt-4.1-surface.txt:9766`) is:

```
EndLocalRaidRequestData
    prop EndRaidResult Results          -> { Result: ExitStatus, Profile: PmcData,
                                             ExitName, PlayTime, KillerId, ... }
    prop Dictionary<String, IEnumerable<Item>> TransferItems
    prop IEnumerable<Item> LostInsuredItems
    prop LocationTransit LocationTransit
    prop String ServerId
```

`docs/API-GAPS.md` already records this: "**This emulator is reading a body
shape it invented**". `tools/emutest.nim` posts the emulator's own guess, so no
test can see it. Whether the wire JSON matches the C# property names is not
established by a metadata dump, so this is a thing to confirm, not to assert.

Two things in that model matter enormously to this pillar and are worth naming
even though nothing here reads them yet:

* **`LocationTransit`** (`:9889`) carries `Location`, `SptExitName`,
  `SptLastVisitedLocation`, `TransitionRaidId`, and per-profile entries. And
  `Transition` (`:10199`) carries `VisitedLocations`, `TransitionCount`,
  `TransitionType`, riding on both `StartLocalRaidRequestData` and its response.
  **The game has its own first-class notion of a chain of maps in one run.**
  That is the "all maps connected" pillar's foundation and it is also this
  pillar's boundary #2 (2.5) — a transit is a save point the game already tells
  the server about.
* **`StartLocalRaidResponseData.LocationLoot : LocationBase`** (`:10154`) and
  **`StartLocalRaidRequestData.ShouldSkipLootGeneration`** (`:10146`). The SPT 4.x
  server delivers the map's loot in the **`/client/match/local/start` response**.
  `onMatchStart` (`tarkov.nim:996`) sends `serverId`, `serverSettings`, `status`
  and `notifier`, and no loot at all.

  **Open question, and it gates section 2.4 entirely:** does the post-1.0 client
  take its floor from `/client/location/getLocalloot`, from
  `match/local/start`'s `LocationLoot`, or from both? If it is the latter, the
  seed hook in 1.3 is in the wrong place and the world cannot seed a map until
  `onMatchStart` learns to answer with one. I have not established which. Nobody
  here can, without a client.

### 3.3 `mods/pathtotarkov` — what the connected-map pillar already proved

Worth reading before designing anything map-shaped. It writes
`locations.<key>.base.Locked` off BSG's own `transits` array — 19 maps, 38
transits on `build/db/db.json`, all 38 resolving — and never invents an edge. Its
own honesty note is the model for this document: "**That the client honours
`Locked` is an argument from the database, not an observation.**"

It also has the defect this pillar must not copy: its pending raid is a single
slot (`ptt/state.nim:88`), as is the emulator's `gRaidId` (`tarkov.nim:88`). For
one player that is fine and it is written down as a limit rather than as a
design. A world that assumes it will only ever have one raid in flight should say
so in the same words.

### 3.4 Refusals — things this pillar will not do

* **It will not claim a client type name it has not resolved.** Not
  `EFT.GameWorld`, not a container class, not a door. 3.1.
* **It will not put world state in the profile document.** The client deletes it
  once per raid. 2.1.
* **It will not commit on an interaction path.** 2.5.
* **It will not mint an id for an authored entity.** 2.3.
* **It will not create store keys per entity.** There is no delete. 2.4.
* **It will not treat an unreadable shard as an absent one.** A world that reads
  "cannot read `world.w1.map.bigmap.a`" and starts a fresh Customs has just
  destroyed a playthrough by the exact mechanism `emu/store.nim` was written to
  stop. `Stored.missing` is the distinction and there is no excuse for not using
  it.
* **It will not add a lock to the mod API.** `emu/profile.nim:406-413`: "a mod
  holding a lock across a request is a mod that can stop the server."

---

## 4. What would have to be built first

In order. Each is a prerequisite for something above, not a nice-to-have.

**4.1 A decision about deleting store keys.** The ABI has no delete
(`abi/aowlspt_abi.h:445-447`). Either add `store_del` at revision 6, or write
down that keys are permanent and design every layout around it. The world's
shard layout (2.4) is already shaped by assuming the second. This is small, it
is the owner's, and everything downstream depends on which way it goes.
*Note the constraint `docs/API-GAPS.md` records about revision bumps: the
simulator cannot claim revision 6 without first claiming revision 5, which
would make `notifyReady()` answer true in the sim.*

**4.2 A dump of the post-1.0 client's IL2CPP type surface.** `il2cppprobe`
already loads `GameAssembly.dll` and reports 242 exported runtime functions;
`il2cpp_class_from_name` and friends are there. What does not exist is the
equivalent of `reference/spt-4.1-surface.txt` **for the client**. Without it,
every sentence about reading world state is a guess, and this document refuses
to write those sentences. This is the single largest unknown in the pillar.

**4.3 An answer to "where does the client get the map's floor from".** 3.2. It
decides whether the seed hook in `emu/raid.localLoot` is sufficient or whether
`onMatchStart` has to grow a `LocationLoot`. Answerable only against a client.

**4.4 The seed made a parameter.** `localLoot(locationId, nowSeconds, raidId)`
→ take the seed from the world shard rather than from `gRaidId`. One argument,
in `emu/raid.nim:235` and `emu/loot.nim:1062`. It is the smallest change in this
document and the one everything in 2.4 stands on. It can be done and tested
today, against the fixture, with no client.

**4.5 A world-clock.** Every TTL in 2.6 needs one, and `now_ms` is *monotonic
milliseconds since host start* (`abi/aowlspt_abi.h:426`) — the exact trap that
produced the id-collision bug in `emu/ids.nim`. The emulator has `nowSeconds()`;
establish what it is and whether it survives a restart before any expiry rule is
written against it. I have not checked this and it should be checked before 2.6
is implemented.

**4.6 Per-profile serialisation in `backend/`, or a written-down single-writer
discipline.** `emu/profile.nim:414-418` already asks for this for the profile.
The world has the same requirement. Until it exists, boundary #4 of 2.5 should
not exist either.

**4.7 Confirmation that loose-loot spawn points carry stable authored ids.**
2.3. Grep `build/db/db.json` — `docs/EMULATOR-REFUSALS.md` is emphatic that six
claimed blockers did not survive that grep, and this may be a seventh. I did not
run it.

---

## Appendix — what in the brief turned out to be false or imprecise

* **"a complete game/world/session system … bots/etc are exactly where you log
  off at"** — the bots part is not reachable from the server, and may not be
  reachable at all. 3.1. What *is* reachable is bots that are the same bots,
  spawned by the server through `/client/game/bot/generate`, with persistent
  identity and inventory — not bots standing where they stood.
* **"there is no BepInEx or Harmony; client-side reach is via native detours and
  the IL2CPP API only"** — correct, and understated in one direction and
  overstated in another. The reach is better than the brief implies: typed
  patches at 23–37 ns, `this` as a pointer, postfix result replacement. And it
  is worse: there is no client type dump, so nothing is known about *what* to
  detour. 3.1, 4.2.
* **"physical chests instead of a stash/hideout"** — the placement machinery for
  the *contents* already exists and is reusable (`emu/grid.findSpace` /
  `markOccupied`, `emu/loot.containerGrids` / `packInto`). Note that these are
  two separate implementations of the same problem, deliberately, and
  `emu/loot.nim:36-42` says why and what closing the duplication would take.
* **`mods/tarkov/emu/` "the emulator — especially `raid.nim`, `loot.nim`,
  `inventory.nim`, `profile.nim`, `grid.nim`"** — accurate, and incomplete for
  this pillar. `emu/ids.nim` (1.2), `emu/store.nim` (1.1) and `emu/sessions.nim`
  (2.2) turned out to matter more to the persistence model than `inventory.nim`
  did.
* **`backend/jsondb.nim`'s `dbPatchPath` / `dbKeys` as a place to put world
  state** — the brief implies these are a candidate. They are not. The database
  is the *shared game database*, loaded from `db.json`, and `abi/aowlspt_abi.h:431`
  is explicit that the store is per-mod and durable while `db_get`/`db_patch`
  address the shared database. Patching a world into it would put a player's save
  in a file the importer regenerates. `dbKeys` is nonetheless directly useful to
  this pillar for enumerating maps without the 12.5 MB read
  (`aowl/src/aowlspt/server.nim:337`, and note `dbKeysReady()` answers **false**
  on the client host and the simulator).
* **"the profile is committed on every inventory drag" as an open decision** —
  still true and still open (`docs/BACKLOG.md`, G1), but the numbers in the brief's
  framing are stale: the 2026-08-19 work took `store_set` 718 → 476 µs and
  `items/moving` 1.17 → 0.90 ms by dropping `MOVEFILE_WRITE_THROUGH`, without
  touching the decision.
