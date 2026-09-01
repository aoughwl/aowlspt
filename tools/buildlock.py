#!/usr/bin/env python3
r"""buildlock.py -- ONE build at a time per checkout. A mechanism, not a rule.

    python tools/buildlock.py build host
    python tools/buildlock.py build examples
    python tools/buildlock.py --wait 900 build mods
    python tools/buildlock.py --status
    python tools/buildlock.py --steal          # only when the holder is dead

Anything after the options is passed to `aowl` verbatim, so this is a drop-in
prefix for any build command.

## Why this exists

CLAUDE.md section 3 has said for a long time that concurrent builds in the SAME
checkout corrupt each other (concurrent builds in separate git worktrees are
measured safe). It is written down, it is explained, and it is agreed to.

It was violated anyway, on 2026-09-01, by the session that had written the rule
into CLAUDE.md an hour earlier. A subagent was running `aowl build host`; the
coordinator ran `aowl build examples` in the same checkout. Two `aowl` and two
`nimony` processes ran at once and **neither** produced an artifact --
`deploy.py check` reported the host DLL simply "not built", and the examples
output directory was empty. Roughly twenty minutes of subagent work had to be
redone.

The reasoning that produced the violation is worth recording, because it is
seductive: *"I am only building a DIFFERENT target, so this is not the case the
rule is about."* It is exactly the case the rule is about. The hazard is the
shared intermediate/output directory and the shared compiler working state, not
the identity of the final artifact.

**A rule in a document cannot fail closed. A lock can.** Every process that
takes this lock is safe from every other process that takes it, and the ones
that do not take it are visible in `--status` by their absence rather than
silently colliding.

## What it guarantees, and what it does not

Guarantees: two invocations OF THIS SCRIPT in the same checkout never run their
build commands concurrently. The lock is per-checkout (keyed on the repo root),
so separate worktrees still build in parallel at full speed -- that property is
measured and valuable and is deliberately not taken away.

Does NOT guarantee: anything about a build started by invoking `aowl` directly.
This is advisory. It is worth having anyway, because the failure it prevents is
silent and expensive while the cost of using it is one word on a command line.

## Staleness, which is the part that is easy to get wrong

A lock file left behind by a killed build would block the checkout forever, so
the holder's PID is recorded and checked for liveness. But "the PID is gone"
must not be confused with "the PID is gone AND this is the same boot" -- PIDs
are recycled. The lock therefore records the start time alongside the PID, and
treats a lock as stale only when the process is absent OR the lock is older
than --max-age (default 2h, comfortably longer than the 18m cold build measured
in this repo). Anything else requires an explicit `--steal`, which prints who
is being evicted rather than doing it quietly.
"""

from __future__ import annotations

import argparse
import errno
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

# A cold `aowl build` is measured at ~18m in this repo; a warm one ~4m27s, and a
# named target ~2m. Two hours is far past any of those, so a lock older than
# this is a leftover rather than a slow build.
DEFAULT_MAX_AGE = 2 * 60 * 60


def lock_path(repo):
    return os.path.join(repo, ".aowl-build.lock")


def pid_alive(pid):
    """True if the pid is running. Windows has no kill(0), so ask the OS.

    Returns True on any inconclusive answer: refusing to declare a lock stale
    is the safe direction, since a wrong 'stale' verdict is exactly the
    concurrent build this file exists to prevent.

    MEASURED LIMITATION, found while trying to falsify this file. `tasklist`
    enumerates WINDOWS pids. A pid from another namespace -- notably Git Bash's
    `$!`, which is an MSYS pid -- is NOT in that list, so this returns False and
    the lock is broken as stale even though a process is genuinely running.

    That is harmless for real holders, because a real holder records
    `os.getpid()` from the Python process running the build, which IS a Windows
    pid. It matters for anyone hand-planting a lock in a test: use
    `subprocess.Popen(...).pid`, not a shell job id. Two attempts to falsify
    this guard silently "passed" for exactly that reason -- the refusal path was
    never reached, and a test that cannot reach the branch it claims to test is
    the bug this repo keeps finding (CLAUDE.md 9b).
    """
    if pid <= 0:
        return False
    if os.name == "nt":
        try:
            out = subprocess.run(
                ["tasklist", "/FI", "PID eq %d" % pid, "/NH"],
                capture_output=True, text=True, timeout=20).stdout
        except Exception:
            return True
        return str(pid) in out
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except Exception:
        return True


def read_lock(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def acquire(path, cmd, wait_s, max_age, steal):
    """Take the lock, or explain precisely why not. Returns True on success."""
    deadline = time.time() + wait_s
    announced = False
    while True:
        me = {"pid": os.getpid(), "cmd": cmd, "started": time.time(),
              "started_h": time.strftime("%Y-%m-%d %H:%M:%S")}
        try:
            fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(me, f)
            return True
        except OSError as e:
            if e.errno != errno.EEXIST:
                raise

        held = read_lock(path)
        if held is None:
            # Present but unreadable -- a partially written lock. Treat as held
            # briefly rather than racing to delete it.
            time.sleep(1.0)
            if time.time() >= deadline:
                print("BLOCKED: %s exists but could not be read. If no build "
                      "is running, delete it." % path)
                return False
            continue

        pid = int(held.get("pid", -1))
        age = time.time() - float(held.get("started", 0))
        alive = pid_alive(pid)

        if steal or not alive or age > max_age:
            why = ("--steal was passed" if steal else
                   "the holder (pid %d) is not running" % pid if not alive else
                   "the lock is %.0fs old, past --max-age %ds" % (age, max_age))
            print("breaking a stale lock: %s. It was taken by pid %d for %r at "
                  "%s." % (why, pid, held.get("cmd"), held.get("started_h")))
            try:
                os.unlink(path)
            except OSError:
                pass
            continue

        if not announced:
            print("WAITING for the build lock: pid %d has been running %r for "
                  "%.0fs (since %s).\n  Concurrent builds in ONE checkout "
                  "corrupt each other -- separate git worktrees are safe and "
                  "do not contend. Waiting up to %.0fs."
                  % (pid, held.get("cmd"), age, held.get("started_h"), wait_s),
                  flush=True)
            announced = True

        if time.time() >= deadline:
            print("REFUSED: the build lock is held by pid %d (%r, running "
                  "%.0fs) and did not free within %.0fs. NOTHING WAS BUILT. "
                  "This is the guard working: running anyway is what wipes "
                  "both artifacts."
                  % (pid, held.get("cmd"), age, wait_s))
            return False
        time.sleep(2.0)


def release(path):
    """Drop the lock, but only if it is still OURS.

    A build that overran --max-age can have had its lock broken and retaken by
    someone else; deleting unconditionally would then evict the innocent holder
    and produce the exact collision this prevents.
    """
    held = read_lock(path)
    if held and int(held.get("pid", -1)) != os.getpid():
        print("not releasing the build lock: it now belongs to pid %s (%r). "
              "Ours was broken as stale while we ran."
              % (held.get("pid"), held.get("cmd")))
        return
    try:
        os.unlink(path)
    except OSError:
        pass


def aowl_exe(repo):
    p = os.path.join(repo, "installer", "build", "aowl.exe")
    return p if os.path.exists(p) else "aowl"


def main():
    p = argparse.ArgumentParser(
        description="serialise `aowl build` within one checkout",
        formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    p.add_argument("--repo", default=REPO)
    p.add_argument("--wait", type=float, default=1800.0,
                   help="seconds to wait for the lock (default 1800; a cold "
                        "build is ~18m)")
    p.add_argument("--max-age", type=int, default=DEFAULT_MAX_AGE)
    p.add_argument("--steal", action="store_true",
                   help="break the lock even if the holder looks alive. Only "
                        "when you KNOW the holder is dead.")
    p.add_argument("--status", action="store_true",
                   help="say who holds the lock, and exit")
    p.add_argument("rest", nargs=argparse.REMAINDER,
                   help="the aowl arguments, e.g. `build host`")
    a = p.parse_args()

    path = lock_path(a.repo)

    if a.status:
        held = read_lock(path)
        if not held:
            print("build lock FREE (%s)" % path)
            return 0
        pid = int(held.get("pid", -1))
        print("build lock HELD by pid %d (%s) %r since %s -- %.0fs ago"
              % (pid, "running" if pid_alive(pid) else "NOT RUNNING (stale)",
                 held.get("cmd"), held.get("started_h"),
                 time.time() - float(held.get("started", 0))))
        return 1

    rest = [x for x in a.rest if x != "--"]
    if not rest:
        print("nothing to run. Example: python tools/buildlock.py build host")
        return 2

    cmd = [aowl_exe(a.repo)] + rest
    if not acquire(path, " ".join(rest), a.wait, a.max_age, a.steal):
        return 4

    t0 = time.time()
    try:
        print("build lock ACQUIRED by pid %d for %r" % (os.getpid(),
                                                        " ".join(rest)),
              flush=True)
        rc = subprocess.run(cmd, cwd=a.repo).returncode
    finally:
        release(path)
    print("%r finished in %.0fs with exit %d (lock released)"
          % (" ".join(rest), time.time() - t0, rc))
    return rc


if __name__ == "__main__":
    sys.exit(main())
