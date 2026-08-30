# The Unity map pipeline — two efforts, reconciled

Two independent efforts in this repo both touch "get EFT maps out of the game".
They are **not** rivals and neither supersedes the other. This document says what
each actually produces, which one to run first, and where the honest limits are.

Run instructions for Effort A live in **`docs/UNITY_MAP_IMPORT.md`** and are not
repeated here.

*Status of the claims below: `measured` = read out of the source in this repo
during this reconciliation. `relayed` = a prior session's measurement, taken on
trust and labelled. `inferred` = reasoning, not measurement. Nobody has run the
Effort A importer end to end; nothing here asserts that it works.*

---

## TL;DR — what to run tonight

**Run Effort A. Only Effort A.**

`tools/unity_import/rip_maps.ps1`, then the Unity menu
*Aowlspt → Import + Unify World (grid)*. That is the only path in this repo that
ends with **all maps, in one Unity scene, with textures, one click**, which is the
stated goal.

Effort B produces **no Unity scene and no texture**. It is a data-recovery track.
It becomes valuable *after* A has produced a project — it is the fix for A's
biggest documented hole — but it does nothing for tonight's click.

---

## Effort A — AssetRipper → one unified Unity scene

Branch `unity-map-import` @ `827e895`. Files: `tools/unity_import/rip_maps.ps1`,
`tools/unity_import/Editor/AowlEftMapImporter.cs`, `docs/UNITY_MAP_IMPORT.md`.

Gives you: a real, loadable Unity 2022.3.43f2 project — meshes, materials,
**texture assets on disk**, scene files, prefabs — plus an Editor menu that opens
every map's sub-scenes additively, groups each map under `AowlWorld/<Map>`,
bounds-packs the footprints into a non-overlapping grid, and re-checks for overlap
afterwards.

Does not give you: BSG shaders (materials fall back to Standard) or **any BSG
MonoBehaviour data** — scripts come through as empty stubs. Both are stated in
`docs/UNITY_MAP_IMPORT.md`.

Relayed measurements: Unity 2022.3.43f2; 480 location scenes across 18 map
folders.

---

## Effort B — what it *actually* produces today

Branch `feat-monobehaviour-extract` @ `6748225`. Four tools, three distinct
outputs. All of it is **JSON and C# text files**; none of it is a Unity project,
a scene, or an image. (measured — read the emitters directly.)

### `tools/mapextract.py` — glTF + hierarchy sidecar

Subcommands `inventory` / `scan` / `extract MAP` / `verify MAP`. Per scene it
writes, under `D:\MapExtract\<map>\`:

| file | contents |
|---|---|
| `<scene>.gltf` + `.bin` | decoded meshes, node tree, per-submesh material indices |
| `<scene>.hierarchy.json` | full transform tree: name, active, layer, tag, **local** T/R/S, plus a whitelist of component entries |
| `<scene>.manifest.json` | source-side counts for `verify` to re-derive independently |
| `_map.json` | which scenes make the map, from the preset |

The component whitelist is `MeshFilter / MeshRenderer / SkinnedMeshRenderer /
MeshCollider / Box|Sphere|CapsuleCollider / LODGroup`. Materials are recorded by
**name and texture name only** — `resolve_material()` reads `m_TexEnvs` and stores
`{slot, ref, name}`. **No image bytes are ever written.** (measured: there is no
Texture2D decode, no PNG/DDS writer, and no image path in the file.) So the glTF
references textures that do not exist on disk.

This overlaps A's geometry job but is strictly weaker for the user's goal: no
texture pixels, no Unity project, no scene, glTF instead of `.unity`.

### `tools/mapextract_mono.py` — the part A cannot do

Writes a **sibling** `<scene>.mono.json` (deliberately not an edit to the
hierarchy sidecar). Every MonoBehaviour in the scene appears, with
`pathId`, `gameObject`, **`path`** (the GameObject path — the join key back to
`hierarchy.json`), `enabled`, `type`, `assembly`, and either
`"status": "DECODED"` with a full **`fields`** object, or `"status":
"UNRESOLVED"` with type name, payload length and a reason. Plus a per-type census.
(measured.)

A decode is accepted only if it consumes the payload to the last byte **and**
re-serialises to identical bytes. That is a check that can fail — §9b-clean.

Relayed: 292,316 of 296,708 MonoBehaviours across Woods and Factory round-trip
byte-exactly (98.5%); Factory 38,770/41,051 (94.4%), Woods 253,546/255,657
(99.2%); 4,392 unresolved, each recorded rather than dropped. **Not re-verified
here** — that needs the Store Python, UnityPy and the decrypted metadata blob.

### `tools/monotree.py` — the layout engine

804 lines. Rebuilds each script's Unity serialisation layout from the decrypted
il2cpp metadata, because the level files ship with type trees stripped. Not run
directly; `mapextract_mono` and `monostub` both sit on it.

### `tools/monostub.py` — the bridge back into Unity

Emits **compilable C# stub classes** from the serialisation layout (declaration
order, `[SerializeField]` restored on non-public fields, `[Serializable]` on
nested value types), so a Unity project's `Assembly-CSharp` contains a class Unity
will bind the serialised data to. `gen --type ...` for named types; **`from-mono
<dir> --out <dir>`** for every type in a directory of `.mono.json` files. A type
it could not lay out is reported, never emitted as an empty class. (measured.)

This exists specifically to put recovered component data back into a Unity
project. It is the fusion point.

### Verdict on B's maturity

**Research artifact with one production-shaped exit.** The decode is verified and
the emitters are honest, but nothing in B assembles a scene: there is no importer,
no texture, no `.unity` file, and the whole pipeline is per-scene CLI runs against
`D:\MapExtract`. Treating it as "the other way to import maps" would be wrong.

---

## Are A and B complementary? — CONFIRMED, with one correction

The hypothesis holds.

* **A recovers what B cannot**: texture pixels, real Unity material/prefab/scene
  assets, a project that opens. B writes JSON and C#; it never decodes a texture.
  (measured.)
* **B recovers what A cannot**: BSG MonoBehaviour **field values**. A's own doc
  says scripts "become empty stub components". B decodes them from stripped type
  trees and can emit the C# class that would hold them. (measured; the decode rate
  is relayed.)
* **Why A cannot**: AssetRipper reconstructs script layouts from il2cpp
  `global-metadata.dat`. Tarkov's is **encrypted** — this repo decrypts it with
  `tools/metablob.py` into `.cache/global-metadata.dec.dat`, and B's tools take
  `--metadec` pointing at that cache. AssetRipper has no such key, so it sees no
  usable script metadata. (inferred, from measured facts: the metadata is
  encrypted, the repo carries the decryptor, B's tools require the decrypted
  file, and A's doc independently reports stub components.)

**The correction to the hypothesis:** the overlap is larger than "A=geometry,
B=components". B's `mapextract.py` *also* does geometry (glTF + transforms). That
half of B is **superseded by A** for this goal and should not be run for it. The
complementary part of B is `mapextract_mono.py` + `monotree.py` + `monostub.py`.

---

## Duplication and contradictions found

1. **Geometry is done twice.** `mapextract.py` (glTF) vs AssetRipper (Unity
   assets). For "one scene with textures", A wins outright — B's glTF has no
   texture bytes. Keep `mapextract.py` for offline analysis (`inventory`, `scan`,
   `verify`), not for import.
2. **B does not obviate A's bounds-packing.** `hierarchy.json` stores **local**
   T/R/S per node. Within a map that reproduces the same sub-scene placement
   AssetRipper already preserves, so A's per-map grouping is unaffected. (measured
   — the emitter writes `m_LocalPosition/Rotation/Scale`.)
3. **Neither effort has inter-map placement data.** A's doc states adjacency is
   not in the game files and refuses to invent it; nothing in B's output contains
   a cross-map offset either (measured: `mono.json` is per-scene and carries no
   world-anchor type; `_map.json` lists scene names only). So the grid + manual
   drag stays the honest answer, and the "connect all the maps" goal is a
   **hand-authored** step in both worlds. Say so plainly to the user.
4. **No contradiction in the measurements.** Both efforts independently report
   Unity 2022.3.43f2, and both agree that BSG script data does not come through
   the ordinary path.

## Two things that are red herrings for this task

* **`build/maps/aowl_greybox_preset.bundle`** — with `tools/mkpreset.py`,
  `tools/stage_greybox.py`, `tools/patch_greybox_location.py`. This is the
  *opposite* direction: proving a custom preset bundle can be staged **into the
  live client** (`StreamingAssets/Windows/maps` + `Windows.json` +
  `ConsistencyInfo` resync). Interesting later — it is how a Unity-authored map
  would ever get back into the game — irrelevant to importing maps out. (measured
  from `stage_greybox.py`'s header.)
* **`dm/`** — a fork of SPT-DynamicMaps, an in-game **2D** minimap mod with raster
  layer support. Nothing to do with 3D scene import. (measured from its README.)

---

## Recommended run order

1. **Tonight — Effort A alone.** Rip, open, click *Import + Unify World (grid)*.
   Expect: all maps, one scene, textured, Standard shaders, no BSG components.
   Then drag map containers to stitch. Follow `docs/UNITY_MAP_IMPORT.md`.
   Nobody has run this end to end; treat the first run as the test.
2. **Later — layer B onto A's project.** Only if the missing component data
   actually blocks something.

## The concrete next step to fuse them

Not built here; this is the sketch, not a claim that it works.

1. `mapextract_mono.py extract --scene <N...> --out <dir>` for the scenes you
   care about → `<scene>.mono.json`.
2. `monostub.py from-mono <dir> --out <csdir>` → C# classes for every laid-out
   type.
3. Drop those `.cs` into the ripped project's script folder — **and first delete
   or rename AssetRipper's own stubs for the same namespace+type**, or
   `Assembly-CSharp` will not compile on duplicate class names. This collision is
   the first real obstacle and is unmeasured.
4. Write a small Editor script that, per scene, reads `<scene>.mono.json`, resolves
   each entry's `path` against the loaded hierarchy, `AddComponent<T>()` the stub
   and assigns `fields` via `SerializedObject`. This does not exist. It is the
   only genuinely new code the fusion needs.

Scope honestly: step 4 is a real project, not a glue script, and the payoff is
spawn points / exfils / AI markers — not visual fidelity. Do not start it to get
maps on screen.

## What is not verified

* The A importer has **never been run**. No claim here that it works.
* B's 98.5% decode rate, the 480-scene count and the 2022.3.43f2 version are
  **relayed** prior measurements, not re-measured during this reconciliation.
* Whether AssetRipper's stub classes collide with `monostub.py` output —
  unmeasured, and the first thing a fusion attempt would hit.
* Whether Unity binds level-file MonoBehaviour data by name in a *ripped* project
  the way it demonstrably does inside a bundle — `monostub.py` documents the
  bundle case; the ripped-project case is untested.
