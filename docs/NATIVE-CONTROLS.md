# Native settings controls — how Tarkov builds a settings row, and what a mod must call

**Status of every number here:** derived OFFLINE from `D:\Aowlspt\GameAssembly.dll` +
`.cache/global-metadata.dec.dat` with `tools/il2cpp_resolve.py` and a helper that reuses
`tools/gen_uimap.py:method_rva` + `Resolver.sharedness`. Nothing below has been proven
against a running client. Offline evidence is **PASS/GAP/UNKNOWN**, never "works".

Self-check passed before any offset was read: `System.String._stringLength@0x10`,
`_firstChar@0x14` reproduced.

Repro for any single line:

```
python tools/il2cpp_resolve.py D:/Aowlspt/GameAssembly.dll .cache/global-metadata.dec.dat fields <Type>
python tools/il2cpp_resolve.py D:/Aowlspt/GameAssembly.dll .cache/global-metadata.dec.dat bytes <RVA>
python tools/il2cpp_resolve.py D:/Aowlspt/GameAssembly.dll .cache/global-metadata.dec.dat shared <RVA>
```

---

## 0. The headline: cloning was never necessary

The game has a first-class prefab-template system for settings rows. **Every settings tab
holds serialized prefab references to the row widgets it needs**, and instantiates them at
`Awake`/`CreateControls` time. A mod does not need to counterfeit a widget: it needs the
tab's prefab field and `Object.Instantiate`.

```
SettingsScreen                    (EFT.UI.Settings.SettingsScreen)
 |- _gameButton .. _controlsButton : UIAnimatedToggleSpawner   <- the TAB buttons
 \- _gameSettingsScreen .. _controlsSettingsTabScreen : SettingsTab subclasses
       |- _settingsRoot / _settingsContainer : RectTransform|Transform   <- row parent
       |- _toggleTemplate       : SettingToggle          <- PREFAB
       |- _dropDownTemplate     : SettingDropDown        <- PREFAB
       |- _floatSliderTemplate  : SettingFloatSlider     <- PREFAB
       \- _selectSliderTemplate : SettingSelectSlider    <- PREFAB
```

`SettingsTab.CreateControl<T>(T prefab, Transform parent)` is the game's own one-liner. It
is a **generic method with no entry in `methodPointers`** — see §5 — so a mod substitutes
`UnityEngine.Object.Instantiate(Object, Transform, bool)`, which is non-generic and has a
real, unique RVA.

## 1. The prefab family

### The row base — `EFT.UI.Settings.SettingControl`

`SettingControl <- EFT.UI.UIInputNode <- EFT.InputSystem.InputNode <- InputNodeAbstract <- SerializedMonoBehaviour <- MonoBehaviour`

| offset | field | type |
|---|---|---|
| 0x80 | `Text` | `LocalizedText` |
| 0x88 | `_blocker` | `UiElementBlocker` |
| 0x90 | `NotifyUserChanged` | `Action` |
| 0x98 | `_tooltipSettingsHover` | `SettingsHoverTooltipArea` |
| 0xa0 | `_elementBlocker` | `UiElementBlocker` |

| RVA | sharedness | signature |
|---|---|---|
| 0x16fa7c0 | unique | `void InitSetting(IGameSetting setting)` |
| 0x16fa890 | unique | `SettingControl SetText(string localizationKey)` |
| 0x16fa910 | unique | `SettingControl SetSiblingIndex(int index)` |
| 0x16fa9d0 | unique | `SettingControl SetName(string newName)` |
| 0x16faa50 | unique | `SettingsHoverTooltipArea GetOrCreateTooltip()` |
| 0x16fac00 | unique | `SettingControl SetTooltip(SettingsTooltipData tooltipData, SettingsTooltip tooltipView)` |
| 0x16fafc0 | unique | `SettingControl SetChangeAction(Action action)` |
| 0x690f30 | **shared x92** | `UiElementBlocker get_Blocker()` |
| 0x628110 | **shared x9614** | `void SetValueText(string value)` — this is the build's universal empty-body stub. `SettingControl` does not override it; the subclasses do. Never detour it. |
| 0xcfd7d0 | **shared x26** | `void .ctor()` |

Note the fluent API: `SetText` / `SetSiblingIndex` / `SetName` / `SetChangeAction` all
return `SettingControl` (RAX = the same `this`), so they chain.

### `EFT.UI.Settings.SettingToggle` (a checkbox row)

`SettingToggle <- SettingControl`. One own field: `0xa8 Toggle : UpdatableToggle`.

| RVA | sharedness | signature |
|---|---|---|
| 0x16fd0d0 | unique | `SettingToggle BindTo(GameSetting<bool> setting)` |
| 0x66e6c0 | **shared x60** | `Component get_TargetComponent()` |
| 0xcfd7d0 | **shared x26** | `.ctor()` |

### `EFT.UI.Settings.SettingFloatSlider`

Own field: `0xa8 Slider : NumberSlider`.

| RVA | sharedness | signature |
|---|---|---|
| 0x16fb4c0 | unique | `SettingFloatSlider BindTo(GameSetting<int> setting, int minValue, int maxValue)` |
| 0x16fb810 | unique | `SettingFloatSlider BindTo(GameSetting<float> setting, float minValue, float maxValue, string format)` |

### `EFT.UI.Settings.SettingSelectSlider`

Own field: `0xa8 Slider : SelectSlider`. All three `BindIndexTo` overloads are **generic
(`mvar`) and have NO code entry** — GAP, see §5. Non-generic here:

| RVA | sharedness | signature |
|---|---|---|
| 0x16fbbe0 | unique | `void SetValueText(string value)` |

### `EFT.UI.Settings.SettingDropDown`

Own field: `0xa8 DropDown : DropDownBox`.

| RVA | sharedness | signature |
|---|---|---|
| 0x16fb330 | unique | `void Close()` |
| 0x16fb390 | unique | `void SetValueText(string value)` |
| 0x16fb3c0 | unique | `SettingDropDown SetSpriteAsset(TMP_SpriteAsset asset)` |
| 0x16fb400 | unique | `ReadOnlyCollection<int> GetIndexCollection(ICollection source)` |
| — | no-code | `BindTo(...)`, `BindToEnum(...)`, `BindDropDownToSetting(...)`, `UpdateDropDownValue(...)` — all generic. GAP. |

### The inner widgets the rows wrap

`EFT.UI.NumberSlider <- UIInputNode` — `_slider : UnityEngine.UI.Slider @0x80`,
`_valueInput : TMP_InputField @0x88`, `_format @0x90`, `_maxValue @0x98`, `_minValue @0x9c`,
`_onValueChanged : Action<float> @0xa8`.

| RVA | sharedness | signature |
|---|---|---|
| 0x16b4ea0 | unique | `void Show(float minValue, float maxValue, string format)` |
| 0x16b5300 | unique | `void SetCurrentValue(float value)` |
| 0x16b5710 | unique | `void UpdateValue(float value, bool sendCallback, Nullable<float> min, Nullable<float> max)` |
| 0x6910c0 | **shared x34** | `void Bind(Action<float> valueChanged)` |
| 0x16b5850 | unique | `float CurrentValue()` |

`EFT.UI.SelectSlider <- UIElement` — `_slider @0x70`, `_valueText : TextMeshProUGUI @0x78`,
`_notchTemplate : GameObject @0x80`, `_notchContainer : RectTransform @0x88`,
`_notches : List<GameObject> @0x90`, `_onValueChanged : Action<int> @0x98`, `_values : string[] @0xb0`.

| RVA | sharedness | signature |
|---|---|---|
| 0x16b9e30 | unique | `void Show(string[] values)` |
| 0x16ba060 | unique | `void Show(Func<string[]> values)` |
| 0x16ba340 | unique | `void UpdateValue(int value, bool sendCallback, Nullable<int> min, Nullable<int> max)` |
| 0x16ba670 | unique | `void SetLabelText(string text)` |
| 0x691000 | **shared x38** | `void Bind(Action<int> valueChanged)` |

`EFT.UI.DropDownBox <- BaseDropDownBox <- InteractableElement <- UIElement` —
`_currentValueText @0xf0`, `_button : UnityEngine.UI.Button @0xf8`, `_background : Image @0x100`.

| RVA | sharedness | signature |
|---|---|---|
| 0x16afc80 | unique | `void Show(IEnumerable<string> values, Func<int,bool> validator)` |
| 0x16b0220 | unique | `void SetPanelState(bool open)` |
| 0x16b0c40 | unique | `void SetTextInternal(string text)` |

### The toggle widget, and the ToggleGroup that is suspected of the inverted highlight

`EFT.UI.UpdatableToggle <- UnityEngine.UI.Toggle <- Selectable <- UIBehaviour`.
`EFT.UI.AnimatedToggle` has the same base.

Inherited `UnityEngine.UI.Toggle` layout (measured):

| offset | field |
|---|---|
| 0x100 | `toggleTransition : ToggleTransition` |
| 0x108 | `graphic : Graphic` |
| **0x110** | **`m_Group : ToggleGroup`** |
| 0x118 | `onValueChanged : ToggleEvent` |
| 0x120 | `m_IsOn : bool` |

`UpdatableToggle` adds `_onValueChanged : Action<bool> @0x128`.
`AnimatedToggle` adds `_onTrigger : string @0x128`, `_offTrigger : string @0x130`,
`OnMouseDown : Action @0x138`.

| RVA | sharedness | signature |
|---|---|---|
| 0x55b9d30 | unique | `UnityEngine.UI.Toggle::void set_group(ToggleGroup value)` |
| 0x55ba150 | unique | `UnityEngine.UI.Toggle::void SetToggleGroup(ToggleGroup newGroup, bool setMemberValue)` |
| 0x66e740 | **shared x28** | `ToggleGroup get_group()` |
| 0x16c4ba0 | unique | `UpdatableToggle::void UpdateValue(bool value, bool sendCallback, Nullable<bool> min, Nullable<bool> max)` |
| 0x691790 | **shared x16** | `UpdatableToggle::void Bind(Action<bool> valueChanged)` |
| 0x66e7c0 | **shared x10** | `UpdatableToggle::bool CurrentValue()` |
| 0x16ad190 | unique | `AnimatedToggle::void set_IsToggled(bool value)` |
| 0x16ad1e0 | unique | `AnimatedToggle::void ToggleSilent(bool value)` |
| 0x16ad660 | unique | `AnimatedToggle::void InstantClearState()` |

**This is the mechanism behind the inverted-highlight suspicion, and it is structural
evidence, not proof.** A cloned toggle carries the donor's serialized `m_Group @0x110`, so
`ToggleGroup.NotifyToggleOn` will turn the clone's siblings off — and, for an
`AnimatedToggle`, the on/off animator trigger is driven from `IsToggled`. If you must keep
a clone alive, `set_group(null)` @0x55b9d30 (unique) is the surgical fix. Instantiating the
prefab avoids the question entirely, because the tab prefab is not a member of the tab-bar
group. **UNKNOWN offline:** whether the observed inversion is `m_Group` or the animator
trigger pair — only a live read of `m_Group @0x110` / `_onTrigger @0x128` settles it.

Do **not** confuse `UnityEngine.UI.Toggle` with `EFT.UI.ToggleEFT`, a separate BSG class
whose own group field is `_toggleGroup : ToggleGroupEFT @0x78` and which is **not** a
`UnityEngine.UI.Toggle`. Reading 0x110 on a `ToggleEFT` reads unrelated memory.

## 2. The tab/subtab button family

``EFT.UI.UIAnimatedToggleSpawner <- EFT.UI.UISpawner`1<AnimatedToggle> <- EFT.UI.UIElement``.
It is the **only** subclass of ``UISpawner`1`` on this build (verified by walking every one
of the 31,282 typedefs' parent chains, resolving `genericinst` bases through
`Il2CppGenericClass.type`).

Fields (PASS — matches the briefing exactly):

| offset | field | type |
|---|---|---|
| 0xa8 | `_canvasGroup` | `CanvasGroup` |
| 0xb0 | `_toggleGroup` | `UnityEngine.UI.ToggleGroup` |
| 0xb8 | `_unavailable` | `bool` |
| 0xbc | `_siblingIndex` | `int` |
| 0xc0 | `_spawnableToggle` | `UISpawnableToggle` (the PREFAB) |

| RVA | sharedness | signature |
|---|---|---|
| **0x16bc7f0** | unique | `AnimatedToggle SpawnObject()` — the factory call |
| 0x16bc670 | unique | `UISpawnableToggle get_SpawnableToggle()` |
| 0x16bcc30 | unique | `void SetHeaderText(string caption, int size)` |
| 0x16bcce0 | unique | `void SetActive(bool active)` |
| 0x16bcba0 | unique | `void ToggleSilently(bool show)` |
| 0x16bc600 | unique | `void set_IsToggled(bool value)` |
| 0x16bca00 | unique | `void SetEllipsis(bool useEllipsis)` |

Inherited ``UISpawner`1`` members — `SpawnObject()`, `SetHeaderText`, `SetMinWidth`,
`SetEllipsis`, `UpdateSpawnerLocale`, `Cleanup` — are all **no-code** (generic definition).
Its fields (`_object`, `_headerCaption`, `_headerFontSize`, `_preservedChildren`,
`_minWidth`, `_useEllipsis`, `_localizationSubscription`, `_spawnedObject`) are **GENERIC —
NO LAYOUT**. Use `UIAnimatedToggleSpawner`'s own overrides above; they have real RVAs.

`EFT.UI.UISpawnableToggle <- ButtonFeedback <- InteractableElement <- UIElement` —
`_headerLabel : TextMeshProUGUI @0xa8`, `_sizeLabel @0xb0`, `_iconSprite : Image @0xb8`,
`_isBoldOnHover @0xc0`, `HoverImage : GameObject @0xc8`, `Toggle : AnimatedToggle @0xd0`,
`_originalFontStyle @0xd8`. Inherited: `_unavailable @0x70`, `_canvasGroup @0x78`,
`_tooltipArea @0x80`, `UI : UIParent @0x60`, `_rectTransform @0x68`.

| RVA | sharedness | signature |
|---|---|---|
| 0x1435af0 | unique | `void Init(ToggleGroup group)` |
| 0x1435b40 | unique | `void InitSpawnableButton(string headerText, int headerSize, Sprite sprite, GameObject hoverImage)` |
| 0x1435a50 | unique | `void set_IsToggled(bool value)` |
| 0x1435ab0 | unique | `void set_Interactable(bool value)` |
| 0x1435f00 | unique | `void SetEllipsis(bool useEllipsis)` |
| 0x1436090 | unique | `void SetMinWidth(float minWidth)` |
| 0x14361f0 | unique | `void Highlighted()` |
| 0x1436380 | unique | `void Default()` |
| 0x1435a20 | **shared x2** | `bool get_IsToggled()` |
| 0x1405c00 | **shared x6** | `bool get_Interactable()` |

## 3. The construction path, end to end

Taking `GameSettingsTab` as the exemplar (its `CreateControls` @0x1703fb0 is the real one):

1. `SettingsScreen.Awake` @0x171e940 wires the five `UIAnimatedToggleSpawner` tab buttons
   and the five `SettingsTab` subclass instances (all serialized fields, §4).
2. Pressing a tab button reaches `SettingsScreen.ShowScreen(ESettingsGroup)` @0x1720de0 ->
   `EnsureTabInitialized(ESettingsGroup)` @0x171ff10.
3. The tab's `Show(...)` (`GameSettingsTab.Show(GameSettingsGroup, IEftSession, bool)`
   @0x17037a0) -> `CreateControls()` @0x1703fb0.
4. `CreateControls` calls one `ShowXxx()` per row — e.g. `ShowFieldOfView()` @0x17066a0,
   `ShowHeadBobbing()` @0x1706430, `ShowStreamerMode()` @0x17072f0.
5. Each `ShowXxx` calls **`SettingsTab.CreateControl<T>(T prefab, Transform parent)`**
   (generic, no-code), which instantiates the prefab under the parent and appends it to
   `SettingsTab._createdControls : List<SettingControl> @0x88`.
6. The fresh control is then chained: `.SetText(key)` @0x16fa890 -> `.SetSiblingIndex(i)`
   @0x16fa910 -> `.BindTo(setting, ...)` (per-type) -> optionally `.SetTooltip(...)`
   @0x16fac00 / `.SetChangeAction(...)` @0x16fafc0.
7. `SettingsTab.Close()` @0x171bdf0 -> `CleanupCreatedControls()` @0x171be50 destroys
   everything in `_createdControls`.

### `EFT.UI.Settings.SettingsTab` (base)

| offset | field | type |
|---|---|---|
| 0x80 | `OnLoadingInProgress` | `Action<bool>` |
| 0x88 | `_createdControls` | `List<SettingControl>` |
| 0x90 | `<IsInitialized>k__BackingField` | `bool` |

| RVA | sharedness | signature |
|---|---|---|
| 0x171bca0 | unique | `void set_IsSelected(bool value)` |
| 0x171bda0 | unique | `void OnTabSelected()` |
| 0x171bdf0 | unique | `void Close()` |
| 0x171be50 | unique | `void CleanupCreatedControls()` |
| 0x171c0d0 | unique | `void SetLoadingStatus(bool inProgress)` |
| — | no-code | `T CreateControl<T>(T prefab, Transform parent)` — GAP, §5 |
| 0x14f3560 | **shared x3** | `void ResetInitialization()` |
| 0xcad190 | **shared x13** | `bool get_IsInitialized()` |
| 0x628110 | **shared x9614** | `OnFirstSelect()` / `OnSelect()` — universal stub on the BASE; subclasses override (e.g. `GameSettingsTab.OnFirstSelect` @0x1703cb0, unique). |

**`_createdControls` is the ownership hook.** A row a mod instantiates and does NOT append
to that list survives `CleanupCreatedControls` and will be a duplicate the next time the
tab opens. A row it DOES append is destroyed for it. Pick one deliberately.

## 4. The prefab fields, per tab

`EFT.UI.Settings.SettingsScreen`

| offset | field | type |
|---|---|---|
| 0xa0 | `_loader` | `GameObject` |
| 0xa8 / 0xb0 / 0xb8 / 0xc0 | `_saveButton` / `_backButton` / `_defaultButton` / `_creditsButton` | `DefaultUIButton` |
| 0xc8 | `_gameButton` | `UIAnimatedToggleSpawner` |
| 0xd0 | `_graphicsButton` | `UIAnimatedToggleSpawner` |
| 0xd8 | `_postFXButton` | `UIAnimatedToggleSpawner` |
| 0xe0 | `_soundButton` | `UIAnimatedToggleSpawner` |
| 0xe8 | `_controlsButton` | `UIAnimatedToggleSpawner` |
| 0xf0 | `_gameSettingsScreen` | `GameSettingsTab` |
| 0xf8 | `_graphicsSettingsScreen` | `GraphicsSettingsTab` |
| 0x100 | `_postFXSettingsScreen` | `PostFXSettingsTab` |
| 0x108 | `_soundSettingsScreen` | `SoundSettingsTab` |
| 0x110 | `_controlsSettingsTabScreen` | `ControlSettingsTab` |
| 0x118 | `_currentTab` | `SettingsTab` |
| 0x138 | `_initializedTabs` | `HashSet<ESettingsGroup>` |
| `0x0` *(static)* | `_tabs` | `Dictionary<ESettingsGroup,SettingsGroupObjects>` — static; `0x0` here is a static-storage index, not an instance offset |

| RVA | sharedness | signature |
|---|---|---|
| 0x171e940 | unique | `void Awake()` |
| 0x171fa00 | unique | `void Show()` |
| 0x171f970 | unique | `void Show(SettingsScreenController controller)` |
| 0x171ff10 | unique | `void EnsureTabInitialized(ESettingsGroup group)` |
| 0x1720c80 | unique | `void OpenGroup(ESettingsGroup desiredGroup)` |
| 0x1720de0 | unique | `void ShowScreen(ESettingsGroup group)` |
| 0x1720fd0 | unique | `void SetSaveButtonActive(bool status)` |
| 0x1721450 | unique | `void SaveButtonAction()` |
| 0x1720b10 | unique | `void Close()` |

`EFT.UI.Settings.GameSettingsTab` — `_settingsRoot : RectTransform @0x98`,
`_dropDownTemplate @0xa0`, `_floatSliderTemplate @0xa8`, `_toggleTemplate @0xb0`,
`_tooltip : SettingsTooltip @0xb8`, `_gameSettings : GameSettingsGroup @0xe8`,
`_controller : GameSettingsController @0xf0`, `_currentControlIndex : int @0x128`.
`Awake` @0x1703480, `Show(GameSettingsGroup,IEftSession,bool)` @0x17037a0,
`OnFirstSelect` @0x1703cb0, `CreateControls` @0x1703fb0, `Close` @0x17083d0 — all unique.

`EFT.UI.Settings.GraphicsSettingsTab` — `_settingsContainer : Transform @0x98`,
`_settingsScroll : ScrollRect @0xa0`, `_tooltip @0xa8`, `_dropDownTemplate @0xb0`,
`_toggleTemplate @0xb8`, `_selectSliderTemplate @0xc0`, `_selectFloatSliderTemplate @0xc8`,
`_selectSliderWideTemplate @0xd0`, `_currentControlIndex @0x144`.

`EFT.UI.Settings.PostFXSettingsTab` — `_mainToggleRoot : RectTransform @0x98`,
`_settingsRoot : RectTransform @0xa0`, `_tooltip @0xa8`, `_selectFloatSliderTemplate @0xb0`,
`_dropDownTemplate @0xb8`, `_toggleLeftTemplate @0xc0`, `_currentControlIndex @0xe8`.

`EFT.UI.Settings.SoundSettingsTab` — `_slidersSection : Transform @0xa0`,
`_togglesSection : Transform @0xa8`, `_selectSliderPrefab @0xb0`, `_floatSliderPrefab @0xb8`,
`_dropDownPrefab @0xc0`, `_togglePrefab @0xc8`, `_voipDropDownsSection @0xf0`,
`_voipSlidersSection @0xf8`, `_tooltip @0x100`.

`GraphicsSettingsTab` and `SoundSettingsTab` are the richest donors: between them they hold
a template for **all four** row kinds.

## 5. What is NOT determinable offline

* **`SettingsTab.CreateControl<T>(T prefab, Transform parent)` has no RVA.** It is a
  generic method; IL2CPP stores instantiations in the generic-method function table, not in
  the per-image `methodPointers` array that `il2cpp_resolve.py` walks. Every by-name lookup
  returns `no-code`. **GAP** — and `tools/il2cpp_resolve.py` has no verb for the generic
  method table. That is a missing verb worth adding (see §7).
* Same for every generic bind: `SettingDropDown.BindTo` / `BindToEnum` /
  `BindDropDownToSetting` / `UpdateDropDownValue`, all three
  `SettingSelectSlider.BindIndexTo` overloads, `SettingsTab.TakeSettingsFrom`,
  `GameSettingsTab.ShowCommonDropDown`, and every method on ``Bsg.GameSettings.GameSetting`1``.
  The two **non-generic** binds — `SettingToggle.BindTo(GameSetting<bool>)` @0x16fd0d0 and
  both `SettingFloatSlider.BindTo` overloads @0x16fb4c0 / @0x16fb810 — are the only ones a
  mod can call at a static RVA today.
* **``Bsg.GameSettings.GameSetting`1`` and ``BaseSettingsController`1`` have NO layout.**
  All fields print `GENERIC`; IL2CPP writes an all-zero fieldOffsets array for an
  uninstantiated generic definition, and every one of the 33,464 `Il2CppGenericClass`
  entries in the file has a null `cached_class`. **Any numeric offset for
  `GameSetting<bool>` or `BaseSettingsController<T>` would be fabricated.** Take that layout
  from a LIVE object's klass and say it is borrowed.
* **Which prefab field is non-null at any moment.** Every template above is a serialized
  Unity reference; it is populated when the prefab loads. A read before the tab's `Awake`
  gets null. Only a live read settles it.
* **Whether the inverted highlight is `m_Group` or the animator triggers.** §1.
* Nothing here has been run. Every RVA listed in §6 was byte-checked to be real code in the
  `il2cpp` section with a plausible prologue (`48 89 5C 24 ..` / `40 53 ..`), and **none of
  the unique ones is the `C2 00 00` universal stub at 0x628110** — but "is real code" is not
  "does what its name says".

## 6. The recipe

Imagebase `0x180000000`; add it to every RVA. Convention: `RCX=this`, `RDX/R8/R9=args`,
then a hidden trailing `const MethodInfo*` (NULL is fine for these — none is a shared
generic). Every call below must sit inside the host's single `aowl_p_p_seh` guard with a
`VirtualQuery` on every hop, per CLAUDE.md §5.

**Live pointers needed, and where they come from**

| pointer | how |
|---|---|
| `SettingsScreen*` | the host's existing `$settings` anchor (populated by the `ShowScreen` postfix or the `EnsureTabInitialized` invoke2 ladder). Inspector: `state`. |
| `GameSettingsTab*` | `$settings @0xf0`. Graphics `@0xf8`, PostFX `@0x100`, Sound `@0x108`, Controls `@0x110`. |
| row parent `Transform*` | `GameSettingsTab @0x98` (`_settingsRoot`) or `GraphicsSettingsTab @0x98` (`_settingsContainer`). |
| toggle prefab | `GameSettingsTab @0xb0` / `GraphicsSettingsTab @0xb8` / `SoundSettingsTab @0xc8`. |
| float-slider prefab | `GameSettingsTab @0xa8` / `GraphicsSettingsTab @0xc8` / `SoundSettingsTab @0xb8`. |
| dropdown prefab | `GameSettingsTab @0xa0` / `GraphicsSettingsTab @0xb0` / `SoundSettingsTab @0xc0`. |
| a `GameSetting<bool>*` to bind | **borrow an existing one** from a settings group, e.g. `GameSettingsTab @0xe8` (`GameSettingsGroup`) and the group's `GameSetting<bool>` fields listed in `docs/UI-MAP.md`. Constructing a fresh one is a GAP (§5). |
| `ToggleGroup*` for a tab button | `UIAnimatedToggleSpawner @0xb0` on any existing tab button (`$settings @0xc8`). |

Every one of these is a **null-capable** read. Refuse, do not proceed, on null — per
CLAUDE.md, an offset that can read null must never be trusted blind.

### (a) Add a subtab button to the settings screen

```
spawner   = <clone or new GameObject with a UIAnimatedToggleSpawner>   # see caveat
prefab    = read ptr  spawner + 0xc0            # _spawnableToggle : UISpawnableToggle
group     = read ptr  ($settings@0xc8) + 0xb0   # the tab bar's ToggleGroup
write i32 spawner + 0xbc = <sibling index>      # _siblingIndex
toggle    = call 0x16bc7f0 (spawner)            # UIAnimatedToggleSpawner.SpawnObject() -> AnimatedToggle*
call      0x16bcc30 (spawner, il2cpp_string_new("MY TAB"), 24)   # SetHeaderText(caption,size)
call      0x16bcce0 (spawner, 1)                                  # SetActive(true)
# wire the press:
call      0x16acc90 (toggle, <Action*>)         # AnimatedToggle.add_OnMouseDown
```

**Caveat, stated plainly:** `SpawnObject` is an instance method on a *spawner component*.
Getting a NEW `UIAnimatedToggleSpawner` onto a new GameObject needs either
`GameObject::AddComponent` on an injected/known klass or an `Instantiate` of an existing
spawner's GameObject. The second is a clone of a *spawner*, not of a *widget* — the clone's
`_spawnableToggle @0xc0` prefab is shared and correct, so the spawned toggle is a genuine
prefab instance, not a relabelled donor. That is strictly better than today's approach but
it is still a clone at the spawner level. **UNKNOWN:** whether a from-scratch spawner is
constructible; managed type injection is *plausible, not proven* on this build.

### (b) Add a checkbox row — the fully supported path

```
tab     = read ptr $settings + 0xf0                  # GameSettingsTab
parent  = read ptr tab + 0x98                        # _settingsRoot : RectTransform
prefab  = read ptr tab + 0xb0                        # _toggleTemplate : SettingToggle
row     = call 0x52adda0 (prefab, parent, 0)         # Object.Instantiate(Object,Transform,bool) -> Object*  [unique]
call      0x16fa890 (row, il2cpp_string_new("my/locale/key"))   # SetText   -> row
call      0x16fa910 (row, <index>)                              # SetSiblingIndex
setting = read ptr (read ptr tab + 0xe8) + <GameSetting<bool> field off from docs/UI-MAP.md>
call      0x16fd0d0 (row, setting)                              # SettingToggle.BindTo(GameSetting<bool>)
# or, with NO GameSetting at all:
call      0x16fafc0 (row, <Action*>)                            # SetChangeAction
```

Every RVA in (b) is **unique**. Optionally append `row` to
`SettingsTab._createdControls @0x88` so the game cleans it up (§3).

`UnityEngine.Object.Instantiate` overloads with real code (all unique):
`Instantiate(Object)` @0x52adbe0, `Instantiate(Object,Transform,bool)` @0x52adda0,
`Instantiate(Object,Vector3,Quaternion)` @0x52ad5e0,
`Instantiate(Object,Vector3,Quaternion,Transform)` @0x52ad8c0. The **generic** `Instantiate<T>`
overloads are no-code — use the non-generic ones.

### (c) Add a slider row

```
tab     = read ptr $settings + 0xf8                  # GraphicsSettingsTab (has all 4 templates)
parent  = read ptr tab + 0x98                        # _settingsContainer : Transform
prefab  = read ptr tab + 0xc8                        # _selectFloatSliderTemplate : SettingFloatSlider
row     = call 0x52adda0 (prefab, parent, 0)
call      0x16fa890 (row, il2cpp_string_new("my/locale/key"))
call      0x16fb810 (row, setting, 0.0f, 100.0f, il2cpp_string_new("F0"))
                       # SettingFloatSlider.BindTo(GameSetting<float>,float,float,string)
# the two floats ride in XMM registers by ARGUMENT POSITION (args 3 and 4 -> XMM2/XMM3
# with this=RCX, setting=RDX). VERIFY that against the disassembly before calling.
```

For a slider with **no** `GameSetting`, drive the inner `NumberSlider` directly:
`row @0xa8` -> `NumberSlider*` -> `Show(min,max,format)` @0x16b4ea0,
`Bind(Action<float>)` @0x6910c0 (**shared x34 — safe to CALL, never detour**),
`SetCurrentValue(float)` @0x16b5300.

### The verification, and it must be able to fail

Structural success is not the check. The finished-state assertions:

* `findtext "<my caption>"` under the settings screen returns **exactly one ACTIVE** hit,
  and its GameObject is a *child of the row parent*, not of the donor.
* **No** TMP under the new row still reads any donor caption (the negative — this is the
  one that catches a relabel).
* Reading `m_Group @0x110` on the new toggle returns **null** (a prefab instance is not in
  the tab-bar group). A non-null value there is the inverted-highlight bug reproduced.
* Pressing it changes the bound value read back from the live `GameSetting`, not merely
  from the widget.

PASS / FAIL / **INCONCLUSIVE** — a `find` that reports STOPPED EARLY, an unreadable
pointer, or a screen that never opened is INCONCLUSIVE, never PASS.

## 7. Tooling gaps hit while writing this (raising immediately, per CLAUDE.md §10)

**STATUS 2026-09-01 (tooling agent): 1, 2, 3 and 5 are FIXED; 4 is not.** `il2cpp_resolve.py` gained `genericmethods <Type>[::<Name>]` (gated on a new `verify-generics` self-check with a negative control) and `typemethods <Type>[--inherited]`; `parent_type` now resolves 0x15 GENERICINST *and* 0x1c OBJECT bases (it was dropping 13,088 of 29,835 real base classes, not only the generic ones) and is gated by `verify-parents`; `gen_uimap.py` GROUPS now covers `EFT.UI.Settings.`, `EFT.UI.Toggle` and `UISpawner`, the INTERESTING name filter is gone, and the map is regenerated. `SettingDropDown::BindTo<T>` has 7 instantiated bodies; `SettingToggle::BindTo` is 0x16fd0d0 (unique). Item 4 (dict-vs-tuple field APIs) was left alone.


1. **`il2cpp_resolve.py` has no verb for generic-method instantiations.** Every
   `CreateControl<T>` / `BindTo<T>` / `GameSetting<T>` member resolves to `no-code`, so the
   single most important method in the construction path (§3 step 5) has no address. IL2CPP
   keeps these in `Il2CppMetadataRegistration.genericMethodTable` /
   `Il2CppCodeRegistration.genericMethodPointers`; a `genericmethods <Type>::<Name>` verb
   that dumps `(instantiation, RVA, sharedness)` would close it. This is the biggest single
   unknown in the whole document.
2. **`Resolver.parent_type` returns `None` for a generic-instance base class.** It only
   accepts `Il2CppTypeEnum` 0x11/0x12 and drops 0x15, so
   ``UIAnimatedToggleSpawner <- UISpawner`1<AnimatedToggle>`` reads as "no base class". I had
   to reimplement the walk (deref `Il2CppGenericClass.type` -> the generic type definition's
   typeDefinitionIndex) to establish that ``UISpawner`1`` has exactly one subclass. A caller
   asking "does X derive from Y" gets a silent **wrong** answer today — that is the
   confidently-wrong-answer class of bug, not a missing feature.
3. **`il2cpp_resolve.py methods <substr>` matches the METHOD name only**, so
   `methods EFT.UI.Settings.SettingToggle` returns a zero-hit "searched EXHAUSTIVELY"
   verdict that reads as "this type has no methods". A `typemethods <Type>` verb (what my
   scratch script does with `type_methods` + `gen_uimap.method_rva` + `sharedness`) is the
   single most useful thing missing; it is ~20 lines and `gen_uimap.py` already contains all
   of it behind an `INTERESTING` name filter that happens to hide `BindTo`.
4. **`declared_fields_ex` returns dicts while `declared_fields` returns 4-tuples**, and
   neither is documented at the call site; unpacking the wrong one raises
   `too many values to unpack (expected 6, got 10)`. Minor, but it cost a cycle.
5. **`tools/gen_uimap.py` was run only with `--only EFT.Settings.`**, so `docs/UI-MAP.md`
   contains no `UISpawnable` section despite `GROUPS` declaring one — and it has no
   `EFT.UI.Settings.` group at all, which is where every type in this document lives.
   Suggested (NOT applied — this agent is read-only outside this file): add
   `("settings-widgets", "EFT.UI.Settings.")` and `("settings-toggles", "EFT.UI.Toggle")` to
   `GROUPS`, drop the `INTERESTING` filter for those, and regenerate.
