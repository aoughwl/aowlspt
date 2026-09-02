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
    r = subprocess.run([sys.executable, BL, "--repo", repo] + list(args),
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
        [sys.executable, BL, "--repo", released, "--wait-free", "60", "--json"],
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
        r = subprocess.run([sys.executable, BL, "--repo", repo] + list(args),
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
        [sys.executable, BL, "--repo", repo, "build", "mod", "maps"],
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
        subprocess.run([sys.executable, BL, "--repo", repo2,
                        "build", "test", "mapsdiag"],
                       capture_output=True, text=True, timeout=60)
        called2 = {}
        if os.path.exists(out2):
            with open(out2, encoding="utf-8") as f:
                called2 = json.load(f)
        check("`build test mapsdiag` forwards verbatim too",
              called2.get("argv", [])[:3] == ["build", "test", "mapsdiag"],
              "argv was %r" % called2.get("argv"))


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

        test_status(tmp)
        test_fifo_reporting(tmp)
        test_wait_free(tmp)
        test_status_streams(tmp)
        test_forwarding(tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print("\n%s -- %d failure(s)"
          % ("FAIL" if FAILURES else "PASS", len(FAILURES)))
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
