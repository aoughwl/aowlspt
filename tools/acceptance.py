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
import inspectfixtures as _fixtures  # noqa: E402 -- the shared measured corpus

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

# THE POSITIVE CONTROL THAT GATES EVERY ABSENCE CLAIM IS NOW IN-BAND.
# There used to be a separate control walk here, `findtext e`, on the reasoning
# that a settings screen yielding zero hits for the commonest letter in English
# has proved only that findtext cannot read text. The reasoning was right and
# the implementation could never pass: `e` matches far more than the 24-match
# cap, so the control always ended HIT_CAP and every absence claim was reported
# INCONCLUSIVE on the control rather than on the evidence -- at the cost of a
# second full 40k-node traversal each time. The host prints its own control on
# every findtext report (`predicate control: N node(s) carried a
# TextMeshProUGUI (of M visited)`), measured on the SAME walk. See
# findtext_control().

SETTINGS_ROOT = "$settings"      # bound once Settings is open; `state` shows it
WALK_BUDGET = 40000              # measured 2026-09-02: EXHAUSTIVE in 7735 nodes


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


# ---------------------------------------------------------------------------
# findtext HIT lines -- parsed HERE, because channel.py's shared _HIT_RE
# CANNOT MATCH THEM. Measured 2026-09-02.
# ---------------------------------------------------------------------------
# `plugins/aowlsptcode/mcp/channel.py:290` reads, after the name and optional
# parent:  (?:\s+text="(?P<text>[^"]*)")? (?:\s+active=(true|false))?
# \s*\(\$(?P<var>f\d+)\)
#
# A real findtext hit on this build is:
#
#   HIT 0x00000203094ddf60  name="Text"  parent="Settings Drop Down(Clone)"  \
#   text="Interface language"  activeInHierarchy=true   ($f1)
#
# The field is `activeInHierarchy=`, not `active=`, so that optional group does
# not match; the regex then requires `($fN)` immediately after `text="..."`,
# finds `activeInHierarchy=true` in the way, and the WHOLE HIT FAILS TO MATCH.
# `parse_find`/`parse_findtext` therefore return ZERO HITS for every findtext
# answer that carries an active flag -- i.e. every one of them. Verified:
# ch.parse_find(<the verbatim line above>)["hits"] == [].
#
# That is a confidently-wrong answer in a SHARED parser (the MCP
# `inspect_findtext` tool reads the same function), and it is reported as a P0
# rather than patched from here: channel.py is not this task's to change. This
# local parser is deliberately narrow -- findtext hits only -- and additionally
# keeps the field channel.py drops entirely, `activeInHierarchy`, which several
# assertions below must have (fact #72: an inactive node is not pressable, and
# placeholder text nothing renders is not a defect).
_FT_HIT_RE = re.compile(
    r'HIT\s+(?P<ptr>0x[0-9a-fA-F]+)\s+name="(?P<name>[^"]*)"'
    r'(?:\s+parent="(?P<parent>[^"]*)")?'
    r'(?:\s+text="(?P<text>[^"]*)")?'
    r'(?:\s+activeInHierarchy=(?P<active>[Tt]rue|[Ff]alse|TRUE|FALSE))?'
    # `.*?` and not `[^()]*`: an INACTIVE hit prints
    # `activeInHierarchy=FALSE (unpressable)   ($f1)`, so the tail legitimately
    # contains parentheses. No DOTALL, so this still cannot span lines.
    r'.*?\(\$(?P<var>f\d+)\)')

# The host's OWN positive control, printed in-band on every findtext report:
#   predicate control: 225 node(s) carried a TextMeshProUGUI (of 1297 visited)
#     -- the predicate demonstrably CAN answer yes on this subtree.
_FT_CONTROL_RE = re.compile(
    r'predicate control:\s*(?P<seen>\d+)\s+node\(s\) carried a '
    r'TextMeshProUGUI\s*\(of\s*(?P<visited>\d+)\s+visited\)')


def findtext_hits(raw):
    """findtext hits off HOST-PRINTED lines only, with text and active state."""
    out = []
    for m in _FT_HIT_RE.finditer(host_text(raw)):
        a = m.group("active")
        out.append({"ptr": m.group("ptr"), "name": m.group("name"),
                    "parent": m.group("parent"), "text": m.group("text"),
                    "active": None if a is None else a.lower() == "true",
                    "var": "$" + m.group("var")})
    return out


def findtext_control(raw):
    """(tmp_seen, visited) from the host's own in-band predicate control, or
    (None, None) if it did not print one.

    This REPLACES the separate `findtext e` control walk that used to gate
    every absence claim here. That walk cost a second full traversal and,
    measured tonight, could not do its job anyway: `e` matches so much that the
    search stops at the 24-match cap, so it reported HIT_CAP and every absence
    claim came back INCONCLUSIVE on the control rather than on the evidence.
    The in-band line is strictly better: it is measured on the SAME walk whose
    absence is being claimed, so it cannot disagree with it."""
    m = _FT_CONTROL_RE.search(host_text(raw))
    if not m:
        return None, None
    return int(m.group("seen")), int(m.group("visited"))


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


INACTIVE_REASON = ("SettingsScreen is bound but not active (another screen "
                   "is up)")

# Every assertion below that reads the SETTINGS SCREEN. When the screen is not
# on display, each of these is reported INCONCLUSIVE by name rather than being
# skipped silently or -- as happened at 03:55 -- run anyway and reported FAIL.
SCREEN_ASSERTION_NAMES = (
    "top-row stock tab count",
    "top-row mod tab clones",
    "no donor caption under MODS row clones",
    "no placeholder text on any RENDERED node",
    "settings tab row group: exactly one toggle is ON",
    "postfx subtab strip under GRAPHICS",
    "postfx toggles share a group, one is on",
    "exactly one settings panel is active",
)


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


def settings_active(live, timeout=40):
    """(True / False / None, note) -- is the SettingsScreen ON DISPLAY?

    MEASURED 2026-09-02 03:55, live: `acceptance.py run --no-launch --keep`
    was started while the client sat on the MatchMaker Side Selection screen
    with Settings dismissed. `$settings` was STILL BOUND (inspect.nim ~4425
    records why: the anchor does NOT go null across a close -- the same
    pointer comes back on reopen), so the run skipped navigation entirely and
    then reported `top-row stock tab count` as FAIL, `0 active, want 4 --
    active: none | inactive: GameToggleSpawner, GraphicsToggleSpawner, ...`.
    Every stock toggle read inactive because the WHOLE SettingsScreen was
    inactive. That FAIL was about a screen that was not on display: a verdict
    asserted about work that could not have succeeded.

    So boundness is NOT readiness. This asks the state that actually differs,
    with the inspector's own `assert-active` verb (activeInHierarchy, via
    Component::get_gameObject -- `$settings` is a SettingsScreen COMPONENT,
    not a Transform, and the verb makes that hop itself). `state` cannot
    answer this: it is field reads only and prints no active flag.

    None means the inspector said INCONCLUSIVE, which is not False.
    """
    acts = active_states(live, [SETTINGS_ROOT], timeout=timeout)
    if not acts:
        return None, ("`assert-active %s` did not print exactly one verdict "
                      "line, so its active state was never established"
                      % SETTINGS_ROOT)
    a = acts[0]
    if a is None:
        return None, ("the inspector answered INCONCLUSIVE for `assert-active "
                      "%s` (unreadable, Unity fake-null, or the getter did not "
                      "verify on this build)" % SETTINGS_ROOT)
    return a, ("activeInHierarchy=true" if a else INACTIVE_REASON)


def wait_active(live, tries=10, delay=1.0):
    """Poll for the FINISHED STATE -- an ACTIVE SettingsScreen -- not for our
    own press. Returns (True/False/None, note) from the last look."""
    act, note = None, "never looked"
    for _ in range(tries):
        time.sleep(delay)
        act, note = settings_active(live)
        if act is True:
            return act, note
    return act, note


def ensure_settings_ready(report, live, args):
    """Get to an OPEN, ACTIVE Settings screen, or say why not.

    Returns (ready, reason). `reason` is the text every screen assertion is
    reported INCONCLUSIVE with when ready is False -- never FAIL, because a
    screen that is not on display falsifies nothing about the host.
    """
    bound, ptr = settings_bound(live)

    if bound:
        act, note = settings_active(live)
        if act is True:
            report.record("settings screen opened", PASS,
                          "$settings already bound at %s and "
                          "activeInHierarchy=true" % ptr)
            return True, ""
        if act is None:
            report.record("settings screen opened", INCONCLUSIVE,
                          "$settings bound at %s but %s" % (ptr, note))
            return False, ("the SettingsScreen's active state could not be "
                           "established: %s" % note)
        # Bound but INACTIVE. One attempt down the EXISTING open path; the
        # `open` verb itself would refuse here (inspect.nim ~4445: ShowScreen
        # on a closed screen escaped its guard), so this is the AnimatedToggle
        # press path, exactly as an unbound run uses.
        print("$settings is bound at %s but the screen is NOT active (%s); "
              "attempting the open path once" % (ptr, INACTIVE_REASON))
        ok, detail = open_settings(live, args.settings_timeout)
        if not ok:
            report.record("settings screen opened", INCONCLUSIVE,
                          "%s; the one re-open attempt did not go through: %s"
                          % (INACTIVE_REASON, detail))
            return False, INACTIVE_REASON
        act, note = wait_active(live)
        if act is True:
            report.record("settings screen opened", PASS,
                          "was bound but inactive; %s and the screen is now "
                          "activeInHierarchy=true" % detail)
            return True, ""
        report.record("settings screen opened", INCONCLUSIVE,
                      "%s; re-opened once (%s) and it is still %s"
                      % (INACTIVE_REASON, detail,
                         "inactive" if act is False else "of unknown state"))
        return False, INACTIVE_REASON

    ok, note = enter_game(args.menu_timeout)
    if not ok:
        report.record("past mode selector", INCONCLUSIVE, note)
        return False, "the mode selector was never passed: %s" % note
    print("menu: %s" % note)

    ok, detail = open_settings(live, args.settings_timeout)
    if not ok:
        report.record("settings screen opened", INCONCLUSIVE, detail)
        return False, "the Settings screen was never opened: %s" % detail

    # Pressing is not opening, and BOUND is not ON DISPLAY. Assert the
    # finished state: an anchor the host binds only once the screen exists,
    # AND that screen being active in the hierarchy.
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
        return False, "$settings never bound after the open path ran"
    act, note = wait_active(live)
    if act is not True:
        report.record("settings screen opened", INCONCLUSIVE,
                      "pressed Settings (%s), $settings bound at %s, but %s"
                      % (detail, ptr, note))
        return False, (INACTIVE_REASON if act is False else
                       "the SettingsScreen's active state could not be "
                       "established: %s" % note)
    report.record("settings screen opened", PASS,
                  "%s; $settings bound at %s and activeInHierarchy=true"
                  % (detail, ptr))
    return True, ""


# ---------------------------------------------------------------------------
# assertions
# ---------------------------------------------------------------------------

def _toggle_strip_ptr(live):
    """(ptr, note). The top-row tab strip is `Toggles`, the direct child of
    SettingsScreen. Rooted at $settings with WALK_BUDGET, which is EXHAUSTIVE
    (measured 2026-09-02: 7735 nodes, 18 hits); the same search rootless STOPS
    EARLY and decides nothing."""
    _s, raw = ch.run_batch(["find Toggles %s %d" % (SETTINGS_ROOT, WALK_BUDGET)],
                            live_dir=live, timeout=90)
    ok, comp = trusted_walk(raw)
    if not ok:
        return None, "the `find Toggles` walk was %s, not EXHAUSTIVE" % comp
    strip = [h for h in find_hits(raw)
             if h["name"] == "Toggles" and h["parent"] == "SettingsScreen"]
    if not strip:
        names = ", ".join(h["name"] for h in find_hits(raw)[:8]) or "none"
        return None, ("the walk was EXHAUSTIVE but no node named exactly "
                      "`Toggles` with parent `SettingsScreen` was in it "
                      "(hits: %s)" % names)
    return strip[0]["ptr"], ""


def _toggle_strip_children(live):
    """(strip_ptr, ptrs, names, note) -- the tab spawners, the strip's direct
    children. The strip pointer comes back too so a caller that also needs the
    tree does not pay for a second `find Toggles` walk (7735 nodes, ~60 frames
    -- measured, and it was being issued twice per run)."""
    strip, note = _toggle_strip_ptr(live)
    if strip is None:
        return None, None, None, note
    _s, raw2 = ch.run_batch(["children %s" % strip],
                             live_dir=live, timeout=40)
    kids = ch.parse_children(host_text(raw2))
    if not kids["parse_ok"] or kids["child_count"] is None:
        return None, None, None, ("`children %s` did not answer with a child "
                                  "list" % strip)
    if any(k.get("unreadable") for k in kids["children"]):
        return None, None, None, ("one or more children of the tab strip were "
                                  "unreadable")
    if kids["child_count"] != len(kids["children"]):
        return None, None, None, ("childCount=%d but %d child line(s) were "
                                  "printed" % (kids["child_count"],
                                                len(kids["children"])))
    return (strip, [k["ptr"] for k in kids["children"]],
            [k["name"] for k in kids["children"]], "")


_PUBLISHED_RE = re.compile(
    r'published\s+(?P<n>\d+)\s+of\s+(?P<total>\d+)\s+client-side settings '
    r'page\(s\)')


def published_pages(root):
    """(n, total, note) -- how many client-side settings pages the HOST says it
    published, from its own log line:

      client settings bridge: published 8 of 8 client-side settings page(s)
      to the backend

    n is None when the line is absent, and the caller must then report
    INCONCLUSIVE rather than fall back to a number. This exists because the
    expected number of mod tab clones was HARDCODED here (`>= 1`), which is a
    check that cannot fail: seven published pages and one clone would have
    passed. The host already knows the answer; ask it.

    The LAST occurrence wins -- the bridge re-publishes every 60s, and an early
    line can legitimately say `published 0 of 8` before the pages are built.
    """
    ns = argparse.Namespace(root=os.path.join(root, "aowlspt"), backend=False)
    try:
        _p, lines = hostlog.read(ns)
    except SystemExit:
        return None, None, "the host log could not be read"
    n = total = None
    for row in hostlog.parse(lines):
        m = _PUBLISHED_RE.search(row[2])
        if m:
            n, total = int(m.group("n")), int(m.group("total"))
    if n is None:
        return None, None, ("the host log has no `published N of M client-side "
                            "settings page(s)` line, so the expected number of "
                            "mod tab clones is not known")
    return n, total, ""


def assert_tab_count(report, live, mods_built, published=None, pub_note=""):
    """Stock top-row tabs, counted by NAME and by activeInHierarchy, with the
    names printed so the number can be checked rather than believed."""
    _strip, ptrs, names, note = _toggle_strip_children(live)
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
    elif published is None:
        # NOT a fallback to `>= 1`, which is what this used to assert: with a
        # hardcoded floor of one, seven missing tabs pass.
        report.record("top-row mod tab clones", INCONCLUSIVE,
                      "%d active clone(s), but the expected count is not known: "
                      "%s" % (len(clones_on), pub_note),
                      ", ".join(clones_on) or "none")
    else:
        v = PASS if len(clones_on) == published else FAIL
        report.record("top-row mod tab clones", v,
                      "%d active clone(s), want %d (host log: published %d "
                      "client-side settings page(s))"
                      % (len(clones_on), published, published),
                      ", ".join(clones_on) or "none")


def _findtext(live, needle, timeout=60):
    """`findtext` with the needle QUOTED. This is the bug that made every
    text assertion here undecidable, measured 2026-09-02.

    `findtext SUBSTR [ROOT] [BUDGET] [all]` takes ONE token as the needle
    (inspect.nim iCmdFindText, ~3193: `let want = ftoks[1]`). Sending
    `findtext Interface language $settings 40000 all` unquoted therefore
    searched for "Interface" and handed `language` to iFindResolveRoot AS THE
    ROOT; that is not a live pointer, so the command was refused and the reply
    carried no walk verdict at all -- which is exactly the
    `walk was UNKNOWN, not EXHAUSTIVE` that both text assertions printed. The
    needle was never searched for. `PLACEHOLDER_TEXT` ("SOME TEXT") had the
    same shape.

    iSplit (inspect.nim ~619) keeps a double-quoted run together, so the fix is
    to quote. A needle containing a quote cannot be expressed in that grammar,
    so it is REFUSED here rather than sent to be mis-split."""
    if '"' in needle:
        raise ValueError(
            "findtext needle %r contains a double quote; the inspector's "
            "tokenizer cannot express that and would silently re-split the "
            "command line into different arguments" % needle)
    return ch.run_batch(['findtext "%s" %s %d all' % (needle, SETTINGS_ROOT,
                                                       WALK_BUDGET)],
                         live_dir=live, timeout=timeout)[1]


def assert_no_text(report, live, name, needle):
    """An ABSENCE claim, so it needs a POSITIVE CONTROL or it passes vacuously.

    The control is now the host's OWN in-band `predicate control:` line, taken
    from the same walk (see findtext_control) rather than a second `findtext e`
    traversal -- that one could never pass, because `e` stops at the 24-match
    cap and a HIT_CAP control was treated as no control at all.

    ACTIVE-ONLY VERDICT, stated rather than assumed. The walk is issued with
    `all` so the evidence is complete, but only hits on nodes that
    `activeInHierarchy=true` can decide FAIL. Measured 2026-09-02: `findtext
    "SOME TEXT" $settings 40000 all` is EXHAUSTIVE with TWELVE hits, and every
    one of them is `activeInHierarchy=FALSE` -- the stock donor prefabs
    (`AnimatedToggle`/`SizeLabel`) ship carrying the placeholder and nothing
    renders them. Failing on those would be failing on the game's own assets;
    the inactive count is printed instead so it can never vanish silently.
    """
    raw = _findtext(live, needle, timeout=90)
    seen, visited = findtext_control(raw)
    if seen is None:
        report.record(name, INCONCLUSIVE,
                      "the reply carried no in-band `predicate control:` line, "
                      "so it is not known that findtext could read ANY text on "
                      "this walk; an absence from it proves nothing")
        return
    if seen == 0:
        report.record(name, INCONCLUSIVE,
                      "POSITIVE CONTROL FAILED: 0 of %s visited node(s) carried "
                      "a TextMeshProUGUI, so the predicate never had anything "
                      "to match and its 'not present' means nothing" % visited)
        return
    ok, comp = trusted_walk(raw)
    if not ok:
        report.record(name, INCONCLUSIVE,
                      "walk was %s, not EXHAUSTIVE -- absence not provable"
                      % comp)
        return
    hits = findtext_hits(raw)
    f = ch.parse_findtext(host_text(raw))
    unknown = [h for h in hits if h["active"] is None]
    if unknown:
        report.record(name, INCONCLUSIVE,
                      "%d of %d hit(s) printed no activeInHierarchy flag, so it "
                      "is not known whether anything renders them"
                      % (len(unknown), len(hits)),
                      "; ".join("%s@%s" % (h["name"], h["ptr"])
                                for h in unknown[:5]))
        return
    live_hits = [h for h in hits if h["active"]]
    dead = [h for h in hits if not h["active"]]
    v = FAIL if live_hits else PASS
    report.record(name, v,
                  "%d rendered occurrence(s) of %r (+%d on inactive, "
                  "unrendered nodes), scope=%s, control %d TMP of %s visited"
                  % (len(live_hits), needle, len(dead), f["scope"], seen,
                     visited),
                  "; ".join("%s under %s @%s" % (h["name"], h["parent"],
                                                  h["ptr"])
                             for h in (live_hits or dead)[:5]))


CLONE_MARK = "(Clone)(Clone)"


def assert_no_donor_caption_on_clones(report, live, mods_built):
    """The rows we CLONED must not still read the row donor's caption.

    Why this is not `assert_no_text(..., DONOR_CAPTION)`, which is what it
    replaced: "Interface language" is a REAL caption on this screen. The stock
    Game-tab row shows it legitimately, so a blanket "zero occurrences under
    $settings" assertion is false by construction and would FAIL forever no
    matter what the host does. The claim that is actually worth making is
    SCOPED: zero occurrences on a node whose parent is one of OUR row clones,
    which the inspector names `Settings Drop Down(Clone)(Clone)` -- a clone of
    a clone, because we clone the stock dropdown row.

    MEASURED 2026-09-02, live, build 4,717,056, Settings open:
    `findtext Interface language $settings 40000` returned FOUR hits -- one
    genuine `Text` under `Settings Drop Down(Clone)` (the stock row) and THREE
    `Text` nodes under `Settings Drop Down(Clone)(Clone)`, all
    activeInHierarchy=true. Those three are the defect: the row relabel wrote
    them, verified them microseconds later, and `LocalizedText` put the
    donor's key back afterwards with nothing watching. That is the state this
    assertion exists to catch, and it is exactly the shape it FAILS on.

    THE CONTROL THAT MAKES THIS FALSIFIABLE IS THE STOCK HIT ITSELF. If the
    walk finds ZERO occurrences of the caption anywhere, findtext is not
    reading this string on this build and a count of zero under the clones
    proves nothing -- so that is INCONCLUSIVE, never PASS. A check whose
    needle is known to be present somewhere carries its own positive control.
    """
    name = "no donor caption under MODS row clones"
    if not mods_built:
        report.record(name, INCONCLUSIVE,
                      "mods_built=False -- there are no row clones in this "
                      "deploy, so nothing was looked at")
        return

    raw = _findtext(live, DONOR_CAPTION, timeout=90)
    hits = findtext_hits(raw)
    f = ch.parse_findtext(host_text(raw))
    _ok, comp = trusted_walk(raw)

    # COMPLETENESS IS ONLY NEEDED FOR THE NEGATIVE. A hit under a clone is a
    # hit: it decides FAIL no matter how the walk ended. Measured 2026-09-02,
    # this walk really does end HIT_CAP (24 matches is the cap and this needle
    # alone produces 24), so requiring EXHAUSTIVE before looking at the hits --
    # which is what this used to do -- threw away a decisive positive and
    # printed INCONCLUSIVE on a screen that was visibly wrong.
    if not hits and comp != "EXHAUSTIVE":
        report.record(name, INCONCLUSIVE,
                      "walk was %s, not EXHAUSTIVE, and it found nothing -- an "
                      "absence under the clones is not provable from it" % comp)
        return

    if not hits:
        report.record(name, INCONCLUSIVE,
                      "POSITIVE CONTROL FAILED: an EXHAUSTIVE walk of an open "
                      "Settings screen found 0 occurrences of %r, but the "
                      "STOCK Game-tab row shows it. findtext is not reading "
                      "this caption, so zero under the clones means nothing"
                      % DONOR_CAPTION)
        return

    unclassifiable = [h for h in hits if not h.get("parent")]
    if unclassifiable:
        report.record(name, INCONCLUSIVE,
                      "%d of %d hit(s) printed no parent= field, so they "
                      "cannot be attributed to a clone or to stock; guessing "
                      "would put a stock hit in our column"
                      % (len(unclassifiable), len(hits)),
                      "; ".join(h["name"] + "@" + h["ptr"]
                                for h in unclassifiable[:5]))
        return

    ours = [h for h in hits if CLONE_MARK in h["parent"]]
    stock = [h for h in hits if CLONE_MARK not in h["parent"]]
    detail = "; ".join("%s under %s @%s" % (h["name"], h["parent"], h["ptr"])
                       for h in (ours or stock)[:5])
    measured = ("%d hit(s) of %r, walk %s, scope=%s: %d under %s (must be 0), "
                "%d stock (positive control, must be >0)"
                % (len(hits), DONOR_CAPTION, comp, f["scope"], len(ours),
                   CLONE_MARK, len(stock)))
    if ours:
        report.record(name, FAIL, measured, detail)
    elif not stock:
        report.record(name, INCONCLUSIVE, measured,
                      "every hit sits under a clone-of-a-clone and none under "
                      "the STOCK row, so the positive control that makes a "
                      "zero meaningful is missing")
    elif comp != "EXHAUSTIVE":
        # 0 under the clones, but the walk stopped: the very next unvisited
        # node could have been one. A capped walk cannot carry a negative.
        report.record(name, INCONCLUSIVE, measured,
                      "0 under %s, but the walk ended %s -- `findtext more` "
                      "would be needed before that zero means anything"
                      % (CLONE_MARK, comp))
    else:
        report.record(name, PASS, measured, detail)


# UnityEngine.UI.Toggle field offsets. NOT guessed and not taken from a
# comment: measured offline on this build with
#   python tools/fldoff.py field UnityEngine.UI.Toggle m_IsOn   -> 0x120
#   python tools/fldoff.py field UnityEngine.UI.Toggle m_Group  -> 0x110
# (fldoff self-checks System.String._stringLength@0x10 before answering).
TOGGLE_TYPE = "UnityEngine.UI.Toggle"
TOGGLE_ISON_OFF = 0x120

_COMP_FOUND_RE = re.compile(
    r'FOUND\s+(?P<type>[\w.]+)\s+component\s*=\s*(?P<ptr>0x[0-9a-fA-F]+)\s+'
    r'klass=(?P<klass>0x[0-9a-fA-F]+)')
_READ_AT_RE = re.compile(
    r'^\s*(?P<addr>0x[0-9a-fA-F]+)\s+as\s+(?P<type>\w+)\s*=\s*(?P<val>\S+)')


def read_toggle_ison(live, node_ptr, timeout=40):
    """(True / False / None, note) -- Toggle.m_IsOn on `node_ptr`.

    None is INCONCLUSIVE and is never collapsed to False. The two ways this
    goes wrong are both checked, not assumed:

    * the object may have no Toggle at all. `component` then prints an `iErr`
      line (`GetComponent(Type) returned NULL -- an ANSWER`), which
      parse_component reports as not-found. Measured shape recorded as fixture
      `component-toggle-absent`.
    * `$comp` STALENESS. A failed `component` has historically left `$comp`
      holding the PREVIOUS batch's pointer, so the following `read $comp+0x120`
      answers about a different object entirely -- a confidently wrong value.
      Defeated arithmetically rather than by trust: the inspector prints the
      ADDRESS it read, and it must equal comp + 0x120 exactly.

    The fully-qualified type name is deliberate: bare `Toggle` falls back to
    GetComponent(String) (the host says so), while `UnityEngine.UI.Toggle`
    resolves offline to an Il2CppType and matches by KLASS IDENTITY -- which is
    what makes the 0x120 offset the right offset for whatever came back.
    """
    _s, raw = ch.run_batch(["component %s %s" % (node_ptr, TOGGLE_TYPE),
                            "read $comp+0x%x bool" % TOGGLE_ISON_OFF],
                           live_dir=live, timeout=timeout)
    h = host_text(raw)
    if not ch.parse_component(h)["found"]:
        return None, ("no %s component on %s (or the lookup was refused)"
                      % (TOGGLE_TYPE, node_ptr))
    fm = _COMP_FOUND_RE.search(h)
    if not fm:
        return None, "the FOUND line for %s could not be parsed" % node_ptr
    reads = [m for m in (_READ_AT_RE.match(l) for l in h.splitlines()) if m]
    if len(reads) != 1:
        return None, ("expected exactly one `read` answer for %s, got %d"
                      % (node_ptr, len(reads)))
    r = reads[0]
    want_addr = int(fm.group("ptr"), 16) + TOGGLE_ISON_OFF
    if int(r.group("addr"), 16) != want_addr:
        return None, ("the read answered about 0x%x but the component found "
                      "for %s is at %s, whose m_IsOn is 0x%x -- refusing to "
                      "attribute one object's field to another"
                      % (int(r.group("addr"), 16), node_ptr, fm.group("ptr"),
                         want_addr))
    if r.group("type") != "bool" or r.group("val") not in ("true", "false"):
        return None, ("m_IsOn read back as %s %r, not a bool"
                      % (r.group("type"), r.group("val")))
    return r.group("val") == "true", ""


def _toggle_hosts(live, strip, spawner_ptrs, spawner_names):
    """[(name, toggle_host_ptr)] for each tab spawner, or (None, note).

    The Toggle component is NOT on the spawner: measured, each spawner has
    exactly one child (`GameToggle`, `GameToggle(Clone)`, ...) and the Toggle
    lives there. One `tree <strip> 2` answers for all of them at once.

    parse_tree exposes no depth, so the spawner/child pairing is not assumed
    from indentation -- it is CHECKED three ways, and any disagreement is a
    refusal rather than a guess: the node count must be 1 + 2*N, every spawner
    slot must report exactly `(1 child)`, and the spawner slots' pointers must
    equal, in order, the pointers `children` independently reported.
    """
    _s, raw = ch.run_batch(["tree %s 2" % strip], live_dir=live, timeout=60)
    t = ch.parse_tree(host_text(raw))
    if not t["parse_ok"] or not t["complete"]:
        return None, "`tree %s 2` did not print a complete tree" % strip
    nodes = t["nodes"]
    n = len(spawner_ptrs)
    if len(nodes) != 1 + 2 * n:
        return None, ("`tree %s 2` printed %d node(s); %d spawner(s) each with "
                      "one child would print %d, so the parent/child pairing "
                      "cannot be read off positionally"
                      % (strip, len(nodes), n, 1 + 2 * n))
    out = []
    for i in range(n):
        sp, kid = nodes[1 + 2 * i], nodes[2 + 2 * i]
        if sp["ptr"] != spawner_ptrs[i] or sp["name"] != spawner_names[i]:
            return None, ("tree slot %d is %s@%s but `children` reported %s@%s "
                          "there -- the two views disagree"
                          % (i, sp["name"], sp["ptr"], spawner_names[i],
                             spawner_ptrs[i]))
        if sp["child_count"] != 1:
            return None, ("%s reports %s child(ren), not 1, so its Toggle host "
                          "is not the next line" % (sp["name"],
                                                    sp["child_count"]))
        out.append((sp["name"], kid["ptr"]))
    return out, ""


def assert_row_group_one_on(report, live, expected_clones):
    """EXACTLY ONE toggle in the top-row tab group is ON.

    WHAT THIS USED TO CHECK, AND WHY THAT WAS WRONG (measured 2026-09-02):
    it read `activeInHierarchy` of the 8 `GameToggleSpawner(Clone)` objects and
    FAILED with `8 of 8 clone(s) active`. All 8 are legitimately active -- they
    are the 8 top-row tab BUTTONS for the 8 pages the host publishes (`client
    settings bridge: published 8 of 8 client-side settings page(s)`), and a tab
    button you cannot see is a tab you cannot press. Selection is not
    visibility: it is `Toggle.m_IsOn`.

    It is also asserted over the WHOLE ROW GROUP, stock tabs included, not over
    the clones alone. Measured: the 13 toggles (5 stock + 8 clones) all share
    one ToggleGroup, `m_Group` = 0x0000020244f84a80 on every one of them, and
    the single ON toggle was the STOCK `GameToggleSpawner`. "Exactly one of the
    clones is on" is therefore false whenever a stock tab is selected -- which
    is the normal state -- so it could only ever have failed.
    """
    name = "settings tab row group: exactly one toggle is ON"
    strip, ptrs, names, note = _toggle_strip_children(live)
    if ptrs is None:
        report.record(name, INCONCLUSIVE, note)
        return
    members, note = _toggle_hosts(live, strip, ptrs, names)
    if members is None:
        report.record(name, INCONCLUSIVE, note)
        return

    states = []
    for nm, host_ptr in members:
        val, why = read_toggle_ison(live, host_ptr)
        states.append((nm, host_ptr, val, why))

    unknown = [(nm, why) for nm, _p, v, why in states if v is None]
    if unknown:
        report.record(name, INCONCLUSIVE,
                      "Toggle.m_IsOn@0x%x could not be trusted for %d of %d "
                      "toggle(s), so the count of ON is unknown"
                      % (TOGGLE_ISON_OFF, len(unknown), len(states)),
                      "; ".join("%s: %s" % (nm, why) for nm, why in unknown[:3]))
        return

    on = [nm for nm, _p, v, _w in states if v]
    clones = [nm for nm, _p, _v, _w in states if "(Clone)" in nm]
    clone_note = ("%d clone(s)" % len(clones)) if expected_clones is None else (
        "%d clone(s), host log published %d page(s)"
        % (len(clones), expected_clones))
    v = PASS if len(on) == 1 else FAIL
    report.record(name, v,
                  "%d of %d toggle(s) in the group are ON (m_IsOn@0x%x), want "
                  "exactly 1" % (len(on), len(states), TOGGLE_ISON_OFF),
                  "ON: %s | group: %d stock + %s"
                  % (", ".join(on) or "none", len(states) - len(clones),
                     clone_note))


def assert_postfx_subtab(report, live):
    """POSTFX folded into GRAPHICS: the subtab strip is a `Toggles(Clone)`
    child of `Graphics Settings`. Falsifiable: it is absent, or it has fewer
    than two subtabs, and this FAILS.

    The m_Group@0x110 / m_IsOn@0x120 half of the old assertion is still NOT
    performed, but NOT for the reason this docstring used to give. It said the
    `component` verb FAULTED 5/5 on this build and would burn the inspector's
    8-fault session budget. RE-MEASURED 2026-09-02: `component <ptr>
    UnityEngine.UI.Toggle` was issued ~30 times against this live screen with
    ZERO faults -- the fully-qualified name takes the GetComponent(System.Type)
    klass-identity route, not the GetComponent(String) one that verdict came
    from. read_toggle_ison() below now depends on it working.

    What is genuinely missing is the wiring: the strip's 4 children each carry
    their Toggle on an `AnimatedToggle` child (measured), so this needs the
    same tree-pairing + per-toggle read that assert_row_group_one_on does, plus
    its own recorded fixtures and negative controls. Until that exists it stays
    INCONCLUSIVE and says so; a stale excuse is not better than no excuse.
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
                  "NOT PERFORMED: this needs a per-subtab Toggle read that is "
                  "not wired up yet (the strip's 4 children each hold their "
                  "Toggle on one `AnimatedToggle` child, measured 2026-09-02) "
                  "-- it is not a pass and nothing about the group was checked")


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

def run_screen_assertions(report, live, args, ready, reason):
    """Every assertion that READS THE SETTINGS SCREEN, or -- when the screen
    could not be put on display -- one INCONCLUSIVE row per assertion naming
    why. Never FAIL: a screen that is not rendered falsifies nothing about the
    host. One function so the skip list and the run list cannot drift apart
    (and `selftest` checks that they have not)."""
    if not ready:
        for nm in SCREEN_ASSERTION_NAMES:
            report.record(nm, INCONCLUSIVE, "NOT PERFORMED: %s" % reason)
        return
    published, _total, pub_note = published_pages(args.root)
    assert_tab_count(report, live, args.mods_built, published, pub_note)
    assert_no_donor_caption_on_clones(report, live, args.mods_built)
    assert_no_text(report, live, "no placeholder text on any RENDERED node",
                   PLACEHOLDER_TEXT)
    assert_row_group_one_on(report, live, published)
    assert_postfx_subtab(report, live)
    assert_one_panel_active(report, live)


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

    # BOUND IS NOT ON DISPLAY. `$settings` survives a close, so "already
    # bound" used to skip navigation and let every screen assertion run
    # against an INACTIVE screen -- see settings_active()'s docstring for the
    # measured false FAIL that came out of it.
    ready, reason = ensure_settings_ready(report, live, args)

    run_screen_assertions(report, live, args, ready, reason)

    # These two do not read the settings screen, so they still run and still
    # decide something even when the screen could not be reached.
    assert_no_faults(report, root)
    assert_settings_json(report, root, guid=args.guid)

    report.summary()

    if not args.keep and not args.no_launch:
        subprocess.run(["taskkill", "/F", "/IM", "EscapeFromTarkov.exe"],
                       capture_output=True)
        subprocess.run(["taskkill", "/F", "/IM", "aowlspt-backend.exe"],
                       capture_output=True)
        print("stopped the client and the backend (use --keep to leave them up)")

    # 2 == "could not look at the screen at all", distinct from 1 == "looked
    # and something did not hold".
    return 2 if not ready else report.exit_code()


# ---------------------------------------------------------------------------
# selftest -- OFFLINE REPLAY of measured inspector prose
# ---------------------------------------------------------------------------
# There was no offline test for this file before today; the brief for this fix
# assumed there was, so that assumption is corrected here rather than worked
# around. `run_batch` is replaced by a replay that refuses any command it has
# no recording for, so a test can never pass by talking to nothing.
#
# TWO TIERS OF FIXTURE, and the difference matters:
#
#   * `_fixtures.fx("...")` -- VERBATIM host output recorded from a real run,
#     in tools/fixtures/inspector/. Prefer these. They are evidence.
#   * the FX_* / _fx_* strings below -- SHAPED prose in inspect.nim's emit
#     format with synthetic numbers, kept only where a case needs a tree that
#     no capture on this machine happens to contain (the five-spawner strip and
#     its per-toggle active flags). The numbers are synthetic; the SHAPES came
#     from the emit sites. When a real capture of one of these turns up,
#     harvest it into the corpus and delete the synthetic one.

# `_Replay` USED TO LIVE HERE. It is now `inspectfixtures.Replay`, shared with
# nativetabs_check.py, because a private replay per tool is the same failure as
# a private parser per tool: nativetabs_check had none at all and shipped a
# baseline that matched its own `> rect $_` echo, and this file's classifier
# matched the batch header. One replay, one corpus of MEASURED prose under
# tools/fixtures/inspector/, and an unrecorded command still RAISES rather than
# returning an empty answer.
_Replay = _fixtures.Replay


def _hdr(batch, n, body):
    return ("aowlspt live inspector -- batch %d, %d command(s), on Unity "
            "thread 1192\n%s\naowlspt live inspector -- batch %d complete, "
            "%d line(s)" % (batch, n, body, batch, body.count("\n") + 3))


# `state` (iCmdState): MEASURED -- boot3.out batch 18, a real reply with a
# non-null $settings. Note it prints NO active flag anywhere, which is the
# whole reason settings_active() exists.
FX_STATE_BOUND = _fixtures.fx("state-settings-bound")

# `assert-active` (iCmdAssertActive -> iAssPass / iAssFail / iAssInc).
FX_ACTIVE_TRUE = _hdr(92, 1, """> assert-active $settings
  PASS: $settings activeInHierarchy = true, as claimed""")

FX_ACTIVE_FALSE = _hdr(93, 1, """> assert-active $settings
  FAIL: $settings activeInHierarchy = false, but assert-active claimed true.\
  An INACTIVE node is NOT pressable: a press on one reports success and does \
nothing (fact #72).""")

FX_ACTIVE_INC = _hdr(94, 1, """> assert-active $settings
  INCONCLUSIVE: assert-active $settings: activeInHierarchy could not be \
determined (Component::get_gameObject or GameObject::get_activeInHierarchy \
did not verify on this build, or a hop was unreadable)  -- nothing was \
established; this is NOT a pass and NOT a failure.""")

FX_ROOTS = _hdr(95, 1, """> roots
    [$r0] transform=0x000001e4a2b03040  go=0x000001e4a2b03100 ($rgo0)  \
name="Preloader UI"   (DontDestroyOnLoad)
  11 root(s) bound to $r0..$r10""")


def _fx_find(name, ptr, parent, batch=96):
    return _hdr(batch, 1, """> find %s
    HIT %s name="%s"  parent="%s"   ($f1)
  visited 812 node(s) over 3 frame(s), 1 match(es), frontier 0 node(s)
  -- the subtree was searched EXHAUSTIVELY. Every match is listed above."""
                % (name, ptr, name, parent))


FX_PRESS_OK = _hdr(97, 3, """> component 0x0000021c00113000 AnimatedToggle
  $comp = 0x0000021c00114500  (EFT.UI.AnimatedToggle)
> call rva:0x55ba430 v_pb $comp 1
  -> returned without faulting (void)""")

# The tab strip, as `children` really prints it (iCmdChildren, inspect.nim
# ~2163-2182). Five spawners: the four stock tabs plus PostFxToggleSpawner.
_TAB_NAMES = ["GameToggleSpawner", "GraphicsToggleSpawner", "SoundToggleSpawner",
              "ControlsToggleSpawner", "PostFxToggleSpawner"]
_TAB_PTRS = ["0x0000021c0022%04d" % (i * 16) for i in range(5)]

FX_TOGGLES_CHILDREN = _hdr(98, 1, "> children 0x0000021c00220000\n"
                            "  childCount = 5\n"
                            "  via Transform::GetChild / get_childCount, "
                            "Object::get_name (calls)\n" +
                            "\n".join(
    '    [%d] transform=%s ($c%d)  go=0x0000021c0033%04d ($g%d)  name="%s"'
    % (i, _TAB_PTRS[i], i, i * 16, i, _TAB_NAMES[i]) for i in range(5)))


def _fx_active_batch(flags, batch=99):
    """One `assert-active` verdict line per pointer, in command order."""
    body = "\n".join(
        ("> assert-active %s\n  PASS: %s activeInHierarchy = true, as claimed"
         % (p, p)) if a else
        ("> assert-active %s\n  FAIL: %s activeInHierarchy = false, but "
         "assert-active claimed true." % (p, p))
        for p, a in zip(_TAB_PTRS, flags))
    return _hdr(batch, len(flags), body)


def _declared_screen_assertion_names():
    """Every assertion name `run_screen_assertions` can print on the READY
    path, read out of the source. Falsifiable on purpose: add an assertion to
    that function and forget SCREEN_ASSERTION_NAMES, and this disagrees."""
    import inspect as _pyinspect
    names = set()
    for fn in (assert_tab_count, assert_no_donor_caption_on_clones,
               assert_row_group_one_on, assert_postfx_subtab,
               assert_one_panel_active):
        src = _pyinspect.getsource(fn)
        names |= set(re.findall(r'report\.record\(\s*"([^"]+)"', src))
        names |= set(re.findall(r'^\s*name\s*=\s*"([^"]+)"', src, re.M))
    src = _pyinspect.getsource(run_screen_assertions)
    names |= set(re.findall(r'assert_no_text\([^,]+,[^,]+,\s*"([^"]+)"', src))
    return names


class _Args(object):
    root = LIVE_DEFAULT.rsplit("\\", 1)[0]
    mods_built = False
    menu_timeout = 5.0
    settings_timeout = 5.0


def _verdicts(report):
    return {name: v for name, v, _m, _d in report.rows}


def cmd_selftest(_args):
    real_run_batch, real_sleep = ch.run_batch, time.sleep
    time.sleep = lambda *_a, **_k: None       # the poll loops, offline
    failures = []

    def case(title, script, check):
        rep = Report()
        rp = _Replay(script)
        ch.run_batch = rp
        print("\n---- %s" % title)
        try:
            note = check(rep, rp)
        except AssertionError as e:
            note = "raised: %s" % e
        if note:
            failures.append("%s: %s" % (title, note))
            print("  ** CASE FAILED: %s" % note)
        else:
            print("  case ok")

    open_path = [("roots", [FX_ROOTS]),
                 ("find TaskBar", [_fx_find("TaskBar", "0x0000021c00110000",
                                            "Common UI")]),
                 ("find Tabs", [_fx_find("Tabs", "0x0000021c00111000",
                                         "TaskBar")]),
                 ("find Settings", [_fx_find("Settings", "0x0000021c00112000",
                                             "Tabs")]),
                 ("find SettingsButton",
                  [_fx_find("SettingsButton", "0x0000021c00113000",
                            "Settings")]),
                 ("component", [FX_PRESS_OK])]

    # --- 1. bound AND active: the ordinary fast path, no navigation. --------
    def c1(rep, rp):
        ready, reason = ensure_settings_ready(rep, live="X", args=_Args())
        if not ready:
            return "expected ready, got reason %r" % reason
        if _verdicts(rep).get("settings screen opened") != PASS:
            return "expected a PASS for the opened assertion"
        if any(s.startswith("find ") for s in rp.sent):
            return "navigated even though the screen was already ON DISPLAY"
        return ""
    case("bound + ACTIVE -> ready, no navigation",
         [("state", [FX_STATE_BOUND]),
          ("assert-active", [FX_ACTIVE_TRUE])], c1)

    # --- 2. THE 03:55 SHAPE: bound but INACTIVE, and it stays inactive. -----
    #     Before this fix, this exact shape produced
    #     `[FAIL] top-row stock tab count  0 active, want 4`.
    def c2(rep, rp):
        ready, reason = ensure_settings_ready(rep, live="X", args=_Args())
        if ready:
            return "reported ready for an INACTIVE SettingsScreen"
        if reason != INACTIVE_REASON:
            return "reason was %r, want %r" % (reason, INACTIVE_REASON)
        run_screen_assertions(rep, "X", _Args(), ready, reason)
        v = _verdicts(rep)
        bad = [n for n, k in v.items() if k == FAIL]
        if bad:
            return "FAIL verdict(s) on a screen that was never displayed: %s" % bad
        missing = [n for n in SCREEN_ASSERTION_NAMES
                   if v.get(n) != INCONCLUSIVE]
        if missing:
            return "not reported INCONCLUSIVE: %s" % missing
        if not any(INACTIVE_REASON in m for _n, _k, m, _d in rep.rows):
            return "no row states the bound-but-not-active reason"
        if not any(s.startswith("component ") for s in rp.sent):
            return "did not attempt the open path even once"
        return ""
    case("bound + INACTIVE, stays inactive -> all screen checks INCONCLUSIVE",
         [("state", [FX_STATE_BOUND]),
          ("assert-active", [FX_ACTIVE_FALSE])] + open_path, c2)

    # --- 3. bound but inactive, and the one re-open attempt WORKS. ----------
    def c3(rep, rp):
        ready, reason = ensure_settings_ready(rep, live="X", args=_Args())
        if not ready:
            return "re-open activated the screen but it reported %r" % reason
        if _verdicts(rep).get("settings screen opened") != PASS:
            return "expected PASS once the screen came up active"
        return ""
    case("bound + INACTIVE, re-open succeeds -> ready",
         [("state", [FX_STATE_BOUND]),
          ("assert-active", [FX_ACTIVE_FALSE, FX_ACTIVE_TRUE])] + open_path, c3)

    # --- 4. the inspector itself could not tell. NOT False, NOT ready. ------
    def c4(rep, rp):
        ready, reason = ensure_settings_ready(rep, live="X", args=_Args())
        if ready:
            return "reported ready on an INCONCLUSIVE active state"
        run_screen_assertions(rep, "X", _Args(), ready, reason)
        if any(k == FAIL for k in _verdicts(rep).values()):
            return "FAIL verdict on an unknown active state"
        if "could not be established" not in reason:
            return "reason does not say the state was unknown: %r" % reason
        if any(s.startswith("component ") for s in rp.sent):
            return "pressed the open path on an UNKNOWN state (should not)"
        return ""
    case("bound + active state UNKNOWN -> INCONCLUSIVE, nothing pressed",
         [("state", [FX_STATE_BOUND]),
          ("assert-active", [FX_ACTIVE_INC])], c4)

    # --- 5/6. THE NEGATIVE CONTROLS. The gate must not have made the tab ----
    #     count unable to fail: with the screen ACTIVE it still FAILs on a
    #     dead strip and still PASSes on a live one.
    def c5(rep, _rp):
        assert_tab_count(rep, "X", False)
        if _verdicts(rep).get("top-row stock tab count") != FAIL:
            return "an ACTIVE screen with 0 active stock tabs did not FAIL"
        return ""
    case("control: screen ACTIVE, 0 active stock tabs -> still FAIL",
         [("find Toggles", [_fx_find("Toggles", "0x0000021c00220000",
                                     "SettingsScreen")]),
          ("children", [FX_TOGGLES_CHILDREN]),
          ("assert-active", [_fx_active_batch([False] * 5)])], c5)

    def c6(rep, _rp):
        if _verdicts(rep).get("top-row stock tab count") is not None:
            return "unexpected"
        assert_tab_count(rep, "X", False)
        if _verdicts(rep).get("top-row stock tab count") != PASS:
            return "4 active stock tabs did not PASS"
        return ""
    case("control: screen ACTIVE, 4 active stock tabs -> PASS",
         [("find Toggles", [_fx_find("Toggles", "0x0000021c00220000",
                                     "SettingsScreen")]),
          ("children", [FX_TOGGLES_CHILDREN]),
          ("assert-active",
           [_fx_active_batch([True, True, True, True, False])])], c6)

    # --- 7-10. THE DONOR CAPTION ON THE ROW CLONES. ------------------------
    #     Replayed from `findtext-clones-donor-caption`, which is the VERBATIM
    #     answer to `findtext "Interface language" $settings 40000 all` on a
    #     live screen: 24 hits, 2 under the stock `Settings Drop Down(Clone)`
    #     and 22 under our `(Clone)(Clone)` rows, and the walk ends HIT_CAP.
    #     Before today this assertion issued the needle UNQUOTED, so the client
    #     never searched for it at all and the run printed
    #     `walk was UNKNOWN, not EXHAUSTIVE`.
    FT_DONOR = _fixtures.fx("findtext-clones-donor-caption")
    FT_PLACEHOLDER = _fixtures.fx("findtext-placeholder-inactive-only")
    DONOR_NAME = "no donor caption under MODS row clones"
    PLACEHOLDER_NAME = "no placeholder text on any RENDERED node"

    CAP_TRAILER = ("  -- stopped at the match cap (24). There may be more; "
                   "`findtext more` continues from the frontier above.")
    EXH_TRAILER = ("  -- the subtree was searched EXHAUSTIVELY. Every match "
                   "is listed above.")

    # The two controls below are DERIVED from measured text, not written: one
    # deletes whole HIT lines, the other swaps one measured trailer for
    # another measured trailer. Every character in them was emitted by the
    # host; only the selection is ours, and that is said out loud here because
    # a fixture nobody can trace is not evidence.
    def _no_clone_hits(text):
        return "\n".join(l for l in text.splitlines() if CLONE_MARK not in l)

    if CAP_TRAILER not in FT_DONOR or EXH_TRAILER not in FT_PLACEHOLDER:
        failures.append("the recorded findtext trailers no longer read as this "
                        "selftest expects; re-harvest the fixtures")

    def c7(rep, _rp):
        assert_no_donor_caption_on_clones(rep, "X", True)
        if _verdicts(rep).get(DONOR_NAME) != FAIL:
            return "22 donor captions under the row clones did not FAIL"
        m = [r for r in rep.rows if r[0] == DONOR_NAME][0][2]
        if "22 under (Clone)(Clone)" not in m or "2 stock" not in m:
            return "hits were not counted by parent: %r" % m
        return ""
    case("donor caption: 22 under (Clone)(Clone), 2 stock, HIT_CAP -> FAIL",
         [('findtext "Interface language"', [FT_DONOR])], c7)

    def c8(rep, _rp):
        assert_no_donor_caption_on_clones(rep, "X", True)
        if _verdicts(rep).get(DONOR_NAME) != PASS:
            return ("0 under the clones + 2 stock hits + an EXHAUSTIVE walk did "
                    "not PASS: %r"
                    % [r for r in rep.rows if r[0] == DONOR_NAME][0][2])
        return ""
    case("control: 0 under clones, stock present, EXHAUSTIVE -> PASS",
         [('findtext "Interface language"',
           [_no_clone_hits(FT_DONOR).replace(CAP_TRAILER, EXH_TRAILER)])], c8)

    def c9(rep, _rp):
        assert_no_donor_caption_on_clones(rep, "X", True)
        v = _verdicts(rep).get(DONOR_NAME)
        if v == PASS:
            return ("a walk that STOPPED AT THE MATCH CAP was allowed to prove "
                    "an absence")
        if v != INCONCLUSIVE:
            return "expected INCONCLUSIVE on a capped walk, got %s" % v
        return ""
    case("control: 0 under clones but the walk was CAPPED -> INCONCLUSIVE",
         [('findtext "Interface language"', [_no_clone_hits(FT_DONOR)])], c9)

    print("\n---- parser: findtext HIT lines (channel.py's _HIT_RE cannot)")
    hits = findtext_hits(FT_DONOR)
    chan = ch.parse_find(host_text(FT_DONOR))["hits"]
    if len(hits) != 24:
        failures.append("findtext_hits parsed %d of 24 measured HIT lines"
                        % len(hits))
    elif any(h["parent"] is None or h["active"] is None or not h["text"]
             for h in hits):
        failures.append("a parsed hit is missing parent/text/activeInHierarchy")
    else:
        print("  case ok (24 hits, all with parent + text + active; the shared "
              "channel.py parser returns %d on the same text)" % len(chan))

    # --- 11-12. PLACEHOLDER TEXT, decided on RENDERED nodes only. ----------
    def c11(rep, _rp):
        assert_no_text(rep, "X", PLACEHOLDER_NAME, PLACEHOLDER_TEXT)
        v = _verdicts(rep).get(PLACEHOLDER_NAME)
        if v != PASS:
            return ("12 hits that are ALL activeInHierarchy=FALSE are donor "
                    "prefabs nothing renders; expected PASS, got %s (%r)"
                    % (v, [r for r in rep.rows if r[0] == PLACEHOLDER_NAME][0][2]))
        m = [r for r in rep.rows if r[0] == PLACEHOLDER_NAME][0][2]
        if "+12 on inactive" not in m:
            return "the inactive hits were not counted out loud: %r" % m
        return ""
    case("placeholder: 12 hits, all on INACTIVE donors -> PASS, counted",
         [('findtext "SOME TEXT"', [FT_PLACEHOLDER])], c11)

    def c12(rep, _rp):
        assert_no_text(rep, "X", PLACEHOLDER_NAME, PLACEHOLDER_TEXT)
        if _verdicts(rep).get(PLACEHOLDER_NAME) != FAIL:
            return "a placeholder on a RENDERED node did not FAIL"
        return ""
    case("control: one placeholder hit is activeInHierarchy=true -> FAIL",
         [('findtext "SOME TEXT"',
           [FT_PLACEHOLDER.replace("activeInHierarchy=FALSE (unpressable)",
                                    "activeInHierarchy=true", 1)])], c12)

    # --- 13-17. THE TAB ROW GROUP. -----------------------------------------
    #     Every batch here is a verbatim capture of ONE live screen: the strip
    #     walk, its 13 children, the depth-2 tree that says which node carries
    #     each Toggle, and one `component + read $comp+0x120` per toggle. On
    #     that screen exactly one toggle is ON and it is a STOCK one, while all
    #     8 clones are activeInHierarchy=true -- which is precisely why the old
    #     assertion (`exactly one of the 8 clones is ACTIVE`) reported
    #     `[FAIL] 8 of 8 clone(s) active` about a correct screen.
    STRIP = [("find Toggles", [_fixtures.fx("find-toggles-strip-with-clones")]),
             ("children 0x000002024b079ee0",
              [_fixtures.fx("children-toggle-strip")]),
             ("tree 0x000002024b079ee0 2",
              [_fixtures.fx("tree-toggle-strip-depth2")])]

    def _toggle_batches(swap=None):
        """One script entry per measured toggle, keyed on its own command.
        `swap` replaces slot N's answer with another fixture -- that is how the
        negative controls are built, from measured text only."""
        ents = sorted((e for e in _fixtures.load().entries
                       if e.eid.startswith("toggle-ison-")),
                      key=lambda e: e.eid)
        if len(ents) != 13:
            failures.append("expected 13 toggle-ison-* fixtures, found %d"
                            % len(ents))
        out = []
        for i, e in enumerate(ents):
            body = e.output
            if swap and i in swap:
                body = _fixtures.fx(swap[i])
            out.append((e.command, [body]))
        return out

    GROUP_NAME = "settings tab row group: exactly one toggle is ON"

    def c13(rep, _rp):
        assert_row_group_one_on(rep, "X", 8)
        v = _verdicts(rep).get(GROUP_NAME)
        m = [r for r in rep.rows if r[0] == GROUP_NAME][0][2]
        if v != PASS:
            return "one ON toggle in a 13-strong group did not PASS: %s %r" % (v, m)
        if "1 of 13" not in m:
            return "the ON count was not stated: %r" % m
        d = [r for r in rep.rows if r[0] == GROUP_NAME][0][3]
        if "published 8" not in d:
            return "the clone count was not tied to the host log: %r" % d
        return ""
    case("row group: 13 toggles, exactly one ON (a STOCK one) -> PASS",
         STRIP + _toggle_batches(), c13)

    def c14(rep, _rp):
        assert_row_group_one_on(rep, "X", 8)
        if _verdicts(rep).get(GROUP_NAME) != FAIL:
            return "two toggles ON at once did not FAIL"
        return ""
    case("control: a second toggle reads m_IsOn=true -> FAIL",
         STRIP + _toggle_batches(swap={5: "toggle-ison-00-true"}), c14)

    def c15(rep, _rp):
        assert_row_group_one_on(rep, "X", 8)
        v = _verdicts(rep).get(GROUP_NAME)
        if v == FAIL:
            return ("an UNREADABLE m_IsOn was counted as a failure -- 'I could "
                    "not look' is not 'the condition does not hold'")
        if v != INCONCLUSIVE:
            return "expected INCONCLUSIVE, got %s" % v
        return ""
    case("control: one toggle has no Toggle component -> INCONCLUSIVE, not FAIL",
         STRIP + _toggle_batches(swap={7: "component-toggle-absent"}), c15)

    def c16(rep, _rp):
        assert_row_group_one_on(rep, "X", 8)
        v = _verdicts(rep).get(GROUP_NAME)
        if v != INCONCLUSIVE:
            return ("`children` and `tree` disagreed about the strip and the "
                    "assertion still returned %s" % v)
        return ""
    case("control: children and tree disagree -> INCONCLUSIVE",
         [("find Toggles", [_fixtures.fx("find-toggles-strip-with-clones")]),
          ("children 0x000002024b079ee0", [_fixtures.fx("children-ok")]),
          ("tree 0x000002024b079ee0 2",
           [_fixtures.fx("tree-toggle-strip-depth2")])], c16)

    # --- 17-19. THE CLONE COUNT COMES FROM THE HOST LOG, not from a want. --
    TABS = [("find Toggles", [_fixtures.fx("find-toggles-strip-with-clones")]),
            ("children 0x000002024b079ee0",
             [_fixtures.fx("children-toggle-strip")]),
            ("assert-active", [_fixtures.fx("assert-active-toggle-strip")])]
    CLONES_NAME = "top-row mod tab clones"

    def c17(rep, _rp):
        assert_tab_count(rep, "X", True, 8, "")
        if _verdicts(rep).get("top-row stock tab count") != PASS:
            return "4 active stock tabs (PostFx inactive by design) did not PASS"
        if _verdicts(rep).get(CLONES_NAME) != PASS:
            return "8 active clones against 8 published pages did not PASS"
        return ""
    case("tab clones: 8 active, host log published 8 -> PASS", TABS, c17)

    def c18(rep, _rp):
        assert_tab_count(rep, "X", True, 9, "")
        if _verdicts(rep).get(CLONES_NAME) != FAIL:
            return ("8 clones against 9 published pages did not FAIL -- the "
                    "published number is not actually driving the verdict")
        return ""
    case("control: 8 active clones, host log published 9 -> FAIL", TABS, c18)

    def c19(rep, _rp):
        assert_tab_count(rep, "X", True, None, "the host log has no such line")
        v = _verdicts(rep).get(CLONES_NAME)
        if v != INCONCLUSIVE:
            return ("with no published-count line the clone check reported %s; "
                    "it must not fall back to a hardcoded want" % v)
        return ""
    case("control: no published-count line -> INCONCLUSIVE, no fallback want",
         TABS, c19)

    # --- 20. the published-count regex, against the measured log line. ------
    print("\n---- published_pages: the host's own line")
    LINE = ("client settings bridge: published 8 of 8 client-side settings "
            "page(s) to the backend")
    m = _PUBLISHED_RE.search(LINE)
    if not m or (int(m.group("n")), int(m.group("total"))) != (8, 8):
        failures.append("_PUBLISHED_RE does not read the measured host line %r"
                        % LINE)
        print("  ** CASE FAILED: %s" % failures[-1])
    elif _PUBLISHED_RE.search("published 8 of 8 pages"):
        failures.append("_PUBLISHED_RE matches an unrelated 'published N of M' "
                        "line, so another feature's log line could set the "
                        "expected tab count")
        print("  ** CASE FAILED: %s" % failures[-1])
    else:
        print("  case ok (8 of 8, and a non-settings line does not match)")

    ch.run_batch, time.sleep = real_run_batch, real_sleep

    # --- 7. drift guard, source-level, no channel at all. -------------------
    print("\n---- drift: SCREEN_ASSERTION_NAMES covers the ready path")
    declared = _declared_screen_assertion_names()
    listed = set(SCREEN_ASSERTION_NAMES)
    if declared != listed:
        failures.append("SCREEN_ASSERTION_NAMES drift: only in source %s; "
                        "only in list %s"
                        % (sorted(declared - listed), sorted(listed - declared)))
        print("  ** CASE FAILED: %s" % failures[-1])
    else:
        print("  case ok (%d names)" % len(listed))

    print("\n==== selftest: %d case(s) failed" % len(failures))
    for f in failures:
        print("  - %s" % f)
    return 1 if failures else 0


def main():
    ap = argparse.ArgumentParser(
        description="one-command acceptance run for the settings screen",
        formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    ap.add_argument("command", choices=["run", "selftest"])
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
    if args.command == "selftest":
        return cmd_selftest(args)
    return cmd_run(args)


if __name__ == "__main__":
    sys.exit(main())
