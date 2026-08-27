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

## `UnityEngine.UI.Selectable.m_Interactable` / `.m_TargetGraphic`, and
## `UnityEngine.UI.Graphic.m_RaycastTarget` -- from the field table
## (`il2cpp_resolve.py fields UnityEngine.UI.Selectable` /
## `...Graphic`), never guessed. A click that never reaches `m_IsOn` can be
## the group question OR a Toggle that cannot receive the click at all; these
## three fields are what answer the second question instead of assuming it.
const ModsOffInteractable = 0xd8'i32
const ModsOffTargetGraphic = 0xe0'i32
const GfxOffRaycastTarget = 0x3a'i32

## `UnityEngine.UI.LayoutElement` -- from the field table
## (`il2cpp_resolve.py fields UnityEngine.UI.LayoutElement`), never guessed.
## Unity's sentinel for "not set" on any of these is a negative value (-1);
## anything >= 0 actively constrains a `LayoutGroup`'s sizing pass.
const ModsOffLeMinHeight = 0x28'i32
const ModsOffLePreferredHeight = 0x30'i32
const ModsOffLeFlexibleHeight = 0x38'i32

## At most this many subtabs. A cap, not an expectation: it bounds how many
## Unity objects a bad page table could instantiate into a live screen. Raised
## from 5 to fit the built-in host pages (4) plus one subtab per fetched mod
## page (`modsBuildPages` appends those from `gSwPages`) with room to spare.
const ModsMaxSubtabs = 8

## How many times the lazy build may be attempted before it gives up quietly.
const ModsMaxBuildTries = 8

## How many TextMeshProUGUI one relabel may consider. A cap, not an
## expectation.
const ModsMaxTmp = 8

## Every label this feature has successfully written, so it can be re-asserted
## if LocalizedText puts the donor's string back. Bounded by ModsMaxSubtabs + 1
## (the tab button), and written only at build time.
var gModsLabelTmp: seq[Il2CppPtr] = @[]
var gModsLabelText: seq[string] = @[]
## The cap on that list: up to three TMPs per caption on this build, times the
## tab button plus ModsMaxSubtabs.
const ModsMaxLabels = 24

## Every cloned button, its donor and its caption, so the extra toggle a live
## spawner spawns AFTER we built can still be reaped. The spawn happens on the
## spawner's own schedule, which may be several frames after the clone exists,
## so a build-time sweep alone cannot be enough.
var gModsReapClone: seq[Il2CppPtr] = @[]
var gModsReapDonor: seq[Il2CppPtr] = @[]
var gModsReapCaption: seq[string] = @[]
## The re-assert throttle, and the count of consecutive checks that found every
## label intact. After ModsStableEnough of those it STOPS: a label nothing is
## fighting over does not need a poll for the rest of the session.
var gModsLabelFrames = 0
var gModsLabelStable = 0
const ModsLabelEveryFrames = 60
const ModsStableEnough = 10

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
## Fault budget for the NATIVE lifecycle rider only (`settingsNativeLifecycle`).
## Separate from `gModsFaults`, which guards the standing-check path that must
## keep working even if this rider self-disables.
var gModsNativeFaults = 0
const ModsNativeMaxFaults = 4
var gModsNativeSaidHide = false

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

## INTERNED TYPE-NAME STRINGS, same idiom as `inspect.nim`'s `gTxtTypeStr`
## (`findtext`'s "allocated ONCE per search, reused for every node's
## GetComponent call"). `modsComponent` used to call `il2cpp_string_new`
## FRESH on every node -- and a live crumb proved that path can hand back a
## pointer that reads as non-null-and-readable and STILL faults inside
## `GetComponent`. Rather than chase why one specific allocation is bad, this
## removes per-call allocation from the picture entirely: each distinct type
## name is interned once, verified, and every later call reuses the SAME
## proven-good string object.
## DECLINE vs ABSENCE, counted separately. A guard inside `modsComponent`
## returning nil BEFORE ever calling GetComponent ("I refused to look") must
## never render the same as GetComponent genuinely finding nothing ("it is
## not there") -- that conflation is what made a false decline look like a
## content problem for two rounds straight (CLAUDE.md rule 9b). Reset per
## search by the caller (`modsCollectTmp`'s top-level entry points), read
## back as a delta.
var gModsExamined = 0   ## every node modsComponent was asked about
var gModsDeclines = 0   ## of those, how many were refused before the icall

## `Component::GetComponent(String)`, resolved ONCE (fully-qualified name
## tried first, bare name as a logged fallback) rather than re-resolved
## (and possibly re-guessed) on every `modsComponent` call.
var gModsGcFn: Il2CppPtr = nil
var gModsGcTries = 0
const ModsGcMaxTries = 8

proc modsInternedStr(typeName: string): Il2CppPtr =
  ## FRESH, NOT CACHED -- despite the name, kept only so every call site does
  ## not need to change. MEASURED LIVE (the coordinator's timeline: self-test
  ## at 0:00:50, walk at 0:02:22): a cached `il2cpp_string_new` result is NOT
  ## GC-pinned, so a pointer proven live at bind time can be collected or
  ## moved before a later call reuses it -- GetComponent then compares
  ## against garbage and returns NULL, no fault, indistinguishable from a
  ## real absence. Caching traded a rare fault (fixed below by the null
  ## check) for a permanent silent null. Allocate immediately before every
  ## use, exactly like the pre-interning code that demonstrably resolved
  ## components, and decline by name if the allocation itself came back bad.
  var name = typeName
  let sp = cNavNewString(toCString(name))
  if sp == nil or not duOk(sp, 0x18'i32):
    warn "mods tab: il2cpp_string_new for \"" & typeName & "\" did not " &
         "produce a live, readable managed string; nothing was called."
    return nil
  result = sp

## STAGE CRUMBS. Same idea as `settingsui.nim`'s `gSwCrumb`: one cheap string
## assignment before every IL2CPP call in the mods-tab body, so a caught fault
## (which unwinds the WHOLE guarded body silently -- fact #19) can still say
## WHERE it died instead of just "FAULTED and was caught". Never per-frame
## allocation-heavy: this runs on a tab click and once per steady-state tick,
## not in a hot loop of its own.
var gModsCrumb = "(nothing attempted yet)"

proc modsCrumb(what: string) =
  gModsCrumb = what

proc modsCrumbP(what: string; p: Il2CppPtr) =
  gModsCrumb = what & " ptr=0x" & hexOf(cast[uint64](p))

proc modsNoteFault(what: string) =
  inc gModsFaults
  warn "mods tab: " & what & " (fault " & $gModsFaults & " of " &
       $ModsMaxFaults & "). LAST HOP ATTEMPTED: " & gModsCrumb
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
  ## An ICALL (`GameObject::SetActive`). `duOk` alone is not enough here: a
  ## DESTROYED-but-still-readable Unity wrapper (a "fake null") passes a plain
  ## readability check and then faults INSIDE Unity's own code when the icall
  ## dereferences `m_CachedPtr` -- `iUnityAlive` is the guard keyed off that.
  modsCrumbP("modsSetActive", go)
  let fn = mi2Fn(Mi2GoSetActive)
  if fn == nil or go == nil or not iUnityAlive(go):
    return false
  cMi2CallVPB(fn, go, (if on: 1'i32 else: 0'i32))
  result = true

proc modsTransformOf(go: Il2CppPtr): Il2CppPtr =
  let fn = mi2Fn(Mi2GoGetTransform)
  if fn == nil or go == nil:
    return nil
  result = cMi2CallPP(fn, go)
  # CONTRACT-GUARANTEED Transform: seed the klass whitelist `modsComponent`
  # checks against, exactly like `inspect.nim`'s own `get_transform` call does.
  if result != nil:
    iNoteTransform(result)

proc modsSetFirstSibling(t: Il2CppPtr): bool =
  ## `Transform::SetAsFirstSibling` -- moves `t` to sibling index 0 among its
  ## PARENT's children. Only ever called on a strip WE cloned; nothing about
  ## the parent or its other children is touched, it is simply where in the
  ## parent's child list our own object sits.
  result = false
  modsCrumbP("modsSetFirstSibling", t)
  let fn = mi2Fn(Mi2SetAsFirstSibling)
  if fn == nil or t == nil or not iUnityAlive(t):
    return
  discard cMi2CallPP(fn, t)              # void method; the "return" is unused
  result = true

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
  ## not one. MEASURED LIVE (not the "returns NULL, no fault" this comment used
  ## to claim): `Component::GetComponent(String)` puts the wrong `this` in RCX
  ## when handed a GameObject and FAULTS inside Unity's own code -- same class
  ## of bug as ff6b769 and the inspector's `iRefuseIfGameObject`. So this
  ## refuses loudly before ever reaching the icall, rather than calling through
  ## and hoping.
  result = nil
  inc gModsExamined
  modsCrumbP("modsComponent(" & typeName & ") node=" & iObjName(comp) &
             " parent=" & iObjName(modsParentOf(comp)), comp)
  if comp == nil:
    inc gModsDeclines
    return
  if iRefuseIfGameObject(comp, "modsComponent(" & typeName & ")"):
    inc gModsDeclines
    warn "mods tab: modsComponent(" & typeName & ") was handed a GameObject " &
         "(" & iObjName(comp) & ", parent " & iObjName(modsParentOf(comp)) &
         ") instead of a Transform/Component -- DECLINING rather than " &
         "calling GetComponent through the wrong `this`."
    return
  if not iUnityAlive(comp):
    inc gModsDeclines
    return
  # REMOVED: a klass whitelist (`gTfKlass`/`iIsTransform`) used to gate here.
  # DISPROVED LIVE: the coordinator ran the inspector's own `component` on
  # the exact node it was added for and got FOUND -- the receiver was always
  # valid, so the whitelist only ever contributed false declines (a decline
  # that then rendered as "no TextMeshProUGUI anywhere", indistinguishable
  # from a real absence -- see `gModsDeclines`/`gModsExamined` below).
  # RESOLVED ONCE, LOUDLY, SELF-TESTED, NOT RE-GUESSED PER CALL. The bare
  # name @0x52a48e0 is CONFIRMED live (self-test finds real components), so
  # this only tries a few times if the bind or a probe node hasn't proven
  # itself yet -- see `gModsDeclines` for how those unproven calls are
  # counted separately from a genuine "GetComponent said no".
  if gModsGcFn == nil:
    # RETRIED, not latched on one failure: a probe node that genuinely lacks
    # `typeName` (e.g. the first call happens to be for "AnimatedToggle" on a
    # node with none) must not be confused with a broken bind, so this tries
    # again on the NEXT call rather than refusing forever after one null --
    # but a resolved RVA is only ever trusted once it has actually PRODUCED a
    # component, never on the strength of iNavFind alone (that is exactly
    # what hid the wrong-address bind for four rounds).
    if gModsGcTries < ModsGcMaxTries:
      inc gModsGcTries
      var f1: Il2CppPtr = nil
      var r1 = 0'u32
      if not iNavFind("GetComponent(String)", f1, r1):
        inc gModsDeclines
        warn "mods tab: GetComponent could not be bound at all (try " &
             $gModsGcTries & " of " & $ModsGcMaxTries & ")."
      else:
        let str0 = modsInternedStr(typeName)
        let probe = (if str0 != nil: cast[Il2CppPtr](cInspUPP(f1, comp, str0, nil))
                     else: nil)
        if probe != nil:
          gModsGcFn = f1
          okLog "mods tab: GetComponent bound @0x" & hexOf(uint64(r1)) &
                " -- SELF-TESTED true, found " & typeName & " = " &
                iPtr(probe) & " on " & iObjName(comp)
          return probe
        else:
          inc gModsDeclines
          warn "mods tab: GetComponent bound @0x" & hexOf(uint64(r1)) & " " &
               "but the self-test for \"" & typeName & "\" on " &
               iObjName(comp) & " came back null (try " & $gModsGcTries &
               " of " & $ModsGcMaxTries & "); not yet trusted -- will not " &
               "call it for real until one self-test finds something."
    else:
      inc gModsDeclines           # tries exhausted; still not trusted
    return
  let fn = gModsGcFn
  if fn == nil:
    return
  if cNavIcallReady() == 0'i32:
    return
  # FRESH, immediately before use, every call -- see `modsInternedStr`. `fn`
  # (a code address) does not go stale between calls the way a GC'd managed
  # string does, so it stays bound-once; the string does not, so it is never
  # reused across calls, no matter how long the walk that calls this runs.
  let sp = modsInternedStr(typeName)
  modsCrumbP("modsComponent(" & typeName & ") node=" & iObjName(comp) &
             " str=", sp)
  if sp == nil:
    return                              # modsInternedStr already warned
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
  ## plain button, otherwise on a CHILD -- by shape, never by the donor's child
  ## name (fact #87: a spawner clone names its toggle `AnimatedToggle`, the
  ## donor names it `ControlsToggle`, and which a walk finds depends on
  ## enumeration order).
  ##
  ## ACTIVE CHILDREN FIRST, and this is not cosmetic. A cloned spawner ends up
  ## with TWO toggles (fact #93) and the reap switches one OFF. Binding the
  ## switched-off one gives a pointer whose `m_IsOn` never changes: the tab
  ## would never hide, and a subtab would never switch a page. That is the
  ## single most likely cause of "selecting a subtab does nothing", so the
  ## search is ordered to make it impossible rather than unlikely.
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
  var pass = 0
  while pass < 2:
    var i = 0
    while i < n and i < 8:
      let inner = iChildAt(t, i)
      if inner != nil and duOk(inner, 0x20'i32):
        let go = iGameObjectOf(inner)
        let live = (go != nil and modsGoActive(go))
        if (pass == 0 and live) or (pass == 1 and not live):
          result = modsComponent(inner, "AnimatedToggle")
          if result == nil:
            result = modsComponent(inner, "Toggle")
          if result != nil:
            if pass == 1:
              warn "mods tab: the only Toggle under this clone is on an " &
                   "INACTIVE object, so its m_IsOn can never change and the " &
                   "control it drives will never respond. Binding it anyway " &
                   "so the failure is visible rather than silent."
            return
      i = i + 1
    pass = pass + 1

proc modsDescribeToggle(tag: string; tog: Il2CppPtr) =
  ## MEASURE, do not infer. Prints what a bound toggle actually is: its object's
  ## active state, its `m_IsOn` (+0x120) and its `m_Group` (+0x110) -- fact #80.
  ## The group pointer is what says whether exclusivity is the game's or ours,
  ## and it was only ever measured for the TAB strip clone; this measures it for
  ## every subtab too, which is what the next live run needs in order to answer
  ## "are the subtabs exclusive?" without guessing.
  if tog == nil:
    warn "mods tab: " & tag & " -> NO TOGGLE BOUND"
    return
  var grp: Il2CppPtr = nil
  if duOk(tog, ModsOffGroup + 8'i32):
    grp = cReadPtrAt(tog, ModsOffGroup)
  let go = iGameObjectOf(tog)
  okLog "mods tab: " & tag & " -> toggle=" & iPtr(tog) & " objectActive=" &
        (if go != nil and modsGoActive(go): "true" else: "FALSE") &
        " m_IsOn=" & (if duOk(tog, ModsOffIsOn + 4'i32) and
                         cSwReadU8(tog, ModsOffIsOn) != 0'i32: "true"
                      else: "false") &
        " m_Group=" & iPtr(grp)

proc modsCollectTmp(t: Il2CppPtr; depth: int; nodes: var seq[Il2CppPtr];
                    tmps: var seq[Il2CppPtr]; isRoot: bool = false) =
  ## EVERY TextMeshProUGUI at or under `t`, to `depth` levels. Capped hard at
  ## `ModsMaxTmp` in total and 16 per level.
  ##
  ## Why all of them rather than the first: a tab button carries more than one.
  ## On this build the one that RENDERS is not necessarily the one named
  ## `Label` -- TMP parents its `TMP UI SubObject` submesh under the object it
  ## renders on, and the clone that came out blank had no submesh at all, which
  ## is the fingerprint of a TMP that was never given text. So the caller tries
  ## each in turn and keeps the one whose text actually reads back.
  ##
  ## `t` MUST be a Transform, never a GameObject: `Component::GetComponent`
  ## reads a GameObject's layout as if it were a Component and returns null on
  ## every call, no fault, no decline -- indistinguishable from a genuine
  ## absence. `isRoot` makes the walk's OWN starting pointer's kind visible in
  ## the log rather than trusted on faith; every recursive step below only
  ## ever hands `t` the result of `iChildAt`, which returns a Transform by
  ## contract, so this is checked once per walk, not once per node.
  if isRoot:
    okLog "mods tab: TMP walk root ptr=" & iPtr(t) & " name=" & iObjName(t) &
          " isGameObject=" & $iIsGameObject(t) & " (must be false -- a " &
          "GameObject here silently resolves zero TMPs every time)"
  if t == nil or depth < 0 or not duOk(t, 0x20'i32) or tmps.len >= ModsMaxTmp:
    return
  if iIsGameObject(t):
    warn "mods tab: TMP walk DECLINED " & iObjName(t) & " -- it is a " &
         "GameObject, not a Transform; GetComponent would silently return " &
         "null on it forever. Fix the caller that fed it in."
    return
  let here = modsComponent(t, "TextMeshProUGUI")
  if here != nil:
    nodes.add t
    tmps.add here
  if depth == 0:
    return
  var n = 0
  if not iChildCount(t, n):
    return
  var i = 0
  while i < n and i < 16 and tmps.len < ModsMaxTmp:
    let c = iChildAt(t, i)
    if c != nil:
      modsCollectTmp(c, depth - 1, nodes, tmps)
    i = i + 1

proc modsTmpText(tmp: Il2CppPtr): string =
  ## What this TMP's `m_text` reads right now. The offset comes from the
  ## settings-write module's own field table, never a guess.
  result = ""
  if tmp == nil or not duOk(tmp, cSuiOffTmpMText() + 8'i32):
    return
  result = suiReadString(cReadPtrAt(tmp, cSuiOffTmpMText()))

proc modsFindTmp(t: Il2CppPtr; depth: int): Il2CppPtr =
  ## Is there ANY reachable TMP under `t`? Used only as a donor-shape assertion
  ## before cloning; the relabel itself uses `modsCollectTmp` and tries them all.
  result = nil
  var nodes: seq[Il2CppPtr] = @[]
  var tmps: seq[Il2CppPtr] = @[]
  modsCollectTmp(t, depth, nodes, tmps, isRoot = true)
  if tmps.len > 0:
    result = tmps[0]

proc modsChildCount(t: Il2CppPtr): int =
  result = 0
  var n = 0
  if t != nil and iChildCount(t, n):
    result = n

proc modsReapExtraToggles(cloneT, donorT: Il2CppPtr; caption: string): int =
  ## FACT #93. Cloning a *ToggleSpawner* clones the toggle it had ALREADY
  ## spawned AND leaves the spawner itself live inside the clone -- so it
  ## spawns a SECOND one, under its own default name. The result is a clone
  ## with two toggles where the donor has one: the captioned one, and an
  ## unlabelled rectangle beside it. That is also why one walk saw
  ## `ControlsToggle` and another saw `AnimatedToggle`: BOTH exist, and which
  ## you find depends on enumeration order.
  ##
  ## The tell was in our own log -- "2 of the clone's FOUR TextMeshProUGUI" --
  ## and the caption check passed anyway, because counting captions says
  ## nothing about an uncaptioned sibling. So the DONOR IS THE GROUND TRUTH FOR
  ## COUNT TOO: the clone may not have more children than the donor.
  ##
  ## Which one survives is decided by OUTCOME, not by name: the child whose
  ## subtree reads our caption is the one the player can read. Everything past
  ## it is switched off. These are objects inside a clone WE made, which is the
  ## only reason this is ours to switch off at all.
  ##
  ## Returns how many were switched off. Idempotent, capped, and it must be
  ## re-run for a while after the build, because the spawn happens on the
  ## spawner's own schedule and may not have happened yet when we relabel.
  result = 0
  let want = modsChildCount(donorT)
  let have = modsChildCount(cloneT)
  if want <= 0 or have <= want:
    return
  var keep = -1
  var i = 0
  while i < have and i < 8:
    let c = iChildAt(cloneT, i)
    if c != nil and duOk(c, 0x20'i32) and keep < 0:
      if modsCountReading(c, caption) > 0:
        keep = i
    i = i + 1
  if keep < 0:
    keep = 0                            # nothing reads our caption; keep the
                                        # first and let the caption check speak
  i = 0
  while i < have and i < 8:
    if i != keep:
      let c = iChildAt(cloneT, i)
      if c != nil and duOk(c, 0x20'i32):
        let go = iGameObjectOf(c)
        if go != nil and modsGoActive(go) and modsSetActive(go, false):
          result = result + 1
    i = i + 1
  if result > 0:
    okLog "mods tab: switched off " & $result & " extra toggle(s) inside a " &
          "cloned spawner -- the donor has " & $want & " child(ren) and the " &
          "clone had " & $have & ". A *ToggleSpawner clone keeps spawning " &
          "(fact #93), so the copy is the captioned one at index " & $keep &
          " and the spawner's own is switched off. Without this there is an " &
          "unlabelled rectangle beside every button we clone."

proc modsCaptionOf(donorT: Il2CppPtr; count: var int): string =
  ## THE DONOR IS THE GROUND TRUTH. What caption does this stock button show,
  ## and on HOW MANY of its TextMeshProUGUI does that caption appear?
  ##
  ## Measured (fact #88): a stock tab button carries THREE TMPs reading
  ## "CONTROLS" -- `SizeLabel` (a sizing helper) and two `SizeLabel/Label`
  ## nodes, and it is the Label nodes the player actually reads. Writing the
  ## first TMP that answers therefore changes a caption nobody sees.
  ##
  ## So the donor is asked how many to expect, and the clone must end up with
  ## the same number. The most common non-empty text wins, because a button may
  ## also carry an unrelated TMP (a hotkey hint, a badge).
  result = ""
  count = 0
  var nodes: seq[Il2CppPtr] = @[]
  var tmps: seq[Il2CppPtr] = @[]
  modsCollectTmp(donorT, 4, nodes, tmps, isRoot = true)
  var i = 0
  while i < tmps.len:
    let ti = modsTmpText(tmps[i])
    if ti.len > 0:
      var c = 0
      var j = 0
      while j < tmps.len:
        if modsTmpText(tmps[j]) == ti:
          c = c + 1
        j = j + 1
      if c > count:
        count = c
        result = ti
    i = i + 1

proc modsCountReading(t: Il2CppPtr; text: string): int =
  ## How many TMPs under `t` currently read exactly `text`. THE OUTCOME CHECK.
  result = 0
  var nodes: seq[Il2CppPtr] = @[]
  var tmps: seq[Il2CppPtr] = @[]
  modsCollectTmp(t, 4, nodes, tmps, isRoot = true)
  var i = 0
  while i < tmps.len:
    if modsTmpText(tmps[i]) == text:
      result = result + 1
    i = i + 1

proc modsRelabelLike(cloneT, donorT: Il2CppPtr; text: string;
                     cloneCtrl: Il2CppPtr = nil): bool =
  ## Relabel a button WE cloned, and prove the CAPTION CHANGED -- not merely
  ## that a write landed.
  ##
  ## FACT #88, and it is the durable lesson of this feature: the previous
  ## version picked the first TMP already carrying text, wrote it, and read
  ## `m_text` back. All three steps genuinely succeeded and the tab was still
  ## blank, because the TMP it verified was `SizeLabel`, the sizing helper --
  ## the glyphs come from the `SizeLabel/Label` nodes. "The write landed" and
  ## "the caption changed" are different claims, and only the first was checked.
  ##
  ## So: take the donor's caption and its COUNT, write every clone TMP that
  ## carries that caption (or is empty where the donor's was not), and then
  ## assert the clone reads the new caption on the SAME NUMBER of TMPs the
  ## donor read the old one on. One of three is a refusal, not a success.
  result = false
  var want = 0
  let caption = modsCaptionOf(donorT, want)
  var cNodes: seq[Il2CppPtr] = @[]
  var cTmps: seq[Il2CppPtr] = @[]
  let examined0 = gModsExamined
  let declines0 = gModsDeclines
  modsCollectTmp(cloneT, 4, cNodes, cTmps, isRoot = true)
  if cTmps.len == 0:
    let ex = gModsExamined - examined0
    let dc = gModsDeclines - declines0
    warn "mods tab: REFUSING to claim the label '" & text & "' -- " &
         (if dc > 0:
            "modsComponent DECLINED " & $dc & " of " & $ex & " node(s) " &
            "examined (searched 4 levels) without ever calling GetComponent " &
            "-- this is a REFUSAL, not proof there is no TextMeshProUGUI"
          else:
            "GetComponent was called on all " & $ex & " node(s) examined " &
            "(4 levels) and found none -- this IS an absence, not a decline") &
         ". Nothing was written."
    return
  if want == 0:
    # No caption on the donor at all. Fall back to writing every candidate,
    # and say so: an expectation we could not derive is not an expectation.
    want = cTmps.len
    okLog "mods tab: the donor for '" & text & "' shows no caption of its " &
          "own, so there is no count to match; writing all " & $cTmps.len &
          " candidate(s) and checking the outcome against that instead."
  var wrote = 0
  var i = 0
  while i < cTmps.len:
    let cur = modsTmpText(cTmps[i])
    # Every TMP that shows the donor's caption, plus the empty ones -- a clone
    # whose Label came out blank is exactly the case being fixed. A TMP showing
    # something ELSE is left alone: it is not part of this caption.
    if cur == caption or cur.len == 0 or caption.len == 0:
      # FACT #88, THE PART THIS RE-ASSERT USED TO MISS: `swRelabelControl`'s
      # first argument is not decorative -- it is what lets it call
      # `LocalizedText::SetLabelText` at the level the game itself writes at.
      # Passed nil (as this loop always did before), only the raw
      # `TMP_Text::set_text` route runs: the write lands, reads back true, and
      # then the row's OWN inherited LocalizedText clobbers it back to the
      # donor's caption the next time it refreshes -- which a subtab's
      # `SetActive(true)` on re-select reliably triggers. That is why every
      # row on every MODS subtab kept showing the donor's caption
      # ('Interface language') even though this same function logged success.
      # Passing the clone's real control here lets the LocalizedText source get
      # fixed too, not just today's TMP text.
      if swRelabelControl(cloneCtrl, cTmps[i], text):
        if modsTmpText(cTmps[i]) == text:
          wrote = wrote + 1
          if gModsLabelTmp.len < ModsMaxLabels:
            gModsLabelTmp.add cTmps[i]
            gModsLabelText.add text
    i = i + 1
  # THE OUTCOME CHECK: re-read the whole clone, not the pointers we just wrote.
  let reads = modsCountReading(cloneT, text)
  gModsLabelStable = 0
  if reads >= want and reads > 0:
    result = true
    okLog "mods tab: caption '" & text & "' is now on " & $reads & " of the " &
          "clone's " & $cTmps.len & " TextMeshProUGUI, matching the donor, " &
          "which shows '" & caption & "' on " & $want &
          ". Verified by re-reading the clone, not by trusting the write."
  else:
    warn "mods tab: the caption '" & text & "' DID NOT FULLY TAKE -- it reads " &
         "on " & $reads & " of the clone's " & $cTmps.len & " TMP(s) but the " &
         "donor shows '" & caption & "' on " & $want & ". " & $wrote &
         " write(s) verified individually. The control is wrong or partly " &
         "blank on screen; reporting that rather than claiming a built tab. " &
         "(This is fact #88: a write that lands on the SIZING helper reads " &
         "back perfectly and changes nothing the player sees.)"

proc modsRelabelRow(cloneT, donorT: Il2CppPtr; text: string;
                    cloneCtrl: Il2CppPtr = nil): bool =
  ## Relabel a ROW clone. Unlike `modsRelabelLike` (used for the tab/subtab
  ## BUTTONS, where "N of N matching the donor" holds up), a row clone is a
  ## clone-of-a-clone ("Settings Drop Down(Clone)(Clone)") and was measured
  ## LIVE (`findtext "Interface language" ... all`) to carry THREE
  ## TextMeshProUGUI where only one -- a child literally named "Text" -- is
  ## the one that renders. `modsRelabelLike`'s "count matches the donor"
  ## check is unfalsifiable here: it only re-reads what it just wrote, so it
  ## can be satisfied by writing the WRONG TMP and never touching the one on
  ## screen -- which is exactly what the host log's "1 of 3, matching the
  ## donor" was doing while every row visibly still read the donor's caption.
  ##
  ## So: write EVERY TMP the clone carries, unconditionally (no cur==caption
  ## filter -- that filter is what skipped the "Text" node when it still held
  ## something the donor-count math treated as already-correct). Then the
  ## check that decides success is the one thing that can actually FAIL: does
  ## any TMP under this clone still read the donor's ORIGINAL caption after
  ## the write? If so, that is the one rendering and the fix did not reach it.
  result = false
  var want = 0
  let donorCaption = modsCaptionOf(donorT, want)
  var cNodes: seq[Il2CppPtr] = @[]
  var cTmps: seq[Il2CppPtr] = @[]
  modsCollectTmp(cloneT, 4, cNodes, cTmps, isRoot = true)
  if cTmps.len == 0:
    warn "mods tab: REFUSING to claim the row label '" & text & "' -- there " &
         "is no TextMeshProUGUI anywhere under this clone (searched 4 " &
         "levels). Nothing was written."
    return
  var wrote = 0
  var i = 0
  while i < cTmps.len:
    if swRelabelControl(cloneCtrl, cTmps[i], text):
      wrote = wrote + 1
    i = i + 1
  # THE CHECK THAT CAN FAIL: re-read every TMP under the clone afterwards and
  # count how many STILL show the donor's ORIGINAL caption -- not how many
  # show ours, and not a count borrowed from the donor.
  var stale = 0
  i = 0
  while i < cTmps.len:
    if donorCaption.len > 0 and modsTmpText(cTmps[i]) == donorCaption:
      stale = stale + 1
    i = i + 1
  result = stale == 0
  if result:
    okLog "mods tab: row caption '" & text & "' written to all " &
          $cTmps.len & " of the clone's TextMeshProUGUI (" & $wrote &
          " write(s) succeeded); none still read the donor's '" &
          donorCaption & "'."
  else:
    warn "mods tab: row caption '" & text & "' DID NOT FULLY TAKE -- " &
         $stale & " of the clone's " & $cTmps.len & " TextMeshProUGUI " &
         "STILL read the donor's original '" & donorCaption & "' after " &
         $wrote & " write(s). That TMP is the one rendering, and it did " &
         "not take the new caption."

proc modsRelabel(t: Il2CppPtr; text: string): bool =
  ## Relabel with no donor to compare against: the clone is its own reference.
  ## Kept for callers that have no donor handy; everything on the build path
  ## uses `modsRelabelLike`, which is strictly stronger.
  result = modsRelabelLike(t, t, text)

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
  modsCrumbP("modsSetToggleQuiet", toggle)
  if toggle == nil or not iUnityAlive(toggle):
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
  devRows.add swRow("settingsNativeLifecycle", "MODS tab hide rides ShowScreen", readBoolKey("settingsNativeLifecycle"), false)
  devRows.add swRow("codeGenAudit", "CodeGen audit", readBoolKey("codeGenAudit"), false)
  result.add modsPage("dev", "Diagnostics", devRows,
                      "Developer instruments. All read once at boot.")

  # ---- one subtab per MOD, fetched over the wire (`modsettingsrender.nim`)
  # and already sitting in `gSwPages` (the same registry the Game-tab flat
  # list reads) by the time the player opens Settings -- the fetch cycle runs
  # off `hostMain`'s own tick loop from boot, well before any tab is built.
  # `swPageRegister` keys pages by id and a mod's id is always "mod:<guid>"
  # (`modSetParseSchema`), so filtering on `modGuid.len > 0` picks out exactly
  # the fetched pages and none of the built-in ones above.
  var m = 0
  while m < gSwPages.len and result.len < ModsMaxSubtabs:
    if gSwPages[m].modGuid.len > 0:
      result.add gSwPages[m]
    m = m + 1

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

proc modsPruneToPath(panelT, stackT: Il2CppPtr): int =
  ## Switch off everything in our cloned panel except the path down to the
  ## container we render into.
  ##
  ## WHY, MEASURED: sweeping the row container's own children left
  ## `Game Settings(Clone)/Container/Nickname Panel` alive -- with its warning
  ## panel, its input field and its caption -- because that is a PANEL, not a
  ## row, and it hangs off a node ABOVE the one we swept. "40 inherited rows
  ## switched off" was true and insufficient.
  ##
  ## So this walks UP from our container to the panel root, and at every node on
  ## that path switches off every child EXCEPT the next node down. The clone
  ## then contains exactly one live spine and whatever we put at the bottom of
  ## it. Bounded: at most 8 levels, 64 children each.
  result = 0
  var path: seq[Il2CppPtr] = @[]
  var cur = stackT
  var guard = 0
  while cur != nil and guard < 8:
    path.add cur
    if cur == panelT:
      break
    cur = modsParentOf(cur)
    guard = guard + 1
  if path.len == 0 or path[path.len - 1] != panelT:
    warn "mods tab: could not walk from the page container back up to the " &
         "cloned panel within 8 levels, so the panel could NOT be pruned. " &
         "Inherited panels above the container may still be on screen."
    return
  var level = path.len - 1
  while level > 0:
    let node = path[level]
    let keep = path[level - 1]
    var n = 0
    if iChildCount(node, n):
      var i = 0
      while i < n and i < 64:
        let c = iChildAt(node, i)
        if c != nil and c != keep and duOk(c, 0x20'i32):
          let go = iGameObjectOf(c)
          if go != nil and modsGoActive(go) and modsSetActive(go, false):
            result = result + 1
        i = i + 1
    level = level - 1

proc modsActiveChildren(t: Il2CppPtr): int =
  ## How many of `t`'s children are active. The outcome check for the sweeps.
  result = 0
  var n = 0
  if t == nil or not iChildCount(t, n):
    return
  var i = 0
  while i < n and i < 64:
    let c = iChildAt(t, i)
    if c != nil and duOk(c, 0x20'i32):
      let go = iGameObjectOf(c)
      if go != nil and modsGoActive(go):
        result = result + 1
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
  ##
  ## NEVER MORE THAN ONE. If `gModsHidden` holds more than one entry, more than
  ## one stock panel was ALREADY active at once before MODS ever touched the
  ## screen (measured: the postfx subtab leaving Graphics Settings AND PostFX
  ## Settings both active is exactly how this happens) -- restoring every entry
  ## would just re-create that inconsistency, one tab switch later and harder to
  ## explain. Keep the first (screenT child order) and leave the rest hidden;
  ## the steady state this asserts is exactly one active stock panel.
  if gModsHidden.len > 1:
    warn "mods tab: " & $gModsHidden.len & " stock panel(s) were active " &
         "together when MODS hid them; restoring only the first so the " &
         "steady state is exactly one active panel, not a pile-up"
  var i = 0
  while i < gModsHidden.len and i < ModsMaxHidden:
    discard modsSetActive(gModsHidden[i], i == 0)
    i = i + 1
  gModsHidden = @[]

proc modsNativeOnShowScreen(group: int32) =
  ## Called from `settingsui.nim`'s ShowScreen-postfix body (the SAME detour
  ## `settingsUiProbe`/`gModsOn` already rides -- this installs NOTHING of its
  ## own), already inside that body's ONE `aowl_p_p_seh` guard. Must NOT open
  ## a second one -- the guard is not re-entrant.
  ##
  ## `group` is whatever `ESettingsGroup` the game just switched TO. It is
  ## never ours (our tab is not a registered group -- see the file header),
  ## so any call here at all is native proof the player just picked a STOCK
  ## tab. If our panel was showing, that means MODS was just left, and this
  ## does the hide/restore right now instead of waiting for the next frame's
  ## toggle poll in `modsTabTickBody`.
  ##
  ## Only ever HIDES. It never shows our panel -- there is no ShowScreen call
  ## for entering MODS to hook (our clone toggle invokes nothing native), so
  ## that edge stays exactly the existing standing-check poll.
  if not gModsOn or not gModsNativeLifecycle:
    return
  if gModsNativeFaults >= ModsNativeMaxFaults:
    return
  if not gModsShown:
    return                                # nothing to natively hide
  if gModsToggle == nil or gModsPanel == nil:
    return
  if not duOk(gModsPanel, 0x20'i32):
    inc gModsNativeFaults
    warn "mods tab: native lifecycle rider could not read our panel on a " &
         "ShowScreen(group=" & $int(group) & ") postfix -- skipping this " &
         "hide, standing-check poll will still catch it. Fault " &
         $gModsNativeFaults & "/" & $ModsNativeMaxFaults
    return
  if not modsSetActive(gModsPanel, false):
    inc gModsNativeFaults
    warn "mods tab: native lifecycle rider failed to switch our panel off " &
         "on ShowScreen(group=" & $int(group) & ") -- leaving it for the " &
         "standing-check poll. Fault " & $gModsNativeFaults & "/" &
         $ModsNativeMaxFaults
    return
  modsRestoreStockPanels()
  gModsShown = false
  var q = 0
  while q < gModsPages.len:
    swReadBackPage(gModsPages[q])
    q = q + 1
  if not gModsNativeSaidHide:
    gModsNativeSaidHide = true
    okLog "mods tab: native lifecycle rider hid the MODS panel from the " &
          "ShowScreen(group=" & $int(group) & ") postfix -- driven by the " &
          "game's own tab switch, not the standing check"
  if gModsNativeFaults > 0:
    gModsNativeFaults = 0                 # a clean run forgives past faults

proc modsBuildSubtabs(stripT, buttonDonorGo, donorT: Il2CppPtr;
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
  var badLabels = 0
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
    # AGAINST THE DONOR, not against itself: the donor says how many TMPs a
    # caption must land on for the button to actually read it. The refusal
    # inside `modsRelabelLike` is the loud one; this only counts them.
    if not modsRelabelLike(btnT, donorT, gModsPages[p].title):
      badLabels = badLabels + 1
    # RE-BIND AFTER THE REAP. `tog` above was read before the extra toggle was
    # switched off, so it may be the pointer to the object we just killed --
    # whose m_IsOn can never change again. This is the most likely reason a
    # subtab click changed nothing, so it is fixed by ORDER, not by hope.
    discard modsReapExtraToggles(btnT, donorT, gModsPages[p].title)
    let live = modsToggleOf(btnT)
    let bound = (if live != nil: live else: tog)
    modsDescribeToggle("subtab '" & gModsPages[p].id & "' after the reap", bound)
    if gModsReapClone.len < ModsMaxSubtabs + 1:
      gModsReapClone.add btnT
      gModsReapDonor.add donorT
      gModsReapCaption.add gModsPages[p].title
    # THE GROUP QUESTION, MEASURED RATHER THAN ASSUMED. On the live client this
    # came back NATIVE for the tab-button donor: Instantiate remapped each
    # clone's m_Group onto the cloned group. The stock-group branch stays
    # because the measurement is PER DONOR and this is a different donor.
    if duOk(bound, ModsOffGroup + 8'i32):
      let g = cReadPtrAt(bound, ModsOffGroup)
      if g != nil and g == stockGroup:
        gModsOwnExclusive = true
        discard cUxWritePtr(bound, ModsOffGroup, cast[Il2CppPtr](0))
    discard modsSetActive(btn, true)
    gModsSubs.add ModsSub(name: gModsPages[p].title, toggle: bound,
                          pageGo: nil, lastOn: false)
    result = result + 1
    p = p + 1
  if badLabels > 0:
    warn "mods tab: " & $badLabels & " of " & $result & " subtab caption(s) " &
         "did not fully take, so those subtabs read blank or wrong on screen. " &
         "The lines above name each one."
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
  # The tab caption, checked AGAINST THE DONOR. `modsRelabelLike` says loudly
  # what happened either way; a partial caption is a blank tab, so it is worth
  # one more line here naming the consequence.
  if not modsRelabelLike(tabCloneT, donorTab, "MODS"):
    warn "mods tab: the sixth tab button will not read 'MODS' on screen. The " &
         "tab is still built and still switches the panel -- it is the " &
         "CAPTION that failed, and the line above says on how many of the " &
         "donor's TextMeshProUGUI it should have landed."
  # THE COUNT CHECK, against the donor. A caption check alone passed while an
  # UNLABELLED second toggle sat beside ours -- fact #93.
  discard modsReapExtraToggles(tabCloneT, donorTab, "MODS")
  gModsReapClone.add tabCloneT
  gModsReapDonor.add donorTab
  gModsReapCaption.add "MODS"
  let mainToggle = modsToggleOf(tabCloneT)
  modsDescribeToggle("the MODS tab button after the reap", mainToggle)
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
  # AND EVERYTHING ABOVE IT. Sweeping the container's own children is not
  # enough: `Game Settings(Clone)/Container/Nickname Panel` survived that sweep
  # -- with its warning panel, input field and caption -- because it is a
  # PANEL, not a row, hanging off a node ABOVE the one we swept. "40 inherited
  # rows switched off" was true and insufficient.
  let pruned = modsPruneToPath(panelT, stackT)
  okLog "mods tab: switched off " & $hidden & " inherited row(s) inside our " &
        "page container and " & $pruned & " inherited sibling(s) on the spine " &
        "above it (that is where 'Nickname Panel' lived), so the MODS body " &
        "starts EMPTY instead of showing a second copy of Game Settings"

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
  let made = modsBuildSubtabs(stripT, donorButtonGo, donorButton,
                              modsToggleOf(donorTab))
  if made <= 0:
    modsNoteFault("the strip yielded no usable subtab button; the panel is " &
                  "left hidden and empty rather than half-built")
    return
  discard modsSetActive(stripClone, true)

  # DOCK AT THE TOP, NOT THE CENTRE. `modsSetParent` always appends, so the
  # cloned strip landed after whatever was already in the layout group and
  # the vertical layout drew it in the middle of the panel instead of above
  # the rows. Same fix as the postfx strip: sibling index 0, then read the
  # order back and REFUSE (hide the strip) rather than ship it floating.
  discard modsSetFirstSibling(stripT)
  var stripAfterN = 0
  if iChildCount(stackT, stripAfterN) and stripAfterN > 0:
    let stripFirstChild = iChildAt(stackT, 0)
    if stripFirstChild != stripT:
      modsNoteFault("SetAsFirstSibling did not stick for the MODS subtab " &
                    "strip -- it is still not sibling 0, so it would still " &
                    "lay out below the page containers. Hiding it rather " &
                    "than shipping it in the wrong place.")
      discard modsSetActive(stripClone, false)
      return

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
  var rowDonorKind = ""
  let rowDonor = swAnyDonor(tabPtr, rowDonorKind)
  let rowDonorT = (if rowDonor != nil: iToTransform(rowDonor) else: nil)
  var r = 0
  var rowsFixed = 0
  var rowsBad = 0
  while r < gModsSubs.len and r < gModsPages.len:
    if gModsSubs[r].pageGo != nil:
      discard swRenderPage(tabPtr, gModsSubs[r].pageGo, gModsPages[r])
      # RE-ASSERT EVERY ROW'S CAPTION ACROSS ALL ITS TMPs.
      #
      # `swCloneRow` labels through `swControlTmp` -- ONE TextMeshProUGUI --
      # which is the same trap as fact #88: the write lands and the row still
      # reads the donor's caption, which is why every row on every page read
      # 'Interface language'. That renderer is shared with the Game-tab pages,
      # so rather than change its behaviour underneath that feature, this
      # re-labels the clones it produced, using the donor-count rule.
      if rowDonorT != nil:
        var q = 0
        while q < gModsPages[r].rows.len and q < cSwMaxRows:
          let ctrl = cast[Il2CppPtr](gModsPages[r].rows[q].clone)
          if ctrl != nil and duOk(ctrl, 0x20'i32):
            var text = gModsPages[r].rows[q].label
            if not gModsPages[r].rows[q].implemented:
              text = text & cSwNotDone
            let rowT = iToTransform(ctrl)
            if rowT != nil:
              if modsRelabelRow(rowT, rowDonorT, text, ctrl):
                rowsFixed = rowsFixed + 1
              else:
                rowsBad = rowsBad + 1
          q = q + 1
    r = r + 1
  okLog "mods tab: re-asserted " & $rowsFixed & " row caption(s) across " &
        "every TextMeshProUGUI they carry (" & $rowsBad & " did not take), " &
        "using the row donor chosen by " & rowDonorKind &
        ". Without this the rows keep the donor's caption -- which is why " &
        "every row on every page read 'Interface language' while the write " &
        "reported success."

  # THE OUTCOME CHECK ON THE CONTAINER, in the same spirit as the caption one:
  # what the player sees in the body must be exactly what we put there -- one
  # subtab strip plus one page container per subtab -- and nothing inherited.
  # THE OUTCOME CHECK, CORRECTED. The previous version expected all five
  # children active and warned on the CORRECT state -- strip plus exactly ONE
  # visible page. Expecting five would mean every page showing at once. A wrong
  # assert is worse than none: it trains us to ignore the warnings that are
  # right.
  #
  # Two separate claims, so a failure says which:
  #   * TOTAL children of ours: strip + one container per subtab;
  #   * ACTIVE children: the strip + exactly one page.
  let totalKids = modsChildCount(stackT)
  let liveKids = modsActiveChildren(stackT)
  let wantTotal = stockN + 1 + gModsSubs.len
  let wantLive = 2
  if liveKids != wantLive:
    warn "mods tab: the page container shows " & $liveKids & " active " &
         "child(ren); it should show exactly " & $wantLive & " -- the subtab " &
         "strip and ONE page. More means several pages are visible at once; " &
         "fewer means the selected page never came on."
  else:
    okLog "mods tab: the body shows exactly the subtab strip and ONE of the " &
          $gModsSubs.len & " page(s), which is the correct steady state"
  if totalKids != wantTotal:
    okLog "mods tab: the page container has " & $totalKids & " child(ren); " &
          $stockN & " inherited (switched off) + 1 strip + " & $gModsSubs.len &
          " page(s) = " & $wantTotal & " was expected. A difference here is " &
          "the game adding or removing something, not a failure by itself."
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

proc modsReassertLabels() =
  ## Put our captions back if LocalizedText has clobbered them.
  ##
  ## This is the same lesson the version brand encodes: a raw store is
  ## re-applied over, and even a setter call can be undone when the game
  ## re-localises a row. So the labels are re-checked -- but on a 60-frame
  ## throttle, capped at ModsMaxTmp entries, and it SWITCHES ITSELF OFF once
  ## ten consecutive checks have found everything intact. Reading a managed
  ## string allocates, which is why this may not run per frame.
  if gModsLabelStable >= ModsStableEnough or gModsLabelTmp.len == 0:
    return
  inc gModsLabelFrames
  if gModsLabelFrames < ModsLabelEveryFrames:
    return
  gModsLabelFrames = 0
  # THE LATE SPAWN. A *ToggleSpawner clone spawns its own toggle on its own
  # schedule, which can be several frames after the build finished, so the
  # build-time reap cannot be the only one. This is idempotent and does nothing
  # once the child counts match the donor's.
  var reaped = 0
  var k = 0
  while k < gModsReapClone.len and k < ModsMaxSubtabs + 1:
    reaped = reaped + modsReapExtraToggles(gModsReapClone[k], gModsReapDonor[k],
                                           gModsReapCaption[k])
    k = k + 1
  var clobbered = 0
  var i = 0
  while i < gModsLabelTmp.len and i < ModsMaxLabels:
    if duOk(gModsLabelTmp[i], cSuiOffTmpMText() + 8'i32):
      if modsTmpText(gModsLabelTmp[i]) != gModsLabelText[i]:
        clobbered = clobbered + 1
        discard swRelabelControl(cast[Il2CppPtr](0), gModsLabelTmp[i],
                                 gModsLabelText[i])
    i = i + 1
  # THE STABILITY GATE MUST NOT TRUST "reaped == 0 this poll" ON ITS OWN: that
  # is also what a poll BEFORE the late spawn looks like, since there is
  # nothing to reap yet. Left alone, the counter can reach ModsStableEnough
  # and switch this whole poll off before the *ToggleSpawner clone has ever
  # spawned its stray child (fact #93/#87) -- which is exactly the bug where
  # ControlsToggleSpawner(Clone) kept a second, unlabelled toggle forever.
  # So "stable" additionally requires every reap target to ALREADY be caught
  # up with its donor's child count, checked fresh every poll.
  var strayRemaining = 0
  var s = 0
  while s < gModsReapClone.len and s < ModsMaxSubtabs + 1:
    let wantS = modsChildCount(gModsReapDonor[s])
    let haveS = modsChildCount(gModsReapClone[s])
    if wantS > 0 and haveS > wantS:
      strayRemaining = strayRemaining + 1
    s = s + 1
  if clobbered == 0 and reaped == 0 and strayRemaining == 0:
    inc gModsLabelStable
    if gModsLabelStable == ModsStableEnough:
      okLog "mods tab: all " & $gModsLabelTmp.len & " label(s) have stayed " &
            "put for " & $ModsStableEnough & " consecutive checks, so the " &
            "re-assert poll has switched itself off for this session"
  else:
    gModsLabelStable = 0

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
  ## Drive the visible page from the subtab toggles.
  ##
  ## TWO WAYS IN, because relying only on a rising edge is relying on never
  ## missing one -- and a missed edge is a body that never changes again, which
  ## is exactly what the player reported:
  ##   1. a RISING edge: the subtab just turned on. Correct whether the clones
  ##      share a ToggleGroup (it turns the others off for us) or not.
  ##   2. a STEADY-STATE disagreement: exactly one subtab reads on and it is
  ##      not the page we are showing. This catches a selection that changed
  ##      without us seeing the transition -- and it is idempotent, because it
  ##      only fires while the two disagree.
  ## Both are guarded byte reads; `modsShowSubtab` is the only thing that calls
  ## anything, and only where something differs.
  var rising = -1
  var onCount = 0
  var onlyOn = -1
  var i = 0
  while i < gModsSubs.len:
    let on = modsToggleIsOn(gModsSubs[i].toggle)
    if on:
      onCount = onCount + 1
      onlyOn = i
      if not gModsSubs[i].lastOn:
        rising = i
    gModsSubs[i].lastOn = on
    i = i + 1
  if rising >= 0 and rising != gModsSel:
    modsShowSubtab(rising)
    return
  if onCount == 1 and onlyOn != gModsSel:
    modsShowSubtab(onlyOn)
    return
  if onCount == 0 and gModsSel >= 0 and gModsSel < gModsSubs.len:
    # Nothing is selected at all -- the group allows switching off, or our
    # clones have no group. Put the current page's own toggle back on rather
    # than leaving the body with no page and no way to choose one.
    discard modsSetToggleQuiet(gModsSubs[gModsSel].toggle, true)
    gModsSubs[gModsSel].lastOn = true

proc modsTabTickBody() =
  modsCrumb("STAGE: entered modsTabTickBody")
  if not gModsOn or gModsFaults >= ModsMaxFaults:
    return
  if not gModsBuilt:
    # Build lazily, once the settings screen has been opened onto the tab whose
    # rows we clone. GATE ON THE SAME POINTER THE BUILD USES: a guard naming a
    # different thing from the code it guards is a silent feature-off switch,
    # and that is how this once shipped doing nothing at all.
    if gModsLastTabPtr != nil and gModsTried < ModsMaxBuildTries:
      modsCrumb("STAGE: lazy modsTabBuild")
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
      # OURS OFF FIRST, THEIRS BACK ON SECOND, and the order is deliberate: the
      # symptom the player reported was BOTH panels drawn at once after leaving
      # MODS. Restoring theirs while ours is still active is exactly that
      # picture, and it is what happens if the hide is skipped or fails.
      if not modsSetActive(gModsPanel, false):
        warn "mods tab: could not switch OUR panel off on the way out of the " &
             "MODS tab, so the stock panel is NOT being restored on top of " &
             "it -- that would draw both at once. The screen keeps showing " &
             "the MODS panel until it can be switched off."
        return
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
  modsCrumb("STAGE: modsReassertLabels")
  modsReassertLabels()                  # throttled, and it stops when stable
  if not gModsShown:
    return
  modsCrumb("STAGE: modsTickSubtabs")
  modsTickSubtabs()

var gModsSanityFrames = 0
const ModsSanityEveryFrames = 30

proc modsPanelSanity() =
  ## THE STANDING OUTCOME CHECK: our panel may be active ONLY while the MODS
  ## toggle is on. Everything above drives that on edges; this verifies the
  ## STATE, on the same throttle as the label re-assert, because an edge that
  ## was missed leaves two panels drawn over each other and nothing would
  ## otherwise notice.
  if not gModsBuilt or gModsPanel == nil or gModsToggle == nil:
    return
  inc gModsSanityFrames
  if gModsSanityFrames < ModsSanityEveryFrames:
    return
  gModsSanityFrames = 0
  if not duOk(gModsPanel, 0x20'i32) or not duOk(gModsToggle, ModsOffIsOn + 4'i32):
    return
  let want = cSwReadU8(gModsToggle, ModsOffIsOn) != 0'i32
  if modsGoActive(gModsPanel) == want:
    return
  if not want:
    if modsSetActive(gModsPanel, false):
      modsRestoreStockPanels()
      gModsShown = false
      warn "mods tab: our panel was still active with the MODS tab NOT " &
           "selected -- both panels would have been drawn at once. Switched " &
           "ours off and restored the stock panel. An edge was missed."
  else:
    gModsShown = false                  # let the edge path show it properly

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
## THE STEADY-STATE cadence, once the label is ours: a cheap re-check for a
## clobber, not a search.
const VerBrandEveryFrames = 120
## THE HUNTING cadence, while the label has not been reached yet. This is the
## whole reason the brand used to appear late: the throttle was 120 frames for
## BOTH phases, and the first attempt was not made until frame 120 either. At
## menu-load framerates 120 frames is not 2 seconds, it is however long 120
## slow frames take -- a frame counter is not a clock, and this one was being
## read as one.
const VerBrandHuntFrames = 2
## The time slice. If one resolve pass costs more than this, the hunt drops
## back to the steady cadence and SAYS SO -- the walk allocates a name string
## per child, and a per-frame unbounded search on this exact rider chain is a
## measured main-thread stall (menuModeText: >=1.08 s/frame for 32 s).
const VerBrandSliceMs = 4'u64
## How long the hunt may go on before it gives up, in WALL CLOCK, not in
## attempts. An attempt budget and a fast poll are incompatible: 40 attempts at
## one every 2 frames is ~1.3 s, which is long before the menu exists. "Not
## reachable yet" is not a failure and must not spend the fault budget.
const VerBrandHuntMs = 300_000'u64
const VerBrandMaxWalkFaults = 40

var gVerTmp: Il2CppPtr = nil
var gVerApplies = 0
var gVerFrames = 0
var gVerSaid = false
## TIMESTAMPS, so "it is late" becomes three numbers instead of an impression.
## All are `cNowMs()` values; `gVerT0` is the first frame the rider chain
## dispatched us, which is itself one of the candidate causes (nothing in this
## file can run before `EFT.UI.PreloaderUI::Update` first fires).
var gVerT0: uint64 = 0
var gVerTResolved: uint64 = 0
var gVerTApplied: uint64 = 0
## Re-applies after the first: a non-zero count here is the CLOBBER signature
## (`LocalizedText` rewriting `m_text` under us), and it is the difference
## between "we were late" and "we were early and overwritten".
var gVerReapplies = 0
## Set when a resolve pass overran the slice; the hunt then runs at the steady
## cadence instead. One-shot log.
var gVerSlow = false
## Passes where the walk legitimately could not reach the label. NOT faults.
var gVerNotReady = 0
var gVerGaveUp = false
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
  ## "aowlspt beta <ver>, aoughwl.com | <tarkov ver>", built from whatever the
  ## game actually wrote.
  ##
  ## The stock label reads e.g. "1.1.0.1.46777 | PvE" (fact #12), so the part
  ## before the pipe is Tarkov's build and the part after is the mode. We keep
  ## the build and DROP the mode: the mode selector is skipped on launch and
  ## its button is hidden, so "| PvE" is a claim about a screen the player
  ## never sees.
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
  result = "aowlspt beta " & VerBrandOurVersion & ", aoughwl.com | " &
           verTrim(tarkov)
  discard verTrim(mode)   # deliberately dropped; see the doc comment above

proc verBrandResolve(): Il2CppPtr =
  ## Walk the fixed path to the label from the live PreloaderUI anchor. Each hop
  ## is checked BY NAME, so a build that moved the label declines loudly instead
  ## of writing into whatever happens to sit at that index.
  result = nil
  # TWO INDEPENDENT ANCHOR SOURCES, ours first. `gVerPreloader` is captured by
  # this feature from its own rider's RCX and from the Awake postfix;
  # `gInspPreloader` is the live inspector's and is only a bonus. Borrowing the
  # inspector's global as the ONLY source is the measured cause of this feature
  # never resolving in a real boot, and it must not come back.
  var anchor = gVerPreloader
  if anchor == nil or not duOk(anchor, 0x20'i32):
    anchor = gInspPreloader
  if anchor == nil or not duOk(anchor, 0x20'i32):
    gVerWhy = "no live PreloaderUI anchor yet (neither this feature's own " &
              "capture from PreloaderUI::Update/Awake RCX, nor the live " &
              "inspector's)"
    return
  let t = iToTransform(anchor)
  if t == nil:
    gVerWhy = "PreloaderUI has no reachable Transform"
    return
  # LOOK DOWN, NOT UP. Measured: `Component::get_transform` on the PreloaderUI
  # gives the SCENE ROOT named "Preloader UI", whose single child is ANOTHER
  # node also named "Preloader UI", and BottomPanel hangs off that one. So the
  # panel is two levels below the component, not beside it and not above it.
  # CLIMB TO THE HIERARCHY ROOT FIRST. The measured path is
  # `Preloader UI/BottomPanel/Content/UpperPart/AlphaLabel` (fact #12), and the
  # component we hold may sit anywhere on that hierarchy. `Transform::get_root`
  # is an ICALL on the object we already verified live -- it does NOT go
  # through `SceneManager`, and that matters: the live UI lives in
  # `DontDestroyOnLoad`, which `sceneCount`/`GetSceneAt` exclude BY DESIGN, so
  # a sibling rider in the same run truthfully reported "iSceneRoots
  # enumerated NO roots (0)". Nothing in this walk may depend on that list.
  var top = iHierRoot(t)
  if top == nil or not duOk(top, 0x20'i32):
    top = t
  # BOUNDED DESCENT for BottomPanel: the root itself, its children, and its
  # grandchildren -- because the root "Preloader UI" has a single child also
  # named "Preloader UI" and the panel hangs off that one. 16 x 16 nodes is the
  # hard ceiling, and the 4 ms slice in `verBrandTickBody` bounds it in time as
  # well. Both bounds, never just one.
  var bottom = modsChildNamed(top, "BottomPanel")
  if bottom == nil:
    var n = 0
    if iChildCount(top, n):
      var i = 0
      while i < n and i < 16 and bottom == nil:
        let c = iChildAt(top, i)
        if c != nil and duOk(c, 0x20'i32):
          bottom = modsChildNamed(c, "BottomPanel")
          if bottom == nil:
            var m = 0
            if iChildCount(c, m):
              var j = 0
              while j < m and j < 16 and bottom == nil:
                let g = iChildAt(c, j)
                if g != nil and duOk(g, 0x20'i32):
                  bottom = modsChildNamed(g, "BottomPanel")
                j = j + 1
        i = i + 1
  if bottom == nil:
    gVerWhy = "no 'BottomPanel' within 2 levels of the PreloaderUI hierarchy " &
              "root (searched at most 16 children x 16 grandchildren; this is " &
              "a BUDGET, so it is not proof the panel is absent)"
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
    let t0 = cNowMs()
    gVerTmp = verBrandResolve()
    let spent = cNowMs() - t0
    if spent > VerBrandSliceMs and not gVerSlow:
      # THE TIME SLICE, reported rather than silently absorbed. The hunt gives
      # up its fast cadence here; it does not give up the hunt.
      gVerSlow = true
      warn "version brand: one label walk cost " & $int(spent) & " ms, over " &
           "the " & $int(VerBrandSliceMs) & " ms slice, so the fast hunt " &
           "(every " & $VerBrandHuntFrames & " frames) has BACKED OFF to " &
           "every " & $VerBrandEveryFrames & " frames. The brand will be " &
           "later, and that is the deliberate trade: this rider runs on the " &
           "Unity main thread."
    if gVerTmp == nil:
      inc gVerNotReady
      if gVerNotReady <= 2:
        okLog "version brand: the label is not reachable yet -- " & gVerWhy &
              ". Retrying; this is normal before the menu is up."
      return
    gVerTResolved = cNowMs()
    okLog "version brand: TIMING -- the AlphaLabel became reachable " &
          $int(gVerTResolved - gVerT0) & " ms after the first " &
          "PreloaderUI::Update tick, on hunt pass " & $(gVerNotReady + 1) &
          ". Nothing this feature does can happen before that moment; it is " &
          "the floor on how early the brand can correctly be."
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
    if gVerSaid:
      # A SECOND APPLY MEANS SOMETHING ELSE WROTE THE LABEL. Reaching this
      # branch is the clobber (fact: `LocalizedText` re-applies over raw
      # stores), and it is reported because "applied at T" plus "clobbered at
      # T+n" is a different bug from "applied late".
      inc gVerReapplies
      if gVerReapplies <= 3:
        warn "version brand: the label was CLOBBERED back to the game's own " &
             "text and has been re-applied (" & $gVerReapplies & " of at " &
             "most " & $(VerBrandMaxApplies - 1) & "), " &
             $int(cNowMs() - gVerTApplied) & " ms after the first apply. If " &
             "this repeats, the brand is not late -- it is being overwritten."
    else:
      gVerSaid = true
      gVerTApplied = cNowMs()
      okLog "version brand: TIMING -- applied " &
            $int(gVerTApplied - gVerT0) & " ms after the first " &
            "PreloaderUI::Update tick, and " &
            $int(gVerTApplied - gVerTResolved) & " ms after the label " &
            "became reachable. The second number is this feature's own " &
            "latency; the first is dominated by the client."
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
## The SeasonsButton GameObject itself, cached so the steady-state check costs
## ONE ICALL and no string compare -- which is what lets it run every frame and
## catch the banner on the FIRST frame it comes back, instead of up to two
## seconds later. Human-reported: "I see the KORD banner for a second before it
## disappears" on the way back from settings. Raising the poll rate would have
## cost that string compare every frame; caching the object costs nothing.
var gSeasonsBtnGo: Il2CppPtr = nil
var gSeasonsFrames = 0
var gSeasonsHidden = 0
var gSeasonsSaid = false
var gSeasonsSaidMissing = false
var gSeasonsFaults = 0

## What the last MenuScreen walk actually saw, so a decline is a sentence and
## not a silence. THIS IS THE BUG THIS BLOCK EXISTS FOR: the feature was armed,
## the flag was true, the rider fired -- and the log contained NOT ONE LINE from
## it after the arm banner. A path that declines without saying why is the worst
## outcome this host produces, and it had one.
var gSeasonsWhy = ""
var gSeasonsPasses = 0
var gSeasonsSaidWalk = false
const SeasonsMaxPasses = 30

proc seasonsFindMenuScreen(): Il2CppPtr =
  ## `MenuScreen`, from the scene roots. The only expensive step, which is why
  ## the result is cached and revalidated rather than re-walked: the root
  ## enumeration allocates, and nothing that allocates may run per frame.
  ##
  ## It looks THREE levels down from each root, not just at direct children:
  ## `Common UI` is a root, but a build that inserts a layer between it and
  ## MenuScreen would otherwise make this fail while reporting nothing.
  result = nil
  var roots: seq[Il2CppPtr] = @[]
  let n = iSceneRoots(roots, false)
  if roots.len == 0:
    gSeasonsWhy = "iSceneRoots enumerated NO roots at all (it returned " & $n &
                  "). That is the scene-root walk failing, not the banner " &
                  "being absent -- it needs the nav targets " &
                  "Scene::GetRootGameObjects / GameObject::get_scene_Injected, " &
                  "which come from the name index; check nameIndex loaded"
    return
  var names = ""
  var i = 0
  while i < roots.len and i < 32:
    let goT = iToTransform(roots[i])
    if goT != nil and duOk(goT, 0x20'i32):
      if names.len < 300:
        names = names & "'" & iObjName(goT) & "' "
      let m = modsFindNamed(goT, "MenuScreen", 3)
      if m != nil:
        gSeasonsWhy = ""
        return m
    i = i + 1
  gSeasonsWhy = "no 'MenuScreen' within 3 levels of any of the " &
                $roots.len & " scene root(s): " & names

proc seasonsTickBody() =
  ## RESOLVES `gSeasonsMenu`, then hides the banner IF `uxHideSeasons` is set.
  ##
  ## The gate is `gSeasonsOn or gBetaNoticeOn` rather than `gSeasonsOn` alone
  ## because the beta notice needs exactly the same MenuScreen and exactly the
  ## same `SeasonsButton`, and the ONLY thing in this host that resolves either
  ## is this proc. Giving the notice its own walk would be a second scene
  ## enumeration on the Unity main thread for an object we already hold -- the
  ## measured mistake that cost 1.08 s/frame. So this resolves, and the hide
  ## below is what is conditional.
  if not (gSeasonsOn or gBetaNoticeOn) or gSeasonsFaults >= SeasonsMaxFaults:
    return
  inc gSeasonsPasses
  # Revalidate the cached MenuScreen before trusting it: a menu rebuild
  # destroys it, and a stale Transform is a fault waiting for the next ICALL.
  if gSeasonsMenu != nil and
     (not duOk(gSeasonsMenu, 0x20'i32) or not iUnityAlive(gSeasonsMenu)):
    gSeasonsMenu = nil
  if gSeasonsMenu == nil:
    gSeasonsMenu = seasonsFindMenuScreen()
    if gSeasonsMenu == nil:
      # SAY IT. Once early, so "armed and doing nothing" is never again
      # indistinguishable from "armed and working", and once more when it gives
      # up. Before the main menu exists this is simply the truth.
      if gSeasonsPasses == 2 and not gSeasonsSaidWalk:
        gSeasonsSaidWalk = true
        okLog "hide seasons: nothing hidden yet -- " & gSeasonsWhy &
              ". This is expected before the main menu is up; it keeps " &
              "looking on a " & $SeasonsEveryFrames & "-frame throttle."
      elif gSeasonsPasses >= SeasonsMaxPasses:
        gSeasonsOn = false
        # The beta notice hangs off this same resolve, so it dies here too --
        # loudly, in its own words, rather than ticking forever against a
        # MenuScreen that is never coming.
        if gBetaNoticeOn:
          gBetaNoticeOn = false
          warn "beta notice: GIVING UP with hide seasons after " &
               $gSeasonsPasses & " passes -- " & gSeasonsWhy & ". No " &
               "MenuScreen was ever reached, so the banner was never even " &
               "looked at. NOTHING was written and NOTHING was hidden; the " &
               "banner is exactly as the game made it, and this feature is " &
               "OFF for the session."
        warn "hide seasons: GIVING UP after " & $gSeasonsPasses &
             " passes -- " & gSeasonsWhy & ". The KORD BREACH / Season " &
             "banner is left exactly as the game made it, and this feature " &
             "is OFF for the session. It is announcing this rather than " &
             "continuing to do nothing quietly."
      return
    okLog "hide seasons: found MenuScreen; looking for its 'SeasonsButton' " &
          "child on every pass from here"
  # FROM HERE DOWN IS THE HIDE, AND ONLY THE HIDE. With `uxBetaNotice` on,
  # `uxHideSeasons` has already been forced off in `aowlhost.nim` (they target
  # one object from opposite directions), so this returns with `gSeasonsMenu`
  # resolved and `betaNoticeFrom` -- called from the same branch, under the
  # same single guard -- does the rest.
  if not gSeasonsOn:
    return
  # THE FAST PATH, taken every frame once the button is known: validate the
  # cached GameObject without allocating, ask `activeSelf`, and hide it the
  # frame it comes back. `modsChildNamed` compares NAMES, and reading a managed
  # name allocates, so that walk stays on the throttle below.
  if gSeasonsBtnGo != nil:
    if duOk(gSeasonsBtnGo, 0x20'i32) and iUnityAlive(gSeasonsBtnGo):
      if modsGoActive(gSeasonsBtnGo):
        if modsSetActive(gSeasonsBtnGo, false):
          inc gSeasonsHidden
          if gSeasonsHidden == 2:
            okLog "hide seasons: the banner came back after a menu rebuild " &
                  "and was hidden again on the FIRST frame it did, from the " &
                  "cached object -- not on the next throttled pass"
      return
    gSeasonsBtnGo = nil                 # destroyed; fall through and re-resolve
  # BY NAME, on the throttled pass. The button is re-resolved rather than
  # trusted, so a rebuilt banner is found again and a destroyed one is not.
  let btn = modsChildNamed(gSeasonsMenu, "SeasonsButton")
  if btn == nil:
    if not gSeasonsSaidMissing:
      gSeasonsSaidMissing = true
      okLog "hide seasons: MenuScreen was reached but has NO child named " &
            "'SeasonsButton' on this build. NOTHING was hidden -- there is " &
            "deliberately no positional fallback, because hiding whatever " &
            "happens to sit there is how the Play button disappears after a " &
            "patch."
    return
  let go = iGameObjectOf(btn)
  if go == nil or not iUnityAlive(go):
    return
  gSeasonsBtnGo = go                    # from here the fast path owns it
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
  else:
    warn "hide seasons: GameObject::SetActive(false) REFUSED on " &
         "SeasonsButton (the target verified, the call did not run). The " &
         "banner is untouched."

# ---------------------------------------------------------------------------
# THE BOTTOM-RIGHT MODE BUTTON (`uxHideModeButton`), hidden from HERE.
#
# It lives at `Common UI/MenuScreen/ChangeGameModeButton` -- a DIRECT SIBLING
# of SeasonsButton. MEASURED on the live client: `find ChangeGameModeButton`
# over all 16 scene roots returns exactly one hit, `parent="MenuScreen"`.
#
# **fact #116 says `Common UI/ChangeGameModeButton` and that path DOES NOT
# EXIST.** Being wrong by that one level cost four separate implementation
# rounds in `modetext.nim`, each of which searched the wrong depth, correctly
# reported "not found", and was believed. One of those rounds also drove the
# shared scene-root enumerator ~340 times during a warm-up and took THIS
# feature down with it -- hide seasons went silent and the host log dropped
# from 4,248 lines to 262.
#
# So it is done here instead, and it does no searching at all: `gSeasonsMenu`
# is already resolved and cached above, and this is one more `modsChildNamed`
# on an object we are already holding. No scene enumeration, no anchor
# dependency, no budget, nothing to back off from. If hide seasons can reach
# MenuScreen -- and it demonstrably can, every run -- so can this.
#
# There is deliberately NO positional fallback, for the same reason the
# seasons block gives: hiding whatever happens to sit there is how the Play
# button disappears after a patch.
var gModeBtnGo: Il2CppPtr = nil
var gModeBtnSaid = false
var gModeBtnSaidMissing = false
var gModeBtnHidden = 0

proc modeButtonHideFrom(menu: Il2CppPtr) =
  ## Hide the mode button, given the MenuScreen hide-seasons just resolved.
  if not gModeHideOn or menu == nil:
    return
  # Fast path: we already own the GameObject and it is still alive.
  if gModeBtnGo != nil:
    if duOk(gModeBtnGo, 0x20'i32) and iUnityAlive(gModeBtnGo):
      if modsGoActive(gModeBtnGo):
        if modsSetActive(gModeBtnGo, false):
          inc gModeBtnHidden
          okLog "hide mode button: the button came back after a menu " &
                "rebuild and was switched off again (" & $gModeBtnHidden &
                " time(s)) from the cached object."
      return
    gModeBtnGo = nil                    # destroyed; fall through and re-resolve
  let btn = modsChildNamed(menu, "ChangeGameModeButton")
  if btn == nil:
    if not gModeBtnSaidMissing:
      gModeBtnSaidMissing = true
      okLog "hide mode button: MenuScreen was reached, so the menu exists, " &
            "but it has NO child named 'ChangeGameModeButton'. NOTHING was " &
            "hidden. This is a REAL ABSENCE at this level -- MenuScreen was " &
            "held, not searched for -- so the name has changed, and there " &
            "is deliberately no positional fallback."
    return
  let go = iGameObjectOf(btn)
  if go == nil or not iUnityAlive(go):
    return
  gModeBtnGo = go
  if not modsGoActive(go):
    return                              # already hidden: a read, and no call
  if modsSetActive(go, false):
    inc gModeBtnHidden
    if not gModeBtnSaid:
      gModeBtnSaid = true
      okLog "hide mode button: Common UI/MenuScreen/ChangeGameModeButton " &
            "switched off (the bottom-right PVE ZONE / switch-game-mode " &
            "control). Reached as one named child of the SAME MenuScreen " &
            "hide-seasons resolves -- no scene walk, no budget. It is " &
            "re-checked on the same throttle, so a menu rebuild hides it " &
            "again; it is never re-enabled by this host."
  else:
    warn "hide mode button: GameObject::SetActive(false) REFUSED on " &
         "ChangeGameModeButton (the target verified, the call did not run). " &
         "The button is untouched."

# ---------------------------------------------------------------------------
# THE BETA NOTICE IN THE SEASONS BANNER SLOT (`uxBetaNotice`, default OFF).
#
# REPURPOSE, NOT REPLACE, and the trade is worth stating plainly.
#
# Replacing would mean drawing our own panel. Native Unity UI construction is
# ruled out on this project -- days were lost to it on the settings screen --
# and the surviving alternative, a cheap overlay, lives on a DIFFERENT SURFACE:
# it is drawn over the client rather than laid out by it, it is owned by
# another file, and it would not sit in the banner slot the user actually
# pointed at. Repurposing costs us BSG's prefab and BSG's child structure --
# which is the real cost, since we do not get to choose which TextMeshProUGUI
# is the big one -- but it buys the game's own position, font, and layout for
# free, on an object THIS FILE ALREADY HOLDS AND REVALIDATES EVERY RUN.
#
# So: no scene walk, no anchor hunt, no budget. `seasonsTickBody` above has
# already resolved `MenuScreen`; this is one `modsChildNamed` on it.
#
# WHAT IT DOES NOT ASSUME. It does not hardcode a path inside the banner. The
# season prefab's internals have never been measured on this build, and fact
# #116 was WRONG BY ONE LEVEL about a node in this exact subtree, costing four
# implementation rounds -- so a recorded path here would be a guess wearing a
# measurement's clothes. Instead it enumerates the banner's own descendants,
# bounded to `BetaNoticeMaxNodes` nodes and `BetaNoticeMaxDepth` levels, and
# keeps every TextMeshProUGUI whose `m_text` is NON-EMPTY.
#
# THE NON-EMPTY TEST IS THE ASSERTION, and it is the same one the version
# brand makes: an empty `m_text` is the FINGERPRINT OF THE WRONG OBJECT (fact
# #13 -- exactly what the old `$verlabel` target reads, and exactly why that
# feature looked armed for months and changed nothing). A node that renders
# nothing today will render nothing tomorrow.
#
# THE FAILURE MODE IS DECIDED IN ADVANCE: if that enumeration finds ZERO
# non-empty labels, or if no setter takes, this writes NOTHING, says so once
# in full, switches the banner OFF, and disables itself. Half a notice -- our
# headline over BSG's subtitle, or "AOWLSPT BETA" alone under a season
# artwork -- is strictly worse than the banner simply being gone, which is the
# behaviour the player already has today.
#
# TEXT IS WRITTEN BY CALLING THE SETTERS, never by storing `m_text`: a raw
# store reads back true and is then clobbered by `LocalizedText`. This goes
# through `swRelabelControl` -- SetLabelText @0x140FE70 then set_text
# @0x51BC1E0 plus the repaint latch -- the SAME writer the version brand and
# the settings rows use. There is deliberately no second text-writer in this
# host.
#
# ALLOCATION: the strings are `const`, composed at compile time, and
# `swRelabelControl` allocates one managed String per label per APPLY. Applies
# are capped at `BetaNoticeMaxApplies`. The steady state is one pointer
# validation and ONE `m_text` read on the first label -- no allocation, no
# walk -- on the throttle `seasonsTick` already owns.
#
# THE SLOT ORDER IS A KNOWN UNCERTAINTY AND IS REPORTED AS ONE. Labels are
# taken in breadth-first order and slot 0 gets the headline, slot 1 the
# sub-line, the rest are blanked. Which of the banner's labels is visually the
# title has NOT been measured. So the apply log prints the STOCK text each slot
# carried before we wrote it: if the mapping is inverted, that one line says so
# and the fix is to swap two constants.
# ---------------------------------------------------------------------------

## FALSE until a MEASURED tree of `SeasonsButton` says which child is the
## headline, which is a sub-line, and which are the battlepass progress
## widgets to switch off. While it is false the feature publishes its census
## and declines. See the slot gate in `betaNoticeFrom` for what measuring it
## costs and why guessing is not allowed.
const BetaNoticeSlotsVerified = false
const BetaNoticeMaxNodes = 64
const BetaNoticeMaxDepth = 4
const BetaNoticeMaxChildren = 32
## Applies, not passes. A clobber costs one; eight is enough to win an argument
## with `LocalizedText` and few enough that a label which fights back forever
## cannot spin.
const BetaNoticeMaxApplies = 8
## What tells us the banner is ALREADY OURS, read back off the live label. Not
## a flag of our own -- a flag would say "we wrote it", and what we need to
## know is "it still says it".
const BetaNoticeSentinel = "AOWLSPT"
const BetaNoticeHead = "AOWLSPT BETA"
const BetaNoticeSub = "aoughwl.com  -  F12 for mod settings"
## Used when the banner turns out to have exactly ONE label: everything on one
## line rather than dropping half the message.
const BetaNoticeOneLine =
  "AOWLSPT BETA  -  aoughwl.com  -  F12 for mod settings"
## `swRelabelControl` REFUSES an empty string (`text.len == 0` returns false),
## so a surplus label is blanked with a space rather than "".
const BetaNoticeBlank = " "

var gBetaBtnT: Il2CppPtr = nil          ## the SeasonsButton transform
var gBetaTmps: seq[Il2CppPtr] = @[]     ## its non-empty TextMeshProUGUIs
var gBetaApplies = 0
var gBetaReapplies = 0
var gBetaSaid = false
var gBetaSaidMissing = false
var gBetaOff = false                    ## declined; never try again this run

proc betaCollectTexts(root: Il2CppPtr): seq[Il2CppPtr] =
  ## Every TextMeshProUGUI at or under `root` whose `m_text` is NON-EMPTY, in
  ## breadth-first order. Bounded twice over -- by node count and by depth --
  ## and every hop validated, because a corrupt `childCount` inside a frame is
  ## an infinite loop on the Unity main thread.
  result = @[]
  if root == nil:
    return
  var qT: seq[Il2CppPtr] = @[]
  var qD: seq[int] = @[]
  qT.add root
  qD.add 0
  var head = 0
  while head < qT.len and head < BetaNoticeMaxNodes:
    let t = qT[head]
    let d = qD[head]
    head = head + 1
    if t == nil or not duOk(t, 0x20'i32) or not iUnityAlive(t):
      continue
    let tmp = modsComponent(t, "TextMeshProUGUI")
    if tmp != nil and duOk(tmp, 0xE8'i32):
      if suiReadString(cReadPtrAt(tmp, 0xE0'i32)).len > 0:
        result.add tmp
    if d < BetaNoticeMaxDepth:
      var n = 0
      if iChildCount(t, n):
        var i = 0
        while i < n and i < BetaNoticeMaxChildren and
              qT.len < BetaNoticeMaxNodes:
          let c = iChildAt(t, i)
          if c != nil:
            qT.add c
            qD.add (d + 1)
          i = i + 1

proc betaNoticeDecline(go: Il2CppPtr; why: string) =
  ## The loud refusal. NOTHING is written, the banner is switched OFF so the
  ## player gets the `uxHideSeasons` outcome rather than a half-branded season
  ## advert, and the feature is done for the session.
  gBetaOff = true
  gBetaNoticeOn = false
  let hid = (go != nil and modsSetActive(go, false))
  warn "beta notice: REFUSING to write -- " & why & ". Nothing was written " &
       "to any label. The banner has " &
       (if hid: "been SWITCHED OFF instead"
        else: "NOT been switched off either (SetActive(false) did not run), " &
              "so it still shows the game's own season caption") &
       ", and uxBetaNotice is OFF for this session. This is deliberate: a " &
       "partly-written banner -- our headline over BSG's subtitle -- is " &
       "worse than no banner at all."

proc betaNoticeFrom(menu: Il2CppPtr) =
  ## Brand the seasons banner, given the MenuScreen hide-seasons just resolved.
  ## Rides `gModsBranch == 3` -- the SAME single `aowl_p_p_seh` -- and adds no
  ## guard of its own, because that guard is not re-entrant and a nested one
  ## would DISARM it.
  if not gBetaNoticeOn or gBetaOff or menu == nil:
    return
  if gBetaApplies >= BetaNoticeMaxApplies:
    return
  # Revalidate the cached banner: a menu rebuild destroys it, and a stale
  # Transform is a fault waiting for the next ICALL.
  if gBetaBtnT != nil and
     (not duOk(gBetaBtnT, 0x20'i32) or not iUnityAlive(gBetaBtnT)):
    gBetaBtnT = nil
    gBetaTmps = @[]
  if gBetaBtnT == nil:
    let btn = modsChildNamed(menu, "SeasonsButton")
    if btn == nil:
      if not gBetaSaidMissing:
        gBetaSaidMissing = true
        warn "beta notice: MenuScreen was reached, so the menu exists, but " &
             "it has NO child named 'SeasonsButton'. NOTHING was written. " &
             "This is a REAL ABSENCE at this level -- MenuScreen was held, " &
             "not searched for -- so the name has changed on this build, and " &
             "there is deliberately no positional fallback: branding " &
             "whatever happens to sit there is how the Play button ends up " &
             "reading 'AOWLSPT BETA'."
      return
    gBetaBtnT = btn
    gBetaTmps = @[]
  let go = iGameObjectOf(gBetaBtnT)
  if go == nil or not iUnityAlive(go):
    return
  # THE ENUMERATION, once per resolve -- not per frame. `m_text` is readable
  # whether or not the object is active, so this runs BEFORE anything is made
  # visible: we do not put the banner on screen until we know we can brand it.
  if gBetaTmps.len == 0:
    gBetaTmps = betaCollectTexts(gBetaBtnT)
  if gBetaTmps.len == 0:
    betaNoticeDecline(go, "the banner was found and walked (" &
                      $BetaNoticeMaxNodes & " nodes, " & $BetaNoticeMaxDepth &
                      " levels max) but NOT ONE TextMeshProUGUI under it has " &
                      "non-empty m_text. An empty label is the fingerprint of " &
                      "the wrong object (fact #13), so there is nothing here " &
                      "this host is willing to write to")
    return
  # THE STEADY STATE: one read. If the first label still carries our sentinel,
  # the notice is intact and this pass costs nothing more.
  let cur0 = suiReadString(cReadPtrAt(gBetaTmps[0], 0xE0'i32))
  if cur0.len == 0:
    gBetaTmps = @[]                     # label died under us; re-enumerate
    return
  if gBetaApplies > 0 and cur0.startsWith(BetaNoticeSentinel):
    return
  # ---- THE SLOT GATE. MEASURED 2026-08-26, ON SCREEN, AND IT LOOKED BAD. ----
  #
  # The bring-up behaviour was "write every non-empty label", which succeeded
  # completely -- `6 of 6 non-empty labels written` -- and rendered wrong. That
  # is the §9b shape exactly: a true report of our own write, next to a screen
  # the user described as "it sucks".
  #
  # WHAT THE CENSUS BELOW ACTUALLY TOLD US, live:
  #   slot 0 [Battlepass]  slot 1 [SeasonWidget/Progress]  slot 2 [12 / 40]
  # These are BATTLEPASS PROGRESS-WIDGET labels. They sit to the RIGHT of the
  # logo, which is where our text appeared.
  #
  # AND THE HEADLINE IS NOT A LABEL AT ALL. "KORD BREACH / SEASON 1" survived
  # untouched through a write to all six TMPs, so it is an IMAGE. No text
  # writer can remove it. The non-empty-`m_text` heuristic did not fail here --
  # it correctly reported that the headline is not text.
  #
  # So this feature CANNOT reach its target by writing labels, and the honest
  # state is that we do not yet know which nodes to drive. Until a measured
  # slot mapping exists, it REFUSES: it publishes the census -- the one thing
  # here with evidential value -- switches the banner off, and disables itself.
  # That leaves the player with the `uxHideSeasons` outcome, which is known
  # good, rather than our caption beside a battlepass progress bar.
  #
  # Flipping `BetaNoticeSlotsVerified` without a measured tree of SeasonsButton
  # re-ships the screenshot the user rejected.
  if not BetaNoticeSlotsVerified:
    var census = ""
    var k = 0
    while k < gBetaTmps.len and k < BetaNoticeMaxNodes:
      census = census & "[" &
               suiReadString(cReadPtrAt(gBetaTmps[k], 0xE0'i32)) & "] "
      k = k + 1
    okLog "beta notice: CENSUS of the " & $gBetaTmps.len & " non-empty " &
          "label(s) under SeasonsButton, in breadth-first slot order: " &
          census & "-- published because this is the measurement the " &
          "feature needs and cannot get any other way."
    betaNoticeDecline(go, "there is NO VERIFIED SLOT MAPPING for this " &
                      "banner yet. Writing every label was the bring-up " &
                      "step, and it landed on battlepass progress labels " &
                      "beside the logo. The 'KORD BREACH / SEASON 1' " &
                      "headline is an IMAGE -- it survived a write to every " &
                      "TMP here -- so no text writer can replace it. " &
                      "Refusing rather than re-shipping a banner that reads " &
                      "correctly in the log and badly on screen")
    return
  var stock = ""
  var wrote = 0
  var i = 0
  while i < gBetaTmps.len and i < BetaNoticeMaxNodes:
    let want = (if gBetaTmps.len == 1: BetaNoticeOneLine
                elif i == 0: BetaNoticeHead
                elif i == 1: BetaNoticeSub
                else: BetaNoticeBlank)
    if i < 3:
      stock = stock & "[" &
              suiReadString(cReadPtrAt(gBetaTmps[i], 0xE0'i32)) & "] "
    if swRelabelControl(cast[Il2CppPtr](0), gBetaTmps[i], want):
      wrote = wrote + 1
    i = i + 1
  if wrote == 0:
    betaNoticeDecline(go, "the banner has " & $gBetaTmps.len & " non-empty " &
                      "label(s), but NOT ONE of them accepted a write -- " &
                      "neither LocalizedText::SetLabelText nor " &
                      "TMP_Text::set_text nor the raw m_text fallback took")
    return
  inc gBetaApplies
  # ONLY NOW is it made visible. Ordering is the whole failure design: every
  # path that could decline has already run.
  if not modsGoActive(go):
    discard modsSetActive(go, true)
  if gBetaSaid:
    # A SECOND APPLY MEANS SOMETHING ELSE WROTE THESE LABELS -- the clobber
    # (`LocalizedText` re-applying over our text), or a menu rebuild. Either
    # way it is a different event from "applied late" and is named as one.
    inc gBetaReapplies
    if gBetaReapplies <= 3:
      warn "beta notice: the banner was CLOBBERED back to the game's own " &
           "text and has been re-applied (" & $gBetaReapplies & " of at " &
           "most " & $(BetaNoticeMaxApplies - 1) & "). If this repeats, the " &
           "notice is not late -- it is being overwritten."
  else:
    gBetaSaid = true
    okLog "beta notice: Common UI/MenuScreen/SeasonsButton now reads \"" &
          (if gBetaTmps.len == 1: BetaNoticeOneLine
           else: BetaNoticeHead & "\" / \"" & BetaNoticeSub) &
          "\" -- " & $wrote & " of " & $gBetaTmps.len & " non-empty labels " &
          "written through LocalizedText::SetLabelText / TMP_Text::set_text " &
          "(never a raw m_text store, which LocalizedText clobbers)."
    okLog "beta notice: the STOCK text each slot carried before we wrote it, " &
          "in slot order, was " & stock & "-- if the headline and the " &
          "sub-line look swapped on screen, THIS LINE IS WHY: the banner's " &
          "internal layout was never measured, slots are taken " &
          "breadth-first, and the fix is to swap BetaNoticeHead and " &
          "BetaNoticeSub."

# ---------------------------------------------------------------------------
# POSTFX AS A SUBTAB OF GRAPHICS (`settingsPostFxSubtab`, default OFF).
#
# The top row loses POSTFX and the Graphics panel gains a two-button strip:
# GRAPHICS SETTINGS | POSTFX. Four tabs above, two subtabs inside.
#
# THIS ONE IS DIFFERENT IN KIND FROM EVERYTHING ELSE IN THIS FILE, AND IS
# TREATED THAT WAY. Everything above only ever writes to clones we made. This
# drives the GAME'S OWN panels and hides one of the GAME'S OWN tab buttons, so
# it takes the seasons feature's discipline rather than the clone discipline:
#
#   * `PostFxToggleSpawner` is only ever SetActive(false) -- never destroyed,
#     never re-parented, never written to. Nothing here persists, so a session
#     started with the flag off has the stock POSTFX tab back.
#   * It is hidden LAST, after both strips exist and both stock panels have
#     been located. A build that fails half way therefore leaves the stock tab
#     exactly where it was; the player never loses POSTFX because our walk
#     broke.
#   * If the feature turns itself off after faults, the spawner is put back.
#   * Neither panel is cloned. This re-parents CONTROL, not content: the two
#     stock panels are switched between, which is precisely what the game will
#     not do for us, because it switches panels by `ESettingsGroup` and our
#     subtab is not one.
#
# THE STRIP HAS TO EXIST TWICE, and that is a consequence, not a choice: it
# lives inside the panel it switches, so a single strip would vanish with the
# panel that carried it. So there is one in each, and whichever is on screen
# drives both. They are kept in agreement on every switch.
# ---------------------------------------------------------------------------

const GfxMaxFaults = 4
const GfxMaxBuildTries = 8

var gGfxBuilt = false
var gGfxTried = 0
var gGfxFaults = 0
## The two STOCK panels, and the stock tab button we hide. Every one of these
## is an object the GAME made: they are read, and switched active, and nothing
## else is ever done to them.
var gGfxPanelGo: Il2CppPtr = nil
var gGfxPostGo: Il2CppPtr = nil
var gGfxSpawnerGo: Il2CppPtr = nil
## Our two strips' toggles: index 0 = GRAPHICS SETTINGS, 1 = POSTFX, one pair
## per strip. Clones we made, so these are ours to write.
var gGfxTogA: seq[Il2CppPtr] = @[]
var gGfxTogB: seq[Il2CppPtr] = @[]
var gGfxLast: seq[bool] = @[]
## Which subtab is showing: 0 = graphics, 1 = postfx.
var gGfxSel = 0
var gGfxSaid = false
var gGfxBothActiveSaid = false

proc gfxNoteFault(what: string) =
  inc gGfxFaults
  warn "postfx subtab: " & what & " (fault " & $gGfxFaults & " of " &
       $GfxMaxFaults & ")"
  if gGfxFaults >= GfxMaxFaults:
    gGfxOn = false
    # PUT THE STOCK TAB BACK. A feature that disables itself must not leave the
    # player without POSTFX at all -- that would be strictly worse than never
    # having run.
    if gGfxSpawnerGo != nil and modsSetActive(gGfxSpawnerGo, true):
      warn "postfx subtab: fault ceiling reached; the feature is OFF for this " &
           "session and the STOCK POSTFX TAB HAS BEEN PUT BACK in the top row."
    else:
      warn "postfx subtab: fault ceiling reached; the feature is OFF for this " &
           "session. The stock POSTFX tab could NOT be restored -- open " &
           "another tab and back, or restart, to get it."

proc gfxContentContainerT(panelT: Il2CppPtr; why: var string): Il2CppPtr =
  ## The panel's own content container, found BY STRUCTURE rather than by a
  ## name borrowed from a different panel. Every stock panel under
  ## SettingsScreen uses its own name for this child ("Container",
  ## "Other Settings", "Panel", "Toggles" -- measured across all five stock
  ## panels), so no single literal name is safe to hardcode. What every one of
  ## them DOES share is an "Overlay Layer" child (holding a SettingsTooltip)
  ## that is never the content: skip that, skip anything named like a
  ## tooltip, and if exactly one direct child remains, that is the container.
  ##
  ## (No `strutils` needed here -- the one non-"Overlay Layer" name that is
  ## not content on any measured panel is the literal "SettingsTooltip".)
  ## Verified against the measured tree of all five panels: Game Settings
  ## (Container / Overlay Layer), Graphics Settings (Other Settings /
  ## Overlay Layer), PostFX Settings (Panel / Overlay Layer), Sound Settings
  ## (Panel / SettingsTooltip) all resolve to exactly one candidate. Control
  ## Settings (Toggles / Content / Overlay Layer) does NOT -- two candidates
  ## remain -- so this REFUSES rather than guessing there; that panel is not
  ## one this feature needs a container from.
  result = nil
  why = ""
  if panelT == nil or not duOk(panelT, 0x20'i32):
    why = "the panel transform itself is not readable"
    return
  var n = 0
  if not iChildCount(panelT, n):
    why = "child count of " & iObjName(panelT) & " could not be read"
    return
  var candidate: Il2CppPtr = nil
  var candidates = 0
  var i = 0
  while i < n and i < 16:
    let c = iChildAt(panelT, i)
    if c != nil and duOk(c, 0x20'i32):
      let nm = iObjName(c)
      if nm != "Overlay Layer" and nm != "SettingsTooltip":
        candidates = candidates + 1
        candidate = c
    i = i + 1
  if candidates != 1:
    why = iObjName(panelT) & " has " & $candidates & " non-overlay child(ren) " &
          "(expected exactly 1); refusing to guess which one is the content " &
          "container"
    return
  result = candidate

proc gfxBuildStrip(panelT, donorStripGo, donorButtonGo, donorButtonT: Il2CppPtr;
                   into: var seq[Il2CppPtr]; stripGoOut: var Il2CppPtr): bool =
  ## One strip of two buttons inside one stock panel. The strip and the buttons
  ## are CLONES; the panel they go into is the game's, and the only thing done
  ## to it is `SetParentAndAlign` of an object of ours.
  result = false
  into = @[]
  stripGoOut = nil
  var why = ""
  let stackT = gfxContentContainerT(panelT, why)
  if stackT == nil:
    warn "postfx subtab: no content container inside the stock panel " &
         iObjName(panelT) & " (" & why & "), so there is nowhere to put the " &
         "subtab strip that the stock layout group would lay out. Nothing " &
         "was added to that panel."
    return
  let stackGo = iGameObjectOf(stackT)
  if stackGo == nil:
    return
  let strip = modsClone(donorStripGo)
  if strip == nil or not modsSetParent(strip, stackGo):
    warn "postfx subtab: the subtab strip could not be cloned into " &
         iObjName(panelT) & "; nothing was added to that panel."
    return
  let stripT = modsTransformOf(strip)
  # The donor strip's own buttons came along with the clone: switch them off,
  # exactly as the MODS strip does.
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
  let stripGo = iGameObjectOf(stripT)
  if stripGo == nil:
    return
  var made = 0
  var i = 0
  while i < 2:
    let caption = (if i == 0: "GRAPHICS SETTINGS" else: "POSTFX")
    let btn = modsClone(donorButtonGo)
    if btn == nil or not modsSetParent(btn, stripGo):
      warn "postfx subtab: could not clone the " & caption & " button"
      i = i + 1
      continue
    let btnT = modsTransformOf(btn)
    if not modsRelabelLike(btnT, donorButtonT, caption):
      warn "postfx subtab: the caption " & caption & " did not fully take; " &
           "that button reads wrong or blank on screen"
    discard modsReapExtraToggles(btnT, donorButtonT, caption)
    let tog = modsToggleOf(btnT)
    modsDescribeToggle("postfx strip button " & caption, tog)
    if tog == nil:
      warn "postfx subtab: the " & caption & " clone has no Toggle, so it " &
           "could never be read"
      discard modsSetActive(btn, false)
      i = i + 1
      continue
    discard modsSetActive(btn, true)
    into.add tog
    made = made + 1
    i = i + 1
  discard modsSetActive(strip, true)
  if made != 2:
    warn "postfx subtab: only " & $made & " of 2 buttons came out usable in " &
         iObjName(panelT) & "; REFUSING to hide the stock POSTFX tab, because " &
         "a half-built strip with no way back is worse than no feature."
    return
  # DOCK AT THE TOP, NOT THE BOTTOM. The panel's own layout group lays out
  # children in sibling order, and `modsSetParent` always appends -- so the
  # strip landed AFTER the tall scrolling settings list and read as floating
  # in the middle of the panel instead of docked by the tabs. Move it to
  # sibling index 0, then read the order back and REFUSE (hide the strip,
  # same as any other build failure here) rather than ship it in the wrong
  # place if that did not stick.
  discard modsSetFirstSibling(stripT)
  var afterN = 0
  if iChildCount(stackT, afterN) and afterN > 0:
    let firstChild = iChildAt(stackT, 0)
    if firstChild != stripT:
      warn "postfx subtab: SetAsFirstSibling did not stick in " &
           iObjName(panelT) & " -- the strip is still not sibling 0, so it " &
           "would still lay out below the settings list. Hiding it rather " &
           "than shipping it in the wrong place."
      discard modsSetActive(strip, false)
      return
  # SIZE TO CONTENT, NOT TO THE DONOR. `donorStripGo` is `Control Settings/
  # Toggles`, a VerticalLayoutGroup sized (via its own `LayoutElement`, if it
  # carries one) to hold that panel's WHOLE checkbox list -- a size the clone
  # inherits VERBATIM, because a `LayoutElement`'s min/preferred/flexible
  # fields are ordinary serialized floats that Instantiate does not
  # recompute. Left alone, that reserves the donor's full height inside a
  # two-button strip and reads as "the settings start half way down the
  # panel". MEASURED, not guessed: read first, and only reset a field that is
  # actually a positive constraint (Unity's "unset" sentinel is negative).
  let stripLe = modsComponent(stripT, "LayoutElement")
  if stripLe != nil and duOk(stripLe, ModsOffLeFlexibleHeight + 4'i32):
    var reset = 0
    let minH = cReadF32At(duPtrAdd(stripLe, ModsOffLeMinHeight))
    let prefH = cReadF32At(duPtrAdd(stripLe, ModsOffLePreferredHeight))
    let flexH = cReadF32At(duPtrAdd(stripLe, ModsOffLeFlexibleHeight))
    if minH >= 0.0:
      discard cDuWriteF32(stripLe, ModsOffLeMinHeight, -1.0)
      reset = reset + 1
    if prefH >= 0.0:
      discard cDuWriteF32(stripLe, ModsOffLePreferredHeight, -1.0)
      reset = reset + 1
    if flexH > 0.0:
      discard cDuWriteF32(stripLe, ModsOffLeFlexibleHeight, 0.0)
      reset = reset + 1
    if reset > 0:
      okLog "postfx subtab: " & iObjName(panelT) & "'s strip inherited a " &
            "LayoutElement sized for the donor's full checkbox list (min=" &
            $minH & " preferred=" & $prefH & " flexible=" & $flexH &
            "); reset " & $reset & " field(s) to Unity's unset sentinel so " &
            "the panel's layout group sizes it to its own two buttons."
  # THE GROUP QUESTION, MEASURED PER STRIP (the two buttons made just above),
  # exactly the check `modsBuildSubtabs` uses -- same donor, same question.
  # MEASURED (fact #117): both buttons came out with m_Group=0 -- unlike the
  # MODS strip, the buttons here are cloned SEPARATELY from the strip
  # (`modsClone(donorButtonGo)`, not part of the strip's own Instantiate), so
  # Unity has no cloned hierarchy to remap an external reference onto and the
  # field is left null. The technique `modsBuildSubtabs` uses is passive (it
  # only NULLS a clone that inherited the STOCK group); there is nothing to
  # null here. So: if the strip clone itself carries a ToggleGroup component
  # (the donor "Toggles" object is the group owner, and that identity comes
  # along with the strip's own Instantiate), WRITE both buttons' m_Group onto
  # it -- read-validate-write, on a clone we made, never on a stock object.
  var groupWired = false
  let stripGroup = modsComponent(stripT, "ToggleGroup")
  if stripGroup != nil and into.len == 2 and
     duOk(into[0], ModsOffGroup + 8'i32) and duOk(into[1], ModsOffGroup + 8'i32):
    let g0 = cReadPtrAt(into[0], ModsOffGroup)
    let g1 = cReadPtrAt(into[1], ModsOffGroup)
    if g0 == nil and g1 == nil:
      discard cUxWritePtr(into[0], ModsOffGroup, stripGroup)
      discard cUxWritePtr(into[1], ModsOffGroup, stripGroup)
      groupWired = true
      okLog "postfx subtab: " & iObjName(panelT) & "'s strip toggle group " &
            "-> both buttons came out m_Group=NULL (no Instantiate remap: " &
            "the buttons are cloned separately from the strip), so both " &
            "were WIRED onto the strip's own cloned ToggleGroup " & iPtr(stripGroup) &
            " -- native exclusivity now runs off that group."
    elif g0 != nil and g0 == g1:
      groupWired = true
      okLog "postfx subtab: " & iObjName(panelT) & "'s strip toggle group " &
            "check -> GRAPHICS m_Group=" & iPtr(g0) & " POSTFX m_Group=" &
            iPtr(g1) & "; exclusivity is NATIVE already (both point at the " &
            "same cloned ToggleGroup)"
    else:
      okLog "postfx subtab: " & iObjName(panelT) & "'s strip toggle group " &
            "check -> GRAPHICS m_Group=" & iPtr(g0) & " POSTFX m_Group=" &
            iPtr(g1) & "; NOT wired (neither both-null nor matching), " &
            "left alone -- exclusivity stays OURS, enforced every frame by " &
            "gfxApply/gfxTickBody"
  else:
    okLog "postfx subtab: " & iObjName(panelT) & "'s strip clone carries no " &
          "reachable ToggleGroup component, so m_Group could not be wired; " &
          "exclusivity stays OURS, enforced every frame by " &
          "gfxApply/gfxTickBody"
  # THE CLICK QUESTION, MEASURED NOT ASSUMED. A group wiring fix does nothing
  # if the click never reaches the Toggle at all. Read (never blind-write)
  # Selectable.m_Interactable and the target Graphic's m_RaycastTarget for
  # each button and say what was found; only flip m_Interactable when it
  # measures false, because THAT alone is unambiguously wrong for a control
  # meant to be clickable -- raycastTarget/occlusion is reported, not patched,
  # since fixing it blind could as easily be the wrong sibling.
  var i2 = 0
  while i2 < into.len:
    let tog = into[i2]
    if tog != nil and duOk(tog, ModsOffInteractable + 1'i32):
      let interact = cSwReadU8(tog, ModsOffInteractable) != 0'i32
      var rtStr = "n/a"
      if duOk(tog, ModsOffTargetGraphic + 8'i32):
        let tg = cReadPtrAt(tog, ModsOffTargetGraphic)
        if tg != nil and duOk(tg, GfxOffRaycastTarget + 1'i32):
          rtStr = (if cSwReadU8(tg, GfxOffRaycastTarget) != 0'i32: "true" else: "FALSE")
        else:
          rtStr = "no reachable targetGraphic"
      if not interact:
        discard cUxWritePtr(tog, ModsOffInteractable, cast[Il2CppPtr](1))
        warn "postfx subtab: " & iObjName(panelT) & " strip button " & $i2 &
             " measured m_Interactable=FALSE (raycastTarget=" & rtStr &
             ") -- a click could never reach it. Flipped to true."
      else:
        okLog "postfx subtab: " & iObjName(panelT) & " strip button " & $i2 &
              " measured m_Interactable=true, targetGraphic.raycastTarget=" &
              rtStr & "."
    i2 = i2 + 1
  result = true

proc gfxApply(sel: int) =
  ## Switch the two STOCK panels and put both strips in agreement. Calls only
  ## where something differs: this runs while the player is on the Graphics
  ## tab, so it must be quiet in the steady state.
  if gGfxPanelGo == nil or gGfxPostGo == nil:
    return
  let wantPost = (sel == 1)
  if modsGoActive(gGfxPostGo) != wantPost:
    discard modsSetActive(gGfxPostGo, wantPost)
  if modsGoActive(gGfxPanelGo) == wantPost:
    discard modsSetActive(gGfxPanelGo, not wantPost)
  var i = 0
  while i < 2:
    let want = (i == sel)
    if i < gGfxTogA.len and modsToggleIsOn(gGfxTogA[i]) != want:
      discard modsSetToggleQuiet(gGfxTogA[i], want)
    if i < gGfxTogB.len and modsToggleIsOn(gGfxTogB[i]) != want:
      discard modsSetToggleQuiet(gGfxTogB[i], want)
    if i < gGfxLast.len:
      gGfxLast[i] = want
    i = i + 1
  gGfxSel = sel
  if not gGfxSaid:
    gGfxSaid = true
    okLog "postfx subtab: switching between the STOCK Graphics Settings and " &
          "PostFX Settings panels from a cloned two-button strip. Neither " &
          "panel is cloned and neither is written to -- only its active state " &
          "is driven, which is the one thing the game will not do for us, " &
          "because it switches panels by ESettingsGroup."

proc gfxSeedSelection() =
  ## Seed the STRIP's own visual state to GRAPHICS SETTINGS selected -- and
  ## ONLY the strip. `SetIsOnWithoutNotify` on our own clones, never
  ## `SetActive` on a stock panel: that split is the whole fix for DEFECT A
  ## (see `gfxBuild`) without reintroducing it. Without this the strip shows
  ## NEITHER button selected on first open even though the game itself is
  ## already showing Graphics Settings by default, which is exactly "should
  ## be enabled/active by default" read backwards.
  var i = 0
  while i < 2:
    let want = (i == 0)
    if i < gGfxTogA.len:
      discard modsSetToggleQuiet(gGfxTogA[i], want)
    if i < gGfxTogB.len:
      discard modsSetToggleQuiet(gGfxTogB[i], want)
    if i < gGfxLast.len:
      gGfxLast[i] = want
    i = i + 1

proc gfxBuild(): bool =
  result = false
  if gModsLastTabPtr == nil or not duOk(gModsLastTabPtr, 0x20'i32):
    return
  if gModsLastTabName != "game":
    return                              # the container name comes from this tab
  inc gGfxTried
  let tabT = iToTransform(gModsLastTabPtr)
  let screenT = (if tabT != nil: modsParentOf(tabT) else: nil)
  if screenT == nil:
    gfxNoteFault("could not reach the SettingsScreen from the tab")
    return
  let toggles = modsChildNamed(screenT, "Toggles")
  let gfxPanel = modsChildNamed(screenT, "Graphics Settings")
  let postPanel = modsChildNamed(screenT, "PostFX Settings")
  let ctrlPanel = modsChildNamed(screenT, "Control Settings")
  let donorStrip = (if ctrlPanel != nil: modsChildNamed(ctrlPanel, "Toggles")
                    else: nil)
  let donorButton = (if donorStrip != nil:
                       modsChildNamed(donorStrip, "ControlToggle") else: nil)
  if toggles == nil or gfxPanel == nil or postPanel == nil or
     donorStrip == nil or donorButton == nil:
    gfxNoteFault("the pieces this needs were not all found (" &
                 (if toggles == nil: "Toggles " else: "") &
                 (if gfxPanel == nil: "Graphics-Settings " else: "") &
                 (if postPanel == nil: "PostFX-Settings " else: "") &
                 (if donorStrip == nil: "the donor strip " else: "") &
                 (if donorButton == nil: "ControlToggle" else: "") &
                 "). NOTHING was hidden: the stock POSTFX tab is untouched.")
    return
  let spawner = modsChildNamed(toggles, "PostFxToggleSpawner")
  if spawner == nil:
    gfxNoteFault("no PostFxToggleSpawner in the tab bar, so there is no stock " &
                 "tab to fold in. Nothing was changed.")
    return
  let donorStripGo = iGameObjectOf(donorStrip)
  let donorButtonGo = iGameObjectOf(donorButton)
  gGfxPanelGo = iGameObjectOf(gfxPanel)
  gGfxPostGo = iGameObjectOf(postPanel)
  if donorStripGo == nil or donorButtonGo == nil or gGfxPanelGo == nil or
     gGfxPostGo == nil:
    gfxNoteFault("a GameObject was not reachable; nothing was changed")
    return
  # BOTH STRIPS FIRST. The stock tab is hidden only once both exist.
  var stripAGo: Il2CppPtr = nil
  var stripBGo: Il2CppPtr = nil
  if not gfxBuildStrip(gfxPanel, donorStripGo, donorButtonGo, donorButton,
                       gGfxTogA, stripAGo):
    gfxNoteFault("the strip inside Graphics Settings was not built; the stock " &
                 "POSTFX tab is left exactly where it was")
    return
  if not gfxBuildStrip(postPanel, donorStripGo, donorButtonGo, donorButton,
                       gGfxTogB, stripBGo):
    # Strip A already came out usable and is live in Graphics Settings. Left
    # alone it would be a stray, non-functional row -- exactly the kind of
    # half-built residue this feature promises not to leave. Hide it (never
    # destroy; the clone discipline for this file is SetActive only) so the
    # screen is back to stock, matching the fault-ceiling promise below.
    if stripAGo != nil:
      discard modsSetActive(stripAGo, false)
    gGfxTogA = @[]
    gfxNoteFault("the strip inside PostFX Settings was not built; the stock " &
                 "POSTFX tab is left exactly where it was, and the Graphics " &
                 "Settings strip that was already built has been hidden")
    return
  gGfxLast = @[false, false]
  # NOW, and only now, the stock tab comes out of the top row.
  gGfxSpawnerGo = iGameObjectOf(spawner)
  if gGfxSpawnerGo == nil or not modsSetActive(gGfxSpawnerGo, false):
    gGfxSpawnerGo = nil
    gfxNoteFault("the stock POSTFX tab button could not be switched off, so " &
                 "the top row would show five tabs AND a duplicate subtab. " &
                 "The strips are built but the fold-in is incomplete.")
    return
  # THE OUTCOME CHECK: 5 stock tabs minus the one just hidden, PLUS the MODS
  # clone if it exists. Hardcoding "4" was a false alarm waiting to happen:
  # with settingsModsTab also on, the correct live count is 5 (5 stock + 1
  # MODS - 1 hidden POSTFX), and a constant that assumes a stock-only world
  # reported a CORRECT state as suspicious. Derived from the same flag the
  # MODS feature itself sets when its clone actually exists, not re-guessed.
  let expectTabs = 4 + (if gModsBuilt: 1 else: 0)
  let liveTabs = modsActiveChildren(toggles)
  if liveTabs == expectTabs:
    okLog "postfx subtab: the top row now shows " & $liveTabs & " tab " &
          "button(s) (expected " & $expectTabs & ", accounting for the MODS " &
          "clone = " & $gModsBuilt & ") -- POSTFX has " &
          # Kept as ONE literal on purpose: `tools/deploy.json` verifies this
          # exact phrase, and a marker that spans a `&` boundary is not
          # contiguous in the binary, so the check fails on a feature that is
          # actually present. Reword the sentence around it, never through it.
          "been folded into Graphics as a subtab" &
          ". The stock button is HIDDEN, never destroyed, and comes back on " &
          "its own if this feature turns itself off."
  else:
    warn "postfx subtab: the top row shows " & $liveTabs & " active tab " &
         "button(s); " & $expectTabs & " was expected after hiding POSTFX " &
         "(4 stock + MODS clone=" & $gModsBuilt & "). Something else is " &
         "adding or hiding buttons -- reporting it rather than assuming."
  gGfxBuilt = true
  gGfxSel = 0
  # DO NOT force either panel active here. The build ran while the player is
  # on the GAME tab (the guard above requires it), so `gGfxPanelGo` /
  # `gGfxPostGo` are the game's to show or hide -- forcing Graphics Settings
  # on right now was DEFECT A: it left Graphics Settings active ALONGSIDE
  # Game Settings, with our strip drawn over the wrong panel. Panel
  # visibility is driven only by `gfxTickBody`'s steady-state checks, and
  # only once the game itself has actually put one of the two panels up.
  #
  # THE STRIP'S OWN SELECTED STATE IS A DIFFERENT CONCERN, and forcing a
  # panel active was never required to seed it: `gfxSeedSelection` writes
  # only to toggles WE cloned, never to a stock panel's active state.
  gfxSeedSelection()
  result = true

## Throttled tick diagnostic (fact from the live run: gfxTickBody's neither-
## panel-active early return is CORRECT behaviour, but it also made an
## experiment look like "enforcement is dead" when the player was simply on
## another tab. This says which branch the tick took, ONCE per settings
## screen open -- not per frame -- so the next person can tell "correctly
## idle" from "silently broken" without re-running the experiment.
var gGfxTickDiagSaid = false

proc gfxTickBody() =
  if not gGfxOn or gGfxFaults >= GfxMaxFaults:
    return
  if not gGfxBuilt:
    if gModsLastTabPtr != nil and gGfxTried < GfxMaxBuildTries:
      discard gfxBuild()
    return
  if gModsLastTabPtr == nil:
    gGfxTickDiagSaid = false          # settings screen closed; re-arm for next open
  if gGfxPanelGo == nil or gGfxPostGo == nil:
    return
  if not duOk(gGfxPanelGo, 0x20'i32) or not duOk(gGfxPostGo, 0x20'i32):
    return
  let gfxUp = modsGoActive(gGfxPanelGo)
  let postUp = modsGoActive(gGfxPostGo)
  if not gGfxTickDiagSaid:
    gGfxTickDiagSaid = true
    okLog "postfx subtab: tick diagnostic (once per open) -> " &
          "gfxPanelActive=" & $gfxUp & " postPanelActive=" & $postUp &
          "; branch = " &
          (if not gfxUp and not postUp: "IDLE (player on another tab; " &
             "nothing touched, this is correct)"
           elif gfxUp and postUp: "BOTH-ACTIVE (forcing back to selection)"
           else: "NORMAL (watching the strip for a rising edge)")
  if not gfxUp and not postUp:
    # The player is on some other tab entirely. Do NOT touch anything -- the
    # game owns the screen here. Just remember that re-entering starts on
    # GRAPHICS SETTINGS, which is what the stock tab used to do.
    if gGfxSel != 0:
      gGfxSel = 0
      var i = 0
      while i < gGfxLast.len:
        gGfxLast[i] = (i == 0)
        i = i + 1
    return
  if gfxUp and postUp:
    # Both stock panels drawn at once -- the same failure the MODS tab had, and
    # it happens here when the game switches TO graphics while our subtab still
    # says postfx. Resolve towards what the strip says. THE OUTCOME, logged
    # once so a real recurrence is visible without spamming every frame it
    # persists.
    if not gGfxBothActiveSaid:
      gGfxBothActiveSaid = true
      warn "postfx subtab: BOTH Graphics Settings and PostFX Settings were " &
           "active at once (activeSelf true/true); forcing back to " &
           "selection " & $gGfxSel & " so exactly one is up, as the game " &
           "itself would enforce for its own stock tabs."
    gfxApply(gGfxSel)
    return
  # Which subtab did the player just press? Either strip may be the visible one,
  # so both are read and a rising edge on either wins.
  var rising = -1
  var i = 0
  while i < 2:
    let on = (i < gGfxTogA.len and modsToggleIsOn(gGfxTogA[i])) or
             (i < gGfxTogB.len and modsToggleIsOn(gGfxTogB[i]))
    if on and i < gGfxLast.len and not gGfxLast[i]:
      rising = i
    if i < gGfxLast.len:
      gGfxLast[i] = on
    i = i + 1
  if rising >= 0 and rising != gGfxSel:
    gfxApply(rising)
    return
  # STEADY STATE: the panel that is up must be the one the selection names.
  if postUp and gGfxSel != 1:
    gfxApply(gGfxSel)
  elif gfxUp and gGfxSel == 1:
    gfxApply(1)

proc gfxTick() =
  ## Every frame while armed: the steady state is two `activeSelf` reads and a
  ## handful of guarded byte reads, with no allocation and no call.
  if not gGfxOn or gGfxFaults >= GfxMaxFaults:
    return
  gModsBranch = 4
  if cModsGuarded(cast[Il2CppPtr](0)) == nil:
    gfxNoteFault("the postfx-subtab tick FAULTED and was caught; the game " &
                 "survived. The stock panels are left as they were")

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
    # THE STATE CHECK, after the edge work and inside the same single guard --
    # never a second one. Throttled inside itself.
    modsPanelSanity()
  elif gModsBranch == 2:
    verBrandTickBody()
  elif gModsBranch == 3:
    seasonsTickBody()
    # The mode button rides the SAME branch and the SAME guard -- never a
    # second one, because `aowl_p_p_seh` is not re-entrant. It reuses the
    # MenuScreen hide-seasons just resolved, so it costs one child lookup and
    # no search of its own. If seasons found nothing, `gSeasonsMenu` is nil and
    # this returns immediately.
    modeButtonHideFrom(gSeasonsMenu)
    # The beta notice rides the SAME branch and the SAME guard, for the same
    # reason: `aowl_p_p_seh` is not re-entrant, so a guard of its own would
    # disarm this one. It reuses the MenuScreen resolved above and costs one
    # child lookup. If nothing was resolved, `gSeasonsMenu` is nil and this
    # returns immediately.
    betaNoticeFrom(gSeasonsMenu)
  elif gModsBranch == 4:
    gfxTickBody()

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
  if not gVerOn or gVerGaveUp:
    return
  if gVerWalkFaults >= VerBrandMaxWalkFaults:
    # A CEILING REACHED SILENTLY IS THE WORST THING THIS FILE CAN DO. This used
    # to just `return` forever with nothing in the log after the third fault.
    gVerGaveUp = true
    warn "version brand: REFUSING further attempts -- the label walk faulted " &
         $gVerWalkFaults & " times (the ceiling). LAST REASON: " & gVerWhy &
         ". The bottom-left label is left STOCK and will NOT say aowlspt."
    return
  if gVerApplies >= VerBrandMaxApplies:
    gVerGaveUp = true
    warn "version brand: STOPPING -- the label was written " & $gVerApplies &
         " times (the apply ceiling) and kept being overwritten. Something " &
         "else owns this label's text; it is left as the game made it."
    return
  if gVerT0 == 0:
    # THE FIRST FRAME THE RIDER CHAIN GAVE US. Recorded, and logged, because
    # every other timestamp is relative to it and because this moment is
    # itself a candidate cause: nothing here can run before
    # `EFT.UI.PreloaderUI::Update` first fires.
    gVerT0 = cNowMs()
    okLog "version brand: TIMING -- first tick; the rider chain on " &
          "EFT.UI.PreloaderUI::Update has started dispatching. The label " &
          "hunt begins on THIS frame, not 120 frames from now."
  # ADAPTIVE, and every branch is bounded:
  #   * not resolved yet -> every `VerBrandHuntFrames` frames, the closing of
  #     the "stock version string visible for seconds" window;
  #   * resolved         -> every `VerBrandEveryFrames` frames, a clobber
  #     re-check that is one guarded pointer check and one string read;
  #   * pass overran the slice -> the steady cadence, and it said so.
  let hunting = (gVerTmp == nil) and not gVerSlow
  let every = (if hunting: VerBrandHuntFrames else: VerBrandEveryFrames)
  inc gVerFrames
  if gVerFrames < every:
    return
  gVerFrames = 0
  if gVerTmp == nil and gVerT0 != 0 and cNowMs() - gVerT0 > VerBrandHuntMs:
    # THE GIVE-UP, in wall clock. It says how long it hunted and why it
    # stopped, so "the label is stock" is never a silent outcome.
    gVerGaveUp = true
    warn "version brand: GIVING UP after " & $int(VerBrandHuntMs div 1000) &
         " s and " & $gVerNotReady & " walk attempts -- " & gVerWhy &
         ". The label is left stock. This is a REFUSAL, not a success."
    return
  gModsBranch = 2
  if cModsGuarded(cast[Il2CppPtr](0)) == nil:
    inc gVerWalkFaults
    # A REAL FAULT ENDS THE FAST HUNT. Otherwise a walk that faults every pass
    # would spend the whole 40-fault budget in ~80 frames -- the same
    # "gave up before its target existed" failure the budget split was made to
    # prevent, just moved.
    gVerSlow = true
    # NAME THE HOP. A caught fault with no location is precisely what costs
    # cycles here, and the breadcrumb is already being written for us.
    if gVerWalkFaults <= 3:
      warn "version brand: the label walk FAULTED and was caught; the game " &
           "survived. LAST HOP: " & readCString(cInspCrumb()) & "  at " &
           iPtr(cInspCrumbPtr()) & ". Expected before the menu exists; it " &
           "retries (" & $gVerWalkFaults & " of " & $VerBrandMaxWalkFaults & ")"

proc seasonsTick() =
  ## Throttled entry for the seasons-banner hider AND the beta notice, which
  ## share the MenuScreen resolve and therefore share this throttle.
  if not (gSeasonsOn or gBetaNoticeOn) or gSeasonsFaults >= SeasonsMaxFaults:
    return
  # THE THROTTLE IS ADAPTIVE, and it lives here because every throttle in this
  # file lives on the side that decides whether to enter the guard.
  #   * button known  -> EVERY FRAME. The body's fast path is one guarded
  #     pointer check and one `activeSelf` ICALL, with no allocation, and it is
  #     what closes the "banner visible for a second" window.
  #   * menu known    -> every 10 frames: a name walk over MenuScreen's
  #     children, which allocates a string per child.
  #   * nothing known -> the full throttle: the root enumeration allocates.
  inc gSeasonsFrames
  let every = (if gSeasonsBtnGo != nil: 1
               elif gSeasonsMenu != nil: 10
               else: SeasonsEveryFrames)
  if gSeasonsFrames < every:
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

proc modsRidersTick(regs: Il2CppPtr) =
  ## Everything in this file that wants a frame, behind ONE call the rider
  ## chain in `aowlhost.nim` makes. Each entry re-arms the guard separately --
  ## never nested -- and each is a cheap flag test when its feature is off.
  ##
  ## `regs` IS THE FIX FOR A MEASURED FAILURE. This used to take no arguments,
  ## so the version brand had no PreloaderUI of its own and borrowed
  ## `gInspPreloader` -- a global written ONLY by the live inspector's rider.
  ## In a real boot with the inspector's rider not writing it, the brand hunted
  ## from 14.797 s, the menu came up, and it never resolved once. RCX here is
  ## the live `PreloaderUI` `this` in both dispatch halves, so it is captured
  ## before anything else runs.
  if regs != nil:
    let selfRaw = cRegsInt(regs, 0'i32)
    if selfRaw != 0'u64:
      let self = cast[Il2CppPtr](selfRaw)
      if duOk(self, 0x20'i32):
        gVerPreloader = self
        # AND SEED THE SHARED ENUMERATOR'S ANCHOR, if nothing has yet.
        #
        # `iSceneRoots` reaches `DontDestroyOnLoad` -- the only scene the live
        # UI is actually in -- by asking a live object which scene it belongs
        # to. That object is `gInspPreloader`, which has exactly ONE writer in
        # the whole host: `inspectFired`, the live inspector's rider. So every
        # consumer of `iSceneRoots` silently depended on the inspector being
        # armed AND having ticked FIRST.
        #
        # Measured, on a run where it had not: `iSceneRoots` returned 0, and
        # `hide seasons` -- which works every other run -- gave up after 30
        # passes saying "iSceneRoots enumerated NO roots at all". The mode
        # button, the version brand and fact #108's `$settings` anchor are the
        # same disease; four features, one unwritten global.
        #
        # We already hold a verified-live `PreloaderUI` right here, from RCX,
        # roughly 13 seconds before the inspector's first dispatch. Seeding it
        # costs one nil check and makes the shared walk work for everyone
        # regardless of which rider happens to tick first.
        if gInspPreloader == nil:
          gInspPreloader = self
  modsTabTick()
  verBrandTick()
  seasonsTick()
  gfxTick()

proc bindModsTab(verbose: bool): bool =
  ## A RIDER on `EFT.UI.PreloaderUI::Update`, never a second detour on it: two
  ## detours on one function have the second overwrite the first's trampoline
  ## and silently kill the first feature. So this only ever ALIASES onto a slot
  ## another feature already claimed, and if nobody has claimed one it says so
  ## and binds nothing.
  result = false
  if gModsSlot >= 0:
    return true
  if not (gModsOn or gVerOn or gSeasonsOn or gGfxOn or gBetaNoticeOn):
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
