/* uxtest.c -- the settings screen's INPUT MODEL, headless.
 *
 * Two things here are logic, not appearance, and so can be settled offline:
 *
 *   * WHEEL ROUTING. A notch belongs to whichever list the cursor is over.
 *     The check is a NEGATIVE on both sides (CLAUDE.md 9b): over the nav, the
 *     control cursor must NOT have moved; over the control list, the nav's
 *     scroll must NOT have moved. A router that hands every notch to the nav
 *     -- the reported defect -- fails the second; the one that hands every
 *     notch to the list fails the first. There is no way to pass both by
 *     routing everything one way.
 *   * FOCUS. TAB moves focus between the nav column and the control list, and
 *     the keys that belong to the unfocused side must do NOTHING. Again a
 *     negative: with the nav focused, DOWN must not move `selItem`; with the
 *     list focused, DOWN must not move `selCat`.
 *
 * Also re-measures `aowl_ov_build` on the settings screen, and FAILS on a
 * ceiling rather than printing a number.
 *
 * Build:  gcc -O2 -I..\..\abi uxtest.c -o uxtest.exe
 */
#define COBJMACROS
#define CINTERFACE
#include <windows.h>
#include <stdio.h>
#include <string.h>

#include "aowlspt_overlay.h"

int32_t aowlspt_nim_patch_fired(int32_t slot, void* regs) {
    (void)slot; (void)regs; return 0;
}
int32_t aowlspt_nim_patch_returned(int32_t slot, void* regs) {
    (void)slot; (void)regs; return 0;
}

static int failures = 0;
static void eq_int(const char* what, int got, int want) {
    if (got == want) { printf("ok    %s\n", what); return; }
    printf("error %s: got %d, wanted %d\n", what, got, want);
    failures++;
}

/* ================================================================== *
 * WHAT THE FRAME ACTUALLY RENDERS, decoded from the vertex buffer.
 *
 * `aowl_ov_build` fills `g_ov.vtx` with no device and no back buffer, and a
 * glyph quad carries its own identity: the atlas is 16 cells of AOWL_OV_CW x
 * AOWL_OV_CH, so the cell index -- and therefore the character -- is
 * recoverable from u0/v0. That makes the nav header and the empty-state
 * caption assertable OFFLINE against what was DRAWN, rather than against the
 * string literal in the source, which is the check that cannot fail
 * (CLAUDE.md 9b).
 *
 * A quad is text when its two top corners differ in u; a solid rect samples
 * the white texel and has u0 == u1.
 * ================================================================== */

/* Reconstruct every text run in the frame into `out`, one run per line. Runs
 * break on a colour change, a y change, or a gap in x -- i.e. exactly where
 * the eye sees a separate piece of text. */
static void ov_render_text(char* out, int cap) {
    int n = 0, i;
    float lastX = -1e9f, lastY = -1e9f;
    uint32_t lastCol = 0;
    out[0] = 0;
    for (i = 0; i + 5 < g_ov.vtxCount; i += 6) {
        const AowlOvVert* v = &g_ov.vtx[i];
        int idx, cell;
        char c;
        if (v[0].u == v[1].u) continue;             /* a solid rect, not text */
        cell = (int)(v[0].u * (float)AOWL_OV_ATW / (float)AOWL_OV_CW + 0.5f);
        idx  = cell + 16 * (int)(v[0].v * (float)AOWL_OV_ATH / (float)AOWL_OV_CH + 0.5f);
        if (idx < 0 || idx > 94) continue;
        c = (char)(idx + 32);
        if (v[0].col != lastCol || v[0].y != lastY ||
            v[0].x < lastX - 0.5f || v[0].x > lastX + 0.5f) {
            if (n > 0 && n < cap - 1) out[n++] = '\n';
        }
        if (n < cap - 1) out[n++] = c;
        lastCol = v[0].col; lastY = v[0].y;
        lastX = v[0].x + (float)AOWL_OV_CW * (float)(g_ov.scale > 0 ? g_ov.scale : 1);
    }
    out[n] = 0;
}

/* Is `want` a WHOLE rendered run? Whole, not a substring of the frame, so
 * `mods` cannot be satisfied by the word inside some sentence elsewhere. */
static int ov_has_run(const char* txt, const char* want) {
    const char* p = txt;
    size_t w = strlen(want);
    while (*p) {
        const char* e = strchr(p, '\n');
        size_t len = e ? (size_t)(e - p) : strlen(p);
        if (len == w && memcmp(p, want, w) == 0) return 1;
        if (!e) break;
        p = e + 1;
    }
    return 0;
}

/* Does the word `want` appear ANYWHERE in what was drawn? Used only for the
 * negative. */
static int ov_has_word(const char* txt, const char* want) {
    return strstr(txt, want) != NULL;
}

/* ------------------------------------------------------------------ *
 * The badge-collision detector.
 *
 * Every glyph quad in the frame, decoded to (char, x, y, width). A "badge run"
 * is a horizontal sequence of glyphs on one scanline spelling `want`. A
 * COLLISION is any glyph outside that run, on the same scanline, whose x-span
 * overlaps it -- i.e. the thing the eye reads as "the SAVING text is invisible
 * / overlaps with other stuff".
 *
 * Adjacency is not overlap: consecutive glyphs in a run touch exactly at
 * x + cw, so the test uses a strict interior overlap with a half-unit slack.
 * ------------------------------------------------------------------ */
#define OV_MAX_GLYPHS 8192
typedef struct { float x, y, w; char c; } OvGlyph;

static int ov_glyphs(OvGlyph* g, int cap) {
    int n = 0, i;
    float cw = (float)AOWL_OV_CW * (float)(g_ov.scale > 0 ? g_ov.scale : 1);
    for (i = 0; i + 5 < g_ov.vtxCount && n < cap; i += 6) {
        const AowlOvVert* v = &g_ov.vtx[i];
        int idx, cell;
        if (v[0].u == v[1].u) continue;             /* a solid rect, not text */
        cell = (int)(v[0].u * (float)AOWL_OV_ATW / (float)AOWL_OV_CW + 0.5f);
        idx  = cell + 16 * (int)(v[0].v * (float)AOWL_OV_ATH / (float)AOWL_OV_CH + 0.5f);
        if (idx < 0 || idx > 94) continue;
        g[n].c = (char)(idx + 32);
        g[n].x = v[0].x;
        g[n].y = v[0].y;
        g[n].w = cw;
        n++;
    }
    return n;
}

/* Index of the first glyph of the `nth` run spelling `want`, or -1. */
static int ov_badge_at(const OvGlyph* g, int n, const char* want, int nth) {
    int i, k;
    int len = (int)strlen(want);
    int seen = 0;
    for (i = 0; i + len <= n; i++) {
        for (k = 0; k < len; k++) {
            if (g[i + k].c != want[k]) break;
            if (g[i + k].y != g[i].y) break;
            if (k > 0 && g[i + k].x < g[i + k - 1].x + g[i].w - 0.5f) break;
            if (k > 0 && g[i + k].x > g[i + k - 1].x + g[i].w + 0.5f) break;
        }
        if (k == len) {
            if (seen == nth) return i;
            seen++;
            i += len - 1;
        }
    }
    return -1;
}

static int ov_badge_runs(const char* want) {
    static OvGlyph g[OV_MAX_GLYPHS];
    int n = ov_glyphs(g, OV_MAX_GLYPHS);
    int c = 0;
    while (ov_badge_at(g, n, want, c) >= 0) c++;
    return c;
}

static int ov_badge_origin(const char* want, int* ox, int* oy) {
    static OvGlyph g[OV_MAX_GLYPHS];
    int n = ov_glyphs(g, OV_MAX_GLYPHS);
    int a = ov_badge_at(g, n, want, 0);
    if (a < 0) return 0;
    *ox = (int)g[a].x; *oy = (int)g[a].y;
    return 1;
}

static int ov_badge_collisions(const char* want) {
    static OvGlyph g[OV_MAX_GLYPHS];
    int n = ov_glyphs(g, OV_MAX_GLYPHS);
    int len = (int)strlen(want);
    int hits = 0, run = 0, a, j;
    while ((a = ov_badge_at(g, n, want, run)) >= 0) {
        float x0 = g[a].x;
        float x1 = g[a + len - 1].x + g[a].w;
        for (j = 0; j < n; j++) {
            if (j >= a && j < a + len) continue;
            if (g[j].y != g[a].y) continue;
            if (g[j].x + g[j].w <= x0 + 0.5f) continue;
            if (g[j].x >= x1 - 0.5f) continue;
            hits++;
        }
        run++;
    }
    return hits;
}

/* A wide 1px-tall rule inside the nav column -- the ROOT BORDER that used to
 * be drawn above every top-level row. The negative for it. The nav`s vertical
 * divider is the same colour but is 1 unit WIDE and hundreds tall, so it
 * cannot be confused for one. */
static int ov_count_nav_hairlines(void) {
    int i, found = 0;
    float k = (float)(g_ov.scale > 0 ? g_ov.scale : 1);
    float navW = (float)((g_ov.navW >= 140 && g_ov.navW <= 640) ? g_ov.navW : 256);
    for (i = 0; i + 5 < g_ov.vtxCount; i += 6) {
        const AowlOvVert* v = &g_ov.vtx[i];
        float w, h;
        if (v[0].u != v[1].u) continue;             /* text, not a rect */
        if (v[0].col != AOWL_OV_EDGE) continue;
        w = v[4].x - v[0].x;
        h = v[4].y - v[0].y;
        /* SCOPED TO THE NAV COLUMN, or this counts the panel's own header and
         * footer rules (940 wide) and the right pane's row separators (652
         * wide, and 276 units to the right) and reports a border that is not
         * there. Measured from the dump: those are the only wide EDGE rules in
         * a settings frame. The root hairline was drawn at panX + 1 and was
         * `leftW + PAD` wide, so both bounds are needed. */
        if (v[0].x > (g_ov.panX + 2.0f) * k) continue;
        if (w > 100.0f * k && w <= ((float)navW + (float)AOWL_OV_PAD + 8.0f) * k
            && h <= 1.5f * k) found++;
    }
    return found;
}

/* A page nav with more rows than fit, and a control list with more rows than
 * fit -- both lists have to be scrollable for the routing question to mean
 * anything. */
static void stage(void) {
    int i;
    g_ov.sPageCount = 40;
    for (i = 0; i < 40; i++) {
        _snprintf(g_ov.sPages[i].id, sizeof(g_ov.sPages[i].id) - 1, "p%d", i);
        _snprintf(g_ov.sPages[i].label, sizeof(g_ov.sPages[i].label) - 1, "page %d", i);
        g_ov.sPages[i].isMod = 1;
        g_ov.pageOpen[i] = 0;
    }
    g_ov.sItemCount = 200;
    for (i = 0; i < 200; i++) {
        _snprintf(g_ov.sItems[i].key, sizeof(g_ov.sItems[i].key) - 1, "k%d", i);
        _snprintf(g_ov.sItems[i].label, sizeof(g_ov.sItems[i].label) - 1, "item %d", i);
        _snprintf(g_ov.sItems[i].value, sizeof(g_ov.sItems[i].value) - 1, "0");
        g_ov.sItems[i].kind = AOWL_S_INT;
        g_ov.sItems[i].implemented = 1;
        g_ov.sItems[i].depth = 0;
    }
    aowl_ov_copy(g_ov.sItemsPage, (int32_t)sizeof(g_ov.sItemsPage), "p0");
    aowl_ov_copy(g_ov.curPage, (int32_t)sizeof(g_ov.curPage), "p0");
    g_ov.curPageIsMod = 1;
    g_ov.sItemsErr = 0;
    g_ov.sCatCount = 0;
    g_ov.selPage = 0; g_ov.topPage = 0;
    g_ov.selItem = 100; g_ov.topItem = 90;
    g_ov.selCat = -1;
    g_ov.navFree = 0;
    g_ov.settings = 1;
    g_ov.searchFocus = 0;
    g_ov.editItem = -1;
}

/* One frame with `notches` waiting and the cursor at panel-x `px`. */
static void frame_wheel(float px, int notches) {
    InterlockedExchange(&g_ov.mx, (LONG)(px * (float)(g_ov.scale > 0 ? g_ov.scale : 1)));
    InterlockedExchange(&g_ov.my, (LONG)((g_ov.panY + 200.0f) *
                                         (float)(g_ov.scale > 0 ? g_ov.scale : 1)));
    InterlockedExchange(&g_ov.wheel, (LONG)notches);
    g_ov.drawSig = 0;
    aowl_ov_build();
}

static void key(int vk) {
    aowl_ov_push_key(vk);
    g_ov.drawSig = 0;
    aowl_ov_build();
}

int main(void) {
    float navX, listX;
    InitializeCriticalSection(&g_ov.cs);
    g_ov.bbW = 1920; g_ov.bbH = 1080;
    g_ov.scalePref = 1;
    aowl_ov_prefs_default();
    InterlockedExchange(&g_ov.visible, 1);
    stage();
    aowl_ov_build();                       /* settle the geometry */

    /* Panel-unit x of a point clearly inside each column. `navW` is the nav's
     * width and the divider sits just past it. */
    navX  = g_ov.panX + (float)AOWL_OV_PAD + 4.0f;
    listX = g_ov.panX + (float)AOWL_OV_PAD +
            (float)((g_ov.navW >= 140 && g_ov.navW <= 640) ? g_ov.navW : 256) +
            40.0f;

    printf("-- the wheel belongs to the list under the cursor --\n");
    {
        int32_t p0, i0;
        stage(); aowl_ov_build();
        p0 = g_ov.topPage; i0 = g_ov.topItem;
        frame_wheel(navX, -1);              /* wheel DOWN over the nav */
        eq_int("over the nav, the nav scrolled", g_ov.topPage > p0, 1);
        eq_int("over the nav, the control list did NOT scroll", g_ov.topItem, i0);

        stage(); aowl_ov_build();
        p0 = g_ov.topPage; i0 = g_ov.topItem;
        frame_wheel(listX, -1);             /* wheel DOWN over the controls */
        eq_int("over the controls, the control list scrolled", g_ov.topItem > i0, 1);
        eq_int("over the controls, the nav did NOT scroll", g_ov.topPage, p0);
        /* THE DEFECT ITSELF. The routing was already right; what was wrong was
         * that this side moved the SELECTION and left the follow-clamp to
         * decide whether the view moved at all -- so with the cursor mid-list
         * the first notches did nothing on screen while the nav, which has
         * always free-scrolled, answered instantly. A free scroll must move
         * the view WITHOUT dragging the selection, and that is a negative:
         * "scroll everything" cannot pass it. */
        eq_int("a free scroll does NOT drag the selection with it",
               g_ov.selItem, 100);

        /* The divider itself: one pixel left of it is nav, one right is list. */
        stage(); aowl_ov_build();
        p0 = g_ov.topPage;
        frame_wheel(listX - 41.0f, -1);     /* just inside the nav */
        eq_int("a notch one pixel inside the divider is the nav's",
               g_ov.topPage > p0, 1);
    }

    printf("-- TAB moves focus, and the unfocused side is inert --\n");
    {
        int32_t i0, p0;
        stage(); aowl_ov_build();
        eq_int("focus starts on the control list", g_ov.navFocus, 0);
        i0 = g_ov.selItem; p0 = g_ov.selPage;
        key(VK_DOWN);
        eq_int("with the list focused, DOWN steps the control cursor",
               g_ov.selItem, i0 + 1);
        eq_int("with the list focused, DOWN does NOT move the nav",
               g_ov.selPage, p0);

        key(VK_TAB);
        eq_int("TAB moves focus to the nav", g_ov.navFocus, 1);
        i0 = g_ov.selItem; p0 = g_ov.selPage;
        key(VK_DOWN);
        eq_int("with the nav focused, DOWN moves the nav", g_ov.selPage, p0 + 1);
        eq_int("with the nav focused, DOWN does NOT step the control cursor",
               g_ov.selItem == i0 + 1, 0);

        key(VK_TAB);
        eq_int("TAB moves focus back to the list", g_ov.navFocus, 0);
        p0 = g_ov.selPage; i0 = g_ov.selItem;
        key(VK_DOWN);
        eq_int("back on the list, DOWN steps the control cursor again",
               g_ov.selItem, i0 + 1);
        eq_int("back on the list, the nav is inert again", g_ov.selPage, p0);

        /* RETURN is the other way off the nav. */
        key(VK_TAB);
        key(VK_RETURN);
        eq_int("RETURN steps out of the nav and back onto the controls",
               g_ov.navFocus, 0);
    }

    printf("-- the nav column names what it lists, and does not fence it --\n");
    {
        static char txt[65536];
        int hair;

        stage();
        g_ov.drawSig = 0;
        aowl_ov_build();
        ov_render_text(txt, (int)sizeof(txt));

        /* POSITIVE: the caption over the nav column, read back off the quads
         * that were emitted for it. */
        eq_int("the nav column header renders as `mods`",
               ov_has_run(txt, "mods"), 1);
        /* NEGATIVE, and this is the one that can fail: the old caption must
         * not be anywhere in the frame. Restoring the word in any of the
         * three places it used to live fails here. */
        eq_int("the word `pages` renders NOWHERE in a settings frame",
               ov_has_word(txt, "pages"), 0);

        /* ROOT BORDER GONE, asserted on geometry rather than on the absence
         * of a line of source: no wide 1px rule is drawn. The hairline this
         * replaces was `leftW + PAD` wide and 1 tall. */
        hair = ov_count_nav_hairlines();
        eq_int("no root row is fenced by a hairline", hair, 0);
        /* AND THE DETECTOR CAN SAY YES. A counter scoped until it matches
         * nothing would pass this file forever; so draw the exact rule that
         * was removed -- panX + 1, `leftW + PAD` wide, 1 tall, EDGE -- and
         * require it to be seen. This is the input that makes the check
         * above fail (CLAUDE.md 9b). */
        aowl_ov_rect(g_ov.panX + 1.0f,
                     g_ov.panY + (float)AOWL_OV_HEAD_H + (float)AOWL_OV_LINE_H,
                     (float)((g_ov.navW >= 140 && g_ov.navW <= 640)
                               ? g_ov.navW : 256) + (float)AOWL_OV_PAD,
                     1.0f, AOWL_OV_EDGE);
        eq_int("...and the hairline detector DOES see one when it is drawn",
               ov_count_nav_hairlines(), 1);

        /* THE EMPTY STATE says it too. It only draws with no pages at all, so
         * it is staged on purpose -- otherwise the rename is untested exactly
         * where the old word survived longest. */
        stage();
        g_ov.sPageCount = 0;
        g_ov.sCatCount = 0;
        g_ov.backendPort = 0;
        g_ov.sIdxWhy[0] = 0;
        g_ov.drawSig = 0;
        aowl_ov_build();
        ov_render_text(txt, (int)sizeof(txt));
        eq_int("the empty nav says `no mods`, not `no pages`",
               ov_has_word(txt, "no mods") && !ov_has_word(txt, "no pages"), 1);

        stage();
        aowl_ov_build();
    }

    printf("-- the SAVING badge is legible at every width --\n");
    {
        /* THE USER'S REPORT: "the SAVING text is invisible/overlaps with other
         * stuff". It was drawn right-aligned at the ROW's right edge, which is
         * inside the control column -- and every control is drawn AFTER it, so
         * the value box painted over it.
         *
         * The assertion is on the FINISHED VERTEX BUFFER, not on the constant
         * that positions the badge: find the glyphs that spell SAVING, and
         * require that NO other glyph in the frame shares their scanline and
         * overlaps them horizontally. That is a negative, it is checked at
         * four panel widths, and the falsifiability proof below draws one
         * colliding glyph and requires the detector to see it. */
        static const int widths[4] = { 1280, 1600, 1920, 2560 };
        int w, i;
        for (w = 0; w < 4; w++) {
            int over;
            stage();
            /* Long labels, so the label column is the crowded one -- if the
             * badge is going to collide with anything, it is here. */
            for (i = 0; i < 200; i++) {
                _snprintf(g_ov.sItems[i].label, sizeof(g_ov.sItems[i].label) - 1,
                          "a deliberately long setting label %d", i);
                g_ov.sItems[i].pend = (i % 3 == 0) ? AOWL_OV_PEND_SAVING
                                                   : AOWL_OV_PEND_NONE;
                /* A RANGED row with a WIDE value, deliberately: that is the
                 * shape whose value box reaches the row's right inner edge,
                 * which is where the badge used to be drawn. Staged with the
                 * narrow plus/minus control instead, the frame has nothing out
                 * there and the old, broken position would pass this test --
                 * a check that cannot fail (CLAUDE.md 9b). The revert proof at
                 * the end of this block is what verified that. */
                g_ov.sItems[i].kind = AOWL_S_FLOAT;
                g_ov.sItems[i].hasRange = 1;
                g_ov.sItems[i].lo = -99999.0f;
                g_ov.sItems[i].hi = 99999.0f;
                g_ov.sItems[i].step = 1.0f;
                aowl_ov_copy(g_ov.sItems[i].value,
                             (int32_t)sizeof(g_ov.sItems[i].value), "-98765");
                aowl_ov_copy(g_ov.sItems[i].raw,
                             (int32_t)sizeof(g_ov.sItems[i].raw), "-98765");
            }
            g_ov.bbW = widths[w];
            g_ov.drawSig = 0;
            aowl_ov_build();
            over = ov_badge_collisions("SAVING");
            printf("      bbW=%4d  SAVING runs drawn: %d\n",
                   widths[w], ov_badge_runs("SAVING"));
            eq_int("at least one SAVING badge was actually drawn",
                   ov_badge_runs("SAVING") > 0, 1);
            eq_int("no glyph overlaps the SAVING badge at this width", over, 0);
        }
        /* THE INPUT THAT MAKES IT FAIL. Put a single glyph on top of a badge --
         * which is exactly what the old right-edge position did once the value
         * box was drawn -- and require the detector to report it. A collision
         * counter that can only ever return 0 would pass this file forever. */
        {
            int bx, by;
            if (ov_badge_origin("SAVING", &bx, &by)) {
                aowl_ov_text((float)bx / (float)(g_ov.scale > 0 ? g_ov.scale : 1)
                                 + 1.0f,
                             (float)by / (float)(g_ov.scale > 0 ? g_ov.scale : 1),
                             "X", AOWL_OV_ERR);
                eq_int("...and the collision detector DOES see one when drawn",
                       ov_badge_collisions("SAVING") > 0, 1);
            } else {
                printf("error the badge origin could not be located -- "
                       "INCONCLUSIVE, not a pass\n");
                failures++;
            }
        }
        stage();
        g_ov.bbW = 1920;
        aowl_ov_build();
    }

    printf("-- what a settings frame costs --\n");
    {
        LARGE_INTEGER f, a, b;
        double each; int i;
        QueryPerformanceFrequency(&f);
        stage(); aowl_ov_build();
        QueryPerformanceCounter(&a);
        for (i = 0; i < 3000; i++) { g_ov.drawSig = 0; aowl_ov_build(); }
        QueryPerformanceCounter(&b);
        each = (double)(b.QuadPart - a.QuadPart) * 1e9 / ((double)f.QuadPart * 3000.0);
        printf("      SETTINGS rebuild: %8.0f ns/frame\n", each);
        eq_int("a settings rebuild stays under 1 ms", each < 1000000.0, 1);
        aowl_ov_build();                    /* prime the cache */
        QueryPerformanceCounter(&a);
        for (i = 0; i < 3000; i++) aowl_ov_build();
        QueryPerformanceCounter(&b);
        each = (double)(b.QuadPart - a.QuadPart) * 1e9 / ((double)f.QuadPart * 3000.0);
        printf("      SETTINGS cached : %8.0f ns/frame\n", each);
        eq_int("a cached settings frame stays under 20 us", each < 20000.0, 1);
    }

    printf("\n%s -- %d failure(s)\n", failures ? "FAILED" : "PASSED", failures);
    return failures ? 1 : 0;
}
