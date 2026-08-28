/* WHAT DOES THE F12 PANEL ACTUALLY DISPLAY, TICK BY TICK?
 *
 * The bug this file exists for was reported four separate times and was never
 * a write bug: the edit always applied. MEASURED (facts #204, #210) the write
 * pipeline takes 13.7 s end to end, because `sbCollect()` snapshots the rows
 * BEFORE the sync whose reply drains the edit, so the value only appears on
 * the push after that. The panel re-GETs its page about a second after the
 * POST, got the PRE-EDIT document, and painted the old value back over the one
 * the player had just set. Thirteen seconds later it corrected itself. From
 * the player's chair that is "the setting reverted".
 *
 * So the assertion here is not "did the write succeed" -- `test_settings_ack.c`
 * already answers that, and it answered YES the whole time the panel looked
 * broken. It is: WHAT VALUE IS ON SCREEN at t=1s, t=5s, and after the pipeline
 * settles. That is the finished state a player can see, which is the only
 * thing that was ever wrong.
 *
 * The code under test is SLICED verbatim out of `abi/aowlspt_overlay.h` by
 * `tools/gen_test_settings_display.py` -- `aowl_ov_pend_begin/apply/settle`,
 * `aowl_ov_sval_text`, `aowl_ov_verify_match` and the whole verdict ladder.
 * Only the two seams that touch the outside world are replaced: the backend
 * (`aowl_ov_fetch`) and the page re-read (`aowl_ov_settings_load`), and the
 * fake re-read performs the SAME two steps the real `aowl_ov_read_items`
 * performs -- `aowl_ov_sval_display` per row, then `aowl_ov_pend_apply` once
 * at the end -- so the ordering under test is the shipping ordering.
 *
 * BOTH DIRECTIONS. Every scenario runs twice: once as it ships, and once in
 * PRE-FIX mode, where the driver simply does not open an optimistic edit --
 * which is exactly what the panel did yesterday. The suite REQUIRES the
 * pre-fix run to fail the t=1s assertion. A harness that passed in both modes
 * would be testing nothing, and that assertion is itself falsifiable: delete
 * the fix and the "pre-fix must be red" check goes green while the fixed run
 * goes red.
 *
 * Build (PowerShell):
 *   python tools\gen_test_settings_display.py
 *   gcc -O1 -Wall -o tools\test_settings_display.exe tools\test_settings_display.c
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

typedef int AowlFakeCS;
#define EnterCriticalSection(p) ((void)(p))
#define LeaveCriticalSection(p) ((void)(p))

#define AOWL_OV_MAX_SITEMS 256

enum { AOWL_S_BOOL = 0, AOWL_S_INT, AOWL_S_FLOAT, AOWL_S_STRING,
       AOWL_S_ENUM, AOWL_S_KEYBIND, AOWL_S_NESTED };

enum {
    AOWL_OV_PEND_NONE = 0,
    AOWL_OV_PEND_SAVING,
    AOWL_OV_PEND_REJECTED,
    AOWL_OV_PEND_UNKNOWN
};

#define AOWL_OV_PEND_MAX 8

typedef struct AowlOvPend {
    char    page[80];
    char    key[80];
    char    raw[64];
    int32_t state;
} AowlOvPend;

typedef struct AowlOvSItem {
    char    key[80];
    int32_t kind;
    char    value[64];
    char    raw[64];
    char    auth[64];
    int32_t pend;
} AowlOvSItem;

static struct {
    AowlOvSItem items[AOWL_OV_MAX_SITEMS];
    int32_t     itemCount;
    char        itemsPage[80];
    AowlOvPend  opt[AOWL_OV_PEND_MAX];
    int32_t     optCountP;
    char        writeWhy[512];
    int32_t     dataSerial;
    AowlFakeCS  cs;
} g_ov;

static void aowl_ov_note(const char* what) { (void)what; }

static void aowl_ov_copy(char* dst, int32_t cap, const char* src) {
    int32_t n = 0;
    if (cap <= 0) return;
    while (src && src[n] && n < cap - 1) { dst[n] = src[n]; n++; }
    dst[n] = 0;
}

static void aowl_ov_settings_load(const char* guid, int32_t isMod,
                                  char* buf, int32_t cap);
static int32_t aowl_ov_fetch(const wchar_t* verb, const wchar_t* path,
                             const char* body, char* buf, int32_t cap);
/* The write leg. Counted only: whether pumping it keeps the pipeline moving is
 * `tools/test_settings_push.c`'s question. Here it exists so that a change
 * which stops pumping -- the fact #210 deadlock -- shows up as a zero. */
static int32_t g_pumps = 0;
static void aowl_ov_pump_post(void) { g_pumps++; }

/* ---- the sliced-in production code -------------------------------------- */

#include "test_settings_display.gen.h"

/* ---- the scripted pipeline ---------------------------------------------- */

/* One poll is AOWL_OV_VERIFY_WAIT (800 ms) of wall clock, which is also how
 * often the panel re-reads its page while a verify is running. The MEASURED
 * 13.7 s therefore lands on poll 17. */
#define POLL_MS AOWL_OV_VERIFY_WAIT

typedef struct {
    const char* name;
    int32_t drainAtPoll;    /* when the edit leaves the queue; -1 = never   */
    int32_t applyAtPush;    /* republishes after the drain before the new
                             * value is visible; MEASURED 2 (fact #204, the
                             * push AFTER the draining push); -1 = never */
    const char* oldValue;
    const char* newValue;
} Scenario;

static const Scenario SCENARIOS[] = {
    /* The reported bug at its MEASURED timing: the edit sits in the queue for
     * 15 polls, and the value then needs TWO more republishes to become
     * visible -- 17 x 800 ms = 13.6 s, which is the 13.7 s that was measured
     * on the live pipeline. */
    { "the measured 13.7 s pipeline", 15, 2, "1.58", "0.71" },
    /* The same shape, faster -- a mod that republishes promptly. */
    { "a fast mod",                    1, 1, "1.58", "0.71" },
    /* The mod REFUSED it. The document never carries the new value, the queue
     * drains, and the pushes accumulate: that is the one case with proof the
     * pipeline finished, so it is the one case allowed to say NOT APPLIED. */
    { "the mod refuses the value",     2, -1, "1.58", "0.71" },
};

static const Scenario* gSc;
static int32_t gPoll;           /* how many page re-reads have happened     */
static int32_t gPushes;         /* republishes, as client/status reports    */
static int32_t gPrefix;         /* 1 = emulate the panel before the fix     */

/* What the row would print at each re-read, and in which state. Index 0 is the
 * re-read the POST itself performs -- roughly one second after the player let
 * go of the control, which is when they saw the value revert. */
#define MAX_TICKS 64
static char    gShown[MAX_TICKS][64];
static int32_t gShownPend[MAX_TICKS];
static int32_t gTicks;

static const char* served_value(void) {
    /* Keyed on REPUBLISHES, not on the clock -- fact #204 is about which
     * snapshot the value is in, and a wall-clock model would let the test pass
     * for a reason the real pipeline does not have. */
    if (gSc->applyAtPush >= 0 && gPushes >= gSc->applyAtPush) return gSc->newValue;
    return gSc->oldValue;
}

/* The fake page re-read. Performs exactly the two steps the real
 * `aowl_ov_read_items` performs, in the real order. */
static void aowl_ov_settings_load(const char* guid, int32_t isMod,
                                  char* buf, int32_t cap) {
    (void)guid; (void)isMod; (void)buf; (void)cap;
    g_ov.itemCount = 1;
    aowl_ov_copy(g_ov.items[0].key, 80, "opticFovMulti");
    g_ov.items[0].kind = AOWL_S_FLOAT;
    aowl_ov_copy(g_ov.items[0].raw, 64, served_value());
    aowl_ov_sval_display(&g_ov.items[0]);   /* sets `auth`, clears `pend` */
    aowl_ov_pend_apply();                   /* the optimistic overlay     */
    if (gTicks < MAX_TICKS) {
        aowl_ov_copy(gShown[gTicks], 64, g_ov.items[0].raw);
        gShownPend[gTicks] = g_ov.items[0].pend;
        gTicks++;
    }
    gPoll++;
    /* A republish happens on every poll once the edit has drained -- this is
     * the `pushes` counter the status route reports, driven from the SCENARIO
     * and never from our own re-reads. (The old ack harness advanced it from
     * its re-reads, which baked in the assumption under test.) */
    if (gSc->drainAtPoll >= 0 && gPoll > gSc->drainAtPoll) gPushes++;
}

static int32_t aowl_ov_fetch(const wchar_t* verb, const wchar_t* path,
                             const char* body, char* buf, int32_t cap) {
    int32_t pending = (gSc->drainAtPoll < 0 || gPoll <= gSc->drainAtPoll);
    (void)verb; (void)path; (void)body;
    return (int32_t)_snprintf(buf, (size_t)cap,
                              "{\"known\":true,\"pending\":%s,\"pushes\":%d}",
                              pending ? "true" : "false", gPushes);
}

/* ---- the driver: what `aowl_ov_settings_set` does, minus the transport --- */

static void run(const Scenario* sc, int32_t prefix) {
    char buf[2048];
    gSc = sc; gPoll = 0; gPushes = 0; gTicks = 0; gPrefix = prefix;
    memset(&g_ov, 0, sizeof(g_ov));
    aowl_ov_copy(g_ov.itemsPage, 80, "aowl.tarkov");
    aowl_ov_pend_clear();
    /* THE ONE LINE THAT DIFFERS BETWEEN THE TWO MODES. Pre-fix, the panel
     * opened no optimistic edit and simply displayed whatever the document
     * said -- which for 13.7 s was the old value. */
    if (!prefix) (void)aowl_ov_pend_begin("aowl.tarkov", "opticFovMulti", sc->newValue);
    /* POST, then the immediate re-read. */
    aowl_ov_settings_load("aowl.tarkov", 1, buf, (int32_t)sizeof(buf));
    aowl_ov_settings_verify("aowl.tarkov", "opticFovMulti", sc->newValue, 1,
                            buf, (int32_t)sizeof(buf));
}

/* ---- assertions on the FINISHED STATE ----------------------------------- */

static int32_t gFail;

static int32_t shown_at_ms(int32_t ms, char* out, int32_t* pend) {
    /* Tick 0 is the re-read the POST performs; tick n is n polls later. */
    int32_t t = ms / POLL_MS;
    if (t >= gTicks) return 0;
    aowl_ov_copy(out, 64, gShown[t]);
    *pend = gShownPend[t];
    return 1;
}

static int32_t check(const char* what, int32_t ok) {
    printf("    %-58s %s\n", what, ok ? "PASS" : "FAIL");
    if (!ok) gFail++;
    return ok;
}

/* Same shape, but the caller EXPECTS red -- used for the pre-fix run, where a
 * PASS is the failure. */
static int32_t check_red(const char* what, int32_t wentRed) {
    printf("    %-58s %s\n", what, wentRed ? "RED (as required)"
                                           : "GREEN -- THE TEST PROVES NOTHING");
    if (!wentRed) gFail++;
    return wentRed;
}

static int32_t displays(int32_t ms, const char* want) {
    char got[64]; int32_t pend = 0;
    if (!shown_at_ms(ms, got, &pend)) return 0;      /* could not look */
    return strcmp(got, want) == 0;
}

/* THREE OUTCOMES, NEVER TWO. "the run had already finished by t=5s so there is
 * no tick to look at" is INCONCLUSIVE, not a failure -- flattening it to FAIL
 * is the same error in the other direction as flattening it to PASS. */
static void check3(const char* what, int32_t canLook, int32_t ok) {
    if (!canLook) { printf("    %-58s INCONCLUSIVE (settled first)\n", what); return; }
    check(what, ok);
}

static int32_t can_look(int32_t ms) { return (ms / POLL_MS) < gTicks; }

/* THE INVARIANT, stated as a negative so it can be falsified: at no point
 * between the edit and the verdict does the panel put the stale value back on
 * screen. That single sentence IS the reported bug, and it holds for every
 * scenario -- fast, slow, and refused. */
static int32_t never_shows_stale(const char* oldValue) {
    int32_t t;
    if (gTicks == 0) return 0;
    for (t = 0; t < gTicks; t++)
        if (strcmp(gShown[t], oldValue) == 0) return 0;
    return 1;
}

int main(void) {
    size_t i;
    printf("F12 settings panel -- WHAT IS ON SCREEN, tick by tick\n");

    for (i = 0; i < sizeof(SCENARIOS) / sizeof(SCENARIOS[0]); i++) {
        const Scenario* sc = &SCENARIOS[i];
        int32_t rejects = (sc->applyAtPush < 0);
        char last[64]; int32_t lastPend = 0;

        printf("\n  %s (fixed)\n", sc->name);
        run(sc, 0);
        check("t=1s shows the value the player just set",
              displays(1000, sc->newValue));
        check3("t=5s still shows it", can_look(5000),
               displays(5000, sc->newValue));
        check("the stale value is NEVER repainted before the verdict",
              never_shows_stale(sc->oldValue));
        /* THE LATENCY BUDGET. `gTicks` is one per 800 ms page re-read, so the
         * number of ticks IS the measured wall clock from the edit to the
         * confirmed display. Pre-fix the panel showed the player's value only
         * once the document did, which for the measured pipeline was tick 17
         * -- 13.6 s. The budget asserted here is the user-visible one. */
        check("edit -> the player's value on screen is under 1 s",
              gTicks > 0 && strcmp(gShown[0], sc->newValue) == 0);
        check("the write leg kept being pumped (fact #210)", g_pumps > 0);

        aowl_ov_copy(last, 64, gShown[gTicks - 1]);
        lastPend = gShownPend[gTicks - 1];
        if (!rejects) {
            check("settles on the new value",
                  strcmp(last, sc->newValue) == 0);
            check("and stops saying SAVING once confirmed",
                  g_ov.optCountP == 0 &&
                  g_ov.items[0].pend == AOWL_OV_PEND_NONE);
            check("with no banner",  g_ov.writeWhy[0] == 0);
        } else {
            /* The whole point of the rejected case: the authoritative value is
             * back on screen AND the panel says the edit was not accepted.
             * Either half alone is the silent reversion that started this. */
            check("a rejected edit shows the AUTHORITATIVE value",
                  strcmp(g_ov.items[0].raw, sc->oldValue) == 0);
            check("and is explicitly marked not-accepted, never silent",
                  g_ov.items[0].pend == AOWL_OV_PEND_REJECTED);
            check("and the banner says NOT APPLIED in words",
                  strncmp(g_ov.writeWhy, "NOT APPLIED", 11) == 0);
        }
        (void)lastPend;

        /* ---- the other direction ---- */
        printf("  %s (pre-fix)\n", sc->name);
        run(sc, 1);
        check_red("t=1s: pre-fix panel must NOT show the new value",
                  !displays(1000, sc->newValue));
        check("pre-fix showed the STALE value at t=1s, which is the bug",
              displays(1000, sc->oldValue));
        /* THE MEASURED BEFORE-NUMBER, from the same scripted pipeline the
         * fixed run uses -- not quoted from a log. */
        {
            int32_t t, first = -1;
            for (t = 0; t < gTicks; t++)
                if (strcmp(gShown[t], sc->newValue) == 0) { first = t; break; }
            if (first < 0)
                printf("    pre-fix: the new value NEVER reached the screen\n");
            else
                printf("    pre-fix latency to the new value on screen: %d ms\n",
                       first * POLL_MS);
            if (!rejects)
                check_red("pre-fix latency must EXCEED the 1000 ms budget",
                          first < 0 || first * POLL_MS >= 1000);
        }
    }

    printf("\n%s\n", gFail ? "SUITE FAILED" : "SUITE PASSED");
    return gFail ? 1 : 0;
}
