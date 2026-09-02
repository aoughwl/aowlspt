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
  ArSideGraceMs   = 12000'u64   ## SIDE: how long to wait for the side selector's
                                ## SHOW EVENT after PLAY before concluding this
                                ## flow does not show one and continuing.
                                ## MEASURED 2026-09-02: pressing PLAY puts
                                ## `MatchMaker Side Selection Screen` (PMC or
                                ## SCAV) up, under the `Menu UI` root -- the step
                                ## after PLAY is NOT the location list, and it is
                                ## NOT the character/slot screen either.
  ArSideSettleMs  = 6000'u64    ## after pressing a side control, how long before
                                ## another press is allowed.
  ArMaxSidePresses = 2          ## presses of the side control, EVER. Then the
                                ## step refuses by name rather than mashing.
  ArMaxSideBtns   = 24          ## nodes collected per walk, for the name census
                                ## as much as for the match.
  ArSideDepth     = 6           ## descent under the side screen for containers.
  ArSideDeepDepth = 8           ## descent INSIDE a container (PMCs/Scavs).
                                ## MEASURED 2026-09-02: a depth-6 census from
                                ## the SCREEN listed [PMCs] and then 23 MODEL
                                ## nodes ([MenuPlayer][Mesh][USEC_head_Hugh] ..
                                ## [pistol_holster]), so the pressable control
                                ## is deeper than the walk reached and the cap
                                ## was spent on the character mesh. The
                                ## CONTAINER is the thing to walk, not the
                                ## screen.
  ArSideNextDepth = 6           ## descent from the side screen to its own
                                ## `ScreenDefaultButtons -> NextButton`, which
                                ## is at depth 2 (measured live).
  ArMaxSideNext   = 96          ## ACTIVE nodes examined for that search. Large
                                ## enough that a truncation is visibly AT the
                                ## cap in the refusal, rather than looking like
                                ## an absence.
  ArLocDepth      = 8           ## descent from the location screen to a tile's
                                ## `Button Panel -> AnimatedToggle` (depth 5
                                ## measured live).
  ArMaxTiles      = 96          ## ACTIVE nodes collected on that screen. There
                                ## is one tile per map plus the templates, so a
                                ## count at the cap is visible in the refusal.
  ArMaxSideConts  = 8           ## pmc/scav containers examined.
  ArMaxSideProbe  = 40          ## nodes GetComponent-probed INSIDE one
                                ## container. Bounded because each probe
                                ## allocates a managed string inside
                                ## GetComponent(String); this runs only while
                                ## the SIDE step is live -- a handful of ticks,
                                ## one per ArTickFrames frames -- and never in
                                ## a steady state.
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
  ArSide      = 10  ## after PLAY: the PMC/SCAV side selector
  ArPreMenu   = 11  ## before the menu: dismiss a screen overlaying MenuScreen
  ArScreen    = 12  ## GENERIC: advance whichever show-event screen is up

# ---------------------------------------------------------------------------
# THE GENERIC SCREEN TABLE.
#
# Every screen in this flow is advanced the same way and NOTHING ELSE WORKS:
# press THAT screen's own `ScreenDefaultButtons -> NextButton`, resolved from
# the receiver its own `::Show` handed us, then read back that the screen went
# INACTIVE and wait for the next screen's show event. This session produced the
# same 45-second refusal THREE times -- `NEXT->location`, then after SIDE, then
# `NEXT->insurance` -- and every one was the same mistake: hunting a NextButton
# across the scene roots for a screen nobody had handed us.
#
# So it is a TABLE, not another hand-written step. Adding the next screen in the
# chain is a row plus a uihooks site, and the driver below does not change.
#
# `practice` marks the one row that needs a pre-action: on the offline raid
# screen the practice/offline toggle decides whether the raid routes to the
# emulated backend at all, so its state is READ AND LOGGED before anything is
# pressed, and set only if it reads off.
const
  ArScrN = 3
  ArScrPracticeRow = 0        ## the offline raid screen, and only it

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
proc cPmnCallToggleSet(fn, toggle: Il2CppPtr; value, sendCallback: int32) {.
  importc: "aowl_pmn_call_toggle_set", nodecl.}
proc cPmnCallPointerClick(fn, button: Il2CppPtr) {.
  importc: "aowl_pmn_call_pointer_click", nodecl.}
proc cPmnCallShowInRaid(fn, menu: Il2CppPtr) {.
  importc: "aowl_pmn_call_show_in_raid", nodecl.}
proc cPmnOffDubButton(): int32 {.importc: "aowl_pmn_off_dub_button", nodecl.}
proc cPmnOffTabInteract(): int32 {.importc: "aowl_pmn_off_tab_interact", nodecl.}

const
  # The row name is the WHOLE doc comment on purpose: tools/idxbind.py reads it
  # as the row this index claims to address and fails the build if the C table
  # ever stops agreeing. RVAs, arities and prologues are in the header.
  PmnTSsClose = 0'i32   ## EFT.UI.Settings.SettingsScreen::Close
  PmnTToggleSet = 1'i32   ## UnityEngine.UI.Toggle::Set
  PmnTPointerClick = 2'i32   ## EFT.UI.TweenAnimatedButton::OnPointerClick
  PmnTShowInRaid = 3'i32   ## EFT.UI.MenuScreen::ShowInRaid

# ---- state (gArOn / gArMap are set in the flag-reading pass in aowlhost.nim) ----
var gArOn = false                  ## the `uxAutoRaid` flag; DEFAULT OFF
var gArOff = false                 ## self-disabled after faults / a timed-out step
var gArFaults = 0
## A FAULT BUDGET PER STEP, not one budget for the whole machine. MEASURED
## 2026-09-02: one PRE-MENU fault (which the retry then recovered from) plus two
## SIDE faults tripped the session-wide budget of three and switched the whole
## feature off, so a recovered fault in one step spent another step's budget.
## Sized ArFailed+1 so every step id indexes it.
var gArStepFaults: array[ArFailed + 2, int]
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
var gArSide = "pmc"                ## `autoRaidSide`: which side control to press
var gArSidePresses = 0             ## side presses this session
var gArSidePressedMs = 0'u64       ## when the side was pressed (readback clock)
var gArSideLogMs = 0'u64           ## rate limiter for the SIDE census line
var gArSideAnswered = 0            ## side screens this feature got past
var gArSideEpoch = 0               ## last seen uihooks site-3 epoch
var gArSideFires = 0               ## side-screen show events observed while armed
var gArSideTr: Il2CppPtr = nil     ## the live side screen's Transform, from the
                                   ## receiver the GAME handed us in RCX
var gArSideNamesLogged = false     ## the control-name census, once per session
## The rows. Parallel arrays rather than a tuple array: nimony's object/tuple
## literals in a module-level `var` are more trouble than three arrays, and the
## indices are checked by `arScrSite` below, which is the ONLY place that maps a
## row to a site.
var gArScrEpoch: array[ArScrN, int]
var gArScrTr: Il2CppPtr = nil      ## receiver of the screen currently being advanced
var gArScrIdx = -1                 ## which row that is, -1 = none
var gArScrPressed = false          ## its NextButton has been pressed
var gArScrMs = 0'u64               ## when (readback clock)
var gArScrLogMs = 0'u64
var gArScrDone = 0                 ## screens advanced this session
var gArPracticeChecked = false     ## the toggle state has been read+logged
var gArLocEpoch = 0                ## last seen uihooks site-4 epoch
var gArLocFires = 0                ## location-screen show events while armed
var gArLocTr: Il2CppPtr = nil      ## the live location screen's Transform
var gArLocPressed = false          ## the wanted map tile was pressed
var gArLocPressedMs = 0'u64        ## when (readback clock)
var gArLocNextDone = false         ## this screen's own NextButton was pressed
var gArLocNextMs = 0'u64
var gArLocLogMs = 0'u64            ## rate limiter for the tile census
var gArLocNamesLogged = false      ## the tile-name census, once per session
var gArSideNextDone = false        ## this screen's own NextButton was pressed
var gArSideNextMs = 0'u64          ## when it was pressed (readback clock)
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
var gArPreAttempted = false        ## PRE-MENU has acted at least once

## WHERE THE GUARDED BODY WAS WHEN IT FAULTED.
##
## MEASURED 2026-09-02: `autoRaid: the guarded tick body faulted (1 of 3)` fired
## during PRE-MENU, moments before the BackButton press succeeded -- and the
## line named neither the step nor the operation, so it cost a third of the
## session's fault budget and told nobody anything. A fault that cannot say
## where it was is a fault that will be paid for again.
##
## An INT, deliberately: assigning a string literal to a module-level var
## allocates, and this is set several times per tick on the live path. The text
## is produced only when a fault is actually being reported.
var gArCrumb = 0

proc arCrumbName(c: int): string =
  case c
  of 0:  "tick entry"
  of 1:  "reading the offline-raid show epoch (uihooks site 0)"
  of 2:  "reading the side-selector show epoch (uihooks site 3)"
  of 3:  "WAIT-MENU: arFindPlay (walking roots for MenuScreen/PlayButton)"
  of 4:  "WAIT-MENU: arOverlayScreen (looking for an ACTIVE SettingsScreen)"
  of 5:  "WAIT-MENU: arChatActive (ChatScreen census, never pressed)"
  of 6:  "WAIT-MENU: arScreenCensus (the refusal census)"
  of 7:  "WAIT-MENU: pressing the MenuScreen PlayButton"
  of 8:  "PRE-MENU: arFindPlay (the finished-state readback)"
  of 9:  "PRE-MENU: arOverlayScreen"
  of 10: "PRE-MENU: arScreenCensus"
  of 11: "PRE-MENU: pressing the SettingsScreen BackButton"
  of 12: "PRE-MENU: calling SettingsScreen::Close"
  of 13: "SIDE: arSideActive (is the side screen still up)"
  of 14: "SIDE: walking the pmc/scav containers and pressing"
  of 15: "SELECT-MAP: the side-screen INACTIVE readback"
  of 16: "SELECT-MAP: arSelectMap (map tiles)"
  of 17: "NEXT: arFindNext (looking for an active NextButton)"
  of 18: "NEXT: pressing the NextButton"
  of 19: "the step timeout census"
  of 20: "SIDE: pressing this screen's own NextButton"
  of 21: "SIDE: breadth-first walk for the pmc/scav containers"
  of 22: "SIDE: breadth-first walk INSIDE the wanted side's scope"
  of 23: "SIDE: GetComponent probe on a candidate node"
  of 24: "SIDE: reading DefaultUIButton._text @0xB8"
  of 25: "SIDE: pressing the side control"
  of 26: "PRE-MENU: walking the SettingsScreen subtree for BackButton"
  of 27: "PRE-MENU: GetComponent probe on a back-control candidate"
  of 28: "PRE-MENU: firing the BackButton OnClick"
  of 29: "SELECT-MAP: breadth-first walk of the location screen for tiles"
  of 30: "SELECT-MAP: reading a tile's Label TMP text"
  of 31: "SELECT-MAP: setting the map tile's AnimatedToggle"
  of 32: "SELECT-MAP: pressing this screen's own NextButton"
  of 33: "SELECT-MAP: the location-screen INACTIVE readback"
  of 34: "reading the location-screen show epoch (uihooks site 4)"
  of 35: "SCREEN-NEXT: walking the offline raid screen for the practice toggle"
  of 36: "SCREEN-NEXT: setting the practice toggle"
  of 37: "reading the generic screen table's show epochs"
  of 38: "SCREEN-NEXT: BFS for this screen's own NextButton"
  of 39: "SCREEN-NEXT: pressing this screen's own NextButton"
  of 40: "SCREEN-NEXT: the screen-INACTIVE readback"
  else:  "unknown (" & $c & ")"

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
  of ArSide:      "SIDE"
  of ArPreMenu:   "PRE-MENU"
  of ArScreen:    "SCREEN-NEXT"
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
proc arSetToggleComp(comp: Il2CppPtr): bool =
  ## `UnityEngine.UI.Toggle::Set(true, true)` @0x55BA450 -- the game's own way
  ## to turn a toggle on, byte-verified against the startup prologue snapshot.
  ##
  ## THIS REPLACES FIRING A UNITYEVENT AT +0x100 ON A TOGGLE, WHICH KILLED THE
  ## CLIENT. MEASURED 2026-09-02: `EFT.UI.AnimatedToggle` derives from
  ## `UnityEngine.UI.Toggle`, whose 0x100 is `toggleTransition`, an ENUM --
  ## `onValueChanged` is at 0x118 and `m_IsOn` at 0x120 (tools/fldoff.py). So
  ## the generic `arOnClickOff` slot read a small integer, which is not null,
  ## not a GameObject and not a known klass -- it passes every guard `arPress`
  ## has -- and called it as a UnityEvent. Two deterministic access violations
  ## at step SIDE, on the first frame the toggle was found.
  result = false
  if comp == nil or not iUnityAlive(comp): return
  let fn = cPmnFn(PmnTToggleSet)
  if fn == nil:
    warn "autoRaid: Toggle::Set @0x" & hexOf(uint64(cPmnRva(PmnTToggleSet))) &
         " did NOT verify against the startup prologue snapshot on this " &
         "build; REFUSING to call it. The toggle was NOT pressed, and the " &
         "old +0x100 UnityEvent route is not a fallback -- it is the bug."
    return false
  cPmnCallToggleSet(fn, comp, 1'i32, 1'i32)
  result = true

proc arDubButton(comp: Il2CppPtr): Il2CppPtr =
  ## `EFT.UI.DefaultUIButton._button` @0x108 -- the `TweenAnimatedButton` that
  ## actually receives the click. Offset from tools/fldoff.py, never guessed.
  result = nil
  if comp == nil: return
  let off = cPmnOffDubButton()
  if not duOk(comp, off + 8'i32): return
  let b = cReadPtrAt(comp, off)
  if b == nil or not duOk(b, 0x70'i32) or not iUnityAlive(b): return
  result = b

proc arTabInteractable(btn: Il2CppPtr; ok: var bool): bool =
  ## `EFT.UI.TweenAnimatedButton._interactable` @0x68. `ok` says whether the
  ## read happened; a caller that ignores it would be reading "not clickable"
  ## out of a failure to look.
  result = false
  ok = false
  if btn == nil or not duOk(btn, 0x70'i32): return
  ok = true
  let a = cast[Il2CppPtr](cast[uint64](btn) + uint64(cPmnOffTabInteract()))
  result = (cReadI32At(a) and 0xFF'i32) != 0'i32

proc arClickDefaultUIButton(comp: Il2CppPtr; why: var string): bool =
  ## PRESS THE WAY A PLAYER DOES: `TweenAnimatedButton::OnPointerClick`
  ## @0x14359B0, the button's OWN entry point, instead of firing
  ## `DefaultUIButton.OnClick` @0x120 behind it.
  ##
  ## DERIVED, not guessed -- the 16 bytes of that function are
  ##   cmp byte [rcx+0x68],0 / je / mov rcx,[rcx+0x70] / test / je / invoke
  ## so it gates on `_interactable`, loads its `Action OnClick` and invokes it,
  ## and NEVER READS the PointerEventData in RDX (hence NULL is safe). See
  ## abi/aowlspt_premenu.h row [2] for the full chain and the disassembly.
  ##
  ## MEASURED 2026-09-02: firing the UnityEvent at +0x120 directly reaches the
  ## same handler but skips this gate, and left the profile/mode screen
  ## HALF-TRANSITIONED with neither card clickable.
  result = false
  why = ""
  let btn = arDubButton(comp)
  if btn == nil:
    why = "the DefaultUIButton has no readable `_button` (TweenAnimatedButton) " &
          "at +0x" & hexOf(uint64(cPmnOffDubButton())) & ", so the player's " &
          "own click entry point cannot be reached"
    return false
  var ok = false
  let inter = arTabInteractable(btn, ok)
  if not ok:
    why = "could not read `_interactable` on the TweenAnimatedButton, so " &
          "whether the control is clickable at all is UNKNOWN -- which is not " &
          "the same as false, and nothing was pressed"
    return false
  if not inter:
    why = "the control's TweenAnimatedButton reads `_interactable` = FALSE. " &
          "Its own OnPointerClick would return without invoking anything, so " &
          "pressing it is provably a no-op and NOTHING WAS PRESSED"
    return false
  let fn = cPmnFn(PmnTPointerClick)
  if fn == nil:
    why = "TweenAnimatedButton::OnPointerClick @0x" &
          hexOf(uint64(cPmnRva(PmnTPointerClick))) & " did NOT verify against " &
          "the startup prologue snapshot on this build; REFUSING to call it"
    return false
  cPmnCallPointerClick(fn, btn)
  return true

proc arPress(node: Il2CppPtr; compType: string): bool =
  result = false
  if node == nil: return
  # RE-VALIDATE AT THE POINT OF USE. The node was found on an earlier line, and
  # between the walk and here the screen may have been torn down: a destroyed
  # object stays READABLE with `m_CachedPtr` zeroed (fact #182), so `duOk`
  # alone hands back a corpse and the GetComponent below faults inside Unity.
  if not duOk(node, 0x20'i32) or not iUnityAlive(node): return
  var comp: Il2CppPtr = nil
  var w = ""
  if not iVisComponent(node, compType, comp, w) or comp == nil: return
  # A TOGGLE IS SET, NEVER INVOKED. Both call sites -- the side selector and the
  # map tiles -- go through here, so the fix lands in one place.
  if compType == "AnimatedToggle":
    return arSetToggleComp(comp)
  # A DefaultUIButton is clicked THROUGH ITS OWN BUTTON, not by firing its
  # UnityEvent behind it. The direct invoke stays below as an announced
  # fallback for the case where `_button` is not reachable.
  if compType == "DefaultUIButton":
    var why = ""
    if arClickDefaultUIButton(comp, why):
      return true
    if why.len > 0:
      warn "autoRaid: the player's click path (TweenAnimatedButton::" &
           "OnPointerClick) was not usable on this DefaultUIButton -- " & why &
           ". Falling back to firing DefaultUIButton.OnClick@+0x120 directly, " &
           "which is the WEAKER path: it reaches the same handler but skips " &
           "the button's own interactable gate."
  let off = arOnClickOff(compType)            # 0x120 for DefaultUIButton, else 0x100
  if not duOk(comp, off + 8'i32) or not iUnityAlive(comp): return
  let ev = cReadPtrAt(comp, off)
  if ev == nil or iIsGameObject(ev) or iIsKnownKlass(cast[uint64](ev)): return
  # WHAT THIS POINTER IS, BEFORE IT IS CALLED. MEASURED 2026-09-02: PRE-MENU's
  # BackButton press faulted ONCE per session inside this invoke and then
  # worked on the retry, which is the signature of a control read while it is
  # being built or torn down.
  #
  # A managed object's FIRST QWORD is its Il2CppClass*, so an object that is
  # really there has a readable klass pointer with a readable name field. This
  # checks the SHAPE of that -- readable klass, and the klass's own first
  # pointer readable -- rather than asserting an identity it cannot prove:
  # `iIsKnownKlass` only knows klasses this session has already SEEN, so
  # requiring it here would refuse every first press. Stated plainly: this is a
  # FLOOR, not proof. It cannot certify that `ev` is a UnityEvent; it can and
  # does reject a value that is not a live managed object at all, which is the
  # class of value that faults.
  if not duOk(ev, 0x40'i32):
    warn "autoRaid: REFUSING to invoke the OnClick at +0x" & hexOf(uint64(off)) &
         " on a " & compType & ": the event pointer (0x" &
         hexOf(cast[uint64](ev)) & ") is not readable for 0x40 bytes, so it " &
         "is not a live managed object. Nothing was called."
    return
  let evKlass = cReadPtrAt(ev, 0'i32)
  if evKlass == nil or not duOk(evKlass, 0x40'i32):
    warn "autoRaid: REFUSING to invoke the OnClick at +0x" & hexOf(uint64(off)) &
         " on a " & compType & ": the object at 0x" & hexOf(cast[uint64](ev)) &
         " has no readable Il2CppClass* in its first qword (read 0x" &
         hexOf(cast[uint64](evKlass)) & "), so it is not a live managed " &
         "object. Nothing was called. This is the guard the once-per-session " &
         "BackButton fault asked for -- a FLOOR, not proof that it is a " &
         "UnityEvent."
    return
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
# THE SIDE SELECTOR (PMC / SCAV) -- the screen the main-menu PLAY leads to.
#
# MEASURED 2026-09-02, live, on the previous build of this file. autoraid
# pressed PLAY at 1:24, then refused, and the census it prints on a refusal said
# what was really on screen:
#
#   Common UI active(depth<=2)=2: [Common UI][ChatScreen]
#   Menu UI   active(depth<=2)=3: [UI][MatchMaker Side Selection Screen]
#                                 [Operation Queue Indicator]
#
# So the step after PLAY is `EFT.UI.Matchmaker.MatchMakerSideSelectionScreen`
# -- choose PMC or SCAV, then NEXT. Two earlier readings were WRONG and are
# recorded here so nobody re-derives them:
#
#   * the "SELECT YOUR CHARACTER / PVE ZONE" screenshot was THIS screen, not
#     `CharacterSelectionScreen`. `CharacterSelectionScreen` is the BOOT-time
#     slot screen that modeskip answers, and it does not come back after PLAY.
#   * which is also why modeskip's `ShowSlot` postfix never fired for it. The
#     event was not missed; the screen was never shown.
#
# The previous cut of this step hunted an ACTIVE `CharacterSelectionScreen` and
# grace-skipped after 12 s having found nothing, which is exactly what a poll
# looking for the wrong thing does: it cannot tell "not there yet" from "not
# this screen at all".
#
# SO THIS STEP IS EVENT-DRIVEN, and gets the screen from the game itself:
#   `MatchMakerSideSelectionScreen::Show(controller)` @0x1790180 -- UNIQUE,
#   16-byte prologue-verified, 17-byte steal whose only relative operand is a
#   RIP-relative `cmp` (byte-for-byte the same shape as the offline-raid site
#   already in that table) -- is uihooks SITE 3. Its POSTFIX hands us RCX, the
#   live screen, so the screen is never searched for by name; `uihSelf`
#   re-validates it and `iToTransform` gets onto its Transform.
#
# The side CONTROL is then matched by GameObject NAME (`autoRaidSide`, default
# "pmc"), and this is stated rather than hidden: the captions on this screen are
# `DefaultUIButton._text`, NOT TMP text, so the displayed-text match the map
# tiles use is not available without a field offset this host has not measured.
# Every ACTIVE control name under the screen is logged once, so the next run
# turns the names into a measured fact instead of a guess in the code.
#
# The screen's own NEXT is NOT pressed here: that is the existing NEXT->location
# step, unchanged. The finished state is asserted in two halves, both logged --
# the press, and then the side screen going INACTIVE, checked on entry to
# SELECT-MAP -- and the raid path's later readback is site 0,
# `MatchmakerOfflineRaidScreen::Show`.
# ---------------------------------------------------------------------------
proc arCollectBFS(root: Il2CppPtr; depth: int; budget: var int;
                  deadline: uint64; into: var seq[Il2CppPtr]; cap: int;
                  skip: string) =
  ## TRUE level-by-level breadth-first: EVERY node of level N is visited before
  ## ANY node of level N+1, using `into` itself as the queue.
  ##
  ## WHY THIS EXISTS ALONGSIDE `arCollectActiveBF`, WHICH IS ALSO "BREADTH
  ## FIRST". MEASURED 2026-09-02: the other one is breadth-per-node -- it takes
  ## a whole level, then RECURSES into the first child, which is depth-first one
  ## level down. Under `PMCs` that is fatal in exactly the same way the fully
  ## depth-first version was: level 1 gives [PMCPlayerMV][AnimatedToggleSpawner]
  ## [Button][ScavPlayerMV][RandomToggleSpawner], and then the recursion dives
  ## into `PMCPlayerMV` -- the character MODEL -- and spends the 40-node cap in
  ## its mesh before ever descending into `AnimatedToggleSpawner`. The live run
  ## reported exactly that: `1 node(s) carrying a control ... [Button Button]`,
  ## with the `AnimatedToggle` one level down never collected.
  ##
  ## A real BFS cannot do that: `AnimatedToggle` is at level 2 and every level-2
  ## node is visited before any level-3 mesh node.
  if root == nil or depth <= 0 or budget <= 0 or cap <= 0: return
  let start = into.len
  var q: seq[Il2CppPtr] = @[]
  q.add root
  var head = 0
  var levelEnd = 1
  var lvl = 0
  while head < q.len and lvl < depth and into.len - start < cap and budget > 0:
    let node = q[head]
    head = head + 1
    var n = 0
    if duOk(node, 0x20'i32) and iChildCount(node, n):
      var j = 0
      while j < n and j < ArFanout and into.len - start < cap and budget > 0:
        let c = iChildAt(node, j)
        if c != nil and duOk(c, 0x20'i32):
          budget = budget - 1
          if (budget and 31) == 0 and cNowMs() > deadline:
            budget = 0
            return
          let a = iActiveInHierarchy(c)
          if a[0] and a[1] and
             (skip.len == 0 or not iContains(iLower(iObjName(c)), skip)):
            into.add c
            q.add c
        j = j + 1
    if head >= levelEnd:
      levelEnd = q.len
      lvl = lvl + 1

proc arFindActiveNamedBFS(root: Il2CppPtr; name: string; depth, cap: int;
                          visited: var int; names: var string): Il2CppPtr =
  ## The ACTIVE node named `name` under `root`, found LEVEL BY LEVEL, reporting
  ## how many nodes it examined and what it saw.
  ##
  ## WHY NOT `arWalkActive`. MEASURED 2026-09-02: the side selector's own
  ## `NextButton` is at DEPTH 2 under the site-3 receiver
  ## (`ScreenDefaultButtons -> NextButton`, confirmed live with
  ## `find NextButton <receiver> 4000` -> HIT, 558 nodes, EXHAUSTIVE, and
  ## `assert-active` -> PASS), and `arWalkActive` still returned nil eight times
  ## in a row. It takes each level breadth-first but then RECURSES into child 0,
  ## which under this screen is `PMCs` -- the character MODEL -- so it spends
  ## its 120 ms in-frame slice down there and poisons its own budget before it
  ## ever reaches the sibling `ScreenDefaultButtons`. The inspector's `find`
  ## does not hit this because it auto-resumes across FRAMES; a host walk gets
  ## one slice, so total node count says nothing about whether it fits.
  ##
  ## A real BFS cannot fail that way: level 2 is fully examined before any
  ## level-3 mesh node is touched. This is the same lesson as `arCollectBFS`,
  ## and it is now applied to the by-NAME search as well as the collect.
  result = nil
  visited = 0
  names = ""
  if root == nil or name.len == 0: return
  var nodes: seq[Il2CppPtr] = @[]
  var b = ArNodeBudget
  arCollectBFS(root, depth, b, cNowMs() + ArWalkMs, nodes, cap, "")
  visited = nodes.len
  var i = 0
  while i < nodes.len:
    let nm = iObjName(nodes[i])
    if nm.len > 0 and names.len < 500:
      names = names & "[" & nm & "]"
    if result == nil and nm == name:
      result = nodes[i]
    i = i + 1

proc arCollectActiveBF(t: Il2CppPtr; depth: int; budget: var int;
                       deadline: uint64; into: var seq[Il2CppPtr]; cap: int;
                       skip: string) =
  ## Every ACTIVE node under `t`, BREADTH BEFORE DEPTH, skipping any subtree
  ## whose name contains `skip` (lowercased; "" skips nothing).
  ##
  ## THE BREADTH ORDER IS THE WHOLE FIX HERE, not a preference. MEASURED
  ## 2026-09-02: the depth-first version of this walk, capped at 24 nodes,
  ## reported ZERO pressable nodes under the side selector -- because `PMCs`'
  ## FIRST child is `PMCPlayerMV`, the character MODEL, and a depth-first walk
  ## spends the entire cap inside its mesh before it ever reaches the sibling
  ## `AnimatedToggleSpawner` two levels down. The live tree (inspector, on the
  ## parked client) is
  ##   PMCs -> [PMCPlayerMV] [AnimatedToggleSpawner -> AnimatedToggle] [Button]
  ##           [ScavPlayerMV -> [AnimatedToggleSpawner] [Button]]
  ##           [RandomToggleSpawner -> RandomToggle]
  ## so the controls are shallow and the model is deep. Breadth-first finds them
  ## in the first two levels; depth-first cannot find them at all. This is the
  ## same lesson `arWalkActive` and `arCollectChildren` already carry.
  ##
  ## `skip` is how one side is chosen without guessing: BOTH sides live under
  ## `PMCs`, and the Scav one is inside a `ScavPlayerMV` subtree, so "the PMC
  ## control" is "the first control under PMCs that is NOT under a scav node".
  if t == nil or depth <= 0 or budget <= 0 or into.len >= cap: return
  var n = 0
  if not iChildCount(t, n): return
  # Pass 1 -- breadth.
  var i = 0
  while i < n and i < ArFanout and budget > 0 and into.len < cap:
    let c = iChildAt(t, i)
    if c != nil and duOk(c, 0x20'i32):
      budget = budget - 1
      if (budget and 31) == 0 and cNowMs() > deadline:
        budget = 0
        return
      let a = iActiveInHierarchy(c)
      if a[0] and a[1]:
        if skip.len == 0 or not iContains(iLower(iObjName(c)), skip):
          into.add c
          if into.len >= cap: return
    i = i + 1
  # Pass 2 -- depth, only once the whole level has been taken.
  i = 0
  while i < n and i < ArFanout and budget > 0 and into.len < cap:
    let c = iChildAt(t, i)
    if c != nil and duOk(c, 0x20'i32):
      let a = iActiveInHierarchy(c)
      if a[0] and a[1] and
         (skip.len == 0 or not iContains(iLower(iObjName(c)), skip)):
        arCollectActiveBF(c, depth - 1, budget, deadline, into, cap, skip)
    i = i + 1

proc arCollectAllActive(t: Il2CppPtr; depth: int; budget: var int;
                        deadline: uint64; into: var seq[Il2CppPtr]; cap: int) =
  ## Breadth-first, no subtree skipped. Kept as the name the census callers use.
  arCollectActiveBF(t, depth, budget, deadline, into, cap, "")

proc arSideScreen(): Il2CppPtr =
  ## The live side selector, as a TRANSFORM -- obtained from the RECEIVER THE
  ## GAME HANDED US in RCX at `MatchMakerSideSelectionScreen::Show`, never by a
  ## name search. `uihSelf` re-validates the pointer on the way out (a destroyed
  ## screen stays readable with `m_CachedPtr` zeroed, fact #182), and
  ## `iToTransform` is safe on a component or a transform alike.
  result = nil
  let self = uihSelf(UihSiteSideSelect)
  if self == nil: return
  let tr = iToTransform(self)
  if tr == nil or not duOk(tr, 0x20'i32): return
  result = tr

proc arSideActive(): bool =
  ## Is that screen still on screen? The FINISHED STATE for this step is the
  ## NEGATIVE of this, which is the only form that can fail.
  let tr = arSideScreen()
  if tr == nil: return false
  let a = iActiveInHierarchy(tr)
  result = a[0] and a[1]

proc arBtnCaption(comp: Il2CppPtr): string =
  ## `DefaultUIButton._text` @0xB8 -- THE TEXT A PERSON READS on this control.
  ## The offset is from `tools/fldoff.py field DefaultUIButton _text` -> 0xb8,
  ## never guessed. Guarded exactly as `splTmpText` guards `m_text`: a
  ## KNOWN-KLASS value in that slot is type confusion, not a String, and must
  ## not be read as one. "" means NOT READABLE, and the caller must never treat
  ## that as a caption.
  result = ""
  gArCrumb = 24
  if comp == nil or not duOk(comp, 0xC0'i32): return
  let sp = cReadPtrAt(comp, 0xB8'i32)
  if sp != nil and not iIsKnownKlass(cast[uint64](sp)) and duOk(sp, 0x18'i32):
    result = suiReadString(sp)

proc arButtonOn(node: Il2CppPtr; comp: var Il2CppPtr): string =
  ## Which pressable component this node carries, "" for none.
  ##
  ## THE THREE KLASS NAMES ARE MEASURED, NOT GUESSED. Read live off the parked
  ## side-selection screen with the inspector's `components` verb, 2026-09-02:
  ##
  ##   the toggle node   (`AnimatedToggle`, under `AnimatedToggleSpawner`)
  ##       UnityEngine.RectTransform, CanvasRenderer, UI.Image, Animator,
  ##       EFT.UI.AnimatedToggle, EFT.UI.UISpawnableToggle,
  ##       UI.HorizontalLayoutGroup, UI.LayoutElement
  ##   the `Button` node under each side
  ##       UnityEngine.RectTransform, CanvasRenderer,
  ##       **UnityEngine.UI.Button**, EventSystems.EventTrigger
  ##   `NextButton` (under the sibling `ScreenDefaultButtons`)
  ##       UnityEngine.RectTransform, **EFT.UI.DefaultUIButton**,
  ##       DefaultUIButtonAnimation, TweenAnimatedButton, layout components
  ##
  ## So the previous probe -- DefaultUIButton then AnimatedToggle -- could only
  ## ever have matched the toggle, and the earlier run reported ZERO because the
  ## depth-first walk never reached it. `UnityEngine.UI.Button` is a THIRD
  ## klass this file had never looked for, and it is what the side's `Button`
  ## node carries.
  ##
  ## GetComponent here is the STRING overload, which Unity matches by SHORT type
  ## name, so `AnimatedToggle` finds `EFT.UI.AnimatedToggle` and `Button` finds
  ## `UnityEngine.UI.Button` -- the short names above, not the namespaces.
  result = ""
  comp = nil
  var w = ""
  if iVisComponent(node, "AnimatedToggle", comp, w) and comp != nil:
    return "AnimatedToggle"
  comp = nil
  if iVisComponent(node, "DefaultUIButton", comp, w) and comp != nil:
    return "DefaultUIButton"
  comp = nil
  if iVisComponent(node, "Button", comp, w) and comp != nil:
    return "Button"
  comp = nil

proc arPressUnityButton(comp: Il2CppPtr): bool =
  ## `UnityEngine.UI.Button::Press` @0x539A7A0 -- THE GAME'S OWN CLICK PATH. It
  ## re-checks IsActive and IsInteractable itself and then fires m_OnClick,
  ## exactly as a real click does, which is why the inspector's `click` uses it.
  ##
  ## It is used INSTEAD of `arPress` for this klass on purpose: `arOnClickOff`
  ## returns the generic 0x100 for everything that is not a DefaultUIButton, and
  ## firing a UnityEvent read at a guessed offset on a klass this file has never
  ## handled is precisely the blind write the host does not do. Resolved through
  ## `iNavFind`, so it is byte-verified against the startup prologue snapshot
  ## and refused if it does not match.
  result = false
  if comp == nil or not iUnityAlive(comp): return
  var fn: Il2CppPtr = nil
  var rva = 0'u32
  if not iNavFind("Button::Press", fn, rva) or fn == nil: return
  iMark("autoRaid: Button::Press", comp)
  discard cInspUP(fn, comp, nil)
  result = true

proc arPressAny(node, comp: Il2CppPtr; compType: string): bool =
  ## Press `node` by whichever route its klass calls for. Three klasses, three
  ## routes, each measured:
  ##   EFT.UI.DefaultUIButton    OnClick UnityEvent @+0x120  (arPress)
  ##   EFT.UI.AnimatedToggle     Toggle::Set(true,true)      (arPress -> Set)
  ##   UnityEngine.UI.Button     Button::Press @0x539A7A0    (the game's path)
  ## There is no generic route, because the generic route is what faulted.
  if compType == "Button":
    return arPressUnityButton(comp)
  result = arPress(node, compType)

proc arPressSideUnder(scr: Il2CppPtr; want: string; nSeen: var int;
                      names: var string; why: var string): bool =
  ## Press the control for the wanted side on the live side-selection screen.
  ##
  ## THE STRUCTURE, read off the live client with the inspector (`tree`,
  ## 2026-09-02) rather than guessed:
  ##
  ##   MatchMaker Side Selection Screen
  ##     +- PMCs                      <- the container for BOTH sides
  ##     |    +- PMCPlayerMV          <- the PMC character MODEL (deep, huge)
  ##     |    +- AnimatedToggleSpawner -> AnimatedToggle   <- the PMC control
  ##     |    +- Button                                     <- and its Button
  ##     |    +- ScavPlayerMV                              <- the SCAV side,
  ##     |    |    +- AnimatedToggleSpawner                    NESTED INSIDE
  ##     |    |    +- Button                                   the PMC container
  ##     |    +- RandomToggleSpawner -> RandomToggle
  ##     +- ScreenDefaultButtons -> NextButton, BackButton
  ##
  ## So "the PMC control" cannot be found by a name containing "pmc" (the
  ## controls are called `AnimatedToggle` and `Button`) and cannot be found by a
  ## caption either (they carry no `DefaultUIButton`, so there is no `_text`).
  ## It is a STRUCTURAL fact: the PMC control is the first control under `PMCs`
  ## that is NOT inside a `scav` subtree, and the SCAV control is the first one
  ## inside the `scav` subtree. That is what the `skip` argument of
  ## `arCollectActiveBF` expresses, and it is why the walk must be breadth-first.
  result = false
  nSeen = 0
  names = ""
  why = ""
  if scr == nil:
    why = "no live side screen"
    return false

  # Phase 1 -- the container(s), breadth-first from the screen.
  var all: seq[Il2CppPtr] = @[]
  var b0 = ArNodeBudget
  gArCrumb = 21
  arCollectAllActive(scr, ArSideDepth, b0, cNowMs() + ArWalkMs, all,
                     ArMaxSideBtns)
  var cont: Il2CppPtr = nil
  var i = 0
  while i < all.len:
    let nm = iLower(iObjName(all[i]))
    if nm.len > 0 and (iContains(nm, "pmc") or iContains(nm, "scav")):
      cont = all[i]
      break
    i = i + 1
  if cont == nil:
    why = "no ACTIVE node under the live side screen has a name mentioning " &
          "`pmc` or `scav`, so there is no container to walk into. NOTHING " &
          "WAS PRESSED -- this is a refusal, not a miss"
    return false

  # Phase 2 -- narrow to the wanted SIDE inside that container.
  var scope = cont
  var skip = ""
  let wantScav = iContains(want, "scav")
  if wantScav:
    # The scav side is a NESTED subtree; find it and search only there.
    var inner: seq[Il2CppPtr] = @[]
    var b1 = ArNodeBudget
    arCollectAllActive(cont, ArSideDeepDepth, b1, cNowMs() + ArWalkMs, inner,
                       ArMaxSideProbe)
    var found: Il2CppPtr = nil
    var j = 0
    while j < inner.len:
      if iContains(iLower(iObjName(inner[j])), "scav"):
        found = inner[j]
        break
      j = j + 1
    if found == nil:
      why = "wanted the SCAV side but no ACTIVE node named `*scav*` exists " &
            "under the container. NOTHING WAS PRESSED"
      return false
    scope = found
  else:
    # The PMC side is everything under the container EXCEPT the scav subtree.
    skip = "scav"

  # Phase 3 -- the first node in that scope that CARRIES a control, breadth
  # first, every candidate reported with the klass that matched and (where the
  # klass has one) the caption a person reads.
  var nodes: seq[Il2CppPtr] = @[]
  var b2 = ArNodeBudget
  nodes.add scope                             # the scope itself may carry it
  gArCrumb = 22
  arCollectBFS(scope, ArSideDeepDepth, b2, cNowMs() + ArWalkMs, nodes,
               ArMaxSideProbe, skip)
  var hit: Il2CppPtr = nil
  var hitComp: Il2CppPtr = nil
  var hitType = ""
  var ni = 0
  while ni < nodes.len:
    var comp: Il2CppPtr = nil
    gArCrumb = 23
    let ct = arButtonOn(nodes[ni], comp)
    if ct.len > 0:
      nSeen = nSeen + 1
      let nm = iObjName(nodes[ni])
      let cap = (if ct == "DefaultUIButton": arBtnCaption(comp) else: "")
      if names.len < 620:
        names = names & "[" & nm & " " & ct &
                (if cap.len > 0: " caption=" & cap else: "") & "]"
      # PREFER THE TOGGLE. It is the control the screen's own spawner created
      # for this side (EFT.UI.AnimatedToggle + EFT.UI.UISpawnableToggle, the
      # same family as the settings tabs); the bare UnityEngine.UI.Button
      # alongside it is taken only if no toggle is found.
      if ct == "AnimatedToggle" and (hit == nil or hitType != "AnimatedToggle"):
        hit = nodes[ni]
        hitComp = comp
        hitType = ct
      elif hit == nil:
        hit = nodes[ni]
        hitComp = comp
        hitType = ct
    ni = ni + 1

  if hit == nil:
    why = "walked the " & (if wantScav: "`scav` subtree" else: "`pmc` " &
          "container with `scav` subtrees EXCLUDED") & " breadth-first and " &
          "found NO node carrying an AnimatedToggle, a DefaultUIButton or a " &
          "UnityEngine.UI.Button (" & $nodes.len & " active node(s) probed, " &
          "cap " & $ArMaxSideProbe & "). NOTHING WAS PRESSED"
    return false
  gArCrumb = 25
  if arPressAny(hit, hitComp, hitType):
    okLog "autoRaid SIDE: pressed the " & hitType & " on `" &
          iObjName(hit) & "` for side \"" & want & "\", chosen STRUCTURALLY " &
          "(the control under the container that is " &
          (if wantScav: "INSIDE the scav subtree" else: "NOT inside the scav " &
           "subtree") & "), because these controls have neither a matching " &
          "name nor a caption to match on. Candidates: " & names
    return true
  why = "the " & hitType & " on `" & iObjName(hit) & "` was found but could " &
        "not be pressed" &
        (if hitType == "Button":
           " (UnityEngine.UI.Button::Press did not verify against the startup " &
           "prologue snapshot, or the component's native half is null)"
         else: " (its OnClick UnityEvent could not be resolved and validated)")

proc arLabelUnderName(node: Il2CppPtr; name: string; depth: int): string =
  ## The TMP text of the first descendant named `name`, found LEVEL BY LEVEL.
  ## "" is NOT FOUND or NOT READABLE and must never be treated as a match -- an
  ## empty string compares equal to nothing useful, which is how a check that
  ## cannot fail gets written.
  result = ""
  var hits: seq[Il2CppPtr] = @[]
  var b = ArNodeBudget
  arCollectBFS(node, depth, b, cNowMs() + ArWalkMs, hits, 24, "")
  var i = 0
  while i < hits.len:
    if iObjName(hits[i]) == name:
      let tmp = splTmpOf(hits[i])
      if tmp != nil:
        let t = arTrim(splTmpText(tmp))
        if t.len > 0: return t
    i = i + 1

proc arLocScreen(): Il2CppPtr =
  ## The live LOCATION LIST, as a Transform, from the RECEIVER THE GAME HANDED
  ## US at `MatchMakerSelectionLocationScreen::Show` (uihooks site 4). Never a
  ## name search: the screen's GameObject is called "Matchmaker Location
  ## Selection", with SPACES, which no single-token name search can express.
  result = nil
  let self = uihSelf(UihSiteLocation)
  if self == nil: return
  let tr = iToTransform(self)
  if tr == nil or not duOk(tr, 0x20'i32): return
  result = tr

proc arLocActive(): bool =
  let tr = arLocScreen()
  if tr == nil: return false
  let a = iActiveInHierarchy(tr)
  result = a[0] and a[1]

proc arPressMapTileUnder(scr: Il2CppPtr; want: string; nTiles: var int;
                         names: var string; why: var string): bool =
  ## Press the location tile whose DISPLAYED NAME is `want` (`autoRaidMap`).
  ##
  ## THE STRUCTURE, read off the live screen with the inspector (2026-09-02),
  ## not guessed:
  ##
  ##   Matchmaker Location Selection
  ##     +- Content -> Map -> Image
  ##     |    +- "Location Template(Clone)"   <- ONE PER MAP, all identically
  ##     |         |                             named, so the OBJECT NAME
  ##     |         |                             cannot select a map
  ##     |         +- Info -> Text            <- reads "NOT AVAILABLE" etc,
  ##     |         |                             a STATUS, not the map name
  ##     |         +- Button Panel
  ##     |              +- AnimatedToggle     <- EFT.UI.AnimatedToggle, the
  ##     |                   +- SizeLabel        control
  ##     |                        +- Label    <- TMP, reads "WOODS"
  ##     +- ScreenDefaultButtons -> NextButton, BackButton
  ##
  ## So the map is chosen by the TEXT A PERSON READS on the toggle's Label, the
  ## tile's own `Info -> Text` is a red herring (it is the availability status),
  ## and the press is a TOGGLE -- which is why it must go through `Toggle::Set`
  ## and not through a UnityEvent at a guessed offset.
  ##
  ## Every tile name seen is reported, so a refusal names the maps that WERE on
  ## offer instead of only the one that was wanted.
  result = false
  nTiles = 0
  names = ""
  why = ""
  if scr == nil:
    why = "no live location screen"
    return false
  var toggles: seq[Il2CppPtr] = @[]
  var b = ArNodeBudget
  gArCrumb = 29
  arCollectBFS(scr, ArLocDepth, b, cNowMs() + ArWalkMs, toggles, ArMaxTiles, "")
  var i = 0
  while i < toggles.len:
    if iObjName(toggles[i]) == "AnimatedToggle":
      nTiles = nTiles + 1
      gArCrumb = 30
      let lbl = arLabelUnderName(toggles[i], "Label", ArMapDepth)
      if names.len < 620:
        names = names & "[" & (if lbl.len > 0: lbl else: "<unreadable>") & "]"
      if lbl.len > 0 and iLower(arTrim(lbl)) == want:
        gArCrumb = 31
        if arPress(toggles[i], "AnimatedToggle"):
          okLog "autoRaid SELECT-MAP: pressed the tile whose Label reads \"" &
                lbl & "\" (EFT.UI.AnimatedToggle, via Toggle::Set). Tiles " &
                "offered: " & names
          return true
        why = "the tile whose Label reads \"" & lbl & "\" matched, but its " &
              "AnimatedToggle could not be set (Toggle::Set unverified, or " &
              "the component's native half is null)"
        return false
    i = i + 1
  why = "no location tile under the live screen has a Label reading \"" &
        want & "\" (`autoRaidMap`). " & $nTiles & " tile toggle(s) examined; " &
        "the maps ON OFFER are " &
        (if names.len > 0: names else: "<none readable>") &
        ". NOTHING WAS PRESSED -- match one of those"

proc arScrSite(row: int): int =
  ## Row -> uihooks site. THE ONLY mapping, so a row cannot mean two things in
  ## two places (fact #187 in miniature).
  case row
  of 0: UihSiteOfflineRaid
  of 1: UihSiteInsurance
  of 2: UihSiteAccept
  else: -1

proc arScrName(row: int): string =
  case row
  of 0: "offline raid screen"
  of 1: "insurance screen"
  of 2: "accept screen (its READY is itself a NextButton)"
  else: "unknown row"

proc arScrLast(row: int): bool =
  ## Is this the row after which the raid is LOADING and the host must go
  ## hands-off? Pressing anything during the load errors matchmaking (fact
  ## #261), so this is the one row whose success ends the machine.
  row == 2

proc arScrTransform(row: int): Il2CppPtr =
  result = nil
  let site = arScrSite(row)
  if site < 0: return
  let self = uihSelf(site)
  if self == nil: return
  let tr = iToTransform(self)
  if tr == nil or not duOk(tr, 0x20'i32): return
  result = tr

proc arScrActive(row: int): bool =
  let tr = arScrTransform(row)
  if tr == nil: return false
  let a = iActiveInHierarchy(tr)
  result = a[0] and a[1]

proc arToggleIsOn(comp: Il2CppPtr; ok: var bool): bool =
  ## `UnityEngine.Toggle.m_IsOn` @0x120 -- offset from tools/fldoff.py, never
  ## guessed (the same layout dump that proved 0x100 is `toggleTransition` and
  ## not an event). `ok` says whether the read HAPPENED; the result is
  ## meaningless when it did not, and a caller that ignores `ok` would be
  ## reading "off" out of a failure.
  result = false
  ok = false
  if comp == nil or not duOk(comp, 0x128'i32) or not iUnityAlive(comp): return
  ok = true
  # There is no byte-read primitive in this host, so the 4 bytes AT the field
  # are read and only the low one is tested: `m_IsOn` is a 1-byte bool at
  # 0x120 and the three bytes after it are padding. The address is computed
  # explicitly rather than via an offset helper that does not exist.
  let addrOn = cast[Il2CppPtr](cast[uint64](comp) + 0x120'u64)
  result = (cReadI32At(addrOn) and 0xFF'i32) != 0'i32

proc arAssertPracticeToggle(scr: Il2CppPtr) =
  ## READ AND LOG the practice/offline toggle on the offline raid screen, and
  ## set it only if it reads OFF. This is the toggle that decides whether the
  ## raid routes to the emulated backend, so its state is worth a line in the
  ## log whatever it is -- "I set it" and "it was already on" are different
  ## facts and both are reported.
  ##
  ## HONEST LIMIT: `singleplayerRebrand` deactivates this checkbox's GameObject
  ## on purpose, so on a session with that feature on the toggle is INACTIVE and
  ## this finds nothing. That is reported as "not found", never as "off".
  if scr == nil or gArPracticeChecked: return
  gArPracticeChecked = true
  var nodes: seq[Il2CppPtr] = @[]
  var b = ArNodeBudget
  gArCrumb = 35
  arCollectBFS(scr, ArLocDepth, b, cNowMs() + ArWalkMs, nodes, ArMaxTiles, "")
  var i = 0
  while i < nodes.len:
    if iObjName(nodes[i]) == "AnimatedToggle":
      let lbl = iLower(arLabelUnderName(nodes[i], "Label", ArMapDepth))
      if lbl.len > 0 and (iContains(lbl, "practice") or iContains(lbl, "offline")):
        var comp: Il2CppPtr = nil
        var w = ""
        if iVisComponent(nodes[i], "AnimatedToggle", comp, w) and comp != nil:
          var ok = false
          let isOn = arToggleIsOn(comp, ok)
          if not ok:
            warn "autoRaid SCREEN-NEXT: found the practice toggle but could " &
                 "NOT read m_IsOn@0x120 on it. Its state is UNKNOWN -- that " &
                 "is not the same as off, and nothing was pressed."
            return
          if isOn:
            okLog "autoRaid SCREEN-NEXT: the practice/offline toggle reads " &
                  "m_IsOn=TRUE already; nothing was pressed. The raid should " &
                  "route to the emulated backend."
            return
          okLog "autoRaid SCREEN-NEXT: the practice/offline toggle reads " &
                "m_IsOn=FALSE. Setting it via Toggle::Set(true, true)."
          gArCrumb = 36
          if not arPress(nodes[i], "AnimatedToggle"):
            warn "autoRaid SCREEN-NEXT: could not set the practice toggle. " &
                 "The raid may not route offline; this is announced, not " &
                 "silently accepted."
          return
    i = i + 1
  info "autoRaid SCREEN-NEXT: no ACTIVE toggle under the offline raid screen " &
       "has a Label mentioning practice/offline, so its state was NOT read. " &
       "With `singleplayerRebrand` on this is EXPECTED -- that feature " &
       "deactivates the checkbox's GameObject deliberately -- and it is " &
       "reported as `not found`, never as `off`."

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
#   1. THE GAME'S OWN BACK PATH -- that screen's OWN Back control, scoped to ITS
#      subtree, fired through the same validated DefaultUIButton OnClick(+0x120)
#      -> UnityEvent::Invoke every other press here uses. That is what a human
#      click runs, and it is the handler that RESTORES THE MENU. Scoped, so this
#      is not the all-roots name hunt that refuses (fact #243).
#   2. `EFT.UI.Settings.SettingsScreen::Close()` @0x1720B10 (UNIQUE, arity 0,
#      prologue-verified against the STARTUP SNAPSHOT, CALLED and never
#      detoured; abi/aowlspt_premenu.h has the disassembly and the virtual-call
#      hazard) -- FALLBACK ONLY.
#
# THE ORDER WAS SWAPPED BY MEASUREMENT, 2026-09-02. `Close()` was attempt 1 and
# it HID the settings screen: its own readback passed --
# `no ACTIVE SettingsScreen remains`, `Overlays cleared this session: 1` -- and
# then WAIT-MENU sat for its whole 180 s bound, because the census showed NO
# MenuScreen active at all. Close hides the screen WITHOUT restoring the menu.
# That is the exact shape of a check that cannot fail: the step asserted the
# thing it had just done rather than the thing it was for.
#
# So the FINISHED STATE is now THE MENU BEING USABLE -- an ACTIVE, PRESSABLE
# MenuScreen PlayButton, obtained from the SAME `arFindPlay` WAIT-MENU uses, so
# the two cannot disagree -- and neither attempt is believed without it. If the
# attempts run out, the step refuses and names what is really active.
#
# There is no third route to reach for, and that is CHECKED, not assumed:
# `EFT.UI.Settings.SettingsScreen` declares no Back and no Hide (all 23 declared
# methods listed offline), its base `EFT.UI.Screens.EftScreen` is an
# UNINSTANTIATED GENERIC whose methods have RVA `None` (shared generic code
# needs a real MethodInfo, which this host does not have), and
# `SettingsScreenController` has no Back either.
#
# CHATSCREEN IS NEVER TOUCHED, and that is now MEASURED rather than assumed:
# it read ACTIVE in BOTH menu censuses taken on 2026-09-02 (once with Settings
# over the menu, once with the menu working normally and PLAY pressable). It is
# a normal part of the menu, not an overlay, so PRE-MENU ignores it by name and
# never closes it. The counter (`ChatScreen was ACTIVE on N of M checks`) stays,
# because a count that keeps agreeing is what makes the claim checkable.
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

proc arPressBackUnder(ss: Il2CppPtr; names: var string; nSeen: var int;
                      why: var string): bool =
  ## Attempt 1: the screen's OWN Back control, scoped to ITS subtree.
  ##
  ## `BackButton` by exact name first, because that is the name the inspector
  ## reported live on this screen. If that is not there, ANY active descendant
  ## whose name contains "back" -- and either way the active names seen are
  ## reported, so a refusal here lists the candidates instead of shrugging.
  result = false
  why = ""
  names = ""
  nSeen = 0
  if ss == nil:
    why = "no live SettingsScreen to search"
    return false
  var b = ArNodeBudget
  gArCrumb = 26
  let back = arWalkActive(ss, "BackButton", ArFindDepth, b,
                          cNowMs() + ArWalkMs, nil)
  if back != nil:
    gArCrumb = 28
    if arPress(back, "DefaultUIButton"):
      return true
    why = "the SettingsScreen's own ACTIVE `BackButton` was found, but its " &
          "DefaultUIButton OnClick could not be resolved and validated, so it " &
          "was NOT pressed"
    return false
  # No node called exactly `BackButton`. Census the active names and try any
  # that reads like a back control, so the refusal carries evidence.
  var nodes: seq[Il2CppPtr] = @[]
  var b2 = ArNodeBudget
  gArCrumb = 27
  arCollectAllActive(ss, ArSideDepth, b2, cNowMs() + ArWalkMs, nodes,
                     ArMaxSideBtns)
  nSeen = nodes.len
  var i = 0
  while i < nodes.len:
    let nm = iObjName(nodes[i])
    if nm.len > 0 and names.len < 600:
      names = names & "[" & nm & "]"
    i = i + 1
  i = 0
  while i < nodes.len:
    let nm = iObjName(nodes[i])
    if nm.len > 0 and iContains(iLower(nm), "back"):
      if arPress(nodes[i], "DefaultUIButton"):
        return true
    i = i + 1
  why = "no ACTIVE node named `BackButton`, and none of the " & $nSeen &
        " active node name(s) under the screen containing \"back\" could be " &
        "pressed (searched THAT SUBTREE only, never all 16 scene roots -- the " &
        "all-roots hunt is the one that refuses, fact #243). Names seen: " &
        (if names.len > 0: names else: "<none>")

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
  gArCrumb = 0
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
  # THE SIDE SELECTOR'S OWN SHOW EVENT. Same shape, same cost: one integer
  # compare per tick. This is what makes the step after PLAY event-driven
  # instead of a visibility poll -- and the receiver comes with it, so the
  # screen never has to be found by name at all.
  gArCrumb = 2
  let sep = uihEpoch(UihSiteSideSelect)
  if sep != gArSideEpoch:
    gArSideEpoch = sep
    gArSideFires = gArSideFires + 1
    gArCrumb = 13
    gArSideTr = arSideScreen()
    gArSideNextDone = false
    gArSidePresses = 0
    if gArStep == ArSide or gArStep == ArPressPlay or gArStep == ArWaitMenu or
       gArStep == ArNext1:
      okLog "autoRaid: READBACK -- MatchMakerSideSelectionScreen::Show fired " &
            "(uihooks site 3, epoch " & $sep & "). The PMC/SCAV side selector " &
            "is UP, which is an observation, not a guess, and its receiver " &
            "came with the event (screen transform 0x" &
            hexOf(cast[uint64](gArSideTr)) & "). Step SIDE."
      gArLastPressed = nil
      arGoto(ArSide)
    else:
      info "autoRaid: MatchMakerSideSelectionScreen::Show fired (uihooks " &
           "site 3, epoch " & $sep & ") while at step " & arStepName(gArStep) &
           "; noted, no resynchronisation (that step is already past it)."
  # THE LOCATION LIST'S OWN SHOW EVENT. MEASURED 2026-09-02: the side selector's
  # NextButton lands DIRECTLY on this screen -- there is no NEXT to press to
  # reach it, which is why the old NEXT->location step timed out against a
  # census that already read `[Matchmaker Location Selection]`. So its arrival
  # is an event, the receiver comes with it, and the machine goes straight to
  # SELECT-MAP.
  gArCrumb = 34
  let lep = uihEpoch(UihSiteLocation)
  if lep != gArLocEpoch:
    gArLocEpoch = lep
    gArLocFires = gArLocFires + 1
    gArLocTr = arLocScreen()
    gArLocPressed = false
    gArLocNextDone = false
    if gArStep == ArSide or gArStep == ArNext1 or gArStep == ArSelectMap:
      okLog "autoRaid: READBACK -- MatchMakerSelectionLocationScreen::Show " &
            "fired (uihooks site 4, epoch " & $lep & "). The location list is " &
            "UP, which is an observation, not a guess, and its receiver came " &
            "with the event (screen transform 0x" &
            hexOf(cast[uint64](gArLocTr)) & "). Going straight to SELECT-MAP; " &
            "NEXT->location is SKIPPED because there is nothing to press to " &
            "reach a screen that is already here."
      gArLastPressed = nil
      arGoto(ArSelectMap)
    else:
      info "autoRaid: MatchMakerSelectionLocationScreen::Show fired (uihooks " &
           "site 4, epoch " & $lep & ") while at step " & arStepName(gArStep) &
           "; noted, no resynchronisation."
  # ---- THE GENERIC SCREEN WATCHER ----------------------------------------
  # One integer compare per row per tick. Whichever table screen announces
  # itself becomes the current screen, and the SCREEN-NEXT step advances it.
  # This is the whole of "add the next screen in the chain": a uihooks site and
  # a row.
  gArCrumb = 37
  var row = 0
  while row < ArScrN:
    let site = arScrSite(row)
    if site >= 0:
      let e = uihEpoch(site)
      if e != gArScrEpoch[row]:
        gArScrEpoch[row] = e
        if gArStep != ArDone and gArStep != ArFailed:
          gArScrIdx = row
          gArScrTr = arScrTransform(row)
          gArScrPressed = false
          gArScrMs = 0'u64
          gArLastPressed = nil
          okLog "autoRaid: READBACK -- the " & arScrName(row) & " announced " &
                "itself (uihooks site " & $site & ", epoch " & $e &
                "), receiver 0x" & hexOf(cast[uint64](gArScrTr)) &
                ". SCREEN-NEXT will press THAT screen's own NextButton, from " &
                "THAT receiver -- the only thing that has ever worked here."
          arGoto(ArScreen)
    row = row + 1
  gArCrumb = 1
  let ep = uihEpoch(UihSiteOfflineRaid)
  if ep != gArOffEpoch:
    gArOffEpoch = ep
    gArOffFires = gArOffFires + 1
    if gArStep == ArSide or gArStep == ArNext1 or
       gArStep == ArSelectMap or gArStep == ArNext2:
      # The GENERIC SCREEN DRIVER below owns this screen (row 0): it presses
      # THIS screen's own NextButton from THIS receiver. All this block does is
      # note the event and stop the ArNext2 wait; it must not send the machine
      # to a legacy step, or the same "hunt a NextButton across the roots"
      # mistake happens for a fourth time.
      okLog "autoRaid: READBACK -- MatchmakerOfflineRaidScreen::Show fired " &
            "(uihooks site 0, epoch " & $ep & "). The offline raid screen is " &
            "UP, which is an observation, not a guess. The generic screen " &
            "driver takes it from here."
      gArLastPressed = nil
      gArOffAwaitMs = 0'u64
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
      gArCrumb = 19
      census = arScreenCensus()
    arFail("step " & arStepName(gArStep) & " never completed within " &
           $(int(stepTimeout div 1000'u64)) & " s (control never became " &
           "visible)." &
           (if gArStep == ArSide:
              " Wanted the side control whose name contains \"" & gArSide &
              "\" (`autoRaidSide`)."
            else: "") &
           " Show events seen while armed: side=" & $gArSideFires &
           " offline-raid=" & $gArOffFires &
           ". Side screens got past: " & $gArSideAnswered & "." &
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
    gArCrumb = 3
    let pb = arFindPlay(nMs, nPb, nActive)
    if pb != nil:
      gArPlaySeen = true
      gArCrumb = 7
      if arPress(pb, "DefaultUIButton"):
        okLog "autoRaid: menu ready -- pressed PLAY (MenuScreen PlayButton, " &
              "atomic find-and-press); driving into an OFFLINE raid on map \"" &
              gArMap & "\"."
        gArLastPressed = nil
        gArLastActionMs = now
        # MEASURED 2026-09-02: the screen after PLAY is the PMC/SCAV SIDE
        # selector, not the location list. SIDE grace-skips itself if its show
        # event never arrives, so this ordering costs nothing on a flow that
        # does not have one.
        arGoto(ArSide)
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
        gArCrumb = 5
        if arChatActive(): gArPreChatSeen = gArPreChatSeen + 1
        gArCrumb = 4
        let ov = arOverlayScreen()
        if ov == nil and gArPreAttempted:
          # PRE-MENU has already acted and the menu is STILL not usable, with
          # nothing left on screen to dismiss. Waiting out the remaining
          # ArMenuWaitMs would spend three minutes reaching the same verdict,
          # so refuse NOW, with the census that says what is really up.
          var census = ""
          if not gArCensused:
            gArCensused = true
            gArCrumb = 6
            census = arScreenCensus()
          arFail("WAIT-MENU refusing IMMEDIATELY rather than waiting out its " &
                 $(int(ArMenuWaitMs div 1000'u64)) & " s bound: PRE-MENU has " &
                 "already dismissed an overlay (via " & gArPreVia & ") and " &
                 "there is now NO ACTIVE SettingsScreen and still no ACTIVE, " &
                 "pressable MenuScreen PlayButton (MenuScreens seen=" & $nMs &
                 ", PlayButtons under them=" & $nPb & ", active=" & $nActive &
                 "). The settings screen was HIDDEN WITHOUT THE MENU BEING " &
                 "RESTORED, which is what SettingsScreen::Close alone does " &
                 "(MEASURED 2026-09-02). Nothing further here will make the " &
                 "menu appear" &
                 (if census.len > 0: ". ACTIVE:" & census else: ""))
          return
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
    # (a) THE FINISHED STATE. It is NOT "no ACTIVE SettingsScreen" -- that check
    # PASSED on 2026-09-02 while the menu never came back, which makes it a
    # check that cannot fail for the thing this step exists to achieve. The
    # finished state is THE MENU BEING USABLE: an ACTIVE, PRESSABLE MenuScreen
    # PlayButton, asked for with the very same function WAIT-MENU uses, so the
    # two can never disagree.
    var nMs = 0
    var nPb = 0
    var nAct = 0
    gArCrumb = 8
    let pb = arFindPlay(nMs, nPb, nAct)
    if pb != nil:
      if gArPreTries > 0:
        gArPreDismissed = gArPreDismissed + 1
        okLog "autoRaid PRE-MENU: dismissed SettingsScreen via " & gArPreVia &
              " -- READBACK: the MenuScreen PlayButton is ACTIVE and PRESSABLE " &
              "again (MenuScreens=" & $nMs & ", PlayButtons=" & $nPb &
              ", active=" & $nAct & "). That is the menu being usable, not " &
              "merely the settings screen being hidden. Overlays cleared this " &
              "session: " & $gArPreDismissed & "."
      else:
        info "autoRaid PRE-MENU: the menu became usable before anything was " &
             "attempted (the player closed the overlay, most likely). Nothing " &
             "was called and nothing is claimed; back to WAIT-MENU."
      gArPreTries = 0
      gArStepT0 = 0'u64
      arGoto(ArWaitMenu)
      return
    gArCrumb = 9
    let ov = arOverlayScreen()
    # (b) settle after an attempt before judging it or trying again.
    if gArPreTries > 0 and now - gArPreActMs < ArPreSettleMs:
      return
    # (c) nothing left to try, or nothing left to dismiss: REFUSE, naming what
    # is actually up.
    if gArPreTries >= ArPreMaxTries or (ov == nil and gArPreTries > 0):
      var census = ""
      if not gArCensused:
        gArCensused = true
        gArCrumb = 10
        census = arScreenCensus()
      arFail("step PRE-MENU -- the MAIN MENU DID NOT COME BACK. After " &
             $gArPreTries & " dismissal attempt(s) (last via " & gArPreVia &
             ") there is still no ACTIVE, pressable MenuScreen PlayButton " &
             "(MenuScreens seen=" & $nMs & ", PlayButtons under them=" & $nPb &
             ", active=" & $nAct & "), and SettingsScreen is " &
             (if ov == nil:
                "no longer active -- so the settings screen was HIDDEN " &
                "WITHOUT THE MENU BEING RESTORED, which is exactly what " &
                "SettingsScreen::Close alone does (MEASURED 2026-09-02)"
              else: "STILL ACTIVE") &
             ". ChatScreen is a normal part of the menu and was never touched " &
             "(ACTIVE on " & $gArPreChatSeen & " of " & $gArPreChecks &
             " checks)" & (if census.len > 0: ". ACTIVE:" & census else: ""))
      return
    if ov == nil:
      # No overlay and no menu, with nothing attempted yet: there is nothing
      # here for this step to dismiss. Say so and let WAIT-MENU judge.
      info "autoRaid PRE-MENU: no ACTIVE SettingsScreen and no pressable " &
           "PlayButton either, with nothing attempted yet. There is nothing " &
           "here to dismiss; back to WAIT-MENU."
      gArStepT0 = 0'u64
      arGoto(ArWaitMenu)
      return
    # (d) THE LADDER. Attempt 1 is the GAME'S OWN BACK PATH -- the settings
    # screen's own BackButton, scoped to its subtree, fired through the same
    # validated DefaultUIButton OnClick(+0x120) -> UnityEvent::Invoke that every
    # other press in this file uses. That is what a human click runs, and it is
    # the handler that RESTORES THE MENU.
    #
    # Attempt 2 is `SettingsScreen::Close()` @0x1720B10, kept only as a
    # FALLBACK and demoted for a MEASURED reason: on 2026-09-02 it hid the
    # settings screen -- its own readback passed, `no ACTIVE SettingsScreen
    # remains` -- and the main menu never came back; the census afterwards had
    # no MenuScreen active at all. It is still worth trying second, because a
    # hidden settings screen with a dead menu is a state the refusal above can
    # NAME, but it is not the back path.
    #
    # There is no third thing to reach for, and that is checked rather than
    # assumed: `EFT.UI.Settings.SettingsScreen` declares no Back and no Hide of
    # its own (all 23 declared methods listed offline), and its base
    # `EFT.UI.Screens.EftScreen` is an UNINSTANTIATED GENERIC whose methods have
    # RVA `None` -- shared generic code needs a real MethodInfo, which this host
    # does not have. `SettingsScreenController` has no Back either. So the
    # button's own handler IS the game's back path here.
    var why = ""
    if gArPreTries == 0:
      gArPreTries = 1
      gArPreAttempted = true
      gArPreActMs = now
      gArLastActionMs = now
      gArPreVia = "the screen's own BackButton (DefaultUIButton OnClick -> " &
                  "UnityEvent::Invoke), scoped to the ACTIVE SettingsScreen"
      var backNames = ""
      var backSeen = 0
      gArCrumb = 11
      if arPressBackUnder(ov, backNames, backSeen, why):
        okLog "autoRaid PRE-MENU: pressed " & gArPreVia &
              ". PRESSED IS NOT RESTORED -- the readback is the next tick " &
              "finding an ACTIVE, PRESSABLE MenuScreen PlayButton, not merely " &
              "the settings screen going away."
      else:
        warn "autoRaid PRE-MENU: the BackButton press did not go through -- " &
             why & ". Falling back to SettingsScreen::Close on the next " &
             "attempt, which is MEASURED to hide the screen WITHOUT restoring " &
             "the menu, so expect the refusal below rather than a success."
      return
    gArPreTries = gArPreTries + 1
    gArPreAttempted = true
    gArPreActMs = now
    gArLastActionMs = now
    gArPreVia = "SettingsScreen::Close @0x" & hexOf(uint64(cPmnRva(PmnTSsClose)))
    gArCrumb = 12
    if arCloseSettings(ov, why):
      okLog "autoRaid PRE-MENU: called " & gArPreVia &
            " on the ACTIVE SettingsScreen (FALLBACK -- this hides the screen " &
            "and is MEASURED not to restore the menu). CALLED IS NOT " &
            "RESTORED: the readback is an ACTIVE, PRESSABLE PlayButton."
    else:
      warn "autoRaid PRE-MENU: could not call SettingsScreen::Close either -- " &
           why & "."
    return

  if gArStep == ArScreen:
    if gArScrIdx < 0 or gArScrTr == nil:
      # Nothing to advance. Never a silent stall: say so once and go back to
      # waiting for an event.
      if now - gArScrLogMs > 5000'u64:
        gArScrLogMs = now
        warn "autoRaid SCREEN-NEXT: no current screen receiver, which should " &
             "be impossible in this step. Nothing was pressed."
      return
    if not gArScrPressed:
      # Row 0 has a pre-action: read and log the practice/offline toggle.
      if gArScrIdx == ArScrPracticeRow:
        arAssertPracticeToggle(gArScrTr)
      gArCrumb = 38
      var seen = 0
      var seenNames = ""
      let nb = arFindActiveNamedBFS(gArScrTr, "NextButton", ArSideNextDepth,
                                    ArMaxSideNext, seen, seenNames)
      if nb == nil:
        if now - gArScrLogMs > 5000'u64:
          gArScrLogMs = now
          warn "autoRaid SCREEN-NEXT: NO ACTIVE node named `NextButton` under " &
               "the " & arScrName(gArScrIdx) & "'s own receiver (0x" &
               hexOf(cast[uint64](gArScrTr)) & ") -- BFS, depth " &
               $ArSideNextDepth & ", cap " & $ArMaxSideNext & ", examined " &
               $seen & " ACTIVE node(s): " &
               (if seenNames.len > 0: seenNames else: "<none>") &
               ". NOTHING WAS PRESSED. If `NextButton` is in that list the " &
               "comparison is wrong; if the count is at the cap the search " &
               "was truncated; if it is tiny the receiver is not the screen."
        return
      gArCrumb = 39
      if arPress(nb, "DefaultUIButton"):
        gArScrPressed = true
        gArScrMs = now
        gArLastPressed = nb
        gArLastActionMs = now
        okLog "autoRaid: SCREEN-NEXT -- pressed the " & arScrName(gArScrIdx) &
              "'s own NextButton (EFT.UI.DefaultUIButton, from its own show " &
              "receiver). PRESSED IS NOT ADVANCED: the readback is this " &
              "screen going INACTIVE, and then the next screen's show event."
      elif now - gArScrLogMs > 5000'u64:
        gArScrLogMs = now
        warn "autoRaid SCREEN-NEXT: found the " & arScrName(gArScrIdx) &
             "'s ACTIVE `NextButton` but its DefaultUIButton OnClick could " &
             "not be resolved and validated, so it was NOT pressed."
      return
    # PRESSED: the readback is a NEGATIVE -- this screen is no longer active.
    gArCrumb = 40
    if not arScrActive(gArScrIdx):
      gArScrDone = gArScrDone + 1
      let wasLast = arScrLast(gArScrIdx)
      okLog "autoRaid: READBACK -- the " & arScrName(gArScrIdx) & " is no " &
            "longer active after its own NextButton. Screens advanced this " &
            "session: " & $gArScrDone & "." &
            (if wasLast:
               " That was the ACCEPT screen, so the raid is now LOADING: this " &
               "feature goes hands-off and will not touch the UI again this " &
               "session (touching it during the load errors matchmaking)."
             else:
               " Waiting for the next screen's show event; if none arrives " &
               "this step times out and refuses with a census.")
      gArScrIdx = -1
      gArScrTr = nil
      gArScrPressed = false
      gArLastPressed = nil
      gArLastActionMs = now
      if wasLast:
        arGoto(ArDone)
      return
    if now - gArScrMs > ArSideSettleMs:
      warn "autoRaid SCREEN-NEXT: the " & arScrName(gArScrIdx) & " is STILL " &
           "ACTIVE " & $int(now - gArScrMs) & "ms after its own NextButton " &
           "was pressed. The press ran and did not advance the screen; the " &
           "step timeout will refuse with a census."
      gArScrMs = now
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
    gArCrumb = 17
    var nb = arFindNext(gArLastPressed)
    if nb == nil and gArLastPressed != nil and
       now - gArLastActionMs > ArReuseMs:
      nb = arFindNext(nil)                     # allow the reused object
    gArCrumb = 18
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

  if gArStep == ArSide:
    # (a) THE SIDE IS CHOSEN: press THIS SCREEN'S OWN NextButton, then read
    # back that the screen has gone. Handing straight to NEXT->location was
    # measured wrong -- see the block below.
    if gArSidePresses > 0 and not gArSideNextDone:
      # THIS SCREEN'S OWN NEXT. Handing straight to NEXT->location was wrong and
      # MEASURED wrong: that step searches the `Menu UI` root for an active
      # `NextButton` for the NEXT screen and never pressed this one, so the side
      # screen stayed up until the step timed out 45 s later with the census
      # still showing `[MatchMaker Side Selection Screen]`. The button is a
      # sibling subtree of the side controls -- `ScreenDefaultButtons ->
      # NextButton` -- and it carries `EFT.UI.DefaultUIButton` (measured live
      # with the inspector's `components`), so the ordinary +0x120 press path
      # fits it. It is resolved from the SITE-3 RECEIVER's own subtree, never by
      # an all-roots name hunt.
      gArCrumb = 20
      var seen = 0
      var seenNames = ""
      let nb = arFindActiveNamedBFS(gArSideTr, "NextButton", ArSideNextDepth,
                                    ArMaxSideNext, seen, seenNames)
      if nb == nil:
        if now - gArSideLogMs > 5000'u64:
          gArSideLogMs = now
          warn "autoRaid SIDE: the side was chosen but NO ACTIVE node named " &
               "`NextButton` was found under the site-3 receiver (0x" &
               hexOf(cast[uint64](gArSideTr)) & ") -- level-by-level BFS, " &
               "depth " & $ArSideNextDepth & ", cap " & $ArMaxSideNext &
               ", examined " & $seen & " ACTIVE node(s): " &
               (if seenNames.len > 0: seenNames else: "<none>") &
               ". NOTHING WAS PRESSED. The names above are the evidence: if " &
               "`NextButton` is among them the comparison is wrong, if the " &
               "count is at the cap the search was truncated, and if the " &
               "count is tiny the receiver is not the screen."
        return
      if arPress(nb, "DefaultUIButton"):
        gArSideNextDone = true
        gArSideNextMs = now
        gArLastPressed = nb
        gArLastActionMs = now
        okLog "autoRaid: step SIDE -- pressed THIS screen's own NextButton " &
              "(EFT.UI.DefaultUIButton, resolved from the site-3 receiver's " &
              "subtree). PRESSED IS NOT ADVANCED: the readback is this screen " &
              "going INACTIVE, and then MatchmakerOfflineRaidScreen::Show " &
              "(uihooks site 0) firing."
      elif now - gArSideLogMs > 5000'u64:
        gArSideLogMs = now
        warn "autoRaid SIDE: found this screen's ACTIVE `NextButton` but its " &
             "DefaultUIButton OnClick could not be resolved and validated, so " &
             "it was NOT pressed."
      return
    if gArSideNextDone:
      # THE READBACK, and it is a NEGATIVE: this screen is no longer active.
      gArCrumb = 13
      if not arSideActive():
        gArSideAnswered = gArSideAnswered + 1
        okLog "autoRaid: READBACK -- the MatchMakerSideSelectionScreen is no " &
              "longer active after its own NextButton. Side \"" & gArSide &
              "\" is committed as far as this host can observe; site 0 " &
              "(MatchmakerOfflineRaidScreen::Show) is the next readback and " &
              "will resynchronise the machine if it fires. Handing to " &
              "NEXT->location. Side screens got past this session: " &
              $gArSideAnswered & "."
        gArSidePresses = 0
        gArSideNextDone = false
        gArLastPressed = nil
        gArLastActionMs = now
        arGoto(ArNext1)
        return
      if now - gArSideNextMs > ArSideSettleMs and
         gArSidePresses < ArMaxSidePresses:
        # Still up after the settle window: allow ONE more attempt at the pair,
        # then let the step timeout refuse with its census.
        warn "autoRaid SIDE: the side screen is STILL ACTIVE " &
             $int(now - gArSideNextMs) & "ms after its own NextButton was " &
             "pressed. Retrying the side control and NEXT once more (attempt " &
             $(gArSidePresses + 1) & " of " & $ArMaxSidePresses & ")."
        gArSideNextDone = false
        gArSidePresses = 0
      return
    gArCrumb = 13
    if not arSideActive():
      # (b) NO SCREEN. Either its show event never came, or a human answered it.
      # Not an error -- but never claimed as a success either.
      if now - gArStepT0 > ArSideGraceMs:
        okLog "autoRaid: step SIDE -- no live MatchMakerSideSelectionScreen " &
              "is active within " & $(int(ArSideGraceMs div 1000'u64)) &
              " s of pressing PLAY (site-3 show events seen while armed: " &
              $gArSideFires & "). Nothing was pressed and nothing is claimed; " &
              "continuing to NEXT->location. If a side selector IS on screen, " &
              "then its ::Show did not fire or did not bind -- check the " &
              "`uihooks:` lines, not this step."
        gArLastPressed = nil
        arGoto(ArNext1)
      return
    var nSeen = 0
    var names = ""
    var why = ""
    let want = iLower(arTrim(gArSide))
    gArCrumb = 14
    let pressed = arPressSideUnder(gArSideTr, want, nSeen, names, why)
    if not gArSideNamesLogged and nSeen > 0:
      # THE CANDIDATE CENSUS, once: every node INSIDE a `pmc`/`scav` container
      # that carries a pressable component, with the caption a person actually
      # reads on it (`DefaultUIButton._text` @0xB8, offset from fldoff.py).
      # This is what turns the next refusal into evidence instead of a shrug.
      gArSideNamesLogged = true
      info "autoRaid SIDE: " & $nSeen & " node(s) carrying a control in the " &
           "wanted side's scope: " & names & " -- side \"" & want &
           "\" (`autoRaidSide`) is chosen STRUCTURALLY (both sides live under " &
           "`PMCs`; the scav one is nested in a `*scav*` subtree), because " &
           "these controls carry no DefaultUIButton and therefore no caption."
    if pressed:
      gArSidePresses = gArSidePresses + 1
      gArSidePressedMs = now
      gArLastActionMs = now
      okLog "autoRaid: step SIDE -- pressed the side control matching \"" &
            want & "\" under the live MatchMakerSideSelectionScreen (" &
            $nSeen & " pressable candidate(s) examined). PRESSED IS NOT " &
            "ADVANCED: the readback is this screen going INACTIVE after its " &
            "NEXT, and then MatchmakerOfflineRaidScreen::Show (uihooks site 0)."
    elif now - gArSideLogMs > 5000'u64:
      gArSideLogMs = now
      warn "autoRaid SIDE: the side selector is up and NOTHING was pressed -- " &
           why & "."
    return

  if gArStep == ArSelectMap:
    # THE OTHER HALF OF THE SIDE READBACK, asserted once and as a NEGATIVE.
    if gArSideTr != nil:
      gArCrumb = 15
      if arSideActive():
        warn "autoRaid: READBACK FAILED -- the side selector is STILL ACTIVE " &
             "after its NextButton was pressed. The map list may not be what " &
             "is on screen, so anything SELECT-MAP does next is against an " &
             "unknown screen. Continuing, but this is not a success."
      else:
        okLog "autoRaid: READBACK -- the MatchMakerSideSelectionScreen is no " &
              "longer active after NEXT; the side step is complete."
      gArSideTr = nil

    if gArLocTr != nil:
      # THE EVENT-DRIVEN PATH: the screen came from site 4, so everything here
      # is scoped to the receiver the game handed us. No root hunt, no
      # name search for a GameObject whose name contains spaces.
      if gArLocPressed and not gArLocNextDone:
        gArCrumb = 32
        var seen = 0
        var seenNames = ""
        let nb = arFindActiveNamedBFS(gArLocTr, "NextButton", ArSideNextDepth,
                                      ArMaxSideNext, seen, seenNames)
        if nb == nil:
          if now - gArLocLogMs > 5000'u64:
            gArLocLogMs = now
            warn "autoRaid SELECT-MAP: the map was chosen but NO ACTIVE node " &
                 "named `NextButton` was found under the site-4 receiver " &
                 "(0x" & hexOf(cast[uint64](gArLocTr)) & ") -- BFS, depth " &
                 $ArSideNextDepth & ", cap " & $ArMaxSideNext & ", examined " &
                 $seen & " ACTIVE node(s): " &
                 (if seenNames.len > 0: seenNames else: "<none>") &
                 ". NOTHING WAS PRESSED."
          return
        if arPress(nb, "DefaultUIButton"):
          gArLocNextDone = true
          gArLocNextMs = now
          gArLastPressed = nb
          gArLastActionMs = now
          okLog "autoRaid: step SELECT-MAP -- pressed THIS screen's own " &
                "NextButton (EFT.UI.DefaultUIButton, resolved from the site-4 " &
                "receiver's subtree). PRESSED IS NOT ADVANCED: the readback " &
                "is this screen going INACTIVE and then " &
                "MatchmakerOfflineRaidScreen::Show (uihooks site 0)."
        elif now - gArLocLogMs > 5000'u64:
          gArLocLogMs = now
          warn "autoRaid SELECT-MAP: found this screen's ACTIVE `NextButton` " &
               "but its DefaultUIButton OnClick could not be resolved and " &
               "validated, so it was NOT pressed."
        return
      if gArLocNextDone:
        gArCrumb = 33
        if not arLocActive():
          okLog "autoRaid: READBACK -- the location list is no longer active " &
                "after its own NextButton; map \"" & gArMap & "\" is " &
                "committed as far as this host can observe. Waiting for " &
                "MatchmakerOfflineRaidScreen::Show (uihooks site 0), which " &
                "resynchronises the machine when it fires."
          gArOffAwaitMs = now
          gArLastPressed = nil
          gArLastActionMs = now
          arGoto(ArNext2)
          return
        if now - gArLocNextMs > ArSideSettleMs:
          warn "autoRaid SELECT-MAP: the location list is STILL ACTIVE " &
               $int(now - gArLocNextMs) & "ms after its own NextButton was " &
               "pressed. The press ran and did not advance the screen; the " &
               "step timeout will refuse with a census."
          gArLocNextMs = now
        return
      # Not pressed yet: choose the tile by the TEXT A PERSON READS.
      var nTiles = 0
      var tileNames = ""
      var why = ""
      let want = iLower(arTrim(gArMap))
      if arPressMapTileUnder(gArLocTr, want, nTiles, tileNames, why):
        gArLocPressed = true
        gArLocPressedMs = now
        gArLastActionMs = now
      else:
        if not gArLocNamesLogged and nTiles > 0:
          gArLocNamesLogged = true
          info "autoRaid SELECT-MAP: " & $nTiles & " location tile(s) on " &
               "offer, by the Label a person reads: " & tileNames &
               " -- wanted \"" & want & "\" (`autoRaidMap`). Tile object names " &
               "are ALL `Location Template(Clone)` on this build, so the " &
               "displayed text is the only thing that identifies a map."
        if now - gArLocLogMs > 5000'u64:
          gArLocLogMs = now
          warn "autoRaid SELECT-MAP: " & why & "."
      return

    # THE FALLBACK PATH: no site-4 receiver (the hook did not bind, or the
    # screen was reached without its show event). The legacy scan hunts the
    # AnimatedToggles across the scene roots. It is announced as the fallback
    # so a run can never quietly be the weaker one.
    gArCrumb = 16
    if arSelectMap():
      okLog "autoRaid: selected map \"" & gArMap & "\" via the LEGACY " &
            "all-roots scan (no site-4 receiver this session -- see the " &
            "`uihooks:` lines). This is the weaker path: it is not scoped to " &
            "a screen the game handed us."
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
  gArCensused = false
  gArSidePresses = 0
  gArSidePressedMs = 0'u64
  gArSideLogMs = 0'u64
  gArSideNextDone = false
  gArSideNextMs = 0'u64
  gArSideTr = nil
  # Snapshot the side screen's epoch too: an event from BEFORE this arming is
  # not evidence about this run.
  gArSideEpoch = uihEpoch(UihSiteSideSelect)
  gArLocEpoch = uihEpoch(UihSiteLocation)
  var arow = 0
  while arow < ArScrN:
    let asite = arScrSite(arow)
    gArScrEpoch[arow] = (if asite >= 0: uihEpoch(asite) else: 0)
    arow = arow + 1
  gArScrIdx = -1
  gArScrTr = nil
  gArScrPressed = false
  gArScrLogMs = 0'u64
  gArPracticeChecked = false
  gArLocTr = nil
  gArLocPressed = false
  gArLocNextDone = false
  gArLocLogMs = 0'u64
  gArPreTries = 0
  gArPreAttempted = false
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
  XrShowSayMs  = 5000'u64   ## how long a step may sit SILENT before it explains
                            ## itself. A step that refuses at 20s having said
                            ## nothing for 20s is what made the last refusal
                            ## unactionable.
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
var gXrSaidNoRecv = false           ## the "no receiver" explanation, once
var gXrSaidNoDisc = false           ## the "disconnect still closed" line, once

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

proc xrMenuFromEvent(via: var string): Il2CppPtr =
  ## The live MenuScreen COMPONENT, from a show event rather than from a search.
  ##
  ## THIS IS THE ENTRY HALF'S FIX APPLIED TO THE EXIT HALF: take the receiver
  ## the game handed us. MEASURED 2026-09-02, with the client DEPLOYED in
  ## Woods, `raidexit` refused after 20 s with `step SHOW-IN-RAID found
  ## nothing` -- because `xrFindAny` walks the ENUMERATED SCENE ROOTS, and in a
  ## raid that enumeration is the LOCATION scene. The menu lives in
  ## DontDestroyOnLoad and is not in scope there at all. No amount of waiting
  ## fixes a search that is looking in the wrong scene.
  ##
  ## TWO SOURCES, in order of how directly each answers "the in-raid menu is
  ## up", and the caller LOGS WHICH ONE ANSWERED so a run can never quietly
  ## rest on the weakest:
  ##   site 7  MenuScreen::ShowInRaid  -- the in-raid menu was SHOWN, by us or
  ##                                      by the player's own ESC. Strongest.
  ##   site 2  MenuScreen::Show(5-arg) -- the menu from BEFORE the raid.
  ##                                      MenuScreen is DontDestroyOnLoad so
  ##                                      the pointer survives; `uihSelf`
  ##                                      re-validates it and returns nil for a
  ##                                      destroyed screen rather than a corpse
  ##                                      (fact #182).
  ##   (site 1, MenuScreen::Awake, is NOT in this ladder: binding it is measured
  ##    to kill the client at menu arrival -- see `arWantShowHook`.)
  result = nil
  via = ""
  var self = uihSelf(UihSiteShowInRaid)
  if self != nil:
    via = "uihooks site 7 (MenuScreen::ShowInRaid -- the in-raid menu was shown)"
    return self
  self = uihSelf(UihSiteMenuShow)
  if self != nil:
    via = "uihooks site 2 (MenuScreen::Show(5-arg) from before the raid; " &
          "MenuScreen is DontDestroyOnLoad and the pointer was re-validated)"
    return self
  # SITE 1 (MenuScreen::Awake) IS NOT CONSULTED. It is not merely the weakest
  # source -- binding it is MEASURED to kill the client at menu arrival (see the
  # comment in `arWantShowHook`), so this feature neither wants it nor reads it.
  # Reading it would be harmless on its own, but a reader is an argument for a
  # want, and that argument is what cost three boots.

proc xrCensus(root: Il2CppPtr): string =
  ## What IS active under a receiver, in the entry half's census style, so that
  ## a stall here is evidence rather than a shrug.
  result = ""
  if root == nil:
    return " (no receiver to look under)"
  var count = 0
  var names = ""
  arActiveCensus(root, 3, count, names)
  result = " ACTIVE under the receiver (depth<=3, " & $count & "): " &
           (if names.len > 0: names else: "<none>")

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
    # THE RECEIVER, FROM AN EVENT. The scene-root search is kept only as an
    # announced fallback: in a raid it cannot see DontDestroyOnLoad at all.
    var via = ""
    var comp = xrMenuFromEvent(via)
    if comp == nil:
      let ms = xrFindAny("MenuScreen")
      if ms == nil:
        if now - gXrStepT0 > XrShowSayMs and not gXrSaidNoRecv:
          gXrSaidNoRecv = true
          warn "raidExit: no MenuScreen receiver from ANY show event (site 7 " &
               "ShowInRaid empty, and site 2 Show(5-arg) empty or unbound -- " &
               "site 1 Awake is deliberately never used), and " &
               "the scene-root search found nothing either -- which is " &
               "EXPECTED in a raid, where the enumerated roots are the " &
               "LOCATION scene and the menu lives in DontDestroyOnLoad. Check " &
               "the `uihooks:` lines: if site 7 did not BIND, the exit half " &
               "has no way to reach the menu at all."
        return        # keep looking; the step timeout bounds this
      var w = ""
      if not iVisComponent(ms, "MenuScreen", comp, w) or comp == nil:
        # The GameObject named MenuScreen exists but carries no MenuScreen
        # component -- say that rather than calling ShowInRaid on a Transform.
        xrFail("a GameObject named MenuScreen was found but it has no " &
               "EFT.UI.MenuScreen component (" & w & ")")
        return
      via = "the LEGACY scene-root search (no show-event receiver this " &
            "session -- the weaker path, and announced as such)"
    if not duOk(comp, XrDiscBtnOff + 8'i32):
      xrFail("the MenuScreen component is not readable to +0x" &
             iHexPad(uint64(XrDiscBtnOff), 3))
      return
    # THE CALL TARGET COMES FROM THIS FEATURE'S OWN TABLE, and the refusal
    # names WHICH TABLE. MEASURED 2026-09-02: at boot the host said `the
    # in-raid menu show event is LIVE -- MenuScreen::ShowInRaid @0x1539650
    # (uihooks site 7) is bound`, and on arming it said the same RVA `did not
    # resolve as callable code on this build`. BOTH were true, because they
    # were about different tables: the hook resolved through `aowl_uih_sites`,
    # while the call went through the INSPECTOR's navigation table, which has
    # no row for this RVA. "on this build" pointed at the game when the gap was
    # ours. `aowl_pmn_targets` row [3] now carries it, verified against the
    # SAME 16 bytes site 7 verifies, so the two cannot disagree.
    let fn = cPmnFn(PmnTShowInRaid)
    if fn == nil:
      xrFail("MenuScreen::ShowInRaid @0x" & iHexPad(XrShowInRaidRva, 7) &
             " did not verify against the STARTUP PROLOGUE SNAPSHOT via " &
             "`aowl_pmn_targets` row " & $PmnTShowInRaid & " (verified=" &
             $int(cPmnOkCount()) & " rejected=" & $int(cPmnBadCount()) &
             " snapshot-table-full=" & $int(cPmnProfullCount()) & "). This " &
             "names OUR table, not the game: uihooks site 7 verifies the same " &
             "RVA and the same 16 bytes for its detour, so if that one bound " &
             "and this refuses, the fault is in this row or in the snapshot, " &
             "not in the client")
      return
    gXrMenu = comp
    iMark("raidExit: MenuScreen::ShowInRaid", comp)
    cPmnCallShowInRaid(fn, comp)
    okLog "raidExit: called MenuScreen::ShowInRaid on " & iPtr(comp) &
          ", receiver via " & via & " -- waiting for _disconnectButton@+0x" &
          iHexPad(uint64(XrDiscBtnOff), 3) & " to become activeInHierarchy " &
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
      # STILL CLOSED. Pressing it now would report success and do nothing
      # (fact #72). Say so ONCE, with a census, so a stall here is evidence.
      if now - gXrStepT0 > XrShowSayMs and not gXrSaidNoDisc:
        gXrSaidNoDisc = true
        info "raidExit: the MenuScreen _disconnectButton exists but is NOT " &
             "activeInHierarchy yet, so nothing was pressed." &
             xrCensus(iToTransform(gXrMenu))
      return
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
    # THE RECEIVER FIRST, the root NAME second. `SessionEndUI::Awake` (site 8)
    # hands us the results UI itself; `Session End UI` is a scene-root name and
    # is only a fallback, for the same reason the entry half stopped hunting
    # screens by name.
    var nb: Il2CppPtr = nil
    let seSelf = uihSelf(UihSiteSessionEnd)
    if seSelf != nil:
      let seTr = iToTransform(seSelf)
      if seTr != nil and duOk(seTr, 0x20'i32):
        var seSeen = 0
        var seNames = ""
        nb = arFindActiveNamedBFS(seTr, "NextButton", ArSideNextDepth,
                                  ArMaxSideNext, seSeen, seNames)
        if nb != nil and nb == gXrLastPressed:
          nb = nil                # the same object as last time: not progress
    if nb == nil:
      nb = arFindActiveAcross("Session End UI", "NextButton", gXrLastPressed)
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
  gXrSaidNoRecv = false
  gXrSaidNoDisc = false
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
  # The PMC/SCAV side selector. MEASURED 2026-09-02: this is the screen the
  # main-menu PLAY button leads to, so without this site the step after PLAY is
  # a poll, and the poll had nothing to look for -- it hunted a
  # `CharacterSelectionScreen` that is not there after PLAY at all.
  uihWant(UihSiteSideSelect)
  # The LOCATION LIST. Without this the machine has to hunt a screen whose
  # GameObject name contains spaces, from the scene roots, while a character
  # model sits in the same subtree -- which is the search that has failed three
  # times this session.
  uihWant(UihSiteLocation)
  # The generic table's screens. A row whose site is not wanted is a row whose
  # screen this machine cannot see arrive.
  var wrow = 0
  while wrow < ArScrN:
    let ws = arScrSite(wrow)
    if ws >= 0: uihWant(ws)
    wrow = wrow + 1
  # THE EXIT HALF. `raidexit` is an on-demand verb, so these are wanted
  # whenever the inspector is on as well as when autoraid is: a site nobody
  # wanted is never patched, and an unpatched site puts the exit half back to
  # searching DontDestroyOnLoad from inside a raid, which cannot work.
  uihWant(UihSiteShowInRaid)
  uihWant(UihSiteSessionEnd)
  # SITES 1 AND 2 ARE DELIBERATELY NOT WANTED HERE, AND THIS IS A REGRESSION
  # FIX, NOT A PREFERENCE. MEASURED 2026-09-02: wanting them from this feature
  # (i.e. whenever `liveInspector` is on) bound `MenuScreen::Awake` for the
  # FIRST TIME on any build this project has run, and the very next boot died
  # at MENU ARRIVAL -- no Settings, no raid -- in
  # `SeasonWidgetData::From @0x141FFD0+0x133` under
  # `MenuScreen::Show(5-arg) @0x15387A0+0x994`, with the host's last line being
  # `uihooks: FIRST show event -- EFT.UI.MenuScreen::Awake`. `Awake` runs
  # immediately before `Show`, and `Show` then read a bad Profile. Three boots,
  # three deaths; every surviving build tonight had site 1 UNBOUND.
  #
  # Site 2 is left to `modload`, which is who wanted it on every build that
  # survived. This feature READS both through `uihSelf`, which returns nil for
  # an unbound site -- so the ladder degrades to the sites it does want, and
  # nothing here depends on a detour it did not ask for.

proc arShowHookVerdict() =
  ## Read back whether it actually BOUND, after `uihArm`. Announced either way:
  ## without it this machine has no positive readback that a screen arrived and
  ## falls back to its per-step timeout, which is exactly the failure mode this
  ## change exists to remove.
  if not gArOn and not gInspOn: return
  var vrow = 0
  while vrow < ArScrN:
    let vs = arScrSite(vrow)
    if vs >= 0:
      if uihBound(vs):
        okLog "autoRaid: the " & arScrName(vrow) & "'s show event is LIVE " &
              "(uihooks site " & $vs & "), so SCREEN-NEXT advances it from " &
              "its own receiver."
      else:
        warn "autoRaid: uihooks site " & $vs & " (" & arScrName(vrow) &
             ") did NOT bind, so that screen's arrival is invisible to this " &
             "machine and the flow will stall there. The reason is in the " &
             "`uihooks:` lines above."
    vrow = vrow + 1
  if uihBound(UihSiteShowInRaid):
    okLog "raidExit: the in-raid menu's show event is LIVE -- " &
          "MenuScreen::ShowInRaid @0x1539650 (uihooks site 7) is bound, so " &
          "the exit half takes the MenuScreen from the event instead of " &
          "searching scene roots that, during a raid, do not include " &
          "DontDestroyOnLoad."
  else:
    warn "raidExit: uihooks site 7 (MenuScreen::ShowInRaid) did NOT bind, so " &
         "the exit half falls back to the scene-root search -- which MEASURED " &
         "2026-09-02 finds nothing at all in a raid. Expect SHOW-IN-RAID to " &
         "refuse. The reason is in the `uihooks:` lines above."
  if uihBound(UihSiteSessionEnd):
    okLog "raidExit: the session-end UI's arrival is LIVE (uihooks site 8, " &
          "SessionEndUI::Awake @0x1726850) -- a CONSTRUCTION event, used only " &
          "to obtain the receiver for the results pages, never as proof that " &
          "they are populated."
  else:
    warn "raidExit: uihooks site 8 (SessionEndUI::Awake) did NOT bind; the " &
         "results pages fall back to the `Session End UI` scene-root name."
  if uihBound(UihSiteLocation):
    okLog "autoRaid: the LOCATION list's show event is LIVE -- " &
          "MatchMakerSelectionLocationScreen::Show @0x178ACB0 (uihooks site " &
          "4) is bound, so SELECT-MAP is entered on the screen's own arrival " &
          "and works from the receiver the game handed us."
  else:
    warn "autoRaid: uihooks site 4 (MatchMakerSelectionLocationScreen::Show) " &
         "did NOT bind, so SELECT-MAP falls back to the LEGACY all-roots " &
         "toggle scan. The reason is in the `uihooks:` lines above."
  if uihBound(UihSiteSideSelect):
    okLog "autoRaid: the SIDE selector's show event is LIVE -- " &
          "MatchMakerSideSelectionScreen::Show @0x1790180 (uihooks site 3) is " &
          "bound, so the step after PLAY is driven by the screen's own show " &
          "event and gets the screen's pointer from the game, with no name " &
          "search at all."
  else:
    warn "autoRaid: uihooks site 3 (MatchMakerSideSelectionScreen::Show) did " &
         "NOT bind, so the step after PLAY has no show event and will " &
         "grace-skip after " & $(int(ArSideGraceMs div 1000'u64)) & " s. The " &
         "reason is in the `uihooks:` lines above."
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
    let st = (if gArStep >= 0 and gArStep < gArStepFaults.len: gArStep
              else: ArFailed + 1)
    gArStepFaults[st] = gArStepFaults[st] + 1
    warn "autoRaid: the guarded tick body faulted (" & $gArStepFaults[st] &
         " of " & $ArMaxFaults & " for step " & arStepName(gArStep) &
         "; " & $gArFaults & " in the session across all steps), in: " &
         arCrumbName(gArCrumb) & ". The crumb is set immediately before each " &
         "operation that touches live managed memory, so this names WHERE it " &
         "died rather than only THAT it died. THE BUDGET IS PER STEP: a fault " &
         "one step recovered from must not spend another step's budget."
    if gArStepFaults[st] >= ArMaxFaults:
      arFail("step " & arStepName(gArStep) & " faulted " & $gArStepFaults[st] &
             " times, in: " & arCrumbName(gArCrumb))
