#!/usr/bin/env python3
"""test_hostcfg_falsifier.py -- proves `hostcfg.py --selftest` CAN FAIL.

The bug hostcfg's self-test exists for: `show` called four keys typos, one of
which (`uxNativeRaidDrive`) was live and driving raid entry. The obvious
over-correction is a classifier that NEVER says typo -- and hostcfg's own
comment says case B is what makes case A falsifiable. This asserts that is
true rather than merely intended.

    python tools/test_hostcfg_falsifier.py   exit 0 = the self-test detected it
"""
import argparse, io, os, sys, contextlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hostcfg

args = argparse.Namespace(root=hostcfg.DEFAULT_ROOT,
                          host=os.path.join(hostcfg.REPO, "host"))

hostcfg.classify_unknown = lambda k, keys, root, repo: ("LIVE", "mutated")
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    rc = hostcfg.selftest(args)

if rc == 0:
    print("FAIL -- a classifier that answers LIVE to everything (never 'typo?',"
          " never UNKNOWN) still passed hostcfg --selftest.")
    sys.exit(1)
print("PASS -- hostcfg --selftest went red (rc=%d) on an always-LIVE "
      "classifier, so cases B/C/D are live checks." % rc)
sys.exit(0)
