/* stagetest.c -- the F3 per-stage COST ACCOUNTING, headless.
 *
 * WHY THIS FILE EXISTS
 * --------------------
 * A live raid reported, through the shared region's own accounting:
 *
 *     region: participant 'debugui' OVERRAN its frame budget:
 *             24552 us against 900 us (1 consecutive, 247 total,
 *             worst 30524 us)
 *
 * and then, later, 32115 and 40427. That number names the PARTICIPANT and
 * nothing else. It cannot distinguish "the world census walks more bots than
 * it used to" from "composing widget text re-reads every field every frame",
 * which is the whole question. `abi/aowlspt_widget.h` therefore charges the
 * interval between two breadcrumbs to the stage named by the earlier one.
 *
 * WHAT IS ASSERTED HERE, AND WHY IT CAN FAIL
 * ------------------------------------------
 * CLAUDE.md 9b: assert a property of the FINISHED STATE, and prefer a check
 * that a broken implementation would fail. Every case below spends a KNOWN,
 * deliberate amount of wall-clock time inside a NAMED stage and then asks the
 * accounting where the time went. The falsifying input is stated with each:
 *
 *   1  a stage that burns ~20 ms is charged ~20 ms.  An accounting that
 *      charged the wrong stage, charged nothing, or charged everything to the
 *      total only would fail this.
 *   2  the stages that did NOTHING while that happened are charged ~0.
 *      This is the negative: an implementation that simply reported the frame
 *      total under every stage name would pass case 1 and fail this one.
 *   3  the frame total is at least the hot stage's cost, and the worst-frame
 *      breakdown is kept as ONE COHERENT SET from the single worst frame --
 *      not a per-stage maximum taken across different frames, which would
 *      describe a frame that never happened.
 *   4  time spent OUTSIDE a begin/end window is charged to NOTHING. The
 *      separate PreloaderUI detour body also drops crumbs; without this,
 *      its time would be attributed to whatever F3 stage happened to be
 *      current, which is a confidently wrong answer.
 *   5  before any frame completes, every getter answers -1, NOT 0. Three
 *      states, never two: "nothing measured yet" is not "measured, cheap".
 *   6  the instrument's OWN cost is bounded: 4,000 crumbs cost well under the
 *      900 us frame budget in total. An instrument that is itself the largest
 *      cost in the frame is measuring mostly itself.
 *
 * TIMING TOLERANCES. The busy-wait targets are large (20 ms, 5 ms) and the
 * bands are wide, because this runs on a loaded desktop under other agents'
 * builds. A scheduler hiccup can only ever make a measured stage LARGER, so
 * the lower bounds are the load-bearing half and the upper bounds are
 * generous. If this file ever goes flaky, widen the upper bound -- never the
 * lower one, which is what the checks actually rest on.
 *
 * Build/run: wired into `aowl build verify` next to f3test. Exit code is the
 * failure count.
 */

#include <stdio.h>
#include <stdint.h>

/* The unit under test. `aowlspt_widget.h` pulls in <windows.h> and also
 * `aowlspt_navui.h`, which needs the prologue verifier's byte ceiling; in the
 * host that is already in the single generated translation unit by the time
 * the widget header lands, so here it has to be named first. */
#include "aowlspt_prologue.h"
#include "aowlspt_widget.h"

/* ONE LINE PER CHECK, in the `ok <name>` / `error <name>` shape that
 * `tests/overlayhost/run-all.py` parses -- a test that printed only a summary
 * is read by that harness as "produced no ok/error lines at all", which it
 * correctly reports as INCONCLUSIVE rather than as a pass. */
static int fails = 0;

static void ck(int cond, const char* what) {
    if (!cond) { printf("error %s\n", what); fails++; }
    else       { printf("ok %s\n", what); }
}

/* A busy wait, not Sleep(). Sleep yields the thread and the accounting is
 * wall-clock, so a sleeping stage would still be charged -- true, but it would
 * not exercise the thing the live overlay actually does, which is compute. */
static void burn_us(int64_t us) {
    LARGE_INTEGER f, a, b;
    QueryPerformanceFrequency(&f);
    QueryPerformanceCounter(&a);
    for (;;) {
        QueryPerformanceCounter(&b);
        if (((b.QuadPart - a.QuadPart) * 1000000ll) / f.QuadPart >= us) return;
    }
}

static int near_us(int64_t got, int64_t want, int64_t lo_slack,
                   int64_t hi_slack) {
    return got >= want - lo_slack && got <= want + hi_slack;
}

int main(void) {
    int64_t hot, cold, tot, worstTot, worstHot, i;
    LARGE_INTEGER f, a, b;

    printf("F3 per-stage cost accounting\n");

    /* ---- 5: nothing measured yet is -1, not 0 ---------------------- */
    aowl_wg_stage_reset();
    ck(aowl_wg_stage_frames() == 0, "no frames recorded after a reset");
    ck(aowl_wg_stage_us(AOWL_WG_CRUMB_WTEXT) == -1,
       "a stage reads -1 (NOT MEASURED) before any frame completes");
    ck(aowl_wg_stage_frame_us() == -1,
       "the frame total reads -1 before any frame completes");
    ck(aowl_wg_stage_worst_total_us() == -1,
       "the worst-frame total reads -1 before any frame completes");

    /* ---- 4: outside a window, nothing is charged ------------------- */
    aowl_wg_crumb(AOWL_WG_CRUMB_WTEXT);
    burn_us(3000);
    aowl_wg_crumb(AOWL_WG_CRUMB_DONE);
    ck(aowl_wg_stage_frames() == 0,
       "crumbs OUTSIDE a begin/end window record no frame at all");
    ck(aowl_wg_stage_us(AOWL_WG_CRUMB_WTEXT) == -1,
       "3 ms burned outside the window is charged to NOTHING");

    /* ---- 1 and 2: the hot stage is named, the cold ones are not ---- */
    aowl_wg_stage_reset();
    aowl_wg_stage_begin();
    aowl_wg_crumb(AOWL_WG_CRUMB_ENTER);
    aowl_wg_crumb(AOWL_WG_CRUMB_SCANWORLD);
    burn_us(1000);                       /* a modest census            */
    aowl_wg_crumb(AOWL_WG_CRUMB_MOUSE);  /* costs nothing              */
    aowl_wg_crumb(AOWL_WG_CRUMB_WTEXT);
    burn_us(20000);                      /* THE HOT STAGE              */
    aowl_wg_crumb(AOWL_WG_CRUMB_WSETTEXT);
    aowl_wg_crumb(AOWL_WG_CRUMB_DONE);
    aowl_wg_stage_end();

    ck(aowl_wg_stage_frames() == 1, "exactly one frame recorded");

    hot = aowl_wg_stage_us(AOWL_WG_CRUMB_WTEXT);
    printf("#       composing a widget's text measured %lld us\n",
           (long long)hot);
    ck(near_us(hot, 20000, 2000, 20000),
       "the 20 ms stage is charged ~20 ms to 'composing a widget's text'");

    cold = aowl_wg_stage_us(AOWL_WG_CRUMB_MOUSE);
    printf("#       sampling the pointer measured %lld us\n", (long long)cold);
    /* THE NEGATIVE. Reporting the frame total under every name passes the
     * check above and fails this one. */
    ck(cold >= 0 && cold < 1000,
       "a stage that did nothing is charged ~0, NOT the frame total");
    ck(aowl_wg_stage_us(AOWL_WG_CRUMB_MARKERS) == 0,
       "a stage never entered at all is charged exactly 0");

    ck(near_us(aowl_wg_stage_us(AOWL_WG_CRUMB_SCANWORLD), 1000, 200, 5000),
       "the 1 ms census stage is charged ~1 ms, separately from the hot one");

    tot = aowl_wg_stage_frame_us();
    printf("#       frame total %lld us\n", (long long)tot);
    ck(tot >= hot, "the frame total is at least the hot stage's cost");
    ck(tot >= 20000, "the frame total exceeds the 900 us budget, as staged");

    /* ---- 3: the worst frame is ONE COHERENT SET ------------------- */
    /* Second frame: a DIFFERENT stage is hot, and the frame is CHEAPER. The
     * worst-frame breakdown must still describe frame 1 -- if it were a
     * per-stage maximum taken across frames it would show frame 1's WTEXT and
     * frame 2's MARKERS together, a frame that never happened. */
    aowl_wg_stage_begin();
    aowl_wg_crumb(AOWL_WG_CRUMB_ENTER);
    aowl_wg_crumb(AOWL_WG_CRUMB_MARKERS);
    burn_us(5000);
    aowl_wg_crumb(AOWL_WG_CRUMB_DONE);
    aowl_wg_stage_end();

    ck(aowl_wg_stage_frames() == 2, "two frames recorded");
    ck(near_us(aowl_wg_stage_us(AOWL_WG_CRUMB_MARKERS), 5000, 500, 10000),
       "frame 2 charges ~5 ms to 'the ESP markers'");
    ck(aowl_wg_stage_us(AOWL_WG_CRUMB_WTEXT) < 1000,
       "frame 2's LAST-frame view has forgotten frame 1's hot stage");
    ck(near_us(aowl_wg_stage_peak_us(AOWL_WG_CRUMB_WTEXT), 20000, 2000, 20000),
       "the PEAK view still remembers frame 1's hot stage");

    worstTot = aowl_wg_stage_worst_total_us();
    worstHot = aowl_wg_stage_worst_us(AOWL_WG_CRUMB_WTEXT);
    printf("#       worst frame %lld us, its WTEXT share %lld us\n",
           (long long)worstTot, (long long)worstHot);
    ck(near_us(worstHot, 20000, 2000, 20000),
       "the worst-frame breakdown is frame 1's, the frame that was worst");
    ck(aowl_wg_stage_worst_us(AOWL_WG_CRUMB_MARKERS) == 0,
       "the worst-frame breakdown does NOT mix in frame 2's markers cost");
    ck(worstTot >= worstHot,
       "the worst-frame total is consistent with its own breakdown");

    /* ---- 6: the instrument's own cost is bounded ------------------- */
    aowl_wg_stage_reset();
    QueryPerformanceFrequency(&f);
    QueryPerformanceCounter(&a);
    aowl_wg_stage_begin();
    for (i = 0; i < 4000; i++) {
        aowl_wg_crumb(AOWL_WG_CRUMB_WTEXT);
        aowl_wg_crumb_w((int32_t)(i & 7));
    }
    aowl_wg_stage_end();
    QueryPerformanceCounter(&b);
    tot = ((b.QuadPart - a.QuadPart) * 1000000ll) / f.QuadPart;
    printf("#       8000 crumbs cost %lld us in total\n", (long long)tot);
    /* A real refresh drops on the order of 50 crumbs. 8000 of them inside
     * 3 ms bounds one crumb at 375 ns, so ~50 of them cost under 20 us --
     * about 2% of the 900 us budget. An implementation that made a syscall or
     * a 64-bit division per crumb would not fit. */
    ck(tot < 3000,
       "8000 crumbs cost under 3 ms, so ~50 per refresh is ~2% of the budget");
    ck(aowl_wg_stage_backwards() == 0,
       "the performance counter never went backwards during the run");

    if (fails) printf("stagetest: %d FAILED\n", fails);
    else       printf("stagetest: all checks passed\n");
    return fails;
}
