/* aowlspt_uistate.h -- a MOD-FACING "which blocking UI surface is open" signal.
 *
 * WHY THIS FILE EXISTS
 * --------------------
 * A mod that draws a HUD during a raid (the maps radar, an ESP overlay) has no
 * way to know that a BLOCKING UI surface is up in front of it -- the game's own
 * Settings screen, or one of our overlay panels (F6 admin, F3 debug) -- so it
 * keeps drawing on top of a screen the player is trying to read. The region ABI
 * (`aowlspt_region.h`) exposes no such mask. This file adds one PE export,
 * `aowl_ui_overlay_mask`, that any mod can `GetProcAddress` on
 * `aowlspt-host-il2cpp.dll` and poll each frame.
 *
 * THE MASK
 * --------
 *   bit0  AOWL_UI_OVL_SETTINGS  the GAME's Settings screen is open
 *   bit1  AOWL_UI_OVL_ADMIN     our F6 admin overlay is open
 *   bit2  AOWL_UI_OVL_DEBUG     our F3 debug overlay is open
 *   bit3  AOWL_UI_OVL_OVERLAY   our F12 mod-manager / settings panel is open
 * Higher bits are reserved; a surface whose state cannot be determined reads 0
 * (an honestly-absent signal, never a guessed 1 -- CLAUDE.md 9b).
 *
 * HOW EACH BIT IS SOURCED
 * -----------------------
 * bit1/bit2/bit3 are LEVELS already maintained by the cursor module
 * (`aowlspt_cursor.h`): the overlay DLL publishes F12 (OVERLAY, the mod-manager
 * / settings panel) and F6 (ADMIN) and the host publishes F3 (DEBUGUI) every
 * frame, and a publication expires after `AOWL_CUR_STALE_MS`. We read that union
 * -- no game call, no new detour. bit3 was added because the F12 panel is the
 * one the launch hint tells the player to press ("F12 for Mod Settings"); it is
 * a full-screen blocking surface, yet its cursor bit (AOWL_CUR_P_OVERLAY) was
 * never folded into this mask, so a HUD polling the mask kept drawing over it.
 *
 * bit0 is NOT a level the host already maintained. `gSettingsLiveSelf` is the
 * LAST-KNOWN SettingsScreen `this` (settingsui.nim); it is set on the ShowScreen
 * postfix and is never cleared, so it says "was opened once", NOT "is open now".
 * To answer "is it open NOW" truthfully we read the FINISHED STATE off that
 * pointer every tick: `Component::get_gameObject` then
 * `GameObject::get_activeInHierarchy`, two ordinary instance getters CALLED (not
 * detoured) at static RVAs byte-verified against the startup prologue snapshot.
 * A screen that has been closed deactivates its GameObject, so activeInHierarchy
 * is the negative-falsifiable test the task asks for. If either getter cannot be
 * verified, or `gSettingsLiveSelf` is null/unreadable, bit0 is 0 and the reason
 * is countable (see `aowl_ui_st_*`), never a guessed 1.
 *
 * Both RVAs are re-used, byte-for-byte, from tables that already ship in this
 * repo (`aowlspt_invoke2.h` get_gameObject @0x11F57E0, `aowlspt_nativeui.h`
 * get_activeInHierarchy @0x52A8C90); they were resolved offline with
 * `il2cpp_resolve.py` on build 1.1.0.1.46777 and `--shared` annotated neither.
 * Calling a getter is safe even were it shared -- it is correct code for the
 * receiver passed -- and nothing here is detoured.
 *
 * THE EIGHT RULES
 * ---------------
 *  1. Prologue byte-verify (16 bytes, startup snapshot) before any call:
 *     `aowl_ui_fn`.
 *  2. `VirtualQuery` on the target page; `aowl_is_readable` on the SettingsScreen
 *     `this` and on the GameObject hop before each getter.
 *  3. ONE `aowl_p_p_seh`, installed by the caller (uistate.nim) around
 *     `aowl_ui_settings_probe_body`. Nothing here nests a guard.
 *  4. No loops but the capped one over `AOWL_UI_TARGET_COUNT` (2).
 *  5. The managed probe (bit0) is gated by `overlayStateSignal`, DEFAULT OFF.
 *     bit1/bit2 are pure reads of already-published state and always publish.
 *  6. Self-disables the bit0 probe after `AOWL_UI_MAX_FAULTS` faults.
 *  7. No managed allocation; the getters allocate nothing.
 *  8. Never writes anything into the game -- read-only throughout.
 */

#ifndef AOWLSPT_UISTATE_H
#define AOWLSPT_UISTATE_H

#include <stdint.h>

/* THIS HEADER IS SELF-SUFFICIENT ON PURPOSE.
 *
 * It used to declare nothing and rely on the includer (aowlhost.nim) having
 * already emitted the shim and prologue headers above it. That is an ordering
 * contract nothing enforces: any other translation unit that pulls this file in
 * gets IMPLICIT DECLARATIONS of `aowl_is_readable`, `aowl_p_p_seh` and
 * `aowl_pro_verify`, so C89 rules make them return `int` -- and on Win64 that
 * TRUNCATES `aowl_p_p_seh`'s returned pointer to 32 bits. A warning about an
 * int->void* conversion is the symptom; a silently halved pointer is the bug.
 * The right fix is a real prototype, never a cast at the call site.
 *
 * Both files carry include guards, so this is idempotent and the existing host
 * include order is unaffected. windows.h (LONG, InterlockedExchange,
 * VirtualQuery) arrives through them.
 */
#include "aowlspt_shim.h"      /* aowl_is_readable, aowl_p_p_seh */
#include "aowlspt_prologue.h"  /* aowl_pro_verify                */

/* Public, for mod consumers. */
#define AOWL_UI_OVL_SETTINGS  0x1u   /* the GAME's Settings screen is open  */
#define AOWL_UI_OVL_ADMIN     0x2u   /* our F6 admin overlay is open        */
#define AOWL_UI_OVL_DEBUG     0x4u   /* our F3 debug overlay is open        */
#define AOWL_UI_OVL_OVERLAY   0x8u   /* our F12 mod-manager/settings panel  */
#define AOWL_UI_OVL_ALL       0xFu

#define AOWL_UI_MAX_FAULTS  3

/* The last-published mask. A single aligned 32-bit store/load, published on the
 * Unity main thread and read by mods on whatever thread they poll from; a mask
 * republished every frame needs no lock. */
static volatile LONG g_ui_overlay_mask = 0;

/* THE EXPORT mods bind to. */
__declspec(dllexport) uint32_t aowl_ui_overlay_mask(void) {
    return (uint32_t)g_ui_overlay_mask;
}

/* The host publishes the composed mask here once per drain tick. */
static void aowl_ui_publish_mask(uint32_t mask) {
    InterlockedExchange(&g_ui_overlay_mask, (LONG)(mask & AOWL_UI_OVL_ALL));
}

/* ------------------------------------------------------------------ *
 * bit0 -- the game Settings screen, read as a FINISHED STATE every tick
 * ------------------------------------------------------------------ */

typedef struct AowlUiTarget {
    const char*   name;
    uint32_t      rva;
    unsigned char sig[16];
    int32_t       siglen;
} AowlUiTarget;

static const AowlUiTarget aowl_ui_targets[] = {
    /* [0] UnityEngine.Component::get_gameObject -- instance, 0 args -> GameObject.
     * Byte-identical to aowlspt_invoke2.h's entry. */
    { "UnityEngine.Component::get_gameObject", 0x11F57E0u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0xFB,0xEC,0xED,0x05,
        0x48,0x8B,0xD9 }, 16 },
    /* [1] UnityEngine.GameObject::get_activeInHierarchy -- instance, 0 args ->
     * bool. Byte-identical to aowlspt_nativeui.h's entry. */
    { "UnityEngine.GameObject::get_activeInHierarchy", 0x52A8C90u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0x0B,0xB9,0xE2,0x01,
        0x48,0x8B,0xD9 }, 16 },
};

#define AOWL_UI_TARGET_COUNT \
    ((int32_t)(sizeof(aowl_ui_targets) / sizeof(aowl_ui_targets[0])))
#define AOWL_UI_T_GETGO      0
#define AOWL_UI_T_GETACTIVE  1

static int32_t aowl_ui_verified = 0;
static int32_t aowl_ui_rejected = 0;
/* Verifies refused because the SHARED prologue snapshot table was full --
 * our capacity limit, not a client change. Kept apart from `rejected` so a
 * refusal can never be reported as "this build changed". */
static int32_t aowl_ui_profull = 0;
static int32_t aowl_ui_profull_count(void){ return aowl_ui_profull; }
static int32_t aowl_ui_faults   = 0;
static int32_t aowl_ui_off      = 0;   /* self-disabled bit0 probe */
static int32_t aowl_ui_last_open = -1; /* 1 open, 0 closed, -1 inconclusive */

static void* aowl_ui_fn(int32_t i) {
    HMODULE ga;
    const AowlUiTarget* t;
    unsigned char* p;
    MEMORY_BASIC_INFORMATION mbi;
    if (i < 0 || i >= AOWL_UI_TARGET_COUNT) return NULL;
    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) return NULL;
    t = &aowl_ui_targets[i];
    p = (unsigned char*)ga + t->rva;
    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return NULL;
    if (mbi.State != MEM_COMMIT) return NULL;
    if (!(mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)))
        return NULL;
    if (t->siglen > 0 && !aowl_pro_verify(t->rva, t->sig, t->siglen)) {
        /* TWO DIFFERENT FAILURES, TWO DIFFERENT REASONS. A verify that failed
         * because OUR snapshot table had no free row says nothing about the
         * client, so it is counted separately and never latched as a
         * signature mismatch. See aowl_pro_last_reason_text(). */
        if (aowl_pro_last_was_table_full()) { aowl_ui_profull++; return NULL; }
        aowl_ui_rejected++;
        return NULL;
    }
    aowl_ui_verified++;
    return (void*)p;
}

/* Instance, arity 0: `this` in RCX, hidden MethodInfo* in RDX (NULL is fine --
 * neither is a shared generic). */
typedef void*   (*AowlUi_GetGo)(void*, void*);
typedef int32_t (*AowlUi_GetActive)(void*, void*);

/* The SettingsScreen `this` the caller has learned, handed in per tick. */
static void* g_ui_settings_self = NULL;

/* THE GUARDED BODY. Runs under ONE `aowl_p_p_seh` installed by uistate.nim.
 * Sets `aowl_ui_last_open` to 1/0; leaves it -1 (inconclusive) on any refusal.
 * Returns non-NULL on clean completion; the guard returns NULL if it faulted. */
static void* aowl_ui_settings_probe_body(void* a) {
    void* self = g_ui_settings_self;
    void* go;
    void* fnGo;
    void* fnActive;
    int32_t active;
    (void)a;

    aowl_ui_last_open = -1;
    if (!self) { aowl_ui_last_open = 0; return (void*)1; }   /* known-closed */
    if (!aowl_is_readable(self, 8)) return (void*)1;         /* inconclusive */

    fnGo = aowl_ui_fn(AOWL_UI_T_GETGO);
    if (!fnGo) return (void*)1;
    go = ((AowlUi_GetGo)fnGo)(self, NULL);
    if (!go || !aowl_is_readable(go, 8)) return (void*)1;

    fnActive = aowl_ui_fn(AOWL_UI_T_GETACTIVE);
    if (!fnActive) return (void*)1;
    active = ((AowlUi_GetActive)fnActive)(go, NULL) & 1;
    aowl_ui_last_open = active ? 1 : 0;
    return (void*)1;
}

static void* aowl_ui_settings_probe_guarded(void* a) {
    return aowl_p_p_seh((void*)aowl_ui_settings_probe_body, a);
}

/* Diagnostics for uistate.nim. */
static int32_t aowl_ui_st_verified(void) { return aowl_ui_verified; }
static int32_t aowl_ui_st_rejected(void) { return aowl_ui_rejected; }
static int32_t aowl_ui_st_faults(void)   { return aowl_ui_faults; }
static int32_t aowl_ui_st_off(void)      { return aowl_ui_off; }
static int32_t aowl_ui_st_last_open(void){ return aowl_ui_last_open; }
static void    aowl_ui_st_set_self(void* p) { g_ui_settings_self = p; }
static void    aowl_ui_st_fault(void) {
    aowl_ui_faults++;
    if (aowl_ui_faults >= AOWL_UI_MAX_FAULTS) aowl_ui_off = 1;
}

#endif /* AOWLSPT_UISTATE_H */
