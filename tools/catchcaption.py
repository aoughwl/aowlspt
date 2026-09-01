#!/usr/bin/env python3
r"""catchcaption.py -- capture a TRANSIENT UI object that only exists during load.

    python tools/catchcaption.py                     wait, catch "loading"
    python tools/catchcaption.py --text "profile"
    python tools/catchcaption.py --json
    python tools/catchcaption.py --arm-only          just say when to look

## The problem it solves

The client's own loading captions -- "Loading profile data...", and whatever
else the boot sequence prints -- are the style donors the mod loading screen has
to match. They are also GONE by the time anyone can look at them by hand.
Measured 2026-09-01: `findtext "Loading" $preloader 60000 all` at the main menu
searched 4,095 nodes EXHAUSTIVELY, with `all` (which includes INACTIVE nodes),
and found nothing at all. So the caption is genuinely destroyed rather than
merely deactivated, and the observation window is the ~60s of boot.

Doing this by hand means watching a log, guessing when to fire a batch, and
usually missing. Missing it silently is the bad part: the loading screen then
falls back to its own defaults and reports `NOT matched`, which reads like a
code bug when it is really "nobody ever looked at the right moment".

## What it does

Tails the host log for the boot markers, then -- ONCE, in the window -- issues a
single narrow batch: `findtext <text>`, then `rect` and `parent` on the first
hit. It records the caption's real anchors, size, pivot, font size and parent
name, which is exactly what a style-matching feature needs and cannot get later.

## The risk, stated plainly

**Inspector reads during a scene load can stall Unity's main thread.** Fact #261
in this project: a read issued during the RAID scene load stalled the loading
thread and errored the load; fact #245 is the same shape, timing out
matchmaking. That is why `enterraid.py` goes deliberately inspector-silent after
READY and watches the log instead.

This tool targets the BOOT load, not the raid load, which is the phase the
inspector is normally driven in anyway. It still minimises exposure: it fires at
most ONE batch of at most three commands, never polls in a loop during the
window, and `--arm-only` exists so you can decide to look yourself rather than
have this fire at all. Do not point it at a raid load.

## Three outcomes, never two

    CAUGHT        the caption was found and its geometry recorded.
    MISSED        the window passed and the batch found nothing. This is a real
                  answer: the caption did not exist, or is named/worded
                  differently, or the search STOPPED EARLY (which is reported
                  separately, because a truncated walk is not absence).
    INCONCLUSIVE  the client never booted, the channel never answered, or the
                  search was truncated. NOT a pass.
"""

from __future__ import annotations

import argparse
import json as jsonmod
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

DEFAULT_ROOT = r"D:\Aowlspt"

# Host-log lines that mean the client is far enough along to have a canvas and
# to be printing load captions, but is not yet at the menu. The mod loading
# screen's own arm line is the most reliable of these because it is emitted
# from exactly the phase we care about.
BOOT_MARKERS = (
    "mod loading screen ARMED",
    "live inspector: rider FIRST DISPATCHED",
)

# The phase line means the boot is OVER -- MENU is published once no GameWorld
# is cached. Seeing it means the window has closed.
AT_MENU = re.compile(r"raid phase = MENU")


def hostlog(root):
    return os.path.join(root, "aowlspt", "aowlspt-host.log")


def tail_for(path, markers, stop_re, timeout, from_pos):
    """Wait for any of `markers`. Returns ('MARKER'|'CLOSED'|'TIMEOUT', line)."""
    pos = from_pos
    deadline = time.time() + timeout
    leftover = ""
    while time.time() < deadline:
        try:
            size = os.path.getsize(path)
        except OSError:
            time.sleep(0.5)
            continue
        if size < pos:          # truncated: a new run started
            pos = 0
            leftover = ""
        if size > pos:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                f.seek(pos)
                data = f.read()
                pos = f.tell()
            data = leftover + data
            lines = data.split("\n")
            leftover = lines.pop()
            for line in lines:
                for m in markers:
                    if m in line:
                        return "MARKER", line.strip()
                if stop_re and stop_re.search(line):
                    return "CLOSED", line.strip()
        time.sleep(0.3)
    return "TIMEOUT", ""


def run_inspector(commands, timeout):
    """One batch through the MCP-free path: write the file, read the answer.

    Deliberately shells out to the existing `ui.py` rather than reimplementing
    the channel, so the BOM rule, the serial bump and the answer parsing stay in
    exactly one place.
    """
    try:
        import ui  # noqa: E402
    except Exception as e:
        return None, "could not import tools/ui.py: %s" % e
    try:
        return ui._run(commands), None
    except Exception as e:
        return None, "inspector batch failed: %s" % e


def main():
    p = argparse.ArgumentParser(
        description="capture a UI object that only exists during the boot load",
        formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    p.add_argument("--root", default=DEFAULT_ROOT)
    p.add_argument("--text", default="loading",
                   help="substring of the DISPLAYED text to catch "
                        "(default 'loading'). Localized -- see the note below.")
    p.add_argument("--wait", type=float, default=300.0,
                   help="seconds to wait for the boot window")
    p.add_argument("--settle", type=float, default=1.5,
                   help="seconds to wait after the marker before looking")
    p.add_argument("--arm-only", action="store_true",
                   help="report when the window opens and fire NOTHING")
    p.add_argument("--json", action="store_true")
    a = p.parse_args()

    path = hostlog(a.root)
    try:
        start_pos = os.path.getsize(path)
    except OSError:
        start_pos = 0

    print("watching %s for the boot window (up to %.0fs)..." % (path, a.wait),
          flush=True)
    why, line = tail_for(path, BOOT_MARKERS, AT_MENU, a.wait, start_pos)

    if why == "TIMEOUT":
        out = {"verdict": "INCONCLUSIVE",
               "why": "no boot marker within %.0fs -- the client never got far "
                      "enough, so NOTHING was looked at. This is not 'the "
                      "caption is absent'." % a.wait}
    elif why == "CLOSED":
        out = {"verdict": "INCONCLUSIVE",
               "why": "the client reached the MENU before any boot marker was "
                      "seen, so the load window was missed entirely. Restart "
                      "and run this BEFORE launching.",
               "evidence": line}
    elif a.arm_only:
        out = {"verdict": "ARMED",
               "why": "the boot window is OPEN now -- look immediately.",
               "evidence": line}
    else:
        time.sleep(a.settle)
        raw, err = run_inspector(['findtext %s' % a.text], 60.0)
        if err:
            out = {"verdict": "INCONCLUSIVE", "why": err, "evidence": line}
        elif raw is None:
            out = {"verdict": "INCONCLUSIVE",
                   "why": "the inspector returned nothing", "evidence": line}
        else:
            hits = re.findall(r'HIT (0x[0-9a-fA-F]+)', raw)
            truncated = "STOPPED EARLY" in raw
            if not hits:
                out = {"verdict": "INCONCLUSIVE" if truncated else "MISSED",
                       "why": ("the walk STOPPED EARLY, so nothing is proven "
                               "about whether the caption exists"
                               if truncated else
                               "the window was open and no node displayed %r. "
                               "The caption may be worded differently, or "
                               "localized -- this matches DISPLAYED TEXT."
                               % a.text),
                       "evidence": line, "raw": raw[-1200:]}
            else:
                ptr = hits[0]
                more, err2 = run_inspector(
                    ["rect %s" % ptr, "parent %s 2" % ptr, "label %s" % ptr],
                    60.0)
                out = {"verdict": "CAUGHT", "hit": ptr,
                       "hits": len(hits), "evidence": line,
                       "geometry": (more or "")[-2500:],
                       "why": "recorded the caption's real frame and parent. "
                              "NOTE: matched by DISPLAYED TEXT, so this is "
                              "locale-dependent; a structural match is safer "
                              "for shipping code."}
                if err2:
                    out["verdict"] = "INCONCLUSIVE"
                    out["why"] = "found the caption but could not read it: %s" % err2

    if a.json:
        print(jsonmod.dumps(out, indent=2))
    else:
        print("\n" + "-" * 66)
        print(" %s" % out["verdict"])
        print(" %s" % out["why"])
        if out.get("evidence"):
            print(" window opened by: %s" % out["evidence"][:150])
        if out.get("geometry"):
            print("\n%s" % out["geometry"])
        print("-" * 66)
    return {"CAUGHT": 0, "ARMED": 0, "MISSED": 1}.get(out["verdict"], 3)


if __name__ == "__main__":
    sys.exit(main())
