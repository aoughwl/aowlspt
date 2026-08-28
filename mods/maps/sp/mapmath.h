/* mods/maps/sp/mapmath.h -- the PURE arithmetic behind the in-game map, the
 * radar and the directional indicators.
 *
 * It is a separate header for one reason: none of it may be verifiable only by
 * looking at the screen. Every function here is a total function of its
 * arguments -- no globals, no game memory, no allocation, no draw calls -- so
 * `tests/overlayhost/mapstest.c` can assert the FINISHED result (a pixel lands
 * where a known world point must land) offline, with no client running. The
 * draw code in sp/hud.nim is then only submission: it decides colours and
 * rectangles, and every coordinate in it came from here.
 *
 * Coordinate conventions, stated once:
 *   * World is Unity's: X right, Y UP, Z forward. Top-down work uses (X, Z)
 *     and Y is elevation only.
 *   * Screen is the region's: pixels, origin TOP-LEFT, +Y DOWN. That is why
 *     every mapping below negates the world Z term -- north (+Z) must go UP
 *     the screen, and getting that sign wrong produces a mirrored map that
 *     still looks plausible, which is the failure this project cares about.
 */
#ifndef AOWL_MAPMATH_H
#define AOWL_MAPMATH_H

#include <math.h>

typedef struct { float x, y; } MmPt;

/* --- top-down projection ----------------------------------------------
 * Map a world (wx, wz) into a square pane of side `size` whose top-left is
 * (px, py), where the pane spans `spanM` metres across and is centred on the
 * world point (cx, cz).
 *
 * `rot` is the viewer's HEADING, in radians, measured 0 = +Z (north) and
 * increasing toward +X (east) -- NOT the inverse rotation to apply. Pass the
 * heading straight in and the pane comes out heading-up; pass 0 and it comes
 * out north-up. The distinction is worth stating because both readings produce
 * a smooth, plausible, MIRRORED map, and the offline test pins it: facing east
 * (rot = +pi/2), a contact due north must appear to the LEFT.
 *
 * Total: every input produces an output. Whether that output is INSIDE the
 * pane is a separate question, answered by mm_in_rect -- deliberately not
 * folded in, because a clamp and a cull are different decisions and a function
 * that silently did one of them would hide which.
 */
static MmPt mm_topdown(float wx, float wz, float cx, float cz,
                       float px, float py, float size, float spanM, float rot)
{
    MmPt o;
    float dx = wx - cx, dz = wz - cz, rx, rz, scale;
    if (rot != 0.0f) {
        float s = (float)sin((double)rot), c = (float)cos((double)rot);
        rx = dx * c - dz * s;
        rz = dx * s + dz * c;
    } else { rx = dx; rz = dz; }
    scale = (spanM > 0.0001f) ? (size / spanM) : 0.0f;
    o.x = px + size * 0.5f + rx * scale;
    o.y = py + size * 0.5f - rz * scale;   /* +Z is UP the screen */
    return o;
}

/* Planar (X,Z) distance. Y is excluded on purpose: a bot one floor up is at
 * the same place on a top-down map, and folding elevation in here would make a
 * near contact vanish off the radar for being tall. */
static float mm_dist2d(float ax, float az, float bx, float bz)
{
    float dx = ax - bx, dz = az - bz;
    return (float)sqrt((double)(dx * dx + dz * dz));
}

static int mm_in_rect(MmPt p, float rx, float ry, float rw, float rh)
{
    return (p.x >= rx && p.x <= rx + rw && p.y >= ry && p.y <= ry + rh) ? 1 : 0;
}

/* --- the directional indicator ----------------------------------------
 * Given a point already projected to screen space by the CAMERA (so it is
 * genuinely camera-relative, not north-up), place a marker for it.
 *
 * `behind` is the projector's own verdict that the point is behind the camera
 * plane. It must be passed in, not inferred: a point behind the camera
 * projects to a mathematically valid but MIRRORED screen position, and an
 * indicator that trusts it points confidently in exactly the wrong direction.
 * When behind, the direction is taken from the mirrored offset negated.
 *
 * The marker is clamped to a margin rectangle inset `inset` px from the screen
 * edge, so an off-screen contact becomes an edge marker on the correct side.
 * Returns 1 and writes *out when a marker should be drawn.
 *
 * `*offscreen` receives 1 when the result was clamped -- the caller needs that
 * to draw an edge chevron rather than an on-target box, and, more importantly,
 * a test needs it to tell "already on screen" from "clamped to the edge",
 * which the coordinates alone cannot distinguish at the boundary.
 */
static int mm_indicator(float sx, float sy, int behind,
                        float screenW, float screenH, float inset,
                        MmPt* out, int* offscreen)
{
    float cx = screenW * 0.5f, cy = screenH * 0.5f;
    float dx, dy, len, lx, ly, t, tx, ty;
    float minX = inset, minY = inset;
    float maxX = screenW - inset, maxY = screenH - inset;

    if (!out || !offscreen) return 0;
    if (!(screenW > 2.0f * inset) || !(screenH > 2.0f * inset)) return 0;

    dx = sx - cx; dy = sy - cy;
    if (behind) { dx = -dx; dy = -dy; }

    if (!behind && sx >= minX && sx <= maxX && sy >= minY && sy <= maxY) {
        out->x = sx; out->y = sy; *offscreen = 0;
        return 1;
    }

    len = (float)sqrt((double)(dx * dx + dy * dy));
    if (len < 0.0001f) {
        /* Dead centre and behind: there is no direction to point in. Say so by
         * refusing, rather than emitting an arbitrary one. */
        return 0;
    }
    lx = dx / len; ly = dy / len;

    /* Scale the unit direction out until it meets the nearer of the two
     * bounding edges. Both axes are tested and the SMALLER t wins, which is
     * what puts a corner-ward contact on the correct edge rather than past it.
     * A zero component yields an enormous t for that axis, so it never wins. */
    tx = (lx > 0.0001f)  ? (maxX - cx) / lx
       : (lx < -0.0001f) ? (minX - cx) / lx : 1.0e30f;
    ty = (ly > 0.0001f)  ? (maxY - cy) / ly
       : (ly < -0.0001f) ? (minY - cy) / ly : 1.0e30f;
    t = tx < ty ? tx : ty;
    if (t >= 1.0e29f) return 0;

    out->x = cx + lx * t;
    out->y = cy + ly * t;
    *offscreen = 1;
    return 1;
}

/* --- the north-up FALLBACK indicator -----------------------------------
 * Used only when no projector is installed. It is a bearing on a ring around
 * screen centre and it is NOT camera-relative: with no heading measured
 * (sp/world.nim publishes hasHeading:false) it points at world north, not at
 * where the player is looking. Kept as a distinct function, rather than a flag
 * on mm_indicator, so no caller can accidentally present one as the other.
 */
static int mm_bearing_ring(float wx, float wz, float cx, float cz,
                           float rot, float screenW, float screenH,
                           float ringFrac, MmPt* out)
{
    float dx = wx - cx, dz = wz - cz, rx, rz, d, ring;
    if (!out) return 0;
    if (rot != 0.0f) {
        float s = (float)sin((double)rot), c = (float)cos((double)rot);
        rx = dx * c - dz * s;
        rz = dx * s + dz * c;
    } else { rx = dx; rz = dz; }
    d = (float)sqrt((double)(rx * rx + rz * rz));
    if (d < 0.001f) return 0;
    ring = (screenH < screenW ? screenH : screenW) * ringFrac;
    out->x = screenW * 0.5f + (rx / d) * ring;
    out->y = screenH * 0.5f - (rz / d) * ring;
    return 1;
}

/* --- pocketmap tile selection ------------------------------------------
 * Fact #49: StreamingAssets/.../pocketmap/ is a zoom-tiled pyramid named
 * map_tile_<col>x<row>_<scale>. This picks the tile covering a world point at
 * a given scale, given the pyramid's world origin and tile world size.
 *
 * It is here, and TESTED, even though nothing draws a tile today: the region
 * command set is FILL/BOX/LINE/TEXT with no textured quad, so an image cannot
 * be submitted through it at all (see sp/hud.nim's header). Having the
 * selection maths settled and falsifiable is what makes adding a texture
 * command the only remaining work, rather than that plus this.
 */
static int mm_tile_index(float wx, float wz, float originX, float originZ,
                         float tileWorldSize, int cols, int rows,
                         int* col, int* row)
{
    int c, r;
    if (!col || !row) return 0;
    if (!(tileWorldSize > 0.0001f) || cols <= 0 || rows <= 0) return 0;
    c = (int)floor((double)((wx - originX) / tileWorldSize));
    /* Rows increase DOWNWARD in image space while +Z goes north, so the row
     * axis is inverted against Z. */
    r = (rows - 1) - (int)floor((double)((wz - originZ) / tileWorldSize));
    if (c < 0 || c >= cols || r < 0 || r >= rows) return 0;
    *col = c; *row = r;
    return 1;
}

#endif /* AOWL_MAPMATH_H */
