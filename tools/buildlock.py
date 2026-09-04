#!/usr/bin/env python3
r"""buildlock.py -- ONE build at a time per checkout. A mechanism, not a rule.

    python tools/buildlock.py build host
    python tools/buildlock.py build examples
    python tools/buildlock.py --wait 900 build mods
    python tools/buildlock.py --status
    python tools/buildlock.py --status --json  # machine-readable; see below
    python tools/buildlock.py --wait-free 600  # block until nobody is building
    python tools/buildlock.py --steal          # only when the holder is dead
    python tools/buildlock.py --status --check-hung   # is the holder ALIVE-but-DEAD?
    python tools/buildlock.py --break-hung build host # kill a hung holder, then build
    python tools/buildlock.py verify-artifact host    # is the dll still MY build?
    python tools/buildlock.py --no-lint build host    # skip the nimlint pre-flight

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

## A holder can be RUNNING and DEAD at the same time

MEASURED TWICE on 2026-09-01 evening: `aowl build host` stopped inside
`nimony.exe` after codegen -- the last thing written was
`host\Aowlspt.Host.Il2Cpp\nimcache\*.final.build.nif` -- with nimony sitting at
~0.27s of CPU and accumulating **zero** further CPU across repeated 60s
samples, and no child compiler process at all. The third attempt of the exact
same command finished in 41s.

Every liveness answer this file had was "the pid exists", so `--status` printed
`(running)` for fifteen minutes and the queue behind it waited about twenty-
five. `pid_alive` was not wrong; it was answering a different question.

So there is a second question now, and it is deliberately a WEAK one:

    is the holder's process tree burning CPU, or writing to a nimcache?

If neither is true across a window (default 20s), the verdict is **`hung?`**,
with the question mark meant literally. It is evidence, not a diagnosis: pids,
per-process CPU deltas, and the age of the newest nimcache file are printed so
a human can disagree. Three outcomes, never two -- `working`, `hung?`, and
**`unknown`** when the process table could not be read, when the nimcache walk
was truncated, or when two samples a window apart do not yet exist. `unknown`
is never treated as `hung?`, and it RESETS the strike count, because a check
that cannot look must not be allowed to accumulate toward a kill.

Signals that count as WORKING, i.e. all the ways this refuses to cry hung:

* >= --hung-cpu (default 0.5s) of CPU accumulated across the whole tree;
* any file under any `nimcache/` in the checkout modified during the window;
* any process in the tree having EXITED during the window (a compiler
  finishing is progress, and biasing toward "working" is the safe direction --
  a false `hung?` can kill a healthy build, a false `working` only wastes the
  time this feature was written to save).

Nothing is ever killed by default. A waiter that observes `hung?` for
--hung-strikes (default 3) CONSECUTIVE windows -- a full minute of a tree doing
nothing at all -- prints what it saw and tells you to re-run with
`--break-hung`. Only with that flag does it kill the holder's process tree
(`taskkill /T /F`), log every pid and image name it killed, drop the lock file
and take it. `--steal` remains the blunt instrument for when you already know.

`--status` samples across CALLS via a small state file (`.aowl-build.hung.json`
beside the lock) rather than blocking for a window, so it stays instant; the
first call says "sampling started, no verdict yet" and the next call after the
window returns one. `--status --check-hung` blocks and takes both samples
itself when you want an answer now. Checking is skipped entirely for a holder
younger than --hung-after (default 120s), because a two-minute build has not
hung yet and the check is not free.

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

## Whose bug is it? The working-tree snapshot

MEASURED 2026-09-01: `python tools/buildlock.py build host` failed with
`modsindex.nim(399): undeclared identifier: 'ntKeyCodeName'` in a file the
building agent had never touched. Another agent had created an untracked
`host/Aowlspt.Host.Il2Cpp/keycodes.nim` in the shared checkout *while the build
ran*, so a half-written change compiled into someone else's build. The error
read as the builder's own bug and cost a round trip to disprove.

The lock serialises BUILDS. It cannot serialise EDITS -- agents write source
into the same checkout at any time, and nothing here should stop them. What it
can do is stop the resulting failure from being anonymous. So the working tree
is snapshotted (`git status --porcelain` paths + statuses + mtimes, and
`git rev-parse HEAD`) at ACQUIRE and again at EXIT, and on a NON-ZERO exit the
difference is printed.

Two rules it follows, both from CLAUDE.md 9b:

* **Only on failure, and never a verdict.** A successful build prints nothing
  extra; a failed one prints evidence, not a diagnosis. Ownership is genuinely
  unknowable from here -- this process cannot tell which agent wrote a file --
  so the block lists what moved and says the failure is *likely* somebody
  else's, rather than asserting it.
* **A snapshot that could not be taken says so.** If `git` is missing, slow or
  errors, the block prints that the comparison was NOT PERFORMED. Silence
  would read exactly like "nothing changed", which is the confidently-wrong
  answer this whole file exists to avoid.

## A build's exit 0 is not the artifact's existence -- measured 2026-09-02

FIVE times in one evening. `aowl build host` REMOVES
`host/Aowlspt.Host.Il2Cpp/bin/aowlspt-host-il2cpp.dll` before it writes it.
Agent A's build finished (exit 0, artifact present) and A began verifying;
queued agent B's build then took the lock, removed the artifact, hit a compile
error and produced nothing. A's verification read an ABSENT dll -- and this
script had already told A `ok`, about a file that no longer existed. Separately,
a build that exits 0 with its declared artifact never written has been reported
as success outright.

The lock cannot fix that: the deletion happens after the first build's lock is
released, and serialising VERIFICATION would mean holding the build slot while
somebody reads a DLL. What it can do is refuse to lie:

* After a successful build the target's declared artifact(s) are resolved from
  `tools/deploy.json` -- the same `src` fields `aowl`'s `buildDeploySet` maps
  onto build steps, so there is no second list of paths here to rot -- and each
  one is checked. **`BUILT BUT ARTIFACT ABSENT` exits 5**; **`ARTIFACT STALE
  (mtime before build start)` exits 6**, which is the earlier build's leftover
  file. The staleness rule applies only to build OUTPUTS: `registry/mods.json`
  is checked-in data that no build rewrites, and failing on its mtime would be
  a check that always fires. A target that declares no artifact in deploy.json
  (`build sim`, `build test X`) prints **ARTIFACT CHECK NOT PERFORMED** and does
  not pass silently; so does an artifact whose `requiresInput` is absent.
* On success each artifact's path, size and sha256 are printed, and the same
  is written to `<artifact>.built.json` (target, sha256, size, mtime, started,
  finished, pid, git_head). It exists so a verifier minutes later can PROVE the
  bytes it is reading are the build it thinks it is.
* `python tools/buildlock.py verify-artifact <target>` compares the file
  against that sidecar: **MATCH 0 / REPLACED 2 / ABSENT 3 / NO SIDECAR 5**.
  REPLACED names the pid and finish time recorded for the bytes that are there
  now. Pass `--expect <sha256>` (the sha printed by your own build) to ask the
  sharper question -- *is this still MY build* -- because a later build
  overwrites the sidecar too, so sidecar-vs-file agreeing only proves the file
  and the record are consistent, not that they are yours.

## A failure that names no file is not an ordinary failure -- 2026-09-01

From 19:49 to 22:26 every host and backend build died inside nimony's hexer
with `getOrQuit: missing key` and no file, no line, no symbol. The session read
"build failed", assumed its own edits, and spent 2.5 hours bisecting. The cause
was two lines (`import aowlspt/jsonpath` + `export jsonpath`) that a 200ms grep
finds. So:

* **Pre-flight.** `tools/nimlint.py` scans the tree BEFORE the lock is taken.
  A finding refuses with **exit 7**, prints the finding, builds nothing and
  queues for nothing. `--no-lint` is the escape; `--lint-strict` also refuses
  on warnings. If nimlint cannot be imported or cannot scan, the pre-flight
  says **NOT PERFORMED / INCONCLUSIVE** and builds anyway -- a missing linter
  must not block work, and must never read as a clean lint.
* **The offline invariants.** In the same place and for the same reason, four
  checks that the compiler cannot make: `drainaudit.py` (D1/D2 postfix slots,
  D4 sharedness, D5 a function detoured twice) -> **exit 9**, `gateaudit.py`
  (X1, a token-gated il2cpp export bound or called outside `aowl_gate_call`)
  -> **exit 11**, `sehnest.py` (D8, a nested `aowl_p_p_seh`) -> **exit 12**,
  `flagaudit.py` (D10, a feature flag defaulting ON with no allowlisted
  reason) -> **exit 13**. Each refusal names the invariant and the first
  file:line. Each has its own `--no-*-audit`. INCONCLUSIVE never refuses and
  never reads as a pass: it prints NOT PERFORMED and builds anyway.
* **Post-mortem.** The build's output is tee'd (every byte still reaches
  stdout) and, on failure, scanned. `getOrQuit: missing key`, or any compiler
  fatal whose only printed locations are inside the compiler's own sources,
  prints `COMPILER-INTERNAL CRASH (no file named)` and **exit 8** instead of
  the child's code -- and runs nimlint, saying plainly when nimlint is CLEAN,
  because a clean lint after that signature means the shape is a NEW one.

## The bytes still vanish AFTER the lock is released -- measured 2026-09-04

08:58: a clean `build host` finished (exit 0, sidecar written, sha recorded).
Before `deploylock.py deploy host` copied it, another agent's queued
`build host` acquired the lock and `aowl` -- which REMOVES its output before
writing it -- deleted the artifact. The deploy refused with "the artifact is
not the build that was recorded", which was correct, and the launcher ran the
OLD host DLL. With several agents building in one checkout this is the normal
case, not an exotic one, and no lock can fix it: the deletion happens after the
first build's lock has been released.

So a proven artifact is COPIED where no build writes:

    .stage/<target>/<sha256[:12]>/<basename>  + its sidecar + stage.json

printed on the success line, six kept per artifact, older pruned.
`tools/deploy.py` deploys FROM the stage (`--sha PREFIX`, else the newest
stage that is not `stale_sources` and whose markers all pass), so a running
build cannot remove the file mid-copy. `--status` lists the stages; so does
`deploy.py stages [NAME]`. `--no-stage` opts out and says so.

The stage is not a second opinion about whether a build was good: the sidecar
sha, `stale_sources` and the deploy.json marker list are all applied to the
staged bytes exactly as they were applied to `bin/`. It only removes the window
in which the file can disappear.

## A build whose SOURCES moved under it -- measured 2026-09-03 19:24

`buildlock.py build host` reported success (exit 0, sidecar written) for a
build whose sources were edited AFTER the lock was acquired: source mtimes
19:24, lock acquired 19:22:39. The DLL was a PRE-EDIT snapshot and `grep -a`
found ZERO of the seven literals the edit had added -- so the marker check that
followed measured the wrong file, confidently.

The lock cannot serialise EDITS and should not try. It can refuse to call that
a success. The newest source mtime under the artifact's declared source roots
(the SAME roots and the SAME generated-file exclusions the UP-TO-DATE/STALE
logic uses -- one walker, so they cannot drift) is recorded at acquire and
again at build exit. Anything newer than the acquire instant prints
`SOURCES CHANGED DURING THE BUILD` with the files and their mtimes, marks the
sidecar `stale_sources: true`, and exits **15**. `deploy.py` refuses a sidecar
carrying that flag, so the bytes cannot reach the live install by another
route. `--no-source-check` turns it off.

Three states, never two: a scan that was truncated, errored, or whose roots
could not be derived prints `SOURCE-CHANGE CHECK NOT PERFORMED`, records
`source_check: "not-performed"` in the sidecar and does NOT refuse -- it must
not block a build that is fine, and it must not read as a clean bill either.

Exit codes now: 0 ok, 2 usage, 4 lock not acquired, 5 artifact absent, 6
artifact stale, 7 lint refusal, 8 compiler-internal crash, 15 sources changed
during the build, otherwise the child's own code.
"""

from __future__ import annotations

import argparse
import errno
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
if HERE not in sys.path:
    sys.path.insert(0, HERE)
import stage as stagemod                                        # noqa: E402

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


def you_state(held, q, pids):
    """Where the CALLER stands: holding, queued at position K, or neither.

    Two agents asked for this on 2026-09-03 for the same reason: `--status`
    described the world without saying where the reader is in it, so "pid 12345
    is building" had to be compared by hand against a pid the reader often did
    not have. Three outcomes, and `not-in-queue` is said in as many words --
    silence there reads as "queued", which is the answer that makes somebody
    wait for nothing.

    `pids` is the caller's own pid plus, when set, `AOWL_BUILDLOCK` -- which
    every process spawned under a locked build inherits, so a script running
    INSIDE a build resolves to that build rather than to nothing.
    """
    for pid in pids:
        if held and int(held.get("pid", -1)) == int(pid):
            return {"pid": int(pid), "state": "holding", "position": None,
                    "of": len(q),
                    "via": "the lock file" if pid == pids[0]
                           else "AOWL_BUILDLOCK"}
    for pid in pids:
        for i, t in enumerate(q):
            if int(t.get("pid", -1)) == int(pid):
                return {"pid": int(pid), "state": "queued", "position": i + 1,
                        "of": len(q),
                        "via": "a queue ticket" if pid == pids[0]
                               else "AOWL_BUILDLOCK"}
    return {"pid": int(pids[0]), "state": "not-in-queue", "position": None,
            "of": len(q), "via": None}


def caller_pids():
    pids = [os.getpid()]
    env = os.environ.get("AOWL_BUILDLOCK")
    if env and env.strip().isdigit() and int(env) not in pids:
        pids.append(int(env))
    return pids


def holder_artifacts(repo, target):
    """The path(s) the holder's build will WRITE. `(paths, why_none)`.

    A waiter's next question after "who is building" is always "what will land
    on disk when it finishes", and answering it from `--status` is the
    difference between waiting and re-deriving the deploy.json mapping by hand.
    `why_none` is printed rather than swallowed: a target that declares no
    artifact must not look like a target that writes nothing.
    """
    if not target:
        return [], "the lock records no target"
    arts, why = target_artifacts(repo, target.split())
    if arts is None:
        return [], why
    return [_norm(a["src"]) for a in arts], ""


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
    repo = os.path.dirname(path) or "."
    you = you_state(held, q, caller_pids())
    if not held:
        return {"state": "free", "pid": None, "running": None, "target": None,
                "since": None, "since_epoch": None, "age_s": None,
                "queued_since": None, "queued_arrival": None, "fifo": "n/a",
                "hung": None, "you": you, "artifacts": [],
                "artifacts_why": "nobody is building", "queue": qout,
                "stages": status_stages(repo), "lock": path}
    arts, arts_why = holder_artifacts(repo, held.get("cmd"))
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
            # Filled in by hung_check() when a caller asks for it. It is NOT
            # computed here: status() is called in tight poll loops and a
            # process-table query per poll would make the cheap question
            # expensive. `null` means NOT CHECKED, never "not hung".
            "hung": None,
            "you": you, "artifacts": arts, "artifacts_why": arts_why,
            "queue": qout, "stages": status_stages(repo, held.get("cmd")),
            "lock": path}


STATUS_STAGES = 6


def status_stages(repo, held_target=None, limit=STATUS_STAGES):
    """The most recent staged builds, for `--status`.

    The holder's own target first when there is one, because the next question
    after "who is building" is "what can I deploy right now" -- and the answer
    is a stage, not whatever happens to be in bin/ at the instant you look.
    """
    try:
        recs = stagemod.stages(repo)
    except Exception:                                    # noqa: BLE001
        return []
    if held_target:
        key = stagemod.target_key(held_target)
        recs.sort(key=lambda r: (r["target_key"] != key, -r["built_at"]))
    return recs[:limit]


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


# ---------------------------------------------------------------------------
# Hang detection. See the module docstring for the measurement that produced it.
# ---------------------------------------------------------------------------

DEFAULT_HUNG_WINDOW = 20.0   # seconds between the two CPU samples
DEFAULT_HUNG_CPU = 0.5       # seconds of tree CPU below which nothing happened
DEFAULT_HUNG_STRIKES = 3     # consecutive hung? windows before a kill is offered
DEFAULT_HUNG_AFTER = 120.0   # do not even look at a holder younger than this

# Bound the nimcache walk. It runs once per window, not per poll, but this
# checkout has ~6k files under nimcache/ and an unbounded walk in a tool that
# is meant to diagnose a stall would be a poor joke.
NIMCACHE_TIME_BUDGET = 3.0
NIMCACHE_FILE_BUDGET = 60000
NIMCACHE_MAX_DEPTH = 4
NIMCACHE_SKIP = {".git", ".claude", "__pycache__", "node_modules", ".cache",
                 "bin", "obj", "build", "dm"}


def hung_state_path(lock):
    return os.path.join(os.path.dirname(lock) or ".", ".aowl-build.hung.json")


PS_PROC_TABLE = (
    "Get-CimInstance Win32_Process | "
    "Select-Object ProcessId,ParentProcessId,Name,KernelModeTime,UserModeTime "
    "| ConvertTo-Json -Compress -Depth 2"
)


def proc_table():
    """Every process as {pid: {"ppid", "name", "cpu_s"}}, or (None, why).

    ONE query, not one per pid: the parent/child links and the CPU times have
    to come from the same instant or a tree assembled from several calls can
    contain a child of a parent that no longer exists.

    Windows CPU times are `KernelModeTime` + `UserModeTime` in 100ns units.
    A process we lack rights to inspect reports 0, which reads as "no CPU" --
    that is a false HUNG source, so `unreadable` is counted and reported and
    the caller downgrades to `unknown` when the ROOT itself is unreadable.
    """
    if os.name == "nt":
        for shell in (["powershell", "-NoProfile", "-NonInteractive",
                       "-Command", PS_PROC_TABLE],
                      ["powershell", "-NoProfile", "-NonInteractive",
                       "-Command", PS_PROC_TABLE.replace(
                           "Get-CimInstance", "Get-WmiObject")]):
            try:
                r = subprocess.run(shell, capture_output=True, text=True,
                                   timeout=60)
            except Exception as e:
                return None, "%s: %s" % (type(e).__name__, e)
            if r.returncode != 0 or not (r.stdout or "").strip():
                continue
            try:
                doc = json.loads(r.stdout)
            except ValueError as e:
                return None, "unparseable process table (%s)" % e
            if isinstance(doc, dict):
                doc = [doc]
            out = {}
            for row in doc:
                try:
                    pid = int(row["ProcessId"])
                except (KeyError, TypeError, ValueError):
                    continue
                k = row.get("KernelModeTime") or 0
                u = row.get("UserModeTime") or 0
                try:
                    ppid = int(row.get("ParentProcessId") or 0)
                except (TypeError, ValueError):
                    ppid = 0
                out[pid] = {"ppid": ppid, "name": row.get("Name") or "?",
                            "cpu_s": (int(k) + int(u)) / 1e7}
            if out:
                return out, None
        return None, "no process table (powershell Win32_Process returned none)"
    try:
        r = subprocess.run(["ps", "-eo", "pid=,ppid=,time=,comm="],
                           capture_output=True, text=True, timeout=60)
    except Exception as e:
        return None, "%s: %s" % (type(e).__name__, e)
    if r.returncode != 0:
        return None, "ps exit %d" % r.returncode
    out = {}
    for line in r.stdout.splitlines():
        parts = line.split(None, 3)
        if len(parts) < 4:
            continue
        try:
            pid, ppid = int(parts[0]), int(parts[1])
        except ValueError:
            continue
        t, secs = parts[2], 0.0
        if "-" in t:
            d, t = t.split("-", 1)
            secs += float(d) * 86400
        bits = t.split(":")
        try:
            for b in bits:
                secs = secs * 60 + float(b)
        except ValueError:
            continue
        out[pid] = {"ppid": ppid, "name": parts[3].strip(), "cpu_s": secs}
    return (out, None) if out else (None, "ps returned no rows")


def proc_tree(table, root, max_nodes=400):
    """`root` and every descendant, root first.

    Depth and node count are capped: a pid table can contain a cycle after pid
    reuse (a child whose ppid was recycled into one of its own descendants),
    and an unbounded walk there never returns.
    """
    if table is None or root not in table:
        return []
    kids = {}
    for pid, info in table.items():
        kids.setdefault(info["ppid"], []).append(pid)
    seen, order, stack = {root}, [root], list(kids.get(root, ()))
    while stack and len(order) < max_nodes:
        pid = stack.pop()
        if pid in seen:
            continue
        seen.add(pid)
        order.append(pid)
        stack.extend(kids.get(pid, ()))
    return order


def find_nimcache_dirs(repo, max_depth=NIMCACHE_MAX_DEPTH):
    """Every `nimcache/` in THIS checkout, shallow-first.

    All of them, not the one belonging to the target being built: mapping a
    target string onto a directory is guesswork (`build mod maps` ->
    mods/maps/nimcache, `build host` -> two directories, `build` -> twenty),
    and a wrong mapping makes the check look at a directory nobody is writing
    and report `hung?` for a perfectly healthy build. Watching all of them can
    only ever produce a FALSE 'working', which is the safe direction.

    `.claude/worktrees` is skipped on purpose -- those are other checkouts with
    their own locks, and their build activity says nothing about ours.
    """
    found, stack = [], [(repo, 0)]
    while stack:
        d, depth = stack.pop()
        try:
            entries = list(os.scandir(d))
        except OSError:
            continue
        for e in entries:
            try:
                if not e.is_dir(follow_symlinks=False):
                    continue
            except OSError:
                continue
            if e.name == "nimcache":
                found.append(e.path)
                continue
            if e.name in NIMCACHE_SKIP or e.name.startswith("."):
                continue
            if depth + 1 < max_depth:
                stack.append((e.path, depth + 1))
    return sorted(found)


def nimcache_newest(repo, dirs=None, time_budget=NIMCACHE_TIME_BUDGET,
                    file_budget=NIMCACHE_FILE_BUDGET):
    """The newest mtime under any nimcache in the checkout.

    `truncated` is the honest part. If the walk ran out of budget we have seen
    a SUBSET: a recent mtime in that subset still proves activity, but the
    ABSENCE of one proves nothing, and the caller must degrade to `unknown`
    rather than to `hung?`.
    """
    t0 = time.time()
    res = {"newest": None, "path": None, "dirs": 0, "files": 0,
           "truncated": False, "error": None}
    try:
        dirs = find_nimcache_dirs(repo) if dirs is None else list(dirs)
    except Exception as e:
        res["error"] = "%s: %s" % (type(e).__name__, e)
        return res
    res["dirs"] = len(dirs)
    stack = list(dirs)
    while stack:
        if time.time() - t0 > time_budget or res["files"] > file_budget:
            res["truncated"] = True
            break
        d = stack.pop()
        try:
            entries = list(os.scandir(d))
        except OSError:
            continue
        for e in entries:
            try:
                if e.is_dir(follow_symlinks=False):
                    stack.append(e.path)
                    continue
                mt = e.stat(follow_symlinks=False).st_mtime
            except OSError:
                continue
            res["files"] += 1
            if res["newest"] is None or mt > res["newest"]:
                res["newest"] = mt
                res["path"] = os.path.relpath(e.path, repo)
    return res


def take_sample(repo, pid, table=None, nimcache_dirs=None):
    """One instant: the holder's tree with per-pid CPU, plus the nimcache tip."""
    if table is None:
        table, err = proc_table()
    else:
        err = None
    tree = proc_tree(table, pid)
    procs = {}
    for p in tree:
        procs[str(p)] = {"name": table[p]["name"], "cpu_s": table[p]["cpu_s"]}
    return {"at": time.time(), "pid": pid, "procs": procs,
            "proc_error": err,
            "root_seen": bool(tree),
            "nimcache": nimcache_newest(repo, dirs=nimcache_dirs)}


def hung_verdict(prev, cur, window_s=DEFAULT_HUNG_WINDOW,
                 cpu_floor=DEFAULT_HUNG_CPU):
    """`working` / `hung?` / `unknown`, with the evidence that produced it.

    The bar for `hung?` is deliberately high and the bar for `working` is
    deliberately low: this verdict can lead to a build being KILLED, so every
    ambiguity resolves away from that. In particular a truncated nimcache walk,
    an unreadable process table, a root pid we cannot see and a window that is
    simply too short are all `unknown` -- and `unknown` resets the strike
    count in hung_check(), so no amount of not-looking can add up to a kill.
    """
    ev = {"verdict": "unknown", "why": "", "window_s": None,
          "cpu_delta_s": None, "procs": [], "gone": [],
          "nimcache_newest_age_s": None, "nimcache_path": None,
          "nimcache_dirs": None, "nimcache_changed": None}
    if not prev or not cur:
        ev["why"] = "only one sample so far; a verdict needs two"
        return ev
    elapsed = cur["at"] - prev["at"]
    ev["window_s"] = elapsed
    nc = cur.get("nimcache") or {}
    ev["nimcache_dirs"] = nc.get("dirs")
    ev["nimcache_path"] = nc.get("path")
    if nc.get("newest") is not None:
        ev["nimcache_newest_age_s"] = cur["at"] - nc["newest"]
        ev["nimcache_changed"] = nc["newest"] > prev["at"]

    if cur.get("proc_error") or prev.get("proc_error"):
        ev["why"] = ("the process table could not be read (%s) -- NOT PERFORMED"
                     % (cur.get("proc_error") or prev.get("proc_error")))
        return ev
    if not prev.get("root_seen") or not cur.get("root_seen"):
        ev["why"] = ("the holder pid %s was not in the process table at both "
                     "ends of the window -- nothing was compared" % cur["pid"])
        return ev
    if elapsed < window_s:
        ev["why"] = ("the samples are %.1fs apart; the window is %.0fs "
                     "(%.0fs to go)" % (elapsed, window_s, window_s - elapsed))
        return ev

    p_prev, p_cur = prev["procs"], cur["procs"]
    delta = 0.0
    rows = []
    for pid, info in sorted(p_cur.items(), key=lambda kv: int(kv[0])):
        was = p_prev.get(pid)
        # A pid that appeared during the window contributes its WHOLE cpu:
        # a compiler that started and did work is work, and pretending its
        # baseline was its current value would hide exactly that.
        d = info["cpu_s"] - was["cpu_s"] if was else info["cpu_s"]
        d = max(0.0, d)
        delta += d
        rows.append({"pid": int(pid), "name": info["name"],
                     "cpu_s": info["cpu_s"], "cpu_delta_s": d,
                     "new": was is None})
    gone = [{"pid": int(p), "name": v["name"], "cpu_s": v["cpu_s"]}
            for p, v in sorted(p_prev.items(), key=lambda kv: int(kv[0]))
            if p not in p_cur]
    ev["cpu_delta_s"] = delta
    ev["procs"] = rows
    ev["gone"] = gone

    if delta >= cpu_floor:
        ev["verdict"] = "working"
        ev["why"] = ("the holder's tree burned %.2fs of CPU in %.0fs"
                     % (delta, elapsed))
        return ev
    if gone:
        ev["verdict"] = "working"
        ev["why"] = ("%d process(es) in the holder's tree exited during the "
                     "window (%s) -- a compiler finishing is progress"
                     % (len(gone), ", ".join("%s/%d" % (g["name"], g["pid"])
                                             for g in gone[:4])))
        return ev
    if ev["nimcache_changed"]:
        ev["verdict"] = "working"
        ev["why"] = ("no CPU, but %s was written %.0fs ago, inside the window"
                     % (nc.get("path"), ev["nimcache_newest_age_s"]))
        return ev
    if nc.get("error"):
        ev["why"] = ("no CPU, and the nimcache could not be scanned (%s) -- "
                     "NOT PERFORMED, not 'nothing was written'" % nc["error"])
        return ev
    if nc.get("truncated"):
        ev["why"] = ("no CPU, but the nimcache walk was TRUNCATED after %d "
                     "files, so 'nothing was written' was not established"
                     % nc.get("files", 0))
        return ev
    if nc.get("newest") is None:
        ev["why"] = ("no CPU, and no nimcache file exists at all (%d dirs "
                     "scanned) -- there is nothing here to show progress, so "
                     "no claim is made" % nc.get("dirs", 0))
        return ev
    ev["verdict"] = "hung?"
    ev["why"] = ("the holder's whole process tree accumulated %.2fs of CPU in "
                 "%.0fs (floor %.2fs) and no nimcache file was touched; the "
                 "newest is %.0fs old" % (delta, elapsed, cpu_floor,
                                          ev["nimcache_newest_age_s"]))
    return ev


def _read_hung_state(p):
    try:
        with open(p, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def _write_hung_state(p, doc):
    tmp = p + ".tmp%d" % os.getpid()
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(doc, f)
        os.replace(tmp, p)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def hung_check(lock, repo, st, window_s=DEFAULT_HUNG_WINDOW,
               cpu_floor=DEFAULT_HUNG_CPU, blocking=False,
               after_s=DEFAULT_HUNG_AFTER, strikes=DEFAULT_HUNG_STRIKES):
    """Sample, compare with the previous sample, and count consecutive hung?s.

    Non-blocking by default: the baseline lives in `.aowl-build.hung.json`
    beside the lock, so the FIRST call arms the check and a later call, once a
    window has passed, returns a verdict. `blocking=True` takes both samples
    itself.

    The state file can be written by several waiters at once. That is benign --
    `os.replace` is atomic, so the worst case is a baseline being reset by
    somebody else and one extra window elapsing before a verdict. Exclusion
    never depends on this file; nothing here can let two builds run at once.
    """
    ev = {"verdict": "unknown", "why": "", "consecutive": 0,
          "strikes_needed": strikes, "cached": False}
    if st.get("state") != "held" or not st.get("pid"):
        ev["why"] = "no live holder to check"
        return ev
    age = st.get("age_s") or 0.0
    if not blocking and age < after_s:
        ev["why"] = ("the holder is only %.0fs old; hang checking starts at "
                     "%.0fs" % (age, after_s))
        return ev

    spath = hung_state_path(lock)
    state = _read_hung_state(spath)
    same = (state.get("holder_pid") == st["pid"]
            and state.get("holder_started") == st.get("since_epoch"))
    prev = state.get("sample") if same else None
    consec = int(state.get("consecutive", 0)) if same else 0

    if not blocking and same and state.get("verdict_at") \
            and time.time() - state["verdict_at"] < window_s:
        # A verdict younger than one window is REPLAYED rather than recomputed.
        # Sampling costs a process-table query, and `--status` is polled in
        # tight loops; more importantly, resampling faster than the window can
        # never produce a new verdict anyway, so the query would buy nothing.
        # It is flagged `cached` so nobody reads it as a fresh measurement.
        ev = dict(state.get("verdict") or ev)
        ev["cached"] = True
        ev["consecutive"] = consec
        ev["strikes_needed"] = strikes
        ev["why"] = "%s   [replayed, measured %.0fs ago]" % (
            ev.get("why", ""), time.time() - state["verdict_at"])
        return ev

    dirs = find_nimcache_dirs(repo)
    if blocking:
        prev = take_sample(repo, st["pid"], nimcache_dirs=dirs)
        time.sleep(window_s)
    cur = take_sample(repo, st["pid"], nimcache_dirs=dirs)

    v = hung_verdict(prev, cur, window_s, cpu_floor)
    v["strikes_needed"] = strikes
    v["cached"] = False

    if v["verdict"] == "hung?":
        consec += 1
        baseline = cur
    elif v["verdict"] == "working":
        consec = 0
        baseline = cur
    else:
        # UNKNOWN. It must not accumulate toward a kill, and it must not
        # discard a baseline that has simply not aged into a window yet --
        # replacing it every poll is how a 1s poll loop would guarantee the
        # window never closes.
        consec = 0
        baseline = prev if (prev and not blocking) else cur
    v["consecutive"] = consec
    doc = {"holder_pid": st["pid"],
           "holder_started": st.get("since_epoch"),
           "holder_cmd": st.get("target"),
           "sample": baseline, "consecutive": consec,
           "last_verdict": v["verdict"], "last_at": time.time()}
    if v["verdict"] != "unknown" or v.get("window_s"):
        # Only a verdict that came from a real comparison is worth replaying.
        # "only one sample so far" must NOT be cached, or the very next call
        # would replay it instead of taking the second sample.
        doc["verdict"] = v
        doc["verdict_at"] = time.time()
    _write_hung_state(spath, doc)
    return v


def hung_lines(ev):
    """The evidence block. Never a bare verdict: the pids, the CPU deltas and
    the nimcache age are the whole point, because they are what lets a human
    say 'no, that one is fine' without re-deriving anything."""
    tag = {"hung?": "HUNG?", "working": "working",
           "unknown": "hang check: unknown"}.get(ev["verdict"], ev["verdict"])
    out = ["  %s -- %s" % (tag, ev["why"])]
    if ev.get("window_s"):
        out[0] += "  [window %.0fs]" % ev["window_s"]
    for r in (ev.get("procs") or [])[:8]:
        out.append("      pid %-6d %-22s cpu %8.2fs  delta %+.2fs%s"
                   % (r["pid"], r["name"][:22], r["cpu_s"], r["cpu_delta_s"],
                      "  (NEW)" if r.get("new") else ""))
    if len(ev.get("procs") or []) > 8:
        out.append("      ... and %d more" % (len(ev["procs"]) - 8))
    for g in (ev.get("gone") or [])[:4]:
        out.append("      pid %-6d %-22s EXITED during the window"
                   % (g["pid"], g["name"][:22]))
    if ev.get("nimcache_newest_age_s") is not None:
        out.append("      newest nimcache file %.0fs old: %s   (%s dirs "
                   "watched)" % (ev["nimcache_newest_age_s"],
                                 ev.get("nimcache_path"),
                                 ev.get("nimcache_dirs")))
    if ev["verdict"] == "hung?":
        out.append("      %d consecutive hung window(s); %d needed before "
                   "--break-hung will act"
                   % (ev.get("consecutive", 0), ev.get("strikes_needed",
                                                       DEFAULT_HUNG_STRIKES)))
    return out


def kill_tree(pid, table=None):
    """Kill the holder and everything under it. Returns what was killed.

    The tree is enumerated BEFORE the kill, so the log names real processes
    rather than whatever survived. `taskkill /T` walks the tree itself; the
    enumeration is for the record, not for the killing.
    """
    if table is None:
        table, _err = proc_table()
    victims = [{"pid": p, "name": (table or {}).get(p, {}).get("name", "?")}
               for p in proc_tree(table, pid)] or [{"pid": pid, "name": "?"}]
    if os.name == "nt":
        try:
            subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"],
                           capture_output=True, text=True, timeout=60)
        except Exception:
            pass
    else:
        for v in reversed(victims):
            try:
                os.kill(v["pid"], 9)
            except Exception:
                pass
    return victims


def print_you(st):
    """Where the reader stands, and what the holder will write."""
    y = st.get("you") or {}
    if y.get("state") == "holding":
        print("  you are pid %s: HOLDING this lock (via %s)"
              % (y["pid"], y.get("via")))
    elif y.get("state") == "queued":
        print("  you are pid %s: QUEUED position %d of %d (via %s)"
              % (y["pid"], y["position"], y["of"], y.get("via")))
    else:
        print("  you are pid %s: NOT IN THE QUEUE -- nothing here is waiting "
              "on your behalf" % y.get("pid"))
    if st["state"] != "free":
        if st.get("artifacts"):
            print("  the holder will write: %s" % ", ".join(st["artifacts"]))
        else:
            print("  the holder's artifact path is UNKNOWN (%s) -- not "
                  "'it writes nothing'"
                  % (st.get("artifacts_why") or "no reason recorded"))


def print_stages(st):
    """What is deployable RIGHT NOW, independently of what bin/ holds.

    A stage is a copy no build writes to, so this list is the honest answer to
    "what can be deployed while somebody is building". Absence is stated
    outright: an empty section reads as "the tool did not print anything",
    which is not the same as "there is nothing to deploy".
    """
    recs = st.get("stages") or []
    if not recs:
        print("  staged builds: NONE under .stage/ -- a deploy will have to "
              "read bin/, where a build can delete the file mid-copy.")
        return
    print("  staged builds (newest first; deploy with "
          "`deploy.py deploy --only NAME --sha PREFIX`):")
    for ln in stagemod.lines(recs):
        print(ln)


def print_status_human(st):
    """The text a person reads. UNCHANGED on purpose -- scripts should use
    --json or the exit code, but existing eyes and greps should not break."""
    if st["state"] == "free":
        print("build lock FREE (%s)" % st["lock"])
        for i, t in enumerate(st["queue"]):
            print("  queued %d: pid %s %r since %s"
                  % (i + 1, t["pid"], t["target"], t["since"]))
        print_you(st)
        print_stages(st)
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
    print_you(st)
    print_stages(st)
    if st.get("fifo") == "INVERTED":
        print("  FIFO INVERTED: the holder joined the queue AFTER a waiter "
              "that is still waiting. That is a real fairness bug, measured "
              "on comparable clocks -- report it with this output.")
    if st.get("hung"):
        for ln in hung_lines(st["hung"]):
            print(ln)
        if st["hung"]["verdict"] == "hung?":
            print("      a pid that EXISTS is not a build that is PROGRESSING. "
                  "If you agree with the evidence above, re-run your build "
                  "with --break-hung (it kills this tree), or --steal.")
    elif st["state"] == "held":
        # An absent hang check must never read as a clean bill of health.
        print("  (no hang check was performed -- pass --check-hung for one. "
              "'running' here means only that the pid exists.)")


def wait_free(path, max_age, timeout, poll=1.0, announce=True, hopts=None):
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
    hung_every = (hopts["window"] + 1.0) if hopts else 0.0
    last_hung_at = time.time()
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
        # This waiter runs NOTHING, so it never kills anything -- but it should
        # still say when the thing it is waiting for has stopped moving,
        # otherwise `--wait-free 1800` in front of a hung holder is a
        # half-hour of silence indistinguishable from a slow build.
        if announce and hopts and hopts.get("enabled") \
                and (st["age_s"] or 0) >= hopts["after"] \
                and time.time() - last_hung_at >= hung_every:
            last_hung_at = time.time()
            ev = hung_check(path, hopts["repo"], st, hopts["window"],
                            hopts["cpu"], False, hopts["after"],
                            hopts["strikes"])
            if ev["verdict"] == "hung?":
                print("")
                print("THE HOLDER MAY BE HUNG (pid %s, %r):"
                      % (st["pid"], st["target"]))
                for ln in hung_lines(ev):
                    print(ln)
                print("  --wait-free runs nothing and kills nothing. To end "
                      "that tree, run your build with --break-hung.",
                      flush=True)
        if time.time() >= deadline:
            return None
        time.sleep(min(poll, max(0.0, deadline - time.time()) + 0.01))


def hung_opts(repo=None, enabled=True, break_hung=False,
              window=DEFAULT_HUNG_WINDOW, cpu=DEFAULT_HUNG_CPU,
              strikes=DEFAULT_HUNG_STRIKES, after=DEFAULT_HUNG_AFTER):
    """The knobs a waiter uses to decide whether a holder is alive-but-dead.

    `enabled` controls DETECTION; `break_hung` controls KILLING, and they are
    separate on purpose. Detection defaults on because its whole value is being
    there when nobody suspected a hang; killing defaults off because the
    verdict is heuristic and a false positive destroys a running build.
    """
    return {"repo": repo or REPO, "enabled": enabled, "break_hung": break_hung,
            "window": window, "cpu": cpu, "strikes": strikes, "after": after}


def acquire(path, cmd, wait_s, max_age, steal, hopts=None):
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
                               steal, slot, hopts)
    except BaseException:
        leave_queue(slot[0])
        raise


def race_acquire(path, cmd, wait_s, max_age, steal, hopts=None):
    """The OLD, UNFAIR algorithm: no ticket, everyone races for `O_EXCL`.

    Kept for exactly one reason: `tools/test_buildlock.py` needs something that
    CAN let the later arrival win. Without it the FIFO test asserts an ordering
    that a coin-toss would also produce most of the time, and an ordering test
    with no losing counterpart is the check-that-cannot-fail this repo keeps
    finding (CLAUDE.md 9b). It is not used by `main` and must not be.
    """
    return _acquire_queued(path, None, None, cmd, wait_s, max_age, steal,
                           None, hopts)


def _acquire_queued(path, qdir, ticket, cmd, wait_s, max_age, steal,
                    slot=None, hopts=None):
    deadline = time.time() + wait_s
    announced = False
    yielded_to = None
    requeues = 0
    # The hang check runs at most once per window, and the +1s matters: the
    # verdict is only made when the two samples are at least a FULL window
    # apart, so polling at exactly `window` would land just short of it about
    # half the time and never produce a verdict at all.
    hung_every = (hopts["window"] + 1.0) if hopts else 0.0
    last_hung_at = time.time()
    warned_at_strike = 0
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

        # IS THE HOLDER ACTUALLY BUILDING? `alive` above only says the pid
        # exists, and a nimony that stops dead keeps its pid for as long as you
        # let it. Measured 2026-09-01: fifteen minutes of `(running)` and a
        # queue waiting twenty-five behind a process at 0.27s of CPU.
        if hopts and hopts.get("enabled") and not steal \
                and age >= hopts["after"] \
                and time.time() - last_hung_at >= hung_every:
            last_hung_at = time.time()
            ev = hung_check(path, hopts["repo"], status(path, max_age),
                            hopts["window"], hopts["cpu"], False,
                            hopts["after"], hopts["strikes"])
            if ev["verdict"] == "hung?":
                print("")
                print("THE HOLDER MAY BE HUNG (pid %d, %r):" % (pid, held.get("cmd")))
                for ln in hung_lines(ev):
                    print(ln)
                strikes = hopts["strikes"]
                if ev["consecutive"] >= strikes:
                    if hopts.get("break_hung"):
                        victims = kill_tree(pid)
                        print("--break-hung: KILLING the holder's process "
                              "tree after %d consecutive hung window(s). "
                              "Killed:" % ev["consecutive"])
                        for v in victims:
                            print("      pid %-6d %s" % (v["pid"], v["name"]))
                        try:
                            os.unlink(path)
                        except OSError:
                            pass
                        try:
                            os.unlink(hung_state_path(path))
                        except OSError:
                            pass
                        print("      lock dropped; taking it now.", flush=True)
                        announced = False
                        continue
                    if warned_at_strike != ev["consecutive"]:
                        warned_at_strike = ev["consecutive"]
                        print("  NOTHING WAS KILLED. Killing is opt-in: "
                              "re-run this command with --break-hung to end "
                              "that process tree and take the lock. Check the "
                              "evidence above first -- this verdict is a "
                              "heuristic, and a false positive destroys a "
                              "running build.", flush=True)
            else:
                warned_at_strike = 0
                if ev["verdict"] == "unknown" and ev["why"]:
                    print("  (hang check: %s)" % ev["why"], flush=True)

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


# Source trees an agent edits. A change under one of these can plausibly break
# somebody else's compile; a change under `.cache/` or `installer/build/`
# cannot, and listing it would just dilute the block.
WATCH_PREFIXES = ("host/", "mods/", "tools/")

# Enough to name the culprit, not enough to become a log dump.
MAX_LINES = 40

# The lock's own bookkeeping, which changes on every acquire and release.
SELF_PATHS = (".aowl-build.lock", ".aowl-build.queue",
              ".aowl-build.hung.json")


def _git(repo, args, timeout=10.0):
    """(stdout, None) or (None, why). Never raises, never blocks for long."""
    try:
        r = subprocess.run(["git"] + list(args), cwd=repo,
                           capture_output=True, text=True, timeout=timeout)
    except Exception as e:  # git missing, timeout, anything
        return None, "%s: %s" % (type(e).__name__, e)
    if r.returncode != 0:
        why = (r.stderr or "").strip().splitlines()
        return None, (why[0][:160] if why else "git exit %d" % r.returncode)
    return r.stdout, None


def _porcelain_path(line):
    """The path from one `git status --porcelain` line.

    For a rename (`R  old -> new`) this is the DESTINATION, because that is
    the file that now exists and can break a compile. Quoted paths (non-ASCII
    or spaces) are unquoted; a path we cannot decode is returned as-is rather
    than dropped, since a mangled name in the block is still a lead and a
    missing one is not.
    """
    rest = line[3:]
    if " -> " in rest:
        rest = rest.split(" -> ", 1)[1]
    rest = rest.strip()
    if len(rest) >= 2 and rest.startswith('"') and rest.endswith('"'):
        try:
            rest = rest[1:-1].encode("utf-8").decode("unicode_escape")
        except Exception:
            rest = rest[1:-1]
    return rest


def tree_snapshot(repo):
    """What the working tree looks like right now: HEAD, status codes, mtimes.

    `--porcelain` (v1, default `-unormal`) is used rather than `-uall` on
    purpose: `-uall` walks INTO untracked directories, and this checkout has
    untracked `build/` and `dm/` trees that would make the call slow enough to
    notice on every acquire. An untracked directory still appears as one entry,
    and its MTIME changes when a file is created inside it, so a file appearing
    in an untracked dir is still detected -- just named by its directory.

    `error` is a string, never silently empty: a snapshot that failed must be
    reportable as "not performed".
    """
    snap = {"at": time.time(), "head": None, "status": {}, "mtime": {},
            "error": None}
    out, err = _git(repo, ["rev-parse", "HEAD"])
    if err is not None:
        snap["error"] = "git rev-parse HEAD failed (%s)" % err
    else:
        snap["head"] = out.strip()
    out, err = _git(repo, ["status", "--porcelain"])
    if err is not None:
        snap["error"] = ((snap["error"] + "; ") if snap["error"] else "") + \
            "git status --porcelain failed (%s)" % err
        return snap
    for line in out.splitlines():
        if len(line) < 4:
            continue
        p = _porcelain_path(line)
        # NOT `lstrip("./")` here: lstrip strips CHARACTERS, so it would eat
        # the leading dot of `.aowl-build.lock` and the match would silently
        # never fire.
        if not p or p.replace("\\", "/").startswith(SELF_PATHS):
            # Our OWN lock and queue files move on every acquire and release.
            # Reporting them as "changed during this build" would be true and
            # useless, and a block that always has noise in it stops being
            # read.
            continue
        snap["status"][p] = line[:2]
        try:
            snap["mtime"][p] = os.path.getmtime(os.path.join(repo, p))
        except OSError:
            snap["mtime"][p] = None
    return snap


def _rel_mtime(mt, t0):
    """An mtime as an offset from the acquire time: `+12s` is DURING the
    build, `-90s` is before it started. Absolute clock times would force the
    reader to do this subtraction in their head, which is where a coincidence
    starts looking like a cause."""
    if mt is None:
        return "mtime unreadable"
    d = mt - t0
    # One decimal: a build that fails in three seconds would otherwise report
    # every mtime as `+0s`, which reads as "no information".
    return "mtime %+.1fs vs lock acquire" % d


def concurrent_edit_lines(before, after, watch=WATCH_PREFIXES,
                          max_lines=MAX_LINES):
    """The body of the block: what moved in the tree while the build ran.

    Returns a list of lines. It is deliberately EVIDENCE, not a verdict --
    this process cannot know who wrote any of these files, and saying it could
    would be the confidently wrong answer. An unusable snapshot produces a
    NOT PERFORMED line, never an empty list that reads as "all clear".
    """
    lines = []
    if before.get("error") or after.get("error"):
        lines.append("  NOT PERFORMED: the working-tree comparison could not "
                     "be made (%s). This is NOT 'nothing changed'."
                     % (before.get("error") or after.get("error")))
        return lines

    if before.get("head") != after.get("head"):
        lines.append("  HEAD MOVED during this build: %s -> %s   (a checkout, "
                     "commit or rebase under a running build)"
                     % ((before.get("head") or "?")[:12],
                        (after.get("head") or "?")[:12]))

    t0 = before["at"]
    b, a = before["status"], after["status"]
    changed = []
    for p in sorted(set(b) | set(a)):
        if p not in b:
            changed.append(("APPEARED", p, a[p], after["mtime"].get(p)))
        elif p not in a:
            changed.append(("GONE    ", p, b[p], before["mtime"].get(p)))
        elif b[p] != a[p]:
            changed.append(("STATUS  %s->%s" % (b[p], a[p]), p, a[p],
                            after["mtime"].get(p)))
        elif before["mtime"].get(p) != after["mtime"].get(p):
            changed.append(("REWRITTEN", p, a[p], after["mtime"].get(p)))

    if changed:
        lines.append("  changed in the working tree WHILE this build ran:")
        for kind, p, st, mt in changed[:max_lines]:
            lines.append("    %-9s %-6s %s   (%s)"
                         % (kind.strip(), "[%s]" % st, p, _rel_mtime(mt, t0)))
        if len(changed) > max_lines:
            lines.append("    ... and %d more" % (len(changed) - max_lines))

    seen = {p for _, p, _, _ in changed}
    pre = [p for p in sorted(b)
           if p not in seen and p.replace("\\", "/").startswith(watch)]
    if pre:
        lines.append("  already modified/untracked when the lock was taken "
                     "(ownership is UNKNOWABLE from here -- some of these are "
                     "probably yours):")
        for p in pre[:max_lines]:
            lines.append("    %-6s %s   (%s)"
                         % ("[%s]" % b[p], p,
                            _rel_mtime(before["mtime"].get(p), t0)))
        if len(pre) > max_lines:
            lines.append("    ... and %d more" % (len(pre) - max_lines))

    if not changed and not pre:
        lines.append("  no working-tree change was observed during this build, "
                     "and no host/ mods/ tools/ file was dirty when it started.")
    return lines


def print_concurrent_edits(before, after):
    """The block printed after a FAILED build. Nothing is printed on success;
    see main()."""
    print("")
    print("CONCURRENT EDITS DURING THIS BUILD:")
    for ln in concurrent_edit_lines(before, after):
        print(ln)
    print("  a failure in a file you did not edit is likely another agent's "
          "half-written change; re-run after the queue drains")


# ---------------------------------------------------------------------------
# EXIT 0 IS NOT AN ARTIFACT. See the module docstring for the measurement.
# ---------------------------------------------------------------------------

ARTIFACT_ABSENT_EXIT = 5
ARTIFACT_STALE_EXIT = 6
# A build whose SOURCES moved under it. See source_change_check().
SOURCES_CHANGED_EXIT = 15
# Filesystem/clock granularity around the acquire instant. A file written in
# the same second the lock was taken cannot be attributed to either side, and
# calling that a mid-build edit would refuse builds that are fine. One second
# is granularity; the incident this catches had the edit MINUTES after acquire.
SOURCE_CHANGE_SLACK = 1.0

VERIFY_MATCH_EXIT = 0
VERIFY_REPLACED_EXIT = 2
VERIFY_ABSENT_EXIT = 3
VERIFY_NO_SIDECAR_EXIT = 5

# A build that writes its artifact within a second of starting is not the case
# this guards against -- the stale artifact it catches is MINUTES old, left by
# an earlier build whose successor removed nothing because it failed before it
# got that far. Two seconds of slack absorbs clock/filesystem granularity
# without being able to mask that.
ARTIFACT_MTIME_SLACK = 2.0

SIDECAR_SUFFIX = ".built.json"

# What a nimony build here actually READS. Deliberately narrow: a broader set
# (docs, tools/*.py) would make every no-op rebuild look stale again, which is
# the false refusal this exists to remove.
SOURCE_EXTS = (".nim", ".nims", ".nimble", ".cfg", ".h", ".c", ".cpp",
               ".hlsl", ".inc")
# Roots every module in this checkout compiles against, on top of its own
# module directory. Missing one here can only produce a FALSE UP-TO-DATE, so
# the list errs wide and the scan REPORTS which roots it looked at.
SHARED_SOURCE_ROOTS = ("abi", "host/common")
SOURCE_SCAN_BUDGET = 8.0
SOURCE_SKIP_DIRS = {".git", "bin", "build", "nimcache", ".cache", "__pycache__",
                    ".claude", "node_modules"}

# A file the BUILD WRITES, sitting inside a source root, is not a source. See
# generated_sources() -- this pattern finds the ones tools/aowl.nim names.
AOWL_OUT_RE = re.compile(
    r'let\s+(out[A-Za-z0-9_]*)\s*=\s*joinPath\(e\.repo,\s*"([^"]+)"\)')


def _norm(p):
    return p.replace("\\", "/")


def generated_sources(repo):
    """Files the BUILD WRITES under the source roots. `(declared, notes)`.

    ## The defect

    MEASURED 2026-09-02: two consecutive no-op `build host` runs exited 6
    ARTIFACT STALE naming `abi/aowlspt_symtab.nim` as "modified after the
    artifact", while the artifact was correct and byte-identical to its
    sidecar. That file is REGENERATED BY EVERY BUILD -- `symTab()` in
    tools/aowl.nim runs `il2cpp_symtab.py gen` into `abi/aowlspt_symtab.h`
    and `abi/aowlspt_symtab.nim` before anything compiles -- so it is newer
    than the artifact after EVERY build that does not rewrite the artifact.
    A staleness check that fires on the build's own output cannot ever pass:
    that is the check-that-cannot-succeed twin of CLAUDE.md 9b.

    ## Where the list comes from, and why there are two sources

    `declared` is DATA, in `tools/deploy.json` under `generatedSources`
    (`{"path": ..., "why": ...}`). It is the authority, because an entry here
    WEAKENS a check -- wrongly excluding a real source would produce a false
    UP-TO-DATE, and that is the dangerous direction -- so it is a reviewed
    human decision, not a guess.

    `notes` carries a CROSS-CHECK against the build definition: tools/aowl.nim
    is scanned for `let out... = joinPath(e.repo, "...")`, which is the shape
    every generator output there has today. Anything it finds under a source
    root that is NOT declared is REPORTED as undeclared -- and deliberately
    NOT excluded, so the list can rot loudly (a re-appearing false STALE with
    a line naming the culprit) instead of silently widening the hole. If
    aowl.nim cannot be read the note says the cross-check was NOT PERFORMED.

    NOTE for whoever edits deploy.json: aowl.nim's `deployArtifacts` reader is
    LINE-BASED and grabs any line starting with `"src"`. Generated entries use
    `"path"` for exactly that reason; do not rename it to `src`.
    """
    notes = []
    declared = {}
    p = os.path.join(repo, "tools", "deploy.json")
    try:
        with open(p, "r", encoding="utf-8-sig") as f:
            cfg = json.load(f)
    except Exception as e:
        notes.append("tools/deploy.json could not be read (%s: %s), so NO "
                     "build output could be excluded from the staleness scan "
                     "-- a regenerated file may read as a modified source"
                     % (type(e).__name__, e))
        cfg = {}
    for row in (cfg.get("generatedSources") or []):
        if isinstance(row, str):
            declared[_norm(row)] = ""
        elif isinstance(row, dict) and row.get("path"):
            declared[_norm(row["path"])] = row.get("why", "")
    nim = os.path.join(repo, "tools", "aowl.nim")
    try:
        with open(nim, "r", encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError as e:
        notes.append("the cross-check against tools/aowl.nim was NOT "
                     "PERFORMED (%s) -- the excluded set is whatever "
                     "deploy.json declares, unverified" % e)
        return declared, notes
    found = set()
    for _var, path in AOWL_OUT_RE.findall(text):
        # The literal is NIM SOURCE: `"abi\\aowlspt_symtab.h"` is one
        # backslash. Normalising without unescaping first yields `abi//...`,
        # which matches nothing and made the cross-check report a file it had
        # itself mangled as undeclared.
        rel = _norm(path.replace("\\\\", "\\"))
        if rel.lower().endswith(SOURCE_EXTS):
            found.add(rel)
    undeclared = sorted(f for f in found if f not in declared)
    if undeclared:
        notes.append("tools/aowl.nim writes %s, which tools/deploy.json does "
                     "NOT list under generatedSources. It is being treated as "
                     "a SOURCE (so it can still cause a false STALE); declare "
                     "it there if the build really generates it."
                     % ", ".join(undeclared))
    return declared, notes


def artifact_source_roots(repo, art):
    """Directories whose contents are INPUTS to this artifact.

    The module directory is everything in `src` above its `bin/` component
    (`host/Aowlspt.Host.Il2Cpp/bin/x.dll` -> `host/Aowlspt.Host.Il2Cpp`), plus
    the shared roots above. An artifact may name its own list with a `sources`
    key in tools/deploy.json; nothing does today.

    Returns `(roots, why_empty)`. An artifact that is not a build output (e.g.
    checked-in data that a build only ships) has no source roots and must not
    be given an mtime verdict at all.
    """
    declared = art.get("sources")
    if declared:
        rel = [_norm(x) for x in declared if isinstance(x, str)]
    else:
        s = _norm(art["src"])
        if "/bin/" not in s:
            return [], ("%s is not under a bin/ directory, so its module "
                        "root cannot be derived" % s)
        rel = [s.split("/bin/", 1)[0]] + list(SHARED_SOURCE_ROOTS)
    out = []
    for r in rel:
        full = os.path.join(repo, r.replace("/", os.sep))
        if os.path.isdir(full):
            out.append(r)
    if not out:
        return [], "none of %s exists under %s" % (rel, repo)
    return out, ""


def newest_source(repo, roots, budget=SOURCE_SCAN_BUDGET, generated=None,
                  newer_than=None):
    """The newest source file under `roots`, IGNORING build outputs.

    dict: mtime / path / files / roots / truncated / error / excluded / newer.

    `newer_than` (an epoch time) additionally COLLECTS every source whose mtime
    is after it, into `newer`. It is the same walk on purpose: a separate
    "which sources changed during the build" scanner would use a second copy of
    the extension list, the skip list and the generated-file exclusions, and
    the moment those two copies disagree one of them is answering a question
    nobody asked. `newer` is only meaningful when `truncated` and `error` are
    both falsey -- an incomplete walk that found nothing has established
    NOTHING.
    `truncated` or `error` means the walk did NOT see everything, and a caller
    must treat that as INCONCLUSIVE -- never as "nothing is newer". That
    distinction is the whole point: "I did not look" reading as "it is fine" is
    CLAUDE.md 9b.

    `generated` is `{relpath: why}` from generated_sources(). A file the build
    itself writes is not an input, and treating it as one made every no-op
    rebuild refuse. Every skipped file lands in `excluded` WITH its reason and
    is printed, because an exclusion that nobody can see is a hole.
    """
    t0 = time.time()
    generated = dict(generated or {})
    res = {"mtime": None, "path": None, "files": 0, "roots": list(roots),
           "truncated": False, "error": None, "excluded": [], "newer": []}
    try:
        for r in roots:
            base = os.path.join(repo, r.replace("/", os.sep))
            for dirpath, dirnames, filenames in os.walk(base):
                dirnames[:] = [d for d in dirnames
                               if d not in SOURCE_SKIP_DIRS]
                if time.time() - t0 > budget:
                    res["truncated"] = True
                    return res
                for fn in filenames:
                    if not fn.lower().endswith(SOURCE_EXTS):
                        continue
                    p = os.path.join(dirpath, fn)
                    try:
                        mt = os.stat(p).st_mtime
                    except OSError:
                        continue
                    rel = _norm(os.path.relpath(p, repo))
                    if rel in generated:
                        res["excluded"].append({"path": rel,
                                                "why": generated[rel],
                                                "mtime": mt})
                        continue
                    res["files"] += 1
                    if res["mtime"] is None or mt > res["mtime"]:
                        res["mtime"], res["path"] = mt, p
                    if newer_than is not None and mt > newer_than:
                        res["newer"].append({"path": rel, "mtime": mt})
    except OSError as e:
        res["error"] = "%s: %s" % (type(e).__name__, e)
    return res


def build_source_roots(repo, rest):
    """The union of source roots for everything `rest` will build.

    `(roots, why_empty)`. Empty roots is NOT "no sources changed" -- it is "I
    do not know what this target reads", and every caller must print that
    rather than pass.
    """
    arts, why = target_artifacts(repo, rest)
    if arts is None:
        return [], why
    roots, whys = [], []
    for a in arts:
        r, w = artifact_source_roots(repo, a)
        for x in r:
            if x not in roots:
                roots.append(x)
        if w:
            whys.append(w)
    if not roots:
        return [], "; ".join(whys) or "no source roots could be derived"
    return roots, ""


def source_change_check(repo, roots, why_empty, acquired_at, before=None,
                        slack=SOURCE_CHANGE_SLACK):
    """Did a source move UNDER this build? -> a dict with `state`.

    ## The defect this exists for

    MEASURED 2026-09-03 ~19:24: `buildlock.py build host` reported success
    (exit 0, sidecar written) for a build whose sources were edited AFTER the
    lock was acquired -- source mtimes 19:24, lock acquired 19:22:39. The DLL
    was a PRE-EDIT snapshot, and `grep -a` found ZERO of the seven literals
    the edit had added. Every downstream check then measured the wrong file:
    marker-checking an artifact that does not contain the change you are
    looking for is the silent-wrong-answer class this repo treats as worst
    case, because the marker verdict is confident and the bytes are stale.

    The lock serialises BUILDS, not EDITS (see the module docstring), and it
    should not try to stop anyone editing. What it must not do is call the
    result a success.

    ## Three states, never two

    * `unchanged`     -- the walk completed and nothing under the roots is
                         newer than the acquire instant. This is the only pass.
    * `CHANGED`       -- named files, with mtimes. Refusal, exit 15.
    * `not-performed` -- the roots could not be derived, or the walk was
                         truncated or errored. It NEVER refuses (a build that
                         is genuinely fine must not be blocked by a scan that
                         could not look) and it NEVER reads as a pass: it is
                         printed as NOT PERFORMED and recorded in the sidecar
                         as `source_check: "not-performed"` so a later verifier
                         knows the question was not answered.

    `before` is the acquire-time scan (same roots), carried only so the report
    can say what the newest source was when the build started.
    """
    res = {"state": "not-performed", "why": "", "roots": list(roots),
           "files": [], "cutoff": acquired_at,
           "before_newest": (before or {}).get("mtime"),
           "before_path": (before or {}).get("path"),
           "scan": None}
    if not roots:
        res["why"] = ("this target's source roots could not be derived (%s), "
                      "so 'no source changed during the build' was NOT "
                      "ESTABLISHED" % (why_empty or "no reason recorded"))
        return res
    gen, gen_notes = generated_sources(repo)
    scan = newest_source(repo, roots, generated=gen,
                         newer_than=acquired_at + slack)
    res["scan"] = scan
    res["generated_notes"] = gen_notes
    if scan["error"] or scan["truncated"]:
        res["why"] = ("the source scan of %s did NOT COMPLETE (%s), so "
                      "'nothing changed during the build' was NOT ESTABLISHED"
                      % (", ".join(scan["roots"]),
                         scan["error"] or "time budget exceeded"))
        return res
    if scan["newer"]:
        res["state"] = "CHANGED"
        res["files"] = sorted(scan["newer"], key=lambda r: -r["mtime"])
        res["why"] = ("%d source file(s) under %s were modified after the "
                      "lock was acquired" % (len(scan["newer"]),
                                             ", ".join(scan["roots"])))
        return res
    res["state"] = "unchanged"
    res["why"] = ("all %d source file(s) under %s predate the acquire instant "
                  "(%d build output(s) excluded)"
                  % (scan["files"], ", ".join(scan["roots"]),
                     len(scan.get("excluded") or [])))
    return res


def source_change_lines(chg, acquired_at):
    """What the build prints about its own inputs."""
    when = time.strftime("%H:%M:%S", time.localtime(acquired_at))
    if chg["state"] == "CHANGED":
        out = ["", "SOURCES CHANGED DURING THE BUILD: %s" % chg["why"],
               "  the lock was acquired at %s; these are NEWER, so the "
               "artifact is a snapshot of the tree BEFORE them:" % when]
        for f in chg["files"][:20]:
            out.append("    %s   mtime %s"
                       % (f["path"], time.strftime("%H:%M:%S",
                                                   time.localtime(f["mtime"]))))
        if len(chg["files"]) > 20:
            out.append("    ... and %d more" % (len(chg["files"]) - 20))
        out.append("  THIS IS NOT A SUCCESS. Marker-checking these bytes would "
                   "measure the pre-edit build; the sidecar is flagged "
                   "stale_sources and deploy.py will refuse it. Re-run the "
                   "build.")
        out.append("  exit %d (sources changed during the build)"
                   % SOURCES_CHANGED_EXIT)
        return out
    if chg["state"] == "not-performed":
        return ["  SOURCE-CHANGE CHECK NOT PERFORMED: %s. Exit 0 above is a "
                "claim about the build, not about which revision of the "
                "sources it compiled." % chg["why"]]
    return ["  sources unchanged during the build (acquired %s): %s"
            % (when, chg["why"])]


def deploy_artifacts(repo):
    """Every declared artifact, from `tools/deploy.json`. `(arts, None)` or
    `(None, why)`.

    deploy.json is the ONE place this repo declares where an artifact is built,
    and `aowl`'s own `buildDeploySet` reads the same `src` fields. Nothing here
    keeps a second list of paths: a hardcoded copy would rot the day someone
    adds an artifact, and would then report a PASS for a target whose real
    output it had never heard of.

    It is read from `<repo>/tools/deploy.json` -- the checkout being BUILT --
    and there is deliberately no fallback to the copy beside this file. A
    `--repo` pointing somewhere without one is not a repo whose artifacts this
    file can name, and answering from another checkout's declarations would be
    a check performed against the wrong tree.
    """
    p = os.path.join(repo, "tools", "deploy.json")
    if not os.path.exists(p):
        return None, ("%s does not exist, so nothing declares what `%s` is "
                      "supposed to produce" % (p, repo))
    try:
        with open(p, "r", encoding="utf-8-sig") as f:
            cfg = json.load(f)
    except Exception as e:
        return None, "%s could not be read (%s: %s)" % (p, type(e).__name__, e)
    arts = [a for a in cfg.get("artifacts", [])
            if isinstance(a, dict) and a.get("name") and a.get("src")
            and not str(a["name"]).startswith("//")]
    if not arts:
        return None, "%s declares no artifacts" % p
    return arts, None


def target_artifacts(repo, rest):
    """Which declared artifacts `aowl <rest>` is supposed to produce.

    Returns `(artifacts, None)` or `(None, why)`. The mapping is the INVERSE of
    `buildDeploySet` in tools/aowl.nim, which maps a deploy.json `src` onto a
    build step; here a build target selects the `src` values that step writes.

    `(None, why)` is a real outcome and must never be reported as a pass:
    `build sim`, `build test X`, `build settings` and friends declare no
    artifact in deploy.json at all, so nothing about them can be checked, and
    the caller prints NOT PERFORMED.
    """
    arts, err = deploy_artifacts(repo)
    if arts is None:
        return None, err
    words = [w for w in rest if not w.startswith("-")]
    if not words or words[0] != "build":
        return None, ("%r is not a `build` command, so it declares no artifact"
                      % " ".join(rest))
    target = words[1].lower() if len(words) > 1 else ""
    name = words[2] if len(words) > 2 else ""

    def pick(pred):
        return [a for a in arts if pred(_norm(a["src"]))]

    if target in ("host", "il2cpp"):
        sel = pick(lambda s: s.startswith("host/Aowlspt.Host.Il2Cpp/bin/"))
    elif target == "backend":
        sel = pick(lambda s: s.startswith("backend/bin/"))
    elif target in ("launch", "launcher"):
        sel = pick(lambda s: s == "installer/build/aowlspt-launch.exe")
    elif target in ("mod", "mods"):
        if name:
            want = [n.strip() for n in name.split(",") if n.strip()]
            sel = pick(lambda s: any(s.startswith("mods/%s/bin/" % n)
                                     for n in want))
        elif target == "mods":
            sel = pick(lambda s: s.startswith("mods/") and "/bin/" in s)
        else:
            return None, "`build mod` with no name builds nothing"
    elif target == "examples":
        sel = pick(lambda s: s.startswith("examples/") and "/bin/" in s)
    elif target == "deploy":
        sel = list(arts)
    else:
        return None, ("`build %s` names no artifact in tools/deploy.json "
                      "(it knows: host, backend, launch, mod NAME, mods, "
                      "examples, deploy)" % (target or "<nothing>"))
    if not sel:
        return None, ("tools/deploy.json declares no artifact built by `%s`"
                      % " ".join(words[:3]))
    return sel, None


def is_build_output(rel):
    """Is this path WRITTEN by a build, or is it checked-in data that a build
    only ships? `registry/mods.json` is the second kind: it exists before any
    build and its mtime says nothing, so the staleness rule must not be applied
    to it or every `build deploy` would refuse."""
    s = _norm(rel)
    return "/bin/" in s or s.startswith("installer/build/")


def missing_declared_input(repo, art):
    """`(path, why)` when the artifact declares an input that is ABSENT.

    Same `requiresInput` field `deploy.py` reads, resolved against `repo` so a
    worktree (or a test) answers about itself. `.cache/global-metadata.dec.dat`
    is not shared between worktrees, and without it `aowl build host` produces
    the host DLL but no name index -- an absence that is explained, not a
    dropped feature, and reporting it as ABSENT would be a false refusal.
    """
    req = art.get("requiresInput") or {}
    rel = req.get("path") or ""
    if not rel:
        return None
    full = os.path.join(repo, _norm(rel).replace("/", os.sep))
    if os.path.exists(full):
        return None
    return rel, req.get("why", "")


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def artifact_status(repo, art, started=None, want_sha=True):
    """One artifact, measured. States: ok / absent / stale / input-missing /
    unreadable.

    `started` is the moment the build began. An artifact older than that was
    written by an EARLIER build: exactly the case measured five times on
    2026-09-02, where a queued build removed the file, failed, and left the
    previous one's verifier reading either nothing or something it did not
    build.
    """
    rel = _norm(art["src"])
    full = os.path.join(repo, rel.replace("/", os.sep))
    rec = {"name": art.get("name"), "src": rel, "path": full,
           "state": "unreadable", "why": "", "size": None, "sha256": None,
           "mtime": None, "built": is_build_output(rel),
           "mtime_checked": False}
    if not os.path.exists(full):
        mi = missing_declared_input(repo, art)
        if mi:
            rec["state"] = "input-missing"
            rec["why"] = ("its declared input %s is absent (%s) -- the build "
                          "could not produce it, so this was NOT CHECKED"
                          % (mi[0], mi[1]))
        else:
            rec["state"] = "absent"
            rec["why"] = "nothing at %s" % full
        return rec
    try:
        stt = os.stat(full)
    except OSError as e:
        rec["why"] = "stat failed (%s: %s) -- NOT CHECKED" % (
            type(e).__name__, e)
        return rec
    rec["size"], rec["mtime"] = stt.st_size, stt.st_mtime
    unwritten = (started is not None and rec["built"]
                 and stt.st_mtime < started - ARTIFACT_MTIME_SLACK)
    if started is not None and rec["built"]:
        rec["mtime_checked"] = True
    try:
        rec["sha256"] = sha256_file(full) if (want_sha or unwritten) else None
    except OSError as e:
        rec["why"] = "could not be hashed (%s: %s) -- NOT CHECKED" % (
            type(e).__name__, e)
        return rec
    if unwritten:
        # MEASURED 2026-09-02: a no-op `build host` (41s, nothing changed,
        # aowl left the existing DLL alone) exited 6 ARTIFACT STALE purely
        # because the mtime predated the build. That is a FALSE REFUSAL: the
        # build was asked to make the artifact current and the artifact IS
        # current. STALE now means what it says -- a source is newer than the
        # artifact and this build did not rewrite it.
        #
        # UP-TO-DATE needs BOTH halves, and the asymmetry is deliberate:
        # everything unproven falls through to STALE, so a scan that could not
        # complete refuses rather than passing.
        side = read_sidecar(full)
        roots, why_empty = artifact_source_roots(repo, art)
        gen, gen_notes = generated_sources(repo)
        src = newest_source(repo, roots, generated=gen) if roots else None
        rec["sources"] = src
        rec["generated_notes"] = gen_notes
        when = time.strftime("%H:%M:%S", time.localtime(stt.st_mtime))
        if not side or not side.get("sha256"):
            rec["state"] = "stale"
            rec["why"] = ("this build did not write it (mtime %s, %.0fs before "
                          "the build started) and there is NO SIDECAR beside "
                          "it, so which build produced these bytes is UNKNOWN"
                          % (when, started - stt.st_mtime))
        elif side.get("sha256") != rec["sha256"]:
            rec["state"] = "stale"
            rec["why"] = ("this build did not write it (mtime %s) and its "
                          "sha %s does NOT match the sidecar's %s -- something "
                          "replaced it outside this lock"
                          % (when, rec["sha256"][:12],
                             str(side.get("sha256"))[:12]))
        elif src is None:
            rec["state"] = "stale"
            rec["why"] = ("this build did not write it (mtime %s) and its "
                          "source inputs could not be identified (%s), so "
                          "'nothing is newer' was NOT ESTABLISHED"
                          % (when, why_empty))
        elif src["error"] or src["truncated"]:
            rec["state"] = "stale"
            rec["why"] = ("this build did not write it (mtime %s) and the "
                          "source scan of %s did NOT COMPLETE (%s) -- refusing "
                          "rather than assuming nothing is newer"
                          % (when, ", ".join(src["roots"]),
                             src["error"] or "time budget exceeded"))
        elif src["mtime"] is not None and src["mtime"] > stt.st_mtime:
            rec["state"] = "stale"
            rec["why"] = ("%s was modified %s, AFTER the artifact's mtime %s, "
                          "and this build did not rewrite the artifact"
                          % (_norm(os.path.relpath(src["path"], repo)),
                             time.strftime("%H:%M:%S",
                                           time.localtime(src["mtime"])),
                             when))
        else:
            rec["state"] = "up-to-date"
            rec["why"] = ("this build wrote nothing, and nothing needed "
                          "writing: all %d source file(s) under %s are older "
                          "than the artifact (mtime %s), %d build output(s) "
                          "were excluded, and its sha %s is byte-identical to "
                          "the sidecar pid %s wrote"
                          % (src["files"], ", ".join(src["roots"]), when,
                             len(src.get("excluded") or []),
                             rec["sha256"][:12], side.get("pid")))
        return rec
    rec["state"] = "ok"
    return rec


def artifact_exit(recs):
    """The exit code for a set of artifact records. ABSENT outranks STALE
    because it is the stronger statement; both refuse.

    `up-to-date` is a PASS: the build wrote nothing because nothing needed
    writing, and refusing that was a false alarm (see artifact_status)."""
    if any(r["state"] == "absent" for r in recs):
        return ARTIFACT_ABSENT_EXIT
    if any(r["state"] == "stale" for r in recs):
        return ARTIFACT_STALE_EXIT
    return 0


def excluded_lines(rec):
    """What the staleness scan REFUSED to call a source, and why.

    Printed for both verdicts on purpose. An exclusion narrows what STALE can
    detect, so it must be visible in the passing case (where it did the work)
    and in the refusing case (where the reader needs to know it was not the
    reason). Silence would make the exclusion set unauditable.
    """
    out = []
    src = rec.get("sources") or {}
    for e in src.get("excluded") or []:
        out.append("                 excluded from the staleness scan: %s "
                   "(mtime %s) -- %s"
                   % (e["path"],
                      time.strftime("%H:%M:%S", time.localtime(e["mtime"])),
                      e["why"] or "declared a build output in "
                                  "tools/deploy.json generatedSources"))
    for n in rec.get("generated_notes") or []:
        out.append("                 note: %s" % n)
    return out


def artifact_lines(recs):
    """What the build prints about its own outputs. Every state says which it
    is; `input-missing` and `unreadable` say NOT CHECKED in as many words,
    because 'I could not look' must never be readable as 'it is there'."""
    out = []
    for r in recs:
        if r["state"] == "ok":
            out.append("  %-14s %s   %d bytes   sha256 %s"
                       % (r["name"], r["src"], r["size"], r["sha256"]))
        elif r["state"] == "up-to-date":
            out.append("  UP-TO-DATE     %s (%s)   %d bytes   sha256 %s"
                       % (r["name"], r["src"], r["size"], r["sha256"]))
            out.append("                 %s" % r["why"])
            out.extend(excluded_lines(r))
        elif r["state"] == "absent":
            out.append("  BUILT BUT ARTIFACT ABSENT: %s (%s) -- %s"
                       % (r["name"], r["src"], r["why"]))
        elif r["state"] == "stale":
            out.append("  ARTIFACT STALE (mtime before build start): %s (%s) "
                       "-- %s" % (r["name"], r["src"], r["why"]))
            out.extend(excluded_lines(r))
        else:
            out.append("  artifact check NOT PERFORMED for %s (%s) -- %s"
                       % (r["name"], r["src"], r["why"]))
    return out


def sidecar_path(artifact_path):
    return artifact_path + SIDECAR_SUFFIX


def read_sidecar(artifact_path):
    try:
        with open(sidecar_path(artifact_path), "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def write_sidecar(rec, target, started, finished, git_head, src_change=None):
    """Record WHICH bytes this build produced, beside the artifact.

    The point is not bookkeeping. A verifier that opens the DLL minutes later
    has no way to tell whether it is reading the build it thinks it is; with
    this it can. Written only for build OUTPUTS (all of which live in
    gitignored `bin/` or `installer/build/`), never beside checked-in data.
    """
    doc = {"target": target, "artifact": rec["src"], "sha256": rec["sha256"],
           "size": rec["size"], "mtime": rec["mtime"],
           "started": started, "finished": finished,
           "started_h": time.strftime("%Y-%m-%d %H:%M:%S",
                                      time.localtime(started)),
           "finished_h": time.strftime("%Y-%m-%d %H:%M:%S",
                                       time.localtime(finished)),
           "pid": os.getpid(), "git_head": git_head}
    # WHICH REVISION OF THE SOURCES these bytes are. `stale_sources` true means
    # a source was edited after the lock was acquired, so the artifact predates
    # that edit; deploy.py refuses on it. The field is written in EVERY state
    # (including "not-performed") so that its absence means "built by a
    # buildlock too old to know", never "checked and clean".
    if src_change is not None:
        doc["source_check"] = src_change["state"]
        doc["stale_sources"] = src_change["state"] == "CHANGED"
        doc["source_check_why"] = src_change.get("why", "")
        if src_change.get("files"):
            doc["sources_changed"] = [
                {"path": f["path"],
                 "mtime_h": time.strftime("%Y-%m-%d %H:%M:%S",
                                          time.localtime(f["mtime"]))}
                for f in src_change["files"][:50]]
    p = sidecar_path(rec["path"])
    tmp = p + ".tmp%d" % os.getpid()
    try:
        with open(tmp, "w", encoding="utf-8", newline="\n") as f:
            json.dump(doc, f, indent=1, sort_keys=True)
        os.replace(tmp, p)
    except OSError as e:
        print("  (could not write %s: %s -- a later verifier will report NO "
              "SIDECAR, not a pass)" % (p, e))
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return None
    return doc


def stage_artifacts(repo, rest, recs):
    """Copy every artifact this build proved into `.stage/`, and say where.

    MEASURED 2026-09-04 08:58: a clean `build host` finished, and before the
    deploy could copy the DLL a queued build took the lock and `aowl` removed
    it. The deploy refused (correctly) and the launcher ran the OLD host. The
    bytes existed and were good for a few seconds and then did not exist at
    all.

    A staging failure is printed and does NOT fail the build: the artifact is
    still in `bin/` and still deployable the old way. Silence is what is
    forbidden -- an unexplained absent stage is how somebody concludes the
    build never happened.
    """
    out = []
    for r in recs:
        if r["state"] not in ("ok", "up-to-date") or not r["built"]:
            continue
        rec, why = stagemod.put(repo, " ".join(rest), r["path"],
                                artifact_src=r["src"], name=r["name"])
        if rec:
            out.append("  staged %s -> %s   (sha %s)"
                       % (r["name"], _norm(os.path.relpath(rec["path"], repo)),
                          rec["sha"]))
        else:
            out.append("  NOT STAGED %s: %s" % (r["name"], why))
            out.append("    a deploy will have to read %s directly, where a "
                       "concurrent build can delete it mid-copy." % r["src"])
    return out


def check_and_record(repo, rest, started, finished, no_sidecar=False,
                     src_change=None, no_stage=False):
    """Post-build: did the thing we asked for actually appear? Returns an exit
    code -- 0, ARTIFACT_ABSENT_EXIT or ARTIFACT_STALE_EXIT."""
    arts, why = target_artifacts(repo, rest)
    if arts is None:
        print("ARTIFACT CHECK NOT PERFORMED: %s. Exit 0 above means the build "
              "command succeeded; it is NOT evidence that a file exists."
              % why)
        return 0
    recs = [artifact_status(repo, a, started) for a in arts]
    rc = artifact_exit(recs)
    if rc:
        print("")
        print("REFUSING TO REPORT SUCCESS -- the build exited 0 but its "
              "declared artifact(s) are not there:")
    for ln in artifact_lines(recs):
        print(ln)
    if rc:
        print("  a build's exit 0 is not the artifact's existence. `aowl` "
              "REMOVES its output before writing it, so a later build that "
              "fails leaves the previous one's file deleted.")
        print("  exit %d (%s)" % (rc, "artifact absent"
                                  if rc == ARTIFACT_ABSENT_EXIT else
                                  "artifact stale"))
        return rc
    if no_sidecar:
        return 0
    head, _err = _git(repo, ["rev-parse", "HEAD"])
    head = head.strip() if head else None
    for r in recs:
        if r["state"] == "ok" and r["built"]:
            write_sidecar(r, " ".join(rest), started, finished, head,
                          src_change)
    if no_stage:
        print("  --no-stage: these bytes were NOT copied to .stage/, so a "
              "deploy must read bin/ and a concurrent build can delete the "
              "file first (measured 2026-09-04).")
        return 0
    for ln in stage_artifacts(repo, rest, recs):
        print(ln)
    return 0


VERIFY_TAG = {VERIFY_MATCH_EXIT: "MATCH",
              VERIFY_REPLACED_EXIT: "REPLACED",
              VERIFY_ABSENT_EXIT: "ABSENT",
              VERIFY_NO_SIDECAR_EXIT: "NO SIDECAR"}


def verify_one(repo, art, expect=None):
    """`(code, lines)` for one artifact against its sidecar."""
    rec = artifact_status(repo, art, started=None)
    side = read_sidecar(rec["path"])
    if rec["state"] == "absent":
        return VERIFY_ABSENT_EXIT, [
            "  ABSENT      %s (%s) -- nothing is there now.%s"
            % (rec["name"], rec["src"],
               ("  It existed when pid %s finished %r at %s (sha %s)."
                % (side.get("pid"), side.get("target"), side.get("finished_h"),
                   str(side.get("sha256"))[:12])) if side else
               "  No sidecar either, so it was never built through this lock.")]
    if rec["state"] in ("input-missing", "unreadable"):
        return VERIFY_NO_SIDECAR_EXIT, [
            "  NOT PERFORMED %s (%s) -- %s" % (rec["name"], rec["src"],
                                               rec["why"])]
    if expect:
        if rec["sha256"] == expect:
            return VERIFY_MATCH_EXIT, [
                "  MATCH       %s (%s) is the build you named (sha %s, %d "
                "bytes)" % (rec["name"], rec["src"], rec["sha256"][:12],
                            rec["size"])]
        lines = ["  REPLACED    %s (%s): the file on disk is sha %s, you "
                 "expected %s" % (rec["name"], rec["src"], rec["sha256"][:12],
                                  expect[:12])]
        if side and side.get("sha256") == rec["sha256"]:
            lines.append("              the bytes there now were written by "
                         "pid %s building %r, finished %s"
                         % (side.get("pid"), side.get("target"),
                            side.get("finished_h")))
        elif side:
            lines.append("              the sidecar records sha %s from pid "
                         "%s at %s, which matches NEITHER -- something wrote "
                         "the file without going through this lock"
                         % (str(side.get("sha256"))[:12], side.get("pid"),
                            side.get("finished_h")))
        else:
            lines.append("              there is no sidecar, so who wrote "
                         "these bytes is UNKNOWN")
        return VERIFY_REPLACED_EXIT, lines
    if not side:
        return VERIFY_NO_SIDECAR_EXIT, [
            "  NO SIDECAR  %s (%s) exists (sha %s) but was not built through "
            "this lock, so there is nothing to compare it with. Not a pass."
            % (rec["name"], rec["src"], rec["sha256"][:12])]
    if side.get("sha256") == rec["sha256"]:
        return VERIFY_MATCH_EXIT, [
            "  MATCH       %s (%s) is byte-identical to the build pid %s "
            "finished at %s (sha %s, %d bytes)"
            % (rec["name"], rec["src"], side.get("pid"),
               side.get("finished_h"), rec["sha256"][:12], rec["size"])]
    return VERIFY_REPLACED_EXIT, [
        "  REPLACED    %s (%s): sha %s now, but the sidecar recorded %s from "
        "pid %s building %r at %s -- something overwrote it without going "
        "through this lock"
        % (rec["name"], rec["src"], rec["sha256"][:12],
           str(side.get("sha256"))[:12], side.get("pid"), side.get("target"),
           side.get("finished_h"))]


def cmd_verify_artifact(repo, rest):
    """`verify-artifact <target> [--expect SHA256]`.

    Answers ONE question: is the file I am about to verify the build I think
    it is? MATCH 0 / REPLACED 2 / ABSENT 3 / NO SIDECAR 5.
    """
    words, expect = [], None
    it = iter(rest[1:])
    for w in it:
        if w in ("--expect", "--expect-sha"):
            expect = next(it, None)
        elif w.startswith("--expect="):
            expect = w.split("=", 1)[1]
        else:
            words.append(w)
    if not words:
        print("verify-artifact needs a target, e.g. "
              "`python tools/buildlock.py verify-artifact host`")
        return 2
    if expect:
        expect = expect.strip().lower()
    arts, why = target_artifacts(repo, ["build"] + words)
    if arts is None:
        print("NOT PERFORMED: %s" % why)
        return VERIFY_NO_SIDECAR_EXIT
    print("verify-artifact %s (%d declared artifact(s))"
          % (" ".join(words), len(arts)))
    worst, seen = VERIFY_MATCH_EXIT, []
    for a in arts:
        code, lines = verify_one(repo, a, expect)
        seen.append(code)
        for ln in lines:
            print(ln)
    for code in (VERIFY_ABSENT_EXIT, VERIFY_REPLACED_EXIT,
                 VERIFY_NO_SIDECAR_EXIT):
        if code in seen:
            worst = code
            break
    print("verdict: %s (exit %d)" % (VERIFY_TAG.get(worst, "?"), worst))
    return worst


# ---------------------------------------------------------------------------
# PRE-FLIGHT LINT, and reading a compiler-internal crash for what it is
# ---------------------------------------------------------------------------
#
# MEASURED 2026-09-01, 19:49 -> 22:26: every host and backend build in this
# checkout died inside nimony's hexer with `getOrQuit: missing key` and NOTHING
# else -- no file, no line, no symbol. Two and a half hours went into bisecting
# it. The cause was two lines in host/common/jsonpath.nim (`import
# aowlspt/jsonpath` + `export jsonpath`), which a 200ms grep can see.
#
# So two things happen here, and they are different:
#
#   * BEFORE the lock is taken, `tools/nimlint.py` scans the tree. A build that
#     is going to die this way should not first wait forty minutes in a queue
#     and then occupy the build slot for four. Refusal is exit 7, and
#     `--no-lint` is the escape.
#   * AFTER a build fails, the OUTPUT is read. A failure that names no file is
#     a categorically different event from a failure that names one, and
#     reporting it as an ordinary nonzero exit is how the 2.5 hours started --
#     the session read "build failed" and went looking for its own mistake.
#
# The build's output has to be captured to do the second, so it is TEE'd: every
# byte still reaches stdout, and the last LOG_RING lines are kept for the scan.
# Note that `aowl` writes nothing to a redirected stream until it exits
# (CLAUDE.md records this), so piping does not make progress reporting worse
# than it already was -- but it does not make it better either.

LINT_EXIT = 7
DRAIN_EXIT = 9
    # DISTINCT from LINT_EXIT on purpose. The two pre-flights refuse for
    # completely different reasons -- nimlint refuses a shape that kills the
    # COMPILER, drainaudit refuses a shape that kills the CLIENT -- and a
    # caller (or a script, or the next session) that cannot tell them apart
    # will fix the wrong thing. 8 is already the internal-crash code.
INTERNAL_CRASH_EXIT = 8
GATE_EXIT = 11
    # X1: a token-gated il2cpp export bound or called outside the armed path.
SEH_EXIT = 12
    # D8: a nested `aowl_p_p_seh`.
FLAG_EXIT = 13
    # D10: a feature flag that defaults ON without an allowlist entry.
STORE_EXIT = 14
    # M3/M6: a raw store into game-owned memory outside the typed FieldRef
    # path. Its own code, like the four above, because a caller that cannot
    # tell these apart fixes the wrong thing.
    # Each pre-flight gets its OWN code for the reason DRAIN_EXIT does: a
    # caller that cannot tell them apart fixes the wrong thing.
LOG_RING = 4000

CRASH_LINE = ("COMPILER-INTERNAL CRASH (no file named): run "
              "tools/nimlint.py; last time this was a whole-module re-export "
              "and cost 2.5 hours")

# `getOrQuit: missing key` is the measured signature and never carries a
# location. The others are shapes that MAY name a file, so they only count as
# an internal crash when nothing in the output names a file that exists.
CRASH_HARD = ("getOrQuit: missing key",)
CRASH_SOFT = ("unhandled exception", "Traceback (most recent call last)",
              "internal error:", "SIGSEGV", "fatal error: cannot open",
              "Error: internal error")

# `foo.nim(2051, 5)` / `foo.nim(149)` -- nim's own location syntax.
NIM_LOC_RE = re.compile(r"([A-Za-z0-9_.\-]+\.nim)\((\d+)")


def repo_nim_basenames(repo, limit=20000):
    """Every .nim basename in the checkout, for deciding whether an error
    location names OUR code or the COMPILER's own source.

    `nifcursors.nim(149)` is a location, and a naive "did it name a file?"
    test reads it as one -- but it is a file inside nimony, and a crash inside
    the compiler's error renderer is exactly the event this is trying to
    distinguish. Measured 2026-09-01 (commit 531498a's message): five build
    variants all died at `nifcursors.nim(149)` while formatting a message for
    a real error they never printed.
    """
    names = set()
    skip = {"build", "bin", "nimcache", ".git", "__pycache__", ".cache",
            "node_modules", ".aowl"}
    for dirpath, dirnames, filenames in os.walk(repo):
        dirnames[:] = [d for d in dirnames if d not in skip]
        for fn in filenames:
            if fn.endswith(".nim"):
                names.add(fn.lower())
                if len(names) >= limit:
                    return names
    return names


def internal_crash_verdict(text, repo=None, known=None):
    """Did the compiler die WITHOUT naming a file of ours?

    Returns a dict: crash (bool), markers (which signatures matched),
    located (locations that name a file in this checkout), foreign (locations
    that name something else -- i.e. compiler internals).
    """
    low = text.lower()
    hard = [m for m in CRASH_HARD if m.lower() in low]
    soft = [m for m in CRASH_SOFT if m.lower() in low]
    if known is None:
        known = repo_nim_basenames(repo) if repo else set()
    located, foreign = [], []
    for m in NIM_LOC_RE.finditer(text):
        (located if m.group(1).lower() in known else foreign).append(
            "%s(%s)" % (m.group(1), m.group(2)))
    return {"crash": bool(hard) or (bool(soft) and not located),
            "markers": hard + soft,
            "located": located[:8], "foreign": foreign[:8]}


def print_internal_crash(ev, repo, out=None):
    """The distinct report. It says what to run next, and it also says when
    nimlint has NOTHING -- because a clean lint after this signature means the
    shape is NEW, and a silent lint would read as reassurance."""
    w = (out.write if out is not None
         else (lambda s: sys.stdout.write(s)))
    w(CRASH_LINE + "\n")
    w("    signature: %s\n" % ", ".join(ev["markers"]))
    if ev["foreign"]:
        w("    the only locations printed are INSIDE THE COMPILER (%s) -- "
          "not your source\n" % ", ".join(ev["foreign"]))
    else:
        w("    no source location was printed at all\n")
    res, err = lint_scan(repo)
    if res is None:
        w("    nimlint: NOT PERFORMED (%s) -- this is not a clean result\n"
          % err)
        return
    if res.errors:
        w("    nimlint found %d error(s):\n" % len(res.errors))
        for f in res.errors:
            w("      %s:%d  %s\n" % (f.rel, f.line, f.pattern["id"]))
    else:
        w("    nimlint is CLEAN (%d files, %d warning(s)) -- so this is a "
          "shape it does not know yet. Minimise it and add a PATTERNS entry; "
          "do not spend 2.5 hours the way the last one did.\n"
          % (res.files, len(res.warnings)))


def lint_scan(repo):
    """(ScanResult, None) or (None, why-not). Importing nimlint is allowed to
    fail: a missing linter must NOT block builds, but it must also never be
    reported as a clean lint."""
    try:
        if HERE not in sys.path:
            sys.path.insert(0, HERE)
        import nimlint  # noqa: E402
    except Exception as e:                      # pragma: no cover
        return None, "tools/nimlint.py unimportable: %s" % e
    try:
        return nimlint.scan(list(nimlint.DEFAULT_ROOTS), repo=repo), None
    except Exception as e:                      # pragma: no cover
        return None, "nimlint raised %s: %s" % (type(e).__name__, e)


def lint_preflight(repo, strict=False, out=None):
    """0 = go, LINT_EXIT = refuse. Prints its reasoning either way."""
    w = out.write if out is not None else (lambda s: sys.stdout.write(s))
    res, err = lint_scan(repo)
    if res is None:
        w("nimlint PRE-FLIGHT NOT PERFORMED: %s. The build is NOT being "
          "vouched for; it is only not being blocked.\n" % err)
        return 0
    bad = list(res.errors) + (list(res.warnings) if strict else [])
    # A finding is checked FIRST. An incomplete scan that also found a fatal
    # shape must refuse, not shrug -- "inconclusive" is for a scan that found
    # nothing while being unable to look everywhere.
    if not bad:
        if res.could_not_scan:
            w("nimlint PRE-FLIGHT INCONCLUSIVE: %s. Not a pass; building "
              "anyway.\n"
              % ("; ".join(res.missing_roots + [u[0] for u in res.unreadable])))
        return 0
    w("BUILD REFUSED BEFORE THE LOCK: tools/nimlint.py found %d finding(s) "
      "that make nimony die without naming a file.\n\n" % len(bad))
    for f in bad:
        w(f.human() + "\n\n")
    w("Nothing was built and no lock was taken. Fix the finding, or "
      "`--no-lint` if you are certain this is not it (and then say so).\n")
    return LINT_EXIT


def drain_preflight(repo, out=None):
    """0 = go, DRAIN_EXIT = refuse. Prints its reasoning either way.

    `tools/drainaudit.py` refuses a POSTFIX host detour on a call that uses
    more than four register slots. That shape does not fail the build and does
    not fail a marker check: it builds cleanly, deploys cleanly, and then kills
    the client -- measured 2026-09-02, three consecutive boots dead in
    `SeasonWidgetData::From` because the postfix thunk fed
    `EFT.UI.MenuScreen::Show(5-arg)` its own frame where argument five belongs.

    So the refusal is here, BEFORE the lock, next to nimlint and for the same
    reason: a build that must not be deployed should not first spend forty
    minutes in a queue and then occupy the one serial resource in the checkout.

    INCONCLUSIVE (exit 3, the metadata inputs absent) does NOT refuse the
    build. It says so instead. Refusing every build on a machine without
    GameAssembly.dll would make `--no-drain-audit` the default incantation,
    which is the outcome this whole pre-flight exists to prevent -- but an
    unchecked build is never reported as a checked one.
    """
    w = out.write if out is not None else (lambda s: sys.stdout.write(s))
    import io as _io
    try:
        sys.path.insert(0, os.path.join(repo, "tools"))
        import drainaudit                                   # noqa: E402
    except Exception as e:
        w("drainaudit PRE-FLIGHT NOT PERFORMED: tools/drainaudit.py "
          "unimportable (%s). The build is NOT being vouched for; it is only "
          "not being blocked.\n" % e)
        return 0
    buf = _io.StringIO()
    try:
        rc = drainaudit.audit(repo, drainaudit.GAMEASM_DEFAULT,
                              drainaudit.METADEC_DEFAULT, quiet=False)
    except Exception as e:
        w("drainaudit PRE-FLIGHT NOT PERFORMED: it raised %s: %s. Not a "
          "pass; building anyway.\n" % (type(e).__name__, e))
        return 0
    finally:
        buf.close()
    if rc == drainaudit.INCONCLUSIVE:
        w("drainaudit PRE-FLIGHT INCONCLUSIVE: the metadata inputs are "
          "absent, so declared register-slot counts were not cross-checked. "
          "Not a pass; building anyway.\n")
        return 0
    if rc != 0:
        w("\nBUILD REFUSED BEFORE THE LOCK: tools/drainaudit.py found a "
          "POSTFIX detour on a call with STACK arguments (or a slot count it "
          "could not check). That shape builds and deploys cleanly and then "
          "kills the client.\n"
          "Nothing was built and no lock was taken. Fix the site, or "
          "`--no-drain-audit` if you are certain this is not it (and then say "
          "so).\n")
        return DRAIN_EXIT
    return 0


FIRST_LOC = re.compile(r"((?:[\w./\\-]+\.(?:nim|h|c|json))(?::\d+)?)")


def invariant_preflight(repo, module, invariant, exit_code, skip_flag,
                        out=None, kwargs=None):
    """One offline invariant, refused BEFORE the lock. 0 = go, exit_code = no.

    Same place and same reasoning as the nimlint and drainaudit pre-flights:
    a build that must not be deployed should not first spend forty minutes in
    the queue and then hold the one serial resource in the checkout while it
    fails. These three refuse shapes that kill the CLIENT (X1, D8) or ship an
    unproven path to every user (D10) -- none of which the compiler can see.

    INCONCLUSIVE never refuses. It says, in full, that the check was NOT
    PERFORMED, because "I could not look" must never read as a pass and a gate
    that refuses on a machine missing an input becomes the flag everyone
    passes.
    """
    w = out.write if out is not None else (lambda s: sys.stdout.write(s))
    import io as _io
    try:
        sys.path.insert(0, os.path.join(repo, "tools"))
        mod = __import__(module)
    except Exception as e:
        w("%s PRE-FLIGHT NOT PERFORMED: tools/%s.py unimportable (%s). The "
          "build is NOT being vouched for; it is only not being blocked.\n"
          % (module, module, e))
        return 0
    buf = _io.StringIO()
    try:
        old, sys.stdout = sys.stdout, buf
        try:
            rc = mod.audit(repo, **(kwargs or {}))
        finally:
            sys.stdout = old
    except Exception as e:
        w("%s PRE-FLIGHT NOT PERFORMED: it raised %s: %s. Not a pass; "
          "building anyway.\n" % (module, type(e).__name__, e))
        return 0
    text = buf.getvalue()
    w(text)
    if rc == mod.INCONCLUSIVE:
        w("%s PRE-FLIGHT INCONCLUSIVE: %s was NOT checked. Not a pass; "
          "building anyway.\n" % (module, invariant))
        return 0
    if rc != 0:
        # The first file:line AFTER the FAIL header -- sehnest's finding line
        # is a call CHAIN and carries its location in the sentence below it,
        # so scanning only the "FAIL" line itself would print a refusal that
        # names no file at all.
        at = text.find("FAIL --")
        m = FIRST_LOC.search(text[at:] if at >= 0 else text)
        where = m.group(1) if m else ""
        w("\nBUILD REFUSED BEFORE THE LOCK: %s -- %s. Nothing was built and no "
          "lock was taken. Fix it, or `%s` if you are certain this is not it "
          "(and then say so).\n" % (invariant, where or "see the finding(s) "
                                    "above", skip_flag))
        return exit_code
    return 0


def run_teed(cmd, cwd, env, ring=LOG_RING):
    """Run the build, pass its output straight through, and keep the tail.

    Returns (returncode, text). Decoding is errors='replace' -- a compiler that
    emits one bad byte must not turn into a python traceback here, which would
    be this script losing the build instead of the build failing.
    """
    from collections import deque
    p = subprocess.Popen(cmd, cwd=cwd, env=env, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT)
    tail = deque(maxlen=ring)
    while True:
        raw = p.stdout.readline()
        if not raw:
            break
        line = raw.decode("utf-8", "replace")
        sys.stdout.write(line)
        sys.stdout.flush()
        tail.append(line)
    p.stdout.close()
    return p.wait(), "".join(tail)


def aowl_exe(repo):
    p = os.path.join(repo, "installer", "build", "aowl.exe")
    return p if os.path.exists(p) else "aowl"


NO_DRIVER_EXIT = 16


def resolve_command(repo, rest):
    """(cmd, message, exit_code) -- what to actually run for `rest`.

    MEASURED 2026-09-04: with no `installer\\build\\aowl.exe` (the normal state
    of a FRESH worktree -- that directory is gitignored), `aowl_exe` fell back
    to the bare name "aowl", nothing on PATH provides it, and
    `subprocess.Popen` raised FileNotFoundError [WinError 2] out of `main`.
    A python traceback where a build verdict belongs is unreadable, and worse,
    it happened for `bootstrap` -- the ONE verb whose entire purpose is to
    create the missing driver. The chicken-and-egg is not real:
    `tools\\bootstrap.ps1` compiles `tools\\aowl.nim` with nimony directly and
    needs no driver, so bootstrap runs THAT, still under this script's lock.

    Any other target with no driver is a refusal that names the fix, not a
    traceback and not a silent PATH guess.
    """
    exe = os.path.join(repo, "installer", "build", "aowl.exe")
    if os.path.exists(exe):
        return [exe] + list(rest), "", 0
    onpath = shutil.which("aowl")
    if rest and rest[0] == "bootstrap":
        ps1 = os.path.join(repo, "tools", "bootstrap.ps1")
        if not os.path.exists(ps1):
            return None, ("there is no installer\\build\\aowl.exe and no "
                          "tools\\bootstrap.ps1 in %s, so there is no way to "
                          "build the driver from here. NOTHING WAS RUN."
                          % repo), NO_DRIVER_EXIT
        return (["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
                 "-File", ps1] + list(rest[1:])),\
               ("no installer\\build\\aowl.exe: bootstrapping through "
                "tools\\bootstrap.ps1, which compiles tools\\aowl.nim with "
                "nimony directly (no driver needed). The lock is held for it."),\
               0
    if onpath:
        return [onpath] + list(rest), "", 0
    return None, ("there is no installer\\build\\aowl.exe in %s and no `aowl` "
                  "on PATH, so %r cannot be run. NOTHING WAS RUN and no lock "
                  "was taken. Build the driver first: `python "
                  "tools/buildlock.py bootstrap`. (Do NOT copy aowl.exe from "
                  "another checkout -- it runs THAT checkout's tools/aowl.nim.)"
                  % (repo, " ".join(rest))), NO_DRIVER_EXIT


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
    p.add_argument("--check-hung", action="store_true",
                   help="with --status: take BOTH cpu samples now (blocks one "
                        "--hung-window) instead of sampling across calls, and "
                        "ignore --hung-after")
    p.add_argument("--break-hung", action="store_true", dest="break_hung",
                   help="if the holder looks HUNG for --hung-strikes "
                        "consecutive windows, kill its process tree and take "
                        "the lock. OFF by default; it logs what it killed.")
    p.add_argument("--no-hung-check", action="store_true", dest="no_hung",
                   help="do not look at whether the holder is progressing at "
                        "all (detection only; nothing is ever killed without "
                        "--break-hung)")
    p.add_argument("--hung-window", type=float, default=DEFAULT_HUNG_WINDOW,
                   metavar="SECONDS",
                   help="seconds between the two cpu samples (default %d)"
                        % DEFAULT_HUNG_WINDOW)
    p.add_argument("--hung-cpu", type=float, default=DEFAULT_HUNG_CPU,
                   metavar="SECONDS",
                   help="tree cpu below this in one window counts as no "
                        "progress (default %.1f)" % DEFAULT_HUNG_CPU)
    p.add_argument("--hung-strikes", type=int, default=DEFAULT_HUNG_STRIKES,
                   metavar="N",
                   help="consecutive hung windows before --break-hung acts "
                        "(default %d)" % DEFAULT_HUNG_STRIKES)
    p.add_argument("--hung-after", type=float, default=DEFAULT_HUNG_AFTER,
                   metavar="SECONDS",
                   help="do not hang-check a holder younger than this "
                        "(default %d)" % DEFAULT_HUNG_AFTER)
    p.add_argument("--no-artifact-check", action="store_true",
                   dest="no_artifact_check",
                   help="do not check that the target's declared artifact(s) "
                        "exist after a successful build, and write no "
                        "sidecar. The check is what turns exit 0 into "
                        "evidence; turning it off means the exit code is a "
                        "claim about the build PROCESS only.")
    p.add_argument("--no-stage", action="store_true", dest="no_stage",
                   help="do NOT copy the built artifact into .stage/. The "
                        "deploy then reads bin/, where a queued build can "
                        "delete it mid-copy (measured 2026-09-04).")
    p.add_argument("--no-source-check", action="store_true",
                   dest="no_source_check",
                   help="do not check whether a source was edited AFTER the "
                        "lock was acquired. With it off, exit 0 stops being "
                        "evidence that the artifact contains your edit "
                        "(measured 2026-09-03: it did not).")
    p.add_argument("--no-lint", action="store_true", dest="no_lint",
                   help="skip the tools/nimlint.py pre-flight. The pre-flight "
                        "refuses (exit %d) BEFORE taking the lock when the "
                        "tree holds a shape measured to kill nimony without "
                        "naming a file." % LINT_EXIT)
    p.add_argument("--no-drain-audit", action="store_true",
                   dest="no_drain_audit",
                   help="skip the tools/drainaudit.py pre-flight. It refuses "
                        "(exit %d -- NOT %d, they are different faults) "
                        "BEFORE taking the lock when a host detour would "
                        "POSTFIX a call whose arguments do not all fit in "
                        "registers." % (DRAIN_EXIT, LINT_EXIT))
    p.add_argument("--no-gate-audit", action="store_true", dest="no_gate_audit",
                   help="skip the tools/gateaudit.py pre-flight (X1). It "
                        "refuses with exit %d when a TOKEN-GATED il2cpp "
                        "export is bound or called outside aowl_gate_call."
                        % GATE_EXIT)
    p.add_argument("--no-seh-audit", action="store_true", dest="no_seh_audit",
                   help="skip the tools/sehnest.py pre-flight (D8). It "
                        "refuses with exit %d when a guarded body reaches a "
                        "second aowl_p_p_seh." % SEH_EXIT)
    p.add_argument("--no-flag-audit", action="store_true", dest="no_flag_audit",
                   help="skip the tools/flagaudit.py pre-flight (D10). It "
                        "refuses with exit %d when a host feature flag "
                        "defaults ON without an allowlisted reason."
                        % FLAG_EXIT)
    p.add_argument("--no-store-audit", action="store_true",
                   dest="no_store_audit",
                   help="skip the tools/storelint.py pre-flight (M3/M6). It "
                        "refuses with exit %d when a raw store into "
                        "game-owned memory appears outside the typed FieldRef "
                        "path in hostfieldwrite.nim." % STORE_EXIT)
    p.add_argument("--lint-strict", action="store_true", dest="lint_strict",
                   help="the pre-flight refuses on nimlint WARNINGS too "
                        "(three exist in this tree today, in code that "
                        "builds)")
    p.add_argument("--no-snapshot", action="store_true",
                   help="skip the working-tree snapshot taken around the "
                        "build (it costs two `git status` calls and is only "
                        "printed when the build FAILS)")
    p.add_argument("rest", nargs=argparse.REMAINDER,
                   help="the aowl arguments, e.g. `build host`")
    a = p.parse_args()

    path = lock_path(a.repo)
    hopts = hung_opts(repo=a.repo, enabled=not a.no_hung,
                      break_hung=a.break_hung, window=a.hung_window,
                      cpu=a.hung_cpu, strikes=a.hung_strikes,
                      after=a.hung_after)

    if a.status:
        st = status(path, a.max_age)
        if hopts["enabled"] and st["state"] == "held":
            st["hung"] = hung_check(path, a.repo, st, a.hung_window,
                                    a.hung_cpu, a.check_hung, a.hung_after,
                                    a.hung_strikes)
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
        st = wait_free(path, a.max_age, a.wait_free,
                       announce=not a.json, hopts=hopts)
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

    if rest[0] == "verify-artifact":
        # A QUESTION, not a build: it takes no lock and runs nothing, so it is
        # safe to ask while somebody else is building (and answering it while
        # a build runs is exactly when it is worth asking).
        return cmd_verify_artifact(a.repo, rest)

    # BEFORE the lock, deliberately. A build that cannot succeed should not
    # first spend forty minutes in the queue -- and it should not hold the one
    # serial resource in the checkout while it fails.
    if not a.no_lint:
        lrc = lint_preflight(a.repo, strict=a.lint_strict)
        if lrc:
            return lrc
    # Same place, same reason, different fault: nimlint refuses a shape that
    # kills the COMPILER, drainaudit refuses one that kills the CLIENT. The
    # second cannot be caught by building, so it has to be caught here.
    if not a.no_drain_audit:
        drc = drain_preflight(a.repo)
        if drc:
            return drc
    # Three more offline invariants from docs/INTERACTION-LAYER-MAP.md 7.1,
    # each with its OWN exit code so a script can tell them apart.
    for enabled, module, invariant, code, flag, kw in (
            (not a.no_gate_audit, "gateaudit",
             "X1 (a token-gated il2cpp export bound or called outside "
             "aowl_gate_call, which returns MT19937-64 output that passes a "
             "nil check)", GATE_EXIT, "--no-gate-audit", None),
            (not a.no_seh_audit, "sehnest",
             "D8 (a nested aowl_p_p_seh -- the inner guard DISARMS the outer "
             "one)", SEH_EXIT, "--no-seh-audit", None),
            (not a.no_flag_audit, "flagaudit",
             "D10 (a feature flag that defaults ON with no allowlist entry in "
             "tools/deploy.json flagDefaultsOn)", FLAG_EXIT, "--no-flag-audit",
             None),
            (not a.no_store_audit, "storelint",
             "M3/M6 (a raw store into game-owned memory outside the typed "
             "FieldRef path -- a bare offset guarded only by readability, "
             "which cannot fail on the IL2CPP GC heap)", STORE_EXIT,
             "--no-store-audit", {"quiet": True})):
        if not enabled:
            continue
        rc = invariant_preflight(a.repo, module, invariant, code, flag,
                                 kwargs=kw)
        if rc:
            return rc

    cmd, why, drc = resolve_command(a.repo, rest)
    if cmd is None:
        print("BUILD REFUSED: %s" % why)
        return drc
    if why:
        print(why, flush=True)
    if not acquire(path, " ".join(rest), a.wait, a.max_age, a.steal,
                   hopts):
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
        # Taken AFTER the "ACQUIRED" line so the two snapshots bracket exactly
        # the interval the child runs in, and before the child starts so the
        # child's own outputs are not mistaken for someone's edit.
        before = tree_snapshot(a.repo) if not a.no_snapshot else None
        # The acquire-time source scan. Taken here, in the same instant the
        # child starts, so "newer than the acquire time" means exactly that.
        src_roots, src_why = ([], "--no-source-check was passed, so nothing "
                                  "was scanned")
        src_before = None
        if not a.no_source_check:
            src_roots, src_why = build_source_roots(a.repo, rest)
            if src_roots:
                gen, _n = generated_sources(a.repo)
                src_before = newest_source(a.repo, src_roots, generated=gen)
        rc, build_text = run_teed(cmd, a.repo, env)
    finally:
        release(path)
    finished = time.time()
    print("%r finished in %.0fs with exit %d (lock released)"
          % (" ".join(rest), finished - t0, rc))
    # "the build failed" and "the COMPILER died and could not say where" are
    # different events, and reporting the second as the first is what turned a
    # two-line source bug into 2.5 hours on 2026-09-01.
    if rc != 0:
        ev = internal_crash_verdict(build_text, repo=a.repo)
        if ev["crash"]:
            print_internal_crash(ev, a.repo)
            if before is not None:
                print_concurrent_edits(before, tree_snapshot(a.repo))
            return INTERNAL_CRASH_EXIT
    # Only on FAILURE. A green build printing a list of other agents' edits
    # would train everyone to ignore the block, and the block is only worth
    # anything if seeing it means something.
    if rc != 0 and before is not None:
        print_concurrent_edits(before, tree_snapshot(a.repo))
    # Did the sources move under us? Asked on SUCCESS only: a failed build's
    # exit code is already telling the truth, and the failure path prints the
    # concurrent-edit block above. On success the exit code is a claim, and
    # this is the half of that claim nobody was checking.
    srcchg = None
    if rc == 0 and not a.no_source_check:
        srcchg = source_change_check(a.repo, src_roots, src_why, t0,
                                     src_before)
        for ln in source_change_lines(srcchg, t0):
            print(ln)
    if rc == 0 and not a.no_artifact_check:
        # The build said it worked. That is a claim about a PROCESS. Whether a
        # file exists is a different question, and it is the one the caller
        # actually asked -- measured five times on 2026-09-02 answering `ok`
        # for an artifact a queued build had already deleted.
        arc = check_and_record(a.repo, rest, t0, finished,
                               src_change=srcchg, no_stage=a.no_stage)
        if arc:
            return arc
    # AFTER the artifact check, so the sidecar carries the flag before we
    # refuse: the artifact exists and somebody will look at it, and the whole
    # point is that what they find beside it says these bytes predate an edit.
    if srcchg is not None and srcchg["state"] == "CHANGED":
        return SOURCES_CHANGED_EXIT
    return rc


if __name__ == "__main__":
    sys.exit(main())
