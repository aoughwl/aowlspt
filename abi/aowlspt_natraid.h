/* aowlspt_natraid.h -- NATIVE RAID ENTRY: the byte-verified target table, the
 * call thunks, and the guarded scalar read/write primitives.
 *
 * WHAT THIS IS FOR
 * ----------------
 * The UI-automation auto-raid (`autoraid.nim`) drives the menu by finding and
 * pressing GameObjects. It stalls on the character/side-select screen, whose
 * control is not reliably pressable. This layer replaces the pressing with a
 * DIRECT call at a static RVA into the game's own commit path, so no
 * GameObject has to be found or pressed at all.
 *
 * THE ROUTE (all offline-measured; see the header comment of `natraid.nim`)
 *
 *   TarkovApplication (the `this` of the Update drain we already ride)
 *     -> get_CurrentRaidSettings()      @0x691340   RaidSettings
 *     -> get_MatchmakerOperation()      @0x977360   MatchmakerOperation
 *   RaidSettings.<Side>k__BackingField      @0x20   ESideType   (Pmc = 0)
 *   RaidSettings.LocationId                 @0x30   string
 *   RaidSettings.<RaidMode>k__BackingField  @0x44   ERaidMode   (Local = 1)
 *   RaidSettings.IsPveOffline               @0xa0   bool
 *   RaidSettings._selectedLocation          @0xa8   Location
 *   MatchmakerOperation._raidSettings       @0x40   RaidSettings
 *   MatchmakerOperation._offlineRaidSettings@0x48   RaidSettings
 *   MatchmakerOperation._readyPressed       @0x60   bool
 *   MatchmakerOperation.<MatchmakerPlayersController>k__BackingField @0xa0
 *     -> OnReadyPressed()               @0xA312E0   void
 *
 * SHAREDNESS, measured with `il2cpp_resolve.py ... shared <RVA>`:
 *   0x977360  UNIQUE   (1 owner)
 *   0xA312E0  UNIQUE   (1 owner)
 *   0x691340  SHARED, 36 owners -- this table CALLS it and NOTHING here ever
 *             detours anything, so the 36-owner blast radius does not apply.
 *             Its whole body is `mov rax,[rcx+0xd8]; ret`, i.e. calling it IS
 *             a field read, with the game's own offset rather than a guess.
 *
 * SAFETY (CLAUDE.md section 5, all of it)
 *   * Every target is 16-byte prologue-verified against the STARTUP SNAPSHOT
 *     (`aowl_pro_verify`), never against live memory -- so a verify here can
 *     never read another feature's trampoline and self-reject.
 *   * VirtualQuery (`aowl_is_readable`) on EVERY hop, and additionally a
 *     writable-protection check before the ONE kind of write this makes.
 *   * NO detour is installed by this file. It rides the existing
 *     `TarkovApplication::Update` drain.
 *   * The refusal reason is RECORDED per target, exactly as `aowl_nu_fn` does,
 *     so "GameAssembly.dll is not loaded yet" can never be reported as "this
 *     build's bytes do not match".
 *
 * MUST be included AFTER `aowlspt_shim.h` (aowl_is_readable) and
 * `aowlspt_prologue.h` (aowl_pro_verify / aowl_pro_prime).
 */
#ifndef AOWLSPT_NATRAID_H
#define AOWLSPT_NATRAID_H

#include <windows.h>
#include <stdint.h>
#include <string.h>

#define AOWL_NR_SIG_BYTES 16

typedef struct {
    const char*   name;
    uint32_t      rva;
    unsigned char sig[AOWL_NR_SIG_BYTES];
    int32_t       siglen;
} AowlNrTarget;

/* Target indices. Keep in step with the table below. */
#define AOWL_NR_T_GET_RAIDSETTINGS   0
#define AOWL_NR_T_GET_MATCHMAKEROP   1
#define AOWL_NR_T_ONREADYPRESSED     2

/* The bytes were read out of D:/Games/Tarkov/GameAssembly.dll with
 * `tools/il2cpp_resolve.py ... bytes <RVA>` and are recorded here so the host
 * can refuse on a build these RVAs did not come from, rather than calling into
 * the middle of some other function. */
static AowlNrTarget aowl_nr_targets[] = {
    { "EFT.TarkovApplication::get_CurrentRaidSettings", 0x691340u,
      { 0x48,0x8B,0x81,0xD8,0x00,0x00,0x00,0xC3,
        0xCC,0xCC,0xCC,0xCC,0xCC,0xCC,0xCC,0xCC }, 16 },
    { "EFT.TarkovApplication::get_MatchmakerOperation", 0x977360u,
      { 0x40,0x55,0x48,0x83,0xEC,0x40,0x80,0x3D,
        0x80,0x1B,0x74,0x06,0x00,0x48,0x8B,0xE9 }, 16 },
    { "EFT.MatchmakerOperation::OnReadyPressed", 0xA312E0u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x80,0x3D,
        0x95,0x7F,0x68,0x06,0x00,0x48,0x8B,0xD9 }, 16 },
};

#define AOWL_NR_TARGET_COUNT \
    ((int32_t)(sizeof(aowl_nr_targets) / sizeof(aowl_nr_targets[0])))

/* Why a target was refused -- the five-reasons lesson from `aowl_nu_fn`. */
#define AOWL_NR_WHY_OK         0
#define AOWL_NR_WHY_NO_MODULE  1   /* GameAssembly.dll not loaded (yet)      */
#define AOWL_NR_WHY_NOT_COMMIT 2   /* the RVA is not committed memory        */
#define AOWL_NR_WHY_NOT_EXEC   3   /* committed, but not executable          */
#define AOWL_NR_WHY_MISMATCH   4   /* THE REAL ONE: the bytes differ         */
#define AOWL_NR_WHY_DISABLED   5   /* the layer has self-disabled            */
#define AOWL_NR_WHY_BADINDEX   6
#define AOWL_NR_WHY_UNTRIED    7   /* never asked for                        */

static int32_t aowl_nr_why[AOWL_NR_TARGET_COUNT] = {
    AOWL_NR_WHY_UNTRIED, AOWL_NR_WHY_UNTRIED, AOWL_NR_WHY_UNTRIED
};
static int32_t aowl_nr_faults = 0;

#define AOWL_NR_MAX_FAULTS 3

static int32_t aowl_nr_disabled(void) {
    return (aowl_nr_faults >= AOWL_NR_MAX_FAULTS) ? 1 : 0;
}
static void    aowl_nr_note_fault(void)  { aowl_nr_faults++; }
static int32_t aowl_nr_fault_count(void) { return aowl_nr_faults; }
static int32_t aowl_nr_target_count(void){ return AOWL_NR_TARGET_COUNT; }

static const char* aowl_nr_name(int32_t i) {
    if (i < 0 || i >= AOWL_NR_TARGET_COUNT) return "";
    return aowl_nr_targets[i].name;
}
static uint32_t aowl_nr_rva(int32_t i) {
    if (i < 0 || i >= AOWL_NR_TARGET_COUNT) return 0u;
    return aowl_nr_targets[i].rva;
}
static int32_t aowl_nr_why_of(int32_t i) {
    if (i < 0 || i >= AOWL_NR_TARGET_COUNT) return AOWL_NR_WHY_BADINDEX;
    return aowl_nr_why[i];
}
static const char* aowl_nr_why_text(int32_t w) {
    switch (w) {
    case AOWL_NR_WHY_OK:         return "verified";
    case AOWL_NR_WHY_NO_MODULE:  return "GameAssembly.dll is not loaded yet";
    case AOWL_NR_WHY_NOT_COMMIT: return "the RVA is not committed memory";
    case AOWL_NR_WHY_NOT_EXEC:   return "committed but not executable";
    case AOWL_NR_WHY_MISMATCH:   return "PROLOGUE BYTES DIFFER from this build";
    case AOWL_NR_WHY_DISABLED:   return "the native-raid layer self-disabled";
    case AOWL_NR_WHY_BADINDEX:   return "bad target index";
    default:                     return "not yet attempted";
    }
}

/* A verified code pointer, or NULL. VirtualQuery FIRST (a stale RVA on another
 * build can address an uncommitted page where memcmp itself faults), then the
 * snapshot compare. */
static void* aowl_nr_fn(int32_t i) {
    HMODULE ga;
    const AowlNrTarget* t;
    unsigned char* p;
    MEMORY_BASIC_INFORMATION mbi;
    if (i < 0 || i >= AOWL_NR_TARGET_COUNT) return NULL;
    if (aowl_nr_disabled()) { aowl_nr_why[i] = AOWL_NR_WHY_DISABLED; return NULL; }
    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) { aowl_nr_why[i] = AOWL_NR_WHY_NO_MODULE; return NULL; }
    t = &aowl_nr_targets[i];
    p = (unsigned char*)ga + t->rva;
    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0 || mbi.State != MEM_COMMIT) {
        aowl_nr_why[i] = AOWL_NR_WHY_NOT_COMMIT;
        return NULL;
    }
    if (!(mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY))) {
        aowl_nr_why[i] = AOWL_NR_WHY_NOT_EXEC;
        return NULL;
    }
    if (!aowl_pro_verify(t->rva, t->sig, t->siglen)) {
        aowl_nr_why[i] = AOWL_NR_WHY_MISMATCH;
        return NULL;
    }
    aowl_nr_why[i] = AOWL_NR_WHY_OK;
    return (void*)p;
}

/* Prime the snapshot for every target at host startup, before any feature has
 * had a chance to patch one. None of these three is a target any other feature
 * in this host detours today -- primed anyway, for the reason the eager pass
 * exists at all. */
static void aowl_nr_prime_all(void) {
    int32_t i;
    for (i = 0; i < AOWL_NR_TARGET_COUNT; i++)
        aowl_pro_prime(aowl_nr_targets[i].rva);
}

/* ------------------------------------------------------------------ *
 *  Call thunks. Instance convention: RCX = this, then the hidden
 *  trailing `const MethodInfo*`. All three targets take ZERO declared
 *  arguments and NONE is a shared generic, so a NULL MethodInfo* is
 *  correct -- the game's own call site for OnReadyToStartMatchingAsync
 *  does `xor r9d,r9d` on the same path.
 * ------------------------------------------------------------------ */
typedef void* (*AowlNr_P_P)(void*, void*);
typedef void  (*AowlNr_V_P)(void*, void*);

static void* aowl_nr_call_getter(void* fn, void* self) {
    if (!fn || !self) return NULL;
    return ((AowlNr_P_P)fn)(self, NULL);
}
static void aowl_nr_call_void(void* fn, void* self) {
    if (!fn || !self) return;
    ((AowlNr_V_P)fn)(self, NULL);
}

/* ------------------------------------------------------------------ *
 *  Guarded scalar access. Rule 2 is per-hop, so each of these does its
 *  OWN VirtualQuery rather than trusting the caller's earlier one.
 * ------------------------------------------------------------------ */
static int32_t aowl_nr_read_i32(void* base, int32_t off, int32_t* out) {
    unsigned char* p;
    if (!base || !out) return 0;
    p = (unsigned char*)base + off;
    if (!aowl_is_readable((void*)p, 4)) return 0;
    memcpy(out, p, 4);
    return 1;
}
static int32_t aowl_nr_read_u8(void* base, int32_t off, int32_t* out) {
    unsigned char* p;
    if (!base || !out) return 0;
    p = (unsigned char*)base + off;
    if (!aowl_is_readable((void*)p, 1)) return 0;
    *out = (int32_t)(*p);
    return 1;
}
static void* aowl_nr_read_ptr(void* base, int32_t off) {
    unsigned char* p;
    void* v = NULL;
    if (!base) return NULL;
    p = (unsigned char*)base + off;
    if (!aowl_is_readable((void*)p, 8)) return NULL;
    memcpy(&v, p, 8);
    return v;
}

/* Is a slot WRITABLE? A readable page is not necessarily a writable one, and a
 * blind store into a read-only page is an access violation, not a no-op. */
static int32_t aowl_nr_writable(void* p, SIZE_T n) {
    MEMORY_BASIC_INFORMATION mbi;
    if (!p) return 0;
    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return 0;
    if (mbi.State != MEM_COMMIT) return 0;
    if (!(mbi.Protect & (PAGE_READWRITE | PAGE_WRITECOPY |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)))
        return 0;
    /* Do not straddle: insist the whole span is inside this one region. */
    if ((unsigned char*)p + n >
        (unsigned char*)mbi.BaseAddress + mbi.RegionSize) return 0;
    return 1;
}

/* READ, VALIDATE, THEN WRITE -- never blind (rule 8). Returns:
 *    2 = the slot already held `v`; NOTHING was written
 *    1 = the slot was read, differed, and was written
 *    0 = refused (unreadable, unwritable, or the read-back did not stick)
 * The read-back is the point: a store that did not take is otherwise
 * indistinguishable from one that did. */
static int32_t aowl_nr_write_i32_checked(void* base, int32_t off, int32_t v) {
    unsigned char* p;
    int32_t cur = 0, back = 0;
    if (!base) return 0;
    p = (unsigned char*)base + off;
    if (!aowl_is_readable((void*)p, 4)) return 0;
    memcpy(&cur, p, 4);
    if (cur == v) return 2;
    if (!aowl_nr_writable((void*)p, 4)) return 0;
    memcpy(p, &v, 4);
    memcpy(&back, p, 4);
    return (back == v) ? 1 : 0;
}

#endif /* AOWLSPT_NATRAID_H */
