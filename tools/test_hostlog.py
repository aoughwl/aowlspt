#!/usr/bin/env python3
r"""test_hostlog.py -- prove `hostlog.py tail` TERMINATES, and that `--follow`
is the thing that does not. No game required.

    python tools/test_hostlog.py
    python tools/test_hostlog.py -v

## Why this exists

`hostlog.py tail` followed the log unconditionally. It printed "following ...
ctrl-c to stop" and never returned, so `hostlog.py tail --max 6` -- which reads
like a six-line peek -- hung a scripted call for the caller's entire 2-minute
timeout. That is not a crash and not an error message; the caller simply
stops, having asked for six lines it never receives.

A unit test cannot catch that, because a function that never returns hangs the
test too. So every case here runs the real script as a SUBPROCESS with a wall
clock on it, and the interesting assertion is about time, not output.

## The negative control is the point

`tail` returning quickly proves nothing on its own -- a `tail` that had been
accidentally turned into a no-op would pass it just as happily. So the suite
also asserts that `--follow` DOES block (it must hit the subprocess timeout)
and that the bounded run really printed the NEWEST lines and no others. If
`--follow` ever stops blocking, this suite fails, and that is deliberate:
without it, "tail returned" is a check that cannot fail.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
HOSTLOG = os.path.join(HERE, "hostlog.py")

VERBOSE = "-v" in sys.argv

RESULTS = []


def check(name, cond, detail=""):
    RESULTS.append((name, bool(cond), detail))
    if VERBOSE or not cond:
        print("  %-5s %s%s" % ("ok" if cond else "FAIL", name,
                               ("  -- " + detail) if detail else ""))


class Bed:
    """A fake install dir holding one synthetic host log."""

    def __init__(self, nlines=40):
        self.root = tempfile.mkdtemp(prefix="aowl-hostlog-")
        self.path = os.path.join(self.root, "aowlspt-host.log")
        with open(self.path, "w", encoding="utf-8", newline="\n") as f:
            f.write("aowlspt host\n")
            for i in range(nlines):
                f.write("[0:00:%02d.000] info   synthetic line %d\n"
                        % (i % 60, i))

    def close(self):
        shutil.rmtree(self.root, ignore_errors=True)


def run(bed, extra, timeout):
    """Run hostlog.py against the bed. Returns (rc, out, timed_out)."""
    cmd = [sys.executable, HOSTLOG, "tail", "--root", bed.root,
           "--no-color"] + list(extra)
    try:
        r = subprocess.run(cmd, capture_output=True, text=True,
                           timeout=timeout)
        return r.returncode, r.stdout + r.stderr, False
    except subprocess.TimeoutExpired as e:
        out = ""
        for part in (e.stdout, e.stderr):
            if part:
                out += part.decode("utf-8", "replace") if isinstance(
                    part, bytes) else part
        return None, out, True


# -- 1. the bug: `tail --max 6` must RETURN, and quickly --------------------
def t_tail_returns():
    b = Bed()
    try:
        rc, out, timed = run(b, ["--max", "6"], timeout=20)
        check("tail/returns-within-20s", not timed,
              "THE BUG: `tail --max 6` did not exit; a scripted call hangs "
              "until the caller's timeout")
        if timed:
            return
        check("tail/exit-0", rc == 0, "rc=%r" % rc)
        check("tail/does-not-say-following", "following" not in out,
              "the default must not enter the blocking loop: %r" % out[:200])
        body = [l for l in out.splitlines() if "synthetic line" in l]
        check("tail/prints-exactly-max", len(body) == 6,
              "wanted 6 body lines, got %d" % len(body))
        # NEWEST, not oldest. A `tail` that returned the head would satisfy
        # every check above and be useless.
        check("tail/prints-the-newest", body and body[-1].endswith("line 39")
              and body[0].endswith("line 34"),
              "first=%r last=%r" % (body[0] if body else None,
                                    body[-1] if body else None))
        check("tail/says-it-truncated", "last 6 of" in out,
              "a truncated answer that does not say so is a wrong answer")
    finally:
        b.close()


# -- 2. NEGATIVE CONTROL: --follow is what blocks ---------------------------
def t_follow_blocks():
    b = Bed()
    try:
        rc, out, timed = run(b, ["--max", "3", "--follow"], timeout=6)
        check("follow/blocks", timed,
              "`--follow` returned rc=%r -- if following no longer blocks, "
              "then case 1 proves nothing about the default" % rc)
    finally:
        b.close()


# -- 3. --max 0 means all, still bounded in time ----------------------------
def t_tail_all():
    b = Bed()
    try:
        rc, out, timed = run(b, ["--max", "0"], timeout=20)
        check("tail/max0-returns", not timed)
        if timed:
            return
        body = [l for l in out.splitlines() if "synthetic line" in l]
        check("tail/max0-prints-all", len(body) == 40, "got %d" % len(body))
        check("tail/max0-no-truncation-note", "last " not in out)
    finally:
        b.close()


# -- 4. a missing log is a REFUSAL, not an empty pass -----------------------
def t_missing_log():
    d = tempfile.mkdtemp(prefix="aowl-hostlog-empty-")
    try:
        cmd = [sys.executable, HOSTLOG, "tail", "--root", d, "--no-color"]
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=20)
        check("missing/exits-nonzero", r.returncode != 0,
              "rc=%r" % r.returncode)
        check("missing/says-why", "no log at" in (r.stdout + r.stderr))
    finally:
        shutil.rmtree(d, ignore_errors=True)


def main():
    for fn in (t_tail_returns, t_follow_blocks, t_tail_all, t_missing_log):
        if VERBOSE:
            print("%s:" % fn.__name__)
        try:
            fn()
        except Exception as e:
            check(fn.__name__ + "/raised", False,
                  "%s: %s" % (type(e).__name__, e))

    bad = [r for r in RESULTS if not r[1]]
    print("\n%s -- %d/%d checks passed"
          % ("PASS" if not bad else "FAIL", len(RESULTS) - len(bad),
             len(RESULTS)))
    if bad:
        for n, _ok, d in bad:
            print("   FAILED  %s  %s" % (n, d))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
