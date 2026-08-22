# modstab.nim -- A SIXTH TAB IN TARKOV'S OWN SETTINGS SCREEN.
#
# `include`d into `aowlhost.nim` LAST, after `inspect.nim`, because it stands on
# that file's Transform walkers (`iChildAt`, `iChildCount`, `iObjName`,
# `iToTransform`, `iGameObjectOf`) which reach the nav table, and on
# `invoke2.nim`'s verified call targets and `settingswrite.nim`'s label setter.
#
# WHY A CLONE AND NOT A NEW TAB
# -----------------------------
# The screen's tab machinery is CLOSED, and this was measured rather than
# assumed. `EFT.UI.Settings.SettingsScreen` carries five hardcoded field pairs
# -- `_gameButton`.._controlsButton` (UIAnimatedToggleSpawner) against
# `_gameSettingsScreen`.._controlsSettingsTabScreen` -- plus a STATIC
# `Dictionary<ESettingsGroup, SettingsGroupObjects> _tabs`. There is no list to
# append to, and you cannot add a field: an IL2CPP type's layout is baked at
# build time.
#
# Registering a sixth entry in `_tabs` is not obviously impossible -- an enum is
# just an int32 at runtime (`ESettingsGroup.value__` is an `int` at +0x10) and
# nothing validates the range -- but it needs `Dictionary<K,V>::Add` for that
# instantiation, whose code the offline resolver cannot currently locate. So it
# is left as the eventual upgrade, and this takes the route that is proven on
# this build for everything else in the settings screen: CLONE.
#
# WHAT IS ACTUALLY NATIVE HERE, AND WHAT IS OURS
# ----------------------------------------------
# Native, and not simulated:
#   * The tab button is a clone of a real `*ToggleSpawner`, so it inherits the
#     real `ToggleGroup`. Selecting any stock tab turns ours OFF and selecting
#     ours turns the stock one off, through the game's own group logic. This
#     was verified live before a line of this file was written.
#   * The panel is a clone of a real tab panel, parented to the SettingsScreen
#     beside the stock five, so it inherits layout, background and styling.
#
# Ours, and the only part the game does not do for us: nothing tells the game
# to SHOW our panel when our toggle goes on, because the game switches panels
# by `ESettingsGroup` and ours is not one. So this polls the toggle's `m_IsOn`
# and drives `GameObject::SetActive` on the panel to match. That is one byte
# read and, on a change only, one call -- per frame, while the settings screen
# is open. It is not a hack around a missing feature; it IS the feature, and it
# is the same shape as the clone-and-retarget the rows already use.
#
# SAFETY
# ------
# Default OFF (`settingsModsTab`). Every hop `duOk`-guarded, every call to a
# byte-verified prologue, the build runs at most once and self-disables after
# `ModsMaxFaults`.
#
# It DOES arm an SEH guard of its own, and it must. An earlier version of this
# comment said it did not, on the reasoning that it runs inside the rider which
# already has one -- that reasoning was wrong and it killed the client. The
# rider's guard wraps the inspector's own COMMANDS and has already returned by
# the time these ticks are called, so without a guard here they run naked on
# Unity's main thread. See the note above `aowl_mods_guarded`.

# ---------------------------------------------------------------------------
# THE GUARD. Everything below runs on Unity's main thread and touches live
# managed objects, so it needs one -- and the first version of this file did
# NOT have one, which killed the client outright.
#
# The mistake is worth stating exactly, because the surrounding code made it
# easy: the inspector guards each COMMAND, and these ticks are called from the
# rider AFTER that guard has returned. So they ran naked on the Unity thread,
# an ICALL on a not-yet-live object faulted inside Unity's C++, and the process
# died with the log stopping mid-line. Nothing caught it because nothing was
# watching.
#
# ONE `aowl_p_p_seh` per entry and NEVER nested, exactly as everywhere else in
# this host: both ticks are dispatched through a single body selected by a
# global, so only one branch runs per guarded call and neither re-enters.
# ---------------------------------------------------------------------------
{.emit: """
extern void* aowl_mods_body(void* a);
static void* aowl_mods_guarded(void* a) {
    return aowl_p_p_seh((void*)aowl_mods_body, a);
}
""".}
proc cModsGuarded(a: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_mods_guarded", nodecl.}

## Which branch `aowl_mods_body` should run: 1 = the sixth tab, 2 = the version
## brand. A global rather than an argument because the guard passes exactly one
## pointer and that is the object, not the selector.
var gModsBranch = 0

const ModsMaxFaults = 4

## `settingsModsTab` -- default OFF, like every other feature here.
var gModsOn = false
var gModsBuilt = false
var gModsTried = 0
var gModsFaults = 0
## The AnimatedToggle component on our cloned tab button, and our cloned panel's
## GameObject. Both nil until the build succeeds.
var gModsToggle: Il2CppPtr = nil
var gModsPanel: Il2CppPtr = nil
## Last state pushed to the panel, so the per-frame path calls SetActive only on
## an actual edge rather than every frame.
var gModsShown = false
var gModsSaidShown = false

## `UnityEngine.UI.Toggle.m_IsOn` -- from the field table for AnimatedToggle,
## which IS a Toggle (its chain is Selectable -> Toggle -> AnimatedToggle).
## Never guessed: `il2cpp_resolve.py fields AnimatedToggle`.
const ModsOffIsOn = 0x120'i32

proc modsNoteFault(what: string) =
  inc gModsFaults
  warn "mods tab: " & what & " (fault " & $gModsFaults & " of " &
       $ModsMaxFaults & ")"
  if gModsFaults >= ModsMaxFaults:
    gModsOn = false
    warn "mods tab: fault ceiling reached; the feature is OFF for this " &
         "session. The stock settings screen is untouched."

proc modsChildNamed(parent: Il2CppPtr; name: string): Il2CppPtr =
  ## The child transform whose name matches exactly, or nil. Capped, guarded,
  ## and it does NOT fall back to a partial match -- "Toggles" and
  ## "ToggleShopButton" both contain "Toggle", and picking the wrong one would
  ## produce a plausible tab in the wrong place.
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

proc modsGameObjectOf(comp: Il2CppPtr): Il2CppPtr =
  let fn = mi2Fn(Mi2GetGameObject)
  if fn == nil or comp == nil:
    return nil
  result = cMi2CallPP(fn, comp)

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

proc modsComponent(go: Il2CppPtr; typeName: string): Il2CppPtr =
  ## `Component::GetComponent(System.String)` -- the reflection-free way from a
  ## GameObject to a component on this build. Unity matches by SHORT type name
  ## and, measured, by BASE type names too, which is why "AnimatedToggle"
  ## resolves the concrete toggle and "MonoBehaviour" resolves anything.
  ##
  ## The icall is checked first: the wrapper's failure branch RAISES a
  ## missing-method exception, and a managed throw from inside a detour is not
  ## something to discover empirically.
  result = nil
  if go == nil or not duOk(go, 0x20'i32):
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
  result = cast[Il2CppPtr](cInspUPP(fn, go, sp, nil))

proc modsLabelTab(toggleRoot: Il2CppPtr; text: string) =
  ## Relabel the cloned tab button. The label lives at
  ## <spawner>/<Toggle>/SizeLabel/Label and is a TextMeshProUGUI, so this goes
  ## through the same `swRelabelControl` route the settings rows use -- a raw
  ## `m_text` store is re-applied over by LocalizedText.
  if toggleRoot == nil:
    return
  var n = 0
  if not iChildCount(toggleRoot, n) or n < 1:
    return
  let toggle = iChildAt(toggleRoot, 0)          # the <X>Toggle child
  if toggle == nil:
    return
  let sizeLabel = modsChildNamed(toggle, "SizeLabel")
  if sizeLabel == nil:
    return
  let label = modsChildNamed(sizeLabel, "Label")
  if label == nil:
    return
  let go = iGameObjectOf(label)
  if go == nil:
    return
  let tmp = modsComponent(go, "TextMeshProUGUI")
  if tmp == nil:
    okLog "mods tab: the cloned tab's Label has no TextMeshProUGUI; it keeps " &
          "the donor's caption (cosmetic only)"
    return
  discard swRelabelControl(cast[Il2CppPtr](0), tmp, text)

proc modsTabBuild(): bool =
  ## Build the tab ONCE, from the live SettingsScreen. Every step announces its
  ## own failure: a feature that declines silently is the worst thing this host
  ## produces.
  result = false
  # FROM THE LIVE TAB, NOT FROM `gMi2Self`.
  #
  # The first version keyed off `gMi2Self`, the SettingsScreen `this` -- and it
  # never built anything, silently, because that pointer is set by invoke2's own
  # STEP probe which is not armed in this configuration. The ShowScreen postfix
  # that IS armed hands `settingspages.nim` a live SettingsTab instead, and that
  # is published as `gSwLastTabPtr`. A tab's PARENT is the SettingsScreen, so
  # the hierarchy this needs is one hop up from something we are always given.
  if gSwLastTabPtr == nil or not duOk(gSwLastTabPtr, 0x20'i32):
    return                              # settings not opened yet; not an error
  inc gModsTried
  let tabT = iToTransform(gSwLastTabPtr)
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
  modsLabelTab(tabCloneT, "MODS")
  # The toggle itself, for the per-frame read. It is the spawner's only child.
  if tabCloneT != nil:
    let inner = iChildAt(tabCloneT, 0)
    if inner != nil:
      let innerGo = iGameObjectOf(inner)
      if innerGo != nil:
        gModsToggle = modsComponent(innerGo, "AnimatedToggle")
  if gModsToggle == nil:
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
  gModsPanel = panel
  # Start hidden. The clone inherits the donor's active state, and the donor is
  # whatever tab happened to be up -- so without this the panel can appear over
  # a stock tab the moment it is created, which is exactly the "always visible"
  # symptom this feature is built to avoid.
  discard modsSetActive(gModsPanel, false)
  gModsShown = false
  gModsBuilt = true
  okLog "mods tab: built -- a sixth tab button cloned into SettingsScreen/" &
        "Toggles (labelled MODS, sharing the stock ToggleGroup so selection " &
        "is the game's own) and a panel cloned beside the stock five. Its " &
        "visibility follows the toggle from here."
  result = true

proc modsTabTickBody() =
  ## Per-frame, on Unity's thread, inside the rider's existing guard.
  ##
  ## Cheap by construction: when the settings screen is not open this is one
  ## null check. When it is, it is one guarded byte read, and a call ONLY on an
  ## edge.
  if not gModsOn or gModsFaults >= ModsMaxFaults:
    return
  if not gModsBuilt:
    # Build lazily, and only while the settings screen is actually live. Capped
    # so a build that cannot succeed does not retry every frame forever.
    if gMi2Self != nil and gModsTried < 8:
      discard modsTabBuild()
    return
  if gModsToggle == nil or gModsPanel == nil:
    return
  if not duOk(gModsToggle, ModsOffIsOn + 4'i32):
    return                              # screen torn down; nothing to drive
  let isOn = cSwReadU8(gModsToggle, ModsOffIsOn) != 0'i32
  if isOn == gModsShown:
    return                              # no edge, no call
  if modsSetActive(gModsPanel, isOn):
    gModsShown = isOn
    if isOn and not gModsSaidShown:
      gModsSaidShown = true
      okLog "mods tab: the MODS panel is showing; selection is driven by the " &
            "stock ToggleGroup and the panel follows it"

# ---------------------------------------------------------------------------
# THE VERSION BRAND, done properly this time.
#
# `uxVersionBrand` has never visibly worked, and the reason is measured, not
# guessed: it aims at `PreloaderUI + cUxVersionLabelOffset()`, and the object
# there has an EMPTY `m_text`. It is not the label on screen. The label on
# screen is
#
#     <PreloaderUI>/BottomPanel/Content/UpperPart/AlphaLabel
#
# whose TextMeshProUGUI reads e.g. "1.1.0.1.46777 | PvE".
#
# Two further things the old path got wrong and this does not:
#   * It wrote with a RAW STORE into `m_text`. That appears to work and is then
#     re-applied over by `LocalizedText`. This goes through `swRelabelControl`
#     -- SetLabelText then set_text plus the repaint latch -- the same route the
#     settings rows use.
#   * It fired ONCE, from an Awake postfix, before the label had text at all.
#     This polls: it re-checks periodically and re-applies if the game has
#     rewritten it, with a cap so a label that fights back cannot spin forever.
#
# The composed text is built from what the game ACTUALLY wrote, not hardcoded:
# the stock label is "<tarkov version> | <mode>", and both halves are carried
# through, so a game update or a different mode stays correct on its own.
# ---------------------------------------------------------------------------

## What the label calls US. Deliberately not read from ./VERSION: that file
## says 0.1.0 and describes the release BUNDLE, while this is the string a
## player reads on the menu.
const VerBrandOurVersion = "1.0"
const VerBrandMaxApplies = 8
const VerBrandEveryFrames = 120

var gVerOn = false
var gVerTmp: Il2CppPtr = nil
var gVerApplies = 0
var gVerFrames = 0
var gVerSaid = false
## Faults during the WALK are counted separately from successful applies.
## They are not the same event and must not share a budget: the first
## version spent all eight APPLY attempts on walk faults between 20s and
## 29s -- before the menu existed at all -- and then had nothing left for
## the moment the label finally appeared. A feature that gives up before
## its target exists has not failed; it was asked too early.
var gVerWalkFaults = 0
const VerBrandMaxWalkFaults = 40
var gVerStock = ""

proc verTrim(s: string): string =
  ## Leading/trailing ASCII spaces removed. Written out rather than reaching for
  ## a stdlib `strip`, because this host targets nimony and assuming Nim 2's
  ## stdlib surface is exactly the mistake CLAUDE.md warns about.
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
  ## whatever the game actually wrote. The stock label is
  ## "<tarkov version> | <mode>"; both halves are carried through, so a game
  ## update or a different mode stays correct without anyone editing this.
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

## WHY the last walk gave up, so a silent nil becomes a sentence. Without
## this the feature could fail forever saying nothing at all: resolve
## returning nil is not a fault, so no guard reports it, and the tick just
## quietly does nothing every frame.
var gVerWhy = ""

proc verBrandResolve(): Il2CppPtr =
  ## Walk the fixed path to the label, from the PreloaderUI the rider gives us.
  ## Each hop is checked by NAME, so a build that moved the label declines
  ## loudly instead of writing into whatever happens to sit at that index.
  result = nil
  if gInspPreloader == nil or not duOk(gInspPreloader, 0x20'i32):
    gVerWhy = "no live PreloaderUI anchor yet"
    return
  var t = iToTransform(gInspPreloader)
  if t == nil:
    gVerWhy = "PreloaderUI has no reachable Transform"
    return
  # LOOK DOWN, NOT UP. Measured, because the first version guessed and found
  # nothing: `Component::get_transform` on the PreloaderUI gives the SCENE ROOT
  # named "Preloader UI", whose single child is ANOTHER node also named
  # "Preloader UI", and BottomPanel hangs off that one. So the panel is two
  # levels below the component, not beside it and not above it.
  #
  # Searching the root's children as well as the root itself costs one extra
  # level and makes this survive the layer being added or removed, which is
  # exactly the kind of shuffle a game patch does.
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
  # LIVENESS BEFORE THE ICALL. `Component::get_gameObject` is an IL2CPP
  # internal-call wrapper: it dereferences m_CachedPtr at +0x10 and, when
  # that is zero, faults INSIDE Unity's C++ where no guard of ours reaches.
  # Measured -- the breadcrumb named this exact hop, at 18s, on an
  # AlphaLabel that EXISTS in the hierarchy but whose native half is not up
  # yet. Unity's 'fake null': a perfectly good managed wrapper over nothing.
  if not iUnityAlive(alpha):
    gVerWhy = "AlphaLabel exists but its native half is null (not live yet)"
    return
  let go = iGameObjectOf(alpha)
  if go == nil:
    gVerWhy = "AlphaLabel has no reachable GameObject"
    return
  gVerWhy = "AlphaLabel has no TextMeshProUGUI"
  result = modsComponent(go, "TextMeshProUGUI")
  if result != nil:
    gVerWhy = ""

proc verBrandTickBody() =
  ## The guarded half. NO THROTTLE HERE -- the entry point owns it.
  ##
  ## When this was split into entry + body the frame counter was left in
  ## BOTH, and the two cancelled each other exactly: the entry counted to
  ## 120 and reset to 0, then this incremented to 1 and returned because
  ## 1 < 120. Every frame. The feature was armed, the guard was entered,
  ## nothing faulted, and the label never changed -- a silent no-op with no
  ## failure path to notice, which is the exact shape this codebase keeps
  ## paying for. A throttle belongs on ONE side of a split, and the side
  ## that decides whether to enter the guard is the cheap one.
  if gVerTmp == nil or not duOk(gVerTmp, 0xE8'i32):
    gVerTmp = verBrandResolve()
    if gVerTmp == nil:
      inc gVerWalkFaults
      if gVerWalkFaults <= 2:
        okLog "version brand: the label is not reachable yet -- " &
              gVerWhy & ". Retrying; this is normal before the menu is up."
      elif gVerWalkFaults == VerBrandMaxWalkFaults:
        warn "version brand: GIVING UP after " & $gVerWalkFaults &
             " attempts -- " & gVerWhy & ". The label is stock."
      return                            # menu not up yet; try again later
  let cur = suiReadString(cReadPtrAt(gVerTmp, 0xE0'i32))
  if cur.len == 0:
    return                              # not populated yet
  if cur.startsWith("aowlspt"):
    return                              # already ours
  if gVerStock.len == 0:
    gVerStock = cur
  let want = verBrandCompose(gVerStock)
  if swRelabelControl(cast[Il2CppPtr](0), gVerTmp, want):
    inc gVerApplies
    if not gVerSaid:
      gVerSaid = true
      okLog "version brand: the bottom-left label now reads \"" & want &
            "\" -- written through LocalizedText::SetLabelText / " &
            "TMP_Text::set_text on AlphaLabel, NOT the $verlabel anchor, " &
            "whose m_text is empty and which is why this never showed before"


proc modsBody(a: Il2CppPtr): Il2CppPtr {.exportc: "aowl_mods_body", cdecl.} =
  ## The one guarded body. Returns non-nil so the caller can tell "ran" from
  ## "faulted" -- `aowl_p_p_seh` gives back NULL when it caught something.
  result = cast[Il2CppPtr](1)
  if gModsBranch == 1:
    modsTabTickBody()
  elif gModsBranch == 2:
    verBrandTickBody()

proc modsTabTick() =
  ## The rider's entry. Cheap enough to call every frame: when the feature is
  ## off or already settled this does not enter the guard at all.
  if not gModsOn or gModsFaults >= ModsMaxFaults:
    return
  gModsBranch = 1
  if cModsGuarded(cast[Il2CppPtr](0)) == nil:
    modsNoteFault("the sixth-tab tick FAULTED and was caught; the game " &
                  "survived. Nothing was left half-built: the panel is only " &
                  "recorded once both clones exist")

proc verBrandTick() =
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
