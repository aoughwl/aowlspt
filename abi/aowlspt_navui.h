/* aowlspt_navui.h -- UI NAVIGATION TARGETS for the live inspector.
 *
 * The inspector could already READ the running game. These are the first
 * targets that let it DRIVE it: open the settings screen, select a tab. The
 * point is to remove the human step from "open settings, pick the Game tab,
 * look at what appeared" -- a loop that otherwise costs somebody's attention
 * every single time a question is asked.
 *
 * WHY CALL THE GAME'S OWN METHODS RATHER THAN SYNTHESISE INPUT
 * -----------------------------------------------------------
 * A synthetic click has to land on the right screen-space pixel of the right
 * control in the right frame, and it silently does nothing when any of those
 * is wrong. Calling `ShowScreen` / `set_IsSelected` is deterministic, it is
 * the same entry point the game's own button handlers use, and it either runs
 * or faults visibly. The whole design of this instrument is that a failure is
 * loud; a missed click is the opposite of that.
 *
 * PROVENANCE OF EVERY BYTE BELOW
 * ------------------------------
 * These prologues were read directly out of `GameAssembly.dll` at the stated
 * RVAs, via the PE section table (RVA -> file offset), NOT copied from a doc.
 * The reader was validated in the same pass against two targets whose
 * signatures are already baked into `aowlspt_debugui.h`:
 *
 *   Canvas::get_renderMode   @0x5584080  40 53 48 83 EC 20 48 8B 05 73 3E B5 01 48 8B D9
 *   Canvas::get_sortingOrder @0x5584540  40 53 48 83 EC 20 48 8B 05 23 3A B5 01 48 8B D9
 *
 * both of which matched the header byte-for-byte. A reader that reproduces two
 * known answers exactly is a reader whose new answers can be trusted.
 *
 * The same pass also confirmed, as a control, that
 * `TMP_Text::ForceMeshUpdate` @0x628110 begins `C2 00 00` -- `ret 0`, a stub
 * that does nothing. That is why this file carries a SHAPE CHECK as well as a
 * signature check: on UnityEngine and TMP types, "the RVA resolves" is not the
 * same as "the function does anything", and calling a stub is a silent no-op
 * that looks exactly like a failed navigation.
 *
 * Both functions below open with a real register-save prologue
 * (`mov [rsp+x], reg` ...), which is a genuine compiled body -- not a stub
 * (`ret`/`ret n`), and not the IL2CPP internal-call shape
 * (`mov rax,[rip+...]` into a cached native pointer) that the Canvas property
 * getters have. That distinction matters: an icall dereferences the native
 * half of a UnityEngine.Object and faults inside Unity's C++ if that half is
 * gone, which is a fault nothing on our side can guard.
 *
 * VERIFICATION GOES THROUGH THE SNAPSHOT
 * --------------------------------------
 * `aowl_pro_verify` (aowlspt_prologue.h), never a live compare, so that a
 * target another feature has already detoured cannot self-reject. Neither of
 * these is detoured today; that is a property of today's feature set and not
 * a guarantee, which is exactly why it goes through the snapshot anyway.
 */

#ifndef AOWLSPT_NAVUI_H
#define AOWLSPT_NAVUI_H

#include <windows.h>
#include <stdint.h>
#include <string.h>

/* ---- field offsets on EFT.UI.SettingsScreen / SettingsTab ---- */
#define AOWL_NAV_SS_CURRENTTAB   0x118  /* SettingsScreen._currentTab    ptr  */
#define AOWL_NAV_SS_INITTABS     0x138  /* SettingsScreen._initializedTabs ptr*/
#define AOWL_NAV_TAB_FIRSTSEL    0x090  /* SettingsTab first-select latch     */
#define AOWL_NAV_TAB_CREATED     0x088  /* SettingsTab._createdControls  ptr  */

static int32_t aowl_nav_off_currenttab(void) { return AOWL_NAV_SS_CURRENTTAB; }
static int32_t aowl_nav_off_inittabs(void)   { return AOWL_NAV_SS_INITTABS;   }
static int32_t aowl_nav_off_firstsel(void)   { return AOWL_NAV_TAB_FIRSTSEL;  }
static int32_t aowl_nav_off_created(void)    { return AOWL_NAV_TAB_CREATED;   }

typedef struct AowlNavTarget {
    const char*         name;
    uint32_t            rva;
    const unsigned char sig[24];
    int32_t             siglen;
} AowlNavTarget;

static const AowlNavTarget aowl_nav_targets[] = {
    /* EFT.UI.SettingsScreen::ShowScreen -- rcx = screen, edx = group.
     * The selected tab lands at [rcx+0x118] some frames later, which is why
     * the inspector has an `until` primitive: this returns long before the
     * screen it asked for actually exists.
     * NOTE: this function exits by TAIL-JUMP. It is only ever CALLED here,
     * never detoured, so that does not matter to us -- but it would matter a
     * great deal to anyone who tried to postfix it, and it is recorded here so
     * that person does not have to rediscover it. */
    { "EFT.UI.SettingsScreen::ShowScreen", 0x1720DE0u,
      { 0x48,0x89,0x5C,0x24,0x08,
        0x48,0x89,0x74,0x24,0x10,
        0x57,
        0x48,0x83,0xEC,0x30,
        0x80 }, 16 },

    /* EFT.UI.SettingsTab::set_IsSelected -- rcx = tab, dl = value.
     * An ordinary `ret`, so it is safe to call and would be safe to detour.
     * Selecting a tab for the FIRST time runs OnFirstSelect (vtable slot 25,
     * [rdx+0x2C8]) -> CreateControls -> SettingsTab::CreateControl<T>, which
     * is what populates _createdControls at +0x88. So the first select costs
     * frames and later ones do not -- another reason to verify with `state`
     * rather than assume. */
    { "EFT.UI.SettingsTab::set_IsSelected", 0x171BCA0u,
      { 0x48,0x89,0x5C,0x24,0x10,
        0x56,
        0x48,0x83,0xEC,0x20,
        0x48,0x8B,0x05,0x37,0x88,0x9B }, 16 },

    /* ---- DOWNWARD TRAVERSAL. The inspector could only walk UP a parent
     * chain, which means that from any known object it could never reach a
     * BUTTON -- and so could never click anything. These two are what turn it
     * from a viewer into a harness.
     *
     * Resolved from the DECRYPTED metadata (see docs/METADATA-DECRYPT.md) and
     * then read back out of GameAssembly.dll twice, independently, before
     * being written here. */

    /* UnityEngine.Transform::GetChild(int) -- rcx = transform, edx = index.
     * A real body that forwards to an icall, so the native half must be
     * checked before calling. Returns a Transform. */
    { "UnityEngine.Transform::GetChild", 0x52BA180u,
      { 0x48,0x89,0x5C,0x24,0x08,
        0x57,
        0x48,0x83,0xEC,0x20,
        0x48,0x8B,0x05,0x6F,0xAA,0xE1 }, 16 },

    /* UnityEngine.Transform::get_childCount -- rcx = transform.
     * INTERNAL CALL shape (`mov rax,[rip+..]` into a cached native pointer).
     * It dereferences m_CachedPtr at +0x10 and faults inside Unity's C++ if
     * that is null, which is unguardable from our side -- hence the liveness
     * check every caller here performs first. */
    { "UnityEngine.Transform::get_childCount", 0x52B9CA0u,
      { 0x40,0x53,
        0x48,0x83,0xEC,0x20,
        0x48,0x8B,0x05,0x03,0xAF,0xE1,0x01,
        0x48,0x8B,0xD9 }, 16 },

    /* ---- ACTIVATION. Two routes, deliberately.
     *
     * `Button::Press` is the game's OWN path: it re-checks IsActive and
     * IsInteractable itself and then fires m_OnClick, exactly as a real click
     * does. That is what `click` uses, because reproducing the game's path is
     * always safer than reproducing its effect.
     *
     * `UnityEvent::Invoke` fires a UnityEvent directly, skipping those checks.
     * That is what `invoke` uses, for the case where a control is deliberately
     * non-interactable but the handler still needs to run. Two commands rather
     * than one flag, so the log says which was used. */
    { "UnityEngine.UI.Button::Press", 0x539A7A0u,
      { 0x40,0x53,
        0x48,0x83,0xEC,0x20,
        0x80,0x3D,0xCC,0xC5,0xD3,0x01,0x00,
        0x48,0x8B,0xD9 }, 16 },

    { "UnityEngine.Events.UnityEvent::Invoke", 0x52C34A0u,
      { 0x48,0x89,0x5C,0x24,0x18,
        0x48,0x89,0x6C,0x24,0x20,
        0x57,
        0x48,0x83,0xEC,0x20,
        0x80 }, 16 },
};

/* ---- FIELD OFFSETS, corroborated by the accessors' own inlined bodies.
 *
 * These are not guesses from a dump; each one is confirmed by disassembling
 * the property getter, which on this build is inlined to a single load:
 *
 *   Button::get_onClick          @0x691570  48 8B 81 00 01 00 00 C3
 *                                           mov rax,[rcx+0x100]; ret
 *   Selectable::get_interactable @0x7DC330  0F B6 81 D8 00 00 00 C3
 *                                           movzx eax,byte [rcx+0xD8]; ret
 *   Toggle::get_isOn             @0x66E7C0  0F B6 81 20 01 00 00 C3
 *                                           movzx eax,byte [rcx+0x120]; ret
 *
 * A getter that IS the field read is the strongest possible evidence for an
 * offset, and it means the inspector can read all three with NO CALL AT ALL --
 * no icall, no native dereference, nothing that can fault inside Unity. */
#define AOWL_NAV_BTN_ONCLICK     0x100  /* Button.m_OnClick -> UnityEvent    */
#define AOWL_NAV_SEL_INTERACT    0x0D8  /* Selectable.m_Interactable  bool   */
#define AOWL_NAV_TOG_ISON        0x120  /* Toggle.m_IsOn              bool   */
#define AOWL_NAV_TOG_ONVALUE     0x118  /* Toggle.onValueChanged -> event    */
#define AOWL_NAV_UOBJ_CACHEDPTR  0x010  /* UnityEngine.Object.m_CachedPtr    */

static int32_t aowl_nav_off_onclick(void)   { return AOWL_NAV_BTN_ONCLICK;    }
static int32_t aowl_nav_off_interact(void)  { return AOWL_NAV_SEL_INTERACT;   }
static int32_t aowl_nav_off_ison(void)      { return AOWL_NAV_TOG_ISON;       }
static int32_t aowl_nav_off_onvalue(void)   { return AOWL_NAV_TOG_ONVALUE;    }
static int32_t aowl_nav_off_cachedptr(void) { return AOWL_NAV_UOBJ_CACHEDPTR; }

#define AOWL_NAV_TARGET_COUNT \
    ((int32_t)(sizeof(aowl_nav_targets) / sizeof(aowl_nav_targets[0])))

static int32_t aowl_nav_stub_rejects = 0;

/* Is this code a do-nothing stub? `C3` (ret) or `C2 xx xx` (ret n) as the very
 * first instruction means calling it accomplishes nothing. TMP's
 * ForceMeshUpdate @0x628110 is exactly this. A stub that passes a signature
 * check is the worst kind of target: every call "succeeds" and nothing
 * happens, which is indistinguishable from a click that missed. */
static int32_t aowl_nav_is_stub(const unsigned char* p) {
    if (p[0] == 0xC3) return 1;
    if (p[0] == 0xC2) return 1;
    return 0;
}

/* WHY A VERIFY FAILURE MUST NAME ITSELF.
 *
 * `aowl_nav_verify` has five independent ways to say no, and the first version
 * of this file collapsed all of them into a single NULL. The caller then
 * printed "did not verify on this build (or is a stub)" -- a message that
 * covers a wrong RVA, an unmapped page, a non-executable page, a genuine
 * signature mismatch and a stub, and distinguishes none of them. That is
 * precisely the shape of message that has cost this project a full
 * deploy/launch cycle every time it has appeared.
 *
 * So the reason is recorded, and so are the bytes actually found, and the
 * caller prints both. One run now answers what previously took several. */
#define AOWL_NAV_OK          0
#define AOWL_NAV_NO_MODULE   1
#define AOWL_NAV_NO_QUERY    2
#define AOWL_NAV_NOT_COMMIT  3
#define AOWL_NAV_NOT_EXEC    4
#define AOWL_NAV_SIG_MISMATCH 5
#define AOWL_NAV_STUB        6

static int32_t       aowl_nav_reason = AOWL_NAV_OK;
static unsigned char aowl_nav_actual[AOWL_PRO_MAX_BYTES];
static int32_t       aowl_nav_actual_ok = 0;

static void* aowl_nav_verify(uint32_t rva, const unsigned char* sig,
                             int32_t siglen) {
    HMODULE ga;
    unsigned char* p;
    MEMORY_BASIC_INFORMATION mbi;

    aowl_nav_reason = AOWL_NAV_OK;
    aowl_nav_actual_ok = 0;

    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) { aowl_nav_reason = AOWL_NAV_NO_MODULE; return NULL; }
    p = (unsigned char*)ga + rva;

    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) {
        aowl_nav_reason = AOWL_NAV_NO_QUERY; return NULL; }
    if (mbi.State != MEM_COMMIT) {
        aowl_nav_reason = AOWL_NAV_NOT_COMMIT; return NULL; }
    if (!(mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY))) {
        aowl_nav_reason = AOWL_NAV_NOT_EXEC; return NULL; }

    /* Record what is REALLY there, so a mismatch can be shown rather than
     * merely asserted. Safe: the page passed the checks above. */
    memcpy(aowl_nav_actual, p, AOWL_PRO_MAX_BYTES);
    aowl_nav_actual_ok = 1;

    /* THE STUB CHECK READS THE ACTUAL CODE, NOT THE SIGNATURE.
     * The first version tested `sig` -- the bytes we EXPECT -- which can never
     * detect a stub, because a signature copied from a real function never
     * starts with `ret`. The whole point is to catch a target whose LIVE bytes
     * are a stub, so it has to read `p`. */
    if (aowl_nav_is_stub(p)) {
        aowl_nav_stub_rejects++;
        aowl_nav_reason = AOWL_NAV_STUB;
        return NULL;
    }
    /* Against the SNAPSHOT, never live memory. */
    if (siglen > 0 && !aowl_pro_verify(rva, sig, siglen)) {
        aowl_nav_reason = AOWL_NAV_SIG_MISMATCH;
        return NULL;
    }
    return (void*)p;
}

static int32_t aowl_nav_last_reason(void) { return aowl_nav_reason; }
static int32_t aowl_nav_actual_valid(void) { return aowl_nav_actual_ok; }
static int32_t aowl_nav_actual_at(int32_t i) {
    if (i < 0 || i >= AOWL_PRO_MAX_BYTES) return -1;
    return (int32_t)aowl_nav_actual[i];
}
static int32_t aowl_nav_expected_at(int32_t t, int32_t i) {
    if (t < 0 || t >= AOWL_NAV_TARGET_COUNT) return -1;
    if (i < 0 || i >= AOWL_PRO_MAX_BYTES) return -1;
    return (int32_t)aowl_nav_targets[t].sig[i];
}

static void* aowl_nav_target_at(int32_t i) {
    if (i < 0 || i >= AOWL_NAV_TARGET_COUNT) return NULL;
    return aowl_nav_verify(aowl_nav_targets[i].rva,
                           aowl_nav_targets[i].sig,
                           aowl_nav_targets[i].siglen);
}

static const char* aowl_nav_target_name(int32_t i) {
    if (i < 0 || i >= AOWL_NAV_TARGET_COUNT) return "";
    return aowl_nav_targets[i].name;
}

static uint32_t aowl_nav_target_rva(int32_t i) {
    if (i < 0 || i >= AOWL_NAV_TARGET_COUNT) return 0u;
    return aowl_nav_targets[i].rva;
}

static int32_t aowl_nav_target_count(void) { return AOWL_NAV_TARGET_COUNT; }

#endif /* AOWLSPT_NAVUI_H */
