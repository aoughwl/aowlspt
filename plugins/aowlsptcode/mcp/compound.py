#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""compound.py -- multi-step MCP tools that do a whole verification job in
ONE call, built on top of channel.py's sentinel-guarded transport.

Every raw-verb tool in server.py already exists; the problem this file
solves is that a single real question ("is this path there", "did settings
open", "does assertion X hold") took 4-8 of them chained by hand, each a
separate MCP round trip, each requiring the caller to re-derive the walk.

Same honesty contract as everywhere else in this plugin: PASS / FAIL /
INCONCLUSIVE, never collapsed to two outcomes, and a step that could not be
trusted (STOPPED_EARLY, an unreadable pointer, a timeout) makes the whole
compound call INCONCLUSIVE rather than silently reading as failure or
success.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import channel  # noqa: E402

# WHERE `tools/` COMES FROM, AND WHY IT MIGHT NOT BE THERE AT ALL.
#
# This plugin is PUBLIC and is meant to be installed on its own, next to an
# aowlspt INSTALL. The aowlspt SOURCE REPO is private and most people who run
# this will not have it. Everything in this file that talks to the live client
# goes through the file channel and needs nothing but the install; only
# `inspect_assert` reaches into the repo, for `tools/acceptance.py`.
#
# So the repo is treated as OPTIONAL and located rather than assumed. The old
# code walked four directories up from this file and appended `tools`, which is
# correct exactly when the plugin is sitting inside a checkout at
# `plugins/aowlsptcode/mcp/` and is silently wrong everywhere else -- it would
# put a nonexistent path on sys.path and the failure would surface much later
# as a confusing ImportError inside one tool.
#
# `AOWLSPT_REPO` wins if set; otherwise the in-checkout layout is tried and
# accepted only if it actually contains `acceptance.py`. If neither works,
# `REPO`/`TOOLS` are None and `inspect_assert` says so plainly instead of
# raising something that reads like a bug.
def _find_tools():
    env = os.environ.get("AOWLSPT_REPO")
    cands = []
    if env:
        cands.append(os.path.join(env, "tools"))
    cands.append(os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(
        os.path.dirname(os.path.abspath(__file__))))), "tools"))
    for c in cands:
        if os.path.isfile(os.path.join(c, "acceptance.py")):
            return os.path.dirname(c), c
    return None, None


REPO, TOOLS = _find_tools()
if TOOLS and TOOLS not in sys.path:
    sys.path.insert(0, TOOLS)


# ---------------------------------------------------------------------------
# inspect_path -- resolve a slash path from the scene roots in one call.
# ---------------------------------------------------------------------------

def resolve_path(path, live_dir=None, timeout=25.0, budget=20000):
    """`path` is `RootName/Child/Grandchild/...`. The first segment is
    matched against `roots` output (by name, via `find NAME $rN 4000` scoped
    to each root transform in turn is too slow/ambiguous -- instead this
    walks `find <segment> <current_ptr> <budget>` from root outward, taking
    the first hit each step, same as every hand-driven walk in this repo's
    history was doing one MCP call at a time).

    Returns a dict: {ok, steps: [{segment, ptr, name}], final_ptr,
    completeness_per_step, parse_ok}. `ok` is False the instant one segment
    is not FOUND -- and that segment's completeness is examined: an
    STOPPED_EARLY/HIT_CAP miss is reported as inconclusive_at, never folded
    into the same "not found" bucket as a genuinely EXHAUSTIVE miss.
    """
    segments = [s for s in path.split("/") if s]
    if not segments:
        return {"ok": False, "reason": "empty path", "steps": []}

    sentinel, raw = channel.run_batch(["roots"], live_dir=live_dir, timeout=timeout)
    roots = channel.parse_roots(raw)
    if not roots["parse_ok"]:
        return {"ok": False, "reason": "could not parse `roots` output",
                "steps": [], "raw_roots": raw}

    # `roots` only binds $rN, it does not name them -- so the first segment
    # is matched with an unscoped `find`, same as any other hop, and the
    # steps list starts there rather than pretending `roots` resolved it.
    steps = []
    cur_ptr = None
    for i, seg in enumerate(segments):
        scope = cur_ptr  # None on the first hop == search all scene roots
        # `iSplit` (inspect.nim:473) splits find's NAME on whitespace unless
        # quoted, so a multi-word segment like "Preloader UI" would tokenize
        # as `find Preloader UI` -> NAME=Preloader, ROOT=UI and fail with
        # "not an address: UI" -- measured live. Always quote the segment.
        seg_q = '"%s"' % seg
        cmd = "find %s" % seg_q if scope is None else "find %s %s %d" % (seg_q, scope, budget)
        s2, raw2 = channel.run_batch([cmd], live_dir=live_dir, timeout=timeout)
        f = channel.parse_find(raw2)
        if not f["hits"]:
            step = {"segment": seg, "found": False,
                    "completeness": f["completeness"],
                    "can_trust_absence": f["can_trust_absence"], "ptr": None}
            steps.append(step)
            status = "INCONCLUSIVE" if not f["can_trust_absence"] else "FAIL"
            return {"ok": False, "status": status, "steps": steps,
                    "failed_at": i, "final_ptr": None,
                    "reason": ("segment %r not found (%s)%s" %
                               (seg, f["completeness"],
                                "" if f["can_trust_absence"] else
                                " -- this is NOT proof of absence"))}
        hit = f["hits"][0]
        cur_ptr = hit["ptr"]
        steps.append({"segment": seg, "found": True, "ptr": hit["ptr"],
                       "name": hit["name"], "completeness": f["completeness"],
                       "multiple_hits": len(f["hits"]) > 1})
    return {"ok": True, "status": "PASS", "steps": steps, "final_ptr": cur_ptr}


# ---------------------------------------------------------------------------
# inspect_open_settings -- the fact #109 recipe, as one call.
# ---------------------------------------------------------------------------

OPEN_SETTINGS_RVA = "rva:0x55ba430"  # AnimatedToggle::SetOn, v_pb -- fact #109

# WHAT A TIMEOUT ON THIS CHANNEL ACTUALLY MEANS.
#
# Measured 2026-09-01: inspect_open_settings returned
#   {"error":{"kind":"timeout","message":"no answer for aowl-batch-... within
#    40s"}}
# and the Settings screen WAS OPEN ON SCREEN immediately afterwards. The tool
# reported failure for an action that worked -- the confidently-wrong-answer
# class this repo treats as worst-case.
#
# The channel is a file drop drained on Unity's MAIN THREAD. When the client is
# busy, the batch is still sitting in the queue when our deadline passes; the
# write already happened and Unity will very likely run it. So "no answer in
# Ns" is INCONCLUSIVE, never FAIL: the command MAY HAVE RUN, and for the two
# steps that WRITE (`call ... SetOn`) it may have run AND taken effect.
#
# Timeouts are also raised across the board -- 40s was below the observed
# latency of the very step that produced the false failure.
STEP_TIMEOUT = 90.0


class _StepTimeout(Exception):
    def __init__(self, step, seconds, message, mutating):
        Exception.__init__(self, message)
        self.step = step
        self.seconds = seconds
        self.message = message
        self.mutating = mutating


def _step(label, lines, live_dir, timeout, write=False, mutating=False):
    """One channel round trip that turns a TimeoutErr into a _StepTimeout
    carrying WHICH step and whether that step writes -- so the caller can say
    "handed to Unity's thread, may have run" instead of "failed"."""
    try:
        return channel.run_batch(lines, live_dir=live_dir, timeout=timeout,
                                 write=write)
    except channel.TimeoutErr as e:
        raise _StepTimeout(label, timeout, str(e), mutating)


def _inconclusive_timeout(e):
    return {
        "status": "INCONCLUSIVE",
        "reason": ("step %r was handed to Unity's main thread and no answer "
                   "came back within %gs. It MAY HAVE RUN%s -- the file-channel "
                   "batch was written and is drained on the main thread, so a "
                   "busy client looks exactly like a lost command. This is NOT "
                   "evidence the Settings screen failed to open; check "
                   "inspect_state or the screen itself."
                   % (e.step, e.seconds,
                      " AND TAKEN EFFECT" if e.mutating else "")),
        "timed_out_step": e.step,
        "timeout_s": e.seconds,
        "may_have_run": True,
        "detail": e.message,
    }


def open_settings(live_dir=None, timeout=180.0):
    """Walk Preloader UI/.../Tabs -> child named 'Settings' (last child,
    bottom-right icon) -> SettingsButton -> component AnimatedToggle ->
    `call rva:0x55ba430 v_pb $comp 1` -> confirm `state` now reports a bound
    $settings anchor. Returns PASS/FAIL/INCONCLUSIVE with the measured
    evidence at each step, never just a bool. A step that TIMES OUT yields
    INCONCLUSIVE with `may_have_run`, never FAIL -- see STEP_TIMEOUT above."""
    try:
        return _open_settings(live_dir, timeout)
    except _StepTimeout as e:
        return _inconclusive_timeout(e)
    except channel.TimeoutErr as e:
        # resolve_path's own round trips raise the untagged form. Same
        # meaning, same verdict -- a read-only step that may still have run.
        return _inconclusive_timeout(
            _StepTimeout("resolve_path(Preloader UI)", STEP_TIMEOUT, str(e), False))


def _open_settings(live_dir, timeout):
    r = resolve_path("Preloader UI", live_dir=live_dir, timeout=STEP_TIMEOUT)
    if not r["ok"]:
        return {"status": "INCONCLUSIVE", "reason": "Preloader UI scene root not found",
                "detail": r}
    preloader = r["final_ptr"]

    sentinel, raw = _step("find TaskBar",
        ["find TaskBar %s 40000" % preloader], live_dir=live_dir, timeout=STEP_TIMEOUT)
    f = channel.parse_find(raw)
    if not f["hits"]:
        status = "INCONCLUSIVE" if not f["can_trust_absence"] else "FAIL"
        return {"status": status, "reason": "TaskBar not found under Preloader UI",
                "completeness": f["completeness"]}
    taskbar = f["hits"][0]["ptr"]

    sentinel, raw = _step("find Tabs",
        ["find Tabs %s 40000" % taskbar], live_dir=live_dir, timeout=STEP_TIMEOUT)
    f = channel.parse_find(raw)
    if not f["hits"]:
        status = "INCONCLUSIVE" if not f["can_trust_absence"] else "FAIL"
        return {"status": status, "reason": "Tabs not found under TaskBar",
                "completeness": f["completeness"]}
    tabs = f["hits"][0]["ptr"]

    sentinel, raw = _step("find Settings",
        ["find Settings %s 40000" % tabs], live_dir=live_dir, timeout=STEP_TIMEOUT)
    f = channel.parse_find(raw)
    if not f["hits"]:
        status = "INCONCLUSIVE" if not f["can_trust_absence"] else "FAIL"
        return {"status": status, "reason": "no child named Settings under Tabs " +
                "(it should be the LAST child, bottom-right icon)",
                "completeness": f["completeness"]}
    settings_tab = f["hits"][0]["ptr"]

    sentinel, raw = _step("find SettingsButton",
        ["find SettingsButton %s 20000" % settings_tab], live_dir=live_dir, timeout=STEP_TIMEOUT)
    f = channel.parse_find(raw)
    if not f["hits"]:
        status = "INCONCLUSIVE" if not f["can_trust_absence"] else "FAIL"
        return {"status": status, "reason": "SettingsButton not found under Settings tab",
                "completeness": f["completeness"]}
    settings_button = f["hits"][0]["ptr"]

    sentinel, raw = _step("component AnimatedToggle",
        ["component %s AnimatedToggle" % settings_button], live_dir=live_dir, timeout=STEP_TIMEOUT)
    comp = channel.parse_component(raw)
    if not comp["bound"]:
        return {"status": "FAIL", "reason": "AnimatedToggle component did not resolve",
                "raw": raw}

    sentinel, raw = _step(
        "call AnimatedToggle::SetOn(true)",
        ["call %s v_pb $comp 1" % OPEN_SETTINGS_RVA], live_dir=live_dir,
        timeout=timeout, write=True, mutating=True)
    call = channel.parse_call(raw)
    if not call["ok"]:
        return {"status": "FAIL", "reason": "AnimatedToggle::SetOn call did not go through",
                "raw": raw}

    # Confirm the effect, never trust "the call returned" as proof (state.nim
    # docstring says exactly this). `state` is free-form prose (parse_ok
    # always False by design -- see parse_state), so this greps the one
    # literal it is documented to contain.
    sentinel, raw = _step("state", ["state"], live_dir=live_dir, timeout=STEP_TIMEOUT)
    settings_bound = "$settings=NOT KNOWN" not in raw.replace(" ", "") and \
        "settings: NOT KNOWN" not in raw
    if settings_bound:
        return {"status": "PASS", "reason": "SetOn(true) fired and state now reports "
                "a bound $settings anchor", "state_raw": raw}
    return {"status": "INCONCLUSIVE", "reason": "SetOn(true) returned without faulting "
            "but `state` does not yet show a bound $settings anchor -- the ShowScreen "
            "hook may not have fired yet, or the flag arming it is off",
            "state_raw": raw}


# ---------------------------------------------------------------------------
# inspect_batch -- run several raw verbs in ONE channel round trip.
# ---------------------------------------------------------------------------

_PARSERS = {
    "find": channel.parse_find, "findtext": channel.parse_findtext,
    "roots": channel.parse_roots, "children": channel.parse_children,
    "tree": channel.parse_tree, "parent": channel.parse_parent,
    "component": channel.parse_component, "comp": channel.parse_component,
    "label": channel.parse_label, "call": channel.parse_call,
    "press": channel.parse_press, "state": channel.parse_state,
    "where": channel.parse_state,
}


def run_batch_commands(commands, live_dir=None, timeout=30.0, write=False):
    """Sends every line in `commands` as ONE batch (the channel already
    supports this -- server.py's per-tool handlers just never used it). The
    combined raw text cannot be reliably split back into per-command
    sub-answers (the channel has no delimiter between them), so this returns
    the whole raw text plus a best-effort parse keyed by each command's verb
    against ITS OWN copy of the parser run over the full raw blob -- callers
    who need precise per-line attribution should prefer one command per call
    via inspect_find/inspect_children/etc. That limitation is stated here,
    not hidden."""
    sentinel, raw = channel.run_batch(commands, live_dir=live_dir, timeout=timeout,
                                       write=write)
    parsed = []
    for c in commands:
        verb = c.strip().split()[0].lower() if c.strip() else ""
        parser = _PARSERS.get(verb)
        parsed.append({
            "command": c, "verb": verb,
            "parsed": parser(raw) if parser else None,
            "parser_available": parser is not None,
        })
    return {"sentinel": sentinel, "raw": raw, "results": parsed,
            "note": ("raw is the WHOLE batch's combined output; per-command "
                     "'parsed' fields each ran their parser over that SAME "
                     "combined text and are unreliable when the batch mixes "
                     "verbs whose output could overlap (e.g. two `find`s) -- "
                     "use inspect_batch for verification of independent "
                     "single-purpose commands, not for extracting N distinct "
                     "structured answers from one call.")}


# ---------------------------------------------------------------------------
# inspect_assert -- one named acceptance assertion from tools/acceptance.py.
# ---------------------------------------------------------------------------

class AssertionUnknown(Exception):
    pass


def run_assertion(name, live_dir=None, root=None, mods_built=False, guid=None):
    """Runs ONE assertion function from tools/acceptance.py against an
    ALREADY-RUNNING client with the Settings screen ALREADY OPEN -- this
    does NOT launch the client, does NOT drive the mode selector, and does
    NOT call open_settings itself, because CLAUDE.md forbids a subagent (and
    this MCP server may run inside one) from starting/stopping the game.
    Call inspect_open_settings first if the screen is not open yet.

    live_dir defaults to channel.LIVE_DEFAULT; root defaults to its parent.
    """
    if TOOLS is None:
        # The private source repo is not present. Say that, precisely, rather
        # than letting an ImportError surface as if the tool were broken: this
        # is the ONLY tool in the plugin that needs the repo, and on a normal
        # public install its absence is expected, not a fault.
        raise AssertionUnknown(
            "inspect_assert needs `tools/acceptance.py` from the aowlspt "
            "SOURCE repo, which is private and is not installed here. Every "
            "other tool in this plugin talks to the live client through the "
            "file channel and needs only the game install, so they are "
            "unaffected. Set AOWLSPT_REPO to a checkout to enable this one.")
    import acceptance as acc  # tools/acceptance.py, imported lazily so a
    # missing/broken acceptance.py degrades this one tool, not the whole
    # server's import.

    live = live_dir or channel.paths()["live"]
    root = root or os.path.dirname(live)

    table = {
        "tab_count": lambda rep: acc.assert_tab_count(rep, live, mods_built),
        "no_donor_caption": lambda rep: acc.assert_no_text(
            rep, live, "no donor caption under MODS", acc.DONOR_CAPTION),
        "no_placeholder_text": lambda rep: acc.assert_no_text(
            rep, live, "no placeholder text anywhere", acc.PLACEHOLDER_TEXT),
        "spawner_one_active_toggle": lambda rep: acc.assert_spawner_one_active_toggle(rep, live),
        "postfx_group": lambda rep: acc.assert_postfx_group(rep, live),
        "one_panel_active_per_group": lambda rep: acc.assert_one_panel_active_per_group(rep, live),
        "no_faults": lambda rep: acc.assert_no_faults(rep, root),
        "settings_json": lambda rep: acc.assert_settings_json(rep, root, guid=guid),
    }
    if name not in table:
        raise AssertionUnknown("%r is not a known assertion; known: %s" %
                                (name, ", ".join(sorted(table))))

    report = acc.Report()
    table[name](report)
    if not report.rows:
        return {"status": "INCONCLUSIVE", "measured": "",
                "detail": "assertion function recorded nothing", "name": name}
    rows = [{"name": n, "status": v, "measured": m, "detail": d}
            for (n, v, m, d) in report.rows]
    # An assertion helper may record more than one row (e.g. per-tab); the
    # compound verdict is PASS only if every row is PASS, matching Report's
    # own exit_code() semantics -- never optimistic majority-voting.
    if any(row["status"] == "FAIL" for row in rows):
        overall = "FAIL"
    elif any(row["status"] == "INCONCLUSIVE" for row in rows):
        overall = "INCONCLUSIVE"
    else:
        overall = "PASS"
    return {"status": overall, "name": name, "rows": rows}
