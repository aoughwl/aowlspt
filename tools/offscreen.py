#!/usr/bin/env python3
r"""offscreen.py -- get the Tarkov client off the user's monitors, and PROVE it.

    python tools\offscreen.py --selftest        # offline; no game needed
    python tools\offscreen.py monitors
    python tools\offscreen.py where
    python tools\offscreen.py park               # move the client off-screen
    python tools\offscreen.py park --defocus     # ...and hand focus back
    python tools\offscreen.py restore
    python tools\offscreen.py verify             # PASS/FAIL/INCONCLUSIVE
    python tools\offscreen.py throttle --seconds 90

WHY THIS EXISTS, AND WHAT IT IS NOT
-----------------------------------
The ask was a `--headless` launch arg. `docs/HEADLESS.md` already establishes
that a truly headless Tarkov client is NOT reachable from here, and
`tools/headless.py` is the no-client CI runner. Neither of those gets a raid
running while the user does something else on the same machine.

This does the next thing down, and it is the cheap 80%: the client renders
normally on the GPU, in a window, at a position that intersects **no monitor**.
Nothing appears on the user's screen. It is NOT headless and this tool never
says that it is.

THE ASSERTION IS A NEGATIVE, AND IT IS THE FINISHED STATE (CLAUDE.md 9b)
------------------------------------------------------------------------
Not "SetWindowPos returned non-zero" -- that is an assertion about our own
write, and Windows is free to ignore, clamp or re-snap a position. The check
is: **after the fact, does the client's window rectangle intersect any monitor
Windows knows about?** It is answered two independent ways and they must agree:

  1. `MonitorFromWindow(hwnd, MONITOR_DEFAULTTONULL)` -- Windows' own opinion.
     NULL means "this rect is on no display".
  2. Our own intersection of `GetWindowRect` against every rect returned by
     `EnumDisplayMonitors`.

If they DISAGREE the verdict is INCONCLUSIVE, never a pass. A minimised window
also reads as off-screen to (1) and that would be a false pass, so `IsIconic`
is checked and a minimised client is reported as MINIMISED -- a distinct,
non-passing outcome, because a minimised Unity player is exactly the case that
gets throttled.

`--selftest` runs the whole checker against a window this process creates
itself, including a NEGATIVE CONTROL: it puts that window back on the primary
monitor and requires the checker to say VISIBLE. A checker that cannot report
VISIBLE cannot report OFF-SCREEN meaningfully either.

THE THROTTLE QUESTION -- MEASURED, NOT ASSUMED
----------------------------------------------
Unity throttles a player that loses focus unless `Application.runInBackground`
is set, and a throttled client makes every timing measurement wrong. So:

  * `UnityEngine.Application::set_runInBackground` **does not exist in this
    build's metadata** -- the managed linker stripped the unused setter. We
    therefore cannot turn it on. `get_runInBackground` DOES exist, at
    RVA 0x525BE20 (sharedness=UNIQUE, real body), so the value is READABLE via
    the live inspector; `Application::get_isFocused` is at RVA 0x525BDD0
    (also UNIQUE). This tool prints those and tells you the inspector line to
    run; it does not call into the game itself.
  * `throttle` measures it behaviourally instead, off the host's own
    `frameMeter` line in `aowlspt-host.log`. The meter advances only if the
    Unity Update drain advances, so a stalled frame loop shows up as the log
    line ceasing -- which is also the "the frame loop advanced" half of the
    acceptance assertion. It needs `frameMeter` set in aowlspt-host.json.

Because we cannot force `runInBackground`, `park` defaults to LEAVING FOCUS ON
THE CLIENT. An off-screen focused window still receives the keyboard, which is
in the user's way in a different sense -- so `--defocus` exists, and `throttle`
is how you find out whether it costs you frames on this build. Do not assume
either way; the answer is a property of BSG's player settings, which are not
readable from here.

EXIT CODES   0 PASS   1 FAIL   2 INCONCLUSIVE
"""

import argparse
import ctypes
import ctypes.wintypes as w
import json
import os
import re
import sys
import time

PASS, FAIL, INCONCLUSIVE = "PASS", "FAIL", "INCONCLUSIVE"
CODE = {PASS: 0, FAIL: 1, INCONCLUSIVE: 2}

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
DEFAULT_ROOT = r"D:\Aowlspt"
CLIENT_EXE = "EscapeFromTarkov.exe"
STASH = os.path.join(REPO, "build", "offscreen-stash.json")

# Measured offline from GameAssembly.dll + the decrypted metadata on 2026-08-31
# with tools/il2cpp_resolve.py. Printed for the operator to use with the live
# inspector; NOTHING in this file calls them.
RVA_GET_RUNINBACKGROUND = 0x525BE20
RVA_GET_ISFOCUSED = 0x525BDD0

if sys.platform != "win32":
    sys.exit("offscreen.py is Windows-only: it drives user32 window placement.")

u32 = ctypes.WinDLL("user32", use_last_error=True)
k32 = ctypes.WinDLL("kernel32", use_last_error=True)

MONITOR_DEFAULTTONULL = 0
SWP_NOSIZE, SWP_NOZORDER, SWP_NOACTIVATE = 0x0001, 0x0004, 0x0010
SW_SHOWNOACTIVATE, SW_RESTORE = 4, 9
GWL_STYLE = -16
WS_VISIBLE = 0x10000000


class MONITORINFO(ctypes.Structure):
    _fields_ = [("cbSize", w.DWORD), ("rcMonitor", w.RECT),
                ("rcWork", w.RECT), ("dwFlags", w.DWORD)]


def _dpi_aware():
    """Without this, GetWindowRect on a 4K display returns VIRTUALISED
    coordinates and every rectangle we compare is quietly in the wrong space.
    Best-effort: an old Windows build simply will not have the entry point."""
    try:
        # -4 == DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
        u32.SetProcessDpiAwarenessContext.restype = w.BOOL
        if u32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4)):
            return "per-monitor-v2"
    except AttributeError:
        pass
    try:
        ctypes.WinDLL("shcore").SetProcessDpiAwareness(2)
        return "per-monitor"
    except Exception:
        pass
    try:
        u32.SetProcessDPIAware()
        return "system"
    except Exception:
        return "NONE -- rectangles below may be DPI-virtualised; treat them as INCONCLUSIVE"


MONENUMPROC = ctypes.WINFUNCTYPE(w.BOOL, w.HMONITOR, w.HDC,
                                 ctypes.POINTER(w.RECT), w.LPARAM)


def monitors():
    """Every display rectangle Windows currently reports, in virtual-screen
    coordinates. This is enumerated live rather than derived from
    SM_CXVIRTUALSCREEN, because the virtual screen is a bounding box and can
    contain holes that no monitor covers."""
    out = []

    def cb(hmon, hdc, lprc, lparam):
        mi = MONITORINFO()
        mi.cbSize = ctypes.sizeof(MONITORINFO)
        primary = False
        if u32.GetMonitorInfoW(hmon, ctypes.byref(mi)):
            primary = bool(mi.dwFlags & 1)
            r = mi.rcMonitor
        else:
            r = lprc.contents
        out.append({"left": r.left, "top": r.top, "right": r.right,
                    "bottom": r.bottom, "primary": primary})
        return True

    u32.EnumDisplayMonitors(None, None, MONENUMPROC(cb), 0)
    return out


ENUMWINDOWSPROC = ctypes.WINFUNCTYPE(w.BOOL, w.HWND, w.LPARAM)


def _title(hwnd):
    n = u32.GetWindowTextLengthW(hwnd)
    buf = ctypes.create_unicode_buffer(n + 2)
    u32.GetWindowTextW(hwnd, buf, n + 2)
    return buf.value


def pids_for(exe=CLIENT_EXE):
    import subprocess
    try:
        out = subprocess.run(["tasklist", "/FI", "IMAGENAME eq %s" % exe,
                              "/FO", "CSV", "/NH"],
                             capture_output=True, text=True, timeout=20).stdout
    except Exception:
        return None            # could not look: NOT "no processes"
    pids = []
    for ln in out.splitlines():
        parts = [p.strip('"') for p in ln.split('","')]
        if len(parts) > 1 and parts[0].lower() == exe.lower():
            try:
                pids.append(int(parts[1]))
            except ValueError:
                pass
    return pids


def top_windows_of(pids):
    """Top-level windows belonging to those pids.

    A Unity player owns several HWNDs (splash, message-only, tooltip helpers).
    We keep only windows with a non-empty client rect and the WS_VISIBLE style,
    and return them largest-first; the render window is the big one. If more
    than one qualifies the caller is told, rather than one being picked
    silently."""
    found = []

    def cb(hwnd, lparam):
        pid = w.DWORD()
        u32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
        if pid.value not in pids:
            return True
        if not (u32.GetWindowLongW(hwnd, GWL_STYLE) & WS_VISIBLE):
            return True
        r = w.RECT()
        if not u32.GetWindowRect(hwnd, ctypes.byref(r)):
            return True
        wd, ht = r.right - r.left, r.bottom - r.top
        if wd < 64 or ht < 64:
            return True
        found.append({"hwnd": hwnd, "title": _title(hwnd), "w": wd, "h": ht,
                      "rect": (r.left, r.top, r.right, r.bottom)})
        return True

    u32.EnumWindows(ENUMWINDOWSPROC(cb), 0)
    found.sort(key=lambda d: d["w"] * d["h"], reverse=True)
    return found


def rect_of(hwnd):
    r = w.RECT()
    if not u32.GetWindowRect(hwnd, ctypes.byref(r)):
        return None
    return (r.left, r.top, r.right, r.bottom)


def _overlap(a, b):
    l = max(a[0], b["left"]); t = max(a[1], b["top"])
    rt = min(a[2], b["right"]); bt = min(a[3], b["bottom"])
    if rt <= l or bt <= t:
        return 0
    return (rt - l) * (bt - t)


def classify(hwnd):
    """The whole verdict for one window. Three outcomes, and the two
    independent methods must agree or it is INCONCLUSIVE.

    Returns (verdict, state, detail-dict). `state` is one of
    OFF-SCREEN / VISIBLE / MINIMISED / GONE / DISAGREEMENT."""
    if not u32.IsWindow(hwnd):
        return INCONCLUSIVE, "GONE", {"why": "the window handle is no longer valid"}
    rc = rect_of(hwnd)
    if rc is None:
        return INCONCLUSIVE, "GONE", {"why": "GetWindowRect failed"}
    iconic = bool(u32.IsIconic(hwnd))
    mons = monitors()
    px = sum(_overlap(rc, m) for m in mons)
    win_says_none = u32.MonitorFromWindow(hwnd, MONITOR_DEFAULTTONULL) == 0
    d = {"rect": rc, "monitors": mons, "visible_pixels": px,
         "MonitorFromWindow_null": win_says_none, "iconic": iconic,
         "title": _title(hwnd)}
    if iconic:
        # A minimised window reports an off-screen rect on Windows
        # (-32000,-32000). Passing that as "off-screen" would be the exact
        # false positive this file exists to avoid: minimised is the state
        # Unity is MOST likely to throttle.
        return FAIL, "MINIMISED", d
    if win_says_none and px == 0:
        return PASS, "OFF-SCREEN", d
    if (not win_says_none) and px > 0:
        return FAIL, "VISIBLE", d
    d["why"] = ("MonitorFromWindow and the enumerated-rect intersection "
                "disagree (%s vs %d visible px). No verdict is reported from a "
                "split answer." % (win_says_none, px))
    return INCONCLUSIVE, "DISAGREEMENT", d


def park_targets(mons):
    """Candidate off-screen origins, tried in order. Windows may clamp or snap
    a position, so more than one is offered and the result is VERIFIED after
    each; nothing here trusts the SetWindowPos return value."""
    left = min(m["left"] for m in mons)
    top = min(m["top"] for m in mons)
    right = max(m["right"] for m in mons)
    bottom = max(m["bottom"] for m in mons)
    return [("right of every monitor", right + 64, top),
            ("below every monitor", left, bottom + 64),
            ("left of every monitor", left - 64, top)]


def move(hwnd, x, y):
    return bool(u32.SetWindowPos(hwnd, None, int(x), int(y), 0, 0,
                                 SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE))


def park(hwnd, mons):
    """Move a window until it verifiably intersects no monitor.

    Every candidate position is applied and then RE-CLASSIFIED. A position
    Windows silently refused looks identical to one it accepted if you only
    read the return code."""
    for why, x, y in park_targets(mons):
        move(hwnd, x, y)
        time.sleep(0.25)        # give the target's own window proc a beat
        verdict, state, d = classify(hwnd)
        if state == "OFF-SCREEN":
            return verdict, state, d, why
    verdict, state, d = classify(hwnd)
    return verdict, state, d, "no candidate position took"


def defocus(hwnd):
    """Take the foreground away from the parked window.

    SetForegroundWindow across processes is subject to Windows' foreground
    lock and MAY be refused, so the result is read back from
    GetForegroundWindow rather than from the call."""
    desk = u32.GetShellWindow() or u32.GetDesktopWindow()
    u32.SetForegroundWindow(desk)
    time.sleep(0.3)
    fg = u32.GetForegroundWindow()
    return fg != hwnd, fg


# ---------------------------------------------------------------- frame meter

FRAME_RE = re.compile(
    r"frameMeter:.*?RECENT \(last (\d+) of (\d+)\) mean=([0-9.]+)ms")
INCONC_RE = re.compile(r"frameMeter: INCONCLUSIVE")


def hostlog(root):
    return os.path.join(root, "aowlspt", "aowlspt-host.log")


def read_frame_samples(path, since_pos):
    """Every frameMeter RECENT reading appended since `since_pos`.

    Returns (samples, new_pos, saw_inconclusive). A frameMeter line that says
    INCONCLUSIVE is carried through as such -- it means the meter itself could
    not look, which is not a slow frame and must not average in as one."""
    out, inc = [], False
    try:
        size = os.path.getsize(path)
    except OSError:
        return out, since_pos, inc
    if size < since_pos:
        since_pos = 0
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        f.seek(since_pos)
        chunk = f.read()
        pos = f.tell()
    for ln in chunk.splitlines():
        if INCONC_RE.search(ln):
            inc = True
        m = FRAME_RE.search(ln)
        if m:
            out.append({"n": int(m.group(1)), "mean_ms": float(m.group(3))})
    return out, pos, inc


# ------------------------------------------------------------------- commands

def cmd_monitors(a):
    print("DPI awareness: %s" % _dpi_aware())
    for i, m in enumerate(monitors()):
        print("  monitor %d %s  (%d,%d)-(%d,%d)  %dx%d"
              % (i, "PRIMARY" if m["primary"] else "       ",
                 m["left"], m["top"], m["right"], m["bottom"],
                 m["right"] - m["left"], m["bottom"] - m["top"]))
    return 0


def _one_client_window(a):
    """(hwnd, None) or (None, (verdict, message)). Never guesses."""
    pids = pids_for(a.exe)
    if pids is None:
        return None, (INCONCLUSIVE,
                      "could not run tasklist, so I do not know whether the "
                      "client is running. This is not 'it is not running'.")
    if not pids:
        return None, (INCONCLUSIVE, "%s is not running." % a.exe)
    wins = top_windows_of(set(pids))
    if not wins:
        return None, (INCONCLUSIVE,
                      "%s is running (pid %s) but has no visible top-level "
                      "window >=64px yet. The client takes >60s to put one up; "
                      "this is 'not yet', not 'never'."
                      % (a.exe, ",".join(map(str, pids))))
    if len(wins) > 1 and not a.first:
        lines = "\n".join("    hwnd=0x%X %dx%d %r" % (x["hwnd"], x["w"], x["h"],
                                                      x["title"]) for x in wins)
        return None, (INCONCLUSIVE,
                      "%d candidate windows; refusing to pick one silently. "
                      "Re-run with --first to take the largest.\n%s"
                      % (len(wins), lines))
    return wins[0]["hwnd"], None


def _report(verdict, state, d):
    print("  state   %s" % state)
    if "title" in d:
        print("  window  %r  rect=%s" % (d["title"], d.get("rect")))
    if "visible_pixels" in d:
        print("  visible %d px across %d monitor(s); MonitorFromWindow=%s"
              % (d["visible_pixels"], len(d.get("monitors", [])),
                 "NULL (on no display)" if d["MonitorFromWindow_null"]
                 else "a monitor"))
    if "why" in d:
        print("  note    %s" % d["why"])
    print("  %s" % verdict)


def cmd_where(a):
    _dpi_aware()
    hwnd, err = _one_client_window(a)
    if err:
        print(err[1]); print("  %s" % err[0]); return CODE[err[0]]
    verdict, state, d = classify(hwnd)
    _report(verdict, state, d)
    fg = u32.GetForegroundWindow()
    print("  focus   %s" % ("the client HAS the foreground"
                            if fg == hwnd else "the client does NOT have the foreground"))
    return CODE[verdict]


def cmd_park(a):
    _dpi_aware()
    hwnd, err = _one_client_window(a)
    if err:
        print(err[1]); print("  %s" % err[0]); return CODE[err[0]]
    before = rect_of(hwnd)
    if u32.IsIconic(hwnd):
        # Restore first: you cannot park a minimised window, and leaving it
        # minimised is the throttled case.
        u32.ShowWindow(hwnd, SW_RESTORE)
        time.sleep(0.5)
        before = rect_of(hwnd)
    try:
        os.makedirs(os.path.dirname(STASH), exist_ok=True)
        with open(STASH, "w", newline="\n") as f:
            json.dump({"hwnd": hwnd, "rect": before, "at": time.time()}, f)
    except OSError as e:
        print("  warning: could not write %s (%s); `restore` will need "
              "--to X,Y" % (STASH, e))
    verdict, state, d, why = park(hwnd, monitors())
    print("  tried   %s" % why)
    _report(verdict, state, d)
    if verdict == PASS and a.defocus:
        ok, fg = defocus(hwnd)
        print("  defocus %s (foreground is now 0x%X)"
              % ("done" if ok else "REFUSED by the foreground lock -- the "
                 "client still has the keyboard", fg or 0))
        if not ok:
            print("  note    that is not a failure of the parking; it is a "
                  "separate, reported fact.")
    print("\n  NOT HEADLESS. The renderer is running and the GPU is working; "
          "the window is merely on no display.")
    return CODE[verdict]


def cmd_restore(a):
    _dpi_aware()
    hwnd, err = _one_client_window(a)
    if err:
        print(err[1]); print("  %s" % err[0]); return CODE[err[0]]
    x = y = None
    if a.to:
        try:
            x, y = [int(v) for v in a.to.split(",")]
        except ValueError:
            sys.exit("--to wants X,Y")
    else:
        try:
            with open(STASH) as f:
                st = json.load(f)
            if st.get("hwnd") != hwnd:
                print("  note: the stash was written for a different window "
                      "(0x%X); using the primary monitor origin instead."
                      % (st.get("hwnd") or 0))
            elif st.get("rect"):
                x, y = st["rect"][0], st["rect"][1]
        except (OSError, ValueError):
            pass
    if x is None:
        prim = [m for m in monitors() if m["primary"]] or monitors()
        x, y = prim[0]["left"] + 64, prim[0]["top"] + 64
    move(hwnd, x, y)
    u32.ShowWindow(hwnd, SW_SHOWNOACTIVATE)
    time.sleep(0.25)
    verdict, state, d = classify(hwnd)
    # Restoring INVERTS the verdict: here VISIBLE is the success.
    _report(PASS if state == "VISIBLE" else INCONCLUSIVE, state, d)
    return 0 if state == "VISIBLE" else 2


def cmd_verify(a):
    return cmd_where(a)


def cmd_throttle(a):
    """Behavioural: does the frame loop keep up while parked?

    Two windows of frameMeter readings -- one before the move, one after -- are
    compared. This can FAIL (the parked mean is materially worse), PASS (it is
    not), or be INCONCLUSIVE, which is the outcome whenever the meter did not
    produce enough readings in either window. It never reports a ratio computed
    from one sample."""
    _dpi_aware()
    lp = hostlog(a.root)
    if not os.path.isfile(lp):
        print("no host log at %s -- nothing to measure.\n  %s" % (lp, INCONCLUSIVE))
        return 2
    hwnd, err = _one_client_window(a)
    if err:
        print(err[1]); print("  %s" % err[0]); return CODE[err[0]]

    half = max(20, a.seconds // 2)
    pos = os.path.getsize(lp)
    print("baseline: watching %s for %ds (client where it is now)" % (
        os.path.basename(lp), half))
    time.sleep(half)
    base, pos, inc_a = read_frame_samples(lp, pos)

    verdict, state, d, why = park(hwnd, monitors())
    if verdict != PASS:
        print("  could not park the window (%s); the comparison would be "
              "meaningless.\n  %s" % (state, INCONCLUSIVE))
        return 2
    if a.defocus:
        ok, _ = defocus(hwnd)
        print("  defocus: %s" % ("done" if ok else "REFUSED -- measuring a "
                                 "still-focused window, say so"))
    print("parked (%s): watching another %ds" % (why, half))
    time.sleep(half)
    after, pos, inc_b = read_frame_samples(lp, pos)

    def mean(rows):
        return sum(r["mean_ms"] for r in rows) / len(rows) if rows else None

    ma, mb = mean(base), mean(after)
    print("\n  baseline readings %d%s  parked readings %d%s"
          % (len(base), " (meter said INCONCLUSIVE)" if inc_a else "",
             len(after), " (meter said INCONCLUSIVE)" if inc_b else ""))
    if not base or not after:
        print("  the frameMeter produced no usable reading in one or both "
              "windows. Is `frameMeter` set in aowlspt-host.json, and is the "
              "client past the menu? NOTHING is concluded about throttling.")
        print("  %s" % INCONCLUSIVE)
        return 2
    if len(base) < 2 or len(after) < 2:
        print("  fewer than two readings in a window: a single sample is not "
              "a distribution. mean %.1fms -> %.1fms is REPORTED, not judged."
              % (ma, mb))
        print("  %s" % INCONCLUSIVE)
        return 2
    ratio = mb / ma if ma else 0.0
    print("  frame interval mean %.1fms -> %.1fms  (x%.2f)" % (ma, mb, ratio))
    if ratio >= a.threshold:
        print("  FAIL: the parked client is at least %.2fx slower per frame. "
              "This build THROTTLES in this configuration, and every timing "
              "measurement taken while parked is wrong." % a.threshold)
        return 1
    print("  PASS: no material slowdown at the %.2fx threshold. Note this is "
          "one comparison on one run, not a guarantee." % a.threshold)
    return 0


def cmd_rvas(a):
    print("Application.runInBackground on this build, measured offline "
          "2026-08-31 with tools/il2cpp_resolve.py:")
    print("  set_runInBackground  ABSENT from metadata -- the managed linker "
          "stripped it. We CANNOT turn runInBackground on from here.")
    print("  get_runInBackground  RVA 0x%X  sharedness=UNIQUE" % RVA_GET_RUNINBACKGROUND)
    print("  get_isFocused        RVA 0x%X  sharedness=UNIQUE" % RVA_GET_ISFOCUSED)
    print("\nRead them live (the host log prints the module base; the "
          "inspector takes the RVA form it already understands):")
    print("  call 0x%X ()bool" % RVA_GET_RUNINBACKGROUND)
    print("  call 0x%X ()bool" % RVA_GET_ISFOCUSED)
    print("\nNOT VERIFIED LIVE BY THIS TOOL. It calls nothing in the game.")
    return 0


# -------------------------------------------------------------------- selftest

_WNDPROC = ctypes.WINFUNCTYPE(ctypes.c_longlong, w.HWND, ctypes.c_uint,
                              ctypes.c_ulonglong, ctypes.c_longlong)


class WNDCLASS(ctypes.Structure):
    _fields_ = [("style", w.UINT), ("lpfnWndProc", _WNDPROC),
                ("cbClsExtra", ctypes.c_int), ("cbWndExtra", ctypes.c_int),
                ("hInstance", w.HINSTANCE), ("hIcon", w.HICON),
                ("hCursor", w.HANDLE), ("hbrBackground", w.HBRUSH),
                ("lpszMenuName", w.LPCWSTR), ("lpszClassName", w.LPCWSTR)]


def _make_window():
    # argtypes MUST be declared. Without them ctypes guesses per call and
    # raises OverflowError on the negative LPARAM values Windows sends during
    # window creation -- the window still worked, but every message printed a
    # traceback, which is noise that would hide a real failure.
    u32.DefWindowProcW.restype = ctypes.c_longlong
    u32.DefWindowProcW.argtypes = [w.HWND, ctypes.c_uint,
                                   ctypes.c_ulonglong, ctypes.c_longlong]
    proc = _WNDPROC(lambda h, m, wp, lp: u32.DefWindowProcW(h, m, wp, lp))
    # The same rule for the HANDLES. MEASURED 2026-09-05: with no restype,
    # GetModuleHandleW's 64-bit HMODULE came back truncated to a C int, and
    # with no argtypes CreateWindowExW then re-converted that hInstance as a
    # C int and raised `argument 11: OverflowError: int too long to convert`.
    # The module base moves with ASLR, so this passed on one run and blocked
    # a deploy on the next -- a flaky gate is worse than none.
    k32.GetModuleHandleW.restype = w.HMODULE
    k32.GetModuleHandleW.argtypes = [w.LPCWSTR]
    u32.RegisterClassW.restype = w.ATOM
    u32.RegisterClassW.argtypes = [ctypes.POINTER(WNDCLASS)]
    u32.CreateWindowExW.restype = w.HWND
    u32.CreateWindowExW.argtypes = [w.DWORD, w.LPCWSTR, w.LPCWSTR, w.DWORD,
                                    ctypes.c_int, ctypes.c_int, ctypes.c_int,
                                    ctypes.c_int, w.HWND, w.HMENU,
                                    w.HINSTANCE, w.LPVOID]
    u32.SetLayeredWindowAttributes.restype = w.BOOL
    u32.SetLayeredWindowAttributes.argtypes = [w.HWND, w.COLORREF, w.BYTE,
                                               w.DWORD]
    cls = WNDCLASS()
    cls.lpfnWndProc = proc
    cls.hInstance = k32.GetModuleHandleW(None)
    cls.lpszClassName = "AowlsptOffscreenSelftest"
    if not u32.RegisterClassW(ctypes.byref(cls)):
        if ctypes.get_last_error() != 1410:      # already registered
            raise OSError("RegisterClassW failed")
    hwnd = u32.CreateWindowExW(
        0x00080080,        # WS_EX_TOOLWINDOW (no taskbar button) | WS_EX_LAYERED
        "AowlsptOffscreenSelftest", "aowlspt offscreen selftest",
        0x90000000,                    # WS_POPUP | WS_VISIBLE
        100, 100, 400, 300, None, None, cls.hInstance, None)
    if not hwnd:
        raise OSError("CreateWindowExW failed: %d" % ctypes.get_last_error())
    # Fully transparent. The selftest deliberately parks this window ON the
    # user's primary monitor as its negative control, and a solid rectangle
    # flashing over whatever they are doing is not acceptable from a tool whose
    # entire purpose is to stay out of their way. Alpha does not change the
    # window RECTANGLE, which is the only thing under test.
    u32.SetLayeredWindowAttributes(hwnd, 0, 0, 0x02)   # LWA_ALPHA, alpha 0
    return hwnd, proc, cls


def cmd_selftest(a):
    """Exercise the checker against a window we own. NO GAME REQUIRED.

    The point is the NEGATIVE CONTROL. Any checker can return OFF-SCREEN; the
    question is whether it is capable of returning anything else. So this
    demands, in order: VISIBLE on the primary monitor -> OFF-SCREEN after
    parking -> VISIBLE again after restoring -> MINIMISED (and NOT a pass)
    when iconified. If the classifier said OFF-SCREEN for all four it would be
    useless, and this selftest is what makes that impossible to ship."""
    print("aowlspt offscreen selftest -- NO GAME CLIENT IS TOUCHED")
    print("DPI awareness: %s" % _dpi_aware())
    mons = monitors()
    if not mons:
        print("  EnumDisplayMonitors returned no display. On a session with no "
              "desktop there is nothing to be off-screen FROM.")
        print("  %s" % INCONCLUSIVE)
        return 2
    print("  %d monitor(s)" % len(mons))
    prim = ([m for m in mons if m["primary"]] or mons)[0]

    hwnd, proc, cls = _make_window()
    failures = []
    try:
        def step(name, expect_state, expect_verdict):
            v, s, d = classify(hwnd)
            ok = (s == expect_state and v == expect_verdict)
            print("  %-28s got %-13s %-12s expected %s/%s   %s"
                  % (name, s, v, expect_state, expect_verdict,
                     "ok" if ok else "MISMATCH"))
            if not ok:
                failures.append("%s: got %s/%s, wanted %s/%s"
                                % (name, s, v, expect_state, expect_verdict))

        move(hwnd, prim["left"] + 100, prim["top"] + 100)
        time.sleep(0.2)
        step("on the primary monitor", "VISIBLE", FAIL)

        v, s, d, why = park(hwnd, mons)
        print("  parked via: %s" % why)
        step("parked off every monitor", "OFF-SCREEN", PASS)

        # Half-on, half-off must NOT read as off-screen. This is the case a
        # naive "is the origin outside the desktop?" check gets wrong.
        move(hwnd, prim["right"] - 40, prim["top"] + 100)
        time.sleep(0.2)
        step("straddling the right edge", "VISIBLE", FAIL)

        move(hwnd, prim["left"] + 100, prim["top"] + 100)
        time.sleep(0.2)
        u32.ShowWindow(hwnd, 6)                  # SW_MINIMIZE
        time.sleep(0.4)
        step("minimised", "MINIMISED", FAIL)
        u32.ShowWindow(hwnd, SW_RESTORE)
        time.sleep(0.3)

        # And the frameMeter parser, on a fixture -- so a regression in the
        # regex is caught without a running client.
        fix = os.path.join(REPO, "build", "offscreen-selftest.log")
        os.makedirs(os.path.dirname(fix), exist_ok=True)
        with open(fix, "w", newline="\n") as f:
            f.write("frameMeter: INCONCLUSIVE -- 3 interval(s)\n"
                    "frameMeter: LIFETIME n=900 mean=27.4ms (36fps). "
                    "RECENT (last 512 of 512) mean=31.2ms (32fps) p50 ...\n"
                    "unrelated line\n"
                    "frameMeter: LIFETIME n=1400 mean=28.0ms (35fps). "
                    "RECENT (last 512 of 512) mean=110.5ms (9fps) p50 ...\n")
        rows, _, inc = read_frame_samples(fix, 0)
        ok = (len(rows) == 2 and abs(rows[0]["mean_ms"] - 31.2) < 1e-6
              and abs(rows[1]["mean_ms"] - 110.5) < 1e-6 and inc)
        print("  %-28s got %d reading(s), inconclusive-seen=%s   %s"
              % ("frameMeter parser", len(rows), inc, "ok" if ok else "MISMATCH"))
        if not ok:
            failures.append("frameMeter parser did not read the fixture")
    finally:
        u32.DestroyWindow(hwnd)
        del proc, cls

    print("")
    if failures:
        for f in failures:
            print("  %s" % f)
        print("  FAIL -- the classifier is not trustworthy; do not use `park` "
              "to conclude anything.")
        return 1
    print("  PASS -- the classifier distinguishes VISIBLE, OFF-SCREEN, "
          "straddling and MINIMISED, and can therefore fail.")
    print("  This says NOTHING about the Tarkov client, which was not started.")
    return 0


def main():
    p = argparse.ArgumentParser(
        description="park the Tarkov client off every monitor, and prove it",
        formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    p.add_argument("command", nargs="?", default="where",
                   choices=["where", "verify", "park", "restore", "monitors",
                            "throttle", "rvas"])
    p.add_argument("--selftest", action="store_true",
                   help="run the offline classifier selftest and exit")
    p.add_argument("--root", default=DEFAULT_ROOT)
    p.add_argument("--exe", default=CLIENT_EXE)
    p.add_argument("--first", action="store_true",
                   help="if several client windows qualify, take the largest "
                        "instead of refusing")
    p.add_argument("--defocus", action="store_true",
                   help="after parking, try to hand the foreground back. May "
                        "be refused by Windows; the result is reported.")
    p.add_argument("--to", default="", help="restore: move to X,Y")
    p.add_argument("--seconds", type=int, default=120,
                   help="throttle: total wall time, split between the two "
                        "measurement windows")
    p.add_argument("--threshold", type=float, default=1.35,
                   help="throttle: parked/baseline frame-interval ratio at or "
                        "above which the run FAILS")
    a = p.parse_args()
    if a.selftest:
        return cmd_selftest(a)
    return {"where": cmd_where, "verify": cmd_verify, "park": cmd_park,
            "restore": cmd_restore, "monitors": cmd_monitors,
            "throttle": cmd_throttle, "rvas": cmd_rvas}[a.command](a)


if __name__ == "__main__":
    sys.exit(main())
