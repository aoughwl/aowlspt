# aowlspt resource packs

Distributable resource packs for the aowlspt resource-pack system.

> **SCHEMA: PROVISIONAL** — both packs conform to the provisional schema in
> [`RESOURCE_PACK_SCHEMA.md`](RESOURCE_PACK_SCHEMA.md). The authoritative schema
> is owned by branch `feat-resource-packs` (`RESOURCE_PACKS.md`), which had not
> committed a schema when these packs were authored. Reconcile before release —
> each pack's README has a "Schema reconciliation" section.

| Pack | Kind | Assets | License | Distribution model |
|------|------|--------|---------|--------------------|
| [`ambientcg-overhaul/`](ambientcg-overhaul/) | textures | 512 PBR overrides (ambientCG) | CC0-1.0 | manifest committed; ~2.2 GB images assembled by one command |
| [`vanilla-4k/`](vanilla-4k/) | textures | your own, upscaled to 4K | user-generated | generator script only; built on the user's machine, zero game assets shipped |

- **ambientCG Overhaul** — a fresh, non-Tarkov PBR aesthetic from CC0 ambientCG
  materials. Freely redistributable. `assemble.ps1` copies the images the
  manifest lists out of your local `TarkovTextures` tree.
- **Vanilla 4K** — same look as stock Tarkov, upscaled. Ships **only** a
  generator (`generate.ps1`) + template + docs; it extracts and upscales your
  own installed textures locally, so no BSG-copyrighted asset is ever
  distributed.
