# Map terrain and calibration — where these files came from

## Source

    repo   https://github.com/savannt/SPT-DynamicMaps
    ref    main
    commit 7d7aa109a855bb457342c0df98d2b2e059e061b5   (2026-08-23T17:56:09Z)

That repository is the fork carrying **real map terrain SVG images**, which is
what distinguishes it from upstream. Confirmed before anything was copied, by
reading its git tree through the GitHub API: **47 SVG files, 2,639,128 bytes**
under `Plugin/Resources/Maps/*/Layers/`. It is a standalone repo, not a GitHub
fork (`parent: null`), so "the fork we already created" means the project, not
a fork relationship.

## What was taken, and what was deliberately left

Taken: the layer **SVGs** (36 of the 47 — one per layer that a map config
actually references) and the **calibration** out of each map's `.jsonc`.

**Left behind: every `*_PocketMap.png` layer.** Those are the game's own map
art, extracted from the local install at first launch, and the fork's own
config files mark their registration in as many words:

> `UNVERIFIED CALIBRATION - eyeballed, NOT derived from any data in the game
> files. [...] Nothing ties a pixel to a world coordinate, so this rect had to
> be chosen by hand.`

Shipping them would put a layer on the map whose world alignment is admittedly
a guess. Dropping them means **every coordinate in this directory is derived**,
which is the property the rest of this mod depends on. `vendor.py`'s layer
resolver skips any `Images` entry that is not an `.svg` for exactly this reason.

## Conversion

`.jsonc` → `.json`: `//` comments stripped outside string literals, trailing
commas removed, keys lowercased to this repo's convention. Nothing numeric was
touched. `index.json` is a generated summary; the per-map `<Id>.json` files are
the authority.

## The transform these files feed

Derived, not guessed. Full derivation with its citations is in the header of
`mods/maps/sp/page.nim`. In brief:

1. **World → map plane** is `(world.x, world.z)`, from the fork's
   `Plugin/Utils/MathUtils.cs`:
   `ConvertToMapPosition(Vector3 u) => new Vector3(u.x, u.z, u.y)`.
   Unity's `y` is up, so it is the *height* and selects a layer, not a position.
2. **Map plane → image** uses the layer's `imageBounds`, with `+y` upward
   (`Plugin/README.md`), flipped for SVG's downward `y`.
3. **`coordinateRotation`** is one rotation of the group holding the art *and*
   the markers, so they cannot come apart.
4. **`gameBounds`** boxes are written in map-plane coordinates with `z` as the
   **height** — the same swap as step 1. Getting this backwards puts the player
   underground on every map, so it is applied in exactly one place.

## Attribution and licence

The map art is credited per map in each `<Id>.json` (`author` / `authorLink`) —
principally **Tarkov.dev** and **TarkovData**. The source repository carries
**no LICENSE file**, so no licence is asserted here. If these are to ship in a
public release, that needs settling with the upstream authors first; this note
exists so the question is not silently skipped.

## Falsifying this

    curl -s "http://127.0.0.1/aowlspt/maps/index?ident=1"
    curl -s "http://127.0.0.1/aowlspt/maps/map/Customs_TarkovDev?ident=1"
    curl -sI "http://127.0.0.1/aowlspt/maps/asset/Customs_TarkovDev/Layers/SVG/Customs.svg?ident=1"

The last must come back `Content-Type: image/svg+xml`. Served as anything else,
a browser downloads it instead of rendering it and the map is silently blank.
