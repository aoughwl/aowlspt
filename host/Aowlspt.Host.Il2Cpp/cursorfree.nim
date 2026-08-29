# cursorfree.nim -- free the mouse while an aowlspt overlay panel is open.
#
# `include`d into `aowlhost.nim` (NOT imported) so it shares that file's
# logging (`okLog`/`warn`/`info`), `cNowMs`, and the VEH/SEH guard.
#
# The mechanism, the four RVAs, why the OS route (ClipCursor/ShowCursor) cannot
# work, why the ref count is a level and not a counter, and the eight rules are
# all in `abi/aowlspt_cursor.h`. This file is the wiring: the flag, the host's
# own publication, the drain tick, the cross-module export, and the diag line.
#
# WHERE IT RUNS, AND WHY NOT THE OBVIOUS PLACE
# --------------------------------------------
# `EFT.TarkovApplication::Update` -- the host's validated main-thread bridge
# (RVA 0x977B10) -- as an ALIAS on the slot the bridge already claimed, exactly
# like `modeSkipDrainTick` beside it. NO SECOND DETOUR: a second detour on one
# function overwrites the first's trampoline and silently kills it.
#
# `PreloaderUI::Update` is the rider most features here use and it is the WRONG
# one for this feature: it ticks only in the menu. That is documented in
# `abi/aowlspt_region.h` and is why the live inspector carries its own
# `gInspSlot2` alias onto this same drain. A raid is the entire point of this
# feature, so it rides the drain that ticks in one.
#
# AND, IN A RAID, THE RENDER DRAIN TOO. The update-drain tick frees and holds at
# the PREFIX of `TarkovApplication::Update`, which runs BEFORE the client's own
# Update-time cursor re-lock each frame -- so in a raid it lost the per-frame
# race (measured: reasserts climbed every tick while `current` stayed
# Locked/hidden). `cursorFreeRenderReassert` (below) re-applies None/visible from
# the RENDER drain (OnRenderObject/OnPostRender), the last main-thread point in
# the frame, which runs AFTER the re-lock and therefore wins. It only re-applies;
# the state machine stays on the update drain.
#
# THE MOUSELOOK DECISION -- deliberately NOT suppressed
# -----------------------------------------------------
# A freed cursor that still turns the player is arguably worse than the current
# behaviour, so this is a real question and it is being answered explicitly
# rather than by omission.
#
# Mouselook is NOT suppressed, for two reasons and one admission.
#
#   1. Suppressing it means DETOURING the look-input path (a `MouseLookControl`
#      / `Update` on the player), and this host's own rule is that detouring a
#      by-name-resolved address is a write with unbounded blast radius: 28.3% of
#      by-name lookups land on a SHARED RVA, and a shared detour fires for every
#      method that shares it. That is not a cost worth paying on a first
#      landing, and it is not a cost worth paying at all until somebody has
#      established that it is NEEDED.
#   2. It is not established that it IS needed. `Cursor.lockState = None` may
#      well be what Tarkov's own look code gates on -- the game unlocks the
#      cursor whenever it opens a menu, and the view does not spin while a menu
#      is open -- in which case freeing the cursor already stops mouselook and a
#      detour would be a second mechanism doing nothing.
#
# THE ADMISSION: I could not settle (2) empirically, because this change was
# made without permission to start the client. So it is recorded as OPEN, not
# as decided. THE INSTRUMENT THAT SETTLES IT, in one look: enter a raid, press
# F12, move the mouse, and watch whether the view turns. If it does, the follow-
# up is a suppression, and the right shape for it is almost certainly NOT a new
# detour -- it is to ride a rider that already exists.
#
# Until then the failure mode is the mild one: the panel is clickable (the bug
# the player reported is fixed) and the view may drift while they click. The
# alternative failure mode -- a detour on the player's input path going wrong in
# a raid -- is the severe one.

# ---- the verified targets, the pure decision, the tick body ----
# (abi/aowlspt_cursor.h, emitted from aowlhost.nim)
proc cCurTargetCount(): int32 {.importc: "aowl_cur_target_count", nodecl.}
proc cCurOkCount(): int32 {.importc: "aowl_cur_ok_count", nodecl.}
proc cCurBadCount(): int32 {.importc: "aowl_cur_bad_count", nodecl.}
proc cCurBaseOk(): int32 {.importc: "aowl_cur_base_ok", nodecl.}
proc cCurName(i: int32): cstring {.importc: "aowl_cur_name", nodecl.}
proc cCurRva(i: int32): uint32 {.importc: "aowl_cur_rva", nodecl.}
proc cCurFn(i: int32): Il2CppPtr {.importc: "aowl_cur_fn", nodecl.}

proc cCurPublishHost(mask: uint32; nowMs: uint64) {.
  importc: "aowl_cur_publish_host", nodecl.}

proc cCurStPanels(): int32 {.importc: "aowl_cur_st_panels", nodecl.}
proc cCurStMask(): int32 {.importc: "aowl_cur_st_mask", nodecl.}
proc cCurStHaveSaved(): int32 {.importc: "aowl_cur_st_have_saved", nodecl.}
proc cCurStSavedLock(): int32 {.importc: "aowl_cur_st_saved_lock", nodecl.}
proc cCurStSavedVis(): int32 {.importc: "aowl_cur_st_saved_vis", nodecl.}
proc cCurStOff(): int32 {.importc: "aowl_cur_st_off", nodecl.}
proc cCurStFaults(): int32 {.importc: "aowl_cur_st_faults", nodecl.}
proc cCurStFrees(): int64 {.importc: "aowl_cur_st_frees", nodecl.}
proc cCurStRestores(): int64 {.importc: "aowl_cur_st_restores", nodecl.}
proc cCurStReasserts(): int64 {.importc: "aowl_cur_st_reasserts", nodecl.}
proc cCurStTicks(): int64 {.importc: "aowl_cur_st_ticks", nodecl.}
proc cCurStEnable(on: int32) {.importc: "aowl_cur_st_enable", nodecl.}
proc cCurAct(): int32 {.importc: "aowl_cur_act", nodecl.}
proc cCurCurLock(): int32 {.importc: "aowl_cur_cur_lock", nodecl.}
proc cCurCurVis(): int32 {.importc: "aowl_cur_cur_vis", nodecl.}
proc cCurReadback(): int32 {.importc: "aowl_cur_readback", nodecl.}

const
  # POSITIONAL INDICES into `aowl_cur_targets` (abi/aowlspt_cursor.h). Each one
  # is annotated with the row it means, which is what `tools/idxbind.py` checks:
  # an index that is merely IN RANGE but points at the wrong row is fact #187 --
  # a byte-verified, non-shared, perfectly valid function of the wrong shape.
  CurTGetVis  = 0'i32            ## UnityEngine.Cursor::get_visible
  CurTSetVis  = 1'i32            ## UnityEngine.Cursor::set_visible
  CurTGetLock = 2'i32            ## UnityEngine.Cursor::get_lockState
  CurTSetLock = 3'i32            ## UnityEngine.Cursor::set_lockState

  CurPDebugUi = 0x4'u32          ## F3  -- the widget layout editor
  CurPSettings = 0x8'u32         ## the GAME's own Settings screen (uistate.nim)
  CurActFree    = 1'i32
  CurActHold    = 2'i32
  CurActRestore = 3'i32
  CurMaxFaults  = 3
    ## Matches AOWL_CUR_MAX_FAULTS. Three, not one: a single fault during a
    ## scene change is worth surviving, a pattern of them is not.
  CurDiagEveryMs = 5000'u64
    ## While a panel is open, restate the state at most this often, so a stuck
    ## cursor NAMES ITSELF in the log instead of being a mystery. Nothing is
    ## logged at all while nothing is open.

# ---------------------------------------------------------------------------
# THE GUARD AND THE CROSS-MODULE EXPORT
# ---------------------------------------------------------------------------
#
# `aowl_p_p_seh` is NOT re-entrant: this is the ONE guard for the whole body and
# nothing inside `aowl_cur_tick_body` adds a nested one, because a nested guard
# DISARMS the outer one.
#
# `aowl_cursor_panels_x` is how the overlay -- which is a SEPARATE DLL
# (`host/Aowlspt.Overlay`) -- declares which of its panels are open. It resolves
# this by `GetProcAddress` on `aowlspt-host-il2cpp.dll`, exactly as it already
# does for `aowl_region_commands_x`; a host too old to export it is a clean
# "nothing published", never a load failure. The call is a pair of interlocked
# stores and nothing else -- it runs on the RENDER thread, and every managed
# call in this feature happens on Unity's main thread instead.

{.emit: """
extern void* aowl_cur_tick_body(void* a);
static void* aowl_cur_tick_guarded(void* a) {
    return aowl_p_p_seh((void*)aowl_cur_tick_body, a);
}
__declspec(dllexport) int32_t aowl_cursor_panels_x(int32_t mask) {
    aowl_cursor_panels(mask, (uint32_t)GetTickCount64());
    return 1;
}
/* THE RENDER-PHASE RE-CLOBBER. In a RAID the client re-locks the cursor
 * (lockState=Locked, visible=false) every frame from inside its Update-time
 * input path, which runs LATER in the frame than the update-drain tick (the
 * prefix of EFT.TarkovApplication::Update) -- so that tick's HOLD lost the race:
 * measured in-raid, reasserts climbed every tick while `current` stayed
 * Locked/hidden and the mouse could not move. This body re-applies None/visible
 * from the RENDER drain (OnRenderObject / OnPostRender), which Unity runs at the
 * END of the frame on the main thread, AFTER the game's re-lock -- so the cursor
 * the overlay is drawn over (at Present) is free.
 *
 * It does ONE thing. FREE (the save of the game's real state) and RESTORE (on
 * close) and the whole state machine stay with the update-drain tick; this only
 * fires while that tick is already holding (haveSaved), never saves, never
 * restores, and touches only the `reasserts` counter. READ BEFORE WRITE, and a
 * getter that refused (returns <0, meaning it did not verify against the startup
 * snapshot) makes this skip rather than blind-write. It is defined here rather
 * than in the ABI header so a fix stays a 48s host rebuild, and it references
 * `g_cur` and the file-static helpers because this emit is in the SAME
 * translation unit that #included aowlspt_cursor.h. */
void* aowl_cur_reassert_body(void* a) {
    int32_t curLock, curVis;
    (void)a;
    if (!g_cur.haveSaved || !g_cur.enabled || g_cur.off) return (void*)1;
    if (aowl_cur_live_mask(&g_cur, (uint64_t)GetTickCount64()) == 0)
        return (void*)1;               /* panel closed; the update tick restores */
    curLock = aowl_cur_get_lock();
    curVis  = aowl_cur_get_vis();
    if (curLock < 0 || curVis < 0) return (void*)1;   /* getter refused */
    if (curLock != AOWL_CUR_LOCK_NONE || curVis == 0) {
        if (aowl_cur_set_lock(AOWL_CUR_LOCK_NONE) && aowl_cur_set_vis(1)) {
            aowl_cur_did_hold(&g_cur);
            aowl_cur_last_lock = AOWL_CUR_LOCK_NONE;
            aowl_cur_last_vis  = 1;
        } else {
            aowl_cur_last_lock = curLock;
            aowl_cur_last_vis  = curVis;
        }
    } else {
        aowl_cur_last_lock = curLock;   /* already None/visible: nothing to do */
        aowl_cur_last_vis  = curVis;
    }
    return (void*)1;
}
static void* aowl_cur_reassert_guarded(void* a) {
    return aowl_p_p_seh((void*)aowl_cur_reassert_body, a);
}
""".}
proc cCurTickGuarded(a: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_cur_tick_guarded", nodecl.}
proc cCurReassertGuarded(a: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_cur_reassert_guarded", nodecl.}

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

var gCursorFreeOn = false          ## the flag; DEFAULT OFF
var gCursorFreeOff = false         ## self-disabled after faults
var gCursorFreeFaults = 0
var gCursorFreeLastAct = -1
var gCursorFreeLastDiagMs = 0'u64
var gCursorFreeArmLogged = false
var gCursorFreeBooted = false

## Forward-declared: the verify runs on the FIRST DRAIN TICK (see below), so the
## tick names it before this file defines it.
proc cursorFreeBoot()

proc curLockName(v: int32): string =
  ## `CursorLockMode`, from `il2cpp_resolve.py enum CursorLockMode`.
  case v
  of 0: "None"
  of 1: "Locked"
  of 2: "Confined"
  of -1: "UNREADABLE"
  else: "?" & $v

proc curStateStr(lock, vis: int32): string =
  curLockName(lock) & "/" &
    (if vis < 0: "vis=UNREADABLE"
     elif vis == 0: "hidden" else: "visible")

# ---------------------------------------------------------------------------
# THE HOST'S OWN PUBLICATION
# ---------------------------------------------------------------------------

proc cursorFreeHostMask(): uint32 =
  ## Which panels THIS module is showing. Today that is the F3 debug overlay's
  ## LAYOUT EDIT mode and only that: the F3 info panel itself is read-only text
  ## that nothing points at, and taking the cursor away from a player who is
  ## merely reading their coordinates would be a regression, not a feature.
  ##
  ## Republished EVERY tick, including as 0 -- that is what makes the claim a
  ## level rather than an edge, and it is why this module going quiet releases
  ## the cursor by itself.
  result = 0'u32
  if gDuEdit: result = result or CurPDebugUi
  # The GAME's own Settings screen, when the `overlayStateSignal` probe has
  # confirmed it is active-in-hierarchy this tick (uistate.nim, included just
  # before this file). This is what frees the cursor for the reported bug --
  # "when I open settings my mouse is not free" -- and it is a LEVEL, republished
  # every tick, so it releases itself the moment the screen closes.
  if uiStateSettingsOpen(): result = result or CurPSettings

# ---------------------------------------------------------------------------
# THE TICK
# ---------------------------------------------------------------------------

proc cursorFreeDrainTick() =
  ## Rides the `EFT.TarkovApplication::Update` drain (slot alias, no second
  ## detour). Cheap when idle: the guarded body's fast path is two integer
  ## compares and makes NO call into the game at all when nothing is open and
  ## nothing is held.
  if gCursorFreeOff:
    return
  # THE VERIFY HAPPENS HERE, not in the flag pass. That pass runs before il2cpp
  # is attached, where `GameAssembly.dll` may not be loaded and the prologue
  # snapshot may not be primed -- verifying there would reject four correct RVAs
  # and blame the game build. One latch, one pass, on the first tick.
  if not gCursorFreeBooted:
    gCursorFreeBooted = true
    cursorFreeBoot()
  let now = cNowMs()
  # The host's own source, ALWAYS, even when the feature is disabled -- the
  # publication is just a level and the decision is what the flag gates. This
  # runs before the body so the body sees this frame's value, not last frame's.
  cCurPublishHost(cursorFreeHostMask(), now)

  if cCurTickGuarded(cast[Il2CppPtr](0)) == nil:
    inc gCursorFreeFaults
    warn "overlay cursor: the guarded tick faulted (" & $gCursorFreeFaults &
         " of " & $CurMaxFaults & ")"
    if gCursorFreeFaults >= CurMaxFaults:
      gCursorFreeOff = true
      # The body's own decision path restores on the way out, but it just
      # faulted, so it cannot be relied on to have done so. Disable the feature
      # in the C state and give the tick ONE more chance to unwind: leaving a
      # player with a freed cursor in a firefight is the worst thing this
      # feature could do, and it must not be the thing it does when it gives up.
      cCurStEnable(0)
      discard cCurTickGuarded(cast[Il2CppPtr](0))
      warn "overlay cursor: too many faults; switching itself off for this " &
           "session. A final restore pass was attempted -- the line below " &
           "says whether the cursor state came back."
      warn "overlay cursor: final state " &
           curStateStr(cCurCurLock(), cCurCurVis()) &
           ", saved was " & curStateStr(cCurStSavedLock(), cCurStSavedVis()) &
           ", stillHoldingSaved=" & $cCurStHaveSaved()
    return

  if not gCursorFreeOn:
    return

  # ---- TRANSITIONS ONLY. Nothing here allocates unless something changed. ----
  let act = cCurAct()
  if act != gCursorFreeLastAct and act != CurActHold:
    gCursorFreeLastAct = act
    if act == CurActFree:
      okLog "overlay cursor: a panel opened -- SAVED the game's own cursor " &
            "state (" & curStateStr(cCurStSavedLock(), cCurStSavedVis()) &
            ") and freed the cursor; panels=" & $cCurStPanels() &
            " mask=0x" & hexOf(uint64(cCurStMask()))
      gCursorFreeLastDiagMs = now
    elif act == CurActRestore:
      # THE FALSIFIABLE ASSERTION, and it is made against the CAPTURED value
      # rather than against a constant: `Locked` would have been wrong for the
      # common case (a panel opened from inside a game menu, which is how this
      # works today by accident). Three outcomes, never two.
      let rb = cCurReadback()
      let verdict =
        if rb == 1: "PASS"
        elif rb == 0: "FAIL"
        else: "INCONCLUSIVE (the getters refused; nothing was read back)"
      let line = "overlay cursor: the last panel closed -- restored " &
                 curStateStr(cCurStSavedLock(), cCurStSavedVis()) &
                 "; read back " & curStateStr(cCurCurLock(), cCurCurVis()) &
                 " -> " & verdict & ". reasserts=" & $cCurStReasserts() &
                 " frees=" & $cCurStFrees() & " restores=" & $cCurStRestores()
      if rb == 1: okLog line else: warn line

  # ---- THE PERIODIC DIAG, while a panel is open ----------------------------
  #
  # A stuck cursor must name itself. This states the SAVED state, the CURRENT
  # state and the open-panel count -- the three things somebody debugging a
  # stuck cursor would otherwise have to guess -- and it says how many times the
  # client has put the lock back behind us, which is the measured answer to
  # "does the game fight us" rather than an assumption in a comment.
  if cCurStHaveSaved() != 0 and now - gCursorFreeLastDiagMs >= CurDiagEveryMs:
    gCursorFreeLastDiagMs = now
    info "overlay cursor: panels=" & $cCurStPanels() &
         " mask=0x" & hexOf(uint64(cCurStMask())) &
         " saved=" & curStateStr(cCurStSavedLock(), cCurStSavedVis()) &
         " current=" & curStateStr(cCurCurLock(), cCurCurVis()) &
         " reasserts=" & $cCurStReasserts() & "/" & $cCurStTicks() &
         " (reasserts~=ticks means the client re-asserts the lock every " &
         "frame and the per-tick hold is what makes this work; 0 means a " &
         "one-shot set survives)"

proc cursorFreeRenderReassert() =
  ## THE RENDER-PHASE RE-CLOBBER, riding the render drain (OnRenderObject /
  ## OnPostRender) -- end of frame, on Unity's main thread, AFTER the game's
  ## Update-time cursor re-lock. The update-drain tick runs at the PREFIX of
  ## `EFT.TarkovApplication::Update`, BEFORE the game re-locks each frame, so in a
  ## raid its HOLD lost the race: measured, reasserts climbed every tick while
  ## `current` stayed Locked/hidden. This runs late enough to win, so `current`
  ## reads None/visible -- the falsifiable check the fix is judged on.
  ##
  ## Re-applies ONLY: FREE, RESTORE and the state machine stay with the update
  ## tick, and this fires only while that tick is already holding (haveSaved). It
  ## opens its OWN single `aowl_p_p_seh`, never nested: `patchFired`'s render
  ## branch is not itself guarded, exactly like the update branch that already
  ## calls `cursorFreeDrainTick`. Idle cost when nothing is freed is one integer
  ## compare and NO call into the game.
  if not gCursorFreeOn or gCursorFreeOff: return
  if cCurStHaveSaved() == 0: return
  if cCurReassertGuarded(cast[Il2CppPtr](0)) == nil:
    inc gCursorFreeFaults
    warn "overlay cursor: the render-phase reassert faulted (" &
         $gCursorFreeFaults & " of " & $CurMaxFaults & ")"
    if gCursorFreeFaults >= CurMaxFaults:
      gCursorFreeOff = true
      cCurStEnable(0)
      warn "overlay cursor: too many faults (render reassert); switching itself " &
           "off for this session. This is a REFUSAL, not a success."

# ---------------------------------------------------------------------------
# Boot
# ---------------------------------------------------------------------------

proc cursorFreeBoot() =
  ## Called once from the host's flag pass. Verifies all four targets against
  ## the STARTUP PROLOGUE SNAPSHOT before anything is armed, and says plainly
  ## what it found -- a feature that declines silently is this host's recurring
  ## failure mode.
  if not gCursorFreeOn:
    return
  var ok = 0
  var bad = 0
  # Named by their positional constants rather than by a bare `0 ..< count`
  # sweep, so that `tools/idxbind.py` has something to bind: a row inserted into
  # the C table would shift these and the build gate says so.
  for i in [CurTGetVis, CurTSetVis, CurTGetLock, CurTSetLock]:
    if cCurFn(i) == nil:
      inc bad
      warn "overlay cursor: " & $cCurName(i) & " @0x" &
           hexOf(uint64(cCurRva(i))) &
           " did NOT verify against the startup prologue snapshot"
    else:
      inc ok
  if bad > 0 or ok < int(cCurTargetCount()):
    gCursorFreeOn = false
    cCurStEnable(0)
    warn "overlay cursor: " & $ok & " of " & $cCurTargetCount() &
         " UnityEngine.Cursor targets verified (" & $bad & " rejected" &
         (if cCurBaseOk() == 0: ", and GameAssembly.dll was not found"
          else: "") & "). REFUSING to arm: this feature writes cursor state " &
         "and it will not write a state it could not first read. The cursor " &
         "behaves exactly as the client left it."
    return
  cCurStEnable(1)
  gCursorFreeArmLogged = true
  okLog "overlay cursor: ARMED on the EFT.TarkovApplication::Update drain " &
        "(no second detour). All " & $ok & " UnityEngine.Cursor targets " &
        "byte-verified against the startup snapshot. While any overlay panel " &
        "is open the cursor is freed and the game's own state is put back " &
        "verbatim when the last one closes."
