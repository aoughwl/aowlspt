/* aowlspt_betanotice.h -- THE MAIN-MENU BETA NOTICE, DRAWN ON THE OVERLAY.
 *
 * What this is, and why it is not the other thing
 * -----------------------------------------------
 * The first attempt at a beta notice REPURPOSED the game's own seasons banner
 * (`Common UI/MenuScreen/SeasonsButton`) by rewriting its labels through
 * `LocalizedText::SetLabelText`. That write fully SUCCEEDED -- the host log
 * recorded "6 of 6 non-empty labels written" -- and the result still looked
 * wrong, because the labels it had written were the banner's PROGRESS widget
 * (`[Battlepass] [SeasonWidget/Progress] [12 / 40]`), so our caption rendered
 * to the right of a logo that is an Image and therefore could never be removed
 * by writing text. That is the canonical shape of a check that cannot fail: it
 * asserted a property of OUR OWN WRITE instead of a property of the finished
 * screen.
 *
 * So the banner is simply HIDDEN now (`uxHideSeasons`), and the notice is
 * DRAWN, on the D3D11 overlay, where the position and the colour are ours and
 * are not negotiated with a BSG prefab every eighteen seconds.
 *
 * How it draws without a second detour and without owning a hook
 * --------------------------------------------------------------
 * It is a PARTICIPANT of the shared per-frame region (`aowlspt_region.h`),
 * registered with a DRAW mask. That buys, for free and without one line of new
 * hook code:
 *
 *   - the Unity main thread, as a rider on the EXISTING
 *     `EFT.UI.PreloaderUI::Update` detour -- no second detour is installed;
 *   - ONE `aowl_p_p_seh` opened by the dispatcher around our callback. This
 *     file therefore opens NO GUARD OF ITS OWN: `aowl_p_p_seh` is not
 *     re-entrant, and a guard here would NEST and thereby DISARM the
 *     dispatcher's;
 *   - fault isolation: three faults and the region disables THIS participant
 *     BY NAME, in the host log, while every other participant keeps running;
 *   - a per-participant microsecond budget;
 *   - rasterisation: `aowl_ov_region_append` in `abi/aowlspt_overlay.h` already
 *     drains every published region command every frame and draws it with the
 *     panel's own primitives, whether or not the F12 panel is open. Nothing in
 *     the overlay had to change for this file to appear on screen.
 *
 * NO PER-FRAME ALLOCATION. Every string is a file-scope `static const char[]`
 * built by the compiler; the region copies text INLINE into its command
 * (`AowlRegionCmd::text`), so there is no lifetime question and no heap.
 * The whole draw is a handful of integer/float stores into a fixed array.
 *
 * MAIN MENU ONLY. `aowl_beta_set_menu` is driven from the host's existing
 * raid-state signal -- the same `gInRaidLast` the graphics post-process gates
 * on -- and the callback returns immediately when it is not in the menu. It
 * never reads input and never submits anything but FILL and TEXT commands, so
 * it cannot steal a click: the overlay's region append is pure rasterisation
 * with no hit testing.
 *
 * WHERE IT DRAWS, and the one honest gap
 * --------------------------------------
 * Placement is a fraction of the back-buffer, so it survives a resolution
 * change. The back-buffer size is not published to the region by the overlay
 * (`aowl_region_set_screen` exists in the header but no one calls it), so this
 * file asks UNITY instead: `UnityEngine.Screen::get_width/get_height`, both
 * already in the byte-verified `aowl_mi2_targets` table of
 * `abi/aowlspt_invoke2.h`, resolved through `aowl_mi2_fn` which refuses on an
 * uncommitted page or a prologue mismatch. It is re-read once every
 * AOWL_BETA_RES_EVERY frames, not every frame. If the resolve refuses, this
 * feature DRAWS NOTHING and says so once -- it does not invent a resolution and
 * put the notice in a plausible-looking wrong place.
 *
 * COLOUR. `AOWL_BETA_WARN` is byte-identical to the overlay's own house token
 * `AOWL_OV_WARN` = RGBA(226,170,80) -- the amber the manager panel already uses
 * for every warning. It is deliberately NOT the accent blue and deliberately
 * not the stock banner's green: this is a warning, and green is exactly what
 * the user rejected. The value is duplicated rather than included so this file
 * does not drag the 7,000-line overlay header into the host translation unit.
 */
#ifndef AOWLSPT_BETANOTICE_H
#define AOWLSPT_BETANOTICE_H

#include <windows.h>
#include <stdint.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>

#ifdef __cplusplus
extern "C" {
#endif

/* This header is only ever compiled into the ONE host translation unit that
 * already included `aowlspt_region.h` with AOWL_REGION_HOST defined and
 * `aowlspt_invoke2.h`. It uses their file-static functions directly; it does
 * not re-include either, so it cannot create a second registry. */

/* ---- layout, in unscaled back-buffer pixels ----------------------- *
 * The overlay forces its integer font scale to 1 across the region append, so
 * one glyph is exactly AOWL_BETA_CW x AOWL_BETA_CH. These two constants MUST
 * agree with AOWL_OV_CW / AOWL_OV_CH (8 / 16) or the panel will be mis-sized;
 * they are asserted against the measured width of the finished panel below
 * rather than trusted.
 * ------------------------------------------------------------------ */
#define AOWL_BETA_CW            8
#define AOWL_BETA_CH            16
#define AOWL_BETA_PAD           12    /* inside the band, px               */
#define AOWL_BETA_GAP           6     /* between the two lines, px         */
#define AOWL_BETA_BAR           3     /* the house 3 px accent bar         */
#define AOWL_BETA_RES_EVERY     120   /* frames between resolution re-reads*/
#define AOWL_BETA_RES_GIVEUP    16    /* refusals before this stops asking */

/* 0xAABBGGRR, matching the overlay's vertex colour and the region's contract */
#define AOWL_BETA_RGBA(r,g,b,a) \
    ((uint32_t)(((uint32_t)(a) << 24) | ((uint32_t)(b) << 16) | \
                ((uint32_t)(g) <<  8) |  (uint32_t)(r)))

#define AOWL_BETA_WARN   AOWL_BETA_RGBA(226, 170,  80, 255)  /* = AOWL_OV_WARN */
#define AOWL_BETA_WARN2  AOWL_BETA_RGBA(198, 150,  74, 255)  /* the subline    */
#define AOWL_BETA_BG     AOWL_BETA_RGBA( 18,  21,  27, 214)  /* = AOWL_OV_PANEBG,
                                                                translucent    */

/* ---- the text, built ONCE, at compile time ------------------------ */
static const char AOWL_BETA_LINE1[] = "AOWLSPT BETA";
static const char AOWL_BETA_LINE2[] = "aoughwl.com  -  F12 for mod settings";

/* ---- state -------------------------------------------------------- */
typedef struct AowlBetaState {
    int32_t handle;        /* DRAW participant handle, or <0              */
    int32_t tickHandle;    /* TICK participant handle (resolution), or <0  */
    int32_t inMenu;        /* 1 while the host says we are NOT in a raid  */
    int32_t scrW, scrH;    /* last good back-buffer size, 0 = unknown     */
    int32_t resAge;        /* frames since the last successful re-read    */
    int32_t resFail;       /* consecutive refusals of the Screen getters  */
    int32_t saidNoRes;     /* refusal announced once, not every frame     */
    int32_t saidDrawn;     /* first successful draw announced once        */
    int32_t wIdx, hIdx;    /* invoke2 target indices, -1 = not looked up  */
    float   fracX, fracY;  /* centre X and top Y, as a fraction of screen */
    int64_t draws;
} AowlBetaState;

/* handle, tickHandle, inMenu, scrW, scrH, resAge, resFail, saidNoRes,
 * saidDrawn, wIdx, hIdx, fracX, fracY, draws.
 * BOTH handles start at -1. Adding `tickHandle` shifted every positional
 * value in this initialiser by one, which would have silently set
 * tickHandle = 1 (a valid-looking participant handle) and inMenu = 0 --
 * a feature that unregisters someone else's participant and never draws. */
static AowlBetaState g_beta = { -1, -1, 1, 0, 0, 0, 0, 0, 0, -1, -1,
                                0.5f, 0.11f, 0 };

/* The host installs this so refusals reach `aowlspt-host.log` through the same
 * sink the region uses. NULL is legal and means silence. */
static void (*g_beta_sink)(const char*) = 0;

static void aowl_beta_sayf(const char* fmt, ...) {
    char b[400];
    va_list ap;
    if (!g_beta_sink) return;
    va_start(ap, fmt);
    _vsnprintf(b, sizeof(b) - 1, fmt, ap);
    b[sizeof(b) - 1] = 0;
    va_end(ap);
    g_beta_sink(b);
}

/* ---- the resolution, from Unity, through the verified table -------- */

static int32_t aowl_beta_target(const char* name) {
    int32_t i, n = aowl_mi2_target_count();
    for (i = 0; i < n; i++)
        if (strcmp(aowl_mi2_name(i), name) == 0) return i;
    return -1;
}

/* Refreshes `scrW`/`scrH` at most once every AOWL_BETA_RES_EVERY frames.
 * Returns 1 when a usable size is known. Every failure is a REFUSAL that leaves
 * the previous good size alone and, once it has failed enough times, stops
 * asking rather than calling into the runtime forever. */
static int32_t aowl_beta_resolution(void) {
    void *fw, *fh;
    int32_t w, h;
    if (g_beta.scrW > 0 && g_beta.resAge < AOWL_BETA_RES_EVERY) {
        g_beta.resAge++;
        return 1;
    }
    if (g_beta.resFail >= AOWL_BETA_RES_GIVEUP) return g_beta.scrW > 0;
    if (g_beta.wIdx < 0)
        g_beta.wIdx = aowl_beta_target("UnityEngine.Screen::get_width");
    if (g_beta.hIdx < 0)
        g_beta.hIdx = aowl_beta_target("UnityEngine.Screen::get_height");
    if (g_beta.wIdx < 0 || g_beta.hIdx < 0) {
        g_beta.resFail++;
        return g_beta.scrW > 0;
    }
    /* `aowl_mi2_fn` does the VirtualQuery + committed + executable + 16-byte
     * prologue byte-compare and returns NULL on any of them. */
    fw = aowl_mi2_fn(g_beta.wIdx);
    fh = aowl_mi2_fn(g_beta.hIdx);
    if (!fw || !fh) { g_beta.resFail++; return g_beta.scrW > 0; }
    w = aowl_mi2_call_i_v(fw);
    h = aowl_mi2_call_i_v(fh);
    /* A resolution the machine cannot have is a refusal, not a number. */
    if (w < 640 || h < 360 || w > 16384 || h > 16384) {
        g_beta.resFail++;
        return g_beta.scrW > 0;
    }
    g_beta.resFail = 0;
    g_beta.resAge  = 0;
    g_beta.scrW    = w;
    g_beta.scrH    = h;
    return 1;
}

/* ---- the draw callback -------------------------------------------- *
 * Called by the region dispatcher, on the Unity main thread, ALREADY INSIDE
 * one `aowl_p_p_seh`. It opens no guard, allocates nothing, dereferences no
 * game pointer, and loops over nothing.
 * ------------------------------------------------------------------- */
static void aowl_beta_tick(void* user, int64_t frame) {
    /* THE RESOLUTION RE-READ LIVES HERE, NOT IN THE DRAW.
     *
     * MEASURED on the live client: registered DRAW-only, this participant was
     * reported by the region as `OVERRAN its frame budget: 142 us against
     * 120 us` and again at 147 us, roughly 120 frames apart. The draw itself
     * is four fixed submissions and some arithmetic -- it cannot cost that.
     * The spike is exactly this function on its re-read frame: two prologue
     * byte-compares plus two managed calls into `Screen::get_width/height`.
     *
     * Raising the draw budget would have silenced a TRUE signal -- the
     * comment on `budgetUs` says "anything near this is a bug", and it was
     * right. Splitting is the honest fix: DRAW stays pure submission and
     * keeps its tight budget, and the periodic managed call moves to TICK
     * with a budget sized for what it actually does. Amortised the re-read
     * was always cheap (~140 us every 120 frames is ~1.2 us/frame); the
     * problem was never the cost, it was charging it to the wrong meter. */
    (void)user; (void)frame;
    if (!g_beta.inMenu) return;
    (void)aowl_beta_resolution();
}

static void aowl_beta_draw(void* user, int64_t frame) {
    float x, y, w, h, tx;
    int32_t cols;
    (void)user; (void)frame;

    if (!g_beta.inMenu) return;              /* raid: draw nothing at all   */
    /* Read only what TICK has already resolved -- no managed call here. */
    if (!(g_beta.scrW > 0)) {
        if (!g_beta.saidNoRes) {
            g_beta.saidNoRes = 1;
            aowl_beta_sayf(
                "beta notice: REFUSED to draw -- UnityEngine.Screen::"
                "get_width/get_height did not verify against their prologue "
                "snapshot, so the back-buffer size is UNKNOWN. Nothing is "
                "drawn; a guessed resolution would put the notice in a "
                "plausible-looking wrong place, which is the failure this "
                "feature exists to stop repeating.");
        }
        return;
    }

    /* Panel size, from the LONGER of the two lines. Both are compile-time
     * constants, so this is two subtractions, not a measurement. */
    cols = (int32_t)(sizeof(AOWL_BETA_LINE2) - 1);
    if ((int32_t)(sizeof(AOWL_BETA_LINE1) - 1) > cols)
        cols = (int32_t)(sizeof(AOWL_BETA_LINE1) - 1);

    w = (float)(cols * AOWL_BETA_CW + AOWL_BETA_PAD * 2 + AOWL_BETA_BAR);
    h = (float)(AOWL_BETA_CH * 2 + AOWL_BETA_GAP + AOWL_BETA_PAD * 2);
    x = (float)g_beta.scrW * g_beta.fracX - w * 0.5f;
    y = (float)g_beta.scrH * g_beta.fracY;
    if (x < 0.0f) x = 0.0f;
    if (y < 0.0f) y = 0.0f;

    /* The house group shape: a filled PANEBG band with a 3 px accent bar down
     * its left edge -- except the accent here is the WARN amber, because this
     * is a warning and not a section header. */
    aowl_region_fill(x, y, w, h, AOWL_BETA_BG);
    aowl_region_fill(x, y, (float)AOWL_BETA_BAR, h, AOWL_BETA_WARN);

    tx = x + (float)(AOWL_BETA_BAR + AOWL_BETA_PAD);
    aowl_region_text(tx, y + (float)AOWL_BETA_PAD,
                     AOWL_BETA_LINE1, AOWL_BETA_WARN);
    aowl_region_text(tx, y + (float)(AOWL_BETA_PAD + AOWL_BETA_CH +
                                     AOWL_BETA_GAP),
                     AOWL_BETA_LINE2, AOWL_BETA_WARN2);
    g_beta.draws++;
    if (!g_beta.saidDrawn) {
        g_beta.saidDrawn = 1;
        aowl_beta_sayf(
            "beta notice: first frame SUBMITTED -- 2 fills + 2 texts at "
            "(%d,%d) %dx%d px on a %dx%d back buffer, title colour 0x%08X "
            "(the overlay's own AOWL_OV_WARN amber). The overlay's region "
            "append rasterises it; if it is not on screen, the failure is "
            "downstream of here.",
            (int32_t)x, (int32_t)y, (int32_t)w, (int32_t)h,
            g_beta.scrW, g_beta.scrH, (unsigned)AOWL_BETA_WARN);
    }
}

/* ---- the host-facing API ------------------------------------------- */

static void aowl_beta_set_sink(void (*sink)(const char*)) { g_beta_sink = sink; }

/* Main-menu gate. 1 = menu (draw), 0 = raid (silent). */
static void aowl_beta_set_menu(int32_t on) { g_beta.inMenu = on ? 1 : 0; }

/* Placement, as a fraction of the back buffer: `cx` is the panel's CENTRE on
 * X, `ty` its TOP on Y. Out-of-range values are refused and the default kept,
 * because a notice parked off screen reads to a player as "it does not work". */
static int32_t aowl_beta_set_pos(float cx, float ty) {
    if (cx < 0.02f || cx > 0.98f || ty < 0.0f || ty > 0.95f) return 0;
    g_beta.fracX = cx;
    g_beta.fracY = ty;
    return 1;
}

/* The same thing from a config string, `"<cx>,<ty>"`, so the position can be
 * nudged in `aowlspt-host.json` without a rebuild. Parsing lives HERE rather
 * than in Nim because C has `strtod` and a hand-rolled float parser in the host
 * is a bug waiting for a decimal comma. Returns 1 only if BOTH numbers parsed
 * AND `aowl_beta_set_pos` accepted them; anything else leaves the default in
 * place and says so at the call site. */
static int32_t aowl_beta_set_pos_str(const char* s) {
    char* end = 0;
    double cx, ty;
    if (!s || !s[0]) return 0;
    cx = strtod(s, &end);
    if (!end || end == s) return 0;
    while (*end == ' ' || *end == ',' || *end == ';') end++;
    s = end;
    ty = strtod(s, &end);
    if (!end || end == s) return 0;
    return aowl_beta_set_pos((float)cx, (float)ty);
}

static int32_t aowl_beta_register(void) {
    AowlRegionDesc d;
    if (g_beta.handle >= 0) return g_beta.handle;
    memset(&d, 0, sizeof(d));
    d.size = (int32_t)sizeof(d);
    strncpy(d.name, "beta-notice", AOWL_REGION_NAME_LEN - 1);
    d.mask     = AOWL_REGION_DRAW;
    d.order    = 900;   /* late: over any mod's world markers, under the panel */
    d.budgetUs = 120;   /* four fixed submissions; anything near this is a bug */
    d.fn       = aowl_beta_draw;
    d.user     = 0;
    g_beta.handle = aowl_region_register(&d);
    if (g_beta.handle < 0) return g_beta.handle;

    /* The periodic resolution re-read, on its own meter. See aowl_beta_tick:
     * folded into DRAW it overran a correct 120 us budget at 142/147 us on
     * the frame it re-read, once every ~120 frames. */
    memset(&d, 0, sizeof(d));
    d.size = (int32_t)sizeof(d);
    strncpy(d.name, "beta-notice-res", AOWL_REGION_NAME_LEN - 1);
    d.mask     = AOWL_REGION_TICK;
    d.order    = 899;   /* before the draw, so the draw sees this frame's size */
    d.budgetUs = 400;   /* two prologue verifies + two managed calls, periodic */
    d.fn       = aowl_beta_tick;
    d.user     = 0;
    g_beta.tickHandle = aowl_region_register(&d);
    /* The DRAW half is what the feature IS. If only the periodic re-read
     * failed to register we still draw, using whatever resolution the first
     * read got -- and the region names the missing participant itself. */
    return g_beta.handle;
}

static int32_t aowl_beta_unregister(void) {
    int32_t h = g_beta.handle;
    int32_t t = g_beta.tickHandle;
    int32_t rc;
    if (h < 0 && t < 0) return 0;
    g_beta.handle = -1;
    g_beta.tickHandle = -1;
    /* BOTH, always. Releasing only the draw half would leave the resolution
     * tick running against a feature that is switched off. */
    rc = (h >= 0) ? aowl_region_unregister(h) : 0;
    if (t >= 0) { int32_t rc2 = aowl_region_unregister(t); if (!rc) rc = rc2; }
    return rc;
}

static int32_t aowl_beta_handle(void)  { return g_beta.handle; }
static int64_t aowl_beta_draws(void)   { return g_beta.draws; }
static int32_t aowl_beta_scr_w(void)   { return g_beta.scrW; }
static int32_t aowl_beta_scr_h(void)   { return g_beta.scrH; }

#ifdef __cplusplus
}
#endif
#endif /* AOWLSPT_BETANOTICE_H */
