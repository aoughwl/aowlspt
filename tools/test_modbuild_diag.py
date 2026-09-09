#!/usr/bin/env python3
r"""test_modbuild_diag.py -- modbuild reports the CAUSE, not the last lines.

    python tools/test_modbuild_diag.py

`modbuild.build_one` used to report `splitlines()[-6:]` of a failed compile --
the tail. nimony ends a failed build with a `FAILURE: <entire nifmake command
line>` banner, so the tail was the banner, and the caller then cut each line to
160 characters. Measured on 2026-09-01: three mods failed and the report was

    failed    manager  -- nimony exited 1
        | FAILURE: C:\...\fakeinstall\toolchain\nimony

which names no cause at all. The real diagnostics -- a missing import, an
unresolved path, an ambiguous identifier -- had been pushed off the top by the
banner announcing that a failure had happened. Each cause had to be recovered
by re-running the compile by hand.

The fixtures below are the REAL captured output of those compiles, so this test
asserts against what nimony actually printed rather than against a guess at its
format. Every assertion has a negative control: the point is not that the new
code returns something, it is that it returns the cause and DROPS the banner.
"""

from __future__ import annotations

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import modbuild  # noqa: E402

FAILURES = []


def check(name, cond, detail=""):
    if cond:
        print("  PASS  %s" % name)
    else:
        print("  FAIL  %s   %s" % (name, detail))
        FAILURES.append(name)


# --- real captured output, 2026-09-01 --------------------------------------

BANNER = (r"FAILURE: C:\Users\savant\AppData\Local\Temp\claude\scratchpad"
          r"\fakeinstall\toolchain\nimony\bin\nifmake.exe --base:C:/Users/"
          r"savant/scratchpad/fakeinstall/mods/manager -j run --progress:0:50 "
          r"nimcache\man0pgndo.build.nif")

MANAGER = "\n".join([
    r"mgr/cfgscan.nim(47, 1) Error: file not found: C:\Users\savant\scratchpad"
    r"\fakeinstall\toolchain\host\common\jsonpath.nim",
    r"mgr/cfgscan.nim(107, 15) Error: undeclared identifier: 'jsonFault'",
    BANNER,
])

SAIN = "\n".join([
    r"client/drivecalls.nim(88, 1) Error: file not found: C:\Users\savant"
    r"\scratchpad\fakeinstall\toolchain\abi",
    r"client/drivecalls.nim(173, 19) Error: ambiguous identifier",
    r"client/drivecalls.nim(174, 17) Error: ambiguous identifier",
    r"client/drivecalls.nim(175, 22) Error: ambiguous identifier",
    r"client/drivecalls.nim(176, 13) Error: ambiguous identifier",
    r"client/drivecalls.nim(177, 16) Error: ambiguous identifier",
    BANNER,
])

AMMO = "\n".join([
    r"ammoloading.nim(424, 17) Error: ambiguous identifier",
    r"ammoloading.nim(425, 17) Error: ambiguous identifier",
    r"ammoloading.nim(717, 17) Error: Type mismatch at [position]",
    r"verify(tInstantiate)",
    r"  expected: int",
    r"  but got:  string",
    BANNER,
])

# A failure with NO recognisable diagnostic at all. This is the fallback path,
# and it must still say something.
OPAQUE = "\n".join(["something went wrong", "no idea what", BANNER])


def joined(out):
    return "\n".join(out)


def main():
    print("modbuild.diagnostics: the cause, not the tail")

    print("\nthe banner is dropped")
    for name, text in (("manager", MANAGER), ("sain", SAIN), ("ammo", AMMO)):
        out = modbuild.diagnostics(text, "")
        check("%s: the FAILURE banner is NOT reported" % name,
              not any(l.lower().startswith("failure:") for l in out),
              joined(out)[:200])
        check("%s: something IS reported" % name, len(out) > 0)

    print("\nthe cause is reported")
    out = joined(modbuild.diagnostics(MANAGER, ""))
    check("manager: names the missing file", "jsonpath.nim" in out, out[:200])
    check("manager: names the undeclared identifier", "jsonFault" in out,
          out[:200])
    out = joined(modbuild.diagnostics(SAIN, ""))
    check("sain: names the unresolved path", "drivecalls.nim(88" in out,
          out[:200])
    check("sain: reports the ambiguous identifiers too",
          "ambiguous identifier" in out, out[:200])
    out = modbuild.diagnostics(AMMO, "")
    check("ammo: keeps the lines AFTER the error (the type detail)",
          any("but got" in l for l in out), joined(out)[:300])

    # NEGATIVE CONTROL. The OLD behaviour was the tail; if the tail still won,
    # every check above could pass vacuously on a fixture whose cause happens
    # to be near the end. Assert the specific thing the old code did: report
    # the last 6 lines including the banner.
    print("\nnegative controls")
    old_manager = MANAGER.strip().splitlines()[-6:]
    check("the OLD tail behaviour WOULD have shown the banner",
          any(l.lower().startswith("failure:") for l in old_manager),
          "if this fails the fixture does not reproduce the bug")
    check("the new behaviour differs from the old tail",
          modbuild.diagnostics(MANAGER, "") != old_manager)

    print("\nthe fallback (a failure with no recognisable diagnostic)")
    out = modbuild.diagnostics(OPAQUE, "")
    check("an unrecognised failure still reports SOMETHING", len(out) > 0,
          joined(out))
    check("...and does not silently return an empty list",
          out != [], joined(out))
    check("an empty output returns an empty list, not a crash",
          modbuild.diagnostics("", "") == [])

    print("\n%s -- %d failure(s)"
          % ("FAIL" if FAILURES else "PASS", len(FAILURES)))
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
