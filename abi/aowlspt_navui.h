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
};

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

static void* aowl_nav_verify(uint32_t rva, const unsigned char* sig,
                             int32_t siglen) {
    HMODULE ga;
    unsigned char* p;
    MEMORY_BASIC_INFORMATION mbi;

    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) return NULL;
    p = (unsigned char*)ga + rva;

    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return NULL;
    if (mbi.State != MEM_COMMIT) return NULL;
    if (!(mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)))
        return NULL;
    /* Against the SNAPSHOT, never live memory. */
    if (siglen > 0 && !aowl_pro_verify(rva, sig, siglen)) return NULL;
    if (aowl_nav_is_stub(sig)) { aowl_nav_stub_rejects++; return NULL; }
    return (void*)p;
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
