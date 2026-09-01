#!/usr/bin/env python3
r"""raidprof.py -- WHERE DOES THE TIME GO between launch and standing in a raid.

    python tools/raidprof.py                 the newest session
    python tools/raidprof.py --top 20        more gaps
    python tools/raidprof.py --json
    python tools/raidprof.py --session log_2026.09.01_13-56-55_1.1.0.1.46777

## The question this answers

"Surely it does not take this long to get into a raid." It takes about two
minutes, and until now the only evidence was eight lines EFT prints itself:

    GameCreated:57.7(1.34)   real:68.33(1.36)
    PlayerSpawnEvent:61.28(61.28) real:78.9(78.9)
    GamePooled:80.08(22.38)  real:99.12(30.79)
    GameRunned:92.53(12.44)  real:120.81(21.68)
    GameSpawned:92.53(31.25) real:120.81(41.9)

Those are real but nearly unusable for deciding what to cut: the cumulative and
the delta are measured from different origins (PlayerSpawnEvent reports a delta
equal to its own cumulative), several phases share a timestamp, and none of them
says WHAT was running during the gap.

So this ignores the self-reported numbers and measures the only thing that is
unambiguous: **the wall-clock gap between consecutive log lines**. Whatever the
client was doing during the biggest gap is where the time went, and the line on
each side of it names the work.

## Why gaps rather than a profiler

A sampling profiler over IL2CPP would be better and is not available. But the
client logs continuously through load -- asset loads, scene progress, backend
round trips -- so silence in the log IS the expensive operation. A 30-second gap
between "loading level" and the next line is thirty seconds inside one call,
and the pair of lines names it.

This is the same reasoning `harness.py` uses to tell IDLE from HUNG, applied to
a timeline instead of a deadline.

## What it will not tell you

It does not attribute time to a FUNCTION, and it cannot see work that logs
nothing at all -- that shows up as one big anonymous gap, which is itself the
finding. It reports the gap and the lines around it; deciding what is skippable
is a judgement about the game, not something this can measure.
"""

from __future__ import annotations

import argparse
import datetime as dt
import glob
import json as jsonmod
import os
import re
import sys

DEFAULT_LOGS = r"D:\Aowlspt\Logs"

# "2026-09-01 12:13:19.702|1.1.0.1.46777|Info|application|message"
LINE = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+)\|[^|]*\|([^|]*)\|([^|]*)\|(.*)$")

# EFT's own phase markers, kept separately because they are the milestones a
# reader recognises even though their arithmetic is not trustworthy.
PHASE = re.compile(r"\b([A-Z][A-Za-z]+):([0-9.]+)\(([0-9.]+)\) real:([0-9.]+)\(([0-9.]+)\)")

MAX_BYTES = 24 << 20   # a raid session's application log is a few MB; bounded anyway


def newest_session(root):
    ds = [d for d in glob.glob(os.path.join(root, "log_*")) if os.path.isdir(d)]
    return max(ds, key=os.path.getmtime) if ds else None


def read_lines(path):
    try:
        size = os.path.getsize(path)
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            if size > MAX_BYTES:
                f.seek(size - MAX_BYTES)
                f.readline()
            return f.read().splitlines()
    except OSError:
        return []


def parse(paths):
    """(timestamp, channel, message) for every timestamped line, time-ordered."""
    out = []
    for p in paths:
        for raw in read_lines(p):
            m = LINE.match(raw)
            if not m:
                continue
            try:
                t = dt.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S.%f")
            except ValueError:
                continue
            out.append((t, m.group(3), m.group(4)))
    out.sort(key=lambda r: r[0])
    return out


def main():
    p = argparse.ArgumentParser(
        description="where the time goes between launch and being in a raid",
        formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    p.add_argument("--logs", default=DEFAULT_LOGS)
    p.add_argument("--session", default=None)
    p.add_argument("--top", type=int, default=12)
    p.add_argument("--json", action="store_true")
    a = p.parse_args()

    d = os.path.join(a.logs, a.session) if a.session else newest_session(a.logs)
    if not d or not os.path.isdir(d):
        print("no session under %s" % a.logs)
        return 3

    paths = [f for f in glob.glob(os.path.join(d, "*.log"))
             if f.endswith(("application_000.log", "output_000.log"))]
    rows = parse(paths)
    if len(rows) < 2:
        print("session %s has too few timestamped lines to profile (%d) -- "
              "INCONCLUSIVE, not fast" % (os.path.basename(d), len(rows)))
        return 3

    t0, t1 = rows[0][0], rows[-1][0]
    total = (t1 - t0).total_seconds()

    gaps = []
    for i in range(1, len(rows)):
        g = (rows[i][0] - rows[i - 1][0]).total_seconds()
        if g > 0.4:
            gaps.append((g, rows[i - 1], rows[i]))
    gaps.sort(key=lambda x: -x[0])

    phases = []
    for t, _ch, msg in rows:
        m = PHASE.search(msg)
        if m:
            phases.append((m.group(1), float(m.group(4)), (t - t0).total_seconds()))

    accounted = sum(g for g, _a, _b in gaps)

    if a.json:
        print(jsonmod.dumps({
            "session": os.path.basename(d),
            "span_s": round(total, 1),
            "lines": len(rows),
            "gap_total_s": round(accounted, 1),
            "top_gaps": [{"seconds": round(g, 2), "after": b[2][:160],
                          "before": c[2][:160]} for g, b, c in gaps[:a.top]],
            "phases": [{"name": n, "at_s": round(at, 1)} for n, _r, at in phases],
        }, separators=(",", ":")))
        return 0

    bar = "-" * 74
    print(bar)
    print(" %s" % os.path.basename(d))
    print(" %d timestamped line(s) spanning %.1fs" % (len(rows), total))
    print(" %.1fs of that (%.0f%%) is spent in gaps longer than 0.4s"
          % (accounted, 100.0 * accounted / total if total else 0))
    print(bar)
    if phases:
        print(" MILESTONES (seconds from the first log line):")
        for n, _r, at in phases:
            print("   %7.1fs  %s" % (at, n))
        print(bar)
    print(" THE BIGGEST GAPS -- the client logged nothing for this long, so")
    print(" whatever ran between these two lines is where the time went:")
    for g, before, after in gaps[:a.top]:
        print("\n  %6.1fs  at +%.1fs" % (g, (before[0] - t0).total_seconds()))
        print("     last: %s" % before[2][:150])
        print("     next: %s" % after[2][:150])
    print("\n" + bar)
    return 0


if __name__ == "__main__":
    sys.exit(main())
