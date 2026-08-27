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
proc cDuName(i: int32): Il2CppPtr {.importc: "aowl_du_name", nodecl.}
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

proc cWgCrumb(stage: int32) {.importc: "aowl_wg_crumb", nodecl.}
proc cWgCrumbW(idx: int32) {.importc: "aowl_wg_crumb_w", nodecl.}
proc cWgCrumbGet(): int32 {.importc: "aowl_wg_crumb_get", nodecl.}
proc cWgCrumbGetW(): int32 {.importc: "aowl_wg_crumb_get_w", nodecl.}
proc cWgCrumbTextC(s: int32): cstring {.importc: "aowl_wg_crumb_text", nodecl.}
proc cWgCrumbDepth(packed: int32): int32 {.
  importc: "aowl_wg_crumb_depth", nodecl.}
proc cWgCrumbRoleC(packed: int32): cstring {.
  importc: "aowl_wg_crumb_role", nodecl.}

const
  WgCrumbEnter     = 1'i32
  WgCrumbToggle    = 2'i32
  WgCrumbBuild     = 3'i32
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
  WgCrumbHideRest  = 14'i32
  WgCrumbMarkers   = 15'i32
  WgCrumbDone      = 16'i32
  # Inside duBuild. The live run narrowed the fault to "cloning the label pool",
  # which is still a dozen distinct managed operations; these split it the rest
  # of the way rather than inviting another guess.
  WgCrumbBAnchor      = 17'i32
  WgCrumbBRoot        = 18'i32
  WgCrumbBProbeClone  = 19'i32
  WgCrumbBProbeDraw   = 20'i32
  WgCrumbBSrcCanvas   = 21'i32
  WgCrumbBProbeCanvas = 22'i32
  WgCrumbBDropCanvas  = 23'i32
  WgCrumbBAssertLog   = 24'i32
  WgCrumbBProbeReuse  = 25'i32
  WgCrumbBPanelClone  = 26'i32
  WgCrumbBPanelDraw   = 27'i32
  WgCrumbBMarkClone   = 28'i32
  WgCrumbBMarkDraw    = 29'i32
  WgCrumbBScale       = 30'i32
  WgCrumbBDiagDump    = 31'i32
  WgCrumbBReadback    = 32'i32
  # Inside duCanvasRootGo -- every one of these is a managed call on a
  # UnityEngine.Object whose native half may already be gone.
  WgCrumbRAnchorAlive = 33'i32
  WgCrumbRRect        = 34'i32
  WgCrumbRRectAlive   = 35'i32
  WgCrumbRParent      = 36'i32
  WgCrumbRParSane     = 37'i32
  WgCrumbRParGo       = 38'i32
  WgCrumbRCanvas      = 39'i32
  WgCrumbRClimb       = 40'i32
  WgCrumbRDone        = 41'i32
  WgCrumbRClimbParent = 42'i32
  WgCrumbRRectSrc     = 43'i32

# ---- target indices, mirroring the AOWL_DU_* defines ----
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
  DuGetRect        = 13'i32
  DuGetLocalScale  = 14'i32
  DuSetLocalScale  = 15'i32
  DuGetLocalPos    = 16'i32
  DuSetLocalPos    = 17'i32
  DuGetParent      = 18'i32
  DuGoActiveSelf   = 19'i32
  DuGoActiveInHier = 20'i32
  DuGoLayer        = 21'i32
  DuCanvasOrder    = 22'i32
  DuCanvasMode     = 23'i32
  DuCanvasScale    = 24'i32
  DuSetRaycast     = 25'i32
  DuSetEnabled     = 26'i32

# ---------------------------------------------------------------------------
# Caps
#
# Every one of these is a REFUSAL, not a preference: a corrupt `_size` on a
# List, a config file with a silly number in it, or a raid with three hundred
# bots must all cost a bounded amount of work inside a per-frame detour.
# ---------------------------------------------------------------------------
const
  cDuMaxPanelLines = 12    ## panel labels; the config picks which fields fill them
  cDuMaxMarkers    = 48    ## hard ceiling on ESP labels, whatever the config says
  cDuMaxPlayers    = 64    ## registered players read per pass
  cDuMaxTextLen    = 1024  ## characters written into ONE label.
    ## Was 160, which was right when a label held ONE line and wrong the moment
    ## a widget became many. The profiler table alone is ~40 characters a row
    ## over up to twelve rows, so 160 silently cut it off mid-row -- and a
    ## truncated read-out that still looks like a read-out is the worst kind.
    ## Still a hard cap, and `duSetText` still truncates rather than refusing.

## The `last` value a freshly cloned label starts at. It must be a string no
## real caption can equal, because `duSetText` short-circuits on unchanged text
## and a clone starts out carrying the DONOR'S text ("1.1.0.1.4677 | PvE").
## With `last` initialised to "" the first `duHide` compared "" to "" , decided
## nothing had changed, and left the donor's string on screen at the donor's
## position -- which is the stray label parked in the middle of the screen.
## The leading control byte is deliberate: no caption this overlay composes
## ever begins with one, so the sentinel cannot collide with real text.
const cDuUnset = "\x01<clone has never been written to>"

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

# ---------------------------------------------------------------------------
# The label pool
#
# One entry per cloned TextMeshProUGUI. `last` is what was last written into it,
# so an unchanged line costs no managed String allocation at all -- which is the
# difference between a debug panel and a debug panel that shows up in the frame
# time.
# ---------------------------------------------------------------------------
type DuLabel = object
  tmp: Il2CppPtr        ## the cloned TextMeshProUGUI component
  rect: Il2CppPtr       ## its RectTransform (m_rectTransform, or get_transform)
  last: string          ## the text currently in it
  shown: bool           ## whether it is currently non-empty
  ## The anchor + offset this label was last PLACED at. `duPlace` costs four
  ## managed calls; a panel line that has not moved since the last refresh needs
  ## none of them, and a panel line almost never moves.
  pAnchor: string
  pX: float64
  pY: float64
  placed: bool
  ## The clone's GameObject, so a label can be switched off entirely rather
  ## than merely blanked, and whether it is currently on.
  go: Il2CppPtr
  active: bool

var gDuPanel: seq[DuLabel] = @[]
var gDuMarks: seq[DuLabel] = @[]

## The clone anchor and the canvas root, resolved once and then reused. Both are
## re-validated by every user, because a scene change can leave either dangling
## and this file must notice rather than dereference.
var gDuAnchorTmp: Il2CppPtr = nil
var gDuRootGo: Il2CppPtr = nil

## The live GameWorld, cached by the kind=11 RegisterPlayer detour (or by
## botdiag when that is the one armed). Cleared when it stops being readable.
var gDuGameWorld: Il2CppPtr = nil

## The canvas scale factor, resolved once when the pool is built. See the note
## where it is assigned: it is the pixels-to-canvas-units divisor the ESP
## projection needs and the panel does not.
var gDuCanvasScale = 1.0

## Whether the overlay is currently visible, and whether the markers are.
var gDuVisible = false
var gDuEspVisible = false
## Per-frame bookkeeping.
var gDuFires = 0
var gDuBuilt = false
var gDuBuildFailed = false
var gDuLoggedOnce = false
var gDuFaults = 0
## The single trial clone whose canvas decides whether the rest of the pool is
## built at all, and how many refreshes we have waited for Unity to resolve its
## canvas. Held across frames so a retry never clones again.
var gDuProbe: DuLabel
var gDuProbeWaits = 0
## Whether the copied-Canvas repair has been attempted on the probe. Once only:
## if disabling it did not help, doing it again will not either.
var gDuCanvasDropTried = false

proc duPtrAdd(p: Il2CppPtr; off: int32): Il2CppPtr =
  cast[Il2CppPtr](cast[uint64](p) + uint64(off))

proc duOk(p: Il2CppPtr; size: int32): bool =
  ## One gate for every pointer hop, identical in spirit to botdiag's `bdOk`:
  ## non-null, in a plausible user-space range, and page-readable for `size`
  ## bytes by VirtualQuery -- never a faulting deref to find out.
  result = p != nil and bdSanePtr(p) and cIsReadable(p, size) != 0'i32

proc cDuOffCachedPtr(): int32 {.importc: "aowl_nav_off_cachedptr", nodecl.}
  ## From `abi/aowlspt_navui.h` (AOWL_NAV_UOBJ_CACHEDPTR = 0x10), never guessed.

proc duUnityAlive(p: Il2CppPtr): bool =
  ## IS THE NATIVE HALF OF THIS UnityEngine.Object STILL THERE?
  ##
  ## THIS IS THE GATE WHOSE ABSENCE WAS THE BUG. `duOk` proves a pointer is
  ## READABLE. It cannot prove the object is ALIVE, and those are different
  ## facts: when Unity destroys an object, the managed wrapper survives -- fully
  ## readable, `duOk` passes -- but `m_CachedPtr` at +0x10 is zeroed. That is
  ## Unity's famous "fake null": an object that compares equal to null in C# and
  ## kills the process if you call anything on it.
  ##
  ## `Component::get_transform`, `Component::get_gameObject` and
  ## `Transform::get_parent` -- the three calls `duCanvasRootGo` is built out of
  ## -- are all IL2CPP internal-call wrappers that dereference `m_CachedPtr`
  ## with no null check of their own.
  ##
  ## MEASURED: the overlay faulted on `duCanvasRootGo` on every refresh, at the
  ## MAIN MENU, two minutes after boot. The menu rebuild destroys the tree the
  ## boot-time version label lived in; `PreloaderUI._alphaVersionLabel` still
  ## points at the destroyed wrapper, `duFindAnchor`'s `duOk` chain passes it
  ## happily, and the first `get_transform` on it dies inside Unity's C++.
  ##
  ## `inspect.nim` learned this first (`iUnityAlive`) but is included AFTER this
  ## file in the one translation unit, so this is the same gate stated here
  ## rather than a second opinion. The offset comes from `aowlspt_navui.h`
  ## (`AOWL_NAV_UOBJ_CACHEDPTR`, 0x10), never from a guess.
  ##
  ## This is a plain guarded field read and cannot itself fault.
  if not duOk(p, cDuOffCachedPtr() + 8'i32):
    return false
  result = cReadPtrAt(p, cDuOffCachedPtr()) != nil

# ---------------------------------------------------------------------------
# Reaching the anchor
#
# PreloaderUI._alphaVersionLabel (+0x20) -> LocalizedText._labels (+0x78)
#   -> List<TextMeshProUGUI> -> _items (+0x10) -> elems (+0x20) -> [0]
#
# Every hop guarded. A failure at any hop is "not yet" -- PreloaderUI's Update
# can fire before its label list is populated -- so it returns nil and the caller
# simply tries again next frame rather than latching a failure.
# ---------------------------------------------------------------------------
proc duFindAnchor(preloader: Il2CppPtr): Il2CppPtr =
  result = nil
  if not duOk(preloader, cDuOffPreVersionLabel() + 8'i32):
    return
  let loc = cReadPtrAt(preloader, cDuOffPreVersionLabel())
  if not duOk(loc, cDuOffLocLabels() + 8'i32):
    return
  let lst = cReadPtrAt(loc, cDuOffLocLabels())
  if not duOk(lst, cDuOffListSize() + 4'i32):
    return
  let arr = cReadPtrAt(lst, cDuOffListItems())
  let size = cReadI32At(duPtrAdd(lst, cDuOffListSize()))
  if not duOk(arr, cDuOffArrElems() + 8'i32) or size <= 0'i32:
    return
  let tmp0 = cReadPtrAt(arr, cDuOffArrElems())
  # The anchor must be readable all the way past the fields this file writes,
  # because a TMP-shaped pointer that is short is not a TextMeshProUGUI.
  if not duOk(tmp0, cDuOffTmpRect() + 8'i32):
    return
  # AND ALIVE. `_alphaVersionLabel` keeps pointing at the boot-time label after
  # the menu rebuild destroys it: readable, `duOk` passes, `m_CachedPtr` zero.
  # Returning nil here means "not yet" and the caller re-resolves next refresh,
  # which is the whole fix -- the old code handed the dead wrapper onward.
  if not duUnityAlive(tmp0):
    return
  result = tmp0

## What `duRectOf` last did, for the log. A pointer that faulted is worth far
## more with its provenance attached than without.
var gDuRectSource = "not resolved"
var gDuRectMismatchLogged = false
var gDuRectEvidenceLogged = false

proc duRectOf(tmp: Il2CppPtr): Il2CppPtr =
  ## The RectTransform of a TMP component -- FROM `Component::get_transform`,
  ## which is live truth, NOT from TMP's `m_rectTransform` cache at +0x388.
  ##
  ## THE CACHE IS WHY THE WALK STILL FAULTED. The previous version preferred the
  ## cached field and returned it after nothing but a `duOk` readability check --
  ## before even reaching the liveness gate below it. `duCanvasRootGo` then gated
  ## that pointer (readable: yes; `m_CachedPtr` non-zero: yes) and called
  ## `Transform::get_parent` on it, which died. Measured: the fault moved from
  ## `get_transform` to `get_parent` exactly when the anchor gate started
  ## working, which means the receiver of `get_parent` -- this value -- is the
  ## remaining bad pointer.
  ##
  ## Both gates can pass on a pointer that is still wrong, and that is the whole
  ## lesson here. `duOk` proves READABLE. `duUnityAlive` proves `m_CachedPtr` is
  ## NON-ZERO -- it does not prove that pointer still points at a live native
  ## object, and it does not prove the managed object is a Transform at all. A
  ## stale field left over from a rebuilt tree satisfies both.
  ##
  ## So: ask the live component what its transform IS. One managed call, made
  ## only while building the pool (not per frame), on a receiver that has just
  ## been liveness-gated. The cached field is kept only as a CROSS-CHECK and is
  ## logged once when the two disagree -- which is the evidence that says whether
  ## the field is stale or the offset is wrong for this build.
  result = nil
  gDuRectSource = "not resolved"
  if tmp == nil:
    return
  let fn = cDuFn(DuGetTransform)
  if fn == nil:
    gDuRectSource = "Component::get_transform did not verify on this build"
    return
  # `Component::get_transform` is an internal-call wrapper that dereferences
  # `m_CachedPtr`, so liveness is checked BEFORE the call, never after.
  if not duUnityAlive(tmp):
    gDuRectSource = "the TMP component is destroyed (m_CachedPtr 0)"
    return
  let t = cDuCallPP(fn, tmp)
  if not (duOk(t, 0x20'i32) and duUnityAlive(t)):
    gDuRectSource = "get_transform returned null, unreadable or destroyed"
    return
  gDuRectSource = "Component::get_transform (live)"

  # The cross-check. Read-only, and it decides nothing -- it only reports.
  if not gDuRectMismatchLogged and duOk(tmp, cDuOffTmpRect() + 8'i32):
    let cached = cReadPtrAt(tmp, cDuOffTmpRect())
    if cached != t:
      gDuRectMismatchLogged = true
      warn "debugui: TMP's m_rectTransform cache (+0x" &
           hexOf(uint64(cDuOffTmpRect())) & ") = 0x" &
           hexOf(cast[uint64](cached)) & " but Component::get_transform says 0x" &
           hexOf(cast[uint64](t)) & ". The cached value is " &
           (if cached == nil: "null"
            elif not duOk(cached, 0x20'i32): "UNREADABLE"
            elif not duUnityAlive(cached): "readable but DESTROYED (m_CachedPtr 0)"
            else: "readable and alive-looking, m_CachedPtr=0x" &
                  hexOf(cast[uint64](duReadPtrField(cached, cDuOffCachedPtr()))) &
                  ", klass=0x" & hexOf(cast[uint64](duReadPtrField(cached, 0'i32)))) &
           ". The overlay uses get_transform and ignores the cache; this line " &
           "is evidence about the field, not a failure."
  result = t

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
  if s == nil or cIsReadable(s, 0x14'i32) == 0'i32:
    return
  result = bdReadString(s)

# ---------------------------------------------------------------------------
# Making a clone actually DRAW
#
# A clone of the version label inherits the version label's ENTIRE styling, and
# that styling is for a faint bottom-corner stamp, not for a panel. Six separate
# inherited properties can each independently render a live, parented, correctly
# positioned label as zero pixels; the header note lists them with the field
# offsets. This applies the opposite of each, by raw field write into a component
# THIS FILE CLONED -- never into anything the game built.
#
# All of it is idempotent and none of it needs a managed call, so it costs one
# burst of stores per label per session.
# ---------------------------------------------------------------------------
const
  cDuAlignLeft   = 1'i32      ## HorizontalAlignmentOptions.Left
  cDuAlignTop    = 256'i32    ## VerticalAlignmentOptions.Top
  cDuAlignTopLft = 257'i32    ## TextAlignmentOptions.TopLeft
  cDuOverflowOn  = 0'i32      ## TextOverflowModes.Overflow
  cDuIntMax      = 2147483647'i32

proc duMakeDrawable(lab: DuLabel; w, h: float64) =
  if lab.tmp == nil:
    return
  # Word wrap OFF and overflow Overflow: after this the rect's WIDTH cannot
  # hide a single glyph, which removes the whole class of "the box collapsed".
  discard cDuWriteU8(lab.tmp, cDuOffTmpWordWrap(), 0'i32)
  discard cDuWriteI32(lab.tmp, cDuOffTmpOverflow(), cDuOverflowOn)
  # Auto-sizing OFF, or the font size written by `duStyle` is advisory and the
  # real size is whatever fits a box we just collapsed to a point.
  discard cDuWriteU8(lab.tmp, cDuOffTmpAutosize(), 0'i32)
  # Top-left alignment, to match the top-left pivot `duPlace` sets: otherwise
  # the glyphs sit a whole rect-height below where the anchor claims they are.
  discard cDuWriteI32(lab.tmp, cDuOffTmpHAlign(), cDuAlignLeft)
  discard cDuWriteI32(lab.tmp, cDuOffTmpVAlign(), cDuAlignTop)
  discard cDuWriteI32(lab.tmp, cDuOffTmpTextAlign(), cDuAlignTopLft)
  # Nothing clipped from either end: a source label with a reveal effect leaves
  # these clamped, and a clamp of zero is an invisible label with perfect text.
  discard cDuWriteI32(lab.tmp, cDuOffTmpFirstVis(), 0'i32)
  discard cDuWriteI32(lab.tmp, cDuOffTmpMaxVisChars(), cDuIntMax)
  discard cDuWriteI32(lab.tmp, cDuOffTmpMaxVisWords(), cDuIntMax)
  discard cDuWriteI32(lab.tmp, cDuOffTmpMaxVisLines(), cDuIntMax)
  discard cDuWriteI32(lab.tmp, cDuOffTmpPage(), 1'i32)
  # No margins -- the version label's margins are sized for its own corner.
  discard cDuWriteColor(lab.tmp, cDuOffTmpMargin(), 0.0, 0.0, 0.0, 0.0)
  # The Graphic tint the CanvasRenderer multiplies by. The alpha version label
  # is drawn faint; a clone that inherits alpha 0.15 is not literally invisible
  # but is indistinguishable from it against the game's background.
  discard cDuWriteColor(lab.tmp, cDuOffTmpGColor(), 1.0, 1.0, 1.0, 1.0)
  # A real box. `duPlace` collapses anchorMin == anchorMax to a POINT, after
  # which the rect IS the sizeDelta -- and the sizeDelta inherited from a
  # stretch-anchored source is routinely zero or negative.
  let fnSize = cDuFn(DuSetSizeDelta)
  if fnSize != nil and lab.rect != nil:
    cDuSetVec2(fnSize, lab.rect, w, h)
  # Identity scale and a zero local Z. `SetParentAndAlign` does NOT reset the
  # local transform (it is `SetParent(parent, false)` plus a layer walk), so the
  # clone arrives carrying whatever the source had.
  let fnScale = cDuFn(DuSetLocalScale)
  if fnScale != nil and lab.rect != nil:
    cDuSetVec3(fnScale, lab.rect, 1.0, 1.0, 1.0)
  let fnPos = cDuFn(DuSetLocalPos)
  if fnPos != nil and lab.rect != nil:
    cDuSetVec3(fnPos, lab.rect, 0.0, 0.0, 0.0)
  # And finally: awake. `Instantiate` copies `activeSelf`, so a clone of a
  # disabled source is a disabled clone that will never render anything.
  let go = duGameObjectOf(lab.tmp)
  let fnAct = mi2Fn(Mi2GoSetActive)
  if go != nil and fnAct != nil:
    cMi2CallVPB(fnAct, go, 1'i32)
  # Never a raycast target: a debug read-out must not eat the player's clicks.
  duNoRaycast(lab.tmp)
  # And never its own canvas: `Instantiate` copies the source label's nested
  # Canvas onto every single clone, which is what put 33 canvases in the scene.
  # The probe proves the repair works; this applies it to the rest.
  if gDuAnchorTmp != nil:
    discard duDropNestedCanvas(lab.tmp, duReadPtrField(gDuAnchorTmp,
                                                       cDuOffTmpGCanvas()))
  discard cDuWriteU8(lab.tmp, cDuOffTmpDirty(), 1'i32)

# ---------------------------------------------------------------------------
# Making one label
#
# `Object::Instantiate(Object)` on the anchor COMPONENT (see the header note on
# why the component and not its GameObject), then `SetParentAndAlign` into the
# canvas root, then anchors/pivot so the caller can position it in screen terms.
# Returns a `DuLabel` with `tmp == nil` if any step did not happen.
# ---------------------------------------------------------------------------
proc duCloneLabel(anchor, rootGo: Il2CppPtr): DuLabel =
  result = DuLabel(tmp: nil, rect: nil, last: cDuUnset, shown: false,
                   pAnchor: "", pX: 0.0, pY: 0.0, placed: false,
                   go: nil, active: true)
  let fnInst = mi2Fn(Mi2Instantiate)
  if fnInst == nil or anchor == nil:
    return
  let clone = cMi2CallPS1(fnInst, anchor)
  if not duOk(clone, cDuOffTmpRect() + 8'i32):
    return
  # Parent it before anything else: SetParentAndAlign resets the local transform,
  # so any position written before it would be thrown away.
  let fnGo = mi2Fn(Mi2GetGameObject)
  var cloneGo: Il2CppPtr = nil
  if fnGo != nil:
    cloneGo = cMi2CallPP(fnGo, clone)
  if cloneGo != nil and rootGo != nil:
    let fnPar = mi2Fn(Mi2SetParentAlign)
    if fnPar != nil:
      cMi2CallVS2(fnPar, cloneGo, rootGo)
  let rect = duRectOf(clone)
  if rect == nil:
    # A label with no RectTransform cannot be positioned, and an unpositioned
    # clone sitting on top of the version label is worse than no label at all.
    return
  result = DuLabel(tmp: clone, rect: rect, last: cDuUnset, shown: false,
                   pAnchor: "", pX: 0.0, pY: 0.0, placed: false,
                   go: cloneGo, active: true)

# The widget model and ALL of its pure geometry live in `wgeom.nim`, which has
# no game dependency of any kind -- no managed call, no IL2CPP pointer, no
# Windows call. That is not tidiness: it is what lets `tests/wgeom_test.nim`
# exercise the built-in placement path, the snap and the on-screen clamp against
# a 0x0 and a 3840x2160 back buffer WITHOUT the client. The live faults this
# overlay produced could not be reproduced any other way.
include wgeom

proc duPlace(lab: var DuLabel; anchorName: string; x, y: float64) =
  ## Anchor + pivot + offset, in that order. FOUR managed calls -- so a label
  ## that has not moved since the last refresh makes none of them. The panel
  ## used to re-anchor all nine of its lines on every refresh forever, for a
  ## layout that changes only when the config is re-read; markers genuinely do
  ## move and pay the cost only when they actually did.
  if lab.rect == nil:
    return
  if lab.placed and lab.pAnchor == anchorName and lab.pX == x and lab.pY == y:
    return
  var ax = 0.0
  var ay = 1.0
  var px = 0.0
  var py = 1.0
  duAnchorVec(anchorName, ax, ay, px, py)
  let fnMin = cDuFn(DuSetAnchorMin)
  let fnMax = cDuFn(DuSetAnchorMax)
  let fnPiv = cDuFn(DuSetPivot)
  let fnPos = cDuFn(DuSetAnchoredPos)
  if fnMin != nil: cDuSetVec2(fnMin, lab.rect, ax, ay)
  if fnMax != nil: cDuSetVec2(fnMax, lab.rect, ax, ay)
  if fnPiv != nil: cDuSetVec2(fnPiv, lab.rect, px, py)
  if fnPos != nil: cDuSetVec2(fnPos, lab.rect, x, y)
  lab.pAnchor = anchorName
  lab.pX = x
  lab.pY = y
  lab.placed = true

proc duStyle(lab: DuLabel; size, r, g, b: float64) =
  ## Font size and colour by RAW FIELD WRITE -- `m_fontSize` (+0x1EC, float) and
  ## `m_fontColor` (+0x150, four floats). Both are plain managed fields, so no
  ## call is needed; the dirty flag set by `duSetText` is what makes TMP notice.
  if lab.tmp == nil:
    return
  if size > 0.0:
    discard cDuWriteF32(lab.tmp, cDuOffTmpFontSize(), size)
  discard cDuWriteColor(lab.tmp, cDuOffTmpFontColor(), r, g, b, 1.0)

## Carries the text into `duNewStringImpl` -- the guarded alloc thunk passes one
## pointer, and a string is easier held in a global than marshalled through it.
## Exactly the shape `gBrandText` uses for the version brand.
var gDuStrText: string = ""

proc duNewStringImpl(a: Il2CppPtr): Il2CppPtr {.
    exportc: "aowl_du_newstring", cdecl.} =
  ## Allocates the managed `System.String` for `gDuStrText`. `a` is unused. This
  ## is NOT separately SEH-guarded: the whole overlay body already runs under one
  ## `aowl_p_p_seh`, and that guard is not re-entrant -- a nested one would
  ## disarm the outer on return and leave the rest of the body unprotected.
  result = newString(gRt, gDuStrText)

proc duSetText(lab: var DuLabel; text: string): bool =
  ## Put `text` into a cloned label, by the primitive proven live by the version
  ## brand: allocate a managed String and RAW-WRITE its pointer into `m_text`
  ## (+0xE0), then set `m_havePropertiesChanged` (+0x378) so TMP re-lays it out
  ## on its next tick.
  ##
  ## Unchanged text is a no-op, which is what keeps a 12-line panel from
  ## allocating 12 Strings every refresh forever.
  result = false
  if lab.tmp == nil:
    return
  if lab.last == text:
    return true
  var t = text
  if t.len > cDuMaxTextLen:
    # Truncate rather than refuse: a runaway nickname must not be able to stop
    # the rest of the panel from updating.
    var cut = ""
    for i in 0 ..< cDuMaxTextLen:
      cut.add t[i]
    t = cut
  gDuStrText = t
  let s = duNewStringImpl(cast[Il2CppPtr](0))
  if s == nil or cIsReadable(s, 0x14'i32) == 0'i32:
    return
  if cUxWritePtr(lab.tmp, cDuOffTmpText(), s) == 0'i32:
    return
  discard cDuWriteU8(lab.tmp, cDuOffTmpDirty(), 1'i32)
  lab.last = t
  lab.shown = t.len > 0
  result = true

proc duSetActive(lab: var DuLabel; on: bool) =
  ## Switch the whole clone on or off. Called only on a CHANGE, so an idle
  ## marker costs nothing per frame.
  if lab.go == nil or lab.active == on:
    return
  let fnAct = mi2Fn(Mi2GoSetActive)
  if fnAct == nil:
    return
  cMi2CallVPB(fnAct, lab.go, (if on: 1'i32 else: 0'i32))
  lab.active = on

proc duHide(lab: var DuLabel) =
  ## Take a label off the screen properly.
  ##
  ## The old version only blanked the text, and only when `shown` was already
  ## true -- so a clone that had never been written kept the DONOR'S caption and
  ## the donor's position, visible, forever. That is the "1.1.0.1.4677 | PvE"
  ## floating in the dead centre of the screen: marker 0, never assigned a bot,
  ## never actually hidden.
  ##
  ## Now it clears the text (the `cDuUnset` sentinel guarantees the first call
  ## really writes) AND deactivates the GameObject, which also takes the label
  ## out of the canvas batch and out of the raycaster.
  discard duSetText(lab, "")
  duSetActive(lab, false)

proc duShow(lab: var DuLabel) =
  duSetActive(lab, true)

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
  if cIsReadable(duPtrAdd(p, off), 12'i32) == 0'i32:
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
  if cIsReadable(duPtrAdd(mc, cDuOffMcRotation()), 8'i32) == 0'i32:
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
    if cIsReadable(slot, 8'i32) == 0'i32:
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
#   CANVAS UNITS    what `anchoredPosition` is in. Origin BOTTOM-left, Y grows
#                   UP. Pixels / the CanvasScaler's scaleFactor.
#   ANCHORED        the offset the widget stores: canvas units relative to its
#                   anchor point, with its pivot deciding which corner of the
#                   text sits there.
#
# `gDuCanvasScale` is the measured scaleFactor of the canvas the clones actually
# landed in (read at build time, not assumed), so these conversions are the same
# correction the ESP markers already apply.
# ---------------------------------------------------------------------------

proc duCanvasSize(cw, ch: var float64): bool =
  ## Canvas extent in canvas units. False when the client rect is not readable,
  ## in which case no drag maths is attempted at all.
  let pw = float64(cWgClientW())
  let ph = float64(cWgClientH())
  if pw < 16.0 or ph < 16.0 or gDuCanvasScale <= 0.01:
    return false
  cw = pw / gDuCanvasScale
  ch = ph / gDuCanvasScale
  true

proc duCursorCanvas(cx, cy: var float64): bool =
  ## The cursor in canvas units, Y-up. False unless the sample is inside our own
  ## client area this refresh.
  if cWgMouseOk() == 0'i32 or gDuCanvasScale <= 0.01:
    return false
  let ph = float64(cWgClientH())
  cx = float64(cWgMouseX()) / gDuCanvasScale
  cy = (ph - float64(cWgMouseY())) / gDuCanvasScale
  true

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
var gDuDragIdx = -1

proc duDragTick() =
  ## One drag step. Runs only in edit mode, only while our window has the
  ## foreground, and only on the panel's throttled refresh.
  if not gDuEdit:
    if gDuDragIdx >= 0:
      gDuDragIdx = -1
    return
  var cw = 0.0
  var ch = 0.0
  if not duCanvasSize(cw, ch):
    return
  var cx = 0.0
  var cy = 0.0
  let haveCursor = duCursorCanvas(cx, cy)

  # RELEASE first, so a release in the same refresh as a press cannot leave a
  # widget stuck to the cursor.
  if cWgLmbReleased() != 0'i32:
    if gDuDragIdx >= 0 and gDuDragIdx < gDuWidgets.len:
      gDuWidgets[gDuDragIdx].dragging = false
      duSnapWidget(gDuDragIdx, cw, ch)
      duSaveWidgets()
    gDuDragIdx = -1
    return

  # GRAB. Topmost-last wins: later widgets are drawn later, so iterating
  # backwards picks the one visually on top when two overlap.
  if cWgLmbPressed() != 0'i32 and gDuDragIdx < 0 and haveCursor:
    var i = gDuWidgets.len - 1
    while i >= 0:
      if gDuWidgets[i].on and gDuWidgets[i].w > 0.0 and gDuWidgets[i].h > 0.0:
        var l = 0.0
        var t = 0.0
        var r = 0.0
        var b = 0.0
        duWidgetRect(gDuWidgets[i], cw, ch, l, t, r, b)
        if cx >= l and cx <= r and cy <= t and cy >= b:
          var pvx = 0.0
          var pvy = 0.0
          duWidgetPivotPoint(gDuWidgets[i], cw, ch, pvx, pvy)
          gDuWidgets[i].grabDx = cx - pvx
          gDuWidgets[i].grabDy = cy - pvy
          gDuWidgets[i].dragging = true
          gDuDragIdx = i
          break
      dec i
    return

  # MOVE. `haveCursor` false (cursor left the client area mid-drag) HOLDS the
  # widget where it is rather than teleporting it to a clamped edge.
  if gDuDragIdx >= 0 and gDuDragIdx < gDuWidgets.len and
     cWgLmbHeld() != 0'i32 and haveCursor:
    var ax = 0.0
    var ay = 1.0
    var px = 0.0
    var py = 1.0
    duAnchorVec(gDuWidgets[gDuDragIdx].anchor, ax, ay, px, py)
    gDuWidgets[gDuDragIdx].x = (cx - gDuWidgets[gDuDragIdx].grabDx) - ax * cw
    gDuWidgets[gDuDragIdx].y = (cy - gDuWidgets[gDuDragIdx].grabDy) - ay * ch
  elif gDuDragIdx >= 0 and cWgLmbHeld() == 0'i32:
    # The button went up in a refresh we skipped. Treat it as a drop rather
    # than leaving a widget welded to the cursor forever.
    if gDuDragIdx < gDuWidgets.len:
      gDuWidgets[gDuDragIdx].dragging = false
      duSnapWidget(gDuDragIdx, cw, ch)
      duSaveWidgets()
    gDuDragIdx = -1

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
# Rendering a widget
#
# One label, one string, newline-separated. `duSetText` short-circuits when the
# text has not changed, so a widget whose values are steady costs one string
# comparison and no managed call at all.
#
# THE EXTENT IS AN ESTIMATE, and is labelled one. TMP's real rendered bounds are
# behind `GetPreferredValues`/`textBounds`, which are struct-returning managed
# calls this file has not byte-verified -- and `ForceMeshUpdate` on this build
# is the universal empty-body stub (`ret 0`, shared by 6,438 methods), so the
# mesh is not guaranteed refreshed at the moment we would read it anyway. What
# the estimate is used for is HIT-TESTING A DRAG, where being a few units res
# costs a slightly generous grab box and nothing else. It is never used to place
# text, only to catch a cursor.
# ---------------------------------------------------------------------------
const cDuGlyphAspect = 0.55   ## mean advance / point size for this font, approx

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

proc duUpdateWidgets() =
  ## Refresh, place and size every widget. One label per widget, taken from the
  ## same pool the old single-column panel used.
  var cw = 0.0
  var ch = 0.0
  let haveCanvas = duCanvasSize(cw, ch)
  var used = 0
  for i in 0 ..< gDuWidgets.len:
    if used >= gDuPanel.len or used >= cDuMaxWidgets:
      break
    if not gDuWidgets[i].on:
      continue
    # A widget already charged with `cDuWidgetFaultLimit` faults is skipped
    # entirely -- not retried, not recharged. This is what keeps one bad widget
    # from taking the other seven dark.
    if i < gDuWidgetFaults.len and gDuWidgetFaults[i] >= cDuWidgetFaultLimit:
      continue
    # THE BREADCRUMB: one store per stage into a file-scope volatile, so it
    # survives the guard's longjmp and the handler can name the stage AND the
    # widget. See the note in `abi/aowlspt_widget.h`.
    cWgCrumbW(int32(i))
    cWgCrumb(WgCrumbWText)
    var lines = 0
    var widest = 0
    let text = duWidgetText(gDuWidgets[i], lines, widest)
    # Extent, in canvas units, from the font size the config asked for.
    gDuWidgets[i].lines = lines
    gDuWidgets[i].w = float64(widest) * gDuCfg.panelFont * cDuGlyphAspect + 12.0
    gDuWidgets[i].h = float64(lines) * gDuCfg.panelLine + 6.0
    # A widget dragged off the canvas by a resolution change is pulled back on
    # BEFORE it is placed, so it can never become unreachable by the mouse.
    if haveCanvas:
      duClampOnScreen(i, cw, ch)
    cWgCrumb(WgCrumbWPlace)
    duPlace(gDuPanel[used], gDuWidgets[i].anchor,
            gDuWidgets[i].x, gDuWidgets[i].y)
    cWgCrumb(WgCrumbWStyle)
    # The widget being dragged is tinted, so "which one am I holding" is
    # answered on screen rather than by feel.
    if gDuEdit and gDuWidgets[i].dragging:
      duStyle(gDuPanel[used], gDuCfg.panelFont, 0.45, 1.0, 0.45)
    elif gDuEdit:
      duStyle(gDuPanel[used], gDuCfg.panelFont, 0.6, 0.85, 1.0)
    else:
      duStyle(gDuPanel[used], gDuCfg.panelFont,
              gDuCfg.panelR, gDuCfg.panelG, gDuCfg.panelB)
    cWgCrumb(WgCrumbWSetText)
    discard duSetText(gDuPanel[used], text)
    cWgCrumb(WgCrumbWShow)
    duShow(gDuPanel[used])
    inc used
  # Out of the per-widget region. The widget crumb is CLEARED rather than left
  # pointing at the last widget that rendered successfully, which would blame an
  # innocent one for a fault raised after the loop.
  cWgCrumbW(-1'i32)
  # THE EDIT-MODE BANNER, in the spare label the pool was sized for. It exists
  # because edit mode is otherwise invisible, and an invisible mode that changes
  # what a left click does is the worst kind: it says what is on, what the keys
  # are, and -- explicitly -- that the click is NOT taken from the game.
  cWgCrumb(WgCrumbBanner)
  if gDuEdit and used < gDuPanel.len:
    var b = "EDIT MODE  --  drag a widget with the left mouse button"
    b.add "\n  Ctrl+F3 leave   1-9 toggle a widget   0 reset all placements"
    b.add "\n  drops snap to screen edges, corners and to other widgets,"
    b.add "\n  and are saved to aowlspt-debugui-layout.json on every drop."
    b.add "\n  The overlay does NOT swallow the click; the game still sees it."
    b.add "\n  widgets: "
    var n = 0
    for i in 0 ..< gDuWidgets.len:
      if n >= 9:
        break
      if n > 0:
        b.add "  "
      b.add $(n + 1) & "=" & gDuWidgets[i].id &
            (if gDuWidgets[i].on: "" else: "(off)")
      inc n
    b.add "\n  layout from " & gDuLayoutSource
    duPlace(gDuPanel[used], "bottom", 0.0, 16.0)
    duStyle(gDuPanel[used], gDuCfg.panelFont, 1.0, 0.85, 0.35)
    discard duSetText(gDuPanel[used], b)
    duShow(gDuPanel[used])
    inc used
  # Every label past the last enabled widget is hidden, or a widget turned off
  # leaves its last text on screen forever.
  cWgCrumb(WgCrumbHideRest)
  for i in used ..< gDuPanel.len:
    duHide(gDuPanel[i])

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

proc duUpdatePanel() =
  ## Refresh every panel line. Positions are re-applied each refresh because the
  ## line COUNT can change between refreshes (a field that produced no text is
  ## still a slot), and re-anchoring is three cheap calls on a label that is
  ## already parented.
  let fields = duSplit(gDuCfg.panelFields, ',')
  var used = 0
  for i in 0 ..< gDuPanel.len:
    if used >= fields.len or used >= cDuMaxPanelLines:
      duHide(gDuPanel[i])
      continue
    let text = duPanelLine(fields[used])
    duPlace(gDuPanel[i], gDuCfg.panelAnchor,
            gDuCfg.panelX, gDuCfg.panelY - float64(used) * gDuCfg.panelLine)
    discard duSetText(gDuPanel[i], text)
    duShow(gDuPanel[i])
    inc used

# ---------------------------------------------------------------------------
# The in-world markers
#
# Screen-space, via `Camera.main.WorldToScreenPoint(botPosition)`. Unity's screen
# point has its ORIGIN AT THE BOTTOM-LEFT and a `z` that is the distance in front
# of the camera, so `z <= 0` is BEHIND the camera and the marker must be hidden
# (its x/y are finite there, and drawing them would put ghost markers on screen
# for everything behind you -- the classic ESP bug).
#
# The label is anchored bottom-left of the canvas so that `anchoredPosition` is
# in the same coordinate system the projection produces, which is what makes this
# a straight copy with no resolution maths.
# ---------------------------------------------------------------------------
proc duUpdateMarkers(): bool =
  ## Returns false when projection is unavailable on this build, so the caller
  ## can say so once and fall back to the panel's `botlist` line.
  let fnCam = cDuFn(DuCameraMain)
  let fnW2S = cDuFn(DuWorldToScreen)
  if fnCam == nil or fnW2S == nil:
    for i in 0 ..< gDuMarks.len:
      duHide(gDuMarks[i])
    return false
  let cam = cDuCallPV(fnCam)
  if not duOk(cam, 0x20'i32):
    # No main camera: the menu, or a loading screen. Not an error.
    for i in 0 ..< gDuMarks.len:
      duHide(gDuMarks[i])
    return true

  var eyeOk = false
  var ex = 0.0
  var ey = 0.0
  var ez = 0.0
  duPlayerPos(gDuYou, eyeOk, ex, ey, ez)

  let want = duSplit(gDuCfg.espFields, ',')
  var used = 0
  for i in 0 ..< gDuBots.len:
    if used >= gDuMarks.len:
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
      continue                      # behind the camera
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
    # Pixels -> canvas units. `gDuCanvasScale` is 1.0 when the scaler is 1 or
    # when the canvas could not be read, so this is a no-op in the case the
    # original code assumed and a correction in the case it did not.
    let inv = 1.0 / gDuCanvasScale
    duPlace(gDuMarks[used], "bottomleft",
            cDuScreenX() * inv, cDuScreenY() * inv + gDuCfg.espY)
    discard duSetText(gDuMarks[used], text)
    duShow(gDuMarks[used])
    inc used
  for i in used ..< gDuMarks.len:
    duHide(gDuMarks[i])
  result = true

# ---------------------------------------------------------------------------
# THE ONE-SHOT DIAGNOSTIC DUMP
#
# The rule in this codebase is that the client tells you; you do not reason from
# source. The first build of this overlay logged "built 9 panel line(s) and 24
# marker label(s)" and put nothing on screen, and there was no way to tell which
# of five completely different causes it was -- a collapsed rect, a wiped
# position, an inactive object, a hidden canvas, or a label drawn behind the game
# -- because the code only ever wrote and never read.
#
# So: once, on the first successful build, dump the SOURCE label and CLONE[0]
# side by side. The two columns next to each other are the answer: everything the
# clone inherited shows as an identical pair, and everything the overlay changed
# shows as a difference. Read-only, capped, and it never runs again.
# ---------------------------------------------------------------------------
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
var gDuParentRoute = "?"
var gDuParentRect: Il2CppPtr = nil

proc duRectIsSane(t: Il2CppPtr): bool =
  ## True only if `t` really is a RectTransform with a usable rect. This is the
  ## guard the first version did not have, and its absence is the whole bug:
  ## `Transform::get_root` on the version label lands on a plain Transform
  ## ('Preloader UI', the OUTERMOST root), and reading RectTransform fields off a
  ## plain Transform yields garbage -- the live dump showed w=-7268628.0 h=0.0.
  ## A clone parented there inherits no screen-space Canvas, so Unity gives each
  ## one its OWN world-space canvas: 33 clones became 33 extra render passes,
  ## which is the lag, the stutter and (with the churn on top) the crash.
  ##
  ## `RectTransform::get_rect` is an sret call; a plain Transform does not have
  ## the method at all, but the call is made through the RectTransform vtable-free
  ## static RVA, so what protects us is the SANITY of the answer, not the type.
  result = false
  if not duOk(t, 0x20'i32):
    return
  var ok = false
  duGetSret(DuGetRect, t, 4'i32, ok)
  if not ok:
    return
  let w = cDuSret2()
  let h = cDuSret3()
  # A real UI rect: positive, finite, and not absurd. 32..16384 covers every
  # sane canvas from a small panel to an 8K screen and excludes both the zero
  # rect of a plain Transform and the -7,268,628 garbage the dump showed.
  result = w > 32.0 and w < 16384.0 and h > 32.0 and h < 16384.0

## Why the walk refused, in words, for the log. Set at every early return so a
## refusal is never silent and never generic -- "duCanvasRootGo returned nil" is
## the kind of message that costs a whole cycle.
var gDuRootRefusal = "not attempted"

proc duCanvasRootGo(anchor: Il2CppPtr): Il2CppPtr =
  ## The GameObject the clones must be parented under.
  ##
  ## EVERY HOP HERE IS A MANAGED CALL ON A UnityEngine.Object, and every one of
  ## those calls is an IL2CPP internal-call wrapper that dereferences
  ## `m_CachedPtr` without checking it. So every hop is gated TWICE -- `duOk`
  ## for readability and `duUnityAlive` for the native half -- and carries its
  ## own breadcrumb, because the second live run proved that "it faulted
  ## somewhere in this proc" is not a narrow enough answer to act on.
  ##
  ## THE FAULT THIS FIXES. At the main menu, two minutes after boot, the anchor
  ## reached through `PreloaderUI._alphaVersionLabel` is a DESTROYED wrapper: the
  ## menu rebuild replaced the tree it lived in. It is perfectly readable, so the
  ## old `duOk`-only chain handed it over, and `Component::get_transform` on it
  ## faulted inside Unity's C++ on every single refresh until the overlay
  ## switched itself off.
  ##
  ## ROUTE 1, right by CONSTRUCTION rather than by lookup: the source label's
  ## OWN PARENT. A sibling of the version label is on the version label's canvas
  ## because it is in the version label's subtree -- there is no canvas to
  ## resolve and nothing to be wrong about. The live dump names it: `UpperPart`,
  ## parent[0], rect 1920x1080.
  ##
  ## The two earlier attempts both went looking for a canvas instead and both
  ## landed the clones on a DIFFERENT canvas from the source:
  ##   * `Transform::get_root` -> the outermost 'Preloader UI', a plain
  ##     Transform with no canvas above it -> a world-space canvas each.
  ##   * "highest sane RectTransform ancestor" -> 'Preloader UI' at parent[3],
  ##     which carries the OUTER canvas, not the nested one the source draws on.
  ## `Graphic.m_Canvas` was meant to fix that and did not take on the live run,
  ## so it is a CROSS-CHECK only: routes 2 and 3 exist so a build where
  ## `get_parent` is unavailable still gets something, and each says which it
  ## used.
  result = nil
  gDuParentRoute = "none"
  gDuParentRect = nil

  let fnGo = mi2Fn(Mi2GetGameObject)
  if fnGo == nil:
    gDuRootRefusal = "Component::get_gameObject did not verify on this build"
    return

  # ---- HOP 0: is the anchor itself still alive? -------------------------
  # This is the one that was missing. Everything below calls into Unity with
  # `anchor` or something derived from it as `this`.
  cWgCrumb(WgCrumbRAnchorAlive)
  if not duUnityAlive(anchor):
    gDuRootRefusal = "the anchor (PreloaderUI._alphaVersionLabel) is a " &
      "DESTROYED UnityEngine.Object -- readable, but m_CachedPtr is 0. This " &
      "is what a menu rebuild leaves behind; re-resolving next refresh."
    return

  # ---- route 1: the source label's own parent -- a sibling by construction ----
  cWgCrumb(WgCrumbRRect)
  let rect = duRectOf(anchor)
  cWgCrumb(WgCrumbRRectAlive)
  # `rect != nil` was the ONLY check here, and a non-nil pointer is not a live
  # object. Both gates, before it is ever used as a `this`.
  let rectOk = duOk(rect, 0x20'i32) and duUnityAlive(rect)
  let fnPar = cDuFn(DuGetParent)
  if not rectOk:
    gDuRootRefusal = "the anchor's RectTransform is null, unreadable or " &
      "destroyed (m_CachedPtr 0)"
  elif fnPar == nil:
    gDuRootRefusal = "Transform::get_parent did not verify on this build"
  else:
    # THE EVIDENCE, written BEFORE the call that has been dying, so it survives
    # even if this still faults. Everything here is a guarded field read; none
    # of it calls into Unity.
    if not gDuRectEvidenceLogged:
      gDuRectEvidenceLogged = true
      okLog "debugui: about to call Transform::get_parent on rect=0x" &
            hexOf(cast[uint64](rect)) & " from " & gDuRectSource &
            "; klass=0x" & hexOf(cast[uint64](duReadPtrField(rect, 0'i32))) &
            " m_CachedPtr=0x" &
            hexOf(cast[uint64](duReadPtrField(rect, cDuOffCachedPtr()))) &
            " (anchor=0x" & hexOf(cast[uint64](anchor)) & " klass=0x" &
            hexOf(cast[uint64](duReadPtrField(anchor, 0'i32))) & ")"
    cWgCrumbW(2'i32)                   # role 2: in the call itself, depth 0
    cWgCrumb(WgCrumbRParent)
    let par = cDuCallPP(fnPar, rect)
    # The parent comes back from Unity and gets the same two gates: a destroyed
    # parent is exactly as fatal as a destroyed anchor.
    if duOk(par, 0x20'i32) and duUnityAlive(par):
      cWgCrumb(WgCrumbRParSane)
      if duRectIsSane(par):
        cWgCrumb(WgCrumbRParGo)
        let go = cMi2CallPP(fnGo, par)
        if duOk(go, 0x20'i32) and duUnityAlive(go):
          gDuParentRoute = "the source label's own parent (sibling of the version label)"
          gDuParentRect = par
          gDuRootRefusal = ""
          cWgCrumb(WgCrumbRDone)
          return go
        gDuRootRefusal = "route 1: the parent's GameObject is unreadable or destroyed"
      else:
        gDuRootRefusal = "route 1: the parent is not a sane RectTransform"
    else:
      gDuRootRefusal = "route 1: Transform::get_parent returned null, " &
        "unreadable or destroyed"

  # ---- route 2: the Graphic's own Canvas ----
  cWgCrumb(WgCrumbRCanvas)
  let canvas = duReadPtrField(anchor, cDuOffTmpGCanvas())
  if duOk(canvas, 0x20'i32) and duUnityAlive(canvas):
    let cgo = cMi2CallPP(fnGo, canvas)
    if duOk(cgo, 0x20'i32) and duUnityAlive(cgo):
      let fnT = mi2Fn(Mi2GoGetTransform)
      if fnT != nil:
        let ct = cMi2CallPP(fnT, cgo)
        if duOk(ct, 0x20'i32) and duUnityAlive(ct) and duRectIsSane(ct):
          gDuParentRoute = "Graphic.m_Canvas (route 1 was unavailable)"
          gDuParentRect = ct
          gDuRootRefusal = ""
          cWgCrumb(WgCrumbRDone)
          return cgo

  # ---- route 3: the highest SANE RectTransform ancestor ----
  cWgCrumb(WgCrumbRClimb)
  if not rectOk or fnPar == nil:
    return
  var cur = rect
  var best: Il2CppPtr = nil
  var depth = 0
  while depth < 8:
    # The crumb's second slot carries `depth * 4 + role` here, so a fault in
    # this loop says WHICH iteration and whether it was gating the receiver,
    # gating the result, or inside the call. Route 1 above has no loop, which
    # is how the log already distinguished the two.
    cWgCrumb(WgCrumbRClimbParent)
    cWgCrumbW(int32(depth * 4 + 0))
    # `cur` is gated on EVERY iteration, not only the ones that came back from
    # get_parent: the first `cur` is the anchor's own rect.
    if not (duOk(cur, 0x20'i32) and duUnityAlive(cur)):
      break
    cWgCrumbW(int32(depth * 4 + 2))
    let par = cDuCallPP(fnPar, cur)
    cWgCrumbW(int32(depth * 4 + 1))
    if not (duOk(par, 0x20'i32) and duUnityAlive(par)):
      break                            # cur was the outermost root; stop
    if duRectIsSane(par):
      best = par                       # keep climbing; the highest sane one wins
    cur = par
    inc depth
  if best == nil:
    if gDuRootRefusal.len == 0 or gDuRootRefusal == "not attempted":
      gDuRootRefusal = "no route produced a parent: no sane RectTransform " &
        "ancestor within 8 hops"
    return
  let go = cMi2CallPP(fnGo, best)
  if duOk(go, 0x20'i32) and duUnityAlive(go):
    gDuParentRoute = "highest sane RectTransform ancestor (LAST RESORT -- " &
                     "expect the clones to be on the wrong canvas)"
    gDuParentRect = best
    gDuRootRefusal = ""
    cWgCrumb(WgCrumbRDone)
    result = go

proc duNoRaycast(tmp: Il2CppPtr) =
  ## Take a clone out of the raycaster.
  ##
  ## A TextMeshProUGUI is a Graphic and a Graphic is a raycast target by
  ## default, so every clone is an invisible clickable surface. The panel is a
  ## 1200-unit-wide strip; with it open, a click in the menu lands on OUR label
  ## instead of the button beneath it. That is the reported crash -- "clicking
  ## with the panel open killed the game". A read-out must never eat input.
  if tmp == nil:
    return
  let fn = cDuFn(DuSetRaycast)
  if fn != nil:
    cDuCallVPB(fn, tmp, 0'i32)
  else:
    # The setter did not verify; store the field directly. `get_raycastTarget`
    # is `movzx eax, byte [rcx+0x3A]; ret`, so the offset is not a guess -- but
    # the raw store skips SetRaycastDirty, so the graphic stays registered until
    # something else re-registers it. Better than remaining clickable.
    discard cDuWriteU8(tmp, 0x3A'i32, 0'i32)

proc duDropNestedCanvas(tmp, srcCanvas: Il2CppPtr): bool =
  ## Turn OFF a `Canvas` that `Object::Instantiate` copied onto our clone.
  ##
  ## This is the actual root cause of every canvas symptom chased so far. The
  ## version label's own GameObject carries a NESTED Canvas, so each clone gets
  ## a copy of it and reports its own canvas pointer no matter where it is
  ## parented -- which is exactly what the live log showed after the clone was
  ## made a sibling of the source. It was never a parenting problem.
  ##
  ## `Graphic.m_Canvas` (+0x60) already points at whichever Canvas the clone
  ## renders on, so there is no component lookup to do: if that pointer is not
  ## the source's canvas, it IS the copied one. Disabling it makes the clone
  ## fall through to the nearest enabled ancestor canvas.
  ##
  ## SAFETY: this only ever disables a Canvas that (1) differs from the source's
  ## and (2) lives on the CLONE'S OWN GameObject. Both are checked before
  ## anything is written, so a Canvas the game owns can never be switched off by
  ## this -- the rule in this codebase is that we write only into objects the
  ## host itself created.
  result = false
  let cv = duReadPtrField(tmp, cDuOffTmpGCanvas())
  if cv == nil or cv == srcCanvas or not duOk(cv, 0x20'i32):
    return                              # nothing copied, or already correct
  let fnGo = mi2Fn(Mi2GetGameObject)
  if fnGo == nil:
    return
  let cvGo = cMi2CallPP(fnGo, cv)
  let myGo = cMi2CallPP(fnGo, tmp)
  if cvGo == nil or myGo == nil or cvGo != myGo:
    # The offending canvas is NOT on our own object -- it is an ancestor's, and
    # ancestors belong to the game. Refuse, and say so.
    warn "debugui: clone canvas 0x" & hexOf(cast[uint64](cv)) &
         " is not on the clone's own GameObject (canvasGo=0x" &
         hexOf(cast[uint64](cvGo)) & " cloneGo=0x" &
         hexOf(cast[uint64](myGo)) & "); it belongs to the game and will NOT " &
         "be touched"
    return
  let fnEn = cDuFn(DuSetEnabled)
  if fnEn == nil:
    warn "debugui: UnityEngine.Behaviour::set_enabled did not verify on this " &
         "build, so the Canvas copied onto the clone cannot be switched off"
    return
  cDuCallVPB(fnEn, cv, 0'i32)
  okLog "debugui: disabled the nested Canvas 0x" & hexOf(cast[uint64](cv)) &
        " that Instantiate copied onto our own clone (cloneGo=0x" &
        hexOf(cast[uint64](myGo)) & "); the clone should now fall through to " &
        "the source's canvas 0x" & hexOf(cast[uint64](srcCanvas))
  result = true

# ---------------------------------------------------------------------------
# THE ONE-SHOT DIAGNOSTIC DUMP, continued
# ---------------------------------------------------------------------------
proc duDumpOne(tag: string; tmp: Il2CppPtr) =
  ## Everything about one TMP label that can decide whether it draws.
  if not duOk(tmp, cDuOffTmpRect() + 8'i32):
    info "debugui/diag " & tag & ": component not readable"
    return
  let rect = duRectOf(tmp)
  let go = duGameObjectOf(tmp)
  let canvas = duReadPtrField(tmp, cDuOffTmpGCanvas())
  let txt = duReadPtrField(tmp, cDuOffTmpText())
  info "debugui/diag " & tag & ": tmp=0x" & hexOf(cast[uint64](tmp)) &
       " go=0x" & hexOf(cast[uint64](go)) &
       " name='" & (if go != nil: duNameOf(go) else: "") & "'" &
       " cachedPtr=0x" & hexOf(cast[uint64](duReadPtrField(tmp, 0x10'i32))) &
       " activeSelf=" & duDescribeInt(DuGoActiveSelf, go) &
       " activeInHierarchy=" & duDescribeInt(DuGoActiveInHier, go) &
       " layer=" & duDescribeInt(DuGoLayer, go)
  info "debugui/diag " & tag & ": rect=0x" & hexOf(cast[uint64](rect)) &
       " anchoredPos=" & duDescribeVec2(DuGetAnchoredPos, rect) &
       " sizeDelta=" & duDescribeVec2(DuGetSizeDelta, rect) &
       " anchorMin=" & duDescribeVec2(DuGetAnchorMin, rect) &
       " pivot=" & duDescribeVec2(DuGetPivot, rect) &
       " localPos=" & duDescribeVec3(DuGetLocalPos, rect) &
       " localScale=" & duDescribeVec3(DuGetLocalScale, rect) &
       " rect=[" & duDescribeRect(rect) & "]"
  let fontSize = duReadF32Field(tmp, cDuOffTmpFontSize())
  let alpha = duReadF32Field(tmp, cDuOffTmpFontColor() + 12'i32)
  let galpha = duReadF32Field(tmp, cDuOffTmpGColor() + 12'i32)
  info "debugui/diag " & tag & ": fontSize=" & duFmt1(fontSize) &
       " fontColor.a=" & duFmt2(alpha) & " graphicColor.a=" & duFmt2(galpha) &
       " textPtr=0x" & hexOf(cast[uint64](txt)) &
       " textLen=" & $int(cDuStringLen(txt)) &
       " wordWrap=" & $int(duReadBoolField(tmp, cDuOffTmpWordWrap())) &
       " overflow=" & $int(duReadI32Field(tmp, cDuOffTmpOverflow())) &
       " autoSize=" & $int(duReadBoolField(tmp, cDuOffTmpAutosize())) &
       " maxVisChars=" & $int(duReadI32Field(tmp, cDuOffTmpMaxVisChars())) &
       " firstVis=" & $int(duReadI32Field(tmp, cDuOffTmpFirstVis())) &
       " textAlign=" & $int(duReadI32Field(tmp, cDuOffTmpTextAlign()))
  if canvas != nil:
    info "debugui/diag " & tag & ": canvas=0x" & hexOf(cast[uint64](canvas)) &
         " sortingOrder=" & duDescribeInt(DuCanvasOrder, canvas) &
         " renderMode=" & duDescribeInt(DuCanvasMode, canvas) &
         " scaleFactor=" & duDescribeScale(canvas)
  else:
    info "debugui/diag " & tag & ": Graphic.m_Canvas is NULL -- the label is " &
         "not attached to a canvas, so it cannot draw at all"
  # The parent chain, capped. This is what says WHERE the clone ended up, and
  # whether anything above it is inactive or scaled to nothing.
  var cur = rect
  var depth = 0
  while cur != nil and depth < 8:
    let fnPar = cDuFn(DuGetParent)
    if fnPar == nil:
      break
    let par = cDuCallPP(fnPar, cur)
    if not duOk(par, 0x20'i32):
      break
    let pgo = duGameObjectOf(par)
    info "debugui/diag " & tag & ": parent[" & $depth & "] t=0x" &
         hexOf(cast[uint64](par)) & " name='" &
         (if pgo != nil: duNameOf(pgo) else: "") & "'" &
         " activeSelf=" & duDescribeInt(DuGoActiveSelf, pgo) &
         " localScale=" & duDescribeVec3(DuGetLocalScale, par) &
         " rect=[" & duDescribeRect(par) & "]"
    cur = par
    inc depth

var gDuDiagDone = false

proc duDiagDump(anchor: Il2CppPtr) =
  if gDuDiagDone:
    return
  gDuDiagDone = true
  var okTargets = 0
  for i in 0 ..< int(cDuTargetCount()):
    if cDuFn(int32(i)) != nil: inc okTargets
  info "debugui/diag: " & $okTargets & " of " & $int(cDuTargetCount()) &
       " managed targets verified; screen=" & duDescribeScreen()
  duDumpOne("SOURCE(version label)", anchor)
  if gDuPanel.len > 0:
    duDumpOne("CLONE[0](panel line 0)", gDuPanel[0].tmp)
  if gDuMarks.len > 0:
    duDumpOne("CLONE[m0](marker 0)", gDuMarks[0].tmp)

# ---------------------------------------------------------------------------
# Building and tearing down the label pool
# ---------------------------------------------------------------------------
## duBUILD FAULTS, counted separately from widget faults.
##
## They are not attributable to any widget -- the pool does not exist yet when
## they happen -- so the per-widget retirement cannot save the panel from them.
## That is exactly what the live run hit: eight identical faults in `duBuild`,
## and a black screen.
##
## The response is to DEGRADE, not to die. After `cDuBuildFaultsBeforeMinimal`
## faults inside `duBuild` the pool is rebuilt at its MINIMUM size -- one panel
## label, no markers. If the fault is in the ninth clone, or anywhere in the
## marker loop, a one-label panel still draws and the user gets a read-out
## instead of nothing.
##
## It also PARTITIONS the cause, which is the more valuable half: if the minimum
## builds, the fault is in the pool size or a later clone; if the minimum faults
## too, it is in the very first `Instantiate` and nothing about the widget work
## is implicated at all.
const cDuBuildFaultsBeforeMinimal = 3
var gDuBuildFaults = 0
var gDuMinimalLogged = false

var gDuRebuilds = 0
var gDuRootRefusalLogged = ""

proc duInvalidateIfStale() =
  ## RE-RESOLVE RATHER THAN CACHE ACROSS A MENU REBUILD.
  ##
  ## `gDuAnchorTmp`, `gDuProbe`, `gDuPanel` and `gDuMarks` are all pointers into
  ## the tree that was live when the pool was built. A menu rebuild destroys
  ## that tree: the wrappers stay readable, so nothing here looks wrong, and
  ## every managed call the refresh makes goes into freed native memory.
  ##
  ## The version brand and the hide-seasons code both hit this and both had to
  ## stop caching. The overlay cannot stop caching -- it owns 33 clones -- so it
  ## does the next thing: it notices, throws the pool away, and builds again.
  ##
  ## The clones themselves are NOT destroyed by us. They were children of the
  ## destroyed tree and Unity has already taken them with it; calling Destroy on
  ## a dead wrapper is the very fault this is avoiding. Dropping the references
  ## is the whole teardown.
  if not gDuBuilt:
    return
  if duUnityAlive(gDuAnchorTmp):
    return
  inc gDuRebuilds
  gDuBuilt = false
  gDuBuildFailed = false
  gDuPanel = @[]
  gDuMarks = @[]
  gDuProbe = DuLabel(tmp: nil, rect: nil, last: cDuUnset, shown: false,
                     placed: false, pAnchor: "", pX: 0.0, pY: 0.0)
  gDuProbeWaits = 0
  gDuCanvasDropTried = false
  gDuAnchorTmp = nil
  gDuRootGo = nil
  # The fault budget is reset too. Those faults were caused by a tree that no
  # longer exists; carrying them forward would retire the overlay for a
  # condition that has already been repaired.
  gDuBuildFaults = 0
  gDuMinimalLogged = false
  if gDuRebuilds <= 8 or (gDuRebuilds mod 50) == 0:
    okLog "debugui: the anchor's native half is gone (menu rebuild #" &
          $gDuRebuilds & "); dropped the label pool and re-resolving from " &
          "PreloaderUI on the next refresh. Nothing was destroyed by us."


proc duBuild(preloader: Il2CppPtr): bool =
  ## Clone every label the configuration asks for, once. Returns false while the
  ## anchor is not yet reachable (the caller retries next frame) and latches
  ## `gDuBuildFailed` only when a clone genuinely could not be made -- retrying a
  ## real failure every frame forever would be its own performance bug.
  if gDuBuilt:
    return true
  if gDuBuildFailed:
    return false
  cWgCrumb(WgCrumbBAnchor)
  cWgCrumbW(-1'i32)
  let anchor = duFindAnchor(preloader)
  if anchor == nil:
    return false                       # not yet; try again next frame
  cWgCrumb(WgCrumbBRoot)
  let rootGo = duCanvasRootGo(anchor)
  if rootGo == nil:
    # SAY WHY, and say it once per distinct reason. `duCanvasRootGo` is called
    # every throttled refresh until it succeeds, so an unconditional log would
    # be a per-second spam; a log only on CHANGE means the reason appears the
    # first time and again whenever it becomes a different reason.
    if gDuRootRefusal != gDuRootRefusalLogged:
      gDuRootRefusalLogged = gDuRootRefusal
      warn "debugui: the canvas-root walk declined -- " & gDuRootRefusal &
           ". No clone was made and nothing in the game was touched; the " &
           "overlay retries on the next refresh."
    return false
  gDuAnchorTmp = anchor
  gDuRootGo = rootGo

  # ---------------------------------------------------------------------
  # THE PROBE CLONE, and the canvas assertion.
  #
  # Build exactly ONE label first and check which canvas it landed on. If it is
  # not the source's canvas, do NOT go on to build thirty-two more: that is the
  # regression that cost the user two crashes, and one stray inactive clone is a
  # far cheaper way to find out than thirty-three live ones.
  #
  # A clone's `Graphic.m_Canvas` is resolved by Unity, not by us, and is null
  # until the graphic has been through a canvas update -- so an unresolved
  # canvas means TRY AGAIN NEXT FRAME, not FAIL. The probe is kept in a global
  # across those frames precisely so that retrying does not clone every frame.
  # ---------------------------------------------------------------------
  if gDuProbe.tmp == nil:
    cWgCrumb(WgCrumbBProbeClone)
    gDuProbe = duCloneLabel(anchor, rootGo)
    if gDuProbe.tmp == nil:
      gDuBuildFailed = true
      warn "debugui: Object::Instantiate produced no usable label clone; the " &
           "overlay cannot draw on this build (nothing was changed in the game)"
      return false
    cWgCrumb(WgCrumbBProbeDraw)
    duMakeDrawable(gDuProbe, 400.0, 20.0)
  cWgCrumb(WgCrumbBSrcCanvas)
  let srcCv0 = duReadPtrField(anchor, cDuOffTmpGCanvas())
  cWgCrumb(WgCrumbBProbeCanvas)
  let probeCv = duReadPtrField(gDuProbe.tmp, cDuOffTmpGCanvas())
  if probeCv == nil:
    inc gDuProbeWaits
    if gDuProbeWaits > 240:
      gDuBuildFailed = true
      duHide(gDuProbe)
      warn "debugui: the probe clone's Graphic.m_Canvas never resolved after " &
           $gDuProbeWaits & " refreshes (parent route = " & gDuParentRoute &
           "). Refusing to build the rest of the overlay rather than put " &
           "labels on an unknown canvas. Nothing in the game was changed."
      return false
    return false                       # not yet resolved; try again next frame
  if probeCv != srcCv0:
    # A MISMATCH IS NOT YET A VERDICT.
    #
    # Two things can produce it, and they want opposite responses:
    #   * `Instantiate` copied the source's own nested Canvas onto our clone.
    #     That is the real cause, and it is FIXABLE -- switch the copy off and
    #     the clone falls through to the source's canvas.
    #   * the clone is only part-initialised this frame, and Unity has not yet
    #     re-resolved its canvas. That resolves itself and must not be punished.
    #
    # So: try the fix, then give it several frames to settle, and only refuse if
    # it is still wrong afterwards. Refusing on the first frame is what made the
    # last build report a permanent failure for a condition it could have
    # repaired.
    if not gDuCanvasDropTried:
      gDuCanvasDropTried = true
      cWgCrumb(WgCrumbBDropCanvas)
      discard duDropNestedCanvas(gDuProbe.tmp, srcCv0)
      return false                     # re-check next frame
    inc gDuProbeWaits
    if gDuProbeWaits <= 120:
      return false                     # still settling; look again next frame
    gDuBuildFailed = true
    duHide(gDuProbe)
    warn "debugui: REFUSING TO BUILD. After disabling the copied Canvas and " &
         "waiting " & $gDuProbeWaits & " refreshes, the probe clone is still " &
         "on canvas 0x" & hexOf(cast[uint64](probeCv)) & " (renderMode=" &
         duDescribeInt(DuCanvasMode, probeCv) & ") while the source is on 0x" &
         hexOf(cast[uint64](srcCv0)) & " (renderMode=" &
         duDescribeInt(DuCanvasMode, srcCv0) & "); parent route = " &
         gDuParentRoute & ", parentRect=[" & duDescribeRect(gDuParentRect) &
         "]. Exactly one clone was made and it has been switched off. " &
         "Nothing else in the game was changed."
    return false
  cWgCrumb(WgCrumbBAssertLog)
  okLog "debugui: canvas assertion PASSED -- probe clone and source label are " &
        "both on canvas 0x" & hexOf(cast[uint64](srcCv0)) & " (renderMode=" &
        duDescribeInt(DuCanvasMode, srcCv0) & ", scaleFactor=" &
        duDescribeScale(srcCv0) & ") via " & gDuParentRoute &
        ". One canvas, one render pass; the rest of the pool is safe to build."

  # ONE LABEL PER WIDGET (plus one for the edit-mode banner), not one per line.
  # The pool is sized here, once, and cannot grow later -- so adding a widget to
  # the config takes effect on the next game start, exactly as adding a panel
  # field always did. `cDuMaxWidgets` is the ceiling whatever the config says.
  var nPanel = gDuWidgets.len + 1
  if nPanel > cDuMaxPanelLines: nPanel = cDuMaxPanelLines
  if not gDuCfg.panelOn: nPanel = 0
  var nMark = gDuCfg.espMax
  if not gDuCfg.espOn: nMark = 0
  if nMark > cDuMaxMarkers: nMark = cDuMaxMarkers

  # DEGRADE RATHER THAN DIE -- see `gDuBuildFaults` above. Stop asking for
  # thirty-three clones once several attempts have faulted, and ask for one.
  if gDuBuildFaults >= cDuBuildFaultsBeforeMinimal:
    nPanel = 1
    nMark = 0
    if not gDuMinimalLogged:
      gDuMinimalLogged = true
      warn "debugui: duBuild has faulted " & $gDuBuildFaults & " times; " &
           "retrying at MINIMUM size (1 panel label, 0 markers) rather than " &
           "going dark. If this builds, the fault is in the pool size or in a " &
           "later clone; if it faults too, it is the first Instantiate."

  var panel: seq[DuLabel] = @[]
  # The probe becomes panel line 0 when the panel wants one, so the assertion
  # costs nothing; otherwise it is switched off and left alone.
  var reused = false
  if nPanel > 0:
    var p0 = gDuProbe
    cWgCrumb(WgCrumbBProbeReuse)
    duStyle(p0, gDuCfg.panelFont, gDuCfg.panelR, gDuCfg.panelG, gDuCfg.panelB)
    duMakeDrawable(p0, 1200.0, gDuCfg.panelLine * 1.6)
    panel.add p0
    reused = true
  else:
    duHide(gDuProbe)
  for i in (if reused: 1 else: 0) ..< nPanel:
    # The crumb's widget slot carries the CLONE INDEX here, so a fault names
    # which of the nine died rather than only that one of them did.
    cWgCrumbW(int32(i))
    cWgCrumb(WgCrumbBPanelClone)
    var lab = duCloneLabel(anchor, rootGo)
    if lab.tmp == nil:
      break
    cWgCrumb(WgCrumbBPanelDraw)
    duStyle(lab, gDuCfg.panelFont, gDuCfg.panelR, gDuCfg.panelG, gDuCfg.panelB)
    duMakeDrawable(lab, 1200.0, gDuCfg.panelLine * 1.6)
    # Born hidden. A fresh clone still carries the DONOR'S caption and the
    # DONOR'S position, and the update pass only ever touches the labels it
    # actually uses -- so anything not hidden here is a stray label sitting in
    # the middle of the screen reading "1.1.0.1.4677 | PvE".
    duHide(lab)
    panel.add lab
  var marks: seq[DuLabel] = @[]
  for i in 0 ..< nMark:
    cWgCrumbW(int32(i))
    cWgCrumb(WgCrumbBMarkClone)
    var lab = duCloneLabel(anchor, rootGo)
    if lab.tmp == nil:
      break
    cWgCrumb(WgCrumbBMarkDraw)
    duStyle(lab, gDuCfg.espFont, gDuCfg.espR, gDuCfg.espG, gDuCfg.espB)
    duMakeDrawable(lab, 400.0, gDuCfg.espFont * 1.6)
    # Markers especially: with ESP off, or in the menu where there are no bots,
    # `duUpdateMarkers` never assigns them, so an unhidden marker is visible
    # forever showing the donor's text. Every one of the 24 was doing that.
    duHide(lab)
    marks.add lab
  if panel.len == 0 and marks.len == 0:
    gDuBuildFailed = true
    warn "debugui: Object::Instantiate produced no usable label clone; the " &
         "overlay cannot draw on this build (nothing was changed in the game)"
    return false
  gDuPanel = panel
  gDuMarks = marks
  gDuBuilt = true
  # The canvas the clones actually landed in, and its scale factor. Unity's
  # WorldToScreenPoint answers in PIXELS; `anchoredPosition` is in CANVAS UNITS.
  # They are the same number only when the CanvasScaler is at 1, and EFT's menu
  # canvas is not -- so an uncorrected marker for a bot at the middle of the
  # screen lands off the edge of it.
  cWgCrumb(WgCrumbBScale)
  cWgCrumbW(-1'i32)
  gDuCanvasScale = 1.0
  if panel.len > 0:
    let cv = duReadPtrField(panel[0].tmp, cDuOffTmpGCanvas())
    let fn = cDuFn(DuCanvasScale)
    if fn != nil and duOk(cv, 0x20'i32):
      let s = cDuCallFP(fn, cv)
      if s > 0.01 and s < 100.0:
        gDuCanvasScale = s
  cWgCrumb(WgCrumbBDiagDump)
  duDiagDump(anchor)
  # PLACEMENT READ-BACK. The clone starts life at the source's anchoredPosition,
  # which on a centre-pivot parent is the middle of the screen -- that is what
  # the user saw. So place panel line 0 for real and then ASK where it ended up,
  # rather than assuming the write took. Intended vs actual, side by side.
  cWgCrumb(WgCrumbBReadback)
  if gDuPanel.len > 0:
    let wantX = gDuCfg.panelX
    let wantY = gDuCfg.panelY
    duPlace(gDuPanel[0], gDuCfg.panelAnchor, wantX, wantY)
    okLog "debugui: placement check, panel line 0 -- anchor='" &
          gDuCfg.panelAnchor & "' intended anchoredPos=(" & duFmt1(wantX) &
          "," & duFmt1(wantY) & ") actual=" &
          duDescribeVec2(DuGetAnchoredPos, gDuPanel[0].rect) &
          " anchorMin=" & duDescribeVec2(DuGetAnchorMin, gDuPanel[0].rect) &
          " pivot=" & duDescribeVec2(DuGetPivot, gDuPanel[0].rect) &
          " parentRect=[" & duDescribeRect(gDuParentRect) & "]"
  okLog "debugui: parent route = " & gDuParentRoute &
        "; parentRect=[" & duDescribeRect(gDuParentRect) & "]" &
        "; canvas 0x" & hexOf(cast[uint64](srcCv0)) &
        " shared by the source and every clone (asserted before building)"
  okLog "debugui: built " & $panel.len & " widget label(s) and " & $marks.len &
        " marker label(s), all born hidden and none a raycast target; layout " &
        "from " & gDuCfg.source
  return true

proc duHideAll() =
  for i in 0 ..< gDuPanel.len:
    duHide(gDuPanel[i])
  for i in 0 ..< gDuMarks.len:
    duHide(gDuMarks[i])

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
  let selfRaw = cRegsInt(regs, 0'i32)         # RCX = the PreloaderUI `this`
  if selfRaw == 0'u64:
    return cast[Il2CppPtr](1)
  let preloader = cast[Il2CppPtr](selfRaw)
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
      if cWgCtrlDown() != 0'i32:
        if not gDuVisible:
          gDuVisible = true
          duLoadLayout()
          duLoadWidgets()
        gDuEdit = not gDuEdit
        if not gDuEdit:
          gDuDragIdx = -1
          for i in 0 ..< gDuWidgets.len:
            gDuWidgets[i].dragging = false
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
              "re-read from " & gDuCfg.source & " + " & gDuLayoutSource & ")"
      else:
        gDuEdit = false
        gDuDragIdx = -1
        if gDuCfg.espVk <= 0:
          gDuEspVisible = false
        duHideAll()
        okLog "debugui: panel OFF"
    if gDuCfg.espVk > 0 and cDuKeyEdge(int32(gDuCfg.espVk)) != 0'i32:
      gDuEspVisible = not gDuEspVisible
      if not gDuEspVisible:
        for i in 0 ..< gDuMarks.len:
          duHide(gDuMarks[i])

  if not gDuVisible and not gDuEspVisible:
    return cast[Il2CppPtr](1)

  # Throttle. The panel is a debug read-out, not an instrument: refreshing it
  # every tenth frame is indistinguishable to a human and costs a tenth as much.
  # The markers ride the same throttle -- a marker that lags a frame or two is
  # still exactly where the bot is standing, and a frozen bot does not move at
  # all, which is the case being investigated.
  if (gDuFires mod gDuCfg.panelThrottle) != 0:
    return cast[Il2CppPtr](1)

  # Before anything else in the build path: has the tree we cached been
  # replaced? A menu rebuild leaves every cached pointer readable and dead.
  duInvalidateIfStale()
  cWgCrumb(WgCrumbBuild)
  if not duBuild(preloader):
    return cast[Il2CppPtr](1)

  # The cached GameWorld goes stale at the end of a raid; drop it rather than
  # keep reading a dead object.
  if gDuGameWorld != nil and
     not duOk(gDuGameWorld, cBdOffRegPlayers() + 8'i32):
    gDuGameWorld = nil

  cWgCrumb(WgCrumbScanWorld)
  duScanWorld()

  if gDuVisible:
    # The pointer is sampled ONCE per refresh, before anything reads it, so a
    # drag cannot see the cursor in two places within one frame and the button
    # edges are computed exactly once. It is a `GetCursorPos` and a
    # `GetAsyncKeyState`: no message, no hook, nothing swallowed from the game.
    cWgCrumb(WgCrumbMouse)
    discard cWgMouseSample()
    cWgCrumb(WgCrumbEditKeys)
    duEditKeys()
    cWgCrumb(WgCrumbDrag)
    duDragTick()
    duUpdateWidgets()
  cWgCrumb(WgCrumbMarkers)
  if gDuEspVisible:
    if not duUpdateMarkers():
      if not gDuEspUnavailableLogged:
        gDuEspUnavailableLogged = true
        warn "debugui: Camera::get_main / Camera::WorldToScreenPoint did not " &
             "verify on this build, so in-world markers are unavailable. The " &
             "panel's `botlist` field still shows every AI bot's world " &
             "coordinates and distance -- add it to panelFields."
  cWgCrumb(WgCrumbDone)
  return cast[Il2CppPtr](1)

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
    # THE SLOT MEANS TWO DIFFERENT THINGS, so it is never rendered ambiguously.
    # In the draw loop it is a WIDGET index; inside duBuild's two pool loops it
    # is a CLONE index, and printing a widget id for one of those would name an
    # innocent widget for a fault raised before any widget existed.
    let isCloneIdx = (stage == WgCrumbBPanelClone or
                      stage == WgCrumbBPanelDraw or
                      stage == WgCrumbBMarkClone or
                      stage == WgCrumbBMarkDraw)
    # A THIRD meaning for the same slot, in the canvas-root walk: packed
    # `depth * 4 + role`. Three meanings is one too many for a bare integer, so
    # each is decoded explicitly and none is ever printed raw.
    let isWalkSlot = (stage == WgCrumbRClimbParent or stage == WgCrumbRParent)
    if isWalkSlot and wi >= 0:
      where.add " -- climb depth " & $int(cWgCrumbDepth(int32(wi))) & ", " &
                $cWgCrumbRoleC(int32(wi))
      if gDuRectSource.len > 0:
        where.add "; the rect came from " & gDuRectSource
    elif isCloneIdx and wi >= 0:
      where.add " -- clone index " & $wi
    elif not isCloneIdx and not isWalkSlot and wi >= 0 and
         wi < gDuWidgets.len:
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
    if stage >= WgCrumbBAnchor and stage <= WgCrumbBReadback:
      inc gDuBuildFaults

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

proc bindDebugUi(verbose: bool): bool =
  ## Installs the kind=10 PREFIX detour on `EFT.UI.PreloaderUI::Update` from the
  ## verified static target in `aowlspt_debugui.h`. Opt-in (`debugUi`/`debugEsp`);
  ## binds nothing on a build whose prologue differs, in which case the overlay
  ## is simply absent.
  if gDebugUiSlot >= 0:
    return true
  if not gReady or gDisableDrain:
    return false
  # The widget set is read at BIND, not at first F3, because `duBuild` sizes the
  # label pool from it and the pool is built once. Reading it here means the
  # count on screen matches the count in the config from the very first press.
  # Both files are re-read on every toggle-ON as well, so editing them still
  # needs no restart -- only ADDING a widget does.
  duLoadWidgets()
  okLog "debugui: " & $gDuWidgets.len & " widget(s) configured -- " &
        gDuLayoutSource
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
