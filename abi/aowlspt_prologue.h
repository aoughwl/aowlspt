/* aowlspt_prologue.h -- ORIGINAL prologue bytes, snapshotted once, before any
 * detour is installed.
 *
 * THE BUG THIS EXISTS TO KILL
 * --------------------------
 * Every feature in this host verifies its target by comparing 16 prologue
 * bytes against a signature baked in from the decrypted metadata. That check
 * is a real safety property -- it is what makes a stale RVA on a different
 * game build a silent no-op instead of a jump into the middle of an unrelated
 * function -- and it must keep holding.
 *
 * But it was reading LIVE memory at bind time. As soon as two features share a
 * target, that is wrong: the first binder writes its jump over the very bytes
 * the second binder is about to compare. The second reads the trampoline,
 * sees a mismatch, and rejects a target that is perfectly correct.
 *
 * Observed live, twice, on two builds: with `debugUi` and `uxMenuModeText`
 * both on, the overlay armed and then
 *
 *     menu mode text: PreloaderUI.Update did not verify on this build
 *                     (0 target(s) verified, 1 rejected); nothing bound
 *
 * and the corner label stayed "PVE ZONE". Nothing was wrong with the RVA, the
 * signature, or the multiplex -- only with WHEN the bytes were read.
 *
 * This is a whole CLASS of bug, not one feature's mistake: any feature that
 * prologue-verifies a function another feature already patched will
 * self-reject, and it will do it with a message that blames the game build.
 *
 * THE FIX
 * -------
 * One RVA-keyed table of original prologue bytes, captured BEFORE anything is
 * patched, and every later verify compares against the SNAPSHOT rather than
 * against live memory. The signature check is not weakened in any way -- it is
 * still an exact 16-byte compare against the baked-in expectation. It is only
 * fed the bytes the function actually started with.
 *
 * Capture happens two ways, and both matter:
 *
 *   * EAGERLY, from `aowl_pro_prime_all` at host startup, before any bind
 *     runs. This is the real guarantee and the reason the whole class is
 *     fixed rather than one instance of it.
 *   * LAZILY, on the first verify of an RVA that has not been primed. This is
 *     the belt-and-braces path for a target added later whose RVA nobody
 *     remembered to add to the priming list. It is only correct because the
 *     FIRST verify of a target still necessarily precedes that target's first
 *     patch -- a feature cannot patch what it has not yet verified.
 *
 * A snapshot is written EXACTLY ONCE per RVA and never updated. That is the
 * entire point: a second capture attempt after a detour landed would record
 * the trampoline and re-introduce the bug this file removes.
 *
 * SAFETY
 * ------
 * Capture is subject to the same discipline as the compare it replaces:
 * `VirtualQuery` first, insist on MEM_COMMIT and an executable protection,
 * and only then read. A capture that cannot satisfy that records nothing and
 * leaves the RVA unprimed, so the verify fails closed (refuses the target)
 * rather than comparing against a zeroed row.
 */

#ifndef AOWLSPT_PROLOGUE_H
#define AOWLSPT_PROLOGUE_H

#include <windows.h>
#include <stdint.h>
#include <string.h>

#define AOWL_PRO_MAX_BYTES 16
/* Comfortably above the number of distinct detour/call targets this host
 * verifies (currently well under 64 across every feature combined). A table
 * that fills up refuses further rows rather than overwriting one. */
#define AOWL_PRO_MAX_ROWS  128

typedef struct {
    uint32_t      rva;      /* key: offset into GameAssembly.dll             */
    unsigned char b[AOWL_PRO_MAX_BYTES];
    int32_t       len;      /* bytes actually captured                      */
    int32_t       used;     /* 1 once captured; never re-captured           */
} AowlProRow;

static AowlProRow aowl_pro_rows[AOWL_PRO_MAX_ROWS];
static int32_t    aowl_pro_used     = 0;  /* rows occupied                  */
static int32_t    aowl_pro_primed   = 0;  /* captured by the eager pass     */
static int32_t    aowl_pro_lazy     = 0;  /* captured on first verify       */
static int32_t    aowl_pro_full     = 0;  /* capture refused: table full    */
static int32_t    aowl_pro_unreadable = 0;/* capture refused: bad memory    */

static AowlProRow* aowl_pro_find(uint32_t rva) {
    int32_t i;
    for (i = 0; i < aowl_pro_used; i++)
        if (aowl_pro_rows[i].rva == rva) return &aowl_pro_rows[i];
    return NULL;
}

/* Capture the original bytes at GameAssembly+rva, ONCE. Returns the row, or
 * NULL when the memory could not be safely read or the table is full.
 * A second call for an rva already captured is a no-op that returns the
 * EXISTING row -- that is what keeps a post-patch call from recording a
 * trampoline over the truth. */
static AowlProRow* aowl_pro_capture(uint32_t rva) {
    HMODULE ga;
    unsigned char* p;
    MEMORY_BASIC_INFORMATION mbi;
    AowlProRow* r = aowl_pro_find(rva);
    if (r) return r;                      /* already known: never overwrite */
    if (aowl_pro_used >= AOWL_PRO_MAX_ROWS) { aowl_pro_full++; return NULL; }
    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) return NULL;
    p = (unsigned char*)ga + rva;
    /* Same guard the inline compares used, for the same reason: a stale RVA
     * can land on an uncommitted page, and reading there faults. */
    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) { aowl_pro_unreadable++; return NULL; }
    if (mbi.State != MEM_COMMIT)               { aowl_pro_unreadable++; return NULL; }
    if (!(mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY))) {
        aowl_pro_unreadable++; return NULL;
    }
    r = &aowl_pro_rows[aowl_pro_used++];
    r->rva = rva;
    r->len = AOWL_PRO_MAX_BYTES;
    memcpy(r->b, p, AOWL_PRO_MAX_BYTES);
    r->used = 1;
    return r;
}

/* The eager pass: prime one RVA at startup, before any detour exists. */
static int32_t aowl_pro_prime(uint32_t rva) {
    AowlProRow* r;
    if (aowl_pro_find(rva)) return 1;          /* already primed */
    r = aowl_pro_capture(rva);
    if (!r) return 0;
    aowl_pro_primed++;
    return 1;
}

/* THE VERIFY. Compares `sig` against the SNAPSHOT of the original bytes, not
 * against live memory, and so gives the same answer whether or not somebody
 * has since detoured the function.
 *
 * Returns 1 on a match. Fails CLOSED on anything else -- an rva whose bytes
 * could never be captured is refused, exactly as an unreadable target always
 * was. `p` is only used to report the code pointer; the compare never touches
 * it. */
static int32_t aowl_pro_verify(uint32_t rva,
                               const unsigned char* sig, int32_t siglen) {
    AowlProRow* r;
    if (siglen <= 0) return 1;                 /* nothing asserted */
    if (siglen > AOWL_PRO_MAX_BYTES) siglen = AOWL_PRO_MAX_BYTES;
    r = aowl_pro_find(rva);
    if (!r) {
        /* Not primed. Capture now -- still correct, because a target's first
         * verify necessarily precedes its first patch. */
        r = aowl_pro_capture(rva);
        if (!r) return 0;                      /* fail closed */
        aowl_pro_lazy++;
    }
    if (r->len < siglen) return 0;
    return memcmp(r->b, sig, (size_t)siglen) == 0 ? 1 : 0;
}

/* ------------------------------------------------------------------------
 * THE EMPTY-BODY STUB GATE.
 *
 * Resolving `TMP_Text::ForceMeshUpdate` by name lands on 0x628110, whose bytes
 * are `C2 00 00` -- `ret 0`. That is NOT that method's code. It is this build's
 * UNIVERSAL EMPTY-BODY STUB, and 6,438 methods fold onto it. The lookup
 * succeeds, every existing check (module, code page, il2cpp section, even a
 * 16-byte prologue compare against a signature copied from that same address)
 * PASSES, and the call is a no-op. A verification that cannot fail is the bug.
 *
 * So classify the SHAPE of the body before trusting the address. This is the
 * runtime twin of `Resolver.classify_thunk` in tools/il2cpp_resolve.py and the
 * two are deliberately the same table of shapes; if one grows a case the other
 * must. The stub set is DERIVED from the bytes, not from a hardcoded 0x628110:
 * any address whose body is an immediate return is refused, wherever it is.
 *
 * Conservative in one direction only: NOT matching is not evidence of a real
 * body, and that is stated at every call site rather than assumed away.
 *
 * `aowl_pro_classify` is a PURE function of bytes so it can be exercised
 * offline against constructed inputs -- a guard nobody has seen fire is not a
 * guard. See tools/shapetest.c. */
enum {
    AOWL_SHAPE_UNKNOWN  = -1, /* bytes unavailable: fail CLOSED, never "fine" */
    AOWL_SHAPE_BODY     = 0,  /* no non-body shape matched (NOT "verified")   */
    AOWL_SHAPE_RET      = 1,  /* C3                       -- empty body       */
    AOWL_SHAPE_RETN     = 2,  /* C2 imm16                 -- empty body       */
    AOWL_SHAPE_XORRET   = 3,  /* [48] 33 C0 C3            -- returns 0        */
    AOWL_SHAPE_TRIVIAL  = 4,  /* mov rax,[rcx+d8]; ret    -- real, but FOLDED */
    AOWL_SHAPE_JMPTABLE = 5,  /* FF 25                    -- indirect jump    */
    AOWL_SHAPE_TAILJUMP = 6   /* E9 rel32                 -- tail-call thunk  */
};

static int32_t aowl_pro_classify(const unsigned char* b, int32_t n) {
    int32_t i;
    if (!b || n < 4) return AOWL_SHAPE_UNKNOWN;
    if (b[0] == 0xC3) return AOWL_SHAPE_RET;
    if (b[0] == 0xC2) return AOWL_SHAPE_RETN;
    if ((b[0] == 0x33 && b[1] == 0xC0 && b[2] == 0xC3) ||
        (b[0] == 0x48 && b[1] == 0x33 && b[2] == 0xC0 && b[3] == 0xC3))
        return AOWL_SHAPE_XORRET;
    if (b[0] == 0x48 && b[1] == 0x8B && b[2] == 0x41 && n > 4 && b[4] == 0xC3)
        return AOWL_SHAPE_TRIVIAL;
    if (b[0] == 0xFF && b[1] == 0x25) return AOWL_SHAPE_JMPTABLE;
    for (i = 0; i < 9 && i < n - 4; i++) {
        if (b[i] == 0xE9) {
            int32_t pad = (i + 5 >= n) || b[i + 5] == 0xCC || b[i + 5] == 0x90;
            if (i == 0 || pad) return AOWL_SHAPE_TAILJUMP;
            break;
        }
    }
    return AOWL_SHAPE_BODY;
}

static const char* aowl_pro_shape_name(int32_t k) {
    switch (k) {
    case AOWL_SHAPE_RET:      return "STUB (immediate ret -- EMPTY BODY)";
    case AOWL_SHAPE_RETN:     return "STUB (ret imm16 -- EMPTY BODY; this is "
                                     "the shape of the universal stub at "
                                     "0x628110 that 6,438 methods fold onto)";
    case AOWL_SHAPE_XORRET:   return "STUB (xor eax,eax; ret -- returns 0, no "
                                     "body)";
    case AOWL_SHAPE_TRIVIAL:  return "TRIVIAL (one-instruction field getter; a "
                                     "real body, but bodies this small are "
                                     "FOLDED, so expect the RVA to be SHARED)";
    case AOWL_SHAPE_JMPTABLE: return "JMPTABLE (jmp [rip+disp32] -- an indirect "
                                     "jump, not a body)";
    case AOWL_SHAPE_TAILJUMP: return "TAILJUMP (jmp rel32 -- a tail-call thunk; "
                                     "a postfix detour here has no return site)";
    case AOWL_SHAPE_BODY:     return "BODY (no empty-body or thunk shape "
                                     "matched -- which is NOT proof of a real "
                                     "body, only absence of a known bad one)";
    default:                  return "UNKNOWN (the original bytes could not be "
                                     "read, so nothing was classified)";
    }
}

/* The shape of the ORIGINAL bytes at an RVA, from the startup snapshot --
 * never from live memory, for exactly the reason `aowl_pro_verify` uses the
 * snapshot: after another feature detours a function, live memory holds that
 * feature's trampoline and every shape read from it is a lie. */
static int32_t aowl_pro_shape(uint32_t rva) {
    AowlProRow* r = aowl_pro_find(rva);
    if (!r) {
        r = aowl_pro_capture(rva);
        if (!r) return AOWL_SHAPE_UNKNOWN;    /* fail closed */
        aowl_pro_lazy++;
    }
    return aowl_pro_classify(r->b, r->len);
}

/* Is this shape an EMPTY BODY? Refused for a call AND for a detour: calling it
 * silently does nothing, which is this project's worst failure mode. */
static int32_t aowl_pro_shape_is_stub(int32_t k) {
    return (k == AOWL_SHAPE_RET || k == AOWL_SHAPE_RETN ||
            k == AOWL_SHAPE_XORRET) ? 1 : 0;
}

/* Is this shape unsafe to DETOUR specifically? Adds the thunks: a tail jump
 * has no return site for a postfix, and an indirect jump is not a body at all.
 * Calling either is still meaningful, so this is not `is_stub`. */
static int32_t aowl_pro_shape_no_detour(int32_t k) {
    return (aowl_pro_shape_is_stub(k) || k == AOWL_SHAPE_JMPTABLE ||
            k == AOWL_SHAPE_TAILJUMP || k == AOWL_SHAPE_UNKNOWN) ? 1 : 0;
}

/* Whether an RVA's ORIGINAL bytes are on record. Lets a caller say in the log
 * that it verified against a snapshot rather than against live memory. */
static int32_t aowl_pro_have(uint32_t rva) {
    return aowl_pro_find(rva) ? 1 : 0;
}

/* Diagnostics, so the boot log can state the snapshot's health rather than
 * leaving it to be inferred. */
static int32_t aowl_pro_rows_used(void)   { return aowl_pro_used; }
static int32_t aowl_pro_primed_count(void){ return aowl_pro_primed; }
static int32_t aowl_pro_lazy_count(void)  { return aowl_pro_lazy; }
static int32_t aowl_pro_full_count(void)  { return aowl_pro_full; }
static int32_t aowl_pro_bad_count(void)   { return aowl_pro_unreadable; }

#endif /* AOWLSPT_PROLOGUE_H */
