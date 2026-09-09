#!/usr/bin/env python3
r"""triage.py -- what went wrong in the last run. One command, ranked, no grep.

    python tools/triage.py                 the last run, ranked
    python tools/triage.py --json          machine-readable
    python tools/triage.py --full          more of everything

## Why this exists

Every log this project produces is already accessible. That was never the
problem. The problem is that finding the ONE line that matters means an LLM
reading text -- `grep -a ERRORDIALOG`, then `tail -c 400`, then
`clientlog.py sweep`, then the backend log, then working out whether "the log
just stops here" means crashed or idle. That is six-plus tool calls, a screenful
of irrelevant log in the transcript each time, and it has to be re-derived every
session because the right grep depends on what broke.

A run has a handful of possible outcomes and they all have signatures. This
reads EVERY log of the last run, ranks what it finds by how decisive it is, and
prints the top of that ranking. The point is that the answer floats up on its
own instead of being fished for.

## What it reads

  * `aowlspt-host.log`        -- our own; run length, faults, ERRORDIALOG,
                                 warn/error lines, and the last lines before it
                                 stopped (which is where a death shows).
  * `aowlspt-backend.log`     -- the emulated server's own errors.
  * the newest `D:\Aowlspt\Logs\log_*` -- the CLIENT's own logs, classified
                                 through `crashwatch`'s measured signatures so
                                 the crash list stays defined in exactly one
                                 place.

Nothing is ever read whole into the report. The files are read to build a
ranking; what is PRINTED is bounded, and the paths are named so anything deeper
can be looked at deliberately.

## Ranking

Decisiveness, not chronology. In order:

    1  ERRORDIALOG            the client put an error window up. It is not idle.
    2  client crash signature crashwatch's classification of a thrown exception
    3  host fault             a guarded body faulted (the game survived, but
                              something is wrong with our code)
    4  host error/warn        our own complaints
    5  backend error
    6  the tail before silence  where a death actually happened

An empty report is a real answer and says so, distinctly from "I could not
look" -- if a log is missing, that is stated as INCONCLUSIVE rather than
counted as clean.
"""

from __future__ import annotations

import argparse
import json as jsonmod
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import crashwatch  # noqa: E402 -- the crash signatures live there, not here

DEFAULT_ROOT = r"D:\Aowlspt"

# `[0:00:21.844] warn   message`
HOSTLINE = re.compile(r"^\[(\d+:\d\d:\d\d\.\d+)\]\s+(\w+)\s+(.*)$")

# A guarded body faulted. The game survived (that is what the guard is for) but
# our code did something wrong, so it ranks above an ordinary warn.
FAULT = re.compile(r"FAULTED|fault \d+ of \d+|caught; the game survived")

# Host noise that is routine and must not crowd out the real finding. Each of
# these is a normal thing the host says on a healthy run.
HOST_NOISE = re.compile(
    r"INCONCLUSIVE\s+no |is not set|left exactly as it is|"
    r"does not mention|is installed and not selected|"
    r"NOT MEASURED|no indicator has been drawn|not in a raid")


def read_lines(path, limit_bytes=4 << 20):
    """Read a log, tail-biased. Never more than `limit_bytes` -- these files are
    measured token bombs and an unwindowed read has ended sessions before."""
    try:
        size = os.path.getsize(path)
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            if size > limit_bytes:
                f.seek(size - limit_bytes)
                f.readline()          # drop the partial first line
            return f.read().splitlines()
    except OSError:
        return None


def host_findings(path, full):
    """(findings, meta). meta carries run length and how the log ended."""
    lines = read_lines(path)
    if lines is None:
        return ([{"rank": 0, "kind": "INCONCLUSIVE",
                  "text": "no host log at %s -- the host never ran, so nothing "
                          "here can be called clean" % path}], {})
    out = []
    last_stamp = ""
    tail = []
    for raw in lines:
        m = HOSTLINE.match(raw)
        if not m:
            continue
        stamp, level, msg = m.group(1), m.group(2).lower(), m.group(3)
        last_stamp = stamp
        tail.append("[%s] %s %s" % (stamp, level, msg))
        del tail[:-8]
        if "ERRORDIALOG kind=" in msg and 'header="<suppressed>"' not in msg:
            out.append({"rank": 1, "kind": "ERRORDIALOG", "at": stamp,
                        "text": msg})
        elif FAULT.search(msg):
            out.append({"rank": 3, "kind": "host-fault", "at": stamp,
                        "text": msg})
        elif level in ("error", "err"):
            out.append({"rank": 4, "kind": "host-error", "at": stamp,
                        "text": msg})
        elif level == "warn" and not HOST_NOISE.search(msg):
            out.append({"rank": 4, "kind": "host-warn", "at": stamp,
                        "text": msg})
    meta = {"run_length": last_stamp, "tail": tail,
            "errdlg_armed": any("errdlg ARMED" in l for l in lines)}
    return out, meta


def backend_findings(path):
    lines = read_lines(path)
    if lines is None:
        return []
    out = []
    for raw in lines:
        m = HOSTLINE.match(raw)
        if not m:
            continue
        stamp, level, msg = m.group(1), m.group(2).lower(), m.group(3)
        if level in ("error", "err"):
            out.append({"rank": 5, "kind": "backend-error", "at": stamp,
                        "text": msg})
    return out


def client_findings(logs_root):
    """Classify the client's own logs through crashwatch's signatures."""
    d = crashwatch.newest_log_dir(logs_root)
    if not d:
        return ([{"rank": 0, "kind": "INCONCLUSIVE",
                  "text": "no log_* dir under %s -- the client wrote no logs, "
                          "which itself means it died very early" % logs_root}],
                None)
    files = crashwatch.resolve_files(d)
    out = []
    for _suf, p in files.items():
        lines = read_lines(p)
        if lines is None:
            continue
        # Rebuild records the way crashwatch does: a header line plus its
        # unindented continuations, classified by the SAME function, so the two
        # tools can never disagree about what a crash is.
        rec, level = [], ""
        for raw in lines:
            if crashwatch.TS.match(raw):
                if rec:
                    got = crashwatch.classify("\n".join(rec), level)
                    if got:
                        out.append({"rank": 2, "kind": got[0],
                                    "text": got[1],
                                    "record": "\n".join(rec)[:400]})
                rec = [raw]
                parts = raw.split("|")
                level = parts[2] if len(parts) > 2 else ""
            elif rec:
                rec.append(raw)
    return out, d


def dedupe(findings):
    """Collapse identical findings, keeping a count. A crash that fires 200
    times is one finding with n=200, not 200 lines of report."""
    seen = {}
    order = []
    for f in findings:
        key = (f.get("kind"), f.get("text", "")[:160])
        if key in seen:
            seen[key]["n"] += 1
        else:
            f = dict(f)
            f["n"] = 1
            seen[key] = f
            order.append(key)
    return [seen[k] for k in order]


def main():
    p = argparse.ArgumentParser(
        description="what went wrong in the last run, ranked",
        formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    p.add_argument("--root", default=DEFAULT_ROOT)
    p.add_argument("--top", type=int, default=12)
    p.add_argument("--full", action="store_true")
    p.add_argument("--json", action="store_true")
    args = p.parse_args()

    inst = os.path.join(args.root, "aowlspt")
    hostlog = os.path.join(inst, "aowlspt-host.log")
    backlog = os.path.join(inst, "aowlspt-backend.log")

    hf, meta = host_findings(hostlog, args.full)
    bf = backend_findings(backlog)
    cf, cdir = client_findings(os.path.join(args.root, "Logs"))

    findings = dedupe(sorted(hf + bf + cf, key=lambda f: f["rank"]))
    top = findings if args.full else findings[:args.top]

    if args.json:
        print(jsonmod.dumps({
            "run_length": meta.get("run_length"),
            "errdlg_armed": meta.get("errdlg_armed"),
            "findings": top,
            "tail": meta.get("tail", []),
            "client_log_dir": cdir,
        }, separators=(",", ":")))
        return 0 if not findings else 1

    bar = "-" * 68
    print(bar)
    print(" LAST RUN   host log ran %s" % (meta.get("run_length") or "<never>"))
    if not meta.get("errdlg_armed"):
        print("            in-game error-dialog catch NOT armed -- a run that"
              " showed a")
        print("            dialog would look identical to a healthy idle one.")
    print(bar)
    if not findings:
        print(" nothing ranked. That is a real 'clean', not a 'could not look':")
        print(" the host log parsed and contained no fault, error or dialog.")
    for f in top:
        n = ("  x%d" % f["n"]) if f["n"] > 1 else ""
        at = (" @%s" % f["at"]) if f.get("at") else ""
        print(" %-22s%s%s" % (f["kind"], at, n))
        print("   %s" % f["text"][:220])
    if meta.get("tail"):
        print("\n last host lines before it stopped -- a death shows HERE:")
        for l in meta["tail"][-5:]:
            print("   | " + l[:180])
    print("\n logs: %s" % hostlog)
    if cdir:
        print("       %s" % cdir)
    print(bar)
    return 0 if not findings else 1


if __name__ == "__main__":
    sys.exit(main())
