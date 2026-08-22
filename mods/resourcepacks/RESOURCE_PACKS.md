# aowl.resourcepacks — shareable resource packs for post-1.0 Tarkov

A resource pack is a **folder** holding a `manifest.json` and its asset files.
Anyone can author one, zip the folder, and hand the zip to a friend; the friend
extracts it into `packs/` and the game loads it. It is deliberately the
Minecraft model: packs are read-only and self-contained, and a separate config
records which ones are enabled and in what order.

This mod renders nothing itself. It is an **orchestrator** that resolves the
enabled packs into one flattened override set and feeds it to two systems that
already exist:

- **textures** → a flattened manifest in the texture mod's own format, written
  to a file the texture mod reads. The existing byte-verified `LoadAsset` swap
  hook, VRAM budget, and `swapMode` ladder do the actual swapping — unchanged.
- **grade/shaders** → merged post-process parameters pushed through the existing
  `aowlspt.host::gfx_apply` host call, i.e. the graphics mod's driven-mode
  Present. **No second Present hook is ever created.**

---

## 1. Directory layout

```
mods/resourcepacks/
  resourcepacks.nim         # the loader (this mod)
  config.json               # enabled set + stack order + safety toggles
  resolved.manifest.json    # GENERATED: the flattened texture manifest (default out path)
  packs/
    example-textures/
      manifest.json
      textures/metal_plate_01.png
    example-grade/
      manifest.json
    <your-pack>/
      manifest.json
      ...assets...
```

The **folder name** is the pack's stable `id` (used in config). To share a pack,
zip its folder; to install one, extract the folder into `packs/`.

> **Zip note.** The loader reads pack *folders*. A `.zip` dropped into `packs/`
> must be extracted first (right-click → Extract). A zip left as-is is ignored,
> not loaded — the same fail-safe posture as a broken manifest.

---

## 2. Manifest schema (`manifest.json`)

```json
{
  "schema": "aowlspt.resourcepack",
  "schemaVersion": 1,
  "name": "Human Readable Name",
  "version": "1.0.0",
  "author": "you",
  "description": "One line about what this pack does.",
  "capabilities": ["textures", "grade"],

  "textures": [
    {
      "name": "metal_plate_01",
      "file": "textures/metal_plate_01.png",
      "map": "albedo",
      "cat": "Metal",
      "tier": "2K",
      "conf": 1.0
    }
  ],

  "grade": {
    "tonemapper": 1,
    "tonemapStrength": 0.9,
    "exposure": 0.05,
    "contrast": 1.08,
    "saturation": 1.06,
    "temperature": 0.12,
    "tint": -0.02,
    "vignette": 0.22,
    "lut": "grade/look.png"
  }
}
```

### Top-level fields

| field           | required | meaning |
|-----------------|----------|---------|
| `schema`        | yes      | must be exactly `"aowlspt.resourcepack"` |
| `schemaVersion` | yes      | must be `1` (this build) |
| `name`          | yes      | display name, non-empty |
| `version`       | yes      | pack version, non-empty (semver recommended) |
| `author`        | no       | credit string |
| `description`   | no       | one-line summary |
| `capabilities`  | no       | advisory list: any of `"textures"`, `"grade"`. The presence of a usable `textures` array or `grade` object is what actually arms each path; a declared capability with no payload is reported as a note. |
| `textures`      | if a texture pack | array of override entries (below) |
| `grade`         | if a grade pack   | flat object of post-process params (below) |

A pack that ships **neither** a usable `textures` array **nor** a `grade` object
is refused as invalid (nothing to load).

### Texture entry fields (each element of `textures`)

| field  | required | meaning |
|--------|----------|---------|
| `name` | yes      | the Unity texture asset name the game asks for (case-insensitive; lowercased on read) |
| `file` | yes      | image path **relative to the pack folder** (PNG/JPG/TGA — anything `ImageConversion.LoadImage` decodes) |
| `map`  | no       | `albedo` (default) / `normal` / `roughness` / `ao` / … — informational |
| `cat`  | no       | free-form category tag (Metal, Wood, …) |
| `tier` | no       | `2K` (default) or `4K` — feeds the texture mod's VRAM budget |
| `conf` | no       | author-declared match confidence 0..1 (default 1.0) |

A texture entry whose `file` does not exist on disk is **skipped** (counted,
logged), the pack still loads — the same fail-soft the texture mod applies.

### Grade object fields (any subset of)

`tonemapper` (0 none, 1 AgX, 2 ACES), `tonemapStrength`, `exposure`, `contrast`,
`saturation`, `temperature`, `tint`, `lift`, `gamma`, `gain`, `shadows`,
`highlights`, `sharpness`, `bloom`, `bloomStrength`, `vignette`,
`vignetteRadius` — **exactly the graphics mod's flat params**. Booleans are
written as `0`/`1` (the graphics mod's numeric convention). Only the keys a pack
sets are changed; every other post-process value keeps whatever the graphics mod
last set, so a pack that sets only `contrast` nudges nothing else.

`lut` is an optional look-up-table image path (relative to the pack). It is
parsed and surfaced today; host LUT sampling is a future graphics-mod step, so a
LUT-only grade pack currently contributes its path but no live effect until that
lands.

---

## 3. Stack order (multiple packs at once)

Several packs can be enabled together. The enabled list in `config.json` is
ordered **low → high priority** (index 0 is the base). When two packs set the
same texture `name` or the same grade key, the **later** pack in the list wins —
exactly like Minecraft's applied-pack list, where the top entry overrides those
below it. The loader flattens the whole stack into one map with last-writer-wins.

---

## 4. Config (`config.json`) — safe by default

```json
{
  "enabled": true,
  "swapMode": "off",
  "driveGrade": false,
  "packsDir": "",
  "textureManifestOut": "",
  "packs": [
    { "id": "example-grade", "enabled": false },
    { "id": "example-textures", "enabled": false }
  ]
}
```

| key                  | default | meaning |
|----------------------|---------|---------|
| `enabled`            | `true`  | master switch for the loader |
| `swapMode`           | `"off"` | texture-swap ladder. **`off` (safe) writes an empty texture manifest — nothing is swapped.** `probe` → `match` → `full` escalate exactly as the texture mod documents. |
| `driveGrade`         | `false` | `false` = this mod never touches the post-process (graphics mod owns it). `true` = enabled grade packs are merged and pushed through `gfx_apply`. |
| `packsDir`           | `""`    | pack folder location; empty = `<modDir>/packs` |
| `textureManifestOut` | `""`    | where the flattened texture manifest is written; empty = `<modDir>/resolved.manifest.json` |
| `packs`              | `[]`    | enabled set **and** stack order. Array order is load order. A pack folder present on disk but absent here is available-but-disabled. |

**Why two safety gates.** `swapMode=off` keeps textures inert until a user opts
in (a texture swap is the risky, VRAM-heavy, hook-driven path). `driveGrade=false`
keeps this mod from fighting the graphics mod over the shared grade. Both must be
turned on deliberately.

---

## 5. Wiring into the texture mod

The loader writes the resolved texture manifest (when `swapMode != off`) to
`textureManifestOut`, which defaults to
`<install>/mods/resourcepacks/resolved.manifest.json`.

`aowl.textures` reads it through **one config key**, `manifestPath`. In the
**texture mod's** `config.json`:

```jsonc
  "packRoot":     "",                                              // the emitted file paths are absolute
  "manifestPath": "<install>/mods/resourcepacks/resolved.manifest.json"
```

`packRoot` must be `""`: the resolved manifest's `file` values are absolute, and
a non-empty `packRoot` would prefix them into nonsense. `manifestPath` empty
(the shipped default) keeps the texture mod on its own committed curated
manifest, so installing the pack loader changes nothing until you set this.

Then raise the texture mod's `swapMode` to `probe` → `match` → `full`, one rung
at a time. The byte-verify, arm delay, and VRAM budget stay entirely in the
texture mod and are unaware a pack system exists — that is the point of the
seam. Load order matters and the registry enforces it: `aowl.resourcepacks`
writes the file during its `onLoad`, `aowl.textures` reads it during its, and
`aowl.textures` carries `loadAfter: ["aowl.resourcepacks"]`.

`aowl run mods/resourcepacks` proves this handoff offline: it writes
`resolved.manifest.json` for real, reads it back, and asserts every `file` path
in it is absolute.

## 6. Wiring into the graphics mod

Set `driveGrade=true`. On load and on every settings change, the loader merges
the enabled grade packs and calls `aowlspt.host::gfx_apply` with the graphics
mod's exact flat params — the same driven-mode Present path. On unload (or when
`driveGrade` is turned off), the loader pushes `{"enabled":0}` so the stock look
returns until the graphics mod re-applies.

---

## 7. Settings page contract (for the future in-game SettingsScreen)

A native **Resource Packs** section is planned for the real in-game
`SettingsScreen` (not the overlay), injected separately via a Unity-thread
static-offset field path. That page is **not built here**. What is built is the
clean surface it will bind to — it reads and writes **only** this mod's
`config.json` and this HTTP endpoint:

**Endpoint:** `GET/POST /aowlspt/settings/aowl.resourcepacks`

**GET** returns the current state:

```json
{
  "swapMode": "off",
  "driveGrade": false,
  "packs": [
    {
      "id": "example-grade",
      "name": "Warm Cinematic Grade",
      "version": "1.0.0",
      "author": "savannt",
      "description": "…",
      "kind": "grade",          // "textures" | "grade" | "both" | "none"
      "valid": true,
      "error": "",              // skip reason when valid=false; a note otherwise
      "enabled": false,
      "order": 0                // position in the stack (low→high priority)
    }
  ]
}
```

Packs are listed in stack order, then any on-disk packs not yet in config
(available-but-disabled), so a freshly dropped-in pack appears ready to enable.

**POST** the same URL with one of these bodies; each persists to `config.json`,
re-scans, re-applies the stack, and returns the GET body:

```json
{ "action": "toggle",        "id": "example-grade", "enabled": true }
{ "action": "reorder",       "order": ["example-textures", "example-grade"] }
{ "action": "setSwapMode",   "value": "match" }
{ "action": "setDriveGrade", "value": true }
```

- **toggle** — enable/disable one pack (list = the checkboxes).
- **reorder** — set the full stack order, low→high priority (list = drag-to-reorder).
- **setSwapMode / setDriveGrade** — the two safety gates (the section's two
  master switches).

So the settings page reads: `packs[]` (name/version/author/kind/valid/error),
`enabled`, `order`, `swapMode`, `driveGrade`. It writes: the four POST actions
above. Nothing else is needed — the loader owns resolution and emission.

---

## 8. Authoring a pack, end to end

1. Copy `packs/example-textures/` (or `example-grade/`) to `packs/my-pack/`.
2. Edit `manifest.json`: set `name`, `version`, and your `textures`/`grade`.
3. Drop your images beside it and reference them with relative `file` paths.
4. Enable it: `POST {"action":"toggle","id":"my-pack","enabled":true}` (or add
   `{ "id":"my-pack", "enabled":true }` to `config.json`'s `packs`).
5. For textures, raise `swapMode`; for grade, set `driveGrade=true`.
6. Share it: zip the `my-pack/` folder. A friend extracts it into their `packs/`.

Run `aowl run mods/resourcepacks` for an offline self-test that parses the
example packs, resolves a two-pack stack, validates both emitted artifacts, and
writes and re-reads the handoff file `aowl.textures` consumes — no game or
runtime required.

---

## 9. Installing it, and the user workflow

The mod is in `registry/mods.json` as `aowl.resourcepacks` and in the
**Vanilla Plus** list, immediately before `aowl.textures`. `aowl payload` stages
a mod's `packs/` directory alongside its `data/` and `config.json`, so the
install ends up with:

```
<install>/mods/resourcepacks/
    resourcepacks.dll
    config.json                  <- what is enabled, in what order
    packs/
        example-textures/        <- shipped, as something to copy
        example-grade/
    resolved.manifest.json       <- generated; do not edit
```

**Where do I drop a pack?** Extract the pack folder (the one containing
`manifest.json`) into `<install>/mods/resourcepacks/packs/`. Nothing else. Packs
are read-only to this mod; it never writes inside one.

**How do I enable and order them?** Either edit `config.json`'s `packs` array —

```jsonc
  "packs": [
    { "id": "base-textures",  "enabled": true },
    { "id": "my-overrides",   "enabled": true }   // later wins on any conflict
  ],
  "swapMode": "match",     // off -> probe -> match -> full
  "driveGrade": false
```

— or drive it live over the mod's own endpoint, which is the same surface the
future in-game page binds to (§7):

```
GET  /aowlspt/settings/aowl.resourcepacks
POST /aowlspt/settings/aowl.resourcepacks  {"action":"toggle","id":"my-pack","enabled":true}
POST /aowlspt/settings/aowl.resourcepacks  {"action":"reorder","order":["base-textures","my-overrides"]}
```

Order is low → high priority: the **last** pack in the list wins a conflict, as
in Minecraft's applied-pack list. A pack dropped in but never named in config
shows up in the GET body as available-and-disabled, so it is one toggle away.

**Restart or reload?** A `POST` re-scans, re-resolves and rewrites the manifest
immediately, as does firing the `aowl.resourcepacks.reload` event. But
`aowl.textures` loads its manifest once, at *its* `onLoad` — so a change to the
enabled stack reaches the game on the next start.

---

## 10. How pack content actually reaches the client — and what is not done

This was the open question, and the answer is not the obvious one.

**Loose texture replacement does not go through `StreamingAssets`, and does not
go through HTTP either.** `aowl.textures` postfixes
`UnityEngine.AssetBundle::LoadAsset`, and on a name match decodes a **loose
image file it reads itself, from an ordinary path on disk**, into the returned
`Texture2D` in place. The bytes never travel: no bundle, no URL, no listener.
That is why a pack's images can sit inside the pack folder and simply work, and
why the asset-port/`/files/` machinery that fixed trader avatars is irrelevant
here — those are two unrelated pipelines that both happen to move images.

**`StreamingAssets` is the constraint for a pack that ships an asset *bundle*,
and that is the part that is not built.** From
`docs/timbuktu/IMAGE-LOADING-RE2.md` §6.3, confirmed in the disassembly:
`BundlesManager`'s loading url comes from `AssetsEnvironment::GetDownloadingUrl`
→ `Application::get_streamingAssetsPath`, i.e.
`file://<install>/EscapeFromTarkov_Data/StreamingAssets/Windows/`. The metadata
carries no bundle CDN literal at all. So bundles are local file reads and always
were; serving one over the asset port would work only if something first pointed
a bundle url at it, and nothing does.

On this install the tree is real and populated:

```
D:\Aowlspt\EscapeFromTarkov_Data\StreamingAssets\Windows\
    Windows.json      <- the bundle manifest (name -> FileName, Crc, Dependencies)
    assets\ maps\ shaders\ cubemaps\ packages\ ...
```

**And here is the landmine for that future work.** The client's boot-time
files-checker reads `D:\Aowlspt\ConsistencyInfo` and refuses to boot with
`Consistency ensurance failed. File size does not match` if a listed file
changes size. That file has **10120 entries, 8080 of them under
`StreamingAssets`** — every stock bundle is size-and-checksum pinned, so
*replacing* a bundle in place is off the table without a re-sync. `Windows.json`
itself is listed (`"Size":2736376`), and a new bundle has to be named in it to
be loadable, so even the additive design touches exactly one pinned file. A
bundle-shipping pack would therefore have to:

1. write its `.bundle` files as **new** paths under `StreamingAssets/Windows/`
   (new files are not listed and are not checked),
2. add their entries to `Windows.json`,
3. re-sync `Windows.json`'s `ConsistencyInfo` entry — `"<name>","Size":N,
   "Checksum":M` where `Checksum` is the file's byte-sum mod 2^32. **There is no
   re-sync helper in this repo yet**; nothing here writes a `ConsistencyInfo`
   entry (the installer only *reads* the file's version, `eft.nim`, and
   `tools/firstrun.nim` writes a synthetic stub for a fixture). Writing that
   helper is step zero of the bundle work,
4. and be able to undo all three on uninstall.

None of that is implemented. The pack schema has no bundle entry type, the
loader writes nothing outside its own mod directory, and it touches no file
under `D:\Aowlspt`. That is a deliberate stopping point, not an oversight: the
loose-texture and grade paths are complete and need none of it.

### Honest status

| | status |
|---|---|
| Pack schema, parse, validate, refuse-a-bad-pack | **working** (`aowl run mods/resourcepacks`) |
| Stack resolution, later-wins override, per-pack enable/order | **working**, self-tested |
| Handoff file written where `aowl.textures` reads it | **working**, self-tested end to end |
| `aowl.textures` consuming it (`manifestPath`) | **working** offline: 1-entry example pack loads and its name resolves |
| Registered, listed, and staged into an install by `aowl payload` | **coded**, not yet installed or run against the live client |
| Grade packs driving `gfx_apply` | **coded**; the call path is the graphics mod's, unverified from here |
| A pack actually changing a pixel in-game | **unproven** — needs `aowl.textures` `swapMode` raised to `full` on a live client, which is its own separate ladder |
| Distribution packs (`packs/ambientcg-overhaul`, `packs/vanilla-4k`) | **manifests/scripts only**; neither ships assets, both need their assemble/generate step run locally first |
| Bundle-shipping packs via `StreamingAssets` | **not started** — see above |
| In-game native Resource Packs settings page | **not started** — §7 is the contract it will bind to |
