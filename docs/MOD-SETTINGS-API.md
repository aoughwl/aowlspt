# Mod Settings API — design

Status: design only, not implemented. Target: `feat-mod-settings-api`.

## 0. What already exists (reuse, do not reinvent)

Two pieces of working infrastructure cover most of this problem already:

1. **`aowl/src/aowlspt/settings.nim`** — a mod-facing schema
   library. `Setting`/`SettingType` (`stBool stInt stFloat stEnum stString
   stKeybind stSelect`), builder procs (`boolSetting`, `intSetting`,
   `floatSetting`, `enumSetting`, `stringSetting`, `keybindSetting`,
   `selectSetting`), `declareSettings()` /
   `declaredSettings()` / `declaredSchemaJson()`, and the write path
   `applySettingFromBody()` → `configSet()` → the mod's own `config.json`.
   Nine mods already call `declareSettings` + `serve("/aowlspt/settings/" &
   ModGuid, handler)` today (admin, blackdivision, classicmovement, fov,
   graphics, morebots, resourcepacks, sain, textures, tarkov). **This is
   already schema + wire + persistence for the declarative/imperative
   surfaces.** It currently feeds only the F12 D3D11 overlay panel, not
   Tarkov's native settings screen.
2. **`host/Aowlspt.Host.Il2Cpp/settingspages.nim`** (929 lines) — the ONLY
   code that renders a real row into Tarkov's own `SettingsTab`. It clones a
   donor control (`swCloneRow`, `swFindDonor`, `swAnyDonor`), currently only
   `swkToggle`/`swkSlider`, seeds its value (`swSeedToggle`), reads it back
   (`swReadBackPage`), and drives all of it from a `SwPage`/`SwRow` list built
   in-process by `swBuildHostPage()` — today hard-coded to the handful of host
   feature flags in `aowlspt-host.json`, nothing mod-declared.
3. **`mods/settingshub/settingshub.nim`** — the aggregation pattern to copy:
   `GET /aowlspt/settings/spt/index` → page list, `GET
   /aowlspt/settings/spt/page/<id>` → one page. Built for the SPT-config
   catalogue, but it is the right shape for "list of mods with settings" +
   "one mod's schema" too.

The design below is: extend (1) with the two missing control kinds and one
new route shape, teach (3)'s aggregation pattern to enumerate declared mod
schemas instead of a static catalogue, and give (2) a schema-driven
`SwPage` builder instead of its hard-coded one. Nothing here proposes a new
persistence layer, a new route framework, or a new backend module.

## 1. Schema — control kinds (measured, `docs/timbuktu/SETTINGS-CONTROLS-RE.md` §4)

Tarkov's native settings screen has exactly four concrete leaf controls, each
identified by its widget at `+0xA8`:

| class | widget | maps from `SettingType` |
|---|---|---|
| `SettingToggle` | `Toggle` | `stBool` |
| `SettingFloatSlider` | `Slider` (continuous) | `stInt`/`stFloat` with `hasRange` |
| `SettingSelectSlider` | `Slider` (discrete/stepped) | `stEnum` with ordered/numeric-ish options, or an int with `step` and few steps |
| `SettingDropDown` | `DropDown` | `stEnum` with free-form string options |

`stString` and `stKeybind` have **no native equivalent** — no post-1.0
`SettingControl` subclass is a text field or key-capture box. Two choices,
not resolved here (see Open Questions): drop them from the native surface and
keep serving them only to the F12 overlay, or render `stKeybind` onto
`SettingSelectSlider`/`SettingDropDown` over an enumerated key list. Existing
declared settings using `stKeybind` (e.g. `zoomToggleKey` in the module's own
docstring) would need this decided before they can appear natively.

`stEnum` maps to either `SettingSelectSlider` or `SettingDropDown` — both are
"pick one of N options" natively; Tarkov's own settings use `SelectSlider` for
short numeric/ordered option lists (e.g. resolution presets) and `DropDown`
for longer or unordered lists (e.g. language). Proposed rule: a mod can force
either with an optional `enumSetting(..., widget = swDropDown)` argument;
default is `SelectSlider` when `options.len <= 6`, else `DropDown` — a
heuristic, not measured, and worth revisiting once real mods use it.

## 2. Wire format and routes

Reuse `Setting.toJson()`'s shape verbatim — it already carries everything a
native row needs (`key label type default value min max step options
category subcategory description implemented`). No new JSON shape for the
schema itself.

**Since, for scale** (see `docs/UI-API.md` for the wire contract): every row
may carry `subcategory` — one grouping level inside `category` — and
`stSelect` exists for an enumeration too large to draw as a dropdown. A
`selectSetting` may ship its choices inline (`options`, with optional
parallel `optionLabels`) or name an `optionsUrl` the UI queries as the user
types, which is what makes "pick one of several thousand item ids" a
declarable setting rather than a bespoke screen. The value on the wire and in
`config.json` is a plain string either way, exactly like `stEnum`, so nothing
about persistence changed and an older renderer degrades to a dropdown.

New routes, following the `settingshub` aggregation pattern and the existing
per-mod `/aowlspt/settings/<guid>` convention (`matchRoute`'s exact-match /
longest-prefix rule in `backend/aowlbackend.nim:947`):

```
GET  /aowlspt/settings/index
     -> {"mods":[{"guid":"aowl.fov","name":"FOV","count":4}, ...]}
     One entry per mod that has called declareSettings(), server-side.

GET  /aowlspt/settings/<guid>
     -> declaredSchemaJson() for that mod  (ALREADY SERVED, unchanged)

POST /aowlspt/settings/<guid>
     body {"key":"...","value":<literal>}
     -> applySettingFromBody(), 200 always (ALREADY SERVED, unchanged)
```

Only `/aowlspt/settings/index` is new — one static route, registered by
whichever mod becomes the aggregator (`settingshub`, generalized, is the
natural owner: it already runs `sides = {sideServer}` and already answers an
`/index` + `/page/<id>` shape). It needs a way to enumerate every OTHER mod's
declared schema, which `declareSettings`'s current design does not give it
(each mod's `gDeclared` is a private module-level var). That is the one real
gap: **a process-wide registry**, not a per-mod one — see §6 checklist.

## 3. Three authoring surfaces, one schema

All three produce a `seq[Setting]` passed to `declareSettings()`. No new
lowering machinery is needed for (a) and (c) — they already exist.

**(a) Declarative block** (existing, works today):
```nim
declareSettings(@[
  boolSetting("fastLoad", "Fast load", true, category = "Loading"),
  intSetting("botCount", "Bot count", 12, lo = 0, hi = 30, step = 1,
             category = "Bots")])
```

**(b) Typed config object** (new — a macro/proc pair over an existing config
type, so a mod's `Config = object` doubles as its schema instead of writing
builder calls by hand):
```nim
type MyConfig = object
  fastLoad {.setting: "Fast load", category: "Loading".}: bool
  botCount {.setting: "Bot count", category: "Bots", range: (0, 30).}: int

declareSettingsFrom(MyConfig)   # walks the object's fields+pragmas at
                                 # compile time, emits the same seq[Setting]
                                 # that (a) would have written by hand
```
This needs a `{.pragma.}`-reading compile-time proc (Nimony macro support
permitting — unverified, see Open Questions) that maps Nim types to
`SettingType` (`bool->stBool`, `int->stInt`, `float->stFloat`, `string
->stString`, `enum->stEnum` with `options` from `$typ` iteration) and reads
`range`/`category`/`label` off pragma arguments. It is sugar over (a): the
runtime artifact is identical, so a host or the wire never see a difference
between (a) and (b).

**(c) Imperative escape hatch** (existing, trivially available — nothing
stops a mod calling `declareSettings(@[boolSetting(...)])` conditionally, or
building the seq across several `add`s before one `declareSettings` call at
the end of `onLoad`). The one addition worth naming: `declareSetting(one:
Setting)` (singular) that appends to `gDeclared` instead of replacing it, for
a mod that wants to register settings from more than one source file without
assembling the whole seq in one place first.

## 4. Persistence

Unchanged from what exists: each mod's own `config.json`, read with
`setting(key).asFloat/asInt/asText/asBool(default)` and written with
`configSet(key, valueJson)` (both already exported from `aowlspt`/`aowlspt/
server`). A mod reads its own setting the same way whether the edit arrived
through the F12 overlay or a new native control — the write path
(`applySettingFromBody`) is identical either way, because both are the same
POST to `/aowlspt/settings/<guid>`. **No new persistence layer.** The
existing comment in `applySetting` — a mod that wants the new value live
re-reads its config itself, the setter does not push it — carries over
unchanged; native rendering does not change that contract.

## 5. Host-side checklist (for the host-side agent — NOT written here)

- [ ] Add `swkSelectSlider` and `swkDropDown` alongside the existing
      `swkToggle`/`swkSlider` in `settingspages.nim`'s `SwRowKind`, with a
      donor-clone path for `SettingSelectSlider`/`SettingDropDown` (classes
      15668/15659 per the RE doc) — today only Toggle and (float) Slider are
      cloned.
- [ ] Add a "Singleplayer" tab: confirm how the native tab list is built
      (`SettingsScreen::ShowScreen` per the RE doc's §3 hook) and whether a
      new tab needs a donor tab to clone the way rows clone a donor control,
      or whether it can be injected into the existing five-tab
      `EnsureTabInitialized` prewarm list.
- [ ] Replace `swBuildHostPage()`'s hard-coded host-flag list with an HTTP
      fetch of `GET /aowlspt/settings/index` then one `GET
      /aowlspt/settings/<guid>` per mod, building one `SwPage` per mod (or
      grouping by `category` within the tab — undecided, see Open
      Questions).
- [ ] Wire `swReadBackPage`'s existing write path to `POST
      /aowlspt/settings/<guid>` instead of (or alongside) the current
      host-flag write, using the same `{"key":...,"value":...}` body shape
      `applySettingFromBody` already expects.
- [ ] Decide and implement the `implemented: false` greyed-row treatment for
      the native controls — it exists today only in the F12 overlay's
      renderer.
- [ ] `stString`/`stKeybind` rows: either suppress them on the native tab or
      pick a native encoding (see §1) — do not silently drop them without a
      visible reason, per CLAUDE.md's "every failure path must announce
      itself".

## 6. Backend-side gap (not host, still undesigned in detail here)

`declareSettings` is per-mod-process-private (`var gDeclared` in
`settings.nim`, one instance per loaded mod binary). `/aowlspt/settings/
index` needs to enumerate every mod's declaration from ONE mod's route
handler, which today it cannot do — there is no cross-mod registry, only
cross-mod HTTP (routes). Two options, not chosen here:
- Each mod also self-registers into a shared registry proc exported from
  `aowlspt` itself (a backend-level, not mod-level, list) at
  `declareSettings()` time — requires a new export on the mod ABI.
  or
- The aggregator does N internal HTTP calls to each `/aowlspt/settings/
  <guid>` it already knows about (from `mods/manager`'s existing mod list —
  it already enumerates loaded mods for `/aowlspt/mods/list`) — no ABI
  change, reuses `manager`'s registry, costs N loopback round-trips per
  index fetch.

## 7. Open questions / risks

1. **Nimony macro/pragma support for (b).** Unverified in this session
   (nimlang MCP tools were not available; this survey used Grep/Read on
   source directly, which is *itself* an "aowl mode" violation worth
   flagging — see below). If Nimony cannot read field pragmas at compile
   time, (b) has to be a runtime helper (`configFrom[T](obj: T)`) that
   iterates fields via `fieldPairs` instead of pragmas, losing per-field
   label/category/range metadata unless carried in the type via named
   tuples instead of pragmas.
2. **stString/stKeybind on the native tab** — no decision made, see §1/§5.
3. **SelectSlider vs DropDown heuristic** (`options.len <= 6`) is a guess,
   not measured against how Tarkov's own settings actually choose.
4. **Cross-mod registry** (§6) needs an ABI decision before it can be built.
5. **Category-to-page grouping**: does each mod get one page (tab section),
   or does `category` from any mod merge into shared native sections
   (`FOV`, `Bots`, ...) the way the F12 overlay might already do? Undecided;
   changes the `SwPage` construction in the host checklist.
6. **Write latency / no live-apply**: `applySettingFromBody` only persists;
   a mod must re-read on its own next use. For a native slider this means
   the row shows the new value instantly (host-local echo) but the actual
   game behavior may lag until the mod's next tick — same contract as
   today, but more visible with real-time sliders than it was with the F12
   panel's explicit save action.

## Process note

This survey used `Grep`/`Read` directly against `.nim` sources under
`mods/`, `backend/`, and `host/` because the nimlang MCP tools named in the
"aowl mode (guided)" instruction were not present in this session's toolset
— there was no `search`/`symbols`/`decl_of`/`outline`/`api` tool to call.
Flagging this per CLAUDE.md §10 rather than silently routing around it.
