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
    if (g_mhud.mapOn) {
        float mx = g_mhud.mapX, my = g_mhud.mapY, ms = g_mhud.mapSize;
        aowl_region_fill(mx, my, ms, ms, MHUD_RGBA(8, 10, 14, 190));
        aowl_region_box(mx, my, ms, ms, 2.0f, MHUD_RGBA(150, 180, 210, 220));
        if (g_mhud.mapGrid > 0) {
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
