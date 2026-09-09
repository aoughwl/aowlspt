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
import crashwatch      # noqa: E402  -- the real tailers, not a stand-in
import runledger       # noqa: E402  -- the real ledgers, not a stand-in

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
        # The CLIENT's own session dir, created on demand. Named the way
        # crashwatch's `newest_log_dir` globs for it (`log_*`), with the
        # stamp-prefixed file names `resolve_files` matches by suffix -- so the
        # real Tailer, the real classifier and the real suffix resolution run.
        self.client_dir = None
        self.client_files = {}

    def client_log(self, *suffixes):
        d = os.path.join(self.root, "Logs", "log_2026.09.02_8-09-51_1.1.0")
        if not os.path.isdir(d):
            os.makedirs(d)
        self.client_dir = d
        for suf in suffixes or ("output_000.log",):
            p = os.path.join(d, "2026.09.02_8-09-51_1.1.0 " + suf)
            open(p, "a").close()
            self.client_files[suf] = p
        return d

    def client_say(self, text, suf=None):
        suf = suf or sorted(self.client_files)[0]
        with open(self.client_files[suf], "a", encoding="utf-8") as f:
            f.write(text + "\n")

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
        # By default no client log dir in the bed. When one was created, wire
        # the REAL tailers to it -- from the start, since everything in it was
        # written after this supervisor began watching.
        if self.client_dir:
            s.logs_root = os.path.join(self.root, "Logs")
            s.cur_dir = self.client_dir
            _, s.tailers = crashwatch.build_tailers(self.client_dir,
                                                    from_start=True)
        else:
            s.tailers = {}
        # Never shell out to tasklist from a test: liveness is injected.
        s.alive_probe = lambda: kw.get("alive", True)
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


# -- 6b-ii. MENU needs a host-side PROOF that the menu was shown ----------
#
# MEASURED 2026-09-02 03:20: `run.py --keep --until-phase MENU` printed REACHED
# ("the boot is over and the client is parked at the menu") for a client that
# was sitting on the CHARACTER/MODE SELECT screen. The host log for that run
# ends with `skip mode screen: SHOWING 1 ... closed` and then nothing -- no
# `MenuScreen::Show fired (uihooks site 2, epoch N)`, no `mod loading: release
# gated -- READY at`, no `hide seasons: menu epoch`. The settle window was not
# wrong about the boot having stopped; the PHASE was wrong about where. All
# `raid phase = MENU` has ever meant is "no GameWorld is cached", which the
# loading screen and the slot screen satisfy too.
#
# Three cases, and the third is what stops this being a check that can only say
# no: an old host build cannot emit the proof line, so on that build the
# ABSENCE of proof must not be reported as a failure.

# The host's first line of a boot, and the uihooks boot-summary line -- the
# latter's shape from uihooks.nim's uihStatusLines.
BANNER = "aowlspt-host-il2cpp 0.1.0"

# The uihooks boot-summary line, shape from uihooks.nim's uihStatusLines.
SITE2_BOUND = ("[0:00:06.100] ok     site 2 EFT.UI.MenuScreen::Show "
               "@0x15387a0: BOUND (slot 3), fired 0x, 0 with a live receiver, "
               "0 rejected, 0 faulted dispatch(es)")

# The 03:20 boot, in order and with nothing after it.
BOOT_0320 = [
    "[0:00:25.703] ok     skip mode screen: "
    "CharacterSelectionScreen.ShowSlot first fired; the selection screen is "
    "up and is being answered",
    "[0:00:26.075] ok     skip mode screen: SHOWING 1 of the character/mode "
    "screen closed on this frame -- 1 ShowSlot call(s), the first showing.",
]


def _settled_menu(b, extra_lines):
    """Feed a boot, then let MENU settle. Returns the verdict tuple or None."""
    s = b.sup(until_phase="MENU", phase_max=0.0, menu_settle=20.0)
    s.menu_settle = 20.0
    b.say(phase_line("MENU"))                  # the ~9s first sighting
    s.poll_host()
    for line in extra_lines:
        b.say(line)
    s.poll_host()
    s.last_progress = time.time() - 25.0       # quiet for longer than settle
    b.say(phase_line("MENU"))
    return s.poll_host()


def t_menu_proof_required():
    # (a) THE MEASURED 03:20 SHAPE. Site 2 is bound, so a menu show WOULD have
    # been logged; it was not, and the host last named the slot screen.
    b = Bed()
    try:
        hit = _settled_menu(b, [SITE2_BOUND] + BOOT_0320)
        check("menuproof/0320-is-parked-before-menu",
              hit is not None and hit[0] == "PARKED-BEFORE-MENU",
              repr(hit)[:160])
        # The LAST screen the host named, which on this boot is the `SHOWING
        # ... closed` line, not the earlier ShowSlot one.
        check("menuproof/0320-names-the-character-screen",
              hit is not None and "character/mode SELECT screen" in hit[1],
              "the verdict must say WHICH screen the host last named: %s"
              % (hit[1][:200] if hit else None))
    finally:
        b.close()

    # ShowSlot ALONE (no `SHOWING ... closed` after it) names the slot screen.
    b = Bed()
    try:
        hit = _settled_menu(b, [SITE2_BOUND, BOOT_0320[0]])
        check("menuproof/showslot-alone-names-the-slot-screen",
              hit is not None and hit[0] == "PARKED-BEFORE-MENU"
              and "SLOT screen" in hit[1], repr(hit)[:200])
    finally:
        b.close()

    # And with NO screen line at all the verdict must say the location is
    # unknown rather than inventing one.
    b = Bed()
    try:
        hit = _settled_menu(b, [SITE2_BOUND])
        check("menuproof/no-screen-line-says-unknown",
              hit is not None and hit[0] == "PARKED-BEFORE-MENU"
              and "unknown" in hit[1], repr(hit)[:200])
    finally:
        b.close()

    # (b) A REAL MENU BOOT. Same shape plus the one line that proves the show
    # event fired. This is the falsifying half: without it the check above
    # would pass for every input and prove nothing.
    b = Bed()
    try:
        hit = _settled_menu(b, [SITE2_BOUND] + BOOT_0320 + [
            "[0:00:31.500] ok     mod loading: release gated -- READY at "
            "0:00:22.100, MenuScreen::Show at 0:00:31.480, releasing now"])
        check("menuproof/real-menu-boot-reaches",
              hit is not None and hit[0] == "REACHED", repr(hit)[:160])
        check("menuproof/reached-says-it-was-proved",
              hit is not None and "MenuScreen::Show" in hit[1],
              hit[1][:160] if hit else None)
    finally:
        b.close()

    # Every literal in the table must be able to carry the proof on its own --
    # a table entry that never matches is a silent gap, and this suite exists
    # to stop exactly that.
    for sig in runmod.MENU_PROOF_LINES:
        b = Bed()
        try:
            hit = _settled_menu(b, [SITE2_BOUND] + BOOT_0320 +
                                ["[0:00:31.500] ok     " + sig + "3 -- rest"])
            check("menuproof/literal proves: %s" % sig[:34].strip(),
                  hit is not None and hit[0] == "REACHED", repr(hit)[:120])
        finally:
            b.close()

    # (c) AN OLD HOST BUILD: no `site 2 ... BOUND` line anywhere, so no feature
    # could ever have printed the proof. "I could not look" is not a FAIL any
    # more than it is a PASS -- keep the old verdict and say it is unproven.
    b = Bed()
    try:
        hit = _settled_menu(b, [
            "[0:00:12.000] ok     mods tab: GetComponent bound",
        ])
        check("menuproof/old-build-still-reaches",
              hit is not None and hit[0] == "REACHED", repr(hit)[:160])
        check("menuproof/old-build-says-unproven",
              hit is not None and "UNPROVEN" in hit[1],
              "a REACHED with no proof available must SAY so: %s"
              % (hit[1][:160] if hit else None))
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
        rc, out = _run_py(root, ["--teardown"])
        check("teardown/line-in-verdict-block", "TEARDOWN:" in out,
              "a silent teardown reads as a crash afterwards; got %r"
              % out[-300:])
        check("teardown/line-names-the-escape-hatch", "--teardown" in out)
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
            _run_py(root, ["--teardown"])
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
           die_at=None, phase="MENU", idle_stall=None, client_events=(),
           poll_client=False):
    """Drive `sup` over a synthetic boot in virtual time. Returns the first
    verdict and the virtual second it landed on, or (None, horizon).

    `idle_stall` and `poll_client` bring this driver up to the ORDER main()
    actually uses (host -> clocks -> client -> idle). They are opt-in only so
    the pre-existing cases keep driving exactly what they drove before.
    """
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
        events.append((t, phase_line(phase)))
        t += 5.0
    cevents = sorted(client_events)
    if die_at is not None:
        events = [e for e in events if e[0] < die_at]
    events.sort(key=lambda e: e[0])

    t0 = clock.t
    i = 0
    j = 0
    vt = 0.0
    while vt <= horizon:
        clock.t = t0 + vt
        while i < len(events) and events[i][0] <= vt:
            bed.say(events[i][1])
            i += 1
        while j < len(cevents) and cevents[j][0] <= vt:
            bed.client_say(cevents[j][1])
            j += 1
        hit = sup.poll_host() or sup.check_clocks(clock.time())
        if not hit and poll_client:
            hit = sup.poll_client()
        if not hit and idle_stall is not None:
            hit = sup.idle_verdict(clock.time(), idle_stall)
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


# -- 8. --attach must read the arming state ALREADY on disk --------------
def t_attach_reads_existing_arming():
    """MEASURED 2026-09-02: `--attach --until-phase DEPLOYED` exited 6 with
    `dialog catch UNKNOWN`, because the host printed `errdlg ARMED` once at
    [0:00:01] and we attached two minutes later, tailing from end-of-file.

    The falsifying half is the FIRST check: a supervisor that starts at the end
    of the file must still read UNKNOWN, or the prescan below proves nothing.
    """
    for line, want, label in (
            ("[0:00:01.500] ok     errdlg ARMED: read-only postfix detours on "
             "all 3 PreloaderUI error-screen entry points.", True, "armed"),
            ("[0:00:01.500] warn   errdlg did not arm: "
             "catchErrorDialogs is explicitly false", False, "not-armed"),
            ("[0:00:01.500] ok     something else entirely", None, "silent")):
        b = Bed()
        try:
            b.say(line)
            for _ in range(200):
                b.say("[0:00:02.000] ok     natesp: raid phase = MENU -- S1")
            s = b.sup()
            s.host_pos = os.path.getsize(b.host)   # --attach: start at the END
            check("attach/unknown-without-prescan (%s)" % label,
                  s.poll_host() is None and s.errdlg_armed is None,
                  "tailing from EOF cannot see a one-shot line from earlier in "
                  "the same boot; got %r" % (s.errdlg_armed,))
            got = s.prescan_host()
            check("attach/prescan-%s" % label,
                  got is want and s.errdlg_armed is want,
                  "prescan returned %r, errdlg_armed %r, wanted %r"
                  % (got, s.errdlg_armed, want))
        finally:
            b.close()


# -- 8b. --attach must read the SITE-2 CAPABILITY already on disk ---------
def t_attach_reads_site2_capability():
    """MEASURED 2026-09-02: `run.py --attach --until-phase MENU` on a client
    that had booted minutes earlier printed `REACHED ... but UNPROVEN: this
    host build never printed a uihooks 'site 2 ... BOUND' line`, while that
    boot's log carries the BOUND line at [0:00:01.032]. Same shape as the
    errdlg bug: a one-shot capability line, an attach point after it.

    Four cases. (a) is the bug, (b) is its falsifying control -- without the
    prescan the SAME log must still read UNPROVEN, or (a) proves nothing --
    (c) is a genuinely old build, which must keep saying UNPROVEN, and (d) is
    the banner restart: a BOUND line belonging to an EARLIER boot must not
    certify this one.
    """
    def attached(b, boot_lines, prescan=True, **kw):
        """Write a boot, attach at EOF like --attach does, then settle MENU."""
        for line in boot_lines:
            b.say(line)
        s = b.sup(until_phase="MENU", phase_max=0.0, menu_settle=20.0)
        s.host_pos = os.path.getsize(b.host)      # --attach: start at the END
        if prescan:
            s.prescan_host()
        b.say(phase_line("MENU"))
        s.poll_host()
        for line in kw.get("after", ()):
            b.say(line)
        s.poll_host()
        s.last_progress = time.time() - 25.0
        b.say(phase_line("MENU"))
        return s, s.poll_host()

    PROOF = ("[0:04:31.500] ok     mod loading: release gated -- READY at "
             "0:00:22.100, MenuScreen::Show at 0:04:31.480, releasing now")

    # (a) THE BUG: BOUND at boot, before the attach point; the proof arrives
    # after it. REACHED, and NOT hedged.
    b = Bed()
    try:
        s, hit = attached(b, [BANNER, SITE2_BOUND], after=[PROOF])
        check("attach/site2-prescanned", s.site2_seen,
              "the BOUND line was at boot, before the attach point; prescan "
              "must read it")
        check("attach/site2-reached-and-proved",
              hit is not None and hit[0] == "REACHED"
              and "UNPROVEN" not in hit[1], repr(hit)[:200])
    finally:
        b.close()

    # (b) FALSIFYING CONTROL: the identical log with the prescan skipped must
    # still produce the wrong-but-honest UNPROVEN wording. If this passed too,
    # (a) would not be evidence that the prescan did anything.
    b = Bed()
    try:
        s, hit = attached(b, [BANNER, SITE2_BOUND], prescan=False,
                          after=[PROOF])
        check("attach/site2-unseen-without-prescan", not s.site2_seen,
              "tailing from EOF cannot see a one-shot line from earlier in "
              "the same boot")
    finally:
        b.close()

    # The same control at the VERDICT level: no proof line either, so the
    # settle window has to choose its wording with no capability known.
    b = Bed()
    try:
        s, hit = attached(b, [BANNER, SITE2_BOUND], prescan=False)
        check("attach/site2-unproven-without-prescan",
              hit is not None and hit[0] == "REACHED" and "UNPROVEN" in hit[1],
              "without the prescan this log must still read UNPROVEN, or the "
              "case above proves nothing: %r" % (hit,))
    finally:
        b.close()

    # (c) A GENUINELY OLD BUILD: no BOUND line anywhere in the file. The
    # prescan must not invent the capability, and the wording stays UNPROVEN.
    b = Bed()
    try:
        s, hit = attached(b, [BANNER,
                              "[0:00:06.100] ok     mods tab: GetComponent "
                              "bound"])
        check("attach/old-build-site2-still-unseen", not s.site2_seen)
        check("attach/old-build-still-unproven",
              hit is not None and hit[0] == "REACHED" and "UNPROVEN" in hit[1],
              repr(hit)[:200])
    finally:
        b.close()

    # (d) BANNER RESTART: an EARLIER boot bound site 2; this boot's banner
    # follows it and this boot never did. Capability belongs to the build that
    # is running now, so the earlier line must be discarded.
    b = Bed()
    try:
        s, hit = attached(b, [BANNER, SITE2_BOUND, BANNER,
                              "[0:00:06.100] ok     mods tab: GetComponent "
                              "bound"])
        check("attach/site2-restarts-at-the-last-banner", not s.site2_seen,
              "a `site 2 ... BOUND` line above the last host banner describes "
              "a build that is no longer running")
        check("attach/site2-restart-keeps-unproven-wording",
              hit is not None and hit[0] == "REACHED" and "UNPROVEN" in hit[1],
              repr(hit)[:200])
    finally:
        b.close()

    # And the errdlg prescan must survive the same restart rule: ARMED in THIS
    # boot is still read, with an earlier boot ahead of it in the file.
    b = Bed()
    try:
        b.say(BANNER)
        b.say("[0:00:01.500] warn   errdlg did not arm: catchErrorDialogs is "
              "explicitly false")
        b.say(BANNER)
        b.say("[0:00:01.500] ok     errdlg ARMED: read-only postfix detours "
              "on all 3 PreloaderUI error-screen entry points.")
        s = b.sup()
        s.host_pos = os.path.getsize(b.host)
        check("attach/errdlg-takes-the-last-boot",
              s.prescan_host() is True and s.errdlg_armed is True,
              "the arming state of the boot BELOW the last banner is the one "
              "that describes the running host; got %r" % (s.errdlg_armed,))
    finally:
        b.close()


# -- 9. a LOADING raid is legitimately quiet ------------------------------
def t_loading_quiet_is_not_idle():
    """The measured exit-6 run, in both of its halves.

    (a) phase LOADING with `--until-phase DEPLOYED`: quiet is expected, so no
        IDLE -- but `--phase-max` must still be able to bound it, or the
        exemption is a check that cannot fail.
    (b) the SAME quiet with `--until-phase MENU`: old behaviour, IDLE at 45s.
        Without this control (a) would be indistinguishable from an IDLE rule
        that was simply switched off.
    """
    def body(clock):
        # (a) en route to DEPLOYED -- keeps waiting.
        b = Bed()
        try:
            s = b.sup(until_phase="DEPLOYED", phase_max=480.0, stall=45.0)
            s.phase_since = clock.t
            s.last_progress = clock.t
            hit, vt = replay(b, s, clock, 120.0, [], [], phase="LOADING",
                             phase_from=1.0, idle_stall=45.0)
            check("loading/quiet-en-route-is-not-idle", hit is None,
                  "a raid loads quietly for 1-3 minutes; got %r at t=%ss"
                  % (hit[0] if hit else None, vt))
        finally:
            b.close()

        # (a2) ...and it is STILL BOUNDED. Same input, --phase-max 60.
        b = Bed()
        try:
            s = b.sup(until_phase="DEPLOYED", phase_max=60.0, stall=45.0)
            s.phase_since = clock.t
            s.last_progress = clock.t
            hit, vt = replay(b, s, clock, 120.0, [], [], phase="LOADING",
                             phase_from=1.0, idle_stall=45.0)
            check("loading/exemption-is-still-bounded",
                  hit is not None and hit[0] == "STALLED",
                  "--phase-max must still catch a load that never finishes; "
                  "got %r" % (hit[0] if hit else None,))
        finally:
            b.close()

        # (b) NEGATIVE CONTROL: the same quiet, MENU requested -> old verdict.
        b = Bed()
        try:
            s = b.sup(until_phase="MENU", phase_max=480.0, stall=45.0)
            s.phase_since = clock.t
            s.last_progress = clock.t
            hit, vt = replay(b, s, clock, 120.0, [], [], phase="LOADING",
                             phase_from=1.0, idle_stall=45.0)
            check("loading/control-menu-still-goes-idle",
                  hit is not None and hit[0] == "IDLE",
                  "with MENU requested, a quiet LOADING client is IDLE exactly "
                  "as before; got %r at t=%ss"
                  % (hit[0] if hit else None, vt))
        finally:
            b.close()
    _with_clock(body)


# -- 10. the phase was MENU, not LOADING: the client log is what covers it -
def t_client_log_carries_a_load():
    """At 60.8s of the failing run the phase was still MENU -- natesp's S1 is
    true on the loading screen too. So the phase exemption above could NOT have
    spared that run, and saying otherwise would be a fix that cannot fire.

    Three cases, and the first is the one that fails without the fix.
    """
    def body(clock):
        loading = [(t, "2026-09-02 08:1%d:00.100|1.1.0|Info|application|"
                       "Loading bundle assets/scenes/factory_%d" % (t // 60, t))
                   for t in range(5, 120, 10)]
        cases = (
            ("DEPLOYED", loading, None,
             "client/load-lines-carry-a-menu-phased-load",
             "the measured case: phase MENU, raid loading, client log moving"),
            ("DEPLOYED", [], "IDLE",
             "client/no-client-progress-still-goes-idle",
             "with NOTHING moving anywhere, quiet must still be IDLE"),
            (None, loading, "IDLE",
             "client/load-lines-do-not-count-outside-a-raid-entry",
             "LOAD_PROGRESS_RX matches 'Loading' and 'bundle', which the "
             "client logs at the menu too -- outside a raid entry it must not "
             "become a new heartbeat"),
        )
        for dest, cev, want, name, why in cases:
            b = Bed()
            try:
                b.client_log("output_000.log")
                s = b.sup(until_phase=dest, phase_max=480.0, stall=45.0)
                s.phase_since = clock.t
                s.last_progress = clock.t
                hit, vt = replay(b, s, clock, 120.0, [], [], phase="MENU",
                                 phase_from=1.0, idle_stall=45.0,
                                 client_events=cev, poll_client=True)
                got = hit[0] if hit else None
                check(name, got == want, "%s; got %r at t=%ss" % (why, got, vt))
            finally:
                b.close()
    _with_clock(body)


# -- 11. a LOGGED exception is not a CRASH while the client is alive ------
NRE_RECORD = [
    "2026-09-02 08:12:00.123|1.1.0.1.46777|Error|application|"
    "NullReferenceException: Object reference not set to an instance of an "
    "object",
    "  at MalfunctionLayer.ShallUseNow () [0x00000] in <filename unknown>:0",
    "  at EFT.BotsController.UpdateByUnity () [0x00000] in "
    "<filename unknown>:0",
    # A following header is what CLOSES the record in crashwatch's Tailer.
    "2026-09-02 08:12:00.456|1.1.0.1.46777|Info|application|GameUpdate",
]


def t_logged_exception_is_not_a_crash():
    """MEASURED 2026-09-02: `--attach --until-phase MENU` exited 5 (CRASH,
    `unhandled-exception -- NullReferenceException`) after 0.5s while the client
    was ALIVE and standing in a raid. The record was Tarkov's own bot AI,
    logged and CAUGHT in every raid.

    Both directions, because only the pair is a check:
      alive + the record  -> no verdict, and a NOTE that says what was seen;
      gone  + the record  -> CRASH, unchanged.
    The note itself is the guard against a vacuous pass: if the classifier had
    not matched at all, `client_exceptions` would be 0 and the first case would
    fail rather than silently proving nothing.
    """
    for alive, want in ((True, None), (False, "CRASH")):
        b = Bed()
        try:
            b.client_log("output_000.log", "errors_000.log")
            s = b.sup(alive=alive)
            for line in NRE_RECORD:
                b.client_say(line, "errors_000.log")
            hit = s.poll_client()
            got = hit[0] if hit else None
            label = "alive" if alive else "gone"
            check("crash/%s-%s" % (label, want or "no-verdict"), got == want,
                  "client %s + a caught NullReferenceException must be %s; "
                  "got %r" % (label, want or "a NOTE, not a verdict", got))
            check("crash/%s-counted" % label, s.client_exceptions >= 1,
                  "the record must actually have been classified, or this "
                  "case passes vacuously; count=%d" % s.client_exceptions)
            note = s.exception_note()
            check("crash/%s-note-names-it" % label,
                  bool(note) and "NullReferenceException" in note,
                  "note=%r" % (note,))
        finally:
            b.close()


# -- 12. --teardown is OPT-IN now, and --keep is a no-op -----------------
#
# MEASURED last night, three times at ~20 minutes each: `run.py` without
# `--keep` force-stopped the client at its verdict, and a TaskStop of the
# launching shell did the same. Both read afterwards as a clean crash. The
# default is therefore inverted, and BOTH directions are asserted here --
# without the second, "the default keeps the client" would be indistinguishable
# from a teardown that simply stopped announcing itself.

def t_teardown_is_opt_in():
    root, inst = _run_bed()
    note = os.path.join(inst, runmod.TEARDOWN_LOG)
    try:
        rc, out = _run_py(root, [])
        check("teardown/default-does-not-tear-down", "TEARDOWN:" not in out,
              "the default must now LEAVE the client running; got %r"
              % out[-300:])
        check("teardown/default-writes-no-note", not os.path.isfile(note))
        rc2, out2 = _run_py(root, ["--teardown"])
        check("teardown/flag-is-what-tears-down", "TEARDOWN:" in out2,
              "and --teardown must still do it, or the check above proves "
              "only that the feature was deleted; got %r" % out2[-300:])
        check("teardown/flag-announces-itself-up-front",
              "the client WILL be stopped" in out2, out2[:400])
    finally:
        shutil.rmtree(root, ignore_errors=True)


def t_keep_is_accepted_and_says_so():
    root, inst = _run_bed()
    try:
        rc, out = _run_py(root, ["--keep"])
        check("teardown/keep-still-accepted",
              "unrecognized arguments" not in out and "usage:" not in out,
              "old callers and recipes pass --keep; it must not become an "
              "argparse error. got %r" % out[:300])
        check("teardown/keep-says-it-is-a-no-op",
              "--keep is now the default and does nothing" in out, out[:400])
    finally:
        shutil.rmtree(root, ignore_errors=True)


# -- 13. THE TEARDOWN LEDGER, and KILLED-BY-TOOL -------------------------
#
# The ledger is the machine-readable half of the announcement: a later reader --
# possibly another session with no transcript at all -- can ask "did a tool stop
# the client at 13:18:04?" and get an answer. `classify_death` is the one
# decision that turns a DIED into a KILLED-BY-TOOL, and it is tested here
# against a synthetic ledger, with all four negative controls.

def t_teardown_ledger_written():
    root, inst = _run_bed()
    try:
        _run_py(root, ["--teardown"])
        rows = runledger.read(runledger.teardown_path(root))
        check("ledger/teardown-written", bool(rows),
              "expected entries in %s" % runledger.teardown_path(root))
        if rows:
            e = rows[-1]
            for k in ("when", "pid", "tool", "reason", "argv"):
                check("ledger/field %s" % k, k in e, repr(e)[:200])
            check("ledger/names-the-tool", e.get("tool") == "run.py",
                  repr(e)[:200])
            check("ledger/argv-is-a-list", isinstance(e.get("argv"), list)
                  and any("run.py" in str(a) for a in e["argv"]),
                  repr(e.get("argv"))[:200])
        # The PRE-LAUNCH stop is recorded too -- it is a real stop of whatever
        # client was up, and a reader must see it.
        check("ledger/pre-launch-stop-recorded",
              any("pre-launch stop" in (r.get("reason") or "") for r in rows),
              "%d row(s)" % len(rows))
    finally:
        shutil.rmtree(root, ignore_errors=True)


def t_killed_by_tool():
    root = tempfile.mkdtemp(prefix="aowl-killed-")
    led = os.path.join(root, "teardown.jsonl")
    try:
        now = 1_000_000.0
        # Written directly at a KNOWN path and time: `record` would shell out
        # to tasklist and stamp the real clock, and this case is about a
        # SPECIFIC two-second gap.
        runledger._append(led, {
            "when": now - 2.0, "when_local": "2026-09-02 13:18:04",
            "pid": 4242, "pids_known": True, "tool": "deploy.py",
            "reason": "deploying the host DLL",
            "argv": ["deploy.py", "deploy", "host"]})

        v, why, ev, note = runmod.classify_death(
            "DIED", "the client process was up and is gone", [], now,
            crashwatch.DEATH_QUIET, path=led)
        check("killed/fires", v.startswith("KILLED-BY-TOOL"), repr(v)[:160])
        check("killed/names-the-tool-and-reason",
              "deploy.py" in v and "deploying the host DLL" in v, repr(v)[:200])
        check("killed/exit-code-is-distinct",
              runmod.exit_code(v) == runmod.EXIT["KILLED-BY-TOOL"]
              and runmod.exit_code(v) != runmod.EXIT["DIED"],
              "exit_code(%r) = %r" % (v, runmod.exit_code(v)))
        check("killed/evidence-carries-the-entry",
              any("deploy.py" in e for e in ev), repr(ev)[:200])

        # NEGATIVE 1: too far away in time.
        v2, _w, _e, _n = runmod.classify_death(
            "DIED", "gone", [], now + 60.0, crashwatch.DEATH_QUIET, path=led)
        check("killed/outside-the-window-stays-DIED", v2 == "DIED", repr(v2))

        # NEGATIVE 2: the entry predates THIS client's launch, so it cannot
        # have killed it. Without this floor, run.py's own pre-launch stop
        # would explain every early death -- a verdict that cannot be wrong.
        v3, _w, _e, _n = runmod.classify_death(
            "DIED", "gone", [], now, crashwatch.DEATH_QUIET, path=led,
            not_before=now - 1.0)
        check("killed/entry-before-launch-stays-DIED", v3 == "DIED", repr(v3))

        # NEGATIVE 3: the OS recorded a real crash. A teardown that lands beside
        # a fail-fast must NOT bury it.
        v4, _w, _e, n4 = runmod.classify_death(
            "DIED", "gone", [], now, crashwatch.DEATH_FAILFAST, path=led)
        check("killed/real-crash-outranks-a-teardown", v4 == "DIED", repr(v4))
        check("killed/real-crash-says-why-it-was-not-attributed",
              bool(n4) and "NOT reported as KILLED-BY-TOOL" in n4,
              repr(n4)[:200])

        # NEGATIVE 4: a healthy verdict is never rewritten.
        v5, _w, _e, _n = runmod.classify_death(
            "REACHED", "fine", [], now, crashwatch.DEATH_QUIET, path=led)
        check("killed/reached-is-untouched", v5 == "REACHED", repr(v5))
    finally:
        shutil.rmtree(root, ignore_errors=True)


# -- 14. DIED FORENSICS -------------------------------------------------------
#
# MEASURED last night: every "clean" death had a Unity crash report AND a
# minidump naming the faulting argument in registers, and ~2.5 hours went into
# theories before either was opened. And MEASURED 2026-09-02 13:18: a death with
# NO Crash_* folder at all was a fail-fast (0xc0000409, abort() from a mimalloc
# assertion inside admin.dll), which Unity's handler never sees -- so "no crash
# report newer than launch" was itself a WRONG teardown verdict.

# dmpread's real output shape (tools/dmpread.py main()).
DMPREAD_TEXT = """thread 12  ACCESS_VIOLATION (0xc0000005)  at 0x7ffb2c0be110
  a READ of 0x0 faulted
  Rax=0000000000000001 Rbx=00000228bf001200 Rcx=0000000000000001 Rdx=0000000000000000
  Rsp=000000e5d51fe8a0 Rbp=0000000000000000 Rsi=0000000000000000 Rdi=0000000000000000
  (no register holds a known allocator fill pattern)"""

# il2cpp_resolve disasm's real output shape (tools/il2cpp_resolve.py cmd_disasm).
DISASM_TEXT = """disasm   0x150e110  (VA 0x18150e110)   section il2cpp
owner    Profile::get_Health @0x150e0f0 [unique]
args     rcx=EFT.Profile this   rdx=System.Int32 mode
decoding from the owner start 0x150e0f0 (exact instruction boundaries)
   RVA        BYTES                  INSTRUCTION
   0x150e0f0  4883ec28               sub rsp, 0x28
>> 0x150e110  488b09                 mov rcx, qword ptr [rcx]    Profile._healthController@0x0
   0x150e113  4885c9                 test rcx, rcx
   0x150e116  7405                   je 0x150e11d
   0x150e118  e893ffffff             call 0x150e0b0"""

# The 2026-09-02 13:18 Application Error record, as PowerShell hands it back.
WER_TEXT = ("%s\n2026-09-02 13:18:05\nApplication Error\n"
            "Faulting application name: EscapeFromTarkov.exe, version: "
            "0.16.8.1.46777, time stamp: 0x68a1b2c3\n"
            "Faulting module name: ucrtbase.dll, version: 10.0.19041.5794, "
            "time stamp: 0x9a1f2b3c\n"
            "Exception code: 0xc0000409\n"
            "Fault offset: 0x000000000007286e\n"
            "Faulting process id: 0x424c\n"
            "Faulting module path: C:\\WINDOWS\\System32\\ucrtbase.dll\n"
            "%s\n" % (crashwatch.WER_SEP, crashwatch.WER_DONE))

# cdb's real answer on that dump (measured, 2026-09-02).
CDB_TEXT = """Loading Dump File [EscapeFromTarkov.exe.16972.dmp]
Child-SP          RetAddr               Call Site
000000e5`d51fe8a0 00007ffb`5ede21ef     ucrtbase!abort+0x4e
000000e5`d51fe8d0 00007ffb`5edfa3dd     admin!mi_assert_fail+0x3d
000000e5`d51fe920 00007ffb`5ee06a1b     admin!mi_malloc+0xcb
000000e5`d51ff410 00007ffb`5ee0a75a     admin!onUpdate_0_adm65d7rb+0x38

quit:
"""

MODLINE = (r"D:\Games\Tarkov\GameAssembly.dll:GameAssembly.dll "
           "(00007FFB2ABB0000), size: 126812160 (result: 0), "
           "SymType: '-deferred-', PDB: ''")

PLAYER_LOG = "\n".join([
    "Unity Player [version: Unity 2021.3.x]",
    "",
    crashwatch.STACK_BEGIN,
    "",
    "0x00007FFB2C0BE110 (GameAssembly) mono_class_has_parent",
    "0x00007FFB5EE0A75A (admin) onUpdate_0_adm65d7rb",
    "",
    crashwatch.STACK_END,
    "",
    MODLINE,
    "",
])


def _crash_fixture(when=None, with_dmp=False):
    """A real Crash_<UTC stamp> folder, parsed by the real CrashReport."""
    root = tempfile.mkdtemp(prefix="aowl-crashroot-")
    when = time.time() if when is None else when
    name = time.strftime("Crash_%Y-%m-%d_%H%M%S",
                         time.gmtime(when)) + "000"
    d = os.path.join(root, name)
    os.makedirs(d)
    with open(os.path.join(d, "Player.log"), "w", encoding="utf-8",
              newline="\n") as f:
        f.write(PLAYER_LOG)
    if with_dmp:
        open(os.path.join(d, "crash.dmp"), "wb").close()
    return root, d


def _fake_tools(dmpread=DMPREAD_TEXT, disasm=DISASM_TEXT, rc=0):
    def runner(cmd):
        joined = " ".join(str(c) for c in cmd)
        if "dmpread.py" in joined:
            return rc, dmpread
        if "il2cpp_resolve.py" in joined:
            return rc, disasm
        return 127, "unexpected command: " + joined
    return runner


def t_died_forensics_block():
    """The whole block, driven end to end against a fixture crash report.

    The tools themselves are injected -- a real minidump and a real
    GameAssembly.dll cannot be fixtures -- but everything BETWEEN them is the
    real code: crashwatch's report parser, the fault-address extraction, the
    module rebase off the report's own base line, and the disasm excerpt.
    """
    root, folder = _crash_fixture()
    dumps = tempfile.mkdtemp(prefix="aowl-dumps-")
    try:
        open(os.path.join(dumps, "EscapeFromTarkov.exe.16972.dmp"),
             "wb").close()
        started = time.time() - 30.0
        lines, kind = runmod.died_forensics(
            started, crash_root=root, runner=_fake_tools(), symbolize=False,
            ps_runner=lambda script: (0, WER_TEXT),
            cdb_runner=lambda cmd: (0, CDB_TEXT),
            dumps_dir=dumps, cdb=sys.executable)
        txt = "\n".join(lines)
        check("forensics/has-a-header",
              lines and lines[0] == runmod.FORENSICS_HEADER, repr(lines[:1]))
        check("forensics/names-the-crash-folder",
              os.path.basename(folder) in txt, txt[:300])
        check("forensics/prints-crash-site-frames",
              "mono_class_has_parent" in txt, txt[:600])
        check("forensics/prints-the-faulting-registers",
              "Rax=0000000000000001" in txt and "ACCESS_VIOLATION" in txt,
              txt[:600])
        check("forensics/rebases-to-an-rva",
              "RVA 0x150e110" in txt,
              "0x7FFB2C0BE110 - base 0x7FFB2ABB0000; got: %s" % txt[-900:])
        check("forensics/prints-the-disasm-owner",
              "owner    Profile::get_Health" in txt, txt[-900:])
        check("forensics/prints-the-disasm-args", "args     rcx=" in txt,
              txt[-900:])
        check("forensics/prints-the-faulting-instruction-and-three-after",
              ">> 0x150e110" in txt and "0x150e118" in txt
              and "0x150e11d" in txt, txt[-700:])
        check("forensics/asks-the-windows-event-log",
              "Windows Application event log since launch:" in txt
              and "ucrtbase.dll" in txt,
              "the event log must be asked and its answer printed -- a "
              "fail-fast writes no Crash_* folder at all: %s" % txt[-900:])
        check("forensics/prints-the-event-code",
              "0xc0000409" in txt and "FAST_FAIL" in txt, txt[-1200:])
        check("forensics/prints-the-cdb-call-sites",
              "admin!onUpdate_0_adm65d7rb" in txt, txt[-1200:])
        check("forensics/states-a-death-kind",
              "DEATH KIND" in txt and kind == crashwatch.DEATH_NATIVE,
              "a Crash_* folder exists, so this is a native crash: %r" % kind)
    finally:
        shutil.rmtree(root, ignore_errors=True)
        shutil.rmtree(dumps, ignore_errors=True)


def t_forensics_refusals_are_verbatim():
    """A tool that REFUSES must be quoted, never skipped.

    Two real refusals, neither mocked: dmpread on a crash.dmp that does not
    exist, and the disasm step which then has no faulting address to work from.
    """
    root, folder = _crash_fixture()
    try:
        started = time.time() - 30.0
        lines, _kind = runmod.died_forensics(
            started, crash_root=root, symbolize=False, wer=False)
        txt = "\n".join(lines)
        check("forensics/dmpread-refusal-is-printed",
              "dmpread" in txt.lower() or "No such file" in txt
              or "cannot find" in txt.lower(),
              "the refusal must be quoted; got: %s" % txt[-500:])
        check("forensics/refusal-is-not-silent",
              "NOT LOOKED AT" in txt or "exited" in txt,
              "a step that could not run must SAY so: %s" % txt[-500:])
        check("forensics/disabled-windows-pass-is-inconclusive",
              _kind == crashwatch.DEATH_UNKNOWN
              and "NOT LOOKED AT" in txt, repr(_kind))
    finally:
        shutil.rmtree(root, ignore_errors=True)


def t_died_is_never_bare():
    """THE RULE: a DIED line never appears without forensics or a reason.

    Both directions. The falsifying half is the second: if the block printed
    unconditionally, the first check would pass while proving nothing.
    """
    import io
    import contextlib
    for v, forensics, want in (
            ("DIED", None, runmod.FORENSICS_MISSING),
            ("DIED", ["BLOCK", "   a line"], "BLOCK"),
            ("KILLED-BY-TOOL run.py x", None, None),
            ("REACHED", None, None)):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            runmod.verdict_block(v, "why", [], 1.0, True, [], False,
                                 forensics=forensics)
        out = buf.getvalue()
        if want:
            check("bare/%s prints %s" % (v.split()[0], want[:12]),
                  want in out, out[-400:])
        else:
            check("bare/%s prints no forensics stub" % v.split()[0],
                  runmod.FORENSICS_MISSING not in out, out[-400:])
    check("bare/only-DIED-demands-forensics",
          runmod.needs_forensics("DIED")
          and not runmod.needs_forensics("KILLED-BY-TOOL run.py x")
          and not runmod.needs_forensics("REACHED")
          and not runmod.needs_forensics("TIMEOUT"))


# -- 15. the FAIL-FAST verdict logic -------------------------------------
#
# `death_kind` is the rule that "no Crash_* folder" is NOT a teardown. Every
# branch, and the two INCONCLUSIVE ones especially: a question that could not
# be asked must never collapse into "nothing was found".

def t_death_kind():
    ev = [{"provider": "Application Error", "code": "0xc0000409",
           "module": "ucrtbase.dll", "when": "2026-09-02 13:18:05"}]
    av = [{"provider": "Application Error", "code": "0xc0000005",
           "module": "GameAssembly.dll", "when": "2026-09-02 13:18:05"}]
    cases = (
        ("failfast", None, ev, [], crashwatch.DEATH_FAILFAST),
        ("native-via-event", None, av, [], crashwatch.DEATH_NATIVE),
        ("native-via-folder", "Crash_2026-09-02_131805000", [], [],
         crashwatch.DEATH_NATIVE),
        ("os-dump-only", None, [], ["EscapeFromTarkov.exe.16972.dmp"],
         crashwatch.DEATH_OS_DUMP),
        ("quiet", None, [], [], crashwatch.DEATH_QUIET),
        ("events-unreadable", None, None, [], crashwatch.DEATH_UNKNOWN),
        ("dumps-unreadable", None, [], None, crashwatch.DEATH_UNKNOWN),
    )
    for name, folder, events, dumps, want in cases:
        kind, sentence = crashwatch.death_kind(folder, events, dumps,
                                               "query blew up", "dir blew up")
        check("deathkind/%s" % name, kind == want,
              "wanted %r, got %r -- %s" % (want, kind, sentence[:160]))
        if want == crashwatch.DEATH_QUIET:
            check("deathkind/quiet-says-it-asked-all-three",
                  "all three" in sentence, sentence[:200])
        if want == crashwatch.DEATH_FAILFAST:
            check("deathkind/failfast-names-the-module-and-code",
                  "ucrtbase.dll" in sentence and "0xc0000409" in sentence,
                  sentence[:250])
    # THE MEASURED FAILURE, stated as a check: an unaskable question must not
    # be reported as a teardown.
    kind, _s = crashwatch.death_kind(None, None, [])
    check("deathkind/unreadable-log-is-not-a-teardown",
          kind != crashwatch.DEATH_QUIET,
          "'I could not read the event log' must never read as 'it was torn "
          "down'")


def t_wer_parsing():
    evs, why = crashwatch.parse_wer_output(WER_TEXT)
    check("wer/parses-one-event", evs is not None and len(evs) == 1,
          "%r %r" % (evs, why))
    if evs:
        e = evs[0]
        check("wer/reads-the-faulting-module", e["module"] == "ucrtbase.dll",
              repr(e)[:200])
        check("wer/reads-the-exception-code", e["code"] == "0xc0000409",
              repr(e)[:200])
        check("wer/reads-the-fault-offset",
              e["offset"] == "0x000000000007286e", repr(e)[:200])
        check("wer/reads-the-time-and-provider",
              e["when"] == "2026-09-02 13:18:05"
              and e["provider"] == "Application Error", repr(e)[:200])
    check("wer/names-the-code",
          "FAST_FAIL" in (crashwatch.code_name("0xc0000409") or ""),
          repr(crashwatch.code_name("0xc0000409")))
    # THE FALSIFYING HALF: a truncated answer is INCONCLUSIVE, not "no events".
    evs2, why2 = crashwatch.parse_wer_output(WER_TEXT.split(
        crashwatch.WER_DONE)[0])
    check("wer/truncated-output-is-inconclusive",
          evs2 is None and "INCONCLUSIVE" in (why2 or ""), repr(why2)[:200])
    evs3, _w = crashwatch.parse_wer_output(crashwatch.WER_DONE + "\n")
    check("wer/complete-but-empty-is-zero-events", evs3 == [], repr(evs3))


def t_cdb_stack():
    stack, note = crashwatch.cdb_stack("x.dmp", cdb=sys.executable,
                                       runner=lambda cmd: (0, CDB_TEXT))
    check("cdb/reads-the-call-site-column", stack is not None
          and any("admin!onUpdate_0_adm65d7rb" in l for l in stack),
          repr(stack)[:300])
    check("cdb/stops-at-the-end-of-the-stack",
          stack is not None and not any("quit:" in l for l in stack),
          repr(stack)[:300])
    # cdb ABSENT: say so and do not pretend the stack was read.
    stack2, note2 = crashwatch.cdb_stack(
        "x.dmp", cdb=os.path.join(tempfile.gettempdir(), "no-such-cdb.exe"))
    check("cdb/absent-is-stated", stack2 is None
          and "NOT installed" in (note2 or ""), repr(note2)[:200])
    # cdb ran but said nothing useful -- also not a pass.
    stack3, note3 = crashwatch.cdb_stack("x.dmp", cdb=sys.executable,
                                         runner=lambda cmd: (0, "hello"))
    check("cdb/no-call-site-column-is-stated", stack3 is None
          and "no `Call Site`" in (note3 or ""), repr(note3)[:200])


# -- 16. THE BOOT LEDGER --------------------------------------------------
#
# ~7 commits landed per boot last night, so every crash needed a bisect and two
# one-sample bisects gave wrong answers. This line says, before the client is
# even launched, whether a crash on this boot will be attributable at all --
# and it is derived from git and the deployed file, never guessed.

def _git_repo():
    """A throwaway repo whose commit TIMES are set explicitly.

    Deterministic dates matter here: `boot_facts` counts `git log --since=<the
    previous boot>`, and with wall-clock commits the base commit and the boot
    marker land in the same second and the count is off by one depending on
    which side of it git rounds. A test that is one commit out at random is
    worse than no test.
    """
    d = tempfile.mkdtemp(prefix="aowl-gitrepo-")
    def g(*a, **kw):
        env = dict(os.environ)
        when = kw.get("when")
        if when is not None:
            stamp = "%d +0000" % int(when)
            env["GIT_AUTHOR_DATE"] = stamp
            env["GIT_COMMITTER_DATE"] = stamp
        subprocess.run(["git", "-C", d] + list(a), capture_output=True,
                       text=True, timeout=60, env=env)
    g("init", "-q")
    g("config", "user.email", "you@example.com")
    g("config", "user.name", "savannt")
    g("config", "commit.gpgsign", "false")
    os.makedirs(os.path.join(d, "host"))
    return d, g


def t_boot_facts_are_measured():
    repo, g = _git_repo()
    root = tempfile.mkdtemp(prefix="aowl-bootroot-")
    try:
        os.makedirs(runledger.install_dir(root))
        dll = os.path.join(runledger.install_dir(root), runledger.HOST_DLL)
        with open(dll, "wb") as f:
            f.write(b"x" * 4321)
        # A first commit, then a recorded boot, then SIX more commits: exactly
        # the shape of last night. All times are explicit -- see _git_repo.
        t0 = time.time() - 7200.0
        with open(os.path.join(repo, "host", "a.nim"), "w", newline="\n") as f:
            f.write("one\n")
        g("add", "-A")
        g("commit", "-qm", "base", when=t0)
        led = os.path.join(root, "boots.jsonl")
        runledger.record_boot(root, facts={}, when=t0 + 1800.0, path=led)
        for i in range(6):
            with open(os.path.join(repo, "host", "a.nim"), "a",
                      newline="\n") as f:
                f.write("line %d\n" % i)
            g("add", "-A")
            g("commit", "-qm", "change %d" % i, when=t0 + 3600.0 + i * 60.0)
        # ...plus two uncommitted host files, and one under tools/ that must
        # NOT be counted (it cannot be in the DLL that just booted).
        for name in ("b.nim", "c.nim"):
            with open(os.path.join(repo, "host", name), "w",
                      newline="\n") as f:
                f.write("dirty\n")
        os.makedirs(os.path.join(repo, "tools"))
        with open(os.path.join(repo, "tools", "t.py"), "w",
                  newline="\n") as f:
            f.write("# not host code\n")

        f = runledger.boot_facts(root, repo=repo, path=led)
        check("boot/counts-commits-since-the-previous-boot", f["commits"] == 6,
              "wanted 6, got %r" % (f["commits"],))
        check("boot/counts-uncommitted-host-files",
              f["dirty"] is not None and len(f["dirty"]) == 2,
              "wanted the 2 host files and NOT tools/t.py; got %r"
              % (f["dirty"],))
        check("boot/reads-the-deployed-dll", f["dll_size"] == 4321,
              repr(f["dll_size"]))
        check("boot/reads-the-sha", bool(f["sha"]) and len(f["sha"]) >= 6,
              repr(f["sha"]))

        lines = runledger.boot_line(f)
        check("boot/line-shape", lines[0].startswith("this boot carries: "),
              lines[0][:160])
        check("boot/line-states-size-and-time",
              "4,321 bytes built " in lines[0], lines[0][:200])
        check("boot/line-states-dirty-count", "dirty: 2 files" in lines[0],
              lines[0][:200])
        check("boot/line-states-both-counts",
              "6 commit(s) and 2 uncommitted host/mod file(s)" in lines[0],
              lines[0][:250])
        check("boot/warns-when-a-bisect-would-be-needed",
              runledger.WARN_BISECT in lines,
              "6+2 > %d must warn; got %r" % (runledger.BISECT_LIMIT, lines))

        # THE FALSIFYING HALF: a SMALL boot must not warn, or the warning is
        # noise that will be ignored within a day.
        small = dict(f, commits=1, dirty=[])
        check("boot/small-boot-does-not-warn",
              runledger.WARN_BISECT not in runledger.boot_line(small),
              repr(runledger.boot_line(small)))

        # ...and an UNMEASURABLE boot must say so rather than reading clean.
        blind = dict(f, commits=None, dirty=None, sha=None,
                     git_error="git could not be run at all")
        bl = runledger.boot_line(blind)
        check("boot/unmeasured-is-not-a-clean-bill",
              any("could NOT be measured" in l for l in bl), repr(bl))
        check("boot/unmeasured-names-the-reason",
              any("git could not be run" in l for l in bl), repr(bl))

        # A FIRST boot has no previous launch and must say UNKNOWN, not 0.
        first = runledger.boot_facts(root, repo=repo,
                                     path=os.path.join(root, "none.jsonl"))
        fl = runledger.boot_line(first)
        check("boot/no-previous-boot-says-unknown",
              "NO previous boot is recorded" in fl[0], fl[0][:250])
    finally:
        shutil.rmtree(repo, ignore_errors=True)
        shutil.rmtree(root, ignore_errors=True)


def t_boot_line_is_printed_and_recorded():
    root, inst = _run_bed()
    try:
        rc, out = _run_py(root, [])
        check("boot/printed-at-launch", "this boot carries: " in out,
              out[:400])
        rows = [r for r in runledger.read(runledger.boot_path(root))
                if r.get("kind") == "launch"]
        check("boot/launch-recorded", len(rows) == 1,
              "one launch must be recorded so the NEXT boot can count against "
              "it; got %d" % len(rows))
        rc, out = _run_py(root, [])
        rows = [r for r in runledger.read(runledger.boot_path(root))
                if r.get("kind") == "launch"]
        check("boot/second-launch-appends", len(rows) == 2, repr(rows)[:200])
        check("boot/second-boot-counts-against-the-first",
              "since the previous boot" in out, out[:400])
    finally:
        shutil.rmtree(root, ignore_errors=True)


def main():
    for fn in (t_stalled_fires, t_progress_never_stalls, t_bound_disable,
               t_heartbeat_is_not_progress, t_backend_down,
               t_existing_verdicts, t_menu_must_settle, t_menu_proof_required,
               t_periodic_table_is_honest, t_measured_false_stalled,
               t_measured_control_run, t_measured_real_stall_stays_stalled,
               t_stall_at_destination_needs_total_silence,
               t_teardown_announced, t_teardown_silent_with_keep,
               t_exit_codes_distinct, t_attach_reads_existing_arming,
               t_attach_reads_site2_capability,
               t_loading_quiet_is_not_idle, t_client_log_carries_a_load,
               t_logged_exception_is_not_a_crash,
               t_teardown_is_opt_in, t_keep_is_accepted_and_says_so,
               t_teardown_ledger_written, t_killed_by_tool,
               t_died_forensics_block, t_forensics_refusals_are_verbatim,
               t_died_is_never_bare, t_death_kind, t_wer_parsing, t_cdb_stack,
               t_boot_facts_are_measured, t_boot_line_is_printed_and_recorded):
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
