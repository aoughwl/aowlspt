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

> ### 1a. SUPERSEDED — native injection is now proven VIABLE (2026-08)
>
> The conclusion above was refuted live. The three "why not" reasons all assumed
> managed work happens on the **host** thread; the fix was to get onto the Unity
> thread, not to avoid managed work. See `abi/aowlspt_bridge.h` and the
> `il2cpp` bridge in `host/Aowlspt.Host.Il2Cpp/aowlhost.nim`.
>
> **What changed.** A **static-RVA** detour (BE-style, byte-verified, no runtime
> metadata read) on `SettingsScreen::Show` @ RVA `0x171FA00` was installed and
> **fired on the Unity main thread** on a live client, game alive:
> *"SettingsScreen.Show fired on thread 18156 (host thread 14760) ... Unity's
> main thread ... this=0x1b1d0f88bd0 (readable)."* So a detour DOES reach the
> Unity thread on a user action, and from inside it the whole runtime API
> (`il2cpp_runtime_invoke` / `object_new` / `value_box` / field walk) is safe --
> the reads that fault on the host thread do not fault here. Reasons 1-3 are
> answered; reason 4 (F-key) never applied (the overlay already toggles F12).
>
> **The RVAs are trustworthy.** The offline resolver `tools/il2cpp_resolve.py`
> (type -> image -> that image's `Il2CppCodeGenModule.methodPointers[rid-1]`)
> reproduces all five BE-bypass RVAs and every VA in this table byte-for-byte.
> The earlier "the methodPointers table is null / unreliable" belief was a
> module-mapping bug: `BattlEye.BEClient` is in `Assembly-CSharp-firstpass.dll`
> (table base `0x186BF1380`), not `Assembly-CSharp.dll`.
>
> **Injection targets (all `Assembly-CSharp.dll`, RVAs from imagebase
> 0x180000000, this build):**
>
> | Type | Member | RVA |
> |---|---|---|
> | `EFT.UI.Settings.GameSettingsTab` | `CreateControls` | 0x1703FB0 |
> | `EFT.UI.Settings.GameSettingsTab` | `ShowFieldOfView` (FOV row builder) | 0x17066A0 |
> | `EFT.UI.Settings.SettingFloatSlider` | `BindTo` (2 overloads) | 0x16FB4C0 / 0x16FB810 |
> | `EFT.UI.Settings.SettingFloatSlider` | `.ctor` | 0xCFD7D0 |
> | `EFT.UI.Settings.SettingsScreen` | `Show` / `OpenGroup` | 0x171FA00 / 0x1720C80 |
>
> Tab types (type indices): SettingsTab 15717 (abstract `CreateControl`),
> GameSettingsTab 15697, GraphicsSettingsTab 15711, SoundSettingsTab 15720,
> ControlSettingsTab 15683, PostFXSettingsTab 15715. Control types:
> SettingControl 15652, SettingFloatSlider 15662, SettingToggle 15677,
> SettingDropDown 15659, SettingSelectSlider 15668.
>
> **Status.** Bridge confirmed (managed box round-trips on the Unity thread).
> Field walk of the live `SettingsScreen` (STEP 2) reads the tab/control layout.
> Next: hook `GameSettingsTab::CreateControls` postfix and add one row (an FOV
> slider bound to the `fov` mod's config key) -- the whole thing gated behind the
> detour (touches only the screen the user opened), one control at a time,
> fail-safe (any offset/bind failure -> log + skip, never corrupt the screen).
> The overlay-as-settings below remains the fallback for anything not yet wired.

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
  **client-only** (`{sideClient, sideSim}`), as is `mods/graphics` (`{sideClient}`,
  twenty wired settings) and the client half of `mods/admin`: their routes are
  never registered anywhere at all -- the client host **refuses
  `route_register`**, because the game process serves no HTTP -- so the
  `SettingsIndexQuery` broadcast that fills the index (server-side, in
  `mods/settingshub`) could never hear them and their pages were absent from the
  F12 nav entirely.

  **This is now fixed by the in-process schema push.**
  `host/Aowlspt.Host.Il2Cpp/settingsbridge.nim` runs the same broadcast inside
  the GAME process over the event bus -- the one cross-mod channel the client
  host does implement -- collecting `SettingsIndexAnnounce` and, per mod,
  `SettingsPageAnnounce` (both added to `aowl/src/aowlspt/settings.nim`). It
  POSTs each mod's page to `POST /aowlspt/settings/client/sync`, and settingshub
  then lists it in `/aowlspt/settings/index` (tagged `"client":true`) and answers
  `GET /aowlspt/settings/<guid>` for it off a **fallback prefix** -- exact routes
  and longer prefixes still win, so no server mod's own route is displaced and
  **the overlay needed no change at all**.

  An edit is the same path backwards: the panel POSTs to the URL it always did,
  settingshub QUEUES it (it does not own the mod and must not pretend to), and
  the sync reply hands it to the game process, which emits `SettingsApplyQuery`
  at the owning mod. The mod persists it through the same
  `applySettingFromBody` its route uses and then runs its `onSettingsApplied`
  hook, so the change hot-applies where the runtime is. The deliberate
  non-solution is giving a client mod a server side: the page would appear and
  the edit would land in the wrong process -- a control that moves and changes
  nothing, which is worse than an absent page.

  `tools/settingsdump.py` is the check: it fetches the index and every page and
  asserts the negative -- *no mod declaring settings is absent from the nav, and
  no listed page is unreadable* -- tolerating and REPORTING the fact-#122
  unquoted-`value` invalidity, and verifying a `--set` by re-reading the value
  rather than by the status code (fact #135).
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

## 6. NATIVE injection, Phase 2 and Phase 3 — writing into the real screen

§1a recorded that native injection is *viable*; Phase 1 then read 78 real
controls off the live screen (labels decoded, klass pointers censused, widget
pointers in hand). That proved we can **see** the settings screen. Phases 2 and
3 are about **changing** it, because the standing requirement has never moved:
mod configuration belongs in Tarkov's own settings screen, not in our overlay.

Everything below is **default OFF**, rides the ShowScreen postfix the read probe
already installs (so it costs no extra detour), runs inside that postfix's
existing `aowl_p_p_seh` guard, and shares one fault budget — two faults and the
whole write side switches itself off for the session.

### The primitives, and what each one can actually do

| Primitive | Route | Repaints? |
|---|---|---|
| Label text | `il2cpp_string_new` → raw store into `TMP_Text.m_text` (+0xE0) → dirty byte (+0x378) | **yes** — TMP repaints from the flag |
| Toggle value | raw store into `Toggle.m_IsOn` (+0x120) | no — model only |
| Toggle value | direct call `Toggle::SetIsOnWithoutNotify` @0x55BA440 | **yes**, and fires no listener |
| Slider value | raw store into `Slider.m_Value` (+0x120) | no — model only |
| Slider value | direct call `Slider::SetValueWithoutNotify` @0x55B3420 | **yes**, and fires no listener |
| New control | `Object::Instantiate` + `TMP_DefaultControls::SetParentAndAlign` | **yes** — the only reflection-free way to make one |

The text row is why Phase 2a leads with relabelling: it is the one edit that is
complete and visible through a primitive already running in production (the
version brand and the F3 overlay both use it).

**Why clone rather than construct.** The game builds a row with
`SettingsTab::CreateControl<T>` @0x2B86E20 — one shared-generic body serving
every `T`, with the `T` carried entirely in the hidden `MethodInfo*`. A shared
generic is the single documented case where passing NULL for that `MethodInfo`
is *not* safe, and obtaining a real one needs the metadata reflection that is
dead on this build. So a row cannot be constructed; it can only be copied.

**Why *without-notify*.** A clone inherits its donor's `onValueChanged`
listeners. Seeding a cloned row with the notifying setter would run the **game's**
handler for the stock setting the donor came from, with our mod's value. The
without-notify variants repaint and stay quiet. The player's own click still
travels the game's normal path — which is exactly how the edit gets back to us.

### Telling the four widget types apart without reflection

`il2cpp_object_get_class` and `il2cpp_class_get_name` both fault here, so a
control's type cannot be *asked for* — it is *observed*. The klass pointer at
`obj+0x00` is stable within one process, and the live census found exactly four
distinct values across all 78 controls (dropdown 38, toggle 19, float slider 13,
select slider 8). The absolute values differ per launch, so the host learns them
per session by matching a control whose stock label is known — `'FOV:'` → float
slider, `'Enable VoIP'` → toggle, `'Device:'` → dropdown, `'Overall volume:'` →
select slider — and then types every other control by pointer equality alone.

Every control subclass carries its widget at the **same** offset, `+0xA8`,
because they all inherit the identical base field run and each declares exactly
one field of its own — which is why fetching the widget needs no per-type
dispatch, only interpreting it does.

### The flags

| Flag | Phase | What it does |
|---|---|---|
| `settingsRelabelProbe` | 2a | Rewrites the Game tab's `FOV:` row to `FOV: [aowlspt]`. Idempotent — never double-brands. |
| `settingsBindProbe` | 2b | Reads every recognised control's live value and logs it beside its label. Writes nothing. |
| `settingsPages` | 3 | Renders the host's own settings page into the Game tab by cloning a stock toggle row per entry. |

Each turns `settingsUiProbe` on with itself, because that flag is what arms the
hook they all run from.

### Phase 3 — the page framework

A page is a title plus rows; a row is a config key, a label, a kind and a value.
That is field-for-field the subset of `aowlspt/settings.Setting` (§2) a native
control can express — which is the point. **The schema layer already exists**:
every mod declares one with `declareSettings` and serves it at
`/aowlspt/settings/<guid>`. Phase 3 does not replace it; it adds a *second
renderer* for it, the native one, alongside the overlay's.

The first shipped page is the host's own flags out of `aowlspt-host.json`,
because the host can read those without asking anyone — it needs no HTTP and so
proves the renderer independently of the fetch. Rows that are carried but not
yet wired are suffixed **`(not done yet)`**, the same honesty `implemented =
false` already carries in the schema module.

**The seam.** `swPageRegister` takes a fully-formed page and the renderer
neither knows nor cares where it came from. Turning the other mods' schemas into
native pages is therefore a fetch and a parse into that one call — wiring, not
redesign.

**Read-back.** A row the player changes is read off its clone on the next tab
build and persisted into `aowlspt-host.json` by a key-targeted edit that mirrors
`readBoolKey`'s shallow scan: find the key, replace the token after the colon,
put the file back. Nothing else in the file moves.

### What the first live cycle still owes

Phase 2a/2b are read-and-relabel and are as proven as the primitives they reuse.
Phase 3 renders into a live UI graph and has **not** been through a live cycle
yet; specifically unverified are where the clones land in the tab's layout
(they are parented to the tab's own GameObject, reached via
`SettingsTab._rectTransform` @0x78 → `Component::get_gameObject`, which is
correct for *being drawn* but may not be the container the layout group drives),
and whether the clones survive a tab close/reopen. Both fail visibly and
harmlessly: a mis-parented row is a row in the wrong place, and a destroyed
clone re-renders on the next build.

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
