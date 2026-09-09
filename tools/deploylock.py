#!/usr/bin/env python3
r"""deploylock.py -- run deploy.py while HOLDING the build lock.

    python tools/deploylock.py deploy host,launch
    python tools/deploylock.py check --only host
    python tools/deploylock.py markers --for host
    python tools/deploylock.py markers <worktree>/mods/maps/bin/maps.dll -s x

## Why

`aowl` removes its output before writing it, so an artifact vanishes for the
whole of a build. With several agents queued on the build lock, the lock is
released and re-taken within a second, and a `deploy.py deploy host` issued in
that second reads a half-written or absent DLL. Measured 2026-09-01, twice: the
deploy correctly refused ("a BUILD IS IN PROGRESS"), but the coordinator's live
pass died with it, and the next free window never came because the FIFO queue
was five deep.

Holding the same lock while deploying makes the copy atomic with respect to
builds: nothing can start under it, and a queued build simply waits the few
seconds a deploy takes. deploy.py itself is unchanged and still verifies every
marker before copying.

## The stage closes the other half of the same race

MEASURED 2026-09-04 08:58: a clean `build host` finished and released the lock;
before this script could copy the DLL, a queued `build host` took the lock and
`aowl` deleted the artifact. Holding the lock for the copy does not help when
the file is already gone. `tools/buildlock.py` now copies every artifact it
proves into `.stage/<target>/<sha12>/`, and `deploy.py` deploys from there --
so the bytes cannot vanish between the build and the deploy. Everything here is
unchanged; `--sha PREFIX` and `--stage-only` pass straight through to
deploy.py.

## `markers` -- the same race, one command down

MEASURED 2026-09-02: `python tools/markers.py
host/Aowlspt.Host.Il2Cpp/bin/aowlspt-host-il2cpp.dll ...` answered
INCONCLUSIVE "no such file" because a build had the lock and had already
removed its output. That answer is honest -- markers.py refuses rather than
reporting MISSING -- but it is a wasted check, and an agent re-running it hits
the same window again.

`markers` runs `tools/markers.py` under the build lock, so the read cannot
land inside a build's delete-then-write window. It queues exactly like
`deploy` does.

**It takes the lock only when it has to.** The build lock is the one genuinely
serial resource here, and a worktree DLL, a scratch build or `--list-artifacts`
has nothing to do with this checkout's builds -- locking for those would make
a marker check a reason somebody's build is queued. So the target path is
resolved first and compared with the artifacts declared in this checkout's
`tools/deploy.json`; anything else runs immediately and says why no lock was
taken. A target that cannot be resolved at all is INDETERMINATE and DOES take
the lock: the safe direction is the slow one.
"""

from __future__ import annotations

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import buildlock  # noqa: E402

# markers.py options whose VALUE is a literal or a number, never the artifact.
# Mis-classifying one of these as the target could only ever take the lock
# unnecessarily (slow, safe); missing the real target would skip the lock
# (fast, unsafe), so the target scan below errs toward locking.
MARKERS_VALUE_OPTS = {"-s", "--string", "--absent", "--control", "-f",
                      "--markers-file", "--min-markers", "--encoding"}
# These read no artifact at all.
MARKERS_NO_READ = {"--list-artifacts", "--selftest", "-h", "--help"}


def _split_opt(a):
    if a.startswith("--") and "=" in a:
        k, v = a.split("=", 1)
        return k, v
    return a, None


def markers_targets(repo, args):
    """(paths, why) -- which file(s) `markers.py <args>` is going to READ.

    `paths` are absolute. `why` is non-empty when the answer is INDETERMINATE,
    and the caller must then lock rather than guess: a check that skips the
    lock because it could not work out what it was reading is precisely the
    race this mode exists to close.
    """
    paths, i = [], 0
    for a in args:
        k, _v = _split_opt(a)
        if k in MARKERS_NO_READ:
            return [], ""
    while i < len(args):
        a = args[i]
        k, v = _split_opt(a)
        if k in MARKERS_VALUE_OPTS:
            i += 2 if v is None else 1
            continue
        if k in ("--artifact", "--for"):
            val = v if v is not None else (args[i + 1] if i + 1 < len(args)
                                           else None)
            i += 2 if v is None else 1
            if val is None:
                return [], "%s was given no value" % k
            if k == "--artifact":
                paths.append(os.path.abspath(val))
            else:
                try:
                    import markers  # noqa: WPS433 -- optional, see below
                    dll, _m, _e, _p = markers.resolve_for(val)
                    paths.append(os.path.abspath(dll))
                except Exception as e:
                    return paths, ("--for %s could not be resolved to a file "
                                   "(%s: %s)" % (val, type(e).__name__, e))
            continue
        if a.startswith("-"):
            i += 1
            continue
        # The first bare token is markers.py's `dll` positional; the rest are
        # marker literals.
        if not paths:
            paths.append(os.path.abspath(a))
        i += 1
    if not paths:
        return [], "no artifact path could be identified on the command line"
    return paths, ""


def declared_artifact_paths(repo):
    """Absolute paths of every artifact THIS checkout builds, or (None, why)."""
    arts, err = buildlock.deploy_artifacts(repo)
    if arts is None:
        return None, err
    out = {}
    for a in arts:
        rel = str(a["src"]).replace("/", os.sep)
        full = os.path.normcase(os.path.abspath(os.path.join(repo, rel)))
        out[full] = a.get("name")
    return out, ""


def markers_needs_lock(repo, args):
    """(bool, reason). Three inputs, three answers -- and the indeterminate
    one locks, because being slow is recoverable and racing a build is not."""
    paths, why = markers_targets(repo, args)
    if why:
        return True, ("the target could not be determined (%s), so the lock "
                      "is taken rather than assumed unnecessary" % why)
    if not paths:
        return False, ("this command reads no artifact, so no build can race "
                       "it")
    declared, derr = declared_artifact_paths(repo)
    if declared is None:
        return True, ("this checkout's declared artifacts could not be read "
                      "(%s), so whether %s is one of them is UNKNOWN -- "
                      "locking" % (derr, paths[0]))
    hits = [p for p in paths
            if os.path.normcase(os.path.abspath(p)) in declared]
    if hits:
        return True, ("%s is an artifact this checkout builds (%s), and `aowl` "
                      "removes its output before writing it"
                      % (hits[0], declared[os.path.normcase(
                          os.path.abspath(hits[0]))]))
    return False, ("%s is not an artifact declared in %s/tools/deploy.json -- "
                   "no build in this checkout writes it, so there is nothing "
                   "to serialise against" % (paths[0], repo))


def run_markers(repo, argv, wait_s):
    lock = buildlock.lock_path(repo)
    need, why = markers_needs_lock(repo, argv)
    cmd = [sys.executable, os.path.join(HERE, "markers.py")] + argv
    if not need:
        print("NO BUILD LOCK TAKEN: %s" % why, flush=True)
        return subprocess.run(cmd, cwd=repo).returncode
    print("taking the build lock for a marker check: %s" % why, flush=True)
    if not buildlock.acquire(lock, "markers " + " ".join(argv), wait_s,
                             buildlock.DEFAULT_MAX_AGE, False,
                             buildlock.hung_opts(repo=repo, break_hung=False)):
        print("REFUSED: the build lock was not acquired within %.0fs. NOTHING "
              "WAS CHECKED -- this is not a MISSING and not a PRESENT."
              % wait_s)
        return 4
    try:
        print("build lock ACQUIRED for markers (builds wait)", flush=True)
        return subprocess.run(cmd, cwd=repo).returncode
    finally:
        buildlock.release(lock)


def main():
    repo = buildlock.REPO
    argv = sys.argv[1:] or ["check"]
    # `--repo` / `--wait` are OURS and are consumed here; everything after the
    # sub-command goes to deploy.py or markers.py verbatim. They are only
    # accepted BEFORE the sub-command, so a `--repo` meant for the child is
    # never swallowed.
    wait_s = 1800.0
    while argv and argv[0] in ("--repo", "--wait"):
        if len(argv) < 2:
            print("usage: deploylock.py [--repo DIR] [--wait S] "
                  "deploy|check|markers ...")
            return 2
        if argv[0] == "--repo":
            repo = os.path.abspath(argv[1])
        else:
            try:
                wait_s = float(argv[1])
            except ValueError:
                print("--wait wants seconds, got %r" % argv[1])
                return 2
        argv = argv[2:]
    if not argv:
        argv = ["check"]
    if argv[0] == "markers":
        return run_markers(repo, argv[1:], wait_s)
    lock = buildlock.lock_path(repo)
    # deploy.py now gates a deploy on `selftests.py --fast` (~60 s). Run it
    # BEFORE taking the lock, not under it: the build lock is the one genuinely
    # serial resource in this repo, and holding it for a minute of python tests
    # would make the gate the reason somebody's build is queued. The run writes
    # .aowl-selftests.json, so deploy.py's own gate finds a green cache for the
    # same HEAD+tree and returns immediately -- the suite is not run twice.
    if argv and argv[0] == "deploy" and "--no-selftest" not in argv:
        rc = subprocess.run([sys.executable,
                             os.path.join(HERE, "selftests.py"), "--fast"],
                            cwd=repo).returncode
        if rc != 0:
            print("refusing to take the build lock: selftests.py --fast "
                  "exited %d. Nothing was deployed and no build was blocked."
                  % rc)
            return 1
    # Detection ON, killing OFF. A deploy is the LAST thing that should be
    # given a licence to kill somebody's build, but it is very often the
    # process sitting behind a stopped one -- the 25-minute wait that produced
    # the hang detector was exactly this shape. Without hopts this waiter goes
    # through the same loop with the check disabled and says nothing at all.
    if not buildlock.acquire(lock, "deploy " + " ".join(argv), wait_s,
                             buildlock.DEFAULT_MAX_AGE, False,
                             buildlock.hung_opts(repo=repo, break_hung=False)):
        return 4
    try:
        print("build lock ACQUIRED for deploy (builds wait)", flush=True)
        return subprocess.run([sys.executable, os.path.join(HERE, "deploy.py")]
                              + argv, cwd=repo).returncode
    finally:
        buildlock.release(lock)


if __name__ == "__main__":
    sys.exit(main())
