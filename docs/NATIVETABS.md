# nativetabs — one declarative call adds a settings tab

**Status of every number here:** measured. RVAs from `tools/il2cpp_resolve.py`
against `D:\Aowlspt\GameAssembly.dll` + `.cache/global-metadata.dec.dat`;
offsets from `Il2CppMetadataRegistration.fieldOffsets` (`tools/fldoff.py`,
System.String self-check passing). Items marked **GAP** are not solved. Items
marked **LIVE** were observed in a running client during the postfx work.

Nothing in this document has been built yet. It exists to be checked once
instead of iterated three times.

---

## 0. Why the previous attempt was hard, in one paragraph

The postfx subtab was built by **cloning** — a strip cloned from
`Control Settings/Toggles`, dropped into another panel's content container. It
took five attempts and each failure was the same shape: a clone inherits the
donor's serialized wiring, and the container it was dropped into was owned by a
`LayoutGroup` that then re-arranged the game's own scroll view. Measured:
`SettingsList` went from `(0,-20)/(850,755)` to `(0,-420.5)/(850,354.5)`
because a sibling was added. Every fix negotiated with a layout system we had
no business being inside.

The foundation below never enters that argument, because it puts our rows
**inside a real panel**, in the container the game's own rows go into, laid out
by the group that already lays those rows out. Geometry stops being our
problem.

---

## 1. The API

```nim
type
  NtRowKind = enum ntToggle, ntSlider, ntChoice, ntLabel
  NtPanel = object                 ## opaque; a live panel + its row parent

proc defineTab(id, headerText: string; rows: proc(p: NtPanel)): bool
proc defineSubtabs(parentTabId: string;
                   subs: seq[(string, string, proc(p: NtPanel))]): bool

## inside a `rows` callback, one call per row:
proc ntToggleRow(p: NtPanel; key, label: string; value: bool;
                 onChange: NtBoolSink): bool
proc ntSliderRow(p: NtPanel; key, label: string;
                 value, lo, hi: float32; fmt: string;
                 onChange: NtFloatSink): bool
proc ntChoiceRow(p: NtPanel; key, label: string;
                 choices: seq[string]; index: int): bool
proc ntLabelRow(p: NtPanel; text: string): bool
```

`rows` is called **once**, when the panel is first shown. Not per frame.

---

## 2. The five mechanisms, and the game's own code for each

### 2.1 The top-row button — **GAP, see §3.1**

| what | RVA / offset | sharedness |
|---|---|---|
| `UIAnimatedToggleSpawner.SpawnObject()` | `0x16BC7F0` | UNIQUE |
| `.SetHeaderText(string,int)` | `0x16BCC30` | UNIQUE |
| `.SetActive(bool)` | `0x16BCCE0` | UNIQUE |
| `._spawnableToggle` (the prefab) | `@0xC0` | — |
| `._toggleGroup` | `@0xB0` | — |
| `._siblingIndex` | `@0xBC` | — |
| `UnityEngine.UI.Toggle.set_group(ToggleGroup)` | `0x55B9D30` | UNIQUE |
| `Toggle.m_Group` / `m_IsOn` | `@0x110` / `@0x120` | — |

The stock tabs are `UIAnimatedToggleSpawner`s on `SettingsScreen/Toggles`,
reachable at `SettingsScreen @0xC8..@0xE8`. Joining the stock `ToggleGroup`
via `set_group` makes exclusivity native — we do not enforce it.

### 2.2 The panel — instantiate a stock one, then empty it

| what | RVA / offset | sharedness |
|---|---|---|
| `Object.Instantiate(Object,Transform,bool)` | `0x52ADDA0` | UNIQUE |
| `SettingsTab.CleanupCreatedControls()` | `0x171BE50` | UNIQUE |
| `SettingsTab._createdControls : List<SettingControl>` | `@0x88` | — |
| `SettingsTab.Close()` | `0x171BDF0` | UNIQUE |
| `GameSettingsTab._settingsRoot : RectTransform` | `@0x98` | — |

Clone `Game Settings` under `SettingsScreen`, call
`CleanupCreatedControls` on the clone's own tab component to destroy the rows
it came with, and keep its Scroll View / SettingsList / Content / LayoutGroup
**untouched**. We add rows to `_settingsRoot`; the stock group lays them out.

**Risk to verify first:** the cloned panel carries a live `GameSettingsTab`
component whose `Awake`/`Show` may re-create stock rows. Mitigation, in order
of preference: (a) `CleanupCreatedControls` after its first show; (b) disable
the component. Both are one call; which is needed is a live question.

### 2.3 The rows — the tab's own prefab templates

| template | GameSettingsTab | GraphicsSettingsTab | PostFXSettingsTab |
|---|---|---|---|
| dropdown | `@0xA0` | `@0xB0` | `@0xB8` |
| float slider | `@0xA8` | `@0xC8` | `@0xB0` |
| toggle | `@0xB0` | `@0xB8` | `@0xC0` |

| call | RVA | sharedness |
|---|---|---|
| `SettingControl.SetText(string)` | `0x16FA890` | UNIQUE |
| `SettingControl.SetName(string)` | `0x16FA9D0` | UNIQUE |
| `SettingControl.SetSiblingIndex(int)` | `0x16FA910` | UNIQUE |
| `SettingControl.SetChangeAction(Action)` | `0x16FAFC0` | UNIQUE |
| `NumberSlider.Show(float,float,string)` | `0x16B4EA0` | UNIQUE |
| `NumberSlider.SetCurrentValue(float)` | `0x16B5300` | UNIQUE |
| `NumberSlider.CurrentValue()` | `0x16B5850` | UNIQUE |
| `SettingFloatSlider.Slider : NumberSlider` | `@0xA8` | — |

**LIVE:** this row path already works. The postfx build instantiated real
`SettingToggle` and `SettingFloatSlider` rows from these templates and the user
confirmed them on screen ("vanilla sliders").

### 2.4 `CreateControl` is reachable after all — **new**

`SettingsTab.CreateControl<T>(T prefab, Transform parent)` has exactly **one**
instantiation:

```
RVA=0x2B86E20   class<> method<object>   body-unique-in-genericMethodPointers
```

`method<object>` is the shared-reference instantiation, so it serves every
reference `T` — which is every settings prefab. Calling it instead of
`Instantiate` would let the **game** append the row to `_createdControls`, so
its own `CleanupCreatedControls` frees our rows and the ownership question in
`postfxrows.nim` disappears.

It needs a real `MethodInfo*` (a shared generic; NULL is not allowed). See
§3.2.

### 2.5 Dropdowns — reachable, same precondition

`SettingDropDown::BindTo<T>` has 7 instantiations;
`method<int>` is `0x2B81640`, `body-unique-in-genericMethodPointers`. Also
needs a `MethodInfo*`. Until §3.2 is solved, `ntChoiceRow` renders a labelled
row marked not-wired and says why — never a toggle wearing a dropdown's label.

`shared <RVA>` reports **UNKNOWN** for all generic bodies. That is a refusal,
not "unshared" — generic bodies are not in the per-image `methodPointers`
histogram at all.

---

## 3. The two real gaps. Neither is hand-waved.

### 3.1 We cannot construct a *new* `UIAnimatedToggleSpawner`

`SpawnObject()` is an instance method on a spawner **component**. Calling it on
a stock spawner adds a second toggle to *that* spawner — not a new tab. Getting
a new spawner needs either `AddComponent` on an injected klass or an
`Instantiate` of an existing spawner's GameObject.

Instantiating the spawner is a *clone*, but a materially better one than the
old approach: the clone's `_spawnableToggle @0xC0` prefab reference is shared
and correct, so the toggle it spawns is a genuine prefab instance rather than a
relabelled donor. **Known trap (measured, fact #93):** a cloned spawner keeps
the toggle it had already spawned *and* spawns a second one, so the clone must
be reaped down to the donor's child count.

**This is the one place the foundation still clones.** It is one object, in one
place, with a measured trap and a known reap — not the whole strip.

### 3.2 We cannot build a managed delegate, so "onValueChanged" is not directly reachable

`SetChangeAction(Action)` and every `BindTo` want a managed delegate or a
`GameSetting<T>`. Constructing either needs type injection or an instantiated
generic layout, and **`GameSetting<T>` has no reachable layout offline** — all
33,464 `Il2CppGenericClass` entries have a null `cached_class`.

The brief says "our toggle's onValueChanged drives SetActive" and separately
"NO polling". Those two cannot both hold today, and I would rather say so than
quietly poll. Three options, in order of preference:

1. **Detour `UnityEngine.UI.Toggle::set_isOn` @0x55BA430 (UNIQUE)** and drain
   it: a real event, no polling, one detour, and it is the same lever the
   coordinator already drives the game with by hand. Cost: one more detour, and
   the double-detour rule applies — if anything else ever hooks it, ride it.
2. **Read the `MethodInfo*` for `CreateControl`/`BindTo` out of a caller's
   metadata-usage slot** (the technique `nativeui.nim` already uses to warm
   `AddComponent<T>`), which unlocks §2.4 and §2.5 and lets the game do its own
   binding. This is the highest-value item in this document.
3. One `m_IsOn` byte read per frame from the existing Update drain. This *is*
   polling, but it is one guarded byte, not a node hunt — it is what the
   current code does and it is what the user's directive is really aimed at
   ("constantly poll for some ui element" = the multi-node hunts).

**Recommendation: (1) for activation now, (2) as the next foundation task.**

---

## 4. Activation — the one piece of steering we own

The game switches panels by `ESettingsGroup` inside
`SettingsScreen.ShowScreen` @0x1720DE0; our tab is not a group, so it will
never switch to our panel. So exactly one thing is ours: on our toggle turning
on, `SetActive(true)` our panel and `SetActive(false)` the stock one that was
up; on it turning off, the reverse.

Done in **one** place, with the finished-state readback that the postfx work
already proved is the right assertion: *exactly one panel under
`SettingsScreen` is active, and it is the one our selection names.* Two active
panels, or zero, is a failure.

Show/hide is driven from `uihooks.nim` when it lands; until then, the existing
`SettingsScreen::ShowScreen` postfix. **No hunts, no per-frame searching.**

---

## 5. Subtabs

`defineSubtabs` is the same primitive one level down: the strip lives in **our
own panel's** header band, never in a stock container, so no stock geometry is
touched and the entire padding/`LayoutGroup` saga does not recur. For
`("graphics", [...])` the "GRAPHICS SETTINGS" subtab shows the *stock* Graphics
panel and "POSTFX" shows ours — the stock panel is only ever `SetActive`d,
never re-parented and never written to.

---

## 6. Verification — `tools/nativetabs_check.py`

Three outcomes, PASS / FAIL / **INCONCLUSIVE**, asserted off the live tree with
Settings open:

1. the top row has `N+1` toggles and **all** report the same `m_Group @0x110`;
2. selecting ours leaves **exactly one** panel under `SettingsScreen` active,
   and it is ours;
3. our panel's row parent has **K** children where `K == the schema's row
   count` — not "more than zero";
4. **the negative, and the important one:** the stock Game / Graphics / Sound /
   Controls `SettingsList` geometry is byte-identical to a baseline captured
   with the feature off. This is what every previous attempt broke, and it is
   the check that can fail.

A `find` that reports STOPPED EARLY, an unreadable pointer or a screen that
never opened is INCONCLUSIVE, never PASS.

---

## 7. Order of work

0. this document, checked;
1. `nativetabs.nim` + `defineTab` + the §6 checker, proving one empty tab;
2. rows (§2.3 — already proven live);
3. `defineSubtabs`, then PostFX as its first consumer, deleting the clone,
   padding and per-panel backstop paths;
4. MODS tab on `/aowlspt/settings/index`;
5. Controls → MODS keybinds.

Each step verified live before the next.
