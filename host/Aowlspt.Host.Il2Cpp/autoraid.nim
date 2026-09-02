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
  ArCharGraceMs   = 12000'u64   ## CHARACTER: how long to wait for the character/
                                ## mode screen to become ACTIVE after PLAY before
                                ## concluding this flow does not show one and
                                ## continuing. MEASURED 2026-09-01: pressing PLAY
                                ## puts "SELECT YOUR CHARACTER / PVE ZONE"
                                ## (GameObject `CharacterSelectionScreen`, under
                                ## the `Menu UI` root) on screen, and nothing
                                ## answered it -- the step after PLAY is NOT the
                                ## location list.
  ArCharSettleMs  = 6000'u64    ## after pressing a slot's Apply, how long the
                                ## screen may stay active before we try again.
  ArMaxCharPresses = 2          ## presses of the character slot, EVER. Then the
                                ## step refuses by name rather than mashing.
  ArMaxSlots      = 8           ## CharacterSlotView* collected per screen.
  ArCharDepth     = 8           ## descent under the screen for slots/Title/Apply.
  ArCensusCap     = 24          ## names printed by the stuck-step screen census.
  ArPreMaxTries   = 2           ## PRE-MENU dismissal attempts, EVER. Then the
                                ## step refuses by name, loudly, naming the
                                ## screen it could not dismiss.
  ArPreSettleMs   = 4000'u64    ## after a dismissal attempt, how long the
                                ## overlay may still read active before the
                                ## next attempt is allowed.
  ArOffWaitMs     = 20000'u64   ## after NEXT->offline-raid, how long we wait for
                                ## the MatchmakerOfflineRaidScreen::Show event
                                ## before saying the readback never arrived.

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
  ArCharacter = 10  ## after PLAY: answer the character/mode selection screen
  ArPreMenu   = 11  ## before the menu: dismiss a screen overlaying MenuScreen

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

# ---- PRE-MENU: the screen's OWN close path (abi/aowlspt_premenu.h) ----------
# ONE row, so the positional index cannot drift silently -- and it is registered
# in tools/idxbind.py all the same, because a table that is not registered there
# fails the build by design.
proc cPmnFn(i: int32): Il2CppPtr {.importc: "aowl_pmn_fn", nodecl.}
proc cPmnRva(i: int32): uint32 {.importc: "aowl_pmn_rva", nodecl.}
proc cPmnOkCount(): int32 {.importc: "aowl_pmn_ok_count", nodecl.}
proc cPmnBadCount(): int32 {.importc: "aowl_pmn_bad_count", nodecl.}
proc cPmnProfullCount(): int32 {.importc: "aowl_pmn_profull_count", nodecl.}
proc cPmnCallClose(fn, screen: Il2CppPtr) {.
  importc: "aowl_pmn_call_close", nodecl.}

const
  # The row name is the WHOLE doc comment on purpose: tools/idxbind.py reads it
  # as the row this index claims to address and fails the build if the C table
  # ever stops agreeing. RVA 0x1720B10, arity 0, UNIQUE -- in the header.
  PmnTSsClose = 0'i32   ## EFT.UI.Settings.SettingsScreen::Close

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
var gArChar = "PvE Zone"           ## `autoRaidCharacter`: the slot TITLE to press
var gArCharPresses = 0             ## slot Apply presses this session
var gArCharPressedMs = 0'u64       ## when the slot was pressed (readback clock)
var gArCharLogMs = 0'u64           ## rate limiter for the CHARACTER census line
var gArCharAnswered = 0            ## character screens dismissed by THIS feature
var gArOffEpoch = 0                ## last seen uihooks site-0 epoch (offline raid)
var gArOffFires = 0                ## site-0 show events observed while armed
var gArOffAwaitMs = 0'u64          ## when NEXT->offline-raid was pressed
var gArCensused = false            ## the stuck-step census has been printed once
var gArPreTries = 0                ## PRE-MENU dismissal attempts made
var gArPreActMs = 0'u64            ## when the last dismissal attempt was made
var gArPreDismissed = 0            ## overlays this feature actually cleared
var gArPreChatSeen = 0             ## ticks on which ChatScreen read ACTIVE
var gArPreChecks = 0               ## PRE-MENU overlay checks made (the divisor)
var gArPreVia = "nothing"          ## which route the last attempt used

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
  of ArCharacter: "CHARACTER"
  of ArPreMenu:   "PRE-MENU"
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
# THE CHARACTER/MODE SELECTION SCREEN, answered by the TEXT A PERSON READS.
#
# MEASURED 2026-09-01 (aowlspt-host.log + one screenshot + the live inspector):
# pressing PLAY does NOT go to the location list. It puts the character/mode
# screen up again -- "SELECT YOUR CHARACTER / PVE ZONE", GameObject
# `CharacterSelectionScreen` (the inspector read `BackButton` parent =
# CharacterSelectionScreen) -- and NOTHING answered it, so the old machine sat
# on NEXT->location for its whole 45 s bound and refused.
#
# WHY THIS IS HERE AND NOT ONLY IN modeskip.nim: modeskip is driven by a POSTFIX
# on `CharacterSelectionScreen::ShowSlot`, and in that run the event did NOT
# fire for the second showing. The host log has the boot slots (slot 1 and slot
# 2 at 0:00:28, Submit at 0:00:28.313) and NOTHING after PLAY at 0:04:30 --
# neither further slot lines (the per-slot log resets per controller and prints
# the first 8) nor the "ShowSlot fired AGAIN" warning, in a session where the
# feature was armed and had not self-disabled. A feature cannot answer an event
# it never hears. modeskip is still made RE-ANSWERABLE (it is the cheaper and
# genuinely event-driven path when the event does fire, and its log now says so
# either way); this step is the one that does not depend on that.
#
# The route is the one tools/entergame.py verified live from the inspector side:
#   the ACTIVE `CharacterSelectionScreen`  (two copies exist; the Login UI one
#     is INACTIVE and pressing it silently does nothing -- fact #72 -- so the
#     screen is found with `arWalkActive`, which returns only ACTIVE nodes)
#     -> `CharacterSlotView*`   (matched by name PREFIX: the suffix names the
#        slot, and object NAMES ARE NOT TITLES -- `CharacterSlotView_pvp` is
#        labelled "PvE", so keying on the name would confidently pick wrong)
#        -> descendant `Title` TMP == the wanted title (`autoRaidCharacter`,
#           default "PvE Zone")
#        -> descendant `Apply` -> DefaultUIButton OnClick(+0x120)
# ---------------------------------------------------------------------------
proc arStartsWith(s, pre: string): bool =
  if pre.len > s.len: return false
  var i = 0
  while i < pre.len:
    if s[i] != pre[i]: return false
    i = i + 1
  return true

proc arCollectPrefixChildren(t: Il2CppPtr; pre: string; depth: int;
                             budget: var int; deadline: uint64;
                             into: var seq[Il2CppPtr]; cap: int) =
  ## Breadth-before-depth collect by name PREFIX. Same shape and the same bounds
  ## as `arCollectChildren`; only the predicate differs, so the two cannot drift
  ## apart in their budget or deadline handling.
  if depth <= 0 or budget <= 0 or into.len >= cap: return
  var n = 0
  if not iChildCount(t, n): return
  var i = 0
  while i < n and i < ArFanout and budget > 0 and into.len < cap:
    let c = iChildAt(t, i)
    if c != nil and duOk(c, 0x20'i32):
      budget = budget - 1
      if (budget and 31) == 0 and cNowMs() > deadline:
        budget = 0
        return
      if arStartsWith(iObjName(c), pre):
        into.add c
        if into.len >= cap: return
    i = i + 1
  i = 0
  while i < n and i < ArFanout and budget > 0 and into.len < cap:
    let c = iChildAt(t, i)
    if c != nil:
      arCollectPrefixChildren(c, pre, depth - 1, budget, deadline, into, cap)
    i = i + 1

proc arCollectPrefix(t: Il2CppPtr; pre: string; depth: int; budget: var int;
                     deadline: uint64; into: var seq[Il2CppPtr]; cap: int) =
  if t == nil or budget <= 0 or into.len >= cap or not duOk(t, 0x20'i32): return
  budget = budget - 1
  if arStartsWith(iObjName(t), pre):
    into.add t
    if into.len >= cap: return
  arCollectPrefixChildren(t, pre, depth, budget, deadline, into, cap)

proc arCharScreen(): Il2CppPtr =
  ## The ACTIVE `CharacterSelectionScreen`: `Menu UI` first, then any root.
  result = arFindActiveAcross("Menu UI", "CharacterSelectionScreen", nil)

proc arLabelUnder(node: Il2CppPtr; name: string; depth: int): string =
  ## TMP text of the first descendant named `name`. "" means NOT FOUND or
  ## UNREADABLE -- the caller must never treat that as a match (an empty string
  ## comparing equal to an empty wanted title would be a check that cannot fail).
  result = ""
  var hits: seq[Il2CppPtr] = @[]
  var b = ArNodeBudget
  arCollect(node, name, depth, b, cNowMs() + ArWalkMs, hits, 4)
  var i = 0
  while i < hits.len:
    let tmp = splTmpOf(hits[i])
    if tmp != nil:
      let t = arTrim(splTmpText(tmp))
      if t.len > 0: return t
    i = i + 1

proc arAnswerCharacterUnder(scr: Il2CppPtr; nSlots, nTitled: var int;
                            titles: var string): bool =
  ## Press the `Apply` of the slot whose displayed Title == `gArChar`. True ONLY
  ## when a real match was pressed; an unmatched title keeps the step (a
  ## REFUSAL), never a silent advance. `titles` collects what was actually
  ## readable so that a refusal is evidence rather than a shrug.
  result = false
  nSlots = 0
  nTitled = 0
  titles = ""
  if scr == nil: return
  var slots: seq[Il2CppPtr] = @[]
  var b = ArNodeBudget
  arCollectPrefix(scr, "CharacterSlotView", ArCharDepth, b,
                  cNowMs() + ArWalkMs, slots, ArMaxSlots)
  nSlots = slots.len
  let want = iLower(arTrim(gArChar))
  var i = 0
  while i < slots.len:
    let slot = slots[i]
    let title = arLabelUnder(slot, "Title", ArCharDepth)
    if title.len > 0:
      nTitled = nTitled + 1
      if titles.len < 240:
        titles = titles & "[" & iObjName(slot) & "=" & title & "]"
      if iLower(title) == want and want.len > 0:
        var b2 = ArNodeBudget
        let apply = arWalkActive(slot, "Apply", ArCharDepth, b2,
                                 cNowMs() + ArWalkMs, nil)
        if apply == nil:
          warn "autoRaid: step CHARACTER -- the slot titled " & title &
               " was found but has no ACTIVE descendant named `Apply`, so " &
               "there is nothing pressable on it. NOTHING WAS PRESSED."
          return false
        if arPress(apply, "DefaultUIButton"):
          return true
        warn "autoRaid: step CHARACTER -- the slot titled " & title &
             " has an active `Apply`, but its DefaultUIButton OnClick could " &
             "not be resolved and validated, so it was NOT pressed."
        return false
    i = i + 1

proc arActiveCensus(root: Il2CppPtr; depth: int; count: var int;
                    into: var string) =
  ## Names of the ACTIVE nodes at depth <= `depth` under `root`. The honest
  ## answer to "what screen is up": it guesses no class names, it reports what
  ## the live tree really has ACTIVE, and it is bounded by `ArCensusCap` names
  ## and by the same fanout every other walk here uses.
  if root == nil or depth <= 0 or count >= ArCensusCap: return
  var n = 0
  if not iChildCount(root, n): return
  var i = 0
  while i < n and i < ArFanout and count < ArCensusCap:
    let c = iChildAt(root, i)
    if c != nil and duOk(c, 0x20'i32):
      let a = iActiveInHierarchy(c)
      if a[0] and a[1]:
        count = count + 1
        if into.len < 700:
          into = into & "[" & iObjName(c) & "]"
        arActiveCensus(c, depth - 1, count, into)
    i = i + 1

proc arScreenCensus(): string =
  ## ONE line naming the ACTIVE nodes under `Menu UI` and `Common UI`. Printed
  ## when a step is about to refuse, so that a timeout is EVIDENCE about which
  ## screen the client is really on instead of "the control never became
  ## visible", which names only what we failed to find.
  result = ""
  var roots: seq[Il2CppPtr] = @[]
  arEnumRoots(roots)
  var i = 0
  while i < roots.len:
    let r = iToTransform(roots[i])
    if r != nil and duOk(r, 0x20'i32):
      let nm = iObjName(r)
      if nm == "Menu UI" or nm == "Common UI":
        var count = 0
        var names = ""
        arActiveCensus(r, 2, count, names)
        result = result & " " & nm & " active(depth<=2)=" & $count & ": " & names
    i = i + 1
  if result.len == 0:
    result = " (neither `Menu UI` nor `Common UI` is an enumerated root now)"

# ---------------------------------------------------------------------------
# PRE-MENU: clear a screen that is OVER the main menu.
#
# MEASURED 2026-09-02, live, on the previous build of this file: `raid Woods`
# issued with Settings open sat in WAIT-MENU for the whole 180 s bound and
# refused with this census --
#
#   Common UI active(depth<=2)=3: [Common UI][SettingsScreen][ChatScreen]
#   Menu UI   active(depth<=2)=2: [UI][Operation Queue Indicator]
#
# -- i.e. `MenuScreen found=1, PlayButton under it=1, active=0`. The button was
# found and INACTIVE because SettingsScreen was over it, and an inactive control
# is not pressable (fact #72). The refusal was correct; the machine simply had
# no way to clear the overlay. `pressname BackButton` does not do it either: it
# searches all 16 roots and refuses (fact #243).
#
# THE LADDER, in this order, bounded at `ArPreMaxTries` attempts TOTAL:
#   1. the screen's OWN close path -- `EFT.UI.Settings.SettingsScreen::Close()`
#      @0x1720B10, resolved OFFLINE, UNIQUE, arity 0, 16-byte prologue-verified
#      against the STARTUP SNAPSHOT, CALLED and never detoured
#      (abi/aowlspt_premenu.h has the disassembly and the virtual-call hazard).
#   2. that screen's OWN Back button, scoped to ITS subtree, pressed through the
#      same validated DefaultUIButton OnClick(+0x120) path every other step
#      uses. Scoped, so this is not the all-roots name hunt that fails.
#
# NEITHER attempt is believed. The step advances only on the FINISHED STATE:
# no ACTIVE SettingsScreen anywhere. If two attempts leave it up, the step
# refuses and NAMES the screen it could not dismiss.
#
# CHATSCREEN IS NEVER TOUCHED. It was active in that census and the menu was
# perfectly usable behind it, so it is not an overlay this feature has any
# business closing. Whether it is ALWAYS active is not yet measured, so it is
# COUNTED here (`chat active on N of M checks`) and acted on never -- the log
# will answer it across runs instead of a guess being written into the code.
# ---------------------------------------------------------------------------
proc arOverlayScreen(): Il2CppPtr =
  ## The ACTIVE `SettingsScreen`, `Common UI` first then any root. Only ACTIVE
  ## nodes are ever returned (`arWalkActive`), so a screen that merely EXISTS in
  ## the hierarchy -- which SettingsScreen always does -- is not an overlay.
  result = arFindActiveAcross("Common UI", "SettingsScreen", nil)

proc arChatActive(): bool =
  ## OBSERVED, NEVER ACTED ON. See the banner.
  result = arFindActiveAcross("Common UI", "ChatScreen", nil) != nil

proc arCloseSettings(ss: Il2CppPtr; why: var string): bool =
  ## Call the screen's own `Close()`. Returns whether the CALL was made -- NOT
  ## whether the screen went away; that is the caller's finished-state readback,
  ## because a handler that returns normally is not evidence of anything.
  result = false
  why = ""
  var comp: Il2CppPtr = nil
  var w = ""
  if not iVisComponent(ss, "SettingsScreen", comp, w):
    why = "could not ask the live object for its SettingsScreen component (" &
          w & "), so nothing was called"
    return false
  if comp == nil:
    why = "the ACTIVE object named `SettingsScreen` carries no component of " &
          "that short type name on this build, so there is no receiver for " &
          "Close() and nothing was called"
    return false
  if not iUnityAlive(comp):
    why = "the SettingsScreen component's native half (m_CachedPtr) is null " &
          "-- a destroyed object stays readable (fact #182), so nothing was " &
          "called"
    return false
  let fn = cPmnFn(PmnTSsClose)
  if fn == nil:
    why = "SettingsScreen::Close @0x" & hexOf(uint64(cPmnRva(PmnTSsClose))) &
          " did NOT verify against the startup prologue snapshot on this " &
          "build (verified=" & $int(cPmnOkCount()) & " rejected=" &
          $int(cPmnBadCount()) & " snapshot-table-full=" &
          $int(cPmnProfullCount()) & "); REFUSING to call it"
    return false
  cPmnCallClose(fn, comp)
  return true

proc arPressBackUnder(ss: Il2CppPtr; why: var string): bool =
  ## Attempt 2: the screen's OWN Back button, scoped to ITS subtree.
  result = false
  why = ""
  var b = ArNodeBudget
  let back = arWalkActive(ss, "BackButton", ArFindDepth, b,
                          cNowMs() + ArWalkMs, nil)
  if back == nil:
    why = "no ACTIVE node named `BackButton` under the ACTIVE SettingsScreen " &
          "subtree (searched that subtree only, NOT every scene root -- the " &
          "all-roots hunt is the one that refuses, fact #243)"
    return false
  if not arPress(back, "DefaultUIButton"):
    why = "the SettingsScreen's own `BackButton` was found and ACTIVE, but " &
          "its DefaultUIButton OnClick could not be resolved and validated, " &
          "so it was NOT pressed"
    return false
  return true

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
  # ---- THE SCREEN-ARRIVAL ORACLE ------------------------------------------
  # `MatchmakerOfflineRaidScreen::Show` @0x1788590 (uihooks site 0, UNIQUE,
  # prologue-verified there). ONE integer compare per tick when nothing has
  # happened; no walk, no call into the game. This is a POSITIVE READBACK that
  # the next screen is really up -- the thing a visibility timeout can never be.
  # It also RESYNCHRONISES the machine: if the offline raid screen is up, then
  # whatever we believed about PLAY/CHARACTER/location/map is settled by
  # observation and the correct next action is the NEXT on THIS screen.
  let ep = uihEpoch(UihSiteOfflineRaid)
  if ep != gArOffEpoch:
    gArOffEpoch = ep
    gArOffFires = gArOffFires + 1
    if gArStep == ArCharacter or gArStep == ArNext1 or
       gArStep == ArSelectMap or gArStep == ArNext2:
      okLog "autoRaid: READBACK -- MatchmakerOfflineRaidScreen::Show fired " &
            "(uihooks site 0, epoch " & $ep & "). The offline raid screen is " &
            "UP, which is an observation, not a guess. Resynchronising from " &
            "step " & arStepName(gArStep) & " to NEXT->insurance."
      gArLastPressed = nil
      gArOffAwaitMs = 0'u64
      arGoto(ArNext3)
    else:
      info "autoRaid: MatchmakerOfflineRaidScreen::Show fired (uihooks site " &
           "0, epoch " & $ep & ") while at step " & arStepName(gArStep) &
           "; noted, no resynchronisation (that step is already past it)."
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
    # A REFUSAL MUST NAME THE STEP AND SAY WHAT WAS ON SCREEN. "the control
    # never became visible" names only what we failed to find; the census names
    # what the client actually had ACTIVE, which is what settles where we are.
    var census = ""
    if not gArCensused:
      gArCensused = true
      census = arScreenCensus()
    arFail("step " & arStepName(gArStep) & " never completed within " &
           $(int(stepTimeout div 1000'u64)) & " s (control never became " &
           "visible)." &
           (if gArStep == ArCharacter:
              " Wanted the character slot titled \"" & gArChar &
              "\" (`autoRaidCharacter`)."
            else: "") &
           " Offline-raid show events seen while armed: " & $gArOffFires &
           ". Character screens answered: " & $gArCharAnswered & "." &
           (if census.len > 0: " ACTIVE:" & census else: ""))
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
        # MEASURED: the screen after PLAY is the character/mode selector, not
        # the location list. CHARACTER grace-skips itself if no such screen
        # becomes active, so this ordering costs nothing on a flow without one.
        arGoto(ArCharacter)
    else:
      # No pressable PlayButton this tick -- log the candidate census (§9b), so a
      # failure is EVIDENCE (roots enumerated? MenuScreen found? a PlayButton
      # under it? active?) rather than a silent 180 s timeout. `active` counts
      # activeInHierarchy PlayButtons; a non-zero `active` with no press means the
      # active one was not pressable (a same-named wrapper without a button).
      # Rate-limited to ~10 s.
      # FOUND BUT INACTIVE IS A DIFFERENT FACT FROM NOT FOUND. A PlayButton
      # that exists under a found MenuScreen and reads inactive means something
      # is OVER the menu -- MEASURED: Settings. That is not a reason to wait
      # 180 s; it is a reason to clear the overlay. Checked at most once every
      # 5 s, and ONLY in this already-stuck case, so the common path pays
      # nothing for it.
      if nMs > 0 and nPb > 0 and nActive == 0 and
         now - gArWaitLogMs > 5000'u64:
        gArPreChecks = gArPreChecks + 1
        if arChatActive(): gArPreChatSeen = gArPreChatSeen + 1
        let ov = arOverlayScreen()
        if ov != nil and gArPreTries < ArPreMaxTries:
          gArWaitLogMs = now
          okLog "autoRaid WAIT-MENU: MenuScreen and its PlayButton were FOUND " &
                "but the button is INACTIVE, and an ACTIVE `SettingsScreen` " &
                "is over the menu. That is an overlay, not a slow menu. " &
                "Going to PRE-MENU to dismiss it (attempt " &
                $(gArPreTries + 1) & " of " & $ArPreMaxTries & "). " &
                "ChatScreen was ACTIVE on " & $gArPreChatSeen & " of " &
                $gArPreChecks & " checks and is NEVER touched."
          arGoto(ArPreMenu)
          return
      if now - gArWaitLogMs > 10000'u64:
        gArWaitLogMs = now
        info "autoRaid WAIT-MENU: roots=" & $gArRootCount &
             ", MenuScreen found=" & $nMs & ", PlayButton under it=" & $nPb &
             ", active=" & $nActive & " (nothing pressable this tick)"
    return

  if gArStep == ArPreMenu:
    let ov = arOverlayScreen()
    # (a) THE FINISHED STATE, and it is a NEGATIVE: no ACTIVE SettingsScreen.
    if ov == nil:
      if gArPreTries > 0:
        gArPreDismissed = gArPreDismissed + 1
        okLog "autoRaid PRE-MENU: dismissed SettingsScreen via " &
              gArPreVia & " -- READBACK: no ACTIVE `SettingsScreen` remains " &
              "anywhere. Returning to WAIT-MENU. Overlays cleared this " &
              "session: " & $gArPreDismissed & "."
      else:
        info "autoRaid PRE-MENU: the ACTIVE SettingsScreen went away before " &
             "anything was attempted (the player closed it, most likely). " &
             "Nothing was called and nothing is claimed; back to WAIT-MENU."
      gArPreTries = 0
      gArStepT0 = 0'u64
      arGoto(ArWaitMenu)
      return
    # (b) settle after an attempt before judging it or trying again.
    if gArPreTries > 0 and now - gArPreActMs < ArPreSettleMs:
      return
    if gArPreTries >= ArPreMaxTries:
      var census = ""
      if not gArCensused:
        gArCensused = true
        census = arScreenCensus()
      arFail("step PRE-MENU -- `SettingsScreen` is STILL ACTIVE over the main " &
             "menu after " & $gArPreTries & " dismissal attempts (" &
             gArPreVia & "), so the MenuScreen PlayButton stays unpressable " &
             "and this feature will not reach the menu. The screen it could " &
             "NOT dismiss is SettingsScreen; ChatScreen was never touched " &
             "(ACTIVE on " & $gArPreChatSeen & " of " & $gArPreChecks &
             " checks)" & (if census.len > 0: ". ACTIVE:" & census else: ""))
      return
    # (c) the ladder: the screen's own Close() first, its own Back button next.
    var why = ""
    if gArPreTries == 0:
      gArPreTries = 1
      gArPreActMs = now
      gArLastActionMs = now
      gArPreVia = "SettingsScreen::Close @0x" &
                  hexOf(uint64(cPmnRva(PmnTSsClose)))
      if arCloseSettings(ov, why):
        okLog "autoRaid PRE-MENU: called " & gArPreVia &
              " on the ACTIVE SettingsScreen. CALLED IS NOT DISMISSED -- the " &
              "readback is the next tick finding NO active SettingsScreen."
      else:
        warn "autoRaid PRE-MENU: could not call SettingsScreen::Close -- " &
             why & ". Falling back to the screen's own BackButton on the " &
             "next attempt."
      return
    gArPreTries = gArPreTries + 1
    gArPreActMs = now
    gArLastActionMs = now
    gArPreVia = "the screen's own BackButton (DefaultUIButton OnClick)"
    if arPressBackUnder(ov, why):
      okLog "autoRaid PRE-MENU: pressed " & gArPreVia & ", scoped to the " &
            "ACTIVE SettingsScreen subtree. PRESSED IS NOT DISMISSED -- the " &
            "readback is the next tick finding NO active SettingsScreen."
    else:
      warn "autoRaid PRE-MENU: the BackButton fallback did not press -- " &
           why & "."
    return

  if gArStep == ArNext2 and gArOffAwaitMs != 0'u64:
    # NEXT->offline-raid has been pressed and we are waiting for the show
    # EVENT. Do not press anything meanwhile: a second press here skips a
    # screen. Either the oracle fires (handled at the top of this body) or the
    # window lapses, and a lapse is ANNOUNCED, not swallowed.
    if now - gArOffAwaitMs < ArOffWaitMs: return
    gArOffAwaitMs = 0'u64
    var census = ""
    if not gArCensused:
      gArCensused = true
      census = arScreenCensus()
    warn "autoRaid: NEXT->offline-raid was pressed " &
         $(int(ArOffWaitMs div 1000'u64)) & " s ago and " &
         "MatchmakerOfflineRaidScreen::Show (uihooks site 0) has NOT fired, " &
         "so this host has NO evidence the offline raid screen came up. " &
         "Continuing to NEXT->insurance UNVERIFIED -- treat any raid entered " &
         "from here as unconfirmed." &
         (if census.len > 0: " ACTIVE:" & census else: "")
    gArLastPressed = nil
    arGoto(ArNext3)
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
      elif gArStep == ArNext2:
        if not uihBound(UihSiteOfflineRaid):
          # No oracle this session. Advance exactly as before -- but say that
          # the advance is UNVERIFIED rather than letting it read as a success.
          warn "autoRaid: pressed NEXT->offline-raid and advancing WITHOUT a " &
               "readback: uihooks site 0 is not bound this session, so " &
               "nothing here can confirm the offline raid screen came up."
          arGoto(ArNext3)
          return
        # Do NOT advance on the press. The screen-arrival oracle above advances
        # this step when `MatchmakerOfflineRaidScreen::Show` really fires; the
        # step's own timeout still bounds it if the event never comes.
        gArOffAwaitMs = now
        okLog "autoRaid: NEXT->offline-raid pressed. NOT advancing on the " &
              "press: the step advances when MatchmakerOfflineRaidScreen::" &
              "Show (uihooks site 0) fires, which is a readback that the " &
              "screen is really up. If that event never arrives this step " &
              "times out and says so."
      elif gArStep == ArNext3: arGoto(ArNext4)
      elif gArStep == ArNext4: arGoto(ArReady)
      else:
        okLog "autoRaid: READY pressed -- the raid scene is loading. Going " &
              "hands-off; this feature will not touch the UI again this session."
        arGoto(ArDone)
    return

  if gArStep == ArCharacter:
    let scr = arCharScreen()
    # (a) ALREADY PRESSED: assert the FINISHED STATE, which is a NEGATIVE --
    # no ACTIVE CharacterSelectionScreen anywhere. Never "the press returned
    # cleanly": a handler that returns normally is not proof it did anything.
    if gArCharPresses > 0:
      if scr == nil:
        gArCharAnswered = gArCharAnswered + 1
        okLog "autoRaid: READBACK -- no ACTIVE CharacterSelectionScreen " &
              "remains after pressing the slot titled \"" & gArChar &
              "\" (press " & $gArCharPresses & "). The character/mode screen " &
              "is answered; continuing to NEXT->location. Answered this " &
              "session: " & $gArCharAnswered & "."
        gArCharPresses = 0
        gArLastPressed = nil
        gArLastActionMs = now
        arGoto(ArNext1)
        return
      if now - gArCharPressedMs < ArCharSettleMs:
        return                                # still settling; do not re-press
      if gArCharPresses >= ArMaxCharPresses:
        var census = ""
        if not gArCensused:
          gArCensused = true
          census = arScreenCensus()
        arFail("step CHARACTER -- the slot titled \"" & gArChar &
               "\" was pressed " & $gArCharPresses & " times and an ACTIVE " &
               "CharacterSelectionScreen is STILL up after " &
               $int(now - gArCharPressedMs) & "ms, so the press ran and did " &
               "not advance the screen" &
               (if census.len > 0: ". ACTIVE:" & census else: ""))
        return
      # settled, still up, and presses remain: fall through and press again.
    if scr == nil:
      # (b) NO SCREEN. Not an error -- some flows may not show one. Wait the
      # grace window, then continue and SAY SO, rather than failing on a screen
      # that was never going to appear.
      if now - gArStepT0 > ArCharGraceMs:
        okLog "autoRaid: step CHARACTER -- no ACTIVE CharacterSelectionScreen " &
              "appeared within " & $(int(ArCharGraceMs div 1000'u64)) &
              " s of pressing PLAY. Nothing was pressed and nothing is " &
              "claimed; continuing to NEXT->location. If the selector IS on " &
              "screen, then it is not named `CharacterSelectionScreen` on " &
              "this build, and that is the thing to check."
        gArLastPressed = nil
        arGoto(ArNext1)
      return
    var nSlots = 0
    var nTitled = 0
    var titles = ""
    if arAnswerCharacterUnder(scr, nSlots, nTitled, titles):
      gArCharPresses = gArCharPresses + 1
      gArCharPressedMs = now
      gArLastActionMs = now
      okLog "autoRaid: step CHARACTER -- pressed the `Apply` of the slot " &
            "titled \"" & gArChar & "\" (" & $nSlots & " CharacterSlotView* " &
            "under the ACTIVE screen, " & $nTitled & " with a readable " &
            "Title). PRESSED IS NOT ANSWERED: the readback is the next tick " &
            "finding NO active CharacterSelectionScreen."
    elif now - gArCharLogMs > 5000'u64:
      gArCharLogMs = now
      info "autoRaid CHARACTER: an ACTIVE CharacterSelectionScreen is up, " &
           "slots=" & $nSlots & ", titled=" & $nTitled & ", titles=" &
           (if titles.len > 0: titles else: "<none readable>") & ", wanted=\"" &
           gArChar & "\" (`autoRaidCharacter`). Object NAMES are not titles " &
           "on this build, so the match is on the DISPLAYED text only."
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
  gArCharPresses = 0
  gArCharPressedMs = 0'u64
  gArCharLogMs = 0'u64
  gArCensused = false
  gArPreTries = 0
  gArPreActMs = 0'u64
  gArPreVia = "nothing"
  gArOffAwaitMs = 0'u64
  # Snapshot the show-event epoch NOW: an event from BEFORE this arming is not
  # evidence about this run, and consuming a stale one would resynchronise the
  # machine to a screen that is no longer up.
  gArOffEpoch = uihEpoch(UihSiteOfflineRaid)
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

proc arWantShowHook() =
  ## Declare the subscription to `MatchmakerOfflineRaidScreen::Show` (uihooks
  ## site 0). MUST run before the single `uihArm` pass -- a site nobody wanted
  ## is never patched. Wanted when `uxAutoRaid` is set OR the live inspector is
  ## on, because the inspector `raid` verb arms this machine on demand in
  ## sessions where the launch flag is off.
  if not gArOn and not gInspOn: return
  uihWant(UihSiteOfflineRaid)

proc arShowHookVerdict() =
  ## Read back whether it actually BOUND, after `uihArm`. Announced either way:
  ## without it this machine has no positive readback that a screen arrived and
  ## falls back to its per-step timeout, which is exactly the failure mode this
  ## change exists to remove.
  if not gArOn and not gInspOn: return
  if uihBound(UihSiteOfflineRaid):
    okLog "autoRaid: the screen-arrival oracle is LIVE -- " &
          "MatchmakerOfflineRaidScreen::Show @0x1788590 (uihooks site 0) is " &
          "bound, so NEXT->offline-raid advances on the show EVENT rather " &
          "than on a visibility timeout."
  else:
    warn "autoRaid: uihooks site 0 (MatchmakerOfflineRaidScreen::Show) did " &
         "NOT bind, so this session has no positive readback that the offline " &
         "raid screen arrived: NEXT->offline-raid falls back to its per-step " &
         "timeout. The reason is in the `uihooks:` lines; the usual causes " &
         "are a different game build or another detour having patched " &
         "0x1788590 first (a hook-ORDER problem)."

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
