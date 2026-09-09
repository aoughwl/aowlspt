/* mods/maps/sp/mapart.h -- the PURE arithmetic behind drawing real map ART
 * under the blips: which layer the player is on, and where each tile of that
 * layer lands on a top-down pane.
 *
 * Same contract as sp/mapmath.h and for the same reason: no globals, no game
 * memory, no allocation, no draw calls. `tests/overlayhost/mapstest.c` asserts
 * on the FINISHED numbers -- a known world point lands on the expected texel of
 * the expected tile -- with no client running. `sp/hud.nim` only submits.
 *
 * ------------------------------------------------------------------ the model
 * The calibration in `mods/maps/data/maps/` (the per-map JSON) is turned into
 * tiles by
 * `tools/maptiles.py`, which writes `data/maptiles/manifest.json`. The mod
 * parses that manifest ONCE and fills the fixed-size structs below. Nothing
 * here parses anything, and nothing here allocates: the caller owns the memory
 * and the caps are compile-time.
 *
 * -------------------------------------------------------------- the axis trap
 * Stated once, applied once, tested. From `sp/page.nim`'s derivation, which
 * cites the DynamicMaps fork's `MathUtils.ConvertToMapPosition`:
 *
 *     map plane = (world.x, world.z)      height = world.y
 *
 * and a `gameBounds` box is written in MAP-PLANE coordinates with its `z` as
 * the HEIGHT. So a box's (x, y, z) compare against (world.x, world.z, world.y).
 * Getting this backwards puts the player underground on every map and selects a
 * basement layer that renders perfectly. `ma_in_box` is the only place it
 * happens.
 *
 * ------------------------------------------------- why rotation is NOT applied
 * Every shipped map carries a non-zero `coordinateRotation` (90/180/270; none
 * is 0). In the fork it rotates the container holding the art AND the markers,
 * about the centre of the bounds -- so it changes which way is up on screen and
 * changes NOTHING about art-to-marker registration. Art expressed in
 * `imageBounds` and markers expressed in the map plane are already registered
 * without it. It is therefore recorded in the manifest, checked against the
 * calibration by `maptiles.py verify`, and deliberately not applied here.
 *
 * The consequence that matters: `AOWL_REGION_CMD_QUAD` is an AXIS-ALIGNED dest
 * rect with an axis-aligned UV rect. It cannot draw rotated art. So when the
 * pane itself is rotated -- heading-up, once a heading is measured -- the tiles
 * would be drawn square while the blips swing, which is a misregistered map
 * that still looks like a map. `ma_can_draw` refuses that case BY NAME
 * (`MA_REFUSE_ROTATED`) and the caller falls back to the labelled grid. It is a
 * stated limit of the quad command, not a bug in the calibration, and it must
 * never degrade silently.
 */
#ifndef AOWL_MAPART_H
#define AOWL_MAPART_H

#include <math.h>
#include <stdint.h>

#define MA_MAX_LAYERS 8
#define MA_MAX_TILES  32     /* == AOWL_REGION_TEX_MAX; one tile, one slot */
#define MA_MAX_BOXES  8

/* A map-plane rectangle: x is world x, y is world z. */
typedef struct { float minX, minY, maxX, maxY; } MaRect;

/* A gameBounds box. `minH`/`maxH` are the HEIGHT range and correspond to the
 * box's z in the JSON and to world.y in the game. Named `H` and not `Z` on
 * purpose -- calling it z is exactly how the axis trap gets re-sprung. */
typedef struct { float minX, minY, minH, maxX, maxY, maxH; } MaBox;

typedef struct {
    MaRect   world;        /* the map-plane rect this tile covers */
    uint64_t key;          /* the region texture key (0 = not uploaded) */
    int32_t  col, row;
} MaTile;

typedef struct {
    int32_t level;
    int32_t nBoxes;
    MaBox   box[MA_MAX_BOXES];
    MaRect  imageBounds;
    int32_t cols, rows;
    int32_t tile0, nTiles;   /* slice of MaArt.tile */
} MaLayer;

typedef struct {
    int32_t  valid;          /* 0 until a manifest map has been bound */
    int32_t  defaultLevel;
    int32_t  rotationDeg;    /* recorded, NOT applied -- see the header note */
    int32_t  nLayers;
    MaLayer  layer[MA_MAX_LAYERS];
    int32_t  nTiles;
    MaTile   tile[MA_MAX_TILES];
} MaArt;

/* WHY a layer was chosen, as a value. Same discipline as MM_POS_* in mapmath.h:
 * "the default level, because no box contained the player" and "a box contained
 * the player" are different confidences and the diag must be able to say which.
 */
#define MA_LAYER_NONE        0   /* nothing selected -- no layers at all       */
#define MA_LAYER_GAMEBOUNDS  1   /* the player is inside a declared box        */
#define MA_LAYER_DEFAULT     2   /* map defaultLevel; no box contained them    */
#define MA_LAYER_FIRST       3   /* no box, and no layer at defaultLevel       */

/* WHY art could not be drawn. Never "0 tiles" with no reason. */
#define MA_OK                0
#define MA_REFUSE_NOMAP      1   /* no calibration matched this raid's map     */
#define MA_REFUSE_NOLAYER    2   /* the map has no layers                      */
#define MA_REFUSE_ROTATED    3   /* the pane is rotated; QUAD is axis-aligned  */
#define MA_REFUSE_NOPOS      4   /* no validated player position               */
#define MA_REFUSE_NOTEX      5   /* no tile of the chosen layer is resident    */
#define MA_REFUSE_OFFPANE    6   /* the layer is real but entirely off-pane    */
#define MA_REFUSE_NORAID     7   /* not an active, spawned, in-world raid       */
#define MA_REFUSE_MAPKEY     8   /* raid map key had no calibration entry       */
#define MA_REFUSE_MISMATCH   9   /* resolved map's bounds do not contain player */

static const char* ma_refusal_text(int32_t r)
{
    switch (r) {
    case MA_OK:               return "ok";
    case MA_REFUSE_NOMAP:     return "no calibration matches this map";
    case MA_REFUSE_NOLAYER:   return "the calibration declares no layers";
    case MA_REFUSE_ROTATED:   return "the pane is heading-up and the region "
                                     "QUAD is axis-aligned, so the art would "
                                     "be misregistered against the blips";
    case MA_REFUSE_NOPOS:     return "no validated player position";
    case MA_REFUSE_NOTEX:     return "no tile of the chosen layer is resident "
                                     "in the region texture cache";
    case MA_REFUSE_OFFPANE:   return "the chosen layer lies entirely outside "
                                     "the visible pane";
    case MA_REFUSE_NORAID:    return "not in a raid, HUD idle";
    case MA_REFUSE_MAPKEY:    return "the raid's map key has no calibration "
                                     "entry -- refusing rather than guessing a "
                                     "map by bounds";
    case MA_REFUSE_MISMATCH:  return "the map resolved from the raid's key does "
                                     "NOT contain the player position -- a "
                                     "calibration/coordinate mismatch, refused";
    default:                  return "unknown";
    }
}

static const char* ma_layer_why_text(int32_t w)
{
    switch (w) {
    case MA_LAYER_GAMEBOUNDS: return "inside a declared gameBounds box";
    case MA_LAYER_DEFAULT:    return "map defaultLevel (no box contained the "
                                     "player)";
    case MA_LAYER_FIRST:      return "first layer (no box, no defaultLevel "
                                     "match)";
    default:                  return "none";
    }
}

/* The axis trap, in one place. `wx,wy,wz` are WORLD (Unity: y is up). */
static int32_t ma_in_box(const MaBox* b, float wx, float wy, float wz)
{
    float lo, hi;
    if (!b) return 0;
    lo = b->minX < b->maxX ? b->minX : b->maxX;
    hi = b->minX < b->maxX ? b->maxX : b->minX;
    if (wx < lo || wx > hi) return 0;
    lo = b->minY < b->maxY ? b->minY : b->maxY;
    hi = b->minY < b->maxY ? b->maxY : b->minY;
    if (wz < lo || wz > hi) return 0;          /* map y IS world z */
    lo = b->minH < b->maxH ? b->minH : b->maxH;
    hi = b->minH < b->maxH ? b->maxH : b->minH;
    if (wy < lo || wy > hi) return 0;          /* box z IS world y */
    return 1;
}

/* Pick the layer the player is actually ON. Returns the index, or -1, and
 * always writes *why. gameBounds first because it is a data-backed answer;
 * defaultLevel second because it is a stated fallback; first layer last. This
 * is the same ladder `sp/page.nim`'s `pickLayer` uses, so the browser view and
 * the in-game view cannot disagree about which floor you are on. */
static int32_t ma_pick_layer(const MaArt* a, float wx, float wy, float wz,
                             int32_t* why)
{
    int32_t i, j;
    if (why) *why = MA_LAYER_NONE;
    if (!a || !a->valid || a->nLayers <= 0) return -1;

    for (i = 0; i < a->nLayers && i < MA_MAX_LAYERS; i++) {
        const MaLayer* L = &a->layer[i];
        for (j = 0; j < L->nBoxes && j < MA_MAX_BOXES; j++) {
            if (ma_in_box(&L->box[j], wx, wy, wz)) {
                if (why) *why = MA_LAYER_GAMEBOUNDS;
                return i;
            }
        }
    }
    for (i = 0; i < a->nLayers && i < MA_MAX_LAYERS; i++) {
        if (a->layer[i].level == a->defaultLevel) {
            if (why) *why = MA_LAYER_DEFAULT;
            return i;
        }
    }
    if (why) *why = MA_LAYER_FIRST;
    return 0;
}

/* ---- tile -> pane ------------------------------------------------------
 *
 * A tile's map-plane rect projected onto the top-down pane, CLIPPED to the pane
 * and with the UV rect narrowed by exactly the same fraction. Returns 1 and
 * fills the outputs when any of the tile is visible.
 *
 * The pane transform is mm_topdown's with rot = 0 (see the header note on why
 * rotation is refused rather than approximated):
 *
 *     sx = px + size/2 + (mapX - cx) * scale
 *     sy = py + size/2 - (mapY - cz) * scale        scale = size / spanM
 *
 * The Y NEGATION is why maxY becomes the TOP edge and v = 0 belongs to maxY.
 * A tile drawn with v flipped is vertically mirrored art in the right place,
 * which is the exact class of failure this file exists to make falsifiable.
 */
static int32_t ma_tile_quad(const MaRect* t,
                            float cx, float cz,
                            float px, float py, float size, float spanM,
                            float* dx, float* dy, float* dw, float* dh,
                            float* u0, float* v0, float* u1, float* v1)
{
    float scale, x0, x1, y0, y1, cx0, cx1, cy0, cy1;
    float fu0, fu1, fv0, fv1;

    if (!t || !dx || !dy || !dw || !dh || !u0 || !v0 || !u1 || !v1) return 0;
    if (!(size > 0.0f) || !(spanM > 0.0001f)) return 0;
    if (!(t->maxX > t->minX) || !(t->maxY > t->minY)) return 0;

    scale = size / spanM;
    x0 = px + size * 0.5f + (t->minX - cx) * scale;
    x1 = px + size * 0.5f + (t->maxX - cx) * scale;
    y0 = py + size * 0.5f - (t->maxY - cz) * scale;   /* maxY is the TOP */
    y1 = py + size * 0.5f - (t->minY - cz) * scale;

    if (!(x1 > x0) || !(y1 > y0)) return 0;

    cx0 = x0 < px ? px : x0;
    cy0 = y0 < py ? py : y0;
    cx1 = x1 > px + size ? px + size : x1;
    cy1 = y1 > py + size ? py + size : y1;
    if (!(cx1 > cx0) || !(cy1 > cy0)) return 0;       /* entirely off-pane */

    fu0 = (cx0 - x0) / (x1 - x0);
    fu1 = (cx1 - x0) / (x1 - x0);
    fv0 = (cy0 - y0) / (y1 - y0);
    fv1 = (cy1 - y0) / (y1 - y0);

    *dx = cx0; *dy = cy0; *dw = cx1 - cx0; *dh = cy1 - cy0;
    *u0 = fu0; *u1 = fu1; *v0 = fv0; *v1 = fv1;
    return 1;
}

/* Is a given world point inside a tile's rect? Used by the test to pin the
 * projection against `mm_tile_index`, and by nothing that draws. */
static int32_t ma_rect_has(const MaRect* r, float mapX, float mapY)
{
    if (!r) return 0;
    return (mapX >= r->minX && mapX <= r->maxX &&
            mapY >= r->minY && mapY <= r->maxY) ? 1 : 0;
}

/* The single gate the caller asks before drawing anything. It exists so the
 * refusal is produced in ONE place and can therefore be printed by the diag in
 * the same words every time. `rot` is the pane rotation in radians.
 *
 * ROTATION IS NO LONGER REFUSED. The region gained a ROTATED textured quad
 * (AOWL_REGION_CMD_QUADR, ABI 3): the renderer rotates the four dest corners
 * about the pane centre and clips to the pane, so heading-up art registers
 * against the blips instead of being misregistered. `rot` is therefore ignored
 * here; a heading-up pane draws its art via `ma_tile_rect_rot` below rather
 * than falling back to the labelled grid. MA_REFUSE_ROTATED is kept defined for
 * ABI/diag stability but is never returned. */
static int32_t ma_can_draw(const MaArt* a, int32_t hasPos, float rot)
{
    (void)rot;
    if (!hasPos) return MA_REFUSE_NOPOS;
    if (!a || !a->valid) return MA_REFUSE_NOMAP;
    if (a->nLayers <= 0) return MA_REFUSE_NOLAYER;
    return MA_OK;
}

/* HEADING-UP tile geometry. Unlike `ma_tile_quad`, this neither clips the dest
 * rect nor narrows the UV: it returns the tile's UNCLIPPED north-up (rot=0)
 * dest rect (dx,dy,dw,dh) with the full 0..1 UV implied, because the RENDERER
 * rotates those four corners about the pane centre (rcos,rsin) and clips to the
 * pane square (AOWL_REGION_CMD_QUADR). `rcos`/`rsin` are the SAME cos/sin the
 * renderer will apply, so the cull here and the draw there agree by
 * construction: rotating a rot=0 corner about the pane centre reproduces
 * mm_topdown's heading-up projection exactly (proven in mapstest).
 *
 * Returns 1 with the rect filled when the tile's ROTATED bounding box overlaps
 * the pane square (a cheap cull so an off-pane tile costs no command), 0 to
 * skip. The v axis is already oriented: dy is placed from maxY (the TOP), so
 * v=0 belongs to the top exactly as in ma_tile_quad. */
static int32_t ma_tile_rect_rot(const MaRect* t, float cx, float cz,
                                float px, float py, float size, float spanM,
                                float rcos, float rsin,
                                float* dx, float* dy, float* dw, float* dh)
{
    float scale, x0, x1, y0, y1, pcx, pcy;
    float minx, miny, maxx, maxy, xs[4], ys[4];
    int32_t i;
    if (!t || !dx || !dy || !dw || !dh) return 0;
    if (!(size > 0.0f) || !(spanM > 0.0001f)) return 0;
    if (!(t->maxX > t->minX) || !(t->maxY > t->minY)) return 0;

    scale = size / spanM;
    x0 = px + size * 0.5f + (t->minX - cx) * scale;
    x1 = px + size * 0.5f + (t->maxX - cx) * scale;
    y0 = py + size * 0.5f - (t->maxY - cz) * scale;   /* maxY is the TOP */
    y1 = py + size * 0.5f - (t->minY - cz) * scale;
    if (!(x1 > x0) || !(y1 > y0)) return 0;
    *dx = x0; *dy = y0; *dw = x1 - x0; *dh = y1 - y0;

    /* Cull: rotate the four corners about the pane centre, take their AABB,
     * test overlap with the pane square. */
    pcx = px + size * 0.5f; pcy = py + size * 0.5f;
    xs[0] = x0; ys[0] = y0; xs[1] = x1; ys[1] = y0;
    xs[2] = x1; ys[2] = y1; xs[3] = x0; ys[3] = y1;
    minx = miny = 1e30f; maxx = maxy = -1e30f;
    for (i = 0; i < 4; i++) {
        float ddx = xs[i] - pcx, ddy = ys[i] - pcy;
        float rx = pcx + ddx * rcos - ddy * rsin;
        float ry = pcy + ddx * rsin + ddy * rcos;
        if (rx < minx) minx = rx;
        if (rx > maxx) maxx = rx;
        if (ry < miny) miny = ry;
        if (ry > maxy) maxy = ry;
    }
    if (maxx < px || minx > px + size || maxy < py || miny > py + size)
        return 0;                                     /* wholly off the pane */
    return 1;
}

#endif /* AOWL_MAPART_H */
