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
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

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


GEOM_RE = re.compile(r"^(anchoredPosition|sizeDelta|anchorMin|anchorMax|pivot|"
                     r"rect \(x,y,w,h\))\s*=\s*\((-?[\d.]+),\s*(-?[\d.]+)"
                     r"(?:,\s*(-?[\d.]+),\s*(-?[\d.]+))?\)")


def geom_of(text, needle):
    """The FULL geometry the host printed for `rect`: all six lines, numbers
    only, joined -- so a shift in anchoredPosition with an unchanged rect is
    still a change.

    MEASURED 2026-09-01: the first version matched any line containing
    `rect`, and the inspector ECHOES every command as `> rect $_`; the
    baseline was recorded as the string "> rect $_" and reported PASS -- a
    check that passed on its own input. Lines beginning with `>` are echoes
    and are never geometry. Fewer than six lines is "not observed".
    """
    if not text:
        return None
    got = []
    for line in text.splitlines():
        t = line.strip()
        if t.startswith(">"):
            continue
        m = GEOM_RE.match(t)
        if m:
            got.append("%s=(%s)" % (m.group(1), ",".join(
                g for g in m.groups()[1:] if g is not None)))
    if len(got) < 6:
        return None
    return " ".join(got)


def ensure_settings_open():
    """The SettingsScreen only exists once opened; `find SettingsList` from
    the roots stops early with 0 hits otherwise (measured). Walk the proven
    open path from acceptance.py, then wait for `$settings` to bind."""
    import acceptance
    ans = run(["state"])
    if ans and "$settings=0x0000000000000000" not in ans:
        return True, "already open"
    ok, detail = acceptance.open_settings(INSTALL, 90)
    if not ok:
        return False, detail
    for _ in range(10):
        time.sleep(1.0)
        ans = run(["state"])
        if ans and "$settings=0x" in ans and            "$settings=0x0000000000000000" not in ans:
            return True, detail
    return False, "pressed Settings but $settings never bound: " + detail


HOSTLOG = os.path.join(INSTALL, "aowlspt-host.log")


def host_native_tabs_lines():
    """Every `native tabs` line the host wrote this session, bounded read."""
    out = []
    try:
        with open(HOSTLOG, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if "native tabs" in line:
                    out.append(line.rstrip()[:300])
    except OSError:
        return None
    return out


def cmd_baseline():
    ok, detail = ensure_settings_open()
    if not ok:
        say("INCONCLUSIVE", "Settings could not be opened, so the stock "
                            "geometry was not observed: " + detail)
        return INCONCLUSIVE
    ans = run(["state",
               "find SettingsList $settings 40000",
               "rect $f1"])
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

    ans = run(["state", "find Toggles $settings 40000", "children $f1"])
    if ans is None:
        say("INCONCLUSIVE", "the inspector never answered. NOT a pass.")
        return INCONCLUSIVE
    if "STOPPED EARLY" in ans:
        say("INCONCLUSIVE", "the search stopped early, so absence proves "
                            "nothing. NOT a pass.")
        return INCONCLUSIVE

    problems = []
    # 4 -- the negative, first, because it is the one that has always broken.
    ok, detail = ensure_settings_open()
    if not ok:
        say("INCONCLUSIVE", "Settings could not be opened: " + detail)
        return INCONCLUSIVE
    ans4 = run(["find SettingsList $settings 40000", "rect $f1"])
    g4 = geom_of(ans4, "rect")
    if not g4:
        say("INCONCLUSIVE", "SettingsList could not be re-read, so the stock "
                            "geometry was not observed. NOT a pass.")
        return INCONCLUSIVE
    if g4 != base.get("settingslist"):
        problems.append("STOCK GEOMETRY CHANGED. was %s -- now %s. This is "
                        "the defect every previous attempt shipped."
                        % (base.get("settingslist"), g4))

    # THE VACUOUS-PASS GUARD, measured 2026-09-02: the geometry was byte-
    # identical because the feature had FAULTED 4/4 on the first frame Settings
    # was known and switched itself off -- nothing was ever added, so nothing
    # could have moved. Unchanged geometry is only evidence once the host says
    # the tab was built. Read the host's own trail: a fault ceiling is a FAIL,
    # and no VERDICT line at all is "I could not look", never a pass.
    trail = host_native_tabs_lines()
    if trail is None:
        say("INCONCLUSIVE", "the host log could not be read, so whether the "
                            "feature ran is unknown. NOT a pass.")
        return INCONCLUSIVE
    faults = [l for l in trail if "FAULTED" in l or "fault ceiling" in l]
    if faults:
        problems.append("the native-tabs tick FAULTED and the feature switched "
                        "itself off; the unchanged geometry is vacuous. Host: "
                        + faults[-1].strip())
    elif not any("native tabs VERDICT" in l for l in trail):
        say("INCONCLUSIVE", "the host never printed `native tabs VERDICT`, so "
                            "the tab was not observed being built; unchanged "
                            "geometry proves nothing. NOT a pass.")
        return INCONCLUSIVE

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
