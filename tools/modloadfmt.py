#!/usr/bin/env python3
r"""modloadfmt.py -- the ONE renderer for `aowlspt-modload.txt`.

The in-game mod-loading step is a plain-text file the host renders VERBATIM.
It is exactly three lines and the host parses nothing but two control words on
line 0:

    line 0   WHAT IT IS DOING NOW, and the control line.
             starts with "MODS READY"  -> the build is finished; release the
                                          mods and dismiss the step
             contains  "FAILED"        -> it finished badly; keep it up longer
                                          and shout it into the log
    line 1   OVERALL progress          e.g. "Mods 7 of 15"
    line 2   the CURRENT STEP          e.g. "maps  building  12s"

    Loading mods: maps
    Mods 7 of 15
    maps  building

Keep this in step with the header comment of
`host/Aowlspt.Host.Il2Cpp/modload.nim`, which documents the same format from
the reading end.

## Why this is a module and not three lines in each writer

There are three writers, and there were two independent implementations:

  * `tools/modbuild.py` -- the real one, driven by an actual compile;
  * `tools/modloadsim.py` -- the synthetic driver, which exists because a
    HAND-WRITTEN fixture was left frozen mid-build three times in one session
    and the user reported it as a bug each time;
  * `tools/aowllaunch.nim` -- the launcher, which writes the opening state
    before it spawns the builder (see below). That one cannot share Python
    code, so its format is asserted against this module by
    `tools/test_modloadfmt.py` instead.

The two Python writers had drifted already, in a way neither could see: the
simulator wrote LF (`newline="\n"`) and modbuild wrote CRLF (Python's text
mode translates on Windows). The host strips `\r` when it splits, so nothing
broke live -- but the two files were not byte-identical for the same state,
which is precisely the drift a shared renderer exists to prevent, and the next
difference might not have been one the host tolerated.

## The stale-READY hazard, which is why `queued` exists

The file survives a reboot. If a previous session left `MODS READY` in it and
the next boot's builder has not written anything yet, the host reads a READY
that belongs to the LAST run, releases the mods immediately and dismisses a
step for a build that is still starting. So whoever starts a build must write
`queued(...)` FIRST, synchronously, before the client can read it -- and that
is a different thing from truncating the file, because an empty file has no
defined meaning to the host.
"""

from __future__ import annotations

import os

STATUS_W = 9
ROWS = 3


def queued(n=None, detail="starting the compiler"):
    """The opening state: a build is about to begin. Overwrites any stale
    `MODS READY` from a previous session, which is the whole point."""
    return ["Loading mods...",
            "Mods 0 of %s" % (n if n is not None else "?"),
            detail]


def building(mod, i, n, status="building", extra=""):
    """One mod is being worked on."""
    return ["Loading mods: %s" % mod if mod else "Loading mods...",
            "Mods %d of %d" % (i, n),
            ("%-14s %-*s %s" % (mod, STATUS_W, status, extra)).strip()]


def ready(done, n, failed=()):
    """The terminal state. `failed` is the mod names that did not compile.

    "MODS READY" is on line 0 in BOTH cases on purpose: a build that finished
    with failures is still finished, and withholding the mods that DID build
    helps nobody. The word FAILED on the same line is what makes the host keep
    the line on screen longer and record it in the log."""
    failed = sorted(failed)
    if failed:
        return ["MODS READY -- %d FAILED" % len(failed),
                "Mods %d of %d" % (done, n),
                "failed: %s" % ", ".join(failed)[:64]]
    return ["MODS READY", "Mods %d of %d" % (done, n), ""]


def not_built(why):
    """No build ran at all, and none is coming.

    This still says MODS READY, because that word is the host's control for
    "stop waiting" -- and the mods on disk genuinely are as ready as they are
    going to get. It does NOT claim a build happened: line 1 says the opposite
    and line 2 says why. The alternative, staying silent, makes the host wait
    out its whole defer deadline for a build that will never report."""
    return ["MODS READY", "Mods not rebuilt", why[:64]]


def write(path, lines):
    """Whole-file atomic replace, LF, exactly `ROWS` lines.

    Atomic because the host reads this from another process, every poll: a
    half-written file on a loading screen reads as corruption, not progress.
    LF explicitly, so the two writers produce identical bytes for identical
    state on Windows."""
    lines = list(lines)[:ROWS]
    while len(lines) < ROWS:
        lines.append("")
    d = os.path.dirname(os.path.abspath(path))
    if d and not os.path.isdir(d):
        os.makedirs(d, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(tmp, path)
