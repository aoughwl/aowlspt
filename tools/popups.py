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
#
# `UnityWndClass` is the GAME'S OWN RENDER WINDOW. Measured 2026-09-01 with the
# client sitting healthy on the main menu, this tool said:
#
#     verdict: POPUP
#       class=UnityWndClass proc=EscapeFromTarkov.exe
#       caption='EscapeFromTarkov' text=[] buttons=[]
#
# It qualified only because EscapeFromTarkov.exe is in OF_INTEREST, and the old
# "no caption and no children -> skip" guard did not fire because the render
# window DOES have a caption. `run.py` polls this on its supervision loop, so a
# healthy launch returned verdict POPUP (exit 7) the moment the game window
# existed -- an unattended overnight run would abort on every iteration.
NOT_A_POPUP = ("ConsoleWindowClass", "PseudoConsoleWindow",
               "CASCADIA_HOSTING_WINDOW_CLASS", "Chrome_WidgetWin_1",
               "Shell_TrayWnd", "AlwaysOnTop_Border", "Progman", "WorkerW",
               "UnityWndClass")

BUTTON_WORDS = ("ok", "cancel", "yes", "no", "retry", "abort",
                "ignore", "close", "quit")


def buttons_in(texts):
    return [t for t in texts if t.lower().strip("&") in BUTTON_WORDS]


def is_interesting_process(pname):
    return any(k in (pname or "").lower() for k in OF_INTEREST)


def classify(rec, include_all=False):
    """PURE decision over one window record -> (is_popup, reason).

    Kept free of HWNDs deliberately: the enumeration was never the part that
    was wrong, the RULE was, and a rule that cannot be exercised without a real
    fatal dialog on screen cannot be falsified. `rec` needs only
    `class` / `process` / `caption` / `text` (list) / `buttons` (list).

    THE RULE, in order:

      1. `--all` reports everything, unfiltered. That is its whole job.
      2. A class in NOT_A_POPUP is never a popup, whatever its process.
      3. Otherwise it must be a dialog class OR belong to a process we care
         about -- unchanged.
      4. AND it must actually CARRY A MESSAGE: some child text, or buttons, or
         the `#32770` message-box class. **A caption alone is a window, not a
         message box.** This is the clause that was missing.

    Rule 4 is what keeps rule 2 from being the whole fix: adding one class name
    to a denylist only suppresses the window we happened to see. Both real
    detections this tool exists for -- the BattlEye "service is not running"
    box and the Unity "Fatal error [EscapeFromTarkov.exe]" version-check box --
    carry their sentence as `Static` CHILD TEXT, so both still pass rule 4.
    """
    if include_all:
        return True, "--all: reporting every visible top-level window"
    cls = rec.get("class") or ""
    if cls in NOT_A_POPUP:
        return False, "class %s is never an error popup" % cls
    if cls != DIALOG_CLASS and not is_interesting_process(rec.get("process")):
        return False, "not a dialog class and not a process of interest"
    if not (rec.get("text") or rec.get("buttons") or cls == DIALOG_CLASS):
        return False, ("carries no message: no child text, no buttons, and not "
                       "class %s -- a caption alone is a window, not a message "
                       "box" % DIALOG_CLASS)
    if not (rec.get("caption") or rec.get("text")):
        return False, "dialog frame with no caption and no text"
    return True, "carries a message and comes from a dialog or a watched process"


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


PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
kernel32.OpenProcess.argtypes = [wt.DWORD, wt.BOOL, wt.DWORD]
kernel32.OpenProcess.restype = wt.HANDLE
kernel32.QueryFullProcessImageNameW.argtypes = [
    wt.HANDLE, wt.DWORD, wt.LPWSTR, ctypes.POINTER(wt.DWORD)]
kernel32.CloseHandle.argtypes = [wt.HANDLE]

_pid_names = {}


def _proc_name(pid):
    """The image name for a pid, via ONE native call, cached.

    This used to shell out to `tasklist` PER WINDOW. With 30-40 visible windows
    that is 30-40 subprocesses per scan, several seconds each time -- and since
    `run.py` polls this on its supervision loop, the loop stalled and a launch
    that had already reached `host running` sat there instead of returning.
    Measured: the user watched a run go all the way into a raid while the
    supervisor was still blocked. A diagnostic tool that slows the thing it is
    watching is a bug, not a tradeoff.
    """
    if pid in _pid_names:
        return _pid_names[pid]
    name = ""
    h = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
    if h:
        try:
            buf = ctypes.create_unicode_buffer(1024)
            n = wt.DWORD(1024)
            if kernel32.QueryFullProcessImageNameW(h, 0, buf, ctypes.byref(n)):
                name = buf.value.rsplit("\\", 1)[-1]
        finally:
            kernel32.CloseHandle(h)
    _pid_names[pid] = name
    return name


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
            # Cheap rejects BEFORE the expensive per-child WM_GETTEXT walk:
            # classify with empty text/buttons, and only pay for the children
            # if the record could still qualify once they are known.
            cheap = {"class": cls, "process": pname, "caption": "",
                     "text": ["?"], "buttons": []}
            if not include_all and not classify(cheap, False)[0]:
                return True
            cap = _caption_of(hwnd)
            kids = _children_text(hwnd)
            rec = {
                "hwnd": hwnd, "class": cls, "pid": pid, "process": pname,
                "caption": cap, "text": kids,
                # The buttons are what make it a STOP rather than a notice.
                "buttons": buttons_in(kids),
            }
            ok, why = classify(rec, include_all)
            rec["why"] = why
            if ok:
                found.append(rec)
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
