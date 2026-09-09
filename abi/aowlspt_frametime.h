/* aowlspt_frametime.h -- THE FRAME METER. A frame-interval instrument that
 * depends on NOTHING under test.
 *
 * WHY THIS EXISTS, measured. The client runs at ~9-10 fps in raid (110ms/frame
 * from the maps mod's frame counter; 100.7ms independently from natesp's own
 * gap counter) while the menu is ~37 fps. The obvious next step -- turn host
 * features off one at a time and watch the number -- was attempted twice and
 * BOTH attempts measured nothing, because every frame counter in the host lives
 * inside a feature:
 *
 *   attempt 1: 27 features off -> no frame data at all (the counters live in
 *              natEspDiag and the maps diag; the instruments were disabled with
 *              the subject).
 *   attempt 2: natEsp off but natEspDiag on -> "the pane renderer has not run
 *              yet (0 calls)", and no `raid phase =` line at all, because the
 *              raid-phase latch is driven from the ESP path and the maps HUD
 *              only draws once that latch reads DEPLOYED.
 *
 * So frame instrumentation was TRANSITIVELY GATED on `natEsp`, and the one
 * experiment that matters -- what is the frame rate with the ESP off -- was
 * impossible to run. That is the gap this file closes.
 *
 * WHAT IT HOOKS, and why that is independent of every feature. Exactly one
 * thing: `aowl_ft_tick()`, called from the FIRST statement of the
 * `i == gDrainSlot` branch of `patchFired` -- the host's own
 * `EFT.TarkovApplication::Update` drain, before `mainDrain()` and before every
 * rider. That drain is bound by the host bridge itself (`gDrainSlot`), not by
 * any feature flag; it ticks for the whole session, menu and raid alike; and it
 * is the same anchor every feature rides, so the interval it measures IS the
 * interval those features are charged against. It installs NO detour, resolves
 * NO name, and calls NOTHING in the game.
 *
 * IT CANNOT FAULT, so it arms no SEH guard -- deliberately. Its entire working
 * set is the statics in this file plus `QueryPerformanceCounter`. It
 * dereferences no game pointer, allocates nothing (managed or otherwise) and
 * takes no lock. `aowl_p_p_seh` is not re-entrant, and the drain branch it is
 * called from is not inside one, so a guard here would buy nothing and could
 * only mislead a later reader into thinking a guard is required at that call
 * site. The steady-state cost is one QPC read, one 64-bit divide and ~20
 * integer ops -- tens of nanoseconds against a 110,000,000ns frame.
 *
 * WHAT IT REPORTS: mean, p50, p95, max, a histogram and the SAMPLE COUNT, over
 * two windows -- LIFETIME (every tick since the flag came on) and RECENT (the
 * last AOWL_FT_RING intervals, re-bucketed on demand at report time so a reader
 * looking at the log during a raid gets the raid's number even though the
 * lifetime figure folds the menu in).
 *
 * IT DOES NOT DISTINGUISH MENU FROM RAID, and says so in its own line. The only
 * feature-free menu/raid signals available on this build are the raid-phase
 * latch (driven from the ESP path -- the exact dependency this file exists to
 * escape) and `EFT.UI.PreloaderUI::Update` (menu-only, but every rider slot on
 * it is flag-gated, so with all features off it never fires). Inventing a third
 * would mean resolving something new. The RECENT window is the honest
 * substitute: it is a time-local number a human can read at a known moment.
 *
 * NO SENTINEL IS EVER PRINTED AS A NUMBER. The predecessor meter printed
 * INT64_MAX/1000 as a "p95" -- a saturation rendered as a measurement, which is
 * a confidently wrong diagnostic. Here the edge table is entirely FINITE and
 * reaches 2s; samples above the top edge go to a separate overflow counter; and
 * a percentile that lands there returns AOWL_FT_PCT_SAT, which is NEGATIVE
 * precisely so no formatting path can mistake it for a duration. Three returns,
 * never two: a real edge, -1 for "no samples", or the saturation marker.
 *
 * THREE OUTCOMES ON THE COUNT, never two. Below AOWL_FT_MIN_N samples the
 * caller is required to say INCONCLUSIVE. "Not enough samples" is not a pass.
 * There is deliberately NO budget and NO PASS/FAIL on the frame rate itself:
 * what counts as an acceptable frame time is the human's call, not the meter's.
 */
#ifndef AOWLSPT_FRAMETIME_H
#define AOWLSPT_FRAMETIME_H

#include <stdint.h>
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

/* Histogram edges, ns. Entirely finite, and chosen so the interesting region
 * for THIS investigation (a 27ms 37fps menu frame against a 110ms raid frame)
 * is resolved rather than collapsed into one bucket. */
#define AOWL_FT_NB 16
static const int64_t g_ft_edge[AOWL_FT_NB] = {
    1000000LL,    2000000LL,   4000000LL,   8000000LL,   12000000LL,
    16700000LL,   20000000LL,  25000000LL,  33400000LL,  50000000LL,
    66700000LL,   100000000LL, 150000000LL, 250000000LL, 500000000LL,
    2000000000LL };

/* Returned by the percentile helpers when the wanted sample sits in the
 * overflow counter. NEGATIVE on purpose -- see the header comment. */
#define AOWL_FT_PCT_SAT (-2LL)

/* Below this many samples, the verdict is INCONCLUSIVE. At ~10fps this is 12
 * seconds of raid; at 60fps it is two seconds. */
#define AOWL_FT_MIN_N 120

/* The recent window. 512 intervals is ~51s at 10fps and ~8.5s at 60fps -- long
 * enough to be stable, short enough to be time-local. */
#define AOWL_FT_RING 512

typedef struct {
    int64_t n, sum, max, min;
    int64_t h[AOWL_FT_NB];
    int64_t ovf;                 /* samples ABOVE the top finite edge */
} aowl_ft_bucket;

static aowl_ft_bucket g_ft_life;
static int64_t g_ft_ring[AOWL_FT_RING];
static int32_t g_ft_ring_head = 0;
static int64_t g_ft_ring_n    = 0;   /* total pushed; window is min(n, RING) */

static int64_t g_ft_qpf   = 0;
static int64_t g_ft_prev  = 0;
static int64_t g_ft_ticks = 0;       /* every call, including the first */
static int64_t g_ft_dropped = 0;     /* intervals refused as absurd */
static int32_t g_ft_on    = 0;

static void aowl_ft_bucket_add(aowl_ft_bucket* b, int64_t ns) {
    int i;
    b->n++; b->sum += ns;
    if (ns > b->max) b->max = ns;
    if (b->min == 0 || ns < b->min) b->min = ns;
    for (i = 0; i < AOWL_FT_NB; i++) {
        if (ns <= g_ft_edge[i]) { b->h[i]++; return; }
    }
    b->ovf++;
}

static int64_t aowl_ft_pct(const aowl_ft_bucket* b, int64_t pct) {
    int64_t want, seen = 0; int i;
    if (b->n <= 0) return -1;
    want = (b->n * pct + 99) / 100;
    for (i = 0; i < AOWL_FT_NB; i++) {
        seen += b->h[i];
        if (seen >= want) return g_ft_edge[i];
    }
    return AOWL_FT_PCT_SAT;
}

/* ---- THE TICK ---------------------------------------------------------
 * One QPC read, one divide, one bucket file, one ring store. Nothing else.
 * Called once per `TarkovApplication::Update` drain. */
static void aowl_ft_tick(void) {
    LARGE_INTEGER v;
    int64_t q, d, ns;
    if (!g_ft_on) return;
    if (!g_ft_qpf) {
        LARGE_INTEGER f;
        if (!QueryPerformanceFrequency(&f) || f.QuadPart <= 0) return;
        g_ft_qpf = (int64_t)f.QuadPart;
    }
    QueryPerformanceCounter(&v);
    q = (int64_t)v.QuadPart;
    g_ft_ticks++;
    if (g_ft_prev) {
        d = q - g_ft_prev;
        /* Refuse the absurd rather than let it move a mean: a negative delta
         * (counter went backwards) or anything over 10 seconds (a load screen,
         * a breakpoint, a suspended process) is COUNTED as dropped, never
         * silently discarded. */
        if (d > 0 && d < g_ft_qpf * 10) {
            ns = (d * 1000000000LL) / g_ft_qpf;
            aowl_ft_bucket_add(&g_ft_life, ns);
            g_ft_ring[g_ft_ring_head] = ns;
            g_ft_ring_head = (g_ft_ring_head + 1) % AOWL_FT_RING;
            g_ft_ring_n++;
        } else {
            g_ft_dropped++;
        }
    }
    g_ft_prev = q;
}

static void aowl_ft_set_enabled(int32_t on) {
    /* Turning it on mid-session must not manufacture one enormous interval out
     * of the gap while it was off. */
    if (on && !g_ft_on) g_ft_prev = 0;
    g_ft_on = on ? 1 : 0;
}
static int32_t aowl_ft_enabled(void) { return g_ft_on; }

/* ---- READOUT: LIFETIME ------------------------------------------------- */
static int64_t aowl_ft_samples(void)  { return g_ft_life.n; }
static int64_t aowl_ft_ticks_seen(void) { return g_ft_ticks; }
static int64_t aowl_ft_dropped(void)  { return g_ft_dropped; }
static int64_t aowl_ft_mean_ns(void) {
    if (g_ft_life.n <= 0) return -1;
    return g_ft_life.sum / g_ft_life.n;
}
static int64_t aowl_ft_p50_ns(void)   { return aowl_ft_pct(&g_ft_life, 50); }
static int64_t aowl_ft_p95_ns(void)   { return aowl_ft_pct(&g_ft_life, 95); }
static int64_t aowl_ft_max_ns(void)   { return g_ft_life.max; }
static int64_t aowl_ft_min_ns(void)   { return g_ft_life.min; }
static int64_t aowl_ft_hist(int32_t i) {
    if (i < 0 || i >= AOWL_FT_NB) return 0;
    return g_ft_life.h[i];
}
static int64_t aowl_ft_ovf(void)      { return g_ft_life.ovf; }

/* ---- READOUT: RECENT WINDOW -------------------------------------------
 * Re-bucketed on demand from the ring, at report time only (<=512 iterations,
 * once every few seconds, off the per-frame path entirely). `aowl_ft_recent`
 * MUST be called before any of the recent getters; it returns the window size
 * so the caller can refuse rather than read a stale window. */
static aowl_ft_bucket g_ft_recent;
static int64_t aowl_ft_recent(void) {
    int64_t win, i, idx;
    int j;
    g_ft_recent.n = 0; g_ft_recent.sum = 0;
    g_ft_recent.max = 0; g_ft_recent.min = 0; g_ft_recent.ovf = 0;
    for (j = 0; j < AOWL_FT_NB; j++) g_ft_recent.h[j] = 0;
    win = g_ft_ring_n < (int64_t)AOWL_FT_RING ? g_ft_ring_n
                                              : (int64_t)AOWL_FT_RING;
    for (i = 0; i < win; i++) {
        idx = ((int64_t)g_ft_ring_head - 1 - i + 2 * (int64_t)AOWL_FT_RING)
              % (int64_t)AOWL_FT_RING;
        aowl_ft_bucket_add(&g_ft_recent, g_ft_ring[idx]);
    }
    return g_ft_recent.n;
}
static int64_t aowl_ft_r_mean_ns(void) {
    if (g_ft_recent.n <= 0) return -1;
    return g_ft_recent.sum / g_ft_recent.n;
}
static int64_t aowl_ft_r_p50_ns(void) { return aowl_ft_pct(&g_ft_recent, 50); }
static int64_t aowl_ft_r_p95_ns(void) { return aowl_ft_pct(&g_ft_recent, 95); }
static int64_t aowl_ft_r_max_ns(void) { return g_ft_recent.max; }
static int64_t aowl_ft_r_samples(void){ return g_ft_recent.n; }

/* ---- CONSTANTS the caller needs to format honestly --------------------- */
static int64_t aowl_ft_pct_sat(void)   { return AOWL_FT_PCT_SAT; }
static int64_t aowl_ft_top_edge(void)  { return g_ft_edge[AOWL_FT_NB - 1]; }
static int32_t aowl_ft_bins(void)      { return AOWL_FT_NB; }
static int64_t aowl_ft_edge(int32_t i) {
    if (i < 0 || i >= AOWL_FT_NB) return -1;
    return g_ft_edge[i];
}
static int64_t aowl_ft_min_samples(void) { return AOWL_FT_MIN_N; }
static int32_t aowl_ft_ring_size(void)   { return AOWL_FT_RING; }

#endif /* AOWLSPT_FRAMETIME_H */
