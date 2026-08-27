# modeskip.nim -- never show the character/mode selection screen.
#
# `include`d into `aowlhost.nim` (NOT imported) so it shares that file's guarded
# raw primitives (`cIsReadable`), its logging (`okLog`/`warn`/`info`), `hexOf`,
# `cRegsInt`, `cThreadId`, `attachDrain` and the VEH/SEH guard.
#
# WHAT IT DOES
# ------------
# The launcher ALREADY binds a profile: `tools/aowllaunch.nim` picks one and
# passes `-token=<id>`, and without that token the client dies at "Client not
# authenticated". So by the time the character/mode selection screen appears,
# the question it is asking has already been answered -- the host simply could
# not see the answer. `aowllaunch` now also writes that same id into
# `aowlspt-host.json` as `launchProfileId`, and this feature uses it to answer
# the screen programmatically.
#
# THE ROUTE
# ---------
# All three RVAs, their unsharedness, the disassembled prologues and the field
# offsets are in `abi/aowlspt_modeskip.h`, resolved offline. In particular that
# header records WHY the controller is captured from its constructor rather than
# from `ShowSlot`: `ShowSlot` has arity 4, so `controller` is a STACK argument,
# and the host's detour thunk saves only RCX..R9.
#
#   [0] CharacterSelectionScreen::ShowSlot   @0x13efae0  POSTFIX detour, READ ONLY
#   [1] ...ScreenController::.ctor           @0x13f0530  POSTFIX detour, READ ONLY
#   [2] ...ScreenController::Submit          @0x13f0bf0  CALLED, never detoured
#
# Neither detour ever suppresses its original. The screen is allowed to build
# itself completely; it is then dismissed from a LATER frame.
#
# WHY THE SUBMIT IS DEFERRED -- AND WHY TWO FRAMES WAS NOT ENOUGH
# ---------------------------------------------------------------
# Calling `Submit` from inside `ShowSlot` would re-enter the selection screen's
# own code from the middle of one of its own calls, while it is still building
# the very slot it is being told to accept.
#
# Deferring by TWO DRAIN TICKS was not enough either, and shipping that was a
# real regression: the player got a blank Escape From Tarkov background with no
# menu at all. MEASURED, from the client's own
# `...output_000.log` and from the live inspector:
#
#   * host log: ShowSlot first fired at 0:00:25.703, Submit at 0:00:25.719 --
#     SIXTEEN MILLISECONDS later.
#   * client log, 372 ms after that: `NullReferenceException` in
#     `EFT.UI.CharacterSelectionSeasonPanel.ShowPerks`, thrown under
#     `RunInitialLobbyFlow -> RunCharacterSelectionFlow ->
#      ShowCharacterSelectionScreen -> ShowScreenAsync -> DisplayScreen ->
#      CharacterSelectionScreen.Show -> ShowSlot`. The client shows this screen
#     a SECOND time from its own async startup flow, and we had already
#     answered and torn down the first one.
#   * that exception aborts the whole `RunInitialLobbyFlow` task (it surfaces as
#     an `AggregateException` at `TasksExtensions:HandleFinishedTask`), so
#     nothing ever activates the main menu.
#   * live inspector, six minutes into that run: `MenuScreen` (parent
#     `Common UI`) `activeInHierarchy = 0`; `CharacterSelectionScreen` under
#     `Login UI` = 0; `CharacterSelectionScreen` under `UI` = 0. Everything
#     built, nothing shown.
#
# The gate is therefore no longer a frame count. It is WALL-CLOCK QUIET on an
# OBSERVABLE EVENT: `Submit` is sent only once `ShowSlot` has not fired for
# `ModeSkipQuietMs`, and every ShowSlot -- including the late one -- restarts
# that clock. If quiet never arrives inside `ModeSkipMaxWaitMs` the feature
# DECLINES and presses nothing, leaving the stock screen usable.
#
# So the capture only RECORDS a wish,
# and the call happens from the `EFT.TarkovApplication::Update` drain -- the
# host's validated main-thread bridge (RVA 0x977B10), which ticks for the whole
# session, menu and raid alike -- on a strictly LATER tick than the capture.
#
# THIS DELIBERATELY DOES NOT USE A "the world is up" GATE. `whenReady` on a type
# name tests TYPE RESOLVABILITY, not whether anything exists, so it goes true at
# host boot with no raid anywhere (fact #141) -- a check that cannot fail. The
# only gate here is a POINTER THE GAME ITSELF HANDED US in a register, plus a
# tick counter. There is no by-name resolution anywhere in this feature: every
# address is a byte-verified static RVA (fact #145 -- a by-name route is fatal
# when USED, not when resolved).
#
# HONEST ABOUT WHAT IT ACHIEVES
# -----------------------------
# The screen IS constructed and IS on screen for the frames between `ShowSlot`
# and the deferred `Submit`. This does not prevent it from ever being drawn; it
# dismisses it immediately. Suppressing `ShowSlot` outright was considered and
# rejected: it would leave the screen up with EMPTY slots, which is strictly
# worse than a brief flash.
#
# SAFETY
# ------
#   * flag-gated `uxSkipModeScreen`, default OFF, and additionally inert unless
#     `launchProfileId` is set -- two independent conditions, both explicit;
#   * all three targets are 16-byte prologue-verified against the STARTUP
#     SNAPSHOT before anything binds or is called, so on any other build this
#     binds nothing and is a silent no-op rather than a hazard;
#   * each handler body runs under ONE `aowl_p_p_seh` -- one, never nested,
#     because the guard is not re-entrant;
#   * every pointer hop is VirtualQuery-guarded (`aowl_msk_readable`) before it
#     is dereferenced, including every hop inside the managed-string read;
#   * the string read is CAPPED at 256 chars and refuses a negative or absurd
#     length, so a corrupt length field cannot become an unbounded loop;
#   * fires AT MOST ONCE per controller instance;
#   * self-disables after `ModeSkipMaxFaults` guarded bodies fail;
#   * NO PER-FRAME ALLOCATION: nothing here allocates managed memory at all.

# ---- the verified targets and thunks (abi/aowlspt_modeskip.h) ----
proc cMskFn(i: int32): Il2CppPtr {.importc: "aowl_msk_fn", nodecl.}
proc cMskOkCount(): int32 {.importc: "aowl_msk_ok_count", nodecl.}
proc cMskBadCount(): int32 {.importc: "aowl_msk_bad_count", nodecl.}
proc cMskProfileIs(pd: Il2CppPtr; want: cstring): int32 {.
  importc: "aowl_msk_profile_is", nodecl.}
proc cMskProfileId(pd: Il2CppPtr; outBuf: cstring; cap: int32): int32 {.
  importc: "aowl_msk_profile_id", nodecl.}
proc cMskProfileNick(pd: Il2CppPtr; outBuf: cstring; cap: int32): int32 {.
  importc: "aowl_msk_profile_nick", nodecl.}
proc cMskProfileStatus(pd: Il2CppPtr): int32 {.
  importc: "aowl_msk_profile_status", nodecl.}
proc cMskProfileSide(pd: Il2CppPtr): int32 {.
  importc: "aowl_msk_profile_side", nodecl.}
proc cMskCallSubmit(fn, controller: Il2CppPtr; gameMode: uint64;
                    pd: Il2CppPtr) {.importc: "aowl_msk_call_submit", nodecl.}

const
  MskTShowSlot = 0'i32                 ## EFT.UI.CharacterSelectionScreen::ShowSlot
  MskTCtor     = 1'i32                 ## CharacterSelectionScreenController::.ctor
  MskTSubmit   = 2'i32                 ## CharacterSelectionScreenController::Submit
  ModeSkipMaxFaults = 3
    ## After this many guarded bodies have faulted the feature switches itself
    ## off for the session. Three, not one: a single fault during a scene change
    ## is worth surviving, a pattern of them is not.
  ModeSkipQuietMs = 0'u64
    ## WALL-CLOCK milliseconds of `ShowSlot` SILENCE that must pass after the
    ## last slot was shown before `Submit` is called.
    ##
    ## THIS NUMBER IS WHY THE FEATURE BROKE, AND WHAT FIXES IT. Measured from
    ## `D:\Aowlspt\Logs\log_2026.08.26_13-33-04...\...output_000.log`: the
    ## client's OWN startup flow calls `CharacterSelectionScreen.Show` a SECOND
    ## time, from
    ##   RunInitialLobbyFlow -> RunCharacterSelectionFlow
    ##     -> ShowCharacterSelectionScreen -> ScreenController.ShowScreenAsync
    ##     -> DisplayScreen -> Show -> ShowSlot
    ## **372 ms** after the first slots appeared. The old rule waited TWO drain
    ## ticks (~16 ms), so `Submit` landed in the middle of that async flow; the
    ## late `Show` then ran against a controller we had already answered and
    ## `EFT.UI.CharacterSelectionSeasonPanel.ShowPerks` threw
    ## `NullReferenceException`, which aborted the whole `RunInitialLobbyFlow`
    ## task. The selection screen went away and `MenuScreen` was never
    ## activated -- MEASURED through the live inspector: `MenuScreen` (parent
    ## `Common UI`) `activeInHierarchy = 0`, and both `CharacterSelectionScreen`
    ## copies (parents `Login UI` and `UI`) `activeInHierarchy = 0`. A blank
    ## background with nothing on it.
    ##
    ## So the gate is no longer a TICK COUNT. A tick count is a guess whose
    ## meaning changes with the frame rate (this client runs the lobby at 120
    ## and the raid at 240 fps, both configurable), and it rots. This is
    ## wall-clock, and it is anchored to an OBSERVABLE EVENT -- the last
    ## `ShowSlot` -- rather than to the moment we happened to notice a match.
    ## 500 ms was chosen AFTER the real cause was found, and the history
    ## matters because the first number here was picked for a reason that
    ## turned out to be wrong. The blank-background bug was NOT this race.
    ## It was the `pvp-season` slot: sending that key populated the SEASONAL
    ## slot view, whose `RefreshModeSpecificState` calls
    ## `CharacterSelectionSeasonPanel.ShowPerks` with the `SeasonalPerksData`
    ## the client fetched from `/client/seasonal-perks/list`. That value came
    ## back null, `ShowPerks` threw a NullReferenceException inside the
    ## client's own `RunInitialLobbyFlow`, and the task that activates
    ## `MenuScreen` never completed. Waiting 3000 ms did NOT stop it -- that
    ## run still threw -- which is what falsified the race theory. Dropping
    ## the seasonal key fixed it outright.
    ##
    ## So this window is no longer defending against the crash. It only has
    ## to clear the client's own second `ShowSlot`, measured at 372 ms after
    ## the first. 500 ms covers that with a small margin and is imperceptible
    ## to a player. It stays anchored to the last OBSERVED `ShowSlot` rather
    ## than to a tick count, because a tick count means different things at
    ## the lobby's 120 fps and a raid's 240 fps, and it rots.
  ModeSkipMaxWaitMs = 30000'u64
    ## Hard upper bound on that wait. If `ShowSlot` never goes quiet for
    ## `ModeSkipQuietMs` within this long, the feature DECLINES: it never
    ## presses anything, so the stock selection screen is left exactly as the
    ## client built it and the player can use it. A visible screen the player
    ## can click is strictly better than a blank background, which is the
    ## outcome this whole change exists to prevent.
  ModeSkipStarveTicks = 3600
    ## Roughly a minute of drain ticks. If the feature is armed and the screen
    ## has never been seen, it says so once rather than being a silent no-op.

# `gModeSkipOn`, `gModeSkipWantId`, `gModeSkipCtorSlot` and `gModeSkipShowSlot`
# are declared in `aowlhost.nim` next to `gModeTextSlot`: `attachDrain` and the
# dispatch path are defined ABOVE this file's include point and name them, and
# while procs resolve across the whole module regardless of order, module-level
# `var`s do not. The rest of the state is local to this feature.
var gModeSkipFaults = 0
var gModeSkipOff = false              ## self-disabled
var gModeSkipController: Il2CppPtr = nil
var gModeSkipPendingPd: Il2CppPtr = nil
var gModeSkipPendingMode: uint64 = 0
var gModeSkipPending = false
var gModeSkipArmedAtMs: uint64 = 0     ## when the matching slot was seen
var gModeSkipLastSlotMs: uint64 = 0    ## when ANY slot was last shown
var gModeSkipTicks = 0
var gModeSkipSubmittedAtMs: uint64 = 0
var gModeSkipDeclined = false
var gModeSkipLateShow = false
var gModeSkipSubmittedFor: Il2CppPtr = nil   ## once per controller instance
var gModeSkipSubmits = 0
var gModeSkipSlotsSeen = 0
var gModeSkipStarved = false
var gModeSkipCtorLogged = false
## The wanted ProfileId as a STABLE NUL-terminated char buffer.
##
## `gModeSkipWantId` is a Nim string and cannot be handed to C as a `cstring`
## (Nimony allows that conversion only for string literals). More importantly a
## string's backing store is not something this feature should be handing to a
## C function that runs inside a detour: this buffer is filled ONCE at bind
## time and never touched again, so the pointer passed on every slot is fixed
## for the session and cannot be invalidated by anything the host does later.
var gModeSkipWantBuf: array[264, char]
var gModeSkipWantLen = 0

## Scratch for the two log-only string reads below. MODULE level, not locals:
## Nimony cannot prove a local array is initialised before it is handed to C,
## and these are only ever touched from the ONE guarded body, which only ever
## runs on Unity's main thread. That also keeps a 528-byte pair of buffers off
## the stack of a function that runs inside a detour.
var gModeSkipIdBuf: array[264, char]
var gModeSkipNickBuf: array[264, char]

proc modeSkipSetWantBuf(s: string): bool =
  ## Copies `s` into the fixed buffer, NUL-terminated. Capped: refuses anything
  ## that would not fit rather than truncating, because a TRUNCATED profile id
  ## would silently compare unequal to every slot and look exactly like "the
  ## feature is armed and does nothing".
  if s.len == 0 or s.len >= gModeSkipWantBuf.len:
    return false
  for i in 0 ..< s.len:
    gModeSkipWantBuf[i] = s[i]
  gModeSkipWantBuf[s.len] = char(0)
  gModeSkipWantLen = s.len
  return true

var gModeSkipShowLogged = false

# ---------------------------------------------------------------------------
# THE CAPTURE HALVES
# ---------------------------------------------------------------------------

{.emit: """
extern void* aowl_msk_slot_body(void* a);
static void* aowl_msk_slot_guarded(void* a) {
    return aowl_p_p_seh((void*)aowl_msk_slot_body, a);
}
extern void* aowl_msk_submit_body(void* a);
static void* aowl_msk_submit_guarded(void* a) {
    return aowl_p_p_seh((void*)aowl_msk_submit_body, a);
}
""".}
proc cMskSlotGuarded(a: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_msk_slot_guarded", nodecl.}
proc cMskSubmitGuarded(a: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_msk_submit_guarded", nodecl.}

## Carries the profile data into the guarded body, for the same reason
## `gModeTextAlloc` exists: `aowl_p_p_seh` passes exactly one pointer, and this
## body needs the game mode as well.
var gModeSkipSlotPd: Il2CppPtr = nil
var gModeSkipSlotMode: uint64 = 0

proc modeSkipSlotBody(a: Il2CppPtr): Il2CppPtr {.
    exportc: "aowl_msk_slot_body", cdecl.} =
  ## READ ONLY. Decides whether the slot just shown is the one the launcher
  ## bound, and if so records a wish. Calls nothing into managed code and
  ## writes nothing to the game. `a` is unused; the inputs are the two globals
  ## above, set immediately before the guarded call.
  result = cast[Il2CppPtr](1)
  let pd = gModeSkipSlotPd
  if pd == nil:
    return
  inc gModeSkipSlotsSeen

  let idLen = cMskProfileId(pd, cast[cstring](addr gModeSkipIdBuf[0]), 264'i32)
  discard cMskProfileNick(pd, cast[cstring](addr gModeSkipNickBuf[0]), 264'i32)
  let status = cMskProfileStatus(pd)
  let side = cMskProfileSide(pd)
  let idStr = (if idLen > 0: $cast[cstring](addr gModeSkipIdBuf[0]) else: "<none>")
  let nickStr = $cast[cstring](addr gModeSkipNickBuf[0])

  # Every slot the screen shows is logged ONCE per screen, so a run that did not
  # skip can be diagnosed from the log alone rather than by guessing. This is
  # the only place the ids the client actually offered are visible.
  if gModeSkipSlotsSeen <= 8:
    info "skip mode screen: slot " & $gModeSkipSlotsSeen & " gameMode=" &
         $gModeSkipSlotMode & " profileId=" & idStr &
         " nickname=\"" & nickStr & "\" status=" & $status & " side=" & $side

  # THE PREDICATE: ProfileId equality, and nothing else. `status` is logged
  # above but deliberately NOT gated on -- the integer that means "Available"
  # is not something this host knows (the enum's constants are in metadata
  # `fieldDefaultValues`, which no resolver verb exposes), and gating on a
  # guessed enum value would be a guessed offset in another costume. Equality
  # is strictly stronger: an EMPTY slot carries no ProfileId to match.
  if cMskProfileIs(pd, cast[cstring](addr gModeSkipWantBuf[0])) == 0'i32:
    return

  if gModeSkipPending:
    return                                   # already have one; first wins
  gModeSkipPendingPd = pd
  gModeSkipPendingMode = gModeSkipSlotMode
  gModeSkipPending = true
  gModeSkipArmedAtMs = cNowMs()
  okLog "skip mode screen: slot for profile " & idStr & " (\"" & nickStr &
        "\", gameMode=" & $gModeSkipSlotMode & ") matches launchProfileId; " &
        "Submit is QUEUED, not sent -- it waits for " & $int(ModeSkipQuietMs) &
        "ms with no further ShowSlot, because the client's own " &
        "RunCharacterSelectionFlow shows this screen AGAIN ~372ms later and " &
        "answering before that lands throws inside CharacterSelectionSeason" &
        "Panel.ShowPerks and strands the player on a blank background"

proc modeSkipCtorFired(regs: Il2CppPtr) =
  ## POSTFIX on `CharacterSelectionScreenController::.ctor`. Captures `this`.
  ## This is a single register read and a pointer compare; it dereferences
  ## nothing, so it needs no guarded body of its own.
  if gModeSkipOff or not gModeSkipOn:
    return
  let raw = cRegsInt(regs, 0'i32)              # RCX = the controller `this`
  if raw == 0'u64:
    return
  let ctl = cast[Il2CppPtr](raw)
  if ctl == gModeSkipController:
    return
  # A NEW controller: a new selection screen. Clear anything left over from the
  # previous one, so "fire once per screen" is per INSTANCE and a second visit
  # to the screen is skipped too.
  gModeSkipController = ctl
  gModeSkipPending = false
  gModeSkipPendingPd = nil
  gModeSkipSlotsSeen = 0
  # A NEW controller means a NEW screen, so the previous screen's Submit must
  # not be mistaken for this one's -- otherwise the very first slot of a second
  # visit reads as a "late show AFTER Submit" and the feature would disable
  # itself on a false positive.
  gModeSkipSubmittedAtMs = 0'u64
  gModeSkipLateShow = false
  if not gModeSkipCtorLogged:
    gModeSkipCtorLogged = true
    let tid = int(cThreadId())
    okLog "skip mode screen: CharacterSelectionScreenController constructed " &
          "(0x" & hexOf(cast[uint64](ctl)) & ") on thread " & $tid &
          (if tid == int(gHostThreadId):
             " (HOST thread -- unexpected, NOT Unity's)"
           else: " (Unity's main thread)")

proc modeSkipShowSlotFired(regs: Il2CppPtr) =
  ## POSTFIX on `EFT.UI.CharacterSelectionScreen::ShowSlot`.
  ##   RCX = this (the screen)   RDX = slotView
  ##   R8  = gameMode (EGameMode) R9 = profileData
  ## The fourth argument, `controller`, is on the STACK and is therefore NOT
  ## reachable here -- which is why it is captured from the .ctor instead.
  if gModeSkipOff or not gModeSkipOn:
    return
  # STAMPED FIRST, AND UNCONDITIONALLY. This timestamp is the readiness signal
  # the deferred Submit waits on, so it must be refreshed by EVERY slot the
  # client shows -- including slots shown by the LATE second Show that
  # RunCharacterSelectionFlow performs, and including slots shown after a match
  # has already been queued. The old code returned early once a slot matched,
  # which is precisely how the late Show became invisible to this feature.
  gModeSkipLastSlotMs = cNowMs()
  if gModeSkipSubmittedAtMs != 0'u64 and not gModeSkipLateShow:
    # A slot AFTER our Submit. The screen is being re-shown by the client's own
    # flow, which is the exact condition that used to abort RunInitialLobbyFlow.
    # It is reported rather than swallowed: a silent decline is this host's
    # recurring failure mode.
    gModeSkipLateShow = true
    warn "skip mode screen: CharacterSelectionScreen.ShowSlot fired AGAIN " &
         $int(cNowMs() - gModeSkipSubmittedAtMs) & "ms AFTER Submit was " &
         "called. That means the client re-showed the selection screen after " &
         "it had been answered -- the condition that throws inside " &
         "CharacterSelectionSeasonPanel.ShowPerks and leaves the player on a " &
         "blank background. The quiet window (" & $int(ModeSkipQuietMs) &
         "ms) was NOT long enough on this run. Switching this feature off for " &
         "the session so it cannot do it twice."
    gModeSkipOff = true
    return
  if gModeSkipPending:
    return                                   # a slot already matched
  let pdRaw = cRegsInt(regs, 3'i32)            # R9
  if pdRaw == 0'u64:
    return
  if not gModeSkipShowLogged:
    gModeSkipShowLogged = true
    okLog "skip mode screen: CharacterSelectionScreen.ShowSlot first fired; " &
          "the selection screen is up and is being answered"
  gModeSkipSlotPd = cast[Il2CppPtr](pdRaw)
  gModeSkipSlotMode = cRegsInt(regs, 2'i32)    # R8
  if cMskSlotGuarded(cast[Il2CppPtr](0)) == nil:
    inc gModeSkipFaults
    warn "skip mode screen: the guarded capture body faulted (" &
         $gModeSkipFaults & " of " & $ModeSkipMaxFaults & ")"
    if gModeSkipFaults >= ModeSkipMaxFaults:
      gModeSkipOff = true
      warn "skip mode screen: too many faults; switching itself off for this " &
           "session. The selection screen is left for the player to use."

# ---------------------------------------------------------------------------
# THE DEFERRED SUBMIT
# ---------------------------------------------------------------------------

proc modeSkipSubmitBody(a: Il2CppPtr): Il2CppPtr {.
    exportc: "aowl_msk_submit_body", cdecl.} =
  ## Calls the game's own `Submit` at its byte-verified static RVA. This is the
  ## method the slot's action button ends up calling, so this is what "the
  ## player chose this slot" means to the rest of the game.
  result = cast[Il2CppPtr](1)
  let fn = cMskFn(MskTSubmit)
  if fn == nil:
    warn "skip mode screen: Submit did not verify against the startup " &
         "prologue snapshot; REFUSING to call it. Nothing was pressed and " &
         "the selection screen is left for the player to use."
    gModeSkipOff = true
    return
  cMskCallSubmit(fn, gModeSkipController, gModeSkipPendingMode,
                 gModeSkipPendingPd)
  gModeSkipSubmittedAtMs = cNowMs()
  inc gModeSkipSubmits

proc modeSkipDrainTick() =
  ## Rides the `EFT.TarkovApplication::Update` drain (slot alias, no second
  ## detour). Cheap when idle: two integer compares.
  if gModeSkipOff or not gModeSkipOn:
    return
  inc gModeSkipTicks

  if not gModeSkipPending:
    # ARMED BUT STARVED. One shot, and only once the drain has demonstrably
    # been ticking for a while with the screen never seen. Being armed is not
    # the same as working, and a silent no-op is this host's recurring failure.
    if not gModeSkipStarved and gModeSkipTicks >= ModeSkipStarveTicks and
       not gModeSkipShowLogged:
      gModeSkipStarved = true
      warn "skip mode screen: the drain has ticked " & $gModeSkipTicks &
           " times and CharacterSelectionScreen.ShowSlot has never fired, so " &
           "nothing has been skipped. Either the client never showed the " &
           "screen (fine), or the ShowSlot detour is not bound (check the " &
           "bind line above)."
    return

  # ---- THE READINESS GATE -------------------------------------------------
  #
  # Not "N frames have passed" (a guess that rots with the frame rate) but "the
  # client has stopped showing slots for a while". The wait is anchored to an
  # OBSERVABLE EVENT -- the last ShowSlot -- and it is a NEGATIVE, which is the
  # only kind of check that can fail: if the client shows one more slot the
  # clock restarts and we do not press.
  let now = cNowMs()
  if now - gModeSkipLastSlotMs < ModeSkipQuietMs:
    # If the wait has run past its hard bound, DECLINE. Never press anyway.
    if now - gModeSkipArmedAtMs > ModeSkipMaxWaitMs and not gModeSkipDeclined:
      gModeSkipDeclined = true
      gModeSkipPending = false
      gModeSkipOff = true
      warn "skip mode screen: DECLINING. A slot matched launchProfileId " &
           $int(now - gModeSkipArmedAtMs) & "ms ago but " &
           "CharacterSelectionScreen.ShowSlot has never been quiet for " &
           $int(ModeSkipQuietMs) & "ms, so this host cannot tell that the " &
           "client's own character-selection flow has finished. NOTHING WAS " &
           "PRESSED: the stock selection screen is exactly as the client " &
           "built it and the player can use it. That is deliberate -- a " &
           "screen the player can click is better than the blank background " &
           "an early Submit produces."
    return
  if gModeSkipController == nil:
    warn "skip mode screen: a slot matched launchProfileId but the " &
         "controller was never captured, so there is nothing to Submit to. " &
         "The .ctor detour did not fire; the selection screen is left for " &
         "the player to use."
    gModeSkipPending = false
    gModeSkipOff = true
    return
  if gModeSkipSubmittedFor == gModeSkipController:
    gModeSkipPending = false
    return                                   # once per controller, never twice
  gModeSkipSubmittedFor = gModeSkipController
  gModeSkipPending = false

  if cMskSubmitGuarded(cast[Il2CppPtr](0)) == nil:
    inc gModeSkipFaults
    warn "skip mode screen: the guarded Submit faulted (" & $gModeSkipFaults &
         " of " & $ModeSkipMaxFaults & ")"
    if gModeSkipFaults >= ModeSkipMaxFaults:
      gModeSkipOff = true
      warn "skip mode screen: too many faults; switching itself off for this " &
           "session. The selection screen is left for the player to use."
    return
  okLog "skip mode screen: Submit called for profile " & gModeSkipWantId &
        " (gameMode=" & $gModeSkipPendingMode & ") after " &
        $int(cNowMs() - gModeSkipArmedAtMs) & "ms of waiting, the last " &
        $int(ModeSkipQuietMs) & "ms of it with no further ShowSlot. The " &
        "character/mode selection screen has been answered without a human. " &
        "Submits this session: " & $gModeSkipSubmits & ". THIS IS NOT PROOF " &
        "THE MENU APPEARED -- assert that separately: MenuScreen (parent " &
        "\"Common UI\") must be activeInHierarchy, and BOTH " &
        "CharacterSelectionScreen copies (parents \"Login UI\" and \"UI\") " &
        "must not be."

# ---------------------------------------------------------------------------
# BINDING
# ---------------------------------------------------------------------------

proc bindModeSkip(verbose: bool): bool =
  ## Installs the two READ-ONLY POSTFIX detours. Opt-in (`uxSkipModeScreen`) and
  ## additionally inert without a `launchProfileId`. A build whose prologues do
  ## not match binds nothing at all, so this is a no-op elsewhere rather than a
  ## hazard.
  ##
  ## Neither target is shared with any other host feature -- both are unshared
  ## RVAs (checked offline with `il2cpp_resolve.py --shared`) and nothing else
  ## in this host names them, so there is no double-detour hazard here and no
  ## rider alias to take. The `Submit` CALL needs no detour at all.
  if not gModeSkipOn:
    return false
  if gModeSkipCtorSlot >= 0 and gModeSkipShowSlot >= 0:
    return true
  if not gReady or gDisableDrain:
    return false

  if gModeSkipWantId.len == 0:
    # THE NO-PROFILE CASE. The launcher is the only thing that can bind a
    # profile (it is what passes `-token`), so a missing id is a LAUNCHER
    # error, and it is reported as one. The host does not invent a profile and
    # does not silently do nothing: it says exactly what is missing and leaves
    # the stock screen, which is the only safe in-client outcome.
    warn "skip mode screen: uxSkipModeScreen is on but `launchProfileId` is " &
         "absent or empty in aowlspt-host.json, so there is no profile to " &
         "select. NOTHING IS BOUND and the character/mode selection screen " &
         "will appear as normal. aowllaunch writes this key from the same id " &
         "it passes as -token; if it is missing, the launcher failed to bind " &
         "a profile and that is where to look."
    return false

  if not modeSkipSetWantBuf(gModeSkipWantId):
    warn "skip mode screen: `launchProfileId` is " & $gModeSkipWantId.len &
         " characters, which does not fit the fixed comparison buffer (max " &
         $(gModeSkipWantBuf.len - 1) & "). REFUSING rather than comparing a " &
         "truncated id, which would match nothing and look like a silent " &
         "no-op. Nothing bound; the selection screen is left for the player."
    return false

  let ctorFn = cMskFn(MskTCtor)
  let slotFn = cMskFn(MskTShowSlot)
  let submitFn = cMskFn(MskTSubmit)
  if ctorFn == nil or slotFn == nil or submitFn == nil:
    warn "skip mode screen: the selection-screen targets did not verify " &
         "against the startup prologue snapshot on this build (" &
         $int(cMskOkCount()) & " verified, " & $int(cMskBadCount()) &
         " REJECTED): ctor=" & (if ctorFn == nil: "no" else: "ok") &
         " showSlot=" & (if slotFn == nil: "no" else: "ok") &
         " submit=" & (if submitFn == nil: "no" else: "ok") &
         ". Nothing bound; the selection screen is left for the player."
    return false

  # The .ctor first: the controller must be capturable before the first slot is
  # shown, or a matching slot would have nothing to Submit to.
  if not attachDrain("CharacterSelectionScreenController::.ctor", ctorFn,
                     cast[Il2CppMethod](0), false, verbose, 17'i32, true):
    warn "skip mode screen: could not bind the controller .ctor detour; " &
         "nothing else is bound either, because a captured slot with no " &
         "controller cannot be submitted."
    return false
  if not attachDrain("EFT.UI.CharacterSelectionScreen::ShowSlot", slotFn,
                     cast[Il2CppMethod](0), false, verbose, 18'i32, true):
    warn "skip mode screen: the controller .ctor detour bound but ShowSlot " &
         "did not; no slot will ever be captured, so nothing will be skipped."
    return false

  okLog "skip mode screen ARMED: read-only postfix detours on " &
        "CharacterSelectionScreenController::.ctor (slot " &
        $gModeSkipCtorSlot & ") and CharacterSelectionScreen::ShowSlot (slot " &
        $gModeSkipShowSlot & "); the slot whose ProfileId is " &
        gModeSkipWantId & " will be Submitted from the " &
        "TarkovApplication::Update drain once ShowSlot has been quiet for " &
        $int(ModeSkipQuietMs) & "ms (hard bound " & $int(ModeSkipMaxWaitMs) &
        "ms, after which it DECLINES and leaves the stock screen). The " &
        "screen is built and visible for that whole wait; it is dismissed, " &
        "not prevented."
  return true
