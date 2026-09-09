# ---------------------------------------------------------------------------
# camera -- THE HOST CAMERA API, and a free camera built on it.
#
# WHY THIS EXISTS. Before this module the host could do exactly one thing to a
# camera: write its field of view (`mods/fov`). Everything else -- where the
# camera is, where it looks, how near it clips -- was unreachable, and every
# feature that wanted any of it would have had to re-derive an RVA, re-derive a
# calling convention and re-derive an acquisition path. This is that surface,
# derived ONCE, byte-verified, and shared.
#
# WHAT IT DOES NOT DO: acquire a camera of its own. `UnityEngine.Camera::
# get_main` @0x5260400 is already verified in debugui's target table and is
# already signal S5 of the deploy latch in `raidphase.nim`. There is one
# acquisition path in this host and this module uses it
# (`cDuFn(DuCameraMain)` -> `cDuCallPV`), reaching the camera's Transform
# through the same table's `Component::get_transform` @0x73B0F0. A second path
# would be a second answer to "which camera?", and the two would drift.
#
# THE ABI IS MEASURED, NOT ASSUMED. See `abi/aowlspt_camera.h` for the byte
# evidence. In one line: a Vector3 is 12 bytes, so it is RETURNED through a
# hidden buffer (retbuf RCX, this RDX, MethodInfo* R8) and PASSED BY ADDRESS in
# RDX -- `Transform::get_position` zeroes exactly 12 bytes through RCX
# (`48 89 01` + `89 41 08`) with `this` in RDX (`48 8B FA`), and
# `Transform::set_eulerAngles` dereferences RDX (`F2 0F 10 02` /
# `F3 0F 10 4A 08`). A Quaternion (16 bytes) is the same both ways. That is
# NOT the Vector2 rule -- a Vector2 is 8 bytes and comes back packed in RAX --
# which is why the header has three thunk families and not one.
#
# SHAREDNESS. All fifteen targets in the camera table resolve `unique`
# (owners=1) per `tools/il2cpp_resolve.py ... shared`. Nothing here is
# detoured in any case; this module installs NO detour and rides the existing
# `TarkovApplication::Update` drain plus the existing render drain, because a
# second detour on one function overwrites the first's trampoline and silently
# kills it. `Component::get_transform`, reused out of debugui, IS shared (15
# owners) -- it is CALLED, which is correct for the receiver we pass, and never
# patched.
#
# THE FREE CAMERA, and the two things that make it honest:
#
#   1. THE HOST HOLDS THE AUTHORITATIVE POSE. It does not read the camera's
#      position and add a delta; it keeps its own `gCamPos`/`gCamYaw`/
#      `gCamPitch` and writes them every frame. That is what makes the readback
#      a real check: if the game re-drives the camera transform later in the
#      frame, next frame's `get_position` will NOT equal what we wrote, and
#      `camStatus` says so. A read-modify-write could never fail that way and
#      would therefore prove nothing (CLAUDE.md 9b).
#
#   2. RESTORE IS VERIFIED BY READBACK, NEGATIVELY. On exit the saved position,
#      the saved QUATERNION (not the euler -- euler round-trip is lossy), the
#      saved FOV and both clip planes are written back, then read back off the
#      SAME camera and compared to the saved originals. Three outcomes: PASS
#      (every one reads back equal), FAIL (at least one does not), INCONCLUSIVE
#      (a read refused, so we could not look). "I wrote the old values" is not
#      evidence and is never reported as one.
#
# THE THIRD-OVERLAY RULE. An overlay that survives onto the raid-ended screen
# has been complained about twice. So the free camera does not merely stop when
# the raid ends: `camDrainTick` exits and RESTORES the moment `rpPhase()` is
# anything other than `RpPhaseDeployed` -- which includes RESULTS
# (SessionEndUIScene listed), MENU, LOADING and UNKNOWN. UNKNOWN means "I could
# not look", and for this feature that must restore, not persist.
#
# SAFETY. Flag-gated `cameraApi` (the read/write surface) and `cameraFreeCam`
# (the free camera), both default OFF. Idle cost with both off is one integer
# compare. Every managed pointer hop is `duOk`-guarded and every UnityEngine
# object is checked for Unity's fake null (`iUnityAlive`) before any internal
# call, because readability is not liveness. The camera's klass pointer is
# pinned on first acquisition and a change is refused, so a pointer that is
# readable, alive and the WRONG TYPE cannot get through either. Both bodies run
# under ONE `aowl_p_p_seh` each, opened at the drain entry and never nested --
# the guard is a single thread-local jmp_buf and a nested one DISARMS the
# outer. Self-disables after `CamMaxFaults` faults. No allocation on any
# per-frame path: every per-frame value is a float64 in a module-level var.
#
# THE EXPORTS ARE CACHE-AND-REQUEST, ON PURPOSE. `aowl_host_camera_read` hands
# back the pose the guarded drain last SAMPLED, and `aowl_host_camera_write`
# records a request the next drain applies. It does not evaluate in the
# caller's thread or inside the caller's guard, for the same reason
# `aowl_host_raid_phase` does not: a mod calls these from inside its own
# `aowl_p_p_seh`, and that guard is not re-entrant.
# ---------------------------------------------------------------------------

{.emit: """#include "aowlspt_camera.h" """.}

# ---- the byte-verified target table (abi/aowlspt_camera.h) ----
proc cCamFn(i: int32): Il2CppPtr {.importc: "aowl_cam_fn", nodecl.}
proc cCamName(i: int32): cstring {.importc: "aowl_cam_name", nodecl.}
proc cCamRva(i: int32): uint32 {.importc: "aowl_cam_rva", nodecl.}
proc cCamTargetCount(): int32 {.importc: "aowl_cam_target_count", nodecl.}
proc cCamOkCount(): int32 {.importc: "aowl_cam_ok_count", nodecl.}
proc cCamBadCount(): int32 {.importc: "aowl_cam_bad_count", nodecl.}
proc cCamReason(): int32 {.importc: "aowl_cam_reason", nodecl.}
proc cCamReasonText(): cstring {.importc: "aowl_cam_reason_text", nodecl.}
proc cCamModuleReady(): int32 {.importc: "aowl_cam_module_ready", nodecl.}
proc cCamWaitCount(): int32 {.importc: "aowl_cam_wait_count", nodecl.}

proc cCamGetF(fn, self: Il2CppPtr): float64 {.importc: "aowl_cam_get_f", nodecl.}
proc cCamGetFOk(fn, self: Il2CppPtr): int32 {.
  importc: "aowl_cam_get_f_ok", nodecl.}
proc cCamSetF(fn, self: Il2CppPtr; v: float64): int32 {.
  importc: "aowl_cam_set_f", nodecl.}
proc cCamGetV(fn, self: Il2CppPtr; nfloats: int32): int32 {.
  importc: "aowl_cam_get_v", nodecl.}
proc cCamV0(): float64 {.importc: "aowl_cam_v0", nodecl.}
proc cCamV1(): float64 {.importc: "aowl_cam_v1", nodecl.}
proc cCamV2(): float64 {.importc: "aowl_cam_v2", nodecl.}
proc cCamV3(): float64 {.importc: "aowl_cam_v3", nodecl.}
proc cCamSetV(fn, self: Il2CppPtr; x, y, z, w: float64): int32 {.
  importc: "aowl_cam_set_v", nodecl.}
proc cCamKeyDown(vk: int32): int32 {.importc: "aowl_cam_key_down", nodecl.}

# ---- the guarded bodies. ONE `aowl_p_p_seh` each, never nested. ----
{.emit: """
extern void* aowl_cam_tick_body(void* a);
static void* aowl_cam_tick_guarded(void* a) {
    return aowl_p_p_seh((void*)aowl_cam_tick_body, a);
}
extern void* aowl_cam_reassert_body(void* a);
static void* aowl_cam_reassert_guarded(void* a) {
    return aowl_p_p_seh((void*)aowl_cam_reassert_body, a);
}
""".}
proc cCamTickGuarded(a: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_cam_tick_guarded", nodecl.}
proc cCamReassertGuarded(a: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_cam_reassert_guarded", nodecl.}

const
  # Target indices -- MUST match the #defines in abi/aowlspt_camera.h. The
  # order is checked at boot by `camIndicesOk`, which compares the NAME the C
  # table actually holds at each index against the name this code believes is
  # there. That check exists because the identical class of bug once handed
  # `Transform::set_localPosition` a NULL Vector3 pointer through a perfectly
  # valid, byte-verified function and faulted inside the call.
  CamTGetFov   = 0'i32   ## UnityEngine.Camera::get_fieldOfView
  CamTSetFov   = 1'i32   ## UnityEngine.Camera::set_fieldOfView
  CamTGetNear  = 2'i32   ## UnityEngine.Camera::get_nearClipPlane
  CamTSetNear  = 3'i32   ## UnityEngine.Camera::set_nearClipPlane
  CamTGetFar   = 4'i32   ## UnityEngine.Camera::get_farClipPlane
  CamTSetFar   = 5'i32   ## UnityEngine.Camera::set_farClipPlane
  CamTGetPos   = 6'i32   ## UnityEngine.Transform::get_position
  CamTSetPos   = 7'i32   ## UnityEngine.Transform::set_position
  CamTGetRot   = 8'i32   ## UnityEngine.Transform::get_rotation
  CamTSetRot   = 9'i32   ## UnityEngine.Transform::set_rotation
  CamTGetEuler = 10'i32  ## UnityEngine.Transform::get_eulerAngles
  CamTSetEuler = 11'i32  ## UnityEngine.Transform::set_eulerAngles
  CamTGetFwd   = 12'i32  ## UnityEngine.Transform::get_forward
  CamTGetRight = 13'i32  ## UnityEngine.Transform::get_right
  CamTGetUp    = 14'i32  ## UnityEngine.Transform::get_up

  CamMaxFaults = 8

  # Virtual-key codes. Written out rather than pulled from a table so a reader
  # can check them against MSDN without a second hop.
  CamVkW      = 0x57'i32
  CamVkA      = 0x41'i32
  CamVkS      = 0x53'i32
  CamVkD      = 0x44'i32
  CamVkSpace  = 0x20'i32
  CamVkCtrl   = 0x11'i32
  CamVkShift  = 0x10'i32
  CamVkLeft   = 0x25'i32
  CamVkUp     = 0x26'i32
  CamVkRight  = 0x27'i32
  CamVkDown   = 0x28'i32
  CamVkF7     = 0x76'i32

  # Movement. Metres per second and degrees per second, both scaled by dt, so
  # the camera moves the same distance at 30fps and at 144fps.
  CamBaseSpeed = 8.0
  CamFastMult  = 6.0
  CamSlowMult  = 0.2
  CamTurnSpeed = 90.0
  CamMaxDtMs   = 100.0   ## a frame longer than this is a hitch; clamp, never
                         ## integrate it, or one stall teleports the camera.

  # Restore tolerances. A float32 round-trip of a value we stored verbatim
  # should be EXACT; these are slack for the float64<->float32 boundary only,
  # and are deliberately tight enough that a real clobber fails the check.
  CamPosEps = 0.001
  CamRotEps = 0.0001
  CamFovEps = 0.001

# ---- flags and fault state ----
var gCamApi = false            ## flag `cameraApi` -- the read/write surface
var gCamFree = false           ## flag `cameraFreeCam` -- the free camera
var gCamFaults = 0
var gCamTicks = 0'i64
var gCamIndicesOk = -1'i32     ## -1 not checked, 1 ok, 0 MISMATCH
var gCamWhy = "not attempted"
# ---- binding state: THREE outcomes, never two ----
# 0 not attempted, 1 DEFERRED (GameAssembly.dll was not mapped when we asked --
# retryable, and NOT a verdict), 2 attempted with the module PRESENT and the
# verdict recorded. Only state 2 is latched, because only state 2 is a fact
# about the build.
var gCamBindState = 0'i32
var gCamBindTries = 0'i64      ## retries made from the main-thread drain
var gCamBindSaidWait = false   ## the "still waiting" warning is said once

# ---- the acquired camera, and the type-confusion pin ----
var gCamObj: Il2CppPtr = nil   ## UnityEngine.Camera, by contract from get_main
var gCamTf: Il2CppPtr = nil    ## its Transform, by contract from get_transform
var gCamKlass = 0'u64          ## pinned on first acquisition; a change refuses
var gCamTfKlass = 0'u64
var gCamAt = 0'i64

# ---- the last SAMPLED pose (what the exports hand out) ----
var gCamSampled = false
var gCamPx = 0.0
var gCamPy = 0.0
var gCamPz = 0.0
var gCamRx = 0.0
var gCamRy = 0.0
var gCamRz = 0.0
var gCamRw = 0.0
var gCamFov = 0.0
var gCamNear = 0.0
var gCamFar = 0.0

# ---- free-camera state: the host holds the authoritative pose ----
var gCamFreeOn = false
var gCamPos0 = 0.0             ## x/y/z of the pose we own and write each frame
var gCamPos1 = 0.0
var gCamPos2 = 0.0
var gCamYaw = 0.0
var gCamPitch = 0.0
var gCamLastMs = 0'u64
var gCamHeld = 0'i64           ## frames the free camera has been active

# ---- what was saved at entry, and what the restore readback found ----
var gCamSaved = false
var gSavePx = 0.0
var gSavePy = 0.0
var gSavePz = 0.0
var gSaveRx = 0.0
var gSaveRy = 0.0
var gSaveRz = 0.0
var gSaveRw = 0.0
var gSaveFov = 0.0
var gSaveNear = 0.0
var gSaveFar = 0.0
var gCamRestoreVerdict = "INCONCLUSIVE -- the free camera has not been exited yet"
var gCamHoldVerdict = "INCONCLUSIVE -- no free-camera frame has been read back yet"
var gCamExitReason = ""

# ---- the pending write request the exports record ----
var gCamReqKind = 0'i32        ## 0 none, 1 fov, 2 near, 3 far, 4 position,
                               ## 5 euler
var gCamReqA = 0.0
var gCamReqB = 0.0
var gCamReqC = 0.0
var gCamReqDone = 0'i32        ## 1 applied, 2 refused; read back by the caller
var gCamWantOn = false         ## an export asked for the free camera; the DRAIN
var gCamWantOff = false        ## acts on it, never the caller's thread
var gCamSaidAt = 0'u64         ## throttle for the periodic status line

# ---- the config-driven engage latch (`cameraFreeCamEngage`) ----
#
# WHY THIS EXISTS: F7 is the only way in, and synthetic function keys do NOT
# reach this client (measured: SendKeys `m` toggled the maps overlay, `{F7}`
# produced no log line at all), so the restore verdict -- the whole point of
# the feature -- could never be obtained without a human at the keyboard. This
# is a LIVE RECONCILE of one host-config boolean, polled off the same drain,
# and it drives the SAME `camFreeEnter` / `camFreeExit` pair F7 drives. It adds
# no target, no detour and no new RVA.
var gCamEngageCfg = false      ## the last value read out of the file
var gCamEngageSeen = false     ## have we ever read it? (first read is not an edge)
var gCamEngagePollAt = 0'u64   ## throttle: the file is re-read at most every 2s
var gCamEngageLatch = false    ## config says ON and we are not on yet -- KEEP
                               ## trying, because "not deployed yet" is a
                               ## reason to wait, not a reason to forget
var gCamEngageWhy = "the config key cameraFreeCamEngage has not been seen true"

proc camDisabled*(): bool = gCamFaults >= CamMaxFaults

## Forward-declared: the deferred bind lives below (it needs `camIndicesOk`),
## but `camDrainTick` above it is the retry site.
proc camBindRetry()

proc camIndicesOk(): bool =
  ## Compare the NAME the C table holds at each index against the name this Nim
  ## code believes is there. Without this, reordering the table silently calls
  ## a valid function of the wrong shape -- which is not a crash at the call
  ## site but a fault deep inside game code on a receiver that passed every
  ## liveness gate.
  if gCamIndicesOk >= 0'i32: return gCamIndicesOk == 1'i32
  gCamIndicesOk = 1'i32
  if cCamTargetCount() != 15'i32: gCamIndicesOk = 0'i32
  elif $cCamName(CamTSetFov) != "UnityEngine.Camera::set_fieldOfView":
    gCamIndicesOk = 0'i32
  elif $cCamName(CamTSetPos) != "UnityEngine.Transform::set_position":
    gCamIndicesOk = 0'i32
  elif $cCamName(CamTSetRot) != "UnityEngine.Transform::set_rotation":
    gCamIndicesOk = 0'i32
  elif $cCamName(CamTSetEuler) != "UnityEngine.Transform::set_eulerAngles":
    gCamIndicesOk = 0'i32
  elif $cCamName(CamTGetFwd) != "UnityEngine.Transform::get_forward":
    gCamIndicesOk = 0'i32
  if gCamIndicesOk == 0'i32:
    warn "camera: the C target table does not hold the functions this module " &
         "believes it does (index " & $int(CamTSetFov) & " reads '" &
         $cCamName(CamTSetFov) & "'). NOTHING is called. This is a build-order " &
         "defect in abi/aowlspt_camera.h, not a wrong RVA."
  gCamIndicesOk == 1'i32

proc camAcquire(): bool =
  ## The ONE acquisition path, borrowed whole from debugui's verified table.
  ## Re-asked at most every 15 ticks; the cached pointers are re-validated
  ## every call, so a camera destroyed between refreshes cannot be reported
  ## live. Unity's fake null (a readable wrapper with m_CachedPtr == 0) is
  ## checked explicitly, because readability is NOT liveness -- and the klass
  ## pin is checked on top of that, because a readable, ALIVE object can still
  ## be the wrong type.
  let fnMain = cDuFn(DuCameraMain)
  let fnTf = cDuFn(DuGetTransform)
  if fnMain == nil or fnTf == nil:
    gCamWhy = "debugui's Camera::get_main / Component::get_transform did not " &
              "byte-verify on this build"
    gCamObj = nil
    gCamTf = nil
    return false
  if (gCamTicks - gCamAt) >= 15 or gCamObj == nil or
     not duOk(gCamObj, 0x20'i32):
    gCamObj = cDuCallPV(fnMain)
    gCamTf = nil
    gCamAt = gCamTicks
  if gCamObj == nil or not duOk(gCamObj, 0x20'i32) or not bdSanePtr(gCamObj):
    gCamObj = nil
    gCamTf = nil
    gCamWhy = "Camera.main is null -- menu, loading screen or post-raid " &
              "results screen (this is the same S5 the deploy latch uses)"
    return false
  if not iUnityAlive(gCamObj):
    gCamObj = nil
    gCamTf = nil
    gCamWhy = "Camera.main is Unity FAKE NULL: readable, m_CachedPtr == 0. " &
              "Calling anything on it would fault inside Unity's own C++ " &
              "where no guard of ours reaches."
    return false
  let k = iKlassOf(gCamObj)
  if gCamKlass == 0'u64:
    gCamKlass = k
  elif k != gCamKlass:
    gCamObj = nil
    gCamTf = nil
    gCamWhy = "Camera.main returned an object whose klass is not the one " &
              "pinned on first acquisition -- REFUSED. Type confusion beats " &
              "both readability and liveness, so this is checked separately."
    return false
  if gCamTf == nil or not duOk(gCamTf, 0x20'i32):
    gCamTf = cDuCallPP(fnTf, gCamObj)
  if gCamTf == nil or not duOk(gCamTf, 0x20'i32) or not bdSanePtr(gCamTf) or
     not iUnityAlive(gCamTf):
    gCamTf = nil
    gCamWhy = "the camera is live but Component::get_transform gave no " &
              "readable, Unity-alive Transform"
    return false
  let kt = iKlassOf(gCamTf)
  if gCamTfKlass == 0'u64:
    gCamTfKlass = kt
  elif kt != gCamTfKlass:
    gCamTf = nil
    gCamWhy = "the camera's Transform klass changed from the pinned one -- " &
              "REFUSED"
    return false
  gCamWhy = "live"
  true

# ---------------------------------------------------------------------------
# The primitive reads and writes. Every one refuses rather than guessing, and
# every one is callable ONLY from inside an already-open guard.
# ---------------------------------------------------------------------------

proc camReadF(idx: int32; into: var float64): bool =
  let fn = cCamFn(idx)
  if fn == nil or gCamObj == nil: return false
  if cCamGetFOk(fn, gCamObj) == 0'i32: return false
  into = cCamGetF(fn, gCamObj)
  true

proc camWriteF(idx: int32; v: float64): bool =
  let fn = cCamFn(idx)
  if fn == nil or gCamObj == nil: return false
  cCamSetF(fn, gCamObj, v) != 0'i32

proc camReadV3(idx: int32; x, y, z: var float64): bool =
  let fn = cCamFn(idx)
  if fn == nil or gCamTf == nil: return false
  if cCamGetV(fn, gCamTf, 3'i32) == 0'i32: return false
  x = cCamV0()
  y = cCamV1()
  z = cCamV2()
  true

proc camReadV4(idx: int32; x, y, z, w: var float64): bool =
  let fn = cCamFn(idx)
  if fn == nil or gCamTf == nil: return false
  if cCamGetV(fn, gCamTf, 4'i32) == 0'i32: return false
  x = cCamV0()
  y = cCamV1()
  z = cCamV2()
  w = cCamV3()
  true

proc camWriteV(idx: int32; x, y, z, w: float64): bool =
  let fn = cCamFn(idx)
  if fn == nil or gCamTf == nil: return false
  cCamSetV(fn, gCamTf, x, y, z, w) != 0'i32

proc camSample(): bool =
  ## Read the whole pose off the live camera into the cached values the exports
  ## hand out. Partial success is NOT success: if any leg refuses, `gCamSampled`
  ## goes false and every consumer sees "I could not look" rather than a mix of
  ## fresh and stale numbers.
  gCamSampled = false
  if not camReadF(CamTGetFov, gCamFov): return false
  if not camReadF(CamTGetNear, gCamNear): return false
  if not camReadF(CamTGetFar, gCamFar): return false
  if not camReadV3(CamTGetPos, gCamPx, gCamPy, gCamPz): return false
  if not camReadV4(CamTGetRot, gCamRx, gCamRy, gCamRz, gCamRw): return false
  gCamSampled = true
  true

proc camAbs(v: float64): float64 = (if v < 0.0: -v else: v)

# ---------------------------------------------------------------------------
# The free camera
# ---------------------------------------------------------------------------

proc camFreeEnter(): bool =
  ## Save the pose, then take ownership of it. The QUATERNION is saved, not the
  ## euler: euler -> quaternion -> euler does not round-trip, so restoring from
  ## a saved euler could not be verified equal even when it was visually right,
  ## and a check that cannot pass is as useless as one that cannot fail.
  if not camSample():
    gCamExitReason = "refused to enter: the pose could not be read"
    return false
  gSavePx = gCamPx
  gSavePy = gCamPy
  gSavePz = gCamPz
  gSaveRx = gCamRx
  gSaveRy = gCamRy
  gSaveRz = gCamRz
  gSaveRw = gCamRw
  gSaveFov = gCamFov
  gSaveNear = gCamNear
  gSaveFar = gCamFar
  gCamSaved = true
  gCamPos0 = gCamPx
  gCamPos1 = gCamPy
  gCamPos2 = gCamPz
  # Start looking exactly where the player was looking. The euler read is the
  # only lossy step and it is on ENTRY, where it costs nothing: the restore
  # path never touches euler.
  var ex = 0.0
  var ey = 0.0
  var ez = 0.0
  if camReadV3(CamTGetEuler, ex, ey, ez):
    gCamPitch = ex
    gCamYaw = ey
  else:
    gCamPitch = 0.0
    gCamYaw = 0.0
  gCamFreeOn = true
  gCamHeld = 0
  gCamLastMs = cNowMs()
  gCamExitReason = ""
  gCamHoldVerdict = "INCONCLUSIVE -- no free-camera frame has been read back yet"
  warn "camera: FREE CAMERA ON. The host now owns the camera pose and writes " &
       "it every frame. Saved pose: pos(" & duFmt2(gSavePx) & ", " &
       duFmt2(gSavePy) & ", " & duFmt2(gSavePz) & ") quat(" & duFmt2(gSaveRx) &
       ", " & duFmt2(gSaveRy) & ", " & duFmt2(gSaveRz) & ", " &
       duFmt2(gSaveRw) & ") fov=" & duFmt2(gSaveFov) & " near=" &
       duFmt2(gSaveNear) & " far=" & duFmt2(gSaveFar) & ". It will be written " &
       "back and READ BACK on exit; the verdict is in camStatus."
  true

proc camFreeExit(why: string) =
  ## Restore, then VERIFY THE FINISHED STATE by reading it back off the same
  ## camera. Never by echoing the write.
  if not gCamFreeOn: return
  gCamFreeOn = false
  gCamExitReason = why
  if not gCamSaved:
    gCamRestoreVerdict = "INCONCLUSIVE -- nothing was saved, so nothing was " &
                         "restored (" & why & ")"
    warn "camera: free camera OFF (" & why & "). " & gCamRestoreVerdict
    return
  if not camAcquire():
    gCamRestoreVerdict = "INCONCLUSIVE -- the camera was gone at exit, so the " &
                         "saved pose could not be written back and could not " &
                         "be read back. The camera we altered no longer " &
                         "exists; a NEW Camera.main starts from the game's " &
                         "own state, not ours. (" & gCamWhy & ")"
    warn "camera: free camera OFF (" & why & "). " & gCamRestoreVerdict
    return
  var wrote = 0
  if camWriteV(CamTSetPos, gSavePx, gSavePy, gSavePz, 0.0): wrote = wrote + 1
  if camWriteV(CamTSetRot, gSaveRx, gSaveRy, gSaveRz, gSaveRw): wrote = wrote + 1
  if camWriteF(CamTSetFov, gSaveFov): wrote = wrote + 1
  if camWriteF(CamTSetNear, gSaveNear): wrote = wrote + 1
  if camWriteF(CamTSetFar, gSaveFar): wrote = wrote + 1

  # ---- the readback. Prefer the NEGATIVE: nothing still differs. ----
  var px = 0.0
  var py = 0.0
  var pz = 0.0
  var rx = 0.0
  var ry = 0.0
  var rz = 0.0
  var rw = 0.0
  var fov = 0.0
  var nr = 0.0
  var fr = 0.0
  let okP = camReadV3(CamTGetPos, px, py, pz)
  let okR = camReadV4(CamTGetRot, rx, ry, rz, rw)
  let okF = camReadF(CamTGetFov, fov)
  let okN = camReadF(CamTGetNear, nr)
  let okX = camReadF(CamTGetFar, fr)
  if not okP or not okR or not okF or not okN or not okX:
    gCamRestoreVerdict = "INCONCLUSIVE -- " & $wrote & " of 5 writes were " &
      "accepted but the camera could not be read back afterwards, so whether " &
      "the pose is restored is UNKNOWN. This is not a pass."
    warn "camera: free camera OFF (" & why & "). " & gCamRestoreVerdict
    return
  var bad = 0
  var first = ""
  if camAbs(px - gSavePx) > CamPosEps or camAbs(py - gSavePy) > CamPosEps or
     camAbs(pz - gSavePz) > CamPosEps:
    bad = bad + 1
    if first.len == 0:
      first = "position reads (" & duFmt2(px) & ", " & duFmt2(py) & ", " &
              duFmt2(pz) & ") but was saved as (" & duFmt2(gSavePx) & ", " &
              duFmt2(gSavePy) & ", " & duFmt2(gSavePz) & ")"
  if camAbs(rx - gSaveRx) > CamRotEps or camAbs(ry - gSaveRy) > CamRotEps or
     camAbs(rz - gSaveRz) > CamRotEps or camAbs(rw - gSaveRw) > CamRotEps:
    bad = bad + 1
    if first.len == 0:
      first = "rotation quaternion does not read back equal to the saved one"
  if camAbs(fov - gSaveFov) > CamFovEps:
    bad = bad + 1
    if first.len == 0:
      first = "fieldOfView reads " & duFmt2(fov) & " but was saved as " &
              duFmt2(gSaveFov)
  if camAbs(nr - gSaveNear) > CamFovEps:
    bad = bad + 1
    if first.len == 0:
      first = "nearClipPlane reads " & duFmt2(nr) & " but was saved as " &
              duFmt2(gSaveNear)
  if camAbs(fr - gSaveFar) > CamFovEps:
    bad = bad + 1
    if first.len == 0:
      first = "farClipPlane reads " & duFmt2(fr) & " but was saved as " &
              duFmt2(gSaveFar)
  if bad == 0:
    gCamRestoreVerdict = "PASS -- no component of the camera pose still " &
      "differs from what was saved on entry: position, rotation quaternion, " &
      "fieldOfView, nearClipPlane and farClipPlane all READ BACK equal off " &
      "the live camera."
  else:
    gCamRestoreVerdict = "FAIL -- " & $bad & " of 5 components did not read " &
      "back equal after the restore write; first: " & first & ". The camera " &
      "is NOT as it was found."
  warn "camera: free camera OFF (" & why & "). RESTORE " & gCamRestoreVerdict

proc camFreeStep(dt: float64) =
  ## One frame of the free camera. Called from inside the already-open guard.
  # Rotation first: the movement basis must reflect where we are about to look,
  # not where we looked last frame.
  var turn = CamTurnSpeed * dt
  if cCamKeyDown(CamVkShift) != 0'i32: turn = turn * 2.0
  if cCamKeyDown(CamVkLeft) != 0'i32: gCamYaw = gCamYaw - turn
  if cCamKeyDown(CamVkRight) != 0'i32: gCamYaw = gCamYaw + turn
  if cCamKeyDown(CamVkUp) != 0'i32: gCamPitch = gCamPitch - turn
  if cCamKeyDown(CamVkDown) != 0'i32: gCamPitch = gCamPitch + turn
  # Clamp pitch rather than wrapping it: past +-90 the yaw axis flips and the
  # controls invert, which reads to a player as the camera being broken.
  if gCamPitch > 89.0: gCamPitch = 89.0
  if gCamPitch < -89.0: gCamPitch = -89.0
  while gCamYaw >= 360.0: gCamYaw = gCamYaw - 360.0
  while gCamYaw < 0.0: gCamYaw = gCamYaw + 360.0
  discard camWriteV(CamTSetEuler, gCamPitch, gCamYaw, 0.0, 0.0)

  # The basis comes from the camera's OWN transform, read back after the
  # rotation write. No trigonometry is done here: the host has no verified sin
  # or cos on this path and inventing one to save three calls would be exactly
  # the kind of unverified arithmetic that produces a plausible wrong number.
  var fx = 0.0
  var fy = 0.0
  var fz = 0.0
  var rx = 0.0
  var ry = 0.0
  var rz = 0.0
  var ux = 0.0
  var uy = 0.0
  var uz = 0.0
  if not camReadV3(CamTGetFwd, fx, fy, fz): return
  if not camReadV3(CamTGetRight, rx, ry, rz): return
  if not camReadV3(CamTGetUp, ux, uy, uz): return

  var speed = CamBaseSpeed * dt
  if cCamKeyDown(CamVkShift) != 0'i32: speed = speed * CamFastMult
  elif cCamKeyDown(CamVkCtrl) != 0'i32: speed = speed * CamSlowMult
  var mf = 0.0
  var mr = 0.0
  var mu = 0.0
  if cCamKeyDown(CamVkW) != 0'i32: mf = mf + 1.0
  if cCamKeyDown(CamVkS) != 0'i32: mf = mf - 1.0
  if cCamKeyDown(CamVkD) != 0'i32: mr = mr + 1.0
  if cCamKeyDown(CamVkA) != 0'i32: mr = mr - 1.0
  if cCamKeyDown(CamVkSpace) != 0'i32: mu = mu + 1.0
  gCamPos0 = gCamPos0 + (fx * mf + rx * mr + ux * mu) * speed
  gCamPos1 = gCamPos1 + (fy * mf + ry * mr + uy * mu) * speed
  gCamPos2 = gCamPos2 + (fz * mf + rz * mr + uz * mu) * speed
  discard camWriteV(CamTSetPos, gCamPos0, gCamPos1, gCamPos2, 0.0)

proc camCheckHold() =
  ## THE FINISHED-STATE CHECK for the free camera itself, and the one that can
  ## genuinely fail: read the position off the live camera and compare it to
  ## the pose the host wrote LAST frame. If the game re-drives the camera
  ## transform in its own LateUpdate, this reports it in words instead of the
  ## feature silently appearing to do nothing.
  if gCamHeld < 2: return
  var px = 0.0
  var py = 0.0
  var pz = 0.0
  if not camReadV3(CamTGetPos, px, py, pz):
    gCamHoldVerdict = "INCONCLUSIVE -- the camera position could not be read " &
                      "back this frame"
    return
  if camAbs(px - gCamPos0) > 0.05 or camAbs(py - gCamPos1) > 0.05 or
     camAbs(pz - gCamPos2) > 0.05:
    gCamHoldVerdict = "FAIL -- the camera reads (" & duFmt2(px) & ", " &
      duFmt2(py) & ", " & duFmt2(pz) & ") but the host wrote (" &
      duFmt2(gCamPos0) & ", " & duFmt2(gCamPos1) & ", " & duFmt2(gCamPos2) &
      "). Something else is re-driving the camera transform after our write " &
      "-- the free camera is NOT holding, whatever it looks like."
  else:
    gCamHoldVerdict = "PASS -- the camera reads back at the position the host " &
      "wrote, so the write is holding against the game's own per-frame " &
      "camera drive."

proc camApplyRequest() =
  ## Apply the one pending write an export asked for. Requests are applied from
  ## the drain, never from the caller's thread, because a mod calls the export
  ## from inside its own non-re-entrant guard.
  if gCamReqKind == 0'i32: return
  let k = gCamReqKind
  gCamReqKind = 0'i32
  var ok = false
  if k == 1'i32: ok = camWriteF(CamTSetFov, gCamReqA)
  elif k == 2'i32: ok = camWriteF(CamTSetNear, gCamReqA)
  elif k == 3'i32: ok = camWriteF(CamTSetFar, gCamReqA)
  elif k == 4'i32: ok = camWriteV(CamTSetPos, gCamReqA, gCamReqB, gCamReqC, 0.0)
  elif k == 5'i32: ok = camWriteV(CamTSetEuler, gCamReqA, gCamReqB, gCamReqC, 0.0)
  gCamReqDone = (if ok: 1'i32 else: 2'i32)

proc camTickBody(a: Il2CppPtr): Il2CppPtr {.
    exportc: "aowl_cam_tick_body", cdecl.} =
  # THE END-OF-RAID RULE, evaluated FIRST and unconditionally. An overlay that
  # survives onto the raid-ended screen has been complained about twice; this
  # is the check that stops a third. UNKNOWN counts as "not deployed" on
  # purpose -- "I could not look" must restore the camera, not keep it.
  if gCamFreeOn and rpPhase() != RpPhaseDeployed:
    camFreeExit("raid phase is " & rpPhaseName(rpPhase()) &
                ", not DEPLOYED -- " & rpWhy())
    return cast[Il2CppPtr](1)

  if not camAcquire():
    if gCamFreeOn:
      camFreeExit("the camera went away: " & gCamWhy)
    return cast[Il2CppPtr](1)

  discard camSample()
  camApplyRequest()

  # An export's request, honoured here rather than in the caller's thread.
  if gCamWantOff:
    gCamWantOff = false
    gCamWantOn = false
    if gCamFreeOn:
      camFreeExit("a mod called aowl_host_camera_free(0)")
      return cast[Il2CppPtr](1)
  if gCamWantOn:
    gCamWantOn = false
    if gCamFree and not gCamFreeOn and rpPhase() == RpPhaseDeployed:
      discard camFreeEnter()

  # THE CONFIG ENGAGE LATCH. Held, not consumed: `cameraFreeCamEngage` true
  # while the player is still in the menu must engage when the raid starts,
  # not be dropped on the floor. Every refusal names itself in `gCamEngageWhy`
  # so a run where nothing happened reads as INCONCLUSIVE with a reason,
  # rather than as silence.
  if gCamEngageLatch and not gCamFreeOn:
    if not gCamFree:
      gCamEngageWhy = "cameraFreeCamEngage is true but cameraFreeCam is OFF " &
                      "-- nothing is armed. INCONCLUSIVE."
    elif rpPhase() != RpPhaseDeployed:
      gCamEngageWhy = "cameraFreeCamEngage is true and WAITING: the raid " &
                      "phase is " & rpPhaseName(rpPhase()) & ", not DEPLOYED " &
                      "(" & rpWhy() & "). INCONCLUSIVE."
    else:
      if camFreeEnter():
        gCamEngageLatch = false
        gCamEngageWhy = "engaged by the config key cameraFreeCamEngage"
      else:
        gCamEngageWhy = "cameraFreeCamEngage is true but the entry was " &
                        "refused: " & gCamExitReason & ". INCONCLUSIVE."

  if gCamFree and rpPhase() == RpPhaseDeployed:
    if cDuForeground() != 0'i32 and cDuKeyEdge(CamVkF7) != 0'i32:
      if gCamFreeOn:
        camFreeExit("F7 pressed")
        return cast[Il2CppPtr](1)
      else:
        discard camFreeEnter()

  if gCamFreeOn:
    camCheckHold()
    let now = cNowMs()
    var ms = float64(now - gCamLastMs)
    gCamLastMs = now
    if ms < 1.0: ms = 1.0
    if ms > CamMaxDtMs: ms = CamMaxDtMs
    # Foreground gating: alt-tabbed out, GetAsyncKeyState still sees the whole
    # keyboard, so without this typing "was" in a chat window flies the camera.
    if cDuForeground() != 0'i32:
      camFreeStep(ms / 1000.0)
    gCamHeld = gCamHeld + 1
  cast[Il2CppPtr](1)

proc camReassertBody(a: Il2CppPtr): Il2CppPtr {.
    exportc: "aowl_cam_reassert_body", cdecl.} =
  ## Re-write the pose at the LAST main-thread point in the frame.
  ##
  ## WHY: the update drain is a PREFIX on `TarkovApplication::Update`, so the
  ## game's own camera drive (a LateUpdate) runs AFTER it and wins the frame.
  ## This is the identical race the cursor feature lost and then won by moving
  ## its re-clobber into the render drain, and it is why `camCheckHold` exists
  ## to say which of the two actually happened rather than assuming.
  if not gCamFreeOn: return cast[Il2CppPtr](1)
  if gCamObj == nil or gCamTf == nil: return cast[Il2CppPtr](1)
  if not duOk(gCamTf, 0x20'i32) or not iUnityAlive(gCamTf):
    return cast[Il2CppPtr](1)
  discard camWriteV(CamTSetEuler, gCamPitch, gCamYaw, 0.0, 0.0)
  discard camWriteV(CamTSetPos, gCamPos0, gCamPos1, gCamPos2, 0.0)
  cast[Il2CppPtr](1)

proc camDrainTick*() =
  ## Rides the existing `TarkovApplication::Update` drain. Installs no detour:
  ## a second detour on one function overwrites the first's trampoline and
  ## silently kills it.
  if camDisabled(): return
  if not gCamApi and not gCamFree: return
  if not camIndicesOk(): return
  # FINISH THE BIND. At boot GameAssembly.dll may not be mapped yet; here on
  # the Update drain it is mapped by construction, because this drain IS game
  # code. Cheap and self-latching: one integer compare once bound.
  camBindRetry()
  gCamTicks = gCamTicks + 1

  # LIVE RECONCILE of `cameraFreeCamEngage`. Outside the guard on purpose: this
  # is a file read and touches no game memory, and the guard below is not
  # re-entrant. Throttled to 0.5Hz so the drain never does per-frame file IO.
  # Only the EDGES act, so a config left true does not re-enter after an F7
  # exit, and a config left false does not fight a hand-driven F7 session.
  let nowCfg = cNowMs()
  if (nowCfg - gCamEngagePollAt) >= 2000'u64:
    gCamEngagePollAt = nowCfg
    let want = readBoolKey("cameraFreeCamEngage")
    if not gCamEngageSeen:
      gCamEngageSeen = true
      gCamEngageCfg = want
      if want:
        gCamEngageLatch = true
        gCamEngageWhy = "cameraFreeCamEngage was already true at the first poll"
        info "camera: cameraFreeCamEngage is true at startup -- the free " &
             "camera will engage as soon as the raid phase is DEPLOYED."
    elif want != gCamEngageCfg:
      gCamEngageCfg = want
      if want:
        gCamEngageLatch = true
        gCamEngageWhy = "cameraFreeCamEngage went false -> true"
        info "camera: cameraFreeCamEngage went ON (config reconcile). " &
             "Engaging the free camera on the next DEPLOYED frame."
      else:
        gCamEngageLatch = false
        gCamEngageWhy = "cameraFreeCamEngage went true -> false"
        info "camera: cameraFreeCamEngage went OFF (config reconcile). " &
             "Disengaging; look for the RESTORE verdict on the next line."
        gCamWantOff = true

  # THE STATUS LINE IN THE LOG. Every 10s while the free camera is active, and
  # every 60s when it is not.
  #
  # THE DEFECT THIS REPLACES, measured 2026-08-31: this was gated on
  # `gCamFreeOn`, so a whole run with `cameraApi` on and the camera never
  # engaged printed NOTHING -- "camera never sampled" and "acquire failed"
  # were indistinguishable, and both read as silence rather than as
  # INCONCLUSIVE. A status line that only appears on success cannot report a
  # failure.
  let quiet = if gCamFreeOn: 10000'u64 else: 60000'u64
  if (cNowMs() - gCamSaidAt) >= quiet:
    gCamSaidAt = cNowMs()
    info camStatus()
  if cCamTickGuarded(nil) == nil:
    gCamFaults = gCamFaults + 1
    gCamSampled = false
    gCamFreeOn = false
    if gCamFaults == 1 or gCamFaults == CamMaxFaults:
      warn "camera: the guarded tick FAULTED (" & $gCamFaults & " of " &
           $CamMaxFaults & "). The free camera is forced OFF and every read " &
           "now answers INCONCLUSIVE, which is a refusal and not a pose. At " &
           "the cap this module stops touching game memory for the session. " &
           "NOTE: the saved pose could not be written back through a faulting " &
           "path, so if the free camera was active the camera is left where " &
           "the host last put it -- that is a FAILED restore, and it is said " &
           "here rather than left to be discovered on screen."

proc camRenderTick*() =
  ## Rides the existing render drain (`OnRenderObject`/`OnPostRender`), the last
  ## main-thread point in the frame. Its own single guard; opens no inner one.
  if camDisabled(): return
  if not gCamFreeOn: return
  if cCamReassertGuarded(nil) == nil:
    gCamFaults = gCamFaults + 1
    gCamFreeOn = false

proc camBindAttempt(fromRetry: bool) =
  ## ONE bind attempt. Called at boot and, if that was too early, again from the
  ## main-thread drain until GameAssembly.dll is mapped.
  ##
  ## THE DEFECT THIS REPLACES, measured live 2026-08-31: this ran once at
  ## host-config time, ~1s before IL2CPP maps GameAssembly.dll, so all 15
  ## targets came back reason code 1 (`!ga`) and the host PRINTED that as
  ## "0 of 15 targets verified" -- a verdict about the build, computed before
  ## the build's code was mapped. `mods/fov` byte-verified the very same
  ## addresses moments later purely because it binds later. Nothing was ever
  ## wrong with an RVA or a prologue.
  ##
  ## Nothing about the verification is relaxed here: `aowl_cam_fn` still
  ## VirtualQuery-checks committed+executable and still compares 16 prologue
  ## bytes against the STARTUP SNAPSHOT (`aowl_pro_verify`), and every operation
  ## still refuses on an unverified target. The only change is WHEN we ask, and
  ## that a "no module" answer is no longer mistaken for an answer.
  if not camIndicesOk():
    gCamBindState = 2'i32
    return
  if cCamModuleReady() == 0'i32:
    # NOT a verdict. The startup prologue snapshot cannot be taken before the
    # bytes are mapped either, so concluding anything here would be concluding
    # from an unmapped module.
    gCamBindState = 1'i32
    if not fromRetry:
      info "camera: binding DEFERRED -- GameAssembly.dll is not mapped yet " &
           "(reason code " & $cCamReason() & ": " & $cCamReasonText() & "). " &
           "This is NOT a byte mismatch and NOT a wrong RVA; the host runs at " &
           "DLL-attach and IL2CPP maps the module about a second later. The " &
           "bind will be RETRIED on the TarkovApplication::Update drain and " &
           "the real verdict printed then. No NULL handle is cached."
    return
  var ok = 0
  var bad = 0
  var i = 0
  while i < int(cCamTargetCount()):
    if cCamFn(int32(i)) != nil:
      ok = ok + 1
    else:
      bad = bad + 1
      warn "camera: target " & $i & " '" & $cCamName(int32(i)) & "' @0x" &
           hexOf(uint64(cCamRva(int32(i)))) & " REJECTED, reason code " &
           $cCamReason() & ": " & $cCamReasonText()
    i = i + 1
  gCamBindState = 2'i32
  info "camera: " & $ok & " of " & $int(cCamTargetCount()) & " targets " &
       "verified by RVA + startup-snapshot prologue (" & $bad & " rejected, " &
       "last reason code " & $cCamReason() & "). ABI, MEASURED from the " &
       "prologues and not assumed: Vector3 (12 bytes) RETURNS through a " &
       "hidden buffer (retbuf RCX, this RDX, MethodInfo* R8) and is PASSED BY " &
       "ADDRESS in RDX; Quaternion (16 bytes) the same; a float argument is " &
       "in XMM1. All 15 RVAs resolve UNIQUE (owners=1). No detour is " &
       "installed and no name is resolved at runtime."
  if bad > 0:
    warn "camera: " & $bad & " target(s) did NOT byte-verify. Every operation " &
         "that needs one of them will REFUSE and say so; none will be " &
         "attempted against unverified bytes."
  if gCamFree:
    info "camera: cameraFreeCam is set. Press F7 IN A RAID (raid phase must " &
         "read DEPLOYED) to take the camera; WASD moves, Space rises, arrows " &
         "look, Shift is fast and Ctrl is slow. F7 again restores. The " &
         "restore is verified by READING THE POSE BACK off the live camera " &
         "and comparing it to what was saved, not by echoing the write -- " &
         "look for 'RESTORE PASS' or 'RESTORE FAIL' in this log. It exits and " &
         "restores automatically the moment the raid phase stops reading " &
         "DEPLOYED, which includes the post-raid results screen."
    info "camera: NO KEYBOARD NEEDED. Setting \"cameraFreeCamEngage\": true " &
         "in aowlspt-host.json engages the free camera live (polled off this " &
         "drain every 2s, no restart); setting it back to false disengages " &
         "and runs the SAME readback restore check. Measured reason F7 is not " &
         "enough: synthetic function keys do not reach this client."

proc camBind*() =
  ## Read the flags at boot and make the FIRST bind attempt. If the module is
  ## not mapped yet the attempt defers and `camBindRetry` finishes the job.
  gCamApi = readBoolKey("cameraApi")
  gCamFree = readBoolKey("cameraFreeCam")
  if not gCamApi and not gCamFree:
    return
  if gCamFree and not gCamApi:
    gCamApi = true
    info "camera: cameraFreeCam implies cameraApi; the read/write surface is " &
         "armed because the free camera is built on it."
  camBindAttempt(false)

proc camBindRetry() =
  ## Called from the main-thread drain, where GameAssembly.dll is mapped by
  ## construction (the drain rides TarkovApplication::Update, which is game
  ## code). At most one attempt per frame, and it stops the moment a real
  ## verdict exists -- state 2 is latched, so this cannot re-verify or
  ## re-count.
  if gCamBindState == 2'i32: return
  gCamBindTries = gCamBindTries + 1
  camBindAttempt(true)
  if gCamBindState != 2'i32 and gCamBindTries >= 600 and not gCamBindSaidWait:
    gCamBindSaidWait = true
    warn "camera: still UNBOUND after " & $gCamBindTries & " drain frames " &
         "(" & $cCamWaitCount() & " resolves found no module). The camera API " &
         "is INCONCLUSIVE, not failed: nothing has been verified and nothing " &
         "will be called. Reason code " & $cCamReason() & ": " &
         $cCamReasonText()

proc camStatus*(): string =
  ## Every leg separately falsifiable, so a wrong verdict says WHICH one
  ## produced it instead of being a bare bool.
  if camDisabled():
    return "camera: self-disabled after " & $gCamFaults &
           " faults -- INCONCLUSIVE"
  if not gCamApi and not gCamFree:
    return "camera: both flags OFF (cameraApi, cameraFreeCam). Nothing is " &
           "armed; this is not a statement about the build."
  if gCamBindState != 2'i32:
    return "camera: NOT BOUND YET -- the bind is deferred until " &
           "GameAssembly.dll is mapped (" & $gCamBindTries & " drain retries " &
           "so far, reason code " & $cCamReason() & ": " & $cCamReasonText() &
           "). INCONCLUSIVE, not a failure: nothing verified, nothing called."
  "camera: acquire=" & gCamWhy &
  " targets=" & $cCamOkCount() & "/" & $int(cCamTargetCount()) &
  " sampled=" & (if gCamSampled: "yes" else: "NO -- reads are refusals") &
  (if gCamSampled:
     " pos(" & duFmt2(gCamPx) & ", " & duFmt2(gCamPy) & ", " & duFmt2(gCamPz) &
     ") fov=" & duFmt2(gCamFov) & " near=" & duFmt2(gCamNear) & " far=" &
     duFmt2(gCamFar)
   else: "") &
  " freecam=" & (if gCamFreeOn: "ON(" & $gCamHeld & " frames)" else: "off") &
  " engage=" & (if gCamEngageCfg: "cfg ON" else: "cfg off") &
  "/" & (if gCamEngageLatch: "LATCHED" else: "idle") & " (" & gCamEngageWhy & ")" &
  (if gCamExitReason.len > 0: "[last exit: " & gCamExitReason & "]" else: "") &
  " hold=" & gCamHoldVerdict &
  " restore=" & gCamRestoreVerdict &
  " ticks=" & $gCamTicks & " faults=" & $gCamFaults

# ---------------------------------------------------------------------------
# THE EXPORTED ABI -- for mods and the live inspector.
#
# Read is CACHE-ONLY and write is REQUEST-ONLY: neither evaluates in the
# caller's thread, because a mod calls these from inside its own
# `aowl_p_p_seh` and that guard is not re-entrant. This is the same shape
# `aowl_host_raid_phase` uses and for the same reason.
#
# `aowl_host_camera_read(what)` returns 1 when the cached pose is a real
# sample and 0 when it is a refusal -- 0 is never dressed up as a value.
# ---------------------------------------------------------------------------

var gCamOut0 = 0.0
var gCamOut1 = 0.0
var gCamOut2 = 0.0
var gCamOut3 = 0.0

proc aowlHostCameraRead(what: int32): int32 {.
    exportc: "aowl_host_camera_read_impl", cdecl.} =
  ## what: 1 position, 2 rotation quaternion, 3 fieldOfView, 4 nearClipPlane,
  ## 5 farClipPlane, 6 the host's free-camera pose (0 when not active).
  gCamOut0 = 0.0
  gCamOut1 = 0.0
  gCamOut2 = 0.0
  gCamOut3 = 0.0
  if what == 6'i32:
    if not gCamFreeOn: return 0'i32
    gCamOut0 = gCamPos0
    gCamOut1 = gCamPos1
    gCamOut2 = gCamPos2
    gCamOut3 = gCamYaw
    return 1'i32
  if not gCamSampled: return 0'i32
  if what == 1'i32:
    gCamOut0 = gCamPx
    gCamOut1 = gCamPy
    gCamOut2 = gCamPz
  elif what == 2'i32:
    gCamOut0 = gCamRx
    gCamOut1 = gCamRy
    gCamOut2 = gCamRz
    gCamOut3 = gCamRw
  elif what == 3'i32: gCamOut0 = gCamFov
  elif what == 4'i32: gCamOut0 = gCamNear
  elif what == 5'i32: gCamOut0 = gCamFar
  else: return 0'i32
  1'i32

proc aowlHostCameraOut(i: int32): float64 {.
    exportc: "aowl_host_camera_out_impl", cdecl.} =
  if i == 0'i32: gCamOut0
  elif i == 1'i32: gCamOut1
  elif i == 2'i32: gCamOut2
  elif i == 3'i32: gCamOut3
  else: 0.0

proc aowlHostCameraWrite(what: int32; a, b, c: float64): int32 {.
    exportc: "aowl_host_camera_write_impl", cdecl.} =
  ## Record a request the next guarded drain applies. Returns 1 when the
  ## request was RECORDED -- not when it landed. Poll `aowl_host_camera_done`
  ## for that; conflating the two would be a check that cannot fail.
  if camDisabled() or not gCamApi: return 0'i32
  if what < 1'i32 or what > 5'i32: return 0'i32
  gCamReqKind = what
  gCamReqA = a
  gCamReqB = b
  gCamReqC = c
  gCamReqDone = 0'i32
  1'i32

proc aowlHostCameraDone(): int32 {.
    exportc: "aowl_host_camera_done_impl", cdecl.} =
  ## 0 still pending, 1 applied, 2 the write was REFUSED by the guarded path.
  gCamReqDone

proc aowlHostCameraFree(on: int32): int32 {.
    exportc: "aowl_host_camera_free_impl", cdecl.} =
  ## Ask for the free camera. Honoured only while the raid phase reads
  ## DEPLOYED, and refused (0) otherwise -- the same latch that keeps overlays
  ## off the post-raid screen.
  if camDisabled() or not gCamFree: return 0'i32
  if on != 0'i32:
    if rpPhase() != RpPhaseDeployed: return 0'i32
    if gCamFreeOn: return 1'i32
    gCamReqKind = 0'i32
    # Entering touches game memory, so it happens in the drain, not here.
    gCamWantOn = true
    return 1'i32
  gCamWantOff = true
  1'i32

{.emit: """
extern int aowl_host_camera_read_impl(int what);
extern double aowl_host_camera_out_impl(int i);
extern int aowl_host_camera_write_impl(int what, double a, double b, double c);
extern int aowl_host_camera_done_impl(void);
extern int aowl_host_camera_free_impl(int on);
__declspec(dllexport) int aowl_host_camera_read(int what) {
    return aowl_host_camera_read_impl(what);
}
__declspec(dllexport) double aowl_host_camera_out(int i) {
    return aowl_host_camera_out_impl(i);
}
__declspec(dllexport) int aowl_host_camera_write(int what, double a,
                                                 double b, double c) {
    return aowl_host_camera_write_impl(what, a, b, c);
}
__declspec(dllexport) int aowl_host_camera_done(void) {
    return aowl_host_camera_done_impl();
}
__declspec(dllexport) int aowl_host_camera_free(int on) {
    return aowl_host_camera_free_impl(on);
}
""".}
