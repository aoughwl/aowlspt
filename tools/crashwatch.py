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
  * matchmaking-timeout    a NetworkGameMatching trace armed, then ZERO load
                           progress of ANY kind for --match-timeout seconds
                           (default 150). Load progress = the raid is loading,
                           not a matchmaking hang, so ANYTHING loading disarms
                           it: geometry/asset loads, scene/location progress,
                           prewarm, a raid-start marker. Measured: a healthy
                           OFFLINE Woods load emits a NetworkGameMatching trace
                           (it resolves offline) and then does not touch geometry
                           for ~47s -- so an earlier 45s/raid-marker-only version
                           killed a perfectly healthy load. This signature now
                           fires ONLY when nothing loads at all for 150s+, which
                           is a genuinely stuck matchmaking with no assets moving.

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
#
# `errors_000.log` was NOT in this list until 2026-08-31, and that omission is
# most of why two wrong-type defects in one day were found by the USER reading a
# modal dialog rather than by us. MEASURED: the client's own errors_000.log
# carries the deserialization message with its JSON PATH intact, e.g.
#   JsonSerializationException: Error converting value False to type
#   'ChatShared.ChatMessageSystemData'. Path 'data[0].message.systemData',
#   line 1, position 473.
# -- which is the same string class as the dialog the player sees. The dialog
# text is therefore NOT unreachable; we simply were not reading the file.
WANT_SUFFIXES = ("application_000.log", "output_000.log", "backend_000.log",
                 "errors_000.log")

# Header line: "TS|version|Level|channel|source|message". Level is field [2].
TS = re.compile(r"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+\|")
EXTYPE = re.compile(r"([A-Za-z][\w.`+]*(?:Exception|Error))\b")
# A thrown exception carries a stack: a managed frame, an `at `, or a rethrow.
# This is what separates a real crash from a plain Error LOG MESSAGE such as
# "generate profile with same id" or "Item deserialization error" -- both logged
# at Error but recoverable, and killing the game on them is a false positive.
STACKISH = re.compile(r"(?::MoveNext\(|\bMoveNext\s*\(|^\s*at |Rethrow as )", re.M)

# ANY of these DISARMS the matchmaking timer: the raid is loading, not hung.
# Deliberately broad -- the failure mode we are fixing is over-firing, and a
# NetworkGameMatching trace appears even in a healthy OFFLINE load (it resolves
# offline), so its mere presence is NOT a hang. A healthy offline Woods load can
# go ~47s from the matchmaking trace to the first geometry load with nothing in
# between, so the timeout is long (150s) AND anything loading clears it.
# Substrings, matched anywhere in a line (case-insensitive via LOAD_PROGRESS_RX).
MATCH_PROGRESS = (
    # raid-start / handshake milestones
    "LocationLoaded", "MatchingCompleted", "GameStarted", "GameSpawn",
    "OnGameStarted", "GamePrepared", "GameCreated", "PlayerSpawn",
    # asset / geometry / scene loading -- the raid is actively coming up
    "loaded Geometry", "[Geometry]", "MetaXRAcoustic", "StreamingAssets",
    "Loading ", "prewarm", "scene preset", "SceneLoad", "LevelLoad",
    "loading level", "bundle",
)
LOAD_PROGRESS_RX = re.compile(
    "|".join(re.escape(s) for s in MATCH_PROGRESS), re.IGNORECASE)

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


# A payload WE SERVED did not match the DTO the client declared. Newtonsoft
# throws rather than degrading, the client raises a MODAL DIALOG, and the player
# reads a message far more specific than any stack frame:
#   "error reading integer. unexpected token: Boolean.
#    Path '[0].Quests[558].availableAfter'"
# Both wrong-type defects on 2026-08-31 were found this way -- by a human typing
# the dialog out -- and neither appeared in the host log. This signature exists
# so the JSON PATH lands in a file we own, automatically.
#
# It is deliberately NOT gated on level and does NOT require a stack: the value
# of the record is the message, and requiring `STACKISH` would drop the bare
# reader errors, which are the most actionable of all.
DATA_ERROR = re.compile(
    r"Json(?:Reader|Serialization|Writer)Exception"
    r"|error reading \w+\. unexpected token"
    r"|Error converting value .* to type"
    r"|Unexpected character encountered while parsing"
    r"|Cannot deserialize the current JSON",
    re.IGNORECASE)
# The bit worth putting in front of a human: the JSON path into OUR payload.
DATA_PATH = re.compile(r"Path '([^']+)'")


def classify(record, level):
    """Return (signature, detail) for a completed record, or None.

    A record is a header line plus its unindented stack continuations. `level`
    is the header's Level field. Ordered most-specific first so the report names
    the useful signature rather than the generic one.
    """
    if is_benign(record):
        return None

    # First, and above the level gate: a shape mismatch in a payload we served.
    if DATA_ERROR.search(record):
        m = DATA_PATH.search(record)
        return ("served-payload-shape",
                ("wrong JSON type at %s" % m.group(1)) if m
                else "the client could not deserialize a payload we served")

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

    def poll(self, on_line=None):
        """Read new bytes; yield (signature, detail, record_text) for hits.

        A record is closed when the NEXT timestamped header arrives. A trailing
        record with no following header is closed by flush() on idle. `on_line`,
        if given, is called with every raw line exactly once (used to feed the
        matchmaking watcher without re-slicing the ring).
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
            if on_line is not None:
                on_line(line)
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
    """Fires only when NOTHING loads for `timeout` seconds after a matchmaking
    trace -- i.e. a genuinely stuck matchmaking with no assets moving.

    Arms on a NetworkGameMatching trace. Disarms the moment ANY load-progress
    line appears (LOAD_PROGRESS_RX: geometry/asset/scene/prewarm/raid-start),
    because that means the raid IS loading. So a surviving armed timer past the
    timeout means zero progress happened in the whole window. The clock is
    injected (`now`) so this is deterministically testable against a static log.
    """

    def __init__(self, timeout):
        self.timeout = timeout
        self.armed_at = None

    def feed(self, line, now=None):
        if LOAD_PROGRESS_RX.search(line):
            self.armed_at = None
            return
        if "NetworkGameMatching" in line:
            # Arm only if not already counting -- keep the ORIGINAL arm time so a
            # repeated trace with no progress does not perpetually reset the clock.
            if self.armed_at is None:
                self.armed_at = time.time() if now is None else now

    def expired(self, now=None):
        if self.armed_at is None:
            return False
        t = time.time() if now is None else now
        return (t - self.armed_at) > self.timeout


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


# Signatures that must NOT kill the client. A shape mismatch raises a modal
# dialog and the session survives; killing the game on one would destroy both
# the player's session and the evidence on screen. The point of catching these
# is to WRITE THEM DOWN, not to intervene.
NOKILL = frozenset(["served-payload-shape"])

# Where a finding is written so it survives the session. Deliberately NOT the
# host log: the backend holds `aowlspt-host.log` open and a second writer
# appending to it interleaves records. This is a sibling file in the same
# directory, in the same `LEVEL|source|message` spirit, so `hostlog.py`-style
# habits still read it.
DEFAULT_SINK = "D:/Aowlspt/aowlspt/aowlspt-clienterr.log"
_sink = None


def sink_open(path):
    """Open the sink and stamp it. The stamp is the ARMED PROOF.

    crashwatch was once reported as "armed" for a whole session while it was
    not running at all -- `| head -3` closed its stdout, SIGPIPE killed it, and
    exit 0 read as success. A watcher whose only evidence of life is the claim
    that it was started is not evidence. A dated line in a file is.
    """
    global _sink
    if not path:
        return None
    try:
        d = os.path.dirname(path)
        if d and not os.path.isdir(d):
            os.makedirs(d, exist_ok=True)
        _sink = open(path, "a", encoding="utf-8", errors="replace")
    except OSError as e:
        print("crashwatch: CANNOT open sink %s (%s) -- findings will go to "
              "stdout ONLY, and stdout is not evidence" % (path, e))
        _sink = None
        return None
    _sink.write("%s|INFO|crashwatch|armed, watching the client's logs\n"
                % time.strftime("%Y-%m-%d %H:%M:%S"))
    _sink.flush()
    return _sink


def emit(s=""):
    print(s)
    if _sink is not None:
        try:
            _sink.write(s + "\n")
        except (OSError, ValueError):
            pass


def report(signature, detail, record, log_path, tail, action):
    line = "=" * 68
    # The one line meant to be SEEN, first, at error level so nothing that
    # filters on change or on level can suppress it.
    emit("%s|ERROR|crashwatch|%s: %s"
         % (time.strftime("%Y-%m-%d %H:%M:%S"), signature, detail))
    emit("\n" + line)
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
        # To the SINK as well: for a shape mismatch this line IS the dialog the
        # player sees, and it is the only part that names the field.
        emit(" exception : %s" % msg.strip()[:400])
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


def replay(args):
    """Run the classifier over an ALREADY-WRITTEN log dir and report every hit.

    This is how the watcher is proved against reality without a running game:
    point it at a session that is known to have gone wrong and see whether it
    names the thing that went wrong. It never kills anything.
    """
    logdir = args.replay
    if not os.path.isdir(logdir):
        print("no such log dir: %s" % logdir)
        return 2
    sink_open(args.out)
    files, tailers = build_tailers(logdir, from_start=True)
    if not tailers:
        print("no client logs (%s) in %s" % (", ".join(WANT_SUFFIXES), logdir))
        return 2
    print("crashwatch: REPLAY over %s (%d file(s))" % (logdir, len(tailers)))
    n = 0
    for suf, t in tailers.items():
        while True:
            got = list(t.poll())
            if not got:
                f = t.flush()
                if f:
                    got = [f]
                else:
                    break
            for sig, detail, text in got:
                n += 1
                report(sig, detail, text, t.path, t.tail_lines(6),
                       "REPLAY: nothing was killed")
    print("crashwatch: replay found %d finding(s)" % n)
    return 0 if n else 3


def run(args):
    logs_root = args.logs
    cur_dir = newest_log_dir(logs_root)
    if not cur_dir:
        print("no log_* directory under %s -- is the client installed there?"
              % logs_root)
        return 2
    sink_open(args.out)
    print("crashwatch: watching %s" % cur_dir)
    if args.out:
        print("crashwatch: findings also appended to %s" % args.out)
    files, tailers = build_tailers(cur_dir, args.scan_existing)
    if not tailers:
        print("no client logs (%s) in that dir yet; will keep looking"
              % ", ".join(WANT_SUFFIXES))
    match = MatchWatch(args.match_timeout) if not args.no_matchmaking else None

    last_idle_flush = time.time()
    last_dir_check = time.time()

    while True:
        hit = None
        feed = match.feed if match is not None else None
        for suf, t in list(tailers.items()):
            for sig, detail, text in t.poll(on_line=feed):
                hit = (sig, detail, text, t)
                break
            if hit:
                break
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
                   "no load progress at all within %ds of a NetworkGameMatching "
                   "trace" % args.match_timeout, "", path, tail, action)
            match.armed_at = None
            if not args.watch:
                return 1
            continue

        if hit:
            sig, detail, text, t = hit
            if sig in NOKILL:
                action = ("left the game RUNNING on purpose: a payload-shape "
                          "error raises a dialog the session survives, and "
                          "killing it would destroy the evidence on screen")
            else:
                action = kill_game(args.dry_run)
            report(sig, detail, text, t.path, t.tail_lines(15), action)
            if match is not None:
                match.armed_at = None
            # A NOKILL finding never ends the watch: there may be more, and the
            # player is still playing.
            if not args.watch and sig not in NOKILL:
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


# Every case below is either TEXT LIFTED FROM A REAL CLIENT LOG or the exact
# dialog a human transcribed. The negatives matter as much as the positives: a
# watcher that fires on healthy noise gets turned off, and a turned-off watcher
# is the state we are trying to leave.
SELFTEST = [
    # (label, record, level, expected signature or None)
    ("the 2026-08-31 dialog, verbatim from the player",
     "2026-08-31 12:00:00.000|1.1.0|Error|output|x|"
     "error reading integer. unexpected token: Boolean. "
     "Path '[0].Quests[558].availableAfter', line 1, position 90212.",
     "Error", "served-payload-shape"),
    ("the same message logged at Info -- level must NOT gate this signature",
     "2026-08-31 12:00:00.000|1.1.0|Info|output|x|"
     "error reading integer. unexpected token: Boolean. "
     "Path '[0].Quests[558].availableAfter'.",
     "Info", "served-payload-shape"),
    ("lifted from log_2026.08.27_12-25-52 errors_000.log",
     "2026-08-27 12:25:52.000|1.1.0|Error|output|x|JsonSerializationException: "
     "Error converting value False to type 'ChatShared.ChatMessageSystemData'. "
     "Path 'data[0].message.systemData', line 1, position 473.",
     "Error", "served-payload-shape"),
    ("a real crash still classifies as one",
     "2026-08-31 12:00:00.000|1.1.0|Error|output|x|NullReferenceException: "
     "Object reference not set\n  at EFT.Foo.Bar ()",
     "Error", "unhandled-exception"),
    ("the benign prewarm NRE fires on EVERY healthy raid load",
     "2026-08-31 12:00:00.000|1.1.0|Error|output|x|Failed prewarm shot "
     "delegate: NullReferenceException\n  at BallisticCalculatorPrewarmer ()",
     "Error", None),
    ("an ordinary Error LOG MESSAGE is not a crash",
     "2026-08-31 12:00:00.000|1.1.0|Error|output|x|generate profile with "
     "same id", "Error", None),
]


def selftest():
    """Assert the classifier's verdicts on recorded text. Falsifiable: each
    case names an EXPECTED signature, and both a miss and a false positive
    fail. A watcher that has never been shown to catch anything is
    INCONCLUSIVE, not PASS."""
    bad = 0
    for label, rec, level, want in SELFTEST:
        got = classify(rec, level)
        sig = got[0] if got else None
        ok = (sig == want)
        if not ok:
            bad += 1
        print("%-4s %-58s want=%-22s got=%s"
              % ("ok" if ok else "FAIL", label[:58], want, sig))
    # And the part that carries the whole point: the JSON path must survive.
    got = classify(SELFTEST[0][1], "Error")
    if not got or "[0].Quests[558].availableAfter" not in got[1]:
        print("FAIL the JSON path did not reach the reported detail -- the "
              "path is the ONLY part that names the broken field")
        bad += 1
    else:
        print("ok   detail carries the JSON path: %s" % got[1])
    print("\n%s: %d case(s) failed" % ("FAIL" if bad else "PASS", bad))
    return 1 if bad else 0


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
    p.add_argument("--match-timeout", type=int, default=150,
                   help="seconds with ZERO load progress after a "
                        "NetworkGameMatching trace before it counts as a hang "
                        "(default 150; a healthy offline load can idle ~47s "
                        "between the trace and the first geometry load)")
    p.add_argument("--no-matchmaking", action="store_true",
                   help="disable the (softest) matchmaking-timeout signature")
    p.add_argument("--interval", type=float, default=0.5,
                   help="poll interval in seconds (default 0.5)")
    p.add_argument("--out", default=DEFAULT_SINK,
                   help="append findings to this file as well as stdout "
                        "(default %s); pass '' to disable" % DEFAULT_SINK)
    p.add_argument("--replay", metavar="LOGDIR",
                   help="classify an already-written log_* dir and exit; "
                        "kills nothing. Exit 0 = found something, 3 = clean")
    p.add_argument("--selftest", action="store_true",
                   help="feed recorded real client error text through the "
                        "classifier and assert the verdicts; needs no game")
    args = p.parse_args()
    if args.selftest:
        return selftest()
    if args.replay:
        return replay(args)
    try:
        return run(args)
    except KeyboardInterrupt:
        print("\ncrashwatch: stopped")
        return 130


if __name__ == "__main__":
    sys.exit(main())
