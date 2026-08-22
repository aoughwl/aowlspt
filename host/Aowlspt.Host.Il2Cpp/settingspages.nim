# settingspages.nim -- PHASE 3: a per-mod settings PAGE inside Tarkov's own
# settings screen.
#
# `include`d into `aowlhost.nim` after `settingswrite.nim`, whose primitives it
# is built entirely out of: the klass census that types a control without
# reflection, the label chain that can be written, and the guarded value
# read/write. It adds three things those do not have:
#
#   1. a SCHEMA -- a page is a name plus a list of rows, and a row is a config
#      key, a label, a kind and a default. This is the same shape mods already
#      declare through `aowlspt/settings` (`aowl/src/aowlspt/settings.nim`) and
#      already serve at `/aowlspt/settings/<guid>`; see the seam note below.
#   2. a RENDERER -- rows become real Unity controls by CLONING a stock control
#      of the right widget type and retargeting the clone. Cloning is the
#      reflection-free way to make a control on this build, and it is already
#      proven here (`invoke2.nim` STEP 5 clones a live settings label).
#   3. a BINDING -- the clone shows the config's value, and the value the player
#      leaves it at is read back and persisted.
#
# WHY CLONING RATHER THAN CREATING
# --------------------------------
# The game builds a row with `SettingsTab::CreateControl<T>` @0x2B86E20. That is
# ONE shared-generic body serving every T, with the T carried entirely in the
# hidden MethodInfo* -- and a shared generic is the single documented case where
# passing NULL for that MethodInfo is NOT safe (see `abi/aowlspt_invoke2.h`).
# Obtaining a real generic MethodInfo needs the metadata reflection that is dead
# on this build. So the row cannot be constructed; it can only be copied.
#
# THE SEAM (deliberate, and named so the next step is wiring rather than design)
# -----------------------------------------------------------------------------
# `swPageRegister` takes a fully-formed `SwPage`. This file ships ONE built-in
# page -- the aowlspt host's own flags, which the host can read without asking
# anyone. Every OTHER mod's page already exists as JSON at
# `/aowlspt/settings/<guid>`, in exactly the {key,label,type,value,min,max,
# options,implemented} shape `SwRow` mirrors field for field. Turning those into
# pages is a fetch and a parse into `swPageRegister`, not a redesign: the
# renderer below neither knows nor cares where a page came from.
#
# SAFETY
# ------
# Default OFF (`settingsPages`). Runs inside the settings postfix's existing
# `aowl_p_p_seh` guard and arms no second one (that guard is not re-entrant).
# Every pointer hop is `cIsReadable`-guarded, every loop is capped, every direct
# call is to a byte-verified prologue, and the whole thing shares
# `settingswrite.nim`'s fault budget -- two faults and it stops for the session.
# Nothing here ever writes to a control the GAME created: it writes only to
# clones it made itself, and it refuses to render at all if it cannot identify
# the widget type it needs.

# ---- the Phase 3 setter table (abi/aowlspt_settingswrite.h) ----
proc cSwFn(i: int32): Il2CppPtr {.importc: "aowl_sw_fn", nodecl.}
proc cSwFnName(i: int32): Il2CppPtr {.importc: "aowl_sw_name", nodecl.}
proc cSwFnRva(i: int32): uint32 {.importc: "aowl_sw_rva", nodecl.}
proc cSwFnCount(): int32 {.importc: "aowl_sw_target_count", nodecl.}
proc cSwFnOk(): int32 {.importc: "aowl_sw_ok_count", nodecl.}
proc cSwFnBad(): int32 {.importc: "aowl_sw_bad_count", nodecl.}
proc cSwCallVPF(fn, self: Il2CppPtr; v: float64) {.
  importc: "aowl_sw_call_v_pf", nodecl.}
proc cSwCallVPB(fn, self: Il2CppPtr; b: int32) {.
  importc: "aowl_sw_call_v_pb", nodecl.}
proc cSwCallVP(fn, self: Il2CppPtr) {.importc: "aowl_sw_call_v_p", nodecl.}

const
  SwToggleNoNotify  = 0'i32
  SwToggleSetIsOn   = 1'i32
  SwSliderNoNotify  = 2'i32
  SwSliderSetMin    = 3'i32
  SwSliderSetMax    = 4'i32
  SwSliderRepaint   = 5'i32

proc swFn(i: int32): Il2CppPtr =
  ## A byte-verified setter, or nil. Logged on refusal so a target that did not
  ## verify on this build is never mistaken for a row that rendered and did
  ## nothing.
  result = cSwFn(i)
  if result == nil:
    warn "settings pages: setter " & readCString(cSwFnName(i)) & " @ 0x" &
         hexOf(uint64(cSwFnRva(i))) & " did not verify on this build; the row " &
         "that needs it is skipped rather than rendered wrong"

# ---------------------------------------------------------------------------
# The schema
#
# Field-for-field the subset of `aowlspt/settings.Setting` that a NATIVE control
# can express. `stEnum`/`stString`/`stKeybind` have no clone-able widget yet and
# are carried as `swkStub` rows -- drawn, labelled, and honestly marked as not
# wired, which is the same discipline `implemented = false` already has in the
# schema module.
# ---------------------------------------------------------------------------
type
  SwKind* = enum
    swkStub                     ## drawn and labelled, bound to nothing yet
    swkToggle                   ## a bool -> SettingToggle clone
    swkSlider                   ## a float -> SettingFloatSlider clone

  SwRow* = object
    key*: string                ## the config key, verbatim
    label*: string              ## the text drawn on the row
    kind*: SwKind
    bval*: bool                 ## current value, for swkToggle
    fval*: float64              ## current value, for swkSlider
    lo*: float64
    hi*: float64
    implemented*: bool          ## false -> suffixed with the not-wired marker
    ## Filled by the renderer: the clone this row is showing on, and the value
    ## it was last seeded with, so a change made by the player can be spotted.
    clone*: uint64
    seeded*: bool

  SwPage* = object
    id*: string                 ## stable key, e.g. "host"
    title*: string              ## the heading row's text
    rows*: seq[SwRow]
    stub*: bool                 ## true -> render the heading + the stub note only
    note*: string               ## why it is a stub, shown to the player
    ## Renderer state: which tab object this page was last rendered into, so
    ## re-opening the tab does not render it twice.
    renderedFor*: uint64

## The marker a not-yet-wired row carries. Deliberately verbose: a settings row
## that silently does nothing is worse than no row, and this is the project's
## existing `implemented = false` convention made visible natively.
const cSwNotDone = "  (not done yet)"

## How many rows one page may render. A cap, not an expectation -- it bounds the
## clone count so a bad schema cannot instantiate hundreds of Unity objects into
## a live screen.
const cSwMaxRows = 24

var gSwPages: seq[SwPage] = @[]
## `settingsPages` -- Phase 3. Default OFF.
var gSwPagesOn = false
## How many times the entry point has been reached this session. Logged for the
## first few so the log SHOWS the path being taken rather than leaving its
## silence to be interpreted.
var gSwPagesFires = 0

proc swPageRegister(p: SwPage) =
  ## Add a page, replacing any page already registered under the same id. The
  ## replace matters for the seam: a page fetched from a mod's schema route is
  ## re-registered whenever the schema is re-fetched, and must not accumulate.
  var i = 0
  while i < gSwPages.len:
    if gSwPages[i].id == p.id:
      gSwPages[i] = p
      return
    i = i + 1
  gSwPages.add p

# ---------------------------------------------------------------------------
# Persistence -- one key of `aowlspt-host.json`, edited in place
#
# The host reads its flags with `readBoolKey`, a deliberately shallow scan that
# needs no JSON parser. The write is its exact mirror: find the key, replace the
# token after the colon, and put the file back. Nothing else in the file moves,
# so a hand-edited config keeps its comments-by-convention, its key order and
# its formatting.
#
# A key that is not in the file yet is INSERTED after the opening brace rather
# than appended, because appending would have to find the last value and worry
# about a trailing comma, and inserting only has to worry about whether the
# object is empty.
# ---------------------------------------------------------------------------
proc swBoolText(v: bool): string =
  if v: result = "true" else: result = "false"

proc swSetHostFlag(key: string; value: bool): bool =
  ## Persist one boolean into `aowlspt-host.json`. Returns false and changes
  ## nothing if the file cannot be read or written -- a setting that fails to
  ## persist is a log line, never a crash and never a truncated config.
  result = false
  let path = joinPath(gDir, "aowlspt-host.json")
  var text = ""
  if not readTextFile(path, text):
    warn "settings pages: cannot read " & path & "; '" & key &
         "' was not persisted"
    return
  let needle = "\"" & key & "\""
  let at = find(text, needle)
  var edited = ""
  if at < 0:
    # Not present: insert straight after the opening brace.
    let brace = find(text, "{")
    if brace < 0:
      warn "settings pages: " & path & " has no JSON object in it; '" & key &
           "' was not persisted"
      return
    # An empty object needs no trailing comma; anything else does.
    var rest = ""
    var j = brace + 1
    while j < text.len:
      rest.add text[j]
      j = j + 1
    var hasMore = false
    for ch in rest:
      if ch != ' ' and ch != '\t' and ch != '\r' and ch != '\n' and ch != '}':
        hasMore = true
        break
    var k = 0
    while k <= brace:
      edited.add text[k]
      k = k + 1
    edited.add "\n  \"" & key & "\": " & swBoolText(value)
    if hasMore:
      edited.add ","
    edited.add rest
  else:
    # Present: step past the key, the colon and any spaces, then replace the
    # token that follows with the new literal.
    var i = at + needle.len
    while i < text.len and (text[i] == ' ' or text[i] == ':' or
                            text[i] == '\t'):
      i = i + 1
    var j = i
    while j < text.len and text[j] != ',' and text[j] != '}' and
          text[j] != '\r' and text[j] != '\n':
      j = j + 1
    var k = 0
    while k < i:
      edited.add text[k]
      k = k + 1
    edited.add swBoolText(value)
    var m = j
    while m < text.len:
      edited.add text[m]
      m = m + 1
  if not writeTextFile(path, edited).ok:
    warn "settings pages: could not write " & path & "; '" & key &
         "' was not persisted (the file is unchanged)"
    return
  okLog "settings pages: persisted \"" & key & "\": " & swBoolText(value) &
        " into aowlspt-host.json"
  result = true

# ---------------------------------------------------------------------------
# The built-in page: the aowlspt host's own flags
#
# Every one of these is a real key `readBoolKey` already consumes at boot, so
# the page is honest by construction -- it shows the host's actual switches
# rather than a curated subset. They are marked `implemented = false` where the
# flag exists but changing it needs a restart to take effect, which is most of
# them: a detour is installed once, at boot, and cannot be un-installed by
# unticking a box.
# ---------------------------------------------------------------------------
proc swRow(key, label: string; value, wired: bool): SwRow =
  result = SwRow(key: key, label: label, kind: swkToggle, bval: value,
                 fval: 0.0, lo: 0.0, hi: 0.0, implemented: wired,
                 clone: 0'u64, seeded: false)

proc swBuildHostPage(): SwPage =
  ## The host-flags page, read fresh from `aowlspt-host.json` each time it is
  ## built, so it always shows what the file says rather than what the host
  ## happened to latch at boot.
  var rows: seq[SwRow] = @[]
  rows.add swRow("debugUi", "F3 debug panel", readBoolKey("debugUi"), false)
  rows.add swRow("debugEsp", "In-world AI markers", readBoolKey("debugEsp"), false)
  rows.add swRow("botDiag", "Bot registration logging", readBoolKey("botDiag"), false)
  rows.add swRow("unlimitedBots", "Lift the bot cap", readBoolKey("unlimitedBots"), false)
  rows.add swRow("botNav", "Bot navigation API", readBoolKey("botNav"), false)
  rows.add swRow("botAiActivate", "Bot AI activation rescue", readBoolKey("botAiActivate"), false)
  rows.add swRow("osCloseFix", "OS window-close fix", readBoolKey("osCloseFix"), false)
  rows.add swRow("uxVersionBrand", "Brand the version label", readBoolKey("uxVersionBrand"), false)
  rows.add swRow("uxMenuModeText", "Menu corner label", readBoolKey("uxMenuModeText"), false)
  rows.add swRow("settingsUiProbe", "Settings-screen probe", readBoolKey("settingsUiProbe"), false)
  rows.add swRow("settingsRelabelProbe", "Settings relabel proof", readBoolKey("settingsRelabelProbe"), false)
  rows.add swRow("settingsBindProbe", "Settings value read-back", readBoolKey("settingsBindProbe"), false)
  rows.add swRow("settingsPages", "Native mod settings pages", readBoolKey("settingsPages"), false)
  result = SwPage(id: "host", title: "aowlspt - host", rows: rows,
                  stub: false,
                  note: "These are the host's own switches. Every one is read " &
                        "once at boot, so a change here takes effect on the " &
                        "next launch.",
                  renderedFor: 0'u64)

# ---------------------------------------------------------------------------
# The renderer
# ---------------------------------------------------------------------------

proc swFirstControl(tabPtr: Il2CppPtr): Il2CppPtr =
  ## The first readable control on the tab, or nil. This is the object the rest
  ## of the renderer navigates from, and it is the one thing on this screen the
  ## host has PROVEN it can reach: the Phase-1.8 probe walked 25-33 of these per
  ## tab and decoded every label off them.
  result = nil
  if tabPtr == nil or cIsReadable(tabPtr, cSuiOffCreatedCtrls() + 8'i32) == 0'i32:
    return
  let lst = cReadPtrAt(tabPtr, cSuiOffCreatedCtrls())
  if lst == nil or cIsReadable(lst, cSuiOffListSize() + 4'i32) == 0'i32:
    return
  let arr = cReadPtrAt(lst, cSuiOffListItems())
  let size = cReadI32At(suiPtrAdd(lst, cSuiOffListSize()))
  if arr == nil or size <= 0'i32:
    return
  let n = (if size > int32(cSuiMaxControls): int32(cSuiMaxControls) else: size)
  for i in 0 ..< int(n):
    let slot = suiPtrAdd(arr, cSuiOffArrElems() + int32(i) * 8'i32)
    if cIsReadable(slot, 8'i32) == 0'i32:
      continue
    let control = cReadPtrAt(slot, 0'i32)
    if control != nil and cIsReadable(control, cSuiOffCtrlValue() + 8'i32) != 0'i32:
      return control

proc swRowContainerGo(tabPtr: Il2CppPtr; why: var string): Il2CppPtr =
  ## The GameObject a NEW ROW must be parented under: the container the tab's
  ## existing rows are children of.
  ##
  ## WHY NOT `_rectTransform`@0x78. That was the previous route and it is dead:
  ## live, on the real screen, it reads null/unreadable, so Phase 3 declined
  ## every time and nothing could ever be rendered. Rather than keep re-guessing
  ## an offset, this walks from an object the host has ALREADY VERIFIED it can
  ## reach and read -- a live SettingControl out of `_createdControls`@0x88,
  ## the list the probe decodes 25-33 correct labels from on every tab.
  ##
  ##   control (a MonoBehaviour, hence a Component)
  ##     -> Component::get_gameObject   -> the row's GameObject
  ##     -> GameObject::get_transform   -> the row's Transform
  ##     -> Transform::get_parent       -> the CONTAINER the rows live in
  ##     -> Component::get_gameObject   -> what SetParentAndAlign wants
  ##
  ## Being the parent of a real row is what makes this the right answer rather
  ## than a plausible one: a new child of that container is a SIBLING of the
  ## stock rows, so the tab's own layout group positions it exactly as it
  ## positions everything else, and it inherits the same canvas by construction.
  ## This is the identical lesson the debug overlay learned the hard way -- reach
  ## a container by walking from a verified live object, never by an offset that
  ## can read null.
  ##
  ## Every hop names itself and its pointer on failure. A silent decline here is
  ## what cost three cycles.
  result = nil
  why = ""
  let control = swFirstControl(tabPtr)
  if control == nil:
    why = "the tab has no readable control in _createdControls (+0x" &
          hexOf(uint64(cSuiOffCreatedCtrls())) & ") to navigate from"
    return
  let fnGo = mi2Fn(Mi2GetGameObject)
  let fnTr = mi2Fn(Mi2GoGetTransform)
  let fnPar = cDuFn(DuGetParent)
  if fnGo == nil or fnTr == nil or fnPar == nil:
    why = "a navigation target did not verify on this build (get_gameObject=" &
          (if fnGo != nil: "OK" else: "REJECTED") & " get_transform=" &
          (if fnTr != nil: "OK" else: "REJECTED") & " get_parent=" &
          (if fnPar != nil: "OK" else: "REJECTED") & ")"
    return
  let rowGo = cMi2CallPP(fnGo, control)
  if rowGo == nil or cIsReadable(rowGo, 0x20'i32) == 0'i32:
    why = "Component::get_gameObject(control=0x" &
          hexOf(cast[uint64](control)) & ") gave 0x" &
          hexOf(cast[uint64](rowGo)) & ", which is not readable"
    return
  let rowT = cMi2CallPP(fnTr, rowGo)
  if rowT == nil or cIsReadable(rowT, 0x20'i32) == 0'i32:
    why = "GameObject::get_transform(rowGo=0x" & hexOf(cast[uint64](rowGo)) &
          ") gave 0x" & hexOf(cast[uint64](rowT)) & ", which is not readable"
    return
  let contT = cDuCallPP(fnPar, rowT)
  if contT == nil or cIsReadable(contT, 0x20'i32) == 0'i32:
    why = "Transform::get_parent(rowT=0x" & hexOf(cast[uint64](rowT)) &
          ") gave 0x" & hexOf(cast[uint64](contT)) &
          " -- the row appears to have no parent, which cannot be right"
    return
  let contGo = cMi2CallPP(fnGo, contT)
  if contGo == nil or cIsReadable(contGo, 0x20'i32) == 0'i32:
    why = "Component::get_gameObject(containerT=0x" &
          hexOf(cast[uint64](contT)) & ") gave 0x" &
          hexOf(cast[uint64](contGo)) & ", which is not readable"
    return
  okLog "settings pages: row container reached by walking from a live control" &
        " -- control=0x" & hexOf(cast[uint64](control)) &
        " rowGo=0x" & hexOf(cast[uint64](rowGo)) &
        " rowT=0x" & hexOf(cast[uint64](rowT)) &
        " containerT=0x" & hexOf(cast[uint64](contT)) &
        " containerGo=0x" & hexOf(cast[uint64](contGo)) &
        ". New rows become siblings of the stock rows, so the tab's own " &
        "layout group places them."
  result = contGo

proc swAnyDonor(tabPtr: Il2CppPtr; kind: var string): Il2CppPtr =
  ## A donor row when the klass census could not name a toggle.
  ##
  ## The census learns 'toggle' by matching the stock English label
  ## 'Enable VoIP'. On a client whose language is not English -- or on any build
  ## where that row moves or is renamed -- it never learns, `gSwKlassToggle`
  ## stays 0, and Phase 3 declined with `toggleKlass=0x0`. Refusing to draw
  ## anything because one label did not match is a worse answer than drawing a
  ## row cloned from whatever the tab actually has: a row is a row, we relabel
  ## it ourselves, and a row we cannot BIND is still honestly marked as such.
  ##
  ## So: prefer the learned toggle; otherwise take the most common klass on the
  ## tab (settings tabs are mostly toggles and sliders, so the mode is a real
  ## row and not an oddity); otherwise the first control there is.
  result = nil
  kind = "none"
  let byKlass = swFindDonor(tabPtr, gSwKlassToggle)
  if byKlass != nil:
    kind = "learned toggle klass 0x" & hexOf(gSwKlassToggle)
    return byKlass
  # The most common klass on the tab.
  #
  # Counted by a plain double loop over the control list rather than with a
  # scratch table: nimony insists a local be provably initialised before it is
  # read, an `array` of counters is not, and the list is capped at
  # `cSuiMaxControls` anyway -- so the quadratic version is both simpler and
  # bounded by a number the probe has already measured (25-33 in practice).
  var best = 0'u64
  var bestN = 0
  let lst = (if tabPtr != nil and
                cIsReadable(tabPtr, cSuiOffCreatedCtrls() + 8'i32) != 0'i32:
               cReadPtrAt(tabPtr, cSuiOffCreatedCtrls())
             else: nil)
  if lst != nil and cIsReadable(lst, cSuiOffListSize() + 4'i32) != 0'i32:
    let arr = cReadPtrAt(lst, cSuiOffListItems())
    let size = cReadI32At(suiPtrAdd(lst, cSuiOffListSize()))
    if arr != nil and size > 0'i32:
      let n = int(if size > int32(cSuiMaxControls): int32(cSuiMaxControls)
                  else: size)
      for i in 0 ..< n:
        let si = suiPtrAdd(arr, cSuiOffArrElems() + int32(i) * 8'i32)
        if cIsReadable(si, 8'i32) == 0'i32:
          continue
        let ci = cReadPtrAt(si, 0'i32)
        if ci == nil or cIsReadable(ci, cSuiOffCtrlValue() + 8'i32) == 0'i32:
          continue
        let k = cast[uint64](cReadPtrAt(ci, 0'i32))
        if k == 0'u64:
          continue
        var cnt = 0
        for j in 0 ..< n:
          let sj = suiPtrAdd(arr, cSuiOffArrElems() + int32(j) * 8'i32)
          if cIsReadable(sj, 8'i32) == 0'i32:
            continue
          let cj = cReadPtrAt(sj, 0'i32)
          if cj == nil or cIsReadable(cj, cSuiOffCtrlValue() + 8'i32) == 0'i32:
            continue
          if cast[uint64](cReadPtrAt(cj, 0'i32)) == k:
            cnt = cnt + 1
        if cnt > bestN:
          bestN = cnt
          best = k
  if best != 0'u64:
    let byMode = swFindDonor(tabPtr, best)
    if byMode != nil:
      kind = "most common klass 0x" & hexOf(best) & " (" & $bestN &
             " row(s) of it on this tab; the toggle klass was never learned, " &
             "so the donor is chosen by shape rather than by name)"
      return byMode
  let any = swFirstControl(tabPtr)
  if any != nil:
    kind = "the first readable control on the tab (no klass census at all)"
    return any

proc swFindDonor(tabPtr: Il2CppPtr; wantKlass: uint64): Il2CppPtr =
  ## The first control on this tab whose klass is `wantKlass` -- the row we will
  ## copy. Returns nil if the tab has none, which is the correct answer: a page
  ## that needs a toggle cannot be rendered onto a tab that has no toggle to
  ## copy, and rendering something else would be worse than rendering nothing.
  result = nil
  if wantKlass == 0'u64 or tabPtr == nil:
    return
  if cIsReadable(tabPtr, cSuiOffCreatedCtrls() + 8'i32) == 0'i32:
    return
  let lst = cReadPtrAt(tabPtr, cSuiOffCreatedCtrls())
  if lst == nil or cIsReadable(lst, cSuiOffListSize() + 4'i32) == 0'i32:
    return
  let arr = cReadPtrAt(lst, cSuiOffListItems())
  let size = cReadI32At(suiPtrAdd(lst, cSuiOffListSize()))
  if arr == nil or size <= 0'i32:
    return
  let n = (if size > int32(cSuiMaxControls): int32(cSuiMaxControls) else: size)
  for i in 0 ..< int(n):
    let slot = suiPtrAdd(arr, cSuiOffArrElems() + int32(i) * 8'i32)
    if cIsReadable(slot, 8'i32) == 0'i32:
      continue
    let control = cReadPtrAt(slot, 0'i32)
    if control == nil or cIsReadable(control, cSuiOffCtrlValue() + 8'i32) == 0'i32:
      continue
    if cast[uint64](cReadPtrAt(control, 0'i32)) == wantKlass:
      return control

proc swCloneRow(donor, parentGo: Il2CppPtr; text: string): Il2CppPtr =
  ## Clone one stock control, put it in the live hierarchy, and label it.
  ## Returns the cloned CONTROL (not its GameObject), or nil if any step
  ## refused. Every step is a byte-verified direct call; none is a shared
  ## generic, so the NULL MethodInfo is safe for all of them.
  result = nil
  let fnInst = mi2Fn(Mi2Instantiate)
  if fnInst == nil or donor == nil:
    return
  swCrumbP("Object::Instantiate(donor) for row '" & text & "' donor", donor)
  let clone = cMi2CallPS1(fnInst, donor)
  if clone == nil or cIsReadable(clone, cSuiOffCtrlValue() + 8'i32) == 0'i32:
    warn "settings pages: Instantiate returned nothing usable for row '" &
         text & "'; the row is skipped"
    return
  # Into the hierarchy. Without a parent under the Canvas a cloned UI object
  # exists but is not drawn, so this is not cosmetic.
  let fnGo = mi2Fn(Mi2GetGameObject)
  if fnGo == nil or parentGo == nil:
    warn "settings pages: row '" & text & "' has no parent to go under " &
         "(get_gameObject=" & (if fnGo != nil: "OK" else: "REJECTED") &
         " parentGo=0x" & hexOf(cast[uint64](parentGo)) &
         "); the clone is left unparented and is NOT drawn"
  else:
    swCrumbP("Component::get_gameObject(clone) for row '" & text & "' clone",
             clone)
    let cloneGo = cMi2CallPP(fnGo, clone)
    if cloneGo == nil:
      warn "settings pages: Component::get_gameObject on the clone for row '" &
           text & "' returned null; it cannot be parented or shown"
    else:
      let fnPar = mi2Fn(Mi2SetParentAlign)
      if fnPar != nil:
        swCrumbP("SetParentAndAlign(cloneGo, parentGo) for row '" & text &
                 "' cloneGo", cloneGo)
        cMi2CallVS2(fnPar, cloneGo, parentGo)
      else:
        warn "settings pages: TMP_DefaultControls::SetParentAndAlign did not " &
             "verify on this build; row '" & text & "' cannot be placed"
      let fnAct = mi2Fn(Mi2GoSetActive)
      if fnAct != nil:
        swCrumbP("GameObject::SetActive(true) for row '" & text & "' cloneGo",
                 cloneGo)
        cMi2CallVPB(fnAct, cloneGo, 1'i32)
  # The label, by the SAME setter-first path the relabel now uses: a clone
  # inherits the donor's LocalizedText, which would otherwise put the donor's
  # own localised string back over ours the moment the row is enabled.
  swCrumbP("swControlTmp(clone) -- the label chain for row '" & text &
           "' clone", clone)
  let tmp = swControlTmp(clone)
  if tmp != nil:
    swCrumbP("relabel row '" & text & "' tmp", tmp)
    if swRelabelControl(clone, tmp, text):
      okLog "settings pages: cloned row '" & text & "' (control=0x" &
            hexOf(cast[uint64](clone)) & ") labelled via " & gSwLastRoutes
    else:
      warn "settings pages: the clone for row '" & text & "' could not be " &
           "labelled; it is left showing the donor's text"
  else:
    warn "settings pages: the clone for row '" & text & "' has no reachable " &
         "TMP label; it is left showing the donor's text"
  result = clone

proc swSeedToggle(control: Il2CppPtr; value: bool): bool =
  ## Show `value` on a cloned toggle. Uses `SetIsOnWithoutNotify`, NOT
  ## `set_isOn`: a clone inherits the donor's `onValueChanged` listeners, so the
  ## notifying setter would run the GAME's handler for the stock setting the
  ## donor came from -- with our value. Without-notify repaints and stays quiet.
  result = false
  if control == nil or cIsReadable(control, cSuiOffCtrlValue() + 8'i32) == 0'i32:
    return
  let widget = cReadPtrAt(control, cSuiOffCtrlValue())
  if widget == nil or cIsReadable(widget, cSwOffToggleIsOn() + 4'i32) == 0'i32:
    return
  let fn = swFn(SwToggleNoNotify)
  if fn == nil:
    # Fall back to the raw store: the model will be right even though the
    # checkmark will not move until the player clicks it. Better than a row
    # whose value is simply the donor's.
    return cDuWriteU8(widget, cSwOffToggleIsOn(),
                      (if value: 1'i32 else: 0'i32)) != 0'i32
  cSwCallVPB(fn, widget, (if value: 1'i32 else: 0'i32))
  result = true

## One-shot, so a full page does not print sixty lines.
var gSwGeomDumped = false

proc swDescribeGo(tag: string; comp: Il2CppPtr) =
  ## Everything about one row that can decide whether it is on screen. Read-only
  ## and every call guarded by the same `duOk`/`cIsReadable` discipline the rest
  ## of this file uses; `comp` is a Component (a SettingControl or a TMP).
  ##
  ## This exists because "rows cloned and labelled" and "the user sees nothing"
  ## are both true at once, and the difference between them is geometry we have
  ## never once looked at. The rule in this codebase is that the client tells
  ## you.
  if comp == nil or cIsReadable(comp, 0x20'i32) == 0'i32:
    okLog "settings pages/geom " & tag & ": component not readable"
    return
  let fnGo = mi2Fn(Mi2GetGameObject)
  let fnTr = mi2Fn(Mi2GoGetTransform)
  if fnGo == nil or fnTr == nil:
    okLog "settings pages/geom " & tag & ": navigation targets unavailable"
    return
  swCrumbP("geom dump " & tag & " get_gameObject", comp)
  let go = cMi2CallPP(fnGo, comp)
  if go == nil or cIsReadable(go, 0x20'i32) == 0'i32:
    okLog "settings pages/geom " & tag & ": no readable GameObject"
    return
  swCrumbP("geom dump " & tag & " get_transform", go)
  let t = cMi2CallPP(fnTr, go)
  okLog "settings pages/geom " & tag & ": comp=0x" & hexOf(cast[uint64](comp)) &
        " go=0x" & hexOf(cast[uint64](go)) &
        " name='" & duNameOf(go) & "'" &
        " activeSelf=" & duDescribeInt(DuGoActiveSelf, go) &
        " activeInHierarchy=" & duDescribeInt(DuGoActiveInHier, go) &
        " layer=" & duDescribeInt(DuGoLayer, go)
  if t != nil and cIsReadable(t, 0x20'i32) != 0'i32:
    okLog "settings pages/geom " & tag & ": rect=[" & duDescribeRect(t) & "]" &
          " anchoredPos=" & duDescribeVec2(DuGetAnchoredPos, t) &
          " sizeDelta=" & duDescribeVec2(DuGetSizeDelta, t) &
          " anchorMin=" & duDescribeVec2(DuGetAnchorMin, t) &
          " pivot=" & duDescribeVec2(DuGetPivot, t) &
          " localPos=" & duDescribeVec3(DuGetLocalPos, t) &
          " localScale=" & duDescribeVec3(DuGetLocalScale, t)
    # Two levels of parent, named. If the clone landed somewhere with a zero
    # rect, or under something inactive, this is where it shows.
    let fnPar = cDuFn(DuGetParent)
    if fnPar != nil:
      swCrumbP("geom dump " & tag & " get_parent", t)
      let p1 = cDuCallPP(fnPar, t)
      if p1 != nil and cIsReadable(p1, 0x20'i32) != 0'i32:
        let p1go = cMi2CallPP(fnGo, p1)
        okLog "settings pages/geom " & tag & ": parent[0]=0x" &
              hexOf(cast[uint64](p1)) & " name='" &
              (if p1go != nil: duNameOf(p1go) else: "") & "'" &
              " activeSelf=" & duDescribeInt(DuGoActiveSelf, p1go) &
              " rect=[" & duDescribeRect(p1) & "]" &
              " localScale=" & duDescribeVec3(DuGetLocalScale, p1)

proc swDumpRowGeometry(donor, clone, parentGo: Il2CppPtr) =
  ## DONOR vs CLONE, side by side. Whatever differs between a row the game drew
  ## and a row we drew is the reason ours is not visible.
  okLog "settings pages/geom: --- donor vs clone, one shot ---"
  swDescribeGo("DONOR(control)", donor)
  swDescribeGo("CLONE(control)", clone)
  let dTmp = swControlTmp(donor)
  let cTmp = swControlTmp(clone)
  if dTmp != nil:
    swDescribeGo("DONOR(label TMP)", dTmp)
  if cTmp != nil:
    swDescribeGo("CLONE(label TMP)", cTmp)
  let fnTr = mi2Fn(Mi2GoGetTransform)
  if parentGo != nil and fnTr != nil and cIsReadable(parentGo, 0x20'i32) != 0'i32:
    swCrumbP("geom dump PARENT get_transform", parentGo)
    let pt = cMi2CallPP(fnTr, parentGo)
    if pt != nil and cIsReadable(pt, 0x20'i32) != 0'i32:
      okLog "settings pages/geom PARENT: go=0x" &
            hexOf(cast[uint64](parentGo)) & " name='" & duNameOf(parentGo) &
            "' rect=[" & duDescribeRect(pt) & "]" &
            " activeSelf=" & duDescribeInt(DuGoActiveSelf, parentGo) &
            " localScale=" & duDescribeVec3(DuGetLocalScale, pt)

proc swRenderPage(tabPtr, parentGo: Il2CppPtr; page: var SwPage): int =
  ## Render one page's rows onto a tab. Returns how many rows were rendered.
  ##
  ## A heading row comes first, then one row per schema row. A stub page renders
  ## its heading and its note and stops -- which is the point of `stub`: the
  ## player sees the page exists and is told plainly that it does nothing yet.
  result = 0
  var donorKind = ""
  let donorToggle = swAnyDonor(tabPtr, donorKind)
  if donorToggle == nil:
    warn "settings pages: DECLINED -- page '" & page.id & "' has no row on " &
         "this tab to clone at all (tabPtr=0x" & hexOf(cast[uint64](tabPtr)) &
         ", learned toggle klass=0x" & hexOf(gSwKlassToggle) &
         "); nothing rendered and nothing written"
    return
  okLog "settings pages: page '" & page.id & "' donor=0x" &
        hexOf(cast[uint64](donorToggle)) & " chosen by " & donorKind &
        "; parent=0x" & hexOf(cast[uint64](parentGo))
  # The heading, cloned from the same donor so it inherits the row styling. It
  # is a toggle underneath, which is not ideal and IS honest: there is no label
  # widget to clone on a settings tab that we can identify without reflection.
  swCrumb("render the heading row for page '" & page.id & "'")
  discard swCloneRow(donorToggle, parentGo, page.title)
  if page.stub:
    discard swCloneRow(donorToggle, parentGo, page.note & cSwNotDone)
    okLog "settings pages: page '" & page.id & "' is a STUB -- heading and " &
          "note rendered, no rows bound"
    return
  var i = 0
  while i < page.rows.len and result < cSwMaxRows:
    var text = page.rows[i].label
    if not page.rows[i].implemented:
      text = text & cSwNotDone
    swCrumb("render row " & $i & " of " & $page.rows.len & " ('" & text & "')")
    let clone = swCloneRow(donorToggle, parentGo, text)
    if clone != nil:
      page.rows[i].clone = cast[uint64](clone)
      if page.rows[i].kind == swkToggle:
        swCrumbP("swSeedToggle for row '" & text & "' clone", clone)
        page.rows[i].seeded = swSeedToggle(clone, page.rows[i].bval)
      result = result + 1
      # ONE-SHOT GEOMETRY DUMP. Rows are being cloned and labelled and the user
      # sees nothing, so the next question is WHERE they went -- and that is a
      # question to ask the client, not to reason about. Dump the donor and the
      # first clone side by side; every field the two share is inherited and
      # every field that differs is ours.
      if not gSwGeomDumped:
        gSwGeomDumped = true
        swDumpRowGeometry(donorToggle, clone, parentGo)
    i = i + 1
  okLog "settings pages: page '" & page.id & "' rendered " & $result &
        " row(s) of " & $page.rows.len

proc swReadBackPage(page: var SwPage) =
  ## Read every rendered row's live value and persist the ones the player
  ## changed. This is the half that makes the page a SETTING rather than a
  ## display: the click went through the game's own toggle path, and this is
  ## where the result comes back to us.
  ##
  ## Only rows this page actually seeded are read: a row whose clone failed has
  ## `clone == 0` and is skipped rather than guessed at.
  var i = 0
  while i < page.rows.len:
    if page.rows[i].clone != 0'u64 and page.rows[i].kind == swkToggle:
      let control = cast[Il2CppPtr](page.rows[i].clone)
      swCrumbP("read back row '" & page.rows[i].key & "' clone", control)
      var ok = false
      let live = swReadToggle(control, ok)
      if ok and live != page.rows[i].bval:
        okLog "settings pages: row '" & page.rows[i].key & "' changed " &
              swBoolText(page.rows[i].bval) & " -> " & swBoolText(live) &
              " in game"
        if swSetHostFlag(page.rows[i].key, live):
          page.rows[i].bval = live
    i = i + 1

proc swPagesOnTabBuilt(tabPtr: Il2CppPtr; tabName: string; revisit: bool) =
  ## Phase 3, driven off the same ShowScreen postfix everything else here uses.
  ##
  ## Pages are rendered onto ONE tab (`game`), not spread across the stock tabs:
  ## a mod's settings do not belong under Sound, and putting them all in one
  ## place is what the player asked for. A tab of our own would be the right
  ## answer and needs a `SettingsTab` we cannot construct -- see the note at the
  ## top of this file about shared generics.
  ##
  ## EVERY early return announces itself. The previous build's worst failure
  ## mode was this feature doing nothing AND saying nothing: the banner printed
  ## at boot, the hook demonstrably fired (Phase 2a/2b logged on the same
  ## postfix), and across a full pass of every tab there was not one page line,
  ## not one clone line and not one fault line. A path that declines must say
  ## why, or it cannot be debugged from a log at all.
  if gSwPagesOn:
    inc gSwPagesFires
    if gSwPagesFires <= 8:
      okLog "settings pages: entry #" & $gSwPagesFires & " tab='" & tabName &
            "' tabPtr=0x" & hexOf(cast[uint64](tabPtr)) &
            " on=" & (if gSwPagesOn: "true" else: "false") &
            " off=" & (if gSwOff: "true" else: "false") &
            " pages=" & $gSwPages.len &
            " toggleKlass(before census)=0x" & hexOf(gSwKlassToggle)
  if swVisitBlocked():
    if gSwPagesOn and gSwPagesFires <= 8:
      okLog "settings pages: DECLINED -- " &
            (if gSwOff: "the SESSION fault ceiling has been reached; nothing " &
                        "further is rendered this session"
             else: "this TAB VISIT has spent its fault budget; re-open the " &
                   "tab to try again (the feature is still armed)")
    return
  if not gSwPagesOn:
    return                              # flag off: silence is the correct answer
  if tabPtr == nil:
    okLog "settings pages: DECLINED -- the tab pointer was nil"
    return
  if tabName != "game":
    if gSwPagesFires <= 8:
      okLog "settings pages: DECLINED -- pages render only onto the Game tab " &
            "and this is '" & tabName & "' (expected; open Settings -> Game)"
    return
  let tabKey = cast[uint64](tabPtr)
  # Learn the widget-klass census OURSELVES rather than relying on Phase 2
  # having been switched on. Phase 3 previously depended on `settingsRelabel
  # Probe`/`settingsBindProbe` for its klass pointers without saying so, which
  # meant `settingsPages` alone could only ever decline.
  swLearnTabKlasses(tabPtr)
  if gSwPagesFires <= 8:
    okLog "settings pages: after the census on this same tab visit -- " &
          "toggle=0x" & hexOf(gSwKlassToggle) &
          " float=0x" & hexOf(gSwKlassFloat) &
          " dropdown=0x" & hexOf(gSwKlassDropdown) &
          " select=0x" & hexOf(gSwKlassSelect) &
          ". A zero here means the stock anchor label for that type was not " &
          "found on this tab (a non-English client will do that), which is why " &
          "the donor is no longer required to be a learned toggle."
  # The registry is rebuilt from the config each time the tab is opened, so the
  # rows show what the file currently says.
  if gSwPages.len == 0:
    swPageRegister(swBuildHostPage())
    okLog "settings pages: registry was empty; built the host page -> " &
          $gSwPages.len & " page(s), " &
          (if gSwPages.len > 0: $gSwPages[0].rows.len else: "0") & " row(s)"
  if gSwPages.len == 0:
    warn "settings pages: DECLINED -- the page registry is STILL empty after " &
         "building the host page. Nothing can be rendered; this is a host bug, " &
         "not a game one, and nothing was written to the settings screen."
    return
  var i = 0
  while i < gSwPages.len:
    # Read back BEFORE deciding whether to re-render, so a value the player
    # changed is captured even on the pass that decides to rebuild the page.
    if gSwPages[i].renderedFor == tabKey:
      swReadBackPage(gSwPages[i])
      # Still rendered into this same tab object; nothing to rebuild. A clone
      # that has been destroyed under us reads unreadable, and that is what
      # forces a re-render.
      var alive = false
      var r = 0
      while r < gSwPages[i].rows.len:
        if gSwPages[i].rows[r].clone != 0'u64 and
           cIsReadable(cast[Il2CppPtr](gSwPages[i].rows[r].clone), 8'i32) != 0'i32:
          alive = true
          break
        r = r + 1
      if alive:
        i = i + 1
        continue
      okLog "settings pages: page '" & gSwPages[i].id & "' lost its clones " &
            "(the tab was rebuilt under it); re-rendering"
    var why = ""
    let parentGo = swRowContainerGo(tabPtr, why)
    if parentGo == nil:
      warn "settings pages: DECLINED -- could not reach the row container (" &
           why & "); page '" & gSwPages[i].id &
           "' is not rendered (nothing was written)"
      i = i + 1
      continue
    discard swRenderPage(tabPtr, parentGo, gSwPages[i])
    gSwPages[i].renderedFor = tabKey
    i = i + 1
