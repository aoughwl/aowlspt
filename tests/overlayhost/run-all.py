#!/usr/bin/env python3
"""run-all.py -- build and run every `*test.c` under tests/overlayhost.

Each test here used to be hand-compiled from a gcc line buried in the file's
own header comment. That is fine once and wrong forever: an agent runs the two
it remembers, the third silently rots, and "the overlay tests pass" comes to
mean "the tests I happened to type out pass".

RUN IT FROM POWERSHELL. `gcc` invoked from Git Bash on this machine exits 1
having printed nothing (CLAUDE.md section 3). This script does not paper over
that: it locates gcc itself, and if the compile does not produce a NEW .exe it
reports COMPILE-FAILED, never "0 failures".

    powershell> python tests\\overlayhost\\run-all.py
    powershell> python tests\\overlayhost\\run-all.py --only jsontest

Output per file: BUILD ok/failed, then pass / fail / KNOWN-RED counts.

## KNOWN-RED is not a pass

Two assertions in jsontest.c fail on a CLEAN CHECKOUT and are unrelated to
anything being changed today (subtab category counts). They are listed in
KNOWN_RED below so that a NEW failure is visible instead of drowning in noise
-- but they are still PRINTED every run, still counted separately, and the
summary always states how many are outstanding. They are not suppressed and
they are not "expected passes". If one of them starts passing, this script
says so too, because a stale baseline is its own lie.

Exit status: 0 only if every file built, every file ran, and every failure is
one of the KNOWN_RED entries. A file that could not be built or could not be
run is a hard failure -- "I could not look" is never a pass (CLAUDE.md 9b).
"""
import argparse
import glob
import os
import re
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ABI = os.path.normpath(os.path.join(HERE, "..", "..", "abi"))
OUT = os.path.join(HERE, "build")

# Compile flags per test, lifted from each file's own header comment. -O1 and
# -Wno-unused-function are what jsontest.c documents; the others are -O2 with
# no extra flags, and -Wno-unused-function is harmless everywhere.
CFLAGS = ["-O1", "-Wno-unused-function", "-I", ABI]

# (test stem, exact assertion text) that FAIL on a clean checkout, verified
# 2026-08-27 at 28f54f4 by building and running jsontest.c unmodified.
KNOWN_RED = {
    ("jsontest",
     "subtabs: one tab per distinct category: got 4, wanted 2"),
    ("jsontest",
     "subtabs: each category is exactly its contiguous range: got 3, wanted 0"),
}

OK_RE = re.compile(r"^ok\s+(.*)$")
ERR_RE = re.compile(r"^(?:error|fail|not ok)\s+(.*)$", re.I)


def build(stem, src):
    exe = os.path.join(OUT, stem + ".exe")
    if os.path.exists(exe):
        os.remove(exe)
    gcc = shutil.which("gcc")
    if not gcc:
        return None, ("gcc is not on PATH. This script must be run from "
                      "PowerShell; from Git Bash gcc exits 1 printing "
                      "nothing (CLAUDE.md section 3).")
    p = subprocess.run([gcc] + CFLAGS + [src, "-o", exe],
                       capture_output=True, text=True)
    if not os.path.exists(exe):
        # exit 0 with no output file is a REAL failure mode here.
        return None, ("no executable was produced (gcc exit %d)%s"
                      % (p.returncode,
                         (": " + (p.stderr or p.stdout).strip()[:400])
                         if (p.stderr or p.stdout).strip() else ""))
    if p.returncode != 0:
        return None, ("gcc exit %d: %s"
                      % (p.returncode, (p.stderr or p.stdout).strip()[:400]))
    return exe, None


def run(exe):
    try:
        p = subprocess.run([exe], capture_output=True, text=True, timeout=300,
                           cwd=HERE)
    except subprocess.TimeoutExpired:
        return None, None, "timed out after 300s"
    lines = (p.stdout + "\n" + p.stderr).splitlines()
    passed, failed = [], []
    for ln in lines:
        s = ln.strip()
        m = OK_RE.match(s)
        if m:
            passed.append(m.group(1).strip())
            continue
        m = ERR_RE.match(s)
        if m:
            failed.append(m.group(1).strip())
    if not passed and not failed:
        return None, None, ("produced no ok/error lines at all (exit %d) -- "
                            "this is INCONCLUSIVE, not a pass" % p.returncode)
    return passed, failed, None


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--only", default=None,
                    help="comma-separated test stems, e.g. jsontest,uxtest")
    a = ap.parse_args()

    os.makedirs(OUT, exist_ok=True)
    srcs = sorted(glob.glob(os.path.join(HERE, "*test.c")))
    if a.only:
        want = {w.strip() for w in a.only.split(",") if w.strip()}
        known = {os.path.basename(s)[:-2] for s in srcs}
        bad = want - known
        if bad:
            sys.exit("unknown test(s): %s (known: %s)"
                     % (", ".join(sorted(bad)), ", ".join(sorted(known))))
        srcs = [s for s in srcs if os.path.basename(s)[:-2] in want]
    if not srcs:
        sys.exit("no *test.c found under %s -- nothing was run, which is NOT "
                 "a pass." % HERE)

    hard = 0
    red_seen = set()
    new_fail = 0
    t0 = time.time()
    for src in srcs:
        stem = os.path.basename(src)[:-2]
        exe, err = build(stem, src)
        if err:
            print("BUILD-FAILED  %-12s %s" % (stem, err))
            hard += 1
            continue
        passed, failed, err = run(exe)
        if err:
            print("RUN-FAILED    %-12s %s" % (stem, err))
            hard += 1
            continue
        red = [f for f in failed if (stem, f) in KNOWN_RED]
        new = [f for f in failed if (stem, f) not in KNOWN_RED]
        red_seen |= {(stem, f) for f in red}
        new_fail += len(new)
        verdict = "FAIL" if new else ("ok  " if not red else "red ")
        print("%s          %-12s %3d passed, %d new failure(s), "
              "%d known-red" % (verdict, stem, len(passed), len(new), len(red)))
        for f in new:
            print("      NEW FAILURE  %s" % f)
        for f in red:
            print("      known-red    %s" % f)

    stale = KNOWN_RED - red_seen
    if a.only is None and stale:
        # A baseline that no longer matches reality is a lie of its own kind.
        print("\nBASELINE STALE: %d KNOWN_RED entr(y/ies) did not fail this "
              "run. Confirm it is really fixed, then delete it from "
              "KNOWN_RED in this file:" % len(stale))
        for stem, f in sorted(stale):
            print("      %s: %s" % (stem, f))

    print("\n%d file(s) in %.1fs -- %d new failure(s), %d known-red "
          "outstanding, %d file(s) could not be built or run."
          % (len(srcs), time.time() - t0, new_fail, len(red_seen), hard))
    if hard:
        print("A file that could not be built or run was NOT verified. "
              "That is INCONCLUSIVE, not a pass.")
    return 1 if (hard or new_fail) else 0


if __name__ == "__main__":
    sys.exit(main())
