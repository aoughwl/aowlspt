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

/* TMPro.TMP_Text -- the fields that decide whether a label DRAWS AT ALL.
 *
 * These were added after the overlay built 33 clones and showed nothing. Every
 * one of them is a way for a live, parented, correctly-positioned TMP label to
 * render zero glyphs, and every one of them is INHERITED BY THE CLONE from the
 * version label, which is styled for a corner of the screen and not for us:
 *
 *   m_enableWordWrapping  a narrow rect wraps every word onto its own line and
 *   m_overflowMode        an Overflow mode of Ellipsis/Truncate/Masking then
 *                         clips them away. Wrapping OFF + overflow Overflow(0)
 *                         makes the rect's WIDTH stop mattering entirely.
 *   m_enableAutoSizing    auto-size shrinks the text to fit the rect; against a
 *                         collapsed rect it shrinks it to nothing.
 *   m_maxVisibleCharacters / Words / Lines
 *                         a typewriter/reveal effect on the source leaves these
 *                         clamped, and a clamp of 0 is an invisible label with
 *                         perfectly good text in `m_text`.
 *   m_firstVisibleCharacter / m_pageToDisplay
 *                         the same, from the other end.
 *   m_HorizontalAlignment / m_VerticalAlignment / m_textAlignment
 *                         the version label is bottom-anchored; a top-left panel
 *                         wants top-left alignment or the text sits a rect-height
 *                         away from where the anchor says it is.
 *   m_Color (Graphic)     the CanvasRenderer tint. The alpha version label is
 *                         drawn faint; a clone that inherits alpha 0.15 is not
 *                         invisible but is very close to it.
 *   m_Canvas (Graphic)    read-only here -- it is how the diagnostics name the
 *                         canvas the clone actually landed in.
 *
 * Values (standard TMP enums): HorizontalAlignmentOptions.Left = 1,
 * VerticalAlignmentOptions.Top = 256, TextAlignmentOptions.TopLeft = 257,
 * TextOverflowModes.Overflow = 0.
 */
#define AOWL_DU_TMP_GCOLOR       0x028  /* Graphic m_Color -> Color (4 floats) */
#define AOWL_DU_TMP_GRECT        0x050  /* Graphic m_RectTransform             */
#define AOWL_DU_TMP_GCANVAS      0x060  /* Graphic m_Canvas -> Canvas          */
#define AOWL_DU_TMP_AUTOSIZE     0x240  /* m_enableAutoSizing -> bool          */
#define AOWL_DU_TMP_HALIGN       0x274  /* m_HorizontalAlignment -> int        */
#define AOWL_DU_TMP_VALIGN       0x278  /* m_VerticalAlignment -> int          */
#define AOWL_DU_TMP_TEXTALIGN    0x27C  /* m_textAlignment -> int              */
#define AOWL_DU_TMP_WORDWRAP     0x2E0  /* m_enableWordWrapping -> bool        */
#define AOWL_DU_TMP_OVERFLOW     0x2E8  /* m_overflowMode -> int               */
#define AOWL_DU_TMP_FIRSTVIS     0x32C  /* m_firstVisibleCharacter -> int      */
#define AOWL_DU_TMP_MAXVISCHARS  0x330  /* m_maxVisibleCharacters -> int       */
#define AOWL_DU_TMP_MAXVISWORDS  0x334  /* m_maxVisibleWords -> int            */
#define AOWL_DU_TMP_MAXVISLINES  0x338  /* m_maxVisibleLines -> int            */
#define AOWL_DU_TMP_PAGE         0x340  /* m_pageToDisplay -> int              */
#define AOWL_DU_TMP_MARGIN       0x348  /* m_margin -> Vector4 (l,t,r,b)       */

/* System.String, for reading a name back out of a managed string. */
#define AOWL_DU_STR_LEN          0x010
#define AOWL_DU_STR_CHARS        0x014

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
static int32_t aowl_du_off_tmp_gcolor(void)      { return AOWL_DU_TMP_GCOLOR; }
static int32_t aowl_du_off_tmp_gcanvas(void)     { return AOWL_DU_TMP_GCANVAS; }
static int32_t aowl_du_off_tmp_autosize(void)    { return AOWL_DU_TMP_AUTOSIZE; }
static int32_t aowl_du_off_tmp_halign(void)      { return AOWL_DU_TMP_HALIGN; }
static int32_t aowl_du_off_tmp_valign(void)      { return AOWL_DU_TMP_VALIGN; }
static int32_t aowl_du_off_tmp_textalign(void)   { return AOWL_DU_TMP_TEXTALIGN; }
static int32_t aowl_du_off_tmp_wordwrap(void)    { return AOWL_DU_TMP_WORDWRAP; }
static int32_t aowl_du_off_tmp_overflow(void)    { return AOWL_DU_TMP_OVERFLOW; }
static int32_t aowl_du_off_tmp_firstvis(void)    { return AOWL_DU_TMP_FIRSTVIS; }
static int32_t aowl_du_off_tmp_maxvischars(void) { return AOWL_DU_TMP_MAXVISCHARS; }
static int32_t aowl_du_off_tmp_maxviswords(void) { return AOWL_DU_TMP_MAXVISWORDS; }
static int32_t aowl_du_off_tmp_maxvislines(void) { return AOWL_DU_TMP_MAXVISLINES; }
static int32_t aowl_du_off_tmp_page(void)        { return AOWL_DU_TMP_PAGE; }
static int32_t aowl_du_off_tmp_margin(void)      { return AOWL_DU_TMP_MARGIN; }

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
/* The READ-BACK half, added for the "33 clones, nothing on screen" hunt: the
 * overlay could WRITE a transform but had no way to ask what the transform then
 * actually was, so a clone parked at a garbage rect was indistinguishable from a
 * clone that was never drawn. Every one of these is read-only. */
#define AOWL_DU_GET_ANCHOREDPOS  8
#define AOWL_DU_GET_SIZEDELTA    9
#define AOWL_DU_SET_SIZEDELTA    10
#define AOWL_DU_GET_ANCHORMIN    11
#define AOWL_DU_GET_PIVOT        12
#define AOWL_DU_GET_RECT         13
#define AOWL_DU_GET_LOCALSCALE   14
#define AOWL_DU_SET_LOCALSCALE   15
#define AOWL_DU_GET_LOCALPOS     16
#define AOWL_DU_SET_LOCALPOS     17
#define AOWL_DU_GET_PARENT       18
#define AOWL_DU_GO_ACTIVESELF    19
#define AOWL_DU_GO_ACTIVEINHIER  20
#define AOWL_DU_GO_LAYER         21
#define AOWL_DU_CANVAS_ORDER     22
#define AOWL_DU_CANVAS_MODE      23
#define AOWL_DU_CANVAS_SCALE     24

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

    /* ---- the read-back / geometry half ----
     *
     * RVAs from the same per-image methodPointers resolve that produced the
     * eight above (UnityEngine.RectTransform is type 23163, Transform 23165,
     * GameObject 23102, Canvas 30443), and each prologue below was dumped from
     * GameAssembly.dll rather than typed from memory. The three targets already
     * in this table that the same dump covers (Camera::get_main,
     * Object::Instantiate, RectTransform::set_anchoredPosition) came back
     * byte-identical to what was already written down, which is what makes the
     * new rows trustworthy.
     *
     * SHAPES, from those prologues:
     *   a Vector2 is 8 bytes, so it is RETURNED IN RAX  -> AowlDu_U_P
     *   a Vector3 is 12 and a Rect is 16, so both are returned through a HIDDEN
     *     BUFFER: (retbuf in RCX, this in RDX, MethodInfo*) -> AowlDu_SRET_P
     *     (`33 C0 / 48 8B FA / 48 89 01` -- zero, this into RDI, store into
     *      [RCX] -- is that shape written out)
     *   a Vector3 ARGUMENT is likewise passed BY ADDRESS in RDX
     *     (`48 8B DA` then the address is handed to the icall) -> AowlDu_V_PPTR
     *   an int/bool/float return is the plain (this, MethodInfo*) shape.
     */
    { "UnityEngine.RectTransform::get_anchoredPosition", 0x52B5430u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x33,0xC0,0x48,0x8B,0xD9,0x48,0x89,
        0x44,0x24,0x40 }, 16 },
    { "UnityEngine.RectTransform::get_sizeDelta", 0x52B54F0u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x33,0xC0,0x48,0x8B,0xD9,0x48,0x89,
        0x44,0x24,0x40 }, 16 },
    { "UnityEngine.RectTransform::set_sizeDelta", 0x52B5550u,
      { 0x40,0x53,0x48,0x83,0xEC,0x30,0x48,0x8B,0x05,0x13,0xF6,0xE1,0x01,
        0x48,0x8B,0xD9 }, 16 },
    { "UnityEngine.RectTransform::get_anchorMin", 0x52B52B0u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x33,0xC0,0x48,0x8B,0xD9,0x48,0x89,
        0x44,0x24,0x40 }, 16 },
    { "UnityEngine.RectTransform::get_pivot", 0x52B55B0u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x33,0xC0,0x48,0x8B,0xD9,0x48,0x89,
        0x44,0x24,0x40 }, 16 },
    /* get_anchorMax -- rid 3151, resolved with tools/il2cpp_resolve.py against
     * type 23163 (UnityEngine.RectTransform, UnityEngine.CoreModule.dll), NOT
     * annotated `[shared]` by that resolver's --shared pass. Same Vector2-in-RAX
     * prologue as the four getters above it -> AowlDu_U_P / aowl_du_vec2_x/y.
     * Added for `rect`'s anchorMax column; get_anchorMin already covered the
     * other corner. */
    { "UnityEngine.RectTransform::get_anchorMax", 0x52B5370u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x33,0xC0,0x48,0x8B,0xD9,0x48,0x89,
        0x44,0x24,0x40 }, 16 },
    /* get_rect returns a Rect (x, y, width, height) -- the ONE call that says
     * outright how big the label's box is after every anchor has been applied,
     * and, on the canvas root, how big the canvas is in canvas units. */
    { "UnityEngine.RectTransform::get_rect", 0x52B5240u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,
        0xDF,0xF8,0xE1 }, 16 },
    { "UnityEngine.Transform::get_localScale", 0x52B8100u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x33,0xC0,0x48,
        0x8B,0xFA,0x48 }, 16 },
    { "UnityEngine.Transform::set_localScale", 0x52B8170u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,
        0xCF,0xCA,0xE1 }, 16 },
    { "UnityEngine.Transform::get_localPosition", 0x52B71B0u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x33,0xC0,0x48,
        0x8B,0xFA,0x48 }, 16 },
    { "UnityEngine.Transform::set_localPosition", 0x52B7220u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,
        0xEF,0xD9,0xE1 }, 16 },
    { "UnityEngine.Transform::get_parent", 0x52B81D0u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0xB3,0xC9,0xE1,0x01,
        0x48,0x8B,0xD9 }, 16 },
    { "UnityEngine.GameObject::get_activeSelf", 0x52A8C40u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0x53,0xB9,0xE2,0x01,
        0x48,0x8B,0xD9 }, 16 },
    { "UnityEngine.GameObject::get_activeInHierarchy", 0x52A8C90u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0x0B,0xB9,0xE2,0x01,
        0x48,0x8B,0xD9 }, 16 },
    { "UnityEngine.GameObject::get_layer", 0x52A8B30u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0x4B,0xBA,0xE2,0x01,
        0x48,0x8B,0xD9 }, 16 },
    /* The Canvas the clone landed in: its sorting order says whether anything
     * is drawn OVER us, its render mode says whether "screen corner" even means
     * anything, and its scale factor is the number the ESP projection has to
     * divide by -- Screen.WorldToScreenPoint is in PIXELS, anchoredPosition is
     * in CANVAS UNITS, and they are only the same number at scale 1. */
    { "UnityEngine.Canvas::get_sortingOrder", 0x5584540u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0x23,0x3A,0xB5,0x01,
        0x48,0x8B,0xD9 }, 16 },
    { "UnityEngine.Canvas::get_renderMode", 0x5584080u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0x73,0x3E,0xB5,0x01,
        0x48,0x8B,0xD9 }, 16 },
    { "UnityEngine.Canvas::get_scaleFactor", 0x5584180u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0x8B,0x3D,0xB5,0x01,
        0x48,0x8B,0xD9 }, 16 },

    /* UnityEngine.UI.Graphic::set_raycastTarget(bool) -- instance, 1 bool.
     *
     * ADDED AFTER THE LIVE CRASH. A TextMeshProUGUI is a Graphic, and a Graphic
     * defaults to being a RAYCAST TARGET. Every clone the overlay makes is
     * therefore an invisible-but-clickable surface, and the panel spans a wide
     * strip of the screen. With the panel open, a click in the menu lands on
     * OUR label instead of the button under it -- which is exactly the report:
     * "clicking with the panel open killed the game". A debug read-out must
     * never eat input.
     *
     * The getter proves the field for anyone who prefers the raw store:
     * `Graphic::get_raycastTarget` @0x1A180B0 is literally
     * `movzx eax, byte [rcx+0x3A]; ret`, so m_RaycastTarget is +0x3A. We call
     * the setter anyway -- it also runs SetRaycastDirty, which is what actually
     * unregisters the graphic from the raycaster.
     * Type 26949 UnityEngine.UI.Graphic, rid 231, RVA 0x53AD7F0, section
     * `il2cpp`. */
    { "UnityEngine.UI.Graphic::set_raycastTarget", 0x53AD7F0u,
      { 0x48,0x89,0x5C,0x24,0x10,0x57,0x48,0x83,0xEC,0x20,0x80,0x3D,0xDA,
        0x95,0xD2,0x01 }, 16 },

    /* UnityEngine.Behaviour::set_enabled(bool) -- instance, 1 bool.
     *
     * THE ROOT OF THE WHOLE CANVAS SAGA. The version label's own GameObject
     * carries a nested `Canvas`, so `Object::Instantiate` copies that Canvas
     * onto every clone -- which is why the clone reported a DIFFERENT canvas
     * pointer no matter what we parented it to, including the source's own
     * parent. It was never a parenting problem.
     *
     * A `Canvas` is a `Behaviour`, so disabling it through this setter makes
     * the clone's graphics fall through to the nearest enabled ancestor canvas
     * -- the source's -- without destroying anything. Disable rather than
     * Destroy on purpose: Destroy on a component of a live UI object is the
     * riskier operation, and a disabled component is reversible.
     * Type 23083 UnityEngine.Behaviour, rid 2655, RVA 0xC4C760, section
     * `il2cpp`. */
    { "UnityEngine.Behaviour::set_enabled", 0xC4C760u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,
        0x4F,0x7D,0x48 }, 16 },

    /* ---- THE VISIBILITY BLOCK (indices 28..35) -------------------------
     *
     * APPENDED, never inserted. Every index above is positional and lives in
     * debugui.nim / settingspages.nim; inserting a row in the MIDDLE of this
     * table is exactly the defect that made `DuGetParent` resolve to
     * `Transform::set_localPosition` and cost four rounds. Appending leaves
     * every existing index untouched, and `duTargetsBindOk` still fails loudly
     * if the appended NAMES do not match what the Nim side believes.
     *
     * These eight answer "is it actually on screen", which the table above
     * could not: it could place a label and never say whether the label drew.
     * SHAREDNESS was checked for each (il2cpp_resolve.py type --shared); the
     * three folded ones are annotated. We only ever CALL these -- a shared RVA
     * is correct code for the receiver passed; it must never be HOOKED. */

    /* UnityEngine.Transform::TransformPoint(Vector3) -- INSTANCE, sret,
     * argument BY ADDRESS: (retbuf, this, &position, MethodInfo*). Identical
     * ABI shape to Camera::WorldToScreenPoint above, which is why
     * `aowl_du_call_sret_p_v3` serves both. Local rect corner -> WORLD point;
     * for a ScreenSpaceOverlay canvas a world unit IS a screen pixel, which is
     * what makes `screenrect` real pixels rather than an estimate.
     * Type 23165, rid 3232, RVA 0x52B9A10, section `il2cpp`, not shared. */
    { "UnityEngine.Transform::TransformPoint(Vector3)", 0x52B9A10u,
      { 0x48,0x89,0x5C,0x24,0x08,0x48,0x89,0x74,0x24,0x10,0x57,0x48,0x83,
        0xEC,0x20,0x33 }, 16 },

    /* UnityEngine.Transform::get_lossyScale -- INSTANCE, Vector3 sret.
     * A zero component here is a complete explanation for an invisible node
     * and is invisible to every other verb we have.
     * Type 23165, rid 3245, RVA 0x52B9F60, not shared. */
    { "UnityEngine.Transform::get_lossyScale", 0x52B9F60u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x33,0xC0,0x48,
        0x8B,0xFA,0x48 }, 16 },

    /* UnityEngine.CanvasGroup::get_alpha -- INSTANCE -> float (XMM0).
     * Type 30437, rid 2, RVA 0x5580A20, not shared. */
    { "UnityEngine.CanvasGroup::get_alpha", 0x5580A20u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0x7B,0x73,0xB5,0x01,
        0x48,0x8B,0xD9 }, 16 },

    /* UnityEngine.CanvasGroup::get_ignoreParentGroups -- INSTANCE -> bool.
     * Without this the alpha chain is WRONG, not merely incomplete: a group
     * with ignoreParentGroups set terminates the multiplication, so folding
     * ancestors past it would report an alpha the renderer never uses.
     * Type 30437, rid 8, RVA 0x5580C30, not shared. */
    { "UnityEngine.CanvasGroup::get_ignoreParentGroups", 0x5580C30u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0x9B,0x71,0xB5,0x01,
        0x48,0x8B,0xD9 }, 16 },

    /* UnityEngine.UI.Graphic::get_color -- INSTANCE, Color (16 bytes) sret.
     * The body is the whole method: `movups xmm0,[rdx+0x28]; mov rax,rcx;
     * movups [rcx],xmm0; ret` -- i.e. m_Color at +0x28, retbuf in RCX, this in
     * RDX. SHARED with 13 other methods (14 total) purely because that body is
     * generic; calling it with a Graphic receiver is correct. NEVER HOOK IT.
     * Type 26949, rid 228, RVA 0xC41C50. */
    { "UnityEngine.UI.Graphic::get_color", 0xC41C50u,
      { 0x0F,0x10,0x42,0x28,0x48,0x8B,0xC1,0x0F,0x11,0x01,0xC3,0xCC,0xCC,
        0xCC,0xCC,0xCC }, 16 },

    /* UnityEngine.UI.Graphic::get_canvas -- INSTANCE -> Canvas.
     * The PROPERTY, not the `m_Canvas` field the `canvas` verb reads raw: the
     * field is a cache that is null until the graphic has been registered, so
     * a raw read of it reports "no canvas" for a graphic that draws fine.
     * Type 26949, rid 247, RVA 0x53AE230, not shared. */
    { "UnityEngine.UI.Graphic::get_canvas", 0x53AE230u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x80,0x3D,0xA4,
        0x8B,0xD2,0x01 }, 16 },

    /* UnityEngine.Behaviour::get_enabled -- INSTANCE -> bool. The read half of
     * set_enabled above; a disabled Canvas is the single most common reason a
     * correctly built, correctly parented clone never draws.
     * SHARED with 32 other methods (33 total) -- call only, never hook.
     * Type 23083, rid 2654, RVA 0xC4C710. */
    { "UnityEngine.Behaviour::get_enabled", 0xC4C710u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0x9B,0x7D,0x48,0x06,
        0x48,0x8B,0xD9 }, 16 },

    /* UnityEngine.Behaviour::get_isActiveAndEnabled -- INSTANCE -> bool.
     * `enabled` AND `gameObject.activeInHierarchy` in one call, which is the
     * question actually being asked of a Canvas or a Graphic.
     * SHARED with 3 other methods (4 total) -- call only, never hook.
     * Type 23083, rid 2656, RVA 0x207A0E0. */
    { "UnityEngine.Behaviour::get_isActiveAndEnabled", 0x207A0E0u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0xDB,0xA3,0x05,0x05,
        0x48,0x8B,0xD9 }, 16 },
};

#define AOWL_DU_TARGET_COUNT \
    ((int32_t)(sizeof(aowl_du_targets) / sizeof(aowl_du_targets[0])))

static int32_t aowl_du_verified = 0;
static int32_t aowl_du_rejected = 0;
/* Verifies refused because the SHARED prologue snapshot table was full --
 * our capacity limit, not a client change. Kept apart from `rejected` so a
 * refusal can never be reported as "this build changed". */
static int32_t aowl_du_profull = 0;

/* PER-TARGET RESOLUTION STATE: 0 untried, 1 verified, 2 rejected.
 *
 * MEASURED DEFECT this fixes: `aowl_du_verified` was incremented on every
 * SUCCESSFUL CALL to `aowl_du_fn`, but reported as though it were a count of
 * distinct targets -- "%d of %d managed targets verified". Since the overlay
 * calls `aowl_du_fn` repeatedly at runtime (every `duPlace` resolves four
 * setters, every refresh), the left-hand number grew without bound while the
 * right-hand one stayed at the table size. A live run printed
 *
 *     36 of 28 managed targets verified by RVA + prologue
 *
 * which is arithmetically impossible and therefore worthless as evidence in
 * EITHER direction -- it can no longer be read as "all targets verified" nor as
 * "something is wrong". The TOTAL was right; the left-hand number was the bug.
 *
 * The state array makes the counters mean what the message says: each target is
 * counted exactly once, on its first resolution. It also removes a repeated
 * VirtualQuery and prologue compare per call, which is a small bonus and not
 * the point. */
static unsigned char aowl_du_state[AOWL_DU_TARGET_COUNT];

static void* aowl_du_fn_full(int32_t i) {
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
    /* Against the ORIGINAL-bytes snapshot, not live memory -- see
     * `aowlspt_prologue.h`. Symmetrical with the mode-text verifier: whichever
     * of the two features binds second must still be able to verify. */
    if (t->siglen > 0 && !aowl_pro_verify(t->rva, t->sig, t->siglen)) {
        /* TWO DIFFERENT FAILURES. A verify refused because OUR snapshot
         * table had no free row says nothing about the client build, so it
         * is counted apart and NOT latched as a permanent rejection. */
        if (aowl_pro_last_was_table_full()) { aowl_du_profull++; return NULL; }
        /* Counted ONCE, on first rejection. See `aowl_du_state`. */
        if (aowl_du_state[i] == 0) { aowl_du_state[i] = 2; aowl_du_rejected++; }
        return NULL;
    }
    if (aowl_du_state[i] == 0) { aowl_du_state[i] = 1; aowl_du_verified++; }
    return (void*)p;
}

/* The same verify cache `aowl_nu_fn` carries, for the same measured reason:
 * `Camera::WorldToScreenPoint` and the player-position reads run per contact
 * per tick, and each was paying a `GetModuleHandleA` + `VirtualQuery` +
 * snapshot memcmp preamble. The verify still happens against the STARTUP
 * SNAPSHOT and the region is still required committed+executable; it is asked
 * at most once per AOWL_DU_REVERIFY_MS per target instead of per call. See the
 * long note in aowlspt_nativeui.h for what this does and does NOT weaken. */
#define AOWL_DU_REVERIFY_MS 2000
static void*    aowl_du_cache[AOWL_DU_TARGET_COUNT];
static uint64_t aowl_du_cache_at[AOWL_DU_TARGET_COUNT];
static int32_t  aowl_du_cache_valid[AOWL_DU_TARGET_COUNT];

static void* aowl_du_fn(int32_t i) {
    uint64_t now;
    void* p;
    if (i < 0 || i >= AOWL_DU_TARGET_COUNT) return NULL;
    now = (uint64_t)GetTickCount64();
    if (aowl_du_cache_valid[i] && (now - aowl_du_cache_at[i]) < AOWL_DU_REVERIFY_MS)
        return aowl_du_cache[i];       /* may be NULL: a cached REFUSAL */
    p = aowl_du_fn_full(i);
    aowl_du_cache[i] = p;
    aowl_du_cache_at[i] = now;
    aowl_du_cache_valid[i] = 1;
    return p;
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
static int32_t aowl_du_profull_count(void){ return aowl_du_profull; }
/* Distinct targets, never call counts. Both are now bounded by
 * AOWL_DU_TARGET_COUNT by construction: a target transitions out of state 0
 * exactly once, and only one of the two counters is incremented when it does.
 * `ok + bad <= total` is therefore an invariant a reader may rely on. */
static int32_t aowl_du_ok_count(void)     { return aowl_du_verified; }
static int32_t aowl_du_bad_count(void)    { return aowl_du_rejected; }
/* How many targets have been resolved AT ALL. `ok + bad < resolved_total` is
 * impossible; a caller that wants to say "all verified" should compare
 * `aowl_du_ok_count()` against `aowl_du_target_count()` and nothing else. */
static int32_t aowl_du_tried_count(void)  {
    return aowl_du_verified + aowl_du_rejected;
}

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
    /* THE SHARED TARGET. This one function is wanted by the debug overlay and
     * by the menu mode-text feature, so by the time the second of them asks,
     * the first one's JUMP is sitting in these bytes. Comparing live memory
     * here returned NULL to the second caller and, worse, to the alias check
     * that decides whether the two features may share one detour -- which is
     * exactly how a correct multiplex came out as "did not verify on this
     * build". Against the snapshot it answers the same before and after the
     * patch, which is the only way the sharing can work. */
    if (!aowl_pro_verify(AOWL_DU_PRELOADER_UPDATE_RVA,
                         aowl_du_preloader_update_sig,
                         (int32_t)sizeof(aowl_du_preloader_update_sig))) {
        /* Distinguish OUR capacity limit from a real byte mismatch: the
         * shared-detour multiplex hangs off this verify, and reporting an
         * exhausted table as "did not verify on this build" is precisely
         * the confidently-wrong diagnostic this file was written to end. */
        if (aowl_pro_last_was_table_full()) aowl_du_profull++;
        return NULL;
    }
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
/* An instance method with a single BOOL argument (position 1 -> DL/RDX, the
 * hidden MethodInfo* position 2 -> R8). */
static void aowl_du_call_v_pb(void* fn, void* self, int32_t b) {
    typedef void (*Fn)(void*, int32_t, void*);
    if (!fn || !self) return;
    ((Fn)fn)(self, b ? 1 : 0, (void*)0);
}

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
/* INSTANCE, 0 declared args -> a Vector2 (8 bytes, so returned IN RAX).
 * `aowl_du_vec2_x/y` unpack it; the pair is returned as one uint64 rather than
 * through statics because it is genuinely one register and nimony can hold it. */
typedef uint64_t (*AowlDu_U_P)(void*, void*);
static uint64_t aowl_du_call_u_p(void* fn, void* self) {
    if (!fn || !self) return 0;
    return ((AowlDu_U_P)fn)(self, NULL);
}
static double aowl_du_vec2_x(uint64_t packed) {
    float f[2]; memcpy(f, &packed, sizeof(f)); return (double)f[0];
}
static double aowl_du_vec2_y(uint64_t packed) {
    float f[2]; memcpy(f, &packed, sizeof(f)); return (double)f[1];
}

/* INSTANCE, 0 declared args -> int32 / bool / float. */
typedef int32_t (*AowlDu_I_P)(void*, void*);
static int32_t aowl_du_call_i_p(void* fn, void* self) {
    if (!fn || !self) return 0;
    return ((AowlDu_I_P)fn)(self, NULL);
}
typedef float (*AowlDu_F_P)(void*, void*);
static double aowl_du_call_f_p(void* fn, void* self) {
    if (!fn || !self) return 0.0;
    return (double)((AowlDu_F_P)fn)(self, NULL);
}

/* INSTANCE, 0 declared args -> a struct BIGGER than 8 bytes (Vector3, Rect), so
 * Win64 returns it through a hidden buffer: (retbuf, this, MethodInfo*).
 *
 * The result lands in four statics read back with `aowl_du_sret_0..3`, for the
 * same reason `aowl_du_world_to_screen` does it: nimony cannot hand out the
 * address of an array element, and the overlay is single-threaded. A NaN or an
 * absurd magnitude returns 0 and leaves the statics alone, so a half-torn-down
 * transform cannot feed a garbage number into a layout decision. */
typedef void (*AowlDu_SRET_P)(void*, void*, void*);
static double aowl_du_sret_out[4] = { 0.0, 0.0, 0.0, 0.0 };
static int32_t aowl_du_call_sret_p(void* fn, void* self, int32_t nfloats) {
    float ret[4];
    int i;
    if (!fn || !self) return 0;
    if (nfloats < 1 || nfloats > 4) return 0;
    for (i = 0; i < 4; i++) ret[i] = 0.0f;
    ((AowlDu_SRET_P)fn)((void*)ret, self, NULL);
    for (i = 0; i < nfloats; i++) {
        float v = ret[i];
        if (v != v) return 0;
        if (v > 1.0e9f || v < -1.0e9f) return 0;
    }
    for (i = 0; i < nfloats; i++) aowl_du_sret_out[i] = (double)ret[i];
    return 1;
}
/* INSTANCE, ONE Vector3 argument BY ADDRESS, struct >8 bytes returned through
 * a hidden buffer: (retbuf, this, &arg, MethodInfo*).
 *
 * The same ABI shape `aowl_du_world_to_screen` hardcodes for
 * Camera::WorldToScreenPoint, generalised so Transform::TransformPoint can use
 * it without a second copy of the plumbing. Result lands in the SAME
 * `aowl_du_sret_out` statics as `aowl_du_call_sret_p`, read back with
 * `aowl_du_sret_0..3`. Returns 0 -- leaving the statics untouched -- on a NaN
 * or an absurd magnitude, because a garbage screen position that still looks
 * like a number is the failure this whole file exists to stop. */
static int32_t aowl_du_call_sret_p_v3(void* fn, void* self,
                                      double ax, double ay, double az,
                                      int32_t nfloats) {
    float arg[3];
    float ret[4];
    int i;
    if (!fn || !self) return 0;
    if (nfloats < 1 || nfloats > 4) return 0;
    arg[0] = (float)ax; arg[1] = (float)ay; arg[2] = (float)az;
    for (i = 0; i < 4; i++) ret[i] = 0.0f;
    ((AowlDu_W2S)fn)((void*)ret, self, (void*)arg, NULL);
    for (i = 0; i < nfloats; i++) {
        float v = ret[i];
        if (v != v) return 0;
        if (v > 1.0e9f || v < -1.0e9f) return 0;
    }
    for (i = 0; i < nfloats; i++) aowl_du_sret_out[i] = (double)ret[i];
    return 1;
}
static double aowl_du_sret_0(void) { return aowl_du_sret_out[0]; }
static double aowl_du_sret_1(void) { return aowl_du_sret_out[1]; }
static double aowl_du_sret_2(void) { return aowl_du_sret_out[2]; }
static double aowl_du_sret_3(void) { return aowl_du_sret_out[3]; }

/* INSTANCE, one Vector3 BY ADDRESS -> void.  (this, &value, MethodInfo*)
 * A Vector3 is 12 bytes, which is neither 1/2/4/8, so Win64 passes it by
 * address -- the opposite of the Vector2 setters two thunks up, and the reason
 * they are two thunks and not one. */
typedef void (*AowlDu_V_PPTR)(void*, void*, void*);
static void aowl_du_call_setvec3(void* fn, void* self,
                                 double x, double y, double z) {
    float v[3];
    if (!fn || !self) return;
    v[0] = (float)x; v[1] = (float)y; v[2] = (float)z;
    ((AowlDu_V_PPTR)fn)(self, (void*)v, NULL);
}

/* The length of a managed System.String, or -1 when the pointer is not one we
 * can read. Used by the diagnostics to say "the write landed and the string is
 * N characters long" without decoding it twice. */
static int32_t aowl_du_string_len(void* s) {
    MEMORY_BASIC_INFORMATION mbi;
    int32_t n;
    if (!s) return -1;
    if (VirtualQuery(s, &mbi, sizeof(mbi)) == 0) return -1;
    if (mbi.State != MEM_COMMIT) return -1;
    if (mbi.Protect & (PAGE_NOACCESS | PAGE_GUARD)) return -1;
    memcpy(&n, (char*)s + AOWL_DU_STR_LEN, sizeof(n));
    if (n < 0 || n > 0x100000) return -1;
    return n;
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
