/* tests/overlayhost/mapstest.c -- offline checks for the maps overlay maths.
 *
 * Modelled on f3test.c: no client, no D3D, no game memory. Every assertion
 * here is about the FINISHED coordinate, not about whether a call ran.
 *
 * Each case is written so that a plausible WRONG implementation fails it:
 *
 *   * north-up sign -- a point due north must land ABOVE the pane centre.
 *     A mirrored map (the +Z sign flipped) produces a perfectly reasonable
 *     picture and fails this.
 *   * scale -- a point at exactly half the span must land exactly on the pane
 *     edge, not merely "somewhere inside". A radius/diameter mixup is a factor
 *     of two that looks fine until you compare with the real map.
 *   * rotation -- with the player facing east, a contact due north must appear
 *     on the LEFT. Getting the rotation sense backwards mirrors the radar.
 *   * the indicator clamp -- a marker for an off-screen contact must land ON
 *     the margin rectangle's boundary (not inside it, not past it) and on the
 *     correct side; and a point BEHIND the camera must be marked on the
 *     opposite side from where its mirrored projection would put it.
 *   * tile selection -- the row axis must invert against +Z, and an
 *     out-of-pyramid point must be REFUSED rather than clamped to an edge
 *     tile, because a clamped tile is a confidently wrong picture.
 */
#include <stdio.h>
#include <math.h>
#include "../../mods/maps/sp/mapmath.h"

static int g_fail = 0, g_pass = 0;

static void ok(int cond, const char* what)
{
    if (cond) { g_pass++; }
    else { g_fail++; printf("FAIL: %s\n", what); }
}

static void near(float got, float want, float tol, const char* what)
{
    if (fabs((double)(got - want)) <= (double)tol) { g_pass++; }
    else {
        g_fail++;
        printf("FAIL: %s (got %.4f, want %.4f, tol %.4f)\n",
               what, got, want, tol);
    }
}

/* ---------------------------------------------------------------- topdown */

static void test_topdown(void)
{
    /* A 200px pane at (100, 50) spanning 400 m, centred on the world origin.
     * 1 metre is therefore exactly 0.5 px. */
    const float px = 100.0f, py = 50.0f, size = 200.0f, span = 400.0f;
    MmPt p;

    p = mm_topdown(0.0f, 0.0f, 0.0f, 0.0f, px, py, size, span, 0.0f);
    near(p.x, 200.0f, 0.001f, "centre maps to pane centre x");
    near(p.y, 150.0f, 0.001f, "centre maps to pane centre y");

    /* Due NORTH (+Z 100 m) must go UP: y decreases. */
    p = mm_topdown(0.0f, 100.0f, 0.0f, 0.0f, px, py, size, span, 0.0f);
    near(p.x, 200.0f, 0.001f, "north does not move x");
    near(p.y, 100.0f, 0.001f, "north moves UP by 50px (not down)");
    ok(p.y < 150.0f, "north is above centre -- the map is not mirrored");

    /* Due EAST (+X 100 m) must go RIGHT. */
    p = mm_topdown(100.0f, 0.0f, 0.0f, 0.0f, px, py, size, span, 0.0f);
    near(p.x, 250.0f, 0.001f, "east moves RIGHT by 50px");
    ok(p.x > 200.0f, "east is right of centre");

    /* Exactly half a span north lands exactly on the pane's TOP edge.
     * A radius/diameter confusion puts it at the quarter mark instead. */
    p = mm_topdown(0.0f, span * 0.5f, 0.0f, 0.0f, px, py, size, span, 0.0f);
    near(p.y, py, 0.001f, "half a span north lands on the pane's top edge");
    ok(mm_in_rect(p, px, py, size, size), "that edge point is inside the pane");

    /* Just beyond half a span is OUTSIDE -- mm_topdown does not clamp. */
    p = mm_topdown(0.0f, span * 0.5f + 1.0f, 0.0f, 0.0f, px, py, size, span,
                   0.0f);
    ok(!mm_in_rect(p, px, py, size, size),
       "beyond half a span is outside the pane (topdown must not clamp)");

    /* Off-centre: the pane follows the centre, so a contact AT the centre
     * point always renders at the pane's middle whatever the world coords. */
    p = mm_topdown(1234.0f, -567.0f, 1234.0f, -567.0f, px, py, size, span,
                   0.0f);
    near(p.x, 200.0f, 0.001f, "off-origin centre still maps to pane centre x");
    near(p.y, 150.0f, 0.001f, "off-origin centre still maps to pane centre y");

    /* Rotation. `rot` is the HEADING itself (0 = +Z north, increasing toward
     * +X east), not the inverse rotation to apply -- the two readings differ
     * only by a mirror, and both look plausible on screen, so this is pinned
     * here. Facing east, a contact due north is on your LEFT. */
    {
        const float halfPi = 1.5707963f;
        p = mm_topdown(0.0f, 100.0f, 0.0f, 0.0f, px, py, size, span, halfPi);
        ok(p.x < 200.0f - 1.0f,
           "facing east, a northern contact is to the LEFT");
        near(p.y, 150.0f, 0.01f, "facing east, a northern contact is level");
    }

    /* A zero span must not divide by zero and must not scatter points. */
    p = mm_topdown(500.0f, 500.0f, 0.0f, 0.0f, px, py, size, 0.0f, 0.0f);
    near(p.x, 200.0f, 0.001f, "zero span collapses to centre, not NaN");
    ok(p.y == p.y, "zero span produces no NaN");
}

/* ------------------------------------------------------------- dist2d/cull */

static void test_dist(void)
{
    near(mm_dist2d(0.0f, 0.0f, 3.0f, 4.0f), 5.0f, 0.001f, "3-4-5 planar");
    near(mm_dist2d(10.0f, -10.0f, 10.0f, -10.0f), 0.0f, 0.001f, "self is zero");
}

/* ------------------------------------------------------------- indicator */

static void test_indicator(void)
{
    const float W = 1920.0f, H = 1080.0f, inset = 40.0f;
    MmPt o;
    int off = -1;

    /* A point comfortably on screen is passed through untouched and reported
     * as NOT clamped. */
    ok(mm_indicator(1000.0f, 500.0f, 0, W, H, inset, &o, &off),
       "on-screen point accepted");
    near(o.x, 1000.0f, 0.001f, "on-screen x untouched");
    near(o.y, 500.0f, 0.001f, "on-screen y untouched");
    ok(off == 0, "on-screen point reported as NOT clamped");

    /* Far to the RIGHT: must clamp exactly onto the right margin, and stay
     * vertically centred because it was level with the centre. */
    off = -1;
    ok(mm_indicator(5000.0f, 540.0f, 0, W, H, inset, &o, &off),
       "far-right point accepted");
    near(o.x, W - inset, 0.01f, "clamped ONTO the right margin, not past it");
    near(o.y, H * 0.5f, 0.01f, "level contact stays vertically centred");
    ok(off == 1, "far-right point reported as clamped");

    /* Far to the LEFT. */
    off = -1;
    ok(mm_indicator(-5000.0f, 540.0f, 0, W, H, inset, &o, &off),
       "far-left point accepted");
    near(o.x, inset, 0.01f, "clamped onto the left margin");
    ok(off == 1, "far-left point reported as clamped");

    /* Far ABOVE: the vertical edge must win, not the horizontal one. */
    off = -1;
    ok(mm_indicator(960.0f, -5000.0f, 0, W, H, inset, &o, &off),
       "far-above point accepted");
    near(o.y, inset, 0.01f, "clamped onto the TOP margin");
    near(o.x, W * 0.5f, 0.01f, "directly above stays horizontally centred");

    /* A corner-ward contact must land on the margin RECTANGLE -- i.e. exactly
     * one of its coordinates is on a margin and neither is past one. This is
     * the case a naive per-axis clamp gets wrong by producing a point outside
     * the rectangle on the other axis. */
    off = -1;
    ok(mm_indicator(9000.0f, 9000.0f, 0, W, H, inset, &o, &off),
       "corner-ward point accepted");
    ok(o.x <= W - inset + 0.01f && o.x >= inset - 0.01f,
       "corner-ward x within the margin rect");
    ok(o.y <= H - inset + 0.01f && o.y >= inset - 0.01f,
       "corner-ward y within the margin rect");
    ok(fabs((double)(o.x - (W - inset))) < 0.01
       || fabs((double)(o.y - (H - inset))) < 0.01,
       "corner-ward point sits ON an edge of the margin rect");

    /* BEHIND the camera. Its projection lands to the RIGHT of centre, but the
     * contact is really to the LEFT, so the marker must go LEFT. An
     * implementation that trusts the mirrored projection puts it right and
     * points the player exactly the wrong way -- this is the whole reason
     * `behind` is a parameter. */
    off = -1;
    ok(mm_indicator(1500.0f, 540.0f, 1, W, H, inset, &o, &off),
       "behind-camera point accepted");
    ok(o.x < W * 0.5f, "behind-camera marker is on the OPPOSITE side");
    near(o.x, inset, 0.01f, "behind-camera marker clamps to the left margin");
    ok(off == 1, "behind-camera point is always reported as clamped");

    /* Behind AND dead centre: no direction exists, so it must refuse rather
     * than invent one. */
    ok(!mm_indicator(W * 0.5f, H * 0.5f, 1, W, H, inset, &o, &off),
       "behind and dead-centre is REFUSED, not given an arbitrary direction");

    /* A degenerate screen smaller than its own margins is refused. */
    ok(!mm_indicator(10.0f, 10.0f, 0, 50.0f, 50.0f, inset, &o, &off),
       "a screen narrower than twice the inset is refused");
}

/* ------------------------------------------------------- bearing fallback */

static void test_bearing(void)
{
    const float W = 1920.0f, H = 1080.0f;
    MmPt o;

    /* Due north, north-up: straight above centre. */
    ok(mm_bearing_ring(0.0f, 100.0f, 0.0f, 0.0f, 0.0f, W, H, 0.35f, &o),
       "north bearing accepted");
    near(o.x, W * 0.5f, 0.01f, "north bearing is horizontally centred");
    ok(o.y < H * 0.5f, "north bearing is ABOVE centre");
    near(o.y, H * 0.5f - H * 0.35f, 0.01f, "north bearing sits on the ring");

    /* Distance must not change the bearing -- only direction matters. */
    {
        MmPt far_;
        ok(mm_bearing_ring(0.0f, 9999.0f, 0.0f, 0.0f, 0.0f, W, H, 0.35f, &far_),
           "distant north bearing accepted");
        near(far_.x, o.x, 0.01f, "ring position is distance-independent (x)");
        near(far_.y, o.y, 0.01f, "ring position is distance-independent (y)");
    }

    /* Coincident: no bearing exists, so refuse. */
    ok(!mm_bearing_ring(5.0f, 5.0f, 5.0f, 5.0f, 0.0f, W, H, 0.35f, &o),
       "a coincident contact has no bearing and is refused");
}

/* ------------------------------------------------------------ tile index */

static void test_tiles(void)
{
    int c = -1, r = -1;
    /* An 8x8 pyramid of 100 m tiles with its origin at (-400, -400): the
     * world square (-400..400) on both axes. */
    const float ox = -400.0f, oz = -400.0f, ts = 100.0f;

    ok(mm_tile_index(-395.0f, -395.0f, ox, oz, ts, 8, 8, &c, &r),
       "south-west corner is inside the pyramid");
    ok(c == 0, "south-west is column 0");
    ok(r == 7, "south-west is the BOTTOM row (row axis inverts against +Z)");

    ok(mm_tile_index(395.0f, 395.0f, ox, oz, ts, 8, 8, &c, &r),
       "north-east corner is inside the pyramid");
    ok(c == 7, "north-east is column 7");
    ok(r == 0, "north-east is the TOP row");

    ok(mm_tile_index(5.0f, 5.0f, ox, oz, ts, 8, 8, &c, &r), "centre is inside");
    ok(c == 4, "centre column");
    ok(r == 3, "centre row");

    /* Outside must be REFUSED, not clamped: a clamped tile draws the wrong
     * part of the map with total confidence. */
    ok(!mm_tile_index(10000.0f, 0.0f, ox, oz, ts, 8, 8, &c, &r),
       "a point east of the pyramid is refused, not clamped");
    ok(!mm_tile_index(0.0f, -10000.0f, ox, oz, ts, 8, 8, &c, &r),
       "a point south of the pyramid is refused, not clamped");
    ok(!mm_tile_index(0.0f, 0.0f, ox, oz, 0.0f, 8, 8, &c, &r),
       "a zero tile size is refused, not divided by");
    ok(!mm_tile_index(0.0f, 0.0f, ox, oz, ts, 0, 0, &c, &r),
       "an empty pyramid is refused");
}

int main(void)
{
    test_topdown();
    test_dist();
    test_indicator();
    test_bearing();
    test_tiles();
    printf("mapstest: %d passed, %d failed\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
