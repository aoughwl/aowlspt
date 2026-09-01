#!/usr/bin/env python3
r"""popups.py -- READ THE NATIVE ERROR POPUPS. Nothing else can.

    python tools/popups.py                 what is on screen right now
    python tools/popups.py --json
    python tools/popups.py --watch 120     poll until one appears, then report
    python tools/popups.py --all           every top-level window, not just dialogs

## Why this exists, and what it cost to learn

There is a whole class of fatal error in this stack that reaches NO LOG FILE AT
ALL. It is a native Win32 message box, put up before Unity's logging exists or
by a process that is not the game:

    "The BattlEye service is not running."
    "Unable to check the client version. Please check for client updates
     and network availability."

Both are hard stops. Neither appears in `aowlspt-host.log`, in the client's own
`Logs\` directory, in Unity's `Player.log` (which is created and left EMPTY), or
in the Windows event log. The process sits there, alive, waiting for someone to
click OK -- which is byte-for-byte the shape of the in-game error dialog the
host's `errdlg` feature was built to catch, one layer lower and invisible to it.

Measured cost on 2026-09-01: the client stopped booting and it took hours to
find, across five single-variable experiments that each correctly exonerated a
component. Every tool in this repo reads logs; the answer was never in a log.
`BEService: Stopped` was even printed early on and reasoned past, because SPT
normally bypasses BattlEye -- a fact explained away instead of tested. The first
machine-readable trace of any of it was an exit code of 35, hours later.

A dialog is a crash with a button on it. This reads the button's window.

## How it reads them

`EnumWindows` for every top-level window, then for each one that is visible and
either a dialog class (`#32770`) or owned by a process we care about, the title
plus the text of every child control (`EnumChildWindows` + `WM_GETTEXT`). That
is where a message box keeps its message: the caption is usually just the
product name, and the sentence that matters is a `Static` child.

`WM_GETTEXT` is used rather than `GetWindowTextW` for children, because
`GetWindowTextW` only crosses a process boundary for the caption -- for a
control in another process it returns empty, which would make every popup look
blank and is exactly the confidently-wrong answer this must not produce.

## Three outcomes, never two

`POPUP` (found, with the text), `NONE` (looked, nothing there) and
`INCONCLUSIVE` (could not enumerate). "I could not look" is not "nothing is
wrong" -- see CLAUDE.md 9b.
"""

from __future__ import annotations

import argparse
import ctypes
import ctypes.wintypes as wt
import json as jsonmod
import sys
import time

user32 = ctypes.WinDLL("user32", use_last_error=True)
kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

WM_GETTEXT = 0x000D
WM_GETTEXTLENGTH = 0x000E

EnumWindowsProc = ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)

user32.IsWindowVisible.argtypes = [wt.HWND]
user32.GetClassNameW.argtypes = [wt.HWND, wt.LPWSTR, ctypes.c_int]
user32.GetWindowTextW.argtypes = [wt.HWND, wt.LPWSTR, ctypes.c_int]
user32.GetWindowThreadProcessId.argtypes = [wt.HWND, ctypes.POINTER(wt.DWORD)]
user32.SendMessageTimeoutW.argtypes = [
    wt.HWND, wt.UINT, wt.WPARAM, wt.LPARAM, wt.UINT, wt.UINT,
    ctypes.POINTER(ctypes.c_size_t)]

# Processes whose windows are worth reporting even when the class is not a
# dialog. BattlEye's popup does NOT belong to the game.
OF_INTEREST = ("escapefromtarkov", "battleye", "beservice", "aowlspt")

# A message box is class #32770. Unity's own fatal window and BattlEye's are
# both ordinary dialogs, which is why this one class covers the cases measured.
DIALOG_CLASS = "#32770"

SMTO_ABORTIFHUNG = 0x0002

# Window classes that are NEVER an error popup, however interesting their
# process is. A console window belongs to our own launcher and matching it made
# the tool report a POPUP on a perfectly healthy launch -- a false positive here
# is worse than a miss, because it would train the reader to ignore the tool.
NOT_A_POPUP = ("ConsoleWindowClass", "PseudoConsoleWindow",
               "CASCADIA_HOSTING_WINDOW_CLASS", "Chrome_WidgetWin_1",
               "Shell_TrayWnd", "AlwaysOnTop_Border", "Progman", "WorkerW")


def _class_of(hwnd):
    buf = ctypes.create_unicode_buffer(256)
    user32.GetClassNameW(hwnd, buf, 256)
    return buf.value


def _caption_of(hwnd):
    buf = ctypes.create_unicode_buffer(1024)
    user32.GetWindowTextW(hwnd, buf, 1024)
    return buf.value


def _text_of(hwnd):
    """A control's text, ACROSS a process boundary.

    `GetWindowTextW` only works cross-process for a top-level caption; for a
    child control owned by another process it returns an empty string. A popup
    would then read as having no message at all -- present, and blank. So the
    control is asked directly with WM_GETTEXT, with a timeout, because the
    process showing a fatal dialog may not be pumping messages normally and a
    blocking send would hang this tool on the thing it is trying to diagnose.
    """
    n = ctypes.c_size_t(0)
    if not user32.SendMessageTimeoutW(hwnd, WM_GETTEXTLENGTH, 0, 0,
                                      SMTO_ABORTIFHUNG, 1000, ctypes.byref(n)):
        return ""
    length = int(n.value)
    if length <= 0:
        return ""
    buf = ctypes.create_unicode_buffer(length + 1)
    got = ctypes.c_size_t(0)
    if not user32.SendMessageTimeoutW(hwnd, WM_GETTEXT, length + 1,
                                      ctypes.cast(buf, ctypes.c_void_p).value,
                                      SMTO_ABORTIFHUNG, 1000, ctypes.byref(got)):
        return ""
    return buf.value


def _pid_of(hwnd):
    pid = wt.DWORD(0)
    user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    return int(pid.value)


def _proc_name(pid):
    try:
        import subprocess
        out = subprocess.run(["tasklist", "/FI", "PID eq %d" % pid, "/NH", "/FO", "CSV"],
                             capture_output=True, text=True, timeout=10).stdout
        if out.strip().startswith('"'):
            return out.split('","')[0].strip('"')
    except Exception:
        pass
    return ""


def _children_text(hwnd):
    out = []

    @EnumWindowsProc
    def cb(child, _lp):
        t = _text_of(child).strip()
        if t and t not in out:
            out.append(t)
        return True

    user32.EnumChildWindows(hwnd, cb, 0)
    return out


def scan(include_all=False):
    """Every candidate popup on screen. Raises nothing; returns a list."""
    found = []

    @EnumWindowsProc
    def cb(hwnd, _lp):
        try:
            if not user32.IsWindowVisible(hwnd):
                return True
            cls = _class_of(hwnd)
            pid = _pid_of(hwnd)
            pname = _proc_name(pid)
            interesting = any(k in pname.lower() for k in OF_INTEREST)
            if cls in NOT_A_POPUP and not include_all:
                return True
            if not include_all and cls != DIALOG_CLASS and not interesting:
                return True
            cap = _caption_of(hwnd)
            kids = _children_text(hwnd)
            # A dialog with no text anywhere is a frame, not a message.
            if not include_all and not cap and not kids:
                return True
            found.append({
                "hwnd": hwnd, "class": cls, "pid": pid, "process": pname,
                "caption": cap, "text": kids,
                # The buttons are what make it a STOP rather than a notice.
                "buttons": [t for t in kids
                            if t.lower().strip("&") in
                            ("ok", "cancel", "yes", "no", "retry", "abort",
                             "ignore", "close", "quit")],
            })
        except Exception:
            pass
        return True

    user32.EnumWindows(cb, 0)
    return found


def verdict(found, looked=True):
    if not looked:
        return "INCONCLUSIVE"
    return "POPUP" if found else "NONE"


def main():
    p = argparse.ArgumentParser(
        description="read native error popups that never reach any log",
        formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    p.add_argument("--json", action="store_true")
    p.add_argument("--all", action="store_true",
                   help="every visible top-level window, not just dialogs")
    p.add_argument("--watch", type=float, default=0.0,
                   help="poll this many seconds, returning as soon as one appears")
    a = p.parse_args()

    deadline = time.time() + a.watch
    found = []
    looked = False
    while True:
        try:
            found = scan(a.all)
            looked = True
        except Exception as e:
            print("could not enumerate windows: %s" % e)
            looked = False
        if found or time.time() >= deadline:
            break
        time.sleep(0.5)

    v = verdict(found, looked)
    if a.json:
        print(jsonmod.dumps({"verdict": v, "popups": found},
                            separators=(",", ":")))
        return 0 if v == "NONE" else (1 if v == "POPUP" else 3)

    if v == "INCONCLUSIVE":
        print("INCONCLUSIVE -- the window list could not be read, which is NOT "
              "the same as 'no popup is up'.")
        return 3
    if v == "NONE":
        print("NONE -- looked at every visible top-level window; no dialog and "
              "nothing from the game, BattlEye or aowlspt.")
        return 0

    print("POPUP -- %d native dialog(s). NONE of this reaches any log file:"
          % len(found))
    for f in found:
        print("  %s  [%s pid=%d class=%s]"
              % (f["caption"] or "(no caption)", f["process"] or "?",
                 f["pid"], f["class"]))
        for t in f["text"]:
            if t in f["buttons"]:
                continue
            print("      %s" % t)
        if f["buttons"]:
            print("      buttons: %s" % ", ".join(f["buttons"]))
    return 1


if __name__ == "__main__":
    sys.exit(main())
