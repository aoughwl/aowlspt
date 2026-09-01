#!/usr/bin/env python3
"""inspector.py -- the shell side of the live inspector.

The host polls `aowlspt-inspect.txt` for a CONTENT change and answers into
`aowlspt-inspect-out.txt`. Driving that by hand costs four steps every time:
bump a serial so an identical batch re-runs, write the file without a BOM,
guess how long to wait, and read the answer. All four are mechanical, and the
third is the one that produces wrong conclusions -- a read taken before the
host answered shows the PREVIOUS batch, which looks like a plausible answer to
the question just asked.

So: this appends a unique `echo` sentinel as the last command and waits for
that exact literal to appear in the out file. The wait is therefore keyed to
THIS batch, not to a duration, and "timed out" stays a distinct, honest
outcome from "the host answered something else".

  python tools/inspector.py state roots
  python tools/inspector.py -f batch.txt
  echo "find SettingsScreen" | python tools/inspector.py -f -
  python tools/inspector.py --timeout 30 "find Version" "label $_"

Exit codes: 0 answered, 2 timed out, 3 the channel is not there at all.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ichannel as _ch  # noqa: E402 -- the ONE python transport (channel.py)

LIVE = _ch.paths()["live"]
CMD = _ch.paths()["cmd"]
OUT = _ch.paths()["out"]
LOG = _ch.paths()["log"]

read = _ch._read


def diagnose():
    """Say WHY there was no answer, from the host's own words. A timeout with
    no explanation is the failure mode this whole project keeps paying for."""
    return _ch.diagnose(LOG)


# `Timeout` is bound to channel.py's BASE error, not to TimeoutErr alone, on
# purpose. Callers here (`tools/ui.py`, `tools/enterraid.py`) do `except
# Timeout:` and print the message; channel.py can also raise ChannelMissing
# ("D:\\Aowlspt\\aowlspt does not exist"), which the old hand-rolled loop
# turned into a 25-second wait and then a timeout. Catching the base class
# keeps those callers graceful AND lets the message name the real cause, rather
# than reporting a missing install as a silent host. `.kind` distinguishes them
# ("timeout" / "channel_missing") for anything that wants to branch.
Timeout = _ch.InspectorError


def run_batch(lines, timeout=25.0, write=False):
    """Send one batch and return its answer text.

    Exposed as a function, not just a CLI, because a script that DRIVES the
    menu is a sequence of batches whose later commands depend on pointers
    parsed out of earlier answers -- the per-batch anchors ($f1, $comp) do not
    survive across batches, so the pointers have to come back out to the caller.

    DE-FORKED: this used to be a second hand-rolled sentinel/poll loop, and its
    sentinel was `int(time.time()*1000) % 1000000` -- which WRAPS every ~17
    minutes and is therefore reusable within one long session. Reading a stale
    out-file whose sentinel happened to match is the exact failure the sentinel
    exists to prevent. It now delegates to channel.py's `run_batch`, whose
    sentinel is a never-reused monotonic counter plus wall clock. The return
    shape here (answer text only, `Timeout` on failure) is unchanged, so
    `tools/ui.py` and `tools/enterraid.py` are unaffected.
    """
    _sentinel, text = _ch.run_batch(list(lines), timeout=timeout, write=write)
    return text


def selftest():
    """Three fixtures, each of which CAN fail, for the 2026-08-31 channel bugs.

    1. WEDGED is reported as WEDGED. The host's watchdog prints prose that says
       "no batch queued" while its own counters in the SAME line say batch=9
       done=-1 -- i.e. it accepted batch 9 and never finished it. Batches WERE
       queued; the prose is false. A fixture of that exact line must come back
       WEDGED, and a healthy line (done caught up) must come back None.
    2. A STALE OUT-FILE IS REFUSED, NOT PARSED. This is the dangerous one: a
       consumer that reads the previous batch's answers as its own gets a
       confidently wrong result rather than an error. The fixture serves an
       out-file that is a complete, plausible answer to a DIFFERENT batch;
       run_batch must time out rather than return it.
    3. TWO WRITERS CANNOT INTERLEAVE. The second holder of the channel lock
       must raise ChannelBusy -- distinct from a timeout, because blaming the
       host for a shell-side collision is how the last one was misdiagnosed.
    """
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from ui import channel_verdict
    bad = 0

    def case(label, ok, extra=""):
        nonlocal bad
        if not ok:
            bad += 1
        print("%-4s %s%s" % ("ok" if ok else "FAIL", label, extra))

    # The post-162d3b8 watchdog shape, which carries `delivered=` and `running=`.
    def line(head, batch, delivered, running, done=-1):
        return ("2026-08-31 20:19:49 WARN live inspector: %s -- the rider IS "
                "dispatching (9 fires). polls=8916 reads=579 readFails=0 "
                "unchanged=570 lastRead=1881B lastKnown=1881B pending=0 "
                "batch=%d delivered=%d running=%d "
                "done(handshake,cleared-on-delivery)=%d suspended=false "
                "abandons=0 inFlight=true  file=D:\\Aowlspt\\aowlspt\\"
                "aowlspt-inspect.txt" % (head, batch, delivered, running, done))

    WEDGED = line("WEDGED -- batch 9 was claimed by Unity's thread 130s ago and "
                  "has NOT completed; it is stuck at command 12 of 58: tree $r3",
                  9, 8, 9)
    # THE CASE THAT WOULD HAVE CAUGHT THE BUG, and whose absence is why it
    # shipped. This is the REAL healthy state: everything delivered, the
    # handshake cleared to -1 by the delivery path itself (inspect.nim:7014),
    # nothing running. The first predicate (`done < batch`) called this WEDGED.
    HEALTHY_IDLE = line("IDLE and HEALTHY -- batch 9 completed and its answers "
                        "were delivered. No NEW batch has been queued for 130s "
                        "because the command file's CONTENT has not changed.",
                        9, 9, -1, done=-1)
    QUEUED = line("batch 10 is QUEUED and has not been claimed for 12s",
                  10, 9, -1)
    # The pre-162d3b8 shape. Undecidable, and it must SAY so.
    OLD = ("2026-08-31 18:40:02 WARN live inspector: no batch queued for 130s "
           "while the rider IS dispatching (9 fires). polls=4210 reads=4210 "
           "readFails=0 unchanged=4209 lastRead=1485B lastKnown=1485B "
           "pending=0 batch=9 done=-1 suspended=false inFlight=true")

    s, n = channel_verdict(text=WEDGED)
    case("a genuinely wedged line reports WEDGED", s == "WEDGED")
    case("  ...and it relays the host's own stuck-command detail",
         s == "WEDGED" and "stuck at command 12 of 58" in (n or ""))

    s, n = channel_verdict(text=HEALTHY_IDLE)
    case("HEALTHY IDLE (done=-1, delivered==batch, running=-1) reports HEALTHY",
         s == "HEALTHY",
         "\n     <- THE REGRESSION CASE. `done=-1` is the NORMAL state of a "
         "delivered\n        channel (inspect.nim:7014 clears it ON SUCCESS); "
         "the first predicate\n        `done < batch` called this WEDGED, a "
         "false positive on the happy path.")

    s, _n = channel_verdict(text=QUEUED)
    case("a queued-but-unclaimed batch is NOT wedged", s == "HEALTHY")

    s, n = channel_verdict(text=OLD)
    case("a pre-162d3b8 host reports UNKNOWN, not HEALTHY", s == "UNKNOWN")
    case("  ...and says the wedge was NOT CHECKED",
         s == "UNKNOWN" and "NOT CHECKED" in (n or ""),
         "  <- 'I could not look' must never read as a pass")

    s, _n = channel_verdict(text="nothing to see here")
    case("a log with no watchdog line at all reports UNKNOWN", s == "UNKNOWN")

    # --- 2. a stale out-file must never be returned -------------------------
    stale = ("> roots\n[$r0] transform=0xdead go=0xbeef ($rgo0) name=\"Menu UI\"\n"
             "aowl-batch-1755000000000-0\n")     # a PREVIOUS batch's sentinel
    served = {"body": None}

    def fake_write(body):
        served["body"] = body

    try:
        _ch.run_batch(["roots"], live_dir="X", timeout=0.5,
                      read_out=lambda: stale, write_cmd=fake_write,
                      sleep=lambda s: None, lock=False)
        case("a stale out-file is REFUSED, not parsed", False,
             "  <- it RETURNED the previous batch's answer")
    except _ch.TimeoutErr:
        case("a stale out-file is REFUSED, not parsed (TimeoutErr raised)", True)

    # And the negative: when the CURRENT sentinel is there, it does return.
    def read_fresh():
        s = served["body"].splitlines()[0][1:]
        return "> roots\nfine\n%s\n" % s
    try:
        _s, text = _ch.run_batch(["roots"], live_dir="X", timeout=0.5,
                                 read_out=read_fresh, write_cmd=fake_write,
                                 sleep=lambda s: None, lock=False)
        case("a FRESH out-file is accepted", "fine" in text,
             "  <- this is what makes the stale case falsifiable")
    except _ch.TimeoutErr:
        case("a FRESH out-file is accepted", False)

    # --- 3. two writers cannot interleave -----------------------------------
    import tempfile
    lp = os.path.join(tempfile.gettempdir(), "aowlspt-selftest-%d.lock"
                      % os.getpid())
    try:
        with _ch._Lock(lp, timeout=0.3):
            try:
                with _ch._Lock(lp, timeout=0.3, sleep=lambda s: None):
                    case("a second writer is refused while the first holds it",
                         False, "  <- it acquired the lock TWICE")
            except _ch.ChannelBusy as e:
                case("a second writer is refused with ChannelBusy", True)
                case("  ...and ChannelBusy is NOT a timeout",
                     e.kind == "channel_busy" and
                     not isinstance(e, _ch.TimeoutErr))
        # released
        with _ch._Lock(lp, timeout=0.3) as l2:
            case("the lock is released afterwards (a third writer gets it)",
                 l2.held)
    finally:
        try:
            os.unlink(lp)
        except OSError:
            pass

    print("\n%s: %d case(s) failed" % ("FAIL" if bad else "PASS", bad))
    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--selftest", action="store_true",
                    help="prove wedge detection, stale-answer refusal and the "
                         "single-writer lock; needs no game")
    ap.add_argument("cmds", nargs="*", help="one inspector command per argument")
    ap.add_argument("-f", "--file", help="read the batch from a file ('-' = stdin)")
    ap.add_argument("--timeout", type=float, default=25.0,
                    help="seconds to wait for THIS batch's answer (default 25)")
    ap.add_argument("--write", action="store_true",
                    help="prepend 'allow write' (still needs liveInspectorWrite)")
    ap.add_argument("--raw", action="store_true", help="print the answer only")
    a = ap.parse_args()
    if a.selftest:
        return selftest()

    lines = []
    if a.file:
        src = sys.stdin.read() if a.file == "-" else read(a.file)
        lines = [l.rstrip() for l in src.splitlines() if l.strip()]
    lines += list(a.cmds)
    if not lines:
        ap.error("no commands given")
    if a.write:
        lines.insert(0, "allow write")

    if not os.path.isdir(LIVE):
        print("!! %s does not exist -- is the game installed there?" % LIVE,
              file=sys.stderr)
        return 3

    # DE-FORKED, 2026-08-31. This used to be a THIRD hand-rolled sentinel loop,
    # and it was the broken one: its serial was `int(time.time()*1000) % 1000000`
    # (wraps every ~17 minutes, so it is reusable inside one long session -- the
    # exact stale-answer case the sentinel exists to prevent), and it called
    # `time.time()` with `time` NEVER IMPORTED in this module, so the CLI path
    # raised NameError instead of ever running. Both are gone: it now delegates
    # to the one transport, which also takes the channel lock.
    try:
        sentinel, text = _ch.run_batch(lines, timeout=a.timeout)
    except _ch.InspectorError as e:
        print("!! %s" % e, file=sys.stderr)
        if getattr(e, "kind", "") == "channel_missing":
            return 3
        # A timeout is not always idleness. Ask the host's own counters.
        try:
            sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
            from ui import wedge_verdict
            w = wedge_verdict(LOG)
        except Exception:
            w = None
        print(w or diagnose(), file=sys.stderr)
        return 2
    if not a.raw:
        print("--- %s: %d command(s) ---" % (sentinel, len(lines)))
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
