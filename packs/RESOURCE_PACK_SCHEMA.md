# aowlspt resource-pack manifest schema (PROVISIONAL v1)

> STATUS: PROVISIONAL. The authoritative schema is owned by branch
> `feat-resource-packs` (its `RESOURCE_PACKS.md` + loader). At the time these
> packs were authored that branch had **not committed a schema yet**, so the
> manifests here conform to this provisional schema, designed to match the field
> set the coordinator specified. If `feat-resource-packs` lands with different
> field names, only the small header fields need renaming — the per-asset
> `overrides` rows already mirror the shape the `mods/textures` client mod
> consumes (`name` / `file` / `map`), so the override table itself should port
> unchanged.

A resource pack is a self-describing directory with a `manifest.json` at its
root and (optionally) a pack-relative asset tree it ships or generates.

## `manifest.json`

```jsonc
{
  "schema": "aowlspt.resource-pack",   // fixed string, identifies the format
  "schemaVersion": 1,                   // integer, bumped on breaking changes

  "id": "ambientcg-overhaul",           // stable slug, unique per pack, [a-z0-9-]
  "name": "ambientCG Overhaul",         // human display name
  "version": "1.0.0",                   // semver of THIS pack's content
  "author": "savannt",                  // pack author
  "description": "…",                   // one/two sentence summary
  "license": "CC0-1.0",                 // SPDX id of the shipped assets' license

  "kind": "textures",                   // "textures" | "shaders" | "both"

  "assetRoot": "assets",                // pack-relative dir that holds the files
                                        //   every override `file` is relative to
                                        //   the MANIFEST location (so it usually
                                        //   begins with this prefix)

  // Optional, texture-pack specific hints the client mod already understands:
  "quality": "2k",                      // "2k" | "4k" — informational tier tag

  // The asset override mapping. One row per replaced game asset.
  "overrides": [
    {
      "name": "airductmetal",           // lowercased Unity/BSG asset name to match
      "file": "assets/Metal/Painted Metal 004/PaintedMetal004_2K-JPG_Color.jpg",
      "map":  "albedo",                 // albedo|normal|roughness|ao|height|metalness
      "cat":  "Metal",                  // surface class (informational)
      "tier": "2K",                     // resolution tier of this file
      "conf": 0.593                     // matcher confidence (informational)
    }
    // …
  ]
}
```

### Field notes

- **`file` paths are ALWAYS pack-relative** (relative to `manifest.json`), use
  forward slashes, and never escape the pack directory. This makes a pack
  relocatable — drop it anywhere and the loader resolves assets against the
  manifest's own directory.
- **`overrides[].name`** is the lowercased asset name the runtime matches
  against (the same key `mods/textures` uses today), so an existing textures
  manifest maps 1:1 into `overrides`.
- **`map`** lets a single logical material ship albedo/normal/roughness/… as
  separate rows (BSG splits maps into separate named textures with `_d`/`_n`/`_g`
  suffixes, so each suffix is its own row).
- A pack may ship its assets in-tree (Pack 1, ambientCG / CC0) **or** generate
  them on the user's machine and leave `overrides` empty in the distributed
  manifest, to be filled at generate time (Pack 2, Vanilla 4K).

## Two shipping modes

| Mode | Ships images? | `overrides` at distribution | Example |
|------|---------------|------------------------------|---------|
| **In-tree** | yes (or one-command assemble) | fully populated | ambientCG Overhaul (CC0) |
| **Generated** | no (built on user's PC) | empty template, filled by generator | Vanilla 4K |
