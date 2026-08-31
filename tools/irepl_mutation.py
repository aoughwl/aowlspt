#!/usr/bin/env python3
"""irepl_mutation.py -- proves `irepl.py --selftest` CAN FAIL.

CLAUDE.md 9b: "if you cannot describe the input that would make your check
fail, you have not written a check." This is that input. It injects the single
most likely real bug in `modctl.classify` -- collapsing the three-state
`clientLive` (present-true / present-false / ABSENT) into two by defaulting the
absent case to false, which is exactly what `manager.nim` says must never
happen -- and asserts the self-test goes red.

    python tools\\irepl_mutation.py     exit 0 = the self-test detected it

Exit 1 here would mean the self-test is decorative.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import modctl, irepl
orig = modctl.classify
def broken(row, e=None, live_dir=None):
    row = dict(row)
    row.setdefault("clientLive", False)   # the exact bug the 3-state field prevents
    return orig(row, e, live_dir)
modctl.classify = broken
rc = irepl.selftest()
print("exit", rc, "-- non-zero means the self-test CAN fail")
sys.exit(0 if rc else 1)
