/* A FALSIFIABILITY HARNESS FOR THE F12 WRITE-ACKNOWLEDGEMENT VERDICT.
 *
 * The banner that says APPLIED / NOT APPLIED / INCONCLUSIVE was, until this
 * file existed, unfalsifiable in practice: the only way to see which verdict
 * it produced was to deploy, launch the client, get into the menu and edit a
 * row by hand -- so a verdict that was WRONG in one direction (it reported NOT
 * APPLIED for an edit the host log recorded as applied) survived.
 *
 * The functions under test are not re-implemented here. They are SLICED, byte
 * for byte, out of `abi/aowlspt_overlay.h` by `tools/gen_test_settings_ack.py`
 * into `test_settings_ack.gen.h`, together with the real JSON reader and the
 * real formatter, so what runs here is what ships. Only the two things that
 * touch the outside world are replaced: `aowl_ov_fetch` (the backend) and
 * `aowl_ov_settings_load` (the page re-read). Those are driven by a scripted
 * fake pipeline whose timing mirrors the MEASURED one.
 *
 * Five cases, and the suite fails if any verdict is merely "not wrong":
 * each case asserts the exact outcome CLASS, and the two that matter most are
 * the pair that proves the check can go both ways.
 *
 * Build (PowerShell):
 *   gcc -O1 -Wall -o tools\test_settings_ack.exe tools\test_settings_ack.c
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <stdint.h>
#include <wchar.h>

/* ---- the outside world, replaced ---------------------------------------- */

static int32_t g_sleeps = 0;
#define Sleep(ms) (g_sleeps++)

#define AOWL_OV_MAX_SITEMS 256

typedef struct { char key[64]; char raw[64]; } AowlOvSItem;

static struct {
    AowlOvSItem items[AOWL_OV_MAX_SITEMS];
    int32_t     itemCount;
    char        writeWhy[512];
} g_ov;

static void aowl_ov_note(const char* what) { (void)what; }

/* Forward declarations for the two seams. Their definitions -- the scripted
 * fake pipeline -- are below the sliced code, because that code is what they
 * exist to drive. */
static void aowl_ov_settings_load(const char* guid, int32_t isMod,
                                  char* buf, int32_t cap);
static int32_t aowl_ov_fetch(const wchar_t* verb, const wchar_t* path,
                             const char* body, char* buf, int32_t cap);
/* The write leg the verify wait now pumps. Counted, not modelled: whether
 * pumping it keeps the pipeline moving is `tools/test_settings_push.c`'s
 * question, and this file's scenarios drive `pushes` directly. */
static int32_t g_pumps = 0;
static void aowl_ov_pump_post(void) { g_pumps++; }

/* ---- the sliced-in production code -------------------------------------- */

#include "test_settings_ack.gen.h"

/* ---- the scripted pipeline ---------------------------------------------- */
/*
 * `gPushes` is how many times the owning mod has republished its page.
 * `gApplyAtPush` is the push on which the new value first becomes visible --
 * MEASURED to be push 2, not push 1, because `sbCollect()` snapshots the rows
 * before the sync that drains the edit. `gDrainAtPush` is when the edit leaves
 * settingshub's queue. A scenario sets these and nothing else.
 */
typedef struct {
    const char* name;
    int32_t hasStatusRoute;   /* 0 = an older backend with no client/status */
    int32_t known;            /* 0 = server-side page (authoritative at once) */
    int32_t drainAtPoll;      /* -1 = never drains (bridge stalled) */
    int32_t applyAtPoll;      /* -1 = never applies (the mod refused it) */
    const char* oldValue;
    const char* newValue;
} Scenario;

static Scenario gS;
static int32_t  gPushes;      /* advances one per re-read, i.e. ~800 ms */
static int32_t  gFetches;
static int32_t  gLoads;

/* HOW FAST THE FAKE PIPELINE RUNS, and it is not a round number by accident.
 *
 * One re-read is one poll, `AOWL_OV_VERIFY_WAIT` = 800 ms apart. The client
 * republishes a client-side page once per settings-bridge cycle, MEASURED at
 * 7.3 s from `aowlspt-host.log` (the `applied an F12 edit` lines at 0:03:46.282,
 * 0:03:53.563, 0:04:00.875 -- 7.28 s apart, against the nominal
 * `cSbPeriodMs = 5000` plus the push). 7300 / 800 = 9 polls per republish.
 *
 * That number is the whole bug: the value first appears on republish 2, i.e.
 * poll ~18, and the OLD check gave up at poll 10. `main` asserts that
 * explicitly, so this harness would notice if anyone tuned the budget back
 * down. */
#define POLLS_PER_REPUBLISH 9

static void aowl_ov_settings_load(const char* guid, int32_t isMod,
                                  char* buf, int32_t cap) {
    (void)guid; (void)isMod; (void)buf; (void)cap;
    gLoads++;
    gPushes = gS.known ? (gLoads / POLLS_PER_REPUBLISH) : gLoads;
    g_ov.itemCount = 1;
    strcpy(g_ov.items[0].key, "opticFovMulti");
    if (gS.applyAtPoll >= 0 && gLoads >= gS.applyAtPoll)
        strcpy(g_ov.items[0].raw, gS.newValue);
    else
        strcpy(g_ov.items[0].raw, gS.oldValue);
}

static int32_t aowl_ov_fetch(const wchar_t* verb, const wchar_t* path,
                             const char* body, char* buf, int32_t cap) {
    int32_t pending;
    (void)verb; (void)path; (void)body;
    gFetches++;
    if (!gS.hasStatusRoute) return 0;             /* nobody answered */
    pending = (gS.drainAtPoll < 0 || gLoads < gS.drainAtPoll) ? 1 : 0;
    if (!gS.known) pending = 0;
    snprintf(buf, (size_t)cap,
             "{\"guid\":\"aowl.fovfix\",\"key\":\"opticFovMulti\","
             "\"known\":%s,\"pending\":%s,\"pushes\":%d,\"stamp\":%d,"
             "\"syncs\":%d}",
             gS.known ? "true" : "false", pending ? "true" : "false",
             gS.known ? gPushes : 0, gPushes, gPushes);
    return (int32_t)strlen(buf);
}

/* ---- the assertions ------------------------------------------------------ */

enum { V_APPLIED, V_NOTAPPLIED, V_INCONCLUSIVE };

static int32_t classify(void) {
    if (g_ov.writeWhy[0] == 0) return V_APPLIED;
    if (!strncmp(g_ov.writeWhy, "NOT APPLIED", 11)) return V_NOTAPPLIED;
    return V_INCONCLUSIVE;
}

static const char* vname(int32_t v) {
    return v == V_APPLIED ? "APPLIED"
         : v == V_NOTAPPLIED ? "NOT APPLIED" : "INCONCLUSIVE";
}

static int32_t gFails = 0;

static void run(Scenario s, int32_t want, const char* why) {
    static char buf[65536];
    int32_t got;
    gS = s; gPushes = 0; gFetches = 0; gLoads = 0; g_sleeps = 0;
    memset(&g_ov, 0, sizeof(g_ov));
    /* The panel POSTs, then re-reads once, then verifies -- the same order
     * `aowl_ov_settings_set` uses. */
    aowl_ov_settings_load("aowl.fovfix", 1, buf, (int32_t)sizeof(buf));
    aowl_ov_settings_verify("aowl.fovfix", "opticFovMulti", s.newValue, 1,
                            buf, (int32_t)sizeof(buf));
    got = classify();
    printf("%-34s %-13s %-13s reads=%2d  %s\n",
           s.name, vname(want), got == want ? "PASS" : "FAIL", gLoads,
           got == want ? why : g_ov.writeWhy);
    if (got != want) {
        gFails++;
        printf("    got %s, wanted %s\n", vname(got), vname(want));
        if (g_ov.writeWhy[0]) printf("    banner: %s\n", g_ov.writeWhy);
    }
}

int main(void) {
    /* THE BUG THAT WAS REPORTED. A client-side mod that accepts the edit. The
     * value appears on the SECOND republish, which on the live client was
     * 13.7 s after the POST -- past the old 10-try / 8 s budget. This case is
     * the one that used to print NOT APPLIED. */
    run((Scenario){"client, accepted (the bug)", 1, 1,
               1 * POLLS_PER_REPUBLISH, 2 * POLLS_PER_REPUBLISH,
               "1.00", "2.00"},
        V_APPLIED, "the row reads back what was sent");

    /* THE OTHER DIRECTION, and the reason this is a check and not a
     * rubber stamp: the same pipeline, the same delays, but the mod keeps the
     * old value. The verdict window opens and the mismatch is then real. */
    run((Scenario){"client, mod REFUSED the value", 1, 1,
               1 * POLLS_PER_REPUBLISH, -1, "1.00", "2.00"},
        V_NOTAPPLIED, "drained and republished twice; value unchanged");

    /* A pipeline that never collects the edit is not a refusal. It must never
     * be reported as one. */
    run((Scenario){"client, bridge never collects", 1, 1, -1, -1, "1.00", "2.00"},
        V_INCONCLUSIVE, "still queued; nothing has applied it");

    /* An older backend with no status route can prove nothing either way. */
    run((Scenario){"no client/status route", 0, 1, 2, -1, "1.00", "2.00"},
        V_INCONCLUSIVE, "no way to tell 'not yet' from 'never'");

    /* A server-side page is authoritative the moment the POST returns, so a
     * mismatch there needs no window and must still be caught. */
    run((Scenario){"server-side, refused", 1, 0, 0, -1, "1.00", "2.00"},
        V_NOTAPPLIED, "authoritative store still holds the old value");

    /* ...and a server-side page that DID take must clear the banner. */
    run((Scenario){"server-side, accepted", 1, 0, 0, 1, "1.00", "2.00"},
        V_APPLIED, "authoritative store holds the new value");

    /* THE REGRESSION GUARD. The reported bug was not "the budget was a bit
     * tight": the working path needed more polls than the old budget HAD, so
     * it could not have passed however lucky the timing was. Re-run case 1 and
     * assert it in numbers, because a budget is exactly the kind of constant
     * that gets quietly tuned back down. */
    {
        Scenario s = (Scenario){"client, accepted (the bug)", 1, 1,
                                1 * POLLS_PER_REPUBLISH,
                                2 * POLLS_PER_REPUBLISH, "1.00", "2.00"};
        static char buf[65536];
        const int32_t oldBudget = 10;   /* AOWL_OV_VERIFY_TRIES before the fix */
        gS = s; gPushes = 0; gLoads = 0; g_sleeps = 0;
        memset(&g_ov, 0, sizeof(g_ov));
        aowl_ov_settings_load("aowl.fovfix", 1, buf, (int32_t)sizeof(buf));
        aowl_ov_settings_verify("aowl.fovfix", "opticFovMulti", s.newValue, 1,
                                buf, (int32_t)sizeof(buf));
        printf("\nthe working path needed %d polls; the old budget was %d "
               "-- %s\n", gLoads, oldBudget,
               gLoads > oldBudget
                 ? "so the old check COULD NOT have passed it"
                 : "which the old check would have covered");
        if (classify() != V_APPLIED || gLoads <= oldBudget) {
            gFails++;
            printf("    FAIL: expected APPLIED after more than %d polls\n",
                   oldBudget);
        }
    }

    printf("\n%s: %d failure(s)\n", gFails ? "FAIL" : "PASS", gFails);
    return gFails ? 1 : 0;
}
