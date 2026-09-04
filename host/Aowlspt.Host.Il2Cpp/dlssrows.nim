## ===========================================================================
## dlssrows.nim -- the DLSS section on the stock GRAPHICS page (the GENERAL
## subtab), built by INSTANTIATING THE GAME'S OWN SETTINGS-ROW PREFABS.
##
## Same mechanism as `postfxrows.nim`, a different tab and a different mod:
## five rows for `aowl.dlss` go into the container the game's own 33 Graphics
## rows live in, so they look like -- because they ARE -- stock controls.
##
## WHERE THE ROWS GO, AND HOW THAT WAS OBTAINED
## --------------------------------------------
## `EFT.UI.Settings.GraphicsSettingsTab`, offsets read from
## `Il2CppMetadataRegistration.fieldOffsets` (`tools/fldoff.py fields
## EFT.UI.Settings.GraphicsSettingsTab`, the System.String self-check passing),
## never guessed and NOT shared with `PostFXSettingsTab`, whose numbers differ:
##
##     0x98  _settingsContainer         Transform            <- THE ROW PARENT
##     0xb0  _dropDownTemplate          SettingDropDown      (declined, below)
##     0xb8  _toggleTemplate            SettingToggle        <- PREFAB
##     0xc0  _selectSliderTemplate      SettingSelectSlider  (declined, below)
##     0xc8  _selectFloatSliderTemplate SettingFloatSlider   <- PREFAB
##
## `_settingsContainer` is the same object a live walk measured on the deployed
## build as holding "exactly the 33 stock rows and none of ours" (see the
## STOCK-GEOMETRY BASELINE note in `modstab.nim`), which is why it is the
## parent rather than the panel root: the panel's LayoutGroup drives it.
##
## The tab COMPONENT is reached by WALKING from `gGfxPanelT` -- the live
## "Graphics Settings" panel transform the subtab feature already located and
## validated -- and never by an offset that can read null.
##
## WHY THE TWO CHOICES ARE STEP-VALUED SLIDERS AND NOT DROPDOWNS
## -------------------------------------------------------------
## "DLSS version" and "Upscaler" are choices, and a native choice row is a
## `SettingDropDown` or a `SettingSelectSlider`. EVERY bind either of those has
## -- `BindTo`, `BindToEnum`, `UpdateDropDownValue`, all three
## `SettingSelectSlider.BindIndexTo` overloads -- is a GENERIC method with no
## entry in `methodPointers` and therefore NO RVA offline. `postfxrows.nim`
## declines `preset` and `tonemapper` for exactly that reason, and this file
## does not quietly un-decline it: instantiating a select-slider we cannot bind
## would render a control that moves and changes nothing.
##
## The two BINDABLE kinds on this build (`settingsbind.nim`, measured event
## routes) are a `Toggle` and a `NumberSlider`. So each choice is a slider with
## an integer range and an "F0" format -- a stepper, mutually exclusive by
## construction, which a set of independent toggles is not -- and the caption
## carries the mapping. The number is the same in all three surfaces (this row,
## the F12 overlay, `mods/dlss/config.json`), so they cannot drift.
##
## WHAT IS DECLINED, LOUDLY: TOOLTIPS
## ----------------------------------
## The brief asks for the schema's descriptions as tooltips.
## `SettingControl::SetTooltip(SettingsTooltipData, SettingsTooltip)`
## @0x16fac00 is unique and byte-verifiable, but its first argument is a
## managed `SettingsTooltipData` INSTANCE, and constructing one is runtime type
## injection -- PLAUSIBLE and UNPROVEN on this build. It is called with a real
## object or not at all, never with NULL. So NO tooltip is attached: the fact
## each description carries that a player must see -- "applies on restart", and
## what each step means -- is in the CAPTION instead, where `SetText` (a
## measured, unique, non-generic setter) really does put it.
##
## THE VALUES ARE THE CONFIG'S, OR THE DECLARED DEFAULTS, AND THE LOG SAYS WHICH
## ---------------------------------------------------------------------------
## `sbdRegisterSlider` / `sbdRegisterToggle` seed each row from the mod's live
## `/aowlspt/settings/aowl.dlss` page when `modSettingsRender` has fetched one,
## and return whether they did. Rows that were not seeded show the DECLARED
## default, and the verdict counts them separately -- printing a default and
## letting it read as the player's setting is a confident wrong answer.
##
## NOTHING HERE APPLIES ANYTHING. Every one of these takes effect on the next
## launch: `aowlspt-launch` runs `tools/dlssapply.py` before the client starts
## (the DLL is open in this process and OptiScaler read its ini at attach) and
## prints the PASS/FAIL verdict in the boot log. The captions say so.
##
## SAFETY, against the eight rules
## -------------------------------
##  1. No detour is bound here at all. Every call is a direct call to a
##     byte-verified prologue through `nuikit`'s target table
##     (`nuTargetsBindOk()` is checked before the first one).
##  2. Every pointer hop is `nuOk`/`nuAlive`/`duOk`-guarded.
##  3. NO guard is opened: this runs inside `gfxTickBody`'s single
##     `aowl_p_p_seh`, which is not re-entrant.
##  4. Every loop is capped (`DlrMaxRows`).
##  5. Flag-gated `settingsDlssRows`, DEFAULT OFF, and inert without
##     `settingsPostFxSubtab` (which is what locates the Graphics panel) and
##     `nativeUiKit`.
##  6. Self-disables after `DlrMaxFaults`.
##  7. After the one-shot build the tick is two boolean tests; no allocation.
##  8. Nothing stock is ever written. The rows are OURS -- they are not added
##     to `SettingsTab._createdControls`, so the game never destroys them and
##     this file destroys them itself on every screen close, which is also what
##     stops them duplicating when the page is re-entered.
## ===========================================================================

const
  DlrMaxFaults = 3
  DlrMaxRows = 8
  DlrGuid = "aowl.dlss"

  ## MEASURED, see the header. GraphicsSettingsTab's own numbers.
  DlrOffGfxContainer  = 0x98'i32
  DlrOffToggleTmpl    = 0xb8'i32
  DlrOffFloatSliderTmpl = 0xc8'i32

var gDlrOn = false        ## `settingsDlssRows` -- read once at boot
var gDlrOff = false       ## self-disabled
var gDlrBuilt = false
var gDlrTried = 0
var gDlrFaults = 0
var gDlrSaid = false
var gDlrRowGo: seq[Il2CppPtr] = @[]
var gDlrRowKey: seq[string] = @[]
var gDlrBuiltN = 0
var gDlrSeeded = 0
var gDlrRefused = 0

type
  DlrKind = enum dlrToggle, dlrSlider

  DlrRow = object
    kind*: DlrKind
    key*: string
    label*: string
    fmt*: string        ## NumberSlider::Show format; "F0" for the steppers
    lo*, hi*, def*: float32
    defB*: bool

proc dlrS(key, label, fmt: string; lo, hi, def: float32): DlrRow =
  DlrRow(kind: dlrSlider, key: key, label: label, fmt: fmt,
         lo: lo, hi: hi, def: def, defB: false)

proc dlrB(key, label: string; def: bool): DlrRow =
  DlrRow(kind: dlrToggle, key: key, label: label, fmt: "",
         lo: 0.0'f32, hi: 0.0'f32, def: 0.0'f32, defB: def)

proc dlrCatalogue(): seq[DlrRow] =
  ## The five settings `mods/dlss/dlss.nim:schema()` declares, with ITS ranges
  ## and ITS defaults. A STATIC MIRROR of that schema (the live values come
  ## from the fetch, the RANGES do not), so it drifts if the mod's schema
  ## changes -- `tools/dlssapply.py selftest` cross-checks the naming.
  @[dlrS("version",
         "DLSS version  (1 = 310.5.3 shipped / 2 = 310.7.0 / 3 = 310.7.129) - applies on restart",
         "F0", 1.0'f32, 3.0'f32, 2.0'f32),
    dlrS("upscaler",
         "Upscaler  (1 = DLSS / 2 = FSR 3.1 / 3 = XeSS) - applies on restart",
         "F0", 1.0'f32, 3.0'f32, 1.0'f32),
    dlrB("nrEnabled", "DLSS 5 re-lighting - applies on restart", false),
    dlrS("nrWorkingScale", "DLSS 5 working scale - applies on restart",
         "F2", 0.25'f32, 1.0'f32, 0.25'f32),
    dlrS("nrIntensity", "DLSS 5 intensity - applies on restart",
         "F2", 0.0'f32, 2.0'f32, 1.0'f32)]

proc dlrNoteFault(what: string) =
  inc gDlrFaults
  warn "dlss rows: " & what & " (fault " & $gDlrFaults & " of " &
       $DlrMaxFaults & ")"
  if gDlrFaults >= DlrMaxFaults:
    gDlrOff = true
    warn "dlss rows: self-disabled for this session after " & $gDlrFaults &
         " fault(s). No row of ours is left in the Graphics page."

proc dlrDestroyAll(): int =
  ## Tear down every row WE made. The game never will: they are deliberately
  ## not in `SettingsTab._createdControls` (that list is an instantiated
  ## generic whose layout is not reachable offline, and a raw write into one is
  ## a fabricated offset into a collection the game then iterates).
  result = 0
  var i = 0
  while i < gDlrRowGo.len and i < DlrMaxRows:
    let go = gDlrRowGo[i]
    if go != nil and duOk(go, 0x20'i32) and iUnityAlive(go):
      if nuDestroy(go): result = result + 1
    i = i + 1
  gDlrRowGo = @[]
  gDlrRowKey = @[]
  gDlrBuilt = false
  gDlrBuiltN = 0
  gDlrSeeded = 0
  gDlrRefused = 0

proc dlrTab(): Il2CppPtr =
  ## The live `GraphicsSettingsTab` COMPONENT, by WALKING from the validated
  ## "Graphics Settings" panel transform. `modsComponent` refuses a GameObject
  ## receiver up front, which is the fault this walk would otherwise take.
  result = nil
  if gGfxPanelT == nil or not duOk(gGfxPanelT, 0x20'i32): return
  if not iUnityAlive(gGfxPanelT): return
  result = modsComponent(gGfxPanelT, "GraphicsSettingsTab")
  if result != nil and not nuOk(result, DlrOffFloatSliderTmpl + 8'i32):
    result = nil

proc dlrMakeRow(prefab, parent: Il2CppPtr; r: DlrRow;
                sliderOut, ctrlOut: var Il2CppPtr): Il2CppPtr =
  ## ONE row, the game's own way. No `SetSiblingIndex` is called: `Instantiate`
  ## appends, which puts our section AFTER the stock rows -- and any index we
  ## chose would REORDER controls the game created, which is a write to stock
  ## state this file does not make.
  result = nil
  sliderOut = nil
  ctrlOut = nil
  let row = nuInstantiateUnder(prefab, parent)
  if row == nil: return
  let go = nuGameObjectOf(row)
  if go == nil:
    warn "dlss rows: the instantiated row for '" & r.key & "' has no " &
         "reachable GameObject, so it could be neither shown nor torn down. " &
         "Refusing this row."
    return
  # `SetText` takes a LOCALIZATION KEY; an aowlspt setting has no BSG locale
  # entry, so the literal renders as itself. A raw `m_text` store would be
  # clobbered by `LocalizedText`, which is why the setter is called.
  if not nuRowSetText(row, r.label):
    warn "dlss rows: SetText refused for '" & r.key & "'; the row would carry " &
         "the PREFAB's own caption, which reads as a stock setting that is " &
         "not there. Refusing this row."
    discard nuDestroy(go)
    return
  discard nuRowSetName(row, "aowlspt-dlss-" & r.key)
  if r.kind == dlrSlider:
    let sl = nuRowSlider(row)
    if sl == nil:
      warn "dlss rows: '" & r.key & "' instantiated but its inner NumberSlider " &
           "(SettingFloatSlider.Slider @0xa8) read null, so the row would show " &
           "a slider with no range and no value. Refusing it."
      discard nuDestroy(go)
      return
    if not nuSliderShow(sl, r.lo, r.hi, r.fmt):
      warn "dlss rows: NumberSlider::Show refused for '" & r.key & "' (range " &
           nuF(r.lo) & ".." & nuF(r.hi) & "). Refusing this row."
      discard nuDestroy(go)
      return
    discard nuSliderSetValue(sl, r.def)
    sliderOut = sl
  discard nuSetActive(go, true)
  ctrlOut = row
  result = go

proc dlrBuild(): bool =
  ## Build the five rows into the live Graphics panel. Called ONCE, from the
  ## tick, only after that panel has actually been observed up.
  result = false
  if gDlrBuilt or gDlrOff or not gDlrOn: return
  inc gDlrTried
  if not nuTargetsBindOk():
    dlrNoteFault("the aowl_nu_targets POSITIONAL self-check FAILED, so every " &
                 "call this file makes would go to the wrong method with the " &
                 "wrong frame. Nothing was built.")
    return
  let tab = dlrTab()
  if tab == nil:
    dlrNoteFault("the GraphicsSettingsTab component could not be reached by " &
                 "walking from the live 'Graphics Settings' panel transform. " &
                 "Without it there is no row parent and no prefab, so nothing " &
                 "was built.")
    return
  let parent = (if nuOk(tab, DlrOffGfxContainer + 8'i32):
                  cNuGetRef(tab, DlrOffGfxContainer) else: nil)
  if not nuOk(parent, 0x10'i32) or not nuAlive(parent):
    dlrNoteFault("GraphicsSettingsTab._settingsContainer @0x98 read null, " &
                 "unreadable or not a live Unity object. That field is " &
                 "serialized and is populated when the prefab loads, so this " &
                 "is 'asked too early' rather than a wrong offset. Nothing " &
                 "was built and nothing was parented anywhere.")
    return
  let togPrefab = (if nuOk(tab, DlrOffToggleTmpl + 8'i32):
                     cNuGetRef(tab, DlrOffToggleTmpl) else: nil)
  let sliPrefab = (if nuOk(tab, DlrOffFloatSliderTmpl + 8'i32):
                     cNuGetRef(tab, DlrOffFloatSliderTmpl) else: nil)
  if not nuOk(togPrefab, 0x10'i32) and not nuOk(sliPrefab, 0x10'i32):
    dlrNoteFault("NEITHER _toggleTemplate @0xb8 nor " &
                 "_selectFloatSliderTemplate @0xc8 read back as a live " &
                 "object, so there is no prefab to instantiate. Refusing to " &
                 "fall back to building controls from scratch.")
    return
  let rows = dlrCatalogue()
  gDlrRowGo = @[]
  gDlrRowKey = @[]
  var built = 0
  var refused = 0
  var seeded = 0
  var i = 0
  while i < rows.len and i < DlrMaxRows:
    let r = rows[i]
    let prefab = (if r.kind == dlrToggle: togPrefab else: sliPrefab)
    if not nuOk(prefab, 0x10'i32):
      refused = refused + 1
      i = i + 1
      continue
    var sl: Il2CppPtr = nil
    var ct: Il2CppPtr = nil
    let go = dlrMakeRow(prefab, parent, r, sl, ct)
    if go != nil:
      gDlrRowGo.add go
      gDlrRowKey.add r.key
      built = built + 1
      # THE VALUE BINDING (settingsbind.nim, flag `settingsRowsBind`, default
      # OFF -- with it off both calls do nothing and the row is a real control
      # that changes nothing). The pointers handed over are the ones this loop
      # ALREADY HOLDS; nothing is re-found by name or by index later.
      if r.kind == dlrToggle:
        if sbdRegisterToggle(DlrGuid, r.key, ct, r.defB):
          seeded = seeded + 1
      elif sl != nil:
        if sbdRegisterSlider(DlrGuid, r.key, sl, r.lo, r.hi, r.def):
          seeded = seeded + 1
    else:
      refused = refused + 1
    i = i + 1
  if built == 0:
    dlrNoteFault("zero rows were built out of " & $rows.len & " declared (" &
                 $refused & " refused). Nothing is left in the Graphics page.")
    discard dlrDestroyAll()
    return
  gDlrBuilt = true
  gDlrBuiltN = built
  gDlrSeeded = seeded
  gDlrRefused = refused
  result = true

proc dlrVerdict() =
  ## ONE line per visit to the page, and it states which values are on screen.
  if gDlrSaid or not gDlrBuilt: return
  gDlrSaid = true
  okLog "dlss rows: " & $gDlrBuiltN & " row(s) built into the stock Graphics " &
        "page (GraphicsSettingsTab._settingsContainer@0x98), " & $gDlrRefused &
        " refused. " & $gDlrSeeded & " of " & $gDlrBuiltN & " show the " &
        "player's CONFIG value; the other " & $(gDlrBuiltN - gDlrSeeded) &
        " show mods/dlss' DECLARED DEFAULT because no " &
        "/aowlspt/settings/aowl.dlss page had been fetched when they were " &
        "built (modSettingsRender). Nothing here applies anything: the " &
        "launcher's dlssapply.py step applies these before the next start " &
        "and prints the PASS/FAIL verdict in the boot log."

proc dlrOnPanelUp(gfxUp: bool) =
  ## Called every tick from `gfxTickBody`, inside its existing guard. The
  ## steady state is two boolean tests.
  if not gDlrOn or gDlrOff: return
  if not gfxUp: return
  if not gDlrBuilt:
    if gDlrTried < 4:
      discard dlrBuild()
    return
  dlrVerdict()

proc dlrOnScreenClosed() =
  ## The settings screen went away. Our rows are OURS -- the game's
  ## `CleanupCreatedControls` does not know about them -- so they are torn down
  ## here UNCONDITIONALLY and rebuilt on the next visit. That is what stops the
  ## section appearing twice, then three times, the way an owned row parented
  ## into a re-initialised stock container otherwise does.
  gDlrSaid = false
  if gDlrBuilt or gDlrRowGo.len > 0:
    let n = dlrDestroyAll()
    gDlrTried = 0
    if n > 0:
      okLog "dlss rows: the settings screen closed; " & $n & " row(s) of ours " &
            "were torn down and will be rebuilt on the next visit. Nothing " &
            "stale is left parented into the stock Graphics container."
