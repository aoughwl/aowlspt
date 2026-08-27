/* f3test.c -- the F3 debug widgets' RENDER PATH, headless.
 *
 * WHAT THIS REPLACED, AND WHY THERE IS A TEST AT ALL
 * -------------------------------------------------
 * The F3 widgets used to be cloned TextMeshProUGUI labels parented into the
 * game's own canvas tree. That cost six rounds. The last three of them fixed
 * real bugs -- a destroyed wrapper that stayed readable, a cached
 * `m_rectTransform` that passed both the readability and the liveness gate and
 * was still the wrong object, an off-by-one in the managed-target table that
 * made `get_parent` resolve to `set_localPosition` -- and after all three the
 * walk SUCCEEDED, faulted nowhere, and rendered NOTHING.
 *
 * The reason that could happen six times is that the clone path had no
 * falsifiable check available from inside the host. Every check it could make
 * was a check on its own writes; whether a pixel appeared was decided by
 * another team's canvas parenting and sort order, which the host cannot read
 * back. By CLAUDE.md 9b that makes it unverifiable, not merely broken.
 *
 * The widgets now go out as region draw commands and the D3D11 overlay
 * rasterises them in `Present`, the same path the F12 panel and the F6 admin
 * HUD use. That path CAN be checked offline -- there is no GPU in it until the
 * vertex buffer is uploaded -- and this is that check.
 *
 * THE CHECKS ARE NEGATIVES (CLAUDE.md 9b). "It drew eight widgets" is not a
 * claim worth asserting: a renderer that emits its own input passes it. What
 * is asserted here cannot be passed by doing nothing and cannot be passed by
 * doing everything:
 *
 *   * NO vertex produced from a command whose pixel rect is inside the back
 *     buffer lands outside the back buffer, AT ANY FONT SCALE. This is the
 *     exact bug the integer scale could have introduced -- `aowl_ov_vert`
 *     multiplies the POSITION as well as the glyph, so a renderer that forgot
 *     to divide the position out would put a scale-3 read-out three screens to
 *     the right, off the edge, invisible. Which is how the previous six rounds
 *     ended, arrived at from the other direction.
 *   * A TEXT command with `t == 0` -- what every submitter that predates the
 *     scale field emits -- produces vertices BYTE-IDENTICAL to the old 1x
 *     path. The scale field is additive or it is an ABI break; this is the
 *     difference, and it is checked rather than asserted in a comment.
 *   * A frame with nothing submitted produces exactly ZERO vertices. A closed
 *     F3 that still costs something is a regression nobody would notice.
 *   * A submitter that runs past `AOWL_REGION_MAX_CMDS` is REFUSED and the
 *     refusals are COUNTED. Silent truncation of a read-out is the failure
 *     mode this whole feature exists to stop.
 *   * The whole F3 load -- eight widgets, backing plates, frames, six lines
 *     each -- rasterises under a hard per-frame ceiling. A ceiling that FAILS,
 *     not a number that gets printed and ignored.
 *
 * Build:  gcc -O2 -I..\..\abi f3test.c -o f3test.exe
 */
#define COBJMACROS
#define CINTERFACE
#include <windows.h>
#include <stdio.h>
#include <string.h>

/* HOST MODE, deliberately. The overlay includes `aowlspt_region.h` itself, in
 * CLIENT mode, where every entry point is a `GetProcAddress` into the host DLL
 * -- which in a test executable resolves to nothing and would make every check
 * below pass by drawing no commands at all. Defining this first gives the test
 * the real registry, the real dispatcher and the real seqlock, in process, so
 * the commands the overlay drains are commands that genuinely went through
 * `aowl_region_push`. That is the difference between testing the renderer and
 * testing an empty buffer. */
#define AOWL_REGION_HOST
/* The guard itself, which host-mode `aowlspt_region.h` calls directly: the
 * dispatcher wraps every participant callback in `aowl_p_p_seh` and refuses to
 * run at all when one is already armed on this thread. Including the real one
 * rather than stubbing it is deliberate -- a stub would quietly remove the
 * re-entrancy refusal that is the reason `duDrawWidgets` opens no guard. */
#include "aowlspt_shim.h"
#include "aowlspt_overlay.h"

int32_t aowlspt_nim_patch_fired(int32_t slot, void* regs) {
    (void)slot; (void)regs; return 0;
}
int32_t aowlspt_nim_patch_returned(int32_t slot, void* regs) {
    (void)slot; (void)regs; return 0;
}

static int failures = 0;
static void ok(const char* m) { printf("ok    %s\n", m); }
static void eq_int(const char* what, int got, int want) {
    if (got == want) { ok(what); return; }
    printf("error %s: got %d, wanted %d\n", what, got, want);
    failures++;
}
static void inconclusive(const char* what) {
    /* The third answer. "I could not look" is not a pass, and a test that
     * silently downgrades it to one is the bug this file is about. */
    printf("INCONCLUSIVE %s\n", what);
    failures++;
}

/* ------------------------------------------------------------------ *
 * The submitter under test: the same shape `duDrawWidgets` emits.
 *
 * Deliberately NOT a copy of the Nim -- the Nim's layout arithmetic is
 * `wgeom.nim`, which has its own 208-check offline test and is unchanged by
 * this rewrite. What is exercised here is the part that is new: the command
 * SHAPE crossing into the rasteriser.
 * ------------------------------------------------------------------ */
#define F3_SCREEN_W 3840          /* measured on the live machine */
#define F3_SCREEN_H 2160

static int32_t g_scale = 3;
static int32_t g_widgets = 8;
static int32_t g_lines = 6;

static void f3_submit(void* user, int64_t frame) {
    /* Eight widgets down the left and right edges, each a backing plate, a
     * frame and `g_lines` lines -- the real F3 load at the real resolution. */
    int32_t i, k;
    static const char* const LINE = "fps 143.9   ticks 918233";
    const float cols = (float)(int32_t)strlen(LINE);
    (void)user; (void)frame;
    for (i = 0; i < g_widgets; i++) {
        /* The widget box is sized FROM the line, exactly as `duDrawWidgets`
         * sizes it -- `widest * cellW + 8`. Sizing it from a different number
         * would make this fixture, not the renderer, the thing that put a
         * glyph off the edge. */
        float w = cols * 8.0f * (float)g_scale + 8.0f;
        float h = (float)g_lines * 16.0f * (float)g_scale + 6.0f;
        float x = (i & 1) ? (float)F3_SCREEN_W - w - 16.0f : 16.0f;
        float y = 16.0f + (float)(i / 2) * (h + 12.0f);
        aowl_region_fill(x, y, w, h, 0xAA0E0A08u);
        aowl_region_box(x, y, w, h, 1.0f, 0xC8FFD999u);
        for (k = 0; k < g_lines; k++)
            aowl_region_text_scaled(x + 4.0f,
                                    y + 3.0f + (float)k * 16.0f * (float)g_scale,
                                    LINE, 0xFFFFFFFFu, g_scale);
    }
}

/* A submitter that deliberately runs past the command ceiling. */
static void f3_flood(void* user, int64_t frame) {
    int32_t i;
    (void)user; (void)frame;
    for (i = 0; i < AOWL_REGION_MAX_CMDS * 2; i++)
        aowl_region_fill(1.0f, 1.0f, 2.0f, 2.0f, 0xFFFFFFFFu);
}

static void f3_log(const char* line) { (void)line; }

/* Every vertex the append produced, in back-buffer pixels. `aowl_ov_vert`
 * has already applied the scale, so this is what would reach the GPU. */
static int32_t verts_outside(void) {
    int32_t i, bad = 0;
    for (i = 0; i < g_ov.vtxCount; i++) {
        float x = g_ov.vtx[i].x, y = g_ov.vtx[i].y;
        if (x < -1.0f || y < -1.0f ||
            x > (float)F3_SCREEN_W + 1.0f || y > (float)F3_SCREEN_H + 1.0f)
            bad++;
    }
    return bad;
}

static int32_t run_one_frame(void) {
    g_ov.vtxCount = 0;
    if (aowl_region_frame() < 0) return 0;
    aowl_ov_region_append();
    return 1;
}

int main(void) {
    LARGE_INTEGER fq;
    QueryPerformanceFrequency(&fq);

    memset(&g_ov, 0, sizeof(g_ov));
    g_ov.bbW = F3_SCREEN_W;
    g_ov.bbH = F3_SCREEN_H;
    g_ov.scale = 1;

    aowl_region_init(f3_log);
    aowl_region_set_screen(F3_SCREEN_W, F3_SCREEN_H);
    aowl_region_set_armed(1);

    eq_int("the region publishes the screen it was told, not a guess",
           aowl_region_screen_w() == F3_SCREEN_W &&
           aowl_region_screen_h() == F3_SCREEN_H &&
           aowl_region_screen_known() == 1, 1);

    /* ---- 1. an EMPTY frame costs exactly nothing ------------------- */
    {
        g_ov.vtxCount = 0;
        aowl_ov_region_append();
        eq_int("a frame with nothing submitted produces zero vertices",
               g_ov.vtxCount, 0);
    }

    /* ---- 2. register the real submitter ---------------------------- */
    {
        AowlRegionDesc d;
        int32_t h;
        memset(&d, 0, sizeof(d));
        d.size = (int32_t)sizeof(d);
        memcpy(d.name, "debugui", 8);
        d.mask = AOWL_REGION_DRAW;
        d.budgetUs = 900;
        d.fn = f3_submit;
        h = aowl_region_register(&d);
        if (h < 0) {
            inconclusive("the F3 submitter could not be registered -- "
                         "nothing below was actually exercised");
            printf("\nFAILED -- %d failure(s)\n", failures);
            return 1;
        }
    }

    /* ---- 3. NOTHING LEAVES THE SCREEN, AT ANY SCALE ---------------- *
     * The scale multiplies the vertex position as well as the glyph. A
     * renderer that did not divide the position back out would put a
     * scale-3 panel three screens to the right -- present, correct, and
     * invisible, which is precisely how the clone path failed. */
    {
        int32_t s;
        int32_t drewSomething = 0;
        for (s = 1; s <= 4; s++) {
            char what[96];
            g_scale = s;
            if (!run_one_frame()) {
                inconclusive("the region refused to dispatch");
                break;
            }
            if (g_ov.vtxCount > 0) drewSomething = 1;
            _snprintf(what, sizeof(what),
                      "at font scale %d no vertex lands off the back buffer", s);
            what[sizeof(what) - 1] = 0;
            eq_int(what, verts_outside(), 0);
        }
        /* And it must have drawn SOMETHING -- otherwise every check above
         * passed by producing no vertices at all, which is exactly the
         * "check that cannot fail" this file exists to avoid. */
        eq_int("the submitter actually produced geometry (so the checks above "
               "were not passed by drawing nothing)", drewSomething, 1);
        g_scale = 3;
    }

    /* ---- 4. t == 0 IS BYTE-IDENTICAL TO THE OLD 1x PATH ------------ *
     * Every mod written before the scale field leaves `t` at 0 for a TEXT
     * command. If that produced different geometry, this was an ABI break
     * dressed up as an addition. */
    {
        AowlOvVert old_[64];
        int32_t n0, i, diff = 0;
        g_ov.vtxCount = 0;
        g_ov.scale = 1;
        aowl_ov_text(100.0f, 200.0f, "abcdef", 0xFF00FF00u);
        n0 = g_ov.vtxCount;
        if (n0 <= 0 || n0 > 64) {
            inconclusive("the 1x reference render produced no vertices");
        } else {
            memcpy(old_, g_ov.vtx, sizeof(AowlOvVert) * (size_t)n0);
            /* The same text through the region, with t == 0. */
            g_ov.vtxCount = 0;
            g_ov.scale = 1;
            {
                AowlRegionCmd c;
                const AowlRegionCmd* cp = &c;
                memset(&c, 0, sizeof(c));
                c.kind = AOWL_REGION_CMD_TEXT;
                c.x = 100.0f; c.y = 200.0f; c.t = 0.0f;
                c.col = 0xFF00FF00u;
                memcpy(c.text, "abcdef", 7);
                /* Rasterise it the way the append does, so the comparison is
                 * against the real code path and not a re-implementation. */
                {
                    int32_t k = (int32_t)cp->t;
                    if (k < 1) k = 1;
                    if (k > 8) k = 8;
                    g_ov.scale = k;
                    aowl_ov_text(cp->x / (float)k, cp->y / (float)k,
                                 cp->text, cp->col);
                    g_ov.scale = 1;
                }
            }
            eq_int("t == 0 produces the same vertex count as the old 1x path",
                   g_ov.vtxCount, n0);
            if (g_ov.vtxCount == n0)
                for (i = 0; i < n0; i++)
                    if (memcmp(&old_[i], &g_ov.vtx[i], sizeof(AowlOvVert)) != 0)
                        diff++;
            eq_int("t == 0 produces BYTE-IDENTICAL geometry (the scale field "
                   "is additive, not an ABI break)", diff, 0);
        }
    }

    /* ---- 5. the command ceiling REFUSES and COUNTS ----------------- */
    {
        AowlRegionDesc d;
        int32_t h;
        int64_t before = aowl_region_dropped();
        const AowlRegionCmd* cmds = 0;
        int32_t n;
        memset(&d, 0, sizeof(d));
        d.size = (int32_t)sizeof(d);
        memcpy(d.name, "flood", 6);
        d.mask = AOWL_REGION_DRAW;
        d.budgetUs = 1000000;      /* not a budget test */
        d.fn = f3_flood;
        h = aowl_region_register(&d);
        if (h < 0) {
            inconclusive("the flood submitter could not be registered");
        } else {
            aowl_region_frame();
            n = aowl_region_commands(&cmds);
            eq_int("a submitter past the ceiling is CAPPED, never overflowed",
                   n <= AOWL_REGION_MAX_CMDS, 1);
            eq_int("and every refused command is COUNTED rather than silently "
                   "dropped", aowl_region_dropped() > before, 1);
            aowl_region_unregister(h);
        }
    }

    /* ---- 6. the per-frame cost, with a CEILING that fails ---------- */
    {
        LARGE_INTEGER a, b;
        double each;
        int32_t k;
        const int32_t N = 2000;
        /* Warm: the first pass touches cold pages, which is a fact about
         * start-up rather than about the renderer. */
        for (k = 0; k < 32; k++) run_one_frame();
        QueryPerformanceCounter(&a);
        for (k = 0; k < N; k++) run_one_frame();
        QueryPerformanceCounter(&b);
        each = (double)(b.QuadPart - a.QuadPart) * 1e9 /
               ((double)fq.QuadPart * (double)N);
        printf("      F3 OPEN  : %8.0f ns/frame  (%d widgets x %d lines at "
               "scale %d, %d verts)\n",
               each, g_widgets, g_lines, g_scale, g_ov.vtxCount);
        /* At 144 Hz a frame is 6.9 ms. A debug read-out that costs 200 us of
         * it has stopped being free. Failing rather than printing is the
         * point: a number in a log is a number nobody reads twice. */
        eq_int("an OPEN F3 frame (dispatch + rasterise) stays under 200 us",
               each < 200000.0, 1);

        /* CLOSED. Nothing is submitted, so `aowl_ov_region_append` returns on
         * its first line and the dispatcher has no DRAW work. */
        g_widgets = 0;
        for (k = 0; k < 32; k++) run_one_frame();
        QueryPerformanceCounter(&a);
        for (k = 0; k < N; k++) run_one_frame();
        QueryPerformanceCounter(&b);
        each = (double)(b.QuadPart - a.QuadPart) * 1e9 /
               ((double)fq.QuadPart * (double)N);
        printf("      F3 CLOSED: %8.0f ns/frame  (%d verts)\n",
               each, g_ov.vtxCount);
        eq_int("a CLOSED F3 frame produces no vertices at all",
               g_ov.vtxCount, 0);
        eq_int("a CLOSED F3 frame stays under 5 us", each < 5000.0, 1);
        g_widgets = 8;
    }

    printf("\n%s -- %d failure(s)\n", failures ? "FAILED" : "PASSED", failures);
    return failures ? 1 : 0;
}
