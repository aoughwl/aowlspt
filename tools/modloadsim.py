#!/usr/bin/env python3
r"""modloadsim.py -- drive the mod loading step through a WHOLE lifecycle.

    python tools/modloadsim.py                  15 mods, ~0.6s each, then READY
    python tools/modloadsim.py --fail sain      one mod FAILED (panel must stay)
    python tools/modloadsim.py --step 0.2       faster
    python tools/modloadsim.py --hold 20        park mid-build for 20s first

## Why a tool, and not a hand-written file

The host renders `aowlspt-modload.txt` verbatim: line 0 = current action (with
the control words `MODS READY` / `FAILED`), line 1 = overall progress, line 2 =
the current step. The real writer is `tools/modbuild.py`. To see the step
without a real build, the obvious move is to hand-write that file -- and that
was done THREE times in one session, each time as a frozen mid-build state with
no `MODS READY`, and each time the user reported it as a bug: "still stuck on 7
of 15", "still doing mod 7 or 15...".

From where the user sits a frozen input is indistinguishable from a hang. Worse,
a frozen fixture never reaches the paths that matter -- the completion marker,
the dismissal, the teardown sweep -- which is exactly where the real bug was.

So this drives the file through the whole lifecycle: N steps, each written
atomically (temp + os.replace, so the host never reads a half-file), then the
terminal marker. The only way to leave it frozen is `--hold`, which says so on
stdout and still finishes afterwards.

## What to read back afterwards

    python tools/hostlog.py grep "mod loading step" --max 12

Expected on a healthy run, in order: `BUILT` (or `RE-STYLED` / `STEP-PARENTED`
when the game's own caption is found), a `dismissed` line after READY, and the
survivor sweep reaching `EXHAUSTIVE` with zero `aowlspt-modload*` nodes. With
`--fail`, the panel must STAY up naming the failed mod -- that is the one
outcome worth reading and the host keeps it on screen on purpose.
"""

from __future__ import annotations

import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import modloadfmt  # noqa: E402 -- the ONE renderer, shared with modbuild.py

DEFAULT_PATH = r"D:\Aowlspt\aowlspt\aowlspt-modload.txt"

MODS = ["tarkov", "manager", "sain", "morebots", "fov", "settingshub",
        "uihub", "admin", "admintrader", "graphics", "textures", "maps",
        "debug", "waypoints", "ammoloading"]


# The three-line format and the atomic write both come from `modloadfmt`, the
# same module `tools/modbuild.py` renders through. They used to be two copies,
# and the copies had already drifted on line endings (this one LF, modbuild
# CRLF) without either being able to see it. A simulator that renders a
# DIFFERENT file from the real writer proves nothing about the real writer.
write = modloadfmt.write


def main():
    p = argparse.ArgumentParser(
        description="drive aowlspt-modload.txt through a complete build lifecycle",
        formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    p.add_argument("--path", default=DEFAULT_PATH)
    p.add_argument("--step", type=float, default=0.6, help="seconds per mod")
    p.add_argument("--fail", default=None, metavar="MOD",
                   help="mark this mod FAILED; the panel must then stay up")
    p.add_argument("--hold", type=float, default=0.0,
                   help="park at mod 7 for this many seconds BEFORE finishing "
                        "(for looking at the mid-build state). Still finishes.")
    a = p.parse_args()

    mods = MODS
    n = len(mods)
    t0 = time.time()
    for i, m in enumerate(mods, 1):
        cached = (i % 3 == 0)
        st = "cached" if cached else "building"
        detail = "from cache" if cached else "compiling"
        if a.fail == m:
            st, detail = "FAILED", "nimony exited 1"
        write(a.path, modloadfmt.building(m, i, n, st, detail))
        print("  %2d/%d  %-14s %s" % (i, n, m, st), flush=True)
        if a.hold and i == 7:
            print("  -- HOLDING at 7/%d for %.0fs (deliberate; will finish) --"
                  % (n, a.hold), flush=True)
            time.sleep(a.hold)
        time.sleep(a.step)

    if a.fail:
        # "FAILED" MUST be on line 0: that is the host's control word for
        # "keep this on screen and say so in the log".
        write(a.path, modloadfmt.ready(n, n, [a.fail]))
        print("MODS READY -- 1 FAILED written (%s). The panel must STAY UP "
              "naming it; that is the intended behaviour." % a.fail)
    else:
        write(a.path, modloadfmt.ready(n, n))
        print("MODS READY written after %.1fs. The panel must now dismiss; "
              "read back with:  python tools/hostlog.py grep \"mod loading "
              "step\" --max 12" % (time.time() - t0))
    return 0


if __name__ == "__main__":
    sys.exit(main())
