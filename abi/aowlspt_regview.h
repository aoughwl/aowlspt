/* aowlspt_regview.h -- A READ-ONLY VIEW OF THE SHARED REGION'S PARTICIPANT
 * TABLE, for the F3 profiler widget.
 *
 * INCLUDED FROM `region.nim` ONLY, and only AFTER that file's own
 * `#define AOWL_REGION_HOST` / `#include "aowlspt_region.h"`. It is therefore
 * looking at `g_region` itself -- the same table the dispatcher writes on every
 * frame -- through the header's own `aowl_region_status`.
 *
 * WHY THIS IS A SEPARATE FILE FROM `aowlspt_widget.h`
 * --------------------------------------------------
 * The whole host is ONE translation unit: `aowlhost.nim` `include`s
 * `debugui.nim`, `region.nim` and the rest, and they all become one C file, in
 * that order. `region.nim` is the single place that defines AOWL_REGION_HOST.
 * An earlier include of `aowlspt_region.h` from `debugui.nim`'s side -- in
 * CLIENT mode, since the define is not set there -- would set the include guard
 * first, and `region.nim`'s host-mode include would then expand to NOTHING:
 * the registry, the dispatcher and every `aowl_region_*` function would silently
 * disappear from the build. That is not hypothetical; it is what the first
 * attempt did, and it surfaced as nine `implicit declaration of aowl_region_*`
 * errors in code nobody had touched.
 *
 * So the ordering is load-bearing and is enforced, not merely documented: this
 * file REFUSES TO COMPILE unless AOWL_REGION_HOST is already defined.
 *
 * WHY THERE IS NO SECOND TIMER ANYWHERE
 * ------------------------------------
 * Everything the profiler widget shows is ALREADY being computed. The region
 * dispatcher times each participant's callback, compares it against the budget
 * that participant declared at registration, counts overruns, counts faults,
 * and counts the frames it skipped it for. Reading that costs nothing and adds
 * nothing to the frame; instrumenting it a second time would both double the
 * cost and measure a different thing. And a second DETOUR to collect it would
 * overwrite the first's trampoline, which is the standing rule here.
 *
 * WHAT CROSSES THE LINE is scalars and a `const char*` -- never the struct. The
 * widget side (`aowlspt_widget.h`) has matching `extern` declarations and no
 * knowledge of `AowlRegionStatus`'s layout at all.
 */
#ifndef AOWLSPT_REGVIEW_H
#define AOWLSPT_REGVIEW_H

#ifndef AOWL_REGION_HOST
#error "aowlspt_regview.h must be included from the ONE host-mode translation \
unit, after aowlspt_region.h -- see the header comment"
#endif

/* One scratch record, refilled per query. File-scope and fixed: nothing here
 * allocates, and the widget calls this on a throttled refresh, single-threaded
 * on the Unity thread, inside the guard the overlay body already holds. */
static AowlRegionStatus aowl_wg_rg;
static int32_t          aowl_wg_rg_valid = 0;
static char             aowl_wg_rg_name[AOWL_REGION_NAME_LEN + 1];
static char             aowl_wg_rg_reason[AOWL_REGION_REASON_LEN + 1];

/* Handles are plain slot indices into a FIXED array, so enumeration is bounded
 * by a compile-time constant. There is deliberately no "give me the count and
 * loop to it" path: a corrupted count is an unbounded loop inside a frame. */
int32_t aowl_wg_rg_max(void) { return AOWL_REGION_MAX; }

int32_t aowl_wg_rg_select(int32_t h) {
    int32_t rc;
    aowl_wg_rg_valid = 0;
    aowl_wg_rg_name[0] = 0;
    aowl_wg_rg_reason[0] = 0;
    if (h < 0 || h >= AOWL_REGION_MAX) return 0;
    memset(&aowl_wg_rg, 0, sizeof(aowl_wg_rg));
    aowl_wg_rg.size = (int32_t)sizeof(aowl_wg_rg);
    rc = aowl_region_status(h, &aowl_wg_rg);
    if (rc != AOWL_REGION_OK) return 0;
    if (!aowl_wg_rg.live) return 0;
    /* NUL-terminate defensively. `aowl_region_status` memcpy's the whole fixed
     * name array; a name that exactly filled it would leave no terminator, and
     * the Nim side reading it as a cstring would run off the end. */
    memcpy(aowl_wg_rg_name, aowl_wg_rg.name, AOWL_REGION_NAME_LEN);
    aowl_wg_rg_name[AOWL_REGION_NAME_LEN] = 0;
    memcpy(aowl_wg_rg_reason, aowl_wg_rg.reason, AOWL_REGION_REASON_LEN);
    aowl_wg_rg_reason[AOWL_REGION_REASON_LEN] = 0;
    aowl_wg_rg_valid = 1;
    return 1;
}

/* -1 means NOT MEASURED and the widget renders it as `--`. It must never be
 * rendered as 0, which reads as "this participant is free". */
const char* aowl_wg_rg_name_of(void)   { return aowl_wg_rg_name; }
const char* aowl_wg_rg_reason_of(void) { return aowl_wg_rg_reason; }
int64_t aowl_wg_rg_budget(void)  { return aowl_wg_rg_valid ? (int64_t)aowl_wg_rg.budgetUs : -1; }
int64_t aowl_wg_rg_last(void)    { return aowl_wg_rg_valid ? aowl_wg_rg.lastUs : -1; }
int64_t aowl_wg_rg_max_us(void)  { return aowl_wg_rg_valid ? aowl_wg_rg.maxUs : -1; }
int64_t aowl_wg_rg_calls(void)   { return aowl_wg_rg_valid ? aowl_wg_rg.calls : -1; }
int64_t aowl_wg_rg_skipped(void) { return aowl_wg_rg_valid ? aowl_wg_rg.skipped : -1; }
int32_t aowl_wg_rg_faults(void)    { return aowl_wg_rg_valid ? aowl_wg_rg.faults : 0; }
int32_t aowl_wg_rg_overruns(void)  { return aowl_wg_rg_valid ? aowl_wg_rg.overruns : 0; }
int32_t aowl_wg_rg_enabled(void)   { return aowl_wg_rg_valid ? aowl_wg_rg.enabled : 0; }
int32_t aowl_wg_rg_disabled(void)  { return aowl_wg_rg_valid ? aowl_wg_rg.disabled : 0; }
int32_t aowl_wg_rg_throttled(void) { return aowl_wg_rg_valid ? aowl_wg_rg.throttled : 0; }

/* Whether the region is dispatching at all. An empty participant table is
 * ambiguous between "nothing registered" and "the region is not armed"; this is
 * what lets the widget SAY WHICH instead of rendering nothing and letting the
 * reader conclude that nothing is costing anything. */
int32_t aowl_wg_rg_armed(void) { return aowl_region_is_armed(); }

/* ================================================================== *
 * THE SUBMITTER SIDE -- how the F3 widgets get DRAWN
 *
 * The F3 overlay used to clone TextMeshPro labels into the game's own canvas
 * tree. Six rounds of that ended with a walk that succeeded, faulted nowhere,
 * and rendered NOTHING, because the clones landed under a canvas whose
 * parenting and sort order belong to somebody else's UI. There is no check
 * available from inside the host that can tell "drawn" from "not drawn" there,
 * which by the rule in CLAUDE.md 9b makes the whole approach unverifiable.
 *
 * So F3 is now an ordinary REGION PARTICIPANT: it emits screen-space draw
 * commands and the D3D11 overlay rasterises them in `Present`, exactly as the
 * F12 panel and the F6 admin HUD already do. Nothing about it touches Unity's
 * canvas, so there is no parenting, no sort order and no clone to keep alive.
 *
 * These are thin, NON-STATIC wrappers for the same reason the read-only view
 * above is: `debugui.nim` is compiled into this one translation unit BEFORE
 * `region.nim`, so it cannot see a `static` defined here. It gets `extern`
 * declarations from `aowlspt_widget.h` and no knowledge of any struct.
 *
 * Every one of these is a no-op outside a DRAW callback -- `aowl_region_push`
 * refuses when `drawOpen` is 0 -- so a stray call can add a command to nobody
 * else's frame.
 * ================================================================== */

int32_t aowl_wg_dr_fill(float x, float y, float w, float h, uint32_t col) {
    return aowl_region_fill(x, y, w, h, col);
}
int32_t aowl_wg_dr_box(float x, float y, float w, float h, float t,
                       uint32_t col) {
    return aowl_region_box(x, y, w, h, t, col);
}
int32_t aowl_wg_dr_text(float x, float y, const char* s, uint32_t col,
                        int32_t scale) {
    return aowl_region_text_scaled(x, y, s, col, scale);
}

/* The back-buffer size the region publishes once a frame, measured from the
 * game window's own client rect. `known` is the third answer: 0 means NOBODY
 * HAS MEASURED IT YET, which must never be flattened into 0x0 -- snapping a
 * layout against a zero canvas drags every widget to the origin. */
int32_t aowl_wg_scr_w(void)     { return aowl_region_screen_w(); }
int32_t aowl_wg_scr_h(void)     { return aowl_region_screen_h(); }
int32_t aowl_wg_scr_known(void) { return aowl_region_screen_known(); }

/* Registration, by scalars only, so the widget side never sees AowlRegionDesc.
 * Returns the handle, or the region's own negative refusal code -- which the
 * caller must render through `aowl_region_refusal_text`, never as a number. */
int32_t aowl_wg_rg_register(const char* name, void (*fn)(void*, int64_t),
                            int32_t mask, int32_t order, int32_t budgetUs) {
    AowlRegionDesc d;
    int32_t i;
    memset(&d, 0, sizeof(d));
    d.size = (int32_t)sizeof(d);
    for (i = 0; i < AOWL_REGION_NAME_LEN - 1 && name && name[i]; i++)
        d.name[i] = name[i];
    d.mask     = mask;
    d.order    = order;
    d.budgetUs = budgetUs;
    d.fn       = fn;
    d.user     = 0;
    return aowl_region_register(&d);
}

const char* aowl_wg_rg_refusal_text(int32_t r) {
    return aowl_region_refusal_text(r);
}

int32_t aowl_wg_rg_mask_draw(void) { return AOWL_REGION_DRAW; }

#endif /* AOWLSPT_REGVIEW_H */
