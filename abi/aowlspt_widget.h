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
static int32_t aowl_wg_mouse_sample(void) {
    POINT p;
    RECT  rc;
    HWND  h;
    DWORD pid = 0;
    int32_t down;

    aowl_wg_ms_ok = 0;
    aowl_wg_lmb_press = 0;
    aowl_wg_lmb_rel   = 0;

    h = GetForegroundWindow();
    if (!h) { aowl_wg_lmb_was = 0; aowl_wg_lmb_down = 0; return 0; }
    GetWindowThreadProcessId(h, &pid);
    if (pid != GetCurrentProcessId()) {
        /* Not our window. Forget the button entirely rather than carry a held
         * state across a focus change -- otherwise alt-tabbing away mid-drag
         * and clicking elsewhere comes back as a release we act on. */
        aowl_wg_lmb_was = 0; aowl_wg_lmb_down = 0;
        return 0;
    }
    if (!GetClientRect(h, &rc)) return 0;
    if (rc.right <= rc.left || rc.bottom <= rc.top) return 0;
    if (!GetCursorPos(&p)) return 0;
    if (!ScreenToClient(h, &p)) return 0;

    aowl_wg_ms_w = (int32_t)(rc.right - rc.left);
    aowl_wg_ms_h = (int32_t)(rc.bottom - rc.top);
    aowl_wg_ms_x = (int32_t)p.x;
    aowl_wg_ms_y = (int32_t)p.y;

    down = (GetAsyncKeyState(VK_LBUTTON) & 0x8000) ? 1 : 0;
    if (down && !aowl_wg_lmb_was)  aowl_wg_lmb_press = 1;
    if (!down && aowl_wg_lmb_was)  aowl_wg_lmb_rel   = 1;
    aowl_wg_lmb_was  = down;
    aowl_wg_lmb_down = down;

    /* The cursor may legitimately be outside the client area (title bar,
     * another monitor) while the window still has focus. The sample is then
     * NOT ok, so a drag in progress holds its last good position rather than
     * teleporting the widget to a negative coordinate. */
    if (p.x < 0 || p.y < 0 || p.x >= aowl_wg_ms_w || p.y >= aowl_wg_ms_h)
        return 0;

    aowl_wg_ms_ok = 1;
    return 1;
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
    AOWL_WG_CRUMB_BUILD     = 3,
    AOWL_WG_CRUMB_SCANWORLD = 4,
    AOWL_WG_CRUMB_MOUSE     = 5,
    AOWL_WG_CRUMB_EDITKEYS  = 6,
    AOWL_WG_CRUMB_DRAG      = 7,
    AOWL_WG_CRUMB_WTEXT     = 8,   /* composing a widget's text        */
    AOWL_WG_CRUMB_WPLACE    = 9,   /* duPlace on a widget              */
    AOWL_WG_CRUMB_WSTYLE    = 10,
    AOWL_WG_CRUMB_WSETTEXT  = 11,
    AOWL_WG_CRUMB_WSHOW     = 12,
    AOWL_WG_CRUMB_BANNER    = 13,
    AOWL_WG_CRUMB_HIDEREST  = 14,
    AOWL_WG_CRUMB_MARKERS   = 15,
    AOWL_WG_CRUMB_DONE      = 16,

    /* INSIDE duBuild. The live run narrowed the fault to "cloning the label
     * pool", which is still a dozen distinct managed operations -- so the
     * build path gets its own stages rather than another round of guessing.
     * `aowl_wg_crumb_w` doubles as the CLONE INDEX in the two pool loops. */
    AOWL_WG_CRUMB_B_ANCHOR   = 17,  /* duFindAnchor                        */
    AOWL_WG_CRUMB_B_ROOT     = 18,  /* duCanvasRootGo                      */
    AOWL_WG_CRUMB_B_PROBECLONE = 19,/* Instantiate for the probe           */
    AOWL_WG_CRUMB_B_PROBEDRAW  = 20,/* duMakeDrawable on the probe         */
    AOWL_WG_CRUMB_B_SRCCANVAS  = 21,/* reading the SOURCE's m_Canvas       */
    AOWL_WG_CRUMB_B_PROBECANVAS= 22,/* reading the PROBE's m_Canvas        */
    AOWL_WG_CRUMB_B_DROPCANVAS = 23,/* duDropNestedCanvas                  */
    AOWL_WG_CRUMB_B_ASSERTLOG  = 24,/* the assertion's own describe calls  */
    AOWL_WG_CRUMB_B_PROBEREUSE = 25,/* style+drawable on the reused probe  */
    AOWL_WG_CRUMB_B_PANELCLONE = 26,/* pool clone loop; crumb_w = index    */
    AOWL_WG_CRUMB_B_PANELDRAW  = 27,/* style+drawable on a pool clone      */
    AOWL_WG_CRUMB_B_MARKCLONE  = 28,/* marker clone loop; crumb_w = index  */
    AOWL_WG_CRUMB_B_MARKDRAW   = 29,
    AOWL_WG_CRUMB_B_SCALE      = 30,/* reading the canvas scaleFactor      */
    AOWL_WG_CRUMB_B_DIAGDUMP   = 31,/* duDiagDump                          */
    AOWL_WG_CRUMB_B_READBACK   = 32,/* the placement read-back             */

    /* INSIDE duCanvasRootGo -- the canvas-root walk, which the second live run
     * named. Every one of these is a MANAGED CALL on a UnityEngine.Object whose
     * native half may be gone (Unity's "fake null"), so each hop gets its own
     * crumb and its own liveness gate. */
    AOWL_WG_CRUMB_R_ANCHORALIVE = 33,
    AOWL_WG_CRUMB_R_RECT        = 34, /* duRectOf -> Component::get_transform */
    AOWL_WG_CRUMB_R_RECTALIVE   = 35,
    AOWL_WG_CRUMB_R_PARENT      = 36, /* Transform::get_parent                */
    AOWL_WG_CRUMB_R_PARSANE     = 37, /* duRectIsSane -> get_rect (sret)      */
    AOWL_WG_CRUMB_R_PARGO       = 38, /* Component::get_gameObject            */
    AOWL_WG_CRUMB_R_CANVAS      = 39, /* route 2                              */
    AOWL_WG_CRUMB_R_CLIMB       = 40, /* route 3                              */
    AOWL_WG_CRUMB_R_DONE        = 41
};

static volatile int32_t aowl_wg_crumb_stage  = 0;
static volatile int32_t aowl_wg_crumb_widget = -1;

static void aowl_wg_crumb(int32_t stage) { aowl_wg_crumb_stage = stage; }
static void aowl_wg_crumb_w(int32_t idx) { aowl_wg_crumb_widget = idx; }
static int32_t aowl_wg_crumb_get(void)   { return aowl_wg_crumb_stage; }
static int32_t aowl_wg_crumb_get_w(void) { return aowl_wg_crumb_widget; }

static const char* aowl_wg_crumb_text(int32_t s) {
    switch (s) {
    case AOWL_WG_CRUMB_ENTER:     return "entering the body";
    case AOWL_WG_CRUMB_TOGGLE:    return "reading the toggle key";
    case AOWL_WG_CRUMB_BUILD:     return "duBuild (cloning the label pool)";
    case AOWL_WG_CRUMB_SCANWORLD: return "duScanWorld (walking RegisteredPlayers)";
    case AOWL_WG_CRUMB_MOUSE:     return "sampling the pointer";
    case AOWL_WG_CRUMB_EDITKEYS:  return "edit-mode keys";
    case AOWL_WG_CRUMB_DRAG:      return "the drag step";
    case AOWL_WG_CRUMB_WTEXT:     return "composing a widget's text";
    case AOWL_WG_CRUMB_WPLACE:    return "placing a widget (duPlace)";
    case AOWL_WG_CRUMB_WSTYLE:    return "styling a widget (duStyle)";
    case AOWL_WG_CRUMB_WSETTEXT:  return "writing a widget's text (duSetText)";
    case AOWL_WG_CRUMB_WSHOW:     return "showing a widget (duShow)";
    case AOWL_WG_CRUMB_BANNER:    return "the edit-mode banner";
    case AOWL_WG_CRUMB_HIDEREST:  return "hiding unused labels";
    case AOWL_WG_CRUMB_MARKERS:   return "the ESP markers";
    case AOWL_WG_CRUMB_DONE:      return "finished (fault came from elsewhere)";
    case AOWL_WG_CRUMB_B_ANCHOR:      return "duBuild: duFindAnchor (locating the donor version label)";
    case AOWL_WG_CRUMB_B_ROOT:        return "duBuild: duCanvasRootGo (walking to the canvas root)";
    case AOWL_WG_CRUMB_B_PROBECLONE:  return "duBuild: Object::Instantiate for the PROBE clone";
    case AOWL_WG_CRUMB_B_PROBEDRAW:   return "duBuild: duMakeDrawable on the probe clone";
    case AOWL_WG_CRUMB_B_SRCCANVAS:   return "duBuild: reading the SOURCE label's Graphic.m_Canvas";
    case AOWL_WG_CRUMB_B_PROBECANVAS: return "duBuild: reading the PROBE clone's Graphic.m_Canvas";
    case AOWL_WG_CRUMB_B_DROPCANVAS:  return "duBuild: duDropNestedCanvas on the probe";
    case AOWL_WG_CRUMB_B_ASSERTLOG:   return "duBuild: composing the canvas-assertion log line";
    case AOWL_WG_CRUMB_B_PROBEREUSE:  return "duBuild: restyling the reused probe as panel label 0";
    case AOWL_WG_CRUMB_B_PANELCLONE:  return "duBuild: Object::Instantiate for a POOL label (index in the widget field)";
    case AOWL_WG_CRUMB_B_PANELDRAW:   return "duBuild: duStyle/duMakeDrawable on a pool label";
    case AOWL_WG_CRUMB_B_MARKCLONE:   return "duBuild: Object::Instantiate for a MARKER label (index in the widget field)";
    case AOWL_WG_CRUMB_B_MARKDRAW:    return "duBuild: duStyle/duMakeDrawable on a marker label";
    case AOWL_WG_CRUMB_B_SCALE:       return "duBuild: reading the canvas scaleFactor";
    case AOWL_WG_CRUMB_B_DIAGDUMP:    return "duBuild: duDiagDump";
    case AOWL_WG_CRUMB_B_READBACK:    return "duBuild: the placement read-back";
    case AOWL_WG_CRUMB_R_ANCHORALIVE: return "duCanvasRootGo: liveness gate on the anchor";
    case AOWL_WG_CRUMB_R_RECT:        return "duCanvasRootGo: duRectOf -> Component::get_transform on the anchor";
    case AOWL_WG_CRUMB_R_RECTALIVE:   return "duCanvasRootGo: liveness gate on the anchor's RectTransform";
    case AOWL_WG_CRUMB_R_PARENT:      return "duCanvasRootGo: Transform::get_parent";
    case AOWL_WG_CRUMB_R_PARSANE:     return "duCanvasRootGo: duRectIsSane -> RectTransform::get_rect on the parent";
    case AOWL_WG_CRUMB_R_PARGO:       return "duCanvasRootGo: Component::get_gameObject on the parent";
    case AOWL_WG_CRUMB_R_CANVAS:      return "duCanvasRootGo: route 2, the Graphic's own Canvas";
    case AOWL_WG_CRUMB_R_CLIMB:       return "duCanvasRootGo: route 3, climbing to the highest sane ancestor";
    case AOWL_WG_CRUMB_R_DONE:        return "duCanvasRootGo: finished";
    default:                      return "nothing recorded";
    }
}

#endif /* AOWLSPT_WIDGET_H */
