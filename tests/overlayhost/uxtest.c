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
