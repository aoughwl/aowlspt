#!/usr/bin/env python3
"""ui.py -- a reusable NAVIGATION layer over the live inspector.

WHY THIS EXISTS
---------------
`tools/inspector.py` gives you raw verbs, and every one of them keys off the
OBJECT NAME. Object names lie: `CharacterSlotView_pvp` displays "PvE" (fact
#7). So the only honest way to point at a control is the text a PERSON sees --
and the inspector has no verb for that. Consequently every session re-walks
`children` one level at a time to reach a screen it reached yesterday.

This module supplies the two missing pieces:

  1. FIND BY DISPLAYED TEXT  -- `find_text("DEPLOY")`
  2. A CACHED SCREEN MAP     -- name -> path-of-names, re-verified before use

plus the verbs a caller actually wants (`screen`, `dump_screen`, `click_text`,
`wait_for_screen`, `wait_until`).

TWO RULES THIS MODULE ENFORCES, both learned the expensive way
--------------------------------------------------------------
* A press goes through `EFT.UI.DefaultUIButton.OnClick` (`press`). It is NOT a
  `UnityEngine.UI.Button` (fact #1), and `ButtonFeedback::OnPointerClick`
  plays the click SOUND and presses nothing (fact #5) -- a perfect false
  positive. `click_text` resolves a DefaultUIButton and verifies an EFFECT.
* Nothing here is force-activated. Screens are driven by pressing what a
  player presses, because a GameObject you SetActive yourself is a screen the
  game does not think is open.

EVERY FAILURE PATH ANNOUNCES ITSELF. A search reports how much of the tree it
covered, and `Truncated` (the tree hit its node cap) is a DISTINCT outcome
from "absent" -- exactly as the inspector's own
"searched EXHAUSTIVELY" / "STOPPED EARLY" distinction.

  python tools/ui.py screen
  python tools/ui.py dump "Matchmaker Offline Raid Screen"
  python tools/ui.py findtext DEPLOY
  python tools/ui.py click DEPLOY
  python tools/ui.py roots
"""
import json
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from inspector import run_batch, Timeout  # noqa: E402

LIVE = os.environ.get("AOWLSPT_LIVE", r"D:\Aowlspt\aowlspt")
CACHE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "uimap.json")

# The tree walker's own ceiling. The host prints "complete." when it printed
# the WHOLE subtree; anything else means it stopped, and we propagate that.
TREE_NODE_CAP = 3000

_ROOT = re.compile(r'\[\$r(\d+)\] transform=(0x[0-9a-fA-F]+)\s+go=(0x[0-9a-fA-F]+)'
                   r'\s+\(\$rgo\d+\)\s+name="([^"]*)"')
_CHILD = re.compile(r'\[(\d+)\] transform=(0x[0-9a-fA-F]+) \(\$c\d+\)\s+'
                    r'go=(0x[0-9a-fA-F]+) \(\$g\d+\)\s+name="([^"]*)"')
# NOTE the trailing group is OPTIONAL: `tree` prints "(N child)" only for
# nodes that HAVE children, so a regex that requires it silently drops every
# leaf -- which is to say, every label. That bug made a 128-node subtree
# parse as 68 nodes and read as a complete answer.
_TREE = re.compile(r'^(\s*)\+?\s*"([^"]*)"\s+(0x[0-9a-fA-F]+)\s*(?:\((\d+) child\))?\s*$')
_TEXT = re.compile(r'text = "(.*)"')
_I32 = re.compile(r'-> i32 (-?\d+)')
_PTR = re.compile(r'-> ptr (0x[0-9a-fA-F]+)')
# `parent` prints transform=, klass=, name=, go= on ONE line. A naive
# findall-for-hex over that line returns the KLASS as the second pointer, and
# GetComponent on a klass pointer FAULTS -- burning one of the eight faults
# the inspector allows itself before switching off for the session. Parse the
# fields by name, never by position.
_PARENT = re.compile(r'\[(\d+)\] transform=(0x[0-9a-fA-F]+) klass=0x[0-9a-fA-F]+ '
                     r'name="([^"]*)" go=(0x[0-9a-fA-F]+) activeSelf=(\w+)')

# Text-bearing component types, in the order worth trying. Unity's
# GetComponent(string) matches by SHORT type name and DOES match base types,
# so TMP_Text catches both TextMeshProUGUI and TextMeshPro.
TEXT_COMPONENTS = ("TextMeshProUGUI", "TMP_Text", "Text")
# Pressable component types, MOST SPECIFIC FIRST, each with the verb that
# actually actuates it. Getting this mapping wrong is not a style question:
#
#  * DefaultUIButton is NOT a UnityEngine.UI.Button (fact #1). Unity's press
#    path cannot touch one; its real event is OnClick at +0x120, which is what
#    the inspector's `press` fires.
#  * AnimatedToggle IS a UnityEngine.UI.Toggle (fact #9) with m_IsOn at +0x120
#    -- the SAME offset DefaultUIButton keeps its UnityEvent at. So `press` on
#    a toggle would invoke a BOOL as a UnityEvent. It is actuated by calling
#    Toggle::set_isOn instead, the route the open-settings recipe proved.
#  * Never ButtonFeedback: OnPointerClick plays the click SOUND and presses
#    nothing (fact #5). It is the sound layer, and the best false positive in
#    this codebase.
TOGGLE_SET_ISON_RVA = "0x55ba430"      # UnityEngine.UI.Toggle::set_isOn(bool)
BUTTON_COMPONENTS = ("DefaultUIButton", "SimpleStateButton", "AnimatedToggle",
                     "Button")


class UiError(Exception):
    pass


# --------------------------------------------------------------------------
# scope -- the world these measurements are true in
# --------------------------------------------------------------------------

def scope_key():
    """A key that CHANGES when the game build changes.

    A cached UI path that silently points at the wrong node is worse than no
    cache at all, so the cache is stamped with this and a mismatch discards
    the whole file rather than trusting one entry of it. Same idea as the fact
    store's scope, deliberately: size+mtime of GameAssembly.dll is enough to
    catch a Tarkov update, and cheap enough to compute on every call.
    """
    parts = []
    for p in (os.path.join(os.path.dirname(LIVE), "EscapeFromTarkov_Data",
                           "il2cpp_data", "Metadata", "global-metadata.dat"),
              os.path.join(os.path.dirname(LIVE), "GameAssembly.dll")):
        try:
            st = os.stat(p)
            parts.append("%s:%d:%d" % (os.path.basename(p), st.st_size,
                                       int(st.st_mtime)))
        except OSError:
            parts.append("%s:absent" % os.path.basename(p))
    return "|".join(parts)


# --------------------------------------------------------------------------
# primitives -- thin, parsed wrappers on the inspector verbs
# --------------------------------------------------------------------------

def _run(cmds, timeout=45, write=False, tries=3):
    """run_batch with a RETRY, because the host drops batches it has read.

    Not a size problem and not a hypothesis: the host log shows
    `lastRead=1485B lastKnown=1485B pending=0` -- it consumed a 1.4KB batch --
    while simultaneously warning "no batch queued for 55s". A 1.4KB batch is
    nowhere near either measured cap, so the channel loses work
    non-deterministically and the only symptom is the caller's timeout.

    A retry writes a NEW serial, which is what actually re-arms the poll. This
    is a WORKAROUND for a host bug, and it is deliberately noisy about it on
    stderr so the bug does not become invisible.
    """
    last = None
    for i in range(tries):
        try:
            return run_batch(cmds, timeout=timeout, write=write)
        except Timeout as e:
            last = e
            # `tries - 1` here printed "retry 3/2" -- past the tool's own stated
            # limit, so the message contradicted itself and made the retry bound
            # look broken. The bound was right; the denominator was wrong.
            sys.stderr.write("  (inspector dropped a %d-command batch; "
                             "retry %d/%d)\n" % (len(cmds), i + 1, tries))
            sys.stderr.flush()
    # Before giving up, say WHICH failure this is. A wedged host (a batch whose
    # `done` never advances) reports itself as "no batch queued", which is the
    # OPPOSITE of the truth and sent a whole session down the wrong path on
    # 2026-08-31. channel_wedged() reads the host's own counters instead.
    w = wedge_verdict()
    if w:
        sys.stderr.write("  %s\n" % w)
        sys.stderr.flush()
        raise UiError("the inspector channel is WEDGED, not idle. " + w)
    raise last


# --------------------------------------------------------------------------
# wedge detection -- the host's watchdog line, read honestly
# --------------------------------------------------------------------------

# `done` IS NOT THE WEDGE PREDICATE. This is the correction that matters, and
# the first version of this function got it exactly wrong.
#
# MEASURED, host/Aowlspt.Host.Il2Cpp/inspect.nim:7014 -- the DELIVERY path sets
# `gInspBatchDone = -1` itself, immediately after `inspWriteOut()`:
#
#     if done >= 0 and cInspHave() == 0'i32 and gInspOut.len > 0:
#       inspWriteOut()
#       ...
#       gInspBatchDone = -1          # <-- cleared ON SUCCESS
#
# So `done=-1` is the NORMAL, HEALTHY state of a channel that has delivered
# everything it was asked for. `done` is a one-shot HANDSHAKE, not a high-water
# mark, and the old predicate `done < batch` therefore reported WEDGED for every
# healthy idle channel -- a false positive on the happy path, which is the same
# confidently-wrong-answer class this whole task was about.
#
# The right signals are `delivered` (a HISTORY, monotonic) and `running` (the
# batch Unity's thread has claimed). The host on `fix-inspector-wedge`
# (162d3b8) prints both, and chooses its own three-state headline from them:
#
#   live inspector: WEDGED -- batch 9 was claimed by Unity's thread 130s ago
#   and has NOT completed; it is stuck at command 12 of 58: tree $r3 -- the
#   rider IS dispatching (N fires). polls=.. batch=9 delivered=8 running=9
#   done(handshake,cleared-on-delivery)=-1 suspended=.. abandons=.. inFlight=..
#
# THREE OUTCOMES, and the third is the one that keeps this honest: a host that
# predates 162d3b8 prints no `delivered=`/`running=` at all, and from the old
# fields the wedge is genuinely UNDECIDABLE. That case reports UNKNOWN and says
# the deployed host is too old to tell -- it must never read as healthy.
_WATCHDOG = re.compile(r"live inspector: (?P<head>.*?) -- the rider IS "
                       r"dispatching.*?batch=(?P<batch>-?\d+)"
                       r"(?:\s+delivered=(?P<delivered>-?\d+))?"
                       r"(?:\s+running=(?P<running>-?\d+))?")
# The pre-162d3b8 shape, kept ONLY so it can be recognised and refused.
_WATCHDOG_OLD = re.compile(r"live inspector: no batch queued for (\d+)s.*?"
                           r"batch=(-?\d+)\s+done=(-?\d+)")


def channel_verdict(log_path=None, text=None):
    """('WEDGED'|'HEALTHY'|'UNKNOWN', sentence) from the host's own counters.

    Never collapsed to a bool and never guessed. UNKNOWN covers both "there is
    no watchdog line to read" and "the deployed host is too old to say", and
    neither is a clean bill of health.
    """
    if text is None:
        log_path = log_path or os.path.join(LIVE, "aowlspt-host.log")
        try:
            with open(log_path, "rb") as f:
                # Tail only. The host log is written by the LIVE client and can
                # be tens of MB; never read the whole thing (CLAUDE.md 8).
                f.seek(0, os.SEEK_END)
                f.seek(max(0, f.tell() - 262144))
                text = f.read().decode("utf-8", "replace")
        except OSError:
            return ("UNKNOWN", None)

    last = None
    for m in _WATCHDOG.finditer(text):
        last = m
    if last is None:
        if _WATCHDOG_OLD.search(text):
            return ("UNKNOWN",
                    "the deployed host predates fix-inspector-wedge (162d3b8): "
                    "its watchdog prints no `delivered=`/`running=`, and from "
                    "`done` alone the wedge is UNDECIDABLE -- `done=-1` is the "
                    "NORMAL state of a healthy delivered channel, because the "
                    "delivery path clears it (inspect.nim:7014). NOT CHECKED.")
        return ("UNKNOWN", None)

    head = last.group("head") or ""
    delivered = last.group("delivered")
    running = last.group("running")

    if delivered is None or running is None:
        return ("UNKNOWN",
                "the host's watchdog line carries no `delivered=`/`running=` "
                "(pre-162d3b8 build), so the wedge is UNDECIDABLE from it. "
                "NOT CHECKED. The host said: %s" % head[:200])

    delivered, running = int(delivered), int(running)
    # The host already decided, from the same two fields, and says so in its
    # headline. Prefer ITS words -- they name the stuck command, which no
    # amount of counter-parsing here could recover.
    if head.startswith("WEDGED"):
        return ("WEDGED",
                "WEDGED (the host says so itself): %s Nothing shell-side can "
                "unwedge this." % head)
    if running >= 0 and delivered < running:
        return ("WEDGED",
                "WEDGED: batch %d was claimed by Unity's thread and delivered "
                "has not caught up (delivered=%d running=%d), so every later "
                "batch is being ignored. Nothing shell-side can unwedge this: "
                "the host must abandon the batch or be restarted."
                % (running, delivered, running))
    return ("HEALTHY", head[:300] or None)


def wedge_verdict(log_path=None, text=None):
    """The WEDGED sentence, or None. Thin wrapper over channel_verdict().

    Deliberately returns None for BOTH 'healthy' and 'unknown': its callers use
    it to enrich an error message, and asserting a wedge we did not measure
    would be the same defect in the other direction. Anything that needs to
    tell those two apart must call channel_verdict().
    """
    state, note = channel_verdict(log_path, text)
    return note if state == "WEDGED" else None


def roots(timeout=60):
    """Every scene root: name -> {"t": transform, "go": gameobject}.

    `roots` is the only way in. The live UI is in DontDestroyOnLoad, which
    SceneManager does not enumerate, so every listed scene truthfully reports
    rootCount=0 and a `find` without a root reaches nothing.
    """
    out = _run(["roots"], timeout=timeout)
    got = {}
    for m in _ROOT.finditer(out):
        got[m.group(4)] = {"t": m.group(2), "go": m.group(3)}
    if not got:
        raise UiError("`roots` returned no scene roots. The host answered:\n" + out)
    return got


def children(ptr, timeout=40):
    """Direct children as [{"t","go","name"}].

    The GameObject is read out, never computed. It is USUALLY transform-0x20
    on this build and sometimes is not (three of the 28 menu screens differ),
    so computing it would be right 90% of the time -- the worst possible
    failure rate for a pointer.
    """
    out = _run(["children %s" % ptr], timeout=timeout)
    return [{"t": m.group(2), "go": m.group(3), "name": m.group(4)}
            for m in _CHILD.finditer(out)]


def tree(ptr, depth=4, timeout=90):
    """The subtree as a flat list of {"t","name","path","depth","nchild"}.

    Returns (nodes, complete). `complete` is False when the host stopped at
    its node cap -- and a False there is NOT proof that a name or a label is
    absent. Callers must propagate that distinction; this module never
    collapses the two.
    """
    out = _run(["tree %s %d" % (ptr, depth)], timeout=timeout)
    nodes, stack = [], []
    for line in out.splitlines():
        m = _TREE.match(line.rstrip())
        if not m:
            continue
        indent = len(m.group(1))
        name, p = m.group(2), m.group(3)
        nch = int(m.group(4) or 0)
        while stack and stack[-1][0] >= indent:
            stack.pop()
        path = [s[1] for s in stack] + [name]
        stack.append((indent, name))
        nodes.append({"t": p, "name": name, "path": path,
                      "depth": len(path) - 1, "nchild": nch})
    # "complete." vs "STOPPED EARLY on a cap" -- the host says which,
    # and the difference is the whole point. `tree` stops at 128 LINES
    # despite advertising "max 3000 nodes" in its own header, so this
    # goes False far more often than the header suggests.
    complete = "complete." in out and "STOPPED EARLY" not in out
    if not nodes:
        raise UiError("`tree %s` produced no nodes. Host said:\n%s" % (ptr, out))
    return nodes, complete


def walk(ptr, budget=4000, timeout=60, root_name="?", visible_only=False):
    """FULL subtree enumeration by BFS over `children`. (nodes, complete).

    This exists because `tree` cannot do it. `tree` advertises "max 3000
    nodes" in its own header and then stops after 128 PRINTED LINES -- so on
    any real screen it truncates, and a caller that trusted it would conclude
    a label is absent when the walk simply stopped. Measured: Common UI at
    depth 4 prints "128 node(s) printed -- STOPPED EARLY on a cap".

    `children` has no such limit and additionally yields the GameObject
    pointer, which `tree` does not print and which must never be computed from
    the transform (it is transform-0x20 for most nodes and not for others).

    One command per node, ~125 per batch, ~0.3s a batch: a 2000-node screen
    enumerates in a few seconds. Each block is attributed to the parent the
    HOST echoed on its own `> children 0x...` line, so a fault mid-batch
    cannot reparent the nodes that follow it.

    `complete` is False only when `budget` was exhausted with frontier left --
    and then an empty result is NOT evidence of absence.
    """
    root = {"t": ptr, "go": None, "name": root_name, "path": [root_name]}
    nodes = [root]
    by_ptr = {ptr: root}
    frontier = [ptr]
    complete = True
    while frontier:
        if len(nodes) >= budget:
            complete = False
            break
        cmds = ["children %s" % p for p in frontier]
        nxt = []
        for out in batched(cmds, timeout=timeout, start=40):
            cur = None
            for line in out.splitlines():
                mp = re.match(r'\s*> children (0x[0-9a-fA-F]+)', line)
                if mp:
                    cur = by_ptr.get(mp.group(1))
                    continue
                if cur is None:
                    continue
                mc = _CHILD.search(line)
                if not mc:
                    continue
                kid = {"t": mc.group(2), "go": mc.group(3), "name": mc.group(4),
                       "path": cur["path"] + [mc.group(4)]}
                kid["depth"] = len(kid["path"]) - 1
                if kid["t"] in by_ptr:
                    continue
                by_ptr[kid["t"]] = kid
                nodes.append(kid)
                nxt.append(kid["t"])
        if visible_only and nxt:
            # An INACTIVE node hides its whole subtree, so not descending into
            # one is both a big pruning win and the correct meaning of "what
            # is on screen". Menu UI is ~4,600 nodes; the visible slice of it
            # is a small fraction of that.
            #
            # activeInHierarchy is asked of the GAMEOBJECT. Asking a Transform
            # does not fail -- `call` does not type-check pointer arguments --
            # it returns a number read off the wrong object, which is exactly
            # how an earlier script reported "still active" for a press that
            # had visibly worked.
            st = actives([by_ptr[p]["go"] for p in nxt], timeout=timeout)
            keep = []
            for p, a in zip(nxt, st):
                by_ptr[p]["active"] = a
                if a:
                    keep.append(p)
                elif a is None:
                    # Could not tell. Say so on the node rather than silently
                    # pruning it, and do not descend -- but the caller can see
                    # that this branch was skipped for lack of an answer.
                    by_ptr[p]["unknown_active"] = True
            nxt = keep
        frontier = nxt
    return nodes, complete


def go_of(ptr, timeout=40):
    """Transform -> GameObject, by calling Component::get_gameObject.

    Necessary because GameObject methods (get_activeInHierarchy) silently
    accept a Transform and return a number read off the wrong object. `call`
    does not type-check its pointer arguments; that is how an earlier script
    reported "still active" for a press that had visibly worked.
    """
    out = _run(["call name:Component::get_gameObject p_p %s" % ptr],
                    timeout=timeout, write=True)
    m = _PTR.search(out)
    return m.group(1) if m else None


def is_active(go, timeout=40):
    """GameObject.activeInHierarchy: True / False / None (could not tell)."""
    out = _run(["call name:get_activeInHierarchy i_p %s" % go],
                    timeout=timeout, write=True)
    m = _I32.findall(out)
    return None if not m else bool(int(m[-1]))


def actives(gos, timeout=60):
    """activeInHierarchy for MANY GameObjects, chunked. -> [True/False/None].

    Batching is what makes visibility cheap: ~60 answers per round trip at
    0.3s, so asking about 28 screens costs one trip rather than 28.

    Each answer is tied to an `echo UIQ<n>` marker rather than to output
    order, so a call that faults in the middle of a batch cannot shift every
    subsequent result onto the wrong object. None means "no answer for this
    one" and stays None -- it is never rounded down to False.
    """
    cmds = []
    for i, g in enumerate(gos):
        cmds.append("echo UIQ%d" % i)
        cmds.append("call name:get_activeInHierarchy i_p %s" % g)
    res = [None] * len(gos)
    for out in batched(cmds, timeout=timeout, write=True, per=2, start=60):
        cur = None
        for line in out.splitlines():
            mk = re.match(r'\s*UIQ(\d+)\s*$', line)
            if mk:
                cur = int(mk.group(1))
                continue
            if cur is not None:
                mv = _I32.search(line)
                if mv:
                    res[cur] = bool(int(mv.group(1)))
                    cur = None
    return res


# --------------------------------------------------------------------------
# 1. FIND BY DISPLAYED TEXT -- the verb the inspector does not have
# --------------------------------------------------------------------------

# TWO MEASURED CEILINGS, and both fail SILENTLY -- the worst shape a limit
# can have. Over either one the host READS the command file and then never
# executes it: its log says "no batch queued" while its own counters show
# `lastRead=3529B lastKnown=3529B pending=0`, i.e. it consumed the batch and
# dropped it on the floor. The caller just times out.
#
#   * command count -- 127 commands answer in 0.15s, 128 hang. Hard cliff.
#   * OUTPUT volume  -- 40 `children` commands (491 output lines) answer in
#     0.6s; 60 (~740 lines) are dropped. So a batch of cheap commands can be
#     long and a batch of chatty ones cannot, and the input size tells you
#     nothing about which you have.
#
# Since output volume is not knowable in advance, this does not guess: it
# starts optimistic and HALVES on a timeout. Self-tuning beats a hard-coded
# constant that is wrong for the next verb someone adds.
MAX_CMDS = 120


def batched(cmds, timeout=45, write=False, per=1, start=None, on_gap=None):
    """Run commands in chunks that survive the host's silent batch caps AND
    its silent mid-batch truncation. Yields each chunk's output.

    THE TRUNCATION IS THE DANGEROUS PART (fact #19). A fault caught by the
    host's guard unwinds the ENTIRE guarded body, so every command after the
    faulting one in that batch never runs -- and the output simply stops. To a
    parser that reads what came back, a batch cut short at command 12 of 80 is
    indistinguishable from 80 commands that all found nothing. That would make
    a screen map QUIETLY INCOMPLETE, which is the precise failure this module
    exists to prevent.

    So every chunk is RECONCILED: the host echoes each command it actually
    ran as a `> ...` line, and if it echoed fewer than we sent, the batch was
    cut short. We resume from exactly where it stopped and re-run the
    remainder in smaller pieces, announcing it. A short batch is never
    silently accepted as a complete answer.

    `per` keeps a logical group (component+label for one node) from being
    split across batches, which would strand a $comp lookup from its read.
    """
    step = start or MAX_CMDS
    i = 0
    while i < len(cmds):
        n = min(step, len(cmds) - i)
        n -= n % per
        n = max(n, per)
        try:
            out = _run(cmds[i:i + n], timeout=timeout, write=write)
        except (Timeout, UiError):
            if n <= per:
                raise UiError(
                    "the host dropped even a minimal %d-command batch. Not a "
                    "size problem -- check the client is alive and the "
                    "liveInspector flag is on. First command: %s"
                    % (n, cmds[i]))
            step = max(per, n // 2)
            continue
        # Reconcile: how many of the commands we sent did the host echo back?
        # run_batch strips its own sentinel echo, but `allow write` is echoed.
        ran = len(re.findall(r'^\s*> ', out, re.M)) - (1 if write else 0)
        yield out
        if ran >= n or ran <= 0:
            i += n
            if ran <= 0:
                sys.stderr.write(
                    "  !! the host echoed NONE of a %d-command batch -- its "
                    "output cannot be reconciled and those nodes are being "
                    "reported as unanswered, not as empty.\n" % n)
                if on_gap:
                    on_gap(cmds[i - n:i])
            continue
        # Cut short. Everything after `ran` never executed.
        sys.stderr.write(
            "  !! batch TRUNCATED: sent %d commands, the host ran %d. A caught "
            "fault unwinds the whole guarded body (fact #19), so the rest "
            "never ran. Resuming at command %d in smaller pieces -- NOT "
            "treating the missing answers as empty.\n" % (n, ran, i + ran))
        i += max(per, (ran // per) * per)
        step = max(per, min(step, 8 * per))
    return


def labels_of(ptrs, timeout=60, components=TEXT_COMPONENTS):
    """The DISPLAYED text of many transforms -> {transform: text}.

    THIS IS THE VERB THE INSPECTOR DOES NOT HAVE. Everything else in the file
    is plumbing around it.

    For each node we GetComponent a text-bearing type and read TMP_Text.m_text
    off the result. Traps handled here, each one measured:

    * `label` on a TRANSFORM reports `text = ""`. That is not an answer, it is
      the wrong object -- so we ALWAYS go through the component, and a lookup
      that returned NULL is never read.
    * Unity's GetComponent(string) matches BASE type names, so "TMP_Text"
      catches TextMeshProUGUI and TextMeshPro in ONE pass (verified against
      the known AlphaLabel, which reads "1.1.0.1.46777 | PvE" through either
      name). "Text" is a genuinely different component and gets its own pass
      over whatever is still unlabelled -- it returns NULL on a TMP node.
    * Results are keyed off the pointer the HOST echoed back on its own
      `> component 0x... ` line, not off our loop index. A value therefore
      cannot drift onto the wrong node even if a lookup faults mid-batch --
      which is how an earlier session got a complete and entirely fictional
      field map.

    Absence from the returned dict means "no text component here": a measured
    answer, not a failure.
    """
    found = {}
    for comp in components:
        todo = [p for p in ptrs if p not in found]
        if not todo:
            break
        cmds = []
        for p in todo:
            cmds += ["component %s %s" % (p, comp), "label $comp"]
        for out in batched(cmds, timeout=timeout, write=True, per=2, start=80):
            cur = None
            for line in out.splitlines():
                mc = re.match(r'\s*> component (0x[0-9a-fA-F]+)\s', line)
                if mc:
                    cur = mc.group(1)
                    continue
                if cur is None:
                    continue
                if "returned NULL" in line or "not readable" in line:
                    cur = None
                    continue
                mt = _TEXT.search(line)
                if mt:
                    if mt.group(1).strip():
                        found[cur] = mt.group(1)
                    cur = None
    return found


def find_text(text, root="Common UI", exact=False, budget=4000,
              subtree=None, visible_only=True, depth=None, node_cap=None):
    """Find every control whose DISPLAYED text matches.

    root    -- a scene-root NAME (from `roots`), or pass `subtree` to search
               under a pointer you already hold.
    exact   -- case-insensitive equality; default is a case-insensitive
               substring, because in-game labels carry padding and casing that
               nobody remembers correctly.

    Returns (matches, complete). Each match is
        {"t","text","name","path"}
    and `complete` is False when the tree walk hit its cap -- in which case an
    EMPTY match list is NOT evidence that the text is absent, and any caller
    that reports "not found" must say so.
    """
    if subtree is None:
        rs = roots()
        if root not in rs:
            raise UiError("no scene root named %r. Present: %s"
                          % (root, ", ".join(sorted(rs))))
        subtree = rs[root]["t"]
    nodes, complete = walk(subtree, budget=budget, root_name=root,
                           visible_only=visible_only)
    if node_cap:
        nodes = nodes[:node_cap]
    texts = labels_of([n["t"] for n in nodes])
    want = text.strip().lower()
    hits = []
    for n in nodes:
        t = texts.get(n["t"])
        if t is None:
            continue
        got = t.strip().lower()
        if (got == want) if exact else (want in got):
            hits.append({"t": n["t"], "text": t, "name": n["name"],
                         "path": n["path"]})
    return hits, complete


# --------------------------------------------------------------------------
# 2. THE SCREEN MAP + CACHE
# --------------------------------------------------------------------------

def _load_cache():
    try:
        with open(CACHE, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {"scope": scope_key(), "paths": {}}
    if data.get("scope") != scope_key():
        # The build moved. Do not try to salvage individual entries -- a path
        # that resolves but points somewhere else is the failure mode this
        # whole file exists to prevent.
        return {"scope": scope_key(), "paths": {}, "_was_stale": True}
    return data


def _save_cache(data):
    data.pop("_was_stale", None)
    data["scope"] = scope_key()
    with open(CACHE, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=1, sort_keys=True)


def cache_put(key, path):
    d = _load_cache()
    d["paths"][key] = path
    _save_cache(d)


def resolve_path(path, timeout=40):
    """Walk a path of NAMES from a scene root to a live pointer, verifying
    every hop. Returns {"t","go"} or None.

    VERIFICATION IS THE POINT. Pointers do not survive a restart, so the cache
    stores names; and a name that no longer exists at that level means the
    cached path is stale, which returns None so the caller re-derives. It
    never falls back to "something with a similar name".
    """
    rs = roots(timeout=timeout)
    if not path or path[0] not in rs:
        return None
    cur = {"t": rs[path[0]]["t"], "go": rs[path[0]]["go"]}
    for name in path[1:]:
        kids = children(cur["t"], timeout=timeout)
        nxt = [k for k in kids if k["name"] == name]
        if len(nxt) != 1:
            return None            # absent, or ambiguous -- both are stale
        cur = {"t": nxt[0]["t"], "go": nxt[0]["go"]}
    return cur


def cached_path(key, derive=None):
    """A cached path, VERIFIED, or re-derived via `derive()` and re-cached."""
    d = _load_cache()
    path = d["paths"].get(key)
    if path:
        hit = resolve_path(path)
        if hit:
            return hit, path, "cache"
        # Say it out loud. A silently-dropped cache entry is how a tool starts
        # lying about how fast it is.
        sys.stderr.write("cache MISS (stale): %s -> %s no longer resolves; "
                         "re-deriving.\n" % (key, "/".join(path)))
    if derive is None:
        return None, path, "stale"
    got = derive()
    if got:
        cache_put(key, got["path"])
        return {"t": got["t"], "go": got["go"]}, got["path"], "derived"
    return None, path, "absent"


def screens(root="Menu UI"):
    """Every screen under <root>/UI with its live active state.

    [{"name","t","go","active"}] -- one batch for the children, one for all
    the activeInHierarchy calls.
    """
    rs = roots()
    if root not in rs:
        raise UiError("no scene root named %r" % root)
    kids = children(rs[root]["t"])
    if len(kids) == 1 and kids[0]["name"] == "UI":
        kids = children(kids[0]["t"])
    st = actives([k["go"] for k in kids])
    return [{"name": k["name"], "t": k["t"], "go": k["go"], "active": a}
            for k, a in zip(kids, st)]


def screen(root="Menu UI"):
    """The names of the screens that are ACTIVE right now.

    Plural on purpose: this build routinely has an overlay active over a base
    screen, and returning "the" screen would be a confidently wrong answer.
    """
    return [s["name"] for s in screens(root) if s["active"]]


def dump_screen(name=None, root="Menu UI", visible_only=True, depth=None):
    """The labelled controls of a screen -- for DISCOVERY.

    Returns (rows, complete) where rows are {"text","name","path"}. This is
    the answer to "what can I press here", which previously required a
    hand-walk of `children` one level at a time.
    """
    ss = screens(root)
    if name is None:
        act = [s for s in ss if s["active"]]
        if not act:
            raise UiError("no active screen under %r -- nothing to dump. "
                          "Screens present: %d" % (root, len(ss)))
        target = act[-1]
    else:
        cand = [s for s in ss if s["name"] == name]
        if not cand:
            raise UiError("no screen named %r. Present: %s"
                          % (name, ", ".join(s["name"] for s in ss)))
        target = cand[0]
    nodes, complete = walk(target["t"], root_name=target["name"],
                           visible_only=visible_only)
    texts = labels_of([n["t"] for n in nodes])
    rows = [{"text": texts[n["t"]], "name": n["name"], "path": n["path"],
             "t": n["t"]}
            for n in nodes if n["t"] in texts]
    return rows, complete


# --------------------------------------------------------------------------
# 3. ACTING -- press what a player presses
# --------------------------------------------------------------------------

def ancestors(ptr, up=5, timeout=40):
    """The node and its parents as [{"t","go","name","activeSelf"}], nearest first."""
    out = _run(["parent %s %d" % (ptr, up)], timeout=timeout)
    return [{"t": m.group(2), "name": m.group(3), "go": m.group(4),
             "activeSelf": m.group(5) == "true"}
            for m in _PARENT.finditer(out)]


def button_for(ptr, up=5, timeout=40):
    """The pressable component at or above <ptr>: {"at","type","name"} or None.

    A label is a CHILD of its button far more often than it is the button --
    the main-menu PLAY control is `PlayButton`, and the text lives two levels
    down on `PlayButton/SizeLabel/Label` -- so this walks the parent chain.

    DefaultUIButton is tried first because that is what EFT actually uses:
    fact #1, it is NOT a UnityEngine.UI.Button, GetComponent("Button")
    returns NULL on one, and the Unity press path cannot touch it.
    """
    chain = ancestors(ptr, up=up, timeout=timeout)
    if not chain:
        return None
    for node in chain:
        for ctype in BUTTON_COMPONENTS:
            o = _run(["component %s %s" % (node["t"], ctype)],
                     timeout=timeout, write=True)
            # NULL is an ANSWER ("no such component here"); FAULTED is not,
            # and it costs one of the eight faults the inspector allows itself
            # before it switches off for the whole session -- so both are
            # skipped, but only NULL is unremarkable.
            if "GetComponent returned NULL" in o:
                continue
            if "FAULTED" in o:
                sys.stderr.write("  (component %s on %s FAULTED -- that burns "
                                 "one of the inspector's 8 faults)\n"
                                 % (ctype, node["name"]))
                continue
            return {"at": node["t"], "type": ctype, "name": node["name"],
                    "chain": [n["name"] for n in chain]}
    return None


def actuate(ptr, ctype="DefaultUIButton", timeout=60):
    """Actuate a control the way its OWN type is actuated. -> (ok, output).

    "returned without faulting" is NOT success -- it only means the handler
    did not crash. Every caller must still verify an EFFECT; that is what
    `click_text`'s `expect` predicate is for.
    """
    # An INACTIVE GameObject accepts the call, does not fault, and the game
    # ignores it -- so a bare "ok" here is a false positive. Measured live:
    # MenuScreen/RaidButtonsGroup/DisconnectButton persists into a raid while
    # inactive, and pressing it reported success twice while the client stayed
    # in the raid. Refuse by name instead of reporting a success that is not one.
    try:
        go = go_of(ptr)
        act = is_active(go) if go else None
    except Exception:
        go, act = None, None
    if act is False:
        return False, ("the control exists but its GameObject is INACTIVE "
                       "(%s) -- nothing was pressed. It is not the control on "
                       "screen; find the active one." % (go,))
    if act is None:
        # Unknown is not permission: say so, and let the caller decide.
        pass

    if ctype == "AnimatedToggle":
        cmds = ["component %s %s" % (ptr, ctype),
                "call rva:%s v_pb $comp 1" % TOGGLE_SET_ISON_RVA,
                "wait 300"]
    elif ctype == "Button":
        cmds = ["component %s %s" % (ptr, ctype), "click $comp", "wait 300"]
    else:
        cmds = ["component %s %s" % (ptr, ctype), "press $comp", "wait 300"]
    out = _run(cmds, timeout=timeout, write=True)
    ok = ("returned without faulting" in out) and "FAULTED" not in out
    return ok, out


def press(ptr, ctype="DefaultUIButton", timeout=60):
    """Back-compat alias for `actuate`."""
    return actuate(ptr, ctype=ctype, timeout=timeout)


def click_text(text, root="Common UI", exact=False, subtree=None,
               expect=None, settle=15.0, visible_only=True, depth=None):
    """Find a control by its DISPLAYED text, press it, and VERIFY an effect.

    expect -- a zero-arg predicate returning True once the click has visibly
              done something. Without it this returns "pressed, UNVERIFIED"
              and says so, because a handler that returns cleanly proves only
              that it did not crash.

    Returns (ok, message).
    """
    hits, complete = find_text(text, root=root, exact=exact,
                               subtree=subtree, visible_only=visible_only)
    if not hits:
        return False, ("no control DISPLAYS %r under %r%.0s. The tree "
                       "walk was %s -- %s"
                       % (text, root, -1,
                          "COMPLETE" if complete else "TRUNCATED at the node cap",
                          "so this is evidence of absence."
                          if complete else "so this is NOT evidence of absence; "
                          "raise depth or search a narrower subtree."))
    # PREFER AN EXACT MATCH when a substring search turned up several.
    if len(hits) > 1 and not exact:
        ex = [h for h in hits if h["text"].strip().lower() == text.strip().lower()]
        if ex:
            hits = ex

    # SEVERAL NODES CAN DISPLAY THE SAME TEXT, and only some are controls. On
    # the location screen "Factory" is on the map toggle AND on the info
    # panel's Location Name; on every screen a button's label is duplicated by
    # its parent SizeLabel. Taking the first hit picked the info panel -- a
    # label with no button above it -- and reported "nothing pressable", which
    # reads as "you cannot press Factory" and is simply wrong.
    #
    # So: walk the candidates and take the first that actually resolves to a
    # pressable component. Say how many were considered.
    btn, hit, rejected = None, None, []
    for cand in hits:
        b = button_for(cand["t"])
        if b:
            btn, hit = b, cand
            break
        rejected.append(cand)
    if btn is None:
        return False, ("%d node(s) display %r but NONE of them has a "
                       "pressable component on it or its 5 nearest ancestors "
                       "(tried %s). Nothing was pressed. Considered: %s"
                       % (len(hits), text, ", ".join(BUTTON_COMPONENTS),
                          "; ".join("/".join(h["path"][-3:]) for h in hits[:6])))
    extra = ("" if len(hits) == 1 else
             "  (%d node(s) displayed that text; actuated %s via %s%s)"
             % (len(hits), "/".join(hit["path"][-2:]), btn["name"],
                "" if not rejected else
                ", skipped %d unpressable label(s)" % len(rejected)))
    ok, out = actuate(btn["at"], btn["type"])
    if not ok:
        return False, ("actuated %s on %s and the call did not return "
                       "cleanly:\n%s" % (btn["type"], btn["at"], out[-600:]))
    if expect is None:
        return True, ("pressed %r via %s on %s%s -- UNVERIFIED: no `expect` "
                      "predicate was given, so this proves only that the "
                      "handler did not fault."
                      % (hit["text"], btn["type"], btn["at"], extra))
    if wait_until(expect, timeout=settle):
        return True, ("pressed %r via %s and VERIFIED the expected effect.%s"
                      % (hit["text"], btn["type"], extra))
    return False, ("pressed %r via %s on %s -- the handler ran without "
                   "faulting but the expected effect did NOT appear within "
                   "%gs. This is the false-positive shape: treat it as a "
                   "failure.%s" % (hit["text"], btn["type"], btn["at"],
                                   settle, extra))


# --------------------------------------------------------------------------
# waiting -- always on OBSERVED state, never on a duration
# --------------------------------------------------------------------------

def wait_until(pred, timeout=30.0, poll=1.0):
    """Poll a predicate until it is true. Returns True/False -- never sleeps
    a fixed duration and hopes, which is the habit this repo keeps paying
    for."""
    deadline = time.time() + timeout
    while True:
        try:
            if pred():
                return True
        except Timeout:
            pass
        if time.time() >= deadline:
            return False
        time.sleep(poll)


def wait_for_screen(name, timeout=60.0, root="Menu UI"):
    return wait_until(lambda: name in screen(root), timeout=timeout)


HOSTLOG = os.path.join(LIVE, "aowlspt-host.log")
_REGPLAYER = re.compile(r"botdiag: RegisterPlayer #(\d+)")


def register_player_count():
    """How many times EFT.GameWorld::RegisterPlayer has fired this session.

    THIS IS THE IN-RAID SIGNAL, and the choice is not arbitrary. The obvious
    candidate -- the inspector's `in-raid anchor slot` from `state` -- reads
    -1 WHILE A HUMAN IS DEMONSTRABLY INSIDE A RAID (measured; fact #51). That
    anchor binds by NAME, and by-name method/class resolution is dead on this
    build (fact #35: findMethod and findClass both hand back non-nil handles
    into unmapped memory). So it never binds, and anything gated on it reports
    "not in a raid" forever -- a false negative that looks exactly like truth.

    RegisterPlayer is bound by VERIFIED STATIC RVA and therefore actually
    fires: 18 registrations at the start of the raid a human just played, 29
    by the end. Counting its log lines is a POSITIVE signal -- something that
    was seen to happen -- rather than a field read that may only be unbound.

    Returns None if the counter cannot be read at all (log absent, or the
    `botDiag` host flag is off so the line is never emitted). None means
    UNKNOWN and callers must say "unknown", never "false".
    """
    try:
        with open(HOSTLOG, "rb") as f:
            blob = f.read().decode("utf-8", "replace")
    except OSError:
        return None
    hits = _REGPLAYER.findall(blob)
    if not hits:
        # Distinguish "no raid yet" from "the diagnostic is switched off".
        # Without botDiag this line never appears and a 0 would be a lie.
        return 0 if "botdiag:" in blob else None
    return int(hits[-1])


def raid_started(baseline, timeout=180.0, poll=2.0):
    """Wait for NEW RegisterPlayer activity above `baseline`. True/False.

    Take the baseline BEFORE pressing anything: the counter is cumulative for
    the host's whole session, so its absolute value proves nothing about the
    raid you are trying to enter.
    """
    return wait_until(lambda: (register_player_count() or 0) > (baseline or 0),
                      timeout=timeout, poll=poll)


def host_phase(path=None, tail_bytes=262144):
    """The newest `raid phase = X` the host published, or None.

    Reads only the last `tail_bytes` of the host log (it is multi-MB and a
    measured token bomb; the phase line repeats every 5s so the tail always
    holds one when the host is alive). None means the host has not published
    a phase in that window -- an honest "not known", never "menu".
    """
    import os as _os
    p = path or _os.path.join(
        _os.environ.get("AOWLSPT_LIVE", r"D:\Aowlspt\aowlspt"), "aowlspt-host.log")
    try:
        size = _os.path.getsize(p)
        with open(p, "rb") as f:
            f.seek(max(0, size - tail_bytes))
            data = f.read().decode("utf-8", "replace")
    except OSError:
        return None
    last = None
    for m in re.finditer(r"raid phase = ([A-Z]+)", data):
        last = m.group(1)
    return last


def in_raid(root="Menu UI"):
    """True / False / None -- and None is a REAL, reportable answer.

    Built only from POSITIVELY-OBSERVED signals:

      * the `Game Scene` scene root being ACTIVE is positive evidence of a
        raid; `Menu UI` being active with `Game Scene` inactive is positive
        evidence of the menu. Both come from GameObject.activeInHierarchy on
        roots that `roots` enumerated, so nothing here depends on by-name
        method or class resolution (dead on this build, fact #35).

    WHAT THIS DELIBERATELY DOES NOT USE, and why:

      * the inspector's `in-raid anchor slot` from `state`. It reads -1 while
        a human is demonstrably inside a raid (fact #51). It binds by name, so
        it never binds. A false negative that looks exactly like truth.
      * the cumulative `botdiag: RegisterPlayer` counter. It is a session
        total that never decreases, so after a raid ENDS it still says a raid
        began -- which is precisely the wrong answer this function returned
        the first time it was written. RegisterPlayer is the right signal for
        the raid-entry TRANSITION (see `raid_started`) and the wrong one for
        "am I in a raid now".

    When neither root speaks, this returns None. On this build a field that
    reads zero or null is NOT evidence of absence -- it may only mean whatever
    populates it never bound -- so callers must print "unknown", never
    "false".
    """
    # FIRST: the host's own published phase. `raidphase.nim` latches
    # `raid phase = DEPLOYED` on the TRUE deploy signal
    # (SpatialAudioSystem::AfterGameStarted inside GameWorld::OnGameStarted)
    # and re-publishes every 5s, off the game thread, in the host log. That is
    # positive evidence of a raid that costs no inspector round trip and
    # cannot stall a loading main thread. Measured 2026-09-01: the roots-based
    # check below returned None TWICE for a client demonstrably standing in a
    # Woods raid, so exitraid refused to act -- "I could not look" for an
    # answer the host was printing every 5 seconds.
    ph = host_phase()
    if ph in ("DEPLOYED", "LOADING"):
        return True
    if ph == "MENU":
        return False
    try:
        rs = roots()
    except (UiError, Timeout):
        return None
    names = ["Game Scene", root]
    gos = [rs[n]["go"] for n in names if n in rs]
    if not gos:
        return None
    st = dict(zip([n for n in names if n in rs], actives(gos)))
    if st.get("Game Scene") is True:
        return True
    if st.get("Game Scene") is False and st.get(root) is True:
        return False
    return None


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def _main(argv):
    if not argv:
        print(__doc__)
        return 0
    cmd, rest = argv[0], argv[1:]
    try:
        if cmd == "roots":
            for n, v in roots().items():
                print("  %-34s t=%s go=%s" % (n, v["t"], v["go"]))
        elif cmd == "screen":
            act = screen()
            print("active: " + (", ".join(act) if act else
                                "<none under Menu UI/UI>"))
        elif cmd == "screens":
            for s in screens():
                print("  %-38s %s  %s" % (s["name"],
                                          {True: "ACTIVE", False: "     ",
                                           None: "  ?  "}[s["active"]], s["t"]))
        elif cmd == "dump":
            rows, complete = dump_screen(rest[0] if rest else None)
            for r in rows:
                print("  %-40r %s" % (r["text"][:40], "/".join(r["path"][-3:])))
            print("  -- %d labelled node(s); tree walk %s"
                  % (len(rows), "COMPLETE" if complete else
                     "TRUNCATED (absence proves nothing)"))
        elif cmd == "findtext":
            hits, complete = find_text(" ".join(rest))
            for h in hits:
                print("  %s  %-28r %s" % (h["t"], h["text"][:28],
                                          "/".join(h["path"][-4:])))
            print("  -- %d hit(s); tree walk %s"
                  % (len(hits), "COMPLETE" if complete else
                     "TRUNCATED (absence proves nothing)"))
        elif cmd == "click":
            ok, msg = click_text(" ".join(rest))
            print(("OK: " if ok else "FAILED: ") + msg)
            return 0 if ok else 4
        elif cmd == "inraid":
            v = in_raid()
            print({True: "IN RAID",
                   False: "NOT in a raid (a menu screen is active)",
                   None: "UNKNOWN -- no menu screen is active and "
                         "RegisterPlayer has not fired (or botDiag is off). "
                         "Saying unknown rather than guessing."}[v])
        else:
            print("unknown command %r" % cmd, file=sys.stderr)
            return 2
    except (UiError, Timeout) as e:
        print("!! %s" % e, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
