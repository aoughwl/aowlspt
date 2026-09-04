#!/usr/bin/env python3
r"""test_il2cpp_flags.py -- prove il2cpp_resolve.py REFUSES a flag it does not
implement, instead of ignoring it.

Run:  python tools/test_il2cpp_flags.py

Offline and FAST: the flag check runs BEFORE the Resolver is built, so this
test passes two arbitrary existing files as GAMEASM/METADEC and never parses
GameAssembly.dll. Nothing is written and the game is not touched.

WHY THIS EXISTS (measured 2026-09-04)
-------------------------------------
`il2cpp_resolve.py ... disasm <RVA> --count 200` SILENTLY IGNORED `--count`
and printed the default 64-byte window. The reader had asked for 200
instructions and got 16, with nothing in the output saying so -- it read as
"this function is 16 instructions long". A confidently wrong answer is the
worst thing this repo produces (CLAUDE.md 10).

WHAT IS ASSERTED, and what would make each case FAIL
----------------------------------------------------
  * an unknown flag on `disasm` exits NON-ZERO, names the flag, echoes the
    FULL command line, and lists the flags `disasm` does accept. A tool that
    dropped the flag exits 0 and prints instructions -- so the test also
    asserts NO disassembly row was printed.
  * the same holds for a verb with NO flags at all (`fields`), so the refusal
    is not disasm-specific.
  * FALSIFIER 1 (the check CAN say yes): the accepted window flags -- --count,
    -n, --insns, --len, --length, --to -- are NOT reported by unknown_flags on
    `disasm`. A blanket "refuse everything" would fail here.
  * FALSIFIER 2 (the check is VERB-SPECIFIC): `--count` IS reported for
    `callers`, which does not implement it. If unknown_flags accepted every
    flag any verb takes, this case fails.
  * FALSIFIER 3 (the refusal comes from the registry, not from the message):
    with `--bogus` temporarily added to VERB_FLAGS["disasm"], unknown_flags
    returns nothing for the identical argv. So the registry is what decides.
  * a negative NUMBER (`-0x10`) is NOT mistaken for a flag -- otherwise the
    check would refuse legitimate addresses.
  * every verb in VERBS has a VERB_FLAGS entry; an unregistered verb would be
    silently unchecked, which is the original bug wearing a different hat.
"""

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from il2cpp_resolve import VERBS, VERB_FLAGS, unknown_flags   # noqa: E402

TOOL = os.path.join(HERE, "il2cpp_resolve.py")
# Any two existing files: the flag refusal fires before either is opened.
DUMMY = TOOL

_fails = []


def case(label, ok, detail=""):
    print("%-4s %s%s" % ("ok" if ok else "FAIL", label,
                         ("  -- " + detail) if detail else ""))
    if not ok:
        _fails.append(label)


def run_cli(*args):
    p = subprocess.run([sys.executable, TOOL, DUMMY, DUMMY] + list(args),
                       capture_output=True, text=True)
    return p.returncode, (p.stdout or "") + (p.stderr or "")


def main():
    # ---- the reported defect, end to end ---------------------------------
    rc, out = run_cli("disasm", "0x141ffd0", "--nosuchflag", "200")
    case("unknown flag on disasm exits NON-ZERO", rc != 0, "rc=%d" % rc)
    case("it names the flag", "'--nosuchflag'" in out or
         '"--nosuchflag"' in out, out[:200])
    case("it echoes the full command line",
         "disasm 0x141ffd0 --nosuchflag 200" in out, out[:300])
    case("it lists the flags disasm DOES accept",
         "--count" in out and "--len" in out and "--to" in out, out[:300])
    case("and NOTHING was disassembled (no instruction rows)",
         "INSTRUCTION" not in out and "\nwindow " not in out
         and ">> 0x" not in out, out[:200])

    # ---- a verb with no flags at all -------------------------------------
    rc2, out2 = run_cli("fields", "System.String", "--verbose")
    case("unknown flag on a flag-less verb exits NON-ZERO", rc2 != 0,
         "rc=%d" % rc2)
    case("and says the verb takes no flags at all",
         "no flags at all" in out2, out2[:200])

    # ---- FALSIFIER 1: the accepted flags are accepted ---------------------
    ok_flags = ["--count", "-n", "--insns", "--len", "--length", "--to",
                "--base", "--max-gap", "--no-fields"]
    bad = unknown_flags("disasm", ["0x1000"] + ok_flags)
    case("FALSIFIER: every documented disasm window flag is ACCEPTED "
         "(the check is not a blanket refusal)", bad == [], repr(bad))
    case("FALSIFIER: and the `=` forms too",
         unknown_flags("disasm", ["--count=8", "--len=64"]) == [])

    # ---- FALSIFIER 2: it is verb-specific --------------------------------
    case("FALSIFIER: --count is REFUSED for `callers`, which has no such flag",
         unknown_flags("callers", ["--count", "8"]) == ["--count"],
         repr(unknown_flags("callers", ["--count", "8"])))

    # ---- FALSIFIER 3: the registry decides -------------------------------
    argv = ["0x1000", "--bogus"]
    before = unknown_flags("disasm", argv)
    saved = VERB_FLAGS["disasm"]
    VERB_FLAGS["disasm"] = tuple(saved) + ("--bogus",)
    try:
        after = unknown_flags("disasm", argv)
    finally:
        VERB_FLAGS["disasm"] = saved
    case("FALSIFIER: the refusal comes from VERB_FLAGS -- registering "
         "--bogus makes the SAME argv pass",
         before == ["--bogus"] and after == [],
         "before=%r after=%r" % (before, after))

    # ---- a negative number is not a flag ---------------------------------
    case("a negative number (-0x10) is not mistaken for a flag",
         unknown_flags("disasm", ["-0x10"]) == [],
         repr(unknown_flags("disasm", ["-0x10"])))

    # ---- registry completeness -------------------------------------------
    missing = [v for v in VERBS if v not in VERB_FLAGS]
    case("every verb has a VERB_FLAGS entry (an unregistered verb would be "
         "UNCHECKED)", missing == [], ", ".join(missing))

    print("\n%d case(s) FAILED" % len(_fails) if _fails
          else "\nALL CASES PASSED")
    return 1 if _fails else 0


if __name__ == "__main__":
    sys.exit(main())
