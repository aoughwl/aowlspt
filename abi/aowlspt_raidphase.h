/* aowlspt_raidphase.h -- THE PRICE OF THE ONE UNCONDITIONAL RIDER.
 *
 * WHY THIS FILE EXISTS. `rpDrainTick` is the only per-frame rider on
 * `TarkovApplication::Update` that touches the game with NO feature flag in
 * front of it (it self-disables only after RpMaxFaults). Every other rider can
 * be bisected away by turning its flag off; this one cannot, so in four
 * performance bisects it was silently present in every arm and in none of the
 * budgets. It had never been measured. This file measures it.
 *
 * THE CLOCK. QueryPerformanceCounter, through the same two helpers used by both
 * the real bracket and the POSITIVE CONTROL, so the control cannot accidentally
 * be timed by a different mechanism than the thing it controls for. That is the
 * entire point of a control. Modelled on `aowlspt_natesp.h`, deliberately: the
 * two meters must be directly comparable, because they bracket work in the same
 * drain on the same frame.
 *
 * NO SENTINEL IS EVER PRINTED AS A NUMBER. The edge table is entirely FINITE.
 * Samples above the top finite edge go to a separate overflow counter, never to
 * a bucket carrying a printable edge; if the 95th sample lands there,
 * `p95_ns` returns AOWL_RP_P95_SAT (NEGATIVE, so no formatting path can render
 * it as a duration) and the caller is REQUIRED to say "saturated, INCONCLUSIVE".
 * This is the same defect natesp printed once as `9223372036854775.8us`
 * (INT64_MAX/1000) and it is designed out here rather than avoided by care.
 *
 * ALL UNITS ARE NANOSECONDS internally and are formatted, and explicitly
 * LABELLED, as MICROSECONDS by the caller. natesp's sub-means were misread as
 * nanoseconds once and cost an agent a wasted investigation; every line this
 * meter feeds spells its unit.
 *
 * SAFETY. This file touches no game memory, resolves no address, installs no
 * detour and allocates nothing. It is statics plus QPC. It opens no SEH guard:
 * `rpDrainTick` already holds exactly one and `aowl_p_p_seh` is not re-entrant.
 */
#ifndef AOWLSPT_RAIDPHASE_H
#define AOWLSPT_RAIDPHASE_H

/* ---- PHASES: disjoint and exhaustive over ticks -------------------------
 * Every tick either ran the ~1/s SceneManager query or did not. Folding the
 * two into one mean hides the whole cost of the expensive tick inside sixty
 * cheap ones -- which is precisely the shape of hole that hid 11.4ms for a
 * session. So they are counted apart, and every tick lands in exactly one. */
#define AOWL_RP_PH_LIGHT 0   /* no scene query this tick */
#define AOWL_RP_PH_SCENE 1   /* the scene-name query ran this tick */
#define AOWL_RP_PH_N     2

/* ---- SUB-BRACKETS: disjoint, and their sum is REPORTED against the whole -
 * SCENE + CAM + WORLD are the three things the body does. Whatever is left is
 * bookkeeping. The caller prints `accounted=X of Y us (Z%)`; a decomposition
 * that does not sum to the whole is a hole, and the only way to see the hole is
 * to print the identity. */
#define AOWL_RP_SUB_SCENE 0  /* S4 iSceneNamePresent */
#define AOWL_RP_SUB_CAM   1  /* S5 Camera.main */
#define AOWL_RP_SUB_WORLD 2  /* S1/S2/S3 the GameWorld + alive-list walk */
#define AOWL_RP_SUB_N     3

/* A per-frame rider with no flag in front of it should not cost a tenth of a
 * 16.6ms frame. 250us is the same generous ceiling natesp uses, so the two
 * verdicts mean the same thing. */
#define AOWL_RP_BUDGET_NS   250000LL
/* Below this many samples the verdict is INCONCLUSIVE, never PASS. "I could
 * not look" is not a pass. */
#define AOWL_RP_MIN_SAMPLES 120

#define AOWL_RP_NB 19
static const int64_t g_rp_edge[AOWL_RP_NB] = {
    1000LL, 2000LL, 5000LL, 10000LL, 20000LL, 50000LL, 100000LL,
    250000LL, 500000LL, 1000000LL, 2000000LL, 5000000LL, 10000000LL,
    20000000LL, 50000000LL, 100000000LL, 250000000LL, 500000000LL,
    1000000000LL };
#define AOWL_RP_P95_SAT (-2LL)

typedef struct {
    int64_t n, sum, max, over;
    int64_t h[AOWL_RP_NB];
    int64_t ovf;                 /* samples ABOVE the top finite edge */
} aowl_rp_bucket;

static aowl_rp_bucket g_rp_cost[AOWL_RP_PH_N];
static aowl_rp_bucket g_rp_sub[AOWL_RP_SUB_N];
static aowl_rp_bucket g_rp_gap;              /* tick-to-tick interval */
static aowl_rp_bucket g_rp_acc;              /* per-tick accounted sum */
static aowl_rp_bucket g_rp_ctrl_out;         /* POSITIVE CONTROL, out of guard */
static aowl_rp_bucket g_rp_ctrl_in;          /* POSITIVE CONTROL, in guard */

static int64_t g_rp_qpf      = 0;
static int64_t g_rp_cost_t0  = 0;
static int64_t g_rp_prev_t0  = 0;
static int64_t g_rp_acc_cur  = 0;
static int64_t g_rp_sub_t0[AOWL_RP_SUB_N];
static int     g_rp_phase    = AOWL_RP_PH_LIGHT;
static int64_t g_rp_dropped  = 0;            /* samples refused as absurd */

/* ---- THE ONE CLOCK ---------------------------------------------------- */
static int64_t aowl_rp_qpc(void) {
    LARGE_INTEGER v;
    if (!g_rp_qpf) { LARGE_INTEGER f; QueryPerformanceFrequency(&f);
                     g_rp_qpf = (int64_t)f.QuadPart; }
    QueryPerformanceCounter(&v);
    return (int64_t)v.QuadPart;
}
static int64_t aowl_rp_elapsed_ns(int64_t t0) {
    if (g_rp_qpf <= 0) return -1;
    return ((aowl_rp_qpc() - t0) * 1000000000LL) / g_rp_qpf;
}

static void aowl_rp_bucket_add(aowl_rp_bucket* b, int64_t ns) {
    int i;
    b->n++; b->sum += ns;
    if (ns > b->max) b->max = ns;
    if (ns > AOWL_RP_BUDGET_NS) b->over++;
    for (i = 0; i < AOWL_RP_NB; i++) {
        if (ns <= g_rp_edge[i]) { b->h[i]++; return; }
    }
    b->ovf++;
}

/* ---- THE POSITIVE CONTROL ----------------------------------------------
 *
 * THE QUESTION IT SETTLES. If this meter reports a large number, exactly two
 * explanations survive and no amount of reading the body distinguishes them:
 *
 *   (A) the BRACKET is wrong -- something between begin and end blocks on the
 *       frame (a VSync wait, a render join, the drain not being invoked where
 *       we think), so the number describes the GAME, not us;
 *   (B) the COST is real.
 *
 * So: bracket KNOWN-TRIVIAL work with the SAME clock helpers in the SAME place
 * in the tick. 512 integer adds into a volatile sink -- it cannot be optimised
 * away and it touches no pointer, no game memory and no managed heap.
 *
 * READING IT is mechanical, with no judgement call:
 *   ctrl in the tens of ms         -> (A). The bracket measures the frame; any
 *                                    verdict from it is an artifact.
 *   ctrl in single-digit us while
 *     the body is ms               -> (B). The cost is real; read the sub-lines.
 *   ctrl_out cheap, ctrl_in dear   -> SEH guard ENTRY is the cost. Neither of
 *                                    the above, and it would be new.
 *
 * In natesp this control priced trivial work at 0.1us while the body reported
 * 14460.8us -- which is what proved that cost real. */
static volatile int64_t g_rp_ctrl_sink = 0;
static void aowl_rp_ctrl_run(aowl_rp_bucket* into) {
    int64_t t0 = aowl_rp_qpc();
    int64_t acc = 0, ns;
    int i;
    for (i = 0; i < 512; i++) acc += (int64_t)i;
    g_rp_ctrl_sink = acc;
    ns = aowl_rp_elapsed_ns(t0);
    if (ns < 0 || ns > 10000000000LL) return;
    aowl_rp_bucket_add(into, ns);
}
static void aowl_rp_ctrl_out(void) { aowl_rp_ctrl_run(&g_rp_ctrl_out); }
static void aowl_rp_ctrl_in(void)  { aowl_rp_ctrl_run(&g_rp_ctrl_in);  }
static int64_t aowl_rp_ctrl_mean_ns(int32_t which) {
    aowl_rp_bucket* b = which ? &g_rp_ctrl_in : &g_rp_ctrl_out;
    if (b->n <= 0) return -1;
    return b->sum / b->n;
}
static int64_t aowl_rp_ctrl_max_ns(int32_t which) {
    aowl_rp_bucket* b = which ? &g_rp_ctrl_in : &g_rp_ctrl_out;
    return b->max;
}
static int64_t aowl_rp_ctrl_samples(int32_t which) {
    aowl_rp_bucket* b = which ? &g_rp_ctrl_in : &g_rp_ctrl_out;
    return b->n;
}

/* ---- THE REAL BRACKET --------------------------------------------------- */
static void aowl_rp_cost_begin(void) {
    int64_t q = aowl_rp_qpc();
    int i;
    if (g_rp_prev_t0 && g_rp_qpf > 0) {
        int64_t d = q - g_rp_prev_t0;
        if (d > 0 && d < g_rp_qpf * 10)
            aowl_rp_bucket_add(&g_rp_gap, (d * 1000000000LL) / g_rp_qpf);
    }
    g_rp_prev_t0 = q;
    g_rp_cost_t0 = q;
    g_rp_acc_cur = 0;                 /* the accounting identity is PER TICK */
    g_rp_phase   = AOWL_RP_PH_LIGHT;  /* the body promotes to SCENE if it queries */
    for (i = 0; i < AOWL_RP_SUB_N; i++) g_rp_sub_t0[i] = 0;
}

static void aowl_rp_phase_scene(void) { g_rp_phase = AOWL_RP_PH_SCENE; }

static void aowl_rp_sub_begin(int32_t s) {
    if (s < 0 || s >= AOWL_RP_SUB_N) return;
    g_rp_sub_t0[s] = aowl_rp_qpc();
}
static void aowl_rp_sub_end(int32_t s) {
    int64_t ns;
    if (s < 0 || s >= AOWL_RP_SUB_N || !g_rp_sub_t0[s]) return;
    ns = aowl_rp_elapsed_ns(g_rp_sub_t0[s]);
    g_rp_sub_t0[s] = 0;
    if (ns < 0 || ns > 10000000000LL) return;
    aowl_rp_bucket_add(&g_rp_sub[s], ns);
    g_rp_acc_cur += ns;               /* disjoint: no sub encloses another */
}

static void aowl_rp_cost_end(void) {
    int64_t ns;
    if (!g_rp_cost_t0) return;
    ns = aowl_rp_elapsed_ns(g_rp_cost_t0);
    g_rp_cost_t0 = 0;
    /* A sample that is negative or absurd is DROPPED AND COUNTED, never
     * folded into a mean where it would be indistinguishable from work. */
    if (ns < 0 || ns > 10000000000LL) { g_rp_dropped++; return; }
    aowl_rp_bucket_add(&g_rp_cost[g_rp_phase], ns);
    if (g_rp_acc_cur >= 0 && g_rp_acc_cur <= ns)
        aowl_rp_bucket_add(&g_rp_acc, g_rp_acc_cur);
    else
        g_rp_dropped++;   /* subs summed to more than the whole: not reported */
}

/* ---- READOUT ------------------------------------------------------------ */
static int64_t aowl_rp_cost_mean_ns(int32_t ph) {
    if (ph < 0 || ph >= AOWL_RP_PH_N || g_rp_cost[ph].n <= 0) return -1;
    return g_rp_cost[ph].sum / g_rp_cost[ph].n;
}
static int64_t aowl_rp_cost_max_ns(int32_t ph) {
    if (ph < 0 || ph >= AOWL_RP_PH_N) return -1;
    return g_rp_cost[ph].max;
}
static int64_t aowl_rp_cost_n(int32_t ph) {
    if (ph < 0 || ph >= AOWL_RP_PH_N) return 0;
    return g_rp_cost[ph].n;
}
static int64_t aowl_rp_cost_over(int32_t ph) {
    if (ph < 0 || ph >= AOWL_RP_PH_N) return 0;
    return g_rp_cost[ph].over;
}
static int64_t aowl_rp_cost_ovf(int32_t ph) {
    if (ph < 0 || ph >= AOWL_RP_PH_N) return 0;
    return g_rp_cost[ph].ovf;
}
/* THREE RETURNS, never two: a real UPPER-BOUND edge, -1 for "no samples", and
 * AOWL_RP_P95_SAT for "the 95th sample is above the top finite edge". */
static int64_t aowl_rp_cost_p95_ns(int32_t ph) {
    int64_t want, seen = 0; int i;
    if (ph < 0 || ph >= AOWL_RP_PH_N || g_rp_cost[ph].n <= 0) return -1;
    want = (g_rp_cost[ph].n * 95 + 99) / 100;
    for (i = 0; i < AOWL_RP_NB; i++) {
        seen += g_rp_cost[ph].h[i];
        if (seen >= want) return g_rp_edge[i];
    }
    return AOWL_RP_P95_SAT;
}
static int64_t aowl_rp_p95_sat(void)    { return AOWL_RP_P95_SAT; }
static int64_t aowl_rp_top_edge_ns(void){ return g_rp_edge[AOWL_RP_NB - 1]; }
static int64_t aowl_rp_budget_ns(void)  { return AOWL_RP_BUDGET_NS; }
static int64_t aowl_rp_min_samples(void){ return AOWL_RP_MIN_SAMPLES; }

static int64_t aowl_rp_sub_mean_ns(int32_t s) {
    if (s < 0 || s >= AOWL_RP_SUB_N || g_rp_sub[s].n <= 0) return -1;
    return g_rp_sub[s].sum / g_rp_sub[s].n;
}
static int64_t aowl_rp_sub_max_ns(int32_t s) {
    if (s < 0 || s >= AOWL_RP_SUB_N) return -1;
    return g_rp_sub[s].max;
}
static int64_t aowl_rp_sub_n(int32_t s) {
    if (s < 0 || s >= AOWL_RP_SUB_N) return 0;
    return g_rp_sub[s].n;
}
static const char* aowl_rp_sub_name(int32_t s) {
    switch (s) {
    case AOWL_RP_SUB_SCENE: return "scene(S4)";
    case AOWL_RP_SUB_CAM:   return "camera(S5)";
    case AOWL_RP_SUB_WORLD: return "world(S1/S2/S3)";
    default: return "?";
    }
}
static int32_t aowl_rp_sub_count(void) { return AOWL_RP_SUB_N; }

static int64_t aowl_rp_acc_mean_ns(void) {
    if (g_rp_acc.n <= 0) return -1;
    return g_rp_acc.sum / g_rp_acc.n;
}
static int64_t aowl_rp_acc_n(void)     { return g_rp_acc.n; }
static int64_t aowl_rp_gap_mean_ns(void) {
    if (g_rp_gap.n <= 0) return -1;
    return g_rp_gap.sum / g_rp_gap.n;
}
static int64_t aowl_rp_gap_n(void)     { return g_rp_gap.n; }
static int64_t aowl_rp_dropped(void)   { return g_rp_dropped; }

#endif /* AOWLSPT_RAIDPHASE_H */
