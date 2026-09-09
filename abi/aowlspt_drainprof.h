/* aowlspt_drainprof.h -- THE DRAIN PROFILER. A per-rider QPC bracket over every
 * rider on the host's two per-frame drains, so "where does the frame go" is
 * answered by reading ONE log line instead of relaunching the game.
 *
 * WHY THIS EXISTS, measured. `abi/aowlspt_frametime.h` established the fact:
 * 87.4-92.2ms/frame in raid (phase-verified DEPLOYED in the same log) against
 * 26.7ms in the menu. It cannot say WHICH of the fourteen riders on
 * `TarkovApplication::Update` and the three on the render drain is spending it.
 * Four bisection attempts by relaunching with features toggled produced one
 * RETRACTED claim; removing ~11ms of real, measured work (the nuFn/duFn
 * per-call verify preamble) moved the frame only 92.2 -> 87.4ms, which is not a
 * result any toggle experiment can explain. So: bracket everything, at once, in
 * one run.
 *
 * WHAT IT HOOKS. Nothing new. It installs NO detour, resolves NO name, calls
 * NOTHING in the game and dereferences no game pointer. It is a pair of QPC
 * reads around call sites that already exist, in `patchFired`'s `gDrainSlot`
 * and `gRenderDrainSlot` branches, plus one pair around `cInvokeCallback` in
 * `runDue` for the per-mod breakdown.
 *
 * IT ARMS NO SEH GUARD, deliberately and for the same reason the frame meter
 * does not: its entire working set is the statics in this file plus
 * QueryPerformanceCounter. More important, `aowl_p_p_seh` is NOT RE-ENTRANT --
 * several of the riders it brackets (natEspDrainTick, camDrainTick,
 * cwDrainTick, rpDrainTick) open one internally, and a guard here would be
 * OUTSIDE theirs, which is where a bracket belongs, but a guard nested the
 * other way would disarm the outer one. So: no guard, ever, in this file.
 *
 * DISJOINT AND EXHAUSTIVE, by construction and then by arithmetic.
 *   - The TOP-LEVEL rows (slot 0..AOWL_DP_TOP-1) bracket sequential,
 *     non-overlapping statements. They cannot double-count.
 *   - The NESTED rows (slot AOWL_DP_TOP..) are per-mod callback times measured
 *     INSIDE `mainDrain`. They are a BREAKDOWN OF row 1, not additional cost,
 *     and the reporter must never add them to the top-level sum.
 *   - `aowl_dp_frame()` accumulates the interval between successive drain
 *     entries -- the same clock, the same place in the tick as the frame meter
 *     -- so `accounted% = sum(top-level) / frame_ns` is computed against a
 *     denominator this file measured itself and does not borrow.
 *   - Whatever is left is OUTSIDE every bracket and the reporter is required to
 *     say so in those words. It is not "the rest of the host"; it is the game.
 *
 * THE POSITIVE CONTROL, slot AOWL_DP_CTRL. 512 dependent integer adds, run in
 * the same tick, through the same bracket, with the same clock. Its expected
 * cost is on the order of a few hundred nanoseconds on this machine; if the
 * control reads 0us or reads milliseconds, THE METER IS LYING and every other
 * row in the line is void. Tonight a control settled exactly this question and
 * disproved the theory that produced it. The adds are accumulated into a
 * volatile sink so no compiler may delete them.
 *
 * UNITS. Every accumulator is NANOSECONDS internally and every printed number
 * is MICROSECONDS with the letters `us` attached, because `neUs()` output was
 * read as nanoseconds tonight and sent an agent chasing a phantom. There is no
 * unitless number anywhere in the output.
 *
 * NO SENTINEL IS EVER PRINTED AS A VALUE. There are no percentiles here and so
 * no saturation marker; every row is a total and a call count, and a row with
 * zero calls prints `0 calls` rather than a duration of zero.
 *
 * THE METER'S OWN OVERHEAD IS MEASURED, not asserted. At enable time
 * `aowl_dp_calibrate()` runs AOWL_DP_CAL empty bracket pairs and stores the
 * per-pair cost, which the reporter prints and multiplies by the observed call
 * count so a reader can see the instrument's share of its own reading.
 *
 * THREE OUTCOMES. Below AOWL_DP_MIN_FRAMES bracketed frames the reporter is
 * required to say INCONCLUSIVE. "Not enough frames" is not a pass.
 */
#ifndef AOWLSPT_DRAINPROF_H
#define AOWLSPT_DRAINPROF_H

#include <stdint.h>
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

/* Top-level rows: the riders, in the order they run. Kept in lockstep with the
 * call sites in `patchFired`; the names live here so the log line and the
 * bracket cannot drift apart. */
#define AOWL_DP_FT        0
#define AOWL_DP_MAIN      1
#define AOWL_DP_INSPECT   2
#define AOWL_DP_MODESKIP  3
#define AOWL_DP_UISTATE   4
#define AOWL_DP_CURSOR    5
#define AOWL_DP_SPLREBR   6
#define AOWL_DP_AUTORAID  7
#define AOWL_DP_NATRAID   8
#define AOWL_DP_RAIDPHASE 9
#define AOWL_DP_CAM      10
#define AOWL_DP_NATESP   11
#define AOWL_DP_CW       12
#define AOWL_DP_RDRAIN   13
#define AOWL_DP_RCURSOR  14
#define AOWL_DP_RCAM     15
#define AOWL_DP_CTRL     16
#define AOWL_DP_TOP      17

/* Nested rows: per-mod callback cost inside `mainDrain`'s `runDue`. A
 * BREAKDOWN of AOWL_DP_MAIN, never added to the top-level sum. Keyed by a
 * direct map on modIndex with one shared overflow row, so there is no search on
 * the per-callback path. */
#define AOWL_DP_MOD0     AOWL_DP_TOP
#define AOWL_DP_NMOD     14
#define AOWL_DP_MODOTHER (AOWL_DP_MOD0 + AOWL_DP_NMOD - 1)
#define AOWL_DP_SLOTS    (AOWL_DP_MOD0 + AOWL_DP_NMOD)

/* 512 dependent integer adds. Large enough to be far above the clock's
 * resolution, small enough that it can be left on permanently. */
#define AOWL_DP_CTRL_ITERS 512

/* Empty bracket pairs used to measure the instrument's own cost. */
#define AOWL_DP_CAL 2000

/* Below this many bracketed frames the verdict is INCONCLUSIVE. At ~11fps this
 * is about 11 seconds of raid. */
#define AOWL_DP_MIN_FRAMES 120

static int64_t g_dp_ns[AOWL_DP_SLOTS];
static int64_t g_dp_calls[AOWL_DP_SLOTS];
static int64_t g_dp_max_ns[AOWL_DP_SLOTS];

static int64_t g_dp_qpf     = 0;
static int64_t g_dp_prev    = 0;   /* QPC at the previous drain entry */
static int64_t g_dp_frames  = 0;   /* intervals accumulated */
static int64_t g_dp_frame_ns = 0;  /* their sum */
static int64_t g_dp_dropped = 0;   /* intervals refused as absurd */
static int64_t g_dp_overhead_ns = -1; /* per bracket PAIR, measured */
static int32_t g_dp_on      = 0;
static volatile int64_t g_dp_sink = 0; /* the control's sink; never optimised out */

static int aowl_dp_init_qpf(void) {
    LARGE_INTEGER f;
    if (g_dp_qpf) return 1;
    if (!QueryPerformanceFrequency(&f) || f.QuadPart <= 0) return 0;
    g_dp_qpf = (int64_t)f.QuadPart;
    return 1;
}

/* Raw counter, in QPC ticks. The Nim side holds this in a local across the
 * bracketed statement and hands it straight back to `aowl_dp_add`; it is never
 * interpreted as a duration on its own. */
static int64_t aowl_dp_now(void) {
    LARGE_INTEGER v;
    if (!g_dp_on) return 0;
    QueryPerformanceCounter(&v);
    return (int64_t)v.QuadPart;
}

static void aowl_dp_add(int32_t slot, int64_t t0) {
    LARGE_INTEGER v;
    int64_t d, ns;
    if (!g_dp_on || !t0) return;
    if (slot < 0 || slot >= AOWL_DP_SLOTS) return;
    if (!aowl_dp_init_qpf()) return;
    QueryPerformanceCounter(&v);
    d = (int64_t)v.QuadPart - t0;
    /* A negative delta means the counter went backwards; a delta over 10s means
     * a load screen or a suspended process. Neither is charged to a rider. */
    if (d < 0 || d > g_dp_qpf * 10) { g_dp_dropped++; return; }
    ns = (d * 1000000000LL) / g_dp_qpf;
    g_dp_ns[slot] += ns;
    g_dp_calls[slot]++;
    if (ns > g_dp_max_ns[slot]) g_dp_max_ns[slot] = ns;
}

/* Called ONCE at the top of the drain branch. Accumulates the frame interval on
 * the same clock as every bracket, which is what makes the accounted-for
 * percentage an honest ratio rather than a comparison of two instruments. */
static void aowl_dp_frame(void) {
    LARGE_INTEGER v;
    int64_t q, d;
    if (!g_dp_on) return;
    if (!aowl_dp_init_qpf()) return;
    QueryPerformanceCounter(&v);
    q = (int64_t)v.QuadPart;
    if (g_dp_prev) {
        d = q - g_dp_prev;
        if (d > 0 && d < g_dp_qpf * 10) {
            g_dp_frame_ns += (d * 1000000000LL) / g_dp_qpf;
            g_dp_frames++;
        } else {
            g_dp_dropped++;
        }
    }
    g_dp_prev = q;
}

/* THE POSITIVE CONTROL. Dependent adds into a volatile sink. */
static void aowl_dp_control_body(void) {
    int64_t acc = g_dp_sink;
    int i;
    for (i = 0; i < AOWL_DP_CTRL_ITERS; i++) acc += (int64_t)i ^ (acc & 7);
    g_dp_sink = acc;
}

static void aowl_dp_calibrate(void) {
    LARGE_INTEGER a, b;
    int64_t t, d; int i;
    g_dp_overhead_ns = -1;
    if (!aowl_dp_init_qpf()) return;
    QueryPerformanceCounter(&a);
    for (i = 0; i < AOWL_DP_CAL; i++) { t = aowl_dp_now(); aowl_dp_add(AOWL_DP_CTRL, t); }
    QueryPerformanceCounter(&b);
    d = (int64_t)b.QuadPart - (int64_t)a.QuadPart;
    if (d <= 0) return;
    g_dp_overhead_ns = ((d * 1000000000LL) / g_dp_qpf) / (int64_t)AOWL_DP_CAL;
    /* The calibration used the control's own row; wipe it so the first report
     * is not polluted by AOWL_DP_CAL synthetic calls. */
    g_dp_ns[AOWL_DP_CTRL] = 0;
    g_dp_calls[AOWL_DP_CTRL] = 0;
    g_dp_max_ns[AOWL_DP_CTRL] = 0;
}

static void aowl_dp_reset(void) {
    int i;
    for (i = 0; i < AOWL_DP_SLOTS; i++) {
        g_dp_ns[i] = 0; g_dp_calls[i] = 0; g_dp_max_ns[i] = 0;
    }
    g_dp_frames = 0; g_dp_frame_ns = 0; g_dp_dropped = 0; g_dp_prev = 0;
}

static void aowl_dp_set_enabled(int32_t on) {
    if (on && !g_dp_on) {
        g_dp_on = 1;
        aowl_dp_reset();
        aowl_dp_calibrate();
        return;
    }
    if (!on) g_dp_on = 0;
}
static int32_t aowl_dp_enabled(void) { return g_dp_on; }

/* Map a modIndex onto a nested row without a search. Anything outside the
 * direct range lands in the shared overflow row, which is LABELLED as such --
 * a bucket that silently absorbs unknowns and is printed as if it were one mod
 * is exactly the kind of confidently wrong row this project treats as worse
 * than none. */
static int32_t aowl_dp_mod_slot(int32_t modIndex) {
    if (modIndex >= 0 && modIndex < (AOWL_DP_NMOD - 1))
        return (int32_t)AOWL_DP_MOD0 + modIndex;
    return (int32_t)AOWL_DP_MODOTHER;
}

/* ---- READOUT ----------------------------------------------------------- */
static int64_t aowl_dp_ns(int32_t i) {
    if (i < 0 || i >= AOWL_DP_SLOTS) return 0; return g_dp_ns[i];
}
static int64_t aowl_dp_calls(int32_t i) {
    if (i < 0 || i >= AOWL_DP_SLOTS) return 0; return g_dp_calls[i];
}
static int64_t aowl_dp_max(int32_t i) {
    if (i < 0 || i >= AOWL_DP_SLOTS) return 0; return g_dp_max_ns[i];
}
static int64_t aowl_dp_frames(void)    { return g_dp_frames; }
static int64_t aowl_dp_frame_ns(void)  { return g_dp_frame_ns; }
static int64_t aowl_dp_dropped(void)   { return g_dp_dropped; }
static int64_t aowl_dp_overhead(void)  { return g_dp_overhead_ns; }
static int32_t aowl_dp_top(void)       { return AOWL_DP_TOP; }
static int32_t aowl_dp_slots(void)     { return AOWL_DP_SLOTS; }
static int32_t aowl_dp_mod0(void)      { return AOWL_DP_MOD0; }
static int32_t aowl_dp_modother(void)  { return AOWL_DP_MODOTHER; }
static int32_t aowl_dp_ctrl(void)      { return AOWL_DP_CTRL; }
static int32_t aowl_dp_ctrl_iters(void){ return AOWL_DP_CTRL_ITERS; }
static int64_t aowl_dp_min_frames(void){ return AOWL_DP_MIN_FRAMES; }
static int32_t aowl_dp_cal(void)       { return AOWL_DP_CAL; }

/* Sum of the TOP-LEVEL rows only. The nested per-mod rows are inside
 * AOWL_DP_MAIN and adding them would double-count. */
static int64_t aowl_dp_accounted_ns(void) {
    int64_t s = 0; int i;
    for (i = 0; i < AOWL_DP_TOP; i++) s += g_dp_ns[i];
    return s;
}

#endif /* AOWLSPT_DRAINPROF_H */
