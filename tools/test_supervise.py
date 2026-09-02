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
import subprocess
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
                              phase_max=kw.get("phase_max", 900.0),
                              until_phase=kw.get("until_phase"),
                              menu_settle=kw.get("menu_settle", 20.0))
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
         ["[0:00:03] error  the runtime did not come up: the il2cpp_init "
          "lookup was armed, init was handed out 1 time(s)"], "DIED")

    # REGRESSION, and an expensive one. `il2cpp_init returned 0` is logged at
    # fail level from INSIDE aowlhost's wait loop, which then keeps going for
    # up to 120s and usually succeeds. It was in FATAL_HOST_LINES, so the
    # supervisor killed three healthy launches at ~7s and blamed the host, the
    # deploy and BattlEye in turn. A mid-progress line must NEVER be terminal.
    case("died/mid-wait-progress-is-not-fatal",
         ["[0:00:01.719] error  il2cpp_init returned 0 after 1500ms, which is "
          "a failure: the runtime did not initialise",
          "[0:00:11.328] info   still waiting for the runtime (10s)"],
         None)
    case("reached/fires",
         ["[0:00:04] ok     host running"], "REACHED", until="host running")


# -- 6b. MENU is not "reached" on first sight -----------------------------
def t_menu_must_settle():
    # THE TRAP, measured: `raid phase = MENU` is published at ~0:00:09 on
    # every boot because it only means "no GameWorld is cached". run.py
    # returned REACHED on that first line for a client that then died at
    # 0:00:15. MENU must only count once it has HELD with no other progress.
    b = Bed()
    try:
        s = b.sup(until_phase="MENU", phase_max=0.0)
        s.menu_settle = 20.0
        b.say(phase_line("MENU"))                 # first sighting, early boot
        hit = s.poll_host()
        check("menu/first-sighting-is-not-reached", hit is None, repr(hit)[:100])
        b.say("[0:00:12] ok     mods tab: GetComponent bound")   # real progress
        s.poll_host()
        b.say(phase_line("MENU"))
        hit = s.poll_host()
        check("menu/heartbeat-right-after-progress-is-not-reached",
              hit is None, repr(hit)[:100])
        s.last_progress = time.time() - 25.0      # quiet for longer than settle
        b.say(phase_line("MENU"))
        hit = s.poll_host()
        check("menu/settled-is-reached",
              hit is not None and hit[0] == "REACHED", repr(hit)[:120])
        # DEPLOYED must still arrive immediately -- only MENU needs settling.
        s2 = b.sup(until_phase="DEPLOYED", phase_max=0.0)
        b.say(phase_line("DEPLOYED"))
        hit = s2.poll_host()
        check("menu/deployed-arrives-immediately",
              hit is not None and hit[0] == "REACHED", repr(hit)[:120])
    finally:
        b.close()


# -- 6c. the TEARDOWN announcement ---------------------------------------
#
# `run.py` without `--keep` force-stops the client, the backend and the
# launcher the moment the verdict lands. Read afterwards that is
# INDISTINGUISHABLE from a clean crash: the host log ends on a heartbeat, no
# fault line, no crash folder. It cost twenty minutes once. The default is
# deliberately unchanged; what must be true is that the teardown says so, in
# the verdict block AND in a file a later reader of the install directory will
# find.
#
# HOW THIS AVOIDS KILLING ANYTHING: `run.py --dry-teardown` means "this
# invocation stops no processes" -- it covers both the pre-launch kill and the
# post-verdict one, and it still prints the line and still writes the note, so
# the code path under test is the real one. No mocking, no monkeypatching, and
# nothing here calls Stop-Process.

def _run_bed():
    """A fake D:\\Aowlspt for a full `run.py main()` pass.

    The launcher is a COPY of this interpreter, invoked as `python -c pass`, so
    the spawn is real (Popen of a real .exe in a real cwd) and exits at once.
    """
    root = tempfile.mkdtemp(prefix="aowl-teardown-")
    inst = os.path.join(root, "aowlspt")
    os.makedirs(inst)
    os.makedirs(os.path.join(root, "Logs"))
    open(os.path.join(inst, "aowlspt-host.log"), "w").close()
    shutil.copy(sys.executable, os.path.join(inst, "aowlspt-launch.exe"))
    return root, inst


def _run_py(root, extra, timeout=90):
    cmd = [sys.executable, os.path.join(HERE, "run.py"), "--root", root,
           "--timeout", "2", "--stall", "1", "--dry-teardown",
           "--launcher-arg", "-c pass"] + list(extra)
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout + r.stderr


def t_teardown_announced():
    root, inst = _run_bed()
    note = os.path.join(inst, runmod.TEARDOWN_LOG)
    try:
        rc, out = _run_py(root, [])
        check("teardown/line-in-verdict-block", "TEARDOWN:" in out,
              "a silent teardown reads as a crash afterwards; got %r"
              % out[-300:])
        check("teardown/line-names-the-escape-hatch", "--keep" in out)
        check("teardown/note-written", os.path.isfile(note),
              "expected %s" % note)
        if os.path.isfile(note):
            txt = open(note, encoding="utf-8").read()
            check("teardown/note-has-the-same-sentence",
                  runmod.TEARDOWN_LINE in txt, repr(txt)[:200])
            # A note with no timestamp cannot answer "was the client stopped at
            # THAT second", which is the only question it exists to answer.
            check("teardown/note-is-timestamped",
                  txt.lstrip().startswith("[") and ":" in txt.split("]")[0],
                  repr(txt)[:120])
            _run_py(root, [])
            n = open(note, encoding="utf-8").read().count(runmod.TEARDOWN_LINE)
            check("teardown/note-appends", n == 2,
                  "a second run must ADD a line, not replace the file; "
                  "found %d" % n)
    finally:
        shutil.rmtree(root, ignore_errors=True)


def t_teardown_silent_with_keep():
    # THE FALSIFYING HALF. If the line were printed unconditionally, the test
    # above would pass while telling the reader something false.
    root, inst = _run_bed()
    note = os.path.join(inst, runmod.TEARDOWN_LOG)
    try:
        rc, out = _run_py(root, ["--keep"])
        check("teardown/keep-prints-nothing", "TEARDOWN:" not in out,
              "with --keep nothing is stopped, so the warning must not "
              "appear; got %r" % out[-300:])
        check("teardown/keep-writes-no-note", not os.path.isfile(note))
    finally:
        shutil.rmtree(root, ignore_errors=True)


# -- 6d. THE MEASURED FALSE STALLED --------------------------------------
#
# 2026-09-01 23:03. Three consecutive boots of ONE build, one client state --
# alive, parked at the main menu, host heartbeating -- produced THREE different
# verdicts:
#
#   bootT  --phase-max 200  -> STALLED at 219s   (exit 8)   FALSE
#   bootR  --phase-max 900  -> TIMEOUT at 300s   (exit 2)   FALSE
#   bootL  (inspector idle line absent) -> REACHED at 119.7s          correct
#
# The cause was not a threshold. `--menu-settle` measured quiet against
# `last_progress`, which every PERIODIC status line refreshed, while the phase
# bound measured against `phase_since`, which they did not. The two rules
# disagreed about whether a parked client was making progress, and the
# disagreement was settled by which periodic line happened to land in the
# window -- bootL differs from bootT only in that nobody was driving the live
# inspector on it, so its 15s `IDLE and HEALTHY` line was absent and a 20s
# quiet window could open.
#
# These replay all three from synthetic logs on the measured cadences. The
# clock is virtual (a shim over `run.time`) so a 350-second run costs
# milliseconds; everything else -- the tailing, the classification, the
# ordering -- is the real code.

class Clock:
    """A stand-in for the `time` module inside run.py. Only .time() moves."""

    def __init__(self, t0=1_000_000.0):
        self.t = t0

    def time(self):
        return self.t

    def sleep(self, s):
        self.t += s

    def strftime(self, *a, **k):
        return time.strftime(*a, **k)


# Cadences measured off the three runs, in host-relative seconds.
# (substring, first emission, period).  period=None means one-shot.
PERIODIC_MEASURED = [
    ("[t] warn live inspector: IDLE and HEALTHY -- batch 9 completed",
     31.0, 15.0),
    ("[t] info ammoloading  ARMED but NEVER FIRED. mode=probe", 28.0, 30.0),
    ("[t] warn natesp: VERDICT STILL INCONCLUSIVE after N unchanged cycle(s)",
     69.0, 60.0),
    ("[t] warn Maps: diag STILL NOT-PASS after N unchanged cycle(s)",
     81.0, 60.0),
    ("[t] info camera: acquire=Camera.main is null -- menu", 8.0, 60.0),
    ("[t] ok   client settings bridge: published 8 of 8 client-side "
     "settings page(s)", 16.0, 60.0),
]

# The REAL progress of a boot, measured: the host log is DENSE from attach to
# ~0:00:45 (hundreds of lines: flag banners, RVA verifications, the FOV block),
# thins out, and the last genuinely new thing it says is at ~0:01:04 -- after
# which it says nothing new for the rest of the run. The early density matters:
# without it the settle window opens during the boot, which is the trap
# `menu/first-sighting-is-not-reached` already guards.
PROGRESS_MEASURED = [(float(t), "[t] info boot chatter %d" % t)
                     for t in range(0, 37)] + [
    (37.0, "[t] ok   the main-thread drain is firing again"),
    (41.0, "[t] info FOV, what was actually applied:"),
    (42.0, "[t] ok   hide seasons: the banner came back after a menu rebuild"),
    (54.0, "[t] info region projector: not installed yet -- bind state 3"),
    (64.0, "[t] warn hide mode button: GIVING UP after 30 post-warm-up walks"),
]

LAST_REAL_PROGRESS_S = 64.0


def replay(bed, sup, clock, horizon, periodics, progress, phase_from=8.0,
           die_at=None):
    """Drive `sup` over a synthetic boot in virtual time. Returns the first
    verdict and the virtual second it landed on, or (None, horizon)."""
    events = list(progress)
    for text, first, period in periodics:
        t = first
        while t <= horizon:
            events.append((t, text))
            if not period:
                break
            t += period
    # the 5s raid-phase heartbeat
    t = phase_from
    while t <= horizon:
        events.append((t, phase_line("MENU")))
        t += 5.0
    if die_at is not None:
        events = [e for e in events if e[0] < die_at]
    events.sort(key=lambda e: e[0])

    t0 = clock.t
    i = 0
    vt = 0.0
    while vt <= horizon:
        clock.t = t0 + vt
        while i < len(events) and events[i][0] <= vt:
            bed.say(events[i][1])
            i += 1
        hit = sup.poll_host() or sup.check_clocks(clock.time())
        if hit:
            return hit, vt
        vt += 1.0
    return None, horizon


def _with_clock(fn):
    clock = Clock()
    real = runmod.time
    runmod.time = clock
    try:
        return fn(clock)
    finally:
        runmod.time = real


def t_measured_false_stalled():
    def body(clock):
        # bootT, exactly: --until-phase MENU --phase-max 200, and the live
        # inspector's 15s line present because another session was driving it.
        b = Bed()
        try:
            s = b.sup(until_phase="MENU", phase_max=200.0, menu_settle=20.0,
                      stall=45.0)
            s.phase_since = clock.t
            s.last_progress = clock.t
            hit, vt = replay(b, s, clock, 260.0, PERIODIC_MEASURED,
                             PROGRESS_MEASURED)
            got = hit[0] if hit else None
            check("measured/bootT-is-not-stalled", got == "REACHED",
                  "the 219s false STALLED: a client parked at the menu with "
                  "the host heartbeating must REACH, not stall. got %r at "
                  "t=%ss -- %s" % (got, vt, (hit[1][:110] if hit else "")))
            # ...and it must arrive at the settle window, not at the bound.
            check("measured/bootT-arrives-at-the-settle-window",
                  hit is not None and LAST_REAL_PROGRESS_S + 20.0 <= vt <= 95.0,
                  "expected ~%ds (last real progress %ds + settle 20s), got %s"
                  % (LAST_REAL_PROGRESS_S + 20, LAST_REAL_PROGRESS_S, vt))
        finally:
            b.close()
    _with_clock(body)


def t_measured_control_run():
    # bootL: the run that was already CORRECT. It differs from bootT only by
    # the absence of the 15s inspector line. A fix that changed this one would
    # be changing the answer that was already right -- this is the negative
    # control on the whole change.
    def body(clock):
        b = Bed()
        try:
            s = b.sup(until_phase="MENU", phase_max=900.0, menu_settle=20.0,
                      stall=45.0)
            s.phase_since = clock.t
            s.last_progress = clock.t
            periodics = [p for p in PERIODIC_MEASURED
                         if "IDLE and HEALTHY" not in p[0]]
            hit, vt = replay(b, s, clock, 260.0, periodics, PROGRESS_MEASURED)
            got = hit[0] if hit else None
            check("measured/bootL-still-reaches", got == "REACHED",
                  "got %r at t=%ss" % (got, vt))
            check("measured/bootL-time-unchanged",
                  hit is not None and LAST_REAL_PROGRESS_S + 20.0 <= vt <= 95.0,
                  "the already-correct run must not move; got t=%ss" % vt)
        finally:
            b.close()
    _with_clock(body)


def t_measured_real_stall_stays_stalled():
    # THE FALSIFYING HALF, and the reason the arrival rule carries a liveness
    # qualifier. A host that keeps making REAL progress and then stops dead
    # must not be laundered into REACHED by the settle window -- quiet is a
    # subset of silence, so without the qualifier arrival (20s) would always
    # beat silence (45s) and this verdict could never fire.
    def body(clock):
        b = Bed()
        try:
            s = b.sup(until_phase="MENU", phase_max=900.0, menu_settle=20.0,
                      stall=45.0)
            s.phase_since = clock.t
            s.last_progress = clock.t
            # Real progress right up to the INSTANT everything stops. That
            # detail is the whole scenario: a host that goes quiet ten seconds
            # BEFORE it dies is genuinely ambiguous at the moment the settle
            # window closes, and this suite does not assert a hard verdict on
            # an ambiguous input. "Progressing, then gone" is not ambiguous.
            progress = [(float(t), "[t] ok   settings page %d rendered" % t)
                        for t in range(20, 200, 5)]
            hit, vt = replay(b, s, clock, 400.0, PERIODIC_MEASURED, progress,
                             die_at=200.0)
            got = hit[0] if hit else None
            check("measured/dead-host-at-menu-stays-stalled", got == "STALLED",
                  "the host stopped printing entirely at t=200s; got %r at "
                  "t=%ss -- %s" % (got, vt, (hit[1][:110] if hit else "")))
            check("measured/dead-host-stalls-at-the-stall-window",
                  hit is not None and 240.0 <= vt <= 260.0,
                  "expected ~245s (silence began at 199s + stall 45s), got %s"
                  % vt)
            check("measured/dead-host-verdict-names-the-heartbeat",
                  hit is not None and "heartbeat" in hit[1],
                  "the verdict must say WHY silence is decisive; got %r"
                  % (hit[1][:120] if hit else None))
            # THE ORDERING MUST BE EXPRESSIBLE AT THE DEFAULTS. Arrival is
            # gated on the host having heartbeated within
            # HOST_HEARTBEAT_S * 3; if that allowance were >= --menu-settle,
            # arrival could never be blocked and the STALLED above could never
            # fire -- a check that cannot fail.
            check("measured/liveness-allowance-is-below-default-settle",
                  runmod.HOST_HEARTBEAT_S * 3 < 20.0,
                  "allowance %.0fs vs default --menu-settle 20s"
                  % (runmod.HOST_HEARTBEAT_S * 3))
        finally:
            b.close()
    _with_clock(body)


def t_stall_at_destination_needs_total_silence():
    # THE FALSIFYING HALF of the false positive itself. The bug reported
    # STALLED for a client sitting in exactly the phase --until-phase asked
    # for, while the host was still heartbeating. Drive well past --phase-max
    # with heartbeats only and assert the run never stalls -- and then, with
    # NO --until-phase, assert the same input DOES stall, so the exemption is
    # shown to be the reason and not an accidental pass.
    def body(clock):
        for dest, want in (("MENU", None), (None, "STALLED")):
            b = Bed()
            try:
                s = b.sup(until_phase=dest, phase_max=30.0, menu_settle=20.0,
                          stall=45.0)
                s.phase_since = clock.t
                s.last_progress = clock.t
                # Heartbeats ONLY, forever. No progress at all.
                hit, vt = replay(b, s, clock, 120.0, [], [], phase_from=1.0)
                got = hit[0] if hit else None
                if dest == "MENU":
                    # With --until-phase MENU this must ARRIVE, never stall.
                    check("destination/never-stalls-while-heartbeating",
                          got == "REACHED",
                          "the measured false positive: phase_max 30s passed "
                          "at the requested destination; got %r at t=%ss"
                          % (got, vt))
                else:
                    check("destination/exemption-is-what-spares-it",
                          got == want,
                          "the SAME input with no --until-phase must still "
                          "stall, or the test above proves nothing; got %r"
                          % got)
            finally:
                b.close()
    _with_clock(body)


def t_periodic_table_is_honest():
    # A heartbeat entry that swallows a REAL line silently deletes progress,
    # which is worse than a missing entry. Two directions, both falsifiable.
    for text in ("[t] warn live inspector: IDLE and HEALTHY -- batch 9",
                 "[t] info ammoloading  ARMED but NEVER FIRED. mode=probe",
                 "[t] warn Maps: diag STILL NOT-PASS after 90 unchanged "
                 "cycle(s) (180s)",
                 "[t] ok   natesp: raid phase = MENU -- S1: synthetic"):
        check("periodic/suppresses %s" % text[10:38].strip(),
              not runmod.is_progress(text))
    # MEASURED one-shots. Each occurs EXACTLY ONCE per boot in all three runs,
    # so classifying them as periodic would delete the last real progress a
    # parked boot ever makes -- which is precisely the line the settle window
    # is measured from.
    for text in ("[t] ok   version brand: the bottom label now reads "
                 "\"aowlspt beta9\"",
                 "[t] ok   hide seasons: the banner came back after a menu "
                 "rebuild",
                 "[t] warn hide mode button: GIVING UP after 30 post-warm-up "
                 "walks",
                 "[t] ok   the main-thread drain is firing again",
                 "[t] ok   Maps: diag NOT-PASS: placement:INCONCLUSIVE",
                 "[t] ok   inspect| aowlspt live inspector -- batch 10"):
        check("periodic/keeps %s" % text[10:38].strip(),
              runmod.is_progress(text))


# -- 7. every verdict has a DISTINCT exit code ---------------------------
def t_exit_codes_distinct():
    codes = list(runmod.EXIT.values())
    check("exit/codes-are-distinct", len(codes) == len(set(codes)),
          "duplicate exit code makes two verdicts indistinguishable to a "
          "caller: %r" % (runmod.EXIT,))


def main():
    for fn in (t_stalled_fires, t_progress_never_stalls, t_bound_disable,
               t_heartbeat_is_not_progress, t_backend_down,
               t_existing_verdicts, t_menu_must_settle,
               t_periodic_table_is_honest, t_measured_false_stalled,
               t_measured_control_run, t_measured_real_stall_stays_stalled,
               t_stall_at_destination_needs_total_silence,
               t_teardown_announced, t_teardown_silent_with_keep,
               t_exit_codes_distinct):
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
