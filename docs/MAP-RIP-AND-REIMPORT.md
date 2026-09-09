# Ripping the pre-1.0 maps and re-importing them as ONE world (EscapeFromMyBasement)

Research document, 2026-09-07. Target: the SPT 4.1.5 client at `D:\SPT415`
(EFT 0.16.9.5-40743, Mono). Nothing here was run against a live game; nothing
under `D:\SPT415` was modified. Every claim is tagged **measured** (with the
command that produced it) or **unverified**. The scripts are
`tools/maprip/rip.ps1` (+ `maps.json`); the user runs them, this session did not.

The one fact that reshapes the whole plan, first:

> **The maps are not asset bundles.** Every location is a set of scenes built
> INTO THE PLAYER (`EscapeFromTarkov_Data\level{N}` + `sharedassets{N}.assets`).
> `StreamingAssets\Windows\maps\*_preset.bundle` are 6-64 KB `ScenesPreset`
> ScriptableObjects that only NAME those scenes. Ripping a map means ripping
> the specific `level{N}`/`sharedassets{N}` files its preset lists, not a
> bundle directory. (measured, section 1.3)

---

## 1. What is on disk

### 1.1 Engine and game version — measured

```powershell
(Get-Item D:\SPT415\EscapeFromTarkov.exe).VersionInfo   # FileVersion 0.16.9.40743, ProductVersion 0.16.9.5-40743-f137e819
(Get-Item D:\SPT415\UnityPlayer.dll).VersionInfo        # ProductVersion 2022.3.43f1 (85497d293fa1)
strings -n 6 StreamingAssets\Windows\maps\factory_day_preset.bundle | head   # "UnityFS", "2022.3.43f1" (bundle header agrees)
```

* Unity **2022.3.43f1**. Mono scripting (`MonoBleedingEdge\`, `Managed\Assembly-CSharp.dll` 16,233,472 B, 171 DLLs in `Managed\`).
  An `il2cpp_data\` directory also exists under `EscapeFromTarkov_Data` (with `Metadata\` and `Resources\`); its role in a Mono build is **unverified** — it was not opened.
* Locally installed editors (measured `ls "C:\Program Files\Unity\Hub\Editor"`): **2022.3.43f1**, 2022.3.62f3, 6000.6.0f1. The exact matching editor is already installed.
* Disk (measured `df -h`): `D:` 745 GB free, `C:` 8.8 GB free. **Everything must go on D:** — rip output, staging, the Unity project, the Library cache. `rip.ps1` defaults to `D:\aowlspt-maprip`.

### 1.2 Where the map data lives — measured

`EscapeFromTarkov_Data\` (57,969 MB total, measured `du -sm`):

| what | measured |
|---|---|
| `level0..level557` | 558 files, 2,707.75 MB (`ls -l level* \| awk`) |
| `level{N}.resS` | 489 files |
| `sharedassets{N}.assets` (+ `.resS`) | 1,068 files, 21,066.6 MB |
| `resources.assets` / `.resS` | 316,964,564 B / 358,540,432 B |
| `globalgamemanagers` BuildSettings | **558 scene paths** (parsed with UnityPy, `buildsettings_scenes.json`; `strings` finds only 420 of them — a `strings`-based index map is WRONG, the first draft of this doc had one) |
| `StreamingAssets\Windows\` | 6,571 files, 28,745 MB, one manifest `Windows.json` (2,384,070 B, 6,570 entries: `{key: {FileName, Crc, Hash, Dependencies}}`). There are no per-bundle `.manifest` files. |
| `StreamingAssets\Windows\maps\` | 15 preset bundles, 6,624-63,696 B each (list below) |
| `StreamingAssets\Windows\assets\content\locations\` | 1 MB, one `_presets` entry — nothing else |
| `StreamingAssets\Windows\assets\content\location_objects\` | 750 MB (map prop prefabs, shared by maps) |
| `StreamingAssets\Windows\shaders` | one 378,084,672 B bundle (every bundle's `Dependencies` names `shaders` and `cubemaps`) |
| `StreamingAssets\Culling_Data\` | 11 files, 2,530 MB, named `<guid>_packed_cull.bytes` — Koenigz **PerfectCulling** bakes (`Koenigz.PerfectCulling.EFT.PerfectCullingCrossSceneSampler::InitializeAutoCulling` is called from `TarkovApplication/CG_LoadMapAndData`); which guid is which map is **unverified** (the guids do not occur in `globalgamemanagers`/`resources.assets`) |
| `StreamingAssets\AudioBakeData\` | 15 files, 514 MB, one `<map>_sound.audiobakedata` per location |
| `StreamingAssets\Acoustics\` | 576 files, 770 MB, one dir per scene chunk (179 `City_*`, 43 `Laboratory_*`, 36 `Reserve_*` ...) |
| `StreamingAssets\Grass\` | 7 `.pcl` (Arena/City/Sandbox/Terminal grass) |

The scene paths in BuildSettings group as (measured): City 247, Laboratory 49, Reserve_Base 49, Sandbox 47, Custom 29, Lighthouse 29, shorline 20, Shopping_Mall 18, Factory_Rework 18, Labyrinth 14, Woods 9, Factory 8, Arena 3, bunker 1, other (UI/main/Dissonance) 17.

### 1.3 The location-id -> scenes manifest — measured

Two halves:

**Server side** — `D:\SPT415\SPT_Runtime\SPT_Data\database\locations\<id>\base.json`, field `Scene: {path, rcid}` (python over every `base.json`):

| dir | `Id` | `Name` | `Enabled` | `Scene.path` | `Scene.rcid` | spawns / exits | base.json |
|---|---|---|---|---|---|---|---|
| factory4_day | factory4_day | Factory | true | maps/factory_day_preset.bundle | factory_day.scenespreset.asset | 145 / 5 | 109 KB |
| factory4_night | factory4_night | Factory | false | maps/factory_night_preset.bundle | factory_night.scenespreset.asset | 145 / 5 | 108 KB |
| bigmap | bigmap | Customs | true | maps/customs_preset.bundle | bigmap.scenespreset.asset | 318 / 11 | 231 KB |
| woods | Woods | Woods | true | maps/woods_preset.bundle | woods.scenespreset.asset | 368 / 9 | 258 KB |
| shoreline | Shoreline | Shoreline | true | maps/shoreline_preset.bundle | shoreline.scenespreset.asset | 312 / 10 | 229 KB |
| interchange | Interchange | Interchange | true | maps/shopping_mall.bundle | Shopping_Mall.ScenesPreset.asset | 252 / 6 | 178 KB |
| rezervbase | RezervBase | ReserveBase | true | maps/rezerv_base_preset.bundle | Rezerv_Base.scenespreset.asset | 208 / 6 | 157 KB |
| laboratory | laboratory | Laboratory | true | maps/laboratory_preset.bundle | laboratory.ScenesPreset.asset | 170 / 7 | 129 KB |
| lighthouse | Lighthouse | Lighthouse | true | maps/lighthouse_preset.bundle | lighthouse.scenespreset.asset | 250 / 7 | 188 KB |
| tarkovstreets | TarkovStreets | Streets of Tarkov | true | maps/city_preset.bundle | city.scenespreset.asset | 458 / 12 | 315 KB |
| sandbox | Sandbox | Sandbox | true | maps/sandbox_preset.bundle | sandbox.scenespreset.asset | 232 / 5 | 158 KB |
| sandbox_high | Sandbox_high | Sandbox | true | maps/sandbox_high_preset.bundle | sandbox_high.scenespreset.asset | 233 / 5 | 164 KB |
| labyrinth | Labyrinth | Labyrinth | false | maps/labyrinth_preset.bundle | Labyrinth.scenespreset.asset | 14 / 1 | 30 KB |
| develop | develop | Arena | false | maps/develop_preset.bundle | develop.scenespreset.asset | 11 / 6 | 14 KB |
| hideout | hideout | Hideout | false | maps/bunker_preset.bundle (**file does not exist** in `maps\`) | bunker.ScenesPreset.asset | 3 / 0 | 5 KB |
| terminal / privatearea / suburbs / town | Terminal / Private Area / Suburbs / Town | — | true/false/false/false | `""` | `""` | 0 / 0 | 3 KB each |

`base.json` has 100 top-level keys (`Id, Name, Enabled, Scene, SpawnPointParams, exits, transits, BossLocationSpawn, waves, Loot, OcculsionCullingEnabled, MaxPlayers, EscapeTimeLimit, ...`). There is **no `Bounds`/size field**; the only map-extent data is `SpawnPointParams[].Position` and `exits`. Measured factory4_day spawn extents: x -46.7..72.1, z -73.9..63.1, y -3.9..8.2 (~120 x 137 m).

**Client side** — the preset bundle. `EFT.ScenesPreset : ScriptableObject` (MemberCheck `type ScenesPreset`):

```
F Guid ActiveSceneGuid      (EFT.ScenesPreset/Guid = {String guid; Boolean _onlyOffline})
F String ServerName
F List`1 ScenesGuids
F Boolean _disableServerScenes   (NOT serialised — measured absent from the payload)
F ScenesPreset[] ChildPresets
F String _activeSceneName
F List`1 _scenesResourceKeys     (EFT.SceneResourceKey : ResourceKey {path, rcid} + _onlyOffline)
P SceneResourceKey[] ScenesResourceKeys {get}   -> _scenesResourceKeys.Where(ShouldLoadScene)
```

The bundles carry no type tree, so the payload was parsed by hand from the hex dump (UnityPy `get_raw_data()`, all 15 bundles, every preset consumed byte-exactly: `presets.txt`/`presets.json` in the scratchpad, condensed into `tools/maprip/maps.json`). Result per `ServerName`:

| ServerName | preset bundle | presets in bundle | scenes (via ChildPresets) | built-in bytes (level+sharedassets) |
|---|---|---|---|---|
| factory4_day | factory_day_preset.bundle | 3 | **14** (`Factory_Rework_*`, active `Factory_Day`) | 0.21 GB |
| factory4_night | factory_night_preset.bundle | 3 | 14 | 0.21 GB |
| bigmap | customs_preset.bundle | 2 | 29 | 6.31 GB |
| Woods | woods_preset.bundle | 1 | 9 | 1.52 GB |
| Shoreline | shoreline_preset.bundle | 1 | 20 | 2.93 GB |
| Interchange | shopping_mall.bundle | 1 | 18 | 1.14 GB |
| RezervBase | rezerv_base_preset.bundle | 1 | 49 | 1.24 GB |
| laboratory | laboratory_preset.bundle | 1 | 49 | 0.64 GB |
| Lighthouse | lighthouse_preset.bundle | 1 | 29 | 1.90 GB |
| TarkovStreets | city_preset.bundle | 23 | 247 | 3.95 GB |
| Sandbox / Sandbox_high | sandbox(_high)_preset.bundle | 6 | 46 each (same scenes, different `*_AI`/light) | 0.62 GB |
| Labyrinth | labyrinth_preset.bundle | 1 | 14 | 0.21 GB |
| develop (Arena) | develop_preset.bundle | 1 | 3 | ~0 |

Every scene name in every preset resolves to a BuildSettings entry (`missing_in_build=[]` for all 13). Each location has exactly one `*_AI` scene flagged `onlyOffline` (the bot navigation/`BotZone` scene, loaded only offline — SPT is always offline, so it loads).

**Total map payload: 21.85 GB of built-in scene data over 558 scenes** (measured sum of `level{i}`+`level{i}.resS`+`sharedassets{i}.assets`+`.resS`, exact indices), of which 21.6 GB belongs to the 13 playable presets above. Add `resources.assets` (0.63 GB) and `shaders` (0.35 GB) which they all reference. **Not** 28.7 GB of `StreamingAssets\Windows` — that is items, weapons, characters, audio, hands and pocket-maps; the maps proper are only `location_objects` (750 MB) and the 15 tiny presets.

Terrain scenes by name (measured from BuildSettings, sizes exact): `custom_Terrain` 501.7 MB, `shoreline_Terrain` 642.9 MB, `woods_terrain` 538.0 MB, `Lighthouse_Terrain` 306.5 MB, `Reserve_Base_Terrain` 160.2 MB, `Shopping_Mall_Terrain` 128.4 MB. Factory, Labs, Streets, Sandbox, Labyrinth have no terrain scene. Whether these hold `TerrainData` or only meshes is **unverified** (class ids are not visible to `strings`; AssetRipper will show it in one load).

### 1.4 How the client loads a location — measured (MemberCheck on a %TEMP% copy of Assembly-CSharp.dll)

```
TarkovApplication/CG_LocalGameMatching::MoveNext
  RaidSettings.get_SelectedLocation()  -> JsonType.LocationSettings/Location   (F ResourceKey Scene  <- base.json "Scene")
  new ScenePresetLoadConfig(location.Scene, disableServerScenes)
  TarkovApplication.LoadMapAndData(config, ...)
    -> TarkovApplication/CG_LoadMapAndData
       AssetsManagerExtension.LoadScenesFromPreset(IAssetsManager, ScenePresetLoadConfig, loadFirstAsSingle, parallel, allowActivation, ct, progress)
         -> LoadScenesFromPresetOperation.LoadPresetAsync(ScenesPreset)          # GetAsset<ScenesPreset>(key) from the EasyAssets bundle system
              keys = preset.ScenesResourceKeys                                    # _scenesResourceKeys filtered by ShouldLoadScene (onlyOffline)
              ScenesLoadCoroutine(keys) -> per key: AssetsManagerExtension.LoadScene(mgr, key, mode, allowActivation, progress)
                 -> AssetsManager/LoadSceneOperation/CG_Coroutine::MoveNext:
                      BundlesManager.LoadBundleAsync(bundleName, ...)             # for a built-in scene the key path is "Assets/Content/Locations/....unity" -> not in Windows.json, no bundle
                      SceneManager.LoadSceneAsync(Path.GetFileNameWithoutExtension(sceneName), loadSceneMode)   # BY NAME, so it hits the built-in level{N}
       GameWorld.InitLevel(ItemFactory, ObjectsFactoryConfig, bool, List<ResourceKey>, IProgress<InitLevelProgress>, ct)
       PerfectCullingCrossSceneSampler.InitializeAutoCulling(ct, progress)
       LevelSettings.OnPostLoadingScene()
```

`ResourceKey.ToAssetName()` = `rcid` if set, else `path` without its directory; `ResourceKey.FileName` = `GetFileNameWithoutExtension(path)`. A second, newer loader exists (`EFT.ModernLoadScenesFromPreset.Load(ResourceKey)`, used by `TarkovApplication/HideoutController` and `EFT.NarrateScene`) and does the same: `EasyAssetsExtensions.Retain(bundle keys)` -> `GetAsset<ScenesPreset>` -> `LoadScene(name, mode)` -> `SceneManager.LoadSceneAsync(name)`. `Streamer : MonoBehaviour` (fields `Player`, `Backlash`, `Scenes[]`, `LoadChunkCoroutine`) also calls `LoadSceneAsync(string, mode)` — the Streets chunk streamer.

What the scene must contain for the game to accept it: `LocationScene : MonoBehaviour` registers arrays the world reads by type — `StaticLoot[]`, `LootableContainer[]`, `WorldInteractiveObject[]`, `NavMeshDoorLink[]`, `SpawnPointMarker[]` (`EFT.Game.Spawning.SpawnPointMarker`), `BotZone[]`, `ExfiltrationPoint[]`, `AIPlaceInfo[]`, `BorderZone[]` (BoxCollider + `_extents`), `TransitPoint[]`, `LocationOrigin[]`, `AudioSource[]`, `treeWinds` ... (full list in the MemberCheck output; `LocationScene.LoadedScenes` is the static registry). `EFT.Interactive.Location : MonoBehaviourSingleton<Location>` has `SceneId` and the loot-point/container/spawn-marker arrays. These are the MonoBehaviours a re-imported scene keeps if — and only if — the scripts still resolve to `Assembly-CSharp` (section 3a).

### 1.5 The bundle system and SPT's hook into it — measured

`Diz.Resources.EasyAssets : MonoBehaviour` (`Create(GameObject, IBundleLock, defaultKey, rootPath, platformName, shouldExclude, bundleCheck)`, `Manifest : CompatibilityAssetBundleManifest`, `_bundles : EasyBundle[]`) reads `Windows.json`; `EasyBundle.LoadingCoroutine` -> `AssetBundle.LoadFromFileAsync(path)` (the only `LoadFromFile*` caller in Assembly-CSharp). SPT's own client module patches exactly this:

* `SPT.Custom.Patches.EasyAssetsPatch` (in `D:\SPT415\BepInEx\plugins\spt\spt-custom.dll`): prefix on `EasyAssets.Create`, re-implements `Init` and merges the server's mod bundle list (`GetManifestBundle`/`GetManifestJson`) into the manifest; `SPT.Custom.Patches.EasyBundlePatch` postfixes `EasyBundle..ctor(key, rootPath, manifest, bundleLock)` to redirect a mod bundle's path; `SPT.Custom.Utils.BundleManager` (`RuntimePath`, `CachePath`, `Bundles`, `GetBundleFilePath(BundleItem{FileName, Crc, Dependencies, ModPath})`).
* Server side: `SPTarkov.Server.Core.Loaders.BundleLoader.LoadBundlesAsync(mods)` reads each mod's `bundles.json` (`{"manifest":[{"key": "<bundle key>", "dependencyKeys": []}]}` — measured shape from `user\mods\BorkelRNVGServer\bundles.json`), serves it via `BundleStaticRouter`/`BundleDynamicRouter`.

**So a mod can add a bundle under any key, and a `SceneResourceKey.path` that names a bundle key makes `LoadSceneOperation` call `LoadBundleAsync(thatKey)` before `LoadSceneAsync(name)` — i.e. a STREAMED-SCENE bundle shipped by a mod is loadable by the game's own loader, without patching the loader.** This is the re-import path (section 3c). Unverified: whether `BundlesManager.LoadBundleAsync` tolerates a key that is only in the SPT-merged manifest (it should — that is how every custom item bundle works) and whether `m_IsStreamedSceneAssetBundle` bundles go through `EasyBundle` unchanged (EasyBundle calls `LoadFromFileAsync`, which is bundle-type agnostic).

---

## 2. The ripping toolchain

### 2.1 AssetRipper — measured

* Latest release **2.0.0** (2026-08-24; previous 1.3.14 2026-04-25) — `api.github.com/repos/AssetRipper/AssetRipper/releases/latest`. Assets: `AssetRipper_win_x64.zip` (44,439,367 B, **sha256 `9a7ef0e7c5c3ea5b90b4e6d855e2d98d5f7ec8c3f9e26fccbc194c6a7b01baf7`**, measured on the downloaded file), contents: `AssetRipper.GUI.Free.exe`, `capstone.dll`, `compile_time.txt`. README: supports Unity 3.5.0 – 6000.4.x; GPL-3.0. 2022.3.43f1 is squarely inside the range.
* **There is no export CLI.** Measured `AssetRipper.GUI.Free.exe --help`: only `--headless` (don't open a browser), `--port`, `--log`, `--log-path`, `--local-web-file`, `--version` (`AssetRipper.GUI.Web 2.0.0+1ac666f4`). The older `AssetRipperConsole` (`-o`, `-q`) no longer ships. Community forks (LiveGobe/AssetRipper.CLI) target older versions — not pinned here.
* **It is scriptable anyway**: it hosts an ASP.NET app with an OpenAPI description. Measured by starting `--headless --port 47311` and reading `/openapi.json` (saved in the scratchpad): `POST /LoadFile`, `POST /LoadFolder` (form `Path`), `POST /Settings/Update` (form fields), `POST /Export/UnityProject`, `POST /Export/PrimaryContent` (form `Path`), `GET /Collections/Count`, `/Scenes/View`, `/FailedFiles/View`, `/Reset`. `rip.ps1` drives exactly these. Unverified: whether Load/Export block for the duration of the request (the script uses long timeouts and checks `/Collections/Count` after load).
* Settings field names (measured from `GET /Settings/Edit`): `ScriptExportMode` {Decompiled, **Hybrid** (default), DllExportWithRenaming, DllExportWithoutRenaming}, `ShaderExportMode` {**Dummy** (default), Decompile, ...}, `ScriptContentLevel` {Level0, Level1, ...}, `BundledAssetsExportMode` {GroupByAssetType, GroupByBundleName, **DirectExport**}, `LightmapTextureExportFormat` {Exr, Image}, `ImageExportFormat`, `AudioExportFormat`, `TextExportMode`, `SpriteExportMode`, `EnableStaticMeshSeparation`, `EnablePrefabOutlining`, `EnableAssetDeduplication`, `IgnoreStreamingAssets`, `TargetVersion`/`DefaultVersion`, `PublicizeAssemblies`, `RemoveNullableAttributes`, `ScriptLanguageVersion`, `ScriptTypesFullyQualified`.
* Documented caveats that apply here (assetripper.github.io Common Issues): scripts from bundles need the `.dll`s alongside (the script links `Managed\`); publicized / Il2CppInterop-modified assemblies break field deserialization — use the stock `Assembly-CSharp.dll`, not BepInEx's publicized copy; shader decompilation is a premium feature, the free build exports **dummy shaders** (so every material is a stub that needs a real shader at reimport, section 3a). Terrain (`TerrainData` -> `.asset`) and lightmaps (EXR) export in the free build (**unverified on this game**).

### 2.2 AssetStudio — fallback, unverified

AssetStudio (Perfare, archived; community forks "AssetStudioMod"/"AssetStudio.GUI" by aelurum) reads 2022.3 serialized files and exports meshes (OBJ/FBX), textures and audio one asset at a time; it does **not** reconstruct scenes/prefabs. Use it only to salvage a specific mesh/texture AssetRipper fails on. Not pinned or downloaded.

### 2.3 The dependency closure — measured (this killed the first two runs)

The first staging (a map's `level{N}` + `sharedassets{N}` only) made AssetRipper log dozens of `Import : Dependency 'sharedassetsNNN.assets' wasn't found` (coordinator's runs 1-2). The cause is measured with UnityPy over `SerializedFile.externals`, iterated to a fixed point from each map's files + `globalgamemanagers(.assets)` + `resources.assets`:

| map | start files / GB | closure files / GB (+.resS) |
|---|---|---|
| factory4_day | 31 / 1.17 | **385 / 17.50** (354 extra `sharedassets*.assets`) |
| Woods | 21 / 2.48 | 344 / 17.50 |
| bigmap | 61 / 7.28 | 365 / 18.89 |
| TarkovStreets | 497 / 4.91 | 662 / 18.07 |
| laboratory / RezervBase / Sandbox / Interchange / Shoreline / Lighthouse / Labyrinth | 39-101 / 1.2-3.9 | 355-436 / 17.2-17.7 |
| **all 13 together** | — | **1,542 files / 22.61 GB** |

So the closure of ANY one map is effectively the whole build (the `sharedassets` files form one connected graph); per-map staging saves only the scene files (14 `level{N}` instead of 558), not the assets. `maps.json` now carries `closureFiles` per map and `rip.ps1` stages exactly that (hard links, so 17.5 GB of staging costs 0 bytes). RAM on this machine: 31.9 GB total, 14.3 GB free at the time, 12 GB pagefile on the nearly full C: — AssetRipper's peak working set for a 17.5 GB load is recorded by the script (`peakRAM=` in the verdict line), see 2.5.

### 2.4 What `rip.ps1` does — as fixed after runs 1-3

`tools\maprip\rip.ps1`:

1. Downloads the pinned zip into `<ToolRoot>\2.0.0\` (default `D:\aowlspt-tools\assetripper`; C: has 8.8 GB free), refuses on sha256 mismatch.
2. Per map: stages `<OutRoot>\_staging\<map>_Data\` with hard links to every `closureFiles` entry + `Managed\*.dll`.
3. Starts `AssetRipper.GUI.Free.exe --headless --port 47311` with `-RedirectStandardOutput` (measured: the `--log true --log-path "..."` form never started listening; the plain form answers within ~10 s), `TEMP`/`TMP` pointed at `D:\aowlspt-tools\tmp`.
4. `POST /Settings/Update`, `POST /LoadFolder`. **Measured: both `/LoadFolder` and `/Export/UnityProject` return `302` in < 0.1 s and do the work asynchronously**; `GET /Collections/Count` is per-collection (`404 The path must be included in the request` without `?Path=`), so it is not a readiness signal. The only completion signals are stdout lines — `Processing : Finished processing assets` after a load and `Export : Finished post-export` after an export (measured on a tiny load/export of `factory_day_preset.bundle`; the load log ends `Import : Finished reading files` -> `Processing : ...` -> that line; the export log ends `Export : Finished exporting assets` -> `Export : Saving game assemblies...` -> that line). The script polls the log for those, tracks `PeakWorkingSet64`, and returns `done | died | timeout | error` (OutOfMemory / Unhandled exception lines).
5. Verdict that can fail: every scene name in the preset must exist as a `.unity` in the export — `PASS` / `FAIL (missing scenes: ...)` / `INCONCLUSIVE (...)`; plus a census line: meshes, materials, prefabs, load/export seconds, peak RAM, staged GB, output GB, `Dependency ... wasn't found` count, error-line count.
6. `-DryRun` prints the plan and touches nothing; `-Maps all` does the 13 locations, each a separate AssetRipper process (17-19 GB load each — 13 loads of the same graph; a single whole-folder load + one export of all 558 scenes is the alternative when disk allows, since the closure IS the whole build).

### 2.5 The real factory4_day run — measured 2026-09-07

Run 4 (this session; runs 1-3 were the coordinator's and died on the two bugs above). `rip.ps1 -Maps factory4_day -OutRoot D:\aowlspt-maprip -ToolRoot D:\aowlspt-tools\assetripper -TempDir D:\aowlspt-tools\tmp -KeepStaging`, AssetRipper 2.0.0 headless on port 47311, staged 737 files / 17.50 GB (hard links) + `Managed\`.

```
VERDICT factory4_day : PASS   scenes=14/14 (Factory_Rework_AI, _Admin_Office, _Areas, _Background, _Basement, _Day_Culling,
                              _Day_Light, _Day_Scripts, _DesignMain, _DesignStuff, _Laboratory, _Main_Building, _Quests,
                              Factory_Sound_Rework -- every preset scene present as .unity, 0 extra .unity)
load   = 18 s   ("Import : Finished reading files" -> "Processing : Finished processing assets" at 15:11:25; started 15:11:07)
        Import : Files use the 'Mono' scripting backend   (Managed\ was picked up)
        depMissing (Dependency ... wasn't found) = 0       (was dozens with the non-closure staging)
export = 684 s  (POST 15:14:28 -> "Export : Finished post-export" 15:25:52), 127,371 assets, ~11k assets/min
RAM    = peak working set 7.72 GB (PeakPagedMemorySize 7.73 GB), 828 CPU-seconds total on 10c/20t
output = D:\aowlspt-maprip\factory4_day  29,755 MB, 269,439 files
         97,596 .asset (93,014 of them under Assets\Mesh)  13,388 .png  7,973 .mat  5,567 .physicMaterial
         1,543 .audioclip  376 .shader (dummies)  325 .prefab  233 .dll  8,694 .cs  24 .terrainlayer  47 NavMesh* files
         22 TerrainData .asset  0 .exr (no lightmaps exported as EXR -- lightmaps landed as .png or were not separate; unverified which)
log    = 132,893 lines; real errors 0; 1,543 x "Can't decode audio clip ... audio data could not be found"
         (every clip: the audio lives in StreamingAssets bundles we excluded -- expected, not a map problem);
         8 x "Unable to convert '<font> Atlas' to bitmap" (TMP font atlases, irrelevant)
scripts: LocationScene.cs / BotZone.cs / SpawnPointMarker.cs / ExfiltrationPoint.cs / LootableContainer.cs exported with
         guids, and the scene YAML references them (LocationScene guid in 14/14 scenes; BotZone in the _AI scene;
         SpawnPointMarker in 2; ExfiltrationPoint in 1; LootableContainer in 1)
missing scripts (m_Script: {fileID: 0}) per scene: Factory_Rework_AI 93, Factory_Rework_Background 1, all others 0
scene sizes: Basement 102 MB, Areas 80 MB, Main_Building 78 MB (8,575 MonoBehaviours), Admin_Office 39 MB, Background 35 MB,
         Day_Light 25 MB, Laboratory 13 MB, AI 5.5 MB, DesignStuff 4 MB, Day_Scripts 4 MB, Sound 4 MB, DesignMain 0.7 MB,
         Quests 91 KB, Day_Culling 28 KB
```

What this settles: AssetRipper 2.0.0 reconstructs BSG's 2022.3.43f1 scenes intact (14/14, no dependency holes with the closure, Mono scripts resolved, terrain and navmesh assets present). Cost per map is fixed by the closure, not the map: ~18 s load + ~11 min export + ~30 GB out (the 93k meshes are the whole game's, exported once per map). For `-Maps all` that is 13 x 30 GB = ~390 GB and ~2.5 h — or one whole-`_Data` load (22.6 GB) and one export with all 558 scenes (~same assets + 544 more scene files), which is the better shape and still needs an export-filter that the free build lacks. Unverified: the 93 missing scripts in `Factory_Rework_AI` (likely generic/obfuscated `CG_*` MonoBehaviours the decompiler skipped — inspect before phase 1), lightmap format, whether Unity opens the 30 GB project without choking on 97k `.asset` imports (expect a long first import; put `Library\` on D:).

Fixes that came out of the run (all in `rip.ps1`): the launch line, the async done-signals, the closure staging, and — found on this run — `[IO.File]::ReadAllText` on the redirected stdout log is DENIED while PowerShell holds it (the load finished in 18 s and the poller spun for minutes reporting an empty last line, because the exception was swallowed: a check that could not fail). Now `FileShare.ReadWrite`, and an unreadable log is a hard `Fail`, never "still loading". The export for this run was therefore driven by hand against the loaded instance (`POST /Export/UnityProject`), and the census by hand; the script's own end-to-end path with the fix is **not yet exercised** — the next `-Maps Woods` run is that test.

---

## 3. Re-import, honestly

### 3a. Unity project version and what breaks

* Use **Unity 2022.3.43f1** (installed). A scene bundle built by any other editor version is refused or mis-deserialised by the 2022.3.43f1 player; prefabs/MonoBehaviour layouts must match too.
* **Shaders**: the free AssetRipper exports dummies, and EFT's shaders are stripped/custom (the 378 MB `shaders` bundle). Two workable routes, both unverified on this game: (1) at runtime, load the game's own `shaders` bundle (it is already loaded — every bundle depends on it) and remap each material by shader NAME through `Shader.Find` after the custom scene loads (a small `MonoBehaviour`/plugin pass); (2) in the editor, replace every dummy with `Standard`/URP-less built-in shaders for authoring, accept flat lighting, and do (1) anyway on load. Route (1) is the one that keeps BSG's look.
* **Scripts**: exported scenes reference `Assembly-CSharp` MonoBehaviours (`LocationScene`, `BotZone`, `SpawnPointMarker`, `ExfiltrationPoint`, `LootableContainer`, `WorldInteractiveObject`, `NavMeshDoorLink`, `Streamer`, PerfectCulling `BakeInformation`...). For the bundle to keep them, the Unity project must contain an assembly with the SAME name and the same serialised field layouts. Practical approach used by SPT modders (and the one WTT/Custom-item bundles rely on): drop the stock `Assembly-CSharp.dll` (plus its dependencies from `Managed\`) into `Assets\Plugins\` as a **plugin DLL** so `[MonoScript]` references resolve by (assembly, namespace, class) at build time; do NOT use `ScriptExportMode=Decompiled` for the whole game (16 MB DLL, obfuscated `CG_*` names, will not compile). `Hybrid` (default) is the right setting: it decompiles what it can and keeps the DLL. Scripts that fail to resolve become `Missing (Mono Script)` and are silently dropped from the bundle — a check that must be run: after building the bundle, count `LocationScene`/`BotZone`/`SpawnPointMarker` components in the loaded scene (`LocationScene.LoadedScenes`, `Object.FindObjectsOfType`) and compare with the exported YAML count. A count of 0 is the expected first failure.
* **Occlusion / culling**: PerfectCulling data is in `Culling_Data\<guid>_packed_cull.bytes` keyed by a baked guid; a merged scene will not match any bake -> disable auto culling (`OcculsionCullingEnabled` in base.json is a server flag) or accept the performance hit. Unity's own `OcclusionCullingData` per scene cannot be merged across offsets either. Plan: none in phase 1.
* **Lightmaps**: exported as EXR per scene with `LightmapSettings`; lightmap indices are per scene, so additive loading of several scenes keeps each scene's lightmaps (Unity supports that) — but a MERGED single scene would need a rebake (hours at BSG quality, days for Streets). Keep the maps as SEPARATE scenes loaded additively at offsets (see 3b); do not physically merge geometry.
* **NavMesh**: each `*_AI` scene ships a `NavMeshData` for its map at its original origin. `NavMesh.AddNavMeshData(data, position, rotation)` accepts an offset — so translated navmeshes work without a rebake, as long as nothing bridges between maps (bridges need a small baked connector piece or `OffMeshLink`s). DrakiaXYZ-Waypoints (installed under `BepInEx\plugins\DrakiaXYZ-Waypoints`) already loads extra navmesh bundles per map at runtime — the exact API it uses is **unverified** (README fetch 404'd); read its source before writing a loader.
* **Terrain**: 6 terrain scenes; `TerrainData` export is supported by AssetRipper in principle; whether EFT's terrain is stock `Terrain` or a custom mesh terrain is unverified until the first rip.

### 3b. Stitching into ONE world

* **Do not merge scenes into one `.unity`**. Load each map's scenes additively at a **world offset**: wrap each map's root objects in one `Transform` (`<map>_root`) and set its position; NavMesh data gets the same offset via `AddNavMeshData`; lightmaps and light probes survive because they stay per scene. The Streets `Streamer` proves the engine side already loads/unloads chunks additively around the player.
* **Footprints** (measured extents from `SpawnPointParams` on the server, x/z metres; **inferred** as playable area, real geometry is bigger): factory4_day 120 x 137; the others need the same one-liner (`python` over `base.json`) — numbers not computed here for all 13. Woods/Shoreline/Lighthouse/Streets/Customs are each on the order of 1-2 km; a grid layout with 500 m gaps between footprints and one map per cell is the safe first layout (no overlaps in y either: Labs is at negative y, Reserve has deep basements — offset y by +0 and check `SpawnPointParams.y` ranges).
* **Loading budget**: all 13 at once is ~22 GB of scene data — the client cannot hold that. The world must stream: keep a 3x3 neighbourhood loaded, unload the rest (`ModernLoadScenesFromPreset.UnloadScene(name)` exists; or drive `SceneManager.UnloadSceneAsync` yourself). Phase 3 problem; phase 1 is one map.
* Cross-map travel = an `ExfiltrationPoint`/`TransitPoint` replaced by a plain trigger that shifts the streaming window; the game's own `transits` (in `base.json`, `LocationTransit`) are server round-trips and not needed once there is no raid boundary.

### 3c. Loading a custom scene bundle at runtime (BepInEx, Mono)

Community state (searched 2026-09-07): **no maintained SPT mod loads a new playable location.** WTT-CommonLib (the big content lib) explicitly has no custom-location service — it adds zones/spawns/loot INTO existing maps. The only public attempt (KleskBY, "Loading custom maps in EFT — stalker mod", Unity 2018 era) loaded a prefab bundle from a dnSpy-patched `PlayerCameraController.Update` and abandoned it on navmesh/ballistics problems. So this is new ground; the measured loader chain in 1.4/1.5 says how to do it without patching the loader:

1. **Build** in 2022.3.43f1: `BuildPipeline.BuildAssetBundles` with the scene(s) in one bundle (a scene bundle; Unity sets `m_IsStreamedSceneAssetBundle`), plus a second tiny bundle containing a `ScenesPreset` ScriptableObject — or, simpler and fully in the mod's hands, **do not use a preset at all** (step 3).
2. **Ship** via SPT's bundle system: `user\mods\<yourServerMod>\bundles.json` with `{"manifest":[{"key":"maps/basement_world.bundle","dependencyKeys":["shaders","cubemaps"]}]}` and the file under the mod's `bundles\` dir (path convention per `BundleManager.GetBundleFilePath`, unverified). `spt-custom`'s `EasyAssetsPatch` merges it into the client manifest at boot.
3. **Load** from the BepInEx plugin (`Basement.Client`, already targets `D:\SPT415`): the least invasive is a prefix on `TarkovApplication.LoadMapAndData(ScenePresetLoadConfig, ...)` (or on `CG_LocalGameMatching` where `ScenePresetLoadConfig` is constructed) that replaces `config.key` with a `ResourceKey{path="maps/basement_preset.bundle", rcid="basement.ScenesPreset.asset"}` whose preset's `_scenesResourceKeys[i].path` = the scene-bundle key. Then the game's own `LoadSceneOperation` does `LoadBundleAsync(key)` + `LoadSceneAsync("<scene>")`, `GameWorld.InitLevel` runs, and `LocationScene` registration happens exactly as for a stock map. If a preset-in-a-bundle proves awkward, the fallback is a postfix after `LoadScenesFromPreset` that `AssetBundle.LoadFromFileAsync` + `SceneManager.LoadSceneAsync(name, Additive)` the extra scene(s) yourself before `InitLevel` — `InitLevel` only sees what `LocationScene.LoadedScenes` registered.
4. **Server entry**: `SPTarkov.Server.Core.Models.Spt.Tables.LocationTable` is a **record with one fixed property per location** (`Factory4Day, Bigmap, ..., Terminal, Town, Develop, PrivateArea, Suburbs`), `HydrateDictionary()` builds the id->Location dictionary by **reflection over those properties** (`Type.GetProperties()` measured), and `Enums.ELocationName` is fixed (12 names + `any`). **A brand-new location id cannot be added by dropping a folder into `database\locations\`.** Two honest options: (a) **hijack a slot** — `develop` (Arena, `Enabled:false`, 3 scenes) or `terminal`/`suburbs`/`town` (empty `Scene`) — by editing that `base.json` (`Enabled:true`, `Scene.path/rcid` -> your preset, your `SpawnPointParams`/`exits`/`waves`, `Name`); the client selects it as any raid; (b) a C# server mod (`IOnLoad.OnLoadAsync`, the shape `BlackDivServer.dll` uses) that sets `locationTable.Develop = yourLocation` at load — same slot, done in code. For EscapeFromMyBasement, which never shows the map-select screen, slot `develop` is enough for every phase: the plugin always starts a raid on `develop`, and everything else is the world streaming inside that one "location".
5. `base.json` fields the client consumes on load (names measured in `JsonType.LocationSettings/Location`, 100 fields; list in `Location_fields.txt`): the ones that matter first are `Id, _Id, Name, Enabled, Scene, SpawnPointParams, exits, MaxPlayers, EscapeTimeLimit, waves/BossLocationSpawn (empty is fine), OcculsionCullingEnabled:false, Loot: []`.

### 3d. Legal / practical

The ripped assets are BSG's copyrighted content. Keep everything under `D:\aowlspt-maprip\` and the resulting bundles **out of the repo, out of Discord, out of any release** — a distributed mod must ship only the plugin and a script that rebuilds the world bundle on the user's machine from THEIR game files (this `rip.ps1` is the first half of that). `.gitignore` `D:\aowlspt-maprip` is not needed (outside the repo) but never point a repo path at it.

---

## 4. Phased plan

| phase | what | falsifiable exit check | effort (estimate) |
|---|---|---|---|
| 0 | run `rip.ps1 -DryRun`, then `rip.ps1` (factory4_day only) | PASS line: 14/14 `.unity` exported; open `D:\aowlspt-maprip\factory4_day` in 2022.3.43f1, `Factory_Rework_Main_Building.unity` shows geometry; count `Missing (Mono Script)` components | 1-2 h wall, mostly export time |
| 1 | shaders + scripts: `Assembly-CSharp.dll` as plugin; build ONE scene bundle of the 14 factory scenes; write `maps/basement_preset` (or the additive-load fallback) | `LocationScene.LoadedScenes.Count == 14` in the BepInEx log after entering `develop`; bots spawn (`BotZone` count > 0); at least one `ExfiltrationPoint` works | 2-4 days |
| 2 | the loader: hijack slot `develop` (base.json + `bundles.json` + prefix on `LoadMapAndData`) so a raid on `develop` loads the custom bundle; material remap from the loaded `shaders` bundle | walking Factory in-game from a custom bundle, textures not pink, navmesh works (bot reaches you) | 2-3 days |
| 3 | rip all 13 (`-Maps all`), per-map root transform + offset table, `AddNavMeshData` with offset, streaming window (load neighbours, unload far) | two maps loaded at once at different offsets, walk from one to the other over a connector piece, no z-fight/overlap, memory < 16 GB | 1-2 weeks |
| 4 | basement world logic on top (spawns from `/world/people`, no exits, no timer) | `EscapeTimeLimit` irrelevant, raid never ends; the existing `basement_check.py` story passes in-world | separate track |

**First thing to try (the milestone that can fail):** `powershell -ExecutionPolicy Bypass -File tools\maprip\rip.ps1` — factory4_day, 14 scenes, 0.21 GB — then load the exported `Factory_Rework_Main_Building.unity` in the 2022.3.43f1 editor. If it exports 14/14 and the scene renders (even pink), phases 1-2 are engineering; if AssetRipper cannot reconstruct BSG's scenes at all, the plan pivots to AssetStudio meshes + hand-rebuilt scenes and the estimate triples. That question costs one script run.

---

## 5. Things measured that were surprising (record for AOWL_FACTS)

* `strings` on `globalgamemanagers` returns 420 of the 558 BuildSettings scene paths and in a DIFFERENT order than the real build indices — a `strings`-derived `level{N}` map is wrong; parse `BuildSettings.scenes` (UnityPy, `read_typetree`).
* `factory4_day` uses the **`Factory_Rework_*`** scenes (14), not `Factory.unity`(285 MB)/`Factory_Day.unity`; the old Factory scenes are still in the build but no preset references them.
* `customs_preset.bundle` contains a second preset with `ServerName='Lighthouse'` (1 scene) — a leftover; `factory_night_preset.bundle` contains a child with `ServerName='factory4_day'`. `ServerName` is per preset object, so `grep`ing bundles for a server name over-matches.
* `hideout/base.json` points at `maps/bunker_preset.bundle`, which does not exist in `StreamingAssets\Windows\maps\` (the hideout loads via `ModernLoadScenesFromPreset` from elsewhere; not chased).
* SPT 4.1.5's `LocationTable` is a fixed-property record hydrated by reflection: location ids are closed; hijack a slot or write a server mod.
* AssetRipper 2.0.0 has no export CLI but a full OpenAPI HTTP surface (`/openapi.json`) — headless automation is a form POST.
* The Windows Store `python.exe` on this machine has pip (3.13.14); the MSYS `python` has none. UnityPy installed into the former (`--user`).

Scratchpad artefacts backing this doc (session-local, not committed): `buildsettings_scenes.json`, `scene_sizes.tsv`, `presets.txt`/`presets.json`, `Location_fields.txt`, `ar/openapi.json`.
