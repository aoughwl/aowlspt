#!/usr/bin/env python3
r"""run.py -- ONE command that launches the client, supervises it, and prints a
verdict small enough to read.

    python tools/run.py                       launch, supervise, report
    python tools/run.py --until "host running"
    python tools/run.py --inspect "state" "find SettingsScreen"
    python tools/run.py --attach              the game is already running
    python tools/run.py --json                machine-readable, one line
    python tools/run.py --keep                leave the client up afterwards

## Why this exists

The dev loop was: launch it, then poll `tasklist`, then grep the host log, then
grep the client log, then wonder whether "no new lines" meant idle or dead, then
run the inspector, then read the out file. Six-plus round trips per iteration,
each one dumping a screenful of log into the transcript, and the expensive part
was not any single step -- it was that NONE of them could tell an error dialog
from a healthy idle client, so a broken run looked exactly like a working one
until the whole timeout expired.

This collapses that into one call with one verdict, and the verdict distinguishes
every outcome that has actually happened on this project.

## The verdicts (never two, never "probably")

    REACHED       the --until sentinel appeared. Exit 0.
    IDLE          alive, log quiet, no dialog. The NORMAL end state of a
                  no-profile launch: the boot finished and the game is waiting
                  at profile-select for a person. Exit 3.
    ERRORDIALOG   the client put a modal error window up and is waiting for a
                  click. Exit 4. THIS IS THE ONE THAT USED TO BE INVISIBLE --
                  see below.
    CRASH         the client's own logs show a thrown exception / abort, via
                  crashwatch's measured signatures. Exit 5.
    DIED          the process is gone. Exit 1.
    TIMEOUT       none of the above within --timeout. Exit 2.
    STALLED       it got somewhere real and then stopped getting anywhere: one
                  raid phase, unchanged, past --phase-max, while the host is
                  still alive and talking. Exit 8. NOT reported for the phase
                  `--until-phase` asked for -- being parked there is the goal,
                  so a stall there requires the host log to have stopped
                  entirely, heartbeat included. See Supervisor.check_clocks.
    BACKENDDOWN   the launcher gave up restarting the server. The client is
                  usually still up and still looks fine. Exit 9.

The last two are the ones that used to cost HOURS rather than minutes. The host
re-publishes the raid phase every 5s forever; that heartbeat refreshed the
progress clock, so IDLE could never fire once the host attached and a wedged
raid was watched to its full timeout. And no supervisor had ever tailed the
backend log at all, so a dead server was indistinguishable from a slow game.

`IDLE` and `ERRORDIALOG` are the pair that matters. From outside they are
byte-identical: the process is alive, the host log has gone quiet, nothing is
logged at Error level. Conflating them is what let an unattended `autoraid` run
sit on a dead client for its entire timeout -- measured at ~12 minutes in one
recorded case. The host now says which it is (`catchErrorDialogs`, default ON,
one `ERRORDIALOG` line per dialog) and this believes it.

If the host did NOT arm the dialog catcher, this says so and downgrades an IDLE
verdict to INCONCLUSIVE, because "I could not look" is not a pass (CLAUDE.md 9b).

## It STOPS the client when it is done, and it says so

Without `--keep` (and without `--attach`), the client, the backend and the
launcher are force-stopped the moment the verdict lands. That default is
right -- the host DLL is locked while the game runs -- but it was SILENT, and a
silently stopped client is indistinguishable, after the fact, from one that
crashed: the host log just ends, on a heartbeat, with no fault and no crash
folder. That cost twenty minutes once.

So the teardown announces itself twice: a `TEARDOWN:` line inside the verdict
block, and a timestamped line appended to `aowlspt-run-teardown.log` beside the
host log, written BEFORE anything is killed. `--dry-teardown` does both and
kills nothing.

## Token discipline

The default output is a verdict block of at most ~12 lines: the verdict, why,
how long, and -- only on a bad verdict -- the handful of log lines that justify
it. The full logs are on disk and are NAMED, not printed. `--verbose` streams
the host log the way harness.py does, for when that is actually wanted.

This matters because the logs here are measured token bombs (CLAUDE.md 8): a
single unwindowed read of the wrong file ends a session. Nothing in this script
ever reads a whole log -- every tail seeks to the end and reads only what is
appended after.
"""

from __future__ import annotations

import argparse
import json as jsonmod
import os
import re
import signal
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import crashwatch  # noqa: E402  -- reuse the measured signatures, do not restate
import popups     # noqa: E402  -- native dialogs, which reach NO log at all
import harness     # noqa: E402  -- reuse the launcher + process check

DEFAULT_ROOT = r"D:\Aowlspt"

# How long to allow for the client process to appear at all before calling it a
# no-start. CLAUDE.md section 1: the client takes >60s to reach profile-select,
# and "wait 90s+ before declaring a crash" is the measured rule -- a shorter
# window reports a healthy slow boot as a death.
BOOT_GRACE_S = 95

# PERIODIC lines the host prints whether or not anything is happening. They are
# proof the host is ALIVE and proof of nothing else, so they must NOT refresh
# the progress clock.
#
# This is the bug that cost the most wall-clock in this project, and it is a
# check that could never fire rather than one that could never fail.
# `raidphase.nim` re-states the current phase every 5.0s forever (measured: 40
# consecutive `raid phase = MENU` lines at a 5.015s cadence). Since every host
# line reset `last_progress`, the IDLE detector was structurally incapable of
# triggering the moment the host attached -- so a run that was wedged in a raid,
# or sitting at a screen nobody would ever click, was watched to its full
# timeout with a supervisor that looked healthy the whole time. A heartbeat is
# not progress. Treating it as progress makes a liveness check assert only that
# the clock still ticks.
# PERIODIC STATUS lines: the second family of the same bug, measured
# 2026-09-01 23:03 across three consecutive boots of the same build.
#
# `raid phase =` was not the only line the host re-prints forever. At a client
# parked on the main menu, five more families repeat on fixed cadences and say
# nothing new. Measured occurrence times (host-relative), identical in shape in
# all three runs:
#
#   live inspector: IDLE and HEALTHY      every ~15s   (25/28/0 occurrences)
#   ... ARMED but NEVER FIRED             every  30s   (14/16/9)
#   ... unchanged cycle(s)                every  60s   (12/13/8)
#   camera: acquire=                      every  60s   ( 7/ 8/5)
#   client settings bridge: published     every  60s   ( 8/ 9/6)
#
# Each of these refreshed `last_progress`, so the MENU-settle window could
# never open: the 15s inspector line alone makes a 20s quiet window impossible.
# The run then sat in MENU until some OTHER bound fired, and WHICH one fired
# depended on the flags -- `--phase-max 200` produced a false STALLED at 219s
# on a healthy client sitting at the menu, while the same boot with the default
# `--phase-max 900` produced a false TIMEOUT at 300s. A third boot, on which
# nobody happened to be driving the live inspector, had no 15s line, opened a
# 24s quiet window and correctly said REACHED. Three different verdicts for one
# client state, decided by which periodic line landed in the window.
#
# `unchanged cycle(s)` is deliberately the predicate rather than the two
# feature names that print it (natesp's VERDICT block and Maps' diag block).
# It is a literal those features emit ONLY when they are re-stating an
# unchanged result -- the FIRST diag of a run, and any diag whose verdict
# actually moved, does not carry it and is still counted as progress. A
# heartbeat entry that swallowed a real state change would be the mirror of
# this bug.
#
# NOT added, though they were proposed: `version brand ... re-applied` and the
# `hide seasons` re-hide. Checked against all three runs -- each occurs EXACTLY
# ONCE per boot, so they are one-shot progress, not periodic status. A false
# entry here silently deletes real progress, which is strictly worse than a
# missing one.
PERIODIC_HOST_LINES = (
    "live inspector: IDLE and HEALTHY",
    "ARMED but NEVER FIRED",
    "unchanged cycle(s)",
    "camera: acquire=",
    "client settings bridge: published ",
)

HEARTBEAT_HOST_LINES = (
    "natesp: raid phase = ",
    "frameMeter:",
) + PERIODIC_HOST_LINES


def is_progress(line):
    """THE single definition of progress. Every clock in here uses this one.

    The false STALLED above was not a wrong threshold; it was two rules with
    two different ideas of what counts. `--menu-settle` measured quiet against
    `last_progress` (which periodic lines refreshed), while the phase bound
    measured against `phase_since` (which they did not). They therefore
    disagreed about whether a client parked at the menu was making progress,
    and the disagreement was resolved by whichever line happened to land in the
    window. One predicate, used by all of them, makes that disagreement
    impossible to express.
    """
    return not any(h in line for h in HEARTBEAT_HOST_LINES)

# The phase the host publishes. `raidphase.nim` has emitted this all along and
# nothing consumed it -- the raid was bounded by `time.sleep(60.0)` in
# enterraid.py, which asserts a DURATION and never a STATE.
RAID_PHASE = re.compile(r"raid phase = ([A-Z]+)")

# The host's raid-phase cadence, MEASURED: 40 consecutive `raid phase = MENU`
# lines at 5.015s apart. It is the proof-of-life the silence test leans on -- a
# host that has printed nothing for several multiples of this has stopped.
HOST_HEARTBEAT_S = 5.0

# The launcher's own watchdog verdict. It prints this and gives up; until now
# nothing read the backend log at all, so the supervisor kept waiting on a game
# whose server was already declared dead.
BACKEND_DOWN_LINE = "BACKEND DOWN"

# Lines the HOST itself prints when the run is already over. Matching one ends
# the supervision at once instead of waiting out a timeout that can only
# confirm what the line already said. Each is a literal the host emits; they are
# deliberately few and specific, because a false positive here aborts a healthy
# run.
FATAL_HOST_LINES = (
    # The host's runtime wait GAVE UP. This is the terminal line of the loop in
    # aowlhost.nim:7231 -- after it, nothing else is tried.
    #
    # It used to read `il2cpp_init returned 0`, and that was WRONG in the worst
    # possible way. That line is logged at `fail` level from INSIDE the wait
    # loop, which then keeps going ("still waiting for the runtime (10s)...")
    # for up to 120s and routinely succeeds afterwards. Treating it as terminal
    # made the supervisor abort three consecutive HEALTHY launches at ~7s and
    # report DIED, which sent this session hunting a nonexistent regression
    # through the host DLL, the deploy and the BattlEye service -- each of
    # which it correctly exonerated, because none of them was the problem. The
    # supervisor was.
    #
    # A false positive in this table is strictly worse than a missing entry: a
    # miss costs a timeout, a false positive fabricates a cause and destroys
    # trust in every verdict the tool prints. Match only on a line the host
    # emits when it has actually stopped trying.
    "the runtime did not come up:",
    # The launcher refuses to leave a client running with no host in it.
    "terminating the client rather than leaving it running without mods",
)

# Exit codes. Distinct per verdict on purpose: a caller should be able to branch
# on "it showed a dialog" without parsing prose.
EXIT = {
    "REACHED": 0,
    "DIED": 1,
    "TIMEOUT": 2,
    "IDLE": 3,
    "ERRORDIALOG": 4,
    "CRASH": 5,
    "INCONCLUSIVE": 6,
    "POPUP": 7,
    # Bounded rather than inferred: the run got somewhere real and then
    # stopped getting anywhere. Distinct from TIMEOUT (never got there) and
    # from IDLE (the whole host went quiet) so a caller can tell "wedged in a
    # raid" from "never reached the raid".
    "STALLED": 8,
    # The launcher declared the server dead. The client may still be sitting
    # there looking perfectly alive.
    "BACKENDDOWN": 9,
}


def install_dir(root):
    return os.path.join(root, "aowlspt")


# The single sentence a later reader needs. It is one literal so the console
# block and the on-disk note cannot drift apart -- a warning that says two
# slightly different things in two places is how you end up trusting neither.
TEARDOWN_LINE = ("TEARDOWN: stopping the client, backend and launcher now "
                 "(no --keep). If you meant to keep driving it, rerun with "
                 "--keep.")

# Written next to aowlspt-host.log, deliberately: whoever is reading the host
# log after the fact is already in that directory.
TEARDOWN_LOG = "aowlspt-run-teardown.log"

STOP_PS = ("Get-Process -Name EscapeFromTarkov,aowlspt-backend,aowlspt-launch "
           "-ErrorAction SilentlyContinue | Stop-Process -Force")


def do_teardown(root, dry=False):
    """Stop the client -- and LEAVE A TRACE THAT WE DID.

    Measured cost, 2026-09-01: ~20 minutes. `run.py` without `--keep` kills the
    client the instant its verdict lands. Read afterwards, that is
    indistinguishable from a clean crash -- the host log simply ends, on a
    heartbeat, with no fault line and no crash folder, which is exactly the
    shape of a client that vanished on its own. The tool was the cause of the
    evidence someone then spent twenty minutes explaining.

    The default is NOT changed; a harness that leaves the game running by
    default is worse. What changes is that the teardown now announces itself in
    two places: the verdict block (for whoever ran it) and an appended,
    timestamped line in the install directory (for whoever reads that directory
    later, possibly in another session, and has no transcript at all).

    The note is written BEFORE the kill, so it exists even if the kill hangs or
    this process is itself reaped mid-teardown.
    """
    stamp = time.strftime("%Y-%m-%d %H:%M:%S")
    note = os.path.join(install_dir(root), TEARDOWN_LOG)
    try:
        with open(note, "a", encoding="utf-8", newline="\n") as f:
            f.write("[%s] %s%s\n"
                    % (stamp, TEARDOWN_LINE,
                       "  (--dry-teardown: nothing was stopped)" if dry
                       else ""))
    except OSError as e:
        # Never let bookkeeping stop the teardown; say so rather than hiding it.
        print("  (could not write %s: %s)" % (note, e), flush=True)
    if dry:
        return
    subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-Command",
                    STOP_PS], capture_output=True, timeout=60)


class Supervisor:
    """Watches all three sources at once and returns the FIRST decisive event.

    * the host log      -- ERRORDIALOG, and the `errdlg ARMED` line that says
                           whether the dialog catcher is actually watching.
    * the client's logs -- crashwatch's measured crash signatures.
    * the process       -- gone is gone.

    Order matters where two fire in the same tick: a dialog names the cause, an
    incidental exception logged beside it usually does not.
    """

    def __init__(self, root, until, stall, quiet, phase_max=900.0,
                 until_phase=None, menu_settle=20.0):
        # MENU is only "reached" once it has held with no other host progress
        # for this long -- see poll_host for why the first sighting lies.
        self.menu_settle = menu_settle
        self.host_path = harness.hostlog_path(root)
        self.until = until
        self.stall = stall
        self.quiet = quiet
        # The RAID BOUND. `phase` is whatever raidphase.nim last published;
        # `phase_since` is when it last CHANGED. A raid that has not changed
        # phase in `phase_max` is wedged -- which is a state, not a duration,
        # and is the thing `time.sleep(60.0)` could never express.
        self.phase = None
        # Arrive on a STATE the client publishes about itself, instead of
        # waiting for a log line to imply it. "We are already on the main menu,
        # why are we still waiting" -- because nothing consulted this.
        self.until_phase = until_phase
        self.phase_since = time.time()
        self.phase_max = phase_max
        # The BACKEND log, tailed exactly like the host log. The launcher has
        # printed `BACKEND DOWN` all along and no supervisor has ever read it,
        # so the server dying looked identical to the game being slow.
        self.backend_path = os.path.join(install_dir(root),
                                         "aowlspt-backend.log")
        try:
            self.backend_pos = os.path.getsize(self.backend_path)
        except OSError:
            self.backend_pos = 0
        self.backend_leftover = ""
        # START AT THE END of whatever host log is already on disk. Two reasons,
        # and the first one bit immediately:
        #
        #  * The previous run's log is still there until the host attaches and
        #    truncates it. Reading it sets `seen_any`, and `seen_any` plus a
        #    client that has not spawned YET reads as DIED -- a fabricated crash
        #    at ~3s, which is exactly the false-crash trap CLAUDE.md section 1
        #    describes from the other direction.
        #  * It is also a token bomb: the old log can be tens of thousands of
        #    lines and none of them are about this run.
        #
        # When the host attaches it truncates, `size < host_pos` fires, and the
        # NEW run is then read from byte 0 -- so nothing from this run is missed.
        try:
            self.host_pos = os.path.getsize(self.host_path)
        except OSError:
            self.host_pos = 0
        self.host_leftover = ""
        self.host_tail = []
        self.errdlg_armed = None      # None = not stated yet in this run's log
        self.seen_any = False
        self.last_progress = time.time()
        # ANY host line, heartbeats included. Distinct from `last_progress` on
        # purpose: a host that has stopped printing even its 5s heartbeat is
        # not idle, it is gone -- and that, not "nothing interesting is
        # happening", is what a stall at the destination phase looks like.
        self.last_line = None
        self.evidence = []
        self.marks = []
        # The client's own logs, through crashwatch so the signature list stays
        # in exactly one place.
        self.logs_root = os.path.join(root, "Logs")
        self.cur_dir = crashwatch.newest_log_dir(self.logs_root)
        self.tailers = {}
        if self.cur_dir:
            _, self.tailers = crashwatch.build_tailers(self.cur_dir,
                                                       from_start=False)

    # -- host log ---------------------------------------------------------
    def _host_lines(self):
        try:
            size = os.path.getsize(self.host_path)
        except OSError:
            return []
        if size < self.host_pos:      # host attached, fresh run
            self.host_pos = 0
            self.host_leftover = ""
            self.errdlg_armed = None
        if size == self.host_pos:
            return []
        with open(self.host_path, "r", encoding="utf-8", errors="replace") as f:
            f.seek(self.host_pos)
            data = f.read()
            self.host_pos = f.tell()
        data = self.host_leftover + data
        lines = data.split("\n")
        self.host_leftover = lines.pop()
        return [l.rstrip("\r") for l in lines]

    # -- backend log ------------------------------------------------------
    def poll_backend(self):
        """Did the SERVER die? Nothing used to ask.

        `aowllaunch.nim` restarts the backend on failure and, after N failures,
        prints `BACKEND DOWN` and stops trying. The client keeps running and
        keeps looking healthy from the outside -- it just cannot reach
        127.0.0.1 any more. Every symptom of that arrives late and disguised
        (a hang at a loading screen, an in-game error dialog minutes later),
        which is precisely the "waiting on logs for something that already
        failed" shape this whole tool exists to kill.

        Read the same way as the host log: seek to the end at construction, and
        only ever read what is appended. The backend log is 600KB and growing;
        it is never read whole.
        """
        try:
            size = os.path.getsize(self.backend_path)
        except OSError:
            return None                      # no backend log is not evidence
        if size < self.backend_pos:          # rotated / fresh run
            self.backend_pos = 0
            self.backend_leftover = ""
        if size == self.backend_pos:
            return None
        with open(self.backend_path, "r", encoding="utf-8",
                  errors="replace") as f:
            f.seek(self.backend_pos)
            data = f.read()
            self.backend_pos = f.tell()
        data = self.backend_leftover + data
        lines = data.split("\n")
        self.backend_leftover = lines.pop()
        for line in lines:
            if BACKEND_DOWN_LINE in line:
                return ("BACKENDDOWN", line.strip(), [line.strip()])
        return None

    def mark(self, text):
        """A sparse, one-line progress note on a STATE TRANSITION.

        Not per-log-line streaming -- that is what `--verbose` is for, and it is
        the token bomb this tool exists to avoid. This is a handful of lines per
        run, and it exists because a verdict printed only at the very end is
        lost entirely to a hard kill.

        On Windows an external `TerminateProcess` (what a `timeout` wrapper or a
        task reaper uses) CANNOT be caught -- the SIGINT/SIGTERM handler below
        only covers Ctrl-C. Measured: a supervised launch wrapped in `timeout`
        left a completely empty output file. So the trail has to already be on
        stdout before the kill arrives, not assembled after it.
        """
        if not self.marks or self.marks[-1] != text:
            self.marks.append(text)
            print("  .. %s" % text, flush=True)

    def check_clocks(self, now, evidence=None):
        """The TIME-driven rules, in ONE place and in an EXPLICIT order.

        These used to be scattered: the MENU-settle test lived in an `elif` of
        the phase-change branch, the phase bound in the next `elif`, and the
        IDLE test in the main loop. Nothing stated which outranked which, so
        the answer was "whichever the log happened to reach first" -- and that
        is exactly how one client state produced REACHED, STALLED and TIMEOUT
        on three consecutive boots.

        The order, stated once:

          0. TOTAL SILENCE at the destination is a STALL. The host prints its
             raid phase every 5s forever; a log that has produced NOTHING AT
             ALL for `--stall` is a host that stopped, not a client parked at a
             screen. This is checked FIRST because it is the only reading of
             "stalled at the phase you asked for" that a healthy parked client
             cannot also satisfy.
          1. ARRIVAL. `--until-phase` was asked for, the client is in that
             phase, no progress for `--menu-settle`, AND the host is still
             heartbeating. It cannot lose to a stall bound, because being
             parked where you asked to be parked is success, not a wedge.
          2. THE PHASE BOUND, but only away from the destination. In the phase
             you ASKED for, "one phase for a long time" is the goal, so it
             cannot also be the failure -- reporting STALLED there is the
             measured false positive this ordering exists to prevent.

        The liveness qualifier on rule 1 is what keeps rule 0 reachable. Quiet
        is the SUCCESS condition here, and silence is a superset of quiet, so
        without it a host that died at the menu would satisfy arrival first
        (at `--menu-settle`) and never reach the silence test (at `--stall`,
        which is longer). `HOST_HEARTBEAT_S` is measured; the allowance of
        three missed beats is a stated tolerance, not a measurement.

        This still cannot distinguish a host that died from one parked at the
        menu if `--menu-settle` is set below that allowance. Say so rather than
        pretending otherwise: the process poll and the crash detector are what
        cover a dead client, not this.

        Returns a verdict tuple or None. `evidence` is the line that prompted
        the call, when there was one.
        """
        if self.phase is None:
            return None
        ev = [evidence] if evidence else self.host_tail[-1:]
        at_destination = bool(self.until_phase) and self.phase == self.until_phase
        quiet = now - self.last_progress
        silent = now - self.last_line if self.last_line else 0.0

        # 0. THE HOST STOPPED TALKING ALTOGETHER.
        if at_destination and self.last_line and silent >= self.stall:
            return ("STALLED",
                    "raid phase %s is where --until-phase asked to stop, but "
                    "the host log has printed NOTHING AT ALL -- not even its "
                    "%.0fs heartbeat -- for %ds. A live host heartbeats, so "
                    "this is a host that stopped, not a client parked at a "
                    "screen" % (self.phase, HOST_HEARTBEAT_S, int(silent)), ev)

        # 1. ARRIVAL.
        if (at_destination and self.phase == "MENU"
                and quiet >= self.menu_settle
                and silent <= HOST_HEARTBEAT_S * 3):
            return ("REACHED",
                    "raid phase = MENU has held with no other host progress "
                    "for %ds -- the boot is over and the client is parked at "
                    "the menu" % int(quiet), ev)

        # 2. THE PHASE BOUND.
        if (self.phase_max and not at_destination
                and now - self.phase_since > self.phase_max):
            return ("STALLED",
                    "stuck in raid phase %s for %ds (limit %ds) -- the host is "
                    "alive and still publishing, so this is a wedged run, not "
                    "a dead one"
                    % (self.phase, int(now - self.phase_since),
                       int(self.phase_max)), ev)
        return None

    def poll_host(self):
        for line in self._host_lines():
            if not self.seen_any:
                self.mark("host attached, log restarted")
            self.seen_any = True
            self.last_line = time.time()

            # A HEARTBEAT proves the host is alive; it does not prove the RUN
            # is going anywhere. Only a non-periodic line refreshes the
            # progress clock -- see HEARTBEAT_HOST_LINES for what this cost.
            if is_progress(line):
                self.last_progress = time.time()

            # RAID PHASE. The signal existed and nothing consumed it. A phase
            # CHANGE is real progress even though the line carrying it is a
            # heartbeat, so it refreshes the clock and re-arms the bound.
            m = RAID_PHASE.search(line)
            if m:
                ph = m.group(1)
                if ph != self.phase:
                    self.mark("raid phase -> %s" % ph)
                    self.phase = ph
                    self.phase_since = time.time()
                    self.last_progress = time.time()

                    # ARRIVED. The host publishing a phase is the client
                    # SAYING where it is, which beats waiting for a log
                    # sentinel to imply it.
                    # MENU is special and this bit me: it is published at
                    # ~0:00:09 on every boot, BEFORE the main thread is even
                    # ticking, because it only means "no GameWorld is cached".
                    # Returning REACHED on that first sighting reported a
                    # healthy boot for a client that then died at 0:00:15.
                    # So MENU is only "reached" once it has SETTLED: the phase
                    # is MENU and the host has printed no real progress for a
                    # while, which is what the finished boot looks like and
                    # what an early boot never looks like.
                    if (self.until_phase and ph == self.until_phase
                            and ph != "MENU"):
                        return ("REACHED",
                                "the host published raid phase = %s" % ph,
                                [line.strip()])

                    # NOTE on a rule deliberately NOT implemented here: it is
                    # tempting to declare a load-phase `--until` FUTILE the
                    # moment MENU is published, since the mod loading screen
                    # and profile load are over by then. But MENU only means
                    # "no GameWorld is cached", which is equally true during
                    # early boot -- so that rule would abort healthy runs
                    # exactly the way the `il2cpp_init returned 0` entry in
                    # FATAL_HOST_LINES did. The honest bound for "parked at a
                    # screen" is the IDLE detector, which works now that
                    # heartbeats no longer refresh the progress clock.

                # Settle and the phase bound are BOTH time-driven, so they live
                # in check_clocks and are evaluated in a stated order. They are
                # re-checked here as well as from the main loop so that a
                # verdict lands on the exact line that carried the phase.
                hit = self.check_clocks(time.time(), line.strip())
                if hit:
                    return hit
            if self.quiet:
                self.host_tail.append(line)
                del self.host_tail[:-40]
            else:
                print(line)
            if "errdlg ARMED" in line:
                self.mark("error-dialog catch ARMED")
            if "errdlg ARMED" in line:
                self.errdlg_armed = True
            elif "catchErrorDialogs is explicitly false" in line or \
                 "errdlg did not arm" in line or \
                 "NONE of the" in line and "error-screen entry points bound" in line:
                self.errdlg_armed = False
            # A HOST-REPORTED FATAL. Return immediately, do not wait anything
            # out.
            #
            # This is the gap that made a supervised run still burn its whole
            # timeout: a client that dies in ~1.6s is never observed alive by
            # the 5s process poll, so `ever_alive` stays false and the DIED
            # branch waits the full BOOT_GRACE_S before concluding anything --
            # 95 seconds spent watching a process that already printed the
            # reason it was doomed. The host SAYS these; believing it is
            # strictly better than inferring death from a process table.
            for sig in FATAL_HOST_LINES:
                if sig in line:
                    return ("DIED", "the host reported a fatal: " + line.strip(),
                            [line.strip()])
            # The suppression notice is the host saying it stopped printing; it
            # is not itself a dialog and must not be reported as one.
            if "ERRORDIALOG kind=" in line and 'header="<suppressed>"' not in line:
                return ("ERRORDIALOG", line.strip(), [line.strip()])
            if self.until and self.until in line:
                return ("REACHED", line.strip(), [line.strip()])
        return None

    # -- client logs ------------------------------------------------------
    def poll_client(self):
        # A relaunch makes a new session dir; pick it up.
        nd = crashwatch.newest_log_dir(self.logs_root)
        if nd and nd != self.cur_dir:
            self.cur_dir = nd
            _, self.tailers = crashwatch.build_tailers(nd, from_start=True)
        for _suf, t in list(self.tailers.items()):
            for sig, detail, text in t.poll():
                return ("CRASH", "%s -- %s" % (sig, detail), t.tail_lines(8))
        return None


def verdict_block(v, why, evidence, elapsed, armed, logs, as_json,
                  teardown=False):
    if as_json:
        print(jsonmod.dumps({
            "verdict": v, "why": why, "elapsed_s": round(elapsed, 1),
            "errdlg_armed": armed, "evidence": evidence[-6:], "logs": logs,
            "teardown": bool(teardown),
        }, separators=(",", ":")))
        if teardown:
            # --json is one machine-readable line and must stay one line, so
            # the human sentence goes to stderr rather than being dropped.
            sys.stderr.write(TEARDOWN_LINE + "\n")
            sys.stderr.flush()
        return
    bar = "-" * 64
    print("\n" + bar)
    print(" %-12s  %s" % (v, why))
    print(" %-12s  %.1fs" % ("elapsed", elapsed))
    if armed is False:
        print(" %-12s  NO -- in-game error dialogs were NOT being watched on "
              "this run." % "dialog catch")
        print(" %-12s  So a quiet log does NOT prove the client is healthy."
              % "")
    elif armed is None:
        print(" %-12s  UNKNOWN -- the host never said whether it armed."
              % "dialog catch")
    for line in evidence[-6:]:
        print("   | " + line[:200])
    if logs:
        print(" %-12s  %s" % ("logs", "  ".join(logs)))
    if teardown:
        print(" " + TEARDOWN_LINE)
    print(bar, flush=True)


def main():
    p = argparse.ArgumentParser(
        description="launch + supervise the client and print one verdict",
        formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    p.add_argument("--root", default=DEFAULT_ROOT)
    p.add_argument("--until", default=None,
                   help="host-log literal that counts as success")
    p.add_argument("--timeout", type=int, default=300)
    p.add_argument("--until-phase", default=None,
                   metavar="MENU|LOADING|DEPLOYED",
                   help="stop as soon as the host publishes this raid phase. "
                        "The client saying where it is beats waiting for a log "
                        "line to imply it: MENU = the main menu is up, "
                        "DEPLOYED = standing in the raid.")
    p.add_argument("--launcher-arg", action="append", default=[],
                   metavar="FLAG[ VALUE]",
                   help="raw flag passed to aowlspt-launch.exe, repeatable "
                        "(e.g. --launcher-arg \"--modbuild C:/x/modbuild.py\")")
    p.add_argument("--menu-settle", type=float, default=20.0,
                   help="with --until-phase MENU: seconds of no other host "
                        "progress before MENU counts as reached. MENU is "
                        "published at ~9s on every boot, long before the menu "
                        "exists; the first sighting is never the answer.")
    p.add_argument("--phase-max", type=float, default=900.0,
                   help="seconds allowed in ONE raid phase before the run is "
                        "called STALLED. Bounds the raid on a published "
                        "state rather than on a blind sleep; a phase change "
                        "re-arms it. 0 disables the bound. It does NOT apply "
                        "to the phase --until-phase asked for.")
    p.add_argument("--stall", type=int, default=45,
                   help="seconds with no PROGRESS line that count as IDLE. In "
                        "the phase --until-phase asked for it means something "
                        "stricter: seconds with no host line AT ALL, "
                        "heartbeats included, before that counts as STALLED.")
    p.add_argument("--attach", action="store_true",
                   help="do not launch; the client is already running")
    p.add_argument("--keep", action="store_true",
                   help="leave the client running afterwards. Without it the "
                        "client, backend and launcher are STOPPED once the "
                        "verdict lands, and the verdict block says so.")
    p.add_argument("--dry-teardown", action="store_true",
                   help="announce the teardown and write the teardown note, "
                        "but do not actually Stop-Process anything. Exists so "
                        "tools/test_supervise.py can drive the real code path "
                        "without killing a game a human may be playing.")
    p.add_argument("--inspect", nargs="*", default=None,
                   help="inspector commands to run once the run settles")
    p.add_argument("--json", action="store_true")
    p.add_argument("--verbose", action="store_true",
                   help="stream the host log instead of only the verdict")
    args = p.parse_args()

    quiet = not args.verbose
    started = time.time()

    # SAY SOMETHING WHEN KILLED FROM OUTSIDE.
    #
    # This printed its verdict only at the very end, so an external kill -- a
    # `timeout` wrapper, a Ctrl-C, a harness reaping a background task -- lost
    # EVERYTHING. Measured: a supervised launch wrapped in `timeout 260` left a
    # completely empty output file, which is the exact "something went wrong and
    # you cannot tell what" outcome this tool exists to end. A supervisor that
    # goes silent when interrupted is worse than no supervisor, because the run
    # looked supervised.
    #
    # On SIGTERM/SIGINT: print what is known SO FAR, clearly marked as
    # interrupted rather than concluded, and exit 130. The state is deliberately
    # read out of the live `sup` object, so this reports the real progress and
    # never a placeholder.
    state = {"sup": None}

    def _on_signal(_signum, _frame):
        sup_ = state.get("sup")
        el = time.time() - started
        armed = sup_.errdlg_armed if sup_ else None
        tail = (sup_.host_tail[-4:] if sup_ else [])
        verdict_block(
            "INTERRUPTED",
            ("killed after %.1fs before a verdict was reached -- this is what "
             "was known at that moment, NOT a conclusion about the run" % el),
            tail, el, armed, [], args.json)
        sys.exit(130)

    for _sig in ("SIGTERM", "SIGINT", "SIGBREAK"):
        s = getattr(signal, _sig, None)
        if s is not None:
            try:
                signal.signal(s, _on_signal)
            except (ValueError, OSError):
                pass    # not the main thread, or unsupported here: not fatal

    if not args.attach:
        # Stop whatever is up first: the host DLL is LOCKED while the game runs.
        # `--dry-teardown` covers THIS kill too, not only the one at the end:
        # the flag means "this invocation stops no processes", and a test that
        # opted out of the teardown but still reaped a human's running client
        # on the way in would be worse than no test.
        if args.dry_teardown:
            print("(--dry-teardown: not stopping any running client first)",
                  flush=True)
        else:
            subprocess.run(["powershell", "-NoProfile", "-NonInteractive",
                            "-Command", STOP_PS],
                           capture_output=True, timeout=60)
            time.sleep(3)
        launcher = os.path.join(install_dir(args.root), "aowlspt-launch.exe")
        if not os.path.isfile(launcher):
            print("no launcher at %s" % launcher)
            return EXIT["INCONCLUSIVE"]
        cmd = [launcher]
        # Raw pass-through for launcher flags (e.g. `--modbuild PATH`,
        # `--no-mod-build`, `--rebuild-mods`). Printed so the run's own
        # transcript shows exactly what was started.
        for extra in (args.launcher_arg or []):
            cmd += extra.split(" ", 1) if " " in extra else [extra]
        print("$ %s" % " ".join(cmd), flush=True)
        subprocess.Popen(cmd, cwd=install_dir(args.root))

    sup = Supervisor(args.root, args.until, args.stall, quiet,
                     phase_max=args.phase_max,
                     until_phase=args.until_phase,
                     menu_settle=args.menu_settle)
    state["sup"] = sup   # the signal handler reports from the live object
    verdict = why = None
    evidence = []
    last_alive = 0.0
    last_popup = 0.0
    ever_alive = False

    while verdict is None:
        now = time.time()
        # Host first (it names causes), then the BACKEND (a dead server is
        # the cause of symptoms that surface minutes later in the client),
        # then the client's own logs.
        # `check_clocks` is asked on every tick, not only when a line arrives:
        # the settle window and the total-silence test are about time PASSING,
        # and a rule that can only be evaluated by an incoming log line cannot
        # observe the absence of log lines.
        hit = (sup.poll_host() or sup.check_clocks(now)
               or sup.poll_backend() or sup.poll_client())
        if hit:
            verdict, why, evidence = hit
            break
        # NATIVE POPUPS. Checked on the same cadence as the process, because a
        # Win32 message box is the one failure that reaches NO log file: not the
        # host log, not the client's Logs/, not Unity's Player.log (created and
        # left EMPTY), not the event log. Measured 2026-09-01: "The BattlEye
        # service is not running" and "Unable to check the client version" each
        # stopped every launch dead while every log-reading tool reported
        # nothing wrong. The process stays alive holding the dialog, which is
        # indistinguishable from a healthy slow boot -- so without this the
        # supervisor waits out its whole timeout on a run that is already over.
        if now - last_popup > 5:
            last_popup = now
            try:
                pops = popups.scan()
            except Exception:
                pops = []
            if pops:
                first = pops[0]
                lines = [t for t in first["text"] if t not in first["buttons"]]
                verdict = "POPUP"
                why = ("a native dialog is up and waiting for a click: %s -- %s"
                       % (first["caption"] or "(no caption)",
                          " / ".join(lines) or "(no message text)"))
                evidence = ["%s [%s]" % (first["caption"], first["process"])] + lines
                break

        if now - last_alive > 5:
            last_alive = now
            if harness.client_alive():
                if not ever_alive:
                    sup.mark("client process is up")
                ever_alive = True
            elif ever_alive:
                # It was up and now it is not. That is a real death.
                verdict, why = "DIED", "the client process was up and is gone"
                evidence = sup.host_tail[-6:]
                break
            elif now - started > BOOT_GRACE_S:
                # Never seen alive at all. CLAUDE.md section 1: the client takes
                # >60s to reach profile-select, and a process check taken too
                # early reads "gone" simply because it has not spawned yet. So
                # this needs a real grace period, and it is reported as its own
                # thing rather than as a crash -- "it never started" and "it
                # started and died" have completely different causes.
                verdict = "DIED"
                why = ("the client never appeared within %ds -- it did not "
                       "start, as opposed to starting and dying"
                       % BOOT_GRACE_S)
                evidence = sup.host_tail[-6:]
                break
        if sup.seen_any and now - sup.last_progress > args.stall:
            # ORDERING, stated rather than implied. If `--until-phase` was
            # asked for and the client is sitting in that phase, quiet is the
            # SUCCESS condition, not the idle condition -- check_clocks owns
            # this state and will return REACHED once --menu-settle elapses.
            # With the defaults settle (20s) < stall (45s) so REACHED already
            # wins on time, but a run given `--menu-settle 60` would otherwise
            # be reported IDLE at 45s for doing exactly what was asked.
            if not (sup.until_phase and sup.phase == sup.until_phase):
                verdict = "IDLE"
                why = ("alive, but no host-log line for %ds" % args.stall)
                evidence = sup.host_tail[-3:]
                break
        if now - started > args.timeout:
            verdict, why = "TIMEOUT", "%ds elapsed" % args.timeout
            evidence = sup.host_tail[-3:]
            break
        time.sleep(0.3)

    # "I could not look" is not a pass. An IDLE verdict is only trustworthy if
    # the dialog catcher was actually armed -- otherwise a modal error window
    # produces exactly this same quiet-but-alive shape, and calling that IDLE
    # would be a check that cannot fail.
    if verdict == "IDLE" and sup.errdlg_armed is not True:
        verdict = "INCONCLUSIVE"
        why = ("the log went quiet and the client is alive, but the in-game "
               "error-dialog catch was NOT confirmed armed, so this cannot be "
               "distinguished from the client sitting on an error window")

    # Only run inspector commands when the client is actually up and healthy.
    if args.inspect and verdict in ("REACHED", "IDLE"):
        cmd = [sys.executable, os.path.join(HERE, "inspector.py"),
               "--timeout", "60"] + list(args.inspect)
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
        sys.stdout.write(r.stdout)
        if r.returncode != 0:
            sys.stderr.write(r.stderr)
    elif args.inspect:
        print("\n(skipped --inspect: the verdict was %s, so the client is not "
              "in a state where an inspector batch would mean anything)"
              % verdict)

    logs = [p for p in (harness.hostlog_path(args.root),) if os.path.isfile(p)]
    if sup.cur_dir:
        logs.append(sup.cur_dir)
    tearing = not args.keep and not args.attach
    verdict_block(verdict, why, evidence, time.time() - started,
                  sup.errdlg_armed, logs, args.json, teardown=tearing)

    if tearing:
        do_teardown(args.root, dry=args.dry_teardown)
    return EXIT.get(verdict, EXIT["INCONCLUSIVE"])


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
