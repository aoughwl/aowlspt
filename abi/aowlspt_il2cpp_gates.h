/* aowlspt_il2cpp_gates.h -- calling the TOKEN-GATED il2cpp exports correctly.
 *
 * WHY THIS EXISTS
 * ===============
 * For months this project recorded "IL2CPP reflection is dead": a handle came
 * back non-NULL, the nil check passed, and the first dereference killed the
 * client. `docs/IL2CPP_EXPORTS.md` established the real mechanism and this
 * header acts on it.
 *
 * 40 of the 241 `il2cpp_*` exports take an EXTRA TRAILING ARGUMENT that stock
 * IL2CPP does not have: a pointer to 32 bytes. The callee `memcmp`s it before
 * doing any work. On mismatch it does NOT return NULL and does NOT abort -- it
 * tail-calls a trap that lazily seeds a per-thread MT19937-64 and returns a
 * UNIFORM RANDOM NON-ZERO uint64.
 *
 * That is the whole bug. We were calling these with the stock signature, so the
 * token argument was whatever junk happened to be in the register, the compare
 * failed every time, and we got a random number that looked like a pointer.
 *
 * MEASURED, NOT ASSUMED
 * =====================
 * Everything below was verified OFFLINE against
 * `D:\Games\Tarkov\GameAssembly.dll` (123,891,024 bytes) by mapping it into a
 * scratch process -- never the running game -- and calling one export against a
 * STAGED receiver buffer we allocated and filled ourselves, so the correct
 * answer was known independently of the call.
 *
 *   il2cpp_method_get_param_count(staged, correct_token)  -> 7, 7, 7, 7, 7
 *   il2cpp_method_get_param_count(staged, corrupt_token)  -> 8551E516, 23DBF07,
 *                                                            DA01ECF3, ...
 *   il2cpp_method_get_param_count(staged, NULL)           -> 1AD46590, E65AE66A,
 *                                                            F4201CA4  <- what
 *                                                            we always did
 *
 * The staged buffer had 7 written at +0x52, which is the byte this export
 * actually reads (`movzx eax, byte ptr [rbx+0x52]`). Identical-with-token and
 * all-different-without-token is the falsifiable pair; "it returned something"
 * proves nothing here, because the trap also returns something.
 *
 * THE TWO GATE FLAVOURS
 * =====================
 * STATIC (22 exports). The expected 32 bytes are a constant in `.rdata`. The
 * caller passes a pointer to them. Read them FROM THE MAPPED IMAGE at runtime
 * (`base + token_rva`); never hardcode an absolute address, and never copy the
 * bytes into source, because they are build-specific.
 *
 * NONCE (18 exports). The callee reads a 64-bit nonce from a per-API TLS slot,
 * ZEROES the slot (single use), calls a per-API derivation function, and
 * memcmps its result against the caller's 32 bytes. The nonce is produced by
 * the exported, NON-STOCK `il2cpp_nonce(apiId)` @ 0x5B3D60.
 *
 * The apiId -> slot mapping is not in any symbol; it was recovered mechanically
 * by calling `il2cpp_nonce(id)` for every id and observing which TLS slot
 * became non-zero. `il2cpp_nonce` also RETURNS the value it stores, so the
 * caller never has to read TLS at all.
 *
 * Verified end to end on `il2cpp_field_get_offset` (apiId 0x58, slot 0x198,
 * derivation 0x5B93B0) against a staged FieldInfo with 42 at +0x18:
 *
 *   nonce = il2cpp_nonce(0x58); tok = deriv(nonce);
 *   il2cpp_field_get_offset(staged, tok) -> 42, 42, 42, 42, 42
 *   il2cpp_field_get_offset(staged, junk)  (no nonce obtained)
 *        -> D960FE44EADCA5E9, 43C9CE620DA369B5, F3999C704C1CD6CA
 *
 * HONEST LIMIT on the nonce flavour: perturbing the nonce passed to the
 * derivation function did not change its return pointer, so it is NOT measured
 * that the derivation is keyed by the nonce value. What IS measured is that the
 * slot must be non-empty -- calling without first obtaining a nonce traps. Treat
 * "the derivation is nonce-keyed" as INCONCLUSIVE, not as fact.
 *
 * SAFETY
 * ======
 * A wrong token is not a soft failure. It yields a plausible random pointer,
 * and the caller's first dereference kills the client. So this layer:
 *   - is flag-gated and DEFAULT OFF (`il2cppGates`);
 *   - byte-verifies each export's prologue against the STARTUP SNAPSHOT before
 *     the first call, never against live memory (a verify run after another
 *     feature patched the function reads trampoline bytes and self-rejects);
 *   - VirtualQuery-checks the module base, the token bytes and the receiver;
 *   - runs the call under ONE `aowl_p_p_seh` and never nests one inside it;
 *   - caps iteration everywhere;
 *   - self-disables after AOWL_GATE_MAX_FAULTS faults;
 *   - refuses loudly rather than calling with an unverified token.
 *
 * A NOTE ON NIL CHECKS, per CLAUDE.md 9b. The two existing nil checks in shared
 * code -- `ensureCall`'s `if c == nil: return false` and `readCString`'s
 * `if p == nil` -- are checks that CANNOT FAIL against this trap, because the
 * trap never returns zero. Callers must stop treating non-NULL as success and
 * use `aowl_gate_call_ok()`, which reports whether the GATE was satisfied,
 * separately from whatever the export returned.
 */
#ifndef AOWLSPT_IL2CPP_GATES_H
#define AOWLSPT_IL2CPP_GATES_H

#include <windows.h>
#include <string.h>
#include <stdint.h>

#include "aowlspt_shim.h"              /* aowl_p_p_seh, aowl_is_readable */
#include "aowlspt_il2cpp_gates_data.h" /* GENERATED: the 40 rows + export list */

#define AOWL_GATE_TOKEN_BYTES 32
#define AOWL_GATE_MAX_FAULTS   3
#define AOWL_GATE_SIG_BYTES   16

/* ---- outcomes. Three, never two: OK / a named refusal / FAULTED. ---------- */
#define AOWL_GATE_OK            0
#define AOWL_GATE_DISABLED      1  /* flag off, or self-disabled after faults  */
#define AOWL_GATE_NO_MODULE     2  /* GameAssembly.dll is not loaded           */
#define AOWL_GATE_UNKNOWN       3  /* export name is not in the generated map  */
#define AOWL_GATE_NOT_GATED     4  /* ungated: call it with the stock signature*/
#define AOWL_GATE_BAD_TOKEN     5  /* the token bytes are unreadable           */
#define AOWL_GATE_BAD_ARG       6  /* the receiver failed VirtualQuery         */
#define AOWL_GATE_PROLOGUE      7  /* prologue != startup snapshot             */
#define AOWL_GATE_NO_NONCE      8  /* il2cpp_nonce returned 0 for this apiId   */
#define AOWL_GATE_NO_DERIV      9  /* no derivation fn recorded for this row   */
#define AOWL_GATE_FAULTED      10  /* the call took an access violation        */
#define AOWL_GATE_ARITY        11  /* token arg index beyond what we dispatch  */

static const char* aowl_gate_why(int32_t w) {
    switch (w) {
    case AOWL_GATE_OK:        return "ok";
    case AOWL_GATE_DISABLED:  return "the il2cppGates flag is off, or the layer self-disabled after repeated faults";
    case AOWL_GATE_NO_MODULE: return "GameAssembly.dll is not loaded";
    case AOWL_GATE_UNKNOWN:   return "that export is not in the generated gate map -- regenerate tools/il2cpp_gatescan.py against this build";
    case AOWL_GATE_NOT_GATED: return "that export is NOT token-gated; call it with the stock signature, passing no token";
    case AOWL_GATE_BAD_TOKEN: return "the expected token bytes are not readable at their .rdata RVA -- wrong build, or the map is stale";
    case AOWL_GATE_BAD_ARG:   return "the receiver pointer failed VirtualQuery";
    case AOWL_GATE_PROLOGUE:  return "the export's first bytes are not the startup snapshot: something detoured it, or the map is for a different build";
    case AOWL_GATE_NO_NONCE:  return "il2cpp_nonce(apiId) returned 0 -- the handshake did not arm the TLS slot, so the call would trap to a random value";
    case AOWL_GATE_NO_DERIV:  return "no derivation function was recovered for this nonce-gated export";
    case AOWL_GATE_FAULTED:   return "the call took an access violation and was caught";
    case AOWL_GATE_ARITY:     return "the token argument sits beyond the fourth register and this layer does not place stack arguments";
    default:                  return "unknown";
    }
}

/* ---- module state -------------------------------------------------------- */
/* THE MOST DANGEROUS PROPERTY OF THIS WHOLE LAYER. Read this before touching
 * anything below.
 *
 * A nonce-gated export begins:
 *
 *     49 83 3C 07 00     cmp qword ptr [tls_slot], 0
 *     74 7E              je   -> the trap
 *
 * If the slot is ZERO it jumps STRAIGHT to the trap, returns a random value,
 * and NEVER TOUCHES THE CALLER'S TOKEN. The slot has been zero for the entire
 * life of this project, because nothing ever called `il2cpp_nonce`. That
 * accident is the ONLY reason years of stock-signature by-name calls -- the
 * ~20 in `mods/sain` alone -- returned garbage instead of crashing.
 *
 * `il2cpp_nonce(apiId)` ARMS that slot, and the arming is SINGLE USE: only the
 * export itself consumes it (it zeroes the slot as it reads it). So arming a
 * slot and not immediately calling the export LEAVES A LOADED GUN ON THIS
 * THREAD: the next stock-signature caller no longer early-outs, and instead
 * reaches `memcmp(caller_token, deriv(nonce), 32)` with a token that is
 * whatever junk was in the register. That is an access violation inside
 * memcmp, at GameAssembly.dll+0x6206E0.
 *
 * MEASURED, in a scratch process against the real GameAssembly.dll:
 *   slot zero   -> il2cpp_field_get_offset(staged, 0xCDCD..) = 396CF427.. , no fault
 *   slot armed  -> same call = ACCESS VIOLATION at +0x6206E0 reading 0xFFFF..
 * That offset is byte-identical to the WER fault offset that killed the live
 * client the first time this layer ran, ~1s after the self-test PASSED.
 *
 * Note what did NOT happen: the crash never went through `aowl_gate_call`, so
 * the fault counter stayed at 0 and the layer never self-disabled. A gate can
 * only count its own faults; it cannot count the ones it ARMED FOR SOMEONE
 * ELSE. Hence `aowl_gate_nonce_outstanding` below, which is the check that
 * actually fires.
 *
 * THE RULE: never arm a nonce you will not consume in the same breath. If you
 * only want to know whether a row COULD arm, call `aowl_gate_can_arm`, which
 * reads the static map and never touches the runtime.
 */
static int32_t        aowl_gate_nonce_outstanding = 0;

static unsigned char* aowl_gate_base    = 0;
static size_t         aowl_gate_size    = 0;
static int32_t        aowl_gate_enabled = 0;   /* rule 5: DEFAULT OFF          */
static int32_t        aowl_gate_faults  = 0;   /* rule 6: self-disable         */
static int32_t        aowl_gate_snapped = 0;
static unsigned char  aowl_gate_snap[AOWL_GATE_ROWS][AOWL_GATE_SIG_BYTES];
static unsigned char  aowl_gate_snap_ok[AOWL_GATE_ROWS];

static int32_t aowl_gate_bind_module(void) {
    if (aowl_gate_base) return 1;
    {
        HMODULE h = GetModuleHandleA("GameAssembly.dll");
        MEMORY_BASIC_INFORMATION mbi;
        if (!h) return 0;
        aowl_gate_base = (unsigned char*)h;
        /* image size from the PE header, so bounds checks are real */
        {
            IMAGE_DOS_HEADER* dos = (IMAGE_DOS_HEADER*)aowl_gate_base;
            IMAGE_NT_HEADERS64* nt;
            if (!aowl_is_readable(aowl_gate_base, 0x40)) { aowl_gate_base = 0; return 0; }
            nt = (IMAGE_NT_HEADERS64*)(aowl_gate_base + dos->e_lfanew);
            if (!aowl_is_readable(nt, sizeof(*nt)))      { aowl_gate_base = 0; return 0; }
            aowl_gate_size = (size_t)nt->OptionalHeader.SizeOfImage;
        }
        (void)mbi;
    }
    return 1;
}

/* THE STARTUP SNAPSHOT. Must be taken once, early, before any feature has had a
 * chance to detour anything. Verifying against live memory instead would read a
 * trampoline and self-reject -- a hook-order problem misreported as a bad RVA. */
static void aowl_gate_snapshot(void) {
    int32_t i;
    if (aowl_gate_snapped) return;
    if (!aowl_gate_bind_module()) return;
    for (i = 0; i < AOWL_GATE_ROWS; i++) {          /* rule 4: capped */
        unsigned char* p = aowl_gate_base + aowl_gate_rows[i].export_rva;
        aowl_gate_snap_ok[i] = 0;
        if (aowl_gate_rows[i].export_rva >= aowl_gate_size) continue;
        if (!aowl_is_readable(p, AOWL_GATE_SIG_BYTES)) continue;
        memcpy(aowl_gate_snap[i], p, AOWL_GATE_SIG_BYTES);
        aowl_gate_snap_ok[i] = 1;
    }
    aowl_gate_snapped = 1;
}

static void aowl_gate_set_enabled(int32_t on) { aowl_gate_enabled = on ? 1 : 0; }

static int32_t aowl_gate_find(const char* name) {
    int32_t i;
    if (!name) return -1;
    for (i = 0; i < AOWL_GATE_ROWS; i++)            /* rule 4: capped */
        if (strcmp(aowl_gate_rows[i].name, name) == 0) return i;
    return -1;
}

/* Is this export gated at all? Answers for the WHOLE 241-export surface, so a
 * caller can route ungated exports straight through instead of guessing. */
static int32_t aowl_gate_is_gated(const char* name) {
    return aowl_gate_find(name) >= 0 ? 1 : 0;
}
static int32_t aowl_gate_is_known_export(const char* name) {
    int32_t i;
    if (!name) return 0;
    for (i = 0; i < AOWL_IL2CPP_EXPORT_COUNT; i++)  /* rule 4: capped */
        if (strcmp(aowl_il2cpp_exports[i], name) == 0) return 1;
    return 0;
}

/* apiId -> TLS slot, recovered mechanically (see the header comment). We key on
 * the SLOT, which the generated map records per export, so no apiId is ever
 * guessed from a name. */
typedef struct { unsigned slot; unsigned apiId; } aowl_gate_apiid_t;
static const aowl_gate_apiid_t aowl_gate_apiids[] = {
    { 0x118, 0x95 }, { 0x140, 0x56 }, { 0x148, 0x88 }, { 0x170, 0x26 },
    { 0x198, 0x58 }, { 0x200, 0x19 }, { 0x208, 0x2B }, { 0x270, 0x89 },
    { 0x278, 0x91 }, { 0x280, 0x2E }, { 0x288, 0x8A }, { 0x2B0, 0x22 },
    { 0x2D8, 0x57 }, { 0x2E0, 0x2D },
};
#define AOWL_GATE_APIID_COUNT ((int32_t)(sizeof(aowl_gate_apiids)/sizeof(aowl_gate_apiids[0])))

static int32_t aowl_gate_apiid_for_slot(unsigned slot, unsigned* out) {
    int32_t i;
    for (i = 0; i < AOWL_GATE_APIID_COUNT; i++)
        if (aowl_gate_apiids[i].slot == slot) { *out = aowl_gate_apiids[i].apiId; return 1; }
    return 0;
}

/* ---- the token for a row ------------------------------------------------- */
/* STATIC: a pointer straight into the mapped .rdata -- no copy, no hardcoding.
 * NONCE : run the handshake, return the derivation's pointer.
 * Returns NULL and sets *why on any refusal. NEVER returns an unverified
 * pointer, because an unverified token is indistinguishable from success until
 * the caller dereferences the random value it produces. */
static void* aowl_gate_token(int32_t row, int32_t* why) {
    const aowl_gate_row_t* r;
    *why = AOWL_GATE_OK;
    if (row < 0 || row >= AOWL_GATE_ROWS) { *why = AOWL_GATE_UNKNOWN; return 0; }
    if (!aowl_gate_bind_module())         { *why = AOWL_GATE_NO_MODULE; return 0; }
    r = &aowl_gate_rows[row];

    if (r->kind == AOWL_GATE_KIND_STATIC) {
        unsigned char* t;
        if (r->token_rva == 0 || r->token_rva >= aowl_gate_size) { *why = AOWL_GATE_BAD_TOKEN; return 0; }
        t = aowl_gate_base + r->token_rva;
        if (!aowl_is_readable(t, AOWL_GATE_TOKEN_BYTES))         { *why = AOWL_GATE_BAD_TOKEN; return 0; }
        return t;
    }

    /* NONCE */
    {
        unsigned apiId = 0;
        uint64_t n;
        void* tok;
        typedef uint64_t (*nonce_fn)(unsigned);
        typedef void*    (*deriv_fn)(uint64_t);
        nonce_fn nonce;
        deriv_fn deriv;

        if (r->deriv_rva == 0 || r->deriv_rva >= aowl_gate_size) { *why = AOWL_GATE_NO_DERIV; return 0; }
        if (!aowl_gate_apiid_for_slot(r->tls_slot, &apiId))      { *why = AOWL_GATE_NO_NONCE; return 0; }
        if (AOWL_IL2CPP_NONCE_RVA == 0 ||
            AOWL_IL2CPP_NONCE_RVA >= aowl_gate_size)             { *why = AOWL_GATE_NO_NONCE; return 0; }

        nonce = (nonce_fn)(aowl_gate_base + AOWL_IL2CPP_NONCE_RVA);
        deriv = (deriv_fn)(aowl_gate_base + r->deriv_rva);

        /* The nonce is SINGLE USE: the export zeroes the slot as it reads it.
         * So this pair must run immediately before each call, never cached. */
        n = nonce(apiId);
        if (n == 0) { *why = AOWL_GATE_NO_NONCE; return 0; }
        /* THE SLOT IS NOW ARMED AND ONLY THE EXPORT CAN DISARM IT. From here
         * to the call there must be no early return that does not account for
         * it -- see the block comment at the top of this file. */
        aowl_gate_nonce_outstanding++;
        tok = deriv(n);
        if (!aowl_is_readable(tok, AOWL_GATE_TOKEN_BYTES)) {
            /* The slot stays armed and we cannot clear it without a blind
             * write into TLS (rule 8). Leave the counter incremented so the
             * caller learns this thread is now unsafe for stock-signature
             * calls into this export, and say why. */
            *why = AOWL_GATE_BAD_TOKEN; return 0;
        }
        return tok;
    }
}

/* Would this row be able to produce a token? PURE: it reads the generated map
 * and the mapped image only, and NEVER calls `il2cpp_nonce`, so it cannot arm
 * anything. This is what a survey must use. Calling `aowl_gate_token` merely
 * to count what works is what killed the client. */
static int32_t aowl_gate_can_arm(int32_t row, int32_t* why) {
    const aowl_gate_row_t* r;
    unsigned apiId;
    *why = AOWL_GATE_OK;
    if (row < 0 || row >= AOWL_GATE_ROWS) { *why = AOWL_GATE_UNKNOWN; return 0; }
    if (!aowl_gate_bind_module())         { *why = AOWL_GATE_NO_MODULE; return 0; }
    r = &aowl_gate_rows[row];
    if (r->kind == AOWL_GATE_KIND_STATIC) {
        /* For a static row this is a real MEASUREMENT, not a structural claim:
         * the expected bytes are read out of .rdata and checked. */
        unsigned char* t;
        if (r->token_rva == 0 || r->token_rva >= aowl_gate_size) { *why = AOWL_GATE_BAD_TOKEN; return 0; }
        t = aowl_gate_base + r->token_rva;
        if (!aowl_is_readable(t, AOWL_GATE_TOKEN_BYTES))         { *why = AOWL_GATE_BAD_TOKEN; return 0; }
        return 1;
    }
    /* For a nonce row this is STRUCTURAL ONLY -- it says the map has a
     * derivation and an apiId, not that a nonce would come back. Report it as
     * ARMABLE, never as ARMED. */
    if (r->deriv_rva == 0 || r->deriv_rva >= aowl_gate_size) { *why = AOWL_GATE_NO_DERIV; return 0; }
    if (!aowl_gate_apiid_for_slot(r->tls_slot, &apiId))      { *why = AOWL_GATE_NO_NONCE; return 0; }
    if (AOWL_IL2CPP_NONCE_RVA == 0 ||
        AOWL_IL2CPP_NONCE_RVA >= aowl_gate_size)             { *why = AOWL_GATE_NO_NONCE; return 0; }
    return 1;
}

static int32_t aowl_gate_nonce_outstanding_count(void) {
    return aowl_gate_nonce_outstanding;
}

/* ---- the call ------------------------------------------------------------ */
/* Up to four integer-class arguments, with the token spliced in at the index
 * the generated map recorded. `argc` counts the caller's own arguments, NOT the
 * token. The token is appended/inserted by us; a caller must never pass one. */
typedef struct {
    void*   args[4];
    int32_t argc;
    void*   ret;       /* raw return value                                    */
    int32_t why;       /* AOWL_GATE_*; ONLY AOWL_GATE_OK means the gate passed*/
    int32_t done;      /* 0 => the call FAULTED and the guard caught it       */
} aowl_gate_call_t;

static void* aowl_gate_invoke_thunk(void* p) {
    aowl_gate_call_t* c = (aowl_gate_call_t*)p;
    typedef void* (*f4)(void*, void*, void*, void*);
    f4 f = (f4)c->args[0];   /* slot 0 carries the target on entry */
    void* r = f(c->args[1], c->args[2], c->args[3], c->ret);
    /* `aowl_p_p_seh` returns 0 both for a caught fault and for a legitimate 0
     * return, so its value alone CANNOT distinguish them -- a check that cannot
     * fail. This flag can: it is only ever reached if the call returned. */
    c->done = 1;
    return r;
}

/* Returns 1 only when the GATE was satisfied and the call completed. The
 * export's own return value is in `out->ret`. Do NOT infer success from
 * `ret != NULL`: the trap never returns NULL. */
static int32_t aowl_gate_call(const char* name, void** argv, int32_t argc,
                              aowl_gate_call_t* out) {
    int32_t row, why = AOWL_GATE_OK, i;
    const aowl_gate_row_t* r;
    void* tok;
    void* slots[5];
    unsigned char* fp;

    memset(out, 0, sizeof(*out));
    out->why = AOWL_GATE_DISABLED;

    if (!aowl_gate_enabled)                    { out->why = AOWL_GATE_DISABLED; return 0; }
    if (aowl_gate_faults >= AOWL_GATE_MAX_FAULTS) { out->why = AOWL_GATE_DISABLED; return 0; }
    if (!aowl_gate_bind_module())              { out->why = AOWL_GATE_NO_MODULE; return 0; }

    row = aowl_gate_find(name);
    if (row < 0) {
        out->why = aowl_gate_is_known_export(name) ? AOWL_GATE_NOT_GATED : AOWL_GATE_UNKNOWN;
        return 0;
    }
    r = &aowl_gate_rows[row];
    if (argc < 0 || argc > 3)                  { out->why = AOWL_GATE_ARITY; return 0; }
    if (r->argidx > 3)                         { out->why = AOWL_GATE_ARITY; return 0; }

    /* rule 1: prologue byte-verify against the STARTUP SNAPSHOT */
    aowl_gate_snapshot();
    fp = aowl_gate_base + r->export_rva;
    if (!aowl_gate_snap_ok[row] ||
        !aowl_is_readable(fp, AOWL_GATE_SIG_BYTES) ||
        memcmp(fp, aowl_gate_snap[row], AOWL_GATE_SIG_BYTES) != 0) {
        out->why = AOWL_GATE_PROLOGUE; return 0;
    }

    /* rule 2: VirtualQuery every caller pointer we are about to hand over */
    for (i = 0; i < argc; i++)
        if (argv[i] && !aowl_is_readable(argv[i], 1)) { out->why = AOWL_GATE_BAD_ARG; return 0; }

    tok = aowl_gate_token(row, &why);
    if (!tok) { out->why = why; return 0; }

    /* splice: caller args fill the non-token slots in order */
    {
        int32_t src = 0;
        for (i = 0; i < 4; i++) slots[i] = 0;
        for (i = 0; i < 4; i++) {
            if (i == (int32_t)r->argidx) slots[i] = tok;
            else if (src < argc)         slots[i] = argv[src++];
        }
    }

    /* rule 3: ONE guard around the whole body, never nested */
    {
        aowl_gate_call_t c;
        void* rv;
        memset(&c, 0, sizeof(c));
        c.args[0] = (void*)fp;
        c.args[1] = slots[0];
        c.args[2] = slots[1];
        c.args[3] = slots[2];
        c.ret     = slots[3];
        rv = aowl_p_p_seh((void*)aowl_gate_invoke_thunk, &c);
        /* The export zeroes the nonce slot as it READS it, which happens
         * before the memcmp that can fault -- so the arm is consumed whether
         * or not the call completed. Account for it on BOTH paths, or the
         * outstanding counter drifts and reports a hazard that is not there. */
        if (r->kind == AOWL_GATE_KIND_NONCE && aowl_gate_nonce_outstanding > 0)
            aowl_gate_nonce_outstanding--;
        if (!c.done) {
            /* An access violation inside the call, caught by the guard. This
             * used to be reported as AOWL_GATE_OK with a 0 return, which is a
             * verification that cannot fail (CLAUDE.md 9b). */
            /* rule 6: self-disable after AOWL_GATE_MAX_FAULTS. */
            if (aowl_gate_faults < AOWL_GATE_MAX_FAULTS) aowl_gate_faults++;
            out->ret  = 0;
            out->done = 0;
            out->why  = AOWL_GATE_FAULTED;
            return 0;
        }
        out->ret  = rv;
        out->done = 1;
    }
    out->why = AOWL_GATE_OK;
    return 1;
}

/* The honest success predicate, replacing `ret != nil`. A caller must ALSO not
 * infer anything from `ret` alone: the trap never returns NULL. */
static int32_t aowl_gate_call_ok(const aowl_gate_call_t* c) {
    return c && c->why == AOWL_GATE_OK && c->done;
}

static void aowl_gate_note_fault(void) {
    if (aowl_gate_faults < AOWL_GATE_MAX_FAULTS) aowl_gate_faults++;
}

#endif /* AOWLSPT_IL2CPP_GATES_H */
