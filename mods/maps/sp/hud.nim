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

    int64_t  frames, drawn, blips;
    int32_t  handle;
} g_mhud;

static void mhud_reset(void) {
    memset(&g_mhud, 0, sizeof(g_mhud));
    g_mhud.handle  = -1;
    g_mhud.radiusM = 120.0f;
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
    float cx, cy, half, scale, scx, scy, ring;
    int32_t i;
    (void)user; (void)frame;

    g_mhud.frames++;
    if (!g_mhud.hasLocal) return;   /* no centre => nothing truthful to draw */
    g_mhud.drawn++;

    half  = g_mhud.radarSize * 0.5f;
    cx    = g_mhud.radarX + half;
    cy    = g_mhud.radarY + half;
    scale = half / g_mhud.radiusM;
    scx   = g_mhud.screenW * 0.5f;
    scy   = g_mhud.screenH * 0.5f;
    ring  = (g_mhud.screenH < g_mhud.screenW ? g_mhud.screenH : g_mhud.screenW)
            * 0.35f;

    if (g_mhud.radarOn) {
        aowl_region_fill(g_mhud.radarX, g_mhud.radarY,
                         g_mhud.radarSize, g_mhud.radarSize,
                         MHUD_RGBA(10, 12, 16, 150));
        aowl_region_box(g_mhud.radarX, g_mhud.radarY,
                        g_mhud.radarSize, g_mhud.radarSize, 1.0f,
                        MHUD_RGBA(120, 160, 200, 200));
        /* the player, always dead centre */
        aowl_region_fill(cx - 2.0f, cy - 2.0f, 4.0f, 4.0f,
                         MHUD_RGBA(255, 255, 255, 255));
    }

    for (i = 0; i < g_mhud.n; i++) {
        float dx = g_mhud.e[i].x - g_mhud.px;
        float dz = g_mhud.e[i].z - g_mhud.pz;
        float dy = g_mhud.e[i].y - g_mhud.py;
        float rx, rz, d, blipX, blipY;
        uint32_t col;

        if (g_mhud.e[i].bot && !g_mhud.showBots) continue;
        if (!g_mhud.e[i].bot && !g_mhud.showPlayers) continue;

        /* North-up unless a heading was actually measured. `hasHeading` is
         * false today (sp/world.nim never reads one), so this rotates by
         * nothing rather than by a guessed zero that LOOKS like a heading. */
        if (g_mhud.hasHeading) {
            float s = (float)sin((double)g_mhud.heading);
            float c = (float)cos((double)g_mhud.heading);
            rx =  dx * c - dz * s;
            rz =  dx * s + dz * c;
        } else { rx = dx; rz = dz; }

        d = (float)sqrt((double)(rx * rx + rz * rz));
        if (d > g_mhud.radiusM) continue;

        col = g_mhud.e[i].bot ? MHUD_RGBA(230, 70, 60, 235)
                              : MHUD_RGBA(70, 190, 255, 235);

        if (g_mhud.radarOn) {
            blipX = cx + rx * scale;
            blipY = cy - rz * scale;          /* +Z is up on the radar */
            aowl_region_fill(blipX - 2.0f, blipY - 2.0f, 4.0f, 4.0f, col);
            /* elevation: a 2px tick above or below the blip, only when the
             * difference is big enough to mean a different floor. */
            if (dy > 2.0f)
                aowl_region_fill(blipX - 1.0f, blipY - 5.0f, 2.0f, 2.0f, col);
            else if (dy < -2.0f)
                aowl_region_fill(blipX - 1.0f, blipY + 4.0f, 2.0f, 2.0f, col);
        }

        if (g_mhud.indicatorsOn && d > 0.001f) {
            /* Same answer as the radar, reduced to a bearing: a mark on a ring
             * around screen centre. */
            float ux = rx / d, uz = rz / d;
            aowl_region_fill(scx + ux * ring - 3.0f, scy - uz * ring - 3.0f,
                             6.0f, 6.0f, col);
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

type
  HudOpts* = object
    radar*, indicators*: bool
    radiusM*: float
    screenW*, screenH*: float
    size*, x*, y*: float
    showBots*, showPlayers*: bool
    budgetUs*: int
    order*: int

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
  " blips=" & $cHudBlips()
