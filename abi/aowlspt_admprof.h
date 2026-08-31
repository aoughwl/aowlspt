/* THE ADMIN PHASE PROFILER -- what mod[8] spends its 6.6ms/frame on.
 *
 * WHY THIS EXISTS. The host's drain profiler (abi/aowlspt_drainprof.h) measured,
 * live, in a phase-confirmed raid, with an honest meter (control 0.3us/call,
 * 35ns/pair overhead = 0.0% of frame):
 *
 *     INSIDE mainDrain: mod[8]=6579.2us/frame over 7096 callbacks,
 *                       max 43575.5us.  mainDrain total 7396.9us/frame.
 *
 * mod[8] is mods/admin, and 6579.2 of 7396.9 is ~89% of ALL mod time in the
 * drain. There is exactly one admin callback in the drain -- `onCamTick`,
 * registered with `everyMain` -- so the whole of that number is inside one
 * function, and the only useful next measurement is INSIDE it.
 *
 * This deliberately COPIES `mods/maps/sp/mapsprof.h`'s rules rather than
 * inventing new ones, because each of those rules was learned by getting the
 * measurement wrong first:
 *
 *   * ONE clock: QueryPerformanceCounter, converted to nanoseconds once.
 *   * EVERY printed number is MICROSECONDS with `us` attached, or NANOSECONDS
 *     with `ns` attached. There is no unitless duration in the output. (A
 *     microsecond figure was read as nanoseconds once and sent a whole agent
 *     after a phantom.)
 *   * A POSITIVE CONTROL through the same bracket, in the same tick. Without
 *     it "the meter is lying" cannot be ruled out, and it has had to be ruled
 *     out three times.
 *   * DISJOINT and EXHAUSTIVE phases at each level, each level with its OWN
 *     parent bracket to subtract against, so the report says "N% is OUTSIDE
 *     every bracket and is UNEXPLAINED" rather than implying the phases sum to
 *     the total.
 *   * A level that sums to >= 100% of its parent is printed as BROKEN, not as
 *     a result. (One shipped reading 104.3% because its parent bracketed only
 *     one of two call sites.)
 *   * "0 calls, NEVER RAN" is a DIFFERENT report from "cheap".
 *   * A saturation sentinel is never printed as a value.
 *   * Below AP_MIN_TICKS the verdict is INCONCLUSIVE -- "I could not look yet"
 *     is not a pass (CLAUDE.md 9b).
 *
 * IT IS NOT A GUARD AND OPENS NONE. Every bracket is a pair of QPC reads around
 * a call site that already exists. It installs no detour, resolves no name,
 * calls nothing in the game and dereferences nothing of the game's, and every
 * bracket sits strictly OUTSIDE any `aowl_p_p_seh` -- that guard is not
 * re-entrant (CLAUDE.md 5). It holds fixed static storage and allocates
 * nothing, managed or otherwise (rule 7).
 *
 * FOUR LEVELS, each with its own parent:
 *   L0  AP_WHOLE                 the entire onCamTick body
 *   L1  AP_HOTKEY..AP_POS        phases of the tick        (parent AP_WHOLE)
 *   L2  AP_P_ARM..AP_P_MOVE      phases of posSample()     (parent AP_POS)
 *   L3  AP_E_FETCH..AP_E_ADD     phases of one list slot   (parent AP_P_LOOP)
 *   L4  AP_L_H1..AP_L_TAIL       hops inside pos_live      (parent AP_L_WHOLE)
 *
 * WHY L4's PARENT IS AP_L_WHOLE AND NOT AP_E_ADD. `posSample` calls
 * `aowl_admin_pos_add` TWICE per sweep's worth of work: once for the LOCAL
 * player (bracketed AP_P_ME, at L2) and once per list entity (bracketed
 * AP_E_ADD, at L3). Both reach `aowl_admin_pos_live` and both fire the L4
 * brackets, so children of AP_E_ADD would count strictly MORE calls than their
 * parent and sum above it -- the exact 104.3% shape. AP_L_WHOLE brackets the
 * whole `pos_live` body on every return path including the early ones, so by
 * construction it encloses every child and has at least each child's call
 * count. The reporter asserts that containment OUT LOUD, so a future call site
 * that opens a child outside the whole announces itself by name instead of
 * quietly re-creating the bug.
 *
 * ONE definition, ONE translation unit. The counters are process-global state,
 * so `static` here would give every including TU its own private copy and the
 * report would describe whichever TU printed it -- a plausible number from a
 * meter that measured a fraction of itself. `mods/admin/adm/admprof.nim` is the
 * ONLY TU that defines AOWL_ADMPROF_IMPL; every other includer gets prototypes.
 */
#ifndef AOWLSPT_ADMPROF_H
#define AOWLSPT_ADMPROF_H

#include <stdint.h>
#include <windows.h>

#define AP_WHOLE     0   /* L0 -- the whole onCamTick body */

#define AP_HOTKEY    1   /* L1 -- hotkeyPoll (before the ESP gate, always runs) */
#define AP_CAM       2   /* L1 -- camSample: 3 RVA calls + guarded hops + math  */
#define AP_POS       3   /* L1 -- posSample: the Unity-thread position sweep    */

#define AP_P_ARM     4   /* L2 -- posArm (sticky after the first success)       */
#define AP_P_WORLD   5   /* L2 -- worldPtr + playersList + items/size reads     */
#define AP_P_ME      6   /* L2 -- posAdd for the LOCAL player                   */
#define AP_P_LOOP    7   /* L2 -- the whole entity loop                         */
#define AP_P_COMMIT  8   /* L2 -- posCommit (double-buffer flip + carry-forward)*/
#define AP_P_MOVE    9   /* L2 -- the movement self-check (posGet + arithmetic) */

#define AP_E_FETCH  10   /* L3 -- rdPtr(items, ArrDataOff + i*8), per SLOT      */
#define AP_E_ADD    11   /* L3 -- posAdd, per non-nil non-local slot            */

#define AP_L_H1     12   /* L4 -- Player+0xB40  -> PlayerBones        (rp, 8)   */
#define AP_L_H2     13   /* L4 -- PlayerBones+0x178 -> BifacialXform  (rp, 8)   */
#define AP_L_H3     14   /* L4 -- BT+0xA9 _accumulatePositionAndRot   (u8, 1)   */
#define AP_L_H4     15   /* L4 -- BT+0xA8 _useImitation               (u8, 1)   */
#define AP_L_H5     16   /* L4 -- BT+0x10 Original                    (rp, 8)   */
#define AP_L_CALL   17   /* L4 -- the ONE direct call at verified RVA 0x6F32C0  */
#define AP_L_TAIL   18   /* L4 -- copy-out + aowl_admin_pos_classify            */
#define AP_L_WHOLE  19   /* the L4 PARENT: the whole pos_live body, every path  */

#define AP_CTRL     20   /* the positive control */
#define AP_SLOTS    21

#define AP_CTRL_ITERS 512
#define AP_CAL_ITERS  256
#define AP_MIN_TICKS  60

/* An interval longer than this is not a measurement, it is a debugger break or
 * a suspended thread. Counted as DROPPED and never folded into a total, because
 * one such sample would dominate every mean in the report. */
#define AP_ABSURD_NS 10000000000LL

int64_t aowl_ap_now(void);
void    aowl_ap_add(int32_t slot, int64_t t0);
void    aowl_ap_control_body(void);
void    aowl_ap_set_enabled(int32_t on);
int32_t aowl_ap_enabled(void);
void    aowl_ap_tick(void);
int64_t aowl_ap_ns(int32_t i);
int64_t aowl_ap_calls(int32_t i);
int64_t aowl_ap_max(int32_t i);
int64_t aowl_ap_ticks(void);
int64_t aowl_ap_dropped(void);
int64_t aowl_ap_overhead(void);
int32_t aowl_ap_cal(void);
int32_t aowl_ap_slots(void);
int32_t aowl_ap_ctrl_iters(void);
int64_t aowl_ap_min_ticks(void);

#ifdef AOWL_ADMPROF_IMPL

typedef struct {
    int64_t ns[AP_SLOTS];
    int64_t calls[AP_SLOTS];
    int64_t max[AP_SLOTS];
    int64_t ticks;        /* completed AP_WHOLE brackets */
    int64_t dropped;
    int64_t overheadNs;   /* per bracket PAIR, measured at enable; <0 = unmeasured */
    int32_t calIters;
    int32_t on;
    int64_t freq;
    int32_t ctrlSink;     /* the control's accumulator, kept so it cannot be
                           * optimised away into a measurement of nothing */
} AowlAdmProf;

AowlAdmProf g_ap = {{0},{0},{0},0,0,-1,0,0,0,0};

int64_t aowl_ap_now(void) {
    LARGE_INTEGER c;
    if (!g_ap.freq) {
        LARGE_INTEGER f;
        if (!QueryPerformanceFrequency(&f) || f.QuadPart <= 0) return 0;
        g_ap.freq = f.QuadPart;
    }
    if (!QueryPerformanceCounter(&c)) return 0;
    /* to nanoseconds without overflowing: split the division */
    return (c.QuadPart / g_ap.freq) * 1000000000LL +
           ((c.QuadPart % g_ap.freq) * 1000000000LL) / g_ap.freq;
}

void aowl_ap_add(int32_t slot, int64_t t0) {
    int64_t d;
    if (!g_ap.on || slot < 0 || slot >= AP_SLOTS || t0 == 0) return;
    d = aowl_ap_now() - t0;
    if (d < 0 || d > AP_ABSURD_NS) { g_ap.dropped++; return; }
    g_ap.ns[slot] += d;
    g_ap.calls[slot]++;
    if (d > g_ap.max[slot]) g_ap.max[slot] = d;
}

/* The control body: AP_CTRL_ITERS integer adds. Chosen to land in the same
 * order of magnitude the smallest real phase is expected to occupy, so a meter
 * that reads it as 0.0us or as milliseconds is visibly broken. */
void aowl_ap_control_body(void) {
    int32_t i, s = g_ap.ctrlSink;
    for (i = 0; i < AP_CTRL_ITERS; i++) s += i;
    g_ap.ctrlSink = s;
}

void aowl_ap_reset(void) {
    int32_t i;
    for (i = 0; i < AP_SLOTS; i++) { g_ap.ns[i] = 0; g_ap.calls[i] = 0; g_ap.max[i] = 0; }
    g_ap.ticks = 0;
    g_ap.dropped = 0;
}

/* Calibration measures the meter's own share of its reading. It is MEASURED,
 * never asserted, and when it fails the report says the share is UNKNOWN rather
 * than printing a zero that reads as "free". */
void aowl_ap_set_enabled(int32_t on) {
    g_ap.on = on ? 1 : 0;
    aowl_ap_reset();
    if (!g_ap.on) return;
    {
        int32_t i;
        int64_t t = aowl_ap_now(), d;
        if (t == 0) { g_ap.overheadNs = -1; return; }
        for (i = 0; i < AP_CAL_ITERS; i++) { int64_t a = aowl_ap_now(); (void)a; }
        d = aowl_ap_now() - t;
        if (d <= 0 || d > AP_ABSURD_NS) { g_ap.overheadNs = -1; return; }
        g_ap.overheadNs = d / AP_CAL_ITERS;   /* two QPC reads = one pair */
        g_ap.calIters = AP_CAL_ITERS;
    }
}

int32_t aowl_ap_enabled(void) { return g_ap.on; }
void    aowl_ap_tick(void)    { if (g_ap.on) g_ap.ticks++; }
int64_t aowl_ap_ns(int32_t i)    { return (i >= 0 && i < AP_SLOTS) ? g_ap.ns[i] : 0; }
int64_t aowl_ap_calls(int32_t i) { return (i >= 0 && i < AP_SLOTS) ? g_ap.calls[i] : 0; }
int64_t aowl_ap_max(int32_t i)   { return (i >= 0 && i < AP_SLOTS) ? g_ap.max[i] : 0; }
int64_t aowl_ap_ticks(void)      { return g_ap.ticks; }
int64_t aowl_ap_dropped(void)    { return g_ap.dropped; }
int64_t aowl_ap_overhead(void)   { return g_ap.overheadNs; }
int32_t aowl_ap_cal(void)        { return g_ap.calIters; }
int32_t aowl_ap_slots(void)      { return AP_SLOTS; }
int32_t aowl_ap_ctrl_iters(void) { return AP_CTRL_ITERS; }
int64_t aowl_ap_min_ticks(void)  { return AP_MIN_TICKS; }

#endif /* AOWL_ADMPROF_IMPL */

#endif /* AOWLSPT_ADMPROF_H */
