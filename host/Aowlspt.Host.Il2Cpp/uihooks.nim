# uihooks.nim -- SHOW-EVENT hooks for menu screens. The mechanism that replaces
# per-frame hunting.
#
# THE PROBLEM THIS EXISTS FOR (measured, not supposed)
# ----------------------------------------------------
# Four cosmetic features in this host looked for their control by walking the
# live Unity tree on a cadence, forever, on the Unity main thread. The
# singleplayer rebrand is the worst of them: today's `aowlspt-host.log` carries
#
#   singleplayer rebrand: not resolved -- BUDGET, not absence: the scan for node
#   "MainCaption" under screen "Matchmaker Offline Raid Screen" (scan reached
#   level 4 of 12, visited 64 node(s)) was CUT OFF by the WALL-CLOCK SLICE (18 ms)
#
# repeated at ~100 ms intervals for the whole session, plus the periodic "yielded
# no targets on 20 consecutive re-scans; dropping the cached screen and re-walking
# the scene roots". That is ~64 nodes of interop per 18 ms slice at ~10 Hz,
# producing NOTHING, for as long as the client runs -- and Tarkov is main-thread
# bound, so every millisecond of it is taken from bot AI and rendering.
#
# The screens it hunts for appear exactly ONCE, on a definite user action. The
# game already announces that action.
#
# WHAT THIS IS
# ------------
# A tiny registry of screen SHOW SITES. A feature calls `uihWant(site)` before
# arming; `uihArm` installs ONE byte-verified POSTFIX detour per wanted site;
# when the game shows that screen the detour hands the live screen object
# straight to the feature, which applies its change once and goes idle.
#
# Between events the cost is exactly ZERO -- not "a cheap poll", zero: nothing in
# this file runs off a frame tick at all. The subscriber's own rider still ticks,
# but it can return on a single integer compare (`uihEpoch(site)` unchanged).
#
# THE SITE TABLE LIVES IN C (`abi/aowlspt_uihooks.h`) and carries, per site, the
# RVA, the SHAREDNESS verdict, and the 16 prologue bytes. `aowl_uih_site_at`
# VirtualQuerys for committed executable memory and memcmps the prologue before
# handing back a pointer, and names the refusal when it does not.
#
# SAFETY (the eight rules), stated for THIS file specifically:
#   1. prologue byte-verify -- in `aowl_uih_site_at`, before every bind. A
#      mismatch REFUSES and logs which of the two causes it is (another detour
#      got there first == hook ORDER, or a different game build).
#   2. every pointer hop guarded -- the only pointer this file dereferences is
#      the detour's `regs`, through `cRegsInt`, and the receiver, through `duOk`
#      + `iUnityAlive` before it is handed to anyone.
#   3. ONE `aowl_p_p_seh` per body -- THIS FILE OPENS NONE. It is a dispatcher.
#      The subscriber opens its own single guard (splrebrand's
#      `cSplTickGuarded`), exactly as `settingsTabInitFired` does for the
#      settings probe. Opening one here would NEST inside the subscriber's and
#      DISARM it.
#   4. capped iteration -- the only loops here are over `UihSiteCount` (3).
#   5. flag-gated default OFF -- nothing is wanted, and therefore nothing is
#      bound, unless a feature's own default-OFF flag asked for it.
#   6. self-disable after N faults -- delegated: the subscriber's guard counts
#      its own faults and switches itself off. This file additionally stops
#      dispatching to a site once `UihMaxDispatchFaults` dispatches into it have
#      come back faulted, so a broken subscriber cannot make every screen open
#      cost a fault.
#   7. no per-frame managed allocation -- nothing here runs per frame.
#   8. never blind-write -- this file writes nothing into the game at all.
#
# WHY NOT ONE UNIVERSAL HOOK, and why not `ScreenController`2::ShowScreen`:
# both answered in the header's banner. Short form: identifying the screen from
# a shared base hook needs the receiver's class, and `il2cpp_object_get_class`
# is `mov rax,[rcx]; ret` -- it hands back a plausible number for a bad pointer
# instead of failing; and `ScreenController`2::ShowScreen` is an uninstantiated
# generic with RVA `None` (docs/NATIVE_SCREEN_NAV.md sec.2).

{.emit: """#include "aowlspt_uihooks.h" """.}

proc cUihSiteCount(): int32 {.importc: "aowl_uih_site_count", nodecl.}
proc cUihSiteAt(i: int32): Il2CppPtr {.importc: "aowl_uih_site_at", nodecl.}
proc cUihSiteName(i: int32): Il2CppPtr {.importc: "aowl_uih_site_name", nodecl.}
proc cUihSiteRva(i: int32): uint32 {.importc: "aowl_uih_site_rva", nodecl.}
proc cUihReasonCode(): int32 {.importc: "aowl_uih_reason_code", nodecl.}
proc cUihReasonText(c: int32): Il2CppPtr {.importc: "aowl_uih_reason_text", nodecl.}

const
  UihSiteOfflineRaid = 0
    ## `EFT.UI.Matchmaker.MatchmakerOfflineRaidScreen::Show(controller)`
    ## @0x1788590, UNIQUE. RCX = the live screen.
  UihSiteMenuScreen  = 1
    ## `EFT.UI.MenuScreen::Awake()` @0x1538360, UNIQUE. RCX = the live
    ## MenuScreen. A CONSTRUCTION event, not a show event -- see the header and
    ## docs/UIHOOKS.md before subscribing to it.
  UihSiteMenuShow    = 2
    ## `EFT.UI.MenuScreen::Show(MatchmakerPlayersController, ExpansionsPlayerInfo,
    ## GameModeDescriptor, Profile, SeasonalRewardController)` @0x15387A0,
    ## UNIQUE. RCX = the live MenuScreen.
    ##
    ## This IS a show event, not a construction event: it is the private 5-arg
    ## overload the public `Show(MainMenuBaseScreenController)` calls, and it
    ## takes the `Profile`, so it cannot run before a profile has been chosen.
    ## `modload.nim` uses it as the ORDERING fact that gates the deferred mod
    ## release -- see the header entry for the honest limit (a postfix on it
    ## means the body ran, NOT that the menu is fully populated).
  UihSiteSideSelect  = 3
    ## `EFT.UI.Matchmaker.MatchMakerSideSelectionScreen::Show(controller)`
    ## @0x1790180, UNIQUE. RCX = the live screen -- the PMC/SCAV chooser that
    ## the main-menu PLAY button leads to (MEASURED 2026-09-02; the screen
    ## after PLAY is this one, NOT CharacterSelectionScreen). A SHOW event, not
    ## a construction event. `autoraid.nim` reads its epoch and its receiver.
  UihSiteLocation    = 4
    ## `EFT.UI.Matchmaker.MatchMakerSelectionLocationScreen::Show(controller)`
    ## @0x178ACB0, UNIQUE. RCX = the live screen -- the LOCATION LIST, which the
    ## side selector's own NextButton lands on DIRECTLY (MEASURED 2026-09-02:
    ## there is no NEXT to press to reach it). Note the word order of the type
    ## name; "LocationSelection" matches only a coroutine class.
  UihSiteCount = 5
    ## Must equal `aowl_uih_site_count()`. Checked at arm time and logged as a
    ## REFUSAL if it ever drifts, rather than silently indexing past the table.
  UihMaxDispatchFaults = 3
    ## After this many faulted dispatches into one site, stop dispatching to it.

## Per-site state. All plain integers; nothing here is a managed object.
var gUihSlot:   array[UihSiteCount, int] = [-1, -1, -1, -1, -1]  ## detour slot, -1 = unbound
var gUihWant:   array[UihSiteCount, bool]            ## a feature subscribed
var gUihFires:  array[UihSiteCount, int]             ## postfix firings
var gUihEpoch:  array[UihSiteCount, int]             ## firings with a GOOD receiver
var gUihBad:    array[UihSiteCount, int]             ## firings whose RCX was unusable
var gUihFaults: array[UihSiteCount, int]             ## faulted dispatches
var gUihSelf:   array[UihSiteCount, Il2CppPtr]       ## last good receiver
var gUihSiteOff: array[UihSiteCount, bool]           ## dispatch disabled (rule 6)

var gUihArming = -1        ## which site `attachDrain` is currently binding
var gUihArmed = false      ## `uihArm` has run
var gUihThread = 0         ## thread id of the FIRST firing, for the log
var gUihFirstLogged = false

proc uihSiteMenuShowIdx(): int =
  ## `UihSiteMenuShow` as a PROC, for callers included BEFORE this file.
  ##
  ## `modstab.nim` is included at 6757 and this file at 6765, and nimony
  ## forward-resolves PROCS across an include boundary but not consts or
  ## variables -- so the bare constant is invisible there while this call is
  ## not. Duplicating the number in modstab would work today and drift the
  ## first time a site is inserted above it, which is fact #187 in a different
  ## costume.
  UihSiteMenuShow

proc uihValidSite(site: int): bool =
  site >= 0 and site < UihSiteCount

proc uihWant(site: int) =
  ## Subscribe to a site. Called by a feature from its own flag block, BEFORE
  ## `uihArm`. Wanting a site is what causes its detour to be installed at all;
  ## an unwanted site is never patched.
  if uihValidSite(site):
    gUihWant[site] = true

proc uihBound(site: int): bool =
  uihValidSite(site) and gUihSlot[site] >= 0

proc uihEpoch(site: int): int =
  ## Monotonic count of GOOD show events on this site. A subscriber's rider can
  ## compare this against its own copy in ONE integer compare and return -- that
  ## is the whole per-frame cost of a migrated feature.
  if uihValidSite(site): gUihEpoch[site] else: 0

proc uihSelf(site: int): Il2CppPtr =
  ## The receiver from the last good firing, re-validated on the way out. A
  ## screen that has been destroyed since stays READABLE with `m_CachedPtr`
  ## zeroed (fact #182), so `duOk` alone would hand back a corpse.
  result = nil
  if not uihValidSite(site): return
  let p = gUihSelf[site]
  if p == nil: return
  if not duOk(p, 0x20'i32) or not iUnityAlive(p):
    gUihSelf[site] = nil
    return
  result = p

proc uihFires(site: int): int =
  if uihValidSite(site): gUihFires[site] else: 0

proc uihSiteOfSlot(i: int): int =
  ## Which site owns detour slot `i`, or -1. Two entries; no cap needed beyond
  ## the array bound itself.
  result = -1
  var s = 0
  while s < UihSiteCount:
    if gUihSlot[s] == i and i >= 0:
      return s
    s = s + 1

proc uihIsSlot(i: int): bool =
  uihSiteOfSlot(i) >= 0

proc uihNoteSlot(claimed: int32) =
  ## Called from `attachDrain` for kind 26. `attachDrain` knows the kind but not
  ## the site, so `uihArm` parks the site in `gUihArming` around the call. Same
  ## mechanism the kind->slot chain uses, one level down.
  if uihValidSite(gUihArming):
    gUihSlot[gUihArming] = int(claimed)

proc uihArm(verbose: bool) =
  ## Install one byte-verified POSTFIX detour per WANTED site. Binds nothing for
  ## a site nobody subscribed to, and nothing at all on a build whose prologue
  ## does not match. Idempotent.
  if gUihArmed: return
  gUihArmed = true
  if not gReady or gDisableDrain:
    gUihArmed = false
    return
  if int(cUihSiteCount()) != UihSiteCount:
    warn "uihooks: REFUSING to arm -- the C site table has " &
         $int(cUihSiteCount()) & " entries but this file was written against " &
         $UihSiteCount & ". That is a source drift in THIS repo, not a game " &
         "build difference, and indexing past the table would read whatever " &
         "follows it. Nothing was patched."
    return
  var s = 0
  while s < UihSiteCount:
    if gUihWant[s] and gUihSlot[s] < 0:
      let spec = readCString(cUihSiteName(int32(s)))
      let fn = cUihSiteAt(int32(s))
      if fn == nil:
        warn "uihooks: site " & $s & " (" & spec & " @0x" &
             hexOf(uint64(cUihSiteRva(int32(s)))) & ") did NOT verify: " &
             readCString(cUihReasonText(cUihReasonCode())) &
             ". Nothing was patched for it, and every feature subscribed to it " &
             "will say so rather than fall back to hunting silently."
      else:
        gUihArming = s
        let ok = attachDrain(spec, fn, cast[Il2CppMethod](0), false, verbose,
                             26'i32, true)
        gUihArming = -1
        if ok:
          okLog "uihooks: SHOW-EVENT hook armed POSTFIX on " & spec & " @0x" &
                hexOf(uint64(cUihSiteRva(int32(s)))) & " (sharedness UNIQUE, " &
                "16-byte prologue matched). Subscribers to site " & $s &
                " now fire on the screen being shown and do NO per-frame " &
                "searching."
        else:
          warn "uihooks: site " & $s & " (" & spec & ") verified but the " &
               "detour would not attach. See the attach message above for the " &
               "engine's own reason; the usual one is a prologue whose stolen " &
               "bytes contain a relative branch."
    s = s + 1

proc uihDispatch(site: int; self: Il2CppPtr): bool =
  ## The hand-written subscriber list. Returns false if the subscriber's own
  ## guard reported a fault, so this file can stop dispatching into a site that
  ## keeps dying (rule 6) instead of paying a fault on every screen open.
  ##
  ## Deliberately a hand-written `if` chain and NOT a table of procs: a stale
  ## proc pointer in a table is a call into freed code with no way to verify it
  ## first, which is exactly the class of failure the rest of this host spends
  ## its effort refusing.
  result = true
  if site == UihSiteOfflineRaid:
    result = splRebrandOnScreenShown(self)

proc uihShowFired(i: int; regs: Il2CppPtr) =
  ## The POSTFIX half, dispatched by slot identity from `patchReturned`. Opens
  ## NO guard -- see rule 3 in the banner. Reads two registers, validates the
  ## receiver, and hands it to the subscriber.
  let site = uihSiteOfSlot(i)
  if not uihValidSite(site): return
  gUihFires[site] = gUihFires[site] + 1
  if gUihSiteOff[site]: return
  let self = cast[Il2CppPtr](cRegsInt(regs, 0'i32))
  if self == nil or not duOk(self, 0x20'i32) or not iUnityAlive(self):
    gUihBad[site] = gUihBad[site] + 1
    if gUihBad[site] <= 3:
      warn "uihooks: " & readCString(cUihSiteName(int32(site))) & " fired but " &
           "its receiver (RCX=0x" & hexOf(cast[uint64](self)) & ") is not a " &
           "live Unity object. NOTHING was handed to the subscriber. This is a " &
           "refusal, not a silent skip."
    return
  gUihSelf[site] = self
  gUihEpoch[site] = gUihEpoch[site] + 1
  if not gUihFirstLogged:
    gUihFirstLogged = true
    gUihThread = int(cThreadId())
    okLog "uihooks: FIRST show event -- " &
          readCString(cUihSiteName(int32(site))) & " on thread " & $gUihThread &
          " (host thread " & $int(gHostThreadId) & ")" &
          (if gUihThread == int(gHostThreadId):
             " -- HOST thread, which is NOT Unity's; a subscriber that calls " &
             "into Unity from here would be wrong"
           else: " -- Unity's main thread") & "; screen=0x" & hexOf(cast[uint64](self))
  if not uihDispatch(site, self):
    gUihFaults[site] = gUihFaults[site] + 1
    if gUihFaults[site] >= UihMaxDispatchFaults:
      gUihSiteOff[site] = true
      warn "uihooks: site " & $site & " (" &
           readCString(cUihSiteName(int32(site))) & ") has faulted " &
           $gUihFaults[site] & " times in its subscriber; this file will stop " &
           "dispatching to it for the session. The hook stays installed and " &
           "keeps counting, so the fire count below is still honest."

proc uihStatusLines(): seq[string] =
  ## One line per site, for the boot summary. States BOUND/unbound, the fire
  ## count and the epoch separately -- a fire whose receiver was rejected is not
  ## an epoch, and collapsing the two would hide exactly the case this file's
  ## receiver check exists to catch.
  result = @[]
  var s = 0
  while s < UihSiteCount:
    if gUihWant[s] or gUihSlot[s] >= 0:
      result.add("  site " & $s & " " & readCString(cUihSiteName(int32(s))) &
        " @0x" & hexOf(uint64(cUihSiteRva(int32(s)))) & ": " &
        (if gUihSlot[s] >= 0: "BOUND (slot " & $gUihSlot[s] & ")"
         else: "NOT BOUND") &
        ", fired " & $gUihFires[s] & "x, " & $gUihEpoch[s] &
        " with a live receiver, " & $gUihBad[s] & " rejected, " &
        $gUihFaults[s] & " faulted dispatch(es)" &
        (if gUihSiteOff[s]: " -- DISPATCH DISABLED" else: ""))
    s = s + 1
