#!/usr/bin/env python3
r"""buildlock.py -- ONE build at a time per checkout. A mechanism, not a rule.

    python tools/buildlock.py build host
    python tools/buildlock.py build examples
    python tools/buildlock.py --wait 900 build mods
    python tools/buildlock.py --status
    python tools/buildlock.py --status --json  # machine-readable; see below
    python tools/buildlock.py --wait-free 600  # block until nobody is building
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

## Asking the lock a question from a script

`--status` prints prose for a human, and prose is not an interface. An agent
wrote a wait loop that matched the substring `"build lock is FREE"` -- a string
this file has never printed -- so the loop never fired and the agent waited for
nothing. That is the failure mode CLAUDE.md 9b is about: a check that cannot
succeed reads exactly like a check that has not succeeded YET.

So there are now two contracts that do not depend on reading English:

* `--status --json` prints ONE json object: `state` (`free`/`held`/`stale`),
  `pid`, `running`, `target`, `since`, `since_epoch`, `age_s`, `queue`, `lock`,
  plus `queued_since` / `queued_arrival` (when the HOLDER joined the queue) and
  `fifo` (`ok` / `INVERTED` / `unknown`).

## `since` is not `arrived`, and that cost a session

MEASURED 2026-09-02 01:35: `--status` printed a holder `since 01:22:41` above
`queued 1: pid 13160 ... since 01:19:27 <- next`, and it read as a waiter being
passed over by a later arrival. It was not. The holder's `since` is when it
ACQUIRED; a queue line's `since` is when that waiter ARRIVED. A process that
joined the queue at 01:18 and won the lock at 01:22:41 is perfectly FIFO and
looked exactly like a bug. The ordering tests could not reproduce it because
there was nothing to reproduce -- `tools/test_buildlock.py` now also races a
warm waiter into the millisecond of the release (`run_release_window`) and the
queue still wins, with an unfair control that loses 3/3.

So the lock record now carries the holder's queue ARRIVAL, `--status` prints it
next to the acquire time, and `fifo` states the comparison outright. `unknown`
is a real outcome: a lock file predating this field, or one taken via `--steal`
(no ticket), CANNOT be compared, and saying `ok` there would be a check that
cannot fail.
* `--status` EXIT CODE: **0 free, 1 held by a live process, 2 held by a dead
  one (stale)**. Note that 1 and 2 used to both be 1; a script that only tested
  `rc == 0` is unaffected.

  The report goes to **stdout in every state**, and stderr stays empty --
  measured 2026-09-02 and pinned by `test_status_streams` in
  `tools/test_buildlock.py`, after an agent reported it "prints to stderr".
  It does not. What it does do is exit **non-zero while perfectly healthy**,
  and that is the trap: `subprocess.run(..., check=True)` raises, and a
  harness that renders a failed command as an error can fold the body away.
  Either way the caller sees no text and may conclude the lock is free while
  a build is running. Read stdout regardless of the exit code, or use
  `--json` and the `state` field.

The human text is deliberately unchanged, because things already read it.

`--wait-free [SECONDS]` blocks until the lock is free (or stale, which the next
acquirer will break) and exits 0, or exits 1 on timeout. It is a HINT, not a
reservation: nothing stops someone taking the lock in the microsecond after it
returns. The only thing that serialises a build is running the build THROUGH
this script.

## The env var

The child build runs with `AOWL_BUILDLOCK=<pid of this script>`. `aowl` refuses
to build when it is absent, so `aowl.exe build host` typed by hand -- which
corrupted this checkout's nimcache twice on 2026-09-01 while `--status` read
FREE, because an unlocked build is invisible to the lock by construction -- now
stops instead of colliding. `aowl build --no-lock` is the deliberate escape,
for bootstrap and CI.
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


def queue_dir(repo_or_lock):
    """The FIFO queue lives beside the lock, one small file per waiter.

    ## Why fairness had to be added

    The lock was correct and unfair. It was pure retry: every waiter slept two
    seconds and raced for `O_EXCL`, so whoever happened to call at the right
    moment won, and a waiter could be passed over indefinitely by a stream of
    later arrivals. Measured on 2026-09-01: an agent's `build launch` waited
    roughly FORTY MINUTES while other agents in the same checkout took the lock
    repeatedly. It was never blocked -- it just kept losing the coin toss.

    ## The layering, which matters more than the queue

    `O_EXCL` is still the ONLY thing providing mutual exclusion. The queue only
    decides who is allowed to *attempt* the create. So a bug in the fairness
    logic can make the lock unfair again -- it cannot make it unsafe, and it
    cannot let two builds run at once. Fairness is advisory; exclusion is not.
    That is deliberate: the expensive failure here is two concurrent builds,
    and no ordering scheme should be able to reintroduce it.

    A ticket is `<arrival_ns>-<pid>.json`. Ordering is by (arrival, pid), which
    is a total order, so every waiter independently computes the same winner
    without needing to agree with anyone.
    """
    base = repo_or_lock
    if base.endswith(".lock"):
        base = os.path.dirname(base)
    return os.path.join(base, ".aowl-build.queue")


def _ticket_name(arrival_ns, pid):
    return "%020d-%d.json" % (arrival_ns, pid)


def join_queue(qdir, cmd):
    """Take a ticket. Returns its path."""
    os.makedirs(qdir, exist_ok=True)
    arrival = time.time_ns()
    p = os.path.join(qdir, _ticket_name(arrival, os.getpid()))
    tmp = p + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump({"pid": os.getpid(), "cmd": cmd, "arrival": arrival,
                   "arrival_h": time.strftime("%Y-%m-%d %H:%M:%S")}, f)
    os.replace(tmp, p)
    return p


def ticket_arrival(ticket):
    """The arrival_ns encoded in a ticket filename, or None.

    The lock record carries this forward so that `--status` can compare the
    HOLDER and the WAITERS on one clock. See print_status_human().
    """
    if not ticket:
        return None
    try:
        return int(os.path.basename(ticket).split("-", 1)[0])
    except (ValueError, IndexError):
        return None


def leave_queue(ticket):
    if not ticket:
        return
    try:
        os.unlink(ticket)
    except OSError:
        pass


def read_queue(qdir, max_age):
    """Every LIVE waiter, oldest first. Dead and ancient tickets are pruned.

    Pruning is not housekeeping, it is correctness: a waiter that was killed
    would otherwise sit at the head of the queue for ever and nobody would ever
    build again -- a fairness mechanism that can deadlock the thing it is
    ordering is worse than the unfairness it replaced.
    """
    out = []
    try:
        names = sorted(os.listdir(qdir))
    except OSError:
        return out
    now = time.time_ns()
    for n in names:
        if not n.endswith(".json"):
            continue
        p = os.path.join(qdir, n)
        try:
            with open(p, "r", encoding="utf-8") as f:
                t = json.load(f)
        except Exception:
            # Unreadable or half-written. Skip it this pass rather than
            # deleting it; a ticket being written right now is not stale.
            continue
        pid = int(t.get("pid", -1))
        age_s = (now - int(t.get("arrival", 0))) / 1e9
        if age_s > max_age or not pid_alive(pid):
            try:
                os.unlink(p)
            except OSError:
                pass
            continue
        t["_path"] = p
        out.append(t)
    out.sort(key=lambda t: (int(t.get("arrival", 0)), int(t.get("pid", 0))))
    return out


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


STATUS_EXIT = {"free": 0, "held": 1, "stale": 2}


def status(path, max_age):
    """One dict describing the lock. The single source for text AND --json.

    Three states, never two: `free`, `held` (a live process is building) and
    `stale` (a lock file whose holder is gone, which the next acquirer will
    break). Collapsing `stale` into `held` is how a waiter ends up waiting for
    a process that died -- and collapsing it into `free` would hide a crashed
    build entirely.
    """
    q = read_queue(queue_dir(path), max_age)
    qout = [{"pid": t.get("pid"), "target": t.get("cmd"),
             "since": t.get("arrival_h"), "arrival": t.get("arrival")}
            for t in q]
    held = read_lock(path)
    if not held:
        return {"state": "free", "pid": None, "running": None, "target": None,
                "since": None, "since_epoch": None, "age_s": None,
                "queued_since": None, "queued_arrival": None, "fifo": "n/a",
                "queue": qout, "lock": path}
    pid = int(held.get("pid", -1))
    running = pid_alive(pid)
    started = float(held.get("started", 0))
    return {"state": "held" if running else "stale",
            "pid": pid, "running": running, "target": held.get("cmd"),
            "since": held.get("started_h"), "since_epoch": started,
            "age_s": time.time() - started,
            "queued_since": held.get("arrival_h"),
            "queued_arrival": held.get("arrival"),
            "fifo": fifo_verdict(held, q),
            "queue": qout, "lock": path}


def fifo_verdict(held, q):
    """`ok` / `INVERTED` / `unknown` -- three outcomes, never two.

    An inversion is only a claim worth making when both sides are on the SAME
    clock: the holder's QUEUE ARRIVAL against the waiters' queue arrivals. A
    lock file written before this field existed, or one taken via --steal (no
    ticket), carries no arrival -- that is `unknown`, an honest "I could not
    compare", and it must never be reported as `ok`. Reporting an
    uncomparable pair as ok is the check-that-cannot-fail (CLAUDE.md 9b);
    reporting it as INVERTED would be the confidently wrong answer that sent a
    session hunting a bug the ordering tests could not reproduce.
    """
    mine = held.get("arrival")
    if not mine:
        return "unknown"
    for t in q:
        if int(t.get("arrival", 0)) < int(mine):
            return "INVERTED"
    return "ok"


def print_status_human(st):
    """The text a person reads. UNCHANGED on purpose -- scripts should use
    --json or the exit code, but existing eyes and greps should not break."""
    if st["state"] == "free":
        print("build lock FREE (%s)" % st["lock"])
        for i, t in enumerate(st["queue"]):
            print("  queued %d: pid %s %r since %s"
                  % (i + 1, t["pid"], t["target"], t["since"]))
        return
    print("build lock HELD by pid %d (%s) %r since %s -- %.0fs ago"
          % (st["pid"], "running" if st["running"] else "NOT RUNNING (stale)",
             st["target"], st["since"], st["age_s"]))
    # `since` above is when the holder WON the lock; the queue lines below are
    # when each waiter ARRIVED. Print the holder's arrival too, or the two
    # columns are on different clocks and a fair handoff reads as a queue-jump.
    if st.get("queued_since"):
        print("  (that is when it ACQUIRED; it joined the queue at %s -- "
              "the queue times below are arrivals, so compare against this "
              "one)" % st["queued_since"])
    elif st["queue"]:
        print("  (that is when it ACQUIRED, not when it queued -- this lock "
              "records no arrival time, so it CANNOT be compared with the "
              "arrival times below. Not an inversion; not checked.)")
    for i, t in enumerate(st["queue"]):
        print("  queued %d: pid %s %r since %s (arrived)%s"
              % (i + 1, t["pid"], t["target"], t["since"],
                 "   <- next" if i == 0 else ""))
    if st.get("fifo") == "INVERTED":
        print("  FIFO INVERTED: the holder joined the queue AFTER a waiter "
              "that is still waiting. That is a real fairness bug, measured "
              "on comparable clocks -- report it with this output.")


def wait_free(path, max_age, timeout, poll=1.0, announce=True):
    """Block until nobody is building. Returns the final status, or None on
    timeout.

    `stale` counts as free: the next acquirer breaks a stale lock itself, so
    waiting for it to disappear would be waiting for a dead process to tidy up.
    The reason is printed rather than assumed.

    This does NOT reserve anything (see the module docstring). It exists so a
    wait loop can be written without parsing prose.
    """
    deadline = time.time() + timeout
    announced = False
    while True:
        st = status(path, max_age)
        if st["state"] != "held":
            return st
        if announce and not announced:
            announced = True
            print("waiting for the build lock: pid %s has been running %r for "
                  "%.0fs. Up to %.0fs."
                  % (st["pid"], st["target"], st["age_s"], timeout),
                  flush=True)
        if time.time() >= deadline:
            return None
        time.sleep(min(poll, max(0.0, deadline - time.time()) + 0.01))


def acquire(path, cmd, wait_s, max_age, steal):
    """Take the lock, or explain precisely why not. Returns True on success.

    FIFO: a ticket is taken first, and the `O_EXCL` create is only attempted
    when we are the oldest LIVE waiter. `--steal` skips the queue, because it
    already means "I know what I am doing to the current holder".
    """
    qdir = queue_dir(path)
    # A one-element cell, because the ticket can be REPLACED mid-wait (see the
    # requeue path). Cleaning up the ticket we started with would leave the
    # replacement behind, and an abandoned ticket at the head of the queue
    # stalls everyone until its pid is noticed to be gone.
    slot = [join_queue(qdir, cmd)]
    try:
        return _acquire_queued(path, qdir, slot[0], cmd, wait_s, max_age,
                               steal, slot)
    except BaseException:
        leave_queue(slot[0])
        raise


def race_acquire(path, cmd, wait_s, max_age, steal):
    """The OLD, UNFAIR algorithm: no ticket, everyone races for `O_EXCL`.

    Kept for exactly one reason: `tools/test_buildlock.py` needs something that
    CAN let the later arrival win. Without it the FIFO test asserts an ordering
    that a coin-toss would also produce most of the time, and an ordering test
    with no losing counterpart is the check-that-cannot-fail this repo keeps
    finding (CLAUDE.md 9b). It is not used by `main` and must not be.
    """
    return _acquire_queued(path, None, None, cmd, wait_s, max_age, steal,
                           None)


def _acquire_queued(path, qdir, ticket, cmd, wait_s, max_age, steal,
                    slot=None):
    deadline = time.time() + wait_s
    announced = False
    yielded_to = None
    requeues = 0
    while True:
        # AM I NEXT? Checked before the create is attempted, so a later arrival
        # cannot win the race against an earlier one that happens to be asleep.
        if not steal and ticket is not None:
            q = read_queue(qdir, max_age)
            # Position is recomputed EVERY pass, not only when the head
            # changes. It used to be computed inside the "the head changed"
            # branch and then reused by the refusal message many polls later,
            # so a refusal could name a position we had long since left.
            pos = next((i for i, t in enumerate(q)
                        if t.get("_path") == ticket), -1)
            if pos < 0:
                # OUR OWN TICKET IS GONE. read_queue prunes on a liveness
                # probe, and that probe (`tasklist`) can answer "not running"
                # for a running process -- an empty stdout from a transient
                # failure is indistinguishable from a real absence. Whatever
                # the cause, we are no longer IN the queue, and the old code
                # then fell through to the O_EXCL create with q[0] belonging
                # to somebody else -- i.e. it jumped the queue, silently.
                # Re-join instead: that costs us our place, which is honest,
                # and never takes anyone else's.
                requeues += 1
                if requeues > 3:
                    print("GIVING UP ON THE QUEUE after %d lost tickets; "
                          "falling back to racing for the lock. Exclusion is "
                          "unaffected -- ORDER IS NOT GUARANTEED from here."
                          % requeues, flush=True)
                    ticket = None
                    if slot is not None:
                        slot[0] = None
                    continue
                ticket = join_queue(qdir, cmd)
                if slot is not None:
                    slot[0] = ticket
                yielded_to = None
                print("REQUEUED: our queue ticket disappeared (a liveness "
                      "probe pruned it, or it was cleaned up) -- taking a new "
                      "one at the BACK rather than jumping the queue.",
                      flush=True)
                time.sleep(0.2)
                continue
            if q[0].get("_path") != ticket:
                head = q[0]
                if yielded_to != head.get("_path"):
                    yielded_to = head.get("_path")
                    print("QUEUED at position %d of %d: pid %s (%r) arrived "
                          "first and is next for the lock."
                          % (pos + 1, len(q), head.get("pid"),
                             head.get("cmd")), flush=True)
                if time.time() >= deadline:
                    print("REFUSED: still position %d in the build queue after "
                          "%.0fs. NOTHING WAS BUILT."
                          % (pos + 1, wait_s))
                    leave_queue(ticket)
                    return False
                time.sleep(1.0)
                continue

        arrival_ns = ticket_arrival(ticket)
        me = {"pid": os.getpid(), "cmd": cmd, "started": time.time(),
              "started_h": time.strftime("%Y-%m-%d %H:%M:%S"),
              # WHEN WE JOINED THE QUEUE, not when we won it. Without this the
              # holder's only timestamp is its acquire time, and `--status`
              # then prints the holder's acquire time next to the waiters'
              # ARRIVAL times -- two different clocks, side by side, with no
              # label. A holder that queued at 01:18 and acquired at 01:22:41
              # while a waiter arrived at 01:19:27 is perfectly FIFO and reads
              # as a queue-jump. That misreading is what sent a session hunting
              # a fairness bug that the ordering tests could not reproduce.
              "arrival": arrival_ns,
              "arrival_h": (time.strftime(
                  "%Y-%m-%d %H:%M:%S", time.localtime(arrival_ns / 1e9))
                  if arrival_ns else None)}
        try:
            fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(me, f)
            # Out of the queue the moment the lock is HELD, not before: leaving
            # earlier would let the next waiter believe it was head while we
            # were still between the check and the create.
            leave_queue(ticket)
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
                leave_queue(ticket)
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
            leave_queue(ticket)
            return False
        # One second, not two: this is now a HANDOFF, not a race. The head of
        # the queue is the only process attempting the create, so a shorter
        # poll costs nothing in contention and shortens the gap between one
        # build releasing and the next starting.
        time.sleep(1.0)


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
                   help="say who holds the lock, and exit. Exit 0 free, "
                        "1 held, 2 stale.")
    p.add_argument("--json", action="store_true",
                   help="with --status: print ONE json object instead of "
                        "prose (state/pid/running/target/since/queue)")
    p.add_argument("--wait-free", type=float, nargs="?", const=1800.0,
                   default=None, dest="wait_free", metavar="SECONDS",
                   help="block until the lock is free, then exit 0; exit 1 on "
                        "timeout (default 1800s). Runs nothing.")
    p.add_argument("rest", nargs=argparse.REMAINDER,
                   help="the aowl arguments, e.g. `build host`")
    a = p.parse_args()

    path = lock_path(a.repo)

    if a.status:
        st = status(path, a.max_age)
        if a.json:
            print(json.dumps(st))
        else:
            print_status_human(st)
        return STATUS_EXIT[st["state"]]

    rest = [x for x in a.rest if x != "--"]

    if a.wait_free is not None:
        if rest:
            print("--wait-free runs NOTHING. To wait and then build, use "
                  "`--wait %.0f %s`." % (a.wait_free, " ".join(rest)))
            return 2
        # In --json mode stdout is a DATA channel: the "waiting for..." line
        # would sit in front of the object and make it unparseable, which is
        # the same class of bug as the prose-matching wait loop this exists to
        # replace. It cost two test failures here before it cost anyone else.
        st = wait_free(path, a.max_age, a.wait_free, announce=not a.json)
        if st is None:
            cur = status(path, a.max_age)
            msg = ("still HELD by pid %s (%r) after %.0fs"
                   % (cur["pid"], cur["target"], a.wait_free))
            if a.json:
                print(json.dumps({"state": "timeout", "waited_s": a.wait_free,
                                  "status": cur}))
            else:
                print("TIMEOUT: %s. NOTHING WAS WAITED OUT." % msg)
            return 1
        if a.json:
            print(json.dumps(st))
        elif st["state"] == "stale":
            print("build lock is free enough: the lock file is present but "
                  "its holder (pid %s) is NOT RUNNING, so the next build "
                  "breaks it as stale." % st["pid"])
        else:
            print("build lock FREE (%s)" % path)
        return 0

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
        # The proof-of-lock the child checks for. `aowl` refuses to build
        # without it, which turns "please use the lock" from a rule into a
        # mechanism -- the hand-typed `aowl.exe build host` that corrupted this
        # checkout's nimcache was invisible to the lock precisely because not
        # taking a lock leaves no trace anywhere.
        env = dict(os.environ)
        env["AOWL_BUILDLOCK"] = str(os.getpid())
        rc = subprocess.run(cmd, cwd=a.repo, env=env).returncode
    finally:
        release(path)
    print("%r finished in %.0fs with exit %d (lock released)"
          % (" ".join(rest), time.time() - t0, rc))
    return rc


if __name__ == "__main__":
    sys.exit(main())
