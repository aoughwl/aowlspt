## sp/hud.nim -- the IN-GAME draw: radar and direction indicators, over the
## SHARED per-frame region.
##
## ## Why this file exists, and what it replaced
##
## The mod's original answer for the radar and the indicators was a browser
## page. `maps.nim`'s own header says why, and says plainly what blocked the
## in-game version: "it is ownership of the existing ESP draw region, not a
## capability this build lacks". That reading of the hazard was RIGHT -- a
## second detour on one function overwrites the first's trampoline -- and the
## conclusion drawn from it was wrong. The answer was never to add a second
## hook, and never to borrow `abi/aowlspt_admin.h`, which is another mod's
## private surface. It is to RIDE the one dispatch point as a participant.
##
## `abi/aowlspt_region.h` is exactly that contract, and this file is a plain
## client of it: register a DRAW callback, get called once a frame on Unity's
## thread inside ONE `aowl_p_p_seh`, submit screen-space POD commands, and let
## the D3D11 overlay drain and rasterise them on the render thread.
##
## ## What this file may and may not touch
##
## It resolves NO IL2CPP name, calls NO game method and reads NO game memory.
## Every position it draws was already read, guarded, by `sp/world.nim` on the
## same thread earlier in the frame and copied into a POD mirror here. The draw
## callback is therefore pure C arithmetic over a fixed-size static array: it
## cannot fault on a game pointer because it holds none, and it cannot allocate
## because there is nothing in it that allocates.
##
## That is also why the callback is C and not Nim. The region enters it inside
## the shim's guard, and the guard is not re-entrant; a Nim callback would drag
## the runtime (and, on any allocating path, a lock) into a frame that must do
## neither. The Nim side of this file only ever fills the mirror and reads the
## meter.
##
## ## Threading
##
## `hudPublish` runs on Unity's main thread (the `everyMain` collector in
## `maps.nim`, immediately after `collect`). The region dispatches the draw
## callback on that same thread. One writer, one reader, same thread, so there
## is no lock here and none is needed -- and no torn read is possible either.
## The mod's OWN publish timer thread never touches this mirror; it reads
## `gSnap` under `maps.nim`'s lock, which is a different object.
##
## ## The meter
##
## `hudFrames` / `hudDrawn` / `hudBlips` are the mod's own draw budget meter,
## separate from the region's per-participant one (`aowl_region_status`, which
## the host logs). Two numbers that can disagree: frames counts every dispatch,
## drawn counts the dispatches that had a local player to centre on. If frames
## climbs and drawn does not, the region is alive and the FEED is not -- which
## is a different bug from "nothing is on screen", and reporting them as one
## number would hide it.

import aowlspt
import world  # the Snapshot this file mirrors; no game memory is read here

{.emit: """
#include <stdint.h>
#include <string.h>
#include <math.h>
#include "aowlspt_region.h"
#include "sp/mapmath.h"
#include "sp/mapart.h"

#define MHUD_MAX 128
#define MHUD_RGBA(r, g, b, a) \
    ((uint32_t)((uint32_t)(r) | ((uint32_t)(g) << 8) | \
                ((uint32_t)(b) << 16) | ((uint32_t)(a) << 24)))

/* Packing MATCHES `AOWL_RGBA` in abi/aowlspt_overlay.h (r | g<<8 | b<<16 |
 * a<<24), which is what the overlay's DXGI_FORMAT_R8G8B8A8_UNORM vertex
 * expects. It is redefined here rather than included, because overlay.h is a
 * 8,800-line header two other agents are editing and this file needs four
 * bytes out of it. If that packing ever changes, the colours here go wrong --
 * visibly and harmlessly, never fatally. */

typedef struct { float x, y, z; int32_t bot; } MHudEnt;

static struct {
    int32_t  n;
    MHudEnt  e[MHUD_MAX];
    float    px, py, pz;
    int32_t  hasLocal;
    float    heading;        /* radians; 0 = +Z. Only used if hasHeading. */
    int32_t  hasHeading;
    float    radiusM;

    /* Layout. Pixels, origin top-left -- the region's stated space. */
    float    screenW, screenH;
    int32_t  radarOn, indicatorsOn;
    float    radarSize, radarX, radarY;
    int32_t  showBots, showPlayers;

    /* the MAP pane -- a big top-down view, distinct from the small radar */
    int32_t  mapOn;
    float    mapX, mapY, mapSize, mapSpanM;
    int32_t  mapGrid;          /* grid line count per axis, 0 = none */
    float    indicatorInset;   /* margin the edge markers clamp onto */

    int64_t  frames, drawn, blips;
    /* Indicators are drawn one of TWO ways and the two are counted apart, on
     * purpose. `indProjected` is the real, camera-relative answer via the
     * region's projector; `indBearing` is the north-up fallback used when no
     * projector is installed, which points at world north and not at what the
     * player is looking at. One combined number would let a session in which
     * the projector never arrived read exactly like one in which it did --
     * which is the failure this project keeps paying for. */
    int64_t  indProjected, indBearing, indRefused;
    int32_t  screenFromRegion; /* 1 = measured back buffer, 0 = config guess */
    int32_t  handle;
} g_mhud;

static void mhud_reset(void) {
    memset(&g_mhud, 0, sizeof(g_mhud));
    g_mhud.handle         = -1;
    g_mhud.radiusM        = 120.0f;
    g_mhud.mapSpanM       = 500.0f;
    g_mhud.indicatorInset = 48.0f;
}

/* ---- the mirror, filled on Unity's thread before the draw ------------- */

static void mhud_begin(float px, float py, float pz, int32_t hasLocal,
                       float heading, int32_t hasHeading) {
    g_mhud.n = 0;
    g_mhud.px = px; g_mhud.py = py; g_mhud.pz = pz;
    g_mhud.hasLocal = hasLocal ? 1 : 0;
    g_mhud.heading = heading;
    g_mhud.hasHeading = hasHeading ? 1 : 0;
}

static void mhud_add(float x, float y, float z, int32_t bot) {
    if (g_mhud.n >= MHUD_MAX) return;   /* capped by construction */
    g_mhud.e[g_mhud.n].x = x;
    g_mhud.e[g_mhud.n].y = y;
    g_mhud.e[g_mhud.n].z = z;
    g_mhud.e[g_mhud.n].bot = bot ? 1 : 0;
    g_mhud.n++;
}

static void mhud_configure(float radiusM, float screenW, float screenH,
                           int32_t radarOn, int32_t indicatorsOn,
                           float radarSize, float radarX, float radarY,
                           int32_t showBots, int32_t showPlayers) {
    g_mhud.radiusM      = radiusM > 1.0f ? radiusM : 1.0f;
    g_mhud.screenW      = screenW > 16.0f ? screenW : 1920.0f;
    g_mhud.screenH      = screenH > 16.0f ? screenH : 1080.0f;
    g_mhud.radarOn      = radarOn ? 1 : 0;
    g_mhud.indicatorsOn = indicatorsOn ? 1 : 0;
    g_mhud.radarSize    = radarSize > 32.0f ? radarSize : 32.0f;
    g_mhud.radarX       = radarX;
    g_mhud.radarY       = radarY;
    g_mhud.showBots     = showBots ? 1 : 0;
    g_mhud.showPlayers  = showPlayers ? 1 : 0;
}

static void mhud_configure_map(int32_t mapOn, float mapX, float mapY,
                               float mapSize, float mapSpanM, int32_t mapGrid,
                               float indicatorInset) {
    g_mhud.mapOn          = mapOn ? 1 : 0;
    g_mhud.mapX           = mapX;
    g_mhud.mapY           = mapY;
    g_mhud.mapSize        = mapSize > 64.0f ? mapSize : 64.0f;
    g_mhud.mapSpanM       = mapSpanM > 10.0f ? mapSpanM : 10.0f;
    g_mhud.mapGrid        = (mapGrid > 0 && mapGrid <= 32) ? mapGrid : 0;
    g_mhud.indicatorInset = indicatorInset > 4.0f ? indicatorInset : 4.0f;
}

/* THE BACK-BUFFER SIZE, asked of the region rather than guessed.
 *
 * `aowl_region_screen_known()` is checked first and the answer is REMEMBERED
 * as `screenFromRegion`, because the getters return 0 until the host has
 * published a measurement and 0 is not a refusal -- it is a plausible number
 * that collapses every edge-anchored mark into the top-left corner. The mod's
 * config values remain the fallback, and the status line says which was used,
 * so "my indicators are all in the corner" is a distinguishable report. */
static void mhud_screen(float* w, float* h) {
    if (aowl_region_screen_known()) {
        *w = (float)aowl_region_screen_w();
        *h = (float)aowl_region_screen_h();
        g_mhud.screenFromRegion = 1;
    } else {
        *w = g_mhud.screenW;
        *h = g_mhud.screenH;
        g_mhud.screenFromRegion = 0;
    }
}

/* ==================== MAP ART ==========================================
 *
 * Real map art -- buildings, layout, the floor you are on -- drawn under the
 * blips as textured quads, instead of the bare grid.
 *
 * The art is SVG in `mods/maps/data/maps/`. It is rasterised to BC1 tiles
 * OFFLINE by `tools/maptiles.py` (run as `aowl build maptiles`), which also
 * writes a fixed-layout binary manifest. NOTHING here parses SVG, decodes an
 * image, or allocates: the load is one fread per tile into a static buffer, and
 * the per-frame cost is one `aowl_region_quad` per visible tile.
 *
 * The geometry -- layer choice by height, tile rect to pane rect, and the
 * refusal codes -- is in `sp/mapart.h`, so `tests/overlayhost/mapstest.c` can
 * assert on the finished numbers offline. This file only submits.
 *
 * PER-FRAME ALLOCATION: none. `aowl_region_texture_define` is called from the
 * UNITY thread (mhud_art_upload, driven by the mod's publish tick), never from
 * the draw callback, and it is idempotent for a resident key of the same shape
 * -- so the steady state is a no-op that copies zero bytes.
 */

#define MA_ART_MAX_TILE_BYTES 131072u    /* a 512x512 BC1 tile */
#define MA_ART_BIN_MAX        (256u * 1024u)
#define MA_ART_HDR            32
#define MA_ART_MAPREC        128
#define MA_ART_LAYERREC      232
#define MA_ART_TILEREC       120
#define MA_ART_MAGIC         0x31544D41u  /* 'AMT1' */

static struct {
    MaArt    art;
    int32_t  loaded;          /* a manifest has been read                    */
    int32_t  tilePx;
    uint32_t tileBytes;
    uint8_t  bytes[MA_MAX_TILES][MA_ART_MAX_TILE_BYTES];
    int32_t  haveBytes[MA_MAX_TILES];
    char     file[MA_MAX_TILES][96];   /* the tile path, for the Nim loader */
    int32_t  candidates;               /* how many maps' bounds contained us */

    /* the last DRAW verdict, for the diag. Never a bare count. */
    int32_t  refusal;         /* MA_* */
    int32_t  layerIdx, layerWhy, layerLevel;
    int32_t  tilesDrawn, tilesRefused;
    int64_t  artFrames;
    char     mapId[32];
} g_art;

static void mhud_art_reset(void) { memset(&g_art, 0, sizeof(g_art)); }

/* Forward-declared because the binder below uses it and the accessor block
 * that defines it reads better next to the other accessors. */
static int32_t mhud_art_copy(const char* src, char* out, int32_t cap);

/* ---- little-endian field reads, by OFFSET and not by struct cast ------
 * A packed struct would depend on the compiler honouring #pragma pack for a
 * layout produced by Python. These read bytes, so the two cannot disagree, and
 * every read is bounds-checked against the buffer the caller supplied. */
static int32_t ma_i32(const uint8_t* p) {
    return (int32_t)((uint32_t)p[0] | ((uint32_t)p[1] << 8) |
                     ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24));
}
static uint32_t ma_u32(const uint8_t* p) { return (uint32_t)ma_i32(p); }
static float ma_f32(const uint8_t* p) {
    union { uint32_t u; float f; } c;
    c.u = ma_u32(p);
    return c.f;
}

/* Header validation, once, so both binders share exactly one set of bounds
 * checks. Fills the four offsets/counts. Returns 1 when the file is coherent. */
static int32_t ma_bin_head(const uint8_t* bin, uint32_t n,
                           uint32_t* nMaps, uint32_t* nLayers, uint32_t* nTiles,
                           uint32_t* tilePx, uint32_t* tb,
                           uint32_t* offMaps, uint32_t* offLayers,
                           uint32_t* offTiles)
{
    if (!bin || n < (uint32_t)MA_ART_HDR) return 0;
    if (ma_u32(bin) != MA_ART_MAGIC || ma_u32(bin + 4) != 1u) return 0;
    *tilePx  = ma_u32(bin + 8);
    *nMaps   = ma_u32(bin + 16);
    *nLayers = ma_u32(bin + 20);
    *nTiles  = ma_u32(bin + 24);
    *tb      = ma_u32(bin + 28);
    if (!*tilePx || *tb == 0 || *tb > MA_ART_MAX_TILE_BYTES) return 0;
    if (*nMaps == 0 || *nMaps > 4096u || *nLayers > 65536u || *nTiles > 262144u)
        return 0;
    *offMaps   = MA_ART_HDR;
    *offLayers = *offMaps + *nMaps * MA_ART_MAPREC;
    *offTiles  = *offLayers + *nLayers * MA_ART_LAYERREC;
    /* EXACT, not >=. A file whose records do not account for every byte is a
     * file we do not understand, and reading it anyway is how a plausible
     * wrong offset gets believed. */
    if (*offTiles + *nTiles * (uint32_t)MA_ART_TILEREC != n) return 0;
    return 1;
}

/* Which map is this raid on? The raid's location id is NOT available to this
 * mod (see sp/page.nim), so this is the SAME weak heuristic the browser view
 * uses: the smallest-area map whose bounds contain the player. It records how
 * many maps matched, and the diag PRINTS that -- a 1 is a real answer and
 * anything above 1 is a guess, and the two must never look alike. */
static int32_t ma_bin_pick_map(const uint8_t* bin, uint32_t nMaps,
                               uint32_t offMaps, float wx, float wz,
                               int32_t* candidates)
{
    uint32_t m;
    int32_t best = -1;
    float bestArea = 0.0f;
    if (candidates) *candidates = 0;
    for (m = 0; m < nMaps; m++) {
        const uint8_t* mr = bin + offMaps + m * MA_ART_MAPREC;
        float x0 = ma_f32(mr + 96 + 16), y0 = ma_f32(mr + 96 + 20);
        float x1 = ma_f32(mr + 96 + 24), y1 = ma_f32(mr + 96 + 28);
        float lo, hi, area;
        lo = x0 < x1 ? x0 : x1; hi = x0 < x1 ? x1 : x0;
        if (wx < lo || wx > hi) continue;
        lo = y0 < y1 ? y0 : y1; hi = y0 < y1 ? y1 : y0;
        if (wz < lo || wz > hi) continue;      /* map y IS world z */
        if (candidates) (*candidates)++;
        area = (hi - lo) * ((x1 > x0 ? x1 - x0 : x0 - x1));
        if (best < 0 || area < bestArea) { best = (int32_t)m; bestArea = area; }
    }
    return best;
}

/* Bind ONE map out of the binary manifest, by its index. Everything is capped
 * and every index is checked against the counts in the HEADER, never against a
 * count in the record it came from. */
static int32_t ma_bind_index(const uint8_t* bin, uint32_t n, int32_t want)
{
    uint32_t nMaps, nLayers, nTiles, tilePx, tb;
    uint32_t offMaps, offLayers, offTiles;
    uint32_t m, j, t;

    g_art.art.valid = 0;
    if (!ma_bin_head(bin, n, &nMaps, &nLayers, &nTiles, &tilePx, &tb,
                     &offMaps, &offLayers, &offTiles)) return 0;
    if (want < 0 || (uint32_t)want >= nMaps) return 0;
    m = (uint32_t)want;
    {
        const uint8_t* mr = bin + offMaps + m * MA_ART_MAPREC;
        {
            int32_t l0 = ma_i32(mr + 96 + 8);
            int32_t nl = ma_i32(mr + 96 + 12);
            int32_t li;
            if (l0 < 0 || nl <= 0 || (uint32_t)(l0 + nl) > nLayers) return 0;
            memset(&g_art.art, 0, sizeof(g_art.art));
            g_art.art.rotationDeg  = ma_i32(mr + 96 + 0);
            g_art.art.defaultLevel = ma_i32(mr + 96 + 4);
            memcpy(g_art.mapId, mr, 31);
            g_art.mapId[31] = 0;
            if (nl > MA_MAX_LAYERS) nl = MA_MAX_LAYERS;
            g_art.art.nLayers = nl;
            g_art.art.nTiles = 0;

            for (li = 0; li < nl; li++) {
                const uint8_t* lr = bin + offLayers
                                  + (uint32_t)(l0 + li) * MA_ART_LAYERREC;
                MaLayer* L = &g_art.art.layer[li];
                int32_t t0, nt, nb;
                L->level = ma_i32(lr + 0);
                L->imageBounds.minX = ma_f32(lr + 4);
                L->imageBounds.minY = ma_f32(lr + 8);
                L->imageBounds.maxX = ma_f32(lr + 12);
                L->imageBounds.maxY = ma_f32(lr + 16);
                L->cols = ma_i32(lr + 20);
                L->rows = ma_i32(lr + 24);
                t0  = ma_i32(lr + 28);
                nt  = ma_i32(lr + 32);
                nb  = ma_i32(lr + 36);
                if (nb < 0) nb = 0;
                if (nb > MA_MAX_BOXES) nb = MA_MAX_BOXES;
                L->nBoxes = nb;
                for (j = 0; j < (uint32_t)nb; j++) {
                    const uint8_t* b = lr + 40 + j * 24;
                    L->box[j].minX = ma_f32(b + 0);
                    L->box[j].minY = ma_f32(b + 4);
                    L->box[j].minH = ma_f32(b + 8);
                    L->box[j].maxX = ma_f32(b + 12);
                    L->box[j].maxY = ma_f32(b + 16);
                    L->box[j].maxH = ma_f32(b + 20);
                }
                L->tile0 = g_art.art.nTiles;
                L->nTiles = 0;
                if (t0 < 0 || nt <= 0 || (uint32_t)(t0 + nt) > nTiles) continue;
                for (t = 0; t < (uint32_t)nt; t++) {
                    const uint8_t* tr = bin + offTiles
                                      + (uint32_t)(t0 + (int32_t)t) * MA_ART_TILEREC;
                    int32_t slot = g_art.art.nTiles;
                    if (slot >= MA_MAX_TILES) break;   /* capped, never grows */
                    g_art.art.tile[slot].col = ma_i32(tr + 0);
                    g_art.art.tile[slot].row = ma_i32(tr + 4);
                    g_art.art.tile[slot].world.minX = ma_f32(tr + 8);
                    g_art.art.tile[slot].world.minY = ma_f32(tr + 12);
                    g_art.art.tile[slot].world.maxX = ma_f32(tr + 16);
                    g_art.art.tile[slot].world.maxY = ma_f32(tr + 20);
                    /* the tile's file path, so the Nim loader never has to
                     * know this record layout */
                    {
                        int32_t q = 0;
                        const char* fp = (const char*)(tr + 24);
                        while (fp[q] && q < 95) { g_art.file[slot][q] = fp[q]; q++; }
                        g_art.file[slot][q] = 0;
                    }
                    /* The key is derived, not a counter: it must be stable
                     * across a rebind so a re-`define` of an unchanged tile is
                     * the idempotent no-op the ABI promises. */
                    g_art.art.tile[slot].key =
                        ((uint64_t)0xA0410000u << 32)
                        ^ ((uint64_t)(m + 1) << 24)
                        ^ ((uint64_t)(l0 + li) << 8)
                        ^ (uint64_t)(t + 1);
                    g_art.art.nTiles++;
                    L->nTiles++;
                }
            }
            g_art.tilePx = (int32_t)tilePx;
            g_art.tileBytes = tb;
            g_art.art.valid = (g_art.art.nTiles > 0) ? 1 : 0;
            g_art.loaded = 1;
            return g_art.art.valid;
        }
    }
}

/* THE ENTRY POINT the mod calls, on the Unity thread, when a position first
 * validates or when the inferred map changes. Everything above is private.
 *
 * Returns the number of tiles bound (0 = nothing to draw, and the diag will
 * say which of NOMAP / NOLAYER it was). Re-binding the SAME map is a no-op, so
 * this may be called every publish tick without re-reading anything. */
static int32_t mhud_art_bind_at(const uint8_t* bin, uint32_t n,
                                float wx, float wz)
{
    uint32_t nMaps, nLayers, nTiles, tilePx, tb, oM, oL, oT;
    int32_t pick, cand = 0;
    if (!ma_bin_head(bin, n, &nMaps, &nLayers, &nTiles, &tilePx, &tb,
                     &oM, &oL, &oT)) { g_art.loaded = 0; return 0; }
    g_art.loaded = 1;
    pick = ma_bin_pick_map(bin, nMaps, oM, wx, wz, &cand);
    g_art.candidates = cand;
    if (pick < 0) { g_art.art.valid = 0; g_art.refusal = MA_REFUSE_NOMAP; return 0; }
    {
        const uint8_t* mr = bin + oM + (uint32_t)pick * MA_ART_MAPREC;
        /* Already bound to this map: do not clear the uploaded bytes. */
        if (g_art.art.valid && strncmp(g_art.mapId, (const char*)mr, 31) == 0)
            return g_art.art.nTiles;
    }
    memset(g_art.haveBytes, 0, sizeof(g_art.haveBytes));
    if (!ma_bind_index(bin, n, pick)) { g_art.refusal = MA_REFUSE_NOMAP; return 0; }
    return g_art.art.nTiles;
}

static int32_t mhud_art_candidates(void) { return g_art.candidates; }

static int32_t mhud_art_tile_file(int32_t idx, char* out, int32_t cap) {
    if (idx < 0 || idx >= g_art.art.nTiles || idx >= MA_MAX_TILES) {
        if (out && cap > 0) out[0] = 0;
        return 0;
    }
    return mhud_art_copy(g_art.file[idx], out, cap);
}

static int32_t mhud_art_tile_have(int32_t idx) {
    if (idx < 0 || idx >= MA_MAX_TILES) return 0;
    return g_art.haveBytes[idx];
}

/* Hand one tile's BC1 bytes in, from the Unity thread. `idx` is the slot
 * assigned by mhud_art_bind, so the caller cannot invent one. */
static int32_t mhud_art_tile_bytes(int32_t idx, const void* data, uint32_t n)
{
    if (idx < 0 || idx >= g_art.art.nTiles || idx >= MA_MAX_TILES) return 0;
    if (!data || n == 0 || n != g_art.tileBytes) return 0;
    if (n > MA_ART_MAX_TILE_BYTES) return 0;
    memcpy(g_art.bytes[idx], data, n);
    g_art.haveBytes[idx] = 1;
    return 1;
}

/* Take a whole .dds FILE and copy only its payload. Doing the 128-byte header
 * skip here rather than in Nim is not a style choice: slicing a 128 KiB string
 * in nimony is a per-byte loop on the Unity thread, and this is a pointer
 * addition. The header is CHECKED, not assumed -- a file whose magic is not
 * 'DDS ' is refused, so a half-written or wrong file cannot be uploaded as
 * texels. */
static int32_t mhud_art_tile_dds(int32_t idx, const char* dds, uint32_t n)
{
    if (!dds || n <= 128u) return 0;
    if (dds[0] != 'D' || dds[1] != 'D' || dds[2] != 'S' || dds[3] != ' ')
        return 0;
    return mhud_art_tile_bytes(idx, dds + 128, n - 128u);
}

/* UNITY THREAD. Idempotent for a resident key of the same shape, so calling
 * this every publish tick costs nothing and keeps the working set alive against
 * the region's LRU. Returns how many tiles are resident. */
static int32_t mhud_art_upload(void)
{
    int32_t i, ok = 0;
    if (!g_art.art.valid) return 0;
    for (i = 0; i < g_art.art.nTiles && i < MA_MAX_TILES; i++) {
        if (!g_art.haveBytes[i]) continue;
        if (aowl_region_texture_define(g_art.art.tile[i].key,
                                       AOWL_REGION_TEXFMT_BC1,
                                       g_art.tilePx, g_art.tilePx,
                                       g_art.bytes[i], g_art.tileBytes)
            == AOWL_REGION_OK) ok++;
    }
    return ok;
}

/* RENDER THREAD, inside the draw callback. Submits quads only. Returns the
 * number drawn; the refusal, when zero, is already in g_art.refusal. */
static int32_t mhud_art_draw_pane(float px, float py, float size, float spanM,
                                  float rot, uint32_t tint)
{
    int32_t r, li, why = MA_LAYER_NONE, i, drawn = 0;
    const MaLayer* L;

    r = ma_can_draw(&g_art.art, g_mhud.hasLocal, rot);
    if (r != MA_OK) { g_art.refusal = r; return 0; }

    li = ma_pick_layer(&g_art.art, g_mhud.px, g_mhud.py, g_mhud.pz, &why);
    if (li < 0) { g_art.refusal = MA_REFUSE_NOLAYER; return 0; }
    g_art.layerIdx = li;
    g_art.layerWhy = why;
    g_art.layerLevel = g_art.art.layer[li].level;
    L = &g_art.art.layer[li];

    for (i = 0; i < L->nTiles && i < MA_MAX_TILES; i++) {
        int32_t slot = L->tile0 + i;
        float dx, dy, dw, dh, u0, v0, u1, v1;
        if (slot < 0 || slot >= g_art.art.nTiles) continue;
        if (!g_art.haveBytes[slot]) continue;
        if (!ma_tile_quad(&g_art.art.tile[slot].world,
                          g_mhud.px, g_mhud.pz, px, py, size, spanM,
                          &dx, &dy, &dw, &dh, &u0, &v0, &u1, &v1))
            continue;                                  /* off-pane, not an error */
        if (aowl_region_quad(dx, dy, dw, dh, u0, v0, u1, v1,
                             g_art.art.tile[slot].key, tint) == AOWL_REGION_OK)
            drawn++;
        else
            g_art.tilesRefused++;
    }
    if (drawn == 0)
        g_art.refusal = g_art.tilesRefused ? MA_REFUSE_NOTEX : MA_REFUSE_OFFPANE;
    else
        g_art.refusal = MA_OK;
    return drawn;
}

/* ---- the draw -------------------------------------------------------- *
 *
 * NO LINE COMMANDS. `AOWL_REGION_CMD_LINE` exists, but the overlay renders a
 * line as the axis-aligned quad spanning its two endpoints, so a diagonal
 * comes out as a filled rectangle. Every mark here is therefore a FILL or a
 * BOX, which render exactly. Stated rather than discovered again.
 *
 * Command budget: 3 fixed marks + at most 2 per entity + 1 label, so at most
 * 3 + 2*128 + 1 = 260 against AOWL_REGION_MAX_CMDS (2048). It cannot overrun.
 */
static void mhud_draw(void* user, int64_t frame) {
    float rot, scrW, scrH;
    int32_t i;
    (void)user; (void)frame;

    g_mhud.frames++;
    if (!g_mhud.hasLocal) return;   /* no centre => nothing truthful to draw */
    g_mhud.drawn++;

    mhud_screen(&scrW, &scrH);

    /* North-up unless a heading was actually MEASURED. `hasHeading` is false
     * today (sp/world.nim reads no rotation and says so), so this rotates by
     * nothing rather than by a guessed zero that LOOKS like a heading. When a
     * heading does arrive, both the radar and the map pane become heading-up
     * together, because both take `rot` from this one place. */
    rot = g_mhud.hasHeading ? g_mhud.heading : 0.0f;

    /* ---- the MAP pane: the same top-down view, at map scale -------------- *
     * Player-CENTRED, not map-anchored. Anchoring to the level would need the
     * pocketmap pyramid's world origin and extent, which nothing here has
     * measured; centring on the player needs only the player's position,
     * which sp/world.nim already validated. A wrong origin would slide every
     * feature of the map a constant distance off and still look like a map,
     * so the anchored version waits for a measurement rather than a guess.
     *
     * There is NO map ARTWORK under these blips. The region command set is
     * FILL / BOX / LINE / TEXT -- there is no textured-quad command, so the
     * pocketmap tiles cannot be submitted through this contract at all. The
     * grid is a scale reference and is drawn as such, not as scenery. */
    g_art.tilesDrawn = 0;
    g_art.artFrames++;

    if (g_mhud.mapOn) {
        float mx = g_mhud.mapX, my = g_mhud.mapY, ms = g_mhud.mapSize;
        int32_t art;
        aowl_region_fill(mx, my, ms, ms, MHUD_RGBA(8, 10, 14, 190));

        /* THE ART, under everything. Drawn first so the frame, the grid, the
         * blips and the label all land on top of it. */
        art = mhud_art_draw_pane(mx, my, ms, g_mhud.mapSpanM, rot,
                                 MHUD_RGBA(255, 255, 255, 225));
        g_art.tilesDrawn += art;

        aowl_region_box(mx, my, ms, ms, 2.0f, MHUD_RGBA(150, 180, 210, 220));
        /* The grid is a SCALE REFERENCE when art is present and the FALLBACK
         * PICTURE when it is not, so it is drawn thinner over art -- and the
         * diag's ART line, not this, is what says which happened. */
        if (art == 0 && g_mhud.mapGrid > 0) {
            int32_t g;
            float step = ms / (float)g_mhud.mapGrid;
            for (g = 1; g < g_mhud.mapGrid; g++) {
                float o = (float)g * step;
                /* 1px FILLs, not LINEs: the overlay renders a LINE as the
                 * axis-aligned quad spanning its endpoints, which is right for
                 * these two but wrong for anything diagonal, so this file uses
                 * FILL everywhere and never has to remember the exception. */
                aowl_region_fill(mx + o, my, 1.0f, ms,
                                 MHUD_RGBA(60, 75, 95, 120));
                aowl_region_fill(mx, my + o, ms, 1.0f,
                                 MHUD_RGBA(60, 75, 95, 120));
            }
        }
        /* the player, at the pane's centre by construction */
        {
            MmPt me = mm_topdown(g_mhud.px, g_mhud.pz, g_mhud.px, g_mhud.pz,
                                 mx, my, ms, g_mhud.mapSpanM, rot);
            aowl_region_fill(me.x - 3.0f, me.y - 3.0f, 6.0f, 6.0f,
                             MHUD_RGBA(255, 255, 255, 255));
        }
        /* A north pip, so which way is up is never a guess. It sits at the top
         * of the pane when north-up and swings with `rot` when heading-up. */
        {
            MmPt np = mm_topdown(g_mhud.px, g_mhud.pz + g_mhud.mapSpanM * 0.45f,
                                 g_mhud.px, g_mhud.pz, mx, my, ms,
                                 g_mhud.mapSpanM, rot);
            aowl_region_fill(np.x - 2.0f, np.y - 2.0f, 4.0f, 4.0f,
                             MHUD_RGBA(255, 210, 90, 230));
        }
    }

    /* ---- the RADAR frame ------------------------------------------------ */
    if (g_mhud.radarOn) {
        MmPt me;
        aowl_region_fill(g_mhud.radarX, g_mhud.radarY,
                         g_mhud.radarSize, g_mhud.radarSize,
                         MHUD_RGBA(10, 12, 16, 150));
        /* The SAME art on the compact radar, at radar scale. One code path, so
         * the two surfaces cannot disagree about which floor you are on. */
        g_art.tilesDrawn += mhud_art_draw_pane(
            g_mhud.radarX, g_mhud.radarY, g_mhud.radarSize,
            g_mhud.radiusM * 2.0f, rot, MHUD_RGBA(255, 255, 255, 200));
        aowl_region_box(g_mhud.radarX, g_mhud.radarY,
                        g_mhud.radarSize, g_mhud.radarSize, 1.0f,
                        MHUD_RGBA(120, 160, 200, 200));
        me = mm_topdown(g_mhud.px, g_mhud.pz, g_mhud.px, g_mhud.pz,
                        g_mhud.radarX, g_mhud.radarY, g_mhud.radarSize,
                        g_mhud.radiusM * 2.0f, rot);
        aowl_region_fill(me.x - 2.0f, me.y - 2.0f, 4.0f, 4.0f,
                         MHUD_RGBA(255, 255, 255, 255));
    }

    /* ---- every contact, on all three surfaces ---------------------------- *
     * Command budget: the map frame is at most 2 + 2*31 + 2 = 66, the radar
     * frame 3, and each entity contributes at most 1 (map) + 2 (radar) + 2
     * (indicator) = 5. With MHUD_MAX 128 that is 66 + 3 + 640 = 709 against
     * AOWL_REGION_MAX_CMDS (2048). It cannot overrun.
     */
    for (i = 0; i < g_mhud.n; i++) {
        float ex = g_mhud.e[i].x, ez = g_mhud.e[i].z;
        float dy = g_mhud.e[i].y - g_mhud.py;
        float d;
        uint32_t col;

        if (g_mhud.e[i].bot && !g_mhud.showBots) continue;
        if (!g_mhud.e[i].bot && !g_mhud.showPlayers) continue;

        col = g_mhud.e[i].bot ? MHUD_RGBA(230, 70, 60, 235)
                              : MHUD_RGBA(70, 190, 255, 235);
        d = mm_dist2d(ex, ez, g_mhud.px, g_mhud.pz);

        /* map pane: everything within the pane's span, culled by the RECT and
         * not by a radius, so the corners of the pane are not dead. */
        if (g_mhud.mapOn) {
            MmPt p = mm_topdown(ex, ez, g_mhud.px, g_mhud.pz,
                                g_mhud.mapX, g_mhud.mapY, g_mhud.mapSize,
                                g_mhud.mapSpanM, rot);
            if (mm_in_rect(p, g_mhud.mapX, g_mhud.mapY,
                           g_mhud.mapSize, g_mhud.mapSize))
                aowl_region_fill(p.x - 2.0f, p.y - 2.0f, 4.0f, 4.0f, col);
        }

        /* radar: a tighter radius, and the radius CULL stays a radius here
         * because a radar is a circle. */
        if (g_mhud.radarOn && d <= g_mhud.radiusM) {
            MmPt b = mm_topdown(ex, ez, g_mhud.px, g_mhud.pz,
                                g_mhud.radarX, g_mhud.radarY,
                                g_mhud.radarSize, g_mhud.radiusM * 2.0f, rot);
            aowl_region_fill(b.x - 2.0f, b.y - 2.0f, 4.0f, 4.0f, col);
            /* elevation: a 2px tick above or below the blip, only when the
             * difference is big enough to mean a different floor. */
            if (dy > 2.0f)
                aowl_region_fill(b.x - 1.0f, b.y - 5.0f, 2.0f, 2.0f, col);
            else if (dy < -2.0f)
                aowl_region_fill(b.x + -1.0f, b.y + 4.0f, 2.0f, 2.0f, col);
        }

        /* ---- the DIRECTIONAL indicator ---------------------------------- *
         * Preferred path: ask the region's projector where this world point
         * is on screen and clamp that to the screen edge. That answer is
         * camera-relative -- it points where the player is actually LOOKING,
         * which is the whole point of the feature.
         *
         * `aowl_region_project` returns 0 when no projector has been installed
         * (nothing in the host calls `aowl_region_set_projector` yet). That
         * zero is a REFUSAL and is treated as one: we fall back to the
         * north-up bearing ring and count the fallback separately, so the
         * status line can never present a north-up guess as a look-relative
         * answer. */
        if (g_mhud.indicatorsOn && d > 0.001f) {
            float sx = 0.0f, sy = 0.0f;
            MmPt m;
            int offscreen = 0;
            if (aowl_region_project(ex, g_mhud.e[i].y, ez, &sx, &sy)) {
                /* The projector reports nothing about the camera plane through
                 * this ABI, so `behind` cannot be known here and is passed as
                 * 0. mm_indicator handles a behind-camera point correctly when
                 * told; it is simply never told, which is a capability gap in
                 * the projector contract and is named as one rather than
                 * papered over with a sign heuristic. */
                if (mm_indicator(sx, sy, 0, scrW, scrH,
                                 g_mhud.indicatorInset, &m, &offscreen)) {
                    aowl_region_fill(m.x - 3.0f, m.y - 3.0f, 6.0f, 6.0f, col);
                    if (offscreen)
                        aowl_region_box(m.x - 5.0f, m.y - 5.0f, 10.0f, 10.0f,
                                        1.0f, col);
                    g_mhud.indProjected++;
                } else {
                    g_mhud.indRefused++;
                }
            } else if (mm_bearing_ring(ex, ez, g_mhud.px, g_mhud.pz, rot,
                                       scrW, scrH, 0.35f, &m)) {
                aowl_region_fill(m.x - 3.0f, m.y - 3.0f, 6.0f, 6.0f, col);
                g_mhud.indBearing++;
            } else {
                g_mhud.indRefused++;
            }
        }
    }
    g_mhud.blips += (int64_t)g_mhud.n;
}

/* ---- art accessors, for the diag ------------------------------------- *
 * These are what the ART line reports. They are DELIBERATELY separate numbers:
 * "a manifest loaded", "a map bound", "tiles resident", "tiles drawn" and "why
 * not" fail independently, and one combined "art: off" would make a missing
 * calibration read exactly like a missing tile file. */
static int32_t mhud_art_loaded(void)   { return g_art.loaded; }
static int32_t mhud_art_valid(void)    { return g_art.art.valid; }
static int32_t mhud_art_layers(void)   { return g_art.art.nLayers; }
static int32_t mhud_art_ntiles(void)   { return g_art.art.nTiles; }
static int32_t mhud_art_resident(void) {
    int32_t i, n = 0;
    for (i = 0; i < g_art.art.nTiles && i < MA_MAX_TILES; i++)
        if (g_art.haveBytes[i]) n++;
    return n;
}
static int32_t mhud_art_drawn(void)    { return g_art.tilesDrawn; }
static int32_t mhud_art_refusal(void)  { return g_art.refusal; }
static int32_t mhud_art_layer_idx(void)   { return g_art.layerIdx; }
static int32_t mhud_art_layer_level(void) { return g_art.layerLevel; }
static int32_t mhud_art_layer_why(void)   { return g_art.layerWhy; }
static int32_t mhud_art_tilepx(void)      { return g_art.tilePx; }
static int32_t mhud_art_rotation(void)    { return g_art.art.rotationDeg; }

static int32_t mhud_art_copy(const char* src, char* out, int32_t cap) {
    int32_t i = 0;
    if (!out || cap <= 0) return 0;
    if (!src) { out[0] = 0; return 0; }
    while (src[i] && i < cap - 1) { out[i] = src[i]; i++; }
    out[i] = 0;
    return i;
}
static int32_t mhud_art_refusal_text(char* out, int32_t cap) {
    return mhud_art_copy(ma_refusal_text(g_art.refusal), out, cap);
}
static int32_t mhud_art_why_text(char* out, int32_t cap) {
    return mhud_art_copy(ma_layer_why_text(g_art.layerWhy), out, cap);
}
static int32_t mhud_art_mapid(char* out, int32_t cap) {
    return mhud_art_copy(g_art.mapId, out, cap);
}

/* Slot -> the tile file's index within the binary manifest's tile table, so
 * the Nim loader can name the file to read without re-deriving the layout. */
static int32_t mhud_art_tile_bytes_len(void) { return (int32_t)g_art.tileBytes; }

/* ---- registration ---------------------------------------------------- */

static int32_t mhud_register(int32_t budgetUs, int32_t order) {
    AowlRegionDesc d;
    int32_t r;
    if (g_mhud.handle >= 0) return AOWL_REGION_OK;
    memset(&d, 0, sizeof(d));
    d.size = (int32_t)sizeof(d);
    strncpy(d.name, "maps.hud", AOWL_REGION_NAME_LEN - 1);
    d.fn       = mhud_draw;
    d.user     = 0;
    d.mask     = AOWL_REGION_DRAW;
    d.order    = order;
    d.budgetUs = budgetUs;
    r = aowl_region_register(&d);
    if (r >= 0) { g_mhud.handle = r; return AOWL_REGION_OK; }
    return r;
}

static int32_t mhud_unregister(void) {
    int32_t r;
    if (g_mhud.handle < 0) return AOWL_REGION_OK;
    r = aowl_region_unregister(g_mhud.handle);
    g_mhud.handle = -1;
    return r;
}

/* Copied into a caller-owned buffer rather than returned as a `const char*`:
 * nimony has no cstring -> string conversion, and inventing one here would be
 * a second answer to a question `sp/world.nim` already answers this way. */
static int32_t mhud_refusal(int32_t code, char* out, int32_t cap) {
    const char* t = aowl_region_refusal_text(code);
    int32_t i = 0;
    if (!out || cap <= 0) return 0;
    for (; t[i] && i < cap - 1; i++) out[i] = t[i];
    out[i] = 0;
    return i;
}
static int32_t mhud_armed(void)   { return aowl_region_is_armed(); }
static int64_t mhud_frames(void)  { return g_mhud.frames; }
static int64_t mhud_drawn(void)   { return g_mhud.drawn; }
static int64_t mhud_blips(void)   { return g_mhud.blips; }
static int32_t mhud_handle(void)  { return g_mhud.handle; }
static int64_t mhud_ind_projected(void) { return g_mhud.indProjected; }
static int64_t mhud_ind_bearing(void)   { return g_mhud.indBearing; }
static int64_t mhud_ind_refused(void)   { return g_mhud.indRefused; }
static int32_t mhud_screen_measured(void) { return g_mhud.screenFromRegion; }
static int32_t mhud_screen_w(void) { float w, h; mhud_screen(&w, &h);
                                     return (int32_t)w; }
static int32_t mhud_screen_h(void) { float w, h; mhud_screen(&w, &h);
                                     return (int32_t)h; }
""".}

proc cHudReset() {.importc: "mhud_reset", nodecl.}
proc cHudBegin(px, py, pz: cfloat; hasLocal: int32;
               heading: cfloat; hasHeading: int32) {.
  importc: "mhud_begin", nodecl.}
proc cHudAdd(x, y, z: cfloat; bot: int32) {.importc: "mhud_add", nodecl.}
proc cHudConfigure(radiusM, screenW, screenH: cfloat;
                   radarOn, indicatorsOn: int32;
                   radarSize, radarX, radarY: cfloat;
                   showBots, showPlayers: int32) {.
  importc: "mhud_configure", nodecl.}
proc cHudRegister(budgetUs, order: int32): int32 {.
  importc: "mhud_register", nodecl.}
proc cHudUnregister(): int32 {.importc: "mhud_unregister", nodecl.}
proc cHudRefusal(code: int32; outBuf: cstring; cap: int32): int32 {.
  importc: "mhud_refusal", nodecl.}
proc cHudArmed(): int32 {.importc: "mhud_armed", nodecl.}
proc cHudFrames(): int64 {.importc: "mhud_frames", nodecl.}
proc cHudDrawn(): int64 {.importc: "mhud_drawn", nodecl.}
proc cHudBlips(): int64 {.importc: "mhud_blips", nodecl.}
proc cHudHandle(): int32 {.importc: "mhud_handle", nodecl.}
proc cHudConfigureMap(mapOn: int32; mapX, mapY, mapSize, mapSpanM: cfloat;
                      mapGrid: int32; indicatorInset: cfloat) {.
  importc: "mhud_configure_map", nodecl.}
proc cHudIndProjected(): int64 {.importc: "mhud_ind_projected", nodecl.}
proc cHudIndBearing(): int64 {.importc: "mhud_ind_bearing", nodecl.}
proc cHudIndRefused(): int64 {.importc: "mhud_ind_refused", nodecl.}
proc cHudScreenMeasured(): int32 {.importc: "mhud_screen_measured", nodecl.}
proc cHudScreenW(): int32 {.importc: "mhud_screen_w", nodecl.}
proc cHudScreenH(): int32 {.importc: "mhud_screen_h", nodecl.}

# The counters, as ORDINARY Nim procs so another module can read them.
#
# The `importc ... nodecl` declarations above name `static` C functions that
# live in THIS file's {.emit.} block and are therefore invisible outside this
# translation unit -- exporting the Nim declaration exports a name that does
# not link (`implicit declaration of function 'mhud_frames'`). These wrappers
# are compiled here, where those statics are in scope, and are what maps.nim's
# diagnostic reads.
#
# They are the FINISHED-STATE evidence the diag asserts on: `frames` counts
# dispatches, `drawn` counts the dispatches that had a local player to centre
# on, and `blips` counts marks actually emitted. frames > 0 with drawn == 0 is
# precisely the silent failure this mod shipped with.
proc hudFrames*(): int64 = cHudFrames()
proc hudDrawn*(): int64 = cHudDrawn()
proc hudBlips*(): int64 = cHudBlips()
proc hudIndProjected*(): int64 = cHudIndProjected()
proc hudIndBearing*(): int64 = cHudIndBearing()
proc hudScreenMeasured*(): int32 = cHudScreenMeasured()
proc hudScreenW*(): int32 = cHudScreenW()
proc hudScreenH*(): int32 = cHudScreenH()

# ---------------------------------------------------------------- map ART

proc cArtBindAt(bin: cstring; n: uint32; wx, wz: cfloat): int32 {.
  importc: "mhud_art_bind_at", nodecl.}
proc cArtTileDds(idx: int32; data: cstring; n: uint32): int32 {.
  importc: "mhud_art_tile_dds", nodecl.}
proc cArtTileFile(idx: int32; outBuf: cstring; cap: int32): int32 {.
  importc: "mhud_art_tile_file", nodecl.}
proc cArtTileHave(idx: int32): int32 {.importc: "mhud_art_tile_have", nodecl.}
proc cArtTileLen(): int32 {.importc: "mhud_art_tile_bytes_len", nodecl.}
proc cArtUpload(): int32 {.importc: "mhud_art_upload", nodecl.}
proc cArtLoaded(): int32 {.importc: "mhud_art_loaded", nodecl.}
proc cArtValid(): int32 {.importc: "mhud_art_valid", nodecl.}
proc cArtLayers(): int32 {.importc: "mhud_art_layers", nodecl.}
proc cArtNTiles(): int32 {.importc: "mhud_art_ntiles", nodecl.}
proc cArtResident(): int32 {.importc: "mhud_art_resident", nodecl.}
proc cArtDrawn(): int32 {.importc: "mhud_art_drawn", nodecl.}
proc cArtRefusal(): int32 {.importc: "mhud_art_refusal", nodecl.}
proc cArtLayerLevel(): int32 {.importc: "mhud_art_layer_level", nodecl.}
proc cArtTilePx(): int32 {.importc: "mhud_art_tilepx", nodecl.}
proc cArtRotation(): int32 {.importc: "mhud_art_rotation", nodecl.}
proc cArtCandidates(): int32 {.importc: "mhud_art_candidates", nodecl.}
proc cArtRefusalText(outBuf: cstring; cap: int32): int32 {.
  importc: "mhud_art_refusal_text", nodecl.}
proc cArtWhyText(outBuf: cstring; cap: int32): int32 {.
  importc: "mhud_art_why_text", nodecl.}
proc cArtMapId(outBuf: cstring; cap: int32): int32 {.
  importc: "mhud_art_mapid", nodecl.}

proc artLoaded*(): bool = cArtLoaded() != 0'i32
proc artValid*(): bool = cArtValid() != 0'i32
proc artLayers*(): int = int(cArtLayers())
proc artTiles*(): int = int(cArtNTiles())
proc artResident*(): int = int(cArtResident())
proc artDrawn*(): int = int(cArtDrawn())
proc artLayerLevel*(): int = int(cArtLayerLevel())
proc artTilePx*(): int = int(cArtTilePx())
proc artRotation*(): int = int(cArtRotation())
proc artCandidates*(): int = int(cArtCandidates())

proc artRefusalText*(): string =
  ## The three string accessors are written out rather than routed through one
  ## higher-order helper: passing an `importc` proc as a VALUE does not type
  ## check on this toolchain (nimony emitted an incompatible-pointer-type C
  ## error), and three eight-line copies that compile beat one clever one that
  ## does not.
  var buf = ""
  while buf.len < 160: buf.add ' '
  let n = cArtRefusalText(toCString(buf), int32(buf.len))
  result = ""
  var i = 0
  while i < int(n) and i < buf.len:
    result.add buf[i]
    inc i

proc artLayerWhy*(): string =
  var buf = ""
  while buf.len < 160: buf.add ' '
  let n = cArtWhyText(toCString(buf), int32(buf.len))
  result = ""
  var i = 0
  while i < int(n) and i < buf.len:
    result.add buf[i]
    inc i

proc artMapId*(): string =
  var buf = ""
  while buf.len < 160: buf.add ' '
  let n = cArtMapId(toCString(buf), int32(buf.len))
  result = ""
  var i = 0
  while i < int(n) and i < buf.len:
    result.add buf[i]
    inc i

proc artBindAt*(binBytes: var string; wx, wz: float): int =
  ## UNITY THREAD. Choose the map whose calibration bounds contain (wx, wz) and
  ## bind its layers and tile rects. Re-binding the same map is a no-op, so the
  ## caller may do this every publish tick. Returns the tile count.
  ## `binBytes` is `var` ONLY because `toCString` requires it on this
  ## toolchain. Taking it by value would copy a 27 KB manifest on EVERY Unity
  ## frame -- a per-frame allocation, which is the one thing a region
  ## participant may never do. Nothing here mutates it.
  if binBytes.len < 32: return 0
  result = int(cArtBindAt(toCString(binBytes), uint32(binBytes.len),
                          cfloat(wx), cfloat(wz)))

proc artTileFile*(idx: int): string =
  ## The tile's path RELATIVE to data/maptiles, as recorded in the manifest.
  var buf = ""
  while buf.len < 128: buf.add ' '
  let n = cArtTileFile(int32(idx), toCString(buf), int32(buf.len))
  result = ""
  var i = 0
  while i < int(n) and i < buf.len:
    result.add buf[i]
    inc i

proc artTileHave*(idx: int): bool = cArtTileHave(int32(idx)) != 0'i32
proc artTileLen*(): int = int(cArtTileLen())

proc artGiveTileDds*(idx: int; ddsFile: var string): bool =
  ## Hand one tile's WHOLE .dds file in. The C side checks the 'DDS ' magic,
  ## skips the 128-byte header and refuses anything whose payload length is not
  ## exactly what the manifest declared -- so a truncated, half-written or
  ## wrong-resolution file is never uploaded as texels.
  if ddsFile.len <= 128: return false
  result = cArtTileDds(int32(idx), toCString(ddsFile),
                       uint32(ddsFile.len)) != 0'i32

proc artUpload*(): int =
  ## UNITY THREAD. Idempotent for resident keys; keeps the working set alive
  ## against the region's LRU. Returns the number of resident tiles.
  int(cArtUpload())


type
  HudOpts* = object
    radar*, indicators*: bool
    radiusM*: float
    screenW*, screenH*: float
    size*, x*, y*: float
    showBots*, showPlayers*: bool
    budgetUs*: int
    order*: int
    ## the MAP pane -- a separate, larger top-down surface from the radar
    map*: bool
    mapX*, mapY*, mapSize*, mapSpanM*: float
    mapGrid*: int
    indicatorInset*: float

proc hudInit*(o: HudOpts) =
  ## Resets the mirror and installs the layout. Safe to call before the region
  ## exists; it touches nothing but this file's own struct.
  cHudReset()
  cHudConfigure(cfloat(o.radiusM), cfloat(o.screenW), cfloat(o.screenH),
                (if o.radar: 1'i32 else: 0'i32),
                (if o.indicators: 1'i32 else: 0'i32),
                cfloat(o.size), cfloat(o.x), cfloat(o.y),
                (if o.showBots: 1'i32 else: 0'i32),
                (if o.showPlayers: 1'i32 else: 0'i32))
  cHudConfigureMap((if o.map: 1'i32 else: 0'i32),
                   cfloat(o.mapX), cfloat(o.mapY), cfloat(o.mapSize),
                   cfloat(o.mapSpanM), int32(o.mapGrid),
                   cfloat(o.indicatorInset))

proc hudArmed*(): bool =
  ## Whether the HOST has armed the shared region at all. This is the host flag
  ## `sharedRegion`, not anything this mod controls, and it is reported
  ## separately from registration for exactly that reason: registration always
  ## succeeds, and a registered participant on an unarmed region simply never
  ## fires. Those are two different states and a player is owed both.
  cHudArmed() != 0'i32

proc hudRegister*(o: HudOpts; why: var string): bool =
  ## Registers the draw participant. `why` carries the region's own refusal
  ## text on failure -- never a bare number.
  let r = cHudRegister(int32(o.budgetUs), int32(o.order))
  if r >= 0'i32:
    why = ""
    return true
  var buf = ""               # AOWL_REGION_REASON_LEN(192) + slack + NUL
  while buf.len < 208: buf.add ' '
  let n = cHudRefusal(r, toCString(buf), int32(buf.len))
  why = ""
  var i = 0
  while i < int(n) and i < buf.len:
    why.add buf[i]
    inc i
  if why.len == 0: why = "the shared region refused registration"
  result = false

proc hudUnregister*() =
  discard cHudUnregister()

proc hudPublish*(snap: Snapshot) =
  ## Unity's thread, right after `collect`. Copies the already-guarded POD
  ## positions into the C mirror. Reads no game memory of its own.
  if snap.localIdx < 0 or snap.localIdx >= snap.n:
    cHudBegin(0.0, 0.0, 0.0, 0'i32, 0.0, 0'i32)
    return
  let me = snap.ents[snap.localIdx]
  cHudBegin(cfloat(me.x), cfloat(me.y), cfloat(me.z), 1'i32,
            cfloat(snap.heading), (if snap.hasHeading: 1'i32 else: 0'i32))
  var i = 0
  while i < snap.n:
    if i != snap.localIdx:
      let e = snap.ents[i]
      cHudAdd(cfloat(e.x), cfloat(e.y), cfloat(e.z),
              (if e.bot: 1'i32 else: 0'i32))
    inc i

proc hudStatusText*(): string =
  ## Three numbers that can disagree, kept apart on purpose -- see the header.
  "region=" & (if hudArmed(): "armed" else: "NOT armed (host flag sharedRegion)") &
  " handle=" & $cHudHandle() &
  " frames=" & $cHudFrames() &
  " drawn=" & $cHudDrawn() &
  " blips=" & $cHudBlips() &
  " screen=" & $cHudScreenW() & "x" & $cHudScreenH() &
  (if cHudScreenMeasured() != 0'i32: " (measured back buffer)"
   else: " (CONFIG FALLBACK -- the region has not been told the real size)") &
  " indicators: projected=" & $cHudIndProjected() &
  " bearing=" & $cHudIndBearing() &
  " refused=" & $cHudIndRefused() &
  (if cHudIndProjected() == 0'i64 and cHudIndBearing() > 0'i64:
     " -- NO projector is installed, so every indicator drawn so far is a " &
     "NORTH-UP bearing, not a look-relative direction. The host does not call " &
     "aowl_region_set_projector yet"
   else: "")
