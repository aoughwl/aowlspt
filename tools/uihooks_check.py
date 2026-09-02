#!/usr/bin/env python3
"""uihooks_check.py -- did the menu features stop polling?

THREE OUTCOMES, NEVER TWO: PASS (0) / FAIL (1) / INCONCLUSIVE (3).

THE ASSERTION, and it is a NEGATIVE so it can actually fail:

  * every migrated menu feature acts AT MOST ONCE per menu epoch, and
  * no per-frame throttle/walk idiom appears for those features at all.

"The feature still works" is not the question -- it worked before. The question
is whether it works WITHOUT polling, and the only observable difference is how
many times it acted for a given number of menu rebuilds. So this compares two
counts. A regression to per-frame behaviour makes actions outrun epochs on the
very first menu.

IT DOES NOT READ THE LOG ITSELF. The host log is the one channel out of the
client and a whole-file read of it is a measured context bomb, so every query
here goes through `tools/hostlog.py grep`, which is the accessor built for
exactly this. That also means this script stays correct if the log moves or
grows.

Usage:
    python tools/uihooks_check.py
"""
import re
import subprocess
import sys
import os

PASS, FAIL, INCONCLUSIVE = 0, 1, 3
HOSTLOG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hostlog.py")


def grep(pattern):
    """Matching lines via hostlog.py, or None when the log could not be read."""
    try:
        out = subprocess.run(
            [sys.executable, HOSTLOG, "grep", pattern, "--max", "0", "--no-color"],
            capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError) as exc:
        print("INCONCLUSIVE: could not run hostlog.py (%s)." % exc)
        return None
    if out.returncode not in (0, 1):
        print("INCONCLUSIVE: hostlog.py grep exited %d: %s"
              % (out.returncode, (out.stderr or "").strip()[:200]))
        return None
    return [ln for ln in out.stdout.splitlines() if ln.strip()]


# One entry per migrated feature: the ONE line it may emit per epoch.
FEATURES = [
    ("hide seasons", r"hide seasons: menu epoch", re.compile(r"menu epoch (\d+)")),
    ("version brand", r"version brand: menu epoch", re.compile(r"menu epoch (\d+)")),
    ("hide mode button", r"hide mode button: menu epoch",
     re.compile(r"menu epoch (\d+)")),
]

# Idioms the migration removed. Their return means something polls again.
# Idioms the migration RETIRED. Their return means something polls again.
#
# THESE MUST NAME THE OLD IDIOM, NOT A WORD THAT ALSO APPEARS IN THE NEW LINES.
# The first version matched "bounded walk", which is a substring of the NEW
# action line "one bounded pass ..." -- so the check FAILED on exactly the
# lines that prove the migration worked. A regex that fires on success is worse
# than no check: it trains the reader to ignore it.
BANNED = [
    ("hide seasons", r"hide seasons.*(throttle|re-checked|keeps looking)"),
    ("hide mode button", r"hide mode button.*(post-warm-up walks|bounded walks)"),
    ("version brand", r"version brand.*[0-9]+-frame"),
]


def main():
    highest = 0
    counts = {}
    for label, pat, epoch_re in FEATURES:
        lines = grep(pat)
        if lines is None:
            return INCONCLUSIVE
        counts[label] = len(lines)
        for ln in lines:
            m = epoch_re.search(ln)
            if m:
                highest = max(highest, int(m.group(1)))

    if highest == 0 and not any(counts.values()):
        print("INCONCLUSIVE: no menu-epoch action lines at all. Either the "
              "features are off, the menu was never shown, or uihooks site 2 "
              "never bound. Nothing was observed -- NOT a pass.")
        return INCONCLUSIVE

    problems = []
    for label, n in counts.items():
        if n > highest:
            problems.append(
                "%s acted %d time(s) across %d menu epoch(s) -- more actions "
                "than epochs means it is firing per frame, not per event."
                % (label, n, highest))

    for label, pat in BANNED:
        lines = grep(pat)
        if lines is None:
            return INCONCLUSIVE
        # NEVER SCAN A FEATURE'S OWN ACTION LINE. Measured: the action lines
        # described what they replaced ("No walk, no throttle...", "the
        # 120-frame clobber re-check is gone"), so the banned-idiom scan
        # matched the very lines that PROVE the migration worked. The prose was
        # fixed, but the check must not depend on prose staying careful --
        # anything carrying "menu epoch" is an action line by construction.
        offenders = [ln for ln in lines if "menu epoch" not in ln]
        if offenders:
            problems.append("%s still logs a per-frame idiom: %s"
                            % (label, offenders[0].strip()[:110]))

    if problems:
        for p in problems:
            print("FAIL: " + p)
        return FAIL

    print("PASS: %d menu epoch(s); " % highest +
          ", ".join("%s acted %d time(s)" % (k, v) for k, v in counts.items()) +
          "; no throttle or walk idiom for any migrated feature.")
    return PASS


if __name__ == "__main__":
    sys.exit(main())
