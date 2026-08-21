# ambientCG Overhaul — aowlspt resource pack

> **SCHEMA: `aowlspt.resourcepack` v1** — this pack's `manifest.json` is
> reconciled to the final schema (see
> [`../RESOURCE_PACK_SCHEMA.md`](../RESOURCE_PACK_SCHEMA.md)). Regenerate any time
> with `.\assemble.ps1 -RegenManifest`.

A revamped, **non-Tarkov-style** PBR surface overhaul. Replaces metal, wood,
concrete, brick, fabric, and ground surfaces with clean, high-detail
physically-based materials from [ambientCG](https://ambientcg.com). This is a
deliberately different aesthetic from stock BSG textures — brighter, sharper,
more "studio PBR" than "grimy Tarkov".

- **Capabilities:** `["textures"]`
- **Assets:** 512 curated texture rows (Metal, Wood, Concrete, Brick, Fabric, Ground)
- **Tier:** 2K (JPG PBR maps: albedo / normal / roughness / AO / etc.)
- **License:** CC0-1.0 — public domain, freely redistributable
  (see [`LICENSE-ASSETS.txt`](LICENSE-ASSETS.txt))

## What is committed vs. assembled on demand

The ambientCG images total **~2.2 GB**, far too large to commit. So git holds:

| Committed | Assembled on demand (not committed) |
|-----------|--------------------------------------|
| `manifest.json` (512 texture rows, ~84 KB) | `assets/**` — the 512 image files |
| `assemble.ps1`, `assemble_pack.py` | |
| README + license | |

`assets/` copies are a **pure copy** of exactly the files `manifest.json` lists,
so the assembled tree always matches the manifest.

## How to build the full pack (one command)

You need the ambientCG source tree locally — the same `TarkovTextures/` tree the
`mods/textures` pipeline uses (with `ambientcg/<Category>/<Material>/...` maps).

```powershell
# from packs/ambientcg-overhaul
.\assemble.ps1                       # auto-detects TarkovTextures (sibling of the
                                     #   repo, or mods/textures config.json packRoot)
.\assemble.ps1 -Src D:\TarkovTextures   # or point it explicitly
```

This copies the 512 referenced images into `.\assets\<Cat>\<Material>\<file>.jpg`.
It is idempotent and resumable (already-copied files are skipped), so you can
re-run it safely.

Requirement: **Python 3** on `PATH`. No other dependency.

## How to install

1. Assemble the pack (above), so `assets/` is populated.
2. Copy the whole `ambientcg-overhaul/` directory into your SPT install's
   resource-packs location per the `feat-resource-packs` loader
   (`mods/resourcepacks/RESOURCE_PACKS.md`).
3. Enable it and boot.

### Bridging to the `mods/textures` mod

The existing `mods/textures` mod can consume these same assets directly: point
its `config.json` `packRoot` at this pack's `assets/` directory. This pack's
`manifest.json` is `mods/textures/data/manifest.json` wrapped in the
`aowlspt.resourcepack` v1 shape with `assets/`-relative paths — the per-asset
`textures[]` rows (`name`/`file`/`map`/`cat`/`tier`/`conf`) are identical to what
the mod matches on. Regenerate the wrapped manifest any time with
`.\assemble.ps1 -RegenManifest`.
