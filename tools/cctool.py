#!/usr/bin/env python3
r"""cctool.py -- resolve a C compiler that WORKS, identically from every shell.

## The measurement this file exists because of (2026-09-02)

`python tools/test_mqpolicy.py`, same checkout, same command, same second:

    from PowerShell   ->  11 PASS  0 FAIL  0 INCONCLUSIVE
    from Git Bash     ->  INCONCLUSIVE compile -- the header did not compile
                          clean with -Wall -Werror

Both shells resolve the SAME compiler: `shutil.which("gcc")` returns
`C:\msys64\ucrt64\bin\gcc.exe` in both. The argv is identical. Only the
environment differs, and the difference is PATH ORDER:

    Git Bash prepends   C:\Program Files\Git\mingw64\bin
    ...which precedes   C:\msys64\ucrt64\bin

`gcc.exe` itself loads fine -- Windows searches an executable's OWN directory
first, and `C:\msys64\ucrt64\bin` holds its DLLs. But gcc then execs

    C:\msys64\ucrt64\lib\gcc\x86_64-w64-mingw32\15.2.0\cc1.exe

and THAT directory contains exactly one DLL (`liblto_plugin.dll`), so cc1's
imports fall through to PATH and bind Git-for-Windows' MINGW64 builds of
`libgmp-10.dll`, `libiconv-2.dll`, `libwinpthread-1.dll`, `libintl-8.dll`,
`libzstd.dll`, `zlib1.dll`, `libgcc_s_seh-1.dll` -- 17 DLL names collide
between the two directories and every one differs in size.

Measured exit status of cc1 under that PATH:

    cc1 CLEAN PATH                rc=0           (compiles)
    cc1 Git\mingw64\bin first     rc=0xC0000139  (STATUS_ENTRYPOINT_NOT_FOUND)

`0xC0000139` is a **loader** failure: cc1 dies before `main`, so it writes
nothing to stderr and nothing to stdout. gcc observes a dead child and exits 1
with no diagnostic. That is the whole of "gcc silently fails in Git Bash".

It is NOT about MSYSTEM, TMPDIR, MSYS path conversion, or the shell's argv
quoting -- each of those was removed independently and the failure persisted;
only removing `C:\Program Files\Git\mingw64\bin` from PATH (or prepending
ucrt64) fixed it.

## The fix, and why it is a directory and not a shell

Prepend the compiler's OWN directory to PATH. Then cc1's imports resolve
against the toolchain that shipped it, whatever the parent shell put on PATH.
This is the same rule `tools/modbuild.py:build_env` already applies to mod
compiles; this module exists so that every OTHER caller gets it too instead of
each one rediscovering the 0xC0000139.

## Using it

    from cctool import find_cc, cc_env, cc_run, why_no_cc

    cc, note = find_cc()
    if cc is None:
        print("INCONCLUSIVE -- " + note)      # `note` names the cause + fix
    r = cc_run([cc, "-c", src, "-o", obj])    # sanitised env, always

`cc_run` is a thin `subprocess.run` wrapper that supplies `cc_env(cc)`. Use it
rather than plain `subprocess.run`, or the PATH fix is not applied and the
shell-dependence comes straight back.

Run this file directly for a diagnosis of the current shell:

    python tools/cctool.py

Exit: 0 a working compiler / 3 none (INCONCLUSIVE -- never a pass).
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile

# Known-good toolchain roots on a developer machine, in preference order.
# `tools/modbuild.py` calls the first of these DEV_UCRT64 and treats it as
# mandatory; keep the two in agreement.
FALLBACK_BINS = (
    r"C:\msys64\ucrt64\bin",
    r"C:\msys64\mingw64\bin",
)

NAMES = ("gcc", "cc", "clang")

# The one-line cause, quoted by callers into their own INCONCLUSIVE text so the
# reader gets the measured reason and the fix instead of "it did not compile".
SHELL_CAUSE = (
    "gcc's cc1.exe died in the Windows loader with 0xC0000139 "
    "(STATUS_ENTRYPOINT_NOT_FOUND) and therefore printed nothing at all -- "
    "the classic cause is 'C:\\Program Files\\Git\\mingw64\\bin' preceding "
    "'C:\\msys64\\ucrt64\\bin' on PATH (Git Bash prepends it), so cc1 binds "
    "Git's libgmp/libiconv/libwinpthread instead of the toolchain's. "
    "Fix: run the compiler through tools/cctool.py cc_run(), which prepends "
    "the compiler's own directory to PATH."
)


def _norm(p):
    return os.path.normpath(p) if p else p


def cc_env(cc, base=None):
    """The environment a compile must run under: the compiler's own bin
    directory FIRST on PATH.

    Not a nicety. Without it, a gcc resolved by absolute path still execs a
    cc1 that resolves its DLLs through the caller's PATH -- see the module
    docstring. Prepending the compiler's own directory is general: it is
    correct for whichever toolchain was found, not just for ucrt64.
    """
    env = dict(os.environ if base is None else base)
    own = os.path.dirname(_norm(cc))
    parts = [p for p in env.get("PATH", "").split(os.pathsep) if p]
    # Remove any existing occurrence so the prepend genuinely wins, then lead
    # with it.
    low = own.lower()
    parts = [p for p in parts if _norm(p).lower() != low]
    env["PATH"] = os.pathsep.join([own] + parts)
    return env


def cc_run(cmd, **kw):
    """`subprocess.run` with the compiler's directory forced onto the front of
    PATH. `cmd[0]` must be the compiler path."""
    kw.setdefault("capture_output", True)
    kw.setdefault("text", True)
    kw["env"] = cc_env(cmd[0], kw.get("env"))
    return subprocess.run(cmd, **kw)


def _works(cc):
    """Compile a trivial translation unit. Returns (ok, detail).

    This is the point of the module: a compiler that is PRESENT is not a
    compiler that WORKS, and the 0xC0000139 failure is invisible in
    `--version` (gcc.exe itself loads fine; only cc1 dies). So the probe must
    actually drive a compile.
    """
    d = tempfile.mkdtemp(prefix="aowl-cccheck-")
    try:
        src = os.path.join(d, "probe.c")
        with open(src, "w", newline="\n") as f:
            f.write("int main(void){return 0;}\n")
        try:
            r = cc_run([cc, "-std=c99", "-Wall", "-Werror", src,
                        "-o", os.path.join(d, "probe.exe")])
        except OSError as ex:
            return False, "could not be executed at all: %s" % ex
        if r.returncode == 0:
            return True, ""
        msg = (r.stdout or "") + (r.stderr or "")
        if not msg.strip():
            return False, ("exited %d with NO output on stdout or stderr. %s"
                           % (r.returncode, SHELL_CAUSE))
        return False, "exited %d: %s" % (r.returncode, msg.strip()[:400])
    finally:
        shutil.rmtree(d, ignore_errors=True)


def find_cc(verify=True):
    """Return (path, note) for a compiler that compiles, else (None, reason).

    Candidates: gcc/cc/clang on PATH, then the known msys2 bins. Each is
    PROBED with a real compile when `verify` is set, and the first that works
    wins -- so a broken-by-PATH gcc no longer shadows a working one, and the
    answer does not depend on which shell started python.
    """
    seen = []
    cands = []
    for n in NAMES:
        p = shutil.which(n)
        if p:
            cands.append(_norm(p))
    for b in FALLBACK_BINS:
        for n in NAMES:
            p = os.path.join(b, n + ".exe")
            if os.path.isfile(p):
                cands.append(_norm(p))

    tried = []
    for p in cands:
        if p.lower() in [t.lower() for t in tried]:
            continue
        tried.append(p)
        if not verify:
            return p, "found %s (not verified)" % p
        ok, detail = _works(p)
        if ok:
            return p, "verified %s compiles a trivial TU" % p
        seen.append("%s -> %s" % (p, detail))

    if not tried:
        return None, ("no gcc/cc/clang on PATH and none at %s, so the compile "
                      "was NOT PERFORMED (this is not a pass)"
                      % ", ".join(FALLBACK_BINS))
    return None, ("found %d compiler(s) but none could compile a trivial "
                  "translation unit, so the compile was NOT PERFORMED (this "
                  "is not a pass): %s" % (len(tried), "; ".join(seen)))


def why_no_cc(reason):
    """The text a selftest should print when `find_cc` returned None. Kept
    here so every caller says the same measured thing."""
    return reason


def main():
    cc, note = find_cc()
    print("shell PATH head:")
    for p in os.environ.get("PATH", "").split(os.pathsep)[:6]:
        print("   ", p)
    print()
    if cc is None:
        print("INCONCLUSIVE  compiler  -- " + note)
        return 3
    print("OK  compiler  -- " + note)
    print("    PATH head under cc_env: %s"
          % cc_env(cc)["PATH"].split(os.pathsep)[0])
    return 0


if __name__ == "__main__":
    sys.exit(main())
