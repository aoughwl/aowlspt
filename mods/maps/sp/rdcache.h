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
 * process's very large VAD tree -- and this mod issues one PER FIELD HOP:
 * classOf alone is four, posOf is five, and the string readers used to issue one
 * PER UTF-16 CHARACTER (sp_rd_chars' span guard already fixed that half; its
 * effect is not yet measured).
 *
 * WHAT THIS CHANGES, AND WHAT IT DELIBERATELY DOES NOT.
 *
 * The check is NOT removed and NOT weakened. `aowl_is_readable(p, size)` asks
 * exactly one question -- "does [p, p+size) lie wholly inside ONE committed,
 * non-guard, readable region?" -- and answers it from a `MEMORY_BASIC_INFORMATION`
 * describing a REGION, not an address. That answer is therefore valid for every
 * address in that region, and re-asking it per hop re-derives an identical
 * answer at syscall price. This file remembers the region and replays the SAME
 * predicate against it. A miss falls straight through to the real
 * `aowl_is_readable`; there is no path here that returns 1 without some
 * `VirtualQuery` having said so.
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
 * INVALIDATION ON FAULT is explicit: `sp_rdc_flush()`. world.nim calls it when
 * the collector records a fault and when the player list identity changes, so a
 * world that has been torn down cannot be answered for out of a cache.
 *
 * IT OPENS NO GUARD AND INSTALLS NOTHING. No detour, no name resolved, no RVA
 * called, nothing in the game dereferenced. It sits strictly outside any
 * `aowl_p_p_seh` (that guard is not re-entrant -- CLAUDE.md 5), holds only
 * fixed-size static storage, and allocates nothing, managed or otherwise.
 *
 * HONESTY. It counts hits, misses and refusals so the log can state the cache's
 * own behaviour as a measured number rather than as an assumption, and so
 * "0 lookups, NEVER RAN" is distinguishable from "every lookup missed".
 */
#ifndef AOWLSPT_MAPS_RDCACHE_H
#define AOWLSPT_MAPS_RDCACHE_H

#include <stdint.h>
#include <windows.h>

#include "aowlspt_shim.h"   /* aowl_is_readable -- the predicate, unchanged */

#define SP_RDC_SLOTS        32
#define SP_RDC_POS_TTL_MS   250     /* stale positive == crash; keep it short */
#define SP_RDC_NEG_TTL_MS  2000     /* stale negative == a decline; cheap      */
#define SP_RDC_MIN_POS_SIZE 0x10000 /* 64 KB: heap segment / image section     */

typedef struct {
    uintptr_t base;      /* mbi.BaseAddress                      */
    uintptr_t end;       /* base + mbi.RegionSize                */
    uint64_t  stamp;     /* GetTickCount64 at the VirtualQuery   */
    int32_t   ok;        /* what aowl_is_readable said for it    */
    int32_t   used;
} SpRdcEntry;

typedef struct {
    SpRdcEntry e[SP_RDC_SLOTS];
    int32_t    next;     /* round-robin victim                   */
    int64_t    hits;
    int64_t    misses;
    int64_t    flushes;
    int64_t    uncacheable;  /* answered by syscall, deliberately not stored */
} SpRdcState;

static SpRdcState sp_rdc = {{{0,0,0,0,0}}, 0, 0, 0, 0, 0};

static void sp_rdc_flush(void) {
    int32_t i;
    for (i = 0; i < SP_RDC_SLOTS; i++) sp_rdc.e[i].used = 0;
    sp_rdc.next = 0;
    sp_rdc.flushes++;
}

/* The cached predicate. Contract IDENTICAL to `aowl_is_readable`: 1 iff
 * [p, p+size) lies wholly inside one committed, non-guard, readable region. */
static int32_t sp_rdc_readable(void* p, int32_t size) {
    uintptr_t a, need;
    uint64_t now;
    int32_t i, ans;
    MEMORY_BASIC_INFORMATION mbi;

    if (!p || size <= 0) return 0;
    a = (uintptr_t)p;
    need = a + (uintptr_t)size;
    if (need < a) return 0;            /* overflow -- same refusal as the guard */

    now = GetTickCount64();

    for (i = 0; i < SP_RDC_SLOTS; i++) {
        SpRdcEntry* e = &sp_rdc.e[i];
        uint64_t ttl;
        if (!e->used) continue;
        if (a < e->base || need > e->end) continue;
        ttl = e->ok ? (uint64_t)SP_RDC_POS_TTL_MS : (uint64_t)SP_RDC_NEG_TTL_MS;
        if (now - e->stamp > ttl) { e->used = 0; continue; }
        sp_rdc.hits++;
        return e->ok;
    }

    /* MISS. The real guard answers, exactly as before. */
    ans = aowl_is_readable(p, size);
    sp_rdc.misses++;

    /* Learn the REGION this answer came from. A second VirtualQuery is the
     * price of the miss only, and it is the same query the guard just made --
     * we cannot see its mbi, so we re-ask rather than reach into it. */
    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return ans;
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
            SpRdcEntry* e = &sp_rdc.e[sp_rdc.next];
            sp_rdc.next = (sp_rdc.next + 1) % SP_RDC_SLOTS;
            e->base = base; e->end = end; e->stamp = now;
            e->ok = ans ? 1 : 0; e->used = 1;
        }
    }
    return ans;
}

static int64_t sp_rdc_hits(void)        { return sp_rdc.hits; }
static int64_t sp_rdc_misses(void)      { return sp_rdc.misses; }
static int64_t sp_rdc_flushes(void)     { return sp_rdc.flushes; }
static int64_t sp_rdc_uncacheable(void) { return sp_rdc.uncacheable; }

#endif /* AOWLSPT_MAPS_RDCACHE_H */
