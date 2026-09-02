/* aowlspt_premenu.h -- autoraid's PRE-MENU dismissal of an overlaying screen.
 *
 * WHY THIS EXISTS
 * ---------------
 * MEASURED 2026-09-02 on the live client (1.1.0.1.46777): `raid Woods` issued
 * while the Settings screen was open sat in autoraid's WAIT-MENU for the full
 * 180 s bound. The census autoraid now prints on a refusal said exactly why:
 *
 *   Common UI active(depth<=2)=3: [Common UI][SettingsScreen][ChatScreen]
 *   Menu UI   active(depth<=2)=2: [UI][Operation Queue Indicator]
 *
 * MenuScreen was found and its PlayButton was found, but INACTIVE, because
 * SettingsScreen was over it. An inactive control is not pressable (fact #72),
 * so the machine was correct to refuse -- it simply had no way to clear the
 * overlay. The inspector's `pressname BackButton` does NOT close Settings: it
 * searches all 16 roots and refuses (fact #243).
 *
 * THE ROUTE, AND WHY IT IS NOT A NAME SEARCH
 * ------------------------------------------
 * `EFT.UI.Settings.SettingsScreen::Close()` is the screen's OWN close path.
 * Resolved OFFLINE (tools/il2cpp_resolve.py, GameAssembly.dll + the decrypted
 * metadata), never by a runtime name lookup -- a by-name lookup goes through a
 * token-gated il2cpp export whose failure mode is a plausible RANDOM value.
 *
 *   EFT.UI.Settings.SettingsScreen::Close()   RVA 0x1720B10
 *     arity   0            (so: RCX = this, RDX = MethodInfo*, nothing else)
 *     shared  UNIQUE, owners=1   (`il2cpp_resolve.py shared 0x1720b10`)
 *     section il2cpp       (generated method code is NOT in .text)
 *     bytes   40 53 | 48 83 EC 20 | 80 3D 02 D9 99 05 00 | 48 8B D9
 *             push rbx ; sub rsp,0x20 ; cmp byte [rip+0x0599D902],0 ; mov rbx,rcx
 *
 * The window contains a RIP-relative operand. That is irrelevant here and is
 * recorded so nobody has to rediscover it: this target is only ever CALLED,
 * never detoured, so nothing relocates those bytes. It would matter a great
 * deal to anyone who tried to steal them.
 *
 * HONEST HAZARD, not glossed: `Close` is PUBLIC|VIRTUAL. A direct call at the
 * RVA runs THIS body even for a derived receiver that overrides it. The
 * receiver passed is whatever `GetComponent("SettingsScreen")` returns off the
 * live screen object, so if this build ever puts a SUBCLASS there, this call
 * runs the base body. That is why the caller does NOT believe its own call:
 * it asserts the FINISHED STATE afterwards (no ACTIVE SettingsScreen), and
 * falls back to pressing the screen's own Back button through the already
 * verified `UnityEngine.UI.Button::Press` if the state did not change.
 *
 * SAFETY
 * ------
 *   * VirtualQuery + MEM_COMMIT + an executable protection BEFORE the compare,
 *     so a stale RVA on an uncommitted page cannot fault inside `memcmp`;
 *   * a 16-byte compare against the STARTUP SNAPSHOT (aowlspt_prologue.h),
 *     never against live memory -- verifying against live memory reads another
 *     feature's trampoline and self-rejects;
 *   * "the snapshot table was full" is counted APART from "the bytes differ",
 *     because only the second says anything about the client;
 *   * a NULL fn or a NULL receiver calls nothing at all.
 */
#ifndef AOWLSPT_PREMENU_H
#define AOWLSPT_PREMENU_H

#include <windows.h>
#include <stdint.h>

#define AOWL_PMN_SS_CLOSE_RVA    0x1720B10u
#define AOWL_PMN_TOGGLE_SET_RVA  0x55BA450u
#define AOWL_PMN_POINTER_CLICK_RVA 0x14359B0u
#define AOWL_PMN_SHOW_IN_RAID_RVA  0x1539650u
/* DefaultUIButton._button -> TweenAnimatedButton, and that button's own
 * interactable gate. Both from tools/fldoff.py, never guessed. */
#define AOWL_PMN_DUB_BUTTON_OFF   0x108
#define AOWL_PMN_TAB_INTERACT_OFF 0x68

typedef struct AowlPmnTarget {
    const char*   name;
    uint32_t      rva;
    unsigned char sig[16];
    int32_t       siglen;
} AowlPmnTarget;

static const AowlPmnTarget aowl_pmn_targets[] = {
    /* [0] EFT.UI.Settings.SettingsScreen::Close() -- CALLED, never detoured. */
    { "EFT.UI.Settings.SettingsScreen::Close", AOWL_PMN_SS_CLOSE_RVA,
      { 0x40,0x53, 0x48,0x83,0xEC,0x20,
        0x80,0x3D,0x02,0xD9,0x99,0x05,0x00,
        0x48,0x8B,0xD9 }, 16 },

    /* [1] UnityEngine.UI.Toggle::Set(bool value, bool sendCallback)
     * APPENDED AT THE END. Index 0 keeps its meaning; tools/idxbind.py checks
     * that the Nim constant naming each row still resolves to the row it names.
     *
     * WHY THIS IS HERE, MEASURED 2026-09-02. autoraid pressed an
     * `EFT.UI.AnimatedToggle` by reading a UnityEvent at component+0x100 and
     * calling `UnityEvent::Invoke` on it, which is what `arOnClickOff` returns
     * for every klass that is not a DefaultUIButton. That offset is WRONG for
     * this klass and the client died of it, twice, deterministically, on the
     * first frame the toggle was found (the SEH guard caught it; the host log
     * says `faulted ... at step SIDE, in: walking the pmc/scav containers and
     * pressing`).
     *
     * `EFT.UI.AnimatedToggle` derives from `UnityEngine.UI.Toggle`, whose
     * layout (tools/fldoff.py, offline) is
     *      0x100  toggleTransition   ToggleTransition   <- AN ENUM, not an event
     *      0x108  graphic            Graphic
     *      0x110  m_Group            ToggleGroup
     *      0x118  onValueChanged     ToggleEvent        <- the real event
     *      0x120  m_IsOn             bool
     * so +0x100 reads a small integer (0/1/2), which passes a null check, is
     * not a GameObject and is not a known klass -- every guard `arPress` has --
     * and is then CALLED as a UnityEvent. A plausible non-null value that is
     * not a pointer is the worst input those guards can get.
     *
     * So a toggle is now SET through the game's own method instead of having
     * an event fired at a guessed offset:
     *   RVA         0x55BA450   (VA 0x1855BA450)
     *   sharedness  UNIQUE (owners=1)
     *   section     il2cpp
     *   attrs       PRIVATE|HIDEBYSIG -- non-virtual, so a direct call at the
     *               RVA is the only dispatch and there is no override hazard.
     *   arity 2     RCX=this(Toggle), DL=value, R8B=sendCallback, R9=MethodInfo*
     *   bytes  48 89 5C 24 08 | 48 89 74 24 10 | 57 | 48 83 EC 20 | 80
     *          mov [rsp+8],rbx ; mov [rsp+0x10],rsi ; push rdi ; sub rsp,0x20
     *
     * `sendCallback = true` on purpose: the point of pressing the control is to
     * run the handler the screen attached to it. Calling `set_isOn` @0x55BA430
     * instead was considered and rejected -- it is an 11-byte tail-jump thunk
     * into this same body (docs/AOWL_FACTS.md), so it buys nothing and is worse
     * to reason about. */
    { "UnityEngine.UI.Toggle::Set", AOWL_PMN_TOGGLE_SET_RVA,
      { 0x48,0x89,0x5C,0x24,0x08, 0x48,0x89,0x74,0x24,0x10,
        0x57, 0x48,0x83,0xEC,0x20, 0x80 }, 16 },

    /* [2] EFT.UI.TweenAnimatedButton::OnPointerClick(PointerEventData)
     * APPENDED AT THE END. Indices 0 and 1 keep their meaning.
     *
     * THIS IS WHAT A PLAYER CLICKING A CARD ACTUALLY RUNS, and it was DERIVED
     * rather than guessed. The chain, all measured offline on 2026-09-02:
     *
     *   the card control `Apply`  carries  EFT.UI.DefaultUIButton
     *   DefaultUIButton._button  @0x108 -> EFT.UI.TweenAnimatedButton
     *   TweenAnimatedButton._interactable @0x68  (bool)
     *   TweenAnimatedButton.OnClick       @0x70  (an ACTION, not a UnityEvent)
     *   DefaultUIButton.OnClick           @0x120 (the UnityEvent we used to
     *                                             fire DIRECTLY)
     *
     * NEITHER wrapper is a `UnityEngine.UI.Button`: DefaultUIButton derives
     * from EFT.UI.ButtonFeedback and TweenAnimatedButton from
     * Sirenix.OdinInspector.SerializedMonoBehaviour. So `Button::Press`
     * @0x539A7A0 does NOT apply to either -- calling it on one would be the
     * native type confusion this project keeps paying for.
     *
     * THE BODY, 16 bytes, which is why NULL is a safe argument:
     *   80 79 68 00     cmp  byte [rcx+0x68], 0     ; _interactable
     *   74 18           je   +0x18                  ; not interactable -> ret
     *   48 8B 49 70     mov  rcx, [rcx+0x70]        ; the OnClick Action
     *   48 85 C9        test rcx, rcx
     *   74 0F           je   +0x0F                  ; null -> ret
     *   48 ..           (then invokes the Action)
     * The `eventData` argument in RDX is NEVER READ. That is not an assumption
     * about Unity, it is the disassembly of this function: it checks a bool,
     * loads a delegate and invokes it. So passing NULL runs exactly the code a
     * real click runs.
     *
     *   RVA         0x14359B0   (VA 0x1814359B0)
     *   sharedness  UNIQUE (owners=1)
     *   section     il2cpp
     *   attrs       arity 1: RCX=this(TweenAnimatedButton),
     *               RDX=PointerEventData (unread), R8=MethodInfo*
     *
     * WHY IT MATTERS: firing `DefaultUIButton.OnClick` @0x120 directly reaches
     * the same handler but skips this gate, and MEASURED 2026-09-02 that left
     * the profile/mode screen HALF-TRANSITIONED with neither card clickable --
     * a user-visible regression. Going through the button's own entry point
     * also means an INTERACTABLE=false control is a no-op BY CONSTRUCTION
     * rather than something this host has to model. */
    { "EFT.UI.TweenAnimatedButton::OnPointerClick", AOWL_PMN_POINTER_CLICK_RVA,
      { 0x80,0x79,0x68,0x00, 0x74,0x18, 0x48,0x8B,0x49,0x70,
        0x48,0x85,0xC9, 0x74,0x0F, 0x48 }, 16 },

    /* [3] EFT.UI.MenuScreen::ShowInRaid()
     * APPENDED AT THE END. Indices 0..2 keep their meaning.
     *
     * WHY A CALL ROW FOR A FUNCTION WE ALREADY HOOK. MEASURED 2026-09-02: the
     * host logged, at boot, `the in-raid menu show event is LIVE --
     * MenuScreen::ShowInRaid @0x1539650 (uihooks site 7) is bound` -- the
     * DETOUR side verified this exact RVA against this exact prologue -- and
     * then, on arming, `raidExit: MenuScreen::ShowInRaid @0x1539650 did not
     * resolve as callable code on this build -- stopping`.
     *
     * Both statements were true, because they are about DIFFERENT TABLES.
     * `raidexit` resolved the call through the inspector's navigation table
     * (`cInspCode`), which has no row for this RVA; the hook resolved it
     * through `aowl_uih_sites`. A refusal that says "on this build" when it
     * means "in OUR table" points the next reader at the game instead of at
     * us, so this row exists and the refusal now names the table.
     *
     *   RVA         0x1539650   (VA 0x181539650)
     *   sharedness  UNIQUE (owners=1)
     *   section     il2cpp
     *   arity 0     RCX=this(MenuScreen), RDX=MethodInfo*
     *   48 89 5C 24 08 | 48 89 74 24 10 | 57 | 48 83 EC 20 | 48
     *   -- the SAME 16 bytes site [7] of aowlspt_uihooks.h verifies, so the
     *   two tables cannot disagree about what this function starts with. */
    { "EFT.UI.MenuScreen::ShowInRaid", AOWL_PMN_SHOW_IN_RAID_RVA,
      { 0x48,0x89,0x5C,0x24,0x08, 0x48,0x89,0x74,0x24,0x10,
        0x57, 0x48,0x83,0xEC,0x20, 0x48 }, 16 },
};

#define AOWL_PMN_TARGET_COUNT \
    ((int32_t)(sizeof(aowl_pmn_targets) / sizeof(aowl_pmn_targets[0])))

#define AOWL_PMN_T_SS_CLOSE   0
#define AOWL_PMN_T_TOGGLE_SET 1
#define AOWL_PMN_T_POINTER_CLICK 2
#define AOWL_PMN_T_SHOW_IN_RAID  3

static int32_t aowl_pmn_verified = 0;
static int32_t aowl_pmn_rejected = 0;
static int32_t aowl_pmn_profull  = 0;

static void* aowl_pmn_fn(int32_t i) {
    HMODULE ga;
    const AowlPmnTarget* t;
    unsigned char* p;
    MEMORY_BASIC_INFORMATION mbi;
    if (i < 0 || i >= AOWL_PMN_TARGET_COUNT) return NULL;
    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) return NULL;
    t = &aowl_pmn_targets[i];
    p = (unsigned char*)ga + t->rva;
    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return NULL;
    if (mbi.State != MEM_COMMIT) return NULL;
    if (!(mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)))
        return NULL;
    if (t->siglen > 0 && !aowl_pro_verify(t->rva, t->sig, t->siglen)) {
        if (aowl_pro_last_was_table_full()) { aowl_pmn_profull++; return NULL; }
        aowl_pmn_rejected++;
        return NULL;
    }
    aowl_pmn_verified++;
    return (void*)p;
}

static const char* aowl_pmn_name(int32_t i) {
    if (i < 0 || i >= AOWL_PMN_TARGET_COUNT) return "";
    return aowl_pmn_targets[i].name;
}
static uint32_t aowl_pmn_rva(int32_t i) {
    if (i < 0 || i >= AOWL_PMN_TARGET_COUNT) return 0u;
    return aowl_pmn_targets[i].rva;
}
static int32_t aowl_pmn_target_count(void) { return AOWL_PMN_TARGET_COUNT; }
static int32_t aowl_pmn_ok_count(void)     { return aowl_pmn_verified; }
static int32_t aowl_pmn_bad_count(void)    { return aowl_pmn_rejected; }
static int32_t aowl_pmn_profull_count(void){ return aowl_pmn_profull; }

/* The eager pass. Called from aowl_pro_prime_all at host startup, before any
 * bind exists, so this verify can never be fed another feature's trampoline. */
static void aowl_pmn_prime_all(void) {
    int32_t i;
    for (i = 0; i < AOWL_PMN_TARGET_COUNT; i++)
        aowl_pro_prime(aowl_pmn_targets[i].rva);
}

/* Instance, arity 0: RCX = this, RDX = the hidden trailing MethodInfo*.
 * `Close` is not generic, so a NULL MethodInfo is correct -- the restriction is
 * on SHARED GENERIC code. It is passed EXPLICITLY rather than left to whatever
 * happens to be in RDX. */
typedef void (*AowlPmn_Close)(void*, void*);
static void aowl_pmn_call_close(void* fn, void* screen) {
    if (!fn || !screen) return;
    ((AowlPmn_Close)fn)(screen, NULL);
}

/* Instance, arity 2: RCX = this, DL = value, R8B = sendCallback, R9 = the
 * hidden trailing MethodInfo*. `Set` is not generic, so a NULL MethodInfo is
 * correct; it is passed EXPLICITLY rather than left to whatever is in R9.
 * The bools are widened to uint64 -- the callee reads the low byte of each
 * register, which is exactly what the Win64 convention delivers. */
typedef void (*AowlPmn_ToggleSet)(void*, uint64_t, uint64_t, void*);
static void aowl_pmn_call_toggle_set(void* fn, void* toggle,
                                     int32_t value, int32_t sendCallback) {
    if (!fn || !toggle) return;
    ((AowlPmn_ToggleSet)fn)(toggle, (uint64_t)(value ? 1 : 0),
                            (uint64_t)(sendCallback ? 1 : 0), NULL);
}

/* Instance, arity 1: RCX = this, RDX = the PointerEventData the body never
 * reads (see the row comment -- this is from its disassembly, not an
 * assumption), R8 = the hidden trailing MethodInfo*. Not generic, so NULL is
 * correct, and it is passed explicitly. */
typedef void (*AowlPmn_PointerClick)(void*, void*, void*);
static void aowl_pmn_call_pointer_click(void* fn, void* button) {
    if (!fn || !button) return;
    ((AowlPmn_PointerClick)fn)(button, NULL, NULL);
}

/* Instance, arity 0: RCX = this(MenuScreen), RDX = the hidden trailing
 * MethodInfo*. Not generic, so NULL is correct and it is passed explicitly. */
typedef void (*AowlPmn_ShowInRaid)(void*, void*);
static void aowl_pmn_call_show_in_raid(void* fn, void* menu) {
    if (!fn || !menu) return;
    ((AowlPmn_ShowInRaid)fn)(menu, NULL);
}

static int32_t aowl_pmn_off_dub_button(void)   { return AOWL_PMN_DUB_BUTTON_OFF; }
static int32_t aowl_pmn_off_tab_interact(void) { return AOWL_PMN_TAB_INTERACT_OFF; }

#endif /* AOWLSPT_PREMENU_H */
