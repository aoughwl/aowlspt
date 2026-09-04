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
#   [0] CharacterSelectionScreen::ShowSlot   @0x13efae0  PREFIX detour, READ ONLY
#   [1] ...ScreenController::.ctor           @0x13f0530  PREFIX detour, READ ONLY
#
# BOTH WERE POSTFIXES UNTIL 2026-09-02 AND BOTH WERE UNSAFE AS SUCH. ShowSlot
# uses 6 register slots and the .ctor 8 (`this` + declared arguments + IL2CPP's
# trailing MethodInfo*); past FOUR they arrive on the stack, and the postfix
# thunk `sub`s its own frame before `call`ing the original, so the original
# reads them from the thunk's frame. Measured on a different site the same day:
# `EFT.UI.MenuScreen::Show(5-arg)` did exactly this and killed three boots in
# `SeasonWidgetData::From`. Nothing either handler reads is later than entry --
# see the dispatch banner in `patchFired`.
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
## VirtualQuery-guarded field reads (they return NULL/0 rather than faulting on
## an unreadable address). Used for the two values `Submit` needs, read off the
## SLOT VIEW rather than taken from registers.
proc cMskReadPtr(base: Il2CppPtr; off: int32): Il2CppPtr {.
  importc: "aowl_msk_read_ptr", nodecl.}
proc cMskReadI32(base: Il2CppPtr; off: int32): int32 {.
  importc: "aowl_msk_read_i32", nodecl.}
## KLASS IDENTITY, three-valued: 1 = names EFT.CharacterSelectionProfileData,
## 0 = names something ELSE (refuse), -1 = no name readable (INCONCLUSIVE).
## `cMskKlassName` returns whatever the last call read, so a refusal can name
## the type it found instead of asserting a cause.
proc cMskKlassIsPd(obj: Il2CppPtr): int32 {.
  importc: "aowl_msk_klass_is_pd", nodecl.}
proc cMskKlassName(): cstring {.importc: "aowl_msk_klass_name", nodecl.}

const
  # `EFT.UI.CharacterSelectionSlotViewBase`, from the offline derivation
  # (docs/AOWL_FACTS.md). These are the two arguments `Submit` takes.
  #
  # THEY ARE A LATE CROSS-CHECK, NOT THE SOURCE. `ShowSlot` is a PREFIX detour,
  # and at PREFIX ENTRY these fields have not been written yet: the host log of
  # boot 20:41 (build 0a9d871) line 416 reads "NOTHING WAS PRESSED -- the slot
  # view's `_profileData` @0x178 read back as 0x0", and the client parked on the
  # character screen. `ShowSlot` writes them LATER in its own body, at +0x727:
  #     mov r8, r13 ; mov edx, edi ; call 0x13f3ca0
  #       = CharacterSelectionSlotViewBase::Show(gameMode, profileData, vm)
  #   and Show @0x13f3ca0 +0xdd/+0xe4 does
  #     mov [rbx+0x160], r12d   -> _gameMode@0x160
  #     mov [rbx+0x178], r13    -> _profileData@0x178
  # where `edi` is ShowSlot's R8D and `r13` is ShowSlot's R9. So the ARGUMENT
  # REGISTERS AT ENTRY ARE THE SAME TWO VALUES, one call earlier -- measured
  # with `il2cpp_resolve.py disasm`, not inferred from the method names.
  #
  # The registers are therefore what is captured; these offsets are re-read at
  # SUBMIT time (hundreds of ms later, by which point the client has populated
  # them) purely so the two can be COMPARED. A disagreement is logged loudly and
  # the FIELD wins, because the field is what a player's click would pass.
  MskSlotGameModeOff = 0x160'i32   ## _gameMode      EGameMode, int32
  MskSlotProfileOff  = 0x178'i32   ## _profileData   CharacterSelectionProfileData
  MskStatusAvailable = 2'i32
    ## `EFT.ECharacterSelectionProfileStatus`: Locked=0, Empty=1, Available=2,
    ## InRaid=3 -- MEASURED from the metadata `HASDEFAULT` constants and written
    ## up in docs/BOOT-FLOW-MAP.md §4.4, which also measures that `SubmitAsync`
    ## itself refuses `Status == 0` and only proceeds on `Status == 2`. The old
    ## comment here said the enum was not knowable offline; it is, and this is
    ## the value.

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
  ModeSkipMaxAnswers = 4
    ## How many SHOWINGS of the character/mode screen this feature will answer
    ## in one session. It used to answer exactly ONE and then switch itself off
    ## the moment a slot was shown again -- and MEASURED 2026-09-01, the client
    ## shows this screen AGAIN after the main-menu PLAY button is pressed, so
    ## "one-shot" meant the second showing was never answered by anything and
    ## autoraid sat on the next step until it timed out.
    ##
    ## The old self-disable was written when the blank-background bug was
    ## believed to be a race with the client's own second Show. It was NOT --
    ## the banner above records that it was the `pvp-season` slot and a null
    ## SeasonalPerksData, and that dropping the seasonal key fixed it outright.
    ## So a re-showing is now RE-ARMED rather than fatal. It is still BOUNDED:
    ## after this many answers the feature stops answering and says so, because
    ## an unbounded answer loop against a screen that keeps coming back would
    ## be exactly the kind of thing that must never run in a live client.
  ModeSkipAnswerBurst = 1
    ## WHICH SHOWING OF THE SCREEN IS ANSWERED. Not the first.
    ##
    ## MEASURED 2026-09-02: the client died at 48 s in
    ## `SeasonWidgetData::From @0x141FFD0+0x133` called from
    ## `MenuScreen::Show(5-arg) @0x15387A0+0x994` -- the FIRST MenuScreen::Show
    ## of the session, faulting on its own Profile/SeasonalRewardController
    ## argument. The host trail was
    ##   [0:00:26.844] CharacterSelectionScreenController #1 constructed
    ##   [0:00:26.859] Submit called ... after 0ms of waiting
    ## and NO `MenuScreen::Show fired` epoch line at all. Every boot that
    ## SURVIVED that night logged `after 15-31ms`. Submitting on the FIRST
    ## showing hands the client's own `RunCharacterSelectionFlow` a Profile it
    ## is still building.
    ##
    ## THE OLD GATE WAS A MILLISECOND TIMER AND IT WAS SET TO ZERO.
    ## `ModeSkipQuietMs` is `0` in this file while its own comment argues for
    ## 500 -- so there was never any wait: Submit went out on the first drain
    ## tick after the match, and "0ms" vs "15-31ms" only records which
    ## millisecond that tick happened to land in. That is a coin flip, not a
    ## gate. (For the record, since it was asked: the `answer only after a NEW
    ## .ctor` rule added earlier CANNOT have shortened this. It only ever
    ## BLOCKS a re-answer; the first answer's path does not read it.)
    ##
    ## ANSWERING THE SECOND SHOWING WAS TRIED, AND THERE IS NO SECOND SHOWING.
    ## MEASURED on the very next build: `SHOWING 1 ... 3 ShowSlot call(s)`, the
    ## match discarded as designed -- and then nothing at all for over three
    ## minutes. No showing 2, no Submit, no `MenuScreen::Show`, mods still
    ## HELD, the client parked on the character screen. The "~372 ms re-show"
    ## this file's older comments lean on does NOT happen by itself here; the
    ## boots that survived were showing 1 answered a tick or two after its
    ## burst, and the boot that died was showing 1 answered in the SAME tick.
    ##
    ## So this is 1: answer the FIRST showing, but never on the tick its burst
    ## ends -- see the deferral in `modeSkipDrainTick`. The unit is a DRAIN
    ## TICK (an observed frame), not a millisecond, because tick phase is
    ## precisely what decided crash-vs-survive before. The counters below keep
    ## running regardless, so if this client ever does produce a showing 2 the
    ## log will say so rather than this comment being believed forever.
  ModeSkipDeclineTicks = 900
    ## If the showing this host answers never arrives within this many drain
    ## ticks of showing 1 (~15 s at 60 fps), DECLINE: never press, leave the
    ## stock screen for the player. UNREACHABLE while `ModeSkipAnswerBurst` is
    ## 1, which is the shipped value -- it exists for whoever raises that
    ## constant, and it is deliberately not dressed up as a readiness signal:
    ## "the showing has not come" is not the same claim as "the flow is
    ## ready", and answering anyway is the guess that killed the client.
  ModeSkipApplyDepth = 6
    ## Descent from the slot view to its `Apply` control. `tools/entergame.py`
    ## finds it with a budget of 5000 from the slot, so it is shallow.
  ModeSkipApplyCap = 64
    ## ACTIVE nodes examined for that search. A count AT the cap is visible in
    ## the refusal, so a truncation cannot read as an absence.
  ModeSkipConfirmTicks = 120
    ## Drain ticks (~2 s at 60 fps) to wait for `MenuScreen::Show` after the
    ## CARD press before pressing a confirm-shaped control, if the card has
    ## one. Short, because this is the second half of one answer, not a retry.
  ModeSkipReadbackTicks = 900
    ## Drain ticks (~15 s at 60 fps) to wait for `MenuScreen::Show` after the
    ## press before saying, out loud, that there was NO readback.
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
var gModeSkipBoundLogged = false        ## the answer-bound message, once
var gModeSkipCtors = 0                 ## controller constructions observed
var gModeSkipCtorsAtSubmit = 0         ## `gModeSkipCtors` when Submit was sent
var gModeSkipSlotsThisTick = 0         ## ShowSlot calls since the last drain tick
var gModeSkipBursts = 0                ## SHOWINGS closed so far, this controller
var gModeSkipBurstMs = 0'u64           ## when the last burst closed
var gModeSkipPendingBurst = 0          ## the burst the queued match came from
var gModeSkipBurst1Tick = 0            ## drain tick on which burst 1 closed
var gModeSkipBurstOpen = false         ## a showing is in progress right now
var gModeSkipBurstSlots = 0            ## ShowSlot calls in the open showing
var gModeSkipBurstLastTick = 0         ## last drain tick that saw a ShowSlot
var gModeSkipSlotView: Il2CppPtr = nil     ## ShowSlot RDX: the slot view
var gModeSkipScreen: Il2CppPtr = nil       ## ShowSlot RCX: the screen
var gModeSkipPendingView: Il2CppPtr = nil  ## the MATCHING slot's view
var gModeSkipPendingScreen: Il2CppPtr = nil
var gModeSkipArgFromRegs = false
  ## The Submit pair currently held came from `ShowSlot`'s ARGUMENT REGISTERS
  ## (R8D/R9) rather than from the slot view's fields, because at PREFIX entry
  ## the fields are not written yet. `modeSkipSubmitBody` re-reads the fields
  ## later and flips this to false if they agree or supersede.
var gModeSkipPressedOk = false             ## the Apply press went through
var gModeSkipPressWhy = ""                 ## why it did not
var gModeSkipPressAtTick = 0               ## drain tick of the press
var gModeSkipMenuEpoch0 = 0                ## site-2 epoch BEFORE the press
var gModeSkipReadbackDone = false          ## the readback has been reported
var gModeSkipPressPhase = 0                ## 0 = the card, 1 = its confirm
var gModeSkipPressedNode: Il2CppPtr = nil  ## what phase 0 pressed
var gModeSkipCandNames = ""                ## every pressable candidate seen
var gModeSkipPickName = ""                 ## what was pressed, name + klass
var gModeSkipHasConfirm = false            ## the card has a second control
var gModeSkipConfirmName = ""              ## and what that one is called
var gModeSkipCardTitle = ""                ## the TITLE A PERSON READS on it
var gModeSkipArgMode: int32 = 0            ## _gameMode @0x160, as passed
var gModeSkipArgPd: Il2CppPtr = nil        ## _profileData @0x178, as passed
var gModeSkipDeclinedLate = false      ## the "burst 2 never came" refusal, once
var gModeSkipStaleLogged = false       ## the stale-controller refusal, once
var gModeSkipMenuEpoch = 0             ## last seen uihooks MenuScreen::Show epoch
var gModeSkipMenuSiteOk = false        ## the site was verified BY NAME
var gModeSkipMenuSite = -1             ## its index, handed over by the caller
var gModeSkipCleared = 0               ## caches dropped on a menu-show event
var gModeSkipShows = 0                 ## ShowSlot firings observed
var gModeSkipSubmittedAtLogMs = 0'u64  ## last Submit time, kept for the log
                                       ## after the re-arm clears the gate
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

  # THE PREDICATE: ProfileId equality first, and it is the strong one -- an
  # EMPTY slot carries no ProfileId to match, and an integer masquerading as a
  # pointer cannot carry a matching 24-hex-digit id.
  if cMskProfileIs(pd, cast[cstring](addr gModeSkipWantBuf[0])) == 0'i32:
    return

  # THE KLASS CHECK. Readability is not identity: the 2026-09-02 minidump had
  # `EGameMode.Pve == 1` sitting where a Profile belongs, and every page check
  # in the world says nothing about that. Three outcomes, never two.
  let klassVerdict = cMskKlassIsPd(pd)
  if klassVerdict == 0'i32:
    warn "skip mode screen: NOT ANSWERING -- the profileData in R9 (0x" &
         hexOf(cast[uint64](pd)) & ") is a `" & $cMskKlassName() &
         "`, not an EFT.CharacterSelectionProfileData. Nothing was pressed."
    return
  if klassVerdict < 0'i32:
    info "skip mode screen: the klass of the R9 profileData could not be " &
         "named (INCONCLUSIVE, not a pass). Proceeding on ProfileId equality, " &
         "which is the stronger test and has already matched."

  # THE STATUS GATE. MEASURED (docs/BOOT-FLOW-MAP.md §4.4): the client's own
  # `SubmitAsync` refuses `Status == 0` and its bypass path proceeds only on
  # `Status == 2 (Available)`; ShowSlot itself compares `[profileData+0x20]`
  # against 2 twice. Locked/Empty/InRaid must not be pressed.
  if status != MskStatusAvailable:
    warn "skip mode screen: NOT ANSWERING -- profile " & idStr &
         " matched launchProfileId but its Status@0x20 is " & $status &
         ", not " & $MskStatusAvailable &
         " (Available). Locked=0 Empty=1 Available=2 InRaid=3. Nothing was " &
         "pressed; the screen is left for the player."
    return

  if gModeSkipPending:
    return                                   # already have one; first wins
  gModeSkipPendingPd = pd
  gModeSkipPendingView = gModeSkipSlotView
  # THE TWO ARGUMENTS, TAKEN FROM `ShowSlot`'S OWN ARGUMENT REGISTERS.
  #
  # This is a PREFIX detour. At entry the slot view's `_gameMode`@0x160 and
  # `_profileData`@0x178 HAVE NOT BEEN WRITTEN -- boot 20:41 read 0x0 out of
  # 0x178 and pressed nothing. `ShowSlot` writes them itself, further down its
  # own body, by calling `CharacterSelectionSlotViewBase::Show(gameMode,
  # profileData, viewModel)` @0x13f3ca0 with edx = its own R8D and r8 = its own
  # R9; `Show` then stores rdx -> +0x160 and r8 -> +0x178. So R8/R9 at entry are
  # not a substitute for the fields, they are literally the values the fields
  # are about to hold. Measured with `il2cpp_resolve.py disasm`, both bodies.
  #
  # The click path a player takes -- `OnActionButtonPressed` @0x13F61B0 ->
  # `Selected(_gameMode, _profileData)` -> `Submit` -- passes those same fields,
  # so this is still the player's pair. `modeSkipSubmitBody` re-reads the fields
  # at press time, when they ARE populated, and prefers them if they disagree.
  gModeSkipArgMode = cast[int32](cast[uint32](gModeSkipSlotMode))  # R8D
  gModeSkipArgPd = pd                                             # R9
  gModeSkipArgFromRegs = true
  gModeSkipPendingScreen = gModeSkipScreen
  gModeSkipPendingMode = gModeSkipSlotMode
  gModeSkipPending = true
  # WHICH SHOWING this match belongs to. The burst currently in progress is the
  # one after the last CLOSED burst, so it is `gModeSkipBursts + 1`.
  gModeSkipPendingBurst = gModeSkipBursts + 1
  gModeSkipArmedAtMs = cNowMs()
  okLog "skip mode screen: slot for profile " & idStr & " (\"" & nickStr &
        "\", gameMode=" & $gModeSkipSlotMode & ") matches launchProfileId; " &
        "Submit is QUEUED, not sent -- it waits for " & $int(ModeSkipQuietMs) &
        "ms with no further ShowSlot, because the client's own " &
        "RunCharacterSelectionFlow shows this screen AGAIN ~372ms later and " &
        "answering before that lands throws inside CharacterSelectionSeason" &
        "Panel.ShowPerks and strands the player on a blank background"

proc modeSkipCtorFired(regs: Il2CppPtr) =
  ## PREFIX on `CharacterSelectionScreenController::.ctor`. Captures `this`.
  ## This is a single register read and a pointer compare; it dereferences
  ## nothing, so it needs no guarded body of its own.
  ##
  ## AT CTOR ENTRY NOTHING IS INITIALISED -- not one field of the object in RCX,
  ## and that is exactly the hazard that made the ShowSlot prefix read 0x0 out
  ## of `_profileData`. So this reads `this` AND NOTHING ELSE, forever. Anything
  ## the feature needs about the controller's contents must come from a later
  ## call that has been handed it -- `ShowSlot`'s arguments, in practice.
  ## The .ctor uses 8 register slots (`this` + 6 declared arguments + the hidden
  ## MethodInfo*), which is the other reason it is a prefix and not a postfix.
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
  gModeSkipArgFromRegs = false
  gModeSkipSlotsSeen = 0
  # A NEW controller means a NEW screen, so the previous screen's Submit must
  # not be mistaken for this one's -- otherwise the very first slot of a second
  # visit reads as a "late show AFTER Submit" and the feature would disable
  # itself on a false positive.
  gModeSkipSubmittedAtMs = 0'u64
  gModeSkipLateShow = false
  # A NEW controller is a NEW screen, so its showings are counted from zero.
  # Otherwise burst 2 of the FIRST screen would answer the SECOND screen's
  # first showing -- the same off-by-one-screen mistake as answering a stale
  # controller, in a different costume.
  gModeSkipBursts = 0
  gModeSkipSlotsThisTick = 0
  gModeSkipPendingBurst = 0
  gModeSkipBurst1Tick = 0
  gModeSkipBurstOpen = false
  gModeSkipBurstSlots = 0
  gModeSkipBurstLastTick = 0
  gModeSkipBurstMs = 0'u64
  gModeSkipDeclinedLate = false
  inc gModeSkipCtors
  # EVERY construction is logged, not just the first, and the log carries the
  # counter. The old once-only line made the whole question "does the client
  # build a NEW controller for the post-PLAY showing?" unanswerable from the
  # log, which is the question this feature's behaviour depends on. Capped at
  # 8 lines so a pathological loop cannot flood the log; the counter continues.
  if gModeSkipCtors <= 8:
    gModeSkipCtorLogged = true
    let tid = int(cThreadId())
    okLog "skip mode screen: CharacterSelectionScreenController #" &
          $gModeSkipCtors & " constructed " &
          "(0x" & hexOf(cast[uint64](ctl)) & ") on thread " & $tid &
          (if tid == int(gHostThreadId):
             " (HOST thread -- unexpected, NOT Unity's)"
           else: " (Unity's main thread)")

proc modeSkipShowSlotFired(regs: Il2CppPtr) =
  ## PREFIX on `EFT.UI.CharacterSelectionScreen::ShowSlot`.
  ##   slot 0  RCX = this (the screen)
  ##   slot 1  RDX = slotView                 (CharacterSelectionSlotViewBase)
  ##   slot 2  R8D = gameMode                 (EGameMode, a 32-bit enum)
  ##   slot 3  R9  = profileData              (CharacterSelectionProfileData)
  ##   slot 4  STACK entry_rsp+0x28 = controller
  ##   slot 5  STACK entry_rsp+0x30 = MethodInfo*
  ## MEASURED with `il2cpp_resolve.py disasm 0x13efae0`, which prints that arg
  ## mapping itself and whose 16 prologue bytes match this feature's signature
  ## table exactly. The two stack slots are the reason this is a PREFIX and not
  ## a postfix (eb39963): a postfix thunk on more than four slots shifts them.
  ##
  ## The fourth argument, `controller`, is not read here -- it is captured from
  ## the controller's own .ctor, where it is `this` in RCX. (`aowl_uih_stack_arg`
  ## could reach it now; that is a change with its own evidence requirement and
  ## is deliberately NOT made as part of this fix.)
  ##
  ## WHAT IS **NOT** READ AT ENTRY: the slot view's `_gameMode`@0x160 and
  ## `_profileData`@0x178. `ShowSlot` has not written them yet -- that is the
  ## whole bug this comment exists for.
  if gModeSkipOff or not gModeSkipOn:
    return
  # STAMPED FIRST, AND UNCONDITIONALLY. This timestamp is the readiness signal
  # the deferred Submit waits on, so it must be refreshed by EVERY slot the
  # client shows -- including slots shown by the LATE second Show that
  # RunCharacterSelectionFlow performs, and including slots shown after a match
  # has already been queued. The old code returned early once a slot matched,
  # which is precisely how the late Show became invisible to this feature.
  gModeSkipLastSlotMs = cNowMs()
  # THE VERSION BRAND'S VERDICT ANCHOR. `CharacterSelectionScreen::ShowSlot` is
  # the only bound event in this host that means "the character-selection
  # screen is on screen" -- uihooks has no site for that screen (site 3 is the
  # PMC/SCAV side selector, which is much later). This stores ONE timestamp and
  # does no pointer work; the read-back happens in `modstab.nim` under that
  # feature's own guard. It is therefore gated on `skipModeScreen` being on --
  # with modeskip off the brand reports INCONCLUSIVE rather than PASS.
  verBrandNoteCharSelect()
  inc gModeSkipShows
  inc gModeSkipSlotsThisTick
  if gModeSkipSubmittedAtMs != 0'u64:
    # A slot AFTER our Submit: the screen is being SHOWN AGAIN. MEASURED
    # 2026-09-01 that this is what the client does after the main-menu PLAY
    # button, and answering it is the whole point of the feature -- the screen
    # that shows after PLAY is the same character/mode selector, and nothing
    # answered it, so autoraid's next step never got a screen and refused.
    #
    # RE-ARM, bounded, and say so. This is not the blank-background condition:
    # that was the `pvp-season` slot and a null SeasonalPerksData (see the
    # banner), not a second Show.
    gModeSkipLateShow = true
    if gModeSkipSubmits >= ModeSkipMaxAnswers:
      if not gModeSkipBoundLogged:
        gModeSkipBoundLogged = true
        warn "skip mode screen: the selection screen has been shown again " &
             "after " & $gModeSkipSubmits & " answers, which is the bound " &
             "(ModeSkipMaxAnswers). NOT answering it: an unbounded answer " &
             "loop against a screen that keeps returning is not something " &
             "this host will run. The stock screen is left for the player."
      return
    # THE CONTROLLER MUST BE FRESH. MEASURED 2026-09-02: a build that re-armed
    # on ANY re-showing died 2 of 2 boots at ~36 s, on the drain line for menu
    # arrival, with `mono_class_has_parent` inside GameAssembly. That is the
    # signature of a class read on a FREED managed object: the controller was
    # captured from its .ctor at ~26 s, the first screen was answered and torn
    # down, and a second showing ten seconds later made this feature call
    # `Submit` on the DEAD pointer it still had. The pd is fresh (the game just
    # handed it to us in R9); the CONTROLLER is not, and nothing in a pointer's
    # bits says it has been collected.
    #
    # So a re-showing is only answerable if the client built a NEW controller
    # for it -- an event this feature OBSERVES, from the .ctor postfix. If it
    # did not, we decline and say exactly that. Declining is what the previous
    # build did (it switched itself off); this keeps the feature alive for a
    # later, genuinely new screen, and never presses on a stale pointer.
    if gModeSkipCtors <= gModeSkipCtorsAtSubmit:
      if not gModeSkipStaleLogged:
        gModeSkipStaleLogged = true
        warn "skip mode screen: ShowSlot fired again after Submit, but NO new " &
             "CharacterSelectionScreenController has been constructed since " &
             "(constructions=" & $gModeSkipCtors & ", at last Submit=" &
             $gModeSkipCtorsAtSubmit & "). The controller this feature holds " &
             "is the one it already answered and the client may have destroyed " &
             "it. NOT ANSWERING: calling Submit on a freed object is a " &
             "`mono_class_has_parent` crash inside GameAssembly, MEASURED " &
             "2026-09-02 at ~36s on 2 of 2 boots. The screen is left for the " &
             "player, or for autoraid's CHARACTER step, which presses live UI " &
             "and holds no cached pointer."
      return
    gModeSkipSubmittedAtMs = 0'u64
    gModeSkipSubmittedFor = nil
    gModeSkipPending = false
    gModeSkipPendingPd = nil
    gModeSkipSlotsSeen = 0
    okLog "skip mode screen: ShowSlot fired AGAIN " &
          $int(cNowMs() - gModeSkipSubmittedAtLogMs) & "ms after the last " &
          "Submit -- the client is showing the character/mode screen for the " &
          "" & $gModeSkipShows & "th slot event this session. RE-ARMING " &
          "(answers so far " & $gModeSkipSubmits & " of at most " &
          $ModeSkipMaxAnswers & "); this showing will be answered too."
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
  # RDX is the SLOT VIEW and RCX is the SCREEN. Both are receivers the game
  # handed us, and they are what makes it possible to answer this screen THE
  # WAY A PLAYER DOES instead of calling `Submit` behind the flow's back.
  gModeSkipSlotView = cast[Il2CppPtr](cRegsInt(regs, 1'i32))
  gModeSkipScreen = cast[Il2CppPtr](cRegsInt(regs, 0'i32))
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
  ## PRESS THE SLOT THE WAY A PLAYER DOES. This used to CALL
  ## `CharacterSelectionScreenController::Submit` at its RVA, and that is the
  ## thing that had to stop.
  ##
  ## MEASURED 2026-09-02, from the minidump of the menu-arrival crash
  ## (`tools/dmpread.py` on Crash_2026-09-02_131229783):
  ##   ACCESS_VIOLATION at 0x7FFB3EE80103, a READ of 0x21 faulted,
  ##   Rax=1 Rcx=1 Rdx=0
  ## The faulting instruction is `mov r8,[rax+0x20]` inside
  ## `SeasonWidgetData::From(Profile, SeasonalRewardController)`: **the Profile
  ## argument was the INTEGER 1 and the SeasonalRewardController was NULL.**
  ## `MenuScreen::Show` was called by the game's own `MainMenuShowOperation`
  ## with an unpopulated selection -- and that flow starts from our Submit.
  ##
  ## So calling `Submit` directly skips the work the game does between the
  ## player's click and `Show`: it hands the menu flow a selection that has not
  ## been built. The tick+1 deferral made that RARER, not impossible -- roughly
  ## 4 deaths against 5 survivals with the rule in place. A timing rule cannot
  ## fix a MISSING STEP, and "rarer" was mistaken for "fixed" twice tonight.
  ##
  ## The route now is the one `tools/entergame.py` has always used from the
  ## inspector side, and it is verified live: the slot's own `Apply` control,
  ## an `EFT.UI.DefaultUIButton`, pressed through exactly the same OnClick
  ## path the raid-entry steps use. The game then runs ITS OWN selection flow
  ## and populates Profile and SeasonalRewardController before `Show`.
  ##
  ## The receiver is not searched for: `ShowSlot` handed us the SLOT VIEW in
  ## RDX and the screen in RCX. `Submit` @0x1720B10's table row is deliberately
  ## LEFT in `aowl_msk_targets` (removing it would renumber the rows below it),
  ## but nothing calls it any more.
  result = cast[Il2CppPtr](1)
  gModeSkipPressedOk = false
  gModeSkipPressWhy = ""
  let view = gModeSkipPendingView
  if view == nil:
    gModeSkipPressWhy = "ShowSlot never handed us a slot view in RDX"
    return
  let tr = iToTransform(view)
  if tr == nil or not duOk(tr, 0x20'i32):
    gModeSkipPressWhy = "the slot view (0x" & hexOf(cast[uint64](view)) &
                        ") did not resolve to a readable Transform"
    return
  # THE DERIVED CALL, AND NOTHING ELSE. No button is pressed and no tree is
  # searched: the offline derivation settled what a click actually runs.
  #
  #   CharacterSelectionSlotViewBase::OnActionButtonPressed @0x13F61B0
  #     -> Selected(_gameMode, _profileData)
  #       -> CharacterSelectionScreenController::Submit(EGameMode,
  #            CharacterSelectionProfileData) @0x13F0BF0   UNIQUE
  #
  # FRAME: RCX = controller, EDX = EGameMode as int32 (Regular=0, Pve=1,
  # PvpSeason=2), R8 = CharacterSelectionProfileData, R9 = MethodInfo* (the
  # game itself passes 0).
  #
  # The arguments come from the SLOT VIEW's own fields -- `_gameMode` @0x160 and
  # `_profileData` @0x178 -- because that is what `Selected` is handed. The
  # previous call took them from the ShowSlot argument registers, which put an
  # EGameMode where the Profile goes: the minidump's `Profile == 1` is
  # `EGameMode.Pve == 1` sitting in the profile slot, and that is the crash.
  #
  # `Submit` is ASYNC (TaskCompletionSource -> RunCharacterSelectionFlow
  # d__130 -> ExecuteCharacterSelection -> MainMenuShowOperation ->
  # MenuScreen::Show), so returning proves nothing and the readback stays the
  # site-2 show event.
  if gModeSkipController == nil:
    gModeSkipPressWhy = "the CharacterSelectionScreenController was never " &
                        "captured (its .ctor PREFIX did not fire), so there " &
                        "is no receiver for Submit"
    return
  if cIsReadable(gModeSkipController, 0x30'i32) == 0'i32:
    gModeSkipPressWhy = "the controller (0x" &
                        hexOf(cast[uint64](gModeSkipController)) &
                        ") is not readable at the moment of use"
    return
  # ---- RECONCILE: the registers we captured against the fields, NOW ----
  #
  # This runs hundreds of milliseconds after `ShowSlot` returned, so by here the
  # slot view's own `_gameMode`/`_profileData` HAVE been written (ShowSlot ->
  # CharacterSelectionSlotViewBase::Show @0x13f3ca0 stores them). That makes
  # this a check that CAN fail: two independently-sourced values for the same
  # pair, compared. The FIELD wins when both are present, because the field is
  # exactly what a player's click passes; a mismatch is reported, never hidden.
  let fieldPd = cMskReadPtr(gModeSkipPendingView, MskSlotProfileOff)
  let fieldMode = cMskReadI32(gModeSkipPendingView, MskSlotGameModeOff)
  if fieldPd != nil and cIsReadable(fieldPd, 0x30'i32) != 0'i32:
    if fieldPd != gModeSkipArgPd or fieldMode != gModeSkipArgMode:
      warn "skip mode screen: the slot view's fields DISAGREE with the " &
           "ShowSlot arguments -- _profileData@0x178 = 0x" &
           hexOf(cast[uint64](fieldPd)) & " vs R9 = 0x" &
           hexOf(cast[uint64](gModeSkipArgPd)) & "; _gameMode@0x160 = " &
           $fieldMode & " vs R8D = " & $gModeSkipArgMode & ". Using the " &
           "FIELDS, which are what a player's click passes."
    gModeSkipArgPd = fieldPd
    gModeSkipArgMode = fieldMode
    gModeSkipArgFromRegs = false
  else:
    info "skip mode screen: the slot view's `_profileData`@0x178 still reads " &
         "0x" & hexOf(cast[uint64](fieldPd)) & " at press time, so the pair " &
         "captured from ShowSlot's argument registers (R8D/R9) is used. Those " &
         "are the same two values the view is written FROM -- ShowSlot passes " &
         "R8D/R9 to CharacterSelectionSlotViewBase::Show @0x13f3ca0, which " &
         "stores them into 0x160/0x178."

  if gModeSkipArgPd == nil or cIsReadable(gModeSkipArgPd, 0x30'i32) == 0'i32:
    gModeSkipPressWhy = "the profileData is 0x" &
                        hexOf(cast[uint64](gModeSkipArgPd)) &
                        ", which is not a readable object. It was read from " &
                        (if gModeSkipArgFromRegs:
                           "ShowSlot's REGISTER SLOT 3 (R9, the declared " &
                           "`CharacterSelectionProfileData profileData` " &
                           "argument)"
                         else:
                           "the slot view's `_profileData` field @0x" &
                           hexOf(uint64(MskSlotProfileOff))) &
                        ". NOTHING WAS CALLED"
    return
  if cMskKlassIsPd(gModeSkipArgPd) == 0'i32:
    gModeSkipPressWhy = "the profileData (0x" &
                        hexOf(cast[uint64](gModeSkipArgPd)) &
                        ") is a `" & $cMskKlassName() & "`, not an " &
                        "EFT.CharacterSelectionProfileData. NOTHING WAS CALLED"
    return
  if cMskProfileStatus(gModeSkipArgPd) != MskStatusAvailable:
    gModeSkipPressWhy = "the profileData's Status@0x20 is " &
                        $cMskProfileStatus(gModeSkipArgPd) & ", not " &
                        $MskStatusAvailable & " (Available; Locked=0 Empty=1 " &
                        "InRaid=3). The client's own SubmitAsync refuses that " &
                        "too. NOTHING WAS CALLED"
    return
  if gModeSkipArgMode < 0 or gModeSkipArgMode > 8:
    gModeSkipPressWhy = "the gameMode is " & $gModeSkipArgMode &
                        ", which is not a plausible EGameMode (Regular=0, " &
                        "Pve=1, PvpSeason=2). It was read from " &
                        (if gModeSkipArgFromRegs:
                           "ShowSlot's REGISTER SLOT 2 (R8D, the declared " &
                           "`EGameMode gameMode` argument)"
                         else:
                           "the slot view's `_gameMode` field @0x" &
                           hexOf(uint64(MskSlotGameModeOff))) &
                        ". NOTHING WAS CALLED"
    return
  let fn = cMskFn(MskTSubmit)
  if fn == nil:
    gModeSkipPressWhy = "Submit @0x13F0BF0 did not verify against the startup " &
                        "prologue snapshot on this build; REFUSING to call it"
    return
  cMskCallSubmit(fn, gModeSkipController, uint64(gModeSkipArgMode),
                 gModeSkipArgPd)
  gModeSkipPressedOk = true
  gModeSkipSubmittedAtMs = cNowMs()
  gModeSkipSubmittedAtLogMs = gModeSkipSubmittedAtMs
  gModeSkipCtorsAtSubmit = gModeSkipCtors
  inc gModeSkipSubmits

proc modeSkipWantShowHook(site: int) =
  ## Subscribe to `EFT.UI.MenuScreen::Show` (5-arg) so that the cached
  ## controller can be DROPPED the moment the main menu is up: the selection
  ## screen is gone by then, and a pointer to a screen the client has torn down
  ## is exactly what killed the client on 2026-09-02.
  ##
  ## THE SITE INDEX IS PASSED IN, AND VERIFIED BY NAME BY THE CALLER. It cannot
  ## be resolved here: `uihooks.nim` is included AFTER this file, so neither its
  ## `UihSite*` constants nor the C accessors from its header are in scope at
  ## this point in the translation unit (procs resolve module-wide; constants,
  ## module-level vars and `{.emit.}`ed C declarations do not). Writing a bare
  ## `2` here and hoping would be exactly the positional-index bug the build's
  ## idxbind gate exists to prevent -- so the caller reads the site's own NAME
  ## back and only then hands the index over.
  if not gModeSkipOn: return
  gModeSkipMenuSite = site
  gModeSkipMenuSiteOk = true
  uihWant(site)

proc modeSkipPressReadback() =
  ## THE READBACK FOR THE PRESS, and it is an event, not a self-comparison:
  ## `MenuScreen::Show` (uihooks site 2) firing is the game's own confirmation
  ## that the selection flow ran to completion. A press that returned cleanly
  ## is not evidence -- that is exactly what the old `Submit` call did, right
  ## up to the crash.
  if not gModeSkipPressedOk or gModeSkipReadbackDone: return
  if gModeSkipMenuSiteOk and uihEpoch(gModeSkipMenuSite) > gModeSkipMenuEpoch0:
    gModeSkipReadbackDone = true
    okLog "skip mode screen: READBACK -- MenuScreen::Show fired (uihooks " &
          "site " & $gModeSkipMenuSite & ", epoch " &
          $uihEpoch(gModeSkipMenuSite) & ") after the slot press. The " &
          "client's own selection flow completed and the menu is coming up; " &
          "that is the thing this feature exists to achieve, and it is now " &
          "OBSERVED rather than assumed."
    return
  # A SECOND STEP, ONLY ON EVIDENCE. If the card has a confirm-shaped control
  # and the first press produced no readback within the confirm window, press
  # that one too -- in order, with this readback between them, never both at
  # once.
  if gModeSkipHasConfirm and gModeSkipPressPhase == 0 and
     gModeSkipTicks - gModeSkipPressAtTick > ModeSkipConfirmTicks:
    gModeSkipPressPhase = 1
    gModeSkipPressAtTick = gModeSkipTicks
    okLog "skip mode screen: the card press produced no MenuScreen::Show " &
          "within " & $ModeSkipConfirmTicks & " drain ticks, and this card " &
          "HAS a second, confirm-shaped control (" & gModeSkipConfirmName &
          "). Pressing that now, in order, with the readback between -- never " &
          "both at once."
    if cMskSubmitGuarded(cast[Il2CppPtr](0)) == nil:
      inc gModeSkipFaults
      warn "skip mode screen: the guarded confirm press faulted (" &
           $gModeSkipFaults & " of " & $ModeSkipMaxFaults & ")"
    elif not gModeSkipPressedOk:
      warn "skip mode screen: the confirm press did NOT go through -- " &
           gModeSkipPressWhy & "."
    else:
      okLog "skip mode screen: pressed the confirm control `" &
            gModeSkipPickName & "`. The readback is still MenuScreen::Show."
    return
  if gModeSkipTicks - gModeSkipPressAtTick > ModeSkipReadbackTicks:
    gModeSkipReadbackDone = true
    var count = 0
    var names = ""
    let scr = iToTransform(gModeSkipPendingScreen)
    if scr != nil and duOk(scr, 0x20'i32):
      arActiveCensus(scr, 3, count, names)
    # IS THE SCREEN STILL USABLE? This host writes NOTHING to the screen -- it
    # invokes the control's own entry point and sets no state -- so there is
    # nothing to undo. What it CAN do is say whether the card is still
    # clickable, read off the button itself rather than asserted.
    # THIS HOST PRESSES NOTHING AND WRITES NOTHING. The answer is one call --
    # `Submit`, the method a click ends at -- so there is no half-applied UI
    # state to undo and the stock screen remains exactly as the client built
    # it. Said out loud, because the build before this one DID press a control
    # and left the screen half-transitioned.
    warn "skip mode screen: the values passed to Submit were controller=0x" &
         hexOf(cast[uint64](gModeSkipController)) & ", EGameMode=" &
         $gModeSkipArgMode & ", profileData=0x" &
         hexOf(cast[uint64](gModeSkipArgPd)) & ", MethodInfo=0, sourced from " &
         (if gModeSkipArgFromRegs:
            "ShowSlot's argument registers (slot 2 = R8D gameMode, slot 3 = " &
            "R9 profileData)"
          else:
            "the slot view's fields (_gameMode@0x160, _profileData@0x178)") &
         ". Nothing was " &
         "pressed and no screen state was written by this host, so the " &
         "selection screen is exactly as the client left it."
    warn "skip mode screen: NO READBACK. Submit was called " &
         $(gModeSkipTicks - gModeSkipPressAtTick) & " drain ticks ago and " &
         (if not gModeSkipMenuSiteOk:
            "uihooks site 2 (MenuScreen::Show) is not armed here, so this " &
            "host cannot see whether the menu came up at all"
          else:
            "MenuScreen::Show (uihooks site 2) has NOT fired") &
         ". The press ran and the flow did not complete; that is a REFUSAL to " &
         "claim success, not a failure to act. ACTIVE under the selection " &
         "screen (depth<=3, " & $count & "): " &
         (if names.len > 0: names else: "<none>")

proc modeSkipMenuTick() =
  ## ONE integer compare per drain tick. When the main menu shows, everything
  ## this feature cached about the selection screen is presumed DEAD.
  if not gModeSkipMenuSiteOk: return
  let ep = uihEpoch(gModeSkipMenuSite)
  if ep == gModeSkipMenuEpoch: return
  gModeSkipMenuEpoch = ep
  if gModeSkipController == nil and not gModeSkipPending: return
  gModeSkipCleared = gModeSkipCleared + 1
  gModeSkipController = nil
  gModeSkipPendingPd = nil
  gModeSkipPending = false
  gModeSkipSubmittedFor = nil
  okLog "skip mode screen: MenuScreen::Show fired (uihooks site 2, epoch " &
        $ep & ") -- the main menu is up, so the character/mode screen is gone " &
        "and every pointer this feature cached about it is DROPPED (drop " &
        $gModeSkipCleared & "). Nothing stale can be Submitted to. A later " &
        "showing is answered only after a NEW controller .ctor."

proc modeSkipDrainTick() =
  ## Rides the `EFT.TarkovApplication::Update` drain (slot alias, no second
  ## detour). Cheap when idle: two integer compares.
  if gModeSkipOff or not gModeSkipOn:
    return
  modeSkipMenuTick()
  modeSkipPressReadback()
  inc gModeSkipTicks

  # ---- SHOWING BOOKKEEPING, AND THE ONE-TICK DEFERRAL ---------------------
  #
  # MEASURED 2026-09-02, and this is the third rule here because the first two
  # were wrong in opposite directions:
  #
  #   * a MILLISECOND quiet window. `ModeSkipQuietMs` was 0 while its own
  #     comment argued for 500, so Submit went out on the first drain tick after
  #     the matching slot -- sometimes in the SAME millisecond as the burst
  #     (logged `after 0ms`), which killed the client inside
  #     `SeasonWidgetData::From` under the first `MenuScreen::Show`, and
  #     sometimes one or two ticks later (logged `after 15-31ms`), which
  #     survived. A coin flip, decided by tick phase.
  #   * answering SHOWING 2. There IS no showing 2: a run on the build that
  #     tried it logged `SHOWING 1 ... closed on this frame -- 3 ShowSlot
  #     call(s)`, discarded the match, and then sat on the character screen for
  #     over three minutes with no second showing, no Submit and no
  #     MenuScreen::Show. The client does NOT re-show this screen by itself
  #     here; the surviving boots were showing 1 answered a tick or two late.
  #
  # So the rule is showing 1, answered ONE DRAIN TICK after its burst ends, and
  # the tick is the unit because a tick is an OBSERVED FRAME rather than a
  # reading off a clock whose phase decided the outcome:
  #
  #   a tick that saw ShowSlot calls  -> the burst is still OPEN. Extend it and
  #                                      submit NOTHING this tick.
  #   the first tick that saw NONE    -> the burst has ended one full tick ago.
  #                                      Close the showing and let the gate
  #                                      below answer on THIS tick.
  #
  # A burst that spans several ticks therefore extends rather than counting as
  # several showings, which is what "if more ShowSlot calls arrive in that next
  # tick, the burst is still open" means in code.
  if gModeSkipSlotsThisTick > 0:
    gModeSkipBurstSlots = gModeSkipBurstSlots + gModeSkipSlotsThisTick
    gModeSkipSlotsThisTick = 0
    gModeSkipBurstOpen = true
    gModeSkipBurstLastTick = gModeSkipTicks
    return
  if gModeSkipBurstOpen:
    gModeSkipBurstOpen = false
    inc gModeSkipBursts
    let nowB = cNowMs()
    let gap = (if gModeSkipBurstMs == 0'u64: 0'u64 else: nowB - gModeSkipBurstMs)
    gModeSkipBurstMs = nowB
    if gModeSkipBursts == 1:
      gModeSkipBurst1Tick = gModeSkipTicks
    if gModeSkipBursts <= 4:
      okLog "skip mode screen: SHOWING " & $gModeSkipBursts & " of the " &
            "character/mode screen ENDED -- " & $gModeSkipBurstSlots &
            " ShowSlot call(s), and this tick is the first with none, so the " &
            "burst is over" &
            (if gModeSkipBursts == 1: " (the first showing)"
             else: " (" & $int(gap) & "ms after showing " &
                   $(gModeSkipBursts - 1) & ")") &
            ". The counters keep running, so if this client ever DOES produce " &
            "a showing 2 the log will say so."
    gModeSkipBurstSlots = 0
    # A match captured on a showing this host does not answer is DISCARDED
    # rather than left queued: `modeSkipShowSlotFired` returns early while a
    # match is pending, so a stale queued match would BLOCK the showing that IS
    # answered from ever capturing -- a gate that can never open. With
    # ModeSkipAnswerBurst = 1 this cannot trigger today; it is kept because the
    # constant is the thing someone will change.
    if gModeSkipPending and gModeSkipPendingBurst < ModeSkipAnswerBurst:
      gModeSkipPending = false
      gModeSkipPendingPd = nil
      gModeSkipPendingBurst = 0
      info "skip mode screen: the match captured on showing " &
           $gModeSkipBursts & " is DISCARDED, not queued -- this host answers " &
           "showing " & $ModeSkipAnswerBurst & "."

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

  # ---- THE SHOWING GATE ---------------------------------------------------
  #
  # Answer showing `ModeSkipAnswerBurst`, and no earlier one. This is a count of
  # OBSERVED EVENTS -- ShowSlot bursts separated by frames -- not a millisecond
  # threshold, so it cannot be won or lost by which millisecond a drain tick
  # landed in, which is exactly how the crashing run differed from the ones that
  # survived.
  if gModeSkipBursts < ModeSkipAnswerBurst or
     gModeSkipPendingBurst < ModeSkipAnswerBurst:
    if gModeSkipBurst1Tick > 0 and not gModeSkipDeclinedLate and
       gModeSkipTicks - gModeSkipBurst1Tick > ModeSkipDeclineTicks:
      gModeSkipDeclinedLate = true
      gModeSkipPending = false
      warn "skip mode screen: DECLINING. Showing 1 ended " &
           $(gModeSkipTicks - gModeSkipBurst1Tick) & " drain ticks ago and " &
           "the showing this host is configured to answer (" &
           $ModeSkipAnswerBurst & ") never arrived (showings seen: " &
           $gModeSkipBursts & "). NOTHING WAS PRESSED and nothing will be: " &
           "\"the showing has not come\" is NOT the same claim as \"the " &
           "flow is ready\", and pressing on that guess is what faulted " &
           "SeasonWidgetData::From inside MenuScreen::Show on 2026-09-02. " &
           "The stock screen is left exactly as the client built it. This " &
           "branch is unreachable while ModeSkipAnswerBurst is 1, which is " &
           "its shipped value; it exists for whoever changes that constant."
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
  # The epoch BEFORE the press, so the readback compares against the right
  # baseline rather than against whatever the menu did earlier in the session.
  gModeSkipMenuEpoch0 = (if gModeSkipMenuSiteOk: uihEpoch(gModeSkipMenuSite)
                         else: 0)
  gModeSkipReadbackDone = false
  gModeSkipPressPhase = 0
  gModeSkipPressedNode = nil
  # THE TITLE A PERSON READS on the card, so the log names WHICH card was
  # pressed in the words on screen ("PvE Zone" / "PvE") and not only an object
  # name -- on this build the two DISAGREE: `CharacterSlotView_pvp` is the card
  # labelled "PvE".
  block:
    let ctr = iToTransform(gModeSkipPendingView)
    gModeSkipCardTitle = (if ctr != nil and duOk(ctr, 0x20'i32):
                            arLabelUnderName(ctr, "Title", ModeSkipApplyDepth)
                          else: "")

  gModeSkipPressAtTick = gModeSkipTicks
  if cMskSubmitGuarded(cast[Il2CppPtr](0)) == nil:
    inc gModeSkipFaults
    warn "skip mode screen: the guarded Submit faulted (" & $gModeSkipFaults &
         " of " & $ModeSkipMaxFaults & ")"
    if gModeSkipFaults >= ModeSkipMaxFaults:
      gModeSkipOff = true
      warn "skip mode screen: too many faults; switching itself off for this " &
           "session. The selection screen is left for the player to use."
    return
  if not gModeSkipPressedOk:
    warn "skip mode screen: NOTHING WAS PRESSED -- " & gModeSkipPressWhy &
         ". The stock character/mode screen is left exactly as the client " &
         "built it and the player can use it. This host does NOT fall back to " &
         "calling Submit at its RVA: that call is what handed the game's own " &
         "MainMenuShowOperation an unpopulated selection, and the minidump of " &
         "Crash_2026-09-02_131229783 shows the consequence -- " &
         "SeasonWidgetData::From faulting on a Profile argument of INTEGER 1 " &
         "with a NULL SeasonalRewardController."
    return
  okLog "skip mode screen: called CharacterSelectionScreenController::Submit " &
        "@0x13F0BF0 -- RCX=controller 0x" &
        hexOf(cast[uint64](gModeSkipController)) & ", EDX=EGameMode " &
        $gModeSkipArgMode & " (read from the slot view's `_gameMode`@0x160), " &
        "R8=CharacterSelectionProfileData 0x" &
        hexOf(cast[uint64](gModeSkipArgPd)) &
        " (read from `_profileData`@0x178), R9=0 -- for profile " &
        gModeSkipWantId & ", answering showing " & $gModeSkipPendingBurst &
        " on tick +" & $(gModeSkipTicks - gModeSkipBurstLastTick) &
        " after its ShowSlot burst ended. This is the frame a player's click " &
        "produces (OnActionButtonPressed @0x13F61B0 -> Selected(_gameMode, " &
        "_profileData) -> Submit), with BOTH arguments read off the slot view " &
        "rather than taken from the argument registers -- taking them from " &
        "the registers is what put an EGameMode where the Profile goes. " &
        "Submit is ASYNC, so returning proves NOTHING: the readback is " &
        "MenuScreen::Show (uihooks site 2), logged separately."

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
  # PREFIX, and `postfix = false` here is load-bearing. The .ctor takes SIX
  # declared arguments, so its compiled call uses EIGHT register slots (`this`
  # + 6 + MethodInfo*) and four of them arrive on the STACK -- a postfix would
  # make the original read them out of the thunk's own frame. The handler only
  # compares `this` by pointer identity, so entry-time is as good as
  # return-time for it. See `attachDrain`'s postfix gate.
  if not attachDrain("CharacterSelectionScreenController::.ctor", ctorFn,
                     cast[Il2CppMethod](0), false, verbose, 17'i32, false):
    warn "skip mode screen: could not bind the controller .ctor detour; " &
         "nothing else is bound either, because a captured slot with no " &
         "controller cannot be submitted."
    return false
  # PREFIX, same rule: `ShowSlot` takes FOUR declared arguments, so its call
  # uses SIX register slots and two arrive on the stack. Everything this
  # handler reads (RCX/RDX/R8/R9, and the slot view's own fields, which the
  # CALLER populated) is already valid at entry.
  if not attachDrain("EFT.UI.CharacterSelectionScreen::ShowSlot", slotFn,
                     cast[Il2CppMethod](0), false, verbose, 18'i32, false):
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

# ===========================================================================
# F2 -- SKIP THE SCREEN WITH **NO FRAME OF UI**
# ===========================================================================
#
# Everything above this line is F2's predecessor: it lets the character/mode
# screen be BUILT and SHOWN, then presses the slot's own Apply a few frames
# later. It works, and it flashes the screen. This section removes the flash by
# answering the question one level earlier, before the selection controller
# exists at all.
#
# THE HOOK -- `EFT.TarkovApplication::TryCreateInRaidCharacterSelection`
# @0x97bbf0, target [3] in `abi/aowlspt_modeskip.h`, where its full derivation
# lives (STATIC, arity 2, UNIQUE, clean 16-byte relocation window, two callers).
# The boot BRANCHES ON ITS RETURN VALUE: `true` with a filled 24-byte
# `CharacterSelectionResult` means "a character is already chosen", and the
# selection screen is never constructed. `ShowLanguageSelectionIfNeeded(data)`
# @0x97bd20 sits on the bypass side of that branch, so taking the bypass does
# not skip it -- which is why this hooks HERE and not further down.
#
# TWO STAGES, ONE BUILD, TWO INDEPENDENT FLAGS:
#
#   `modeSkipProbe`          READ ONLY, default OFF. On the FIRST firing it
#                            dumps the dictionary in RCX -- header bytes, the
#                            candidate _buckets/_entries/_count, and every
#                            entry's key and value with the value's klass name,
#                            Status and ProfileId. It changes nothing and
#                            always lets the original run.
#
#   `uxSkipModeScreenNative` THE SKIP, default OFF. On the FIRST firing it
#                            looks for the entry whose value passes ALL THREE
#                            runtime self-checks, writes the result exactly as
#                            the original would have for that entry, and
#                            returns true WITHOUT calling the original. If any
#                            check fails it falls through to the original --
#                            the screen shows and the old Submit path (if
#                            `uxSkipModeScreen` is also on) handles it -- and
#                            the log says which check failed and what it read.
#
# WHY THE VALUES CANNOT BE COMPUTED. `data` is the game's own
# `Dictionary<EGameMode, CharacterSelectionProfileData>`; the pair the original
# writes is `(a key of that dictionary, the value stored under it)`. The host
# never constructs either. The 2026-09-02 minidump -- `Rcx=1`, a Profile
# argument that was the integer 1 -- is what computing them costs.
#
# WHY THE CANDIDATE LAYOUT IS NOT A GUESS IN THE DANGEROUS SENSE. The
# instantiated generic layout is not reachable offline (map section 4.3), so
# the offsets in the header ARE a candidate. What makes them safe is that a
# wrong candidate cannot pass the self-check: the value it produces would have
# to have a klass whose full name reads `EFT.CharacterSelectionProfileData`,
# AND a `Status@0x20` of exactly 2, AND a `ProfileId@0x78` equal to
# `launchProfileId`. A readability check alone would prove nothing -- that is
# how a plausible number becomes a crash.
#
# ONE-SHOT, AND WHY. The site has TWO callers (header target [3]): the boot's
# `<RunInitialLobbyFlow>d__121` and the in-menu `switch character`
# `<OpenCharacterSelectionFromMenu>d__118`. Only the boot call may be
# bypassed -- bypassing the in-menu one would make "switch character" silently
# do nothing. This acts on the FIRST call of the session only. REASONED, not
# measured: the boot call necessarily precedes any in-menu switch, because the
# menu does not exist until the boot flow has passed this point.
#
# THE EIGHT RULES: prologue byte-verified against the startup snapshot before
# anything binds; every pointer hop VirtualQuery-guarded in C; ONE
# `aowl_p_p_seh` around the whole body and no nested guard; every loop capped
# at `AOWL_MSK_ENT_MAX`; both flags default OFF; self-disables after
# `ModeSkipMaxFaults` faults; no managed allocation anywhere (this path runs
# ONCE per session, not per frame); and the single write is read-validate-write
# with an explicit writability query.

proc cMskKlassNameOf(obj: Il2CppPtr; outBuf: cstring; cap: int32): int32 {.
  importc: "aowl_msk_klass_name_of", nodecl.}
proc cMskHexdump(p: Il2CppPtr; n: int32; outBuf: cstring; cap: int32): int32 {.
  importc: "aowl_msk_hexdump", nodecl.}
proc cMskArrData(a: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_msk_arr_data", nodecl.}
proc cMskArrLen(a: Il2CppPtr): int64 {.
  importc: "aowl_msk_arr_len", nodecl.}
proc cMskEntry(data: Il2CppPtr; i: int32; key: var int32;
               value: var Il2CppPtr): int32 {.
  importc: "aowl_msk_entry", nodecl.}
proc cMskResultWrite(res: Il2CppPtr; gameMode: int32; pd: Il2CppPtr): int32 {.
  importc: "aowl_msk_result_write", nodecl.}
proc cMskTcSetRet(p: Il2CppPtr; v: uint64) {.
  importc: "aowl_regs_set_ret_int", nodecl.}

const
  MskTTryCreate = 3'i32 ## EFT.TarkovApplication::TryCreateInRaidCharacterSelection
  MskDictBucketsOff = 0x10'i32
  MskDictEntriesOff = 0x18'i32
  MskDictCountOff   = 0x20'i32
  MskEntMax = 16'i32
    ## Mirrors `AOWL_MSK_ENT_MAX`. A corrupt `_count` cannot become an
    ## unbounded loop inside a frame; a walk that stops AT the cap says so, so
    ## a truncation can never read as an absence.
  MskF2MaxFaults = 3
    ## Same shape and reason as `ModeSkipMaxFaults`. In practice this path runs
    ## once per session, so reaching 3 would mean something is badly wrong.

var gMskTcCalls = 0                     ## firings of the site, this session
var gMskTcOff = false                   ## self-disabled after faults
var gMskTcFaults = 0
var gMskTcProbed = false                ## the dump has been printed once
var gMskTcSuppressed = false            ## the bypass was taken
var gMskTcData: Il2CppPtr = nil         ## RCX, parked for the guarded body
var gMskTcRes: Il2CppPtr = nil          ## RDX, ditto
var gMskTcWantSkip = false              ## body -> caller: suppress the original
var gMskTcSkipMode: int32 = 0           ## the key that was chosen
var gMskTcSkipPd: Il2CppPtr = nil       ## the value stored under it
var gMskTcWhy = ""                      ## why the skip was declined
var gMskTcBoundLogged = false
## Scratch, MODULE level for the same reason `gModeSkipIdBuf` is: Nimony cannot
## prove a local array initialised before it is handed to C, and these are only
## ever touched from the ONE guarded body on Unity's thread.
var gMskTcKlassBuf: array[404, char]
var gMskTcDumpBuf: array[416, char]
var gMskTcIdBuf: array[264, char]

{.emit: """
extern void* aowl_msk_tc_body(void* a);
static void* aowl_msk_tc_guarded(void* a) {
    return aowl_p_p_seh((void*)aowl_msk_tc_body, a);
}
""".}
proc cMskTcGuarded(a: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_msk_tc_guarded", nodecl.}

proc mskTcKlassOf(p: Il2CppPtr): string =
  ## The klass full name of `p`, or the INCONCLUSIVE marker. Never asserts
  ## "not that type" from an unreadable name.
  if cMskKlassNameOf(p, cast[cstring](addr gMskTcKlassBuf[0]), 404'i32) == 0'i32:
    return "<no klass name readable -- INCONCLUSIVE>"
  return $cast[cstring](addr gMskTcKlassBuf[0])

proc modeSkipTryCreateBody(a: Il2CppPtr): Il2CppPtr {.
    exportc: "aowl_msk_tc_body", cdecl.} =
  ## THE WHOLE BODY, under the ONE guard installed by `aowl_msk_tc_guarded`.
  ## Nothing in here opens a second guard: `aowl_p_p_seh` is not re-entrant and
  ## a nested region would DISARM this one.
  ##
  ## `a` is unused; the inputs are `gMskTcData` / `gMskTcRes`, parked by the
  ## caller immediately before the guarded call, exactly as `modeSkipSlotBody`
  ## takes its inputs.
  result = cast[Il2CppPtr](1)
  gMskTcWantSkip = false
  gMskTcSkipPd = nil
  gMskTcSkipMode = 0
  let data = gMskTcData
  let res = gMskTcRes
  if data == nil:
    gMskTcWhy = "the `data` argument in RCX was NULL, so there is no " &
                "dictionary to read. The original decides (it fails the same " &
                "way) and the screen appears."
    return

  # ---- stage (a): the read-only census -----------------------------------
  let buckets = cMskReadPtr(data, MskDictBucketsOff)
  let entries = cMskReadPtr(data, MskDictEntriesOff)
  let count = cMskReadI32(data, MskDictCountOff)
  let entData = cMskArrData(entries)
  let entLen = cMskArrLen(entries)

  let doProbe = gModeSkipProbeOn and not gMskTcProbed
  if doProbe:
    gMskTcProbed = true
    let dumped = cMskHexdump(data, 128'i32,
                             cast[cstring](addr gMskTcDumpBuf[0]), 416'i32)
    info "modeSkipProbe: TryCreateInRaidCharacterSelection @0x97BBF0 fired " &
         "(call " & $gMskTcCalls & "). RCX data=0x" &
         hexOf(cast[uint64](data)) & " klass=`" & mskTcKlassOf(data) &
         "`, RDX result buffer=0x" & hexOf(cast[uint64](res)) &
         ". Header " & (if dumped < 0: "UNREADABLE" else: $dumped &
         " bytes: " & $cast[cstring](addr gMskTcDumpBuf[0]))
    info "modeSkipProbe: CANDIDATE Dictionary<EGameMode," &
         "CharacterSelectionProfileData> layout (NOT measured -- the " &
         "instantiated generic layout is not reachable offline; this is the " &
         "shape IL2CPP compiles CoreCLR's Dictionary into, and the entry " &
         "walk below is what CONFIRMS or REFUTES it): _buckets@0x10=0x" &
         hexOf(cast[uint64](buckets)) & " klass=`" & mskTcKlassOf(buckets) &
         "`, _entries@0x18=0x" & hexOf(cast[uint64](entries)) & " klass=`" &
         mskTcKlassOf(entries) & "` max_length=" & $entLen &
         " data=0x" & hexOf(cast[uint64](entData)) & ", _count@0x20=" & $count
    info "modeSkipProbe: CharacterSelectionResult is 24 bytes and the " &
         "original writes exactly three fields into the caller's out-param " &
         "(MEASURED, `R disasm 0x97bbf0 --to 0x97bd20`): GameMode dword@0x00 " &
         "= the dictionary KEY, ProfileData qword@0x08 = the VALUE stored " &
         "under it, Cancelled byte@0x10 = 0, followed by GC write barriers " &
         "for the two managed slots, then `return true`. The failure path " &
         "zeroes all 24 bytes and returns false."

  if entData == nil or entLen <= 0:
    gMskTcWhy = "the candidate `_entries`@0x18 (0x" &
                hexOf(cast[uint64](entries)) & ") did not read back as an " &
                "array (max_length=" & $entLen & "). The CANDIDATE dictionary " &
                "layout is therefore REFUTED on this build, not confirmed. " &
                "Nothing was written; the original runs and the screen appears."
    return

  # How many entries to examine: `_count` if it is sane, else the array length,
  # and never more than the cap. A walk that stops AT the cap says so below.
  var n = count
  if n <= 0 or int64(n) > entLen:
    n = int32(entLen)
  var capped = false
  if n > MskEntMax:
    n = MskEntMax
    capped = true

  var chosenMode: int32 = 0
  var chosenPd: Il2CppPtr = nil
  var idMatches = 0
  var i: int32 = 0
  while i < n:
    var key: int32 = 0
    var value: Il2CppPtr = nil
    if cMskEntry(entData, i, key, value) == 0'i32:
      if doProbe:
        info "modeSkipProbe: entry " & $i & " NOT READABLE at stride 0x18 -- " &
             "the candidate entry layout does not hold here"
      inc i
      continue
    let klass = (if value == nil: "<null value>" else: mskTcKlassOf(value))
    let isPd = (if value == nil: 0'i32 else: cMskKlassIsPd(value))
    var status: int32 = -1
    var idStr = "<none>"
    if isPd == 1'i32:
      status = cMskProfileStatus(value)
      let idLen = cMskProfileId(value, cast[cstring](addr gMskTcIdBuf[0]),
                                264'i32)
      if idLen > 0:
        idStr = $cast[cstring](addr gMskTcIdBuf[0])
    if doProbe:
      info "modeSkipProbe: entry " & $i & " key(EGameMode)=" & $key &
           " value=0x" & hexOf(cast[uint64](value)) & " klass=`" & klass &
           "` isCharacterSelectionProfileData=" & $isPd &
           " Status@0x20=" & $status & " (Locked0 Empty1 Available2 InRaid3)" &
           " ProfileId@0x78=" & idStr
    # THE SELF-CHECK, all three parts, in the order that makes a wrong layout
    # cheapest to reject. `isPd == 1` is a POSITIVE name match, never an
    # unreadable name treated as a pass.
    if isPd == 1'i32 and chosenPd == nil and gModeSkipWantLen > 0:
      if cMskProfileIs(value, cast[cstring](addr gModeSkipWantBuf[0])) != 0'i32:
        inc idMatches
        if status == MskStatusAvailable:
          chosenMode = key
          chosenPd = value
    inc i

  if capped:
    info "modeSkipProbe/native: the entry walk STOPPED AT THE CAP of " &
         $MskEntMax & " entries (_count read " & $count & "). That is a " &
         "TRUNCATION, not an absence -- if the profile was not found, this " &
         "line is why."

  # ---- stage (b): the skip ------------------------------------------------
  if not gModeSkipNativeOn:
    gMskTcWhy = "uxSkipModeScreenNative is OFF, so this firing was READ ONLY. " &
                "The original runs and the screen appears."
    return
  if gModeSkipWantLen == 0:
    gMskTcWhy = "`launchProfileId` is absent, so there is no profile to " &
                "match. Nothing was written; the screen appears."
    return
  if chosenPd == nil:
    gMskTcWhy = "no dictionary entry passed all three self-checks. " &
                $idMatches & " entr(y/ies) matched launchProfileId " &
                gModeSkipWantId & " by ProfileId; of those, none also read " &
                "Status@0x20 == 2 (Available). Walked " & $n & " of _count=" &
                $count & " entries. NOTHING WAS WRITTEN and the original " &
                "runs, so the stock character/mode screen appears and the " &
                "ShowSlot/Submit path (uxSkipModeScreen) can still answer it."
    return
  # THE WRITE. Read-validate-write: `aowl_msk_result_write` VirtualQueries the
  # 24 bytes for COMMITTED WRITABLE and refuses a buffer that straddles a
  # region boundary rather than writing half of one.
  if cMskResultWrite(res, chosenMode, chosenPd) == 0'i32:
    gMskTcWhy = "the 24-byte CharacterSelectionResult out-param at 0x" &
                hexOf(cast[uint64](res)) & " is not committed writable " &
                "memory (VirtualQuery refused it). Nothing was written and " &
                "the original runs."
    return
  gMskTcSkipMode = chosenMode
  gMskTcSkipPd = chosenPd
  gMskTcWantSkip = true

proc modeSkipTryCreateFired(regs: Il2CppPtr): int32 =
  ## PREFIX on `EFT.TarkovApplication::TryCreateInRaidCharacterSelection`.
  ##   slot 0  RCX = data   (CharacterSelectionDataResponse, a Dictionary)
  ##   slot 1  RDX = &result (24-byte CharacterSelectionResult out-param)
  ##   slot 2  R8  = MethodInfo* (the caller passes NULL)
  ## STATIC, three register slots, nothing on the caller's stack.
  ##
  ## Returns 1 to SUPPRESS the original -- the only place this host does that
  ## on this site -- and 0 to let it run. It returns 1 only when the guarded
  ## body actually wrote a result built from the game's own dictionary.
  result = 0'i32
  if gMskTcOff:
    return
  if not (gModeSkipProbeOn or gModeSkipNativeOn):
    return
  inc gMskTcCalls
  if gMskTcCalls > 1:
    # THE IN-MENU `switch character` PATH, and it is left alone. Bypassing it
    # would make that button silently do nothing.
    if gMskTcCalls == 2:
      info "modeSkipProbe/native: TryCreateInRaidCharacterSelection fired a " &
           "SECOND time. Only the FIRST call of the session is acted on -- " &
           "the site has two callers (the boot's RunInitialLobbyFlow and the " &
           "in-menu OpenCharacterSelectionFromMenu) and the in-menu switch " &
           "must keep working. This firing was not touched."
    return
  let data = cast[Il2CppPtr](cRegsInt(regs, 0'i32))
  let res = cast[Il2CppPtr](cRegsInt(regs, 1'i32))
  if res == nil:
    warn "modeSkipProbe/native: the out-param pointer in RDX was NULL. " &
         "Nothing read, nothing written; the original runs."
    return
  gMskTcData = data
  gMskTcRes = res
  gMskTcWhy = ""
  if cMskTcGuarded(cast[Il2CppPtr](0)) == nil:
    inc gMskTcFaults
    warn "modeSkipProbe/native: the guarded body faulted (" & $gMskTcFaults &
         " of " & $MskF2MaxFaults & "). The original RUNS -- suppression " &
         "requires a completed write, so a fault can never leave the caller " &
         "with an unfilled result."
    if gMskTcFaults >= MskF2MaxFaults:
      gMskTcOff = true
      warn "modeSkipProbe/native: too many faults; switching itself off for " &
           "this session."
    return
  if not gMskTcWantSkip:
    if gMskTcWhy.len > 0:
      info "modeSkipProbe/native: NOT skipping -- " & gMskTcWhy
    return
  # SUPPRESS. RAX = 1 (`true`), and the caller's 24-byte result is already
  # filled with the game's own (key, value) pair.
  cMskTcSetRet(regs, 1'u64)
  gMskTcSuppressed = true
  okLog "skip mode screen NATIVELY (F2): TryCreateInRaidCharacterSelection " &
        "@0x97BBF0 SUPPRESSED and answered true. The out-param at 0x" &
        hexOf(cast[uint64](res)) & " was written GameMode@0x00=" &
        $gMskTcSkipMode & " (the dictionary KEY, not a computed value), " &
        "ProfileData@0x08=0x" & hexOf(cast[uint64](gMskTcSkipPd)) &
        " (the VALUE stored under that key, klass-verified as EFT." &
        "CharacterSelectionProfileData with Status@0x20=2 Available and " &
        "ProfileId@0x78=" & gModeSkipWantId & "), Cancelled@0x10=0. The " &
        "selection controller is never constructed, so there is NO frame of " &
        "the character/mode screen. Returning true proves only that the " &
        "branch was taken: the readback is MenuScreen::Show (uihooks site 2) " &
        "firing with the selection screen's show-site count still at 0."
  return 1'i32

proc bindModeSkipNative(verbose: bool): bool =
  ## Binds the F2 PREFIX. Opt-in twice over: either `modeSkipProbe` or
  ## `uxSkipModeScreenNative` must be on, and the skip half additionally needs
  ## a `launchProfileId`. A build whose prologue does not match binds nothing.
  ##
  ## Nothing else in this host names 0x97BBF0, so there is no double-detour
  ## hazard and no rider alias to take. It is a PREFIX because the whole point
  ## is to decide whether the original runs at all -- and because the method is
  ## static with two declared arguments, i.e. THREE register slots, so
  ## `attachDrain`'s postfix gate is not even in question.
  if not (gModeSkipProbeOn or gModeSkipNativeOn):
    return false
  if gModeSkipTryCreateSlot >= 0:
    return true
  if not gReady or gDisableDrain:
    return false
  if gModeSkipNativeOn and gModeSkipWantId.len == 0:
    warn "uxSkipModeScreenNative is on but `launchProfileId` is absent or " &
         "empty in aowlspt-host.json. There is no profile to select, so the " &
         "skip half can never pass its self-check. Binding anyway ONLY if " &
         "modeSkipProbe is on; otherwise nothing is bound and the screen " &
         "appears as normal."
    if not gModeSkipProbeOn:
      return false
  if gModeSkipWantId.len > 0 and gModeSkipWantLen == 0:
    if not modeSkipSetWantBuf(gModeSkipWantId):
      warn "skip mode screen (native): `launchProfileId` does not fit the " &
           "fixed comparison buffer. REFUSING rather than comparing a " &
           "truncated id, which would match nothing and look like a silent " &
           "no-op. Nothing bound."
      return false
  let fn = cMskFn(MskTTryCreate)
  if fn == nil:
    warn "skip mode screen (native): " &
         "EFT.TarkovApplication::TryCreateInRaidCharacterSelection @0x97BBF0 " &
         "did not verify against the STARTUP PROLOGUE SNAPSHOT on this build " &
         "(" & $int(cMskOkCount()) & " verified, " & $int(cMskBadCount()) &
         " rejected). Nothing bound; the selection screen will appear as " &
         "normal. Expected 48 89 5C 24 10 57 48 83 EC 40 33 FF 48 8B DA 89."
    return false
  if not attachDrain("EFT.TarkovApplication::TryCreateInRaidCharacterSelection",
                     fn, cast[Il2CppMethod](0), false, verbose, 34'i32, false,
                     3'i32):
    warn "skip mode screen (native): the prefix on " &
         "TryCreateInRaidCharacterSelection did not bind. Nothing is skipped " &
         "and the screen appears as normal."
    return false
  if not gMskTcBoundLogged:
    gMskTcBoundLogged = true
    okLog "skip mode screen (F2) ARMED: PREFIX on EFT.TarkovApplication::" &
          "TryCreateInRaidCharacterSelection @0x97BBF0 (slot " &
          $gModeSkipTryCreateSlot & "), probe=" &
          (if gModeSkipProbeOn: "ON" else: "off") & " skip=" &
          (if gModeSkipNativeOn: "ON" else: "off") & ". On the FIRST firing " &
          "only, the game's own Dictionary<EGameMode,CharacterSelection" &
          "ProfileData> in RCX is read; a value that is klass-verified, " &
          "Status==2 Available and whose ProfileId is " &
          (if gModeSkipWantId.len > 0: gModeSkipWantId else: "<unset>") &
          " is written into the 24-byte out-param and the original is " &
          "SUPPRESSED with true. Any failed check falls through to the " &
          "original, which shows the screen, and says which check failed."
  return true
