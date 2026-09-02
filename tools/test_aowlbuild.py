#!/usr/bin/env python3
"""Does `aowl build` REFUSE the things it must refuse?

Three refusals, each of which used to be either impossible to reach or a
warning that scrolled past:

  1. `aowl build mod nosuchmod`  -- an unknown mod name, refused BY NAME and
     before anything is compiled. `build mod`/`build mods A,B` are new: until
     2026-09-02 the only serialisable way to rebuild one mod was `build mods`
     (all 22, ~10 minutes for a one-line change) or a hand-run nimony, which
     is the unserialised path CLAUDE.md section 3 forbids.
  2. `aowl build test nosuchtest` -- likewise for the per-test target.
  3. a STALE DRIVER -- `aowl.exe` not built from this worktree's
     `tools/aowl.nim`. That was a warning printed above four minutes of `ok`
     lines, and it has bitten three agents: a build step defined on the
     current source silently does not run. It is now exit 4.

Every check has a control that CAN fail, because the failure mode here is a
refusal that refuses everything -- `build mod maps` erroring too would make
checks 1 and 2 pass while the feature is useless. So:

  * the unknown-name refusal must LIST the real mods (so it enumerated them),
  * `build mods maps,nosuchmod` must refuse without compiling maps,
  * and the stale-driver refusal is run twice: once refusing (exit 4), once
    with `--allow-stale-driver`, which must get PAST it and fail for the
    other reason (exit 1). If the second run also returned 4, the flag does
    nothing and the first result proves nothing.

It runs `aowl` through `tools/buildlock.py`, like everything else that builds
in this checkout -- these invocations compile nothing, but they take the same
lock and so cannot interleave with a real build.

Exit 0 PASS, 1 FAIL, 3 INCONCLUSIVE (no driver, or a driver this test may not
trust).
"""

from __future__ import annotations

import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
BL = os.path.join(HERE, "buildlock.py")
AOWL = os.path.join(REPO, "installer", "build", "aowl.exe")
STAMP = os.path.join(REPO, "installer", "build", ".aowlstamp")

FAILURES = []


def check(name, cond, detail=""):
    print("  %-4s %s" % ("ok" if cond else "FAIL", name))
    if not cond:
        if detail:
            print("       %s" % detail)
        FAILURES.append(name)
    return cond


def aowl(*args, timeout=600):
    """Through the lock, always. Returns (rc, output)."""
    r = subprocess.run([sys.executable, BL, "--wait", "1800"] + list(args),
                       cwd=REPO, capture_output=True, text=True,
                       timeout=timeout)
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def main():
    if not os.path.exists(AOWL):
        print("INCONCLUSIVE: no %s -- run `python tools/buildlock.py "
              "bootstrap` first. Nothing was tested." % AOWL)
        return 3

    print("aowl build: refusals")

    t0 = time.time()
    rc, out = aowl("build", "mod", "nosuchmod")
    check("`build mod nosuchmod` exits non-zero", rc != 0, "rc=%d" % rc)
    check("...and says WHICH name it could not find",
          "no such mod: nosuchmod" in out,
          "output did not name it: %r" % out[-400:])
    # The control: a refusal that lists no mods would refuse a real name too.
    check("...and lists the mods that DO exist (so it enumerated them)",
          "mods here:" in out and " maps" in out,
          "no mod list in the refusal: %r" % out[-400:])
    check("...and compiled nothing", "mod maps" not in out.replace(
        "mods here:", ""), "something was built: %r" % out[-400:])
    print("       (%.1fs)" % (time.time() - t0))

    rc, out = aowl("build", "mods", "maps,nosuchmod")
    check("`build mods maps,nosuchmod` refuses the WHOLE list before "
          "building the good one", rc != 0 and "no such mod: nosuchmod" in out,
          "rc=%d out=%r" % (rc, out[-400:]))

    rc, out = aowl("build", "test", "nosuchtest")
    check("`build test nosuchtest` exits non-zero", rc != 0, "rc=%d" % rc)
    check("...and says WHICH test it could not find",
          "no such test target: nosuchtest" in out,
          "output did not name it: %r" % out[-400:])
    check("...and lists the test targets that DO exist",
          "mapsdiag" in out, "no target list: %r" % out[-400:])

    rc, out = aowl("build", "mod")
    check("`build mod` with no name refuses rather than building all of them",
          rc != 0 and "needs a name" in out, "rc=%d out=%r" % (rc, out[-300:]))

    print("\naowl build: the stale-driver gate")
    if not os.path.exists(STAMP):
        check("INCONCLUSIVE: no .aowlstamp, so the gate could not be "
              "exercised either way", False,
              "bootstrap writes it; without it every build already refuses")
        return 1 if FAILURES else 0

    with open(STAMP, "rb") as f:
        saved = f.read()
    try:
        with open(STAMP, "wb") as f:
            f.write(b"0")   # a stamp that cannot match any source hash
        rc, out = aowl("build", "mod", "nosuchmod")
        check("a stale driver REFUSES with exit 4",
              rc == 4 and "REFUSED" in out, "rc=%d out=%r" % (rc, out[-400:]))
        check("...and points at the bootstrap command",
              "buildlock.py bootstrap" in out, out[-400:])
        rc2, out2 = aowl("build", "mod", "nosuchmod", "--allow-stale-driver")
        # The control. If this ALSO returned 4 the flag is dead and the check
        # above is not evidence about the gate, only about the exit code.
        check("--allow-stale-driver gets PAST the gate (fails for the other "
              "reason instead)",
              rc2 == 1 and "no such mod: nosuchmod" in out2,
              "rc=%d out=%r" % (rc2, out2[-400:]))
    finally:
        with open(STAMP, "wb") as f:
            f.write(saved)

    rc, out = aowl("build", "mod", "nosuchmod")
    check("the stamp was restored, so ordinary builds are not refused",
          rc == 1 and "REFUSED" not in out, "rc=%d out=%r" % (rc, out[-300:]))

    print("\n%s -- %d failure(s)"
          % ("FAIL" if FAILURES else "PASS", len(FAILURES)))
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
