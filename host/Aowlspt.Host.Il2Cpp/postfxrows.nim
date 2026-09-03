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
var gPfxScrollContentT: Il2CppPtr = nil  ## the row parent we made the content
var gPfxScrollSaid = false

## ---- the gray-out (defect 3) -------------------------------------------
var gPfxGrayInit = false
var gPfxGrayOn = false             ## `settingsPostFxGrayOut`, DEFAULT OFF
var gPfxGrayApplied = false        ## the state currently written to the rows
var gPfxGrayHave = false           ## ...and whether it has ever been written
var gPfxGraySaid = false
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
  gPfxGrayHave = false
  gPfxGrayApplied = false
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

proc pfxScrollify(rowParent: Il2CppPtr): bool =
  ## DEFECT 2. Give the PostFX page the SAME scroll structure the Graphics page
  ## has, by cloning the Graphics page's own `SettingsList` -- ScrollRect,
  ## Viewport, Content, Scrollbar and all -- rather than assembling one.
  ##
  ## WHY A CLONE AND NOT AN AddComponent: a `ScrollRect` built from scratch has
  ## every serialized reference null (`m_Viewport`, the Viewport's
  ## `Mask`/`RectMask2D`, the Content's `ContentSizeFitter`, both scrollbars),
  ## and `nuAdd` has no ScrollRect kind and no attested `.data` cache slot for
  ## one. `Object.Instantiate` copies the whole wiring AND remaps the internal
  ## references to the clone's own children, which is the part that cannot be
  ## reproduced by hand.
  ##
  ## WHAT MUST SURVIVE: `PostFXSettingsTab._settingsRoot@0xa0` is the row
  ## parent for the game's OWN stock rows as well as our 27, and the tab holds
  ## that pointer. So the row parent's IDENTITY is never changed -- it is MOVED
  ## into the cloned Viewport and made the ScrollRect's `m_Content`.
  ## `EnablePanel` stays where it is, a sibling under `Panel`, deliberately:
  ## the game's own enable toggle belongs above the scrolled body, not inside
  ## it.
  ##
  ## THE CLONE'S OWN `Content` IS RETIRED, NOT DESTROYED -- `SetActive false`.
  ## The map's Destroy trap: `Object.Destroy` is deferred to end of frame, so a
  ## destroyed node is still walkable, still counted and still readable for the
  ## rest of the frame, and a verdict that ran in that window would report a
  ## tree that no longer exists.
  result = false
  if gPfxScrollGo != nil: return true
  if gGfxPanelT == nil or gGfxPostT == nil: return false
  if not iUnityAlive(gGfxPanelT) or not iUnityAlive(gGfxPostT): return false
  # THE DONOR, reached by WALKING the measured path and validating each hop --
  # "Graphics Settings" -> "Other Settings" -> "SettingsList" (inspector,
  # 2026-09-03). A depth-limited name search is the fallback, not the first
  # choice, because a name search can find a DIFFERENT SettingsList.
  var donorT = modsChildNamed(modsChildNamed(gGfxPanelT, "Other Settings"),
                              "SettingsList")
  if donorT == nil:
    donorT = modsFindNamed(gGfxPanelT, "SettingsList", 4)
  if donorT == nil or not duOk(donorT, 0x20'i32) or not iUnityAlive(donorT):
    pfxNoteFault("the Graphics page's 'SettingsList' (the ScrollRect donor) " &
                 "could not be reached by walking 'Graphics Settings' -> " &
                 "'Other Settings' -> 'SettingsList', nor found by name " &
                 "within 4 levels. Nothing was cloned and the PostFX page is " &
                 "exactly as it was.")
    return
  let donorSr = modsComponent(donorT, "ScrollRect")
  if donorSr == nil:
    pfxNoteFault("the node found as the Graphics 'SettingsList' carries no " &
                 "ScrollRect, so it is NOT the scroll host and cloning it " &
                 "would graft a container with no scrolling into the PostFX " &
                 "page. Refused; nothing was cloned.")
    return
  let panelT = modsChildNamed(gGfxPostT, "Panel")
  if panelT == nil or not duOk(panelT, 0x20'i32) or not iUnityAlive(panelT):
    pfxNoteFault("'PostFX Settings' -> 'Panel' could not be reached, so " &
                 "there is nowhere to put the scroll host. Nothing was " &
                 "cloned.")
    return
  let donorGo = iGameObjectOf(donorT)
  let panelGo = iGameObjectOf(panelT)
  if donorGo == nil or panelGo == nil:
    pfxNoteFault("the donor SettingsList or the PostFX 'Panel' has no " &
                 "reachable GameObject, so it could be neither cloned nor " &
                 "parented. Nothing was cloned.")
    return
  let dg = nuReadGeom(donorT)
  let cloneGo = modsClone(donorGo)
  let cloneT = (if cloneGo != nil: modsTransformOf(cloneGo) else: nil)
  if cloneGo == nil or cloneT == nil:
    pfxNoteFault("Object::Instantiate of the Graphics SettingsList returned " &
                 "null or a clone with no reachable Transform. Nothing is " &
                 "parented anywhere.")
    return
  if not modsSetParent(cloneGo, panelGo):
    pfxNoteFault("the cloned SettingsList could not be parented under the " &
                 "PostFX 'Panel'. It is destroyed rather than left at the " &
                 "scene root, where it would render over the screen.")
    discard nuDestroy(cloneGo)
    return
  # SetParentAndAlign zeroes the local pose, so the donor's OWN geometry is
  # re-applied afterwards. Read from the live donor, never a constant: this
  # user runs 1.5x display scaling and a transcribed pixel is wrong on the
  # next machine.
  if dg.ok:
    discard nuLayout(cloneT, dg.aMinX, dg.aMinY, dg.aMaxX, dg.aMaxY,
                     dg.pivX, dg.pivY, dg.sdX, dg.sdY, dg.posX, dg.posY)
  let sr = modsComponent(cloneT, "ScrollRect")
  let viewportT = modsChildNamed(cloneT, "Viewport")
  let contentT = (if viewportT != nil: modsChildNamed(viewportT, "Content")
                  else: nil)
  if sr == nil or viewportT == nil or contentT == nil:
    pfxNoteFault("the clone is missing " &
                 (if sr == nil: "its ScrollRect"
                  elif viewportT == nil: "its 'Viewport' child"
                  else: "its 'Viewport/Content' child") &
                 ", so it cannot host anything. It is destroyed and the " &
                 "PostFX page is left exactly as it was.")
    discard nuDestroy(cloneGo)
    return
  # RETIRE the donor rows the clone brought with it. SetActive false, capped,
  # and never Destroy (see the header note above).
  var retired = 0
  var kids = 0
  if iChildCount(contentT, kids):
    var i = 0
    while i < kids and i < 64:
      let c = iChildAt(contentT, i)
      if c != nil and duOk(c, 0x20'i32):
        let cgo = iGameObjectOf(c)
        if cgo != nil and modsSetActive(cgo, false): retired = retired + 1
      i = i + 1
  # MOVE the real row parent into the clone's Viewport and give it the
  # Content's authored anchoring, keeping its OWN height: the row parent has
  # its own LayoutGroup and its own resolved height, and overwriting that with
  # the donor Content's would be inventing a number.
  let cg = nuReadGeom(contentT)
  let rg = nuReadGeom(rowParent)
  if not nuParentTransform(rowParent, viewportT, false):
    pfxNoteFault("_settingsRoot could not be reparented into the cloned " &
                 "Viewport. The clone is destroyed and the rows stay exactly " &
                 "where they already are -- unscrolled, but intact.")
    discard nuDestroy(cloneGo)
    return
  if cg.ok and rg.ok:
    discard nuLayout(rowParent, cg.aMinX, cg.aMinY, cg.aMaxX, cg.aMaxY,
                     cg.pivX, cg.pivY, cg.sdX, rg.sdY, cg.posX, cg.posY)
  # The clone's own Content is now redundant; retire it whole.
  let contentGo = iGameObjectOf(contentT)
  if contentGo != nil: discard modsSetActive(contentGo, false)
  # THE ONE WRITE THAT MATTERS: `ScrollRect.m_Content@0x20` (MEASURED,
  # `fldoff.py fields UnityEngine.UI.ScrollRect`). Read first -- a field that
  # cannot be read is not a field that may be written.
  if not nuOk(sr, NuOffScrollContent + 8'i32):
    pfxNoteFault("the cloned ScrollRect's m_Content@0x20 could not be READ, " &
                 "so it is not written either. The clone is destroyed.")
    discard nuDestroy(cloneGo)
    return
  if cNuSetRef(sr, NuOffScrollContent, rowParent) == 0'i32:
    pfxNoteFault("the write to the cloned ScrollRect's m_Content@0x20 was " &
                 "refused by the writability check. The clone is destroyed " &
                 "rather than left pointing at its own retired Content.")
    discard nuDestroy(cloneGo)
    return
  gPfxScrollGo = cloneGo
  gPfxScrollContentT = rowParent
  okLog "postfx rows: SCROLL GRAFT applied -- cloned the Graphics page's own " &
        "'SettingsList' (ScrollRect + Viewport + Content + Scrollbar) under " &
        "'PostFX Settings'/'Panel', retired " & $retired & " donor row(s) " &
        "from the clone with SetActive(false) (never Destroy -- a destroyed " &
        "node is still walkable for the rest of the frame), moved " &
        "_settingsRoot@0xa0 into the clone's Viewport and pointed " &
        "ScrollRect.m_Content@0x20 at it. EnablePanel was NOT moved: the " &
        "game's enable toggle stays above the scrolled body. The verdict " &
        "below reads all of that back off the live components."
  result = true

proc pfxScrollVerdict(rowParent: Il2CppPtr) =
  ## REPLACES the INCONCLUSIVE this file used to print. The old verdict asked
  ## `modsComponent(gGfxPostT, "ScrollRect")` -- a GetComponent on the PANEL
  ## ROOT, not a search of its children -- so it could only ever answer "no
  ## ScrollRect", which is precisely the shape of check that cannot fail.
  ##
  ## FOUR readings, all off live components, none of them our own write:
  ##   1. a ScrollRect exists under 'PostFX Settings';
  ##   2. its `m_Content@0x20` IS the row parent (`_settingsRoot@0xa0`);
  ##   3. the content's resolved height EXCEEDS the viewport's -- if it does
  ##      not, there is nothing to scroll and a scrollbar would be decoration;
  ##   4. the scrollbar GameObject is active in the hierarchy.
  let host = (if gPfxScrollGo != nil: modsTransformOf(gPfxScrollGo)
              else: modsFindNamed(gGfxPostT, "SettingsList", 4))
  let sr = (if host != nil: modsComponent(host, "ScrollRect") else: nil)
  if sr == nil:
    warn "postfx rows SCROLL VERDICT INCONCLUSIVE: no ScrollRect was found " &
         "under 'PostFX Settings' at all, so whether our row parent is the " &
         "thing that scrolls could not be asked. NOTE this is now a search " &
         "of the panel's CHILDREN; the previous verdict asked GetComponent " &
         "on the panel root, where a ScrollRect was never going to be, and " &
         "therefore could only ever answer INCONCLUSIVE."
    return
  if not nuOk(sr, NuOffScrollContent + 8'i32):
    warn "postfx rows SCROLL VERDICT INCONCLUSIVE: the ScrollRect was found " &
         "but m_Content@0x20 could not be read. 'I could not look' is not a " &
         "pass."
    return
  let content = cNuGetRef(sr, NuOffScrollContent)
  if content != rowParent:
    warn "postfx rows SCROLL VERDICT FAIL: ScrollRect.m_Content@0x20 is " &
         iPtr(content) & " ('" & iObjName(content) & "') but our rows are in " &
         "_settingsRoot@0xa0 at " & iPtr(rowParent) & " ('" &
         iObjName(rowParent) & "'). Our rows are NOT in the scrolled content, " &
         "and no change to heights, fitters or layout groups can fix that."
    return
  let viewport = (if nuOk(sr, NuOffScrollViewport + 8'i32):
                    cNuGetRef(sr, NuOffScrollViewport) else: nil)
  let vg = nuReadGeom(viewport)
  let cgm = nuReadGeom(content)
  if not vg.ok or not cgm.ok:
    warn "postfx rows SCROLL VERDICT INCONCLUSIVE: m_Content is correct, but " &
         (if not vg.ok: "the viewport" else: "the content") &
         " did not read back a valid rect, so whether there is anything to " &
         "scroll is unknown."
    return
  var barActive = false
  let barT = (if host != nil: modsChildNamed(host, "Scrollbar") else: nil)
  let barGo = (if barT != nil: iGameObjectOf(barT) else: nil)
  if barGo != nil: barActive = nuActiveInHierarchy(barGo)
  if cgm.rectH > vg.rectH and barActive:
    okLog "postfx rows SCROLL VERDICT PASS: the ScrollRect under 'PostFX " &
          "Settings' names our row parent as m_Content@0x20, its content " &
          "resolves to " & nuF(cgm.rectH) & " px against a " & nuF(vg.rectH) &
          " px viewport (so there IS something to scroll), and the scrollbar " &
          "reads activeInHierarchy. Every number read from get_rect on the " &
          "live RectTransforms."
  else:
    warn "postfx rows SCROLL VERDICT FAIL: m_Content@0x20 is correct, but " &
         (if cgm.rectH <= vg.rectH:
            "the content resolves to " & nuF(cgm.rectH) &
            " px which is NOT taller than the " & nuF(vg.rectH) &
            " px viewport, so nothing can scroll -- the row parent has a " &
            "LayoutGroup but its height is not being driven (a " &
            "ContentSizeFitter is what does that on the Graphics page)"
          else:
            "the 'Scrollbar' child is not activeInHierarchy, so the page " &
            "scrolls with the wheel and shows the player nothing") & "."

proc pfxEnableToggle(): Il2CppPtr =
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
        if nuOk(t, 0x18'i32) and nuAlive(t): return t
      return nil
    i = i + 1

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

proc pfxGrayApply(enabled: bool; applied, declined: var int) =
  ## Every row of OURS except the 'enabled' row itself.
  applied = 0
  declined = 0
  var i = 0
  while i < gPfxRowCtrl.len and i < PfxMaxHandles:
    if i < gPfxRowName.len and gPfxRowName[i] != PfxEnableKey:
      let g = pfxRowGroup(gPfxRowCtrl[i])
      if g == nil: declined = declined + 1
      elif pfxGraySet(g, enabled): applied = applied + 1
      else: declined = declined + 1
    i = i + 1

proc pfxGrayVerdict(enabled: bool; applied, declined: int) =
  ## THE FINISHED STATE, read through the CanvasGroup GETTERS -- a different
  ## path than the setters that wrote it -- and stated as a NEGATIVE that can
  ## fail: with the enable toggle OFF, NO row of ours still reads free.
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
          let free = (alpha > 0.9'f32) and inter
          let blocked = (alpha < 0.9'f32) and not inter
          if (enabled and not free) or ((not enabled) and not blocked):
            wrong = wrong + 1
            if firstWrong.len == 0:
              firstWrong = gPfxRowName[i] & " (alpha " & nuF(alpha) &
                           ", interactable " &
                           (if inter: "true" else: "false") & ")"
    i = i + 1
  if judged == 0:
    warn "postfx rows GRAY-OUT VERDICT INCONCLUSIVE: not one of our " &
         $gPfxRowCtrl.len & " row(s) exposed a readable CanvasGroup through " &
         "SettingControl._blocker@0x88 -> UiElementBlocker.Group@0x20 (" &
         $declined & " declined at the walk). Nothing was judged, and 'I " &
         "could not look' is not a pass."
  elif wrong == 0:
    okLog "postfx rows GRAY-OUT VERDICT PASS: with 'Enable post-process' " &
          (if enabled: "ON" else: "OFF") & ", NO row of ours reads " &
          (if enabled: "blocked" else: "free") & " -- all " & $judged &
          " judged row(s) report CanvasGroup alpha " &
          (if enabled: "1.0 and interactable"
           else: "0.3 and non-interactable") &
          ", read back through get_alpha/get_interactable rather than from " &
          "what we wrote. " & $applied & " written, " & $declined &
          " declined for want of a blocker."
  else:
    warn "postfx rows GRAY-OUT VERDICT FAIL: " & $wrong & " of " & $judged &
         " judged row(s) do not match the enable toggle, which reads " &
         (if enabled: "ON" else: "OFF") & ". First: " & firstWrong &
         ". A row that looks live and is inert (or looks dead and is live) " &
         "is worse than no gray-out at all."

proc pfxGrayTick() =
  ## DEFECT 3, driven by POLLING our own 'enabled' toggle rather than by an
  ## onValueChanged delegate -- stated plainly because the alternative is not
  ## available: our rows are UNBOUND, and attaching a callback needs a managed
  ## `Action`, which needs runtime type injection. Injection is PLAUSIBLE on
  ## this build and UNPROVEN, so it is not used and nothing pretends it is.
  ## The poll is one field read and one call on ONE toggle per frame; the 26
  ## writes happen only on the EDGE, so there is no per-frame allocation.
  if not gPfxGrayInit:
    gPfxGrayInit = true
    gPfxGrayOn = readBoolKeyDef("settingsPostFxGrayOut", false)
  if not gPfxGrayOn or not gPfxBuilt: return
  let tog = pfxEnableToggle()
  if tog == nil:
    if not gPfxGraySaid:
      gPfxGraySaid = true
      warn "postfx rows GRAY-OUT INCONCLUSIVE: our 'enabled' row's " &
           "UpdatableToggle (SettingToggle.Toggle@0xa8) could not be " &
           "reached, so there is no state to mirror and NOTHING was written " &
           "to any row. The other 26 rows are left exactly as they were."
    return
  let (ok, on) = nuToggleIsOn(tog)
  if not ok: return
  if gPfxGrayHave and on == gPfxGrayApplied: return
  var applied = 0
  var declined = 0
  pfxGrayApply(on, applied, declined)
  gPfxGrayApplied = on
  gPfxGrayHave = true
  pfxGrayVerdict(on, applied, declined)

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
        "now: " & $built & " row(s) built, values are the mod's DECLARED " &
        "DEFAULTS rather than the saved config, and the rows are NOT BOUND " &
        "-- moving one changes nothing yet. Owned by the active Preset and " &
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
  if gPfxScrollOn:
    discard pfxScrollify(parent)
  pfxScrollVerdict(parent)
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
    gPfxScrollGo = nil
    gPfxScrollContentT = nil
  if gPfxBuilt and (gGfxPostGo == nil or not duOk(gGfxPostGo, 0x20'i32) or
                    not iUnityAlive(gGfxPostGo)):
    let n = pfxDestroyAll()
    okLog "postfx rows: the PostFX panel was destroyed under us; " & $n &
          " row(s) of ours were torn down and will be rebuilt on the next " &
          "visit. Nothing stale is left parented into a dead object."
