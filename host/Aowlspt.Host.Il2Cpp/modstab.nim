# modstab.nim -- A SIXTH TAB IN TARKOV'S OWN SETTINGS SCREEN, WITH SUBTABS.
#
# `include`d into `aowlhost.nim` LAST, after `inspect.nim`, because it stands on
# that file's Transform walkers (`iChildAt`, `iChildCount`, `iObjName`,
# `iToTransform`, `iGameObjectOf`, `iUnityAlive`), on `debugui.nim`'s `duOk` and
# `mi2Fn`/`cMi2Call*` byte-verified call targets, and on `settingspages.nim`'s
# row renderer (`swAnyDonor` / `swCloneRow` / `swSeedToggle` / `swRenderPage` /
# `swReadBackPage`).
#
# THIS FILE IS THE MODS HALF ONLY. The branch it was extracted from carried the
# version-brand feature in the same file; this host already has that brand
# INLINE in `aowlhost.nim`, so copying the file whole would have shipped it
# twice. Only `modsTabBuild` / `modsTabTickBody` / `modsTabTick` / the guarded
# body and their helpers came across, plus the subtab layer below, which is new.
#
# WHY A CLONE AND NOT A NEW TAB
# -----------------------------
# The screen's tab machinery is CLOSED, measured rather than assumed:
# `EFT.UI.Settings.SettingsScreen` carries five hardcoded field pairs
# (`_gameButton`.._controlsButton` against `_gameSettingsScreen`..) plus a
# static `Dictionary<ESettingsGroup, SettingsGroupObjects> _tabs`. There is no
# list to append to and an IL2CPP type's layout is baked at build time. So the
# route proven on this build for everything else in the settings screen is
# taken: CLONE.
#
# WHAT IS NATIVE AND WHAT IS OURS
# -------------------------------
# Native, not simulated:
#   * The tab button is a clone of a real `*ToggleSpawner`, so it inherits the
#     real `ToggleGroup`: selecting a stock tab turns ours off and vice versa,
#     through the game's own group logic.
#   * The panel is a clone of a real tab panel parented to the SettingsScreen,
#     so it inherits background, padding and styling.
#   * The SUBTAB BAR is a clone of the tab bar itself (`SettingsScreen/Toggles`)
#     -- so the row of subtabs is literally the game's own tab strip, with the
#     game's own HorizontalLayoutGroup doing the spacing. NOTHING in this file
#     positions a rect by hand, because everything it places is parented through
#     `TMP_DefaultControls::SetParentAndAlign` into a stock layout group.
#   * Each subtab's PAGE is a clone of the stock row container, so its rows get
#     the stock VerticalLayoutGroup spacing, and the rows themselves are cloned
#     stock controls via `settingspages.nim`.
#
# Ours, and the only parts the game does not do for us:
#   1. Nothing tells the game to SHOW our panel when our toggle goes on -- it
#      switches panels by `ESettingsGroup` and ours is not one. So the panel's
#      active state is driven from the toggle: one guarded byte read per frame,
#      one `GameObject::SetActive` call ON AN EDGE ONLY.
#   2. The same for which subtab's page is visible.
#
# THE SUBTAB GROUP QUESTION, ANSWERED AT RUNTIME RATHER THAN GUESSED
# ------------------------------------------------------------------
# `Toggle.m_Group` is at +0x110 (`il2cpp_resolve.py fields UnityEngine.UI.
# Toggle`; `m_IsOn` at +0x120 from the same table). When the tab bar is cloned,
# Unity remaps references that point INSIDE the cloned hierarchy -- so IF the
# `ToggleGroup` component lives on the bar object itself, each cloned subtab's
# `m_Group` comes out pointing at the CLONED group and exclusive selection is
# native and free. If it lives elsewhere, the clones still point at the STOCK
# group, and clicking a subtab would turn the MODS tab itself off -- exactly the
# "it was a mess" failure.
#
# So this MEASURES it: compare a cloned subtab's `m_Group` against the stock
# toggle's. Same pointer -> the clone is wired to the stock group, so we NULL
# that field (on a clone WE made -- never on anything the game created) and run
# exclusivity ourselves with `Toggle::SetIsOnWithoutNotify`, on an edge only.
# Different pointer -> the remap happened, the group is ours, leave it alone.
# Either way the log says which, so the live behaviour is not a mystery.
#
# SAFETY
# ------
# Default OFF (`settingsModsTab`). Every hop `duOk`-guarded, every call to a
# byte-verified prologue, the build runs at most once, all iteration capped, no
# managed allocation on the per-frame path, and it self-disables after
# `ModsMaxFaults` trapped faults.
#
# It DOES arm an SEH guard of its own, and it must. An earlier version reasoned
# that the rider it runs from already has one -- that reasoning was wrong and it
# killed the client: the rider's guard wraps the inspector's own COMMANDS and
# has already returned by the time these ticks are called. ONE `aowl_p_p_seh`
# per entry and NEVER nested: the tick is dispatched through a single body, so
# only one branch runs per guarded call and neither re-enters.
#
# FACT #19 IS DESIGNED FOR, NOT HOPED AROUND: a caught fault unwinds the ENTIRE
# guarded body, so nothing after a faulting call runs. Every state variable this
# file writes is therefore assigned only AFTER the call that could fault has
# returned, so a trapped fault leaves the feature un-advanced rather than
# half-advanced, and the next frame retries the same step.
# ---------------------------------------------------------------------------

{.emit: """
extern void* aowl_mods_body(void* a);
static void* aowl_mods_guarded(void* a) {
    return aowl_p_p_seh((void*)aowl_mods_body, a);
}
""".}

proc cModsGuarded(a: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_mods_guarded", nodecl.}

## How many trapped faults this feature may spend before it turns itself off.
const ModsMaxFaults = 4

## `UnityEngine.UI.Toggle.m_IsOn` / `.m_Group` -- from the field table, never
## guessed: `il2cpp_resolve.py fields UnityEngine.UI.Toggle`.
const ModsOffIsOn = 0x120'i32
const ModsOffGroup = 0x110'i32

## At most this many subtabs. A cap, not an expectation: it bounds how many
## Unity objects a bad page table could instantiate into a live screen.
const ModsMaxSubtabs = 5

## How many times the lazy build may be attempted before it gives up quietly.
const ModsMaxBuildTries = 8

var gModsBuilt = false
var gModsTried = 0
var gModsFaults = 0

## The cloned tab button's toggle and the cloned panel.
var gModsToggle: Il2CppPtr = nil
var gModsPanel: Il2CppPtr = nil
## Last state pushed to the panel, so the per-frame path calls SetActive only on
## an actual edge rather than every frame.
var gModsShown = false
var gModsSaidShown = false

## The tab pointer the last ShowScreen postfix handed us, and its group name.
## Published by `settingsui.nim`; declared in `aowlhost.nim` because nimony
## forward-resolves procs across an `include` boundary but NOT variables.

type
  ModsSub = object
    ## One subtab: the cloned tab widget, its page container, and the page model
    ## rendered into it.
    name: string
    toggle: Il2CppPtr           ## the cloned AnimatedToggle
    pageGo: Il2CppPtr           ## the cloned row container this page lives in
    lastOn: bool                ## m_IsOn as of the previous frame

var gModsSubs: seq[ModsSub] = @[]
var gModsPages: seq[SwPage] = @[]
## Index of the subtab currently showing, or -1 when none has been chosen yet.
var gModsSel = -1
## True when the cloned subtabs share the STOCK ToggleGroup and we had to null
## their `m_Group`, which means exclusivity is ours to enforce.
var gModsOwnExclusive = false

proc modsNoteFault(what: string) =
  inc gModsFaults
  warn "mods tab: " & what & " (fault " & $gModsFaults & " of " &
       $ModsMaxFaults & ")"
  if gModsFaults >= ModsMaxFaults:
    gModsOn = false
    warn "mods tab: fault ceiling reached; the feature is OFF for this " &
         "session. The stock settings screen is untouched."

# ---------------------------------------------------------------------------
# Primitives. Every one is a guarded hop or a byte-verified direct call.
# ---------------------------------------------------------------------------

proc modsChildNamed(parent: Il2CppPtr; name: string): Il2CppPtr =
  ## The child transform whose name matches EXACTLY, or nil. It deliberately
  ## does not fall back to a partial match: "Toggles" and "ToggleShopButton"
  ## both contain "Toggle", and picking the wrong one would produce a plausible
  ## tab in the wrong place.
  result = nil
  if parent == nil:
    return
  var n = 0
  if not iChildCount(parent, n):
    return
  var i = 0
  while i < n and i < 64:
    let c = iChildAt(parent, i)
    if c != nil and duOk(c, 0x20'i32) and iObjName(c) == name:
      return c
    i = i + 1

proc modsClone(src: Il2CppPtr): Il2CppPtr =
  ## `Object::Instantiate(Object)` -- the reflection-free way to make a Unity
  ## object on this build. Returns the clone's GameObject, or nil.
  result = nil
  let fn = mi2Fn(Mi2Instantiate)
  if fn == nil or src == nil:
    return
  result = cMi2CallPS1(fn, src)

proc modsSetParent(child, parent: Il2CppPtr): bool =
  ## `TMP_DefaultControls::SetParentAndAlign`. THE ONLY PLACEMENT PRIMITIVE
  ## THIS FILE USES: it parents and aligns, and whatever stock layout group the
  ## parent carries does the spacing. Nothing here sets a rect by hand.
  let fn = mi2Fn(Mi2SetParentAlign)
  if fn == nil or child == nil or parent == nil:
    return false
  cMi2CallVS2(fn, child, parent)
  result = true

proc modsSetActive(go: Il2CppPtr; on: bool): bool =
  let fn = mi2Fn(Mi2GoSetActive)
  if fn == nil or go == nil or not duOk(go, 0x20'i32):
    return false
  cMi2CallVPB(fn, go, (if on: 1'i32 else: 0'i32))
  result = true

proc modsTransformOf(go: Il2CppPtr): Il2CppPtr =
  let fn = mi2Fn(Mi2GoGetTransform)
  if fn == nil or go == nil:
    return nil
  result = cMi2CallPP(fn, go)

proc modsParentOf(t: Il2CppPtr): Il2CppPtr =
  ## `Transform::get_parent`. Guarded like every other hop: an ICALL on a
  ## destroyed object faults inside Unity's C++ where no guard of ours reaches.
  result = nil
  var idx = 0
  var hits = 0
  if not iFindTarget("Transform::get_parent", idx, hits):
    return
  let fn = iTargetFn(idx)
  if fn == nil or t == nil or not iUnityAlive(t):
    return
  iMark("Transform::get_parent", t)
  let par = cast[Il2CppPtr](cInspUP(fn, t, nil))
  if par != nil and duOk(par, 0x20'i32):
    result = par

proc modsComponent(comp: Il2CppPtr; typeName: string): Il2CppPtr =
  ## PASS A COMPONENT (a Transform will do), NOT a GameObject.
  ##
  ## `GetComponent` is declared on `UnityEngine.Component`, and a GameObject is
  ## not one. Handing it a GameObject returns NULL every time -- no fault, no
  ## complaint, just nothing. That one mistake previously broke this feature and
  ## reported itself as two unrelated symptoms.
  result = nil
  if comp == nil or not duOk(comp, 0x20'i32):
    return
  var fn: Il2CppPtr = nil
  var rva = 0'u32
  if not iNavFind("GetComponent(String)", fn, rva):
    return
  if cNavIcallReady() == 0'i32:
    return
  var name = typeName
  let sp = cNavNewString(toCString(name))
  if sp == nil:
    return
  result = cast[Il2CppPtr](cInspUPP(fn, comp, sp, nil))

## The SettingsScreen transform, kept from the build so the per-frame path can
## switch the incumbent stock panel off and back on without walking again.
var gModsScreenT: Il2CppPtr = nil

## Which branch `aowl_mods_body` should run: 1 = the settings tab, 2 = the
## version brand. Both go through ONE guard entry, so only one branch runs per
## guarded call and neither re-enters -- `aowl_p_p_seh` is not re-entrant.
var gModsBranch = 0

# ---------------------------------------------------------------------------
# THE DONORS, AND WHY EACH ONE. Every one was chosen from a live hierarchy dump
# of the settings screen, not by a shape heuristic. The first version picked its
# layout container by "the busiest node", and what that selected was the Control
# Settings panel's own sub-tab strip; it then cloned that STRIP once per page
# and parented each copy back into the strip it came from. That recursion is
# what the player saw as "weird rectangles" and "dropdowns".
#
#   the tab button    SettingsScreen/Toggles/ControlsToggleSpawner
#       A stock tab-shaped button already in the tab bar and already in the
#       bar's ToggleGroup. Unchanged: measured working.
#
#   the panel         SettingsScreen/'Game Settings'   (WAS: Control Settings)
#       Control Settings is a KEYBIND TABLE -- a four-column header
#       (ACTION | KEY | KEY | PRESS TYPE) over bespoke row prefabs -- and
#       cloning it inherited that header, which is what the player saw over an
#       otherwise blank body. Game Settings is a plain vertical list of
#       labelled rows, which is the shape a mod settings page actually is, and
#       it is the panel `settingspages.nim` already clones its ROWS from, so
#       donor row and donor container cannot disagree about layout.
#
#   the subtab strip  'Control Settings'/Toggles
#       The game ALREADY HAS an in-panel subtab strip: Control Settings holds a
#       `Toggles` node containing `ControlToggle` and `GesturesToggle`. That is
#       exactly the widget being reproduced, so it is the widget cloned -- its
#       spacing, height and alignment are the game's own. Cloned ONCE.
#
#   the subtab button 'Control Settings'/Toggles/ControlToggle
#       ONE BUTTON, cloned once per page. The bug being fixed is precisely that
#       this used to be the strip.
#
# A donor need not come from the panel we cloned. It needs to be the right
# SHAPE, and these are the only stock widgets on this screen that are.
#
# WHAT IS ASSERTED BEFORE ANYTHING IS CLONED
# ------------------------------------------
# A wrong clone is SILENT: it renders, it just renders nonsense. So each donor
# passes a shape test or the build refuses and says which test failed:
#   * the subtab button donor must carry a Toggle-family component AND have a
#     reachable TextMeshProUGUI, or its clones would all read "ControlToggle";
#   * the page container must NOT look like a table (no child named
#     Header/Part/Table/Column) -- the exact fingerprint of the panel that was
#     cloned by mistake;
#   * the page container inside our clone is found BY NAME, matched against the
#     container `swRowContainerGo` walks to on the live tab: a proven walker,
#     not a heuristic.
# ---------------------------------------------------------------------------

## The stock panels this feature switched off in order to show its own, and
## which must be switched back on when it stops showing.
const ModsMaxHidden = 8
var gModsHidden: seq[Il2CppPtr] = @[]

proc modsNameHas(name, needle: string): bool =
  ## Substring test, written out rather than assuming a stdlib surface this
  ## nimony host may not have. Bounded by the strings' own lengths.
  result = false
  if needle.len == 0 or name.len < needle.len:
    return
  var i = 0
  while i <= name.len - needle.len:
    var j = 0
    var ok = true
    while j < needle.len:
      if name[i + j] != needle[j]:
        ok = false
        break
      j = j + 1
    if ok:
      return true
    i = i + 1

proc modsGoActive(go: Il2CppPtr): bool =
  ## `GameObject::get_activeSelf`, guarded like every other ICALL hop: a call on
  ## a destroyed object faults inside Unity's C++ where no guard of ours reaches.
  result = false
  var idx = 0
  var hits = 0
  if not iFindTarget("GameObject::get_activeSelf", idx, hits):
    return
  let fn = iTargetFn(idx)
  if fn == nil or go == nil or not iUnityAlive(go):
    return
  iMark("GameObject::get_activeSelf", go)
  result = (cInspUP(fn, go, nil) and 1'u64) != 0'u64

proc modsLooksLikeTable(t: Il2CppPtr; what: var string): bool =
  ## Does this container look like the keybind table rather than a row list?
  ## Capped, read-only, and it names what it saw, so a refusal is checkable.
  result = false
  what = ""
  if t == nil:
    return
  var n = 0
  if not iChildCount(t, n):
    return
  var i = 0
  while i < n and i < 32:
    let c = iChildAt(t, i)
    if c != nil and duOk(c, 0x20'i32):
      let nm = iObjName(c)
      if modsNameHas(nm, "Header") or modsNameHas(nm, "Part") or
         modsNameHas(nm, "Table") or modsNameHas(nm, "Column"):
        what = nm
        return true
    i = i + 1

proc modsToggleOf(t: Il2CppPtr): Il2CppPtr =
  ## The Toggle-family component for a button: on the node itself if it is a
  ## plain button, otherwise on its first child, which is the shape a
  ## `*ToggleSpawner` has. The concrete type is tried first and the base second,
  ## because Unity's GetComponent(String) matches base names too.
  result = nil
  if t == nil:
    return
  result = modsComponent(t, "AnimatedToggle")
  if result == nil:
    result = modsComponent(t, "Toggle")
  if result != nil:
    return
  var n = 0
  if not iChildCount(t, n) or n < 1:
    return
  let inner = iChildAt(t, 0)
  if inner == nil:
    return
  result = modsComponent(inner, "AnimatedToggle")
  if result == nil:
    result = modsComponent(inner, "Toggle")

proc modsFindTmp(t: Il2CppPtr; depth: int): Il2CppPtr =
  ## The first TextMeshProUGUI at or under `t`, to `depth` levels, capped at
  ## every level. A button whose caption cannot be reached is REFUSED as a donor
  ## rather than cloned and left showing someone else's word.
  result = nil
  if t == nil or depth < 0 or not duOk(t, 0x20'i32):
    return
  result = modsComponent(t, "TextMeshProUGUI")
  if result != nil or depth == 0:
    return
  var n = 0
  if not iChildCount(t, n):
    return
  var i = 0
  while i < n and i < 16:
    let c = iChildAt(t, i)
    if c != nil:
      result = modsFindTmp(c, depth - 1)
      if result != nil:
        return
    i = i + 1

proc modsRelabel(t: Il2CppPtr; text: string): bool =
  ## Relabel a button WE cloned, by CALLING the game's setters through
  ## `swRelabelControl`: a raw `m_text` store is put back by the LocalizedText
  ## the clone inherited from its donor.
  result = false
  let tmp = modsFindTmp(t, 3)
  if tmp == nil:
    return
  result = swRelabelControl(cast[Il2CppPtr](0), tmp, text)

proc modsToggleIsOn(toggle: Il2CppPtr): bool =
  result = false
  if toggle == nil or not duOk(toggle, ModsOffIsOn + 4'i32):
    return
  result = cSwReadU8(toggle, ModsOffIsOn) != 0'i32

proc modsSetToggleQuiet(toggle: Il2CppPtr; on: bool): bool =
  ## `Toggle::SetIsOnWithoutNotify` on a toggle WE cloned. Never `set_isOn`: a
  ## clone inherits the donor's `onValueChanged`, so the notifying setter would
  ## run the GAME's handler for the tab the donor came from.
  result = false
  if toggle == nil or not duOk(toggle, ModsOffIsOn + 4'i32):
    return
  let fn = swFn(SwToggleNoNotify)
  if fn == nil:
    return
  cSwCallVPB(fn, toggle, (if on: 1'i32 else: 0'i32))
  result = true

# ---------------------------------------------------------------------------
# The page table -- one page per subtab. Built ONCE at build time (never per
# frame) and read fresh from `aowlspt-host.json`. Every key here is a key this
# host really reads; a page advertising a flag nobody reads would be a lie
# rendered natively.
# ---------------------------------------------------------------------------

proc modsPage(id, title: string; rows: seq[SwRow]; note: string): SwPage =
  result = SwPage(id: id, title: title, rows: rows, stub: false, note: note,
                  renderedFor: 0'u64)

proc modsBuildPages(): seq[SwPage] =
  result = @[]
  var interfaceRows: seq[SwRow] = @[]
  interfaceRows.add swRow("debugUi", "F3 debug panel", readBoolKey("debugUi"), false)
  interfaceRows.add swRow("debugEsp", "In-world AI markers", readBoolKey("debugEsp"), false)
  interfaceRows.add swRow("uxVersionBrand", "Brand the version label", readBoolKey("uxVersionBrand"), false)
  interfaceRows.add swRow("uxMenuModeText", "Menu corner label", readBoolKey("uxMenuModeText"), false)
  interfaceRows.add swRow("osCloseFix", "OS window-close fix", readBoolKey("osCloseFix"), false)
  result.add modsPage("interface", "Interface", interfaceRows,
                      "Host switches that change what the menu shows.")

  var botRows: seq[SwRow] = @[]
  botRows.add swRow("unlimitedBots", "Lift the bot cap", readBoolKey("unlimitedBots"), false)
  botRows.add swRow("botDiag", "Bot registration logging", readBoolKey("botDiag"), false)
  botRows.add swRow("botNav", "Bot navigation API", readBoolKey("botNav"), false)
  botRows.add swRow("botAiActivate", "Bot AI activation rescue", readBoolKey("botAiActivate"), false)
  result.add modsPage("bots", "Bots", botRows,
                      "Offline raid population and AI.")

  var assetRows: seq[SwRow] = @[]
  assetRows.add swRow("imageCdnRedirect", "Serve images locally", readBoolKey("imageCdnRedirect"), false)
  result.add modsPage("assets", "Assets", assetRows,
                      "Where the client fetches its art from.")

  var devRows: seq[SwRow] = @[]
  devRows.add swRow("liveInspector", "Live inspector", readBoolKey("liveInspector"), false)
  devRows.add swRow("liveInspectorWrite", "Inspector may write", readBoolKey("liveInspectorWrite"), false)
  devRows.add swRow("settingsUiProbe", "Settings-screen probe", readBoolKey("settingsUiProbe"), false)
  devRows.add swRow("settingsPages", "Native mod settings pages", readBoolKey("settingsPages"), false)
  devRows.add swRow("codeGenAudit", "CodeGen audit", readBoolKey("codeGenAudit"), false)
  result.add modsPage("dev", "Diagnostics", devRows,
                      "Developer instruments. All read once at boot.")

# ---------------------------------------------------------------------------
# The build. Runs at most once, from the live SettingsScreen, and every step
# announces its own failure.
# ---------------------------------------------------------------------------

proc modsFindNamed(t: Il2CppPtr; name: string; depth: int): Il2CppPtr =
  ## The descendant called `name`, to `depth` levels, capped at each level.
  ## THIS IS HOW OUR PAGE CONTAINER IS FOUND: a clone keeps its donor's node
  ## names, so the container inside our panel is the one whose name matches the
  ## container `swRowContainerGo` walked to on the live tab.
  result = nil
  if t == nil or depth < 0 or not duOk(t, 0x20'i32):
    return
  if iObjName(t) == name:
    return t
  if depth == 0:
    return
  var n = 0
  if not iChildCount(t, n):
    return
  var i = 0
  while i < n and i < 32:
    let c = iChildAt(t, i)
    if c != nil:
      result = modsFindNamed(c, name, depth - 1)
      if result != nil:
        return
    i = i + 1

proc modsHideStockPanels(screenT, ourPanel: Il2CppPtr) =
  ## Switch off every ACTIVE stock panel beside ours, remembering exactly which,
  ## so leaving the tab can put them back.
  ##
  ## THIS IS THE HALF THAT WAS MISSING. Showing our panel is not switching to
  ## it: the incumbent stays active and draws over us. Measured live -- with
  ## MODS selected, `Game Settings` was still active=True alongside our clone,
  ## and hiding it by hand made ours appear.
  ##
  ## Chosen by NAME SUFFIX, not "every active sibling": the panels are named
  ## `<X> Settings`, and blanking every active sibling would take the tab bar
  ## and any backdrop with it. `(Clone)` can only be one of ours.
  gModsHidden = @[]
  if screenT == nil:
    return
  var n = 0
  if not iChildCount(screenT, n):
    return
  var i = 0
  while i < n and i < 32 and gModsHidden.len < ModsMaxHidden:
    let c = iChildAt(screenT, i)
    if c != nil and duOk(c, 0x20'i32):
      let go = iGameObjectOf(c)
      if go != nil and go != ourPanel:
        let nm = iObjName(c)
        if modsNameHas(nm, "Settings") and not modsNameHas(nm, "(Clone)"):
          if modsGoActive(go):
            if modsSetActive(go, false):
              gModsHidden.add go
    i = i + 1

proc modsRestoreStockPanels() =
  ## Put back exactly what `modsHideStockPanels` took away. Without this,
  ## leaving MODS for a stock tab can leave the screen blank: the game's own tab
  ## switch never knew we had switched a panel off.
  var i = 0
  while i < gModsHidden.len and i < ModsMaxHidden:
    discard modsSetActive(gModsHidden[i], true)
    i = i + 1
  gModsHidden = @[]

proc modsBuildSubtabs(stripT, buttonDonorGo: Il2CppPtr;
                      stockToggle: Il2CppPtr): int =
  ## Fill OUR cloned strip with one cloned BUTTON per page. The strip's own
  ## inherited buttons are switched off first, so what is left is exactly ours.
  result = 0
  if stripT == nil or buttonDonorGo == nil:
    return
  var inherited = 0
  if iChildCount(stripT, inherited):
    var h = 0
    while h < inherited and h < 32:
      let c = iChildAt(stripT, h)
      if c != nil and duOk(c, 0x20'i32):
        let go = iGameObjectOf(c)
        if go != nil:
          discard modsSetActive(go, false)
      h = h + 1
  var stockGroup: Il2CppPtr = nil
  if stockToggle != nil and duOk(stockToggle, ModsOffGroup + 8'i32):
    stockGroup = cReadPtrAt(stockToggle, ModsOffGroup)
  let stripGo = iGameObjectOf(stripT)
  if stripGo == nil:
    return
  var p = 0
  while p < gModsPages.len and p < ModsMaxSubtabs:
    let btn = modsClone(buttonDonorGo)
    if btn == nil:
      warn "mods tab: Instantiate returned null for the subtab button of '" &
           gModsPages[p].id & "'; that subtab is skipped"
      p = p + 1
      continue
    if not modsSetParent(btn, stripGo):
      warn "mods tab: could not parent the subtab button of '" &
           gModsPages[p].id & "' into the strip; it is skipped"
      p = p + 1
      continue
    let btnT = modsTransformOf(btn)
    let tog = modsToggleOf(btnT)
    if tog == nil:
      warn "mods tab: the cloned subtab button for '" & gModsPages[p].id &
           "' has no Toggle component, so it could never be read; skipped"
      discard modsSetActive(btn, false)
      p = p + 1
      continue
    if not modsRelabel(btnT, gModsPages[p].title):
      okLog "mods tab: subtab '" & gModsPages[p].id & "' kept its donor " &
            "caption (no reachable TMP on the clone); cosmetic only"
    # THE GROUP QUESTION, MEASURED RATHER THAN ASSUMED. On the live client this
    # came back NATIVE for the tab-button donor: Instantiate remapped each
    # clone's m_Group onto the cloned group. The stock-group branch stays
    # because the measurement is PER DONOR and this is a different donor.
    if duOk(tog, ModsOffGroup + 8'i32):
      let g = cReadPtrAt(tog, ModsOffGroup)
      if g != nil and g == stockGroup:
        gModsOwnExclusive = true
        discard cUxWritePtr(tog, ModsOffGroup, cast[Il2CppPtr](0))
    discard modsSetActive(btn, true)
    gModsSubs.add ModsSub(name: gModsPages[p].title, toggle: tog,
                          pageGo: nil, lastOn: false)
    result = result + 1
    p = p + 1
  if result > 0:
    okLog "mods tab: " & $result & " subtab BUTTON(s) cloned into a clone of " &
          "the game's own in-panel strip (donor 'Control Settings'/Toggles/" &
          "ControlToggle); the strip's " & $inherited & " inherited button(s) " &
          "are hidden. Exclusivity is " &
          (if gModsOwnExclusive:
             "OURS (the clones came out wired to the STOCK ToggleGroup, so " &
             "their m_Group was nulled on OUR clones only)"
           else:
             "NATIVE (Instantiate remapped each clone's m_Group onto the " &
             "cloned group, so the game's own group logic runs the strip)")

proc modsTabBuild(): bool =
  ## Build everything ONCE. Ordered so that a trapped fault -- which unwinds the
  ## whole guarded body, fact #19 -- leaves nothing recorded as built.
  result = false
  if gModsLastTabPtr == nil or not duOk(gModsLastTabPtr, 0x20'i32):
    return                              # settings not opened yet; not an error
  if gModsLastTabName != "game":
    return                              # wait for the tab whose rows we clone
  inc gModsTried
  let tabPtr = gModsLastTabPtr
  let tabT = iToTransform(tabPtr)
  let screenT = (if tabT != nil: modsParentOf(tabT) else: nil)
  if screenT == nil:
    modsNoteFault("could not reach the SettingsScreen transform from the tab")
    return
  let screenGo = iGameObjectOf(screenT)
  if screenGo == nil:
    modsNoteFault("the SettingsScreen transform has no reachable GameObject")
    return
  let toggles = modsChildNamed(screenT, "Toggles")
  if toggles == nil:
    modsNoteFault("no `Toggles` child under SettingsScreen -- the tab bar " &
                  "moved on this build; nothing was cloned")
    return
  let donorTab = modsChildNamed(toggles, "ControlsToggleSpawner")
  let donorPanel = modsChildNamed(screenT, "Game Settings")
  let ctrlPanel = modsChildNamed(screenT, "Control Settings")
  let donorStrip = (if ctrlPanel != nil: modsChildNamed(ctrlPanel, "Toggles")
                    else: nil)
  let donorButton = (if donorStrip != nil:
                       modsChildNamed(donorStrip, "ControlToggle") else: nil)
  if donorTab == nil or donorPanel == nil:
    modsNoteFault("the donor tab button or panel was not found (" &
                  (if donorTab == nil: "ControlsToggleSpawner " else: "") &
                  (if donorPanel == nil: "'Game Settings'" else: "") &
                  "); nothing was cloned")
    return
  if donorStrip == nil or donorButton == nil:
    modsNoteFault("the subtab donors were not found ('Control Settings'/" &
                  "Toggles" &
                  (if donorButton == nil: "/ControlToggle" else: "") &
                  "). REFUSING to substitute something else: cloning a " &
                  "container where a button belongs is exactly the bug this " &
                  "check exists for. Nothing was cloned.")
    return
  # ASSERT THE BUTTON DONOR'S SHAPE BEFORE CLONING IT.
  if modsToggleOf(donorButton) == nil:
    modsNoteFault("the subtab button donor 'ControlToggle' carries no " &
                  "Toggle-family component, so it is not a button; refusing " &
                  "to clone it")
    return
  if modsFindTmp(donorButton, 3) == nil:
    modsNoteFault("the subtab button donor 'ControlToggle' has no reachable " &
                  "TextMeshProUGUI, so its clones could never be relabelled " &
                  "and would all read 'ControlToggle'; refusing to clone it")
    return
  let donorTabGo = iGameObjectOf(donorTab)
  let donorPanelGo = iGameObjectOf(donorPanel)
  let donorStripGo = iGameObjectOf(donorStrip)
  let donorButtonGo = iGameObjectOf(donorButton)
  let togglesGo = iGameObjectOf(toggles)
  if donorTabGo == nil or donorPanelGo == nil or togglesGo == nil or
     donorStripGo == nil or donorButtonGo == nil:
    modsNoteFault("a donor's GameObject was not reachable; nothing was cloned")
    return
  # WHERE OUR ROWS GO, by name-match against a proven walker rather than by
  # shape: `swRowContainerGo` walks from a live control on the tab to the
  # container its rows are children of, and our panel is a clone of that panel.
  var containerWhy = ""
  let stockContainerGo = swRowContainerGo(tabPtr, containerWhy)
  if stockContainerGo == nil:
    modsNoteFault("could not reach the Game tab's row container (" &
                  containerWhy & "), so there is no name to look for inside " &
                  "our cloned panel; nothing was cloned")
    return
  let stockContainerT = modsTransformOf(stockContainerGo)
  let containerName = (if stockContainerT != nil: iObjName(stockContainerT)
                       else: "")
  if containerName.len == 0:
    modsNoteFault("the Game tab's row container has no readable name to " &
                  "match inside our clone; nothing was cloned")
    return

  # ---- the tab button ----
  let tabClone = modsClone(donorTabGo)
  if tabClone == nil:
    modsNoteFault("Instantiate returned null for the tab button")
    return
  if not modsSetParent(tabClone, togglesGo):
    modsNoteFault("could not parent the cloned tab button into the bar")
    return
  let tabCloneT = modsTransformOf(tabClone)
  if not modsRelabel(tabCloneT, "MODS"):
    okLog "mods tab: the cloned tab button kept its donor caption (no " &
          "reachable TMP label); cosmetic only"
  let mainToggle = modsToggleOf(tabCloneT)
  if mainToggle == nil:
    modsNoteFault("the cloned tab button has no Toggle component, so its " &
                  "selected state cannot be read; the panel would never show")
    return

  # ---- the panel ----
  let panel = modsClone(donorPanelGo)
  if panel == nil:
    modsNoteFault("Instantiate returned null for the panel")
    return
  if not modsSetParent(panel, screenGo):
    modsNoteFault("could not parent the cloned panel into the SettingsScreen")
    return
  discard modsSetActive(panel, false)   # never visible while half-built
  let panelT = modsTransformOf(panel)
  let stackT = modsFindNamed(panelT, containerName, 4)
  if stackT == nil:
    modsNoteFault("our cloned panel has no '" & containerName & "' inside it, " &
                  "though that is the container the live Game tab's rows sit " &
                  "in (" & containerWhy & "). The panel is left hidden and " &
                  "EMPTY rather than filled with something else.")
    return
  var tableWhat = ""
  if modsLooksLikeTable(stackT, tableWhat):
    modsNoteFault("the page container '" & containerName & "' contains '" &
                  tableWhat & "', the fingerprint of a TABLE (header + column " &
                  "parts) rather than a row list. Refusing to render into it " &
                  "-- this is the check that would have caught the keybind " &
                  "panel being cloned.")
    return
  let stackGo = iGameObjectOf(stackT)
  if stackGo == nil:
    modsNoteFault("the page container '" & containerName & "' has no " &
                  "reachable GameObject; the panel is left empty and hidden")
    return
  okLog "mods tab: pages go into '" & containerName & "' inside our cloned " &
        "'Game Settings' panel, name-matched against the container " &
        "swRowContainerGo walks to on the live tab (" & containerWhy &
        "). The stock layout group on it does all the spacing -- nothing in " &
        "this feature positions a rect."

  # ---- the donor panel's own rows, switched off BEFORE anything of ours is
  # added, so the hide cannot take our own clones with it (it did, once) ----
  var hidden = 0
  var stockN = 0
  if iChildCount(stackT, stockN):
    var h = 0
    while h < stockN and h < 64:
      let c = iChildAt(stackT, h)
      if c != nil and duOk(c, 0x20'i32):
        let go = iGameObjectOf(c)
        if go != nil and modsSetActive(go, false):
          hidden = hidden + 1
      h = h + 1
  okLog "mods tab: switched off " & $hidden & " inherited row(s) in our " &
        "cloned panel, so the MODS body starts EMPTY instead of showing a " &
        "second copy of Game Settings"

  # ---- the subtab strip: ONE clone of the game's own in-panel strip ----
  let stripClone = modsClone(donorStripGo)
  if stripClone == nil:
    modsNoteFault("Instantiate returned null for the subtab strip")
    return
  if not modsSetParent(stripClone, stackGo):
    modsNoteFault("could not parent the subtab strip into the panel")
    return
  let stripT = modsTransformOf(stripClone)
  gModsPages = modsBuildPages()
  gModsSubs = @[]
  let made = modsBuildSubtabs(stripT, donorButtonGo, modsToggleOf(donorTab))
  if made <= 0:
    modsNoteFault("the strip yielded no usable subtab button; the panel is " &
                  "left hidden and empty rather than half-built")
    return
  discard modsSetActive(stripClone, true)

  # ---- one page container per subtab: a clone of the SAME layout container,
  # so it inherits its vertical spacing, emptied of the rows it came with and
  # appended AFTER the strip, so the strip stays on top ----
  var s = 0
  while s < gModsSubs.len and s < ModsMaxSubtabs:
    let c = modsClone(stackGo)
    if c == nil:
      modsNoteFault("Instantiate returned null for the page container of '" &
                    gModsPages[s].id & "'")
      return
    if not modsSetParent(c, stackGo):
      modsNoteFault("could not parent the page container of '" &
                    gModsPages[s].id & "' into the panel's layout group")
      return
    let cT = modsTransformOf(c)
    # A clone of the container AS IT IS NOW: its stock rows are already
    # inactive and the strip is not in it, so there is nothing of ours to hide.
    # This pass is belt-and-braces, and capped.
    var cn = 0
    if iChildCount(cT, cn):
      var k = 0
      while k < cn and k < 64:
        let cc = iChildAt(cT, k)
        if cc != nil and duOk(cc, 0x20'i32):
          let ccgo = iGameObjectOf(cc)
          if ccgo != nil:
            discard modsSetActive(ccgo, false)
        k = k + 1
    gModsSubs[s].pageGo = c
    discard modsSetActive(c, s == 0)
    s = s + 1

  # ---- the rows, by the SAME renderer the Game-tab pages already use ----
  swLearnTabKlasses(tabPtr)
  var r = 0
  while r < gModsSubs.len and r < gModsPages.len:
    if gModsSubs[r].pageGo != nil:
      discard swRenderPage(tabPtr, gModsSubs[r].pageGo, gModsPages[r])
    r = r + 1

  gModsSel = 0
  if gModsSubs.len > 0:
    discard modsSetToggleQuiet(gModsSubs[0].toggle, true)
    gModsSubs[0].lastOn = true

  # Everything succeeded. Only NOW is any of it recorded, so a trapped fault
  # above leaves the feature un-built and retrying rather than half-built.
  gModsScreenT = screenT
  gModsToggle = mainToggle
  gModsPanel = panel
  gModsShown = false
  gModsBuilt = true
  okLog "mods tab: built -- a sixth tab button cloned into SettingsScreen/" &
        "Toggles (labelled MODS, sharing the stock ToggleGroup so selection " &
        "is the game's own), a panel cloned from 'Game Settings' beside the " &
        "stock five, a subtab strip cloned from the game's own in-panel strip " &
        "holding " & $gModsSubs.len & " cloned BUTTON(s), and one page of " &
        "cloned rows behind each. Selecting MODS switches the incumbent stock " &
        "panel OFF; leaving MODS switches it back ON."
  result = true

# ---------------------------------------------------------------------------
# The per-frame tick. Cheap by construction: when the screen is not open this is
# one null check; when it is, it is a handful of guarded byte reads and a call
# ONLY on an edge. No managed allocation on this path.
# ---------------------------------------------------------------------------

proc modsShowSubtab(sel: int) =
  ## Make `sel` the visible page. Calls only where something changes.
  var i = 0
  while i < gModsSubs.len:
    let want = (i == sel)
    if gModsSubs[i].pageGo != nil:
      discard modsSetActive(gModsSubs[i].pageGo, want)
    if gModsOwnExclusive and gModsSubs[i].toggle != nil:
      if modsToggleIsOn(gModsSubs[i].toggle) != want:
        discard modsSetToggleQuiet(gModsSubs[i].toggle, want)
    gModsSubs[i].lastOn = want
    i = i + 1
  gModsSel = sel

proc modsTickSubtabs() =
  ## Which subtab did the player just turn ON? Read every subtab's `m_IsOn` and
  ## act only on a RISING edge -- correct whether the clones ended up on their
  ## own ToggleGroup (measured: they did, for the tab-button donor, so the group
  ## turns the others off for us) or on none at all (we do it ourselves).
  var rising = -1
  var i = 0
  while i < gModsSubs.len:
    let on = modsToggleIsOn(gModsSubs[i].toggle)
    if on and not gModsSubs[i].lastOn:
      rising = i
    gModsSubs[i].lastOn = on
    i = i + 1
  if rising >= 0 and rising != gModsSel:
    modsShowSubtab(rising)

proc modsTabTickBody() =
  if not gModsOn or gModsFaults >= ModsMaxFaults:
    return
  if not gModsBuilt:
    # Build lazily, once the settings screen has been opened onto the tab whose
    # rows we clone. GATE ON THE SAME POINTER THE BUILD USES: a guard naming a
    # different thing from the code it guards is a silent feature-off switch,
    # and that is how this once shipped doing nothing at all.
    if gModsLastTabPtr != nil and gModsTried < ModsMaxBuildTries:
      discard modsTabBuild()
    return
  if gModsToggle == nil or gModsPanel == nil:
    return
  if not duOk(gModsToggle, ModsOffIsOn + 4'i32):
    return                              # screen torn down; nothing to drive
  let isOn = cSwReadU8(gModsToggle, ModsOffIsOn) != 0'i32
  if isOn != gModsShown:
    # BOTH EDGES. Showing our panel is not switching to it: the stock panel the
    # game had up stays active and draws over ours unless it is switched off,
    # and it must be switched back on when we go away, or the screen is blank.
    if isOn:
      modsHideStockPanels(gModsScreenT, gModsPanel)
      if not modsSetActive(gModsPanel, true):
        modsRestoreStockPanels()        # never leave the screen with nothing up
        return
      gModsShown = true
      if not gModsSaidShown:
        gModsSaidShown = true
        okLog "mods tab: the MODS panel is showing; " & $gModsHidden.len &
              " stock panel(s) were switched off for it and are switched back " &
              "on when MODS is deselected"
    else:
      discard modsSetActive(gModsPanel, false)
      modsRestoreStockPanels()
      gModsShown = false
      # THE PERSIST POINT, on the HIDE edge and nowhere else: reading back and
      # rewriting `aowlspt-host.json` allocates and touches the disk, which has
      # no business on a per-frame path.
      var q = 0
      while q < gModsPages.len:
        swReadBackPage(gModsPages[q])
        q = q + 1
    return                              # one edge's worth of work per frame
  if not gModsShown:
    return
  modsTickSubtabs()

# ---------------------------------------------------------------------------
# THE VERSION BRAND, ported from `merge-host-v3` where it worked, and the
# reason it lives in THIS file: it stands on the same walkers and the same
# label setter as the tab, and it rides the same detour.
#
# WHY THIS AND NOT THE PROBE ALREADY IN `aowlhost.nim`. Measured, not argued:
#   * The old path aims at `PreloaderUI + cUxVersionLabelOffset()`. Fact #13 --
#     that object's `m_text` is EMPTY. It is not the label on screen, which is
#     why `uxVersionBrand` has never visibly worked.
#   * The label on screen is fact #12:
#         <PreloaderUI>/BottomPanel/Content/UpperPart/AlphaLabel
#     whose TextMeshProUGUI reads e.g. "1.1.0.1.46777 | PvE".
#   * The old path also wrote with a RAW STORE into `m_text`, which appears to
#     work and is then re-applied over by `LocalizedText`. This goes through
#     `swRelabelControl` -- SetLabelText @0x140FE70 then set_text @0x51BC1E0
#     plus the repaint latch -- the same route the settings rows use.
#   * The old path fired ONCE, from an Awake postfix, before the label had any
#     text. This POLLS and re-applies, with a cap so a label that fights back
#     cannot spin forever.
#
# ONLY ONE WRITER. The old probe is left in place, flag-gated and READ-ONLY:
# `aowlhost.nim` forces `gVersionWrite` off whenever this brand is armed, and
# says so, so the two can never both write to a version label.
#
# THE ASSERTION, and it is the difference between this working and looking like
# it works: the resolved label's text must be NON-EMPTY before anything is
# written to it. A label that reads empty is the wrong object -- that is
# literally fact #13 -- so this refuses and says so rather than branding it.
#
# The composed text is built from what the game ACTUALLY wrote, not hardcoded:
# the stock label is "<tarkov version> | <mode>" and both halves are carried
# through, so a game update or a different mode stays correct on its own.
# ---------------------------------------------------------------------------

## What the label calls US. Deliberately not read from ./VERSION: that file says
## 0.1.0 and describes the release BUNDLE, while this is the string a player
## reads on the menu.
const VerBrandOurVersion = "1.0"
const VerBrandMaxApplies = 8
const VerBrandEveryFrames = 120
const VerBrandMaxWalkFaults = 40

var gVerTmp: Il2CppPtr = nil
var gVerApplies = 0
var gVerFrames = 0
var gVerSaid = false
## Faults during the WALK are counted separately from successful applies. They
## are not the same event and must not share a budget: an earlier version spent
## all eight APPLY attempts on walk faults between 20s and 29s -- before the
## menu existed at all -- and had nothing left for the moment the label finally
## appeared. A feature that gives up before its target exists has not failed; it
## was asked too early.
var gVerWalkFaults = 0
var gVerStock = ""
## WHY the last walk gave up, so a silent nil becomes a sentence. Without this
## the feature could fail forever saying nothing: resolve returning nil is not a
## fault, so no guard reports it and the tick just quietly does nothing.
var gVerWhy = ""
## One-shot: the empty-label refusal explains itself once, not every poll.
var gVerSaidEmpty = false

proc verTrim(s: string): string =
  ## Leading/trailing ASCII blanks removed. Written out rather than reaching for
  ## a stdlib `strip`, because this host targets nimony and assuming Nim 2's
  ## stdlib surface is exactly the mistake the repo rules warn about.
  var a = 0
  var b = s.len - 1
  while a <= b and (s[a] == ' ' or s[a] == '\t'):
    a = a + 1
  while b >= a and (s[b] == ' ' or s[b] == '\t'):
    b = b - 1
  result = ""
  var i = a
  while i <= b:
    result.add s[i]
    i = i + 1

proc verBrandCompose(stock: string): string =
  ## "aowlspt <ver>, aoughwl.com  -  tarkov <tarkov ver> | <mode>", built from
  ## whatever the game actually wrote.
  var tarkov = ""
  var mode = ""
  var seen = false
  var i = 0
  while i < stock.len:
    if stock[i] == '|' and not seen:
      seen = true
    elif seen:
      mode.add stock[i]
    else:
      tarkov.add stock[i]
    i = i + 1
  result = "aowlspt " & VerBrandOurVersion & ", aoughwl.com  -  tarkov " &
           verTrim(tarkov)
  let m = verTrim(mode)
  if m.len > 0:
    result = result & " | " & m

proc verBrandResolve(): Il2CppPtr =
  ## Walk the fixed path to the label from the live PreloaderUI anchor. Each hop
  ## is checked BY NAME, so a build that moved the label declines loudly instead
  ## of writing into whatever happens to sit at that index.
  result = nil
  if gInspPreloader == nil or not duOk(gInspPreloader, 0x20'i32):
    gVerWhy = "no live PreloaderUI anchor yet"
    return
  let t = iToTransform(gInspPreloader)
  if t == nil:
    gVerWhy = "PreloaderUI has no reachable Transform"
    return
  # LOOK DOWN, NOT UP. Measured: `Component::get_transform` on the PreloaderUI
  # gives the SCENE ROOT named "Preloader UI", whose single child is ANOTHER
  # node also named "Preloader UI", and BottomPanel hangs off that one. So the
  # panel is two levels below the component, not beside it and not above it.
  var bottom = modsChildNamed(t, "BottomPanel")
  if bottom == nil:
    var n = 0
    if iChildCount(t, n):
      var i = 0
      while i < n and i < 16 and bottom == nil:
        let c = iChildAt(t, i)
        if c != nil and duOk(c, 0x20'i32):
          bottom = modsChildNamed(c, "BottomPanel")
        i = i + 1
  if bottom == nil:
    gVerWhy = "no 'BottomPanel' under the PreloaderUI or its children"
    return
  let content = modsChildNamed(bottom, "Content")
  if content == nil:
    gVerWhy = "no 'Content' under BottomPanel"
    return
  let upper = modsChildNamed(content, "UpperPart")
  if upper == nil:
    gVerWhy = "no 'UpperPart' under Content"
    return
  let alpha = modsChildNamed(upper, "AlphaLabel")
  if alpha == nil:
    gVerWhy = "no 'AlphaLabel' under UpperPart"
    return
  # LIVENESS BEFORE THE ICALL. `Component::get_gameObject` dereferences
  # m_CachedPtr at +0x10 and, when that is zero, faults INSIDE Unity's C++
  # where no guard of ours reaches. Measured on an AlphaLabel that EXISTS in
  # the hierarchy but whose native half is not up yet: Unity's 'fake null'.
  if not iUnityAlive(alpha):
    gVerWhy = "AlphaLabel exists but its native half is null (not live yet)"
    return
  gVerWhy = "AlphaLabel has no TextMeshProUGUI"
  result = modsComponent(alpha, "TextMeshProUGUI")
  if result != nil:
    gVerWhy = ""

proc verBrandTickBody() =
  ## The guarded half. NO THROTTLE HERE -- the entry point owns it. When this
  ## was split into entry + body the frame counter was once left in BOTH and the
  ## two cancelled exactly: armed, guarded, never faulting, never changing the
  ## label. A throttle belongs on ONE side of a split, and it belongs on the
  ## side that decides whether to enter the guard.
  if gVerTmp == nil or not duOk(gVerTmp, 0xE8'i32):
    gVerTmp = verBrandResolve()
    if gVerTmp == nil:
      inc gVerWalkFaults
      if gVerWalkFaults <= 2:
        okLog "version brand: the label is not reachable yet -- " & gVerWhy &
              ". Retrying; this is normal before the menu is up."
      elif gVerWalkFaults == VerBrandMaxWalkFaults:
        warn "version brand: GIVING UP after " & $gVerWalkFaults &
             " attempts -- " & gVerWhy & ". The label is stock."
      return
  let cur = suiReadString(cReadPtrAt(gVerTmp, 0xE0'i32))
  if cur.len == 0:
    # THE ASSERTION. An empty label is the FINGERPRINT OF THE WRONG OBJECT --
    # fact #13, and precisely why the old path looked armed and changed
    # nothing. Refuse, say so once, and drop the pointer so the next poll
    # re-walks rather than writing into it.
    if not gVerSaidEmpty:
      gVerSaidEmpty = true
      warn "version brand: REFUSING to write -- the TextMeshProUGUI this walk " &
           "reached has an EMPTY m_text, which is the fingerprint of the " &
           "WRONG object (fact #13: that is exactly what the old " &
           "uxVersionBrand target reads, and why it never visibly worked). " &
           "The real label reads '<tarkov version> | <mode>'. Nothing was " &
           "written; the walk is retried."
    gVerTmp = nil
    return
  if cur.startsWith("aowlspt"):
    return                              # already ours
  if gVerStock.len == 0:
    gVerStock = cur
  let want = verBrandCompose(gVerStock)
  if swRelabelControl(cast[Il2CppPtr](0), gVerTmp, want):
    inc gVerApplies
    if not gVerSaid:
      gVerSaid = true
      okLog "version brand: the bottom label now reads \"" & want &
            "\" -- written through LocalizedText::SetLabelText / " &
            "TMP_Text::set_text on AlphaLabel (fact #12), NOT the $verlabel " &
            "anchor, whose m_text is empty and which is why this never showed"

# ---------------------------------------------------------------------------
# HIDE THE MAIN-MENU SEASONS BANNER (`uxHideSeasons`, default OFF).
#
# `Common UI/MenuScreen/SeasonsButton` is the "KORD BREACH / Season 1" banner
# above the Play button. Seasons do not apply to single-player.
#
# THIS IS THE ONE PATH IN THIS FILE THAT TOUCHES AN OBJECT THE GAME CREATED, so
# it is deliberately the most conservative:
#   * it only ever sets active=FALSE, and never re-enables anything -- if it did
#     not disable it, it does not touch it;
#   * it re-resolves the button BY NAME every pass rather than trusting a cached
#     pointer across a screen rebuild, and re-walks to MenuScreen the moment
#     that cached transform stops validating;
#   * it checks `activeSelf` first, so the steady state is a guarded read and NO
#     call at all;
#   * it is throttled, capped and self-disabling.
#
# FOUND STRUCTURALLY, NOT BY TEXT. Searching KORD / SEASON / BREACH across
# Common UI, Menu UI and Preloader UI returned zero hits on COMPLETE walks: the
# banner is image-driven and carries no matching label. So the route is the
# hierarchy -- MenuScreen under Common UI, child named SeasonsButton -- and if
# that name is not there this logs and does nothing. There is no positional
# fallback, because hiding "whatever sits there" is how you blank the Play
# button on the next patch.
# ---------------------------------------------------------------------------

const SeasonsEveryFrames = 120
const SeasonsMaxFaults = 4

var gSeasonsMenu: Il2CppPtr = nil       ## the MenuScreen transform, revalidated
var gSeasonsFrames = 0
var gSeasonsHidden = 0
var gSeasonsSaid = false
var gSeasonsSaidMissing = false
var gSeasonsFaults = 0

proc seasonsFindMenuScreen(): Il2CppPtr =
  ## `MenuScreen`, from the scene roots. This is the only expensive step, and it
  ## is why the result is cached and revalidated rather than re-walked: the root
  ## enumeration allocates, and nothing that allocates may run per frame.
  result = nil
  var roots: seq[Il2CppPtr] = @[]
  discard iSceneRoots(roots, false)
  var i = 0
  while i < roots.len and i < 32:
    let goT = iToTransform(roots[i])
    if goT != nil and duOk(goT, 0x20'i32):
      let m = modsChildNamed(goT, "MenuScreen")
      if m != nil:
        return m
    i = i + 1

proc seasonsTickBody() =
  if not gSeasonsOn or gSeasonsFaults >= SeasonsMaxFaults:
    return
  # Revalidate the cached MenuScreen before trusting it; a menu rebuild
  # destroys it and a stale Transform is a fault waiting for the next ICALL.
  if gSeasonsMenu != nil and
     (not duOk(gSeasonsMenu, 0x20'i32) or not iUnityAlive(gSeasonsMenu)):
    gSeasonsMenu = nil
  if gSeasonsMenu == nil:
    gSeasonsMenu = seasonsFindMenuScreen()
    if gSeasonsMenu == nil:
      return                            # menu not up; normal, and cheap
  # BY NAME, EVERY PASS. The button is re-resolved rather than cached, so a
  # rebuilt banner is hidden again and a destroyed one is simply not found.
  let btn = modsChildNamed(gSeasonsMenu, "SeasonsButton")
  if btn == nil:
    if not gSeasonsSaidMissing:
      gSeasonsSaidMissing = true
      okLog "hide seasons: MenuScreen has no child named 'SeasonsButton' on " &
            "this build. NOTHING was hidden -- there is deliberately no " &
            "positional fallback, because hiding whatever happens to sit " &
            "there is how the Play button disappears after a patch."
    return
  let go = iGameObjectOf(btn)
  if go == nil or not iUnityAlive(go):
    return
  if not modsGoActive(go):
    return                              # already hidden: a read, and no call
  if modsSetActive(go, false):
    inc gSeasonsHidden
    if not gSeasonsSaid:
      gSeasonsSaid = true
      okLog "hide seasons: Common UI/MenuScreen/SeasonsButton switched off " &
            "(the KORD BREACH / Season banner above Play). It is re-checked " &
            "on a throttle, so a menu rebuild hides it again; it is never " &
            "re-enabled by this host."

# ---------------------------------------------------------------------------
# ONE GUARDED ENTRY, THREE BRANCHES. `aowl_p_p_seh` is NOT re-entrant, so all
# three features are dispatched through a single body selected by a global:
# only one branch runs per guarded call and none of them nests a second guard.
# ---------------------------------------------------------------------------

proc modsBody(a: Il2CppPtr): Il2CppPtr {.exportc: "aowl_mods_body", cdecl.} =
  ## Returns non-nil so the caller can tell "ran" from "faulted" --
  ## `aowl_p_p_seh` gives back NULL when it caught something.
  discard a
  result = cast[Il2CppPtr](1)
  if gModsBranch == 1:
    modsTabTickBody()
  elif gModsBranch == 2:
    verBrandTickBody()
  elif gModsBranch == 3:
    seasonsTickBody()

proc modsTabTick() =
  ## The rider's entry, called every frame from the shared
  ## `EFT.UI.PreloaderUI::Update` detour. When the feature is off this does not
  ## enter the guard at all.
  if not gModsOn or gModsFaults >= ModsMaxFaults:
    return
  gModsBranch = 1
  if cModsGuarded(cast[Il2CppPtr](0)) == nil:
    modsNoteFault("the mods-tab tick FAULTED and was caught; the game " &
                  "survived. Nothing is left half-built: the panel and the " &
                  "subtabs are only recorded once every clone exists")

proc verBrandTick() =
  ## Throttled entry for the version brand. The throttle lives HERE and nowhere
  ## else -- see `verBrandTickBody`.
  if not gVerOn or gVerApplies >= VerBrandMaxApplies or
     gVerWalkFaults >= VerBrandMaxWalkFaults:
    return
  inc gVerFrames
  if gVerFrames < VerBrandEveryFrames:
    return
  gVerFrames = 0
  gModsBranch = 2
  if cModsGuarded(cast[Il2CppPtr](0)) == nil:
    inc gVerWalkFaults
    # NAME THE HOP. A caught fault with no location is precisely what costs
    # cycles here, and the breadcrumb is already being written for us.
    if gVerWalkFaults <= 3:
      warn "version brand: the label walk FAULTED and was caught; the game " &
           "survived. LAST HOP: " & readCString(cInspCrumb()) & "  at " &
           iPtr(cInspCrumbPtr()) & ". Expected before the menu exists; it " &
           "retries (" & $gVerWalkFaults & " of " & $VerBrandMaxWalkFaults & ")"

proc seasonsTick() =
  ## Throttled entry for the seasons-banner hider, on the same terms.
  if not gSeasonsOn or gSeasonsFaults >= SeasonsMaxFaults:
    return
  inc gSeasonsFrames
  if gSeasonsFrames < SeasonsEveryFrames:
    return
  gSeasonsFrames = 0
  gModsBranch = 3
  if cModsGuarded(cast[Il2CppPtr](0)) == nil:
    inc gSeasonsFaults
    warn "hide seasons: the MenuScreen walk FAULTED and was caught; the game " &
         "survived. LAST HOP: " & readCString(cInspCrumb()) & "  at " &
         iPtr(cInspCrumbPtr()) & " (fault " & $gSeasonsFaults & " of " &
         $SeasonsMaxFaults & "). Nothing was hidden on this pass."
    if gSeasonsFaults >= SeasonsMaxFaults:
      gSeasonsOn = false
      warn "hide seasons: fault ceiling reached; the feature is OFF for this " &
           "session and the banner is left exactly as the game made it."

proc modsRidersTick() =
  ## Everything in this file that wants a frame, behind ONE call the rider
  ## chain in `aowlhost.nim` makes. Each entry re-arms the guard separately --
  ## never nested -- and each is a cheap flag test when its feature is off.
  modsTabTick()
  verBrandTick()
  seasonsTick()

proc bindModsTab(verbose: bool): bool =
  ## A RIDER on `EFT.UI.PreloaderUI::Update`, never a second detour on it: two
  ## detours on one function have the second overwrite the first's trampoline
  ## and silently kill the first feature. So this only ever ALIASES onto a slot
  ## another feature already claimed, and if nobody has claimed one it says so
  ## and binds nothing.
  result = false
  if gModsSlot >= 0:
    return true
  if not (gModsOn or gVerOn or gSeasonsOn):
    return false
  if gDebugUiSlot >= 0:
    gModsSlot = gDebugUiSlot
  elif gModeTextSlot >= 0:
    gModsSlot = gModeTextSlot
  elif gInspSlot >= 0:
    gModsSlot = gInspSlot
  else:
    if verbose:
      warn "mods tab / version brand / hide seasons: nothing holds a detour " &
           "on EFT.UI.PreloaderUI::Update, so there is no per-frame firing to " &
           "ride and NONE of them will tick. They refuse to add a second " &
           "detour to that function. Turn on debugUi, uxMenuModeText or " &
           "liveInspector -- any one of which claims that slot -- and they " &
           "will run from the same single detour."
    return false
  okLog "mods tab / version brand / hide seasons armed as RIDERS on the " &
        "existing EFT.UI.PreloaderUI::Update detour (slot " & $gModsSlot &
        ") -- one detour, one trampoline. The tab is built the first time " &
        "Settings -> Game is opened, because the rows it clones come from " &
        "that tab."
  result = true
