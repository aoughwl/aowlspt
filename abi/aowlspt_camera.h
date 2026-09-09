/* aowlspt_camera.h -- the C half of the host CAMERA API.
 *
 * ===========================================================================
 * WHAT THIS IS
 * ===========================================================================
 *
 * A guarded, byte-verified surface for READING and WRITING the live camera:
 * position, rotation (quaternion and euler), field of view, near/far clip, and
 * the three basis vectors. It is the foundation the free camera in
 * `host/Aowlspt.Host.Il2Cpp/camera.nim` is built on, and it is deliberately a
 * plain API rather than one feature's private plumbing -- mods and the live
 * inspector call the same entry points.
 *
 * ===========================================================================
 * WHAT IS NOT HERE, AND WHY
 * ===========================================================================
 *
 * There is NO camera-acquisition target in this table. `UnityEngine.Camera::
 * get_main` @0x5260400 already lives in `aowlspt_debugui.h`'s verified table
 * (index AOWL_DU_CAMERA_MAIN) and is already the deploy latch's signal S5 in
 * `raidphase.nim`. A second acquisition path would be a second answer to the
 * question "which camera?", and the two would drift. `camera.nim` calls
 * `aowl_du_fn(AOWL_DU_CAMERA_MAIN)` / `aowl_du_call_p_v`, and reaches the
 * camera's Transform through `aowl_du_fn(AOWL_DU_GET_TRANSFORM)`
 * (`UnityEngine.Component::get_transform` @0x73B0F0) -- also already verified
 * there.
 *
 * `EFT.CameraControl.CameraManager::SetFov` @0x1268D20 is NOT here and must not
 * be added. MEASURED by disassembly (and re-stated in `mods/fov/fov.nim`): it
 * opens `mov rdi,[rbx+0x70]; test rdi,rdi; je <epilogue>` and `<Camera>@0x70`
 * reads null on this build, so every call through it is a silent no-op that
 * still returns success. Writing `Camera::set_fieldOfView` on the camera we
 * actually hold is the only route that lands.
 *
 * ===========================================================================
 * THE ABI, MEASURED -- NOT ASSUMED
 * ===========================================================================
 *
 * Every claim below was read out of `GameAssembly.dll` with
 * `tools/il2cpp_resolve.py ... type UnityEngine.Camera|UnityEngine.Transform`
 * plus a 32-56 byte code dump at each RVA. The bytes are quoted in the comment
 * beside each row.
 *
 * A Vector3 is 12 bytes -- neither 1/2/4/8 -- so Win64 cannot pass or return it
 * in a register. The build agrees, and says so twice:
 *
 *   RETURN (hidden buffer / sret).  `Transform::get_position` @0x52B70E0 opens
 *       33 C0           xor  eax,eax
 *       48 8B FA        mov  rdi,rdx        <- `this` arrives in RDX
 *       48 89 01        mov  [rcx],rax      <- 8 bytes of the retbuf at RCX
 *       48 8B D9        mov  rbx,rcx
 *       89 41 08        mov  [rcx+8],eax    <- the 12th byte
 *   i.e. exactly 12 bytes zeroed through RCX before the icall. So the shape is
 *   (retbuf in RCX, this in RDX, MethodInfo* in R8) -- the SAME shape the
 *   already-live `RectTransform::get_rect` sret path uses. `get_eulerAngles`,
 *   `get_forward`, `get_right` and `get_up` open with the identical
 *   `33 C0 / 0F 57 C0 / 48 89 01 / 48 8B FA / 89 41 08`.
 *
 *   ARGUMENT (by address).  `Transform::set_eulerAngles` @0x52B7320 opens
 *       F2 0F 10 02     movsd  xmm0,[rdx]     <- x,y read THROUGH rdx
 *       48 8B D9        mov    rbx,rcx        <- rcx is `this`
 *       ...
 *       F3 0F 10 4A 08  movss  xmm1,[rdx+8]   <- z
 *   RDX is dereferenced, so it is a POINTER to the Vector3, not the value.
 *   `set_position`/`set_rotation` carry RDX through untouched
 *   (`48 8B DA` ... `48 8B D3`) into the icall, which is the same conclusion.
 *
 * A Quaternion is 16 bytes and takes the same two treatments: `get_rotation`
 * @0x52B7F60 zeroes the retbuf with `0F 57 C0 / 0F 11 01` (movups [rcx],xmm0 --
 * all 16 bytes at once), and `set_rotation` passes RDX through by address.
 *
 * A float argument is ordinary: `Camera::set_fieldOfView` @0x525DD30 does
 * `0F 28 F1  movaps xmm6,xmm1`, so the value is in XMM1 with `this` in RCX.
 *
 * This differs from the Vector2 case only because of size: a Vector2 is 8 bytes
 * and comes back PACKED IN RAX (`aowl_du_call_u_p`). Three sizes, three
 * conventions, all measured.
 *
 * ===========================================================================
 * SHAREDNESS
 * ===========================================================================
 *
 * `tools/il2cpp_resolve.py ... shared <rva>` over every row below reports
 * `unique` (owners=1) for ALL FIFTEEN. Nothing here is detoured in any case --
 * this file only CALLS -- but the check was run because 28.3% of by-name
 * lookups land on a shared RVA and "we only call it" is not a reason to skip a
 * measurement that is free.
 *
 * For completeness and because it is the one exception worth stating:
 * `Component::get_transform` @0x73B0F0, which `camera.nim` reuses out of the
 * debugui table, is SHARED (15 owners). Calling a shared address is correct
 * code for the receiver passed; DETOURING one would not be. It is called here
 * and never patched.
 *
 * ===========================================================================
 * SAFETY
 * ===========================================================================
 *
 * `aowl_cam_fn` is a byte-for-byte copy of `aowl_du_fn`'s discipline:
 * GameAssembly.dll must be mapped (through `aowl_cam_ga`, the single
 * never-cached accessor -- and if it is absent the caller must RETRY rather
 * than record a verdict; see the comment on that function), the address must
 * land in COMMITTED
 * EXECUTABLE memory (checked before the memcmp, because a stale RVA on another
 * build can point at an uncommitted page and memcmp there faults), and the
 * prologue is compared against the STARTUP SNAPSHOT (`aowl_pro_verify`) rather
 * than live memory -- so a feature that binds second still verifies instead of
 * reading someone else's trampoline and self-rejecting.
 *
 * Per-target state is recorded once (`aowl_cam_state`), so the verified/rejected
 * counters are counts of DISTINCT TARGETS and not of successful calls -- the
 * defect that once printed "36 of 28 managed targets verified".
 *
 * Every thunk refuses a NULL function pointer and a NULL receiver rather than
 * calling through it, and every sret read rejects a NaN or an absurd magnitude
 * and leaves the output statics alone, because a garbage coordinate that still
 * looks like a number is the failure this whole file exists to stop.
 *
 * This header opens NO `aowl_p_p_seh` guard of its own. `camera.nim` opens
 * exactly one around its whole body; that guard is not re-entrant, so a nested
 * one here would DISARM it.
 * ------------------------------------------------------------------ */

#ifndef AOWLSPT_CAMERA_H
#define AOWLSPT_CAMERA_H

/* Depends on `aowlspt_prologue.h` (aowl_pro_verify) and windows.h, both already
 * included by aowlhost.nim ahead of this file -- the same arrangement
 * aowlspt_debugui.h uses. */

typedef struct AowlCamTarget {
    const char*         name;
    uint32_t            rva;
    const unsigned char sig[16];
    int32_t             siglen;
} AowlCamTarget;

#define AOWL_CAM_GET_FOV        0
#define AOWL_CAM_SET_FOV        1
#define AOWL_CAM_GET_NEAR       2
#define AOWL_CAM_SET_NEAR       3
#define AOWL_CAM_GET_FAR        4
#define AOWL_CAM_SET_FAR        5
#define AOWL_CAM_GET_POSITION   6
#define AOWL_CAM_SET_POSITION   7
#define AOWL_CAM_GET_ROTATION   8
#define AOWL_CAM_SET_ROTATION   9
#define AOWL_CAM_GET_EULER      10
#define AOWL_CAM_SET_EULER      11
#define AOWL_CAM_GET_FORWARD    12
#define AOWL_CAM_GET_RIGHT      13
#define AOWL_CAM_GET_UP         14

static const AowlCamTarget aowl_cam_targets[] = {
    /* ---- UnityEngine.Camera, INSTANCE, image UnityEngine.CoreModule.dll,
     * section `il2cpp`, all rid/arity from the metadata resolve. ---- */

    /* float get_fieldOfView()  rid=426 arity=0 -> (this, MethodInfo*) in RAX/XMM0.
     * Byte-identical to `mods/fov/fov.nim`'s ProCamFieldOfView, which is already
     * bound and firing live -- an independent corroboration of this row. */
    { "UnityEngine.Camera::get_fieldOfView", 0x525DCE0u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0x63,0x4D,0xE7,0x01,
        0x48,0x8B,0xD9 }, 16 },

    /* void set_fieldOfView(float)  rid=427 arity=1 -> (this, XMM1, MethodInfo*).
     * `0F 28 F1 movaps xmm6,xmm1` at +0x15 is the float landing in XMM1.
     * THE WRITE THAT LANDS; CameraManager::SetFov @0x1268D20 does not. */
    { "UnityEngine.Camera::set_fieldOfView", 0x525DD30u,
      { 0x40,0x53,0x48,0x83,0xEC,0x30,0x48,0x8B,0x05,0x1B,0x4D,0xE7,0x01,
        0x48,0x8B,0xD9 }, 16 },

    /* float get_nearClipPlane()  rid=422 / void set_nearClipPlane(float) rid=423 */
    { "UnityEngine.Camera::get_nearClipPlane", 0x525DB80u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0xA3,0x4E,0xE7,0x01,
        0x48,0x8B,0xD9 }, 16 },
    { "UnityEngine.Camera::set_nearClipPlane", 0x525DBD0u,
      { 0x40,0x53,0x48,0x83,0xEC,0x30,0x48,0x8B,0x05,0x5B,0x4E,0xE7,0x01,
        0x48,0x8B,0xD9 }, 16 },

    /* float get_farClipPlane()  rid=424 / void set_farClipPlane(float) rid=425 */
    { "UnityEngine.Camera::get_farClipPlane", 0x525DC30u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0x03,0x4E,0xE7,0x01,
        0x48,0x8B,0xD9 }, 16 },
    { "UnityEngine.Camera::set_farClipPlane", 0x525DC80u,
      { 0x40,0x53,0x48,0x83,0xEC,0x30,0x48,0x8B,0x05,0xBB,0x4D,0xE7,0x01,
        0x48,0x8B,0xD9 }, 16 },

    /* ---- UnityEngine.Transform, INSTANCE ---- */

    /* Vector3 get_position()  rid=3185 -> SRET (retbuf RCX, this RDX, MI* R8).
     * `33 C0 / 48 8B FA / 48 89 01 ... 89 41 08` -- see the header preamble. */
    { "UnityEngine.Transform::get_position", 0x52B70E0u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x33,0xC0,0x48,
        0x8B,0xFA,0x48 }, 16 },
    /* void set_position(Vector3)  rid=3186 -> (this RCX, &value RDX, MI* R8).
     * `48 8B DA` stashes RDX and `48 8B D3` hands it straight to the icall --
     * carried as a POINTER, never loaded as floats. */
    { "UnityEngine.Transform::set_position", 0x52B7150u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,
        0xAF,0xDA,0xE1 }, 16 },

    /* Quaternion get_rotation()  rid=3198 -> SRET, 16 bytes (`0F 11 01`). */
    { "UnityEngine.Transform::get_rotation", 0x52B7F60u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,
        0xB7,0xCC,0xE1 }, 16 },
    /* void set_rotation(Quaternion)  rid=3199 -> (this, &value, MI*). */
    { "UnityEngine.Transform::set_rotation", 0x52B7FD0u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,
        0x4F,0xCC,0xE1 }, 16 },

    /* Vector3 get_eulerAngles()  rid=3189 -> SRET. */
    { "UnityEngine.Transform::get_eulerAngles", 0x52B7280u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x40,0x33,0xC0,0x0F,
        0x57,0xC0,0x48 }, 16 },
    /* void set_eulerAngles(Vector3)  rid=3190 -> (this RCX, &value RDX, MI*).
     * The clearest by-address proof in the whole table: `F2 0F 10 02` reads
     * x,y THROUGH rdx and `F3 0F 10 4A 08` reads z from rdx+8.
     * THE ROTATION WRITE THE FREE CAMERA USES -- yaw/pitch are kept in host
     * state and pushed as (pitch, yaw, 0), so no quaternion math is needed and
     * none is invented. */
    { "UnityEngine.Transform::set_eulerAngles", 0x52B7320u,
      { 0x40,0x53,0x48,0x83,0xEC,0x50,0xF2,0x0F,0x10,0x02,0x48,0x8B,0xD9,
        0xF3,0x0F,0x10 }, 16 },

    /* Vector3 get_forward/get_right/get_up  rid=3196/3193/3194 -> SRET.
     * All three share one prologue (bigger frame than get_position, same
     * `33 C0 / 0F 57 C0 / 48 89 01 / 48 8B FA / 89 41 08` sret shape), which is
     * why the free camera can move along the camera's OWN basis rather than
     * doing trigonometry the host has no verified math for. */
    { "UnityEngine.Transform::get_forward", 0x52B7BC0u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x81,0xEC,0xD0,0x00,0x00,0x00,
        0x33,0xC0,0x0F }, 16 },
    { "UnityEngine.Transform::get_right", 0x52B75A0u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x81,0xEC,0xD0,0x00,0x00,0x00,
        0x33,0xC0,0x0F }, 16 },
    { "UnityEngine.Transform::get_up", 0x52B7820u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x81,0xEC,0xD0,0x00,0x00,0x00,
        0x33,0xC0,0x0F }, 16 }
};

#define AOWL_CAM_TARGET_COUNT \
    ((int32_t)(sizeof(aowl_cam_targets) / sizeof(aowl_cam_targets[0])))

static int32_t       aowl_cam_verified = 0;
static int32_t       aowl_cam_rejected = 0;
/* Verifies refused because the SHARED prologue snapshot table was full --
 * our capacity limit, not a client change. Kept apart from `rejected` so a
 * refusal can never be reported as "this build changed". */
static int32_t aowl_cam_profull = 0;
/* 0 untried, 1 verified, 2 rejected -- one entry per TARGET, so the counters
 * above cannot climb past AOWL_CAM_TARGET_COUNT however often we resolve. */
static unsigned char aowl_cam_state[AOWL_CAM_TARGET_COUNT];
/* Why the LAST failed resolve failed: 0 ok, 1 no module, 2 VirtualQuery,
 * 3 not committed, 4 not executable, 5 prologue mismatch, 6 bad index. A
 * feature that declines must say which of the six happened. */
static int32_t       aowl_cam_last_reason = 0;
/* Resolves that found no GameAssembly.dll at all. NOT rejections: see below. */
static int32_t       aowl_cam_waits = 0;

/* THE ONE ACQUISITION, and it is deliberately not cached.
 *
 * MEASURED 2026-08-31, from a live host log: `camBind` ran at host-config time
 * and every one of the 15 targets came back with reason code 1 -- `!ga` -- while
 * a few lines later `mods/fov` byte-verified 0x525DCE0 and 0x525DD30, the very
 * same addresses, successfully. There was never a byte mismatch and never a
 * wrong RVA: the host calls in at DLL-attach and IL2CPP does not map
 * GameAssembly.dll until ~1s later, so `GetModuleHandleA` correctly returned
 * NULL, and the bind then REPORTED that as a verdict about the build. FOV
 * "worked" only because it binds later.
 *
 * The rule this encodes, and the reason there is a named function here rather
 * than an inline call at each use site: a handle that is absent is a fact about
 * WHEN we asked, never a fact about the build, so it is never latched and never
 * remembered. `aowl_pro_capture` needs the module for exactly the same reason --
 * the startup snapshot cannot be taken before the bytes are mapped -- so a
 * caller that gets 0 from `aowl_cam_module_ready` must RETRY, not conclude.
 * `aowl_cam_state` is likewise only ever latched on a genuine prologue
 * mismatch, so a deferred bind cannot poison the verified/rejected counters. */
static HMODULE aowl_cam_ga(void) {
    return GetModuleHandleA("GameAssembly.dll");
}
static int32_t aowl_cam_module_ready(void) { return aowl_cam_ga() ? 1 : 0; }
static int32_t aowl_cam_wait_count(void)   { return aowl_cam_waits; }

static void* aowl_cam_fn(int32_t i) {
    HMODULE ga;
    const AowlCamTarget* t;
    unsigned char* p;
    MEMORY_BASIC_INFORMATION mbi;
    if (i < 0 || i >= AOWL_CAM_TARGET_COUNT) { aowl_cam_last_reason = 6; return NULL; }
    ga = aowl_cam_ga();
    if (!ga) { aowl_cam_waits++; aowl_cam_last_reason = 1; return NULL; }
    t = &aowl_cam_targets[i];
    p = (unsigned char*)ga + t->rva;
    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) { aowl_cam_last_reason = 2; return NULL; }
    if (mbi.State != MEM_COMMIT) { aowl_cam_last_reason = 3; return NULL; }
    if (!(mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY))) {
        aowl_cam_last_reason = 4;
        return NULL;
    }
    /* STARTUP SNAPSHOT, not live memory. */
    if (t->siglen > 0 && !aowl_pro_verify(t->rva, t->sig, t->siglen)) {
        /* TWO DIFFERENT FAILURES, TWO DIFFERENT REASONS. A verify that failed
         * because OUR snapshot table had no free row is not evidence about the
         * client at all, so it must not be reported as a signature mismatch
         * and must NOT latch this target as permanently rejected. */
        if (aowl_pro_last_was_table_full()) {
            aowl_cam_profull++;
            aowl_cam_last_reason = 9;   /* snapshot table full -- ours */
            return NULL;
        }
        if (aowl_cam_state[i] == 0) { aowl_cam_state[i] = 2; aowl_cam_rejected++; }
        aowl_cam_last_reason = 5;
        return NULL;
    }
    if (aowl_cam_state[i] == 0) { aowl_cam_state[i] = 1; aowl_cam_verified++; }
    aowl_cam_last_reason = 0;
    return (void*)p;
}

static const char* aowl_cam_name(int32_t i) {
    if (i < 0 || i >= AOWL_CAM_TARGET_COUNT) return "";
    return aowl_cam_targets[i].name;
}
static uint32_t aowl_cam_rva(int32_t i) {
    if (i < 0 || i >= AOWL_CAM_TARGET_COUNT) return 0u;
    return aowl_cam_targets[i].rva;
}
static int32_t aowl_cam_target_count(void) { return AOWL_CAM_TARGET_COUNT; }
static int32_t aowl_cam_ok_count(void)     { return aowl_cam_verified; }
static int32_t aowl_cam_bad_count(void)    { return aowl_cam_rejected; }
static int32_t aowl_cam_reason(void)       { return aowl_cam_last_reason; }
static int32_t aowl_cam_profull_count(void){ return aowl_cam_profull; }
/* Human-readable form of the last reason, so a refusal in the log names the
 * cause instead of a bare integer the reader has to look up in this file. */
static const char* aowl_cam_reason_text(void) {
    switch (aowl_cam_last_reason) {
        case 0: return "ok";
        case 1: return "GameAssembly.dll is not mapped yet (RETRYABLE -- not a "
                       "statement about the build)";
        case 2: return "VirtualQuery failed on the target address";
        case 3: return "the target page is not committed";
        case 4: return "the target page is not executable";
        case 5: return "the 16-byte prologue did not match the startup snapshot";
        case 6: return "target index out of range";
        default: return "unknown";
    }
}

/* ------------------------------------------------------------------ *
 * The thunks.
 *
 * Each one is a separate typedef because the SHAPES genuinely differ, and a
 * call through the wrong shape is exactly the defect that once handed
 * `Transform::set_localPosition` a NULL Vector3 pointer and faulted inside a
 * perfectly valid, byte-verified function. Every one passes the hidden trailing
 * `MethodInfo*` explicitly as a real parameter of the callee type rather than
 * hoping a register happens to be zero.
 * ------------------------------------------------------------------ */

/* INSTANCE, 0 args -> float.  (this, MethodInfo*) */
typedef float (*AowlCam_F_P)(void*, void*);
static double aowl_cam_get_f(void* fn, void* self) {
    float v;
    if (!fn || !self) return 0.0;
    v = ((AowlCam_F_P)fn)(self, NULL);
    if (v != v) return 0.0;                 /* NaN is never an answer */
    return (double)v;
}
/* Did the float getter give a usable number? Separate from the value, because
 * 0.0 is both a legal FOV-ish reading and this thunk's refusal value, and a
 * refusal that is indistinguishable from a measurement is a check that cannot
 * fail. */
static int32_t aowl_cam_get_f_ok(void* fn, void* self) {
    float v;
    if (!fn || !self) return 0;
    v = ((AowlCam_F_P)fn)(self, NULL);
    if (v != v) return 0;
    if (v > 1.0e9f || v < -1.0e9f) return 0;
    return 1;
}

/* INSTANCE, one float -> void.  (this RCX, value XMM1, MethodInfo* R8) */
typedef void (*AowlCam_V_PF)(void*, float, void*);
static int32_t aowl_cam_set_f(void* fn, void* self, double v) {
    if (!fn || !self) return 0;
    if (v != v) return 0;
    if (v > 1.0e9 || v < -1.0e9) return 0;
    ((AowlCam_V_PF)fn)(self, (float)v, NULL);
    return 1;
}

/* INSTANCE, 0 args -> a struct > 8 bytes.  (retbuf RCX, this RDX, MI* R8)
 * Vector3 (nfloats 3) and Quaternion (nfloats 4) both. Results land in statics
 * because nimony cannot hand out the address of an array element; the host is
 * single-threaded on this path. */
typedef void (*AowlCam_SRET_P)(void*, void*, void*);
static double aowl_cam_sret_out[4] = { 0.0, 0.0, 0.0, 0.0 };
static int32_t aowl_cam_get_v(void* fn, void* self, int32_t nfloats) {
    float ret[4];
    int i;
    if (!fn || !self) return 0;
    if (nfloats < 1 || nfloats > 4) return 0;
    for (i = 0; i < 4; i++) ret[i] = 0.0f;
    ((AowlCam_SRET_P)fn)((void*)ret, self, NULL);
    for (i = 0; i < nfloats; i++) {
        float v = ret[i];
        if (v != v) return 0;
        /* A world coordinate in Tarkov is a few hundred metres. 1e9 is not a
         * preference, it is a refusal: a half-torn-down transform must not feed
         * a plausible-looking number into a movement decision. */
        if (v > 1.0e9f || v < -1.0e9f) return 0;
    }
    for (i = 0; i < nfloats; i++) aowl_cam_sret_out[i] = (double)ret[i];
    return 1;
}
static double aowl_cam_v0(void) { return aowl_cam_sret_out[0]; }
static double aowl_cam_v1(void) { return aowl_cam_sret_out[1]; }
static double aowl_cam_v2(void) { return aowl_cam_sret_out[2]; }
static double aowl_cam_v3(void) { return aowl_cam_sret_out[3]; }

/* INSTANCE, one Vector3/Quaternion BY ADDRESS -> void. (this, &value, MI*)
 * `nfloats` picks 12 vs 16 bytes; the buffer is 4 floats either way so the
 * callee can never read past it. */
typedef void (*AowlCam_V_PPTR)(void*, void*, void*);
static int32_t aowl_cam_set_v(void* fn, void* self,
                              double x, double y, double z, double w) {
    float v[4];
    if (!fn || !self) return 0;
    if (x != x || y != y || z != z || w != w) return 0;
    if (x >  1.0e9 || y >  1.0e9 || z >  1.0e9 || w >  1.0e9) return 0;
    if (x < -1.0e9 || y < -1.0e9 || z < -1.0e9 || w < -1.0e9) return 0;
    v[0] = (float)x; v[1] = (float)y; v[2] = (float)z; v[3] = (float)w;
    ((AowlCam_V_PPTR)fn)(self, (void*)v, NULL);
    return 1;
}

/* ------------------------------------------------------------------ *
 * Input.
 *
 * `GetAsyncKeyState` for the HELD state, because a free camera needs "is W down
 * right now", not an edge. This is a plain user32 call with no managed state
 * behind it, so it is safe from any thread and cannot fault. The EDGE detector
 * for the toggle key is `aowl_du_key_edge` in aowlspt_debugui.h -- not
 * duplicated here, so the two cannot disagree about what one press means.
 * Foreground gating is `aowl_du_foreground`, likewise reused.
 * ------------------------------------------------------------------ */
static int32_t aowl_cam_key_down(int32_t vk) {
    if (vk <= 0 || vk > 0xFF) return 0;
    return (GetAsyncKeyState(vk) & 0x8000) ? 1 : 0;
}

#endif /* AOWLSPT_CAMERA_H */
