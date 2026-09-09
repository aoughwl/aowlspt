/* THE REGION-READABILITY CACHE -- lever 1 of the entity-loop cost fix.
 *
 * WHY. Measured live, in a phase-confirmed raid, by sp/mapsprof.h:
 *
 *     c.entityLoop = 4394.3us/tick over 46430 calls / 1312 collects
 *       e.posOf   = 1711.7us/tick (38.9%)   e.classOf = 1156.6us/tick (26.3%)
 *       e.idTailOf=  741.5us/tick (16.8%)   e.aiData  =  357.8us/tick ( 8.1%)
 *
 * ~124us PER ENTITY PER TICK, of which ~48us is MERELY READING A POSITION. No
 * RVA call costs 48us. What every one of those rows has in common is
 * `aowl_is_readable`, which is a raw `VirtualQuery` -- a SYSCALL that walks this
 * process's very large VAD tree -- and this mod issues one PER FIELD HOP.
 *
 * WHAT THIS CHANGES, AND WHAT IT DELIBERATELY DOES NOT.
 *
 * The check is NOT removed and NOT weakened. `aowl_is_readable(p, size)` asks
 * exactly one question -- "does [p, p+size) lie wholly inside ONE committed,
 * non-guard, readable region?" -- and answers it from a `MEMORY_BASIC_INFORMATION`
 * describing a REGION, not an address. That answer is therefore valid for every
 * address in that region, and re-asking it per hop re-derives an identical
 * answer at syscall price. This file remembers the region and replays the SAME
 * predicate against it. A miss falls straight through to a real `VirtualQuery`;
 * there is no path here that returns 1 without one having said so.
 *
 * ---------------------------------------------------------------------------
 * WHY THE FIRST VERSION MISSED ACROSS CALLS AND HIT WITHIN ONE. (measured)
 *
 * Per-call hop costs, phase-confirmed raid, tick-count independent, honest
 * meter (30ns/pair overhead == 0.1%), over 92927 calls of sp_pos_live:
 *
 *     h1.bones    (Pl+0xB40 ptr) = 71483 ns/call
 *     h2.bodyXf   (PB+0x178 ptr) = 33860 ns/call
 *     h3.accumFlag(BT+0xA9 u8)   = 54475 ns/call
 *     h4.useImit  (BT+0xA8 u8)   =    51 ns/call   <-- ~1000x cheaper
 *     h5.original (BT+0x10 ptr)  =   115 ns/call
 *
 * h3 and h4 read ADJACENT BYTES OF THE SAME OBJECT and differ by ~1000x, so the
 * cost is not the region, not the object and not the read instruction: it is
 * the FIRST touch of a region within a call. h4/h5 are repeat touches of the
 * region h3 has just stored, and they are free -- which proves the store path
 * runs and that lookup works. The entry simply did not survive to the next call.
 *
 * The four candidate causes, and how each was settled against numbers already
 * in the host log (`Maps: rdcache: ...`) rather than by argument:
 *
 *   * "the key is the POINTER, so distinct entities miss even in one region"
 *     -- FALSE. The key was already the REGION (mbi.BaseAddress/RegionSize) and
 *     lookup was a containment test. Read the v1 source.
 *   * "sub-64KB regions cache nothing and pay two syscalls"
 *     -- FALSE, measured: `small-region-positives-not-cached=0`. No hop lands
 *     in a small region.
 *   * "flushed between calls" -- FALSE, measured: `flushes=23` in 5 minutes,
 *     against 1.4M lookups.
 *   * "the 250ms positive TTL expires between calls" -- FALSE: the entity loop
 *     revisits every entity each tick, ~33ms at 30fps, an order of magnitude
 *     inside the TTL.
 *
 * What is left, and what this version fixes: CAPACITY. The table was
 * SP_RDC_SLOTS=32 entries with a ROUND-ROBIN victim and a linear scan. The live
 * working set is ~35 entities x >=3 distinct object regions ~= 100+ regions.
 * A 32-entry round-robin cannot hold 100+ live keys: each entry is overwritten
 * roughly three times over before the loop comes back to it, so every first
 * touch of a region in a call finds its entry already recycled, while a repeat
 * touch in the same call finds the entry it stored microseconds ago. That is
 * exactly the h3-vs-h4 signature.
 *
 * `evict-live` below is the counter that can FALSIFY this: it counts victims
 * that were still used and still inside their TTL, i.e. evictions forced by
 * capacity rather than by time. If capacity is the cause, evict-live in v1 is
 * of the same order as misses; if this version's larger table is the fix,
 * evict-live goes to ~0 and the hit rate rises. Neither is asserted here.
 *
 * ---------------------------------------------------------------------------
 * HOW THIS VERSION IS ORGANISED.
 *
 * Lookup must find a region entry from an ARBITRARY ADDRESS inside it, and the
 * base is not known until a VirtualQuery has been made -- so the table cannot
 * be hashed on the region base. It is hashed on the address's 64KB CHUNK
 * (`a >> 16`), 2-way set associative, SP_RDC_SETS sets. A region spanning many
 * chunks simply installs one entry per chunk it is actually touched in; every
 * such entry carries the SAME base/end, so they cannot disagree. Every answer
 * still re-checks, in this order: epoch, chunk tag, containment
 * (`a >= base && need <= end`), TTL. A stale tag or an aliased set therefore
 * cannot produce a wrong answer -- only a miss.
 *
 * THE HAZARD, NAMED. A cached POSITIVE that has gone stale is a read of a
 * decommitted page, i.e. a crash. A cached NEGATIVE that has gone stale is a
 * refused read, i.e. a decline -- which this mod already reports as Unknown and
 * counts. The two are not symmetric, so their TTLs are not either:
 *
 *   * POSITIVE: 250 ms, and ONLY for regions >= 64 KB. natesp's nuFn fix used
 *     2 s, but it cached CODE pages inside GameAssembly, which are mapped for
 *     the process's life. These are IL2CPP GC-heap and Unity-native regions,
 *     which CAN be decommitted. Large regions are heap segments and image
 *     sections; a sub-64KB region is a transient VirtualAlloc and is never
 *     cached positively -- it just pays the syscall, correctly.
 *   * NEGATIVE: 2000 ms, any size. Failing safe costs a decline.
 *
 * REGION REUSE AFTER A FREE -- the question a bigger table makes fair to ask.
 * Enlarging the table does NOT widen the stale-positive window, because the
 * cached fact is unchanged in kind and in lifetime: it is still "this REGION
 * was committed and readable at time T", still region-scoped, still 250ms. The
 * only difference is that more addresses inside an already-validated region now
 * reach the entry that v1 would also have answered from, had capacity not
 * recycled it first. Concretely:
 *
 *   * A region DECOMMITTED after we cached it is answerable stale for at most
 *     250 ms. That window is unchanged from v1 and is why the positive TTL is
 *     not being raised, however tempting the syscall saving.
 *   * A region SPLIT by a partial decommit keeps our old, larger `end`, so an
 *     address now in a different region could be answered from it -- again
 *     bounded by the same 250 ms, again unchanged from v1.
 *   * A region REUSED for a DIFFERENT allocation is the benign case for this
 *     predicate: it is still committed and readable, so the cached answer is
 *     still TRUE. What has changed is the OBJECT, not the readability -- and
 *     this cache never claimed liveness. Unity FAKE NULL means readability is
 *     not liveness and type confusion beats both guards; nothing here weakens
 *     or substitutes for the callers' own value and type validation, which is
 *     untouched.
 *   * `sp_rdc_flush()` remains the explicit invalidation, and is now O(1) via
 *     an epoch bump rather than a loop, so it stays cheap at any table size.
 *     world.nim calls it when the collector records a fault and when the player
 *     list identity changes, so a world that has been torn down cannot be
 *     answered for out of a cache.
 *
 * THE PREDICATE IS REPLICATED, AND THE REPLICATION IS AUDITED LIVE. A miss used
 * to cost TWO syscalls: `aowl_is_readable` (one VirtualQuery) and then a second
 * VirtualQuery here to learn the region, because the first one's mbi is not
 * visible to us. `sp_rdc_pred` below applies the SAME clauses in the SAME order
 * to ONE mbi, so a miss is one syscall. To keep that from silently drifting
 * from `abi/aowlspt_shim.h`, one miss in SP_RDC_AUDIT_EVERY also calls the real
 * `aowl_is_readable` and compares; `pred-disagree` counts any difference. A
 * non-zero pred-disagree means this file has drifted and must be resynced --
 * it is a measurement, not a claim.
 *
 * IT OPENS NO GUARD AND INSTALLS NOTHING. No detour, no name resolved, no RVA
 * called, nothing in the game dereferenced. It sits strictly outside any
 * `aowl_p_p_seh` (that guard is not re-entrant -- CLAUDE.md 5), holds only
 * fixed-size static storage, and allocates nothing, managed or otherwise.
 *
 * HONESTY. It counts hits, misses, evictions, expiries and refusals so the log
 * can state the cache's own behaviour as a measured number rather than as an
 * assumption, and so "0 lookups, NEVER RAN" is distinguishable from "every
 * lookup missed".
 */
#ifndef AOWLSPT_MAPS_RDCACHE_H
#define AOWLSPT_MAPS_RDCACHE_H

#include <stdint.h>
#include <windows.h>

#include "aowlspt_shim.h"   /* aowl_is_readable -- the predicate, unchanged */

#define SP_RDC_SETS         1024    /* 1024 sets x 2 ways = 2048 entries      */
#define SP_RDC_WAYS         2
#define SP_RDC_CHUNK_SHIFT  16      /* 64KB granule: the Windows alloc unit   */
#define SP_RDC_POS_TTL_MS   250     /* stale positive == crash; keep it short */
#define SP_RDC_NEG_TTL_MS  2000     /* stale negative == a decline; cheap      */
#define SP_RDC_MIN_POS_SIZE 0x10000 /* 64 KB: heap segment / image section     */
#define SP_RDC_AUDIT_EVERY  256     /* 1 miss in N re-checked against the shim */

typedef struct {
    uintptr_t tag;       /* address >> SP_RDC_CHUNK_SHIFT, 0 == empty slot   */
    uintptr_t base;      /* mbi.BaseAddress                                  */
    uintptr_t end;       /* base + mbi.RegionSize                            */
    uint64_t  stamp;     /* GetTickCount64 at the VirtualQuery               */
    uint32_t  epoch;     /* != sp_rdc.epoch  =>  flushed, treat as empty     */
    int32_t   ok;        /* what the predicate said for this region          */
} SpRdcEntry;

typedef struct {
    SpRdcEntry e[SP_RDC_SETS][SP_RDC_WAYS];
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
} SpRdcState;

static SpRdcState sp_rdc;   /* zero-initialised static storage; epoch 0 */

static void sp_rdc_flush(void) {
    sp_rdc.epoch++;
    if (sp_rdc.epoch == 0) sp_rdc.epoch = 1;   /* never collide with a wrapped 0 */
    sp_rdc.flushes++;
}

/* THE PREDICATE, replicated clause-for-clause from `aowl_is_readable` in
 * abi/aowlspt_shim.h, applied to an mbi WE already hold so a miss costs one
 * syscall instead of two. Audited live against the original (see the header).
 * If you change one of these, change both, and expect `pred-disagree` to say so
 * if you do not. */
static int32_t sp_rdc_pred(const MEMORY_BASIC_INFORMATION* mbi,
                           uintptr_t a, uintptr_t need) {
    if (mbi->State != MEM_COMMIT) return 0;
    if (mbi->Protect & (PAGE_NOACCESS | PAGE_GUARD)) return 0;
    if (!(mbi->Protect & (PAGE_READONLY | PAGE_READWRITE | PAGE_WRITECOPY |
                          PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE |
                          PAGE_EXECUTE_WRITECOPY))) return 0;
    {
        uintptr_t start = (uintptr_t)mbi->BaseAddress;
        uintptr_t end   = start + (uintptr_t)mbi->RegionSize;
        if (a < start) return 0;          /* v1's containment, made explicit */
        return need <= end ? 1 : 0;
    }
}

static uint32_t sp_rdc_set_of(uintptr_t tag) {
    /* Mix, so that regions laid out at a regular stride do not all alias into
     * one set -- the failure mode a plain (tag & MASK) would reintroduce. */
    uint64_t h = (uint64_t)tag * 0x9E3779B97F4A7C15ull;
    return (uint32_t)((h >> 40) & (uint64_t)(SP_RDC_SETS - 1));
}

/* The cached predicate. Contract IDENTICAL to `aowl_is_readable`: 1 iff
 * [p, p+size) lies wholly inside one committed, non-guard, readable region. */
static int32_t sp_rdc_readable(void* p, int32_t size) {
    uintptr_t a, need, tag;
    uint64_t now;
    uint32_t set;
    int32_t w, ans;
    MEMORY_BASIC_INFORMATION mbi;

    if (!p || size <= 0) return 0;
    a = (uintptr_t)p;
    need = a + (uintptr_t)size;
    if (need < a) return 0;            /* overflow -- same refusal as the guard */

    now = GetTickCount64();
    /* +1, not |1: it must stay INJECTIVE. `| 1` would give adjacent 64KB chunks
     * the same tag, which containment would then reject as a miss -- correct,
     * but a self-inflicted conflict. */
    tag = (a >> SP_RDC_CHUNK_SHIFT) + 1u; /* never 0; 0 marks an empty slot  */
    set = sp_rdc_set_of(tag);

    for (w = 0; w < SP_RDC_WAYS; w++) {
        SpRdcEntry* e = &sp_rdc.e[set][w];
        uint64_t ttl;
        if (e->tag != tag) continue;
        if (e->epoch != sp_rdc.epoch) continue;          /* flushed */
        if (a < e->base || need > e->end) continue;      /* containment */
        ttl = e->ok ? (uint64_t)SP_RDC_POS_TTL_MS : (uint64_t)SP_RDC_NEG_TTL_MS;
        if (now - e->stamp > ttl) { e->tag = 0; sp_rdc.expired++; continue; }
        sp_rdc.hits++;
        return e->ok;
    }

    /* MISS. ONE VirtualQuery, and the same predicate the guard applies. */
    sp_rdc.misses++;
    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return 0;   /* guard's refusal */
    ans = sp_rdc_pred(&mbi, a, need);

    /* Live audit of the replication, on a sample of misses. Costs one extra
     * syscall 1 time in SP_RDC_AUDIT_EVERY and is the only thing that can prove
     * this file has not drifted from abi/aowlspt_shim.h. */
    if (++sp_rdc.auditTick >= (uint32_t)SP_RDC_AUDIT_EVERY) {
        sp_rdc.auditTick = 0;
        sp_rdc.auditChecks++;
        if (aowl_is_readable(p, size) != ans) sp_rdc.auditDisagree++;
    }

    {
        uintptr_t base = (uintptr_t)mbi.BaseAddress;
        uintptr_t end  = base + (uintptr_t)mbi.RegionSize;
        if (end <= base) return ans;
        /* A POSITIVE is only stored for a large region (see the header comment).
         * Anything else is answered honestly and forgotten. */
        if (ans && (end - base) < (uintptr_t)SP_RDC_MIN_POS_SIZE) {
            sp_rdc.uncacheable++;
            return ans;
        }
        {
            /* Victim: an empty/flushed way first, else the OLDER stamp. */
            SpRdcEntry* v = &sp_rdc.e[set][0];
            for (w = 0; w < SP_RDC_WAYS; w++) {
                SpRdcEntry* c = &sp_rdc.e[set][w];
                if (c->tag == 0 || c->epoch != sp_rdc.epoch) { v = c; break; }
                if (c->stamp < v->stamp) v = c;
            }
            /* Was this eviction forced by CAPACITY rather than by time? That is
             * the number which decides whether the table is big enough. */
            if (v->tag != 0 && v->tag != tag && v->epoch == sp_rdc.epoch) {
                uint64_t vttl = v->ok ? (uint64_t)SP_RDC_POS_TTL_MS
                                      : (uint64_t)SP_RDC_NEG_TTL_MS;
                if (now - v->stamp <= vttl) sp_rdc.evictLive++;
            }
            v->tag = tag; v->base = base; v->end = end; v->stamp = now;
            v->epoch = sp_rdc.epoch; v->ok = ans ? 1 : 0;
        }
    }
    return ans;
}

static int64_t sp_rdc_hits(void)        { return sp_rdc.hits; }
static int64_t sp_rdc_misses(void)      { return sp_rdc.misses; }
static int64_t sp_rdc_flushes(void)     { return sp_rdc.flushes; }
static int64_t sp_rdc_uncacheable(void) { return sp_rdc.uncacheable; }
static int64_t sp_rdc_evict_live(void)  { return sp_rdc.evictLive; }
static int64_t sp_rdc_expired(void)     { return sp_rdc.expired; }
static int64_t sp_rdc_audits(void)      { return sp_rdc.auditChecks; }
static int64_t sp_rdc_disagree(void)    { return sp_rdc.auditDisagree; }

#endif /* AOWLSPT_MAPS_RDCACHE_H */
