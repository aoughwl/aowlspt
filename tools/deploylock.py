#!/usr/bin/env python3
r"""deploylock.py -- run deploy.py while HOLDING the build lock.

    python tools/deploylock.py deploy host,launch
    python tools/deploylock.py check --only host

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
"""

from __future__ import annotations

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import buildlock  # noqa: E402


def main():
    repo = buildlock.REPO
    lock = buildlock.lock_path(repo)
    argv = sys.argv[1:] or ["check"]
    if not buildlock.acquire(lock, "deploy " + " ".join(argv), 1800.0,
                             buildlock.DEFAULT_MAX_AGE, False):
        return 4
    try:
        print("build lock ACQUIRED for deploy (builds wait)", flush=True)
        return subprocess.run([sys.executable, os.path.join(HERE, "deploy.py")]
                              + argv, cwd=repo).returncode
    finally:
        buildlock.release(lock)


if __name__ == "__main__":
    sys.exit(main())
