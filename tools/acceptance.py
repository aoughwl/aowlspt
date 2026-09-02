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


INACTIVE_REASON = ("SettingsScreen is bound but not active (another screen "
                   "is up)")

# Every assertion below that reads the SETTINGS SCREEN. When the screen is not
# on display, each of these is reported INCONCLUSIVE by name rather than being
# skipped silently or -- as happened at 03:55 -- run anyway and reported FAIL.
SCREEN_ASSERTION_NAMES = (
    "top-row stock tab count",
    "top-row mod tab clones",
    "no donor caption under MODS row clones",
    "no placeholder text anywhere",
    "cloned mods spawner: exactly one active toggle",
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
    ok, comp = trusted_walk(raw)
    if not ok:
        report.record(name, INCONCLUSIVE,
                      "walk was %s, not EXHAUSTIVE -- an absence under the "
                      "clones is not provable from it" % comp)
        return
    hits = find_hits(raw)
    f = ch.parse_findtext(host_text(raw))

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
                       for h in ours[:5])
    verdict = FAIL if ours else PASS
    report.record(name, verdict,
                  "%d hit(s) of %r, scope=%s: %d under %s (must be 0), %d "
                  "stock (positive control, must be >0)"
                  % (len(hits), DONOR_CAPTION, f["scope"], len(ours),
                     CLONE_MARK, len(stock)),
                  detail)


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
    assert_tab_count(report, live, args.mods_built)
    assert_no_donor_caption_on_clones(report, live, args.mods_built)
    assert_no_text(report, live, "no placeholder text anywhere",
                   PLACEHOLDER_TEXT)
    assert_spawner_one_active_toggle(report, live, args.mods_built)
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
# around. The fixtures below are inspector prose in the EXACT emit format of
# inspect.nim (`iOut` sites named per fixture); the numbers in them are
# synthetic, the SHAPES are not. `run_batch` is replaced by a replay that
# refuses any command it has no recording for, so a test can never pass by
# talking to nothing.

class _Replay(object):
    """Offline stand-in for ch.run_batch. `script` is a list of
    (command-prefix, [answer, ...]); answers are consumed in order and the
    LAST one repeats (a poll loop asks the same question many times). An
    unrecorded command is an AssertionError, never a silent empty answer --
    an empty answer is exactly how a check that cannot fail gets built."""

    def __init__(self, script):
        self.script = [(p, list(a)) for p, a in script]
        self.sent = []

    def __call__(self, lines, live_dir=None, timeout=25.0, write=False, **kw):
        first = lines[0] if lines else ""
        self.sent.append(first)
        for prefix, answers in self.script:
            if first.startswith(prefix):
                return "SENTINEL", (answers.pop(0) if len(answers) > 1
                                    else answers[0])
        raise AssertionError("replay has no recording for %r" % first)


def _hdr(batch, n, body):
    return ("aowlspt live inspector -- batch %d, %d command(s), on Unity "
            "thread 1192\n%s\naowlspt live inspector -- batch %d complete, "
            "%d line(s)" % (batch, n, body, batch, body.count("\n") + 3))


# `state` (iCmdState): field reads only -- note it prints NO active flag, which
# is the whole reason settings_active() exists.
FX_STATE_BOUND = _hdr(91, 1, """> state
  anchors: $preloader=0x000001e4a2b03040 $settings=0x000002b7c4180a80
  channel: polls=902 reads=91 readFails=0 unchanged=811 batch=91 faults=0""")

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
               assert_spawner_one_active_toggle, assert_postfx_subtab,
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
