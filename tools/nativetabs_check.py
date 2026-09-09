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
    python tools/nativetabs_check.py selftest   # OFFLINE, no client: replays
                                                # tools/fixtures/inspector/
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
    if problems:
        # A changed stock geometry is a FAIL whatever the host says about
        # itself -- it is the one assertion that has always broken.
        for p in problems:
            say("FAIL", p)
        return FAIL

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
    elif any("native tabs VERDICT FAIL" in l for l in trail):
        # MEASURED 2026-09-02 05:10: the first verdict the host ever printed
        # was `native tabs VERDICT FAIL: 6 panels are active at once ...` and
        # this tool said PASS because it only looked for the word VERDICT.
        # A verdict line is only a pass when the host says PASS.
        problems.append("the host's own verdict is FAIL: "
                        + [l for l in trail if "native tabs VERDICT FAIL" in l][-1].strip())
    elif not any("native tabs VERDICT PASS" in l for l in trail):
        say("INCONCLUSIVE", "the host never printed `native tabs VERDICT PASS`, so "
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


# ---------------------------------------------------------------------------
# selftest -- OFFLINE, against tools/fixtures/inspector/ (MEASURED prose)
# ---------------------------------------------------------------------------
# This file had NO offline test at all, which is how it shipped a baseline that
# recorded the string `> rect $_` -- its own command echo -- as the stock
# geometry, so `verify` compared the echo to itself and printed PASS. The fix
# was made once, by hand, with nothing to stop it coming back. These cases are
# that stop, and every input below is host text really captured on this machine
# (tools/inspectfixtures.py `list` says where each came from).
#
# THE CASES ARE CHOSEN SO EACH ONE CAN FAIL:
#   1 echo trap        -- the echoes alone must yield NO geometry (the old bug)
#   2 rect refusal     -- a refusal is INCONCLUSIVE, never a recorded baseline
#   3 real geometry    -- the six measured lines DO record a baseline
#   4 changed geometry -- the comparison can actually fail (negative control)
#   5 fault ceiling    -- unchanged geometry after a self-disable is VACUOUS
#   6 no VERDICT line  -- "the tab was never observed being built" is not a pass

def cmd_selftest():
    import tempfile
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import inspectfixtures as fx

    g = globals()
    real = {k: g[k] for k in ("run", "ensure_settings_open",
                              "host_native_tabs_lines", "BASELINE")}
    failures = []
    tmp = tempfile.mkdtemp(prefix="nativetabs-selftest-")
    seq = [0]

    def case(title, fn):
        seq[0] += 1
        g["BASELINE"] = os.path.join(tmp, "baseline-%d.json" % seq[0])
        print("\n---- %s" % title)
        try:
            note = fn()
        except AssertionError as e:
            note = "raised: %s" % e
        if note:
            failures.append("%s: %s" % (title, note))
            print("  ** CASE FAILED: %s" % note)
        else:
            print("  case ok")

    def use(script, trail=None, open_ok=True):
        """Wire run/ensure_settings_open/host_native_tabs_lines to fixtures."""
        rp = fx.Replay(script)
        g["run"] = rp.text_only
        g["ensure_settings_open"] = lambda: (open_ok, "replay")
        g["host_native_tabs_lines"] = lambda: trail
        return rp

    SIX = fx.fx("rect-six-line-geometry")
    REFUSAL = fx.fx("rect-refused-unreadable")
    STATE = fx.fx("state-settings-bound")
    FAULTS = fx.fx("hostlog-nativetabs-fault-ceiling").splitlines()
    NEVER = fx.fx("hostlog-nativetabs-never-built").splitlines()

    # 1 -- THE ECHO TRAP. `echo_only` keeps ONLY the `>` lines of a reply that
    #      really did contain geometry, so the input is measured and the only
    #      thing removed is the host's actual answer.
    def c1():
        echoes = fx.echo_only(SIX)
        if "> rect" not in echoes:
            return "the trap input does not even contain a rect echo (%r)" % echoes
        if geom_of(echoes, "rect") is not None:
            return ("geom_of accepted the COMMAND ECHOES as geometry -- this is "
                    "the exact bug that made verify compare `> rect $_` to "
                    "itself and PASS")
        if geom_of(fx.header_only(SIX), "rect") is not None:
            return "geom_of accepted the batch header/trailer as geometry"
        return ""
    case("echo trap: command echoes are NOT geometry", c1)

    # 2 -- a REFUSAL must not become a baseline.
    def c2():
        use([("state\nfind SettingsList", [REFUSAL])])
        rc = cmd_baseline()
        if rc != INCONCLUSIVE:
            return "rect refused to read the pointer and this returned %d, " \
                   "want INCONCLUSIVE(%d)" % (rc, INCONCLUSIVE)
        if os.path.exists(BASELINE):
            return "a baseline file was written from a refusal"
        return ""
    case("`rect` refusal (not readable) -> INCONCLUSIVE, nothing recorded", c2)

    # 3 -- the six measured lines DO record, and record all six.
    def c3():
        use([("state\nfind SettingsList", [SIX])])
        rc = cmd_baseline()
        if rc != PASS:
            return "six-line geometry returned %d, want PASS(%d)" % (rc, PASS)
        rec = json.load(open(BASELINE, encoding="utf-8"))["settingslist"]
        for key in ("anchoredPosition", "sizeDelta", "anchorMin", "anchorMax",
                    "pivot", "rect (x,y,w,h)"):
            if key not in rec:
                return "baseline is missing %r: %r" % (key, rec)
        if "0.0000,-755.0000,850.0000,755.0000" not in rec.replace(" ", ""):
            return "baseline did not capture the measured rect numbers: %r" % rec
        return ""
    case("six-line measured geometry -> baseline recorded, all six lines", c3)

    # 4 -- NEGATIVE CONTROL: verify must be able to say the geometry moved.
    def c4():
        use([("state\nfind SettingsList", [SIX])])
        if cmd_baseline() != PASS:
            return "setup: baseline did not record"
        moved = SIX.replace("(850.0000, 755.0000)", "(851.0000, 755.0000)")
        use([("state\nfind Toggles", [STATE]),
             ("find SettingsList", [moved])], trail=NEVER + [
                 "client  [0:01:20.000]ok  native tabs VERDICT: synthetic, "
                 "case 4 only -- see the note in cmd_selftest"])
        if cmd_verify() != FAIL:
            return "a CHANGED sizeDelta did not FAIL -- the comparison cannot fail"
        return ""
    case("control: changed stock geometry -> FAIL", c4)

    # 5 -- the vacuous pass: identical geometry, but the tick faulted itself off.
    def c5():
        use([("state\nfind SettingsList", [SIX])])
        if cmd_baseline() != PASS:
            return "setup: baseline did not record"
        use([("state\nfind Toggles", [STATE]),
             ("find SettingsList", [SIX])], trail=FAULTS)
        if cmd_verify() != FAIL:
            return ("identical geometry after a 4-of-4 fault ceiling was not "
                    "FAIL -- nothing was ever added, so nothing could move")
        return ""
    case("fault ceiling in the host log -> FAIL, not a vacuous PASS", c5)

    # 6 -- no VERDICT line anywhere: "I could not look" is not a pass. MEASURED:
    #      no capture on this machine contains `native tabs VERDICT` at all.
    def c6():
        use([("state\nfind SettingsList", [SIX])])
        if cmd_baseline() != PASS:
            return "setup: baseline did not record"
        use([("state\nfind Toggles", [STATE]),
             ("find SettingsList", [SIX])], trail=NEVER)
        rc = cmd_verify()
        if rc != INCONCLUSIVE:
            return "no `native tabs VERDICT` line returned %d, want " \
                   "INCONCLUSIVE(%d)" % (rc, INCONCLUSIVE)
        return ""
    case("no `native tabs VERDICT` line -> INCONCLUSIVE", c6)

    g.update(real)
    print("\n==== nativetabs selftest: %d case(s) failed" % len(failures))
    for f in failures:
        print("  - %s" % f)
    return 1 if failures else 0


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("baseline", "verify",
                                                "selftest"):
        print(__doc__)
        return INCONCLUSIVE
    if sys.argv[1] == "selftest":
        return cmd_selftest()
    return cmd_baseline() if sys.argv[1] == "baseline" else cmd_verify()


if __name__ == "__main__":
    sys.exit(main())
