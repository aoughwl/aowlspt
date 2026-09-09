/* aowlspt_natesp.h -- the NATIVE uGUI ESP's pure-C half.
 *
 * WHAT THIS IS. `natesp.nim` draws contact boxes as REAL Tarkov uGUI
 * GameObjects (nativeui's `nu*` primitives), parented to a canvas DISCOVERED at
 * runtime. This header holds only what must be C: the single SEH guard shim,
 * the fixed caps, the fault budget, and the verdict/refusal vocabulary. There
 * is no il2cpp here and nothing in this file can fault.
 *
 * THE ONE GUARD. `aowl_ne_tick_guarded` wraps the WHOLE tick body in ONE
 * `aowl_p_p_seh`. `aowl_p_p_seh` is NOT re-entrant -- a nested inner guard
 * disarms the outer one -- so the Nim body opens none of its own, exactly as
 * natraid.nim does.
 *
 * ALLOCATION PROFILE, stated up front because it is a hard rule. The pool is
 * built ONCE: `AOWL_NE_POOL` GameObjects, each with a RectTransform and one
 * Graphic. After that the per-frame work is `_Injected` layout setters plus
 * `GameObject::SetActive` -- no `object_new`, no `il2cpp_string_new`, no
 * managed allocation of any kind in the update path.
 *
 * WHY THE VERDICT VOCABULARY LIVES HERE. CLAUDE.md 9b: a check that cannot
 * fail IS the bug, and there are THREE outcomes, never two. The three literals
 * below are the only three things the diag may ever say, they are mutually
 * exclusive, and PASS is the one that is hardest to reach on purpose -- it
 * requires a READBACK of the finished state, not a record of our own writes.
 */
#ifndef AOWLSPT_NATESP_H
#define AOWLSPT_NATESP_H

#include <stdint.h>

/* ---- caps. Every one of these bounds an iteration; none is a guess. ---- */

/* Boxes in the pool.
 *
 * MEASURED 2026-08-31, live raid, natesp verdict line: "21 placed, 45
 * contact(s), 24 over the per-faction pool". The pool was FOUR SUB-POOLS OF
 * EIGHT and a contact could only ever be drawn by a box of its own faction, so
 * a raid of 32 scavs drew 8 scavs and left 24 undrawn while 24 USEC/BEAR/boss
 * boxes sat idle. That is a partition, not a capacity limit, and it is the
 * worse of the two failures: the pool was 32 and only 21 of it was reachable.
 *
 * THE POOL IS NOW FLAT. Any box can draw any contact, because colour is set on
 * the box per placement (`Graphic::set_color`, byte-verified, called only when
 * the box's (class, fade band) actually CHANGES -- see g_ne_recolours) instead
 * of being baked in at build time. 64 boxes is above the 45 contacts measured
 * and above NeMaxContacts is NOT required: the overflow policy is NEAREST-N and
 * it is explicit, counted, and printed. See aowl_ne_drop_policy(). */
#define AOWL_NE_FACTIONS      4
#define AOWL_NE_POOL          64

/* Discovery walk. Breadth-first over the scene roots, sliced across frames so
 * one frame can never spend the whole budget. Both bound the SAME walk: the
 * node budget bounds it in total, the millisecond slice bounds it per frame. */
/* MEASURED 2026-08-31, live raid: with 20000 the walk reported
 * `visited=20000 budgetLeft=0 queued=32879 deepest=3/8 scope=TRUNCATED` -- it
 * burned the whole budget on map geometry three levels down and never reached
 * any UI. It CANNOT establish nested absence at any sane budget, so it is no
 * longer asked to: the creation gate now rests on phase 0's EXHAUSTIVE root
 * ask alone, and this walk is a PREFERENCE (adopt a nested canvas if one turns
 * up early) rather than a gate. A preference gets a small budget. */
#define AOWL_NE_MAX_NODES     3000
#define AOWL_NE_MAX_CHILDREN  512
#define AOWL_NE_SLICE_MS      6

/* DEPTH cap. A raid scene is orders of magnitude larger than a menu -- Woods
 * alone reports 62 geometry chunks -- and an undepth-capped breadth-first walk
 * spends its whole node budget on terrain before it ever reaches a UI root. A
 * Canvas is the ROOT of a uGUI tree: it sits within a few levels of a scene
 * root, never buried under terrain. Capping depth is therefore not a heuristic
 * shortcut, it is the actual shape of the thing being looked for -- and it is
 * what keeps the walk exhaustive WITHIN its cap instead of truncated at random.
 * Nested canvases deeper than this are deliberately out of scope; the refusal
 * line says so rather than implying the search was complete. */
#define AOWL_NE_MAX_DEPTH     8

/* A canvas smaller than this in either axis is not a HUD canvas; refusing it is
 * cheaper than parenting to a 0x0 rect and reporting success forever. */
#define AOWL_NE_MIN_CANVAS_PX 200.0f

/* ---- CREATING OUR OWN CANVAS (the third outcome) ------------------------
 *
 * Sort order. An overlay canvas is composited by `sortingOrder`, so one at or
 * below the game's HUD is drawn UNDER it and is invisible while every call in
 * the creation sequence reports success -- this project's signature failure.
 * 32000 is just below Unity's int16 sorting ceiling (32767), chosen to be
 * unambiguously above anything the game itself uses without sitting exactly at
 * the boundary. */
#define AOWL_NE_CANVAS_SORT_ORDER 32000

/* HOW LONG TO WAIT FOR THE CANVAS TO SETTLE, IN TICKS.
 *
 * A freshly created ScreenSpaceOverlay canvas does not have its screen-sized
 * rect until Unity's canvas update has run; reading `get_rect_Injected` in the
 * SAME frame can legitimately return 0x0. Refusing on that first read would
 * throw away a perfectly good canvas, and ACCEPTING without reading at all is
 * the "check that cannot fail" this project keeps producing.
 *
 * So the readback is RETRIED, and the timeout is a REFUSAL, never a pass. The
 * three outcomes stay three: sane readback -> CREATED, cap reached with no sane
 * readback -> REFUSED(canvas-unverified) and the object is DESTROYED, a fault
 * -> the discovery fault ledger. ~2 seconds at 60fps. */
#define AOWL_NE_CANVAS_SETTLE_TICKS 120

/* Unity's built-in `UI` layer. A UI object on another layer can be culled and
 * render nothing while every call succeeds. */
#define AOWL_NE_UI_LAYER 5

/* Rescan the world every N ticks. The world scan is the only part of the tick
 * that walks a game collection, so this is the throttle that keeps the steady
 * state cheap. Box rects are still updated EVERY tick from the last scan. */
#define AOWL_NE_SCAN_EVERY    5

/* THE READBACK VERDICT IS THROTTLED, NOT REMOVED. It asks the GAME, per box,
 * for activeInHierarchy + anchoredPosition + sizeDelta -- three il2cpp calls
 * for each of up to AOWL_NE_POOL boxes, i.e. the single most expensive thing
 * a steady-state tick does, and it was measured at 6.8ms of a 14.5ms tick.
 *
 * Deleting it was never an option: it is the only check in this feature that
 * cannot be satisfied by our own bookkeeping, and a self-comparison in its
 * place would be a check that cannot fail (CLAUDE.md 9b). But it answers a
 * question about a STATE, not about an EVENT, and the state is only ever
 * REPORTED once every 5 seconds by the diag emit. Running it 300 times per
 * report bought nothing. It now runs every N ticks; `gNeVerdict` holds the
 * last real answer in between, and the diag line states the age of it so a
 * stale PASS can never be read as a fresh one. */
#define AOWL_NE_VERDICT_EVERY 30

/* Self-disable after this many faults inside the guarded body. */
#define AOWL_NE_MAX_FAULTS    6

/* Discovery gets its OWN, separate fault ledger.
 *
 * MEASURED (integ-beta6, loaded Woods raid, host log): six consecutive guarded
 * ticks faulted during state=1 and the feature self-disabled for the session
 * before discovery had finished even one pass. The cause was Unity FAKE NULLS
 * -- destroyed UnityEngine.Object wrappers that stay perfectly READABLE with
 * m_CachedPtr zeroed -- reached through the nu* icall wrappers, which checked
 * readability but never liveness. Those nodes are now liveness-checked and
 * SKIPPED as a normal outcome, so they are not faults at all.
 *
 * Anything that still faults during the walk is genuinely unexpected, and it
 * charges this ledger rather than the steady-state one: a per-frame walk that
 * touches thousands of foreign objects must not be able to burn down the
 * running feature's budget. It still self-disables -- rule 6 is not weakened,
 * only given its own, honestly-named counter. */
#define AOWL_NE_MAX_DISC_FAULTS 24

/* SEED ATTEMPTS. `Scene::GetRootGameObjects` ALLOCATES (a List and an array),
 * and a seed that faults leaves `gNeSeeded` false, so it re-runs on the NEXT
 * frame -- MEASURED: 24 allocating enumerations of 178 roots each before the
 * discovery ledger finally capped out. Even with the per-root fault now
 * isolated and skipped, the seed must be bounded by attempts as well as by
 * faults, so that "the seed cannot succeed" can never become a per-frame
 * allocating path. */
#define AOWL_NE_MAX_SEED_TRIES 8

/* Roots whose conversion faulted and are therefore skipped on the retry. A
 * fixed cap because it is an iteration bound like every other one here; a raid
 * that faults on more roots than this is not a raid we can seed from. */
#define AOWL_NE_MAX_SEED_SKIPS 64

/* ---- the faction sub-pools -------------------------------------------- */
/* EPlayerSide is 1=Usec, 2=Bear, 4=Savage -- NOT 3. Savage is split by
 * WildSpawnType into plain scav and everything scarier. */
#define AOWL_NE_F_USEC   0
#define AOWL_NE_F_BEAR   1
#define AOWL_NE_F_SCAV   2
#define AOWL_NE_F_BOSS   3

static const char *aowl_ne_faction_name(int32_t f) {
    switch (f) {
    case AOWL_NE_F_USEC: return "USEC";
    case AOWL_NE_F_BEAR: return "BEAR";
    case AOWL_NE_F_SCAV: return "scav";
    case AOWL_NE_F_BOSS: return "boss";
    default:             return "?";
    }
}

/* Graphic.m_Color is a UnityEngine.Color -- four floats, 0..1, NOT bytes.
 *
 * The table is now MUTABLE, because the four colours are user settings
 * (`colorSetting(format="hex")`). It is written ONCE, at host config load, from
 * `aowl_ne_set_faction_rgba`; nothing writes it per frame. `aowl_ne_col_source`
 * reports where each row came from so the log can never claim a setting took
 * effect when the parse actually refused and the default was kept. */
static float g_ne_col[AOWL_NE_FACTIONS][4] = {
    { 0.30f, 0.65f, 1.00f, 0.85f },   /* USEC -- blue    */
    { 1.00f, 0.45f, 0.25f, 0.85f },   /* BEAR -- orange  */
    { 0.85f, 0.85f, 0.85f, 0.75f },   /* scav -- grey    */
    { 1.00f, 0.20f, 0.85f, 0.90f },   /* boss -- magenta */
};
static int32_t g_ne_col_src[AOWL_NE_FACTIONS] = { 0, 0, 0, 0 };

static float aowl_ne_faction_rgba(int32_t f, int32_t chan) {
    if (f < 0 || f >= AOWL_NE_FACTIONS) return 0.0f;
    if (chan < 0 || chan > 3) return 0.0f;
    return g_ne_col[f][chan];
}

/* Clamped, NaN-rejecting. A colour channel that is not finite would reach
 * `Graphic::set_color` and produce an invisible box while every call reported
 * success -- this project's signature failure. Returns 0 (refused, table
 * untouched) or 1 (stored). */
static int32_t aowl_ne_set_faction_rgba(int32_t f, float r, float g, float b,
                                        float a) {
    int i;
    float v[4];
    if (f < 0 || f >= AOWL_NE_FACTIONS) return 0;
    v[0] = r; v[1] = g; v[2] = b; v[3] = a;
    for (i = 0; i < 4; i++)
        if (!(v[i] >= 0.0f) || !(v[i] <= 1.0f)) return 0;   /* NaN-safe */
    for (i = 0; i < 4; i++) g_ne_col[f][i] = v[i];
    g_ne_col_src[f] = 1;
    return 1;
}

static int32_t aowl_ne_col_source(int32_t f) {
    if (f < 0 || f >= AOWL_NE_FACTIONS) return 0;
    return g_ne_col_src[f];   /* 0 = compiled default, 1 = from settings */
}

/* ---- DISTANCE FADE AND SCALE -------------------------------------------
 *
 * NO SECOND TIMER. There is a contact-fade in mods/maps that ages tracks
 * against OBSERVED time; it is a different binary, a different data set, and a
 * staleness question. This is not staleness. natesp re-reads the live world
 * every AOWL_NE_SCAN_EVERY ticks and every contact it draws was observed on the
 * most recent pass, so nothing here can be stale and nothing here needs a
 * clock. Both functions below are pure functions of the projected DEPTH, which
 * `Camera::WorldToScreenPoint` already produced for the placement -- so the fade
 * costs one multiply and reads no new state.
 *
 * Fade: full alpha to AOWL_NE_FADE_NEAR m, then linear down to
 * AOWL_NE_FADE_FLOOR at AOWL_NE_FADE_FAR m and no further. It never reaches
 * zero, because a box that fades to invisible while `neVerdict` still counts it
 * as on-screen would make PASS mean less than it says. */
#define AOWL_NE_FADE_NEAR   30.0f
#define AOWL_NE_FADE_FAR   250.0f
#define AOWL_NE_FADE_FLOOR   0.30f

static float aowl_ne_fade_alpha(float depth) {
    float t;
    if (!(depth > 0.0f)) return 1.0f;                       /* NaN-safe */
    if (depth <= AOWL_NE_FADE_NEAR) return 1.0f;
    if (depth >= AOWL_NE_FADE_FAR)  return AOWL_NE_FADE_FLOOR;
    t = (depth - AOWL_NE_FADE_NEAR) / (AOWL_NE_FADE_FAR - AOWL_NE_FADE_NEAR);
    return 1.0f - t * (1.0f - AOWL_NE_FADE_FLOOR);
}

/* The recolour QUANTISER. Calling `Graphic::set_color` every frame for every
 * box is 64 managed calls a frame for a value that barely moves. The alpha is
 * therefore banded, and a box is recoloured only when its (class, band) pair
 * changes. 8 bands over the fade range is one recolour per ~27 m of travel. */
#define AOWL_NE_FADE_BANDS 8
static int32_t aowl_ne_fade_band(float depth) {
    float a = aowl_ne_fade_alpha(depth);
    int32_t b = (int32_t)(a * (float)(AOWL_NE_FADE_BANDS - 1) + 0.5f);
    if (b < 0) b = 0;
    if (b >= AOWL_NE_FADE_BANDS) b = AOWL_NE_FADE_BANDS - 1;
    return b;
}

static float aowl_ne_band_alpha(int32_t band) {
    if (band < 0) band = 0;
    if (band >= AOWL_NE_FADE_BANDS) band = AOWL_NE_FADE_BANDS - 1;
    return (float)band / (float)(AOWL_NE_FADE_BANDS - 1);
}

/* ---- THE OVERFLOW POLICY, NAMED --------------------------------------- */
/* The old policy was "the first 8 contacts of each faction, and the rest are
 * silently absent". This one is NEAREST-N over the whole flat pool, and the
 * count that did not fit is reported every verdict. */
static const char *aowl_ne_drop_policy(void) {
    return "NEAREST-" "64" " by camera depth over a FLAT pool (any box may draw "
           "any class; colour is set per placement). Contacts beyond the pool "
           "are the FARTHEST ones and are counted in `dropped`, never dropped "
           "silently";
}

/* ---- the three outcomes ----------------------------------------------- */
/*
 * (a) PASS         -- a canvas was found AND at least one box is active AND its
 *                     rect READS BACK renderable and on-screen this frame.
 * (b) FAIL         -- a canvas was found and the pool is built, contacts exist,
 *                     and ZERO boxes came back active-with-a-valid-rect. This
 *                     is the real failure and it is the one an "the callback
 *                     ran" style diag reports as success.
 * (c) INCONCLUSIVE -- no canvas, no pool, or not in a raid. "I could not look"
 *                     is NOT a pass.
 */
#define AOWL_NE_V_INCONCLUSIVE 0
#define AOWL_NE_V_FAIL         1
#define AOWL_NE_V_PASS         2

/* ---- refusal reasons. Every failure path announces itself. ------------- */
#define AOWL_NE_R_NONE           0
#define AOWL_NE_R_OFF            1
#define AOWL_NE_R_NO_NATIVEUI    2
#define AOWL_NE_R_NO_GETCOMP     3
#define AOWL_NE_R_NO_GAMEWORLD   4
#define AOWL_NE_R_NO_CAMERA      5
#define AOWL_NE_R_NO_SCREEN      6
#define AOWL_NE_R_NO_ROOTS       7
#define AOWL_NE_R_NO_CANVAS      8
#define AOWL_NE_R_NO_GRAPHIC     9
#define AOWL_NE_R_BUILD_FAILED  10
#define AOWL_NE_R_FAULTED       11
#define AOWL_NE_R_NO_STRING     12
#define AOWL_NE_R_DISC_FAULTED  13
#define AOWL_NE_R_SEED_TRIES    14
/* ---- the CREATED path's own refusals. Three, told apart on purpose: we
 * never had a class donor / a step of the sequence refused / it was built and
 * never read back sane. Collapsing them would make the log say the same thing
 * for three different bugs. */
#define AOWL_NE_R_CANVAS_DONOR  15
#define AOWL_NE_R_CANVAS_CREATE 16
#define AOWL_NE_R_CANVAS_UNVERIFIED 17

static const char *aowl_ne_refusal_text(int32_t r) {
    switch (r) {
    case AOWL_NE_R_NONE:         return "no refusal";
    case AOWL_NE_R_OFF:          return "the natEsp flag is off (default)";
    case AOWL_NE_R_NO_NATIVEUI:  return "the nativeui layer is off or self-disabled; the nu* primitives are the only way this draws anything";
    /* The nav table row is UnityEngine.Component::GetComponent(String) @
     * 0x52A48E0 with a 16-byte prologue snapshot; iNavFind byte-verifies it
     * against that snapshot and rejects the C2 00 00 universal empty-body
     * stub. This refusal means the verify FAILED -- module not loaded, bytes
     * differ, or another feature patched it first (a hook-order problem, not a
     * bad RVA). Discovery stops rather than guessing an address. */
    case AOWL_NE_R_NO_GETCOMP:   return "Component::GetComponent(String) did not byte-verify against the startup prologue snapshot; discovery needs it and will NOT guess an RVA";
    case AOWL_NE_R_NO_GAMEWORLD: return "no live GameWorld -- not in a raid (and GameWorld existing is not deployment either)";
    case AOWL_NE_R_NO_CAMERA:    return "Camera.main is null -- menu or loading screen, so nothing can be projected";
    case AOWL_NE_R_NO_SCREEN:    return "the back-buffer size is not measured yet; projecting against a zero screen puts every box at the origin";
    case AOWL_NE_R_NO_ROOTS:     return "the scene-root enumeration returned nothing to walk";
    case AOWL_NE_R_NO_CANVAS:    return "the walk finished and found NO active Canvas with a renderable rect; refusing to parent to a guessed pointer";
    case AOWL_NE_R_CANVAS_DONOR: return "there is no canvas AND no live GameObject to take a class pointer from, so our own canvas could not even be allocated. INCONCLUSIVE -- nothing was created";
    case AOWL_NE_R_CANVAS_CREATE: return "a step of the canvas-creation sequence refused (allocate / RectTransform / AddComponent<Canvas> / set_renderMode / activate). Everything created up to that point was DESTROYED -- no half-built canvas is ever left behind";
    case AOWL_NE_R_CANVAS_UNVERIFIED: return "our canvas was created and every call succeeded, but within AOWL_NE_CANVAS_SETTLE_TICKS it never read back as renderMode==ScreenSpaceOverlay AND activeInHierarchy AND a rect of at least AOWL_NE_MIN_CANVAS_PX on both axes. It was DESTROYED rather than parented to. Calls returning is not a finished state";
    case AOWL_NE_R_NO_GRAPHIC:   return "no live Graphic donor was found, so nuAdd could only ever answer INCONCLUSIVE for the box component";
    case AOWL_NE_R_BUILD_FAILED: return "the pool build refused partway; the partial pool was destroyed rather than left half-parented";
    case AOWL_NE_R_FAULTED:      return "self-disabled after AOWL_NE_MAX_FAULTS faults inside the guarded tick";
    case AOWL_NE_R_DISC_FAULTED: return "the canvas walk itself faulted AOWL_NE_MAX_DISC_FAULTS times; every node is liveness-checked before any internal call, so these were NOT fake nulls and the cause is unknown -- discovery stopped rather than fault every frame";
    case AOWL_NE_R_SEED_TRIES:   return "seeding was attempted AOWL_NE_MAX_SEED_TRIES times without ever queueing a root; Scene::GetRootGameObjects ALLOCATES, so retrying it every frame forever is itself a defect. This is INCONCLUSIVE -- read the `seed:` ledger for which step and which root index";
    case AOWL_NE_R_NO_STRING:    return "the two managed type-name strings could not be interned (nativeui's intern table is full); GetComponent(String) has nothing to be asked with";
    default:                     return "?";
    }
}

/* ---- fault budget ------------------------------------------------------ */
static int32_t g_aowl_ne_faults = 0;
static int32_t aowl_ne_fault_count(void) { return g_aowl_ne_faults; }
static void    aowl_ne_note_fault(void)  { if (g_aowl_ne_faults < 1000) g_aowl_ne_faults++; }
static int32_t aowl_ne_disabled(void)    { return g_aowl_ne_faults >= AOWL_NE_MAX_FAULTS ? 1 : 0; }

static int32_t aowl_ne_pool(void)        { return AOWL_NE_POOL; }
static int32_t aowl_ne_factions(void)    { return AOWL_NE_FACTIONS; }
static int32_t aowl_ne_max_nodes(void)   { return AOWL_NE_MAX_NODES; }
static int32_t aowl_ne_max_children(void){ return AOWL_NE_MAX_CHILDREN; }
static int32_t aowl_ne_max_depth(void)   { return AOWL_NE_MAX_DEPTH; }
static int32_t aowl_ne_max_disc_faults(void) { return AOWL_NE_MAX_DISC_FAULTS; }
static int32_t aowl_ne_max_seed_tries(void)  { return AOWL_NE_MAX_SEED_TRIES; }
static int32_t aowl_ne_max_seed_skips(void)  { return AOWL_NE_MAX_SEED_SKIPS; }
static int32_t aowl_ne_slice_ms(void)    { return AOWL_NE_SLICE_MS; }
static int32_t aowl_ne_scan_every(void)  { return AOWL_NE_SCAN_EVERY; }
static int32_t aowl_ne_verdict_every(void) { return AOWL_NE_VERDICT_EVERY; }
static float   aowl_ne_min_canvas_px(void) { return AOWL_NE_MIN_CANVAS_PX; }
static int32_t aowl_ne_canvas_sort_order(void) { return AOWL_NE_CANVAS_SORT_ORDER; }
static int32_t aowl_ne_canvas_settle_ticks(void) { return AOWL_NE_CANVAS_SETTLE_TICKS; }
static int32_t aowl_ne_ui_layer(void) { return AOWL_NE_UI_LAYER; }

/* Is a projected screen point actually ON the screen this frame? A box whose
 * rect reads back off-screen is NOT evidence of rendering, so PASS must not
 * count it. Written in C so the diag and the placement use one predicate. */
static int32_t aowl_ne_on_screen(float x, float y, float w, float h,
                                 float sw, float sh) {
    if (!(w > 0.5f) || !(h > 0.5f)) return 0;       /* NaN-safe: !(x>y)      */
    if (!(w < 16384.0f) || !(h < 16384.0f)) return 0;
    if (!(sw > 16.0f) || !(sh > 16.0f)) return 0;
    if (!(x > -w) || !(x < sw + w)) return 0;
    if (!(y > -h) || !(y < sh + h)) return 0;
    return 1;
}

/* ---- THE PER-FRAME COST METER -----------------------------------------
 *
 * The user has twice reported that the game "runs like crap" with host features
 * on, and a per-frame path that cannot say what it costs is a per-frame path
 * nobody can defend. This is the same shape as the maps mod's `drawCost` line:
 * QueryPerformanceCounter around the guarded tick, kept as a running max and a
 * running mean in MICROSECONDS, printed with the verdict.
 *
 * It measures the WHOLE guarded body, so it includes discovery while discovery
 * is running -- which is why the max and the mean are reported separately and
 * why the meter can be RESET when the state machine reaches NeRun. A mean that
 * silently averaged the 6ms discovery slices into the steady state would be a
 * number that cannot be wrong, i.e. a number that says nothing. */
#include <windows.h>
#include <string.h>

/* WHY THIS WAS REWRITTEN -- measured 2026-08-31.
 *
 * The previous meter reported `mean 15887868ns, max 350605us over 435 guarded
 * tick(s) since the pool was built`. Two defects made that number undefendable,
 * and NEITHER could be settled by reading it:
 *
 *  1. ONE POOL for every state. `aowl_ne_cost_reset` fires only on the
 *     NeBuild->NeRun edge, so a canvas teardown that sends the machine back to
 *     NeIdle/NeDiscover feeds SEEDING ticks (178 scene roots) and 6ms sliced
 *     walk ticks into a total still LABELLED "since the pool was built". The
 *     label asserted steady state; the samples were whatever happened.
 *  2. The reset fired INSIDE the bracket -- `cost_begin` had already stamped
 *     `t0`, so the pool-build tick itself (64 GameObject creations) was
 *     recorded as sample #1 of the "clean" steady state. That is the only
 *     credible source of a 350ms sample.
 *
 * And it could not answer the question that actually matters: is the number the
 * BODY's own work, or a frame interval leaking into the bracket? So the meter
 * now also samples the TICK-TO-TICK interval from the same clock. If body ~=
 * interval the bracket is wrong; if body << interval the body cost is real.
 * That comparison is printed, not inferred.
 *
 * Everything below is NANOSECONDS end to end. The old line mixed `...ns` and
 * `...us` in one sentence, which is how a 15.9ms mean got read three different
 * ways in one session.
 *
 * Phases are disjoint and exhaustive: every recorded tick lands in exactly one.
 */

#define AOWL_NE_PH_GATE     0   /* menu/loading gate: returned before work    */
#define AOWL_NE_PH_DISCOVER 1   /* seed + sliced canvas walk                  */
#define AOWL_NE_PH_SETTLE   2
#define AOWL_NE_PH_BUILD    3   /* the one-off pool construction              */
#define AOWL_NE_PH_RUN      4   /* THE STEADY STATE -- the only budgeted one  */
#define AOWL_NE_PH_N        5

/* THE BUDGET. Stated up front so the verdict can FAIL. The author's declared
 * bound for the run path is <=64 projections, <=4096 float compares, <=64
 * setter calls, <=64 Graphic::set_color. At Win64 call cost that is tens of
 * microseconds; 250us is a generous ceiling that still leaves 15/16ths of a
 * 16.6ms frame. p95 above it is a FAIL -- not a number for a human to judge. */
#define AOWL_NE_BUDGET_NS   250000LL
/* Fewer than this many RUN samples and the verdict is INCONCLUSIVE, never
 * PASS. "I could not look" is not a pass. */
#define AOWL_NE_MIN_SAMPLES 120

/* Histogram edges in NANOSECONDS, for a real p95 instead of mean-and-max.
 * A mean plus a max cannot say whether one 350ms outlier carries the mean.
 *
 * WHY THE EDGES CHANGED -- measured 2026-08-31, live raid.
 *
 * The previous table's LAST edge was INT64_MAX, and `p95_ns` returned that edge
 * when the 95th sample landed in it. The run phase measured a 30ms mean against
 * a 20ms top edge, so EVERY sample fell in that final bucket and the verdict
 * printed:
 *
 *     FAIL: p95 9223372036854775.8us EXCEEDS the budget 250.0us
 *
 * 9223372036854775.8us is INT64_MAX/1000. That is a SENTINEL rendered as a
 * measurement -- a confidently wrong diagnostic, which this project treats as
 * worse than no diagnostic, because a reader has no way to tell it from a
 * number. Two changes, and they are one change:
 *
 *  1. The edge table is now entirely FINITE and reaches 1s, so a 30ms or 51ms
 *     sample lands on a real bound instead of falling off the end.
 *  2. Samples above the top edge go to a SEPARATE overflow counter, never to a
 *     bucket with a printable edge. If the p95 lands there, `p95_ns` returns
 *     AOWL_NE_P95_SAT and the caller is REQUIRED to say "histogram saturated,
 *     INCONCLUSIVE". There is no longer any code path that can turn a
 *     saturation into a numeral. */
#define AOWL_NE_NB 19
static const int64_t g_ne_edge[AOWL_NE_NB] = {
    1000LL, 2000LL, 5000LL, 10000LL, 20000LL, 50000LL, 100000LL,
    250000LL, 500000LL, 1000000LL, 2000000LL, 5000000LL, 10000000LL,
    20000000LL, 50000000LL, 100000000LL, 250000000LL, 500000000LL,
    1000000000LL };
/* Returned by `p95_ns` when the 95th sample is in the overflow counter. It is
 * NEGATIVE precisely so that no arithmetic or formatting path can mistake it
 * for a duration -- the old failure was a positive sentinel. */
#define AOWL_NE_P95_SAT (-2LL)

typedef struct {
    int64_t n, sum, max, over;      /* ns; `over` = samples > budget */
    int64_t h[AOWL_NE_NB];
    int64_t ovf;                    /* samples ABOVE the top finite edge */
} aowl_ne_bucket;

static aowl_ne_bucket g_ne_cost[AOWL_NE_PH_N];
static aowl_ne_bucket g_ne_gap;     /* tick-to-tick interval, all phases */
/* PER-PHASE tick interval. The lifetime `g_ne_gap` mean folds menu ticks and
 * raid ticks into one number: in the measured run it read 38ms while the raid's
 * own interval was ~100ms, so "the body is 78% of a tick" was comparing a
 * RUN-phase body against a mostly-MENU interval. The body-vs-frame question is
 * only answerable when both sides come from the same phase. */
static aowl_ne_bucket g_ne_gap_ph[AOWL_NE_PH_N];
static int64_t g_ne_gap_pending = -1;   /* this tick's interval, ns; -1 = none */
static int64_t g_ne_cost_t0   = 0;
static int64_t g_ne_prev_t0   = 0;
static int64_t g_ne_qpf       = 0;
static int     g_ne_phase     = AOWL_NE_PH_GATE;
static int64_t g_ne_dropped   = 0;  /* samples refused as absurd */

static void aowl_ne_bucket_add(aowl_ne_bucket* b, int64_t ns) {
    int i;
    b->n++; b->sum += ns;
    if (ns > b->max) b->max = ns;
    if (ns > AOWL_NE_BUDGET_NS) b->over++;
    for (i = 0; i < AOWL_NE_NB; i++) {
        if (ns <= g_ne_edge[i]) { b->h[i]++; return; }
    }
    b->ovf++;                       /* above every finite edge: counted apart */
}

/* ---- THE ONE CLOCK ------------------------------------------------------
 * Both the real bracket and the POSITIVE CONTROL below go through these two
 * helpers, so the control cannot accidentally be timed by a different
 * mechanism than the thing it is controlling for. That is the entire point of
 * a control, and it is why these are factored out rather than duplicated. */
static int64_t aowl_ne_qpc(void) {
    LARGE_INTEGER v;
    if (!g_ne_qpf) { LARGE_INTEGER f; QueryPerformanceFrequency(&f);
                     g_ne_qpf = (int64_t)f.QuadPart; }
    QueryPerformanceCounter(&v);
    return (int64_t)v.QuadPart;
}
static int64_t aowl_ne_elapsed_ns(int64_t t0) {
    if (g_ne_qpf <= 0) return -1;
    return ((aowl_ne_qpc() - t0) * 1000000000LL) / g_ne_qpf;
}

/* The accounting accumulator lives here, ABOVE `cost_begin`, because that is
 * the first function that touches it. See the long note at the sub-brackets. */
static aowl_ne_bucket g_ne_acc;
static int64_t g_ne_acc_cur = 0;

static void aowl_ne_cost_begin(void) {
    int64_t q = aowl_ne_qpc();
    /* The interval between consecutive tick STARTS. Sampled from the same
     * clock as the body so the two are directly comparable. Held PENDING and
     * filed at `cost_end`, once the tick has said which phase it was, so the
     * per-phase interval and the per-phase body describe the same ticks. */
    g_ne_gap_pending = -1;
    if (g_ne_prev_t0 && g_ne_qpf > 0) {
        int64_t d = q - g_ne_prev_t0;
        if (d > 0 && d < g_ne_qpf * 10) {
            g_ne_gap_pending = (d * 1000000000LL) / g_ne_qpf;
            aowl_ne_bucket_add(&g_ne_gap, g_ne_gap_pending);
        }
    }
    g_ne_prev_t0 = q;
    g_ne_cost_t0 = q;
    g_ne_acc_cur = 0;   /* the accounting identity is PER TICK */
    /* Default phase for a tick that faults before the body classified itself:
     * it is attributed, never silently dropped. */
    g_ne_phase = AOWL_NE_PH_GATE;
}

/* ---- THE POSITIVE CONTROL ----------------------------------------------
 *
 * THE QUESTION IT SETTLES, and why nothing else can settle it. The run phase
 * measured a 30ms mean for a body whose declared bound is <=64 projections,
 * <=4096 float compares and <=64 setter calls. That bound and that mean cannot
 * both be true. Exactly two explanations survive:
 *
 *   (A) the BRACKET is wrong -- something between `cost_begin` and `cost_end`
 *       blocks on the frame (a VSync wait, a render join, the drain being
 *       invoked from a point that is not where we think it is), in which case
 *       the number describes the game and the FAIL was an instrument artifact;
 *   (B) the COST is real, and one of the calls inside is far more expensive
 *       than a Win64 call has any right to be.
 *
 * No amount of reading the body distinguishes those, because both produce the
 * same source. So: bracket a KNOWN-TRIVIAL operation with the SAME clock
 * helpers, in the SAME place in the tick, and print what it says.
 *
 *   ctrl_out : taken immediately before the real bracket, OUTSIDE the SEH
 *              guard.
 *   ctrl_in  : taken at the top of the guarded body, INSIDE the SEH guard,
 *              which additionally prices guard entry itself.
 *
 * Both do the identical trivial work: 512 integer adds into a volatile sink,
 * so the optimiser cannot delete them and they cannot touch the game, the
 * managed heap, or any pointer. Expected: single-digit microseconds.
 *
 * READING IT is mechanical, which is the point -- there is no judgement call:
 *   ctrl tens of ms  -> (A). The bracket measures the frame. The run FAIL is an
 *                       artifact and the ESP path was never shown to be costly.
 *   ctrl microseconds
 *   while run is ms  -> (B). The cost is real; read the sub-phase lines to see
 *                       which call carries it.
 *   ctrl_out cheap but ctrl_in expensive -> the SEH guard entry is the cost,
 *                       which is neither of the above and would be new. */
static aowl_ne_bucket g_ne_ctrl_out;
static aowl_ne_bucket g_ne_ctrl_in;
static volatile int64_t g_ne_ctrl_sink = 0;

static void aowl_ne_ctrl_run(aowl_ne_bucket* into) {
    int64_t t0 = aowl_ne_qpc();
    int64_t acc = 0, ns;
    int i;
    for (i = 0; i < 512; i++) acc += (int64_t)i;
    g_ne_ctrl_sink = acc;               /* volatile: not optimised away */
    ns = aowl_ne_elapsed_ns(t0);
    if (ns < 0 || ns > 10000000000LL) return;
    aowl_ne_bucket_add(into, ns);
}
static void aowl_ne_ctrl_out(void) { aowl_ne_ctrl_run(&g_ne_ctrl_out); }
static void aowl_ne_ctrl_in(void)  { aowl_ne_ctrl_run(&g_ne_ctrl_in);  }
static int64_t aowl_ne_ctrl_mean_ns(int32_t which) {
    aowl_ne_bucket* b = which ? &g_ne_ctrl_in : &g_ne_ctrl_out;
    if (b->n <= 0) return -1;
    return b->sum / b->n;
}
static int64_t aowl_ne_ctrl_max_ns(int32_t which) {
    aowl_ne_bucket* b = which ? &g_ne_ctrl_in : &g_ne_ctrl_out;
    return b->max;
}
static int64_t aowl_ne_ctrl_samples(int32_t which) {
    aowl_ne_bucket* b = which ? &g_ne_ctrl_in : &g_ne_ctrl_out;
    return b->n;
}

/* ---- SUB-PHASE BRACKETS, for outcome (B) -------------------------------
 * If the control says the cost is real, the next question is WHICH call. These
 * price the four things a steady-state tick does, each with its own t0 so they
 * never nest and never clobber one another. They are only meaningful in the
 * RUN phase; nothing else calls them. Cost of the instrument itself: two QPC
 * reads per sub-phase per tick, ~30ns each. */
#define AOWL_NE_SUB_SCAN    0   /* the census pass (every Nth tick)          */
#define AOWL_NE_SUB_PROJECT 1   /* pass 1: <=64 WorldToScreen                */
#define AOWL_NE_SUB_SORT    2   /* pass 2: <=4096 float compares, no calls   */
#define AOWL_NE_SUB_APPLY   3   /* pass 3: set_color / sizeDelta / SetActive */
#define AOWL_NE_SUB_VERDICT 4   /* the readback: <=64 * 3 il2cpp calls       */
#define AOWL_NE_SUB_GATE    5   /* neRaidGate: rpDeployed, Camera.main, size */
#define AOWL_NE_SUB_LIVE    6   /* the canvas liveness pair, 2 il2cpp calls  */
#define AOWL_NE_SUB_N       7
static aowl_ne_bucket g_ne_sub[AOWL_NE_SUB_N];
static int64_t g_ne_sub_t0[AOWL_NE_SUB_N];

/* ---- THE ACCOUNTING IDENTITY -------------------------------------------
 * A decomposition that does not sum to the whole is not a decomposition; it is
 * a hole with labels around it. Whatever the sub-brackets measure inside ONE
 * tick is accumulated here, and `cost_end` files that total against the same
 * tick's body. `accounted = mean(acc) / mean(body)` is therefore a ratio of
 * two means over the SAME population -- unlike summing per-sub means, which
 * are taken over different `n` (scan runs every Nth tick) and cannot be added.
 *
 * It is falsifiable in the direction that matters: if it comes out at 78%,
 * 22% of the cost is somewhere no bracket is, and that is the answer. */
static void aowl_ne_sub_begin(int32_t id) {
    if (id < 0 || id >= AOWL_NE_SUB_N) return;
    g_ne_sub_t0[id] = aowl_ne_qpc();
}
static void aowl_ne_sub_end(int32_t id) {
    int64_t ns;
    if (id < 0 || id >= AOWL_NE_SUB_N || !g_ne_sub_t0[id]) return;
    ns = aowl_ne_elapsed_ns(g_ne_sub_t0[id]);
    g_ne_sub_t0[id] = 0;
    if (ns < 0 || ns > 10000000000LL) return;
    aowl_ne_bucket_add(&g_ne_sub[id], ns);
    g_ne_acc_cur += ns;
}
static int64_t aowl_ne_acc_mean_ns(void) {
    if (g_ne_acc.n <= 0) return -1;
    return g_ne_acc.sum / g_ne_acc.n;
}
static int64_t aowl_ne_acc_samples(void) { return g_ne_acc.n; }
static int64_t aowl_ne_sub_mean_ns(int32_t id) {
    if (id < 0 || id >= AOWL_NE_SUB_N || g_ne_sub[id].n <= 0) return -1;
    return g_ne_sub[id].sum / g_ne_sub[id].n;
}
static int64_t aowl_ne_sub_max_ns(int32_t id) {
    if (id < 0 || id >= AOWL_NE_SUB_N) return 0;
    return g_ne_sub[id].max;
}
static int64_t aowl_ne_sub_samples(int32_t id) {
    if (id < 0 || id >= AOWL_NE_SUB_N) return 0;
    return g_ne_sub[id].n;
}
static const char* aowl_ne_sub_name(int32_t id) {
    switch (id) {
    case AOWL_NE_SUB_SCAN:    return "scan";
    case AOWL_NE_SUB_PROJECT: return "project";
    case AOWL_NE_SUB_SORT:    return "sort";
    case AOWL_NE_SUB_APPLY:   return "apply";
    case AOWL_NE_SUB_VERDICT: return "verdict";
    case AOWL_NE_SUB_GATE:    return "gate";
    case AOWL_NE_SUB_LIVE:    return "live";
    default: return "?";
    }
}

/* Called by the body once it knows which state it is executing. This is what
 * keeps a seeding tick out of the steady-state pool -- the old code relied on a
 * reset that fired on one edge and could be bypassed by a teardown. */
static void aowl_ne_cost_phase(int32_t ph) {
    if (ph >= 0 && ph < AOWL_NE_PH_N) g_ne_phase = (int)ph;
}

static void aowl_ne_cost_end(void) {
    int64_t ns;
    if (!g_ne_cost_t0 || g_ne_qpf <= 0) return;
    ns = aowl_ne_elapsed_ns(g_ne_cost_t0);
    g_ne_cost_t0 = 0;
    /* File this tick's INTERVAL under the phase the tick turned out to be, so
     * body and interval are drawn from the same population. */
    if (g_ne_gap_pending >= 0) {
        aowl_ne_bucket_add(&g_ne_gap_ph[g_ne_phase], g_ne_gap_pending);
        g_ne_gap_pending = -1;
    }
    /* A refused sample is COUNTED. Silently dropping the pathological ones is
     * how a meter stops being able to report a bad number. */
    if (ns < 0 || ns > 10000000000LL) { g_ne_dropped++; return; }
    aowl_ne_bucket_add(&g_ne_cost[g_ne_phase], ns);
    /* Only the RUN phase is decomposed, so only RUN ticks may enter the
     * accounting population -- mixing a gate tick (which runs no sub-bracket
     * at all) into it would drag `accounted` down and read as a hole. */
    if (g_ne_phase == AOWL_NE_PH_RUN) aowl_ne_bucket_add(&g_ne_acc, g_ne_acc_cur);
}

static void aowl_ne_cost_reset(void) {
    int i;
    for (i = 0; i < AOWL_NE_PH_N; i++) {
        aowl_ne_bucket z; memset(&z, 0, sizeof(z));
        g_ne_cost[i] = z; g_ne_gap_ph[i] = z;
    }
    for (i = 0; i < AOWL_NE_SUB_N; i++) {
        aowl_ne_bucket z; memset(&z, 0, sizeof(z)); g_ne_sub[i] = z;
    }
    { aowl_ne_bucket z; memset(&z, 0, sizeof(z));
      g_ne_gap = z; g_ne_ctrl_out = z; g_ne_ctrl_in = z; g_ne_acc = z; }
    g_ne_dropped = 0;
    /* t0 is deliberately LEFT ALONE: reset can be called from inside the
     * bracket, and clearing t0 there would make the enclosing tick vanish. */
}

static int64_t aowl_ne_cost_samples(int32_t ph) {
    if (ph < 0 || ph >= AOWL_NE_PH_N) return 0;
    return g_ne_cost[ph].n;
}
static int64_t aowl_ne_cost_max_ns(int32_t ph) {
    if (ph < 0 || ph >= AOWL_NE_PH_N) return 0;
    return g_ne_cost[ph].max;
}
static int64_t aowl_ne_cost_mean_ns(int32_t ph) {
    if (ph < 0 || ph >= AOWL_NE_PH_N || g_ne_cost[ph].n <= 0) return -1;
    return g_ne_cost[ph].sum / g_ne_cost[ph].n;
}
static int64_t aowl_ne_cost_over(int32_t ph) {
    if (ph < 0 || ph >= AOWL_NE_PH_N) return 0;
    return g_ne_cost[ph].over;
}
/* Upper edge of the bucket holding the p95 sample -- an UPPER BOUND, stated as
 * such by the caller, never dressed up as an exact percentile.
 *
 * THREE RETURNS, never two: a real edge, -1 for "no samples", and
 * AOWL_NE_P95_SAT for "the 95th sample is above the top finite edge". The old
 * version had the overflow bucket carrying INT64_MAX as its edge and returned
 * it, which is how a sentinel got printed as 9223372036854775.8us. There is now
 * no edge in the table that is not a real duration. */
static int64_t aowl_ne_cost_p95_ns(int32_t ph) {
    int64_t want, seen = 0; int i;
    if (ph < 0 || ph >= AOWL_NE_PH_N || g_ne_cost[ph].n <= 0) return -1;
    want = (g_ne_cost[ph].n * 95 + 99) / 100;
    for (i = 0; i < AOWL_NE_NB; i++) {
        seen += g_ne_cost[ph].h[i];
        if (seen >= want) return g_ne_edge[i];
    }
    return AOWL_NE_P95_SAT;
}
static int64_t aowl_ne_p95_sat(void)  { return AOWL_NE_P95_SAT; }
static int64_t aowl_ne_top_edge_ns(void) { return g_ne_edge[AOWL_NE_NB - 1]; }
static int64_t aowl_ne_cost_ovf(int32_t ph) {
    if (ph < 0 || ph >= AOWL_NE_PH_N) return 0;
    return g_ne_cost[ph].ovf;
}
static int64_t aowl_ne_gap_mean_ns(void) {
    if (g_ne_gap.n <= 0) return -1;
    return g_ne_gap.sum / g_ne_gap.n;
}
static int64_t aowl_ne_gap_samples(void)  { return g_ne_gap.n; }
/* The interval between the ticks OF ONE PHASE -- the only interval the
 * body-vs-frame comparison may legitimately use. */
static int64_t aowl_ne_gap_ph_mean_ns(int32_t ph) {
    if (ph < 0 || ph >= AOWL_NE_PH_N || g_ne_gap_ph[ph].n <= 0) return -1;
    return g_ne_gap_ph[ph].sum / g_ne_gap_ph[ph].n;
}
static int64_t aowl_ne_gap_ph_samples(int32_t ph) {
    if (ph < 0 || ph >= AOWL_NE_PH_N) return 0;
    return g_ne_gap_ph[ph].n;
}
static int64_t aowl_ne_cost_dropped(void) { return g_ne_dropped; }
static int64_t aowl_ne_budget_ns(void)    { return AOWL_NE_BUDGET_NS; }
static int64_t aowl_ne_min_samples(void)  { return AOWL_NE_MIN_SAMPLES; }
static const char* aowl_ne_phase_name(int32_t ph) {
    switch (ph) {
    case AOWL_NE_PH_GATE:     return "gate";
    case AOWL_NE_PH_DISCOVER: return "discover";
    case AOWL_NE_PH_SETTLE:   return "settle";
    case AOWL_NE_PH_BUILD:    return "build";
    case AOWL_NE_PH_RUN:      return "run";
    default:                  return "?";
    }
}

/* ---- THE RECOLOUR METER ----------------------------------------------- */
/* Colour is no longer baked in at build time, so the claim "nothing is
 * recoloured per frame" is no longer free -- it has to be MEASURED. This counts
 * every `Graphic::set_color` the placement issues; if the (class, band) cache is
 * working the steady state is ~0 per frame and a walking player produces a
 * trickle. A count that tracks the box count every frame falsifies the claim. */
static int64_t g_ne_recolours = 0;
static void    aowl_ne_note_recolour(void) { g_ne_recolours++; }
static int64_t aowl_ne_recolours(void)     { return g_ne_recolours; }

#endif /* AOWLSPT_NATESP_H */
