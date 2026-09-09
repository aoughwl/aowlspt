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
#define AOWL_UIH_SITE_LOCATION     4
#define AOWL_UIH_SITE_INSURANCE    5
#define AOWL_UIH_SITE_ACCEPT       6
#define AOWL_UIH_SITE_SHOW_IN_RAID 7
#define AOWL_UIH_SITE_SESSION_END  8

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
    /* HOW MANY REGISTER SLOTS THE COMPILED CALL USES: `this` (0 for a
     * static), the declared arguments, and IL2CPP's trailing
     * `MethodInfo*`. Past FOUR they arrive ON THE STACK, and a POSTFIX
     * detour cannot serve them.
     *
     * MEASURED 2026-09-02, and it is the cause of a real crash, not a
     * precaution. The postfix thunk in `aowlspt_detour.h` does
     * `subq $0x98,%rsp` and then `call *tramp`, so the original is
     * entered with a DIFFERENT rsp and reads its fifth argument out of
     * the THUNK'S OWN FRAME. For site [2] that argument is exactly the
     * `Profile`:
     *   R disasm 0x15387A0  ->  0x1538a4f  mov rax,[rsp+0xc0]
     *                                      (= [entry_rsp+0x28], arg 5)
     *                           0x1538a57  mov [r14+0x18],rax
     *                           0x1539126  mov rdx,[r14+0x18]
     *                           0x153912f  call SeasonWidgetData::From
     * and [entry_rsp+0x28] lands on thunk-frame +0x20, the slot the
     * thunk uses to park RAX across the dispatcher call -- not yet
     * written at the moment of the call. That is the `Rcx=1` in the
     * crash dumps: a Profile that is a small integer.
     *
     * `invoke.nim`'s `postfixRefusal` already refuses this shape for a
     * MOD's patch (`PostfixMaxSlots = 4`). `attachDrain` never applied
     * it, so this host bound the one detour its own engine documents as
     * impossible. This column is how uihooks applies it.
     *
     * A site with slots > 4 is bound as a PREFIX instead. The prefix
     * path restores rsp exactly (`addq $0x98,%rsp ; jmp *tramp`), so
     * every stack argument is where the original expects it. */
    int32_t       slots;
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
        0x80,0x3D,0x2F,0x61,0x93,0x05 }, 16, 1, 3 },

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
     *   *** DO NOT WANT THIS SITE WITHOUT NEW EVIDENCE. MEASURED 2026-09-02. ***
     *   A build that subscribed to it -- the first build in this project ever
     *   to BIND it; every surviving build had it unbound -- died on three
     *   consecutive boots, once at MENU ARRIVAL with no Settings and no raid,
     *   in `SeasonWidgetData::From @0x141FFD0+0x133` called from
     *   `MenuScreen::Show(5-arg) @0x15387A0+0x994`, with the host's last log
     *   line being `uihooks: FIRST show event -- EFT.UI.MenuScreen::Awake`.
     *   `Awake` runs immediately before `Show`, and `Show` then read a bad
     *   Profile.
     *
     *   The row is left here, with its RVA and prologue intact, because the
     *   NUMBERS are still correct and deleting it would renumber every site
     *   below it (fact #187). What is NOT established is that the 16 stolen
     *   bytes survive relocation in this function's real control flow: the
     *   sharedness is UNIQUE and the shape looks benign, and it still killed
     *   the client three times. Prologue arithmetic that "looks benign" is not
     *   a measurement. Anyone who wants this site again owes a bisect that
     *   shows a boot surviving WITH it bound, not a re-reading of these bytes.
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
        0x80,0x3D,0x2D,0x55,0xB8,0x05,0x00, 0x48,0x8B,0xD9 }, 16, 1, 2 },

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
        0x48,0x89,0x4C,0x24,0x08, 0x57 }, 16, 1, 7 },

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
        0x80,0x3D,0x79,0xE5,0x92,0x05 }, 16, 1, 3 },

    /* [4] EFT.UI.Matchmaker.MatchMakerSelectionLocationScreen::Show(
     *         SelectionLocationScreenController controller)
     *
     * APPENDED AT THE END, like [3]: every index here is positional.
     *
     * MEASURED 2026-09-02: the side selector's own NextButton lands DIRECTLY on
     * the location list -- autoraid pressed it, read back
     * `the MatchMakerSideSelectionScreen is no longer active`, and then its
     * NEXT->location step timed out with the census showing
     * `Menu UI active(depth<=2)=3: [UI][Matchmaker Location Selection]
     *  [Operation Queue Indicator]`. There is no NEXT to press to REACH that
     * screen; it is already up. So its arrival is an event, and this is it.
     *
     * NOTE THE TYPE NAME'S WORD ORDER: `MatchMakerSelectionLocationScreen`,
     * not `...LocationSelectionScreen`. Searching the metadata for
     * "LocationSelection" finds only a compiler-generated coroutine class
     * (`<ShowMatchmakerLocationSelection>d__58`) and would read as absent.
     *
     *   RVA         0x178ACB0   (VA 0x18178ACB0)
     *   sharedness  UNIQUE (owners=1)  -- safe to DETOUR, not merely to call
     *   section     il2cpp
     *   attrs       the 1-arg controller overload, the same shape as [0]/[3];
     *               the type also declares a 3-arg Show @0x178AD40.
     *   arity 1     RCX=this(MatchMakerSelectionLocationScreen)
     *               RDX=SelectionLocationScreenController
     *               R8 =MethodInfo* (NULL ok -- not generic)
     *
     *   48 89 5C 24 08     mov  [rsp+0x08], rbx        (5)
     *   57                 push rdi                    (1) -> 6
     *   48 83 EC 30        sub  rsp, 0x30              (4) -> 10
     *   80 3D 22 3A 93 05 00  cmp byte [rip+0x05933A22], 0 (7) -> 17
     *
     *   BYTE-FOR-BYTE THE SAME SHAPE AS [0] AND [3]: 17-byte steal, and the
     *   only relative operand is the RIP-relative displacement of the `cmp`,
     *   which `aowl_copy_relocated` fixes up. No relative BRANCH is cut, so
     *   relocatable=1 for exactly the same reason. */
    { "EFT.UI.Matchmaker.MatchMakerSelectionLocationScreen::Show", 0x178ACB0u,
      { 0x48,0x89,0x5C,0x24,0x08, 0x57, 0x48,0x83,0xEC,0x30,
        0x80,0x3D,0x22,0x3A,0x93,0x05 }, 16, 1, 3 },

    /* [5] EFT.UI.Matchmaker.MatchmakerInsuranceScreen::Show(
     *         InsuranceScreenController controller)
     *   RVA 0x1769910, UNIQUE (owners=1), section il2cpp, arity 1,
     *   RCX=this, RDX=controller, R8=MethodInfo*.
     *   48 89 5C 24 08 | 57 | 48 83 EC 30 | 80 3D E8 4C 95 05 00
     *   The SAME prologue shape as [0], [3] and [4] -- 17-byte steal whose only
     *   relative operand is the RIP-relative `cmp`. relocatable=1.
     *
     * [6] EFT.UI.Matchmaker.MatchMakerAcceptScreen::Show(
     *         MatchmakerAcceptScreenController controller)
     *   RVA 0x1773EF0, UNIQUE (owners=1), section il2cpp, arity 1, same shape:
     *   48 89 5C 24 08 | 57 | 48 83 EC 30 | 80 3D 51 A7 94 05 00
     *
     * BOTH ARE APPENDED, AND BOTH EXIST FOR ONE MEASURED REASON: every screen
     * in this flow is advanced by ITS OWN `ScreenDefaultButtons -> NextButton`,
     * and the only reliable way to reach that button is from the receiver the
     * screen's own ::Show handed us. Three separate 45-second refusals this
     * session (`NEXT->location`, then again after SIDE, then
     * `NEXT->insurance`) were all the same mistake: hunting a NextButton across
     * roots for a screen we had not been handed. */
    { "EFT.UI.Matchmaker.MatchmakerInsuranceScreen::Show", 0x1769910u,
      { 0x48,0x89,0x5C,0x24,0x08, 0x57, 0x48,0x83,0xEC,0x30,
        0x80,0x3D,0xE8,0x4C,0x95,0x05 }, 16, 1, 3 },

    { "EFT.UI.Matchmaker.MatchMakerAcceptScreen::Show", 0x1773EF0u,
      { 0x48,0x89,0x5C,0x24,0x08, 0x57, 0x48,0x83,0xEC,0x30,
        0x80,0x3D,0x51,0xA7,0x94,0x05 }, 16, 1, 3 },

    /* ---- THE EXIT HALF. Appended, like everything above. ----
     *
     * [7] EFT.UI.MenuScreen::ShowInRaid()
     *   RVA 0x1539650, UNIQUE (owners=1), section il2cpp, arity 0,
     *   RCX=this(MenuScreen), RDX=MethodInfo*.
     *   48 89 5C 24 08 | 48 89 74 24 10 | 57 | 48 83 EC 20 | 48
     *   mov [rsp+8],rbx ; mov [rsp+0x10],rsi ; push rdi ; sub rsp,0x20
     *   The first instruction boundary at or past AOWL_JMP_SIZE (14) is 15, and
     *   those 15 bytes contain NO relative operand at all -- not even a
     *   RIP-relative displacement -- so this is a STRICTLY easier relocation
     *   than sites [0]/[3]/[4], the same class as [2].
     *
     *   WHY IT IS A SITE AT ALL, given that raidexit CALLS this method itself:
     *   because the receiver is the thing that is hard to get. MEASURED
     *   2026-09-02: with the client DEPLOYED in Woods, `raidexit` refused after
     *   20 s -- `step SHOW-IN-RAID found nothing` -- because it looks for a
     *   GameObject named `MenuScreen` by walking the enumerated scene roots,
     *   and IN A RAID that enumeration sees the LOCATION scene, not
     *   DontDestroyOnLoad, where the menu lives. A POSTFIX here hands us the
     *   MenuScreen in RCX whenever the menu is shown in raid -- including when
     *   the PLAYER opens it with ESC -- so the receiver is given, not hunted.
     *
     * [8] EFT.UI.SessionEnd.SessionEndUI::Awake()
     *   RVA 0x1726850, UNIQUE (owners=1), section il2cpp, arity 0.
     *   48 89 5C 24 08 | 48 89 74 24 10 | 57 | 48 83 EC 30 | 80
     *   Same 15-byte steal with no relative operand.
     *
     *   THIS ONE IS A CONSTRUCTION EVENT AND IS NAMED AS ONE. `SessionEndUI`
     *   declares only Awake, OnDestroy and .ctor (checked offline), so there is
     *   no ::Show to prefer -- but the object is created per session end, so
     *   its Awake IS its arrival in practice. The honest limit is the same as
     *   site [1]'s: a postfix here proves the body ran, NOT that the results
     *   pages are populated. It is used to OBTAIN THE RECEIVER, never as proof
     *   that anything is ready. */
    { "EFT.UI.MenuScreen::ShowInRaid", 0x1539650u,
      { 0x48,0x89,0x5C,0x24,0x08, 0x48,0x89,0x74,0x24,0x10,
        0x57, 0x48,0x83,0xEC,0x20, 0x48 }, 16, 1, 2 },

    { "EFT.UI.SessionEnd.SessionEndUI::Awake", 0x1726850u,
      { 0x48,0x89,0x5C,0x24,0x08, 0x48,0x89,0x74,0x24,0x10,
        0x57, 0x48,0x83,0xEC,0x30, 0x80 }, 16, 1, 2 },
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

/* The i'th site's compiled register-slot count. uihooks.nim reads this to
 * decide PREFIX vs POSTFIX; > 4 means the call has stack arguments and a
 * postfix would feed the original garbage for them. Answers -1 for a bad
 * index rather than a plausible number. */
static int32_t aowl_uih_site_slots(int32_t i) {
    if (i < 0 || i >= AOWL_UIH_SITE_COUNT) return -1;
    return aowl_uih_sites[i].slots;
}

/* Committed-and-readable (optionally executable) for `n` bytes, wholly
 * inside ONE region. Used by the two readers below; nothing here ever
 * dereferences a pointer this has not passed. */
static int aowl_uih_readable(const void* p, size_t n, int wantExec) {
    MEMORY_BASIC_INFORMATION mbi;
    const unsigned char* c = (const unsigned char*)p;
    if (!p) return 0;
    if ((uintptr_t)p < 0x10000u) return 0;
    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return 0;
    if (mbi.State != MEM_COMMIT) return 0;
    if (mbi.Protect & (PAGE_NOACCESS | PAGE_GUARD)) return 0;
    if (c + n > (const unsigned char*)mbi.BaseAddress + mbi.RegionSize)
        return 0;
    if (wantExec && !(mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ |
                                     PAGE_EXECUTE_READWRITE |
                                     PAGE_EXECUTE_WRITECOPY)))
        return 0;
    return 1;
}

/* THE STACK-ARGUMENT READER. PREFIX firings only.
 *
 * `regs` is the `AowlRegs` the thunk hands the dispatcher. The thunk
 * (aowlspt_detour.h) does `subq $0x98,%rsp` on entry and passes
 * `leaq 0x40(%rsp),%rdx` as `regs`, so
 *     entry_rsp == (char*)regs - 0x40 + 0x98 == (char*)regs + 0x58
 * and the original was entered with THAT rsp, because a prefix is
 * reached by a JMP from the patched prologue and not by a CALL.
 *
 * Win64: [entry_rsp] is the return address, [entry_rsp+8 .. +0x20) is
 * the home space for RCX/RDX/R8/R9, and the FIFTH argument is at
 * [entry_rsp+0x28]. CONFIRMED against site [2]'s own body, which after
 * `sub rsp,0x98` reads its `profile` at `[rsp+0xc0]` == [entry_rsp+0x28]
 * (R disasm 0x15387A0, instruction 0x1538a4f).
 *
 * THE CHECK THAT CAN FAIL: the qword at [entry_rsp] must be a committed
 * EXECUTABLE address. If the frame arithmetic above ever stops matching
 * the thunk -- someone changes the 0x98, or moves where `regs` points --
 * that word is not a return address and this REFUSES rather than
 * handing back a plausible pointer. `*ok` is 0 on refusal and 1 on
 * success; the value is never invented.
 *
 * `k` is 0 for the fifth argument slot, 1 for the sixth, and so on. */
#define AOWL_UIH_REGS_TO_ENTRY_RSP 0x58

static void* aowl_uih_stack_arg(void* regs, int32_t k, int32_t* ok) {
    unsigned char* entry;
    void* ret;
    if (ok) *ok = 0;
    if (!regs || k < 0 || k > 7) return 0;
    entry = (unsigned char*)regs + AOWL_UIH_REGS_TO_ENTRY_RSP;
    if (!aowl_uih_readable(entry, (size_t)(0x30 + 8 * k), 0)) return 0;
    ret = *(void**)entry;
    if (!aowl_uih_readable(ret, 1, 1)) return 0;   /* the falsifiable one */
    if (ok) *ok = 1;
    return *(void**)(entry + 0x28 + 8 * k);
}

/* Is `p` shaped like a live managed object? Three answers, never two:
 *   0  NULL -- a legal argument value, not a fault
 *   1  PLAUSIBLE -- readable, and its first qword (the Il2CppClass*) is
 *      itself readable
 *   2  IMPLAUSIBLE -- a small integer, or unreadable, or a klass slot
 *      that does not read back
 *
 * This deliberately does NOT claim the klass IS `EFT.Profile`.
 * `il2cpp_object_get_class` is `mov rax,[rcx]; ret`, so it answers a
 * plausible number for a bad pointer instead of failing, and
 * `il2cpp_class_get_name` is token-gated. A type NAME printed here would
 * be an invention. Identity is established instead by uihooks comparing
 * the klass POINTER against the one seen on the first good firing.
 *
 * The integer 1 from the crash dumps answers 2. */
static int32_t aowl_uih_obj_shape(void* p) {
    void* klass;
    if (!p) return 0;
    if (!aowl_uih_readable(p, 8, 0)) return 2;
    klass = *(void**)p;
    if (!aowl_uih_readable(klass, 8, 0)) return 2;
    return 1;
}

/* The Il2CppClass* of a PLAUSIBLE object, else NULL. Nothing here
 * dereferences it any further. */
static void* aowl_uih_obj_klass(void* p) {
    if (aowl_uih_obj_shape(p) != 1) return 0;
    return *(void**)p;
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
