/* DOES AN F12 EDIT REACH THE GAME PROCESS AND GET APPLIED?
 *
 * `tools/test_settings_ack.c` asks whether the BANNER is right. This asks the
 * question underneath it, which is the one the player cares about: an edit
 * POSTed to the backend has to be collected by the settings bridge in the game
 * process and produce `applied an F12 edit`. Nothing in the ack harness could
 * ever fail on that, because it models `pushes` as advancing with the verify
 * loop's own re-reads -- i.e. it ASSUMES the pipeline keeps running while the
 * verdict loop waits. That assumption is exactly what was false.
 *
 * WHAT WAS FALSE (measured 2026-08-28, `aowlspt-backend.log` +
 * `aowlspt-host.log` of a live session):
 *
 *   0:01:43.266  the last of six healthy POST /aowlspt/settings/client/sync
 *   0:01:46.235  the player edits aowl.fovfix; `aowl_ov_settings_verify`
 *                starts and BLOCKS the single overlay worker thread
 *   0:01:46.06+  GET /aowlspt/mods/panel and /mods/list stop entirely
 *   0:02:17.594  ONE client/sync POST -- 31.3 s later, one per verify cap
 *   0:01:58.343  the bridge gives up at its 12 s budget: fault 1/6
 *   ...          faults 2, 3, 4 at 30 s intervals
 *   0:03:50.218  the player leaves the screen; six-per-cycle resumes at once
 *   grep 'applied an F12 edit' = 0 for the whole session
 *
 * The verify loop waits for this guid to republish twice. A republish IS a
 * `client/sync` POST. The only thread that sends that POST is the one the
 * verify loop is sitting on. It is a deadlock with a 32-second timer on it,
 * and the bridge's 12-second budget expires inside every one of those timers.
 *
 * THE SHAPE OF THIS HARNESS. `aowl_ov_settings_verify` is not re-implemented:
 * it is sliced verbatim out of `abi/aowlspt_overlay.h` by
 * `tools/gen_test_settings_ack.py`, same as the ack harness. Three seams are
 * replaced -- the backend (`aowl_ov_fetch`), the page re-read
 * (`aowl_ov_settings_load`) and the write leg (`aowl_ov_pump_post`) -- and
 * around them sits a model of the parts that are NOT C: the single overlay
 * POST slot, settingshub's edit queue, and `sbTick` from
 * `host/Aowlspt.Host.Il2Cpp/settingsbridge.nim` with its real constants.
 *
 * Virtual time. `Sleep(ms)` advances the clock and runs the settings-bridge
 * ticks that would have run on the HOST tick thread -- which is a different
 * thread and is never blocked. Only the overlay worker is blocked, and the
 * whole question is what that costs.
 *
 * BOTH DIRECTIONS, and each case fails if the other build is compiled in:
 *   PUMPED  (the fix)  -> the edit is APPLIED, the bridge raises no fault.
 *   STARVED (the bug)  -> the edit is NOT applied, and the bridge's stalled
 *                         push is observed at stage 1 (ARMED AND UNSENT), not
 *                         stage 2 -- i.e. the cause is our worker thread, not
 *                         the backend. A run that reported stage 2 would have
 *                         sent four sessions to look at the port again.
 *
 * Build (PowerShell):
 *   python tools\gen_test_settings_ack.py
 *   gcc -O1 -Wall -o tools\test_settings_push.exe tools\test_settings_push.c
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <stdint.h>
#include <wchar.h>

/* ---- virtual time, and the host tick thread that is NOT blocked ---------- */

static uint64_t gNowMs = 0;
static void hostTicksUntil(uint64_t t);
#define Sleep(ms) do { hostTicksUntil(gNowMs + (uint64_t)(ms)); } while (0)

#define AOWL_OV_MAX_SITEMS 256

typedef struct { char key[64]; char raw[64]; } AowlOvSItem;

static struct {
    AowlOvSItem items[AOWL_OV_MAX_SITEMS];
    int32_t     itemCount;
    char        writeWhy[512];
} g_ov;

static void aowl_ov_note(const char* what) { (void)what; }

static void aowl_ov_settings_load(const char* guid, int32_t isMod,
                                  char* buf, int32_t cap);
static int32_t aowl_ov_fetch(const wchar_t* verb, const wchar_t* path,
                             const char* body, char* buf, int32_t cap);
static void aowl_ov_pump_post(void);

/* ---- the sliced-in production code -------------------------------------- */

#include "test_settings_ack.gen.h"

/* ---- the single overlay POST slot --------------------------------------- */
/*
 * `abi/aowlspt_overlay.h`: `postArm` is set by `aowl_ov_post_start` on the
 * host thread; `aowl_ov_pump_post` moves it to `postInFlight`, sends, and
 * bumps `postSerial`. `aowl_ov_post_stage()` is the three-way state the
 * bridge's fault message names. Modelled here, not sliced, because the real
 * one is wrapped in a critical section this single-threaded harness has no
 * use for -- the STATE MACHINE is what is under test and it is identical.
 */
enum { STAGE_IDLE = 0, STAGE_ARMED = 1, STAGE_INFLIGHT = 2 };

static int32_t gArm, gInFlight, gSerial, gTaken, gPostOk;
static char    gPostPath[192];
static char    gPostResp[4096];

static int32_t postStage(void) {
    return gInFlight ? STAGE_INFLIGHT : (gArm ? STAGE_ARMED : STAGE_IDLE);
}
static int32_t postPending(void) { return (gArm || gInFlight) ? 1 : 0; }

/* ---- settingshub: the queue an edit waits in ---------------------------- */

static int32_t gQueued;        /* an edit is queued for the game process     */
static int32_t gPushes;        /* republishes of aowl.fovfix seen by the hub */
static int32_t gApplied;       /* THE FINISHED STATE: host applied the edit  */
static int32_t gAppliedAtPush; /* the push on which the row goes new         */
static const char* gOld = "1.00";
static const char* gNew = "2.00";

/* ---- the write leg, as either build ------------------------------------- */

static int32_t gPumped;        /* 1 = the fix (verify pumps), 0 = the bug    */
static int32_t gSyncsSent;

static void pumpOnce(void) {
    if (!gArm) return;
    gArm = 0; gInFlight = 1;
    /* The backend's handler for POST /aowlspt/settings/client/sync: it counts
     * the republish and hands back whatever is queued for this guid. */
    if (!strcmp(gPostPath, "/aowlspt/settings/client/sync")) {
        gSyncsSent++;
        gPushes++;
        snprintf(gPostResp, sizeof(gPostResp),
                 "{\"ok\":true,\"pending\":[%s]}",
                 gQueued ? "{\"guid\":\"aowl.fovfix\","
                           "\"key\":\"opticFovMulti\",\"value\":2.0}" : "");
        if (gQueued) gQueued = 0;   /* it leaves the queue on collection */
    } else {
        snprintf(gPostResp, sizeof(gPostResp), "{\"ok\":true}");
    }
    gPostOk = 1;
    gInFlight = 0;
    gSerial++;
}

/* THE SEAM UNDER TEST. In the shipping header this is `aowl_ov_pump_post`,
 * called both from the worker loop tail and from the verify wait. `gPumped`
 * selects which build the sliced verify code is running against. */
static void aowl_ov_pump_post(void) { if (gPumped) pumpOnce(); }

/* ---- the settings bridge, transcribed from settingsbridge.nim ----------- */
/*
 * Constants copied from that file; if they are retuned there and not here the
 * two disagree, which is why they are named the same.
 */
#define SB_PERIOD_MS  5000
#define SB_STALL_MS  12000

static int32_t  gSbFaults;
static int32_t  gSbStageAtFault = -1;   /* what postStage said when it gave up */
static uint64_t gSbNextMs, gSbArmedAt;
static int32_t  gSbPushing;

static void sbApplyPending(const char* reply) {
    /* One edit, applied HERE -- the mod persists it and runs its hot-apply
     * hook. This is the line the whole pipeline exists to produce. */
    if (strstr(reply, "\"guid\":\"aowl.fovfix\"")) {
        gApplied = 1;
        gAppliedAtPush = gPushes;
    }
}

static void sbTick(uint64_t now) {
    if (!gSbPushing) {
        if (now < gSbNextMs) return;
        gSbNextMs = now + SB_PERIOD_MS;
        gSbPushing = 1;
        return;
    }
    if (postPending()) {
        if (gSbArmedAt > 0 && now - gSbArmedAt > SB_STALL_MS) {
            gSbFaults++;
            gSbStageAtFault = postStage();
            gSbArmedAt = 0;
            gSbPushing = 0;
        }
        return;
    }
    if (gSbArmedAt > 0) {
        gSbArmedAt = 0;
        gSbPushing = 0;
        if (gSerial != gTaken) {
            gTaken = gSerial;
            if (gPostOk) sbApplyPending(gPostResp);
        }
        return;
    }
    strcpy(gPostPath, "/aowlspt/settings/client/sync");
    gArm = 1;
    gSbArmedAt = now;
}

static int32_t gWorkerBusy;   /* 1 while `aowl_ov_settings_verify` owns it */

static void hostTicksUntil(uint64_t t) {
    /* The host ticks far faster than anything here resolves; 50 ms is well
     * under every budget in play and keeps the loop bounded.
     *
     * Two threads advance here, and keeping them apart is the whole point:
     * the HOST tick thread runs `sbTick` and is never blocked, while the
     * single OVERLAY WORKER thread runs the write leg once per pass -- and
     * stops doing so entirely while it is inside the verify loop. `gPumped`
     * is then the only thing that can still send a POST. */
    while (gNowMs < t) {
        gNowMs += 50;
        sbTick(gNowMs);
        if (!gWorkerBusy) pumpOnce();
    }
}

/* ---- the two remaining seams -------------------------------------------- */

static int32_t gLoads;

static void aowl_ov_settings_load(const char* guid, int32_t isMod,
                                  char* buf, int32_t cap) {
    (void)guid; (void)isMod; (void)buf; (void)cap;
    gLoads++;
    g_ov.itemCount = 1;
    strcpy(g_ov.items[0].key, "opticFovMulti");
    /* MEASURED (and the reason `AOWL_OV_VERIFY_PUSHES` is 2): the push that
     * DRAINS the edit still carries pre-edit rows, so the new value is first
     * visible on the push after the one that applied it. */
    if (gApplied && gPushes > gAppliedAtPush)
        strcpy(g_ov.items[0].raw, gNew);
    else
        strcpy(g_ov.items[0].raw, gOld);
}

static int32_t aowl_ov_fetch(const wchar_t* verb, const wchar_t* path,
                             const char* body, char* buf, int32_t cap) {
    (void)verb; (void)path; (void)body;
    /* GET /aowlspt/settings/client/status/aowl.fovfix?key=opticFovMulti */
    snprintf(buf, (size_t)cap,
             "{\"known\":true,\"pending\":%s,\"pushes\":%d}",
             gQueued ? "true" : "false", gPushes);
    return (int32_t)strlen(buf);
}

/* ---- the run ------------------------------------------------------------ */

static int32_t gFails;

static void expectI(const char* what, int32_t got, int32_t want) {
    if (got == want) {
        printf("    ok    %-46s = %d\n", what, got);
    } else {
        printf("    FAIL  %-46s = %d, wanted %d\n", what, got, want);
        gFails++;
    }
}

static void reset(int32_t pumped) {
    memset(&g_ov, 0, sizeof(g_ov));
    gNowMs = 0; gArm = 0; gInFlight = 0; gSerial = 0; gTaken = 0; gPostOk = 0;
    gPostPath[0] = 0; gPostResp[0] = 0;
    gQueued = 0; gPushes = 0; gApplied = 0; gAppliedAtPush = -1;
    gPumped = pumped; gSyncsSent = 0; gWorkerBusy = 0;
    gSbFaults = 0; gSbStageAtFault = -1; gSbNextMs = 0; gSbArmedAt = 0;
    gSbPushing = 0;
    gLoads = 0;
}

static const char* vname(void) {
    if (g_ov.writeWhy[0] == 0) return "APPLIED";
    if (!strncmp(g_ov.writeWhy, "NOT APPLIED", 11)) return "NOT APPLIED";
    return "INCONCLUSIVE";
}

static void run(int32_t pumped) {
    static char buf[65536];
    reset(pumped);
    /* Let the bridge settle into its steady six-per-cycle rhythm first, so a
     * run cannot pass merely because it started from a lucky phase. */
    hostTicksUntil(20000);
    if (gSyncsSent < 3) {
        printf("    FAIL  the pipeline was not healthy BEFORE the edit "
               "(%d syncs in 20 s)\n", gSyncsSent);
        gFails++;
        return;
    }
    /* The player edits a row. settingshub queues it; the panel POSTs, re-reads
     * once, then verifies -- the order `aowl_ov_settings_set` uses. */
    gQueued = 1;
    gSyncsSent = 0;             /* count only what goes out DURING the wait */
    aowl_ov_settings_load("aowl.fovfix", 1, buf, (int32_t)sizeof(buf));
    gWorkerBusy = 1;
    aowl_ov_settings_verify("aowl.fovfix", "opticFovMulti", gNew, 1,
                            buf, (int32_t)sizeof(buf));
    gWorkerBusy = 0;
}

int main(void) {
    printf("PUMPED build -- aowl_ov_pump_post() runs inside the verify wait\n");
    run(1);
    printf("    verdict %s / %s\n", vname(),
           g_ov.writeWhy[0] ? g_ov.writeWhy : "(banner cleared)");
    /* THE FINISHED STATE, not "the push returned". */
    expectI("edit applied in the game process", gApplied, 1);
    expectI("settings-bridge faults", gSbFaults, 0);
    /* Two is the floor, not a round number: the verify loop returns the
     * INSTANT the row matches, and the row can only match after the push that
     * drains the edit AND the push after it (`AOWL_OV_VERIFY_PUSHES`). Fewer
     * than two means the write leg was starved and the pass above was luck. */
    if (gSyncsSent < 2) {
        printf("    FAIL  only %d client/sync push(es) went out during the "
               "wait; the write leg is still starved\n", gSyncsSent);
        gFails++;
    } else {
        printf("    ok    %-46s = %d\n",
               "client/sync pushes during the wait", gSyncsSent);
    }

    printf("\nSTARVED build -- the wait sleeps through it (the bug)\n");
    run(0);
    printf("    verdict %s / %s\n", vname(),
           g_ov.writeWhy[0] ? g_ov.writeWhy : "(banner cleared)");
    expectI("edit applied in the game process", gApplied, 0);
    /* NAMES THE CAUSE. Stage 1 is "armed and never sent" -- our worker thread.
     * Stage 2 would be "sent, backend silent", which is a different bug in a
     * different process, and reporting it here is what "never came back" did. */
    expectI("post stage the bridge gave up at", gSbStageAtFault, STAGE_ARMED);
    if (gSbFaults < 1) {
        printf("    FAIL  the bridge did not fault, so the stall was silent\n");
        gFails++;
    } else {
        printf("    ok    settings-bridge faults                  = %d\n",
               gSbFaults);
    }
    /* And it must NOT be reported as a refusal: nothing here is evidence
     * about the value. */
    if (!strncmp(g_ov.writeWhy, "NOT APPLIED", 11)) {
        printf("    FAIL  a starved pipeline was called NOT APPLIED\n");
        gFails++;
    } else {
        printf("    ok    starved pipeline reported as INCONCLUSIVE\n");
    }

    printf("\n%s\n", gFails ? "FAILED" : "all checks passed");
    return gFails ? 1 : 0;
}
