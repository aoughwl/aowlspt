#!/usr/bin/env python3
r"""crashwatch.py - watch the live EFT client's logs and report what went wrong.

IT DOES NOT KILL ANYTHING UNLESS YOU ARM IT. That is a change, and it is the
whole point of the 2026-08-31 rewrite: `--watch` used to force-kill the game on
every signature, and the kill left NO trace -- aowlspt-clienterr.log held only
`armed, watching the client's logs` lines. Four instances accumulated in one
day, each killing a live client every few minutes, and an hour went into
bisecting the user's code against a killer that was constant in every arm.
Every bisect "reproduced" the failure, which felt like signal and was noise.

So now: observe-only by default; `--kill-on SIG` / `--kill-any` to arm; a kill
is the loudest line the tool ever writes (signature, matched text, PIDs, to the
sink and to stdout); the `armed` line states whether THIS instance can kill; and
a second `--watch` instance is refused unless you pass --allow-duplicates.

This watcher tails the CLIENT's OWN logs under D:\Aowlspt\Logs, AND the host log
for the one thing the client's logs can never show: the in-game error dialog
(`--no-host` turns that half off). It never reads a whole log: it seeks to the
current end and reads only new bytes as they are written, so a 230 KB
output_000.log costs nothing.

    python tools/crashwatch.py               # one-shot: observe + report, exit
    python tools/crashwatch.py --watch       # keep observing across relaunches
    python tools/crashwatch.py --watch --kill-on matchmaking-timeout
                                             # ARM the kill, for ONE signature
    python tools/crashwatch.py last [N]      # the morning read: the newest N
                                             # UNITY CRASH REPORTS, each with
                                             # the module its crash site is in
    python tools/crashwatch.py symbolize-host <dmp|Crash_dir>
                                             # our OWN frames as function
                                             # names: picks the DLL build that
                                             # was actually loaded (PE
                                             # TimeDateStamp vs every .bak-*),
                                             # reads its COFF symbols with
                                             # objdump -t, and scrapes the
                                             # stack when the walk collapses.
                                             # `last` and `wer` run it for you.
    python tools/crashwatch.py --selftest    # prove both halves; needs no game
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
  * in-game-error-dialog   an ERRORDIALOG line in the HOST log (not a client
                           log -- the client does not consider a modal error
                           window an error and logs nothing). This is the case
                           that used to be invisible: the process stays alive,
                           no Error record is written, and the game sits on the
                           dialog forever waiting for a click that no unattended
                           run will ever make. A dialog is a crash with a button
                           on it, so it is treated as one. Needs the host's
                           `catchErrorDialogs` feature, which is ON by default.
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
import bisect
import datetime
import glob
import hashlib
import os
import re
import struct
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
DEFAULT_HOST_LOG = "D:/Aowlspt/aowlspt/aowlspt-host.log"
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

# `errors_000.log` is the client's OWN error channel. Anything the client itself
# decided was an error is in there and nothing else is -- so the reporting rule
# for this file is UNCONDITIONAL: every `|Error|` (or worse) header is reported
# with its stack, and `classify` only supplies a LABEL. Classification must never
# be the thing that decides whether to report; that inversion is exactly what let
# two real 2026-08-31 errors pass a watcher that was provably running.
ALWAYS_SUFFIXES = ("errors_000.log",)
ALWAYS_LEVELS = ("Error", "Fatal", "Critical", "Exception")

# How many floor-level records the BENIGN allowlist swallowed. Reported, always.
_benign_suppressed = 0

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
    # Stock rigging noise: the client logs a missing attachment bone at Error for
    # every helmet/rig prefab it pools. 60+ per raid load on a healthy session
    # (measured across log_2026.08.27_12-25-52), and the raid loads fine.
    re.compile(r"bone \w+ not found in GameObject"),
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
# Bare "Error"/"Exception" match EXTYPE out of ordinary prose -- "Error while
# starting matching: ..." yielded the label "Error", which names nothing. Drop
# them so the fallback below uses the MESSAGE, which does.
_NOISE_TYPES = ("LogError", "LogException", "LogWarning", "Error", "Exception")


def _head_message(record):
    """The message field of a record's header line, for use as a label."""
    first = next((l for l in record.split("\n") if l.strip()), "")
    parts = first.split("|")
    return ("|".join(parts[4:]).strip() if len(parts) > 4 else first.strip())


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
            return ("unhandled-exception",
                    t or _head_message(record)[:160] or (level or "error"))

    return None


class Tailer:
    """Follows one file from a byte offset, assembling multi-line records.

    Never reads the whole file: seeks once, then reads only appended bytes. Keeps
    a small ring of recent raw lines for the report's context window.
    """

    def __init__(self, path, from_start=False, ring=48, always=False):
        self.path = path
        # `always`: this file is the client's own error channel, so every
        # Error-level record is reported regardless of what `classify` says.
        self.always = always
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
        if (not sig and self.always and level in ALWAYS_LEVELS
                and is_benign(text)):
            # The ONE thing allowed to suppress a floor report: the explicit,
            # reviewed BENIGN allowlist. It is counted, not silent -- the count
            # is printed at the end of every replay and every watch, so a
            # too-greedy allowlist is visible instead of being the new blind spot.
            global _benign_suppressed
            _benign_suppressed += 1
        elif not sig and self.always and level in ALWAYS_LEVELS:
            # The floor. `classify` declined -- benign-listed, no exception type,
            # no recognised stack shape -- but the CLIENT logged it to its own
            # error channel, so it is reported anyway, with a label that says the
            # classifier had nothing to add. It is NOKILL precisely because the
            # classifier could not vouch for it: report, never intervene.
            sig = ("client-error", _head_message(text)[:200] or level)
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


def list_pids(names=None):
    """(pid, name) for every live game process. Read-only; kills nothing."""
    names = names or PROCS
    cmd = ("Get-Process -Name %s -ErrorAction SilentlyContinue "
           "| ForEach-Object { \"$($_.Id) $($_.ProcessName)\" }"
           % ",".join(names))
    try:
        r = subprocess.run(["powershell", "-NoProfile", "-NonInteractive",
                            "-Command", cmd], capture_output=True, timeout=30,
                           text=True)
    except Exception:
        return []
    out = []
    for line in (r.stdout or "").splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0].isdigit():
            out.append((int(parts[0]), parts[1]))
    return out


def kill_game(signature, detail, procs=None, killer=None):
    """Force-kill the game and LEAVE A LOUD, PERMANENT RECORD OF DOING SO.

    THE 2026-08-31 P0. This function used to be called unconditionally on every
    signature, and it wrote NOTHING to the sink -- the only lines in
    aowlspt-clienterr.log were `armed, watching the client's logs`. So a client
    this tool had force-killed was indistinguishable from a client that had
    crashed: no exception, no dump, the log simply stopping. An hour of
    bisecting the USER's code went into chasing a killer that was constant in
    every arm, and every bisect "reproduced" the failure.

    Two rules follow, and they are the whole fix:
      1. Nothing calls this unless the operator armed the signature by name
         (--kill-on / --kill-any). Observe-only is the default.
      2. A kill is the LOUDEST line this tool ever writes: the signature, the
         matched text, and the PIDs it actually killed, to the sink AND stdout.
         `procs`/`killer` are injected so the selftest can prove both halves --
         that observe-only leaves a fixture process alive, and that an armed
         kill is recorded -- without touching a real client.
    """
    procs = procs if procs is not None else PROCS
    victims = list_pids(procs) if killer is None else killer("list", procs)
    # THE MACHINE-READABLE HALF of rule 2, added 2026-09-02. The loud sink line
    # below is for a human reading this tool's own log; the ledger is what
    # run.py reads back, so a client killed here is reported as KILLED-BY-TOOL
    # rather than as a crash. Written BEFORE the kill, and never allowed to
    # raise: bookkeeping must not be able to block a kill.
    #
    # ONLY on a REAL kill (`killer is None`). The selftest injects `killer` and
    # stops nothing; writing a ledger entry there would tell run.py that
    # crashwatch had killed a client it never touched -- a fabricated
    # attribution, which is the exact failure this ledger exists to prevent.
    if killer is None:
        try:
            sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
            import runledger as _rl
            _rl.record("crashwatch.py",
                       "force-kill on signature %r (%s)"
                       % (signature, (detail or "")[:120]),
                       pids=[p for p, _n in victims] or None)
        except Exception:
            pass
    names = ", ".join("%s(%d)" % (n, p) for p, n in victims) or "nothing running"
    emit("%s|KILL|crashwatch|FORCE-KILLING THE GAME on signature %r (%s) -- "
         "killed: %s" % (time.strftime("%Y-%m-%d %H:%M:%S"), signature,
                         (detail or "")[:200], names))
    if killer is not None:
        killer("kill", procs)
        return "KILLED (armed on %r): %s" % (signature, names)
    cmd = ("Get-Process -Name %s -ErrorAction SilentlyContinue "
           "| Stop-Process -Force" % ",".join(procs))
    try:
        subprocess.run(["powershell", "-NoProfile", "-NonInteractive",
                        "-Command", cmd], capture_output=True, timeout=30)
    except Exception as e:
        emit("%s|KILL|crashwatch|the kill FAILED: PowerShell errored: %s"
             % (time.strftime("%Y-%m-%d %H:%M:%S"), e))
        return "kill attempted, but PowerShell errored: %s" % e
    return "KILLED (armed on %r): %s" % (signature, names)


def kill_decision(sig, args):
    """(should_kill, action_text) -- the ONE place that decides.

    Default: observe only. `--kill-any` arms every killable signature;
    `--kill-on SIG` arms named ones. NOKILL signatures are never killable, no
    matter what was armed, because the classifier did not vouch for them.
    """
    if sig in NOKILL:
        return False, ("OBSERVED ONLY: %s is never killable -- the session "
                       "survives it and killing would destroy the evidence "
                       "on screen" % sig)
    if args.kill_any or sig in set(args.kill_on or []):
        if args.dry_run:
            return False, ("DRY-RUN: armed on %r, would have force-killed %s"
                           % (sig, ",".join(PROCS)))
        return True, None
    return False, ("OBSERVED ONLY: killing is not armed for %r "
                   "(pass --kill-on %s, or --kill-any, to arm it)" % (sig, sig))


# Signatures that must NOT kill the client. A shape mismatch raises a modal
# dialog and the session survives; killing the game on one would destroy both
# the player's session and the evidence on screen. The point of catching these
# is to WRITE THEM DOWN, not to intervene.
# `client-error` joins it for a different reason: it is the FLOOR signature, the
# one raised when the classifier had nothing to say about a line the client
# nonetheless logged as an error. Reporting it is free; killing the game on a
# record nothing vouched for is how a watcher earns being turned off.
NOKILL = frozenset(["served-payload-shape", "client-error"])

# Where a finding is written so it survives the session. Deliberately NOT the
# host log: the backend holds `aowlspt-host.log` open and a second writer
# appending to it interleaves records. This is a sibling file in the same
# directory, in the same `LEVEL|source|message` spirit, so `hostlog.py`-style
# habits still read it.
DEFAULT_SINK = "D:/Aowlspt/aowlspt/aowlspt-clienterr.log"
_sink = None


def sink_open(path, armed_note="killing DISABLED (observe-only)"):
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
    # The armed line STATES WHETHER THIS INSTANCE CAN KILL. Without that, the
    # log cannot answer "could this have killed the client?" without reading
    # the source -- and on 2026-08-31 it could not, so nobody asked.
    _sink.write("%s|INFO|crashwatch|armed (pid %d), watching the client's "
                "logs -- %s\n"
                % (time.strftime("%Y-%m-%d %H:%M:%S"), os.getpid(), armed_note))
    _sink.flush()
    return _sink


def other_watchers():
    """Other live `crashwatch.py --watch` processes, excluding this one.

    Four accumulated unnoticed on 2026-08-31, each one an independent killer.
    A tool that is easy to leave running in the background must say when it
    already is.
    """
    cmd = ("Get-CimInstance Win32_Process -Filter \"Name like 'python%'\" "
           "| ForEach-Object { \"$($_.ProcessId)|$($_.CommandLine)\" }")
    try:
        r = subprocess.run(["powershell", "-NoProfile", "-NonInteractive",
                            "-Command", cmd], capture_output=True, timeout=30,
                           text=True)
    except Exception:
        return None          # could not look -- NOT the same as "none"
    me = os.getpid()
    found = []
    for line in (r.stdout or "").splitlines():
        pid, _, cl = line.partition("|")
        if not pid.strip().isdigit() or int(pid) == me:
            continue
        if "crashwatch" in cl and "--watch" in cl:
            found.append((int(pid), cl.strip()[:120]))
    return found


def emit(s=""):
    print(s)
    if _sink is not None:
        try:
            _sink.write(s + "\n")
        except (OSError, ValueError):
            pass


# The client mirrors its error channel: the SAME exception lands in both
# errors_000.log and output_000.log, so tailing both reported each of the
# 2026-08-31 errors twice. Dedup on (signature, header message) -- NOT on the
# whole record, whose stack depth differs between the two copies. Deliberately
# per-run and unbounded-in-time: a repeat of the same error later in a session
# is genuinely the same finding, and suppressing the echo is what makes the
# report readable enough to keep reading.
_seen = set()


def report(signature, detail, record, log_path, tail, action, dedup=True):
    if dedup:
        key = (signature, _head_message(record)[:200])
        if key in _seen:
            return False
        _seen.add(key)
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
        # To the SINK too. An error without its stack is a rumour: the frames are
        # what say WHERE it came from (SingleOrDefault / IsLeaving named the
        # duplicate-profile cause on 2026-08-31), and the sink is the only copy
        # that outlives the terminal.
        emit(" stack     :")
        for s in stack:
            emit("   %s" % s[:160])

    print(" last %2d   :" % len(tail))
    for l in tail:
        print("   %s" % l[:160])

    print(" action    : %s" % action)
    print(line + "\n")
    sys.stdout.flush()
    return True


class HostTailer:
    """Tail `aowlspt-host.log` for events the CLIENT's own logs cannot show.

    The client logs are BSG's; they say nothing about an in-game error dialog,
    because the client does not consider one an error -- it puts a modal window
    up and waits for a click. From outside that is indistinguishable from the
    game sitting idle at profile-select, which is the normal end state of every
    scripted launch. So the whole class of "it stopped and is showing you a box"
    was invisible to this watcher: the process is alive, no Error record is
    written, and the timeout runs to completion.

    The host's `errdlg` feature (abi/aowlspt_errdlg.h) closes that by detouring
    the three `EFT.UI.PreloaderUI` error-screen entry points read-only and
    writing ONE line per dialog:

        ERRORDIALOG kind=<message|exception|critical> header="..." text="..."

    That marker is the contract, and it is asserted by a deploy marker in
    tools/deploy.json so a rebuild cannot silently drop it.

    This is a much simpler tailer than `Tailer`: the host log is one event per
    line with no multi-line records to reassemble, so there is nothing to
    accumulate. It never reads the whole file -- it seeks to the end on first
    open and reads only what is appended after, so a long-running session costs
    nothing (CLAUDE.md section 8).
    """

    # A dialog is a crash with a button on it. `critical` is the unrecoverable
    # one ("quit to desktop" class); both are fatal for an unattended run.
    ERRDLG = re.compile(r"ERRORDIALOG\s+kind=(\S+)")

    def __init__(self, path, from_start=False):
        self.path = path
        self.pos = 0
        self.leftover = ""
        self.ring = deque(maxlen=200)
        if not from_start:
            try:
                self.pos = os.path.getsize(path)
            except OSError:
                self.pos = 0

    def poll(self):
        """Yield (signature, detail, line) for each new host-log event."""
        try:
            size = os.path.getsize(self.path)
        except OSError:
            return
        if size < self.pos:          # truncated: a relaunch rewrote it
            self.pos = 0
            self.leftover = ""
        if size == self.pos:
            return
        with open(self.path, "r", encoding="utf-8", errors="replace") as f:
            f.seek(self.pos)
            data = f.read()
            self.pos = f.tell()
        data = self.leftover + data
        lines = data.split("\n")
        self.leftover = lines.pop()
        for raw in lines:
            line = raw.rstrip("\r")
            self.ring.append(line)
            m = self.ERRDLG.search(line)
            if not m:
                continue
            kind = m.group(1)
            # The host prints one suppression notice once it has logged its cap,
            # so a client erroring in a loop cannot flood the log. That notice is
            # NOT another dialog and must not be reported as one -- it would put
            # a fabricated extra crash in the report.
            if 'header="<suppressed>"' in line:
                continue
            yield ("in-game-error-dialog",
                   "the client raised a %s error window and is waiting for a "
                   "click; it is not idle" % kind,
                   line)

    def tail_lines(self, n=15):
        return list(self.ring)[-n:]


def build_tailers(logdir, from_start):
    files = resolve_files(logdir)
    if not files:
        return None, {}
    tailers = {suf: Tailer(p, from_start=from_start,
                           always=suf in ALWAYS_SUFFIXES)
               for suf, p in files.items()}
    return files, tailers


def adopt_new_files(logdir, tailers):
    """Pick up wanted logs that did not EXIST when the dir was first scanned.

    THIS IS THE 2026-08-31 BUG. `errors_000.log` is not created with the session
    dir -- MEASURED birth times in log_2026.08.31_17-17-05: output_000.log at
    17:17:05.09 (with the dir), errors_000.log at 17:17:39.174, which is the
    instant of the first error, 34s later. The old loop re-scanned only under
    `elif not tailers:` -- and `tailers` was never empty, because the other three
    files were already there -- so the error channel was never opened for the
    whole life of the session and both of that day's errors were invisible.

    A newly appeared file is tailed FROM THE START unconditionally: everything in
    it was written after we began watching, so none of it is stale.
    """
    added = []
    for suf, path in resolve_files(logdir).items():
        if suf not in tailers:
            tailers[suf] = Tailer(path, from_start=True,
                                  always=suf in ALWAYS_SUFFIXES)
            added.append(suf)
    return added


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
                if report(sig, detail, text, t.path, t.tail_lines(6),
                          "REPLAY: nothing was killed"):
                    n += 1
    print("crashwatch: replay found %d finding(s); %d benign-allowlisted "
          "error record(s) suppressed" % (n, _benign_suppressed))
    return 0 if n else 3


def run(args):
    logs_root = args.logs
    cur_dir = newest_log_dir(logs_root)
    if not cur_dir:
        print("no log_* directory under %s -- is the client installed there?"
              % logs_root)
        return 2
    if args.kill_any:
        armed_note = ("KILLING ARMED for EVERY killable signature (--kill-any)"
                      + (" but --dry-run is set, so nothing will die"
                         if args.dry_run else ""))
    elif args.kill_on:
        armed_note = ("KILLING ARMED for: %s" % ", ".join(args.kill_on)
                      + (" (--dry-run: nothing will die)" if args.dry_run else ""))
    else:
        armed_note = ("killing DISABLED (observe-only) -- this instance CANNOT "
                      "have killed the client")
    sink_open(args.out, armed_note)
    print("crashwatch: watching %s" % cur_dir)
    print("crashwatch: %s" % armed_note)
    if args.out:
        print("crashwatch: findings also appended to %s" % args.out)

    others = other_watchers()
    if others is None:
        print("crashwatch: could NOT enumerate other watchers (WMI query "
              "failed) -- this was not checked, which is not the same as none")
    elif others:
        print("crashwatch: %d OTHER crashwatch --watch instance(s) are already "
              "running:" % len(others))
        for pid, cl in others:
            print("    pid %d  %s" % (pid, cl))
        if not args.allow_duplicates:
            print("crashwatch: REFUSING to start a second watcher. Stop those "
                  "first, or pass --allow-duplicates.")
            return 4
        print("crashwatch: --allow-duplicates given; starting anyway.")
    files, tailers = build_tailers(cur_dir, args.scan_existing)
    if not tailers:
        print("no client logs (%s) in that dir yet; will keep looking"
              % ", ".join(WANT_SUFFIXES))
    match = MatchWatch(args.match_timeout) if not args.no_matchmaking else None

    # The host log, watched alongside the client's own. This is the only source
    # for an in-game error dialog: see HostTailer. It is deliberately tailed from
    # the END by default, exactly like the client logs, so a dialog from a
    # PREVIOUS session cannot kill a freshly relaunched game.
    host = None
    if not args.no_host:
        if os.path.isfile(args.host_log):
            host = HostTailer(args.host_log, from_start=args.scan_existing)
            print("crashwatch: also watching %s for ERRORDIALOG" % args.host_log)
        else:
            # Say so rather than watching nothing quietly. A watcher that is
            # silently not watching is worse than no watcher, because the run
            # looks supervised and is not.
            print("crashwatch: WARNING -- %s does not exist, so in-game error "
                  "dialogs will NOT be detected on this run. An error dialog "
                  "will look like an idle client." % args.host_log)

    last_idle_flush = time.time()
    last_dir_check = time.time()

    while True:
        hit = None
        # The HOST log first. An error dialog is the one failure that nothing
        # else here can see, and it is checked before the client logs so that
        # when a dialog and some incidental client noise land in the same tick,
        # the report names the dialog -- which is the cause and the actionable
        # thing -- rather than whatever exception happened to be logged near it.
        if host is not None:
            for sig, detail, text in host.poll():
                hit = (sig, detail, text, host)
                break
        feed = match.feed if match is not None else None
        if hit is None:
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
            det = ("no load progress at all within %ds of a "
                   "NetworkGameMatching trace" % args.match_timeout)
            do, action = kill_decision("matchmaking-timeout", args)
            if do:
                action = kill_game("matchmaking-timeout", det)
            report("matchmaking-timeout", det, "", path, tail, action)
            match.armed_at = None
            if not args.watch:
                return 1
            continue

        if hit:
            sig, detail, text, t = hit
            # Ask the deduper FIRST. A mirrored echo of an error we already acted
            # on must not trigger a second kill.
            if (sig, _head_message(text)[:200]) in _seen:
                continue
            do, action = kill_decision(sig, args)
            if do:
                action = kill_game(sig, detail)
            report(sig, detail, text, t.path, t.tail_lines(15), action)
            if match is not None:
                match.armed_at = None
            # A NOKILL finding never ends the watch: there may be more, and the
            # player is still playing.
            if not args.watch and sig not in NOKILL:
                return 1
            # In --watch, keep going; a relaunch makes a new dir we pick up below.

        # Rescan the CURRENT dir every tick -- in one-shot mode too, because a
        # log we care about may not exist yet (see adopt_new_files). This used to
        # be gated on `not tailers` and therefore never ran.
        tick = now - last_dir_check > 5.0
        if tick:
            last_dir_check = now
        if tick and cur_dir:
            added = adopt_new_files(cur_dir, tailers)
            for suf in added:
                print("crashwatch: %s appeared, now tailing it from the start"
                      % suf)

        # In --watch mode, notice a newer session dir (a relaunch) and switch.
        if args.watch and tick:
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
    # The two MISSED live errors of 2026-08-31, lifted verbatim. Both classify
    # here and always did -- they were missed because errors_000.log was never
    # opened, not because of the classifier. These cases guard the classifier
    # half; the replay over the two run dirs guards the discovery half.
    ("17:17:39 duplicate-profile crash (log_2026.08.31_17-17-05)",
     "2026-08-31 17:17:39.174|1.1.0.1.46777|Error|errors|"
     "InvalidOperationException: Sequence contains more than one matching "
     "element\nSystem.Linq.Enumerable.SingleOrDefault[TSource] (...)\n"
     "EFT.TarkovApplication.IsLeaving (...)", "Error", "unhandled-exception"),
    ("17:21:21 matching NRE (log_2026.08.31_17-20-40)",
     "2026-08-31 17:21:21.055|1.1.0.1.46777|Error|errors|Error while starting "
     "matching: Object reference not set to an instance of an object.\n"
     "UnityEngine.Debug:LogError(Object)\nEFT.<Ready>d__40:MoveNext()\n"
     "EFT.MatchmakerOperation:OnReadyPressed()", "Error",
     "unhandled-exception"),
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
    bad += kill_selftest()
    print("\n%s: %d case(s) failed" % ("FAIL" if bad else "PASS", bad))
    return 1 if bad else 0


class _Args(object):
    """A stand-in for the parsed argv, so kill_decision can be tested."""
    def __init__(self, **kw):
        self.kill_on = kw.get("kill_on")
        self.kill_any = kw.get("kill_any", False)
        self.dry_run = kw.get("dry_run", False)


def kill_selftest():
    """BOTH HALVES of the P0, each falsifiable.

    Half 1 -- observe-only must NOT kill. Proved against a REAL child process:
    a `python -c "time.sleep(30)"` fixture is started, the observe-only path is
    driven over a crash signature, and the fixture must still be alive. If
    observe-only ever regresses to killing, the fixture dies and this fails.

    Half 2 -- an armed kill must be LOUD. The armed path is driven with an
    injected killer, and the sink text must afterwards contain the signature,
    the detail, and the PIDs. If the kill ever goes silent again -- which is
    exactly what cost an hour on 2026-08-31 -- the sink is missing that line
    and this fails.
    """
    global _sink
    import io
    bad = 0

    def case(label, ok):
        print("%-4s %s" % ("ok" if ok else "FAIL", label))
        return 0 if ok else 1

    # ---- half 1: a real process survives the observe-only path -------------
    fix = subprocess.Popen([sys.executable, "-c",
                            "import time; time.sleep(30)"])
    try:
        killed = []

        def fake_killer(op, procs):
            if op == "list":
                return [(fix.pid, "fixture")]
            killed.append(tuple(procs))
            fix.kill()
            return None

        a = _Args()                       # DEFAULT: nothing armed
        do, action = kill_decision("unhandled-exception", a)
        if do:
            kill_game("unhandled-exception", "x", ["fixture"], fake_killer)
        time.sleep(0.4)
        alive = (fix.poll() is None)
        bad += case("observe-only (no flags): a real fixture process SURVIVES "
                    "-- pid %d alive=%s, decision=%s"
                    % (fix.pid, alive, "OBSERVE" if not do else "KILL"),
                    alive and not do and not killed)
        bad += case("observe-only names why it did not kill: %r"
                    % (action or "")[:60],
                    bool(action) and "not armed" in (action or ""))

        # ---- half 2: the armed kill is loud AND actually kills -------------
        old_sink, _sink = _sink, io.StringIO()
        a = _Args(kill_on=["unhandled-exception"])
        do, _ = kill_decision("unhandled-exception", a)
        act = kill_game("unhandled-exception", "NullReferenceException at Foo",
                        ["fixture"], fake_killer) if do else "(not armed)"
        text = _sink.getvalue()
        _sink = old_sink
        time.sleep(0.4)
        bad += case("--kill-on arms the kill (decision=%s) and it ran" % do,
                    do and bool(killed))
        bad += case("the kill is RECORDED in the sink at KILL level",
                    "|KILL|crashwatch|FORCE-KILLING" in text)
        bad += case("the record names the SIGNATURE",
                    "'unhandled-exception'" in text)
        bad += case("the record names the MATCHED TEXT",
                    "NullReferenceException at Foo" in text)
        bad += case("the record names the PID it killed (%d)" % fix.pid,
                    ("(%d)" % fix.pid) in text)
        bad += case("the fixture process is now GONE",
                    fix.poll() is not None)
        bad += case("the returned action says KILLED: %r" % act[:40],
                    act.startswith("KILLED"))
    finally:
        if fix.poll() is None:
            fix.kill()

    # ---- a NOKILL signature stays unkillable even when --kill-any is on ----
    do, action = kill_decision("served-payload-shape", _Args(kill_any=True))
    bad += case("served-payload-shape is unkillable even with --kill-any",
                not do and "never killable" in (action or ""))
    # ---- and --dry-run does not kill even when armed ----------------------
    do, action = kill_decision("unhandled-exception",
                               _Args(kill_any=True, dry_run=True))
    bad += case("--dry-run with --kill-any still does not kill",
                not do and "DRY-RUN" in (action or ""))
    return bad


# ---------------------------------------------------------------------------
# Unity's own crash reports. MEASURED 2026-09-02.
#
# Four clean-looking client deaths were chased for an hour with no cause while
# Unity's crash handler had already written a full report for each one, under
#
#   %LOCALAPPDATA%\Temp\Battlestate Games\EscapeFromTarkov\Crashes
#       Crash_<yyyy-MM-dd_HHmmssfff>\Player.log   (+ a small crash.dmp)
#
# Nothing in this repo read them. `run.py`'s DIED verdict said only "the client
# process was up and is gone" -- which is true and useless, when the report
# sitting on disk names the module the fault came out of.
#
# Two things about the format, both measured on the two 2026-09-02 reports:
#
#  * THE FOLDER TIMESTAMP IS UTC. Crash_2026-09-02_045033156 is 00:50:33 local.
#    Comparing that name against a local wall clock makes a crash that just
#    happened look ~4h in the future, i.e. "newer than launch" for every launch
#    forever. Every comparison here goes through epoch seconds.
#  * THE STACK SECTION CAN CONTAIN TWO FRAME BLOCKS. It opens with
#    `========== OUTPUTTING STACK TRACE ==================`, then the crash-site
#    frames, and in one of the two reports the symbol handler then dumped
#    `SymInit:` plus the whole loaded-module list INTO the middle of the
#    section, followed by a second, longer walked stack, before
#    `========== END OF STACKTRACE ===========`.
#
# That second point decides the attribution rule, so it is stated rather than
# implied: attribution is taken from the FIRST block -- the crash-site frames.
# The walked block is kept and reported, but a module that appears only there
# is a note, not the verdict. Crash_2026-09-02_045033156 is exactly this case:
# its crash site is two GameAssembly frames, and aowlspt-host-il2cpp appears
# only in the walked stack. Blaming the host off that would be a confident
# wrong answer of the kind CLAUDE.md 9b is about.

DEFAULT_CRASH_ROOT = os.path.join(
    os.environ.get("LOCALAPPDATA", r"C:\Users\Default\AppData\Local"),
    "Temp", "Battlestate Games", "EscapeFromTarkov", "Crashes")
DEFAULT_INSTALL = "D:/Aowlspt/aowlspt"

STACK_BEGIN = "========== OUTPUTTING STACK TRACE =================="
STACK_END = "========== END OF STACKTRACE ==========="
# "0x00007FFB7C61E345 (sain) toJson_0_sethgq4xy1"
FRAME_RX = re.compile(r"^\s*(0x[0-9A-Fa-f]+)\s+\(([^)]*)\)\s*(.*?)\s*$")
# The symbol handler interleaves these with the frames; they annotate the frame
# that follows and must NOT split a block.
FRAME_NOISE_RX = re.compile(r"^\s*(ERROR: Sym\w+|WARNING: Sym\w+)")
CRASH_DIR_RX = re.compile(r"^Crash_(\d{4}-\d\d-\d\d)_(\d{6})(\d{0,3})$")


def crash_dir_epoch(name):
    """Epoch seconds for a Crash_* folder NAME, read as UTC. None if unparsable.

    The UTC part is the whole point -- see the note above.
    """
    m = CRASH_DIR_RX.match(os.path.basename(str(name).rstrip("\\/")))
    if not m:
        return None
    day, hms, ms = m.group(1), m.group(2), m.group(3) or "0"
    try:
        dt = datetime.datetime.strptime(day + "_" + hms, "%Y-%m-%d_%H%M%S")
    except ValueError:
        return None
    dt = dt.replace(tzinfo=datetime.timezone.utc,
                    microsecond=int(ms.ljust(3, "0")) * 1000)
    return dt.timestamp()


def our_modules(install_root=DEFAULT_INSTALL, repo_root=None):
    """The module names on a stack that belong to US, lowercased, no extension.

    Unity prints the module without its extension (`sain`, `GameAssembly`,
    `aowlspt-host-il2cpp`), so these are stems. Sourced from BOTH the deployed
    install (mods/<name>/<name>.dll) and this repo's mods/ directory, so the
    answer does not silently become "nothing is ours" on a machine where
    D:\\Aowlspt is absent -- which would turn every attribution into the top
    frame's module without saying it had stopped looking.
    """
    names = {"aowlspt-host-il2cpp", "aowlspt-backend"}
    if install_root:
        for p in glob.glob(os.path.join(install_root, "mods", "*", "*.dll")):
            names.add(os.path.splitext(os.path.basename(p))[0].lower())
    if repo_root is None:
        repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    moddir = os.path.join(repo_root, "mods")
    if os.path.isdir(moddir):
        for n in os.listdir(moddir):
            if os.path.isdir(os.path.join(moddir, n)):
                names.add(n.lower())
    return names


class Frame(object):
    __slots__ = ("addr", "module", "symbol", "walked")

    def __init__(self, addr, module, symbol, walked=False):
        self.addr, self.module, self.symbol = addr, module, symbol
        self.walked = walked

    def __repr__(self):
        return "%s (%s) %s" % (self.addr, self.module, self.symbol)

    text = property(__repr__)


class CrashReport(object):
    """One Crash_* folder, parsed. Three states, never two.

    `ok` False with `why` set means the folder exists but could not be read as
    a report -- no Player.log, no stack section, no frames. That is
    INCONCLUSIVE ("I could not look"), and callers must not print it as if it
    were an attribution.
    """

    def __init__(self, folder, when=None):
        self.folder = folder
        self.log = os.path.join(folder, "Player.log")
        self.dump = os.path.join(folder, "crash.dmp")
        self.when = when if when is not None else crash_dir_epoch(folder)
        if self.when is None and os.path.isdir(folder):
            self.when = os.path.getmtime(folder)
        self.frames = []          # the crash-site block
        self.walked = []          # everything after the symbol-handler dump
        self.modlines = []        # the loaded-module lines (runtime bases)
        self.ok = False
        self.why = ""
        self._parse()

    # -- parsing ---------------------------------------------------------
    def _parse(self):
        if not os.path.isfile(self.log):
            self.why = "no Player.log in %s" % self.folder
            return
        try:
            with open(self.log, "r", encoding="utf-8", errors="replace") as fh:
                lines = fh.read().splitlines()
        except OSError as e:
            self.why = "could not read %s: %s" % (self.log, e)
            return
        blocks = parse_stack_blocks(lines)
        if blocks is None:
            self.why = ("%s has no %r section -- it is a log, not a crash "
                        "report" % (os.path.basename(self.log), "STACK TRACE"))
            return
        if not blocks:
            self.why = "the stack section of %s contains no frames" % self.log
            return
        # The loaded-module lines, kept because they carry the RUNTIME BASE of
        # every module ("GameAssembly.dll (00007FFB2ABB0000), size: ...") and
        # nothing can rebase a frame VA to an RVA without them. Only the
        # candidate lines are kept, not the whole 2,300-line log.
        self.modlines = [l for l in lines if "), size: " in l]
        self.frames = blocks[0]
        for b in blocks[1:]:
            for f in b:
                f.walked = True
                self.walked.append(f)
        self.ok = True

    # -- accessors -------------------------------------------------------
    @property
    def all_frames(self):
        return self.frames + self.walked

    @property
    def modules(self):
        """Every module ON THE STACK, crash site and walked stack together."""
        return set(f.module for f in self.all_frames)

    @property
    def site_modules(self):
        return set(f.module for f in self.frames)

    def age_after(self, start_epoch):
        if self.when is None or start_epoch is None:
            return None
        return self.when - start_epoch

    def attribute(self, ours=None):
        """(module, source, frame, note). Never guesses.

        source is 'ours' (a frame at the crash site is in one of our modules),
        'top' (nothing of ours at the crash site -- the top frame's module), or
        'none' (unparsable report; module is None).
        """
        if ours is None:
            ours = our_modules()
        ours = set(m.lower() for m in ours)
        if not self.ok or not self.frames:
            return (None, "none", None, self.why or "no frames")
        note = None
        for f in self.walked:
            if f.module.lower() in ours:
                note = ("%s also appears in the WALKED stack (%s), which is "
                        "not the crash site" % (f.module, f.symbol or f.addr))
                break
        for f in self.frames:
            if f.module.lower() in ours:
                return (f.module, "ours", f, note)
        return (self.frames[0].module, "top", self.frames[0], note)


def parse_stack_blocks(lines):
    """Frames of a Unity crash report, grouped into contiguous blocks.

    None  -> no stack section at all (not a crash report)
    []    -> a section with no frames in it
    [[Frame, ...], ...] -> block 0 is the crash site; later blocks are the
                           walked stack that follows the symbol-handler dump.

    Blank lines and `ERROR: SymGetSymFromAddr64 ...` annotations do not split a
    block; anything else non-frame does.
    """
    if isinstance(lines, str):
        lines = lines.splitlines()
    start = None
    for i, ln in enumerate(lines):
        if STACK_BEGIN in ln:
            start = i + 1
            break
    if start is None:
        return None
    blocks, cur = [], []
    for ln in lines[start:]:
        if STACK_END in ln:
            break
        if not ln.strip() or FRAME_NOISE_RX.match(ln):
            continue
        m = FRAME_RX.match(ln)
        if m:
            cur.append(Frame(m.group(1), m.group(2), m.group(3)))
        elif cur:
            blocks.append(cur)
            cur = []
    if cur:
        blocks.append(cur)
    return blocks


def crash_folders(root=DEFAULT_CRASH_ROOT, since=None, slack=0.0):
    """Crash_* folders, newest FIRST, optionally only those created after
    `since` (epoch seconds, local clock -- the UTC conversion happens here)."""
    out = []
    for p in glob.glob(os.path.join(root, "Crash_*")):
        if not os.path.isdir(p):
            continue
        t = crash_dir_epoch(p)
        if t is None:
            t = os.path.getmtime(p)
        if since is not None and t < since - slack:
            continue
        out.append((t, p))
    out.sort(key=lambda x: x[0], reverse=True)
    return out


def newest_crash_report(since=None, root=DEFAULT_CRASH_ROOT, slack=0.0):
    """The newest crash report created after `since`, or None if there is none.

    None means something: no report newer than launch is evidence that the
    client was torn down or exited, NOT that it crashed natively.
    """
    for t, p in crash_folders(root, since=since, slack=slack):
        return CrashReport(p, when=t)
    return None


_RESOLVERS = {}


def symbolize_frames(frames, modlines):
    """([(frame, Sym-or-None, per-frame note)], global_note_or_None).

    The GameAssembly frames of a Unity crash report are labelled with the
    NEAREST EXPORT (`mono_class_has_parent` for nearly everything on this
    build) because there is no PDB -- a confidently wrong answer. This asks
    tools/il2cpp_resolve.py to name the method whose body actually contains
    each address, offline.

    Returns (None, note) -- and NEVER a silent skip -- when the resolver's two
    inputs are not available, because "I could not look" is INCONCLUSIVE, not
    a pass (CLAUDE.md 9b).
    """
    try:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import il2cpp_resolve as ir
    except Exception as e:                      # pragma: no cover
        return None, ("frames NOT symbolized: could not import "
                      "il2cpp_resolve (%s)" % e)
    gameasm, metadec = ir.default_paths()
    missing = [p for p in (gameasm, metadec) if not os.path.exists(p)]
    if missing:
        return None, ("frames NOT symbolized: %s absent. Unity's own labels "
                      "below are NEAREST-EXPORT guesses, not the methods that "
                      "crashed. (The metadata cache is produced by "
                      "tools/metablob.py at .cache/global-metadata.dec.dat.)"
                      % ", ".join(missing))
    key = (gameasm, metadec)
    try:
        R = _RESOLVERS.get(key)
        if R is None:
            R = _RESOLVERS[key] = ir.Resolver(gameasm, metadec)
        rows = ir.symbolize_frames(R, frames, ir.parse_module_bases(modlines),
                                   key=key)
    except Exception as e:
        return None, ("frames NOT symbolized: the resolver failed (%s: %s)"
                      % (type(e).__name__, e))
    return rows, None


def format_crash_report(rep, start_epoch=None, top=12, ours=None, indent="   ",
                        symbolize=True):
    """The block run.py prints. Returns a list of lines."""
    if rep is None:
        return ["NO CRASH REPORT was written after launch -- the client was "
                "torn down or exited, rather than dying in native code."]
    age = rep.age_after(start_epoch)
    head = "CRASH REPORT %s" % os.path.basename(rep.folder)
    if age is not None:
        head += " (%.0fs after launch)" % age
    lines = [head]
    if not rep.ok:
        lines.append(indent + "INCONCLUSIVE -- " + rep.why)
        return lines
    shown = rep.frames[:top]
    syms, note = (symbolize_frames(shown, rep.modlines) if symbolize
                  else (None, "symbolization was not requested"))
    if note:
        lines.append(indent + note)
    for i, f in enumerate(shown):
        lines.append(indent + f.text)
        if syms is None:
            continue
        _f, s, why = syms[i]
        if s is not None:
            lines.append(indent + "    -> " + s.line())
        elif why:
            lines.append(indent + "    -> " + why)
    rest = len(rep.frames) - top
    if rest > 0:
        lines.append(indent + "... %d more crash-site frame(s)" % rest)
    if rep.walked:
        lines.append(indent + "... plus %d frame(s) in the walked stack that "
                              "follows the module dump" % len(rep.walked))
    mod, source, frame, note = rep.attribute(ours)
    if source == "ours":
        lines.append("attributed to %s -- first crash-site frame in one of our "
                     "modules: %s" % (mod, frame.text))
    else:
        lines.append("attributed to %s -- top crash-site frame; nothing of "
                     "ours is on the crash site" % mod)
    if note:
        lines.append(indent + "note: " + note)
    return lines


# ---------------------------------------------------------------------------
# FAIL-FAST: the death Unity's crash handler NEVER sees
#
# MEASURED 2026-09-02 13:18. A client died with NO Crash_* folder at all, and
# "no crash report newer than launch" was read -- wrongly -- as a teardown or a
# clean exit. It was neither: it was 0xc0000409 FAST_FAIL_FATAL_APP_EXIT, an
# abort() out of a mimalloc assertion inside a MOD DLL. `__fastfail` does not
# raise a catchable SEH exception and does not run the process's unhandled
# exception filter, so Unity's handler is never entered and writes nothing.
#
# The OS, however, records it in three places, and all three were sitting there:
#
#   1. the Application event log -- provider `Application Error` (faulting
#      module, exception code, fault offset) and `Windows Error Reporting`;
#   2. %LOCALAPPDATA%\CrashDumps\EscapeFromTarkov.exe.<pid>.dmp, when
#      LocalDumps is configured;
#   3. that dump, read by cdb -- and cdb's `k` names OUR DLLs and nim procs
#      (`admin!mi_assert_fail` <- `admin!mi_malloc` <- ... <- `admin!onUpdate`),
#      which is the whole answer in one line.
#
# So the rule, and it is the point of this section: a death may be called a
# teardown or an exit ONLY when the Crash_* folders, the event log AND
# CrashDumps are ALL empty -- and only when each of those questions was
# actually ASKED and ANSWERED. A query that failed is INCONCLUSIVE and must
# never collapse into "nothing was found".
# ---------------------------------------------------------------------------

WER_PROVIDERS = ("Application Error", "Windows Error Reporting")
WER_IMAGE = "EscapeFromTarkov.exe"
CRASHDUMPS_DIR = os.path.join(
    os.environ.get("LOCALAPPDATA", r"C:\Users\Default\AppData\Local"),
    "CrashDumps")
CDB_EXE = r"C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\cdb.exe"

# Printed by the PowerShell probe as its LAST line. Its absence means the query
# did not complete, which is a different answer from "no events".
WER_DONE = "===WERDONE==="
WER_SEP = "===EVENT==="

# `Exception code: 0xc0000409` -- the one that started this.
FAST_FAIL_CODE = 0xC0000409
EXC_NAMES = {
    0xC0000409: "STATUS_STACK_BUFFER_OVERRUN / FAST_FAIL_FATAL_APP_EXIT -- a "
                "__fastfail or abort(), NOT a page fault. Unity's crash "
                "handler never sees this one.",
    0xC0000005: "ACCESS_VIOLATION",
    0xC000001D: "ILLEGAL_INSTRUCTION",
    0x80000003: "BREAKPOINT",
    0xE0434352: "a managed (.NET/CLR) exception",
}

WER_FIELDS = (
    ("module", re.compile(r"Faulting module name:\s*([^,\r\n]+)")),
    ("app", re.compile(r"Faulting application name:\s*([^,\r\n]+)")),
    ("code", re.compile(r"Exception code:\s*(0x[0-9A-Fa-f]+)")),
    ("offset", re.compile(r"Fault offset:\s*(0x[0-9A-Fa-f]+)")),
    ("pid", re.compile(r"Faulting process id:\s*(0x[0-9A-Fa-f]+|\d+)")),
    ("path", re.compile(r"Faulting module path:\s*([^\r\n]+)")),
)


def _ps(script, timeout=120, runner=None):
    """(rc, text) from PowerShell. Never raises; injectable for tests."""
    if runner is not None:
        return runner(script)
    try:
        r = subprocess.run(["powershell", "-NoProfile", "-NonInteractive",
                            "-Command", script],
                           capture_output=True, text=True, timeout=timeout)
    except Exception as e:
        return 127, "could not run PowerShell (%s: %s)" % (type(e).__name__, e)
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def wer_query_script(since_local):
    """The Application-log query, as one PowerShell command.

    Filtered server-side by StartTime so the whole log is never materialised
    (it is routinely six figures of records), then narrowed to the two
    providers that record a process death and to messages naming the client.
    """
    return (
        "$ErrorActionPreference='SilentlyContinue';"
        "$e = Get-WinEvent -FilterHashtable @{LogName='Application'; "
        "StartTime=[datetime]'%s'} -ErrorAction SilentlyContinue;"
        "foreach ($x in $e) { if (($x.ProviderName -eq 'Application Error' -or "
        "$x.ProviderName -eq 'Windows Error Reporting') -and "
        "($x.Message -like '*%s*')) { "
        "Write-Output '%s'; "
        "Write-Output $x.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'); "
        "Write-Output $x.ProviderName; Write-Output $x.Message } };"
        "Write-Output '%s'" % (since_local, WER_IMAGE, WER_SEP, WER_DONE))


def parse_wer_output(text):
    """([event, ...], note) or (None, why) when the query did not complete.

    None is the INCONCLUSIVE state and callers must keep it: "I could not read
    the event log" is not "the client did not crash".
    """
    if text is None:
        return None, "the event-log query produced no output at all"
    if WER_DONE not in text:
        return None, ("the event-log query did not complete (no %s marker) -- "
                      "this is INCONCLUSIVE, not 'no events'. Output was: %s"
                      % (WER_DONE, (text or "").strip()[:300]))
    body = text.split(WER_DONE)[0]
    out = []
    for chunk in body.split(WER_SEP)[1:]:
        lines = chunk.strip().splitlines()
        if len(lines) < 2:
            continue
        ev = {"when": lines[0].strip(), "provider": lines[1].strip(),
              "message": "\n".join(lines[2:]).strip()}
        for name, rx in WER_FIELDS:
            m = rx.search(ev["message"])
            ev[name] = m.group(1).strip() if m else None
        out.append(ev)
    return out, None


def wer_events(since, runner=None):
    """([event, ...], note). `None` for the list means the query FAILED."""
    stamp = time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(since))
    rc, text = _ps(wer_query_script(stamp), runner=runner)
    evs, why = parse_wer_output(text)
    if evs is None and rc != 0:
        why = ("the event-log query exited %d: %s"
               % (rc, (text or "").strip()[:300]))
    return evs, why


def crash_dumps(since, directory=None):
    """(dumps, note) -- WER LocalDumps files newer than launch.

    An ABSENT directory is a fact ("Windows only writes there when LocalDumps
    is configured"), not a failure, and it is stated: a reader must not take an
    empty list for proof that no dump was written if the feature was simply off.
    """
    d = directory or CRASHDUMPS_DIR
    if not os.path.isdir(d):
        return [], ("%s does not exist -- LocalDumps is not configured, so the "
                    "ABSENCE of a dump here proves nothing" % d)
    out = []
    try:
        for name in os.listdir(d):
            if not name.lower().endswith(".dmp"):
                continue
            if WER_IMAGE.lower() not in name.lower():
                continue
            p = os.path.join(d, name)
            try:
                mt = os.path.getmtime(p)
            except OSError:
                continue
            if since is None or mt > since:
                out.append((mt, p))
    except OSError as e:
        return None, "could not list %s: %s" % (d, e)
    out.sort(reverse=True)
    return [p for _mt, p in out], None


CDB_CMD = ".ecxr; k 40; q"


def cdb_stack(dmp, cdb=None, runner=None, timeout=300):
    """(call-site lines, note). `None` for the lines means cdb could not run.

    cdb's `k` is the only thing in this whole file that names a nim proc inside
    one of our mod DLLs. When it is absent that is SAID, and the caller falls
    back to dmpread's registers rather than printing nothing.
    """
    exe = cdb or CDB_EXE
    if not os.path.isfile(exe):
        return None, ("cdb.exe is NOT installed at %s, so the call stack of "
                      "this dump was not read. Install the Windows SDK "
                      "Debugging Tools, or read the registers below." % exe)
    cmd = [exe, "-z", dmp, "-c", CDB_CMD]
    if runner is not None:
        rc, text = runner(cmd)
    else:
        try:
            r = subprocess.run(cmd, capture_output=True, text=True,
                               timeout=timeout)
            rc, text = r.returncode, (r.stdout or "") + (r.stderr or "")
        except Exception as e:
            return None, ("cdb exists but could not be run (%s: %s)"
                          % (type(e).__name__, e))
    lines = [l.rstrip() for l in (text or "").splitlines()]
    out = []
    seen = False
    for l in lines:
        if "Call Site" in l:
            seen = True
            out.append(l)
            continue
        if not seen:
            continue
        if not l.strip() or l.strip().startswith("quit:"):
            break
        out.append(l)
    if not out:
        return None, ("cdb ran (exit %d) but printed no `Call Site` column -- "
                      "the stack was NOT read. Its output began: %s"
                      % (rc, " / ".join(l for l in lines if l.strip())[:300]))
    return out, None


def code_int(code):
    """The exception code as an int, or None. Never guesses at a bad string."""
    try:
        s = str(code).strip()
        return int(s, 16) if s.lower().startswith("0x") else int(s)
    except (TypeError, ValueError):
        return None


def code_name(code):
    n = code_int(code)
    return None if n is None else EXC_NAMES.get(n)


# The four states a vanished client can be in. Three, never two -- and the
# fourth is INCONCLUSIVE, which is what the old code silently collapsed into
# "teardown".
DEATH_NATIVE = "NATIVE-CRASH"
DEATH_FAILFAST = "FAIL-FAST"
DEATH_OS_DUMP = "OS-DUMP"
DEATH_QUIET = "EXIT-OR-TEARDOWN"
DEATH_UNKNOWN = "INCONCLUSIVE"


def death_kind(crash_folder, events, dumps, events_note=None,
               dumps_note=None):
    """(kind, sentence). THE rule this section exists to enforce.

    `events` / `dumps` are None when their question could not be answered.
    "teardown or exit" is reachable ONLY when all three sources were asked and
    all three came back empty -- which is what makes it falsifiable.
    """
    if crash_folder:
        return (DEATH_NATIVE,
                "Unity's crash handler wrote %s, so this was a native fault it "
                "could see." % os.path.basename(str(crash_folder)))
    if events is None:
        return (DEATH_UNKNOWN,
                "no Crash_* folder, and the Windows event log could NOT be "
                "queried (%s). This is INCONCLUSIVE -- a fail-fast "
                "(0xc0000409) leaves no Crash_* folder at all, so absence of "
                "one is not evidence of a teardown."
                % (events_note or "no reason given"))
    if events:
        codes = set(e.get("code") for e in events if e.get("code"))
        fast = any(code_int(c) == FAST_FAIL_CODE for c in codes)
        mods = sorted(set(e.get("module") for e in events if e.get("module")))
        return ((DEATH_FAILFAST if fast else DEATH_NATIVE),
                "no Crash_* folder, but the Windows Application log recorded "
                "%d %s event(s) for %s: code(s) %s, faulting module(s) %s. "
                "This was a CRASH, not a teardown%s."
                % (len(events), "/".join(sorted(set(e["provider"]
                                                    for e in events))),
                   WER_IMAGE, ", ".join(sorted(codes)) or "unstated",
                   ", ".join(mods) or "unstated",
                   " -- __fastfail/abort(), which Unity's handler never sees"
                   if fast else ""))
    if dumps is None:
        return (DEATH_UNKNOWN,
                "no Crash_* folder, no matching event-log entry, and "
                "%%LOCALAPPDATA%%\\CrashDumps could not be listed (%s)."
                % (dumps_note or "no reason given"))
    if dumps:
        return (DEATH_OS_DUMP,
                "no Crash_* folder and no event-log entry, but Windows wrote "
                "%d dump(s) under CrashDumps after launch (%s). A dump is a "
                "crash." % (len(dumps), os.path.basename(dumps[0])))
    return (DEATH_QUIET,
            "asked all three -- no Crash_* folder newer than launch, no "
            "`Application Error`/`Windows Error Reporting` entry naming %s, "
            "and no new dump under CrashDumps%s. Only now does this read as a "
            "teardown or an exit rather than a crash."
            % (WER_IMAGE, (" (%s)" % dumps_note) if dumps_note else ""))


def format_wer(since, indent="   ", ps_runner=None, cdb_runner=None,
               dumps_dir=None, cdb=None, dmpread_lines=None,
               crash_folder=None):
    """(lines, kind, detail). The block run.py prints, and `crashwatch.py wer`.

    Every one of the three questions is asked and REPORTED, including when the
    answer is "I could not look".
    """
    lines = []
    evs, note = wer_events(since, runner=ps_runner)
    lines.append("Windows Application event log since launch:")
    if evs is None:
        lines.append(indent + "COULD NOT LOOK -- " + (note or "unstated"))
    elif not evs:
        lines.append(indent + "no `Application Error` / `Windows Error "
                              "Reporting` entry naming %s" % WER_IMAGE)
    else:
        for e in evs[:6]:
            lines.append(indent + "%s  %s" % (e["when"], e["provider"]))
            lines.append(indent + "   faulting module %s  code %s  offset %s"
                         % (e.get("module") or "(unstated)",
                            e.get("code") or "(unstated)",
                            e.get("offset") or "(unstated)"))
            cn = code_name(e.get("code"))
            if cn:
                lines.append(indent + "   %s" % cn)
        if len(evs) > 6:
            lines.append(indent + "... %d more event(s)" % (len(evs) - 6))

    dumps, dnote = crash_dumps(since, directory=dumps_dir)
    lines.append("%LOCALAPPDATA%\\CrashDumps newer than launch:")
    if dumps is None:
        lines.append(indent + "COULD NOT LOOK -- " + (dnote or "unstated"))
    elif not dumps:
        lines.append(indent + "none" + ((" -- " + dnote) if dnote else ""))
    else:
        for p in dumps[:5]:
            lines.append(indent + p)

    if dumps:
        stack, snote = cdb_stack(dumps[0], cdb=cdb, runner=cdb_runner)
        lines.append("cdb -z %s -c %r:" % (os.path.basename(dumps[0]), CDB_CMD))
        if stack is None:
            lines.append(indent + "NOT READ -- " + (snote or "unstated"))
            for l in (dmpread_lines or []):
                lines.append(indent + l)
            if not dmpread_lines:
                lines.append(indent + "(no dmpread registers were supplied "
                                      "either, so nothing describes this "
                                      "dump's faulting instruction)")
        else:
            for l in stack[:45]:
                lines.append(indent + l)

    kind, sentence = death_kind(crash_folder, evs, dumps, note, dnote)
    lines.append("DEATH KIND  %s -- %s" % (kind, sentence))
    return lines, kind, {"events": evs, "dumps": dumps, "events_note": note,
                         "dumps_note": dnote}


# ---------------------------------------------------------------------------
# HOST / MOD SYMBOLISATION. MEASURED 2026-09-03, and done BY HAND twice that day.
#
# Our DLLs ship without a PDB, so every tool that reads a crash of ours prints
# the same two useless things:
#
#   * Unity's report:  `0x00007FFB1DB980C4 (aowlspt-host-il2cpp) (function-name
#     not available)`, and -- worse -- `aowl_region_screen_known_x` for SEVEN
#     consecutive different frames, because dbghelp falls back to the nearest
#     EXPORT and we export very few. That is a confidently wrong answer.
#   * cdb's `k`:  `aowlspt_host_il2cpp+0x80c4` and then `0x84`, `0x1` -- the
#     walk collapses after one frame ("0 walked") because there is no unwind
#     information it will trust for our frames.
#
# Both are recoverable OFFLINE, because the mingw link leaves a full COFF symbol
# table in the DLL. The whole method, measured end to end on
# Crash_2026-09-03_155245216:
#
#  1. WHICH BUILD WAS LOADED. The deployed file has already been replaced by the
#     time anyone reads the crash (measured: the dump's host DLL is stamped
#     11:22:30, the deployed file at read time was the 21:12 build), so
#     symbolising against `D:\Aowlspt\aowlspt\aowlspt-host-il2cpp.dll` gives
#     wrong names with no warning. The PE TimeDateStamp identifies the build:
#     cdb `lmv m aowlspt*` prints `Timestamp: ... (6A9990B6)`, `ImageSize`,
#     `CheckSum`, and every candidate file's own header carries the same three.
#     MEASURED: TimeDateStamp 0x6A9990B6 matched EXACTLY ONE of 275 candidate
#     files (`aowlspt-host-il2cpp.dll.bak-20260903-122227`); SizeOfImage alone
#     matched two, so size alone is not an identity.
#  2. THE SYMBOLS. `objdump -t` on that file lists 2,630 `.text` symbols. An
#     objdump symbol's printed address is SECTION-RELATIVE, so its RVA is
#     `section_rva + value`, with the 1-based `(sec N)` indexing the PE section
#     table. Frame RVA = frame VA - the module base from the dump.
#     MEASURED result for the four "(function-name not available)" frames:
#     `_mi_page_free_collect+0x6d`, `_mi_segment_page_alloc+0x3db`,
#     `_mi_malloc_generic+0x57`, `mi_malloc+0x76` -- i.e. a mimalloc crash,
#     which no reading of the raw report could have told you. The seven frames
#     dbghelp all called `aowl_region_screen_known_x` are really `substr_0`,
#     `strip_0`, `pathGet_0`, `parseDesired_0`, `takeModSet_0`, ...
#  3. WHEN THE WALK FAILS. `dps @rsp L400` and keep the words that land inside
#     one of our modules. That is a SCRAPE, not a walk: it is stack memory in
#     address order and it can contain stale return addresses from earlier,
#     deeper calls. It is labelled as a scrape everywhere it is printed, and it
#     must never be presented as a call stack.
#  4. MIMALLOC. When a frame is inside mimalloc, `da` on the argument registers
#     often holds the assertion/abort text -- that is how
#     `"corrupted thread-free list."` (page.c:205) was read out of
#     EscapeFromTarkov.exe.636.dmp on 2026-09-03. Only reported when `da`
#     actually yields a printable string; never guessed from the function name.
#
# objdump is run through tools/cctool.py's environment, with its OWN directory
# forced to the front of PATH. Not decoration: objdump.exe links the same
# msys2 libraries cc1.exe does, so under Git Bash it can bind Git's
# mingw64 copies and die in the loader before main with no diagnostic --
# CLAUDE.md section 3.

OBJDUMP_EXE = r"C:\msys64\ucrt64\bin\objdump.exe"
DEFAULT_REPO_MODS = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "mods")

# "[  0](sec  1)(fl 0x00)(ty   20)(scl   2) (nx 0) 0x00000000000000 _CRT_INIT"
OBJDUMP_SYM_RX = re.compile(
    r"^\[\s*\d+\]\(sec\s+(-?\d+)\)\(fl\s+\S+\)\(ty\s+(\S+)\)\(scl\s+(\d+)\)"
    r"\s+\(nx\s+\d+\)\s+0x([0-9a-fA-F]+)\s+(.+?)\s*$")

# cdb `lmv`: "00007ffb`1db90000 00007ffb`205a6000   aowlspt_host_il2cpp   T ..."
LMV_HEAD_RX = re.compile(
    r"^([0-9a-fA-F`]+)\s+([0-9a-fA-F`]+)\s+(\S+)\s")
LMV_KV_RX = re.compile(r"^\s+([A-Za-z ]+?):\s+(.*?)\s*$")
# cdb `dps`: "00000030`6f7ff158  00007ffb`1db9e734 aowlspt_host_il2cpp+0xe734"
DPS_RX = re.compile(
    r"^([0-9a-fA-F`]+)\s+([0-9a-fA-F`]+)\s+(\S+?)\+0x([0-9a-fA-F]+)\s*$")
# cdb `da 00007ffb...`: "00007ffb`3dfd1373  \"corrupted thread-free list.\""
DA_RX = re.compile(r"^[0-9a-fA-F`]+\s+\"(.*)\"\s*$")

MIMALLOC_FN_RX = re.compile(r"^_?mi_|^mi_|_mi_assert|mi_error")
ARG_REGS = ("rcx", "rdx", "r8", "r9", "rax", "rbx", "rsi", "rdi")


def _unhex(s):
    """A cdb address (`00007ffb`1db90000`) as an int, or None."""
    try:
        return int(str(s).replace("`", "").strip(), 16)
    except (TypeError, ValueError):
        return None


def pe_ident(path):
    """The PE identity of a file on disk, or None if it is not a PE.

    Returns the three things cdb's `lmv` prints -- TimeDateStamp, SizeOfImage,
    CheckSum -- plus the ImageBase and the section table, which is what turns
    an objdump symbol into an RVA. Pure Python: no external tool, so this half
    can never fail for environment reasons.
    """
    try:
        with open(path, "rb") as fh:
            head = fh.read(0x1000)
    except OSError:
        return None
    if len(head) < 0x40 or head[:2] != b"MZ":
        return None
    try:
        off = struct.unpack_from("<I", head, 0x3C)[0]
        if head[off:off + 4] != b"PE\0\0":
            return None
        machine, nsec = struct.unpack_from("<HH", head, off + 4)
        stamp = struct.unpack_from("<I", head, off + 8)[0]
        optsz = struct.unpack_from("<H", head, off + 20)[0]
        opt = off + 24
        magic = struct.unpack_from("<H", head, opt)[0]
        if magic == 0x20B:                      # PE32+
            base = struct.unpack_from("<Q", head, opt + 24)[0]
        else:
            base = struct.unpack_from("<I", head, opt + 28)[0]
        image_size = struct.unpack_from("<I", head, opt + 56)[0]
        checksum = struct.unpack_from("<I", head, opt + 64)[0]
        secs = []
        st = opt + optsz
        for i in range(nsec):
            e = st + 40 * i
            if e + 40 > len(head):
                break
            name = head[e:e + 8].rstrip(b"\0").decode("ascii", "replace")
            vsize, vaddr = struct.unpack_from("<II", head, e + 8)
            chars = struct.unpack_from("<I", head, e + 36)[0]
            secs.append({"name": name, "rva": vaddr, "size": vsize,
                         "code": bool(chars & 0x20)})
    except (struct.error, IndexError):
        return None
    return {"path": path, "timestamp": stamp, "image_size": image_size,
            "checksum": checksum, "base": base, "machine": machine,
            "sections": secs}


def build_candidates(stem, install_root=DEFAULT_INSTALL, repo_mods=None):
    """Every file on disk that could BE the build named `stem`.

    The live artifact plus each of its backups: `.bak-*` is what deploy.py
    writes, and the `.MINE-*` / `.MODLOAD-*` siblings exist in the install too.
    Mods are covered from both the install (`mods/<n>/<n>.dll*`) and the repo
    (`mods/<n>/bin/<n>.dll*`), because after a redeploy the loaded build often
    survives only in the worktree that produced it.
    """
    stem = str(stem).lower().replace("_", "-")
    pats = []
    if install_root:
        pats += [os.path.join(install_root, stem + ".dll*"),
                 os.path.join(install_root, "mods", "*", stem + ".dll*")]
    if repo_mods is None:
        repo_mods = DEFAULT_REPO_MODS
    if repo_mods:
        pats += [os.path.join(repo_mods, "*", "bin", stem + ".dll*"),
                 os.path.join(repo_mods, "*", stem + ".dll*")]
    out, seen = [], set()
    for pat in pats:
        for p in glob.glob(pat):
            k = os.path.normcase(os.path.abspath(p))
            if k in seen or not os.path.isfile(p):
                continue
            seen.add(k)
            out.append(p)
    return sorted(out)


def _sha256(path):
    try:
        h = hashlib.sha256()
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                h.update(chunk)
        return h.hexdigest()
    except OSError:
        return None


def match_build(want, candidates, hasher=_sha256):
    """(path, how, note) for the file that IS the loaded build, or (None, None,
    why).

    `want` is a dict with any of timestamp / image_size / checksum. Only the
    keys actually present are compared, and `how` names them -- so a match on
    size alone can never read as a match on the TimeDateStamp.

    Three outcomes, never two. Zero survivors is INCONCLUSIVE and NAMES THE
    TIMESTAMP, because "no backup has that stamp" is the actionable fact (the
    build was never backed up, or it came from a worktree that is gone). More
    than one survivor is INCONCLUSIVE too -- unless the survivors are
    byte-identical, which happens routinely because a redeploy of an unchanged
    artifact makes another .bak.
    """
    keys = [k for k in ("timestamp", "image_size", "checksum")
            if want.get(k) is not None]
    if not keys:
        return None, None, ("nothing identifies the loaded build (no "
                            "TimeDateStamp, SizeOfImage or CheckSum was "
                            "read from the dump), so no file was matched")
    idents = []
    for p in candidates:
        i = pe_ident(p)
        if i is not None:
            idents.append(i)
    if not idents:
        return None, None, ("no candidate file on disk is a PE at all "
                            "(%d path(s) looked at)" % len(candidates))
    hits = [i for i in idents if all(i[k] == want[k] for k in keys)]
    shown = "TimeDateStamp 0x%08X" % want["timestamp"] if "timestamp" in keys \
        else "SizeOfImage 0x%X" % (want.get("image_size") or 0)
    if not hits:
        return None, None, (
            "INCONCLUSIVE: none of the %d candidate build(s) on disk has %s "
            "(also compared: %s). The loaded build was not backed up, or its "
            "backup has been deleted -- so its addresses were NOT symbolised, "
            "and nothing below should be read as if they had been."
            % (len(idents), shown,
               ", ".join("%s=%s" % (k, hex(want[k])) for k in keys)))
    if len(hits) > 1:
        digests = set()
        for i in hits:
            d = hasher(i["path"])
            digests.add(d if d is not None else i["path"])
        if len(digests) == 1:
            return (hits[0]["path"],
                    "matched %s; %d byte-identical copies, used the first"
                    % (", ".join(keys), len(hits)), None)
        return None, None, (
            "INCONCLUSIVE: %d DIFFERENT files share %s (%s) -- the loaded "
            "build cannot be told apart from them, so no symbols were used: %s"
            % (len(hits), shown, ", ".join(keys),
               ", ".join(os.path.basename(i["path"]) for i in hits[:6])))
    return hits[0]["path"], "matched %s" % ", ".join(
        "%s=0x%X" % (k, want[k]) for k in keys), None


def find_objdump(path=None):
    """(objdump path, note) or (None, why). Never guesses that one exists."""
    if path and os.path.isfile(path):
        return path, None
    if os.path.isfile(OBJDUMP_EXE):
        return OBJDUMP_EXE, None
    import shutil as _sh
    p = _sh.which("objdump")
    if p:
        return p, "using objdump from PATH: %s" % p
    return None, ("objdump.exe is NOT present at %s and not on PATH, so the "
                  "host/mod frames were NOT symbolised. Install msys2's "
                  "binutils." % OBJDUMP_EXE)


def objdump_symbol_text(dll, objdump=None, runner=None, timeout=180):
    """(raw `objdump -t` text, note). None for the text means it did not run.

    Run through cctool's environment so objdump's own directory leads PATH.
    """
    exe, note = find_objdump(objdump)
    if exe is None:
        return None, note
    if runner is not None:
        rc, text = runner([exe, "-t", dll])
    else:
        try:
            sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
            import cctool
            r = cctool.cc_run([exe, "-t", dll], timeout=timeout)
        except Exception as e:
            return None, ("objdump could not be run (%s: %s)"
                          % (type(e).__name__, e))
        rc, text = r.returncode, (r.stdout or "") + (r.stderr or "")
    if rc != 0 or "SYMBOL TABLE" not in (text or ""):
        return None, ("objdump -t exited %s without a SYMBOL TABLE for %s -- "
                      "the frames were NOT symbolised. Output began: %s"
                      % (rc, os.path.basename(dll),
                         (text or "").strip()[:200]))
    return text, note


def parse_objdump_symbols(text, sections):
    """[(rva, name), ...] sorted, for CODE sections only.

    An objdump symbol address is SECTION-RELATIVE and `(sec N)` is 1-based into
    the PE section table -- getting that wrong shifts every name by the section
    RVA, which produces plausible wrong function names rather than an error.
    """
    out = []
    for line in (text or "").splitlines():
        m = OBJDUMP_SYM_RX.match(line.rstrip())
        if not m:
            continue
        sec = int(m.group(1))
        if sec < 1 or sec > len(sections):
            continue                       # -1/0 = absolute/undefined
        s = sections[sec - 1]
        if not s.get("code"):
            continue
        name = m.group(5).strip()
        if not name or name.startswith("."):
            continue
        out.append((s["rva"] + int(m.group(4), 16), name))
    out.sort()
    return out


class HostSymbols(object):
    """Nearest-preceding-symbol lookup over one build's COFF symbol table."""

    def __init__(self, dll, symbols, how=None, sections=None):
        self.dll = dll
        self.how = how
        self.symbols = symbols
        self.sections = sections or []
        self._keys = [r for r, _n in symbols]

    def in_code(self, rva):
        """Is this RVA inside a CODE section of the build?

        The check that stops the worst answer this class could give. Without
        it, a .data address scraped off the stack (0x39E040 in the measured
        dump) falls after the last .text symbol and is reported as
        `__add_nanbits_D2A+0xF8630` -- a real function name, a plausible
        offset, and entirely fictional. If the section table is unavailable the
        answer is None (unknown), never True.
        """
        if not self.sections:
            return None
        for s in self.sections:
            if s["rva"] <= rva < s["rva"] + max(s["size"], 1):
                return bool(s.get("code"))
        return False

    def lookup(self, rva):
        """(name, offset) or None. None means the RVA is outside every code
        section, or before every symbol -- said, never fabricated."""
        if not self._keys or self.in_code(rva) is False:
            return None
        i = bisect.bisect_right(self._keys, rva) - 1
        if i < 0:
            return None
        r, n = self.symbols[i]
        return n, rva - r

    def label(self, rva):
        got = self.lookup(rva)
        if got is None:
            return ("(no preceding symbol -- RVA 0x%X is before every code "
                    "symbol in this build)" % rva)
        return "%s+0x%X" % got


def load_host_symbols(want, stem, install_root=DEFAULT_INSTALL,
                      repo_mods=None, objdump=None, objdump_runner=None,
                      candidates=None, hasher=_sha256):
    """(HostSymbols, note) or (None, why). The whole steps 1+2 in one call."""
    cands = (candidates if candidates is not None
             else build_candidates(stem, install_root, repo_mods))
    if not cands:
        return None, ("INCONCLUSIVE: no file named %s.dll* exists under %s or "
                      "%s, so nothing could be matched against the dump's "
                      "module list" % (stem, install_root, repo_mods
                                       or DEFAULT_REPO_MODS))
    path, how, why = match_build(want, cands, hasher=hasher)
    if path is None:
        return None, why
    ident = pe_ident(path)
    text, note = objdump_symbol_text(path, objdump=objdump,
                                     runner=objdump_runner)
    if text is None:
        return None, "%s (build matched: %s)" % (note, os.path.basename(path))
    syms = parse_objdump_symbols(text, ident["sections"])
    if not syms:
        return None, ("objdump -t on %s listed no code-section symbols, so "
                      "nothing was symbolised" % os.path.basename(path))
    return HostSymbols(path, syms,
                       "%s (%s; %d code symbols)"
                       % (os.path.basename(path), how, len(syms)),
                       sections=ident["sections"]), note


# -- cdb: the module list, the scraped stack, and the mimalloc string --------

def cdb_run(dmp, commands, cdb=None, runner=None, timeout=300):
    """(text, note). None for the text means cdb did not run."""
    exe = cdb or CDB_EXE
    if runner is not None:
        rc, text = runner([exe, "-z", dmp, "-c", commands])
        return (text, None) if text is not None else (None, "no cdb output")
    if not os.path.isfile(exe):
        return None, ("cdb.exe is NOT installed at %s, so the dump's module "
                      "list and stack were not read (Windows SDK Debugging "
                      "Tools)." % exe)
    try:
        r = subprocess.run([exe, "-z", dmp, "-c", commands],
                           capture_output=True, text=True, timeout=timeout)
    except Exception as e:
        return None, ("cdb exists but could not be run (%s: %s)"
                      % (type(e).__name__, e))
    return (r.stdout or "") + (r.stderr or ""), None


def parse_lmv(text):
    """{stem: {...}} from `lmv` output: base, end, path, timestamp, image_size,
    checksum. Keys absent from the output stay absent -- never defaulted."""
    mods = {}
    cur = None
    for raw in (text or "").splitlines():
        line = raw.rstrip()
        m = LMV_HEAD_RX.match(line)
        if m and not line.startswith(" "):
            base, end = _unhex(m.group(1)), _unhex(m.group(2))
            if base is None:
                cur = None
                continue
            cur = {"stem": m.group(3), "base": base, "end": end}
            mods[m.group(3)] = cur
            continue
        if cur is None:
            continue
        kv = LMV_KV_RX.match(line)
        if not kv:
            continue
        key, val = kv.group(1).strip().lower(), kv.group(2)
        if key == "image path":
            cur["path"] = val
        elif key == "image name":
            cur["name"] = val
        elif key == "timestamp":
            m2 = re.search(r"\(([0-9A-Fa-f]{8})\)", val)
            if m2:
                cur["timestamp"] = int(m2.group(1), 16)
        elif key == "imagesize":
            cur["image_size"] = _unhex(val)
        elif key == "checksum":
            cur["checksum"] = _unhex(val)
    return mods


def parse_dps(text, modules=None):
    """[(stack_addr, va, stem, module_offset), ...] in stack order.

    THIS IS A SCRAPE. It is every qword on the stack that cdb annotated as
    living inside a module, which includes stale return addresses from calls
    that already returned. It is not a walk and callers must not print it as
    one.
    """
    out = []
    for raw in (text or "").splitlines():
        m = DPS_RX.match(raw.rstrip())
        if not m:
            continue
        sp, va = _unhex(m.group(1)), _unhex(m.group(2))
        if sp is None or va is None:
            continue
        stem = m.group(3)
        if modules is not None and stem not in modules:
            continue
        out.append((sp, va, stem, int(m.group(4), 16)))
    return out


def parse_registers(text):
    """{'rcx': int, ...} from an `.ecxr` register dump."""
    regs = {}
    for m in re.finditer(r"\b(r[a-z0-9]{1,3}|[er][a-z]{2})=([0-9a-fA-F`]{8,16})\b",
                         text or ""):
        v = _unhex(m.group(2))
        if v is not None:
            regs.setdefault(m.group(1), v)
    return regs


def mimalloc_message(dmp, regs, cdb=None, runner=None):
    """(string, note) -- the assertion/abort text, or (None, why).

    `da` on each argument register; keep the longest printable result that
    looks like a sentence. Nothing is inferred from the function name: if `da`
    yields no string, this says so and names nothing.
    """
    cands = [(r, regs[r]) for r in ARG_REGS
             if regs.get(r) and regs[r] > 0x10000]
    if not cands:
        return None, ("no argument register held a plausible pointer, so no "
                      "`da` was attempted")
    cmds = "; ".join("da 0x%X L40" % v for _r, v in cands) + "; q"
    text, note = cdb_run(dmp, cmds, cdb=cdb, runner=runner)
    if text is None:
        return None, note or "cdb did not run, so no string was read"
    found = []
    for raw in (text or "").splitlines():
        m = DA_RX.match(raw.rstrip())
        if not m:
            continue
        s = m.group(1).strip()
        if len(s) >= 8 and sum(ch.isalpha() for ch in s) >= 5:
            found.append(s)
    if not found:
        return None, ("`da` on %s yielded no printable string, so the "
                      "assertion text was NOT recovered (it is not guessed "
                      "from the function name)"
                      % ", ".join(r for r, _v in cands))
    found.sort(key=len, reverse=True)
    return found[0], None


# -- the command ------------------------------------------------------------

def _our_stems(ours=None):
    return set(m.lower().replace("_", "-")
               for m in (ours if ours is not None else our_modules()))


def _stem_of(mod):
    return str(mod).lower().replace("_", "-")


def symbolize_host_dump(dmp, ours=None, install_root=DEFAULT_INSTALL,
                        repo_mods=None, cdb=None, objdump=None,
                        cdb_runner=None, objdump_runner=None, indent="   ",
                        scrape_words=0x400, cdb_text=None, dps_text=None):
    """The `symbolize-host` block, as a list of lines.

    Every step states its own outcome, including "not performed". `cdb_text` /
    `dps_text` are injected by the tests so the whole pipeline is exercised
    against recorded output with no debugger present.
    """
    lines = ["HOST/MOD SYMBOLISATION of %s" % dmp]
    stems = _our_stems(ours)
    if cdb_text is None:
        cdb_text, note = cdb_run(
            dmp, ".ecxr; k 40; lm 1m; lmv m aowlspt*; lmv m *; q",
            cdb=cdb, runner=cdb_runner)
        if cdb_text is None:
            lines.append(indent + "NOT PERFORMED -- " + (note or "unstated"))
            return lines
    mods = parse_lmv(cdb_text)
    ourmods = {s: m for s, m in mods.items() if _stem_of(s) in stems}
    if not ourmods:
        lines.append(indent + "no module of ours is in the dump's module list "
                             "(%d module(s) listed), so there is nothing here "
                             "to symbolise" % len(mods))
        return lines
    regs = parse_registers(cdb_text)

    # Step 1+2: match each of our loaded modules to a build on disk and load
    # its COFF symbols.
    symtabs, base_of = {}, {}
    for stem, m in sorted(ourmods.items()):
        base_of[stem] = m.get("base")
        want = dict((k, m[k]) for k in ("timestamp", "image_size", "checksum")
                    if m.get(k) is not None)
        hs, why = load_host_symbols(want, _stem_of(stem),
                                    install_root=install_root,
                                    repo_mods=repo_mods, objdump=objdump,
                                    objdump_runner=objdump_runner)
        if hs is None:
            lines.append(indent + "%s @ 0x%X: %s"
                         % (stem, m.get("base") or 0, why))
            continue
        symtabs[stem] = hs
        lines.append(indent + "%s @ 0x%X -> %s" % (stem, m.get("base") or 0,
                                                   hs.how))
        if why:
            lines.append(indent + "    " + why)
    if not symtabs:
        lines.append(indent + "no build was matched, so NOTHING below is "
                              "symbolised")
        return lines

    def label(stem, va, why=False):
        hs, base = symtabs.get(stem), base_of.get(stem)
        if hs is None or base is None:
            return None
        rva = va - base
        got = hs.lookup(rva)
        if got is not None:
            return "%s+0x%X" % got
        if not why:
            return None
        # Saying WHICH of the two it is matters: a data address on the stack is
        # a local, not a return address, and reporting it as a function is the
        # exact failure this check exists to prevent.
        return ("(not code -- RVA 0x%X is in a data section, so it is a local "
                "or a heap pointer, not a return address)" % rva
                if hs.in_code(rva) is False
                else "(no preceding code symbol for RVA 0x%X)" % rva)

    # The walked frames cdb did produce, symbolised.
    walked = []
    seen_k = False
    for raw in (cdb_text or "").splitlines():
        line = raw.strip()
        if line.startswith("Child-SP"):
            seen_k = True
            continue
        if not seen_k or not line:
            continue
        m = re.search(r"(\S+)\+0x([0-9a-fA-F]+)$", line)
        if not m:
            if walked:
                break
            continue
        stem = m.group(1)
        if stem not in ourmods:
            walked.append((stem, None, line))
            continue
        va = (base_of.get(stem) or 0) + int(m.group(2), 16)
        walked.append((stem, va, line))
    lines.append(indent + "cdb walked %d frame(s):" % len(walked))
    for stem, va, raw in walked[:20]:
        lab = label(stem, va) if va is not None else None
        lines.append(indent + "    %s%s" % (raw, ("   -> " + lab) if lab else ""))
    if not walked:
        lines.append(indent + "    (none -- the walk produced no frames)")

    # Step 3: the scrape, only worth doing when the walk collapsed.
    if len(walked) <= 2:
        if dps_text is None:
            dps_text, dnote = cdb_run(dmp, ".ecxr; dps @rsp L%X; q"
                                      % scrape_words, cdb=cdb,
                                      runner=cdb_runner)
            if dps_text is None:
                lines.append(indent + "SCRAPE NOT PERFORMED -- "
                             + (dnote or "unstated"))
                dps_text = ""
        rows = parse_dps(dps_text, modules=ourmods)
        lines.append(indent + "the walk yielded %d frame(s), so `dps @rsp "
                              "L%X` was SCRAPED instead. THIS IS A SCRAPE, NOT "
                              "A WALK: it is every stack word pointing into "
                              "one of our modules, in address order, and it "
                              "can include stale return addresses from calls "
                              "that already returned."
                     % (len(walked), scrape_words))
        if not rows:
            lines.append(indent + "    no stack word pointed into one of our "
                                  "modules")
        shown = [r for r in rows if label(r[2], r[1]) is not None]
        dropped = len(rows) - len(shown)
        for sp, va, stem, off in shown[:40]:
            lines.append(indent + "    [rsp+0x%-5x] 0x%016X %s+0x%X   -> %s"
                         % (sp - rows[0][0], va, stem, off,
                            label(stem, va, why=True)))
        if len(shown) > 40:
            lines.append(indent + "    ... %d more scraped word(s)"
                         % (len(shown) - 40))
        if dropped:
            lines.append(indent + "    (%d further word(s) pointed into a "
                                  "DATA section of one of our modules and are "
                                  "not shown: they are locals or heap "
                                  "pointers, not return addresses)" % dropped)

    # Step 4: mimalloc.
    site = None
    for stem, va, _raw in walked:
        if va is not None:
            site = label(stem, va)
            break
    if site is None and regs.get("rip") is not None:
        for stem in symtabs:
            b = base_of.get(stem) or 0
            m = ourmods[stem]
            if b <= regs["rip"] < (m.get("end") or (b + (m.get("image_size")
                                                         or 0))):
                site = label(stem, regs["rip"])
                break
    if site:
        lines.append(indent + "crash site: %s" % site)
    if site and MIMALLOC_FN_RX.match(site):
        msg, why = mimalloc_message(dmp, regs, cdb=cdb, runner=cdb_runner)
        if msg:
            lines.append(indent + "mimalloc: the crash is inside the allocator "
                                  "and `da` on an argument register reads: %r"
                         % msg)
        else:
            lines.append(indent + "mimalloc: the crash is inside the "
                                  "allocator, but " + (why or "unstated"))
    return lines


def cmd_symbolize_host(argv):
    """`crashwatch.py symbolize-host <dmp|Crash_dir>` -- steps 1-4, one call."""
    rest = list(argv)
    if not rest:
        emit("usage: crashwatch.py symbolize-host <crash.dmp | Crash_* dir>")
        return 2
    target = rest.pop(0)
    if os.path.isdir(target):
        target = os.path.join(target, "crash.dmp")
    if not os.path.isfile(target):
        emit("no such dump: %s" % target)
        return 2
    for l in symbolize_host_dump(target):
        emit(l)
    return 0


def host_frames_present(rep, ours=None):
    """True when a Crash_* report has a frame in one of our modules whose
    symbol is missing or is dbghelp's nearest-export guess.

    The guess is detectable: dbghelp repeats ONE export name across many
    different addresses, because our DLLs export very few symbols. Three or
    more frames sharing a symbol is that, not three calls to one function.
    """
    if rep is None or not rep.ok:
        return False
    stems = _our_stems(ours)
    names = {}
    hit = False
    for f in rep.all_frames:
        if _stem_of(f.module) not in stems:
            continue
        s = (f.symbol or "").strip()
        if not s or "not available" in s.lower():
            hit = True
        names[s] = names.get(s, 0) + 1
    return hit or any(v >= 3 for k, v in names.items() if k)


def cmd_wer(argv):
    """`crashwatch.py wer [--since EPOCH|ISO] [--minutes N]` -- standalone."""
    since = time.time() - 3600.0
    rest = list(argv)
    if "--since" in rest:
        v = rest[rest.index("--since") + 1]
        try:
            since = float(v)
        except ValueError:
            since = time.mktime(time.strptime(v, "%Y-%m-%d %H:%M:%S"))
    if "--minutes" in rest:
        since = time.time() - 60.0 * float(rest[rest.index("--minutes") + 1])
    emit("since %s" % time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(since)))
    rep = newest_crash_report(since=since)
    folder = rep.folder if rep is not None else None
    if folder:
        emit("Crash_* folder newer than launch: %s" % folder)
    else:
        emit("no Crash_* folder newer than that time")
    lines, _kind, d = format_wer(since, crash_folder=folder)
    for l in lines:
        emit(l)
    # A WER dump of a fail-fast is exactly the case where cdb's `k` collapses
    # in our modules -- so the host/mod symbolisation runs on it automatically
    # rather than being a thing someone has to know to ask for.
    dumps = (d or {}).get("dumps") or []
    if dumps:
        for l in symbolize_host_dump(dumps[0]):
            emit(l)
    elif folder and os.path.isfile(os.path.join(folder, "crash.dmp")):
        for l in symbolize_host_dump(os.path.join(folder, "crash.dmp")):
            emit(l)
    return 0


def cmd_last(argv):
    """`crashwatch.py last [N]` -- the morning read, one command."""
    n = 3
    root = DEFAULT_CRASH_ROOT
    rest = list(argv)
    sym = "--no-symbolize" not in rest
    host = "--no-host-symbols" not in rest
    rest = [a for a in rest
            if a not in ("--no-symbolize", "--no-host-symbols")]
    if rest and rest[0].isdigit():
        n = int(rest.pop(0))
    if rest and rest[0] == "--root":
        rest.pop(0)
        root = rest.pop(0) if rest else root
    fs = crash_folders(root)
    if not fs:
        emit("no Crash_* folders under %s" % root)
        return 1
    for t, p in fs[:n]:
        rep = CrashReport(p, when=t)
        local = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(t))
        mod, source, frame, note = rep.attribute()
        if not rep.ok:
            emit("%s  %s  INCONCLUSIVE -- %s"
                 % (os.path.basename(p), local, rep.why))
            continue
        emit("%s  %s  %-22s %s"
             % (os.path.basename(p), local, mod,
                (frame.symbol or frame.addr) if frame else ""))
        emit("      %d crash-site frame(s), %d walked, modules: %s%s"
             % (len(rep.frames), len(rep.walked),
                ", ".join(sorted(rep.modules)[:8]),
                "" if source == "ours" else "   [nothing of ours at the site]"))
        if note:
            emit("      note: " + note)
        if sym:
            # The frames as METHODS, not as nearest exports. This is the first
            # thing anyone does with a crash report, and it used to be done by
            # hand.
            rows, why = symbolize_frames(rep.frames[:8], rep.modlines)
            if why:
                emit("      " + why)
            else:
                for f, s, per in rows:
                    if s is not None:
                        emit("      %s -> %s" % (f.addr, s.line()))
                    elif per:
                        emit("      %s -> %s" % (f.addr, per))
        # AND the half il2cpp_resolve cannot do: our OWN modules. Unity prints
        # `(function-name not available)` for them, or repeats one export name
        # across many addresses. Two agents did this by hand on 2026-09-03.
        if host and host_frames_present(rep):
            if os.path.isfile(rep.dump):
                for l in symbolize_host_dump(rep.dump):
                    emit("      " + l)
            else:
                emit("      host/mod frames are unsymbolised in this report, "
                     "and %s does not exist, so they were NOT symbolised "
                     "(that is inconclusive, not clean)" % rep.dump)
    return 0


def main():
    # `last` is a positional subcommand and is handled before argparse, which
    # this tool otherwise uses purely for flags.
    if sys.argv[1:2] == ["last"]:
        return cmd_last(sys.argv[2:])
    if sys.argv[1:2] == ["wer"]:
        return cmd_wer(sys.argv[2:])
    if sys.argv[1:2] == ["symbolize-host"]:
        return cmd_symbolize_host(sys.argv[2:])
    p = argparse.ArgumentParser(
        description="watch the live EFT client's logs; kill + report on a crash",
        formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    p.add_argument("--logs", default=DEFAULT_LOGS,
                   help="client log root (default %s)" % DEFAULT_LOGS)
    p.add_argument("--watch", action="store_true",
                   help="keep monitoring across relaunches (default: one-shot)")
    p.add_argument("--kill-on", action="append", metavar="SIGNATURE",
                   help="ARM killing for this signature (repeatable). Without "
                        "this (or --kill-any) the tool NEVER kills anything. "
                        "Signatures: unhandled-exception, aggregate-exception, "
                        "raid-load-abort, matchmaking-timeout")
    p.add_argument("--kill-any", action="store_true",
                   help="ARM killing for every killable signature (the old, "
                        "and dangerous, default behaviour)")
    p.add_argument("--allow-duplicates", action="store_true",
                   help="start even if another crashwatch --watch is running")
    p.add_argument("--dry-run", action="store_true",
                   help="with --kill-on/--kill-any, report what WOULD be "
                        "killed without killing it")
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
    p.add_argument("--host-log", default=DEFAULT_HOST_LOG,
                   help="aowlspt-host.log, tailed for ERRORDIALOG lines -- the "
                        "in-game error dialog, which the client's own logs "
                        "never mention (default: %(default)s)")
    p.add_argument("--no-host", action="store_true",
                   help="do not watch the host log. An in-game error dialog "
                        "will then be undetectable and will look like an idle "
                        "client, which is the failure this watcher exists to "
                        "end -- so only pass this if the host is not running.")
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
