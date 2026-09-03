## ===========================================================================
## postfxrows.nim -- CONTENT for the PostFX subtab panel, built by
## INSTANTIATING THE GAME'S OWN SETTINGS-ROW PREFABS.
##
## WHAT CHANGED, AND WHY
## ---------------------
## This file used to build every row from scratch out of `nuikit` labels, and
## before that the feature CLONED a live stock row and relabelled it. Both were
## workarounds for one missing fact: how the game itself builds a settings row.
## `docs/NATIVE-CONTROLS.md` now maps that path, so neither workaround is
## justified any more.
##
##   Every `SettingsTab` holds SERIALIZED PREFAB references to the row widgets
##   it uses. On `EFT.UI.Settings.PostFXSettingsTab` (offsets measured from
##   Il2CppMetadataRegistration.fieldOffsets, System.String self-check passed):
##
##       0x88  _createdControls            List<SettingControl>
##       0xa0  _settingsRoot               RectTransform      <- THE ROW PARENT
##       0xb0  _selectFloatSliderTemplate  SettingFloatSlider <- PREFAB
##       0xb8  _dropDownTemplate           SettingDropDown    <- PREFAB
##       0xc0  _toggleLeftTemplate         SettingToggle      <- PREFAB
##
## and the construction call is `SettingsTab.CreateControl<T>(prefab, parent)`
## -- a GENERIC method with no entry in `methodPointers`, so it has NO RVA. The
## non-generic substitute is `Object.Instantiate(Object, Transform, bool)`
## @0x52ADDA0 (unique), followed by the game's own fluent chain
## `SetText` @0x16FA890 -> `SetSiblingIndex` @0x16FA910. All of that is in
## `abi/aowlspt_nativeui.h` with its provenance, byte-verified against the
## STARTUP PROLOGUE SNAPSHOT (never live memory) on every call.
##
## WHY THIS IS BETTER THAN A CLONE, concretely and not as a slogan: a clone
## inherits the DONOR's serialized wiring -- its `ToggleGroup`, its
## `LayoutElement` sizing, the children its spawner had already spawned -- and
## every one of those had to be found and undone by hand, once each, after it
## shipped a visible defect. A prefab instance inherits the PREFAB's wiring,
## which is exactly what the game's own rows inherit.
##
## WHAT IS DECLINED, LOUDLY
## ------------------------
## `preset` and `tonemapper` are ENUM settings. Their row kind is
## `SettingDropDown`, whose every bind -- `BindTo`, `BindToEnum`,
## `BindDropDownToSetting`, `UpdateDropDownValue` -- is GENERIC and therefore
## has no code entry offline. The same is true of all three
## `SettingSelectSlider.BindIndexTo` overloads. There is no honest way to build
## one today, so NO row is built for them: they are counted, named in the log,
## and named in the on-screen banner. A dropdown faked out of a toggle would
## render, look right, and do nothing, which is the single defect this
## repository has produced most often.
##
## WHAT IS RENDERED, AND WHAT IT IS NOT
## ------------------------------------
## 4 boolean settings as real `SettingToggle` rows, 23 numeric settings as real
## `SettingFloatSlider` rows whose inner `NumberSlider` is given the schema's
## own range and the schema's own DEFAULT via `Show(min,max,format)`
## @0x16B4EA0 and `SetCurrentValue(float)` @0x16B5300.
##
## They are NOT BOUND, and the banner says so on screen. Binding needs a
## `Bsg.GameSettings.GameSetting<T>`: `SettingToggle.BindTo(GameSetting<bool>)`
## @0x16FD0D0 and `SettingFloatSlider.BindTo(GameSetting<float>,...)`
## @0x16FB810 both have real unique RVAs, but `GameSetting`1` is an
## INSTANTIATED GENERIC whose layout is not reachable offline (every one of the
## 33,464 `Il2CppGenericClass` entries has a null `cached_class`) and
## constructing one is a GAP. `SetChangeAction(Action)` @0x16FAFC0 is the
## no-GameSetting alternative and IS in the target table -- it needs a managed
## `Action` delegate, which needs type injection, which is PLAUSIBLE and
## UNPROVEN on this build. It is called with a real delegate or not at all,
## never with NULL.
##
## The values shown are the DECLARED DEFAULTS from `mods/graphics`' own schema,
## not the player's saved config. The live-value path is the
## `/aowlspt/settings/<guid>` fetch in `modsettingsrender.nim`, gated on
## `modSettingsRender`, which crashes the client at character-select. Another
## agent owns that crash. The banner states which of the two the numbers are,
## because printing a default and letting it read as "your setting" is a
## confident wrong answer.
##
## OWNERSHIP -- CHOSEN DELIBERATELY, NOT BY DEFAULT
## ------------------------------------------------
## `SettingsTab._createdControls` @0x88 is the list `CleanupCreatedControls`
## @0x171BE50 destroys on close, and the map is explicit that a row which is
## not in it survives and duplicates. We do NOT append to it: it is a
## `List<SettingControl>`, an instantiated generic whose layout is exactly the
## thing that is not reachable offline, and a raw write to a guessed
## `_items`/`_size` pair is a fabricated offset into a live collection the game
## then iterates. Instead this file OWNS its rows and destroys them itself
## through `Object::Destroy` (`nuDestroy`), on the same tear-down hook it
## already had. Stated so the next reader does not "fix" it by writing the
## list.
##
## SAFETY. Flag-gated `settingsPostFxRows`, default OFF, and additionally inert
## unless `nativeUiKit` is on. Built ONCE, lazily, the first time the PostFX
## panel is actually up. No per-frame work and no per-frame allocation: after
## the build the tick is one boolean. Self-disables after `PfxMaxFaults`. Every
## iteration is capped. No guard is opened here -- this is called from inside
## `modsBody`'s single `aowl_p_p_seh`, and `aowl_p_p_seh` is NOT re-entrant.
##
## LIVE STATUS, stated because it is the deliverable: NOTHING in this file has
## been observed in a running client. The client is unbootable this pass for an
## unrelated reason. Every offset and every RVA here is METADATA-DERIVED and
## byte-verified offline; none of it is behavioural proof.
## ===========================================================================

const PfxMaxFaults = 4
const PfxMaxRows = 64              ## rule 4; the catalogue is 29
const PfxMaxHandles = 48

## PostFXSettingsTab field offsets. MEASURED, never guessed --
## `tools/il2cpp_resolve.py ... fields EFT.UI.Settings.PostFXSettingsTab`,
## System.String self-check passed. Every one is a serialized Unity reference
## and therefore NULL-CAPABLE: read through `nuOk`, never dereferenced blind.
const PfxOffSettingsRoot   = 0xa0'i32   ## _settingsRoot : RectTransform
const PfxOffSliderTemplate = 0xb0'i32   ## _selectFloatSliderTemplate
const PfxOffDropTemplate   = 0xb8'i32   ## _dropDownTemplate  (declined; see above)
const PfxOffToggleTemplate = 0xc0'i32   ## _toggleLeftTemplate

## ---- THE GRAY-OUT, and how the game itself does it ----------------------
##
## MEASURED OFFLINE, and the whole point is that NONE of this was invented:
##
##   `PostFXSettingsTab._postFxBlockController@0xd0 : BlockBySettingController<bool>`
##   (`fldoff.py fields EFT.UI.Settings.PostFXSettingsTab`), built by
##   `PostFXSettingsTab::CreateBlockers()` @0x1719540, whose base
##   `EFT.UI.BlockControllerBase` holds `Blockers : List<UiElementBlocker>@0x20`.
##
##   `EFT.UI.UiElementBlocker::SetBlock(bool, string, string)` @0x16bf9d0
##   (UNIQUE) is `_isBlocking@0x48 = block` and then a tail-jump to
##   `StartBlock` @0x16bfa00 / `RemoveBlock` @0x16bfd40.
##
##   `StartBlock` @0x16bfa00+0x125 calls
##   `MyExtensions::SetUnlockStatus(CanvasGroup group, bool value, bool
##   setRaycast)` @0x1d20100 (UNIQUE) on `UiElementBlocker.Group@0x20`.
##
##   `SetUnlockStatus` @0x1d20100, disassembled end to end, is EXACTLY three
##   calls on the CanvasGroup and nothing else:
##       set_alpha(value ? [rip 0x65b6000] : [rip 0x65b5a5c])
##       set_interactable(value)
##       if (setRaycast) set_blocksRaycasts(value)
##   and the two float literals read `00 00 80 3F` and `9A 99 99 3E` --
##   1.0f and 0.3f (`il2cpp_resolve.py bytes 0x65b6000 / 0x65b5a5c`).
##
## SO THE MECHANISM IS: CanvasGroup alpha 1.0 / 0.3, interactable, blocks-
## raycasts. Mirrored below through the three setters nativeui already
## byte-verifies, in that order.
##
## AND THE CANVASGROUP ALREADY EXISTS -- nothing is AddComponent'd. Every
## `EFT.UI.Settings.SettingControl` declares `_blocker : UiElementBlocker@0x88`
## and `_elementBlocker@0xa0` (same `fldoff.py` run), so each of OUR prefab
## instances brought its own blocker, and each blocker its own serialized
## `Group : CanvasGroup@0x20`. Per-row is also STRICTLY BETTER than a group
## over the container here: our rows share `_settingsRoot` with the game's own
## 9 stock rows, and a CanvasGroup on that parent would gray those out too.
##
## WHAT THIS CANNOT ASSERT, stated because the obvious check is the wrong one:
## `Selectable.interactable` is `m_Interactable`, a field the CanvasGroup does
## NOT write -- CanvasGroup participates in `Selectable.IsInteractable()` at
## evaluation time instead. So a verdict reading `Selectable::get_interactable`
## would read `true` on a correctly grayed row. The finished state that IS
## readable, and that the verdict below reads, is the CanvasGroup's own alpha
## and interactable, through the getters and not through what we wrote.
const PfxOffCtrlBlocker  = 0x88'i32  ## SettingControl._blocker : UiElementBlocker
const PfxOffCtrlBlocker2 = 0xa0'i32  ## SettingControl._elementBlocker (fallback)
const PfxOffBlockerGroup = 0x20'i32  ## UiElementBlocker.Group : CanvasGroup
const PfxAlphaFree    = 1.0'f32      ## MEASURED [.rdata 0x65b6000]
const PfxAlphaBlocked = 0.3'f32      ## MEASURED [.rdata 0x65b5a5c]
const PfxEnableKey    = "enabled"    ## the catalogue key that gates the rest

var gPfxOn = false                 ## `settingsPostFxRows` -- read once at boot
var gPfxOff = false                ## self-disabled
var gPfxBuilt = false
var gPfxTried = 0
var gPfxFaults = 0
var gPfxVerdictSaid = false

## OUR ROWS. `gPfxRowGo` is the GameObject we destroy; `gPfxRowSlider` is the
## inner `NumberSlider` for a float row (nil for a toggle row) and is what the
## verdict READS BACK -- never the value we passed in.
var gPfxBanner: NuElem
var gPfxHaveBanner = false
var gPfxRowGo: seq[Il2CppPtr] = @[]
var gPfxRowSlider: seq[Il2CppPtr] = @[]
var gPfxRowWant: seq[float32] = @[]
var gPfxRowName: seq[string] = @[]
var gPfxDeclined: seq[string] = @[]
## The `SettingControl` COMPONENT of each row, parallel to `gPfxRowGo`. Carried
## because the gray-out needs `_blocker@0x88`, which is declared on the control
## and is not reachable from the GameObject without a GetComponent per row per
## application.
var gPfxRowCtrl: seq[Il2CppPtr] = @[]

## ---- the scroll graft (defect 2) ---------------------------------------
var gPfxScrollInit = false
var gPfxScrollOn = false           ## `settingsPostFxScroll`, DEFAULT OFF
var gPfxScrollGo: Il2CppPtr = nil  ## the cloned SettingsList we own
var gPfxScrollHostT: Il2CppPtr = nil     ## ...its transform (the scroll host)
var gPfxScrollContentT: Il2CppPtr = nil  ## the clone's Content -- the new root
var gPfxScrollBarT: Il2CppPtr = nil      ## the clone's Scrollbar
var gPfxScrollSaid = false
## The AUTHORED `SettingsPanel`: the object and the rect it had BEFORE we
## touched anything. The rect is what the scroll region must reproduce, and
## the object is what `_settingsRoot@0xa0` is put back to on tear-down -- the
## tab holds that field, and leaving it pointing at a clone we destroyed is a
## dangling managed reference in the game's own object.
var gPfxOrigRootT: Il2CppPtr = nil
var gPfxOrigGeom = nuNoGeom()
## THE PANELS, RESOLVED FROM THE TAB ITSELF rather than borrowed from
## modstab's `gGfxPostT` / `gGfxPanelT`. Those two are populated by the SUBTAB
## feature's tick, so the graft depended on another feature having run first
## -- and when it had not, the graft returned SILENTLY (postfxrows.nim:633-634
## on the deployed build a7386d1f: two bare `return false` lines with no
## refusal between them). The whole run then produced no 'SCROLL GRAFT' line
## at all and only the verdict's INCONCLUSIVE, which read as "there is no
## ScrollRect" when the truth was "the graft never ran".
var gPfxPostPanelT: Il2CppPtr = nil
var gPfxGfxPanelT: Il2CppPtr = nil
## THE GRAFT'S OWN OUTCOME, so the verdict can tell 'declined, and why' apart
## from 'applied, but the result is wrong'. Both printed the same INCONCLUSIVE
## before, which is the same class of defect as the checks 9b is about: one
## sentence covering two different causes with different fixes.
## Frames between the graft and judging it. A LayoutGroup rebuild lands in
## `willRenderCanvases`, and the ContentSizeFitter's height follows the
## rebuild, so two frames is the minimum honest delay and three is cheap.
const PfxScrollJudgeDelay = 3
var gPfxScrollJudge = 0
var gPfxScrollJudgeRoot: Il2CppPtr = nil
var gPfxGraftTried = false
var gPfxGraftOk = false
var gPfxGraftWhy = ""

## ---- the gray-out (defect 3) -------------------------------------------
var gPfxGrayInit = false
var gPfxGrayOn = false             ## `settingsPostFxGrayOut`, DEFAULT OFF
var gPfxGrayApplied = false        ## the state currently written to the rows
var gPfxGrayHave = false           ## ...and whether it has ever been written
var gPfxGraySaid = false
## THE TWO TOGGLES THE ROWS FOLLOW. `gPfxStockTog` is the GAME'S own 'Enable
## PostFX' in `EnablePanel` -- the one the user actually unchecked while our
## 26 rows stayed live -- and `gPfxOwnTog` is our own 'Enable post-process'
## row. The rows are free only when BOTH are on.
var gPfxStockTog: Il2CppPtr = nil
var gPfxOwnTog: Il2CppPtr = nil
var gPfxStockOn = false
var gPfxOwnOn = false
## WHICH STATES WERE ACTUALLY OBSERVED. A PASS may only ever be claimed for a
## state the run really reached; these are what let the summary say so out
## loud instead of implying both were checked.
var gPfxSeenFree = false
var gPfxSeenBlocked = false
## THE STOCK DONOR GEOMETRY, read live and captured once per build. See
## `pfxDonorGeom`. `gPfxParentW` is the row parent's own rect width, and it is
## what the finished-state check measures every row against -- a row wider than
## its container is the reported defect, stated as a number.
var gPfxGeom = nuNoGeom()
var gPfxHaveGeom = false
var gPfxParentW = 0.0'f32

type
  PfxKind = enum
    pkToggle,      ## boolSetting   -> SettingToggle prefab
    pkSlider,      ## floatSetting  -> SettingFloatSlider prefab
    pkChoice       ## enumSetting   -> SettingDropDown: DECLINED, see header

  PfxRow = object
    kind*: PfxKind
    label*: string
    key*: string
    ## PRESET-OWNED. Derived from `mods/graphics`' `loadConfig`, which calls
    ## `applyPreset` and RETURNS whenever `preset != "custom"`, so with the
    ## deployed preset every look setting below that line is read and then
    ## discarded. Marked on screen so a player cannot conclude a knob is broken
    ## when it is in fact owned.
    presetOwned*: bool
    ## Range and DECLARED DEFAULT, transcribed from `mods/graphics/graphics.nim
    ## :schema()`. Meaningless for `pkToggle` / `pkChoice`.
    lo*, hi*, def*: float32

proc pfxF(label, key: string; owned: bool; lo, hi, def: float32): PfxRow =
  PfxRow(kind: pkSlider, label: label, key: key, presetOwned: owned,
         lo: lo, hi: hi, def: def)

proc pfxB(label, key: string; owned: bool): PfxRow =
  PfxRow(kind: pkToggle, label: label, key: key, presetOwned: owned,
         lo: 0.0'f32, hi: 0.0'f32, def: 0.0'f32)

proc pfxE(label, key: string): PfxRow =
  PfxRow(kind: pkChoice, label: label, key: key, presetOwned: false,
         lo: 0.0'f32, hi: 0.0'f32, def: 0.0'f32)

proc pfxCatalogue(): seq[PfxRow] =
  ## The 29 settings `mods/graphics/graphics.nim:schema()` declares, with the
  ## kind, range and default it declares for each. A STATIC MIRROR -- the
  ## schema fetch that would make it live is blocked (see the header) -- so it
  ## will drift if the mod's schema changes.
  ##
  ## Ordered by the schema's own category, and WITHOUT category headers: a
  ## settings tab has no header prefab, and inventing one out of a label would
  ## be exactly the from-scratch construction this change exists to remove.
  @[pfxE("Preset", "preset"),
    pfxB("Enable post-process", "enabled", false),
    pfxB("Raid only (menu stays stock)", "raidOnly", false),
    pfxE("Tonemapper", "tonemapper"),
    pfxF("Tonemap strength", "tonemapStrength", true, 0.0'f32, 1.0'f32, 0.85'f32),
    pfxF("Exposure (EV)", "exposure", true, -3.0'f32, 3.0'f32, 0.0'f32),
    pfxF("Contrast", "contrast", true, 0.5'f32, 1.8'f32, 1.05'f32),
    pfxF("Saturation", "saturation", true, 0.0'f32, 2.0'f32, 1.05'f32),
    pfxF("Vibrance", "vibrance", true, 0.0'f32, 1.0'f32, 0.35'f32),
    pfxF("Shadow detail (toe lift)", "shadowDetail", true, 0.0'f32, 1.0'f32, 0.35'f32),
    pfxF("Temperature", "temperature", true, -1.0'f32, 1.0'f32, 0.0'f32),
    pfxF("Tint", "tint", true, -1.0'f32, 1.0'f32, 0.0'f32),
    pfxF("Lift (shadows)", "lift", true, -0.2'f32, 0.2'f32, 0.0'f32),
    pfxF("Gamma (midtones)", "gamma", true, 0.5'f32, 1.8'f32, 1.0'f32),
    pfxF("Gain (highlights)", "gain", true, 0.5'f32, 1.8'f32, 1.0'f32),
    pfxF("Shadow lift (additive)", "shadows", true, -0.2'f32, 0.2'f32, 0.0'f32),
    pfxF("Highlight roll-off", "highlights", true, 0.5'f32, 2.0'f32, 1.1'f32),
    pfxF("Sharpening (CAS)", "sharpness", true, 0.0'f32, 1.0'f32, 0.35'f32),
    pfxB("Bloom", "bloom", true),
    pfxF("Bloom strength", "bloomStrength", true, 0.0'f32, 2.0'f32, 0.35'f32),
    pfxF("Bloom threshold", "bloomThreshold", true, 0.0'f32, 1.0'f32, 0.70'f32),
    pfxF("Vignette", "vignette", true, 0.0'f32, 1.0'f32, 0.18'f32),
    pfxF("Vignette radius", "vignetteRadius", true, 0.5'f32, 1.5'f32, 1.0'f32),
    pfxF("Clarity (local contrast)", "clarity", true, 0.0'f32, 1.0'f32, 0.30'f32),
    pfxF("Film grain", "grain", true, 0.0'f32, 1.0'f32, 0.18'f32),
    pfxF("Grain size (px)", "grainSize", true, 1.0'f32, 4.0'f32, 1.5'f32),
    pfxF("Output dither (LSB)", "dither", true, 0.0'f32, 2.0'f32, 1.0'f32),
    pfxF("Chromatic aberration", "chroma", true, 0.0'f32, 1.0'f32, 0.0'f32),
    pfxB("Red-tint diagnostic", "diag", false)]

proc pfxNoteFault(what: string) =
  inc gPfxFaults
  warn "postfx rows: " & what & " (fault " & $gPfxFaults & " of " &
       $PfxMaxFaults & ")"
  if gPfxFaults >= PfxMaxFaults:
    gPfxOff = true
    warn "postfx rows: fault ceiling reached; this feature is OFF for the rest " &
         "of the session. Nothing it built is left behind -- the rows it owns " &
         "are destroyed on the next tear-down, and the PostFX panel goes back " &
         "to exactly the empty stock panel it was."

proc pfxDestroyAll(): int =
  ## Tear our rows down. These are prefab INSTANCES we own (see the OWNERSHIP
  ## note in the header: they are deliberately NOT registered in the tab's
  ## `_createdControls`, so the game will not do it for us). `nuDestroy` asks
  ## Unity's own `op_Implicit` liveness first, so a second call cannot
  ## double-destroy.
  result = 0
  var i = 0
  while i < gPfxRowGo.len and i < PfxMaxHandles:
    if nuDestroy(gPfxRowGo[i]):
      result = result + 1
    i = i + 1
  if gPfxHaveBanner and nuDestroy(gPfxBanner):
    result = result + 1
  gPfxHaveBanner = false
  gPfxRowGo = @[]
  gPfxRowSlider = @[]
  gPfxRowWant = @[]
  gPfxRowName = @[]
  gPfxRowCtrl = @[]
  # The value binding's handles name the very rows just destroyed. Dropping
  # them here is also the DISCARD half of the revert: anything staged and not
  # saved is thrown away rather than written. See `sbdSweep`.
  sbdSweep()
  gPfxGrayHave = false
  gPfxGrayApplied = false
  gPfxOwnTog = nil
  gPfxBuilt = false

proc pfxDonorTmp(): Il2CppPtr =
  ## A LIVE `TextMeshProUGUI` whose font asset and materials `nuLabel` copies
  ## in for the BANNER (the rows themselves need no donor -- a prefab instance
  ## brings its own font). Nothing is ever written to the donor.
  result = nil
  if gGfxPostT != nil and duOk(gGfxPostT, 0x20'i32):
    result = modsFindTmp(gGfxPostT, 6)
  if result == nil and gGfxPanelT != nil and duOk(gGfxPanelT, 0x20'i32):
    result = modsFindTmp(gGfxPanelT, 6)
  if result != nil and not iUnityAlive(result):
    result = nil

proc pfxTab(): Il2CppPtr =
  ## The live `PostFXSettingsTab` COMPONENT, reached by WALKING from a verified
  ## live object -- `gGfxPostT`, the "PostFX Settings" panel transform that the
  ## subtab feature already located and validated -- and never by an offset
  ## that can read null. `modsComponent` refuses a GameObject receiver up
  ## front, which is the fault this walk would otherwise take.
  result = nil
  if gGfxPostT == nil or not duOk(gGfxPostT, 0x20'i32): return
  if not iUnityAlive(gGfxPostT): return
  result = modsComponent(gGfxPostT, "PostFXSettingsTab")
  if result != nil and not nuOk(result, PfxOffToggleTemplate + 8'i32):
    result = nil

## GraphicsSettingsTab._settingsContainer @0x98 : Transform. MEASURED
## (`il2cpp_resolve.py ... fields EFT.UI.Settings.GraphicsSettingsTab`), and
## NULL-CAPABLE like every serialized reference here.
const PfxOffGfxContainer = 0x98'i32

proc pfxDonorGeom(g: var NuGeom; parentW: var float32): bool =
  ## MEASURE A STOCK ROW AND COPY IT. Do not invent a width.
  ##
  ## THE DEFECT THIS EXISTS FOR, observed live on the deployed build: the
  ## prefab rows render, and the two kinds do not agree. The `SettingToggle`
  ## rows sat near the horizontal centre; every `SettingFloatSlider` row put
  ## its label far left and ran its control column off the RIGHT EDGE of the
  ## panel, clipped. Nothing was writing the fresh row's geometry, so each kind
  ## kept whatever its own prefab shipped with -- and the PostFX tab's two
  ## templates were authored against different container widths.
  ##
  ## WHY A HARDCODED WIDTH IS NOT ACCEPTABLE, specifically: this user runs
  ## Windows at 1.5x display scaling, so a pixel constant measured on one
  ## machine is a different fraction of the panel on the next. The donor is
  ## read LIVE, so it is resolution-independent by construction.
  ##
  ## WHERE THE DONOR COMES FROM: the GRAPHICS SETTINGS panel, whose stock rows
  ## the game itself built and which lays out correctly on screen right now.
  ## The PostFX panel has no stock rows to borrow from -- its tab was folded
  ## away, so its `CreateControls` never ran, which is the whole reason this
  ## feature exists at all.
  ##
  ## THE DONOR IS CHOSEN BY CONSENSUS, NOT BY POSITION, and that is the part
  ## that can fail. Taking "child 0" would silently take a header, a spacer or
  ## our own cloned subtab strip. Instead every candidate is measured and the
  ## width that AT LEAST TWO stock rows agree on wins. If no two agree, this
  ## refuses and says so rather than copying one arbitrary rectangle.
  result = false
  parentW = 0.0'f32
  if gGfxPanelT == nil or not duOk(gGfxPanelT, 0x20'i32): return
  if not iUnityAlive(gGfxPanelT): return
  let gfxTab = modsComponent(gGfxPanelT, "GraphicsSettingsTab")
  if not nuOk(gfxTab, PfxOffGfxContainer + 8'i32):
    warn "postfx rows: the GraphicsSettingsTab component could not be reached " &
         "from the live Graphics Settings panel, so there is no stock row to " &
         "measure. Rows keep the PREFAB's own geometry -- which is the defect " &
         "being fixed -- and the width check in the verdict will say so."
    return
  let cont = cNuGetRef(gfxTab, PfxOffGfxContainer)
  if not nuOk(cont, 0x10'i32) or not nuAlive(cont):
    warn "postfx rows: GraphicsSettingsTab._settingsContainer @0x98 read null " &
         "or not a live object; there is no stock row to measure."
    return
  var n = 0
  if not iChildCount(cont, n) or n <= 0:
    warn "postfx rows: the stock Graphics row container reports " & $n &
         " child(ren); nothing to measure."
    return
  const PfxMaxDonors = 24
  var cw: seq[float32] = @[]
  var crt: seq[Il2CppPtr] = @[]
  var skippedClones = 0
  var i = 0
  while i < n and i < PfxMaxDonors:
    let c = iChildAt(cont, i)
    i = i + 1
    if c == nil or not duOk(c, 0x20'i32): continue
    if not iUnityAlive(c): continue
    # OUR OWN CLONED SUBTAB STRIP LIVES IN THIS CONTAINER. Unity names every
    # Instantiate result "<donor>(Clone)", and the game's own rows never carry
    # that suffix, so this is an exact discriminator, not a heuristic.
    if iObjName(c).contains("(Clone)"):
      skippedClones = skippedClones + 1
      continue
    let gg = nuReadGeom(c)
    if not gg.ok: continue
    # A ROW, not a container and not a hairline. Bounded on BOTH sides so a
    # full-height scroll viewport cannot be mistaken for a settings row.
    if gg.rectH < 8.0'f32 or gg.rectH > 200.0'f32: continue
    if gg.rectW < 100.0'f32: continue
    cw.add gg.rectW
    crt.add c
  if cw.len < 2:
    warn "postfx rows: only " & $cw.len & " stock Graphics row(s) could be " &
         "measured (" & $skippedClones & " skipped as our own clones, out of " &
         $n & " children). At least TWO must agree on a width before one is " &
         "trusted, so NO geometry is copied. Rows keep the prefab's own width " &
         "and the verdict below reports that as a number."
    return
  # CONSENSUS. The width the most rows share wins; ties go to the first.
  var bestIdx = -1
  var bestCount = 0
  var ia = 0
  while ia < cw.len and ia < PfxMaxDonors:
    var cnt = 0
    var ib = 0
    while ib < cw.len and ib < PfxMaxDonors:
      let d = cw[ia] - cw[ib]
      if d < 1.0'f32 and d > -1.0'f32: cnt = cnt + 1
      ib = ib + 1
    if cnt > bestCount:
      bestCount = cnt
      bestIdx = ia
    ia = ia + 1
  if bestIdx < 0 or bestCount < 2:
    warn "postfx rows: " & $cw.len & " stock row(s) were measured and NO TWO " &
         "agree on a width to within 1px, so none is a trustworthy donor. No " &
         "geometry is copied."
    return
  let donor = nuReadGeom(crt[bestIdx])
  if not donor.ok: return
  let pg = nuReadGeom(cont)
  if pg.ok: parentW = pg.rectW
  g = donor
  okLog "postfx rows: stock donor row MEASURED LIVE -- " & $bestCount & " of " &
        $cw.len & " Graphics Settings rows agree on this width, so it is the " &
        "game's own row geometry and not one we invented: " &
        nuGeomNote(donor) & ". Their container is " & nuF(parentW) & " wide."
  result = true

proc pfxMakeRow(prefab, parent: Il2CppPtr; r: PfxRow; idx: int32;
                sliderOut: var Il2CppPtr; ctrlOut: var Il2CppPtr): Il2CppPtr =
  ## ONE row, the game's own way: Instantiate the prefab under the row parent,
  ## then the fluent chain. Returns the row's GameObject (what we destroy), or
  ## nil, and never leaves a half-built object parented in.
  result = nil
  sliderOut = nil
  ctrlOut = nil
  let row = nuInstantiateUnder(prefab, parent)
  if row == nil: return
  let go = nuGameObjectOf(row)
  if go == nil:
    # An instantiated component whose GameObject cannot be reached is not
    # something to leave in the tree: we could neither activate nor destroy it.
    warn "postfx rows: the instantiated row for '" & r.key & "' has no " &
         "reachable GameObject, so it could be neither shown nor torn down. " &
         "Refusing this row."
    return
  # The caption. `SetText` is the game's own setter and takes a LOCALIZATION
  # KEY; an aowlspt setting has no BSG locale entry, so the literal is passed
  # and renders as itself. A raw `m_text` store would be clobbered by
  # `LocalizedText`, which is why the setter is called rather than the field
  # written.
  # VANILLA CAPTION, NO MARKER. The `"* "` prefix that used to go here marked
  # a row as owned by the active Preset -- a real fact, encoded in a way that
  # makes our page look unlike every other page in this screen. No stock
  # settings row carries a sigil, and the user asked for vanilla. The fact is
  # not lost: it goes to the log below, where it costs the player nothing.
  let cap = r.label
  if not nuRowSetText(row, cap):
    warn "postfx rows: SetText refused for '" & r.key & "'; the row would " &
         "carry the PREFAB's own caption, which reads as a stock setting " &
         "that is not there. Refusing this row."
    discard nuDestroy(go)
    return
  # The GameObject name is what the live inspector's `find` searches on, and it
  # is how a later session tells our row from a stock one without guessing.
  discard nuRowSetName(row, "aowlspt-pfx-" & r.key)
  discard nuRowSetSiblingIndex(row, idx)
  # THE GEOMETRY. Horizontal only -- the parent's LayoutGroup owns Y and
  # height, and fighting it would lose on the next relayout. Applied to the
  # ROW's own RectTransform, which for a UI object is what get_transform
  # returns. A refusal here is not fatal: the row is still a real native
  # control, merely at the prefab's own width, and the verdict measures that
  # and reports it as a number rather than hiding it.
  if gPfxHaveGeom:
    let rt = nuTransformOf(go)
    if rt == nil or not nuApplyGeomX(rt, gPfxGeom):
      warn "postfx rows: the stock row geometry could not be applied to '" &
           r.key & "'; that row keeps the PREFAB's own width and may not line " &
           "up with the others."
  if r.kind == pkSlider:
    let sl = nuRowSlider(row)
    if sl == nil:
      warn "postfx rows: '" & r.key & "' instantiated but its inner " &
           "NumberSlider (SettingFloatSlider.Slider @0xa8) read null, so the " &
           "row would show a slider with no range and no value. Refusing it."
      discard nuDestroy(go)
      return
    if not nuSliderShow(sl, r.lo, r.hi, "F2"):
      warn "postfx rows: NumberSlider::Show refused for '" & r.key &
           "' (range " & nuF(r.lo) & ".." & nuF(r.hi) & "). Refusing this row."
      discard nuDestroy(go)
      return
    discard nuSliderSetValue(sl, r.def)
    sliderOut = sl
  discard nuSetActive(go, true)
  # The `SettingControl` component itself -- what `Instantiate` returned, so
  # no GetComponent and no by-name lookup is involved. The gray-out reads
  # `_blocker@0x88` off exactly this pointer.
  ctrlOut = row
  result = go

proc pfxRetireKids(parentT: Il2CppPtr): int =
  ## SetActive(false) on every child, capped. NEVER Destroy: `Object.Destroy`
  ## is deferred to end of frame, so a destroyed node is still walkable, still
  ## counted and still readable for the rest of the frame -- a verdict that ran
  ## in that window would report a tree that no longer exists (the map's
  ## Destroy trap).
  result = 0
  var n = 0
  if parentT == nil or not iChildCount(parentT, n): return
  var i = 0
  while i < n and i < 64:
    let c = iChildAt(parentT, i)
    if c != nil and duOk(c, 0x20'i32):
      let go = iGameObjectOf(c)
      if go != nil and modsSetActive(go, false): result = result + 1
    i = i + 1

proc pfxMoveKids(fromT, toT: Il2CppPtr): int =
  ## Move every child of `fromT` under `toT`, LAST FIRST. Walking forwards is
  ## the bug: `SetParent` removes the child from the source list, so indices
  ## shift under the loop and every second child is skipped. Backwards, the
  ## indices below the cursor are untouched.
  result = 0
  var n = 0
  if fromT == nil or toT == nil or not iChildCount(fromT, n): return
  var i = n - 1
  var steps = 0
  while i >= 0 and steps < 64:
    let c = iChildAt(fromT, i)
    if c != nil and duOk(c, 0x20'i32):
      if nuParentTransform(c, toT, false): result = result + 1
    i = i - 1
    steps = steps + 1

proc pfxGraftRefuse(why: string) =
  ## EVERY exit from the graft that is not a success comes through here. There
  ## is no silent `return` left in `pfxScrollify`, and that is the point: the
  ## deployed build had exactly two, they fired, and the only trace was a
  ## verdict line about a missing ScrollRect that had nothing to do with the
  ## cause.
  gPfxGraftWhy = why
  pfxNoteFault("SCROLL GRAFT DECLINED -- " & why)

proc pfxResolvePanels(tab: Il2CppPtr; postT, gfxT: var Il2CppPtr): bool =
  ## BOTH PANELS, WALKED FROM THE TAB THE CALLER ALREADY VALIDATED. Nothing
  ## here reads `gGfxPostT` / `gGfxPanelT`: those belong to the subtab feature
  ## and are nil until ITS tick has run, so depending on them made this graft
  ## silently ordering-dependent on a different feature.
  ##
  ## The walk, with every hop validated and NOTHING assumed about which node
  ## the tab component sits on -- the tab's own GameObject is checked BY NAME
  ## and, only if that is not the panel, its parent is. Guessing either way
  ## round would produce a plausible transform and a wrong donor.
  postT = nil
  gfxT = nil
  let go = nuGameObjectOf(tab)
  if go == nil:
    pfxGraftRefuse("the PostFXSettingsTab component has no reachable " &
                   "GameObject, so neither panel can be walked to. Nothing " &
                   "was cloned.")
    return false
  let tt = modsTransformOf(go)
  if tt == nil or not duOk(tt, 0x20'i32) or not iUnityAlive(tt):
    pfxGraftRefuse("the PostFXSettingsTab's own Transform could not be read, " &
                   "so the walk to 'PostFX Settings' cannot start. Nothing " &
                   "was cloned.")
    return false
  var pp = tt
  if iObjName(tt) != "PostFX Settings":
    let par = modsParentOf(tt)
    if par != nil and iObjName(par) == "PostFX Settings":
      pp = par
    else:
      pfxGraftRefuse("neither the tab's own node ('" & iObjName(tt) &
                     "') nor its parent ('" & iObjName(par) &
                     "') is named 'PostFX Settings', so the walk landed " &
                     "somewhere this file does not recognise. Refusing " &
                     "rather than grafting a scroll host onto an unknown node.")
      return false
  let screenT = modsParentOf(pp)
  if screenT == nil or not duOk(screenT, 0x20'i32):
    pfxGraftRefuse("the SettingsScreen transform (the parent of 'PostFX " &
                   "Settings') could not be reached, so the Graphics donor " &
                   "panel cannot be found. Nothing was cloned.")
    return false
  let gp = modsChildNamed(screenT, "Graphics Settings")
  if gp == nil or not duOk(gp, 0x20'i32) or not iUnityAlive(gp):
    pfxGraftRefuse("'Graphics Settings' is not a child of the SettingsScreen " &
                   "we walked to from the tab, so there is no donor to clone " &
                   "a ScrollRect from. Nothing was cloned.")
    return false
  postT = pp
  gfxT = gp
  gPfxPostPanelT = pp
  gPfxGfxPanelT = gp
  return true

proc pfxScrollify(tab, rowParent: Il2CppPtr; newRootOut: var Il2CppPtr): bool =
  ## DEFECT 2, SECOND ATTEMPT -- and the first one is worth stating, because
  ## the verdict that blessed it is the exact failure 9b is about.
  ##
  ## WHAT THE FIRST ATTEMPT DID: cloned the Graphics page's `SettingsList`,
  ## moved `SettingsPanel` (the row parent) into the clone's Viewport, and
  ## pointed `ScrollRect.m_Content@0x20` at it. The verdict then compared
  ## `m_Content` against the row parent and two heights -- and passed.
  ##
  ## WHAT WAS ACTUALLY ON SCREEN (inspector, 2026-09-03 12:16):
  ##   * the clone sat top-LEFT of the 930-wide panel: anchors (0,1)-(0,1),
  ##     pivot (0,1), anchoredPosition (0,-59), sizeDelta (850,726) -- an inset
  ##     box, not the space `SettingsPanel` used to occupy;
  ##   * its Viewport resolved to 750x686 while `SettingsPanel` inside it kept
  ##     a FIXED 850x726 with pivot (0.5,0.5) -- 100 px WIDER than the viewport
  ##     that was supposed to clip it, with nothing driving its height;
  ##   * the donor `Content` was still an ACTIVE 1490 px tall object sitting in
  ##     the same Viewport, so the Viewport had TWO children.
  ## Every one of those is a geometry fact the verdict never looked at.
  ##
  ## SO THE SHAPE IS FIXED BY CONSTRUCTION, not by adjustment:
  ##
  ##   1. `SettingsPanel`'s AUTHORED geometry is captured BEFORE anything is
  ##      touched, and given verbatim to the CLONE ROOT. The scroll region then
  ##      occupies precisely the space the authored panel occupied -- no
  ##      constant is involved and it is resolution-independent.
  ##   2. The clone's Viewport is STRETCHED to the clone root (anchors
  ##      (0,0)-(1,1), sizeDelta (0,0)), so viewport rect == the authored
  ##      SettingsPanel rect. The donor's own centred 750-wide viewport is
  ##      exactly the inset the user saw and is not kept.
  ##   3. THE CONTENT IS THE CLONE'S OWN `Content`, not `SettingsPanel`. This
  ##      is the part that removes a whole class of defect instead of patching
  ##      it: the donor Content already carries the LayoutGroup and
  ##      ContentSizeFitter that DRIVE its height, already has top-stretch
  ##      anchors (0,1)-(1,1) with pivot (0.5,1), and already is what the
  ##      cloned ScrollRect names. Nothing has to be added, and `nuAdd` has no
  ##      attested ContentSizeFitter kind, so adding one was never available.
  ##      The rows MOVE into it and `_settingsRoot@0xa0` is repointed at it, so
  ##      the game's own future stock rows land there too.
  ##   4. The donor's 33 rows are retired FIRST (SetActive false), so the
  ##      ContentSizeFitter recomputes from our rows alone -- a layout group
  ##      skips inactive children. The emptied `SettingsPanel` is retired whole,
  ##      so the Viewport ends with exactly ONE active child.
  result = false
  newRootOut = nil
  gPfxGraftTried = true
  if gPfxScrollGo != nil: return true
  # THE TWO SILENT RETURNS THAT USED TO BE HERE WERE THE WHOLE BUG on
  # a7386d1f: `if gGfxPanelT == nil or gGfxPostT == nil: return false` and its
  # liveness twin, both bare. One of them fired on every run and said nothing.
  # Both panels now come from the tab, and every exit below announces itself.
  var postT: Il2CppPtr = nil
  var gfxT: Il2CppPtr = nil
  if not pfxResolvePanels(tab, postT, gfxT): return
  # (1) THE AUTHORED RECT, read before we write anything anywhere. Without it
  # there is nothing to size the scroll region to and nothing to restore, so
  # this is a refusal, not a fallback.
  let og = nuReadGeom(rowParent)
  if not og.ok:
    pfxGraftRefuse("the authored geometry of _settingsRoot (the SettingsPanel " &
                 "the scroll region must exactly replace) could not be read, " &
                 "so there is no rect to size the clone to. Nothing was " &
                 "cloned and the page is untouched.")
    return
  var donorT = modsChildNamed(modsChildNamed(gfxT, "Other Settings"),
                              "SettingsList")
  if donorT == nil:
    donorT = modsFindNamed(gfxT, "SettingsList", 4)
  if donorT == nil or not duOk(donorT, 0x20'i32) or not iUnityAlive(donorT):
    pfxGraftRefuse("the Graphics page's 'SettingsList' (the ScrollRect donor) " &
                 "could not be reached by walking 'Graphics Settings' -> " &
                 "'Other Settings' -> 'SettingsList', nor found by name " &
                 "within 4 levels. Nothing was cloned.")
    return
  if modsComponent(donorT, "ScrollRect") == nil:
    pfxGraftRefuse("the node found as the Graphics 'SettingsList' carries no " &
                 "ScrollRect, so it is NOT the scroll host and cloning it " &
                 "would graft a container that cannot scroll. Refused.")
    return
  let panelT = modsChildNamed(postT, "Panel")
  let panelGo = (if panelT != nil: iGameObjectOf(panelT) else: nil)
  let donorGo = iGameObjectOf(donorT)
  if panelT == nil or panelGo == nil or donorGo == nil:
    pfxGraftRefuse("'PostFX Settings' -> 'Panel' or the donor SettingsList has " &
                 "no reachable GameObject, so there is nowhere to put a " &
                 "scroll host and nothing to clone. The page is untouched.")
    return
  let cloneGo = modsClone(donorGo)
  let cloneT = (if cloneGo != nil: modsTransformOf(cloneGo) else: nil)
  if cloneGo == nil or cloneT == nil:
    pfxGraftRefuse("Object::Instantiate of the Graphics SettingsList returned " &
                 "null or a clone with no reachable Transform. Nothing is " &
                 "parented anywhere.")
    return
  if not modsSetParent(cloneGo, panelGo):
    pfxGraftRefuse("the cloned SettingsList could not be parented under the " &
                 "PostFX 'Panel'. It is destroyed rather than left at the " &
                 "scene root, where it would render over the screen.")
    discard nuDestroy(cloneGo)
    return
  # (1) THE CLONE ROOT BECOMES THE AUTHORED PANEL, exactly.
  if not nuLayout(cloneT, og.aMinX, og.aMinY, og.aMaxX, og.aMaxY,
                  og.pivX, og.pivY, og.sdX, og.sdY, og.posX, og.posY):
    pfxGraftRefuse("the authored SettingsPanel geometry could not be applied " &
                 "to the clone root, so the scroll region would sit wherever " &
                 "the donor happened to sit -- the inset box the user saw. " &
                 "The clone is destroyed.")
    discard nuDestroy(cloneGo)
    return
  let sr = modsComponent(cloneT, "ScrollRect")
  let viewportT = modsChildNamed(cloneT, "Viewport")
  let contentT = (if viewportT != nil: modsChildNamed(viewportT, "Content")
                  else: nil)
  if sr == nil or viewportT == nil or contentT == nil:
    var missing = "its 'Viewport/Content' child"
    if sr == nil: missing = "its ScrollRect"
    elif viewportT == nil: missing = "its 'Viewport' child"
    pfxGraftRefuse("the clone is missing " & missing & ", so it cannot host " &
                 "anything. It is destroyed and the PostFX page is left " &
                 "exactly as it was.")
    discard nuDestroy(cloneGo)
    return
  # (2) THE VIEWPORT FILLS THE CLONE ROOT. The donor's viewport is a centred
  # 750-wide inset of an 850-wide list; kept, it is the 100 px of unclipped
  # overhang the user reported.
  if not nuLayout(viewportT, 0.0'f32, 0.0'f32, 1.0'f32, 1.0'f32,
                  0.5'f32, 0.5'f32, 0.0'f32, 0.0'f32, 0.0'f32, 0.0'f32):
    pfxGraftRefuse("the cloned Viewport could not be stretched to the clone " &
                 "root, so it would clip at the donor's own inset width. The " &
                 "clone is destroyed.")
    discard nuDestroy(cloneGo)
    return
  # (4) DONOR ROWS OUT FIRST, so the ContentSizeFitter never sees them plus
  # ours and resolves a 1490 px content that scrolls past the end.
  let retired = pfxRetireKids(contentT)
  # (3) OUR ROWS IN, and `_settingsRoot` repointed at the thing that now holds
  # them. The tab's field is written LAST of the three so that a refusal
  # anywhere above leaves it naming the panel that still holds the rows.
  let moved = pfxMoveKids(rowParent, contentT)
  if moved <= 0:
    pfxGraftRefuse("not one row could be moved from SettingsPanel into the " &
                 "cloned Content, so the rows are still in the unscrolled " &
                 "panel. The clone is destroyed and _settingsRoot is " &
                 "untouched -- nothing is half-moved.")
    discard nuDestroy(cloneGo)
    return
  if not nuOk(sr, NuOffScrollContent + 8'i32) or
     not nuOk(tab, PfxOffSettingsRoot + 8'i32):
    pfxGraftRefuse("ScrollRect.m_Content@0x20 or PostFXSettingsTab." &
                 "_settingsRoot@0xa0 could not be READ, so neither is " &
                 "written. The rows have already moved into the cloned " &
                 "Content; they are moved back and the clone destroyed.")
    discard pfxMoveKids(contentT, rowParent)
    discard nuDestroy(cloneGo)
    return
  if cNuSetRef(sr, NuOffScrollContent, contentT) == 0'i32 or
     cNuSetRef(tab, PfxOffSettingsRoot, contentT) == 0'i32:
    pfxGraftRefuse("the write to m_Content@0x20 or _settingsRoot@0xa0 was " &
                 "refused by the writability check. The rows are moved back " &
                 "into SettingsPanel and the clone destroyed, so the page is " &
                 "unscrolled but intact.")
    discard pfxMoveKids(contentT, rowParent)
    discard nuDestroy(cloneGo)
    return
  # (4) THE EMPTIED PANEL GOES DOWN, leaving the Viewport with exactly one
  # active child. An empty-but-active 850x726 box in the viewport is still a
  # raycast target and still a layout participant.
  let oldGo = iGameObjectOf(rowParent)
  if oldGo != nil: discard modsSetActive(oldGo, false)
  # ---- MAKE THE LAYOUT ACTUALLY RUN ------------------------------------
  #
  # MEASURED live on 82cb47ee (host log 18:36, lines 1750-1751): the graft
  # applied, and then "29 pair(s) of consecutive rows have intersecting y
  # ranges ... content 850x1490". 1490 is the DONOR's height, computed for the
  # 33 Graphics rows we had just retired. A stale height and 31 rows all at the
  # same y are one symptom, not two: the LayoutGroup and ContentSizeFitter on
  # the Content never re-ran after the reparent, so every moved row kept the
  # absolute position it had inside the old fixed SettingsPanel box (which had
  # no layout group at all, so those positions were authored, not driven).
  #
  # A LayoutGroup only positions children on a REBUILD, and a rebuild happens
  # when something marks the rect dirty. `Transform::SetParent` marks the
  # TRANSFORM hierarchy dirty; it does not queue a CanvasUpdate layout pass for
  # a group that was already enabled and already thought itself clean.
  #
  # THE CHEAPEST HONEST TRIGGER IS THE ONE THE GAME ITSELF USES: deactivate and
  # reactivate the Content. Every component's `OnEnable` runs again, and both
  # `LayoutGroup::OnEnable` and `ContentSizeFitter::OnEnable` call `SetDirty`,
  # which is `LayoutRebuilder::MarkLayoutForRebuild`. That needs NO new entry in
  # the target table -- `LayoutRebuilder::MarkLayoutForRebuild` @0x559B970 and
  # `ForceRebuildLayoutImmediate` @0x559AA70 are both UNIQUE and would be the
  # direct route, but adding a row to `aowl_nu_targets` is an ABI-header change
  # that drops every cache, and another agent is appending rows to that same
  # table this session -- two appends racing is a positional-index collision,
  # which is fact #187 and is worse than the problem it would solve.
  var layoutNote = ""
  let vlg = modsComponent(contentT, "VerticalLayoutGroup")
  let csf = modsComponent(contentT, "ContentSizeFitter")
  layoutNote = "VerticalLayoutGroup=" & (if vlg != nil: "present" else: "ABSENT") &
               " ContentSizeFitter=" & (if csf != nil: "present" else: "ABSENT")
  # ENABLE, unconditionally and deliberately. `UnityEngine.Behaviour.m_Enabled`
  # is NATIVE-side -- `fldoff.py fields UnityEngine.Behaviour` lists no such
  # il2cpp field -- so there is no field to read-then-write, and this is the
  # one place in this file where a read-validate-write is not available. It is
  # safe in the only way that matters: enabling an already-enabled Behaviour is
  # a no-op in Unity, and enabling a disabled one is exactly the repair.
  if vlg != nil: discard nuBehaviourEnable(vlg, true)
  if csf != nil: discard nuBehaviourEnable(csf, true)
  if vlg == nil or csf == nil:
    warn "postfx rows: the cloned Content is missing " &
         (if vlg == nil and csf == nil: "BOTH its VerticalLayoutGroup and its " &
            "ContentSizeFitter"
          elif vlg == nil: "its VerticalLayoutGroup"
          else: "its ContentSizeFitter") &
         ", so nothing will position the rows or drive the content height no " &
         "matter how often a rebuild is requested. The rows are already in " &
         "place; this names the reason the page will still look wrong."
  # A ROW THAT OPTS OUT OF LAYOUT CANNOT BE POSITIONED BY THE GROUP. The rows
  # came from a container with no layout group, so an authored
  # `ignoreLayout = true` on any of them would have been invisible there and is
  # fatal here. Cleared through the PROPERTY, which also calls
  # `LayoutElement::SetDirty` -- a raw store to m_IgnoreLayout@0x20 would
  # change the flag and leave the group holding its old arrangement.
  var optedOut = 0
  var kids2 = 0
  if iChildCount(contentT, kids2):
    var k = 0
    while k < kids2 and k < 64:
      let c = iChildAt(contentT, k)
      if c != nil and duOk(c, 0x20'i32):
        let le = modsComponent(c, "LayoutElement")
        if le != nil and nuSetIgnoreLayout(le, false): optedOut = optedOut + 1
      k = k + 1
  # THE TRIGGER ITSELF, last, so every component it re-enables is already in
  # the state we want it in.
  let cGo = iGameObjectOf(contentT)
  var bounced = false
  if cGo != nil:
    if modsSetActive(cGo, false) and modsSetActive(cGo, true): bounced = true
  if not bounced:
    warn "postfx rows: the cloned Content could not be deactivated and " &
         "reactivated, so no layout rebuild was requested and the rows will " &
         "keep the absolute positions they had in the old SettingsPanel -- " &
         "all stacked at the same y. This is the exact defect measured on " &
         "82cb47ee and it is being reported, not hidden."
  # (5) THE SCROLLBAR. Only touched if it is NOT already right-anchored, and
  # then only with numbers read off itself -- its own resolved width. A
  # scrollbar outside the panel is a visible defect and the verdict checks it
  # either way.
  let barT = modsChildNamed(cloneT, "Scrollbar")
  var barFixed = false
  if barT != nil:
    let bg = nuReadGeom(barT)
    if bg.ok and bg.aMinX < 0.99'f32:
      barFixed = nuLayout(barT, 1.0'f32, 0.0'f32, 1.0'f32, 1.0'f32,
                          1.0'f32, 0.5'f32, bg.rectW, 0.0'f32,
                          0.0'f32, 0.0'f32)
  gPfxScrollGo = cloneGo
  gPfxScrollHostT = cloneT
  gPfxScrollContentT = contentT
  gPfxScrollBarT = barT
  gPfxOrigRootT = rowParent
  gPfxOrigGeom = og
  newRootOut = contentT
  gPfxGraftOk = true
  gPfxGraftWhy = ""
  okLog "postfx rows: SCROLL GRAFT (v2) applied -- the clone root was given " &
        "the AUTHORED SettingsPanel rect verbatim (" & nuGeomNote(og) &
        "), its Viewport stretched to fill that root, " & $retired &
        " donor row(s) retired, " & $moved & " row(s) MOVED into the clone's " &
        "own Content (which already carries the LayoutGroup + " &
        "ContentSizeFitter that drive height -- nothing was AddComponent'd), " &
        "and BOTH ScrollRect.m_Content@0x20 and PostFXSettingsTab." &
        "_settingsRoot@0xa0 repointed at it. The emptied SettingsPanel was " &
        "retired so the Viewport has exactly one active child. Scrollbar " &
        (if barT == nil: "NOT FOUND"
         elif barFixed: "re-anchored to the right edge from its own width"
         else: "left as authored (already right-anchored)") &
        ". Layout on the cloned Content: " & layoutNote & "; " &
        $optedOut & " row(s) had a LayoutElement whose ignoreLayout was " &
        "cleared; the Content was " &
        (if bounced: "deactivated and reactivated to force OnEnable -> " &
           "SetDirty -> MarkLayoutForRebuild"
         else: "NOT bounced, so no rebuild was requested") &
        ". Every claim here is re-read by the verdict, which now runs " &
        "LATER -- see below."
  result = true

proc pfxScrollVerdict(rowParent: Il2CppPtr) =
  ## GEOMETRY, one frame later, off the live tree. The previous verdict read
  ## `m_Content` and two heights and passed on a visibly broken page; every
  ## check below is one of the facts it failed to look at.
  ##
  ## FAIL LOOKS LIKE, precisely:
  ##   * viewport rect not equal (+-1 px) to the authored SettingsPanel rect
  ##     -> the scroll region is not where the panel was: the inset box;
  ##   * content anchors not top-stretch (0,1)-(1,1) pivot y 1, or content
  ##     width != viewport width -> nothing drives the content and it will
  ##     overhang, which is the 850-in-a-750 defect;
  ##   * more than one ACTIVE child under the Viewport -> a retired object is
  ##     still live in there (the 1490 px donor Content);
  ##   * any active row wider than the viewport -> a row is clipped or spills;
  ##   * two consecutive rows whose y ranges intersect -> the rows are stacked
  ##     on each other because no layout group is driving them;
  ##   * the scrollbar rect not inside the panel rect -> it is drawn outside
  ##     the page;
  ##   * content no taller than the viewport -> there is nothing to scroll.
  ## INCONCLUSIVE is a third outcome throughout and is never a pass.
  ## GRAFT OUTCOME FIRST, AND IT IS THREE OUTCOMES, NOT ONE. On a7386d1f the
  ## graft returned silently and this verdict printed "no ScrollRect was found
  ## under PostFX Settings" -- a true sentence about a completely different
  ## cause, and the reason a whole deploy was spent looking at the wrong half
  ## of the feature. "The graft never ran" and "the graft ran and produced no
  ## ScrollRect" are different bugs with different fixes and must never share
  ## a line.
  if not gPfxScrollOn:
    warn "postfx rows SCROLL: the graft is DISABLED (settingsPostFxScroll is " &
         "off), so the PostFX page is the flat unscrolled panel by choice. " &
         "This is not a verdict about a missing ScrollRect."
    return
  if gPfxGraftTried and not gPfxGraftOk:
    warn "postfx rows SCROLL VERDICT INCONCLUSIVE -- THE GRAFT NEVER " &
         "COMPLETED, so there is nothing to judge. Reason: " &
         (if gPfxGraftWhy.len > 0: gPfxGraftWhy
          else: "not recorded, which is itself a defect -- every exit from " &
                "pfxScrollify is supposed to name itself") &
         ". Note this is NOT 'no ScrollRect exists': nothing was ever cloned."
    return
  if not gPfxGraftTried:
    warn "postfx rows SCROLL VERDICT INCONCLUSIVE: the graft was never even " &
         "attempted this build, so the page is unchanged and no geometry " &
         "claim is being made."
    return
  let host = (if gPfxScrollHostT != nil: gPfxScrollHostT
              elif gPfxPostPanelT != nil:
                modsFindNamed(gPfxPostPanelT, "SettingsList", 4)
              else: modsFindNamed(gGfxPostT, "SettingsList", 4))
  let sr = (if host != nil: modsComponent(host, "ScrollRect") else: nil)
  if sr == nil:
    warn "postfx rows SCROLL VERDICT INCONCLUSIVE: no ScrollRect was found " &
         "under 'PostFX Settings'. NOTE this searches the panel's CHILDREN; " &
         "the original verdict asked GetComponent on the panel ROOT, where a " &
         "ScrollRect was never going to be, so it could only ever answer " &
         "INCONCLUSIVE -- a check that could not fail."
    return
  if not nuOk(sr, NuOffScrollContent + 8'i32):
    warn "postfx rows SCROLL VERDICT INCONCLUSIVE: the ScrollRect was found " &
         "but m_Content@0x20 could not be read. 'I could not look' is not a " &
         "pass."
    return
  let content = cNuGetRef(sr, NuOffScrollContent)
  let want = (if gPfxScrollContentT != nil: gPfxScrollContentT else: rowParent)
  if content != want:
    warn "postfx rows SCROLL VERDICT FAIL: ScrollRect.m_Content@0x20 is " &
         iPtr(content) & " ('" & iObjName(content) & "') but the rows are in " &
         iPtr(want) & " ('" & iObjName(want) & "'). The rows are NOT in the " &
         "scrolled content and no change to heights or fitters can fix that."
    return
  let viewport = (if nuOk(sr, NuOffScrollViewport + 8'i32):
                    cNuGetRef(sr, NuOffScrollViewport) else: nil)
  let vg = nuReadGeom(viewport)
  let cg = nuReadGeom(content)
  let pg = nuReadGeom(if gPfxPostPanelT != nil: gPfxPostPanelT
                      else: gGfxPostT)
  if not vg.ok or not cg.ok:
    warn "postfx rows SCROLL VERDICT INCONCLUSIVE: m_Content is correct but " &
         (if not vg.ok: "the viewport" else: "the content") &
         " did not read back a valid rect, so no geometry can be judged."
    return
  var fails = 0
  var why = ""
  # 1. the scroll region occupies exactly the authored SettingsPanel space.
  if gPfxOrigGeom.ok:
    let dw = vg.rectW - gPfxOrigGeom.rectW
    let dh = vg.rectH - gPfxOrigGeom.rectH
    if dw > 1.0'f32 or dw < -1.0'f32 or dh > 1.0'f32 or dh < -1.0'f32:
      fails = fails + 1
      if why.len == 0:
        why = "the viewport resolves to " & nuF(vg.rectW) & "x" &
              nuF(vg.rectH) & " but the AUTHORED SettingsPanel was " &
              nuF(gPfxOrigGeom.rectW) & "x" & nuF(gPfxOrigGeom.rectH) &
              " -- the scroll region is not the space the panel occupied, " &
              "which is the inset-box defect"
  # 2. the content is top-stretch and as wide as the viewport.
  if cg.aMinX > 0.01'f32 or cg.aMaxX < 0.99'f32 or
     cg.aMinY < 0.99'f32 or cg.aMaxY < 0.99'f32 or cg.pivY < 0.99'f32:
    fails = fails + 1
    if why.len == 0:
      why = "the content anchors are " & nuGeomNote(cg) & ", not the " &
            "top-stretch (0,1)-(1,1) pivot-y 1 that lets a ContentSizeFitter " &
            "drive height"
  let cwd = cg.rectW - vg.rectW
  if cwd > 1.0'f32 or cwd < -1.0'f32:
    fails = fails + 1
    if why.len == 0:
      why = "the content is " & nuF(cg.rectW) & " px wide against a " &
            nuF(vg.rectW) & " px viewport, so it overhangs or underfills"
  # 3. exactly ONE active child under the Viewport.
  var vkids = 0
  var activeKids = 0
  if iChildCount(viewport, vkids):
    var i = 0
    while i < vkids and i < 32:
      let c = iChildAt(viewport, i)
      if c != nil and duOk(c, 0x20'i32):
        let go = iGameObjectOf(c)
        if go != nil and nuActiveInHierarchy(go): activeKids = activeKids + 1
      i = i + 1
    if activeKids != 1:
      fails = fails + 1
      if why.len == 0:
        why = $activeKids & " ACTIVE child(ren) under the Viewport, not 1 " &
              "-- a retired object is still live in the scroll area"
  else:
    warn "postfx rows SCROLL VERDICT INCONCLUSIVE: the Viewport's childCount " &
         "could not be read, so 'exactly one active child' is unknown."
    return
  # 4/5. every active row fits, and consecutive rows do not overlap.
  var rows = 0
  var tooWide = 0
  var overlaps = 0
  var prevBottom = 0.0'f32
  var havePrev = false
  var n = 0
  if iChildCount(content, n):
    var i = 0
    while i < n and i < 64:
      let c = iChildAt(content, i)
      if c != nil and duOk(c, 0x20'i32):
        let go = iGameObjectOf(c)
        if go != nil and nuActiveInHierarchy(go):
          let rg = nuReadGeom(c)
          if rg.ok:
            rows = rows + 1
            if rg.rectW > vg.rectW + 1.0'f32: tooWide = tooWide + 1
            let (eok, top, lft) = nuChildEdgeInParent(cg, rg)
            discard lft
            if eok:
              if havePrev and top > prevBottom + 0.5'f32:
                overlaps = overlaps + 1
              prevBottom = top - rg.rectH
              havePrev = true
      i = i + 1
  if rows == 0:
    warn "postfx rows SCROLL VERDICT INCONCLUSIVE: not one ACTIVE row was " &
         "found under the content, so neither width nor stacking could be " &
         "judged. An empty scroll area is not a passing scroll area."
    return
  if tooWide > 0:
    fails = fails + 1
    if why.len == 0:
      why = $tooWide & " of " & $rows & " active row(s) are wider than the " &
            nuF(vg.rectW) & " px viewport"
  if overlaps > 0:
    fails = fails + 1
    if why.len == 0:
      why = $overlaps & " pair(s) of consecutive rows have intersecting y " &
            "ranges -- the rows are stacked on each other, so no layout " &
            "group is driving them"
  # 6. the scrollbar is inside the panel.
  if gPfxScrollBarT != nil and pg.ok:
    let bg = nuReadGeom(gPfxScrollBarT)
    if bg.ok:
      let (bok, btop, bleft) = nuChildEdgeInParent(pg, bg)
      discard btop
      if bok and (bleft < pg.rectX - 1.0'f32 or
                  bleft + bg.rectW > pg.rectX + pg.rectW + 1.0'f32):
        fails = fails + 1
        if why.len == 0:
          why = "the scrollbar spans " & nuF(bleft) & ".." &
                nuF(bleft + bg.rectW) & " in a panel that spans " &
                nuF(pg.rectX) & ".." & nuF(pg.rectX + pg.rectW) &
                " -- it is drawn outside the page"
  # 7. and there must be something to scroll at all.
  if cg.rectH <= vg.rectH:
    fails = fails + 1
    if why.len == 0:
      why = "the content resolves to " & nuF(cg.rectH) &
            " px which is NOT taller than the " & nuF(vg.rectH) &
            " px viewport, so nothing can scroll"
  if fails == 0:
    okLog "postfx rows SCROLL VERDICT PASS: viewport " & nuF(vg.rectW) & "x" &
          nuF(vg.rectH) & " matches the AUTHORED SettingsPanel rect within " &
          "1 px; the content is top-stretch, " & nuF(cg.rectW) &
          " px wide (== the viewport) and " & nuF(cg.rectH) &
          " px tall (so there is something to scroll); the Viewport has " &
          "exactly ONE active child; all " & $rows & " active row(s) fit " &
          "inside the viewport width and no two consecutive rows' y ranges " &
          "intersect; the scrollbar rect is inside the panel rect. Every " &
          "number read from get_rect on the live RectTransforms one frame " &
          "after the graft."
  else:
    warn "postfx rows SCROLL VERDICT FAIL (" & $fails &
         " geometry check(s) failed): " & why & ". " & $rows &
         " active row(s) judged, viewport " & nuF(vg.rectW) & "x" &
         nuF(vg.rectH) & ", content " & nuF(cg.rectW) & "x" & nuF(cg.rectH) &
         ", " & $activeKids & " active Viewport child(ren). This is the page " &
         "the user is looking at, not a summary of what we wrote."

proc pfxOwnToggle(): Il2CppPtr =
  ## The `UpdatableToggle` inside OUR own 'enabled' row -- reached from the
  ## `SettingControl` instance Instantiate handed us, through
  ## `SettingToggle.Toggle@0xa8`. Never by name and never by position.
  result = nil
  var i = 0
  while i < gPfxRowName.len and i < PfxMaxHandles:
    if gPfxRowName[i] == PfxEnableKey and i < gPfxRowCtrl.len:
      let c = gPfxRowCtrl[i]
      if nuOk(c, NuOffSettingToggleTog + 8'i32):
        let t = cNuGetRef(c, NuOffSettingToggleTog)
        if nuOk(t, NuOffToggleIsOn + 4'i32) and nuAlive(t): return t
      return nil
    i = i + 1

proc pfxStockToggle(): Il2CppPtr =
  ## THE GAME'S OWN 'Enable PostFX' toggle, in `EnablePanel` -- the one the
  ## user actually unchecked. Reached by WALKING 'PostFX Settings' -> 'Panel'
  ## -> 'EnablePanel' and validating each hop, then by SHAPE (`modsToggleOf`,
  ## which prefers an ACTIVE toggle) rather than by a child name, because the
  ## panel's single child is a prefab instance whose name is the prefab's and
  ## not something this file may assume.
  result = nil
  if gPfxStockTog != nil and nuAlive(gPfxStockTog): return gPfxStockTog
  # PREFER THE PANEL WE WALKED TO FROM THE TAB. modstab's `gGfxPostT` is
  # populated by the SUBTAB feature's tick and is nil until that has run;
  # leaning on it is exactly what made the scroll graft silently
  # ordering-dependent on another feature, and the same trap applies here.
  let base = (if gPfxPostPanelT != nil: gPfxPostPanelT else: gGfxPostT)
  if base == nil or not iUnityAlive(base): return
  let panelT = modsChildNamed(base, "Panel")
  if panelT == nil: return
  let enT = modsChildNamed(panelT, "EnablePanel")
  if enT == nil or not duOk(enT, 0x20'i32): return
  var t = modsToggleOf(enT)
  if t == nil:
    # The control may hang off the panel's single child rather than the panel.
    var n = 0
    if iChildCount(enT, n) and n > 0:
      let c = iChildAt(enT, 0)
      if c != nil and duOk(c, 0x20'i32):
        let ctrl = modsComponent(c, "SettingToggle")
        if ctrl != nil and nuOk(ctrl, NuOffSettingToggleTog + 8'i32):
          t = cNuGetRef(ctrl, NuOffSettingToggleTog)
        if t == nil: t = modsToggleOf(c)
  if t != nil and nuOk(t, NuOffToggleIsOn + 4'i32) and nuAlive(t):
    gPfxStockTog = t
    result = t

proc pfxRowGroup(ctrl: Il2CppPtr): Il2CppPtr =
  ## The CanvasGroup the game's own blocker would drive for this row:
  ## `SettingControl._blocker@0x88` (or `_elementBlocker@0xa0`) ->
  ## `UiElementBlocker.Group@0x20`. Every hop validated; any of the three can
  ## legitimately be null on a prefab instance, which is a DECLINE, not a fault.
  result = nil
  if not nuOk(ctrl, PfxOffCtrlBlocker2 + 8'i32): return
  var b = cNuGetRef(ctrl, PfxOffCtrlBlocker)
  if not nuOk(b, PfxOffBlockerGroup + 8'i32) or not nuAlive(b):
    b = cNuGetRef(ctrl, PfxOffCtrlBlocker2)
  if not nuOk(b, PfxOffBlockerGroup + 8'i32) or not nuAlive(b): return
  let g = cNuGetRef(b, PfxOffBlockerGroup)
  if not nuOk(g, 0x18'i32) or not nuAlive(g): return
  result = g

proc pfxGraySet(cg: Il2CppPtr; free: bool): bool =
  ## `MyExtensions::SetUnlockStatus(group, value, setRaycast: true)` @0x1d20100,
  ## MIRRORED CALL FOR CALL: set_alpha(1.0 | 0.3), set_interactable(value),
  ## set_blocksRaycasts(value), in that order. See the header for the
  ## disassembly and for where the two float literals were read.
  result = false
  let fA = nuFn(NuTCgSetAlpha)
  let fI = nuFn(NuTCgSetInteract)
  let fB = nuFn(NuTCgSetBlocksRay)
  if fA == nil or fI == nil or fB == nil: return
  if not nuOk(cg, 0x18'i32) or not nuAlive(cg): return
  cNuCallVPF(fA, cg, (if free: PfxAlphaFree else: PfxAlphaBlocked))
  cNuCallVPB(fI, cg, (if free: 1'i32 else: 0'i32))
  cNuCallVPB(fB, cg, (if free: 1'i32 else: 0'i32))
  result = true

## The two thin wrappers that implement the forward declarations in
## `settingspages.nim`. ONE implementation of the gray-out, two consumers: the
## PostFX subtab (whose live verdict derived it) and the MODS tab's per-mod
## pages, which gray a disabled mod's settings the same way rather than
## inventing a second mechanism with a second set of offsets.
proc swRowGrayGroup(ctrl: Il2CppPtr): Il2CppPtr = pfxRowGroup(ctrl)
proc swRowGraySet(cg: Il2CppPtr; free: bool): bool = pfxGraySet(cg, free)

proc pfxGrayApply(free: bool; applied, declined: var int) =
  ## Every row of OURS except the 'enabled' row itself.
  applied = 0
  declined = 0
  var i = 0
  while i < gPfxRowCtrl.len and i < PfxMaxHandles:
    if i < gPfxRowName.len and gPfxRowName[i] != PfxEnableKey:
      let g = pfxRowGroup(gPfxRowCtrl[i])
      if g == nil: declined = declined + 1
      elif pfxGraySet(g, free): applied = applied + 1
      else: declined = declined + 1
    i = i + 1

proc pfxGrayVerdict(free: bool; why: string; applied, declined: int) =
  ## THE STATE THAT WAS ACTUALLY OBSERVED, NAMED. A PASS may only be claimed
  ## for a state the run really reached.
  ##
  ## THE CHECK THIS REPLACES COULD NOT FAIL: it keyed on OUR row alone, which
  ## was ON, so it only ever judged the FREE state and printed "with Enable
  ## post-process ON, no row reads blocked" -- true, vacuous, and PASS while
  ## 26 rows sat interactive under an UNCHECKED stock toggle. Naming the state
  ## and reporting whether the OFF state was ever observed is what makes the
  ## difference visible in the log instead of only on screen.
  ##
  ## Read through the CanvasGroup GETTERS -- a different path than the setters
  ## that wrote -- and stated as a negative: NO row of ours disagrees.
  var judged = 0
  var wrong = 0
  var firstWrong = ""
  var i = 0
  while i < gPfxRowCtrl.len and i < PfxMaxHandles:
    if i < gPfxRowName.len and gPfxRowName[i] != PfxEnableKey:
      let g = pfxRowGroup(gPfxRowCtrl[i])
      if g != nil:
        let (ok, alpha, inter) = nuCgRead(g)
        if ok:
          judged = judged + 1
          let isFree = (alpha > 0.9'f32) and inter
          let isBlocked = (alpha < 0.9'f32) and not inter
          if (free and not isFree) or ((not free) and not isBlocked):
            wrong = wrong + 1
            if firstWrong.len == 0:
              firstWrong = gPfxRowName[i] & " (alpha " & nuF(alpha) &
                           ", interactable " &
                           (if inter: "true" else: "false") & ")"
    i = i + 1
  if free: gPfxSeenFree = true
  else: gPfxSeenBlocked = true
  let seen = " FREE state observed: " & (if gPfxSeenFree: "yes" else: "no") &
             "; OFF (blocked) state observed: " &
             (if gPfxSeenBlocked: "yes" else: "no") &
             ". A verdict covers ONLY the state named above; the other is " &
             "UNJUDGED until the user's own toggles reach it -- nothing here " &
             "ever flips a toggle to manufacture the observation."
  if judged == 0:
    warn "postfx rows GRAY-OUT VERDICT INCONCLUSIVE: not one of our " &
         $gPfxRowCtrl.len & " row(s) exposed a readable CanvasGroup through " &
         "SettingControl._blocker@0x88 -> UiElementBlocker.Group@0x20 (" &
         $declined & " declined at the walk). Nothing was judged." & seen
  elif wrong == 0:
    okLog "postfx rows GRAY-OUT VERDICT PASS for the " &
          (if free: "FREE" else: "BLOCKED") & " state (" & why & "): NO row " &
          "of ours reads " & (if free: "blocked" else: "free") & " -- all " &
          $judged & " judged row(s) report CanvasGroup alpha " &
          (if free: "1.0 and interactable"
           else: "0.3 and non-interactable") &
          ", read back through get_alpha/get_interactable and not from what " &
          "we wrote. " & $applied & " written, " & $declined &
          " declined for want of a blocker." & seen
  else:
    warn "postfx rows GRAY-OUT VERDICT FAIL for the " &
         (if free: "FREE" else: "BLOCKED") & " state (" & why & "): " &
         $wrong & " of " & $judged & " judged row(s) disagree. First: " &
         firstWrong & ". A row that looks live and is inert, or looks dead " &
         "and is live, is worse than no gray-out at all." & seen

proc pfxGrayEval(why: string) =
  ## THE EFFECTIVE STATE IS THE AND OF TWO TOGGLES, and that is the whole
  ## correction. Our rows describe a post-process chain the game's own
  ## 'Enable PostFX' switch can disable outright, so they must read blocked
  ## whenever EITHER that stock toggle or our own 'Enable post-process' row is
  ## off. Keying on ours alone is what let 26 rows stay interactive under an
  ## unchecked stock toggle while the verdict printed PASS.
  if not gPfxGrayOn or not gPfxBuilt: return
  let free = gPfxStockOn and gPfxOwnOn
  if gPfxGrayHave and free == gPfxGrayApplied: return
  var applied = 0
  var declined = 0
  pfxGrayApply(free, applied, declined)
  gPfxGrayApplied = free
  gPfxGrayHave = true
  pfxGrayVerdict(free, why, applied, declined)

proc pfxOnToggleSet(tog: Il2CppPtr; turnedOn: bool) =
  ## RIDES THE EXISTING `UnityEngine.UI.Toggle::Set` PREFIX in nativetabs --
  ## it installs NOTHING. The double-detour rule: a second physical detour on
  ## Toggle::Set would overwrite the first's trampoline and silently kill the
  ## subtab strip. It runs inside that body's single `aowl_p_p_seh` and opens
  ## no guard of its own; the guard is not re-entrant and a nested one DISARMS
  ## the outer.
  ##
  ## Two pointer compares for every toggle in the game, and nothing else in
  ## the steady state.
  ##
  ## THE VALUE BINDING DRAINS HERE FIRST, and above the gray-out's own gates on
  ## purpose: `settingsRowsBind` and `settingsPostFxGrayOut` are independent
  ## flags, and putting this after the `gPfxGrayOn` test would make every row's
  ## value silently depend on a cosmetic feature being on. Its own gate is one
  ## boolean compare when the binding is off.
  sbdOnToggleSet(tog, turnedOn)
  if not gPfxGrayOn or not gPfxBuilt or gPfxOff: return
  if tog == nil: return
  if tog == gPfxStockTog:
    gPfxStockOn = turnedOn
    pfxGrayEval("the game's own 'Enable PostFX' toggle went " &
                (if turnedOn: "ON" else: "OFF") & ", seen on the Toggle::Set " &
                "drain")
    return
  if tog == gPfxOwnTog:
    gPfxOwnOn = turnedOn
    pfxGrayEval("our 'Enable post-process' row went " &
                (if turnedOn: "ON" else: "OFF") & ", seen on the Toggle::Set " &
                "drain")

proc pfxGrayTick() =
  ## DEFECT 3. The EDGES arrive on the Toggle::Set drain above; this is the
  ## BUILD-TIME initial read and the backstop.
  ##
  ## WHY A BACKSTOP AND NOT ONLY THE DRAIN: the drain sees `Set(value, true)`,
  ## so anything that writes `m_IsOn` without a callback -- the game restoring
  ## a saved setting, a SetIsOnWithoutNotify on screen open -- is invisible to
  ## it. The poll is two raw field reads per frame and no allocation, and it
  ## makes a missed edge a one-frame delay instead of a wrong screen.
  ##
  ## NOTHING HERE EVER WRITES A TOGGLE. The user's own switches are read only.
  if not gPfxGrayInit:
    gPfxGrayInit = true
    gPfxGrayOn = readBoolKeyDef("settingsPostFxGrayOut", false)
  if not gPfxGrayOn or not gPfxBuilt: return
  if gPfxOwnTog == nil: gPfxOwnTog = pfxOwnToggle()
  let stock = pfxStockToggle()
  if gPfxOwnTog == nil or stock == nil:
    if not gPfxGraySaid:
      gPfxGraySaid = true
      warn "postfx rows GRAY-OUT INCONCLUSIVE: " &
           (if stock == nil:
              "the GAME'S OWN 'Enable PostFX' toggle could not be reached by " &
              "walking 'PostFX Settings' -> 'Panel' -> 'EnablePanel'"
            else:
              "our own 'enabled' row's UpdatableToggle " &
              "(SettingToggle.Toggle@0xa8) could not be reached") &
           ", so the effective state is UNKNOWN and NOTHING was written to " &
           "any row. Our rows are left exactly as they were -- this declines " &
           "rather than guessing at half the condition, which is the bug it " &
           "replaces."
    return
  # `m_IsOn@0x120`, read raw off both toggles (MEASURED, `fldoff.py field
  # UnityEngine.UI.Toggle m_IsOn`). At build this IS the initial state; every
  # frame after, it is the backstop for an edge the drain could not see.
  let (okS, onS) = nuToggleIsOn(stock)
  let (okO, onO) = nuToggleIsOn(gPfxOwnTog)
  if not okS or not okO: return
  let changed = (onS != gPfxStockOn) or (onO != gPfxOwnOn)
  gPfxStockOn = onS
  gPfxOwnOn = onO
  if not gPfxGrayHave:
    pfxGrayEval("initial state read from Toggle.m_IsOn@0x120 at build: " &
                "stock 'Enable PostFX' " & (if onS: "ON" else: "OFF") &
                ", our 'Enable post-process' " & (if onO: "ON" else: "OFF"))
  elif changed:
    pfxGrayEval("a state change seen by the m_IsOn backstop rather than by " &
                "the Toggle::Set drain (stock " & (if onS: "ON" else: "OFF") &
                ", ours " & (if onO: "ON" else: "OFF") & ")")

proc pfxBuild(): bool =
  ## Build the catalogue into the live PostFX panel. Called ONCE, from the
  ## tick, only after the panel has actually been observed up.
  result = false
  if gPfxBuilt or gPfxOff or not gPfxOn:
    return
  inc gPfxTried
  if not nuTargetsBindOk():
    pfxNoteFault("the aowl_nu_targets POSITIONAL self-check FAILED, so every " &
                 "call this file makes would go to the wrong method with the " &
                 "wrong frame. Nothing was built.")
    return
  let tab = pfxTab()
  if tab == nil:
    pfxNoteFault("the PostFXSettingsTab component could not be reached by " &
                 "walking from the live 'PostFX Settings' panel transform. " &
                 "Without it there is no row parent and no prefab, so nothing " &
                 "was built. NOTE this is the tab COMPONENT, not the panel " &
                 "GameObject the old from-scratch build parented onto.")
    return
  # THE ROW PARENT, and this is DEFECT 2's fix stated in one line: rows go into
  # `_settingsRoot`, the container the game's own rows go into and the one its
  # LayoutGroup drives. The previous build parented onto the PANEL ROOT with
  # explicit offsets, deliberately, to escape that layout group -- which is why
  # its rows started part-way down the page instead of at the top of the list.
  let parent = (if nuOk(tab, PfxOffSettingsRoot + 8'i32):
                  cNuGetRef(tab, PfxOffSettingsRoot) else: nil)
  if not nuOk(parent, 0x10'i32) or not nuAlive(parent):
    pfxNoteFault("PostFXSettingsTab._settingsRoot @0xa0 read null, unreadable " &
                 "or not a live Unity object. That field is serialized and is " &
                 "populated when the prefab loads, so this is 'asked too " &
                 "early' rather than a wrong offset. Nothing was built and " &
                 "nothing was parented anywhere.")
    return
  let togPrefab = (if nuOk(tab, PfxOffToggleTemplate + 8'i32):
                     cNuGetRef(tab, PfxOffToggleTemplate) else: nil)
  let sliPrefab = (if nuOk(tab, PfxOffSliderTemplate + 8'i32):
                     cNuGetRef(tab, PfxOffSliderTemplate) else: nil)
  let drpPrefab = (if nuOk(tab, PfxOffDropTemplate + 8'i32):
                     cNuGetRef(tab, PfxOffDropTemplate) else: nil)
  if not nuOk(togPrefab, 0x10'i32) and not nuOk(sliPrefab, 0x10'i32):
    pfxNoteFault("NEITHER _toggleLeftTemplate @0xc0 nor " &
                 "_selectFloatSliderTemplate @0xb0 read back as a live " &
                 "object, so there is no prefab to instantiate. Refusing to " &
                 "fall back to building controls from scratch -- that is the " &
                 "workaround this change removed.")
    return
  # THE STOCK DONOR, and the row parent's own width. Read BEFORE any row is
  # built, once, so the loop below costs nothing extra.
  var geom = nuNoGeom()
  var parentW = 0.0'f32
  gPfxHaveGeom = pfxDonorGeom(geom, parentW)
  if gPfxHaveGeom: gPfxGeom = geom
  let pgeom = nuReadGeom(parent)
  gPfxParentW = (if pgeom.ok: pgeom.rectW else: parentW)
  let rows = pfxCatalogue()
  gPfxRowGo = @[]
  gPfxRowSlider = @[]
  gPfxRowWant = @[]
  gPfxRowName = @[]
  gPfxRowCtrl = @[]
  gPfxDeclined = @[]
  var built = 0
  var refused = 0
  var i = 0
  var seededFromConfig = 0
  while i < rows.len and i < PfxMaxRows and gPfxRowGo.len < PfxMaxHandles:
    let r = rows[i]
    if r.kind == pkChoice:
      # THE LOUD DECLINE. Named here, named in the summary, named on screen.
      gPfxDeclined.add r.key
      i = i + 1
      continue
    let prefab = (if r.kind == pkToggle: togPrefab else: sliPrefab)
    if not nuOk(prefab, 0x10'i32):
      gPfxDeclined.add r.key
      refused = refused + 1
      i = i + 1
      continue
    var sl: Il2CppPtr = nil
    var ct: Il2CppPtr = nil
    let go = pfxMakeRow(prefab, parent, r, int32(built), sl, ct)
    if go != nil:
      gPfxRowGo.add go
      gPfxRowSlider.add sl
      gPfxRowCtrl.add ct
      gPfxRowWant.add r.def
      gPfxRowName.add r.key
      built = built + 1
      # THE VALUE BINDING (settingsbind.nim), flag `settingsRowsBind`, default
      # OFF -- with it off both calls return false having done nothing and the
      # row is exactly what it was before: a real control that changes nothing.
      #
      # The pointers handed over are the ones this loop ALREADY HOLDS, from
      # `Instantiate` and from `SettingFloatSlider.Slider@0xa8`. Nothing is
      # re-found by name or by sibling index later, which is what made a
      # previous version of the subtab strip stop responding silently once the
      # player cycled tabs.
      #
      # The return value is "was this seeded from the CONFIG": false means the
      # row is showing the schema's DECLARED DEFAULT, and that is counted so
      # the banner can say which of the two the numbers are instead of letting
      # a default read as the player's setting.
      if r.kind == pkToggle:
        if sbdRegisterToggle(SbdPostFxGuid, r.key, ct, false):
          seededFromConfig = seededFromConfig + 1
      elif sl != nil:
        if sbdRegisterSlider(SbdPostFxGuid, r.key, sl, r.lo, r.hi, r.def):
          seededFromConfig = seededFromConfig + 1
    else:
      refused = refused + 1
    i = i + 1
  if built == 0:
    pfxNoteFault("zero rows were built out of " & $rows.len & " declared (" &
                 $refused & " refused, " & $gPfxDeclined.len & " declined as " &
                 "an unreachable row kind). Nothing is left in the panel.")
    discard pfxDestroyAll()
    return
  # THE BANNER IS GONE, AND ITS SENTENCE IS HERE INSTEAD.
  #
  # MEASURED on the deployed build (user report + live rect): the from-scratch
  # `nuLabel` at y=-60 h=40 named "aowl-pfx-banner" DID NOT RENDER, and its
  # slot left an empty ~60px band above the first row. So it cost a visible
  # defect and delivered nothing. It was also the ONE from-scratch element in
  # a file whose whole thesis is "instantiate the game's own prefabs"; a label
  # built out of nothing is exactly the thing that does not inherit the
  # wiring that makes stock text appear.
  #
  # Everything it was trying to say is a fact about OUR build, not about the
  # player's screen, so it belongs in the log. Nothing is suppressed: the
  # preset-owned rows and the declined row kinds are both named below.
  var declinedTxt = ""
  var d = 0
  while d < gPfxDeclined.len and d < 8:
    declinedTxt = declinedTxt & (if d > 0: ", " else: "") & gPfxDeclined[d]
    d = d + 1
  var presetOwnedTxt = ""
  var po = 0
  var pi2 = 0
  while pi2 < rows.len and pi2 < 64:
    if rows[pi2].presetOwned:
      po = po + 1
      if po <= 8:
        presetOwnedTxt = presetOwnedTxt & (if po > 1: ", " else: "") &
                         rows[pi2].key
    pi2 = pi2 + 1
  okLog "postfx rows: NO BANNER and NO CAPTION PREFIX -- the page is vanilla. " &
        "The from-scratch 'aowl-pfx-banner' label did not render and its " &
        "40px slot at y=-60 was the empty band above the first row, so it " &
        "cost a visible defect and said nothing; the '* ' prefix marked " &
        "preset-owned rows in a way no stock row does. Both facts live here " &
        "now: " & $built & " row(s) built, " & $gSbdRows.len &
        " REGISTERED with the value binding (a count of 0 here with the flag " &
        "on means every row on screen is bound to nothing, and no SAVE is " &
        "needed to find that out), " & $seededFromConfig &
        " seeded FROM THE SAVED CONFIG and " & $(built - seededFromConfig) &
        " showing the mod's DECLARED DEFAULT, binding " &
        (if seededFromConfig > 0 or gSbdRows.len > 0:
           "ON (settingsRowsBind): edits are staged and written on SAVE"
         else:
           "OFF (settingsRowsBind): moving a row changes nothing") &
        ". Owned by the active Preset and " &
        "ignored until Preset=custom (" & $po & "): " &
        (if presetOwnedTxt.len > 0: presetOwnedTxt else: "-") &
        ". No row for: " & (if declinedTxt.len > 0: declinedTxt else: "-") &
        " (dropdown and select-slider binds are generic and have no offline " &
        "address)."
  # THE SCROLL VERDICT, and it can FAIL.
  #
  # MEASURED USER REPORT: the Graphics body scrolls and the PostFX body does
  # not. The falsifiable question is NOT "does it look scrollable" -- it is
  # "is the container our rows went into the SAME RectTransform the panel's
  # ScrollRect is told to scroll", i.e. `ScrollRect.m_Content@0x20`
  # (MEASURED `fldoff.py fields UnityEngine.UI.ScrollRect`). If our rows are
  # in a sibling of the content, no amount of height makes them scroll, and
  # nothing about the RECT would have told us so -- §3's warning that
  # Graphics' and PostFX's geometry agree only by arithmetic coincidence at
  # this window height is exactly why a rect-derived answer here is worthless.
  #
  # INTENDED FINISHED PAGE, stated so the verdict has something to judge:
  # ShowScreen(PostFX) makes the game build its OWN stock PostFX rows into
  # `_settingsRoot@0xa0` first; ours are instantiated into the SAME root and
  # therefore land after them; all of it is inside the ScrollRect's content,
  # whose height is driven by the content's own layout, and no row is outside
  # the viewport's clipping parent. In the build this replaces the stock rows
  # NEVER EXISTED, because the panel was only ever `SetActive`d and
  # `PostFXSettingsTab::Show`/`OnFirstSelect` never ran.
  #
  # FAIL looks like: `m_Content` naming something other than `_settingsRoot`.
  # INCONCLUSIVE looks like: no ScrollRect found, or the field unreadable --
  # which is NOT a pass.
  # THE GRAFT RUNS FIRST, THEN THE VERDICT JUDGES WHAT IT LEFT. Both are
  # flag-gated separately: with `settingsPostFxScroll` off the page is exactly
  # what it was and the verdict still runs, which is how the "no ScrollRect
  # anywhere in this panel" reading stays available as a control.
  if not gPfxScrollInit:
    gPfxScrollInit = true
    gPfxScrollOn = readBoolKeyDef("settingsPostFxScroll", false)
  var scrollRoot: Il2CppPtr = nil
  if gPfxScrollOn:
    discard pfxScrollify(tab, parent, scrollRoot)
  # THE ROW PARENT MAY HAVE MOVED. If the graft succeeded, the rows now live
  # in the clone's Content and every later measurement -- the width check, the
  # verdict -- must be against THAT, not against the panel they were built in.
  # Reading this back rather than assuming it is the difference between the
  # verdict judging the finished page and judging our intent.
  let judgeRoot = (if scrollRoot != nil: scrollRoot else: parent)
  let jg = nuReadGeom(judgeRoot)
  if jg.ok: gPfxParentW = jg.rectW
  # JUDGED LATER, NEVER NOW -- AND THE PREVIOUS BUILD GOT THIS WRONG.
  # `pfxScrollVerdict` used to be called right here, on the same frame as
  # the graft. A LayoutGroup rebuild is deferred to `willRenderCanvases`,
  # so on that frame the content still reports the DONOR's height and
  # every row still reports its pre-move position. The live FAIL on
  # 82cb47ee -- '29 pair(s) of consecutive rows have intersecting y
  # ranges ... content 850x1490' -- is partly a real defect and partly
  # this: a reading taken before the thing it measures had happened. That
  # makes it INCONCLUSIVE dressed as FAIL, which is the same family of
  # error as a check that cannot fail and is no more acceptable.
  gPfxScrollJudgeRoot = judgeRoot
  gPfxScrollJudge = PfxScrollJudgeDelay
  gPfxBuilt = true
  okLog "postfx rows: built " & $built & " NATIVE PREFAB row(s) into " &
        "PostFXSettingsTab._settingsRoot -- " &
        "instantiated from the tab's own serialized templates" &
        " (_toggleLeftTemplate @0xc0 / _selectFloatSliderTemplate @0xb0) via " &
        "Object::Instantiate(Object,Transform,bool) @0x52ADDA0, captioned " &
        "with SettingControl::SetText @0x16FA890. NOTHING WAS CLONED and " &
        "nothing was built from scratch except the banner. " & $refused &
        " row(s) refused, " & $gPfxDeclined.len & " DECLINED as a row kind " &
        "we cannot honestly build (dropdown/select-slider binds are generic " &
        "and have no offline address). This is a STRUCTURAL report of what " &
        "was called; the verdict below is the finished-state read."
  result = true

proc pfxWidthOk(go: Il2CppPtr; i: int; firstWide: var string;
                wrongWidth, overflow: var int): bool =
  ## ONE row's width, read off the LIVE RectTransform through `get_rect` --
  ## never from anything this file wrote.
  ##
  ## Two independent ways to fail, kept separate because they have different
  ## causes: a row that does not match the stock donor (the copy did not take)
  ## and a row wider than its own container (the clipped-slider defect the
  ## player actually sees). A row can be the second without being the first if
  ## the donor itself is wrong, which is exactly why both are asked.
  result = true
  let rt = nuTransformOf(go)
  if rt == nil: return                # unreadable is handled by the caller's incon
  let g = nuReadGeom(rt)
  if not g.ok: return
  if gPfxParentW > 1.0'f32 and g.rectW > gPfxParentW + 1.0'f32:
    overflow = overflow + 1
    result = false
    if firstWide.len == 0:
      firstWide = gPfxRowName[i] & " is " & nuF(g.rectW) & " wide inside a " &
                  nuF(gPfxParentW) & " container -- it is CLIPPED"
    return
  if gPfxHaveGeom:
    # WHAT WIDTH IS CORRECT depends on how the donor is anchored, and getting
    # this wrong is how a check starts failing on healthy rows.
    #
    # The stock Graphics rows are STRETCH-anchored horizontally
    # (anchorMin.x = 0, anchorMax.x = 1), so `nuApplyGeomX` copies "fill your
    # parent" rather than a number. Our rows live in the PostFX tab's
    # `_settingsRoot`, a DIFFERENT container from the Graphics one -- so the
    # correct expectation is the PostFX parent's width, not the Graphics
    # donor's absolute width. Comparing against the donor's number would fail
    # every row whenever the two panels differ, which is a check that fails for
    # the wrong reason.
    #
    # Only when the donor is NOT stretched does its absolute width mean
    # anything transferable.
    let stretched = (gPfxGeom.aMaxX - gPfxGeom.aMinX) > 0.99'f32
    let expectW = (if stretched: gPfxParentW else: gPfxGeom.rectW)
    if expectW > 1.0'f32:
      let d = g.rectW - expectW
      if d > 1.0'f32 or d < -1.0'f32:
        wrongWidth = wrongWidth + 1
        result = false
        if firstWide.len == 0:
          firstWide = gPfxRowName[i] & " reads " & nuF(g.rectW) &
                      " wide; expected " & nuF(expectW) &
                      (if stretched: " (the donor row stretches to fill its " &
                         "parent, so a correct row is the width of ITS parent)"
                       else: " (the stock donor row's own width)")

proc pfxVerdict() =
  ## THE 9b ACCEPTANCE TEST, read back off the LIVE objects.
  ##
  ## Two assertions, and both can fail:
  ##   * every row we own reads back `activeInHierarchy` -- a row that is on
  ##     the page but not in the hierarchy is invisible and unpressable, which
  ##     is exactly the "blank panel" the player reported;
  ##   * NO row is wider than the container it sits in, and every row reports
  ##     the SAME width as the stock donor to within 1px. This is the check for
  ##     the reported layout defect and it is stated as the NEGATIVE on
  ##     purpose: "no row's right edge extends past the panel" can be
  ##     falsified by one clipped slider, whereas "we wrote the donor width"
  ##     compares our own write against itself and cannot fail. The width is
  ##     read from `get_rect`, NOT from `sizeDelta` -- for a stretched anchor
  ##     sizeDelta is an inset and would read 0 for a correctly full-width row.
  ##   * every FLOAT row's inner `NumberSlider::CurrentValue()` @0x16B5850
  ##     reads back the value we asked for. That is a read of the LIVE widget
  ##     through a different method than the one that wrote it -- not a
  ##     re-read of our own variable -- so a `Show` that silently clamped, an
  ##     inverted range or a slider that never took the value all break it.
  ##
  ## The read is refusable: `nuSliderValue` returns `(false, _)` when it could
  ## not ask, and that counts as INCONCLUSIVE, never as a pass. Three outcomes.
  if gPfxVerdictSaid:
    return
  if not gPfxBuilt:
    if gPfxOff:
      gPfxVerdictSaid = true
      warn "postfx rows VERDICT FAIL: nothing was ever built -- " & $gPfxTried &
           " attempt(s), " & $gPfxFaults & " fault(s), the feature has " &
           "self-disabled. The PostFX panel is the empty stock panel. See the " &
           "fault line above for which hop refused."
    return
  var good = 0
  var notActive = 0
  var wrongValue = 0
  var wrongWidth = 0
  var overflow = 0
  var incon = 0
  var firstBad = ""
  var firstWide = ""
  var i = 0
  while i < gPfxRowGo.len and i < PfxMaxHandles:
    let go = gPfxRowGo[i]
    if not nuOk(go, 0x10'i32) or not nuAlive(go):
      incon = incon + 1
    elif not nuActiveInHierarchy(go):
      notActive = notActive + 1
      if firstBad.len == 0: firstBad = gPfxRowName[i] & " (not in hierarchy)"
    elif not pfxWidthOk(go, i, firstWide, wrongWidth, overflow):
      # Counted inside `pfxWidthOk` so the two width failures stay distinct:
      # "does not match the stock donor" and "runs off the end of the panel"
      # have different causes and only the second is visible to the player.
      discard
    elif gPfxRowSlider[i] != nil:
      let (rOk, v) = nuSliderValue(gPfxRowSlider[i])
      if not rOk:
        incon = incon + 1
      elif v - gPfxRowWant[i] > 0.01'f32 or gPfxRowWant[i] - v > 0.01'f32:
        wrongValue = wrongValue + 1
        if firstBad.len == 0:
          firstBad = gPfxRowName[i] & " (asked " & nuF(gPfxRowWant[i]) &
                     ", the live slider reads " & nuF(v) & ")"
      else:
        good = good + 1
    else:
      good = good + 1
    i = i + 1
  gPfxVerdictSaid = true
  if good == 0:
    warn "postfx rows VERDICT FAIL: 0 of " & $gPfxRowGo.len & " prefab row(s) " &
         "read back as a live, in-hierarchy row with the value it was given (" &
         $notActive & " not activeInHierarchy, " & $wrongValue &
         " value did not take, " & $incon & " unreadable). First: " &
         (if firstBad.len > 0: firstBad else: "none named") &
         ". The panel is still blank to the player even though the build " &
         "reported success -- that gap is why this reads the live objects."
  elif notActive > 0 or wrongValue > 0 or wrongWidth > 0 or overflow > 0:
    warn "postfx rows VERDICT FAIL: " & $good & " of " & $gPfxRowGo.len &
         " row(s) are good, but " & $notActive & " are not activeInHierarchy, " &
         $wrongValue & " read back a value that is not the one they were " &
         "given, " & $wrongWidth & " do not match the stock donor's width and " &
         $overflow & " are WIDER THAN THE PANEL and therefore clipped. " &
         "First value problem: " &
         (if firstBad.len > 0: firstBad else: "none") &
         ". First width problem: " &
         (if firstWide.len > 0: firstWide else: "none") &
         ". A partially wrong page is still the reported bug."
  elif incon > 0:
    warn "postfx rows VERDICT INCONCLUSIVE: " & $good & " row(s) read back " &
         "correctly, but " & $incon & " of " & $gPfxRowGo.len & " could not " &
         "be read at all, so the page was not fully observed. NOT a pass."
  else:
    okLog "postfx rows VERDICT PASS: " & $good & " of " & $gPfxRowGo.len &
          " native prefab row(s) read back activeInHierarchy; NONE is wider " &
          "than the " & nuF(gPfxParentW) & " row container (so nothing is " &
          "clipped) and every one matches the geometry copied from the stock " &
          "donor row -- " & nuGeomNote(gPfxGeom) & " -- read from get_rect " &
          "off the live RectTransform; and every float row's inner NumberSlider " &
          "reports the value it was given when asked through CurrentValue() " &
          "-- a different method than the one that wrote it. " & $gPfxDeclined.len & " setting(s) have NO row at all " &
          "and that is deliberate, not a failure: their kind is a dropdown, " &
          "whose binds are generic and have no offline address."

proc pfxOnPanelUp(postUp: bool) =
  ## Called every tick from `gfxTickBody`, inside its existing guard. The
  ## steady state is two boolean tests.
  ##
  ## THE VALUE BINDING'S TICK, above every gate here on purpose. It owns the
  ## write queue (the shared POST slot is single, so exactly one write is
  ## released per tick) and the two verdicts, and neither has anything to do
  ## with whether the PostFX panel happens to be up. Its own gate is one
  ## boolean compare when `settingsRowsBind` is off.
  sbdTick()
  if not gPfxOn or gPfxOff:
    return
  if not postUp:
    return
  if not gPfxBuilt:
    if gPfxTried < 4:
      discard pfxBuild()
    return
  # DEFECT 3, polled. One toggle read per frame; the 26 writes only on the
  # edge. It runs BEFORE the row verdict so that a gray-out fault is reported
  # against the same frame it happened in.
  pfxGrayTick()
  if gPfxScrollJudge > 0:
    gPfxScrollJudge = gPfxScrollJudge - 1
    if gPfxScrollJudge == 0:
      pfxScrollVerdict(gPfxScrollJudgeRoot)
  pfxVerdict()

proc pfxOnScreenClosed() =
  ## The settings screen went away. Re-arm the verdict so the NEXT visit prints
  ## a fresh one, and drop our rows if the container they were parented to has
  ## been destroyed under us. We own these rows outright (they are NOT in the
  ## tab's `_createdControls`), so nothing else will ever clean them up.
  gPfxVerdictSaid = false
  gPfxScrollSaid = false
  gPfxGraySaid = false
  # The scroll host is ours and lives under the PostFX panel; if that panel is
  # gone the clone went with it, so the handle must not survive as a pointer
  # into a destroyed object. Dropped BEFORE the row tear-down below, because
  # `pfxDestroyAll` re-arms the build and a stale handle would make
  # `pfxScrollify` return "already done" on a host that no longer exists.
  if gPfxScrollGo != nil and (not duOk(gPfxScrollGo, 0x20'i32) or
                              not iUnityAlive(gPfxScrollGo)):
    # PUT THE TAB'S FIELD BACK FIRST. `_settingsRoot@0xa0` was repointed at the
    # clone's Content; with the clone gone, that field names a destroyed object
    # and the game's own `CreateControls` would parent stock rows into it.
    let tab2 = pfxTab()
    if tab2 != nil and gPfxOrigRootT != nil and
       nuOk(tab2, PfxOffSettingsRoot + 8'i32):
      discard cNuSetRef(tab2, PfxOffSettingsRoot, gPfxOrigRootT)
      warn "postfx rows: the scroll host was destroyed under us; " &
           "PostFXSettingsTab._settingsRoot@0xa0 has been put back to the " &
           "authored SettingsPanel so the game's own CreateControls cannot " &
           "parent stock rows into a dead object."
    gPfxScrollGo = nil
    gPfxScrollHostT = nil
    gPfxScrollContentT = nil
    gPfxScrollBarT = nil
  if gPfxBuilt and (gGfxPostGo == nil or not duOk(gGfxPostGo, 0x20'i32) or
                    not iUnityAlive(gGfxPostGo)):
    let n = pfxDestroyAll()
    okLog "postfx rows: the PostFX panel was destroyed under us; " & $n &
          " row(s) of ours were torn down and will be rebuilt on the next " &
          "visit. Nothing stale is left parented into a dead object."
