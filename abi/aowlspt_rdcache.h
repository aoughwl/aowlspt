/* aowlspt_rdcache.h -- a CACHE in front of the readability syscall, for the
 * host's per-frame GAME-DATA reads only.
 *
 * WHY. `aowl_is_readable` (abi/aowlspt_shim.h) is one `VirtualQuery` SYSCALL per
 * call, and the host's guarded-read discipline means one call per POINTER HOP.
 * MEASURED on the deployed build (natesp's own sub-phase meter, aowlspt-host.log):
 *
 *     sub[scan]: mean=23052.9us max=37983.2us n=1387
 *
 * for a census bounded at 64 contacts. The census makes roughly ten guarded hops
 * per contact (slot, IsYourPlayer, MovementContext + PreviousPosition, and the
 * five-hop Profile->Info->Settings side/role walk), i.e. ~600 VirtualQuery calls
 * per pass. That is the cost, and it is a syscall cost, not a work cost.
 *
 * The identical remedy has already been measured twice in this repo
 * (mods/maps/sp/rdcache.h): -85% on maps, -96% on admin. This file is that same
 * cache, moved to the host so the host's own hot paths can use it.
 *
 * THE ASYMMETRY IS THE WHOLE DESIGN, and it is not a tuning knob:
 *
 *   A STALE POSITIVE IS A CRASH.   A STALE NEGATIVE IS A DECLINE.
 *
 * so positives get a SHORT ttl (250ms) and are stored ONLY for regions of 64KB
 * or more -- a heap segment or an image section, the things that do not get
 * unmapped between two frames. A small region that happened to read positive is
 * answered honestly and then FORGOTTEN, counted in `uncacheable`. Negatives are
 * cheap to be wrong about, so they get 2000ms.
 *
 * SIZING. A 32-slot round-robin v1 FAILED in the maps mod: it hit within a call
 * and missed across calls, because the working set is the set of distinct 64KB
 * chunks the walk touches, which is hundreds. 1024 sets x 2 ways is sized for
 * that, and `evict-live` MEASURES whether it still is -- a rising evict-live is
 * the table being too small, reported rather than assumed.
 *
 * DRIFT. The predicate below is replicated clause-for-clause from
 * `aowl_is_readable`, applied to an mbi we already hold so a miss costs ONE
 * syscall rather than two. To keep the copy from silently drifting, one miss in
 * AOWL_RDC_AUDIT_EVERY also calls the real `aowl_is_readable` and compares.
 * `aowl_rdc_disagree()` MUST read 0; non-zero means this file has drifted and is
 * a measurement, not a claim.
 *
 * SCOPE -- READ THIS BEFORE ADDING A CALLER. This is for reading GAME DATA in a
 * per-frame path. It is deliberately NOT wired into:
 *   - detour binding or prologue verification (aowlspt_prologue.h, codegen),
 *   - `aowl_is_code_pointer`,
 *   - anything that decides whether to WRITE or PATCH.
 * Those are one-off, are not hot, and are exactly the places where a stale
 * positive is unrecoverable. They keep calling the uncached shim, unchanged.
 *
 * IT OPENS NO GUARD AND INSTALLS NOTHING. No detour, no name resolved, no RVA
 * called, nothing in the game dereferenced. It sits strictly outside any
 * `aowl_p_p_seh` (that guard is NOT re-entrant), holds only fixed-size static
 * storage, and allocates nothing, managed or otherwise.
 */
#ifndef AOWLSPT_RDCACHE_H
#define AOWLSPT_RDCACHE_H

#include <stdint.h>
#include <windows.h>

#include "aowlspt_shim.h"   /* aowl_is_readable -- the predicate, unchanged */

#define AOWL_RDC_SETS         1024    /* 1024 sets x 2 ways = 2048 entries    */
#define AOWL_RDC_WAYS         2
#define AOWL_RDC_CHUNK_SHIFT  16      /* 64KB granule: Windows' alloc unit    */
#define AOWL_RDC_POS_TTL_MS   250     /* stale positive == crash; keep short  */
#define AOWL_RDC_NEG_TTL_MS  2000     /* stale negative == a decline; cheap   */
#define AOWL_RDC_MIN_POS_SIZE 0x10000 /* 64 KB: heap segment / image section  */
#define AOWL_RDC_AUDIT_EVERY  256     /* 1 miss in N re-checked vs the shim   */

typedef struct {
    uintptr_t tag;       /* address >> AOWL_RDC_CHUNK_SHIFT, 0 == empty slot */
    uintptr_t base;      /* mbi.BaseAddress                                  */
    uintptr_t end;       /* base + mbi.RegionSize                            */
    uint64_t  stamp;     /* GetTickCount64 at the VirtualQuery               */
    uint32_t  epoch;     /* != g_aowl_rdc.epoch  =>  flushed, treat as empty */
    int32_t   ok;        /* what the predicate said for this region          */
} AowlRdcEntry;

typedef struct {
    AowlRdcEntry e[AOWL_RDC_SETS][AOWL_RDC_WAYS];
    uint32_t   epoch;        /* bumped by flush; O(1) invalidation           */
    uint32_t   auditTick;
    int64_t    hits;
    int64_t    misses;
    int64_t    flushes;
    int64_t    uncacheable;  /* answered by syscall, deliberately not stored */
    int64_t    evictLive;    /* victim was USED and INSIDE its TTL: capacity */
    int64_t    expired;      /* entry matched but its TTL had run out        */
    int64_t    auditChecks;
    int64_t    auditDisagree;/* MUST stay 0; non-zero == drift from the shim */
} AowlRdcState;

static AowlRdcState g_aowl_rdc;   /* zero-initialised static storage; epoch 0 */

/* O(1) invalidation. Call on any event that can UNMAP memory under us -- a
 * scene teardown, a raid ending. Bumping an epoch is cheaper and safer than
 * trusting the TTL alone across such an edge. */
static void aowl_rdc_flush(void) {
    g_aowl_rdc.epoch++;
    if (g_aowl_rdc.epoch == 0) g_aowl_rdc.epoch = 1;  /* never a wrapped 0 */
    g_aowl_rdc.flushes++;
}

/* THE PREDICATE, replicated clause-for-clause from `aowl_is_readable`, applied
 * to an mbi WE already hold. If you change one of these, change both, and
 * expect `aowl_rdc_disagree()` to say so if you do not. */
static int32_t aowl_rdc_pred(const MEMORY_BASIC_INFORMATION* mbi,
                             uintptr_t a, uintptr_t need) {
    if (mbi->State != MEM_COMMIT) return 0;
    if (mbi->Protect & (PAGE_NOACCESS | PAGE_GUARD)) return 0;
    if (!(mbi->Protect & (PAGE_READONLY | PAGE_READWRITE | PAGE_WRITECOPY |
                          PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE |
                          PAGE_EXECUTE_WRITECOPY))) return 0;
    {
        uintptr_t start = (uintptr_t)mbi->BaseAddress;
        uintptr_t end   = start + (uintptr_t)mbi->RegionSize;
        if (a < start) return 0;
        return need <= end ? 1 : 0;
    }
}

static uint32_t aowl_rdc_set_of(uintptr_t tag) {
    /* Mix, so regions laid out at a regular stride do not all alias into one
     * set -- the failure mode a plain (tag & MASK) would reintroduce. */
    uint64_t h = (uint64_t)tag * 0x9E3779B97F4A7C15ull;
    return (uint32_t)((h >> 40) & (uint64_t)(AOWL_RDC_SETS - 1));
}

/* The cached predicate. Contract IDENTICAL to `aowl_is_readable`: 1 iff
 * [p, p+size) lies wholly inside one committed, non-guard, readable region. */
static int32_t aowl_rdc_readable(void* p, int32_t size) {
    uintptr_t a, need, tag;
    uint64_t now;
    uint32_t set;
    int32_t w, ans;
    MEMORY_BASIC_INFORMATION mbi;

    if (!p || size <= 0) return 0;
    a = (uintptr_t)p;
    need = a + (uintptr_t)size;
    if (need < a) return 0;          /* overflow -- same refusal as the guard */

    now = GetTickCount64();
    /* +1, not |1: the tag must stay INJECTIVE. `| 1` would give adjacent 64KB
     * chunks the same tag, which containment would then reject as a miss --
     * correct, but a self-inflicted conflict. */
    tag = (a >> AOWL_RDC_CHUNK_SHIFT) + 1u;  /* never 0; 0 marks empty */
    set = aowl_rdc_set_of(tag);

    for (w = 0; w < AOWL_RDC_WAYS; w++) {
        AowlRdcEntry* e = &g_aowl_rdc.e[set][w];
        uint64_t ttl;
        if (e->tag != tag) continue;
        if (e->epoch != g_aowl_rdc.epoch) continue;      /* flushed */
        if (a < e->base || need > e->end) continue;      /* containment */
        ttl = e->ok ? (uint64_t)AOWL_RDC_POS_TTL_MS
                    : (uint64_t)AOWL_RDC_NEG_TTL_MS;
        if (now - e->stamp > ttl) {
            e->tag = 0; g_aowl_rdc.expired++; continue;
        }
        g_aowl_rdc.hits++;
        return e->ok;
    }

    /* MISS. ONE VirtualQuery, and the same predicate the guard applies. */
    g_aowl_rdc.misses++;
    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return 0;  /* guard's refusal */
    ans = aowl_rdc_pred(&mbi, a, need);

    /* Live audit of the replication, on a sample of misses. Costs one extra
     * syscall 1 time in AOWL_RDC_AUDIT_EVERY and is the only thing that can
     * prove this file has not drifted from abi/aowlspt_shim.h. */
    if (++g_aowl_rdc.auditTick >= (uint32_t)AOWL_RDC_AUDIT_EVERY) {
        g_aowl_rdc.auditTick = 0;
        g_aowl_rdc.auditChecks++;
        if (aowl_is_readable(p, size) != ans) g_aowl_rdc.auditDisagree++;
    }

    {
        uintptr_t base = (uintptr_t)mbi.BaseAddress;
        uintptr_t end  = base + (uintptr_t)mbi.RegionSize;
        if (end <= base) return ans;
        /* A POSITIVE is only stored for a LARGE region. Anything else is
         * answered honestly and forgotten -- see the asymmetry at the top. */
        if (ans && (end - base) < (uintptr_t)AOWL_RDC_MIN_POS_SIZE) {
            g_aowl_rdc.uncacheable++;
            return ans;
        }
        {
            /* Victim: an empty/flushed way first, else the OLDER stamp. */
            AowlRdcEntry* v = &g_aowl_rdc.e[set][0];
            for (w = 0; w < AOWL_RDC_WAYS; w++) {
                AowlRdcEntry* c = &g_aowl_rdc.e[set][w];
                if (c->tag == 0 || c->epoch != g_aowl_rdc.epoch) { v = c; break; }
                if (c->stamp < v->stamp) v = c;
            }
            /* Was this eviction forced by CAPACITY rather than by time? That
             * is the number which decides whether the table is big enough. */
            if (v->tag != 0 && v->tag != tag && v->epoch == g_aowl_rdc.epoch) {
                uint64_t vttl = v->ok ? (uint64_t)AOWL_RDC_POS_TTL_MS
                                      : (uint64_t)AOWL_RDC_NEG_TTL_MS;
                if (now - v->stamp <= vttl) g_aowl_rdc.evictLive++;
            }
            v->tag = tag; v->base = base; v->end = end; v->stamp = now;
            v->epoch = g_aowl_rdc.epoch; v->ok = ans ? 1 : 0;
        }
    }
    return ans;
}

static int64_t aowl_rdc_hits(void)        { return g_aowl_rdc.hits; }
static int64_t aowl_rdc_misses(void)      { return g_aowl_rdc.misses; }
static int64_t aowl_rdc_flushes(void)     { return g_aowl_rdc.flushes; }
static int64_t aowl_rdc_uncacheable(void) { return g_aowl_rdc.uncacheable; }
static int64_t aowl_rdc_evict_live(void)  { return g_aowl_rdc.evictLive; }
static int64_t aowl_rdc_expired(void)     { return g_aowl_rdc.expired; }
static int64_t aowl_rdc_audits(void)      { return g_aowl_rdc.auditChecks; }
static int64_t aowl_rdc_disagree(void)    { return g_aowl_rdc.auditDisagree; }

#endif /* AOWLSPT_RDCACHE_H */
