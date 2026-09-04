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
 * `Status` is READ and LOGGED but NOT gated on.
 *
 * *** THE REASON GIVEN HERE FOR THAT WAS WRONG. CORRECTED 2026-09-02. ***
 *
 * This file used to say that `ECharacterSelectionProfileStatus`'s constant
 * values live in metadata `fieldDefaultValues`, "which neither resolver verb
 * exposes", and therefore that the integer meaning "Available" was not
 * something this host could KNOW. That was true of the resolver at the time
 * and is not true now. MEASURED:
 *
 *   python tools/il2cpp_resolve.py D:/Games/Tarkov/GameAssembly.dll \r
 *          .cache/global-metadata.dec.dat fields \r
 *          EFT.ECharacterSelectionProfileStatus
 *
 * prints the HASDEFAULT constants directly:
 *
 *   Locked = 0    Empty = 1    Available = 2    InRaid = 3
 *
 * (docs/BOOT-FLOW-MAP.md sec. 1.7 and sec. 7 item 1.) So a `Status == 2`
 * gate is now a MEASURED gate, not a guessed one, and the refusal above must
 * not be copied forward into new code. The game's own flow relies on exactly
 * these values: `<SubmitAsync>d__43::MoveNext` @0x13F1500 refuses outright
 * when `profileData.Status@0x20 == 0` (Locked), and
 * `<ExecuteCharacterSelection>d__131::MoveNext` @0x9B6E60 takes its fast path
 * only when `Status == 2` (Available).
 *
 * THIS FILE'S OWN PREDICATE IS STILL ProfileId EQUALITY, and that is still
 * right for THIS path: ProfileId equality is strictly stronger here, because
 * an empty slot carries no ProfileId to match and the one profile the
 * launcher bound is by construction the one that is available. What changes
 * is that any path which SUBSTITUTES its own (gameMode, profileData) pair --
 * notably a `TryCreateInRaidCharacterSelection` @0x97BBF0 bypass, which the
 * game's own code does NOT status-check because `TryGetInRaidProfile` is what
 * enforces InRaid there -- MUST gate on `Status == 2` itself, and can.
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
#define AOWL_MSK_TRYCREATE_RVA   0x97bbf0u

/* ---- F2: the CANDIDATE layouts, to be confirmed at RUNTIME -------------
 *
 * EVERYTHING IN THIS BLOCK IS A CANDIDATE, NOT A MEASUREMENT, and the code
 * that uses it says so in the log. The reason is recorded in
 * docs/BOOT-FLOW-MAP.md 4.3: `CharacterSelectionDataResponse` IS a
 * `Dictionary<EGameMode, CharacterSelectionProfileData>`, and the
 * INSTANTIATED generic layout is NOT reachable offline -- `R fields
 * EFT.CharacterSelectionDataResponse` ends in the `GENERIC -- NO LAYOUT`
 * refusal, and every `Il2CppGenericClass.cached_class` in the metadata file is
 * null. So these offsets come from the SHAPE of CoreCLR's
 * `Dictionary<TKey,TValue>` as IL2CPP compiles it, and the ONLY thing that
 * makes them usable is the runtime self-check in `modeskip.nim`: the value
 * pointer a candidate entry yields must have a klass whose full name reads
 * `EFT.CharacterSelectionProfileData`, its `Status@0x20` must read
 * `Available (2)`, and its `ProfileId@0x78` must equal `launchProfileId`.
 * A wrong layout cannot pass all three. A wrong layout that passed only a
 * readability check is precisely the failure mode this project keeps paying
 * for -- `il2cpp_object_get_class` is `mov rax,[rcx]; ret`, so a bad pointer
 * yields a plausible number in silence.
 *
 * Dictionary<K,V> instance fields, CANDIDATE:
 *   0x10  _buckets   int[]
 *   0x18  _entries   Entry[]
 *   0x20  _count     int32
 * Entry, for TKey = EGameMode (int32) and TValue = a reference, CANDIDATE:
 *   0x00  hashCode  uint32
 *   0x04  next      int32
 *   0x08  key       int32   (+4 padding)
 *   0x10  value     void*
 *   stride 0x18
 * Il2CppArray, the ordinary IL2CPP array header:
 *   0x00 klass  0x08 monitor  0x10 bounds  0x18 max_length  0x20 element 0
 */
#define AOWL_MSK_DICT_BUCKETS_OFF 0x10
#define AOWL_MSK_DICT_ENTRIES_OFF 0x18
#define AOWL_MSK_DICT_COUNT_OFF   0x20
#define AOWL_MSK_ARR_LEN_OFF      0x18
#define AOWL_MSK_ARR_DATA_OFF     0x20
#define AOWL_MSK_ENT_HASH_OFF     0x00
#define AOWL_MSK_ENT_NEXT_OFF     0x04
#define AOWL_MSK_ENT_KEY_OFF      0x08
#define AOWL_MSK_ENT_VALUE_OFF    0x10
#define AOWL_MSK_ENT_STRIDE       0x18
#define AOWL_MSK_ENT_MAX          16
    /* Hard cap on entries examined. A corrupt `_count` cannot become an
     * unbounded loop inside a frame. */

/* CharacterSelectionResult -- the 24-byte out-param. MEASURED from the disasm
 * of 0x97bbf0 (see target [3] below), NOT from a field table: it is a value
 * type, so it has no object header and no klass, and `tools/fldoff.py` cannot
 * describe where a CALLER's buffer lives. */
#define AOWL_MSK_RES_GAMEMODE_OFF  0x00   /* dword */
#define AOWL_MSK_RES_PROFILE_OFF   0x08   /* qword, a managed reference */
#define AOWL_MSK_RES_CANCELLED_OFF 0x10   /* byte  */
#define AOWL_MSK_RES_SIZE          24

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
     * point. A PREFIX detour since eb39963: ShowSlot uses SIX register slots
     * (`this` + 4 declared arguments + IL2CPP's hidden trailing MethodInfo*),
     * and a POSTFIX thunk on more than four shifts the caller's stack
     * arguments. At PREFIX ENTRY the saved registers are exactly the ones the
     * caller passed. Never suppresses the original: the screen is allowed to
     * build itself normally, and is dismissed a frame later.
     *
     * WHAT EACH SAVED SLOT HOLDS -- MEASURED, `il2cpp_resolve.py disasm
     * 0x13efae0`, whose own argument tracing prints:
     *   slot 0 RCX = this: CharacterSelectionScreen
     *   slot 1 RDX = CharacterSelectionSlotViewBase slotView
     *   slot 2 R8  = EGameMode gameMode        (32-bit enum; read as R8D)
     *   slot 3 R9  = CharacterSelectionProfileData profileData
     *   slot 4     = controller  -- ON THE STACK at entry_rsp+0x28
     *   slot 5     = MethodInfo* -- ON THE STACK at entry_rsp+0x30
     * Corroborated inside the body: `mov r13,r9` / `mov edi,r8d` at +0x1d/+0x20,
     * `test r13,r13` guarding the empty-slot path, and
     * `mov rax,[rsp+0xf0]` -- which after `push rbx/rbp/rdi/r13` and
     * `sub rsp,0xa8` is exactly entry_rsp+0x28, the controller.
     *
     * AND WHY READING R8/R9 IS NOT A SUBSTITUTE FOR THE SLOT VIEW'S FIELDS BUT
     * THE SAME VALUES ONE CALL EARLIER: at +0x727 ShowSlot does
     * `mov r8,r13 ; mov edx,edi ; call 0x13f3ca0`
     * = `CharacterSelectionSlotViewBase::Show(gameMode, profileData, viewModel)`,
     * and that method at +0xdd/+0xe4 does
     * `mov [rbx+0x160], r12d`  -> `_gameMode@0x160`
     * `mov [rbx+0x178], r13`   -> `_profileData@0x178`.
     * So ShowSlot's R8/R9 ARE what those two fields become. At PREFIX entry the
     * fields are still 0 -- that is why reading them there pressed nothing.
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

    /* [3] EFT.TarkovApplication::TryCreateInRaidCharacterSelection(
     *         CharacterSelectionDataResponse data,
     *         out CharacterSelectionResult result)   @0x97bbf0
     *
     * THIS IS THE F2 SITE -- the one that skips the screen with NO frame of UI,
     * as opposed to the ShowSlot/Submit route above, which lets the screen be
     * built and then dismisses it.
     *
     * MEASURED (docs/BOOT-FLOW-MAP.md 4.1, `il2cpp_resolve.py member` /
     * `bytes` / `callers`):
     *   attrs 0x0091 PRIVATE|STATIC|HIDEBYSIG, arity 2, section il2cpp,
     *   sharedness UNIQUE (owners=1).
     * It is STATIC, so the ABI is
     *   RCX = data (CharacterSelectionDataResponse)
     *   RDX = &result -- a 24-byte out buffer the CALLER supplies; the boot
     *         passes `lea rdx,[rsi+0x40]`, a field of its own state machine
     *   R8  = MethodInfo*  (the caller passes `xor r8d,r8d`, i.e. NULL)
     * THREE register slots, so no argument of this method ever lives on the
     * caller's stack and a PREFIX sees all of them.
     *
     * ITS BODY, MEASURED (`R disasm 0x97bbf0 --to 0x97bd20`):
     *   if (data == null) goto fail
     *   if (!data.TryGetInRaidProfile(out gameMode, out profile)) goto fail
     *   result->GameMode    = gameMode   (dword at +0x00)
     *   result->ProfileData = profile    (qword at +0x08)
     *   result->Cancelled   = 0          (byte  at +0x10)
     *   <GC write barriers for the two managed slots>
     *   return true
     * fail:
     *   result->{0,0,0}; return false
     * There is no other side effect: it touches no TarkovApplication field,
     * starts no task and shows nothing. THAT is why returning `true` with a
     * correctly filled result skips the screen outright -- the caller branches
     * on the return value BEFORE the selection controller is constructed, and
     * `ShowLanguageSelectionIfNeeded(data)` @0x97bd20 sits on the bypass side
     * of that branch, so taking the bypass does not skip it.
     *
     *   48 89 5C 24 10    mov  [rsp+0x10], rbx
     *   57                push rdi
     *   48 83 EC 40       sub  rsp, 0x40
     *   33 FF             xor  edi, edi
     *   48 8B DA          mov  rbx, rdx
     *   89 ..             (byte 15)
     * NO rip-relative operand in the window, so the 14-byte absolute-jump
     * detour has a clean relocation window -- unlike ShowProfileLoadingScreen,
     * PrepareGame or MainMenuLoad, each of which carries `80 3D <rel32>`
     * inside the first 16 bytes (map section 5, T3).
     *
     * TWO CALLERS, MEASURED (`R callers 0x97bbf0`):
     *   0x9d8735  <RunInitialLobbyFlow>d__121::MoveNext        <- the boot
     *   0x9cd95f  <OpenCharacterSelectionFromMenu>d__118::MoveNext <- in-menu
     * A detour fires for BOTH, and the in-menu "switch character" path must be
     * left alone. `modeskip.nim` therefore acts on the FIRST call of the
     * session only. */
    { "EFT.TarkovApplication::TryCreateInRaidCharacterSelection",
      AOWL_MSK_TRYCREATE_RVA,
      { 0x48,0x89,0x5C,0x24,0x10, 0x57, 0x48,0x83,0xEC,0x40,
        0x33,0xFF, 0x48,0x8B,0xDA, 0x89 }, 16 },
};

#define AOWL_MSK_TARGET_COUNT \
    ((int32_t)(sizeof(aowl_msk_targets) / sizeof(aowl_msk_targets[0])))

#define AOWL_MSK_T_SHOWSLOT 0
#define AOWL_MSK_T_CTOR     1
#define AOWL_MSK_T_SUBMIT   2
#define AOWL_MSK_T_TRYCREATE 3

/* Diagnostics, so a refusal in the log names its own reason rather than being
 * indistinguishable from "the feature was off". */
static int32_t aowl_msk_base_found = 0;
static int32_t aowl_msk_verified   = 0;
static int32_t aowl_msk_rejected   = 0;
/* Verifies refused because the SHARED prologue snapshot table was full --
 * our capacity limit, not a client change. Kept apart from `rejected` so a
 * refusal can never be reported as "this build changed". */
static int32_t aowl_msk_profull = 0;

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
        /* TWO DIFFERENT FAILURES, TWO DIFFERENT REASONS. A verify that failed
         * because OUR snapshot table had no free row says nothing about the
         * client, so it is counted separately and never latched as a
         * signature mismatch. See aowl_pro_last_reason_text(). */
        if (aowl_pro_last_was_table_full()) { aowl_msk_profull++; return NULL; }
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
static int32_t aowl_msk_profull_count(void){ return aowl_msk_profull; }

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

/* ---- KLASS IDENTITY: the check that can actually fail ------------------ *
 *
 * `aowl_msk_readable` proves a page is mapped. It does NOT prove the pointer
 * is a `CharacterSelectionProfileData`, and the crash of 2026-09-02 was
 * exactly that failure: `EGameMode.Pve == 1` sitting where a profile belongs,
 * which no page check can distinguish from an object.
 *
 * The type name is MEASURED, not assumed:
 *   `il2cpp_resolve.py find CharacterSelectionProfileData`
 *     -> 8775 EFT.CharacterSelectionProfileData  (1 hit, searched EXHAUSTIVELY)
 *
 * THREE OUTCOMES, never two. 1 = the klass names that type. 0 = it names
 * something ELSE -- a positive mismatch, and refused. -1 = no name could be
 * read at all, which is INCONCLUSIVE and is logged as such; on its own it does
 * NOT refuse, because the caller has already passed ProfileId string equality,
 * which is a strictly stronger identity test than a name compare (an integer
 * cannot carry a matching 24-hex-digit profile id). Making an unreadable name
 * a refusal would let one bad layout inference kill the whole feature.
 */
#define AOWL_MSK_PD_TYPE   "EFT.CharacterSelectionProfileData"
#define AOWL_MSK_KLASS_MAX 400

/* A FORWARD DECLARATION, not a second implementation.
 * `aowl_comp_klass_fullname` is defined in `abi/aowlspt_components.h`, which
 * `inspect.nim` includes LATER in this SAME translation unit (modeskip.nim and
 * inspect.nim are both `include`d into aowlhost.nim, so there is one C file
 * and the order is the include order). C permits a `static` function to be
 * declared before it is defined; copying the klass->name reader in here would
 * mean two implementations and therefore two possible answers to one question
 * -- and the inspector's `component` verb has already proven THAT reader
 * against live objects on THIS build. */
static int32_t aowl_comp_klass_fullname(const void *klass, char *out, int32_t cap);

static char aowl_msk_klassbuf[AOWL_MSK_KLASS_MAX];

static int32_t aowl_msk_klass_is_pd(void* obj) {
    void* klass = NULL;
    aowl_msk_klassbuf[0] = 0;
    if (!obj) return -1;
    if (!aowl_msk_readable(obj, sizeof(void*))) return -1;
    memcpy(&klass, obj, sizeof(void*));
    if (!klass) return -1;
    if (!aowl_msk_readable(klass, 0x20)) return -1;
    if (!aowl_comp_klass_fullname(klass, aowl_msk_klassbuf,
                                  AOWL_MSK_KLASS_MAX)) return -1;
    return strcmp(aowl_msk_klassbuf, AOWL_MSK_PD_TYPE) == 0 ? 1 : 0;
}

/* Whatever the last `aowl_msk_klass_is_pd` read, so a refusal can NAME the
 * type it actually found instead of asserting a cause with no evidence. */
static const char* aowl_msk_klass_name(void) { return aowl_msk_klassbuf; }

/* ---- F2 probe + skip primitives ---------------------------------------
 *
 * Every one of these is READ-ONLY except `aowl_msk_result_write`, and every
 * one VirtualQuery-checks the exact bytes it is about to touch. None calls
 * into managed code, none allocates, none loops without a cap.
 */

/* The klass full name of an arbitrary object, into the caller's buffer.
 * Returns 1 on success, 0 if no name could be read -- which is INCONCLUSIVE
 * and must never be flattened into "it is not that type". */
static int32_t aowl_msk_klass_name_of(void* obj, char* out, int32_t cap) {
    void* klass = NULL;
    if (!out || cap <= 0) return 0;
    out[0] = 0;
    if (!obj) return 0;
    if (!aowl_msk_readable(obj, sizeof(void*))) return 0;
    memcpy(&klass, obj, sizeof(void*));
    if (!klass) return 0;
    if (!aowl_msk_readable(klass, 0x20)) return 0;
    return aowl_comp_klass_fullname(klass, out, cap) ? 1 : 0;
}

/* `n` bytes at `p` as "xx xx xx ...". Returns the number of BYTES rendered,
 * or -1 if the region is not readable -- never a partial line that could read
 * as data. `n` is hard-capped so a bad argument cannot produce a huge line. */
#define AOWL_MSK_DUMP_MAX 128
static int32_t aowl_msk_hexdump(void* p, int32_t n, char* out, int32_t cap) {
    static const char* aowl_msk_hexd = "0123456789ABCDEF";
    const unsigned char* b = (const unsigned char*)p;
    int32_t i = 0, w = 0;
    if (!out || cap <= 0) return -1;
    out[0] = 0;
    if (n < 0) return -1;
    if (n > AOWL_MSK_DUMP_MAX) n = AOWL_MSK_DUMP_MAX;
    if (!p || !aowl_msk_readable(p, (size_t)n)) return -1;
    for (i = 0; i < n; i++) {
        if (w + 4 >= cap) break;          /* capped, never mid-byte */
        if (i) out[w++] = ' ';
        out[w++] = aowl_msk_hexd[(b[i] >> 4) & 0xF];
        out[w++] = aowl_msk_hexd[b[i] & 0xF];
    }
    out[w] = 0;
    return i;
}

/* Guarded u64 read. `ok` is set to 0 when the address was not readable, so a
 * genuine 0 and an unreadable page stay distinguishable -- two outcomes are
 * not enough here either. */
static uint64_t aowl_msk_read_u64(void* base, int32_t off, int32_t* ok) {
    uint64_t v = 0;
    if (ok) *ok = 0;
    if (!base) return 0;
    if (!aowl_msk_readable((const char*)base + off, sizeof(uint64_t))) return 0;
    memcpy(&v, (const char*)base + off, sizeof(uint64_t));
    if (ok) *ok = 1;
    return v;
}

/* Il2CppArray element base and length, under the array header above. */
static void* aowl_msk_arr_data(void* arr) {
    if (!arr) return NULL;
    if (!aowl_msk_readable(arr, AOWL_MSK_ARR_DATA_OFF + 8)) return NULL;
    return (void*)((char*)arr + AOWL_MSK_ARR_DATA_OFF);
}
static int64_t aowl_msk_arr_len(void* arr) {
    int64_t n = 0;
    if (!arr) return -1;
    if (!aowl_msk_readable((const char*)arr + AOWL_MSK_ARR_LEN_OFF,
                           sizeof(int64_t))) return -1;
    memcpy(&n, (const char*)arr + AOWL_MSK_ARR_LEN_OFF, sizeof(int64_t));
    if (n < 0 || n > 0x10000) return -1;   /* absurd length: refuse */
    return n;
}

/* One CANDIDATE Entry. Returns 1 when the whole entry was readable, 0 when it
 * was not; `key` and `value` are only meaningful on 1. */
static int32_t aowl_msk_entry(void* data, int32_t i, int32_t* key, void** value) {
    const char* e;
    if (key) *key = 0;
    if (value) *value = NULL;
    if (!data || i < 0 || i >= AOWL_MSK_ENT_MAX) return 0;
    e = (const char*)data + (size_t)i * AOWL_MSK_ENT_STRIDE;
    if (!aowl_msk_readable(e, AOWL_MSK_ENT_STRIDE)) return 0;
    if (key)   memcpy(key,   e + AOWL_MSK_ENT_KEY_OFF,   sizeof(int32_t));
    if (value) memcpy(value, e + AOWL_MSK_ENT_VALUE_OFF, sizeof(void*));
    return 1;
}

/* THE ONLY WRITE IN THIS FILE.
 *
 * WHICH KIND OF WRITE IT IS: an OUT-PARAMETER store, not a managed field
 * store. `result` is a 24-byte `CharacterSelectionResult` buffer the CALLER
 * owns; in the boot path it is `[rsi+0x40]`, a field of the caller's own async
 * state machine, so the bytes may well live on the managed heap even though
 * the thing being written is a value type with no header and no klass.
 *
 * That is exactly why it does NOT go through `hostfieldwrite`/`AowlFieldRef`.
 * A FieldRef is admitted by comparing the RECEIVER'S KLASS against the klass
 * the field was resolved on (`aowl_fr_recv_ok`), and this receiver HAS no
 * klass to compare: there is no object header at `result`. Handing a
 * headerless buffer to that path would mean either a refusal every time or,
 * worse, reading a klass pointer out of whatever `[rsi+0x40]` happens to
 * contain -- a check that cannot fail, in the other direction. So the guard
 * used here is the one that actually applies to a raw buffer: an explicit
 * VirtualQuery for 24 COMMITTED WRITABLE bytes inside a single region. The
 * values themselves are never computed -- they are read out of the game's own
 * dictionary.
 *
 * NO GC WRITE BARRIER IS EMITTED, and the original does emit two. REASONED,
 * not measured: this build's collector is Boehm, which is non-moving, so the
 * stored pointer stays valid; and the `CharacterSelectionProfileData` written
 * here is simultaneously reachable from the very dictionary the caller handed
 * us in RCX, which the caller's own state machine holds -- so it cannot be
 * collected while this result is live. This is repeated in `modeskip.nim`
 * where the feature is armed, and it is listed there as UNVERIFIED.
 *
 * Returns 1 if all 24 bytes were written, 0 if the buffer was not writable --
 * in which case the caller MUST let the original run. */
static int32_t aowl_msk_result_write(void* result, int32_t gameMode, void* pd) {
    MEMORY_BASIC_INFORMATION mbi;
    unsigned char zero = 0;
    if (!result) return 0;
    memset(&mbi, 0, sizeof(mbi));
    if (VirtualQuery(result, &mbi, sizeof(mbi)) != sizeof(mbi)) return 0;
    if (mbi.State != MEM_COMMIT) return 0;
    if (mbi.Protect & (PAGE_NOACCESS | PAGE_GUARD)) return 0;
    if (!(mbi.Protect & (PAGE_READWRITE | PAGE_WRITECOPY |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)))
        return 0;
    /* All 24 bytes must sit inside that one committed writable region; a
     * result straddling a region boundary is refused rather than half
     * written. */
    if ((size_t)((char*)result - (char*)mbi.BaseAddress) + AOWL_MSK_RES_SIZE
        > mbi.RegionSize) return 0;
    memcpy((char*)result + AOWL_MSK_RES_GAMEMODE_OFF, &gameMode, sizeof(int32_t));
    memcpy((char*)result + AOWL_MSK_RES_PROFILE_OFF,  &pd,       sizeof(void*));
    memcpy((char*)result + AOWL_MSK_RES_CANCELLED_OFF, &zero,
           sizeof(unsigned char));
    return 1;
}

#endif /* AOWLSPT_MODESKIP_H */
