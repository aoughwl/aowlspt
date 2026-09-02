# autoraid.nim -- HOST-NATIVE AUTO-RAID.
#
# On launch, drive the main menu into an OFFLINE raid on a chosen map, natively
# on the Unity main thread, with NO Python and NO live inspector. This is the
# shipped-beta path: `liveInspector` is OFF in the beta, so the Python driver
# `tools/enterraid.py` (which navigates through the inspector file channel)
# cannot run there, and it is also flakier than this -- it drops batches at the
# busy menu. This feature reuses the SAME in-host UI primitives the inspector
# engine already carries (`inspect.nim`): find-by-GameObject-name, the
# activeInHierarchy check, and the DefaultUIButton OnClick(+0x120) press path.
#
# HOW IT IS WIRED -- no new detour
# --------------------------------
# It rides the EXISTING `EFT.TarkovApplication::Update` drain (the same slot the
# singleplayer-rebrand and cursor-free features alias, `gDrainSlot`), by adding
# `autoRaidDrainTick()` to that slot's dispatch in `patchFired`. That drain ticks
# for the WHOLE session -- crucially the matchmaker screens are up before the
# main menu's `PreloaderUI` can be assumed, so a `PreloaderUI::Update` rider
# would be the wrong anchor (this is exactly why `splRebrand` rides this drain,
# not that one). Two detours on one function have the second overwrite the
# first's trampoline; there is only ever ONE, and this adds a rider, not a hook.
#
# THE STATE MACHINE (self-pacing: act only when the expected control is VISIBLE)
# -----------------------------------------------------------------------------
# The measured navigation (facts #240/#263/#265 and tools/enterraid.py):
#
#   ArWaitMenu -> ArPressPlay -> ArNext1 -> ArSelectMap -> ArNext2
#              -> ArNext3 -> ArNext4 -> ArReady -> ArDone
#
#   ArWaitMenu   wait until a PlayButton is activeInHierarchy under MenuScreen
#                (scoped to MenuScreen so the RewardInfo popup's second
#                PlayButton is never mistaken for PLAY, fact #240)
#   ArPressPlay  press that PlayButton (DefaultUIButton OnClick +0x120)
#   ArNext1      press the active NextButton  -> Matchmaker Location Selection
#   ArSelectMap  the location tiles are AnimatedToggles whose descendant "Label"
#                TMP holds the map name; find the one == autoRaidMap and press it
#   ArNext2      press NextButton              -> Matchmaker Offline Raid Screen
#   ArNext3      press NextButton              -> Insurance
#   ArNext4      press NextButton              -> AcceptScreen
#   ArReady      press NextButton (the AcceptScreen READY is ITSELF a NextButton,
#                verified live) -> Final Countdown -> raid loads
#   ArDone       STOP. Once READY is pressed the raid scene is loading; touching
#                the UI during the load errors matchmaking (fact #261), so this
#                state makes NO call into the game ever again.
#
# Practice/offline is NOT ticked here: `singleplayerRebrand` already forces the
# practice toggle host-side (fact #263), which is what keeps the raid routing to
# the emulated backend. This feature only advances the screens; run it WITH
# `singleplayerRebrand` on.
#
# SAFETY, per il2cpp-host discipline
# ----------------------------------
#   * ONE `aowl_p_p_seh` around the whole tick body (`cArTickGuarded`), never
#     nested -- it runs inside no other guard here, and the primitives it calls
#     open none of their own on this path.
#   * Every pointer hop is `duOk`/`iUnityAlive`-checked; nothing is blind-called.
#     The press reads and validates the UnityEvent slot before UnityEvent::Invoke.
#   * Every walk is bounded by a node budget AND an 18ms in-walk wall-clock slice.
#   * Flag-gated `uxAutoRaid`, DEFAULT OFF; map from `autoRaidMap` (default Woods).
#   * Self-disables after `ArMaxFaults` guarded-body faults, and self-disables
#     with a logged reason if any step's control never appears within its bound
#     (it never spins forever).
#   * No per-frame managed allocation on the idle path: the only managed strings
#     it allocates are GetComponent type names, inside GetComponent's own path,
#     throttled to at most one attempt per tick and only while actively stepping.

# ---- bounds ----
const
  ArWarmupMs      = 5000'u64    ## the menu is not up before this; do not walk.
  ArTickFrames    = 30          ## ~0.5 s at 60 fps between attempts.
  ArMinActionMs   = 700'u64     ## min gap between two presses (screen settle).
  ArReuseMs       = 2500'u64    ## if the ONLY active NextButton is the one we just
                                ## pressed and it has persisted this long, the flow
                                ## reuses one NextButton object across screens -- press
                                ## it again rather than waiting forever.
  ArMenuWaitMs    = 180000'u64  ## the menu can take >60 s on a cold launch.
  ArStepTimeoutMs = 45000'u64   ## per non-menu step: if the control never appears.
  ArWalkMs        = 120'u64     ## per-walk wall-clock slice, checked INSIDE the walk.
                                ## GENEROUS on purpose: this runs at the MENU only --
                                ## autoRaid stops at ArDone the instant READY is pressed,
                                ## so it NEVER walks during a raid LOAD (fact #261). A
                                ## brief main-thread hang at the menu is acceptable and it
                                ## makes the path-walk discovery near-instant and immune
                                ## to the breadth-vs-depth fragility a tight slice caused.
  ArNodeBudget    = 120000      ## per-walk node cap -- large so a walk of a known root
                                ## (Common UI / Menu UI) completes in ONE tick even if it
                                ## has thousands of nodes, rather than starving mid-walk.
  ArFanout        = 512         ## children examined per level (a wide root has many).
  ArFindDepth     = 16          ## descent depth.
  ArMapDepth      = 8           ## depth to find a "Label" under a map toggle.
  ArMaxMenuScreens = 3          ## corpse-safety cap on collected MenuScreens. Low so
                                ## the collect-all cannot recurse the whole Common UI
                                ## subtree hunting for phantoms and starve the slice.
  ArMaxToggles    = 32          ## cap on collected map AnimatedToggles (same reason).
  ArMaxFaults     = 3
  ArMaxPlayExtends = 6          ## popup-wait extensions on the PLAY step. The daily-
                                ## reward RewardInfo popup deactivates MenuScreen for
                                ## ~30-60 s AFTER the menu first loads, hiding PLAY;
                                ## "seen once then hidden" is a transient popup, not a
                                ## refusal -- extend the wait rather than self-disable.
                                ## 6 * ArMenuWaitMs is a generous but BOUNDED cap.

# ---- step ids ----
const
  ArWaitMenu  = 0
  ArPressPlay = 1
  ArNext1     = 2   ## -> Matchmaker Location Selection
  ArSelectMap = 3
  ArNext2     = 4   ## -> Matchmaker Offline Raid Screen
  ArNext3     = 5   ## -> Insurance
  ArNext4     = 6   ## -> AcceptScreen
  ArReady     = 7   ## -> Final Countdown (the READY is itself a NextButton)
  ArDone      = 8
  ArFailed    = 9

# ---- the guarded-body thunk (ONE aowl_p_p_seh, never nested) ----
{.emit: """
extern void* aowl_ar_tick_body(void* a);
static void* aowl_ar_tick_guarded(void* a) {
    return aowl_p_p_seh((void*)aowl_ar_tick_body, a);
}
/* raidexit's own guard. A SEPARATE thunk, called from a SEPARATE tick, so the
 * two are sequential and never nested -- aowl_p_p_seh is not re-entrant and a
 * nested guard disarms the outer one. */
extern void* aowl_xr_tick_body(void* a);
static void* aowl_xr_tick_guarded(void* a) {
    return aowl_p_p_seh((void*)aowl_xr_tick_body, a);
}
""".}
proc cArTickGuarded(a: Il2CppPtr): Il2CppPtr {.importc: "aowl_ar_tick_guarded", nodecl.}

# ---- state (gArOn / gArMap are set in the flag-reading pass in aowlhost.nim) ----
var gArOn = false                  ## the `uxAutoRaid` flag; DEFAULT OFF
var gArOff = false                 ## self-disabled after faults / a timed-out step
var gArFaults = 0
var gArMap = "Woods"               ## `autoRaidMap`
var gArStep = ArWaitMenu
var gArT0 = 0'u64                  ## first-tick time (for warm-up)
var gArFrames = 0
var gArStepT0 = 0'u64             ## when the current step began (per-step timeout)
var gArLastPressed: Il2CppPtr = nil ## last NextButton pressed (screen-transition dedup)
var gArLastActionMs = 0'u64        ## time of the last successful press
var gArStarted = false
var gArPlaySeen = false            ## the MenuScreen PlayButton has been visible >=1x
var gArPlayExtends = 0             ## popup-wait extensions granted on the PLAY step
var gArWaitLogMs = 0'u64          ## rate limiter for the WAIT-MENU candidate line

proc arStepName(s: int): string =
  case s
  of ArWaitMenu:  "WAIT-MENU"
  of ArPressPlay: "PLAY"
  of ArNext1:     "NEXT->location"
  of ArSelectMap: "SELECT-MAP"
  of ArNext2:     "NEXT->offline-raid"
  of ArNext3:     "NEXT->insurance"
  of ArNext4:     "NEXT->accept"
  of ArReady:     "READY"
  of ArDone:      "DONE"
  else:           "FAILED"

proc arGoto(s: int) =
  gArStep = s
  gArStepT0 = cNowMs()
  # Publish the stage so the inspector's `raid status` reports what THIS state
  # machine believes, rather than a second opinion computed somewhere else.
  # One string assignment on a step CHANGE -- not per frame, and there are at
  # most ten steps in a whole run, so this is not a per-frame allocation.
  gInspRaidStage = arStepName(s)

# ---------------------------------------------------------------------------
# Discovery: bounded, time-sliced. BREADTH-BEFORE-DEPTH, exactly like
# splrebrand's proven `splFindByName`: at each node, name-check ALL direct
# children before recursing into any subtree. A container like MenuScreen is a
# DIRECT child of a wide root (Common UI has many sibling screens); a pure DFS
# burns the whole 18 ms slice descending the first sibling's subtree before it
# ever reaches MenuScreen -- which is exactly how the first cut sat at WAIT-MENU
# for 180 s and self-disabled. `arWalkActive` additionally requires the match be
# activeInHierarchy (so an INACTIVE NextButton on a screen we are not on can
# never be pressed, fact #72) and can EXCLUDE one pointer (the button we just
# pressed).
# ---------------------------------------------------------------------------
proc arWalkActive(t: Il2CppPtr; name: string; depth: int; budget: var int;
                  deadline: uint64; exclude: Il2CppPtr): Il2CppPtr =
  result = nil
  if t == nil or depth < 0 or budget <= 0 or not duOk(t, 0x20'i32): return
  budget = budget - 1
  if (budget and 31) == 0 and cNowMs() > deadline:
    budget = 0                              # poison the budget: unwinds all levels
    return
  if t != exclude and iObjName(t) == name:
    let a = iActiveInHierarchy(t)
    if a[0] and a[1]:
      return t
    # matched by name but inactive (or state unknown): keep searching.
  if depth == 0: return
  var n = 0
  if not iChildCount(t, n): return
  # Pass 1 -- breadth: name+active check every direct child (no descent).
  var i = 0
  while i < n and i < ArFanout and budget > 0:
    let c = iChildAt(t, i)
    if c != nil and duOk(c, 0x20'i32):
      budget = budget - 1
      if (budget and 31) == 0 and cNowMs() > deadline:
        budget = 0
        return
      if c != exclude and iObjName(c) == name:
        let a = iActiveInHierarchy(c)
        if a[0] and a[1]:
          return c
    i = i + 1
  # Pass 2 -- depth: recurse only after the whole level missed.
  i = 0
  while i < n and i < ArFanout and budget > 0:
    let c = iChildAt(t, i)
    if c != nil:
      result = arWalkActive(c, name, depth - 1, budget, deadline, exclude)
      if result != nil: return
    i = i + 1

proc arCollectChildren(t: Il2CppPtr; name: string; depth: int; budget: var int;
                       deadline: uint64; into: var seq[Il2CppPtr]; cap: int) =
  ## The BREADTH-BEFORE-DEPTH body: name-check every DIRECT child of `t` first,
  ## then recurse. It does NOT check `t` itself -- the caller already did -- so
  ## each node is name-checked EXACTLY once (as some parent's direct child, or as
  ## the collect root) and there are no duplicate hits. Breadth-first matters for
  ## the same reason it does in `arWalkActive`: a container like MenuScreen /
  ## AnimatedToggle is a DIRECT child of a WIDE root (Common UI, Menu UI), and a
  ## pure DFS burns the whole 18 ms slice descending the first sibling's subtree
  ## before ever reaching it -- which is exactly why the pure-DFS collect found 0
  ## MenuScreens live while the breadth-first walk had found it at 42 s.
  if depth <= 0 or budget <= 0 or into.len >= cap: return
  var n = 0
  if not iChildCount(t, n): return
  # Pass 1 -- breadth: name-check every direct child (no descent).
  var i = 0
  while i < n and i < ArFanout and budget > 0 and into.len < cap:
    let c = iChildAt(t, i)
    if c != nil and duOk(c, 0x20'i32):
      budget = budget - 1
      if (budget and 31) == 0 and cNowMs() > deadline:
        budget = 0
        return
      if iObjName(c) == name:
        into.add c
        if into.len >= cap: return
    i = i + 1
  # Pass 2 -- depth: recurse only after the whole level missed.
  i = 0
  while i < n and i < ArFanout and budget > 0 and into.len < cap:
    let c = iChildAt(t, i)
    if c != nil:
      arCollectChildren(c, name, depth - 1, budget, deadline, into, cap)
    i = i + 1

proc arCollect(t: Il2CppPtr; name: string; depth: int; budget: var int;
               deadline: uint64; into: var seq[Il2CppPtr]; cap: int) =
  ## Collect up to `cap` nodes named `name` under `t` (active or not),
  ## breadth-before-depth. Checks `t` itself once, then walks its subtree.
  if t == nil or budget <= 0 or into.len >= cap or not duOk(t, 0x20'i32): return
  budget = budget - 1
  if (budget and 31) == 0 and cNowMs() > deadline:
    budget = 0
    return
  if iObjName(t) == name:
    into.add t
    if into.len >= cap: return
  arCollectChildren(t, name, depth, budget, deadline, into, cap)

# ---------------------------------------------------------------------------
# Scene-root enumeration -- reuse inspect.nim's `iSceneRoots` (the same path
# `splFindScreen` uses successfully), which asks the anchor GameObject for its
# scene via GameObject::get_scene_Injected and enumerates ALL its roots via
# Scene::GetRootGameObjects. The first cut scoped the search to the anchor
# (Preloader UI) subtree, which holds AlphaLabel but NOT PlayButton -- PlayButton
# lives under a DIFFERENT root (Common UI -> MenuScreen). So every step searches
# a PREFERRED root by name, then FALLS BACK across every enumerated root, so a
# wrong scope can never silently starve the search.
# ---------------------------------------------------------------------------
var gArLastRootCount = -1        ## last logged root count (re-log when it changes)
var gArRootCount = 0             ## roots enumerated on the most recent call

proc arEnumRoots(into: var seq[Il2CppPtr]) =
  ## Re-enumerate the DontDestroyOnLoad scene roots FRESH on every call (no
  ## cache): iSceneRoots asks the anchor for its scene and lists its CURRENT
  ## roots, so Common UI / Menu UI enter scope the moment they load (~40 s),
  ## after the boot set (~11). Re-logs whenever the count CHANGES -- so the log
  ## proves the set grows (11 -> 13) rather than being cached, per 9b.
  let anchor = splAnchor()
  discard iSceneRoots(into, false, anchor)
  gArRootCount = into.len
  if into.len != gArLastRootCount:
    gArLastRootCount = into.len
    var names = ""
    var i = 0
    while i < into.len and names.len < 600:
      let r = iToTransform(into[i])
      if r != nil and duOk(r, 0x20'i32):
        names = names & "[" & iObjName(r) & "]"
      i = i + 1
    okLog "autoRaid: enumerated " & $into.len &
          " DontDestroyOnLoad root(s): " & names

proc arNamedRoot(roots: seq[Il2CppPtr]; name: string): Il2CppPtr =
  result = nil
  var i = 0
  while i < roots.len:
    let r = iToTransform(roots[i])
    if r != nil and duOk(r, 0x20'i32) and iObjName(r) == name:
      return r
    i = i + 1

proc arOnClickOff(compType: string): int32 =
  ## The UnityEvent slot that `arPress` fires and `arIsPressable` reads -- the
  ## SINGLE source of that offset for BOTH, so the check and the action can never
  ## again read different slots (the §9b divergence lesson).
  ##
  ## EFT's DefaultUIButton keeps its OnClick UnityEvent at +0x120, NOT at the
  ## generic UnityEngine.UI.Button.m_OnClick@0x100 that `cNavOffOnClick()`
  ## returns. Confirmed live on the MenuScreen PlayButton: comp+0x120 is the real
  ## OnClick UnityEvent (valid), comp+0x100 is a different field the guards reject
  ## -- so reading 0x100 made arIsPressable return false forever on a genuinely
  ## pressable button and auto-raid self-disabled having pressed nothing. Every
  ## other compType (AnimatedToggle) keeps the generic 0x100: 0x120 on a Toggle is
  ## m_IsOn (a bool), not an event, so remapping it would fire garbage.
  if compType == "DefaultUIButton": 0x120'i32
  else: cNavOffOnClick()

proc arIsPressable(node: Il2CppPtr; compType: string): bool =
  ## READ-ONLY check (no Invoke) that `node` carries a live `compType`
  ## (DefaultUIButton / AnimatedToggle) with a valid OnClick UnityEvent at the
  ## offset `arPress` would fire (arOnClickOff) --
  ## i.e. that `arPress` WOULD fire it. This is the fix for the atomic-press gap:
  ## several GameObjects can share the name "PlayButton" (a wrapper/container plus
  ## the real button); returning the first merely-ACTIVE one and then pressing it
  ## a beat later hit a node with no DefaultUIButton and did nothing. Discovery
  ## now returns only a node that is BOTH active AND pressable, so the immediate
  ## press in the same tick always lands on the real button.
  result = false
  if node == nil: return
  var comp: Il2CppPtr = nil
  var w = ""
  if not iVisComponent(node, compType, comp, w) or comp == nil: return
  let off = arOnClickOff(compType)
  if not duOk(comp, off + 8'i32) or not iUnityAlive(comp): return
  let ev = cReadPtrAt(comp, off)
  if ev == nil or iIsGameObject(ev) or iIsKnownKlass(cast[uint64](ev)): return
  result = true

proc arPlayUnder(root: Il2CppPtr; deadline: uint64;
                 nMs, nPb, nActive: var int): Il2CppPtr =
  ## Re-find the LIVE PlayButton FRESH every tick, MenuScreen-first -- the shape
  ## that discovered menu-ready at 42 s -- but robust to the corpse: COLLECT ALL
  ## MenuScreens under `root` (not just the first breadth-first match), and under
  ## each, collect PlayButtons and return the first that is activeInHierarchy.
  ##
  ## WHY collect-all: the daily-reward RewardInfo popup rebuilds the
  ## MenuScreen/PlayButton GameObjects during its cycle, so the FIRST MenuScreen
  ## by name can be the DEAD old instance whose PlayButton is inactive, while a
  ## brand-new active PlayButton exists under a SECOND, live MenuScreen. Trying
  ## every MenuScreen and pressing the first ACTIVE PlayButton finds the live one
  ## without a parent-climb (which rejected valid buttons live). Nothing is
  ## cached across ticks: each call re-enumerates and re-collects.
  ##
  ## `nMs`/`nPb`/`nActive` accumulate: MenuScreens seen, PlayButtons under them,
  ## and active PlayButtons -- so a tick that fails to find a pressable button can
  ## log exactly WHY (§9b) instead of a silent timeout.
  result = nil
  if root == nil: return
  var menus: seq[Il2CppPtr] = @[]
  var b = ArNodeBudget
  arCollect(root, "MenuScreen", ArFindDepth, b, deadline, menus, ArMaxMenuScreens)
  nMs = nMs + menus.len
  # NOTE the loop is NOT gated on the outer `deadline`: the MenuScreen collect
  # above may well have exhausted it (it recurses looking for more MenuScreens
  # than exist), and gating here is exactly what starved the PlayButton search to
  # 0. Each PlayButton search gets its OWN fresh 18 ms slice below, and the loop
  # is bounded by ArMaxMenuScreens (2-3 in practice).
  var mi = 0
  while mi < menus.len:
    let ms = menus[mi]
    var pbs: seq[Il2CppPtr] = @[]
    var b2 = ArNodeBudget
    let pbDeadline = cNowMs() + ArWalkMs   # FRESH slice -- never starved by the
                                           # MenuScreen collect. Breadth-first, so a
                                           # PlayButton that is a near-direct child of
                                           # MenuScreen is found in the first pass.
    arCollect(ms, "PlayButton", ArFindDepth, b2, pbDeadline, pbs, 8)
    nPb = nPb + pbs.len
    var pi = 0
    while pi < pbs.len:
      let pb = pbs[pi]
      if duOk(pb, 0x20'i32):
        let a = iActiveInHierarchy(pb)
        if a[0] and a[1]:
          inc nActive
          # Require BOTH active AND pressable: a same-named wrapper GameObject is
          # active but has no DefaultUIButton, and returning it is what made the
          # atomic press a no-op. Only a node arPress would actually fire wins.
          if result == nil and arIsPressable(pb, "DefaultUIButton"):
            result = pb
      pi = pi + 1
    if result != nil: return               # an active, PRESSABLE PlayButton -- stop
    mi = mi + 1

proc arFindPlay(nMs, nPb, nActive: var int): Il2CppPtr =
  ## The active PlayButton under Common UI -> MenuScreen, with a fallback across
  ## every enumerated root. One shared 18 ms deadline bounds the whole search.
  ## Counters accumulate across roots for the WAIT-MENU candidate log.
  result = nil
  nMs = 0; nPb = 0; nActive = 0
  var roots: seq[Il2CppPtr] = @[]
  arEnumRoots(roots)
  if roots.len == 0: return
  let deadline = cNowMs() + ArWalkMs
  let cu = arNamedRoot(roots, "Common UI")
  if cu != nil:
    result = arPlayUnder(cu, deadline, nMs, nPb, nActive)
    if result != nil: return
  var i = 0
  while i < roots.len and cNowMs() <= deadline:
    let r = iToTransform(roots[i])
    if r != nil and r != cu and duOk(r, 0x20'i32):
      result = arPlayUnder(r, deadline, nMs, nPb, nActive)
      if result != nil: return
    i = i + 1

proc arFindActiveAcross(prefName, ctrlName: string;
                        exclude: Il2CppPtr): Il2CppPtr =
  ## The active control named `ctrlName`, searched under the root named
  ## `prefName` FIRST (fact #237: the shared-name search must hit the intended
  ## root before Common UI eats the name), then across every enumerated root.
  ## One shared 18 ms deadline bounds the whole search.
  result = nil
  var roots: seq[Il2CppPtr] = @[]
  arEnumRoots(roots)
  if roots.len == 0: return
  let deadline = cNowMs() + ArWalkMs
  let pref = arNamedRoot(roots, prefName)
  if pref != nil:
    var b = ArNodeBudget
    result = arWalkActive(pref, ctrlName, ArFindDepth, b, deadline, exclude)
    if result != nil: return
  var i = 0
  while i < roots.len and cNowMs() <= deadline:
    let r = iToTransform(roots[i])
    if r != nil and r != pref and duOk(r, 0x20'i32):
      var b = ArNodeBudget
      result = arWalkActive(r, ctrlName, ArFindDepth, b, deadline, exclude)
      if result != nil: return
    i = i + 1

proc arFindNext(exclude: Il2CppPtr): Il2CppPtr =
  ## The active NextButton under "Menu UI" (fact #237), else any root, excluding
  ## `exclude` (the one we just pressed).
  result = arFindActiveAcross("Menu UI", "NextButton", exclude)

# ---------------------------------------------------------------------------
# The press: DefaultUIButton / AnimatedToggle OnClick(+0x120) via UnityEvent::
# Invoke -- exactly `inspect.nim`'s `iPressComponentAndFire`, but SILENT (host
# log, not the inspector output channel). Nothing is blind-called: the component
# is resolved, the UnityEvent slot read and validated, then Invoke.
# ---------------------------------------------------------------------------
proc arPress(node: Il2CppPtr; compType: string): bool =
  result = false
  if node == nil: return
  var comp: Il2CppPtr = nil
  var w = ""
  if not iVisComponent(node, compType, comp, w) or comp == nil: return
  let off = arOnClickOff(compType)            # 0x120 for DefaultUIButton, else 0x100
  if not duOk(comp, off + 8'i32) or not iUnityAlive(comp): return
  let ev = cReadPtrAt(comp, off)
  if ev == nil or iIsGameObject(ev) or iIsKnownKlass(cast[uint64](ev)): return
  var fn: Il2CppPtr = nil
  var rva = 0'u32
  if not iNavFind("UnityEvent::Invoke", fn, rva): return
  iMark("autoRaid: UnityEvent::Invoke", ev)
  discard cInspUP(fn, ev, nil)
  result = true

proc arTrim(s: string): string =
  ## Strip leading/trailing ASCII whitespace (map labels may be padded).
  var a = 0
  var b = s.len - 1
  while a <= b and (s[a] == ' ' or s[a] == '\t' or s[a] == '\r' or s[a] == '\n'):
    inc a
  while b >= a and (s[b] == ' ' or s[b] == '\t' or s[b] == '\r' or s[b] == '\n'):
    dec b
  result = ""
  var i = a
  while i <= b:
    result.add s[i]
    inc i

proc arSelectMapUnder(root: Il2CppPtr; want: string; deadline: uint64): bool =
  ## Scan the AnimatedToggles under `root` for one whose descendant "Label" TMP
  ## text == `want`, and press it. Breadth-first collect, and each Label search
  ## gets its OWN fresh slice so the toggle collect cannot starve it -- the same
  ## discipline the PlayButton search needs.
  result = false
  if root == nil: return
  var toggles: seq[Il2CppPtr] = @[]
  var b = ArNodeBudget
  let tglDeadline = cNowMs() + ArWalkMs
  arCollect(root, "AnimatedToggle", ArFindDepth, b, tglDeadline, toggles, ArMaxToggles)
  var i = 0
  while i < toggles.len:
    let tog = toggles[i]
    var labels: seq[Il2CppPtr] = @[]
    var b2 = ArNodeBudget
    let lblDeadline = cNowMs() + ArWalkMs         # fresh slice per toggle
    arCollect(tog, "Label", ArMapDepth, b2, lblDeadline, labels, 8)
    var j = 0
    while j < labels.len:
      let tmp = splTmpOf(labels[j])
      if tmp != nil:
        let got = iLower(arTrim(splTmpText(tmp)))
        if got.len > 0 and got == want:
          if arPress(tog, "AnimatedToggle"):
            return true
      j = j + 1
    i = i + 1

proc arSelectMap(): bool =
  ## Find the AnimatedToggle whose descendant "Label" TMP text == `gArMap`
  ## (case-insensitive), under "Menu UI" first (fact #237) then any root, and
  ## press it. Returns true only once a real match was pressed -- an unmatched
  ## map is a REFUSAL (stay on this step), never a silent advance.
  result = false
  var roots: seq[Il2CppPtr] = @[]
  arEnumRoots(roots)
  if roots.len == 0: return
  let deadline = cNowMs() + ArWalkMs
  let want = iLower(arTrim(gArMap))
  let pref = arNamedRoot(roots, "Menu UI")
  if pref != nil and arSelectMapUnder(pref, want, deadline):
    return true
  var i = 0
  while i < roots.len and cNowMs() <= deadline:
    let r = iToTransform(roots[i])
    if r != nil and r != pref and duOk(r, 0x20'i32):
      if arSelectMapUnder(r, want, deadline):
        return true
    i = i + 1

# ---------------------------------------------------------------------------
# The tick body -- everything that touches managed memory, under ONE guard.
# ---------------------------------------------------------------------------
proc arFail(why: string) =
  gArOff = true
  gArStep = ArFailed
  gInspRaidStage = "FAILED"
  gInspRaidAns = "FAILED: " & why
  warn "autoRaid: " & why & " -- switching itself off for this session and " &
       "leaving the menu alone. This is a REFUSAL, not a success."

proc arTickBody(a: Il2CppPtr): Il2CppPtr {.exportc: "aowl_ar_tick_body", cdecl.} =
  ## Returns a non-nil sentinel on clean completion; the guard returns nil on a
  ## fault. At most ONE find+press per call, so the machine self-paces frame by
  ## frame instead of racing the menu.
  result = cast[Il2CppPtr](1)
  discard a
  if gArStep == ArDone or gArStep == ArFailed: return

  let now = cNowMs()
  # Enforce a settle gap after every press so a screen has time to transition.
  if gArLastActionMs != 0'u64 and now - gArLastActionMs < ArMinActionMs: return

  if gArStepT0 == 0'u64: gArStepT0 = now
  let stepTimeout = (if gArStep == ArWaitMenu: ArMenuWaitMs else: ArStepTimeoutMs)
  if now - gArStepT0 > stepTimeout:
    # The PLAY step is patient about a TRANSIENT popup. The daily-reward
    # RewardInfo popup deactivates MenuScreen ~30-60 s after the menu loads, so
    # the PlayButton flips visible -> hidden -> visible; "seen once then hidden"
    # is a popup, not a refusal, so keep waiting (bounded) for it to clear rather
    # than self-disabling. If PLAY was NEVER seen, the menu genuinely did not
    # come up and this DOES fail out.
    if gArStep == ArWaitMenu and gArPlaySeen and gArPlayExtends < ArMaxPlayExtends:
      inc gArPlayExtends
      gArStepT0 = now
      warn "autoRaid: the MenuScreen PlayButton was seen but is currently " &
           "hidden (a daily-reward popup is likely up over MenuScreen); still " &
           "waiting for it to clear (extension " & $gArPlayExtends & " of " &
           $ArMaxPlayExtends & ")."
      return
    arFail("step " & arStepName(gArStep) & " never completed within " &
           $(int(stepTimeout div 1000'u64)) & " s (control never became visible)")
    return

  # WAIT-MENU and PLAY are ONE step: the instant the MenuScreen PlayButton reads
  # visible, PRESS it in the SAME tick. The old two-step form re-clocked a fresh
  # 45 s PLAY window exactly as the RewardInfo popup came up and hid the button,
  # so PLAY self-disabled though the button had been visible moments earlier.
  # Pressing on first-visible wins that race (at menu-ready the popup is not yet
  # up); if the popup IS up, arFindPlay returns nil (the button is inactive) and
  # we wait patiently above for it to clear.
  if gArStep == ArWaitMenu:
    var nMs = 0
    var nPb = 0
    var nActive = 0
    # arFindPlay returns an ACTIVE, PRESSABLE MenuScreen PlayButton (or nil) --
    # arIsPressable already confirmed it carries a live DefaultUIButton with an
    # OnClick UnityEvent. Press THAT EXACT node in THIS SAME tick: no "driving"
    # log then a press on a later tick, and no re-find between finding and
    # pressing (a re-find could return a transient/wrong node). The found node is
    # the pressed node, atomically.
    let pb = arFindPlay(nMs, nPb, nActive)
    if pb != nil:
      gArPlaySeen = true
      if arPress(pb, "DefaultUIButton"):
        okLog "autoRaid: menu ready -- pressed PLAY (MenuScreen PlayButton, " &
              "atomic find-and-press); driving into an OFFLINE raid on map \"" &
              gArMap & "\"."
        gArLastPressed = nil
        gArLastActionMs = now
        arGoto(ArNext1)
    else:
      # No pressable PlayButton this tick -- log the candidate census (§9b), so a
      # failure is EVIDENCE (roots enumerated? MenuScreen found? a PlayButton
      # under it? active?) rather than a silent 180 s timeout. `active` counts
      # activeInHierarchy PlayButtons; a non-zero `active` with no press means the
      # active one was not pressable (a same-named wrapper without a button).
      # Rate-limited to ~10 s.
      if now - gArWaitLogMs > 10000'u64:
        gArWaitLogMs = now
        info "autoRaid WAIT-MENU: roots=" & $gArRootCount &
             ", MenuScreen found=" & $nMs & ", PlayButton under it=" & $nPb &
             ", active=" & $nActive & " (nothing pressable this tick)"
    return

  if gArStep == ArNext1 or gArStep == ArNext2 or gArStep == ArNext3 or
     gArStep == ArNext4 or gArStep == ArReady:
    # One NextButton per screen. Prefer one that differs from the button we last
    # pressed; if the ONLY active NextButton is that same object and it has
    # persisted past ArReuseMs, the flow reuses one object across screens, so
    # press it rather than stall.
    var nb = arFindNext(gArLastPressed)
    if nb == nil and gArLastPressed != nil and
       now - gArLastActionMs > ArReuseMs:
      nb = arFindNext(nil)                     # allow the reused object
    if nb != nil and arPress(nb, "DefaultUIButton"):
      okLog "autoRaid: pressed " & arStepName(gArStep)
      gArLastPressed = nb
      gArLastActionMs = now
      if gArStep == ArNext1:   arGoto(ArSelectMap)
      elif gArStep == ArNext2: arGoto(ArNext3)
      elif gArStep == ArNext3: arGoto(ArNext4)
      elif gArStep == ArNext4: arGoto(ArReady)
      else:
        okLog "autoRaid: READY pressed -- the raid scene is loading. Going " &
              "hands-off; this feature will not touch the UI again this session."
        arGoto(ArDone)
    return

  if gArStep == ArSelectMap:
    if arSelectMap():
      okLog "autoRaid: selected map \"" & gArMap & "\""
      gArLastActionMs = now
      arGoto(ArNext2)
    return

proc arArmOnDemand() =
  ## Drain ONE `raid [MAP]` request from the inspector's mailbox and arm this
  ## state machine exactly as a launch with `uxAutoRaid` on would have.
  ##
  ## THIS IS WHY IT IS HERE AND NOT IN inspect.nim: none of autoraid's discovery
  ## is duplicated. The verb deposits a map name; this resets the same variables
  ## the launch path uses and lets the SAME machine run. If the menu is not
  ## actually up, WAIT-MENU says so and times out -- there is no second, weaker
  ## copy of that check anywhere.
  ##
  ## The warm-up is SKIPPED on purpose. `ArWarmupMs` exists because at LAUNCH
  ## the menu cannot be up yet; an on-demand request comes from a human or an
  ## agent who is looking at the menu, so waiting 5s again would only be slow.
  ## WAIT-MENU remains the thing that decides whether the menu is really there.
  if gInspRaidReq.len == 0: return
  let req = gInspRaidReq
  gInspRaidReq = ""
  if req != "-":
    gArMap = req
  let now = cNowMs()
  gArOn = true
  gArOff = false
  gArFaults = 0
  gArStarted = true
  gArT0 = (if now > ArWarmupMs: now - ArWarmupMs else: now)
  gArFrames = ArTickFrames          ## act on THIS tick, not in half a second
  gArLastPressed = nil
  gArLastActionMs = 0'u64
  gArPlaySeen = false
  gArPlayExtends = 0
  gArWaitLogMs = 0'u64
  arGoto(ArWaitMenu)
  gInspRaidAns = "ARMED on demand, map \"" & gArMap & "\", step WAIT-MENU"
  okLog "autoRaid: ARMED ON DEMAND (inspector `raid`), map \"" & gArMap &
        "\" -- the state machine starts at WAIT-MENU on this tick. If the " &
        "main menu is not up, WAIT-MENU will time out and say so; being " &
        "armed is not being in a raid."


# ---------------------------------------------------------------------------
# raidexit -- LEAVE A RAID, HOST-NATIVE. The mirror of the `raid` verb.
#
# WHY IT IS HERE AND NOT IN A TOOL. MEASURED tonight from inside a live Woods
# raid: rootless `find MenuScreen 80000` plus two `find more` reported
# "searched EXHAUSTIVELY ... genuinely NOT PRESENT" for a screen that was
# alive, because in a raid neither `roots` nor `find` could reach
# DontDestroyOnLoad. `tools/exitraid.py` therefore refused every attempt with
# "no `Common UI` scene root". That reachability bug is fixed separately (the
# remembered DDOL handle in inspect.nim) -- but even with it fixed, driving
# five presses from outside costs five file round-trips and five tree walks.
# The host is already standing next to these objects.
#
# THE SEQUENCE, and what each step ASSERTS rather than assumes:
#   SHOW      EFT.UI.MenuScreen::ShowInRaid() @0x1539650 -- arity 0, UNIQUE,
#             prologue 48 89 5C 24 08 48 89 74 24 10 57 48 83 EC 20 48 (all
#             three re-measured out of the shipped GameAssembly.dll here, not
#             taken on trust). It is what puts the in-raid menu up.
#   DISCONNECT_disconnectButton@+0xC0 (DefaultUIButton, offline field table).
#             WAITS for its GameObject to be activeInHierarchy -- a READBACK,
#             because pressing an inactive object returns success and does
#             nothing (fact #72) -- then fires OnClick(+0x120).
#   LEAVE     ReconnectionScreen/LeaveButton, if one appears. Its ABSENCE is
#             not a failure: it is not always shown, so this step SKIPS after a
#             bounded wait instead of self-disabling.
#   RESULTS   the Session End UI NextButton, pressed repeatedly -- it is
#             REBUILT per results page, so each press excludes the previous
#             pointer and the next one must be a DIFFERENT object.
#   VERIFY    the verdict is read off the LIVE TREE: an ACTIVE PlayButton under
#             `Menu UI`. Not "the calls returned", not a step counter -- the
#             thing a player would look at.
#
# SAFETY: default INERT (it does nothing until the inspector's `raidexit` verb
# arms it, which itself needs liveInspectorWrite + `allow write`); ONE
# aowl_p_p_seh around the whole body, never nested; every step time-boxed and
# the whole run capped; every walk bounded by ArNodeBudget and ArWalkMs; it
# self-disables after XrMaxFaults.
# ---------------------------------------------------------------------------
const
  XrIdle       = 0
  XrShow       = 1
  XrDisconnect = 2
  XrLeave      = 3
  XrResults    = 4
  XrVerify     = 5
  XrDone       = 6
  XrFailed     = 7

  XrShowInRaidRva = 0x1539650'u64
  XrShowInRaidSig = "48895C240848897424105748"
    ## `EFT.UI.MenuScreen::ShowInRaid`. The literal is the first 12 bytes as
    ## hex; `iPrologueOk` compares the bytes it is given, so a SHORTER prefix
    ## is a weaker check, never a false one. Full 16 measured:
    ## 48 89 5C 24 08 48 89 74 24 10 57 48 83 EC 20 48
  XrDiscBtnOff = 0xC0'i32   ## MenuScreen._disconnectButton (offline fields)
  XrInGameOff  = 0x110'i32  ## MenuScreen._inGameScreenStatus (bool)
  XrStepMs     = 20000'u64  ## per-step ceiling
  XrLeaveMs    = 6000'u64   ## how long a LeaveButton is waited for before SKIP
  XrTotalMs    = 180000'u64 ## whole-run ceiling
  XrTickFrames = 12         ## ~0.2s between attempts
  XrMaxFaults  = 3
  XrMaxResults = 12         ## results pages pressed before refusing

var gXrStep = XrIdle
var gXrT0 = 0'u64
var gXrStepT0 = 0'u64
var gXrFrames = 0
var gXrFaults = 0
var gXrMenu: Il2CppPtr = nil        ## the MenuScreen we called ShowInRaid on
var gXrLastPressed: Il2CppPtr = nil ## the NextButton just pressed (dedup)
var gXrResults = 0

proc xrStepName(s: int): string =
  case s
  of XrIdle:       "IDLE"
  of XrShow:       "SHOW-IN-RAID"
  of XrDisconnect: "DISCONNECT"
  of XrLeave:      "LEAVE"
  of XrResults:    "RESULTS"
  of XrVerify:     "VERIFY"
  of XrDone:       "DONE"
  else:            "FAILED"

proc xrGoto(s: int) =
  gXrStep = s
  gXrStepT0 = cNowMs()
  gInspExitStage = xrStepName(s)

proc xrFail(why: string) =
  gXrStep = XrFailed
  gInspExitStage = "FAILED"
  gInspExitAns = "FAILED: " & why
  warn "raidExit: " & why & " -- stopping. This is a REFUSAL, not a success."

proc xrFindAny(name: string): Il2CppPtr =
  ## The node named `name` anywhere in the enumerated roots, ACTIVE OR NOT --
  ## MenuScreen is INACTIVE in a raid, which is the entire reason ShowInRaid
  ## exists, so the active-only walk cannot be used to find it.
  result = nil
  var roots: seq[Il2CppPtr] = @[]
  arEnumRoots(roots)
  if roots.len == 0: return
  let deadline = cNowMs() + ArWalkMs
  var found: seq[Il2CppPtr] = @[]
  var i = 0
  while i < roots.len and cNowMs() <= deadline and found.len == 0:
    let r = iToTransform(roots[i])
    if r != nil and duOk(r, 0x20'i32):
      var b = ArNodeBudget
      arCollect(r, name, ArFindDepth, b, deadline, found, 1)
    i = i + 1
  if found.len > 0:
    result = found[0]

proc xrTickBody(a: Il2CppPtr): Il2CppPtr {.exportc: "aowl_xr_tick_body", cdecl.} =
  ## At most ONE discovery + ONE press per call, so the machine self-paces.
  result = cast[Il2CppPtr](1)
  discard a
  let now = cNowMs()
  if now - gXrT0 > XrTotalMs:
    xrFail("the whole leave sequence exceeded " & $int(XrTotalMs div 1000'u64) &
           "s at step " & xrStepName(gXrStep))
    return
  if gXrStep != XrLeave and now - gXrStepT0 > XrStepMs:
    xrFail("step " & xrStepName(gXrStep) & " found nothing within " &
           $int(XrStepMs div 1000'u64) & "s")
    return

  if gXrStep == XrShow:
    let ms = xrFindAny("MenuScreen")
    if ms == nil: return          # keep looking; the step timeout bounds this
    var comp: Il2CppPtr = nil
    var w = ""
    if not iVisComponent(ms, "MenuScreen", comp, w) or comp == nil:
      # The GameObject named MenuScreen exists but carries no MenuScreen
      # component -- say that rather than calling ShowInRaid on a Transform.
      xrFail("a GameObject named MenuScreen was found but it has no " &
             "EFT.UI.MenuScreen component (" & w & ")")
      return
    if not duOk(comp, XrDiscBtnOff + 8'i32):
      xrFail("the MenuScreen component is not readable to +0x" &
             iHexPad(uint64(XrDiscBtnOff), 3))
      return
    let fn = cInspCode(XrShowInRaidRva)
    if fn == nil:
      xrFail("MenuScreen::ShowInRaid @0x" & iHexPad(XrShowInRaidRva, 7) &
             " did not resolve as callable code on this build")
      return
    if not iPrologueOk(fn, XrShowInRaidSig):
      xrFail("MenuScreen::ShowInRaid @0x" & iHexPad(XrShowInRaidRva, 7) &
             " does not match its recorded prologue on this build")
      return
    gXrMenu = comp
    iMark("raidExit: MenuScreen::ShowInRaid", comp)
    discard cInspUP(fn, comp, nil)
    okLog "raidExit: called MenuScreen::ShowInRaid on " & iPtr(comp) &
          " -- waiting for _disconnectButton to become activeInHierarchy " &
          "(a READBACK, not an assumption)"
    xrGoto(XrDisconnect)
    return

  if gXrStep == XrDisconnect:
    if gXrMenu == nil or not duOk(gXrMenu, XrDiscBtnOff + 8'i32):
      xrFail("the MenuScreen pointer went unreadable before DISCONNECT")
      return
    let btn = cReadPtrAt(gXrMenu, XrDiscBtnOff)
    if btn == nil or not duOk(btn, 0x20'i32) or not iUnityAlive(btn):
      return                      # not wired yet; the step timeout bounds it
    let (ok, act) = iActiveInHierarchy(btn)
    if not ok:
      return
    if not act:
      return                      # STILL CLOSED. Pressing it now would report
                                  # success and do nothing (fact #72).
    if not arIsPressable(btn, "DefaultUIButton"):
      return
    if not arPress(btn, "DefaultUIButton"):
      xrFail("the DISCONNECT button was active and pressable a moment ago and " &
             "the press did not fire")
      return
    okLog "raidExit: pressed DISCONNECT (" & iPtr(btn) & ")"
    gXrLastPressed = nil
    gXrResults = 0
    xrGoto(XrLeave)
    return

  if gXrStep == XrLeave:
    let lb = arFindActiveAcross("Common UI", "LeaveButton", nil)
    if lb == nil:
      if now - gXrStepT0 > XrLeaveMs:
        okLog "raidExit: no ACTIVE LeaveButton appeared within " &
              $int(XrLeaveMs div 1000'u64) & "s -- this screen is not always " &
              "shown, so this is a SKIP, not a failure"
        xrGoto(XrResults)
      return
    if arPress(lb, "DefaultUIButton"):
      okLog "raidExit: pressed LEAVE (" & iPtr(lb) & ")"
      xrGoto(XrResults)
    return

  if gXrStep == XrResults:
    # The results NextButton is REBUILT per page, so `exclude` is what stops
    # this pressing one dead pointer forever and calling it progress.
    let nb = arFindActiveAcross("Session End UI", "NextButton", gXrLastPressed)
    if nb == nil:
      # No further page. Whether that means "finished" is decided by VERIFY,
      # which reads the tree, not by this absence.
      xrGoto(XrVerify)
      return
    if gXrResults >= XrMaxResults:
      xrFail("pressed " & $gXrResults & " results pages without reaching the " &
             "menu; refusing to keep pressing")
      return
    if arPress(nb, "DefaultUIButton"):
      gXrResults = gXrResults + 1
      gXrLastPressed = nb
      gXrStepT0 = now
      okLog "raidExit: pressed results NextButton #" & $gXrResults &
            " (" & iPtr(nb) & ")"
    return

  if gXrStep == XrVerify:
    # THE VERDICT, READ OFF THE LIVE TREE. An ACTIVE PlayButton under `Menu UI`
    # is the thing a player would see; "every call returned" is not evidence.
    let pb = arFindActiveAcross("Menu UI", "PlayButton", nil)
    if pb != nil and arIsPressable(pb, "DefaultUIButton"):
      gXrStep = XrDone
      gInspExitStage = "DONE"
      gInspExitAns = "DONE: an ACTIVE, pressable PlayButton is under `Menu " &
                     "UI` -- we are back at the main menu"
      okLog "raidExit: DONE -- verified by an ACTIVE, pressable PlayButton " &
            "under `Menu UI` (" & iPtr(pb) & "), not by the calls returning"
      return
    # Not there yet: the results chain may have another page.
    if arFindActiveAcross("Session End UI", "NextButton", gXrLastPressed) != nil:
      xrGoto(XrResults)
    return

proc cXrTickGuarded(a: Il2CppPtr): Il2CppPtr {.importc: "aowl_xr_tick_guarded", nodecl.}

proc xrArmOnDemand() =
  if gInspExitReq.len == 0: return
  gInspExitReq = ""
  gXrT0 = cNowMs()
  gXrFaults = 0
  gXrFrames = XrTickFrames
  gXrMenu = nil
  gXrLastPressed = nil
  gXrResults = 0
  xrGoto(XrShow)
  gInspExitAns = "ARMED, step SHOW-IN-RAID"
  okLog "raidExit: ARMED ON DEMAND (inspector `raidexit`) -- SHOW-IN-RAID -> " &
        "DISCONNECT -> LEAVE -> RESULTS -> VERIFY. Armed is not out."

proc raidExitDrainTick() =
  ## Rides the same TarkovApplication::Update drain autoraid does. INERT until
  ## armed: when idle this is one integer compare and one string-length check,
  ## and makes no call into the game.
  xrArmOnDemand()
  if gXrStep == XrIdle or gXrStep == XrDone or gXrStep == XrFailed: return
  gXrFrames = gXrFrames + 1
  if gXrFrames < XrTickFrames: return
  gXrFrames = 0
  if cXrTickGuarded(nil) == nil:
    gXrFaults = gXrFaults + 1
    warn "raidExit: the guarded tick body faulted (" & $gXrFaults & " of " &
         $XrMaxFaults & ")"
    if gXrFaults >= XrMaxFaults:
      xrFail("too many faults")

proc autoRaidDrainTick() =
  ## Rides the `EFT.TarkovApplication::Update` drain (slot alias, no second
  ## detour). Cheap when idle: off, self-disabled, done, or inside the warm-up it
  ## is a handful of integer compares and makes NO call into the game.
  #
  # The mailbox is drained BEFORE the flag early-out, and that ordering is the
  # whole point: `uxAutoRaid` is default OFF, so a check of `gArOn` first would
  # make the on-demand verb work only in sessions that did not need it.
  arArmOnDemand()
  # raidexit rides here too rather than taking a detour of its own, and it is
  # driven BEFORE the autoraid flag early-out for the same reason arArmOnDemand
  # is: gating an on-demand verb behind a default-OFF launch flag would make it
  # work only where it is not needed.
  raidExitDrainTick()
  if not gArOn or gArOff: return
  if gArStep == ArDone: return
  if gArT0 == 0'u64: gArT0 = cNowMs()
  if cNowMs() - gArT0 < ArWarmupMs: return      # the menu cannot be up yet
  if not gArStarted:
    gArStarted = true
    gArStepT0 = cNowMs()
  inc gArFrames
  if gArFrames < ArTickFrames: return
  gArFrames = 0
  if cArTickGuarded(nil) == nil:
    inc gArFaults
    warn "autoRaid: the guarded tick body faulted (" & $gArFaults & " of " &
         $ArMaxFaults & ")"
    if gArFaults >= ArMaxFaults:
      arFail("too many faults")
