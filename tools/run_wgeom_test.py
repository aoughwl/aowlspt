#!/usr/bin/env python3
"""Run tests/wgeom_test.nim's suite by loading the DLL the build already makes.

WHY THIS EXISTS.  `aowl run <file under tests/>` builds that file as a MOD DLL
and hands it to the simulator, which refuses it (error 193) because a test
program is not a mod.  `aowl test` builds the world and takes longer than ten
minutes.  Neither actually executes a standalone Nim test, so a test file under
tests/ was compiled and then never run -- which is indistinguishable from not
having a test at all.

So the suite is exported from the DLL as `aowl_wgeom_test_run_x` and this loads
it and calls it.  No new build target, no raw nimony invocation.

Usage:
    python tools/run_wgeom_test.py            # build must have happened already
Exit code is the failure count (0 = pass), so it composes with anything.
"""
import ctypes
import os
import sys

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DLL = os.path.join(HERE, "tests", "bin", "wgeom_test.dll")


def main() -> int:
    if not os.path.exists(DLL):
        print("NOT BUILT: %s" % DLL)
        print("  build it first:  aowl run tests/wgeom_test.nim")
        print("  (that command will FAIL at the simulator step -- that is")
        print("   expected and harmless; it still produces the DLL.)")
        return 2
    lib = ctypes.CDLL(DLL)
    try:
        fn = lib.aowl_wgeom_test_run_x
    except AttributeError:
        print("The DLL does not export aowl_wgeom_test_run_x.")
        print("  Rebuild after checking the {.emit.} wrapper in the test.")
        return 2
    fn.restype = ctypes.c_int32
    fn.argtypes = []
    failures = fn()
    sys.stdout.flush()
    if failures == 0:
        print("\nrun_wgeom_test: PASS")
    else:
        print("\nrun_wgeom_test: FAIL -- %d failing check(s)" % failures)
    return int(failures)


if __name__ == "__main__":
    sys.exit(main())
