# Re-targeting the pipeline at post-1.0 Escape From Tarkov

The patch-in-place approach in `README.md` is unchanged and is not relitigated here.
What changed is the target: `D:\Aowlspt\EscapeFromTarkov_Data\StreamingAssets\Windows`
instead of the SPT 4.1.2 install, and real ambientCG imagery instead of a hue tint.

| file | what it does |
|---|---|
| `inventory.py` | full `Texture2D` census of the post-1.0 bundle set, built from the bundles |
| `scope_post1.py` | scopes that inventory to in-raid world surfaces and matches ambientCG |
| `build_post1.py` | patches each bundle, writes the pack to a NEW directory |
| `verify_post1.py` | six checks, thresholds set from measurement |
| `negcontrol_post1.py` | three deliberately broken packs the verifier must reject |
| `probe_levels.py` | measures where terrain textures really are (answer: not in bundles) |

```bash
cd texpipe
.venv/Scripts/python.exe inventory.py    --out ../out/inv-post1-full.json --jobs 10   # 28 s
.venv/Scripts/python.exe scope_post1.py  --json ../out/worklist-post1.json
.venv/Scripts/python.exe build_post1.py  --out  ../out/post1-pack                     # 17 s
.venv/Scripts/python.exe verify_post1.py --out  ../out/post1-pack
.venv/Scripts/python.exe negcontrol_post1.py
```

## The measured numbers

Full scan, 2026-08-23, of all 7,560 keys in `Windows.json`, 0 errors:

```
628,554 objects   26,959 Texture2D   19,376 distinct names
DXT5 14,014  DXT1 10,824  BC7 1,360  RGBA32 309  RGB24 299  Alpha8 140  BC6H 12  DXT1Crunched 1
```

This is a different build from the 0.16.9 one fact #65 describes (22,978 `Texture2D`,
16,552 distinct names, 6,570 bundles), which is why nothing was salvaged from
`packs/ambientcg-overhaul` and everything here is re-derived.

Where those textures live, by bundle key prefix:

```
14,510 assets/content/items          6,264 assets/content/pocketmap
 2,228 assets/content/weapons        1,379 assets/content/characters
   881 assets/content/location_objects  709 assets/gpuinstancer/prototypedata
   612 assets/content/hands             23 assets/content/rock and boulders3
```

**The in-raid world is a small minority of the bundle set.** `location_objects` is
1.3 GB of 39 GB, and 608 of its 881 textures are the hideout — which is out of scope by
the brief, and which is exactly the region fact #65 found the old pack landing in.
Strip the hideout and lootables and the entire map-area bundle texture set is **236
textures over 51 distinct name stems**, almost all of it grass and foliage cards
(`Grass2_D`, `T_KrapivaLittle_A`, `romashka`, `grass_cut_dry`) plus a handful of props.

## Where the terrain actually is — and why we cannot reach it

`probe_levels.py` scanned the 25 largest serialized files in `EscapeFromTarkov_Data`
(5.1 GB, 4,827 `Texture2D`, 0 unreadable). The real terrain is there, not in bundles:
`SplatAlpha 0/1/2` (Unity `TerrainData` splat control maps, 1024x1024 RGBA32) in
`sharedassets140.assets` and `sharedassets165.assets`, `City_Asphalt_Trim_01` in
`sharedassets161.assets`, `Grass_02_512` in `sharedassets165.assets`.

Those are `.assets` files, not AssetBundles. The `EasyBundle._path` redirect (fact #82)
does not reach them, and every one is listed in `ConsistencyInfo` by size. Replacing
map terrain is therefore **out of reach of this pipeline as built**, and would need a
different mechanism entirely. Nothing here pretends otherwise.

## ConsistencyInfo

`D:\Aowlspt\ConsistencyInfo` has 10,599 entries; 8,398 are under `StreamingAssets` and
**7,561 are Windows bundle paths** — i.e. every key in `Windows.json`. Patching a bundle
in place changes its size and the client refuses to boot. **The redirect is mandatory,
not merely safer.** `build_post1.py` refuses outright to write under
`D:\Aowlspt\EscapeFromTarkov_Data` or `D:\SPT`.

## What gets replaced, and what is refused

963 textures are in scope; **123 are replaced**, in 123 bundles, over 25 stems, all DXT5.

Refusals are counted, not hidden:

* **709** GPU-instancer tree/bush impostor billboards. An ambientCG tiling surface is
  not a counterpart for a billboard atlas of a whole tree at any confidence.
* **116** normal / specular maps. Fact #36: only albedo is colour. We own no honest
  transform for a data map, so none is applied.
* **15** in scope and albedo, but with no keyword we trust (`scrap_d`,
  `plastic_suitcase_54_DIF`, `Pipeline_Fittings_D`, ...).

Two false positives this scoper exists to block, both found by reading its own output:

* `vetky5_big_terrain_AlbedoAlpha` matched the keyword `terrain`. It is a tree impostor
  ("vetky" = branches). `terrain` is deliberately absent from `FAMILY_RULES`; it
  produced 24 confidently wrong rows and zero right ones.
* `Field_grass_D_autumn` classified as map type "unsuffixed" because the seasonal suffix
  hides the `_D`. Season suffixes are stripped before map-type detection; the in-scope
  "unsuffixed" (i.e. guessed) bucket fell from 807 rows to 46.

There is no fuzzy matching anywhere. Fact #65 records that fuzzy matching at 0.75 on
this data returned nothing but noise.

## Format, mips, and alpha

Format, width, height and mip count are read from the original and re-asserted on the
result; the encode goes through `Texture2DConverter.image_to_texture2d` at the
original's format, and the full mip chain is regenerated. No RGBA32 blow-up: all 123
stay DXT5. The inventory is treated as the contract — if the live object disagrees with
it the row is skipped, not guessed at.

**Alpha is taken from the original, never from ambientCG.** Everything in scope is an
alpha-cut foliage card and an ambientCG `_Color` map is opaque, so a whole-image paste
would turn every grass billboard into a solid rectangle. This is the failure the
`opaque` negative control exists to catch.

## What the verifier checks, and why the thresholds are what they are

1. the set of `(PathID, type)` is identical to the original
2. every untouched object is byte-identical
3. name / width / height / `TextureFormat` / mip count preserved
4. `image_data` length equals what the format and mip chain demand, and pixels are
   inline rather than still pointing at the game's `.resS`
5. **RGB actually changed** — a no-op build fails here
6. **alpha preserved within tolerance** — the cutout mask survived

Checks 1-4 alone would be a green light from a comparison that compared nothing.

Thresholds are measured, not chosen by taste. The `identity` control (pipeline run end
to end writing the original image back) tops out at RGB mean-abs-diff **4.9** — that is
pure DXT5 re-encode loss — and the real pack's floor is **24.6**. `--rgb-min` sits at
12.0, in the gap. Alpha: identity control max 0.55, real pack max 0.55, tolerance 2.0.

Result on `out/post1-pack`: **123 bundles, 299 objects, 123 textures, 0 problems.**
RGB mean-abs-diff min 24.6 / median 50.4 / max 138.0. Alpha min 0.00 / median 0.00 /
max 0.55.

All three negative controls reject, each for its own reason, 123/123:

```
[copy]     "no inline image data"     123/123
[identity] "RGB did not change"       123/123, other=0
[opaque]   "alpha not preserved"      123/123, other=0
```

## Not verified

* **Nothing has been loaded by the game.** No deploy, no launch — that is the
  coordinating session's call. Whether the client accepts these bundles through the
  `EasyBundle._path` redirect is untested.
* **No Unity acceptance run.** `unity/BundleCheck` was pointed at the SPT 4.1.2 pack;
  it has not been run against this one. Unity 2022.3.43f1 may not be this build's
  version.
* **Visual quality is unassessed.** Substituting a tiling ambientCG `Grass` photo into
  an alpha-cut blade card keeps the silhouette but is a real aesthetic gamble; the
  blades will show fragments of a lawn photograph. It is measurably a replacement, which
  is a different claim from it looking good.
* **One pack for both builds is not achieved and, on this evidence, cannot be.** The
  bundle keys and texture names differ between 4.1.2 and post-1.0, and only 10.2% of the
  old pack's names existed even in 0.16.9. This pack is post-1.0 only.
