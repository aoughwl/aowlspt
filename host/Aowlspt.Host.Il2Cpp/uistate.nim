# uistate.nim -- publish the "which blocking UI surface is open" mask.
#
# `include`d into `aowlhost.nim` (NOT imported) so it shares that file's
# logging (`okLog`/`warn`/`info`), `hexOf`, and the SEH guard, and can read
# `gSettingsLiveSelf` (settingsui.nim) and `gDuEdit` directly.
#
# The export, the bit meanings, the two byte-verified getters, and the eight
# rules are all in `abi/aowlspt_uistate.h`. This file is the wiring: the flag,
# the per-tick probe, and the mask publication.
#
# INCLUDED BEFORE cursorfree.nim, on purpose: `cursorFreeHostMask` calls
# `uiStateSettingsOpen()` to fold the game Settings screen into the cursor's own
# level mask, so the cursor is freed while the game's Settings screen is up
# (the reported bug: "when I open settings my mouse is not free").
#
# WHERE IT RUNS
# -------------
# On the `EFT.TarkovApplication::Update` drain, immediately before
# `cursorFreeDrainTick`, so the cursor's host-mask publication this frame sees
# this frame's settings-open state and not last frame's. That drain ticks for
# the whole session, menu and raid alike.

# ---- the export, the getters, the guarded probe (abi/aowlspt_uistate.h) ----
proc cUiPublishMask(mask: uint32) {.importc: "aowl_ui_publish_mask", nodecl.}
proc cUiStSetSelf(p: Il2CppPtr) {.importc: "aowl_ui_st_set_self", nodecl.}
proc cUiSettingsProbeGuarded(a: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_ui_settings_probe_guarded", nodecl.}
proc cUiStLastOpen(): int32 {.importc: "aowl_ui_st_last_open", nodecl.}
proc cUiStVerified(): int32 {.importc: "aowl_ui_st_verified", nodecl.}
proc cUiStRejected(): int32 {.importc: "aowl_ui_st_rejected", nodecl.}
proc cUiStFaults(): int32 {.importc: "aowl_ui_st_faults", nodecl.}
proc cUiStOff(): int32 {.importc: "aowl_ui_st_off", nodecl.}
proc cUiStFault() {.importc: "aowl_ui_st_fault", nodecl.}

# The cursor's live overlay-panel level -- read for the F6/F3 bits so the two
# features cannot drift apart (abi/aowlspt_cursor.h).
proc cCurLiveMaskNow(): uint32 {.importc: "aowl_cur_live_mask_now", nodecl.}

const
  # POSITIONAL INDICES into `aowl_ui_targets` (abi/aowlspt_uistate.h), mirroring
  # the AOWL_UI_T_* #defines the C probe body uses. Annotated with the row each
  # addresses so `tools/idxbind.py` ties them to the C table and a row inserted
  # above one fails the build instead of shifting silently (fact #187).
  UiTGetGo     = 0'i32   ## UnityEngine.Component::get_gameObject
  UiTGetActive = 1'i32   ## UnityEngine.GameObject::get_activeInHierarchy

const
  # Public mask bits, matching abi/aowlspt_uistate.h.
  UiOvlSettings = 0x1'u32
  UiOvlAdmin    = 0x2'u32
  UiOvlDebug    = 0x4'u32
  UiOvlOverlay  = 0x8'u32
  # Cursor panel bits, matching abi/aowlspt_cursor.h.
  CurPOverlay   = 0x1'u32   ## F12 -- the mod-manager / settings panel
  CurPAdmin2    = 0x2'u32
  CurPDebugUi2  = 0x4'u32
  UiMaxFaults   = 3

var gUiStateOn = false          ## flag `overlayStateSignal`; DEFAULT OFF
var gUiSettingsOpen = false     ## the game Settings screen, as of the last tick
var gUiLastMask = 0xFFFFFFFF'u32 ## force a first log
var gUiOffLogged = false

proc uiStateSettingsOpen(): bool =
  ## Read by `cursorfree.nim`. True only when the managed probe verified the
  ## game's SettingsScreen GameObject is active-in-hierarchy this tick; false on
  ## any refusal, so a probe that cannot look never freezes the cursor.
  gUiSettingsOpen

proc uiStateDrainTick() =
  ## Rides the TarkovApplication::Update drain, before cursorFreeDrainTick.
  ## bit1/bit2 are pure reads of the cursor's already-published level -- no game
  ## call. bit0 is the guarded managed probe, gated by `overlayStateSignal`.
  var mask = 0'u32
  let cm = cCurLiveMaskNow()
  if (cm and CurPOverlay) != 0'u32:  mask = mask or UiOvlOverlay
  if (cm and CurPAdmin2) != 0'u32:   mask = mask or UiOvlAdmin
  if (cm and CurPDebugUi2) != 0'u32: mask = mask or UiOvlDebug

  gUiSettingsOpen = false
  if gUiStateOn and cUiStOff() == 0:
    # Hand the probe this session's best-known SettingsScreen `this`; the probe
    # itself decides open/closed from the LIVE activeInHierarchy, never from the
    # pointer being non-null (which only means "was opened once").
    cUiStSetSelf(gSettingsLiveSelf)
    if cUiSettingsProbeGuarded(cast[Il2CppPtr](0)) == nil:
      # The SEH guard caught a fault inside the probe.
      cUiStFault()
      warn "overlay state: the settings-open probe faulted (" &
           $cUiStFaults() & " of " & $UiMaxFaults & ")"
      if cUiStOff() != 0 and not gUiOffLogged:
        gUiOffLogged = true
        warn "overlay state: too many faults; the game-Settings bit (bit0) is " &
             "now permanently 0 for this session. bit1/bit2 are unaffected."
    else:
      let open = cUiStLastOpen()   # 1 open, 0 closed, -1 inconclusive
      if open == 1:
        gUiSettingsOpen = true
        mask = mask or UiOvlSettings

  cUiPublishMask(mask)

  # TRANSITIONS ONLY -- nothing allocates unless the mask changed.
  if mask != gUiLastMask:
    gUiLastMask = mask
    info "overlay state: aowl_ui_overlay_mask -> 0x" & hexOf(uint64(mask)) &
         " (settings=" & (if (mask and UiOvlSettings) != 0'u32: "1" else: "0") &
         " admin=" & (if (mask and UiOvlAdmin) != 0'u32: "1" else: "0") &
         " debug=" & (if (mask and UiOvlDebug) != 0'u32: "1" else: "0") &
         " overlay=" & (if (mask and UiOvlOverlay) != 0'u32: "1" else: "0") & ")" &
         (if gUiStateOn: "" else: " [overlayStateSignal OFF: bit0 forced 0]")
