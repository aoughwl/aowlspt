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
#include <stdint.h>

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

/* ------------------------------------------------------------------ position
 *
 * WHY a position was rejected, as a value rather than as a silent `return`.
 *
 * `sp/world.nim`'s `posOf` used to have six ways to fail and reported none of
 * them: it set ok=false and returned, spending no fault budget and writing no
 * defect string. The live snapshot from the raid that prompted this read
 * `ok:false localIdx:-1 ents:[] faults:0 defect:"none"` -- every player
 * discarded, nothing recorded. The radar then drew nothing and said nothing.
 *
 * The predicate lives HERE, in the header the offline test compiles, so the
 * gate that ships is the gate that is tested. `world.nim` calls this and maps
 * the code onto its counters; it does not re-implement the thresholds.
 *
 * `readable` is passed in by the caller because readability is a VirtualQuery
 * result, not a property of the floats -- and conflating "the page is not
 * mapped" with "the value is zero" is the specific ambiguity that hid this
 * bug. MM_POS_UNREADABLE and MM_POS_ALLZERO are therefore distinct answers.
 */
#define MM_POS_OK         0
#define MM_POS_UNREADABLE 1
#define MM_POS_NAN        2
#define MM_POS_RANGE      3
#define MM_POS_ALLZERO    4

#define MM_POS_LIMIT 1.0e6f

static int mm_pos_classify(int readable, float x, float y, float z)
{
    if (!readable) return MM_POS_UNREADABLE;
    /* NaN is the only value that compares unequal to itself. Written this way
     * rather than with isnan() so it survives -ffast-math builds unchanged. */
    if (x != x || y != y || z != z) return MM_POS_NAN;
    if (x > MM_POS_LIMIT || x < -MM_POS_LIMIT) return MM_POS_RANGE;
    if (y > MM_POS_LIMIT || y < -MM_POS_LIMIT) return MM_POS_RANGE;
    if (z > MM_POS_LIMIT || z < -MM_POS_LIMIT) return MM_POS_RANGE;
    /* Exactly (0,0,0). No Tarkov map places a player on the world origin, and
     * an unmapped page read as zeroes lands here -- which is why `readable`
     * must be answered ABOVE and not inferred from this. */
    if (x == 0.0f && y == 0.0f && z == 0.0f) return MM_POS_ALLZERO;
    return MM_POS_OK;
}

/* ------------------------------------------------------------------- heading
 *
 * WHY A HEADING WAS REJECTED, as a value -- the same discipline as position,
 * for the same reason. `MovementContext.PreviousPosition` @0x370 is declared,
 * correctly named by metadata, and permanently (0,0,0) on this build. Any new
 * field this mod reads must therefore be able to come back as "readable page,
 * all zeros", distinctly from "not mapped" and from "a real value", or the
 * next dead field is invisible exactly as that one was.
 *
 * WHERE THE HEADING COMES FROM. `EFT.Player::get_LookDirection` @0x6F8060 is,
 * in its own instruction bytes, a PURE FIELD READ:
 *
 *     48 8B 42 60                mov rax,[rdx+0x60]        Player.MovementContext
 *     48 85 C0 74 1D             null -> throw
 *     F2 0F 10 80 D0 03 00 00    movsd xmm0,[rax+0x3D0]    _lookDirection.x,.y
 *     8B 80 D8 03 00 00          mov  eax,[rax+0x3D8]      _lookDirection.z
 *     F2 0F 11 01 / 89 41 08     store 12 bytes to the sret buffer
 *
 * and metadata independently names `EFT.MovementContext._lookDirection` a
 * `Vector3` at exactly 0x3D0. Unlike the POSITION -- which bottoms out in the
 * Unity native icall `Transform::get_position_Injected` and so has no managed
 * home at all -- the look direction IS a managed field, so the heading needs
 * no call: a guarded walk and a 12-byte read is strictly less machinery, and
 * less machinery is less blast radius. Nothing here is inferred from the
 * method's NAME; the offsets are read off the accessor and corroborated.
 *
 * The yaw convention is mm_topdown's, stated there: 0 = +Z (north), increasing
 * toward +X (east). Facing east means look=(1,0,z~0) -> atan2(1,0) = +pi/2,
 * and mm_topdown then puts a contact due north on the LEFT. Both conventions
 * are pinned by the offline test, because both readings produce a smooth,
 * plausible, MIRRORED map.
 */
#define MM_HDG_OK         0
#define MM_HDG_UNREADABLE 1
#define MM_HDG_NAN        2
#define MM_HDG_ALLZERO    3
#define MM_HDG_FLAT       4

/* Below this the horizontal projection of the look vector carries no bearing:
 * the player is looking very nearly straight up or down. Rotating the map by
 * the atan2 of two near-zero numbers is not a heading, it is noise amplified,
 * so it is refused and counted rather than drawn. */
#define MM_HDG_MINXZ 1.0e-4f

static int mm_heading_from_look(int readable, float x, float y, float z,
                                float* yaw)
{
    float h2;
    if (yaw) *yaw = 0.0f;
    if (!readable) return MM_HDG_UNREADABLE;
    if (x != x || y != y || z != z) return MM_HDG_NAN;
    /* Exactly (0,0,0): a mapped page that nobody ever wrote. This is the
     * PreviousPosition failure mode and it gets its own answer. */
    if (x == 0.0f && y == 0.0f && z == 0.0f) return MM_HDG_ALLZERO;
    h2 = x * x + z * z;
    if (h2 < MM_HDG_MINXZ * MM_HDG_MINXZ) return MM_HDG_FLAT;
    if (yaw) *yaw = (float)atan2((double)x, (double)z);
    return MM_HDG_OK;
}

/* The smallest signed difference between two yaws, in radians, wrapped into
 * (-pi, pi]. Used by the diagnostic to answer the ONLY question that settles
 * defect 1: has the drawn rotation actually CHANGED? A static non-zero heading
 * is a FAIL, and it is indistinguishable from a working one unless something
 * measures the spread. */
static float mm_yaw_delta(float a, float b)
{
    float d = a - b;
    const float TAU = 6.28318530717958647692f;
    const float PI  = 3.14159265358979323846f;
    while (d >  PI) d -= TAU;
    while (d <= -PI) d += TAU;
    return d;
}

/* --------------------------------------------------------------- indicator
 * lifetime: HOLD, then FADE, then GONE.
 *
 * A directional indicator is a TRANSIENT. It is drawn at full alpha for
 * `holdMs` after the contact was last refreshed, ramps linearly to zero over
 * the following `fadeMs`, and past that it must not be drawn at all.
 *
 * Three separate functions rather than one, on purpose: "how opaque" and "is
 * it gone" are different questions, and a caller that folded them together
 * would draw a fully transparent mark forever and count it as an indicator.
 * `mm_fade_expired` is the one the eviction path uses and it is defined as the
 * strict complement of a positive alpha, so the two can never disagree.
 *
 * A fadeMs of 0 is a legal setting and means "no ramp": full alpha until the
 * hold elapses, then gone. A negative age (a clock that went backwards, or a
 * contact stamped in the future) is treated as fresh rather than as expired --
 * failing OPEN here loses a frame of fade, failing closed loses the feature.
 */
static float mm_fade_alpha(int64_t ageMs, int64_t holdMs, int64_t fadeMs)
{
    if (holdMs < 0) holdMs = 0;
    if (fadeMs < 0) fadeMs = 0;
    if (ageMs <= holdMs) return 1.0f;
    if (fadeMs == 0) return 0.0f;
    if (ageMs >= holdMs + fadeMs) return 0.0f;
    return 1.0f - (float)(ageMs - holdMs) / (float)fadeMs;
}

static int mm_fade_expired(int64_t ageMs, int64_t holdMs, int64_t fadeMs)
{
    return mm_fade_alpha(ageMs, holdMs, fadeMs) <= 0.0f ? 1 : 0;
}

/* Scale the ALPHA byte of a packed r|g<<8|b<<16|a<<24 colour, leaving the
 * three colour bytes untouched. Rounded, not truncated, so a 0.999 factor does
 * not silently drop a level. */
static uint32_t mm_fade_rgba(uint32_t rgba, float a)
{
    uint32_t al = (rgba >> 24) & 0xFFu;
    float scaled;
    if (a <= 0.0f) return rgba & 0x00FFFFFFu;
    if (a >= 1.0f) return rgba;
    scaled = (float)al * a + 0.5f;
    if (scaled < 0.0f) scaled = 0.0f;
    if (scaled > 255.0f) scaled = 255.0f;
    return (rgba & 0x00FFFFFFu) | ((uint32_t)scaled << 24);
}

#endif /* AOWL_MAPMATH_H */
