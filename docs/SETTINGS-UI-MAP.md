# The post-1.0 Tarkov settings screen — complete offline map

Build: `D:\Games\Tarkov\GameAssembly.dll` (123,891,024 bytes, 2026-08-12),
decrypted metadata `.cache/global-metadata.dec.dat` (27,776,072 bytes).
Imagebase `0x180000000`; every address below is an **RVA** unless written `VA`.
Runtime address = `GameAssemblyBase + RVA`.

**Instrument for every MEASURED line, unless stated otherwise:**

```
python tools/il2cpp_resolve.py D:/Games/Tarkov/GameAssembly.dll .cache/global-metadata.dec.dat <verb> ...
```

abbreviated below as `R <verb>`. Verbs used: `find`, `fields`, `typemethods`,
`genericmethods`, `disasm`, `callers`, `shared`, `symbolize`.

Live cross-check: `docs/settings-tree-live-2026-09-02.txt` (live inspector,
GRAPHICS tab up, POSTFX subtab selected). Cited as **LIVE**.

Every statement is tagged **MEASURED**, **LIVE**, **KNOWN-FROM-SOURCE** (Unity
uGUI open source; behaviour not derivable from this build's disasm alone) or
**INFERRED**. Where an existing doc or the current host code disagrees, §7
names it.

---

## 1. Object model

### 1.1 `EFT.UI.Settings.SettingsScreen` — type index 15735, `Assembly-CSharp.dll`

MEASURED `R fields EFT.UI.Settings.SettingsScreen`.
Three-state offsets: a hex offset, `--` for a const/literal (no storage),
`GENERIC` for a field declared by an uninstantiated generic base.

| Offset | Field | Type | Declared by |
|---|---|---|---|
| `0x10` | `m_CachedPtr` | IntPtr | UnityEngine.Object |
| `0x60` | `_children` | List\<InputNode\> | InputNodeAbstract |
| `0x70` | `UI` | UIParent | EFT.UI.UIInputNode |
| `0x78` | `_rectTransform` | RectTransform | EFT.UI.UIInputNode |
| `0x80` | `_showCoroutine` | Coroutine | UIScreen |
| `0x88` | `_hideCoroutine` | Coroutine | UIScreen |
| **GENERIC** | `ScreenController` | var | ``EFT.UI.Screens.BaseScreen`3`` |
| **GENERIC** | `<Destroyed>k__BackingField` | bool | ``BaseScreen`3`` |
| `0xa0` | `_loader` | GameObject | SettingsScreen |
| `0xa8` | `_saveButton` | DefaultUIButton | SettingsScreen |
| `0xb0` | `_backButton` | DefaultUIButton | SettingsScreen |
| `0xb8` | `_defaultButton` | DefaultUIButton | SettingsScreen |
| `0xc0` | `_creditsButton` | DefaultUIButton | SettingsScreen |
| `0xc8` | `_gameButton` | UIAnimatedToggleSpawner | SettingsScreen |
| `0xd0` | `_graphicsButton` | UIAnimatedToggleSpawner | SettingsScreen |
| `0xd8` | `_postFXButton` | UIAnimatedToggleSpawner | SettingsScreen |
| `0xe0` | `_soundButton` | UIAnimatedToggleSpawner | SettingsScreen |
| `0xe8` | `_controlsButton` | UIAnimatedToggleSpawner | SettingsScreen |
| `0xf0` | `_gameSettingsScreen` | GameSettingsTab | SettingsScreen |
| `0xf8` | `_graphicsSettingsScreen` | GraphicsSettingsTab | SettingsScreen |
| `0x100` | `_postFXSettingsScreen` | PostFXSettingsTab | SettingsScreen |
| `0x108` | `_soundSettingsScreen` | SoundSettingsTab | SettingsScreen |
| `0x110` | `_controlsSettingsTabScreen` | ControlSettingsTab | SettingsScreen |
| `0x118` | `_currentTab` | SettingsTab | SettingsScreen |
| `0x120` | `_session` | IEftSession | SettingsScreen |
| `0x128` | `_profileInfo` | ProfileInfo | SettingsScreen |
| `0x130` | `_customization` | BodyCustomization | SettingsScreen |
| `0x0` (**static**) | `_tabs` | `Dictionary<ESettingsGroup,SettingsGroupObjects>` | SettingsScreen |
| `0x138` | `_initializedTabs` | HashSet\<ESettingsGroup\> | SettingsScreen |

**`0x90` is `ScreenController`.** MEASURED-BY-USE, not from the field table —
the table reports `ScreenController` as `GENERIC` because it is declared by
``BaseScreen`3``. `R disasm 0x1720de0` reads `[this+0x90]`, writes
`[rax+0x60] = group` and calls through it; `R disasm 0x171f970` passes
`[this+0x90]` to `SettingsScreenController::InitSettings @0x1721AE0`. So
`ScreenController@0x90`, `<Destroyed>k__BackingField@0x98` — derived from use.
**The offline offset table cannot confirm this.**

`SettingsScreenController` holds the **last opened `ESettingsGroup` at `+0x60`**
(MEASURED: `ShowScreen` writes it; `Show(controller)` reads it and passes it to
`OpenGroup`). `[ctrl+0x50]` is the settings-group container; MEASURED
`R disasm 0x171ff10` reads `+0x10` = GameSettingsGroup, `+0x18` =
SoundSettingsGroup, `+0x20` = PostFxSettingsGroup, `+0x28` =
GraphicsSettingsGroup, `+0x30` = ControlSettingsGroup.

### 1.2 `ESettingsGroup` — type index 15721

MEASURED `R fields ESettingsGroup`:

| Name | Value |
|---|---|
| `Screen` | **0** |
| `Game` | 1 |
| `Sound` | 2 |
| `Control` | 3 |
| `PostFX` | 4 |

**The "GRAPHICS" tab is `ESettingsGroup.Screen == 0`.** There are exactly five
values and no spare. There is no legal sixth value — see §5 T1.

### 1.3 `SettingsGroupObjects` — type index 15729, a `System.ValueType`

MEASURED `R fields SettingsGroupObjects`: boxed offsets `Tab@0x10`
(SettingsTab), `Toggle@0x18` (UIAnimatedToggleSpawner). **Unboxed the struct is
`{ SettingsTab Tab; UIAnimatedToggleSpawner Toggle; }` at `+0x0` / `+0x8`** —
MEASURED by use: `R disasm 0x1720de0` reads `[rax+0]` as the tab and
`R disasm 0x1720c80` reads `[rax+8]` as the spawner, from the same
`Dictionary::get_Item` sret buffer.

Its only method, `.ctor(SettingsTab, UIAnimatedToggleSpawner)` @`0x663770`,
is **SHARED x26** — correct to call, never to detour.

### 1.4 `EFT.UI.Settings.SettingsTab` (abstract base) — type index 15717

MEASURED `R fields`:

| Offset | Field | Type |
|---|---|---|
| `0x70` | `UI` | UIParent |
| `0x78` | `_rectTransform` | RectTransform (**reads null in practice** — §5 T7) |
| `0x80` | `OnLoadingInProgress` | Action\<bool\> |
| `0x88` | `_createdControls` | List\<SettingControl\> |
| `0x90` | `<IsInitialized>k__BackingField` | bool |

MEASURED `R typemethods EFT.UI.Settings.SettingsTab`:

| Member | RVA | sharedness |
|---|---|---|
| `set_IsSelected(bool)` | `0x171BCA0` | UNIQUE |
| `OnTabSelected()` | `0x171BDA0` | UNIQUE |
| `OnFirstSelect()` virtual | `0x628110` | **STUB, SHARED x9614** |
| `OnSelect()` virtual | `0x628110` | **STUB, SHARED x9614** |
| `Close()` virtual | `0x171BDF0` | UNIQUE |
| `CleanupCreatedControls()` | `0x171BE50` | UNIQUE |
| `SetLoadingStatus(bool)` | `0x171C0D0` | UNIQUE |
| `ResetInitialization()` | `0x14F3560` | SHARED x3 |
| `get_IsInitialized()` | `0xCAD190` | SHARED x13 |
| `set_IsInitialized(bool)` | `0xCF6C70` | SHARED x9 |
| `CreateControl<T>(T prefab, Transform parent)` | **generic body `0x2B86E20`** | §5 T5 |
| `.ctor()` | `0xCFD7D0` | **SHARED x26, TAILJUMP** |

**Virtual slot offsets in the `Il2CppClass` vtable, MEASURED from disasm** (each
slot is `{ methodPtr; MethodInfo* }`, 16 bytes):

| Slot pair | Method | Evidence |
|---|---|---|
| `klass+0x288` / `+0x290` | `Close()` | `R disasm 0x17207a0` calls it for each initialized tab |
| `klass+0x2C8` / `+0x2D0` | `OnFirstSelect()` | `R disasm 0x171bca0` at `+0x92` |
| `klass+0x2D8` / `+0x2E0` | `OnSelect()` | `R disasm 0x171bca0` at `+0xa2` |
| `klass+0x2E8` / `+0x2F0` | `ControlSettingsTab::Show` (6 args) | `R disasm 0x171ff10` at `+0x150` |
| `klass+0x468` / `+0x470` | a `SettingsScreenController` bool getter | `R disasm 0x171ff10`, three call sites |

### 1.5 The five tabs

All five derive from `SettingsTab`. Offsets MEASURED `R fields`; RVAs MEASURED
`R typemethods`.

#### `GraphicsSettingsTab` (15711) — GameObject **"Graphics Settings"** (LIVE)

| Offset | Field | Type |
|---|---|---|
| `0x98` | `_settingsContainer` | Transform |
| `0xa0` | `_settingsScroll` | ScrollRect |
| `0xa8` | `_tooltip` | SettingsTooltip |
| `0xb0` | `_dropDownTemplate` | SettingDropDown |
| `0xb8` | `_toggleTemplate` | SettingToggle |
| `0xc0` | `_selectSliderTemplate` | SettingSelectSlider |
| `0xc8` | `_selectFloatSliderTemplate` | SettingFloatSlider |
| `0xd0` | `_selectSliderWideTemplate` | SettingSelectSlider |
| `0xd8` | `_tempSettings` | GraphicsSettingsGroup |
| `0xe0` | `_originalSettings` | GraphicsSettingsGroup |
| `0xe8`..`0x120` | eight `BlockBySettingController<T>` | vsync / framerate / dlss-on / dlss-off / fsr2 / fsr3 / reflex / sampling |
| `0x128` | `_inRaidBlockController` | BlockController |
| `0x130` | `_nvidiaReflexNotAvailableBlockController` | BlockController |
| `0x138` | `_dlssNotAvailableBlockController` | BlockController |
| `0x140` | `_isInRaidBlockersActive` | bool |
| `0x141` | `_textureMessageShown` | bool |
| `0x144` | `_currentControlIndex` | int |
| `0x148` | `_screenValidation` | Action |

Key RVAs: `Show(GraphicsSettingsGroup, bool)` `0x170A780`;
`OnFirstSelect()` `0x170A8B0`; `CreateBlockers()` `0x170AA50`;
`CreateControls()` `0x170BBA0`; `LateUpdate()` `0x17148B0`;
`RefreshDropDownsCoroutine()` `0x1714810`;
`TakeSettingsFrom(SettingsManager)` `0x1714720`;
`ChangeDisplaySettings` `0x1714C60`; `.cctor()` `0x17150B0`;
`.ctor()` `0xCFD7D0` (**SHARED x26**).
Thirty-two `Show*()` row builders, `0x170BD00`..`0x1714440`, all UNIQUE **except
`ShowMipStreaming()` which is `0x628110`** — the universal empty stub. MEASURED:
that feature is compiled out, not merely unused.

`GraphicsQualityPresets : string[]` is a **static** field at slot `0x0`; the five
preset name literals (`ULTRA`/`HIGH`/`MEDIUM`/`LOW`/`VERY_LOW`) are `--` consts.

#### `PostFXSettingsTab` (15715) — GameObject **"PostFX Settings"** (LIVE)

| Offset | Field | Type |
|---|---|---|
| `0x98` | `_mainToggleRoot` | RectTransform |
| `0xa0` | `_settingsRoot` | RectTransform |
| `0xa8` | `_tooltip` | SettingsTooltip |
| `0xb0` | `_selectFloatSliderTemplate` | SettingFloatSlider |
| `0xb8` | `_dropDownTemplate` | SettingDropDown |
| `0xc0` | `_toggleLeftTemplate` | SettingToggle |
| `0xc8` | `_visualizeButton` | DefaultUIButton |
| `0xd0` | `_postFxBlockController` | BlockBySettingController\<bool\> |
| `0xd8` | `_postFXSettingsGroup` | PostFxSettingsGroup |
| `0xe0` | `_screenController` | SettingsScreenController |
| `0xe8` | `_currentControlIndex` | int |

RVAs: `Show(PostFxSettingsGroup, SettingsScreenController)` `0x17193C0`;
`OnFirstSelect()` `0x1719490`; `ShowContent(ctrl)` `0x17194A0`;
`CreateBlockers()` `0x1719540`; `CreateControls()` `0x17197A0`;
`Close()` `0x171B270`; `TakeSettingsFrom` `0x171B180`; nine `Show*` row builders
`0x1719820`..`0x171AE00`.

#### `GameSettingsTab` (15697) — GameObject **"Game Settings"** (LIVE)

`_settingsRoot@0x98` (RectTransform), `_dropDownTemplate@0xa0`,
`_floatSliderTemplate@0xa8`, `_toggleTemplate@0xb0`, `_tooltip@0xb8`,
`_nicknameInput@0xc0`, `_changeNicknameButton@0xc8`, `_nicknameBlocker@0xd0`,
`_clearWishlistButton@0xd8`, `_iconsSettings@0xe0`, `_gameSettings@0xe8`,
`_controller@0xf0`, `_backEndSession@0xf8`, `_profile@0x100`,
`_changedNickname@0x108`, `_changeNicknameDateUtc@0x110`,
`_inRaidBlockController@0x120`, `_currentControlIndex@0x128`,
`_isInRaidUiBlockersActive@0x12c`.
`Awake` `0x1703480`, `Update` `0x1703680`,
`Show(GameSettingsGroup, IEftSession, bool)` `0x17037A0`,
`OnFirstSelect` `0x1703CB0`, `CreateBlockers(bool)` `0x1703E30`,
`CreateControls` `0x1703FB0`, `ShowFieldOfView` `0x17066A0`, `Close` `0x17083D0`.

#### `SoundSettingsTab` (15720) — GameObject **"Sound Settings"** (LIVE)

`_slidersSection@0xa0` (Transform), `_togglesSection@0xa8`,
`_selectSliderPrefab@0xb0`, `_floatSliderPrefab@0xb8`, `_dropDownPrefab@0xc0`,
`_togglePrefab@0xc8`, `_voipEnableBlocker@0xd0`, `_voipBanBlocker@0xd8`,
`_voipBanMessageText@0xe0`, `_voipBanMessage@0xe8`,
`_voipDropDownsSection@0xf0`, `_voipSlidersSection@0xf8`, `_tooltip@0x100`,
`_soundSettings@0x108`, `_controller@0x110`, `_profileInfo@0x118`,
`_voipBan@0x120`, `_cachedSeconds@0x128`, `_deviceEnumDropDown@0x130`,
`_deviceCollectionDropDown@0x138`, `_voipEnabledToggle@0x140`,
`_audioConfigurationSubscribed@0x148`.
`Show(SoundSettingsGroup, ProfileInfo)` `0x171C100`; `OnFirstSelect` `0x171C400`;
**`OnSelect` `0x171C520` — the only tab that overrides `OnSelect` with a real
body**; `Close` `0x171E370`; `.ctor` `0x171E580` (UNIQUE, unlike the other four).

#### `ControlSettingsTab` (15683) — GameObject **"Control Settings"** (LIVE). **The subtab reference implementation.**

| Offset | Field | Type |
|---|---|---|
| `0x98` | `_commandKeyPairTemplate` | CommandKeyPair |
| `0xa0` | `_commandAxisPairTemplate` | CommandAxisPair |
| `0xa8` | `_commandsContainer` | RectTransform |
| `0xb0` | `_sensitivityRoot` | RectTransform |
| `0xb8` | `_invertAxisRoot` | RectTransform |
| `0xc0` | `_toggleTemplate` | SettingToggle |
| `0xc8` | `_selectFloatSliderTemplate` | SettingFloatSlider |
| `0xd0` | `_tooltip` | SettingsTooltip |
| `0xd8` | `_controlButton` | **UIAnimatedToggleSpawner** |
| `0xe0` | `_gesturesButton` | **UIAnimatedToggleSpawner** |
| `0xe8` | `_controlPanel` | GameObject |
| `0xf0` | `_gesturesPanel` | GameObject |
| `0xf8` | `_gesturesMenu` | GesturesMenu |
| `0x118` | `_controlSettings` | ControlSettingsGroup |
| `0x120` | `_soundSettings` | SoundSettingsGroup |
| `0x128` | `_forbiddenKeys` | EGameKey[] |
| `0x130` | `_notInteractableKeys` | EGameKey[] |
| `0x138` | `_forbiddenAxis` | EAxis[] |
| `0x140` | `_gesturesStorage` | GesturesCommandsStorage |
| `0x148` | `_speaker` | BaseSpeaker |
| `0x150` | `_gesturesReady` | bool |
| `0x158` | `_profileInfo` | ProfileInfo |
| `0x160` | `_customization` | BodyCustomization |
| `0x168` | `_isUiBlockersActive` | bool |
| `0x16c` | `_currentControlIndex` | int |

RVAs: `Awake` `0x16FD410`; `Show` (6 args) `0x16FD4F0`;
`CreateControls` `0x16FD990`; **`HandleGesturesToggle(bool isOn)` `0x16FED50`**;
`ShowBindings` `0x16FF000`; `CreateAxisBinding` `0x1700200`;
`KeyChosen` `0x1700680`; `AxisChosen` `0x1700C00`; `Close` `0x1700FC0`;
`CleanUpBindingObjects` `0x1701350`; `OnFirstSelect` `0x16FFF80`;
`OnSelect` `0x16FFFB0`; `SetLockGameObject` `0x1701BE0`; `.ctor` `0x1701CA0`.

LIVE confirms the shape: `Control Settings > Toggles > {ControlToggle,
GesturesToggle}` beside `Control Settings > Content > {ControlsPart, GesturesPanel}`.

### 1.6 The toggle chain

**`EFT.UI.UIAnimatedToggleSpawner` (15473)**, base ``EFT.UI.UISpawner`1``.
MEASURED `R fields`:

| Offset | Field | Type |
|---|---|---|
| `0x60` | `UI` | UIParent (from `EFT.UI.UIElement`) |
| `0x68` | `_rectTransform` | RectTransform |
| **GENERIC** | `_object`, `_headerCaption`, `_headerFontSize`, `_preservedChildren`, `_minWidth`, `_useEllipsis`, `_localizationSubscription`, `_spawnedObject` | ``UISpawner`1`` |
| `0xa8` | `_canvasGroup` | CanvasGroup |
| `0xb0` | `_toggleGroup` | **ToggleGroup** |
| `0xb8` | `_unavailable` | bool |
| `0xbc` | `_siblingIndex` | int |
| `0xc0` | `_spawnableToggle` | UISpawnableToggle (the prefab) |

The ``UISpawner`1`` fields are **GENERIC — no offsets exist offline.** IL2CPP
writes an all-zero fieldOffsets row for the open generic; the concrete layout is
built at runtime. `_spawnedObject` must be read via
``UISpawner`1::get_SpawnedObject()`` **generic body `0x37EA0C0`**, never at a
guessed offset.

Methods: `get_IsToggled` `0x16BC5D0`, `set_IsToggled` `0x16BC600`,
`get_SpawnableToggle` `0x16BC670`, `SpawnObject` `0x16BC7F0`,
`SetEllipsis` `0x16BCA00`, `ToggleSilently(bool)` `0x16BCBA0`,
`SetHeaderText(string,int)` `0x16BCC30`, `SetActive(bool)` `0x16BCCE0`,
`.ctor` `0x16BCED0` — **all nine UNIQUE.**

**`EFT.UI.UISpawnableToggle`**: `_unavailable@0x70`, `_canvasGroup@0x78`,
`_tooltipArea@0x80`, `_enabledTooltipGetter@0x88`, `_disabledTooltipGetter@0x90`,
`_onPointerEnterSound@0x98`, `_hoverSound@0x9c`, `_onPointerClickSound@0xa0`,
`_clickSound@0xa4`, `_headerLabel@0xa8` (TextMeshProUGUI), `_sizeLabel@0xb0`
(TextMeshProUGUI), `_iconSprite@0xb8` (Image), `_isBoldOnHover@0xc0`,
`HoverImage@0xc8` (GameObject), **`Toggle@0xd0` (AnimatedToggle)**,
`_originalFontStyle@0xd8`.

**`EFT.UI.AnimatedToggle` (15413)**, base `UnityEngine.UI.Toggle`:

| Offset | Field | Declared by |
|---|---|---|
| `0x20` | `m_EnableCalled` | Selectable |
| `0x28` | `m_Navigation` | Selectable |
| **`0x50`** | **`m_Transition`** | Selectable |
| `0x54` | `m_Colors` | Selectable |
| `0xb0` | `m_SpriteState` | Selectable |
| `0xd0` | `m_AnimationTriggers` | Selectable |
| `0xd8` | `m_Interactable` | Selectable |
| `0xe0` | `m_TargetGraphic` | Selectable |
| `0xf8` | `m_CanvasGroupCache` | Selectable |
| **`0x100`** | **`toggleTransition`** | Toggle |
| `0x108` | `graphic` | Toggle |
| **`0x110`** | **`m_Group`** | Toggle |
| **`0x118`** | **`onValueChanged`** (ToggleEvent) | Toggle |
| **`0x120`** | **`m_IsOn`** | Toggle |
| **`0x128`** | `_onTrigger` (string) | AnimatedToggle |
| **`0x130`** | `_offTrigger` (string) | AnimatedToggle |
| `0x138` | `OnMouseDown` (Action) | AnimatedToggle |

Methods: `OnPointerClick` `0x16AD5D0`, `OnPointerDown` `0x16ACE90`,
`Awake` `0x16ACF30`, `OnEnable` `0x16AD110`, `set_IsToggled` `0x16AD190`,
`ToggleSilent(bool)` `0x16AD1E0`, `TriggerAnimation(bool)` `0x16AD230`,
`TriggerAnimation(string)` `0x16AD260`, `InstantClearState` `0x16AD660`,
`.ctor` `0x16AD710` — UNIQUE. `get_IsToggled` `0x66E7C0` is **SHARED x10**, the
same body as `Toggle::get_isOn`.

**`UnityEngine.UI.ToggleGroup`**: `m_AllowSwitchOff@0x20` (bool),
`m_Toggles@0x28` (List\<Toggle\>).
`NotifyToggleOn(Toggle,bool)` `0x55BABC0`, `RegisterToggle` `0x55BAE50`,
`UnregisterToggle` `0x55BADD0`, `AnyTogglesOn` `0x55BB360`,
`ActiveToggles` `0x55BB590`, `GetFirstActiveToggle` `0x55BB700`,
`SetAllTogglesOff(bool)` `0x55BB780`, `EnsureValidState` `0x55BAF10`,
`ValidateToggleIsInGroup` `0x55BAA00`, `.ctor` `0x55BA8F0` — all UNIQUE.
`get_allowSwitchOff` `0x6AC8B0` SHARED x66; `set_allowSwitchOff` `0x6AC8C0`
SHARED x43; `Start`/`OnEnable` share `0x55BA9F0`.

MEASURED `List<T>` runtime layout, read out of `NotifyToggleOn`'s own code
(`R disasm 0x55babc0`): `_items@0x10`, `_size@0x18`, element 0 of the `T[]` at
`+0x20`, stride 8 for a reference `T`. **Borrowed from a verified body** — the
offline field table cannot give an instantiated generic's layout.

### 1.7 The row/control classes

`EFT.UI.Settings.SettingControl` (15652), base `EFT.UI.UIInputNode`:

| Offset | Field | Type |
|---|---|---|
| `0x70` | `UI` | UIParent |
| `0x78` | `_rectTransform` | RectTransform |
| **`0x80`** | **`Text`** | **LocalizedText** |
| `0x88` | `_blocker` | UiElementBlocker |
| `0x90` | `NotifyUserChanged` | Action |
| `0x98` | `_tooltipSettingsHover` | SettingsHoverTooltipArea |
| `0xa0` | `_elementBlocker` | UiElementBlocker |

Every subclass adds exactly one field at `0xa8`:

| Subclass | `0xa8` | Bind entry point |
|---|---|---|
| `SettingToggle` (15677) | `Toggle : UpdatableToggle` | `BindTo(GameSetting<bool>)` `0x16FD0D0` UNIQUE |
| `SettingFloatSlider` (15662) | `Slider : NumberSlider` | `BindTo(GameSetting<int>,int,int)` `0x16FB4C0`; `BindTo(GameSetting<float>,float,float,string)` `0x16FB810` — both UNIQUE |
| `SettingDropDown` (15659) | `DropDown : DropDownBox` | `BindToEnum` / `BindTo` are **NO-CODE** (uninstantiated generics) |
| `SettingSelectSlider` (15668) | `Slider : SelectSlider` | three `BindIndexTo` overloads, all **NO-CODE** |

`SettingControl` methods: `InitSetting(IGameSetting)` `0x16FA7C0`,
**`SetText(string localizationKey)` `0x16FA890`**, `SetSiblingIndex(int)`
`0x16FA910`, `SetName(string)` `0x16FA9D0`, `GetOrCreateTooltip()` `0x16FAA50`,
`SetTooltip(SettingsTooltipData, SettingsTooltip)` `0x16FAC00`,
`SetChangeAction(Action)` `0x16FAFC0` — UNIQUE.
`get_Blocker()` `0x690F30` SHARED x92; `SetValueText` `0x628110` **STUB** on the
base (`SettingDropDown` overrides it at `0x16FB390`, `SettingSelectSlider` at
`0x16FBBE0`); `get_TargetComponent()` is NO-CODE on the base and `0x66E6C0`
(**SHARED x60**) on every subclass. `.ctor` `0xCFD7D0` SHARED x26.

**Keybind rows.** `CommandKeyPair` (15650), base `EFT.UI.UIElement`:
`_commandName@0x70` (**LocalizedText**), `_keyButton@0x78` (Button),
`_keyName@0x80` (**plain TMP_Text**), `_key2Button@0x88`, `_key2Name@0x90`
(TMP_Text), `_emptyPressTypeCell@0x98`, `_unavailableCell@0xa0`,
`_typeDropdown@0xa8`, `_commandBackground@0xb0`, `_keyBackground@0xb8`,
`_key2Background@0xc0`, `_pressTypeBackground@0xc8`,
`_unavailableBackground@0xd0`, `_defaultBackgroundColor@0xd8` (Color, 16 bytes),
`_resetBackgroundColor@0xe8`, `_notInteractableTextColor@0xf8`,
`<KeyGroup>k__BackingField@0x108`, `OnKeyPressedAction@0x110`,
`OnKeyChosenAction@0x118`, `_interactable@0x120`, `_isEmpty@0x121`,
`_pressTypes@0x128`.
`Show(KeyGroup, Dictionary<string,EPressType>, bool)` `0x16F9340`;
`ListenForKey(TMP_Text,int)` `0x16F81E0`;
`UpdateKeyNameText(TMP_Text,int)` `0x16F82F0`; `UpdatePressTypeCell` `0x16F84C0`;
`ResetInput(int)` `0x16F8C20`; `.ctor` `0x16F9B60` — UNIQUE.

`CommandAxisPair` (15646) derives straight from `MonoBehaviour` (**not**
`UIElement`), so its layout starts at `0x20`: `_commandName@0x20`,
`_keyButton@0x28`, `_keyName@0x30` (CustomTextMeshProUGUI), `_key2Button@0x38`,
`_key2Name@0x40`, backgrounds `0x48`/`0x50`/`0x58`, colors `0x60`/`0x70`,
`<AxisGroup>@0x80`, `<Positive>@0x88`, `OnKeyPressedAction@0x90`,
`OnKeyChoosedAction@0x98`.
`Show(AxisGroup,bool)` `0x16F7670`; `Awake` `0x16F6D90`;
`.ctor` `0x629540` **SHARED x676**.

### 1.8 `EFT.UI.LocalizedText`

`localizationKey@0x70`, `_labels@0x78` (List\<TextMeshProUGUI\>),
`_stringCase@0x80`, `_formatTemplate@0x88`, `_formatValues@0x90`,
`_localeUnsubscriber@0x98`, `<FormattedText>k__BackingField@0xa0`.

| Member | RVA | sharedness |
|---|---|---|
| `set_LocalizationKey(string)` | `0x140F8B0` | UNIQUE |
| `OnEnable()` | `0x140F910` | UNIQUE |
| `GetTextFromObject()` | `0x140FAE0` | UNIQUE |
| **`UpdateLocale()`** | **`0x140FDB0`** | UNIQUE |
| **`SetLabelText(string)`** | **`0x140FE70`** | UNIQUE |
| `SetFormatValues(object[])` | `0x1410100` | UNIQUE |
| `get_LocalizationKey()` | `0x65ED10` | SHARED x107 |
| `set_FormattedText(string)` | `0x691060` | SHARED x34 |
| `OnDestroy()` | `0xCD3EA0` | SHARED x11 |

---

## 2. Control flow, method by method

### 2.1 Opening the screen

`SettingsScreen::Show(SettingsScreenController controller)` @ **`0x171F970`** —
PUBLIC **VIRTUAL**; a direct call at the RVA runs this body even for a derived
receiver. MEASURED `R disasm 0x171f970 --to 0x171fa00`:

```
ctrl = this.ScreenController@0x90
ctrl.InitSettings(SettingsManager)         ; call 0x1721AE0, MethodInfo* = NULL (r8=0)
this.Show()                                ; call 0x171FA00, the 0-arg UIScreen show
this.SetSaveButtonActive(true)             ; call 0x1720FD0, rdx=1, r8=NULL
this.OpenGroup( (ESettingsGroup)[ctrl+0x60] )    ; TAIL JMP 0x1720C80
```

The last statement is a **tail `jmp`**: a postfix detour on `Show(controller)`
has no return site. `Show()` (0-arg) is `0x171FA00`, PRIVATE, UNIQUE.
`Awake()` is `0x171E940`, UNIQUE.

### 2.2 `Awake` builds the static `_tabs` map and wires the tab toggles

MEASURED `R disasm 0x171e940 --to 0x171f970`, calls extracted:
``Dictionary`2::TryInsert`` `0x3FAD640` (populating the **static** `_tabs`),
``UISpawner`1::get_SpawnedObject`` `0x37EA0C0`,
`System.Delegate::Combine` `0x45D5F30`,
`UnityEngine.Events.UnityEvent::AddListener(UnityAction)` `0x52C3260`,
`Enumerator::MoveNext` `0x2CA8AE0`, `CompositeDisposable::AddDisposable`
`0x1D24DB0`, `Array::Clear` `0x459A0E0`.

The tab-toggle handler is a compiler-generated closure. MEASURED
`R callers 0x1720de0`:

```
0x17240BE  jmp in <>c__DisplayClass26_0::<Awake>b__1(bool isOn) @0x17240A0 +0x1E
```

and MEASURED `R disasm 0x17240a0 --to 0x17240d0`, in full:

```
<Awake>b__1(this, bool isOn):
    if (!isOn) return;                        ; test dl,dl / je
    screen = this.<>4__this@0x28
    if (screen == null) throw
    ShowScreen(screen, (ESettingsGroup)this.key@0x10, NULL)    ; TAIL JMP 0x1720DE0
```

**The single most important control-flow fact on this page: the OFF edge of a
tab toggle does nothing at all.** Only the ON edge switches panels, and it
enters `ShowScreen`, not `OpenGroup`. `<Awake>b__2()` @`0x17240D0` is the second
closure (reads `this.value@0x18`); `<Awake>b__26_0()` @`0x1721900` is a separate
non-capturing lambda on the screen itself.

`<>c__DisplayClass26_0` is type index **15731**, and the name is AMBIGUOUS —
23 types in this build share it. Address it by index (§5 T11).

### 2.3 A tab press, end to end, in exact order

Composed from four MEASURED disassemblies. Pressing GRAPHICS while GAME is on:

```
AnimatedToggle::OnPointerClick        0x16AD5D0
  -> Toggle::InternalToggle           0x55BA7D0   (SHARED x2 with OnSubmit)
    -> Toggle::Set(value=true, sendCallback=true)      0x55BA450
```

`Toggle::Set(bool value, bool sendCallback)` @`0x55BA450`, UNIQUE. MEASURED
`R disasm 0x55ba450 --to 0x55ba690`, in program order:

1. `if (m_IsOn@0x120 == value) return;` — **an early, total return: no callback,
   no effect, no animation** (`cmp byte ptr [rbx+0x120], dil ; je end`).
2. `m_IsOn@0x120 = value`
3. `grp = m_Group@0x110`; if `grp != null` (both CLR-null and Unity
   `m_CachedPtr@0x10` checked) **and** `grp.isActiveAndEnabled` (icall cached at
   `.data 0x70D44C8`) **and** `this.IsActive()` (virtual `klass+0x1C8`):
   a. `if (!m_IsOn && !grp.AnyTogglesOn() && !grp.m_AllowSwitchOff@0x20)` →
      `m_IsOn = 1` (the last toggle cannot be switched off)
   b. `grp.NotifyToggleOn(this, sendCallback)` — **`0x55BABC0`**
4. `PlayEffect(instant: toggleTransition@0x100 == 0)` — `0x55BA690`
5. `if (sendCallback) { UISystemProfilerApi::AddMarker(...) 0x5585080;
   onValueChanged@0x118.Invoke(m_IsOn) 0x37F5180; }`

`ToggleGroup::NotifyToggleOn(toggle, sendCallback)` @`0x55BABC0`, MEASURED:

1. `ValidateToggleIsInGroup(toggle)` — `0x55BAA00`. **Throws** if `toggle` is
   null or not in `m_Toggles` (§5 T3).
2. `for (i = 0; i < m_Toggles._size@0x18; i++)`:
   `t = m_Toggles._items@0x10[i]`; `if (t == toggle) continue;`
   `t.Set(false, sendCallback)` — `r8b = 1` on the `sendCallback == true` path
   and `r8d = 0` on the other, i.e. the flag **propagates verbatim**.

**Therefore the ordering, MEASURED, for a real press of B while A is on:**

```
B.m_IsOn = true
  NotifyToggleOn(B):
     A.Set(false, true)
        A.m_IsOn = false
        A.PlayEffect(...)
        A.onValueChanged(false)   -> <Awake>b__1(false) -> RETURNS, does nothing
     (every other toggle in m_Toggles order, likewise)
  B.PlayEffect(...)
  B.onValueChanged(true)          -> <Awake>b__1(true) -> ShowScreen(B.key)
```

**Every nested `Set(false)` and every OFF callback completes BEFORE the ON
callback runs.** Nothing in the OFF path deactivates a panel. Panel
deactivation happens once, inside `ShowScreen`, after all the OFF edges.

### 2.4 `SettingsScreen::ShowScreen(ESettingsGroup group)` @ `0x1720DE0` (UNIQUE)

MEASURED `R disasm 0x1720de0 --to 0x1720fd0`:

```
old = this._currentTab@0x118
if (old != null && old.m_CachedPtr@0x10 != 0)
      old.set_IsSelected(false)                  ; call 0x171BCA0, rdx=0, r8=NULL
ctrl = this.ScreenController@0x90
if (ctrl == null) throw
ctrl[+0x60] = group                              ; remember the group
this.EnsureTabInitialized(group)                 ; call 0x171FF10
this._currentTab@0x118 = _tabs[group].Tab        ; static dict, sret at [rsp+0x20], [rax+0]
      (with a GC write barrier: shr/bts/lock cmpxchg against the card table at .data 0x711F400)
this._currentTab.set_IsSelected(true)            ; TAIL JMP 0x171BCA0, rdx=1, r8=NULL
```

**Order: OLD OFF → build → NEW ON.** The final `set_IsSelected(true)` is a tail
jump, so a postfix detour on `ShowScreen` has no return site.

### 2.5 `SettingsTab::set_IsSelected(bool value)` @ `0x171BCA0` (UNIQUE) — the panel switch itself

MEASURED `R disasm 0x171bca0 --to 0x171bda0`:

```
go = MonoBehaviour::get_gameObject(this)      ; icall, cached at .data 0x70D44E8,
                                              ; resolved from the .rdata name at 0x58F9A28
if (go == null) throw
GameObject::SetActive(go, value)              ; icall, cached at .data 0x70D4598
if (value) {
    if (!<IsInitialized>@0x90) {
        <IsInitialized>@0x90 = true
        virtual klass+0x2C8   OnFirstSelect()
    }
    virtual klass+0x2D8       OnSelect()
}
```

**A "panel" is literally the tab component's own GameObject, switched with
`GameObject.SetActive`.** LIVE confirms: `SettingsScreen` children `[3]`..`[7]`
are `Game Settings`, `Graphics Settings`, `PostFX Settings`, `Sound Settings`,
`Control Settings`.

`SettingsTab::OnTabSelected()` @`0x171BDA0` is the same tail without the
`SetActive`: first-select gate, then `OnSelect()`. I found **no caller** for it
— INFERRED from its absence in every body I read; I did not run
`R callers 0x171bda0`.

### 2.6 `SettingsScreen::EnsureTabInitialized(ESettingsGroup group)` @ `0x171FF10` (UNIQUE)

MEASURED `R disasm 0x171ff10 --to 0x1720380`:

```
if (_initializedTabs@0x138.Contains(group)) return;       ; HashSet`1::Contains 0x2F85200
switch (group) {
  case 0 Screen:   ctrl = ScreenController@0x90;  g = ctrl[+0x50]
                   tab = _graphicsSettingsScreen@0xf8
                   b   = virtual ctrl.klass+0x468 ()      ; a bool getter
                   tab[+0xd8]  = g[+0x28]                 ; _tempSettings = GraphicsSettingsGroup
                   tab[+0x140] = b                        ; _isInRaidBlockersActive
                   tab[+0x141] = 0                        ; _textureMessageShown
                   tab[+0xe0]  = <singleton>[+0x28][+0x10]; _originalSettings
                   ;; NOTE: NO Show() call. Graphics is initialised by FIELD WRITES only.
  case 1 Game:     _gameSettingsScreen.Show(g[+0x10], _session@0x120, b, null)   ; 0x17037A0
  case 2 Sound:    _soundSettingsScreen.Show(g[+0x18], _profileInfo@0x128)       ; 0x171C100
  case 3 Control:  _controlsSettingsTabScreen.<virtual klass+0x2E8>(
                       g[+0x30], g[+0x18], ctrl[+0x58], b,
                       _profileInfo@0x128, _customization@0x130)                 ; Show, 6 args
  case 4 PostFX:   _postFXSettingsScreen.Show(g[+0x20], ctrl)                    ; 0x17193C0
  default:         throw new ArgumentOutOfRangeException(...)                    ; 0x4491DD0
}
_initializedTabs.AddIfNotPresent(group)                   ; 0x2F89E80
```

Two facts fall straight out. First, **an `ESettingsGroup` value the switch does
not know throws a managed exception** — §5 T1. Second, **Graphics is the odd
one: no `Show(...)` call at all; its rows are built entirely inside
`OnFirstSelect` @`0x170A8B0` → `CreateBlockers` `0x170AA50` → `CreateControls`
@`0x170BBA0`.** PostFX, by contrast, is handed its settings group *and* the
controller here, and `PostFXSettingsTab::OnFirstSelect` @`0x1719490` is a small
body that defers to `ShowContent(screenController)` @`0x17194A0`. That is the
whole structural difference between the two tabs.

### 2.7 `SettingsScreen::OpenGroup(ESettingsGroup desiredGroup)` @ `0x1720C80` (UNIQUE)

MEASURED `R disasm 0x1720c80 --to 0x1720de0`. MEASURED `R callers 0x1720c80` —
two sites, both tail `jmp`: `Show(controller)` and
`<DisplayRevertMessage>b__41_0` `0x1721950`.

```
i = _tabs.FindEntry(desiredGroup)           ; Dictionary`2::FindEntry 0x3FA7B90
if (i < 0) desiredGroup = 1                 ; cmovs edi,1 -- FALLS BACK TO Game
spawner = _tabs[desiredGroup].Toggle        ; [rax+8]
tog = spawner.get_SpawnableToggle().Toggle@0xd0        ; 0x16BC670 then +0xD0
if (tog == null) throw
Toggle::Set(tog, value=true, sendCallback=true)        ; 0x55BA450, r9 = NULL MethodInfo
if (tog.m_Transition@0x50 == 3)                        ; Transition.Animation
      AnimatedToggle::TriggerAnimation(tog, tog._onTrigger@0x128)    ; 0x16AD260
ShowScreen(this, desiredGroup)              ; TAIL JMP 0x1720DE0
```

Note `sendCallback = true`: `Set` fires `onValueChanged(true)`, which itself
tail-jumps into `ShowScreen`. So on the `OpenGroup` path **`ShowScreen` runs
twice for one group** — once re-entrantly from the callback and once from the
tail jump. It is idempotent because the second pass finds `_currentTab` already
equal to that tab and just re-runs `set_IsSelected(false)` then `(true)` on it.
INFERRED from two MEASURED bodies; not observed live.

`OpenGroup` is also the **only** failure path in the screen that does not throw:
an unknown group silently becomes `Game (1)`.

### 2.8 Closing

`SettingsScreen::CloseAll()` @`0x17207A0` (UNIQUE), MEASURED
`R disasm 0x17207a0 --to 0x17209b0`. Five `_initializedTabs.Contains(k)` tests,
in this exact order, each followed by `tab.<virtual klass+0x288>()` = `Close()`:

| Order | `k` | Tab field |
|---|---|---|
| 1 | 1 (Game) | `_gameSettingsScreen@0xf0` |
| 2 | 0 (Screen/Graphics) | `_graphicsSettingsScreen@0xf8` |
| 3 | 4 (PostFX) | `_postFXSettingsScreen@0x100` |
| 4 | 2 (Sound) | `_soundSettingsScreen@0x108` |
| 5 | 3 (Control) | `_controlsSettingsTabScreen@0x110` |

then `_initializedTabs.Clear()` and `_currentTab@0x118 = null` (with write
barrier). **`CloseAll` never calls `set_IsSelected(false)`** — the panel
GameObjects stay active; only the screen's own hide takes them off screen.

`SettingsTab::Close()` @`0x171BDF0`: `CleanupCreatedControls()` →
`<IsInitialized>@0x90 = false` → `CompositeDisposable::Dispose` `0x1D252C0`.

`SettingsTab::CleanupCreatedControls()` @`0x171BE50`: enumerates
`_createdControls@0x88`, and for each calls
`UnityEngine.Object::Destroy(control.gameObject)` (`0x52AE0A0`), then
`Array::Clear` (`0x459A0E0`). **`Destroy` is deferred to end of frame**
(KNOWN-FROM-SOURCE), so a same-frame child sweep still sees every row it just
"destroyed".

Other RVAs, MEASURED `R typemethods`: `SettingsScreen::Close()` `0x1720B10`
(PUBLIC VIRTUAL, UNIQUE); `SaveButtonAction()` `0x1721450`;
`DisplayRevertMessage()` `0x1721080`; `DisplayNoSaveMessage(Action,Action)`
`0x1721310`; `SetSaveButtonActive(bool)` `0x1720FD0`; `ShowCreditsScreen()`
`0x1721610`; `SettingsHandler(bool)` `0x1720380`; `MemberCategoryHandler`
`0x1720580`; `OnLoadingProgressHandler(bool)` `0x1720790`
(**TAILJUMP — no return site**); `.ctor` `0x1721680`; `.cctor` `0x1721820`.
`SettingsScreenController::SaveSettings` `0x1721E20` and `.ctor` `0x1721A40`
come from `docs/SETTINGS.md` and were **not re-measured here**.

### 2.9 How a tab builds rows

MEASURED `R genericmethods "EFT.UI.Settings.SettingsTab::CreateControl"`:
exactly **one** instantiation, `class<> method<object>`, body RVA **`0x2B86E20`**
— a *shared generic*. MEASURED `R disasm 0x2b86e20`: the first thing the body
does is `cmp qword ptr [r9+0x38], 0` and, if zero, call the runtime metadata
initialiser. `r9` is the trailing `MethodInfo*`
(`rcx=this, rdx=prefab, r8=parent, r9=MethodInfo*`). **A NULL `MethodInfo*` here
is an immediate null dereference.** It then calls the Object.Instantiate helper
at `0x5D9E20`.

The per-tab row builders follow a fixed shape — INFERRED from the uniform
`_currentControlIndex` field on four of the five tabs plus the MEASURED
`SettingControl` API: `CreateControl<T>(template, parent)` →
`SetName(string)` `0x16FA9D0` → `SetText(localizationKey)` `0x16FA890` →
`BindTo(...)` → `SetSiblingIndex(_currentControlIndex++)` `0x16FA910` →
`SetTooltip(...)` `0x16FAC00`.

`SettingControl::SetText(string localizationKey)` @`0x16FA890`, MEASURED:
writes into `this.Text@0x80` (`LocalizedText`), then calls
**`LocalizedText::UpdateLocale()` @`0x140FDB0`**, and returns `this`. It does
**not** call `SetLabelText`. `SetLabelText` @`0x140FE70` is the lower-level
"push this literal into every label" entry point.

### 2.10 The subtab pattern, as the game itself implements it

`ControlSettingsTab` is the only stock tab with subtabs, and it is the model.

MEASURED `R disasm 0x16fed50` — `ControlSettingsTab::HandleGesturesToggle(bool isOn)`:

```
GameObject::SetActive(this._gesturesPanel@0xf0, isOn)   ; the icall at .data 0x70D4598
if (isOn) {
    <async state machine>   ; AsyncTaskMethodBuilder::Start 0x2960E30,
                            ; then Task::ContinueWith 0x46142A0
}
```

**It only touches its OWN panel.** The other subtab's panel is turned off by the
other subtab's own handler, fired by `ToggleGroup.NotifyToggleOn`. There is no
central "hide everything then show one" step anywhere in the subtab path.

MEASURED `R disasm 0x16fd4f0 --to 0x16fd970` — `ControlSettingsTab::Show` stores
its six arguments into fields, then drives the strip with
``UISpawner`1::get_SpawnedObject`` `0x37EA0C0` → `Toggle::Set` `0x55BA450`
(three call sites), `get_SpawnableToggle()` `0x16BC670`,
`AnimatedToggle::TriggerAnimation` `0x16AD260`, and
`Selectable::set_interactable` `0x55AFB40`. **There is no `AddListener` call
anywhere in it.** Neither is there one for a `ToggleEvent` in
`SettingsScreen::Awake`, which only calls the non-generic
`UnityEvent::AddListener` `0x52C3260` (the buttons).

**INFERRED, with the evidence stated:** the subtab `onValueChanged → handler`
edge is a **serialized persistent UnityEvent call baked into the prefab**, not
constructed at runtime. Evidence: `HandleGesturesToggle` is `private`, nothing
in `Show` or `Awake` subscribes it, and the rel32 callgraph shows no caller.
This is **not proven** — a rel32 callgraph cannot see a delegate dispatched
through `UnityEvent`.

`UIAnimatedToggleSpawner::SpawnObject()` @`0x16BC7F0`, MEASURED:

```
obj = base UISpawner`1::SpawnObject()               ; generic body 0x37EA210
tog = this.get_SpawnableToggle().Toggle@0xd0
Toggle::SetToggleGroup(tog, this._toggleGroup@0xb0, setMemberValue)   ; 0x55BA150
Toggle::PlayEffect(tog, ...)                                          ; 0x55BA690
Selectable::set_interactable(tog, !this._unavailable@0xb8)            ; 0x55AFB40
```

So **`SetToggleGroup` is the game's own way to join a group.** MEASURED
`R disasm 0x55ba150`: it does the whole job — `UnregisterToggle` from the old
group `0x55BADD0`, store `m_Group@0x110`, `RegisterToggle` into the new
`0x55BAE50`, and if the toggle is on, `NotifyToggleOn` `0x55BABC0`.
`Toggle::OnEnable` @`0x55B9F50` calls `SetToggleGroup(this, m_Group@0x110)`
unconditionally — **so a cloned toggle whose serialized `m_Group` already points
at the stock group registers itself the moment its GameObject is enabled.**

---


### 2.10a LIVE ANSWER, MEASURED 2026-09-02 15:06 (coordinator, live inspector)

On the STOCK `Toggles/GesturesToggle/AnimatedToggle` (component 0x23e5be7fe70,
Game tab up, Controls tab never shown this session):

* `onValueChanged@0x118` -> `UnityEventBase.m_PersistentCalls@0x18` ->
  `PersistentCallGroup.m_Calls@0x10` -> `List._size@0x18` = **0**.
* `UnityEventBase.m_Calls@0x10` -> `InvokableCallList.m_RuntimeCalls@0x18` ->
  `List._size@0x18` = **0**.
* The CLONED strip's GesturesToggle reads the same: 0 persistent, 0 runtime.

So the subtab `onValueChanged -> HandleGesturesToggle` edge is **NOT
prefab-serialized** (§2.10's inference is refuted). With zero calls of either
kind before the Controls tab has been shown, the wiring must be made at
runtime by `ControlSettingsTab::Show` or later -- most plausibly through the
SHARED generic ``UnityEvent`1<bool>::AddListener``, which a rel32 callgraph
cannot attribute (INFERRED). Consequence for §6.2: a cloned strip carries NO
handler at all, so the clone's toggles are inert until we wire our own
drain -- and there is nothing stale on them to remove.

`SettingsScreen+0x90` is a `SettingsScreenController` (Assembly-CSharp):
read live, klass name at `klass+0x10` = "SettingsScreenController". §8's
`ScreenController@0x90` question is settled.

## 3. The Unity side actually present in this build

Every RVA MEASURED `R typemethods`; every sharedness MEASURED `R shared`.

### `UnityEngine.UI.Toggle`

| Member | RVA | sharedness |
|---|---|---|
| `Set(bool,bool)` | `0x55BA450` | **UNIQUE** |
| `set_isOn(bool)` | `0x55BA430` | UNIQUE — an ~11-byte thunk into `Set` |
| `SetIsOnWithoutNotify(bool)` | `0x55BA440` | UNIQUE — `xor r9d,r9d; xor r8d,r8d; jmp 0x55BA450` (MEASURED bytes) → **sendCallback = FALSE** |
| `get_isOn()` | `0x66E7C0` | SHARED x10 |
| `set_group(ToggleGroup)` | `0x55B9D30` | UNIQUE |
| `get_group()` | `0x66E740` | SHARED x28 |
| `SetToggleGroup(ToggleGroup,bool)` | `0x55BA150` | UNIQUE |
| `PlayEffect(bool)` | `0x55BA690` | UNIQUE |
| `InternalToggle()` / `OnSubmit(BaseEventData)` | `0x55BA7D0` | SHARED x2 (with each other) |
| `OnPointerClick(PointerEventData)` | `0x55BA830` | UNIQUE |
| `OnEnable` / `OnDisable` / `OnDestroy` | `0x55B9F50` / `0x55B9F90` / `0x55B9E60` | UNIQUE |
| `Start()` | `0x55BA7C0` | UNIQUE |
| `Rebuild` / `LayoutComplete` / `GraphicUpdateComplete` | `0x628110` | **STUB, SHARED x9614** |

`set_isOn` and `SetIsOnWithoutNotify` are both ~11-byte tail-jump thunks:
stealing a 16-byte prologue from either **writes past the end of the function**.
`Set` is the only correct hook point, and its `sendCallback` argument
distinguishes a real press (`true`) from a silent write (`false`).

### `UnityEngine.UI.Selectable`

`set_interactable(bool)` `0x55AFB40`; `OnEnable()` `0x55B0510`.
Fields (through `AnimatedToggle`): `m_Transition@0x50`, `m_Interactable@0xd8`,
`m_TargetGraphic@0xe0`, `m_CanvasGroupCache@0xf8`, `m_CurrentIndex@0xec`,
`<isPointerInside>@0xf0`, `<isPointerDown>@0xf1`, `<hasSelection>@0xf2`;
statics `s_Selectables` slot `0x0`, `s_SelectableCount` slot `0x8`.

### `UnityEngine.CanvasGroup`

`get_alpha` `0x5580A20`, `set_alpha` `0x5580A70`, `get_interactable`
`0x5580AD0`, `set_interactable` `0x5580B20`, `set_blocksRaycasts` `0x5580BD0`,
`get_ignoreParentGroups` `0x5580C30`, `set_ignoreParentGroups` `0x5580C80` —
UNIQUE. `get_blocksRaycasts` `0x5580B80` is **SHARED x2 with
`IsRaycastLocationValid`** — do not detour it.

**KNOWN-FROM-SOURCE** (uGUI): `interactable = false` makes every `Selectable`
under the group report `IsInteractable() == false` (via `m_CanvasGroupCache`,
refreshed on `OnCanvasGroupChanged`); `blocksRaycasts = false` makes
`GraphicRaycaster` skip the whole subtree, so controls stay *interactable* by
state but are unreachable by pointer; `alpha = 0` changes nothing about
raycasts. All three are independent. A `CanvasGroup` whose `Behaviour.enabled`
is false is ignored entirely — as if it were not there.

### `UnityEngine.UI.LayoutGroup` / `HorizontalOrVerticalLayoutGroup` / `VerticalLayoutGroup`

`LayoutGroup.ctor` `0x5598C10` (UNIQUE); `set_padding` `0x5598570`;
`set_childAlignment` `0x5598640`; `get_rectTransform` `0x5598690`;
`CalculateLayoutInputHorizontal` `0x55987D0`;
`SetChildAlongAxis(RectTransform,int,float)` `0x5599340`, the 4-arg overload
`0x5599780`, `…WithScale` `0x5599450`; `SetLayoutInputForAxis` `0x55992E0`;
`GetTotalMinSize` `0x5598FB0`; `GetTotalPreferredSize` `0x5598FC0`;
`GetTotalFlexibleSize` `0x5598FD0`; `GetStartOffset` `0x5598FE0`;
`GetAlignmentOnAxis` `0x5599290`; `OnDisable` `0x5598F50`.
`get_padding` `0x67BF20` is **SHARED x479**; `get_rectChildren` `0x690CB0`
SHARED x147; `get_childAlignment` `0x6CD400` SHARED x89;
`get_layoutPriority` `0x66C100` is the **`xor eax,eax; ret` stub, SHARED x540**.
`LayoutGroup::SetLayoutHorizontal` / `SetLayoutVertical` /
`CalculateLayoutInputVertical` are **NO-CODE** (abstract).

`HorizontalOrVerticalLayoutGroup`: `set_spacing` `0x5596D10`,
`set_childForceExpandWidth` `0x5596DC0`, `set_childForceExpandHeight`
`0x5596E10`, `set_childControlWidth` `0x5596E60`, `set_childControlHeight`
`0x5596EB0`, `set_childScaleWidth` `0x5596F00`, `set_childScaleHeight`
`0x5596F50`, `set_reverseArrangement` `0x5596FA0`, `CalcAlongAxis` `0x5596FF0`,
`SetChildrenAlongAxis` `0x55974A0`, `GetChildSizes` `0x5597FF0`.
`VerticalLayoutGroup`: `CalculateLayoutInputHorizontal` `0x559E2D0`,
`…Vertical` `0x559E300`, `SetLayoutHorizontal` `0x559E310`, `SetLayoutVertical`
`0x559E320`; its `.ctor` `0x16EDFB0` is **SHARED x4**.

### `UnityEngine.UI.ContentSizeFitter`

`set_horizontalFit` `0x5595960`, `set_verticalFit` `0x55959C0`,
`get_rectTransform` `0x5595A20`, `HandleSelfFittingAlongAxis` `0x5595BD0`,
`SetLayoutHorizontal` `0x5595C70`, `SetLayoutVertical` `0x5595CE0`,
`SetDirty` `0x5595D50`, `OnDisable` `0x5595B70` — UNIQUE.
`OnEnable` and `OnRectTransformDimensionsChange` share `0x5595B60`;
`.ctor` `0x629540` is SHARED x676.

### `UnityEngine.UI.LayoutRebuilder`

`ForceRebuildLayoutImmediate(RectTransform)` **`0x559AA70`**;
`MarkLayoutForRebuild(RectTransform)` **`0x559B970`**;
`MarkLayoutRootForRebuild` `0x559C4A0`; `Rebuild(CanvasUpdate)` `0x559ABC0`;
`ValidController` `0x559C0F0`; `PerformLayoutControl` `0x559B050`;
`PerformLayoutCalculation` `0x559B5C0`; `Initialize` `0x559A320`;
`Clear` `0x559A3A0`; `StripDisabledBehavioursFromList` `0x559A900`;
`ReapplyDrivenProperties` `0x559A7E0`; `IsDestroyed` `0x559A830`;
`LayoutComplete` `0x559C720`; `.cctor` `0x559A400` — all UNIQUE.
`.ctor` and `GraphicUpdateComplete` are `0x628110` (**STUB, SHARED x9614**);
`get_transform` `0x6898E0` SHARED x676; `GetHashCode` `0x6ECBA0` SHARED x197.

**KNOWN-FROM-SOURCE, and this is the part that matters for a strip:**
`SetActive` on a child of a `LayoutGroup` does **not** re-lay-out this frame.
The child's `OnEnable`/`OnDisable` calls `LayoutRebuilder.MarkLayoutForRebuild`,
which enqueues the layout root on `CanvasUpdateRegistry`; the rebuild runs in
`Canvas.willRenderCanvases`, i.e. **at the end of the current frame, before
render**. Any `sizeDelta` or `anchoredPosition` read in the same `Update` as the
`SetActive` returns the *old* geometry. `ForceRebuildLayoutImmediate` is the
synchronous escape hatch, and it is O(subtree).

**The LIVE dump is a worked example of what this costs.** `Graphics Settings`
(`$c4`): `anchoredPosition (0, 60)`, `sizeDelta (1000, -225)`,
`anchorMin (0.5, 0)` / `anchorMax (0.5, 1)`, `pivot (0.5, 0)` — bottom-anchored
and vertically stretched, so its height is `parentHeight - 225`.
`PostFX Settings` (`$c5`): `anchoredPosition (0, -165)`, `sizeDelta (930, 785)`,
`anchorMin = anchorMax = (0.5, 1)`, `pivot (0.5, 1)` — top-anchored, fixed
height. Both resolve to `rect.h = 785` **only because the parent
`SettingsScreen` rect happens to be 1010 tall** (`1010 - 225 = 785`). They agree
by arithmetic coincidence, not by design: change the window height and Graphics
tracks it while PostFX does not. **Anything that positions itself by copying one
panel's rect onto the other is measuring a coincidence.**

### `TMPro.TMP_Text`

`set_text` **`0x51BC1E0`** — MEASURED `R shared 0x51BC1E0` = **UNIQUE**.
`ForceMeshUpdate` resolves to **`0x628110`**, MEASURED `R shared 0x628110` =
**SHARED, owners = 9614**. That address is `C2 00 00` (`ret 0`) — this build's
universal empty-body stub, not TMP code. Calling it does nothing at all.

---

## 4. `LocalizedText` vs raw text — what actually sticks

MEASURED chain. `LocalizedText::OnEnable` @`0x140F910` subscribes to the locale
bindable and calls `UpdateLocale` @`0x140FDB0`, which resolves
`localizationKey@0x70` (plus `_formatTemplate@0x88` / `_formatValues@0x90`) and
pushes the result through `SetLabelText` @`0x140FE70` into every entry of
`_labels@0x78`.

Consequence, MEASURED-BY-STRUCTURE: a raw store into a `TextMeshProUGUI`'s
`m_text`, or even a call to `TMP_Text::set_text` `0x51BC1E0`, is overwritten the
next time `UpdateLocale` runs — which is on enable, on locale change, and on
every `SettingControl::SetText`. The stable options, best first:

1. `LocalizedText::set_LocalizationKey(string)` `0x140F8B0`, then
   `UpdateLocale()` `0x140FDB0` — make the localiser agree with you.
2. `LocalizedText::SetLabelText(string)` `0x140FE70` — pushes a literal now, and
   **must be re-applied** after anything that re-runs `UpdateLocale`.
3. `TMP_Text::set_text` `0x51BC1E0` — only correct on a TMP with **no**
   `LocalizedText` above it. In a keybind row that is `_keyName@0x80` and
   `_key2Name@0x90`; it is **not** `_commandName@0x70`, which is a
   `LocalizedText`.

---

## 5. Traps

**T1 — `ESettingsGroup` has exactly five values, and an unknown one THROWS.**
MEASURED (`R fields ESettingsGroup`; `R disasm 0x171ff10` default case →
`ArgumentOutOfRangeException::.ctor` `0x4491DD0`). A sixth tab cannot reuse the
stock `ShowScreen`/`EnsureTabInitialized` path with an invented enum value; the
`_tabs` lookup in `ShowScreen` would also miss. `OpenGroup` is the one caller
that degrades instead of throwing — it `cmovs`-falls back to `Game (1)`.
**A MODS tab must be driven by our own handler, not by extending the enum.**

**T2 — `Toggle::Set` returns immediately when `m_IsOn` already equals `value`.**
MEASURED (`R disasm 0x55ba450`, first branch). `Set(t, true, true)` on a toggle
that is already on produces **no callback, no animation, no panel switch** — and
looks exactly like success. Read `m_IsOn@0x120` first, or drive the panel
directly.

**T3 — `ToggleGroup::NotifyToggleOn` calls `ValidateToggleIsInGroup`, which
throws.** MEASURED (`R disasm 0x55babc0` +0x6d; `R disasm 0x55baa00` ends in the
`0x5D21C0` / `0x5D2340` format-and-throw pair). A cloned toggle whose
`m_Group@0x110` points at the stock group but which is **not** in
`m_Toggles@0x28` throws an IL2CPP C++ exception on the first `Set(true, …)`.
That exception unwinds *through* a native frame without tripping
`aowl_p_p_seh` — the same failure class `nativetabs.nim` already records for
`CleanupCreatedControls`. Join a group only via `Toggle::SetToggleGroup`
`0x55BA150`, or by enabling a toggle whose serialized `m_Group` is already
correct (`Toggle::OnEnable` `0x55B9F50` registers it).

**T4 — the universal stub `0x628110`, SHARED x9614.** MEASURED
`R shared 0x628110`. Methods in *this* map that land on it:
`SettingsTab::OnFirstSelect`, `SettingsTab::OnSelect`,
`SettingsTab::TranslateAxes`, `SettingControl::SetValueText`,
`GraphicsSettingsTab::ShowMipStreaming`, `Toggle::Rebuild`,
`Toggle::LayoutComplete`, `Toggle::GraphicUpdateComplete`,
`LayoutRebuilder::.ctor`, `LayoutRebuilder::GraphicUpdateComplete`,
`<>c__DisplayClass26_0::.ctor`, and `TMP_Text::ForceMeshUpdate`. A resolve that
lands here has told you the method **has no body**, not where it lives.
The second stub is `0x66C100` (`xor eax,eax; ret`, **SHARED x540**):
`SettingsTab::TranslateCommand`, `SettingControl::TranslateCommand`,
`SettingsTab::ShouldLockCursor`, `LayoutGroup::get_layoutPriority`.

**T5 — `SettingsTab::CreateControl<T>` is a SHARED GENERIC.** MEASURED
`R genericmethods`: one body, `0x2B86E20`, `method<object>`. MEASURED
`R disasm 0x2b86e20`: it dereferences `[MethodInfo* + 0x38]` before anything
else. **A NULL `MethodInfo*` is an immediate null dereference.** This is the
documented exception to "NULL `MethodInfo*` is fine".

**T6 — every shared RVA in this set.** Do not detour any of these by name;
calling them is fine.

| RVA | owners | members here that land on it |
|---|---|---|
| `0x628110` | 9614 | see T4 |
| `0x66C100` | 540 | see T4 |
| `0x629540` | 676 | `ContentSizeFitter::.ctor`, `CommandAxisPair::.ctor` |
| `0x6898E0` | 676 | `LayoutRebuilder::get_transform` |
| `0x67BF20` | 479 | `LayoutGroup::get_padding` |
| `0x906050` | 202 | `SettingsScreen::ShouldLockCursor` |
| `0x6ECBA0` | 197 | `LayoutRebuilder::GetHashCode` |
| `0x690CB0` | 147 | `LayoutGroup::get_rectChildren` |
| `0x6D7FD0` | 141 | `ContentSizeFitter::get_horizontalFit` |
| `0x65ED10` | 107 | `LocalizedText::get_LocalizationKey` |
| `0x690F30` | 92 | `SettingControl::get_Blocker` |
| `0x6CD400` | 89 | `LayoutGroup::get_childAlignment` |
| `0x66E700` | 78 | `CommandAxisPair::get_AxisGroup` |
| `0x66E6F0` | 70 | `LocalizedText::get_FormattedText` |
| `0x6AC8B0` | 66 | `ToggleGroup::get_allowSwitchOff` |
| `0x66E6C0` | 60 | `get_TargetComponent` on **all four** SettingControl subclasses |
| `0x679EA0` | 49 | `ContentSizeFitter::get_verticalFit` |
| `0x6AC8C0` | 43 | `ToggleGroup::set_allowSwitchOff` |
| `0x691060` | 34 | `LocalizedText::set_FormattedText` |
| `0x690ED0` | 34 | `CommandAxisPair::set_AxisGroup` |
| `0x6815A0` | 33 | `HorizontalOrVerticalLayoutGroup::get_childScaleWidth` |
| `0x66E740` | 28 | `Toggle::get_group` |
| `0x6915E0` | 28 | `CommandKeyPair::get_KeyGroup` |
| **`0xCFD7D0`** | **26** | **`.ctor` of `SettingsTab`, `SettingControl`, `SettingToggle`, `SettingFloatSlider`, `SettingDropDown`, `SettingSelectSlider`, `GraphicsSettingsTab`, `PostFXSettingsTab`, `GameSettingsTab`** — and it is also a TAILJUMP |
| `0x663770` | 26 | `SettingsGroupObjects::.ctor` |
| `0x6917F0` / `0x691780` | 21 | `AnimatedToggle::get_OffTrigger` / `get_OnTrigger` |
| `0x691790` / `0x691800` | 16 | `AnimatedToggle::set_OnTrigger` / `set_OffTrigger` |
| `0x6915F0` | 16 | `CommandKeyPair::set_KeyGroup` |
| `0x13AF770` | 14 | `SettingsScreen::TranslateAxes` |
| `0xCAD190` | 13 | `SettingsTab::get_IsInitialized` |
| `0xCD3EA0` | 11 | `LocalizedText::OnDestroy` |
| `0x66E7C0` | 10 | `Toggle::get_isOn` **and** `AnimatedToggle::get_IsToggled` |
| `0xCF6C70` | 9 | `SettingsTab::set_IsInitialized` |
| `0x16EDFB0` | 4 | `VerticalLayoutGroup::.ctor`, `HorizontalOrVerticalLayoutGroup::.ctor` |
| `0x14F3560` | 3 | `SettingsTab::ResetInitialization` |
| `0x55BA7D0` | 2 | `Toggle::InternalToggle` **and** `Toggle::OnSubmit` |
| `0x5580B80` | 2 | `CanvasGroup::get_blocksRaycasts` **and** `IsRaycastLocationValid` |
| `0x55BA9F0` | 2 | `ToggleGroup::Start` **and** `OnEnable` |
| `0x5595B60` | 2 | `ContentSizeFitter::OnEnable` **and** `OnRectTransformDimensionsChange` |

**T7 — `SettingsTab::_rectTransform@0x78` reads null.** Carried from the
existing repo record; **not re-measured here** (it is a live fact, not an
offline one). Reach containers by walking from a verified live object.

**T8 — TAILJUMP bodies have no return site**, so a postfix detour is
meaningless on `SettingsScreen::OnLoadingProgressHandler` `0x1720790`,
`SettingsTab::.ctor` `0xCFD7D0`, and the tail-`jmp` exits of
`SettingsScreen::Show(controller)`, `OpenGroup`, `ShowScreen` and
`SettingsTab::OnTabSelected`. MEASURED `R typemethods` thunk classification and
the disassemblies above.

**T9 — managed exceptions do not trip `aowl_p_p_seh`.** The throwing paths in
this map: `EnsureTabInitialized` default case; `ValidateToggleIsInGroup`;
`set_IsSelected` when `gameObject` is null; and every null hop in
`ShowScreen` / `OpenGroup` / `CloseAll` (`call 0x5D2530`, the null-reference
throw helper — it appears **11 times in `ShowScreen` alone**). MEASURED from
the disassemblies. `CleanupCreatedControls` and `Behaviour::set_enabled` on
clones are already on record as throwers.

**T10 — token-gated exports.** No path in this map needs one. Everything above
is a direct call at a byte-verified static RVA plus raw field reads, which
bypasses the export ABI entirely. The only export a row builder wants is
`il2cpp_string_new`, which is ungated. **Do not** reach for
`il2cpp_object_get_class` to identify a tab: it is `mov rax,[rcx]; ret`, so a
bad pointer yields a plausible number silently.

**T11 — `<>c__DisplayClass26_0` is an ambiguous type name.** MEASURED: 23 types
share it (indices 750, 4824, 5711, 6441, 7731, 8047, 8308, 8623, 9387, 11744,
12312, 14113, 14451, 15041, 15097, 15690, **15731**, 16565, 16862, 16922,
19237, 27523, 29736). The resolver refuses to pick; address it as `15731`.

**T12 — LIVE: our cloned strip still carries the donor's own children.**
`Toggles(Clone)` (`$c15`, `0x1fd22e90220`) has `childCount = 4`:
`[0] ControlToggle`, `[1] GesturesToggle`, `[2] ControlToggle(Clone)`,
`[3] ControlToggle(Clone)`. The first two are the **donor's** toggles, cloned
along with the parent. Its `sizeDelta` is `(-1418.66, 46)` with
`anchorMin (0,1)` / `anchorMax (1,1)` — a stretched-width rect whose resolved
width is `501.34`, i.e. it is sized by its parent, not by us. Two of its four
children are toggles we do not own and never reparented, and they are still in
whatever `ToggleGroup` their `m_Group` names. Predicate 7 in §6.5 fails today.

**T13 -- A SPAWNED TOGGLE POINTER IS NOT STABLE, AND THE SPAWNER SILENTLY
REPLACES IT.** MEASURED `R disasm 0x37ea0c0`
(``UISpawner`1::get_SpawnedObject``, generic body, 1 instantiation):

```
get_SpawnedObject(this):
    rdi = this._spawnedObject@0xa0
    if (rdi == null || rdi.m_CachedPtr@0x10 == 0) {        ; null OR Unity-DEAD
        virtual klass+0x268   SpawnObject()                ; <-- RESPAWNS
        virtual klass+0x278   SetHeaderText(this@0x78, this@0x80)
        if (this@0x90 >= 0f) virtual klass+0x288  SetMinWidth(this@0x90)
        virtual klass+0x298   SetEllipsis(this@0x94)
    }
    return this._spawnedObject@0xa0
```

So the getter is a **lazy factory, not an accessor**: the instant the toggle it
made is destroyed, the next read of the property builds a NEW one and rewrites
`_spawnedObject@0xa0`. Nothing announces this. A pointer captured from
`SpawnObject()` at build time therefore becomes an orphan -- still readable,
still reporting `m_IsOn = 0` forever, never again the object the player clicks.

Corroborating MEASURED facts:

* `R callers 0x16BC7F0` (`UIAnimatedToggleSpawner::SpawnObject`) reports **0
  direct callers** -- it is reached ONLY through the vtable slot `klass+0x268`
  from inside `get_SpawnedObject`. Nothing else in the build calls it.
* **There is no `OnEnable` anywhere in the spawner chain.** `R typemethods
  EFT.UI.UISpawner`1` declares 9 methods and `EFT.UI.UIAnimatedToggleSpawner`
  declares 9; neither list contains `OnEnable`, `Awake` or `Start`. The trigger
  is *"the old one is dead when someone asks"*, **not** *"the GameObject was
  enabled"*.
* `ToggleSilently` @`0x16BCBA0` and every stock driver reach the toggle through
  `get_SpawnedObject` on **every single call** (`R disasm 0x16bcba0`), which is
  why the game itself never suffers from this.

**Runtime offsets on `UIAnimatedToggleSpawner` for this instantiation**, BORROWED
from that body (the ``UISpawner`1`` fields are `GENERIC` and have no offline
row -- §1.6): `_headerCaption@0x78`, `_headerFontSize@0x80`, `_minWidth@0x90`
(float), `_useEllipsis@0x94` (bool), **`_spawnedObject@0xa0`**. `T` is
`AnimatedToggle`, cross-confirmed because `ToggleSilently` passes the getter's
return straight to `Toggle::Set` and then reads `m_Transition@0x50` and
`_onTrigger@0x128` off it.

**LIVE CONFIRMATION, host log 2026-09-02 15:42 boot, lines 930-1129.** The
subtab strip built at 2:49.5 and one press worked at 2:50.8 (VERDICT PASS).
The user then cycled the top-row tabs; from 2:52 the `Toggle::Set` drain
printed *new* first-time pointers for objects under our own strip
(`0x1d0277a2000` / `0x1d0277a22a0`, then `0x1cfcf79dd20` / `0x1cfcf79da80` at
3:15), every one classified `matched-as=other`. From 3:12 every verdict read
`P4 0 of 2 subtabs read m_IsOn=1` while `_currentTab` was correctly
`Graphics Settings`, and on screen neither subtab was selected and neither did
anything. That is this trap exactly: the cached pointers were orphans, so
presses did not match and `ToggleSilently` aimed at the dead objects.

**THE ONLY CORRECT SHAPE: never hold a spawned-toggle pointer.** Hold the
**spawner component** -- which is not replaced -- and resolve the toggle at the
moment you need it, either by calling a spawner method that does it for you
(`ToggleSilently`, `SetHeaderText`, `SetActive`) or by a guarded raw read of
`_spawnedObject@0xa0`. Prefer the raw read for *reading*: the property getter
can SPAWN, which is a managed allocation and a vtable storm on whatever path
asked, and a verdict must not be able to change what it is judging.

**T13a -- `_spawnedObject@0xa0` IS the `AnimatedToggle`. The `+0xd0` hop is
real but belongs to a DIFFERENT field.** This was contested after the live
17:38 boot and is now settled by disassembly, because getting it wrong reads
`AnimatedToggle._offTrigger`-adjacent memory and hands back a plausible
pointer nothing would catch.

MEASURED `R disasm 0x16bc7f0` (`UIAnimatedToggleSpawner::SpawnObject`):

```
rdi = base UISpawner`1::SpawnObject()     ; 0x37EA210 -- fills _spawnedObject@0xa0
rax = this.get_SpawnableToggle()          ; 0x16BC670 -- reads _spawnableToggle@0xc0
if (rax == null) return
rcx = [rax+0xa8]                          ; UISpawnableToggle._headerLabel
rsi = [rax+0xd0]                          ; UISpawnableToggle.Toggle : AnimatedToggle
[rax+0xd8] = [rcx+0x260]                  ; _originalFontStyle = the label's style
Toggle::SetToggleGroup(rsi, this._toggleGroup@0xb0, true)   ; 0x55BA150
Toggle::PlayEffect(rsi, true)                               ; 0x55BA690
Selectable::set_interactable(rdi, !this._unavailable@0xb8)  ; 0x55AFB40  <-- rdi
```

`Selectable::set_interactable` takes a `Selectable`, and it is called on
**`rdi`**, the base `SpawnObject` return -- the value stored in
`_spawnedObject@0xa0`. `UISpawnableToggle` is **not** a `Selectable`: MEASURED
`fldoff.py fields EFT.UI.UISpawnableToggle` puts `_sizeLabel@0xb0` exactly
where `Selectable.m_SpriteState@0xb0` lives, so one type cannot be both.
Therefore `_spawnedObject@0xa0` is the `AnimatedToggle`.

Two independent confirmations: `ToggleSilently` @`0x16BCBA0` passes
`get_SpawnedObject`'s return **straight** into `Toggle::Set` and then reads
`m_Transition@0x50` and `_onTrigger@0x128` off it, with no `+0xd0` anywhere;
and `get_SpawnableToggle` @`0x16BC670` is MEASURED to load
`mov rdi, [rbx+0xc0]` -- the serialized PREFAB reference `_spawnableToggle`,
which is what owns `Toggle@0xd0`. **`+0xd0` applies to `@0xc0`, never to
`@0xa0`.**

**T13b -- a freshly `Instantiate`d spawner has NOT spawned, and verifying
before asking hides the whole feature.** MEASURED live (host log 17:38, lines
873-875): both cloned subtab spawners read `_spawnedObject@0xa0` null-or-dead
**at build**, a build that refused them both and hid the strip -- "only 0 of 2
subtabs came out usable". The field is null until somebody asks the lazy
factory, and a clone has never been asked, so that check was testing for a
thing whose absence the checker itself caused.

The build step must **ask once, then verify**. Ask with
`UIAnimatedToggleSpawner::SpawnObject` @`0x16BC7F0` -- UNIQUE and
**non-generic**, so there is no `MethodInfo*` to supply, unlike
`get_SpawnedObject` @`0x37EA0C0`, whose shared-generic body needs a real one
(§5 T5) that a host has no way to obtain. Per the disassembly above, that call
also performs the `SetToggleGroup` join to the spawner's own
`_toggleGroup@0xb0`, which is the durable membership. Read the field back
afterwards rather than trusting the return. Do **not** call it when the field
already holds a live toggle -- fact #93: a spawner that already has one
produces a SECOND.

The raw-read-only rule is unchanged everywhere else: identity matching on the
click path and every verdict read must never call the getter, because the
getter can CREATE the thing being judged.

**OPEN: is the stock `Control Settings/Toggles` donor itself unspawned** until
`ControlSettingsTab::Show` runs? If the player never opens Controls, a clone
of that strip may inherit null fields -- which would make T13b's null the
*normal* case rather than an accident. Not established offline; the host now
logs both the clone's and the donor's `_spawnedObject@0xa0` at clone time, so
the next boot answers it.

**OPEN: what destroys the spawned toggle here.** Not established. Candidates
are ``UISpawner`1::Cleanup`` (generic body `0x37EA880`) and the settings
close/tab-init path. The fix above does not depend on the answer -- it is
correct for any destroyer -- but the answer is worth having, because whatever
it is is also touching objects of ours.

---

## 6. What a correct implementation must do

Ordered. Every argument value below is **read from the disassembly cited**, not
chosen. The `MethodInfo*` is the trailing argument in every case; it is NULL
wherever the game itself passes NULL (`xor r8d,r8d` / `xor r9d,r9d` in the cited
body), and it is **mandatory and non-NULL** only for `CreateControl<T>`.

### 6.1 Switching to an existing stock tab (Graphics, PostFX, …)

Do **not** press the toggle. Call the game's own entry:

1. Byte-verify the 16-byte prologue of `0x1720DE0` against the **startup
   snapshot**, never live memory.
2. `ShowScreen(screen, group, NULL)` — `rcx = SettingsScreen*`,
   `edx = ESettingsGroup` (`Screen=0 Game=1 Sound=2 Control=3 PostFX=4`),
   `r8 = NULL`. Source: `<Awake>b__1` passes exactly this
   (`mov edx,[rax+0x10]; xor r8d,r8d; jmp 0x1720DE0`).

That performs OLD-OFF → build → NEW-ON and keeps `_currentTab@0x118` and
`ScreenController[+0x60]` consistent. It leaves the tab **toggles** untouched,
so afterwards match the strip with
`UIAnimatedToggleSpawner::ToggleSilently(spawner, true)` `0x16BCBA0` — MEASURED
to route through `Toggle::Set` with `sendCallback = false`, so it cannot
re-enter our own `Set` drain.

### 6.2 A subtab strip on the Graphics tab

Copy `ControlSettingsTab`, exactly:

1. One `UIAnimatedToggleSpawner` per subtab, all in **one shared `ToggleGroup`**,
   joined via `Toggle::SetToggleGroup(tog, group, false)` `0x55BA150` — never by
   writing `m_Group@0x110`. (`SpawnObject` `0x16BC7F0` makes precisely this call;
   `RegisterToggle` alone would leave the old group holding a stale entry.)
2. One panel GameObject per subtab, siblings under one content parent.
3. Our own handler per subtab, doing **only**
   `GameObject::SetActive(myPanel, isOn)` — the shape of `HandleGesturesToggle`
   `0x16FED50`. **Never a "hide all then show one" sweep:** the group already
   guarantees exclusivity, and every OFF handler has already run by the time the
   ON handler is entered (§2.3).
4. Leave `group.m_AllowSwitchOff@0x20` false, so `Set(false)` on the last-on
   toggle is refused inside `Toggle::Set` step 3a.
5. Read `Toggle.m_IsOn@0x120` before any `Set` (T2).

### 6.3 A MODS tab beside the five stock ones

`ESettingsGroup` cannot be extended (T1), so the sixth tab is **ours end to
end**: our spawner, our drain, our panel, our `SetActive`. The stock machinery
never needs to know about it — but pressing a **stock** tab will not hide our
panel, because `ShowScreen` only calls `set_IsSelected` on tabs in `_tabs`.

The correct drain is a read-only detour on **`Toggle::Set` `0x55BA450`
(UNIQUE)**, filtering `sendCallback == true` (register index 2 = `r8`),
comparing `rcx` against our own toggle pointers, and:

* our toggle went ON → `SetActive(ourPanel, true)` and
  `set_IsSelected(_currentTab@0x118, false)` `0x171BCA0` to fold the stock panel;
* a stock tab toggle went ON → `SetActive(ourPanel, false)`.

One detour, riding the same event the game rides. **The OFF events arrive
first** (§2.3) — a drain that assumes otherwise has the order backwards.

### 6.4 A Controls > MODS keybind page

Reuse the row prefab rather than building one:
`ControlSettingsTab._commandKeyPairTemplate@0x98`, parented into
`_commandsContainer@0xa8`. Per row, write `_keyName@0x80` and `_key2Name@0x90`
with `TMP_Text::set_text` `0x51BC1E0`, and the caption via `_commandName@0x70`
→ `LocalizedText::SetLabelText` `0x140FE70`, **re-applied** after any locale
event (§4). Do not call `CommandKeyPair::Show` `0x16F9340` without a real
`KeyGroup`; it reads the input system.

### 6.5 The finished-state predicates a verdict must read back

Each is a property of the finished tree, and each can fail. Three outcomes:
PASS / FAIL / **INCONCLUSIVE** (a pointer that would not read, a screen that
never opened, a `find` that STOPPED EARLY).

1. **Exactly one** of `SettingsScreen` children `[3]`..`[7]`, plus our own panel,
   reports `GameObject::get_activeInHierarchy == true`. Falsifiable: two active
   is FAIL, zero active is FAIL.
2. `_currentTab@0x118` is non-null and its GameObject is the panel from (1) —
   or, if **our** tab is up, `_currentTab`'s GameObject is **inactive** (we
   folded it) and ours is active.
3. **Exactly one** toggle in the tab `ToggleGroup` has `m_IsOn@0x120 != 0`.
   Walk `m_Toggles@0x28` (`_items@0x10`, `_size@0x18`, base `+0x20`, stride 8),
   capped. Falsifiable: two on, or zero on.
4. Likewise exactly one on in the subtab group, and the active subtab panel is
   the one whose handler that toggle drives.
5. **No** TMP under our panel still reads a donor caption — a negative,
   enumerated over the panel subtree, capped.
6. Our strip's parent has **no** `LayoutGroup` component, **or** our strip's
   `LayoutElement.ignoreLayout` is true. Read the component; do not infer it
   from the resulting rect.
7. Our cloned strip's `childCount` equals the number of subtabs we created.
   **T12: this is 4 today where it should be 2.**
8. Geometry is asserted against the panel we parented into, **never** by
   comparing Graphics' rect to PostFX's — §3 shows those agree only by
   arithmetic coincidence at this window height.
9. Assert (1)–(8) **at least one frame after** the change: a `LayoutGroup`
   rebuild is deferred to `willRenderCanvases` and `Object.Destroy` to end of
   frame. A same-frame read is INCONCLUSIVE, not PASS.

---

## 7. Where existing records disagree with this map

Each line names the existing claim and the measurement that contradicts it.

1. **`docs/SETTINGS.md`** lists `SettingsScreen::Show` as VA `0x18171FA00`
   (RVA `0x171FA00`). That is the **0-argument** overload. The one that takes
   the controller and drives `OpenGroup` is **`0x171F970`**, and it is PUBLIC
   VIRTUAL. `R typemethods EFT.UI.Settings.SettingsScreen`.
2. **`docs/SETTINGS.md`** lists `SettingFloatSlider::.ctor` at `0xCFD7D0`.
   MEASURED **SHARED x26** and a TAILJUMP — it is the shared base-constructor
   thunk for nine of the classes in this map, not that class's own code.
3. **`docs/SETTINGS.md` §1** still reads as a live conclusion that native
   injection into the settings screen is infeasible, with the refutation quoted
   only in an indented block below it. Both halves are in one file and the first
   half is wrong.
4. **`CLAUDE.md`** says `0x628110` is shared by **6438** methods. MEASURED
   `R shared 0x628110`: **9614**.
5. **`CLAUDE.md` and the `il2cpp-host` skill** describe `0x628110` as
   `ForceMeshUpdate`, "a bare `ret`". It is `C2 00 00` (`ret 0`), it is not that
   method's code, and `SettingsTab::OnFirstSelect` / `OnSelect` land on it too —
   which means **the base-class first-select hook is a no-op and every real one
   is an override through the vtable at `klass+0x2C8` / `+0x2D8`**.
6. **The `il2cpp-host` skill** says `il2cpp_object_get_class` and
   `il2cpp_value_box` *fault*. `CLAUDE.md` §5 already corrects this: they are
   token-gated or intact, and `object_get_class` is `mov rax,[rcx]; ret`, which
   returns a plausible number for a bad pointer. Not re-measured here; flagged
   because the skill text still carries the old claim.
7. **`nativetabs.nim` (~line 377)** says `set_isOn` is
   `xor r9d,r9d; mov r8b,1; jmp +0x15`. MEASURED at `0x55BA440`
   (`SetIsOnWithoutNotify`): `xor r9d,r9d; xor r8d,r8d; jmp 0x55BA450`. The
   conclusion (both are ~11-byte thunks into `Set`; only `Set` is hookable) is
   right; the quoted bytes belong to the other thunk.
8. **`nativetabs.nim`** frames the subtab problem as geometry negotiation with a
   `LayoutGroup`. MEASURED, the stock subtab mechanism has no geometry step at
   all: `HandleGesturesToggle` is one `SetActive`, and exclusivity is
   `ToggleGroup`'s. The `LayoutGroup` fight is a consequence of cloning a strip
   into a laid-out container, not of having subtabs.
9. **`nativeui.nim`'s target table** (67 entries) carries `Toggle::Set`,
   `Toggle::set_group`, `SettingsTab::CleanupCreatedControls` and
   `UIAnimatedToggleSpawner::SpawnObject`, but **not**
   `SettingsTab::set_IsSelected` `0x171BCA0`, **not**
   `SettingsScreen::ShowScreen` `0x1720DE0`, and **not**
   `Toggle::SetToggleGroup` `0x55BA150` — the whole panel-switch and group-join
   API. (`abi/aowlspt_bridge.h` and `abi/aowlspt_navui.h` do carry the first two
   with the same RVAs measured here, so the numbers agree; it is the *host
   target table* that lacks them.)
10. **`nativeui.nim` uses `Toggle::set_group` `0x55B9D30`.** That setter writes
    `m_Group@0x110` only; the *registering* call is `SetToggleGroup`
    `0x55BA150`. Setting the group without registering is exactly the T3 throw.
11. **`nativetabs.nim`'s `Toggle::Set` drain** ignores `sendCallback == false`,
    which is correct for filtering our own writes — but MEASURED,
    `NotifyToggleOn` propagates `sendCallback` verbatim, so a stock press
    produces `sendCallback == true` **OFF** events for toggles we may own, and
    they arrive **before** the ON event.
12. **`docs/SETTINGS.md`** describes `ControlSettingsTab`'s keybind rows as
    `CommandKeyPair`/`CommandAxisPair` with `ListenForKey` — correct — but does
    not record that `CommandAxisPair` derives from `MonoBehaviour`, not
    `UIElement`, so its field offsets start at `0x20` and share no prefix with
    `CommandKeyPair`'s (which start at `0x70`). Using one layout for both reads
    garbage.

---

## 8. Open questions this map does NOT answer

Stated so nobody mistakes silence for a measurement.

* **Whether the subtab `onValueChanged` edge really is prefab-serialized.**
  §2.10 gives the evidence and marks it INFERRED. Settling it needs one live
  read: `component <GesturesToggle GO> AnimatedToggle`, then
  `read $comp+0x118 ptr` and a walk of the resulting
  `UnityEventBase.m_PersistentCalls`. **This is the live read I would ask for
  first.**
* **`_tabs`' runtime `Dictionary` layout.** Instantiated generic layouts are not
  in `GameAssembly.dll` (every `Il2CppGenericClass.cached_class` is null).
  Everything above goes through `FindEntry` `0x3FA7B90` and the sret buffer,
  which is layout-independent.
* **`SettingsTab::OnTabSelected` `0x171BDA0` appears to have no caller.**
  INFERRED from its absence in the bodies I read; I did not run
  `R callers 0x171bda0`.
* **`ScreenController@0x90` / `<Destroyed>@0x98`.** Derived from use; the
  offline field table reports both as `GENERIC` and cannot confirm the split.
  A live `read <SettingsScreen>+0x90 ptr` followed by `parent`/`fields` on the
  result would settle it.
* **Whether `OpenGroup` really runs `ShowScreen` twice** (§2.7). Derived from
  two measured bodies; not observed live.
* **The exact `Show*()` → `CreateControl<T>` call shape.** §2.9 gives the
  sequence as INFERRED from the API plus `_currentControlIndex`; I did not
  disassemble a `Show*()` body end to end.
