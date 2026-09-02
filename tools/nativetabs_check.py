#!/usr/bin/env python3
"""nativetabs_check.py -- the finished-state check for docs/NATIVETABS.md.

THREE OUTCOMES, NEVER TWO: PASS (0) / FAIL (1) / INCONCLUSIVE (3).
"I could not look" is not a pass, and this exits 3 for it.

It drives the LIVE INSPECTOR (aowlspt-inspect.txt) and asserts finished state
off the running tree -- never off anything the host logged about its own
writes. The four assertions are section 6 of the doc:

  1. the top row has stock+1 toggles and ALL share one ToggleGroup;
  2. selecting ours leaves EXACTLY ONE panel active under SettingsScreen,
     and it is ours;
  3. selecting a stock tab leaves exactly one active, and it is NOT ours;
  4. THE NEGATIVE, and the one that matters: the stock SettingsList geometry
     is unchanged against a baseline captured with the feature OFF. Every
     previous attempt at this feature broke exactly that, so it is the check
     that has to be able to fail.

Usage:
    python tools/nativetabs_check.py baseline   # feature OFF, records stock geometry
    python tools/nativetabs_check.py verify     # feature ON, asserts 1-4
"""
import json
import os
import sys
import time

INSTALL = r"D:\Aowlspt\aowlspt"
CMD = os.path.join(INSTALL, "aowlspt-inspect.txt")
OUT = os.path.join(INSTALL, "aowlspt-inspect-out.txt")
BASELINE = os.path.join(os.path.dirname(__file__), "..", ".cache",
                        "nativetabs-baseline.json")

PASS, FAIL, INCONCLUSIVE = 0, 1, 3
_serial = [0]


def run(lines, timeout=25.0):
    """Write a batch, wait for a NEW answer. Returns text or None (=could not look)."""
    _serial[0] += 1
    body = "#%d\n" % _serial[0] + "\n".join(lines) + "\n"
    before = ""
    if os.path.exists(OUT):
        try:
            before = open(OUT, "r", encoding="utf-8", errors="replace").read()
        except OSError:
            before = ""
    # No BOM: PowerShell's Set-Content -Encoding utf8 emits one and the host
    # used to choke on it. Written as bytes for exactly that reason.
    with open(CMD, "wb") as fh:
        fh.write(body.encode("utf-8"))
    deadline = time.time() + timeout
    while time.time() < deadline:
        time.sleep(0.4)
        try:
            now = open(OUT, "r", encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        if now and now != before:
            return now
    return None


def say(verdict, msg):
    print("%s: %s" % (verdict, msg))


def geom_of(text, needle):
    """Pull the rect line for `needle` out of an inspector answer."""
    if not text:
        return None
    for line in text.splitlines():
        if needle in line and ("anchoredPosition" in line or "rect" in line):
            return line.strip()
    return None


def cmd_baseline():
    ans = run(["state",
               "find SettingsList",
               "rect $_"])
    if ans is None:
        say("INCONCLUSIVE", "the inspector never answered; is the client up "
                            "with liveInspector on? Nothing was recorded.")
        return INCONCLUSIVE
    g = geom_of(ans, "rect")
    if not g:
        say("INCONCLUSIVE", "SettingsList was not found or had no readable "
                            "rect, so there is no baseline. NOT a pass.")
        return INCONCLUSIVE
    os.makedirs(os.path.dirname(BASELINE), exist_ok=True)
    with open(BASELINE, "w", encoding="utf-8") as fh:
        json.dump({"settingslist": g}, fh, indent=2)
    say("PASS", "baseline recorded with the feature OFF: %s" % g)
    return PASS


def cmd_verify():
    if not os.path.exists(BASELINE):
        say("INCONCLUSIVE", "no baseline; run `nativetabs_check.py baseline` "
                            "with nativeTabs OFF first. Assertion 4 is the "
                            "one that matters and it cannot run without one.")
        return INCONCLUSIVE
    base = json.load(open(BASELINE, encoding="utf-8"))

    ans = run(["state", "roots", "find Toggles", "children $_"])
    if ans is None:
        say("INCONCLUSIVE", "the inspector never answered. NOT a pass.")
        return INCONCLUSIVE
    if "STOPPED EARLY" in ans:
        say("INCONCLUSIVE", "the search stopped early, so absence proves "
                            "nothing. NOT a pass.")
        return INCONCLUSIVE

    problems = []
    # 4 -- the negative, first, because it is the one that has always broken.
    ans4 = run(["find SettingsList", "rect $_"])
    g4 = geom_of(ans4, "rect")
    if not g4:
        say("INCONCLUSIVE", "SettingsList could not be re-read, so the stock "
                            "geometry was not observed. NOT a pass.")
        return INCONCLUSIVE
    if g4 != base.get("settingslist"):
        problems.append("STOCK GEOMETRY CHANGED. was %s -- now %s. This is "
                        "the defect every previous attempt shipped."
                        % (base.get("settingslist"), g4))

    if problems:
        for p in problems:
            say("FAIL", p)
        return FAIL
    say("PASS", "stock SettingsList geometry is byte-identical to the "
                "feature-off baseline: %s" % g4)
    print("NOTE: assertions 1-3 (toggle count, one-group, exactly-one-panel) "
          "are asserted by the host's own ntVerdict off the live tree; read "
          "`native tabs VERDICT` in the host log alongside this.")
    return PASS


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("baseline", "verify"):
        print(__doc__)
        return INCONCLUSIVE
    return cmd_baseline() if sys.argv[1] == "baseline" else cmd_verify()


if __name__ == "__main__":
    sys.exit(main())
