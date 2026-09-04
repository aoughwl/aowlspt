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
# arming; `uihArm` installs ONE byte-verified detour per wanted site;
# when the game shows that screen the detour hands the live screen object
# straight to the feature, which applies its change once and goes idle.
#
# Between events the cost is exactly ZERO -- not "a cheap poll", zero: nothing in
# this file runs off a frame tick at all. The subscriber's own rider still ticks,
# but it can return on a single integer compare (`uihEpoch(site)` unchanged).
#
# PREFIX OR POSTFIX IS NOT A PREFERENCE. It is decided per site from the
# `slots` column of the C table, and getting it wrong killed the client.
#
# MEASURED 2026-09-02. Site 2, `MenuScreen::Show(5-arg)` @0x15387A0, was
# bound as a POSTFIX. That method's compiled call uses SEVEN register slots
# (this + 5 declared arguments + IL2CPP's trailing MethodInfo*), so three of
# them arrive ON THE STACK. The postfix thunk in `aowlspt_detour.h` does
# `subq $0x98,%rsp` and then `call *tramp`, so the original runs with a
# DIFFERENT rsp and reads those three out of the thunk's own frame. The
# first of them is the `Profile`:
#
#   R disasm 0x15387A0 -> 0x1538a4f  mov rax,[rsp+0xc0]   (= entry_rsp+0x28)
#                         0x1538a57  mov [r14+0x18],rax
#                         0x1539126  mov rdx,[r14+0x18]
#                         0x153912f  call EFT.UI.SeasonWidgetData::From
#                                         (Profile, SeasonalRewardController)
#
# and that is exactly the frame the three crash dumps of 2026-09-02 died in,
# with `Rcx=1`: a Profile that is the integer 1. The host's OWN engine
# documents this refusal -- `invoke.nim`'s `postfixRefusal`, `PostfixMaxSlots
# = 4` -- but only `hostPatch` (the mod-facing path) applied it. `attachDrain`
# never did, so this file bound the one detour the engine says is impossible.
#
# So: `uihArm` reads `aowl_uih_site_slots` and binds a site with more than
# four slots as a PREFIX. The prefix path is `addq $0x98,%rsp ; jmp *tramp`,
# which restores rsp EXACTLY, so every stack argument is where the original
# expects it. A prefix fires on ENTRY rather than on return; for site 2 that
# is strictly EARLIER, which is fine for every subscriber here because all of
# them use it as an ORDERING fact and take the receiver from RCX, which the
# thunk saves on both paths.
#
# THE SITE TABLE LIVES IN C (`abi/aowlspt_uihooks.h`) and carries, per site,
# the RVA, the SHAREDNESS verdict, the 16 prologue bytes and the slot count. `aowl_uih_site_at`
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
proc cUihSiteSlots(i: int32): int32 {.importc: "aowl_uih_site_slots", nodecl.}
proc cUihStackArg(regs: Il2CppPtr; k: int32; ok: ptr int32): Il2CppPtr {.
  importc: "aowl_uih_stack_arg", nodecl.}
proc cUihObjShape(p: Il2CppPtr): int32 {.importc: "aowl_uih_obj_shape", nodecl.}
proc cUihObjKlass(p: Il2CppPtr): Il2CppPtr {.importc: "aowl_uih_obj_klass", nodecl.}

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
  UihSiteInsurance   = 5
    ## `EFT.UI.Matchmaker.MatchmakerInsuranceScreen::Show(controller)`
    ## @0x1769910, UNIQUE. RCX = the live screen.
  UihSiteAccept      = 6
    ## `EFT.UI.Matchmaker.MatchMakerAcceptScreen::Show(controller)` @0x1773EF0,
    ## UNIQUE. RCX = the live screen. Its READY control is itself a NextButton.
  UihSiteShowInRaid  = 7
    ## `EFT.UI.MenuScreen::ShowInRaid()` @0x1539650, UNIQUE. RCX = the live
    ## MenuScreen. THE EXIT HALF'S RECEIVER: in a raid the scene-root
    ## enumeration sees the LOCATION scene, not DontDestroyOnLoad where the
    ## menu lives, so `raidexit` could not find MenuScreen by name at all
    ## (MEASURED 2026-09-02: `step SHOW-IN-RAID found nothing within 20s`).
    ## This fires for OUR call and for the player's own ESC.
  UihSiteSessionEnd  = 8
    ## `EFT.UI.SessionEnd.SessionEndUI::Awake()` @0x1726850, UNIQUE. RCX = the
    ## live SessionEndUI. A CONSTRUCTION event -- that type declares no Show --
    ## so it yields the RECEIVER for the results pages and is never proof that
    ## they are populated.
  UihSiteCount = 9
    ## Must equal `aowl_uih_site_count()`. Checked at arm time and logged as a
    ## REFUSAL if it ever drifts, rather than silently indexing past the table.
  UihMaxDispatchFaults = 3
    ## After this many faulted dispatches into one site, stop dispatching to it.
  UihPostfixMaxSlots = 4
    ## The Win64 register-argument count. A compiled call using more slots
    ## than this passes the rest ON THE STACK, and the postfix thunk cannot
    ## serve those -- see the banner. Same number as `invoke.nim`'s
    ## `PostfixMaxSlots`, and deliberately the same number, because it is the
    ## same ABI fact; it is restated here rather than imported because this
    ## file is included before `invoke.nim` is in scope.
  UihMaxProfileOkLines = 16
    ## How many OK lines the argument drain writes before it goes quiet.
    ## REFUSALS are never suppressed by this -- only confirmations are, so a
    ## long session cannot bury the one line that matters under 400 good ones.
  UihMaxProfileBadLines = 8

## Per-site state. All plain integers; nothing here is a managed object.
var gUihSlot:   array[UihSiteCount, int] = [-1, -1, -1, -1, -1, -1, -1, -1, -1]  ## detour slot, -1 = unbound
var gUihWant:   array[UihSiteCount, bool]            ## a feature subscribed
var gUihFires:  array[UihSiteCount, int]             ## postfix firings
var gUihEpoch:  array[UihSiteCount, int]             ## firings with a GOOD receiver
var gUihBad:    array[UihSiteCount, int]             ## firings whose RCX was unusable
var gUihFaults: array[UihSiteCount, int]             ## faulted dispatches
var gUihSelf:   array[UihSiteCount, Il2CppPtr]       ## last good receiver
var gUihSiteOff: array[UihSiteCount, bool]           ## dispatch disabled (rule 6)
var gUihPostfix: array[UihSiteCount, bool]           ## bound POSTFIX (else PREFIX)

## The argument drain on site 2. All plain integers and one pointer; nothing
## managed, nothing allocated on a firing.
var gUihProfKlass: Il2CppPtr = nil   ## klass seen on the first PLAUSIBLE profile
var gUihProfOk = 0                   ## firings whose profile was plausible
var gUihProfNull = 0                 ## firings whose profile was NULL (legal)
var gUihProfBad = 0                  ## firings whose profile was NOT an object
var gUihProfOther = 0                ## plausible, but a DIFFERENT klass
var gUihProfNoFrame = 0              ## the frame arithmetic did not hold
var gUihProfOkSaid = 0
var gUihProfBadSaid = 0

## THE MOD-FACING SHOW EVENT (`ui.show`). Flag `uiShowEvents`, read in
## aowlhost.nim's flag pass and DEFAULT ON, so the sites are wanted before the
## single `uihArm` pass whether or not any mod has loaded yet -- a mod cannot
## subscribe in time to influence arming, and making arming depend on mod load
## order is how a feature ends up working on one machine and not another.
var gUihEventsOn = true
var gUihEventsSent = 0     ## `ui.show` emissions
var gUihEventsSaid = false ## the first-emission log line

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
        # PREFIX OR POSTFIX, decided from the ABI and never from taste. See
        # the banner: a postfix on a call with stack arguments feeds the
        # original the thunk's own frame where those arguments belong.
        let slots = int(cUihSiteSlots(int32(s)))
        if slots < 0:
          warn "uihooks: site " & $s & " (" & spec & ") has NO slot count " &
               "in the C table. That is a source drift in this repo, not a " &
               "game build difference. Nothing was patched for it."
          s = s + 1
          continue
        let post = slots <= UihPostfixMaxSlots
        gUihArming = s
        # `slots` is handed DOWN as well as decided here. This file's own
        # choice of prefix-vs-postfix and `attachDrain`'s gate are then the
        # same number from the same column, so they cannot drift apart -- and
        # if this file's arithmetic were ever wrong in the unsafe direction,
        # the gate refuses the bind instead of trusting it.
        let ok = attachDrain(spec, fn, cast[Il2CppMethod](0), false, verbose,
                             26'i32, post, int32(slots))
        gUihArming = -1
        if ok:
          gUihPostfix[s] = post
          okLog "uihooks: SHOW-EVENT hook armed " &
                (if post: "POSTFIX" else: "PREFIX") & " on " & spec &
                " @0x" & hexOf(uint64(cUihSiteRva(int32(s)))) &
                " (sharedness UNIQUE, 16-byte prologue matched, " & $slots &
                " register slot(s)). " &
                (if post:
                   "Every argument is in a register, so the postfix thunk " &
                   "can call the original without moving its arguments."
                 else:
                   "MORE THAN " & $UihPostfixMaxSlots & " SLOTS, so " &
                   $(slots - UihPostfixMaxSlots) & " argument(s) arrive on " &
                   "the STACK and a POSTFIX would make the original read " &
                   "the thunk's own frame for them. Bound PREFIX, which " &
                   "restores rsp exactly. This fires on ENTRY, which is " &
                   "earlier than a postfix; every subscriber here uses it " &
                   "as an ordering fact and takes the receiver from RCX, " &
                   "which the thunk saves on both paths.") &
                " Subscribers to site " & $s &
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

proc uihMenuProfileDrain(regs: Il2CppPtr) =
  ## READ-ONLY. Site 2's fifth argument, `Profile profile`, checked BEFORE
  ## the game dereferences it -- so the crash this file's prefix/postfix rule
  ## fixes shows up as a SENTENCE in the host log rather than as a dump.
  ##
  ## Register map, taken from the declared signature and confirmed against
  ## `R disasm 0x15387A0`: rcx=this(MenuScreen), rdx=MatchmakerPlayersController,
  ## r8=ExpansionsPlayerInfo, r9=GameModeDescriptor, [entry_rsp+0x28]=Profile,
  ## [entry_rsp+0x30]=SeasonalRewardController, [entry_rsp+0x38]=MethodInfo*.
  ## The body itself reads its `profile` at `[rsp+0xc0]` after `sub rsp,0x98`,
  ## which IS [entry_rsp+0x28] -- so this reads the same bytes the game does,
  ## not an offset anyone guessed.
  ##
  ## THREE OUTCOMES, never two. `aowl_uih_stack_arg` refuses outright if the
  ## qword at [entry_rsp] is not committed executable memory, i.e. if the
  ## thunk's frame layout ever stops matching the arithmetic; that is
  ## INCONCLUSIVE and says so, and is never reported as a good profile.
  ##
  ## It opens NO guard -- `uihShowFired` is called from the dispatcher, and
  ## `aowl_p_p_seh` is not re-entrant (rule 3). It needs none: every
  ## dereference it makes goes through `aowl_uih_readable` first, and it
  ## touches nothing else.
  var ok: int32 = 0
  let prof = cUihStackArg(regs, 0'i32, addr ok)
  if ok == 0'i32:
    inc gUihProfNoFrame
    if gUihProfNoFrame <= 3:
      warn "uihooks: INCONCLUSIVE -- MenuScreen::Show fired but the fifth " &
           "argument could not be read: the qword at the computed entry rsp " &
           "is not a committed executable return address, so the thunk frame " &
           "arithmetic (regs + 0x58) no longer matches aowlspt_detour.h. " &
           "NOTHING is claimed about the Profile argument. This is a refusal, " &
           "not a pass."
    return
  let shape = cUihObjShape(prof)
  let n = gUihFires[UihSiteMenuShow]
  if shape == 0'i32:
    # A NULL Profile is a legal argument value and the game's own body
    # tolerates it; it is counted, not called a fault.
    inc gUihProfNull
    if gUihProfOkSaid < UihMaxProfileOkLines:
      inc gUihProfOkSaid
      info "uihooks: MenuScreen::Show #" & $n & " profile=NULL -- legal, " &
           "and NOT the crash shape (that one is a small non-zero integer)."
    return
  if shape != 1'i32:
    inc gUihProfBad
    if gUihProfBadSaid < UihMaxProfileBadLines:
      inc gUihProfBadSaid
      warn "uihooks: REFUSAL -- MenuScreen::Show #" & $n & ": the profile " &
           "argument is not a managed object (value=0x" &
           hexOf(cast[uint64](prof)) & "). It is about to be handed to " &
           "EFT.UI.SeasonWidgetData::From(Profile, SeasonalRewardController) " &
           "@0x141FFD0, which dereferences it. If the client dies in the " &
           "next instant, THIS is the value that killed it. The known cause " &
           "of this shape is a POSTFIX detour on this 7-slot call feeding " &
           "the original the thunk's own frame -- check the ARMED line " &
           "above says PREFIX, not POSTFIX."
    return
  let k = cUihObjKlass(prof)
  if gUihProfKlass == nil:
    gUihProfKlass = k
  inc gUihProfOk
  if k != gUihProfKlass:
    inc gUihProfOther
    if gUihProfBadSaid < UihMaxProfileBadLines:
      inc gUihProfBadSaid
      warn "uihooks: REFUSAL -- MenuScreen::Show #" & $n & " profile=0x" &
           hexOf(cast[uint64](prof)) & " klass=0x" &
           hexOf(cast[uint64](k)) & ", which is NOT the klass every earlier " &
           "firing carried (0x" & hexOf(cast[uint64](gUihProfKlass)) &
           "). One of the two is not an EFT.Profile. The klass NAME is not " &
           "printed on purpose: il2cpp_class_get_name is token-gated and " &
           "il2cpp_object_get_class is `mov rax,[rcx]; ret`, so a name here " &
           "would be an invention."
    return
  if gUihProfOkSaid < UihMaxProfileOkLines:
    inc gUihProfOkSaid
    okLog "uihooks: MenuScreen::Show #" & $n & " profile=0x" &
          hexOf(cast[uint64](prof)) & " klass=0x" & hexOf(cast[uint64](k)) &
          " OK -- readable, and the same klass every firing has carried. " &
          "(The klass is compared as a POINTER; this host cannot ask for its " &
          "NAME without inventing one.)"

proc uihProfileLine(): string =
  ## One line for the boot summary. Counts the four outcomes SEPARATELY --
  ## collapsing `no frame` into `bad` would hide the case where the drain
  ## never looked at all.
  "  site " & $UihSiteMenuShow & " profile argument: " & $gUihProfOk &
  " ok, " & $gUihProfNull & " null, " & $gUihProfBad &
  " NOT AN OBJECT, " & $gUihProfOther & " wrong klass, " & $gUihProfNoFrame &
  " unreadable frame" &
  (if gUihProfBad > 0 or gUihProfOther > 0:
     " -- FAIL: the game was handed something that is not a Profile"
   elif gUihProfOk + gUihProfNull == 0: " -- INCONCLUSIVE: never looked"
   else: " -- PASS")

proc uihEventsWantShowHook() =
  ## Runs in the STRICT ORDER block in aowlhost.nim, with the other
  ## `*WantShowHook`s and BEFORE the single `uihArm` pass.
  ##
  ## It wants every site except 1. Site 1 (`MenuScreen::Awake`) is NEVER
  ## wanted: it killed the client on three boots and is a construction event
  ## rather than a show event, so a subscriber would get a receiver whose
  ## fields are not written yet. That exclusion is the reason this is a
  ## hand-written list and not `for s in 0 ..< UihSiteCount`.
  if not gUihEventsOn: return
  uihWant(UihSiteOfflineRaid)
  uihWant(UihSiteMenuShow)
  uihWant(UihSiteSideSelect)
  uihWant(UihSiteLocation)
  uihWant(UihSiteInsurance)
  uihWant(UihSiteAccept)
  uihWant(UihSiteShowInRaid)
  uihWant(UihSiteSessionEnd)

proc uihEmitShow(site: int; self: Il2CppPtr) =
  ## Emit `ui.show` to every subscribed mod.
  ##
  ## THREAD OF DELIVERY, and it is the thing a consumer must know: `hostEmit`
  ## is `deliverEvent`, which is SYNCHRONOUS on the calling thread
  ## (aowlhost.nim:3234, `hostEventEmit`'s own doc comment). The calling thread
  ## here is the detour thunk on a `::Show` site, i.e. the UNITY MAIN THREAD --
  ## the same thread `uihooks` logs on its first firing. So a subscriber's
  ## handler runs ON the main thread, INSIDE the game's own call, and may touch
  ## Unity objects; it must also return fast, because it is holding a frame.
  ##
  ## `receiver` is a raw pointer as a hex string and is ONLY valid on that
  ## thread, for that call: a screen that has been destroyed stays READABLE
  ## with `m_CachedPtr` zeroed (fact #182), so a consumer that stashes it must
  ## re-validate before use, exactly as `uihSelf` does here.
  ##
  ## Allocation: this builds one small JSON string per SHOW event. A show event
  ## is a screen opening -- single-digit counts per session, not per frame --
  ## so rule 7 (no per-frame managed allocation) is not engaged; when the flag
  ## is off the cost is one bool compare.
  if not gUihEventsOn: return
  let payload = "{\"site\":" & $site &
                ",\"name\":\"" & readCString(cUihSiteName(int32(site))) & "\"" &
                ",\"rva\":\"0x" & hexOf(uint64(cUihSiteRva(int32(site)))) & "\"" &
                ",\"epoch\":" & $gUihEpoch[site] &
                ",\"postfix\":" & (if gUihPostfix[site]: "true" else: "false") &
                ",\"receiver\":\"0x" & hexOf(cast[uint64](self)) & "\"}"
  hostEmit("ui.show", payload)
  gUihEventsSent = gUihEventsSent + 1
  if not gUihEventsSaid:
    gUihEventsSaid = true
    info "uihooks: first `ui.show` event emitted (" &
         readCString(cUihSiteName(int32(site))) & ", site " & $site &
         "). Delivery is SYNCHRONOUS on this thread, which is Unity's main " &
         "thread inside the game's own ::Show call; a subscriber that blocks " &
         "here blocks the frame. Zero subscribers is normal and is logged " &
         "once by the event bus, not here."

proc uihShowFired(i: int; regs: Il2CppPtr) =
  ## The firing half, dispatched by slot identity from EITHER `patchReturned`
  ## (a POSTFIX site) or `patchFired` (a PREFIX site -- see the banner for
  ## which sites are which and why). Opens NO guard -- rule 3.
  ##
  ## The two routes differ in ONE thing that matters to a subscriber: on a
  ## prefix the body has NOT run yet. Every subscriber here either uses the
  ## epoch as an ordering fact or acts from the drain on a LATER frame (the
  ## seasons/mode/widget pass compares `uihEpoch` on the next
  ## `TarkovApplication::Update` tick, by which time Show has returned), so
  ## none of them is broken by the earlier firing. A subscriber that genuinely
  ## needs the body to have finished must check `gUihPostfix` and say so.
  let site = uihSiteOfSlot(i)
  if not uihValidSite(site): return
  gUihFires[site] = gUihFires[site] + 1
  # THE ARGUMENT DRAIN, before anything else and regardless of whether a
  # subscriber wants this firing: its whole value is that it reads the
  # Profile argument BEFORE the game's body dereferences it, and it can only
  # do that on a PREFIX. On a postfix the body has already run (and, on a
  # 7-slot call, has already read the wrong bytes), so there is nothing left
  # to warn about -- which is exactly why it says so instead of staying
  # quiet.
  if site == UihSiteMenuShow:
    if gUihPostfix[site]:
      if gUihProfNoFrame == 0:
        gUihProfNoFrame = 1
        warn "uihooks: the MenuScreen::Show argument drain is INERT -- " &
             "site 2 is bound POSTFIX, so this fires after the body has " &
             "already read its stack arguments out of the thunk frame. " &
             "Nothing is claimed about the Profile."
    else:
      uihMenuProfileDrain(regs)
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
  uihEmitShow(site, self)
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
        (if gUihSlot[s] >= 0:
           "BOUND " & (if gUihPostfix[s]: "POSTFIX" else: "PREFIX") &
           " (slot " & $gUihSlot[s] & ", " & $int(cUihSiteSlots(int32(s))) &
           " register slot(s))"
         else: "NOT BOUND") &
        ", fired " & $gUihFires[s] & "x, " & $gUihEpoch[s] &
        " with a live receiver, " & $gUihBad[s] & " rejected, " &
        $gUihFaults[s] & " faulted dispatch(es)" &
        (if gUihSiteOff[s]: " -- DISPATCH DISABLED" else: ""))
      if s == UihSiteMenuShow:
        result.add(uihProfileLine())
    s = s + 1

proc uihShowStatusJson(): string =
  ## `call("aowlspt.host::ui_show_status", "")` -- per-site state, so a mod can
  ## ASK instead of waiting for an event it may have missed (a mod loaded after
  ## MenuScreen::Show fired would otherwise never learn the menu is up).
  ##
  ## Three things are reported separately and must stay separate: `bound` (the
  ## detour installed), `fires` (the method ran) and `epoch` (the receiver was
  ## a live Unity object). A firing whose receiver was rejected is NOT an
  ## epoch, and collapsing them would hide exactly the case the receiver check
  ## exists to catch. `verdict` names which of the three is the honest answer.
  var sites = ""
  var s = 0
  while s < UihSiteCount:
    if s > 0: sites = sites & ","
    # NOT `uihSelf`, deliberately: that one CLEARS `gUihSelf[site]` when the
    # receiver has gone stale, and this verb can be called from a mod's own
    # thread. A reporting path must not mutate the state it reports on from a
    # thread that does not own it. The two guarded READS are the same ones
    # `uihSelf` makes, and neither calls into Unity: `duOk` is a VirtualQuery
    # and `iUnityAlive` is a guarded read of `m_CachedPtr`.
    var self: Il2CppPtr = gUihSelf[s]
    if self != nil and (not duOk(self, 0x20'i32) or not iUnityAlive(self)):
      self = nil
    sites = sites & "{\"site\":" & $s &
      ",\"name\":\"" & readCString(cUihSiteName(int32(s))) & "\"" &
      ",\"rva\":\"0x" & hexOf(uint64(cUihSiteRva(int32(s)))) & "\"" &
      ",\"wanted\":" & (if gUihWant[s]: "true" else: "false") &
      ",\"bound\":" & (if gUihSlot[s] >= 0: "true" else: "false") &
      ",\"postfix\":" & (if gUihPostfix[s]: "true" else: "false") &
      ",\"fires\":" & $gUihFires[s] &
      ",\"epoch\":" & $gUihEpoch[s] &
      ",\"rejected\":" & $gUihBad[s] &
      ",\"receiver\":\"" &
        (if self != nil: "0x" & hexOf(cast[uint64](self)) else: "") & "\"" &
      ",\"verdict\":\"" &
        (if gUihSiteOff[s]: "DISPATCH DISABLED after " & $gUihFaults[s] &
                            " faults -- INCONCLUSIVE"
         elif gUihSlot[s] < 0:
           (if gUihWant[s]: "WANTED but NOT BOUND -- the prologue did not " &
                            "verify or the drain is disabled"
            else: "not wanted, so not bound -- nothing was looked at")
         elif gUihFires[s] == 0: "BOUND, never fired yet"
         elif gUihEpoch[s] == 0: "BOUND and fired " & $gUihFires[s] &
                                 "x, but every receiver was rejected"
         else: "LIVE") & "\"}"
    s = s + 1
  result = "{\"flag\":" & (if gUihEventsOn: "true" else: "false") &
           ",\"armed\":" & (if gUihArmed: "true" else: "false") &
           ",\"emitted\":" & $gUihEventsSent &
           ",\"event\":\"ui.show\"" &
           ",\"thread\":" & $gUihThread &
           ",\"sites\":[" & sites & "]}"
