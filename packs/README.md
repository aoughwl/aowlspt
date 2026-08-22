# aowlspt resource packs

Distributable resource packs for the aowlspt resource-pack system.

> **SCHEMA: `aowlspt.resourcepack` v1** — both packs are reconciled to the
> schema in [`mods/resourcepacks/RESOURCE_PACKS.md`](../mods/resourcepacks/RESOURCE_PACKS.md),
> which is now the loader's own documentation on `main`; see
> [`RESOURCE_PACK_SCHEMA.md`](RESOURCE_PACK_SCHEMA.md) for a local quick-reference.

**This directory is a staging area, not an install location.** Nothing here is
loaded from where it sits. A pack becomes live only when its folder — the one
holding `manifest.json` — is placed in
`<install>/mods/resourcepacks/packs/` and enabled; see
[§9 "Installing it, and the user workflow"](../mods/resourcepacks/RESOURCE_PACKS.md)
for the enable/order steps and the one `aowl.textures` config key
(`manifestPath`) that connects the stack to the swap hook.

Both packs below ship **no images**. Run the pack's own assemble/generate step
first; until you do, its `assets/` directory is empty and the loader will report
every entry as a missing file and skip it.

Checked on 2026-08-21: all **512** files named in `ambientcg-overhaul/manifest.json`
resolve against the local `TarkovTextures` tree, so `assemble.ps1` has everything
it needs here — it just has not been run (it writes ~2.2 GB, and `assets/` is
gitignored by design). `vanilla-4k` has no manifest at all until `generate.ps1`
produces one from your own install.

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
