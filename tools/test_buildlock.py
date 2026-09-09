#!/usr/bin/env python3
r"""test_buildlock.py -- the build lock is FIFO and answerable, and the tests
can fail.

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

## The second thing being checked: --status --json and --wait-free

An agent's wait loop matched the substring `"build lock is FREE"` against the
human output. That string has never been printed by this file, so the loop
could not fire, and "not free yet" and "I am asking the wrong question" look
identical from the outside.

The tests for the machine-readable answers therefore never assert a single
state in isolation -- a status tool that hardcoded `free` would pass that. They
run the SAME command against three constructed worlds (nobody holding, a LIVE
process holding, a DEAD pid's lock file left behind) and require three
different `state` values AND three different exit codes. And `--wait-free` is
tested both ways round: it must return 0 when the holder dies, and it must
still be blocking (exit 1, after the full timeout) when the holder does not.
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
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import buildlock
import stage as stagemod  # noqa: E402

FAILURES = []
TIMINGS = []

# ---------------------------------------------------------------------------
# THE SANDBOX GUARD.
#
# MEASURED 2026-09-02: this suite ran for over two minutes while a REAL
# `buildlock.py build host` held `.aowl-build.lock` in this very checkout, and
# it was not obvious whether the suite was blocked on that lock or merely slow.
# It must not be possible to wonder. A unit suite has no business touching the
# live lock, the live nimcache or the live `aowl`, so every path into
# buildlock -- in-process and through the CLI -- is funnelled past this guard,
# and main() additionally asserts the real lock file was neither created nor
# modified by the run. The guard has its own positive control (guard/fires),
# because a guard that cannot fire is exactly the defect it is guarding
# against.
# ---------------------------------------------------------------------------

REAL_LOCK = buildlock.lock_path(REPO)


def _inside_repo(path):
    a = os.path.normcase(os.path.abspath(path))
    b = os.path.normcase(os.path.abspath(REPO))
    return a == b or a.startswith(b + os.sep)


class SandboxViolation(AssertionError):
    pass


def guard_repo(repo):
    """Refuse any repo whose lock file would land in the real checkout."""
    lp = _real_lock_path(repo)
    if _inside_repo(lp):
        raise SandboxViolation(
            "a test aimed buildlock at the REAL checkout: --repo %r resolves "
            "its lock to %s, which is inside %s. Point it at a temp dir."
            % (repo, lp, REPO))
    return repo


_real_lock_path = buildlock.lock_path


def _guarded_lock_path(repo):
    lp = _real_lock_path(repo)
    if _inside_repo(lp):
        raise SandboxViolation(
            "buildlock.lock_path(%r) -> %s is inside the real checkout"
            % (repo, lp))
    return lp


buildlock.lock_path = _guarded_lock_path


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


GATED_CHILD = r'''
import json, os, sys, time
sys.path.insert(0, r"%(here)s")
import buildlock
path, out, label, mode, gate = sys.argv[1:6]
# Already imported, already warm: from here the only thing between us and the
# O_EXCL create is the queue check. That is the point -- an arrival timed by
# process startup would be measuring python, not the lock.
while not os.path.exists(gate):
    time.sleep(0.002)
if mode == "fair":
    ok = buildlock.acquire(path, label, 60, 7200, False)
else:
    ok = buildlock.race_acquire(path, label, 60, 7200, False)
rec = {"label": label, "ok": bool(ok), "at": time.time(), "pid": os.getpid()}
with open(out, "a", encoding="utf-8") as f:
    f.write(json.dumps(rec) + "\n")
if ok:
    time.sleep(1.5)
    buildlock.release(path)
'''


def run_release_window(mode, tmp, tag):
    """THE sharp case: A is queued and asleep; B arrives in the millisecond
    the holder releases.

    `run_scenario` above has B arrive ~1s BEFORE the release, so B is already
    parked in the queue-check loop when the lock frees and never even attempts
    a create. That scenario cannot catch a FIFO break that lives in the gap
    between "the lock became free" and "the earliest waiter noticed". This one
    aims straight at that gap: B's interpreter is already warm and parked on a
    gate file, and the gate is touched immediately after the lock is removed,
    while A is mid-`time.sleep(1.0)`.

    Fair mode must still hand it to A. The unfair control must be ABLE to hand
    it to B -- if it never does, this scenario is not reaching the race and the
    fair-mode result is not evidence (CLAUDE.md 9b).
    """
    repo = os.path.join(tmp, tag)
    os.makedirs(repo, exist_ok=True)
    path = buildlock.lock_path(repo)
    out = os.path.join(repo, "order.jsonl")
    gate = os.path.join(repo, "GO")
    holder = plant_holder(path)
    child = os.path.join(repo, "child.py")
    with open(child, "w", encoding="utf-8") as f:
        f.write(CHILD % {"here": HERE})
    gchild = os.path.join(repo, "gchild.py")
    with open(gchild, "w", encoding="utf-8") as f:
        f.write(GATED_CHILD % {"here": HERE})

    a = subprocess.Popen([sys.executable, child, path, out, "A", mode],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    b = subprocess.Popen([sys.executable, gchild, path, out, "B", mode, gate],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    # A must be an ESTABLISHED waiter before the release, or there is nothing
    # to be unfair to. In fair mode that is observable: its ticket is on disk.
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
    time.sleep(2.0)

    holder.kill()
    holder.wait()
    try:
        os.unlink(path)
    except OSError:
        pass
    with open(gate, "w") as f:      # B "arrives" now, microseconds later
        f.write("go")

    for p in (a, b):
        p.wait(timeout=90)

    rows = []
    if os.path.exists(out):
        with open(out, encoding="utf-8") as f:
            for line in f:
                if line.strip():
                    rows.append(json.loads(line))
    rows.sort(key=lambda r: r["at"])
    return rows


BL = os.path.join(HERE, "buildlock.py")


def cli(repo, *args):
    """Run the real CLI the way an agent would. Returns (rc, stdout)."""
    r = subprocess.run([sys.executable, BL, "--repo", guard_repo(repo)] + list(args),
                       capture_output=True, text=True, timeout=180)
    return r.returncode, r.stdout


def plant_stale(path):
    """A lock file whose holder is GONE -- a crashed build, not a running one.

    The pid must be a real, now-exited Windows pid for `pid_alive`'s tasklist
    probe to answer honestly (see plant_holder). A made-up number like 999999
    would also read as dead, but for the wrong reason.
    """
    p = subprocess.Popen([sys.executable, "-c", "pass"])
    p.wait()
    with open(path, "w", encoding="utf-8") as f:
        json.dump({"pid": p.pid, "cmd": "crashed build",
                   "started": time.time() - 30,
                   "started_h": time.strftime("%Y-%m-%d %H:%M:%S")}, f)
    return p.pid


def test_status(tmp):
    """One command, three constructed worlds, three distinguishable answers."""
    print("\n--status --json: free / held / stale")
    worlds = {}
    procs = []

    free_repo = os.path.join(tmp, "st-free")
    os.makedirs(free_repo, exist_ok=True)
    worlds["free"] = cli(free_repo, "--status", "--json")
    free_human = cli(free_repo, "--status")

    held_repo = os.path.join(tmp, "st-held")
    os.makedirs(held_repo, exist_ok=True)
    holder = plant_holder(buildlock.lock_path(held_repo))
    procs.append(holder)
    worlds["held"] = cli(held_repo, "--status", "--json")
    held_human = cli(held_repo, "--status")

    stale_repo = os.path.join(tmp, "st-stale")
    os.makedirs(stale_repo, exist_ok=True)
    dead_pid = plant_stale(buildlock.lock_path(stale_repo))
    worlds["stale"] = cli(stale_repo, "--status", "--json")

    for p in procs:
        p.kill()
        p.wait()

    docs = {}
    for name, (rc, out) in worlds.items():
        try:
            docs[name] = json.loads(out)
        except Exception as ex:
            check("%s world: --json printed ONE parseable json object" % name,
                  False, "%s -- got %r" % (ex, out[:200]))
            docs[name] = {}
        else:
            check("%s world: --json printed ONE parseable json object" % name,
                  True)

    states = [docs.get(n, {}).get("state") for n in ("free", "held", "stale")]
    codes = [worlds[n][0] for n in ("free", "held", "stale")]
    print("    states %s   exit codes %s" % (states, codes))

    # THE control: a status tool that always said the same thing would satisfy
    # any single-world assertion. Three worlds must give three answers.
    check("the three worlds produce three DIFFERENT states",
          len(set(states)) == 3 and None not in states, str(states))
    check("the three worlds produce three DIFFERENT exit codes",
          len(set(codes)) == 3, str(codes))
    check("state names are free/held/stale in that order",
          states == ["free", "held", "stale"], str(states))
    check("exit codes are 0 free / 1 held / 2 stale",
          codes == [0, 1, 2], str(codes))

    check("held: pid is the LIVE holder's and running is true",
          docs.get("held", {}).get("pid") == holder.pid
          and docs["held"].get("running") is True,
          "%r vs planted pid %d" % (docs.get("held"), holder.pid))
    check("held: target is the string the holder recorded",
          docs.get("held", {}).get("target") == "planted holder",
          repr(docs.get("held", {}).get("target")))
    check("stale: pid is the DEAD holder's and running is false",
          docs.get("stale", {}).get("pid") == dead_pid
          and docs["stale"].get("running") is False,
          "%r vs dead pid %d" % (docs.get("stale"), dead_pid))
    check("every world reports a queue list",
          all(isinstance(docs.get(n, {}).get("queue"), list) for n in worlds),
          str({n: docs.get(n, {}).get("queue") for n in worlds}))

    # The human text is a separate contract and must not have drifted.
    check("human --status still prints 'build lock FREE ('",
          free_human[1].startswith("build lock FREE ("),
          repr(free_human[1][:80]))
    check("human --status still prints 'build lock HELD by pid'",
          held_human[1].startswith("build lock HELD by pid"),
          repr(held_human[1][:80]))
    # The exact string the broken wait loop matched. It is not printed, was
    # never printed, and must not be added to paper over that bug -- the fix
    # is --json, not English that happens to match one agent's guess.
    check("the substring an agent wrongly matched is still absent",
          "build lock is FREE" not in free_human[1], repr(free_human[1][:80]))


def plant_ticket(qdir, arrival_ns, cmd):
    """A LIVE waiter's queue ticket. Returns (proc, path)."""
    os.makedirs(qdir, exist_ok=True)
    p = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
    path = os.path.join(qdir, buildlock._ticket_name(arrival_ns, p.pid))
    with open(path, "w", encoding="utf-8") as f:
        json.dump({"pid": p.pid, "cmd": cmd, "arrival": arrival_ns,
                   "arrival_h": time.strftime(
                       "%Y-%m-%d %H:%M:%S",
                       time.localtime(arrival_ns / 1e9))}, f)
    return p, path


def plant_holder_arrived(path, arrival_ns, acquired_at):
    """A holder whose QUEUE ARRIVAL is recorded, i.e. a post-fix lock file."""
    p = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
    with open(path, "w", encoding="utf-8") as f:
        json.dump({"pid": p.pid, "cmd": "build host", "started": acquired_at,
                   "started_h": time.strftime("%Y-%m-%d %H:%M:%S",
                                              time.localtime(acquired_at)),
                   "arrival": arrival_ns,
                   "arrival_h": time.strftime("%Y-%m-%d %H:%M:%S",
                                              time.localtime(arrival_ns / 1e9))},
                  f)
    return p


def test_fifo_reporting(tmp):
    """The thing that was actually wrong on 2026-09-02 at 01:35.

    `--status` printed a holder 'since 01:22:41' above a waiter 'since
    01:19:27' and it read as a queue-jump. It was not one: the holder's
    timestamp was when it ACQUIRED and the waiter's was when it ARRIVED -- two
    different clocks in adjacent columns with no label. The ordering tests
    could not reproduce a fairness bug because there was none to reproduce.

    So the property under test is that the tool can now tell those two worlds
    apart. THREE worlds, three verdicts, and the `unknown` one matters most:
    a lock file with no arrival recorded must NOT be reported as `ok`, or the
    verdict is a check that cannot fail.
    """
    print("\nFIFO reporting: ok / INVERTED / unknown")
    procs = []
    now = time.time()

    # World 1 -- the real 01:35 shape. Holder queued at T-16m, won at T-12m;
    # a waiter arrived at T-15m and is still waiting. FAIR, and must say so.
    r1 = os.path.join(tmp, "fifo-ok")
    os.makedirs(r1, exist_ok=True)
    lp1 = buildlock.lock_path(r1)
    procs.append(plant_holder_arrived(lp1, int((now - 960) * 1e9), now - 720))
    w1, _ = plant_ticket(buildlock.queue_dir(lp1), int((now - 900) * 1e9),
                         "build host")
    procs.append(w1)
    rc1, out1 = cli(r1, "--status", "--json")
    _rc, human1 = cli(r1, "--status")

    # World 2 -- a GENUINE inversion: the holder queued AFTER the waiter.
    r2 = os.path.join(tmp, "fifo-bad")
    os.makedirs(r2, exist_ok=True)
    lp2 = buildlock.lock_path(r2)
    procs.append(plant_holder_arrived(lp2, int((now - 600) * 1e9), now - 300))
    w2, _ = plant_ticket(buildlock.queue_dir(lp2), int((now - 900) * 1e9),
                         "build host")
    procs.append(w2)
    _rc, out2 = cli(r2, "--status", "--json")
    _rc, human2 = cli(r2, "--status")

    # World 3 -- a lock file written before `arrival` existed, or via --steal.
    r3 = os.path.join(tmp, "fifo-unknown")
    os.makedirs(r3, exist_ok=True)
    lp3 = buildlock.lock_path(r3)
    procs.append(plant_holder(lp3))          # legacy record: no arrival field
    w3, _ = plant_ticket(buildlock.queue_dir(lp3), int((now - 900) * 1e9),
                         "build host")
    procs.append(w3)
    _rc, out3 = cli(r3, "--status", "--json")
    _rc, human3 = cli(r3, "--status")

    for p in procs:
        p.kill()
        p.wait()

    verdicts = []
    for out in (out1, out2, out3):
        try:
            verdicts.append(json.loads(out).get("fifo"))
        except Exception:
            verdicts.append("<unparseable>")
    print("    fifo verdicts %s" % verdicts)
    check("three worlds give three DIFFERENT fifo verdicts",
          len(set(verdicts)) == 3, str(verdicts))
    check("fair handoff (acquired later, queued earlier) reads ok",
          verdicts[0] == "ok", str(verdicts))
    check("a real inversion reads INVERTED",
          verdicts[1] == "INVERTED", str(verdicts))
    check("a lock with no arrival recorded reads unknown, NOT ok",
          verdicts[2] == "unknown", str(verdicts))

    check("the fair world's text names the holder's QUEUE time too",
          "it joined the queue at" in human1, repr(human1))
    check("the fair world's text does NOT cry inversion",
          "FIFO INVERTED" not in human1, repr(human1))
    check("the inverted world's text says FIFO INVERTED",
          "FIFO INVERTED" in human2, repr(human2))
    check("the unknown world says it CANNOT be compared, not that it is fine",
          "CANNOT be compared" in human3 and "FIFO INVERTED" not in human3,
          repr(human3))
    check("queue lines label their timestamps as arrivals",
          "(arrived)" in human1, repr(human1))
    check("the held exit code is still 1 with a queue present",
          rc1 == 1, "rc=%d" % rc1)


def test_wait_free(tmp):
    """--wait-free must return when the lock frees AND block when it does not.

    Only one of those halves is the feature; both together are the test. A
    `--wait-free` that returned 0 immediately would pass the first check on its
    own, which is why the negative control below requires a TIMEOUT with a real
    elapsed time under a holder that never lets go.
    """
    print("\n--wait-free: returns when free, blocks when not")

    idle = os.path.join(tmp, "wf-idle")
    os.makedirs(idle, exist_ok=True)
    t0 = time.time()
    rc, out = cli(idle, "--wait-free", "30", "--json")
    quick = time.time() - t0
    check("no lock at all: exits 0 promptly (%.1fs)" % quick,
          rc == 0 and quick < 5.0, "rc=%d out=%r" % (rc, out[:120]))
    try:
        check("no lock at all: --json says state=free",
              json.loads(out).get("state") == "free", repr(out[:120]))
    except Exception as ex:
        check("no lock at all: --json says state=free", False, str(ex))

    released = os.path.join(tmp, "wf-released")
    os.makedirs(released, exist_ok=True)
    lp = buildlock.lock_path(released)
    holder = plant_holder(lp)
    t0 = time.time()
    proc = subprocess.Popen(
        [sys.executable, BL, "--repo", guard_repo(released), "--wait-free", "60", "--json"],
        stdout=subprocess.PIPE, text=True)
    time.sleep(3.0)
    still_running = proc.poll() is None
    holder.kill()
    holder.wait()
    try:
        os.unlink(lp)
    except OSError:
        pass
    out, _ = proc.communicate(timeout=60)
    waited = time.time() - t0
    check("held then released: it was STILL BLOCKED 3s in",
          still_running, "it returned before the holder was killed")
    check("held then released: exits 0 after the release (%.1fs)" % waited,
          proc.returncode == 0, "rc=%s out=%r" % (proc.returncode, out[:120]))
    # --json means stdout is a data channel: a progress line in front of the
    # object makes it unparseable, which is the very bug this feature replaces.
    check("held then released: --json printed ONE line, no progress prose",
          len([x for x in out.splitlines() if x.strip()]) == 1, repr(out[:200]))
    try:
        check("held then released: --json says state=free",
              json.loads(out).get("state") == "free", repr(out[:160]))
    except Exception as ex:
        check("held then released: --json says state=free", False, str(ex))

    # NEGATIVE CONTROL: the holder never goes away.
    stuck = os.path.join(tmp, "wf-stuck")
    os.makedirs(stuck, exist_ok=True)
    holder2 = plant_holder(buildlock.lock_path(stuck))
    t0 = time.time()
    rc, out = cli(stuck, "--wait-free", "4", "--json")
    waited = time.time() - t0
    holder2.kill()
    holder2.wait()
    check("holder never releases: exits 1 (timeout), not 0",
          rc == 1, "rc=%d -- it claimed the lock was free while a live "
                   "process held it" % rc)
    check("holder never releases: it actually waited the 4s (%.1fs)" % waited,
          waited >= 3.5, "returned after %.1fs -- it is not blocking" % waited)
    try:
        d = json.loads(out)
        check("timeout --json says state=timeout and names the holder",
              d.get("state") == "timeout"
              and d.get("status", {}).get("pid") == holder2.pid, repr(out[:160]))
    except Exception as ex:
        check("timeout --json says state=timeout and names the holder",
              False, str(ex))

    # And --wait-free must never be mistaken for "wait, then build".
    rc, out = cli(idle, "--wait-free", "5", "build", "host")
    check("--wait-free with a build command REFUSES rather than building",
          rc == 2 and "runs NOTHING" in out, "rc=%d out=%r" % (rc, out[:160]))


def test_status_streams(tmp):
    """`--status` writes its report to STDOUT, in every state, and writes
    NOTHING to stderr -- while still exiting 0 free / 1 held / 2 stale.

    Reported 2026-09-02 as "--status prints to stderr and exits 1, so a poller
    reading stdout sees nothing and concludes the lock is FREE". MEASURED here
    against this code: the report is on stdout and stderr is empty in all
    three states. The exit code is the only non-zero thing, and a caller that
    treats non-zero as "no output" -- subprocess check=True, a harness that
    renders a failed command as an error with the body folded away -- will
    still see nothing while the lock is very much held.

    So this test is not a fix; it is the pin. If anyone ever "helpfully" moves
    the held report to stderr because it looks like an error, or drops the
    exit codes to make pollers simpler, one of these fails and says which.
    """
    print("\n--status: which stream, and which exit code")

    def streams(repo, *args):
        r = subprocess.run([sys.executable, BL, "--repo", guard_repo(repo)] + list(args),
                           capture_output=True, text=True, timeout=60)
        return r.returncode, r.stdout, r.stderr

    procs = []
    free_repo = os.path.join(tmp, "str-free")
    os.makedirs(free_repo, exist_ok=True)
    held_repo = os.path.join(tmp, "str-held")
    os.makedirs(held_repo, exist_ok=True)
    procs.append(plant_holder(buildlock.lock_path(held_repo)))
    stale_repo = os.path.join(tmp, "str-stale")
    os.makedirs(stale_repo, exist_ok=True)
    plant_stale(buildlock.lock_path(stale_repo))

    try:
        cases = [("free", free_repo, 0, "FREE"),
                 ("held", held_repo, 1, "HELD"),
                 ("stale", stale_repo, 2, "NOT RUNNING")]
        for state, repo, want_rc, want_text in cases:
            rc, out, errout = streams(repo, "--status")
            check("--status (%s): the report is on STDOUT" % state,
                  want_text in out,
                  "stdout=%r stderr=%r" % (out[:160], errout[:160]))
            check("--status (%s): stderr is empty" % state,
                  errout == "", "stderr=%r" % errout[:200])
            check("--status (%s): exit %d as documented" % (state, want_rc),
                  rc == want_rc, "rc=%d" % rc)

            rc, out, errout = streams(repo, "--status", "--json")
            parsed = None
            try:
                parsed = json.loads(out)
            except ValueError:
                pass
            check("--status --json (%s): ONE parseable object on stdout"
                  % state, parsed is not None and parsed.get("state") == state,
                  "stdout=%r" % out[:200])
            check("--status --json (%s): stderr is empty" % state,
                  errout == "", "stderr=%r" % errout[:200])
            check("--status --json (%s): same exit code as the prose form"
                  % state, rc == want_rc, "rc=%d" % rc)
    finally:
        for p in procs:
            p.kill()


def make_fake_driver(repo, sleep_s=4.0):
    """A repo whose `installer/build/aowl.exe` is a python interpreter, and a
    script named `build` beside it that records how it was called.

    The point is to test the REAL CLI path -- argparse REMAINDER -> the lock
    record's `cmd` -> the child's argv -- rather than to call `acquire()` by
    hand, because the bug this guards against lives in that plumbing: a target
    of more than one word (`build mod maps`) must reach `aowl` verbatim AND
    must appear whole in `--status`. A test that constructed the command
    itself could not fail that way.

    A copied python.exe was measured to run from an arbitrary directory on
    this machine; if that ever stops being true this returns None and the
    caller reports INCONCLUSIVE rather than a pass.
    """
    bin_dir = os.path.join(repo, "installer", "build")
    os.makedirs(bin_dir, exist_ok=True)
    exe = os.path.join(bin_dir, "aowl.exe")
    shutil.copy(sys.executable, exe)
    out = os.path.join(repo, "called.json")
    script = os.path.join(repo, "build")
    with open(script, "w", encoding="utf-8", newline="\n") as f:
        f.write("import json, os, sys, time\n"
                "json.dump({'argv': sys.argv,\n"
                "           'lock': os.environ.get('AOWL_BUILDLOCK'),\n"
                "           'cwd': os.getcwd()},\n"
                "          open(%r, 'w'))\n"
                "time.sleep(%r)\n"
                "sys.exit(7)\n" % (out, sleep_s))
    probe = subprocess.run([exe, "-c", "print('ok')"],
                           capture_output=True, text=True)
    if probe.returncode != 0 or "ok" not in probe.stdout:
        return None
    return out


def test_forwarding(tmp):
    """`build mod maps` reaches aowl verbatim and shows up whole in --status.

    MEASURED 2026-09-02: there was no serialised way to rebuild ONE mod, so
    agents either built all 22 (~10 min for a one-mod change) or ran
    modbuild/nimony by hand -- the unserialised path that corrupted this
    checkout's nimcache twice. `aowl build mod NAME` is the fix, and this is
    the check that the lock carries it: a multi-word target must not be
    truncated to `build`, and `--status` must name the whole thing, because
    `--status` is how a waiting agent decides what is happening.
    """
    print("\nforwarding: `build mod maps` through the lock")
    repo = os.path.join(tmp, "fwd")
    os.makedirs(repo, exist_ok=True)
    out = make_fake_driver(repo)
    if out is None:
        check("INCONCLUSIVE: no runnable stand-in driver, nothing was tested",
              False, "the copied python.exe would not start")
        return

    proc = subprocess.Popen(
        [sys.executable, BL, "--repo", guard_repo(repo), "build", "mod", "maps"],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    held = None
    deadline = time.time() + 30
    while time.time() < deadline:
        rc, sout = cli(repo, "--status", "--json")
        try:
            st = json.loads(sout)
        except ValueError:
            st = {}
        if st.get("state") == "held":
            held = st
            break
        if proc.poll() is not None:
            break
        time.sleep(0.2)

    stdout = proc.communicate(timeout=60)[0]

    check("--status showed the lock HELD while `build mod maps` ran",
          held is not None,
          "never observed held; child said %r" % (stdout or "")[:200])
    if held is not None:
        check("--status names the WHOLE target, not just `build`",
              held.get("target") == "build mod maps",
              "target was %r" % held.get("target"))

    called = {}
    if os.path.exists(out):
        with open(out, encoding="utf-8") as f:
            called = json.load(f)
    check("aowl was called with `build mod maps` verbatim",
          called.get("argv", [])[:3] == ["build", "mod", "maps"],
          "argv was %r" % called.get("argv"))
    check("the child ran with AOWL_BUILDLOCK set (the proof-of-lock aowl "
          "refuses to build without)",
          str(called.get("lock") or "").isdigit(),
          "AOWL_BUILDLOCK was %r" % called.get("lock"))
    check("the child's exit code is passed back through the lock",
          proc.returncode == 7, "rc=%d" % proc.returncode)
    check("the lock is FREE again afterwards",
          cli(repo, "--status", "--json")[0] == 0,
          "status after the run was %r" % cli(repo, "--status")[1][:160])

    # `build test mapsdiag` is the other new multi-word target; same plumbing,
    # and cheap to assert, so a future change that special-cases `mod` cannot
    # pass this file.
    repo2 = os.path.join(tmp, "fwd2")
    os.makedirs(repo2, exist_ok=True)
    out2 = make_fake_driver(repo2, sleep_s=0.1)
    if out2 is not None:
        subprocess.run([sys.executable, BL, "--repo", guard_repo(repo2),
                        "build", "test", "mapsdiag"],
                       capture_output=True, text=True, timeout=60)
        called2 = {}
        if os.path.exists(out2):
            with open(out2, encoding="utf-8") as f:
                called2 = json.load(f)
        check("`build test mapsdiag` forwards verbatim too",
              called2.get("argv", [])[:3] == ["build", "test", "mapsdiag"],
              "argv was %r" % called2.get("argv"))


def make_git_repo(tmp, name):
    """A throwaway git repo with one committed file under host/.

    Returns the path, or None if git would not cooperate -- in which case the
    caller reports INCONCLUSIVE. `core.hooksPath` is pointed at a directory
    that does not exist so this never runs the real checkout's pre-commit
    guard, and identity is set locally so it never depends on global config.
    """
    repo = os.path.join(tmp, name)
    # host/Aowlspt.Host.Il2Cpp/ must be a TRACKED directory, or `git status`
    # (which is run with the default -unormal) would collapse the new file
    # into a single untracked-DIRECTORY entry and the test would be asserting
    # against a shape the real checkout never has.
    sub = os.path.join(repo, "host", "Aowlspt.Host.Il2Cpp")
    os.makedirs(sub, exist_ok=True)
    for p in (os.path.join(repo, "host", "pre.nim"),
              os.path.join(sub, "modsindex.nim")):
        with open(p, "w", encoding="utf-8", newline="\n") as f:
            f.write("# committed content\n")

    def g(*args):
        return subprocess.run(["git"] + list(args), cwd=repo,
                              capture_output=True, text=True, timeout=60)
    if g("init", "-q").returncode != 0:
        return None
    g("config", "core.hooksPath", os.path.join(repo, "no-such-hooks"))
    g("config", "user.email", "t@example.invalid")
    g("config", "user.name", "buildlock test")
    g("config", "commit.gpgsign", "false")
    g("add", "-A")
    if g("commit", "-q", "-m", "base").returncode != 0:
        return None
    if not g("rev-parse", "HEAD").stdout.strip():
        return None
    return repo


def make_effect_driver(repo, creates=None, rc=0, sleep_s=0.6):
    """A stand-in `aowl` that optionally CREATES a file mid-build and exits
    with a chosen code -- i.e. it reproduces the measured incident (an
    untracked source file appearing in the checkout while somebody else's
    build is running) without building anything.

    Returns the path it will create, or None if the copied interpreter will
    not run (INCONCLUSIVE, not a pass).
    """
    bin_dir = os.path.join(repo, "installer", "build")
    os.makedirs(bin_dir, exist_ok=True)
    exe = os.path.join(bin_dir, "aowl.exe")
    shutil.copy(sys.executable, exe)
    target = os.path.join(repo, creates) if creates else None
    script = os.path.join(repo, "build")
    with open(script, "w", encoding="utf-8", newline="\n") as f:
        f.write("import os, sys, time\n"
                "time.sleep(%r)\n"
                "t = %r\n"
                "if t:\n"
                "    os.makedirs(os.path.dirname(t), exist_ok=True)\n"
                "    open(t, 'w').write('# written mid-build\\n')\n"
                "time.sleep(%r)\n"
                "sys.exit(%d)\n" % (sleep_s / 2.0, target, sleep_s / 2.0, rc))
    probe = subprocess.run([exe, "-c", "print('ok')"],
                           capture_output=True, text=True)
    if probe.returncode != 0 or "ok" not in probe.stdout:
        return None
    return target


def run_build(repo):
    r = subprocess.run([sys.executable, BL, "--repo", guard_repo(repo), "build", "host"],
                       capture_output=True, text=True, timeout=180)
    return r.returncode, r.stdout


FOOTER = ("a failure in a file you did not edit is likely another agent's "
          "half-written change; re-run after the queue drains")
HEADER = "CONCURRENT EDITS DURING THIS BUILD:"


def test_concurrent_edits(tmp):
    """The measured incident, reproduced: a file appears mid-build.

    MEASURED 2026-09-01: `buildlock build host` failed on
    `modsindex.nim(399): undeclared identifier: 'ntKeyCodeName'` in a file the
    builder had never touched, because another agent had just created
    host/Aowlspt.Host.Il2Cpp/keycodes.nim in the shared checkout. The failure
    read as the builder's own bug.

    The pass condition is NOT 'the block was printed' on its own -- a block
    printed unconditionally would satisfy that. The SUCCESS run below is the
    control: identical scenario, identical mid-build file creation, exit 0, and
    the block must be entirely absent. If the file did not actually get
    created, both halves are vacuous, so that is asserted first.
    """
    print("\nconcurrent-edit reporting: a file appears mid-build")
    new_rel = "host/Aowlspt.Host.Il2Cpp/keycodes.nim"

    repo = make_git_repo(tmp, "ce-fail")
    if repo is None:
        check("INCONCLUSIVE: could not create a git repo, nothing was tested",
              False, "git init/commit failed")
        return
    created = make_effect_driver(repo, creates=new_rel, rc=3)
    if created is None:
        check("INCONCLUSIVE: no runnable stand-in driver, nothing was tested",
              False, "the copied python.exe would not start")
        return
    # A file dirty BEFORE the build starts, to exercise the second section.
    with open(os.path.join(repo, "host", "pre.nim"), "a",
              encoding="utf-8", newline="\n") as f:
        f.write("# edited before the lock was taken\n")

    rc, out = run_build(repo)
    check("the mid-build file was really created (else both halves are "
          "vacuous)", os.path.exists(created), created)
    check("the failing build's exit code still comes back", rc == 3,
          "rc=%d" % rc)
    check("a FAILED build prints the CONCURRENT EDITS block", HEADER in out,
          "stdout tail: %r" % out[-300:])
    check("the block NAMES the file that appeared mid-build",
          "keycodes.nim" in out, "stdout tail: %r" % out[-500:])
    check("the appearing file is reported as APPEARED, not as pre-existing",
          "APPEARED" in out and "keycodes.nim" in out.split("APPEARED", 1)[-1]
          .splitlines()[0], "stdout tail: %r" % out[-500:])
    check("the block reports the file dirty at ACQUIRE time too",
          "already modified" in out and "host/pre.nim" in out,
          "stdout tail: %r" % out[-600:])
    check("the block ends with the re-run line", FOOTER in out,
          "stdout tail: %r" % out[-300:])
    # The lock file and the queue directory change on every single acquire and
    # release. If they showed up here the block would be noise on every
    # failure, and a noisy block is an unread one.
    check("the lock's OWN files are not reported as concurrent edits",
          ".aowl-build" not in out, "stdout tail: %r" % out[-500:])

    print("\n  negative control: the SAME edit, but the build SUCCEEDS")
    repo2 = make_git_repo(tmp, "ce-ok")
    if repo2 is None:
        check("INCONCLUSIVE: could not create the control repo", False, "")
        return
    created2 = make_effect_driver(repo2, creates=new_rel, rc=0)
    if created2 is None:
        check("INCONCLUSIVE: no runnable stand-in driver for the control",
              False, "")
        return
    rc2, out2 = run_build(repo2)
    check("control: the mid-build file was really created here as well",
          os.path.exists(created2), created2)
    check("control: the build succeeded", rc2 == 0, "rc=%d" % rc2)
    check("a SUCCESSFUL build prints NO block, despite the same edit",
          HEADER not in out2 and FOOTER not in out2 and
          "keycodes.nim" not in out2,
          "stdout tail: %r" % out2[-400:])


def test_snapshot_unit(tmp):
    """The two answers that are hard to stage: HEAD moved, and 'I could not
    look'. Both are asserted directly on concurrent_edit_lines(), because a
    snapshot that failed MUST NOT read as 'nothing changed'."""
    print("\nsnapshot reporting: HEAD moved, and the NOT PERFORMED case")
    t0 = time.time()
    base = {"at": t0, "head": "a" * 40, "status": {}, "mtime": {},
            "error": None}
    moved = {"at": t0 + 5, "head": "b" * 40, "status": {}, "mtime": {},
             "error": None}
    lines = "\n".join(buildlock.concurrent_edit_lines(base, moved))
    check("a HEAD move during the build is reported", "HEAD MOVED" in lines,
          lines)

    broken = {"at": t0 + 5, "head": None, "status": {}, "mtime": {},
              "error": "git status --porcelain failed (not a git repository)"}
    lines = "\n".join(buildlock.concurrent_edit_lines(base, broken))
    check("a snapshot that failed says NOT PERFORMED, not 'no changes'",
          "NOT PERFORMED" in lines and "nothing changed" in lines, lines)

    quiet = "\n".join(buildlock.concurrent_edit_lines(base, dict(base, at=t0)))
    check("a genuinely quiet build says so explicitly rather than printing "
          "an empty block",
          "no working-tree change was observed" in quiet, quiet)

    # mtime-only change: same status code, rewritten file. This is the case a
    # naive `git status` diff misses entirely -- an agent rewriting a file that
    # was ALREADY modified changes nothing about the porcelain output.
    b = {"at": t0, "head": "a" * 40, "status": {"host/x.nim": " M"},
         "mtime": {"host/x.nim": t0 - 60}, "error": None}
    a2 = {"at": t0 + 5, "head": "a" * 40, "status": {"host/x.nim": " M"},
          "mtime": {"host/x.nim": t0 + 3}, "error": None}
    lines = "\n".join(buildlock.concurrent_edit_lines(b, a2))
    check("a file REWRITTEN mid-build (identical status code) is caught",
          "REWRITTEN" in lines and "host/x.nim" in lines, lines)


def test_snapshot_speed(tmp):
    """It runs on every build, so it has to be cheap.

    Measured on a THROWAWAY git repo, not the live checkout. It used to run
    `git status` in the real tree, which (a) is contended precisely when a
    build is running -- the case this suite must survive -- and (b) made the
    <1s assertion flaky for reasons that have nothing to do with the code.
    The real checkout is still measured, but only as INFORMATION and only when
    nobody is building; an unmeasured cost is printed as NOT MEASURED, never
    as a pass.
    """
    print("\nsnapshot cost")
    repo = make_git_repo(tmp, "snap-speed")
    if repo is None:
        check("INCONCLUSIVE: git would not make a throwaway repo, so snapshot "
              "cost was NOT MEASURED", False)
        return
    t = time.time()
    snap = buildlock.tree_snapshot(repo)
    dt = time.time() - t
    print("    tree_snapshot(<temp repo>) took %.3fs, %d paths, error=%r"
          % (dt, len(snap["status"]), snap["error"]))
    check("the snapshot reads a repo without error",
          snap["error"] is None and snap["head"], repr(snap["error"]))
    check("the snapshot takes under 1s (%.3fs)" % dt, dt < 1.0,
          "%.3fs -- it runs twice per build" % dt)

    st = buildlock.status(REAL_LOCK, buildlock.DEFAULT_MAX_AGE)
    if st["state"] == "held":
        print("    real checkout: NOT MEASURED -- pid %s is building right "
              "now, so any number here would be a measure of the contention, "
              "not of the snapshot" % st["pid"])
        return
    t = time.time()
    rsnap = buildlock.tree_snapshot(REPO)
    print("    real checkout (information only, read-only): %.3fs, %d paths, "
          "error=%r" % (time.time() - t, len(rsnap["status"]), rsnap["error"]))


# ---------------------------------------------------------------------------
# Hang detection.
# ---------------------------------------------------------------------------

# The measured shape of the real incident: the parent (buildlock's own python,
# then aowl) sits in a blocking wait using no CPU whatsoever, and ALL the work
# -- or all the absence of it -- is in a grandchild. A test that planted a
# single process would pass without ever exercising proc_tree(), which is the
# part that can actually be wrong.
PARENT = ("import subprocess, sys, time\n"
          "subprocess.Popen([sys.executable, '-c'] + sys.argv[1:])\n"
          "time.sleep(300)\n")

CHILD_SLEEP = "import time\ntime.sleep(300)\n"
CHILD_BURN = ("import time\n"
              "t = time.time()\n"
              "while time.time() - t < 300:\n"
              "    pass\n")
CHILD_TOUCH = ("import os, sys, time\n"
               "f = sys.argv[1]\n"
               "for _ in range(3000):\n"
               "    open(f, 'a').close()\n"
               "    os.utime(f, None)\n"
               "    time.sleep(0.4)\n")


def make_hung_world(tmp, name, child_src, child_arg=None, nimcache=True,
                    holder_age=600.0):
    """A checkout-shaped directory with a lock held by a two-deep process tree.

    `holder_age` backdates the acquire time because a holder younger than
    --hung-after is deliberately not checked at all; without it the waiter
    tests would be measuring the age gate rather than the verdict.
    """
    repo = os.path.join(tmp, name)
    cache = os.path.join(repo, "host", "Aowlspt.Host.Il2Cpp", "nimcache")
    os.makedirs(cache, exist_ok=True)
    nif = os.path.join(cache, "aowlhost.final.build.nif")
    if nimcache:
        with open(nif, "w", encoding="utf-8", newline="\n") as f:
            f.write("# codegen output, the last thing the hung build wrote\n")
        old = time.time() - 600
        os.utime(nif, (old, old))
    else:
        # No nimcache at all: the progress signal does not exist here, and the
        # verdict must be `unknown` rather than `hung?`.
        shutil.rmtree(os.path.join(repo, "host"), ignore_errors=True)

    argv = [sys.executable, "-c", PARENT, child_src]
    if child_arg is not None:
        argv.append(child_arg)
    parent = subprocess.Popen(argv, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL)
    lp = buildlock.lock_path(repo)
    started = time.time() - holder_age
    with open(lp, "w", encoding="utf-8") as f:
        json.dump({"pid": parent.pid, "cmd": "build host", "started": started,
                   "started_h": time.strftime("%Y-%m-%d %H:%M:%S",
                                              time.localtime(started))}, f)
    return repo, parent, nif


def kill_world(parent):
    if os.name == "nt":
        subprocess.run(["taskkill", "/PID", str(parent.pid), "/T", "/F"],
                       capture_output=True, text=True)
    try:
        parent.kill()
    except Exception:
        pass
    try:
        parent.wait(timeout=20)
    except Exception:
        pass


def test_hung_verdicts(tmp):
    """FOUR worlds, one command, and the verdicts must differ.

    Every world has a live holder whose pid exists, so `pid_alive` -- the only
    liveness this file used to have -- answers "running" in all four. That is
    the point: the old check CANNOT tell them apart, so if the new one returns
    the same verdict everywhere it has added nothing and this test says so.

      sleeping  parent asleep, child asleep, nimcache untouched   -> hung?
      burning   child in a busy loop                              -> working
      writing   child asleep but rewriting a .nif every 0.4s      -> working
      bare      sleeping, but the checkout has no nimcache at all -> unknown

    The `writing` world is the one that keeps this from being a CPU meter: a
    linker or a slow single-threaded step can use almost no CPU and still be
    making progress, and killing it would be the confidently-wrong answer.
    """
    print("\nhang detection: sleeping / burning / writing / bare")
    worlds, procs = {}, []
    try:
        specs = [("sleeping", CHILD_SLEEP, None, True),
                 ("burning", CHILD_BURN, None, True),
                 ("writing", CHILD_TOUCH, "ARG", True),
                 ("bare", CHILD_SLEEP, None, False)]
        made = {}
        for name, src, arg, cache in specs:
            repo = os.path.join(tmp, "hung-" + name)
            os.makedirs(repo, exist_ok=True)
            nif = os.path.join(repo, "host", "Aowlspt.Host.Il2Cpp", "nimcache",
                               "aowlhost.final.build.nif")
            r, p, nif = make_hung_world(tmp, "hung-" + name, src,
                                        child_arg=(nif if arg else None),
                                        nimcache=cache)
            procs.append(p)
            made[name] = (r, p, nif)

        # Let the busy loop and the toucher get going before the first sample,
        # or the baseline would be taken before either had done anything.
        time.sleep(2.0)

        for name, (repo, p, nif) in made.items():
            t = time.time()
            rc, out = cli(repo, "--status", "--json", "--check-hung",
                          "--hung-window", "5")
            try:
                doc = json.loads(out)
            except ValueError:
                doc = {}
            worlds[name] = doc.get("hung") or {}
            print("    %-9s verdict=%-8s cpu_delta=%s  nimcache_age=%s "
                  "(%.0fs)"
                  % (name, worlds[name].get("verdict"),
                     ("%.2f" % worlds[name]["cpu_delta_s"])
                     if worlds[name].get("cpu_delta_s") is not None else "n/a",
                     ("%.0f" % worlds[name]["nimcache_newest_age_s"])
                     if worlds[name].get("nimcache_newest_age_s") is not None
                     else "n/a", time.time() - t))
            check("%s: --status still exits 1 (held) with a hang check"
                  % name, rc == 1, "rc=%d" % rc)
    finally:
        for p in procs:
            kill_world(p)

    v = {k: worlds.get(k, {}).get("verdict") for k in
         ("sleeping", "burning", "writing", "bare")}
    check("a tree doing NOTHING reads hung?", v["sleeping"] == "hung?", str(v))
    check("a tree burning CPU reads working", v["burning"] == "working",
          str(v))
    check("a tree with NO cpu but a live nimcache reads working (this is the "
          "check that keeps it from being a cpu meter)",
          v["writing"] == "working", str(v))
    check("no nimcache to look at reads unknown, NOT hung?",
          v["bare"] == "unknown", str(v))
    # THE control. pid_alive() says "running" in all four worlds; if the new
    # verdict also collapsed to one value it would have added nothing.
    check("the four worlds are not all the same verdict",
          len(set(v.values())) >= 3, str(v))

    ev = worlds.get("sleeping", {})
    check("the hung? evidence names the pids it sampled",
          len(ev.get("procs") or []) >= 2,
          "procs=%r" % (ev.get("procs"),))
    check("the hung? evidence carries a cpu delta under the floor",
          (ev.get("cpu_delta_s") is not None and ev["cpu_delta_s"] < 0.5),
          "cpu_delta_s=%r" % ev.get("cpu_delta_s"))
    check("the hung? evidence carries the newest nimcache age",
          (ev.get("nimcache_newest_age_s") or 0) > 100,
          "age=%r" % ev.get("nimcache_newest_age_s"))
    burn = worlds.get("burning", {})
    check("the working verdict measured REAL cpu (>= the 0.5s floor)",
          (burn.get("cpu_delta_s") or 0) >= 0.5,
          "cpu_delta_s=%r" % burn.get("cpu_delta_s"))


def test_hung_human_text(tmp):
    """The prose a person actually reads, and the silence that must not be
    mistaken for a clean bill of health."""
    print("\nhang detection: the human report")
    repo, parent, _nif = make_hung_world(tmp, "hung-text", CHILD_SLEEP)
    try:
        rc, out = cli(repo, "--status", "--check-hung", "--hung-window", "5")
        check("the human report says HUNG? for a stopped tree", "HUNG?" in out,
              repr(out[:400]))
        check("the human report prints per-pid cpu evidence",
              "cpu" in out and "delta" in out, repr(out[:400]))
        check("the human report names --break-hung as the (opt-in) way out",
              "--break-hung" in out, repr(out[:600]))
        check("the human report still exits 1 (held)", rc == 1, "rc=%d" % rc)

        # And with the check switched OFF, the absence must announce itself.
        rc2, out2 = cli(repo, "--status", "--no-hung-check")
        check("with no hang check, --status SAYS no check was performed "
              "rather than implying health",
              "no hang check was performed" in out2, repr(out2[:400]))
        check("with no hang check, --json reports hung=null (not checked)",
              json.loads(cli(repo, "--status", "--json",
                             "--no-hung-check")[1]).get("hung") is None,
              "hung was not null")
    finally:
        kill_world(parent)


def test_hung_across_calls(tmp):
    """The DEFAULT `--status` mode: sample across calls, never block.

    `--check-hung` blocks for a window and is what the other tests use because
    it is deterministic. But the mode an agent will actually hit is this one,
    and it has a failure this repo has seen before: a check that can never
    complete. If the baseline were rewritten on every call, two samples a
    window apart would never exist and the verdict would sit on 'need more
    time' for ever -- indistinguishable, from the outside, from a build that
    is fine.

    So the assertion is that the strike count CLIMBS across calls, and the
    control is the burning world, where the identical call sequence must leave
    it pinned at zero.
    """
    print("\nhang detection: sampling across --status calls (no blocking)")

    def poll(repo, window="4"):
        rc, out = cli(repo, "--status", "--json", "--hung-window", window,
                      "--hung-after", "0")
        try:
            return (json.loads(out).get("hung") or {})
        except ValueError:
            return {}

    repo, parent, _ = make_hung_world(tmp, "hung-calls", CHILD_SLEEP)
    burn_repo, burn_parent, _ = make_hung_world(tmp, "burn-calls", CHILD_BURN)
    try:
        time.sleep(1.5)
        first = poll(repo)
        check("call 1 ARMS the check and says so, rather than guessing",
              first["verdict"] == "unknown" and "two" in first["why"],
              str(first))
        check("call 1 did not take a strike from a single sample",
              first["consecutive"] == 0, str(first))
        check("the baseline state file was written beside the lock",
              os.path.exists(buildlock.hung_state_path(
                  buildlock.lock_path(repo))), repo)

        seen, burn_seen = [], []
        for _ in range(3):
            time.sleep(5.0)
            seen.append(poll(repo))
            burn_seen.append(poll(burn_repo))
        strikes = [s.get("consecutive") for s in seen]
        verdicts = [s.get("verdict") for s in seen]
        print("    stopped tree: verdicts %s  strikes %s" % (verdicts, strikes))
        print("    burning tree: verdicts %s  strikes %s"
              % ([s.get("verdict") for s in burn_seen],
                 [s.get("consecutive") for s in burn_seen]))
        check("calls after the first produce real verdicts, not 'need more "
              "time' for ever",
              all(v == "hung?" for v in verdicts), str(verdicts))
        check("consecutive hung windows CLIMB across calls (1,2,3)",
              strikes == [1, 2, 3], str(strikes))

        cached = poll(repo)
        check("an immediate re-poll REPLAYS rather than resampling, and says "
              "so instead of passing a stale number off as fresh",
              cached.get("cached") is True and "replayed" in cached["why"],
              str(cached))
        check("a replayed verdict does not inflate the strike count",
              cached.get("consecutive") == 3, str(cached))

        # THE control. Same calls, same cadence, a tree that is working. Its
        # FIRST poll is an arming call like everyone else's, so the property is
        # not "always working" -- it is "never hung?, and never a strike".
        bv = [s.get("verdict") for s in burn_seen]
        check("the burning tree never reads hung? and never takes a strike",
              all(s.get("consecutive") == 0 for s in burn_seen)
              and "hung?" not in bv and bv.count("working") >= 2, str(bv))
    finally:
        kill_world(parent)
        kill_world(burn_parent)


def test_wait_free_reports_hung(tmp):
    """`--wait-free` is the OTHER waiter, and it must not sit silent.

    It runs nothing and so kills nothing, but `--wait-free 1800` parked in
    front of a stopped holder is half an hour of silence that reads exactly
    like a slow build. It has to say what it can see, and it has to say that
    seeing is all it will do.
    """
    print("\n--wait-free: it reports a hung holder without touching it")
    repo, parent, _ = make_hung_world(tmp, "wf-hung", CHILD_SLEEP)
    try:
        r = subprocess.run([sys.executable, BL, "--repo", guard_repo(repo),
                            "--wait-free", "18", "--hung-window", "3",
                            "--hung-after", "0"],
                           capture_output=True, text=True, timeout=180)
        check("--wait-free names the hang instead of waiting in silence",
              "THE HOLDER MAY BE HUNG" in r.stdout, repr(r.stdout[-700:]))
        check("--wait-free says plainly that it kills nothing",
              "kills nothing" in r.stdout, repr(r.stdout[-700:]))
        check("--wait-free still times out (exit 1); a hung holder is not a "
              "free lock", r.returncode == 1,
              "rc=%d out=%r" % (r.returncode, r.stdout[-300:]))
        check("--wait-free left the holder alive", buildlock.pid_alive(parent.pid),
              "it killed a process while claiming to run nothing")
    finally:
        kill_world(parent)


def test_break_hung(tmp):
    """A waiter may kill a hung holder -- but ONLY with --break-hung.

    Both halves are the test. The default run is the control: same world, same
    stopped tree, same number of windows, and the holder must still be alive at
    the end with nothing built. If killing happened in both, the flag is
    decorative; if it happened in neither, the feature does not exist.
    """
    print("\n--break-hung: opt-in killing of a stopped holder")

    # -- control first: no flag, nothing may die -------------------------
    repo, parent, _ = make_hung_world(tmp, "brk-off", CHILD_SLEEP)
    if make_fake_driver(repo, sleep_s=0.2) is None:
        check("INCONCLUSIVE: no runnable stand-in driver, nothing was tested",
              False, "the copied python.exe would not start")
        kill_world(parent)
        return
    try:
        r = subprocess.run([sys.executable, BL, "--repo", guard_repo(repo),
                            # 14s, not 30: without --break-hung this waiter
                            # can only exit when the wait expires, so the
                            # extra 16s bought nothing. Two 3s windows still
                            # fit, which is what the strike assertions need.
                            "--wait", "14", "--hung-window", "3",
                            "--hung-strikes", "2", "--hung-after", "0",
                            "build", "host"],
                           capture_output=True, text=True, timeout=180)
        alive = buildlock.pid_alive(parent.pid)
        check("control: the waiter REFUSED rather than building (exit 4)",
              r.returncode == 4, "rc=%d out=%r" % (r.returncode, r.stdout[-400:]))
        check("control: it did notice the holder looked hung",
              "THE HOLDER MAY BE HUNG" in r.stdout, repr(r.stdout[-800:]))
        check("control: it said explicitly that NOTHING WAS KILLED",
              "NOTHING WAS KILLED" in r.stdout, repr(r.stdout[-800:]))
        # The threshold it PRINTS must be the threshold it ENFORCES. It was
        # not: the loop honoured --hung-strikes while the evidence block
        # stamped the module default, so a run with `--hung-strikes 2` said
        # "3 needed" and then acted on the second. A number that contradicts
        # the behaviour beside it is worse than no number.
        check("control: the printed strike threshold is the one in force (2)",
              "2 needed before" in r.stdout,
              "it printed a different threshold than --hung-strikes 2; %r"
              % r.stdout[-800:])
        check("control: the holder is STILL ALIVE without --break-hung",
              alive, "the holder was killed with no --break-hung flag")
        check("control: the fake driver never ran",
              not os.path.exists(os.path.join(repo, "called.json")),
              "a build ran while the lock was still held")
    finally:
        kill_world(parent)

    # -- and now with the flag -------------------------------------------
    repo2, parent2, _ = make_hung_world(tmp, "brk-on", CHILD_SLEEP)
    out2 = make_fake_driver(repo2, sleep_s=0.2)
    if out2 is None:
        check("INCONCLUSIVE: no stand-in driver for the --break-hung half",
              False, "")
        kill_world(parent2)
        return
    try:
        r = subprocess.run([sys.executable, BL, "--repo", guard_repo(repo2),
                            "--wait", "90", "--break-hung",
                            "--hung-window", "3", "--hung-strikes", "2",
                            "--hung-after", "0", "build", "host"],
                           capture_output=True, text=True, timeout=240)
        time.sleep(1.0)
        alive = buildlock.pid_alive(parent2.pid)
        check("--break-hung: the holder's tree was killed", not alive,
              "the holder pid %d survived; out=%r"
              % (parent2.pid, r.stdout[-600:]))
        check("--break-hung: it logged the kill",
              "KILLING the holder's process tree" in r.stdout,
              repr(r.stdout[-800:]))
        check("--break-hung: it logged WHICH pids it killed (the holder, and "
              "the child that was the actual problem)",
              str(parent2.pid) in r.stdout
              and r.stdout.count("      pid ") >= 2, repr(r.stdout[-900:]))
        check("--break-hung: the build then ran",
              os.path.exists(out2),
              "no build was started after taking the lock; out=%r"
              % r.stdout[-600:])
        check("--break-hung: the child's exit code came back (7)",
              r.returncode == 7, "rc=%d" % r.returncode)
        check("--break-hung: the lock is FREE afterwards",
              cli(repo2, "--status", "--json", "--no-hung-check")[0] == 0,
              cli(repo2, "--status", "--no-hung-check")[1][:200])
    finally:
        kill_world(parent2)


def test_hung_units(tmp):
    """The two halves that are hard to stage live: an unreadable process table
    and a truncated nimcache walk. Both must degrade to `unknown`, because
    `unknown` resets the strike count and `hung?` does not."""
    print("\nhang detection: the NOT PERFORMED paths")
    t0 = time.time()

    def sample(at, procs, newest, **nc):
        d = {"newest": newest, "path": "x.nif", "dirs": 1, "files": 3,
             "truncated": False, "error": None}
        d.update(nc)
        return {"at": at, "pid": 1, "procs": procs, "proc_error": None,
                "root_seen": True, "nimcache": d}

    idle = {"1": {"name": "python.exe", "cpu_s": 0.27},
            "2": {"name": "nimony.exe", "cpu_s": 0.27}}
    prev = sample(t0, idle, t0 - 600)
    cur = sample(t0 + 30, idle, t0 - 600)
    v = buildlock.hung_verdict(prev, cur, 20, 0.5)
    check("baseline: an idle tree over a full window is hung?",
          v["verdict"] == "hung?", str(v))

    busy = {"1": {"name": "python.exe", "cpu_s": 0.27},
            "2": {"name": "nimony.exe", "cpu_s": 9.5}}
    v = buildlock.hung_verdict(prev, sample(t0 + 30, busy, t0 - 600), 20, 0.5)
    check("cpu on ONE child of the tree is enough to read working",
          v["verdict"] == "working" and v["cpu_delta_s"] > 9, str(v))

    v = buildlock.hung_verdict(prev, sample(t0 + 30, idle, t0 + 10), 20, 0.5)
    check("a nimcache write INSIDE the window reads working",
          v["verdict"] == "working" and v["nimcache_changed"] is True, str(v))

    v = buildlock.hung_verdict(prev, sample(t0 + 5, idle, t0 - 600), 20, 0.5)
    check("samples closer together than the window are unknown, not hung?",
          v["verdict"] == "unknown" and "to go" in v["why"], str(v))

    broken = sample(t0 + 30, idle, t0 - 600)
    broken["proc_error"] = "powershell timed out"
    v = buildlock.hung_verdict(prev, broken, 20, 0.5)
    check("an unreadable process table is unknown and says NOT PERFORMED",
          v["verdict"] == "unknown" and "NOT PERFORMED" in v["why"], str(v))

    v = buildlock.hung_verdict(
        prev, sample(t0 + 30, idle, t0 - 600, truncated=True), 20, 0.5)
    check("a TRUNCATED nimcache walk is unknown, not hung?",
          v["verdict"] == "unknown" and "TRUNCATED" in v["why"], str(v))

    v = buildlock.hung_verdict(
        prev, sample(t0 + 30, idle, t0 - 600, error="scandir blew up"),
        20, 0.5)
    check("a nimcache walk that ERRORED is unknown, not hung?",
          v["verdict"] == "unknown", str(v))

    # A child that finished during the window is progress, even with no cpu
    # delta on the survivors -- a compiler exiting is the most normal thing a
    # build does, and killing at that moment would be the worst false positive.
    gone_cur = sample(t0 + 30, {"1": {"name": "python.exe", "cpu_s": 0.27}},
                      t0 - 600)
    v = buildlock.hung_verdict(prev, gone_cur, 20, 0.5)
    check("a process EXITING during the window reads working",
          v["verdict"] == "working" and len(v["gone"]) == 1, str(v))

    check("hung_lines() prints the pids, the deltas and the nimcache age",
          all(s in "\n".join(buildlock.hung_lines(
              buildlock.hung_verdict(prev, cur, 20, 0.5)))
              for s in ("nimony.exe", "delta", "newest nimcache")),
          "\n".join(buildlock.hung_lines(
              buildlock.hung_verdict(prev, cur, 20, 0.5))))


def test_proc_table_real(tmp):
    """The instrument itself, against this machine. If proc_table() cannot see
    a process we just started, every verdict above is built on nothing.

    The nimcache half runs against a CONSTRUCTED tree, not the live checkout's
    nimcache: walking a nimcache that a real build is writing measures that
    build, not this walker, and it was the slowest thing in the suite whenever
    anyone was building. Constructing the tree also makes the `dirs > 0`
    assertion mean something -- against the real checkout it passed whether or
    not the walk worked, because the directories were there either way.
    """
    print("\nprocess table: can it see a tree we just made?")
    t = time.time()
    table, err = buildlock.proc_table()
    dt = time.time() - t
    if table is None:
        check("INCONCLUSIVE: no process table on this machine, so NO hang "
              "verdict here can be trusted", False, str(err))
        return
    print("    proc_table(): %d processes in %.2fs" % (len(table), dt))
    check("proc_table sees this very process", os.getpid() in table,
          "our pid %d is missing" % os.getpid())
    check("proc_table reports cpu for this process",
          table[os.getpid()]["cpu_s"] > 0,
          "cpu_s=%r" % table[os.getpid()]["cpu_s"])

    p = subprocess.Popen([sys.executable, "-c", PARENT, CHILD_SLEEP],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        time.sleep(2.0)
        table, _ = buildlock.proc_table()
        tree = buildlock.proc_tree(table, p.pid)
        print("    tree of pid %d: %s" % (p.pid, tree))
        check("proc_tree finds the parent AND the grandchild it spawned",
              len(tree) >= 2 and tree[0] == p.pid,
              "tree=%r -- without this, a hung nimony under a sleeping aowl "
              "would never be sampled" % (tree,))
    finally:
        kill_world(p)

    # A constructed checkout: two nimcache dirs at different depths, plus one
    # under a directory the walker is documented to SKIP.
    ncrepo = os.path.join(tmp, "nc-repo")
    for rel in ("host/nimcache", "mods/maps/nimcache",
                ".claude/worktrees/other/nimcache"):
        d = os.path.join(ncrepo, rel.replace("/", os.sep))
        os.makedirs(d, exist_ok=True)
        for i in range(50):
            with open(os.path.join(d, "f%d.c" % i), "w",
                      encoding="utf-8", newline="\n") as f:
                f.write("/* %d */\n" % i)
    t = time.time()
    nc = buildlock.nimcache_newest(ncrepo)
    dt = time.time() - t
    print("    nimcache_newest(constructed): %d dirs, %d files, %.2fs, "
          "truncated=%s" % (nc["dirs"], nc["files"], dt, nc["truncated"]))
    check("the nimcache walk finds BOTH nimcache dirs and skips "
          ".claude/worktrees", nc["dirs"] == 2, str(nc))
    check("the nimcache walk sees the files it planted",
          nc["files"] >= 100, str(nc))
    check("the nimcache walk completes inside its budget",
          not nc["truncated"] and nc["error"] is None, str(nc))
    check("the newest mtime it reports is one of the planted files",
          nc["newest"] is not None and nc["path"]
          and os.path.exists(os.path.join(ncrepo,
                                          nc["path"].replace("/", os.sep))),
          str(nc))


ART_REL = "host/Aowlspt.Host.Il2Cpp/bin/aowlspt-host-il2cpp.dll"


def make_artifact_repo(tmp, name, writes=True, rc=0, payload="one",
                       remove=True, extra=None, touches=None, sleep_s=0.0):
    """A repo with its OWN tools/deploy.json and a stand-in `aowl` that
    reproduces the measured behaviour: it REMOVES the declared artifact before
    (maybe) writing it, then exits with a chosen code.

    That removal is the whole incident. A driver that merely failed to write
    would not reproduce it, because the previous build's file would still be
    sitting there and the check would pass for the wrong reason.

    Returns `(repo, artifact_path)`, or `(None, None)` if the copied
    interpreter will not run -- INCONCLUSIVE, not a pass.
    """
    repo = os.path.join(tmp, name)
    os.makedirs(os.path.join(repo, "tools"), exist_ok=True)
    arts = [{"name": "host", "src": ART_REL, "dst": "aowlspt-host-il2cpp.dll",
             "markers": []}]
    arts.extend(extra or [])
    with open(os.path.join(repo, "tools", "deploy.json"), "w",
              encoding="utf-8", newline="\n") as f:
        json.dump({"install": "D:\\nowhere", "artifacts": arts}, f)
    bin_dir = os.path.join(repo, "installer", "build")
    os.makedirs(bin_dir, exist_ok=True)
    exe = os.path.join(bin_dir, "aowl.exe")
    shutil.copy(sys.executable, exe)
    art = os.path.join(repo, ART_REL.replace("/", os.sep))
    with open(os.path.join(repo, "build"), "w", encoding="utf-8",
              newline="\n") as f:
        # `touches` REWRITES a source file after the artifact is written --
        # i.e. it reproduces the 2026-09-03 incident inside the stand-in
        # driver, where another agent's edit lands while the build is running
        # and the artifact is therefore a pre-edit snapshot.
        f.write("import os, sys, time\n"
                "art = %r\n"
                "os.makedirs(os.path.dirname(art), exist_ok=True)\n"
                "if %r and os.path.exists(art):\n"
                "    os.unlink(art)\n"
                "if %r:\n"
                "    open(art, 'w').write(%r)\n"
                "time.sleep(%r)\n"
                "t = %r\n"
                "if t:\n"
                "    os.makedirs(os.path.dirname(t), exist_ok=True)\n"
                "    open(t, 'a').write('# edited mid-build\\n')\n"
                "    os.utime(t, None)\n"
                "sys.exit(%d)\n"
                % (art, remove, writes, payload, sleep_s,
                   (os.path.join(repo, touches.replace("/", os.sep))
                    if touches else None), rc))
    probe = subprocess.run([exe, "-c", "print('ok')"],
                           capture_output=True, text=True)
    if probe.returncode != 0 or "ok" not in probe.stdout:
        return None, None
    return repo, art


def build_in(repo, *args):
    r = subprocess.run([sys.executable, BL, "--repo", guard_repo(repo)] + list(args),
                       capture_output=True, text=True, timeout=180)
    return r.returncode, r.stdout + r.stderr


def test_status_you(tmp):
    """`--status` must say where the READER stands, and what will be written.

    Two agents asked for this on 2026-09-03: the report described the world
    but not the reader's place in it. Three worlds again, because "you are
    queued" printed unconditionally would be worse than nothing -- it would
    make somebody wait for a build that is not theirs.
    """
    print("\n--status: where the caller stands, and the holder's artifact")
    repo, _art = make_artifact_repo(tmp, "you-status", writes=False)
    if repo is None:
        check("INCONCLUSIVE: no stand-in driver, nothing was tested", False,
              "")
        return
    lp = buildlock.lock_path(repo)

    # 1. A bystander: somebody else holds it, building `build host`.
    holder = plant_holder(lp)
    with open(lp, "r", encoding="utf-8") as f:
        rec = json.load(f)
    rec["cmd"] = "build host"
    with open(lp, "w", encoding="utf-8") as f:
        json.dump(rec, f)
    try:
        rc, out = cli(repo, "--status")
        _rc, jout = cli(repo, "--status", "--json")
        you = json.loads(jout).get("you") or {}
        check("a bystander is told NOT IN THE QUEUE, explicitly",
              "NOT IN THE QUEUE" in out and you.get("state") == "not-in-queue",
              repr(out))

        # 2. The SAME command, with AOWL_BUILDLOCK set to the holder's pid --
        # what a script running inside the build sees.
        env = dict(os.environ)
        env["AOWL_BUILDLOCK"] = str(holder.pid)
        r = subprocess.run([sys.executable, BL, "--repo", guard_repo(repo),
                            "--status"], capture_output=True, text=True,
                           env=env, timeout=60)
        check("a process running INSIDE the build is told it is HOLDING",
              "HOLDING this lock" in r.stdout, repr(r.stdout))
        check("the two answers DIFFER (else the line is unconditional)",
              ("HOLDING this lock" in r.stdout)
              != ("HOLDING this lock" in out), repr(r.stdout))

        # 3. A queued waiter, seen from its own pid.
        w, _t = plant_ticket(buildlock.queue_dir(lp),
                             int(time.time() * 1e9), "build host")
        try:
            env2 = dict(os.environ)
            env2["AOWL_BUILDLOCK"] = str(w.pid)
            r2 = subprocess.run([sys.executable, BL, "--repo",
                                 guard_repo(repo), "--status"],
                                capture_output=True, text=True, env=env2,
                                timeout=60)
            check("a queued waiter is told its POSITION",
                  "QUEUED position 1 of 1" in r2.stdout, repr(r2.stdout))
        finally:
            w.kill()
            w.wait()

        check("the held report names the path the holder will write",
              ART_REL in out, repr(out))
    finally:
        holder.kill()
        holder.wait()

    # A holder whose target declares no artifact must not read as "writes
    # nothing"; it must say the path is UNKNOWN and why.
    holder2 = plant_holder(lp)      # its recorded cmd is "planted holder"
    try:
        _rc, out2 = cli(repo, "--status")
        check("an underivable artifact path says UNKNOWN, not nothing",
              "artifact path is UNKNOWN" in out2, repr(out2))
    finally:
        holder2.kill()
        holder2.wait()


SRC_REL = "host/Aowlspt.Host.Il2Cpp/hostmain.nim"


def _plant_source(repo, rel=SRC_REL, age=120.0):
    """One ordinary source file, comfortably older than any build."""
    p = os.path.join(repo, rel.replace("/", os.sep))
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w", encoding="utf-8", newline="\n") as f:
        f.write("# a source the build reads\n")
    t = time.time() - age
    os.utime(p, (t, t))
    return p


def test_source_change(tmp):
    """A build whose SOURCES moved under it must not be reported as success.

    MEASURED 2026-09-03 ~19:24: `buildlock.py build host` exited 0 and wrote a
    sidecar for a build whose sources were edited AFTER the lock was acquired
    (source mtimes 19:24, acquire 19:22:39). The DLL was a PRE-EDIT snapshot --
    `grep -a` found zero of the seven literals the edit added -- so the marker
    check that followed measured the wrong bytes and said so confidently.

    THE FALSIFIER, and it is the whole test: the second world runs the SAME
    driver, writing the SAME artifact, with the touch turned off. If both
    worlds refused, the refusal would be unconditional and would prove
    nothing; if both passed, the check would be inert. Three worlds, three
    outcomes, and the third (`build sim`, which declares no artifact) pins
    that "I could not look" prints NOT PERFORMED instead of passing quietly.
    """
    print("\nsources changed during the build (exit %d)"
          % buildlock.SOURCES_CHANGED_EXIT)
    repo, art = make_artifact_repo(tmp, "srcchg", touches=SRC_REL, sleep_s=2.0)
    if repo is None:
        check("INCONCLUSIVE: no runnable stand-in driver, nothing was tested",
              False, "the copied python.exe would not start")
        return
    src = _plant_source(repo)
    t_build = time.time()
    # No --no-store-audit here, deliberately: the storelint pre-flight now
    # answers INCONCLUSIVE (never FAIL) for a tree its baseline was not
    # written for, so a synthetic repo with a .nim under host/ no longer
    # refuses the build. These worlds therefore exercise the real pre-flight.
    rc, out = build_in(repo, "build", "host")
    touched_after = os.stat(src).st_mtime > t_build

    check("the driver really did touch the source mid-build (else this world "
          "is vacuous)", touched_after,
          "source mtime %.1f vs build start %.1f"
          % (os.stat(src).st_mtime, t_build))
    check("a build whose source changed exits %d, NOT 0"
          % buildlock.SOURCES_CHANGED_EXIT,
          rc == buildlock.SOURCES_CHANGED_EXIT, "rc=%d\n%s" % (rc, out[-800:]))
    check("it prints SOURCES CHANGED DURING THE BUILD",
          "SOURCES CHANGED DURING THE BUILD" in out, "tail: %r" % out[-600:])
    check("it NAMES the file and its mtime",
          "hostmain.nim" in out.split("SOURCES CHANGED", 1)[-1],
          "tail: %r" % out[-600:])

    side = buildlock.read_sidecar(art)
    check("the sidecar exists and is flagged stale_sources=true",
          bool(side) and side.get("stale_sources") is True
          and side.get("source_check") == "CHANGED", repr(side))
    check("the sidecar names the changed file, so a later reader needs no log",
          any("hostmain.nim" in (f.get("path") or "")
              for f in (side or {}).get("sources_changed") or []),
          repr((side or {}).get("sources_changed")))

    # THE CONTROL. Same driver, same artifact, no mid-build edit.
    repo2, art2 = make_artifact_repo(tmp, "srcchg-ok", sleep_s=2.0)
    if repo2 is None:
        check("INCONCLUSIVE: no control driver, the refusal above is not "
              "evidence", False, "")
        return
    _plant_source(repo2)
    rc2, out2 = build_in(repo2, "build", "host")
    check("CONTROL: the same build without the edit exits 0", rc2 == 0,
          "rc=%d\n%s" % (rc2, out2[-800:]))
    check("CONTROL: it does NOT print SOURCES CHANGED",
          "SOURCES CHANGED" not in out2, "tail: %r" % out2[-600:])
    check("CONTROL: it says the sources were unchanged, in as many words",
          "sources unchanged during the build" in out2,
          "tail: %r" % out2[-600:])
    side2 = buildlock.read_sidecar(art2)
    check("CONTROL: the sidecar records source_check=unchanged and "
          "stale_sources=false",
          bool(side2) and side2.get("stale_sources") is False
          and side2.get("source_check") == "unchanged", repr(side2))

    # THIRD OUTCOME: nothing to scan is NOT PERFORMED, and never a pass.
    rc3, out3 = build_in(repo2, "build", "sim")
    check("a target with no declared artifact prints SOURCE-CHANGE CHECK NOT "
          "PERFORMED", "SOURCE-CHANGE CHECK NOT PERFORMED" in out3,
          "rc=%d tail: %r" % (rc3, out3[-600:]))
    check("...and does not refuse on it", rc3 == 0, "rc=%d" % rc3)

    # And the flag must be able to turn it off, or the escape hatch is a lie.
    # In its OWN repo: re-running the touching driver over `repo` would
    # overwrite the flagged sidecar the deploy assertions below depend on.
    repo3, _art3 = make_artifact_repo(tmp, "srcchg-off", touches=SRC_REL,
                                      sleep_s=2.0)
    if repo3 is not None:
        _plant_source(repo3)
        rc4, out4 = build_in(repo3, "--no-source-check",
                             "build", "host")
        check("--no-source-check builds the same tree without the refusal",
              rc4 == 0 and "SOURCES CHANGED" not in out4,
              "rc=%d\n%s" % (rc4, out4[-600:]))

    # DEPLOY MUST REFUSE THOSE BYTES. This calls the real function deploy.py's
    # cmd_deploy calls, on the real sidecars written above -- a refusal in
    # buildlock that deploy ignores would leave the pre-edit DLL one command
    # away from the live install.
    try:
        import deploy as deploymod
    except Exception as ex:
        check("INCONCLUSIVE: tools/deploy.py could not be imported, so the "
              "deploy refusal was NOT TESTED", False, str(ex))
        return
    ok_bad, lines_bad = deploymod.sidecar_check(art)
    ok_good, lines_good = deploymod.sidecar_check(art2)
    check("deploy.py REFUSES an artifact whose sidecar says stale_sources",
          ok_bad is False and any("SOURCES CHANGED" in l for l in lines_bad),
          repr(lines_bad))
    check("CONTROL: deploy.py accepts the artifact built with no mid-build "
          "edit -- and vouches for it, so the acceptance is not vacuous",
          ok_good is True and any("sha matches" in l for l in lines_good),
          repr(lines_good))


def _rewrite_driver(repo, body):
    """Replace the stand-in `aowl` script -- i.e. run a DIFFERENT build in the
    same checkout, which is exactly the situation this file is about."""
    with open(os.path.join(repo, "build"), "w", encoding="utf-8",
              newline="\n") as f:
        f.write(body)


def test_stage(tmp):
    """A build's bytes must survive the NEXT build.

    MEASURED 2026-09-04 08:58: `build host` finished clean, a queued
    `build host` then took the lock and `aowl` -- which removes its output
    before writing it -- deleted the artifact before the deploy copied it. The
    deploy refused ("the artifact is not the build that was recorded", which
    was the correct answer) and the launcher ran the OLD host DLL.

    The falsifier for every claim below is the same one: with the stage
    removed, `bin/` is empty and there is nothing to deploy. That control is
    asserted, not assumed.
    """
    print("\nstage: the next build must not be able to delete these bytes")
    repo, art = make_artifact_repo(tmp, "stage-ok", payload="firstbuild")
    if repo is None:
        check("INCONCLUSIVE: no runnable stand-in driver, nothing was tested",
              False, "the copied python.exe would not start")
        return

    rc, out = build_in(repo, "build", "host")
    check("a successful build still exits 0 with staging on", rc == 0,
          "rc=%d\n%s" % (rc, out[-600:]))
    check("it PRINTS where it staged the artifact",
          "staged host" in out and ".stage" in out, out[-800:])

    recs = stagemod.stages(repo)
    check("exactly one stage exists after one build", len(recs) == 1,
          str([r["path"] for r in recs]))
    if not recs:
        return
    r0 = recs[0]
    check("the staged bytes are the artifact's bytes",
          os.path.isfile(r0["path"])
          and open(r0["path"], "rb").read() == open(art, "rb").read(),
          r0["path"])
    check("the sidecar was staged beside them, with the same sha",
          r0["sidecar"].get("sha256") == buildlock.sha256_file(art)
          and r0["sha256"] == buildlock.sha256_file(art),
          json.dumps(r0["sidecar"])[:200])
    check("the stage records the target and the git head field",
          r0["target"] == "build host" and "git_head" in r0["sidecar"],
          r0["target"])

    # THE INCIDENT. A second build in the same checkout removes the artifact
    # and fails. bin/ is empty; the stage must still hold the first build.
    _rewrite_driver(repo, "import os, sys\nart = %r\n"
                          "os.path.exists(art) and os.unlink(art)\n"
                          "sys.exit(1)\n" % art)
    rc2, out2 = build_in(repo, "build", "host")
    check("the second build failed and removed bin/", rc2 != 0
          and not os.path.exists(art),
          "rc=%d exists=%s" % (rc2, os.path.exists(art)))
    check("THE POINT: the first build's bytes are still in the stage",
          os.path.isfile(r0["path"])
          and open(r0["path"], "rb").read().decode("utf-8",
                                                   "replace") == "firstbuild",
          r0["path"])
    pick, notes = stagemod.pick(repo, artifact_src=ART_REL)
    check("and pick() selects it by default",
          pick is not None and pick["sha"] == r0["sha"], "; ".join(notes))
    # --status must list what is deployable; asked BEFORE the control below
    # deletes the stage, or it would be measuring the wrong world.
    rc5, out5 = build_in(repo, "--status")
    check("--status lists the staged builds",
          "staged builds" in out5 and r0["sha"] in out5, out5[-600:])

    check("CONTROL: with the stage deleted there is nothing left at all",
          _no_stage_left(repo, r0), "the stage or bin/ still holds something")

    # A stale_sources build is staged (so it can be inspected) but is NEVER
    # auto-selected. Without both halves this would be untestable: a stage
    # that is not written cannot be shown to be skipped.
    repo3, art3 = make_artifact_repo(tmp, "stage-stale", payload="stalebytes",
                                     touches=SRC_REL, sleep_s=1.5)
    _plant_source(repo3)
    rc3, out3 = build_in(repo3, "build", "host")
    check("a build whose sources moved still exits %d"
          % buildlock.SOURCES_CHANGED_EXIT,
          rc3 == buildlock.SOURCES_CHANGED_EXIT, "rc=%d\n%s"
          % (rc3, out3[-400:]))
    st3 = stagemod.stages(repo3)
    check("its bytes ARE staged (so they can be looked at)",
          len(st3) == 1 and st3[0]["stale_sources"],
          str([(r["sha"], r["stale_sources"]) for r in st3]))
    pick3, notes3 = stagemod.pick(repo3, artifact_src=ART_REL)
    check("but pick() refuses to select a stale_sources stage",
          pick3 is None and any("stale_sources" in n for n in notes3),
          "; ".join(notes3))

    # The escape hatch, and it must be loud.
    repo4, _art4 = make_artifact_repo(tmp, "stage-off", payload="two")
    rc4, out4 = build_in(repo4, "--no-stage", "build", "host")
    check("--no-stage stages nothing and SAYS so",
          rc4 == 0 and not stagemod.stages(repo4) and "--no-stage" in out4,
          "rc=%d\n%s" % (rc4, out4[-400:]))

    rc6, out6 = build_in(repo4, "--status")
    check("--status says NONE rather than printing nothing",
          "NONE" in out6, out6[-400:])


def _no_stage_left(repo, rec):
    """Delete the stage and confirm the checkout then holds nothing.

    This is the falsifier for the test above: if `bin/` still had the bytes,
    every 'the stage saved it' claim would pass for the wrong reason.
    """
    shutil.rmtree(os.path.join(repo, ".stage"), ignore_errors=True)
    return (not stagemod.stages(repo)
            and not os.path.exists(os.path.join(repo,
                                                ART_REL.replace("/", os.sep))))


def test_artifact_check(tmp):
    """Exit 0 is a claim about a PROCESS. The artifact is a different question.

    MEASURED five times on 2026-09-02: a queued build removed the previous
    build's DLL and then failed, and this script had already reported `ok` to
    the agent now reading an absent file.

    Every verdict below is paired with a control that makes the opposite
    verdict fire from the same code path, because a refusal that cannot be
    turned off is indistinguishable from a refusal that always fires.
    """
    print("\nartifact check: a build's exit 0 is not the artifact's existence")
    repo, art = make_artifact_repo(tmp, "art-ok")
    if repo is None:
        check("INCONCLUSIVE: no runnable stand-in driver, nothing was tested",
              False, "the copied python.exe would not start")
        return

    rc, out = build_in(repo, "build", "host")
    check("a build that WRITES its artifact still exits 0", rc == 0,
          "rc=%d\n%s" % (rc, out[-600:]))
    check("success prints the artifact path, size and sha256",
          ART_REL in out and "sha256" in out and " bytes" in out,
          out[-600:])
    side = os.path.join(art + ".built.json")
    check("a sidecar was written beside the artifact", os.path.exists(side),
          side)
    if os.path.exists(side):
        with open(side, encoding="utf-8") as f:
            doc = json.load(f)
        real = buildlock.sha256_file(art)
        check("the sidecar's sha256 is the file's real sha256",
              doc.get("sha256") == real,
              "%r vs %r" % (doc.get("sha256"), real))
        check("the sidecar records target/pid/size/started/finished/git_head",
              doc.get("target") == "build host"
              and isinstance(doc.get("pid"), int)
              and doc.get("size") == os.path.getsize(art)
              and doc.get("finished", 0) >= doc.get("started", 1)
              and "git_head" in doc,
              json.dumps(doc)[:300])

    # THE INCIDENT. Same command, same repo shape, a driver that removes the
    # artifact and produces nothing while still exiting 0.
    repo2, art2 = make_artifact_repo(tmp, "art-absent", writes=False)
    rc2, out2 = build_in(repo2, "build", "host")
    check("a build that exits 0 with NO artifact is REFUSED",
          rc2 == buildlock.ARTIFACT_ABSENT_EXIT,
          "rc=%d (wanted %d)\n%s" % (rc2, buildlock.ARTIFACT_ABSENT_EXIT,
                                     out2[-600:]))
    check("it says BUILT BUT ARTIFACT ABSENT", "BUILT BUT ARTIFACT ABSENT"
          in out2, out2[-600:])
    check("and it writes no sidecar for a file that is not there",
          not os.path.exists(art2 + ".built.json"), art2)

    # STALE: the artifact exists, but it is the PREVIOUS build's. The driver
    # neither removes nor writes, so the only thing distinguishing this from
    # the passing case above is the mtime.
    repo3, art3 = make_artifact_repo(tmp, "art-stale", writes=False,
                                     remove=False)
    os.makedirs(os.path.dirname(art3), exist_ok=True)
    with open(art3, "w", encoding="utf-8", newline="\n") as f:
        f.write("an earlier build's output\n")
    old = time.time() - 3600
    os.utime(art3, (old, old))
    rc3, out3 = build_in(repo3, "build", "host")
    check("an artifact older than the build that 'produced' it is REFUSED",
          rc3 == buildlock.ARTIFACT_STALE_EXIT,
          "rc=%d (wanted %d)\n%s" % (rc3, buildlock.ARTIFACT_STALE_EXIT,
                                     out3[-600:]))
    check("it says ARTIFACT STALE (mtime before build start)",
          "ARTIFACT STALE (mtime before build start)" in out3, out3[-600:])

    # CONTROL for the staleness rule: the identical pre-existing file, but this
    # time the build rewrites it. If this failed, the rule would be firing on
    # existence rather than on mtime.
    repo4, art4 = make_artifact_repo(tmp, "art-fresh", writes=True,
                                     remove=False)
    os.makedirs(os.path.dirname(art4), exist_ok=True)
    with open(art4, "w", encoding="utf-8", newline="\n") as f:
        f.write("an earlier build's output\n")
    os.utime(art4, (old, old))
    rc4, out4 = build_in(repo4, "build", "host")
    check("CONTROL: the same stale file REWRITTEN by the build passes",
          rc4 == 0 and "ARTIFACT STALE" not in out4,
          "rc=%d\n%s" % (rc4, out4[-600:]))

    # A failing build keeps its own exit code: the artifact check must not
    # rewrite a compiler error into an artifact error.
    repo5, _ = make_artifact_repo(tmp, "art-rc7", writes=False, rc=7)
    rc5, out5 = build_in(repo5, "build", "host")
    check("a FAILED build still returns the compiler's exit code, not 5",
          rc5 == 7, "rc=%d\n%s" % (rc5, out5[-600:]))

    # A target deploy.json says nothing about must not read as a pass.
    rc6, out6 = build_in(repo, "build", "sim")
    check("a target with no declared artifact says NOT PERFORMED",
          rc6 == 0 and "ARTIFACT CHECK NOT PERFORMED" in out6,
          "rc=%d\n%s" % (rc6, out6[-600:]))

    # The escape hatch exists and does what it says.
    repo7, _ = make_artifact_repo(tmp, "art-off", writes=False)
    rc7, out7 = build_in(repo7, "--no-artifact-check", "build", "host")
    check("--no-artifact-check turns the refusal off (and only that)",
          rc7 == 0 and "BUILT BUT ARTIFACT ABSENT" not in out7,
          "rc=%d\n%s" % (rc7, out7[-600:]))


def _plant_prebuilt(repo, art, payload="one", art_age=3600.0, src_age=7200.0,
                    sidecar=True):
    """An artifact that an EARLIER build produced, its sidecar, and one source
    file. Returns the artifact's mtime."""
    os.makedirs(os.path.dirname(art), exist_ok=True)
    with open(art, "w", encoding="utf-8", newline="\n") as f:
        f.write(payload)
    now = time.time()
    amt = now - art_age
    os.utime(art, (amt, amt))
    src = os.path.join(repo, "host", "Aowlspt.Host.Il2Cpp", "aowlhost.nim")
    os.makedirs(os.path.dirname(src), exist_ok=True)
    with open(src, "w", encoding="utf-8", newline="\n") as f:
        f.write("# a source file\n")
    smt = now - src_age
    os.utime(src, (smt, smt))
    if sidecar:
        with open(art + buildlock.SIDECAR_SUFFIX, "w", encoding="utf-8",
                  newline="\n") as f:
            json.dump({"target": "build host", "artifact": ART_REL,
                       "sha256": buildlock.sha256_file(art),
                       "size": os.path.getsize(art), "mtime": amt,
                       "started": amt - 60, "finished": amt,
                       "pid": 4242, "git_head": None}, f)
    return amt, src


def test_noop_rebuild_is_up_to_date(tmp):
    """MEASURED 2026-09-02: a no-op `build host` -- 41s, nothing changed, aowl
    left the existing DLL in place -- exited 6 ARTIFACT STALE because the DLL's
    mtime predated the build start. A false refusal.

    The two directions are the whole test, and neither can pass vacuously:

      * nothing changed  -> exit 0, and it must SAY up-to-date rather than
        printing the normal success line, and it must not rewrite the sidecar;
      * a source is newer than an unwritten artifact -> still exit 6. Without
        this half, "always exit 0" would pass the first check.
    """
    print("\nno-op rebuild: UP-TO-DATE vs ARTIFACT STALE")

    # (a) the measured case: driver rewrites nothing, sources are older.
    repo, art = make_artifact_repo(tmp, "art-noop", writes=False,
                                   remove=False, rc=0)
    if repo is None:
        check("INCONCLUSIVE: the stand-in driver would not run", False)
        return
    _plant_prebuilt(repo, art)
    side_before = os.path.getmtime(art + buildlock.SIDECAR_SUFFIX)
    rc, out = build_in(repo, "build", "host")
    check("no-op rebuild exits 0 (was exit 6 ARTIFACT STALE)", rc == 0,
          "rc=%d\n%s" % (rc, out[-900:]))
    check("...and SAYS up-to-date rather than claiming it built something",
          "UP-TO-DATE" in out, out[-900:])
    check("...and does not print the refusal banner",
          "REFUSING TO REPORT SUCCESS" not in out
          and "ARTIFACT STALE" not in out, out[-900:])
    check("...and refreshes nothing (the sidecar is untouched)",
          os.path.exists(art + buildlock.SIDECAR_SUFFIX)
          and abs(os.path.getmtime(art + buildlock.SIDECAR_SUFFIX)
                  - side_before) < 0.5,
          "sidecar mtime moved")

    # (b) THE FALSIFYING INPUT. Same unwritten artifact, one source newer.
    repo2, art2 = make_artifact_repo(tmp, "art-noop-stale", writes=False,
                                     remove=False, rc=0)
    if repo2 is None:
        check("INCONCLUSIVE: the stand-in driver would not run (b)", False)
        return
    _, src = _plant_prebuilt(repo2, art2, src_age=60.0)   # newer than the art
    rc2, out2 = build_in(repo2, "build", "host")
    check("a source NEWER than an unwritten artifact is still exit 6",
          rc2 == buildlock.ARTIFACT_STALE_EXIT, "rc=%d\n%s" % (rc2, out2[-900:]))
    check("...and the refusal names the file that is newer",
          "aowlhost.nim" in out2 and "ARTIFACT STALE" in out2, out2[-900:])

    # (c) no sidecar at all: who wrote these bytes is UNKNOWN, so refuse.
    repo3, art3 = make_artifact_repo(tmp, "art-noop-nosidecar", writes=False,
                                     remove=False, rc=0)
    if repo3 is None:
        check("INCONCLUSIVE: the stand-in driver would not run (c)", False)
        return
    _plant_prebuilt(repo3, art3, sidecar=False)
    rc3, out3 = build_in(repo3, "build", "host")
    check("an unwritten artifact with NO SIDECAR still refuses (exit 6)",
          rc3 == buildlock.ARTIFACT_STALE_EXIT, "rc=%d\n%s" % (rc3, out3[-900:]))
    check("...and says which fact is missing, not that it is stale-by-mtime",
          "NO SIDECAR" in out3, out3[-900:])


def test_verify_artifact(tmp):
    """`verify-artifact` can say all four things about the same repo.

    A verifier is only worth having if MATCH is falsifiable, so the same
    artifact is walked through MATCH -> REPLACED -> ABSENT -> NO SIDECAR by
    changing the WORLD, never by changing the question.
    """
    print("\nverify-artifact: is the file I am reading the build I think?")
    repo, art = make_artifact_repo(tmp, "verify", payload="build-A")
    if repo is None:
        check("INCONCLUSIVE: no runnable stand-in driver, nothing was tested",
              False, "the copied python.exe would not start")
        return
    rc, out = build_in(repo, "build", "host")
    if rc != 0:
        check("INCONCLUSIVE: the stand-in build did not succeed", False,
              out[-400:])
        return
    rc, out = build_in(repo, "verify-artifact", "host")
    check("MATCH right after the build that wrote it",
          rc == buildlock.VERIFY_MATCH_EXIT and "MATCH" in out,
          "rc=%d\n%s" % (rc, out[-400:]))

    # Somebody overwrites the bytes without going through the lock.
    with open(art, "w", encoding="utf-8", newline="\n") as f:
        f.write("written by nobody\n")
    rc, out = build_in(repo, "verify-artifact", "host")
    check("REPLACED when the bytes changed under the sidecar",
          rc == buildlock.VERIFY_REPLACED_EXIT and "REPLACED" in out,
          "rc=%d\n%s" % (rc, out[-400:]))

    os.unlink(art)
    rc, out = build_in(repo, "verify-artifact", "host")
    check("ABSENT when the file is gone",
          rc == buildlock.VERIFY_ABSENT_EXIT and "ABSENT" in out,
          "rc=%d\n%s" % (rc, out[-400:]))
    check("ABSENT names the build that HAD produced it, from the sidecar",
          "It existed when pid" in out, out[-400:])

    # NO SIDECAR: a file that exists but was never built through this lock.
    os.unlink(art + ".built.json")
    with open(art, "w", encoding="utf-8", newline="\n") as f:
        f.write("hand-copied from another checkout\n")
    rc, out = build_in(repo, "verify-artifact", "host")
    check("NO SIDECAR is its own verdict, not a MATCH",
          rc == buildlock.VERIFY_NO_SIDECAR_EXIT and "NO SIDECAR" in out,
          "rc=%d\n%s" % (rc, out[-400:]))

    # THE MEASURED INCIDENT, end to end: A builds, B builds something else
    # over the top, and A asks whether the file is still A's. Sidecar-vs-file
    # alone cannot answer that -- B rewrote the sidecar too -- so --expect is
    # the sharper question and this is the case that proves it is needed.
    repo2, art2 = make_artifact_repo(tmp, "verify2", payload="build-A")
    rc, _ = build_in(repo2, "build", "host")
    sha_a2 = buildlock.sha256_file(art2)
    repo2b, _ = make_artifact_repo(tmp, "verify2", payload="build-B")
    rc, _ = build_in(repo2, "build", "host")
    sha_b2 = buildlock.sha256_file(art2)
    check("the second build really did change the bytes (control)",
          sha_a2 != sha_b2, "%s vs %s" % (sha_a2[:12], sha_b2[:12]))
    rc, out = build_in(repo2, "verify-artifact", "host")
    check("plain verify-artifact MATCHes B's build -- consistent, and NOT "
          "proof it is yours",
          rc == buildlock.VERIFY_MATCH_EXIT, "rc=%d\n%s" % (rc, out[-400:]))
    rc, out = build_in(repo2, "verify-artifact", "host", "--expect", sha_a2)
    check("--expect <A's sha> reports REPLACED",
          rc == buildlock.VERIFY_REPLACED_EXIT, "rc=%d\n%s" % (rc, out[-400:]))
    check("...and names the pid and finish time of the build that overwrote it",
          "written by pid" in out and "finished" in out.lower(), out[-400:])
    rc, out = build_in(repo2, "verify-artifact", "host", "--expect", sha_b2)
    check("CONTROL: --expect <B's sha> reports MATCH",
          rc == buildlock.VERIFY_MATCH_EXIT, "rc=%d\n%s" % (rc, out[-400:]))

    rc, out = build_in(repo2, "verify-artifact", "sim")
    check("verify-artifact on a target with no declared artifact is NOT "
          "PERFORMED, not a MATCH",
          rc != buildlock.VERIFY_MATCH_EXIT and "NOT PERFORMED" in out,
          "rc=%d\n%s" % (rc, out[-400:]))


def test_artifact_units(tmp):
    """The pieces, without spawning anything: the mapping, the three-state
    status, and the exit codes being distinct from the ones already in use."""
    print("\nartifact units: the mapping and the states")
    repo = os.path.dirname(HERE)

    sel, why = buildlock.target_artifacts(repo, ["build", "host"])
    check("`build host` maps to the host DLL from the REAL deploy.json",
          sel is not None and any(a["src"].replace("\\", "/") == ART_REL
                                  for a in sel),
          "why=%r" % why)
    sel_sim, why_sim = buildlock.target_artifacts(repo, ["build", "sim"])
    check("`build sim` declares nothing and SAYS so (not an empty pass)",
          sel_sim is None and "no artifact" in (why_sim or ""),
          "%r / %r" % (sel_sim, why_sim))
    sel_mod, _ = buildlock.target_artifacts(repo, ["build", "mod", "maps"])
    check("`build mod maps` maps to exactly the maps DLL",
          sel_mod is not None and [a["name"] for a in sel_mod] == ["maps"],
          str([a["name"] for a in (sel_mod or [])]))
    sel_bad, why_bad = buildlock.target_artifacts(repo, ["build", "mod",
                                                         "nosuchmod"])
    check("an unknown mod name is NOT PERFORMED, not a pass",
          sel_bad is None and bool(why_bad), "%r" % (why_bad,))

    # A --repo with no tools/deploy.json declares nothing, and must not be
    # answered from THIS checkout's declarations -- that would check the wrong
    # tree and report ABSENT for an artifact that tree never claimed to build.
    bare = os.path.join(tmp, "bare-repo")
    os.makedirs(bare, exist_ok=True)
    sel_bare, why_bare = buildlock.target_artifacts(bare, ["build", "host"])
    check("a repo with no tools/deploy.json is NOT PERFORMED, never answered "
          "from this checkout's deploy.json",
          sel_bare is None and "deploy.json" in (why_bare or ""),
          "%r / %r" % (sel_bare, why_bare))

    check("the artifact exit codes do not collide with the ones already used "
          "(0 ok, 2 usage, 4 lock refused)",
          buildlock.ARTIFACT_ABSENT_EXIT not in (0, 2, 4)
          and buildlock.ARTIFACT_STALE_EXIT not in (0, 2, 4)
          and buildlock.ARTIFACT_ABSENT_EXIT
          != buildlock.ARTIFACT_STALE_EXIT,
          "%d / %d" % (buildlock.ARTIFACT_ABSENT_EXIT,
                       buildlock.ARTIFACT_STALE_EXIT))

    # requiresInput: an artifact whose input is absent must NOT be reported as
    # ABSENT. `.cache/global-metadata.dec.dat` is not shared between worktrees,
    # and a false refusal there would be the confidently-wrong answer.
    d = os.path.join(tmp, "units")
    os.makedirs(d, exist_ok=True)
    art = {"name": "nameidx", "src": "host/x/bin/names.idx",
           "requiresInput": {"path": ".cache/global-metadata.dec.dat",
                             "why": "not shared between worktrees"}}
    rec = buildlock.artifact_status(d, art, started=time.time())
    check("an absent artifact with an absent declared INPUT is "
          "input-missing, not absent",
          rec["state"] == "input-missing", str(rec))
    art2 = {"name": "host", "src": "host/x/bin/host.dll"}
    rec2 = buildlock.artifact_status(d, art2, started=time.time())
    check("CONTROL: the same absence with no declared input IS absent",
          rec2["state"] == "absent", str(rec2))
    check("input-missing does not make the build fail",
          buildlock.artifact_exit([rec]) == 0
          and buildlock.artifact_exit([rec2])
          == buildlock.ARTIFACT_ABSENT_EXIT,
          "%d / %d" % (buildlock.artifact_exit([rec]),
                       buildlock.artifact_exit([rec2])))
    check("input-missing PRINTS that it was NOT CHECKED",
          "NOT PERFORMED" in buildlock.artifact_lines([rec])[0]
          or "NOT CHECKED" in buildlock.artifact_lines([rec])[0],
          buildlock.artifact_lines([rec])[0])

    # Checked-in data (registry/mods.json) is shipped, not built: applying the
    # mtime rule to it would refuse every `build deploy`.
    data = os.path.join(d, "registry")
    os.makedirs(data, exist_ok=True)
    p = os.path.join(data, "mods.json")
    with open(p, "w", encoding="utf-8", newline="\n") as f:
        f.write("{}\n")
    old = time.time() - 7200
    os.utime(p, (old, old))
    rec3 = buildlock.artifact_status(d, {"name": "registry",
                                         "src": "registry/mods.json"},
                                     started=time.time())
    check("checked-in data is existence-checked only, never mtime-checked",
          rec3["state"] == "ok" and rec3["mtime_checked"] is False,
          str(rec3))
    bindir = os.path.join(d, "mods", "z", "bin")
    os.makedirs(bindir, exist_ok=True)
    q = os.path.join(bindir, "z.dll")
    with open(q, "w", encoding="utf-8", newline="\n") as f:
        f.write("x\n")
    os.utime(q, (old, old))
    rec4 = buildlock.artifact_status(d, {"name": "z", "src": "mods/z/bin/z.dll"},
                                     started=time.time())
    check("CONTROL: an old file UNDER bin/ is stale",
          rec4["state"] == "stale", str(rec4))


# ---------------------------------------------------------------------------
# the nimlint pre-flight, and reading a compiler-internal crash
# ---------------------------------------------------------------------------

BAD_SHIM = ('import aowlspt/jsonpath\n'
            'export jsonpath\n')

GETORQUIT = "getOrQuit: missing key"
CRASH_TAG = "COMPILER-INTERNAL CRASH (no file named)"


def make_lint_repo(tmp, name, bad=False):
    """A throwaway checkout with all five nimlint roots present.

    All five, deliberately: a repo missing four of them scans INCONCLUSIVE,
    and a pre-flight test run against an inconclusive scan would pass without
    the linter ever having had an opinion.
    """
    repo = os.path.join(tmp, name)
    for r in ("host/common", "aowl/src", "mods/x", "backend", "tools"):
        os.makedirs(os.path.join(repo, *r.split("/")), exist_ok=True)
    with open(os.path.join(repo, "aowl", "src", "ok.nim"), "w",
              encoding="utf-8", newline="\n") as f:
        f.write("import aowlspt/abi\nexport rawRead, rawWrite\n")
    p = os.path.join(repo, "host", "common", "jsonpath.nim")
    with open(p, "w", encoding="utf-8", newline="\n") as f:
        f.write(BAD_SHIM if bad else "proc pathGet*(s: string): string = s\n")
    return repo, p


def make_output_driver(repo, text, rc=1):
    """A stand-in `aowl` that prints chosen text and exits with a chosen code.

    This is how the crash signature is tested without a compiler: the thing
    under test is buildlock READING build output, so the output is the input.
    """
    bin_dir = os.path.join(repo, "installer", "build")
    os.makedirs(bin_dir, exist_ok=True)
    exe = os.path.join(bin_dir, "aowl.exe")
    shutil.copy(sys.executable, exe)
    script = os.path.join(repo, "build")
    with open(script, "w", encoding="utf-8", newline="\n") as f:
        f.write("import sys\n"
                "sys.stdout.write(%r)\n"
                "sys.exit(%d)\n" % (text, rc))
    probe = subprocess.run([exe, "-c", "print('ok')"],
                           capture_output=True, text=True)
    if probe.returncode != 0 or "ok" not in probe.stdout:
        return None
    return exe


def bl(repo, *args, timeout=180):
    r = subprocess.run([sys.executable, BL, "--repo", guard_repo(repo)] + list(args),
                       capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout + r.stderr


def test_nimlint_units(tmp):
    """nimlint's own controls, plus the three-state verdict.

    The selftest is run as a SUBPROCESS on purpose: `--selftest` is what a
    human or a hook will actually run, and an in-process call would not catch
    a broken CLI.
    """
    print("\nnimlint: controls and verdict")
    import nimlint

    rc = subprocess.run([sys.executable,
                         os.path.join(HERE, "nimlint.py"), "--selftest"],
                        capture_output=True, text=True, timeout=120)
    check("nimlint --selftest passes (positive controls FIRE, negatives do "
          "not)", rc.returncode == 0, rc.stdout[-800:] + rc.stderr[-400:])

    fx = nimlint.fixture_dir(REPO)
    pos = nimlint.scan([os.path.join(fx, "bad_reexport")], repo=REPO,
                       skip_fixtures=False)
    check("the positive control is exactly ONE error, at the export line",
          len(pos.errors) == 1 and pos.errors[0].line == 10,
          str([(f.rel, f.line) for f in pos.findings]))
    check("and its refusal text names the incident, not just the rule",
          "2.5h" in pos.errors[0].human() and
          "getOrQuit: missing key" in pos.errors[0].human(),
          pos.errors[0].human()[:200])

    neg = nimlint.scan([os.path.join(fx, "good")], repo=REPO,
                       skip_fixtures=False)
    check("the negative control is silent at EVERY severity",
          neg.files >= 4 and not neg.findings,
          "%d files, %s" % (neg.files,
                            [(f.rel, f.line) for f in neg.findings]))

    # The real checkout: this must be clean of ERRORS, or the linter is
    # asserting that a tree which builds today cannot be built.
    real = nimlint.scan(list(nimlint.DEFAULT_ROOTS), repo=REPO)
    check("the REAL checkout has 0 errors (it builds, so it must)",
          not real.errors,
          str([(f.rel, f.line, f.pattern["id"]) for f in real.errors]))
    check("...and >200 files were actually examined (a scan of nothing is "
          "not a clean scan)", real.files > 200, "%d files" % real.files)
    check("the three known whole-module re-exports are reported as WARNINGS, "
          "not errors", len(real.warnings) == 3,
          str([(f.rel, f.line) for f in real.warnings]))
    check("--strict would make those warnings fail, plain would not",
          nimlint.verdict(real) == 0 and nimlint.verdict(real, True) == 1,
          "%d / %d" % (nimlint.verdict(real),
                       nimlint.verdict(real, True)))

    gone = nimlint.scan(["no-such-root-here"], repo=REPO)
    check("a root that does not exist is INCONCLUSIVE (exit 3), not clean",
          nimlint.verdict(gone) == 3 and gone.could_not_scan,
          str(gone.missing_roots))

    # A finding must outrank an incomplete scan, or a real finding could be
    # waved through as "could not look".
    mixed = nimlint.scan([os.path.join(fx, "bad_reexport"), "no-such-root"],
                         repo=REPO, skip_fixtures=False)
    check("a finding OUTRANKS an incomplete scan (1, not 3)",
          nimlint.verdict(mixed) == 1,
          "verdict %d" % nimlint.verdict(mixed))

    # The strongest check available without a compiler: the REAL file, both
    # sides of the real fix. A reduced fixture can be reduced until it matches
    # whatever the linter happens to do; these two blobs cannot.
    hist = os.path.join(tmp, "hist", "host", "common")
    os.makedirs(hist, exist_ok=True)
    got = {}
    for sha, tag in (("531498a", "broken"), ("cb9a816", "fixed")):
        r = subprocess.run(["git", "show",
                            "%s:host/common/jsonpath.nim" % sha],
                           cwd=REPO, capture_output=True, text=True,
                           timeout=60)
        if r.returncode != 0:
            got[tag] = None
            continue
        with open(os.path.join(hist, "jsonpath.nim"), "w",
                  encoding="utf-8", newline="\n") as f:
            f.write(r.stdout)
        got[tag] = nimlint.scan(["host"], repo=os.path.join(tmp, "hist"))
    if got.get("broken") is None or got.get("fixed") is None:
        check("INCONCLUSIVE: git would not produce the historical blobs, so "
              "the real-file regression was NOT CHECKED", False, str(got))
    else:
        check("the REAL broken file (531498a, the 2.5h one) is caught -- "
              "through 45 lines of prose that mention import and export",
              len(got["broken"].errors) == 1
              and got["broken"].errors[0].line == 46,
              str([(f.line, f.pattern["id"])
                   for f in got["broken"].findings]))
        check("the REAL fixed file (cb9a816, which built) is SILENT",
              not got["fixed"].findings,
              str([(f.line, f.pattern["id"]) for f in got["fixed"].findings]))

    # The stripper. These are the false positives that would get the tool
    # switched off within a day.
    code, nocode, starts = nimlint.strip_noncode(
        ['import a/b', '# export b', 'export b  # trailing', 's = "export b"'])
    check("strip_noncode keeps code and drops comments/strings",
          "export" not in code[1] and code[2].strip() == "export b"
          and "export" not in code[3],
          repr(code))
    check("...and the strings-kept variant still has the literal (imports "
          "need it)", 'export b' in nocode[3], repr(nocode))


def test_lint_preflight(tmp):
    """A tree holding the measured fatal shape refuses BEFORE the lock.

    The properties, and each is separately falsifiable:
      * exit 7, and the finding is printed
      * NO lock file was created and NO build ran -- refusing after taking the
        slot would still cost the queue four minutes
      * the CONTROL (same repo, shape removed) does build
      * --no-lint really is an escape
    """
    print("\nlint pre-flight: refuse before the lock")
    repo, badfile = make_lint_repo(tmp, "lint-bad", bad=True)
    exe = make_output_driver(repo, "should never run\n", rc=0)
    if exe is None:
        check("INCONCLUSIVE: no runnable stand-in driver, nothing was tested",
              False, "the copied python.exe would not start")
        return

    rc, out = bl(repo, "build", "host")
    check("a tree with the fatal shape REFUSES with exit 7",
          rc == buildlock.LINT_EXIT, "exit %d\n%s" % (rc, out[-600:]))
    check("...and the refusal names file, line and the fix",
          "host/common/jsonpath.nim:2" in out.replace("\\", "/")
          and "module-reexport-samename" in out and "fix:" in out,
          out[-800:])
    check("...and it says nothing was built and no lock was taken",
          "no lock was taken" in out, out[-300:])
    check("NO LOCK FILE was created (it refused before acquiring)",
          not os.path.exists(buildlock.lock_path(repo)),
          buildlock.lock_path(repo))
    check("the build command never ran", "should never run" not in out,
          out[-300:])

    rc2, out2 = bl(repo, "--no-lint", "build", "host")
    check("--no-lint is a real escape (the build runs)",
          "should never run" in out2, "exit %d\n%s" % (rc2, out2[-400:]))

    # CONTROL. Same repo, same driver, shape removed -- if this also refused,
    # the test above would be proving nothing about the shape.
    with open(badfile, "w", encoding="utf-8", newline="\n") as f:
        f.write("proc pathGet*(s: string): string = s\n")
    rc3, out3 = bl(repo, "build", "host")
    check("CONTROL: with the two lines removed the SAME repo builds",
          rc3 != buildlock.LINT_EXIT and "should never run" in out3,
          "exit %d\n%s" % (rc3, out3[-400:]))

    # And the warning severity must not block, or the real checkout (which has
    # three of them) could never be built through the lock.
    with open(os.path.join(repo, "mods", "x", "reex.nim"), "w",
              encoding="utf-8", newline="\n") as f:
        f.write("import aowlspt/abi\nexport abi\n")
    rc4, out4 = bl(repo, "build", "host")
    check("a WARNING does not refuse by default",
          rc4 != buildlock.LINT_EXIT and "should never run" in out4,
          "exit %d\n%s" % (rc4, out4[-400:]))
    rc5, out5 = bl(repo, "--lint-strict", "build", "host")
    check("--lint-strict makes that same warning refuse",
          rc5 == buildlock.LINT_EXIT, "exit %d\n%s" % (rc5, out5[-400:]))


def test_internal_crash_units(tmp):
    """`internal_crash_verdict` on the four shapes that matter."""
    print("\ncompiler-internal crash: the verdict function")
    known = {"aowlhost.nim", "uihooks.nim"}

    ev = buildlock.internal_crash_verdict(
        "building host\n" + GETORQUIT + "\n", known=known)
    check("`getOrQuit: missing key` IS an internal crash",
          ev["crash"] and GETORQUIT in ev["markers"], str(ev))

    ev2 = buildlock.internal_crash_verdict(
        "aowlhost.nim(2051, 5) Error: undeclared identifier: 'pathGet'\n",
        known=known)
    check("an ordinary error that NAMES a file is NOT an internal crash",
          not ev2["crash"] and ev2["located"], str(ev2))

    ev3 = buildlock.internal_crash_verdict(
        "unhandled exception: nifcursors.nim(149) `c.p != nil and c.rem > 0`\n",
        known=known)
    check("a fatal whose only location is INSIDE THE COMPILER is an internal "
          "crash", ev3["crash"] and ev3["foreign"] and not ev3["located"],
          str(ev3))

    ev4 = buildlock.internal_crash_verdict(
        "link failed: LNK1120 unresolved externals\n", known=known)
    check("an ordinary failure with no location and no fatal marker is NOT "
          "one (this is the check that stops it firing on everything)",
          not ev4["crash"], str(ev4))

    # Even alongside a real located error, getOrQuit still wins: it is the
    # measured signature and it never carries a location of its own.
    ev5 = buildlock.internal_crash_verdict(
        "aowlhost.nim(1, 1) Error: x\n" + GETORQUIT + "\n", known=known)
    check("getOrQuit outranks a co-printed located error", ev5["crash"],
          str(ev5))


def test_internal_crash_report(tmp):
    """End to end, through the CLI, with a driver that emits the signature."""
    print("\ncompiler-internal crash: the report, end to end")
    repo, _ = make_lint_repo(tmp, "crash-repo", bad=False)
    exe = make_output_driver(repo, "compiling...\n" + GETORQUIT + "\n", rc=1)
    if exe is None:
        check("INCONCLUSIVE: no runnable stand-in driver, nothing was tested",
              False, "the copied python.exe would not start")
        return

    rc, out = bl(repo, "build", "host")
    check("the signature produces the DISTINCT line, not a plain failure",
          CRASH_TAG in out, "exit %d\n%s" % (rc, out[-800:]))
    check("...and the exact wording tells the reader what to run and what it "
          "cost", buildlock.CRASH_LINE in out, out[-800:])
    check("...and exit 8, distinct from the child's own code",
          rc == buildlock.INTERNAL_CRASH_EXIT, "exit %d" % rc)
    check("the build's own output still reached stdout (the tee did not eat "
          "it)", "compiling..." in out, out[-400:])
    check("nimlint's verdict on the tree is reported alongside",
          "nimlint" in out, out[-600:])
    check("...and because this repo is lint-clean it SAYS the shape is new "
          "rather than staying quiet",
          "does not know yet" in out, out[-600:])

    # CONTROL: an ordinary compile error must NOT be dressed up as this.
    make_output_driver(repo,
                       "host/x.nim(12, 3) Error: undeclared identifier: 'q'\n",
                       rc=1)
    rc2, out2 = bl(repo, "build", "host")
    check("CONTROL: an ordinary error that names a file gets NO crash line",
          CRASH_TAG not in out2, out2[-500:])
    check("...and forwards the child's exit code (1), not 8",
          rc2 == 1, "exit %d" % rc2)

    # CONTROL: a SUCCESSFUL build that happens to print the words is not a
    # crash -- the scan only runs on failure, and a passing build must not be
    # turned into one.
    make_output_driver(repo, "note: %s appeared once\n" % GETORQUIT, rc=0)
    rc3, out3 = bl(repo, "--no-artifact-check", "build", "host")
    check("CONTROL: a build that exits 0 is never called a crash",
          CRASH_TAG not in out3 and rc3 == 0, "exit %d\n%s" % (rc3, out3[-400:]))


GEN_REL = "abi/aowlspt_symtab.nim"


def _declare_generated(repo, entries):
    """Add `generatedSources` to a temp repo's deploy.json, in place."""
    p = os.path.join(repo, "tools", "deploy.json")
    with open(p, "r", encoding="utf-8") as f:
        cfg = json.load(f)
    cfg["generatedSources"] = [{"path": e, "why": "written by the build"}
                               for e in entries]
    with open(p, "w", encoding="utf-8", newline="\n") as f:
        json.dump(cfg, f)


def _plant_generated(repo, rel=GEN_REL, age=1.0):
    """A file the BUILD WRITES, sitting in a source root, NEWER than the
    artifact. This is the exact shape of the false positive."""
    p = os.path.join(repo, rel.replace("/", os.sep))
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w", encoding="utf-8", newline="\n") as f:
        f.write("# generated by il2cpp_symtab.py gen\n")
    mt = time.time() - age
    os.utime(p, (mt, mt))
    return p


def test_generated_is_not_a_source(tmp):
    """MEASURED 2026-09-02: two consecutive no-op `build host` runs exited 6
    ARTIFACT STALE naming `abi/aowlspt_symtab.nim` as modified after the
    artifact -- while the artifact was correct and matched its sidecar. That
    file is REGENERATED BY EVERY BUILD (symTab() in tools/aowl.nim), so it is
    newer than an unrewritten artifact every single time: a refusal that could
    not stop firing.

    Three worlds, one command, and the exclusion is the ONLY difference
    between the first two:

      (a) only the GENERATED file is newer, and it is declared  -> UP-TO-DATE;
      (b) a real SOURCE is newer                                -> exit 6;
      (c) the same generated file, NOT declared                 -> exit 6.

    (c) is the one that makes (a) mean something. Without it, "exit 0" in (a)
    could come from the scan never noticing the file at all.
    """
    print("\ngenerated sources: a build output is not an input")

    repo, art = make_artifact_repo(tmp, "gen-uptodate", writes=False,
                                   remove=False, rc=0)
    if repo is None:
        check("INCONCLUSIVE: the stand-in driver would not run", False)
        return
    _plant_prebuilt(repo, art)                 # artifact 1h old, source 2h old
    _plant_generated(repo)                     # generated file 1s old
    _declare_generated(repo, [GEN_REL])
    rc, out = build_in(repo, "build", "host")
    check("a no-op rebuild whose only newer file is GENERATED exits 0",
          rc == 0, "rc=%d\n%s" % (rc, out[-1200:]))
    check("...and says UP-TO-DATE, not ARTIFACT STALE",
          "UP-TO-DATE" in out and "ARTIFACT STALE" not in out, out[-1200:])
    check("...and PRINTS which file it excluded and why",
          "excluded from the staleness scan" in out and GEN_REL in out,
          out[-1200:])

    # (b) THE FALSIFIER. Same repo shape, same declaration, but the newer file
    # is a real source. If this passed, the fix would have disabled the check.
    repo2, art2 = make_artifact_repo(tmp, "gen-real-source", writes=False,
                                     remove=False, rc=0)
    if repo2 is None:
        check("INCONCLUSIVE: the stand-in driver would not run (b)", False)
        return
    _plant_prebuilt(repo2, art2, src_age=30.0)   # aowlhost.nim is newer
    _plant_generated(repo2)
    _declare_generated(repo2, [GEN_REL])
    rc2, out2 = build_in(repo2, "build", "host")
    check("a REAL source newer than the artifact is still exit 6",
          rc2 == buildlock.ARTIFACT_STALE_EXIT,
          "rc=%d\n%s" % (rc2, out2[-1200:]))
    check("...and names the source, not the generated file",
          "aowlhost.nim" in out2, out2[-1200:])

    # (c) CONTROL FOR THE EXCLUSION ITSELF: identical to (a) except that the
    # generated file is not declared.
    repo3, art3 = make_artifact_repo(tmp, "gen-undeclared", writes=False,
                                     remove=False, rc=0)
    if repo3 is None:
        check("INCONCLUSIVE: the stand-in driver would not run (c)", False)
        return
    _plant_prebuilt(repo3, art3)
    _plant_generated(repo3)
    rc3, out3 = build_in(repo3, "build", "host")
    check("CONTROL: the same file UNDECLARED still refuses (exit 6)",
          rc3 == buildlock.ARTIFACT_STALE_EXIT,
          "rc=%d\n%s" % (rc3, out3[-1200:]))
    check("...so (a) passed because of the exclusion, nothing else",
          "aowlspt_symtab.nim" in out3, out3[-1200:])

    # A temp repo has no tools/aowl.nim, so the cross-check CANNOT run there.
    # It must say so rather than reporting a clean list.
    check("a repo with no tools/aowl.nim says the cross-check was NOT "
          "PERFORMED", "NOT PERFORMED" in out, out[-1200:])

    # And the unit, against the REAL checkout (read-only): the file from the
    # incident is declared, and aowl.nim names no generated output that
    # deploy.json has forgotten.
    gen, notes = buildlock.generated_sources(REPO)
    check("the real deploy.json declares abi/aowlspt_symtab.nim as generated",
          GEN_REL in gen, sorted(gen))
    check("...and tools/aowl.nim writes nothing else undeclared", not notes,
          "; ".join(notes))


DL = os.path.join(HERE, "deploylock.py")


def dl(repo, *args, **kw):
    r = subprocess.run([sys.executable, DL, "--repo", guard_repo(repo)]
                       + list(args), capture_output=True, text=True,
                       timeout=kw.get("timeout", 180))
    return r.returncode, r.stdout + r.stderr


def test_markers_under_lock(tmp):
    """MEASURED 2026-09-02: `markers.py <host dll>` answered INCONCLUSIVE "no
    such file" because a concurrent build had already removed the artifact
    (`aowl` deletes its output before writing it).

    `deploylock.py markers` closes that window -- but the interesting property
    is the one that keeps it cheap: it must take the build lock ONLY for a
    path this checkout builds. Both halves are asserted against the SAME held
    lock, so "it queued" and "it did not queue" are produced by the target
    path alone.
    """
    print("\ndeploylock markers: a marker check that cannot race a build")
    repo, art = make_artifact_repo(tmp, "markers-lock", writes=False,
                                   remove=False, rc=0)
    if repo is None:
        check("INCONCLUSIVE: the stand-in driver would not run", False)
        return
    os.makedirs(os.path.dirname(art), exist_ok=True)
    with open(art, "w", encoding="utf-8", newline="\n") as f:
        f.write("hello marker here\n")
    outside = os.path.join(tmp, "markers-lock-outside.dll")
    with open(outside, "w", encoding="utf-8", newline="\n") as f:
        f.write("hello marker here\n")

    # FREE LOCK first: prove the locked path actually runs the check, or the
    # refusal below would be the only thing ever observed.
    rc0, out0 = dl(repo, "markers", art, "--string", "hello marker")
    check("with the lock free, a declared artifact is checked under the lock",
          rc0 == 0 and "build lock ACQUIRED for markers" in out0
          and "PRESENT" in out0, "rc=%d\n%s" % (rc0, out0[-900:]))

    holder = plant_holder(buildlock.lock_path(repo))
    try:
        t0 = time.time()
        rc1, out1 = dl(repo, "--wait", "4", "markers", art,
                       "--string", "hello marker")
        waited = time.time() - t0
        check("a HELD lock makes the declared artifact's check QUEUE and then "
              "refuse (exit 4)", rc1 == 4, "rc=%d\n%s" % (rc1, out1[-900:]))
        # markers.py ends every real run with a `verdict:` line. Its absence is
        # the property that matters -- the refusal text itself contains the
        # words MISSING and PRESENT (it says it is neither), so searching for
        # those would fail on the message that makes the point.
        check("...and it says NOTHING WAS CHECKED rather than a verdict",
              "NOTHING WAS CHECKED" in out1 and "verdict:" not in out1,
              out1[-900:])
        check("...and it really waited (%.1fs >= 4s)" % waited, waited >= 3.5,
              "it returned in %.1fs -- it did not queue" % waited)

        # THE CONTROL, against the same held lock: a path this checkout does
        # not build needs no lock and must not wait for one.
        t1 = time.time()
        rc2, out2 = dl(repo, "--wait", "60", "markers", outside,
                       "--string", "hello marker")
        quick = time.time() - t1
        check("CONTROL: an UNDECLARED path is checked immediately, lock held",
              rc2 == 0 and "NO BUILD LOCK TAKEN" in out2 and "PRESENT" in out2,
              "rc=%d\n%s" % (rc2, out2[-900:]))
        check("...and it did not wait for the lock (%.1fs)" % quick,
              quick < 20.0, "it took %.1fs with --wait 60" % quick)
    finally:
        holder.kill()
        try:
            os.unlink(buildlock.lock_path(repo))
        except OSError:
            pass

    # Units: the decision itself, without running anything.
    import deploylock  # noqa: E402
    need_a, _ = deploylock.markers_needs_lock(repo, [art, "--string", "x"])
    need_b, _ = deploylock.markers_needs_lock(repo, [outside, "--string", "x"])
    need_c, why_c = deploylock.markers_needs_lock(repo, ["--list-artifacts"])
    need_d, why_d = deploylock.markers_needs_lock(repo, ["--string", "x"])
    check("needs_lock: declared yes / undeclared no / no-read no",
          need_a and not need_b and not need_c,
          "%r %r %r (%s)" % (need_a, need_b, need_c, why_c))
    check("needs_lock: an INDETERMINATE target locks rather than guessing",
          need_d, why_d)
    p, _why = deploylock.markers_targets(repo, ["--string", art, outside])
    check("a --string VALUE that looks like a path is not read as the target",
          p == [os.path.abspath(outside)], str(p))


def preflight_sandbox():
    """Before anything runs: prove the guard exists AND that it can fire.

    A guard nobody can falsify is the defect this suite is full of warnings
    about, so the FIRST thing checked is that pointing buildlock at the real
    checkout RAISES, and the second is that a temp repo is NOT refused -- a
    guard that refuses everything would pass the first check and quietly break
    every test below.
    """
    print("sandbox guard")
    fired = False
    try:
        guard_repo(REPO)
    except SandboxViolation:
        fired = True
    check("guard/fires: aiming a test at the REAL checkout is refused", fired,
          "guard_repo(%s) returned instead of raising" % REPO)
    fired2 = False
    try:
        buildlock.lock_path(REPO)
    except SandboxViolation:
        fired2 = True
    check("guard/fires: buildlock.lock_path(REAL) is refused too", fired2)
    with tempfile.TemporaryDirectory() as td:
        ok = True
        try:
            guard_repo(td)
            buildlock.lock_path(td)
        except SandboxViolation:
            ok = False
        check("guard/does-not-fire-on-a-temp-repo (or it proves nothing)", ok)
    return (os.path.exists(REAL_LOCK),
            os.path.getmtime(REAL_LOCK) if os.path.exists(REAL_LOCK) else None)


NO_AUDITS = ["--no-lint", "--no-drain-audit", "--no-gate-audit",
             "--no-seh-audit", "--no-flag-audit", "--no-store-audit",
             "--no-snapshot", "--no-source-check", "--no-artifact-check",
             "--no-stage"]


def test_no_driver(tmp):
    """A worktree with NO installer\\build\\aowl.exe must get a verdict, not a
    traceback.

    MEASURED 2026-09-04: `python tools/buildlock.py bootstrap` in a fresh
    worktree (installer/build is gitignored, so that is its NORMAL state) died
    with FileNotFoundError [WinError 2] from subprocess.Popen -- `aowl_exe`
    had fallen back to the bare name "aowl", which is on nobody's PATH. The
    verb whose whole job is to CREATE the driver was the one that needed it.

    Three worlds, and the third is the one that keeps the second honest:
      (a) driver present            -> run it, unchanged;
      (b) absent + `bootstrap`      -> run tools\\bootstrap.ps1 (needs no
                                       driver), under the lock;
      (c) absent + any other target -> REFUSE with an exit code, naming
                                       bootstrap. Not a traceback, and not a
                                       silent guess at PATH.
    """
    print("\nno driver: bootstrap must not need the thing it builds")
    repo = os.path.join(tmp, "nodriver")
    os.makedirs(os.path.join(repo, "installer", "build"), exist_ok=True)
    os.makedirs(os.path.join(repo, "tools"), exist_ok=True)
    ps1 = os.path.join(repo, "tools", "bootstrap.ps1")
    with open(ps1, "w", newline="\n") as f:
        f.write("exit 0\n")

    # PATH is emptied for the units so that a real `aowl` on this machine
    # cannot make (c) pass for the wrong reason.
    saved = os.environ.get("PATH", "")
    try:
        os.environ["PATH"] = ""
        cmd, why, rc = buildlock.resolve_command(repo, ["bootstrap"])
        check("no aowl.exe + bootstrap -> runs tools\\bootstrap.ps1",
              cmd is not None and rc == 0
              and any(str(x).endswith("bootstrap.ps1") for x in cmd),
              "cmd=%r rc=%r" % (cmd, rc))
        check("...and says so rather than pretending a driver ran",
              "bootstrap.ps1" in why, repr(why))

        cmd, why, rc = buildlock.resolve_command(repo, ["build", "host"])
        check("no aowl.exe + `build host` -> REFUSED with an exit code",
              cmd is None and rc == buildlock.NO_DRIVER_EXIT,
              "cmd=%r rc=%r" % (cmd, rc))
        check("...and the refusal names the fix (bootstrap)",
              "bootstrap" in (why or ""), repr(why))

        # (a): the positive control. Without it, (b) and (c) could both be
        # passing because resolve_command never finds anything.
        exe = os.path.join(repo, "installer", "build", "aowl.exe")
        with open(exe, "wb") as f:
            f.write(b"MZ")
        cmd, _why, rc = buildlock.resolve_command(repo, ["build", "host"])
        check("driver present -> it is what runs (positive control)",
              cmd is not None and rc == 0 and cmd[0] == exe
              and cmd[1:] == ["build", "host"], "cmd=%r" % (cmd,))
        os.remove(exe)
    finally:
        os.environ["PATH"] = saved

    # End to end, which is where the traceback actually appeared.
    rc, out = build_in(repo, *(NO_AUDITS + ["build", "host"]))
    check("end to end: no traceback from a driverless checkout",
          "Traceback (most recent call last)" not in out, out[-400:])
    check("end to end: exit %d (NO DRIVER), not 0" % buildlock.NO_DRIVER_EXIT,
          rc == buildlock.NO_DRIVER_EXIT, "exit %d: %s" % (rc, out[-400:]))


def main():
    t_suite = time.time()
    before_lock = preflight_sandbox()
    print("")
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

        print("\nrelease window: B arrives the instant the holder lets go")
        rw = run_release_window("fair", tmp, "rw-fair")
        order = [r["label"] for r in rw if r["ok"]]
        print("    acquisition order: %s" % (order or "NOBODY ACQUIRED"))
        check("release window: both waiters eventually acquired",
              sorted(order) == ["A", "B"], str(order))
        check("release window: A (queued FIRST) still acquired FIRST",
              order[:1] == ["A"],
              "order was %s -- a waiter that arrived during the release "
              "window jumped an established queue entry" % order)
        if len(rw) == 2:
            gap = abs(rw[1]["at"] - rw[0]["at"])
            check("release window: the two acquisitions did not overlap",
                  gap >= 1.4, "gap was %.2fs -- BOTH RAN AT ONCE" % gap)

        print("\n    negative control for the release window")
        rw_b = 0
        rw_rounds = 3
        for i in range(rw_rounds):
            r = run_release_window("race%d" % i, tmp, "rw-race%d" % i)
            o = [x["label"] for x in r if x["ok"]]
            print("    round %d order: %s" % (i + 1, o or "NOBODY"))
            if o[:1] == ["B"]:
                rw_b += 1
        check("the old algorithm CAN lose the release-window race "
              "(%d/%d rounds)" % (rw_b, rw_rounds), rw_b > 0,
              "B never won in %d rounds -- the gate is not landing inside the "
              "window, so the fair-mode pass above is NOT evidence" % rw_rounds)

        # Timed individually. "the suite hung" and "the suite is slow" are
        # different reports, and without a per-test cost nobody can tell them
        # apart from the outside -- which is exactly what happened on
        # 2026-09-02 while a real build held the lock.
        for fn in (test_status, test_fifo_reporting, test_wait_free,
                   test_status_streams, test_forwarding, test_concurrent_edits,
                   test_snapshot_unit, test_snapshot_speed,
                   test_proc_table_real, test_hung_units, test_hung_verdicts,
                   test_hung_human_text, test_hung_across_calls,
                   test_wait_free_reports_hung, test_break_hung,
                   test_artifact_units, test_artifact_check,
                   test_stage,
                   test_source_change, test_status_you,
                   test_noop_rebuild_is_up_to_date,
                   test_generated_is_not_a_source, test_markers_under_lock,
                   test_verify_artifact,
                   test_nimlint_units, test_lint_preflight,
                   test_internal_crash_units, test_internal_crash_report,
                   test_no_driver):
            t0 = time.time()
            fn(tmp)
            TIMINGS.append((fn.__name__, time.time() - t0))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    # A property of the FINISHED STATE, not of our intentions: whatever the
    # tests did, the real checkout's lock file must be exactly as we found it.
    # This is the line that would have answered "is the suite blocked on the
    # live lock, or merely slow?" without anyone having to guess.
    after = (os.path.exists(REAL_LOCK),
             os.path.getmtime(REAL_LOCK) if os.path.exists(REAL_LOCK)
             else None)
    check("the real checkout's lock file is untouched (%s)" % REAL_LOCK,
          after[0] == before_lock[0]
          and (after[1] is None or before_lock[1] is None
               or abs(after[1] - before_lock[1]) < 0.5),
          "before=%r after=%r -- a test wrote the LIVE build lock"
          % (before_lock, after))

    if TIMINGS:
        print("\nslowest tests")
        for nm, dt in sorted(TIMINGS, key=lambda x: -x[1])[:6]:
            print("    %6.1fs  %s" % (dt, nm))

    print("\n%s -- %d failure(s) in %.1fs"
          % ("FAIL" if FAILURES else "PASS", len(FAILURES),
             time.time() - t_suite))
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
