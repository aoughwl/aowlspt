/* dragtest.c -- the F3 edit-mode POINTER EDGE MACHINE, headless.
 *
 * WHAT THIS COVERS, AND WHAT IT DELIBERATELY DOES NOT
 * --------------------------------------------------
 * The F3 widget drag has two halves and they live in two languages:
 *
 *   the ARITHMETIC   hit-testing, the grab offset, the move, the drop snap and
 *                    the anchor rebind. All of it is pure Nim in
 *                    `host/Aowlspt.Host.Il2Cpp/wgeom.nim`, driven offline by
 *                    `tests/wgeom_test.nim` via `tools/run_wgeom_test.py`.
 *                    It is NOT duplicated here -- a second copy of an assertion
 *                    in another language is a second thing to keep true, not a
 *                    second check.
 *
 *   the EDGE MACHINE `aowl_wg_mouse_apply` in `abi/aowlspt_widget.h`: which of
 *                    a stream of per-frame pointer samples counts as a press,
 *                    which as a release, when the sample is usable, and what a
 *                    focus change does to a button that was held. That is C,
 *                    and it is this file.
 *
 * The edge machine is where a drag dies SILENTLY rather than visibly, which is
 * why it is worth a test at all. A press edge reported on two consecutive
 * frames grabs a second widget under a click the player aimed at the game. A
 * held state carried across an alt-tab comes back as a release the drag acts
 * on, so the widget lands wherever the cursor happened to be in another
 * application. Neither produces a log line, a fault, or anything on screen.
 *
 * THE CHECKS ARE PROPERTIES OF THE FINISHED STATE (CLAUDE.md 9b), and several
 * are negatives that doing-nothing cannot pass and doing-everything cannot
 * pass either: exactly ONE press edge per physical press, exactly ONE release,
 * no edge at all from a repeated identical sample, `ok == 0` for a cursor
 * outside the client area, and `held == 0` after focus is lost.
 *
 * Build/run: see tests/overlayhost/run-all.py. Exit code is the failure count.
 */

#include <stdio.h>
#include <stdint.h>

/* The unit under test. `aowlspt_widget.h` pulls in <windows.h> and the rest of
 * the widget surface; only `aowl_wg_mouse_apply` and the accessors are touched
 * here, and none of them call into Windows. */
/* `aowlspt_widget.h` includes `aowlspt_navui.h`, which needs the prologue
 * verifier's byte ceiling. In the host that header is already in the single
 * generated translation unit by the time the widget header lands; here it has
 * to be named. */
#include "aowlspt_prologue.h"
#include "aowlspt_widget.h"

static int failures = 0;
static int checks   = 0;

/* ONE LINE PER CHECK, in the `ok <name>` / `error <name>` shape that
 * `tests/overlayhost/run-all.py` parses. A test that printed only a summary is
 * read by that harness as "produced no ok/error lines at all", which it
 * correctly reports as INCONCLUSIVE rather than as a pass -- so a summary alone
 * would have been a test that never actually counted. */
static void check(int ok, const char* what) {
    checks++;
    if (ok) {
        printf("ok    %s\n", what);
    } else {
        failures++;
        printf("error %s\n", what);
    }
}

/* A clean machine before each scenario. The statics are file-scope in the
 * header, so a scenario that inherited the previous one's button state would
 * make the ORDER of the scenarios load-bearing -- which is how a test starts
 * passing for the wrong reason. */
static void reset(void) {
    aowl_wg_mouse_apply(0, 0, 0, 0, 0, 0, 0);   /* focus loss clears everything */
}

#define W 3840
#define H 2160

int main(void) {
    /* ---------------------------------------------------------------- *
     * 1. A HELD BUTTON PRODUCES EXACTLY ONE PRESS EDGE.
     *
     * This is the property the whole grab depends on. `duDragStep` grabs on
     * `pressed`, so a press reported every frame while the button is down
     * would re-grab a (possibly different, topmost) widget every frame and the
     * drag would appear to jump between widgets.
     * ---------------------------------------------------------------- */
    reset();
    check(aowl_wg_mouse_apply(1, 1, 100, 100, W, H, 0) == 1,
          "an in-client sample with the button up is usable");
    check(aowl_wg_lmb_pressed() == 0, "button up: no press edge");
    check(aowl_wg_lmb_held() == 0,    "button up: not held");

    aowl_wg_mouse_apply(1, 1, 100, 100, W, H, 1);
    check(aowl_wg_lmb_pressed() == 1, "the frame the button goes down IS a press");
    check(aowl_wg_lmb_held() == 1,    "the frame the button goes down is held");
    check(aowl_wg_lmb_released() == 0, "a press is not also a release");

    int extraPresses = 0;
    for (int i = 0; i < 30; i++) {
        aowl_wg_mouse_apply(1, 1, 100 + i, 100, W, H, 1);
        if (aowl_wg_lmb_pressed()) extraPresses++;
        if (!aowl_wg_lmb_held()) {
            check(0, "a button held down stays held");
            break;
        }
    }
    check(extraPresses == 0,
          "30 further frames with the button still down produce NO further "
          "press edge");

    aowl_wg_mouse_apply(1, 1, 130, 100, W, H, 0);
    check(aowl_wg_lmb_released() == 1, "the frame the button comes up IS a release");
    check(aowl_wg_lmb_held() == 0,     "after the release it is not held");

    int extraReleases = 0;
    for (int i = 0; i < 30; i++) {
        aowl_wg_mouse_apply(1, 1, 130, 100, W, H, 0);
        if (aowl_wg_lmb_released()) extraReleases++;
    }
    check(extraReleases == 0,
          "30 further frames with the button still up produce NO further "
          "release edge");

    /* ---------------------------------------------------------------- *
     * 2. THE CURSOR LEAVING THE CLIENT AREA IS NOT A RELEASE.
     *
     * `ok` must go to 0 so the Nim side HOLDS the widget where it is, but the
     * button must keep reading held, because the player has not let go. The
     * old shape returned early before updating the button at all, which would
     * have frozen `held` at whatever it last was.
     * ---------------------------------------------------------------- */
    reset();
    aowl_wg_mouse_apply(1, 1, 50, 50, W, H, 1);
    check(aowl_wg_lmb_pressed() == 1, "(setup) grabbed inside the client area");

    check(aowl_wg_mouse_apply(1, 1, -12, 50, W, H, 1) == 0,
          "a cursor left of the client area is not a usable sample");
    check(aowl_wg_mouse_ok() == 0, "...and mouse_ok says so");
    check(aowl_wg_lmb_held() == 1, "...but the button is still held");
    check(aowl_wg_lmb_released() == 0, "...and leaving the client area is NOT a release");

    check(aowl_wg_mouse_apply(1, 1, W, 50, W, H, 1) == 0,
          "a cursor at exactly the client width is outside it (0-based pixels)");
    check(aowl_wg_mouse_apply(1, 1, 50, H, W, H, 1) == 0,
          "a cursor at exactly the client height is outside it");
    check(aowl_wg_mouse_apply(1, 1, W - 1, H - 1, W, H, 1) == 1,
          "the bottom-right pixel of the client area IS inside it");

    /* ---------------------------------------------------------------- *
     * 3. LOSING THE FOREGROUND CLEARS THE HELD BUTTON.
     *
     * The failure this prevents: alt-tab mid-drag, click something in another
     * application, come back -- and the machine reports a release, so the
     * widget is dropped and SAVED at a position the player never chose.
     * ---------------------------------------------------------------- */
    reset();
    aowl_wg_mouse_apply(1, 1, 200, 200, W, H, 1);
    check(aowl_wg_lmb_held() == 1, "(setup) held before the focus change");

    check(aowl_wg_mouse_apply(0, 0, 0, 0, 0, 0, 1) == 0,
          "a sample while another process owns the foreground is unusable");
    check(aowl_wg_lmb_held() == 0, "losing the foreground clears the held button");
    check(aowl_wg_lmb_released() == 0,
          "losing the foreground reports NO release edge -- the drag ends via "
          "the held state, and a synthetic release would drop the widget twice");
    check(aowl_wg_mouse_ok() == 0, "losing the foreground makes the sample unusable");

    /* Coming BACK with the button still physically down must read as a fresh
     * press, not as a continuation. Otherwise the first click after alt-tabbing
     * back is swallowed. */
    check(aowl_wg_mouse_apply(1, 1, 200, 200, W, H, 1) == 1,
          "the sample is usable again once we own the foreground");
    check(aowl_wg_lmb_pressed() == 1,
          "returning with the button down reads as a FRESH press, not a "
          "continuation");

    /* ---------------------------------------------------------------- *
     * 4. A DEGENERATE OR MISSING CLIENT RECT IS A REFUSAL, NOT A ZERO.
     *
     * A zero client size would make every canvas-relative coordinate collapse
     * onto the origin -- the same failure `aowl_region_set_screen` refuses for.
     * ---------------------------------------------------------------- */
    reset();
    check(aowl_wg_mouse_apply(1, 0, 10, 10, W, H, 0) == 0,
          "no client rect is a refusal");
    check(aowl_wg_mouse_apply(1, 1, 10, 10, 0, 0, 0) == 0,
          "a 0x0 client rect is a refusal");
    check(aowl_wg_mouse_apply(1, 1, 10, 10, -4, 9, 0) == 0,
          "a negative client width is a refusal");
    check(aowl_wg_mouse_ok() == 0, "a refused sample never reports ok");

    /* A refusal must not leave a STALE usable position behind either: the last
     * good sample's coordinates may still be readable, but `ok` gates them and
     * that is what the Nim side tests. Asserted here so a future change that
     * makes `mouse_ok` sticky is caught. */
    reset();
    aowl_wg_mouse_apply(1, 1, 640, 480, W, H, 0);
    check(aowl_wg_mouse_ok() == 1 && aowl_wg_mouse_x() == 640 &&
          aowl_wg_mouse_y() == 480, "(setup) a good sample is published");
    aowl_wg_mouse_apply(1, 0, 0, 0, 0, 0, 0);
    check(aowl_wg_mouse_ok() == 0,
          "a refusal immediately after a good sample is still a refusal");

    /* ---------------------------------------------------------------- *
     * 5. A CLICK SHORTER THAN ONE FRAME.
     *
     * The button goes down and back up between two samples, so the machine
     * never observes it down. It must report NEITHER a press NOR a release --
     * inventing a press here would grab a widget the player never grabbed.
     * ---------------------------------------------------------------- */
    reset();
    aowl_wg_mouse_apply(1, 1, 10, 10, W, H, 0);
    aowl_wg_mouse_apply(1, 1, 10, 10, W, H, 0);
    check(aowl_wg_lmb_pressed() == 0 && aowl_wg_lmb_released() == 0,
          "a click entirely between two samples produces no edge at all");

    printf("\n");
    if (failures == 0) printf("PASS  %d checks, 0 failures\n", checks);
    else               printf("FAIL  %d checks, %d failure(s)\n", checks, failures);
    return failures;
}
