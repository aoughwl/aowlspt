/* aowlspt_settingswrite.h -- Phase 2/3 layout for WRITING into Tarkov's real
 * SettingsScreen.
 *
 * `aowlspt_settingsui.h` is the READ side and stays read-only; this header is
 * its write-side sibling and carries exactly two things:
 *
 *   1. the value-field offsets of the four concrete setting WIDGETS, so a
 *      control's current value can be read and a new one written by raw field
 *      access -- no reflection, which is dead on this build;
 *   2. one guarded byte reader, the missing sibling of the guarded writers that
 *      `aowlspt_debugui.h` already provides (`aowl_du_write_u8` /
 *      `aowl_du_write_f32`) and `aowlspt_uxpatch.h` provides for references
 *      (`aowl_uxpatch_write_ptr`).
 *
 * ## Where these numbers came from
 *
 * All of them were re-derived offline from `Il2CppMetadataRegistration.
 * fieldOffsets` with `tools/il2cpp_resolve.py fields <Type>` against
 * GameAssembly.dll + the DECRYPTED global-metadata, build 1.1.0.1.46777,
 * imagebase 0x180000000 -- the same tool and the same run that reproduces the
 * `System.String` self-check (`_stringLength`@0x10, `_firstChar`@0x14) and every
 * offset already in `aowlspt_settingsui.h`.
 *
 * The decisive structural fact the resolver confirmed for all four widget types
 * at once: EVERY concrete `SettingControl` subclass carries its widget at the
 * SAME offset, +0xA8, because they all inherit the identical base field run and
 * each declares exactly one field of its own:
 *
 *   EFT.UI.Settings.SettingToggle       +0xA8  Toggle    -> EFT.UI.UpdatableToggle
 *   EFT.UI.Settings.SettingFloatSlider  +0xA8  Slider    -> EFT.UI.NumberSlider
 *   EFT.UI.Settings.SettingSelectSlider +0xA8  Slider    -> EFT.UI.SelectSlider
 *   EFT.UI.Settings.SettingDropDown     +0xA8  DropDown  -> EFT.UI.DropDownBox
 *
 * That is why `AOWL_SUI_CTRL_VALUE` (0xA8) in the read header is correct for
 * every control the live probe walked, and why the widget object at +0xA8 needs
 * no per-type dispatch to FETCH -- only to INTERPRET.
 *
 * ## Telling the four apart without reflection
 *
 * `il2cpp_object_get_class` and `il2cpp_class_get_name` both fault on this
 * build, so the type of a control cannot be asked for. It can, however, be
 * OBSERVED: the klass pointer in the object header (obj+0x00) is stable within
 * one process, and the live Phase-1.8 census found exactly FOUR distinct values
 * across all 78 controls on the real screen (dropdown 38, toggle 19, float
 * slider 13, select slider 8). The absolute values differ per launch, so the
 * host learns them per session by matching a control whose stock label is known
 * -- see `AOWL_SW_ANCHOR_*` below -- and then groups every other control by
 * klass identity. That is the whole discriminator: pointer equality, no names.
 *
 * ## The value fields
 *
 * UpdatableToggle derives from UnityEngine.UI.Toggle, whose backing field is
 * `m_IsOn`@0x120 (bool). NumberSlider wraps a UnityEngine.UI.Slider it holds at
 * `_slider`@0x80, and the value lives on that Slider as `m_Value`@0x120 (float),
 * bounded by `m_MinValue`@0x114 / `m_MaxValue`@0x118 and quantised by
 * `m_WholeNumbers`@0x11C. NumberSlider ALSO keeps its own display bounds at
 * `_minValue`@0x9C / `_maxValue`@0x98, which are what the game clamps typed
 * input against.
 *
 * ## What a raw write does and does not do
 *
 * Writing `m_IsOn` or `m_Value` changes the MODEL, not the pixels: Unity
 * repaints a Toggle from `Toggle::Set` and a Slider from
 * `Slider::UpdateVisuals`, neither of which a field store calls. So a raw value
 * write is correct for READING the user's choice and for seeding a control, and
 * it is NOT sufficient to move a checkmark on screen. The text path is the
 * exception and the reason Phase 2a leads with it: TMP repaints from a plain
 * dirty flag (`m_havePropertiesChanged`@0x378), so a String store plus that one
 * byte IS a complete, visible edit -- which is exactly why the version brand
 * works today, and why relabelling is the honest first proof that we can write
 * into the real settings screen.
 *
 * CORRECTION, from the live run. That last paragraph is true of the version
 * label and of the debug overlay's own clones, and it was NOT true of a settings
 * row. The log proved `m_text` held our String (Phase 2b read the value back
 * THROUGH the new label) and the row on screen still said 'FOV:'. A settings
 * label is not a bare TMP: it sits behind an `EFT.UI.LocalizedText`, which
 * re-applies its own localised string, and the raw store is behind that class's
 * back. So the relabel now CALLS `EFT.UI.LocalizedText::SetLabelText` and
 * `TMPro.TMP_Text::set_text` (both added to the target table below) and keeps
 * the raw store only as the last resort on a build where neither verifies.
 * The lesson generalises: prefer calling the managed setter to poking a field.
 *
 * Fail-safe, like every other write in this codebase: nothing here dereferences
 * anything. The reader below VirtualQueries first and returns a miss rather than
 * faulting, and every caller on the Nim side is additionally inside the
 * `aowl_p_p_seh` VEH/setjmp guard that already wraps the settings postfix body.
 */

#ifndef AOWLSPT_SETTINGSWRITE_H
#define AOWLSPT_SETTINGSWRITE_H

#include <windows.h>
#include <stdint.h>

/* ------------------------------------------------------------------ *
 * Widget value fields (offsets from the widget object at control+0xA8)
 * ------------------------------------------------------------------ */

/* EFT.UI.UpdatableToggle : UnityEngine.UI.Toggle */
#define AOWL_SW_TOGGLE_ISON        0x120  /* m_IsOn -> bool                    */

/* EFT.UI.NumberSlider (the SettingFloatSlider widget) */
#define AOWL_SW_NUMSLIDER_SLIDER   0x080  /* _slider   -> UnityEngine.UI.Slider*/
#define AOWL_SW_NUMSLIDER_MAX      0x098  /* _maxValue -> float                */
#define AOWL_SW_NUMSLIDER_MIN      0x09C  /* _minValue -> float                */

/* UnityEngine.UI.Slider (reached through NumberSlider._slider) */
#define AOWL_SW_SLIDER_MINVALUE    0x114  /* m_MinValue     -> float           */
#define AOWL_SW_SLIDER_MAXVALUE    0x118  /* m_MaxValue     -> float           */
#define AOWL_SW_SLIDER_WHOLENUM    0x11C  /* m_WholeNumbers -> bool            */
#define AOWL_SW_SLIDER_VALUE       0x120  /* m_Value        -> float           */

/* TextMeshPro repaint latch -- the same byte the version brand and the debug
 * overlay set, restated here so the settings writer does not have to reach into
 * the debug overlay's header for it. */
#define AOWL_SW_TMP_DIRTY          0x378  /* m_havePropertiesChanged -> bool   */

/* ------------------------------------------------------------------ *
 * Per-session klass anchors
 *
 * Stock English labels whose control type is known from the live census. The
 * host reads the label of every control on a tab, and the first one that
 * matches an anchor teaches it that anchor's klass pointer for this process.
 * Chosen because each sits on a DIFFERENT tab's default page and none is
 * conditional on hardware: 'FOV:' and 'Enable VoIP' are always on Game,
 * 'Device:' and 'Overall volume:' always on Sound.
 * ------------------------------------------------------------------ */
#define AOWL_SW_ANCHOR_FLOAT     "FOV:"
#define AOWL_SW_ANCHOR_TOGGLE    "Enable VoIP"
#define AOWL_SW_ANCHOR_DROPDOWN  "Device:"
#define AOWL_SW_ANCHOR_SELECT    "Overall volume:"

static const char* aowl_sw_anchor_float(void)    { return AOWL_SW_ANCHOR_FLOAT; }
static const char* aowl_sw_anchor_toggle(void)   { return AOWL_SW_ANCHOR_TOGGLE; }
static const char* aowl_sw_anchor_dropdown(void) { return AOWL_SW_ANCHOR_DROPDOWN; }
static const char* aowl_sw_anchor_select(void)   { return AOWL_SW_ANCHOR_SELECT; }

/* ------------------------------------------------------------------ *
 * The guarded byte read
 *
 * `aowlspt_debugui.h` has the u8/f32 WRITERS and `aowlhost` has the ptr/i32/f32
 * READERS; a one-byte reader is the only primitive the settings writer needs
 * that does not exist yet. Same discipline as its siblings: VirtualQuery the
 * address, insist on a COMMITTED, READABLE region, insist the byte lies inside
 * it, and only then touch memory. Returns the byte in 0..255, or -1 for "not
 * safely readable" -- a value the caller can distinguish from both true and
 * false, which is the point.
 * ------------------------------------------------------------------ */
static int32_t aowl_sw_read_u8(void* p, int32_t off) {
    MEMORY_BASIC_INFORMATION mbi;
    unsigned char* at;
    if (!p || off < 0) return -1;
    at = (unsigned char*)p + off;
    if (VirtualQuery((LPCVOID)at, &mbi, sizeof(mbi)) != sizeof(mbi)) return -1;
    if (mbi.State != MEM_COMMIT) return -1;
    if (mbi.Protect & PAGE_NOACCESS) return -1;
    if (mbi.Protect & PAGE_GUARD) return -1;
    if (!(mbi.Protect & (PAGE_READONLY | PAGE_READWRITE | PAGE_WRITECOPY |
                         PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE |
                         PAGE_EXECUTE_WRITECOPY))) return -1;
    /* the byte must lie inside the region VirtualQuery just described */
    if ((uintptr_t)at < (uintptr_t)mbi.BaseAddress) return -1;
    if ((uintptr_t)at >= (uintptr_t)mbi.BaseAddress + (uintptr_t)mbi.RegionSize)
        return -1;
    return (int32_t)(*at);
}

/* Accessors (importc'd by the Nim side), individual functions for the same
 * reason `aowlspt_settingsui.h` uses them: a fault names the exact hop and the
 * header stays the single source of truth for the numbers. */
static int32_t aowl_sw_off_toggle_ison(void)  { return AOWL_SW_TOGGLE_ISON; }
static int32_t aowl_sw_off_ns_slider(void)    { return AOWL_SW_NUMSLIDER_SLIDER; }
static int32_t aowl_sw_off_ns_min(void)       { return AOWL_SW_NUMSLIDER_MIN; }
static int32_t aowl_sw_off_ns_max(void)       { return AOWL_SW_NUMSLIDER_MAX; }
static int32_t aowl_sw_off_slider_value(void) { return AOWL_SW_SLIDER_VALUE; }
static int32_t aowl_sw_off_slider_min(void)   { return AOWL_SW_SLIDER_MINVALUE; }
static int32_t aowl_sw_off_slider_max(void)   { return AOWL_SW_SLIDER_MAXVALUE; }
static int32_t aowl_sw_off_slider_whole(void) { return AOWL_SW_SLIDER_WHOLENUM; }
static int32_t aowl_sw_off_tmp_dirty(void)    { return AOWL_SW_TMP_DIRTY; }

/* ------------------------------------------------------------------ *
 * PHASE 3 -- the four setters a rendered row needs
 *
 * Phase 2 established that a raw value store changes the MODEL and not the
 * pixels: Unity repaints a Toggle from `Toggle::Set` and a Slider from
 * `Slider::UpdateVisuals`, and a field store calls neither. For a row the host
 * itself put on screen that is not good enough -- a cloned control must SHOW
 * the value it is bound to, not the donor's.
 *
 * So Phase 3 stops storing and starts CALLING, by the route
 * `abi/aowlspt_invoke2.h` already proved on this build: IL2CPP compiles every
 * managed method to an ordinary native function, so the setter is called
 * directly at its RVA with IL2CPP's convention (instance in RCX, args after it,
 * hidden trailing MethodInfo*, floats in XMM by position). No reflection, no
 * runtime_invoke, no MethodInfo lookup -- and none of these is a shared
 * generic, so the NULL MethodInfo that the convention note warns about for
 * generics is safe for every one of them.
 *
 * WITHOUT-NOTIFY IS THE POINT. `SetIsOnWithoutNotify` / `SetValueWithoutNotify`
 * update the control and its visuals but do NOT raise `onValueChanged`. That
 * matters enormously here: a clone of a stock control inherits the stock
 * control's listener list, so seeding a cloned FOV row with `set_isOn` would
 * fire the GAME's own FOV handler with our mod's value. The without-notify
 * variants are how a row is seeded without the donor's behaviour running.
 * The user's own click still goes through the game's normal path, which is
 * exactly what we want -- that is how the edit gets back to us.
 *
 * RVAs resolved offline with `tools/il2cpp_resolve.py type <idx>` (Toggle =
 * 27039, Slider = 27032, both in UnityEngine.UI.dll) and every prologue below
 * was read straight out of GameAssembly.dll at the mapped file offset. All six
 * land in the `il2cpp` section, which is the section generated code actually
 * lives in -- a target that resolved into `.text` would be the wrong function.
 * ------------------------------------------------------------------ */

#define AOWL_SW_TOGGLE_SET_NONOTIFY   0
#define AOWL_SW_TOGGLE_SET_ISON       1
#define AOWL_SW_SLIDER_SET_NONOTIFY   2
#define AOWL_SW_SLIDER_SET_MIN        3
#define AOWL_SW_SLIDER_SET_MAX        4
#define AOWL_SW_SLIDER_UPDATEVISUALS  5
#define AOWL_SW_LOC_SETLABELTEXT      6
#define AOWL_SW_TMP_SET_TEXT          7
#define AOWL_SW_TMP_SET_DIRTY         8

typedef struct AowlSwTarget {
    const char*   name;
    uint32_t      rva;
    unsigned char sig[16];
    int32_t       siglen;
} AowlSwTarget;

static const AowlSwTarget aowl_sw_targets[] = {
    /* UnityEngine.UI.Toggle::SetIsOnWithoutNotify(bool) -- instance, 1 arg.
     * A three-instruction thunk that zeroes the two extra parameters and
     * tail-jumps into `Set(bool,bool,bool)`; calling the thunk is calling Set
     * with the game's own defaults, which is precisely what we want. */
    { "UnityEngine.UI.Toggle::SetIsOnWithoutNotify", 0x55BA440u,
      { 0x45,0x33,0xC9,0x45,0x33,0xC0,0xE9,0x05,0x00,0x00,0x00,0xCC,0xCC,
        0xCC,0xCC,0xCC }, 16 },

    /* UnityEngine.UI.Toggle::set_isOn(bool) -- instance, 1 arg. The NOTIFYING
     * setter, carried for completeness and NOT used to seed a clone (it would
     * run the donor's listeners). */
    { "UnityEngine.UI.Toggle::set_isOn", 0x55BA430u,
      { 0x45,0x33,0xC9,0x41,0xB0,0x01,0xE9,0x15,0x00,0x00,0x00,0xCC,0xCC,
        0xCC,0xCC,0xCC }, 16 },

    /* UnityEngine.UI.Slider::SetValueWithoutNotify(float) -- instance, 1 float
     * arg, which by the convention rides in XMM1 (position 1) with the hidden
     * MethodInfo* in R8 (position 2). */
    { "UnityEngine.UI.Slider::SetValueWithoutNotify", 0x55B3420u,
      { 0x4C,0x8B,0x09,0x45,0x33,0xC0,0x49,0x8B,0x81,0x88,0x04,0x00,0x00,
        0x4D,0x8B,0x89 }, 16 },

    /* UnityEngine.UI.Slider::set_minValue / set_maxValue(float) -- instance,
     * 1 float arg. A bound must be widened BEFORE a value outside the donor's
     * range is set, or the Slider clamps it and the row silently shows the
     * wrong number. */
    { "UnityEngine.UI.Slider::set_minValue", 0x55B3250u,
      { 0x40,0x53,0x48,0x83,0xEC,0x30,0x80,0x3D,0xD4,0x4E,0xB2,0x01,0x00,
        0x48,0x8B,0xD9 }, 16 },
    { "UnityEngine.UI.Slider::set_maxValue", 0x55B32D0u,
      { 0x40,0x53,0x48,0x83,0xEC,0x30,0x80,0x3D,0x55,0x4E,0xB2,0x01,0x00,
        0x48,0x8B,0xD9 }, 16 },

    /* UnityEngine.UI.Slider::UpdateVisuals() -- instance, 0 args. The repaint
     * on its own, for the case where the bounds moved but the value did not. */
    { "UnityEngine.UI.Slider::UpdateVisuals", 0x55B4610u,
      { 0x48,0x89,0x5C,0x24,0x20,0x57,0x48,0x83,0xEC,0x70,0x80,0x3D,0x17,
        0x3B,0xB2,0x01 }, 16 },

    /* ---- the RELABEL repaint path (added after the live failure) ----
     *
     * Phase 2a wrote a String into `m_text` and poked the dirty byte. The log
     * proved the store landed -- Phase 2b read the value back THROUGH the new
     * label in the same pass -- and the row on screen still said 'FOV:'.
     *
     * Two causes fit that exactly: no repaint, or an overwrite by
     * `LocalizedText` re-applying its localised string. Both are answered by
     * CALLING the game's own setter instead of poking a field, which is what
     * these three are for.
     *
     * EFT.UI.LocalizedText::SetLabelText(String) -- instance, 1 ref arg. This
     * is the method the game itself uses to put text on the labels behind a
     * LocalizedText (`UpdateLocale` -> `SetLabelText`), so it does whatever
     * this build's repaint actually is, and it writes at the LocalizedText
     * LEVEL rather than behind its back. Resolved offline: type 14184
     * EFT.UI.LocalizedText, rid 86384, RVA 0x140FE70, section `il2cpp`. */
    { "EFT.UI.LocalizedText::SetLabelText", 0x140FE70u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x60,0x48,0x8B,0xFA,
        0x48,0x8B,0xD9 }, 16 },

    /* TMPro.TMP_Text::set_text(String) -- instance, 1 ref arg. The real
     * property setter: it stores m_text, marks the input source, and requests
     * the layout/vertex rebuild that a raw field store does not. Type 25471,
     * rid 1190, RVA 0x51BC1E0, section `il2cpp`. */
    { "TMPro.TMP_Text::set_text", 0x51BC1E0u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x80,0xB9,0xE8,
        0x00,0x00,0x00 }, 16 },

    /* TMPro.TMP_Text::set_havePropertiesChanged(bool) -- instance, 1 bool.
     * Its first instruction is `cmp byte ptr [rcx+0x378], dl`, which is an
     * INDEPENDENT offline confirmation that AOWL_SW_TMP_DIRTY (0x378) is the
     * right field -- and the method does more than store the byte, which is
     * precisely what a raw store was missing. Type 25471, rid 1320,
     * RVA 0x51BEA30, section `il2cpp`.
     *
     * NOTE for anyone tempted by `TMP_Text::ForceMeshUpdate`: on this build it
     * resolves to 0x628110, whose bytes are `C2 00 00 CC CC ...` -- a bare
     * `ret`. It is a stripped stub and calling it does nothing at all. */
    { "TMPro.TMP_Text::set_havePropertiesChanged", 0x51BEA30u,
      { 0x38,0x91,0x78,0x03,0x00,0x00,0x74,0x1A,0x88,0x91,0x78,0x03,0x00,
        0x00,0x48,0x8B }, 16 },
};

#define AOWL_SW_TARGET_COUNT \
    ((int32_t)(sizeof(aowl_sw_targets) / sizeof(aowl_sw_targets[0])))

static int32_t aowl_sw_base_found = 0;
static int32_t aowl_sw_verified   = 0;
static int32_t aowl_sw_rejected   = 0;

/* The verified code pointer for one setter, or NULL. Identical discipline to
 * `aowl_mi2_fn`: the RVA must land in COMMITTED EXECUTABLE memory before the
 * prologue is compared, because on another build a stale RVA can point at an
 * uncommitted page where `memcmp` itself would fault. A mismatch returns NULL
 * and the caller renders nothing rather than calling a wrong function. */
static void* aowl_sw_fn(int32_t i) {
    HMODULE ga;
    const AowlSwTarget* t;
    unsigned char* p;
    MEMORY_BASIC_INFORMATION mbi;
    if (i < 0 || i >= AOWL_SW_TARGET_COUNT) return NULL;
    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) return NULL;
    aowl_sw_base_found = 1;
    t = &aowl_sw_targets[i];
    p = (unsigned char*)ga + t->rva;
    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return NULL;
    if (mbi.State != MEM_COMMIT) return NULL;
    if (!(mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)))
        return NULL;
    if (t->siglen > 0 && memcmp(p, t->sig, (size_t)t->siglen) != 0) {
        aowl_sw_rejected++;
        return NULL;
    }
    aowl_sw_verified++;
    return (void*)p;
}
static const char* aowl_sw_name(int32_t i) {
    if (i < 0 || i >= AOWL_SW_TARGET_COUNT) return "";
    return aowl_sw_targets[i].name;
}
static uint32_t aowl_sw_rva(int32_t i) {
    if (i < 0 || i >= AOWL_SW_TARGET_COUNT) return 0u;
    return aowl_sw_targets[i].rva;
}
static int32_t aowl_sw_target_count(void) { return AOWL_SW_TARGET_COUNT; }
static int32_t aowl_sw_ok_count(void)  { return aowl_sw_verified; }
static int32_t aowl_sw_bad_count(void) { return aowl_sw_rejected; }

/* The one call shape `aowlspt_invoke2.h` does not already provide: an instance
 * method taking a single FLOAT. The float is argument position 1, so it rides
 * in XMM1, and the hidden MethodInfo* is position 2, so it rides in R8 -- which
 * is exactly what the C compiler emits for this prototype, which is the whole
 * reason the thunks are written as typed calls rather than as assembly.
 *
 * The value is taken as a double and narrowed here, because Nim's float64 is
 * what the caller has and an implicit narrowing at the call site is the kind of
 * thing that is right until someone changes it. */
static void aowl_sw_call_v_pf(void* fn, void* self, double v) {
    typedef void (*Fn)(void*, float, void*);
    if (!fn || !self) return;
    ((Fn)fn)(self, (float)v, (void*)0);
}

/* An instance method with a single BOOL argument (position 1 -> DL/RDX, the
 * MethodInfo* position 2 -> R8). `aowl_mi2_call_v_pb` has this shape already;
 * it is restated here so the settings writer does not depend on the invoke
 * ladder's table being armed to use its thunks. */
static void aowl_sw_call_v_pb(void* fn, void* self, int32_t b) {
    typedef void (*Fn)(void*, int32_t, void*);
    if (!fn || !self) return;
    ((Fn)fn)(self, b ? 1 : 0, (void*)0);
}

/* An instance method with a single REFERENCE argument (position 1 -> RDX, the
 * MethodInfo* position 2 -> R8). This is the shape both `SetLabelText(String)`
 * and `set_text(String)` need. */
static void aowl_sw_call_v_pp(void* fn, void* self, void* arg) {
    typedef void (*Fn)(void*, void*, void*);
    if (!fn || !self) return;
    ((Fn)fn)(self, arg, (void*)0);
}

/* An instance method with no arguments at all (MethodInfo* is position 1 ->
 * RDX). */
static void aowl_sw_call_v_p(void* fn, void* self) {
    typedef void (*Fn)(void*, void*);
    if (!fn || !self) return;
    ((Fn)fn)(self, (void*)0);
}

#endif /* AOWLSPT_SETTINGSWRITE_H */
