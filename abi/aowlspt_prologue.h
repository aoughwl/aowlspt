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
