#!/usr/bin/env python3
r"""test_supervise.py -- prove run.py's verdicts CAN FIRE. No game required.

    python tools/test_supervise.py
    python tools/test_supervise.py -v

## Why this exists

Every verdict `run.py` produces is a check, and CLAUDE.md 9b is blunt about
checks: one that cannot fail is the bug. The two verdicts added here --
`STALLED` and `BACKENDDOWN` -- were added precisely BECAUSE the existing
liveness check could never fire. Shipping their replacements without showing
them fire would repeat the mistake one layer up.

So this drives the real `Supervisor` class against synthetic log files in a
temp directory. Nothing is stubbed except the clock and the filesystem paths:
the parsing, the tailing, the heartbeat classification and the phase bound are
the same code the live tool runs.

## The negative tests are the point

Three of these assert that something does NOT happen, because that is the
falsifiable direction:

  * a stream of heartbeats does NOT refresh the progress clock (the actual
    25-minute bug -- the positive version of this test passes trivially);
  * a phase that keeps CHANGING does NOT trip the stall bound, however long
    the run goes on;
  * `--phase-max 0` does NOT bound anything.

A test that only ever feeds a supervisor bad input proves it can say no. These
feed it good input too, which is the half that catches a checker wired to fail
always -- the mirror-image bug, and just as useless.
"""

from __future__ import annotations

import os
import shutil
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import run as runmod   # noqa: E402  -- the code under test, not a copy of it

VERBOSE = "-v" in sys.argv


class Bed:
    """A fake D:\\Aowlspt: an install dir with a host log and a backend log."""

    def __init__(self):
        self.root = tempfile.mkdtemp(prefix="aowl-sup-")
        os.makedirs(os.path.join(self.root, "aowlspt"))
        os.makedirs(os.path.join(self.root, "Logs"))
        self.host = os.path.join(self.root, "aowlspt", "aowlspt-host.log")
        self.backend = os.path.join(self.root, "aowlspt",
                                    "aowlspt-backend.log")
        open(self.host, "w").close()
        open(self.backend, "w").close()

    def sup(self, **kw):
        kw.setdefault("until", None)
        kw.setdefault("stall", 45)
        kw.setdefault("quiet", True)
        s = runmod.Supervisor(self.root, kw["until"], kw["stall"], kw["quiet"],
                              phase_max=kw.get("phase_max", 900.0))
        # The real host log path comes from harness; point it at the bed.
        s.host_path = self.host
        s.host_pos = 0
        s.backend_path = self.backend
        s.backend_pos = 0
        # No client log dir in the bed -- poll_client is exercised elsewhere.
        s.tailers = {}
        return s

    def say(self, line):
        with open(self.host, "a", encoding="utf-8") as f:
            f.write(line + "\n")

    def backend_say(self, line):
        with open(self.backend, "a", encoding="utf-8") as f:
            f.write(line + "\n")

    def close(self):
        shutil.rmtree(self.root, ignore_errors=True)


RESULTS = []


def check(name, cond, detail=""):
    RESULTS.append((name, bool(cond), detail))
    if VERBOSE or not cond:
        print("  %-5s %s%s" % ("ok" if cond else "FAIL", name,
                               ("  -- " + detail) if detail else ""))


def phase_line(ph):
    return ("[0:01:02.000] ok     natesp: raid phase = %s -- S1: synthetic"
            % ph)


# -- 1. STALLED fires when one phase persists ----------------------------
def t_stalled_fires():
    b = Bed()
    try:
        s = b.sup(phase_max=5.0)
        b.say(phase_line("DEPLOYED"))
        hit = s.poll_host()
        check("stalled/first-phase-is-not-a-stall", hit is None,
              "a phase seen for the first time must never be a stall")
        # Rewind the phase clock rather than sleeping: the bound is a
        # comparison against phase_since, and sleeping 5s per test is how a
        # suite stops being run.
        s.phase_since = time.time() - 6.0
        b.say(phase_line("DEPLOYED"))
        hit = s.poll_host()
        check("stalled/fires", hit is not None and hit[0] == "STALLED",
              repr(hit)[:120])
    finally:
        b.close()


# -- 2. NEGATIVE: a changing phase never stalls --------------------------
def t_progress_never_stalls():
    b = Bed()
    try:
        s = b.sup(phase_max=5.0)
        verdicts = []
        for i, ph in enumerate(["MENU", "LOADING", "DEPLOYED", "MENU",
                                "LOADING", "DEPLOYED"]):
            s.phase_since = time.time() - 600.0   # always "long ago"
            b.say(phase_line(ph))
            h = s.poll_host()
            if h:
                verdicts.append((i, ph, h[0]))
        check("stalled/progress-does-not-trip", not verdicts,
              "a phase CHANGE must re-arm the bound; got %r" % (verdicts,))
    finally:
        b.close()


# -- 3. NEGATIVE: phase_max=0 disables the bound -------------------------
def t_bound_disable():
    b = Bed()
    try:
        s = b.sup(phase_max=0.0)
        b.say(phase_line("DEPLOYED"))
        s.poll_host()
        s.phase_since = time.time() - 100000.0
        b.say(phase_line("DEPLOYED"))
        check("stalled/zero-disables", s.poll_host() is None)
    finally:
        b.close()


# -- 4. THE BUG ITSELF: heartbeats are not progress ----------------------
def t_heartbeat_is_not_progress():
    b = Bed()
    try:
        s = b.sup(phase_max=0.0)          # bound off: isolate the clock
        b.say(phase_line("MENU"))
        s.poll_host()                      # first sighting sets the phase
        s.last_progress = time.time() - 300.0
        before = s.last_progress
        for _ in range(20):
            b.say(phase_line("MENU"))      # 20 heartbeats, same phase
        s.poll_host()
        check("heartbeat/does-not-refresh-clock", s.last_progress == before,
              "THE 25-minute bug: %d heartbeats moved the progress clock by "
              "%.1fs" % (20, s.last_progress - before))

        # ...and a REAL line does refresh it, or the clock is simply broken.
        b.say("[0:01:03.000] ok     mod loading screen: BUILT")
        s.poll_host()
        check("heartbeat/real-line-does-refresh", s.last_progress > before)
    finally:
        b.close()


# -- 5. BACKENDDOWN fires, and only on the real literal ------------------
def t_backend_down():
    b = Bed()
    try:
        s = b.sup()
        b.backend_say("[info] listening on 127.0.0.1:6969")
        check("backend/healthy-is-not-a-verdict", s.poll_backend() is None)
        b.backend_say("BACKEND DOWN -- aowlspt-backend died 5 times in 30s")
        hit = s.poll_backend()
        check("backend/fires", hit is not None and hit[0] == "BACKENDDOWN",
              repr(hit)[:120])
    finally:
        b.close()


# -- 6. the pre-existing verdicts still fire -----------------------------
def t_existing_verdicts():
    # ONE BED PER CASE. Sharing a bed silently broke three of these: a second
    # Supervisor over the same log starts at byte 0, re-reads the first case's
    # ERRORDIALOG line and returns THAT -- so the later cases were reported
    # against a verdict they never produced. A shared fixture that carries
    # state between cases is the test-suite form of the same class of bug this
    # file exists to catch.
    def case(name, lines, want, **kw):
        b = Bed()
        try:
            s = b.sup(**kw)
            for l in lines:
                b.say(l)
            hit = s.poll_host()
            got = hit[0] if hit else None
            check(name, got == want, "wanted %r, got %r" % (want, got))
        finally:
            b.close()

    case("errordialog/fires",
         ['[0:00:01] ERRORDIALOG kind=23 header="Error" text="boom"'],
         "ERRORDIALOG")
    case("errordialog/suppression-notice-is-not-a-dialog",
         ['[0:00:02] ERRORDIALOG kind=23 header="<suppressed>" text=""'],
         None)
    case("died/host-reported-fatal-fires",
         ["[0:00:03] il2cpp_init returned 0"], "DIED")
    case("reached/fires",
         ["[0:00:04] ok     host running"], "REACHED", until="host running")


# -- 7. every verdict has a DISTINCT exit code ---------------------------
def t_exit_codes_distinct():
    codes = list(runmod.EXIT.values())
    check("exit/codes-are-distinct", len(codes) == len(set(codes)),
          "duplicate exit code makes two verdicts indistinguishable to a "
          "caller: %r" % (runmod.EXIT,))


def main():
    for fn in (t_stalled_fires, t_progress_never_stalls, t_bound_disable,
               t_heartbeat_is_not_progress, t_backend_down,
               t_existing_verdicts, t_exit_codes_distinct):
        if VERBOSE:
            print("%s:" % fn.__name__)
        try:
            fn()
        except Exception as e:
            check(fn.__name__ + "/raised", False, "%s: %s" % (type(e).__name__, e))

    bad = [r for r in RESULTS if not r[1]]
    print("\n%s -- %d/%d checks passed"
          % ("PASS" if not bad else "FAIL", len(RESULTS) - len(bad),
             len(RESULTS)))
    if bad:
        for n, _ok, d in bad:
            print("   FAILED  %s  %s" % (n, d))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
