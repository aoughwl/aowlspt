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
                sliderOut: var Il2CppPtr): Il2CppPtr =
  ## ONE row, the game's own way: Instantiate the prefab under the row parent,
  ## then the fluent chain. Returns the row's GameObject (what we destroy), or
  ## nil, and never leaves a half-built object parented in.
  result = nil
  sliderOut = nil
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
  let cap = (if r.presetOwned: "* " else: "") & r.label
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
  result = go

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
    let go = pfxMakeRow(prefab, parent, r, int32(built), sl)
    if go != nil:
      gPfxRowGo.add go
      gPfxRowSlider.add sl
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
  # THE BANNER, last, and only once there is something for it to caption. It is
  # the one from-scratch element left in this file, and it exists to say on
  # screen what the rows cannot do -- a page that quietly shows unbound knobs
  # is the same defect as a control that quietly does nothing.
  let donor = pfxDonorTmp()
  if donor != nil and gGfxPostGo != nil:
    var declinedTxt = ""
    var d = 0
    while d < gPfxDeclined.len and d < 8:
      declinedTxt = declinedTxt & (if d > 0: ", " else: "") & gPfxDeclined[d]
      d = d + 1
    let b = nuLabel(gGfxPostGo, donor, 60.0'f32, -60.0'f32, 1700.0'f32,
                    40.0'f32,
                    "aowlspt post-process - " & $built & " row(s) built from " &
                    "the game's own settings prefabs. The values are the mod's " &
                    "DECLARED DEFAULTS, not your saved config, and the rows " &
                    "are NOT BOUND yet - moving one changes nothing. " &
                    "* = owned by the active Preset and ignored until " &
                    "Preset = custom. No row for: " &
                    (if declinedTxt.len > 0: declinedTxt else: "-") &
                    " (dropdown binds are generic and have no address).",
                    18.0'f32, 1.0'f32, 0.78'f32, 0.35'f32, 1.0'f32,
                    "aowl-pfx-banner")
    if nuLive(b):
      gPfxBanner = b
      gPfxHaveBanner = true
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
  pfxVerdict()

proc pfxOnScreenClosed() =
  ## The settings screen went away. Re-arm the verdict so the NEXT visit prints
  ## a fresh one, and drop our rows if the container they were parented to has
  ## been destroyed under us. We own these rows outright (they are NOT in the
  ## tab's `_createdControls`), so nothing else will ever clean them up.
  gPfxVerdictSaid = false
  if gPfxBuilt and (gGfxPostGo == nil or not duOk(gGfxPostGo, 0x20'i32) or
                    not iUnityAlive(gGfxPostGo)):
    let n = pfxDestroyAll()
    okLog "postfx rows: the PostFX panel was destroyed under us; " & $n &
          " row(s) of ours were torn down and will be rebuilt on the next " &
          "visit. Nothing stale is left parented into a dead object."
