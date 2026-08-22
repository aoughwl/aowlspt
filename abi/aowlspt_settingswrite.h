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

#endif /* AOWLSPT_SETTINGSWRITE_H */
