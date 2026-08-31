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

/* ------------------------------------------------------------------ *
 * THE LOCATION ROUTE (added after the live probe reported
 * `_selectedLocation@0xa8 = null` as the last blocker)
 *
 * MEASURED OFFLINE, by disassembly, not inferred from names:
 *
 * 1. `RaidSettings::set_SelectedLocation` @0x6D7FF0 (UNIQUE) is NOT a plain
 *    store. Its body is:
 *        [this+0xa8] = value                      (with the GC write barrier)
 *        [this+0x30] = (value == NULL) ? NULL : value->Id@0x28
 *    So `LocationId` is DERIVED FROM `_selectedLocation`, never the reverse.
 *    That kills the cheap hypothesis outright: writing the string "Woods" into
 *    LocationId@0x30 resolves NOTHING. Ready() does not look a Location up from
 *    it -- `LocationLevelVariants::ResolveByPlayerLevel` @0x2345F30 takes a
 *    Location as its FIRST ARGUMENT, i.e. one must already exist.
 *
 * 2. `JsonType.LocationLevelVariants::TryGetLocation(LocationSettings,
 *    string locationReference, out Location)` @0x2345770 (UNIQUE, static) is
 *    the lookup, and it is FULLY SELF-GUARDING on its inputs -- disassembled:
 *        mov [rsi], 0           ; the out param is nulled FIRST
 *        test rbx,rbx / je fail ; locationSettings == NULL      -> false
 *        cmp [rbx+0x10],0 / je  ; .locations == NULL            -> false
 *        test r15,r15 / je fail ; locationReference == NULL     -> false
 *        cmp [r15+0x10],0 / jbe ; the string is EMPTY           -> false
 *    then `Dictionary`2::TryGetValue` with the game's OWN MethodInfo* loaded
 *    from `[rip+...]` -- which is precisely why this entry point is used rather
 *    than calling TryGetValue ourselves: the shared-generic MethodInfo problem
 *    is solved by the game's code, not guessed by ours. On a miss it returns
 *    false with the out param still NULL. There is no path here that faults on
 *    a null input and no path that returns a non-null Location it did not find.
 *
 * 3. The dictionary is keyed by the MONGO ID, not by "Woods". Measured on the
 *    payload OUR OWN BACKEND SERVES (`mods/tarkov/data/post1/locations.json`,
 *    read with tools/bigjson.py, never raw):
 *        locations["5704e3c2d2720bac5b8b4567"]._Id = "5704e3c2d2720bac5b8b4567"
 *        locations["5704e3c2d2720bac5b8b4567"].Id  = "Woods"
 *        locations["5704e3c2d2720bac5b8b4567"].Enabled = true
 *    and `TarkovApplication::TryGetLocationById`'s LINQ predicate @0x9B2C90
 *    compares `loc->[0x28]` (= Location.Id) against its captured string, which
 *    independently confirms which field carries "Woods".
 *
 * 4. `TarkovApplication::TryGetLocationById(string, out Location)` @0x987350
 *    (UNIQUE) is the FALLBACK, keyed by Location.Id ("Woods"). It is NOT the
 *    first choice because it dereferences `[this+0x30]` -- a base-class field
 *    this build's metadata gives no offset for -- and NREs if it is null. Its
 *    inputs are therefore not all ours to check. It is attempted only after the
 *    primary misses, and only with `[this+0x30]` confirmed non-null first.
 *
 * THE FINISHED-STATE ASSERT (CLAUDE.md 9b): after a resolve, the Location's own
 * `Id@0x28` is read back as a String and must equal "Woods". A resolve that
 * returns SOME object is not evidence it returned the RIGHT one, and comparing
 * the pointer to what we asked for is a check that cannot fail.
 * ------------------------------------------------------------------ */

/* Target indices. Keep in step with the table below. */
#define AOWL_NR_T_GET_RAIDSETTINGS   0
#define AOWL_NR_T_GET_MATCHMAKEROP   1
#define AOWL_NR_T_ONREADYPRESSED     2
#define AOWL_NR_T_TRYGETLOCATION     3
#define AOWL_NR_T_SET_SELECTEDLOC    4
#define AOWL_NR_T_TRYGETLOCBYID      5

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
    /* STATIC. (LocationSettings, string, out Location) -> bool.
     * sharedness=UNIQUE (1 owner), section=il2cpp, no thunk shape. */
    { "JsonType.LocationLevelVariants::TryGetLocation", 0x2345770u,
      { 0x48,0x89,0x5C,0x24,0x10,0x4C,0x89,0x44,
        0x24,0x18,0x56,0x57,0x41,0x54,0x41,0x56 }, 16 },
    /* INSTANCE. (Location) -> void. Also sets LocationId@0x30 from Id@0x28,
     * with the GC write barrier -- which is exactly why this is CALLED rather
     * than the two slots being stored by hand.
     * sharedness=UNIQUE (1 owner), section=il2cpp, no thunk shape. */
    { "EFT.RaidSettings::set_SelectedLocation", 0x6D7FF0u,
      { 0x8B,0x05,0x4A,0xE5,0x9D,0x06,0x4C,0x8D,
        0x15,0x23,0x11,0xA0,0x06,0x48,0x89,0x91 }, 16 },
    /* INSTANCE, the FALLBACK. (string, out Location) -> bool.
     * sharedness=UNIQUE (1 owner), section=il2cpp, no thunk shape. */
    { "EFT.TarkovApplication::TryGetLocationById", 0x987350u,
      { 0x48,0x89,0x5C,0x24,0x10,0x48,0x89,0x74,
        0x24,0x18,0x48,0x89,0x7C,0x24,0x20,0x41 }, 16 },
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
#define AOWL_NR_WHY_PROFULL    8   /* OURS: the shared prologue snapshot
                                     * table was full; the RVA was never
                                     * captured. NOT a client change. */

static int32_t aowl_nr_why[AOWL_NR_TARGET_COUNT] = {
    AOWL_NR_WHY_UNTRIED, AOWL_NR_WHY_UNTRIED, AOWL_NR_WHY_UNTRIED,
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
static int32_t aowl_nr_profull_count(void){
    int32_t i, n = 0;
    for (i = 0; i < AOWL_NR_TARGET_COUNT; i++)
        if (aowl_nr_why[i] == AOWL_NR_WHY_PROFULL) n++;
    return n;
}

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
        /* TWO DIFFERENT FAILURES, TWO DIFFERENT REASONS. A verify that failed
         * because OUR snapshot table had no free row says nothing about the
         * client, so it is counted separately and never latched as a
         * signature mismatch. See aowl_pro_last_reason_text(). */
        if (aowl_pro_last_was_table_full()) {
            aowl_nr_why[i] = AOWL_NR_WHY_PROFULL;
            return NULL;
        }
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
 *  The location-resolve thunks.
 *
 *  NEITHER target is a shared generic (both `shared <RVA>` = UNIQUE, 1 owner)
 *  and NEITHER reads its trailing MethodInfo* -- verified by disassembly: R9 at
 *  0x2345770 and R8 at 0x6D7FF0 are both dead on entry and are reloaded before
 *  first use. A NULL MethodInfo* is therefore correct here, not merely "usually
 *  fine".
 *
 *  Static, 3 declared params:  RCX, RDX, R8, then MethodInfo* in R9.
 *  Instance, 1 declared param: RCX = this, RDX = arg, then MethodInfo* in R8.
 * ------------------------------------------------------------------ */
typedef unsigned char (*AowlNr_B_PPPP)(void*, void*, void*, void*);
typedef void          (*AowlNr_V_PPP) (void*, void*, void*);
/* the fallback is an INSTANCE method with 2 declared params, so its hidden
 * MethodInfo* lands in R9 -- same four-slot shape as the static above. */

/* TryGetLocation(locationSettings, id, &out). Returns 1 on a hit AND a
 * non-NULL out; 0 otherwise. The callee nulls `out` itself before doing
 * anything, so a 0 here cannot leave a stale pointer behind -- but it is
 * pre-nulled on this side too, because relying on the callee to initialise our
 * own stack is exactly the assumption that would not survive a build change. */
static int32_t aowl_nr_try_get_location(void* fn, void* locSettings,
                                        void* idStr, void** out) {
    void* loc = NULL;
    unsigned char ok;
    if (out) *out = NULL;
    if (!fn || !locSettings || !idStr || !out) return 0;
    ok = ((AowlNr_B_PPPP)fn)(locSettings, idStr, (void*)&loc, NULL);
    if (!ok || !loc) return 0;
    *out = loc;
    return 1;
}

/* TarkovApplication::TryGetLocationById(id, &out) -- the fallback. */
static int32_t aowl_nr_try_get_location_by_id(void* fn, void* self,
                                              void* idStr, void** out) {
    void* loc = NULL;
    unsigned char ok;
    if (out) *out = NULL;
    if (!fn || !self || !idStr || !out) return 0;
    ok = ((AowlNr_B_PPPP)fn)(self, idStr, (void*)&loc, NULL);
    if (!ok || !loc) return 0;
    *out = loc;
    return 1;
}

/* RaidSettings::set_SelectedLocation(loc). */
static void aowl_nr_set_selected_location(void* fn, void* self, void* loc) {
    if (!fn || !self || !loc) return;
    ((AowlNr_V_PPP)fn)(self, loc, NULL);
}

/* ------------------------------------------------------------------ *
 *  `il2cpp_string_new`, resolved by name and CACHED.
 *
 *  Rule 7 is "no per-frame managed allocation", not "no allocation": this
 *  allocates AT MOST ONCE per distinct literal for the whole session and hands
 *  back the same Il2CppString* thereafter, so the drain can ask for it every
 *  tick without ever allocating again. `il2cpp_string_new` is NOT one of the
 *  token-gated exports (it takes no trailing 32-byte token), so calling it by
 *  name is safe -- unlike `il2cpp_object_get_class` and friends.
 *
 *  NOTE the string is NOT GC-rooted. It is created and consumed inside the same
 *  guarded tick on the Unity main thread, and the cache is only ever re-USED
 *  as an argument to a lookup that copies nothing. If this ever needs to
 *  survive a collection, it needs a gchandle -- say so rather than assuming.
 * ------------------------------------------------------------------ */
#define AOWL_NR_MAX_STRINGS 4
#define AOWL_NR_STR_LEN     40

typedef struct { char text[AOWL_NR_STR_LEN]; void* str; } AowlNrStr;
static AowlNrStr g_nr_strings[AOWL_NR_MAX_STRINGS];
static int32_t   g_nr_string_n = 0;
static void*     (*g_nr_string_new)(const char*) = 0;
static int32_t   g_nr_string_export_tried = 0;

static void* aowl_nr_string(const char* s) {
    int32_t i;
    size_t n;
    HMODULE ga;
    if (!s) return NULL;
    n = strlen(s);
    if (n == 0 || n >= AOWL_NR_STR_LEN) return NULL;
    for (i = 0; i < g_nr_string_n && i < AOWL_NR_MAX_STRINGS; i++)
        if (strcmp(g_nr_strings[i].text, s) == 0)
            return g_nr_strings[i].str;
    if (g_nr_string_n >= AOWL_NR_MAX_STRINGS) return NULL;
    if (!g_nr_string_export_tried) {
        g_nr_string_export_tried = 1;
        ga = GetModuleHandleA("GameAssembly.dll");
        if (ga)
            g_nr_string_new = (void* (*)(const char*))(void*)
                GetProcAddress(ga, "il2cpp_string_new");
    }
    if (!g_nr_string_new) return NULL;
    {
        void* v = g_nr_string_new(s);
        if (!v) return NULL;
        memcpy(g_nr_strings[g_nr_string_n].text, s, n + 1);
        g_nr_strings[g_nr_string_n].str = v;
        g_nr_string_n++;
        return v;
    }
}
static int32_t aowl_nr_string_export_ok(void) {
    return g_nr_string_new ? 1 : 0;
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
