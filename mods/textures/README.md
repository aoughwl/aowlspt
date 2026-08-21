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

## What works today vs what the live client must confirm

| | status |
|---|---|
| Offline pipeline + curated 512-entry tiered manifest | **working** (committed output) |
| Manifest load, name lookup, VRAM budgeting | **working** (`aowl run` self-test) |
| Postfix hook registration on the two targets | **coded**, NO-OP if the detour can't bind |
| Name-match of intercepted textures against the manifest | **coded** — runs live once hooks bind |
| Building a `Texture2D` from image bytes and swapping it | **implemented** (see below) |

**The upload path is now implemented end to end, entirely mod-side.** A mod DLL
runs in the game process, so `openIl2Cpp()` binds the loaded `GameAssembly.dll`
and the mod reaches the runtime directly (as `mods/fov` does). On a matched
texture, inside the postfix (Unity thread), `swap.nim`:

1. turns the returned texture handle into an address (`pointerOf`, the host's
   revision-3 live-pointer capability),
2. reads the replacement image bytes from disk (`readBuffer`, non-raising),
3. builds a managed `byte[]` with **`il2cpp_array_new`** — newly exposed through
   `aowl/src/aowlspt/il2cpp.nim` (entry `eArrayNew`) — and copies the bytes in,
4. calls **`UnityEngine.ImageConversion::LoadImage(Texture2D, byte[])`**, which
   decodes the image into the returned `Texture2D` **in place**, so every
   material already referencing it shows the high-res image — no return handle to
   replace, `keepResult()` is correct.

`probeUpload()` checks all four prerequisites at arm time (the `il2cpp_array_new`
export, the `System.Byte` class, a `LoadImage` binding, and `livePointersReady`)
and sets `gCanUpload`. If any is missing it logs why and the mod runs
**match-only** — reporting every texture it would swap while keeping stock
pixels. No host ABI change was needed: the only library change is the additive
`eArrayNew` runtime-table entry, and the byte-copy is a local `{.emit.}` in
`swap.nim` (so nothing the host or other worktrees are editing is touched).

**What the live client must still confirm:** (a) whether the two targets
**detour by name** on the hardened 1.1.0.1.46777 build — `abi/aowlspt_bridge.h`
notes `MethodInfo.methodPointer` is null for many methods, so a by-name `patch`
can fail; if it does, `armSwap` NO-OPs and the durable fix is a static RVA for
`UnityEngine.AssetBundle::LoadAsset` (resolvable with
`tools/il2cpp_resolve.py`). (b) that the bound `LoadImage` is the `byte[]`
overload and not a `NativeArray<byte>` one — the mod's arm log names which method
it bound, so this is a one-line live check.

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

## Deploying the pack

The mod reads two things at runtime: `data/manifest.json` (ships with the mod)
and the replacement **image files**, found under `packRoot`.

- **Committed manifest paths are relative to the `TarkovTextures` root**
  (`ambientcg/<Category>/<Material>/<file>.jpg`). So `config.json` ships with
  `packRoot` pointing at that root (`C:/Users/savant/Projects/TarkovTextures`) —
  on the dev machine the mod finds every image with no copy step.
- **For a portable install**, assemble a self-contained pack next to the mod and
  point `packRoot` at it (or leave it empty to use the `data/pack` fallback):

  ```
  python pipeline/build_pack.py --copy <install>/mods/textures/data/pack --tier 2K
  ```

  That copies only the ~512 referenced maps (deduplicated) and writes a
  pack-relative manifest. The deploy layout is then:

  ```
  <install>/mods/textures/
    textures.dll
    config.json            # packRoot: "" -> data/pack, or an absolute path
    data/manifest.json
    data/pack/<Category>/<Material>/<file>.jpg
  ```

  The client host sets `dataDir()` to `<install>/mods/textures/data`, so an empty
  `packRoot` resolves to `<install>/mods/textures/data/pack`.

`data/pack` is git-ignored (it is ~1 GB of images) and rebuilt by the command
above; only the manifest is committed.

## Safe by default

No manifest, no bound hook, no upload capability, an unreadable image file, an
empty category set, or a spent VRAM budget all resolve to the same outcome:
**stock textures, no crash.** Every path is guarded, and `probeUpload` decides
up front whether the pixels can be uploaded so the arm log tells the truth.
