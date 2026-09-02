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

#define AOWL_PMN_SS_CLOSE_RVA 0x1720B10u

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
};

#define AOWL_PMN_TARGET_COUNT \
    ((int32_t)(sizeof(aowl_pmn_targets) / sizeof(aowl_pmn_targets[0])))

#define AOWL_PMN_T_SS_CLOSE 0

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

#endif /* AOWLSPT_PREMENU_H */
