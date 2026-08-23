# Reaching the real terrain — and the rest of the map

Last round concluded terrain was out of reach: the textures live in `.assets`, not
AssetBundles, so the `EasyBundle._path` redirect cannot see them, and they are all in
`ConsistencyInfo`. Both halves were true. Neither is fatal.

`ConsistencyInfo` is re-syncable, and — more importantly — **`.assets` did not need
to be rewritten at all.** Every texture's pixels live in a sibling `.resS` at a fixed
offset with a fixed size, so a replacement of exactly the same length is a
seek-and-write. The `.assets` files stay byte-identical and every `.resS` keeps its
size; only a checksum changes.

| file | what it does |
|---|---|
| `assets_identity.py` | the `.assets` round-trip identity control |
| `assets_objbytes.py` | per-object raw-byte comparison of two `.assets` |
| `assets_diffhdr.py` | decodes a SerializedFile header, locates differing ranges |
| `terrain_probe.py` | TerrainData → TerrainLayer → albedo, by reference not by name |
| `microsplat_probe.py` | finds what the terrain shader actually samples |
| `slice_control.py` | proves the array slice index ↔ layer mapping |
| `tarray.py` | block-compressed mip arithmetic, encode/decode, alpha carry |
| `terrain_build.py` | writes the 18 terrain albedo arrays |
| `terrain_verify.py` / `terrain_negcontrol.py` | six checks; three wrong packs |
| `assets_inventory.py` | full Texture2D census of the serialized files |
| `assets_scope.py` | scopes that census to prefab surfaces |
| `assets_build.py` | emits a patch-blob pack |
| `assets_verify.py` / `assets_negcontrol.py` | six checks; three wrong packs |
| `consistency.py` | verify / show / re-sync `ConsistencyInfo` |
| `apply.py` | the only writer. Dry-run unless `--commit` |

```bash
cd texpipe
.venv/Scripts/python.exe terrain_build.py  --out ../out/terrain-pack
.venv/Scripts/python.exe terrain_verify.py --pack ../out/terrain-pack --rgb-min 5.0
.venv/Scripts/python.exe assets_inventory.py --out ../out/inv-assets.json
.venv/Scripts/python.exe assets_scope.py   --json ../out/worklist-assets.json
.venv/Scripts/python.exe assets_build.py   --out ../out/assets-pack
.venv/Scripts/python.exe assets_verify.py  --pack ../out/assets-pack --rgb-min 4.0
.venv/Scripts/python.exe apply.py --terrain ../out/terrain-pack --assets ../out/assets-pack
```

## Feasibility, answered before building

**Does UnityPy round-trip a `.assets` safely? MEASURED — content-preserving, but not
byte-identical, and we ended up not needing it.**

`sharedassets140` round-trips byte-identical. `sharedassets165` comes back 4 bytes
longer: the header's `file_size` field, plus four trailing zero pad bytes, and
nothing else. `sharedassets161` is the interesting one — it comes back 4 bytes longer
*and* **relocates 4,896 of its 9,356 objects**, moving the first object (a 48-byte
`LightManager`) to the end and decrementing every other `byte_start` by 48.

That looks alarming and is in fact self-consistent: `assets_objbytes.py` parses the
ObjectInfo table out of both files and compares every object's raw bytes at its own
recorded offset. All 9,356 payloads are identical, 0 differ, 0 changed size. So the
re-serialisation preserves content. It is still not something to lean on, and the
`.resS` method means we never do: **`sharedassets17.assets` is never opened for
writing.**

**Does the client check anything beyond size + checksum? NOT DETERMINED OFFLINE.**

`ConsistencyInfo` size+checksum is the only integrity manifest found, and the
checksum formula is now verified on 128 files. But whether the launcher or BattlEye
performs an additional check — a signature, a per-asset hash — **cannot be settled by
reading files**. No BattlEye behaviour was tested. This is a live test and it belongs
to the coordinating session. Treat the first `--commit` as an experiment with a known
rollback, not as a deploy.

**What are the terrain textures really? MEASURED — and the obvious answer was wrong.**

`SplatAlpha 0/1/2` are splat control maps: per-channel blend weights, no colour.
Replacing them is meaningless, as the brief said.

The 12 `microsplat_layer_*` Texture2Ds *look* like the answer — `Grass_summer_D`,
`Gravel_Road_A_summer_D` and so on, resolved properly through
`TerrainData.m_SplatDatabase.m_TerrainLayers → TerrainLayer.m_DiffuseTexture`. They
are not. Every layer is a **MicroSplat** layer, and MicroSplat does not sample
`TerrainLayer.m_DiffuseTexture` at runtime; it bakes the layers into a
`Texture2DArray` and the shader samples that.

`microsplat_probe.py` reads the materials' `_Diffuse` binding and confirms it:

```
MicroSplat_HQ_summer  _Diffuse -> MicroSplatConfig_summer_diff_tarray          1024 x12
MicroSplat_NQ_summer  _Diffuse -> MicroSplatConfig_summer_diff_NormalTex_tarray 512 x12
MicroSplat_LQ_summer  _Diffuse -> MicroSplatConfig_summer_diff_LowTex_tarray    256 x12
```

Patching the 12 named Texture2Ds would have been a perfectly measurable change that
altered nothing on screen — the false positive this pipeline exists to avoid.

## Quality tiers

**The game already ships three, and they are the setting the brief asked for.**
`MicroSplat_HQ / NQ / LQ` per season — 1024 / 512 / 256, twelve slices each. All
three are filled, so whichever the terrain-quality setting selects is replaced.

**Separate 1K / 2K / 4K packs would ship the same pack three times.** Slot dimensions
are fixed by the original (an in-place patch must produce the same byte count), so a
4K source into a 1024 slot *is* a 1024 texture. `tier_measure.py` encodes the same
set into the same slot from each tier: the largest pairwise difference is **1.41**
mean-abs RGB against an identity-control noise floor of **2.6**. Below noise.

Policy: `--source-tier auto` picks the smallest ambientCG tier ≥ the slot and
downscales with Lanczos. **Upscaling is refused**, not silently interpolated.

**Enlarging a slot is possible and is not done.** We control both `Size` and
`Checksum`, so a bigger `.resS` could be made to pass. A 4096 terrain array would be
~16x the VRAM of the 1024 one, per season, and none of it has been tested. Refused.

## What landed

**Terrain** — 15 arrays, **180 slices**, 5 seasons x 3 tiers, one file:

* refused: **18** `normSAO` arrays (normal/smoothness/AO — data, not colour)
* skipped: **3** winter arrays. The library has **zero** snow sets, so every winter
  slice would become the palest available dirt and the map would lose its snow.
  `--seasons all` overrides this knowingly.
* `.resS` size 335,384,064 → 335,384,064, unchanged.

**Prefab surfaces** — **745** textures across **178** `.resS`, 734 distinct stems.
Suffix-confirmed albedo only; `--allow-unsuffixed` raises it to 1,248 by including
name-guesses, which is why it is off by default.

Refusals are counted, not hidden: 3,731 normal, 2,519 specular/gloss, 84 AO, 81
emission, 68 mask, 36 metalness, 30 height; 850 in a format whose byte length we
cannot reproduce (BC7, RGBA32, RGB24, Alpha8, crunched); 58 with inline pixels; plus
decals, posters, graffiti and signage, which are alpha-masked artwork rather than
tiling surfaces.

**Library gaps, which are real and not substituted:** wood **121** (+1 plank), glass
**86**, snow **4**. ambientCG has 16 families here and none of them is wood.

## Thresholds are measured

|  | identity ceiling | pack floor | gate |
|---|---|---|---|
| terrain RGB | 2.6 | 8.2 | **5.0** |
| prefab RGB | 2.4 | 6.4 | **4.0** |
| prefab alpha | — | max 0.85 | **2.0** |

Both verifiers refuse to gate check 4/5 at all unless a threshold is passed, and say
so in words — a skipped check must not read as a pass.

All controls behave, 4/4 each:

```
terrain  [real] ACCEPT   [copy] 36/36 "did not change enough"
                         [identity] 36/36    [normsao] 3 data maps modified
prefab   [real] ACCEPT   [copy] 120/120 "did not change enough"
                         [identity] 120/120  [noalpha] 110 lost their alpha
```

The `noalpha` control is worth reading: alpha mean-abs-diff goes from a median of
0.50 to **219.44**. That is the measure of how many of these slots are alpha-cut
cards, and of how badly an opaque paste would break them.

## The hardlink

**`D:\Aowlspt\EscapeFromTarkov_Data\*` is hardlinked to `D:\Games\Tarkov\...`** —
link count 2, `fsutil hardlink list` confirms both paths. Writing through one
modifies the real Tarkov install. `apply.py` backs up, **deletes** the Aowlspt path
to break the link, writes a fresh file, and then re-reads the link count and aborts
if it is still 2. Nothing else in this pipeline can write to a game directory; they
all refuse an output path inside one.

## Not verified

* **Nothing has been loaded by the game.** No deploy, no launch. Whether the client
  accepts a re-checksummed `.resS` is untested, and whether BattlEye cares is
  **unknown** — that check was **not performed**, not passed.
* **Visual quality is unassessed.** These are measurably replacements. Whether a
  tiling ambientCG concrete reads correctly at Tarkov's scale, on geometry authored
  for a different texel density, is a human judgement no metric here makes.
* **Normals now disagree with albedo.** We replace colour and leave the original
  normal/AO/gloss. The relief will not match the new surface. That is a deliberate
  compromise, not a solved problem.
* **Only one map's terrain exists in these files** — 19 `Slice_R_C` tiles sharing
  one 12-layer palette. The other 15 `TerrainData` objects (`AI_Terrain_Customs`,
  `AI_Terrain_Shoreline`, `AITerrainWoods2_3`, `AI_Terrain_Reserv_*`) have **zero**
  layers; they are AI/collision proxies. Whether the remaining maps' terrain lives
  somewhere this pipeline has not looked is **not established**.
* **`unity/BundleCheck` has not been run** against any of this.
