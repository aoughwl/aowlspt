# Texture pack pipeline

Turns a `TarkovTextures` tree into `../data/manifest.json` — the curated,
quality-tiered `name → replacement` table the `aowl.textures` mod loads.

## Source tree (`TarkovTextures/`)

The original project's data, produced by its own scripts (kept as-is):

- `extract/` — ~14k BSG textures extracted from the game bundles (PNG), via
  AssetStudioModCLI.
- `ambientcg/<Category>/<Material>/` — high-quality PBR sets downloaded from
  ambientcg. Each material folder has a colour **preview** `<Name>.png` plus the
  real maps as **JPG**: `<Name>_2K-JPG_Color.jpg`, `_NormalDX.jpg`,
  `_NormalGL.jpg`, `_Roughness.jpg`, `_AmbientOcclusion.jpg`, `_Displacement.jpg`.
  Six categories: Metal, Wood, Concrete, Brick, Fabric, Ground.
- `output/match_report.json` — the original matcher's output: for each BSG
  texture, the best-guess ambientcg material by name/category similarity
  (difflib), with a `confidence`, `category`, and `bsg_suffix`
  (`_d`/`_n`/`_g`/`_ao`/…).

## `build_pack.py`

Consumes `match_report.json` and emits a compact `manifest.json`.

```
python build_pack.py --per-cat 120 --min-conf 0.5 --tier 2K
python build_pack.py --copy ../data/pack        # also assemble a self-contained pack
```

For each matched, above-threshold BSG texture it:

1. finds the ambientcg material folder,
2. **resolves the correct PBR map for the texture's BSG suffix** — `_n` →
   `NormalDX`, `_g`/`_r` → `Roughness`, `_ao` → `AmbientOcclusion`, `_d`/unknown
   → `Color` — from the real `.jpg` files at the requested tier,
3. records `{name, file, map, cat, tier, conf}`, keyed by the lowercased Unity
   texture name.

It curates (highest-confidence N per category) and emits the entries sorted by
name so the mod can binary-search them.

## What this overhauls vs the original

The original BepInEx pipeline had three load-bearing bugs, all in map
resolution — this script fixes each:

1. **Wrong extension/tokens.** The C# plugin's `PickBestReplacementFile` searched
   `*.png` for tokens like `_COL_`/`_NRM_`, but the real maps are `.jpg` named
   `_Color`/`_NormalDX`. It never hit, so **every** swap fell back to the single
   colour preview PNG — normal and roughness slots got an albedo image. This
   script resolves the actual `.jpg` maps by their real tokens.
2. **Matcher ignored the maps.** `Match-Textures.py` only indexed `.png`. The
   overhaul reads the `.jpg` maps directly from each material folder.
3. **Threshold mismatch.** Report generated at 0.3, plugin filtered at 0.5. Here
   the floor is one `--min-conf` flag, applied once.

Verify the fix in the committed manifest: `am_rock_01_d/_g/_n` resolve to
`Rocks011_2K-JPG_Color / _Roughness / _NormalDX.jpg` respectively — three
different, correct maps, not three copies of a preview.

## Tiers, deployment, and future work

- **Tiers.** Only 2K maps are present in the source tree today; `--tier 4K`
  degrades to 2K per-map when a 4K file is absent. Fetching 4K is a change to the
  original `Download-AmbientCG.py` (request the 4K zip).
- **Deployment.** By default the manifest stores paths relative to the
  `TarkovTextures` root, and the mod's `packRoot` points there — no copying, good
  for iteration. `--copy PACKDIR` instead assembles a self-contained pack
  (`<cat>/<material>/<file>`) and rewrites paths relative to it, for shipping the
  pack independently. Point the mod's `packRoot` at that directory.
- **Next steps.** (a) Block-compress the maps (BC7/BC1) so the VRAM-per-texture
  cost drops ~4× and the resident set can grow; (b) green-channel-flip GL→DX
  normals where a source ships only `NormalGL`; (c) a specular→roughness
  conversion for BSG's specular-workflow textures (ambientcg is metal/rough).

---

## The other route: in-place asset patching

`resspatch.py` + `makedds.py` replace texture bytes directly inside the shipped
`.assets`/`.resS` pair, instead of swapping at runtime. **See
[RESSPATCH.md](RESSPATCH.md) before running any of it** — the shipped files are
hardlinked to the real Tarkov install, and writing one in place corrupts the
other.
