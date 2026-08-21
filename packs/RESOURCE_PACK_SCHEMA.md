# aowlspt resource-pack manifest schema (v1)

> These packs conform to `aowlspt.resourcepack` **v1**, the schema owned by
> branch `feat-resource-packs`. The **authoritative** doc is
> `feat-resource-packs/mods/resourcepacks/RESOURCE_PACKS.md` — this file is a
> local quick-reference for the two packs in this directory. Both manifests are
> **reconciled to v1** (`_schemaStatus: "reconciled to aowlspt.resourcepack v1"`).

A resource pack is a self-describing directory with a `manifest.json` at its
root and (optionally) a pack-relative asset tree it ships or generates.

## `manifest.json`

```jsonc
{
  "schema": "aowlspt.resourcepack",     // REQUIRED, fixed string
  "schemaVersion": 1,                    // REQUIRED, integer

  "name": "ambientCG Overhaul",          // REQUIRED, human display name
  "version": "1.0.0",                    // REQUIRED, semver of this pack's content
  "author": "savannt",                   // pack author
  "description": "…",                    // one/two sentence summary

  "capabilities": ["textures"],          // array; values "textures" and/or "grade"

  // Present when capabilities includes "textures". One row per replaced asset.
  "textures": [
    {
      "name": "airductmetal",            // lowercased Unity/BSG asset name to match
      "file": "assets/Metal/Painted Metal 004/PaintedMetal004_2K-JPG_Color.jpg",
      "map":  "albedo",                  // albedo|normal|roughness|ao|height|metalness
      "cat":  "Metal",                   // surface class (informational)
      "tier": "2K",                      // resolution tier of this file
      "conf": 0.593                      // matcher confidence (informational)
    }
    // …
  ]

  // Present ONLY for grade packs (capabilities includes "grade"): flat graphics
  // params — tonemapper, tonemapStrength, exposure, contrast, saturation,
  // temperature, tint, vignette, lut. Neither pack here is a grade pack.
}
```

### Field notes

- **Required:** `schema`, `schemaVersion`, `name`, `version`.
- **`textures[].file` is pack-relative** (resolved by the loader; the resolved
  manifest keeps `packRoot=""` verbatim). Forward slashes; never escapes the
  pack dir — a pack is relocatable.
- **`textures[].name`** is the lowercased asset name the runtime matches against
  (same key `mods/textures` uses), so an existing textures manifest maps 1:1.
- **`map`** — BSG splits maps into separate named textures (`_d`/`_n`/`_g`
  suffixes), so each suffix is its own row.
- **License is NOT a manifest field** — it lives in each pack's README /
  `LICENSE-ASSETS.txt`.
- A pack may ship its assets in-tree (Pack 1, ambientCG / CC0) **or** generate
  them on the user's machine and leave `textures` empty in the distributed
  manifest, filled at generate time (Pack 2, Vanilla 4K).

## Two shipping modes

| Mode | Ships images? | `textures` at distribution | Example |
|------|---------------|-----------------------------|---------|
| **In-tree** | yes (or one-command assemble) | fully populated | ambientCG Overhaul (CC0) |
| **Generated** | no (built on user's PC) | empty template, filled by generator | Vanilla 4K |
