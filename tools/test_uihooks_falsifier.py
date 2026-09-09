#!/usr/bin/env python3
"""test_uihooks_falsifier.py -- proves `uihooks_check.py selftest` CAN FAIL.

CLAUDE.md 9b: a verifier ships with its falsifier. `uihooks_check` already
carries negative controls INSIDE its own self-test (case 2: actions must
outnumber epochs to FAIL; case 3: a real throttle line must be caught). What
nothing established is that those controls can go red -- a self-test whose
negatives are decorative is the same bug one layer up.

So this injects the exact historical defect: a banned-idiom list that matches
nothing. `BANNED` once matched the very action lines that PROVED the migration
worked; the fix was to narrow the regexes, and the obvious over-correction is
to narrow them to nothing. Case 3 must go red for that.

    python tools/test_uihooks_falsifier.py    exit 0 = the self-test detected it
"""
import io, os, sys, contextlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import uihooks_check

uihooks_check.BANNED = []          # the mutation: a scan that can never fire
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    rc = uihooks_check.cmd_selftest()

if rc == 0:
    print("FAIL -- with BANNED emptied the self-test still passed, so its "
          "banned-idiom negative control cannot fail.")
    sys.exit(1)
print("PASS -- the self-test went red (rc=%d) on an empty BANNED list, so its "
      "negative control is live." % rc)
sys.exit(0)
