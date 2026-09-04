## ar/exitmachine.nim -- LEAVING A RAID. The mirror of `ar/machine.nim`.
##
## WHY THIS IS IN THE MOD AND NOT IN A TOOL. MEASURED from inside a live Woods
## raid: a rootless `find MenuScreen 80000` plus two `find more` reported
## "searched EXHAUSTIVELY ... genuinely NOT PRESENT" for a screen that was ALIVE,
## because in a raid neither `roots` nor `find` can reach `DontDestroyOnLoad`.
## `tools/exitraid.py` therefore refused every attempt with "no `Common UI`
## scene root". Driving five presses from outside also costs five file
## round-trips and five tree walks; the mod is already standing next to these
## objects.
##
## THE RECEIVER PROBLEM, WHICH IS THE WHOLE DESIGN
## -----------------------------------------------
## The menu is not in the raid's scene. Any search that starts from a scene root
## cannot find it, and no amount of waiting fixes a search looking in the wrong
## place. So the MenuScreen comes from a SHOW EVENT, in this order, and the log
## says WHICH ONE ANSWERED so a run can never quietly rest on the weaker source:
##
##   site 7  MenuScreen::ShowInRaid  -- the in-raid menu was SHOWN, by us or by
##                                      the player's own ESC. STRONGEST.
##   site 2  MenuScreen::Show(5-arg) -- the menu from BEFORE the raid.
##                                      MenuScreen is DontDestroyOnLoad, so the
##                                      pointer survives; it is re-validated
##                                      (liveness, not just readability) before
##                                      anything is called on it.
##
## Site 1 (`MenuScreen::Awake`) is NOT in this ladder and is not read: binding
## it is MEASURED to kill the client at menu arrival, and a reader is an
## argument for a want.
##
## THE SEQUENCE, and what each step ASSERTS rather than assumes
## ------------------------------------------------------------
##   SHOW        call `MenuScreen::ShowInRaid()` on the receiver
##   DISCONNECT  `_disconnectButton` @0xC0 -- WAIT for its GameObject to read
##               activeInHierarchy (a READBACK, because pressing an inactive
##               object returns success and does nothing, fact #72) then press
##   LEAVE       a `LeaveButton`, IF one appears. Its ABSENCE is not a failure:
##               that screen is not always shown, so this SKIPS after a bounded
##               wait rather than refusing
##   RESULTS     the session-end `NextButton`, pressed repeatedly -- it is
##               REBUILT per results page, so each press excludes the previous
##               pointer and the next must be a DIFFERENT object
##   VERIFY      the verdict is read OFF THE LIVE TREE: an ACTIVE, PRESSABLE
##               `PlayButton`. Not "the calls returned", not a step counter --
##               the thing a player would look at.
##
## DEFAULT INERT. Nothing here runs until `arm` is called.

import aowlspt
import aowlspt/il2cpp
import aowlspt/callrva
import native
import calls
import uitree
import press
import showbus
import phase

const
  XrIdle*       = 0
  XrShow*       = 1
  XrDisconnect* = 2
  XrLeave*      = 3
  XrResults*    = 4
  XrVerify*     = 5
  XrDone*       = 6
  XrFailed*     = 7

  XrStepMs      = 20000'i64   ## per-step ceiling
  XrSayMs       = 5000'i64    ## how long a step may sit SILENT before it
                              ## explains itself. A step that refuses at 20 s
                              ## having said nothing for 20 s is what made the
                              ## last refusal unactionable.
  XrLeaveMs     = 6000'i64    ## how long a LeaveButton is waited for before SKIP
  XrTotalMs     = 180000'i64  ## whole-run ceiling
  XrTickFrames  = 12          ## ~0.2 s between attempts
  XrMaxFaults   = 3
  XrMaxResults  = 12          ## results pages pressed before refusing
  XrProbeCap    = 96
    ## ACTIVE nodes examined by any one search here. Same size and same reason
    ## as the entry half's cap: large enough that a truncation shows up AT the
    ## cap in the log rather than looking like an absence.

proc xrStepName*(s: int): string =
  case s
  of XrIdle:       "IDLE"
  of XrShow:       "SHOW-IN-RAID"
  of XrDisconnect: "DISCONNECT"
  of XrLeave:      "LEAVE"
  of XrResults:    "RESULTS"
  of XrVerify:     "VERIFY"
  of XrDone:       "DONE"
  else:            "FAILED"

var gStep = XrIdle
var gT0 = 0'i64
var gStepT0 = 0'i64
var gFrames = 0
var gFaults = 0
var gMenu: Il2CppPtr = nil        ## the MenuScreen we called ShowInRaid on
var gMenuTr: Il2CppPtr = nil      ## its Transform, for climbing to the root
var gLastPressed: Il2CppPtr = nil ## the results NextButton just pressed (dedup)
var gResults = 0
var gSaidNoRecv = false
var gSaidNoDisc = false
var gStage = "IDLE"
var gAnswer = ""

proc stage*(): string = gStage
proc answer*(): string = gAnswer
proc running*(): bool =
  gStep != XrIdle and gStep != XrDone and gStep != XrFailed

proc goto(s: int) =
  gStep = s
  gStepT0 = nowMs()
  gStage = xrStepName(s)

proc fail(why: string) =
  gStep = XrFailed
  gStage = "FAILED"
  gAnswer = "FAILED: " & why
  warn "AutoRaid exit: " & why & " -- stopping. This is a REFUSAL, not a success."

proc menuFromEvent(via: var string): Il2CppPtr =
  ## The live MenuScreen COMPONENT, from a show event rather than from a search.
  ## See the banner for why a search cannot work here.
  result = nil
  via = ""
  var self = receiverOf(SiteShowInRaid)
  if self != nil:
    via = "uihooks site 7 (MenuScreen::ShowInRaid -- the in-raid menu was shown)"
    return self
  self = receiverOf(SiteMenuShow)
  if self != nil:
    via = "uihooks site 2 (MenuScreen::Show(5-arg) from before the raid; " &
          "MenuScreen is DontDestroyOnLoad and the pointer was re-validated " &
          "for liveness, not merely readability)"
    return self

proc arm*(reason: string; why: var string): bool =
  ## Arm the exit sequence. MAIN THREAD ONLY.
  ##
  ## REFUSES when the client is not in a raid at all, because every step below
  ## would then be pressing at a menu that is already where we want to be, and
  ## a sequence that "succeeds" by doing nothing is the worst kind of pass.
  why = ""
  if running():
    why = "a raid-exit sequence is already running (step " &
          xrStepName(gStep) & ")"
    return false
  let p = raidPhase()
  if p.asked and not inRaid(p):
    why = "the client is not in a raid (phase " & p.phase & ", " & p.why &
          "), so there is nothing to leave. REFUSED rather than pressing at " &
          "the menu and calling it a success."
    return false
  if not p.asked:
    warn "AutoRaid exit: this host has no `raid_phase` verb, so whether we " &
         "are in a raid could NOT be checked. Arming anyway, and every step " &
         "below still asserts its own finished state -- but the run is " &
         "INCONCLUSIVE by construction if it turns out we were at the menu."
  if callsDisabled():
    why = "the mod's call surface has self-disabled after repeated faults"
    return false
  gT0 = nowMs()
  gFaults = 0
  gFrames = XrTickFrames
  gMenu = nil
  gMenuTr = nil
  gLastPressed = nil
  gResults = 0
  gSaidNoRecv = false
  gSaidNoDisc = false
  goto(XrShow)
  gAnswer = "ARMED, step SHOW-IN-RAID"
  success "AutoRaid exit: ARMED (" & reason & ") -- SHOW-IN-RAID -> " &
          "DISCONNECT -> LEAVE -> RESULTS -> VERIFY. ARMED IS NOT OUT."
  result = true

proc menuRootOf(): Il2CppPtr =
  ## `Common UI`, climbed from the MenuScreen's own Transform. The only route
  ## available in a raid, and the correct one everywhere.
  if gMenuTr == nil: return nil
  result = rootOf(gMenuTr)

proc tickBody(now: int64) =
  if now - gT0 > XrTotalMs:
    fail("the whole leave sequence exceeded " &
         $int(XrTotalMs div 1000'i64) & " s at step " & xrStepName(gStep))
    return
  # LEAVE is excluded from the per-step ceiling on purpose: its whole design is
  # to wait a short while and SKIP, and a hard refusal there would turn "this
  # screen was not shown" into a failure.
  if gStep != XrLeave and now - gStepT0 > XrStepMs:
    fail("step " & xrStepName(gStep) & " found nothing within " &
         $int(XrStepMs div 1000'i64) & " s")
    return

  if gStep == XrShow:
    var via = ""
    let comp = menuFromEvent(via)
    if comp == nil:
      if now - gStepT0 > XrSayMs and not gSaidNoRecv:
        gSaidNoRecv = true
        warn "AutoRaid exit: no MenuScreen receiver from ANY show event (site " &
             "7 ShowInRaid empty, site 2 Show(5-arg) empty or unbound; site 1 " &
             "Awake is deliberately never used). There is NO fallback search: " &
             "in a raid the enumerated scene roots are the LOCATION scene and " &
             "the menu lives in DontDestroyOnLoad, so a search there finds " &
             "nothing and would only produce a confidently wrong refusal. " &
             "Check the host's `uihooks:` lines for whether site 7 bound."
      return                        # keep looking; the step timeout bounds this
    if not readable(comp, OffMenuDisconnect + 8):
      fail("the MenuScreen component is not readable to +0x" &
           $(OffMenuDisconnect + 8) & ", so `_disconnectButton` could not be " &
           "reached and nothing was called")
      return
    var w = ""
    if not menuShowInRaid(comp, w):
      fail("MenuScreen::ShowInRaid was not called -- " & w)
      return
    gMenu = comp
    gMenuTr = transformOf(comp)
    success "AutoRaid exit: called MenuScreen::ShowInRaid, receiver via " &
            via & " -- now WAITING for `_disconnectButton` @+0xC0 to become " &
            "activeInHierarchy. That wait is a READBACK, not an assumption: " &
            "pressing an inactive object returns success and does nothing."
    goto(XrDisconnect)
    return

  if gStep == XrDisconnect:
    if gMenu == nil or not readable(gMenu, OffMenuDisconnect + 8):
      fail("the MenuScreen pointer went unreadable before DISCONNECT")
      return
    let btn = readPtr(gMenu, OffMenuDisconnect)
    if btn == nil or not readable(btn, 0x20) or not alive(btn):
      return                      # not wired yet; the step timeout bounds it
    var ok = false
    let act = activeInHierarchy(btn, ok)
    if not ok: return
    if not act:
      if now - gStepT0 > XrSayMs and not gSaidNoDisc:
        gSaidNoDisc = true
        info "AutoRaid exit: the MenuScreen `_disconnectButton` exists but is " &
             "NOT activeInHierarchy yet, so NOTHING was pressed (pressing it " &
             "would report success and do nothing -- fact #72)." &
             censusUnder(gMenuTr, 3)
      return
    var comp: Il2CppPtr = nil
    let k = controlOn(btn, comp)
    if k == pkNone or not pressable(btn, k, comp): return
    var via = ""
    var w = ""
    if not press(btn, k, comp, via, w):
      fail("the DISCONNECT button was active and pressable a moment ago and " &
           "the press did not fire -- " & w)
      return
    success "AutoRaid exit: pressed DISCONNECT via " & via
    gLastPressed = nil
    gResults = 0
    goto(XrLeave)
    return

  if gStep == XrLeave:
    let root = menuRootOf()
    var seen = 0
    var names = ""
    var kind = pkNone
    var comp: Il2CppPtr = nil
    var lb: Il2CppPtr = nil
    if root != nil:
      lb = findPressable(root, "LeaveButton", FindDepth, XrProbeCap,
                         seen, names, kind, comp)
    if lb == nil:
      if now - gStepT0 > XrLeaveMs:
        success "AutoRaid exit: no ACTIVE, pressable `LeaveButton` appeared " &
                "within " & $int(XrLeaveMs div 1000'i64) & " s. That screen " &
                "is NOT always shown, so this is a SKIP, not a failure, and " &
                "nothing is claimed about it."
        goto(XrResults)
      return
    var via = ""
    var w = ""
    if press(lb, kind, comp, via, w):
      success "AutoRaid exit: pressed LEAVE via " & via
      goto(XrResults)
    else:
      warn "AutoRaid exit: a `LeaveButton` was found and not pressed -- " & w
    return

  if gStep == XrResults:
    # The results NextButton is REBUILT per page, so excluding the previous
    # pointer is what stops this pressing one dead object forever and calling it
    # progress. THE RECEIVER FIRST (site 8 hands us the results UI itself), the
    # menu root second -- for the same reason the entry half stopped hunting
    # screens by name.
    var nb: Il2CppPtr = nil
    var kind = pkNone
    var comp: Il2CppPtr = nil
    var seen = 0
    var names = ""
    let seTr = screenTransform(SiteSessionEnd)
    if seTr != nil:
      nb = findPressable(seTr, "NextButton", ScreenDepth, XrProbeCap,
                         seen, names, kind, comp)
      if nb != nil and nb == gLastPressed:
        nb = nil                    # the same object as last time: not progress
    if nb == nil:
      let root = menuRootOf()
      if root != nil:
        nb = findPressable(root, "NextButton", FindDepth, XrProbeCap,
                           seen, names, kind, comp)
        if nb != nil and nb == gLastPressed:
          nb = nil
    if nb == nil:
      # No further page. Whether that means "finished" is decided by VERIFY,
      # which READS THE TREE -- not by this absence.
      goto(XrVerify)
      return
    if gResults >= XrMaxResults:
      fail("pressed " & $gResults & " results pages without reaching the " &
           "menu; refusing to keep pressing")
      return
    var via = ""
    var w = ""
    if press(nb, kind, comp, via, w):
      gResults = gResults + 1
      gLastPressed = nb
      gStepT0 = now
      success "AutoRaid exit: pressed results NextButton #" & $gResults &
              " via " & via
    return

  if gStep == XrVerify:
    # THE VERDICT, READ OFF THE LIVE TREE. An ACTIVE, PRESSABLE `PlayButton` is
    # the thing a player would see. "Every call returned" is not evidence.
    let root = menuRootOf()
    if root != nil:
      var seen = 0
      var names = ""
      var kind = pkNone
      var comp: Il2CppPtr = nil
      let pb = findPressable(root, "PlayButton", FindDepth, XrProbeCap,
                             seen, names, kind, comp)
      if pb != nil:
        gStep = XrDone
        gStage = "DONE"
        gAnswer = "DONE: an ACTIVE, pressable PlayButton is under " &
                  nodeName(root) & " -- we are back at the main menu"
        success "AutoRaid exit VERDICT PASS -- verified by an ACTIVE, " &
                "PRESSABLE PlayButton under `" & nodeName(root) & "`, not by " &
                "the calls returning."
        return
    # Not there yet: the results chain may have another page.
    let seTr = screenTransform(SiteSessionEnd)
    if seTr != nil:
      var seen = 0
      var names = ""
      var kind = pkNone
      var comp: Il2CppPtr = nil
      let nb = findPressable(seTr, "NextButton", ScreenDepth, XrProbeCap,
                             seen, names, kind, comp)
      if nb != nil and nb != gLastPressed:
        goto(XrResults)
    return

proc tick*() =
  ## INERT until armed: when idle this is one integer compare and makes no call
  ## into the game.
  if not running(): return
  gFrames = gFrames + 1
  if gFrames < XrTickFrames: return
  gFrames = 0
  let before = int(faultCount())
  tickBody(nowMs())
  let after = int(faultCount())
  if after > before:
    gFaults = gFaults + (after - before)
    warn "AutoRaid exit: " & $(after - before) & " guarded call(s) faulted " &
         "this tick (" & $gFaults & " of " & $XrMaxFaults & ") at step " &
         xrStepName(gStep)
    if gFaults >= XrMaxFaults:
      fail("too many faults")
