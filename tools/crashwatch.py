#!/usr/bin/env python3
r"""crashwatch.py - kill the live EFT client the instant it crashes, then report.

The goal is narrow and blunt: while you are iterating on the dev loop, whenever
the running client hits a fatal error or a hang, the game should CLOSE
IMMEDIATELY and the terminal should show an after-crash report -- so you are not
left staring at a frozen window wondering whether it died or is merely idle.

This watcher tails the CLIENT's OWN logs under D:\Aowlspt\Logs (not the host
log; that is harness.py's job -- see the note at the bottom of this docstring).
It never reads a whole log: it seeks to the current end and reads only new bytes
as they are written, so a 230 KB output_000.log costs nothing.

    python tools/crashwatch.py               # one-shot: watch, kill+report, exit
    python tools/crashwatch.py --watch       # keep watching across relaunches
    python tools/crashwatch.py --dry-run     # detect + report, but DON'T kill
    python tools/crashwatch.py --scan-existing   # also scan text already in the
                                                 # newest dir (off by default so
                                                 # a stale crash can't kill a
                                                 # freshly relaunched game)

Run it in the background from PowerShell so it rides alongside the game:

    Start-Process -WindowStyle Hidden python `
      -ArgumentList 'tools/crashwatch.py','--watch' `
      -RedirectStandardOutput 'D:/Aowlspt/crashwatch.out'

or, from this repo's tooling, `run_in_background`.

## What counts as a crash (conservative on purpose)

A watcher that kills a healthy game is worse than no watcher, so every signature
below was checked against real logs on this box (2026-08-30): a healthy session
has ZERO Error-level lines, and `MoveNext` -- which appears 5000+ times per
session inside ordinary async stack dumps -- is NEVER matched on its own.

  * unhandled-exception    an Error/Fatal/Critical record, OR any record that
                           names an *Exception/*Error type AND carries a stack
                           (a `MoveNext()`, an `at `, or a `Rethrow as`).
  * aggregate-exception    "One or more errors occurred" / AggregateException --
                           the raid-load NRE cascade shows up exactly this way.
  * raid-load-abort        "A task was canceled" / TaskCanceledException.
  * matchmaking-timeout    a NetworkGameMatching trace armed, then no raid-start
                           marker (LocationLoaded / MatchingCompleted /
                           GameStarted) within --match-timeout seconds. This one
                           is the softest signature; see the caveat on it below.

Known-benign stock EFT/Unity noise (convex-mesh, spawn-marker snap, missing
bundle script) is suppressed -- the list is shared in spirit with clientlog.py.

## How it complements harness.py

harness.py tails the HOST log (aowlspt-host.log) during a scripted launch and
already distinguishes DIED (process gone) from IDLE (log went quiet) -- but it
only runs for the duration of one `run`, watches OUR log not the client's, and
does not kill on a crash *signature*; it waits out a stall. crashwatch is the
other half: it watches the CLIENT's own logs for the exception/abort text the
client itself prints, and kills on sight. They do not overlap and neither needs
the other; if you wanted them fused, harness's `watch()` loop is where a
crashwatch check would slot in, but this is deliberately a separate process so
it can outlive any single launch.
"""

from __future__ import annotations

import argparse
import glob
import os
import re
import subprocess
import sys
import time
from collections import deque

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

# Windows-style path on purpose: MSYS/.NET mangle /d/... inconsistently
# (fact #152). Everything downstream stays absolute and uses forward slashes.
DEFAULT_LOGS = "D:/Aowlspt/Logs"
PROCS = ["EscapeFromTarkov", "aowlspt-backend", "aowlspt-launch"]

# The three client logs worth tailing. Filenames on this build are prefixed with
# the session stamp, e.g. "2026.08.30_10-48-04_1.1.0.1.46777 output_000.log",
# so we match by suffix, not exact name.
WANT_SUFFIXES = ("application_000.log", "output_000.log", "backend_000.log")

# Header line: "TS|version|Level|channel|source|message". Level is field [2].
TS = re.compile(r"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+\|")
EXTYPE = re.compile(r"([A-Za-z][\w.`+]*(?:Exception|Error))\b")
# A thrown exception carries a stack: a managed frame, an `at `, or a rethrow.
# This is what separates a real crash from a plain Error LOG MESSAGE such as
# "generate profile with same id" or "Item deserialization error" -- both logged
# at Error but recoverable, and killing the game on them is a false positive.
STACKISH = re.compile(r"(?::MoveNext\(|\bMoveNext\s*\(|^\s*at |Rethrow as )", re.M)

# Progress markers that DISARM the matchmaking timer. LocationLoaded fires well
# before MatchingCompleted on a healthy boot (~19s vs ~47s measured), so it MUST
# be here or a healthy load would trip a 35-45s timer.
MATCH_PROGRESS = ("LocationLoaded", "MatchingCompleted", "GameStarted",
                  "GameSpawn", "OnGameStarted")

# Stock, documented-benign noise. If a record matches one of these it is NOT a
# crash no matter what level it was logged at. The prewarm-shot NRE fires on
# EVERY healthy raid load (BallisticCalculatorPrewarmer.SimulateShot) at Warn
# and the game recovers -- measured in a session that went on to reach the raid.
BENIGN = [
    re.compile(r"SpawnPointMarkers? .*(fix message|fixes:)"),
    re.compile(r"Couldn't create a Convex Mesh.*maximum polygons limit"),
    re.compile(r"Non-convex MeshCollider with non-kinematic Rigidbody"),
    re.compile(r"The referenced script.*is missing"),
    re.compile(r"Failed prewarm shot delegate"),
]


def newest_log_dir(logs_root):
    ds = [d for d in glob.glob(os.path.join(logs_root, "log_*")) if os.path.isdir(d)]
    if not ds:
        return None
    return max(ds, key=os.path.getmtime)


def resolve_files(logdir):
    """Map each wanted suffix to its actual (stamp-prefixed) path, if present."""
    out = {}
    try:
        names = os.listdir(logdir)
    except OSError:
        return out
    for suf in WANT_SUFFIXES:
        for n in names:
            if n.endswith(suf):
                out[suf] = os.path.join(logdir, n)
                break
    return out


def is_benign(text):
    return any(rx.search(text) for rx in BENIGN)


# Unity's own logging helpers end in "Error"/"Exception" but are not the thrown
# type; don't let them win the "what threw" label over a real *Exception.
_NOISE_TYPES = ("LogError", "LogException", "LogWarning")


def best_type(record):
    """Best-guess thrown type for the report: prefer a real *Exception."""
    cands = [c for c in EXTYPE.findall(record) if c not in _NOISE_TYPES]
    for c in cands:
        if c.endswith("Exception"):
            return c
    return cands[0] if cands else None


def classify(record, level):
    """Return (signature, detail) for a completed record, or None.

    A record is a header line plus its unindented stack continuations. `level`
    is the header's Level field. Ordered most-specific first so the report names
    the useful signature rather than the generic one.
    """
    if is_benign(record):
        return None

    if re.search(r"A task was canceled|TaskCanceledException", record):
        return ("raid-load-abort", "the raid-load task was canceled")

    if re.search(r"One or more errors occurred|AggregateException", record):
        return ("aggregate-exception", best_type(record) or "AggregateException")

    # Two conditions, both measured:
    #  * LEVEL gates first. A healthy session that still reaches the raid emits
    #    exception TYPES and MoveNext/SetException stacks at Warn ("Failed
    #    prewarm shot delegate") and Info (a matchmaking stack dump), but ZERO
    #    Error/Fatal/Critical lines -- so anything below Error is not a crash.
    #  * STRUCTURE gates second. Not every Error line is a thrown exception:
    #    "generate profile with same id", "Item deserialization error",
    #    "bot creation data with zero profiles" are all logged at Error and are
    #    recoverable. A real crash names an exception type OR carries a stack.
    if level in ("Error", "Fatal", "Critical"):
        t = best_type(record)
        if t or STACKISH.search(record):
            return ("unhandled-exception", t or (level or "error"))

    return None


class Tailer:
    """Follows one file from a byte offset, assembling multi-line records.

    Never reads the whole file: seeks once, then reads only appended bytes. Keeps
    a small ring of recent raw lines for the report's context window.
    """

    def __init__(self, path, from_start=False, ring=48):
        self.path = path
        self.leftover = ""
        self.rec = []          # current record: header + continuations
        self.rec_level = ""
        self.ring = deque(maxlen=ring)
        try:
            self.pos = 0 if from_start else os.path.getsize(path)
        except OSError:
            self.pos = 0

    def _finish_record(self):
        if not self.rec:
            return None
        text = "\n".join(self.rec)
        level, out = self.rec_level, None
        sig = classify(text, level)
        if sig:
            out = (sig, text)
        self.rec = []
        self.rec_level = ""
        return out

    def poll(self):
        """Read new bytes; yield (signature, detail, record_text) for hits.

        A record is closed when the NEXT timestamped header arrives. A trailing
        record with no following header is closed by flush() on idle.
        """
        try:
            size = os.path.getsize(self.path)
        except OSError:
            return
        if size < self.pos:          # rotated/truncated -> restart at top
            self.pos = 0
            self.leftover = ""
            self.rec = []
        if size == self.pos:
            return
        with open(self.path, "r", encoding="utf-8", errors="replace") as f:
            f.seek(self.pos)
            data = f.read()
            self.pos = f.tell()
        data = self.leftover + data
        lines = data.split("\n")
        self.leftover = lines.pop()   # last element is a partial line
        for raw in lines:
            line = raw.rstrip("\r")
            self.ring.append(line)
            if TS.match(line):
                done = self._finish_record()
                if done:
                    sig, text = done
                    yield sig[0], sig[1], text
                self.rec = [line]
                parts = line.split("|")
                self.rec_level = parts[2] if len(parts) > 2 else ""
            elif self.rec:
                self.rec.append(line)

    def flush(self):
        """Close a dangling trailing record (call on idle)."""
        done = self._finish_record()
        if done:
            sig, text = done
            return sig[0], sig[1], text
        return None

    def tail_lines(self, n=15):
        return list(self.ring)[-n:]


class MatchWatch:
    """Arms on a NetworkGameMatching trace, disarms on a raid-start marker.

    Fires once if armed longer than `timeout`. The softest signature here: on a
    slow box a genuine load could exceed the timer. Kept conservative (disarms on
    the earliest progress marker, LocationLoaded) and the timeout is tunable.
    """

    def __init__(self, timeout):
        self.timeout = timeout
        self.armed_at = None

    def feed(self, line):
        if any(p in line for p in MATCH_PROGRESS):
            self.armed_at = None
            return
        if "NetworkGameMatching" in line:
            self.armed_at = time.time()

    def expired(self):
        if self.armed_at is None:
            return False
        return (time.time() - self.armed_at) > self.timeout


def kill_game(dry_run):
    names = ",".join(PROCS)
    if dry_run:
        return "DRY-RUN: would kill " + names
    cmd = ("Get-Process -Name %s -ErrorAction SilentlyContinue "
           "| Stop-Process -Force" % names)
    try:
        subprocess.run(["powershell", "-NoProfile", "-NonInteractive",
                        "-Command", cmd], capture_output=True, timeout=30)
    except Exception as e:
        return "kill attempted, but PowerShell errored: %s" % e
    return "killed " + names


def report(signature, detail, record, log_path, tail, action):
    line = "=" * 68
    print("\n" + line)
    print(" AFTER-CRASH REPORT")
    print(line)
    print(" time      : %s" % time.strftime("%Y-%m-%d %H:%M:%S"))
    print(" signature : %s (%s)" % (signature, detail))
    print(" log file  : %s" % log_path)

    # The header line of the triggering record, then a short stack excerpt.
    reclines = [l for l in record.split("\n") if l.strip()]
    if reclines:
        head = reclines[0]
        # Trim the log prefix for readability. output records have 6 pipe fields
        # (TS|ver|Level|output|source|msg); application records have 5
        # (TS|ver|Level|application|msg).
        parts = head.split("|")
        if len(parts) >= 6:
            msg = "|".join(parts[5:])
        elif len(parts) >= 5:
            msg = "|".join(parts[4:])
        else:
            msg = head
        print(" exception : %s" % msg.strip()[:200])
    stack = [l.strip() for l in reclines[1:] if l.strip()][:6]
    if stack:
        print(" stack     :")
        for s in stack:
            print("   %s" % s[:160])

    print(" last %2d   :" % len(tail))
    for l in tail:
        print("   %s" % l[:160])

    print(" action    : %s" % action)
    print(line + "\n")
    sys.stdout.flush()


def build_tailers(logdir, from_start):
    files = resolve_files(logdir)
    if not files:
        return None, {}
    tailers = {suf: Tailer(p, from_start=from_start) for suf, p in files.items()}
    return files, tailers


def run(args):
    logs_root = args.logs
    cur_dir = newest_log_dir(logs_root)
    if not cur_dir:
        print("no log_* directory under %s -- is the client installed there?"
              % logs_root)
        return 2
    print("crashwatch: watching %s" % cur_dir)
    files, tailers = build_tailers(cur_dir, args.scan_existing)
    if not tailers:
        print("no client logs (%s) in that dir yet; will keep looking"
              % ", ".join(WANT_SUFFIXES))
    match = MatchWatch(args.match_timeout) if not args.no_matchmaking else None

    last_idle_flush = time.time()
    last_dir_check = time.time()

    while True:
        hit = None
        for suf, t in list(tailers.items()):
            for sig, detail, text in t.poll():
                hit = (sig, detail, text, t)
                break
            if hit:
                break
            if match is not None:
                for line in list(t.ring)[-4:]:
                    match.feed(line)
        now = time.time()

        # Close dangling trailing records if the log paused mid-record.
        if not hit and now - last_idle_flush > 2.0:
            last_idle_flush = now
            for suf, t in tailers.items():
                f = t.flush()
                if f:
                    hit = (f[0], f[1], f[2], t)
                    break

        if not hit and match is not None and match.expired():
            # Attribute it to the application log (where the trace lives).
            at = tailers.get("application_000.log")
            src = at or next(iter(tailers.values()), None)
            tail = src.tail_lines(15) if src else []
            path = files.get("application_000.log", cur_dir) if files else cur_dir
            action = kill_game(args.dry_run)
            report("matchmaking-timeout",
                   "no raid start within %ds of a NetworkGameMatching trace"
                   % args.match_timeout, "", path, tail, action)
            match.armed_at = None
            if not args.watch:
                return 1
            continue

        if hit:
            sig, detail, text, t = hit
            action = kill_game(args.dry_run)
            report(sig, detail, text, t.path, t.tail_lines(15), action)
            if match is not None:
                match.armed_at = None
            if not args.watch:
                return 1
            # In --watch, keep going; a relaunch makes a new dir we pick up below.

        # In --watch mode, notice a newer session dir (a relaunch) and switch.
        if args.watch and now - last_dir_check > 5.0:
            last_dir_check = now
            nd = newest_log_dir(logs_root)
            if nd and nd != cur_dir:
                print("crashwatch: newer session dir, switching -> %s" % nd)
                cur_dir = nd
                # Fresh session: read from the start of the new dir's files so a
                # crash during early boot is not missed.
                files, tailers = build_tailers(cur_dir, from_start=True)
                if match is not None:
                    match.armed_at = None
            elif not tailers:
                files, tailers = build_tailers(cur_dir, args.scan_existing)

        time.sleep(args.interval)


def main():
    p = argparse.ArgumentParser(
        description="watch the live EFT client's logs; kill + report on a crash",
        formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    p.add_argument("--logs", default=DEFAULT_LOGS,
                   help="client log root (default %s)" % DEFAULT_LOGS)
    p.add_argument("--watch", action="store_true",
                   help="keep monitoring across relaunches (default: one-shot)")
    p.add_argument("--dry-run", action="store_true",
                   help="detect and report, but do NOT kill the game")
    p.add_argument("--scan-existing", action="store_true",
                   help="also scan text already in the newest dir at start "
                        "(off by default so a stale crash can't kill a "
                        "freshly relaunched game)")
    p.add_argument("--match-timeout", type=int, default=45,
                   help="seconds a NetworkGameMatching trace may stay unresolved "
                        "before it counts as a hang (default 45)")
    p.add_argument("--no-matchmaking", action="store_true",
                   help="disable the (softest) matchmaking-timeout signature")
    p.add_argument("--interval", type=float, default=0.5,
                   help="poll interval in seconds (default 0.5)")
    args = p.parse_args()
    try:
        return run(args)
    except KeyboardInterrupt:
        print("\ncrashwatch: stopped")
        return 130


if __name__ == "__main__":
    sys.exit(main())
