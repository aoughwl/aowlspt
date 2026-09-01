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
                  still alive and talking. Exit 8.
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
HEARTBEAT_HOST_LINES = (
    "natesp: raid phase = ",
    "frameMeter:",
)

# The phase the host publishes. `raidphase.nim` has emitted this all along and
# nothing consumed it -- the raid was bounded by `time.sleep(60.0)` in
# enterraid.py, which asserts a DURATION and never a STATE.
RAID_PHASE = re.compile(r"raid phase = ([A-Z]+)")

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

    def poll_host(self):
        for line in self._host_lines():
            if not self.seen_any:
                self.mark("host attached, log restarted")
            self.seen_any = True

            # A HEARTBEAT proves the host is alive; it does not prove the RUN
            # is going anywhere. Only a non-periodic line refreshes the
            # progress clock -- see HEARTBEAT_HOST_LINES for what this cost.
            beat = any(h in line for h in HEARTBEAT_HOST_LINES)
            if not beat:
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
                elif (self.until_phase == "MENU" and ph == "MENU"
                      and time.time() - self.last_progress >= self.menu_settle):
                    return ("REACHED",
                            "raid phase = MENU has held with no other host "
                            "progress for %ds -- the boot is over and the "
                            "client is parked at the menu"
                            % int(time.time() - self.last_progress),
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
                elif (self.phase_max and
                      time.time() - self.phase_since > self.phase_max):
                    # Bounded on a STATE, not a duration: the host is still
                    # talking, the process is fine, and the run has been in one
                    # phase past the point where that can be normal.
                    return ("STALLED",
                            "stuck in raid phase %s for %ds (limit %ds) -- the "
                            "host is alive and still publishing, so this is a "
                            "wedged run, not a dead one"
                            % (ph, int(time.time() - self.phase_since),
                               int(self.phase_max)),
                            [line.strip()])
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


def verdict_block(v, why, evidence, elapsed, armed, logs, as_json):
    if as_json:
        print(jsonmod.dumps({
            "verdict": v, "why": why, "elapsed_s": round(elapsed, 1),
            "errdlg_armed": armed, "evidence": evidence[-6:], "logs": logs,
        }, separators=(",", ":")))
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
    print(bar)


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
    p.add_argument("--menu-settle", type=float, default=20.0,
                   help="with --until-phase MENU: seconds of no other host "
                        "progress before MENU counts as reached. MENU is "
                        "published at ~9s on every boot, long before the menu "
                        "exists; the first sighting is never the answer.")
    p.add_argument("--phase-max", type=float, default=900.0,
                   help="seconds allowed in ONE raid phase before the run is "
                        "called STALLED. Bounds the raid on a published "
                        "state rather than on a blind sleep; a phase change "
                        "re-arms it. 0 disables the bound.")
    p.add_argument("--stall", type=int, default=45,
                   help="seconds of host-log silence that count as IDLE")
    p.add_argument("--attach", action="store_true",
                   help="do not launch; the client is already running")
    p.add_argument("--keep", action="store_true",
                   help="leave the client running afterwards")
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
        subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-Command",
                        "Get-Process -Name EscapeFromTarkov,aowlspt-backend,"
                        "aowlspt-launch -ErrorAction SilentlyContinue "
                        "| Stop-Process -Force"], capture_output=True, timeout=60)
        time.sleep(3)
        launcher = os.path.join(install_dir(args.root), "aowlspt-launch.exe")
        if not os.path.isfile(launcher):
            print("no launcher at %s" % launcher)
            return EXIT["INCONCLUSIVE"]
        subprocess.Popen([launcher], cwd=install_dir(args.root))

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
        hit = sup.poll_host() or sup.poll_backend() or sup.poll_client()
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
    verdict_block(verdict, why, evidence, time.time() - started,
                  sup.errdlg_armed, logs, args.json)

    if not args.keep and not args.attach:
        subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-Command",
                        "Get-Process -Name EscapeFromTarkov,aowlspt-backend,"
                        "aowlspt-launch -ErrorAction SilentlyContinue "
                        "| Stop-Process -Force"], capture_output=True, timeout=60)
    return EXIT.get(verdict, EXIT["INCONCLUSIVE"])


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
