/* aowlspt_splprof.h -- THE PHASE METER FOR `splRebrandDrain`, and nothing else.
 *
 * WHY IT EXISTS. The drain profiler priced the whole rider at
 * `splRebrandDrain = 1152.2us/frame (2.9% of frame, 5765 calls, max 194373.3us)`.
 * A 194 MILLISECOND single call inside a rider whose own walk carries an 18ms
 * slice means the stall is in a phase the slice does not cover. One row cannot
 * say which. This adds the DISJOINT, EXHAUSTIVE decomposition of that one row.
 *
 * WHAT IT HOOKS: NOTHING. It is a pair of QPC reads around statements that
 * already run. No detour, no name resolved, no game pointer dereferenced, no
 * guard opened -- so it cannot nest inside `aowl_p_p_seh`. The TOTAL bracket
 * sits in `splRebrandDrainTick`, strictly OUTSIDE `cSplTickGuarded`; every
 * phase bracket sits INSIDE the already-open guard and opens none of its own.
 *
 * GATING. Active only while the drain profiler itself is on (`aowl_dp_enabled`).
 * It adds no flag, and with `drainProfiler` off every entry point here is a
 * single predicted compare and a return.
 *
 * UNITS. Every number this file produces is NANOSECONDS internally and is
 * printed as MICROSECONDS with `us` attached by the Nim side. There is no
 * unitless duration anywhere in its output.
 *
 * HONESTY RULES, all of them learned by getting this wrong:
 *
 *  1. DISJOINT AND EXHAUSTIVE. The phases partition the guarded body. The
 *     reporter prints `accounted=X of Y us (Z%)` and then an explicit
 *     `UNEXPLAINED` line for the remainder. The remainder is never folded into
 *     a phase and never quietly dropped.
 *  2. A POSITIVE CONTROL, on the same clock, through the same bracket. Without
 *     it "the meter is lying" cannot be ruled out.
 *  3. NEVER PRINT A SENTINEL AS A VALUE. `-1` means "not measured" and the Nim
 *     side renders it `n/a`.
 *  4. "NEVER RAN" IS NOT "CHEAP". Every phase carries a call count, and a phase
 *     with zero calls is reported as `never ran`, never as `0.0us`.
 *  5. THE TAIL IS A SEPARATE QUESTION FROM THE MEAN. A 1.15ms mean with a 194ms
 *     max is mostly-idle-occasionally-catastrophic, so this counts calls over
 *     an explicit threshold AND records which phase dominated each of them.
 */

#ifndef AOWLSPT_SPLPROF_H
#define AOWLSPT_SPLPROF_H

/* Requires aowlspt_drainprof.h (aowl_dp_enabled / QPC frequency). */

/* The phases PARTITION the guarded body: disjoint, and together exhaustive up
 * to the UNEXPLAINED remainder the reporter always prints. CONTROL is not part
 * of the partition -- it is the honesty probe.
 *
 * MAINT used to be ONE slot and measured 576.5us/call over 4400 calls (36.3% of
 * the whole) in the 146412a run. One number over four independent jobs cannot
 * say which of them costs that, so it is now split into three disjoint slots.
 * DESCEND, likewise, measured 23578.8us/call over 113 calls (38.1%) while the
 * code that calls it described it as "cheap"; CHEAPHUNT separates the per-frame
 * tier-1 descent from the throttled wide one so that claim is falsifiable. */
#define AOWL_SP_PRE       0   /* liveness + staleness checks before discovery */
#define AOWL_SP_ROOTS     1   /* scene-root enumeration inside splFindScreen   */
#define AOWL_SP_DESCEND   2   /* splFindByName under the WIDE (throttled) walk  */
#define AOWL_SP_CHEAP     3   /* splFindByName under the tier-1 cached UI root  */
#define AOWL_SP_SCAN      4   /* splScanNode: the by-text scan in the screen   */
#define AOWL_SP_MHEAD     5   /* splMaintain: heading + description re-assert  */
#define AOWL_SP_MTOG      6   /* splMaintain: practice toggle force + hide     */
#define AOWL_SP_MWARN     7   /* splMaintain: co-op warning hide               */
#define AOWL_SP_DIAG      8   /* diagnostics + summary string building         */
#define AOWL_SP_CTRL      9   /* THE POSITIVE CONTROL                          */
#define AOWL_SP_SLOTS     10

/* The tail threshold. A call over this is a frame the player felt. */
#define AOWL_SP_SLOW_NS   10000000LL   /* 10 ms */
#define AOWL_SP_CTRL_ITERS 512

static int64_t g_sp_ns[AOWL_SP_SLOTS];
static int64_t g_sp_calls[AOWL_SP_SLOTS];
static int64_t g_sp_max_ns[AOWL_SP_SLOTS];
/* Samples that measured EXACTLY zero nanoseconds -- i.e. below the QPC tick
 * (100 ns on a 10 MHz counter). Splitting a phase into sub-phases makes this
 * reachable, and a bucket that is mostly sub-tick samples is "too small for
 * this clock", which is NOT the same claim as "cheap" and must not print as a
 * plain 0.0us. Rule 4, one level down. */
static int64_t g_sp_subtick[AOWL_SP_SLOTS];
static int64_t g_sp_total_ns = 0;      /* the WHOLE guarded call, outer bracket */
static int64_t g_sp_total_calls = 0;
static int64_t g_sp_total_max_ns = 0;
static int64_t g_sp_slow_calls = 0;    /* calls over AOWL_SP_SLOW_NS            */
static int64_t g_sp_slow_ns = 0;       /* time spent in those calls             */
static int64_t g_sp_slow_by[AOWL_SP_SLOTS]; /* which phase dominated each slow call */
static int64_t g_sp_slow_unexplained = 0;   /* slow calls no phase dominated    */
static int64_t g_sp_dropped = 0;
static volatile int64_t g_sp_sink = 0;

/* Per-call scratch: the phase totals of the CALL currently being timed, so the
 * dominating phase of a slow call can be named. Reset by aowl_sp_call_begin. */
static int64_t g_sp_cur[AOWL_SP_SLOTS];

static int64_t aowl_sp_now(void) {
    LARGE_INTEGER v;
    if (!aowl_dp_enabled()) return 0;
    QueryPerformanceCounter(&v);
    return (int64_t)v.QuadPart;
}

/* Returns the elapsed nanoseconds, or -1 if it could not be measured. Never
 * returns 0 for "unmeasured" -- 0 reads as "free" and that is rule 4. */
static int64_t aowl_sp_delta_ns(int64_t t0) {
    LARGE_INTEGER v;
    int64_t d;
    if (!aowl_dp_enabled() || !t0) return -1;
    if (!aowl_dp_init_qpf()) return -1;
    QueryPerformanceCounter(&v);
    d = (int64_t)v.QuadPart - t0;
    if (d < 0 || d > g_dp_qpf * 10) { g_sp_dropped++; return -1; }
    return (d * 1000000000LL) / g_dp_qpf;
}

static void aowl_sp_add(int32_t slot, int64_t t0) {
    int64_t ns;
    if (slot < 0 || slot >= AOWL_SP_SLOTS) return;
    ns = aowl_sp_delta_ns(t0);
    if (ns < 0) return;
    if (ns == 0) g_sp_subtick[slot]++;
    g_sp_ns[slot] += ns;
    g_sp_calls[slot]++;
    g_sp_cur[slot] += ns;
    if (ns > g_sp_max_ns[slot]) g_sp_max_ns[slot] = ns;
}

static void aowl_sp_call_begin(void) {
    int i;
    if (!aowl_dp_enabled()) return;
    for (i = 0; i < AOWL_SP_SLOTS; i++) g_sp_cur[i] = 0;
}

/* Closes the outer bracket. Charges the WHOLE call, and -- if it crossed the
 * tail threshold -- attributes it to the phase that dominated it, or to
 * "unexplained" when no phase accounted for the majority. That last bucket is
 * the point: a slow call nothing explains must be visible as such. */
static void aowl_sp_call_end(int64_t t0) {
    int64_t ns, best = -1, acc = 0;
    int i, bi = -1;
    ns = aowl_sp_delta_ns(t0);
    if (ns < 0) return;
    g_sp_total_ns += ns;
    g_sp_total_calls++;
    if (ns > g_sp_total_max_ns) g_sp_total_max_ns = ns;
    if (ns < AOWL_SP_SLOW_NS) return;
    g_sp_slow_calls++;
    g_sp_slow_ns += ns;
    for (i = 0; i < AOWL_SP_SLOTS; i++) {
        acc += g_sp_cur[i];
        if (g_sp_cur[i] > best) { best = g_sp_cur[i]; bi = i; }
    }
    /* "Dominated" means it holds more than half of the call. Anything less and
     * we say plainly that no phase explains it. */
    if (bi >= 0 && best * 2 > ns) g_sp_slow_by[bi]++;
    else                          g_sp_slow_unexplained++;
    (void)acc;
}

/* The positive control: dependent adds into a volatile sink, through the SAME
 * bracket, in the SAME call. Its printed cost is what proves the meter honest. */
static void aowl_sp_control(void) {
    int64_t t, a; int i;
    if (!aowl_dp_enabled()) return;
    t = aowl_sp_now();
    a = g_sp_sink;
    for (i = 0; i < AOWL_SP_CTRL_ITERS; i++) a += (int64_t)i ^ (a & 7);
    g_sp_sink = a;
    aowl_sp_add(AOWL_SP_CTRL, t);
}

static int64_t aowl_sp_ns(int32_t i)      { return (i >= 0 && i < AOWL_SP_SLOTS) ? g_sp_ns[i] : -1; }
static int64_t aowl_sp_calls(int32_t i)   { return (i >= 0 && i < AOWL_SP_SLOTS) ? g_sp_calls[i] : -1; }
static int64_t aowl_sp_max(int32_t i)     { return (i >= 0 && i < AOWL_SP_SLOTS) ? g_sp_max_ns[i] : -1; }
static int64_t aowl_sp_subtick(int32_t i) { return (i >= 0 && i < AOWL_SP_SLOTS) ? g_sp_subtick[i] : -1; }
static int64_t aowl_sp_slow_by(int32_t i) { return (i >= 0 && i < AOWL_SP_SLOTS) ? g_sp_slow_by[i] : -1; }
static int64_t aowl_sp_total_ns(void)     { return g_sp_total_ns; }
static int64_t aowl_sp_total_calls(void)  { return g_sp_total_calls; }
static int64_t aowl_sp_total_max(void)    { return g_sp_total_max_ns; }
static int64_t aowl_sp_slow_calls(void)   { return g_sp_slow_calls; }
static int64_t aowl_sp_slow_ns(void)      { return g_sp_slow_ns; }
static int64_t aowl_sp_slow_unexp(void)   { return g_sp_slow_unexplained; }
static int64_t aowl_sp_dropped(void)      { return g_sp_dropped; }
static int64_t aowl_sp_slow_ns_threshold(void) { return AOWL_SP_SLOW_NS; }
static int32_t aowl_sp_slots(void)        { return AOWL_SP_SLOTS; }
static int32_t aowl_sp_ctrl_slot(void)    { return AOWL_SP_CTRL; }

#endif /* AOWLSPT_SPLPROF_H */
