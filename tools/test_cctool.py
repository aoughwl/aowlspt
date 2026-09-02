#!/usr/bin/env python3
r"""test_cctool.py -- the negative control for `tools/cctool.py`.

`cctool.find_cc()` answers "here is a compiler that WORKS". A resolver that
can only ever say yes is worthless, and this one is specifically supposed to
catch a case where the compiler EXISTS and is executable and still cannot
compile -- the measured Git Bash failure, where `C:\Program Files\Git\
mingw64\bin` precedes `C:\msys64\ucrt64\bin`, cc1.exe dies in the loader with
0xC0000139 (STATUS_ENTRYPOINT_NOT_FOUND) and prints NOTHING, so gcc exits 1
with no diagnostic.

So the cases here are the two shapes of "no", plus the positive control
without which they would pass vacuously, plus the actual shell-independence
property the module exists to provide.

  0  positive control   on this machine a working compiler IS found and IS
                        verified by compiling a TU. Without this, a find_cc
                        that returned None unconditionally would satisfy every
                        case below.
  1  nothing present    no compiler on PATH and none at the fallbacks -> None,
                        and the reason says NOT PERFORMED rather than reading
                        as a pass.
  2  present but broken a real executable named gcc.exe that exits 1 with no
                        output -- the exact observable shape of the loader
                        failure -- must be REFUSED, not returned. This is the
                        case a bare `shutil.which("gcc")` gets wrong.
  3  the PATH fix       cc_env() puts the compiler's own directory first, and
                        strips any later duplicate, so cc1's DLL imports bind
                        the toolchain that shipped it.
  4  shell-independence a compile driven through cc_run() succeeds even when
                        PATH is deliberately poisoned with Git's mingw64\bin
                        in front -- i.e. the exact reproduction of the bug is
                        fixed. INCONCLUSIVE (not PASS) if Git's mingw64\bin is
                        not on this machine, because then nothing was proven.

Exit: 0 all cases behaved / 1 a case behaved wrongly / 3 INCONCLUSIVE.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import cctool                                            # noqa: E402

GIT_MINGW = r"C:\Program Files\Git\mingw64\bin"

results = []


def note(state, name, detail=""):
    results.append((state, name, detail))
    print("%-14s %s%s" % (state, name, ("  -- " + detail) if detail else ""))


def with_candidates(names, bins, which=None):
    """Run find_cc with the candidate sources replaced. Restored on exit."""
    old = (cctool.NAMES, cctool.FALLBACK_BINS, cctool.shutil.which)
    cctool.NAMES, cctool.FALLBACK_BINS = names, bins
    if which is not None:
        cctool.shutil.which = which
    try:
        return cctool.find_cc()
    finally:
        cctool.NAMES, cctool.FALLBACK_BINS, cctool.shutil.which = old


def main():
    # -- case 0: the positive control ---------------------------------------
    real, realnote = cctool.find_cc()
    if real is None:
        note("INCONCLUSIVE", "positive-control",
             "no working compiler on this machine, so cases 2-4 cannot be "
             "built and nothing below is attributable: %s" % realnote)
        print("")
        print("0 PASS  0 FAIL  1 INCONCLUSIVE")
        return 3
    note("PASS", "positive-control", realnote)

    # -- case 1: nothing present --------------------------------------------
    cc, why = with_candidates(("no-such-compiler-xyzzy",),
                              (os.path.join(tempfile.gettempdir(),
                                            "no-such-dir-xyzzy"),),
                              which=lambda n: None)
    if cc is not None:
        note("FAIL", "nothing-present",
             "find_cc returned %r when no compiler exists" % cc)
    elif "NOT PERFORMED" not in why:
        note("FAIL", "nothing-present",
             "refused, but the reason does not say NOT PERFORMED, so it can "
             "be misread as a pass: %s" % why)
    else:
        note("PASS", "nothing-present", "refused with a NOT-PERFORMED reason")

    d = tempfile.mkdtemp(prefix="aowl-cctool-t-")
    try:
        # -- case 2: present, executable, silently broken --------------------
        stub = os.path.join(d, "gcc.exe")
        src = os.path.join(d, "stub.c")
        with open(src, "w", newline="\n") as f:
            f.write("int main(void){return 1;}\n")   # exit 1, no output
        r = cctool.cc_run([real, src, "-o", stub])
        if r.returncode != 0:
            note("INCONCLUSIVE", "broken-compiler",
                 "could not build the stub, so this case was NOT PERFORMED: "
                 "%s" % ((r.stderr or "")[:160]))
        else:
            cc, why = with_candidates(("gcc",), (d,), which=lambda n: None)
            if cc is not None:
                note("FAIL", "broken-compiler",
                     "find_cc returned a gcc.exe that exits 1 with no output "
                     "-- this is the Git Bash failure and it must be refused")
            elif "0xC0000139" not in why:
                note("FAIL", "broken-compiler",
                     "refused, but did not name the measured cause, so the "
                     "reader gets no fix: %s" % why)
            else:
                note("PASS", "broken-compiler",
                     "a gcc.exe that exits 1 with no output is REFUSED and "
                     "the reason names the loader failure and the fix")

        # -- case 3: cc_env puts the compiler's own dir first -----------------
        own = os.path.dirname(os.path.normpath(real))
        poisoned = os.pathsep.join([r"C:\decoy", own, r"C:\other"])
        env = cctool.cc_env(real, {"PATH": poisoned})
        parts = env["PATH"].split(os.pathsep)
        dupes = [p for p in parts[1:]
                 if os.path.normpath(p).lower() == own.lower()]
        if os.path.normpath(parts[0]).lower() != own.lower():
            note("FAIL", "cc_env-order",
                 "PATH head is %r, not the compiler's own directory %r"
                 % (parts[0], own))
        elif dupes:
            note("FAIL", "cc_env-order",
                 "the compiler's directory still appears later in PATH (%r), "
                 "so a duplicate could win" % dupes)
        else:
            note("PASS", "cc_env-order",
                 "the compiler's own directory leads PATH exactly once")

        # -- case 4: the actual bug, reproduced and fixed ---------------------
        if not os.path.isdir(GIT_MINGW):
            note("INCONCLUSIVE", "shell-independence",
                 "%s is not on this machine, so the poisoning that caused the "
                 "bug could not be reproduced and this was NOT PERFORMED"
                 % GIT_MINGW)
        else:
            tu = os.path.join(d, "tu.c")
            with open(tu, "w", newline="\n") as f:
                f.write("int main(void){return 0;}\n")
            out = os.path.join(d, "tu.exe")
            clean = os.pathsep.join(
                p for p in os.environ.get("PATH", "").split(os.pathsep)
                if p and "\\Git\\" not in p)
            bad_path = GIT_MINGW + os.pathsep + clean
            cmd = [real, "-std=c99", "-Wall", "-Werror", tu, "-o", out]

            # 4a. the bug still exists if you DON'T use cc_run.
            raw = subprocess.run(cmd, capture_output=True, text=True,
                                 env={**os.environ, "PATH": bad_path})
            # 4b. cc_run must succeed against the same poisoned PATH.
            fixed = subprocess.run(
                cmd, capture_output=True, text=True,
                env=cctool.cc_env(real, {**os.environ, "PATH": bad_path}))

            if fixed.returncode != 0:
                note("FAIL", "shell-independence",
                     "cc_env did NOT rescue the compile: rc=%d %r"
                     % (fixed.returncode, (fixed.stderr or "")[:160]))
            elif raw.returncode == 0:
                note("INCONCLUSIVE", "shell-independence",
                     "cc_run works, but the UNFIXED compile also succeeded "
                     "against a poisoned PATH -- the bug did not reproduce "
                     "here, so this run does not attribute the fix. (A "
                     "toolchain change or a Git update could do this; "
                     "re-measure before deleting the workaround.)")
            else:
                note("PASS", "shell-independence",
                     "with %s ahead of the toolchain the plain compile fails "
                     "(rc=%d, %d bytes of diagnostic) and the SAME command "
                     "through cc_env succeeds"
                     % (GIT_MINGW, raw.returncode,
                        len((raw.stdout or "") + (raw.stderr or ""))))
    finally:
        shutil.rmtree(d, ignore_errors=True)

    fails = [r for r in results if r[0] == "FAIL"]
    incs = [r for r in results if r[0] == "INCONCLUSIVE"]
    print("")
    print("%d PASS  %d FAIL  %d INCONCLUSIVE"
          % (len(results) - len(fails) - len(incs), len(fails), len(incs)))
    if fails:
        return 1
    if incs:
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
