/* aowlspt_regproj.h -- THE HOST'S PROJECTOR FOR THE SHARED REGION.
 *
 * `abi/aowlspt_region.h` has always had a projector SEAT and nothing has ever
 * sat in it. `aowl_region_project` / `_project_ex` refuse with
 * AOWL_REGION_REFUSE_NOPROJ, every consumer falls back, and `mods/maps` has
 * been honestly reporting that for as long as it has existed:
 *
 *     projector INCONCLUSIVE -- N indicator(s) drawn as BEARING RINGS; no
 *     projector is installed (nothing calls aowl_region_set_projector), so
 *     they are a bearing and not a projected screen position.
 *
 * This file is the thing that calls it. It is the difference between a radar
 * (a bearing on a ring) and a map (a contact at the pixel it really occupies).
 *
 * ------------------------------------------------------------------------
 * WHAT IT IS MADE OF, AND WHY NOTHING HERE IS NEW
 * ------------------------------------------------------------------------
 *
 * Not one RVA, prologue signature, calling convention or matrix convention is
 * introduced here. Every one of them is ALREADY MEASURED, disassembled and
 * documented in `abi/aowlspt_admin.h`, which this file includes and uses:
 *
 *   UnityEngine.Camera::get_main                    @ 0x5260400  (static)
 *   UnityEngine.Camera::get_worldToCameraMatrix     @ 0x525F2A0  (sret)
 *   UnityEngine.Camera::get_projectionMatrix        @ 0x525F380  (sret)
 *   EFT.CameraControl.CameraManager::get_Instance   @ 0x1263BD0  (static)
 *   CameraManager.<Camera>k__BackingField           @ 0x70       (field read)
 *
 * with 16-byte prologue signatures for each (AOWL_ADM_SIG_*), the recorded
 * measurement that `Camera.main` is NULL for a whole Tarkov raid because the
 * FPS camera carries no "MainCamera" tag, and the CameraManager fallback that
 * `mods/fov` proves. Duplicating any of that here would give the project two
 * answers to one question, which is exactly what `aowlspt_region.h`'s own
 * header text forbids. So: ONE answer, in `aowlspt_admin.h`, USED from here.
 *
 * Because everything in `aowlspt_admin.h` is `static`, "using it" means being
 * compiled into the SAME translation unit -- `host/.../region.nim`, the one TU
 * in the host that defines AOWL_REGION_HOST. That is also what makes reading
 * `aowl_adm_cam_vp` directly legal below, and it is why this header `#error`s
 * if either of its two prerequisites is missing rather than silently compiling
 * against a second copy of the state.
 *
 * ------------------------------------------------------------------------
 * THE SPLIT ACROSS THE FRAME -- and why the draw path stays cheap
 * ------------------------------------------------------------------------
 *
 * `mods/maps` measures its whole draw pass at 6us against a 400us budget, over
 * 216,649/216,649 validated position reads. A projector that called into Unity
 * once per contact would put an il2cpp call inside that loop and destroy it.
 * So the work is split exactly the way `aowlspt_admin.h` already splits it:
 *
 *   ONCE PER FRAME, UNITY THREAD -- `aowl_regproj_tick()`, driven from
 *     `regionFired` immediately before dispatch. It calls
 *     `aowl_admin_cam_sample()`: get the Camera, pull worldToCamera and
 *     projection through their sret getters, multiply into VP, run the
 *     finished-state self-test, publish 16 floats. Three il2cpp calls a frame,
 *     total, no matter how many contacts there are.
 *
 *   PER CONTACT -- `aowl_regproj_project()`, the installed AowlRegionProjFn.
 *     Pure arithmetic over those 16 floats: 12 multiplies, one divide, no
 *     il2cpp call, no allocation, no pointer hop into the game. It cannot
 *     fault on game memory because it never touches any.
 *
 * ------------------------------------------------------------------------
 * THE GUARD (CLAUDE.md 5, rule 3) -- ONE, AND IT IS NOT HERE
 * ------------------------------------------------------------------------
 *
 * `aowl_p_p_seh` has a single thread-local jmp_buf and clears `aowl_seh_active`
 * on the INNER return, so a nested guard does not add protection, it silently
 * removes the outer one. Therefore:
 *
 *   * `aowl_regproj_tick()` DOES open one, around the camera sample, because
 *     it calls into Unity and `regionFired` deliberately holds no guard at that
 *     point. It is entered and exited before `aowl_region_frame` runs -- which
 *     matters, because the dispatcher REFUSES outright if it finds a guard
 *     already active on the thread.
 *
 *   * `aowl_regproj_project()` opens NONE, and that is deliberate rather than
 *     an omission. It is called from inside a participant callback, which the
 *     dispatcher has already wrapped in THE guard. A guard here would nest
 *     inside that one and disarm it for the rest of the callback -- turning a
 *     safety addition into a safety deletion, for a function whose entire body
 *     is arithmetic on our own static float array.
 *
 * ------------------------------------------------------------------------
 * THE BEHIND-CAMERA DECISION
 * ------------------------------------------------------------------------
 *
 * clip = VP * (x,y,z,1). For Unity's perspective projection, clip.w is the
 * camera-space forward distance in metres: positive in front, negative behind.
 * That is the ONLY thing the sign test uses, and it is what is reported through
 * the `depth` out-parameter -- so a test can assert on a measured number rather
 * than on a flag this code could have set by accident.
 *
 * A point BEHIND still gets pixels written, because the perspective divide by a
 * negative w flips both axes and the result is a usable BEARING once the caller
 * is told. That is precisely the contract `aowl_region_project_ex` documents
 * and precisely what `mm_indicator(..., behind, ...)` in `mods/maps` already
 * implements. `aowl_region_project` (the five-argument form) keeps returning 0
 * for those, so an un-updated caller silently becomes correct rather than
 * drawing a confident mirror image.
 *
 * FLAG-GATED, DEFAULT OFF: `regionProjector` in `aowlspt-host.json`. With the
 * flag off nothing is sampled and nothing is installed, projection keeps
 * refusing with REFUSE_NOPROJ, and every consumer keeps its bearing-ring
 * fallback -- which is why turning this on degrades rather than blanks if it
 * goes wrong.
 *
 * SELF-DISABLE. Two independent limits, because they have different fixes:
 * `aowl_admin_cam_sample` already self-disables after AOWL_ADM_CAM_MAXFAIL
 * (240) consecutive refusals, and the tick below UNINSTALLS the projector after
 * AOWL_REGPROJ_MAXFAULT (8) sample calls that actually FAULTED through the
 * guard. Uninstalling is the honest failure: consumers go straight back to
 * bearing rings and say INCONCLUSIVE, instead of drawing marks from a matrix
 * that stopped being refreshed.
 */

#ifndef AOWLSPT_REGPROJ_H
#define AOWLSPT_REGPROJ_H

#ifndef AOWL_REGION_HOST
#error "aowlspt_regproj.h is HOST-ONLY: include it from the one translation unit that defines AOWL_REGION_HOST, after aowlspt_region.h."
#endif
#ifndef AOWLSPT_ADMIN_H
#error "aowlspt_regproj.h needs aowlspt_admin.h included FIRST -- it uses that file's measured camera RVAs and its per-frame view-projection snapshot, and must share its translation unit because that state is static."
#endif

#include <stdint.h>

#define AOWL_REGPROJ_MAXFAULT 8

/* ---- observability -------------------------------------------------- *
 * Every one of these answers a question a single "it did not work" cannot.
 * They are read by the host log line and, through the region, by any mod that
 * wants to explain itself. Counters saturate rather than wrap. */
static int32_t aowl_regproj_installed  = 0;  /* the seat is actually filled   */
static int32_t aowl_regproj_faults     = 0;  /* sample calls that LONGJMPED   */
static int32_t aowl_regproj_offdisabled= 0;  /* uninstalled by the fault cap  */
static int64_t aowl_regproj_ticks      = 0;  /* Unity-thread sample attempts  */
static int64_t aowl_regproj_samples    = 0;  /* ticks that refreshed the VP   */
static int64_t aowl_regproj_calls      = 0;  /* per-contact projections       */
static int64_t aowl_regproj_infront    = 0;
static int64_t aowl_regproj_behind     = 0;
static int64_t aowl_regproj_nocam      = 0;  /* asked before a matrix existed */
static int64_t aowl_regproj_noscreen   = 0;  /* no back-buffer size published */
static int64_t aowl_regproj_nonfinite  = 0;  /* NaN/absurd out of the divide  */

static void aowl_regproj_bump(int64_t* c) { if (*c < 4000000000LL) (*c)++; }

/* ---- THE PROJECTOR -------------------------------------------------- *
 * ANY thread; called per contact from inside a participant callback that the
 * dispatcher has already guarded. See the header: NO guard is opened here.
 *
 * Returns 1 when sx/sy were written at all (in front OR behind), 0 only when
 * there is no usable camera snapshot -- which is the contract AowlRegionProjFn
 * states and which `aowl_region_project_ex` turns into AOWL_REGION_PROJ_NOCAM.
 * `flags` and `depth` are never NULL when the region calls this, but they are
 * defended anyway so a direct caller cannot turn a refusal into a fault. */
static int32_t aowl_regproj_project(float wx, float wy, float wz,
                                    float* sx, float* sy,
                                    int32_t* flags, float* depth) {
    float lx = 0.0f, ly = 0.0f, ld = 0.0f;
    int32_t lf = 0;
    const float* m;
    float cx, cy, cw, den, px, py;
    int32_t w, h;

    if (!sx)    sx = &lx;
    if (!sy)    sy = &ly;
    if (!flags) flags = &lf;
    if (!depth) depth = &ld;
    *sx = 0.0f; *sy = 0.0f; *depth = 0.0f; *flags = 0;

    aowl_regproj_bump(&aowl_regproj_calls);

    /* `aowl_admin_cam_ready` is the ONE predicate: bound, sampled at least
     * once, sampled RECENTLY (< 120 drains ago), and not self-disabled. A
     * matrix that stopped being refreshed is not a matrix, and drawing from a
     * stale one is how a HUD confidently paints last minute's world. */
    if (!aowl_admin_cam_ready()) {
        aowl_regproj_bump(&aowl_regproj_nocam);
        return 0;
    }

    /* Screen size is measured and published by `regionFired` from the game
     * window's client rect. Without it there is no pixel to convert NDC into,
     * and inventing 1920x1080 would put every mark somewhere plausible and
     * wrong. Refuse, and count it separately so the diagnostic can say which
     * of the two refusals happened. */
    if (!aowl_region_screen_known()) {
        aowl_regproj_bump(&aowl_regproj_noscreen);
        return 0;
    }
    w = aowl_region_screen_w();
    h = aowl_region_screen_h();
    if (w <= 0 || h <= 0) {
        aowl_regproj_bump(&aowl_regproj_noscreen);
        return 0;
    }

    /* Unity Matrix4x4 is COLUMN-MAJOR: element (row r, col c) is m[c*4 + r].
     * Getting this backwards produces a finite, non-zero, entirely plausible
     * matrix that throws every contact off-screen -- which is why
     * `aowl_admin_vp_projects` exists and why the snapshot is only published
     * after a point ten metres straight ahead has been shown to land in the
     * middle fifth of the frame. This read is the same convention. */
    m = aowl_adm_cam_vp;
    cx = m[0]*wx + m[4]*wy + m[8] *wz + m[12];
    cy = m[1]*wx + m[5]*wy + m[9] *wz + m[13];
    cw = m[3]*wx + m[7]*wy + m[11]*wz + m[15];

    /* THE DEPTH, and the whole behind-camera decision, in one measured number.
     * Reported before any clamping so a caller sorting by distance -- or a test
     * asserting on the SIGN rather than on the flag -- sees what was actually
     * computed, not what the divide was made safe with. */
    *depth = cw;

    /* The divide is protected at the singular plane only. Clamping the
     * MAGNITUDE and keeping the SIGN is what preserves the mirrored bearing a
     * behind-camera point is supposed to yield; clamping to a positive epsilon
     * instead would quietly convert "directly beside the camera, behind" into
     * "enormously far in front", i.e. a lie with a plausible number. */
    den = cw;
    if (den > -1.0e-4f && den < 1.0e-4f) den = (den < 0.0f) ? -1.0e-4f : 1.0e-4f;

    px = (cx / den * 0.5f + 0.5f) * (float)w;
    py = (1.0f - (cy / den * 0.5f + 0.5f)) * (float)h;   /* origin TOP-LEFT */

    /* NaN or absurd is a REFUSAL, never a coordinate. `x != x` is the NaN test
     * that survives -ffast-math being off and needs no math.h. */
    if (px != px || py != py ||
        px > 1.0e7f || px < -1.0e7f || py > 1.0e7f || py < -1.0e7f) {
        aowl_regproj_bump(&aowl_regproj_nonfinite);
        *depth = 0.0f;
        return 0;
    }

    *sx = px;
    *sy = py;
    if (cw > 0.0f) {
        *flags |= AOWL_REGION_PROJ_INFRONT;
        aowl_regproj_bump(&aowl_regproj_infront);
    } else {
        *flags |= AOWL_REGION_PROJ_BEHIND;
        aowl_regproj_bump(&aowl_regproj_behind);
    }
    /* AOWL_REGION_PROJ_OFFSCREEN is deliberately NOT set here.
     * `aowl_region_project_ex` owns that bit -- it is the only place that knows
     * the published back-buffer rect is real -- and setting it in two places is
     * how the two come to disagree. */
    return 1;
}

/* ---- the once-per-frame sample, behind ONE guard -------------------- */
static void* aowl_regproj_sample_body(void* unused) {
    (void)unused;
    if (aowl_admin_cam_sample()) aowl_regproj_bump(&aowl_regproj_samples);
    return (void*)1;   /* only reached on RETURN; a longjmp yields 0 */
}

/* UNITY THREAD ONLY. Sample the camera, and install the projector the first
 * time there is a matrix worth projecting through.
 *
 * INSTALL ORDER IS DELIBERATE: the seat is filled only AFTER
 * `aowl_admin_cam_ready()` is true, so `aowl_region_project` never has a window
 * in which it returns pixels from a matrix that has not been self-tested. Until
 * then consumers keep refusing and keep saying so. */
static void aowl_regproj_tick(void) {
    void* ok;

    if (aowl_regproj_offdisabled) return;
    aowl_regproj_bump(&aowl_regproj_ticks);

    ok = aowl_p_p_seh((void*)aowl_regproj_sample_body, (void*)0);
    if (ok == 0) {
        if (aowl_regproj_faults < 1000000) aowl_regproj_faults++;
        if (aowl_regproj_faults >= AOWL_REGPROJ_MAXFAULT) {
            /* SELF-DISABLE, and hand the seat back rather than keep it warm.
             * A consumer must see "no projector" and fall back to its bearing
             * ring; leaving a dead projector installed would have it draw from
             * a snapshot that will never be refreshed again. */
            aowl_regproj_offdisabled = 1;
            if (aowl_regproj_installed) {
                aowl_region_set_projector(0);
                aowl_regproj_installed = 0;
            }
            aowl_region_sayf(
                "region projector: DISABLED after %d faulting camera samples "
                "-- the seat has been vacated, so aowl_region_project refuses "
                "again and every consumer falls back to its bearing ring",
                AOWL_REGPROJ_MAXFAULT);
        }
        return;
    }

    if (!aowl_regproj_installed && aowl_admin_cam_ready()) {
        aowl_region_set_projector(aowl_regproj_project);
        aowl_regproj_installed = 1;
    }
}

/* ---- readback ------------------------------------------------------- */
static int32_t aowl_regproj_is_installed(void) { return aowl_regproj_installed; }
static int32_t aowl_regproj_fault_count(void)  { return aowl_regproj_faults; }
static int32_t aowl_regproj_is_disabled(void)  { return aowl_regproj_offdisabled; }
static int64_t aowl_regproj_tick_count(void)   { return aowl_regproj_ticks; }
static int64_t aowl_regproj_sample_count(void) { return aowl_regproj_samples; }
static int64_t aowl_regproj_call_count(void)   { return aowl_regproj_calls; }
static int64_t aowl_regproj_infront_count(void){ return aowl_regproj_infront; }
static int64_t aowl_regproj_behind_count(void) { return aowl_regproj_behind; }
static int64_t aowl_regproj_nocam_count(void)  { return aowl_regproj_nocam; }
static int64_t aowl_regproj_noscreen_count(void) { return aowl_regproj_noscreen; }
static int64_t aowl_regproj_nonfinite_count(void) { return aowl_regproj_nonfinite; }
/* Straight through to `aowlspt_admin.h`, so the host log can say WHICH of the
 * three camera routes came up empty rather than only that none produced one. */
static int32_t aowl_regproj_cam_bind(void)  { return aowl_admin_cam_state(); }
static int32_t aowl_regproj_cam_route(void) { return aowl_admin_cam_route_get(); }
static int32_t aowl_regproj_cam_gen(void)   { return aowl_admin_cam_gen(); }
static int32_t aowl_regproj_cam_stale(void) { return aowl_admin_cam_stale(); }
static int32_t aowl_regproj_cam_selftest_fails(void) { return aowl_admin_cam_selftest_fails(); }

#endif /* AOWLSPT_REGPROJ_H */
