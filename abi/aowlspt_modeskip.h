/* aowlspt_modeskip.h -- never show the character/mode selection screen.
 *
 * ===========================================================================
 * WHAT THIS IS
 * ===========================================================================
 *
 * The post-1.0 client stops at `EFT.UI.CharacterSelectionScreen` and waits for
 * a human to pick a game mode and a character slot. The user never wants to see
 * it: the launcher ALREADY chose a profile (`tools/aowllaunch.nim` picks one and
 * passes `-token=<id>`; without that token the client dies at "Client not
 * authenticated"), so the screen is asking a question that has already been
 * answered.
 *
 * This feature answers it programmatically. It rides the screen's own code
 * path and calls the same `Submit` the slot's action button calls.
 *
 * ===========================================================================
 * THE ROUTE, AND WHY THESE THREE TARGETS
 * ===========================================================================
 *
 * Resolved OFFLINE from the decrypted `global-metadata.dat` with
 * `tools/il2cpp_resolve.py` (`type 14120`, `type 14118`, `bytes <RVA>`) and
 * `tools/fldoff.py`. Nothing here was guessed and nothing came from a string
 * search of the metadata (managed strings there are encrypted).
 *
 *   EFT.UI.CharacterSelectionScreen           typedef 14120
 *       ShowSlot(CharacterSelectionSlotViewBase slotView, EGameMode gameMode,
 *                CharacterSelectionProfileData profileData,
 *                CharacterSelectionScreenController controller)
 *                                              RVA 0x13efae0   arity 4
 *   CharacterSelectionScreenController        typedef 14118
 *       .ctor(CharacterSelectionDataResponse, bool, string,
 *             Nullable<EGameMode>, SeasonalPerksData, bool)
 *                                              RVA 0x13f0530   arity 6
 *       Submit(EGameMode gameMode, CharacterSelectionProfileData profileData)
 *                                              RVA 0x13f0bf0   arity 2
 *
 * All three are UNSHARED -- `il2cpp_resolve.py type ... --shared` annotates
 * neither of them, while it flags e.g. `get_ProfileId` as 185-way folded. That
 * matters because detouring a shared RVA fires for every method folded onto it.
 *
 * WHY THE .ctor IS IN THIS LIST -- the constraint that shaped the design.
 * `Submit` is an INSTANCE method on the CONTROLLER, so calling it needs the
 * controller pointer. `ShowSlot` receives the controller, but as its FOURTH
 * argument: on the Win64 ABI an instance method's arguments are
 * `RCX=this, RDX=arg0, R8=arg1, R9=arg2`, and arg3 goes ON THE STACK. The
 * host's detour thunk saves only `RCX..R9` (`AowlRegs` in `aowlspt_shim.h`), so
 * the controller is simply NOT VISIBLE from a ShowSlot detour. That was
 * measured, not assumed -- the arity-4 signature above is what makes it true.
 *
 * Two routes to the controller were rejected on evidence:
 *   * `CharacterSelectionScreen::Show(controller)` @0x13ef4d0 takes it in RDX
 *     and would be ideal, but its 14-byte relocation window contains a
 *     rip-relative `80 3D` at byte 10, so its prologue cannot be relocated.
 *   * `CharacterSelectionSlotViewBase` does not STORE the controller --
 *     `tools/fldoff.py fields CharacterSelectionSlotViewBase` lists every field
 *     through 0x180 and there is no controller among them.
 *
 * So the controller is captured where it is unambiguously in RCX: its own
 * constructor. `.ctor` runs exactly once per controller, before any slot is
 * shown, and `this` is in RCX by definition.
 *
 * FIELD OFFSETS (tools/fldoff.py, which self-checks System.String
 * _stringLength@0x10 / _firstChar@0x14 before printing anything):
 *
 *   EFT.CharacterSelectionProfileData  typedef 8775
 *       0x20  Status      ECharacterSelectionProfileStatus
 *       0x60  Nickname    string
 *       0x74  Side        EPlayerSide
 *       0x78  ProfileId   string
 *
 * ===========================================================================
 * WHAT IS MATCHED, AND WHAT IS DELIBERATELY NOT
 * ===========================================================================
 *
 * The predicate is ProfileId EQUALITY against the launcher's `launchProfileId`,
 * and nothing else.
 *
 * `Status` is READ and LOGGED but NOT gated on. That is deliberate and it is a
 * refusal to guess: `ECharacterSelectionProfileStatus`'s constant values live in
 * metadata `fieldDefaultValues`, which neither resolver verb exposes, so the
 * integer meaning "Available" is not something this host KNOWS. Gating on a
 * guessed enum value would be exactly the "never guess an offset" mistake in
 * another costume. ProfileId equality is strictly stronger anyway: an empty slot
 * carries no ProfileId to match, so it cannot be selected by accident, and the
 * one profile the launcher bound is by construction the one that is available.
 *
 * ===========================================================================
 * SAFETY
 * ===========================================================================
 *
 * Every RVA is checked to land in COMMITTED EXECUTABLE memory with
 * `VirtualQuery` BEFORE its 16 prologue bytes are compared, because a stale RVA
 * on another build can point at an uncommitted page and `memcmp` there faults.
 * The comparison itself is against the STARTUP SNAPSHOT (`aowl_pro_verify`,
 * `aowlspt_prologue.h`), never against live memory -- verifying against live
 * bytes after another feature has patched a function reads that feature's
 * trampoline and self-rejects. On any build but this one every target is
 * refused and the feature is a silent no-op, never a hazard.
 *
 * The Nim caller (`modeskip.nim`) is flag-gated `uxSkipModeScreen`, default OFF,
 * runs its whole body under ONE `aowl_p_p_seh` (never nested), guards every
 * pointer hop, caps iteration, self-disables after a few faults, and calls
 * Submit from the TarkovApplication::Update drain -- never inline inside
 * ShowSlot, which would re-enter the screen's own code from inside its own
 * call.
 *
 * HOW LONG IT DEFERS, AND WHY THAT IS NOT A FRAME COUNT.
 * Deferring two drain ticks (~16ms) was measured to BREAK THE CLIENT: the
 * player was left on a blank background with no menu. `TarkovApplication`
 * shows this screen a SECOND time from its own async
 * `RunInitialLobbyFlow -> RunCharacterSelectionFlow ->
 *  ShowCharacterSelectionScreen -> ShowScreenAsync -> DisplayScreen -> Show`,
 * 372ms after the first slots appear. Answering before that lands makes the
 * late `Show` throw `NullReferenceException` inside
 * `EFT.UI.CharacterSelectionSeasonPanel.ShowPerks`, which aborts the whole
 * lobby-flow task, so `MenuScreen` is never activated. `modeskip.nim` now
 * waits for WALL-CLOCK QUIET on `ShowSlot` instead, and declines outright
 * rather than pressing if quiet never arrives.
 */
#ifndef AOWLSPT_MODESKIP_H
#define AOWLSPT_MODESKIP_H

#include <stdint.h>
#include <string.h>
#include <windows.h>

/* ---- the build-pinned targets ---------------------------------------- */

#define AOWL_MSK_SHOWSLOT_RVA    0x13efae0u
#define AOWL_MSK_CTOR_RVA        0x13f0530u
#define AOWL_MSK_SUBMIT_RVA      0x13f0bf0u

/* EFT.CharacterSelectionProfileData */
#define AOWL_MSK_PD_STATUS_OFF   0x20
#define AOWL_MSK_PD_NICKNAME_OFF 0x60
#define AOWL_MSK_PD_SIDE_OFF     0x74
#define AOWL_MSK_PD_PROFILEID_OFF 0x78

/* System.String, self-checked by tools/fldoff.py before it prints anything. */
#define AOWL_MSK_STR_LEN_OFF     0x10
#define AOWL_MSK_STR_CHARS_OFF   0x14

typedef struct AowlMskTarget {
    const char*   name;
    uint32_t      rva;
    unsigned char sig[16];
    int32_t       siglen;
} AowlMskTarget;

static const AowlMskTarget aowl_msk_targets[] = {
    /* [0] EFT.UI.CharacterSelectionScreen::ShowSlot -- the READ-ONLY capture
     * point. A POSTFIX detour, so the saved argument registers are still the
     * ones the caller passed. Never suppresses the original: the screen is
     * allowed to build itself normally, and is dismissed a frame later.
     *
     *   44 89 44 24 18    mov  [rsp+0x18], r8d      ; gameMode
     *   48 89 4C 24 08    mov  [rsp+0x08], rcx      ; this
     *   53                push rbx
     *   55                push rbp
     *   57                push rdi
     *   41 55             push r13
     * 15 clean bytes before the 16th; no rip-relative operand in the window. */
    { "EFT.UI.CharacterSelectionScreen::ShowSlot", AOWL_MSK_SHOWSLOT_RVA,
      { 0x44,0x89,0x44,0x24,0x18, 0x48,0x89,0x4C,0x24,0x08,
        0x53, 0x55, 0x57, 0x41,0x55, 0x48 }, 16 },

    /* [1] CharacterSelectionScreenController::.ctor -- where the controller is
     * captured, because it is `this` in RCX and nowhere else is it reachable.
     * See the header comment: ShowSlot's controller is a STACK argument.
     *
     *   48 89 5C 24 08    mov  [rsp+0x08], rbx
     *   48 89 6C 24 10    mov  [rsp+0x10], rbp
     *   48 89 74 24 18    mov  [rsp+0x18], rsi
     *   57                push rdi
     * 16 clean bytes, stores and a push, nothing rip-relative. */
    { "CharacterSelectionScreenController::.ctor", AOWL_MSK_CTOR_RVA,
      { 0x48,0x89,0x5C,0x24,0x08, 0x48,0x89,0x6C,0x24,0x10,
        0x48,0x89,0x74,0x24,0x18, 0x57 }, 16 },

    /* [2] CharacterSelectionScreenController::Submit(EGameMode,
     * CharacterSelectionProfileData) -- CALLED, never detoured. This is the
     * method the slot's action button ends up calling; invoking it is what
     * "the player picked this slot" means to the rest of the game.
     *
     *   48 89 5C 24 08    mov  [rsp+0x08], rbx
     *   48 89 74 24 10    mov  [rsp+0x10], rsi
     *   57                push rdi
     *   48 83 EC 20       sub  rsp, 0x20                                    */
    { "CharacterSelectionScreenController::Submit", AOWL_MSK_SUBMIT_RVA,
      { 0x48,0x89,0x5C,0x24,0x08, 0x48,0x89,0x74,0x24,0x10,
        0x57, 0x48,0x83,0xEC,0x20, 0x80 }, 16 },
};

#define AOWL_MSK_TARGET_COUNT \
    ((int32_t)(sizeof(aowl_msk_targets) / sizeof(aowl_msk_targets[0])))

#define AOWL_MSK_T_SHOWSLOT 0
#define AOWL_MSK_T_CTOR     1
#define AOWL_MSK_T_SUBMIT   2

/* Diagnostics, so a refusal in the log names its own reason rather than being
 * indistinguishable from "the feature was off". */
static int32_t aowl_msk_base_found = 0;
static int32_t aowl_msk_verified   = 0;
static int32_t aowl_msk_rejected   = 0;

static void* aowl_msk_fn(int32_t i) {
    HMODULE ga;
    const AowlMskTarget* t;
    unsigned char* p;
    MEMORY_BASIC_INFORMATION mbi;
    if (i < 0 || i >= AOWL_MSK_TARGET_COUNT) return NULL;
    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) return NULL;
    aowl_msk_base_found = 1;
    t = &aowl_msk_targets[i];
    p = (unsigned char*)ga + t->rva;
    /* Committed + executable BEFORE the compare: a stale RVA that lands on an
     * uncommitted page would fault inside `memcmp` itself. */
    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return NULL;
    if (mbi.State != MEM_COMMIT) return NULL;
    if (!(mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)))
        return NULL;
    /* Against the SNAPSHOT, never live memory. See aowlspt_prologue.h. */
    if (t->siglen > 0 && !aowl_pro_verify(t->rva, t->sig, t->siglen)) {
        aowl_msk_rejected++;
        return NULL;
    }
    aowl_msk_verified++;
    return (void*)p;
}

static const char* aowl_msk_name(int32_t i) {
    if (i < 0 || i >= AOWL_MSK_TARGET_COUNT) return "";
    return aowl_msk_targets[i].name;
}
static uint32_t aowl_msk_rva(int32_t i) {
    if (i < 0 || i >= AOWL_MSK_TARGET_COUNT) return 0u;
    return aowl_msk_targets[i].rva;
}
static int32_t aowl_msk_target_count(void) { return AOWL_MSK_TARGET_COUNT; }
static int32_t aowl_msk_base_ok(void)      { return aowl_msk_base_found; }
static int32_t aowl_msk_ok_count(void)     { return aowl_msk_verified; }
static int32_t aowl_msk_bad_count(void)    { return aowl_msk_rejected; }

static int32_t aowl_msk_off_status(void)    { return AOWL_MSK_PD_STATUS_OFF; }
static int32_t aowl_msk_off_nickname(void)  { return AOWL_MSK_PD_NICKNAME_OFF; }
static int32_t aowl_msk_off_side(void)      { return AOWL_MSK_PD_SIDE_OFF; }
static int32_t aowl_msk_off_profileid(void) { return AOWL_MSK_PD_PROFILEID_OFF; }

/* ---- guarded raw reads ------------------------------------------------ *
 *
 * Each one VirtualQuery-checks the exact byte range it is about to touch. The
 * caller is already inside ONE `aowl_p_p_seh`; these add no nested guard,
 * because that guard is not re-entrant and a nested one would DISARM it. They
 * are belt-and-braces so that a bad pointer is refused rather than caught. */

static int32_t aowl_msk_readable(const void* p, size_t n) {
    MEMORY_BASIC_INFORMATION mbi;
    const unsigned char* q = (const unsigned char*)p;
    if (!q) return 0;
    if (VirtualQuery(q, &mbi, sizeof(mbi)) == 0) return 0;
    if (mbi.State != MEM_COMMIT) return 0;
    if (mbi.Protect & (PAGE_NOACCESS | PAGE_GUARD)) return 0;
    /* the whole range must lie inside this one committed region */
    if ((const unsigned char*)mbi.BaseAddress + mbi.RegionSize < q + n) return 0;
    return 1;
}

static void* aowl_msk_read_ptr(void* base, int32_t off) {
    void* v = NULL;
    if (!base) return NULL;
    if (!aowl_msk_readable((const char*)base + off, sizeof(void*))) return NULL;
    memcpy(&v, (const char*)base + off, sizeof(void*));
    return v;
}

static int32_t aowl_msk_read_i32(void* base, int32_t off) {
    int32_t v = 0;
    if (!base) return 0;
    if (!aowl_msk_readable((const char*)base + off, sizeof(int32_t))) return 0;
    memcpy(&v, (const char*)base + off, sizeof(int32_t));
    return v;
}

/* Copy a managed `System.String` out as ASCII into `out`, NUL-terminated.
 * Returns the number of characters written, or -1 if the string could not be
 * read safely. Non-ASCII code units become '?', which is fine: this is only
 * ever compared against a profile id, which is hex.
 *
 * CAPPED: never copies more than `cap-1` characters, and refuses a length field
 * that is negative or absurd -- a corrupt length is otherwise an unbounded
 * loop inside a frame. */
#define AOWL_MSK_STR_MAX 256
static int32_t aowl_msk_str_copy(void* s, char* out, int32_t cap) {
    int32_t len, i, n;
    const unsigned char* chars;
    if (!out || cap <= 0) return -1;
    out[0] = 0;
    if (!s) return -1;
    if (!aowl_msk_readable(s, AOWL_MSK_STR_CHARS_OFF + 2)) return -1;
    memcpy(&len, (const char*)s + AOWL_MSK_STR_LEN_OFF, sizeof(int32_t));
    if (len < 0 || len > AOWL_MSK_STR_MAX) return -1;
    chars = (const unsigned char*)s + AOWL_MSK_STR_CHARS_OFF;
    if (len > 0 && !aowl_msk_readable(chars, (size_t)len * 2)) return -1;
    n = len;
    if (n > cap - 1) n = cap - 1;
    for (i = 0; i < n; i++) {
        unsigned int c = (unsigned int)chars[i * 2] |
                         ((unsigned int)chars[i * 2 + 1] << 8);
        out[i] = (c >= 0x20 && c < 0x7F) ? (char)c : '?';
    }
    out[n] = 0;
    return n;
}

/* Does this profile data's ProfileId equal `want`? Guarded end to end; a
 * profile with no ProfileId (an EMPTY slot) can never match, which is what
 * keeps an unbound slot from being selected by accident. */
static int32_t aowl_msk_profile_is(void* profileData, const char* want) {
    char buf[AOWL_MSK_STR_MAX + 1];
    void* s;
    if (!profileData || !want || !want[0]) return 0;
    s = aowl_msk_read_ptr(profileData, AOWL_MSK_PD_PROFILEID_OFF);
    if (!s) return 0;
    if (aowl_msk_str_copy(s, buf, (int32_t)sizeof(buf)) <= 0) return 0;
    return strcmp(buf, want) == 0 ? 1 : 0;
}

/* Read ProfileId / Nickname into a caller buffer, for the log line that makes a
 * run auditable. Never used to decide anything. */
static int32_t aowl_msk_profile_id(void* profileData, char* out, int32_t cap) {
    return aowl_msk_str_copy(
        aowl_msk_read_ptr(profileData, AOWL_MSK_PD_PROFILEID_OFF), out, cap);
}
static int32_t aowl_msk_profile_nick(void* profileData, char* out, int32_t cap) {
    return aowl_msk_str_copy(
        aowl_msk_read_ptr(profileData, AOWL_MSK_PD_NICKNAME_OFF), out, cap);
}
static int32_t aowl_msk_profile_status(void* profileData) {
    return aowl_msk_read_i32(profileData, AOWL_MSK_PD_STATUS_OFF);
}
static int32_t aowl_msk_profile_side(void* profileData) {
    return aowl_msk_read_i32(profileData, AOWL_MSK_PD_SIDE_OFF);
}

/* ---- the one call shape this feature needs ---------------------------- *
 *
 * `Submit(EGameMode gameMode, CharacterSelectionProfileData profileData)` is an
 * INSTANCE method with two arguments, so the frame is
 * `(RCX=this, RDX=gameMode, R8=profileData, R9=MethodInfo*)`.
 *
 * `EGameMode` is an enum -- a 4-byte value type passed BY VALUE in the integer
 * register for its position, which is exactly what `uint64_t` in RDX gives
 * (the callee reads EDX). The value passed is never invented: it is the very
 * `gameMode` this build handed us in R8 at `ShowSlot`, echoed back unchanged,
 * so no EGameMode constant has to be known or guessed.
 *
 * `Submit` is not generic, so a NULL MethodInfo is correct -- the restriction is
 * on SHARED GENERIC code. It is still passed EXPLICITLY rather than left to
 * whatever happens to be in R9. */
typedef void (*AowlMsk_Submit)(void*, uint64_t, void*, void*);
static void aowl_msk_call_submit(void* fn, void* controller,
                                 uint64_t gameMode, void* profileData) {
    if (!fn || !controller) return;
    ((AowlMsk_Submit)fn)(controller, gameMode, profileData, NULL);
}

#endif /* AOWLSPT_MODESKIP_H */
