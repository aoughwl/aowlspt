/* aowlspt_visible.h -- THE PURE ARITHMETIC BEHIND "is it actually on screen".
 *
 * WHY THIS FILE EXISTS SEPARATELY FROM THE VERBS THAT USE IT
 * ----------------------------------------------------------
 * Every managed call in the visibility verbs can only be exercised inside a
 * running Tarkov client. The arithmetic those calls feed -- folding a
 * CanvasGroup alpha chain, deciding whether a pixel rect is on the back
 * buffer, deciding whether a rect is degenerate -- is PURE, and pure logic
 * that can only be tested in the client is logic that never gets tested.
 *
 * So it lives here, as free functions over doubles with no pointer to
 * anything, and `tests/overlayhost/vistest.c` compiles this header on its own
 * and asserts against it offline. The client-side code then contains no
 * arithmetic of its own to get wrong.
 *
 * THE TRI-STATE IS THE POINT (CLAUDE.md 9b). Nothing here returns a plain
 * boolean where "I could not look" is possible. `aowl_vis_alpha_ok` is
 * separate from `aowl_vis_alpha_value`; `aowl_vis_onscreen` has a distinct
 * UNKNOWN return for an unpublished back-buffer size. A verb that flattens
 * "not visible" and "could not determine" into one answer is the exact defect
 * that let a successful F3 clone walk report success while nothing drew.
 *
 * NIMONY CONSTRAINT: nimony cannot hand out the address of an array element,
 * which is why the alpha chain is an incremental push/reset over statics
 * rather than an array parameter -- the same reason `aowl_du_sret_out` in
 * aowlspt_debugui.h is shaped the way it is. The host is single-threaded on
 * this path (one Unity-thread detour, one command at a time), so there is no
 * sharing question. */

#ifndef AOWLSPT_VISIBLE_H
#define AOWLSPT_VISIBLE_H

#include <stdint.h>

/* ------------------------------------------------------------------ */
/* The CanvasGroup alpha chain.                                        */
/*                                                                     */
/* Unity multiplies the alpha of every CanvasGroup from the object     */
/* upward, and STOPS at the first group whose `ignoreParentGroups` is  */
/* set -- that group's own alpha still applies, its ancestors' do not. */
/* Folding past such a group reports an alpha the renderer never uses, */
/* which reads as a correct number and is wrong.                       */
/*                                                                     */
/* Push order is NEAREST FIRST (the node's own group, then upward).    */
/* ------------------------------------------------------------------ */

#define AOWL_VIS_ALPHA_MAX 64

static double  aowl_vis_alpha_acc   = 1.0;
static int32_t aowl_vis_alpha_n     = 0;
static int32_t aowl_vis_alpha_stop  = 0;  /* a group said ignoreParentGroups  */
static int32_t aowl_vis_alpha_bad   = 0;  /* a NaN/absurd alpha was pushed    */

static void aowl_vis_alpha_reset(void) {
    aowl_vis_alpha_acc  = 1.0;
    aowl_vis_alpha_n    = 0;
    aowl_vis_alpha_stop = 0;
    aowl_vis_alpha_bad  = 0;
}

/* Returns 1 when the chain is CLOSED (this group ignores its parents, or the
 * cap was reached, or the value was unusable) and the caller should stop
 * walking; 0 to keep going. */
static int32_t aowl_vis_alpha_push(double alpha, int32_t ignore_parent_groups) {
    if (aowl_vis_alpha_stop || aowl_vis_alpha_bad) return 1;
    if (aowl_vis_alpha_n >= AOWL_VIS_ALPHA_MAX) { aowl_vis_alpha_stop = 1; return 1; }
    /* NaN is the only value not equal to itself. An alpha outside [0,1] is not
     * clamped silently: Unity does clamp, but a value of 4.2 here means we read
     * something that is not a CanvasGroup, and pretending it is 1.0 would hide
     * that. It is recorded as unusable instead. */
    if (alpha != alpha || alpha < -0.001 || alpha > 1.001) {
        aowl_vis_alpha_bad = 1;
        return 1;
    }
    if (alpha < 0.0) alpha = 0.0;
    if (alpha > 1.0) alpha = 1.0;
    aowl_vis_alpha_acc *= alpha;
    aowl_vis_alpha_n++;
    if (ignore_parent_groups) { aowl_vis_alpha_stop = 1; return 1; }
    return 0;
}

static int32_t aowl_vis_alpha_ok(void)    { return aowl_vis_alpha_bad ? 0 : 1; }
static double  aowl_vis_alpha_value(void) { return aowl_vis_alpha_acc; }
static int32_t aowl_vis_alpha_count(void) { return aowl_vis_alpha_n; }
static int32_t aowl_vis_alpha_closed(void){ return aowl_vis_alpha_stop; }

/* ------------------------------------------------------------------ */
/* Screen-rect geometry.                                               */
/* ------------------------------------------------------------------ */

/* THREE OUTCOMES, NEVER TWO.
 *   -1  UNKNOWN   -- the back-buffer size has not been published, or a
 *                    coordinate is NaN/absurd. NOT "off screen".
 *    0  OFF       -- the rect does not intersect the back buffer at all.
 *    1  PARTIAL   -- it intersects but is not wholly inside.
 *    2  FULL      -- wholly inside.
 *
 * Coordinates are Unity screen pixels: ORIGIN BOTTOM-LEFT, y up. (x0,y0) is
 * the lower-left corner and (x1,y1) the upper-right; they are normalised here
 * because a flipped RectTransform legitimately produces them the other way
 * round and a naive comparison would call that "off screen". */
static int32_t aowl_vis_onscreen(double x0, double y0, double x1, double y1,
                                 int32_t sw, int32_t sh, int32_t size_known) {
    double t;
    if (!size_known || sw <= 0 || sh <= 0) return -1;
    if (x0 != x0 || y0 != y0 || x1 != x1 || y1 != y1) return -1;
    if (x0 < -1.0e9 || x0 > 1.0e9 || y0 < -1.0e9 || y0 > 1.0e9) return -1;
    if (x1 < -1.0e9 || x1 > 1.0e9 || y1 < -1.0e9 || y1 > 1.0e9) return -1;
    if (x1 < x0) { t = x0; x0 = x1; x1 = t; }
    if (y1 < y0) { t = y0; y0 = y1; y1 = t; }
    if (x1 <= 0.0 || y1 <= 0.0 || x0 >= (double)sw || y0 >= (double)sh) return 0;
    if (x0 >= 0.0 && y0 >= 0.0 && x1 <= (double)sw && y1 <= (double)sh) return 2;
    return 1;
}

/* A rect thinner than half a pixel in either axis draws nothing, whatever else
 * is true of it. This was one of the invisible layers in the version-label
 * saga: a correct, active, correctly-parented label with a zero-size
 * RectTransform. Returns 1 for degenerate, 0 for not, -1 for unusable input. */
static int32_t aowl_vis_degenerate(double w, double h) {
    if (w != w || h != h) return -1;
    if (w < -1.0e9 || w > 1.0e9 || h < -1.0e9 || h > 1.0e9) return -1;
    if (w < 0.0) w = -w;
    if (h < 0.0) h = -h;
    return (w < 0.5 || h < 0.5) ? 1 : 0;
}

/* A zero (or mirrored-to-zero) lossy scale in x or y collapses the node to
 * nothing on screen even when its rect is a sane size. Same tri-state. */
static int32_t aowl_vis_scale_collapsed(double sx, double sy) {
    if (sx != sx || sy != sy) return -1;
    if (sx < 0.0) sx = -sx;
    if (sy < 0.0) sy = -sy;
    if (sx > 1.0e9 || sy > 1.0e9) return -1;
    return (sx < 1.0e-4 || sy < 1.0e-4) ? 1 : 0;
}

/* Is this alpha low enough that nothing reaches the frame buffer? Unity's own
 * cutoff for a Graphic is a colour alpha of 0; the 1/255 threshold here is the
 * smallest value that can survive an 8-bit blend, so anything below it is
 * genuinely invisible rather than merely faint. */
static int32_t aowl_vis_alpha_invisible(double a) {
    if (a != a) return -1;
    return (a < (1.0 / 255.0)) ? 1 : 0;
}

#endif /* AOWLSPT_VISIBLE_H */
