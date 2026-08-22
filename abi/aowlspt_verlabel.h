/* aowlspt_verlabel.h -- the main menu's CORNER VERSION LABEL, made
 * host/mod-controlled.
 *
 * ===========================================================================
 * WHAT THE LABEL ACTUALLY IS, AND HOW IT IS BUILT
 * ===========================================================================
 *
 * On a stock post-1.0 client the corner label reads
 *
 *     1.1.0.1.4677 | PvE
 *
 * That is NOT one string anybody stores. It is COMPOSED, every time, by
 * `EFT.UI.PreloaderUI::RefreshCornerLabel` @ RVA 0x156d050, out of four fields
 * on `PreloaderUI`, joined by a separator literal, and the result is dropped
 * into the `LocalizedText` at `PreloaderUI+0x20`.
 *
 * This is not inferred from names. It is the method's own code, disassembled
 * from `GameAssembly.dll` at that RVA (imagebase 0x180000000):
 *
 *     +0x00  40 53                 push rbx
 *     +0x02  48 83 EC 20           sub  rsp, 0x20
 *     +0x06  80 3D 88 09 B5 05 00  cmp  byte [rip+0x5B50988], 0   ; cctor guard
 *     +0x0d  48 8B D9              mov  rbx, rcx                  ; rbx = this
 *     ...
 *     +0x2a  48 8B 8B 18 01 00 00  mov  rcx, [rbx+0x118]  ; _sessionIdText
 *     +0x31  48 8B 83 10 01 00 00  mov  rax, [rbx+0x110]  ; _alphaVersionText
 *                                                         ; <- THE ACCUMULATOR
 *     +0x38  48 85 C9              test rcx, rcx
 *     +0x3b  74 1b                 je   skip1             ; null  -> skipped
 *     +0x3d  83 79 10 00           cmp  dword [rcx+0x10], 0
 *     +0x41  76 15                 jbe  skip1             ; EMPTY -> skipped
 *     +0x43  48 8B 15 3E 7D 86 05  mov  rdx, [rip+0x5867D3E]      ; the " | " literal
 *     +0x4a  4C 8B C1              mov  r8, rcx
 *     +0x4d  48 8B C8              mov  rcx, rax
 *     +0x50  45 33 C9              xor  r9d, r9d                  ; MethodInfo* = NULL
 *     +0x53  e8 ..                 call 0x184344170               ; rax = Concat(acc, " | ", part)
 *   skip1:
 *     +0x58  48 8B 8B 28 01 00 00  mov  rcx, [rbx+0x128]  ; _sessionModeText  (same shape)
 *     +0x7f  48 8B 8B 20 01 00 00  mov  rcx, [rbx+0x120]  ; _commitsNotMatchText (same shape)
 *     +0xa6  48 8B 4B 20           mov  rcx, [rbx+0x20]   ; _alphaVersionLabel : LocalizedText
 *     +0xb6  48 89 41 70           mov  [rcx+0x70], rax   ; LocalizedText.localizationKey = composed
 *     ...    (card-marking / write barrier for that store)
 *     +0x63  33 D2                 xor  edx, edx
 *     +0x68  e9 53 2c ea ff        jmp  0x18140FDB0       ; the LocalizedText repaint, tail-called
 *
 * Three facts fall out of those bytes, and every one of them is load-bearing:
 *
 *   1. THE ORDER IS FIXED AND STARTS AT 0x110. The accumulator is seeded from
 *      `_alphaVersionText` (+0x110) and everything else is APPENDED. So a label
 *      that must read "aowlspt | aoughwl.com | <version>" can only be produced
 *      by putting that whole string into +0x110. There is no reordering.
 *
 *   2. AN EMPTY OR NULL COMPONENT IS SKIPPED, SEPARATOR AND ALL. The
 *      `test rcx,rcx / je` and `cmp dword [rcx+0x10],0 / jbe` pair in front of
 *      every append is the game's own "nothing to say" test (0x10 is
 *      `System.String._stringLength`). Nulling +0x118/+0x120/+0x128 therefore
 *      leaves the composed label as EXACTLY +0x110 -- no trailing " | ", no
 *      empty segment. That is why this feature can promise an exact string.
 *
 *   3. THE GAME REPAINTS FOR US. The composed string goes into
 *      `LocalizedText.localizationKey` (+0x70) and the method TAIL-CALLS the
 *      repaint at 0x140FDB0. We never touch `TMP_Text.m_text`, never poke a
 *      dirty byte, and never call the stripped `ForceMeshUpdate` stub at
 *      0x628110 (it is a bare `C2 00 00` ret on this build). The Phase-2a
 *      repaint bug -- store lands, screen never changes -- is structurally
 *      impossible here, because the only thing this feature does is arrange the
 *      INPUTS and then let the game's own code run to completion.
 *
 * Field offsets, from the decrypted `global-metadata.dat` + the registration
 * struct via `tools/il2cpp_resolve.py fields EFT.UI.PreloaderUI` (nothing
 * guessed, no string search -- metadata strings on this build are encrypted):
 *
 *     EFT.UI.PreloaderUI (typedef 14830, Assembly-CSharp.dll)
 *       0x020  _alphaVersionLabel    LocalizedText
 *       0x110  _alphaVersionText     string     <- the accumulator seed
 *       0x118  _sessionIdText        string
 *       0x120  _commitsNotMatchText  string
 *       0x128  _sessionModeText      string     <- what SetGameModeText writes
 *
 *     EFT.UI.LocalizedText (typedef 14184)
 *       0x070  localizationKey                string
 *       0x0a0  <FormattedText>k__BackingField string   <- the rendered text
 *
 * ===========================================================================
 * WHERE THE REAL VERSION COMES FROM -- NEVER HARDCODED
 * ===========================================================================
 *
 * `PreloaderUI::Awake` @ 0x1569a20 seeds +0x110 from the label itself:
 *
 *     +0x1c49  48 8B 43 20           mov rax, [rbx+0x20]     ; _alphaVersionLabel
 *     +0x1c50  48 85 C0              test rax, rax
 *     +0x1c5d  48 8B 80 A0 00 00 00  mov rax, [rax+0xA0]     ; LocalizedText.FormattedText
 *     +0x1c64  48 89 83 10 01 00 00  mov [rbx+0x110], rax    ; _alphaVersionText = it
 *
 * So by the time `RefreshCornerLabel` runs, +0x110 ALREADY HOLDS the client's
 * real, live version string, put there by the game. This feature reads it out
 * of that field by the fixed `System.String` layout (length int32 @ +0x10,
 * UTF-16 chars @ +0x14 -- the layout `verify-fields` asserts), remembers it, and
 * substitutes it into the format. No version number appears anywhere in this
 * host, so a client update changes the label's contents by itself.
 *
 * ===========================================================================
 * WHY `RefreshCornerLabel` AND NOT `Update`
 * ===========================================================================
 *
 * `EFT.UI.PreloaderUI::Update` is congested: the F3 debug overlay, the ESP
 * probe and the menu mode text all want it, and two detours on one function
 * have the second overwrite the first's trampoline. This feature does not go
 * near it. `RefreshCornerLabel` is a function NOTHING ELSE IN THIS HOST HOOKS,
 * and it is exactly the right seam anyway:
 *
 *   * it is the ONLY writer of the corner label, so a PREFIX detour here sees
 *     every single composition, including ones triggered long after boot by
 *     `SetGameModeText` / `SetSessionId` / `SetCommitsNotMatchText`. A one-shot
 *     `Awake` write could be silently undone by any of those; this cannot be.
 *   * it is NOT per-frame. It runs only when a component actually changed, so
 *     there is no hot path to stay off and no per-frame cost to justify.
 *
 * The prefix runs BEFORE the original, sets the fields, and returns 0 -- the
 * original then composes and repaints from what it now finds. The feature never
 * suppresses the original and never calls it.
 *
 * ===========================================================================
 * SAFETY
 * ===========================================================================
 *
 *   * `VirtualQuery` for COMMITTED EXECUTABLE memory BEFORE the prologue
 *     `memcmp`, because a stale RVA on another build can land on an uncommitted
 *     page and fault inside `memcmp` itself;
 *   * the 16 prologue bytes must match EXACTLY or the target is refused and
 *     nothing binds -- on any build but this one the feature is a silent no-op;
 *   * the caller (`verlabel.nim`) is flag-gated (`uxVersionLabel`, default OFF),
 *     runs its whole body under ONE `aowl_p_p_seh` guard (never nested -- the
 *     guard is not re-entrant and a nested one disarms the outer on return),
 *     `aowl_is_readable`-guards every pointer hop, writes only through the
 *     VirtualQuery-checked `aowl_uxpatch_write_ptr`, validates printable ASCII
 *     and length at both ends, self-disables after a small number of faults,
 *     and allocates a managed string ONLY when the composed text actually
 *     changed -- never once per call, and never once per frame.
 */
#ifndef AOWLSPT_VERLABEL_H
#define AOWLSPT_VERLABEL_H

#include <stdint.h>
#include <string.h>
#include <windows.h>

/* ---- the build-pinned target ----------------------------------------- */

#define AOWL_VLB_REFRESHCORNER_RVA   0x156d050u

/* `EFT.UI.PreloaderUI` field offsets. See the header comment for where each of
 * these appears in `RefreshCornerLabel`'s own disassembly. */
#define AOWL_VLB_OFF_VERSION_TEXT    0x110  /* _alphaVersionText    (written)  */
#define AOWL_VLB_OFF_SESSION_ID      0x118  /* _sessionIdText       (nulled)   */
#define AOWL_VLB_OFF_COMMITS         0x120  /* _commitsNotMatchText (nulled)   */
#define AOWL_VLB_OFF_SESSION_MODE    0x128  /* _sessionModeText     (nulled*)  */
#define AOWL_VLB_OFF_CORNER_LABEL    0x20   /* _alphaVersionLabel   (read only)*/
/* `EFT.UI.LocalizedText.<FormattedText>k__BackingField` -- the fallback place
 * to read the real version from if `_alphaVersionText` has not been seeded yet
 * (i.e. if a refresh somehow beats `Awake`'s copy). READ ONLY. */
#define AOWL_VLB_OFF_LOCALIZED_TEXT  0xa0

typedef struct AowlVlbTarget {
    const char*   name;
    uint32_t      rva;
    unsigned char sig[16];
    int32_t       siglen;
} AowlVlbTarget;

static const AowlVlbTarget aowl_vlb_targets[] = {
    /* [0] EFT.UI.PreloaderUI::RefreshCornerLabel -- instance, 0 args -> void.
     * THE composer, and the one function this feature hooks. Byte-identical to
     * target [2] in `aowlspt_modetext.h`, which resolved and verified the same
     * method independently; the two tables agreeing is a free cross-check.
     *
     *   40 53                 push rbx
     *   48 83 EC 20           sub  rsp, 0x20
     *   80 3D 88 09 B5 05 00  cmp  byte [rip+0x5B50988], 0
     *   48 8B D9              mov  rbx, rcx                                   */
    { "EFT.UI.PreloaderUI::RefreshCornerLabel", AOWL_VLB_REFRESHCORNER_RVA,
      { 0x40,0x53, 0x48,0x83,0xEC,0x20, 0x80,0x3D,0x88,0x09,0xB5,0x05,0x00,
        0x48,0x8B,0xD9 }, 16 },
};

#define AOWL_VLB_TARGET_COUNT \
    ((int32_t)(sizeof(aowl_vlb_targets) / sizeof(aowl_vlb_targets[0])))

#define AOWL_VLB_T_REFRESH  0

/* Diagnostics, so a refusal in the log can name its own reason rather than
 * being indistinguishable from "the feature was off". */
static int32_t aowl_vlb_base_found = 0;
static int32_t aowl_vlb_verified   = 0;
static int32_t aowl_vlb_rejected   = 0;

static void* aowl_vlb_fn(int32_t i) {
    HMODULE ga;
    const AowlVlbTarget* t;
    unsigned char* p;
    MEMORY_BASIC_INFORMATION mbi;
    if (i < 0 || i >= AOWL_VLB_TARGET_COUNT) return NULL;
    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) return NULL;
    aowl_vlb_base_found = 1;
    t = &aowl_vlb_targets[i];
    p = (unsigned char*)ga + t->rva;
    /* Committed + executable BEFORE the compare. A stale RVA that landed on an
     * uncommitted page would fault inside `memcmp` itself. */
    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return NULL;
    if (mbi.State != MEM_COMMIT) return NULL;
    if (!(mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)))
        return NULL;
    if (t->siglen > 0 && memcmp(p, t->sig, (size_t)t->siglen) != 0) {
        aowl_vlb_rejected++;
        return NULL;
    }
    aowl_vlb_verified++;
    return (void*)p;
}
static const char* aowl_vlb_name(int32_t i) {
    if (i < 0 || i >= AOWL_VLB_TARGET_COUNT) return "";
    return aowl_vlb_targets[i].name;
}
static uint32_t aowl_vlb_rva(int32_t i) {
    if (i < 0 || i >= AOWL_VLB_TARGET_COUNT) return 0u;
    return aowl_vlb_targets[i].rva;
}
static int32_t aowl_vlb_base_ok(void)  { return aowl_vlb_base_found; }
static int32_t aowl_vlb_ok_count(void) { return aowl_vlb_verified; }
static int32_t aowl_vlb_bad_count(void){ return aowl_vlb_rejected; }

static int32_t aowl_vlb_off_version_text(void)  { return AOWL_VLB_OFF_VERSION_TEXT; }
static int32_t aowl_vlb_off_session_id(void)    { return AOWL_VLB_OFF_SESSION_ID; }
static int32_t aowl_vlb_off_commits(void)       { return AOWL_VLB_OFF_COMMITS; }
static int32_t aowl_vlb_off_session_mode(void)  { return AOWL_VLB_OFF_SESSION_MODE; }
static int32_t aowl_vlb_off_corner_label(void)  { return AOWL_VLB_OFF_CORNER_LABEL; }
static int32_t aowl_vlb_off_localized_text(void){ return AOWL_VLB_OFF_LOCALIZED_TEXT; }

/* NOTE: this header deliberately declares NO call thunk and NO write helper.
 * It does not need a call thunk -- the feature never calls a managed method, it
 * only arranges fields and lets the ORIGINAL `RefreshCornerLabel` run. And the
 * one pointer store it does make goes through `aowl_uxpatch_write_ptr` from
 * `aowlspt_uxpatch.h`, which is already the host's VirtualQuery-checked
 * reference-field write and is already what the version brand uses live. A
 * second copy of that function would be a second thing to get wrong. */

#endif /* AOWLSPT_VERLABEL_H */
