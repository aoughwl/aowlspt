/* aowlspt_debugui.h -- the C half of the in-game, UNITY-NATIVE debug overlay:
 * a Minecraft-F3-style info panel and in-world markers over AI bots.
 *
 * ===========================================================================
 * WHY THIS IS NOT A D3D OVERLAY
 * ===========================================================================
 *
 * The host already HAS a D3D11 Present overlay (`aowlspt_overlay.h`), and it is
 * the wrong tool for this job: it draws into the swapchain after Unity is done,
 * so it knows nothing about the game's canvas, its scaling, its fonts, or --
 * decisively -- where a bot is on screen. What is wanted here is a panel the
 * GAME renders: real Unity UI, in the real canvas, in the game's own font,
 * scaling with the game's own resolution.
 *
 * Post-1.0 that used to be impossible, because IL2CPP reflection on this build
 * is dead (`il2cpp_object_get_class`, `il2cpp_class_get_name`, `il2cpp_value_box`
 * and field iteration all FAULT -- the P2-P5 verdict). It stopped being
 * impossible when `abi/aowlspt_invoke2.h` established that IL2CPP AOT-compiles
 * every managed method into an ordinary native function which can be CALLED
 * DIRECTLY at its RVA, with a plain Win64 convention plus a hidden trailing
 * `const MethodInfo*`. This header is the first real FEATURE built on that.
 *
 * ===========================================================================
 * THE UI-CREATION PATH: CLONE, NOT NEW
 * ===========================================================================
 *
 * `il2cpp_object_new` + `GameObject::.ctor` + `AddComponent<T>` is a chain of
 * three things, two of which are unproven on this build (the generic
 * `MethodInfo*` for `AddComponent<T>` is read from a LAZY .data cache slot that
 * is NULL until TMP's own default-control code has run, and the
 * `AddComponent(Type)` route needs `il2cpp_class_get_type` /
 * `il2cpp_type_get_object` -- reflection surface).
 *
 * `UnityEngine.Object::Instantiate(Object)` @ 0x52ADBE0 is ONE static call with
 * ONE reference argument, needs neither a `System.Type` nor a generic
 * `MethodInfo*`, and hands back a live clone of whatever it was given. So every
 * label this overlay draws is a CLONE of a label the game already built, and
 * the feature has no dependency on object creation at all.
 *
 * The clone anchor is deliberately the most persistent label in the client:
 *
 *     EFT.UI.PreloaderUI                     (the root, whole-session UI)
 *       + 0x020  _alphaVersionLabel  -> EFT.UI.LocalizedText
 *                  + 0x078  _labels  -> List<TMPro.TextMeshProUGUI>
 *                             + 0x010 _items -> TMP[]  + 0x020 elems -> [0]
 *
 * -- i.e. the bottom-left version label. It exists in the menu AND in a raid,
 * it is a TextMeshProUGUI, and the host has ALREADY proven live that it can
 * write that component's text by raw field store (the version brand). Cloning
 * the COMPONENT rather than its GameObject is deliberate: Unity clones the whole
 * GameObject either way, but cloning the component hands back the CLONED
 * COMPONENT, which is the pointer the raw `m_text` write needs. Cloning the
 * GameObject would hand back a GameObject and leave us needing `GetComponent`,
 * which needs a Type again.
 *
 * Parenting: `Transform::get_root` on the anchor's transform reaches the Canvas
 * root, whose RectTransform spans the screen -- so a corner anchor means a
 * SCREEN corner, which is what a layout config expects. Then
 * `TMP_DefaultControls::SetParentAndAlign(cloneGO, rootGO)` (static, two
 * GameObjects, no Type, no generic) puts the clone in the live hierarchy.
 *
 * ===========================================================================
 * THE TARGETS ADDED HERE, AND HOW THEY WERE RESOLVED
 * ===========================================================================
 *
 * Every RVA below is for `GameAssembly.dll` imagebase 0x180000000, build
 * 1.1.0.1.46777, taken from the 185k-entry name->RVA map produced by
 * `tools/il2cpp_resolve.py`, and each one was then DISASSEMBLED to confirm its
 * argument shape before being written down. The shapes are not guesses:
 *
 *  * `UnityEngine.Camera::get_main` @ 0x5260400 -- STATIC, 0 args -> Camera.
 *      5260400: sub rsp,0x28 ; mov rax,[rip+..] ; test rax,rax ; jne ..
 *      5260428: add rsp,0x28 ; jmp rax          <- lazy icall thunk, RCX unread
 *    Identical shape to `Screen::get_width`, which the invoke2 ladder already
 *    calls. RCX carries only the hidden MethodInfo*, and the body never reads it.
 *
 *  * `UnityEngine.Camera::WorldToScreenPoint(Vector3)` @ 0x525F940 -- INSTANCE,
 *    one 12-byte struct argument and a 12-byte struct return, so Win64 puts the
 *    return buffer FIRST and passes the argument BY ADDRESS:
 *      525f940: movsd xmm0,[r8]        <- R8 = &position   (arg0, by address)
 *      525f951: mov [rcx],rax          <- RCX = &retbuf    (sret, hidden arg)
 *      525f954: mov rdi,rdx            <- RDX = this       (the Camera)
 *      525f99f: mov r8d,2              <- eye = Mono, hardcoded: this IS the
 *      525f9ad: call rax                  one-argument overload
 *    so the call is (retbuf, this, &pos, MethodInfo*) and R9 (the MethodInfo) is
 *    used as scratch by the body -- never read. NOTE the sibling at 0x525F700 is
 *    the TWO-argument overload (`..., MonoOrStereoscopicEye`), whose R9 is the
 *    EYE and whose MethodInfo goes on the stack; calling that one by mistake
 *    would pass a garbage eye, which is exactly why both were disassembled.
 *
 *  * `UnityEngine.RectTransform::set_anchoredPosition` @ 0x52B5490,
 *    `set_anchorMin` @ 0x52B5310, `set_anchorMax` @ 0x52B53D0,
 *    `set_pivot` @ 0x52B5610 -- INSTANCE, one Vector2. A Vector2 is EIGHT bytes,
 *    so Win64 passes it BY VALUE in an integer register, and all four bodies
 *    agree:
 *      52b549d: mov rbx,rcx            <- RCX = this
 *      52b54a0: mov [rsp+0x20],rdx     <- RDX = the Vector2, packed
 *      52b54c2: lea rdx,[rsp+0x20]     <- spilled, then passed by address to
 *      52b54ca: call rax                  the icall
 *    so the call is (this, <two floats packed into one uint64>, MethodInfo*).
 *    `aowl_du_call_setvec2` builds that uint64 with memcpy rather than a union
 *    cast, so it is well-defined and endianness-explicit: x in the LOW half.
 *
 *  * `UnityEngine.Component::get_transform` @ 0x73B0F0 and
 *    `UnityEngine.Transform::get_root` @ 0x52B9C50 -- INSTANCE, 0 args ->
 *    reference. The exact shape of `Component::get_gameObject` @ 0x11F57E0 that
 *    invoke2 STEP 1 already proved live, so they reuse its thunk.
 *
 *  * `EFT.UI.PreloaderUI::Update` @ 0x1569F20 -- the per-frame Unity-thread
 *    anchor this whole feature hangs off. PreloaderUI is the ROOT UI
 *    MonoBehaviour: it owns the version label, the FPS counter, the console and
 *    the notifier, it is alive from the preloader through the menu and through a
 *    raid, and its `Update` is an ordinary MonoBehaviour tick. Its prologue is
 *    `mov rax,rsp ; mov [rax+0x10],rbx ; mov [rax+0x20],rsi ; mov [rax+8],rcx ;
 *    push rdi` -- sixteen bytes with no RIP-relative operand, so the detour
 *    engine's copier relocates it cleanly. RCX = the live PreloaderUI, which is
 *    simultaneously the frame tick AND the clone anchor.
 *
 *    It is used in preference to `TarkovApplication::Update` @ 0x977B10
 *    deliberately: that one has a live crash in its history (see the host
 *    internals note), and it does not hand us a UI object.
 *
 * ===========================================================================
 * FIELD OFFSETS
 * ===========================================================================
 *
 * Resolved OFFLINE from `Il2CppMetadataRegistration.fieldOffsets` in
 * GameAssembly.dll indexed by type, against the decrypted global-metadata --
 * the same technique that produced the botdiag and settings-UI offsets, and
 * self-checked on `System.String` (`_stringLength` @ 0x10, `_firstChar` @ 0x14)
 * before anything else was believed. NOT from live `il2cpp_field_get_offset`,
 * which is part of the faulting reflection API.
 *
 * ===========================================================================
 * SAFETY
 * ===========================================================================
 *
 * Nothing here calls anything on its own; it is a table, a set of thunks and a
 * set of guarded stores. `host/Aowlspt.Host.Il2Cpp/debugui.nim` drives it, from
 * inside the PreloaderUI::Update detour (Unity thread), with the entire body
 * under the `aowl_p_p_seh` VEH/setjmp guard, every pointer hop
 * `aowl_is_readable`-guarded, every iteration capped, and both features
 * flag-gated default-OFF. A fault is caught, logged and skipped; it can never
 * take the client down.
 */
#ifndef AOWLSPT_DEBUGUI_H
#define AOWLSPT_DEBUGUI_H

#include <windows.h>
#include <stdint.h>
#include <string.h>

/* ------------------------------------------------------------------ *
 * Field offsets (offline-resolved, single source of truth)
 * ------------------------------------------------------------------ */

/* EFT.UI.PreloaderUI */
#define AOWL_DU_PRE_VERSIONLABEL 0x020  /* _alphaVersionLabel -> LocalizedText */

/* EFT.UI.LocalizedText -- shared with aowlspt_settingsui.h's LOCTEXT_LIST. */
#define AOWL_DU_LOC_LABELS       0x078  /* _labels -> List<TextMeshProUGUI>   */

/* System.Collections.Generic.List<T> and the T[] behind it. */
#define AOWL_DU_LIST_ITEMS       0x010
#define AOWL_DU_LIST_SIZE        0x018
#define AOWL_DU_ARR_ELEMS        0x020

/* TMPro.TMP_Text -- the base of TextMeshProUGUI. */
#define AOWL_DU_TMP_TEXT         0x0E0  /* m_text -> System.String            */
#define AOWL_DU_TMP_FONTSIZE     0x1EC  /* m_fontSize -> float                */
#define AOWL_DU_TMP_FONTCOLOR    0x150  /* m_fontColor -> Color (4 floats)    */
#define AOWL_DU_TMP_DIRTY        0x378  /* m_havePropertiesChanged -> bool    */
#define AOWL_DU_TMP_RECT         0x388  /* m_rectTransform -> RectTransform   */

/* EFT.MovementContext -- the player/bot pose. PreviousPosition matches
 * aowlspt_botdiag.h; _rotation is a Vector2 (yaw at +0, pitch at +4). */
#define AOWL_DU_MC_PREVPOS       0x370
#define AOWL_DU_MC_ROTATION      0x0C0

/* EFT.GameWorld */
#define AOWL_DU_GW_LOCATIONID    0x0E8  /* <LocationId>k__BackingField String */

static int32_t aowl_du_off_pre_versionlabel(void){ return AOWL_DU_PRE_VERSIONLABEL; }
static int32_t aowl_du_off_loc_labels(void)      { return AOWL_DU_LOC_LABELS; }
static int32_t aowl_du_off_list_items(void)      { return AOWL_DU_LIST_ITEMS; }
static int32_t aowl_du_off_list_size(void)       { return AOWL_DU_LIST_SIZE; }
static int32_t aowl_du_off_arr_elems(void)       { return AOWL_DU_ARR_ELEMS; }
static int32_t aowl_du_off_tmp_text(void)        { return AOWL_DU_TMP_TEXT; }
static int32_t aowl_du_off_tmp_fontsize(void)    { return AOWL_DU_TMP_FONTSIZE; }
static int32_t aowl_du_off_tmp_fontcolor(void)   { return AOWL_DU_TMP_FONTCOLOR; }
static int32_t aowl_du_off_tmp_dirty(void)       { return AOWL_DU_TMP_DIRTY; }
static int32_t aowl_du_off_tmp_rect(void)        { return AOWL_DU_TMP_RECT; }
static int32_t aowl_du_off_mc_prevpos(void)      { return AOWL_DU_MC_PREVPOS; }
static int32_t aowl_du_off_mc_rotation(void)     { return AOWL_DU_MC_ROTATION; }
static int32_t aowl_du_off_gw_locationid(void)   { return AOWL_DU_GW_LOCATIONID; }

/* ------------------------------------------------------------------ *
 * The managed-target table
 *
 * Same discipline as `aowl_mi2_fn`: the RVA must land in COMMITTED EXECUTABLE
 * memory before its prologue is compared, because a stale RVA on another build
 * can point at an uncommitted page and `memcmp` there faults. On any build whose
 * bytes differ the lookup returns NULL and the step that needs it simply does
 * not run -- which for this feature means an empty panel, never a crash.
 * ------------------------------------------------------------------ */

typedef struct AowlDuTarget {
    const char*         name;
    uint32_t            rva;
    const unsigned char sig[16];
    int32_t             siglen;
} AowlDuTarget;

#define AOWL_DU_CAMERA_MAIN      0
#define AOWL_DU_WORLD_TO_SCREEN  1
#define AOWL_DU_SET_ANCHOREDPOS  2
#define AOWL_DU_SET_ANCHORMIN    3
#define AOWL_DU_SET_ANCHORMAX    4
#define AOWL_DU_SET_PIVOT        5
#define AOWL_DU_GET_TRANSFORM    6
#define AOWL_DU_GET_ROOT         7

static const AowlDuTarget aowl_du_targets[] = {
    /* UnityEngine.Camera::get_main -- STATIC, 0 args -> Camera. */
    { "UnityEngine.Camera::get_main", 0x5260400u,
      { 0x48,0x83,0xEC,0x28,0x48,0x8B,0x05,0xD5,0x27,0xE7,0x01,0x48,0x85,
        0xC0,0x75,0x18 }, 16 },

    /* UnityEngine.Camera::WorldToScreenPoint(Vector3) -- INSTANCE, sret.
     * (retbuf, this, &position, MethodInfo*). The ONE-argument overload; the
     * two-argument one is the different function at 0x525F700. */
    { "UnityEngine.Camera::WorldToScreenPoint(Vector3)", 0x525F940u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x40,0xF2,0x41,0x0F,
        0x10,0x00,0x33 }, 16 },

    /* UnityEngine.RectTransform::set_anchoredPosition -- INSTANCE, Vector2 in
     * RDX by value. This is what positions every label the overlay draws. */
    { "UnityEngine.RectTransform::set_anchoredPosition", 0x52B5490u,
      { 0x40,0x53,0x48,0x83,0xEC,0x30,0x48,0x8B,0x05,0xC3,0xF6,0xE1,0x01,
        0x48,0x8B,0xD9 }, 16 },

    /* set_anchorMin / set_anchorMax / set_pivot -- the same shape. Together
     * they turn "top-left" into a real screen corner: anchorMin == anchorMax
     * collapses the rect to a point on the parent, and the pivot decides which
     * corner of the label sits on it. */
    { "UnityEngine.RectTransform::set_anchorMin", 0x52B5310u,
      { 0x40,0x53,0x48,0x83,0xEC,0x30,0x48,0x8B,0x05,0x23,0xF8,0xE1,0x01,
        0x48,0x8B,0xD9 }, 16 },
    { "UnityEngine.RectTransform::set_anchorMax", 0x52B53D0u,
      { 0x40,0x53,0x48,0x83,0xEC,0x30,0x48,0x8B,0x05,0x73,0xF7,0xE1,0x01,
        0x48,0x8B,0xD9 }, 16 },
    { "UnityEngine.RectTransform::set_pivot", 0x52B5610u,
      { 0x40,0x53,0x48,0x83,0xEC,0x30,0x48,0x8B,0x05,0x63,0xF5,0xE1,0x01,
        0x48,0x8B,0xD9 }, 16 },

    /* UnityEngine.Component::get_transform -- INSTANCE, 0 args -> Transform.
     * The fallback for a TMP whose cached `m_rectTransform` is still null. */
    { "UnityEngine.Component::get_transform", 0x73B0F0u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0xE3,0x93,0x99,0x06,
        0x48,0x8B,0xD9 }, 16 },

    /* UnityEngine.Transform::get_root -- INSTANCE, 0 args -> Transform. The
     * hop that turns the anchor label into the CANVAS ROOT, so a corner anchor
     * is a screen corner rather than a corner of the version label. */
    { "UnityEngine.Transform::get_root", 0x52B9C50u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0x4B,0xAF,0xE1,0x01,
        0x48,0x8B,0xD9 }, 16 },
};

#define AOWL_DU_TARGET_COUNT \
    ((int32_t)(sizeof(aowl_du_targets) / sizeof(aowl_du_targets[0])))

static int32_t aowl_du_verified = 0;
static int32_t aowl_du_rejected = 0;

static void* aowl_du_fn(int32_t i) {
    HMODULE ga;
    const AowlDuTarget* t;
    unsigned char* p;
    MEMORY_BASIC_INFORMATION mbi;
    if (i < 0 || i >= AOWL_DU_TARGET_COUNT) return NULL;
    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) return NULL;
    t = &aowl_du_targets[i];
    p = (unsigned char*)ga + t->rva;
    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return NULL;
    if (mbi.State != MEM_COMMIT) return NULL;
    if (!(mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)))
        return NULL;
    if (t->siglen > 0 && memcmp(p, t->sig, (size_t)t->siglen) != 0) {
        aowl_du_rejected++;
        return NULL;
    }
    aowl_du_verified++;
    return (void*)p;
}
static const char* aowl_du_name(int32_t i) {
    if (i < 0 || i >= AOWL_DU_TARGET_COUNT) return "";
    return aowl_du_targets[i].name;
}
static uint32_t aowl_du_rva(int32_t i) {
    if (i < 0 || i >= AOWL_DU_TARGET_COUNT) return 0u;
    return aowl_du_targets[i].rva;
}
static int32_t aowl_du_target_count(void) { return AOWL_DU_TARGET_COUNT; }
static int32_t aowl_du_ok_count(void)     { return aowl_du_verified; }
static int32_t aowl_du_bad_count(void)    { return aowl_du_rejected; }

/* ------------------------------------------------------------------ *
 * The detour target: EFT.UI.PreloaderUI::Update
 *
 * A separate table of one, verified the same way, because this is the only
 * thing here that gets a JUMP written into it rather than a call.
 * ------------------------------------------------------------------ */

#define AOWL_DU_PRELOADER_UPDATE_RVA 0x1569F20u

static const unsigned char aowl_du_preloader_update_sig[16] = {
    0x48,0x8B,0xC4,             /* mov  rax, rsp            */
    0x48,0x89,0x58,0x10,        /* mov  [rax+0x10], rbx     */
    0x48,0x89,0x70,0x20,        /* mov  [rax+0x20], rsi     */
    0x48,0x89,0x48,0x08,        /* mov  [rax+0x08], rcx     */
    0x57                        /* push rdi                 */
};

static void* aowl_du_preloader_update_target(void) {
    HMODULE ga;
    unsigned char* p;
    MEMORY_BASIC_INFORMATION mbi;
    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) return NULL;
    p = (unsigned char*)ga + AOWL_DU_PRELOADER_UPDATE_RVA;
    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return NULL;
    if (mbi.State != MEM_COMMIT) return NULL;
    if (!(mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)))
        return NULL;
    if (memcmp(p, aowl_du_preloader_update_sig,
               sizeof(aowl_du_preloader_update_sig)) != 0)
        return NULL;
    return (void*)p;
}
static uint32_t aowl_du_preloader_update_rva(void) {
    return AOWL_DU_PRELOADER_UPDATE_RVA;
}

/* ------------------------------------------------------------------ *
 * The call thunks
 *
 * One per SHAPE. As in `aowlspt_invoke2.h`, the hidden `MethodInfo*` is a REAL
 * parameter of every callee type rather than something hoped to be zero in a
 * register, and every thunk refuses a NULL function pointer rather than calling
 * through it.
 * ------------------------------------------------------------------ */

/* STATIC, 0 declared args -> reference.  (MethodInfo*) */
typedef void* (*AowlDu_P_V)(void*);
static void* aowl_du_call_p_v(void* fn) {
    if (!fn) return NULL;
    return ((AowlDu_P_V)fn)(NULL);
}

/* INSTANCE, 0 declared args -> reference.  (this, MethodInfo*) -- the shape
 * `Component::get_transform` and `Transform::get_root` share with the already
 * proven `Component::get_gameObject`. */
typedef void* (*AowlDu_P_P)(void*, void*);
static void* aowl_du_call_p_p(void* fn, void* self) {
    if (!fn || !self) return NULL;
    return ((AowlDu_P_P)fn)(self, NULL);
}

/* INSTANCE, one Vector2 by value -> void.  (this, packed, MethodInfo*)
 *
 * The Vector2 is two floats in ONE integer register, x in the low half. It is
 * assembled with memcpy into a uint64 rather than by punning a pointer, so it
 * is strict-aliasing-clean and the byte order is stated rather than assumed. */
typedef void (*AowlDu_V_PU)(void*, uint64_t, void*);
static void aowl_du_call_setvec2(void* fn, void* self, double x, double y) {
    uint64_t packed = 0;
    float f[2];
    if (!fn || !self) return;
    f[0] = (float)x;
    f[1] = (float)y;
    memcpy(&packed, f, sizeof(packed));
    ((AowlDu_V_PU)fn)(self, packed, NULL);
}

/* INSTANCE, one Vector3 by address, Vector3 return by hidden buffer.
 *   (retbuf, this, &position, MethodInfo*)
 *
 * The result is left in three C statics and read back with
 * `aowl_du_screen_x/y/z`, rather than through an out-parameter: nimony cannot
 * take the address of an array element to hand out as a `ptr`, and a static
 * triple is unambiguous where a marshalled pointer would be one more thing that
 * has to be right on a per-frame path. The overlay is single-threaded (one
 * Unity-thread detour), so there is no sharing question.
 *
 * Returns 1 when the call was made and the result is finite, 0 otherwise -- a
 * NaN or an infinity here means the camera matrix was not ready, and drawing a
 * marker at NaN would leave a label parked at a garbage screen position.
 *
 * The screen point Unity returns has its ORIGIN AT THE BOTTOM-LEFT and a `z`
 * that is the distance in front of the camera; `z <= 0` means the point is
 * BEHIND the camera, where x/y are still finite but meaningless. That test is
 * the caller's, because the caller is the one that knows to hide the marker. */
typedef void (*AowlDu_W2S)(void*, void*, void*, void*);

static double aowl_du_w2s_out[3] = { 0.0, 0.0, 0.0 };

static int32_t aowl_du_world_to_screen(void* fn, void* cam,
                                       double wx, double wy, double wz) {
    float pos[3];
    float ret[4];
    int i;
    if (!fn || !cam) return 0;
    pos[0] = (float)wx; pos[1] = (float)wy; pos[2] = (float)wz;
    ret[0] = 0.0f; ret[1] = 0.0f; ret[2] = 0.0f; ret[3] = 0.0f;
    ((AowlDu_W2S)fn)((void*)ret, cam, (void*)pos, NULL);
    for (i = 0; i < 3; i++) {
        float v = ret[i];
        /* NaN is the only value not equal to itself; the magnitude bound then
         * rejects the infinities and the absurd finite values a half-built
         * projection matrix produces. */
        if (v != v) return 0;
        if (v > 1.0e9f || v < -1.0e9f) return 0;
        aowl_du_w2s_out[i] = (double)v;
    }
    return 1;
}
static double aowl_du_screen_x(void) { return aowl_du_w2s_out[0]; }
static double aowl_du_screen_y(void) { return aowl_du_w2s_out[1]; }
static double aowl_du_screen_z(void) { return aowl_du_w2s_out[2]; }

/* ------------------------------------------------------------------ *
 * Guarded scalar stores
 *
 * `aowl_uxpatch_write_ptr` covers the reference case (and is what the version
 * brand uses live). These are its int32 / byte / float siblings, with exactly
 * the same discipline: VirtualQuery the destination, insist on a COMMITTED
 * WRITABLE region, insist the whole store fits inside that region, and only
 * then memcpy. Returns 1 on success, 0 if the slot is not safely writable -- in
 * which case NOTHING is written and the caller leaves the game's value alone.
 * ------------------------------------------------------------------ */

static int32_t aowl_du_writable(void* p, int32_t off, size_t n) {
    MEMORY_BASIC_INFORMATION mbi;
    char* at;
    uintptr_t start, end, need;
    if (!p) return 0;
    at = (char*)p + off;
    if (VirtualQuery(at, &mbi, sizeof(mbi)) == 0) return 0;
    if (mbi.State != MEM_COMMIT) return 0;
    if (mbi.Protect & (PAGE_NOACCESS | PAGE_GUARD)) return 0;
    if (!(mbi.Protect & (PAGE_READWRITE | PAGE_WRITECOPY |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)))
        return 0;
    start = (uintptr_t)mbi.BaseAddress;
    end   = start + (uintptr_t)mbi.RegionSize;
    need  = (uintptr_t)at + (uintptr_t)n;
    if (need < (uintptr_t)at) return 0;      /* wrapped */
    if (need > end) return 0;
    return 1;
}
static int32_t aowl_du_write_i32(void* p, int32_t off, int32_t v) {
    if (!aowl_du_writable(p, off, sizeof(int32_t))) return 0;
    memcpy((char*)p + off, &v, sizeof(int32_t));
    return 1;
}
static int32_t aowl_du_write_u8(void* p, int32_t off, int32_t v) {
    unsigned char b = (unsigned char)(v & 0xFF);
    if (!aowl_du_writable(p, off, 1)) return 0;
    memcpy((char*)p + off, &b, 1);
    return 1;
}
static int32_t aowl_du_write_f32(void* p, int32_t off, double v) {
    float f = (float)v;
    if (!aowl_du_writable(p, off, sizeof(float))) return 0;
    memcpy((char*)p + off, &f, sizeof(float));
    return 1;
}
/* A Color is four consecutive floats (r,g,b,a) -- one call rather than four so
 * a half-written colour is not a state the renderer can observe. */
static int32_t aowl_du_write_color(void* p, int32_t off,
                                   double r, double g, double b, double a) {
    float c[4];
    if (!aowl_du_writable(p, off, sizeof(c))) return 0;
    c[0] = (float)r; c[1] = (float)g; c[2] = (float)b; c[3] = (float)a;
    memcpy((char*)p + off, c, sizeof(c));
    return 1;
}

/* ------------------------------------------------------------------ *
 * The toggle key
 *
 * `GetAsyncKeyState` rather than a managed input read: it is a plain user32
 * call with no managed state behind it, so it is safe from any thread and
 * cannot fault, and it does not care whether EFT's own input system has focus
 * of the key. Edge-detected here in C so the Nim side sees ONE `1` per physical
 * press however often it polls.
 *
 * Sixteen independent slots, keyed by virtual-key code, because the panel and
 * the markers may (and by default do not, but may) want different keys.
 * ------------------------------------------------------------------ */

#define AOWL_DU_KEYSLOTS 16
static int32_t aowl_du_key_vk[AOWL_DU_KEYSLOTS];
static int32_t aowl_du_key_was[AOWL_DU_KEYSLOTS];

static int32_t aowl_du_key_edge(int32_t vk) {
    int i, free_slot = -1;
    int down;
    if (vk <= 0 || vk > 0xFF) return 0;
    for (i = 0; i < AOWL_DU_KEYSLOTS; i++) {
        if (aowl_du_key_vk[i] == vk) break;
        if (free_slot < 0 && aowl_du_key_vk[i] == 0) free_slot = i;
    }
    if (i == AOWL_DU_KEYSLOTS) {
        if (free_slot < 0) return 0;         /* table full: never a false edge */
        i = free_slot;
        aowl_du_key_vk[i] = vk;
        aowl_du_key_was[i] = 0;
    }
    down = (GetAsyncKeyState(vk) & 0x8000) ? 1 : 0;
    if (down && !aowl_du_key_was[i]) {
        aowl_du_key_was[i] = 1;
        return 1;
    }
    if (!down) aowl_du_key_was[i] = 0;
    return 0;
}

/* Whether the game's own window has the foreground. The toggle key is polled
 * globally by `GetAsyncKeyState`, so without this an F3 typed into a text editor
 * on the other monitor would toggle the panel. */
static int32_t aowl_du_foreground(void) {
    DWORD pid = 0;
    HWND h = GetForegroundWindow();
    if (!h) return 0;
    GetWindowThreadProcessId(h, &pid);
    return (pid == GetCurrentProcessId()) ? 1 : 0;
}

/* ------------------------------------------------------------------ *
 * The frame-rate estimate
 *
 * `Time::get_frameCount` would give the frame NUMBER, not a rate, and dividing
 * it would need a managed call per sample. This counts detour firings against
 * QueryPerformanceCounter, which is exact, allocation-free, and correct even if
 * the detour is somehow called more than once a frame (the answer is then
 * "firings per second", which is still the number that matters for "is the
 * panel costing me anything").
 *
 * Returns the rate over the last completed window (>= 500ms), or the previous
 * answer while a window is still filling, so the panel never flickers between a
 * real number and a zero.
 * ------------------------------------------------------------------ */

static int64_t aowl_du_fps_qpc0  = 0;
static int64_t aowl_du_fps_freq  = 0;
static int32_t aowl_du_fps_count = 0;
static double  aowl_du_fps_value = 0.0;
static int64_t aowl_du_frames    = 0;

static void aowl_du_fps_sample(void) {
    LARGE_INTEGER now;
    aowl_du_frames++;
    if (aowl_du_fps_freq == 0) {
        LARGE_INTEGER f;
        if (!QueryPerformanceFrequency(&f) || f.QuadPart == 0) return;
        aowl_du_fps_freq = (int64_t)f.QuadPart;
    }
    if (!QueryPerformanceCounter(&now)) return;
    if (aowl_du_fps_qpc0 == 0) {
        aowl_du_fps_qpc0 = (int64_t)now.QuadPart;
        aowl_du_fps_count = 0;
        return;
    }
    aowl_du_fps_count++;
    {
        int64_t dt = (int64_t)now.QuadPart - aowl_du_fps_qpc0;
        if (dt >= aowl_du_fps_freq / 2) {
            aowl_du_fps_value = (double)aowl_du_fps_count *
                                (double)aowl_du_fps_freq / (double)dt;
            aowl_du_fps_qpc0 = (int64_t)now.QuadPart;
            aowl_du_fps_count = 0;
        }
    }
}
static double  aowl_du_fps(void)    { return aowl_du_fps_value; }
static int64_t aowl_du_frame_no(void) { return aowl_du_frames; }

#endif /* AOWLSPT_DEBUGUI_H */
