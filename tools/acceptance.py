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
    if "returned without faulting" not in raw and ch._has_err_line(raw):
        return False, "the AnimatedToggle call did not go through: %s" % raw[-300:]
    return True, "pressed Settings via %s" % OPEN_SETTINGS_RVA


# ---------------------------------------------------------------------------
# assertions
# ---------------------------------------------------------------------------

DONOR_CAPTION = "Interface language"
PLACEHOLDER_TEXT = "SOME TEXT"

# The needle for the POSITIVE CONTROL that gates every findtext-based absence
# claim below. `e` is the most common letter in the English UI; a settings
# screen that renders dozens of captions and yields ZERO hits for it has not
# proved the captions are absent, it has proved findtext could not read them.
FINDTEXT_CONTROL = "e"

SETTINGS_ROOT = "$settings"      # bound once Settings is open; `state` shows it
WALK_BUDGET = 40000              # measured: EXHAUSTIVE in ~1263 nodes from here


# ---------------------------------------------------------------------------
# Reading the inspector's answer: ONLY lines the host PRINTED
# ---------------------------------------------------------------------------
# MEASURED 2026-09-01/02: every panel/toggle assertion in the previous version
# reported `walk was UNKNOWN -- ... on Unity thread 1192`. That trailing text
# is the inspector's own BATCH HEADER, i.e. the classifier had been fed, and
# had matched against, lines the host never printed as an answer:
#
#     aowlspt live inspector -- batch 80, 2 command(s), on Unity thread 1192
#     > find SettingsPanel in Group4 all              <- our own command, echoed
#       ! no object named like "Group4" was found ...  <- the only real answer
#     aowlspt live inspector -- batch 80 complete, 5 line(s)
#
# nativetabs_check.py hit the same class of bug and it was worse there: its
# baseline matched the ECHO `> rect $_` and recorded that string as the stock
# geometry, so `verify` compared the echo to itself and PASSED. A parser that
# can match its own input is a check that cannot fail. So: strip the header,
# the trailer and every `>` echo BEFORE classifying anything.

_HDR_RE = re.compile(r"^\s*aowlspt live inspector --")
_ECHO_RE = re.compile(r"^\s*>")


def host_text(raw):
    """`raw` with the batch header/trailer and all command echoes removed."""
    keep = []
    for line in (raw or "").splitlines():
        if _HDR_RE.match(line) or _ECHO_RE.match(line):
            continue
        keep.append(line)
    return "\n".join(keep)


def completeness_of(raw):
    """Three-plus-state walk completeness, from HOST-PRINTED lines only.

    Delegates the prose contract to channel.py's `_completeness` (shared with
    the MCP tools, so the two cannot drift) and adds the one refusal it does
    not name: `... was found to use as a root. Nothing was searched.` That
    line means ZERO nodes were visited, which is NOTHING_EXAMINED, not
    UNKNOWN and emphatically not a walk whose 0 hits mean anything.
    """
    h = host_text(raw)
    low = h.lower()
    if "nothing was searched" in low:
        return "NOTHING_EXAMINED", h
    comp, _trust = ch._completeness(h)
    return comp, h


def find_hits(raw):
    """find/findtext hits, parsed off host-printed lines only."""
    return ch.parse_find(host_text(raw))["hits"]


def trusted_walk(raw):
    """(ok, completeness). ok is True ONLY for EXHAUSTIVE -- every other value
    means a count taken from this walk cannot decide anything, INCLUDING a
    count of zero. A 0 out of a STOPPED_EARLY or NOTHING_EXAMINED walk used to
    be reported as FAIL ("got 0, want 4"); that is the flagship case of a
    verdict asserted about work that was never done."""
    comp, _h = completeness_of(raw)
    return comp == "EXHAUSTIVE", comp


_ACT_RE = re.compile(r"^\s*(PASS|FAIL|INCONCLUSIVE):\s*(.*)$")


def active_states(live, ptrs, timeout=40):
    """activeInHierarchy for each pointer, via the inspector's own
    `assert-active` verb -- NOT `activeSelf`, and not a field read.

    Returns a list the same length as `ptrs` of True / False / None, where
    None is the inspector's own INCONCLUSIVE (pointer unreadable, Unity
    fake-null, or the getter did not verify on this build). Returns None
    instead of a list if the verdict lines could not be matched 1:1 to the
    commands -- guessing an alignment there would silently attribute one
    node's state to another.

    Why `assert-active` and not `children`/`find` output: neither verb prints
    an active flag at all, so the previous version's
    `[l for l in raw if "active=true" in l]` matched NOTHING on any real
    answer and every such count was structurally 0.
    """
    if not ptrs:
        return []
    cmds = ["assert-active %s" % p for p in ptrs]
    _s, raw = ch.run_batch(cmds, live_dir=live, timeout=timeout)
    verdicts = []
    for line in host_text(raw).splitlines():
        m = _ACT_RE.match(line)
        if not m:
            continue
        kind, rest = m.group(1), m.group(2)
        if kind == "INCONCLUSIVE":
            verdicts.append(None)
        else:
            am = re.search(r"activeInHierarchy\s*=\s*(true|false)", rest, re.I)
            verdicts.append(am.group(1).lower() == "true" if am else None)
    if len(verdicts) != len(ptrs):
        return None
    return verdicts


def settings_bound(live, timeout=25):
    """(ok, ptr_or_note) -- is `$settings` bound? Every settings-screen walk
    below is rooted at it, because MEASURED tonight (nativetabs_check.py,
    0d447b9/5d2446d): a ROOTLESS `find`/`findtext` at the main menu walks
    ~18k+ nodes and STOPS EARLY on the node budget, while the same search
    rooted at $settings is EXHAUSTIVE in ~1263 nodes. A rootless walk here
    cannot produce a trustworthy negative, so it must not be issued at all."""
    _s, raw = ch.run_batch(["state"], live_dir=live, timeout=timeout)
    m = re.search(r"\$settings=(0x[0-9a-fA-F]+)", host_text(raw))
    if not m:
        return False, "`state` did not report a $settings anchor at all"
    if int(m.group(1), 16) == 0:
        return False, "$settings is null -- the Settings screen has not been opened"
    return True, m.group(1)


# ---------------------------------------------------------------------------
# assertions
# ---------------------------------------------------------------------------

def _toggle_strip_children(live):
    """(ptrs, names, note). The top-row tab strip is `Toggles`, the direct
    child of SettingsScreen; its children are the tab spawners. Rooted at
    $settings with WALK_BUDGET, which is EXHAUSTIVE in ~1263 nodes (measured
    2026-09-02); the same search rootless STOPS EARLY and decides nothing."""
    _s, raw = ch.run_batch(["find Toggles %s %d" % (SETTINGS_ROOT, WALK_BUDGET)],
                            live_dir=live, timeout=40)
    ok, comp = trusted_walk(raw)
    if not ok:
        return None, None, "the `find Toggles` walk was %s, not EXHAUSTIVE" % comp
    strip = [h for h in find_hits(raw)
             if h["name"] == "Toggles" and h["parent"] == "SettingsScreen"]
    if not strip:
        names = ", ".join(h["name"] for h in find_hits(raw)[:8]) or "none"
        return None, None, ("the walk was EXHAUSTIVE but no node named exactly "
                            "`Toggles` with parent `SettingsScreen` was in it "
                            "(hits: %s)" % names)
    _s, raw2 = ch.run_batch(["children %s" % strip[0]["ptr"]],
                             live_dir=live, timeout=40)
    kids = ch.parse_children(host_text(raw2))
    if not kids["parse_ok"] or kids["child_count"] is None:
        return None, None, ("`children %s` did not answer with a child list"
                            % strip[0]["ptr"])
    if any(k.get("unreadable") for k in kids["children"]):
        return None, None, "one or more children of the tab strip were unreadable"
    if kids["child_count"] != len(kids["children"]):
        return None, None, ("childCount=%d but %d child line(s) were printed"
                            % (kids["child_count"], len(kids["children"])))
    return ([k["ptr"] for k in kids["children"]],
            [k["name"] for k in kids["children"]], "")


def assert_tab_count(report, live, mods_built):
    """Stock top-row tabs, counted by NAME and by activeInHierarchy, with the
    names printed so the number can be checked rather than believed."""
    ptrs, names, note = _toggle_strip_children(live)
    if ptrs is None:
        report.record("top-row stock tab count", INCONCLUSIVE, note)
        report.record("top-row mod tab clones", INCONCLUSIVE, note)
        return
    acts = active_states(live, ptrs)
    if acts is None or None in (acts or []):
        report.record("top-row stock tab count", INCONCLUSIVE,
                      "activeInHierarchy could not be established for every "
                      "one of the %d tab-strip children" % len(ptrs),
                      ", ".join(names))
        report.record("top-row mod tab clones", INCONCLUSIVE,
                      "same: active state unknown for at least one child")
        return

    stock_on = [n for n, a in zip(names, acts) if a and "(Clone)" not in n]
    stock_off = [n for n, a in zip(names, acts) if not a and "(Clone)" not in n]
    clones_on = [n for n, a in zip(names, acts) if a and "(Clone)" in n]

    # 4, not 5: PostFxToggleSpawner is present but activeInHierarchy=FALSE
    # because settingsPostFxSubtab folds POSTFX into GRAPHICS as a subtab.
    want = 4
    v = PASS if len(stock_on) == want else FAIL
    report.record("top-row stock tab count", v,
                  "%d active, want %d" % (len(stock_on), want),
                  "active: %s | inactive: %s"
                  % (", ".join(stock_on) or "none",
                     ", ".join(stock_off) or "none"))

    if not mods_built:
        report.record("top-row mod tab clones", INCONCLUSIVE,
                      "mods_built=False, so there is no expected clone count "
                      "to compare against; %d active clone(s) observed"
                      % len(clones_on),
                      ", ".join(clones_on) or "none")
    else:
        v = PASS if len(clones_on) >= 1 else FAIL
        report.record("top-row mod tab clones", v,
                      "%d active clone(s)" % len(clones_on),
                      ", ".join(clones_on) or "none")


def _findtext(live, needle, timeout=60):
    return ch.run_batch(["findtext %s %s %d all" % (needle, SETTINGS_ROOT,
                                                     WALK_BUDGET)],
                         live_dir=live, timeout=timeout)[1]


def assert_no_text(report, live, name, needle):
    """An ABSENCE claim, so it needs a POSITIVE CONTROL or it passes vacuously.

    MEASURED 2026-09-02 on the live client: `findtext e $settings 40000 all`
    visited all 1263 nodes of an open Settings screen full of captions and
    reported `0 match(es) ... genuinely NOT PRESENT`. findtext cannot read
    text on this build, so EVERY absence it reports here is vacuous. Without
    this control the two assertions below would both print PASS and mean
    nothing at all -- exactly the failure CLAUDE.md 9b names.
    """
    ctl_raw = _findtext(live, FINDTEXT_CONTROL)
    ok, comp = trusted_walk(ctl_raw)
    if not ok:
        report.record(name, INCONCLUSIVE,
                      "positive control `findtext %s` walk was %s, not "
                      "EXHAUSTIVE" % (FINDTEXT_CONTROL, comp))
        return
    if not find_hits(ctl_raw):
        report.record(name, INCONCLUSIVE,
                      "POSITIVE CONTROL FAILED: `findtext %s` found 0 TMP "
                      "text under an open Settings screen, so findtext is not "
                      "reading text on this build and its absence verdicts "
                      "prove nothing" % FINDTEXT_CONTROL)
        return

    raw = _findtext(live, needle, timeout=90)
    ok, comp = trusted_walk(raw)
    if not ok:
        report.record(name, INCONCLUSIVE,
                      "walk was %s, not EXHAUSTIVE -- absence not provable" % comp)
        return
    hits = find_hits(raw)
    f = ch.parse_findtext(host_text(raw))
    v = FAIL if hits else PASS
    report.record(name, v, "%d occurrence(s) of %r, scope=%s"
                  % (len(hits), needle, f["scope"]),
                  "; ".join("%s@%s" % (h["name"], h["ptr"]) for h in hits[:5]))


def assert_spawner_one_active_toggle(report, live, mods_built):
    """The cloned MODS spawner. There is nothing to assert about it when the
    mods tab was not built into the deploy, and saying PASS in that case would
    be a check that cannot fail."""
    if not mods_built:
        report.record("cloned mods spawner: exactly one active toggle",
                      INCONCLUSIVE,
                      "mods_built=False -- the mods tab clone is not in this "
                      "deploy, so nothing was looked at")
        return
    ptrs, names, note = _toggle_strip_children(live)
    if ptrs is None:
        report.record("cloned mods spawner: exactly one active toggle",
                      INCONCLUSIVE, note)
        return
    idx = [i for i, n in enumerate(names) if "(Clone)" in n]
    if not idx:
        report.record("cloned mods spawner: exactly one active toggle", FAIL,
                      "mods_built=True but the tab strip has no `(Clone)` child",
                      ", ".join(names))
        return
    acts = active_states(live, [ptrs[i] for i in idx])
    if acts is None or None in acts:
        report.record("cloned mods spawner: exactly one active toggle",
                      INCONCLUSIVE,
                      "activeInHierarchy unknown for at least one clone")
        return
    got = sum(1 for a in acts if a)
    v = PASS if got == 1 else FAIL
    report.record("cloned mods spawner: exactly one active toggle", v,
                  "%d of %d clone(s) active" % (got, len(idx)),
                  ", ".join(names[i] for i in idx))


def assert_postfx_subtab(report, live):
    """POSTFX folded into GRAPHICS: the subtab strip is a `Toggles(Clone)`
    child of `Graphics Settings`. Falsifiable: it is absent, or it has fewer
    than two subtabs, and this FAILS.

    The m_Group@0x110 / m_IsOn@0x120 half of the old assertion is NOT
    performed and is reported as such -- reaching a `Toggle` component needs
    the `component` verb, and MEASURED 2026-09-02 that verb FAULTED 5 times
    out of 5 on this build (`GameObject::GetComponent(String)` @0x2a8510),
    each fault spending one of the inspector's 8 per-session fault budget.
    Running it here would disable the inspector mid-run.
    """
    _s, raw = ch.run_batch(["tree %s 2" % SETTINGS_ROOT], live_dir=live,
                            timeout=40)
    t = ch.parse_tree(host_text(raw))
    if not t["parse_ok"] or not t["complete"]:
        report.record("postfx subtab strip under GRAPHICS", INCONCLUSIVE,
                      "`tree %s 2` did not print a complete tree" % SETTINGS_ROOT)
        return
    nodes = t["nodes"]
    gi = next((i for i, n in enumerate(nodes)
               if n["name"] == "Graphics Settings"), None)
    if gi is None:
        report.record("postfx subtab strip under GRAPHICS", INCONCLUSIVE,
                      "no `Graphics Settings` node in the settings tree")
        return
    # depth-2 tree: the children of Graphics Settings are the nodes after it,
    # up to the next node that is itself a child of SettingsScreen. Bound the
    # slice by the NEXT known panel/child name rather than by indentation
    # width, which parse_tree does not expose.
    sub = []
    for n in nodes[gi + 1:]:
        if n["name"] in ("PostFX Settings", "Sound Settings", "Control Settings"):
            break
        sub.append(n)
    strip = [n for n in sub if n["name"] == "Toggles(Clone)"]
    if not strip:
        report.record("postfx subtab strip under GRAPHICS", FAIL,
                      "no `Toggles(Clone)` subtab strip under `Graphics "
                      "Settings`", ", ".join(n["name"] for n in sub) or "none")
    else:
        nsub = strip[0]["child_count"]
        v = PASS if (nsub or 0) >= 2 else FAIL
        report.record("postfx subtab strip under GRAPHICS", v,
                      "subtab strip present with %s child(ren)" % nsub,
                      strip[0]["ptr"])
    report.record("postfx toggles share a group, one is on", INCONCLUSIVE,
                  "NOT PERFORMED: reading Toggle.m_Group@0x110 needs the "
                  "`component` verb, which FAULTED 5/5 on this build and "
                  "spends the inspector's 8-fault session budget")


def assert_one_panel_active(report, live):
    """EXACTLY ONE of the stock settings panels is active.

    The old version searched `find SettingsPanel in Group<N> all` for N=0..4.
    MEASURED: no node named `Group0`..`Group4` exists, so every one of those
    five walks was refused with `Nothing was searched.` and 0 nodes visited --
    five assertions that could never have decided anything. The real panels
    are the direct children of SettingsScreen whose names end in ` Settings`.
    """
    _s, raw = ch.run_batch(["tree %s 1" % SETTINGS_ROOT], live_dir=live,
                            timeout=40)
    t = ch.parse_tree(host_text(raw))
    if not t["parse_ok"] or not t["complete"]:
        report.record("exactly one settings panel is active", INCONCLUSIVE,
                      "`tree %s 1` did not print a complete tree" % SETTINGS_ROOT)
        return
    panels = [n for n in t["nodes"]
              if not n["is_root"] and n["name"].endswith(" Settings")]
    if len(panels) < 2:
        report.record("exactly one settings panel is active", INCONCLUSIVE,
                      "only %d panel(s) named `* Settings` were seen under "
                      "SettingsScreen; that is not a panel set" % len(panels),
                      ", ".join(n["name"] for n in t["nodes"] if not n["is_root"]))
        return
    acts = active_states(live, [p["ptr"] for p in panels])
    if acts is None or None in acts:
        report.record("exactly one settings panel is active", INCONCLUSIVE,
                      "activeInHierarchy could not be established for all %d "
                      "panels" % len(panels),
                      ", ".join(p["name"] for p in panels))
        return
    on = [p["name"] for p, a in zip(panels, acts) if a]
    v = PASS if len(on) == 1 else FAIL
    report.record("exactly one settings panel is active", v,
                  "%d of %d panel(s) active" % (len(on), len(panels)),
                  "active: %s | all: %s" % (", ".join(on) or "none",
                                             ", ".join(p["name"] for p in panels)))


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

    # If Settings is ALREADY open there is nothing to navigate: `$settings`
    # being bound is the finished state the open path exists to reach, so
    # asking for it first avoids re-pressing (and re-deriving) a screen that
    # is already up. Only when it is NOT bound do we walk the open path.
    bound, ptr = settings_bound(live)
    if bound:
        report.record("settings screen opened", PASS,
                      "$settings already bound at %s" % ptr)
    else:
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
        # Pressing is not opening. Assert the FINISHED STATE -- the anchor the
        # host binds only once the screen really exists -- never the press.
        bound, ptr = False, "never bound"
        for _ in range(10):
            time.sleep(1.0)
            bound, ptr = settings_bound(live)
            if bound:
                break
        if not bound:
            report.record("settings screen opened", INCONCLUSIVE,
                          "pressed Settings (%s) but $settings never bound: %s"
                          % (detail, ptr))
            report.summary()
            return 2
        report.record("settings screen opened", PASS,
                      "%s; $settings bound at %s" % (detail, ptr))

    assert_tab_count(report, live, args.mods_built)
    assert_no_text(report, live, "no donor caption under MODS", DONOR_CAPTION)
    assert_no_text(report, live, "no placeholder text anywhere", PLACEHOLDER_TEXT)
    assert_spawner_one_active_toggle(report, live, args.mods_built)
    assert_postfx_subtab(report, live)
    assert_one_panel_active(report, live)
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
