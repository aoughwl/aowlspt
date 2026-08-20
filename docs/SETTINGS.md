# In-game settings (F12) and the mod config schema

F12 opens an in-game settings panel. Every aowlspt mod's `config.json`, the
Tarkov emulator's own settings, and the full SPT server config surface are
meant to be visible and editable there, each value drawn with the right control,
persisted to disk, and hot-applied — with anything aowlspt does not yet back
marked plainly **not implemented yet**.

This page has three parts: the **feasibility spike** that decided *how* the
panel is drawn, the **mod config schema API** a mod uses to declare its
settings, and the **SPT config surface** that fills the rest of the screen.

---

## 1. Feasibility spike — how F12 draws, and why not the real screen

The user's vision is F12 opening Tarkov's *real* settings screen, revamped. We
reverse-engineered that screen and concluded we cannot safely drive it. The
panel is the **hand-drawn D3D11 overlay** instead. This section records why, so
the decision is not relitigated from memory.

### What the real settings screen is (RE, from decrypted metadata + GameAssembly.dll)

Image base `0x180000000`; runtime address = `GameAssemblyBase + (VA − 0x180000000)`.

| Type | Method | Token | VA |
|---|---|---|---|
| `EFT.UI.Settings.SettingsScreen` | `Awake` | 0x060172c5 | 0x18171e940 |
| `EFT.UI.Settings.SettingsScreen` | `Show` (builds UI) | 0x060172c7 | 0x18171fa00 |
| `EFT.UI.Settings.SettingsScreen` | `EnsureTabInitialized` | 0x060172c8 | 0x18171ff10 |
| `EFT.UI.Settings.SettingsScreen` | `OpenGroup` (select tab) | 0x060172d1 | 0x181720c80 |
| `EFT.MainMenuShowOperation` | `ShowSettingsScreen` (the opener) | 0x0600c8d2 | 0x1809fa660 |
| `SettingsScreenController` | `.ctor` | 0x060172e1 | 0x181721a40 |
| `SettingsScreenController` | `SaveSettings` | 0x060172e4 | 0x181721e20 |
| `RaidSettingsScreenController` | `.ctor` (in-raid) | — | 0x181723ff0 |

Tab classes (namespace `EFT.UI.Settings`): `SettingsTab` (abstract base),
`GameSettingsTab`, `GraphicsSettingsTab`, `SoundSettingsTab`,
`ControlSettingsTab`, `PostFXSettingsTab`. Each tab's `CreateControls`
instantiates **`SettingControl`** subclasses from Unity prefabs —
`SettingDropDown` (`BindToEnum`), `SettingFloatSlider` (`BindTo`),
`SettingSelectSlider`, `SettingToggle`, and keybind rows `CommandKeyPair` /
`CommandAxisPair` (`ListenForKey`). Values live in `*SettingsController` /
`*SettingsGroup`; persistence is `Bsg.GameSettings.Json.JsonFileSettingsProvider.SaveJson`.

**Flow:** `MainMenuShowOperation.ShowSettingsScreen` → `new SettingsScreenController`
→ `SettingsScreen.Show` → `OpenGroup` → each tab built lazily on first select.

### Why we do not inject into it

1. **It is pure managed Unity UI.** Adding our rows means instantiating prefabs
   and `SettingControl` subclasses and parenting them into the live screen —
   managed object construction on the game's UI graph, mid-session.
2. **That is the exact crash class this client has proven repeatedly.** Live
   IL2CPP managed method-pointer detours / managed construction from our host
   thread crash this build (see `abi/aowlspt_il2cppready.h`: even *asking*
   `il2cpp_domain_get` at the wrong moment faults inside the runtime). The one
   injection that works — the BattlEye bypass — works because it is **static
   `.text` byte-patches**, not managed activity. Byte-patches can change
   existing code; they cannot build a UI.
3. **`il2cpp_runtime_invoke` is on the wrong thread.** Driving the tab builders
   by invoke would have to run on Unity's main thread; `invoke_main` currently
   runs on the **host** thread (`host/Aowlspt.Host.Il2Cpp`), and instantiating
   prefabs off the main thread is undefined at best.
4. **There is no F-key hook to piggyback.** Input flows through `InputManager` →
   `ECommand` bindings; there is **no `KeyCode.F12` literal anywhere in
   metadata** and no hardcoded F-key handler. Opening the real screen on F12
   would itself require adding a managed `KeyCode→ECommand` binding and routing
   it — more live managed work.

**Conclusion: native injection into the real settings screen is high-risk /
effectively infeasible to make stable on this client today.** Per the project's
own rule ("do NOT build the whole UI on an unproven-unstable path"), the panel
is the **overlay-as-settings** fallback.

### The chosen technique: overlay-as-settings (proven stable)

`abi/aowlspt_overlay.h` already draws a panel by hand inside a hooked
`IDXGISwapChain::Present` — the same place Steam/Discord draw. It is proven
(Insert-toggled today), it never touches managed code, it already has a WndProc
input hook, a per-frame draw with full D3D11 state save/restore, an HTTP worker,
and a JSON feed from the backend. F12 now toggles it (`VkF12`,
`host/Aowlspt.Host.Il2Cpp/aowlhost.nim`). It is now the **built** settings
screen — a Tarkov-dark, left-nav/right-controls renderer over the declared
schema, described in §5 below. F12 toggles it; F2 (or the title-bar toggle)
switches between the settings screen and the mod manager the overlay already
carried.

---

## 2. The mod config schema API (`aowlspt/settings`)

A mod declares its settings once, in code, next to the handler that reads them.
The declaration is pure data; a mod that declares a schema and does nothing else
is still a no-op mod.

```nim
import aowlspt/settings

proc onLoad(): Status =
  loadConfig()
  declareSettings(@[
    floatSetting("opticFovMulti", "Optic FOV multiplier", 1.0,
                 lo = 0.5, hi = 2.0, step = 0.01, category = "FOV",
                 description = "FOV scale while aiming a magnified sight"),
    boolSetting("changeMouseSensitivity", "Scale mouse sensitivity", true,
                category = "Sensitivity"),
    keybindSetting("zoomToggleKey", "Toggle-zoom key", "M",
                   category = "Toggle zoom", implemented = false,
                   description = "Read but not wired: KeyCode enum mapping missing")])
  discard serve("/aowlspt/settings/" & ModGuid, proc(u,b,s: string): string =
    declaredSchemaJson().text)
  Ok
```

### Fields a setting declares

| Field | Meaning |
|---|---|
| `key` | the `config.json` key, verbatim |
| `label` | the human name on the row |
| `type` | `bool` / `int` / `float` / `enum` / `string` / `keybind` |
| `default` | the default, as a JSON literal |
| `lo` `hi` `step` | range + granularity (int/float) |
| `options` | the choices (enum) |
| `category` | the section/sub-page the row groups under |
| `description` | one sentence of help |
| `implemented` | **false → drawn greyed, with `description` as the reason** |

### Builders

`boolSetting`, `intSetting`, `floatSetting`, `enumSetting`, `stringSetting`,
`keybindSetting` — each takes the required fields positionally and the metadata
(`category`, `description`, `implemented`, and `lo/hi/step` or `options`) as
optional trailing arguments. The shortest call still produces a usable control.

### Serialisation and persistence

- `declaredSchemaJson(): Json` — the declared schema with **current values**
  folded in (read from `config.json`, falling back to the default). This is the
  body a `/aowlspt/settings/<guid>` route returns; the UI renders it directly.
- `applySetting(key, valueJson): Status` — persists one edit back into the mod's
  `config.json` (via the host's `config_set`). A mod that wants the value live
  re-runs its own `loadConfig`, because only the mod knows which runtime write a
  key feeds.

### `implemented = false` is the honest half

aowlspt ports upstream mods a capability at a time. A key whose value is read
and carried but not yet acted on is declared `implemented = false` with the
missing capability named — drawn greyed, never pretended to work. FOV Fix, for
example, marks the camera offsets, aim speeds and toggle-zoom keys not
implemented (see `mods/fov/fov.nim` `fovSchema`), matching its module comment.

---

## 3. The SPT server config surface

`reference/spt-config-settings.json` (generated by `tools/genspt_settings.py`
from `reference/spt-4.1-surface.json`) is the full SPT 4.1 server config
surface, as declared settings:

- **28 pages** — one per top-level SPT config file (`configs/*.json`: core,
  bot, hideout, ragfair, inventory, quest, trader, weather, …), the classes
  deriving from `BaseConfig`.
- **323 scalar settings** — every bool/int/float/string/enum, flattened up to
  three levels deep through nested config objects, grouped by `category`.
- **197 nested fields** — lists and dictionaries, listed for completeness and
  edited as raw JSON rather than a single control.
- **All `implemented = false`.** aowlspt is a from-scratch emulator with no SPT
  `ConfigServer`; it does not consume `configs/*.json`, so every value is shown
  but marked not-implemented. As aowlspt grows a backing feature for one, add
  its key to the `IMPLEMENTED` set in `tools/genspt_settings.py` and regenerate.

Regenerate:

```
python tools/genspt_settings.py
```

---

## 4. How it fits together (target architecture)

```
mod (client/server) --declareSettings--> /aowlspt/settings/<guid>  ┐
tarkov emulator mod --declareSettings--> /aowlspt/settings/<emu>   ├─ aggregated ─> F12 overlay panel
reference/spt-config-settings.json  (SPT surface, not-implemented)  ┘        │
                                                                             └─ edit ─> applySetting / config_set ─> config.json (persisted)
```

The overlay fetches the schema over its existing HTTP worker (the same one that
already drives the mod panel), draws a page per mod plus the SPT pages, and posts
edits back. The schema declaration, the persistence path, the F12 key, **and the
Tarkov-themed renderer** are all in place now — see §5.

---

## 5. The built settings screen (`abi/aowlspt_overlay.h`)

F12 opens the overlay; the title bar carries a **MANAGER | SETTINGS** toggle (F2
from the keyboard), and SETTINGS is the new screen. It is drawn by hand in
D3D11, in the same immediate-mode primitives as the mod manager, in the panel's
charcoal/tan palette — no managed IL2CPP is touched, so opening and closing it
cannot crash the game.

**Layout.** A left-hand page nav and a right-hand column of controls.

- **Nav (left):** one page per loaded mod, then the SPT config pages. Mod pages
  read in the panel's text colour; SPT pages are dimmed and tagged `NI`, because
  none of the SPT surface is backed yet. Click or arrow-key to select; Tab and
  `[` `]` change page.
- **Controls (right):** each setting is a row — label on the left, the right
  control on the right, drawn from the schema's `type`:
  - `bool` → an ON/OFF pill (click, Space, or Left/Right toggles);
  - `int`/`float` with a range → a slider (click or drag the track; Left/Right
    nudge by `step`), with the value beside it; without a range → a `−`/`+` pair;
  - `enum` → a `< value >` cycler;
  - `string` → a text box (click to edit, type, Enter commits, Esc cancels);
  - `keybind` → a capture box (click, then press a key);
  - SPT `nested` lists/dicts → the type shown, read-only.
  A detail strip under the list explains the selected row and, for a
  not-implemented one, why.

**"Not implemented yet."** Every SPT value, and every mod key a mod flagged
`implemented:false`, is drawn greyed with an `NI` badge and cannot be changed;
the detail strip prints `NOT IMPLEMENTED YET —` and the reason. This is the
explicit honesty requirement, enforced in one place (`canEdit`).

**Where the schema comes from.** The overlay's worker thread fetches, over the
backend on `127.0.0.1:443`:

- a **mod page** from `GET /aowlspt/settings/<guid>` — the mod's own declared
  schema, current values folded in. Reachable for every **server-side** mod
  (`classicmovement`, `morebots`, `blackdivision`, `sain`, `tarkov`), because
  server routes register on the backend the overlay talks to. `fov` is
  **client-only** (`{sideClient, sideSim}`): its route is not on the backend, so
  its page shows the honest "could not read this page" state. Making it reachable
  needs an in-process host→overlay schema push, which is a separate mechanism.
- the **SPT pages** from the new server-side **settings-hub mod**
  (`mods/settingshub`): `GET /aowlspt/settings/spt/index` for the page list and
  `GET /aowlspt/settings/spt/page/<id>` for one page. The hub carries the whole
  SPT surface embedded in source (`mods/settingshub/sptsurface.nim`, generated by
  `tools/gen_sptsurface.py` from `reference/spt-config-settings.json`), because
  nimony has no compile-time file read.

**Writing an edit back.** A change on an implemented mod row POSTs
`{"key":..,"value":<literal>}` to that mod's `/aowlspt/settings/<guid>` route;
the handler calls `applySettingFromBody` (in `aowlspt/settings`), which persists
the one key into `config.json` and — where the mod has a re-readable config
(`fov`, `classicmovement`, `blackdivision`) — reloads it live. The overlay then
re-fetches the page so the row shows the value the file kept.

---

## How to test

- **Build the schema API + a migrated mod:**
  `aowl build-mod mods/fov` (green).
- **Build the host with F12 wired:** `aowl build` (or the direct
  `nimony c --app:lib … aowlhost.nim`); the overlay now starts on `VkF12`.
- **Fetch a mod's schema in-game/offline:** GET `/aowlspt/settings/<guid>` —
  returns the declared schema with current values.
- **Regenerate the SPT surface:** `python tools/genspt_settings.py` → 28 pages,
  323 settings, all not-implemented.
- **Build the settings-hub mod (the SPT surface):**
  `aowl build-mod mods/settingshub` (green). Regenerate its embedded surface
  after the SPT reference changes: `python tools/gen_sptsurface.py`.
- **In-game (main session only):** launch the client, press **F12** — the
  overlay opens; the **SETTINGS** tab (or F2) shows the settings screen. Pick a
  mod or SPT page on the left, change a control on the right; SPT rows and
  flagged mod keys are greyed with an `NI` badge.
