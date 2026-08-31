# region.nim -- THE HOST'S OWNERSHIP OF THE SHARED PER-FRAME REGION.
#
# `abi/aowlspt_region.h` is the whole facility; this file does three small
# things and nothing else:
#
#   1. It is the ONE translation unit that defines `AOWL_REGION_HOST`, so the
#      registry, the dispatcher and the `aowl_region_*` exports exist exactly
#      once in the process. Every mod DLL includes the same header WITHOUT that
#      define and gets a `GetProcAddress` client of these exports.
#
#   2. It rides the EXISTING `EFT.UI.PreloaderUI::Update` detour. It installs
#      NO second detour -- two detours on one function have the second
#      overwrite the first's trampoline and silently kill the first feature.
#      `bindRegion` aliases onto whichever slot another feature already claimed
#      and, only if nobody holds it, verifies the prologue through
#      `cDuPreloaderTarget` (which compares against the STARTUP SNAPSHOT, not
#      live memory, so it cannot self-reject because someone else detoured the
#      function first) and attaches its own.
#
#   3. It gives the region a log sink, so a fault or an overrun ends up in
#      `aowlspt-host.log` naming the participant.
#
# THE GUARD. `regionFired` calls `aowl_region_frame` DIRECTLY -- not through a
# guard thunk, and that is deliberate rather than an omission. The dispatcher
# opens one `aowl_p_p_seh` per participant, entered and exited before the next
# one is entered; wrapping the dispatcher itself would make every one of those
# a NESTED guard, and `aowl_p_p_seh` has a single thread-local `jmp_buf` and
# clears `aowl_seh_active` on the inner return, so nesting does not add a guard,
# it silently removes the outer one. The dispatcher's own body touches only the
# region's fixed arrays and integers -- no game pointer, no dereference of
# anything a participant supplied, no allocation -- so it has nothing to be
# guarded from. And it does not merely assume that: it REFUSES, loudly, if it
# finds a guard already active on the thread.
#
# FLAG-GATED, DEFAULT OFF: `sharedRegion` in `aowlspt-host.json`. With the flag
# off nothing binds, `aowl_region_register` still succeeds for any mod that
# calls it (registration is always legal), and the region simply never fires --
# which is the documented "registered before the Unity thread is live" state,
# not a silent failure. `aowl_region_is_armed` tells a mod which it is in.

{.emit: """
/* THE CAMERA. Included BEFORE the region so `aowlspt_regproj.h` below can use
 * this file's already-measured RVAs, sret shapes and per-frame view-projection
 * snapshot instead of introducing a second copy of any of them. Everything in
 * it is `static`, so "using it" means sharing this translation unit -- which is
 * exactly what makes this the right TU: it is the only one in the host that
 * defines AOWL_REGION_HOST, so the projector and the seat it fills are compiled
 * together and cannot drift onto two copies of the state. */
#include "aowlspt_admin.h"

#define AOWL_REGION_HOST
#include "aowlspt_region.h"

/* The F3 profiler widget's read-only view of the participant table. It MUST be
 * included here and nowhere else: this is the one translation unit in the host
 * that defines AOWL_REGION_HOST, and `aowlspt_regview.h` `#error`s if it is not
 * already set. See that file for why including `aowlspt_region.h` from the
 * overlay side instead would silently delete this whole facility from the
 * build. */
#include "aowlspt_regview.h"

/* THE PROJECTOR that fills the region's long-empty projector seat, so a map
 * contact is drawn at its TRUE PROJECTED SCREEN POSITION instead of as a
 * bearing on a ring. It must come after BOTH includes above and it says so
 * itself with an #error. See that file for the frame split (three il2cpp calls
 * per frame, pure arithmetic per contact), the single-guard rule it obeys in
 * both directions, and the behind-camera decision. */
#include "aowlspt_regproj.h"

/* THE UNITY POST-PROCESSING SURVEY. Read-only, one-shot, flag-gated
 * (`unityPostProbe`, default OFF). It answers a question the D3D11 grading
 * path in `aowlspt_graphics.h` never could: what post processing does the
 * GAME itself have, live, on this camera. `aowlspt_components.h` comes first
 * because the survey identifies every pointer it touches by reading the
 * object's own klass name -- readability is not liveness, and type confusion
 * beats both guards. */
#include "aowlspt_components.h"
#include "aowlspt_unitypp.h"

/* The log sink. Nimony implements `aowlspt_nim_region_log`; this adapts the
 * plain `const char*` the header emits into it. */
/* nimony renders a `cstring` parameter as `unsigned char*` (its NC8), so the
 * declaration has to say that or the two disagree at the C level. The cast is
 * the only place the two spellings meet. */
extern void aowlspt_nim_region_log(unsigned char* line);
static void aowl_region_sink(const char* line) {
    aowlspt_nim_region_log((unsigned char*)(void*)line);
}
static void aowl_region_boot(void) { aowl_region_init(aowl_region_sink); }

/* ------------------------------------------------------------------ *
 * THE DLL EXPORTS.
 *
 * Everything in `aowlspt_region.h` is `static`, so it is private to this
 * translation unit. These thin wrappers are the mod-facing surface: a mod DLL
 * (or the overlay DLL, which is a separate module) includes the SAME header
 * WITHOUT `AOWL_REGION_HOST` and resolves exactly these names by
 * `GetProcAddress` on `aowlspt-host-il2cpp.dll`. An older host without them is
 * a clean AOWL_REGION_REFUSE_NOHOST, never a load failure.
 *
 * Note what is NOT exported: `aowl_region_frame`, `aowl_region_set_armed` and
 * `aowl_region_set_projector`. Dispatch and arming are the HOST's, and a mod
 * that could call `aowl_region_frame` from its own thread would be dispatching
 * every other mod off the Unity thread. It is refused by not existing.
 * ------------------------------------------------------------------ */
#define AOWL_RG_EXPORT __declspec(dllexport)
AOWL_RG_EXPORT int32_t aowl_region_abi_x(void) { return aowl_region_abi(); }
AOWL_RG_EXPORT int32_t aowl_region_register_x(const AowlRegionDesc* d) { return aowl_region_register(d); }
AOWL_RG_EXPORT int32_t aowl_region_unregister_x(int32_t h) { return aowl_region_unregister(h); }
AOWL_RG_EXPORT int32_t aowl_region_set_enabled_x(int32_t h, int32_t on) { return aowl_region_set_enabled(h, on); }
AOWL_RG_EXPORT int32_t aowl_region_status_x(int32_t h, AowlRegionStatus* o) { return aowl_region_status(h, o); }
AOWL_RG_EXPORT int32_t aowl_region_line_x(float a, float b, float c, float d, float t, uint32_t k) { return aowl_region_line(a,b,c,d,t,k); }
AOWL_RG_EXPORT int32_t aowl_region_box_x(float a, float b, float c, float d, float t, uint32_t k) { return aowl_region_box(a,b,c,d,t,k); }
AOWL_RG_EXPORT int32_t aowl_region_fill_x(float a, float b, float c, float d, uint32_t k) { return aowl_region_fill(a,b,c,d,k); }
AOWL_RG_EXPORT int32_t aowl_region_text_x(float a, float b, const char* s, uint32_t k) { return aowl_region_text(a,b,s,k); }
AOWL_RG_EXPORT int32_t aowl_region_project_x(float a, float b, float c, float* x, float* y) { return aowl_region_project(a,b,c,x,y); }
/* The three-outcome projection. `aowl_region_project_x` above is kept, and is
 * now the STRICTER of the two: it returns 0 for a behind-camera point, which
 * every existing caller already reads as "do not draw". A caller that wants
 * the mirrored bearing must ask for it here, explicitly. */
AOWL_RG_EXPORT int32_t aowl_region_project_ex_x(float a, float b, float c, float* x, float* y, int32_t* f, float* d) { return aowl_region_project_ex(a,b,c,x,y,f,d); }
/* The texture table. `_define_x` copies into the host's static arena and is
 * idempotent for a resident key, so a submitter may call it every frame. */
AOWL_RG_EXPORT int32_t aowl_region_texture_define_x(uint64_t k, int32_t f, int32_t w, int32_t h, const void* p, uint32_t n) { return aowl_region_texture_define(k,f,w,h,p,n); }
AOWL_RG_EXPORT int32_t aowl_region_texture_have_x(uint64_t k) { return aowl_region_texture_have(k); }
AOWL_RG_EXPORT int32_t aowl_region_texture_forget_x(uint64_t k) { return aowl_region_texture_forget(k); }
AOWL_RG_EXPORT int32_t aowl_region_texture_count_x(void) { return aowl_region_texture_count(); }
AOWL_RG_EXPORT int64_t aowl_region_texture_evictions_x(void) { return aowl_region_texture_evictions(); }
/* The renderer needs the SAME frame clock the CPU table ages on, or the two
 * caches evict against each other. */
AOWL_RG_EXPORT int64_t aowl_region_frames_x(void) { return aowl_region_frames(); }
AOWL_RG_EXPORT const AowlRegionTexSlot* aowl_region_texture_slot_x(int32_t i) { return aowl_region_texture_slot(i); }
AOWL_RG_EXPORT int32_t aowl_region_quad_x(float x, float y, float w, float h, float u0, float v0, float u1, float v1, uint64_t k, uint32_t t) { return aowl_region_quad(x,y,w,h,u0,v0,u1,v1,k,t); }
AOWL_RG_EXPORT int32_t aowl_region_quadr_x(float x, float y, float w, float h, float u0, float v0, float u1, float v1, uint64_t k, uint32_t t, float rc, float rs, float rpx, float rpy, float cx, float cy, float cw, float ch) { return aowl_region_quadr(x,y,w,h,u0,v0,u1,v1,k,t,rc,rs,rpx,rpy,cx,cy,cw,ch); }
AOWL_RG_EXPORT int32_t aowl_region_commands_x(const AowlRegionCmd** o) { return aowl_region_commands(o); }
AOWL_RG_EXPORT int32_t aowl_region_is_armed_x(void) { return aowl_region_is_armed(); }
AOWL_RG_EXPORT int32_t aowl_region_count_x(void) { return aowl_region_count(); }

/* THE BACK-BUFFER SIZE -- newly exported. The state and the setter existed but
 * nothing called the setter and nothing could read it, so every participant's
 * read was a provably-always-0. `_known_x` is the one to test first: it is the
 * only way to tell "not published yet" from "zero pixels wide", and a layout
 * that cannot tell those apart collapses silently into the top-left corner. */
AOWL_RG_EXPORT int32_t aowl_region_screen_w_x(void) { return aowl_region_screen_w(); }
AOWL_RG_EXPORT int32_t aowl_region_screen_h_x(void) { return aowl_region_screen_h(); }
AOWL_RG_EXPORT int32_t aowl_region_screen_known_x(void) { return aowl_region_screen_known(); }
""".}

proc cRegionBoot() {.importc: "aowl_region_boot", nodecl.}
proc cRegionFrame(): int32 {.importc: "aowl_region_frame", nodecl.}
proc cRegionSetArmed(on: int32) {.importc: "aowl_region_set_armed", nodecl.}
proc cRegionCount(): int32 {.importc: "aowl_region_count", nodecl.}
proc cRegionFrames(): int64 {.importc: "aowl_region_frames", nodecl.}
proc cRegionFrameUs(): int64 {.importc: "aowl_region_frame_us", nodecl.}
proc cRegionDropped(): int64 {.importc: "aowl_region_dropped", nodecl.}
proc cRegionLastRefusal(): int32 {.importc: "aowl_region_last_refusal", nodecl.}
proc cRegionSetScreen(w, h: int32) {.importc: "aowl_region_set_screen", nodecl.}
proc cRegionScreenKnown(): int32 {.
  importc: "aowl_region_screen_known", nodecl.}
proc cWgWindowW(): int32 {.importc: "aowl_wg_window_w", nodecl.}
proc cWgWindowH(): int32 {.importc: "aowl_wg_window_h", nodecl.}

# THE PROJECTOR (`abi/aowlspt_regproj.h`). `cRegProjTick` is UNITY THREAD ONLY
# and opens its own single guard around the camera sample; everything else here
# is a plain integer read of our own statics.
proc cRegProjTick() {.importc: "aowl_regproj_tick", nodecl.}

# THE UNITY POST-PROCESSING SURVEY (`abi/aowlspt_unitypp.h`). Same contract as
# cRegProjTick: UNITY THREAD ONLY, opens its own single guard, must be entered
# and exited BEFORE cRegionFrame because the dispatcher refuses if it finds a
# guard already active on the thread. One-shot: it latches after one verdict.
proc cUppTick() {.importc: "aowl_upp_tick", nodecl.}
proc cUppDone(): int32 {.importc: "aowl_upp_is_done", nodecl.}
proc cUppDisabled(): int32 {.importc: "aowl_upp_is_disabled", nodecl.}
proc cUppEffects(): int32 {.importc: "aowl_upp_effect_count", nodecl.}
proc cUppHasGrading(): int32 {.importc: "aowl_upp_has_grading", nodecl.}
proc cRegProjInstalled(): int32 {.importc: "aowl_regproj_is_installed", nodecl.}
proc cRegProjDisabled(): int32 {.importc: "aowl_regproj_is_disabled", nodecl.}
proc cRegProjFaults(): int32 {.importc: "aowl_regproj_fault_count", nodecl.}
proc cRegProjSamples(): int64 {.importc: "aowl_regproj_sample_count", nodecl.}
proc cRegProjCalls(): int64 {.importc: "aowl_regproj_call_count", nodecl.}
proc cRegProjInFront(): int64 {.importc: "aowl_regproj_infront_count", nodecl.}
proc cRegProjBehind(): int64 {.importc: "aowl_regproj_behind_count", nodecl.}
proc cRegProjNoCam(): int64 {.importc: "aowl_regproj_nocam_count", nodecl.}
proc cRegProjNoScreen(): int64 {.
  importc: "aowl_regproj_noscreen_count", nodecl.}
proc cRegProjNonFinite(): int64 {.
  importc: "aowl_regproj_nonfinite_count", nodecl.}
proc cRegProjCamBind(): int32 {.importc: "aowl_regproj_cam_bind", nodecl.}
proc cRegProjCamRoute(): int32 {.importc: "aowl_regproj_cam_route", nodecl.}
proc cRegProjCamGen(): int32 {.importc: "aowl_regproj_cam_gen", nodecl.}
proc cRegProjSelfTestFails(): int32 {.
  importc: "aowl_regproj_cam_selftest_fails", nodecl.}

var gRegionFaults = 0
var gRegionBooted = false
var gRegionAnnounced = false
var gRegionScreenLogged = false
var gRegProjInstallLogged = false
var gRegProjSilentLogged = false
var gUppVerdictLogged = false

proc regionLog(line: cstring) {.exportc: "aowlspt_nim_region_log", cdecl.} =
  ## Every line the region emits -- a registration, a fault naming the
  ## participant, a budget overrun, a refusal -- lands in the host log at the
  ## level a human should read it at. Faults and refusals are warnings so
  ## `tools/hostlog.py summary` separates them from chatter.
  let s = $line
  if s.len == 0: return
  if s.contains("FAULTED") or s.contains("DISABLED") or
     s.contains("REFUSED") or s.contains("OVERRAN") or
     s.contains("THROTTLED"):
    warn s
  else:
    info s

proc regionEnsureBooted() =
  if not gRegionBooted:
    gRegionBooted = true
    cRegionBoot()

proc regionFired(regs: Il2CppPtr) =
  ## Dispatched by slot identity from `patchFired` / `patchReturned` for the
  ## shared `EFT.UI.PreloaderUI::Update` detour. Read-only with respect to the
  ## game: it never suppresses the original and never writes a game field.
  ##
  ## NO GUARD IS OPENED HERE. See the header of this file: the dispatcher
  ## guards each participant individually and a guard here would nest.
  discard regs
  # PUBLISH THE BACK-BUFFER SIZE, once a frame, before dispatching anyone.
  #
  # This is the missing caller. `aowl_region_set_screen` and the `screenW`/
  # `screenH` state existed, but nothing in the host ever called the setter and
  # nothing exported a getter -- so every participant that asked how big the
  # screen was read a provably-always-0, which is not a refusal but a plausible
  # number that collapses an edge-anchored layout into the top-left corner.
  #
  # The value is MEASURED from the game window's own client rect via
  # `GetActiveWindow` (the Unity thread owns the window, so this does not need
  # focus and stays correct while alt-tabbed). A non-positive measurement is
  # refused on both sides rather than stored, so a device reset cannot poison
  # it, and `aowl_region_screen_known` stays 0 until a real size has arrived.
  let sw = cWgWindowW()
  let sh = cWgWindowH()
  if sw > 0 and sh > 0:
    cRegionSetScreen(sw, sh)
    if not gRegionScreenLogged:
      gRegionScreenLogged = true
      okLog "region: back-buffer size published to participants -- " &
            $sw & "x" & $sh & " (measured from the game window's client rect; " &
            "aowl_region_screen_known() now reports " &
            $int(cRegionScreenKnown()) & ")"
  # THE PROJECTOR, sampled BEFORE dispatch and never during it.
  #
  # Order matters twice over. First, a participant that projects this frame must
  # see THIS frame's camera, not the previous one's. Second, `cRegProjTick`
  # opens an `aowl_p_p_seh` and the dispatcher REFUSES outright if it finds a
  # guard already active on the thread -- so the tick has to be entered and
  # exited here, above `cRegionFrame`, rather than folded into it.
  #
  # Flag-gated, default OFF (`regionProjector`). With it off nothing is sampled,
  # the projector seat stays empty, `aowl_region_project` keeps refusing with
  # REFUSE_NOPROJ, and every consumer keeps drawing its bearing ring -- which is
  # what makes turning this on a change that DEGRADES rather than blanks.
  # THE UNITY POST-PROCESSING SURVEY, same placement and for the same two
  # reasons as the projector tick below: it calls into Unity and it opens the
  # one guard, so it must run above cRegionFrame. Flag-gated, default OFF, and
  # it latches after a single verdict -- this is a survey, not a per-frame
  # feature, and with the flag off nothing is called at all.
  if gUnityPostProbeOn:
    cUppTick()
    if not gUppVerdictLogged and (cUppDone() != 0 or cUppDisabled() != 0):
      gUppVerdictLogged = true
      okLog "unity post: survey verdict recorded -- " &
            (if cUppDisabled() != 0: "DISABLED after faults"
             else: $cUppEffects() & " effect settings object(s) named, " &
                   "ColorGrading reached = " &
                   (if cUppHasGrading() != 0: "YES" else: "no")) &
            ". GRADING PROVIDER IS STILL D3D11 (aowlspt_graphics.h, Present " &
            "hook): the Unity path writes NOTHING yet, because " &
            "ParameterOverride<T>.value is an instantiated-generic offset " &
            "that is not derivable offline. The per-parameter byte dumps " &
            "above settle it; a write path follows in a separate change."

  if gRegionProjectorOn:
    cRegProjTick()
    if not gRegProjInstallLogged and cRegProjInstalled() != 0:
      gRegProjInstallLogged = true
      okLog "region projector: INSTALLED -- world points now project to TRUE " &
            "screen positions. Camera reached by route " & $cRegProjCamRoute() &
            " (1 = UnityEngine.Camera::get_main, 2 = CameraManager.Instance." &
            "<Camera>k__BackingField), " & $cRegProjSamples() &
            " good sample(s) so far, and the view-projection passed the " &
            "ten-metres-ahead-lands-centre self-test before the seat was " &
            "filled. Behind-camera points are still projected, flagged " &
            "BEHIND, and are a bearing rather than a position."
    # The honest silence-breaker. A projector that never installs is exactly as
    # invisible as one that was never written, so after ~30s of drains say
    # WHICH of the three distinguishable causes it is, once.
    if not gRegProjSilentLogged and cRegProjInstalled() == 0 and
       cRegionFrames() >= 1800'i64:
      gRegProjSilentLogged = true
      let camBind = cRegProjCamBind()
      if camBind == 2:
        warn "region projector: NOT installed -- a camera prologue did not " &
             "byte-match the recorded signature, i.e. a Tarkov update moved " &
             "one of Camera::get_main / get_worldToCameraMatrix / " &
             "get_projectionMatrix. Re-measure them before anything projects."
      elif cRegProjSelfTestFails() > 0'i32:
        warn "region projector: NOT installed -- the matrices were finite " &
             "but " & $cRegProjSelfTestFails() & " sample(s) FAILED the " &
             "finished-state self-test (a point ten metres straight ahead " &
             "did not land in the middle fifth of the frame). That is a " &
             "wrong view/projection pair or a wrong convention, NOT a " &
             "missing camera."
      elif cRegProjFaults() > 0'i32:
        warn "region projector: NOT installed -- " & $cRegProjFaults() &
             " camera sample(s) FAULTED through the guard" &
             (if cRegProjDisabled() != 0: " and it has self-disabled." else: ".")
      else:
        info "region projector: not installed yet -- bind state " & $camBind &
             ", " & $cRegProjCamGen() & " good sample(s). No fault and no " &
             "self-test failure, so this is the ordinary 'no camera exists " &
             "yet' state: Camera.main is untagged in Tarkov and " &
             "CameraManager.Instance.Camera is null outside a raid. " &
             "INCONCLUSIVE, not a failure."
  let r = cRegionFrame()
  if r < 0:
    inc gRegionFaults
    if gRegionFaults == 1 or (gRegionFaults mod 600) == 0:
      warn "region: dispatch refused (" & $r & "), refusal #" &
           $gRegionFaults & " -- the reason line above names it. No " &
           "participant ran this frame."
    if gRegionFaults == 60:
      cRegionSetArmed(0'i32)
      warn "region: sixty consecutive dispatch refusals -- the shared region " &
           "has DISARMED itself for this session rather than refuse every " &
           "frame forever. Individual participants are unaffected; this is " &
           "the region's own self-disable."
    return
  if not gRegionAnnounced and cRegionFrames() >= 120'i64:
    gRegionAnnounced = true
    okLog "region: 120 frames dispatched, " & $cRegionCount() &
          " participant(s), last frame " & $cRegionFrameUs() & " us, " &
          $cRegionDropped() & " draw command(s) dropped"
    # The projector's own numbers, in the SAME line, because "installed" is a
    # statement about our own write and says nothing about whether anything
    # actually projected. These are read back off the finished projections.
    if gRegionProjectorOn:
      okLog "region projector: " &
            (if cRegProjInstalled() != 0: "installed" else: "NOT installed") &
            ", " & $cRegProjCalls() & " projection(s) asked for -- " &
            $cRegProjInFront() & " in front, " & $cRegProjBehind() &
            " BEHIND the camera (bearing only), " & $cRegProjNoCam() &
            " refused for no camera snapshot, " & $cRegProjNoScreen() &
            " refused for no published back-buffer size, " &
            $cRegProjNonFinite() & " refused as NaN/absurd"

proc bindRegion(verbose: bool): bool =
  ## Arms the region as a rider on the existing `PreloaderUI::Update` detour.
  ## Alias-or-attach, exactly as `bindCodeGenProbe` and `bindInspect` do.
  if gRegionSlot >= 0:
    return true
  if not gRegionOn:
    return false
  if not gReady or gDisableDrain:
    return false
  regionEnsureBooted()
  if gDebugUiSlot >= 0:
    gRegionSlot = gDebugUiSlot
  elif gModeTextSlot >= 0:
    gRegionSlot = gModeTextSlot
  elif gInspSlot >= 0:
    gRegionSlot = gInspSlot
  elif gModsSlot >= 0:
    gRegionSlot = gModsSlot
  if gRegionSlot >= 0:
    cRegionSetArmed(1'i32)
    okLog "region: armed as a RIDER on the existing EFT.UI.PreloaderUI::" &
          "Update detour (slot " & $gRegionSlot & ") -- no second detour was " &
          "installed, and " & $cRegionCount() & " participant(s) were " &
          "already registered and waiting"
    return true
  let fn = cDuPreloaderTarget()
  if fn == nil:
    if verbose:
      warn "region: EFT.UI.PreloaderUI::Update did not verify against the " &
           "STARTUP PROLOGUE SNAPSHOT and no other feature holds it, so the " &
           "shared region cannot be armed on this build. Any mod that has " &
           "registered stays registered and simply never fires; " &
           "aowl_region_is_armed() reports 0, which is the state a mod must " &
           "report as UNAVAILABLE rather than as 'nothing to draw'."
    return false
  if attachDrain("EFT.UI.PreloaderUI::Update", fn, cast[Il2CppMethod](0),
                 true, verbose, 17'i32):
    cRegionSetArmed(1'i32)
    okLog "region: armed on EFT.UI.PreloaderUI::Update (per-frame, Unity " &
          "thread) as the FIRST rider on it; " & $cRegionCount() &
          " participant(s) registered"
    return true
  result = false
