#!/usr/bin/env python3
r"""test_buildlock.py -- the build lock is FIFO, and the test can fail.

    python tools/test_buildlock.py

## What is being checked

The lock was correct and unfair. It was pure retry: every waiter slept and
raced for `O_EXCL`, so the winner was whoever happened to wake at the right
moment. Measured 2026-09-01: an agent's `build launch` waited about FORTY
MINUTES while other agents in the same checkout took the lock repeatedly. It
was never blocked; it kept losing the toss.

So the property under test is an ORDERING one, and ordering tests are the
easiest kind to write so that they cannot fail. Two guards against that here:

  * the NEGATIVE CONTROL runs the same scenario against the old, unfair
    algorithm (`race_acquire` below, a faithful copy of what the code used to
    do). If the fair run and the unfair run cannot be told apart, the scenario
    is not exercising fairness and the test says so.
  * every child reports the time it acquired, so "B won" and "B and A both
    ran" are distinguishable -- the second would be a mutual-exclusion
    failure, which is a far worse bug than unfairness and must never be
    reported as a pass.

Everything runs against a throwaway lock directory. It never touches the real
checkout's `.aowl-build.lock`, and it never runs a build.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import buildlock  # noqa: E402

FAILURES = []


def check(name, cond, detail=""):
    if cond:
        print("  PASS  %s" % name)
    else:
        print("  FAIL  %s   %s" % (name, detail))
        FAILURES.append(name)


CHILD = r'''
import json, os, sys, time
sys.path.insert(0, r"%(here)s")
import buildlock
path, out, label, mode = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
if mode == "fair":
    ok = buildlock.acquire(path, label, 60, 7200, False)
else:
    ok = buildlock.race_acquire(path, label, 60, 7200, False)
rec = {"label": label, "ok": bool(ok), "at": time.time(), "pid": os.getpid()}
with open(out, "a", encoding="utf-8") as f:
    f.write(json.dumps(rec) + "\n")
if ok:
    # Hold it briefly so a second winner would be a visible overlap rather
    # than an instantaneous handoff.
    time.sleep(1.5)
    buildlock.release(path)
'''


def plant_holder(path):
    """A REAL live process holding the lock.

    It must be a Windows pid: `pid_alive` shells out to tasklist, and a Git
    Bash job id is an MSYS pid that tasklist cannot see -- a lock planted that
    way reads as stale and gets broken, so the waiters never wait and the test
    passes without reaching the code it claims to test. buildlock's own
    docstring records two earlier attempts that failed exactly this way.
    """
    p = subprocess.Popen([sys.executable, "-c",
                          "import time; time.sleep(30)"])
    with open(path, "w", encoding="utf-8") as f:
        json.dump({"pid": p.pid, "cmd": "planted holder",
                   "started": time.time(),
                   "started_h": time.strftime("%Y-%m-%d %H:%M:%S")}, f)
    return p


def run_scenario(mode, tmp):
    """Holder, then waiter A, then waiter B. Release. Who wins?"""
    repo = os.path.join(tmp, mode)
    os.makedirs(repo, exist_ok=True)
    path = buildlock.lock_path(repo)
    out = os.path.join(repo, "order.jsonl")
    holder = plant_holder(path)
    child = os.path.join(repo, "child.py")
    with open(child, "w", encoding="utf-8") as f:
        f.write(CHILD % {"here": HERE})

    procs = []
    a = subprocess.Popen([sys.executable, child, path, out, "A", mode],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    procs.append(a)
    # A must be established as a waiter BEFORE B exists, or there is no
    # ordering to test. For the fair mode that means its ticket is on disk.
    qd = buildlock.queue_dir(path)
    deadline = time.time() + 20
    while time.time() < deadline:
        if mode == "fair":
            if any(n.endswith(".json") for n in
                   (os.listdir(qd) if os.path.isdir(qd) else [])):
                break
        else:
            time.sleep(2.0)
            break
        time.sleep(0.05)
    time.sleep(1.0)
    b = subprocess.Popen([sys.executable, child, path, out, "B", mode],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    procs.append(b)

    time.sleep(2.0)
    holder.kill()
    holder.wait()
    try:
        os.unlink(path)
    except OSError:
        pass

    for p in procs:
        p.wait(timeout=90)

    rows = []
    if os.path.exists(out):
        with open(out, encoding="utf-8") as f:
            for line in f:
                if line.strip():
                    rows.append(json.loads(line))
    rows.sort(key=lambda r: r["at"])
    return rows


def main():
    print("buildlock: FIFO fairness")
    tmp = tempfile.mkdtemp(prefix="buildlock-test-")
    try:
        print("\nfair mode (the queue)")
        fair = run_scenario("fair", tmp)
        order = [r["label"] for r in fair if r["ok"]]
        print("    acquisition order: %s" % (order or "NOBODY ACQUIRED"))
        check("both waiters eventually acquired",
              sorted(order) == ["A", "B"], str(order))
        check("A (the EARLIER arrival) acquired FIRST",
              order[:1] == ["A"], "order was %s" % order)
        # Mutual exclusion is the property that must never regress, and it is
        # separate from fairness: two winners at once would be catastrophic and
        # must not be reported as an ordering pass.
        if len(fair) == 2:
            gap = abs(fair[1]["at"] - fair[0]["at"])
            check("the two acquisitions did not overlap (held 1.5s each)",
                  gap >= 1.4, "gap was %.2fs -- BOTH RAN AT ONCE" % gap)

        print("\nnegative control: the OLD unfair algorithm")
        print("    (if this cannot lose, the scenario is not testing anything)")
        unfair_wins_b = 0
        rounds = 3
        for i in range(rounds):
            r = run_scenario("race%d" % i, tmp)
            o = [x["label"] for x in r if x["ok"]]
            print("    round %d order: %s" % (i + 1, o or "NOBODY"))
            if o[:1] == ["B"]:
                unfair_wins_b += 1
        check("the old algorithm CAN let the later arrival win "
              "(%d/%d rounds)" % (unfair_wins_b, rounds),
              unfair_wins_b > 0,
              "B never won in %d rounds -- this control proves nothing, and "
              "the fair-mode pass above is therefore not evidence. The old "
              "code raced on a 2s sleep; if the scenario cannot produce an "
              "inversion, lengthen the gap between A and B." % rounds)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print("\n%s -- %d failure(s)"
          % ("FAIL" if FAILURES else "PASS", len(FAILURES)))
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
