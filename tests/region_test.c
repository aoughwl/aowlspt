/* region_test.c -- the MUTATION PROOF for abi/aowlspt_region.h.
 *
 * CLAUDE.md 9b: assert the FINISHED STATE, prefer negatives, and three
 * outcomes. "It compiled and nothing crashed" is not evidence, so this test
 * does not check that the dispatcher runs. It DELIBERATELY BREAKS things and
 * asserts on what survives:
 *
 *   MUTATION 1  a participant in the MIDDLE of the dispatch order dereferences
 *               NULL every frame.
 *               ASSERT (negative): no OTHER participant loses a single frame --
 *               specifically the ones ORDERED AFTER it, which a single guard
 *               wrapped around the whole loop would silently starve. And the
 *               faulting one is disabled after exactly AOWL_REGION_FAULT_LIMIT
 *               faults, by name, with a reason.
 *
 *   MUTATION 2  a participant busy-waits far past its declared budget.
 *               ASSERT: it is counted, reported and throttled -- and, the part
 *               that matters, the well-behaved participants are NOT throttled,
 *               so "throttled" is not a constant.
 *
 *   MUTATION 3  the dispatcher is called from INSIDE an aowl_p_p_seh guard.
 *               ASSERT: it REFUSES with AOWL_REGION_REFUSE_NESTED rather than
 *               nesting. Without this the "never nested" claim is a comment.
 *
 *   MUTATION 3b THE REAL CHAIN. In `aowlhost.nim` the region is the LAST rider
 *               on `EFT.UI.PreloaderUI::Update`; the riders before it
 *               (`debugUiFired`, `modeTextUpdateFired`, `inspectFired`,
 *               `modsRidersTick`) each open their OWN aowl_p_p_seh and return.
 *               So the question that actually matters is not "does dispatch
 *               refuse when nested" but "is the thread clean by the time
 *               dispatch is reached", and the dangerous case is a PRIOR rider
 *               that FAULTED -- because that leaves the guard through the VEH
 *               longjmp path rather than a normal return.
 *               ASSERT: after a sibling guard that returned normally AND after
 *               a sibling guard that FAULTED, dispatch runs normally and does
 *               NOT refuse. Modelled rather than assumed.
 *
 *   MUTATION 4  a participant tries to submit a draw command from OUTSIDE its
 *               draw callback.
 *               ASSERT: refused with REFUSE_CLOSED.
 *
 *   CONTROL     the identical harness with the faulting body replaced by a
 *               harmless one. ASSERT nobody is disabled and nobody is
 *               throttled. This is the run that would FAIL if the checks above
 *               were checks that cannot fail -- if `disabled` were simply
 *               always 1, or `calls` always full, the control catches it.
 *
 * Every assertion is a property of the finished state read back through the
 * public `aowl_region_status`, never of a value this test just wrote.
 *
 * Build:  gcc -I abi -O1 -o tests/region_test.exe tests/region_test.c
 */

#include <stdio.h>
#include <string.h>
#include <windows.h>

#include "aowlspt_shim.h"     /* aowl_p_p_seh, aowl_seh_active            */
#define AOWL_REGION_HOST
#include "aowlspt_region.h"

static int failures = 0;
static int checks   = 0;

static void ok(int cond, const char* what) {
    checks++;
    if (!cond) { failures++; printf("  FAIL  %s\n", what); }
    else       {             printf("  pass  %s\n", what); }
}

static void inconclusive(const char* what) {
    printf("  INCONCLUSIVE  %s\n", what);
    failures++;   /* "I could not look" is not a pass. */
}

/* ---- the log sink: capture, so the test can assert the message NAMES the
 *      participant rather than merely existing. --------------------------- */
#define LOGCAP 256
static char g_log[LOGCAP][320];
static int  g_logN = 0;
static void sink(const char* line) {
    if (g_logN < LOGCAP) { strncpy(g_log[g_logN], line, 319);
                           g_log[g_logN][319] = 0; g_logN++; }
}
static int log_has(const char* a, const char* b) {
    int i;
    for (i = 0; i < g_logN; i++)
        if (strstr(g_log[i], a) && (!b || strstr(g_log[i], b))) return 1;
    return 0;
}

/* ---- the participants ------------------------------------------------- */

static int64_t c_early = 0, c_late = 0, c_last = 0, c_faulty = 0;
static int     g_makeItFault = 1;
static int     g_slowUs      = 0;
static int     g_drawCmds    = 0;

static void part_early(void* u, int64_t f) {
    (void)u; (void)f; c_early++;
    aowl_region_box(10.0f, 10.0f, 40.0f, 20.0f, 1.0f, 0xFF00FF00u);
}

/* MUTATION 1. Ordered between `early` and `late`. */
static void part_faulty(void* u, int64_t f) {
    (void)u; (void)f;
    c_faulty++;                       /* it does get entered ...            */
    aowl_region_text(1.0f, 1.0f, "before the fault", 0xFFFFFFFFu);
    if (g_makeItFault) {
        volatile int* p = (volatile int*)0;
        *p = 1;                       /* ... and never returns.             */
    }
}

static void part_late(void* u, int64_t f) {
    (void)u; (void)f; c_late++;
    aowl_region_fill(100.0f, 100.0f, 8.0f, 8.0f, 0xFF0000FFu);
    aowl_region_line(0.0f, 0.0f, 5.0f, 5.0f, 1.0f, 0xFFFFFFFFu);
}

/* MUTATION 2. Burns wall time with a QPC spin -- not Sleep, which would
 * measure the scheduler rather than the participant. */
static void part_slow(void* u, int64_t f) {
    LARGE_INTEGER a, b, q;
    (void)u; (void)f; c_last++;
    if (g_slowUs <= 0) return;
    QueryPerformanceFrequency(&q);
    QueryPerformanceCounter(&a);
    for (;;) {
        QueryPerformanceCounter(&b);
        if (((b.QuadPart - a.QuadPart) * 1000000ll) / q.QuadPart >= g_slowUs)
            break;
    }
}

static int32_t h_early = -1, h_faulty = -1, h_late = -1, h_slow = -1;

static void reg_all(void) {
    AowlRegionDesc d;
    #define REG(H, NM, FN, ORD, BUD, MASK)                     \
        memset(&d, 0, sizeof(d)); d.size = (int32_t)sizeof(d); \
        strcpy(d.name, NM); d.fn = FN; d.order = ORD;          \
        d.budgetUs = BUD; d.mask = MASK; H = aowl_region_register(&d);
    REG(h_early,  "early",  part_early,  10, 2000, AOWL_REGION_TICK | AOWL_REGION_DRAW)
    REG(h_faulty, "faulty", part_faulty, 20, 2000, AOWL_REGION_TICK | AOWL_REGION_DRAW)
    REG(h_late,   "late",   part_late,   30, 2000, AOWL_REGION_TICK | AOWL_REGION_DRAW)
    REG(h_slow,   "slow",   part_slow,   40,  200, AOWL_REGION_TICK)
    #undef REG
}

static void unreg_all(void) {
    aowl_region_unregister(h_early);  aowl_region_unregister(h_faulty);
    aowl_region_unregister(h_late);   aowl_region_unregister(h_slow);
}

static void reset(void) {
    c_early = c_late = c_last = c_faulty = 0;
    g_logN = 0;
}

static AowlRegionStatus stat_of(int32_t h) {
    AowlRegionStatus s;
    memset(&s, 0, sizeof(s));
    s.size = (int32_t)sizeof(s);
    if (aowl_region_status(h, &s) != AOWL_REGION_OK) memset(&s, 0, sizeof(s));
    return s;
}

/* MUTATION 3b's vehicles: a rider that behaves exactly as `debugUiFired` and
 * friends do -- it opens its own guard, does some work, and leaves. One
 * returns; one dies inside. Both are SIBLINGS of the region's dispatch, which
 * is what the real chain in `patchFired` produces. */
static void* prior_rider_ok(void* a) { *(int32_t*)a = 1; return (void*)(size_t)1; }
static void* prior_rider_faults(void* a) {
    volatile int* p = (volatile int*)0;
    *(int32_t*)a = 1;
    *p = 1;
    return (void*)(size_t)1;
}

/* MUTATION 3's vehicle: run the dispatcher from inside a live guard. */
static void* nested_body(void* a) {
    *(int32_t*)a = aowl_region_frame();
    return (void*)(size_t)1;
}

int main(void) {
    const int FRAMES = 12;
    int i;
    AowlRegionStatus se, sf, sl, ss;

    printf("aowlspt shared region -- MUTATION PROOF\n\n");

    aowl_region_init(sink);
    aowl_region_set_armed(1);

    /* -- registration before the region is armed --------------------- */
    aowl_region_set_armed(0);
    reg_all();
    for (i = 0; i < 3; i++) aowl_region_frame();
    ok(c_early == 0 && c_late == 0,
       "registration is legal while DISARMED and fires nothing until armed");
    aowl_region_set_armed(1);
    reset();

    /* ================= MUTATION 1: a faulting participant ============ */
    printf("\nMUTATION 1 -- 'faulty' dereferences NULL, ordered BETWEEN "
           "'early' and 'late'\n");
    g_makeItFault = 1; g_slowUs = 0;
    for (i = 0; i < FRAMES; i++) aowl_region_frame();

    se = stat_of(h_early); sf = stat_of(h_faulty);
    sl = stat_of(h_late);  ss = stat_of(h_slow);

    if (!se.live || !sf.live || !sl.live)
        inconclusive("a participant vanished from the registry -- nothing "
                     "below can be trusted");

    /* The NEGATIVE that carries the whole design: nobody ordered AFTER the
     * faulting participant lost a frame. A single guard around the loop would
     * make `late` and `slow` read 0 here. */
    ok(sl.calls == FRAMES,
       "no frame was lost by 'late', which is dispatched AFTER the faulting "
       "participant");
    ok(ss.calls == FRAMES,
       "no frame was lost by 'slow', last in the order, behind the fault");
    ok(se.calls == FRAMES,
       "no frame was lost by 'early', which is dispatched before it");

    /* The faulting one: disabled, by name, after exactly the limit. */
    ok(sf.faults == AOWL_REGION_FAULT_LIMIT,
       "'faulty' faulted exactly AOWL_REGION_FAULT_LIMIT times and then "
       "stopped being called");
    ok(sf.disabled == 1, "'faulty' is DISABLED in the finished state");
    ok(sf.calls == 0,
       "'faulty' recorded ZERO completed calls -- the fault detector cannot "
       "be satisfied by a callback that died");
    ok(c_faulty == AOWL_REGION_FAULT_LIMIT,
       "'faulty' was ENTERED exactly the fault limit and never again");
    ok(sf.reason[0] != 0, "'faulty' carries a reason string, not a bare flag");
    ok(log_has("faulty", "FAULTED"),
       "the log names 'faulty' specifically as having faulted");
    ok(log_has("faulty", "DISABLED"),
       "the log names 'faulty' specifically as having been disabled");
    ok(se.disabled == 0 && sl.disabled == 0 && ss.disabled == 0,
       "NO other participant was disabled -- 'disabled' is not a constant");

    /* MUTATION 4, inside this run: a draw outside a draw callback. */
    ok(aowl_region_box(0, 0, 1, 1, 1, 0) == AOWL_REGION_REFUSE_CLOSED,
       "a draw command submitted outside a DRAW callback is REFUSED");

    /* And the draw buffer still carries the survivors' work, plus what the
     * faulting participant managed to submit BEFORE it died. */
    {
        const AowlRegionCmd* cmds = 0;
        int32_t n = aowl_region_commands(&cmds), boxes = 0, fills = 0, txt = 0;
        for (i = 0; i < n; i++) {
            if (cmds[i].kind == AOWL_REGION_CMD_BOX)  boxes++;
            if (cmds[i].kind == AOWL_REGION_CMD_FILL) fills++;
            if (cmds[i].kind == AOWL_REGION_CMD_TEXT) txt++;
        }
        g_drawCmds = n;
        ok(boxes >= 1 && fills >= 1,
           "the last published frame still holds BOTH survivors' draw "
           "commands after twelve frames of a faulting neighbour");
        ok(txt == 0,
           "the dead participant contributes nothing to the LAST frame -- it "
           "is disabled, so it is not merely quiet, it is not called");
    }

    /* ================= MUTATION 2: a budget overrun ================== */
    printf("\nMUTATION 2 -- 'slow' burns 3000us against a 200us budget\n");
    unreg_all(); reset(); reg_all();
    g_makeItFault = 0; g_slowUs = 3000;
    for (i = 0; i < FRAMES; i++) aowl_region_frame();

    ss = stat_of(h_slow); se = stat_of(h_early);
    ok(ss.overruns > 0, "'slow' has its budget overruns COUNTED");
    ok(ss.maxUs > ss.budgetUs,
       "'slow' has a recorded worst frame above its declared budget");
    ok(log_has("slow", "OVERRAN"),
       "the log names 'slow' specifically as having overrun its budget -- "
       "not silently tolerated");
    ok(ss.throttled == 1 && ss.reason[0] != 0,
       "'slow' is THROTTLED in the finished state, with a reason");
    ok(ss.skipped > 0, "'slow' is actually being skipped, not just flagged");
    ok(se.overruns == 0 && se.throttled == 0,
       "'early' is NOT throttled and has NO overruns -- 'throttled' is not a "
       "constant either");
    ok(se.calls == FRAMES,
       "the well-behaved participants keep every frame while a neighbour is "
       "throttled");

    /* ================= MUTATION 3: dispatch inside a guard =========== */
    printf("\nMUTATION 3 -- the dispatcher is called from inside a live "
           "aowl_p_p_seh guard\n");
    {
        int32_t r = 12345;
        reset();
        aowl_p_p_seh((void*)nested_body, (void*)&r);
        ok(r == AOWL_REGION_REFUSE_NESTED,
           "dispatch REFUSES rather than nesting a guard that is not "
           "re-entrant");
        ok(log_has("REFUSED", "not re-entrant"),
           "and it says so, naming the reason");
        ok(aowl_seh_active == 0,
           "the shim's guard flag is left clean afterwards");
    }
    /* Re-entrancy: a participant driving the region from inside its callback. */
    ok(aowl_region_last_refusal() != 0,
       "the last refusal is recorded and readable");

    /* ===== MUTATION 3b: the real rider chain in aowlhost.nim ========= */
    printf("\nMUTATION 3b -- a PRIOR rider's guard, exactly as the "
           "shared PreloaderUI::Update chain runs one\n"
           "              before regionFired\n");
    unreg_all(); reset(); reg_all();
    g_makeItFault = 0; g_slowUs = 0;
    {
        int32_t r;
        int64_t base;

        /* (a) the prior rider returns normally -- debugUiFired on a good frame */
        r = 0;
        ok(aowl_p_p_seh((void*)prior_rider_ok, (void*)&r) != 0 && r == 1,
           "a prior rider's guard was entered and returned normally");
        ok(aowl_seh_active == 0,
           "the thread's guard flag is clear once that rider returned");
        base = c_early;
        ok(aowl_region_frame() == AOWL_REGION_OK,
           "dispatch after a normally-returning prior rider does NOT refuse");
        ok(c_early == base + 1,
           "and every participant actually ran that frame");

        /* (b) the prior rider FAULTS -- the case that leaves its guard through
         *     the VEH longjmp rather than a return. This is the one that would
         *     strand `aowl_seh_active` at 1 and make the region refuse for the
         *     rest of the session while logging nothing but its own refusal. */
        r = 0;
        /* The body sets `r` BEFORE it dies, so `r` proves only that it was
         * entered. Whether it RETURNED is knowable solely from the guard's own
         * value -- 0 on longjmp -- which is the same property the region's
         * fault detector rests on. */
        ok(aowl_p_p_seh((void*)prior_rider_faults, (void*)&r) == 0 && r == 1,
           "a prior rider was ENTERED and then FAULTED inside its own guard");
        ok(aowl_seh_active == 0,
           "the thread's guard flag is clear even after that rider FAULTED -- "
           "the VEH longjmp path disarms it, so the region is not stranded");
        base = c_early;
        ok(aowl_region_frame() == AOWL_REGION_OK,
           "dispatch after a FAULTING prior rider does NOT refuse");
        ok(c_early == base + 1,
           "and every participant still ran that frame");
        ok(!log_has("REFUSED", 0),
           "neither arrangement emitted a REFUSED line at all -- the region "
           "is not stranded by a prior rider, whether it returned or died");
    }

    /* ================= THE CONTROL =================================== */
    printf("\nCONTROL -- the identical harness with nothing misbehaving\n");
    unreg_all(); reset(); reg_all();
    g_makeItFault = 0; g_slowUs = 0;
    for (i = 0; i < FRAMES; i++) aowl_region_frame();

    se = stat_of(h_early); sf = stat_of(h_faulty);
    sl = stat_of(h_late);  ss = stat_of(h_slow);
    ok(sf.disabled == 0 && sf.faults == 0 && sf.calls == FRAMES,
       "with the fault removed, the SAME participant is neither disabled nor "
       "faulted -- so the disable check can fail, and is a check");
    ok(ss.throttled == 0 && ss.overruns == 0,
       "with the overrun removed, the SAME participant is not throttled -- so "
       "the budget check can fail, and is a check");
    ok(se.calls == FRAMES && sl.calls == FRAMES && ss.calls == FRAMES,
       "every participant ran every frame");
    ok(!log_has("FAULTED", 0) && !log_has("OVERRAN", 0),
       "the control run produced NO fault and NO overrun line");

    /* ================= ordering is deterministic ===================== */
    printf("\nORDERING\n");
    {
        const AowlRegionCmd* cmds = 0;
        int32_t n = aowl_region_commands(&cmds);
        int32_t firstOwner = n > 0 ? cmds[0].owner : -1;
        ok(n > 0 && firstOwner == h_early,
           "the first command of the frame belongs to the lowest-order "
           "participant, every time");
    }

    printf("\n%d checks, %d failure(s); %d draw commands in the mutation-1 "
           "frame, %lld dropped overall\n",
           checks, failures, g_drawCmds, (long long)aowl_region_dropped());
    if (failures) { printf("RESULT: FAIL\n"); return 1; }
    printf("RESULT: PASS\n");
    return 0;
}
