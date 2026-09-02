/* aowlspt_uihooks.h -- the SHOW-EVENT site table.
 *
 * WHY THIS EXISTS
 * ---------------
 * Four cosmetic UI features in this host used to find their control by HUNTING
 * for it on a cadence, forever, on the Unity main thread:
 *
 *   * `singleplayerRebrand`  -- re-walked the DontDestroyOnLoad scene roots at
 *     ~10 Hz and died at 64 nodes inside an 18 ms slice, every slice, all
 *     session. (measured, aowlspt-host.log 2026-09-01: "the scan ... was CUT
 *     OFF by the WALL-CLOCK SLICE (18 ms)" repeated at ~100 ms intervals, and
 *     "the CACHED \"Matchmaker Offline Raid Screen\" yielded no targets on 20
 *     consecutive re-scans; dropping the cached screen and re-walking the
 *     scene roots".)
 *   * `uxVersionBrand`       -- 120-frame throttle on the PreloaderUI rider.
 *   * `uxHideSeasons`        -- 120-frame re-check.
 *   * `uxHideModeButton`     -- 4-frame hunt cadence for up to 300 s.
 *
 * Every one of those is looking for something that appears exactly ONCE, on a
 * definite user action. The game already tells us when that action happens:
 * each EFT menu screen has its own `Show` on its own concrete type. A POSTFIX
 * detour there fires exactly when the screen is shown, hands us the live screen
 * object in RCX, and costs NOTHING on any other frame.
 *
 * This is the same shape `settingsui.nim` already uses for the settings screen
 * (`SettingsScreen::ShowScreen` postfix, `aowl_bridge_settingstab_targets`);
 * this header generalises it into a small table so a feature can subscribe to a
 * screen instead of hunting for it.
 *
 * PROVENANCE -- every RVA, signature and sharedness verdict below was produced
 * offline by
 *     python tools/il2cpp_resolve.py D:/Games/Tarkov/GameAssembly.dll \
 *            .cache/global-metadata.dec.dat typemethods|bytes|shared ...
 * on build 1.1.0.1.46777, imagebase 0x180000000. The game was never run to
 * obtain them. Nothing else in this host detours either RVA (grepped).
 *
 * WHY NOT ONE UNIVERSAL HOOK. The obvious candidate is the base-class
 * `EFT.UI.Screens.UIScreen::ShowGameObject(bool)` @0x172E7B0 (UNIQUE, real
 * body). It was REJECTED, not overlooked: identifying WHICH screen was shown
 * from inside it needs the receiver's class, and `il2cpp_object_get_class` is
 * `mov rax,[rcx]; ret` -- it returns a plausible number for a bad pointer
 * rather than failing, which is the worst failure mode available here. A
 * per-screen site needs no type identification at all: the site IS the answer.
 *
 * WHY NOT `ScreenController`2::ShowScreen`. It is an UNINSTANTIATED GENERIC
 * (RVA `None`); a NULL MethodInfo* is not acceptable for shared generics and
 * its per-instantiation code is not reachable offline. See
 * docs/NATIVE_SCREEN_NAV.md sec. 2.
 */
#ifndef AOWLSPT_UIHOOKS_H
#define AOWLSPT_UIHOOKS_H

#include <windows.h>
#include <stdint.h>
#include <string.h>

/* Site ids. These are the ONLY values a feature passes to `uihWant`. */
#define AOWL_UIH_SITE_OFFLINE_RAID 0
#define AOWL_UIH_SITE_MENU_SCREEN  1
#define AOWL_UIH_SITE_MENU_SHOW    2
#define AOWL_UIH_SITE_SIDE_SELECT  3

/* Why the last `aowl_uih_site_at` returned NULL. A refusal must name itself;
 * "returned NULL" is not a diagnosis (CLAUDE.md 6). */
#define AOWL_UIH_R_OK          0
#define AOWL_UIH_R_BAD_INDEX   1
#define AOWL_UIH_R_NO_MODULE   2  /* GameAssembly.dll not loaded yet          */
#define AOWL_UIH_R_UNREADABLE  3  /* not committed / not executable           */
#define AOWL_UIH_R_SIG         4  /* prologue differs from the snapshot below */

typedef struct {
    const char*   name;
    uint32_t      rva;
    unsigned char sig[16];
    int32_t       siglen;
    /* 1 = this site's prologue is known to be RELOCATABLE by
     * `aowl_copy_relocated` (no relative branch inside the stolen bytes).
     * 0 = it is NOT, and `aowl_uih_site_at` refuses it up front rather than
     * letting `aowl_hook_prepare_ex` discover it at bind time. */
    int32_t       relocatable;
} AowlUihSite;

static int32_t aowl_uih_reason = AOWL_UIH_R_OK;

static const AowlUihSite aowl_uih_sites[] = {
    /* [0] EFT.UI.Matchmaker.MatchmakerOfflineRaidScreen::Show(
     *         OfflineRaidScreenController controller)
     *
     *   RVA         0x1788590   (VA 0x181788590)
     *   sharedness  UNIQUE (owners=1)  -- safe to DETOUR, not merely to call
     *   section     il2cpp
     *   attrs       PUBLIC|VIRTUAL|HIDEBYSIG; this is the base-declared entry
     *               point the screen's controller calls to show the screen.
     *   arity 1     RCX=this(MatchmakerOfflineRaidScreen)
     *               RDX=OfflineRaidScreenController
     *               R8 =MethodInfo* (NULL ok -- not generic)
     *
     *   48 89 5C 24 08     mov  [rsp+0x08], rbx        (5)
     *   57                 push rdi                    (1) -> 6
     *   48 83 EC 30        sub  rsp, 0x30              (4) -> 10
     *   80 3D 2F 61 93 05 00  cmp byte [rip+0x593612F], 0  (7) -> 17
     *
     *   AOWL_JMP_SIZE is 14 and the first instruction boundary at or past 14 is
     *   17, so the steal is 17 bytes. The only relative operand in them is the
     *   RIP-relative displacement of the `cmp`, which `aowl_copy_relocated`
     *   fixes up -- exactly like `SettingsScreen::Show` @0x171FA00, which this
     *   host has detoured for months. NO relative BRANCH is cut. */
    { "EFT.UI.Matchmaker.MatchmakerOfflineRaidScreen::Show", 0x1788590u,
      { 0x48,0x89,0x5C,0x24,0x08, 0x57, 0x48,0x83,0xEC,0x30,
        0x80,0x3D,0x2F,0x61,0x93,0x05 }, 16, 1 },

    /* [1] EFT.UI.MenuScreen::Awake()
     *
     *   RVA         0x1538360   (VA 0x181538360)
     *   sharedness  UNIQUE (owners=1)
     *   arity 0     RCX=this(MenuScreen), RDX=MethodInfo*
     *
     *   40 53              push rbx                    (2)
     *   48 83 EC 20        sub  rsp, 0x20              (4) -> 6
     *   80 3D 2D 55 B8 05 00  cmp byte [rip+0x5B8552D], 0 (7) -> 13
     *   48 8B D9           mov  rbx, rcx               (3) -> 16
     *
     *   Byte-for-byte the same SHAPE as `SettingsScreen::Show`: 16-byte steal,
     *   one RIP-relative displacement, no relative branch.
     *
     *   HONEST LIMIT, stated because the name invites the wrong assumption:
     *   `Awake` is a CONSTRUCTION event, not a show event. It fires once per
     *   MenuScreen instantiation, and at postfix time the screen's own children
     *   exist but a child that the screen populates later may not. It is the
     *   right subscription for `uxHideSeasons` / `uxHideModeButton` (which act
     *   on prefab children) PROVIDED the subscriber uses a bounded re-apply
     *   window rather than a single shot -- see docs/UIHOOKS.md.
     *
     *   WHY NOT `MenuScreen::Show(MainMenuBaseScreenController)` @0x1538760,
     *   which would be the true show event: its prologue is
     *       48 83 EC 48        sub  rsp,0x48            (4)
     *       48 85 D2           test rdx,rdx             (3) -> 7
     *       74 31              je   +0x31               (2) -> 9   <-- rel8
     *       48 8B 42 68        mov  rax,[rdx+0x68]      (4) -> 13
     *       4C 8B 4A ..        mov  r9,[rdx+..]         (4) -> 17
     *   The 14-byte steal CUTS ACROSS a `jcc rel8`, which `aowl_copy_relocated`
     *   refuses to relocate (aowlspt_detour.h, "Relative branches"). The bind
     *   would fail safely with "cannot be relocated" -- but a site that can
     *   never bind does not belong in a table of subscribable sites, so it is
     *   documented here and NOT listed. */
    { "EFT.UI.MenuScreen::Awake", 0x1538360u,
      { 0x40,0x53, 0x48,0x83,0xEC,0x20,
        0x80,0x3D,0x2D,0x55,0xB8,0x05,0x00, 0x48,0x8B,0xD9 }, 16, 1 },

    /* [2] EFT.UI.MenuScreen::Show(MatchmakerPlayersController matchmaker,
     *         ExpansionsPlayerInfo expansionsInfo,
     *         GameModeDescriptor modeDescriptor, Profile profile,
     *         SeasonalRewardController seasonalRewardController)
     *
     *   RVA         0x15387A0   (VA 0x1815387A0)
     *   sharedness  UNIQUE (owners=1)  -- safe to DETOUR, not merely to call
     *   section     il2cpp
     *   attrs       PRIVATE|HIDEBYSIG (non-virtual)
     *   arity 5     RCX=this(MenuScreen) ... R9=Profile, 5th on the stack,
     *               then MethodInfo*. We read RCX only.
     *
     *   48 89 5C 24 10     mov  [rsp+0x10], rbx        (5)
     *   48 89 74 24 18     mov  [rsp+0x18], rsi        (5) -> 10
     *   48 89 4C 24 08     mov  [rsp+0x08], rcx        (5) -> 15
     *   57                 push rdi                    (1) -> 16
     *   41 54 41 55 41 56 41 57  push r12..r15         (8) -> 24
     *
     *   AOWL_JMP_SIZE is 14 and the first instruction boundary at or past 14
     *   is 15, so the steal is 15 bytes. Those bytes contain NO relative
     *   operand of any kind -- not even a RIP-relative displacement -- so
     *   `aowl_copy_relocated` has nothing to fix up. This is a STRICTLY
     *   easier relocation than sites [0] and [1].
     *
     *   WHY THIS ONE AND NOT `Show(MainMenuBaseScreenController)` @0x1538760,
     *   which is the public virtual entry point: that one's 14-byte steal cuts
     *   across a `jcc rel8` and cannot be relocated (see [1]'s note). This
     *   PRIVATE 5-arg overload is what the public one calls to actually show
     *   the menu, and it takes the `Profile` -- so it CANNOT run before a
     *   profile has been chosen. That property is why `modload.nim` gates the
     *   deferred mod release on it: it is a real "the main menu is coming up
     *   with a profile" event, not a construction event like [1].
     *
     *   HONEST LIMIT: "the 5-arg Show was entered" is not the same claim as
     *   "the menu is fully laid out and interactive". It is a POSTFIX, so the
     *   body has run, but children the menu populates asynchronously may not
     *   exist yet. It is used here only as an ORDERING fact. */
    { "EFT.UI.MenuScreen::Show(5-arg)", 0x15387A0u,
      { 0x48,0x89,0x5C,0x24,0x10, 0x48,0x89,0x74,0x24,0x18,
        0x48,0x89,0x4C,0x24,0x08, 0x57 }, 16, 1 },

    /* [3] EFT.UI.Matchmaker.MatchMakerSideSelectionScreen::Show(
     *         RaidSideSelectionScreenController controller)
     *
     * APPENDED AT THE END ON PURPOSE. Every index in this table is positional
     * and is named by a constant in uihooks.nim; inserting a row anywhere but
     * the end would silently re-point every site below it (fact #187, and the
     * reason tools/idxbind.py exists).
     *
     * WHY THIS SITE EXISTS -- MEASURED 2026-09-02, live. autoraid pressed PLAY
     * and then refused, and its census said what was really on screen:
     *
     *   Common UI active(depth<=2)=2: [Common UI][ChatScreen]
     *   Menu UI   active(depth<=2)=3: [UI][MatchMaker Side Selection Screen]
     *                                 [Operation Queue Indicator]
     *
     * So the screen after PLAY is the SIDE selector (PMC or SCAV), NOT the
     * boot-time character/slot screen -- the "SELECT YOUR CHARACTER" screenshot
     * was this screen. There is no CharacterSelectionScreen after PLAY at all,
     * which is also why modeskip's ShowSlot postfix never fired for it.
     *
     *   RVA         0x1790180   (VA 0x181790180)
     *   sharedness  UNIQUE (owners=1)  -- safe to DETOUR, not merely to call
     *   section     il2cpp
     *   attrs       PUBLIC|VIRTUAL|HIDEBYSIG -- the base-declared entry point
     *               the screen's controller calls to show it. (The type also
     *               declares a PRIVATE 4-arg Show @0x1790210; this is the
     *               1-arg controller overload, the same shape as site [0].)
     *   arity 1     RCX=this(MatchMakerSideSelectionScreen)
     *               RDX=RaidSideSelectionScreenController
     *               R8 =MethodInfo* (NULL ok -- not generic)
     *
     *   48 89 5C 24 08     mov  [rsp+0x08], rbx        (5)
     *   57                 push rdi                    (1) -> 6
     *   48 83 EC 30        sub  rsp, 0x30              (4) -> 10
     *   80 3D 79 E5 92 05 00  cmp byte [rip+0x0592E579], 0 (7) -> 17
     *
     *   BYTE-FOR-BYTE THE SAME SHAPE AS SITE [0]: AOWL_JMP_SIZE is 14, the
     *   first instruction boundary at or past 14 is 17, so the steal is 17
     *   bytes, and the only relative operand in them is the RIP-relative
     *   displacement of the `cmp`, which `aowl_copy_relocated` fixes up. NO
     *   relative BRANCH is cut, so this is relocatable=1 for exactly the
     *   reason site [0] is. */
    { "EFT.UI.Matchmaker.MatchMakerSideSelectionScreen::Show", 0x1790180u,
      { 0x48,0x89,0x5C,0x24,0x08, 0x57, 0x48,0x83,0xEC,0x30,
        0x80,0x3D,0x79,0xE5,0x92,0x05 }, 16, 1 },
};

#define AOWL_UIH_SITE_COUNT \
    ((int32_t)(sizeof(aowl_uih_sites) / sizeof(aowl_uih_sites[0])))

static int32_t aowl_uih_site_count(void) { return AOWL_UIH_SITE_COUNT; }

static const char* aowl_uih_site_name(int32_t i) {
    if (i < 0 || i >= AOWL_UIH_SITE_COUNT) return "";
    return aowl_uih_sites[i].name;
}

static uint32_t aowl_uih_site_rva(int32_t i) {
    if (i < 0 || i >= AOWL_UIH_SITE_COUNT) return 0u;
    return aowl_uih_sites[i].rva;
}

static int32_t aowl_uih_reason_code(void) { return aowl_uih_reason; }

static const char* aowl_uih_reason_text(int32_t code) {
    switch (code) {
    case AOWL_UIH_R_OK:         return "the prologue matched";
    case AOWL_UIH_R_BAD_INDEX:  return "no such site id (OURS, not the build)";
    case AOWL_UIH_R_NO_MODULE:  return "GameAssembly.dll is not loaded yet "
                                       "(OURS: armed too early)";
    case AOWL_UIH_R_UNREADABLE: return "the RVA is not committed executable "
                                       "memory on this build";
    case AOWL_UIH_R_SIG:        return "the 16 prologue bytes DIFFER from the "
                                       "recorded snapshot -- either another "
                                       "detour already patched this function "
                                       "(a hook-ORDER problem, read the "
                                       "trampoline note in CLAUDE.md sec.5) or "
                                       "this is a different game build";
    default:                    return "unknown";
    }
}

/* The i'th site's verified code pointer, or NULL with `aowl_uih_reason` set.
 * Identical discipline to `aowl_bridge_settings_target_at`: VirtualQuery for
 * committed EXECUTABLE memory, then a 16-byte memcmp of the prologue against
 * the snapshot above. Never patches, never guesses. */
static void* aowl_uih_site_at(int32_t i) {
    HMODULE ga;
    const AowlUihSite* t;
    unsigned char* p;
    MEMORY_BASIC_INFORMATION mbi;

    if (i < 0 || i >= AOWL_UIH_SITE_COUNT) {
        aowl_uih_reason = AOWL_UIH_R_BAD_INDEX; return NULL;
    }
    t = &aowl_uih_sites[i];
    if (!t->relocatable) { aowl_uih_reason = AOWL_UIH_R_SIG; return NULL; }

    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) { aowl_uih_reason = AOWL_UIH_R_NO_MODULE; return NULL; }

    p = (unsigned char*)ga + t->rva;
    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) {
        aowl_uih_reason = AOWL_UIH_R_UNREADABLE; return NULL;
    }
    if (mbi.State != MEM_COMMIT) {
        aowl_uih_reason = AOWL_UIH_R_UNREADABLE; return NULL;
    }
    if (!(mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY))) {
        aowl_uih_reason = AOWL_UIH_R_UNREADABLE; return NULL;
    }
    if (t->siglen > 0 && memcmp(p, t->sig, (size_t)t->siglen) != 0) {
        aowl_uih_reason = AOWL_UIH_R_SIG; return NULL;
    }
    aowl_uih_reason = AOWL_UIH_R_OK;
    return (void*)p;
}

#endif /* AOWLSPT_UIHOOKS_H */
