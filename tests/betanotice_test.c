/* betanotice_test.c -- the MUTATION PROOF for abi/aowlspt_betanotice.h.
 *
 * WHY THIS TEST EXISTS, IN ONE PARAGRAPH
 * --------------------------------------
 * The previous beta notice REPURPOSED the game's seasons banner and its own
 * check reported "6 of 6 non-empty labels written". That was TRUE, and the
 * screen still looked wrong, because the check asserted a property of OUR WRITE
 * instead of a property of the finished thing. So nothing here asserts that a
 * setter was called. Every assertion below reads back the FINISHED PUBLISHED
 * COMMAND BUFFER through the region's own public `aowl_region_commands` -- the
 * exact bytes `aowl_ov_region_append` in the overlay will rasterise -- and most
 * of them are NEGATIVES, because a negative can be falsified.
 *
 *   MUTATION 1  the host says we are IN A RAID.
 *               ASSERT (negative): the notice publishes ZERO commands. Not
 *               "fewer", not "smaller": none. This is the property that says
 *               it cannot appear over a firefight.
 *
 *   MUTATION 2  UnityEngine.Screen::get_width fails to verify (the stub returns
 *               NULL, exactly as `aowl_mi2_fn` does on an uncommitted page or a
 *               prologue mismatch).
 *               ASSERT (negative): ZERO commands, and a REFUSAL in the log --
 *               said ONCE, not every frame. The failure mode this forbids is
 *               inventing a resolution and drawing the notice in a
 *               plausible-looking wrong place, which is the whole reason the
 *               feature moved to the overlay.
 *
 *   MUTATION 3  the resolution changes underneath it (1920x1080 -> 1280x720 ->
 *               2560x1440).
 *               ASSERT: at EVERY one of them the panel lies wholly inside the
 *               back buffer and stays horizontally centred. A fixed pixel
 *               position would pass at one resolution and fail here.
 *
 *   MUTATION 4  a junk / out-of-range `uxBetaOverlayPos`.
 *               ASSERT: REFUSED, and the drawn geometry is BYTE-IDENTICAL to
 *               the default -- i.e. the refusal actually kept the default
 *               rather than half-applying it.
 *
 *   COLOUR      the user rejected the stock banner's GREEN and asked for
 *               yellow. ASSERT the title colour is exactly the overlay's house
 *               warning amber, and -- the falsifiable form -- that its GREEN
 *               channel does not dominate. A test that only compared the
 *               constant to itself would pass on green.
 *
 *   METRICS     AOWL_BETA_CW/CH must equal the overlay's AOWL_OV_CW/CH or the
 *               panel is mis-sized around correctly-drawn glyphs. Rather than
 *               restate 8 and 16 here (a self-comparison), this PARSES
 *               `abi/aowlspt_overlay.h` at run time and compares. If the file
 *               cannot be read the result is INCONCLUSIVE, never a pass.
 *
 *   CONTROL     the ordinary case: in the menu, resolution known. ASSERT it
 *               publishes exactly 2 FILL + 2 TEXT with the exact strings. This
 *               is the run that FAILS if any check above is a check that cannot
 *               fail -- if the participant simply never drew, MUTATION 1 and 2
 *               would both "pass" and this would not.
 *
 * Build:
 *   gcc -I abi -O1 -o tests/betanotice_test.exe tests/betanotice_test.c
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <windows.h>

#include "aowlspt_shim.h"     /* aowl_p_p_seh, aowl_seh_active */
#define AOWL_REGION_HOST
#include "aowlspt_region.h"

/* ------------------------------------------------------------------ *
 * THE INVOKE2 STAND-IN.
 *
 * `aowlspt_betanotice.h` reaches the back-buffer size through four functions
 * of `abi/aowlspt_invoke2.h`. That header needs a live GameAssembly.dll, which
 * a unit test does not have, so the four are provided here with the SAME
 * CONTRACT -- in particular `aowl_mi2_fn` returning NULL for "did not verify",
 * which is the branch MUTATION 2 exercises. Nothing else of invoke2 is used.
 * ------------------------------------------------------------------ */
static int32_t g_fakeW = 1920, g_fakeH = 1080;
static int32_t g_fakeVerifies = 1;     /* 0 == prologue mismatch */
static int32_t g_fakeCalls = 0;        /* how often Unity was actually asked */

static const char* const k_fakeNames[] = {
    "UnityEngine.Time::get_frameCount",
    "UnityEngine.Screen::get_width",
    "UnityEngine.Screen::get_height"
};
static int32_t aowl_mi2_target_count(void) { return 3; }
static const char* aowl_mi2_name(int32_t i) {
    return (i >= 0 && i < 3) ? k_fakeNames[i] : "";
}
static void* aowl_mi2_fn(int32_t i) {
    if (i < 0 || i >= 3) return NULL;
    if (!g_fakeVerifies) return NULL;          /* refuses, exactly as the real one */
    return (void*)(size_t)(i + 1);             /* an opaque non-NULL token */
}
static int32_t aowl_mi2_call_i_v(void* fn) {
    g_fakeCalls++;
    if (fn == (void*)(size_t)2) return g_fakeW;
    if (fn == (void*)(size_t)3) return g_fakeH;
    return 0;
}

#include "aowlspt_betanotice.h"

/* ------------------------------------------------------------------ */
static int failures = 0, checks = 0;
static void ok(int cond, const char* what) {
    checks++;
    if (!cond) { failures++; printf("  FAIL  %s\n", what); }
    else       {             printf("  pass  %s\n", what); }
}
static void inconclusive(const char* what) {
    printf("  INCONCLUSIVE  %s\n", what);
    failures++;   /* "I could not look" is not a pass. */
}

#define LOGCAP 128
static char g_log[LOGCAP][400];
static int  g_logN = 0;
static void sink(const char* line) {
    if (g_logN < LOGCAP) {
        strncpy(g_log[g_logN], line, 399);
        g_log[g_logN][399] = 0;
        g_logN++;
    }
}
static int log_count(const char* needle) {
    int i, n = 0;
    for (i = 0; i < g_logN; i++) if (strstr(g_log[i], needle)) n++;
    return n;
}

/* ---- reading back the FINISHED published frame --------------------- */
typedef struct Shot {
    int32_t n, fills, texts, boxes, lines;
    float   px, py, pw, ph;      /* the background fill: the panel itself */
    float   barW;
    uint32_t bgCol, barCol, titleCol, subCol;
    char    title[AOWL_REGION_TEXT_LEN];
    char    sub[AOWL_REGION_TEXT_LEN];
} Shot;

static Shot shoot(void) {
    const AowlRegionCmd* c = 0;
    Shot s;
    int32_t i, seenFill = 0, seenText = 0;
    memset(&s, 0, sizeof(s));
    aowl_region_frame();
    s.n = aowl_region_commands(&c);
    for (i = 0; i < s.n; i++) {
        switch (c[i].kind) {
        case AOWL_REGION_CMD_FILL:
            s.fills++;
            if (seenFill == 0) {
                s.px = c[i].x; s.py = c[i].y;
                s.pw = c[i].w; s.ph = c[i].h; s.bgCol = c[i].col;
            } else if (seenFill == 1) {
                s.barW = c[i].w; s.barCol = c[i].col;
            }
            seenFill++;
            break;
        case AOWL_REGION_CMD_TEXT:
            s.texts++;
            if (seenText == 0) {
                strncpy(s.title, c[i].text, AOWL_REGION_TEXT_LEN - 1);
                s.titleCol = c[i].col;
            } else if (seenText == 1) {
                strncpy(s.sub, c[i].text, AOWL_REGION_TEXT_LEN - 1);
                s.subCol = c[i].col;
            }
            seenText++;
            break;
        case AOWL_REGION_CMD_BOX:  s.boxes++; break;
        case AOWL_REGION_CMD_LINE: s.lines++; break;
        }
    }
    return s;
}

/* Force the next frame to re-ask Unity for the resolution. */
static void forget_resolution(void) {
    int i;
    for (i = 0; i < AOWL_BETA_RES_EVERY + 2; i++) { /* age it out honestly */ }
    g_beta.resAge = AOWL_BETA_RES_EVERY;
}

/* Parse `#define AOWL_OV_CW 8` out of the overlay header, so the glyph metrics
 * are cross-checked against the file that actually rasterises, not against a
 * number retyped here. Returns 0 if it could not be read. */
static int overlay_metric(const char* name, int* out) {
    static const char* paths[] = { "abi/aowlspt_overlay.h",
                                   "../abi/aowlspt_overlay.h",
                                   "aowlspt_overlay.h" };
    char line[512];
    size_t i;
    for (i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
        FILE* f = fopen(paths[i], "r");
        if (!f) continue;
        while (fgets(line, sizeof(line), f)) {
            char* p = strstr(line, "#define ");
            char* q;
            if (!p) continue;
            p += 8;
            while (*p == ' ' || *p == '\t') p++;
            if (strncmp(p, name, strlen(name)) != 0) continue;
            q = p + strlen(name);
            if (*q != ' ' && *q != '\t') continue;
            *out = atoi(q);
            fclose(f);
            return 1;
        }
        fclose(f);
    }
    return 0;
}

int main(void) {
    Shot s, dflt;
    int32_t h;
    int cw = 0, ch = 0;

    aowl_region_init(sink);
    aowl_beta_set_sink(sink);
    aowl_region_set_armed(1);
    h = aowl_beta_register();
    ok(h >= 0, "the notice registers with the shared region");
    if (h < 0) { printf("\ncannot continue\n"); return 1; }

    printf("\nCONTROL -- in the menu, resolution known\n");
    aowl_beta_set_menu(1);
    s = shoot();
    dflt = s;
    ok(s.fills == 2 && s.texts == 2,
       "publishes exactly 2 fills + 2 texts");
    ok(s.boxes == 0 && s.lines == 0,
       "publishes NO box and NO line -- it is a band, not a widget");
    ok(strcmp(s.title, AOWL_BETA_LINE1) == 0,
       "the title command carries exactly the AOWL_BETA_LINE1 text");
    ok(strcmp(s.sub, AOWL_BETA_LINE2) == 0,
       "the subline carries exactly the AOWL_BETA_LINE2 text");
    ok(strstr(AOWL_BETA_LINE2, "aoughwl.com") != 0 &&
       strstr(AOWL_BETA_LINE2, "F12") != 0,
       "the subline names aoughwl.com AND F12, which is what was asked for");
    ok((int)strlen(AOWL_BETA_LINE2) < AOWL_REGION_TEXT_LEN,
       "the subline fits the region's inline text field UNTRUNCATED "
       "(the region truncates at " "64" " and a half-URL is worse than none)");

    printf("\nCOLOUR -- yellow, and provably not green\n");
    ok(s.titleCol == AOWL_BETA_RGBA(226, 170, 80, 255),
       "the title is the overlay's house warning amber RGBA(226,170,80)");
    {
        uint32_t c = s.titleCol;
        uint32_t r = c & 0xFF, g = (c >> 8) & 0xFF, b = (c >> 16) & 0xFF;
        ok(r >= g && g > b,
           "R >= G > B -- a warm yellow. This is the check that FAILS on the "
           "stock seasons green the user rejected");
        ok(b < 128, "the blue channel is low: not the accent blue either");
        ok(s.barCol == s.titleCol,
           "the 3 px house accent bar is the same amber as the title");
        ok(s.subCol != s.titleCol,
           "the subline is dimmed relative to the title, per the house style");
    }

    printf("\nMETRICS -- against the overlay's own constants\n");
    if (overlay_metric("AOWL_OV_CW", &cw) && overlay_metric("AOWL_OV_CH", &ch)) {
        ok(cw == AOWL_BETA_CW && ch == AOWL_BETA_CH,
           "AOWL_BETA_CW/CH match the overlay's AOWL_OV_CW/CH");
        {
            int cols = (int)strlen(AOWL_BETA_LINE2);
            float want = (float)(cols * cw + AOWL_BETA_PAD * 2 + AOWL_BETA_BAR);
            ok(s.pw == want,
               "the band is exactly as wide as the longest line needs -- "
               "no clipped URL, no empty gutter");
        }
    } else {
        inconclusive("could not read abi/aowlspt_overlay.h to cross-check "
                     "the glyph metrics -- run this from the repo root");
    }

    printf("\nMUTATION 1 -- in a raid\n");
    aowl_beta_set_menu(0);
    s = shoot();
    ok(s.n == 0, "publishes ZERO commands in a raid");
    s = shoot();
    ok(s.n == 0, "still zero on the next frame (not a one-frame fluke)");
    aowl_beta_set_menu(1);
    s = shoot();
    ok(s.n == 4, "and it comes back on returning to the menu -- so the raid "
                 "gate is a gate, not a permanent self-disable");

    printf("\nMUTATION 3 -- the resolution changes underneath it\n");
    {
        int32_t res[3][2] = { {1920,1080}, {1280,720}, {2560,1440} };
        int i;
        for (i = 0; i < 3; i++) {
            char what[160];
            g_fakeW = res[i][0]; g_fakeH = res[i][1];
            forget_resolution();
            s = shoot();
            sprintf(what, "%dx%d: the panel lies wholly inside the back buffer",
                    res[i][0], res[i][1]);
            ok(s.n == 4 && s.px >= 0.0f && s.py >= 0.0f &&
               s.px + s.pw <= (float)res[i][0] &&
               s.py + s.ph <= (float)res[i][1], what);
            sprintf(what, "%dx%d: and stays horizontally centred (+-1 px)",
                    res[i][0], res[i][1]);
            {
                float mid = s.px + s.pw * 0.5f;
                float want = (float)res[i][0] * 0.5f;
                ok(mid > want - 1.0f && mid < want + 1.0f, what);
            }
            sprintf(what, "%dx%d: and sits in the upper part of the screen, "
                          "where the seasons banner was (above Play)",
                    res[i][0], res[i][1]);
            ok(s.py + s.ph < (float)res[i][1] * 0.5f, what);
        }
        g_fakeW = 1920; g_fakeH = 1080;
        forget_resolution();
        s = shoot();
    }

    printf("\nMUTATION 2 -- Screen::get_width does not verify\n");
    {
        int before = log_count("REFUSED"), after1, after2;
        g_fakeVerifies = 0;
        g_beta.scrW = 0; g_beta.scrH = 0; g_beta.resAge = 0;
        g_beta.resFail = 0; g_beta.saidNoRes = 0;
        s = shoot();
        ok(s.n == 0,
           "publishes ZERO commands when the back-buffer size is UNKNOWN -- "
           "it does not invent a resolution");
        after1 = log_count("REFUSED");
        ok(after1 == before + 1, "and says REFUSED, naming the reason");
        {
            int i;
            for (i = 0; i < 200; i++) (void)shoot();
        }
        after2 = log_count("REFUSED");
        ok(after2 == after1,
           "and says it ONCE, not once per frame -- 200 further frames added "
           "no log lines");
        {
            int callsBefore = g_fakeCalls, i;
            for (i = 0; i < 200; i++) (void)shoot();
            ok(g_fakeCalls - callsBefore <= AOWL_BETA_RES_GIVEUP,
               "and it STOPS asking the runtime after "
               "AOWL_BETA_RES_GIVEUP refusals rather than calling into it "
               "every frame forever");
        }
        g_fakeVerifies = 1;
        g_beta.resFail = 0; g_beta.resAge = AOWL_BETA_RES_EVERY;
        s = shoot();
        ok(s.n == 4, "and it recovers once the getters verify again");
    }

    printf("\nMUTATION 4 -- a junk uxBetaOverlayPos\n");
    {
        const char* junk[] = { "", "yes", "9,9", "-1,0.5", "0.5", "0.5,2.0" };
        size_t i;
        int allRefused = 1;
        for (i = 0; i < sizeof(junk) / sizeof(junk[0]); i++)
            if (aowl_beta_set_pos_str(junk[i]) != 0) allRefused = 0;
        ok(allRefused, "every out-of-range or unparseable position is REFUSED");
        forget_resolution();
        s = shoot();
        ok(s.px == dflt.px && s.py == dflt.py &&
           s.pw == dflt.pw && s.ph == dflt.ph,
           "and the geometry is byte-identical to the default -- the refusal "
           "KEPT the default rather than half-applying the junk");
        ok(aowl_beta_set_pos_str("0.25, 0.30") != 0,
           "a well-formed position is accepted");
        forget_resolution();
        s = shoot();
        ok(s.px != dflt.px && s.py != dflt.py,
           "and it actually MOVES the panel -- so the accept path is not a "
           "no-op that would make the refusal test meaningless");
        (void)aowl_beta_set_pos(0.5f, 0.11f);
    }

    printf("\nTHE PARTICIPANT'S OWN FINISHED STATE\n");
    {
        AowlRegionStatus st;
        memset(&st, 0, sizeof(st));
        st.size = (int32_t)sizeof(st);
        if (aowl_region_status(h, &st) == AOWL_REGION_OK) {
            ok(st.faults == 0, "zero faults across every frame above");
            ok(!st.disabled, "the region has not disabled it");
            ok(!st.throttled, "and has not throttled it -- it is inside its "
                              "declared budget");
            ok(st.calls > 0, "and it was actually called (so the zeros above "
                             "are gates, not a participant that never ran)");
        } else {
            inconclusive("aowl_region_status refused");
        }
    }

    printf("\n%d checks, %d failure(s)\n", checks, failures);
    if (failures) {
        printf("BETA NOTICE TEST FAILED\n");
        return 1;
    }
    printf("BETA NOTICE TEST PASSED\n");
    return 0;
}
