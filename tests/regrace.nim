## regrace -- the SDK's *registration* tables under registrations and firings
## arriving on many threads at once.
##
##     regrace [--reg 32] [--dispatch 12] [--rounds 2] [--per 15] [--bench]
##
## `tests/tickrace.nim` did this for the scheduler table. This does it for the
## four tables next to it, which have the same `add`-while-indexing shape and
## are read on hotter threads: `gRoutes`, `gEvents`, `gPatches` (with its
## parallel `gPatchTargets`) and `gTypedPatches`.
##
## ## Why there is a race at all, when registration "happens at load"
##
## Because it does not. Two of this repository's own examples register from
## `on_update` rather than `on_load`, and both do it for a reason that cannot
## be designed away: `examples/clientprobe` waits three seconds for EFT's
## assemblies before it can `patch` anything, and `examples/lesson` arms nine
## hooks from `armHooks` on the first tick its types resolve. A type that does
## not exist yet cannot be hooked at load. On top of that a route handler or an
## event handler may register, and those arrive on the backend's sixteen
## workers.
##
## So a registration lands on an arbitrary thread at an arbitrary time, and the
## *reads* are on other threads again: a route on a backend worker, a patch on
## the game's thread inside a detoured method.
##
## ## What it checks, and what it refuses to check
##
## Not "did it survive". The loudest failure of an unguarded `seq` is a torn
## buffer, and that is not the likeliest one. The likeliest is the quiet one:
##
##     gRoutes.add handler                                  # thread A, len 0->1
##                                    gRoutes.add other     # thread B, len 1->2
##     routeRegister(url, toCookie(gRoutes.len - 1))        # A registers B's!
##
## `/a` is then served by `/b`'s handler and `/a`'s handler is unreachable for
## the session. No crash, no log line, a wrong answer. So every registration
## here carries an **identity** -- one of eight handlers, one per registering
## thread -- and the name it was registered under carries the same digit, and
## the check is equality between the two:
##
##   * every dispatch must reach the handler whose identity the *registration*
##     used. A shared cookie shows up as a handler answering for a name that is
##     not its own.
##   * a JSON patch must be handed the target string its own registration
##     supplied. `gPatches` and `gPatchTargets` are two sequences that are only
##     meaningful in step, so this is the check that sees them drift apart --
##     the right handler told the wrong method name, which is the failure that
##     looks least like a bug.
##   * no two live registrations may share a cookie. A duplicate is one handler
##     permanently unreachable, and it is worth naming separately from the
##     identity check because a duplicate between two threads that happen to
##     share an identity would otherwise pass.
##   * every registration that returned `Ok` must be reachable afterwards. The
##     harness host never refuses, so a registration the library reported as
##     `Ok` and cannot be dispatched to is a registration the library lost.
##   * the counts must add up: as many recorded registrations as successful
##     calls, and `registeredRoutes()` and friends must agree.
##
## ## Proving the checks can fail
##
## A check that has never failed is a check nobody has read. Every one of them
## was made to fail on purpose, and the mutations were built and run:
##
##   * **The library as it was** -- `gRoutes.add handler` then
##     `toCookie(gRoutes.len - 1)`, the four tables growing under the readers.
##     It does not report a check at all: it faults. Eight registrars against
##     six dispatchers dies on `__fastfail` with the heap corrupted, three runs
##     out of three, before the end of round one; **two** registrars against
##     **one** dispatcher dies at 0xc0000005, four runs out of four, which is a
##     reader indexing a `seq` another thread has moved. That is the loud half
##     of the fault and it is not what these checks are for.
##   * So the quiet half was isolated: **the tables reserved as they are now,
##     but the index taken outside the critical section** -- `gRoutes[gRoutesN]
##     = handler; inc gRoutesN; outIdx = gRoutesN - 1`, which is exactly the old
##     check-then-act with the memory corruption removed. The process survives
##     and the answers are wrong: the identity check reports dozens of dispatches
##     per hundred thousand reaching a handler that is not the one their
##     registration named, the cookie check finds duplicates, the slot counts
##     stop agreeing, and the sweep finds registrations that answer as somebody
##     else. Four runs out of eight at the defaults below -- which is a
##     failing test, because a check that fires half the time fires.
##
##     That mutation is *narrower* than the bug it stands in for -- the real
##     `add` did an allocation and a copy of the whole buffer between the two
##     halves of the race, so its window was microseconds where this one is
##     nanoseconds. It is the defaults that make up the difference: 32
##     registering threads rather than 8, because what has to collide is two
##     threads inside a few instructions of each other.
##   * **`patchTyped`'s old `shrink` on a refused registration.** `park` put
##     back as what `shrink(gTypedPatches, len - 1)` amounted to -- give the
##     last index back -- with the harness told to refuse one typed
##     registration in three (`--refuse-every 3`). Five runs out of five: the
##     typed identity check reports dispatches reaching the wrong handler, the
##     cookie check finds duplicates, and the sweep finds registrations
##     answering as somebody else. The index given back is not the refused
##     registration's, it is whichever was taken last -- which under two
##     threads is the *other* one's, installed a moment earlier and reported to
##     its owner as armed, and then handed out again to a third.
##
##     This is also why `park` refills the slot rather than recycling it: a
##     refused registration costs one slot of a thousand for the session, and
##     that is the cheaper of the two mistakes by a wide margin.
##   * **The bound**, by removing the `gRoutesN < RouteCapacity` test: the fill
##     loop at the end then writes past the table instead of being refused, and
##     the run faults rather than reporting "the 1025th route is refused".
##
## ## The measurement
##
## `--bench` times the four trampolines with nothing racing. It is the number
## the design argument rests on: the fix adds **no instruction at all** to the
## read path -- `typedPatchTrampoline` is byte-identical, only the `len` it
## bounds-checks against is now a constant -- whereas a lock pair on that path
## would be 25-27 ns against a 21.8 ns typed prefix. `perfbench` measures the
## host side of the same hook and is likewise unmoved; this measures the mod
## side, which is the part this file changed.

import std/[cmdline, syncio]
import aowlspt
import aowlspt/sync

{.emit: """#include <windows.h>""".}
{.emit: """#include <stdint.h>""".}
{.emit: """#include <stdlib.h>""".}
{.emit: """#include <string.h>""".}
{.emit: """#include "aowlspt_abi.h" """.}
{.emit: """#include "aowlspt_frame.h" """.}

{.emit: """
/* ------------------------------------------------------------------ *
 * Identities and counters.
 *
 * Atomic even though this is only a test: a mismatch counted with `++`
 * from fourteen threads is a mismatch count that can read zero, which is
 * the exact failure mode the thing under test has.
 * ------------------------------------------------------------------ */
#define AOWL_RR_KINDS 8
#define AOWL_RR_MAX   4096

typedef AowlStatus (AOWLSPT_CALL *rr_route_fn)(void*, AowlSlice, AowlSlice, AowlSlice, AowlBuffer*);
typedef AowlStatus (AOWLSPT_CALL *rr_event_fn)(void*, AowlSlice, AowlBuffer*);
typedef AowlStatus (AOWLSPT_CALL *rr_patch_fn)(void*, AowlSlice, AowlSlice, AowlBuffer*);
typedef AowlStatus (AOWLSPT_CALL *rr_typed_fn)(void*, const AowlPatchFrame*);

/* One recorded registration. `name` carries the identity of the thread that
 * made it as its first character, so a dispatch can be checked against the
 * registration without either side having to look anything up. */
typedef struct rr_ent {
    void*   cb;
    void*   user;
    int32_t k;
    char    name[48];
} rr_ent;

static rr_ent rr_routes[AOWL_RR_MAX];
static rr_ent rr_events[AOWL_RR_MAX];
static rr_ent rr_jpatch[AOWL_RR_MAX];
static rr_ent rr_tpatch[AOWL_RR_MAX];
static int32_t rr_nroute = 0, rr_nevent = 0, rr_njpatch = 0, rr_ntpatch = 0;

/* Its own critical section, deliberately not the mod's and not the library's:
 * the subject of the test must not be load-bearing for the harness that tests
 * it. Held only around the table it protects, never around a call into the
 * library. */
static CRITICAL_SECTION rr_cs;
static LONG rr_cs_ready = 0;

static void rr_init(void) {
    if (InterlockedCompareExchange(&rr_cs_ready, 1, 0) == 0) {
        InitializeCriticalSection(&rr_cs);
        InterlockedExchange(&rr_cs_ready, 2);
    }
    while (InterlockedCompareExchange(&rr_cs_ready, 2, 2) != 2) Sleep(0);
}

/* Failure counters, one pair per kind. `bad` is what the checks read. */
static LONG64 rr_good[4];
static LONG64 rr_bad[4];
static LONG64 rr_refused = 0;   /* the harness refused a registration        */
static LONG64 rr_overflow = 0;  /* the harness table filled, not the library */
static LONG   rr_running = 0;
static LONG   rr_refuse_every = 0; /* 0 = never; else refuse 1 typed in N     */
static LONG   rr_refuse_tick = 0;

static void rr_hit(int32_t kind, int32_t ok) {
    if (ok) InterlockedIncrement64(&rr_good[kind]);
    else    InterlockedIncrement64(&rr_bad[kind]);
}
static int64_t rr_get_good(int32_t k) { return (int64_t)InterlockedCompareExchange64(&rr_good[k], 0, 0); }
static int64_t rr_get_bad(int32_t k)  { return (int64_t)InterlockedCompareExchange64(&rr_bad[k], 0, 0); }
static int64_t rr_get_refused(void)   { return (int64_t)InterlockedCompareExchange64(&rr_refused, 0, 0); }
static int64_t rr_get_overflow(void)  { return (int64_t)InterlockedCompareExchange64(&rr_overflow, 0, 0); }
static int32_t rr_is_running(void)    { return InterlockedCompareExchange(&rr_running, 0, 0); }
static void    rr_set_running(int32_t v) { InterlockedExchange(&rr_running, v); }
static void    rr_set_refuse_every(int32_t n) { InterlockedExchange(&rr_refuse_every, n); }

/* ------------------------------------------------------------------ *
 * The host the library is bound to.
 *
 * It never refuses (unless asked to, for the `shrink` mutation), so a
 * registration the library reported as Ok has been recorded, and one that
 * cannot be dispatched to afterwards is the library's doing.
 * ------------------------------------------------------------------ */
static AowlHostApi  rr_api;
static AowlHostInfo rr_info;
static AowlModApi   rr_modapi;

static void* AOWLSPT_CALL rr_alloc(void* ctx, int32_t n) { (void)ctx; return malloc((size_t)n); }
static void  AOWLSPT_CALL rr_free(void* ctx, void* p)    { (void)ctx; free(p); }
static void  AOWLSPT_CALL rr_log(void* ctx, int32_t lvl, AowlSlice m) { (void)ctx; (void)lvl; (void)m; }

static void rr_copy_name(char* dst, AowlSlice s) {
    int32_t n = s.len;
    if (n > 46) n = 46;
    if (n > 0 && s.ptr) memcpy(dst, s.ptr, (size_t)n);
    dst[n > 0 ? n : 0] = '\0';
}

/* The identity is the first character of the registered name. Reading it here
 * rather than being told it is deliberate: it means the harness learns the
 * identity from the *registration*, exactly as the check needs, and cannot be
 * handed a matching pair by a library that got the cookie wrong. */
static int32_t rr_identity(AowlSlice s) {
    if (s.len < 1 || !s.ptr) return -1;
    if (s.ptr[0] < '0' || s.ptr[0] > '7') return -1;
    return (int32_t)(s.ptr[0] - '0');
}

static int32_t rr_record(rr_ent* tab, int32_t* n, AowlSlice name, void* cb, void* user) {
    int32_t idx = -1;
    EnterCriticalSection(&rr_cs);
    if (*n < AOWL_RR_MAX) {
        idx = *n;
        tab[idx].cb = cb;
        tab[idx].user = user;
        tab[idx].k = rr_identity(name);
        rr_copy_name(tab[idx].name, name);
        *n = idx + 1;
    }
    LeaveCriticalSection(&rr_cs);
    if (idx < 0) InterlockedIncrement64(&rr_overflow);
    return idx;
}

static AowlStatus AOWLSPT_CALL rr_route_register(void* ctx, AowlSlice url, int32_t kind,
                                                 AowlRouteFn h, void* user) {
    (void)ctx; (void)kind;
    if (rr_record(rr_routes, &rr_nroute, url, (void*)h, user) < 0) return AOWLSPT_ERR_GENERIC;
    return AOWLSPT_OK;
}

static AowlStatus AOWLSPT_CALL rr_event_subscribe(void* ctx, AowlSlice name,
                                                  AowlCallbackFn h, void* user) {
    (void)ctx;
    if (rr_record(rr_events, &rr_nevent, name, (void*)h, user) < 0) return AOWLSPT_ERR_GENERIC;
    return AOWLSPT_OK;
}

static AowlStatus AOWLSPT_CALL rr_patch(void* ctx, AowlSlice target, int32_t kind,
                                        AowlPatchFn h, void* user) {
    (void)ctx; (void)kind;
    if (rr_record(rr_jpatch, &rr_njpatch, target, (void*)h, user) < 0) return AOWLSPT_ERR_GENERIC;
    return AOWLSPT_OK;
}

static AowlStatus AOWLSPT_CALL rr_patch_typed(void* ctx, AowlSlice target, int32_t kind,
                                              AowlTypedPatchFn h, void* user) {
    (void)ctx; (void)kind;
    /* The refusal path, for the mutation that proves the `shrink` check. Off
     * unless asked for. */
    LONG every = InterlockedCompareExchange(&rr_refuse_every, 0, 0);
    if (every > 0) {
        LONG t = InterlockedIncrement(&rr_refuse_tick);
        if ((t % every) == 0) {
            InterlockedIncrement64(&rr_refused);
            return AOWLSPT_ERR_GENERIC;
        }
    }
    if (rr_record(rr_tpatch, &rr_ntpatch, target, (void*)h, user) < 0) return AOWLSPT_ERR_GENERIC;
    return AOWLSPT_OK;
}

static void* rr_host_new(void) {
    rr_init();
    memset(&rr_api, 0, sizeof(rr_api));
    memset(&rr_info, 0, sizeof(rr_info));
    memset(&rr_modapi, 0, sizeof(rr_modapi));
    rr_info.size         = (int32_t)sizeof(AowlHostInfo);
    rr_info.abi_version  = AOWLSPT_ABI_VERSION;
    rr_info.abi_revision = AOWLSPT_ABI_REVISION;
    rr_info.side         = AOWLSPT_SIDE_SIM;
    /* The full struct, so `typedPatchesReady()` is true and the typed table is
     * actually exercised -- it is the one read on the game's thread. */
    rr_api.size            = (int32_t)sizeof(AowlHostApi);
    rr_api.ctx             = NULL;
    rr_api.info            = &rr_info;
    rr_api.alloc           = rr_alloc;
    rr_api.free            = rr_free;
    rr_api.log             = rr_log;
    rr_api.route_register  = rr_route_register;
    rr_api.event_subscribe = rr_event_subscribe;
    rr_api.patch           = rr_patch;
    rr_api.patch_typed     = rr_patch_typed;
    return (void*)&rr_api;
}

static void* rr_modapi_ptr(void) { return (void*)&rr_modapi; }

/* ------------------------------------------------------------------ *
 * Dispatch -- the read side, on threads that are not the registering ones.
 * ------------------------------------------------------------------ */
static int32_t rr_count(int32_t kind) {
    int32_t n;
    EnterCriticalSection(&rr_cs);
    n = (kind == 0) ? rr_nroute : (kind == 1) ? rr_nevent
      : (kind == 2) ? rr_njpatch : rr_ntpatch;
    LeaveCriticalSection(&rr_cs);
    return n;
}

/* Entries never move and are never rewritten, so once the count has been read
 * under the lock the entry itself needs none. */
static void rr_do_route(int32_t i) {
    AowlBuffer out; AowlSlice u, b, s; AowlStatus st;
    rr_ent* e = &rr_routes[i];
    out.ptr = NULL; out.len = 0;
    u.ptr = (const uint8_t*)e->name; u.len = (int32_t)strlen(e->name);
    b.ptr = NULL; b.len = 0; s.ptr = NULL; s.len = 0;
    st = ((rr_route_fn)e->cb)(e->user, u, b, s, &out);
    rr_hit(0, st == AOWLSPT_OK && out.len == 1 && out.ptr &&
              (int32_t)(out.ptr[0] - '0') == e->k);
    if (out.ptr) free(out.ptr);
}

static void rr_do_event(int32_t i) {
    AowlBuffer out; AowlSlice p; AowlStatus st;
    rr_ent* e = &rr_events[i];
    out.ptr = NULL; out.len = 0;
    p.ptr = (const uint8_t*)e->name; p.len = (int32_t)strlen(e->name);
    st = ((rr_event_fn)e->cb)(e->user, p, &out);
    rr_hit(1, st == AOWLSPT_OK && out.len == 1 && out.ptr &&
              (int32_t)(out.ptr[0] - '0') == e->k);
    if (out.ptr) free(out.ptr);
}

/* The two-table check. The handler answers "<identity>:<the target string it
 * was handed>", and the target it is handed comes from `gPatchTargets`, not
 * from the slice below -- that is the whole reason this reads the answer
 * rather than trusting the status. The slice is deliberately something else
 * entirely, so a library that fell back to it would be caught too. */
static void rr_do_jpatch(int32_t i) {
    AowlBuffer out; AowlSlice t, a; AowlStatus st;
    char want[64];
    rr_ent* e = &rr_jpatch[i];
    out.ptr = NULL; out.len = 0;
    t.ptr = (const uint8_t*)"WRONG"; t.len = 5;
    a.ptr = NULL; a.len = 0;
    st = ((rr_patch_fn)e->cb)(e->user, t, a, &out);
    want[0] = (char)('0' + e->k);
    want[1] = ':';
    strcpy(want + 2, e->name);
    rr_hit(2, st == AOWLSPT_PATCH_SKIP && out.ptr &&
              out.len == (int32_t)strlen(want) &&
              memcmp(out.ptr, want, (size_t)out.len) == 0);
    if (out.ptr) free(out.ptr);
}

/* The typed frame. Built here rather than by a detour engine: `self` carries
 * the identity the registration used, and handler `k` returns "replace" only
 * when it sees its own. A cookie handed to the wrong handler therefore comes
 * back as OK instead of PATCH_SKIP. */
static void rr_do_tpatch(int32_t i) {
    AowlPatchFrame f;
    AowlStatus st;
    rr_ent* e = &rr_tpatch[i];
    memset(&f, 0, sizeof(f));
    f.size    = (int32_t)sizeof(AowlPatchFrame);
    f.argc    = 0;
    f.flags   = AOWL_FRAME_F_STATIC;
    f.live    = 1;
    f.self    = (uint64_t)(e->k + 1);
    f.retKind = AOWLSPT_ARG_NONE;
    f.serial  = 1;
    st = ((rr_typed_fn)e->cb)(e->user, &f);
    rr_hit(3, st == AOWLSPT_PATCH_SKIP);
}

static void rr_dispatch_one(int32_t kind, int32_t i) {
    if (kind == 0) rr_do_route(i);
    else if (kind == 1) rr_do_event(i);
    else if (kind == 2) rr_do_jpatch(i);
    else rr_do_tpatch(i);
}

/* Walks everything recorded, once each. Used after the storm for "every
 * registration that returned Ok is reachable". */
static int64_t rr_sweep(void) {
    int32_t kind, i, n;
    int64_t ran = 0;
    for (kind = 0; kind < 4; kind++) {
        n = rr_count(kind);
        for (i = 0; i < n; i++) { rr_dispatch_one(kind, i); ran++; }
    }
    return ran;
}

/* No two live registrations may share a cookie. A duplicate is one handler
 * permanently unreachable. Cookies are `index + 1` and the capacities are in
 * the low thousands, so a byte per possible cookie is the whole of it. */
#define AOWL_RR_COOKIES 8192
static unsigned char rr_seen[AOWL_RR_COOKIES];

static int32_t rr_dup_cookies(int32_t kind) {
    rr_ent* tab = (kind == 0) ? rr_routes : (kind == 1) ? rr_events
                : (kind == 2) ? rr_jpatch : rr_tpatch;
    int32_t n = rr_count(kind), i, dups = 0;
    memset(rr_seen, 0, sizeof(rr_seen));
    for (i = 0; i < n; i++) {
        uintptr_t c = (uintptr_t)tab[i].user;
        if (c < AOWL_RR_COOKIES) {
            if (rr_seen[c]) dups++;
            rr_seen[c] = 1;
        } else {
            dups++;   /* a cookie no slot could have produced */
        }
    }
    return dups;
}

/* And no registration may have been recorded under an identity the harness
 * could not read -- which would mean the name never reached the host. */
static int32_t rr_bad_identity(int32_t kind) {
    rr_ent* tab = (kind == 0) ? rr_routes : (kind == 1) ? rr_events
                : (kind == 2) ? rr_jpatch : rr_tpatch;
    int32_t n = rr_count(kind), i, bad = 0;
    for (i = 0; i < n; i++) if (tab[i].k < 0) bad++;
    return bad;
}

/* ------------------------------------------------------------------ *
 * Threads.
 *
 * Registering and dispatching threads are started interleaved: with every
 * registrar started first, the tables are already full by the time a reader
 * runs, and the collision this looks for is between a write and a read.
 * ------------------------------------------------------------------ */
int32_t aowl_rr_reg_thread(int32_t which);   /* nimony, below */

static DWORD WINAPI rr_reg_thunk(LPVOID p) {
    return (DWORD)aowl_rr_reg_thread((int32_t)(intptr_t)p);
}

/* Dispatchers run flat out for the length of the round, walking whatever is
 * registered at the moment they look. Each starts at a different offset so
 * that six threads are not all inside the same handler. */
static DWORD WINAPI rr_dispatch_thunk(LPVOID p) {
    int32_t me = (int32_t)(intptr_t)p;
    int32_t kind = me & 3;
    int32_t i = me;
    while (rr_is_running()) {
        int32_t n = rr_count(kind);
        if (n > 0) {
            rr_dispatch_one(kind, i % n);
            i += 7;
            if (i > 1000000) i = me;
        } else {
            Sleep(0);
        }
        kind = (kind + 1) & 3;
    }
    return 0;
}

#define AOWL_RR_MAXT 64
static HANDLE  rr_regt[AOWL_RR_MAXT];
static HANDLE  rr_dist[AOWL_RR_MAXT];
static int32_t rr_nreg = 0;
static int32_t rr_ndis = 0;

static void rr_start(int32_t regs, int32_t dispatch) {
    int32_t r = 0, d = 0;
    rr_nreg = 0;
    rr_ndis = 0;
    rr_set_running(1);
    while (r < regs || d < dispatch) {
        if (r < regs && rr_nreg < AOWL_RR_MAXT) {
            rr_regt[rr_nreg++] = CreateThread(NULL, 0, rr_reg_thunk,
                                              (LPVOID)(intptr_t)r, 0, NULL);
            r++;
        }
        if (d < dispatch && rr_ndis < AOWL_RR_MAXT) {
            rr_dist[rr_ndis++] = CreateThread(NULL, 0, rr_dispatch_thunk,
                                              (LPVOID)(intptr_t)d, 0, NULL);
            d++;
        }
    }
}

/* Joins the registrars first, *then* stops the dispatchers. Two steps and not
 * one: a registrar finishes on its own count while a dispatcher runs until
 * told, and clearing the flag first would end the round before the last
 * registrations had anybody reading them -- which is the window this exists to
 * open. The short sleep between the two is that window, held open on purpose. */
static void rr_join(void) {
    int32_t i;
    for (i = 0; i < rr_nreg; i++) {
        if (rr_regt[i]) {
            WaitForSingleObject(rr_regt[i], INFINITE);
            CloseHandle(rr_regt[i]);
            rr_regt[i] = NULL;
        }
    }
    Sleep(5);
    rr_set_running(0);
    for (i = 0; i < rr_ndis; i++) {
        if (rr_dist[i]) {
            WaitForSingleObject(rr_dist[i], INFINITE);
            CloseHandle(rr_dist[i]);
            rr_dist[i] = NULL;
        }
    }
    rr_nreg = 0;
    rr_ndis = 0;
}

static int64_t rr_qpc(void) { LARGE_INTEGER v; QueryPerformanceCounter(&v); return (int64_t)v.QuadPart; }
static int64_t rr_qpf(void) { LARGE_INTEGER v; QueryPerformanceFrequency(&v); return (int64_t)v.QuadPart; }
""".}

proc cHostNew(): pointer {.importc: "rr_host_new", nodecl.}
proc cModApiPtr(): pointer {.importc: "rr_modapi_ptr", nodecl.}
proc cGood(k: int32): int64 {.importc: "rr_get_good", nodecl.}
proc cBad(k: int32): int64 {.importc: "rr_get_bad", nodecl.}
proc cRefused(): int64 {.importc: "rr_get_refused", nodecl.}
proc cOverflow(): int64 {.importc: "rr_get_overflow", nodecl.}
proc cCount(kind: int32): int32 {.importc: "rr_count", nodecl.}
proc cDupCookies(kind: int32): int32 {.importc: "rr_dup_cookies", nodecl.}
proc cBadIdentity(kind: int32): int32 {.importc: "rr_bad_identity", nodecl.}
proc cSweep(): int64 {.importc: "rr_sweep", nodecl.}
proc cRunning(): int32 {.importc: "rr_is_running", nodecl.}
proc cSetRunning(v: int32) {.importc: "rr_set_running", nodecl.}
proc cStart(regs, dispatch: int32) {.importc: "rr_start", nodecl.}
proc cJoin() {.importc: "rr_join", nodecl.}
proc cSetRefuseEvery(n: int32) {.importc: "rr_set_refuse_every", nodecl.}
proc cDispatchOne(kind, i: int32) {.importc: "rr_dispatch_one", nodecl.}
proc cQpc(): int64 {.importc: "rr_qpc", nodecl.}
proc cQpf(): int64 {.importc: "rr_qpf", nodecl.}

const Kinds = 8

# ---------------------------------------------------------------------------
# The handlers, one identity each
#
# Eight of each kind rather than one closure per registration: nimony has no
# closures over enclosing locals, and identity is the whole point -- a cookie
# handed to the wrong handler shows up here as an answer carrying somebody
# else's digit, which a single shared counter could never see.
# ---------------------------------------------------------------------------

proc r0(url, body, session: string): string = "0"
proc r1(url, body, session: string): string = "1"
proc r2(url, body, session: string): string = "2"
proc r3(url, body, session: string): string = "3"
proc r4(url, body, session: string): string = "4"
proc r5(url, body, session: string): string = "5"
proc r6(url, body, session: string): string = "6"
proc r7(url, body, session: string): string = "7"

proc e0(payload: string): string = "0"
proc e1(payload: string): string = "1"
proc e2(payload: string): string = "2"
proc e3(payload: string): string = "3"
proc e4(payload: string): string = "4"
proc e5(payload: string): string = "5"
proc e6(payload: string): string = "6"
proc e7(payload: string): string = "7"

# The JSON patch handlers answer with their own identity *and* the target they
# were handed. The target comes out of `gPatchTargets`, so this is where the
# two parallel tables drifting apart becomes visible.
proc p0(target, args: string): PatchResult = patchReplace("0:" & target)
proc p1(target, args: string): PatchResult = patchReplace("1:" & target)
proc p2(target, args: string): PatchResult = patchReplace("2:" & target)
proc p3(target, args: string): PatchResult = patchReplace("3:" & target)
proc p4(target, args: string): PatchResult = patchReplace("4:" & target)
proc p5(target, args: string): PatchResult = patchReplace("5:" & target)
proc p6(target, args: string): PatchResult = patchReplace("6:" & target)
proc p7(target, args: string): PatchResult = patchReplace("7:" & target)

# The typed handlers see only registers, so the identity travels in `self`:
# handler `k` replaces exactly when it is shown `k + 1` and continues
# otherwise. `+ 1` because zero is also what a dead frame answers.
proc t0(f: PatchFrame): TypedResult =
  if selfPointer(f) == 1'u64: frameReplace() else: frameContinue()
proc t1(f: PatchFrame): TypedResult =
  if selfPointer(f) == 2'u64: frameReplace() else: frameContinue()
proc t2(f: PatchFrame): TypedResult =
  if selfPointer(f) == 3'u64: frameReplace() else: frameContinue()
proc t3(f: PatchFrame): TypedResult =
  if selfPointer(f) == 4'u64: frameReplace() else: frameContinue()
proc t4(f: PatchFrame): TypedResult =
  if selfPointer(f) == 5'u64: frameReplace() else: frameContinue()
proc t5(f: PatchFrame): TypedResult =
  if selfPointer(f) == 6'u64: frameReplace() else: frameContinue()
proc t6(f: PatchFrame): TypedResult =
  if selfPointer(f) == 7'u64: frameReplace() else: frameContinue()
proc t7(f: PatchFrame): TypedResult =
  if selfPointer(f) == 8'u64: frameReplace() else: frameContinue()

# ---------------------------------------------------------------------------
# Registration, counted so a lost one cannot be read as a firing that failed
# ---------------------------------------------------------------------------

var gOkRoute = 0
var gOkEvent = 0
var gOkJPatch = 0
var gOkTPatch = 0
var gFullRoute = 0
var gFullEvent = 0
var gFullJPatch = 0
var gFullTPatch = 0

# These four counters are read after every thread has been joined and written
# from all of them, so they are guarded -- by the *mod's* lock (`aowlspt/sync`),
# which is a different critical section from the library's and which the
# library under test never takes.

proc regRoute(kind: int32; name: string) =
  var st = ErrGeneric
  case kind
  of 0'i32: st = route(name, rkStatic, r0)
  of 1'i32: st = route(name, rkStatic, r1)
  of 2'i32: st = route(name, rkStatic, r2)
  of 3'i32: st = route(name, rkStatic, r3)
  of 4'i32: st = route(name, rkStatic, r4)
  of 5'i32: st = route(name, rkStatic, r5)
  of 6'i32: st = route(name, rkStatic, r6)
  else: st = route(name, rkStatic, r7)
  withModLock:
    if st == Ok: inc gOkRoute
    elif st == ErrGeneric: inc gFullRoute

proc regEvent(kind: int32; name: string) =
  var st = ErrGeneric
  case kind
  of 0'i32: st = on(name, e0)
  of 1'i32: st = on(name, e1)
  of 2'i32: st = on(name, e2)
  of 3'i32: st = on(name, e3)
  of 4'i32: st = on(name, e4)
  of 5'i32: st = on(name, e5)
  of 6'i32: st = on(name, e6)
  else: st = on(name, e7)
  withModLock:
    if st == Ok: inc gOkEvent
    elif st == ErrGeneric: inc gFullEvent

proc regJPatch(kind: int32; name: string) =
  var st = ErrGeneric
  case kind
  of 0'i32: st = patch(name, pkPrefix, p0, withArgs = true)
  of 1'i32: st = patch(name, pkPrefix, p1, withArgs = true)
  of 2'i32: st = patch(name, pkPrefix, p2, withArgs = true)
  of 3'i32: st = patch(name, pkPrefix, p3, withArgs = true)
  of 4'i32: st = patch(name, pkPrefix, p4, withArgs = true)
  of 5'i32: st = patch(name, pkPrefix, p5, withArgs = true)
  of 6'i32: st = patch(name, pkPrefix, p6, withArgs = true)
  else: st = patch(name, pkPrefix, p7, withArgs = true)
  withModLock:
    if st == Ok: inc gOkJPatch
    elif st == ErrGeneric: inc gFullJPatch

proc regTPatch(kind: int32; name: string) =
  var st = ErrGeneric
  case kind
  of 0'i32: st = patchTyped(name, pkPrefix, t0)
  of 1'i32: st = patchTyped(name, pkPrefix, t1)
  of 2'i32: st = patchTyped(name, pkPrefix, t2)
  of 3'i32: st = patchTyped(name, pkPrefix, t3)
  of 4'i32: st = patchTyped(name, pkPrefix, t4)
  of 5'i32: st = patchTyped(name, pkPrefix, t5)
  of 6'i32: st = patchTyped(name, pkPrefix, t6)
  else: st = patchTyped(name, pkPrefix, t7)
  withModLock:
    if st == Ok: inc gOkTPatch
    elif st == ErrGeneric: inc gFullTPatch

var gPerThread = 12
  ## Registrations of each kind, per thread, per round. Set from `--per`.

proc regThread(which: int32): int32 {.exportc: "aowl_rr_reg_thread", cdecl.} =
  ## One registering thread. Thread `k` registers under names beginning with
  ## `k` and installs handler `k` and nothing else, so every collision
  ## *between* threads is a collision between identities and therefore visible
  ## in the answers.
  let kind = which mod int32(Kinds)
  let tag = $kind & "."
  var n = 0
  while n < gPerThread:
    let s = $n
    regRoute(kind, tag & "r" & s)
    regEvent(kind, tag & "e" & s)
    regJPatch(kind, tag & "p" & s)
    regTPatch(kind, tag & "t" & s)
    inc n
  result = 0'i32

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

var failures = 0

proc say(msg: string) =
  ## Flushed, every line. A test whose subject can take the process down owes
  ## the reader the lines it had already printed: run unflushed, the buffer
  ## dies with the process and a fault in round four is indistinguishable from
  ## a fault before round one.
  echo msg
  flushFile(stdout)

proc ok(msg: string) = say "ok    " & msg
proc bad(msg: string) =
  say "FAIL  " & msg
  inc failures
proc check(cond: bool; msg: string) =
  if cond: ok(msg) else: bad(msg)

proc intOf(s: string; fallback: int): int =
  ## `parseInt` raises, and a test binary whose argument parsing can throw
  ## reports a bad flag as a crash.
  result = 0
  var any = false
  for ch in s:
    if ch >= chr(48) and ch <= chr(57):
      result = result * 10 + (ord(ch) - 48)
      any = true
    else:
      return fallback
  if not any: return fallback

const KindName = ["routes", "events", "JSON patches", "typed patches"]

const Usage = """
regrace -- the SDK registration tables under concurrent registration and firing

  regrace [options]

  --reg N       registering threads (default 32; identity is thread mod 8)
  --dispatch N  dispatching threads (default 12)
  --rounds N    rounds of register-while-dispatching (default 2)
  --per N       registrations of each kind, per thread, per round (default 15)
  --bench       only time the trampolines, single-threaded
  -h, --help    this
"""

# ---------------------------------------------------------------------------
# The measurement
#
# The read path is what the design argument is about, so it is measured rather
# than asserted. `--bench` runs it with nothing racing.
# ---------------------------------------------------------------------------

proc nsText(ticks, freq: int64; reps: int): string =
  ## Nanoseconds to one decimal, in integer arithmetic -- nimony has no `$` for
  ## a float, and a benchmark that prints its number wrong is worse than one
  ## that does not print it.
  if reps <= 0 or freq <= 0: return "?"
  let ps = ticks * 1_000_000_000 div (freq * int64(reps)) * 1000 +
           (ticks * 1_000_000_000 mod (freq * int64(reps))) * 1000 div
           (freq * int64(reps))
  result = $(ps div 1000) & "." & $((ps mod 1000) div 100) & " ns"

proc benchmark() =
  let freq = cQpf()

  # One lock pair, uncontended, through the mod's lock -- the same
  # `aowlspt_lock.h` critical section the library's tables use, one instance
  # per translation unit. This is the number a "just lock the firing path"
  # design would add to every one of the paths below.
  var reps = 2_000_000
  var tA = cQpc()
  for i in 0 ..< reps:
    lockMod()
    unlockMod()
  var tB = cQpc()
  say "  lock pair      " & nsText(tB - tA, freq, reps) &
      "  (one CRITICAL_SECTION enter and leave, uncontended)"
  say "                 -- what a guarded read would cost, per firing"

  # One registration of each kind, so there is something to dispatch to.
  discard route("0.bench", rkStatic, r0)
  discard on("0.bench", e0)
  discard patch("0.bench", pkPrefix, p0, withArgs = true)
  discard patchTyped("0.bench", pkPrefix, t0)

  reps = 500_000
  tA = cQpc()
  for i in 0 ..< reps: cDispatchOne(3'i32, int32(cCount(3'i32) - 1))
  tB = cQpc()
  say "  typedPatch     " & nsText(tB - tA, freq, reps) &
      "  per firing (the game's thread; no allocation)"

  reps = 200_000
  tA = cQpc()
  for i in 0 ..< reps: cDispatchOne(2'i32, int32(cCount(2'i32) - 1))
  tB = cQpc()
  say "  patch (JSON)   " & nsText(tB - tA, freq, reps) &
      "  per firing (includes the harness's own check)"

  reps = 200_000
  tA = cQpc()
  for i in 0 ..< reps: cDispatchOne(0'i32, int32(cCount(0'i32) - 1))
  tB = cQpc()
  say "  route          " & nsText(tB - tA, freq, reps) & "  per request"

  reps = 200_000
  tA = cQpc()
  for i in 0 ..< reps: cDispatchOne(1'i32, int32(cCount(1'i32) - 1))
  tB = cQpc()
  say "  event          " & nsText(tB - tA, freq, reps) & "  per emit"

proc reportKind(k: int32; label: string) =
  let g = cGood(k)
  let b = cBad(k)
  if b == 0:
    ok("every one of the " & $g & " dispatches to " & label &
       " reached the handler its registration named")
  else:
    bad($b & " of " & $(g + b) & " dispatches to " & label &
        " reached the wrong handler, or were handed the wrong target name")

proc main(): int =
  var regs = 32
  var dispatch = 12
  var rounds = 2
  var per = 15
  var benchOnly = false
  var refuseEvery = 0
  var i = 1
  while i <= paramCount():
    let a = paramStr(i)
    if a == "--reg" and i < paramCount():
      inc i
      regs = intOf(paramStr(i), regs)
    elif a == "--dispatch" and i < paramCount():
      inc i
      dispatch = intOf(paramStr(i), dispatch)
    elif a == "--rounds" and i < paramCount():
      inc i
      rounds = intOf(paramStr(i), rounds)
    elif a == "--per" and i < paramCount():
      inc i
      per = intOf(paramStr(i), per)
    elif a == "--refuse-every" and i < paramCount():
      # Undocumented in the usage text on purpose: it exists to prove the
      # "reachable" check can fail, by making the harness refuse one typed
      # registration in N. Against the library as it stands it must change
      # nothing except the refusal count.
      inc i
      refuseEvery = intOf(paramStr(i), 0)
    elif a == "--bench":
      benchOnly = true
    elif a == "--help" or a == "-h":
      say Usage
      return 0
    else:
      say "unknown option: " & a
      return 1
    inc i

  if regs < 1: regs = 1
  # More registering threads than identities is allowed. Two threads sharing an
  # identity are invisible to the identity check -- and still caught by the
  # cookie check, which is why that one is stated separately.
  if regs > 48: regs = 48
  if dispatch < 1: dispatch = 1
  if rounds < 1: rounds = 1
  if per < 1: per = 1
  gPerThread = per

  say "regrace"
  say "-------"

  let hostPtr = cHostNew()
  let st = bindHost(cast[ptr HostApi](hostPtr), cast[ptr ModApi](cModApiPtr()))
  if st != Ok:
    say "error could not bind the harness host: status " & $st
    return 1
  ok "bound the harness host (records every registration, never refuses)"
  check(typedPatchesReady(),
        "the harness reports revision 4, so the typed table is exercised -- " &
        "it is the one read on the game's thread")
  if refuseEvery > 0:
    cSetRefuseEvery(int32(refuseEvery))
    say "  the harness will refuse one typed registration in " & $refuseEvery

  say "  threads   " & $regs & " registering, " & $dispatch & " dispatching"
  say "  work      " & $rounds & " rounds x " & $per &
      " registrations of each kind per thread"
  say ""

  # ------------------------------------------------------------------ #
  # Nothing racing, first.
  #
  # A concurrency test whose checks are wrong passes concurrently for the
  # wrong reason. These establish that the identities are distinct, that the
  # target string really does come from the registration, and that the
  # failure this whole file looks for is one this harness *can* report.
  # ------------------------------------------------------------------ #
  check(route("3.solo", rkStatic, r3) == Ok,
        "single-threaded: a route registers")
  cDispatchOne(0'i32, int32(cCount(0'i32) - 1))
  check(cGood(0'i32) == 1 and cBad(0'i32) == 0,
        "single-threaded: it answers with its own identity and no other")

  check(patch("5.solo", pkPrefix, p5, withArgs = true) == Ok,
        "single-threaded: a JSON patch registers")
  cDispatchOne(2'i32, int32(cCount(2'i32) - 1))
  check(cGood(2'i32) == 1 and cBad(2'i32) == 0,
        "single-threaded: it is handed the target its registration used, not " &
        "the one the firing carried")

  check(patchTyped("6.solo", pkPrefix, t6) == Ok,
        "single-threaded: a typed patch registers")
  cDispatchOne(3'i32, int32(cCount(3'i32) - 1))
  check(cGood(3'i32) == 1 and cBad(3'i32) == 0,
        "single-threaded: it recognises its own frame")

  # And the harness has to be able to say no. Dispatching the route slot with
  # the *patch* handler's identity expectation would be the same shape as the
  # bug; instead, prove the negative directly: register a second route under a
  # different identity and confirm the first still answers as itself.
  check(route("1.solo", rkStatic, r1) == Ok,
        "single-threaded: a second route, under a different identity")
  cDispatchOne(0'i32, 0'i32)
  cDispatchOne(0'i32, 1'i32)
  check(cGood(0'i32) == 3 and cBad(0'i32) == 0,
        "single-threaded: each of the two answers as itself -- identities are " &
        "distinct and the check would see them swapped")
  check(cDupCookies(0'i32) == 0,
        "single-threaded: the two routes were given different cookies")

  # The warm-up registered directly rather than through `regRoute` and friends,
  # so it is not in the counters the "reported Ok, recorded once" check reads.
  # Seeding them from the harness rather than excluding the warm-up keeps that
  # check counting *every* registration this process made -- and the seed is
  # only sound because the four checks immediately above have just proved the
  # warm-up's registrations are each present exactly once.
  withModLock:
    gOkRoute = int(cCount(0'i32))
    gOkEvent = int(cCount(1'i32))
    gOkJPatch = int(cCount(2'i32))
    gOkTPatch = int(cCount(3'i32))
  say ""

  if benchOnly:
    benchmark()
    return 0

  # ------------------------------------------------------------------ #
  # The rounds.
  #
  # Rounds rather than one long storm because the tables are bounded: the
  # whole point of the fix is that they are reserved once and never grow, so
  # a run cannot register for four seconds the way `tickrace` arms for four
  # seconds. What it can do is open the register-while-dispatching window
  # many times over, which is where the collision lives.
  # ------------------------------------------------------------------ #
  var lastRound = 0
  for r in 0 ..< rounds:
    lastRound = r
    cStart(int32(regs), int32(dispatch))
    cJoin()
    let dispatched = cGood(0'i32) + cGood(1'i32) + cGood(2'i32) + cGood(3'i32) +
                     cBad(0'i32) + cBad(1'i32) + cBad(2'i32) + cBad(3'i32)
    say "  round " & $(r + 1) & ": " & $cCount(0'i32) & " routes, " &
        $cCount(1'i32) & " events, " & $cCount(2'i32) & " patches, " &
        $cCount(3'i32) & " typed; " & $dispatched & " dispatches so far"
  say ""

  # ------------------------------------------------------------------ #
  # What the racing produced.
  # ------------------------------------------------------------------ #
  for k in 0 ..< 4:
    reportKind(int32(k), KindName[k])

  var dups = 0
  for k in 0 ..< 4: dups = dups + cDupCookies(int32(k))
  check(dups == 0,
        "no two live registrations share a cookie -- a duplicate is one " &
        "handler unreachable for the session (" & $dups & " found)")

  var badId = 0
  for k in 0 ..< 4: badId = badId + cBadIdentity(int32(k))
  check(badId == 0,
        "every registration reached the host under the name it was made with")

  check(cOverflow() == 0,
        "the harness's own tables never filled, so nothing was dropped on " &
        "its side")

  # Every registration the library said Ok to must be reachable. The harness
  # records one entry per Ok and never refuses, so these two numbers are the
  # same number counted on the two sides of the ABI.
  var okR = 0
  var okE = 0
  var okJ = 0
  var okT = 0
  withModLock:
    okR = gOkRoute
    okE = gOkEvent
    okJ = gOkJPatch
    okT = gOkTPatch
  check(int(cCount(0'i32)) == okR,
        "every route the library reported Ok was registered with the host: " &
        $okR & " reported, " & $cCount(0'i32) & " recorded")
  check(int(cCount(1'i32)) == okE,
        "every event subscription reported Ok was recorded: " & $okE &
        " reported, " & $cCount(1'i32) & " recorded")
  check(int(cCount(2'i32)) == okJ,
        "every JSON patch reported Ok was recorded: " & $okJ & " reported, " &
        $cCount(2'i32) & " recorded")
  check(int(cCount(3'i32)) == okT,
        "every typed patch reported Ok was recorded: " & $okT & " reported, " &
        $cCount(3'i32) & " recorded")

  # A slot the host refused is **parked, not recycled** -- so the library's own
  # count is the registrations it succeeded at plus the ones it was refused,
  # and the refusals are exactly the slots deliberately spent. That is the
  # arithmetic a mutation that gave the index back would break, and it is
  # written as a sum rather than as an equality so that the refusing mode and
  # the ordinary one are checked by the same line.
  let spent = int(cRefused())
  check(registeredRoutes() == okR and registeredEvents() == okE and
        registeredPatches() == okJ and registeredTypedPatches() == okT + spent,
        "the library's own slot counts agree with what it handed the host: " &
        $registeredRoutes() & "/" & $registeredEvents() & "/" &
        $registeredPatches() & "/" & $registeredTypedPatches() &
        " against " & $okR & "/" & $okE & "/" & $okJ & "/" & $okT &
        " Ok plus " & $spent & " refused and parked")

  # And the sweep: every recorded registration, dispatched once, checked. The
  # racing dispatchers walk in strides and need not have reached every entry;
  # this one leaves nothing out.
  let beforeSweep = cBad(0'i32) + cBad(1'i32) + cBad(2'i32) + cBad(3'i32)
  let swept = cSweep()
  let afterSweep = cBad(0'i32) + cBad(1'i32) + cBad(2'i32) + cBad(3'i32)
  check(afterSweep == beforeSweep,
        "sweeping all " & $swept & " registrations once each, every one " &
        "reached its own handler")

  say ""

  # ------------------------------------------------------------------ #
  # The bound, which is what this design costs and therefore has to work.
  # ------------------------------------------------------------------ #
  let usedBefore = registeredRoutes()
  var refusedAt = -1
  var n = usedBefore
  while n < RouteCapacity + 4:
    if route("0.fill" & $n, rkStatic, r0) != Ok:
      refusedAt = n
      break
    inc n
  check(refusedAt == RouteCapacity,
        "the " & $(RouteCapacity + 1) & "th route is refused rather than " &
        "written past the end of the table (refused at " & $refusedAt & ")")
  check(registeredRoutes() == RouteCapacity,
        "a refused registration takes no slot")
  check(route("0.past", rkStatic, r0) == ErrGeneric,
        "and it keeps refusing, with a status a mod can act on")
  # The table is full, so the last thing to prove is that a full table still
  # answers correctly for everything already in it.
  let badBeforeFull = cBad(0'i32)
  cDispatchOne(0'i32, 0'i32)
  cDispatchOne(0'i32, int32(cCount(0'i32) - 1))
  check(cBad(0'i32) == badBeforeFull,
        "a full table still dispatches correctly to what is in it")

  if refuseEvery > 0:
    say ""
    say "  the harness refused " & $cRefused() & " typed registration(s)"

  say ""
  benchmark()
  say ""

  if failures == 0:
    say "regrace: all checks passed (" & $(lastRound + 1) & " rounds)"
    return 0
  say "regrace: " & $failures & " check(s) failed"
  return 1

quit(main())
