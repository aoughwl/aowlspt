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

proc modsToggleOfSpawner(spawnerT: Il2CppPtr): Il2CppPtr =
  ## The `AnimatedToggle` inside a `*ToggleSpawner` clone: the spawner's first
  ## child carries it. Returns nil rather than guessing.
  result = nil
  if spawnerT == nil:
    return
  var n = 0
  if not iChildCount(spawnerT, n) or n < 1:
    return
  let inner = iChildAt(spawnerT, 0)
  if inner == nil:
    return
  result = modsComponent(inner, "AnimatedToggle")

proc modsLabelSpawner(spawnerT: Il2CppPtr; text: string): bool =
  ## Relabel a cloned tab/subtab button. The label lives at
  ## <spawner>/<Toggle>/SizeLabel/Label and is a TextMeshProUGUI, so this goes
  ## through `swRelabelControl` -- a raw `m_text` store is re-applied over by
  ## LocalizedText, which the clone inherits from its donor.
  result = false
  if spawnerT == nil:
    return
  var n = 0
  if not iChildCount(spawnerT, n) or n < 1:
    return
  let toggle = iChildAt(spawnerT, 0)
  if toggle == nil:
    return
  let sizeLabel = modsChildNamed(toggle, "SizeLabel")
  if sizeLabel == nil:
    return
  let label = modsChildNamed(sizeLabel, "Label")
  if label == nil:
    return
  let tmp = modsComponent(label, "TextMeshProUGUI")
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
# The page table -- one page per subtab.
#
# Built ONCE at build time (never per frame) and read fresh from
# `aowlspt-host.json`, so it shows what the file says rather than what the host
# latched at boot. Every key here is a key this host really reads; a page that
# advertised a flag nobody reads would be a lie rendered natively.
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
# announces its own failure: a feature that declines silently is the worst
# thing this host produces.
# ---------------------------------------------------------------------------

proc modsStackParent(panelT: Il2CppPtr; why: var string): Il2CppPtr =
  ## The transform inside our cloned panel that a NEW BLOCK should be parented
  ## under -- i.e. the one the donor panel's own rows are children of, which is
  ## the one carrying the vertical layout group.
  ##
  ## Chosen by SHAPE, not by a guessed name: among the panel's descendants down
  ## to depth 3, the transform with the most children. A settings panel's row
  ## list is by a wide margin the busiest node in it. The name that won is
  ## LOGGED, so the choice is checkable against the live screen instead of being
  ## an article of faith.
  result = nil
  why = "no readable descendant"
  if panelT == nil:
    return
  var bestN = 1
  var lvl0 = panelT
  var n0 = 0
  if not iChildCount(lvl0, n0):
    return
  var i = 0
  while i < n0 and i < 32:
    let c1 = iChildAt(lvl0, i)
    if c1 != nil and duOk(c1, 0x20'i32):
      var n1 = 0
      if iChildCount(c1, n1):
        if n1 > bestN:
          bestN = n1
          result = c1
          why = "'" & iObjName(c1) & "' with " & $n1 & " children (depth 1)"
        var j = 0
        while j < n1 and j < 32:
          let c2 = iChildAt(c1, j)
          if c2 != nil and duOk(c2, 0x20'i32):
            var n2 = 0
            if iChildCount(c2, n2) and n2 > bestN:
              bestN = n2
              result = c2
              why = "'" & iObjName(c2) & "' with " & $n2 & " children (depth 2)"
          j = j + 1
    i = i + 1
  if result == nil:
    why = "the cloned panel has no descendant with more than one child, so " &
          "there is no stock layout group to hang the pages on"

proc modsHideChildren(t: Il2CppPtr; keepFrom: int): int =
  ## Deactivate the inherited children of a clone WE made, from index
  ## `keepFrom` on. Capped. Returns how many were hidden.
  ##
  ## This is what stops the MODS panel from showing the donor tab's own rows --
  ## the single biggest reason the previous attempt "looked a mess".
  result = 0
  if t == nil:
    return
  var n = 0
  if not iChildCount(t, n):
    return
  var i = keepFrom
  while i < n and i < 64:
    let c = iChildAt(t, i)
    if c != nil and duOk(c, 0x20'i32):
      let go = iGameObjectOf(c)
      if go != nil and modsSetActive(go, false):
        result = result + 1
    i = i + 1

proc modsBuildSubtabs(barT, stackGo: Il2CppPtr; stockToggle: Il2CppPtr): int =
  ## Turn the cloned tab strip into OUR subtab strip: relabel the first N of its
  ## cloned buttons, hide the rest, and record each one's toggle. Returns how
  ## many subtabs came out usable.
  result = 0
  var n = 0
  if barT == nil or not iChildCount(barT, n) or n < 1:
    return
  var stockGroup: Il2CppPtr = nil
  if stockToggle != nil and duOk(stockToggle, ModsOffGroup + 8'i32):
    stockGroup = cReadPtrAt(stockToggle, ModsOffGroup)
  var i = 0
  while i < n and i < 16 and result < gModsPages.len and
        result < ModsMaxSubtabs:
    let child = iChildAt(barT, i)
    if child == nil or not duOk(child, 0x20'i32):
      i = i + 1
      continue
    let tog = modsToggleOfSpawner(child)
    if tog == nil:
      i = i + 1
      continue
    let title = gModsPages[result].title
    if not modsLabelSpawner(child, title):
      okLog "mods tab: subtab " & $result & " kept its donor caption (no " &
            "reachable TMP label on the clone); cosmetic only"
    # THE GROUP QUESTION, MEASURED. See the header.
    if duOk(tog, ModsOffGroup + 8'i32):
      let g = cReadPtrAt(tog, ModsOffGroup)
      if g != nil and g == stockGroup:
        gModsOwnExclusive = true
        discard cUxWritePtr(tog, ModsOffGroup, cast[Il2CppPtr](0))
    gModsSubs.add ModsSub(name: title, toggle: tog, pageGo: nil, lastOn: false)
    result = result + 1
    i = i + 1
  # Anything past the subtabs we kept is a leftover stock tab button: hide it,
  # or the strip reads as "Interface Bots Assets Diagnostics Sound Controls".
  discard modsHideChildren(barT, result)
  if result > 0:
    okLog "mods tab: " & $result & " subtab button(s) built from a clone of " &
          "the stock tab strip; exclusivity is " &
          (if gModsOwnExclusive:
             "OURS (the clones came out wired to the STOCK ToggleGroup, so " &
             "their m_Group was nulled on OUR clones only -- otherwise " &
             "clicking a subtab would have deselected the MODS tab itself)"
           else:
             "NATIVE (Instantiate remapped each clone's m_Group onto the " &
             "cloned group, so the game's own group logic runs the strip)")
  discard stackGo

proc modsTabBuild(): bool =
  ## Build everything ONCE. Ordered so that a trapped fault (which unwinds the
  ## whole body -- fact #19) leaves nothing recorded as built.
  result = false
  # FROM THE LIVE TAB, NOT FROM A `this` NOBODY SETS. The ShowScreen postfix in
  # `settingsui.nim` publishes the live SettingsTab; a tab's PARENT chain gets
  # to the SettingsScreen. The donor ROWS also come from that tab, and only the
  # Game tab has controls we know how to clone, so the build waits for it.
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
  let donorPanel = modsChildNamed(screenT, "Control Settings")
  if donorTab == nil or donorPanel == nil:
    modsNoteFault("the donor tab button or panel was not found (" &
                  (if donorTab == nil: "ControlsToggleSpawner " else: "") &
                  (if donorPanel == nil: "'Control Settings'" else: "") &
                  "); nothing was cloned")
    return
  let donorTabGo = iGameObjectOf(donorTab)
  let donorPanelGo = iGameObjectOf(donorPanel)
  let togglesGo = iGameObjectOf(toggles)
  if donorTabGo == nil or donorPanelGo == nil or togglesGo == nil:
    modsNoteFault("a donor's GameObject was not reachable; nothing was cloned")
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
  if not modsLabelSpawner(tabCloneT, "MODS"):
    okLog "mods tab: the cloned tab button kept its donor caption (no " &
          "reachable TMP label); cosmetic only"
  let mainToggle = modsToggleOfSpawner(tabCloneT)
  if mainToggle == nil:
    modsNoteFault("the cloned tab button has no AnimatedToggle, so its " &
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
  let panelT = modsTransformOf(panel)
  var stackWhy = ""
  let stackT = modsStackParent(panelT, stackWhy)
  if stackT == nil:
    discard modsSetActive(panel, false)
    modsNoteFault("the cloned panel gave nothing to hang the pages on (" &
                  stackWhy & "); the panel exists but is left EMPTY and " &
                  "hidden rather than showing the donor tab's own rows")
    return
  let stackGo = iGameObjectOf(stackT)
  if stackGo == nil:
    discard modsSetActive(panel, false)
    modsNoteFault("the chosen layout container (" & stackWhy & ") has no " &
                  "reachable GameObject; the panel is left empty and hidden")
    return
  okLog "mods tab: pages will be laid out by the stock layout group on " &
        stackWhy & " -- nothing in this feature positions a rect by hand"

  # ---- one page container per subtab, cloned from that same layout container
  # so each inherits its spacing, then emptied of the donor's rows ----
  gModsPages = modsBuildPages()
  var containers: seq[Il2CppPtr] = @[]
  var p = 0
  while p < gModsPages.len and p < ModsMaxSubtabs:
    let c = modsClone(stackGo)
    if c == nil:
      modsNoteFault("Instantiate returned null for the page container of '" &
                    gModsPages[p].id & "'")
      discard modsSetActive(panel, false)
      return
    if not modsSetParent(c, stackGo):
      modsNoteFault("could not parent the page container of '" &
                    gModsPages[p].id & "' into the panel's layout group")
      discard modsSetActive(panel, false)
      return
    let cT = modsTransformOf(c)
    discard modsHideChildren(cT, 0)     # drop the donor rows it came with
    discard modsSetActive(c, false)     # every page starts hidden
    containers.add c
    p = p + 1

  # ---- the subtab strip, cloned from the stock tab strip, added BEFORE the
  # pages so sibling order puts it at the top of the vertical layout ----
  let barClone = modsClone(togglesGo)
  if barClone == nil:
    modsNoteFault("Instantiate returned null for the subtab strip")
    discard modsSetActive(panel, false)
    return
  if not modsSetParent(barClone, stackGo):
    modsNoteFault("could not parent the subtab strip into the panel")
    discard modsSetActive(panel, false)
    return
  let barT = modsTransformOf(barClone)
  let stockToggle = modsToggleOfSpawner(donorTab)
  gModsSubs = @[]
  let made = modsBuildSubtabs(barT, stackGo, stockToggle)
  if made <= 0:
    modsNoteFault("the cloned tab strip yielded no usable subtab button; the " &
                  "panel is left hidden and empty rather than half-built")
    discard modsSetActive(panel, false)
    return
  # The strip is a sibling of the pages, so it must sit ABOVE them: it was
  # parented first, and everything below is appended after it.
  discard modsSetActive(barClone, true)

  # ---- the rows, by the SAME renderer the Game-tab pages already use ----
  swLearnTabKlasses(tabPtr)
  var s = 0
  while s < gModsSubs.len and s < containers.len:
    gModsSubs[s].pageGo = containers[s]
    discard swRenderPage(tabPtr, containers[s], gModsPages[s])
    s = s + 1

  # The donor panel's own rows, hidden last: the stack container is shared with
  # them, and hiding them earlier would have hidden the clones we took from it.
  discard modsHideChildren(stackT, 0)
  # ...which also hid the strip and the pages, because they are children of the
  # same container. Put OURS back on: they are clones we made.
  discard modsSetActive(barClone, true)
  var k = 0
  while k < containers.len:
    discard modsSetActive(containers[k], (k == 0))
    k = k + 1
  gModsSel = 0
  if gModsSubs.len > 0:
    discard modsSetToggleQuiet(gModsSubs[0].toggle, true)
    gModsSubs[0].lastOn = true

  # Everything succeeded. Only NOW is any of it recorded, so a trapped fault
  # above leaves the feature un-built and retrying rather than half-built.
  gModsToggle = mainToggle
  gModsPanel = panel
  discard modsSetActive(panel, false)
  gModsShown = false
  gModsBuilt = true
  okLog "mods tab: built -- a sixth tab button cloned into SettingsScreen/" &
        "Toggles (labelled MODS, sharing the stock ToggleGroup so selection " &
        "is the game's own), a panel cloned beside the stock five, a subtab " &
        "strip cloned from the stock tab strip with " & $gModsSubs.len &
        " subtab(s), and one cloned-row page behind each. Visibility follows " &
        "the toggles from here."
  result = true

# ---------------------------------------------------------------------------
# The per-frame tick. Cheap by construction: when the screen is not open this
# is one null check; when it is, it is a handful of guarded byte reads and a
# call ONLY on an edge. No managed allocation on this path.
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
  ## Which subtab did the player just turn ON? Read every subtab's `m_IsOn`, and
  ## act only on a RISING edge -- that is what makes this work whether the
  ## clones ended up on their own ToggleGroup (the group turns the others off
  ## for us) or on none at all (we turn them off ourselves).
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
    # Build lazily, and only once the settings screen has been opened onto the
    # tab whose rows we clone. GATE ON THE SAME POINTER THE BUILD USES: a guard
    # that names a different thing from the code it guards is a silent
    # feature-off switch, and that is exactly how this once shipped doing
    # nothing at all.
    if gModsLastTabPtr != nil and gModsTried < ModsMaxBuildTries:
      discard modsTabBuild()
    return
  if gModsToggle == nil or gModsPanel == nil:
    return
  if not duOk(gModsToggle, ModsOffIsOn + 4'i32):
    return                              # screen torn down; nothing to drive
  let isOn = cSwReadU8(gModsToggle, ModsOffIsOn) != 0'i32
  if isOn != gModsShown:
    if not modsSetActive(gModsPanel, isOn):
      return
    gModsShown = isOn
    if isOn and not gModsSaidShown:
      gModsSaidShown = true
      okLog "mods tab: the MODS panel is showing; selection is driven by the " &
            "stock ToggleGroup and the panel follows it"
    if not isOn:
      # THE PERSIST POINT, on the HIDE edge and nowhere else. Reading back and
      # writing `aowlspt-host.json` allocates and touches the disk, which has no
      # business on a per-frame path -- so it happens once, when the player
      # leaves the tab.
      var q = 0
      while q < gModsPages.len:
        swReadBackPage(gModsPages[q])
        q = q + 1
    return                              # one edge's worth of work per frame
  if not gModsShown:
    return
  modsTickSubtabs()

proc modsBody(a: Il2CppPtr): Il2CppPtr {.exportc: "aowl_mods_body", cdecl.} =
  ## The one guarded body. Returns non-nil so the caller can tell "ran" from
  ## "faulted" -- `aowl_p_p_seh` gives back NULL when it caught something.
  result = cast[Il2CppPtr](1)
  discard a
  modsTabTickBody()

proc modsTabTick() =
  ## The rider's entry, called every frame from the shared
  ## `EFT.UI.PreloaderUI::Update` detour. When the feature is off this does not
  ## enter the guard at all.
  if not gModsOn or gModsFaults >= ModsMaxFaults:
    return
  if cModsGuarded(cast[Il2CppPtr](0)) == nil:
    modsNoteFault("the mods-tab tick FAULTED and was caught; the game " &
                  "survived. Nothing is left half-built: the panel and the " &
                  "subtabs are only recorded once every clone exists")

proc bindModsTab(verbose: bool): bool =
  ## A RIDER on `EFT.UI.PreloaderUI::Update`, never a second detour on it: two
  ## detours on one function have the second overwrite the first's trampoline
  ## and silently kill the first feature. So this only ever ALIASES onto a slot
  ## another feature already claimed, and if nobody has claimed one it says so
  ## and binds nothing.
  result = false
  if gModsSlot >= 0:
    return true
  if not gModsOn:
    return false
  if gDebugUiSlot >= 0:
    gModsSlot = gDebugUiSlot
  elif gModeTextSlot >= 0:
    gModsSlot = gModeTextSlot
  elif gInspSlot >= 0:
    gModsSlot = gInspSlot
  else:
    if verbose:
      warn "mods tab: nothing holds a detour on EFT.UI.PreloaderUI::Update, " &
           "so there is no per-frame firing to ride and this feature will NOT " &
           "tick. It refuses to add a second detour to that function. Turn on " &
           "debugUi, uxMenuModeText or liveInspector, any one of which claims " &
           "that slot, and the MODS tab will run from the same single detour."
    return false
  okLog "mods tab armed as a RIDER on the existing EFT.UI.PreloaderUI::" &
        "Update detour (slot " & $gModsSlot & ") -- one detour, one " &
        "trampoline. The tab is built the first time Settings -> Game is " &
        "opened, because the rows it clones come from that tab."
  result = true
