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
#include <stdio.h>   /* _snprintf, for the startup health line only */

#define AOWL_PRO_MAX_BYTES 16
/* CAPACITY. This was 128 and the comment above it claimed the real demand was
 * "well under 64 across every feature combined". That was wrong, and it was
 * wrong in the direction that fails CLOSED AND SILENT.
 *
 * MEASURED (a harness that includes these very headers and walks these very
 * tables, so it counts keys rather than trusting a grep):
 *
 *     eager, from aowl_pro_prime_all .. 101 distinct RVAs
 *       debugui 36, modetext 3, PreloaderUI.Update 1, botnav 1+3,
 *       navui 18, nativeui 36, natraid 6      (two RVAs are shared, deduped)
 *     lazy, on first verify ............... 54 more distinct RVAs
 *       camera 15, cursor 4, modeskip 3, uistate 2 (1 new), pact 31
 *     ------------------------------------------------------------------
 *     TOTAL DISTINCT RVAs ................ 155
 *
 * 155 > 128. The eager pass alone is unconditional and takes 101, so only 27
 * rows remained for every lazily-captured target in the host -- and `pact`
 * alone wants 31. The table therefore OVERFLOWED in any configuration that
 * enabled the player-action layer, and the features whose rows were refused
 * got `aowl_pro_verify` == 0, indistinguishable from "the bytes differ".
 *
 * 512 is chosen to be more than 3x the measured demand. The cost is the whole
 * point of the choice: sizeof(AowlProRow) is 28 bytes, so 512 rows is ~14 KB
 * of static BSS in a host DLL, paid once, never per frame. There is no reason
 * to run this close to the edge again.
 *
 * If you add targets, do not just bump this: re-measure. A table that fills up
 * still refuses further rows rather than overwriting one -- but now it says so
 * (AOWL_PRO_R_TABLE_FULL), loudly, at startup, instead of failing closed while
 * looking exactly like a stale RVA on a changed game build. */
/* Overridable ONLY so the overflow path can be deliberately exercised by a test
 * that forces the bound low. Nothing in the host defines it. */
#ifndef AOWL_PRO_MAX_ROWS
#define AOWL_PRO_MAX_ROWS  512
#endif

/* WHY A VERIFY SAID NO. `aowl_pro_verify` returns 0 for reasons that demand
 * completely different responses from a human, and for years it returned the
 * same bare 0 for all of them. These codes exist so no caller has to guess,
 * and so no caller reports capacity exhaustion as "this game build changed".
 *
 * Only `MISMATCH` means the client is not what we measured. Everything else is
 * a fault in OUR host. */
#define AOWL_PRO_R_OK          0  /* bytes matched the snapshot               */
#define AOWL_PRO_R_MISMATCH    1  /* REAL: snapshot bytes differ from sig     */
#define AOWL_PRO_R_TABLE_FULL  2  /* OURS: no row free; nothing was captured  */
#define AOWL_PRO_R_UNREADABLE  3  /* OURS: not committed / not executable     */
#define AOWL_PRO_R_NO_MODULE   4  /* OURS: GameAssembly.dll not loaded yet    */
#define AOWL_PRO_R_SHORT       5  /* OURS: snapshot shorter than the sig      */

/* How many dropped RVAs we can NAME in the startup report. The count is exact
 * regardless; this only bounds the list. */
#define AOWL_PRO_MAX_DROPPED 32

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
static int32_t    aowl_pro_reason   = AOWL_PRO_R_OK; /* why the LAST verify
                                           * (or capture) said no. Written by
                                           * every path that can refuse.      */
/* The RVAs we could not seat, so the startup report can NAME them rather than
 * only counting them. Bounded; the counter above stays exact past the bound. */
static uint32_t   aowl_pro_dropped[AOWL_PRO_MAX_DROPPED];
static int32_t    aowl_pro_dropped_n = 0;

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
    if (aowl_pro_used >= AOWL_PRO_MAX_ROWS) {
        /* THE SILENT ONE. This used to bump a counter nobody read and return
         * NULL, which every caller then reported as a byte mismatch. Now it
         * names itself, and it remembers WHICH rva it dropped. */
        aowl_pro_full++;
        aowl_pro_reason = AOWL_PRO_R_TABLE_FULL;
        if (aowl_pro_dropped_n < AOWL_PRO_MAX_DROPPED)
            aowl_pro_dropped[aowl_pro_dropped_n++] = rva;
        return NULL;
    }
    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) { aowl_pro_reason = AOWL_PRO_R_NO_MODULE; return NULL; }
    p = (unsigned char*)ga + rva;
    /* Same guard the inline compares used, for the same reason: a stale RVA
     * can land on an uncommitted page, and reading there faults. */
    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) {
        aowl_pro_unreadable++; aowl_pro_reason = AOWL_PRO_R_UNREADABLE; return NULL;
    }
    if (mbi.State != MEM_COMMIT) {
        aowl_pro_unreadable++; aowl_pro_reason = AOWL_PRO_R_UNREADABLE; return NULL;
    }
    if (!(mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY))) {
        aowl_pro_unreadable++; aowl_pro_reason = AOWL_PRO_R_UNREADABLE; return NULL;
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
    aowl_pro_reason = AOWL_PRO_R_OK;
    if (siglen <= 0) return 1;                 /* nothing asserted */
    if (siglen > AOWL_PRO_MAX_BYTES) siglen = AOWL_PRO_MAX_BYTES;
    r = aowl_pro_find(rva);
    if (!r) {
        /* Not primed. Capture now -- still correct, because a target's first
         * verify necessarily precedes its first patch. */
        r = aowl_pro_capture(rva);
        if (!r) return 0;   /* fail closed; capture already set the reason */
        aowl_pro_lazy++;
    }
    if (r->len < siglen) { aowl_pro_reason = AOWL_PRO_R_SHORT; return 0; }
    if (memcmp(r->b, sig, (size_t)siglen) == 0) return 1;
    aowl_pro_reason = AOWL_PRO_R_MISMATCH;     /* the only one that blames the
                                                * client rather than us       */
    return 0;
}

/* WHY THE LAST VERIFY SAID NO. Callers must consult this before phrasing a
 * refusal: only AOWL_PRO_R_MISMATCH licenses "this build changed". */
static int32_t aowl_pro_last_reason(void) { return aowl_pro_reason; }

/* The one predicate every caller needs, so none of them has to re-derive it
 * from `aowl_pro_have` + `aowl_pro_full_count` the way `pact` had to. */
static int32_t aowl_pro_last_was_table_full(void) {
    return aowl_pro_reason == AOWL_PRO_R_TABLE_FULL ? 1 : 0;
}

static const char* aowl_pro_reason_text(int32_t code) {
    switch (code) {
    case AOWL_PRO_R_OK:         return "ok (prologue matched the startup snapshot)";
    case AOWL_PRO_R_MISMATCH:   return "PROLOGUE MISMATCH -- the snapshot bytes differ from the signature; this RVA is not the code we measured on this build";
    case AOWL_PRO_R_TABLE_FULL: return "SNAPSHOT TABLE FULL -- our own table ran out of rows, so this RVA was never captured. NOT a client change; raise AOWL_PRO_MAX_ROWS";
    case AOWL_PRO_R_UNREADABLE: return "unreadable -- the target page is not committed or not executable";
    case AOWL_PRO_R_NO_MODULE:  return "GameAssembly.dll not loaded yet";
    case AOWL_PRO_R_SHORT:      return "snapshot shorter than the signature";
    default:                    return "unknown";
    }
}

/* Convenience for a refusal message: the text of the reason the LAST verify
 * gave. Never NULL. */
static const char* aowl_pro_last_reason_text(void) {
    return aowl_pro_reason_text(aowl_pro_reason);
}

/* Whether an RVA's ORIGINAL bytes are on record. Lets a caller say in the log
 * that it verified against a snapshot rather than against live memory. */
static int32_t aowl_pro_have(uint32_t rva) {
    return aowl_pro_find(rva) ? 1 : 0;
}

/* Copy an RVA's ORIGINAL bytes out for a reader outside this TU -- the
 * `aowlspt.host::original_bytes` verb, which is how a MOD's own verifier
 * (aowlspt/callrva) byte-verifies a call target the host has ALREADY
 * detoured: the live bytes there are our trampoline's JMP and the truth is in
 * this table, primed before any detour. FIND only, never capture: a capture
 * from here would run after the host's detours and could record a trampoline
 * as the truth. Returns the bytes copied; 0 when the RVA was never primed,
 * which the caller must treat as "no answer", not as "no such function". */
static int32_t aowl_pro_copy(uint32_t rva, unsigned char* out, int32_t n) {
    AowlProRow* r = aowl_pro_find(rva);
    if (!r || !out || n <= 0) return 0;
    if (n > r->len) n = r->len;
    memcpy(out, r->b, (size_t)n);
    return n;
}

/* Diagnostics, so the boot log can state the snapshot's health rather than
 * leaving it to be inferred. */
static int32_t aowl_pro_rows_used(void)   { return aowl_pro_used; }
static int32_t aowl_pro_primed_count(void){ return aowl_pro_primed; }
static int32_t aowl_pro_lazy_count(void)  { return aowl_pro_lazy; }
static int32_t aowl_pro_full_count(void)  { return aowl_pro_full; }
static int32_t aowl_pro_bad_count(void)   { return aowl_pro_unreadable; }
static int32_t aowl_pro_capacity(void)    { return AOWL_PRO_MAX_ROWS; }
static int32_t aowl_pro_dropped_count(void){ return aowl_pro_dropped_n; }
static uint32_t aowl_pro_dropped_at(int32_t i) {
    if (i < 0 || i >= aowl_pro_dropped_n) return 0;
    return aowl_pro_dropped[i];
}

/* THE STARTUP LINE. `aowl_pro_full` was incremented and never reported by
 * anything, which is how a table that had been overflowing stayed invisible
 * while the features past the cutoff were refused and blamed the game build.
 *
 * Returns a single line into `out`. When nothing was dropped it is a quiet
 * one-liner; when something WAS dropped it leads with a shout, gives the exact
 * count, and names as many of the dropped RVAs as we kept. Bounded formatting,
 * no allocation, safe to call from the boot path. */
static char aowl_pro_health_buf[1024];
static const char* aowl_pro_health_line(void) {
    char* out = aowl_pro_health_buf;
    const int32_t cap = (int32_t)sizeof(aowl_pro_health_buf);
    int32_t n, i;
    if (aowl_pro_full == 0) {
        _snprintf(out, (size_t)cap,
            "prologue snapshot: %d/%d rows used (%d primed eagerly, %d lazily), "
            "%d unreadable, 0 dropped",
            aowl_pro_used, AOWL_PRO_MAX_ROWS, aowl_pro_primed, aowl_pro_lazy,
            aowl_pro_unreadable);
        out[cap - 1] = 0;
        return out;
    }
    n = _snprintf(out, (size_t)cap,
        "*** PROLOGUE SNAPSHOT TABLE OVERFLOWED *** %d row(s) DROPPED; "
        "%d/%d rows used. EVERY feature whose RVA was dropped has had its "
        "prologue verify fail CLOSED and will report itself unverified -- that "
        "is OUR capacity limit, NOT a client build change. Raise "
        "AOWL_PRO_MAX_ROWS. Every affected verify reports \"%s\". Dropped RVA(s):",
        aowl_pro_full, aowl_pro_used, AOWL_PRO_MAX_ROWS,
        /* Named through the same accessor every CALLER uses, so the line the
         * boot log prints and the reason a refusal quotes cannot drift. */
        aowl_pro_reason_text(AOWL_PRO_R_TABLE_FULL));
    if (n < 0 || n >= cap) { out[cap - 1] = 0; return out; }
    for (i = 0; i < aowl_pro_dropped_n && n < cap - 16; i++) {
        int32_t k = _snprintf(out + n, (size_t)(cap - n), " 0x%x", aowl_pro_dropped[i]);
        if (k < 0) break;
        n += k;
    }
    if (aowl_pro_full > aowl_pro_dropped_n && n < cap - 24)
        _snprintf(out + n, (size_t)(cap - n), " (+%d more not recorded)",
                  aowl_pro_full - aowl_pro_dropped_n);
    out[cap - 1] = 0;
    return out;
}

#endif /* AOWLSPT_PROLOGUE_H */
