#!/usr/bin/env python3
"""Falsification test for popups.classify -- BOTH directions.

A popup filter has two failure modes and they are the same bug pointed
opposite ways: reporting a healthy window as a POPUP (which aborted every
`run.py` supervision loop on 2026-09-01), and suppressing a real fatal dialog
(which puts us back to hours of blind log-reading). A test that only proved
one direction would pass for a classifier that returns False unconditionally.

Both real detections below are transcribed from the measured dialogs named in
popups.py's own docstring, so the NEGATIVE side of this test can actually fail.

    python tools/test_popups_classify.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import popups  # noqa: E402


# The game's own render window, exactly as measured on a healthy main menu.
GAME_RENDER_WINDOW = {
    "class": "UnityWndClass", "process": "EscapeFromTarkov.exe",
    "caption": "EscapeFromTarkov", "text": [], "buttons": [],
}

# Same shape but a class we have never denylisted -- this is the case that
# proves the fix is the MESSAGE rule, not just one more name in NOT_A_POPUP.
UNKNOWN_CLASS_CAPTION_ONLY = {
    "class": "SomeFutureUnityClass", "process": "EscapeFromTarkov.exe",
    "caption": "EscapeFromTarkov", "text": [], "buttons": [],
}

BATTLEYE_DIALOG = {
    "class": "#32770", "process": "BEService.exe",
    "caption": "BattlEye Launcher",
    "text": ["The BattlEye service is not running.", "OK"],
    "buttons": ["OK"],
}

VERSION_CHECK_DIALOG = {
    "class": "#32770", "process": "EscapeFromTarkov.exe",
    "caption": "Fatal error [EscapeFromTarkov.exe]",
    "text": ["Unable to check the client version. Please check for client "
             "updates and network availability.", "OK"],
    "buttons": ["OK"],
}

# A fatal dialog whose class is NOT #32770 but which does carry child text --
# it must still be caught by the process rule plus the message rule.
UNITY_FATAL_NONSTANDARD = {
    "class": "UnityFatalWindow", "process": "EscapeFromTarkov.exe",
    "caption": "Fatal error [EscapeFromTarkov.exe]",
    "text": ["Unable to check the client version.", "Quit"],
    "buttons": ["Quit"],
}

UNRELATED_WINDOW = {
    "class": "Notepad", "process": "notepad.exe",
    "caption": "notes.txt - Notepad", "text": ["hello"], "buttons": [],
}


CASES = [
    ("game render window (the P0 false positive)", GAME_RENDER_WINDOW, False),
    ("caption-only window, class not denylisted", UNKNOWN_CLASS_CAPTION_ONLY, False),
    ("unrelated process", UNRELATED_WINDOW, False),
    ("BattlEye service dialog", BATTLEYE_DIALOG, True),
    ("client version-check fatal dialog", VERSION_CHECK_DIALOG, True),
    ("fatal dialog, non-standard class", UNITY_FATAL_NONSTANDARD, True),
]


def main():
    failures = []
    for name, rec, expected in CASES:
        got, why = popups.classify(rec, include_all=False)
        ok = (got == expected)
        print("%-4s %-45s -> %-5s  (%s)"
              % ("PASS" if ok else "FAIL", name, got, why))
        if not ok:
            failures.append(name)

    # --all must still report everything, or the escape hatch is broken.
    if not popups.classify(GAME_RENDER_WINDOW, include_all=True)[0]:
        failures.append("--all suppressed the render window")

    # A classifier that says False to everything would pass the first three
    # cases; the last three are what falsify it. Assert the split explicitly so
    # a future edit cannot quietly make this test vacuous.
    positives = sum(1 for _, r, _ in CASES if popups.classify(r)[0])
    if positives == 0:
        failures.append("no case classified as POPUP -- test is vacuous")
    if positives == len(CASES):
        failures.append("every case classified as POPUP -- test is vacuous")

    if failures:
        print("\nFAIL: %d" % len(failures))
        for f in failures:
            print("  - %s" % f)
        return 1
    print("\nPASS: %d/%d, both directions exercised (%d popup, %d not)"
          % (len(CASES), len(CASES), positives, len(CASES) - positives))
    return 0


if __name__ == "__main__":
    sys.exit(main())
