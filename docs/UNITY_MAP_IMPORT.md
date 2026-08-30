# Import all EFT maps into one Unity scene (click once)

This pipeline rips the Escape From Tarkov game data into a fresh, openable Unity
project and gives you a one-click Editor menu that loads **every** map at once,
lays them side-by-side under a single `AowlWorld` object, and centers the whole
thing at the origin. You get real geometry and real textures in a real scene.

It does **not** modify the game, touch the `D:\Aowlspt\aowlspt` deploy, or launch
Escape From Tarkov. It only reads the game data folder.

---

## What is measured / fixed about this build

| Fact | Value | Why it matters |
|------|-------|----------------|
| **Unity Editor version** | **`2022.3.43f2`** | Read from `globalgamemanagers`. Your Unity Editor **must** be this exact version or AssetRipper's export will not open cleanly (shader/asset GUID and serialization mismatches). |
| Game data folder | `D:\Aowlspt\EscapeFromTarkov_Data` | Contains `globalgamemanagers` + `level*` files. Also present at the real install `D:\Games\Tarkov`. |
| Map scenes | **480 location scenes** across **18 map folders** | See the table below. |

Post-1.0 EFT maps are **compiled** Unity scenes baked into the `level*` files, not
editable source. AssetRipper reconstructs an openable project from them, which is
the right tool for *viewing / building on* the geometry in a fresh project. It is
**not** a path to modifying the shipped game.

---

## The maps (folder = one map, made of many additive sub-scenes)

Each map lives as a **folder** under `Assets/Content/Locations/<Map>/`, split into
many additive sub-scenes (geometry, AI nav, lighting, scripts, design props,
indoor blocks, ...). The importer groups every sub-scene of a folder back into one
map under `AowlWorld/<Map>`.

| Folder | EFT map | Sub-scenes |
|--------|---------|-----------:|
| `City`                   | Streets of Tarkov            | 201 |
| `Laboratory`             | The Lab                      | 40 |
| `Sandbox`                | Ground Zero                  | 34 |
| `Sandbox_StartLocation`  | Ground Zero (low-level variant) | 28 |
| `Terminal`               | Terminal                     | 26 |
| `Reserve_Base`           | Reserve                      | 25 |
| `Lighthouse`             | Lighthouse                   | 23 |
| `Custom`                 | Customs                      | 18 |
| `shorline`               | Shoreline (BSG's spelling)   | 14 |
| `Shopping_Mall`          | Interchange                  | 14 |
| `Factory_Rework`         | Factory (reworked)           | 14 |
| `Labyrinth`              | Labyrinth (event/hardcore)   | 12 |
| `Venders`                | Trader/hideout dioramas (not a raid map) | 8 |
| `Woods`                  | Woods                        | 7 |
| `Icebreaker`             | Icebreaker (Arena)           | 7 |
| `Factory`                | Factory (original)           | 6 |
| `Arena`                  | Arena core                   | 2 |
| `bunker`                 | bunker fragment              | 1 |

`Factory_Rework` is build indices 525-538 (fact #205). The importer discovers all
of these at runtime by scanning `Assets/Content/Locations` -- nothing is
hard-coded, so if BSG adds a map it appears automatically.

The full 480-path list is not reproduced here; the importer enumerates it live.
Representative entry scenes: `Woods/woods_combined.unity`,
`Factory/Factory.unity`, `Custom/custom_multiScene.unity`,
`Lighthouse/Lighthouse_Main.unity`, `shorline/Shoreline_North.unity`.

---

## What you must install / download (one time)

1. **AssetRipper (free)** -- not currently on this machine.
   - Open <https://github.com/AssetRipper/AssetRipper/releases/latest>
   - Download **`AssetRipper_win_x64.zip`**.
   - Extract to **`D:\Tools\AssetRipper\`** so that
     `D:\Tools\AssetRipper\AssetRipper.GUI.Free.exe` exists.
   - (Any other folder works too -- pass it with `-AssetRipperPath`, or set
     `ASSETRIPPER_HOME`.)

2. **Unity `2022.3.43f2`** via **Unity Hub**.
   - Unity Hub -> Installs -> Install Editor -> *Archive / "install a specific
     version"* -> pick **2022.3.43f2** exactly. If Hub does not list it, use the
     download archive: <https://unity.com/releases/editor/archive> (2022.3.43).

3. **Disk space.** EFT is large; the exported Unity project is **tens of GB**.
   Make sure `D:\Aowlspt\ripped\` (or your `-OutputDir`) has room.

Nothing else. No SPT, no BepInEx, no game launch.

---

## Step 1 -- rip the game into a Unity project (one command)

From a PowerShell prompt in the repo:

```powershell
pwsh -File tools\unity_import\rip_maps.ps1
```

This is **fully non-interactive**. It:

1. verifies `D:\Aowlspt\EscapeFromTarkov_Data\globalgamemanagers` exists;
2. finds `AssetRipper.GUI.Free.exe`;
3. launches it **headless** on a fixed port (`AssetRipper.GUI.Free.exe --headless
   --port 57893`);
4. `POST /LoadFolder` (the game data folder) then `POST /Export/UnityProject`
   (the output folder) over `http://127.0.0.1:57893` -- AssetRipper's own HTTP
   API, the same one its web UI uses;
5. stops AssetRipper, locates the exported project
   (`.../ProjectSettings/ProjectVersion.txt`), and **copies the Editor importer
   into `<project>\Assets\Editor\`** so the menu is present when you open it.

Useful switches:

```powershell
# non-default AssetRipper location
pwsh -File tools\unity_import\rip_maps.ps1 -AssetRipperPath "C:\path\AssetRipper.GUI.Free.exe"

# different output folder
pwsh -File tools\unity_import\rip_maps.ps1 -OutputDir "E:\eft-unity"
```

### If your AssetRipper is too old for `--headless`

The **official free build has no true command-line export** -- it is a GUI whose
back-end is a localhost web server. This script drives that server headlessly,
which works on current releases. If your build predates `--headless`, the script
says so and you re-run it interactively:

```powershell
pwsh -File tools\unity_import\rip_maps.ps1 -Interactive
```

That launches the GUI and prints the exact clicks:

1. **File -> Open Folder** -> `D:\Aowlspt\EscapeFromTarkov_Data` (wait -- minutes).
2. **Export -> Export all files to Unity project**.
3. Choose output `D:\Aowlspt\ripped\eft-unity`.
4. Then copy `tools\unity_import\Editor\AowlEftMapImporter.cs` into
   `<exported project>\Assets\Editor\` yourself.

(There is also a community console fork, `LiveGobe/AssetRipper.CLI`, if you prefer
a hand-run console exe -- but the headless-HTTP path above needs no extra tool.)

---

## Step 2 -- open the project

1. Unity Hub -> **Add** -> select the exported project folder the script printed
   (under your `-OutputDir`, e.g. `D:\Aowlspt\ripped\eft-unity\ExportedProject`).
2. Open it with **Unity 2022.3.43f2**. The **first** open is slow -- Unity
   reimports every mesh and texture. Let it finish.

---

## Step 3 -- click once

In the Unity menu bar:

> **Aowlspt -> Import + Unify World (grid)**

This opens **every** map, groups each under `AowlWorld/<Map>`, auto-positions the
maps into a tidy non-overlapping grid on one ground plane, and centers everything
at the origin. Save the scene (Ctrl+S) to keep it.

Other menu items (all under **Aowlspt**):

| Menu item | Does |
|-----------|------|
| **Import + Unify World (grid)** | The one-click unified world (above). |
| **Import All EFT Maps (additive)** | Opens every scene additively at their baked coordinates, no layout (maps overlap near origin -- raw view). |
| **Re-Layout AowlWorld (grid)** | Recompute the grid for whatever maps are currently under `AowlWorld` (after you add or remove some). |
| **Clear AowlWorld** | Delete the `AowlWorld` root. |
| **EFT Map Importer Window** | A panel with a per-map **Import** button so you can load **one** map at a time -- recommended, because Streets (`City`, ~200 sub-scenes) alone is heavy. |

### Loading everything is heavy

`City`/Streets is ~200 sub-scenes and the full set is 480. Importing all at once
can take minutes and a lot of RAM. If Unity struggles, use the **EFT Map Importer
Window** and import a handful of maps, then **Re-Layout AowlWorld (grid)**.

---

## Connecting maps into one continuous world

The grid is just a tidy **default** so nothing overlaps. **True geographic
adjacency between EFT maps is not stored in the game files**, and this tool does
**not** invent adjacency numbers.

Each map stays a **separate child of `AowlWorld` with a clean transform**, so to
"stitch" maps you simply select a map container in the Hierarchy and **drag it** in
the Scene view next to another (e.g. line Customs up against Woods). Because each
map is one transform, one drag moves the whole map. Do **not** run *Re-Layout*
after hand-placing -- that re-packs the grid and undoes your arrangement.

> A lore-adjacency preset menu was considered and deliberately left out: the real
> stitched offsets (Customs<->Factory tunnel, Woods<->Customs, Shoreline<->
> Lighthouse, Reserve underground, ...) are not derivable from the files, and
> guessing coordinates would be worse than an honest grid. Drag-to-stitch is the
> supported workflow.

---

## The honest caveats

**What survives the rip:** map **geometry** (meshes) and **textures**, as a real
Unity scene you can fly through, light, and build on.

**What does NOT survive:**

- **BSG custom shaders.** Materials import with their **textures** but on a
  **fallback / Standard** shader. Surfaces will look flatter / wrong compared to
  in-game; terrain blending, glass, foliage, water, decals especially.
- **C# scripts / MonoBehaviours.** They become **empty stub components**. No game
  logic, no BSG components, no interactivity -- just the objects they were on.
- **Some engine-baked data** (occlusion, certain lightmaps, navmesh) may be
  partial or need rebaking.

So: a real, navigable, textured scene of the maps -- yes. A running slice of
Tarkov -- no. That is inherent to ripping a compiled IL2CPP Unity game, not a
limitation of this script.

---

## Files in this pipeline

- `tools/unity_import/rip_maps.ps1` -- the AssetRipper driver (headless HTTP, or
  `-Interactive`).
- `tools/unity_import/Editor/AowlEftMapImporter.cs` -- the Editor menu; copied
  into the exported project automatically by the driver.
- `docs/UNITY_MAP_IMPORT.md` -- this document.
