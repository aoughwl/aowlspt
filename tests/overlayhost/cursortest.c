/* cursortest.c -- the overlay cursor-free decision, OFFLINE.
 *
 * `abi/aowlspt_cursor.h` splits into a pure half (staleness, the union of
 * publications, the popcount that IS the ref count, the save/restore edges, the
 * re-assert hold, the unwind-on-disable) and a live half that calls four
 * managed statics. Compiled with `AOWL_CUR_PURE` the live half is omitted
 * entirely, so every branch of the decision is testable here with no game, no
 * Windows and no D3D.
 *
 * WHAT MAKES THESE CHECKS FALSIFIABLE
 * -----------------------------------
 * Each assertion is about the FINISHED STATE, not about the call that produced
 * it, and the restore assertions compare against the value that was CAPTURED
 * rather than against the constant `Locked`/invisible. `test_restore_is_not_a_
 * constant` is the one that carries the whole point: it opens a panel from a
 * state of None/visible -- the case that works today by accident, and the case
 * a hardcoded restore would silently break -- and asserts the restore puts back
 * None/visible. A version of the header that restored `Locked` would pass every
 * other test in this file and fail that one.
 *
 * `test_stale_source_releases` is the other: it is the reason the ref count is
 * a level and not a counter. A hand-incremented counter passes every test here
 * except that one, where it strands the cursor freed forever.
 *
 * Build: see `tools/aowl.nim` (target `tests`). Standalone:
 *   gcc -std=c99 -I../../abi -o cursortest.exe cursortest.c
 */

#include <stdio.h>
#include <stdint.h>
#include <string.h>

#define AOWL_CUR_PURE 1
#include "aowlspt_cursor.h"

static int g_fail = 0;
static int g_ran  = 0;

#define CHECK(cond, msg) do {                                            \
    g_ran++;                                                             \
    if (!(cond)) { g_fail++;                                             \
        printf("  FAIL %s:%d  %s\n", __FILE__, __LINE__, (msg)); }       \
} while (0)

/* A tiny harness that mirrors what `aowl_cur_tick_body` does, minus the game:
 * decide, then apply the bookkeeping the caller is responsible for. The
 * simulated "game" is two ints the actions write. */
typedef struct Sim {
    AowlCurState st;
    int32_t lock;
    int32_t vis;
    int32_t lastAct;
} Sim;

static void sim_init(Sim* s, int32_t lock, int32_t vis) {
    aowl_cur_reset(&s->st);
    s->st.enabled = 1;
    s->lock = lock;
    s->vis  = vis;
    s->lastAct = AOWL_CUR_ACT_NONE;
}

static void sim_tick(Sim* s, uint64_t nowMs) {
    AowlCurAct a;
    aowl_cur_decide(&s->st, nowMs, s->lock, s->vis, &a);
    s->lastAct = a.kind;
    switch (a.kind) {
    case AOWL_CUR_ACT_FREE:
        /* the caller saves what it READ, then unlocks */
        aowl_cur_did_free(&s->st, s->lock, s->vis);
        s->lock = AOWL_CUR_LOCK_NONE;
        s->vis  = 1;
        break;
    case AOWL_CUR_ACT_HOLD:
        aowl_cur_did_hold(&s->st);
        s->lock = AOWL_CUR_LOCK_NONE;
        s->vis  = 1;
        break;
    case AOWL_CUR_ACT_RESTORE:
        s->lock = a.lock;
        s->vis  = a.vis;
        aowl_cur_did_restore(&s->st);
        break;
    default: break;
    }
}

/* ------------------------------------------------------------------ */

static void test_idle_does_nothing(void) {
    Sim s;
    uint64_t t;
    printf("idle: no panel open touches nothing\n");
    sim_init(&s, AOWL_CUR_LOCK_LOCKED, 0);
    for (t = 100; t < 2000; t += 16) sim_tick(&s, t);
    CHECK(s.lock == AOWL_CUR_LOCK_LOCKED, "idle relocked/unlocked the cursor");
    CHECK(s.vis == 0, "idle changed visibility");
    CHECK(s.st.frees == 0 && s.st.restores == 0, "idle acted");
    CHECK(s.st.haveSaved == 0, "idle saved a state it never changed");
}

static void test_free_and_restore_in_raid(void) {
    Sim s;
    printf("raid: open a panel -> free; close it -> restore the CAPTURED state\n");
    sim_init(&s, AOWL_CUR_LOCK_LOCKED, 0);          /* in a raid */

    aowl_cur_publish(&s.st, AOWL_CUR_SRC_OVERLAY, AOWL_CUR_P_OVERLAY, 1000);
    sim_tick(&s, 1000);
    CHECK(s.lastAct == AOWL_CUR_ACT_FREE, "opening a panel did not free");
    /* THE FINISHED STATE with a panel open. */
    CHECK(s.lock == AOWL_CUR_LOCK_NONE, "cursor is still locked with a panel open");
    CHECK(s.vis == 1, "cursor is still hidden with a panel open");
    CHECK(s.st.panels == 1, "ref count is not 1 with one panel open");

    /* keep it open a while: the mask is republished each frame */
    {
        uint64_t t;
        for (t = 1016; t < 3000; t += 16) {
            aowl_cur_publish(&s.st, AOWL_CUR_SRC_OVERLAY, AOWL_CUR_P_OVERLAY, t);
            sim_tick(&s, t);
        }
    }
    CHECK(s.st.frees == 1, "freed more than once for one panel session");
    CHECK(s.lock == AOWL_CUR_LOCK_NONE, "cursor relocked while the panel was open");

    /* close it: the source publishes an EMPTY mask */
    aowl_cur_publish(&s.st, AOWL_CUR_SRC_OVERLAY, 0, 3016);
    sim_tick(&s, 3016);
    CHECK(s.lastAct == AOWL_CUR_ACT_RESTORE, "closing the panel did not restore");
    CHECK(s.lock == AOWL_CUR_LOCK_LOCKED, "raid lock was not put back");
    CHECK(s.vis == 0, "cursor was left visible after the panel closed");
    CHECK(s.st.haveSaved == 0, "still holding a saved state after restoring");
}

/* THE ONE THAT CATCHES A HARDCODED RESTORE. */
static void test_restore_is_not_a_constant(void) {
    Sim s;
    printf("menu: open a panel from None/visible -> restore None/visible\n");
    /* The common case, and the case that "works today": the player is in a
     * game menu, so the game has ALREADY unlocked the cursor. */
    sim_init(&s, AOWL_CUR_LOCK_NONE, 1);

    aowl_cur_publish(&s.st, AOWL_CUR_SRC_OVERLAY, AOWL_CUR_P_OVERLAY, 500);
    sim_tick(&s, 500);
    CHECK(s.st.savedLock == AOWL_CUR_LOCK_NONE,
          "saved lock is not what the game actually had");
    CHECK(s.st.savedVis == 1, "saved visibility is not what the game actually had");

    aowl_cur_publish(&s.st, AOWL_CUR_SRC_OVERLAY, 0, 600);
    sim_tick(&s, 600);
    /* An implementation that restored the constant Locked+invisible would take
     * the cursor away from a menu that is still open. */
    CHECK(s.lock == AOWL_CUR_LOCK_NONE,
          "restore locked a cursor the game had left unlocked (hardcoded restore)");
    CHECK(s.vis == 1,
          "restore hid a cursor the game had left visible (hardcoded restore)");

    /* And the Confined case, which no constant would ever guess. */
    sim_init(&s, AOWL_CUR_LOCK_CONFINED, 0);
    aowl_cur_publish(&s.st, AOWL_CUR_SRC_OVERLAY, AOWL_CUR_P_ADMIN, 500);
    sim_tick(&s, 500);
    aowl_cur_publish(&s.st, AOWL_CUR_SRC_OVERLAY, 0, 600);
    sim_tick(&s, 600);
    CHECK(s.lock == AOWL_CUR_LOCK_CONFINED, "Confined was not restored verbatim");
}

static void test_refcount_two_panels(void) {
    Sim s;
    printf("refcount: closing one of two panels must NOT relock\n");
    sim_init(&s, AOWL_CUR_LOCK_LOCKED, 0);

    /* F12 from the overlay, F3 from the host: two different sources. */
    aowl_cur_publish(&s.st, AOWL_CUR_SRC_OVERLAY, AOWL_CUR_P_OVERLAY, 1000);
    aowl_cur_publish(&s.st, AOWL_CUR_SRC_HOST,    AOWL_CUR_P_DEBUGUI, 1000);
    sim_tick(&s, 1000);
    CHECK(s.st.panels == 2, "two panels open did not read as a ref count of 2");
    CHECK(s.lock == AOWL_CUR_LOCK_NONE, "two panels open and the cursor is locked");

    /* Close F12. F3 is still up. */
    aowl_cur_publish(&s.st, AOWL_CUR_SRC_OVERLAY, 0,                  1016);
    aowl_cur_publish(&s.st, AOWL_CUR_SRC_HOST,    AOWL_CUR_P_DEBUGUI, 1016);
    sim_tick(&s, 1016);
    CHECK(s.st.panels == 1, "ref count did not drop to 1");
    CHECK(s.lastAct != AOWL_CUR_ACT_RESTORE,
          "closing one of two panels stranded the other by restoring");
    CHECK(s.lock == AOWL_CUR_LOCK_NONE, "cursor relocked under a still-open panel");

    /* Two panels from ONE source, as F12+F6 both are. */
    aowl_cur_publish(&s.st, AOWL_CUR_SRC_OVERLAY,
                     AOWL_CUR_P_OVERLAY | AOWL_CUR_P_ADMIN, 1032);
    aowl_cur_publish(&s.st, AOWL_CUR_SRC_HOST, 0, 1032);
    sim_tick(&s, 1032);
    CHECK(s.st.panels == 2, "one source publishing two panels did not count 2");

    /* Now close everything. */
    aowl_cur_publish(&s.st, AOWL_CUR_SRC_OVERLAY, 0, 1048);
    sim_tick(&s, 1048);
    CHECK(s.lastAct == AOWL_CUR_ACT_RESTORE, "the last panel closing did not restore");
    CHECK(s.lock == AOWL_CUR_LOCK_LOCKED, "the raid lock was not put back");
}

/* THE ONE A HAND-INCREMENTED COUNTER FAILS. */
static void test_stale_source_releases(void) {
    Sim s;
    printf("stale: a source that stops publishing releases itself\n");
    sim_init(&s, AOWL_CUR_LOCK_LOCKED, 0);

    aowl_cur_publish(&s.st, AOWL_CUR_SRC_OVERLAY, AOWL_CUR_P_OVERLAY, 1000);
    sim_tick(&s, 1000);
    CHECK(s.lock == AOWL_CUR_LOCK_NONE, "did not free");

    /* The overlay DLL dies / the render thread stops / the panel is torn down
     * without a close event. Nothing ever publishes again. */
    sim_tick(&s, 1000 + AOWL_CUR_STALE_MS);       /* not yet expired */
    CHECK(s.st.panels == 1, "claim expired too early");
    CHECK(s.lock == AOWL_CUR_LOCK_NONE, "relocked before the claim expired");

    sim_tick(&s, 1000 + AOWL_CUR_STALE_MS + 1);   /* expired */
    CHECK(s.st.panels == 0, "a silent source kept its claim forever");
    CHECK(s.lastAct == AOWL_CUR_ACT_RESTORE, "a silent source did not release");
    CHECK(s.lock == AOWL_CUR_LOCK_LOCKED,
          "the cursor was left FREED after the panel stopped running");
    CHECK(s.vis == 0, "the cursor was left VISIBLE after the panel stopped running");
}

static void test_hold_against_reassert(void) {
    Sim s;
    uint64_t t;
    printf("hold: the game re-asserting the lock is undone, and counted\n");
    sim_init(&s, AOWL_CUR_LOCK_LOCKED, 0);
    aowl_cur_publish(&s.st, AOWL_CUR_SRC_OVERLAY, AOWL_CUR_P_OVERLAY, 1000);
    sim_tick(&s, 1000);
    CHECK(s.st.reasserts == 0, "counted a re-assert on the very first free");

    /* Simulate the client relocking every frame, as `CursorLockMode.Locked`
     * would if something in the player loop keeps setting it. */
    for (t = 1016; t < 1500; t += 16) {
        s.lock = AOWL_CUR_LOCK_LOCKED;
        s.vis  = 0;
        aowl_cur_publish(&s.st, AOWL_CUR_SRC_OVERLAY, AOWL_CUR_P_OVERLAY, t);
        sim_tick(&s, t);
        CHECK(s.lock == AOWL_CUR_LOCK_NONE, "a re-assert was not undone");
    }
    CHECK(s.st.reasserts > 0, "the hold never fired against a relocking game");
    CHECK(s.st.frees == 1, "the hold re-saved the game's state (clobbering the original)");
    CHECK(s.st.savedLock == AOWL_CUR_LOCK_LOCKED,
          "the saved state was overwritten by the state we ourselves forced");

    /* The hold MUST stop the instant the panel closes. */
    aowl_cur_publish(&s.st, AOWL_CUR_SRC_OVERLAY, 0, 1516);
    sim_tick(&s, 1516);
    CHECK(s.lock == AOWL_CUR_LOCK_LOCKED, "the hold did not stop on close");
    {
        int64_t r = s.st.reasserts;
        for (t = 1532; t < 3000; t += 16) sim_tick(&s, t);
        CHECK(s.st.reasserts == r, "the hold kept running after the last panel closed");
        CHECK(s.lock == AOWL_CUR_LOCK_LOCKED, "the hold re-freed after close");
    }
}

static void test_disable_unwinds(void) {
    Sim s;
    printf("unwind: switching off while a panel is open still restores\n");

    /* by the flag */
    sim_init(&s, AOWL_CUR_LOCK_LOCKED, 0);
    aowl_cur_publish(&s.st, AOWL_CUR_SRC_OVERLAY, AOWL_CUR_P_OVERLAY, 1000);
    sim_tick(&s, 1000);
    CHECK(s.lock == AOWL_CUR_LOCK_NONE, "did not free");
    s.st.enabled = 0;
    aowl_cur_publish(&s.st, AOWL_CUR_SRC_OVERLAY, AOWL_CUR_P_OVERLAY, 1016);
    sim_tick(&s, 1016);
    CHECK(s.lock == AOWL_CUR_LOCK_LOCKED,
          "turning the flag off left the cursor freed");
    CHECK(s.st.haveSaved == 0, "still holding a saved state after unwinding");

    /* by the fault budget */
    sim_init(&s, AOWL_CUR_LOCK_LOCKED, 0);
    aowl_cur_publish(&s.st, AOWL_CUR_SRC_OVERLAY, AOWL_CUR_P_OVERLAY, 1000);
    sim_tick(&s, 1000);
    {
        int i;
        for (i = 0; i < AOWL_CUR_MAX_FAULTS; i++) aowl_cur_fault(&s.st);
    }
    CHECK(s.st.off == 1, "the fault budget did not switch the feature off");
    aowl_cur_publish(&s.st, AOWL_CUR_SRC_OVERLAY, AOWL_CUR_P_OVERLAY, 1016);
    sim_tick(&s, 1016);
    CHECK(s.lock == AOWL_CUR_LOCK_LOCKED,
          "self-disabling on faults left the cursor freed IN A RAID");

    /* and it stays off, without acting again */
    aowl_cur_publish(&s.st, AOWL_CUR_SRC_OVERLAY, AOWL_CUR_P_OVERLAY, 1032);
    sim_tick(&s, 1032);
    CHECK(s.lastAct == AOWL_CUR_ACT_NONE, "a disabled feature acted");
}

static void test_never_freed_when_flag_off(void) {
    Sim s;
    printf("flag: default OFF means an open panel changes nothing\n");
    aowl_cur_reset(&s.st);
    s.st.enabled = 0;                    /* the shipped default */
    s.lock = AOWL_CUR_LOCK_LOCKED;
    s.vis  = 0;
    aowl_cur_publish(&s.st, AOWL_CUR_SRC_OVERLAY, AOWL_CUR_P_OVERLAY, 1000);
    sim_tick(&s, 1000);
    CHECK(s.lock == AOWL_CUR_LOCK_LOCKED, "a disabled feature freed the cursor");
    CHECK(s.st.frees == 0, "a disabled feature acted");
}

static void test_clock_glitch_does_not_relock(void) {
    Sim s;
    printf("clock: a backwards clock must not relock under an open panel\n");
    sim_init(&s, AOWL_CUR_LOCK_LOCKED, 0);
    aowl_cur_publish(&s.st, AOWL_CUR_SRC_OVERLAY, AOWL_CUR_P_OVERLAY, 100000);
    sim_tick(&s, 100000);
    CHECK(s.lock == AOWL_CUR_LOCK_NONE, "did not free");
    sim_tick(&s, 50000);                 /* now < stamp */
    CHECK(s.st.panels == 1, "a backwards clock expired a live claim");
    CHECK(s.lock == AOWL_CUR_LOCK_NONE, "a backwards clock relocked the cursor");
}

int main(void) {
    printf("== cursortest: the overlay cursor-free decision, offline ==\n");
    test_idle_does_nothing();
    test_free_and_restore_in_raid();
    test_restore_is_not_a_constant();
    test_refcount_two_panels();
    test_stale_source_releases();
    test_hold_against_reassert();
    test_disable_unwinds();
    test_never_freed_when_flag_off();
    test_clock_glitch_does_not_relock();
    printf("== %d checks, %d failed ==\n", g_ran, g_fail);
    return g_fail ? 1 : 0;
}
