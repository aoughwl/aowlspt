## The nimony face of `abi/aowlspt_admin.h` -- the shared-memory region the mod
## publishes into and the native D3D11 HUD (in the overlay) draws from.
##
## Same shape as `host/Aowlspt.Overlay/aowloverlay.nim`: the C is header-only, so
## the emit pulls the definitions into this translation unit and every entry is
## `importc ... nodecl`. The mod and the overlay each get their own copy of the
## header's `static` functions; the state they actually share is the named file
## mapping `aowl_admin_map` returns, so both talking to it is two views of one
## region, not two copies of a global.

{.emit: """#include "aowlspt_admin.h" """.}

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

proc cCamSample(): int32 {.importc: "aowl_admin_cam_sample", nodecl.}
proc cCamState(): int32 {.importc: "aowl_admin_cam_state", nodecl.}
proc cCamReady(): int32 {.importc: "aowl_admin_cam_ready", nodecl.}
proc cCamGen(): int32 {.importc: "aowl_admin_cam_gen", nodecl.}
proc cCamStale(): int32 {.importc: "aowl_admin_cam_stale", nodecl.}
proc cCamDisabled(): int32 {.importc: "aowl_admin_cam_disabled", nodecl.}
proc cW2s(x, y, z: cfloat; w, h: int32; sx, sy: ptr cfloat): int32 {.
  importc: "aowl_admin_w2s", nodecl.}

proc cGodmode(on: int32; rva: uint32): int32 {.importc: "aowl_admin_godmode", nodecl.}
proc cGodOn(): int32 {.importc: "aowl_admin_god_is_on", nodecl.}
proc cGameAsm(): int32 {.importc: "aowl_admin_gameasm_present", nodecl.}
proc cGetW(s: AdminRegion): int32 {.importc: "aowl_admin_get_w", nodecl.}
proc cGetH(s: AdminRegion): int32 {.importc: "aowl_admin_get_h", nodecl.}
proc cRp(o: pointer; off: int32): pointer {.importc: "aowl_admin_rp", nodecl.}
proc cRi(o: pointer; off: int32): int32 {.importc: "aowl_admin_ri", nodecl.}
proc cRf(o: pointer; off: int32): cfloat {.importc: "aowl_admin_rf", nodecl.}
proc cWf(o: pointer; off: int32; v: cfloat) {.importc: "aowl_admin_wf", nodecl.}

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

proc hostGameWorld*(): pointer =
  ## The live `EFT.GameWorld`, borrowed from the host's existing RegisterPlayer
  ## detour cache. nil is AMBIGUOUS on its own -- always pair with gwState().
  cGameWorld()

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
      "bound, but the Unity-thread sampler has never produced a matrix " &
      "(no main camera yet, or the everyMain driver did not arm)"
    elif camStale() >= 120:
      "bound and sampled " & $camGen() & " times, but the last good sample " &
      "was " & $camStale() & " drains ago (no main camera right now)"
    else:
      "live (gen " & $camGen() & ")"

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
