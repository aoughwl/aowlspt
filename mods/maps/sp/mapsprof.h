/* THE MAPS PHASE PROFILER -- what mod[3] spends its 6.75ms/frame on.
 *
 * WHY THIS EXISTS. The host's drain profiler (abi/aowlspt_drainprof.h) measured
 * mod[3] = Maps at 6751.1us/frame over 8326 callbacks in 5764 frames, i.e. ~4.7ms
 * PER CALL with a 65.7ms maximum. That is a per-CALL cost, not a call-count
 * problem, so the only useful next measurement is INSIDE the call. This is that
 * measurement, and it deliberately copies drainprof's rules rather than
 * inventing new ones:
 *
 *   * ONE clock: QueryPerformanceCounter, converted to nanoseconds once.
 *   * EVERY printed number is MICROSECONDS with `us` attached. There is no
 *     unitless duration anywhere in the output. (natesp's `neUs()` was read as
 *     nanoseconds once and sent a whole agent after a phantom.)
 *   * A POSITIVE CONTROL through the same bracket. Without it "the meter is
 *     lying" cannot be ruled out, and it has had to be ruled out three times.
 *   * DISJOINT and EXHAUSTIVE phases at each level, with a whole-bracket to
 *     subtract against, so the report can say "N% is OUTSIDE every bracket and
 *     is UNEXPLAINED" rather than implying the phases sum to the total.
 *   * "0 calls, never ran" is reported as a DIFFERENT thing from "cheap".
 *   * A saturation sentinel is never printed as a value.
 *
 * IT IS NOT A GUARD AND OPENS NONE. Every bracket here is a pair of QPC reads
 * around a call site that already exists. It installs no detour, resolves no
 * name, dereferences nothing in the game, and sits strictly OUTSIDE any
 * aowl_p_p_seh (that guard is not re-entrant -- CLAUDE.md 5).
 *
 * THREE LEVELS, each with its own whole:
 *   L0  MP_WHOLE      the entire onMainTick body
 *   L1  MP_LOCK..MP_ART        phases of the tick   (whole = MP_WHOLE)
 *   L2  MP_C_PRE..MP_C_ENTS    phases of collect()  (whole = MP_COLLECT)
 *   L3  MP_E_POS..MP_E_STORE   phases of one entity (whole = MP_C_ENTS)
 */
#ifndef AOWLSPT_MAPSPROF_H
#define AOWLSPT_MAPSPROF_H

#include <stdint.h>
#include <string.h>
#include <windows.h>

#define MP_WHOLE     0   /* L0 -- the whole onMainTick body */

#define MP_LOCK      1   /* L1 */
#define MP_COLLECT   2
#define MP_PUBLISH   3
#define MP_FSPOLL    4
#define MP_ART       5

#define MP_C_PRE     6   /* L2 -- inside MP_COLLECT */
#define MP_C_LOC     7
#define MP_C_LOCAL   8
#define MP_C_LIST    9
#define MP_C_ENTS   10

/* L3 -- inside MP_C_ENTS, summed over entities.
 *
 * MP_E_FETCH was added to chase the 9.6% (425.9us/tick) that the first live run
 * reported as UNEXPLAINED at this level -- larger, on its own, than several
 * whole riders. The only work inside MP_C_ENTS that no bracket covered was the
 * per-slot `rdPtr(items, ArrDataOff + i*8)` array read (one guarded
 * VirtualQuery per list slot, n per tick, INCLUDING the slots that are then
 * skipped as nil or as the local player) plus the loop's own arithmetic. That
 * read is now bracketed, so the next run ATTRIBUTES it instead of leaving it in
 * the residual. This is an instrument change, not a claim: nothing here asserts
 * that is where the 9.6% went. */
#define MP_E_FETCH  11
#define MP_E_POS    12
#define MP_E_AI     13
#define MP_E_CLS    14
#define MP_E_ID     15
#define MP_E_STORE  16

/* L4 -- inside sp_pos_live, summed over entities.
 *
 * WHY IT WAS SPLIT PER HOP. The previous L4 measured the walk as ONE row and
 * that row came back, live in a phase-confirmed raid, at 138953 ns/call against
 * 661 ns/call for the RVA call it was supposed to indict. It also came back at
 * ~10x the arithmetic prediction: one guarded hop measured elsewhere in the
 * same ticks (MP_E_AI, a single sp_rd_ptr) costs 2904 ns/call, so five of them
 * should be ~14500 ns. "Five hops cost ten times five hops" is not a result, it
 * is a question, and a single aggregate row cannot answer it. Each hop now has
 * its own bracket so the report can name WHICH one, instead of averaging the
 * answer away:
 *
 *   MP_P_H1  Player+0xB40  -> PlayerBones          (sp_rd_ptr, 8 bytes)
 *   MP_P_H2  PlayerBones+0x178 -> BifacialTransform(sp_rd_ptr, 8 bytes)
 *   MP_P_H3  BT+0xA9 _accumulatePositionAndRotation(sp_rd_u8,  1 byte)
 *   MP_P_H4  BT+0xA8 _useImitation                 (sp_rd_u8,  1 byte)
 *   MP_P_H5  BT+0x10 Original                      (sp_rd_ptr, 8 bytes)
 *   MP_P_CALL the ONE direct call at byte-verified static RVA 0x6F32C0
 *   MP_P_TAIL the 12-byte copy-out and mm_pos_classify
 *
 * The five hop rows SUM to what MP_P_WALK used to report, so the new numbers
 * are diffable against the old one rather than replacing it with something
 * incomparable. Each bracket costs one extra QPC pair; MP_P_WHOLE below
 * ENCLOSES those pairs, so the meter's own cost stays inside the parent and
 * cannot push the level above 100%.
 *
 * MP_P_WHOLE -- THE FIX FOR THE LEVEL THAT SUMMED TO 104.3%.
 *
 * L4's parent used to be MP_E_POS, and MP_E_POS does NOT enclose every call
 * that opens the child brackets. `collectInner` calls posOf TWICE per tick's
 * worth of work: once for the LOCAL player (inside the MP_C_LOCAL bracket, at
 * L2) and once per entity (inside MP_E_POS, at L3). Both reach sp_pos_live and
 * both fire MP_P_*. So the children counted strictly more calls than the
 * parent, and their sum exceeded it -- which the reporter correctly refused to
 * present as a result. That is a WRONG PARENT, not an unclosed bracket.
 *
 * MP_P_WHOLE brackets the entire sp_pos_live body, on every return path
 * including the two that return before any clock is read. It therefore has, by
 * construction, EXACTLY the call count of each child that ran and encloses all
 * of them. The reporter additionally asserts that equality out loud, so a
 * future call site that opens a child outside the whole announces itself
 * instead of quietly re-creating this bug. */
#define MP_P_H1     17
#define MP_P_H2     18
#define MP_P_H3     19
#define MP_P_H4     20
#define MP_P_H5     21
#define MP_P_CALL   22
#define MP_P_TAIL   23
#define MP_P_WHOLE  24   /* the L4 parent -- encloses H1..TAIL, same call count */

#define MP_CTRL     25   /* the positive control */
#define MP_SLOTS    26

#define MP_CTRL_ITERS 512
#define MP_CAL_ITERS  256
#define MP_MIN_TICKS  60

/* An interval longer than this is not a measurement, it is a debugger break or
 * a suspended thread. Counted as DROPPED and never folded into a total, because
 * one such sample would dominate every mean in the report. */
#define MP_ABSURD_NS 10000000000LL

/* ONE definition, ONE translation unit. The counters are process-global state,
 * so `static` here would give every including TU its own private copy and the
 * report would describe whichever TU happened to print it -- a plausible number
 * from a meter that measured a third of itself. `sp/mapsprof.nim` is the ONLY
 * TU that defines AOWL_MAPSPROF_IMPL; every other includer gets prototypes. */
int64_t aowl_mp_now(void);
void    aowl_mp_add(int32_t slot, int64_t t0);
void    aowl_mp_control_body(void);
void    aowl_mp_set_enabled(int32_t on);
int32_t aowl_mp_enabled(void);
void    aowl_mp_tick(void);
int64_t aowl_mp_ns(int32_t i);
int64_t aowl_mp_calls(int32_t i);
int64_t aowl_mp_max(int32_t i);
int64_t aowl_mp_ticks(void);
int64_t aowl_mp_dropped(void);
int64_t aowl_mp_overhead(void);
int32_t aowl_mp_cal(void);
int32_t aowl_mp_slots(void);
int32_t aowl_mp_ctrl_iters(void);
int64_t aowl_mp_min_ticks(void);

#ifdef AOWL_MAPSPROF_IMPL

typedef struct {
    int64_t ns[MP_SLOTS];
    int64_t calls[MP_SLOTS];
    int64_t max[MP_SLOTS];
    int64_t ticks;        /* completed MP_WHOLE brackets */
    int64_t dropped;
    int64_t overheadNs;   /* per bracket PAIR, measured at enable; <0 = unmeasured */
    int32_t calIters;
    int32_t on;
    int64_t freq;
    int32_t ctrlSink;     /* the control's accumulator, kept so it cannot be
                           * optimised away into a measurement of nothing */
} AowlMapsProf;

AowlMapsProf g_mp = {{0},{0},{0},0,0,-1,0,0,0,0};

int64_t aowl_mp_now(void) {
    LARGE_INTEGER c;
    if (!g_mp.freq) {
        LARGE_INTEGER f;
        if (!QueryPerformanceFrequency(&f) || f.QuadPart <= 0) return 0;
        g_mp.freq = f.QuadPart;
    }
    if (!QueryPerformanceCounter(&c)) return 0;
    /* to nanoseconds without overflowing: split the division */
    return (c.QuadPart / g_mp.freq) * 1000000000LL +
           ((c.QuadPart % g_mp.freq) * 1000000000LL) / g_mp.freq;
}

void aowl_mp_add(int32_t slot, int64_t t0) {
    int64_t d;
    if (!g_mp.on || slot < 0 || slot >= MP_SLOTS || t0 == 0) return;
    d = aowl_mp_now() - t0;
    if (d < 0 || d > MP_ABSURD_NS) { g_mp.dropped++; return; }
    g_mp.ns[slot] += d;
    g_mp.calls[slot]++;
    if (d > g_mp.max[slot]) g_mp.max[slot] = d;
}

/* The control body: MP_CTRL_ITERS integer adds. Chosen to land in the same
 * order of magnitude the smallest real phase is expected to occupy, so a meter
 * that reads it as 0.0us or as milliseconds is visibly broken. */
void aowl_mp_control_body(void) {
    int32_t i, s = g_mp.ctrlSink;
    for (i = 0; i < MP_CTRL_ITERS; i++) s += i;
    g_mp.ctrlSink = s;
}

void aowl_mp_reset(void) {
    int32_t i;
    for (i = 0; i < MP_SLOTS; i++) { g_mp.ns[i] = 0; g_mp.calls[i] = 0; g_mp.max[i] = 0; }
    g_mp.ticks = 0;
    g_mp.dropped = 0;
}

/* Calibration measures the meter's own share of its reading. It is MEASURED,
 * never asserted, and when it fails the report says the share is UNKNOWN rather
 * than printing a zero that reads as "free". */
void aowl_mp_set_enabled(int32_t on) {
    g_mp.on = on ? 1 : 0;
    aowl_mp_reset();
    if (!g_mp.on) return;
    {
        int32_t i;
        int64_t t = aowl_mp_now(), d;
        if (t == 0) { g_mp.overheadNs = -1; return; }
        for (i = 0; i < MP_CAL_ITERS; i++) { int64_t a = aowl_mp_now(); (void)a; }
        d = aowl_mp_now() - t;
        if (d <= 0 || d > MP_ABSURD_NS) { g_mp.overheadNs = -1; return; }
        g_mp.overheadNs = d / MP_CAL_ITERS;   /* two QPC reads = one pair */
        g_mp.calIters = MP_CAL_ITERS;
    }
}

int32_t aowl_mp_enabled(void) { return g_mp.on; }
void    aowl_mp_tick(void)    { if (g_mp.on) g_mp.ticks++; }
int64_t aowl_mp_ns(int32_t i)    { return (i >= 0 && i < MP_SLOTS) ? g_mp.ns[i] : 0; }
int64_t aowl_mp_calls(int32_t i) { return (i >= 0 && i < MP_SLOTS) ? g_mp.calls[i] : 0; }
int64_t aowl_mp_max(int32_t i)   { return (i >= 0 && i < MP_SLOTS) ? g_mp.max[i] : 0; }
int64_t aowl_mp_ticks(void)      { return g_mp.ticks; }
int64_t aowl_mp_dropped(void)    { return g_mp.dropped; }
int64_t aowl_mp_overhead(void)   { return g_mp.overheadNs; }
int32_t aowl_mp_cal(void)        { return g_mp.calIters; }
int32_t aowl_mp_slots(void)      { return MP_SLOTS; }
int32_t aowl_mp_ctrl_iters(void) { return MP_CTRL_ITERS; }
int64_t aowl_mp_min_ticks(void)  { return MP_MIN_TICKS; }

#endif /* AOWL_MAPSPROF_IMPL */

#endif /* AOWLSPT_MAPSPROF_H */
