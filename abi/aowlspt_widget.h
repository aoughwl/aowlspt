/* aowlspt_widget.h -- THE NATIVE SURFACE BEHIND THE DRAGGABLE F3 WIDGETS.
 *
 * Three unrelated things live here because all three are the same KIND of
 * thing: a plain Win32 or same-module read that the Nim overlay needs, that
 * touches NO managed memory, resolves NO IL2CPP name, installs NO detour and
 * therefore cannot be the thing that kills the client.
 *
 *   1. THE POINTER. Cursor position in the game window's CLIENT pixels, and
 *      left-button press / hold / release edges.
 *
 *   2. MEMORY. The process working set and private bytes, and the machine's
 *      committed load, for the `mem` widget.
 *
 *   3. THE REGION VIEW. A read-only flattening of `abi/aowlspt_region.h`'s
 *      participant table -- name, budget, last, max, calls, skipped, and the
 *      throttled/disabled/faulted state -- so the profiler widget can show
 *      BUDGET vs ACTUAL for every participant.
 *
 * ---------------------------------------------------------------------------
 * WHY THE POINTER IS READ AND NOT HOOKED, AND WHY THAT SETTLES THE F3 QUESTION
 * ---------------------------------------------------------------------------
 *
 * `abi/aowlspt_overlay.h` records, at length, a bug that cost a session: F10
 * never reached the D3D overlay's wndproc, because Windows classifies F10 as
 * the menu key and delivers it as WM_SYSKEYDOWN, not WM_KEYDOWN. A switch that
 * handled only WM_KEYDOWN therefore never saw it, and the harness had been
 * testing by synthesising a message the OS does not produce for that key.
 *
 * NOTHING IN THIS FILE, AND NOTHING IN THE F3 OVERLAY, READS A WINDOW MESSAGE.
 * `GetAsyncKeyState` and `GetCursorPos` read the system's asynchronous input
 * state, which the raw input thread updates BEFORE any message is created or
 * dispatched. There is no WM_KEYDOWN/WM_SYSKEYDOWN classification to get wrong
 * because no classification happens: the key is either physically down or it is
 * not. That is also why the F3 panel keeps working while the D3D overlay's
 * wndproc is swallowing every WM_KEYDOWN for its own panel -- the async table
 * is not on that path either.
 *
 * This is an argument, not a measurement, so the overlay MEASURES it: the first
 * time the toggle key's edge fires, `debugui` logs the route that saw it and
 * the virtual-key code. If that line never appears, the key never arrived, and
 * the answer is in the log rather than in someone's model of Windows.
 *
 * THE FOREGROUND CHECK is what stops all of this from being a global input
 * grab: the pointer is only ever sampled while the foreground window belongs to
 * THIS process (`aowl_du_foreground` in aowlspt_debugui.h), so dragging a widget
 * can never be triggered by a click in another application.
 *
 * ---------------------------------------------------------------------------
 * SAFETY
 * ---------------------------------------------------------------------------
 *
 * No allocation, on any path. Every buffer here is a file-scope fixed array.
 * No guard is armed: this file is called from inside the ONE `aowl_p_p_seh`
 * the overlay body already holds, and `aowl_p_p_seh` is not re-entrant -- a
 * nested guard would DISARM the outer one rather than add anything.
 * Every loop is bounded by a compile-time constant.
 */
#ifndef AOWLSPT_WIDGET_H
#define AOWLSPT_WIDGET_H

#include <windows.h>
#include <stdint.h>
#include <string.h>
#include <stdio.h>

/* For AOWL_NAV_UOBJ_CACHEDPTR -- the offset of `UnityEngine.Object.m_CachedPtr`,
 * which is how the overlay tells a LIVE object from Unity's "fake null".
 *
 * Included HERE, from the header `debugui.nim` pulls in first, purely for
 * ORDER: `botnav.nim` includes the same file, but its emit lands later in the
 * single generated translation unit than `debugui.nim`'s first use of the
 * accessor -- which surfaced as `implicit declaration of
 * aowl_nav_off_cachedptr` followed by `static declaration follows non-static
 * declaration`. Including it earlier makes botnav's include a no-op through the
 * ordinary include guard.
 *
 * Unlike `aowlspt_region.h`, this is safe to include from anywhere: navui.h has
 * NO host/client mode define, so there is no configuration for an early include
 * to lock in. That difference is the whole reason the region view needed its
 * own file and this does not. */
#include "aowlspt_navui.h"

/* ================================================================== *
 * 1. THE POINTER
 * ================================================================== */

static int32_t aowl_wg_ms_ok = 0;
static int32_t aowl_wg_ms_x  = 0;   /* client px, origin TOP-LEFT      */
static int32_t aowl_wg_ms_y  = 0;
static int32_t aowl_wg_ms_w  = 0;   /* client width  in px             */
static int32_t aowl_wg_ms_h  = 0;   /* client height in px             */

static int32_t aowl_wg_lmb_was  = 0;
static int32_t aowl_wg_lmb_down = 0;
static int32_t aowl_wg_lmb_press = 0;
static int32_t aowl_wg_lmb_rel   = 0;

/* Sample the pointer and the left button ONCE per overlay refresh. Every other
 * accessor below just reads what this stored, so a single refresh can never see
 * the cursor in two places (which is what makes a drag jitter) and the button
 * edges are computed exactly once per frame rather than once per query.
 *
 * Returns 1 when the sample is usable: our process owns the foreground, the
 * window has a real client area, and the cursor is inside it. */
/* THE EDGE MACHINE, SEPARATED FROM THE WIN32 CALLS THAT FEED IT.
 *
 * `aowl_wg_mouse_sample` below is now only the four Win32 reads; every DECISION
 * -- press edge, release edge, whether the sample is usable, what a focus loss
 * does to a held button -- is here, in a function that takes plain integers.
 * That is what `tests/overlayhost/dragtest.c` drives, and it is the half where
 * a drag silently dies: a press edge reported twice grabs the widget under a
 * click the player aimed at the game, and a held state carried across a focus
 * change comes back as a release the drag acts on.
 *
 * `focused` 0 means the foreground window is not ours (or there is none).
 * `w`/`h` are the client size; `x`/`y` the cursor in client pixels. Returns 1
 * only when the sample is usable, which is what `aowl_wg_mouse_ok` publishes. */
static int32_t aowl_wg_mouse_apply(int32_t focused, int32_t haveRect,
                                   int32_t x, int32_t y,
                                   int32_t w, int32_t h, int32_t down) {
    aowl_wg_ms_ok = 0;
    aowl_wg_lmb_press = 0;
    aowl_wg_lmb_rel   = 0;

    if (!focused) {
        /* Not our window. FORGET the button entirely rather than carry a held
         * state across a focus change -- otherwise alt-tabbing away mid-drag
         * and clicking elsewhere comes back as a release we act on. No release
         * EDGE is reported either: the drag is ended by the held state going
         * to 0, which the Nim side treats as a drop, and reporting a synthetic
         * release as well would drop the widget twice. */
        aowl_wg_lmb_was = 0;
        aowl_wg_lmb_down = 0;
        return 0;
    }
    if (!haveRect || w <= 0 || h <= 0) return 0;

    aowl_wg_ms_w = w;
    aowl_wg_ms_h = h;
    aowl_wg_ms_x = x;
    aowl_wg_ms_y = y;

    down = down ? 1 : 0;
    if (down && !aowl_wg_lmb_was)  aowl_wg_lmb_press = 1;
    if (!down && aowl_wg_lmb_was)  aowl_wg_lmb_rel   = 1;
    aowl_wg_lmb_was  = down;
    aowl_wg_lmb_down = down;

    /* The cursor may legitimately be outside the client area (title bar,
     * another monitor) while the window still has focus. The sample is then
     * NOT ok, so a drag in progress holds its last good position rather than
     * teleporting the widget to a negative coordinate. The BUTTON state above
     * is still updated, because a release that happens off the client area is
     * still a release. */
    if (x < 0 || y < 0 || x >= w || y >= h) return 0;

    aowl_wg_ms_ok = 1;
    return 1;
}

static int32_t aowl_wg_mouse_sample(void) {
    POINT p;
    RECT  rc;
    HWND  h;
    DWORD pid = 0;

    h = GetForegroundWindow();
    if (!h) return aowl_wg_mouse_apply(0, 0, 0, 0, 0, 0, 0);
    GetWindowThreadProcessId(h, &pid);
    if (pid != GetCurrentProcessId())
        return aowl_wg_mouse_apply(0, 0, 0, 0, 0, 0, 0);
    if (!GetClientRect(h, &rc))  return aowl_wg_mouse_apply(1, 0, 0, 0, 0, 0, 0);
    if (!GetCursorPos(&p))       return aowl_wg_mouse_apply(1, 0, 0, 0, 0, 0, 0);
    if (!ScreenToClient(h, &p))  return aowl_wg_mouse_apply(1, 0, 0, 0, 0, 0, 0);

    return aowl_wg_mouse_apply(1, 1, (int32_t)p.x, (int32_t)p.y,
                               (int32_t)(rc.right - rc.left),
                               (int32_t)(rc.bottom - rc.top),
                               (GetAsyncKeyState(VK_LBUTTON) & 0x8000) ? 1 : 0);
}

static int32_t aowl_wg_mouse_ok(void) { return aowl_wg_ms_ok; }
static int32_t aowl_wg_mouse_x(void)  { return aowl_wg_ms_x; }
static int32_t aowl_wg_mouse_y(void)  { return aowl_wg_ms_y; }
static int32_t aowl_wg_client_w(void) { return aowl_wg_ms_w; }
static int32_t aowl_wg_client_h(void) { return aowl_wg_ms_h; }
static int32_t aowl_wg_lmb_held(void)     { return aowl_wg_lmb_down; }
static int32_t aowl_wg_lmb_pressed(void)  { return aowl_wg_lmb_press; }
static int32_t aowl_wg_lmb_released(void) { return aowl_wg_lmb_rel; }

/* THE GAME WINDOW'S CLIENT SIZE, INDEPENDENT OF FOCUS AND OF THE OVERLAY.
 *
 * `aowl_wg_mouse_sample` above needs the foreground window, because a drag that
 * worked while the game was in the background would be a global input grab.
 * PUBLISHING THE SCREEN SIZE has the opposite requirement: it must keep working
 * while the player is alt-tabbed, or the region's screen size would go stale
 * exactly when a participant is most likely to be laying out against it.
 *
 * `GetActiveWindow()` is the answer: it returns the calling THREAD's active
 * window, and this is called from the Unity thread, which is the thread that
 * owns the game's window. No focus is required. `GetForegroundWindow` with a
 * PID check is the fallback for the case where the Unity thread is not the
 * window's owner.
 *
 * Returns 1 and writes a real size, or returns 0 and writes nothing. A refusal
 * must never be a zero the caller stores: see the note on
 * `aowl_region_set_screen`, which refuses a non-positive size for the same
 * reason. */
static int32_t aowl_wg_window_size(int32_t* w, int32_t* h) {
    RECT rc;
    HWND hw;
    DWORD pid = 0;
    if (!w || !h) return 0;
    hw = GetActiveWindow();
    if (!hw) {
        hw = GetForegroundWindow();
        if (!hw) return 0;
        GetWindowThreadProcessId(hw, &pid);
        if (pid != GetCurrentProcessId()) return 0;
    }
    if (!GetClientRect(hw, &rc)) return 0;
    if (rc.right <= rc.left || rc.bottom <= rc.top) return 0;
    *w = (int32_t)(rc.right - rc.left);
    *h = (int32_t)(rc.bottom - rc.top);
    return 1;
}

/* The two halves separately, for a Nim caller that has no out-parameters
 * convention here. Both return 0 on a refusal, and a caller must treat 0 as
 * "unknown" -- which is exactly why `aowl_region_set_screen` drops it rather
 * than storing it. */
static int32_t aowl_wg_window_w(void) {
    int32_t w = 0, h = 0;
    return aowl_wg_window_size(&w, &h) ? w : 0;
}
static int32_t aowl_wg_window_h(void) {
    int32_t w = 0, h = 0;
    return aowl_wg_window_size(&w, &h) ? h : 0;
}

/* Ctrl, for the Ctrl+F3 edit-mode toggle. Async, like everything else here. */
static int32_t aowl_wg_ctrl_down(void) {
    return (GetAsyncKeyState(VK_CONTROL) & 0x8000) ? 1 : 0;
}

/* ================================================================== *
 * 2. MEMORY
 *
 * `K32GetProcessMemoryInfo` is in kernel32 on every Windows this build runs on,
 * but it is resolved DYNAMICALLY anyway: an import that does not resolve is a
 * load failure of the whole host DLL, and a memory read-out is not worth that
 * risk. A refusal here is the widget printing "unavailable", never a crash.
 * ================================================================== */

typedef struct AowlWgPmc {
    DWORD  cb;
    DWORD  PageFaultCount;
    SIZE_T PeakWorkingSetSize;
    SIZE_T WorkingSetSize;
    SIZE_T QuotaPeakPagedPoolUsage;
    SIZE_T QuotaPagedPoolUsage;
    SIZE_T QuotaPeakNonPagedPoolUsage;
    SIZE_T QuotaNonPagedPoolUsage;
    SIZE_T PagefileUsage;
    SIZE_T PeakPagefileUsage;
    SIZE_T PrivateUsage;
} AowlWgPmc;

typedef BOOL (WINAPI *AowlWgPmcFn)(HANDLE, AowlWgPmc*, DWORD);
static AowlWgPmcFn aowl_wg_pmc_fn = 0;
static int32_t     aowl_wg_pmc_tried = 0;

static int64_t aowl_wg_ws_mb   = -1;
static int64_t aowl_wg_priv_mb = -1;
static int64_t aowl_wg_sys_pct = -1;
static int64_t aowl_wg_sys_free_mb = -1;

static void aowl_wg_mem_sample(void) {
    AowlWgPmc pmc;
    MEMORYSTATUSEX ms;
    if (!aowl_wg_pmc_tried) {
        HMODULE k;
        aowl_wg_pmc_tried = 1;
        k = GetModuleHandleA("kernel32.dll");
        if (k) aowl_wg_pmc_fn =
            (AowlWgPmcFn)(void*)GetProcAddress(k, "K32GetProcessMemoryInfo");
        if (!aowl_wg_pmc_fn) {
            HMODULE ps = GetModuleHandleA("psapi.dll");
            if (ps) aowl_wg_pmc_fn =
                (AowlWgPmcFn)(void*)GetProcAddress(ps, "GetProcessMemoryInfo");
        }
    }
    if (aowl_wg_pmc_fn) {
        memset(&pmc, 0, sizeof(pmc));
        pmc.cb = (DWORD)sizeof(pmc);
        if (aowl_wg_pmc_fn(GetCurrentProcess(), &pmc, (DWORD)sizeof(pmc))) {
            aowl_wg_ws_mb   = (int64_t)(pmc.WorkingSetSize >> 20);
            aowl_wg_priv_mb = (int64_t)(pmc.PrivateUsage   >> 20);
        }
    }
    memset(&ms, 0, sizeof(ms));
    ms.dwLength = (DWORD)sizeof(ms);
    if (GlobalMemoryStatusEx(&ms)) {
        aowl_wg_sys_pct     = (int64_t)ms.dwMemoryLoad;
        aowl_wg_sys_free_mb = (int64_t)(ms.ullAvailPhys >> 20);
    }
}
static int64_t aowl_wg_ws(void)       { return aowl_wg_ws_mb; }
static int64_t aowl_wg_priv(void)     { return aowl_wg_priv_mb; }
static int64_t aowl_wg_sysload(void)  { return aowl_wg_sys_pct; }
static int64_t aowl_wg_sysfree(void)  { return aowl_wg_sys_free_mb; }

/* ================================================================== *
 * 3. THE REGION VIEW -- DECLARATIONS ONLY
 *
 * The definitions live in `abi/aowlspt_regview.h`, which `region.nim` includes
 * immediately after its own HOST-mode include of `aowlspt_region.h`.
 *
 * THIS SPLIT IS NOT STYLE. The whole host -- `aowlhost.nim` and every file it
 * `include`s, this one among them -- compiles to ONE C translation unit, and
 * `region.nim` is the single place in it that defines `AOWL_REGION_HOST` and so
 * owns `g_region`. `debugui.nim` is included BEFORE `region.nim`, so if this
 * header pulled in `aowlspt_region.h` at all, its include guard would win and
 * `region.nim`'s host-mode include would expand to nothing: the dispatcher, the
 * registry and every `aowl_region_*` function would vanish from the build. That
 * is exactly what happened on the first attempt -- nine `implicit declaration
 * of aowl_region_*` errors, none of them in a file that had been touched.
 *
 * So the widget side declares, and never defines, and never sees the struct.
 * Every accessor returns a scalar or a `const char*`, so no layout knowledge
 * crosses the line and there is no second copy of anything.
 * ================================================================== */

extern int32_t     aowl_wg_rg_max(void);
extern int32_t     aowl_wg_rg_select(int32_t h);
extern const char* aowl_wg_rg_name_of(void);
extern const char* aowl_wg_rg_reason_of(void);
extern int64_t     aowl_wg_rg_budget(void);
extern int64_t     aowl_wg_rg_last(void);
extern int64_t     aowl_wg_rg_max_us(void);
extern int64_t     aowl_wg_rg_calls(void);
extern int64_t     aowl_wg_rg_skipped(void);
extern int32_t     aowl_wg_rg_faults(void);
extern int32_t     aowl_wg_rg_overruns(void);
extern int32_t     aowl_wg_rg_enabled(void);
extern int32_t     aowl_wg_rg_disabled(void);
extern int32_t     aowl_wg_rg_throttled(void);
extern int32_t     aowl_wg_rg_armed(void);

/* THE SUBMITTER SIDE. Defined in `aowlspt_regview.h`, for the same reason and
 * with the same discipline as the read-only view above: scalars and a
 * `const char*` cross the line, never a struct.
 *
 * The F3 widgets DRAW THROUGH THESE, into the shared region, and are
 * rasterised by the D3D11 overlay in `Present` -- the same path the F12 panel
 * and the F6 admin HUD use. They no longer clone a TextMeshProUGUI, no longer
 * walk Unity's canvas tree, and no longer have anything that can be
 * "successfully built" and invisible. */
extern int32_t     aowl_wg_dr_fill(float x, float y, float w, float h,
                                   uint32_t col);
extern int32_t     aowl_wg_dr_box(float x, float y, float w, float h, float t,
                                  uint32_t col);
extern int32_t     aowl_wg_dr_text(float x, float y, const char* s,
                                   uint32_t col, int32_t scale);
extern int32_t     aowl_wg_scr_w(void);
extern int32_t     aowl_wg_scr_h(void);
extern int32_t     aowl_wg_scr_known(void);
extern int32_t     aowl_wg_rg_register(const char* name,
                                       void (*fn)(void*, int64_t),
                                       int32_t mask, int32_t order,
                                       int32_t budgetUs);
extern const char* aowl_wg_rg_refusal_text(int32_t r);
extern int32_t     aowl_wg_rg_mask_draw(void);

/* ================================================================== *
 * 4. THE BREADCRUMB
 *
 * WHY THIS EXISTS. The overlay's per-frame body runs under ONE `aowl_p_p_seh`.
 * That guard is doing its job -- a fault costs a skipped refresh and the client
 * is unaffected -- but the report it produced said only "fault #1 caught by the
 * VEH guard". That is a fault report with NO LOCATION, and it cost a live
 * session: the panel drew nothing, self-disabled after eight faults, and the
 * log could not say which of forty steps had died.
 *
 * A guard cannot tell you where it caught something, because the stack is gone
 * by the time it regains control. So the body leaves a trail instead: one plain
 * `int32_t` store per stage, into a file-scope variable that SURVIVES the
 * longjmp because it is neither on the stack nor in a register. After the guard
 * returns null, the handler reads the last crumb and names the stage.
 *
 * The cost is one aligned 4-byte store per stage on a throttled refresh. That
 * is not a per-frame cost worth optimising and it must not be made conditional:
 * a breadcrumb you have to turn on is a breadcrumb that is off when you need it.
 *
 * `aowl_wg_crumb_widget` is the second half: it names WHICH widget the body was
 * rendering, so a single misbehaving widget can be identified and skipped
 * rather than taking the whole overlay dark with it.
 * ================================================================== */

enum {
    AOWL_WG_CRUMB_NONE      = 0,
    AOWL_WG_CRUMB_ENTER     = 1,
    AOWL_WG_CRUMB_TOGGLE    = 2,
    AOWL_WG_CRUMB_BUILD     = 3,   /* retired with the clone path      */
    AOWL_WG_CRUMB_SCANWORLD = 4,
    AOWL_WG_CRUMB_MOUSE     = 5,
    AOWL_WG_CRUMB_EDITKEYS  = 6,
    AOWL_WG_CRUMB_DRAG      = 7,
    AOWL_WG_CRUMB_WTEXT     = 8,   /* composing a widget's text        */
    AOWL_WG_CRUMB_WPLACE    = 9,   /* laying out a widget's rect       */
    AOWL_WG_CRUMB_WSTYLE    = 10,
    AOWL_WG_CRUMB_WSETTEXT  = 11,
    AOWL_WG_CRUMB_WSHOW     = 12,
    AOWL_WG_CRUMB_BANNER    = 13,
    AOWL_WG_CRUMB_HIDEREST  = 14,  /* retired: nothing persists now    */
    AOWL_WG_CRUMB_MARKERS   = 15,
    AOWL_WG_CRUMB_DONE      = 16
};

/* THE STAGES NUMBERED 17..43 ARE DELETED, not renumbered and not left
 * dormant. They named steps inside the old Unity-UI path -- cloning a
 * TextMeshProUGUI, walking up to a canvas root, dropping a nested Canvas --
 * and that path is gone: the F3 widgets now submit screen-space draw commands
 * to the shared region and the D3D11 overlay rasterises them in `Present`,
 * exactly as the F12 panel and the F6 admin HUD are. A crumb for a stage that
 * can no longer be reached is a stage a future fault report can NAME, and a
 * confidently wrong location is worse than none.
 *
 * `aowl_wg_crumb_widget` therefore now carries EXACTLY ONE meaning -- a widget
 * index -- where it used to carry three (widget index, clone-pool index, and a
 * packed `depth * 4 + role`). The two decoders for the other meanings went
 * with them, for the same reason. */


static volatile int32_t aowl_wg_crumb_stage  = 0;
static volatile int32_t aowl_wg_crumb_widget = -1;

/* ==================================================================
 * PER-STAGE COST ACCOUNTING -- the crumb seams, timed
 * ==================================================================
 *
 * WHY THIS EXISTS. The shared region already times the WHOLE `debugui`
 * participant against its budget, and in a live raid it reported 22,000 to
 * 40,000 us against 900 us, sustained, with the peak CLIMBING. That number
 * names the participant and nothing else: it cannot distinguish "the world
 * census is walking more bots than it used to" from "composing a widget's
 * text re-reads every field every frame". A total with no breakdown is the
 * measurement equivalent of a check that cannot fail -- it can only ever say
 * "debugui is slow", which was already known.
 *
 * WHY IT COSTS ALMOST NOTHING. It reuses the breadcrumb call sites, which
 * already bracket exactly the 16 stages of a refresh, so there are NO new
 * call sites to keep in step with the code. A crumb becomes one
 * QueryPerformanceCounter (~20-25 ns on this machine) and an add: with
 * ~7 frame-level crumbs plus 5 per widget, a frame of 8 widgets pays about
 * 47 QPCs, on the order of 1-2 us against a 900 us budget.
 *
 * WHAT IS CHARGED TO WHAT. The interval between two crumbs is charged to the
 * stage named by the EARLIER one -- that is the stage that was actually
 * running. `aowl_wg_crumb_w` charges first and switches second, for the same
 * reason: without that, widget A's composition time lands on widget B.
 *
 * THREE STATES, NOT TWO. Accumulation only happens between
 * `aowl_wg_stage_begin` and `aowl_wg_stage_end`. Outside that window --
 * including the separate PreloaderUI detour body, which also drops crumbs --
 * `aowl_wg_st_open` is 0 and every charge is dropped rather than attributed
 * to whatever stage happened to be current. `aowl_wg_stage_frames()` is 0
 * until a frame has completed, so a reader can tell "nothing measured yet"
 * from "measured, and it was cheap"; every getter returns -1 in that state.
 *
 * Ticks are accumulated raw and converted to microseconds only on READ, so
 * the per-crumb path has no division in it.
 *
 * Unity thread only. No lock, and none is needed: one writer.
 */
#define AOWL_WG_STAGE_MAX   17   /* crumb ids 0..16                        */
#define AOWL_WG_STAGEW_MAX  16   /* widget indices charged individually    */

static int64_t aowl_wg_st_qpf  = 0;
static int64_t aowl_wg_st_mark = 0;
static int32_t aowl_wg_st_prev = -1;
static int32_t aowl_wg_st_open = 0;
static int64_t aowl_wg_st_cur  [AOWL_WG_STAGE_MAX];
static int64_t aowl_wg_st_last [AOWL_WG_STAGE_MAX];
static int64_t aowl_wg_st_peak [AOWL_WG_STAGE_MAX];
static int64_t aowl_wg_st_worst[AOWL_WG_STAGE_MAX];   /* the worst FRAME's
                                                       * breakdown, kept as
                                                       * one coherent set */
static int64_t aowl_wg_stw_cur [AOWL_WG_STAGEW_MAX];
static int64_t aowl_wg_stw_last[AOWL_WG_STAGEW_MAX];
static int64_t aowl_wg_stw_peak[AOWL_WG_STAGEW_MAX];
static int64_t aowl_wg_st_frame_t   = 0;   /* last complete frame, ticks   */
static int64_t aowl_wg_st_worst_t   = 0;
static int64_t aowl_wg_st_frames    = 0;
static int64_t aowl_wg_st_backwards = 0;   /* QPC went backwards N times   */

static int64_t aowl_wg_st_us(int64_t ticks) {
    if (aowl_wg_st_qpf <= 0) return -1;
    return (int64_t)((ticks * 1000000ll) / aowl_wg_st_qpf);
}

static void aowl_wg_st_charge(void) {
    LARGE_INTEGER c;
    int64_t d;
    if (!aowl_wg_st_open) return;
    if (!QueryPerformanceCounter(&c)) return;
    d = c.QuadPart - aowl_wg_st_mark;
    aowl_wg_st_mark = c.QuadPart;
    /* A negative delta is not a fast stage; it is a broken clock. Counting it
     * would make the hot stage look cheap, so it is dropped AND counted. */
    if (d < 0) { aowl_wg_st_backwards++; return; }
    if (aowl_wg_st_prev >= 0 && aowl_wg_st_prev < AOWL_WG_STAGE_MAX)
        aowl_wg_st_cur[aowl_wg_st_prev] += d;
    if (aowl_wg_crumb_widget >= 0 && aowl_wg_crumb_widget < AOWL_WG_STAGEW_MAX)
        aowl_wg_stw_cur[aowl_wg_crumb_widget] += d;
}

static void aowl_wg_crumb(int32_t stage) {
    aowl_wg_st_charge();
    aowl_wg_st_prev = stage;
    aowl_wg_crumb_stage = stage;
}
static void aowl_wg_crumb_w(int32_t idx) {
    aowl_wg_st_charge();
    aowl_wg_crumb_widget = idx;
}
static int32_t aowl_wg_crumb_get(void)   { return aowl_wg_crumb_stage; }
static int32_t aowl_wg_crumb_get_w(void) { return aowl_wg_crumb_widget; }

static void aowl_wg_stage_begin(void) {
    LARGE_INTEGER f, c;
    int i;
    if (aowl_wg_st_qpf <= 0) {
        if (!QueryPerformanceFrequency(&f) || f.QuadPart <= 0) return;
        aowl_wg_st_qpf = f.QuadPart;
    }
    for (i = 0; i < AOWL_WG_STAGE_MAX;  i++) aowl_wg_st_cur[i]  = 0;
    for (i = 0; i < AOWL_WG_STAGEW_MAX; i++) aowl_wg_stw_cur[i] = 0;
    if (!QueryPerformanceCounter(&c)) return;
    aowl_wg_st_mark = c.QuadPart;
    aowl_wg_st_prev = -1;
    aowl_wg_st_open = 1;
}

static void aowl_wg_stage_end(void) {
    int i;
    int64_t tot = 0;
    if (!aowl_wg_st_open) return;
    aowl_wg_st_charge();
    aowl_wg_st_open = 0;
    for (i = 0; i < AOWL_WG_STAGE_MAX; i++) {
        aowl_wg_st_last[i] = aowl_wg_st_cur[i];
        if (aowl_wg_st_cur[i] > aowl_wg_st_peak[i])
            aowl_wg_st_peak[i] = aowl_wg_st_cur[i];
        tot += aowl_wg_st_cur[i];
    }
    for (i = 0; i < AOWL_WG_STAGEW_MAX; i++) {
        aowl_wg_stw_last[i] = aowl_wg_stw_cur[i];
        if (aowl_wg_stw_cur[i] > aowl_wg_stw_peak[i])
            aowl_wg_stw_peak[i] = aowl_wg_stw_cur[i];
    }
    aowl_wg_st_frame_t = tot;
    aowl_wg_st_frames++;
    if (tot > aowl_wg_st_worst_t) {
        aowl_wg_st_worst_t = tot;
        for (i = 0; i < AOWL_WG_STAGE_MAX; i++)
            aowl_wg_st_worst[i] = aowl_wg_st_cur[i];
    }
}

/* Readers. -1 everywhere means NOT MEASURED YET -- never 0, because 0 us is a
 * legitimate answer for a stage that did nothing and must not be confused
 * with "I could not look". */
static int64_t aowl_wg_stage_frames(void) { return aowl_wg_st_frames; }
static int32_t aowl_wg_stage_count(void)  { return AOWL_WG_STAGE_MAX; }
static int32_t aowl_wg_stage_wcount(void) { return AOWL_WG_STAGEW_MAX; }
static int64_t aowl_wg_stage_backwards(void) { return aowl_wg_st_backwards; }

static int64_t aowl_wg_stage_us(int32_t i) {
    if (aowl_wg_st_frames <= 0 || i < 0 || i >= AOWL_WG_STAGE_MAX) return -1;
    return aowl_wg_st_us(aowl_wg_st_last[i]);
}
static int64_t aowl_wg_stage_peak_us(int32_t i) {
    if (aowl_wg_st_frames <= 0 || i < 0 || i >= AOWL_WG_STAGE_MAX) return -1;
    return aowl_wg_st_us(aowl_wg_st_peak[i]);
}
static int64_t aowl_wg_stage_worst_us(int32_t i) {
    if (aowl_wg_st_frames <= 0 || i < 0 || i >= AOWL_WG_STAGE_MAX) return -1;
    return aowl_wg_st_us(aowl_wg_st_worst[i]);
}
static int64_t aowl_wg_stage_w_us(int32_t i) {
    if (aowl_wg_st_frames <= 0 || i < 0 || i >= AOWL_WG_STAGEW_MAX) return -1;
    return aowl_wg_st_us(aowl_wg_stw_last[i]);
}
static int64_t aowl_wg_stage_w_peak_us(int32_t i) {
    if (aowl_wg_st_frames <= 0 || i < 0 || i >= AOWL_WG_STAGEW_MAX) return -1;
    return aowl_wg_st_us(aowl_wg_stw_peak[i]);
}
static int64_t aowl_wg_stage_frame_us(void) {
    if (aowl_wg_st_frames <= 0) return -1;
    return aowl_wg_st_us(aowl_wg_st_frame_t);
}
static int64_t aowl_wg_stage_worst_total_us(void) {
    if (aowl_wg_st_frames <= 0) return -1;
    return aowl_wg_st_us(aowl_wg_st_worst_t);
}
/* For the offline harness and for a deliberate "start measuring from here". */
static void aowl_wg_stage_reset(void) {
    int i;
    for (i = 0; i < AOWL_WG_STAGE_MAX; i++) {
        aowl_wg_st_cur[i] = aowl_wg_st_last[i] = 0;
        aowl_wg_st_peak[i] = aowl_wg_st_worst[i] = 0;
    }
    for (i = 0; i < AOWL_WG_STAGEW_MAX; i++)
        aowl_wg_stw_cur[i] = aowl_wg_stw_last[i] = aowl_wg_stw_peak[i] = 0;
    aowl_wg_st_frame_t = 0; aowl_wg_st_worst_t = 0;
    aowl_wg_st_frames = 0; aowl_wg_st_backwards = 0;
    aowl_wg_st_open = 0; aowl_wg_st_prev = -1;
}

static const char* aowl_wg_crumb_text(int32_t s) {
    switch (s) {
    case AOWL_WG_CRUMB_ENTER:     return "entering the body";
    case AOWL_WG_CRUMB_TOGGLE:    return "reading the toggle key";
    case AOWL_WG_CRUMB_SCANWORLD: return "duScanWorld (walking RegisteredPlayers)";
    case AOWL_WG_CRUMB_MOUSE:     return "sampling the pointer";
    case AOWL_WG_CRUMB_EDITKEYS:  return "edit-mode keys";
    case AOWL_WG_CRUMB_DRAG:      return "the drag step";
    case AOWL_WG_CRUMB_WTEXT:     return "composing a widget's text";
    case AOWL_WG_CRUMB_WPLACE:    return "laying out a widget's rect";
    case AOWL_WG_CRUMB_WSTYLE:    return "the widget backing plate and frame";
    case AOWL_WG_CRUMB_WSETTEXT:  return "submitting a widget's TEXT commands";
    case AOWL_WG_CRUMB_WSHOW:     return "finishing a widget";
    case AOWL_WG_CRUMB_BANNER:    return "the edit-mode banner";
    case AOWL_WG_CRUMB_MARKERS:   return "the ESP markers";
    case AOWL_WG_CRUMB_DONE:      return "finished (fault came from elsewhere)";
    default:                      return "nothing recorded";
    }
}

#endif /* AOWLSPT_WIDGET_H */
