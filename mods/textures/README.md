# aowl.textures — high-res PBR texture replacement

The aowlspt port and overhaul of the **TarkovTextures** project: swap stock EFT
textures for higher-quality [ambientcg](https://ambientcg.com) PBR sets. The
original was a BepInEx/Harmony plugin; post-1.0 Tarkov is IL2CPP with no
BepInEx, so this does the same job through the aowlspt host's native postfix
detour.

```
aowl build-mod mods/textures     # compile the client mod (a .dll)
aowl run mods/textures           # offline self-test — no game, no runtime
```

## The two halves

This mod is deliberately split into an **offline pipeline** and a **client
runtime**, because the expensive, iterable work (curating and mapping textures)
has no business happening in the game process.

### 1. Offline pipeline — `pipeline/build_pack.py`

Reads a `TarkovTextures` tree and emits `data/manifest.json`, the curated
`name → replacement` table this mod loads. See `pipeline/README.md` for the full
flow. In one line:

```
python pipeline/build_pack.py --per-cat 120 --min-conf 0.5 --tier 2K
```

`data/manifest.json` in this repo is the committed output of that command: **512
curated replacements** across Metal, Wood, Concrete, Brick, Fabric and Ground,
each pointing at the correct ambientcg PBR map (`Color` / `NormalDX` /
`Roughness` / `AmbientOcclusion`) for the BSG texture's map type.

### 2. Client runtime — this mod

- `textures.nim` — lifecycle, config, the F12 settings schema, VRAM reporting.
- `manifest.nim` — loads `data/manifest.json`, answers `lookup(name)` (binary
  search over the sorted, lowercased names).
- `swap.nim` — the two postfix hooks and the name-match + VRAM-budget logic.

## How a texture is replaced (the IL2CPP port)

The original plugin was two Harmony **postfix** patches:

```csharp
[HarmonyPatch(typeof(AssetBundle),        nameof(AssetBundle.LoadAsset), ...)]
[HarmonyPatch(typeof(AssetBundleRequest), "asset", MethodType.Getter)]
```

each reading the returned `Texture2D`, matching it **by name**, and swapping
`__result` for a `Texture2D` built from a loose image via `LoadImage` + `Apply`.

The aowlspt host exposes exactly the primitive those patches used —
`hookReturn`, a postfix x64 detour that is handed the return value and may
replace it. So `swap.nim` installs the same two interceptions:

```
UnityEngine.AssetBundle::LoadAsset         (sync bundle load)
UnityEngine.AssetBundleRequest::get_asset  (async bundle load)
```

The postfix reads the returned object, calls `get_name` on it, lowercases,
looks the name up in the manifest, and — on a hit within the VRAM budget — is
positioned to build the replacement `Texture2D` and `replaceResult` with it.
Crucially, these methods run **on the Unity main thread** (the game calls them
there), which is the only thread on which a texture may legally be created and
uploaded — so the swap site satisfies the thread affinity for free, and the
bridge's per-frame drain (`onMainThread`) is available for any deferred work.

## What works today vs what waits on a named capability

| | status |
|---|---|
| Offline pipeline + curated 512-entry tiered manifest | **working** (committed output) |
| Manifest load, name lookup, VRAM budgeting | **working** (`aowl run` self-test) |
| Postfix hook registration on the two targets | **coded**, NO-OP if the detour can't bind |
| Name-match of intercepted textures against the manifest | **coded** — runs live once hooks bind |
| Building a `Texture2D` from image bytes and swapping it | **waits on one ABI capability** |

The **name-match half is fully expressible** and, once the hooks bind, proves
live in a raid that the mod is intercepting the right texture loads and that the
curated set matches them — it logs every texture it *would* swap.

The **pixel-upload half needs `il2cpp_array_new`** (a managed `byte[]` to hand
`UnityEngine.ImageConversion::LoadImage`) plus a mod-side file read of the
replacement image. Neither is bound on the mod ABI yet
(`aowl/src/aowlspt/il2cpp.nim` has no `arrayNew`, no `readFile`). Until they
are, `swap.nim`'s `gCanUpload` stays false and the postfix returns
`keepResult()` — the game keeps its stock texture. This is the same honest
posture `mods/fov` and `mods/perf` take toward capabilities they await.

A second unknown: whether the two targets **detour by name** on the hardened
1.1.0.1.46777 build at all. `abi/aowlspt_bridge.h` documents that
`MethodInfo.methodPointer` is null for many methods on this build, so a by-name
`patch` can fail to bind. If it does, `armSwap` records the refusal and the mod
NO-OPs. The durable fix, as with the bridge's `TarkovApplication::Update`, is a
static RVA for `UnityEngine.AssetBundle::LoadAsset` for this exact build.

## VRAM

A 2K texture decoded to RGBA32 with a mip chain is **~22 MB of VRAM**. The
curated manifest holds ~500 candidates; swapping them all uncompressed would be
~11 GB. So the mod is bounded by a **hard VRAM budget** (`vramBudgetMB`, default
1024 → ~48 resident 2K textures): it arms textures until the projected budget is
spent, then stops. The manifest is the soft bound (which textures *may* be
swapped); the budget is the hard one (how many become resident).

The real remedy for the per-texture cost is **block compression** (BC7/BC1) in
the pipeline or on upload — the next pipeline step. Until then the budget keeps
the resident set sane by count. `catGround` is off by default because terrain
covers huge screen area and is the heaviest surface class on VRAM.

## Settings (`config.json` / F12 panel)

| key | default | meaning |
|---|---|---|
| `enabled` | `true` | master switch; off installs no hooks |
| `quality` | `"2k"` | `off` / `2k` / `4k` (4K degrades to 2K when absent) |
| `vramBudgetMB` | `1024` | hard resident-VRAM cap |
| `minConfidence` | `0.5` | runtime name-match confidence floor |
| `logMatches` | `true` | log each texture the mod would swap |
| `catMetal … catGround` | see file | per-surface toggles (`catGround` off) |
| `packRoot` | `""` | where replacement images live; empty → `data/pack` |

## Safe by default

No manifest, no bound hook, no upload capability, an empty category set, or a
spent VRAM budget all resolve to the same outcome: **stock textures, no crash.**
Every path is guarded.
