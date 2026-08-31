# debugui.nim -- the in-game, UNITY-NATIVE debug overlay: a Minecraft-F3-style
# info panel and in-world markers over AI bots.
#
# `include`d into `aowlhost.nim` (NOT a separate module) so it shares that file's
# guarded raw primitives (`cIsReadable`/`cReadPtrAt`/`cReadI32At`/`cReadF32At`/
# `cUxWritePtr`), its logging (`okLog`/`warn`/`info`), `hexOf`, `cRegsInt`,
# `attachDrain`, the VEH/SEH guard, `gRt`/`newString`, and -- because it is
# included AFTER `botdiag.nim` -- that file's guarded readers and GameWorld
# offsets, which this file reuses verbatim rather than restating.
#
# WHAT IT DRAWS
# -------------
#   debugUi   (F3)  a text panel of live values, one Unity label per line:
#                   FPS, frame count, player position and rotation, map id,
#                   raid state, bot counts (registered / AI / alive), the host
#                   build, and config-driven note slots.
#   debugEsp        one label per registered AI bot, showing role, nickname and
#                   distance, positioned by projecting the bot's world position
#                   to screen space.
#
# Both default OFF. Both are read-only with respect to game state: the ONLY
# writes this file ever performs are into UI objects IT created (clones), never
# into anything the game built.
#
# HOW IT IS DRAWN -- CLONE, NOT CREATE
# ------------------------------------
# See the long note at the top of `abi/aowlspt_debugui.h`. In one line: every
# label is `UnityEngine.Object::Instantiate` of the client's own bottom-left
# version label -- one static call, one reference argument, no `System.Type`, no
# generic `MethodInfo*`, nothing unproven. The clone is re-parented to the canvas
# ROOT with `TMP_DefaultControls::SetParentAndAlign`, positioned by raw-field and
# `RectTransform` setter calls, and its text set by the raw `m_text` + dirty-flag
# write the version brand already proved live.
#
# WHERE IT RUNS
# -------------
# Inside a PREFIX detour on `EFT.UI.PreloaderUI::Update` (kind=10) -- the Unity
# main thread, once a frame, from the preloader through the menu and through a
# raid. That detour's `this` is simultaneously the frame tick AND the clone
# anchor, which is why it was chosen over `TarkovApplication::Update` (which has
# a live crash in its history and hands us no UI object).
#
# The bot data comes from the GameWorld, which PreloaderUI cannot reach -- so a
# second, read-only kind=11 detour on `EFT.GameWorld::RegisterPlayer` caches the
# `this` pointer. It is the SAME target `botDiag` uses, so the two are mutually
# exclusive by arming order; when botdiag is already armed it feeds the cache
# itself and this second detour is not installed at all.
#
# The entire per-frame body runs under ONE `aowl_p_p_seh` VEH/setjmp guard. It is
# one and not several because that guard is NOT re-entrant (a single thread-local
# `jmp_buf`, disarmed on return), so a nested guard would silently break the
# outer one -- the opposite of what it is for.

# ---- the target table, thunks and offsets (abi/aowlspt_debugui.h) ----
proc cDuFn(i: int32): Il2CppPtr {.importc: "aowl_du_fn", nodecl.}
proc cDuName(i: int32): cstring {.importc: "aowl_du_name", nodecl.}
proc cDuRva(i: int32): uint32 {.importc: "aowl_du_rva", nodecl.}
proc cDuTargetCount(): int32 {.importc: "aowl_du_target_count", nodecl.}
proc cDuOkCount(): int32 {.importc: "aowl_du_ok_count", nodecl.}
proc cDuBadCount(): int32 {.importc: "aowl_du_bad_count", nodecl.}
proc cDuPreloaderTarget(): Il2CppPtr {.
  importc: "aowl_du_preloader_update_target", nodecl.}
proc cDuPreloaderRva(): uint32 {.
  importc: "aowl_du_preloader_update_rva", nodecl.}

proc cDuCallPV(fn: Il2CppPtr): Il2CppPtr {.importc: "aowl_du_call_p_v", nodecl.}
proc cDuCallPP(fn, self: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_du_call_p_p", nodecl.}
proc cDuSetVec2(fn, self: Il2CppPtr; x, y: float64) {.
  importc: "aowl_du_call_setvec2", nodecl.}
proc cDuWorldToScreen(fn, cam: Il2CppPtr; wx, wy, wz: float64): int32 {.
  importc: "aowl_du_world_to_screen", nodecl.}
proc cDuScreenX(): float64 {.importc: "aowl_du_screen_x", nodecl.}
proc cDuScreenY(): float64 {.importc: "aowl_du_screen_y", nodecl.}
proc cDuScreenZ(): float64 {.importc: "aowl_du_screen_z", nodecl.}

proc cDuWriteI32(p: Il2CppPtr; off, v: int32): int32 {.
  importc: "aowl_du_write_i32", nodecl.}
proc cDuWriteU8(p: Il2CppPtr; off, v: int32): int32 {.
  importc: "aowl_du_write_u8", nodecl.}
proc cDuWriteF32(p: Il2CppPtr; off: int32; v: float64): int32 {.
  importc: "aowl_du_write_f32", nodecl.}
proc cDuWriteColor(p: Il2CppPtr; off: int32; r, g, b, a: float64): int32 {.
  importc: "aowl_du_write_color", nodecl.}

proc cDuKeyEdge(vk: int32): int32 {.importc: "aowl_du_key_edge", nodecl.}
proc cDuForeground(): int32 {.importc: "aowl_du_foreground", nodecl.}
proc cDuFpsSample() {.importc: "aowl_du_fps_sample", nodecl.}
proc cDuFps(): float64 {.importc: "aowl_du_fps", nodecl.}
proc cDuFrameNo(): int64 {.importc: "aowl_du_frame_no", nodecl.}

proc cDuOffPreVersionLabel(): int32 {.
  importc: "aowl_du_off_pre_versionlabel", nodecl.}
proc cDuOffLocLabels(): int32 {.importc: "aowl_du_off_loc_labels", nodecl.}
proc cDuOffListItems(): int32 {.importc: "aowl_du_off_list_items", nodecl.}
proc cDuOffListSize(): int32 {.importc: "aowl_du_off_list_size", nodecl.}
proc cDuOffArrElems(): int32 {.importc: "aowl_du_off_arr_elems", nodecl.}
proc cDuOffTmpText(): int32 {.importc: "aowl_du_off_tmp_text", nodecl.}
proc cDuOffTmpFontSize(): int32 {.importc: "aowl_du_off_tmp_fontsize", nodecl.}
proc cDuOffTmpFontColor(): int32 {.importc: "aowl_du_off_tmp_fontcolor", nodecl.}
proc cDuOffTmpDirty(): int32 {.importc: "aowl_du_off_tmp_dirty", nodecl.}
proc cDuCallVPB(fn, self: Il2CppPtr; b: int32) {.
  importc: "aowl_du_call_v_pb", nodecl.}
proc cDuOffTmpRect(): int32 {.importc: "aowl_du_off_tmp_rect", nodecl.}
proc cDuOffMcPrevPos(): int32 {.importc: "aowl_du_off_mc_prevpos", nodecl.}
proc cDuOffMcRotation(): int32 {.importc: "aowl_du_off_mc_rotation", nodecl.}
proc cDuOffGwLocationId(): int32 {.importc: "aowl_du_off_gw_locationid", nodecl.}
proc cDuOffTmpGColor(): int32 {.importc: "aowl_du_off_tmp_gcolor", nodecl.}
proc cDuOffTmpGCanvas(): int32 {.importc: "aowl_du_off_tmp_gcanvas", nodecl.}
proc cDuOffTmpAutosize(): int32 {.importc: "aowl_du_off_tmp_autosize", nodecl.}
proc cDuOffTmpHAlign(): int32 {.importc: "aowl_du_off_tmp_halign", nodecl.}
proc cDuOffTmpVAlign(): int32 {.importc: "aowl_du_off_tmp_valign", nodecl.}
proc cDuOffTmpTextAlign(): int32 {.
  importc: "aowl_du_off_tmp_textalign", nodecl.}
proc cDuOffTmpWordWrap(): int32 {.importc: "aowl_du_off_tmp_wordwrap", nodecl.}
proc cDuOffTmpOverflow(): int32 {.importc: "aowl_du_off_tmp_overflow", nodecl.}
proc cDuOffTmpFirstVis(): int32 {.importc: "aowl_du_off_tmp_firstvis", nodecl.}
proc cDuOffTmpMaxVisChars(): int32 {.
  importc: "aowl_du_off_tmp_maxvischars", nodecl.}
proc cDuOffTmpMaxVisWords(): int32 {.
  importc: "aowl_du_off_tmp_maxviswords", nodecl.}
proc cDuOffTmpMaxVisLines(): int32 {.
  importc: "aowl_du_off_tmp_maxvislines", nodecl.}
proc cDuOffTmpPage(): int32 {.importc: "aowl_du_off_tmp_page", nodecl.}
proc cDuOffTmpMargin(): int32 {.importc: "aowl_du_off_tmp_margin", nodecl.}

proc cDuCallUP(fn, self: Il2CppPtr): uint64 {.
  importc: "aowl_du_call_u_p", nodecl.}
proc cDuVec2X(packed: uint64): float64 {.importc: "aowl_du_vec2_x", nodecl.}
proc cDuVec2Y(packed: uint64): float64 {.importc: "aowl_du_vec2_y", nodecl.}
proc cDuCallIP(fn, self: Il2CppPtr): int32 {.
  importc: "aowl_du_call_i_p", nodecl.}
proc cDuCallFP(fn, self: Il2CppPtr): float64 {.
  importc: "aowl_du_call_f_p", nodecl.}
proc cDuCallSretP(fn, self: Il2CppPtr; nfloats: int32): int32 {.
  importc: "aowl_du_call_sret_p", nodecl.}
proc cDuSret0(): float64 {.importc: "aowl_du_sret_0", nodecl.}
proc cDuSret1(): float64 {.importc: "aowl_du_sret_1", nodecl.}
proc cDuSret2(): float64 {.importc: "aowl_du_sret_2", nodecl.}
proc cDuSret3(): float64 {.importc: "aowl_du_sret_3", nodecl.}
proc cDuSetVec3(fn, self: Il2CppPtr; x, y, z: float64) {.
  importc: "aowl_du_call_setvec3", nodecl.}
proc cDuStringLen(s: Il2CppPtr): int32 {.
  importc: "aowl_du_string_len", nodecl.}

# ---------------------------------------------------------------------------
# THE WIDGET LAYER'S NATIVE SURFACE (abi/aowlspt_widget.h)
#
# The pointer, process memory, and a READ-ONLY view of the shared region's
# participant table. Nothing here detours, resolves a name, or touches managed
# memory; see the header's own preamble for why the pointer is polled with
# `GetAsyncKeyState`/`GetCursorPos` rather than hooked, and why that makes the
# WM_KEYDOWN-vs-WM_SYSKEYDOWN classification that broke F10 in the D3D overlay
# structurally inapplicable to F3 here.
# ---------------------------------------------------------------------------
{.emit: """#include "aowlspt_widget.h" """.}

proc cWgMouseSample(): int32 {.importc: "aowl_wg_mouse_sample", nodecl.}
proc cWgMouseOk(): int32 {.importc: "aowl_wg_mouse_ok", nodecl.}
proc cWgMouseX(): int32 {.importc: "aowl_wg_mouse_x", nodecl.}
proc cWgMouseY(): int32 {.importc: "aowl_wg_mouse_y", nodecl.}
proc cWgClientW(): int32 {.importc: "aowl_wg_client_w", nodecl.}
proc cWgClientH(): int32 {.importc: "aowl_wg_client_h", nodecl.}
proc cWgLmbHeld(): int32 {.importc: "aowl_wg_lmb_held", nodecl.}
proc cWgLmbPressed(): int32 {.importc: "aowl_wg_lmb_pressed", nodecl.}
proc cWgLmbReleased(): int32 {.importc: "aowl_wg_lmb_released", nodecl.}
proc cWgCtrlDown(): int32 {.importc: "aowl_wg_ctrl_down", nodecl.}

proc cWgMemSample() {.importc: "aowl_wg_mem_sample", nodecl.}
proc cWgWs(): int64 {.importc: "aowl_wg_ws", nodecl.}
proc cWgPriv(): int64 {.importc: "aowl_wg_priv", nodecl.}
proc cWgSysLoad(): int64 {.importc: "aowl_wg_sysload", nodecl.}
proc cWgSysFree(): int64 {.importc: "aowl_wg_sysfree", nodecl.}

proc cWgRgMax(): int32 {.importc: "aowl_wg_rg_max", nodecl.}
proc cWgRgSelect(h: int32): int32 {.importc: "aowl_wg_rg_select", nodecl.}
proc cWgRgNameC(): cstring {.importc: "aowl_wg_rg_name_of", nodecl.}
proc cWgRgReasonC(): cstring {.importc: "aowl_wg_rg_reason_of", nodecl.}
proc cWgRgBudget(): int64 {.importc: "aowl_wg_rg_budget", nodecl.}
proc cWgRgLast(): int64 {.importc: "aowl_wg_rg_last", nodecl.}
proc cWgRgMaxUs(): int64 {.importc: "aowl_wg_rg_max_us", nodecl.}
proc cWgRgCalls(): int64 {.importc: "aowl_wg_rg_calls", nodecl.}
proc cWgRgSkipped(): int64 {.importc: "aowl_wg_rg_skipped", nodecl.}
proc cWgRgFaults(): int32 {.importc: "aowl_wg_rg_faults", nodecl.}
proc cWgRgOverruns(): int32 {.importc: "aowl_wg_rg_overruns", nodecl.}
proc cWgRgEnabled(): int32 {.importc: "aowl_wg_rg_enabled", nodecl.}
proc cWgRgDisabled(): int32 {.importc: "aowl_wg_rg_disabled", nodecl.}
proc cWgRgThrottled(): int32 {.importc: "aowl_wg_rg_throttled", nodecl.}
proc cWgRgArmed(): int32 {.importc: "aowl_wg_rg_armed", nodecl.}

## THE SUBMITTER SURFACE -- how the widgets are DRAWN.
##
## Screen-space draw commands into the shared region, rasterised by the D3D11
## overlay inside `Present`, exactly as the F12 settings panel and the F6 admin
## HUD already are. No TextMeshPro clone, no Unity canvas, no parenting and no
## sort order -- so there is no longer a state that can be "built successfully"
## and invisible, which is what six rounds of the clone approach ended at.
##
## Coordinates are TRUE BACK-BUFFER PIXELS, origin TOP-LEFT. `wgeom.nim` works
## in Unity's Y-UP canvas units and is deliberately unchanged; the one flip
## lives in `duPx`.
proc cWgDrFill(x, y, w, h: float32; col: uint32): int32 {.
  importc: "aowl_wg_dr_fill", nodecl.}
proc cWgDrBox(x, y, w, h, t: float32; col: uint32): int32 {.
  importc: "aowl_wg_dr_box", nodecl.}
proc cWgDrText(x, y: float32; s: cstring; col: uint32; scale: int32): int32 {.
  importc: "aowl_wg_dr_text", nodecl.}
proc cWgScrW(): int32 {.importc: "aowl_wg_scr_w", nodecl.}
proc cWgScrH(): int32 {.importc: "aowl_wg_scr_h", nodecl.}
proc cWgScrKnown(): int32 {.importc: "aowl_wg_scr_known", nodecl.}
type AowlRegionCb = proc (user: pointer; frame: int64) {.cdecl.}
proc cWgRgRegister(name: cstring; fn: AowlRegionCb;
                   mask, order, budgetUs: int32): int32 {.
  importc: "aowl_wg_rg_register", nodecl.}
proc cWgRgRefusalTextC(r: int32): cstring {.
  importc: "aowl_wg_rg_refusal_text", nodecl.}
proc cWgRgMaskDraw(): int32 {.importc: "aowl_wg_rg_mask_draw", nodecl.}

## The overlay's font cell, from `AOWL_OV_CW`/`AOWL_OV_CH` in
## `abi/aowlspt_overlay.h`. Fixed 8x16 at scale 1; there is no proportional
## metric to approximate and therefore no `cDuGlyphAspect` guess any more --
## a widget's extent is now EXACT rather than estimated, which is what makes
## the hit box match what is on screen.
const
  cDuCellW = 8.0
  cDuCellH = 16.0
  ## `AOWL_REGION_TEXT_LEN` is 64, so a command carries at most 63 characters.
  ## Lines are TRUNCATED to this and marked, never silently cut: a read-out
  ## that loses its right-hand column without saying so is the failure mode
  ## this whole file exists to avoid.
  cDuCmdText = 63

proc cWgCrumb(stage: int32) {.importc: "aowl_wg_crumb", nodecl.}
proc cWgCrumbW(idx: int32) {.importc: "aowl_wg_crumb_w", nodecl.}
proc cWgCrumbGet(): int32 {.importc: "aowl_wg_crumb_get", nodecl.}
proc cWgCrumbGetW(): int32 {.importc: "aowl_wg_crumb_get_w", nodecl.}
proc cWgCrumbTextC(s: int32): cstring {.importc: "aowl_wg_crumb_text", nodecl.}

## PER-STAGE COST, hung off the same breadcrumb seams (`abi/aowlspt_widget.h`).
## Every getter answers -1 for "no complete frame measured yet", which is a
## THIRD state and not a zero: a stage that genuinely cost 0 us and a stage
## nobody has looked at yet must not print the same thing.
proc cWgStageBegin() {.importc: "aowl_wg_stage_begin", nodecl.}
proc cWgStageEnd() {.importc: "aowl_wg_stage_end", nodecl.}
proc cWgStageFrames(): int64 {.importc: "aowl_wg_stage_frames", nodecl.}
proc cWgStageCount(): int32 {.importc: "aowl_wg_stage_count", nodecl.}
proc cWgStageUs(i: int32): int64 {.importc: "aowl_wg_stage_us", nodecl.}
proc cWgStagePeakUs(i: int32): int64 {.
  importc: "aowl_wg_stage_peak_us", nodecl.}
proc cWgStageWorstUs(i: int32): int64 {.
  importc: "aowl_wg_stage_worst_us", nodecl.}
proc cWgStageFrameUs(): int64 {.importc: "aowl_wg_stage_frame_us", nodecl.}
proc cWgStageWorstTotalUs(): int64 {.
  importc: "aowl_wg_stage_worst_total_us", nodecl.}
proc cWgStageBackwards(): int64 {.importc: "aowl_wg_stage_backwards", nodecl.}

const
  WgCrumbEnter     = 1'i32
  WgCrumbToggle    = 2'i32
  WgCrumbScanWorld = 4'i32
  WgCrumbMouse     = 5'i32
  WgCrumbEditKeys  = 6'i32
  WgCrumbDrag      = 7'i32
  WgCrumbWText     = 8'i32
  WgCrumbWPlace    = 9'i32
  WgCrumbWStyle    = 10'i32
  WgCrumbWSetText  = 11'i32
  WgCrumbWShow     = 12'i32
  WgCrumbBanner    = 13'i32
  WgCrumbMarkers   = 15'i32
  WgCrumbDone      = 16'i32

# ---- target indices into `aowl_du_targets` in abi/aowlspt_debugui.h ----
#
# These are POSITIONAL indices into a C array, and nothing in either language
# ties a name here to a row there. On 2026-08-24, commit 7eb60cb inserted
# `RectTransform::get_anchorMax` into the MIDDLE of that table for the
# inspector's `rect` verb and did not add a name here, so every index from 13
# up addressed the row BEFORE the one it meant. `DuGetParent` = 18 resolved to
# `Transform::set_localPosition` -- a byte-verified, non-shared, perfectly
# valid function of the WRONG SHAPE. `aowl_du_call_p_p` passes (this, NULL),
# so the setter read its Vector3 argument through a NULL pointer and faulted
# inside the call at climb depth 0, on a receiver that had just passed every
# liveness gate. Four rounds of fixing the walk could not have found it.
# `duIndicesOk` below is the check that makes this failure mode impossible to
# ship again -- it compares the NAME the C table actually holds at each index
# against the name this code believes is there.
const
  DuCameraMain     = 0'i32
  DuWorldToScreen  = 1'i32
  DuSetAnchoredPos = 2'i32
  DuSetAnchorMin   = 3'i32
  DuSetAnchorMax   = 4'i32
  DuSetPivot       = 5'i32
  DuGetTransform   = 6'i32
  DuGetRoot        = 7'i32
  DuGetAnchoredPos = 8'i32
  DuGetSizeDelta   = 9'i32
  DuSetSizeDelta   = 10'i32
  DuGetAnchorMin   = 11'i32
  DuGetPivot       = 12'i32
  DuGetAnchorMax   = 13'i32
  DuGetRect        = 14'i32
  DuGetLocalScale  = 15'i32
  DuSetLocalScale  = 16'i32
  DuGetLocalPos    = 17'i32
  DuSetLocalPos    = 18'i32
  DuGetParent      = 19'i32
  DuGoActiveSelf   = 20'i32
  DuGoActiveInHier = 21'i32
  DuGoLayer        = 22'i32
  DuCanvasOrder    = 23'i32
  DuCanvasMode     = 24'i32
  DuCanvasScale    = 25'i32
  DuSetRaycast     = 26'i32
  DuSetEnabled     = 27'i32

# ---------------------------------------------------------------------------
# Caps
#
# Every one of these is a REFUSAL, not a preference: a corrupt `_size` on a
# List, a config file with a silly number in it, or a raid with three hundred
# bots must all cost a bounded amount of work inside a per-frame detour.
# ---------------------------------------------------------------------------
const
  cDuMaxMarkers    = 48    ## hard ceiling on ESP markers, whatever the config says
  cDuMaxPlayers    = 64    ## registered players read per pass

# ---------------------------------------------------------------------------
# The layout configuration
#
# A FLAT JSON object in `aowlspt-debugui.json` beside the host DLL. Flat and not
# nested on purpose: the host has no JSON parser and does not want one, the same
# shallow key scan `readBoolKey` uses is enough for flat keys, and a nested
# schema read by a shallow scanner is a trap (the scanner would happily find
# `"x"` inside a different object). See the schema comment on `duLoadLayout`.
# ---------------------------------------------------------------------------
type DuLayout = object
  panelOn: bool
  panelAnchor: string
  panelX: float64
  panelY: float64
  panelFont: float64
  panelLine: float64
  panelThrottle: int
  panelFields: string
  panelR: float64
  panelG: float64
  panelB: float64
  espOn: bool
  espFont: float64
  espMax: int
  espMaxDist: float64
  espY: float64
  espFields: string
  espR: float64
  espG: float64
  espB: float64
  toggleVk: int
  espVk: int
  note1: string
  note2: string
  note3: string
  loaded: bool
  source: string

var gDuCfg = DuLayout(panelOn: true, panelAnchor: "topleft",
                      panelX: 16.0, panelY: -16.0,
                      panelFont: 18.0, panelLine: 22.0, panelThrottle: 10,
                      panelFields: "fps,frame,build,map,raid,bots,pos,rot",
                      panelR: 1.0, panelG: 1.0, panelB: 0.62,
                      espOn: true, espFont: 14.0, espMax: 24,
                      espMaxDist: 400.0, espY: 24.0,
                      espFields: "role,nick,dist",
                      espR: 1.0, espG: 0.35, espB: 0.30,
                      toggleVk: 0x72, espVk: 0,
                      note1: "", note2: "", note3: "",
                      loaded: false, source: "")

var gDuCfgText = ""
  ## The exact text of `aowlspt-debugui.json` as of the last successful load.
  ## Held so the live-reload check can tell "the file changed" from "the file
  ## is still there", WITHOUT re-parsing it every time it looks. Comparing the
  ## raw text is the honest test: comparing parsed fields would miss a change
  ## to any key this struct does not carry, and comparing a modification
  ## timestamp would fire on a rewrite that changed nothing.

proc duTrim(s: string): string =
  ## Leading/trailing ASCII whitespace off a value token. Written out rather
  ## than reached for in strutils because the value may legitimately contain
  ## inner spaces (a note slot) and only the ends must go.
  var a = 0
  var b = s.len - 1
  while a <= b and (s[a] == ' ' or s[a] == '\t' or s[a] == '\r' or
                    s[a] == '\n'):
    inc a
  while b >= a and (s[b] == ' ' or s[b] == '\t' or s[b] == '\r' or
                    s[b] == '\n'):
    dec b
  result = ""
  for i in a .. b:
    result.add s[i]

proc duRawValue(text: string; key: string; found: var bool): string =
  ## The raw token after `"key" :` in `text`, or "" with `found=false`.
  ##
  ## A quoted value is returned unquoted and un-escaped (no escape sequence is
  ## meaningful in any value this schema has); an unquoted one runs to the next
  ## comma, brace or newline. Deliberately shallow -- exactly the discipline
  ## `readBoolKey` already uses for `aowlspt-host.json`, and the reason the
  ## schema is flat.
  found = false
  result = ""
  let needle = "\"" & key & "\""
  let at = find(text, needle)
  if at < 0:
    return
  var i = at + needle.len
  while i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == ':'):
    inc i
  if i >= text.len:
    return
  found = true
  if text[i] == '"':
    inc i
    while i < text.len and text[i] != '"':
      result.add text[i]
      inc i
    return
  while i < text.len and text[i] != ',' and text[i] != '}' and
        text[i] != '\n' and text[i] != '\r':
    result.add text[i]
    inc i
  result = duTrim(result)

proc duCfgStr(text, key, dflt: string): string =
  var found = false
  let v = duRawValue(text, key, found)
  result = (if found: v else: dflt)

proc duCfgBool(text, key: string; dflt: bool): bool =
  ## `true` / a non-zero leading digit is true; `false` / `0` is false; absent or
  ## unrecognised keeps the default, so a typo weakens nothing.
  var found = false
  let v = duRawValue(text, key, found)
  if not found or v.len == 0:
    return dflt
  if v[0] == 't' or v[0] == 'T':
    return true
  if v[0] == 'f' or v[0] == 'F':
    return false
  if v[0] >= '1' and v[0] <= '9':
    return true
  if v[0] == '0':
    return false
  result = dflt

proc duParseNum(s: string; ok: var bool): float64 =
  ## A hand-rolled signed decimal parse. `parseFloat` is `.raises` in nimony and
  ## would drag a `try` into a per-frame path for no benefit; and a config value
  ## that is not a number must be a SKIP (keep the default), never an error.
  ok = false
  result = 0.0
  var i = 0
  var neg = false
  if i < s.len and (s[i] == '-' or s[i] == '+'):
    neg = s[i] == '-'
    inc i
  var seen = false
  var whole = 0.0
  while i < s.len and s[i] >= '0' and s[i] <= '9':
    whole = whole * 10.0 + float64(int(s[i]) - int('0'))
    seen = true
    inc i
  if i < s.len and s[i] == '.':
    inc i
    var scale = 0.1
    while i < s.len and s[i] >= '0' and s[i] <= '9':
      whole = whole + float64(int(s[i]) - int('0')) * scale
      scale = scale * 0.1
      seen = true
      inc i
  if not seen:
    return
  ok = true
  result = (if neg: -whole else: whole)

proc duCfgNum(text, key: string; dflt: float64): float64 =
  var found = false
  let v = duRawValue(text, key, found)
  if not found:
    return dflt
  var ok = false
  let n = duParseNum(v, ok)
  result = (if ok: n else: dflt)

proc duCfgInt(text, key: string; dflt, lo, hi: int): int =
  ## An integer CLAMPED into [lo, hi]. Clamping rather than rejecting because
  ## every integer in this schema is a budget (a throttle, a marker count) and a
  ## silly value must become a safe one, not disable the feature.
  let v = int(duCfgNum(text, key, float64(dflt)))
  if v < lo: return lo
  if v > hi: return hi
  result = v

proc duSplit(s: string; sep: char): seq[string] =
  ## `s` cut on `sep`, each piece trimmed, empties dropped. Used for the field
  ## lists and the colour triples; `strutils.split` exists but this also trims,
  ## which every caller here wants.
  result = @[]
  var cur = ""
  for i in 0 ..< s.len:
    if s[i] == sep:
      let t = duTrim(cur)
      if t.len > 0: result.add t
      cur = ""
    else:
      cur.add s[i]
  let t = duTrim(cur)
  if t.len > 0: result.add t

proc duParseRgb(s: string; r, g, b: var float64) =
  ## "r,g,b" in 0..1 into three floats. Anything that does not parse into three
  ## numbers leaves all three untouched -- a partial colour is never applied.
  if s.len == 0:
    return
  let parts = duSplit(s, ',')
  if parts.len != 3:
    return
  var ok1 = false
  var ok2 = false
  var ok3 = false
  let v1 = duParseNum(parts[0], ok1)
  let v2 = duParseNum(parts[1], ok2)
  let v3 = duParseNum(parts[2], ok3)
  if ok1 and ok2 and ok3:
    r = v1
    g = v2
    b = v3

proc duLoadLayout() =
  ## Read `aowlspt-debugui.json` beside the host DLL, or keep the built-in
  ## defaults when it is absent. Called at boot AND on every toggle-on, so the
  ## file can be edited and the panel re-toggled without restarting the game --
  ## which is the whole point of having it in a file.
  ##
  ## SCHEMA (one flat JSON object; every key optional, unknown keys ignored):
  ##
  ##   "panelEnabled":     true      -- draw the F3 panel at all
  ##   "panelAnchor":      "topleft" -- topleft | topright | bottomleft |
  ##                                    bottomright | top | bottom | center
  ##   "panelX":           16        -- offset from that corner, in canvas units.
  ##   "panelY":           -16          Unity's Y grows UPWARD, so a top anchor
  ##                                    wants a NEGATIVE Y to move down.
  ##   "panelFontSize":    18
  ##   "panelLineHeight":  22        -- vertical spacing between lines
  ##   "panelThrottle":    10        -- refresh every Nth frame (1..600)
  ##   "panelColor":       "1,1,0.62"-- r,g,b in 0..1
  ##   "panelFields":      "fps,frame,build,map,raid,bots,pos,rot"
  ##        one line per name, in this order. Recognised names:
  ##          fps    frames per second and the host's own frame counter
  ##          frame  the detour firing count on its own
  ##          build  host name/version and the client build
  ##          map    GameWorld.LocationId, or "menu" when there is no world
  ##          raid   whether a GameWorld is live and how long it has been
  ##          bots   registered / AI / alive counts
  ##          pos    your player's world position
  ##          rot    your player's yaw and pitch
  ##          botlist the first few AI bots with world coords + distance
  ##                  (this is the WorldToScreenPoint-free fallback, and it is
  ##                   the most useful single line for the frozen-bot hunt)
  ##          note1 note2 note3   free text from the keys of the same name
  ##
  ##   "espEnabled":       true
  ##   "espFontSize":      14
  ##   "espMaxMarkers":    24        -- 0..48
  ##   "espMaxDistance":   400       -- metres; farther bots get no marker
  ##   "espYOffset":       24        -- pixels above the bot's feet
  ##   "espColor":         "1,0.35,0.3"
  ##   "espFields":        "role,nick,dist"   -- any of role, nick, dist, pos
  ##
  ##   "toggleKey":        114       -- virtual-key code; 114 = VK_F3
  ##   "espToggleKey":     0         -- 0 = the markers follow the panel toggle
  ##   "note1"/"note2"/"note3": "..."
  var text = ""
  if not readTextFile(joinPath(gDir, "aowlspt-debugui.json"), text):
    gDuCfg.loaded = false
    gDuCfg.source = "built-in defaults (no aowlspt-debugui.json)"
    return
  gDuCfg.panelOn    = duCfgBool(text, "panelEnabled", true)
  gDuCfg.panelAnchor= duCfgStr(text, "panelAnchor", "topleft")
  gDuCfg.panelX     = duCfgNum(text, "panelX", 16.0)
  gDuCfg.panelY     = duCfgNum(text, "panelY", -16.0)
  gDuCfg.panelFont  = duCfgNum(text, "panelFontSize", 18.0)
  gDuCfg.panelLine  = duCfgNum(text, "panelLineHeight", 22.0)
  gDuCfg.panelThrottle = duCfgInt(text, "panelThrottle", 10, 1, 600)
  gDuCfg.panelFields= duCfgStr(text, "panelFields",
                               "fps,frame,build,map,raid,bots,pos,rot")
  gDuCfg.espOn      = duCfgBool(text, "espEnabled", true)
  gDuCfg.espFont    = duCfgNum(text, "espFontSize", 14.0)
  gDuCfg.espMax     = duCfgInt(text, "espMaxMarkers", 24, 0, cDuMaxMarkers)
  gDuCfg.espMaxDist = duCfgNum(text, "espMaxDistance", 400.0)
  gDuCfg.espY       = duCfgNum(text, "espYOffset", 24.0)
  gDuCfg.espFields  = duCfgStr(text, "espFields", "role,nick,dist")
  gDuCfg.toggleVk   = duCfgInt(text, "toggleKey", 0x72, 0, 255)
  gDuCfg.espVk      = duCfgInt(text, "espToggleKey", 0, 0, 255)
  gDuCfg.note1      = duCfgStr(text, "note1", "")
  gDuCfg.note2      = duCfgStr(text, "note2", "")
  gDuCfg.note3      = duCfgStr(text, "note3", "")
  # The two colours are one "r,g,b" string each rather than three keys, because
  # three keys is three chances for a half-applied colour.
  var pr = 1.0
  var pg = 1.0
  var pb = 0.62
  duParseRgb(duCfgStr(text, "panelColor", ""), pr, pg, pb)
  gDuCfg.panelR = pr
  gDuCfg.panelG = pg
  gDuCfg.panelB = pb
  var er = 1.0
  var eg = 0.35
  var eb = 0.30
  duParseRgb(duCfgStr(text, "espColor", ""), er, eg, eb)
  gDuCfg.espR = er
  gDuCfg.espG = eg
  gDuCfg.espB = eb
  gDuCfg.loaded = true
  gDuCfg.source = "aowlspt-debugui.json"
  gDuCfgText = text

# ---------------------------------------------------------------------------
# LIVE APPLY -- re-read the layout file while the panel is on screen
#
# THE BUG THIS CLOSES, stated as a measurement rather than a belief: before
# this, `duLoadLayout` had exactly three call sites -- once at arm time, and
# twice on the F3 toggle-ON edge (`duEditKeys`). So a settings change made
# while the overlay was VISIBLE -- font size, X/Y offset, colour, throttle --
# reached `aowlspt-debugui.json` correctly and then sat there, because nothing
# read the file again until the user toggled the panel off and on. From the
# player's seat that is indistinguishable from "the setting does nothing",
# which is exactly the complaint.
#
# What this is NOT: it is not an il2cpp path. It reads a file and writes our
# own struct; there is no managed pointer to hop, no method to byte-verify and
# nothing for `aowl_p_p_seh` to guard that the enclosing region does not already
# guard. Saying "guarded" about it would be theatre. What it DOES carry is the
# rest of the discipline that applies: it is throttled (never per-frame), it is
# bounded (one read of one small file), it self-disables after
# `cDuReloadMaxFaults` consecutive read failures rather than retrying forever,
# and it can be switched off from the file it watches.
#
# The re-parse is skipped unless the file's TEXT actually changed, so the steady
# state costs one read and one string compare per second and never touches the
# config the renderer is reading.
# ---------------------------------------------------------------------------

const
  cDuReloadEveryFires = 30
    ## Check about twice a second at 60fps. Fast enough that dragging a colour
    ## picker looks continuous; slow enough to be free.
  cDuReloadMaxFaults = 5

var gDuReloadFaults = 0
var gDuReloadOff = false
var gDuReloads = 0

proc duHotReloadTick(fires: int): bool =
  ## Re-read `aowlspt-debugui.json` if it has changed since the last read.
  ## Called from the draw region, only while something is actually on screen.
  ## Returns TRUE when the config was re-parsed, so the caller can refresh the
  ## widget layout too.
  ##
  ## `fires` is passed in rather than read from the module's frame counter, and
  ## the widget reload is left to the caller, purely so this can sit beside
  ## `duLoadLayout` -- the loader it reuses -- instead of being pushed to the
  ## bottom of the file away from the schema it is about.
  result = false
  if gDuReloadOff:
    return
  if (fires mod cDuReloadEveryFires) != 0:
    return
  # An explicit off switch, honoured from the config we last successfully read
  # -- so a user who does not want their file watched can say so in the file.
  if not duCfgBool(gDuCfgText, "panelLiveReload", true):
    return
  var text = ""
  if not readTextFile(joinPath(gDir, "aowlspt-debugui.json"), text):
    # A read that fails is usually the writer holding the file for the instant
    # it takes to rewrite it -- transient, and not worth a log line. Only a
    # PERSISTENT failure means something is wrong, and that is what the counter
    # measures.
    gDuReloadFaults = gDuReloadFaults + 1
    if gDuReloadFaults >= cDuReloadMaxFaults:
      gDuReloadOff = true
      warn "debugui: live config reload DISABLED after " & $gDuReloadFaults &
           " consecutive failures to read aowlspt-debugui.json. The panel " &
           "keeps the settings it last read; toggle it off and on to pick up " &
           "a change."
    return
  gDuReloadFaults = 0
  if text.len == 0 or text == gDuCfgText:
    return
  # Changed. Re-parse through the SAME loader the boot path uses -- a second
  # parser here is how the file would come to mean two different things
  # depending on which code path read it.
  duLoadLayout()
  result = true
  gDuReloads = gDuReloads + 1
  if gDuReloads <= 3:
    # Say so the first few times, then stop: this fires on every drag of a
    # slider and would otherwise bury the log.
    okLog "debugui: aowlspt-debugui.json changed on disk -- re-read and " &
          "applied live (font=" & $int(gDuCfg.panelFont) &
          " x=" & $int(gDuCfg.panelX) & " y=" & $int(gDuCfg.panelY) &
          " colour=" & $int(gDuCfg.panelR * 255.0) & "," &
          $int(gDuCfg.panelG * 255.0) & "," & $int(gDuCfg.panelB * 255.0) &
          "). No F3 off/on cycle was needed."

var gDuGameWorld: Il2CppPtr = nil

## Whether the overlay is currently visible, and whether the markers are.
var gDuVisible = false
var gDuEspVisible = false
## Per-frame bookkeeping.
var gDuFires = 0
var gDuLoggedOnce = false
var gDuFaults = 0

proc duPtrAdd(p: Il2CppPtr; off: int32): Il2CppPtr =
  cast[Il2CppPtr](cast[uint64](p) + uint64(off))

proc duOk(p: Il2CppPtr; size: int32): bool =
  ## One gate for every pointer hop, identical in spirit to botdiag's `bdOk`:
  ## non-null, in a plausible user-space range, and page-readable for `size`
  ## bytes by VirtualQuery -- never a faulting deref to find out.
  result = p != nil and bdSanePtr(p) and cIsReadableC(p, size) != 0'i32

# ---------------------------------------------------------------------------
# Read-back helpers
#
# The overlay could WRITE a transform but had no way to ASK what the transform
# then was, which is exactly why "33 clones built" and "nothing on screen" were
# indistinguishable. Everything below is read-only and guarded; a target that did
# not verify makes the reader return `ok=false` rather than a plausible zero.
# ---------------------------------------------------------------------------
proc duGetVec2(target: int32; self: Il2CppPtr; ok: var bool;
               x, y: var float64) =
  ok = false
  x = 0.0
  y = 0.0
  let fn = cDuFn(target)
  if fn == nil or not duOk(self, 0x20'i32):
    return
  let packed = cDuCallUP(fn, self)
  x = cDuVec2X(packed)
  y = cDuVec2Y(packed)
  ok = true

proc duGetSret(target: int32; self: Il2CppPtr; n: int32; ok: var bool) =
  ## Fills `cDuSret0..3`. `n` is how many floats the struct has (3 for a
  ## Vector3, 4 for a Rect).
  ok = false
  let fn = cDuFn(target)
  if fn == nil or not duOk(self, 0x20'i32):
    return
  ok = cDuCallSretP(fn, self, n) != 0'i32

proc duGetInt(target: int32; self: Il2CppPtr; ok: var bool): int32 =
  ok = false
  result = 0'i32
  let fn = cDuFn(target)
  if fn == nil or not duOk(self, 0x20'i32):
    return
  result = cDuCallIP(fn, self)
  ok = true

proc duGameObjectOf(comp: Il2CppPtr): Il2CppPtr =
  result = nil
  let fn = mi2Fn(Mi2GetGameObject)
  if fn == nil or not duOk(comp, 0x20'i32):
    return
  let go = cMi2CallPP(fn, comp)
  if duOk(go, 0x20'i32):
    result = go

proc duNameOf(obj: Il2CppPtr): string =
  ## `UnityEngine.Object::get_name` -> a managed String -> our string. Used only
  ## by the one-shot diagnostics, never per frame: it allocates on the managed
  ## heap and a per-frame allocation is the one cost this overlay refuses.
  result = ""
  let fn = mi2Fn(Mi2GetName)
  if fn == nil or not duOk(obj, 0x20'i32):
    return
  let s = cMi2CallPP(fn, obj)
  if s == nil or cIsReadableC(s, 0x14'i32) == 0'i32:
    return
  result = bdReadString(s)

include wgeom

# ---------------------------------------------------------------------------
# Reading the world
#
# All of it through botdiag's already-live-validated offsets and guarded
# readers, so there is ONE definition of "where is a bot's position" in the host
# and this file is not a second, drifting copy of it.
# ---------------------------------------------------------------------------
proc duReadVec3(p: Il2CppPtr; off: int32; ok: var bool;
                x, y, z: var float64) =
  ok = false
  x = 0.0
  y = 0.0
  z = 0.0
  if p == nil or not bdSanePtr(p):
    return
  if cIsReadableC(duPtrAdd(p, off), 12'i32) == 0'i32:
    return
  x = cReadF32At(duPtrAdd(p, off))
  y = cReadF32At(duPtrAdd(p, off + 4'i32))
  z = cReadF32At(duPtrAdd(p, off + 8'i32))
  ok = true

proc duPlayerPos(player: Il2CppPtr; ok: var bool; x, y, z: var float64) =
  ## player.MovementContext(+0x60) -> PreviousPosition(+0x370). The same chain
  ## botdiag walks, and the same reason: it is the pose the client itself reads.
  ok = false
  x = 0.0
  y = 0.0
  z = 0.0
  if not duOk(player, cBdOffPlMoveCtx() + 8'i32):
    return
  let mc = cReadPtrAt(player, cBdOffPlMoveCtx())
  duReadVec3(mc, cDuOffMcPrevPos(), ok, x, y, z)

proc duPlayerRot(player: Il2CppPtr; ok: var bool; yaw, pitch: var float64) =
  ## MovementContext._rotation (+0xC0) -- a Vector2 of yaw, pitch.
  ok = false
  yaw = 0.0
  pitch = 0.0
  if not duOk(player, cBdOffPlMoveCtx() + 8'i32):
    return
  let mc = cReadPtrAt(player, cBdOffPlMoveCtx())
  if mc == nil or not bdSanePtr(mc):
    return
  if cIsReadableC(duPtrAdd(mc, cDuOffMcRotation()), 8'i32) == 0'i32:
    return
  yaw = cReadF32At(duPtrAdd(mc, cDuOffMcRotation()))
  pitch = cReadF32At(duPtrAdd(mc, cDuOffMcRotation() + 4'i32))
  ok = true

proc duRoleName(role: int32): string =
  ## A few of the EBotRole values worth naming on screen. Unnamed roles print
  ## their number rather than a guess -- a wrong label on a boss would be worse
  ## than a number during a spawn investigation.
  case int(role)
  of 0: "assault"
  of 1: "marksman"
  of 2: "bossTest"
  of 3: "bossBully"
  of 6: "bossKilla"
  of 7: "bossKojaniy"
  of 8: "bossGluhar"
  of 9: "bossSanitar"
  of 24: "pmcBot"
  of 26: "exUsec"
  of 30: "cursedAssault"
  of 32: "sectantWarrior"
  of 33: "sectantPriest"
  else: "role" & $int(role)

proc duFmt2(v: float64): string = formatFloat(v, ffDecimal, 2)
proc duFmt1(v: float64): string = formatFloat(v, ffDecimal, 1)
proc duFmt0(v: float64): string = formatFloat(v, ffDecimal, 0)

type DuBot = object
  ptrv: Il2CppPtr
  nick: string
  role: int32
  x: float64
  y: float64
  z: float64
  posOk: bool
  alive: bool
  dist: float64

## Snapshot of this pass's world census, filled by `duScanWorld` and read by both
## the panel and the markers, so the registered-player list is walked ONCE per
## refresh however many things want to look at it.
var gDuBots: seq[DuBot] = @[]
var gDuRegistered = 0
var gDuAiCount = 0
var gDuAliveCount = 0
var gDuYou: Il2CppPtr = nil

proc duScanWorld() =
  ## Walk GameWorld.RegisteredPlayers (+0x1D0) once: count everything, and keep
  ## the AI entries. Read-only, capped at `cDuMaxPlayers`, every hop guarded --
  ## byte for byte the discipline `bdEnumerate` uses, with the logging replaced
  ## by a snapshot.
  gDuBots = @[]
  gDuRegistered = 0
  gDuAiCount = 0
  gDuAliveCount = 0
  gDuYou = nil
  let gw = gDuGameWorld
  if not duOk(gw, cBdOffRegPlayers() + 8'i32):
    return
  let lst = cReadPtrAt(gw, cBdOffRegPlayers())
  if not duOk(lst, cBdOffListSize() + 4'i32):
    return
  let arr = cReadPtrAt(lst, cBdOffListItems())
  let size = cReadI32At(duPtrAdd(lst, cBdOffListSize()))
  if not duOk(arr, cBdOffArrElems() + 8'i32) or size <= 0'i32:
    return
  gDuRegistered = int(size)
  let alive = bdCollectAlive(gw)
  gDuAliveCount = alive.len
  let n = (if size > int32(cDuMaxPlayers): int32(cDuMaxPlayers) else: size)
  var bots: seq[DuBot] = @[]
  for i in 0 ..< int(n):
    let slot = duPtrAdd(arr, cBdOffArrElems() + int32(i) * 8'i32)
    if cIsReadableC(slot, 8'i32) == 0'i32:
      continue
    let pl = cReadPtrAt(slot, 0'i32)
    if pl == nil or not bdSanePtr(pl):
      continue
    if bdIsYou(pl):
      gDuYou = pl
      continue
    if not bdIsAI(pl):
      continue
    inc gDuAiCount
    var side = 0'i32
    var role = 0'i32
    bdReadSideRole(pl, side, role)
    var posOk = false
    var x = 0.0
    var y = 0.0
    var z = 0.0
    duPlayerPos(pl, posOk, x, y, z)
    var isAlive = false
    let key = cast[uint64](pl)
    for k in alive:
      if k == key: isAlive = true
    bots.add DuBot(ptrv: pl, nick: bdReadNickname(pl), role: role,
                   x: x, y: y, z: z, posOk: posOk, alive: isAlive, dist: 0.0)
  gDuBots = bots

proc duSqrt(v: float64): float64 =
  ## Newton-Raphson, ten iterations from a decent seed. `math.sqrt` is available,
  ## but this file is included into a translation unit that already carries its
  ## own numeric helpers and a distance is the only root it needs; twelve lines
  ## here beats an import whose interaction with nimony's `.raises` surface is
  ## one more thing to be sure of on a per-frame path.
  if v <= 0.0:
    return 0.0
  var x = v
  if x > 1.0:
    x = v * 0.5
  var it = 0
  while it < 12:
    x = 0.5 * (x + v / x)
    inc it
  result = x

proc duDistance(ax, ay, az, bx, by, bz: float64): float64 =
  let dx = ax - bx
  let dy = ay - by
  let dz = az - bz
  result = duSqrt(dx * dx + dy * dy + dz * dz)

# ---------------------------------------------------------------------------
# The panel
# ---------------------------------------------------------------------------
proc duBotListLine(): string =
  ## The WorldToScreenPoint-free fallback, and the single most useful line for
  ## the frozen-bot investigation: the first few AI bots with world coordinates
  ## and distance, straight in the panel. Shown whether or not projection works.
  if gDuBots.len == 0:
    return "bots: none registered"
  var s = ""
  var shown = 0
  for i in 0 ..< gDuBots.len:
    if shown >= 4:
      break
    let b = gDuBots[i]
    if s.len > 0: s.add "  "
    s.add duRoleName(b.role)
    s.add "@"
    s.add (if b.posOk: "(" & duFmt0(b.x) & "," & duFmt0(b.y) & "," &
                       duFmt0(b.z) & ")" else: "?")
    s.add (if b.alive: "" else: "!dead")
    inc shown
  if gDuBots.len > shown:
    s.add "  +" & $(gDuBots.len - shown) & " more"
  result = s

# ---------------------------------------------------------------------------
# PROFILER PANEL LINES (abi/aowlspt_profile.h) -- ADDITIVE
# ---------------------------------------------------------------------------
#
# New `panelFields` names only. Nothing above this point changed: the profiler
# is a set of extra `of` branches in `duPanelLine`, so a config that does not
# name them behaves exactly as it did before, and the profiler being OFF makes
# every one of them print a refusal rather than a zero.
#
# Every number here comes out of the shared region through a typed accessor;
# this file never dereferences the struct. The whole cost of a profiler line is
# a bounded loop over 64 int32 slots, and it only runs on a panel REFRESH
# (`panelThrottle`, default every 10th frame), not every frame.
#
# `-1` from `aowl_prof_slot_permille` means "no complete window yet" and is
# rendered "--", never "0.0%": "I could not look" is not a measurement.
proc cProfSlotCount(): int32 {.importc: "aowl_prof_slot_count", nodecl.}
proc cProfSlotKind(i: int32): int32 {.importc: "aowl_prof_slot_kind", nodecl.}
proc cProfSlotNameC(i: int32): cstring {.importc: "aowl_prof_slot_name", nodecl.}
proc cProfSlotNs(i: int32): int64 {.importc: "aowl_prof_slot_ns", nodecl.}
proc cProfSlotMaxNs(i: int32): int64 {.importc: "aowl_prof_slot_max_ns", nodecl.}
proc cProfSlotCalls(i: int32): int64 {.importc: "aowl_prof_slot_calls", nodecl.}
proc cProfSlotPermille(i: int32): int32 {.
  importc: "aowl_prof_slot_permille", nodecl.}
proc cProfWinUs(which: int32): int32 {.importc: "aowl_prof_win_us", nodecl.}
proc cProfOverheadNs(): int64 {.importc: "aowl_prof_overhead_ns", nodecl.}
proc cProfFaults(): int32 {.importc: "aowl_prof_faults", nodecl.}
proc cProfSelfDisabled(): int32 {.
  importc: "aowl_prof_self_disabled", nodecl.}
proc cProfFramesSeen(): int64 {.importc: "aowl_prof_frames", nodecl.}
proc cProfOn(): int32 {.importc: "aowl_prof_is_enabled", nodecl.}

proc duMsText(ns: int64): string =
  ## Nanoseconds as milliseconds to 3 places, without floating point formatting
  ## and without allocating a table. 1_234_567 ns -> "1.234".
  let us = ns div 1000
  result = $(us div 1000) & "." &
           (if us mod 1000 < 10: "00" elif us mod 1000 < 100: "0" else: "") &
           $(us mod 1000)

proc duProfRank(n: int): int32 =
  ## The index of the n-th costliest slot this window (0-based), or -1 when
  ## there is no n-th slot.
  ##
  ## No sort and no allocation: a bounded selection scan over a table whose
  ## size is a compile-time constant, run n+1 times. The order is TOTAL --
  ## (ns descending, index ascending) -- which is what stops two slots with
  ## identical cost from both being reported as rank 0 and one of them never
  ## appearing at all.
  result = -1'i32
  let cap = cProfSlotCount()
  var prevNs = int64(0)
  var prevIdx = -1'i32
  var rank = 0
  while rank <= n:
    var bestIdx = -1'i32
    var bestNs = int64(-1)
    var i = 0'i32
    while i < cap:
      if cProfSlotKind(i) != 0'i32:
        let v = cProfSlotNs(i)
        let eligible = prevIdx < 0 or v < prevNs or (v == prevNs and i > prevIdx)
        # `v > bestNs` alone breaks ties toward the LOWER index, because the
        # scan runs ascending -- which is the second half of the total order.
        if eligible and v > bestNs:
          bestNs = v
          bestIdx = i
      i = i + 1'i32
    if bestIdx < 0: return -1'i32
    if rank == n: return bestIdx
    prevNs = bestNs
    prevIdx = bestIdx
    rank = rank + 1

proc duProfState(): string =
  if cProfOn() == 0:
    if cProfSelfDisabled() != 0:
      result = "profiler SELF-DISABLED after " & $cProfFaults() & " faults"
    else:
      result = "profiler OFF (turn it on in the Debug mod's settings)"
  elif cProfWinUs(1) == 0:
    result = "profiler ON, no complete window yet"
  else:
    result = ""

proc duProfLine(n: int): string =
  ## The n-th costliest profiled scope, or an explicit refusal.
  let st = duProfState()
  if st.len > 0: return (if n == 0: st else: "")
  let i = duProfRank(n)
  if i < 0: return ""
  let permille = cProfSlotPermille(i)
  let ns = cProfSlotNs(i)
  let noise = cProfOverheadNs() * 3
  result = "  " & $cProfSlotNameC(i) & "  " & duMsText(ns) & " ms  " &
           (if permille < 0: "--"
            else: $(permille div 10) & "." & $(permille mod 10) & "%") &
           "  x" & $cProfSlotCalls(i) &
           "  peak " & duMsText(cProfSlotMaxNs(i)) & " ms" &
           (if noise > 0 and ns < noise: "  [at the noise floor]" else: "")

## THE OVERLAY MEASURING ITSELF.
##
## The region's own accounting says `debugui: 24552 us against 900 us` and stops
## there. That names the participant, which was never the question. This breaks
## the same interval down across the 16 breadcrumb stages, so the answer is a
## stage NAME and a number rather than an invitation to guess.
##
## Sorted by the WORST FRAME's breakdown, not by the last frame's: the last
## frame is whatever happened to be cheap, and the complaint is about the peak.
## `--` means no complete frame has been measured; it never prints 0.
proc duStagesLine(maxRows: int): string =
  if cWgStageFrames() <= 0:
    return "stages  no complete refresh measured yet (three states, not two:\n" &
           "  this is 'not looked at', not 'costs nothing')"
  var res = "stages us  last " & $cWgStageFrameUs() & "  worst frame " &
            $cWgStageWorstTotalUs() & "  over " & $cWgStageFrames() &
            " refresh(es)"
  if cWgStageBackwards() > 0:
    res.add "  [QPC went backwards " & $cWgStageBackwards() & "x]"
  # Selection sort over at most 17 fixed slots, capped twice: by `maxRows` and
  # by the stage count itself, so a bad count cannot make this loop.
  var n = int(cWgStageCount())
  if n > 17: n = 17
  # Explicitly cleared, not merely declared: nimony will not assume an array is
  # zeroed, and a stale `true` here would silently drop a stage from the table.
  var taken: array[17, bool] = default(array[17, bool])
  for i in 0 ..< 17:
    taken[i] = false
  var rows = 0
  var lim = maxRows
  if lim > n: lim = n
  while rows < lim:
    var best = -1
    var bestV: int64 = 0
    for i in 0 ..< n:
      if taken[i]: continue
      let v = cWgStageWorstUs(int32(i))
      if v > bestV or best < 0:
        best = i
        bestV = v
    if best < 0 or bestV <= 0:
      break
    taken[best] = true
    res.add "\n  " & $cWgCrumbTextC(int32(best)) & "  worst " & $bestV &
            "  last " & $cWgStageUs(int32(best)) & "  peak " &
            $cWgStagePeakUs(int32(best))
    inc rows
  if rows == 0:
    res.add "\n  every stage measured 0 us in the worst frame recorded"
  res

proc duPanelLine(field: string): string =
  ## One panel line's text for one field name. An unrecognised name prints
  ## itself with a marker rather than being silently dropped, so a typo in the
  ## config is visible on screen instead of being an inexplicably missing row.
  case field
  of "fps":
    result = "fps " & duFmt1(cDuFps()) & "   ticks " & $int(cDuFrameNo())
  of "frame":
    result = "detour fires " & $gDuFires
  of "build":
    result = HostName & " " & HostVersion & "   client 1.1.0.1.46777"
  of "map":
    var loc = ""
    if duOk(gDuGameWorld, cDuOffGwLocationId() + 8'i32):
      loc = bdReadString(cReadPtrAt(gDuGameWorld, cDuOffGwLocationId()))
    result = "map " & (if loc.len > 0: loc
                       elif gDuGameWorld != nil: "(world, no id)"
                       else: "menu / no GameWorld")
  of "raid":
    result = "raid " & (if gDuGameWorld != nil: "LIVE" else: "not in raid") &
             "   world=0x" & hexOf(cast[uint64](gDuGameWorld))
  of "bots":
    result = "players " & $gDuRegistered & " registered / " & $gDuAiCount &
             " AI / " & $gDuAliveCount & " alive"
  of "pos":
    var ok = false
    var x = 0.0
    var y = 0.0
    var z = 0.0
    duPlayerPos(gDuYou, ok, x, y, z)
    result = "pos " & (if ok: duFmt2(x) & " " & duFmt2(y) & " " & duFmt2(z)
                       else: "-")
  of "rot":
    var ok = false
    var yaw = 0.0
    var pitch = 0.0
    duPlayerRot(gDuYou, ok, yaw, pitch)
    result = "rot yaw " & (if ok: duFmt1(yaw) & "  pitch " & duFmt1(pitch)
                           else: "-")
  of "botlist":
    result = duBotListLine()
  of "frametime":
    if cProfOn() == 0:
      result = "frametime  " & duProfState()
    elif cProfWinUs(1) == 0:
      result = "frametime  profiler ON, no complete window yet"
    else:
      result = "frametime ms  min " & duMsText(int64(cProfWinUs(0)) * 1000) &
               "  p50 " & duMsText(int64(cProfWinUs(2)) * 1000) &
               "  p95 " & duMsText(int64(cProfWinUs(3)) * 1000) &
               "  p99 " & duMsText(int64(cProfWinUs(4)) * 1000) &
               "  max " & duMsText(int64(cProfWinUs(5)) * 1000)
  of "prof":
    let st = duProfState()
    result = "profiler  " &
             (if st.len > 0: st
              else: "window " & $cProfFramesSeen() & " frames seen, " &
                    "scope overhead " & $cProfOverheadNs() & " ns, " &
                    $cProfFaults() & " faults")
  of "prof1": result = duProfLine(0)
  of "prof2": result = duProfLine(1)
  of "prof3": result = duProfLine(2)
  of "prof4": result = duProfLine(3)
  of "prof5": result = duProfLine(4)
  of "prof6": result = duProfLine(5)
  of "prof7": result = duProfLine(6)
  of "prof8": result = duProfLine(7)
  of "note1": result = gDuCfg.note1
  of "note2": result = gDuCfg.note2
  of "note3": result = gDuCfg.note3
  else:
    result = "?" & field

# ===========================================================================
# THE WIDGETS
#
# The panel used to be ONE column: `panelFields` named N fields and the overlay
# stacked N labels under a single anchor. A widget is that idea taken apart --
# an INDEPENDENTLY placed, independently toggleable group of those same fields,
# rendered into ONE label with embedded newlines, and MOVABLE WITH THE MOUSE.
#
# One label per widget, not one per line, and that is what makes dragging cheap
# and correct: a widget is a single rect to hit-test and a single
# `anchoredPosition` to write, so a drag costs the same four managed calls a
# static placement already cost, and a widget can never tear (its lines cannot
# end up half-moved). `duMakeDrawable` already sets word-wrap OFF and overflow
# to Overflow, so a multi-line string is not clipped by the rect it is given.
#
# THE LAYOUT IS RESOLUTION-INDEPENDENT ON PURPOSE. What is persisted is an
# ANCHOR (a corner or edge of the canvas) plus an offset from it -- never a raw
# pixel pair. Dragging a widget to the bottom-right and restarting at a
# different resolution puts it back in the bottom-right, which a stored pixel
# pair would not. That is also why snapping REBINDS the anchor rather than
# nudging the offset: the snap is the thing that makes the stored value mean
# something.
#
# NOTHING HERE ALLOCATES ON THE MANAGED HEAP, and the drag runs on the same
# throttled refresh as the rest of the panel body -- inside the one
# `aowl_p_p_seh` the body already holds. No second guard is armed anywhere in
# this section; see the note on `debugUiBodyImpl`.
# ===========================================================================

# ---------------------------------------------------------------------------
# Loading the widget layout
#
# TWO files, and the split is deliberate:
#
#   `aowlspt-debugui.json`        the USER's file. Hand-edited. Declares which
#                                 widgets exist, their titles and their fields.
#                                 The overlay NEVER writes to it.
#   `aowlspt-debugui-layout.json` the OVERLAY's file. Machine-written on every
#                                 drop. Holds only on/anchor/x/y per widget.
#
# A single file would mean the overlay rewriting the user's comments, ordering
# and field choices every time a widget was nudged. This way a drag can never
# destroy anything a human typed, and deleting the layout file is a clean
# "put everything back where it started".
#
# Both are read with the same shallow flat-key scan the rest of the file uses,
# so the keys are dotted rather than nested (`w.fps.x`, not `{"fps":{"x":..}}`).
# A shallow scanner pointed at a nested schema would happily find an `"x"`
# belonging to a different object, which is a trap, not a convenience.
# ---------------------------------------------------------------------------
proc duLayoutPath(): string = joinPath(gDir, "aowlspt-debugui-layout.json")

proc duLoadWidgets() =
  ## Build `gDuWidgets` from the user file, then apply the saved layout over it.
  ## Called at boot and on every toggle-ON, so both files are live-editable.
  var text = ""
  discard readTextFile(joinPath(gDir, "aowlspt-debugui.json"), text)
  var lay = ""
  let haveLay = readTextFile(duLayoutPath(), lay)

  var order = duCfgStr(text, "widgets",
                       "fps,scene,pos,mem,bots,prof,build,notes")
  var ids = duSplit(order, ',')
  var built: seq[DuWidget] = @[]
  for i in 0 ..< ids.len:
    if built.len >= cDuMaxWidgets:
      break
    let id = duTrim(ids[i])
    if id.len == 0:
      continue
    var title = ""
    var fields = ""
    discard duDefaultWidgetSpec(id, title, fields)
    var w = DuWidget(id: id, title: "", fields: "", on: true,
                     anchor: "topleft", x: 16.0, y: -16.0,
                     w: 0.0, h: 0.0, lines: 0,
                     dragging: false, grabDx: 0.0, grabDy: 0.0)
    duDefaultPlace(id, w.anchor, w.x, w.y)
    # The user file may override title/fields/placement/enabled...
    w.title  = duCfgStr(text, "w." & id & ".title",  title)
    w.fields = duCfgStr(text, "w." & id & ".fields", fields)
    w.on     = duCfgBool(text, "w." & id & ".on", true)
    w.anchor = duCfgStr(text, "w." & id & ".anchor", w.anchor)
    w.x      = duCfgNum(text, "w." & id & ".x", w.x)
    w.y      = duCfgNum(text, "w." & id & ".y", w.y)
    # ...and the SAVED LAYOUT wins over both, because it is the most recent
    # thing the user actually did. Only the four keys a drag can produce are
    # taken from it: a layout file can never redefine what a widget shows.
    if haveLay:
      w.on     = duCfgBool(lay, "w." & id & ".on", w.on)
      w.anchor = duCfgStr(lay,  "w." & id & ".anchor", w.anchor)
      w.x      = duCfgNum(lay,  "w." & id & ".x", w.x)
      w.y      = duCfgNum(lay,  "w." & id & ".y", w.y)
    built.add w
  gDuWidgets = built
  # The fault vector is per-widget and must be the same length, or a fault
  # charged after a config change would retire the wrong widget.
  gDuWidgetFaults = @[]
  for i in 0 ..< built.len:
    gDuWidgetFaults.add 0
  gDuLayoutSource =
    (if haveLay: "aowlspt-debugui-layout.json (saved layout)"
     else: "built-in placement (no layout file yet)")

proc duSaveWidgets() =
  ## Write the layout file. Called ONLY on a drop or a per-widget toggle --
  ## never per frame, never from the render path's hot half. It is a handful of
  ## short lines and one file write, at human speed.
  ##
  ## Writes a WHOLE file, not an edit: there is no partial state a reader can
  ## observe, and a truncated write leaves a file the flat scanner simply finds
  ## no keys in, which falls back to the defaults rather than to nonsense.
  var s = "{\n"
  s.add "  \"_comment\": \"WRITTEN BY THE OVERLAY on every widget drop. " &
        "Safe to delete -- that resets every widget to its built-in corner. " &
        "Which widgets exist, and what they show, lives in " &
        "aowlspt-debugui.json instead; this file only ever holds on/anchor/x/y.\",\n"
  var n = 0
  for i in 0 ..< gDuWidgets.len:
    if n >= cDuMaxWidgets:
      break
    let w = gDuWidgets[i]
    if n > 0:
      s.add ",\n"
    s.add "  \"w." & w.id & ".on\": " & (if w.on: "true" else: "false") &
          ",\n  \"w." & w.id & ".anchor\": \"" & w.anchor &
          "\",\n  \"w." & w.id & ".x\": " & duFmt1(w.x) &
          ",\n  \"w." & w.id & ".y\": " & duFmt1(w.y)
    inc n
  s.add "\n}\n"
  let rc = writeTextFile(duLayoutPath(), s)
  if rc.ok:
    gDuLayoutDirty = false
    okLog "debugui: widget layout saved (" & $n & " widget(s)) -> " &
          duLayoutPath()
  else:
    # A failure to persist must ANNOUNCE itself. Silently losing a layout the
    # user just arranged is exactly the "declined quietly" failure this project
    # treats as the worst outcome available.
    warn "debugui: could NOT write the widget layout to " & duLayoutPath() &
         " -- the arrangement is live but will not survive a restart"

# ---------------------------------------------------------------------------
# Geometry
#
# Three coordinate systems meet here and getting them confused is the whole
# difficulty, so they are named every time:
#
#   CLIENT PIXELS   what `GetCursorPos` + `ScreenToClient` give. Origin TOP-left,
#                   Y grows DOWN.
#   CANVAS UNITS    what `wgeom.nim` works in. Origin BOTTOM-left, Y grows UP,
#                   because that is Unity's convention and wgeom is the one
#                   part of this feature that never failed -- it was left
#                   untouched by the move to the D3D overlay, and its 208-check
#                   offline test still passes unmodified.
#   ANCHORED        the offset the widget stores: canvas units relative to its
#                   anchor point, with its pivot deciding which corner sits
#                   there. This is what is PERSISTED, never a pixel pair, which
#                   is what makes a saved layout survive a resolution change.
#
# One canvas unit IS one back-buffer pixel now. There is no CanvasScaler in the
# path any more, so the only conversion left is the Y flip, in `duPx`.
# ---------------------------------------------------------------------------

proc duCanvasSize(cw, ch: var float64): bool =
  ## THE SCREEN, FROM THE REGION'S OWN PUBLISHED MEASUREMENT.
  ##
  ## `aowl_region_screen_*` is measured once a frame from the game window's
  ## client rect by `region.nim` and is the SAME size the overlay's back buffer
  ## has, which is what makes a snap land where the pixel does. It is never a
  ## constant and never assumed: `known` is a genuine third answer, and a
  ## not-yet-measured screen is refused here rather than flattened into 0x0 --
  ## snapping against a zero canvas drags every widget to the origin.
  ##
  ## A canvas unit IS a back-buffer pixel now: the TextMeshPro CanvasScaler that
  ## used to divide this down is not in the path any more.
  if cWgScrKnown() == 0'i32:
    return false
  let pw = float64(cWgScrW())
  let ph = float64(cWgScrH())
  if pw < 16.0 or ph < 16.0:
    return false
  cw = pw
  ch = ph
  true

proc duCursorCanvas(cx, cy: var float64): bool =
  ## The cursor in canvas units, Y-up. False unless the sample is inside our own
  ## client area this refresh.
  if cWgMouseOk() == 0'i32:
    return false
  var cw = 0.0
  var ch = 0.0
  if not duCanvasSize(cw, ch):
    return false
  cx = float64(cWgMouseX())
  cy = ch - float64(cWgMouseY())
  true

proc duPx(cy, ch: float64): float32 =
  ## THE ONE FLIP. `wgeom.nim` is Unity's Y-up canvas; the overlay is Y-down
  ## pixels. Keeping the conversion to a single named proc is why wgeom did not
  ## have to change at all -- it is the one part of this feature that never
  ## failed and its 208-check offline test still passes untouched.
  float32(ch - cy)

# ---------------------------------------------------------------------------
# The drag
#
# EDIT MODE IS ITS OWN STATE, and default OFF within an already-visible panel.
# Without it, a left click anywhere the overlay happens to sit would grab a
# widget instead of shooting -- so the overlay would be changing what the mouse
# does in a raid, which is exactly the kind of write into game behaviour this
# file is otherwise careful never to make. In edit mode the overlay still
# SWALLOWS NOTHING: it does not hook input and cannot consume the click; it just
# also moves a widget. That is stated plainly on the edit-mode banner.
#
# Ctrl+F3 toggles it. Same key as the panel, plus a modifier read from the same
# async table, so there is no second key to document or collide with.
# ---------------------------------------------------------------------------
proc duDragTick() =
  ## THE ADAPTER. Everything impure happens here and nothing else does:
  ## sample the canvas and the pointer, hand the pure state machine in
  ## `wgeom.nim` a plain set of numbers, and persist when it says a drop
  ## happened. The decision, the hit test and the arithmetic are all in
  ## `duDragStep`, which `tests/wgeom_test.nim` drives with no client.
  ##
  ## WHICH INPUT SOURCE, AND WHY IT IS NOT THE F12 PANEL'S.
  ## The F12 panel reads the mouse from the overlay's hooked WndProc
  ## (`WM_LBUTTONDOWN`/`WM_MOUSEMOVE`/`WM_INPUT` -> `g_ov.clickDown`,
  ## `g_ov.mouseHeld`, `g_ov.mx/my`). That source is wrong here for two
  ## measured reasons, not one:
  ##
  ##   1. It is gated on `g_ov.visible` -- the whole mouse block in
  ##      `aowl_ov_wndproc` is inside `if (g_ov.visible)`. The F3 widgets are a
  ##      separate overlay with a separate key, so with the F12 panel closed
  ##      that source publishes NOTHING and a drag would silently never start.
  ##   2. Every one of those cases `return 0` -- it SWALLOWS the message. That
  ##      is correct for a modal settings panel and completely wrong for F3,
  ##      whose banner promises the click still reaches the game. Routing the
  ##      widget drag through it would take the left mouse button away from the
  ##      player for as long as edit mode is on.
  ##
  ## So this keeps the polled source in `abi/aowlspt_widget.h`:
  ## `GetCursorPos` + `GetAsyncKeyState(VK_LBUTTON)`, sampled exactly once per
  ## frame in `duRegionDraw` before anything reads it. It consumes nothing, it
  ## needs no second hook on a window another feature already subclasses, and
  ## it is gated on our own process owning the foreground, so it cannot move a
  ## widget while the player is alt-tabbed. Its one honest limitation is that a
  ## raid CLIPS the cursor, so absolute positions there are pinned -- edit mode
  ## is a menu activity and the banner does not claim otherwise.
  # EDIT MODE OFF IS THE COMMON CASE AND MUST COST WHAT IT COST BEFORE. The
  # early-out is here, ahead of the canvas and cursor reads, so an open panel
  # that is not being edited does exactly the same work per frame as it did
  # before the drag was wired up: nothing. The machine still gets to decide what
  # a drag in progress means, so the release path is the tested one rather than
  # a second copy written out here.
  if not gDuEdit:
    if duDragActive():
      discard duDragStep(false, false, 0.0, 0.0, 1.0, 1.0, false, false, false)
    return
  var cw = 0.0
  var ch = 0.0
  if not duCanvasSize(cw, ch):
    # No measured screen. Do NOT step the machine against a zero canvas; drop
    # any drag in progress instead of snapping every widget to the origin.
    if duDragActive():
      duDragRelease()
    return
  var cx = 0.0
  var cy = 0.0
  let haveCursor = duCursorCanvas(cx, cy)
  let rc = duDragStep(gDuEdit, haveCursor, cx, cy, cw, ch,
                      cWgLmbPressed() != 0'i32,
                      cWgLmbHeld() != 0'i32,
                      cWgLmbReleased() != 0'i32)
  if rc == duDragDropped:
    # The ONLY impure consequence, and it happens at human speed -- once per
    # drop, never per frame.
    duSaveWidgets()

# ---------------------------------------------------------------------------
# The PROFILER widget: budget vs actual, per region participant
#
# SOURCED FROM THE ACCOUNTING THAT ALREADY EXISTS. `abi/aowlspt_region.h`'s
# dispatcher already times every participant it calls and compares that against
# the budget the participant declared at registration; it already counts
# overruns, faults, and the frames it skipped a participant for. That is exactly
# the ModProfiler read-out, and it is already being computed on every frame the
# region is armed.
#
# So this adds NO detour, NO timer, NO instrumentation of any kind: it calls
# `aowl_region_status_x` -- the export `region.nim` already publishes for mods --
# and formats what comes back. A second detour on the same function overwrites
# the first's trampoline, and a second timer would be measuring the same work
# twice; riding the existing accounting avoids both.
#
# WHAT IT WILL NOT DO IS INVENT A NUMBER. A participant that has never been
# called shows `--`, not `0.00`. A region that is not armed says so instead of
# rendering an empty table that reads as "nothing is costing anything".
# ---------------------------------------------------------------------------
proc duUsText(us: int64): string =
  ## Microseconds as milliseconds, three decimals. `-1` is "not measured" and
  ## renders as `--`; it must never render as 0.000, which reads as "free".
  if us < 0:
    return "--"
  formatFloat(float64(us) / 1000.0, ffDecimal, 3)

proc duRegionLines(maxRows: int): string =
  ## The participant table. One row per LIVE participant, capped by `maxRows`
  ## and, independently, by the region's own compile-time slot ceiling -- so a
  ## corrupt count cannot make this loop.
  if cWgRgArmed() == 0'i32:
    return "region NOT ARMED -- no per-mod timing is being collected.\n" &
           "  (host flag `sharedRegion`; participants may still be registered)"
  var res = ""
  var rows = 0
  var slots = int(cWgRgMax())
  if slots > 64: slots = 64            # a cap on the cap
  var h = 0
  while h < slots:
    if rows >= maxRows:
      res.add "\n  ... more participants than rows; raise this widget's cap"
      break
    if cWgRgSelect(int32(h)) != 0'i32:
      let nm = $cWgRgNameC()
      let bud = cWgRgBudget()
      let last = cWgRgLast()
      let mx = cWgRgMaxUs()
      let calls = cWgRgCalls()
      var flag = ""
      if cWgRgDisabled() != 0'i32: flag = "  [DISABLED]"
      elif cWgRgThrottled() != 0'i32: flag = "  [THROTTLED]"
      elif cWgRgEnabled() == 0'i32: flag = "  [off]"
      elif last >= 0 and bud > 0 and last > bud: flag = "  [OVER]"
      if rows > 0:
        res.add "\n"
      # Never called yet is a DIFFERENT state from called and fast. Saying
      # `--` for both would make a participant that has never run look cheap.
      let lastTxt = (if calls <= 0: "--" else: duUsText(last))
      let maxTxt  = (if calls <= 0: "--" else: duUsText(mx))
      res.add "  " & nm & "  " & lastTxt & " / " & duUsText(bud) &
              " ms  peak " & maxTxt & "  x" & $calls
      if cWgRgSkipped() > 0:
        res.add "  skip " & $cWgRgSkipped()
      if cWgRgOverruns() > 0:
        res.add "  over " & $cWgRgOverruns()
      if cWgRgFaults() > 0:
        res.add "  FAULTS " & $cWgRgFaults()
      res.add flag
      inc rows
    inc h
  if rows == 0:
    return "region ARMED, but NO participant is registered.\n" &
           "  (that is not 'nothing is slow' -- it is 'nothing is measured')"
  "  name  last / budget ms  peak  calls\n" & res

proc duMemLine(): string =
  ## Process working set and private bytes, and the machine's load. `-1` from
  ## the sampler means the API did not resolve, which prints as `unavailable`
  ## rather than as a zero.
  cWgMemSample()
  let ws = cWgWs()
  let pv = cWgPriv()
  if ws < 0 and pv < 0:
    return "mem  unavailable (K32GetProcessMemoryInfo did not resolve)"
  var s = "mem  ws " & (if ws < 0: "--" else: $ws & " MB") &
          "   private " & (if pv < 0: "--" else: $pv & " MB")
  if cWgSysLoad() >= 0:
    s.add "\n     system " & $cWgSysLoad() & "% used, " &
          $cWgSysFree() & " MB free"
  s


# ---------------------------------------------------------------------------
# COMPOSING A WIDGET'S TEXT
#
# One widget is one newline-separated string, and the caller turns each line
# into ONE region TEXT command. `lineCount` and `widest` come back so the caller
# can size the widget's box, and that box is now EXACT rather than estimated:
# the overlay's font is a fixed 8x16 cell, so `widest * 8 * scale` is the real
# rendered width. The old path had to guess (TMP's real bounds are behind
# struct-returning calls this file never byte-verified, and `ForceMeshUpdate` on
# this build is the universal empty-body stub), and a guessed grab box that does
# not match what is on screen is a drag that misses.
#
# Embedded newlines are counted, not just the field count: `region` and
# `botlist` are ONE field and MANY lines, and a height taken from the field
# count gave the profiler widget a grab box one line tall.
# ---------------------------------------------------------------------------
proc duWidgetText(w: DuWidget; lineCount: var int; widest: var int): string =
  var res = ""
  lineCount = 0
  widest = 0
  var cur = 0
  if w.title.len > 0:
    res.add w.title
    lineCount = 1
    widest = w.title.len
  let fields = duSplit(w.fields, ',')
  var used = 0
  for i in 0 ..< fields.len:
    if lineCount >= cDuMaxWidgetLines:
      break
    let f = duTrim(fields[i])
    if f.len == 0:
      continue
    var text = ""
    # The two fields only a widget can produce. Everything else is the SAME
    # `duPanelLine` the single-column panel used, so no field regressed.
    if f == "region":
      text = duRegionLines(cDuMaxWidgetLines - lineCount - 1)
    elif f == "stages":
      text = duStagesLine(cDuMaxWidgetLines - lineCount - 1)
    elif f == "mem":
      text = duMemLine()
    else:
      text = duPanelLine(f)
    if text.len == 0:
      continue
    if lineCount > 0:
      res.add "\n"
    res.add text
    inc used
    # Count the embedded newlines too: `region` and `botlist` are one FIELD but
    # many LINES, and a height computed from the field count would give the
    # profiler widget a grab box one line tall.
    cur = 0
    for k in 0 ..< text.len:
      if text[k] == '\n':
        inc lineCount
        if cur > widest: widest = cur
        cur = 0
      else:
        inc cur
    if cur > widest: widest = cur
    inc lineCount
  if used == 0 and w.title.len == 0:
    res = "?" & w.id
    lineCount = 1
    widest = res.len
  res

## THE COLOURS. Packed 0xAABBGGRR, matching `AOWL_RGBA` and the overlay's
## vertex colour. Plain constants because the region command carries a colour
## per command and nothing here reads a theme.
proc duRgba(r, g, b, a: int): uint32 =
  uint32(r and 255) or (uint32(g and 255) shl 8) or
  (uint32(b and 255) shl 16) or (uint32(a and 255) shl 24)

proc duCfgColour(): uint32 =
  duRgba(int(gDuCfg.panelR * 255.0), int(gDuCfg.panelG * 255.0),
         int(gDuCfg.panelB * 255.0), 255)

proc duTextScale(ch: float64): int32 =
  ## The integer font scale, chosen by the SAME rule the overlay's own panel and
  ## the F6 menu use, so all three read at the same size on one screen. An 8x16
  ## cell is unreadable at 2160p, which is the only reason this exists.
  if ch >= 2500.0: 3'i32
  elif ch >= 1300.0: 2'i32
  else: 1'i32

## ONE FIXED LINE BUFFER, refilled per command. Not a `toCString`: that
## allocates, and this runs several dozen times per frame inside a per-frame
## callback. File-scope and fixed-size, so there is no allocation on the draw
## path at all and the length is bounded by a compile-time constant.
var gDuLineBuf: array[cDuCmdText + 1, char]

proc duEmitLine(x, y: float32; s: string; col: uint32; scale: int32) =
  ## One TEXT command. A line longer than the command's inline buffer is
  ## truncated AND MARKED with a trailing '>', because a read-out that quietly
  ## loses its right-hand column looks exactly like one telling the truth.
  if s.len == 0:
    return
  var n = s.len
  var cut = false
  if n > cDuCmdText:
    n = cDuCmdText - 1
    cut = true
  for i in 0 ..< n:
    gDuLineBuf[i] = s[i]
  if cut:
    gDuLineBuf[n] = '>'
    gDuLineBuf[n + 1] = chr(0)
  else:
    gDuLineBuf[n] = chr(0)
  discard cWgDrText(x, y, cast[cstring](addr gDuLineBuf[0]), col, scale)

# ---------------------------------------------------------------------------
# THE COMPOSITION CACHE
#
# THE DEFECT THIS FIXES, stated as measured behaviour: `debugui` was reported by
# the region's own accounting at 22,000-40,000 us against a 900 us budget, every
# frame, sustained, with the peak CLIMBING. `panelThrottle` was supposed to be
# the answer to exactly that -- but it gated ONLY `duScanWorld`. Everything
# downstream of it ran at full frame rate, and everything downstream of it is
# the expensive half:
#
#   * `duWidgetText` splits `fields` into a fresh `seq[string]` and builds a
#     fresh `string` per widget PER FRAME -- a per-frame managed allocation,
#     which CLAUDE.md 5 forbids outright.
#   * the `mem` field calls `K32GetProcessMemoryInfo` and `GlobalMemoryStatusEx`
#     through `cWgMemSample()` -- two Win32 calls, per frame.
#   * the `region` field loops up to 64 participant slots and builds a table.
#   * the `map` field reads a managed string out of GameWorld.
#   * the `botlist` field walks the bot snapshot -- which GROWS as a raid fills
#     with bots, which is the shape of a peak that climbs.
#
# None of that is per-frame INFORMATION: the numbers behind it only change when
# `duScanWorld` runs, which is every `panelThrottle`th frame. Composing it every
# frame was work whose output was, by construction, usually identical.
#
# So the composed text is cached per widget and recomposed on a cadence, while
# SUBMISSION stays every frame -- the command buffer is rebuilt from empty each
# frame, so throttling submission would flicker the panel off. Recomposition is
# STAGGERED by widget index (`(gDuFires + i) mod cadence`) so the cost is spread
# rather than landing as one spike every Nth frame.
#
# Edit mode recomposes every frame on purpose: the extent is the drag hit-box,
# and a hit-box computed from stale text is a drag that misses.
var gDuWText: seq[string] = @[]
var gDuWLines: seq[int] = @[]
var gDuWWidest: seq[int] = @[]
var gDuWStamp: seq[int] = @[]      ## `gDuFires` at composition; -1 = never

## THE SELF-THROTTLE. A participant that overruns its budget hundreds of times
## in a row must DEGRADE, not keep costing 40 ms: the F3 window has to be usable
## while playing, and an instrument that is itself the largest cost in the frame
## is measuring mostly itself. This raises only the RECOMPOSITION cadence -- the
## panel keeps drawing every frame, its numbers just refresh less often -- and
## it recovers on its own once the cost fits again.
const cDuBudgetUs   = 900'i64    ## declared at registration; kept in step here
const cDuOverStreak = 30         ## consecutive over-budget refreshes to act on
const cDuCadenceCap = 120        ## never slower than this, whatever happens
var gDuCadence = 0               ## 0 = follow the config alone
var gDuOverStreak = 0
var gDuUnderStreak = 0
var gDuThrottleSaid = 0

proc duCadence(): int =
  ## The effective recomposition cadence: the configured throttle, or the
  ## self-imposed one if the overlay has had to slow itself down.
  result = gDuCfg.panelThrottle
  if result < 1: result = 1
  if gDuCadence > result: result = gDuCadence

proc duThrottleTick() =
  ## Read back what the STAGE ACCOUNTING measured for the refresh that just
  ## finished and react to it. This asserts a property of the finished frame --
  ## its measured cost -- not a property of anything this code just did, so it
  ## can fail: if the cost fits, the streak resets and the cadence winds back.
  let us = cWgStageFrameUs()
  if us < 0:
    return                        # not measured yet: not an overrun, not a fit
  if us > cDuBudgetUs:
    inc gDuOverStreak
    gDuUnderStreak = 0
    if gDuOverStreak >= cDuOverStreak:
      gDuOverStreak = 0
      let was = duCadence()
      var next = was * 2
      if next > cDuCadenceCap: next = cDuCadenceCap
      if next > was:
        gDuCadence = next
        if gDuThrottleSaid < 3:
          inc gDuThrottleSaid
          warn "debugui: the F3 refresh measured " & $us & " us against a " &
               $cDuBudgetUs & " us budget for " & $cDuOverStreak &
               " refreshes running, so it has SLOWED ITSELF DOWN -- widget " &
               "text now recomposes every " & $next & " frames instead of " &
               $was & ". The panel still draws every frame; only its numbers " &
               "refresh less often. `stages` names where the time went."
  else:
    gDuOverStreak = 0
    inc gDuUnderStreak
    # Wind back only after a long, quiet run, so a single cheap frame cannot
    # undo a throttle that a sustained overrun earned.
    if gDuUnderStreak >= 600 and gDuCadence > 0:
      gDuUnderStreak = 0
      gDuCadence = gDuCadence div 2
      if gDuCadence <= gDuCfg.panelThrottle:
        gDuCadence = 0
      okLog "debugui: the F3 refresh has fitted its " & $cDuBudgetUs &
            " us budget for 600 refreshes, so the self-imposed throttle is " &
            "being wound back (cadence now " & $duCadence() & " frames)"

proc duDrawWidgets() =
  ## Lay out and SUBMIT every enabled widget. Called from inside the region's
  ## DRAW callback and nowhere else: `aowl_region_push` refuses outside one, so
  ## a stray call cannot add geometry to somebody else's frame.
  ##
  ## NO GUARD IS OPENED HERE. The region dispatcher already wraps each
  ## participant callback in the ONE `aowl_p_p_seh`, and that guard is not
  ## re-entrant -- a guard here would DISARM it rather than add anything.
  var cw = 0.0
  var ch = 0.0
  if not duCanvasSize(cw, ch):
    return                      # screen not measured yet: draw nothing rather
                                # than guess a size
  let scale = duTextScale(ch)
  let cellW = cDuCellW * float64(scale)
  let cellH = cDuCellH * float64(scale)
  let base = duCfgColour()
  # Keep the cache the same shape as the widget list. A reload rebuilds
  # `gDuWidgets` wholesale, so any length change means every cached entry is
  # suspect and the whole cache is dropped rather than re-indexed.
  if gDuWText.len != gDuWidgets.len:
    gDuWText = @[]
    gDuWLines = @[]
    gDuWWidest = @[]
    gDuWStamp = @[]
    for _ in 0 ..< gDuWidgets.len:
      gDuWText.add ""
      gDuWLines.add 0
      gDuWWidest.add 0
      gDuWStamp.add -1
  let cadence = duCadence()
  var drawn = 0
  for i in 0 ..< gDuWidgets.len:
    if drawn >= cDuMaxWidgets:
      break
    if not gDuWidgets[i].on:
      continue
    # A widget already charged with `cDuWidgetFaultLimit` faults is skipped
    # entirely. This is what keeps one bad widget from taking the rest dark.
    if i < gDuWidgetFaults.len and gDuWidgetFaults[i] >= cDuWidgetFaultLimit:
      continue
    cWgCrumbW(int32(i))
    cWgCrumb(WgCrumbWText)
    # RECOMPOSE, OR REUSE. Staggered by index so N widgets do not all rebuild
    # on the same frame. Edit mode always recomposes: the extent doubles as the
    # drag hit-box and a stale hit-box is a drag that misses.
    if gDuWStamp[i] < 0 or gDuEdit or
       ((gDuFires + i) mod cadence) == 0:
      var nl = 0
      var nw = 0
      gDuWText[i] = duWidgetText(gDuWidgets[i], nl, nw)
      if nw > cDuCmdText: nw = cDuCmdText
      gDuWLines[i] = nl
      gDuWWidest[i] = nw
      gDuWStamp[i] = gDuFires
    let text = gDuWText[i]
    let lines = gDuWLines[i]
    let widest = gDuWWidest[i]
    # THE EXTENT IS NOW EXACT, not estimated. The overlay's font is a fixed
    # 8x16 cell, so the box the user grabs is the box that is on screen -- the
    # old estimate against TMP's unknown metrics is gone with it.
    gDuWidgets[i].lines = lines
    gDuWidgets[i].w = float64(widest) * cellW + 8.0
    gDuWidgets[i].h = float64(lines) * cellH + 6.0
    duClampOnScreen(i, cw, ch)
    cWgCrumb(WgCrumbWPlace)
    var l = 0.0
    var t = 0.0
    var r = 0.0
    var b = 0.0
    duWidgetRect(gDuWidgets[i], cw, ch, l, t, r, b)
    let px = float32(l)
    let py = duPx(t, ch)
    cWgCrumb(WgCrumbWStyle)
    # A BACKING PLATE, so pale text on a pale loading screen is still readable.
    # Drawn first; the region rasterises commands in SUBMISSION ORDER, which is
    # the only ordering guarantee this path needs -- and it is a guarantee,
    # unlike a Unity canvas sort order.
    discard cWgDrFill(px, py, float32(gDuWidgets[i].w),
                      float32(gDuWidgets[i].h), duRgba(8, 10, 14, 170))
    var col = base
    if gDuEdit and gDuWidgets[i].dragging:
      col = duRgba(115, 255, 115, 255)
      discard cWgDrBox(px, py, float32(gDuWidgets[i].w),
                       float32(gDuWidgets[i].h), 2.0'f32,
                       duRgba(115, 255, 115, 255))
    elif gDuEdit:
      col = duRgba(153, 217, 255, 255)
      discard cWgDrBox(px, py, float32(gDuWidgets[i].w),
                       float32(gDuWidgets[i].h), 1.0'f32,
                       duRgba(153, 217, 255, 200))
    cWgCrumb(WgCrumbWSetText)
    # ONE COMMAND PER LINE. The command carries its text inline (no lifetime
    # question) and is capped at `AOWL_REGION_TEXT_LEN`, so a multi-line widget
    # is many commands -- bounded by `cDuMaxWidgetLines`, which is why one
    # widget cannot exhaust the frame's command budget.
    var row = 0
    var start = 0
    var k = 0
    while k <= text.len and row < cDuMaxWidgetLines:
      if k == text.len or text[k] == '\n':
        duEmitLine(px + 4.0'f32, py + 3.0'f32 + float32(float64(row) * cellH),
                   text[start ..< k], col, scale)
        inc row
        start = k + 1
      inc k
    cWgCrumb(WgCrumbWShow)
    inc drawn
  cWgCrumbW(-1'i32)
  # THE EDIT-MODE BANNER. Edit mode changes what a left click does, and an
  # invisible mode that does that is the worst kind -- so it says what is on,
  # what the keys are, and that the click is NOT taken from the game.
  cWgCrumb(WgCrumbBanner)
  if gDuEdit:
    var bl: seq[string] = @[
      "EDIT MODE -- drag a widget with the left mouse button",
      "Ctrl+F3 leave   1-9 toggle a widget   0 reset all",
      "drops snap to edges, corners and to other widgets,",
      "and are saved to aowlspt-debugui-layout.json on drop.",
      "The overlay does NOT swallow the click."]
    var names = "widgets: "
    var n = 0
    for i in 0 ..< gDuWidgets.len:
      if n >= 9:
        break
      if n > 0: names.add " "
      names.add $(n + 1) & "=" & gDuWidgets[i].id &
                (if gDuWidgets[i].on: "" else: "-off")
      inc n
    bl.add names
    bl.add "layout from " & gDuLayoutSource
    let bx = float32(cw * 0.5 - 27.0 * cellW)
    let by = float32(ch - 8.0 - float64(bl.len) * cellH)
    discard cWgDrFill(bx - 4.0'f32, by - 3.0'f32, float32(56.0 * cellW),
                      float32(float64(bl.len) * cellH + 6.0),
                      duRgba(8, 10, 14, 190))
    for i in 0 ..< bl.len:
      duEmitLine(bx, by + float32(float64(i) * cellH), bl[i],
                 duRgba(255, 217, 89, 255), scale)
  # NOTHING TO HIDE. The command buffer is rebuilt from empty every frame, so a
  # widget switched off simply stops being submitted. There is no label pool to
  # blank and therefore no way to leave stale text on screen -- a whole class of
  # bug that only existed because the clone path had persistent objects.

# ---------------------------------------------------------------------------
# THE IN-WORLD MARKERS
#
# Same projection as before -- `Camera.main.WorldToScreenPoint` -- but the
# result now goes straight out as a region TEXT command instead of into a cloned
# label. Unity's screen point has its ORIGIN AT THE BOTTOM-LEFT and a `z` that
# is the distance in front of the camera, so `z <= 0` is BEHIND the camera and
# the marker must be dropped; drawing those is the classic ESP ghost bug.
# ---------------------------------------------------------------------------
## THE CAMERA, RESOLVED ON A CADENCE RATHER THAN EVERY FRAME.
##
## `Camera.get_main` is not a field read. On this Unity generation it resolves
## the main camera by TAG, and the cost of that grows with the number of objects
## in the scene -- which is precisely the shape of an overlay cost that climbs
## through a raid as bots and loot spawn. Whether it is THE cost here is a
## question for the `stages` read-out, which now charges it to "the ESP
## markers"; caching it is defensible either way, because a per-frame IL2CPP
## call with an unbounded internal cost has no business on a draw path.
##
## The pointer is re-resolved every `cDuCamRefresh` refreshes and dropped the
## moment it stops reading back, so a camera torn down at the end of a raid is
## never projected against. A failed resolve is remembered as a failed ATTEMPT,
## not retried every frame.
const cDuCamRefresh = 120
var gDuCam: Il2CppPtr = nil
var gDuCamAt = -1000000

proc duCamera(fnCam: Il2CppPtr): Il2CppPtr =
  if (gDuFires - gDuCamAt) >= cDuCamRefresh or
     (gDuCam != nil and not duOk(gDuCam, 0x20'i32)):
    gDuCam = cDuCallPV(fnCam)
    gDuCamAt = gDuFires
    if not duOk(gDuCam, 0x20'i32):
      gDuCam = nil
  gDuCam

## The ESP field list, split ONCE per config load instead of once per frame.
## `duSplit` returns a fresh `seq[string]`; doing it inside the marker loop's
## caller was a per-frame managed allocation on the draw path.
var gDuEspWant: seq[string] = @[]
var gDuEspWantOf = "\x00"

proc duEspFields(): seq[string] =
  if gDuEspWantOf != gDuCfg.espFields:
    gDuEspWant = duSplit(gDuCfg.espFields, ',')
    gDuEspWantOf = gDuCfg.espFields
  gDuEspWant

proc duDrawMarkers(): bool =
  ## False means projection is UNAVAILABLE on this build -- a third answer, not
  ## "nothing to draw" -- so the caller can say so once.
  let fnCam = cDuFn(DuCameraMain)
  let fnW2S = cDuFn(DuWorldToScreen)
  if fnCam == nil or fnW2S == nil:
    return false
  var cw = 0.0
  var ch = 0.0
  if not duCanvasSize(cw, ch):
    return true                 # no measured screen yet; not a build problem
  let cam = duCamera(fnCam)
  if cam == nil or not duOk(cam, 0x20'i32):
    return true                 # menu or loading screen: not an error
  var eyeOk = false
  var ex = 0.0
  var ey = 0.0
  var ez = 0.0
  duPlayerPos(gDuYou, eyeOk, ex, ey, ez)
  let want = duEspFields()
  let scale = duTextScale(ch)
  var used = 0
  for i in 0 ..< gDuBots.len:
    if used >= cDuMaxMarkers:
      break
    let b = gDuBots[i]
    if not b.posOk:
      continue
    var dist = 0.0
    if eyeOk:
      dist = duDistance(ex, ey, ez, b.x, b.y, b.z)
      if gDuCfg.espMaxDist > 0.0 and dist > gDuCfg.espMaxDist:
        continue
    if cDuWorldToScreen(fnW2S, cam, b.x, b.y, b.z) == 0'i32:
      continue
    if cDuScreenZ() <= 0.0:
      continue                  # behind the camera
    var text = ""
    for w in want:
      if text.len > 0: text.add " "
      case w
      of "role": text.add duRoleName(b.role)
      of "nick": text.add (if b.nick.len > 0: b.nick else: "?")
      of "dist": text.add duFmt0(dist) & "m"
      of "pos":  text.add "(" & duFmt0(b.x) & "," & duFmt0(b.z) & ")"
      else: discard
    if not b.alive:
      text.add " [dead]"
    # Unity's screen point is bottom-origin; the overlay is top-origin. The same
    # single flip as the widgets, through the same proc.
    duEmitLine(float32(cDuScreenX()),
               duPx(cDuScreenY() + gDuCfg.espY, ch),
               text, duRgba(255, 190, 80, 255), scale)
    inc used
  true

# ---------------------------------------------------------------------------
# Edit-mode keys
#
# Number keys 1..9 toggle a widget, 0 puts every widget back where it started.
# Read from the SAME async edge detector the toggle key uses and only while edit
# mode is on and the game has the foreground, so a number typed anywhere else --
# including into the game -- can never move a widget.
# ---------------------------------------------------------------------------
proc duEditKeys() =
  if not gDuEdit:
    return
  var i = 0
  while i < 9 and i < gDuWidgets.len:
    if cDuKeyEdge(int32(0x31 + i)) != 0'i32:
      gDuWidgets[i].on = not gDuWidgets[i].on
      okLog "debugui: widget '" & gDuWidgets[i].id & "' " &
            (if gDuWidgets[i].on: "ON" else: "OFF")
      duSaveWidgets()
    inc i
  if cDuKeyEdge(0x30'i32) != 0'i32:
    for j in 0 ..< gDuWidgets.len:
      gDuWidgets[j].on = true
      duDefaultPlace(gDuWidgets[j].id, gDuWidgets[j].anchor,
                     gDuWidgets[j].x, gDuWidgets[j].y)
    okLog "debugui: every widget reset to its built-in placement and enabled"
    duSaveWidgets()

proc duDescribeVec2(target: int32; self: Il2CppPtr): string =
  var ok = false
  var x = 0.0
  var y = 0.0
  duGetVec2(target, self, ok, x, y)
  result = (if ok: "(" & duFmt1(x) & "," & duFmt1(y) & ")" else: "?")

proc duDescribeVec3(target: int32; self: Il2CppPtr): string =
  var ok = false
  duGetSret(target, self, 3'i32, ok)
  result = (if ok: "(" & duFmt2(cDuSret0()) & "," & duFmt2(cDuSret1()) & "," &
                   duFmt2(cDuSret2()) & ")" else: "?")

proc duDescribeRect(self: Il2CppPtr): string =
  var ok = false
  duGetSret(DuGetRect, self, 4'i32, ok)
  result = (if ok: "x=" & duFmt1(cDuSret0()) & " y=" & duFmt1(cDuSret1()) &
                   " w=" & duFmt1(cDuSret2()) & " h=" & duFmt1(cDuSret3())
            else: "?")

proc duDescribeInt(target: int32; self: Il2CppPtr): string =
  var ok = false
  let v = duGetInt(target, self, ok)
  result = (if ok: $int(v) else: "?")

proc duDescribeScale(canvas: Il2CppPtr): string =
  let fn = cDuFn(DuCanvasScale)
  if fn == nil or not duOk(canvas, 0x20'i32):
    return "?"
  result = duFmt2(cDuCallFP(fn, canvas))

proc duDescribeScreen(): string =
  let fw = mi2Fn(Mi2ScreenWidth)
  let fh = mi2Fn(Mi2ScreenHeight)
  if fw == nil or fh == nil:
    return "?"
  result = $int(cMi2CallIV(fw)) & "x" & $int(cMi2CallIV(fh))

proc duReadI32Field(p: Il2CppPtr; off: int32): int32 =
  ## A guarded int32 read at a managed field offset, or -1. `-1` is not a legal
  ## value for any field this dump prints, so it reads as "could not look".
  result = -1'i32
  if duOk(p, off + 4'i32):
    result = cReadI32At(duPtrAdd(p, off))

proc duReadBoolField(p: Il2CppPtr; off: int32): int32 =
  result = -1'i32
  if duOk(p, off + 4'i32):
    result = cReadI32At(duPtrAdd(p, off)) and 1'i32

proc duReadPtrField(p: Il2CppPtr; off: int32): Il2CppPtr =
  result = nil
  if duOk(p, off + 8'i32):
    result = cReadPtrAt(p, off)

proc duReadF32Field(p: Il2CppPtr; off: int32): float64 =
  result = 0.0
  if duOk(p, off + 4'i32):
    result = cReadF32At(duPtrAdd(p, off))

## Where the clones were actually parented, and by which route. Logged once, so
## the next run can be read rather than reasoned about.
# ---------------------------------------------------------------------------
# The per-frame body
#
# Prefix detour on `EFT.UI.PreloaderUI::Update`, Unity thread. Everything below
# runs inside ONE VEH/setjmp guard (`aowl_du_body_guarded`).
# ---------------------------------------------------------------------------
var gDuEspUnavailableLogged = false

proc debugUiBodyImpl(a: Il2CppPtr): Il2CppPtr {.
    exportc: "aowl_du_body", cdecl.} =
  let regs = a
  # THE TRAIL STARTS HERE, and is cleared on every body, so a stale crumb from a
  # previous refresh can never be reported as this refresh's fault site.
  cWgCrumb(WgCrumbEnter)
  cWgCrumbW(-1'i32)
  let tid = int(cThreadId())
  inc gDuFires
  cDuFpsSample()
  if tid == int(gHostThreadId):
    # Not Unity's thread: refuse outright rather than touch a managed object.
    return cast[Il2CppPtr](1)
  # RCX = the PreloaderUI `this`. It is still checked, because a detour firing
  # with a null receiver means the slot is not what we think it is -- but it is
  # no longer USED: nothing on this path walks the UI tree any more.
  if cRegsInt(regs, 0'i32) == 0'u64:
    return cast[Il2CppPtr](1)
  if not gDuLoggedOnce:
    gDuLoggedOnce = true
    okLog "debugui: PreloaderUI::Update detour is live on thread " & $tid &
          " (host thread " & $int(gHostThreadId) & " -- so this is Unity's). " &
          $int(cDuOkCount()) & " of " & $int(cDuTargetCount()) &
          " managed targets verified by RVA + prologue" &
          (if cDuBadCount() > 0'i32: " (" & $int(cDuBadCount()) & " rejected)"
           else: "") & ". Press the toggle key to show the panel."

  # The toggle, edge-detected in C and ignored unless the game has the
  # foreground -- otherwise an F3 typed into an editor on the other monitor
  # would toggle the overlay.
  cWgCrumb(WgCrumbToggle)
  if cDuForeground() != 0'i32:
    if gDuCfg.toggleVk > 0 and
       cDuKeyEdge(int32(gDuCfg.toggleVk)) != 0'i32:
      # WHICH ROUTE ACTUALLY SAW THE KEY -- measured, once, rather than assumed.
      # The F10 bug in the D3D overlay was a key that never arrived because
      # Windows delivered it as WM_SYSKEYDOWN to a wndproc that only handled
      # WM_KEYDOWN. This overlay reads no window message at all: `GetAsyncKeyState`
      # reads the asynchronous key state the raw-input thread updates BEFORE any
      # message exists, so there is no classification to get wrong. If this line
      # is absent from the log after a press, the key genuinely never arrived and
      # the log says so; it is not something to reason about.
      if not gDuKeyRouteLogged:
        gDuKeyRouteLogged = true
        okLog "debugui: toggle key vk=0x" & hexOf(uint64(gDuCfg.toggleVk)) &
              " edge OBSERVED via GetAsyncKeyState (async key state -- not a " &
              "window message, so the WM_KEYDOWN/WM_SYSKEYDOWN routing that " &
              "hid F10 from the D3D overlay's wndproc cannot apply here)"
      # CTRL+F3 IS EDIT MODE, plain F3 is show/hide. Same key, one modifier read
      # from the same async table: no second key to collide with anything.
      #
      # WHICH BRANCH THIS PRESS TOOK IS LOGGED EVERY TIME, and it is logged
      # because the previous run could not answer it. The host log for that run
      # (tools/hostlog.py) shows four F3 edges and four `panel ON`/`panel OFF`
      # lines and NO edit-mode line at all -- which is consistent with two
      # different causes that the log could not tell apart: Ctrl was never
      # actually held, or Ctrl WAS held and `GetAsyncKeyState(VK_CONTROL)` read
      # 0 at the instant the F3 edge was taken. Printing the modifier reading on
      # every toggle turns that into a measurement instead of an argument. It is
      # one line per physical key press, at human speed.
      let ctrl = cWgCtrlDown() != 0'i32
      if ctrl:
        if not gDuVisible:
          gDuVisible = true
          duLoadLayout()
          duLoadWidgets()
        gDuEdit = not gDuEdit
        if not gDuEdit:
          duDragRelease()
        okLog "debugui: edit mode " & (if gDuEdit: "ON -- drag widgets with " &
              "the left mouse button; drops snap and are saved"
              else: "OFF")
        return cast[Il2CppPtr](1)
      gDuVisible = not gDuVisible
      if gDuVisible:
        # Re-read the layout file on every toggle-ON, so the user can edit it
        # and re-toggle without restarting the game.
        duLoadLayout()
        duLoadWidgets()
        if gDuCfg.espVk <= 0:
          gDuEspVisible = gDuCfg.espOn
        okLog "debugui: panel ON (" & $gDuWidgets.len & " widget(s); layout " &
              "re-read from " & gDuCfg.source & " + " & gDuLayoutSource &
              "). Ctrl was NOT down at this edge; hold Ctrl and press the " &
              "toggle key again for edit mode."
      else:
        gDuEdit = false
        duDragRelease()
        if gDuCfg.espVk <= 0:
          gDuEspVisible = false
        okLog "debugui: panel OFF (ctrl was NOT down at the edge -- Ctrl+F3 " &
              "is edit mode)"
    if gDuCfg.espVk > 0 and cDuKeyEdge(int32(gDuCfg.espVk)) != 0'i32:
      gDuEspVisible = not gDuEspVisible
      if gDuEspSuppressed:
        # A key that reports success and draws nothing is the silent decline
        # CLAUDE.md 6 forbids, so the edge says why every time it is pressed.
        warn "debugui: the marker toggle key was pressed, but the in-world " &
             "markers are SUPPRESSED because espProvider selected natEsp as " &
             "the ESP for this session. Nothing will be drawn. Set " &
             "espProvider to \"overlay\" or \"both\" to get them back."

  # NOTHING IS DRAWN FROM THIS DETOUR ANY MORE. Turning the panel on or off only
  # moves a flag; the drawing is `duRegionDraw` below, dispatched by the shared
  # region and rasterised by the D3D11 overlay in `Present`. There is no label
  # to hide on the way out, because there is no persistent object at all.
  cWgCrumb(WgCrumbDone)
  return cast[Il2CppPtr](1)

# ---------------------------------------------------------------------------
# THE DRAW -- a region participant, not a Unity canvas
#
# WHY THIS IS NOT A DETOUR AND NOT A CLONE. Six rounds of cloning a
# TextMeshProUGUI into the game's own canvas ended with a walk that succeeded,
# faulted nowhere, and rendered nothing: the clone landed under a canvas whose
# parenting and sort order belong to somebody else's UI. Worse, there is no
# check reachable from inside the host that can distinguish "drawn" from "not
# drawn" there -- which by CLAUDE.md 9b makes the approach unverifiable, not
# merely broken.
#
# The overlay's own pipeline has neither problem. `abi/aowlspt_region.h` is the
# sanctioned channel: a participant submits screen-space commands on the Unity
# thread, the D3D11 overlay drains the published buffer on the render thread
# inside `Present` and rasterises it with the same primitives the F12 panel and
# the F6 admin HUD use. Whether a command was drawn is decided by our own code
# in one place, not by another team's canvas.
#
# THE GUARD. The region dispatcher wraps EVERY participant callback in the one
# `aowl_p_p_seh`, times it against the budget declared here, counts its faults
# and disables it on its own if it misbehaves. So this body opens NO guard --
# `aowl_p_p_seh` is not re-entrant and one here would disarm the dispatcher's.
# It is also why the profiler widget can report this participant's cost: it is
# the same accounting, read back through `aowl_region_status_x`.
# ---------------------------------------------------------------------------
proc duRegionDraw(user: pointer; frame: int64) {.exportc: "aowl_du_region_draw",
                                                 cdecl.} =
  discard user
  discard frame
  cWgCrumb(WgCrumbEnter)
  cWgCrumbW(-1'i32)
  inc gDuFires
  cDuFpsSample()
  if not gDuVisible and not gDuEspVisible:
    return
  # OPEN THE STAGE WINDOW. Everything between here and `cWgStageEnd` is charged,
  # crumb by crumb, to the stage that was running -- so the region's "debugui
  # overran its budget" grows a breakdown instead of staying a single number
  # that names only the participant. Opened AFTER the early return above, so a
  # hidden overlay never records a frame at all.
  cWgStageBegin()
  cWgCrumb(WgCrumbEnter)
  # LIVE APPLY. Placed here, after the "is anything on screen" early return and
  # inside the stage window, so it is measured like every other stage and a
  # hidden overlay never reads the file at all. When the file really changed,
  # the widget layout is refreshed too -- the config and the widget file are
  # written by the same settings action and must not be applied a second apart.
  if duHotReloadTick(gDuFires):
    duLoadWidgets()
  # Throttle. The panel is a debug read-out, not an instrument: recomposing it
  # every Nth frame is indistinguishable to a human and costs a fraction as
  # much. The SUBMISSION is not throttled -- the command buffer is rebuilt from
  # empty every frame, so skipping a submission would flicker the panel off.
  # What is throttled is the expensive half: the world census AND, since this
  # fix, the text composition that reads what the census found.
  if (gDuFires mod duCadence()) == 0:
    # The cached GameWorld goes stale at the end of a raid; drop it rather than
    # keep reading a dead object.
    if gDuGameWorld != nil and
       not duOk(gDuGameWorld, cBdOffRegPlayers() + 8'i32):
      gDuGameWorld = nil
    cWgCrumb(WgCrumbScanWorld)
    duScanWorld()
  if gDuVisible:
    # The pointer is sampled ONCE per frame, before anything reads it, so a drag
    # cannot see the cursor in two places and the button edges are computed
    # exactly once. It is a `GetCursorPos` and a `GetAsyncKeyState`: no window
    # message, no hook, nothing swallowed from the game.
    cWgCrumb(WgCrumbMouse)
    discard cWgMouseSample()
    cWgCrumb(WgCrumbEditKeys)
    duEditKeys()
    cWgCrumb(WgCrumbDrag)
    duDragTick()
    duDrawWidgets()
  cWgCrumb(WgCrumbMarkers)
  # THE ARBITRATION POINT for the two ESPs. `gDuEspSuppressed` is decided once
  # at config load (see espProvider in aowlhost.nim) and logged there with the
  # loser and the reason; this is the single place the decision takes effect,
  # so the markers cannot come back through the toggle key or a layout reload.
  if gDuEspVisible and not gDuEspSuppressed:
    if not duDrawMarkers():
      if not gDuEspUnavailableLogged:
        gDuEspUnavailableLogged = true
        warn "debugui: Camera::get_main / Camera::WorldToScreenPoint did not " &
             "verify on this build, so in-world markers are unavailable. The " &
             "panel's `botlist` field still shows every AI bot's world " &
             "coordinates and distance -- add it to panelFields."
  cWgCrumb(WgCrumbDone)
  cWgStageEnd()
  # React to what was just MEASURED, not to anything this code believes it did.
  duThrottleTick()

var gDuRegionHandle = -1

proc duRegisterDraw(): bool =
  ## Register the F3 widgets as a DRAW participant. Says WHY it failed, using
  ## the region's own refusal text -- never the raw number, which means nothing
  ## to a reader of the log.
  if gDuRegionHandle >= 0:
    return true
  let h = cWgRgRegister(cstring("debugui"), duRegionDraw,
                        cWgRgMaskDraw(), 50'i32, 900'i32)
  if h < 0:
    warn "debugui: the F3 widgets could NOT be registered with the shared " &
         "region -- " & $cWgRgRefusalTextC(h) & ". Nothing will be drawn, and " &
         "that is reported here rather than as an empty screen."
    return false
  gDuRegionHandle = h
  okLog "debugui: F3 widgets registered with the shared region as DRAW " &
        "participant " & $h & " (budget 900 us). They are rasterised by the " &
        "D3D11 overlay in Present -- the same path as the F12 panel and the " &
        "F6 admin HUD -- so no TextMeshPro clone, no Unity canvas, no " &
        "parenting and no sort order are involved. If the region is not " &
        "armed, aowl_wg_rg_armed() reports 0 and the profiler widget says so."
  true

# The VEH/SEH guard thunk. ONE of them, wrapping the whole body: `aowl_p_p_seh`
# has a single thread-local `jmp_buf` and disarms itself on return, so nesting a
# second guard inside this one would silently disable this one. Anything that
# faults inside -- a stale clone after a scene change, a half-built bot, a
# projection against a camera that is being torn down -- is trapped here and the
# game keeps running with the overlay simply not updated that frame.
{.emit: """
extern void* aowl_du_body(void* a);
static void* aowl_du_body_guarded(void* a) {
    return aowl_p_p_seh((void*)aowl_du_body, a);
}
""".}
proc cDuBodyGuarded(a: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_du_body_guarded", nodecl.}

proc debugUiFired(regs: Il2CppPtr) =
  ## Dispatched by slot identity from `patchFired` for the kind=10 PREFIX detour
  ## on `EFT.UI.PreloaderUI::Update`. Never suppresses the original.
  if cDuBodyGuarded(regs) == nil:
    inc gDuFaults
    # WHERE. The guard itself cannot say -- the stack is gone by the time it
    # regains control -- so the body leaves a trail of file-scope stores the
    # longjmp cannot disturb, and this reads the last one. The old message said
    # only "fault #1 caught by the VEH guard", which is a fault report with NO
    # LOCATION; it cost a live session in which the panel showed nothing and the
    # log could not narrow forty steps down to one.
    let stage = cWgCrumbGet()
    let wi = int(cWgCrumbGetW())
    var where = $cWgCrumbTextC(stage)
    # THE SLOT NOW MEANS EXACTLY ONE THING: a widget index. It used to carry
    # three meanings -- widget index, clone-pool index, and a packed climb
    # depth for the canvas-root walk -- and the clone pool and the walk are
    # both gone with the Unity-UI path, so the ambiguity is gone with them.
    if wi >= 0 and wi < gDuWidgets.len:
      where.add " -- widget '" & gDuWidgets[wi].id & "' (index " & $wi &
                ", fields '" & gDuWidgets[wi].fields & "')"
    if gDuFaults == 1 or (gDuFaults mod 240) == 0:
      warn "debugui: fault #" & $gDuFaults & " caught by the VEH guard while " &
           where & "; the overlay skipped a refresh and the game is unaffected"

    # ATTRIBUTE IT. A fault raised inside a known widget's render is charged to
    # THAT widget; after `cDuWidgetFaultLimit` charges the widget switches itself
    # off and every other widget keeps drawing. This is the difference between
    # "the overlay is off, good luck" and "the prof widget is off, and here is
    # the stage it died in".
    # A duBuild fault is charged to duBuild, which drives the degrade-to-minimum
    # retry. It is deliberately NOT counted as "isolated": it is not, and
    # claiming otherwise would disable the whole-overlay backstop for precisely
    # the case that needs it.
    var isolated = false
    if wi >= 0 and wi < gDuWidgets.len and wi < gDuWidgetFaults.len and
       (stage == WgCrumbWText or stage == WgCrumbWPlace or
        stage == WgCrumbWStyle or stage == WgCrumbWSetText or
        stage == WgCrumbWShow):
      gDuWidgetFaults[wi] = gDuWidgetFaults[wi] + 1
      isolated = true
      if gDuWidgetFaults[wi] == cDuWidgetFaultLimit:
        gDuWidgets[wi].on = false
        warn "debugui: widget '" & gDuWidgets[wi].id & "' faulted " &
             $cDuWidgetFaultLimit & " times while " & where &
             " and has been switched OFF on its own. Every OTHER widget keeps " &
             "drawing. Re-enable it with 0 in edit mode, or by deleting " &
             "aowlspt-debugui-layout.json, once the cause is fixed."

    # THE BACKSTOP, for a fault that belongs to no single widget. A
    # widget-attributable fault no longer reaches it: three charges retire one
    # widget instead of eight taking the whole panel down.
    if gDuFaults >= 8 and not isolated:
      gDuVisible = false
      gDuEspVisible = false
      if gDuFaults == 8:
        warn "debugui: eight faults NOT attributable to any one widget (the " &
             "last was while " & where & ") -- the overlay has switched " &
             "itself OFF for this session"

proc duNoteGameWorld(gw: Il2CppPtr) =
  ## Cache the live GameWorld. Called from the kind=11 RegisterPlayer detour and
  ## ALSO from botdiag's handler, so the two never both need to be armed.
  if gw != nil and bdSanePtr(gw) and gw != gDuGameWorld:
    gDuGameWorld = gw

proc aowlHostGameWorld(): pointer {.exportc: "aowl_host_gameworld_impl", cdecl.} =
  ## READ-ONLY export of the GameWorld pointer the existing kind=11 /
  ## botdiag `RegisterPlayer` detour already caches. Exported so an out-of-host
  ## consumer (mods/admin) can have the live world WITHOUT binding a second
  ## detour on `EFT.GameWorld::RegisterPlayer` -- a second detour would
  ## overwrite the first's trampoline and silently kill debugEsp/botdiag
  ## (CLAUDE.md 5). This rides the existing detour as a drain; it installs
  ## nothing and writes nothing.
  ##
  ## NULL means one of three things, and the caller must not flatten them:
  ##   * not in a raid (no GameWorld exists)          -- expected
  ##   * neither `botDiag` nor `debugEsp` is armed, so nothing populates the
  ##     cache                                        -- INCONCLUSIVE, not "no raid"
  ##   * the cached pointer stopped validating and was dropped (line ~1864)
  ## `aowl_host_gameworld_armed` distinguishes the second case.
  result = cast[pointer](gDuGameWorld)

proc aowlHostGameWorldArmed(): int32 {.
    exportc: "aowl_host_gameworld_armed_impl", cdecl.} =
  ## 1 when a detour that populates the GameWorld cache is actually installed.
  ## Without this a consumer cannot tell "not in a raid" from "nobody is
  ## watching", and reporting the second as the first is exactly the silent
  ## decline CLAUDE.md 6 forbids.
  if gDebugEspSlot >= 0 or gBotDiagSlot >= 0: 1'i32 else: 0'i32

# MEASURED DEFECT: NEITHER OF THE TWO PROCS ABOVE WAS ACTUALLY EXPORTED.
#
# `{.exportc.}` gives the generated C function an unmangled NAME. It does NOT
# put it in the DLL's export table -- that needs `__declspec(dllexport)`, and
# this build has no .def file. `objdump -p` on the built host lists twelve
# exports and neither `aowl_host_gameworld` nor `aowl_host_gameworld_armed` was
# among them.
#
# The symptom, in the field: `mods/admin` and `mods/sain` both log
#
#     no host export aowl_host_gameworld (host too old, or not in the client)
#
# against a host that has the code for it a few lines above. That message is
# accurate about what it observed and badly misleading about why -- it sends
# people looking for a stale deployment when the export never existed in ANY
# build. `region.nim` avoided this only because it wraps every export in an
# explicit `AOWL_RG_EXPORT` (`__declspec(dllexport)`) thunk.
#
# So the Nim procs above are now named `*_impl`, and these thunks publish them
# under the EXACT names the already-shipped mods call `GetProcAddress` for.
# Nothing has to be rebuilt on the mod side.
{.emit: """
extern void* aowl_host_gameworld_impl(void);
extern int   aowl_host_gameworld_armed_impl(void);
__declspec(dllexport) void* aowl_host_gameworld(void) {
    return aowl_host_gameworld_impl();
}
__declspec(dllexport) int aowl_host_gameworld_armed(void) {
    return aowl_host_gameworld_armed_impl();
}
""".}

proc debugEspRegisterFired(regs: Il2CppPtr) =
  ## The kind=11 read-only detour on `EFT.GameWorld::RegisterPlayer`. It does
  ## ONE thing -- take RCX and remember it -- because that is all the overlay
  ## needs from this method and a per-registration walk belongs to botdiag.
  if int(cThreadId()) == int(gHostThreadId):
    return
  let gwRaw = cRegsInt(regs, 0'i32)
  if gwRaw != 0'u64:
    duNoteGameWorld(cast[Il2CppPtr](gwRaw))

proc duIndicesOk(): bool =
  ## Assert the FINISHED STATE of the index table, not our own belief about it.
  ##
  ## For every index this module calls by name, compare the name the C table
  ## actually holds at that index with the name the code means. A row inserted
  ## anywhere in `aowl_du_targets` -- which is what actually happened, and cost
  ## four rounds -- shifts at least one of these and is caught HERE, at bind,
  ## instead of as a null-pointer fault inside Unity a hundred frames later.
  ## Falsifiable by construction: insert or delete any row and it fails.
  const expect: array[36, string] = [
    "UnityEngine.Camera::get_main",
    "UnityEngine.Camera::WorldToScreenPoint(Vector3)",
    "UnityEngine.RectTransform::set_anchoredPosition",
    "UnityEngine.RectTransform::set_anchorMin",
    "UnityEngine.RectTransform::set_anchorMax",
    "UnityEngine.RectTransform::set_pivot",
    "UnityEngine.Component::get_transform",
    "UnityEngine.Transform::get_root",
    "UnityEngine.RectTransform::get_anchoredPosition",
    "UnityEngine.RectTransform::get_sizeDelta",
    "UnityEngine.RectTransform::set_sizeDelta",
    "UnityEngine.RectTransform::get_anchorMin",
    "UnityEngine.RectTransform::get_pivot",
    "UnityEngine.RectTransform::get_anchorMax",
    "UnityEngine.RectTransform::get_rect",
    "UnityEngine.Transform::get_localScale",
    "UnityEngine.Transform::set_localScale",
    "UnityEngine.Transform::get_localPosition",
    "UnityEngine.Transform::set_localPosition",
    "UnityEngine.Transform::get_parent",
    "UnityEngine.GameObject::get_activeSelf",
    "UnityEngine.GameObject::get_activeInHierarchy",
    "UnityEngine.GameObject::get_layer",
    "UnityEngine.Canvas::get_sortingOrder",
    "UnityEngine.Canvas::get_renderMode",
    "UnityEngine.Canvas::get_scaleFactor",
    "UnityEngine.UI.Graphic::set_raycastTarget",
    "UnityEngine.Behaviour::set_enabled",
    # The visibility block, APPENDED (28..35). Nothing addresses these
    # positionally -- the inspector resolves them BY NAME through
    # `iFindTarget` -- but they are listed here anyway, because the check that
    # matters is "the table is exactly what this host was written against",
    # and a check that skips the tail is a check that can only say yes about
    # the head.
    "UnityEngine.Transform::TransformPoint(Vector3)",
    "UnityEngine.Transform::get_lossyScale",
    "UnityEngine.CanvasGroup::get_alpha",
    "UnityEngine.CanvasGroup::get_ignoreParentGroups",
    "UnityEngine.UI.Graphic::get_color",
    "UnityEngine.UI.Graphic::get_canvas",
    "UnityEngine.Behaviour::get_enabled",
    "UnityEngine.Behaviour::get_isActiveAndEnabled"]
  result = true
  let n = int(cDuTargetCount())
  if n != expect.len:
    warn "debugui: the managed-target table holds " & $n & " rows, this " &
         "module was written against " & $expect.len & ". Every index below " &
         "the change is addressing the wrong method. NOT arming."
    return false
  for i in 0 ..< n:
    let got = $cDuName(int32(i))
    if got != expect[i]:
      warn "debugui: managed-target index " & $i & " holds '" & got &
           "' but this module calls it as '" & expect[i] & "'. A row was " &
           "inserted into or removed from aowl_du_targets and the indices in " &
           "debugui.nim were not moved with it. NOT arming."
      result = false
  # Named spot-checks, so the log names the two that have actually bitten.
  if result:
    okLog "debugui: managed-target indices self-checked -- get_parent=" &
          $DuGetParent & " '" & $cDuName(DuGetParent) & "', get_rect=" &
          $DuGetRect & " '" & $cDuName(DuGetRect) & "'"

var gDuIdxChecked = 0   ## 0 = not yet run, 1 = passed, 2 = failed

proc duTargetsBindOk(): bool =
  ## THE GENERALISED BINDING ASSERTION.
  ##
  ## `duIndicesOk` was written for `debugui` and ran only on `bindDebugUi`.
  ## That left `settingspages.nim` -- which indexes the SAME C table with the
  ## SAME positional constants (`DuGetParent`, `DuGoActiveSelf`, ...) -- armed
  ## with no check at all whenever debugui was flagged off. A row inserted into
  ## `aowl_du_targets` would then reach the live client through settingspages
  ## exactly as it reached it through debugui: a valid, byte-verified function
  ## of the WRONG SHAPE, called with the wrong frame.
  ##
  ## So the check is now a MODULE-LEVEL GATE that every consumer of the table
  ## must pass through, memoised so the second caller costs nothing and the
  ## refusal message is printed once rather than per feature.
  if gDuIdxChecked != 0:
    return gDuIdxChecked == 1
  gDuIdxChecked = (if duIndicesOk(): 1 else: 2)
  result = gDuIdxChecked == 1

proc bindDebugUi(verbose: bool): bool =
  ## Installs the kind=10 PREFIX detour on `EFT.UI.PreloaderUI::Update` from the
  ## verified static target in `aowlspt_debugui.h`. Opt-in (`debugUi`/`debugEsp`);
  ## binds nothing on a build whose prologue differs, in which case the overlay
  ## is simply absent.
  if gDebugUiSlot >= 0:
    return true
  if not gReady or gDisableDrain:
    return false
  # The widget set is read at BIND so the count on screen matches the count in
  # the config from the very first press. Both files are re-read on every
  # toggle-ON as well, so editing them needs no restart at all -- there is no
  # longer a pool sized once at build time to be out of step with them.
  duLoadWidgets()
  okLog "debugui: " & $gDuWidgets.len & " widget(s) configured -- " &
        gDuLayoutSource
  if not duTargetsBindOk():
    return false
  var ok = 0
  var bad = 0
  for i in 0 ..< int(cDuTargetCount()):
    if cDuFn(int32(i)) != nil: inc ok else: inc bad
  okLog "debugui: " & $ok & " of " & $int(cDuTargetCount()) &
        " managed targets verified by RVA + prologue on this build" &
        (if bad > 0: " (" & $bad & " rejected)" else: "")
  let fn = cDuPreloaderTarget()
  if fn == nil:
    if verbose:
      info "debugui: EFT.UI.PreloaderUI::Update @ 0x" &
           hexOf(uint64(cDuPreloaderRva())) & " did not verify on this build"
    return false
  # REGISTER THE DRAW before claiming or riding the detour. The detour only
  # supplies the per-frame TICK the region dispatches from; the drawing itself
  # is `duRegionDraw`, submitted to the shared region and rasterised by the
  # D3D11 overlay in Present. If this refuses, it says why -- an F3 that
  # silently draws nothing is the exact failure this rewrite exists to end.
  discard duRegisterDraw()
  # THE SHARED `PreloaderUI::Update` HOOK, from the other side. The menu
  # mode-text feature (kind 13) drains the same function; two detours on one
  # function would have the second overwrite the first's trampoline. aowlhost
  # arms the overlay first, so this branch is the unusual order -- but when
  # mode-text did get there first, the overlay rides on ITS detour rather than
  # installing a second one, and `patchFired`/`patchReturned` dispatch both.
  # Aliased only on a byte-identical target, for the same reason `bindModeText`
  # checks: riding a detour on some other function would hand `debugUiFired` an
  # RCX that is not a PreloaderUI.
  if gModeTextSlot >= 0:
    if cMtxFn(0'i32) != fn:
      warn "debugui: the menu mode-text feature holds a detour on a different " &
           "target than the PreloaderUI::Update this verified; refusing to " &
           "ride on it and refusing to double-detour. The overlay is not armed."
      return false
    gDebugUiSlot = gModeTextSlot
    okLog "debugui armed as a RIDER on the menu mode-text feature's existing " &
          "EFT.UI.PreloaderUI::Update detour (slot " & $gDebugUiSlot &
          ") -- one detour, one trampoline, both features live. Press " &
          (if gDuCfg.toggleVk == 0x72: "F3" else: "VK " & $gDuCfg.toggleVk) &
          " in game to show the panel."
    return true
  # The LIVE INSPECTOR is the third rider on this same function and can be the
  # one that got there first. It claims through this same verified `fn`, so
  # riding it is safe by construction -- but ride it we must, because installing
  # a second detour would overwrite its trampoline. This is what makes the
  # multiplex arming-order INDEPENDENT across all three riders rather than only
  # across the original two.
  if gInspSlot >= 0:
    gDebugUiSlot = gInspSlot
    okLog "debugui armed as a RIDER on the live inspector's existing " &
          "EFT.UI.PreloaderUI::Update detour (slot " & $gDebugUiSlot &
          ") -- one detour, one trampoline, both features live. Press " &
          (if gDuCfg.toggleVk == 0x72: "F3" else: "VK " & $gDuCfg.toggleVk) &
          " in game to show the panel."
    return true
  if attachDrain("EFT.UI.PreloaderUI::Update", fn, cast[Il2CppMethod](0),
                 true, verbose, 10'i32):
    okLog "debugui CLAIMED the shared EFT.UI.PreloaderUI::Update detour " &
          "(slot " & $gDebugUiSlot & ", prefix, per-frame, Unity thread); " &
          "uxMenuModeText will ride on this same detour if it is on. Press " &
          (if gDuCfg.toggleVk == 0x72: "F3" else: "VK " & $gDuCfg.toggleVk) &
          " in game to show the panel; layout comes from " &
          "aowlspt-debugui.json beside the host DLL and is re-read on every " &
          "toggle-on."
    return true
  result = false

proc bindDebugEspWorld(verbose: bool): bool =
  ## The kind=11 GameWorld cache. Shares `EFT.GameWorld::RegisterPlayer` with
  ## botdiag, so it is installed ONLY when botdiag did not take that target --
  ## two detours on one function would have the second overwrite the first's
  ## trampoline. When botdiag owns it, `botDiagRegisterFired` feeds the cache
  ## instead and this is not needed at all.
  if gDebugEspSlot >= 0 or gBotDiagSlot >= 0:
    return true
  if not gReady or gDisableDrain:
    return false
  let count = cBotDiagTargetCount()
  for i in 0 ..< int(count):
    let fn = cBotDiagTargetAt(int32(i))
    if fn == nil:
      continue
    let spec = readCString(cBotDiagTargetName(int32(i)))
    if attachDrain(spec, fn, cast[Il2CppMethod](0), false, verbose, 11'i32):
      okLog "debugui: GameWorld cache armed on " & spec &
            " (read-only, one pointer, nothing walked)"
      return true
  if verbose:
    info "debugui: EFT.GameWorld::RegisterPlayer did not verify on this " &
         "build; in-world markers will have no bot list"
  result = false
