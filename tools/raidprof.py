#!/usr/bin/env python3
r"""raidprof.py -- WHERE DOES THE TIME GO between launch and standing in a raid.

    python tools/raidprof.py                 the newest session
    python tools/raidprof.py --top 20        more gaps
    python tools/raidprof.py --json
    python tools/raidprof.py --session log_2026.09.01_13-56-55_1.1.0.1.46777
    python tools/raidprof.py --phases                 launch -> GameRunned, by phase
    python tools/raidprof.py --compare OLD NEW        two sessions side by side

## Phases and buckets (`--phases`)

The gap list says WHERE the silence is; it does not say whose fault it is. The
phase table cuts launch -> GameRunned ("deployed", the moment the player can
move) at the client's own milestones and, inside each phase, splits the wall
clock three ways using only what the client itself logged:

    server   the UNION of every [---> Request .. <--- Response] interval, so
             ten parallel requests that all take 0.8s count 0.8s, not 8s.
             This is server time PLUS transfer; it is an upper bound on what
             the backend can be blamed for.
    parse    the sum of ParseSeconds -- the client turning our JSON into
             objects. Ours to shrink only by shrinking the payload.
    client   everything else: scene load, pooling, spawning, waiting.

`bots` is the number of `AIDATA create` lines in the phase: how many bots
the client built before the phase ended, which is decided by OUR wave table.
The union is computed per phase over requests that STARTED in it.

Phase boundaries are first occurrences, so a session that never reached
GameRunned prints the phases it did reach and says INCONCLUSIVE for the rest
(exit 3), and `--compare` refuses to print a delta it cannot stand behind.

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


# --------------------------------------------------------------- phases
# (name, regex on the message) -- the first line matching each one ends the
# named phase.  Order matters and is the order the client emits them.
MILESTONES = [
    ("boot",          r"Request HTTPS, id \[1\]"),
    ("login+statics", r"Request HTTPS.*?/client/game/profile/select"),
    ("menu",          r"scene preset path:|TRACE-NetworkGameMatching G"),
    ("matching",      r"TRACE-NetworkGameMatching I"),
    ("scene load",    r"^LocationLoaded:"),
    ("game create",   r"^GameCreated:"),
    ("player spawn",  r"^PlayerSpawnEvent:"),
    ("pooling",       r"^GamePooled:"),
    ("initial spawn", r"^GameRunned:"),
]
MILESTONE_RE = [(n, re.compile(rx)) for n, rx in MILESTONES]

REQ = re.compile(r"---> Request HTTPS, id \[(\d+)\]: URL: \S*?(/\S+?)\.?\s*$")
RSP = re.compile(r"<--- Response HTTPS, id \[(\d+)\]: URL: \S*?(/\S+?), "
                 r"DownloadSeconds: ([0-9.]+), ParseSeconds: ([0-9.]+)")
AIDATA = re.compile(r"AIDATA create")


def union_seconds(intervals):
    """Total length covered by a set of [a,b] intervals, overlaps counted once."""
    tot = 0.0
    cur_a = cur_b = None
    for a, b in sorted(intervals):
        if cur_b is None or a > cur_b:
            if cur_b is not None:
                tot += cur_b - cur_a
            cur_a, cur_b = a, b
        elif b > cur_b:
            cur_b = b
    if cur_b is not None:
        tot += cur_b - cur_a
    return tot


def phase_table(rows):
    """Cut launch -> GameRunned at the milestones; attribute each phase.

    Returns (phases, reached_end). Each phase is a dict: name, start_s,
    seconds, server_s, parse_s, bots, requests, biggest_gap (g, before, after).
    Requests are keyed by id so the same line mirrored into both
    application_000.log and output_000.log is counted once; bot lines are
    deduplicated by (timestamp, message) for the same reason.
    """
    t0 = rows[0][0]
    bounds = []
    idx = 0
    for i, (_t, _ch, msg) in enumerate(rows):
        if idx >= len(MILESTONE_RE):
            break
        name, rx = MILESTONE_RE[idx]
        if rx.search(msg):
            bounds.append((name, i))
            idx += 1
    reached_end = idx == len(MILESTONE_RE)

    reqs = {}
    for t, _ch, msg in rows:
        m = REQ.search(msg)
        if m:
            reqs.setdefault(m.group(1), [t, None, m.group(2), 0.0])
            continue
        m = RSP.search(msg)
        if m:
            r = reqs.setdefault(m.group(1), [t, None, m.group(2), 0.0])
            if r[1] is None:
                r[1] = t
                r[3] = float(m.group(4))

    phases = []
    start_i = 0
    for name, end_i in bounds:
        ts, te = rows[start_i][0], rows[end_i][0]
        sec = (te - ts).total_seconds()
        ivals = []
        parse = 0.0
        nreq = 0
        for _rid, (a, b, _route, ps) in reqs.items():
            if ts <= a < te:
                nreq += 1
                parse += ps
                if b is not None:
                    # the "<--- Response" line is written AFTER the client has
                    # parsed the body, so the server interval ends ParseSeconds
                    # earlier than the line's timestamp; otherwise every big
                    # payload is double-counted as server AND parse.
                    end = (b - t0).total_seconds() - ps
                    ivals.append(((a - t0).total_seconds(), max(end, (a - t0).total_seconds())))
        seen = set()
        bots = 0
        for t, _c, m in rows[start_i:end_i]:
            if AIDATA.search(m) and (t, m) not in seen:
                seen.add((t, m))
                bots += 1
        big = (0.0, None, None)
        for i in range(start_i + 1, end_i + 1):
            g = (rows[i][0] - rows[i - 1][0]).total_seconds()
            if g > big[0]:
                big = (g, rows[i - 1][2], rows[i][2])
        phases.append({
            "name": name, "start_s": (ts - t0).total_seconds(), "seconds": sec,
            "server_s": union_seconds(ivals), "parse_s": parse, "bots": bots,
            "requests": nreq, "biggest_gap": big,
        })
        start_i = end_i
    return phases, reached_end


def print_phases(phases, reached_end, label):
    bar = "-" * 78
    total = sum(p["seconds"] for p in phases)
    print(bar)
    print(" %s" % label)
    if reached_end:
        print(" launch -> GameRunned (deployed): %.1fs" % total)
    else:
        got = [p["name"] for p in phases]
        print(" INCONCLUSIVE: GameRunned never logged; reached only: %s (%.1fs)"
              % (", ".join(got) or "nothing", total))
    print(bar)
    print(" %-14s %7s %5s | %7s %7s %7s | %4s %4s  biggest silence"
          % ("phase", "sec", "%", "server", "parse", "client", "bots", "req"))
    for p in phases:
        client = max(0.0, p["seconds"] - p["server_s"] - p["parse_s"])
        pct = 100.0 * p["seconds"] / total if total else 0
        g = p["biggest_gap"][0]
        print(" %-14s %7.1f %4.0f%% | %7.1f %7.1f %7.1f | %4d %4d  %.1fs"
              % (p["name"], p["seconds"], pct, p["server_s"], p["parse_s"],
                 client, p["bots"], p["requests"], g))
    srv = sum(p["server_s"] for p in phases)
    prs = sum(p["parse_s"] for p in phases)
    rest = total - srv - prs
    print(bar)
    print(" buckets: server(upper bound) %.1fs %.0f%% | parse %.1fs %.0f%% | client %.1fs %.0f%%"
          % (srv, 100.0 * srv / total if total else 0,
             prs, 100.0 * prs / total if total else 0,
             rest, 100.0 * rest / total if total else 0))
    print(" 'server' is request->response wall (server + transfer), overlapping")
    print(" requests counted once; 'parse' is the client's own ParseSeconds.")
    print(bar)


def print_compare(pa, ea, la, pb, eb, lb):
    bar = "-" * 78
    print(bar)
    print(" OLD: %s" % la)
    print(" NEW: %s" % lb)
    ta = sum(p["seconds"] for p in pa)
    tb = sum(p["seconds"] for p in pb)
    if ea and eb:
        print(" launch -> GameRunned: %.1fs -> %.1fs  (%+.1fs, %+.0f%%)"
              % (ta, tb, tb - ta, 100.0 * (tb - ta) / ta if ta else 0))
    else:
        who = "both" if not ea and not eb else ("OLD" if not ea else "NEW")
        print(" INCONCLUSIVE: %s did not reach GameRunned; partial phases only" % who)
    print(bar)
    print(" %-14s %8s %8s %8s | %7s %7s | %5s %5s"
          % ("phase", "old", "new", "delta", "srv old", "srv new", "bots", "bots"))
    da = {p["name"]: p for p in pa}
    db = {p["name"]: p for p in pb}
    nan = float("nan")
    for name, _rx in MILESTONES:
        a, b = da.get(name), db.get(name)
        if a is None and b is None:
            continue
        sa = a["seconds"] if a else nan
        sb = b["seconds"] if b else nan
        print(" %-14s %8.1f %8.1f %+8.1f | %7.1f %7.1f | %5s %5s"
              % (name, sa, sb, sb - sa,
                 a["server_s"] if a else nan, b["server_s"] if b else nan,
                 a["bots"] if a else "-", b["bots"] if b else "-"))
    print(bar)


def load_session(root, name):
    d = os.path.join(root, name) if name else newest_session(root)
    if not d or not os.path.isdir(d):
        return None, []
    paths = [f for f in glob.glob(os.path.join(d, "*.log"))
             if f.endswith(("application_000.log", "output_000.log"))]
    return d, parse(paths)


def main():
    p = argparse.ArgumentParser(
        description="where the time goes between launch and being in a raid",
        formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    p.add_argument("--logs", default=DEFAULT_LOGS)
    p.add_argument("--session", default=None)
    p.add_argument("--top", type=int, default=12)
    p.add_argument("--json", action="store_true")
    p.add_argument("--phases", action="store_true",
                   help="launch -> GameRunned cut at the client's milestones, "
                        "each phase split into server / parse / client")
    p.add_argument("--compare", nargs=2, metavar=("OLD", "NEW"),
                   help="phase table of two sessions side by side with deltas")
    a = p.parse_args()

    if a.compare:
        da, ra = load_session(a.logs, a.compare[0])
        db_, rb = load_session(a.logs, a.compare[1])
        if len(ra) < 2 or len(rb) < 2:
            print("INCONCLUSIVE: a session is missing or has no timestamped lines")
            return 3
        pa, ea = phase_table(ra)
        pb, eb = phase_table(rb)
        print_compare(pa, ea, os.path.basename(da), pb, eb, os.path.basename(db_))
        return 0 if (ea and eb) else 3

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

    if a.phases:
        phases, reached = phase_table(rows)
        if a.json:
            out = []
            for ph in phases:
                o = dict(ph)
                o["biggest_gap"] = round(ph["biggest_gap"][0], 2)
                for k in ("start_s", "seconds", "server_s", "parse_s"):
                    o[k] = round(o[k], 2)
                out.append(o)
            print(jsonmod.dumps({"session": os.path.basename(d),
                                 "reached_gamerunned": reached, "phases": out},
                                separators=(",", ":")))
            return 0 if reached else 3
        print_phases(phases, reached, os.path.basename(d))
        return 0 if reached else 3

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
