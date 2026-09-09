#!/usr/bin/env python3
"""test_hotreload_ledger -- a refused hot reload must say WHY, per attempt.

MEASURED 2026-09-04 (tools/hostlog.py grep, boot 6bd304e3). The whole record of
four failed hot reloads was one line:

    hotreload: attempted=4 completed=0 released=0 refused=4 deferred=0 epoch=0

`gRlRefused` has exactly ONE producer in modcontrol.nim, and it calls
`gOps.log(why)` right next to the increment -- yet the host log contained no
refusal reason for any of the four. Four refusals with no cause is
indistinguishable from four refusals with the WRONG cause, so the count was not
actionable. The reason now rides the ledger (`rlNote`) instead of a separate log
call, and the host renders it under the counters.

This is a SOURCE-STRUCTURE test, and it says so. It cannot prove the live host
printed anything -- only a run can, and this file must not pretend otherwise.
What it CAN falsify, and does:

  1. Every site that increments a non-completing counter (`gRlRefused`,
     `gRlDeferred`, and the not-released branch) records a reason. A future
     counter bumped without a note is exactly how this defect was born.
  2. The host's `hotreload:` reporter actually reads the notes back, and warns
     when there are attempts, no completion and no reason -- the case that
     produced this test.
  3. The verdict reads the mod's VERSION on both sides of the swap, and says
     UNMEASURED rather than nothing when the mod does not come back.

PASS / FAIL / INCONCLUSIVE (exit 0 / 1 / 3).
"""

import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MC = os.path.join(ROOT, "host", "common", "modcontrol.nim")
HOST = os.path.join(ROOT, "host", "Aowlspt.Host.Il2Cpp", "aowlhost.nim")

# The counters whose increment means "an attempt did not turn into a running
# new library". Each must have a reason recorded within a few lines of it.
NON_COMPLETING = ["gRlRefused", "gRlDeferred"]
WINDOW = 12


def read(path):
    try:
        return io.open(path, encoding="utf-8", newline="").read()
    except OSError as e:
        return None


def main():
    print("test_hotreload_ledger -- a refused reload must carry its reason\n")
    mc, host = read(MC), read(HOST)
    if mc is None or host is None:
        print("INCONCLUSIVE -- modcontrol.nim or aowlhost.nim not found")
        return 3

    bad = []
    lines = mc.splitlines()

    # 1. every non-completing increment has an rlNote near it.
    found_any = False
    for i, ln in enumerate(lines):
        for c in NON_COMPLETING:
            if re.search(r"\binc\s+%s\b" % c, ln):
                found_any = True
                near = "\n".join(lines[max(0, i - WINDOW): i + WINDOW])
                if "rlNote(" not in near:
                    bad.append(
                        "modcontrol.nim:%d increments %s with no rlNote() "
                        "within %d lines. That attempt would be COUNTED and "
                        "never EXPLAINED -- the 2026-09-04 defect exactly."
                        % (i + 1, c, WINDOW))
    if not found_any:
        print("INCONCLUSIVE -- no `inc gRlRefused` / `inc gRlDeferred` site "
              "was found at all; this test is checking nothing.")
        return 3

    # the completed-but-not-released branch is the third non-completing case.
    if "NOT-RELEASED" not in mc:
        bad.append("modcontrol.nim records no reason for the "
                   "completed-but-NOT-RELEASED case, which is the one that "
                   "means a rebuilt DLL cannot replace the running one.")

    # 2. the host reads the notes back and cannot report a silent refusal.
    if "hotReloadNotes()" not in host:
        bad.append("aowlhost.nim never calls hotReloadNotes(), so the reasons "
                   "are recorded and never printed.")
    if "hotReloadNotesDropped()" not in host:
        bad.append("aowlhost.nim never reports the note cap, so a TRUNCATED "
                   "reason list would read as a complete one.")
    if "NO " not in host or "RECORDED REASON" not in host:
        bad.append("aowlhost.nim has no branch for attempts>0 with no "
                   "completion and no recorded reason. Without it, this "
                   "defect recurs silently the next time a counter is added.")

    # 3. the verdict reads the mod's new version string.
    if "hotReloadVersions()" not in host:
        bad.append("aowlhost.nim never reads hotReloadVersions(), so 'it "
                   "reloaded' is still only a rising epoch -- which cannot "
                   "distinguish new code from the same library.")
    if "THE SAME STRING" not in host:
        bad.append("the version readback does not call out the "
                   "before == after case, which is the only reading that "
                   "falsifies a reload.")
    if "UNMEASURED" not in host:
        bad.append("a mod unloaded that never came back must read UNMEASURED, "
                   "not be omitted -- 'I could not look' is not a pass.")
    for fn in ("hotReloadNotes", "hotReloadVersions", "hotReloadNotesDropped"):
        if ("proc %s*" % fn) not in mc:
            bad.append("modcontrol.nim does not export %s()." % fn)

    if bad:
        print("FAIL -- %d problem(s):" % len(bad))
        for b in bad:
            print("  * %s" % b)
        return 1
    print("PASS -- every non-completing hot-reload counter records a reason, "
          "the host prints them, and the verdict reads the mod's version on "
          "both sides of the swap.")
    print("\nNOTE: structural only. That the LIVE host emits these lines is "
          "UNVERIFIED here and needs a run.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
