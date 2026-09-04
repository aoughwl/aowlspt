## ar/menu.nim -- THE MAP MENU ON A KEY.
##
## An overlay list of maps: Up/Down or 1-9 to choose, Enter to enter that raid,
## Escape or the menu key again to close. It is fills and text on the host's
## shared region -- there is no button widget and no list widget to reach for,
## and none is wanted: a menu that draws its own rows and polls its own keys has
## no dependency on another mod's private surface and no second detour anywhere.
##
## EVERYTHING HERE RUNS ON UNITY'S THREAD, from the ONE `everyMain` tick this
## mod owns. `UnityEngine.Input::GetKey*` off Unity's thread is a MEASURED
## access violation, not a theoretical one: Unity's input manager pointer is
## null on any other thread and the native body dereferences it at +0x4A0 with
## no null test. The tick itself is gated on the host reporting that its
## main-thread drain has actually FIRED, so this cannot run before there is a
## Unity thread to run on.
##
## THE FOUR WAYS IT CAN DECLINE, AND ALL OF THEM SAY SO ONCE
## ---------------------------------------------------------
##   * `hotkeys` is off            -- nothing is polled at all; that is the
##                                    shipped state and it costs one compare
##   * the key name is unknown     -- `aowl_keycode_of` returns UNKNOWN (-1),
##                                    never 0, because 0 is `KeyCode.None` and
##                                    a bind that resolved to None would poll
##                                    forever for a key that can never be down
##   * `Input::GetKeyDown` refused -- prologue mismatch: the hotkey is dead for
##                                    the session and NOTHING is ever called
##   * the region cannot draw      -- no host export, an ABI mismatch, or the
##                                    region is registered but NOT ARMED
##
## The last one is the one that must not be silent, and it is the one this file
## reports most carefully: REGISTRATION AND ARMING ARE DIFFERENT FACTS.
## Registration nearly always succeeds; a registered participant on an unarmed
## region simply never fires. `AutoRaid MENU: INCONCLUSIVE -- <why>` is logged
## ONCE, and `enterKey` KEEPS WORKING regardless, because arming a raid does not
## need anything drawn.
##
## AND THE CHECK THAT CAN FAIL: the menu's own verdict does not assert that it
## called `menuSetOpen(true)`. It reads back the region's own counters -- frames
## dispatched, frames that actually painted, primitives submitted on the last
## one -- and a menu that is "open" while `drawn` never moves is reported as a
## failure, not as a success.

import aowlspt
import native
import cfg
import uitree
import machine

const
  MenuOrder*    = 900
    ## Late in the region's ascending order: this is a modal overlay and belongs
    ## on top of the map, the radar and the ESP.
  MenuBudgetUs* = 300
    ## Microseconds per frame. The draw is a fixed number of fills and at most
    ## sixteen text commands over a POD mirror, so this is generous; the region
    ## raises an overrun by name and throttles a participant that keeps
    ## overrunning, which is how a frame-time regression here becomes visible
    ## instead of hiding for a month.
  BannerMs*     = 5000'i64
    ## How long the answer to an Enter stays on screen.

var gRegistered = false
var gRegWhy = ""
var gSaidInconclusive = false
var gKcMenu = -1
var gKcEnter = -1
var gKcUp = -1
var gKcDown = -1
var gKcEnterKey = -1
var gKcEscape = -1
var gKcDigit: array[9, int]
var gBannerAt = 0'i64
var gLastStage = ""
var gOpens = 0
var gEnters = 0
var gDrawnAtOpen = 0'i64

proc opens*(): int = gOpens
proc enters*(): int = gEnters
proc registered*(): bool = gRegistered
proc registerWhy*(): string = gRegWhy

proc bindKeys*() =
  ## Resolve every key NAME to its `UnityEngine.KeyCode` ordinal, once per
  ## config load. Called from the hot-apply hook too, so a rebind takes effect
  ## without a relaunch.
  ##
  ## An unknown name resolves to UNBOUND, and that is REPORTED rather than
  ## quietly meaning "never fires": a key row that has been mistyped is exactly
  ## the case where the player is looking at the setting wondering why nothing
  ## happens.
  gKcMenu = keycodeOf(menuKeyName())
  gKcEnter = keycodeOf(enterKeyName())
  gKcUp = keycodeOf("UpArrow")
  gKcDown = keycodeOf("DownArrow")
  gKcEnterKey = keycodeOf("Return")
  gKcEscape = keycodeOf("Escape")
  var i = 0
  while i < 9:
    gKcDigit[i] = keycodeOf("Alpha" & $(i + 1))
    i = i + 1
  if menuKeyName().len > 0 and menuKeyName() != "None" and
     gKcMenu == unboundKey():
    warn "AutoRaid MENU: `menuKey` is \"" & menuKeyName() & "\", which is not " &
         "a UnityEngine.KeyCode name this build knows. The menu key is " &
         "UNBOUND -- it will never fire -- and NOTHING is polled for it. Use " &
         "a name like F8, F9, Home, Insert or BackQuote."
  if enterKeyName().len > 0 and enterKeyName() != "None" and
     gKcEnter == unboundKey():
    warn "AutoRaid MENU: `enterKey` is \"" & enterKeyName() & "\", which is " &
         "not a UnityEngine.KeyCode name this build knows. It is UNBOUND."

proc fillRows() =
  ## Push the map list into the draw mirror. Called when the menu opens, not per
  ## frame: the list only changes when the setting does.
  let maps = mapList()
  var i = 0
  while i < maps.len and i < menuRowCap():
    menuSetRow(i, $(i + 1) & ".  " & maps[i])
    i = i + 1
  menuSetRowCount(i)
  # Start on `defaultMap` if it is in the list; otherwise on the first row. The
  # menu never starts on nothing.
  let want = lower(trim(defaultMap()))
  var j = 0
  var sel = 0
  while j < maps.len:
    if lower(trim(maps[j])) == want:
      sel = j
      break
    j = j + 1
  menuSelect(sel)

proc arm*() =
  ## Register the draw participant, once. Idempotent.
  ##
  ## Called from `onLoad` and again from the hot-apply hook when `hotkeys` flips
  ## on, so the menu works without a relaunch.
  if gRegistered: return
  menuInit()
  var why = ""
  if menuRegister(MenuOrder, MenuBudgetUs, why):
    gRegistered = true
    gRegWhy = ""
    info "AutoRaid MENU: registered as region participant `autoraid.menu` " &
         "(handle " & $menuHandle() & ", ABI " & $regionAbi() & ", order " &
         $MenuOrder & ", budget " & $MenuBudgetUs & "us). REGISTERED IS NOT " &
         "ARMED: a registered participant on an unarmed region never fires, " &
         "and the region reports armed=" &
         (if menuArmed(): "TRUE" else: "FALSE (nothing will draw yet)") & "."
  else:
    gRegWhy = why
    if not gSaidInconclusive:
      gSaidInconclusive = true
      warn "AutoRaid MENU: INCONCLUSIVE -- " & why & ". The map menu cannot " &
           "be DRAWN this session. `enterKey` still works: arming a raid does " &
           "not need anything on screen, so the feature degrades to the map " &
           "in `defaultMap` rather than disappearing."

proc close(reason: string) =
  menuSetOpen(false)
  info "AutoRaid MENU: closed (" & reason & ")."

proc armSelected(): bool =
  ## Enter the highlighted map. The answer is shown in the menu for five
  ## seconds AND logged, because a banner that scrolls away is not a record.
  let maps = mapList()
  let sel = menuSelected()
  if sel < 0 or sel >= maps.len:
    menuSetBanner("nothing selected")
    return false
  gEnters = gEnters + 1
  var why = ""
  let label = maps[sel]
  if arm(label, "pmc", "menu key", why):
    menuSetBanner("accepted: " & label)
    gBannerAt = nowMs()
    success "AutoRaid MENU: armed a raid on \"" & label & "\" from the menu."
    menuSetOpen(false)
    return true
  menuSetBanner("REFUSED: " & why)
  gBannerAt = nowMs()
  warn "AutoRaid MENU: REFUSED \"" & label & "\" -- " & why
  result = false

proc poll*() =
  ## ONE tick of the key surface. UNITY'S THREAD ONLY.
  ##
  ## With `hotkeys` off, or both keys unbound, this is a handful of integer
  ## compares and calls NOTHING -- which is the shipped state.
  if not hotkeysOn():
    if menuOpen():
      # The gate was just turned off while the menu was OPEN. Close it on the
      # tick that notices, rather than leaving a panel the player now has no key
      # to dismiss. This is the fault path too: if the poll ever stops running,
      # the overlay does not outlive it.
      close("hotkeys was turned off")
    return

  # `enterKey` first, and it works whether or not the menu can draw.
  if gKcEnter != unboundKey() and keyDown(gKcEnter):
    var why = ""
    let label = defaultMap()
    if arm(label, "pmc", "enterKey", why):
      success "AutoRaid: armed a raid on the default map \"" & label &
              "\" from `enterKey`."
    else:
      warn "AutoRaid: `enterKey` REFUSED \"" & label & "\" -- " & why

  if gKcMenu == unboundKey(): return

  if keyDown(gKcMenu):
    if menuOpen():
      close("the menu key was pressed again")
    else:
      if not gRegistered:
        # Say it ONCE. The key still toggles the state so that the counters
        # below can distinguish "the player never pressed it" from "the player
        # pressed it and nothing appeared".
        if not gSaidInconclusive:
          gSaidInconclusive = true
          warn "AutoRaid MENU: INCONCLUSIVE -- the region participant is not " &
               "registered (" & (if gRegWhy.len > 0: gRegWhy
                                 else: "registration was never attempted") &
               "), so nothing can be drawn. Use `enterKey` with `defaultMap`, " &
               "or --raid on the command line."
        return
      fillRows()
      menuSetOpen(true)
      gOpens = gOpens + 1
      gDrawnAtOpen = menuDrawn()
      info "AutoRaid MENU: opened with " & $menuRowCount() & " map(s); " &
           "Up/Down or 1-9 to choose, Enter to go, Escape to close."
    return

  if not menuOpen():
    # Keep the machine's stage on the mirror even while closed, so the next
    # open shows the truth rather than a stale line.
    if stage() != gLastStage:
      gLastStage = stage()
      menuSetStatus("state: " & gLastStage)
    return

  # ---- the menu is open: navigation ---------------------------------------
  if gKcEscape != unboundKey() and keyDown(gKcEscape):
    close("Escape")
    return
  if gKcUp != unboundKey() and keyDown(gKcUp):
    menuSelect(menuSelected() - 1)
  if gKcDown != unboundKey() and keyDown(gKcDown):
    menuSelect(menuSelected() + 1)
  var i = 0
  while i < 9:
    if gKcDigit[i] != unboundKey() and keyDown(gKcDigit[i]):
      if i < menuRowCount():
        menuSelect(i)
    i = i + 1
  if gKcEnterKey != unboundKey() and keyDown(gKcEnterKey):
    discard armSelected()
    return

  # The banner ages out. Doing it here rather than in the draw callback keeps
  # the callback free of any clock at all.
  if gBannerAt != 0'i64 and nowMs() - gBannerAt > BannerMs:
    gBannerAt = 0'i64
    menuSetBanner("")
  if stage() != gLastStage:
    gLastStage = stage()
    menuSetStatus("state: " & gLastStage)

proc verdict*(): string =
  ## THE CHECK THAT CAN FAIL. It does NOT re-report that the mod set the open
  ## flag; it reads the region's own counters and asks whether anything was
  ## actually PAINTED while the menu was open.
  ##
  ## PASS / FAIL / INCONCLUSIVE, never two outcomes: "the menu was never opened"
  ## is INCONCLUSIVE, because nobody looked.
  if not hotkeysOn():
    return "AutoRaid MENU VERDICT INCONCLUSIVE -- `hotkeys` is OFF, so no key " &
           "was polled and the menu was never asked to draw. Nothing was " &
           "measured; this is not a pass."
  if not gRegistered:
    return "AutoRaid MENU VERDICT INCONCLUSIVE -- the region participant is " &
           "not registered: " & (if gRegWhy.len > 0: gRegWhy
                                 else: "registration was never attempted") &
           ". Nothing could draw, so nothing was measured."
  if keyBindState() == 2:
    return "AutoRaid MENU VERDICT FAIL -- " & keyBindWhy() &
           " The menu key can never fire this session."
  if gOpens == 0:
    return "AutoRaid MENU VERDICT INCONCLUSIVE -- the menu was never opened " &
           "(key `" & menuKeyName() & "`, ordinal " & $gKcMenu &
           ", bind state: " & keyBindWhy() & "; " & $keyDownCount() &
           " key-down tick(s) seen, " & $keyRefusedCount() &
           " REFUSED by the indiscriminate-read control). Nothing was measured."
  if menuDrawn() <= gDrawnAtOpen:
    return "AutoRaid MENU VERDICT FAIL -- the menu was opened " & $gOpens &
           " time(s) and the region's own `drawn` counter did NOT move (" &
           $menuDrawn() & "). Frames dispatched to this participant: " &
           $menuFrames() & "; region armed: " &
           (if menuArmed(): "yes" else: "NO -- the host has not armed the " &
            "shared region, so a registered participant never fires") &
           ". Something on screen was expected and nothing was painted."
  result = "AutoRaid MENU VERDICT PASS -- opened " & $gOpens & " time(s), " &
           $gEnters & " raid(s) armed from it; the region dispatched " &
           $menuFrames() & " frame(s) to `autoraid.menu` and PAINTED " &
           $menuDrawn() & " of them, " & $menuPrims() &
           " primitive(s) on the last. " & $keyRefusedCount() &
           " keypress(es) were REFUSED by the indiscriminate-read control."
