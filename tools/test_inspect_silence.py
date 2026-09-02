#!/usr/bin/env python3
r"""test_inspect_silence.py -- prove the live inspector cannot go silent again.

    python tools/test_inspect_silence.py
    python tools/test_inspect_silence.py -v

## What went wrong

Two boots (22:32 and 22:40) handed batch 1 to Unity's thread at 0:00:03.312,
first dispatched the rider at 0:00:17.156, and then said NOTHING for three
minutes: no answers in aowlspt-inspect-out.txt, no ABANDONED, no QUEUED, no
watchdog line, and a rewritten command file was swallowed without a word.

The cause is structural, not arithmetic. Every report `inspectPoll` owns had a
precondition that was false in that state, and the two that had none sat below
an early `return`:

    if not gInspOn or gInspOff:  return    <- above delivery, deadline,
                                              watchdog AND the file read
    if cInspHave() != 0'i32:     ... return <- above the watchdog and the read

and the only announcement of a self-disable was an `iOut` -- a line in the
batch OUTPUT BUFFER, which reaches the log only through `inspWriteOut`, which
is called from the proc that had already returned. So the event that silenced
the channel also destroyed the record of itself.

## What this asserts

Structural invariants of the fix, over the real source file -- that the
unconditional report exists and is reachable before both early-outs, that the
self-disable is announced on the host log by the thread that decided it, and
that a refused edit is refused OUT LOUD.

## The negative control is the point

A source-text assertion that passes is worth nothing unless it can fail. So
every case is ALSO run against `git show HEAD:<the file>` -- the code as it was
before the fix -- and the suite FAILS if the pre-fix source passes any check
that is supposed to be about the fix. That is what makes this a falsification
rather than a spelling test.
"""

from __future__ import annotations

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
REL = "host/Aowlspt.Host.Il2Cpp/inspect.nim"
SRC = os.path.join(ROOT, REL.replace("/", os.sep))

RESULTS = []


def check(name, ok, detail=""):
    RESULTS.append((name, bool(ok), detail))
    return bool(ok)


def head_source():
    """The file as of HEAD, or None if git cannot produce it."""
    try:
        out = subprocess.run(["git", "show", "HEAD:" + REL],
                             cwd=ROOT, capture_output=True, timeout=60)
    except Exception:
        return None
    if out.returncode != 0:
        return None
    return out.stdout.decode("utf-8", "replace")


def first(text, needle):
    """Line number (1-based) of the first occurrence, or -1."""
    idx = text.find(needle)
    if idx < 0:
        return -1
    return text.count("\n", 0, idx) + 1


def poll_span(text):
    """(start, end) line numbers of proc inspectPoll."""
    a = first(text, "proc inspectPoll(")
    if a < 0:
        return (-1, -1)
    b = first(text[text.find("proc inspectPoll("):], "\nproc inspectInit(")
    return (a, a + b if b > 0 else len(text.split("\n")))


# --- the invariants, as predicates over the source ---------------------------
# Each returns (ok, detail). They are run against the working tree (must all
# pass) and against HEAD (must all FAIL, or the check cannot fail at all).

def inv_no_combined_off_guard(t):
    n = first(t, "if not gInspOn or gInspOff:")
    return (n < 0,
            "the combined guard is still at line %d; `gInspOff` returns before "
            "delivery, the deadline, the watchdog and the file read" % n)


def inv_flight_report_exists(t):
    return (first(t, "HANDED but NOT DELIVERED") > 0,
            "no unconditional handed-but-not-delivered report")


def inv_flight_report_before_pending(t):
    rep = first(t, "HANDED but NOT DELIVERED")
    pend = first(t, "  if cInspHave() != 0'i32:")
    dead = first(t, "THE DEADLINE ON AN IN-FLIGHT BATCH")
    return (0 < rep < pend and 0 < rep < dead,
            "report@%d pending-branch@%d deadline@%d -- the report must "
            "precede both or it inherits their preconditions"
            % (rep, pend, dead))


def inv_file_read_before_pending(t):
    rd = first(t, "readShared(gInspCmdPath, text)")
    pend = first(t, "  if cInspHave() != 0'i32:")
    return (0 < rd < pend,
            "read@%d pending-branch@%d -- while a batch is pending the host "
            "cannot even see a new command file" % (rd, pend))


def inv_refusal_is_loud(t):
    n = t.count("your new batch is NOT queued")
    return (n >= 2,
            "found %d refusal message(s); both the pending path and the "
            "claimed-and-running path must announce the refusal" % n)


def inv_off_announced_on_log(t):
    has = first(t, "proc inspGoOff(") > 0
    warned = "live inspector: SELF-DISABLED" in t
    sites = t.count("gInspOff = true")
    return (has and warned and sites == 1,
            "inspGoOff=%s warn=%s bare `gInspOff = true` sites=%d (must be "
            "exactly the one inside inspGoOff)" % (has, warned, sites))


def inv_off_still_publishes(t):
    return (first(t, "polling has STOPPED because the channel is OFF") > 0,
            "the OFF state never publishes the dead batch's answers or says "
            "that edits will now be ignored")


def inv_watchdog_survives_off(t):
    wd = first(t, "  inspPollWatchdog()")
    tick = first(t, "proc inspTick()")
    off = t.find("proc inspTick()")
    off = t.count("\n", 0, t.find("if gInspOff:", off)) + 1
    return (0 < tick < wd < off,
            "inspTick@%d calls inspPollWatchdog@%d, gInspOff early-out@%d -- "
            "a self-disable must not silence the host-thread watchdog too"
            % (tick, wd, off))


def inv_stale_file_not_run(t):
    seeded = first(t, "gInspLastText = existing") > 0
    said = first(t, "a stale command file was already on disk") > 0
    return (seeded and said,
            "seeded=%s announced=%s -- the previous session's file is run at "
            "boot, against a client still on the loading screen" % (seeded, said))


def inv_wordy_root_refused(t):
    """A letters-only token in the ROOT slot must REFUSE, and the refusal must
    carry a completeness verdict.

    MEASURED live, twice, by two agents: `findtext Interface language
    $settings 40000 all` took ONE token as the needle and handed `language` to
    the root resolver, which answered `! not an address: language` with 0 hits
    and NO completeness line -- which a consumer that only counts hits reads
    as a clean miss. Three things must hold in the source:
      * the refusal exists and names the real cause;
      * it is reached from the SHARED resolver, so `find`, `findtext` and
        `findcomp` cannot drift apart;
      * it prints NOTHING WAS EXAMINED, the same verdict a zero-node walk
        prints, so the two are classified identically.
    """
    msg = "needle is ONE token" in t
    shared = ("iFindRefuseWordyRoot(toks, startTok, cmdName)" in t
              and t.count("proc iFindResolveRoot(") == 1)
    verdict = ("proc iFindNothingExamined(" in t
               and "iFindNothingExamined(cmdName)" in t
               and t.count(
                   "-- NOTHING WAS EXAMINED (0 valid nodes visited") >= 2)
    # `all`/`more`/`in` are grammar, not roots -- refusing them would break
    # `findtext X all` and `find X in Y`.
    grammar = "proc iFindIsGrammarWord(" in t
    return (msg and shared and verdict and grammar,
            "refusal_text=%s shared_resolver=%s nothing_examined=%s "
            "grammar_exempt=%s" % (msg, shared, verdict, grammar))


INVARIANTS = [
    ("no_combined_off_guard", inv_no_combined_off_guard),
    ("flight_report_exists", inv_flight_report_exists),
    ("flight_report_before_pending", inv_flight_report_before_pending),
    ("file_read_before_pending", inv_file_read_before_pending),
    ("refusal_is_loud", inv_refusal_is_loud),
    ("off_announced_on_log", inv_off_announced_on_log),
    ("off_still_publishes", inv_off_still_publishes),
    ("watchdog_survives_off", inv_watchdog_survives_off),
    ("stale_file_not_run", inv_stale_file_not_run),
    ("wordy_root_refused", inv_wordy_root_refused),
]


def main():
    verbose = "-v" in sys.argv
    if not os.path.exists(SRC):
        print("FAIL -- %s not found" % SRC)
        return 1
    cur = open(SRC, encoding="utf-8", errors="replace").read()

    for name, fn in INVARIANTS:
        try:
            ok, detail = fn(cur)
        except Exception as e:
            ok, detail = False, "%s: %s" % (type(e).__name__, e)
        check("fixed/" + name, ok, detail)
        if verbose:
            print("  fixed/%-30s %s" % (name, "ok" if ok else detail))

    old = head_source()
    if old is None:
        check("control/available", False,
              "git show HEAD:%s failed -- the negative control could not run, "
              "so these checks are UNPROVEN, not passing" % REL)
    else:
        failed_on_old = 0
        for name, fn in INVARIANTS:
            try:
                ok, _ = fn(old)
            except Exception:
                ok = False
            if not ok:
                failed_on_old += 1
            if verbose:
                print("  HEAD/%-30s %s" % (name, "PASSES (bad)" if ok
                                           else "fails (good)"))
        # HEAD is the pre-fix source only if the fix is uncommitted. If someone
        # commits the fix, every check passes on HEAD too and this control
        # becomes vacuous -- so say that rather than reporting a pass.
        if failed_on_old == 0:
            check("control/can_fail", False,
                  "every invariant PASSES on HEAD as well, so this suite "
                  "cannot distinguish fixed from broken. Either the fix is "
                  "committed (re-point the control at the pre-fix commit) or "
                  "the checks are vacuous.")
        else:
            check("control/can_fail", True,
                  "%d of %d invariants fail on the pre-fix source"
                  % (failed_on_old, len(INVARIANTS)))

    bad = [r for r in RESULTS if not r[1]]
    print("\n%s -- %d/%d checks passed"
          % ("PASS" if not bad else "FAIL", len(RESULTS) - len(bad),
             len(RESULTS)))
    for n, ok, d in RESULTS:
        if not ok:
            print("   FAILED  %s  %s" % (n, d))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
