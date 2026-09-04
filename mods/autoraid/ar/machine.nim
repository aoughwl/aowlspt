## ar/machine.nim -- THE RAID-ENTRY STATE MACHINE.
##
## A port of `host/Aowlspt.Host.Il2Cpp/autoraid.nim` into a mod. Every state,
## every bound, every readback line and every refusal census is the host's, and
## every measurement it rests on was made against the live client. What CHANGED
## in the port is stated here, in full, because a port that quietly drops a
## lesson is worse than no port:
##
## 1. **No detour, and no rider on one.** The host adds `autoRaidDrainTick()` to
##    the `EFT.TarkovApplication::Update` slot it already owns. A mod may not:
##    a second detour on one function overwrites the first's trampoline and
##    silently kills the first feature. This runs on `everyMain` -- once per host
##    drain, which on this host is once per frame, on Unity's own thread -- and
##    holds ONE scheduler slot.
##
## 2. **No scene-root enumeration, at all.** The host falls back to walking the
##    `DontDestroyOnLoad` roots. This mod never does, for two measured reasons:
##    `Scene::GetRootGameObjects` ALLOCATES (a List and an array), which is
##    banned on a per-frame path; and MEASURED 2026-09-02 that enumeration is the
##    LOCATION scene once a raid has loaded, so it cannot see the menu at all --
##    `raidexit` refused for exactly that reason with `step SHOW-IN-RAID found
##    nothing` while the menu was alive.
##
##    Instead EVERY screen comes from its own `::Show` receiver, delivered by the
##    host's `ui.show` bus (`ar/showbus.nim`), and anything that needs a scene
##    root climbs to it with `Transform::get_root` FROM a receiver the game
##    handed us. That is the repo's own rule -- reach a container by WALKING from
##    a verified live object, never by an offset or an enumeration that can
##    legitimately read empty -- applied without an exception.
##
## 3. **The legacy `NEXT->x` steps are GONE, not disabled.** The host still
##    carries `ArNext1..ArReady`, which hunt an active `NextButton` across the
##    scene roots. Those steps were MEASURED WRONG THREE TIMES in one session,
##    each time timing out at 45 s against a census that already showed the
##    screen up. They are replaced by two honest WAIT states (`WAIT-LOCATION`,
##    `WAIT-OFFLINE`) that wait for a show EVENT and refuse with a census if it
##    never comes. Keeping a superseded path "just in case" is how a run quietly
##    becomes the weaker one.
##
## 4. **One guard per CALL, not one per tick.** The host wraps its whole body in
##    a single `aowl_p_p_seh`. `aowlspt/callrva` refuses to arm inside another
##    guard, so this mod cannot -- and does not need to: every game call is
##    individually guarded and every read is `VirtualQuery`-gated. Nothing is
##    ever nested. See `ar/native.nim`'s header.
##
## 5. **The fault budget is measured, not inferred.** The host counts ticks where
##    its guarded body did not return. Here the process-wide guarded-call fault
##    counter is sampled before and after each tick and the DELTA is attributed
##    to the step that was running, with a CRUMB naming the operation. That is
##    strictly better information than the host had, and the budget stays PER
##    STEP for the host's own measured reason: on 2026-09-02 one PRE-MENU fault
##    that the retry recovered from, plus two SIDE faults, tripped a session-wide
##    budget of three and switched the whole feature off. A recovered fault in
##    one step must not spend another step's budget.
##
## THE FLOW, and what each step ASSERTS rather than assumes
## -------------------------------------------------------
##   WAIT-MENU     an ACTIVE, PRESSABLE `PlayButton` under a `MenuScreen`
##                 receiver -- found and pressed in the SAME tick
##   [PRE-MENU]    only if the button is found and INACTIVE with a SettingsScreen
##                 over it; the finished state is THE MENU BEING USABLE
##   SIDE          from site 3's receiver: press the side control, then THAT
##                 screen's own NextButton; readback = the screen goes INACTIVE
##   WAIT-LOCATION site 4 fires
##   SELECT-MAP    from site 4's receiver: press the tile whose Label reads the
##                 wanted map, then THAT screen's own NextButton; readback = the
##                 screen goes INACTIVE
##   WAIT-OFFLINE  site 0 fires
##   SCREEN-NEXT   the generic table -- offline raid (site 0), insurance (site 5),
##                 accept (site 6). Press THAT screen's own NextButton from THAT
##                 receiver; readback = it goes INACTIVE
##   DONE          the accept screen advanced. THE RAID IS LOADING. This machine
##                 makes NO call into the game ever again this session, because
##                 touching the UI during the load errors matchmaking (fact #261).

import aowlspt
import aowlspt/il2cpp
import aowlspt/callrva
import native
import calls
import uitree
import press
import showbus
import phase

# ---------------------------------------------------------------------------
# Bounds. Every one of these is the host's, and each is a number somebody had to
# learn.
# ---------------------------------------------------------------------------

const
  TickFrames*     = 30
    ## Frames between attempts -- about half a second at 60 fps. The machine
    ## self-paces: at most ONE find and ONE press per attempt, so it never races
    ## the menu.
  MinActionMs*    = 700'i64
    ## Minimum gap between two presses, so a screen has time to transition.
  MenuWaitMs*     = 180000'i64
    ## WAIT-MENU's bound. The menu can take well over 60 s on a cold launch.
  StepTimeoutMs*  = 45000'i64
    ## Every other step's bound.
  SideGraceMs*    = 12000'i64
    ## How long SIDE waits for its show event before concluding this flow does
    ## not have a side selector and continuing. Nothing is claimed on that path.
  SettleMs*       = 6000'i64
    ## After pressing a screen's NextButton, how long before "still active" is
    ## worth complaining about.
  WaitEventMs*    = 20000'i64
    ## How long a WAIT state waits for its show event before saying, out loud,
    ## that it has no evidence the screen arrived.
  PreSettleMs*    = 4000'i64
    ## After a PRE-MENU dismissal attempt, how long the overlay may still read
    ## active before another attempt is allowed.
  MaxPreTries*    = 2
    ## PRE-MENU dismissal attempts, EVER. Then it refuses by name.
  MaxSidePresses* = 2
    ## Presses of the side control, EVER. Then the step refuses rather than
    ## mashing a control that is not advancing anything.
  MaxPlayExtends* = 6
    ## Popup-wait extensions on WAIT-MENU. The daily-reward `RewardInfo` popup
    ## deactivates MenuScreen for 30-60 s AFTER the menu first loads, hiding
    ## PLAY. "Seen once, then hidden" is a transient popup, not a refusal --
    ## extend the wait rather than self-disable. Bounded, so it cannot spin.
  MaxMenuScreens* = 3
    ## Corpse safety. The popup REBUILDS MenuScreen/PlayButton, so the first
    ## MenuScreen by name can be the DEAD instance whose PlayButton is inactive
    ## while a live one exists under a second. Low, so the collect cannot recurse
    ## the whole subtree hunting phantoms and starve its slice.
  MaxTiles*       = 96
    ## ACTIVE nodes collected on the location screen. There is one tile per map
    ## plus the templates, so a count AT the cap is visibly a truncation in the
    ## refusal rather than looking like an absence.
  MaxSideProbe*   = 40
    ## Nodes probed inside one side container.
  MaxSideNext*    = 96
    ## ACTIVE nodes examined when looking for a screen's own NextButton. Large
    ## enough that a truncation shows up AT the cap.
  MaxStepFaults*  = 3
    ## Guarded-call faults attributed to ONE step before that step refuses.

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------

const
  StWaitMenu*     = 0
  StPreMenu*      = 1
  StSide*         = 2
  StWaitLocation* = 3
  StSelectMap*    = 4
  StWaitOffline*  = 5
  StScreen*       = 6
  StDone*         = 7
  StFailed*       = 8
  StepCount*      = 9

proc stepName*(s: int): string =
  case s
  of StWaitMenu:     "WAIT-MENU"
  of StPreMenu:      "PRE-MENU"
  of StSide:         "SIDE"
  of StWaitLocation: "WAIT-LOCATION"
  of StSelectMap:    "SELECT-MAP"
  of StWaitOffline:  "WAIT-OFFLINE"
  of StScreen:       "SCREEN-NEXT"
  of StDone:         "DONE"
  else:              "FAILED"

# ---------------------------------------------------------------------------
# The generic screen table. Adding the next screen in the chain is ONE ROW and
# a site -- the driver below does not change. That is the whole reason it is a
# table: the same 45-second refusal was hand-written three times before it was.
# ---------------------------------------------------------------------------

const
  RowOfflineRaid* = 0
  RowInsurance*   = 1
  RowAccept*      = 2
  RowCount*       = 3

proc rowSite(row: int): int =
  ## Row -> uihooks site. THE ONLY mapping, so a row cannot mean two different
  ## things in two places.
  case row
  of RowOfflineRaid: SiteOfflineRaid
  of RowInsurance:   SiteInsurance
  of RowAccept:      SiteAccept
  else: -1

proc rowName(row: int): string =
  case row
  of RowOfflineRaid: "offline raid screen"
  of RowInsurance:   "insurance screen"
  of RowAccept:      "accept screen (its READY is itself a NextButton)"
  else: "unknown row"

proc rowIsLast(row: int): bool =
  ## The row after which the raid is LOADING and this mod must go hands-off.
  ## Pressing anything during the load errors matchmaking (fact #261), so this
  ## is the one row whose success ends the machine.
  row == RowAccept

# ---------------------------------------------------------------------------
# Crumbs. AN INT, deliberately: assigning a string literal to a module-level var
# allocates, and this is set several times per tick on the live path. The text
# is produced only when a fault is actually being reported.
#
# MEASURED 2026-09-02, in the host: `the guarded tick body faulted (1 of 3)`
# fired during PRE-MENU moments before the BackButton press succeeded, and named
# neither the step nor the operation. It cost a third of the session's fault
# budget and told nobody anything. A fault that cannot say where it was is a
# fault that will be paid for again.
# ---------------------------------------------------------------------------

var gCrumb = 0

proc crumbName(c: int): string =
  case c
  of 0:  "tick entry"
  of 1:  "polling the show-event epochs"
  of 2:  "WAIT-MENU: collecting MenuScreens under the site-2 receiver"
  of 3:  "WAIT-MENU: finding an ACTIVE, PRESSABLE PlayButton"
  of 4:  "WAIT-MENU: pressing the MenuScreen PlayButton"
  of 5:  "WAIT-MENU/PRE-MENU: looking for an ACTIVE SettingsScreen overlay"
  of 6:  "PRE-MENU: walking the SettingsScreen subtree for its BackButton"
  of 7:  "PRE-MENU: pressing the SettingsScreen BackButton"
  of 8:  "PRE-MENU: calling SettingsScreen::Close"
  of 9:  "SIDE: walking the site-3 receiver for the pmc/scav container"
  of 10: "SIDE: breadth-first walk INSIDE the wanted side's scope"
  of 11: "SIDE: reading DefaultUIButton._text on a candidate"
  of 12: "SIDE: pressing the side control"
  of 13: "SIDE: pressing this screen's own NextButton"
  of 14: "SIDE: the screen-INACTIVE readback"
  of 15: "SELECT-MAP: breadth-first walk of the location screen for tiles"
  of 16: "SELECT-MAP: reading a tile's Label TMP text"
  of 17: "SELECT-MAP: setting the map tile's AnimatedToggle"
  of 18: "SELECT-MAP: pressing this screen's own NextButton"
  of 19: "SELECT-MAP: the screen-INACTIVE readback"
  of 20: "SCREEN-NEXT: reading the practice/offline toggle"
  of 21: "SCREEN-NEXT: setting the practice/offline toggle"
  of 22: "SCREEN-NEXT: BFS for this screen's own NextButton"
  of 23: "SCREEN-NEXT: pressing this screen's own NextButton"
  of 24: "SCREEN-NEXT: the screen-INACTIVE readback"
  of 25: "the step-timeout census"
  else:  "unknown (" & $c & ")"

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

var gOn = false            ## armed. DEFAULT OFF; nothing runs until armed.
var gOff = false           ## self-disabled after faults or a timed-out step
var gStep = StWaitMenu
var gStepT0 = 0'i64
var gFrames = 0
var gMap = "Woods"
var gSide = "pmc"
var gStage = "IDLE"
var gAnswer = ""
var gStepFaults: array[StepCount, int]
var gFaultBase = 0
var gLastActionMs = 0'i64
var gCensused = false

var gPlaySeen = false
var gPlayExtends = 0
var gWaitLogMs = 0'i64
var gPreTries = 0
var gPreActMs = 0'i64
var gPreVia = "nothing"
var gPreAttempted = false
var gPreDismissed = 0

var gSideEpoch = 0
var gSidePresses = 0
var gSideNextDone = false
var gSideNextMs = 0'i64
var gSideLogMs = 0'i64
var gSideNamesLogged = false
var gSideAnswered = 0

var gLocEpoch = 0
var gLocPressed = false
var gLocNextDone = false
var gLocNextMs = 0'i64
var gLocLogMs = 0'i64
var gLocNamesLogged = false

var gScrEpoch: array[RowCount, int]
var gScrIdx = -1
var gScrPressed = false
var gScrMs = 0'i64
var gScrLogMs = 0'i64
var gScrDone = 0
var gPracticeChecked = false
var gWaitEventT0 = 0'i64

proc stage*(): string = gStage
proc answer*(): string = gAnswer
proc armed*(): bool = gOn
proc finished*(): bool = gStep == StDone
proc failed*(): bool = gStep == StFailed
proc wantedMap*(): string = gMap
proc screensAdvanced*(): int = gScrDone

proc goto(s: int) =
  gStep = s
  gStepT0 = nowMs()
  gStage = stepName(s)

proc fail(why: string) =
  gOff = true
  gStep = StFailed
  gStage = "FAILED"
  gAnswer = "FAILED: " & why
  warn "AutoRaid: " & why & " -- switching itself off for this session and " &
       "leaving the menu alone. This is a REFUSAL, not a success."

# ---------------------------------------------------------------------------
# The census a refusal carries.
#
# A refusal that says "the control never became visible" has named only what we
# failed to find. A census names what the client actually had ACTIVE, which is
# what settles where the flow really is. It climbs to the scene root FROM a
# receiver the game handed us, so it is never a search for a root by name.
# ---------------------------------------------------------------------------

proc anyReceiverTransform(): Il2CppPtr =
  ## Any live screen receiver, for climbing to a root. Preference order is by
  ## how likely the screen is to still be up, and every candidate is validated
  ## before it is returned.
  result = screenTransform(SiteMenuShow)
  if result != nil: return
  result = screenTransform(SiteSideSelect)
  if result != nil: return
  result = screenTransform(SiteLocation)
  if result != nil: return
  result = screenTransform(SiteOfflineRaid)
  if result != nil: return
  result = screenTransform(SiteInsurance)
  if result != nil: return
  result = screenTransform(SiteAccept)

proc screenCensus(): string =
  ## What is ACTIVE near the menu, at depth <= 2 from the scene root reached by
  ## climbing from a live receiver.
  gCrumb = 25
  let anchor = anyReceiverTransform()
  if anchor == nil:
    return " (no live screen receiver at all, so there is nothing to climb " &
           "from and NOTHING was examined -- this is INCONCLUSIVE, not an " &
           "empty screen)"
  let root = rootOf(anchor)
  if root == nil:
    return " (a receiver is live but Transform::get_root refused, so nothing " &
           "was examined -- INCONCLUSIVE)"
  result = " " & nodeName(root) & censusUnder(root, 2)

# ---------------------------------------------------------------------------
# WAIT-MENU: the PlayButton, found and pressed atomically.
# ---------------------------------------------------------------------------

proc menuRoot(): Il2CppPtr =
  ## `Common UI` -- reached by climbing from the `MenuScreen::Show` receiver
  ## rather than by enumerating scene roots. Nil means the menu has never been
  ## shown in this process, which is a different fact from "the menu is not up
  ## now" and callers keep them apart.
  let tr = screenTransform(SiteMenuShow)
  if tr == nil: return nil
  result = rootOf(tr)

proc findPlayButton(nMs, nPb, nActive: var int;
                    kind: var PressKind; comp: var Il2CppPtr): Il2CppPtr =
  ## The ACTIVE, PRESSABLE `PlayButton`, re-found FRESH every tick.
  ##
  ## MenuScreen-first, and COLLECT-ALL rather than first-by-name: the
  ## daily-reward `RewardInfo` popup rebuilds the MenuScreen/PlayButton
  ## GameObjects during its cycle, so the FIRST MenuScreen by name can be the
  ## DEAD old instance whose PlayButton is inactive while a brand-new ACTIVE one
  ## exists under a SECOND, live MenuScreen. Trying every MenuScreen and taking
  ## the first pressable PlayButton finds the live one without a parent-climb,
  ## which rejected valid buttons live.
  ##
  ## Nothing is cached across ticks. `nMs`/`nPb`/`nActive` accumulate so that a
  ## tick which finds nothing can log exactly WHY -- roots reached, MenuScreens
  ## found, PlayButtons under them, how many were active -- instead of producing
  ## a silent 180-second timeout.
  result = nil
  kind = pkNone
  comp = nil
  nMs = 0; nPb = 0; nActive = 0
  let root = menuRoot()
  if root == nil: return
  gCrumb = 2
  var menus: seq[Il2CppPtr] = @[]
  var b = NodeBudget
  collect(root, "MenuScreen", FindDepth, b, deadlineNow(), menus, MaxMenuScreens)
  nMs = menus.len
  var mi = 0
  while mi < menus.len:
    gCrumb = 3
    var pbs: seq[Il2CppPtr] = @[]
    var b2 = NodeBudget
    # A FRESH SLICE PER MenuScreen. The collect above may well have exhausted
    # the previous one -- it recurses looking for more MenuScreens than exist --
    # and sharing a deadline here is exactly what starved the PlayButton search
    # to zero in the host's first cut.
    collect(menus[mi], "PlayButton", FindDepth, b2, deadlineNow(), pbs, 8)
    nPb = nPb + pbs.len
    var pi = 0
    while pi < pbs.len:
      let pb = pbs[pi]
      if isActive(pb):
        nActive = nActive + 1
        if result == nil:
          var c: Il2CppPtr = nil
          let k = controlOn(pb, c)
          # BOTH active AND pressable. A same-named wrapper GameObject is active
          # and carries no button; returning it is what made the atomic press a
          # no-op while the machine advanced believing it had acted.
          if k != pkNone and pressable(pb, k, c):
            result = pb
            kind = k
            comp = c
      pi = pi + 1
    if result != nil: return
    mi = mi + 1

proc overlayScreen(): Il2CppPtr =
  ## The ACTIVE `SettingsScreen`, scoped to the menu root. ONLY ACTIVE nodes are
  ## returned, so a screen that merely EXISTS in the hierarchy -- which
  ## SettingsScreen always does -- is not mistaken for an overlay.
  gCrumb = 5
  result = nil
  let root = menuRoot()
  if root == nil: return
  var b = NodeBudget
  result = walkActive(root, "SettingsScreen", FindDepth, b, deadlineNow(), nil)

# ---------------------------------------------------------------------------
# PRE-MENU
#
# MEASURED 2026-09-02: `raid Woods` issued with Settings open sat in WAIT-MENU
# for its whole 180 s bound and refused with `MenuScreen found=1, PlayButton
# under it=1, active=0`. The button was found and INACTIVE because SettingsScreen
# was over it. The refusal was CORRECT; the machine simply had no way to clear
# the overlay.
#
# THE LADDER, bounded at MaxPreTries attempts TOTAL:
#   1. THE GAME'S OWN BACK PATH -- that screen's OWN Back control, scoped to ITS
#      subtree, pressed through the same validated route every other press here
#      uses. That is what a human click runs, and it is the handler that
#      RESTORES THE MENU.
#   2. `SettingsScreen::Close()` -- FALLBACK ONLY.
#
# THE ORDER WAS SWAPPED BY MEASUREMENT. `Close()` was attempt 1 and it HID the
# settings screen: its own readback passed -- "no ACTIVE SettingsScreen remains"
# -- and then WAIT-MENU sat for its whole bound, because there was no MenuScreen
# active at all. Close hides the screen WITHOUT restoring the menu. That is the
# exact shape of a check that cannot fail: the step asserted the thing it had
# just done rather than the thing it was for.
#
# So the FINISHED STATE here is THE MENU BEING USABLE -- an ACTIVE, PRESSABLE
# PlayButton, obtained from the SAME `findPlayButton` WAIT-MENU uses, so the two
# cannot disagree -- and neither attempt is believed without it.
#
# CHATSCREEN IS NEVER TOUCHED. MEASURED: it read ACTIVE in BOTH menu censuses
# taken on 2026-09-02, once with Settings over the menu and once with the menu
# working normally and PLAY pressable. It is a normal part of the menu, not an
# overlay.
# ---------------------------------------------------------------------------

proc pressBackUnder(ss: Il2CppPtr; names: var string; nSeen: var int;
                    why: var string): bool =
  ## Attempt 1: the screen's OWN Back control, scoped to ITS subtree.
  ##
  ## Scoped is the operative word. An all-roots hunt for `BackButton` is the
  ## search that refuses (fact #243), and this mod could not do it anyway.
  result = false
  why = ""
  names = ""
  nSeen = 0
  if ss == nil:
    why = "no live SettingsScreen to search"
    return
  gCrumb = 6
  var kind = pkNone
  var comp: Il2CppPtr = nil
  let back = findPressable(ss, "BackButton", ScreenDepth, MaxSideNext,
                           nSeen, names, kind, comp)
  if back != nil:
    gCrumb = 7
    var via = ""
    var w = ""
    if press(back, kind, comp, via, w):
      return true
    why = "the SettingsScreen's own ACTIVE `BackButton` was found but not " &
          "pressed -- " & w
    return
  why = "no ACTIVE, PRESSABLE node named `BackButton` under the screen " &
        "itself (BFS, depth " & $ScreenDepth & ", cap " & $MaxSideNext &
        ", examined " & $nSeen & " ACTIVE node(s): " &
        (if names.len > 0: names else: "<none>") &
        "). Searched THAT SUBTREE ONLY -- never a hunt across scene roots, " &
        "which is the search that refuses (fact #243)."

proc closeSettings(ss: Il2CppPtr; why: var string): bool =
  ## Call the screen's own `Close()`. Returns whether the CALL was MADE -- NOT
  ## whether the screen went away, and certainly not whether the menu came back.
  ## A handler that returns normally is not evidence of anything.
  result = false
  why = ""
  gCrumb = 8
  var w = ""
  let comp = componentOf(ss, TypeRvaSettingsScreen, w)
  if comp == nil:
    why = "the ACTIVE object named `SettingsScreen` carries no " &
          "EFT.UI.Settings.SettingsScreen component (" & w & "), so there is " &
          "no receiver for Close() and nothing was called"
    return
  result = settingsClose(comp, why)

# ---------------------------------------------------------------------------
# SIDE
#
# THE STRUCTURE, read off the live client with the inspector (2026-09-02):
#
#   MatchMaker Side Selection Screen           <- the site-3 receiver
#     +- PMCs                                  <- the container for BOTH sides
#     |    +- PMCPlayerMV                      <- the PMC character MODEL (deep)
#     |    +- AnimatedToggleSpawner -> AnimatedToggle    <- the PMC control
#     |    +- Button                                     <- and its Button
#     |    +- ScavPlayerMV                     <- the SCAV side, NESTED INSIDE
#     |    |    +- AnimatedToggleSpawner          the PMC container
#     |    |    +- Button
#     |    +- RandomToggleSpawner -> RandomToggle
#     +- ScreenDefaultButtons -> NextButton, BackButton
#
# So "the PMC control" cannot be found by a name containing "pmc" -- the controls
# are called `AnimatedToggle` and `Button` -- and cannot be found by a caption
# either, because they carry no `DefaultUIButton` and therefore no `_text`. It is
# a STRUCTURAL fact: the PMC control is the first control under `PMCs` that is
# NOT inside a `scav` subtree, and the SCAV control is the first one inside it.
# That is what the `skip` argument of `collectBFS` expresses, and it is why the
# walk must be a TRUE level-by-level BFS: a breadth-per-node walk recurses into
# `PMCPlayerMV` and spends its whole cap in the character mesh.
# ---------------------------------------------------------------------------

proc pressSideUnder(scr: Il2CppPtr; want: string; nSeen: var int;
                    names: var string; why: var string): bool =
  result = false
  nSeen = 0
  names = ""
  why = ""
  if scr == nil:
    why = "no live side screen"
    return

  # Phase 1 -- the container, breadth-first from the screen.
  gCrumb = 9
  var all: seq[Il2CppPtr] = @[]
  var b0 = NodeBudget
  collectBFS(scr, ScreenDepth, b0, deadlineNow(), all, MaxSideNext, "")
  var cont: Il2CppPtr = nil
  var i = 0
  while i < all.len:
    let nm = lower(nodeName(all[i]))
    if nm.len > 0 and (contains(nm, "pmc") or contains(nm, "scav")):
      cont = all[i]
      break
    i = i + 1
  if cont == nil:
    why = "no ACTIVE node under the live side screen has a name mentioning " &
          "`pmc` or `scav`, so there is no container to walk into. NOTHING " &
          "WAS PRESSED -- this is a refusal, not a miss"
    return

  # Phase 2 -- narrow to the wanted SIDE inside that container.
  var scope = cont
  var skip = ""
  let wantScav = contains(want, "scav")
  if wantScav:
    gCrumb = 10
    var inner: seq[Il2CppPtr] = @[]
    var b1 = NodeBudget
    collectBFS(cont, ScreenDepth, b1, deadlineNow(), inner, MaxSideProbe, "")
    var found: Il2CppPtr = nil
    var j = 0
    while j < inner.len:
      if contains(lower(nodeName(inner[j])), "scav"):
        found = inner[j]
        break
      j = j + 1
    if found == nil:
      why = "wanted the SCAV side but no ACTIVE node named `*scav*` exists " &
            "under the container. NOTHING WAS PRESSED"
      return
    scope = found
  else:
    skip = "scav"

  # Phase 3 -- the first node in that scope that CARRIES a control.
  gCrumb = 10
  var nodes: seq[Il2CppPtr] = @[]
  var b2 = NodeBudget
  nodes.add scope                       # the scope itself may carry the control
  collectBFS(scope, ScreenDepth, b2, deadlineNow(), nodes, MaxSideProbe, skip)
  var hit: Il2CppPtr = nil
  var hitComp: Il2CppPtr = nil
  var hitKind = pkNone
  var ni = 0
  while ni < nodes.len:
    var comp: Il2CppPtr = nil
    let k = controlOn(nodes[ni], comp)
    if k != pkNone:
      nSeen = nSeen + 1
      gCrumb = 11
      let cap = (if k == pkDefaultUI: buttonCaption(comp) else: "")
      if names.len < MaxNamesLen:
        names = names & "[" & nodeName(nodes[ni]) & " " & kindName(k) &
                (if cap.len > 0: " caption=" & cap else: "") & "]"
      # PREFER THE TOGGLE: it is the control the screen's own spawner created
      # for this side. The bare `UnityEngine.UI.Button` beside it is taken only
      # if no toggle is found.
      if k == pkToggle and (hit == nil or hitKind != pkToggle):
        hit = nodes[ni]; hitComp = comp; hitKind = k
      elif hit == nil:
        hit = nodes[ni]; hitComp = comp; hitKind = k
    ni = ni + 1

  if hit == nil:
    why = "walked the " &
          (if wantScav: "`scav` subtree"
           else: "`pmc` container with `scav` subtrees EXCLUDED") &
          " level by level and found NO node carrying an AnimatedToggle, a " &
          "DefaultUIButton or a UnityEngine.UI.Button (" & $nodes.len &
          " active node(s) probed, cap " & $MaxSideProbe & "). NOTHING WAS " &
          "PRESSED"
    return
  gCrumb = 12
  var via = ""
  var w = ""
  if press(hit, hitKind, hitComp, via, w):
    success "AutoRaid SIDE: pressed the " & kindName(hitKind) & " on `" &
            nodeName(hit) & "` for side \"" & want & "\" via " & via &
            ", chosen STRUCTURALLY (the control under the container that is " &
            (if wantScav: "INSIDE" else: "NOT inside") &
            " the scav subtree), because these controls have neither a " &
            "matching name nor a caption to match on. Candidates: " & names
    return true
  why = "the " & kindName(hitKind) & " on `" & nodeName(hit) & "` was found " &
        "but not pressed -- " & w

# ---------------------------------------------------------------------------
# SELECT-MAP
#
# THE STRUCTURE, read off the live screen with the inspector (2026-09-02):
#
#   Matchmaker Location Selection              <- the site-4 receiver
#     +- Content -> Map -> Image
#     |    +- "Location Template(Clone)"       <- ONE PER MAP, ALL IDENTICALLY
#     |         |                                 NAMED, so the object name
#     |         |                                 cannot select a map
#     |         +- Info -> Text                <- reads "NOT AVAILABLE" etc:
#     |         |                                 a STATUS, a red herring
#     |         +- Button Panel
#     |              +- AnimatedToggle         <- the control
#     |                   +- SizeLabel
#     |                        +- Label        <- TMP, reads "WOODS"
#     +- ScreenDefaultButtons -> NextButton, BackButton
#
# So the map is chosen by THE TEXT A PERSON READS on the toggle's Label, and the
# press is a TOGGLE -- which is why it goes through `Toggle::Set` and not
# through a UnityEvent at a guessed offset.
# ---------------------------------------------------------------------------

proc pressMapTileUnder(scr: Il2CppPtr; want: string; nTiles: var int;
                       names: var string; why: var string): bool =
  result = false
  nTiles = 0
  names = ""
  why = ""
  if scr == nil:
    why = "no live location screen"
    return
  gCrumb = 15
  var toggles: seq[Il2CppPtr] = @[]
  var b = NodeBudget
  collectBFS(scr, ScreenDepth + 2, b, deadlineNow(), toggles, MaxTiles, "")
  var i = 0
  while i < toggles.len:
    if nodeName(toggles[i]) == "AnimatedToggle":
      nTiles = nTiles + 1
      gCrumb = 16
      let lbl = labelUnderName(toggles[i], "Label", MapDepth)
      if names.len < MaxNamesLen:
        names = names & "[" & (if lbl.len > 0: lbl else: "<unreadable>") & "]"
      if lbl.len > 0 and lower(trim(lbl)) == want:
        gCrumb = 17
        var comp: Il2CppPtr = nil
        let k = controlOn(toggles[i], comp)
        if k != pkToggle:
          why = "the tile whose Label reads \"" & lbl & "\" matched, but it " &
                "carries no EFT.UI.AnimatedToggle (" & kindName(k) & "), so " &
                "there is nothing to set. NOTHING WAS PRESSED."
          return
        var via = ""
        var w = ""
        if press(toggles[i], k, comp, via, w):
          success "AutoRaid SELECT-MAP: pressed the tile whose Label reads \"" &
                  lbl & "\" via " & via & ". Tiles offered: " & names
          return true
        why = "the tile whose Label reads \"" & lbl & "\" matched but was not " &
              "pressed -- " & w
        return
    i = i + 1
  why = "no location tile under the live screen has a Label reading \"" &
        want & "\". " & $nTiles & " tile toggle(s) examined; the maps ON " &
        "OFFER are " & (if names.len > 0: names else: "<none readable>") &
        ". NOTHING WAS PRESSED -- ask for one of those"

# ---------------------------------------------------------------------------
# SCREEN-NEXT's one pre-action: the practice/offline toggle.
# ---------------------------------------------------------------------------

proc assertPracticeToggle(scr: Il2CppPtr) =
  ## READ AND LOG the practice/offline toggle, and set it ONLY if it reads OFF.
  ##
  ## This toggle decides whether the raid routes to the emulated backend, so its
  ## state is worth a line in the log whatever it is: "I set it" and "it was
  ## already on" are DIFFERENT FACTS and both are reported.
  ##
  ## HONEST LIMIT: the host's `singleplayerRebrand` deactivates this checkbox's
  ## GameObject on purpose, so with that feature on the toggle is INACTIVE and
  ## this finds nothing. That is reported as "not found", NEVER as "off".
  if scr == nil or gPracticeChecked: return
  gPracticeChecked = true
  gCrumb = 20
  var nodes: seq[Il2CppPtr] = @[]
  var b = NodeBudget
  collectBFS(scr, ScreenDepth + 2, b, deadlineNow(), nodes, MaxTiles, "")
  var i = 0
  while i < nodes.len:
    if nodeName(nodes[i]) == "AnimatedToggle":
      let lbl = lower(labelUnderName(nodes[i], "Label", MapDepth))
      if lbl.len > 0 and (contains(lbl, "practice") or contains(lbl, "offline")):
        var comp: Il2CppPtr = nil
        let k = controlOn(nodes[i], comp)
        if k != pkToggle: return
        var ok = false
        let isOn = readBoolField(comp, OffToggleIsOn, ok)
        if not ok:
          warn "AutoRaid SCREEN-NEXT: found the practice toggle but could NOT " &
               "read m_IsOn@0x120 on it. Its state is UNKNOWN -- which is not " &
               "the same as off, and NOTHING was pressed."
          return
        if isOn:
          success "AutoRaid SCREEN-NEXT: the practice/offline toggle already " &
                  "reads m_IsOn=TRUE; nothing was pressed. The raid should " &
                  "route to the emulated backend."
          return
        success "AutoRaid SCREEN-NEXT: the practice/offline toggle reads " &
                "m_IsOn=FALSE. Setting it via Toggle::Set(true, true)."
        gCrumb = 21
        var via = ""
        var w = ""
        if not press(nodes[i], k, comp, via, w):
          warn "AutoRaid SCREEN-NEXT: could not set the practice toggle -- " &
               w & ". The raid may not route offline; this is ANNOUNCED, not " &
               "silently accepted."
        return
    i = i + 1
  info "AutoRaid SCREEN-NEXT: no ACTIVE toggle under the offline raid screen " &
       "has a Label mentioning practice/offline, so its state was NOT read. " &
       "With the host's `singleplayerRebrand` on this is EXPECTED -- that " &
       "feature deactivates the checkbox's GameObject deliberately -- and it " &
       "is reported as `not found`, never as `off`."

# ---------------------------------------------------------------------------
# Arming
# ---------------------------------------------------------------------------

proc reset(map, side: string) =
  gMap = map
  gSide = side
  gOn = true
  gOff = false
  gStep = StWaitMenu
  gStepT0 = nowMs()
  gFrames = TickFrames          # act on THIS tick, not in half a second
  gLastActionMs = 0'i64
  gCensused = false
  gPlaySeen = false
  gPlayExtends = 0
  gWaitLogMs = 0'i64
  gPreTries = 0
  gPreActMs = 0'i64
  gPreVia = "nothing"
  gPreAttempted = false
  gSidePresses = 0
  gSideNextDone = false
  gSideNextMs = 0'i64
  gSideLogMs = 0'i64
  gSideNamesLogged = false
  gLocPressed = false
  gLocNextDone = false
  gLocNextMs = 0'i64
  gLocLogMs = 0'i64
  gLocNamesLogged = false
  gScrIdx = -1
  gScrPressed = false
  gScrMs = 0'i64
  gScrLogMs = 0'i64
  gPracticeChecked = false
  gWaitEventT0 = 0'i64
  var i = 0
  while i < StepCount:
    gStepFaults[i] = 0
    i = i + 1
  # SNAPSHOT EVERY EPOCH. An event from BEFORE this arming is not evidence about
  # this run, and consuming a stale one would resynchronise the machine to a
  # screen that is no longer up.
  gSideEpoch = snapshotEpoch(SiteSideSelect)
  gLocEpoch = snapshotEpoch(SiteLocation)
  gScrEpoch[RowOfflineRaid] = snapshotEpoch(SiteOfflineRaid)
  gScrEpoch[RowInsurance] = snapshotEpoch(SiteInsurance)
  gScrEpoch[RowAccept] = snapshotEpoch(SiteAccept)
  noteFaultBase()
  gFaultBase = int(faultCount())
  gStage = stepName(gStep)

proc arm*(map, side, reason: string; why: var string): bool =
  ## Arm the machine. MAIN THREAD ONLY -- it reads the live tree through
  ## `snapshotEpoch`/`receiverOf`.
  ##
  ## REFUSES, rather than trying and failing later:
  ##   * while a request is already running -- a second arming would restart the
  ##     machine mid-flow and press the wrong screen's button;
  ##   * while a live `GameWorld` is readable, i.e. WE ARE ALREADY IN A RAID.
  ##     A null GameWorld is deliberately NOT claimed as proof of the menu; only
  ##     the positive is tested.
  ##   * with an empty or absurd map label. 32 characters is the host's own cap
  ##     and it is kept so the two cannot disagree about what is acceptable.
  why = ""
  if gOn and not gOff and gStep != StDone and gStep != StFailed:
    why = "a raid-entry request is already running (step " & stepName(gStep) &
          ", map \"" & gMap & "\"). Refusing to restart it mid-flow: that " &
          "would press the wrong screen's button."
    return false
  let m = trim(map)
  if m.len == 0:
    why = "no map label was given, and there is no default worth guessing " &
          "at -- say which map"
    return false
  if m.len > 32:
    why = "the map label is " & $m.len & " characters; 32 is the cap"
    return false
  let p = raidPhase()
  if inRaid(p):
    why = "the client is already in a raid (phase " & p.phase &
          (if p.gameWorld: ", a live GameWorld is readable" else: "") &
          "). This is a REFUSAL and it will not be retried: driving the main " &
          "menu from inside a raid presses into a UI that is not there. Leave " &
          "the raid first."
    return false
  if callsDisabled():
    why = "the mod's call surface has self-disabled after repeated faults, so " &
          "nothing will be pressed. Nothing was armed."
    return false
  reset(m, lower(trim(side)))
  gAnswer = "ARMED, map \"" & gMap & "\", side \"" & gSide & "\", step WAIT-MENU"
  success "AutoRaid: ARMED (" & reason & "), map \"" & gMap & "\", side \"" &
          gSide & "\" -- the state machine starts at WAIT-MENU on the next " &
          "main-thread tick. If the main menu is not up, WAIT-MENU will time " &
          "out and say so: BEING ARMED IS NOT BEING IN A RAID."
  result = true

# ---------------------------------------------------------------------------
# The show-event watcher, run at the top of every tick. One integer compare per
# site: no walk, no call into the game.
# ---------------------------------------------------------------------------

proc watchEvents(now: int64) =
  gCrumb = 1
  let sep = epochOf(SiteSideSelect)
  if sep != gSideEpoch:
    gSideEpoch = sep
    gSideNextDone = false
    gSidePresses = 0
    if gStep == StWaitMenu or gStep == StSide or gStep == StPreMenu:
      success "AutoRaid: READBACK -- MatchMakerSideSelectionScreen::Show fired " &
              "(uihooks site 3, epoch " & $sep & "). The PMC/SCAV side " &
              "selector is UP, which is an OBSERVATION, not a guess, and its " &
              "receiver came with the event. Step SIDE."
      goto(StSide)
    else:
      info "AutoRaid: site 3 fired (epoch " & $sep & ") while at step " &
           stepName(gStep) & "; noted, no resynchronisation."

  let lep = epochOf(SiteLocation)
  if lep != gLocEpoch:
    gLocEpoch = lep
    gLocPressed = false
    gLocNextDone = false
    if gStep == StSide or gStep == StWaitLocation or gStep == StSelectMap:
      success "AutoRaid: READBACK -- MatchMakerSelectionLocationScreen::Show " &
              "fired (uihooks site 4, epoch " & $lep & "). The location list " &
              "is UP. Going straight to SELECT-MAP: there is nothing to press " &
              "to reach a screen that is already here, and pressing anyway is " &
              "how the old NEXT->location step timed out three times against " &
              "a census that already showed this screen."
      goto(StSelectMap)
    else:
      info "AutoRaid: site 4 fired (epoch " & $lep & ") while at step " &
           stepName(gStep) & "; noted, no resynchronisation."

  # THE GENERIC TABLE. Whichever row's screen announces itself becomes the
  # current screen, and SCREEN-NEXT advances it from THAT receiver.
  var row = 0
  while row < RowCount:
    let site = rowSite(row)
    if site >= 0:
      let e = epochOf(site)
      if e != gScrEpoch[row]:
        gScrEpoch[row] = e
        if gStep != StDone and gStep != StFailed:
          gScrIdx = row
          gScrPressed = false
          gScrMs = 0'i64
          success "AutoRaid: READBACK -- the " & rowName(row) & " announced " &
                  "itself (uihooks site " & $site & ", epoch " & $e & "). " &
                  "SCREEN-NEXT will press THAT screen's own NextButton, from " &
                  "THAT receiver -- the only thing that has ever worked here."
          goto(StScreen)
    row = row + 1

# ---------------------------------------------------------------------------
# The tick
# ---------------------------------------------------------------------------

proc advanceScreen(now: int64) =
  ## The GENERIC driver. One body for every screen in the table.
  if gScrIdx < 0:
    if now - gScrLogMs > 5000'i64:
      gScrLogMs = now
      warn "AutoRaid SCREEN-NEXT: no current screen row, which should be " &
           "impossible in this step. Nothing was pressed."
    return
  let tr = screenTransform(rowSite(gScrIdx))
  if tr == nil:
    if now - gScrLogMs > 5000'i64:
      gScrLogMs = now
      warn "AutoRaid SCREEN-NEXT: the " & rowName(gScrIdx) & "'s receiver is " &
           "no longer readable or is destroyed, so there is nothing to press " &
           "on. Waiting for the step timeout, which will refuse with a census."
    return

  if not gScrPressed:
    if gScrIdx == RowOfflineRaid:
      assertPracticeToggle(tr)
    gCrumb = 22
    var seen = 0
    var names = ""
    var kind = pkNone
    var comp: Il2CppPtr = nil
    let nb = findPressable(tr, "NextButton", ScreenDepth, MaxSideNext,
                           seen, names, kind, comp)
    if nb == nil:
      if now - gScrLogMs > 5000'i64:
        gScrLogMs = now
        warn "AutoRaid SCREEN-NEXT: NO ACTIVE, PRESSABLE node named " &
             "`NextButton` under the " & rowName(gScrIdx) & "'s OWN receiver " &
             "-- level-by-level BFS, depth " & $ScreenDepth & ", cap " &
             $MaxSideNext & ", examined " & $seen & " ACTIVE node(s): " &
             (if names.len > 0: names else: "<none>") &
             ". NOTHING WAS PRESSED. The names are the evidence: if " &
             "`NextButton` is in that list the comparison is wrong; if the " &
             "count is AT the cap the search was truncated; if it is tiny the " &
             "receiver is not the screen."
      return
    gCrumb = 23
    var via = ""
    var w = ""
    if press(nb, kind, comp, via, w):
      gScrPressed = true
      gScrMs = now
      gLastActionMs = now
      success "AutoRaid: SCREEN-NEXT -- pressed the " & rowName(gScrIdx) &
              "'s own NextButton via " & via & ", from its own show receiver. " &
              "PRESSED IS NOT ADVANCED: the readback is this screen going " &
              "INACTIVE, and then the next screen's show event."
    elif now - gScrLogMs > 5000'i64:
      gScrLogMs = now
      warn "AutoRaid SCREEN-NEXT: found the " & rowName(gScrIdx) &
           "'s ACTIVE `NextButton` but it was not pressed -- " & w
    return

  # PRESSED: the readback, and it is a NEGATIVE.
  gCrumb = 24
  if not screenActive(rowSite(gScrIdx)):
    gScrDone = gScrDone + 1
    let wasLast = rowIsLast(gScrIdx)
    success "AutoRaid: READBACK -- the " & rowName(gScrIdx) & " is no longer " &
            "active after its own NextButton. Screens advanced this session: " &
            $gScrDone & "." &
            (if wasLast:
               " That was the ACCEPT screen, so the raid is now LOADING: this " &
               "mod goes HANDS-OFF and will not touch the UI again this " &
               "session (touching it during the load errors matchmaking)."
             else:
               " Waiting for the next screen's show event; if none arrives " &
               "this step times out and refuses with a census.")
    gScrIdx = -1
    gScrPressed = false
    gLastActionMs = now
    if wasLast:
      gAnswer = "DONE: the accept screen advanced; the raid is loading"
      goto(StDone)
    return
  if now - gScrMs > SettleMs:
    warn "AutoRaid SCREEN-NEXT: the " & rowName(gScrIdx) & " is STILL ACTIVE " &
         $int(now - gScrMs) & " ms after its own NextButton was pressed. The " &
         "press ran and did NOT advance the screen; the step timeout will " &
         "refuse with a census."
    gScrMs = now

proc tickBody(now: int64) =
  watchEvents(now)

  # A settle gap after every press, so a screen has time to transition.
  if gLastActionMs != 0'i64 and now - gLastActionMs < MinActionMs: return

  if gStepT0 == 0'i64: gStepT0 = now
  let bound = (if gStep == StWaitMenu: MenuWaitMs else: StepTimeoutMs)
  if now - gStepT0 > bound:
    # WAIT-MENU is patient about a TRANSIENT popup. "Seen once, then hidden" is
    # a popup, not a refusal. If PLAY was NEVER seen, the menu genuinely did not
    # come up and this DOES fail out.
    if gStep == StWaitMenu and gPlaySeen and gPlayExtends < MaxPlayExtends:
      gPlayExtends = gPlayExtends + 1
      gStepT0 = now
      warn "AutoRaid: the MenuScreen PlayButton was SEEN but is currently " &
           "hidden (a daily-reward popup is most likely up over MenuScreen); " &
           "still waiting for it to clear (extension " & $gPlayExtends &
           " of " & $MaxPlayExtends & ")."
      return
    var c = ""
    if not gCensused:
      gCensused = true
      c = screenCensus()
    fail("step " & stepName(gStep) & " never completed within " &
         $(int(bound div 1000'i64)) & " s." &
         (if gStep == StSide:
            " Wanted the side control for \"" & gSide & "\"."
          else: "") &
         " Show events seen while armed: side=" & $firesFor(SiteSideSelect) &
         " location=" & $firesFor(SiteLocation) &
         " offline-raid=" & $firesFor(SiteOfflineRaid) &
         " insurance=" & $firesFor(SiteInsurance) &
         " accept=" & $firesFor(SiteAccept) &
         "; ui.show payloads seen in total: " & $eventsSeen() &
         (if c.len > 0: ". ACTIVE:" & c else: ""))
    return

  # ---- WAIT-MENU (and PLAY, which is the same step) ------------------------
  #
  # The instant the MenuScreen PlayButton reads visible, PRESS IT IN THE SAME
  # TICK. The two-step form re-clocked a fresh 45 s PLAY window exactly as the
  # RewardInfo popup came up and hid the button, so PLAY self-disabled though
  # the button had been visible moments earlier. Pressing on first-visible wins
  # that race; if the popup IS up, the find returns nil and we wait patiently
  # above for it to clear.
  if gStep == StWaitMenu:
    var nMs = 0
    var nPb = 0
    var nAct = 0
    var kind = pkNone
    var comp: Il2CppPtr = nil
    let pb = findPlayButton(nMs, nPb, nAct, kind, comp)
    if pb != nil:
      gPlaySeen = true
      gCrumb = 4
      var via = ""
      var w = ""
      if press(pb, kind, comp, via, w):
        success "AutoRaid: menu ready -- pressed PLAY (MenuScreen PlayButton, " &
                "atomic find-and-press, via " & via & "); driving into an " &
                "OFFLINE raid on map \"" & gMap & "\". The screen after PLAY " &
                "is the PMC/SCAV side selector, which grace-skips itself if " &
                "its show event never arrives."
        gLastActionMs = now
        goto(StSide)
      elif now - gWaitLogMs > 5000'i64:
        gWaitLogMs = now
        warn "AutoRaid WAIT-MENU: an ACTIVE, pressable PlayButton was found " &
             "and the press did not go through -- " & w
      return

    # FOUND BUT INACTIVE IS A DIFFERENT FACT FROM NOT FOUND. A PlayButton that
    # exists under a found MenuScreen and reads inactive means something is OVER
    # the menu -- MEASURED: Settings. That is not a reason to wait 180 s; it is
    # a reason to clear the overlay. Checked at most once every 5 s and ONLY in
    # this already-stuck case, so the common path pays nothing for it.
    if nMs > 0 and nPb > 0 and nAct == 0 and now - gWaitLogMs > 5000'i64:
      let ov = overlayScreen()
      if ov == nil and gPreAttempted:
        var c = ""
        if not gCensused:
          gCensused = true
          c = screenCensus()
        fail("WAIT-MENU refusing IMMEDIATELY rather than waiting out its " &
             $(int(MenuWaitMs div 1000'i64)) & " s bound: PRE-MENU has " &
             "already dismissed an overlay (via " & gPreVia & ") and there is " &
             "now NO ACTIVE SettingsScreen and STILL no ACTIVE, pressable " &
             "MenuScreen PlayButton (MenuScreens=" & $nMs & ", PlayButtons=" &
             $nPb & ", active=" & $nAct & "). The settings screen was HIDDEN " &
             "WITHOUT THE MENU BEING RESTORED, which is exactly what " &
             "SettingsScreen::Close alone does (MEASURED 2026-09-02). Nothing " &
             "further here will make the menu appear" &
             (if c.len > 0: ". ACTIVE:" & c else: ""))
        return
      if ov != nil and gPreTries < MaxPreTries:
        gWaitLogMs = now
        success "AutoRaid WAIT-MENU: MenuScreen and its PlayButton were FOUND " &
                "but the button is INACTIVE, and an ACTIVE `SettingsScreen` " &
                "is over the menu. That is an OVERLAY, not a slow menu. Going " &
                "to PRE-MENU to dismiss it (attempt " & $(gPreTries + 1) &
                " of " & $MaxPreTries & "). ChatScreen is a normal part of " &
                "the menu and is never touched."
        goto(StPreMenu)
        return
    if now - gWaitLogMs > 10000'i64:
      gWaitLogMs = now
      info "AutoRaid WAIT-MENU: MenuScreen found=" & $nMs &
           ", PlayButton under it=" & $nPb & ", active=" & $nAct &
           " (nothing pressable this tick). Menu receiver from uihooks site 2 " &
           "is " & (if menuRoot() != nil: "live" else: "NOT AVAILABLE -- the " &
           "menu has not been shown in this process, or site 2 did not bind") &
           "."
    return

  # ---- PRE-MENU ------------------------------------------------------------
  if gStep == StPreMenu:
    # (a) THE FINISHED STATE: THE MENU BEING USABLE. Not "no ACTIVE
    # SettingsScreen" -- that check PASSED on 2026-09-02 while the menu never
    # came back, which makes it a check that cannot fail for what this step is
    # actually for. Asked with the very same function WAIT-MENU uses, so the two
    # can never disagree.
    var nMs = 0
    var nPb = 0
    var nAct = 0
    var kind = pkNone
    var comp: Il2CppPtr = nil
    let pb = findPlayButton(nMs, nPb, nAct, kind, comp)
    if pb != nil:
      if gPreTries > 0:
        gPreDismissed = gPreDismissed + 1
        success "AutoRaid PRE-MENU: dismissed the overlay via " & gPreVia &
                " -- READBACK: the MenuScreen PlayButton is ACTIVE and " &
                "PRESSABLE again (MenuScreens=" & $nMs & ", PlayButtons=" &
                $nPb & ", active=" & $nAct & "). That is THE MENU BEING " &
                "USABLE, not merely the settings screen being hidden. " &
                "Overlays cleared this session: " & $gPreDismissed & "."
      else:
        info "AutoRaid PRE-MENU: the menu became usable before anything was " &
             "attempted (the player closed the overlay, most likely). " &
             "Nothing was called and nothing is claimed; back to WAIT-MENU."
      gPreTries = 0
      gStepT0 = 0'i64
      goto(StWaitMenu)
      return

    let ov = overlayScreen()
    # (b) settle after an attempt before judging it or trying again.
    if gPreTries > 0 and now - gPreActMs < PreSettleMs: return
    # (c) nothing left to try, or nothing left to dismiss: REFUSE, by name.
    if gPreTries >= MaxPreTries or (ov == nil and gPreTries > 0):
      var c = ""
      if not gCensused:
        gCensused = true
        c = screenCensus()
      fail("step PRE-MENU -- THE MAIN MENU DID NOT COME BACK. After " &
           $gPreTries & " dismissal attempt(s) (last via " & gPreVia &
           ") there is still no ACTIVE, pressable MenuScreen PlayButton " &
           "(MenuScreens=" & $nMs & ", PlayButtons=" & $nPb & ", active=" &
           $nAct & "), and SettingsScreen is " &
           (if ov == nil:
              "no longer active -- so it was HIDDEN WITHOUT THE MENU BEING " &
              "RESTORED, which is exactly what SettingsScreen::Close alone " &
              "does (MEASURED 2026-09-02)"
            else: "STILL ACTIVE") &
           (if c.len > 0: ". ACTIVE:" & c else: ""))
      return
    if ov == nil:
      info "AutoRaid PRE-MENU: no ACTIVE SettingsScreen and no pressable " &
           "PlayButton either, with nothing attempted yet. There is nothing " &
           "here to dismiss; back to WAIT-MENU."
      gStepT0 = 0'i64
      goto(StWaitMenu)
      return

    # (d) THE LADDER.
    var why = ""
    if gPreTries == 0:
      gPreTries = 1
      gPreAttempted = true
      gPreActMs = now
      gLastActionMs = now
      gPreVia = "the screen's own BackButton, scoped to the ACTIVE " &
                "SettingsScreen"
      var names = ""
      var seen = 0
      if pressBackUnder(ov, names, seen, why):
        success "AutoRaid PRE-MENU: pressed " & gPreVia & ". PRESSED IS NOT " &
                "RESTORED -- the readback is the next tick finding an ACTIVE, " &
                "PRESSABLE MenuScreen PlayButton, not merely the settings " &
                "screen going away."
      else:
        warn "AutoRaid PRE-MENU: the BackButton press did not go through -- " &
             why & ". Falling back to SettingsScreen::Close on the next " &
             "attempt, which is MEASURED to hide the screen WITHOUT restoring " &
             "the menu, so expect the refusal above rather than a success."
      return
    gPreTries = gPreTries + 1
    gPreAttempted = true
    gPreActMs = now
    gLastActionMs = now
    gPreVia = "SettingsScreen::Close @0x1720B10"
    if closeSettings(ov, why):
      success "AutoRaid PRE-MENU: called " & gPreVia & " on the ACTIVE " &
              "SettingsScreen (FALLBACK -- this hides the screen and is " &
              "MEASURED NOT to restore the menu). CALLED IS NOT RESTORED: the " &
              "readback is an ACTIVE, pressable PlayButton."
    else:
      warn "AutoRaid PRE-MENU: could not call SettingsScreen::Close either -- " &
           why
    return

  # ---- SIDE ----------------------------------------------------------------
  if gStep == StSide:
    let scr = screenTransform(SiteSideSelect)

    # (a) THE SIDE IS CHOSEN: press THIS SCREEN'S OWN NextButton.
    #
    # Handing straight to a generic "find a NextButton" step was MEASURED wrong:
    # that step searched for the NEXT screen's button and never pressed this
    # one, so the side screen stayed up until the step timed out 45 s later with
    # the census still showing `[MatchMaker Side Selection Screen]`. The button
    # is a SIBLING subtree of the side controls -- `ScreenDefaultButtons ->
    # NextButton` -- and it carries `EFT.UI.DefaultUIButton`.
    if gSidePresses > 0 and not gSideNextDone:
      if scr == nil:
        if now - gSideLogMs > 5000'i64:
          gSideLogMs = now
          warn "AutoRaid SIDE: the side was chosen but the site-3 receiver is " &
               "no longer readable, so this screen's own NextButton cannot be " &
               "resolved. NOTHING WAS PRESSED."
        return
      gCrumb = 13
      var seen = 0
      var names = ""
      var kind = pkNone
      var comp: Il2CppPtr = nil
      let nb = findPressable(scr, "NextButton", ScreenDepth, MaxSideNext,
                             seen, names, kind, comp)
      if nb == nil:
        if now - gSideLogMs > 5000'i64:
          gSideLogMs = now
          warn "AutoRaid SIDE: NO ACTIVE, PRESSABLE node named `NextButton` " &
               "under the site-3 receiver -- level-by-level BFS, depth " &
               $ScreenDepth & ", cap " & $MaxSideNext & ", examined " & $seen &
               " ACTIVE node(s): " & (if names.len > 0: names else: "<none>") &
               ". NOTHING WAS PRESSED."
        return
      var via = ""
      var w = ""
      if press(nb, kind, comp, via, w):
        gSideNextDone = true
        gSideNextMs = now
        gLastActionMs = now
        success "AutoRaid: step SIDE -- pressed THIS screen's own NextButton " &
                "via " & via & ", resolved from the site-3 receiver's own " &
                "subtree. PRESSED IS NOT ADVANCED: the readback is this " &
                "screen going INACTIVE."
      elif now - gSideLogMs > 5000'i64:
        gSideLogMs = now
        warn "AutoRaid SIDE: found this screen's ACTIVE `NextButton` but it " &
             "was not pressed -- " & w
      return

    if gSideNextDone:
      # THE READBACK, and it is a NEGATIVE.
      gCrumb = 14
      if not screenActive(SiteSideSelect):
        gSideAnswered = gSideAnswered + 1
        success "AutoRaid: READBACK -- the MatchMakerSideSelectionScreen is no " &
                "longer active after its own NextButton. Side \"" & gSide &
                "\" is committed as far as this mod can observe. Waiting for " &
                "MatchMakerSelectionLocationScreen::Show (site 4). Side " &
                "screens got past this session: " & $gSideAnswered & "."
        gSidePresses = 0
        gSideNextDone = false
        gLastActionMs = now
        gWaitEventT0 = now
        goto(StWaitLocation)
        return
      if now - gSideNextMs > SettleMs and gSidePresses < MaxSidePresses:
        warn "AutoRaid SIDE: the side screen is STILL ACTIVE " &
             $int(now - gSideNextMs) & " ms after its own NextButton was " &
             "pressed. Retrying the side control and NEXT once more (attempt " &
             $(gSidePresses + 1) & " of " & $MaxSidePresses & ")."
        gSideNextDone = false
        gSidePresses = 0
      return

    if scr == nil:
      # (b) NO SCREEN. Either its show event never came, or a human answered it.
      # Not an error -- and never claimed as a success either.
      if now - gStepT0 > SideGraceMs:
        success "AutoRaid: step SIDE -- no live MatchMakerSideSelectionScreen " &
                "within " & $(int(SideGraceMs div 1000'i64)) & " s of " &
                "pressing PLAY (site-3 show events seen while armed: " &
                $firesFor(SiteSideSelect) & "). NOTHING was pressed and " &
                "NOTHING is claimed; waiting for the location list instead. " &
                "If a side selector IS on screen then its ::Show did not fire " &
                "or did not bind -- read the host's `uihooks:` lines, not this " &
                "step."
        gWaitEventT0 = now
        goto(StWaitLocation)
      return

    var nSeen = 0
    var names = ""
    var why = ""
    let pressed = pressSideUnder(scr, gSide, nSeen, names, why)
    if not gSideNamesLogged and nSeen > 0:
      gSideNamesLogged = true
      info "AutoRaid SIDE: " & $nSeen & " node(s) carrying a control in the " &
           "wanted side's scope: " & names & " -- side \"" & gSide & "\" is " &
           "chosen STRUCTURALLY (both sides live under `PMCs`; the scav one " &
           "is nested in a `*scav*` subtree), because these controls carry no " &
           "DefaultUIButton and therefore no caption to match on."
    if pressed:
      gSidePresses = gSidePresses + 1
      gLastActionMs = now
    elif now - gSideLogMs > 5000'i64:
      gSideLogMs = now
      warn "AutoRaid SIDE: the side selector is up and NOTHING was pressed -- " &
           why
    return

  # ---- WAIT-LOCATION / WAIT-OFFLINE ---------------------------------------
  #
  # These are the two places the host pressed a `NextButton` hunted across the
  # scene roots. They are WAITS now, and they say so out loud when the event
  # does not come, rather than pressing something to feel busy.
  if gStep == StWaitLocation or gStep == StWaitOffline:
    let site = (if gStep == StWaitLocation: SiteLocation else: SiteOfflineRaid)
    if gWaitEventT0 == 0'i64: gWaitEventT0 = now
    if now - gWaitEventT0 > WaitEventMs:
      gWaitEventT0 = now
      var c = ""
      if not gCensused:
        gCensused = true
        c = screenCensus()
      warn "AutoRaid " & stepName(gStep) & ": " &
           $(int(WaitEventMs div 1000'i64)) & " s have passed and " &
           siteName(site) & " (uihooks site " & $site & ") has NOT fired, so " &
           "this mod has NO evidence that screen came up. It is NOT pressing " &
           "anything on a guess: the previous design hunted a NextButton " &
           "across the scene roots here and timed out three separate times " &
           "against a census that already showed the screen. The step timeout " &
           "will refuse. Check whether the host bound site " & $site & "." &
           (if c.len > 0: " ACTIVE:" & c else: "")
    return

  # ---- SELECT-MAP ----------------------------------------------------------
  if gStep == StSelectMap:
    let scr = screenTransform(SiteLocation)
    if scr == nil:
      if now - gLocLogMs > 5000'i64:
        gLocLogMs = now
        warn "AutoRaid SELECT-MAP: the site-4 receiver is not readable or is " &
             "destroyed, so the tiles cannot be reached from the screen the " &
             "game handed us. NOTHING WAS PRESSED, and no fallback hunt is " &
             "attempted -- that hunt is the thing that does not work."
      return

    if gLocPressed and not gLocNextDone:
      gCrumb = 18
      var seen = 0
      var names = ""
      var kind = pkNone
      var comp: Il2CppPtr = nil
      let nb = findPressable(scr, "NextButton", ScreenDepth, MaxSideNext,
                             seen, names, kind, comp)
      if nb == nil:
        if now - gLocLogMs > 5000'i64:
          gLocLogMs = now
          warn "AutoRaid SELECT-MAP: the map was chosen but NO ACTIVE, " &
               "PRESSABLE node named `NextButton` was found under the site-4 " &
               "receiver -- BFS, depth " & $ScreenDepth & ", cap " &
               $MaxSideNext & ", examined " & $seen & " ACTIVE node(s): " &
               (if names.len > 0: names else: "<none>") & ". NOTHING WAS PRESSED."
        return
      var via = ""
      var w = ""
      if press(nb, kind, comp, via, w):
        gLocNextDone = true
        gLocNextMs = now
        gLastActionMs = now
        success "AutoRaid: step SELECT-MAP -- pressed THIS screen's own " &
                "NextButton via " & via & ", resolved from the site-4 " &
                "receiver's subtree. PRESSED IS NOT ADVANCED: the readback is " &
                "this screen going INACTIVE."
      elif now - gLocLogMs > 5000'i64:
        gLocLogMs = now
        warn "AutoRaid SELECT-MAP: found this screen's ACTIVE `NextButton` " &
             "but it was not pressed -- " & w
      return

    if gLocNextDone:
      gCrumb = 19
      if not screenActive(SiteLocation):
        success "AutoRaid: READBACK -- the location list is no longer active " &
                "after its own NextButton; map \"" & gMap & "\" is committed " &
                "as far as this mod can observe. Waiting for " &
                "MatchmakerOfflineRaidScreen::Show (site 0)."
        gLastActionMs = now
        gWaitEventT0 = now
        goto(StWaitOffline)
        return
      if now - gLocNextMs > SettleMs:
        warn "AutoRaid SELECT-MAP: the location list is STILL ACTIVE " &
             $int(now - gLocNextMs) & " ms after its own NextButton was " &
             "pressed. The press ran and did NOT advance the screen; the step " &
             "timeout will refuse with a census."
        gLocNextMs = now
      return

    var nTiles = 0
    var tileNames = ""
    var why = ""
    if pressMapTileUnder(scr, lower(trim(gMap)), nTiles, tileNames, why):
      gLocPressed = true
      gLastActionMs = now
    else:
      if not gLocNamesLogged and nTiles > 0:
        gLocNamesLogged = true
        info "AutoRaid SELECT-MAP: " & $nTiles & " location tile(s) on offer, " &
             "by the Label a person reads: " & tileNames & " -- wanted \"" &
             gMap & "\". Tile OBJECT names are ALL `Location Template(Clone)` " &
             "on this build, so the displayed text is the only thing that " &
             "identifies a map."
      if now - gLocLogMs > 5000'i64:
        gLocLogMs = now
        warn "AutoRaid SELECT-MAP: " & why
    return

  # ---- SCREEN-NEXT ---------------------------------------------------------
  if gStep == StScreen:
    advanceScreen(now)
    return

proc tick*() =
  ## ONE main-thread tick. Called from `everyMain`, so it is on Unity's own
  ## thread, once per host drain.
  ##
  ## CHEAP WHEN IDLE: not armed, self-disabled, done or failed is a handful of
  ## integer compares and makes NO call into the game at all. That matters
  ## because this runs every frame for the whole session.
  if not gOn or gOff: return
  if gStep == StDone or gStep == StFailed: return
  gFrames = gFrames + 1
  if gFrames < TickFrames: return
  gFrames = 0

  gCrumb = 0
  let before = int(faultCount())
  tickBody(nowMs())
  let after = int(faultCount())

  # THE FAULT BUDGET, PER STEP, with the crumb naming the operation.
  if after > before:
    let d = after - before
    let st = (if gStep >= 0 and gStep < StepCount: gStep else: StFailed)
    gStepFaults[st] = gStepFaults[st] + d
    warn "AutoRaid: " & $d & " guarded call(s) FAULTED this tick (" &
         $gStepFaults[st] & " of " & $MaxStepFaults & " for step " &
         stepName(gStep) & "), in: " & crumbName(gCrumb) & ". The crumb is " &
         "set immediately before each operation that touches live managed " &
         "memory, so this names WHERE it died rather than only THAT it died. " &
         "THE BUDGET IS PER STEP: a fault one step recovered from must not " &
         "spend another step's budget."
    if gStepFaults[st] >= MaxStepFaults:
      fail("step " & stepName(gStep) & " faulted " & $gStepFaults[st] &
           " times, in: " & crumbName(gCrumb))
