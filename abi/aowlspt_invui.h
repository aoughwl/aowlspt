/* aowlspt_invui.h -- the shared surface for the NATIVE INVENTORY / ITEM-SPAWNER
 * screen: our inventory on one side, a searchable "everything" stash on the
 * other, and a mint that moves a row from the right side into the left.
 *
 * ## Why a SECOND region and not a bigger `aowlspt_admin.h`
 *
 * Everything here could have been appended to `AowlAdminShared`. It is not, for
 * two measured reasons:
 *
 *   1. `AowlAdminShared` is mapped by THREE modules (the admin mod on both
 *      sides, and the overlay). Appending to it changes `sizeof`, which changes
 *      what `CreateFileMappingA` reserves, which means an old overlay and a new
 *      mod map two different-sized views of one name. `AOWL_ADM_VERSION` exists
 *      to catch that, and bumping it turns EVERY existing admin feature off
 *      until all three modules are rebuilt together. A new screen must not be
 *      able to break ESP.
 *   2. The row tables here are ~11 KB. The admin region is on the ESP hot path
 *      and is read every Present; there is no reason to drag an inventory list
 *      through that cache line budget.
 *
 * So: a separate name, a separate version, and NO dependency in either
 * direction. If this region never gets mapped the native screen renders its
 * "nothing is answering" state and the F6 spawner is completely unaffected.
 *
 * ## The two sides and who owns what
 *
 * | field group | written by | read by |
 * |---|---|---|
 * | `query`, `*Req`, `mintTpl`, `mintCount` | the HOST (native UI, Unity thread) | the backend |
 * | `stash*`, `inv*`, `*Ack`, `note`, `mintVerdict` | the BACKEND (admin mod, server side) | the host |
 *
 * The request/ack pair IS the ownership token for the row tables, exactly as
 * `spawnReq`/`spawnAck` is for `spawnQuery` in `aowlspt_admin.h`. While
 * `req != ack` the tables belong to the backend and the host must not read
 * them; when `req == ack` they belong to the host and the backend must not
 * write them. That is why there is no seqlock here: there is no window in which
 * both sides may touch one table, so there is nothing to retry.
 *
 * `InterlockedExchange` on the ack is the release: every row byte is written
 * BEFORE the ack moves, and the interlocked store is a full barrier on x86-64,
 * so a host that observes `ack == req` observes every row written before it.
 *
 * ## The mint verdict is a READBACK, not an acknowledgement
 *
 * `mintVerdict` is deliberately not "the call returned OK". The backend counts
 * how many of `mintTpl` are in the profile BEFORE the mint and again AFTER, and
 * reports PASS only if the count went UP. A mint that returned success and put
 * nothing in the stash is the single failure this project keeps paying for, and
 * an ack-shaped verdict cannot tell those apart. INCONCLUSIVE is a real outcome
 * and is what a profile that could not be read reports -- never PASS.
 *
 * ## Safety
 *
 * Pure Win32 + stdint. No IL2CPP call, no game pointer, no allocation, no
 * dereference of anything a participant supplied. Every accessor CLAMPS rather
 * than trusting the region: this struct lives in a named section any process on
 * the box can open, so a length longer than its buffer is a thing that CAN
 * happen and must read as a short string, never as a walk off the end.
 */

#ifndef AOWLSPT_INVUI_H
#define AOWLSPT_INVUI_H

#include <windows.h>
#include <stdint.h>
#include <string.h>

/* "AOWLIUv1" as a little-endian u64. A consumer that maps first sees magic 0
 * (the OS zero-fills a new section) and can tell an unarmed region from
 * garbage. */
#define AOWL_IU_MAGIC        0x3176554958574F41ULL
#define AOWL_IU_VERSION      1
#define AOWL_IU_REGION_NAME  "Local\\aowlspt_invui_v1"

/* Rows per side. 64 is a CAP, not a target: it bounds every loop on both sides
 * and it is the page size the native screen scrolls through. The stash side
 * reports `stashMatched` separately, so a truncated list is never presented as
 * a complete one -- that distinction is the whole reason `searchItemsCounted`
 * returns two numbers. */
#define AOWL_IU_MAX_ROWS     64

#define AOWL_IU_TPL_LEN      25    /* 24 hex + NUL, exactly                 */
#define AOWL_IU_NAME_LEN     64    /* display name, truncated not wrapped   */
#define AOWL_IU_QUERY_LEN    64
#define AOWL_IU_NOTE_LEN     256

/* `mintVerdict`. Three outcomes, never two. 0 is "no mint has been asked for
 * yet", which is distinct from INCONCLUSIVE ("a mint ran and could not be
 * checked") on purpose: a screen that showed those the same way would report a
 * never-attempted spawn and an unverifiable one with one word. */
#define AOWL_IU_MV_NONE          0
#define AOWL_IU_MV_PASS          1
#define AOWL_IU_MV_FAIL          2
#define AOWL_IU_MV_INCONCLUSIVE  3

/* `stashOp`. What the host wants the right-hand column filled with. */
#define AOWL_IU_OP_SEARCH    0     /* items whose name contains `query`     */

typedef struct {
    char    tpl[AOWL_IU_TPL_LEN];
    char    name[AOWL_IU_NAME_LEN];
    int32_t count;      /* stack/occurrence count; 0 on the stash side      */
} AowlIuRow;

typedef struct {
    uint64_t      magic;
    uint32_t      version;
    uint32_t      rowStride;      /* sizeof(AowlIuRow), so a mismatched build
                                     is DETECTED rather than mis-parsed      */

    /* ---- the searchable stash (right-hand column) --------------------- */
    char          query[AOWL_IU_QUERY_LEN];
    volatile LONG queryLen;
    volatile LONG stashOp;        /* AOWL_IU_OP_*                           */
    volatile LONG stashReq;
    volatile LONG stashAck;
    int32_t       stashCount;     /* rows populated, 0..AOWL_IU_MAX_ROWS    */
    int32_t       stashMatched;   /* how many REALLY matched; >= stashCount */
    AowlIuRow     stash[AOWL_IU_MAX_ROWS];

    /* ---- our inventory (left-hand column) ----------------------------- */
    volatile LONG invReq;
    volatile LONG invAck;
    int32_t       invCount;       /* rows populated                         */
    int32_t       invTotal;       /* distinct templates in the stash        */
    AowlIuRow     inv[AOWL_IU_MAX_ROWS];

    /* ---- the mint ------------------------------------------------------
     * `mintBusy` is what the native screen reads to refuse a second click
     * while the first is in flight, and it is also what makes the
     * unsynchronised `mintTpl` buffer safe: exactly one side may touch it at
     * a time and which side that is is `mintBusy`.                        */
    char          mintTpl[AOWL_IU_TPL_LEN];
    volatile LONG mintCount;      /* 1..5000, 0 means "never set"           */
    volatile LONG mintCondition;  /* 1..100,  0 means "never set"           */
    volatile LONG mintReq;
    volatile LONG mintAck;
    volatile LONG mintBusy;
    volatile LONG mintVerdict;    /* AOWL_IU_MV_*                           */
    volatile LONG mintBefore;     /* readback: count of mintTpl before      */
    volatile LONG mintAfter;      /* readback: count of mintTpl after       */

    char          note[AOWL_IU_NOTE_LEN];   /* the sentence the screen shows */
    volatile LONG heartbeat;      /* bumped per serviced request            */
} AowlInvUiShared;

/* ------------------------------------------------------------------ *
 * Mapping. Both sides call this; first creates, rest open. The handle is leaked
 * on purpose -- it lives for the process. NULL only if the OS refused, which is
 * a no-screen outcome rather than a crash.
 * ------------------------------------------------------------------ */
static AowlInvUiShared* aowl_invui_map(void) {
    HANDLE h = CreateFileMappingA(INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE, 0,
                                  (DWORD)sizeof(AowlInvUiShared),
                                  AOWL_IU_REGION_NAME);
    AowlInvUiShared* s;
    int existed;
    if (!h) return NULL;
    existed = (GetLastError() == ERROR_ALREADY_EXISTS);
    s = (AowlInvUiShared*)MapViewOfFile(h, FILE_MAP_ALL_ACCESS, 0, 0,
                                        sizeof(AowlInvUiShared));
    if (!s) return NULL;
    if (!existed) {
        s->magic     = AOWL_IU_MAGIC;
        s->version   = AOWL_IU_VERSION;
        s->rowStride = (uint32_t)sizeof(AowlIuRow);
        /* Everything else is left at the OS zero-fill, which is the correct
         * unarmed state for every one of them: no request outstanding, no rows,
         * no verdict, empty query. There is no field here whose zero value is a
         * real setting -- unlike `hotkeyKc` in `aowlspt_admin.h`, where 0 IS a
         * real KeyCode and the zero-fill had to be overwritten. */
    }
    return s;
}

/* Whether this region was stamped by a build that agrees with ours. A version
 * or stride mismatch is REFUSED by name: the alternative is parsing another
 * build's row table as ours, which yields plausible garbage names. */
static int32_t aowl_invui_compatible(AowlInvUiShared* s) {
    if (!s) return 0;
    if (s->magic != AOWL_IU_MAGIC) return 0;
    if (s->version != (uint32_t)AOWL_IU_VERSION) return 0;
    if (s->rowStride != (uint32_t)sizeof(AowlIuRow)) return 0;
    return 1;
}

/* ------------------------------------------------------------------ *
 * Bounded string helpers. Used for every char array in the region, in both
 * directions, so there is exactly one place that can get a length wrong.
 * ------------------------------------------------------------------ */
static void aowl_iu_put_str(char* dst, int32_t cap, const char* src) {
    int32_t n = 0;
    if (!dst || cap <= 0) return;
    if (src) {
        while (n < cap - 1 && src[n]) n++;
        if (n > 0) memcpy(dst, src, (size_t)n);
    }
    dst[n] = '\0';
}

/* Copies at most `cap-1` bytes out and ALWAYS terminates, so a region whose
 * buffer was filled by something else with no NUL reads as a truncated string
 * rather than a walk off the end of the section. */
static void aowl_iu_get_str(const char* src, int32_t srcCap,
                            char* out, int32_t outCap) {
    int32_t n = 0;
    int32_t lim;
    if (!out || outCap <= 0) return;
    out[0] = '\0';
    if (!src || srcCap <= 0) return;
    lim = (srcCap < outCap ? srcCap : outCap) - 1;
    while (n < lim && src[n]) n++;
    if (n > 0) memcpy(out, src, (size_t)n);
    out[n] = '\0';
}

/* ------------------------------------------------------------------ *
 * The HOST side -- the native screen. Asks; never fills a table.
 * ------------------------------------------------------------------ */

/* Ask for the right-hand column to be refilled for `q`. Returns the sequence
 * number issued, or 0 if a request is already in flight (a REFUSAL: overwriting
 * the query under a backend that is mid-scan is precisely how a result list
 * ends up belonging to a query nobody typed). */
static int32_t aowl_invui_ask_stash(AowlInvUiShared* s, const char* q) {
    LONG req;
    if (!aowl_invui_compatible(s)) return 0;
    if (s->stashReq != s->stashAck) return 0;
    aowl_iu_put_str(s->query, AOWL_IU_QUERY_LEN, q);
    InterlockedExchange(&s->queryLen, (LONG)strlen(s->query));
    InterlockedExchange(&s->stashOp, AOWL_IU_OP_SEARCH);
    req = s->stashReq + 1;
    if (req == 0) req = 1;               /* never wrap onto the idle value */
    InterlockedExchange(&s->stashReq, req);
    return (int32_t)req;
}

static int32_t aowl_invui_ask_inv(AowlInvUiShared* s) {
    LONG req;
    if (!aowl_invui_compatible(s)) return 0;
    if (s->invReq != s->invAck) return 0;
    req = s->invReq + 1;
    if (req == 0) req = 1;
    InterlockedExchange(&s->invReq, req);
    return (int32_t)req;
}

static int32_t aowl_invui_ask_mint(AowlInvUiShared* s, const char* tpl,
                                   int32_t count, int32_t condition) {
    LONG req;
    if (!aowl_invui_compatible(s)) return 0;
    if (s->mintReq != s->mintAck) return 0;
    if (s->mintBusy) return 0;
    if (!tpl || !tpl[0]) return 0;       /* an empty mint is a no-op, refused */
    if (count < 1) count = 1;
    if (count > 5000) count = 5000;
    if (condition < 1 || condition > 100) condition = 100;
    aowl_iu_put_str(s->mintTpl, AOWL_IU_TPL_LEN, tpl);
    InterlockedExchange(&s->mintCount, (LONG)count);
    InterlockedExchange(&s->mintCondition, (LONG)condition);
    InterlockedExchange(&s->mintVerdict, AOWL_IU_MV_NONE);
    InterlockedExchange(&s->mintBusy, 1);
    req = s->mintReq + 1;
    if (req == 0) req = 1;
    InterlockedExchange(&s->mintReq, req);
    return (int32_t)req;
}

/* "Is the table mine to read?" -- true only when nothing is outstanding. */
static int32_t aowl_invui_stash_ready(AowlInvUiShared* s) {
    return (aowl_invui_compatible(s) && s->stashReq == s->stashAck) ? 1 : 0;
}
static int32_t aowl_invui_inv_ready(AowlInvUiShared* s) {
    return (aowl_invui_compatible(s) && s->invReq == s->invAck) ? 1 : 0;
}
static int32_t aowl_invui_mint_busy(AowlInvUiShared* s) {
    return (aowl_invui_compatible(s) && s->mintBusy) ? 1 : 0;
}

/* Row accessors. CLAMPED, and they refuse outright unless the table is ready,
 * so there is no way to spell "read row 3 of a list the backend is mid-write".
 * A refusal writes an empty string, never a stale one. */
static int32_t aowl_invui_stash_count(AowlInvUiShared* s) {
    int32_t n;
    if (!aowl_invui_stash_ready(s)) return 0;
    n = s->stashCount;
    if (n < 0) return 0;
    if (n > AOWL_IU_MAX_ROWS) return AOWL_IU_MAX_ROWS;
    return n;
}
static int32_t aowl_invui_stash_matched(AowlInvUiShared* s) {
    int32_t n;
    if (!aowl_invui_stash_ready(s)) return 0;
    n = s->stashMatched;
    return n < 0 ? 0 : n;
}
static int32_t aowl_invui_inv_count(AowlInvUiShared* s) {
    int32_t n;
    if (!aowl_invui_inv_ready(s)) return 0;
    n = s->invCount;
    if (n < 0) return 0;
    if (n > AOWL_IU_MAX_ROWS) return AOWL_IU_MAX_ROWS;
    return n;
}
static int32_t aowl_invui_inv_total(AowlInvUiShared* s) {
    int32_t n;
    if (!aowl_invui_inv_ready(s)) return 0;
    n = s->invTotal;
    return n < 0 ? 0 : n;
}

static void aowl_invui_stash_name(AowlInvUiShared* s, int32_t i,
                                  char* out, int32_t outCap) {
    if (out && outCap > 0) out[0] = '\0';
    if (i < 0 || i >= aowl_invui_stash_count(s)) return;
    aowl_iu_get_str(s->stash[i].name, AOWL_IU_NAME_LEN, out, outCap);
}
static void aowl_invui_stash_tpl(AowlInvUiShared* s, int32_t i,
                                 char* out, int32_t outCap) {
    if (out && outCap > 0) out[0] = '\0';
    if (i < 0 || i >= aowl_invui_stash_count(s)) return;
    aowl_iu_get_str(s->stash[i].tpl, AOWL_IU_TPL_LEN, out, outCap);
}
static void aowl_invui_inv_name(AowlInvUiShared* s, int32_t i,
                                char* out, int32_t outCap) {
    if (out && outCap > 0) out[0] = '\0';
    if (i < 0 || i >= aowl_invui_inv_count(s)) return;
    aowl_iu_get_str(s->inv[i].name, AOWL_IU_NAME_LEN, out, outCap);
}
static void aowl_invui_inv_tpl(AowlInvUiShared* s, int32_t i,
                               char* out, int32_t outCap) {
    if (out && outCap > 0) out[0] = '\0';
    if (i < 0 || i >= aowl_invui_inv_count(s)) return;
    aowl_iu_get_str(s->inv[i].tpl, AOWL_IU_TPL_LEN, out, outCap);
}
static int32_t aowl_invui_inv_qty(AowlInvUiShared* s, int32_t i) {
    if (i < 0 || i >= aowl_invui_inv_count(s)) return 0;
    return s->inv[i].count;
}

static void aowl_invui_note(AowlInvUiShared* s, char* out, int32_t outCap) {
    if (out && outCap > 0) out[0] = '\0';
    if (!aowl_invui_compatible(s)) return;
    aowl_iu_get_str(s->note, AOWL_IU_NOTE_LEN, out, outCap);
}
static int32_t aowl_invui_verdict(AowlInvUiShared* s) {
    return aowl_invui_compatible(s) ? (int32_t)s->mintVerdict : AOWL_IU_MV_NONE;
}
static int32_t aowl_invui_mint_before(AowlInvUiShared* s) {
    return aowl_invui_compatible(s) ? (int32_t)s->mintBefore : 0;
}
static int32_t aowl_invui_mint_after(AowlInvUiShared* s) {
    return aowl_invui_compatible(s) ? (int32_t)s->mintAfter : 0;
}
static int32_t aowl_invui_heartbeat(AowlInvUiShared* s) {
    return aowl_invui_compatible(s) ? (int32_t)s->heartbeat : 0;
}

/* ------------------------------------------------------------------ *
 * The BACKEND side -- the admin mod's server half. Fills tables; never asks.
 * ------------------------------------------------------------------ */

/* The outstanding sequence number, or 0 for "nothing to do". */
static int32_t aowl_invui_stash_pending(AowlInvUiShared* s) {
    if (!aowl_invui_compatible(s)) return 0;
    if (s->stashReq == s->stashAck) return 0;
    return (int32_t)s->stashReq;
}
static int32_t aowl_invui_inv_pending(AowlInvUiShared* s) {
    if (!aowl_invui_compatible(s)) return 0;
    if (s->invReq == s->invAck) return 0;
    return (int32_t)s->invReq;
}
static int32_t aowl_invui_mint_pending(AowlInvUiShared* s) {
    if (!aowl_invui_compatible(s)) return 0;
    if (s->mintReq == s->mintAck) return 0;
    return (int32_t)s->mintReq;
}

static void aowl_invui_get_query(AowlInvUiShared* s, char* out, int32_t outCap) {
    if (out && outCap > 0) out[0] = '\0';
    if (!aowl_invui_compatible(s)) return;
    aowl_iu_get_str(s->query, AOWL_IU_QUERY_LEN, out, outCap);
}
static void aowl_invui_get_mint_tpl(AowlInvUiShared* s, char* out, int32_t outCap) {
    if (out && outCap > 0) out[0] = '\0';
    if (!aowl_invui_compatible(s)) return;
    aowl_iu_get_str(s->mintTpl, AOWL_IU_TPL_LEN, out, outCap);
}
static int32_t aowl_invui_get_mint_count(AowlInvUiShared* s) {
    LONG v;
    if (!aowl_invui_compatible(s)) return 1;
    v = s->mintCount;
    if (v < 1) return 1;
    if (v > 5000) return 5000;
    return (int32_t)v;
}
static int32_t aowl_invui_get_mint_condition(AowlInvUiShared* s) {
    LONG v;
    if (!aowl_invui_compatible(s)) return 100;
    v = s->mintCondition;
    if (v < 1 || v > 100) return 100;
    return (int32_t)v;
}

/* Clear a table before refilling it. Without this a request that matched
 * nothing would leave the PREVIOUS query's rows in place and the screen would
 * render them as the answer to the new one -- a stale list is indistinguishable
 * from a correct one, which is the failure mode this whole file is shaped
 * around. */
static void aowl_invui_stash_begin(AowlInvUiShared* s) {
    if (!aowl_invui_compatible(s)) return;
    memset(s->stash, 0, sizeof(s->stash));
    s->stashCount = 0;
    s->stashMatched = 0;
}
static void aowl_invui_inv_begin(AowlInvUiShared* s) {
    if (!aowl_invui_compatible(s)) return;
    memset(s->inv, 0, sizeof(s->inv));
    s->invCount = 0;
    s->invTotal = 0;
}

/* Append. Returns 1 if the row landed, 0 if the table is full -- a REFUSAL the
 * caller must count, not a silent drop, because a dropped row is exactly the
 * difference between `stashCount` and `stashMatched`. */
static int32_t aowl_invui_stash_add(AowlInvUiShared* s, const char* tpl,
                                    const char* name) {
    int32_t i;
    if (!aowl_invui_compatible(s)) return 0;
    i = s->stashCount;
    if (i < 0 || i >= AOWL_IU_MAX_ROWS) return 0;
    aowl_iu_put_str(s->stash[i].tpl, AOWL_IU_TPL_LEN, tpl);
    aowl_iu_put_str(s->stash[i].name, AOWL_IU_NAME_LEN, name);
    s->stash[i].count = 0;
    s->stashCount = i + 1;
    return 1;
}
static int32_t aowl_invui_inv_add(AowlInvUiShared* s, const char* tpl,
                                  const char* name, int32_t qty) {
    int32_t i;
    if (!aowl_invui_compatible(s)) return 0;
    i = s->invCount;
    if (i < 0 || i >= AOWL_IU_MAX_ROWS) return 0;
    aowl_iu_put_str(s->inv[i].tpl, AOWL_IU_TPL_LEN, tpl);
    aowl_iu_put_str(s->inv[i].name, AOWL_IU_NAME_LEN, name);
    s->inv[i].count = qty;
    s->invCount = i + 1;
    return 1;
}
static void aowl_invui_stash_matched_set(AowlInvUiShared* s, int32_t n) {
    if (aowl_invui_compatible(s)) s->stashMatched = (n < 0 ? 0 : n);
}
static void aowl_invui_inv_total_set(AowlInvUiShared* s, int32_t n) {
    if (aowl_invui_compatible(s)) s->invTotal = (n < 0 ? 0 : n);
}

static void aowl_invui_set_note(AowlInvUiShared* s, const char* msg) {
    if (!aowl_invui_compatible(s)) return;
    aowl_iu_put_str(s->note, AOWL_IU_NOTE_LEN, msg);
}

/* THE RELEASE. Every row byte above is written before these run, and
 * `InterlockedExchange` is a full barrier, so a host that observes the ack has
 * observed the rows. Nothing may write the table after the ack moves. */
static void aowl_invui_stash_done(AowlInvUiShared* s, int32_t req) {
    if (!aowl_invui_compatible(s)) return;
    InterlockedExchange(&s->heartbeat, s->heartbeat + 1);
    InterlockedExchange(&s->stashAck, (LONG)req);
}
static void aowl_invui_inv_done(AowlInvUiShared* s, int32_t req) {
    if (!aowl_invui_compatible(s)) return;
    InterlockedExchange(&s->heartbeat, s->heartbeat + 1);
    InterlockedExchange(&s->invAck, (LONG)req);
}

/* The mint's release carries its READBACK, not an acknowledgement. `before` and
 * `after` are the counts of `mintTpl` in the profile either side of the spawn;
 * the verdict is derived from them here, in ONE place, so no caller can invent
 * a PASS. `after > before` is the only thing that is a PASS. */
static void aowl_invui_mint_done(AowlInvUiShared* s, int32_t req,
                                 int32_t before, int32_t after,
                                 int32_t readable, const char* msg) {
    LONG v;
    if (!aowl_invui_compatible(s)) return;
    aowl_iu_put_str(s->note, AOWL_IU_NOTE_LEN, msg);
    InterlockedExchange(&s->mintBefore, (LONG)before);
    InterlockedExchange(&s->mintAfter, (LONG)after);
    if (!readable)      v = AOWL_IU_MV_INCONCLUSIVE;  /* could not look     */
    else if (after > before) v = AOWL_IU_MV_PASS;
    else                v = AOWL_IU_MV_FAIL;
    InterlockedExchange(&s->mintVerdict, v);
    InterlockedExchange(&s->heartbeat, s->heartbeat + 1);
    InterlockedExchange(&s->mintBusy, 0);
    InterlockedExchange(&s->mintAck, (LONG)req);
}

#endif /* AOWLSPT_INVUI_H */
