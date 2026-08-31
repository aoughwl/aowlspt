## The nimony face of `abi/aowlspt_admin.h` -- the shared-memory region the mod
## publishes into and the native D3D11 HUD (in the overlay) draws from.
##
## Same shape as `host/Aowlspt.Overlay/aowloverlay.nim`: the C is header-only, so
## the emit pulls the definitions into this translation unit and every entry is
## `importc ... nodecl`. The mod and the overlay each get their own copy of the
## header's `static` functions; the state they actually share is the named file
## mapping `aowl_admin_map` returns, so both talking to it is two views of one
## region, not two copies of a global.

# AOWL_ADM_PROF opts this translation unit into the L4 phase brackets inside
# `aowl_admin_pos_live` (see the macro block at the top of aowlspt_admin.h). The
# OVERLAY includes the same header WITHOUT this define and therefore gets no
# brackets and no link dependency on `adm/admprof.nim`'s translation unit. The
# brackets are additionally no-ops at runtime until the profiler is enabled,
# which is flag-gated and DEFAULT OFF.
{.emit: """
#define AOWL_ADM_PROF
#include "aowlspt_admin.h"
""".}
# The overlay-mask suppression hook binds the HOST export `aowl_ui_overlay_mask`,
# which lives in the host DLL, not in this mod. The mod links standalone, so the
# symbol cannot be resolved at link time (and #include-ing aowlspt_uistate.h is
# wrong -- it carries the host-side dllexport body plus its shim deps). It is
# resolved at RUNTIME with GetModuleHandle/GetProcAddress, exactly as the fov mod
# does for aowl_host_gameworld, and called through this zero-arg C thunk.
{.emit: """static uint32_t aowl_adm_u32_v(void* f) { return ((uint32_t(*)(void))f)(); }""".}

type
  AdminRegion* = pointer   ## an `AowlAdminShared*`, opaque on this side

# Toggle bit indices -- must match the enum in aowlspt_admin.h.
const
  admEsp*        = 0'i32
  admGodmode*    = 1'i32
  admStamina*    = 2'i32
  admNoRecoil*   = 3'i32
  admNoWeight*   = 4'i32
  admInstaHeal*  = 5'i32
  admAmmo*       = 6'i32
  admThermal*    = 7'i32
  admNightVis*   = 8'i32
  admFly*        = 9'i32
  admTeleport*   = 10'i32
  admTimeOfDay*  = 11'i32
  admCount*      = 12'i32

# Side codes.
const
  sideUnknown* = 0'i32
  sideFriend*  = 1'i32
  sideEnemy*   = 2'i32
  sideScav*    = 3'i32
  sideBoss*    = 4'i32

# Entity flags.
const
  flagIsAI*     = 0x1'u32
  flagDead*     = 0x2'u32
  flagOnScreen* = 0x4'u32

# --------------------------------------------------------------- C surface

proc cMap(): AdminRegion {.importc: "aowl_admin_map", nodecl.}
proc cSeed(s: AdminRegion) {.importc: "aowl_admin_seed_defaults", nodecl.}
proc cToggleGet(s: AdminRegion; bit: int32): int32 {.
  importc: "aowl_admin_toggle_get", nodecl.}
proc cToggleSet(s: AdminRegion; bit, on: int32) {.
  importc: "aowl_admin_toggle_set", nodecl.}
proc cSetCap(s: AdminRegion; mask: uint32) {.
  importc: "aowl_admin_set_capability", nodecl.}
proc cSetInRaid(s: AdminRegion; v: int32) {.
  importc: "aowl_admin_set_inraid", nodecl.}
proc cSetStatus(s: AdminRegion; text: cstring) {.
  importc: "aowl_admin_set_status", nodecl.}
proc cFrameBegin(s: AdminRegion; w, h: int32) {.
  importc: "aowl_admin_frame_begin", nodecl.}
proc cFrameAdd(s: AdminRegion; cx, top, bottom, health, maxHealth, distance: cfloat;
               side: int32; flags: uint32; name: cstring) {.
  importc: "aowl_admin_frame_add", nodecl.}
proc cFrameCommit(s: AdminRegion) {.importc: "aowl_admin_frame_commit", nodecl.}
proc cProject(m: ptr cfloat; x, y, z: cfloat; w, h: int32;
              sx, sy: ptr cfloat): int32 {.importc: "aowl_admin_project", nodecl.}
proc cMatMul(a, b, outp: ptr cfloat) {.importc: "aowl_admin_mat_mul", nodecl.}

proc cGameWorld(): pointer {.importc: "aowl_admin_gameworld", nodecl.}
proc cGwState(): int32 {.importc: "aowl_admin_gw_state", nodecl.}
proc admGetModuleHandleA(name: cstring): pointer {.
  stdcall, dynlib: "kernel32", importc: "GetModuleHandleA", sideEffect.}
proc admGetProcAddress(m: pointer; name: cstring): pointer {.
  stdcall, dynlib: "kernel32", importc: "GetProcAddress", sideEffect.}
proc admU32V(f: pointer): uint32 {.importc: "aowl_adm_u32_v", nodecl.}

proc cCamSample(): int32 {.importc: "aowl_admin_cam_sample", nodecl.}
proc cCamState(): int32 {.importc: "aowl_admin_cam_state", nodecl.}
proc cCamReady(): int32 {.importc: "aowl_admin_cam_ready", nodecl.}
proc cCamGen(): int32 {.importc: "aowl_admin_cam_gen", nodecl.}
proc cCamStale(): int32 {.importc: "aowl_admin_cam_stale", nodecl.}
proc cCamDisabled(): int32 {.importc: "aowl_admin_cam_disabled", nodecl.}
proc cCamRoute(): int32 {.importc: "aowl_admin_cam_route_get", nodecl.}
proc cCamMgrBound(): int32 {.importc: "aowl_admin_cam_mgr_bound", nodecl.}
proc cCamMainNulls(): int32 {.importc: "aowl_admin_cam_main_nulls", nodecl.}
proc cCamMgrNulls(): int32 {.importc: "aowl_admin_cam_mgr_nulls", nodecl.}
proc cCamFldNulls(): int32 {.importc: "aowl_admin_cam_fld_nulls", nodecl.}
proc cCamSelftestFails(): int32 {.importc: "aowl_admin_cam_selftest_fails", nodecl.}
proc cW2s(x, y, z: cfloat; w, h: int32; sx, sy: ptr cfloat): int32 {.
  importc: "aowl_admin_w2s", nodecl.}

proc cGodmode(on: int32; rva: uint32): int32 {.importc: "aowl_admin_godmode", nodecl.}
proc cGodOn(): int32 {.importc: "aowl_admin_god_is_on", nodecl.}
proc cGameAsm(): int32 {.importc: "aowl_admin_gameasm_present", nodecl.}
proc cSpawnPending(s: AdminRegion): int32 {.
  importc: "aowl_admin_spawn_pending", nodecl.}
proc cSpawnDone(s: AdminRegion; req: int32; text: cstring) {.
  importc: "aowl_admin_spawn_done", nodecl.}
proc cSpawnNote(s: AdminRegion; text: cstring) {.
  importc: "aowl_admin_spawn_note", nodecl.}
proc cSpawnInflight(s: AdminRegion): int32 {.
  importc: "aowl_admin_spawn_inflight", nodecl.}
proc cSpawnCount(s: AdminRegion): int32 {.
  importc: "aowl_admin_spawn_count", nodecl.}
proc cSpawnCondition(s: AdminRegion): int32 {.
  importc: "aowl_admin_spawn_condition", nodecl.}
proc cQueryLen(s: AdminRegion): int32 {.importc: "aowl_admin_query_len", nodecl.}
proc cQueryAt(s: AdminRegion; i: int32): int32 {.
  importc: "aowl_admin_query_at", nodecl.}
proc cGetW(s: AdminRegion): int32 {.importc: "aowl_admin_get_w", nodecl.}
proc cGetH(s: AdminRegion): int32 {.importc: "aowl_admin_get_h", nodecl.}
proc cRp(o: pointer; off: int32): pointer {.importc: "aowl_admin_rp", nodecl.}
proc cRi(o: pointer; off: int32): int32 {.importc: "aowl_admin_ri", nodecl.}
proc cRf(o: pointer; off: int32): cfloat {.importc: "aowl_admin_rf", nodecl.}
proc cWf(o: pointer; off: int32; v: cfloat) {.importc: "aowl_admin_wf", nodecl.}
proc cRb(o: pointer; off: int32): int32 {.importc: "aowl_admin_rb", nodecl.}
proc cWb(o: pointer; off: int32; v: int32): int32 {.importc: "aowl_admin_wb", nodecl.}

# The region-readability cache that sits under every rd*/wr* above and under
# every hop in `aowl_admin_pos_live`. Counters, not claims -- see the block in
# abi/aowlspt_admin.h.
proc cRdcHits(): int64 {.importc: "aowl_admin_rdc_hits", nodecl.}
proc cRdcMisses(): int64 {.importc: "aowl_admin_rdc_misses", nodecl.}
proc cRdcFlushes(): int64 {.importc: "aowl_admin_rdc_flushes", nodecl.}
proc cRdcUncacheable(): int64 {.importc: "aowl_admin_rdc_uncacheable", nodecl.}
proc cRdcEvictLive(): int64 {.importc: "aowl_admin_rdc_evict_live", nodecl.}
proc cRdcExpired(): int64 {.importc: "aowl_admin_rdc_expired", nodecl.}
proc cRdcAudits(): int64 {.importc: "aowl_admin_rdc_audits", nodecl.}
proc cRdcDisagree(): int64 {.importc: "aowl_admin_rdc_disagree", nodecl.}
proc cRdcFlush*() {.importc: "aowl_admin_rdc_flush", nodecl.}

proc rdCacheText*(): string =
  ## The cache's OWN behaviour as a measured number. Three outcomes: a hit rate
  ## it actually achieved, "NEVER RAN" when nothing was ever looked up (which is
  ## not the same as "every lookup missed"), and a hard FAIL if the replicated
  ## predicate ever disagreed with `aowl_admin_readable_raw`.
  let h = cRdcHits()
  let m = cRdcMisses()
  let tot = h + m
  if tot <= 0:
    return "rdcache: NEVER RAN -- 0 lookups. That is NOT 'every lookup " &
           "missed' and NOT 'the cache works'; nothing was measured."
  let pct = (h * 100'i64) div tot
  var s = "rdcache: hits=" & $h & " misses=" & $m & " (" & $pct &
          "% hit) syscalls-avoided=" & $h & " expired=" & $cRdcExpired() &
          " evict-live=" & $cRdcEvictLive() &
          " small-region-positives-not-cached=" & $cRdcUncacheable() &
          " flushes=" & $cRdcFlushes()
  # THE CHECK THAT CAN FAIL: the fast path is compared against the real
  # predicate on a sample of misses, and a single disagreement condemns it.
  let a = cRdcAudits()
  if a <= 0:
    s = s & ". pred-audit: INCONCLUSIVE -- 0 audits sampled, so the " &
        "replication is UNVERIFIED in this run"
  elif cRdcDisagree() > 0:
    s = s & ". pred-audit: FAIL -- " & $cRdcDisagree() & " of " & $a &
        " audited misses DISAGREED with aowl_admin_readable_raw. The " &
        "replicated predicate has DRIFTED; every guarded read in this run is " &
        "suspect"
  else:
    s = s & ". pred-audit=agrees/" & $a &
        " (the fast path never disagreed with the real predicate)"
  s

# The live world position: a byte-verified direct call at EFT.Player::get_Position
# @0x6F32C0, sampled on Unity's thread into a double-buffered snapshot the host
# thread reads back. See the long block in abi/aowlspt_admin.h for the
# disassembly and the metadata that establish every offset and the sret shape.
proc cPosArm(): int32 {.importc: "aowl_admin_pos_arm", nodecl.}
proc cPosArmed(): int32 {.importc: "aowl_admin_pos_armed", nodecl.}
proc cPosBegin() {.importc: "aowl_admin_pos_begin", nodecl.}
proc cPosAdd(p: pointer): int32 {.importc: "aowl_admin_pos_add", nodecl.}
proc cPosCommit() {.importc: "aowl_admin_pos_commit", nodecl.}
proc cPosCount(): int32 {.importc: "aowl_admin_pos_count", nodecl.}
proc cPosGen(): int32 {.importc: "aowl_admin_pos_gen_get", nodecl.}
proc cPosStatAt(code: int32): int32 {.importc: "aowl_admin_pos_stat_at", nodecl.}
proc cPosGet(p: pointer; x, y, z: ptr cfloat): int32 {.
  importc: "aowl_admin_pos_get", nodecl.}

# --------------------------------------------------------------- public

proc adminMap*(): AdminRegion =
  ## Map (or open) the shared region. NULL if the OS refused, which every caller
  ## treats as "no HUD" rather than an error.
  cMap()

proc adminSeedDefaults*(s: AdminRegion) =
  ## ESP + God mode on, the rest off -- once per region. A no-op after the first
  ## call or if the menu has already been used.
  if s != nil: cSeed(s)

proc toggleOn*(s: AdminRegion; bit: int32): bool =
  s != nil and cToggleGet(s, bit) != 0'i32

proc setToggle*(s: AdminRegion; bit: int32; on: bool) =
  ## Used at load to apply config.json's initial states. After that the F6 menu
  ## (in the overlay) owns the toggles.
  if s != nil: cToggleSet(s, bit, if on: 1'i32 else: 0'i32)

proc setCapability*(s: AdminRegion; mask: uint32) =
  if s != nil: cSetCap(s, mask)

proc setInRaid*(s: AdminRegion; inRaid: bool) =
  if s != nil: cSetInRaid(s, if inRaid: 1'i32 else: 0'i32)

proc setStatus*(s: AdminRegion; text: string) =
  if s == nil: return
  var t = text
  cSetStatus(s, toCString(t))

proc frameBegin*(s: AdminRegion; w, h: int) =
  if s != nil: cFrameBegin(s, int32(w), int32(h))

proc frameAdd*(s: AdminRegion; cx, top, bottom, health, maxHealth, distance: float;
               side: int32; flags: uint32; name: string) =
  if s == nil: return
  var nm = name
  cFrameAdd(s, cfloat(cx), cfloat(top), cfloat(bottom), cfloat(health),
            cfloat(maxHealth), cfloat(distance), side, flags, toCString(nm))

proc frameCommit*(s: AdminRegion) =
  if s != nil: cFrameCommit(s)

# --------------------------------------------------------------- spawner
#
# The mod's half of the F6 item spawner. The overlay's WndProc fills the query
# and bumps the request; this side drains it. `spawnPending` returns 0 when
# there is nothing to do, so the common case costs one shared-memory read.

proc spawnPending*(s: AdminRegion): int32 =
  ## The sequence number of an UNSERVICED request, or 0 for none.
  if s == nil: 0'i32 else: cSpawnPending(s)

proc spawnQuery*(s: AdminRegion): string =
  ## The typed query as a nimony string. Bounded by the shared buffer's own
  ## capacity, and it stops at the first NUL, so a length field that overstates
  ## the content yields a short string rather than a walk off the end.
  result = ""
  if s == nil: return
  var n = cQueryLen(s)
  if n < 0'i32: n = 0'i32
  if n > 47'i32: n = 47'i32      # AOWL_ADM_QUERY_LEN - 1
  var i = 0'i32
  while i < n:
    let c = cQueryAt(s, i)
    if c <= 0'i32 or c > 255'i32: break
    result.add char(c)
    i = i + 1'i32

proc spawnCount*(s: AdminRegion): int =
  if s == nil: 1 else: int(cSpawnCount(s))

proc spawnCondition*(s: AdminRegion): int =
  if s == nil: 100 else: int(cSpawnCondition(s))

proc spawnDone*(s: AdminRegion; req: int32; text: string) =
  ## Finish a request. The text is what the player is shown, and it is written
  ## before the ack, so the HUD cannot read the PREVIOUS result as this one's.
  ## It is populated on refusal exactly as on success -- a spawn that did
  ## nothing must never render as one that worked.
  if s == nil: return
  var t = text
  cSpawnDone(s, req, toCString(t))

proc spawnNote*(s: AdminRegion; text: string) =
  ## Write the result line as a NOTE -- no ack, no busy flag. This is the
  ## typeahead channel: the player types, and the line under the query row
  ## becomes what that query currently matches.
  if s == nil: return
  var t = text
  cSpawnNote(s, toCString(t))

proc spawnInflight*(s: AdminRegion): bool =
  ## True while a submitted spawn is still being serviced. A search preview is
  ## suppressed while this holds, so a typeahead line can never overwrite the
  ## answer to a spawn the player actually asked for.
  if s == nil: false else: cSpawnInflight(s) != 0'i32

proc modeName*(bit: int32): string =
  ## The menu label for one mode.
  ##
  ## These duplicate `aowl_admin_mode_name` in `abi/aowlspt_admin.h` -- nimony
  ## has no `$` for `cstring`, so the C function cannot be reused directly.
  ## KEEP THE TWO IN SYNC; the header is the original and the HUD draws from it,
  ## this copy only reaches the log and adminDiag().
  case bit
  of admEsp:       "ESP"
  of admGodmode:   "God mode"
  of admStamina:   "Infinite stamina"
  of admNoRecoil:  "No recoil / sway"
  of admNoWeight:  "No weight"
  of admInstaHeal: "Instant heal"
  of admAmmo:      "Unlimited ammo"
  of admThermal:   "Thermal vision"
  of admNightVis:  "Night vision"
  of admFly:       "Fly / noclip"
  of admTeleport:  "Teleport to marker"
  of admTimeOfDay: "Set time of day"
  else:            "?"

# ------------------------------------------------------------- hotkeys
#
# The C in `abi/aowlspt_admin.h` owns every rule (unknown name -> REFUSAL with
# the name printed, never KeyCode.None; no key on an action whose write is not
# bound; no duplicate binds) so that the F6 menu and this settings path cannot
# drift apart -- there is ONE implementation and two callers.

proc cHkSetName(s: AdminRegion; row: int32; name: cstring): int32 {.
  importc: "aowl_admin_hotkey_set_name", nodecl.}
proc cHkGet(s: AdminRegion; row: int32): int32 {.
  importc: "aowl_admin_hotkey_get", nodecl.}
proc cHkNameAt(s: AdminRegion; row, i: int32): int32 {.
  importc: "aowl_admin_hotkey_name_at", nodecl.}
proc cHkNoteAt(s: AdminRegion; i: int32): int32 {.
  importc: "aowl_admin_hotkey_note_at", nodecl.}
proc cHkStateAt(i: int32): int32 {.
  importc: "aowl_admin_hotkey_state_at", nodecl.}
proc cHkPoll(s: AdminRegion; enabled: int32): int32 {.
  importc: "aowl_admin_hotkey_poll", nodecl.}
proc cHkEpoch(s: AdminRegion): int32 {.
  importc: "aowl_admin_hotkey_epoch", nodecl.}
proc cHkFires(s: AdminRegion): int32 {.
  importc: "aowl_admin_hotkey_fires", nodecl.}
proc cHkDisabled(): int32 {.
  importc: "aowl_admin_hotkey_disabled", nodecl.}
proc cHkCapturing(s: AdminRegion): int32 {.
  importc: "aowl_admin_hotkey_capturing", nodecl.}

proc hotkeySetName*(s: AdminRegion; row: int32; name: string): bool =
  ## True when the key was accepted. False is a REFUSAL, and `hotkeyNote()`
  ## then says why, naming the key. Never silently binds anything.
  if s == nil: return false
  var n = name
  cHkSetName(s, row, toCString(n)) != 0'i32

proc hotkeyName*(s: AdminRegion; row: int32): string =
  ## The KeyCode NAME on this row, or "" for unbound. Never a bare ordinal.
  ##
  ## Read one byte at a time because nimony has no `$` for `cstring` -- the
  ## same reason `modeName` above duplicates the header's table. Capped, so a
  ## buffer that somehow lost its terminator yields a short string rather than
  ## a walk off the end.
  result = ""
  if s == nil: return
  var i = 0'i32
  while i < 40'i32:
    let c = cHkNameAt(s, row, i)
    if c <= 0'i32 or c > 255'i32: break
    result.add char(c)
    i = i + 1'i32

proc hotkeyOrdinal*(s: AdminRegion; row: int32): int =
  if s == nil: -1 else: int(cHkGet(s, row))

proc hotkeyNote*(s: AdminRegion): string =
  ## Why the last bind was REFUSED, in words, or "". Capped at the region's
  ## own buffer size.
  result = ""
  if s == nil: return
  var i = 0'i32
  while i < 191'i32:            # AOWL_ADM_STATUS_LEN - 1
    let c = cHkNoteAt(s, i)
    if c <= 0'i32 or c > 255'i32: break
    result.add char(c)
    i = i + 1'i32

proc hotkeyPoll*(s: AdminRegion; enabled: bool): int =
  ## UNITY THREAD ONLY. 0, or row+1 for the action toggled this frame.
  if s == nil: return 0
  int(cHkPoll(s, (if enabled: 1'i32 else: 0'i32)))

proc hotkeyEpoch*(s: AdminRegion): int =
  if s == nil: 0 else: int(cHkEpoch(s))
proc hotkeyFires*(s: AdminRegion): int =
  if s == nil: 0 else: int(cHkFires(s))
proc hotkeyCapturing*(s: AdminRegion): bool =
  s != nil and cHkCapturing(s) != 0'i32
proc hotkeyDisabled*(): bool = cHkDisabled() != 0'i32
proc hotkeyStateText*(): string =
  ## Whether Input::GetKeyDown bound, and if not, why -- never collapsed into
  ## "no key pressed".
  result = ""
  var i = 0'i32
  while i < 255'i32:
    let c = cHkStateAt(i)
    if c <= 0'i32 or c > 255'i32: break
    result.add char(c)
    i = i + 1'i32
  if result.len == 0: result = "not attempted"

proc hostGameWorld*(): pointer =
  ## The live `EFT.GameWorld`, borrowed from the host's existing RegisterPlayer
  ## detour cache. nil is AMBIGUOUS on its own -- always pair with gwState().
  cGameWorld()

var gUiMaskFn: pointer = cast[pointer](0)
var gUiMaskTried = false

proc hostUiOverlayMask*(): uint32 =
  ## The host `aowl_ui_overlay_mask` export (uint32 bitmask; bit0=game Settings,
  ## bit1=F6, bit2=F3). Non-zero means a menu/settings overlay is open. Resolved
  ## once from the host DLL at runtime; 0 (no overlay) if the export is absent --
  ## an older host, or this mod not running inside the client -- which is the
  ## safe default (ESP simply is not suppressed rather than always suppressed).
  if not gUiMaskTried:
    gUiMaskTried = true
    var hostDll = "aowlspt-host-il2cpp.dll"
    let h = admGetModuleHandleA(toCString(hostDll))
    if h != nil:
      var n = "aowl_ui_overlay_mask"
      gUiMaskFn = admGetProcAddress(h, toCString(n))
  if gUiMaskFn == nil:
    return 0'u32
  admU32V(gUiMaskFn)

proc gwState*(): int =
  ## 0 no host export | 1 export but no detour armed (INCONCLUSIVE) |
  ## 2 armed, no world (not in a raid) | 3 world live.
  int(cGwState())

proc gwStateText*(): string =
  case gwState()
  of 0: "no host export aowl_host_gameworld (host too old, or not in the client)"
  of 1: "host export present but NO detour is armed -- set the host flag " &
        "debugEsp or botDiag; this is INCONCLUSIVE, not \"no raid\""
  of 2: "armed; no GameWorld cached yet (not in a raid)"
  else: "GameWorld live"

# --------------------------------------------------- world -> screen
#
# Two halves on two threads. `camSample` CALLS Unity (Camera::get_main plus the
# two sret Matrix4x4 getters) and is legal ONLY on the game's own thread;
# `worldToScreen` is pure arithmetic over the 16 floats that produced, and runs
# on the mod's thread inside the per-frame ESP pass. See the block comment in
# `abi/aowlspt_admin.h` for the measured RVAs and the sret shape.

proc camSample*(): bool =
  ## UNITY THREAD ONLY. Refresh the view-projection snapshot. True when this
  ## call actually refreshed it.
  cCamSample() != 0'i32

proc camReady*(): bool =
  ## Bound, sampled at least once, sampled recently, not self-disabled. The one
  ## predicate the capability bit, the draw loop and adminDiag() all read.
  cCamReady() != 0'i32

proc camState*(): int =
  ## 0 not attempted | 1 GameAssembly not mapped yet | 2 PROLOGUE MISMATCH (the
  ## RVAs moved -- a Tarkov update) | 3 all three targets bound.
  int(cCamState())

proc camGen*(): int = int(cCamGen())
proc camStale*(): int = int(cCamStale())
proc camDisabled*(): bool = cCamDisabled() != 0'i32

proc camRoute*(): int = int(cCamRoute())
  ## 0 = no camera has ever been acquired | 1 = Camera::get_main |
  ## 2 = CameraManager.Instance.<Camera>k__BackingField.

proc camRouteText*(): string =
  ## WHICH acquisition route came up empty, and how often. Without this the
  ## sampler can only report "no matrix", and a live raid was needed to work out
  ## that `Camera.main` was the null -- 24604 firings that all said the same
  ## uninformative thing. Never collapse the three nulls into one.
  case camRoute()
  of 1: "Camera::get_main"
  of 2: "CameraManager.Instance.Camera"
  else:
    var r = "NO camera acquired yet: Camera::get_main returned null " &
            $int(cCamMainNulls()) & " time(s)"
    if cCamMgrBound() == 0:
      r.add "; the CameraManager fallback is NOT bound (get_Instance" &
            "@0x1263BD0 did not byte-match this build), so there is no " &
            "second route"
    else:
      r.add "; CameraManager::get_Instance returned null " &
            $int(cCamMgrNulls()) & " time(s) and Instance+0x70 read null " &
            $int(cCamFldNulls()) & " time(s)"
    r

proc camStateText*(): string =
  ## Why there is no projection, in words. Never collapses a bind failure or an
  ## un-driven sampler into "not in a raid".
  if camDisabled():
    return "SELF-DISABLED after repeated refusals; last bind state " &
           $camState()
  case camState()
  of 0, 1:
    "GameAssembly.dll is not mapped yet -- nothing has been attempted"
  of 2:
    "PROLOGUE MISMATCH: Camera::get_main@0x5260400 / " &
    "get_worldToCameraMatrix@0x525F2A0 / get_projectionMatrix@0x525F380 do " &
    "not byte-match this build; refusing to call them. Re-measure with " &
    "tools/il2cpp_resolve.py"
  else:
    if camGen() == 0:
      # The old text said "no main camera yet, or the everyMain driver did not
      # arm" -- two causes, no way to tell them apart, which is what made the
      # 24604-firing log unreadable. Say which.
      var r = "bound, but the Unity-thread sampler has never produced a " &
              "matrix -- " & camRouteText()
      if int(cCamSelftestFails()) > 0:
        r.add "; and " & $int(cCamSelftestFails()) & " matrix/matrices WERE " &
              "obtained but failed the centre-projection self-test (a point " &
              "10m ahead of the camera did not land near the middle of the " &
              "frame), so the view/proj pair is unusable or the -Z forward " &
              "convention is wrong for this build"
      r
    elif camStale() >= 120:
      "bound and sampled " & $camGen() & " times via " & camRouteText() &
      ", but the last good sample was " & $camStale() & " drains ago"
    else:
      "live (gen " & $camGen() & ", via " & camRouteText() & ")"

proc worldToScreen*(x, y, z: float; w, h: int; sx, sy: var float): bool =
  ## ANY thread. World point -> pixel through the published snapshot. False when
  ## the point is behind the camera or no snapshot is live.
  var fx = 0.0'f32
  var fy = 0.0'f32
  let ok = cW2s(cfloat(x), cfloat(y), cfloat(z), int32(w), int32(h),
                addr fx, addr fy)
  sx = float(fx)
  sy = float(fy)
  result = ok != 0'i32

# --------------------------------------------------------- live positions
#
# `EFT.MovementContext.PreviousPosition` @0x370 is permanently ZERO on this
# build -- the offset is right and the field is dead. The pose exists only on
# Unity's native side, reachable through `EFT.Player::get_Position` @0x6F32C0,
# which bottoms out in `Transform::get_position_Injected`. That makes it a
# UNITY-THREAD-ONLY call, so `posArm` / `posBegin` / `posAdd` / `posCommit` are
# legal ONLY from the everyMain tick; `posGet` is the any-thread reader.

const
  posOk*         = 0'i32
  posUnreadable* = 1'i32
  posNan*        = 2'i32
  posRange*      = 3'i32
  posAllZero*    = 4'i32
  posNilBones*   = 10'i32
  posNilXform*   = 11'i32
  posImitated*   = 12'i32
  posNoCall*     = 13'i32
  posCodes*      = 14'i32

proc posArm*(): int32 =
  ## UNITY THREAD. Byte-verifies the 16-byte prologue at 0x6F32C0 once.
  ## 1 = armed, 0 = GameAssembly.dll not up yet (retry), -1 = refused for good.
  cPosArm()
proc posArmed*(): int32 = cPosArmed()

proc posBegin*() = cPosBegin()
proc posAdd*(p: pointer): int32 =
  ## UNITY THREAD. Samples one player; returns the exit code it took, so a
  ## caller reports WHICH reason rather than "nothing worked".
  if p == nil: return posNilBones
  cPosAdd(p)
proc posCommit*() = cPosCommit()
proc posCount*(): int = int(cPosCount())
proc posGen*(): int = int(cPosGen())
proc posStat*(code: int32): int = int(cPosStatAt(code))

proc posGet*(p: pointer; x, y, z: var float): bool =
  ## ANY thread. False means "this player was not in the last good sweep" --
  ## never "its position is the origin".
  var fx = 0.0'f32
  var fy = 0.0'f32
  var fz = 0.0'f32
  x = 0.0; y = 0.0; z = 0.0
  if p == nil: return false
  let ok = cPosGet(p, addr fx, addr fy, addr fz)
  x = float(fx); y = float(fy); z = float(fz)
  result = ok != 0'i32

proc posCodeText*(code: int32): string =
  ## The NAMED exit reason, mirroring the classification in aowlspt_admin.h.
  if code == posOk: "OK"
  elif code == posNoCall:
    "EFT.Player::get_Position @0x6F32C0 is NOT ARMED -- GameAssembly.dll was " &
    "absent, or its 16 prologue bytes did not match this build"
  elif code == posNilBones:
    "Player+0xB40 <PlayerBones>k__BackingField read null"
  elif code == posNilXform:
    "PlayerBones+0x178 BodyTransform (or BifacialTransform+0x10 Original) " &
    "read null -- get_Position would have THROWN here, so it was correctly " &
    "NOT called"
  elif code == posImitated:
    "BifacialTransform+0xA8 _useImitation / +0xA9 " &
    "_accumulatePositionAndRotation was SET -- get_position takes a delegate " &
    "path we have not proven throw-free, so the call was declined"
  elif code == posUnreadable:
    "a hop on Player+0xB40 -> PlayerBones+0x178 was NOT READABLE -- a POINTER " &
    "problem, not a zero-field one"
  elif code == posNan: "get_Position @0x6F32C0 returned NaN"
  elif code == posRange:
    "get_Position @0x6F32C0 returned out of range (|component| > 1e6)"
  elif code == posAllZero:
    "get_Position @0x6F32C0 returned exactly (0,0,0) from a READABLE buffer " &
    "-- THE EXACT SHAPE THE OLD MovementContext+0x370 BUG PRODUCED, so the " &
    "walk is reaching a BifacialTransform that is not the body"
  else: "unclassified code " & $code

proc godmodePatch*(on: bool; rva: uint32): bool =
  ## Apply (or revert) the God mode byte-patch on the damage function at `rva`.
  ## Returns whether the patch is now in the requested state.
  cGodmode((if on: 1'i32 else: 0'i32), rva) != 0'i32
proc godmodeIsOn*(): bool = cGodOn() != 0'i32
proc gameAssemblyPresent*(): bool = cGameAsm() != 0'i32

proc hudWidth*(s: AdminRegion): int =
  ## The back-buffer width the overlay last drew at, or 0 before the first frame.
  if s == nil: 0 else: int(cGetW(s))
proc hudHeight*(s: AdminRegion): int =
  if s == nil: 0 else: int(cGetH(s))

proc project*(m: var array[16, float32]; x, y, z: float; w, h: int;
              sx, sy: var float): bool =
  ## World point to screen pixel via the published view-projection matrix.
  var fx = 0.0'f32
  var fy = 0.0'f32
  let ok = cProject(addr m[0], cfloat(x), cfloat(y), cfloat(z),
                    int32(w), int32(h), addr fx, addr fy)
  sx = float(fx)
  sy = float(fy)
  result = ok != 0'i32

proc matMul*(a, b: var array[16, float32]; outM: var array[16, float32]) =
  ## outM = a * b, Unity column-major.
  cMatMul(addr a[0], addr b[0], addr outM[0])

# --------------------------------------------------------------- raw reads
#
# Guarded `*(T*)(object + offset)` reads -- the field-offset path, no managed
# calls. Each checks the address is committed and readable first, so a wrong
# offset or a moved object is a zero rather than a fault.

proc rdPtr*(o: pointer; off: int): pointer =
  if o == nil: return nil
  result = cRp(o, int32(off))
proc rdI32*(o: pointer; off: int): int32 =
  if o == nil: return 0'i32
  result = cRi(o, int32(off))
proc rdF32*(o: pointer; off: int): float =
  if o == nil: return 0.0
  result = float(cRf(o, int32(off)))
proc wrF32*(o: pointer; off: int; v: float) =
  if o != nil: cWf(o, int32(off), cfloat(v))

proc rdBool*(o: pointer; off: int): int32 =
  ## A one-byte managed bool. THREE outcomes, not two: 1, 0, or -1 for "the
  ## address was not readable". `rdI32` on a bool field reads the three bytes
  ## that follow it as well, which is a number, not the field.
  if o == nil: return -1'i32
  result = cRb(o, int32(off))

proc wrBool*(o: pointer; off: int; v: bool): bool =
  ## Returns whether the byte was actually written, so a caller cannot report
  ## success for a write the guard refused.
  if o == nil: return false
  result = cWb(o, int32(off), (if v: 1'i32 else: 0'i32)) != 0'i32
