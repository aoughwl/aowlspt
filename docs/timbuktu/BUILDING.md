# Building, and physical storage

The pillar: replace the stash and the hideout with **containers that are real
objects at real places**, and answer whether a **building system** is possible
at all on a post-1.0 client.

The short answer to the second question is in [The verdict](#the-verdict). Read
it before reading anything else, because most of the rest of this file is about
what to do instead.

Nothing in this repository has ever run against BSG's client. That sentence is
in [IL2CPP.md](../IL2CPP.md), [API-GAPS.md](../API-GAPS.md) and
`mods/morebots/bots/instance.nim`, and it governs every client-side claim
below. Where something here is a hypothesis rather than a fact it is marked
**unverified** and named as a probe.

---

## What exists today

### The stash is already an item, not a menu

This is the single most encouraging fact in the survey, and it contradicts the
usual framing of "replace the stash".

`mods/tarkov/emu/profile.nim:200-220` creates five root container items in
`Inventory.items`, each of them nothing but `{_id, _tpl}` with **no
`parentId`**: equipment, stash, quest raid items, quest stash, sorting table.
`Inventory.stash` (`stashId*`, profile.nim:64) holds the `_id` of one of them.
`StandardStash = "5811ce572459770cba1a34ea"` (profile.nim:36) is a template id
like any other.

`mods/tarkov/emu/inventory.nim` knows nothing about any of this. A container
there is "an item that other items name in `parentId`" and nothing else — no
list of root ids, no special cases. `isRootContainer*` (inventory.nim:146-165)
defines root as *empty `parentId`*, structurally. Every operation —
`doMove*` (:197), `doSplit*` (:231), `doMerge*` (:267), `doTransfer*` (:405),
`doRemove*` (:296/:317), `doSwap*` (:367), `doApplyChanges*` (:480) — is
generic over the tree.

**So "chests instead of a stash" is a data change, not a rewrite.** A chest is
another root container item. The inventory engine already handles it.

### The hideout models much less than its name suggests

`mods/tarkov/emu/hideout.nim` has **no type for the hideout**. State is a JSON
array at `Hideout.Areas`, and one area is exactly `{type, level, active,
passiveBonusesEnabled, completeTime, constructing, slots, lastRecipe}`
(`newArea`, hideout.nim:106-115). Areas are found by linear scan on the integer
`type` (`findArea`, :100-104). Costs, durations and bonuses are never stored —
they are read from the database table `hideout.areas` on demand
(`upgradeSeconds*` :117, `stageRequirements*` :133, `areaGate*` :182).

Slots are not item storage: `haPutItems`/`haTakeItems` (:298-303) overwrite the
area's `slots` array verbatim from the request and move no items; the actual
movement rides along as ordinary inventory actions in the same batch. Bonuses
live in `emu/production` (`bonusesForStage` :1199, `syncBonuses*` :1214).

`Inventory.hideoutAreaStashes` exists on the profile (profile.nim:248) and
**nothing in the emulator reads or writes it**. SPT's own model has it
(`reference/spt-4.1-surface.txt:4278`, `Dictionary<String, MongoId>`) — an area
mapped to a container item id. It is a declared, dead hook.

**Deleting the hideout costs almost nothing.** There is no geometry, no items,
no per-area inventory. What would be lost is crafting, and crafting is
`emu/production`, which is a separate 1482-line module driven by
`resolveRequirements*` (production.nim:564) over seven requirement kinds. That
survives a hideout deletion intact if it is re-pointed at something other than
an area number.

### Container grid geometry is generic, and duplicated three times

`mods/tarkov/emu/grid.nim` is 143 lines of 2-D integer cell arithmetic:
`Grid` (`width`, `height`, private `cells: seq[bool]`, :30-33), `Placement`
(:35-39), `newGrid*` (:41), `occupy*` (:60), private `fits` (:70),
`markOccupied*` (:83), `findSpace*` (:108, first-fit top-left, upright pass then
rotated), `locationJson*` (:138).

`stashGrid*(stashTpl: string)` (:48-58) is named for the stash but is not
stash-specific: it reads `templates.items.<tpl>._props.Grids[0]._props.cellsH /
cellsV` for **any** template, falling back to 10x68. It only looks at
`Grids[0]`, so multi-grid containers are not covered.

That gap is why the same geometry exists twice more:

* `emu/bots.nim:421-468` — a `Container` object with `gridNames: seq[string]`
  and `grids: seq[Grid]`, plus `openContainer` and `placeIn`. Multi-grid, and
  it reuses `Grid`/`findSpace`/`occupy`.
* `emu/loot.nim:286-347, :690-718` — a private `Cells` clone. The comment at
  loot.nim:280-284 says outright that the only thing preventing reuse is that
  `findSpace` looks item sizes up itself, and asks for
  `findSpaceSized(g: Grid; w, h: int)` to be exported.

Existing stash-grid callers: `emu/trading.giveItem` (:243-244, :280),
`emu/market.buyOffer` (:1194-1196), `emu/redeem.place` (:103-109),
`emu/scav.bringHome` (:439-453). Each does `stashGrid` → `markOccupied` →
`findSpace` and refuses when full.

### The one place the server already handles world coordinates

`mods/tarkov/emu/loot.nim` is the only module in the emulator that touches a
world transform, and **it deliberately never reads one**.

`lootEntry(templateJson, rootId, itemsJson)` (loot.nim:734-748) builds one
element of the `Loot` array member-wise off the database's spawn-point
template, setting only `Root` and `Items`. Its docstring says why:

> The template carries `Position`, `Rotation`, `useGravity`,
> `IsGroupPosition` and several fields that differ between map versions, and a
> builder that names the ones this module knows about would drop the rest —
> which is an item spawning in the wrong place, or under the floor.

That array is served by `localLoot*` (`emu/raid.nim:235-269`) on
`/client/location/getLocalloot` (registered at `mods/tarkov/tarkov.nim:1573`,
handler `onLocalLoot` at :991), which calls `lootFor*(locationId, raidId)`
(loot.nim:1062) → `generateLoot*` (loot.nim:999), seeded by
`seededRng(raidId & "|" & locationId)` (:1009) so a raid's floor is
reproducible from its id.

The wire shape it is filling is `SpawnpointTemplate`
(`reference/spt-4.1-surface.txt:3879+`):

```
class SPTarkov.Server.Core.Models.Eft.Common.SpawnpointTemplate
    prop Nullable<Vector3> Position
    prop Nullable<Vector3> Rotation
    prop Nullable<Boolean> IsContainer
    prop Nullable<Boolean> IsAlwaysSpawn
    prop Nullable<Boolean> UseGravity
    prop Nullable<Boolean> RandomRotation
    prop IEnumerable<SptLootItem> Items
    prop String Root
    prop String Id
```

`SptLootItem : Item` — so `Items` is exactly the shape of `Inventory.items`, and
`Root` names the container item inside it. A spawn point is *addressed by its
own `Id`*: `forcedFor(forcedJson, containerId)` (loot.nim:760-776) keys the
items a specific crate always holds by spawn-point id, "because two crates of
the same kind on one map do not both hold the quest item".

**That is the whole mechanism this pillar needs.** It is not a mod hook. It is
the protocol.

Everything else spatial in the emulator is 2-D container-local cells, or paper
map markers in `emu/notes.nim:171-180` (`X`/`Y` floats on the `Map` item,
identified by their old coordinates, not world positions). There is no
`Vector3` type anywhere in `mods/tarkov`.

### The transit graph is present, empty, and free

`emu/raid.nim:174-189`: `locations.paths` is the map-to-map transit graph,
`{Source, Destination, Event}`, served on `/client/locations`. Nothing lands
there today — `aowl importdb` does not import it (:184-185) — so the graph is
always `[]`, and the constant at raid.nim:497 is a fixture.

For "all maps connected" this is the lever, and it costs an importer row and a
table.

### What the client host can reach

From [IL2CPP.md](../IL2CPP.md) and the sources:

| | |
|---|---|
| loader | native DLL injected by `aowlspt-launch`; no BepInEx, no CoreCLR, no proxy assemblies |
| metadata | encrypted; the host never reads `global-metadata.dat` and cannot start the runtime out of process (`il2cppprobe --init` → "il2cpp_init returned no domain") |
| reflection | `il2cpp_class_from_name`, `..._get_method_from_name`, `il2cpp_runtime_invoke`, `il2cpp_field_get_offset` — 62 entries in `EntryNames`, `aowl/src/aowlspt/il2cpp.nim:139-173` |
| construction | `il2cpp_object_new` **is** bound (`eObjectNew`) and **is** exported to mods as `objectNew*` (il2cpp.nim:477-479) |
| patching | x64 inline detour, `abi/aowlspt_detour.h`; 256 slots; relative branches in a prologue refused, RIP-relative relocated |
| the fast path | a mod binds `GameAssembly.dll` itself with `openIl2Cpp()` and calls compiled code directly (`aowl/src/aowlspt/fast.nim`) |
| HTTP to the backend | not in the ABI, but demonstrably possible in-process: the host polls `/aowlspt/mods/client/<ver>` on `backendPort` from the overlay's worker thread (`docs/MODMANAGER.md:216-220`) |

**The per-frame main-thread queue** is `bindMainDrain` in
`host/Aowlspt.Host.Il2Cpp/aowlhost.nim:2217`. What it actually guarantees,
precisely:

* It detours one of four candidates, in order —
  `EFT.MainApplication::Update`, `EFT.GameWorld::Update`,
  `UnityEngine.UI.CanvasUpdateRegistry::PerformUpdate`,
  `UnityEngine.Time::get_deltaTime` (aowlhost.nim:2273-2276) — and drains
  `invoke_main`'s queue from inside it.
* Whichever thread first reaches the detour claims the drain with an
  interlocked exchange; anyone else is counted and sent away. So callbacks are
  **serialised**, never concurrent.
* If none binds, the queue is drained by the host's own tick thread and the
  host **warns**. `invoke_main` still works; it is just not Unity's thread.
* `call("aowlspt.host::main_thread")` answers `{"bound":..., "method":...,
  "mainThreadId":..., "frames":..., "stalled":...}`, and `bound` is true **only
  once the hook has actually fired** — an installed hook that was never reached
  has proved nothing.

What it does **not** guarantee: that any of the four candidates exists on a
post-1.0 client, or that the one that binds is really the player loop's thread.
The docstring at aowlhost.nim:2231-2236 says the `EFT.MainApplication` name is
a pre-1.0 dump name that nobody who wrote the file has verified, "which is
exactly why this is a list and not a constant". IL2CPP.md closes the section:
"None of this has been seen against BSG's client."

**Everything client-side in this document sits on top of that unverified
drain.** If it does not bind, no mod may touch a Unity object at all, because
doing so from the wrong thread "throws or corrupts" (`docs/ABI.md:476-478`).

---

## The verdict

### Free-form building — the player authoring and placing new geometry — is not reachable with what exists today, and will not be reached by finishing anything currently in this tree.

Five separate walls, in the order you would hit them. Two are engineering, three
are permanent.

**1. New meshes need an asset bundle, and there is no bundle path.**
SPT has a bundle mechanism — `BundleCallbacks` (`reference:217-220`),
`BundleLoader` (`:1928-1933`), `BundleSerializer` (`:24880-24894`),
`BundleManifestEntry` (`:18379`) — but that is all *server* side. The half that
fetched and loaded a bundle into the client was a BepInEx plugin, and there is
no BepInEx post-1.0. This repo's emulator registers no bundle route at all
(`mods/tarkov/tarkov.nim:1522-1645`). Whether
`UnityEngine.AssetBundle::LoadFromFile` even survives into this build's
metadata is **unverified** — it is a probe, and a positive result would still
leave you needing the exact Unity version and shader set, neither of which is
recorded anywhere in this tree. Engineering, but large and speculative.

**2. Instantiating an existing prefab has no prefab to instantiate.**
`objectNew*` exists, so managed allocation is reachable — note that
`mods/morebots/bots/instance.nim:114` says "`il2cpp_object_new` is resolved by
the loader but is not exposed to a mod", which is true of the *host ABI* and
**false of the nimony library**, where `objectNew*` is public. But
`il2cpp_object_new` on a `UnityEngine.Object` gives a managed shell with no
native object behind it; you need `.ctor`, and for a prefab you need a
*reference to the prefab*. Tarkov loads its content through Addressables, not
`Resources`, so there is no name-to-asset call to make. The only prefab
references reachable are ones already alive in the scene — which means you can
duplicate what the level happens to contain, and nothing else. Permanent,
absent a bundle path.

**3. Nothing native can declare a C# type.** `mods/morebots/morebots.nim:181-186`
already had to write this down for a different feature: "IL2CPP has no runtime
type definition… Nothing native can declare a C# class." A building system
whose pieces have behaviour — a door that opens, a generator that runs, a
container that saves — wants a `MonoBehaviour`, and a `MonoBehaviour` is a new
type. You can only ever attach components the game already compiled. Permanent.

**4. Bots will walk through anything you place.** NavMesh is baked into the
level. Runtime carving needs `NavMeshObstacle` / the NavMeshComponents package,
whose presence in this build is **unverified**, and even a positive result
covers obstacles, not new walkable surfaces. A base whose walls the AI ignores
is not a base. Permanent for practical purposes.

**5. Nothing a client mod creates survives the raid.** The only raid-end payload
is `EndLocalRaidRequestData` (`reference:9766`): `ServerId`, `Results`,
`LocationTransit`, `LostInsuredItems`, `TransferItems`. There is no route by
which the client reports world state, and `onMatchEnd`
(`mods/tarkov/tarkov.nim:1016-1031`) reads exactly one thing from the body —
`field(body, "profile")`. So even a successfully spawned object must be
re-created from server data on every raid load, which means the *server* has to
own the description anyway. Permanent.

Wall 5 is the one that decides the architecture, because it says: **whatever
the answer is, the server must be able to state the whole world from scratch at
every raid load.** And once that is true, walls 1–4 stop mattering for the
subset that the server *can* state.

### What is reachable, and it is more than it sounds

The server can already place an arbitrary set of **items** at arbitrary world
transforms, with arbitrary contents, on any map, with zero code in the client
process — by writing entries into the `Loot` array that `localLoot*` serves.
The client instantiates them, gives them their own colliders, settles them with
`UseGravity`, renders them, and lets the player open the ones that are
containers. All of that is the game's own loot system doing what it does every
raid.

So the honest headline for the owner:

> **You cannot build walls. You can place things — any thing the game has an
> item model for, anywhere, in any orientation, holding anything, persistently.
> The building system is a placement system over the item catalogue.**

Crates, safes, weapon boxes, jackets, medbags, sacks, ammo boxes, tents where
the catalogue has one, barrels, corpses' gear. Not floors, not doors, not
rooms, not walls.

Whether that is the game the owner wants is not a technical question. It is
[decision 2](#decisions-that-are-genuinely-the-owners).

### One correction to the "what can it reach" folklore

Positioning is *expressible*, and half of it is shipped code — this matters if
anyone later argues the client branch is blocked on calling conventions. It is
not.

* Through the **host ABI's `call`** a `Vector3` is refused.
  `bindArgs` (`host/Aowlspt.Host.Il2Cpp/invoke.nim:295-383`) builds a value-type
  argument only from a JSON number and only up to eight bytes — "this host can
  build one of at most 8 bytes from a number" — and a `Vector3` is twelve, so
  it falls to the final refusal, "which this host cannot build from a JSON
  scalar. Resolve it to a handle and pass `#n`" — and there is no handle to a
  value type (invoke.nim:1058). So `Transform::set_position` is unreachable from
  `call`.
* Through the **fast path** it is reachable. Win64 passes anything larger than
  eight bytes and not a power of two by hidden pointer, so
  `void set_position(Vector3)` compiles to a pointer slot.
  `bindRaw`/`ShapedArgs` (`aowl/src/aowlspt/fast.nim:791-891`) states that shape
  outright, and it is already used for the read direction in
  `mods/blackdivision/bd/watch.nim:404` and `examples/lesson/lesson.nim:1403`.

The client branch is blocked on *what to position* and *whether it persists*,
not on how to say a coordinate.

---

## Physical containers

The design. This is what to build, and it needs no client mod.

### Identity

A chest is `(map, spawnId)`.

`spawnId` is the spawn point's own `Id`, which is already the unit of address
in the loot pipeline — `forcedFor` (loot.nim:760-776) keys per-crate content by
it precisely because two crates of one kind on one map must be distinguishable.
`map` is the canonical database key (`canonicalLocation*`, raid.nim:206), not
the `_Id`, because the loot tables are keyed that way.

Store key: `chest.<map>.<spawnId>`. That is legal under the store's flat-key
rule today (`[A-Za-z0-9._-]`, `docs/ABI.md:263-266`), and `store_list(prefix)`
enumerates a map's chests without the mod knowing where the host put them.

Chests placed by the player get a server-minted id (`newId()`, as
`onMatchStart` uses at tarkov.nim:1010) and are stored the same way. There is no
distinction in the record between a chest the level shipped with and a chest the
player put down; only the `origin` field differs, and that is for the fiction.

### Placement

`position: {x,y,z}`, `rotation: {x,y,z}`, `useGravity: bool`, written into the
spawn-point template the server emits. The server never interprets them — that
is `lootEntry`'s existing contract (loot.nim:738-742) and it should stay.

Where a *player-placed* chest's coordinates come from is the one place a client
mod earns its keep cheaply, and it is a read, not a write: the player's position
and facing at the moment they place. Reading a `Vector3` off the game is
existing, working code — `mods/blackdivision/bd/watch.nim:355-404` binds
`get_Position` with `bindRaw` and reads it every frame. The mod POSTs
`{map, position, rotation, tpl}` to the backend; the chest appears **next**
raid load. That is a real limitation and should be surfaced in the fiction
("you set it down; it settles"), not hidden.

Without any client mod at all, chests can only be placed at coordinates the
server already knows — which is every existing static container spawn point on
every map, and there are hundreds. That is a perfectly good v1.

### Contents

`items: Item[]` plus `rootId: string` — byte-identical in shape to
`Inventory.items` and to `SpawnpointTemplate.Items`.

This is the payoff of the survey: `emu/inventory` is generic over the tree, so
every operation it already implements works on a chest's item array with no
change. `doMove*`, `doSplit*`, `doMerge*`, `doTransfer*`, `wouldCycle*`,
`descendantsOf*` — all of them address items by `_id` in a flat array and know
nothing about stashes.

### Grid geometry

Reuse `emu/grid`, and close the two gaps it already has open tickets for:

1. **Export `findSpaceSized(g: Grid; w, h: int)`.** loot.nim:280-284 asks for
   this by name and maintains a private `Cells` clone only because it is
   missing.
2. **Promote multi-grid support.** `emu/bots.nim:421-468`'s `Container`
   (`gridNames: seq[string]`, `grids: seq[Grid]`, `openContainer`, `placeIn`)
   is the correct shape and is already written; move it into `grid.nim` and
   delete loot.nim's `Cells`. A weapon crate has several grids and
   `stashGrid*` only reads `Grids[0]` (grid.nim:48-58).

After that, `stashGrid*` should be renamed — it is not stash-specific, it
resolves grids for any template id, and the name is the only thing suggesting
otherwise.

### Ownership

A field on the server record — `owner: string` (a profile id, a faction name,
or empty for the level's own crates) — that is **never sent to the client**.
The client has no concept of an owned container and no way to render one
differently without an unverified UI hook.

Ownership therefore decides only two things, both server-side: whether the
server accepts a deposit into it, and whether it is eligible for NPC raiding.

### Can NPCs loot them

**Modelled, not simulated, and the document should say so where players can
read it.**

Bots are generated server-side (`/client/game/bot/generate`, `onBotGenerate` at
tarkov.nim:1201, `emu/bots.nim`) but their behaviour inside a raid is entirely
the client's, and there is no way to tell a bot to walk to a crate. What the
server *can* do is decide, on the next read of a chest record, that time passed
and a faction took something.

The pattern to copy is `tickHideout*` (`emu/production.nim:1356-1402`), driven
off `Hideout.sptUpdateLastRunTimestamp` and called from tarkov.nim:134 on every
request: elapsed time is evaluated lazily on read, not by a timer. A
`tickChest(record, nowSeconds)` in the same shape gives you decay, faction
raids, and rot, for free, on a server that may have been switched off for a
week.

That is honest and it is also better: a dice roll that runs while the player is
on another map is a *persistent world*, where an NPC pathing to a crate the
player cannot see is a simulation nobody observes.

### Persistence — what this pillar needs from `PERSISTENCE.md`

`docs/timbuktu/` is empty as this is written; nothing here depends on decisions
already made there. This is the requirement list, not a design.

1. **A record store addressable by `(map, spawnId)`, with enumeration by map.**
   The per-mod store's `store_list(prefix)` (ABI revision 2, `docs/ABI.md:255`)
   already has the right shape if keys stay flat.
2. **Atomic multi-record commit.** This is the one hard requirement and the one
   the per-mod store does not obviously give. At a raid boundary the player's
   profile and one or more chest records must land **together**. A profile that
   saved and a chest that did not is item duplication; the reverse is item
   loss. If the persistence engine cannot commit a set, this pillar has to
   serialise everything a raid touches into one record, which is ugly and
   should be a last resort.
3. **Read-modify-write under a lock for the length of a reconciliation.** The
   backend already holds a lock per session (`docs/ARCHITECTURE.md:274`); the
   question is whether chest records can join that scope.
4. **A monotonic `lastTickedAt` per record**, so lazy offline evaluation is
   idempotent and a server restart does not run a week of decay twice.
5. **Crash safety mid-write** (`docs/BACKEND.md:325`, "What survives a crash").
   A chest whose record was half-written is worse than one that reverted.
6. **A version or generation on each record**, so a raid-end reconciliation can
   refuse to apply against a record that changed underneath it.

---

## Free-form building, or why not

Covered in [the verdict](#the-verdict). The residue worth writing down is what
the *degraded* forms buy, so nobody re-derives them later:

| idea | reachable? | what it actually gets you |
|---|---|---|
| Place existing container items at authored transforms | **yes, today** | the whole storage pillar. Server-side JSON |
| Place any non-container item as scenery | **yes, today** | barricades made of crates and barrels. Cosmetic only; no collision guarantees beyond the item's own |
| Edit `locations.<map>.base` before serving it | **partly** — `locationBase*` (raid.nim:222) serves it verbatim from the DB, so anything in it is editable | unverified what the base carries post-1.0. Probe: does it define doors, extract volumes, or spawn zones the client honours |
| Edit `SpawnPointParam` (`reference:3879`) | **yes** | move where the player and bots enter a map. Free "your base is where you spawn" |
| Fill `locations.paths` (raid.nim:174-189) | **yes**, one importer row | all maps connected — the transit graph the client already reads |
| Spawn a `GameObject` from a client mod | **unverified, and pointless** | it does not persist (wall 5), bots ignore it (wall 4), and you can only clone what the scene already has (wall 2) |
| Load a custom asset bundle | **no path exists**; unverified whether one could be made | new geometry. This is the only route to real building, and it is a research project, not a task |

---

## The hard questions, answered flatly

**What is a "placed object" at the client?**
One element of the `Loot` array on the `/client/location/getLocalloot`
response, materialised once during raid load into a scene object the client
owns for the raid's duration and destroys at raid end. The client has no idea it
is persistent.

**What is it at the server?**
A record: `{map, spawnId, tpl, position, rotation, useGravity, rootId, items[],
owner, origin, lastTickedAt, generation}`. Never rendered, never simulated.

**How do the two stay agreed?**
**They do not, during a raid, and cannot.** The server declares the entire world
once at raid load and hears nothing more until raid end, and what it hears then
is only the player's profile (`onMatchEnd`, tarkov.nim:1026-1031). There is
exactly one sync point per raid and it is one-way.

This is the load-bearing sentence of the pillar. Every mechanic must be built so
that a raid boundary is a sufficient sync point, or it must not be built.

**Then how does anything get *into* a chest?**
Three options, and the first is the only one that works today:

1. **Deposit at the boundary.** Chests are read-only in-world: you take from
   them, you cannot give. Depositing happens as you leave or transit — the
   raid-end profile is authoritative, the server moves designated items out of
   it and into the chest record, and both land in one commit (requirement 2
   above). Zero client code, zero unverified hooks. Fictionally: you cache at
   the boundary, not mid-firefight. **Ship this first.**
2. **A client mod reports the deposit mid-raid.** Hook whatever handles "item
   moved into a lootable container" and POST it to the backend. Architecturally
   possible — the client process already speaks HTTP to `backendPort`
   (`docs/MODMANAGER.md:216-220`) — and every part of it that touches the game
   is a pre-1.0 name nobody here can check.
   `mods/morebots/bots/instance.nim:96-99` is this repo's own statement of the
   problem: "a type name is not an identity… every such member name is a
   pre-1.0 hypothesis that nothing in this tree can check."
3. **Hijack an existing round trip.** `/client/game/keepalive` is served
   (tarkov.nim:1525). Whether the client calls it during a raid is
   **unverified**. A probe, not a plan.

**What happens when the player is not on that map?**
Nothing runs, and nothing needs to. A chest's state advances by elapsed time
evaluated on the next read — the `tickHideout*` pattern
(production.nim:1356-1402). One map is loaded at a time and the server is often
not running at all, so any design requiring a live world tick is wrong for this
project regardless of anything else here.

**Collision and physics?**
Free, and this is the strongest argument for the spawn-point route over
spawning GameObjects: the client's own loot system instantiates the item with
its own collider and settles it with `UseGravity`, which the server forwards
untouched (loot.nim:738-742). You get colliders you never wrote and never have
to keep working across a game patch. What you do **not** get is NavMesh: a crate
is not an obstacle bots path around, in vanilla either.

**Server-authoritative or client-visual?**

| | |
|---|---|
| a chest exists, and where | **100% server**, declared per raid load |
| what is in it | **100% server**, declared per raid load |
| what happens to it in a raid | **100% client, and completely unobserved** |
| what the server believes afterwards | whatever it declared, plus the raid-end profile diff |

There is no middle. Anything that needs the middle needs option 2 above and
therefore needs a probe run against the real client.

---

## Open questions

Every one of these is a probe against BSG's client, and none can be answered in
this tree.

1. **Does the main-thread drain bind at all?** Four candidates,
   aowlhost.nim:2273-2276, none ever tried against the real client. If none
   binds, every client-side option in this document is off the table. *This is
   the first thing to run.* Read `aowlspt-host.log` and
   `call("aowlspt.host::main_thread")`.
2. **Does the client honour a `Loot` entry at an arbitrary `Position`, or does
   it validate against the level's own spawn-point set?** The whole design
   rests on the first answer. Cheap to test: move one existing entry ten metres
   and see where it lands.
3. **Does `IsContainer: true` on a spawn point whose `Root` is a container
   template produce a lootable object, or does the client only render loose
   items?** Static containers already work this way in vanilla, so this is
   expected to pass — but expected is not verified.
4. **Does the client re-request `/client/location/getLocalloot` on transit, or
   only on a cold raid start?** Decides whether a transit is a sync point.
5. **What is in `locations.<map>.base` post-1.0**, and does the client honour
   edits to it?
6. **Does the client call any route during a raid?** Determines whether option
   2/3 above has a channel at all.
7. **Is `UnityEngine.AssetBundle` in this build's metadata?** One
   `findClass` call. A negative closes the building question permanently; a
   positive opens a research project.

---

## What would have to be built first

In order. Nothing after step 2 is worth starting before step 1 comes back.

1. **The probe run.** `aowlspt-launch --root D:\Aowlspt`, read the log, answer
   open questions 1, 2 and 3. This is one session and it decides the shape of
   everything else.
2. **Server-side, and independent of the probe** — all of this is useful even
   if every client answer comes back bad:
   * `findSpaceSized*` exported from `emu/grid`; loot.nim's private `Cells`
     deleted (loot.nim:280-284 asks for this).
   * `Container` promoted from `emu/bots.nim:421-468` into `emu/grid.nim`;
     `stashGrid*` renamed to something that is not a lie.
   * An importer row for `locations.paths`, so the transit graph is non-empty
     (raid.nim:184-185).
3. **The chest record and its store.** Blocked on `PERSISTENCE.md` answering
   requirement 2 (atomic multi-record commit). Everything else in the
   requirement list is satisfiable with the ABI store as it stands.
4. **The chest → `Loot` emitter.** A pass in `generateLoot*` (loot.nim:999)
   that appends chest records for the map after the generated loot, using
   `lootEntry` unchanged. Small, and it is the moment the pillar becomes real.
5. **Raid-end reconciliation.** Extend `onMatchEnd` (tarkov.nim:1016) to move
   designated items out of the returned profile into chest records, in one
   commit with the profile save. Note that this is the one place the emulator
   already warns about: "it is also the one place a mistake costs a player
   their stash, so the body is checked before it replaces anything"
   (tarkov.nim:1019-1020).
6. **Retire the hideout.** Cheap once chests exist: `Hideout.Areas` is
   `{type, level, active, slots}` integers (hideout.nim:106-115) with no items
   and no geometry. Re-point `emu/production`'s `resolveRequirements*`
   (production.nim:564) `Area` requirement kind at something other than an area
   number, and the rest falls away.
7. **Player placement**, only if probe question 1 and 2 pass: a client mod that
   reads position and facing with `bindRaw` (the read direction already works —
   `mods/blackdivision/bd/watch.nim:404`) and POSTs a placement to the backend.
   The chest appears next raid load.

---

## Decisions that are genuinely the owner's

1. **Is "read-only in-world chests, deposit at the raid boundary" acceptable?**
   If yes, this pillar ships with no client mod and no unverified anything. If
   no, it depends on hooking a method whose name nobody in this tree can check,
   and the schedule becomes unbounded. This is the biggest single decision in
   the pillar.

2. **Is "building = placing things from the item catalogue" the game?** You get
   crates, safes, boxes, sacks, barrels, tents where one exists — placed
   anywhere, holding anything, persistently, with real collision. You do not get
   walls, floors, doors or rooms, and no amount of work in this tree changes
   that. If the pitch was walls-and-rooms, the honest answer is no, and it is
   better heard now.

3. **Is a chest raided while you were away a dice roll?** Cheap and honest, and
   it is the only form NPC interaction with storage can take. The alternative is
   that chests are inviolable, which is also fine and is less work.

4. **Is the probe run worth a session?** Everything client-side is a hypothesis
   until it happens, and three of the seven open questions are answered by one
   launch and one log.

---

## Where this brief was wrong

Recorded because the repo's rule is that a document must not carry a claim it
has not checked, and that cuts both ways.

* **"physical chests instead of a stash"** implies the stash is a menu
  construct that must be replaced. It is not — it is a root item in
  `Inventory.items` (profile.nim:200-220) and `emu/inventory` is already fully
  generic over containers. The work is smaller than the framing suggests.

* **"instead of a hideout"** implies the hideout is a substantial system. It
  models `{type, level, active, slots}` integers per area with no items and no
  geometry (hideout.nim:106-115), stores no bonuses, and
  `Inventory.hideoutAreaStashes` (profile.nim:248) is declared and dead. What is
  substantial is crafting (`emu/production`, 1482 lines), which is separable.

* **"this repo already has a per-frame main-thread queue — say what it
  guarantees"** presumes the queue is on Unity's thread. It guarantees only
  that *some* thread drains it serially and that the host will tell you which
  (aowlhost.nim:2217, `mainThreadReport` at :1055). None of the four candidates
  has ever been tried against BSG's client.

* **`mods/morebots/bots/instance.nim:114`** says "`il2cpp_object_new` is
  resolved by the loader but is not exposed to a mod". That is true of the host
  ABI and **false of the nimony library**: `objectNew*` is public at
  `aowl/src/aowlspt/il2cpp.nim:477`, and a mod holds its own runtime through
  `openIl2Cpp()`. The conclusion that file draws is still right for its own
  case — instantiation was never what a brain swap needed — but the sentence as
  written would mislead someone reading it for this pillar.

* **`docs/timbuktu/PERSISTENCE.md` does not exist yet.** Nothing above depends
  on it; the requirement list is stated so it can be checked against whatever
  is written there.
