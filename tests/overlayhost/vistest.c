/* vistest.c -- the pure arithmetic behind the `visible` / `screenrect` verbs,
 * headless.
 *
 * WHAT THIS SETTLES, AND WHY IT IS WORTH A TEST
 * ---------------------------------------------
 * The F3 overlay investigation ran six rounds. Three of them were real pointer
 * bugs. The fourth outcome was worse: the walk SUCCEEDED -- clones made, nested
 * Canvas disabled, zero faults -- and nothing appeared. There was no way to ask
 * whether the result was visible, so a working walk and a broken one produced
 * the same evidence.
 *
 * `aowlspt_visible.h` is the arithmetic that now answers that. It can be got
 * wrong in exactly the ways that would make the new verbs confidently wrong:
 *
 *   * folding a CanvasGroup chain PAST a group with `ignoreParentGroups`,
 *     producing an alpha the renderer never uses;
 *   * treating "the back-buffer size has not been published yet" as "off
 *     screen", which is the same flattening (a check that cannot fail) that
 *     CLAUDE.md 9b is about;
 *   * calling a flipped rect off-screen because y1 < y0;
 *   * calling a NaN coordinate a definite answer in either direction.
 *
 * Every assertion below is a NEGATIVE or a tri-state discrimination: it is not
 * enough for a visible thing to report visible, an INVISIBLE thing and an
 * UNKNOWN thing must report differently from each other.
 *
 * Build:  gcc -O2 -I..\..\abi vistest.c -o vistest.exe
 * Run:    .\vistest.exe      (exit 0 = PASS, non-zero = number of failures)
 */
#include <stdio.h>
#include <stdint.h>

#include "aowlspt_visible.h"

static int failures = 0;

static void eq_int(const char* what, int got, int want) {
    if (got == want) { printf("ok    %s\n", what); return; }
    printf("error %s: got %d, wanted %d\n", what, got, want);
    failures++;
}
static void eq_dbl(const char* what, double got, double want) {
    double d = got - want;
    if (d < 0) d = -d;
    if (d < 1e-9) { printf("ok    %s\n", what); return; }
    printf("error %s: got %.9f, wanted %.9f\n", what, got, want);
    failures++;
}

/* ---- the alpha chain ------------------------------------------------ */

static void test_alpha(void) {
    /* No CanvasGroup anywhere: fully opaque, and OK -- "no group" is not
     * "could not look". */
    aowl_vis_alpha_reset();
    eq_int("alpha: empty chain is ok", aowl_vis_alpha_ok(), 1);
    eq_dbl("alpha: empty chain is 1.0", aowl_vis_alpha_value(), 1.0);
    eq_int("alpha: empty chain counted 0 groups", aowl_vis_alpha_count(), 0);

    /* Two groups, neither ignoring parents: the product. */
    aowl_vis_alpha_reset();
    eq_int("alpha: 0.5 does not close the chain", aowl_vis_alpha_push(0.5, 0), 0);
    eq_int("alpha: 0.5 again does not close",      aowl_vis_alpha_push(0.5, 0), 0);
    eq_dbl("alpha: 0.5 * 0.5", aowl_vis_alpha_value(), 0.25);
    eq_int("alpha: two groups counted", aowl_vis_alpha_count(), 2);
    eq_int("alpha: chain still open", aowl_vis_alpha_closed(), 0);

    /* THE ONE THAT MATTERS. A nearer group with ignoreParentGroups TERMINATES
     * the walk: the parent's 0.0 must NOT be folded in. A naive
     * multiply-everything implementation reports 0.0 here and would declare a
     * perfectly visible node invisible -- and the wrong REASON is worse than
     * no reason at all (fact #129). */
    aowl_vis_alpha_reset();
    eq_int("alpha: ignoreParentGroups closes the chain",
           aowl_vis_alpha_push(0.8, 1), 1);
    eq_int("alpha: a push after close is refused",
           aowl_vis_alpha_push(0.0, 0), 1);
    eq_dbl("alpha: ancestors past an ignoring group are NOT folded",
           aowl_vis_alpha_value(), 0.8);
    eq_int("alpha: chain reported closed", aowl_vis_alpha_closed(), 1);
    eq_int("alpha: closing is not an error", aowl_vis_alpha_ok(), 1);

    /* A NaN alpha means we read something that is not a CanvasGroup. That is
     * INCONCLUSIVE, and must be distinguishable from a genuine 0.0. */
    aowl_vis_alpha_reset();
    (void)aowl_vis_alpha_push(0.0 / 1.0, 0);
    eq_dbl("alpha: a real 0.0 folds to 0.0", aowl_vis_alpha_value(), 0.0);
    eq_int("alpha: a real 0.0 is a usable answer", aowl_vis_alpha_ok(), 1);

    aowl_vis_alpha_reset();
    {
        double zero = 0.0;
        double nan = zero / zero;
        eq_int("alpha: NaN closes the chain", aowl_vis_alpha_push(nan, 0), 1);
    }
    eq_int("alpha: NaN is NOT a usable answer", aowl_vis_alpha_ok(), 0);

    /* An out-of-range alpha is not silently clamped to a plausible number. */
    aowl_vis_alpha_reset();
    (void)aowl_vis_alpha_push(4.25, 0);
    eq_int("alpha: 4.25 is rejected, not clamped to 1.0", aowl_vis_alpha_ok(), 0);

    /* The cap holds. */
    aowl_vis_alpha_reset();
    {
        int i;
        for (i = 0; i < 200; i++) (void)aowl_vis_alpha_push(1.0, 0);
        eq_int("alpha: chain capped at AOWL_VIS_ALPHA_MAX",
               aowl_vis_alpha_count(), AOWL_VIS_ALPHA_MAX);
    }
}

/* ---- on-screen classification --------------------------------------- */

static void test_onscreen(void) {
    const int32_t SW = 3840, SH = 2160;   /* the size the region exports publish */

    eq_int("onscreen: centred rect is FULL",
           aowl_vis_onscreen(100, 100, 200, 200, SW, SH, 1), 2);
    eq_int("onscreen: rect straddling the left edge is PARTIAL",
           aowl_vis_onscreen(-50, 100, 200, 200, SW, SH, 1), 1);
    eq_int("onscreen: rect entirely left of the buffer is OFF",
           aowl_vis_onscreen(-500, 100, -10, 200, SW, SH, 1), 0);
    eq_int("onscreen: rect entirely above the buffer is OFF",
           aowl_vis_onscreen(100, 5000, 200, 5100, SW, SH, 1), 0);
    eq_int("onscreen: exactly the whole buffer is FULL",
           aowl_vis_onscreen(0, 0, SW, SH, SW, SH, 1), 2);

    /* A flipped rect is the SAME rect. A comparison that assumed y0<y1 would
     * report OFF for a perfectly visible node. */
    eq_int("onscreen: y-flipped rect is normalised, not called OFF",
           aowl_vis_onscreen(100, 200, 200, 100, SW, SH, 1), 2);
    eq_int("onscreen: x-flipped rect is normalised too",
           aowl_vis_onscreen(200, 100, 100, 200, SW, SH, 1), 2);

    /* THE FLATTENING THIS EXISTS TO PREVENT. An unpublished back-buffer size
     * must be UNKNOWN (-1), never OFF (0): a hardcoded or zero size is exactly
     * how a layout collapses into the corner and reports it as a finding. */
    eq_int("onscreen: size not known is UNKNOWN, not OFF",
           aowl_vis_onscreen(100, 100, 200, 200, SW, SH, 0), -1);
    eq_int("onscreen: zero screen width is UNKNOWN, not OFF",
           aowl_vis_onscreen(100, 100, 200, 200, 0, SH, 1), -1);
    {
        double zero = 0.0;
        double nan = zero / zero;
        eq_int("onscreen: a NaN corner is UNKNOWN, not OFF",
               aowl_vis_onscreen(nan, 100, 200, 200, SW, SH, 1), -1);
    }
    eq_int("onscreen: an absurd coordinate is UNKNOWN, not OFF",
           aowl_vis_onscreen(1e12, 100, 1e12 + 10, 200, SW, SH, 1), -1);
}

/* ---- degenerate rects and collapsed scale --------------------------- */

static void test_degenerate(void) {
    eq_int("degenerate: 100x40 is fine", aowl_vis_degenerate(100, 40), 0);
    eq_int("degenerate: zero width",     aowl_vis_degenerate(0, 40), 1);
    eq_int("degenerate: zero height",    aowl_vis_degenerate(100, 0), 1);
    eq_int("degenerate: sub-pixel height", aowl_vis_degenerate(100, 0.25), 1);
    eq_int("degenerate: negative size is a size", aowl_vis_degenerate(-100, -40), 0);
    {
        double zero = 0.0, nan = zero / zero;
        eq_int("degenerate: NaN is UNKNOWN, not degenerate",
               aowl_vis_degenerate(nan, 40), -1);
    }

    eq_int("scale: unit scale is not collapsed",
           aowl_vis_scale_collapsed(1.0, 1.0), 0);
    eq_int("scale: zero x collapses", aowl_vis_scale_collapsed(0.0, 1.0), 1);
    eq_int("scale: zero y collapses", aowl_vis_scale_collapsed(1.0, 0.0), 1);
    eq_int("scale: a mirrored -1 is NOT collapsed",
           aowl_vis_scale_collapsed(-1.0, 1.0), 0);
    {
        double zero = 0.0, nan = zero / zero;
        eq_int("scale: NaN is UNKNOWN, not collapsed",
               aowl_vis_scale_collapsed(nan, 1.0), -1);
    }

    eq_int("alpha-cut: 1.0 is visible",  aowl_vis_alpha_invisible(1.0), 0);
    eq_int("alpha-cut: 0.0 is invisible", aowl_vis_alpha_invisible(0.0), 1);
    eq_int("alpha-cut: 1/255 survives an 8-bit blend",
           aowl_vis_alpha_invisible(1.0 / 255.0), 0);
    eq_int("alpha-cut: half of 1/255 does not",
           aowl_vis_alpha_invisible(0.5 / 255.0), 1);
    {
        double zero = 0.0, nan = zero / zero;
        eq_int("alpha-cut: NaN is UNKNOWN", aowl_vis_alpha_invisible(nan), -1);
    }
}

int main(void) {
    test_alpha();
    test_onscreen();
    test_degenerate();
    if (failures == 0) {
        printf("\nPASS -- visibility arithmetic\n");
        return 0;
    }
    printf("\nFAIL -- %d assertion(s)\n", failures);
    return failures;
}
