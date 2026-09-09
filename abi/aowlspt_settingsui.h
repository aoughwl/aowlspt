/* aowlspt_settingsui.h -- Phase 1 field offsets for the native SettingsScreen
 * control-tree probe.
 *
 * READ-ONLY. This header carries nothing but the static field offsets the host's
 * settings-UI probe walks, exposed as small accessor functions (the same shape
 * as `aowl_uxpatch_version_label_offset`) so the compiled host literally uses the
 * numbers recorded here and a future build's different layout is a one-file edit.
 *
 * The offsets come from the offline field-offset tool (Phase 0,
 * `tools/il2cpp_resolve.py settings-table`, build 1.1.0.1.46777, imagebase
 * 0x180000000) which reads `Il2CppMetadataRegistration.fieldOffsets` and is
 * cross-checked against `System.String` (0x10/0x14). Every one is a CANDIDATE
 * until the live read-only probe logs a known stock label at it -- that content
 * match is what validates the offset before any write is ever attempted (Phase 2+).
 *
 * PHASE 1.5 UPDATE (from the live Phase-1 log): `Show` fires correctly on the
 * Unity thread and the tab fields below all resolve, but at `Show` time every
 * tab's `_createdControls` (0x88) is still NULL -- the controls are built later,
 * lazily, by `SettingsScreen::EnsureTabInitialized`. The probe therefore now
 * ALSO hooks that method as a POSTFIX (target + prologue in `aowlspt_bridge.h`)
 * and walks the one tab that call just built. `Show` stays hooked as the
 * arming/thread confirmation it already proved itself to be.
 *
 * The detour target itself (SettingsScreen::Show @ RVA 0x171FA00) is already
 * verified and handed out by `aowl_bridge_settings_target_at` in
 * `aowlspt_bridge.h`; this header adds only the layout the probe reads once it is
 * on the Unity thread with `this` = the live SettingsScreen.
 *
 * ## The walk (all reads cIsReadable-guarded on the host/Nim side)
 *
 *   SettingsScreen (this)
 *     + 0x118  _currentTab           -> SettingsTab
 *     + 0xF0   _gameSettingsScreen    (typed tab field)
 *     + 0xF8   _graphicsSettingsScreen
 *     + 0x100  _postFXSettingsScreen
 *     + 0x108  _soundSettingsScreen
 *     + 0x110  _controlsSettingsTabScreen
 *
 *   SettingsTab
 *     + 0x88   _createdControls  -> List<SettingControl>
 *
 *   List<T>  (fixed IL2CPP layout, same as every generic List)
 *     + 0x10   _items  -> T[]          (array object)
 *     + 0x18   _size   -> int32 count
 *   T[]  elements are inline starting at  + 0x20  (8 bytes each, a pointer)
 *
 *   SettingControl
 *     + 0x80   Text   -> LocalizedText (label wrapper)
 *     + 0xA8   value widget (NumberSlider / UpdatableToggle / DropDownBox,
 *              per subclass) -- logged raw this phase, not decoded
 *     + 0x00   klass (Il2CppObject header) -> the control's il2cpp type pointer,
 *              logged raw so slider/toggle/dropdown can later be told apart by
 *              matching known type pointers, no reflection
 *
 *   LocalizedText
 *     + 0x78   List<TextMeshProUGUI>   (the same List layout above)
 *   TextMeshProUGUI
 *     + 0xE0   m_text -> System.String  (length @ +0x10, UTF-16 chars @ +0x14)
 */

#ifndef AOWLSPT_SETTINGSUI_H
#define AOWLSPT_SETTINGSUI_H

#include <stdint.h>

/* SettingsScreen tab fields. */
#define AOWL_SUI_SS_CURRENTTAB     0x118
#define AOWL_SUI_SS_GAMETAB        0x0F0
#define AOWL_SUI_SS_GRAPHICSTAB    0x0F8
#define AOWL_SUI_SS_POSTFXTAB      0x100
#define AOWL_SUI_SS_SOUNDTAB       0x108
#define AOWL_SUI_SS_CONTROLSTAB    0x110

/* SettingsTab.
 *
 * PHASE 1.6 -- 0x88 CONFIRMED AGAINST COMPILED CODE, and confirmed to be a BASE
 * field. `SettingsTab::CleanupCreatedControls` (0x171BE50) is declared on the
 * base and used by every derived tab, and it reads `mov r9, [rdi+0x88]`.
 * `SettingsTab::Close` (0x171BDF0) tests the same `[rcx+0x88]`. IL2CPP lays base
 * fields first under single inheritance, so GameSettingsTab /
 * GraphicsSettingsTab / PostFXSettingsTab / SoundSettingsTab /
 * ControlSettingsTab ALL carry it here despite their differing klass pointers.
 * The live "reads null" was never a per-type layout difference -- it was timing.
 *
 * 0x90 is the first-select latch that gates creation: OnTabSelected tests it,
 * sets it, and calls OnFirstSelect (-> CreateControls -> the generic
 * CreateControl<T>, which is what actually allocates and fills the 0x88 list);
 * Close resets it to 0. So the list is null until the tab is SELECTED, and the
 * probe walks it from OnTabSelected's POSTFIX. */
#define AOWL_SUI_TAB_CREATEDCTRLS  0x088
#define AOWL_SUI_TAB_FIRSTSELECTED 0x090

/* List<T> raw layout + array element base. */
#define AOWL_SUI_LIST_ITEMS        0x010
#define AOWL_SUI_LIST_SIZE         0x018
#define AOWL_SUI_ARR_ELEMS         0x020

/* SettingControl. */
#define AOWL_SUI_CTRL_TEXT         0x080
#define AOWL_SUI_CTRL_VALUE        0x0A8

/* LocalizedText wrapper + TextMeshProUGUI text-backing string. */
#define AOWL_SUI_LOCTEXT_LIST      0x078
#define AOWL_SUI_TMP_MTEXT         0x0E0

/* ESettingsGroup -> the typed tab field the game itself loads for that group.
 *
 * NOT guessed: read straight off `SettingsScreen::EnsureTabInitialized`
 * (0x171FF10), whose body is a 5-way switch on the group argument and whose
 * arms load exactly these offsets (see the target comment in
 * `aowlspt_bridge.h`). That agreement between the metadata field offsets above
 * and the compiled code is an independent confirmation of both.
 *
 *   0 graphics -> 0x0F8   1 game -> 0x0F0   2 sound -> 0x108
 *   3 controls -> 0x110   4 postfx -> 0x100
 *
 * Returns -1 for a group outside 0..4, which the probe treats as "walk nothing"
 * rather than reading a made-up offset. */
static int32_t aowl_sui_group_tab_offset(int32_t group) {
    switch (group) {
    case 0: return AOWL_SUI_SS_GRAPHICSTAB;
    case 1: return AOWL_SUI_SS_GAMETAB;
    case 2: return AOWL_SUI_SS_SOUNDTAB;
    case 3: return AOWL_SUI_SS_CONTROLSTAB;
    case 4: return AOWL_SUI_SS_POSTFXTAB;
    default: return -1;
    }
}

/* The same mapping's human name, for the log line. "?" outside 0..4. */
static const char* aowl_sui_group_name(int32_t group) {
    switch (group) {
    case 0: return "graphics";
    case 1: return "game";
    case 2: return "sound";
    case 3: return "controls";
    case 4: return "postfx";
    default: return "?";
    }
}

/* How many ESettingsGroup values this mapping covers -- the probe uses it to
 * size its "logged this group already" bitset. */
#define AOWL_SUI_GROUP_COUNT 5
static int32_t aowl_sui_group_count(void) { return AOWL_SUI_GROUP_COUNT; }

/* Accessors (importc'd by the Nim probe). Individual functions rather than a
 * table so a fault names the exact hop and the header stays self-documenting. */
static int32_t aowl_sui_off_currenttab(void)  { return AOWL_SUI_SS_CURRENTTAB; }
static int32_t aowl_sui_off_gametab(void)      { return AOWL_SUI_SS_GAMETAB; }
static int32_t aowl_sui_off_graphicstab(void)  { return AOWL_SUI_SS_GRAPHICSTAB; }
static int32_t aowl_sui_off_postfxtab(void)    { return AOWL_SUI_SS_POSTFXTAB; }
static int32_t aowl_sui_off_soundtab(void)     { return AOWL_SUI_SS_SOUNDTAB; }
static int32_t aowl_sui_off_controlstab(void)  { return AOWL_SUI_SS_CONTROLSTAB; }
static int32_t aowl_sui_off_createdctrls(void) { return AOWL_SUI_TAB_CREATEDCTRLS; }
static int32_t aowl_sui_off_firstselected(void) { return AOWL_SUI_TAB_FIRSTSELECTED; }
static int32_t aowl_sui_off_list_items(void)   { return AOWL_SUI_LIST_ITEMS; }
static int32_t aowl_sui_off_list_size(void)    { return AOWL_SUI_LIST_SIZE; }
static int32_t aowl_sui_off_arr_elems(void)    { return AOWL_SUI_ARR_ELEMS; }
static int32_t aowl_sui_off_ctrl_text(void)    { return AOWL_SUI_CTRL_TEXT; }
static int32_t aowl_sui_off_ctrl_value(void)   { return AOWL_SUI_CTRL_VALUE; }
static int32_t aowl_sui_off_loctext_list(void) { return AOWL_SUI_LOCTEXT_LIST; }
static int32_t aowl_sui_off_tmp_mtext(void)    { return AOWL_SUI_TMP_MTEXT; }

#endif /* AOWLSPT_SETTINGSUI_H */
