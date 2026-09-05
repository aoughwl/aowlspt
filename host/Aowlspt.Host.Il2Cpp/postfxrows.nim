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
const PfxOffCtrlTipHover = 0x98'i32  ## SettingControl._tooltipSettingsHover
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
var gPfxPanelUpNow = false         ## this tick's `postUp`, for the build to read
var gPfxGraftDeferred = false      ## rows built hidden; the graft waits for panel-up
var gPfxGraftTab: Il2CppPtr = nil
var gPfxGraftParent: Il2CppPtr = nil
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
## ---- defect 1: the DONOR's authored inset ------------------------------
## v2 STRETCHED the clone's Viewport to fill the whole clone root, on the
## reasoning that the donor's centred 750-wide viewport was "the inset box the
## user saw". That was wrong, and the user's screen said so: the donor keeps
## its Viewport 750 wide and centred *precisely so that the Scrollbar has a
## right margin to live in*. Filling the root put the viewport under the
## scrollbar, so the bar draws straight through the slider values at the far
## right. The authored inset is restored VERBATIM from the donor -- read off
## the live Graphics SettingsList, never a constant -- and the donor Viewport
## transform is kept so the verdict can re-read its width from the DONOR
## rather than from anything we wrote.
var gPfxDonorVpT: Il2CppPtr = nil
var gPfxDonorVpG = nuNoGeom()
var gPfxDonorBarG = nuNoGeom()
## ---- defect 2: the background ------------------------------------------
## The scroll area had no background because the node that drew it was the
## `SettingsPanel` we retired (or a child of it that went down with it).
## Which node it actually is is MEASURED at graft time by a census, never
## assumed; `gPfxBgWhy` is that census, verbatim, so a run that found nothing
## says what it looked at.
var gPfxBgT: Il2CppPtr = nil
var gPfxBgWhy = ""
## ---- the layout driver on 'Panel' ---------------------------------------
## MEASURED LIVE on 6bd304e3 (host log 09:5x, line 1209): the graft applied
## with the clone root at 850x729.1, and by the panel's first ACTIVE frame the
## SAME root read **850.0x0.0**. Nothing of ours wrote that: the PostFX
## 'Panel' drives its children, and our clone root -- a `SettingsList` whose
## only ILayoutElement is a ScrollRect, which reports no preferred height --
## is measured as 0 and squashed. The authored `SettingsPanel` was not,
## because of whatever ILayoutElement IT carries.
##
## `LayoutElement.ignoreLayout = true` is the ONE lever available here without
## an ABI-header change (`NuTLayoutElemIgnore` @49 is the PROPERTY, so it also
## calls `LayoutElement::SetDirty`; there is no float writer in
## `aowlspt_nativeui.h` and adding one drops every cache while another agent
## is editing that header). A child that opts out of the group keeps the rect
## we gave it, which is the AUTHORED SettingsPanel rect, verbatim.
##
## And because "the group re-ran and squashed us again" is a thing that can
## happen no matter what we set, the root's height is RE-READ every active
## frame and re-asserted a bounded number of times -- read, compare, write,
## never blind, and it gives up loudly rather than fighting forever.
const
  PfxLeIgnore  = 0x20'i32   ## UnityEngine.UI.LayoutElement.m_IgnoreLayout (bool)
  PfxLeMinW    = 0x24'i32   ## ...m_MinWidth
  PfxLeMinH    = 0x28'i32   ## ...m_MinHeight
  PfxLePrefW   = 0x2c'i32   ## ...m_PreferredWidth
  PfxLePrefH   = 0x30'i32   ## ...m_PreferredHeight
  PfxLeFlexW   = 0x34'i32   ## ...m_FlexibleWidth
  PfxLeFlexH   = 0x38'i32   ## ...m_FlexibleHeight
  ## every one MEASURED: `python tools/fldoff.py fields UnityEngine.UI.LayoutElement`
  PfxMaxReassert = 8
var gPfxReassert = 0
var gPfxReassertSaid = false
var gPfxLayoutNote = ""

## FORWARD DECLARATIONS into `nativepostfx.nim`, which is `include`d AFTER this
## file. Exactly the device -- and exactly the seam shape -- `modstab.nim` uses
## to reach `pfxOnPanelUp` / `pfxOnScreenClosed` from one include earlier.
##
## Two entry points and nothing else crosses the boundary: no `gNpf*` global is
## named here and no state is shared. This file owns the LEGACY rows for
## `mods/graphics`; that file owns the NATIVE rows that drive the game's own
## pipeline. Neither reaches into the other's state, and neither gates the
## other -- see the call site in `pfxOnPanelUp` for why that independence is
## load-bearing rather than tidy.
proc npfOnPanelUp(postUp: bool)
proc npfOnScreenClosed()

## ---- defect 3: the flash ------------------------------------------------
## `Time.frameCount` at the graft, and at the FIRST frame the PostFX panel was
## observed active. The page flashed because the graft ran on the first
## panel-up tick, i.e. after the stock layout had already rendered. The only
## honest finished-state check is the ordering of those two numbers.
var gPfxGraftFrame = -1
var gPfxFirstActiveFrame = -1
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
    ## THE TOOLTIP BODY, transcribed from the `description =` argument of the
    ## matching entry in `mods/graphics/graphics.nim:schema()` -- the same text
    ## the settings-hub page shows. A STATIC MIRROR, exactly like the ranges
    ## above: it drifts if that file changes and nothing here pretends
    ## otherwise. The shared "aowlspt original (native D3D11 post-process)"
    ## preamble every schema entry carries is dropped -- it is identical on all
    ## 29 and says nothing about the row -- and every body is kept well under
    ## the 512-character intern cap (`AOWL_NU_MAX_INTERN_LEN`), which is the
    ## limit that SILENTLY refused four DLSS tooltip bodies on 2026-09-04.
    tip*: string

proc pfxF(label, key: string; owned: bool; lo, hi, def: float32;
          tip: string = ""): PfxRow =
  PfxRow(kind: pkSlider, label: label, key: key, presetOwned: owned,
         lo: lo, hi: hi, def: def, tip: tip)

proc pfxB(label, key: string; owned: bool; tip: string = ""): PfxRow =
  PfxRow(kind: pkToggle, label: label, key: key, presetOwned: owned,
         lo: 0.0'f32, hi: 0.0'f32, def: 0.0'f32, tip: tip)

proc pfxE(label, key: string; tip: string = ""): PfxRow =
  PfxRow(kind: pkChoice, label: label, key: key, presetOwned: false,
         lo: 0.0'f32, hi: 0.0'f32, def: 0.0'f32, tip: tip)

proc pfxCatalogue(): seq[PfxRow] =
  ## The 29 settings `mods/graphics/graphics.nim:schema()` declares, with the
  ## kind, range and default it declares for each. A STATIC MIRROR -- the
  ## schema fetch that would make it live is blocked (see the header) -- so it
  ## will drift if the mod's schema changes.
  ##
  ## Ordered by the schema's own category, and WITHOUT category headers: a
  ## settings tab has no header prefab, and inventing one out of a label would
  ## be exactly the from-scratch construction this change exists to remove.
  @[pfxE("Preset", "preset",
          "A finished look in one word. While this is anything but " &
          "'custom' it OWNS every look slider below and they are " &
          "ignored -- pick 'custom' to drive them yourself. neutral = " &
          "cleanup only; filmic = the default look; cold-clinical = " &
          "visibility first (no bloom, no vignette, shadows pulled " &
          "open); warm-cinematic = the screenshot look; night-owl = " &
          "dark interiors and night raids."),
    pfxB("Enable post-process", "enabled", false,
          "Master switch. Off = the game renders untouched."),
    pfxB("Raid only (menu stays stock)", "raidOnly", false,
          "Grade only in-raid; the menu and 2D UI stay stock. Off = " &
          "grade everywhere (also needed if you run without the " &
          "backend, which is what supplies the raid signal)."),
    pfxE("Tonemapper", "tonemapper",
          "0 none, 1 AgX (filmic, neutral highlights), 2 ACES."),
    pfxF("Tonemap strength", "tonemapStrength", true, 0.0'f32, 1.0'f32, 0.85'f32,
          "Blend of the tonemap look over the linear image."),
    pfxF("Exposure (EV)", "exposure", true, -3.0'f32, 3.0'f32, 0.0'f32,
          "EV bias applied before the tonemap."),
    pfxF("Contrast", "contrast", true, 0.5'f32, 1.8'f32, 1.05'f32,
          "Contrast around 18% mid-grey, in linear."),
    pfxF("Saturation", "saturation", true, 0.0'f32, 2.0'f32, 1.05'f32,
          "0 greyscale, 1 neutral, above 1 vivid."),
    pfxF("Vibrance", "vibrance", true, 0.0'f32, 1.0'f32, 0.35'f32,
          "Saturation weighted by how unsaturated a pixel already is. " &
          "Gains colour separation without turning foliage neon, which " &
          "a flat saturation multiplier does. Free (no extra taps)."),
    pfxF("Shadow detail (toe lift)", "shadowDetail", true, 0.0'f32, 1.0'f32, 0.35'f32,
          "Re-lifts ONLY the toe after contrast, so raising contrast " &
          "does not cost you the ability to see a player standing in a " &
          "doorway. Free."),
    pfxF("Temperature", "temperature", true, -1.0'f32, 1.0'f32, 0.0'f32,
          "Cool (-) to warm (+)."),
    pfxF("Tint", "tint", true, -1.0'f32, 1.0'f32, 0.0'f32,
          "Green (-) to magenta (+)."),
    pfxF("Lift (shadows)", "lift", true, -0.2'f32, 0.2'f32, 0.0'f32,
          "Lift, Gamma, Gain: the SHADOW end of the classic three-way " &
          "grade."),
    pfxF("Gamma (midtones)", "gamma", true, 0.5'f32, 1.8'f32, 1.0'f32,
          "Lift, Gamma, Gain: the MIDTONE end of the classic three-way " &
          "grade."),
    pfxF("Gain (highlights)", "gain", true, 0.5'f32, 1.8'f32, 1.0'f32,
          "Lift, Gamma, Gain: the HIGHLIGHT end of the classic " &
          "three-way grade."),
    pfxF("Shadow lift (additive)", "shadows", true, -0.2'f32, 0.2'f32, 0.0'f32,
          "From TarkovGraphics (the original's grade knob), " &
          "reimplemented in aowlspt's native post-process. Matches the " &
          "original TarkovGraphics shadow knob."),
    pfxF("Highlight roll-off", "highlights", true, 0.5'f32, 2.0'f32, 1.1'f32,
          "From TarkovGraphics (the original's grade knob), " &
          "reimplemented in aowlspt's native post-process. Pre-tonemap " &
          "highlight compression."),
    pfxF("Sharpening (CAS)", "sharpness", true, 0.0'f32, 1.0'f32, 0.35'f32,
          "Contrast-adaptive sharpening, applied after the grade."),
    pfxB("Bloom", "bloom", true,
          "Bloom on or off."),
    pfxF("Bloom strength", "bloomStrength", true, 0.0'f32, 2.0'f32, 0.35'f32,
          "How much of the bright pass is added back over the frame."),
    pfxF("Bloom threshold", "bloomThreshold", true, 0.0'f32, 1.0'f32, 0.70'f32,
          "Luma knee for the bright pass. Raise it so only real light " &
          "sources bloom."),
    pfxF("Vignette", "vignette", true, 0.0'f32, 1.0'f32, 0.18'f32,
          "Corner darkening strength."),
    pfxF("Vignette radius", "vignetteRadius", true, 0.5'f32, 1.5'f32, 1.0'f32,
          "How far in from the corners the vignette begins."),
    pfxF("Clarity (local contrast)", "clarity", true, 0.0'f32, 1.0'f32, 0.30'f32,
          "Wide-radius local contrast. This is what makes a flat, hazy " &
          "frame read as three-dimensional. Costs 4 texture taps; " &
          "masked to mid-tones so it cannot crush blacks or blow " &
          "highlights."),
    pfxF("Film grain", "grain", true, 0.0'f32, 1.0'f32, 0.18'f32,
          "Animated, weighted toward the shadows -- where real grain " &
          "lives and where banding lives. Free."),
    pfxF("Grain size (px)", "grainSize", true, 1.0'f32, 4.0'f32, 1.5'f32,
          "Grain cell size, in pixels."),
    pfxF("Output dither (LSB)", "dither", true, 0.0'f32, 2.0'f32, 1.0'f32,
          "Triangular-PDF noise at about 1 least-significant bit before " &
          "the 8-bit write. The cheapest real win here: it is the only " &
          "thing that kills banding in dark interiors. Leave it on."),
    pfxF("Chromatic aberration", "chroma", true, 0.0'f32, 1.0'f32, 0.0'f32,
          "Radial, red/blue only, exactly zero at the screen centre so " &
          "it never smears what you are aiming at. Off by default. " &
          "Costs 2 texture taps."),
    pfxB("Red-tint diagnostic", "diag", false,
          "Tints the frame red to confirm the blit lands.")]

## Parallel to `gPfxRowGo`: the tooltip body each row should show, and the row
## KIND. Both are needed after the build loop -- the tooltip pass because the
## catalogue is not re-walked there, and the alignment pass because only the
## toggle rows are touched and re-deriving "is this a toggle" from the live
## object would be a guess where the catalogue already holds the fact.
##
## Declared here rather than beside `gPfxRowCtrl` for one boring reason:
## `PfxKind` is declared below that point and Nim needs the type first.
var gPfxRowTip: seq[string] = @[]
var gPfxRowKind: seq[PfxKind] = @[]

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

proc pfxFrameNow(): int32 =
  ## `UnityEngine.Time::get_frameCount`, through invoke2's byte-verified table
  ## (`Mi2FrameCount`). Returns -1 when the target is not bound, which is an
  ## honest "unknown" -- the flash check reports INCONCLUSIVE on it rather than
  ## inventing an ordering.
  result = -1'i32
  let fn = mi2Fn(Mi2FrameCount)
  if fn == nil: return
  result = cMi2CallIV(fn)

proc pfxApplyGeom(rt: Il2CppPtr; g: NuGeom): bool =
  ## Copy one RectTransform's WHOLE authored layout onto another. Used only to
  ## put the donor's own numbers on the clone's Viewport and Scrollbar; the
  ## values are read live off the donor, so no constant of ours is involved
  ## and it is resolution-independent.
  result = false
  if rt == nil or not g.ok: return
  result = nuLayout(rt, g.aMinX, g.aMinY, g.aMaxX, g.aMaxY,
                    g.pivX, g.pivY, g.sdX, g.sdY, g.posX, g.posY)

proc pfxHasImage(t: Il2CppPtr): bool =
  ## Does this node DRAW? `Image` is the only Graphic the settings panels use
  ## for their flat backgrounds. Asked through `GetComponent(String)`, which
  ## works on an inactive node.
  if t == nil or not duOk(t, 0x20'i32) or not iUnityAlive(t): return false
  modsComponent(t, "Image") != nil

proc pfxBackground(panelT, rowParent, cloneT: Il2CppPtr): bool =
  ## DEFECT 1 OF THIS ROUND: there is no background behind the scroll area.
  ##
  ## The census is run FIRST and recorded whole, because "which node draws the
  ## dark background" is a measurement, not something this file may assume --
  ## and the three plausible answers need three different actions:
  ##
  ##   a. the PostFX 'Panel' itself (or a child of it that is NOT the
  ##      SettingsPanel) already draws it -> do NOTHING. Reparenting a
  ##      background that is already behind the clone would only reorder it.
  ##   b. a 'Background' child of the retired SettingsPanel draws it -> move
  ##      that node into the clone root, first sibling (so it draws BEHIND the
  ##      viewport) and stretched to the root.
  ##   c. the SettingsPanel ITSELF carries the Image -> do not retire it. It
  ##      is already a SIBLING of the clone under 'Panel', so it is kept
  ##      ACTIVE and pushed to sibling 0; emptied of rows it is exactly a
  ##      background quad, which is what the Graphics page has.
  ##
  ## Returns TRUE when the SettingsPanel must be KEPT ACTIVE (case c) -- the
  ## caller retires it otherwise.
  result = false
  gPfxBgT = nil
  var note = ""
  let panelImg = pfxHasImage(panelT)
  let rootImg = pfxHasImage(rowParent)
  let bgChild = modsChildNamed(rowParent, "Background")
  let bgChildImg = pfxHasImage(bgChild)
  let panelBg = modsChildNamed(panelT, "Background")
  let panelBgImg = pfxHasImage(panelBg)
  note = "'Panel' Image=" & (if panelImg: "YES" else: "no") &
         ", 'Panel'/Background=" &
         (if panelBg == nil: "absent"
          elif panelBgImg: "present WITH Image" else: "present, no Image") &
         ", SettingsPanel Image=" & (if rootImg: "YES" else: "no") &
         ", SettingsPanel/Background=" &
         (if bgChild == nil: "absent"
          elif bgChildImg: "present WITH Image" else: "present, no Image")
  if panelImg or panelBgImg:
    gPfxBgT = (if panelImg: panelT else: panelBg)
    gPfxBgWhy = note & " -> the PostFX panel ALREADY draws its own " &
                "background behind the clone; nothing was moved."
    return
  if bgChildImg:
    let bgGo = iGameObjectOf(bgChild)
    if bgGo != nil and nuParentTransform(bgChild, cloneT, false) and
       nuLayout(bgChild, 0.0'f32, 0.0'f32, 1.0'f32, 1.0'f32,
                0.5'f32, 0.5'f32, 0.0'f32, 0.0'f32, 0.0'f32, 0.0'f32):
      discard modsSetFirstSibling(bgChild)
      discard modsSetActive(bgGo, true)
      gPfxBgT = bgChild
      gPfxBgWhy = note & " -> that Background node was MOVED into the clone " &
                  "root, stretched to it and pushed to sibling 0 so it draws " &
                  "behind the viewport."
      return
    gPfxBgWhy = note & " -> the Background child was found but could not be " &
                "reparented or laid out, so the scroll area has NO background."
    return
  if rootImg:
    # ONLY safe as a "draw behind the clone" if the two really are siblings.
    # Sibling index is an ordering among ONE parent's children and says
    # nothing across parents, so this is checked rather than assumed.
    let par = modsParentOf(rowParent)
    let sameParent = (par != nil and par == panelT)
    gPfxBgT = rowParent
    if sameParent: discard modsSetFirstSibling(rowParent)
    gPfxBgWhy = note & " -> the SettingsPanel itself carries the Image, so it " &
                "is KEPT ACTIVE (emptied of rows it is exactly a background " &
                "quad)" &
                (if sameParent: " and pushed to sibling 0 under 'Panel', so " &
                   "it draws behind the clone."
                 else: ", but its parent is '" & iObjName(par) &
                   "', not the 'Panel' the clone sits under -- sibling order " &
                   "cannot be used to put it behind, so its draw order is " &
                   "whatever the tree already gives it.")
    return true
  gPfxBgWhy = note & " -> NO node with an Image was found on either panel, " &
              "so nothing draws the scroll area's background and this run " &
              "cannot supply one. Reported, not hidden."

proc pfxLeNote(t: Il2CppPtr): string =
  ## One LayoutElement, READ ONLY, at MEASURED offsets. Never written here.
  ## A node with no LayoutElement is stated as such -- that is the interesting
  ## answer, not a blank.
  if t == nil: return "node absent"
  let le = modsComponent(t, "LayoutElement")
  if le == nil: return "no LayoutElement"
  if not nuOk(le, PfxLeFlexH + 4'i32): return "LayoutElement UNREADABLE"
  var okI = 0'i32
  let ign = cNuGetI32(le, PfxLeIgnore, okI)
  var o1 = 0'i32
  var o2 = 0'i32
  var o3 = 0'i32
  var o4 = 0'i32
  var o5 = 0'i32
  var o6 = 0'i32
  let mw = cNuGetF32(le, PfxLeMinW, addr o1)
  let mh = cNuGetF32(le, PfxLeMinH, addr o2)
  let pw = cNuGetF32(le, PfxLePrefW, addr o3)
  let ph = cNuGetF32(le, PfxLePrefH, addr o4)
  let fw = cNuGetF32(le, PfxLeFlexW, addr o5)
  let fh = cNuGetF32(le, PfxLeFlexH, addr o6)
  if okI == 0 or o1 == 0 or o2 == 0 or o3 == 0 or o4 == 0 or o5 == 0 or
     o6 == 0:
    return "LayoutElement present but a field read was refused"
  "LayoutElement ignoreLayout=" &
    (if (ign and 0xff'i32) != 0'i32: "true" else: "false") &
    " min=(" & nuF(mw) & "," & nuF(mh) & ") preferred=(" & nuF(pw) & "," &
    nuF(ph) & ") flexible=(" & nuF(fw) & "," & nuF(fh) & ")"

proc pfxDrivers(t: Il2CppPtr): string =
  ## WHICH components on this node can drive a child's rect. Asked by name
  ## through GetComponent, which works on an inactive node.
  if t == nil: return "absent"
  var parts = ""
  if modsComponent(t, "VerticalLayoutGroup") != nil:
    parts = parts & "VerticalLayoutGroup "
  if modsComponent(t, "HorizontalLayoutGroup") != nil:
    parts = parts & "HorizontalLayoutGroup "
  if modsComponent(t, "GridLayoutGroup") != nil:
    parts = parts & "GridLayoutGroup "
  if modsComponent(t, "ContentSizeFitter") != nil:
    parts = parts & "ContentSizeFitter "
  if parts.len == 0: parts = "no layout driver "
  parts & "| " & pfxLeNote(t)

proc pfxLayoutCensus(panelT, rowParent, cloneT, enableT: Il2CppPtr): string =
  ## THE MEASUREMENT the 850x0 defect needed and did not have. Read-only, run
  ## once at graft time, printed whole -- so the next person does not have to
  ## deduce which node squashed the clone.
  "'Panel' -> " & pfxDrivers(panelT) & " ;; authored SettingsPanel -> " &
    pfxDrivers(rowParent) & " ;; 'EnablePanel' -> " & pfxDrivers(enableT) &
    " ;; our clone root -> " & pfxDrivers(cloneT)

proc pfxOptOutOfGroup(t: Il2CppPtr; who: string; note: var string): bool =
  ## `LayoutElement.ignoreLayout = true` through the PROPERTY, so the parent
  ## group re-runs without this child. Returns false when the node has no
  ## LayoutElement at all -- which is not a failure of ours, but it IS the
  ## reason the group can still squash it, so the caller says so out loud.
  result = false
  if t == nil:
    note = note & who & ": node absent. "
    return
  let le = modsComponent(t, "LayoutElement")
  if le == nil:
    note = note & who & ": NO LayoutElement, so it cannot opt out of the " &
           "parent group and the group is free to size it (this is the " &
           "850x0 defect's mechanism). "
    return
  if nuSetIgnoreLayout(le, true):
    note = note & who & ": ignoreLayout=true through the property (SetDirty " &
           "ran, so the group re-laid out without it). "
    result = true
  else:
    note = note & who & ": set_ignoreLayout was REFUSED. "

proc pfxReassertRoot() =
  ## THE FINISHED-STATE REPAIR, bounded. Read the root's live height, compare
  ## it with the AUTHORED height, and only then write. A group that re-runs
  ## after we opted out would squash us again; this notices, repairs it a
  ## bounded number of times, and then reports rather than fighting forever.
  if gPfxScrollHostT == nil or not gPfxOrigGeom.ok: return
  if gPfxReassert >= PfxMaxReassert:
    if not gPfxReassertSaid:
      gPfxReassertSaid = true
      warn "postfx rows: the scroll host's height has been re-asserted " &
           $PfxMaxReassert & " times and the layout keeps overriding it. " &
           "GIVING UP rather than writing every frame. Census at graft: " &
           gPfxLayoutNote
    return
  let g = nuReadGeom(gPfxScrollHostT)
  if not g.ok: return
  let dh = g.rectH - gPfxOrigGeom.rectH
  if dh <= 1.0'f32 and dh >= -1.0'f32: return
  gPfxReassert = gPfxReassert + 1
  let did = pfxApplyGeom(gPfxScrollHostT, gPfxOrigGeom)
  var bgDid = false
  if gPfxBgT != nil and gPfxBgT == gPfxOrigRootT:
    bgDid = pfxApplyGeom(gPfxBgT, gPfxOrigGeom)
  warn "postfx rows: the scroll host read " & nuF(g.rectW) & "x" &
       nuF(g.rectH) & " against the AUTHORED " & nuF(gPfxOrigGeom.rectW) &
       "x" & nuF(gPfxOrigGeom.rectH) & " -- something in the parent chain " &
       "re-sized it. Re-asserted (" & $gPfxReassert & " of " &
       $PfxMaxReassert & "): root " & (if did: "rewritten" else: "REFUSED") &
       (if gPfxBgT != nil and gPfxBgT == gPfxOrigRootT:
          ", background quad " & (if bgDid: "rewritten" else: "REFUSED")
        else: "") & "."

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


# ---------------------------------------------------------------------------
# THE SCROLL HOST, EXTRACTED SO THERE IS EXACTLY ONE OF IT.
#
# `pfxScrollify` (defect 2, v3) is the only thing that has ever built a working
# scroll region in this screen, and the mods pages need the identical structure
# -- 949 rows on `aowl.tarkov` are simply unreachable in a fixed-height panel.
# A SECOND COPY of this would be a second set of geometry rules to get wrong,
# and the two would drift the first time either was fixed. So the generic core
# is here and BOTH callers use it: the PostFX graft below, and
# `swScrollHostFor` (settingspages.nim) for every mods page.
#
# What is generic: find the Graphics `SettingsList` donor, clone it, parent it
# under `hostGo`, give the clone root the AUTHORED rect `og`, give its Viewport
# the donor's authored inset (so the scrollbar keeps its margin), opt the root
# out of the parent layout group, retire the donor's own rows, and hand back
# the clone's `Content` -- the node that already carries the VerticalLayoutGroup
# and ContentSizeFitter that DRIVE height.
#
# What is NOT generic and stays with each caller: which rows move in, which
# managed field is repointed at the Content, and the background-quad decision.
#
# Every refusal is returned as text rather than routed through
# `pfxGraftRefuse`, because that charges the PostFX feature's fault budget and
# a mods-page failure must not disable the PostFX rows.
# ---------------------------------------------------------------------------
proc pfxScrollHostMake(gfxT, hostGo: Il2CppPtr; og: NuGeom;
                       censusPanelT, censusRowT: Il2CppPtr;
                       cloneGoOut, cloneTOut, srOut, viewportTOut,
                       contentTOut: var Il2CppPtr;
                       optNoteOut: var string; retiredOut: var int;
                       why: var string): bool =
  result = false
  cloneGoOut = nil; cloneTOut = nil; srOut = nil
  viewportTOut = nil; contentTOut = nil
  retiredOut = 0
  why = ""
  var donorT = modsChildNamed(modsChildNamed(gfxT, "Other Settings"),
                              "SettingsList")
  if donorT == nil:
    donorT = modsFindNamed(gfxT, "SettingsList", 4)
  if donorT == nil or not duOk(donorT, 0x20'i32) or not iUnityAlive(donorT):
    why = ("the Graphics page's 'SettingsList' (the ScrollRect donor) " &
                 "could not be reached by walking 'Graphics Settings' -> " &
                 "'Other Settings' -> 'SettingsList', nor found by name " &
                 "within 4 levels. Nothing was cloned.")
    return
  # THE DONOR'S AUTHORED INSET, read BEFORE anything is cloned. The Graphics
  # page keeps its Viewport narrower than its list root and puts the Scrollbar
  # in the margin that leaves; taking those two rects off the live donor is
  # the whole of defect 1's fix, and it is a measurement, not a constant.
  gPfxDonorVpT = modsChildNamed(donorT, "Viewport")
  gPfxDonorVpG = nuReadGeom(gPfxDonorVpT)
  gPfxDonorBarG = nuReadGeom(modsChildNamed(donorT, "Scrollbar"))
  if modsComponent(donorT, "ScrollRect") == nil:
    why = ("the node found as the Graphics 'SettingsList' carries no " &
                 "ScrollRect, so it is NOT the scroll host and cloning it " &
                 "would graft a container that cannot scroll. Refused.")
    return
  let donorGo = iGameObjectOf(donorT)
  if hostGo == nil or donorGo == nil:
    why = ("the host GameObject the scroll region must be parented " &
                 "under, or the donor SettingsList's own GameObject, is not " &
                 "reachable -- so there is nowhere to put a scroll host and " &
                 "nothing to clone. The page is untouched.")
    return
  let cloneGo = modsClone(donorGo)
  let cloneT = (if cloneGo != nil: modsTransformOf(cloneGo) else: nil)
  if cloneGo == nil or cloneT == nil:
    why = ("Object::Instantiate of the Graphics SettingsList returned " &
                 "null or a clone with no reachable Transform. Nothing is " &
                 "parented anywhere.")
    return
  if not modsSetParent(cloneGo, hostGo):
    why = ("the cloned SettingsList could not be parented under the " &
                 "PostFX 'Panel'. It is destroyed rather than left at the " &
                 "scene root, where it would render over the screen.")
    discard nuDestroy(cloneGo)
    return
  # (1) THE CLONE ROOT BECOMES THE AUTHORED PANEL, exactly.
  if not nuLayout(cloneT, og.aMinX, og.aMinY, og.aMaxX, og.aMaxY,
                  og.pivX, og.pivY, og.sdX, og.sdY, og.posX, og.posY):
    why = ("the authored SettingsPanel geometry could not be applied " &
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
    why = ("the clone is missing " & missing & ", so it cannot host " &
                 "anything. It is destroyed and the PostFX page is left " &
                 "exactly as it was.")
    discard nuDestroy(cloneGo)
    return
  # (2) THE VIEWPORT KEEPS THE DONOR'S AUTHORED INSET -- REVERSED FROM v2.
  #
  # v2 stretched this to fill the clone root, calling the donor's centred
  # 750-wide viewport "the inset box the user saw". MEASURED on the deployed
  # build, by the user's own eyes: the scrollbar then runs straight through
  # the slider values at the far right, because the margin the donor leaves on
  # the right is EXACTLY where the Scrollbar lives. The donor's numbers are
  # re-applied verbatim (the clone already carries them, but writing them
  # explicitly makes the intent auditable and survives any later touch), and a
  # donor whose Viewport cannot be read is a refusal, not a fallback to
  # stretching -- guessing this is what produced the defect.
  if not gPfxDonorVpG.ok:
    why = ("the DONOR Graphics SettingsList's own 'Viewport' rect " &
                 "could not be read, so the authored inset that leaves room " &
                 "for the scrollbar is unknown. Stretching instead is what " &
                 "put the bar through the slider values; refusing. The clone " &
                 "is destroyed.")
    discard nuDestroy(cloneGo)
    return
  if not pfxApplyGeom(viewportT, gPfxDonorVpG):
    why = ("the donor Viewport's authored geometry (" &
                 nuGeomNote(gPfxDonorVpG) & ") could not be applied to the " &
                 "clone's Viewport, so its right margin is not guaranteed " &
                 "and the scrollbar would overlap the rows. The clone is " &
                 "destroyed.")
    discard nuDestroy(cloneGo)
    return
  # (2b) THE PARENT GROUP MUST NOT SIZE THE CLONE ROOT -- MEASURED DEFECT, not
  # a precaution. Census FIRST (read-only, printed whole), then the one lever
  # available: opt the root out of the group and re-apply the authored rect,
  # because `set_ignoreLayout` runs SetDirty and the group re-lays out
  # immediately afterwards.
  if censusPanelT != nil:
    gPfxLayoutNote = pfxLayoutCensus(censusPanelT, censusRowT, cloneT,
                                     modsChildNamed(censusPanelT, "EnablePanel"))
  var optNote = ""
  let rootOpted = pfxOptOutOfGroup(cloneT, "clone root", optNote)
  if rootOpted:
    if not pfxApplyGeom(cloneT, og):
      why = ("the clone root opted out of the parent layout group " &
                   "but its AUTHORED rect could not be re-applied " &
                   "afterwards, so it would keep whatever size the group " &
                   "last gave it -- the 850x0 defect. The clone is destroyed.")
      discard nuDestroy(cloneGo)
      return
  # (4) DONOR ROWS OUT FIRST, so the ContentSizeFitter never sees them plus
  # ours and resolves a 1490 px content that scrolls past the end.
  let retired = pfxRetireKids(contentT)
  cloneGoOut = cloneGo
  cloneTOut = cloneT
  srOut = sr
  viewportTOut = viewportT
  contentTOut = contentT
  optNoteOut = optNote
  retiredOut = retired
  result = true

proc pfxScrollHostFinish(cloneT, contentT: Il2CppPtr;
                         layoutNoteOut: var string; optedOutOut: var int;
                         bouncedOut: var bool; barFixedOut: var bool):
                         Il2CppPtr =
  ## The second half that is equally generic: make the layout actually run on
  ## the cloned Content, clear any authored `ignoreLayout` on the rows now in
  ## it, bounce the Content so `OnEnable -> SetDirty -> MarkLayoutForRebuild`
  ## fires, and give the Scrollbar the donor's authored placement. Returns the
  ## Scrollbar transform (or nil), and reports each outcome through its `var`
  ## parameters rather than asserting any of them.
  ##
  ## CALL THIS AFTER the rows are in `contentT`, never before: the bounce is
  ## what positions them, and a bounce that runs on an empty Content leaves the
  ## rows stacked at the same y -- the exact 82cb47ee defect named below.
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
  # (5) THE SCROLLBAR GETS THE DONOR'S AUTHORED PLACEMENT, verbatim, for the
  # same reason as the Viewport: the bar and the viewport's right margin are
  # ONE authored arrangement and re-deriving either half is how they came to
  # overlap. Nothing is computed here; the verdict then checks the finished
  # state -- every row's right edge strictly left of the bar's left edge.
  let barT = modsChildNamed(cloneT, "Scrollbar")
  var barFixed = false
  if barT != nil and gPfxDonorBarG.ok:
    barFixed = pfxApplyGeom(barT, gPfxDonorBarG)
  layoutNoteOut = layoutNote
  optedOutOut = optedOut
  bouncedOut = bounced
  barFixedOut = barFixed
  result = barT


# ---------------------------------------------------------------------------
# THE MODS-PAGE ENTRY POINT INTO THE SAME SCROLL HOST
#
# `settingspages.nim` forward-declares exactly this one proc. Everything below
# it is `pfxScrollHostMake` / `pfxScrollHostFinish` -- the SAME code the PostFX
# graft runs, not a copy of it -- so a geometry fix lands on both pages at once
# and neither can drift.
#
# WHY A MODS PAGE NEEDS IT AT ALL: `modsindex.nim` now parses a mod's schema
# whole. `aowl.tarkov` is 949 rows. A fixed-height authored panel shows about
# twenty of them and there is no way to reach the rest -- not "below the fold",
# UNREACHABLE. Every page gets a scroll view or the rows do not exist.
# ---------------------------------------------------------------------------
var gSwScrollInit = false
var gSwScrollOn = false            ## `settingsPagesScroll`, DEFAULT OFF
var gSwScrollFaults = 0
const SwScrollFaultCeiling = 3     ## rule 6: self-disable after N faults

proc pfxGraphicsPanelFrom(anchorT: Il2CppPtr; why: var string): Il2CppPtr =
  ## The ScrollRect donor's OWNER panel, reached by WALKING UP from a node the
  ## caller already validated -- never by an offset and never from a cached
  ## global. `gPfxGfxPanelT` exists and is deliberately not used here: it is
  ## nil until the PostFX tick has run, so reading it would make a mods page's
  ## scroll region silently depend on a different feature having been opened
  ## first. That exact dependency is what made the v1 graft fail silently.
  ##
  ## Bounded to 10 hops (rule 4) and every hop validated (rule 2).
  result = nil
  why = ""
  if anchorT == nil or not duOk(anchorT, 0x20'i32) or not iUnityAlive(anchorT):
    why = "the page container's own Transform is not readable, so the walk " &
          "up to the SettingsScreen cannot even start"
    return
  var t = anchorT
  var hops = 0
  while t != nil and hops < 10:
    if duOk(t, 0x20'i32):
      let g = modsChildNamed(t, "Graphics Settings")
      if g != nil and duOk(g, 0x20'i32) and iUnityAlive(g):
        result = g
        return
    t = modsParentOf(t)
    hops = hops + 1
  why = "no ancestor of the page container within " & $hops &
        " hop(s) has a 'Graphics Settings' child, so the SettingsScreen was " &
        "not found and there is no stock ScrollRect to clone. This is a " &
        "REFUSAL, not a fallback: building a scroll region from scratch is " &
        "the geometry that took three attempts to get right on PostFX"

proc swScrollHostFor(anchorT, hostGo: Il2CppPtr; contentGoOut: var Il2CppPtr;
                     note: var string): bool =
  ## Build one page's scroll region and hand back the GameObject rows should be
  ## instantiated into. Returns false with `note` set whenever it cannot -- the
  ## caller renders into the fixed panel and SAYS SO; nothing here pretends.
  ##
  ## Rule 5 (flag-gated, default OFF) and rule 6 (self-disable after N faults)
  ## are both honoured here rather than in the renderer, because this is the
  ## half that clones and reparents live Unity objects.
  result = false
  contentGoOut = nil
  if not gSwScrollInit:
    gSwScrollInit = true
    gSwScrollOn = readBoolKeyDef("settingsPagesScroll", false)
    if gSwScrollOn:
      okLog "settings pages: settingsPagesScroll is ON -- every rendered " &
            "page gets a cloned SettingsList scroll region (the shared v3 " &
            "graft). With it OFF the pages render into the authored " &
            "fixed-height panel exactly as before, and any row past its " &
            "bottom edge is unreachable."
  if not gSwScrollOn:
    note = "settingsPagesScroll is OFF (default), so no scroll region was " &
           "built. This is the flag, not a failure"
    return
  if gSwScrollFaults >= SwScrollFaultCeiling:
    note = "the scroll graft has already declined " & $gSwScrollFaults &
           " time(s) this session and has SELF-DISABLED rather than retry " &
           "on every page"
    return
  if hostGo == nil:
    note = "the page has no host GameObject to parent a scroll region under"
    inc gSwScrollFaults
    return
  var gfxWhy = ""
  let gfxT = pfxGraphicsPanelFrom(anchorT, gfxWhy)
  if gfxT == nil:
    note = gfxWhy
    inc gSwScrollFaults
    return
  # THE CLONE ROOT FILLS THE PAGE CONTAINER. Unlike the PostFX graft there is
  # no authored SettingsPanel whose rect must be reproduced -- the page
  # container IS the space, and the clone is its child, so "fill your parent"
  # is the honest geometry: anchors (0,0)-(1,1), zero inset. A copy of the
  # container's OWN rect would be wrong by construction, because its
  # anchoredPosition is expressed in ITS parent's space, not its own.
  let og = NuGeom(ok: true,
                  aMinX: 0'f32, aMinY: 0'f32, aMaxX: 1'f32, aMaxY: 1'f32,
                  pivX: 0.5'f32, pivY: 0.5'f32,
                  sdX: 0'f32, sdY: 0'f32, posX: 0'f32, posY: 0'f32,
                  rectW: 0'f32, rectH: 0'f32, rectX: 0'f32, rectY: 0'f32)
  var cloneGo: Il2CppPtr = nil
  var cloneT: Il2CppPtr = nil
  var sr: Il2CppPtr = nil
  var viewportT: Il2CppPtr = nil
  var contentT: Il2CppPtr = nil
  var optNote = ""
  var retired = 0
  var why = ""
  if not pfxScrollHostMake(gfxT, hostGo, og, nil, nil,
                           cloneGo, cloneT, sr, viewportT, contentT,
                           optNote, retired, why):
    note = why
    inc gSwScrollFaults
    return
  # `ScrollRect.m_Content@0x20` must name the Content we are about to fill.
  # The clone already names its own Content, so this is a re-assert rather than
  # a repair -- and it is READ before it is written (rule 8), never blind.
  if not nuOk(sr, NuOffScrollContent + 8'i32) or
     cNuSetRef(sr, NuOffScrollContent, contentT) == 0'i32:
    note = "ScrollRect.m_Content@0x20 could not be read or written on the " &
           "cloned SettingsList, so the region would not scroll what we put " &
           "in it. The clone is destroyed and the page is left unscrolled"
    discard nuDestroy(cloneGo)
    inc gSwScrollFaults
    return
  var layoutNote = ""
  var optedOut = 0
  var bounced = false
  var barFixed = false
  # The bounce runs on an EMPTY Content here, which is correct and is the
  # difference from the PostFX caller: those rows were reparented in bulk from
  # a container with no layout group, so they carried stale absolute positions
  # that only a rebuild could fix. These rows do not exist yet -- they are
  # Instantiate'd into the Content one slice at a time, and each Instantiate
  # dirties the group itself. What the bounce buys us here is that the group
  # and the ContentSizeFitter are demonstrably ENABLED before the first row
  # lands, rather than on whatever state the clone inherited.
  let barT = pfxScrollHostFinish(cloneT, contentT, layoutNote, optedOut,
                                 bounced, barFixed)
  let cgo = iGameObjectOf(contentT)
  if cgo == nil:
    note = "the cloned Content has no reachable GameObject, so rows cannot " &
           "be instantiated into it. The clone is destroyed"
    discard nuDestroy(cloneGo)
    inc gSwScrollFaults
    return
  contentGoOut = cgo
  note = $retired & " donor row(s) retired; " & layoutNote & "; scrollbar " &
         (if barT == nil: "NOT FOUND"
          elif barFixed: "given the donor's authored placement"
          else: "left as the clone carried it") &
         "; content bounced=" & (if bounced: "yes" else: "NO") &
         "; opt-out: " & optNote
  result = true

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
  var cloneGo: Il2CppPtr = nil
  var cloneT: Il2CppPtr = nil
  var sr: Il2CppPtr = nil
  var viewportT: Il2CppPtr = nil
  var contentT: Il2CppPtr = nil
  var optNote = ""
  var retired = 0
  var graftWhy = ""
  let panelT = modsChildNamed(postT, "Panel")
  let panelGo = (if panelT != nil: iGameObjectOf(panelT) else: nil)
  if panelT == nil or panelGo == nil:
    pfxGraftRefuse("'PostFX Settings' -> 'Panel' has no reachable " &
                 "GameObject, so there is nowhere to put a scroll host. The " &
                 "page is untouched.")
    return
  if not pfxScrollHostMake(gfxT, panelGo, og, panelT, rowParent,
                           cloneGo, cloneT, sr, viewportT, contentT,
                           optNote, retired, graftWhy):
    pfxGraftRefuse(graftWhy)
    return
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
  # ...UNLESS IT IS THE THING THAT DRAWS THE BACKGROUND. The census runs
  # before the retire and decides which of the three cases this build is in.
  let keepPanel = pfxBackground(panelT, rowParent, cloneT)
  let oldGo = iGameObjectOf(rowParent)
  if oldGo != nil and not keepPanel: discard modsSetActive(oldGo, false)
  # A BACKGROUND QUAD MUST NOT ALSO TAKE LAYOUT SPACE. Kept active inside the
  # same group, the emptied SettingsPanel would be measured a second time and
  # the column's height would double. It opts out too, and is then given the
  # root's rect -- it is now only something that draws.
  if keepPanel:
    discard pfxOptOutOfGroup(rowParent, "kept background SettingsPanel",
                             optNote)
    if not pfxApplyGeom(rowParent, og):
      warn "postfx rows: the kept background SettingsPanel could not be " &
           "given the authored rect back, so the quad behind the scroll " &
           "region may not cover it. The rows are unaffected; this names the " &
           "reason the background may look wrong."
  var layoutNote = ""
  var optedOut = 0
  var bounced = false
  var barFixed = false
  let barT = pfxScrollHostFinish(cloneT, contentT, layoutNote, optedOut,
                                 bounced, barFixed)
  gPfxScrollGo = cloneGo
  gPfxScrollHostT = cloneT
  gPfxScrollContentT = contentT
  gPfxScrollBarT = barT
  gPfxOrigRootT = rowParent
  gPfxOrigGeom = og
  newRootOut = contentT
  gPfxGraftOk = true
  gPfxGraftWhy = ""
  gPfxGraftFrame = int(pfxFrameNow())
  okLog "postfx rows: SCROLL GRAFT (v3) applied at frame " & $gPfxGraftFrame &
        " (panel first seen ACTIVE at frame " &
        (if gPfxFirstActiveFrame >= 0: $gPfxFirstActiveFrame
         else: "NEVER YET -- the panel is still hidden, which is the point") &
        ") -- the clone root was given " &
        "the AUTHORED SettingsPanel rect verbatim (" & nuGeomNote(og) &
        "), its Viewport given the DONOR's authored inset verbatim (" &
        nuGeomNote(gPfxDonorVpG) & ") so the scrollbar keeps its margin, " &
        "background: " & gPfxBgWhy & ". LAYOUT CENSUS: " & gPfxLayoutNote &
        " ;; OPT-OUT: " & optNote & " " & $retired &
        " donor row(s) retired, " & $moved & " row(s) MOVED into the clone's " &
        "own Content (which already carries the LayoutGroup + " &
        "ContentSizeFitter that drive height -- nothing was AddComponent'd), " &
        "and BOTH ScrollRect.m_Content@0x20 and PostFXSettingsTab." &
        "_settingsRoot@0xa0 repointed at it. The emptied SettingsPanel was " &
        (if keepPanel: "KEPT ACTIVE as the background quad (it carries the " &
           "Image), so the Viewport still has exactly one active child -- it " &
           "is a SIBLING of the clone, not a child of the Viewport"
         else: "retired so the Viewport has exactly one active child") &
        ". Scrollbar " &
        (if barT == nil: "NOT FOUND"
         elif barFixed: "given the DONOR's authored placement verbatim (" &
           nuGeomNote(gPfxDonorBarG) & ")"
         else: "left exactly as the clone carried it -- the donor's own bar " &
           "rect was UNREADABLE, so nothing was written to it") &
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
  let rg0 = nuReadGeom(gPfxScrollHostT)
  # 1. THE CLONE ROOT occupies exactly the authored SettingsPanel space. This
  # used to be asked of the VIEWPORT, which is what forced the viewport to be
  # stretched over the scrollbar's margin in the first place: a check that
  # could only be satisfied by the defect. The root is the thing that must
  # replace the panel; the viewport is deliberately narrower than it.
  if gPfxOrigGeom.ok and rg0.ok:
    let dw = rg0.rectW - gPfxOrigGeom.rectW
    let dh = rg0.rectH - gPfxOrigGeom.rectH
    if dw > 1.0'f32 or dw < -1.0'f32 or dh > 1.0'f32 or dh < -1.0'f32:
      fails = fails + 1
      if why.len == 0:
        why = "the scroll host root resolves to " & nuF(rg0.rectW) & "x" &
              nuF(rg0.rectH) & " but the AUTHORED SettingsPanel was " &
              nuF(gPfxOrigGeom.rectW) & "x" & nuF(gPfxOrigGeom.rectH) &
              " -- the scroll region is not the space the panel occupied, " &
              "which is the inset-box defect"
  # 1b. THE VIEWPORT IS AS WIDE AS THE DONOR'S, re-read LIVE off the Graphics
  # page's own Viewport -- a different object than anything we wrote, so this
  # can actually fail. A viewport as wide as its root is the defect the user
  # reported: it leaves the scrollbar no margin and the bar draws through the
  # slider values.
  let dvg = nuReadGeom(gPfxDonorVpT)
  if not dvg.ok:
    warn "postfx rows SCROLL VERDICT: the DONOR Graphics Viewport could not " &
         "be re-read, so 'viewport width == donor viewport width' is " &
         "INCONCLUSIVE -- it is not being counted as a pass. The remaining " &
         "checks still run."
  else:
    let dvw = vg.rectW - dvg.rectW
    if dvw > 1.0'f32 or dvw < -1.0'f32:
      fails = fails + 1
      if why.len == 0:
        why = "the viewport is " & nuF(vg.rectW) & " px wide but the DONOR " &
              "Graphics viewport is " & nuF(dvg.rectW) &
              " px -- the authored inset that leaves room for the scrollbar " &
              "was not reproduced"
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
  # 8. NO ROW IS UNDER THE SCROLLBAR. This is defect 1 stated as the thing the
  # user actually sees, and it is the check that would have failed on the
  # deployed build: every row's RIGHT edge must be strictly left of the bar's
  # LEFT edge. Both are read from live rects and expressed in the CLONE ROOT's
  # coordinate frame -- rows live three levels down (root -> Viewport ->
  # Content -> row), so each hop's offset is composed rather than assumed.
  # `nuChildEdgeInParent` answers in the PARENT's local frame, so converting a
  # frame is (that edge) - (the parent's own rect.x).
  var barLeftRoot = 0.0'f32
  var haveBar = false
  if gPfxScrollBarT != nil and rg0.ok:
    let bg2 = nuReadGeom(gPfxScrollBarT)
    if bg2.ok:
      let (bok2, btop2, bleft2) = nuChildEdgeInParent(rg0, bg2)
      discard btop2
      if bok2:
        barLeftRoot = bleft2
        haveBar = true
  if haveBar and rg0.ok:
    let (vok, vtop, vleft) = nuChildEdgeInParent(rg0, vg)
    discard vtop
    let (cok2, ctop2, cleft2) = nuChildEdgeInParent(vg, cg)
    discard ctop2
    if vok and cok2:
      let offVp = vleft - vg.rectX
      let offCt = (cleft2 - cg.rectX) + offVp
      var under = 0
      var worst = 0.0'f32
      var worstName = ""
      var n2 = 0
      if iChildCount(content, n2):
        var i2 = 0
        while i2 < n2 and i2 < 64:
          let c2 = iChildAt(content, i2)
          if c2 != nil and duOk(c2, 0x20'i32):
            let go2 = iGameObjectOf(c2)
            if go2 != nil and nuActiveInHierarchy(go2):
              let rg2 = nuReadGeom(c2)
              if rg2.ok:
                let (rok2, rtop2, rleft2) = nuChildEdgeInParent(cg, rg2)
                discard rtop2
                if rok2:
                  let right = rleft2 + rg2.rectW + offCt
                  if right > barLeftRoot - 0.5'f32:
                    under = under + 1
                    if right - barLeftRoot > worst:
                      worst = right - barLeftRoot
                      worstName = iObjName(c2)
          i2 = i2 + 1
      if under > 0:
        fails = fails + 1
        if why.len == 0:
          why = $under & " active row(s) extend past the scrollbar's left " &
                "edge (" & nuF(barLeftRoot) & " in the scroll host's frame); " &
                "the worst is '" & worstName & "', " & nuF(worst) &
                " px under the bar -- this is the bar drawn through the " &
                "slider values"
    else:
      warn "postfx rows SCROLL VERDICT: the Viewport/Content edges could not " &
           "be expressed in the scroll host's frame, so 'no row under the " &
           "scrollbar' is INCONCLUSIVE. It is not counted as a pass."
  elif gPfxScrollBarT != nil:
    warn "postfx rows SCROLL VERDICT: the scrollbar's rect could not be " &
         "placed in the scroll host's frame, so 'no row under the scrollbar' " &
         "is INCONCLUSIVE, not a pass."
  # 9. SOMETHING WITH AN ACTIVE IMAGE COVERS THE VIEWPORT. Defect 2 as a
  # finished-state property of the PAGE, not a re-read of what we moved: the
  # background node is asked for its live rect and must cover the viewport's
  # rect, both expressed in the PostFX 'Panel' frame.
  var bgNote = "no background node was identified at graft time"
  if gPfxBgT != nil and pg.ok and rg0.ok:
    let bgg = nuReadGeom(gPfxBgT)
    let bgGo2 = iGameObjectOf(gPfxBgT)
    let bgAlive = (bgGo2 != nil and nuActiveInHierarchy(bgGo2))
    let bgDraws = pfxHasImage(gPfxBgT)
    let (rok3, rtop3, rleft3) = nuChildEdgeInParent(pg, rg0)
    let (vok3, vtop3, vleft3) = nuChildEdgeInParent(rg0, vg)
    if bgg.ok and rok3 and vok3:
      # the background may hang off the Panel or off the clone root; both are
      # resolved into the Panel frame the same way.
      let par3 = modsParentOf(gPfxBgT)
      let inRoot = (par3 != nil and par3 == gPfxScrollHostT)
      let pgOff = (if inRoot: (rleft3 - rg0.rectX) else: 0.0'f32)
      let pgOffY = (if inRoot: (rtop3 - (rg0.rectY + rg0.rectH)) else: 0.0'f32)
      let (bok3, btop3, bleft3) = nuChildEdgeInParent(
        (if inRoot: rg0 else: pg), bgg)
      if bok3:
        let bl = bleft3 + pgOff
        let bt = btop3 + pgOffY
        let vl = vleft3 + (rleft3 - rg0.rectX)
        let vt = vtop3 + (rtop3 - (rg0.rectY + rg0.rectH))
        let covers = bl <= vl + 1.0'f32 and
                     bl + bgg.rectW >= vl + vg.rectW - 1.0'f32 and
                     bt >= vt - 1.0'f32 and
                     bt - bgg.rectH <= vt - vg.rectH + 1.0'f32
        bgNote = "'" & iObjName(gPfxBgT) & "' " &
                 (if bgAlive: "ACTIVE" else: "INACTIVE") & ", Image=" &
                 (if bgDraws: "yes" else: "NO") & ", " & nuF(bgg.rectW) & "x" &
                 nuF(bgg.rectH) & " against a " & nuF(vg.rectW) & "x" &
                 nuF(vg.rectH) & " viewport"
        if not (bgAlive and bgDraws and covers):
          fails = fails + 1
          if why.len == 0:
            why = "the scroll area has no drawn background: " & bgNote &
                  (if not covers: " -- it does not COVER the viewport rect"
                   else: "")
      else:
        fails = fails + 1
        bgNote = "INCONCLUSIVE (not a pass): '" & iObjName(gPfxBgT) &
                 "' read a valid rect but its edges could not be placed in " &
                 (if inRoot: "the scroll host's" else: "the Panel's") & " frame"
        if why.len == 0: why = bgNote
    else:
      # NAME WHICH READ FAILED. The deployed build printed one sentence for
      # three different causes, and the real one was that the scroll host's
      # height was 0, which makes every edge computation in this block
      # degenerate -- nothing was wrong with the background node at all.
      fails = fails + 1
      bgNote = "INCONCLUSIVE (not a pass): " &
               (if not bgg.ok: "the background node '" & iObjName(gPfxBgT) &
                  "' did not read back a valid rect"
                elif not rok3: "the scroll host could not be placed inside " &
                  "the 'Panel' (host rect " & nuF(rg0.rectW) & "x" &
                  nuF(rg0.rectH) & ", panel rect " & nuF(pg.rectW) & "x" &
                  nuF(pg.rectH) & " -- a zero dimension on either makes every " &
                  "edge here degenerate)"
                else: "the viewport could not be placed inside the scroll " &
                  "host (host rect " & nuF(rg0.rectW) & "x" & nuF(rg0.rectH) &
                  ")")
      if why.len == 0: why = bgNote
  else:
    fails = fails + 1
    if why.len == 0:
      why = "NO node was identified as drawing the scroll area's background. " &
            "Census at graft time: " &
            (if gPfxBgWhy.len > 0: gPfxBgWhy else: "not recorded")
  # 7. and there must be something to scroll at all.
  if cg.rectH <= vg.rectH:
    fails = fails + 1
    if why.len == 0:
      why = "the content resolves to " & nuF(cg.rectH) &
            " px which is NOT taller than the " & nuF(vg.rectH) &
            " px viewport, so nothing can scroll"
  # 10. THE FLASH. `gPfxGraftFrame` is Time.frameCount at the graft and
  # `gPfxFirstActiveFrame` is the first frame the panel was observed ACTIVE.
  # If the graft ran at or after that frame, at least one frame WAS rendered
  # with the stock pre-graft layout -- which is exactly what the user sees as
  # a flash on the first press of POSTFX. Unknown frame numbers are
  # INCONCLUSIVE and never a pass.
  var flashNote = ""
  if gPfxGraftFrame < 0 or gPfxFirstActiveFrame < 0:
    flashNote = "INCONCLUSIVE (graft frame " & $gPfxGraftFrame &
                ", first active frame " & $gPfxFirstActiveFrame &
                "; Time.get_frameCount unbound or the panel was never seen " &
                "active) -- not counted as a pass"
    warn "postfx rows SCROLL VERDICT: the flash check is " & flashNote & "."
  elif gPfxGraftFrame >= gPfxFirstActiveFrame:
    fails = fails + 1
    flashNote = "FAILED: grafted at frame " & $gPfxGraftFrame &
                " but the panel was already active at frame " &
                $gPfxFirstActiveFrame
    if why.len == 0:
      why = "the page FLASHED: the graft ran at frame " & $gPfxGraftFrame &
            ", at or after the panel's first ACTIVE frame " &
            $gPfxFirstActiveFrame & ", so at least " &
            $(gPfxGraftFrame - gPfxFirstActiveFrame + 1) &
            " frame(s) were rendered with the stock pre-graft layout"
  else:
    flashNote = "PASS: grafted at frame " & $gPfxGraftFrame &
                ", " & $(gPfxFirstActiveFrame - gPfxGraftFrame) &
                " frame(s) BEFORE the panel first became active, so no frame " &
                "was rendered with the pre-graft layout"
  if fails == 0:
    okLog "postfx rows SCROLL VERDICT PASS: the scroll host root matches the " &
          "AUTHORED SettingsPanel rect within 1 px and the viewport keeps " &
          "the DONOR's " & nuF(vg.rectW) & " px inset (so the scrollbar has " &
          "its margin and no active row reaches it); background: " & bgNote &
          "; first-frame: " & flashNote & "; the content is top-stretch, " &
          nuF(cg.rectW) &
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
         ", " & $activeKids & " active Viewport child(ren); background: " &
         bgNote & "; first-frame: " & flashNote & "; layout census at " &
         "graft: " & gPfxLayoutNote & "; height re-asserted " & $gPfxReassert &
         " time(s). This is the page the user is looking at, not a summary of what " &
         "we wrote."

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

## ---------------------------------------------------------------------------
## TOOLTIPS, AND TOGGLE-CAPTION ALIGNMENT
##
## Both were reported by the player against the deployed build 61238a816f58:
## "some fields have no tooltip" (every PostFX row: this file had never called
## SetTooltip at all) and the toggle rows rendering CENTRE-aligned while stock
## toggle rows do not.
##
## THE TOOLTIP MECHANISM IS NOT NEW HERE, and deliberately so. It is exactly
## the one `dlssrows.nim` proved live on the Graphics page: borrow a live
## `SettingsTooltipData` from a stock row (`SettingControl._tooltipSettings-
## Hover@0x98 -> _tooltipData@0x20`), take its class pointer out of the
## object header, allocate against THAT, fill it through hostfieldwrite's
## typed FieldRef gate, hand it to `SettingControl::SetTooltip` @0x16FAC00 and
## then RE-READ the control. The shared half now lives in `nativeui.nim` as
## `nuMakeTooltipData`, so this file and dlssrows cannot drift apart.
##
## `SetTooltip` has THREE no-op paths and no throw path (MEASURED `disasm
## 0x16fac00 --len 940`: `_blocker@0x88` null, `UiElementBlocker::TryGetTooltip`
## false, or a null data argument -- each returns `this` untouched). So a
## successful call proves nothing, and the verdict reads
## `_tooltipSettingsHover@0x98 -> _tooltipData@0x20 -> Text@0x20` back and
## demands POINTER IDENTITY with the interned string handed over. SetTooltip
## copies the REFERENCE (MEASURED `mov rax,[rbp+0x20] ; mov [rdi+0x20],rax`),
## so identity is a real finished-state test.
##
## THE DONOR COMES FROM THE GRAPHICS PAGE, not this one. The stock PostFX panel
## is EMPTY on this build (`PostFXSettingsTab::Show` / `OnFirstSelect` never
## run -- see the scroll verdict below), so there is no stock PostFX row to
## borrow anything from. `gGfxPanelT` is the live, already-validated Graphics
## panel transform this file's geometry donor also walks from.
const PfxMaxTipScan = 32

var gPfxTipsOn = false        ## `settingsPostFxTooltips`, DEFAULT OFF
var gPfxTipInit = false
var gPfxTipKlass: Il2CppPtr = nil
var gPfxTipAsked = 0
var gPfxTipCalled = 0
var gPfxTipVerified = 0
var gPfxTipWhy = ""
var gPfxTipWant: seq[Il2CppPtr] = @[]

var gPfxAlignOn = false       ## `settingsPostFxToggleAlign`, DEFAULT OFF
var gPfxAlignInit = false
var gPfxAlignAsked = 0
var gPfxAlignCopied = 0
var gPfxAlignVerified = 0
var gPfxAlignInconclusive = 0
var gPfxAlignWhy = ""
var gPfxAlignStockX = 0.0'f32
var gPfxAlignHaveStock = false

## THE DONOR IS NOT THERE YET AT BUILD TIME. MEASURED, host stage
## 4e1f9e7bc8fd, `aowlspt-host.log`:
##
##   [0:00:44.031] warn postfx rows: the stock Graphics row container reports
##                      0 child(ren); nothing to measure.
##   [0:00:45.312] ok   dlss rows: TOOLTIPS -- 5 of 5 row(s) READ BACK ...
##
## i.e. 1.3 s AFTER our pass refused, `dlssrows.nim` walked the SAME container
## (`GraphicsSettingsTab._settingsContainer@0x98`) and found rows in it. The
## pointer is not a different one and the PostFX page does not empty the list:
## both passes run from `pfxBuild`, which BY DESIGN builds while the panel is
## still hidden (same log: applied at frame 1989, "panel first seen ACTIVE at
## frame NEVER YET"), and at that moment the GRAPHICS tab has not instantiated
## its own rows yet. The donor is LATE, not absent -- by the time the verdict
## printed at 0:00:49.234 it had existed for four seconds.
##
## So a refusal whose cause is "no donor" is now DEFERRED rather than final:
## the pass is re-run from the tick, bounded by `PfxDonorRetryMax`, and the
## verdict is withheld until it settles or the budget is spent. Both outcomes
## still print -- a deferred pass that never settles says so, WITH the number
## of ticks it waited, which is the INCONCLUSIVE third outcome and not a pass.
const PfxDonorRetryMax = 600   ## ticks; ~10 s at 60 fps. Capped, never open.

var gPfxTipDeferred = false
var gPfxTipRetry = 0
var gPfxTipSaid = false
var gPfxTipDeferNoted = false
var gPfxAlignDeferred = false
var gPfxAlignRetry = 0
var gPfxAlignSaid = false
var gPfxAlignDeferNoted = false

proc pfxGfxContainer(): Il2CppPtr =
  ## The stock Graphics row container, reached by WALKING from the live
  ## "Graphics Settings" panel transform this feature already located and
  ## validated -- `gGfxPanelT` -> `GraphicsSettingsTab` component ->
  ## `_settingsContainer@0x98`. Never by an offset that can read null from
  ## nowhere. Identical to the walk `pfxDonorGeom` makes; factored out because
  ## two more callers now need it.
  result = nil
  if gGfxPanelT == nil or not duOk(gGfxPanelT, 0x20'i32): return
  if not iUnityAlive(gGfxPanelT): return
  let gfxTab = modsComponent(gGfxPanelT, "GraphicsSettingsTab")
  if not nuOk(gfxTab, PfxOffGfxContainer + 8'i32): return
  let cont = cNuGetRef(gfxTab, PfxOffGfxContainer)
  if not nuOk(cont, 0x10'i32) or not nuAlive(cont): return
  cont

proc pfxStockRowComponent(compName: string; why: var string): Il2CppPtr =
  ## The FIRST stock row in the Graphics container carrying component
  ## `compName` -- a `SettingToggle` for the alignment donor, anything with a
  ## tooltip for the tooltip donor.
  ##
  ## "(Clone)" IS THE DISCRIMINATOR, and it is exact rather than heuristic:
  ## Unity names every `Instantiate` result `<donor>(Clone)`, our rows are all
  ## instantiated, and the game's own rows never carry that suffix. Without
  ## this the walk would happily pick one of OUR rows as the donor -- a
  ## comparison of a thing against itself, which is the check that cannot fail
  ## this repo keeps paying for.
  result = nil
  why = ""
  let cont = pfxGfxContainer()
  if cont == nil:
    why = "the stock Graphics row container could not be reached by walking " &
          "from the live 'Graphics Settings' panel transform (gGfxPanelT -> " &
          "GraphicsSettingsTab -> _settingsContainer@0x98)"
    return
  var n = 0
  if not iChildCount(cont, n) or n <= 0:
    why = "the stock Graphics row container reports " & $n & " child(ren)"
    return
  var i = 0
  var seen = 0
  var clones = 0
  while i < n and i < PfxMaxTipScan:
    let c = iChildAt(cont, i)
    i = i + 1
    if c == nil or not duOk(c, 0x20'i32) or not iUnityAlive(c): continue
    if iObjName(c).contains("(Clone)"):
      clones = clones + 1
      continue
    seen = seen + 1
    let comp = modsComponent(c, compName)
    if comp != nil and nuOk(comp, 0x10'i32): return comp
  why = "none of the " & $seen & " stock (non-clone) row(s) examined in the " &
        "Graphics container carries a '" & compName & "' component (" &
        $clones & " child(ren) skipped as our own clones, out of " & $n & ")"

proc pfxDonorTooltipData(why: var string): Il2CppPtr =
  ## A LIVE `SettingsTooltipData`, borrowed off a stock Graphics row, so that
  ## `il2cpp_object_new` gets a class pointer that came out of an object the
  ## GAME made rather than out of any metadata lookup.
  result = nil
  why = ""
  let cont = pfxGfxContainer()
  if cont == nil:
    why = "the stock Graphics row container could not be reached, so no " &
          "SettingsTooltipData can be borrowed and none is invented"
    return
  var n = 0
  if not iChildCount(cont, n) or n <= 0:
    why = "the stock Graphics row container reports " & $n & " child(ren)"
    return
  var i = 0
  var probed = 0
  while i < n and i < PfxMaxTipScan:
    let c = iChildAt(cont, i)
    i = i + 1
    if c == nil or not duOk(c, 0x20'i32) or not iUnityAlive(c): continue
    if iObjName(c).contains("(Clone)"): continue
    for cn in ["SettingToggle", "SettingFloatSlider", "SettingDropDown",
               "SettingSelectSlider"]:
      let ctrl = modsComponent(c, cn)
      if ctrl == nil: continue
      probed = probed + 1
      let d = nuTooltipDataOf(ctrl)
      if d != nil: return d
  why = "of the stock Graphics rows examined, " & $probed & " carried a " &
        "SettingControl and NONE of them had a live " &
        "_tooltipSettingsHover@0x98 -> _tooltipData@0x20 to borrow. Without " &
        "a donor there is no class pointer to allocate against, and none is " &
        "invented"

proc pfxApplyTooltips() =
  ## Attach the schema's own description to every row we built, then VERIFY by
  ## reading the finished state back. Runs ONCE per build; nothing here is on
  ## a per-frame path and nothing here allocates after it has run.
  if not gPfxTipInit:
    gPfxTipInit = true
    gPfxTipsOn = readBoolKeyDef("settingsPostFxTooltips", false)
  if not gPfxTipsOn or gPfxRowCtrl.len == 0: return
  # A RETRY MUST NOT ACCUMULATE. Every count below is recomputed from scratch,
  # so asked/called/verified always describe ONE pass over the rows and never
  # the sum of a refused attempt and a later good one.
  gPfxTipAsked = 0
  gPfxTipCalled = 0
  gPfxTipVerified = 0
  gPfxTipWhy = ""
  gPfxTipWant = @[]
  var z = 0
  while z < gPfxRowCtrl.len and z < PfxMaxRows:
    gPfxTipWant.add nil
    z = z + 1
  var wd0 = ""
  let donor = pfxDonorTooltipData(wd0)
  if donor == nil:
    gPfxTipWhy = wd0
    # DEFERRED, not failed: the stock Graphics rows are instantiated later than
    # this build runs (see the measurement above). The tick re-runs the pass.
    gPfxTipDeferred = true
    return
  gPfxTipDeferred = false
  gPfxTipKlass = nuKlassOf(donor)
  if gPfxTipKlass == nil:
    gPfxTipWhy = "the donor SettingsTooltipData's object header did not read " &
                 "back a class pointer"
    return
  var i = 0
  while i < gPfxRowCtrl.len and i < PfxMaxRows and i < gPfxRowTip.len:
    if gPfxRowTip[i].len > 0 and gPfxRowCtrl[i] != nil:
      gPfxTipAsked = gPfxTipAsked + 1
      var wb = ""
      var wd = ""
      let body = nuStrWhy(gPfxRowTip[i], wb)
      let data = nuMakeTooltipData(gPfxTipKlass, "postfxrows.tooltip",
                                   gPfxRowName[i], gPfxRowTip[i], wd)
      if data != nil and body != nil:
        gPfxTipWant[i] = body
        if nuSetTooltip(gPfxRowCtrl[i], data):
          gPfxTipCalled = gPfxTipCalled + 1
        else:
          warn "postfx rows: tooltip '" & gPfxRowName[i] & "' -- the template " &
               "was BUILT and SetTooltip was refused before it was made (the " &
               "control did not validate, or the @0x16FAC00 prologue did not " &
               "verify). Nothing was called for this row."
      else:
        # ONE LINE PER FAILING ROW, naming the row AND the cause. Recording
        # only the FIRST failure into a shared string made four rows failing
        # for one reason read as one row failing for another -- MEASURED, on
        # the DLSS rows, 2026-09-04.
        warn "postfx rows: tooltip '" & gPfxRowName[i] & "' NOT applied -- " &
             (if data == nil: wd else: "the body string: " & wb) & "."
        if gPfxTipWhy.len == 0:
          gPfxTipWhy = "first failure was '" & gPfxRowName[i] & "': " &
                       (if data == nil: wd else: wb)
    i = i + 1
  # THE VERDICT: a property of the FINISHED STATE. The tooltip the control now
  # carries must BE the string handed over, read back through the control,
  # from the object the GAME constructed out of our template.
  var i2 = 0
  while i2 < gPfxRowCtrl.len and i2 < PfxMaxRows and i2 < gPfxTipWant.len:
    if gPfxTipWant[i2] != nil:
      if nuTooltipTextOf(gPfxRowCtrl[i2]) == gPfxTipWant[i2]:
        gPfxTipVerified = gPfxTipVerified + 1
      else:
        let hov = (if nuOk(gPfxRowCtrl[i2], PfxOffCtrlTipHover + 8'i32):
                     cNuGetRef(gPfxRowCtrl[i2], PfxOffCtrlTipHover) else: nil)
        let blk = (if nuOk(gPfxRowCtrl[i2], PfxOffCtrlBlocker + 8'i32):
                     cNuGetRef(gPfxRowCtrl[i2], PfxOffCtrlBlocker) else: nil)
        warn "postfx rows: tooltip '" & gPfxRowName[i2] & "' -- SetTooltip " &
             "was CALLED and the finished state does NOT carry our string. " &
             "On this row _tooltipSettingsHover@0x98 = " &
             (if hov == nil: "NULL" else: "0x" & hexOf(cast[uint64](hov))) &
             " and _blocker@0x88 = " &
             (if blk == nil: "NULL" else: "0x" & hexOf(cast[uint64](blk))) &
             ". A NULL blocker is SetTooltip's FIRST no-op path and means " &
             "this prefab needs a SettingsHoverTooltipArea before any " &
             "tooltip can attach; a non-null blocker with a null hover area " &
             "means TryGetTooltip answered false. Either way this row shows " &
             "NO tooltip and is not counted as a pass."
    i2 = i2 + 1

## ---------------------------------------------------------------------------
## TOGGLE-CAPTION ALIGNMENT
##
## OBSERVED (the player, on build 61238a816f58): our toggle rows -- "Red tint
## diagnostic", "Enable post-process", "Raid only" -- render CENTRE-aligned
## while stock toggle rows do not.
##
## WHAT IS AND IS NOT ALREADY DONE. `pfxMakeRow` applies `nuApplyGeomX` to each
## ROW's own RectTransform, copying anchorMin.x / anchorMax.x / pivot.x /
## sizeDelta.x from a stock Graphics row. It does NOT touch anchoredPosition
## (correctly -- the parent LayoutGroup owns that) and, more to the point, it
## does not touch anything INSIDE the row. The caption's placement is authored
## in the prefab, and our toggles come from `PostFXSettingsTab._toggleLeft-
## Template@0xc0` while every stock toggle row on screen came from the GRAPHICS
## tab's own toggle template. Two different prefabs, two different authored
## caption rects; nothing in the row-level copy can equalise them.
##
## WHAT IS DELIBERATELY NOT ASSERTED. This code does NOT claim to know which
## property differs. Reading the source cannot establish that, the live tree
## dump in `docs/settings-tree-live-2026-09-02.txt` records no RectTransform
## numbers for either row, and a subagent may not drive the client. So the
## whole X half of the stock caption's rect is MEASURED LIVE and copied, and
## the LOG PRINTS BOTH GEOMETRIES -- so the next run says which property was
## wrong even though this run did not need to know.
##
## THE VERDICT IS A NEGATIVE AND IT CAN FAIL: our caption's left edge, computed
## as `anchoredPosition.x + rect.x` (the pivot-corrected left edge -- see
## `nuCtrlLabelLeft`), must sit within 1 px of the STOCK toggle row's. A
## centred caption in a differently sized rect cannot pass that by accident,
## and "the label could not be read at all" is a THIRD outcome, counted apart.
const PfxAlignTolPx = 1.0'f32

proc pfxAlignToggleLabels() =
  ## Copy the stock toggle row's caption geometry onto each of our toggle rows,
  ## then judge by re-reading the finished left edge.
  if not gPfxAlignInit:
    gPfxAlignInit = true
    gPfxAlignOn = readBoolKeyDef("settingsPostFxToggleAlign", false)
  if not gPfxAlignOn or gPfxRowCtrl.len == 0: return
  # Recomputed per pass, for the same reason as the tooltip counters above.
  gPfxAlignAsked = 0
  gPfxAlignCopied = 0
  gPfxAlignVerified = 0
  gPfxAlignInconclusive = 0
  gPfxAlignWhy = ""
  var whyStock = ""
  let stockCtrl = pfxStockRowComponent("SettingToggle", whyStock)
  if stockCtrl == nil:
    gPfxAlignWhy = "no STOCK toggle row could be found to measure -- " &
                   whyStock & ". Nothing was written; our rows keep the " &
                   "prefab's own caption placement, which is the defect"
    gPfxAlignDeferred = true
    return
  gPfxAlignDeferred = false
  let stockG = nuCtrlLabelGeom(stockCtrl)
  if not stockG.ok:
    gPfxAlignWhy = "a stock SettingToggle was found and its caption TMP's " &
                   "RectTransform could not be read in full " &
                   "(SettingControl.Text@0x80 -> _labels@0x78 -> [0]). A " &
                   "partial geometry is not a measurement, so nothing was " &
                   "copied"
    return
  let (okS, stockX) = nuCtrlLabelLeft(stockCtrl)
  if not okS:
    gPfxAlignWhy = "the stock caption's left edge could not be computed"
    return
  gPfxAlignStockX = stockX
  gPfxAlignHaveStock = true
  okLog "postfx rows: STOCK TOGGLE CAPTION MEASURED LIVE -- " &
        nuGeomNote(stockG) & ", left edge (anchoredPosition.x + rect.x) = " &
        nuF(stockX) & ". This is the geometry our toggle captions are copied " &
        "to, read off a row the GAME built."
  var i = 0
  while i < gPfxRowCtrl.len and i < PfxMaxRows and i < gPfxRowKind.len:
    if gPfxRowKind[i] != pkToggle or gPfxRowCtrl[i] == nil:
      i = i + 1
      continue
    gPfxAlignAsked = gPfxAlignAsked + 1
    let (okB, beforeX) = nuCtrlLabelLeft(gPfxRowCtrl[i])
    let beforeG = nuCtrlLabelGeom(gPfxRowCtrl[i])
    var w = ""
    if not nuCopyLabelGeom(gPfxRowCtrl[i], stockG, w):
      gPfxAlignInconclusive = gPfxAlignInconclusive + 1
      if gPfxAlignWhy.len == 0:
        gPfxAlignWhy = "'" & gPfxRowName[i] & "': " & w
      i = i + 1
      continue
    gPfxAlignCopied = gPfxAlignCopied + 1
    let (okA, afterX) = nuCtrlLabelLeft(gPfxRowCtrl[i])
    if not okA:
      gPfxAlignInconclusive = gPfxAlignInconclusive + 1
      if gPfxAlignWhy.len == 0:
        gPfxAlignWhy = "'" & gPfxRowName[i] & "': the five setters were " &
                       "called and the caption's left edge could not be read " &
                       "back afterwards, so this row is INCONCLUSIVE -- " &
                       "neither aligned nor proven misaligned"
      i = i + 1
      continue
    let d = (if afterX > stockX: afterX - stockX else: stockX - afterX)
    if d <= PfxAlignTolPx:
      gPfxAlignVerified = gPfxAlignVerified + 1
    else:
      warn "postfx rows: ALIGN '" & gPfxRowName[i] & "' -- the stock toggle " &
           "caption's left edge is " & nuF(stockX) & " and ours reads " &
           nuF(afterX) & " after the copy (" & nuF(d) & " px out, tolerance " &
           nuF(PfxAlignTolPx) & "). BEFORE the copy it was " &
           (if okB: nuF(beforeX) else: "unreadable") & " and its rect was " &
           (if beforeG.ok: nuGeomNote(beforeG) else: "unreadable") &
           "; the stock rect is " & nuGeomNote(stockG) & ". Those two lines " &
           "name the property that still differs -- this file does not guess " &
           "which one it is."
      if gPfxAlignWhy.len == 0:
        gPfxAlignWhy = "'" & gPfxRowName[i] & "': " & nuF(d) & " px out " &
                       "after the copy"
    i = i + 1

proc pfxTooltipVerdict() =
  ## ONE line, and it can FAIL. Silence would make "the flag is off" and "the
  ## flag is on and every row refused" print identically.
  if gPfxTipSaid: return
  if gPfxTipDeferred and gPfxTipRetry < PfxDonorRetryMax:
    if not gPfxTipDeferNoted:
      gPfxTipDeferNoted = true
      info "postfx rows: TOOLTIPS -- VERDICT WITHHELD, the pass is DEFERRED. " &
           "The donor is a STOCK Graphics row and at build time " & gPfxTipWhy &
           ". That is the late-donor case, not a failure: the pass is being " &
           "re-run from the tick (budget " & $PfxDonorRetryMax & " tick(s)) " &
           "and a real verdict -- pass, fail, or a named INCONCLUSIVE -- is " &
           "printed the moment it settles or the budget is spent. Silence " &
           "here would itself be the defect."
    return
  gPfxTipSaid = true
  if not gPfxTipsOn:
    info "postfx rows: TOOLTIPS are OFF (settingsPostFxTooltips). No row " &
         "carries a description, which is the state the player reported; " &
         "turn the flag on to attach them."
    return
  if gPfxTipAsked == 0:
    warn "postfx rows: TOOLTIPS -- the flag is ON and ZERO rows were even " &
         "asked. " & (if gPfxTipWhy.len > 0: gPfxTipWhy
                      else: "No reason was recorded, which is itself a defect") &
         "."
  elif gPfxTipVerified == gPfxTipAsked:
    okLog "postfx rows: TOOLTIPS -- " & $gPfxTipVerified & " of " &
          $gPfxTipAsked & " row(s) READ BACK through " &
          "_tooltipSettingsHover@0x98 -> _tooltipData@0x20 -> Text@0x20 as " &
          "the exact string handed to SettingControl::SetTooltip @0x16FAC00. " &
          "Texts are mods/graphics' own schema descriptions. That is the " &
          "object the GAME built from our template, read through the control " &
          "-- not our own write read back."
  else:
    warn "postfx rows: TOOLTIPS -- only " & $gPfxTipVerified & " of " &
         $gPfxTipAsked & " row(s) read back (" & $gPfxTipCalled &
         " call(s) made). The rest show NO tooltip. First reason: " &
         (if gPfxTipWhy.len > 0: gPfxTipWhy
          else: "none was recorded, which is itself a defect") & "."

proc pfxAlignVerdict() =
  ## ONE line, three outcomes, and the PASS is a negative: no toggle caption of
  ## ours is more than 1 px from the stock one's left edge.
  if gPfxAlignSaid: return
  if gPfxAlignDeferred and gPfxAlignRetry < PfxDonorRetryMax:
    if not gPfxAlignDeferNoted:
      gPfxAlignDeferNoted = true
      info "postfx rows: TOGGLE ALIGNMENT -- VERDICT WITHHELD, the pass is " &
           "DEFERRED. " & gPfxAlignWhy & ". The stock toggle row is " &
           "instantiated later than this build runs, so the pass is being " &
           "re-run from the tick (budget " & $PfxDonorRetryMax & " tick(s)); " &
           "a pass, a fail, or a named INCONCLUSIVE follows."
    return
  gPfxAlignSaid = true
  if not gPfxAlignOn:
    info "postfx rows: TOGGLE-CAPTION ALIGNMENT is OFF " &
         "(settingsPostFxToggleAlign). Our toggle rows keep the " &
         "_toggleLeftTemplate@0xc0 prefab's own authored caption placement, " &
         "which is the centred rendering the player reported."
    return
  if gPfxAlignAsked == 0:
    warn "postfx rows: TOGGLE ALIGNMENT -- the flag is ON and ZERO toggle " &
         "rows were examined. " &
         (if gPfxAlignWhy.len > 0: gPfxAlignWhy
          else: "No reason was recorded, which is itself a defect") & "."
  elif gPfxAlignVerified == gPfxAlignAsked and gPfxAlignInconclusive == 0:
    okLog "postfx rows: TOGGLE ALIGNMENT -- all " & $gPfxAlignVerified &
          " of our toggle row(s) now have a caption whose left edge " &
          "(anchoredPosition.x + rect.x, pivot-corrected) is within " &
          nuF(PfxAlignTolPx) & " px of a STOCK SettingToggle row's, measured " &
          "live at " & nuF(gPfxAlignStockX) & ". That is a comparison against " &
          "a row the GAME built, not against our own write."
  else:
    warn "postfx rows: TOGGLE ALIGNMENT -- " & $gPfxAlignVerified & " of " &
         $gPfxAlignAsked & " toggle row(s) line up with the stock caption (" &
         $gPfxAlignCopied & " copied, " & $gPfxAlignInconclusive &
         " INCONCLUSIVE -- could not be measured, which is neither a pass nor " &
         "a fail). First reason: " &
         (if gPfxAlignWhy.len > 0: gPfxAlignWhy
          else: "none was recorded, which is itself a defect") & "."

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
  gPfxRowTip = @[]
  gPfxRowKind = @[]
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
      # The schema description and the row KIND, from the catalogue entry this
      # iteration is already holding. Kept parallel to `gPfxRowCtrl` so the two
      # passes below never re-derive either from the live object.
      gPfxRowTip.add r.tip
      gPfxRowKind.add r.kind
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
  # THE TOOLTIPS AND THE TOGGLE-CAPTION ALIGNMENT. Both run ONCE, here, after
  # every row exists and after the value binding has seeded them; both are
  # separately flag-gated and DEFAULT OFF; and both judge by re-reading the
  # live object rather than by trusting their own calls. Their verdict lines
  # are printed from `pfxVerdict`, not from here, so a build that never
  # reaches the verdict cannot claim either of them succeeded.
  pfxApplyTooltips()
  pfxAlignToggleLabels()
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
    if gPfxPanelUpNow:
      discard pfxScrollify(tab, parent, scrollRoot)
    else:
      # THE GRAFT NEVER RUNS INTO A HIDDEN PANEL. MEASURED 2026-09-05, twice
      # (the user's click and an inspector `tab` press, same stack): with the
      # ScrollRect clone grafted while the panel was hidden, the panel's FIRST
      # activation -- SettingsScreen::ShowScreen(PostFX) -> SettingsTab::
      # set_IsSelected -> SetActive -> RectMask2D.OnEnable -> MaskUtilities::
      # Notify2DMaskStateChanged -> GameObject::GetComponentsInChildren ->
      # UnityPlayer -> WaitForSingleObjectEx -- never returned: the Unity
      # main thread stopped calling TarkovApplication::Update, the process
      # stayed alive with no dialog and no crash record, and the user saw it
      # as a crash. With the graft off the same press switched the panel in
      # under a frame. The rows are still built hidden (defect 3, no flash
      # for them); only the clone waits for the first panel-up tick, which is
      # the ordering that worked before defect 3 moved the build.
      gPfxGraftDeferred = true
      gPfxGraftTab = tab
      gPfxGraftParent = parent
      info "postfx rows SCROLL: graft DEFERRED -- the panel is hidden, and " &
           "grafting the ScrollRect clone into a hidden panel is MEASURED to " &
           "deadlock Unity at the panel's first activation (RectMask2D " &
           "enable -> GetComponentsInChildren -> WaitForSingleObject, " &
           "forever). The rows are built now; the graft runs on the first " &
           "tick the panel is up."
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
  # TWO MORE VERDICTS, EACH ITS OWN LINE AND EACH ABLE TO FAIL. They are NOT
  # folded into the PASS above: a page whose rows are all present, correctly
  # sized and correctly valued can still have no tooltips and centred toggle
  # captions -- which is exactly what the player reported on 61238a816f58,
  # while that PASS line was printing.
  pfxTooltipVerdict()
  pfxAlignVerdict()

proc pfxDonorRetryTick() =
  ## Re-run a pass whose ONLY refusal was "the stock Graphics donor is not
  ## there yet". Bounded by `PfxDonorRetryMax` ticks, and it announces the
  ## outcome itself the moment it has one: a pass that settles prints its
  ## normal verdict here rather than waiting for another visit, and an
  ## exhausted budget prints the refusal WITH the number of ticks waited, so
  ## "the donor never arrived" can never read the same as "we never looked
  ## again".
  ##
  ## Runs inside `gfxTickBody`'s existing guard -- it adds NO second SEH, no
  ## detour and no managed allocation; a deferred re-run only walks the stock
  ## container, which is itself capped at `PfxMaxTipScan` children.
  ##
  ## Steady state, once neither pass is deferred: two boolean tests.
  if gPfxTipDeferred:
    if gPfxTipRetry < PfxDonorRetryMax:
      gPfxTipRetry = gPfxTipRetry + 1
      pfxApplyTooltips()
      if not gPfxTipDeferred:
        pfxTooltipVerdict()
    else:
      gPfxTipDeferred = false
      gPfxTipWhy = gPfxTipWhy & " -- and that was still true after " &
                   $gPfxTipRetry & " later tick(s) of re-checking, so the " &
                   "donor never arrived while this screen was open"
      pfxTooltipVerdict()
  if gPfxAlignDeferred:
    if gPfxAlignRetry < PfxDonorRetryMax:
      gPfxAlignRetry = gPfxAlignRetry + 1
      pfxAlignToggleLabels()
      if not gPfxAlignDeferred:
        pfxAlignVerdict()
    else:
      gPfxAlignDeferred = false
      gPfxAlignWhy = gPfxAlignWhy & " -- and that was still true after " &
                     $gPfxAlignRetry & " later tick(s) of re-checking"
      pfxAlignVerdict()

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
  # THE NATIVE ROW SET (`nativepostfx.nim`, flag `settingsNativePostFx`,
  # DEFAULT ON), driven from HERE and deliberately ABOVE this file's own gate.
  #
  # The two row sets are INDEPENDENT and ADDITIVE, and that independence is the
  # whole point of the placement: these rows drive the GAME'S OWN pipeline,
  # while everything below drives `mods/graphics` -- our D3D composite pass,
  # which is now LEGACY and default OFF. Putting this call under `gPfxOn` would
  # silently make the replacement require the thing it replaces, so the default
  # configuration (legacy off, native on) would show an EMPTY POSTFX page while
  # every flag read as intended.
  #
  # It opens no guard: this runs inside `gfxTickBody`'s single `aowl_p_p_seh`,
  # which is not re-entrant. Its own gate is one boolean compare when the flag
  # is off.
  npfOnPanelUp(postUp)
  gPfxPanelUpNow = postUp
  if not gPfxOn or gPfxOff:
    return
  # THE FIRST FRAME THE PANEL WAS ACTUALLY ACTIVE, latched once. Everything
  # defect 3 claims is an ordering between this number and the graft's, so it
  # is recorded before any gate that could skip it.
  if postUp and gPfxFirstActiveFrame < 0:
    gPfxFirstActiveFrame = int(pfxFrameNow())
  if not gPfxBuilt:
    # DEFECT 3: BUILD WHILE THE PANEL IS STILL HIDDEN.
    #
    # This used to `return` above unless `postUp`, so the rows and the whole
    # scroll graft ran on the FIRST panel-up tick -- i.e. after Unity had
    # already rendered the stock layout at least once. That single frame is
    # the flash the user reports on the first press of POSTFX.
    #
    # Nothing in the build needs the panel to be visible: `_settingsRoot@0xa0`
    # is a SERIALIZED field populated when the prefab loads, `GetComponent`
    # and `Instantiate` both work on inactive objects, and the layout is
    # rebuilt for free when the panel is finally activated -- Unity runs
    # `OnEnable` on the whole subtree then, and `LayoutGroup::OnEnable` /
    # `ContentSizeFitter::OnEnable` both `SetDirty`, so the first rendered
    # frame is already the grafted one.
    #
    # The try budget is SPLIT rather than shared: at most 2 attempts while
    # hidden, so a build that can only succeed once the panel is up still has
    # attempts left. Merging them would let a hidden-only failure mode burn
    # the whole budget and silently produce no rows at all.
    if postUp:
      if gPfxTried < 4:
        discard pfxBuild()
    elif gPfxTried < 2:
      discard pfxBuild()
    return
  if gPfxGraftDeferred and postUp:
    # The deferred half of the build (see pfxBuild): the panel is up now, so
    # the clone is instantiated into an ACTIVE subtree, which is the ordering
    # the graft has always worked under.
    gPfxGraftDeferred = false
    var root: Il2CppPtr = nil
    if pfxScrollify(gPfxGraftTab, gPfxGraftParent, root) and root != nil:
      let jg = nuReadGeom(root)
      if jg.ok: gPfxParentW = jg.rectW
      gPfxScrollJudgeRoot = root
      gPfxScrollJudge = PfxScrollJudgeDelay
      okLog "postfx rows SCROLL: the DEFERRED graft ran on the first " &
            "panel-up tick (the rows were built hidden); the scroll verdict " &
            "is re-armed against the clone's Content."
    else:
      warn "postfx rows SCROLL: the DEFERRED graft did not complete on the " &
           "first panel-up tick -- its own refusal line above says why. The " &
           "rows stay in the unscrolled panel."
  if not postUp:
    return
  # THE LAYOUT DRIVER ON 'Panel' GETS THE LAST WORD OTHERWISE. Read-compare-
  # write, bounded, and it reports when it gives up. See `pfxReassertRoot`.
  if gPfxGraftOk: pfxReassertRoot()
  # DEFECT 3, polled. One toggle read per frame; the 26 writes only on the
  # edge. It runs BEFORE the row verdict so that a gray-out fault is reported
  # against the same frame it happened in.
  pfxGrayTick()
  if gPfxScrollJudge > 0:
    gPfxScrollJudge = gPfxScrollJudge - 1
    if gPfxScrollJudge == 0:
      pfxScrollVerdict(gPfxScrollJudgeRoot)
  # THE LATE DONOR. Runs BEFORE the verdict so a pass that settles on this
  # tick is judged on this tick.
  pfxDonorRetryTick()
  pfxVerdict()

proc pfxOnScreenClosed() =
  ## The settings screen went away. Re-arm the verdict so the NEXT visit prints
  ## a fresh one, and drop our rows if the container they were parented to has
  ## been destroyed under us. We own these rows outright (they are NOT in the
  ## tab's `_createdControls`), so nothing else will ever clean them up.
  # The NATIVE row set's teardown, driven from here for the same reason its
  # tick is: it owns rows on this page and the game will never clean them up.
  # Unconditional and above this file's own state, so the native rows are torn
  # down and rebuilt per visit whether or not the legacy set is armed.
  npfOnScreenClosed()
  gPfxVerdictSaid = false
  gPfxScrollSaid = false
  gPfxGraySaid = false
  # The two donor-dependent passes get a fresh announcement AND a fresh retry
  # budget per visit: a donor absent on this visit may exist on the next one,
  # and a verdict that printed once must print again for the visit the player
  # is actually looking at.
  gPfxTipSaid = false
  gPfxTipDeferNoted = false
  gPfxTipRetry = 0
  gPfxAlignSaid = false
  gPfxAlignDeferNoted = false
  gPfxAlignRetry = 0
  # The next visit is a fresh "when did this panel first become active", so
  # the flash check judges THAT visit and not a stale pairing.
  gPfxFirstActiveFrame = -1
  # A fresh re-assert budget per visit: the group re-runs on show, so the
  # repair must be available again -- while still bounded within one visit.
  gPfxReassert = 0
  gPfxReassertSaid = false
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
