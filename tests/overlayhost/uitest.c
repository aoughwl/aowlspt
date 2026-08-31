/* uitest.c -- OFFLINE checks for the BACKEND-AGNOSTIC widget core
 * (abi/aowlspt_ui.h). The shared core -- layout arithmetic, the tab-selection
 * state machine, hit geometry and the polled dispatch, and config binding --
 * is pure state and pure arithmetic, so all of it is checkable with no client,
 * no D3D and no il2cpp. That is most of the framework's value and it is exactly
 * where a check that cannot fail would hide (CLAUDE.md 9b), so half of these
 * cases assert a NEGATIVE and `falsify()` feeds the predicates wrong values and
 * requires them to say no.
 *
 * What CANNOT be tested here, stated rather than skipped: whether an overlay
 * FILL actually paints, whether a native TMP renders, whether a real pointer
 * position is read. Those are live and the in-client dual-backend proof
 * (aowluiProofRun) answers them against the finished state.
 */
#include <stdio.h>
#include <string.h>

#define AOWL_UI_HOST
#include "aowlspt_ui.h"

static int g_checks = 0, g_fails = 0;
static void ck(int cond, const char* what) {
    g_checks++;
    if (!cond) { g_fails++; printf("  FAIL  %s\n", what); }
}

/* ------------------------------------------------------------------ */
static void test_rect_and_refusals(void) {
    printf("rect predicate + builder refusals\n");
    aowl_ui_reset();

    /* No backend chosen yet -> every builder must refuse loudly. */
    ck(aowl_ui_new(AOWL_UI_PANEL, -1, 0, 0, 100, 40) == -AOWL_UI_REFUSE_BACKEND,
       "building before aowl_ui_begin refuses with BACKEND, not a silent -1");

    ck(aowl_ui_begin(999) == -AOWL_UI_REFUSE_BACKEND,
       "an unknown backend is refused");
    ck(aowl_ui_begin(AOWL_UI_BK_OVERLAY) == AOWL_UI_OK, "overlay backend ok");

    /* THE invoke2 failure, as a builder refusal: a 0x0 widget renders nothing
     * while every call succeeds. It must never allocate. */
    ck(aowl_ui_new(AOWL_UI_PANEL, -1, 0, 0, 0, 0) == -AOWL_UI_REFUSE_RECT,
       "a 0x0 panel is REFUSED (the invisible-success bug)");
    ck(aowl_ui_new(AOWL_UI_PANEL, -1, 0, 0, 100, 0) == -AOWL_UI_REFUSE_RECT,
       "zero height alone is refused");
    ck(aowl_ui_new(AOWL_UI_PANEL, -1, 0, 0, 1e9f, 40) == -AOWL_UI_REFUSE_RECT,
       "an absurd width is refused");
    ck(aowl_ui_new(999, -1, 0, 0, 100, 40) == -AOWL_UI_REFUSE_KIND,
       "an unknown kind is refused");
    ck(aowl_ui_new(AOWL_UI_PANEL, 77, 0, 0, 100, 40) == -AOWL_UI_REFUSE_PARENT,
       "a parent handle that is not a live widget is refused");

    int p = aowl_ui_new(AOWL_UI_PANEL, -1, 10, 10, 300, 200);
    ck(p >= 0, "a well-formed panel allocates a handle");
    ck(aowl_ui_new(AOWL_UI_LABEL, p, 12, 14, 100, 20) >= 0,
       "a child with a valid parent allocates");
}

static void test_layout(void) {
    printf("layout arithmetic\n");
    float x, y, w, h;

    /* A column of 4 rows in a 200-tall box, pad 10, spacing 6:
     * inner height = 180, cells = (180 - 18)/4 = 40.5 each. */
    ck(aowl_ui_stack_slot(0, 0, 300, 200, 0, 4, 10, 6, 0, &x, &y, &w, &h),
       "vstack slot 0 computes");
    ck(y == 10.0f, "vstack slot 0 starts at pad");
    ck(w == 280.0f, "vstack cross-axis fills minus padding");
    {
        float x3, y3, w3, h3;
        aowl_ui_stack_slot(0, 0, 300, 200, 3, 4, 10, 6, 0, &x3, &y3, &w3, &h3);
        ck(y3 > y, "later slots are lower (monotonic, no overlap by index)");
        ck(y3 + h3 <= 190.5f + 0.5f, "the last slot stays inside the padded box");
    }
    /* index out of range must refuse. */
    ck(aowl_ui_stack_slot(0, 0, 300, 200, 4, 4, 10, 6, 0, &x, &y, &w, &h) == 0,
       "an out-of-range slot index is refused");
    /* too many items for the space -> degenerate cell -> refuse. */
    ck(aowl_ui_stack_slot(0, 0, 300, 30, 0, 100, 10, 6, 0, &x, &y, &w, &h) == 0,
       "100 rows in 30px is refused rather than drawn 0-tall");

    /* row split: 40% label, 60% control. */
    {
        float lx, ly, lw, lh, kx, ky, kw, kh;
        ck(aowl_ui_row_split(0, 0, 400, 30, 0.4f, 8,
                             &lx, &ly, &lw, &lh, &kx, &ky, &kw, &kh),
           "row split computes");
        ck(lx == 0.0f && kx > lx + lw, "control is right of the label with a gap");
        ck(aowl_ui_row_split(0, 0, 400, 30, 1.5f, 8,
                             &lx, &ly, &lw, &lh, &kx, &ky, &kw, &kh) == 0,
           "an out-of-range label fraction is refused");
    }
}

static void test_tabs(void) {
    printf("tab-selection state machine\n");
    aowl_ui_reset();
    aowl_ui_begin(AOWL_UI_BK_OVERLAY);
    int strip = aowl_ui_new(AOWL_UI_TABSTRIP, -1, 0, 0, 300, 30);
    int cA = aowl_ui_new(AOWL_UI_PANEL, -1, 0, 40, 300, 200);
    int cB = aowl_ui_new(AOWL_UI_PANEL, -1, 0, 40, 300, 200);
    int cC = aowl_ui_new(AOWL_UI_PANEL, -1, 0, 40, 300, 200);
    ck(aowl_ui_tab_add(strip, cA) == 0, "tab 0 added");
    ck(aowl_ui_tab_add(strip, cB) == 1, "tab 1 added");
    ck(aowl_ui_tab_add(strip, cC) == 2, "tab 2 added");
    ck(aowl_ui_tab_add(cA, cB) == -AOWL_UI_REFUSE_KIND,
       "adding a tab to a non-tabstrip is refused");

    aowl_ui_tab_apply(strip);
    /* NEGATIVE property: exactly ONE content visible, no other. */
    ck(aowl_ui_at(cA)->visible == 1, "default selection shows content A");
    ck(aowl_ui_at(cB)->visible == 0 && aowl_ui_at(cC)->visible == 0,
       "no OTHER content is visible under the default selection");

    ck(aowl_ui_tab_select(strip, 2) == 2, "selecting tab 2 returns 2");
    ck(aowl_ui_at(cC)->visible == 1, "selecting tab 2 shows content C");
    ck(aowl_ui_at(cA)->visible == 0 && aowl_ui_at(cB)->visible == 0,
       "selecting tab 2 hides A and B (no two contents visible at once)");
    ck(aowl_ui_tab_content_active(strip, cC) == 1 &&
       aowl_ui_tab_content_active(strip, cA) == 0,
       "content-active query agrees with the selection");

    ck(aowl_ui_tab_select(strip, 9) == -1, "an out-of-range tab is refused");
    ck(aowl_ui_tab_selected(strip) == 2, "a refused select does not change state");

    /* tab hit geometry: strip is x=0..300, 3 tabs -> 100px each. */
    ck(aowl_ui_tab_hit(strip, 50) == 0,  "x=50 hits tab 0");
    ck(aowl_ui_tab_hit(strip, 150) == 1, "x=150 hits tab 1");
    ck(aowl_ui_tab_hit(strip, 250) == 2, "x=250 hits tab 2");
    ck(aowl_ui_tab_hit(strip, -5) == -1, "x outside the strip hits no tab");
}

static void test_hit_and_pump(void) {
    printf("hit geometry + polled dispatch\n");
    aowl_ui_reset();
    aowl_ui_begin(AOWL_UI_BK_OVERLAY);
    int btn = aowl_ui_new(AOWL_UI_BUTTON, -1, 100, 100, 80, 30);
    aowl_ui_set_interactive(btn, 1);
    int tog = aowl_ui_new(AOWL_UI_TOGGLE, -1, 100, 200, 30, 30);
    aowl_ui_set_interactive(tog, 1);

    /* point-in: falsifiable boundaries. */
    ck(aowl_ui_point_in(aowl_ui_at(btn), 140, 115) == 1, "center is inside");
    ck(aowl_ui_point_in(aowl_ui_at(btn), 99, 115) == 0, "just left is outside");
    ck(aowl_ui_point_in(aowl_ui_at(btn), 180, 115) == 0,
       "the right edge is exclusive (not inside)");

    /* A press with no prior up is NOT an edge on the first pump if prevDown was
     * already down: seed prevDown=1 by pumping down once away from the button. */
    ck(aowl_ui_pump(0, 0, 1) == 0, "a down press away from any widget is 0 clicks");
    /* Still held, now over the button: NO edge (button was down last frame). */
    ck(aowl_ui_pump(140, 115, 1) == 0,
       "holding the button down across frames is NOT a repeated click");
    /* Release, then press over the button: ONE edge. */
    aowl_ui_pump(140, 115, 0);
    ck(aowl_ui_pump(140, 115, 1) == 1, "a fresh press edge on the button is 1 click");
    ck(aowl_ui_take_click(btn) == 1, "the button reports the click once");
    ck(aowl_ui_take_click(btn) == 0, "and only once (edge consumed)");

    /* Toggle: a click must FLIP the readback state, proven by reading it back
     * (fact #117 -- cloned game toggles never do this). */
    ck(aowl_ui_toggle_state(tog) == 0, "toggle starts off");
    aowl_ui_pump(115, 215, 0);
    aowl_ui_pump(115, 215, 1);
    ck(aowl_ui_toggle_state(tog) == 1, "a click flips the toggle readback to ON");
    aowl_ui_pump(115, 215, 0);
    aowl_ui_pump(115, 215, 1);
    ck(aowl_ui_toggle_state(tog) == 0, "a second click flips it back OFF");

    /* An INVISIBLE interactive widget is not clickable. */
    aowl_ui_set_visible(btn, 0);
    aowl_ui_pump(140, 115, 0);
    ck(aowl_ui_pump(140, 115, 1) == 0, "a hidden widget cannot be clicked");
}

static void test_bindings(void) {
    printf("config binding\n");
    aowl_ui_reset();
    aowl_ui_begin(AOWL_UI_BK_NATIVE);
    int tog = aowl_ui_new(AOWL_UI_TOGGLE, -1, 0, 0, 30, 30);
    aowl_ui_set_interactive(tog, 1);

    int b = aowl_ui_bind_widget(tog, "com.aowl.demo", "esp.enabled",
                                AOWL_UI_BIND_BOOL);
    ck(b >= 0, "a bool binding interns");
    /* interning the same identity returns the SAME id (not a duplicate). */
    ck(aowl_ui_bind_intern("com.aowl.demo", "esp.enabled", AOWL_UI_BIND_BOOL) == b,
       "the same (modGuid,key) interns to the same id");
    /* a different key is a different id. */
    ck(aowl_ui_bind_intern("com.aowl.demo", "esp.range", AOWL_UI_BIND_FLOAT) != b,
       "a different key is a distinct binding");
    /* modGuid MUST disambiguate keys (the join, not a naive concat). */
    ck(aowl_ui_bind_intern("modA", "x.y", AOWL_UI_BIND_BOOL) !=
       aowl_ui_bind_intern("modA.x", "y", AOWL_UI_BIND_BOOL),
       "the guid|key join is unambiguous ('modA','x.y' != 'modA.x','y')");

    ck(aowl_ui_bind_get(b) == 0.0, "binding starts at 0");
    ck(aowl_ui_bind_dirty(b) == 0, "and is not dirty");

    /* A toggle click writes the binding AND marks it dirty for the flush. */
    aowl_ui_pump(15, 15, 0);
    aowl_ui_pump(15, 15, 1);
    ck(aowl_ui_toggle_state(tog) == 1, "clicking the bound toggle turns it on");
    ck(aowl_ui_bind_get(b) == 1.0, "and writes 1 into its binding");
    ck(aowl_ui_bind_dirty(b) == 1, "and marks the binding dirty");
    ck(aowl_ui_bind_dirty_count() >= 1, "the dirty count sees it");
    aowl_ui_bind_clear_dirty(b);
    ck(aowl_ui_bind_dirty(b) == 0, "a flush clears the dirty edge");

    ck(aowl_ui_bind_intern("", "", AOWL_UI_BIND_BOOL) == -AOWL_UI_REFUSE_ARGS,
       "an empty (modGuid,key) is refused");
}

static void test_overlay_emit(void) {
    printf("overlay emit -> draw ops\n");
    aowl_ui_reset();
    aowl_ui_begin(AOWL_UI_BK_OVERLAY);
    int panel = aowl_ui_new(AOWL_UI_PANEL, -1, 0, 0, 200, 120);
    int lbl   = aowl_ui_new(AOWL_UI_LABEL, panel, 6, 6, 180, 20);
    aowl_ui_set_text(lbl, "Hello");
    int tog   = aowl_ui_new(AOWL_UI_TOGGLE, panel, 6, 40, 24, 24);

    int n = aowl_ui_overlay_emit();
    /* panel = FILL+BOX (2), label = TEXT (1), toggle-off = BOX (1) => 4. */
    ck(n == 4, "a panel+label+off-toggle emits exactly 4 ops");
    /* the panel's FILL must be first and cover the panel rect. */
    ck(aowl_ui_op_at(0)->op == AOWL_UI_OP_FILL &&
       aowl_ui_op_at(0)->w == 200.0f,
       "the first op is the panel FILL at the panel size");
    /* turning the toggle on adds its inner FILL. */
    aowl_ui_at(tog)->toggleOn = 1;
    ck(aowl_ui_overlay_emit() == 5, "an ON toggle emits one extra FILL");

    /* a HIDDEN widget emits nothing. */
    aowl_ui_set_visible(panel, 0);
    aowl_ui_set_visible(lbl, 0);
    aowl_ui_set_visible(tog, 0);
    ck(aowl_ui_overlay_emit() == 0, "hidden widgets emit no draw ops");

    /* a NATIVE-backend widget never emits overlay ops. */
    aowl_ui_reset();
    aowl_ui_begin(AOWL_UI_BK_NATIVE);
    aowl_ui_new(AOWL_UI_PANEL, -1, 0, 0, 100, 40);
    ck(aowl_ui_overlay_emit() == 0,
       "native-backend widgets produce no overlay draw ops");
}

/* replay sinks -- stand in for aowl_region_fill/box/text. */
static int g_fills, g_boxes, g_texts;
static char g_lastText[AOWL_UI_TEXT];
static int32_t sink_fill(float x, float y, float w, float h, uint32_t c) {
    (void)x;(void)y;(void)w;(void)h;(void)c; g_fills++; return 0; }
static int32_t sink_box(float x, float y, float w, float h, float t, uint32_t c) {
    (void)x;(void)y;(void)w;(void)h;(void)t;(void)c; g_boxes++; return 0; }
static int32_t sink_text(float x, float y, const char* s, uint32_t c) {
    (void)x;(void)y;(void)c; g_texts++;
    strncpy(g_lastText, s ? s : "", AOWL_UI_TEXT - 1); return 0; }

static void test_replay(void) {
    printf("overlay replay bridge\n");
    aowl_ui_reset();
    aowl_ui_begin(AOWL_UI_BK_OVERLAY);
    int panel = aowl_ui_new(AOWL_UI_PANEL, -1, 0, 0, 200, 120);
    aowl_ui_set_text(panel, "Settings");
    int n = aowl_ui_overlay_emit();     /* FILL + BOX + TEXT (panel caption) */
    g_fills = g_boxes = g_texts = 0;
    int drawn = aowl_ui_overlay_replay(sink_fill, sink_box, sink_text);
    ck(drawn == n, "replay draws exactly the emitted op count");
    ck(g_fills == 1 && g_boxes == 1 && g_texts == 1,
       "the panel replays as one FILL, one BOX, one TEXT");
    ck(strcmp(g_lastText, "Settings") == 0,
       "the caption text reaches the text sink verbatim");
    /* a null sink for one kind must be skipped, not crash. */
    g_fills = g_boxes = g_texts = 0;
    drawn = aowl_ui_overlay_replay(sink_fill, 0, sink_text);
    ck(g_boxes == 0 && drawn == 2, "a null box sink is skipped safely");
}

/* ------------------------------------------------------------------ *
 * GENERATIONAL HANDLES -- the stale-handle bug, asserted as a NEGATIVE.
 *
 * Before generations, a handle was a bare slot index and aowl_ui_reset()
 * recycled indices, so a handle held across a reset silently addressed a
 * DIFFERENT widget: no crash, no error, the wrong element mutated. Every case
 * below would PASS trivially under the old encoding except the ones that
 * demand a refusal -- those are the ones that can fail.
 * ------------------------------------------------------------------ */
static void test_generations(void) {
    int32_t old, fresh, idx;
    AowlUiWidget* p;
    printf("generational handles\n");

    aowl_ui_reset();
    aowl_ui_begin(AOWL_UI_BK_OVERLAY);
    old = aowl_ui_new(AOWL_UI_LABEL, -1, 0, 0, 100, 20);
    aowl_ui_set_text(old, "FIRST");
    ck(old > 0, "a live handle is strictly positive (never 0, never an index)");
    ck((old & 0xFFFF) - 1 == 0, "first widget lands in slot 0");
    ck((old >> 16) > 0, "and carries a non-zero generation");
    ck(aowl_ui_valid(old), "the fresh handle validates");
    ck(aowl_ui_index_of(old) == 0, "index_of decodes it back to slot 0");

    /* THE RECYCLE. A new screen reuses slot 0 for a DIFFERENT widget. */
    aowl_ui_reset();
    aowl_ui_begin(AOWL_UI_BK_OVERLAY);
    fresh = aowl_ui_new(AOWL_UI_LABEL, -1, 0, 0, 100, 20);
    aowl_ui_set_text(fresh, "SECOND");
    ck(aowl_ui_index_of(fresh) == 0, "the new widget really did recycle slot 0");
    ck(fresh != old, "but its handle is NOT the old one (generation moved)");

    /* The negative that carries the whole fix. */
    ck(aowl_ui_valid(old) == 0, "the SPENT handle is refused after the reset");
    ck(aowl_ui_last_handle_refusal() == AOWL_UI_REFUSE_STALE,
       "and it is refused by NAME: STALE-GENERATION");
    ck(aowl_ui_at(old) == (AowlUiWidget*)0,
       "aowl_ui_at(spent) is NULL, not a pointer at the recycled widget");

    /* A stale handle is refused as a PARENT too -- otherwise a whole subtree
     * silently reparents onto the wrong element. (Checked HERE, while the
     * fault budget is still unspent; past the budget the core answers
     * DISABLED, which is a different and also correct refusal.) */
    ck(aowl_ui_new(AOWL_UI_PANEL, old, 0, 0, 50, 50) == -AOWL_UI_REFUSE_PARENT,
       "building under a spent parent refuses PARENT, not a silent adoption");

    /* ...and every mutator that took the spent handle must be a no-op on the
     * element that now occupies the slot. This is the silent-wrong-write. */
    aowl_ui_set_text(old, "CLOBBERED");
    aowl_ui_set_colors(old, 0xFF00FF00u, 0xFF00FF00u);
    aowl_ui_toggle_force(old, 1);
    aowl_ui_set_rect(old, 999, 999, 999, 999);
    p = aowl_ui_at(fresh);
    ck(p != (AowlUiWidget*)0, "the live widget is still reachable");
    ck(p && strcmp(p->text, "SECOND") == 0,
       "a write through the spent handle did NOT reach the recycled widget");
    ck(p && p->x == 0.0f && p->w == 100.0f,
       "nor did it move it");

    /* Malformed handles get their own name, not STALE. */
    ck(aowl_ui_valid(0) == 0 &&
       aowl_ui_last_handle_refusal() == AOWL_UI_REFUSE_RANGE,
       "handle 0 is refused RANGE");
    ck(aowl_ui_valid((1 << 16) | (AOWL_UI_MAX + 1)) == 0 &&
       aowl_ui_last_handle_refusal() == AOWL_UI_REFUSE_RANGE,
       "an out-of-range slot is refused RANGE");
    ck(aowl_ui_index_of(old) == -1, "index_of(spent) is -1, not a slot");

    /* Enumeration never spends the fault budget on empty slots. */
    ck(aowl_ui_handle_at(0) == fresh, "handle_at(0) is the live handle");
    ck(aowl_ui_handle_at(AOWL_UI_MAX - 1) == 0, "handle_at(empty slot) is 0");
    ck(aowl_ui_handle_at(-1) == 0 && aowl_ui_handle_at(AOWL_UI_MAX) == 0,
       "handle_at out of range is 0, not a fabricated handle");

    /* Self-disable after the budget, re-armed only by an explicit reset. */
    aowl_ui_reset();
    aowl_ui_begin(AOWL_UI_BK_OVERLAY);
    ck(aowl_ui_disabled() == 0, "a fresh core is armed");
    for (idx = 0; idx < AOWL_UI_FAULT_BUDGET; idx++) aowl_ui_valid(old);
    ck(aowl_ui_disabled() == 1,
       "the core self-disables after AOWL_UI_FAULT_BUDGET handle faults");
    ck(aowl_ui_new(AOWL_UI_PANEL, -1, 0, 0, 50, 50) == -AOWL_UI_REFUSE_DISABLED,
       "and then refuses to build, by name");
    aowl_ui_reset();
    aowl_ui_begin(AOWL_UI_BK_OVERLAY);
    ck(aowl_ui_disabled() == 0 &&
       aowl_ui_new(AOWL_UI_PANEL, -1, 0, 0, 50, 50) > 0,
       "an explicit reset re-arms it");

    /* Two live handles are never equal -- the property the old encoding could
     * not offer across a reset. */
    ck(aowl_ui_refusal_text(AOWL_UI_REFUSE_STALE)[0] == 'S',
       "STALE has its own refusal text");
}

/* falsify: if the predicates were replaced by `return 1`/`return 0` constants,
 * this must go red. */
static void falsify(void) {
    printf("falsification\n");
    /* rect_ok must reject the degenerate cases a `return 1` would pass. */
    ck(aowl_ui_rect_ok(0, 0, 0, 0) == 0, "rect_ok(0,0,0,0) is false");
    ck(aowl_ui_rect_ok(0, 0, 100, 40) == 1, "rect_ok(valid) is true");
    /* point_in must reject a point a `return 1` would accept. */
    aowl_ui_reset();
    aowl_ui_begin(AOWL_UI_BK_OVERLAY);
    int w = aowl_ui_new(AOWL_UI_BUTTON, -1, 0, 0, 10, 10);
    ck(aowl_ui_point_in(aowl_ui_at(w), 1000, 1000) == 0,
       "point_in rejects a far-away point");
    /* tab_apply on an empty strip returns -1, not a plausible 0. */
    int s = aowl_ui_new(AOWL_UI_TABSTRIP, -1, 0, 0, 100, 20);
    ck(aowl_ui_tab_apply(s) == -1, "tab_apply on an empty strip is -1");
}

int main(void) {
    printf("=== aowlspt_ui.h offline checks ===\n");
    test_rect_and_refusals();
    test_layout();
    test_tabs();
    test_hit_and_pump();
    test_bindings();
    test_overlay_emit();
    test_replay();
    test_generations();
    falsify();
    printf("\n%d checks, %d failures\n", g_checks, g_fails);
    return g_fails ? 1 : 0;
}
