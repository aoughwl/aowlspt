# Vanilla 4K — aowlspt resource pack (GENERATOR)

> **SCHEMA: `aowlspt.resourcepack` v1** — the template and the generated
> `manifest.json` are reconciled to the final schema (see
> [`../RESOURCE_PACK_SCHEMA.md`](../RESOURCE_PACK_SCHEMA.md)).

Your **own** stock Tarkov textures, extracted from your local install and
AI-upscaled to 4K. Same vanilla look — just sharper. Nothing here changes the
art style; it only increases resolution.

## Why this pack ships no images

BSG's game textures are copyrighted — we must **not** distribute them. So this
pack ships **only** a generator script + a manifest template + docs. The script
runs on **your** machine, reads textures out of **your** installed game, upscales
them, and writes a pack locally. No copyrighted asset is ever in the distributed
pack, and nothing copyrighted leaves your PC.

| Committed (distributed) | Produced locally by you (never committed) |
|--------------------------|--------------------------------------------|
| `generate.ps1` | `work/extracted/**` — PNGs pulled from your bundles |
| `manifest.template.json` | `assets/**` — the 4K upscaled textures |
| `README.md` | `manifest.json` — filled from your upscaled files |

## Dependencies (download once — NOT bundled)

1. **Real-ESRGAN** (the one required upscaler) — portable, **no Python**:
   `realesrgan-ncnn-vulkan`, a single `.exe` plus a `models/` folder.
   Download: https://github.com/xinntao/Real-ESRGAN/releases
   (asset `realesrgan-ncnn-vulkan-*-windows.zip`). Needs a Vulkan-capable GPU.
2. **An asset extractor CLI** — to read Unity asset bundles. One of:
   - AssetStudioModCLI — https://github.com/aelurum/AssetStudio
   - AssetRipper — https://github.com/AssetRipper/AssetRipper

Put both on `PATH`, or in `.\tools\`, or pass `-Upscaler` / `-Extractor` paths.

## How to generate

```powershell
# from packs/vanilla-4k
.\generate.ps1 -Stage all
# or point everything explicitly:
.\generate.ps1 -Stage all `
  -TarkovDir "C:\Battlestate Games\EFT" `
  -Extractor "C:\tools\AssetStudioModCLI\AssetStudioModCLI.exe" `
  -Upscaler  "C:\tools\realesrgan\realesrgan-ncnn-vulkan.exe"
```

Stages (each idempotent, resumable — re-run any time, finished work is skipped):

| Stage | Does | External dep |
|-------|------|--------------|
| `extract` | dump Texture2D from your game bundles → `work/extracted/*.png` | extractor CLI |
| `upscale` | 4× each PNG → `assets/**` (skips already-done) | Real-ESRGAN |
| `manifest`| build `manifest.json` from `assets/**` | none |
| `all` | all three in order | both |

Run a single stage with `-Stage upscale` etc. to resume after an interruption.

## How to install

After `-Stage all` completes, this directory (`generate.ps1` +
`manifest.json` + `assets/`) is a complete resource pack. Copy it into your SPT
install's resource-packs location per the `feat-resource-packs` loader
(`mods/resourcepacks/RESOURCE_PACKS.md`). The `mods/textures` mod can also
consume it: point its `config.json` `packRoot` at this pack's `assets/`.

## Honest status — what is DONE vs NOT DONE

- **DONE / working:**
  - Staged, idempotent, resumable orchestration.
  - Install auto-detection (registry + `-TarkovDir`), tool resolution
    (param → PATH → `.\tools`), graceful clear errors when a dependency is
    missing (tells you the exact download URL).
  - **`upscale` stage** — the Real-ESRGAN invocation, resume/skip, and per-file
    failure handling are fully implemented.
  - **`manifest` stage** — fully implemented and TESTED: walks `assets/**`,
    infers the map channel from BSG's `_d/_n/_g/_ao/_h/_m` suffix, writes an
    `aowlspt.resourcepack` v1 `manifest.json` (`capabilities:["textures"]` +
    `textures[]` rows).
- **NOT DONE YET (marked in the script):**
  - **`extract` stage** — the extractor invocation is wired for
    AssetStudioModCLI's intended CLI form, but the exact flags and the set of
    texture-bearing bundles have **not been validated against a live install**.
    You will likely need to (a) confirm your extractor's flags, (b) narrow the
    bundle path to just the surfaces you want (a full dump is large and slow),
    and (c) note AssetRipper uses a different export flow than AssetStudioModCLI.
    The script prints a `NOT-DONE-YET` warning at this stage.

## Schema

Reconciled to `aowlspt.resourcepack` v1: `manifest.template.json` and the
`manifest` stage of `generate.ps1` emit `capabilities:["textures"]` and
`textures[]` rows (`name`/`file`/`map`/`cat`/`tier`/`conf`), matching the final
schema in `feat-resource-packs/mods/resourcepacks/RESOURCE_PACKS.md`.
