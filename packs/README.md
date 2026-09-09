# aowlspt resource packs

Distributable resource packs for the aowlspt resource-pack system.

> **SCHEMA: `aowlspt.resourcepack` v1** — both packs are reconciled to the final
> schema owned by branch `feat-resource-packs`
> (`mods/resourcepacks/RESOURCE_PACKS.md`); see
> [`RESOURCE_PACK_SCHEMA.md`](RESOURCE_PACK_SCHEMA.md) for a local quick-reference.

| Pack | Kind | Assets | License | Distribution model |
|------|------|--------|---------|--------------------|
| [`ambientcg-overhaul/`](ambientcg-overhaul/) | textures | 512 PBR texture rows (ambientCG) | CC0-1.0 | manifest committed; ~2.2 GB images assembled by one command |
| [`vanilla-4k/`](vanilla-4k/) | textures | your own, upscaled to 4K | user-generated | generator script only; built on the user's machine, zero game assets shipped |

- **ambientCG Overhaul** — a fresh, non-Tarkov PBR aesthetic from CC0 ambientCG
  materials. Freely redistributable. `assemble.ps1` copies the images the
  manifest lists out of your local `TarkovTextures` tree.
- **Vanilla 4K** — same look as stock Tarkov, upscaled. Ships **only** a
  generator (`generate.ps1`) + template + docs; it extracts and upscales your
  own installed textures locally, so no BSG-copyrighted asset is ever
  distributed.
