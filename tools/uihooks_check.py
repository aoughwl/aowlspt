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
    python tools/uihooks_check.py selftest   # OFFLINE, no client and no log:
                                             # replays measured host-log lines
                                             # from tools/fixtures/inspector/
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


# ---------------------------------------------------------------------------
# selftest -- OFFLINE, against tools/fixtures/inspector/_hostlog.txt
# ---------------------------------------------------------------------------
# The BANNED list here once matched the very lines that PROVE the migration
# worked, because those lines describe what the migration removed. That was
# found by running it; nothing stopped it coming back. This runs the real
# `main()` against MEASURED host-log lines with only `grep` replaced -- the
# regexes under test are the shipped ones, applied by re.search exactly as
# hostlog.py would apply them.

def cmd_selftest():
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import inspectfixtures as fx

    g = globals()
    real_grep = g["grep"]
    failures = []

    def use(lines):
        """A grep over a fixed corpus of measured lines. `None` lines means the
        log could not be read, which every caller must treat as INCONCLUSIVE."""
        def fake(pattern):
            if lines is None:
                return None
            rx = re.compile(pattern)
            return [l for l in lines if rx.search(l)]
        g["grep"] = fake

    def case(title, fn):
        print("\n---- %s" % title)
        note = fn()
        if note:
            failures.append("%s: %s" % (title, note))
            print("  ** CASE FAILED: %s" % note)
        else:
            print("  case ok")

    ACTIONS = fx.fx("hostlog-menu-epoch-actions").splitlines()

    # 1 -- the success case, on the exact prose that used to fail it.
    def c1():
        use(ACTIONS)
        rc = main()
        if rc != PASS:
            return ("measured epoch-1 action lines returned %d, want PASS(%d). "
                    "If this is a banned-idiom hit, the regex is matching the "
                    "action line's own description of what it replaced." % (rc, PASS))
        return ""
    case("measured menu-epoch action lines -> PASS", c1)

    # 1b -- the SAME check against the EARLIER, dangerous wording of those
    #       lines ("No walk, no throttle", "The 120-frame clobber re-check is
    #       gone"). This is the shape that once made the tool FAIL on success.
    def c1b():
        use(fx.fx("hostlog-menu-epoch-risky-prose").splitlines())
        rc = main()
        if rc != PASS:
            return ("the pre-softening action wording returned %d, want "
                    "PASS(%d) -- a banned-idiom regex is matching an action "
                    "line's own description of what it replaced" % (rc, PASS))
        return ""
    case("action lines that NAME the removed idiom -> still PASS", c1b)

    # 2 -- NEGATIVE CONTROL: more actions than epochs is per-frame behaviour.
    def c2():
        dup = [l for l in ACTIONS if "hide seasons" in l]
        use(ACTIONS + dup + dup)   # 4 'hide seasons' actions, still epoch 1
        if main() != FAIL:
            return "more actions than menu epochs did not FAIL -- the count " \
                   "comparison cannot fail"
        return ""
    case("control: actions outnumber epochs -> FAIL", c2)

    # 3 -- NEGATIVE CONTROL: a genuine banned idiom must still be caught, and
    #      it must be caught on a line that is NOT an action line.
    def c3():
        use(ACTIONS + ["client  [0:00:41.000]ok  hide seasons: re-checked the "
                       "banner again this frame (throttle 30)"])
        if main() != FAIL:
            return "a real per-frame idiom on a non-action line was not caught"
        return ""
    case("control: a real throttle line -> FAIL", c3)

    # 4 -- nothing observed is not a pass.
    def c4():
        use([])
        if main() != INCONCLUSIVE:
            return "an empty log was not INCONCLUSIVE"
        use(None)
        if main() != INCONCLUSIVE:
            return "an unreadable log was not INCONCLUSIVE"
        return ""
    case("no lines / unreadable log -> INCONCLUSIVE", c4)

    g["grep"] = real_grep
    print("\n==== uihooks selftest: %d case(s) failed" % len(failures))
    for f in failures:
        print("  - %s" % f)
    return 1 if failures else 0


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "selftest":
        sys.exit(cmd_selftest())
    sys.exit(main())
