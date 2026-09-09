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
import run as _run  # noqa: E402 -- MENU_PROOF_LINES, one copy in the repo

LIVE_DEFAULT = r"D:\Aowlspt\aowlspt"

PASS, FAIL, INCONCLUSIVE = "PASS", "FAIL", "INCONCLUSIVE"


def _oneline(x, cap=140):
    """Flatten anything to one short line -- exception text and host refusal
    lines are both multi-line, and a newline inside a one-line report row
    silently splits it into two rows that read as two findings."""
    s = " ".join(str(x).split())
    return s if len(s) <= cap else s[:cap - 3] + "..."


class Refusal(object):
    """WE COULD NOT LOOK. Deliberately not a string, and deliberately not
    falsy-by-accident: `isinstance(x, Refusal)` is the only way to consume it,
    so a caller cannot interpolate it into a sentence that reads like an
    answer without having thought about it. `__str__` shouts."""

    __slots__ = ("reason",)

    def __init__(self, reason):
        self.reason = _oneline(reason) or "no reason given"

    def __str__(self):
        return "UNRESOLVED (%s)" % self.reason

    __repr__ = __str__

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


# ZERO slots on screen is AMBIGUOUS, and reading it as one thing is the whole
# bug. MEASURED 2026-09-02 10:35: a client parked at the MAIN MENU -- host log
# carrying `skip mode screen: MenuScreen::Show fired (uihooks site 2, epoch 1)`
# -- produced `[INCONCLUSIVE] past mode selector -- ... no slot shows a real
# title yet (placeholders only: [])` after a full 120s wait, and every screen
# assertion was then marked NOT PERFORMED. No selector on screen was read as
# "the selector has not appeared YET" when it in fact meant "the selector is
# already GONE".
#
# The host itself distinguishes them, and `tools/run.py` already knows how:
# four features log a line off the `EFT.UI.MenuScreen::Show` event (uihooks
# site 2), and any one of them is proof the main menu was built. Those
# substrings are IMPORTED from run.py rather than restated, so there is exactly
# one copy of them in the repo and the two tools cannot drift apart.
MENU_PROOF_LINES = _run.MENU_PROOF_LINES   # source: tools/run.py:306

# The host truncates its log at every start (`modhost.openLog`, and
# tools/hostlog.py's header says so), writing this banner as the first line.
# The file is therefore normally exactly one boot -- but a proof line is only
# allowed to certify THIS boot, so the scan restarts at the LAST banner and
# anything before it is discarded. A menu proof from a previous boot certifying
# this one is the exact failure run.py warns about at its `prescan_host`.
HOST_BANNER_PREFIX = "aowlspt-host-il2cpp "


def menu_proof_from_lines(lines):
    """(proof_line_or_None, saw_banner) from host-log lines. Pure, so the
    selftest drives it with literals; only lines AFTER the last banner count."""
    proof, saw_banner = None, False
    for raw in lines:
        if raw.startswith(HOST_BANNER_PREFIX):
            saw_banner, proof = True, None   # a restart invalidates old proof
            continue
        for sig in MENU_PROOF_LINES:
            if sig in raw:
                proof = raw.strip()
                break
    return proof, saw_banner


def host_menu_proof(root, max_bytes=8 * 1024 * 1024):
    """Did the host log say the MAIN MENU was shown, this boot?

    Returns (proof_line_or_None, note). A None proof is THREE-STATE by way of
    the note: the log was unreadable / the scan was cut short (could not look),
    or the log was read whole and holds no proof (looked, found nothing). The
    caller must not flatten those. Streams and caps its read -- the host log is
    a measured token bomb (CLAUDE.md 8) and is never printed here.
    """
    p = os.path.join(root, "aowlspt", "aowlspt-host.log")
    if not os.path.isfile(p):
        return None, "no host log at %s" % p
    truncated = False
    try:
        with open(p, "r", encoding="utf-8", errors="replace") as f:
            read = 0
            lines = []
            for line in f:
                read += len(line)
                if read > max_bytes:
                    truncated = True
                    break
                lines.append(line)
    except OSError as e:
        return None, "the host log could not be read: %s" % _oneline(e)
    proof, saw_banner = menu_proof_from_lines(lines)
    if proof:
        return proof, ""
    if truncated:
        return None, ("the host log was only read to %d bytes, so the absence "
                      "of a MenuScreen::Show proof line proves nothing"
                      % max_bytes)
    if not saw_banner:
        return None, ("the host log carries no `%s` banner, so which boot it "
                      "describes is unknown" % HOST_BANNER_PREFIX.strip())
    return None, ("this boot's host log has no MenuScreen::Show proof line "
                  "(none of %d signatures)" % len(MENU_PROOF_LINES))


def enter_game(timeout, root, _list=None, _select=None, _proof=None):
    """Get past the mode selector, retrying because on a fresh client the
    pve/seasonal slots can read the localisation placeholder 'New Text'
    before locale lands. Selects whichever slot shows a REAL, non-placeholder
    title -- never guesses by object name (see entergame.py's own header).

    Three outcomes, in this order:
      * slots with real titles      -> the press path, unchanged;
      * NO slot at all + a menu proof line for this boot -> already past;
      * NO slot and no proof        -> keep waiting, then INCONCLUSIVE.

    The proof is only consulted when the selector shows NO slots. Placeholder
    or unreadable slots mean a selector IS on screen and still has to be
    pressed, whatever an older menu proof says.

    `_list`/`_select`/`_proof` are injection points for the selftest; the
    defaults are the real subprocesses and the real host log.
    """
    entergame = os.path.join(HERE, "entergame.py")
    if _list is None:
        def _list():
            return subprocess.run([sys.executable, entergame, "--list"],
                                  capture_output=True, text=True).stdout
    if _select is None:
        def _select(mode):
            r = subprocess.run([sys.executable, entergame, "--mode", mode],
                               capture_output=True, text=True)
            return r.returncode, (r.stdout + r.stderr).strip()[-400:]
    if _proof is None:
        def _proof():
            return host_menu_proof(root)
    deadline = time.time() + timeout
    last_note = "no attempt made yet"
    while time.time() < deadline:
        out = _list()
        if "already past the mode selector" in out:
            return True, "already past the mode selector"
        slots = _parse_slot_titles(out)          # None entries = <unreadable>
        titles = [t for t in slots if t]
        real = [t for t in titles if t.strip() != "New Text"]
        if not real:
            if not slots:
                proof, pnote = _proof()
                if proof:
                    return True, ("already past (host logged "
                                  "MenuScreen::Show): %s" % _oneline(proof))
                last_note = ("no slot is on screen at all, and %s" % pnote)
            else:
                last_note = ("no slot shows a real title yet (placeholders "
                             "only: %r)" % titles)
            time.sleep(4)
            continue
        mode = real[0]
        rc, text = _select(mode)
        if rc == 0:
            return True, "selected %r" % mode
        last_note = "pressed %r, entergame.py exited %d: %s" % (mode, rc, text)
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
# findtext HIT lines. Parsed by the SHARED parser in
# `plugins/aowlsptcode/mcp/channel.py` (re-exported as `ichannel`), not by a
# second regex here. History, because it is the reason this comment exists:
#
# That shared `_HIT_RE` spelled the flag `active=` and required `($fN)`
# immediately after `text="..."`, while a real findtext hit on this build is
#
#   HIT 0x00000203094ddf60  name="Text"  parent="Settings Drop Down(Clone)"  \
#   text="Interface language"  activeInHierarchy=true   ($f1)
#
# so `ch.parse_find(<that line>)["hits"] == []` -- every findtext answer, and
# the MCP `inspect_findtext` tool with it, returned zero hits. A search that
# cannot find. This file worked around it with a private `_FT_HIT_RE`, which
# is the OTHER half of the bug: two parsers of one prose, free to drift.
#
# Fixed 2026-09-02 in channel.py (one regex, both verbs, `activeInHierarchy`
# kept as a three-state `active` field: True / False / None), replayed against
# every HIT line in tools/fixtures/inspector/{find,findtext}.txt with the
# counts asserted against the host's own `K match(es)` line. The private copy
# is gone; the test below stays and now exercises the shared parser.
def _ft_hit_re():
    """The shared pattern, for tests that want to look at it directly."""
    return ch._HIT_RE

# The host's OWN positive control, printed in-band on every findtext report:
#   predicate control: 225 node(s) carried a TextMeshProUGUI (of 1297 visited)
#     -- the predicate demonstrably CAN answer yes on this subtree.
_FT_CONTROL_RE = re.compile(
    r'predicate control:\s*(?P<seen>\d+)\s+node\(s\) carried a '
    r'TextMeshProUGUI\s*\(of\s*(?P<visited>\d+)\s+visited\)')


def findtext_hits(raw):
    """findtext hits off HOST-PRINTED lines only, with text and active state.

    DELEGATES to the shared parser. `host_text` still runs here: it is this
    file's own job to strip anything that is not host-printed answer text
    before a parser ever sees it."""
    return ch.parse_findtext(host_text(raw))["hits"]


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
    "top-row native tab clones",
    "no donor caption on any aowlspt-cloned settings row",
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

    ok, note = enter_game(args.menu_timeout, args.root)
    if not ok:
        report.record("past mode selector", INCONCLUSIVE, note)
        return False, "the mode selector was never passed: %s" % note
    report.record("past mode selector", PASS, note)

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


# `native tabs: built the 'PROOF' tab -- a real UIAnimatedToggleSpawner in the
# STOCK ToggleGroup and a real cloned SettingsTab panel, ...`
# (nativetabs.nim ~612, the ONLY emit site of this phrase).
_NT_BUILT_RE = re.compile(r"native tabs: built the '(?P<name>[^']*)' tab")
# `nativeTabs is set: the host adds ONE proof tab ...` / `nativeTabs is set, so
# settingsUiProbe has been turned on with it ...` (aowlhost.nim ~9177, ~9181).
_NT_FLAG_RE = re.compile(r"nativeTabs is set")


def native_tabs_built(root):
    """(names, on, note) -- which top-row tabs the HOST says it built.

    Supersedes `published_pages` as the source of the expected top-row clone
    count. Until 2026-09-01 every mod got its own top-row tab, so the number
    of published client-side settings pages WAS the number of clones. The
    native-tabs foundation (`host/.../nativetabs.nim`, docs/NATIVETABS.md)
    replaced that: `defineTab` adds EXACTLY ONE clone per tab -- one PROOF tab
    today, a MODS tab next, with the mods themselves becoming SUBTABS inside
    its panel. Comparing 8 published pages against the clone count therefore
    asserted a design that no longer exists, and it FAILED live tonight with
    `1 active clone(s), want 8`.

    `on` is True when the host printed either a `nativeTabs is set` line or at
    least one `built the` line -- a build is direct evidence the feature ran,
    whatever the flag pass logged. `on` False means nativeTabs was OFF this
    session, and the caller must report INCONCLUSIVE with that reason: there
    is NO expected clone count then, and "0 built, 0 clones" must never be
    reported as a pass by default. `names` is None only when the log could not
    be read at all.

    Every matching line this session is counted, NOT deduplicated by name: two
    `built the 'MODS' tab` lines mean two clones went into the strip, and
    folding them together would hide exactly that. Duplicates are named in the
    caller's detail line.
    """
    ns = argparse.Namespace(root=os.path.join(root, "aowlspt"), backend=False)
    try:
        _p, lines = hostlog.read(ns)
    except SystemExit:
        return None, None, "the host log could not be read"
    names, flagged = [], False
    for row in hostlog.parse(lines):
        if _NT_FLAG_RE.search(row[2]):
            flagged = True
        m = _NT_BUILT_RE.search(row[2])
        if m:
            names.append(m.group("name"))
    if not flagged and not names:
        return names, False, (
            "the host log has neither a `nativeTabs is set` line nor any "
            "`native tabs: built the '<NAME>' tab` line, so nativeTabs was OFF "
            "this session and there is no expected top-row clone count")
    return names, True, ""


# ---------------------------------------------------------------------------
# THE NATIVE SUBTAB STRIP (nativetabs.nim `ntBuildSubtabs`).
#
# The OLD strip -- a `Toggles(Clone)` child of the `Graphics Settings` panel,
# built by modstab.nim's `settingsPostFxSubtab` path -- is DELETED (73adced).
# The strip is now a SIBLING of the panels, parented to SettingsScreen: it is
# cloned from `Control Settings/Toggles` with `Object::Instantiate` and never
# renamed, so Unity's own "(Clone)" suffix IS its name. Deliberately not
# `* Settings`, so assert_one_panel_active cannot mistake it for a panel.
#
# Two consequences the assertion below must respect, both read out of
# nativetabs.nim rather than assumed:
#   * the DONOR'S OWN BUTTONS COME WITH THE CLONE and are only
#     `SetActive(false)` -- never destroyed. So the strip's child count is
#     `donor children + our subtabs`, NOT our subtabs, and the inherited ones
#     sit FIRST (ours are appended by SetParentAndAlign afterwards).
#   * `ntBuildSubtabs` is guarded by ONE `gNtSubBuilt`, so at most one strip
#     exists per session: a run that built the MODS (rows) strip has no
#     GRAPHICS|POSTFX strip at all, and that absence is expected.
NT_SUB_STRIP_NAME = "Toggles(Clone)"
NT_SUB_DONOR_PANEL = "Control Settings"
NT_SUB_DONOR_STRIP = "Toggles"

# nativetabs.nim ~1149, the ONLY emit site: `native subtabs: built the
# GRAPHICS SETTINGS | POSTFX strip as a SIBLING of the panels it switches ...`.
# The captions are read OUT of the host's line rather than hardcoded, for the
# same reason the top-row clone count is: a constant `2` here would keep
# passing after someone adds a third subtab.
_NT_SUB_BUILT_RE = re.compile(
    r"native subtabs: built the (?P<caps>.+?) strip as a SIBLING")
# nativetabs.nim ~1262-1278 (`ntSubVerdict`): `native subtabs VERDICT PASS
# (subtab selection): exactly one subtab reads m_IsOn=1 (POSTFX) ...`, plus
# four FAIL variants. Only its PRESENCE is used -- it is the host's own
# statement that there was a strip to judge at all.
_NT_SUB_VERDICT_RE = re.compile(
    r"native subtabs VERDICT (?P<v>PASS|FAIL) \((?P<why>[^)]*)\)")
# nativetabs.nim ~735: the OTHER kind of strip (`NtSubRows`, the MODS one).
_NT_SUB_MODS_RE = re.compile(r"native mods: built (?P<n>\d+) mod subtab\(s\)")
# nativetabs.nim ~1015: `native subtabs: build attempted (nativeTabsSubtabs is
# ON) and returned true|false`. Better evidence than the config file, because
# it is the host saying the flag was on IN THIS PROCESS -- and `returned
# false` is a build that was attempted and refused, which is a different fact
# from "the flag was off" and must not be reported as one.
_NT_SUB_ATTEMPT_RE = re.compile(
    r"native subtabs: build attempted \(nativeTabsSubtabs is ON\) and "
    r"returned (?P<r>true|false)")


def _subtabs_from_messages(msgs):
    """(captions, mods_n, verdicts, attempt, note) from host-log message text.

    Pure, so the selftest can drive it with the literals copied out of
    nativetabs.nim instead of stubbing the log reader. `captions` is None when
    the host never printed the build line -- the caller must NOT fall back to
    a number then, exactly as native_tabs_built refuses to.
    """
    captions, mods_n, verdicts, attempt = None, None, [], None
    for m in msgs:
        a = _NT_SUB_ATTEMPT_RE.search(m)
        if a:
            attempt = (a.group("r") == "true")
        b = _NT_SUB_BUILT_RE.search(m)
        if b:
            captions = [c.strip() for c in b.group("caps").split("|")
                        if c.strip()]
        mm = _NT_SUB_MODS_RE.search(m)
        if mm:
            mods_n = int(mm.group("n"))
        v = _NT_SUB_VERDICT_RE.search(m)
        if v:
            verdicts.append((v.group("v"), v.group("why")))
    if captions is None and attempt is False:
        return None, mods_n, verdicts, attempt, (
            "the host printed `native subtabs: build attempted "
            "(nativeTabsSubtabs is ON) and returned false` -- the build ran "
            "and REFUSED")
    if captions is None and not verdicts:
        return None, mods_n, verdicts, attempt, (
            "the host log has NO `native subtabs: built the <A> | <B> strip "
            "as a SIBLING ...` line and NO `native subtabs VERDICT` line")
    if captions is None:
        return None, mods_n, verdicts, attempt, (
            "the host printed %d `native subtabs VERDICT` line(s) but no "
            "`native subtabs: built the <A> | <B> strip as a SIBLING ...` "
            "line, so how many subtabs it made is not known" % len(verdicts))
    return captions, mods_n, verdicts, attempt, ""


def native_subtabs_built(root):
    """(captions, mods_n, verdicts, attempt, note) -- see
    _subtabs_from_messages."""
    ns = argparse.Namespace(root=os.path.join(root, "aowlspt"), backend=False)
    try:
        _p, lines = hostlog.read(ns)
    except SystemExit:
        return None, None, [], None, "the host log could not be read"
    return _subtabs_from_messages([row[2] for row in hostlog.parse(lines)])


def _subtabs_flag_from_cfg(hostcfg, text):
    """(on, why) for `nativeTabsSubtabs`, resolved THE WAY THE HOST RESOLVES
    IT (aowlhost.nim ~9172 and ~9214-9221), which is not the way a plain JSON
    read would:

      * absent means ON -- `readBoolKeyDef("nativeTabsSubtabs", true)`. A
        reader that treated a missing key as off would report INCONCLUSIVE on
        every default install and never look at the strip again.
      * `settingsPostFxSubtab` being set turns it ON regardless, because the
        old cloned-strip implementation of that feature is deleted.
    """
    present, raw, truthy = hostcfg.value_of(text, "nativeTabsSubtabs")
    gpresent, graw, gtruthy = hostcfg.value_of(text, "settingsPostFxSubtab")
    if gtruthy:
        return True, ("settingsPostFxSubtab is set, which turns "
                      "nativeTabsSubtabs on with it")
    if not present:
        return True, ("nativeTabsSubtabs is absent from aowlspt-host.json and "
                      "the host defaults it to true")
    if truthy:
        return True, "nativeTabsSubtabs = %s" % raw
    return False, ("nativeTabsSubtabs = %s in aowlspt-host.json (and "
                   "settingsPostFxSubtab = %s), so the host built no subtab "
                   "strip this session"
                   % (raw, graw if gpresent else "absent"))


def native_subtabs_flag(root):
    """(on, why) -- on is None when the config could not be read at all."""
    try:
        hostcfg = __import__("hostcfg")
        _p, text = hostcfg.read_cfg(os.path.join(root, "aowlspt"))
    except BaseException:
        # includes SystemExit -- read_cfg exits when the file is absent.
        return None, ("aowlspt-host.json could not be read, so whether "
                      "nativeTabsSubtabs was on this session is not known")
    return _subtabs_flag_from_cfg(hostcfg, text)


def assert_tab_count(report, live, nt_names=None, nt_on=None, nt_note=""):
    """Stock top-row tabs, counted by NAME and by activeInHierarchy, with the
    names printed so the number can be checked rather than believed; then the
    clones, against what the host says it built (`native_tabs_built`).

    `mods_built` used to gate the clone half of this. It no longer does: the
    native tabs are built by the host from a stock spawner and exist whether
    or not any mod DLL was compiled, so a mods_built=False run must still be
    able to FAIL on a missing tab.
    """
    _strip, ptrs, names, note = _toggle_strip_children(live)
    if ptrs is None:
        report.record("top-row stock tab count", INCONCLUSIVE, note)
        report.record("top-row native tab clones", INCONCLUSIVE, note)
        return
    acts = active_states(live, ptrs)
    if acts is None or None in (acts or []):
        report.record("top-row stock tab count", INCONCLUSIVE,
                      "activeInHierarchy could not be established for every "
                      "one of the %d tab-strip children" % len(ptrs),
                      ", ".join(names))
        report.record("top-row native tab clones", INCONCLUSIVE,
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

    # The clone half. Expected count = the number of tabs the HOST says it
    # built this session, one `native tabs: built the '<NAME>' tab` line per
    # `defineTab`. NOT the published page count: mods are becoming SUBTABS.
    CLONES = "top-row native tab clones"
    detail = ("host built: %s | active clones: %s"
              % (", ".join(nt_names) if nt_names else "none",
                 ", ".join(clones_on) or "none"))
    if nt_names is None:
        # Could not look. Not a pass and not a failure.
        report.record(CLONES, INCONCLUSIVE,
                      "%d active clone(s), but the expected count is not "
                      "known: %s" % (len(clones_on), nt_note), detail)
    elif not nt_on:
        # NOT a fallback to `== 0`: with nativeTabs off, zero clones and zero
        # built lines would agree vacuously and print a green light for a
        # feature that never ran.
        report.record(CLONES, INCONCLUSIVE,
                      "%d active clone(s); nativeTabs was OFF this session so "
                      "there is nothing to compare against: %s"
                      % (len(clones_on), nt_note), detail)
    elif not nt_names:
        report.record(CLONES, FAIL,
                      "nativeTabs is ON but the host never printed a "
                      "`native tabs: built the '<NAME>' tab` line this "
                      "session, so no tab was built; %d active clone(s) "
                      "observed" % len(clones_on), detail)
    else:
        want = len(nt_names)
        v = PASS if len(clones_on) == want else FAIL
        report.record(CLONES, v,
                      "%d active clone(s), want %d (host log: built the %s "
                      "tab(s))" % (len(clones_on), want,
                                   ", ".join("'%s'" % n for n in nt_names)),
                      detail)


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

# How many offending hits get an ancestry probe. Each is one `parent EXPR N`
# round trip, so this is a cost cap, not an expectation.
PANEL_PROBE_CAP = 6
PANEL_DEPTH = 8

_PARENT_LINE_RE = re.compile(
    r'\[\d+\]\s+transform=\S+\s+klass=\S+\s+name="([^"]*)"')


def panel_of(live, ptrs):
    """{ptr: owning panel name} via `parent EXPR N`, for hits that FAILED.

    THIS EXISTS BECAUSE THE ASSERTION BLAMED THE WRONG FEATURE. Its first
    version called every `(Clone)(Clone)` hit a "MODS row clone" purely
    because of the name. MEASURED 2026-09-02 on the live client,
    `parent 0x00000203095d3e00 7` walked:

        Text -> Settings Drop Down(Clone)(Clone) -> Settings -> Viewport
             -> Scroll View -> Container -> Game Settings

    All three probed rows shared ONE container (0x0000020244f7e840) under
    `Game Settings` -- the STOCK Game tab -- and `hostlog.py grep` over that
    same run returned ZERO mods-tab row lines, so the MODS row path had not
    run at all. Those rows come from `settingspages.nim`'s
    `swRenderPage`/`swCloneRow`, a different feature in a different file. A
    verdict that names the wrong owner sends the next session to the wrong
    file, which is worse than no verdict at all.

    Deepest named ancestor wins: the panel is the outermost node of the walk.

    THREE STATES, NEVER TWO (§9b). The value for a ptr is:

      * a `str`     -- the outermost named ancestor the walk actually printed.
      * `None`      -- the walk ran and answered, and there was no named
                       ancestor in it at all. An honest "no panel", not a
                       failure.
      * `Refusal`   -- WE COULD NOT LOOK. The channel raised (offline replay
                       with no recording, a timeout, an abandoned batch), or
                       the host answered with an `!` refusal line -- e.g.
                       `Transform::get_parent did not verify on this build`,
                       or the pointer was not readable so the chain ended
                       before any name was printed.

    This used to be one flat `except Exception` that rendered EVERY one of
    those as the string `"unresolved (AssertionError)"`, which the caller then
    interpolated as `(panel: unresolved (AssertionError))` inside a FAIL. Live,
    that reads as a panel attribution -- a plausible-looking answer produced by
    a probe that never got a reply. "I could not look" is not an attribution.
    """
    out = {}
    for ptr in ptrs or []:
        try:
            raw = ch.run_batch(["parent %s %d" % (ptr, PANEL_DEPTH)],
                               live_dir=live, timeout=40)[1]
        except Exception as e:                    # named, never silent
            out[ptr] = Refusal("%s: %s" % (type(e).__name__, _oneline(e)))
            continue
        text = host_text(raw)
        names = _PARENT_LINE_RE.findall(text)
        if names:
            out[ptr] = names[-1]
            continue
        # No names. Distinguish "the walk answered and had none" from "the
        # walk refused", because only the first is an answer.
        refusals = [l.strip().lstrip("! ").strip()
                    for l in text.splitlines() if l.strip().startswith("!")]
        chain_end = [l.strip() for l in text.splitlines()
                     if "not readable; chain ends" in l]
        if refusals:
            out[ptr] = Refusal(_oneline(refusals[0]))
        elif chain_end:
            out[ptr] = Refusal(_oneline(chain_end[0]))
        else:
            out[ptr] = None
    return out


def panel_note(panels, ptr):
    """The ` (panel: ...)` suffix for one hit -- or "" if we never probed it.

    A Refusal prints as `panel: UNRESOLVED (<reason>)`, in capitals, because
    the one thing this string must never do is sit in a FAIL message looking
    like the name of a panel."""
    if ptr not in panels:
        return ""
    p = panels[ptr]
    if isinstance(p, Refusal):
        return " (panel: UNRESOLVED (%s))" % p.reason
    if p is None:
        return " (panel: none -- the walk printed no named ancestor)"
    return " (panel: %s)" % p


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
    name = "no donor caption on any aowlspt-cloned settings row"
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
    shown = (ours or stock)[:PANEL_PROBE_CAP]
    panels = panel_of(live, [h["ptr"] for h in shown]) if ours else {}
    detail = "; ".join("%s under %s @%s%s"
                       % (h["name"], h["parent"], h["ptr"],
                          panel_note(panels, h["ptr"]))
                       for h in shown)
    # Only REAL names are owners. A Refusal and a None are not panel names and
    # must not be sorted in among them (they would also raise TypeError on
    # py3's mixed-type sort). The refusals are counted out loud instead, so a
    # short owner list cannot read as "we checked and there was only one".
    owners = sorted({p for p in panels.values() if isinstance(p, str)})
    refused = sum(1 for p in panels.values() if isinstance(p, Refusal))
    # THE VERDICT BELOW DOES NOT DEPEND ON THE PANEL. It is decided by `ours`
    # -- hits whose PARENT carries the clone mark, which came from the findtext
    # reply itself. The ancestry probe only says WHO to go blame, so a refused
    # probe costs attribution, not the finding. If a future assertion ever
    # decides PASS/FAIL from `panels`, it must go INCONCLUSIVE when
    # `refused` > 0: a verdict read off a probe that never answered is exactly
    # the check-that-cannot-fail this file exists to prevent.
    measured = ("%d hit(s) of %r, walk %s, scope=%s: %d on a `%s` row "
                "(must be 0), %d stock (positive control, must be >0)%s"
                % (len(hits), DONOR_CAPTION, comp, f["scope"], len(ours),
                   CLONE_MARK, len(stock),
                   (("; owning panel(s): " + ", ".join(owners)) if owners else "")
                   + ("; %d of %d ancestry probe(s) UNRESOLVED (%s)"
                      % (refused, len(panels),
                         "; ".join(sorted({p.reason for p in panels.values()
                                           if isinstance(p, Refusal)})[:2]))
                      if refused else "")))
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
TOGGLE_GROUP_OFF = 0x110

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

    A THIN WRAPPER on read_toggle_fields, deliberately: the postfx subtab
    assertion needs m_Group as well, and two copies of the address-echo rule
    would be two chances for one of them to quietly stop checking.
    """
    got, note = read_toggle_fields(live, node_ptr,
                                   (("m_IsOn", TOGGLE_ISON_OFF, "bool"),),
                                   timeout=timeout)
    if got is None:
        return None, note
    return got["m_IsOn"], ""


def read_toggle_fields(live, node_ptr, fields, timeout=40):
    """({label: value}, "") or (None, note) -- Toggle fields on `node_ptr`.

    `fields` is a tuple of (label, offset, type) read in ONE batch after a
    single `component`. Every failure mode is an explicit refusal, never a
    default value:

    * no Toggle on the object -- `component` prints an `iErr` (`GetComponent
      (Type) returned NULL -- an ANSWER`), fixture `component-toggle-absent`;
    * `$comp` STALENESS -- a failed `component` has historically left `$comp`
      holding the PREVIOUS batch's pointer, so a following `read $comp+0xNN`
      answers about a different object. Defeated arithmetically: the inspector
      prints the address it read, and it must equal comp + offset EXACTLY, for
      every field, in order;
    * a read that was refused (`! not readable ...`) prints no `as TYPE =` line
      at all, so the count of answers stops matching the count of fields and
      this returns None. An unreadable field is INCONCLUSIVE and is never
      collapsed to false / 0.

    `bool` comes back True/False; `ptr` comes back as an int (0 IS a value: it
    means the reference is null, which for m_Group means "in no ToggleGroup" --
    a fact, not a failure to read).
    """
    cmds = ["component %s %s" % (node_ptr, TOGGLE_TYPE)]
    cmds += ["read $comp+0x%x %s" % (off, ty) for _lbl, off, ty in fields]
    _s, raw = ch.run_batch(cmds, live_dir=live, timeout=timeout)
    h = host_text(raw)
    if not ch.parse_component(h)["found"]:
        return None, ("no %s component on %s (or the lookup was refused)"
                      % (TOGGLE_TYPE, node_ptr))
    fm = _COMP_FOUND_RE.search(h)
    if not fm:
        return None, "the FOUND line for %s could not be parsed" % node_ptr
    reads = [m for m in (_READ_AT_RE.match(l) for l in h.splitlines()) if m]
    if len(reads) != len(fields):
        return None, ("expected %d `read` answer(s) for %s, got %d -- a "
                      "refused read prints no value line, so this is unknown, "
                      "not a default" % (len(fields), node_ptr, len(reads)))
    comp = int(fm.group("ptr"), 16)
    out = {}
    for r, (lbl, off, ty) in zip(reads, fields):
        want_addr = comp + off
        if int(r.group("addr"), 16) != want_addr:
            return None, ("the read answered about 0x%x but the component "
                          "found for %s is at %s, whose %s is 0x%x -- refusing "
                          "to attribute one object's field to another"
                          % (int(r.group("addr"), 16), node_ptr,
                             fm.group("ptr"), lbl, want_addr))
        if r.group("type") != ty:
            return None, ("%s read back as type %r, not %r"
                          % (lbl, r.group("type"), ty))
        val = r.group("val")
        if ty == "bool":
            if val not in ("true", "false"):
                return None, "%s read back as %r, not a bool" % (lbl, val)
            out[lbl] = (val == "true")
        elif ty == "ptr":
            if not re.match(r"^0x[0-9a-fA-F]+$", val):
                return None, "%s read back as %r, not a pointer" % (lbl, val)
            out[lbl] = int(val, 16)
        else:
            out[lbl] = val
    return out, ""


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


# The names of the two postfx assertions. One constant each, because several
# functions print them (the strip branch delegates, every refusal branch names
# them) and repeated literals would be repeated chances to drift out of
# SCREEN_ASSERTION_NAMES.
#
# `under GRAPHICS` in the first name is kept for continuity of the report, but
# it now means "the GRAPHICS SETTINGS | POSTFX strip", NOT "a child of the
# Graphics Settings panel". The strip is a SIBLING of the panels now.
POSTFX_STRIP_NAME = "postfx subtab strip under GRAPHICS"
POSTFX_GROUP_NAME = "postfx toggles share a group, one is on"


def assert_postfx_subtab(report, live, flag_on=None, captions=None,
                         mods_n=None, note=""):
    """The NATIVE subtab strip: a `Toggles(Clone)` DIRECT CHILD of
    SettingsScreen, carrying the donor's inherited buttons plus exactly the
    subtabs the host says it built.

    REWRITTEN for the native design. The old assertion looked for the strip
    under the `Graphics Settings` panel; that path is DELETED (73adced), so it
    could only ever have said FAIL from here on -- and its `>= 2 children`
    test could not have failed for the right reason anyway, because the clone
    arrives carrying the donor's own buttons and would satisfy `>= 2` with
    zero subtabs of ours in it.

    The expected child count is therefore arithmetic on two MEASURED numbers,
    neither of them a constant in this file:

        strip children  ==  `Control Settings/Toggles` children   (inherited,
                            switched off by the host, never destroyed)
                        +   len(captions)                          (read out
                            of the host's own `native subtabs: built the <A> |
                            <B> strip as a SIBLING ...` line)

    Falsifying inputs, stated because a check whose failing input cannot be
    described is not a check (CLAUDE.md 9b):

      FAIL          no strip AND no `native subtabs` line in the host log --
                    the 09:05 live regression exactly; or the host logged a
                    build and the strip is not there; or more than one
                    `Toggles(Clone)` sits under SettingsScreen; or the child
                    arithmetic does not come out.
      INCONCLUSIVE  nativeTabsSubtabs was off (nothing was built, so nothing
                    is claimed); the one strip went to MODS this session; the
                    tree did not print completely; the donor could not be
                    found, so there is no expected number to compare against.
      PASS          exactly one strip, in the right place, with exactly
                    `inherited + logged subtabs` children.
    """
    def refuse(kind, why, detail=""):
        report.record(POSTFX_STRIP_NAME, kind, why, detail)
        report.record(POSTFX_GROUP_NAME, INCONCLUSIVE,
                      "NOT PERFORMED: %s" % why, detail)

    if flag_on is False:
        refuse(INCONCLUSIVE, note or "nativeTabsSubtabs was off this session")
        return
    _s, raw = ch.run_batch(["tree %s 2" % SETTINGS_ROOT], live_dir=live,
                           timeout=40)
    t = ch.parse_tree(host_text(raw))
    if not t["parse_ok"] or not t["complete"]:
        refuse(INCONCLUSIVE,
               "`tree %s 2` did not print a complete tree" % SETTINGS_ROOT)
        return
    kids, why = _depth2_direct_children(t["nodes"])
    if kids is None:
        refuse(INCONCLUSIVE, why)
        return
    strips = [k for k in kids if k["name"] == NT_SUB_STRIP_NAME]
    names = ", ".join(k["name"] for k in kids) or "none"

    if len(strips) > 1:
        refuse(FAIL,
               "%d nodes named `%s` are direct children of SettingsScreen; "
               "the host builds AT MOST ONE strip (`gNtSubBuilt` guards "
               "`ntBuildSubtabs`), so this is a strip that was built twice or "
               "not cleaned up" % (len(strips), NT_SUB_STRIP_NAME), names)
        return
    if not strips:
        if captions is None and mods_n is not None:
            refuse(INCONCLUSIVE,
                   "the host logged `native mods: built %d mod subtab(s)`, so "
                   "this session's ONE strip is the MODS (rows) strip and "
                   "there is no GRAPHICS SETTINGS | POSTFX strip to find"
                   % mods_n, names)
        elif captions is None:
            # THE 09:05 REGRESSION: nothing on screen and nothing in the log.
            report.record(POSTFX_STRIP_NAME, FAIL,
                          "no `%s` child of SettingsScreen AND %s -- the "
                          "strip was never built this session"
                          % (NT_SUB_STRIP_NAME,
                             note or "the host log has no `native subtabs` "
                                     "line"), names)
            report.record(POSTFX_GROUP_NAME, INCONCLUSIVE,
                          "NOT PERFORMED: there is no subtab strip to read "
                          "toggles from -- nothing about the group was "
                          "checked", names)
        else:
            report.record(POSTFX_STRIP_NAME, FAIL,
                          "the host logged building the `%s` strip but no `%s` "
                          "child of SettingsScreen exists"
                          % (" | ".join(captions), NT_SUB_STRIP_NAME), names)
            report.record(POSTFX_GROUP_NAME, INCONCLUSIVE,
                          "NOT PERFORMED: there is no subtab strip to read "
                          "toggles from", names)
        return

    strip = strips[0]
    got = strip["child_count"]
    if captions is None:
        refuse(INCONCLUSIVE,
               "a `%s` strip IS a direct child of SettingsScreen with %s "
               "child(ren), but %s, so how many of them should be subtabs is "
               "not known" % (NT_SUB_STRIP_NAME, got,
                              note or "the host logged no subtab count"),
               strip["ptr"])
        return
    donor = next((k for k in kids if k["name"] == NT_SUB_DONOR_PANEL), None)
    dstrip = next((g for g in (donor or {}).get("grandchildren", [])
                   if g["name"] == NT_SUB_DONOR_STRIP), None)
    inherited = dstrip["child_count"] if dstrip else None
    if inherited is None or got is None:
        refuse(INCONCLUSIVE,
               "the strip is present (%s) but `%s/%s` -- the donor whose "
               "buttons the clone inherits -- could not be counted, so the "
               "expected child count cannot be computed"
               % (strip["ptr"], NT_SUB_DONOR_PANEL, NT_SUB_DONOR_STRIP),
               names)
        return

    want = inherited + len(captions)
    measured = ("the strip is a direct child of SettingsScreen with %d "
                "child(ren), want %d" % (got, want))
    detail = ("%d inherited from `%s/%s` (cloned, then SetActive(false) -- "
              "never destroyed) + %d subtab(s) the host logged: %s | strip %s"
              % (inherited, NT_SUB_DONOR_PANEL, NT_SUB_DONOR_STRIP,
                 len(captions), " | ".join(captions), strip["ptr"]))
    if got != want:
        report.record(POSTFX_STRIP_NAME, FAIL, measured, detail)
        report.record(POSTFX_GROUP_NAME, INCONCLUSIVE,
                      "NOT PERFORMED: the strip's child count does not match "
                      "`inherited + logged subtabs`, so WHICH of its children "
                      "are ours cannot be decided -- reading a slice of them "
                      "anyway would be a guess", detail)
        return
    report.record(POSTFX_STRIP_NAME, PASS, measured, detail)
    assert_postfx_group_one_on(report, live, strip["ptr"], inherited, captions)


def _depth2_direct_children(nodes):
    """(([direct_child_node, ...]), "") or (None, note) from a `tree X 2`.

    Each returned child is a COPY of the parsed node with a `grandchildren`
    key holding its own children (the depth-2 tree prints them but does not
    expand them further). That is what lets the postfx assertion count the
    DONOR strip `Control Settings/Toggles` from the same single tree it
    already has, instead of issuing a second walk that could see a different
    frame.

    parse_tree exposes no depth -- only the name, the pointer and the node's
    own child count -- so "which of these lines are DIRECT children" cannot be
    read off indentation. It CAN be recomputed exactly, because at a depth cap
    of 2 the grandchildren print their counts but never expand: the flat
    preorder list is root, then, for each direct child, that child followed by
    exactly `child_count` grandchildren.

    Every step of that arithmetic is checked and any mismatch is a REFUSAL, not
    a guess -- the failure this avoids is pairing a toggle with the wrong node
    and then reporting its m_IsOn with full confidence.
    """
    if not nodes:
        return None, "the tree printed no nodes at all"
    root = nodes[0]
    kids = []
    i = 1
    while i < len(nodes):
        kid = nodes[i]
        gc = kid["child_count"] or 0
        if i + 1 + gc > len(nodes):
            return None, ("`%s` claims %d child(ren) but only %d node(s) "
                          "follow it, so the depth-2 layout does not add up "
                          "and the parent/child pairing cannot be trusted"
                          % (kid["name"], gc, len(nodes) - i - 1))
        kid = dict(kid)
        kid["grandchildren"] = nodes[i + 1:i + 1 + gc]
        kids.append(kid)
        i += 1 + gc
    want = root["child_count"]
    if want is not None and len(kids) != want:
        return None, ("`%s` reports %d child(ren) but the depth-2 arithmetic "
                      "yields %d -- the two disagree, so nothing is read off "
                      "this tree" % (root["name"], want, len(kids)))
    return kids, ""


def _postfx_toggle_hosts(live, strip_ptr, subtabs):
    """[(subtab_name, animated_toggle_ptr)] for each subtab, or (None, note).

    MEASURED 2026-09-02: the strip's children do NOT carry the Toggle
    themselves -- each holds it on an `AnimatedToggle` child. One `tree
    <child> 2` per subtab answers where that child is; the pairing is then
    recomputed with _depth2_direct_children rather than assumed positionally.

    Exactly ONE direct child whose name starts with `AnimatedToggle` is
    required. Zero is a refusal (the layout changed and this assertion no
    longer knows what it is reading); more than one is also a refusal, because
    picking "the first" would be inventing an answer.
    """
    out = []
    for sub in subtabs:
        _s, raw = ch.run_batch(["tree %s 2" % sub["ptr"]], live_dir=live,
                               timeout=40)
        t = ch.parse_tree(host_text(raw))
        if not t["parse_ok"] or not t["complete"]:
            return None, ("`tree %s 2` did not print a complete tree for "
                          "subtab `%s`" % (sub["ptr"], sub["name"]))
        kids, note = _depth2_direct_children(t["nodes"])
        if kids is None:
            return None, "subtab `%s`: %s" % (sub["name"], note)
        hosts = [k for k in kids if k["name"].startswith("AnimatedToggle")]
        if len(hosts) != 1:
            return None, ("subtab `%s` has %d direct child(ren) named "
                          "AnimatedToggle*, expected exactly 1 (children: %s)"
                          % (sub["name"], len(hosts),
                             ", ".join(k["name"] for k in kids) or "none"))
        out.append((sub["name"], hosts[0]["ptr"]))
    return out, ""


def assert_postfx_group_one_on(report, live, strip_ptr, inherited=0,
                               captions=None):
    """The postfx subtab strip is ONE ToggleGroup with EXACTLY ONE tab selected.

    `inherited` is how many of the strip's children came with the CLONE and are
    the donor's, not ours -- they are switched off, never destroyed, and they
    sit FIRST because ours are parented in afterwards. They must be skipped:
    the donor's own selected button would otherwise be read as a second ON and
    reported as a confidently wrong FAIL. The slice is only taken when the
    child count is exactly `inherited + len(captions)`; anything else is a
    REFUSAL, because picking which children are ours would be a guess.

    This assertion was `NOT PERFORMED` until now and said so, which was honest
    but bought nothing. It is the same discipline as
    assert_row_group_one_on -- `component <ptr> UnityEngine.UI.Toggle`, then
    m_Group@0x110 and m_IsOn@0x120 with the address echo checked against the
    component pointer -- applied one level down.

    Three outcomes, and the falsifying inputs are stated because a check whose
    failing input cannot be described is not a check (CLAUDE.md 9b):

      FAIL          two subtabs ON (or none), or the toggles do not all report
                    the SAME m_Group, or that shared group is null -- a strip
                    whose toggles are in no group is not a strip that can
                    behave like tabs.
      INCONCLUSIVE  any toggle could not be read: no Toggle component, an
                    unreadable field, or an address echo that did not match.
      PASS          one group, non-null, shared by all, exactly one ON.
    """
    _s, raw = ch.run_batch(["tree %s 2" % strip_ptr], live_dir=live, timeout=40)
    t = ch.parse_tree(host_text(raw))
    if not t["parse_ok"] or not t["complete"]:
        report.record(POSTFX_GROUP_NAME, INCONCLUSIVE,
                      "`tree %s 2` did not print a complete tree" % strip_ptr)
        return
    subtabs, note = _depth2_direct_children(t["nodes"])
    if subtabs is None:
        report.record(POSTFX_GROUP_NAME, INCONCLUSIVE, note)
        return
    if captions is not None:
        want = inherited + len(captions)
        if len(subtabs) != want:
            report.record(POSTFX_GROUP_NAME, INCONCLUSIVE,
                          "the strip printed %d direct child(ren) but %d "
                          "inherited + %d logged subtab(s) were expected, so "
                          "which children are OURS cannot be decided"
                          % (len(subtabs), inherited, len(captions)))
            return
        subtabs = subtabs[inherited:]
    if len(subtabs) < 2:
        report.record(POSTFX_GROUP_NAME, FAIL,
                      "the subtab strip has %d subtab(s) of ours; a group of "
                      "tabs needs at least 2" % len(subtabs))
        return
    members, note = _postfx_toggle_hosts(live, strip_ptr, subtabs)
    if members is None:
        report.record(POSTFX_GROUP_NAME, INCONCLUSIVE, note)
        return

    states = []
    for nm, host_ptr in members:
        got, why = read_toggle_fields(live, host_ptr,
                                      (("m_Group", TOGGLE_GROUP_OFF, "ptr"),
                                       ("m_IsOn", TOGGLE_ISON_OFF, "bool")))
        states.append((nm, got, why))

    unknown = [(nm, why) for nm, got, why in states if got is None]
    if unknown:
        report.record(POSTFX_GROUP_NAME, INCONCLUSIVE,
                      "m_Group@0x%x / m_IsOn@0x%x could not be trusted for %d "
                      "of %d subtab toggle(s), so neither the group nor the "
                      "count of ON is known"
                      % (TOGGLE_GROUP_OFF, TOGGLE_ISON_OFF, len(unknown),
                         len(states)),
                      "; ".join("%s: %s" % (nm, why) for nm, why in unknown[:3]))
        return

    groups = sorted({got["m_Group"] for _nm, got, _w in states})
    on = [nm for nm, got, _w in states if got["m_IsOn"]]
    measured = ("%d subtab(s): %d distinct m_Group, %d ON"
                % (len(states), len(groups), len(on)))
    detail = ("ON: %s | group(s): %s"
              % (", ".join(on) or "none",
                 ", ".join("0x%016x" % g for g in groups)))
    if len(groups) != 1:
        report.record(POSTFX_GROUP_NAME, FAIL, measured,
                      "the subtabs are in %d different ToggleGroups, so they "
                      "cannot deselect one another. %s" % (len(groups), detail))
        return
    if groups[0] == 0:
        report.record(POSTFX_GROUP_NAME, FAIL, measured,
                      "every subtab reports m_Group = null: they are in NO "
                      "ToggleGroup at all, so nothing enforces one selection. "
                      + detail)
        return
    v = PASS if len(on) == 1 else FAIL
    report.record(POSTFX_GROUP_NAME, v, measured, detail)


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
    nt_names, nt_on, nt_note = native_tabs_built(args.root)
    assert_tab_count(report, live, nt_names, nt_on, nt_note)
    assert_no_donor_caption_on_clones(report, live, args.mods_built)
    assert_no_text(report, live, "no placeholder text on any RENDERED node",
                   PLACEHOLDER_TEXT)
    assert_row_group_one_on(report, live, published)
    sub_on, sub_why = native_subtabs_flag(args.root)
    caps, mods_n, _verds, attempt, sub_note = native_subtabs_built(args.root)
    if attempt is not None:
        # The host said, in this process, that the flag was ON. That outranks
        # the config file, which can have been edited since the client booted.
        sub_on, sub_why = True, ""
    assert_postfx_subtab(report, live, sub_on, caps, mods_n,
                         sub_why if sub_on is False else sub_note)
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


def _fx_strip(names, base=0x21c00440000, batch=100):
    """SHAPED, not measured: a `children` answer for a tab strip of arbitrary
    composition, so the clone check can be shown to fail on a count the
    measured 13-child corpus does not happen to contain (5 stock + 2 clones).
    The SHAPE is inspect.nim's iCmdChildren emit; the pointers are synthetic.
    Returns (ptrs, output)."""
    ptrs = ["0x%016x" % (base + i * 0x40) for i in range(len(names))]
    body = ("> children 0x%016x\n  childCount = %d\n"
            "  via Transform::GetChild / get_childCount, Object::get_name "
            "(calls)\n" % (base - 0x40, len(names)))
    body += "\n".join(
        '    [%d] transform=%s ($c%d)  go=0x%016x ($g%d)  name="%s"'
        % (i, ptrs[i], i, base + 0x10000 + i * 0x40, i, names[i])
        for i in range(len(names)))
    return ptrs, _hdr(batch, 1, body)


# ---- the POSTFX SUBTAB STRIP, SHAPED ------------------------------------
# SHAPED, not measured. The SHAPES are the ones in the corpus and are not
# invented here: `tree` is `fixtures/inspector/tree.txt`
# (tree-toggle-strip-depth2) and the component/read pair is
# `fixtures/inspector/component.txt` (toggle-ison-00-true, and
# component-toggle-absent for the refusal) -- pointer VALUES and node names are
# synthetic, because the live screen was in a raid when this was written and
# nothing here may be harvested by hand.
#
# The one shape NOT present in the corpus is `read $comp+0x110 ptr`. Its emit
# is inspect.nim iReadTyped's `ptr` branch -- `  <addr> as ptr = <value>` plus
# `  readable` / `  NOT readable` / `  NULL` -- read out of the source, and it
# is labelled INFERRED-FROM-SOURCE rather than measured for exactly that
# reason. If it is wrong, `_READ_AT_RE` stops matching and the assertion goes
# INCONCLUSIVE; it cannot turn into a false PASS.
# THE NATIVE SUBTAB FIXTURES ARE **SHAPED**, NOT MEASURED. The live client was
# not available to harvest from (a bisect boot was running), so only the FORMAT
# is copied -- from the measured `tree-toggle-strip-depth2` entry in
# tools/fixtures/inspector/tree.txt, via _fx_tree. The NAMES below are shaped
# from nativetabs.nim (`ntBuildSubtabs` clones `Control Settings/Toggles` and
# its `ControlToggle`, and never renames either, so Unity's "(Clone)" suffix is
# what the tree prints); the POINTERS are invented. Only the COUNTS and the
# ORDER -- inherited donor buttons first, ours appended after -- are
# load-bearing, and both of those are read out of nativetabs.nim, not guessed.
_PFX_STRIP = "0x000002024b100000"
_PFX_CAPS = ["GRAPHICS SETTINGS", "POSTFX"]      # the host's own build line
_PFX_DONOR_SUBS = ["ControlToggle", "GesturesToggle"]
_PFX_DONOR_PTRS = ["0x%016x" % (0x2024b1a1000 + i * 0x40) for i in range(4)]
_PFX_DONOR_AT_PTRS = ["0x%016x" % (0x2024b1a2000 + i * 0x40) for i in range(4)]
_PFX_SUBS = ["ControlToggle(Clone)"] * 4
_PFX_SUB_PTRS = ["0x%016x" % (0x2024b101000 + i * 0x40) for i in range(4)]
_PFX_AT_PTRS = ["0x%016x" % (0x2024b102000 + i * 0x40) for i in range(4)]
_PFX_COMP_PTRS = ["0x%016x" % (0x2024b103000 + i * 0x400) for i in range(4)]
_PFX_GROUP = 0x0000020244f84a80


def _fx_tree(root_name, root_ptr, kids, batch=110):
    """A `tree PTR 2` answer: root, then each child followed by its own
    children. Shape from fixture `tree-toggle-strip-depth2`."""
    body = ['> tree %s 2' % root_ptr,
            '  tree from %s name="%s" (max depth 2, max 3000 nodes)'
            % (root_ptr, root_name),
            '    "%s"  %s  (%d child)' % (root_name, root_ptr, len(kids))]
    n = 1
    for name, ptr, gkids in kids:
        body.append('      + "%s"  %s  (%d child)' % (name, ptr, len(gkids)))
        n += 1
        for gname, gptr, gcount in gkids:
            body.append('        + "%s"  %s  (%d child)'
                        % (gname, gptr, gcount))
            n += 1
    body.append("  %d node(s) printed  -- complete." % n)
    return _hdr(batch, 2, "\n".join(body))


def _fx_toggle_read(node_ptr, comp_ptr, group, ison, batch=120):
    """`component <ptr> UnityEngine.UI.Toggle` + `read $comp+0x110 ptr` +
    `read $comp+0x120 bool`. The address each read prints is comp+offset, which
    is the arithmetic read_toggle_fields refuses to proceed without.

    `group=None` records the REFUSAL shape instead: `component` answered NULL
    and the reads printed `! not readable`, which must never be read as 0."""
    c = int(comp_ptr, 16)
    if group is None:
        return _hdr(batch, 3, """> component %s UnityEngine.UI.Toggle
  ! via GetComponent(Type) on %s: GetComponent(Type) returned NULL -- an \
ANSWER: this object has no component of that type.
> read $comp+0x110 ptr
  ! not readable for 8 bytes at 0x0000000000000110
> read $comp+0x120 bool
  ! not readable for 1 bytes at 0x0000000000000120""" % (node_ptr, node_ptr))
    return _hdr(batch, 3, """> component %s UnityEngine.UI.Toggle
  FOUND UnityEngine.UI.Toggle component = %s  klass=0x000001ffe2f98030   \
($comp)   via GetComponent(System.Type) -- klass identity, no string match
  bound to $comp -- e.g.  allow write   then   click $comp
> read $comp+0x110 ptr
  0x%016x as ptr = 0x%016x  readable
> read $comp+0x120 bool
  0x%016x as bool = %s  (0x%02x)"""
                % (node_ptr, comp_ptr, c + TOGGLE_GROUP_OFF, group,
                   c + TOGGLE_ISON_OFF, "true" if ison else "false",
                   1 if ison else 0))


def _fx_settings_tree(ours=2, inherited=2, strip=True, extra=0, strips=1,
                      batch=111):
    """`tree $settings 2` for the NATIVE design (SHAPED -- see _PFX_STRIP).

    The strip is a DIRECT CHILD of SettingsScreen, a SIBLING of the panels --
    NOT a child of `Graphics Settings`, which is why that panel is emitted with
    no children at all here: the old path is deleted, and a fixture that still
    showed it there would let the deleted design keep passing.

    `Control Settings` still carries the donor `Toggles` the clone came from,
    with `inherited` buttons, because that count is half the arithmetic the
    assertion does. `extra` adds children to the strip that the host never
    logged -- the falsifying input.
    """
    n = inherited + ours + extra
    kids = [("Toggles", "0x000002024b000080",
             [("GameToggleSpawner", "0x000002024b000090", 1)]),
            ("Graphics Settings", "0x000002024b000100", []),
            ("Sound Settings", "0x000002024b000200", []),
            (NT_SUB_DONOR_PANEL, "0x000002024b000300",
             [(NT_SUB_DONOR_STRIP, "0x000002024b000380", inherited)])]
    for s in range(strips):
        kids.append((NT_SUB_STRIP_NAME, "0x%016x" % (int(_PFX_STRIP, 16) +
                                                     s * 0x1000),
                     [(nm, ptr, 1) for nm, ptr in _fx_strip_children(
                         ours, inherited, extra)]))
    return _fx_tree("SettingsScreen", "0x000002024b000000", kids, batch=batch)


def _fx_strip_children(ours, inherited, extra=0):
    """[(name, ptr)] in the order the live tree prints them: the donor's own
    buttons FIRST (they came with the clone and were only switched off), then
    ours. `extra` appends unaccounted-for children."""
    out = [(_PFX_DONOR_SUBS[i % len(_PFX_DONOR_SUBS)], _PFX_DONOR_PTRS[i])
           for i in range(inherited)]
    out += [(_PFX_SUBS[i], _PFX_SUB_PTRS[i]) for i in range(ours)]
    out += [("Stray(Clone)", "0x%016x" % (0x2024b1f0000 + i))
            for i in range(extra)]
    return out


def _fx_postfx_script(groups, ons, at_children=("AnimatedToggle",),
                      inherited=2, extra=0):
    """The WHOLE replay script for assert_postfx_subtab, parameterised by what
    OUR subtab toggles report (`len(groups)` of them). `groups[i] is None`
    records the refusal shape.

    NOTHING IS RECORDED FOR THE INHERITED DONOR BUTTONS ON PURPOSE. They are
    in the strip and they carry AnimatedToggle children of their own, so if the
    assertion ever reads them the replay RAISES on an unrecorded command --
    which is the negative control for the skip. Reading them live would find
    the donor's selected button and report a second ON as a FAIL.
    """
    ours = len(groups)
    script = [("tree %s 2" % SETTINGS_ROOT,
               [_fx_settings_tree(ours=ours, inherited=inherited, extra=extra)]),
              ("tree %s 2" % _PFX_STRIP,
               [_fx_tree(NT_SUB_STRIP_NAME, _PFX_STRIP,
                         [(nm, ptr, [("AnimatedToggle",
                                      (_PFX_DONOR_AT_PTRS[i] if i < inherited
                                       else _PFX_AT_PTRS[i - inherited]), 2)])
                          for i, (nm, ptr) in
                          enumerate(_fx_strip_children(ours, inherited, extra))],
                         batch=112)])]
    for i in range(ours):
        # Each subtab: its AnimatedToggle child (which has grandchildren of its
        # own, so the depth-2 arithmetic is actually exercised) plus a Label.
        kids = [(nm, _PFX_AT_PTRS[i],
                 [("Background", "0x%016x" % (0x2024b105000 + i * 8), 0),
                  ("Checkmark", "0x%016x" % (0x2024b106000 + i * 8), 0)])
                for nm in at_children]
        kids.append(("Label", "0x%016x" % (0x2024b104000 + i), []))
        script.append(("tree %s 2" % _PFX_SUB_PTRS[i],
                       [_fx_tree(_PFX_SUBS[i], _PFX_SUB_PTRS[i], kids,
                                 batch=113 + i)]))
    for i in range(ours):
        script.append(
            ("component %s UnityEngine.UI.Toggle" % _PFX_AT_PTRS[i],
             [_fx_toggle_read(_PFX_AT_PTRS[i], _PFX_COMP_PTRS[i],
                              groups[i], ons[i], batch=120 + i)]))
    return script


def _fx_active_ptrs(ptrs, flags, batch=101):
    """One `assert-active` verdict per pointer, in command order (shaped)."""
    body = "\n".join(
        ("> assert-active %s\n  PASS: %s activeInHierarchy = true, as claimed"
         % (p, p)) if a else
        ("> assert-active %s\n  FAIL: %s activeInHierarchy = false, but "
         "assert-active claimed true." % (p, p))
        for p, a in zip(ptrs, flags))
    return _hdr(batch, len(ptrs), body)


def _declared_screen_assertion_names():
    """Every assertion name `run_screen_assertions` can print on the READY
    path, read out of the source. Falsifiable on purpose: add an assertion to
    that function and forget SCREEN_ASSERTION_NAMES, and this disagrees."""
    import inspect as _pyinspect
    names = set()
    for fn in (assert_tab_count, assert_no_donor_caption_on_clones,
               assert_row_group_one_on, assert_postfx_subtab,
               assert_postfx_group_one_on, assert_one_panel_active):
        src = _pyinspect.getsource(fn)
        names |= set(re.findall(r'report\.record\(\s*"([^"]+)"', src))
        names |= set(re.findall(r'^\s*name\s*=\s*"([^"]+)"', src, re.M))
        # A name held in a module CONSTANT is still a name this can print, and
        # a scraper that only saw literals would silently stop covering an
        # assertion the moment it was factored out.
        for ident in re.findall(r'report\.record\(\s*([A-Z][A-Z_0-9]*)\s*,',
                                src):
            val = globals().get(ident)
            if isinstance(val, str):
                names.add(val)
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
        assert_tab_count(rep, "X")
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
        assert_tab_count(rep, "X")
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
    DONOR_NAME = "no donor caption on any aowlspt-cloned settings row"
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
        if "22 on a `(Clone)(Clone)` row" not in m or "2 stock" not in m:
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

    # --- 9a-9c. THE ANCESTRY PROBE IS THREE-STATE. -------------------------
    #     panel_of used to wrap its walk in one `except Exception` and render
    #     every failure as the STRING "unresolved (AssertionError)", which the
    #     caller interpolated as `(panel: unresolved (AssertionError))` inside
    #     a FAIL. Offline that is the replay refusing; LIVE it is an inspector
    #     refusal, an abandoned batch or an unreadable pointer -- and all four
    #     printed as something that reads like a panel attribution. These three
    #     cases pin the refusal, the answer, and the two apart.
    #
    #     BOTH `parent` replies below are SHAPED (tier 2), not captured: no
    #     `parent` reply exists in tools/fixtures/inspector/. The SHAPE is the
    #     emit site inspect.nim:1313 (`    [N] transform=P klass=K name="X"
    #     go=G activeSelf=B`) and iErr's `  ! ` prefix at inspect.nim:798; the
    #     NAMES are the walk quoted in panel_of's docstring, measured live on
    #     2026-09-02. Harvest a real capture and delete these.
    FX_PARENT_WALK = _hdr(101, 1, """> parent 0x00000203095d3e00 8
  via Transform::get_parent, Component::get_transform, Object::get_name, \
Component::get_gameObject, GameObject::get_activeSelf (calls, not field reads)
    [0] transform=0x00000203095d3e00 klass=0x00007ffb1a2b0040 name="Text" \
go=0x00000203095d3f00 activeSelf=true
    [1] transform=0x00000203095d3a00 klass=0x00007ffb1a2b0040 \
name="Settings Drop Down(Clone)(Clone)" go=0x00000203095d3b00 activeSelf=true
    [2] transform=0x0000020244f7e840 klass=0x00007ffb1a2b0040 name="Settings" \
go=0x0000020244f7e940 activeSelf=true
    [3] transform=0x0000020244f7e440 klass=0x00007ffb1a2b0040 name="Viewport" \
go=0x0000020244f7e540 activeSelf=true
    [4] transform=0x0000020244f7e040 klass=0x00007ffb1a2b0040 \
name="Scroll View" go=0x0000020244f7e140 activeSelf=true
    [5] transform=0x0000020244f7dc40 klass=0x00007ffb1a2b0040 name="Container" \
go=0x0000020244f7dd40 activeSelf=true
    [6] transform=0x0000020244f7d840 klass=0x00007ffb1a2b0040 \
name="Game Settings" go=0x0000020244f7d940 activeSelf=true""")

    PARENT_REFUSAL = "Transform::get_parent did not verify on this build"
    FX_PARENT_REFUSED = _hdr(102, 1, """> parent 0x00000203095d3e00 8
  via Transform::get_parent, Component::get_transform, Object::get_name, \
Component::get_gameObject, GameObject::get_activeSelf (calls, not field reads)
  ! %s; cannot walk""" % PARENT_REFUSAL)

    def _donor_row(rep):
        return [r for r in rep.rows if r[0] == DONOR_NAME][0]

    def c9a(rep, _rp):
        assert_no_donor_caption_on_clones(rep, "X", True)
        _n, v, m, d = _donor_row(rep)
        if v != FAIL:
            return "a refused ancestry probe changed the verdict to %s -- the "\
                   "finding comes from the findtext parents, not the probe" % v
        if "UNRESOLVED (" not in d:
            return "the FAIL detail did not mark the probe UNRESOLVED: %r" % d
        if PARENT_REFUSAL not in d:
            return "UNRESOLVED did not carry the host's reason: %r" % d
        if "panel: Game Settings" in d or "owning panel(s)" in m:
            return ("a panel was attributed from a walk that refused: %r / %r"
                    % (m, d))
        if "ancestry probe(s) UNRESOLVED" not in m:
            return "the refusals were not counted in the measured line: %r" % m
        return ""
    case("panel probe REFUSED by the host -> FAIL kept, panel UNRESOLVED(reason)",
         [('findtext "Interface language"', [FT_DONOR]),
          ("parent ", [FX_PARENT_REFUSED])], c9a)

    def c9b(rep, _rp):
        assert_no_donor_caption_on_clones(rep, "X", True)
        _n, v, m, d = _donor_row(rep)
        if v != FAIL:
            return "22 donor captions under the row clones did not FAIL"
        if "(panel: Game Settings)" not in d:
            return "the successful walk did not attribute the panel: %r" % d
        if "owning panel(s): Game Settings" not in m:
            return "the owner was not named in the measured line: %r" % m
        if "UNRESOLVED" in d or "UNRESOLVED" in m:
            return "a walk that ANSWERED was reported unresolved: %r / %r" % (m, d)
        return ""
    case("control: panel probe ANSWERS -> panel named, nothing UNRESOLVED",
         [('findtext "Interface language"', [FT_DONOR]),
          ("parent ", [FX_PARENT_WALK])], c9b)

    def c9c(rep, _rp):
        # No `parent` recording at all: the replay RAISES. That is the exact
        # offline shape of a live abandoned batch, and it must not become a
        # panel name either.
        assert_no_donor_caption_on_clones(rep, "X", True)
        _n, v, m, d = _donor_row(rep)
        if v != FAIL:
            return "a raising ancestry probe changed the verdict to %s" % v
        if "UNRESOLVED (AssertionError" not in d:
            return ("a raised probe was not reported as UNRESOLVED with its "
                    "exception named: %r" % d)
        return ""
    case("control: panel probe RAISES -> FAIL kept, UNRESOLVED(AssertionError)",
         [('findtext "Interface language"', [FT_DONOR])], c9c)

    print("\n---- unit: panel_of is three-state")
    _saved = ch.run_batch
    try:
        ch.run_batch = _Replay([("parent ", [FX_PARENT_WALK])])
        got = panel_of("X", ["0x1"])["0x1"]
        if got != "Game Settings":
            failures.append("panel_of on a real walk returned %r, want the "
                            "outermost named ancestor" % (got,))
        ch.run_batch = _Replay([("parent ", [FX_PARENT_REFUSED])])
        got = panel_of("X", ["0x1"])["0x1"]
        if not isinstance(got, Refusal) or PARENT_REFUSAL not in got.reason:
            failures.append("panel_of on a host refusal returned %r, want a "
                            "Refusal carrying the reason" % (got,))
        # walked, answered, no NAMED ancestor -> None, which is an ANSWER and
        # must not be confused with the refusal above.
        ch.run_batch = _Replay([("parent ", [_hdr(103, 1, """> parent 0x1 8
  via Transform::get_parent, Component::get_transform, Object::get_name, \
Component::get_gameObject, GameObject::get_activeSelf (calls, not field reads)
    [0] 0x0000000000000001  (not readable; chain ends)""")])])
        got = panel_of("X", ["0x1"])["0x1"]
        if not isinstance(got, Refusal) or "not readable" not in got.reason:
            failures.append("panel_of on an unreadable pointer returned %r, "
                            "want a Refusal" % (got,))
        else:
            print("  case ok (name / Refusal(host reason) / Refusal(unreadable)"
                  " are three distinct results)")
    finally:
        ch.run_batch = _saved

    print("\n---- parser: findtext HIT lines (SHARED with channel.py)")
    hits = findtext_hits(FT_DONOR)
    chan = ch.parse_find(host_text(FT_DONOR))["hits"]
    printed = len([l for l in FT_DONOR.splitlines()
                   if l.strip().startswith("HIT ")])
    if len(hits) != 24:
        failures.append("findtext_hits parsed %d of 24 measured HIT lines"
                        % len(hits))
    elif len(chan) != printed:
        # The two must AGREE, and both must agree with what the host printed.
        # This is the assertion that failed before 2026-09-02 (chan was 0) and
        # the reason there is one parser again rather than two.
        failures.append("the shared channel.py parser found %d of the %d HIT "
                        "lines the host printed -- findtext_hits delegates to "
                        "it, so these cannot be allowed to differ"
                        % (len(chan), printed))
    elif any(h["parent"] is None or h["active"] is None or not h["text"]
             for h in hits):
        failures.append("a parsed hit is missing parent/text/activeInHierarchy")
    else:
        print("  case ok (24 hits, all with parent + text + active; the shared "
              "channel.py parser returns %d on the same %d printed HIT lines)"
              % (len(chan), printed))

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

    # --- 16b. THE POSTFX SUBTAB GROUP. Was NOT PERFORMED; now it is. -------
    #     Four cases, and three of them are the falsifying ones: this
    #     assertion is worth having only if there is an input that makes it
    #     say FAIL and an input that makes it say INCONCLUSIVE.
    G = _PFX_GROUP
    CAPS = _PFX_CAPS

    def _pfx(rep, **kw):
        """The call run_screen_assertions makes: flag ON, and the captions the
        host logged. Anything a case wants to vary, it varies by name."""
        kw.setdefault("flag_on", True)
        kw.setdefault("captions", CAPS)
        assert_postfx_subtab(rep, "X", **kw)

    def _row(rep, name):
        rows = [r for r in rep.rows if r[0] == name]
        return rows[0] if rows else None

    def c16a(rep, _rp):
        _pfx(rep)
        v = _verdicts(rep)
        if v.get(POSTFX_STRIP_NAME) != PASS:
            return "the strip half regressed: %s (%r)" % (
                v.get(POSTFX_STRIP_NAME), _row(rep, POSTFX_STRIP_NAME)[2])
        srow = _row(rep, POSTFX_STRIP_NAME)
        if "4 child(ren), want 4" not in srow[2]:
            return "the child arithmetic was not stated: %r" % srow[2]
        if "2 inherited" not in srow[3]:
            return "the inherited donor buttons were not named: %r" % srow[3]
        if v.get(POSTFX_GROUP_NAME) != PASS:
            row = _row(rep, POSTFX_GROUP_NAME)
            return "one group, one ON did not PASS: %s %r" % (row[1], row[2])
        row = _row(rep, POSTFX_GROUP_NAME)
        if "1 distinct m_Group, 1 ON" not in row[2]:
            return "the measurement was not stated: %r" % row[2]
        return ""
    case("native subtabs: strip is a SIBLING, one group, exactly one ON -> PASS",
         _fx_postfx_script([G] * 2, [True, False]), c16a)

    def c16b(rep, _rp):
        _pfx(rep)
        if _verdicts(rep).get(POSTFX_GROUP_NAME) != FAIL:
            return "two subtabs ON at once did not FAIL"
        return ""
    case("control: two postfx subtabs ON -> FAIL",
         _fx_postfx_script([G] * 2, [True, True]), c16b)

    def c16c(rep, _rp):
        _pfx(rep)
        row = _row(rep, POSTFX_GROUP_NAME)
        if row[1] != FAIL:
            return "two different ToggleGroups did not FAIL: %s" % row[1]
        if "2 distinct m_Group" not in row[2]:
            return "the group split was not stated: %r" % row[2]
        return ""
    case("control: postfx subtabs in two different groups -> FAIL",
         _fx_postfx_script([G, G + 0x40], [True, False]), c16c)

    def c16d(rep, _rp):
        _pfx(rep)
        v = _verdicts(rep).get(POSTFX_GROUP_NAME)
        if v == FAIL:
            return ("an UNREADABLE toggle was counted as a failure -- 'I could "
                    "not look' is not 'the condition does not hold'")
        if v != INCONCLUSIVE:
            return "expected INCONCLUSIVE, got %s" % v
        return ""
    case("control: one postfx subtab has no Toggle -> INCONCLUSIVE, not FAIL",
         _fx_postfx_script([G, None], [True, False]), c16d)

    def c16e(rep, _rp):
        _pfx(rep)
        row = _row(rep, POSTFX_GROUP_NAME)
        if row[1] != INCONCLUSIVE:
            return ("a subtab with TWO AnimatedToggle children was resolved "
                    "anyway (verdict %s) -- picking the first would be an "
                    "invented answer" % row[1])
        return ""
    case("control: ambiguous AnimatedToggle child -> INCONCLUSIVE",
         _fx_postfx_script([G] * 2, [True, False],
                           at_children=("AnimatedToggle",
                                        "AnimatedToggle(Clone)")), c16e)

    # --- 16f-16k. THE NATIVE STRIP ITSELF. The old assertion looked under
    #     `Graphics Settings`; these are the inputs that make the new one say
    #     each of its three answers about the strip's PLACEMENT and SIZE.

    def c16f(rep, rp):
        _pfx(rep, captions=None,
             note="the host log has no `native subtabs` line")
        v = _verdicts(rep)
        if v.get(POSTFX_STRIP_NAME) != FAIL:
            return ("no strip AND no host `native subtabs` line -- the 09:05 "
                    "live regression -- did not FAIL: %s"
                    % v.get(POSTFX_STRIP_NAME))
        if "native subtabs" not in _row(rep, POSTFX_STRIP_NAME)[2]:
            return ("the FAIL does not name the missing log line: %r"
                    % _row(rep, POSTFX_STRIP_NAME)[2])
        if v.get(POSTFX_GROUP_NAME) != INCONCLUSIVE:
            return "the group half claimed something with no strip to read"
        if any(s.startswith("component ") for s in rp.sent):
            return "read toggles although there was no strip"
        return ""
    case("THE 09:05 REGRESSION: no strip and no `native subtabs` line -> FAIL",
         [("tree %s 2" % SETTINGS_ROOT, [_fx_settings_tree(strips=0)])], c16f)

    def c16f2(rep, _rp):
        _pfx(rep, captions=None,
             note=("the host printed `native subtabs: build attempted "
                   "(nativeTabsSubtabs is ON) and returned false` -- the "
                   "build ran and REFUSED"))
        if _verdicts(rep).get(POSTFX_STRIP_NAME) != FAIL:
            return "a build that RAN AND REFUSED was not a FAIL"
        if "REFUSED" not in _row(rep, POSTFX_STRIP_NAME)[2]:
            return "the refusal the host reported was not carried into the row"
        return ""
    case("control: the host attempted the build and it returned false -> FAIL",
         [("tree %s 2" % SETTINGS_ROOT, [_fx_settings_tree(strips=0)])], c16f2)

    def c16g(rep, rp):
        _pfx(rep, captions=None, mods_n=3,
             note="the host log has no `native subtabs` line")
        v = _verdicts(rep)
        if v.get(POSTFX_STRIP_NAME) != INCONCLUSIVE:
            return ("a session whose ONE strip went to MODS was judged %s "
                    "rather than INCONCLUSIVE" % v.get(POSTFX_STRIP_NAME))
        if "mod subtab" not in _row(rep, POSTFX_STRIP_NAME)[2]:
            return "the MODS-strip reason was not stated"
        return ""
    case("control: the one strip was built for MODS -> INCONCLUSIVE, not FAIL",
         [("tree %s 2" % SETTINGS_ROOT, [_fx_settings_tree(strips=0)])], c16g)

    def c16h(rep, rp):
        _pfx(rep, flag_on=False,
             note="nativeTabsSubtabs = false in aowlspt-host.json")
        v = _verdicts(rep)
        if v.get(POSTFX_STRIP_NAME) != INCONCLUSIVE or \
           v.get(POSTFX_GROUP_NAME) != INCONCLUSIVE:
            return "a feature that was switched off produced a verdict"
        if rp.sent:
            return ("the client was walked anyway (%r) for a feature that was "
                    "off" % rp.sent)
        return ""
    case("control: nativeTabsSubtabs OFF -> INCONCLUSIVE, nothing walked",
         [], c16h)

    def c16i(rep, rp):
        _pfx(rep)
        v = _verdicts(rep)
        if v.get(POSTFX_STRIP_NAME) != FAIL:
            return ("a strip with one child MORE than `inherited + logged` "
                    "was judged %s" % v.get(POSTFX_STRIP_NAME))
        if "5 child(ren), want 4" not in _row(rep, POSTFX_STRIP_NAME)[2]:
            return "the arithmetic was not stated: %r" % _row(
                rep, POSTFX_STRIP_NAME)[2]
        if v.get(POSTFX_GROUP_NAME) != INCONCLUSIVE:
            return ("the group half read a slice of a strip whose shape it "
                    "could not account for")
        if any(s.startswith("component ") for s in rp.sent):
            return "read toggles out of a strip it could not account for"
        return ""
    case("control: strip has an unaccounted-for child -> FAIL, group refuses",
         [("tree %s 2" % SETTINGS_ROOT,
           [_fx_settings_tree(ours=2, extra=1)])], c16i)

    def c16j(rep, _rp):
        _pfx(rep)
        if _verdicts(rep).get(POSTFX_STRIP_NAME) != FAIL:
            return "two `Toggles(Clone)` strips under SettingsScreen did not FAIL"
        return ""
    case("control: TWO subtab strips under SettingsScreen -> FAIL",
         [("tree %s 2" % SETTINGS_ROOT, [_fx_settings_tree(strips=2)])], c16j)

    def c16k(rep, _rp):
        _pfx(rep, captions=None, note="the host logged no subtab count")
        v = _verdicts(rep)
        if v.get(POSTFX_STRIP_NAME) != INCONCLUSIVE:
            return ("a strip with no logged subtab count was judged %s -- "
                    "there is no number to compare it against"
                    % v.get(POSTFX_STRIP_NAME))
        return ""
    case("control: strip present but the host logged no count -> INCONCLUSIVE",
         [("tree %s 2" % SETTINGS_ROOT, [_fx_settings_tree()])], c16k)

    # --- 16l. THE HOST'S OWN LITERALS, against the message parser. ---------
    print("\n---- native subtabs: the host's own log lines")
    BUILT = ("native subtabs: built the GRAPHICS SETTINGS | POSTFX strip as a "
             "SIBLING of the panels it switches, not inside either one.")
    VERD = ("native subtabs VERDICT PASS (subtab selection): exactly one "
            "subtab reads m_IsOn=1 (POSTFX) and its panel is the ONLY active "
            "one of the two")
    MODS = ("native mods: built 3 mod subtab(s) from the "
            "/aowlspt/settings/index fetch")
    ATT_NO = ("native subtabs: build attempted (nativeTabsSubtabs is ON) and "
              "returned false. NOTE FOR ACCEPTANCE: this strip is a SIBLING "
              "of the panels, parented to SettingsScreen")
    caps, mods_n, verds, att, nt = _subtabs_from_messages([BUILT, VERD])
    if caps != ["GRAPHICS SETTINGS", "POSTFX"]:
        failures.append("_subtabs_from_messages did not read the captions out "
                        "of the host's build line: %r" % (caps,))
    if len(verds) != 1 or verds[0][0] != "PASS":
        failures.append("the VERDICT line was not seen: %r" % (verds,))
    if nt:
        failures.append("a complete pair of lines still produced a note: %r" % nt)
    caps2, mods2, _v2, _a2, nt2 = _subtabs_from_messages([MODS])
    if caps2 is not None or mods2 != 3 or not nt2:
        failures.append("the MODS-strip session was not distinguished: %r"
                        % ((caps2, mods2, nt2),))
    caps3, _m3, _v3, att3, nt3 = _subtabs_from_messages(["something unrelated"])
    if caps3 is not None or att3 is not None or "native subtabs" not in nt3:
        failures.append("a log with no subtab line did not refuse by name: %r"
                        % nt3)
    caps4, _m4, _v4, att4, nt4 = _subtabs_from_messages([ATT_NO])
    if att4 is not False or caps4 is not None or "REFUSED" not in nt4:
        failures.append("`build attempted ... returned false` -- a build that "
                        "RAN AND REFUSED -- was not distinguished from a flag "
                        "that was off: %r" % ((att4, nt4),))
    print("  captions=%r mods_n=%r verdicts=%d attempt=%r/%r"
          % (caps, mods2, len(verds), att, att4))

    # --- 16m. THE FLAG, resolved the way aowlhost.nim resolves it. ---------
    print("\n---- nativeTabsSubtabs: default-on, implied-on, off")
    import hostcfg as _hcfg
    for text, want in (('{"nativeTabs": true}', True),
                       ('{"nativeTabsSubtabs": false}', False),
                       ('{"nativeTabsSubtabs": true}', True),
                       ('{"nativeTabsSubtabs": false, '
                        '"settingsPostFxSubtab": true}', True)):
        on, why = _subtabs_flag_from_cfg(_hcfg, text)
        if on is not want:
            failures.append("nativeTabsSubtabs for %s read %s, want %s (%s)"
                            % (text, on, want, why))
    print("  absent->ON, false->OFF, true->ON, "
          "false+settingsPostFxSubtab->ON")

    # --- 17-19. THE CLONE COUNT COMES FROM THE HOST'S `built the` LINES. ---
    #     It used to come from `published N of M client-side settings page(s)`,
    #     which encoded the SUPERSEDED design of one top-row tab per mod. The
    #     native-tabs foundation adds exactly one clone per `defineTab`, so
    #     that assertion FAILED live tonight with `1 active clone(s), want 8`
    #     against a client that was behaving correctly. `published_pages` is
    #     kept -- the row-group check still uses it, and the future SUBTAB
    #     count is what it will measure.
    TABS = [("find Toggles", [_fixtures.fx("find-toggles-strip-with-clones")]),
            ("children 0x000002024b079ee0",
             [_fixtures.fx("children-toggle-strip")]),
            ("assert-active", [_fixtures.fx("assert-active-toggle-strip")])]
    CLONES_NAME = "top-row native tab clones"
    EIGHT = ["MOD%d" % i for i in range(8)]

    def c17(rep, _rp):
        assert_tab_count(rep, "X", EIGHT, True, "")
        if _verdicts(rep).get("top-row stock tab count") != PASS:
            return "4 active stock tabs (PostFx inactive by design) did not PASS"
        if _verdicts(rep).get(CLONES_NAME) != PASS:
            return "8 active clones against 8 `built the` lines did not PASS"
        row = [r for r in rep.rows if r[0] == CLONES_NAME][0]
        if "MOD0" not in row[3] or "GameToggleSpawner(Clone)" not in row[3]:
            return ("the detail names neither the host's tabs nor the clones "
                    "counted: %r" % row[3])
        return ""
    case("tab clones: 8 active, host built 8 tabs -> PASS", TABS, c17)

    def c18(rep, _rp):
        assert_tab_count(rep, "X", ["PROOF"], True, "")
        row = [r for r in rep.rows if r[0] == CLONES_NAME][0]
        if row[1] != FAIL:
            return ("8 clones against ONE `built the` line did not FAIL -- the "
                    "host's tab count is not driving the verdict")
        if "want 1" not in row[2] or "'PROOF'" not in row[2]:
            return "the expected count and its source are not stated: %r" % row[2]
        return ""
    case("control: host built 1 tab, 8 clones active -> FAIL", TABS, c18)

    # The measured corpus has no 2-clone strip, so this one is SHAPED.
    _p2, _ch2 = _fx_strip(_TAB_NAMES + ["GameToggleSpawner(Clone)"] * 2)
    TWO_CLONES = [("find Toggles", [_fx_find("Toggles", "0x0000021c00220000",
                                             "SettingsScreen")]),
                  ("children", [_ch2]),
                  ("assert-active",
                   [_fx_active_ptrs(_p2, [True, True, True, True, False,
                                          True, True])])]

    def c18b(rep, _rp):
        assert_tab_count(rep, "X", ["PROOF"], True, "")
        row = [r for r in rep.rows if r[0] == CLONES_NAME][0]
        if row[1] != FAIL:
            return "2 active clones against 1 built tab did not FAIL"
        if "2 active clone(s), want 1" not in row[2]:
            return "the counts were not both stated: %r" % row[2]
        return ""
    case("control: host built 1 tab, 2 clones active -> FAIL", TWO_CLONES, c18b)

    def c19(rep, _rp):
        assert_tab_count(rep, "X", [], True, "")
        row = [r for r in rep.rows if r[0] == CLONES_NAME][0]
        if row[1] != FAIL:
            return ("nativeTabs ON with ZERO `built the` lines reported %s; a "
                    "feature that is on and built nothing is a failure, and "
                    "0 == 0 must not pass vacuously" % row[1])
        if "built the" not in row[2]:
            return "the FAIL does not name the missing log line: %r" % row[2]
        return ""
    case("control: nativeTabs ON, 0 `built the` lines -> FAIL naming the line",
         TABS, c19)

    def c19b(rep, _rp):
        note = "the host log has no `nativeTabs is set` line"
        assert_tab_count(rep, "X", [], False, note)
        row = [r for r in rep.rows if r[0] == CLONES_NAME][0]
        if row[1] != INCONCLUSIVE:
            return ("nativeTabs OFF reported %s; with the feature off there is "
                    "no expected count and this must not be a pass" % row[1])
        if note not in row[2]:
            return "the INCONCLUSIVE does not carry the reason: %r" % row[2]
        return ""
    case("control: nativeTabs OFF -> INCONCLUSIVE with the reason", TABS, c19b)

    def c19c(rep, _rp):
        assert_tab_count(rep, "X", None, None, "the host log could not be read")
        v = _verdicts(rep).get(CLONES_NAME)
        if v != INCONCLUSIVE:
            return ("with no readable host log the clone check reported %s; it "
                    "must not fall back to a hardcoded want" % v)
        return ""
    case("control: host log unreadable -> INCONCLUSIVE, no fallback want",
         TABS, c19c)

    # --- 19d. the `built the` / flag regexes, against the host's own text. --
    print("\n---- native_tabs_built: the host's own lines")
    BUILT = ("native tabs: built the 'PROOF' tab -- a real "
             "UIAnimatedToggleSpawner in the STOCK ToggleGroup and a real "
             "cloned SettingsTab panel, emptied of its stock rows.")
    NOT_BUILT = ("native tabs: reaped 2 extra child(ren) from the 'PROOF' "
                 "panel clone")
    FLAG = ("nativeTabs is set: the host adds ONE proof tab to the settings "
            "screen, built from a real UIAnimatedToggleSpawner")
    m = _NT_BUILT_RE.search(BUILT)
    if not m or m.group("name") != "PROOF":
        failures.append("_NT_BUILT_RE does not read the host's emitted line %r"
                        % BUILT)
        print("  ** CASE FAILED: %s" % failures[-1])
    elif _NT_BUILT_RE.search(NOT_BUILT):
        failures.append("_NT_BUILT_RE matches `%s`, so another native-tabs log "
                        "line would inflate the expected clone count"
                        % NOT_BUILT)
        print("  ** CASE FAILED: %s" % failures[-1])
    elif not _NT_FLAG_RE.search(FLAG):
        failures.append("_NT_FLAG_RE does not read the flag line %r" % FLAG)
        print("  ** CASE FAILED: %s" % failures[-1])
    else:
        print("  case ok ('PROOF' read; the reaped line does not match; the "
              "flag line does)")

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

    # --- 21. THE 10:35 SHAPE: parked at the MAIN MENU, so the selector is
    #     GONE and `entergame.py --list` shows ZERO slots. That used to be read
    #     as "not ready yet", waited out for the full 120s and reported
    #     INCONCLUSIVE, which then marked every screen assertion NOT PERFORMED.
    #     The host log settles it. All three cases drive the real enter_game
    #     with its subprocesses and its log read injected -- no client, no log.
    LIST_NO_SLOTS = "Menu UI: looked under the selector\n"
    LIST_TWO_SLOTS = (
        "  0x0000021c00120000  CharacterSlotView            title='PVE'\n"
        "  0x0000021c00121000  CharacterSlotView            title='PVP'\n")
    PROOF = ("[0:00:47.203] info   skip mode screen: MenuScreen::Show fired "
             "(uihooks site 2, epoch 1) -- the main menu is up")

    def _eg(list_out, proof, pnote="", rc=0):
        calls = {"list": 0, "select": [], "proof": 0}

        def L():
            calls["list"] += 1
            return list_out

        def S(mode):
            calls["select"].append(mode)
            return rc, ""

        def P():
            calls["proof"] += 1
            return proof, pnote
        ok, note = enter_game(0.2, "X", _list=L, _select=S, _proof=P)
        return ok, note, calls

    print("\n---- mode selector: proof in the host log + ZERO slots -> PASS")
    ok, note, calls = _eg(LIST_NO_SLOTS, PROOF)
    if not ok:
        failures.append("zero slots WITH a menu proof line still failed: %s"
                        % note)
        print("  ** CASE FAILED: %s" % failures[-1])
    elif "already past (host logged MenuScreen::Show)" not in note:
        failures.append("zero slots + proof returned an unexpected note: %r"
                        % note)
        print("  ** CASE FAILED: %s" % failures[-1])
    elif calls["select"]:
        failures.append("pressed a slot (%r) when there were none on screen"
                        % calls["select"])
        print("  ** CASE FAILED: %s" % failures[-1])
    else:
        print("  case ok (%r)" % _oneline(note, 80))

    print("---- mode selector: NO proof + ZERO slots -> INCONCLUSIVE (unchanged)")
    ok, note, calls = _eg(LIST_NO_SLOTS, None,
                          "this boot's host log has no MenuScreen::Show proof "
                          "line (none of 4 signatures)")
    if ok:
        failures.append("reported past the selector with neither a slot nor a "
                        "menu proof line -- that is a check that cannot fail")
        print("  ** CASE FAILED: %s" % failures[-1])
    elif "could not get past the mode selector" not in note or (
            "no MenuScreen::Show proof line" not in note):
        failures.append("the no-proof refusal does not say what was looked "
                        "at: %r" % note)
        print("  ** CASE FAILED: %s" % failures[-1])
    elif calls["proof"] < 1:
        failures.append("never consulted the host log at all")
        print("  ** CASE FAILED: %s" % failures[-1])
    else:
        print("  case ok (%r)" % _oneline(note, 90))

    print("---- control: slots WITH titles -> the press path still runs")
    ok, note, calls = _eg(LIST_TWO_SLOTS, PROOF)
    if not ok or calls["select"] != ["PVE"]:
        failures.append("the press path did not run for a visible selector: "
                        "ok=%r note=%r select=%r" % (ok, note, calls["select"]))
        print("  ** CASE FAILED: %s" % failures[-1])
    elif calls["proof"]:
        failures.append("consulted the menu proof while real slots were on "
                        "screen; a stale proof must never skip a live selector")
        print("  ** CASE FAILED: %s" % failures[-1])
    else:
        print("  case ok (%r)" % note)

    print("---- mode selector: a proof from a PREVIOUS boot does not count")
    pre, saw = menu_proof_from_lines(
        [PROOF, HOST_BANNER_PREFIX + "0.1.0", "[0:00:03] info  IL2CPP is up"])
    post, _ = menu_proof_from_lines([HOST_BANNER_PREFIX + "0.1.0", PROOF])
    if pre is not None or not saw:
        failures.append("a menu proof BEFORE the last host banner certified "
                        "this boot: %r" % pre)
        print("  ** CASE FAILED: %s" % failures[-1])
    elif post is None:
        failures.append("a menu proof after the banner was not seen")
        print("  ** CASE FAILED: %s" % failures[-1])
    else:
        print("  case ok (old proof discarded, new proof kept)")

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
