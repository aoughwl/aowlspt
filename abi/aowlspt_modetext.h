/* aowlspt_modetext.h -- the main menu's bottom-right GAME MODE label, made
 * host/mod-controlled.
 *
 * ===========================================================================
 * WHAT THE LABEL ACTUALLY IS
 * ===========================================================================
 *
 * The bottom-right corner of the main menu reads "PVE ZONE" on a stock post-1.0
 * client. It is NOT a standalone TMP object and it is NOT a `LocalizedText` that
 * has to be fought. It is one of three strings `EFT.UI.PreloaderUI` composes
 * into its corner label, and the game gives us a real setter for it.
 *
 * Resolved OFFLINE from the decrypted `global-metadata.dat` (decrypted here with
 * `tools/metablob.py` + the installed layout blob at
 * `mods/tarkov/data/metadata/1.1.0.1.46777.json`, verified `AF 1B B1 FA` / v31)
 * via `tools/il2cpp_resolve.py`. No string search of the metadata was involved
 * -- managed strings there are encrypted -- and nothing was guessed.
 *
 *   EFT.UI.PreloaderUI  (typedef 14830, Assembly-CSharp.dll) fields:
 *       0x020  _alphaVersionLabel   LocalizedText        <- the corner label
 *       0x110  _alphaVersionText    string
 *       0x118  _sessionIdText       string
 *       0x128  _sessionModeText     string               <- "PVE ZONE"
 *
 *   EFT.UI.PreloaderUI methods:
 *       Update              RVA 0x1569f20
 *       SetGameModeText     RVA 0x156cff0   instance, 1 string arg -> void
 *       RefreshCornerLabel  RVA 0x156d050
 *
 * THE IDENTIFICATION IS SELF-PROVING, from the disassembly rather than the name.
 * `SetGameModeText`'s own prologue is:
 *
 *     83 3D 49 95 B4 05 00     cmp  dword [rip+0x5B49549], 0   ; cctor guard
 *     4C 8B C9                 mov  r9, rcx                    ; this
 *     48 89 91 28 01 00 00     mov  [rcx+0x128], rdx           ; _sessionModeText = arg
 *
 * i.e. the method stores its RDX argument into field 0x128 and then refreshes
 * the corner label. Field 0x128 IS the mode text, the method IS its setter, and
 * the IL2CPP instance convention (RCX=this, RDX=arg0, R8=hidden MethodInfo*) is
 * visible in those bytes. That is why this file calls the setter and never
 * pokes 0x128 directly.
 *
 * ===========================================================================
 * WHY THIS DOES NOT REPEAT THE PHASE-2a REPAINT BUG
 * ===========================================================================
 *
 * The live Phase-2a bug is: store into `TMP.m_text` (0xE0) + a dirty byte, the
 * store demonstrably lands, and the screen never changes. This file does not do
 * that. It calls the game's OWN setter, which performs whatever invalidation the
 * game performs for itself -- `RefreshCornerLabel` is right there in the same
 * type, at the next RVA, and is what the setter tail-calls. Calling the real
 * managed method at its static RVA is the sanctioned escape from a dead
 * reflection API on this build; `abi/aowlspt_invoke2.h` established the
 * convention with disassembled evidence, and this is the same shape
 * (`aowl_mi2_call_v_pp`: instance, one reference arg, void).
 *
 * ===========================================================================
 * SAFETY
 * ===========================================================================
 *
 * Same discipline as `aowl_mi2_fn` and `aowl_bridge_settings_target_at`:
 *
 *   * every RVA is checked to land in COMMITTED EXECUTABLE memory with
 *     `VirtualQuery` BEFORE the 16 prologue bytes are compared, because a stale
 *     RVA on another build can point at an uncommitted page and `memcmp` there
 *     faults;
 *   * the 16-byte prologue must match exactly or the target is refused and
 *     nothing is bound -- on any build but this one the feature is simply a
 *     no-op, never a hazard;
 *   * the caller (`modetext.nim`) is flag-gated (`uxMenuModeText`), default OFF,
 *     runs its whole body under ONE `aowl_p_p_seh` guard (never nested), guards
 *     every pointer hop with `aowl_is_readable`, self-disables after a small
 *     number of faults, and -- the specific hazard that crashed this host once
 *     before -- allocates a managed string ONLY when the desired text actually
 *     CHANGED, never once per frame.
 */
#ifndef AOWLSPT_MODETEXT_H
#define AOWLSPT_MODETEXT_H

#include <stdint.h>
#include <string.h>
#include <windows.h>

/* ---- the build-pinned targets ---------------------------------------- */

#define AOWL_MTX_PRELOADER_UPDATE_RVA   0x1569f20u
#define AOWL_MTX_SETGAMEMODETEXT_RVA    0x156cff0u
#define AOWL_MTX_REFRESHCORNER_RVA      0x156d050u

/* `EFT.UI.PreloaderUI::_sessionModeText`. Read ONLY -- for the log line that
 * makes the identification verifiable from a real run. Never written. */
#define AOWL_MTX_SESSIONMODETEXT_OFF    0x128
/* `EFT.UI.PreloaderUI::_alphaVersionLabel` -- the LocalizedText that owns the
 * corner label. Read only, and only so the log can name the object the user is
 * looking at. This is the SAME slot the version brand already uses. */
#define AOWL_MTX_CORNERLABEL_OFF        0x20

typedef struct AowlMtxTarget {
    const char*   name;
    uint32_t      rva;
    unsigned char sig[16];
    int32_t       siglen;
} AowlMtxTarget;

static const AowlMtxTarget aowl_mtx_targets[] = {
    /* [0] EFT.UI.PreloaderUI::Update -- the per-frame Unity-thread tick this
     * feature rides. A POSTFIX detour here yields BOTH the live `this` and a
     * main-thread moment to apply a change in, with no new thread and no new
     * detour target invented for the purpose.
     *
     *   48 8B C4        mov  rax, rsp
     *   48 89 58 10     mov  [rax+0x10], rbx
     *   48 89 70 20     mov  [rax+0x20], rsi
     *   48 89 48 08     mov  [rax+0x08], rcx
     *   57              push rdi                                             */
    { "EFT.UI.PreloaderUI::Update", AOWL_MTX_PRELOADER_UPDATE_RVA,
      { 0x48,0x8B,0xC4, 0x48,0x89,0x58,0x10, 0x48,0x89,0x70,0x20,
        0x48,0x89,0x48,0x08, 0x57 }, 16 },

    /* [1] EFT.UI.PreloaderUI::SetGameModeText(string) -- instance, 1 reference
     * arg, void. THE setter. See the disassembly in the file header: the
     * `mov [rcx+0x128], rdx` in these very bytes is the proof that this method
     * and field 0x128 are the mode text.
     *
     *   83 3D 49 95 B4 05 00    cmp  dword [rip+0x5B49549], 0
     *   4C 8B C9                mov  r9, rcx
     *   48 89 91 28 01 00       mov  [rcx+0x128], rdx   (7-byte insn, clipped) */
    { "EFT.UI.PreloaderUI::SetGameModeText", AOWL_MTX_SETGAMEMODETEXT_RVA,
      { 0x83,0x3D,0x49,0x95,0xB4,0x05,0x00, 0x4C,0x8B,0xC9,
        0x48,0x89,0x91,0x28,0x01,0x00 }, 16 },

    /* [2] EFT.UI.PreloaderUI::RefreshCornerLabel -- instance, 0 args, void.
     * NOT called by default: `SetGameModeText` already refreshes. Verified and
     * exposed so that IF a build were ever found where the setter alone did not
     * repaint, the fallback is one already-checked call away rather than a
     * return to poking `m_text`.
     *
     *   40 53           push rbx
     *   48 83 EC 20     sub  rsp, 0x20
     *   80 3D 88 09 B5 05 00   cmp byte [rip+0x5B50988], 0
     *   48 8B D9        mov  rbx, rcx                                        */
    { "EFT.UI.PreloaderUI::RefreshCornerLabel", AOWL_MTX_REFRESHCORNER_RVA,
      { 0x40,0x53, 0x48,0x83,0xEC,0x20, 0x80,0x3D,0x88,0x09,0xB5,0x05,0x00,
        0x48,0x8B,0xD9 }, 16 },
};

#define AOWL_MTX_TARGET_COUNT \
    ((int32_t)(sizeof(aowl_mtx_targets) / sizeof(aowl_mtx_targets[0])))

#define AOWL_MTX_T_UPDATE   0
#define AOWL_MTX_T_SETTEXT  1
#define AOWL_MTX_T_REFRESH  2

/* Diagnostics, so a refusal in the log can name its own reason rather than
 * being indistinguishable from "the feature was off". */
static int32_t aowl_mtx_base_found = 0;
static int32_t aowl_mtx_verified   = 0;
static int32_t aowl_mtx_rejected   = 0;
/* Verifies refused because the SHARED prologue snapshot table was full --
 * our capacity limit, not a client change. Kept apart from `rejected` so a
 * refusal can never be reported as "this build changed". */
static int32_t aowl_mtx_profull = 0;

static void* aowl_mtx_fn(int32_t i) {
    HMODULE ga;
    const AowlMtxTarget* t;
    unsigned char* p;
    MEMORY_BASIC_INFORMATION mbi;
    if (i < 0 || i >= AOWL_MTX_TARGET_COUNT) return NULL;
    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) return NULL;
    aowl_mtx_base_found = 1;
    t = &aowl_mtx_targets[i];
    p = (unsigned char*)ga + t->rva;
    /* Committed + executable BEFORE the compare. A stale RVA that lands on an
     * uncommitted page would fault inside `memcmp` itself. */
    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return NULL;
    if (mbi.State != MEM_COMMIT) return NULL;
    if (!(mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)))
        return NULL;
    /* Compared against the SNAPSHOT of the original prologue, never against
     * live memory. The debug overlay shares this exact function and may
     * already have written its jump over these bytes; reading them here is
     * what made this feature reject a target that was always correct. See
     * `aowlspt_prologue.h`. */
    if (t->siglen > 0 && !aowl_pro_verify(t->rva, t->sig, t->siglen)) {
        /* TWO DIFFERENT FAILURES, TWO DIFFERENT REASONS. A verify that failed
         * because OUR snapshot table had no free row says nothing about the
         * client, so it is counted separately and never latched as a
         * signature mismatch. See aowl_pro_last_reason_text(). */
        if (aowl_pro_last_was_table_full()) { aowl_mtx_profull++; return NULL; }
        aowl_mtx_rejected++;
        return NULL;
    }
    aowl_mtx_verified++;
    return (void*)p;
}
static const char* aowl_mtx_name(int32_t i) {
    if (i < 0 || i >= AOWL_MTX_TARGET_COUNT) return "";
    return aowl_mtx_targets[i].name;
}
static uint32_t aowl_mtx_rva(int32_t i) {
    if (i < 0 || i >= AOWL_MTX_TARGET_COUNT) return 0u;
    return aowl_mtx_targets[i].rva;
}
static int32_t aowl_mtx_target_count(void) { return AOWL_MTX_TARGET_COUNT; }
static int32_t aowl_mtx_profull_count(void){ return aowl_mtx_profull; }
static int32_t aowl_mtx_base_ok(void)      { return aowl_mtx_base_found; }
static int32_t aowl_mtx_ok_count(void)     { return aowl_mtx_verified; }
static int32_t aowl_mtx_bad_count(void)    { return aowl_mtx_rejected; }

static int32_t aowl_mtx_off_mode_text(void)   { return AOWL_MTX_SESSIONMODETEXT_OFF; }
static int32_t aowl_mtx_off_corner_label(void){ return AOWL_MTX_CORNERLABEL_OFF; }

/* ---- the one call shape this feature needs --------------------------- *
 *
 * instance, 1 reference arg -> void: (this, a0, MethodInfo*).
 * `SetGameModeText` is not generic, so a NULL MethodInfo is correct here --
 * the restriction in `aowlspt_invoke2.h` is on SHARED GENERIC code, and this
 * method is neither. The MethodInfo is still passed EXPLICITLY rather than
 * left to whatever happens to be in R8.
 *
 * Deliberately a separate symbol from `aowl_mi2_call_v_pp` so this feature owns
 * its own thunk and merges cleanly alongside concurrent settings-UI work. */
typedef void (*AowlMtx_V_PP)(void*, void*, void*);
static void aowl_mtx_call_v_pp(void* fn, void* self, void* a0) {
    if (!fn) return;
    ((AowlMtx_V_PP)fn)(self, a0, NULL);
}
/* instance, 0 args -> void. The RefreshCornerLabel fallback, unused by default. */
typedef void (*AowlMtx_V_P)(void*, void*);
static void aowl_mtx_call_v_p(void* fn, void* self) {
    if (!fn) return;
    ((AowlMtx_V_P)fn)(self, NULL);
}

#endif /* AOWLSPT_MODETEXT_H */
