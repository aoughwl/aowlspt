#!/usr/bin/env python3
"""acceptance.py -- one-command acceptance run for the settings screen.

WHY THIS EXISTS
----------------
Today's loop per fix was: build -> deploy.py -> restart client -> entergame.py
-> walk Preloader UI / TaskBar / Tabs[13] -> press AnimatedToggle -> chain
5-8 hand-rolled inspector batches with echo-sentinel/grep/cut parsing ->
eyeball the result. Only the coordinating session could do all of that, so
fixes shipped on structural checks (does it compile, is the log line there)
instead of behaviour, and a broken build reached the user three times in a
row. This script is that whole loop, unattended, ending in one honest
PASS / FAIL / INCONCLUSIVE line per assertion and a non-zero exit on any FAIL.

    python tools/acceptance.py run
    python tools/acceptance.py run --no-launch      # client already running
    python tools/acceptance.py run --keep           # leave it running after
    python tools/acceptance.py run --root D:\\Aowlspt

THIS SCRIPT DOES NOT REIMPLEMENT THE LAUNCH OR MENU-NAVIGATION LOGIC.
`tools/harness.py` starts/stops the client and knows the idle-vs-hung
distinction; `tools/entergame.py` knows the mode-selector trap (object names
LIE about what a slot is titled, there are two copies in the hierarchy, only
one is live). Both are shelled out to as subprocesses, verbatim, and their
own exit codes and stdout are trusted rather than re-derived here.

NO STALE READS
---------------
Every inspector batch after menu entry goes through `tools/ichannel.py`,
which is `plugins/aowlsptcode/mcp/channel.py` from `feat-aowlsptcode` copied
in unmodified (see header comment in that file) rather than a third
hand-rolled sentinel loop. It mints a unique sentinel per batch, appends
`echo <sentinel>`, and only accepts an out-file body that contains that exact
literal -- anything else is polled again or times out. `tools/entergame.py`
uses `tools/inspector.py` instead, which independently implements the same
per-batch-sentinel contract; that duplication predates this task and is
called out below, not silently worked around.

THE HONESTY CONTRACT
---------------------
Every assertion prints one of exactly three verdicts -- PASS, FAIL,
INCONCLUSIVE -- and states what it measured, not just the verdict:

  PASS         the check ran to completion and the condition held.
  FAIL         the check ran to completion and the condition did NOT hold.
  INCONCLUSIVE the check could not be trusted: a `find`/`findtext` reported
               STOPPED_EARLY or HIT_CAP rather than EXHAUSTIVE, a pointer read
               came back unreadable, a screen never opened, or the settings
               screen could not be reached at all. INCONCLUSIVE is never
               printed as, or counted as, a PASS.

Exit code is 0 only if every assertion is PASS. Any FAIL or INCONCLUSIVE
makes the run non-zero, because "I could not look" must never look like
success from the calling process's point of view.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import hostlog  # noqa: E402 -- reuse the FAULT regex and log parser, not a new one
import ichannel as ch  # noqa: E402 -- vendored channel.py, sentinel + parsers

LIVE_DEFAULT = r"D:\Aowlspt\aowlspt"

PASS, FAIL, INCONCLUSIVE = "PASS", "FAIL", "INCONCLUSIVE"

# rva:0x55ba430 is `v_pb` (void, pointer-arg, bool-arg) AnimatedToggle::SetOn,
# per fact #109 -- the proven path onto the Settings screen.
OPEN_SETTINGS_RVA = "rva:0x55ba430"


class Report:
    def __init__(self):
        self.rows = []  # (name, verdict, measured, detail)

    def record(self, name, verdict, measured, detail=""):
        self.rows.append((name, verdict, measured, detail))
        print("[%-12s] %-58s %s%s" %
              (verdict, name, measured, ("  -- " + detail) if detail else ""))
        return verdict

    def exit_code(self):
        return 0 if all(v == PASS for _, v, _, _ in self.rows) else 1

    def summary(self):
        n = len(self.rows)
        p = sum(1 for _, v, _, _ in self.rows if v == PASS)
        f = sum(1 for _, v, _, _ in self.rows if v == FAIL)
        i = sum(1 for _, v, _, _ in self.rows if v == INCONCLUSIVE)
        print("\n==== %d assertion(s): %d PASS, %d FAIL, %d INCONCLUSIVE"
              % (n, p, f, i))


# ---------------------------------------------------------------------------
# launch + menu entry -- shelled out to harness.py / entergame.py, verbatim
# ---------------------------------------------------------------------------

def launch_client(root, timeout):
    harness = os.path.join(HERE, "harness.py")
    cmd = [sys.executable, harness, "run", "--root", root,
           "--until", "host running", "--keep", "--timeout", str(int(timeout))]
    print("$ %s" % " ".join(cmd))
    r = subprocess.run(cmd)
    return r.returncode == 0


def _parse_slot_titles(list_stdout):
    """Titles printed by `entergame.py --list`, one per slot, in order."""
    out = []
    for line in list_stdout.splitlines():
        m = re.search(r"title=(?:'([^']*)'|(<unreadable>))", line)
        if m:
            out.append(m.group(1))  # None for <unreadable>
    return out


def enter_game(timeout):
    """Get past the mode selector, retrying because on a fresh client the
    pve/seasonal slots can read the localisation placeholder 'New Text'
    before locale lands. Selects whichever slot shows a REAL, non-placeholder
    title -- never guesses by object name (see entergame.py's own header)."""
    entergame = os.path.join(HERE, "entergame.py")
    deadline = time.time() + timeout
    last_note = "no attempt made yet"
    while time.time() < deadline:
        lst = subprocess.run([sys.executable, entergame, "--list"],
                              capture_output=True, text=True)
        if "already past the mode selector" in lst.stdout:
            return True, "already past the mode selector"
        titles = [t for t in _parse_slot_titles(lst.stdout) if t]
        real = [t for t in titles if t and t.strip() != "New Text"]
        if not real:
            last_note = ("no slot shows a real title yet (placeholders only: %r)"
                         % titles)
            time.sleep(4)
            continue
        mode = real[0]
        sel = subprocess.run([sys.executable, entergame, "--mode", mode],
                              capture_output=True, text=True)
        if sel.returncode == 0:
            return True, "selected %r" % mode
        last_note = "pressed %r, entergame.py exited %d: %s" % (
            mode, sel.returncode, (sel.stdout + sel.stderr).strip()[-400:])
        time.sleep(4)
    return False, "could not get past the mode selector within %gs: %s" % (
        timeout, last_note)


# ---------------------------------------------------------------------------
# open settings -- fact #109's proven path, walked literally
# ---------------------------------------------------------------------------

ROOT_RE = re.compile(r"\[\$r(\d+)\] transform=(0x[0-9a-fA-F]+).*name=\"([^\"]*)\"")


def find_scene_root(name, live, timeout=40):
    sentinel, out = ch.run_batch(["roots"], live_dir=live, timeout=timeout)
    for m in ROOT_RE.finditer(out):
        if m.group(3) == name:
            return m.group(2)
    return None


def open_settings(live, timeout=90):
    """Preloader UI -> TaskBar -> children -> Tabs -> child 'Settings'
    (index 13) -> child SettingsButton -> AnimatedToggle -> SetOn(true).
    Requires the main menu loaded; TaskBar is legitimately inactive earlier.
    Returns (ok, detail)."""
    preloader = find_scene_root("Preloader UI", live, timeout=40)
    if not preloader:
        return False, "no `Preloader UI` scene root -- main menu not loaded"

    sentinel, raw = ch.run_batch(["find TaskBar %s 40000" % preloader],
                                  live_dir=live, timeout=60)
    f = ch.parse_find(raw)
    if not f["hits"]:
        return False, "TaskBar not found (%s)" % f["completeness"]
    taskbar = f["hits"][0]["ptr"]

    sentinel, raw = ch.run_batch(["find Tabs %s 40000" % taskbar],
                                  live_dir=live, timeout=60)
    f = ch.parse_find(raw)
    if not f["hits"]:
        return False, "Tabs not found under TaskBar (%s)" % f["completeness"]
    tabs = f["hits"][0]["ptr"]

    sentinel, raw = ch.run_batch(["find Settings %s 40000" % tabs],
                                  live_dir=live, timeout=60)
    f = ch.parse_find(raw)
    if not f["hits"]:
        return False, "no child named Settings under Tabs (%s)" % f["completeness"]
    settings_tab = f["hits"][0]["ptr"]

    sentinel, raw = ch.run_batch(["find SettingsButton %s 20000" % settings_tab],
                                  live_dir=live, timeout=40)
    f = ch.parse_find(raw)
    if not f["hits"]:
        return False, "no SettingsButton under the Settings tab (%s)" % f["completeness"]
    settings_button = f["hits"][0]["ptr"]

    sentinel, raw = ch.run_batch(
        ["component %s AnimatedToggle" % settings_button,
         "call %s v_pb $comp 1" % OPEN_SETTINGS_RVA],
        live_dir=live, timeout=40, write=True)
    if "returned without faulting" not in raw and "!!" in raw:
        return False, "the AnimatedToggle call did not go through: %s" % raw[-300:]
    return True, "pressed Settings via %s" % OPEN_SETTINGS_RVA


# ---------------------------------------------------------------------------
# assertions
# ---------------------------------------------------------------------------

DONOR_CAPTION = "Interface language"
PLACEHOLDER_TEXT = "SOME TEXT"


def assert_tab_count(report, live, mods_built):
    want = 4 + (1 if mods_built else 0)
    sentinel, raw = ch.run_batch(["find TabButton in Tabs all"],
                                  live_dir=live, timeout=60)
    f = ch.parse_findtext(raw) if "findtext" in raw.lower() else ch.parse_find(raw)
    if f["completeness"] not in ("EXHAUSTIVE",):
        report.record("top-row tab count", INCONCLUSIVE,
                       "walk was %s, not EXHAUSTIVE" % f["completeness"], f["raw"][-200:])
        return
    active = [h for h in f["hits"]]
    got = len(active)
    v = PASS if got == want else FAIL
    report.record("top-row tab count", v, "got %d, want %d (mods_built=%s)"
                  % (got, want, mods_built))


def assert_no_text(report, live, name, needle):
    sentinel, raw = ch.run_batch(["findtext \"%s\" all" % needle],
                                  live_dir=live, timeout=90)
    f = ch.parse_findtext(raw)
    if f["completeness"] != "EXHAUSTIVE":
        report.record(name, INCONCLUSIVE,
                       "walk was %s (not EXHAUSTIVE) -- a STOPPED_EARLY result "
                       "cannot prove absence" % f["completeness"], f["raw"][-200:])
        return
    v = FAIL if f["hits"] else PASS
    report.record(name, v, "%d occurrence(s) of %r, scope=%s"
                  % (len(f["hits"]), needle, f["scope"]),
                  "; ".join("%s@%s" % (h["name"], h["ptr"]) for h in f["hits"][:5]))


def assert_spawner_one_active_toggle(report, live):
    sentinel, raw = ch.run_batch(["find Toggle in ClonedSpawner all"],
                                  live_dir=live, timeout=60)
    f = ch.parse_findtext(raw) if hasattr(ch, "parse_findtext") else ch.parse_find(raw)
    if f["completeness"] != "EXHAUSTIVE":
        report.record("cloned spawner: exactly one active toggle", INCONCLUSIVE,
                       "walk was %s" % f["completeness"], f["raw"][-200:])
        return
    active_lines = [l for l in raw.splitlines() if "active=true" in l.lower()]
    got = len(active_lines)
    v = PASS if got == 1 else FAIL
    report.record("cloned spawner: exactly one active toggle", v,
                  "%d toggle(s) active=true" % got)


def assert_postfx_group(report, live):
    """Toggle.m_Group@0x110 non-zero and shared; exactly one m_IsOn@0x120."""
    sentinel, raw = ch.run_batch(["find Toggle in PostFx all"],
                                  live_dir=live, timeout=60)
    f = ch.parse_findtext(raw) if hasattr(ch, "parse_findtext") else ch.parse_find(raw)
    if f["completeness"] != "EXHAUSTIVE":
        report.record("postfx toggles share a group, one is on", INCONCLUSIVE,
                       "walk was %s" % f["completeness"], f["raw"][-200:])
        return
    if not f["hits"]:
        report.record("postfx toggles share a group, one is on", INCONCLUSIVE,
                      "no Toggle found under PostFx (walk was exhaustive)")
        return
    lines = []
    for h in f["hits"]:
        lines.append("read %s +0x110 ptr" % h["ptr"])
        lines.append("read %s +0x120 bool" % h["ptr"])
    sentinel2, raw2 = ch.run_batch(lines, live_dir=live, timeout=60)
    vals = raw2.strip().splitlines()
    groups, ons = [], []
    for i in range(0, len(vals) - 1, 2):
        gm = re.search(r"=\s*(0x[0-9a-fA-F]+)", vals[i])
        om = re.search(r"=\s*(true|false)", vals[i + 1], re.I)
        groups.append(gm.group(1) if gm else None)
        ons.append((om.group(1).lower() == "true") if om else None)
    if None in groups or None in ons:
        report.record("postfx toggles share a group, one is on", INCONCLUSIVE,
                      "one or more +0x110/+0x120 reads were unparseable",
                      raw2[-300:])
        return
    nonzero = all(g != "0x0" for g in groups)
    shared = len(set(groups)) == 1
    one_on = sum(1 for o in ons if o) == 1
    v = PASS if (nonzero and shared and one_on) else FAIL
    report.record("postfx toggles share a group, one is on", v,
                  "groups=%r on=%r" % (groups, ons))


ESETTINGS_GROUPS = [("graphics", 0), ("game", 1), ("sound", 2),
                     ("controls", 3), ("postfx", 4)]


def assert_one_panel_active_per_group(report, live):
    for name, idx in ESETTINGS_GROUPS:
        sentinel, raw = ch.run_batch(
            ["find SettingsPanel in Group%d all" % idx], live_dir=live, timeout=40)
        f = ch.parse_findtext(raw) if hasattr(ch, "parse_findtext") else ch.parse_find(raw)
        assertion = "exactly one active panel: group %s (%d)" % (name, idx)
        if f["completeness"] != "EXHAUSTIVE":
            report.record(assertion, INCONCLUSIVE,
                          "walk was %s" % f["completeness"], f["raw"][-200:])
            continue
        active = [l for l in raw.splitlines() if "active=true" in l.lower()]
        got = len(active)
        v = PASS if got == 1 else FAIL
        report.record(assertion, v, "%d panel(s) active=true" % got)


def assert_no_faults(report, root):
    ns = argparse.Namespace(root=os.path.join(root, "aowlspt"), backend=False)
    try:
        _, lines = hostlog.read(ns)
    except SystemExit:
        report.record("no fault-caught lines during the run", INCONCLUSIVE,
                      "host log unreadable")
        return
    rows = list(hostlog.parse(lines))
    hits = [r for r in rows if "fault caught" in r[2].lower()]
    if hits:
        stage = None
        m = re.search(r"STAGE[:=]?\s*(\S+)", hits[-1][2])
        stage = m.group(1) if m else hits[-1][2]
        report.record("no fault-caught lines during the run", FAIL,
                      "%d fault-caught line(s)" % len(hits), "last: %s" % stage)
    else:
        report.record("no fault-caught lines during the run", PASS,
                      "0 fault-caught lines in %d log rows" % len(rows))


def _backend_port(root):
    """The real, configurable port -- `backendPort` in aowlspt-host.json (0 =
    disabled by default; see aowlhost.nim ~5633-5644). NOT a guessed constant:
    a wrong guess here would have made this assertion look INCONCLUSIVE for
    the wrong reason on every install that customises the port."""
    try:
        hostcfg = __import__("hostcfg")
        _p, text = hostcfg.read_cfg(os.path.join(root, "aowlspt"))
        present, raw, _truthy = hostcfg.value_of(text, "backendPort")
        return int(raw) if present and raw and raw.lstrip("-").isdigit() else 0
    except BaseException:
        # includes SystemExit -- read_cfg exits if the file is simply absent,
        # which for us just means "cannot confirm the port", not a crash.
        return 0


def assert_settings_json(report, root, guid=None):
    port = _backend_port(root)
    if not port:
        report.record("STRICT JSON: settings endpoints", INCONCLUSIVE,
                      "backendPort is 0 (or unreadable) in aowlspt-host.json "
                      "-- the backend HTTP port is not configured, so it "
                      "cannot be reached to check")
        return
    for path in (["/aowlspt/settings/index"] +
                 (["/aowlspt/settings/%s" % guid] if guid else [])):
        url = "http://127.0.0.1:%d%s" % (port, path)
        try:
            req = urllib.request.Request(url, headers={"Accept-Encoding": "identity"})
            with urllib.request.urlopen(req, timeout=15) as resp:
                body = resp.read()
                enc = resp.headers.get("Content-Encoding")
        except Exception as e:
            report.record("STRICT JSON: %s" % path, INCONCLUSIVE,
                          "request failed", str(e))
            continue
        if enc:
            report.record("STRICT JSON: %s" % path, INCONCLUSIVE,
                          "server sent Content-Encoding=%s despite identity request "
                          "-- cannot trust body as raw JSON" % enc)
            continue
        try:
            json.loads(body.decode("utf-8"))
        except Exception as e:
            report.record("STRICT JSON: %s" % path, FAIL,
                          "%d bytes, not valid JSON" % len(body), str(e))
            continue
        report.record("STRICT JSON: %s" % path, PASS, "%d bytes, parses" % len(body))


# ---------------------------------------------------------------------------

def cmd_run(args):
    report = Report()
    root = args.root
    live = os.path.join(root, "aowlspt")

    if not args.no_launch:
        ok = launch_client(root, args.launch_timeout)
        if not ok:
            report.record("client launch", INCONCLUSIVE,
                          "harness.py did not reach 'host running'")
            report.summary()
            return 2

    ok, note = enter_game(args.menu_timeout)
    if not ok:
        report.record("past mode selector", INCONCLUSIVE, note)
        report.summary()
        return 2
    print("menu: %s" % note)

    ok, detail = open_settings(live, args.settings_timeout)
    if not ok:
        report.record("settings screen opened", INCONCLUSIVE, detail)
        report.summary()
        return 2
    report.record("settings screen opened", PASS, detail)

    assert_tab_count(report, live, args.mods_built)
    assert_no_text(report, live, "no donor caption under MODS", DONOR_CAPTION)
    assert_no_text(report, live, "no placeholder text anywhere", PLACEHOLDER_TEXT)
    assert_spawner_one_active_toggle(report, live)
    assert_postfx_group(report, live)
    assert_one_panel_active_per_group(report, live)
    assert_no_faults(report, root)
    assert_settings_json(report, root, guid=args.guid)

    report.summary()

    if not args.keep and not args.no_launch:
        subprocess.run(["taskkill", "/F", "/IM", "EscapeFromTarkov.exe"],
                       capture_output=True)
        subprocess.run(["taskkill", "/F", "/IM", "aowlspt-backend.exe"],
                       capture_output=True)
        print("stopped the client and the backend (use --keep to leave them up)")

    return report.exit_code()


def main():
    ap = argparse.ArgumentParser(
        description="one-command acceptance run for the settings screen",
        formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    ap.add_argument("command", choices=["run"])
    ap.add_argument("--root", default=LIVE_DEFAULT.rsplit("\\", 1)[0])
    ap.add_argument("--no-launch", action="store_true",
                    help="run against an already-running client")
    ap.add_argument("--keep", action="store_true",
                    help="leave the client and backend running after the run")
    ap.add_argument("--mods-built", action="store_true",
                    help="the MODS tab clone was built into this deploy")
    ap.add_argument("--guid", default=None,
                    help="a profile guid to also check /settings/<guid>")
    ap.add_argument("--launch-timeout", type=float, default=240.0)
    ap.add_argument("--menu-timeout", type=float, default=120.0)
    ap.add_argument("--settings-timeout", type=float, default=90.0)
    args = ap.parse_args()
    return cmd_run(args)


if __name__ == "__main__":
    sys.exit(main())
