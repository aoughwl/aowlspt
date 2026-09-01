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

This watcher tails the CLIENT's OWN logs under D:\Aowlspt\Logs (not the host
log; that is harness.py's job -- see the note at the bottom of this docstring).
It never reads a whole log: it seeks to the current end and reads only new bytes
as they are written, so a 230 KB output_000.log costs nothing.

    python tools/crashwatch.py               # one-shot: observe + report, exit
    python tools/crashwatch.py --watch       # keep observing across relaunches
    python tools/crashwatch.py --watch --kill-on matchmaking-timeout
                                             # ARM the kill, for ONE signature
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


def main():
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
