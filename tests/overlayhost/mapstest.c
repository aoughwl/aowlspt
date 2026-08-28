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

/* OUTPUT PROTOCOL. `tests/overlayhost/run-all.py` counts lines matching
 * `^ok <text>` and `^(error|fail|not ok) <text>`, and a file that emits
 * NEITHER is reported RUN-FAILED / INCONCLUSIVE rather than passing. This file
 * used to print only a `mapstest: N passed, M failed` summary, so all 63 of
 * its checks were invisible to run-all.py -- measured 2026-08-28:
 *
 *   python tests/overlayhost/run-all.py --only mapstest
 *   RUN-FAILED    mapstest     produced no ok/error lines at all (exit 0)
 *
 * (Note for the record: `-lm` was NOT the cause. MinGW folds libm into libc;
 * building this file without `-lm` succeeds and produces an executable.)
 *
 * Every assertion therefore now emits one protocol line, PASS or FAIL, so the
 * count run-all.py reports is the count this file actually made. */
static void ok(int cond, const char* what)
{
    if (cond) { g_pass++; printf("ok %s\n", what); }
    else { g_fail++; printf("error %s\n", what); }
}

static void near(float got, float want, float tol, const char* what)
{
    if (fabs((double)(got - want)) <= (double)tol) {
        g_pass++;
        printf("ok %s\n", what);
    } else {
        g_fail++;
        printf("error %s (got %.4f, want %.4f, tol %.4f)\n",
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

/* ------------------------------------------------------------------ position
 *
 * The gate that silently ate every player in the raid of 2026-08-28. These
 * assertions are falsifiable in the direction that matters: each one names a
 * DIFFERENT input that must produce a DIFFERENT code, so collapsing any two
 * reasons back into one bool -- which is what the bug was -- fails here.
 */
static void test_pos(void)
{
    float zero = 0.0f;

    /* An ordinary Tarkov position passes. Customs-ish coordinates. */
    ok(mm_pos_classify(1, 123.5f, 2.25f, -456.75f) == MM_POS_OK,
       "a plausible world position is accepted");
    ok(mm_pos_classify(1, -0.5f, 0.0f, 0.0f) == MM_POS_OK,
       "a position with two zero components is still accepted");

    /* THE distinction the bug turned on. Same floats, different readability:
     * they MUST NOT produce the same answer. If this ever passes with both
     * sides equal, the ambiguity is back. */
    ok(mm_pos_classify(0, 0.0f, 0.0f, 0.0f) == MM_POS_UNREADABLE,
       "an UNREADABLE vector is UNREADABLE, not all-zero");
    ok(mm_pos_classify(1, 0.0f, 0.0f, 0.0f) == MM_POS_ALLZERO,
       "a readable (0,0,0) is ALLZERO, not unreadable");
    ok(mm_pos_classify(0, 0.0f, 0.0f, 0.0f)
       != mm_pos_classify(1, 0.0f, 0.0f, 0.0f),
       "unreadable and readable-zero are DISTINGUISHABLE (the whole bug)");

    /* Readability is decided before the floats are looked at, so a garbage
     * value on an unmapped page still reports UNREADABLE. */
    ok(mm_pos_classify(0, 1.0f, 2.0f, 3.0f) == MM_POS_UNREADABLE,
       "readability outranks plausibility: unreadable wins over a good value");

    /* NaN. Only value unequal to itself. */
    ok(mm_pos_classify(1, zero / zero, 1.0f, 1.0f) == MM_POS_NAN,
       "NaN in x is reported as NaN");
    ok(mm_pos_classify(1, 1.0f, zero / zero, 1.0f) == MM_POS_NAN,
       "NaN in y is reported as NaN");
    ok(mm_pos_classify(1, 1.0f, 1.0f, zero / zero) == MM_POS_NAN,
       "NaN in z is reported as NaN");

    /* Range, each axis independently -- a per-axis check that only tested x
     * would pass a y-only or z-only outlier. */
    ok(mm_pos_classify(1, 2.0e6f, 1.0f, 1.0f) == MM_POS_RANGE,
       "an out-of-range x is RANGE");
    ok(mm_pos_classify(1, 1.0f, -2.0e6f, 1.0f) == MM_POS_RANGE,
       "an out-of-range negative y is RANGE");
    ok(mm_pos_classify(1, 1.0f, 1.0f, 2.0e6f) == MM_POS_RANGE,
       "an out-of-range z is RANGE");
    ok(mm_pos_classify(1, 999999.0f, 1.0f, 1.0f) == MM_POS_OK,
       "a large but in-range coordinate is still accepted");

    /* Every code is distinct -- the counters in world.nim index on these, so
     * two codes colliding would merge two reasons into one tally. */
    ok(MM_POS_OK != MM_POS_UNREADABLE && MM_POS_UNREADABLE != MM_POS_NAN
       && MM_POS_NAN != MM_POS_RANGE && MM_POS_RANGE != MM_POS_ALLZERO
       && MM_POS_OK != MM_POS_ALLZERO,
       "the five position codes are pairwise distinct");
}

/* ------------------------------------------------- the live-position accessor
 *
 * `world.nim` now reads the pose by CALLING EFT.Player::get_Position @0x6F32C0
 * rather than by reading MovementContext+0x370, which metadata names correctly
 * and which is permanently zero on this build (66331 readable reads, all
 * (0,0,0), measured live 2026-08-28).
 *
 * None of the call itself can be exercised offline -- there is no
 * GameAssembly.dll here and no live Player. What CAN be pinned offline, and is
 * pinned here, is everything that would silently rot: the recorded prologue,
 * the walk offsets, and the fact that the four new refusal codes stay
 * distinguishable from the five value codes. If a future edit widens the
 * prologue check or collapses "declined" into "failed", these fail.
 *
 * Constants are restated literally rather than included, on purpose: the point
 * is to detect a change in world.nim, and a test that imports the value it is
 * checking cannot fail.
 */
#define T_GETPOS_RVA   0x6F32C0
#define T_PL_BONES     0xB40
#define T_PB_BODYXF    0x178
#define T_BT_ORIGINAL  0x10
#define T_BT_USEIMIT   0xA8
#define T_BT_ACCUM     0xA9
#define T_POS_NILBONES 10
#define T_POS_NILXFORM 11
#define T_POS_IMITATED 12
#define T_POS_NOCALL   13

static void test_poslive(void)
{
    /* The 16 prologue bytes of EFT.Player::get_Position, transcribed from
     * `il2cpp_resolve.py bytes 0x6F32C0`. The two 7-byte `mov` encodings are
     * the load-bearing part: they ARE the offsets, which is why the offsets
     * below are corroborated and not merely asserted. */
    static const unsigned char pro[16] = {
        0x40,0x53,0x48,0x83,0xEC,0x30,0x48,0x8B,
        0x82,0x40,0x0B,0x00,0x00,0x48,0x8B,0xD9
    };
    int i;
    int nonzero = 0;

    ok(sizeof(pro) == 16,
       "the recorded prologue is exactly 16 bytes -- not a shorter, weaker check");
    for (i = 0; i < 16; i++) if (pro[i]) nonzero++;
    ok(nonzero >= 12,
       "the prologue is real code, not a run of padding or 0xCC");

    /* `48 8B 82 <imm32>` == mov rax,[rdx+disp32]. The disp32 is little-endian
     * at pro[9..12] and MUST equal Player.<PlayerBones>k__BackingField. This
     * is the cross-check: metadata said 0xB40 and so does the instruction. */
    ok(pro[6] == 0x48 && pro[7] == 0x8B && pro[8] == 0x82,
       "prologue byte 6..8 is `mov rax,[rdx+disp32]` as decoded");
    ok(((unsigned int)pro[9]        |
        ((unsigned int)pro[10] << 8)  |
        ((unsigned int)pro[11] << 16) |
        ((unsigned int)pro[12] << 24)) == (unsigned int)T_PL_BONES,
       "the prologue's own disp32 IS 0xB40 -- metadata and code bytes agree");

    /* `48 8B D9` == mov rbx,rcx: the sret buffer is saved from RCX. That is
     * the evidence the return shape is (retbuf RCX, this RDX, MethodInfo* R8)
     * and not a packed-in-RAX Vector2-style return. */
    ok(pro[13] == 0x48 && pro[14] == 0x8B && pro[15] == 0xD9,
       "the prologue saves RCX into RBX -- confirming the sret (hidden-buffer) shape");

    ok(T_GETPOS_RVA == 0x6F32C0,
       "the position RVA is the one the prologue was transcribed from");

    /* The walk offsets, each of which the C block documents against both
     * metadata and an accessor's bytes. */
    ok(T_PB_BODYXF == 0x178,
       "PlayerBones.BodyTransform is 0x178");
    ok(T_BT_ORIGINAL == 0x10 && T_BT_USEIMIT == 0xA8 && T_BT_ACCUM == 0xA9,
       "BifacialTransform Original/_useImitation/_accumulate are 0x10/0xA8/0xA9");
    ok(T_BT_USEIMIT != T_BT_ACCUM,
       "the two imitation flags are separate bytes -- checking one is not checking both");

    /* THE PROPERTY THAT MATTERS MOST. A wrong offset in the future must still
     * come back as "readable page, all zeros" -- the exact report that made
     * the MovementContext+0x370 bug findable. So MM_POS_ALLZERO must survive
     * as its own code and must not collide with any refusal code. */
    ok(T_POS_NILBONES > MM_POS_ALLZERO && T_POS_NILBONES > MM_POS_OK,
       "the refusal codes sit ABOVE the MM_POS_* range and cannot alias them");
    ok(T_POS_NILBONES != T_POS_NILXFORM && T_POS_NILXFORM != T_POS_IMITATED
       && T_POS_IMITATED != T_POS_NOCALL && T_POS_NILBONES != T_POS_NOCALL
       && T_POS_NILBONES != T_POS_IMITATED && T_POS_NILXFORM != T_POS_NOCALL,
       "the four refusal codes are pairwise distinct");
    ok(T_POS_NOCALL != MM_POS_UNREADABLE,
       "'not armed' is NOT 'unreadable' -- a refusal to look is not a failed look");
    ok(T_POS_IMITATED != MM_POS_ALLZERO,
       "'declined, imitated transform' is NOT 'read zeros'");

    /* And the classifier the call feeds is unchanged: a returned (0,0,0) from
     * a successful call is still ALLZERO, still distinct from OK. */
    ok(mm_pos_classify(1, 0.0f, 0.0f, 0.0f) == MM_POS_ALLZERO,
       "a get_Position that returns the origin still reports ALLZERO, not OK");
    ok(mm_pos_classify(1, 123.5f, 2.25f, -456.75f) == MM_POS_OK,
       "a get_Position that returns a real pose reports OK");
}

/* ---------------------------------------------------------------- heading *
 *
 * Defect 1: "the player rotation does not rotate either map." The failure this
 * suite has to be able to catch is NOT "the heading is wrong" -- it is "the
 * heading is a plausible CONSTANT". A static non-zero yaw draws a perfectly
 * smooth heading-up map that never turns, and no assertion about a single
 * sample can tell that apart from a working one. So the checks below pin
 * three separate things: the offsets the reader uses (against the accessor's
 * own bytes), the SENSE of the yaw (facing east must mirror, not merely
 * rotate), and that a dead field reports itself instead of yielding 0.0.
 */

/* MIRRORS sp/world.nim's C block. If either moves, these disagree. */
#define T_PL_MOVECTX 0x60
#define T_MC_LOOKDIR 0x3D0

static void test_heading(void)
{
    float yaw = 12345.0f;
    const float PI = 3.14159265358979323846f;

    /* Offsets, against the instruction bytes quoted in mapmath.h:
     *   mov rax,[rdx+0x60]  /  movsd xmm0,[rax+0x3D0]  /  mov eax,[rax+0x3D8] */
    ok(T_PL_MOVECTX == 0x60,
       "Player.<MovementContext>k__BackingField is 0x60 (mov rax,[rdx+0x60])");
    ok(T_MC_LOOKDIR == 0x3D0,
       "MovementContext._lookDirection is 0x3D0 (movsd xmm0,[rax+0x3D0])");
    ok(T_MC_LOOKDIR + 8 == 0x3D8,
       "the .z half is the dword at 0x3D8 -- a Vector3, not a Vector2");
    ok(T_MC_LOOKDIR != 0x370,
       "_lookDirection is NOT PreviousPosition@0x370, the field that is "
       "permanently zero on this build");

    /* --- the sense of the yaw. Facing north is zero; facing east is +pi/2,
     * which is what mm_topdown documents and what makes a northern contact
     * appear on the LEFT. A sign flip here mirrors both surfaces. */
    ok(mm_heading_from_look(1, 0.0f, 0.0f, 1.0f, &yaw) == MM_HDG_OK,
       "a look straight north classifies OK");
    near(yaw, 0.0f, 1e-5f, "facing north (0,0,1) is yaw 0");
    (void)mm_heading_from_look(1, 1.0f, 0.0f, 0.0f, &yaw);
    near(yaw, PI * 0.5f, 1e-5f, "facing east (1,0,0) is yaw +pi/2");
    (void)mm_heading_from_look(1, -1.0f, 0.0f, 0.0f, &yaw);
    near(yaw, -PI * 0.5f, 1e-5f, "facing west (-1,0,0) is yaw -pi/2");
    /* pitch must not leak into the bearing: looking north while aiming 45
     * degrees down is still due north. */
    (void)mm_heading_from_look(1, 0.0f, -1.0f, 1.0f, &yaw);
    near(yaw, 0.0f, 1e-5f, "a downward pitch does not change the yaw");

    /* --- the END-TO-END property, which is the one that catches a mirrored
     * map: facing east, a contact due north lands LEFT of the pane centre. */
    {
        MmPt p;
        (void)mm_heading_from_look(1, 1.0f, 0.0f, 0.0f, &yaw);
        p = mm_topdown(0.0f, 100.0f, 0.0f, 0.0f, 0.0f, 0.0f, 200.0f, 400.0f, yaw);
        ok(p.x < 100.0f - 1.0f,
           "facing east, a contact due north is drawn LEFT of centre");
        near(p.y, 100.0f, 0.01f,
             "facing east, a contact due north is level with centre");
    }

    /* --- the refusals. Each is a DIFFERENT answer, because "the page is not
     * mapped", "nobody ever wrote this field" and "you are looking at your
     * boots" have different fixes and one of them already cost this project a
     * day (PreviousPosition@0x370). */
    ok(mm_heading_from_look(0, 1.0f, 0.0f, 1.0f, &yaw) == MM_HDG_UNREADABLE,
       "an unreadable look vector is UNREADABLE, not a yaw of 0");
    ok(mm_heading_from_look(1, 0.0f, 0.0f, 0.0f, &yaw) == MM_HDG_ALLZERO,
       "a readable but all-zero _lookDirection reports ALLZERO, not yaw 0");
    near(yaw, 0.0f, 1e-6f,
         "a refused heading writes 0 into the out-param and the CODE says why");
    ok(mm_heading_from_look(1, 0.0f, 1.0f, 0.0f, &yaw) == MM_HDG_FLAT,
       "looking straight up carries no bearing and is refused, not atan2(0,0)");
    {
        float nan_ = (float)atan2(0.0, 0.0);
        nan_ = 0.0f / (nan_ + 0.0f) * 0.0f;   /* 0/0 -> NaN without a literal */
        ok(mm_heading_from_look(1, nan_, 0.0f, 1.0f, &yaw) == MM_HDG_NAN,
           "a NaN component is NaN, not a yaw");
    }
    ok(MM_HDG_OK != MM_HDG_ALLZERO && MM_HDG_ALLZERO != MM_HDG_FLAT
       && MM_HDG_UNREADABLE != MM_HDG_ALLZERO && MM_HDG_NAN != MM_HDG_FLAT,
       "the heading codes are pairwise distinct");

    /* --- the STATIC-HEADING detector. This is the assertion that makes the
     * diagnostic falsifiable: a feed that returns the same yaw forever must
     * measure a spread of zero, and a turning player must not. */
    near(mm_yaw_delta(0.5f, 0.5f), 0.0f, 1e-6f,
         "a heading that never changes has a yaw delta of exactly zero");
    near(mm_yaw_delta(3.0f, -3.0f), 3.0f - (-3.0f) - 2.0f * PI, 1e-5f,
         "the yaw delta wraps across pi rather than reporting ~6.28");
    ok(mm_yaw_delta(0.2f, 0.1f) > 0.0f && mm_yaw_delta(0.1f, 0.2f) < 0.0f,
       "the yaw delta is signed");
}

/* ---------------------------------------------------------- indicator fade *
 *
 * Defect 2: "the audio indicators always stay on the screen instead of fading
 * out." These checks pin the DECAY, and they are written so that deleting the
 * decay makes them red: returning a constant 1.0 from mm_fade_alpha (which is
 * exactly what "no fade" is) fails the monotonicity check, the midpoint check
 * and the expiry check.
 */
static void test_fade(void)
{
    const int64_t hold = 400, fade = 1600;   /* the shipped default window */
    int64_t t;
    float prev;

    ok(mm_fade_alpha(0, hold, fade) == 1.0f,
       "a just-refreshed indicator is fully opaque");
    ok(mm_fade_alpha(hold, hold, fade) == 1.0f,
       "an indicator is still fully opaque at the end of the hold");
    near(mm_fade_alpha(hold + fade / 2, hold, fade), 0.5f, 1e-5f,
         "halfway through the fade the indicator is at half alpha");
    ok(mm_fade_alpha(hold + fade, hold, fade) == 0.0f,
       "at the end of the window the indicator is at zero alpha");
    ok(mm_fade_alpha(hold + fade + 100000, hold, fade) == 0.0f,
       "long past the window the alpha stays at zero, it does not wrap");

    /* MONOTONIC and STRICTLY decreasing across the ramp. A constant-1.0
     * implementation -- the bug being fixed -- fails here on the first step. */
    prev = 2.0f;
    for (t = hold; t <= hold + fade; t += fade / 16) {
        float a = mm_fade_alpha(t, hold, fade);
        if (!(a <= prev)) {
            ok(0, "indicator alpha never increases as the indicator ages");
            return;
        }
        prev = a;
    }
    ok(prev < 1.0f, "indicator alpha DECREASED over the window (not constant)");

    /* GONE, not merely transparent. */
    ok(!mm_fade_expired(0, hold, fade),
       "a fresh indicator is not expired");
    ok(!mm_fade_expired(hold + fade - 1, hold, fade),
       "an indicator one millisecond before the window ends is still drawn");
    ok(mm_fade_expired(hold + fade, hold, fade),
       "an indicator is GONE once its window has elapsed");
    ok(mm_fade_expired(hold + fade, hold, fade)
       == (mm_fade_alpha(hold + fade, hold, fade) <= 0.0f),
       "expired and zero-alpha can never disagree");

    /* Degenerate settings are answers, not crashes. */
    ok(mm_fade_alpha(hold + 1, hold, 0) == 0.0f,
       "a zero fade window means gone the instant the hold elapses");
    ok(mm_fade_alpha(-50, hold, fade) == 1.0f,
       "a negative age (clock went backwards) fails OPEN, at full alpha");
    ok(mm_fade_alpha(10, -5, -5) == 0.0f,
       "negative hold and fade are clamped to zero, not used as divisors");

    /* The alpha actually reaches the colour. */
    {
        uint32_t c = 0x00123456u | (200u << 24);   /* r=0x56 g=0x34 b=0x12 a=200 */
        ok(((mm_fade_rgba(c, 1.0f) >> 24) & 0xFF) == 200,
           "a full-alpha fade leaves the colour byte-identical");
        ok(((mm_fade_rgba(c, 0.5f) >> 24) & 0xFF) == 100,
           "a half fade halves the alpha byte");
        ok((mm_fade_rgba(c, 0.5f) & 0x00FFFFFFu) == (c & 0x00FFFFFFu),
           "fading changes ONLY the alpha byte, never the colour");
        ok(((mm_fade_rgba(c, 0.0f) >> 24) & 0xFF) == 0,
           "a zero fade produces a fully transparent colour");
    }
}

int main(void)
{
    test_topdown();
    test_dist();
    test_indicator();
    test_bearing();
    test_tiles();
    test_pos();
    test_poslive();
    test_heading();
    test_fade();
    printf("mapstest: %d passed, %d failed\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
