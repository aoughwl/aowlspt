#!/usr/bin/env python3
r"""run.py -- ONE command that launches the client, supervises it, and prints a
verdict small enough to read.

    python tools/run.py                       launch, supervise, report
    python tools/run.py --until "host running"
    python tools/run.py --inspect "state" "find SettingsScreen"
    python tools/run.py --attach              the game is already running
    python tools/run.py --json                machine-readable, one line
    python tools/run.py --teardown            stop the client at the verdict
                                              (NOT the default any more)

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
                  crashwatch's measured signatures, AND THE PROCESS IS GONE.
                  Exit 5. A managed exception logged by a client that is still
                  running is a NOTE in the block, never a verdict: Tarkov logs
                  and catches `NullReferenceException` from its own bot AI
                  (`MalfunctionLayer.ShallUseNow` under
                  `EFT.BotsController.UpdateByUnity`) in every raid, and that
                  alone once produced `CRASH` at 0.5s for a client standing in
                  a raid. See Supervisor.poll_client.
    DIED          the process is gone. Exit 1. NEVER printed bare: a DIED
                  verdict always carries the DIED FORENSICS block (the crash
                  report, crashwatch's frames, dmpread's faulting registers and
                  `il2cpp_resolve disasm` at the faulting RVA) or an explicit
                  sentence saying why each of those could not be collected.
    KILLED-BY-TOOL <tool> <reason>
                  the process is gone AND a tool recorded a teardown within 10s
                  of it in aowlspt-teardown.jsonl. Exit 11. This is our own
                  kill, not the client's fault.
    TIMEOUT       none of the above within --timeout. Exit 2.
    STALLED       it got somewhere real and then stopped getting anywhere: one
                  raid phase, unchanged, past --phase-max, while the host is
                  still alive and talking. Exit 8. NOT reported for the phase
                  `--until-phase` asked for -- being parked there is the goal,
                  so a stall there requires the host log to have stopped
                  entirely, heartbeat included. See Supervisor.check_clocks.
    BACKENDDOWN   the launcher gave up restarting the server. The client is
                  usually still up and still looks fine. Exit 9.
    PARKED-BEFORE-MENU
                  `--until-phase MENU` was asked for, the phase is MENU and
                  the log has gone quiet -- but the host NEVER logged the
                  MenuScreen::Show event, so the main menu was never shown.
                  The client is parked at some earlier screen (usually
                  character/mode select) with no GameWorld cached, which is
                  all `raid phase = MENU` has ever meant. Exit 10. See
                  MENU_PROOF_LINES.

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

## If the process is gone, it reads Unity's OWN crash report

MEASURED 2026-09-02: four deaths were chased for an hour off nothing but "the
client process was up and is gone", while Unity's crash handler had written a
full stack trace for each one under `%LOCALAPPDATA%\Temp\Battlestate
Games\EscapeFromTarkov\Crashes\Crash_<UTC stamp>\Player.log`. So on any verdict
where the process is gone, the block now carries `CRASH REPORT <folder> (<age>s
after launch)`, the top 12 crash-site frames, and ONE attribution line -- the
first crash-site frame in a module of ours (the host DLL or a mod), else the
top frame's module. When no report newer than launch exists it says `NO CRASH
REPORT was written`, which is a fact and not an absence: that death was a
teardown or an exit, not a native fault. Parsing lives in `crashwatch.py`.

## It does NOT stop the client any more unless you ask (changed 2026-09-02)

`--keep` used to be opt-in, and the default force-stopped the client, the
backend and the launcher the moment the verdict landed. Read afterwards, that is
indistinguishable from a clean crash -- the host log ends on a heartbeat, with
no fault and no crash folder -- and it was mistaken for one three times, ~20
minutes each. Stopping the Bash task that launched a run did the same thing.

So the default is now to LEAVE THE CLIENT RUNNING. `--teardown` asks for the old
behaviour and prints a line saying so; `--keep` is still accepted and does
nothing, so old callers and recipes keep working.

Every teardown, by any tool, is also recorded as one JSON line in
`aowlspt-teardown.jsonl` (`tools/runledger.py`) BEFORE anything is killed. A
death within 10s of such an entry is reported as `KILLED-BY-TOOL <tool>
<reason>` (exit 11), never as DIED. The prose `TEARDOWN:` line in the verdict
block and the timestamped `aowlspt-run-teardown.log` note both remain.
`--dry-teardown` does all the announcing and kills nothing.

## It prints what the boot is carrying, BEFORE it launches

`this boot carries: host DLL <size> built <time> from <sha or dirty: N files>;
<K> commits and <M> uncommitted host/mod files since the previous boot`, and a
WARN when K+M is over 4: *a crash on this boot cannot be attributed without a
bisect*. All of it is derived -- the deployed DLL's size and mtime, `git log
--since` the previous recorded launch, `git status --porcelain` -- and anything
that could not be measured prints as `?` with a reason, never as a zero.

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
import runledger   # noqa: E402  -- the teardown + boot ledgers, one definition

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


# A RAID LOAD IS LEGITIMATELY QUIET, AND THE HOST IS NOT WHERE IT SHOWS.
#
# MEASURED 2026-09-02: `run.py --attach --until-phase DEPLOYED --phase-max 480`
# exited 6 (INCONCLUSIVE, "the log went quiet") at 60.8s while the raid was
# loading normally -- it reached DEPLOYED afterwards. Two separate things were
# wrong, and only both together explain that exit:
#
#  * the HOST log during a load is heartbeats and nothing else. natesp
#    re-publishes the phase every 5s and `is_progress` correctly refuses to
#    count that, so `last_progress` froze and the 45s IDLE rule fired.
#  * the phase at that moment was still **MENU**, not LOADING. The host log for
#    that run shows `raid phase = MENU` up to 0:02:17 and the first
#    `raid phase = LOADING` only at 0:02:32 -- natesp's S1 (`no GameWorld is
#    cached`) is equally true on the loading screen. So a rule keyed on the
#    LOADING phase alone would NOT have prevented this exact exit.
#
# Hence two rules, not one:
#
#  1. QUIET_EN_ROUTE: a phase in which quiet is EXPECTED given the phase that
#     was asked for. LOADING on the way to DEPLOYED is the whole measured case.
#     This is deliberately NOT symmetric with the destination exemption -- the
#     phase bound (`--phase-max`) still applies here, so a load that really is
#     wedged is still caught, as STALLED, with a stated limit.
#  2. the CLIENT's own log, which is the only thing that moves during a load.
#     `LocationLoaded`, `GameCreated` and `PlayerSpawnEvent` each occur EXACTLY
#     ONCE per load (measured, log_2026.09.02_8-09-51: 1 occurrence each in
#     application_000.log and in output_000.log), so they are one-shot progress
#     and never a heartbeat -- but three one-shots cannot carry a 3-minute load
#     past a 45s window on their own. crashwatch already owns the broad, measured
#     "the raid IS loading" predicate (`LOAD_PROGRESS_RX`: geometry, bundles,
#     scene loads, plus those three milestones), so that is reused rather than
#     restated.
#
# Rule 2 is DELIBERATELY NARROW: it counts only while `--until-phase DEPLOYED`
# was asked for and the client has not got there yet. `LOAD_PROGRESS_RX` matches
# "Loading " and "bundle", which the client logs at the menu too -- letting that
# refresh the progress clock unconditionally would re-create the heartbeat bug
# (an IDLE detector that can never fire) in a new file. Outside a raid entry
# nothing about IDLE changes.
CLIENT_LOAD_PROGRESS_LINES = ("LocationLoaded", "GameCreated",
                              "PlayerSpawnEvent")

QUIET_EN_ROUTE = {"DEPLOYED": ("LOADING",)}

# How long a cached "is the client alive" answer is trusted. Only bounds how
# stale the answer used by poll_client's gone check may be; the main loop keeps
# its own 5s poll.
ALIVE_CACHE_S = 3.0

# The phase the host publishes. `raidphase.nim` has emitted this all along and
# nothing consumed it -- the raid was bounded by `time.sleep(60.0)` in
# enterraid.py, which asserts a DURATION and never a STATE.
RAID_PHASE = re.compile(r"raid phase = ([A-Z]+)")

# HOST-SIDE PROOF THAT THE MAIN MENU WAS ACTUALLY SHOWN.
#
# MEASURED 2026-09-02 03:20: `run.py --keep --until-phase MENU` printed
# `REACHED ... the boot is over and the client is parked at the menu` while the
# client was sitting on the CHARACTER/MODE SELECT screen. The host log for that
# run ends with `skip mode screen: SHOWING 1 ... closed` and then says nothing
# further -- no menu-show line of any kind. Nothing was wrong with the settle
# window; the phase it keys on is the wrong signal. natesp's own text says what
# `raid phase = MENU` means: "no GameWorld is cached, which is what the menu
# looks like". That is equally true on the loading screen, on the profile/slot
# screen and on the main menu, so the phase cannot distinguish them and must
# not be asked to.
#
# What CAN distinguish them is the `EFT.UI.MenuScreen::Show` event -- uihooks
# site 2, the thing that fires when the main menu is built. Four features log a
# line off that event, and any ONE of them is proof it fired:
#
#   modeskip.nim:609   "skip mode screen: MenuScreen::Show fired (uihooks site
#                       2, epoch N) -- the main menu is up ..."
#   modload.nim:968    "mod loading: release gated -- READY at ...,
#                       MenuScreen::Show at ..., releasing now"  (printed ONLY
#                       on the gated release, i.e. the show event arrived; the
#                       deadline-forced release does not print it)
#   modstab.nim:4937   "hide seasons: menu epoch N -- one bounded ..."
#   modstab.nim:4900   "version brand: menu epoch N -- one bounded ..."
#
# Substrings, not whole lines, and each is the fixed prefix of its emitter --
# the variable part (epoch, timestamp) is always after the last character here.
MENU_PROOF_LINES = (
    "MenuScreen::Show fired (uihooks site 2, epoch ",  # modeskip.nim
    "mod loading: release gated -- READY at ",          # modload.nim
    "hide seasons: menu epoch ",                        # modstab.nim
    "version brand: menu epoch ",                       # modstab.nim
)

# CAN this host build even produce one of the above? `uihStatusLines` in
# uihooks.nim prints one line per site at bind time --
# `  site 2 EFT.UI.MenuScreen::Show @0x...: BOUND (slot N), fired 0x, ...`.
# A build that predates uihooks site 2 prints no such line at all, and on that
# build the absence of a proof line proves NOTHING. So the absence of this
# capability line downgrades the verdict's WORDING to unproven rather than
# turning a healthy run into a failure -- "I could not look" is not a FAIL any
# more than it is a PASS (CLAUDE.md 9b).
#
# Matched as two independent substrings so it also catches `NOT BOUND`: a build
# where the site exists but did not bind is likewise a build that can never
# emit proof, and reporting PARKED-BEFORE-MENU there would be a fabricated
# failure.
MENU_PROOF_SITE = ("site 2 ", "BOUND")

# The host's first line of a boot, written before any timestamped line
# (`aowlspt-host-il2cpp 0.1.0`). Same literal as tools/acceptance.py's
# HOST_BANNER_PREFIX. Used ONLY by the --attach prescan, to restart the
# capability scan at the LAST boot in the file: a `site 2 ... BOUND` line from
# an earlier boot describes an earlier BUILD, and letting it certify this one
# is the same "proof from the previous boot" failure the menu proof avoids.
HOST_BANNER_PREFIX = "aowlspt-host-il2cpp "

# WHICH SCREEN did the host last NAME? Only used to make the
# PARKED-BEFORE-MENU verdict actionable -- "it never reached the menu" is much
# less useful than "it is sitting on the slot screen". These are one-shot host
# lines, not a state machine, so the last one seen is the last screen the host
# had anything to say about, and the verdict says exactly that much and no more.
SCREEN_NAME_LINES = (
    ("skip mode screen: CharacterSelectionScreen.ShowSlot first fired",
     "the character/profile SLOT screen (CharacterSelectionScreen.ShowSlot "
     "fired)"),
    ("skip mode screen: SHOWING",
     "the character/mode SELECT screen (a showing of it opened and closed)"),
    ("mod loading: release HELD",
     "the character-select / profile-Submit transition (mod loading is still "
     "holding its release, waiting for MenuScreen::Show)"),
)

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
    # `--until-phase MENU` settled, but no host line ever proved the main menu
    # was shown. Distinct from REACHED (it is not success) and from STALLED
    # (nothing is wedged and the host is alive and heartbeating) so a caller
    # can branch on "it parked one screen short" without parsing prose.
    "PARKED-BEFORE-MENU": 10,
    # A TOOL stopped the client. Not a death: `run.py`'s own teardown, a
    # deploy, crashwatch's killer or a reaped harness. Distinct from DIED so a
    # caller can never mistake our own kill for the client's fault -- measured
    # cost of NOT having this: three chased "crashes" at ~20 minutes each.
    "KILLED-BY-TOOL": 11,
}

# The verdict token is `KILLED-BY-TOOL <tool> <reason>`, so the exit code is
# looked up on the FIRST WORD. Stated here rather than inline because it is the
# only verdict whose printed name carries data.
def exit_code(verdict):
    return EXIT.get((verdict or "").split(" ", 1)[0], EXIT["INCONCLUSIVE"])


def archive_previous_logs(root):
    """Copy the previous boot's aowlspt-host.log and aowlspt-backend.log to
    <root>/Logs/hostlogs/<name>.<mtime>.log before a launch overwrites them.
    Prints what it did; a failure here is reported, never fatal."""
    import shutil
    dst_dir = os.path.join(root, "Logs", "hostlogs")
    try:
        os.makedirs(dst_dir, exist_ok=True)
    except OSError as e:
        print("host-log archive: could not create %s (%s); not archived" % (dst_dir, e))
        return
    for name in ("aowlspt-host.log", "aowlspt-backend.log"):
        src = os.path.join(install_dir(root), name)
        if not os.path.isfile(src):
            continue
        try:
            stamp = time.strftime("%Y%m%d-%H%M%S", time.localtime(os.path.getmtime(src)))
            dst = os.path.join(dst_dir, "%s.%s.log" % (name[:-4], stamp))
            if os.path.exists(dst):
                continue
            shutil.copy2(src, dst)
            print("host-log archive: %s -> %s (%d bytes)" % (name, dst, os.path.getsize(dst)))
        except OSError as e:
            print("host-log archive: %s not archived (%s)" % (name, e))


def install_dir(root):
    # ONE definition, in runledger, so the ledgers and the logs cannot end up in
    # two different directories.
    return runledger.install_dir(root)


# The single sentence a later reader needs. It is one literal so the console
# block and the on-disk note cannot drift apart -- a warning that says two
# slightly different things in two places is how you end up trusting neither.
TEARDOWN_LINE = ("TEARDOWN: stopping the client, backend and launcher now "
                 "(you passed --teardown). This is recorded in "
                 "aowlspt-teardown.jsonl, so a later reader can tell this stop "
                 "from a crash. Drop --teardown to leave the client running.")

# Written next to aowlspt-host.log, deliberately: whoever is reading the host
# log after the fact is already in that directory.
TEARDOWN_LOG = "aowlspt-run-teardown.log"

STOP_PS = ("Get-Process -Name EscapeFromTarkov,aowlspt-backend,aowlspt-launch "
           "-ErrorAction SilentlyContinue | Stop-Process -Force")


def do_teardown(root, dry=False, reason="--teardown: stopping the client at "
                                        "the verdict"):
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
    # THE LEDGER FIRST. The prose note below is for a human reading the
    # directory; this is the machine-readable half that run.py's own DIED path
    # reads back, and it is written BEFORE anything is stopped so it survives a
    # kill that reaps us too.
    if runledger.record("run.py", reason + ("  (--dry-teardown: nothing was "
                                            "stopped)" if dry else ""),
                        root=root) is None:
        print("  (could not write the teardown ledger at %s -- a death in the "
              "next %ds will NOT be attributable to this stop)"
              % (runledger.teardown_path(root), runledger.KILLED_WINDOW_S),
              flush=True)
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
        # MENU PROOF. `menu_proof` is the host line that showed
        # EFT.UI.MenuScreen::Show fired; `site2_seen` is whether this build can
        # produce such a line at all; `last_screen` is the last screen the host
        # named. All three are per-RUN and are cleared when the host truncates
        # the log, exactly like errdlg_armed -- a proof line from the PREVIOUS
        # boot certifying THIS boot's menu would be the worst kind of pass.
        self.menu_proof = None
        self.site2_seen = False
        self.last_screen = None
        self.seen_any = False
        self.last_progress = time.time()
        # ANY host line, heartbeats included. Distinct from `last_progress` on
        # purpose: a host that has stopped printing even its 5s heartbeat is
        # not idle, it is gone -- and that, not "nothing interesting is
        # happening", is what a stall at the destination phase looks like.
        self.last_line = None
        self.evidence = []
        self.marks = []
        # CLIENT-LOG state. `client_exceptions` counts managed exceptions the
        # client LOGGED AND SURVIVED -- a note, never a verdict (see
        # poll_client). `client_milestones` keeps the load milestones we have
        # already announced, so a raid load prints three marks and not three
        # hundred.
        self.client_exceptions = 0
        self.last_exception = None
        self.client_milestones = set()
        self._said_alive_exception = False
        # Liveness, cached and injectable (tests must be able to say "gone"
        # without killing anything).
        self.alive_probe = harness.client_alive
        self._alive = True
        self._alive_at = None
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
            self.menu_proof = None
            self.site2_seen = False
            self.last_screen = None
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

    def note_errdlg(self, line):
        """Classify ONE host line for whether the dialog catcher is armed.

        Factored out of poll_host so `--attach` can apply exactly the same
        rules to the log that is ALREADY on disk. Two copies of this would be
        two chances to disagree about what "armed" means.
        """
        if "errdlg ARMED" in line:
            self.errdlg_armed = True
            return True
        if ("catchErrorDialogs is explicitly false" in line
                or "errdlg did not arm" in line
                or ("NONE of the" in line
                    and "error-screen entry points bound" in line)):
            self.errdlg_armed = False
            return True
        return False

    def note_site2(self, line):
        """Classify ONE host line for the uihooks site-2 CAPABILITY.

        Factored out for the same reason as `note_errdlg`: the --attach
        prescan and the live tail must agree, to the character, about what
        "this build can emit a MenuScreen::Show proof" means. Two copies of
        `all(s in line for s in MENU_PROOF_SITE)` would be two chances to
        drift, and the thing they decide is the WORDING of the REACHED verdict.

        Returns True on the line that first sets it, so a caller can mark it.
        """
        if not self.site2_seen and all(s in line for s in MENU_PROOF_SITE):
            self.site2_seen = True
            return True
        return False

    def prescan_host(self, max_bytes=8 * 1024 * 1024):
        """--attach: learn the arming state from the log THIS BOOT ALREADY WROTE.

        MEASURED 2026-09-02: an `--attach` run printed `dialog catch UNKNOWN --
        the host never said whether it armed` and downgraded IDLE to
        INCONCLUSIVE (exit 6) for a client that was loading a raid perfectly
        well. The host had said it, once, at [0:00:01] of that boot -- 2 minutes
        before we attached. The supervisor starts tailing at END-OF-FILE (it has
        to; see __init__), so a one-shot line from earlier in the SAME boot is
        invisible, and "I could not look" then becomes the verdict.

        In `--attach` the host is already running, so the log on disk IS this
        boot's -- the host truncates on attach. If it truncates again under us,
        `_host_lines` clears `errdlg_armed` back to None and the live tail
        re-learns it, so a stale ARMED can never certify a later boot.

        MEASURED AGAIN 2026-09-02, the same bug in a second place: an
        `--attach --until-phase MENU` run printed `REACHED ... but UNPROVEN:
        this host build never printed a uihooks 'site 2 ... BOUND' line` for a
        client whose host log carries, at [0:00:01.032], `uihooks:  site 2
        EFT.UI.MenuScreen::Show(5-arg) @0x15387a0: BOUND (slot 7)`. That
        capability line is emitted once at bind time, so from an attach point
        minutes later it is invisible, and the verdict then downgrades itself
        by describing this build as one that predates site 2. So the site-2
        CAPABILITY is prescanned too, through `note_site2` -- the same one
        definition the live tail uses.

        Capability, unlike location, is a property of the BUILD, so reading it
        from the backlog is sound -- but only from THIS boot's backlog. The
        scan therefore restarts at the LAST `aowlspt-host-il2cpp` banner in the
        file: if an older boot's lines are still ahead of it (the host normally
        truncates, but a copied or concatenated log does not), its site-2 line
        describes a build that is not the one running now.

        Only the errdlg and site-2 lines are read out of the backlog. The menu
        PROOF itself and the screen names are NOT, deliberately: those decide a
        verdict about WHERE the client is now, and re-reading them from an
        arbitrarily old part of the log is the "proof from the previous boot"
        failure. Arming is a property of the host process, which is the same
        process either way.

        Never reads the whole file into the transcript or into memory: it
        streams, and reads at most the last `max_bytes` (the log is a measured
        token bomb, CLAUDE.md 8). Returns True/False/None -- the value learned.
        """
        # ARMED is printed at ~[0:00:01], i.e. near the TOP of the log, so this
        # reads from the top; a tail-only window would miss exactly the line it
        # came for. `max_bytes` only bounds a pathological file.
        found = None
        site2 = False
        try:
            with open(self.host_path, "r", encoding="utf-8",
                      errors="replace") as f:
                read = 0
                for line in f:
                    read += len(line)
                    if read > max_bytes:
                        break
                    # A NEW BOOT starts here: everything learned above it
                    # describes a process and a build that are gone.
                    if line.startswith(HOST_BANNER_PREFIX):
                        found = None
                        self.errdlg_armed = None
                        site2 = False
                        self.site2_seen = False
                        continue
                    if self.note_errdlg(line):
                        found = self.errdlg_armed
                    if self.note_site2(line):
                        site2 = True
        except OSError:
            return None
        if found is not None:
            self.mark("--attach: error-dialog catch read from the existing "
                      "host log: %s" % ("ARMED" if found else "NOT ARMED"))
        if site2:
            self.mark("--attach: uihooks site 2 (MenuScreen::Show) is BOUND in "
                      "this build, read from the existing host log")
        return found

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

        # 1. ARRIVAL -- and arrival needs PROOF, not a phase name.
        #
        # The settle window establishes only that the boot stopped moving. It
        # cannot establish WHERE it stopped, because `raid phase = MENU` means
        # "no GameWorld is cached" and nothing more. Measured 2026-09-02 03:20:
        # this branch returned REACHED for a client sitting on the character/
        # mode select screen. So the phase decides WHEN to answer and the
        # MenuScreen::Show event decides WHAT the answer is.
        if (at_destination and self.phase == "MENU"
                and quiet >= self.menu_settle
                and silent <= HOST_HEARTBEAT_S * 3):
            if self.menu_proof:
                return ("REACHED",
                        "raid phase = MENU has held with no other host "
                        "progress for %ds AND the host logged the "
                        "EFT.UI.MenuScreen::Show event -- the main menu really "
                        "was shown and the client is parked on it"
                        % int(quiet), ev + [self.menu_proof])
            if not self.site2_seen:
                # Old host build: no site-2 status line, so no feature could
                # ever have logged the proof. Absence of proof is not proof of
                # absence -- keep the old verdict and SAY it is unverified.
                return ("REACHED",
                        "raid phase = MENU has held with no other host "
                        "progress for %ds -- but UNPROVEN: this host build "
                        "never printed a uihooks `site 2 ... BOUND` line, so "
                        "no MenuScreen::Show proof exists to check and this "
                        "cannot tell the main menu from the character-select "
                        "screen. Treat as the pre-2026-09-02 verdict"
                        % int(quiet), ev)
            return ("PARKED-BEFORE-MENU",
                    "raid phase = MENU has held quiet for %ds, but the host "
                    "NEVER logged the EFT.UI.MenuScreen::Show event -- and "
                    "uihooks site 2 IS bound in this build, so that line would "
                    "have appeared if the main menu had been built. The phase "
                    "only means no GameWorld is cached, which is equally true "
                    "on the loading screen and the character/mode select "
                    "screen. Last screen the host named: %s"
                    % (int(quiet),
                       self.last_screen or "none -- the host named no screen "
                       "at all, so WHERE it is parked is unknown"), ev)

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

            # MENU PROOF, gathered as the lines go past. Deliberately NOT a
            # verdict of its own: the proof line arrives long before the boot
            # settles, and returning on it would re-create the first-sighting
            # bug in a new place. It only decides which answer the settle
            # window gives.
            if self.menu_proof is None:
                for sig in MENU_PROOF_LINES:
                    if sig in line:
                        self.menu_proof = line.strip()
                        self.mark("main menu PROVED shown (MenuScreen::Show)")
                        break
            self.note_site2(line)
            for sig, name in SCREEN_NAME_LINES:
                if sig in line:
                    self.last_screen = name
                    break

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
            self.note_errdlg(line)
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
    def loading_a_raid(self):
        """Is a raid entry in flight RIGHT NOW, as far as the phases say?

        True only while `--until-phase DEPLOYED` was asked for and the client
        has not reached DEPLOYED. This is the gate on rule 2 above: outside it,
        the client log does not touch the progress clock at all.
        """
        return bool(self.until_phase == "DEPLOYED"
                    and self.phase != "DEPLOYED")

    def _client_line(self, line):
        """Every raw client-log line, once. The ONLY thing moving during a load.

        Progress, not liveness: the client writes these because assets are
        actually coming up. Gated by `loading_a_raid` so it cannot become a new
        heartbeat -- see CLIENT_LOAD_PROGRESS_LINES.
        """
        if not self.loading_a_raid():
            return
        if not crashwatch.LOAD_PROGRESS_RX.search(line):
            return
        self.last_progress = time.time()
        for sig in CLIENT_LOAD_PROGRESS_LINES:
            if sig in line and sig not in self.client_milestones:
                self.client_milestones.add(sig)
                self.mark("client log: %s (the raid is loading)" % sig)
                break

    def process_gone(self, now=None):
        """Is the client process gone? Rate-limited, and injectable for tests.

        `alive_probe` shells out to `tasklist` (~100ms), and the main loop
        already polls it every 5s; asking it again for every line the client
        logs would spawn a process several times a second inside a raid. The
        cached answer is at most `ALIVE_CACHE_S` old, which is far shorter than
        anything that turns on it.
        """
        now = time.time() if now is None else now
        if (self._alive_at is None
                or now - self._alive_at >= ALIVE_CACHE_S):
            try:
                self._alive = bool(self.alive_probe())
            except Exception:
                self._alive = True       # cannot tell: never fabricate a death
            self._alive_at = now
        return not self._alive

    def exception_note(self):
        """The verdict-block NOTE for managed exceptions the client survived.

        Not a verdict. See poll_client.
        """
        if not self.client_exceptions:
            return None
        return ("client logged %d managed exception(s) that it CAUGHT and "
                "survived, last: %s" % (self.client_exceptions,
                                        self.last_exception))

    def poll_client(self):
        """The client's own logs. A logged exception is NOT a crash.

        MEASURED 2026-09-02: `run.py --attach --until-phase MENU` exited 5
        (`CRASH unhandled-exception -- NullReferenceException`) after 0.5s while
        the client was ALIVE and standing in a raid. The match was Tarkov's own
        bot AI -- `MalfunctionLayer.ShallUseNow` under
        `EFT.BotsController.UpdateByUnity` -- which the game logs on EVERY raid
        and CATCHES. The signature is real; the verdict was fabricated.

        crashwatch's classifier answers "this record looks like a managed
        exception", which is the right question for a killer watching for a
        client that is dying. It is NOT evidence that the client DIED, and this
        tool's job is a verdict about the run. So a crash signature is only ever
        a CRASH verdict when the PROCESS IS GONE (or Unity's own crash handler
        wrote a report after we started -- `crash_evidence` in main, printed for
        every gone-process verdict). While the client is alive it is counted and
        reported as a NOTE, which is the honest reading: N exceptions happened
        and the client kept running.

        The negative half matters as much: a client that logs an exception and
        then dies must still be CRASH, not DIED-with-no-cause. That is what the
        gone check preserves.
        """
        # A relaunch makes a new session dir; pick it up.
        nd = crashwatch.newest_log_dir(self.logs_root)
        if nd and nd != self.cur_dir:
            self.cur_dir = nd
            _, self.tailers = crashwatch.build_tailers(nd, from_start=True)
        hit = None
        for _suf, t in list(self.tailers.items()):
            for sig, detail, _text in t.poll(on_line=self._client_line):
                self.client_exceptions += 1
                self.last_exception = "%s -- %s" % (sig, detail)
                if hit is None:
                    hit = ("CRASH", "%s -- %s" % (sig, detail),
                           t.tail_lines(8))
        if hit is None:
            return None
        if self.process_gone():
            return hit
        if not self._said_alive_exception:
            self._said_alive_exception = True
            self.mark("client logged an exception and is STILL RUNNING (%s) -- "
                      "noted, not a verdict" % self.last_exception[:80])
        return None

    # -- IDLE -------------------------------------------------------------
    def idle_verdict(self, now, stall):
        """Quiet-and-alive: is that IDLE, or is it a client doing its job?

        Lived in `main()` as an inline `if`, which meant nothing could test it
        and the two exemptions could not be stated in one place. Returns a
        verdict tuple or None.

        The exemptions, both narrow and both falsifiable:

          * you asked to stop AT this phase -- quiet is then the SUCCESS
            condition and check_clocks owns the answer (pre-existing);
          * this phase is one where quiet is expected on the way to the phase
            you asked for: LOADING en route to DEPLOYED. `--phase-max` still
            bounds it, so a load that never finishes is still reported, as
            STALLED with a stated limit, rather than as a quiet log.

        Note what this does NOT cover, because the measured case needed it: at
        60.8s of the failing run the phase was MENU, not LOADING, and no phase
        exemption would have spared it. `_client_line` is what covers that.
        """
        if not self.seen_any or now - self.last_progress <= stall:
            return None
        if self.until_phase and self.phase == self.until_phase:
            return None
        if self.phase in QUIET_EN_ROUTE.get(self.until_phase or "", ()):
            return None
        return ("IDLE", "alive, but no host-log progress line for %ds"
                % int(stall), self.host_tail[-3:])


def looks_like_crashes_root(path):
    """(ok, why) -- is `path` plausibly Unity's Crashes directory?

    Three-state by construction (CLAUDE.md 9b): the caller turns `ok=False`
    into an INCONCLUSIVE answer, never into "no crash report". Accepts a
    directory that either

      * has held a report at some point (any `Crash_*` entry, ever -- NOT only
        ones newer than launch, since "empty right now" is normal), or
      * sits at a `...\\Temp\\Battlestate Games\\...\\Crashes` shaped path, which
        is the genuine-but-never-yet-used case.

    Everything else is a refusal, because the falsifying input is real: the
    INSTALL root `D:\\Aowlspt` was passed here, it exists, it is a directory,
    and it has never contained a crash report -- so every lookup answered "no
    crash report newer than launch" and that answer could not fail.
    """
    if not path:
        return False, "empty path"
    if not os.path.exists(path):
        return False, "does not exist"
    if not os.path.isdir(path):
        return False, "is not a directory"
    try:
        entries = os.listdir(path)
    except OSError as e:
        return False, "could not be listed (%s)" % e
    if any(n.startswith("Crash_") for n in entries):
        return True, "contains Crash_* entries"
    norm = os.path.normpath(os.path.abspath(path)).replace("/", "\\").lower()
    if "\\temp\\battlestate games\\" in norm and norm.endswith("\\crashes"):
        return True, "is a Battlestate Games Crashes path (currently empty)"
    return False, ("has no Crash_* entry and is not a "
                   "Temp\\Battlestate Games\\...\\Crashes path -- this looks "
                   "like the INSTALL root, not Unity's Crashes root")


def crash_evidence(started, crashes_root=None, symbolize=True):
    """What Unity's OWN crash handler recorded about this death, if anything.

    `crashes_root` is UNITY'S CRASHES DIRECTORY
    (%LOCALAPPDATA%\\Temp\\Battlestate Games\\EscapeFromTarkov\\Crashes), NOT
    the install root. It used to be called `root`, and `D:\\Aowlspt` was passed
    for it: a directory that has never held a report, so the lookup answered
    "no crash report newer than launch" forever. That is refused now -- the
    result comes back source="inconclusive" and says which directory it was
    handed and why it does not look like a Crashes root.

    Returns a dict: `lines` is the block to print, and the rest is the same
    finding in machine-readable form. `folder` None means NO report newer than
    launch exists -- which is itself a fact, and the reason this never returns
    None: "the client was torn down or exited" and "the client died in native
    code" are different causes and must not both print as silence.

    MEASURED 2026-09-02: four deaths were chased for an hour off the DIED line
    alone ("the client process was up and is gone") while a full report with a
    named module sat under %LOCALAPPDATA%\\Temp\\Battlestate Games\\...\\Crashes
    for each one. crashwatch owns the parsing; this only prints it.
    """
    if crashes_root is not None:
        ok, why = looks_like_crashes_root(crashes_root)
        if not ok:
            return {"folder": None, "path": None, "module": None,
                    "source": "inconclusive", "age_s": None, "modules": [],
                    "modlines": [],
                    "lines": ["crash report lookup NOT PERFORMED -- %s %s."
                              % (crashes_root, why),
                              "This is INCONCLUSIVE, NOT 'no crash report': "
                              "nothing was searched. Pass Unity's Crashes "
                              "root (%%LOCALAPPDATA%%\\Temp\\Battlestate "
                              "Games\\EscapeFromTarkov\\Crashes), not the "
                              "install root."]}
    kw = {} if crashes_root is None else {"root": crashes_root}
    try:
        rep = crashwatch.newest_crash_report(since=started, **kw)
    except Exception as e:                       # never let this hide a verdict
        return {"folder": None, "module": None, "source": "error",
                "age_s": None, "modules": [],
                "lines": ["crash report lookup FAILED (%s: %s) -- this is "
                          "INCONCLUSIVE, not 'no crash report'"
                          % (type(e).__name__, e)]}
    lines = crashwatch.format_crash_report(rep, start_epoch=started,
                                           symbolize=symbolize)
    if rep is None:
        return {"folder": None, "path": None, "module": None, "source": "none",
                "age_s": None, "modules": [], "modlines": [], "lines": lines}
    mod, source, _frame, _note = rep.attribute()
    return {"folder": os.path.basename(rep.folder), "path": rep.folder,
            "module": mod,
            "source": source, "age_s": (None if rep.age_after(started) is None
                                        else round(rep.age_after(started), 1)),
            "modules": sorted(rep.modules), "modlines": list(rep.modlines),
            "lines": lines}


# ---------------------------------------------------------------------------
# DIED FORENSICS -- automatic, because nobody reads them otherwise
#
# MEASURED, the night of 2026-09-01: every "clean" client death had a Unity
# crash report AND a minidump naming the faulting argument in registers, and
# ~2.5 hours went into theories before anyone opened either. The tools existed
# the whole time (`crashwatch.py last`, `dmpread.py`, `il2cpp_resolve.py
# disasm`); what did not exist was anything that ran them WITHOUT being asked.
#
# So a DIED verdict now costs four tool calls it never has to be told to make,
# and the rule is absolute: a DIED line NEVER appears without this block or
# without an explicit `forensics unavailable because ...`. A skipped step must
# read as skipped -- CLAUDE.md 9b, "I could not look" is not a pass -- so every
# refusal any of these tools emits is printed VERBATIM and nothing is swallowed.
# ---------------------------------------------------------------------------

DMPREAD_PY = os.path.join(HERE, "dmpread.py")
RESOLVE_PY = os.path.join(HERE, "il2cpp_resolve.py")

FORENSICS_HEADER = "DIED FORENSICS (run automatically -- read these first)"

# `thread 12  ACCESS_VIOLATION (0xc0000005)  at 0x7ffb2c0be110`
FAULT_AT_RX = re.compile(r"\bat 0x([0-9A-Fa-f]+)")

# How much of a tool's own output is reproduced. These are short by
# construction (dmpread prints a fault line plus 5 register rows); the cap only
# bounds a pathological answer, and it SAYS when it truncates.
TOOL_LINE_CAP = 40


def _run_tool(cmd, timeout=180):
    """(rc, text). Never raises -- a tool that cannot be run is a REFUSAL to
    print, not an exception that hides the whole block."""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except Exception as e:
        return 127, ("could not run %s (%s: %s)"
                     % (" ".join(cmd), type(e).__name__, e))
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def _tool_lines(text, cap=TOOL_LINE_CAP):
    ls = [l.rstrip() for l in (text or "").splitlines() if l.strip()]
    if len(ls) > cap:
        ls = ls[:cap] + ["... %d more line(s) from this tool, not shown"
                         % (len(ls) - cap)]
    return ls or ["(the tool printed nothing at all)"]


def module_for_va(modlines, va):
    """(name, base, size) of the loaded module containing `va`, or None.

    The bases come from the crash report's own module list, because
    GameAssembly.dll is ASLR-relocated and 0x180000000 is only its PREFERRED
    base -- hardcoding that is how an RVA ends up 200MB wrong.
    """
    try:
        import il2cpp_resolve as ir
    except Exception:
        return None
    try:
        bases = ir.parse_module_bases(list(modlines or []))
    except Exception:
        return None
    for name, (base, size) in sorted(bases.items()):
        if name.endswith(":conflict"):
            continue
        if base <= va < base + size:
            return (name, base, size)
    return None


def disasm_excerpt(text):
    """The four things worth reading out of `il2cpp_resolve.py disasm`.

    owner / args / CAVEAT lines, then the `>>` line (the faulting instruction)
    and the three after it. If there is no `>>` line the excerpt SAYS so -- a
    disasm whose window never covered the address proves nothing and must not
    be presented as if it had.
    """
    lines = [l.rstrip() for l in (text or "").splitlines()]
    head = [l for l in lines
            if l.startswith(("disasm ", "named ", "owner ", "args ",
                             "CAVEAT ", "REFUSED", "INCONCLUSIVE", "NOTE "))]
    hit = None
    for i, l in enumerate(lines):
        if l.startswith(">>"):
            hit = i
            break
    if hit is None:
        return head + ["no `>>` line: this disassembly never reached the "
                       "faulting address, so it does NOT show the faulting "
                       "instruction"]
    return head + lines[hit:hit + 4]


def died_forensics(started, crash=None, runner=None, resolve_paths=None,
                   crash_root=None, symbolize=True, wer=True, ps_runner=None,
                   cdb_runner=None, dumps_dir=None, cdb=None):
    """(lines, kind) -- the block printed before any DIED exit line.

    Six questions, in the order that answers a death fastest:
      1. did Unity write a crash report newer than this launch?
      2. what do the crash-site frames say (crashwatch, symbolized)?
      3. what were the registers at the faulting instruction (dmpread)?
      4. what IS that instruction (il2cpp_resolve disasm, owner + args + `>>`)?
      5. what does the WINDOWS event log say -- because a fail-fast
         (0xc0000409, abort()/__fastfail out of a mod) writes NO Crash_* folder
         at all, and reading that absence as a teardown was wrong on
         2026-09-02 13:18;
      6. is there a WER dump, and what does cdb's `k` name in it? That column
         is what prints `admin!mi_assert_fail <- ... <- admin!onUpdate`.

    `kind` is crashwatch's death classification (NATIVE-CRASH / FAIL-FAST /
    OS-DUMP / EXIT-OR-TEARDOWN / INCONCLUSIVE). Every question can answer "I
    could not look", and each says so in its own words. The runners are
    injectable so tools/test_supervise.py can drive the whole path, including
    the branches that need a real minidump, a real event log and cdb.
    """
    runner = runner or _run_tool
    out = [FORENSICS_HEADER]
    crash, native, dmp_lines = _unity_forensics(
        started, crash, runner, resolve_paths, crash_root, symbolize)
    out += native
    if not wer:
        out.append("4. Windows     NOT LOOKED AT: the event-log / CrashDumps / "
                   "cdb pass was disabled for this call, so NOTHING here may "
                   "be read as 'not a crash'.")
        return out, crashwatch.DEATH_UNKNOWN
    out.append("4. Windows     the OS's own record -- a fail-fast (0xc0000409) "
               "writes NO Crash_* folder, so absence of one is not a teardown")
    try:
        wlines, kind, _detail = crashwatch.format_wer(
            started, ps_runner=ps_runner, cdb_runner=cdb_runner,
            dumps_dir=dumps_dir, cdb=cdb, dmpread_lines=dmp_lines,
            crash_folder=crash.get("path"))
    except Exception as e:
        out.append("   the Windows pass RAISED (%s: %s) -- INCONCLUSIVE, not "
                   "'no crash'" % (type(e).__name__, e))
        return out, crashwatch.DEATH_UNKNOWN
    out += ["   " + l for l in wlines]
    return out, kind


def _unity_forensics(started, crash, runner, resolve_paths, crash_root,
                     symbolize):
    """(crash, lines, dmpread_lines) -- steps 1-4, Unity's own crash report.

    Split out so that every "I could not look" branch below can return early
    WITHOUT skipping the Windows pass that follows it. That skip is precisely
    the bug of 2026-09-02 13:18: no Crash_* folder ended the enquiry, and the
    death was reported as a teardown when the event log held a fail-fast.
    """
    out = []
    dmp_lines = []
    if crash is None:
        # NOTE the argument name: `crash_root` is Unity's Crashes directory
        # (%LOCALAPPDATA%\Temp\Battlestate Games\...), NOT the install root.
        # Passing D:\Aowlspt here would search a directory that has never
        # contained a crash report and answer "no crash report" every time --
        # a check that cannot fail.
        crash = crash_evidence(started, crash_root, symbolize=symbolize)

    # 1 + 2 -- the crash report and its frames. crashwatch owns both; when there
    # is none it says so, and step 4 below is what decides whether that absence
    # means anything.
    out.append("1. crash report")
    out += ["   " + l for l in crash["lines"]]

    folder = crash.get("path")
    if not folder and crash.get("source") in ("inconclusive", "error"):
        # Distinct from the line below on purpose: "we searched and found
        # nothing" and "we never searched" must not print the same sentence.
        out.append("2. minidump    NOT LOOKED AT: the crash-report lookup was "
                   "INCONCLUSIVE (see step 1) -- no directory was searched, so "
                   "this says NOTHING about whether a report exists.")
        out.append("3. disasm      NOT LOOKED AT: without a dump there is no "
                   "faulting address to decode.")
    elif not folder:
        out.append("2. minidump    NOT LOOKED AT: no Unity crash report newer "
                   "than launch, so there is no crash.dmp to read. This is NOT "
                   "yet a teardown -- see step 4.")
        out.append("3. disasm      NOT LOOKED AT: without a dump there is no "
                   "faulting address to decode.")
        return crash, out, dmp_lines

    dmp = os.path.join(folder, "crash.dmp")
    out.append("2. minidump    %s" % dmp)
    rc, text = runner([sys.executable, DMPREAD_PY, dmp])
    dmp_lines = _tool_lines(text)
    out += ["   " + l for l in dmp_lines]
    if rc != 0:
        out.append("   (dmpread exited %d -- the text above is its refusal, "
                   "printed verbatim)" % rc)

    m = FAULT_AT_RX.search(text or "")
    if not m:
        out.append("3. disasm      NOT LOOKED AT: dmpread named no faulting "
                   "address, so there is nothing to decode. This is "
                   "INCONCLUSIVE, not 'the instruction is fine'.")
        return crash, out, dmp_lines
    va = int(m.group(1), 16)

    hit = module_for_va(crash.get("modlines"), va)
    if hit is None:
        out.append("3. disasm      NOT LOOKED AT: 0x%x is in NO module the "
                   "crash report lists a base for, so it cannot be rebased to "
                   "an RVA. GameAssembly.dll is ASLR-relocated; guessing "
                   "0x180000000 would be a confidently wrong answer." % va)
        return crash, out, dmp_lines
    name, base, _size = hit
    if name != "gameassembly":
        out.append("3. disasm      NOT DECODED: the fault is at 0x%x, inside "
                   "%s (base 0x%x), not GameAssembly.dll. il2cpp_resolve only "
                   "decodes GameAssembly; for %s read the crash-site frames "
                   "above and the cdb stack in step 4." % (va, name, base, name))
        return crash, out, dmp_lines
    gameasm, metadec = (resolve_paths if resolve_paths
                        else _resolve_paths())
    missing = [p for p in (gameasm, metadec) if not p or not os.path.exists(p)]
    if missing:
        out.append("3. disasm      NOT LOOKED AT: %s absent, so the resolver "
                   "cannot run. (.cache/global-metadata.dec.dat is produced by "
                   "tools/metablob.py and is NOT shared between worktrees.)"
                   % ", ".join(str(p) for p in missing))
        return crash, out, dmp_lines
    rva = va - base
    out.append("3. disasm      RVA 0x%x (0x%x - %s base 0x%x)"
               % (rva, va, name, base))
    rc, text = runner([sys.executable, RESOLVE_PY, gameasm, metadec, "disasm",
                       hex(va), "--base", hex(base)])
    if rc != 0:
        out += ["   " + l for l in _tool_lines(text)]
        out.append("   (il2cpp_resolve exited %d -- the text above is its "
                   "refusal, printed verbatim)" % rc)
        return crash, out, dmp_lines
    out += ["   " + l for l in disasm_excerpt(text)]
    return crash, out, dmp_lines


def _resolve_paths():
    try:
        import il2cpp_resolve as ir
        return ir.default_paths()
    except Exception:
        return (None, None)


def classify_death(verdict, why, evidence, when, kind, root=None,
                   not_before=None, path=None):
    """(verdict, why, evidence, note) -- was this death OUR doing?

    Lives outside `main` so it can be driven from a test with a synthetic
    ledger; inline, the one decision that turns a DIED into a KILLED-BY-TOOL
    could not be exercised without killing a real client.

    TWO conditions, and the second is what keeps this from becoming a verdict
    that launders real crashes:

      * a teardown entry within KILLED_WINDOW_S of the death, recorded AFTER
        this client was launched (`not_before`);
      * AND the OS recording no crash. A fail-fast writes no Crash_* folder, so
        a stop that happened to land beside one would otherwise bury it -- the
        exact 2026-09-02 13:18 failure, in reverse.
    """
    if not needs_forensics(verdict):
        return verdict, why, evidence, None
    killer = runledger.near(when, root=root, not_before=not_before, path=path)
    if not killer:
        return verdict, why, evidence, None
    if kind not in (crashwatch.DEATH_QUIET, crashwatch.DEATH_UNKNOWN):
        return verdict, why, evidence, (
            "NOTE: %s recorded a teardown at %s, within %ds of this death -- "
            "but the OS recorded a real crash (%s), so this is NOT reported as "
            "KILLED-BY-TOOL."
            % (killer.get("tool"), killer.get("when_local"),
               runledger.KILLED_WINDOW_S, kind))
    verdict = ("KILLED-BY-TOOL %s %s"
               % (killer.get("tool") or "?",
                  killer.get("reason") or "(no reason recorded)"))
    why = ("this was NOT a crash: %s recorded a teardown at %s, within %ds of "
           "the client disappearing (pid %s), and the OS recorded no crash "
           "(%s). The original reading was: %s"
           % (killer.get("tool"), killer.get("when_local"),
              runledger.KILLED_WINDOW_S, killer.get("pid"), kind, why))
    return (verdict, why,
            list(evidence) + [jsonmod.dumps(killer, separators=(",", ":"))],
            None)


def needs_forensics(v):
    """Which verdicts may NEVER be printed bare. Exactly the deaths.

    Stated as a predicate rather than as an `if` inside the printer so a test
    can assert the rule itself, and so a future verdict that means "it died"
    has one place to be added.
    """
    return (v or "").split(" ", 1)[0] == "DIED"


FORENSICS_MISSING = ("forensics unavailable because they were never collected "
                     "for this DIED verdict -- this is a BUG in run.py, not a "
                     "statement that the client died cleanly")


def verdict_block(v, why, evidence, elapsed, armed, logs, as_json,
                  teardown=False, crash=None, notes=(), forensics=None):
    notes = [n for n in (notes or ()) if n]
    # THE RULE, enforced HERE and not at the call site: a DIED line never
    # appears without the forensics block or without an explicit sentence
    # saying why there is none. A caller that forgets gets the sentence, which
    # is a visible defect; silence would be an invisible one.
    if needs_forensics(v) and not forensics:
        forensics = ([FORENSICS_HEADER]
                     + ["   " + l for l in (crash or {}).get("lines", [])]
                     + ["   " + FORENSICS_MISSING])
    if as_json:
        print(jsonmod.dumps({
            "verdict": v, "why": why, "elapsed_s": round(elapsed, 1),
            "errdlg_armed": armed, "evidence": evidence[-6:], "logs": logs,
            "teardown": bool(teardown), "notes": notes,
            "forensics": list(forensics or []),
            "crash": (None if crash is None
                      else {k: crash[k] for k in
                            ("folder", "module", "source", "age_s", "modules")}),
        }, separators=(",", ":")))
        if forensics:
            # --json is one machine-readable line; the human-readable block
            # goes to stderr rather than being dropped, because dropping it is
            # exactly the failure this change exists to end.
            for line in forensics:
                sys.stderr.write(line + "\n")
        elif crash is not None:
            for line in crash["lines"]:
                sys.stderr.write(line + "\n")
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
    for n in notes:
        print(" %-12s  %s" % ("note", n))
    for line in evidence[-6:]:
        print("   | " + line[:200])
    if logs:
        print(" %-12s  %s" % ("logs", "  ".join(logs)))
    if forensics:
        # The forensics block ALREADY contains the crash-report lines (it is
        # built around them), so printing `crash` as well would say everything
        # twice.
        print("")
        for line in forensics:
            print(" " + line)
    elif crash is not None:
        print("")
        for line in crash["lines"]:
            print(" " + line)
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
                        "exists; the first sighting is never the answer. The "
                        "window decides WHEN to answer; a host-side "
                        "MenuScreen::Show line decides whether the answer is "
                        "REACHED or PARKED-BEFORE-MENU.")
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
    p.add_argument("--teardown", action="store_true",
                   help="STOP the client, backend and launcher once the "
                        "verdict lands. Off by default since 2026-09-02: the "
                        "old default killed the client at its verdict and the "
                        "result was mistaken for a crash three times, ~20 "
                        "minutes each. Every stop is recorded in "
                        "aowlspt-teardown.jsonl.")
    p.add_argument("--keep", action="store_true",
                   help="ACCEPTED AND IGNORED -- keeping the client is now the "
                        "default. Kept so existing callers and recipes do not "
                        "break; pass --teardown for the old behaviour.")
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
    # The floor for "did a tool kill THIS client". None with --attach, on
    # purpose: there the client predates us, so a teardown from before we
    # attached can genuinely be the one that killed it. When WE launched it,
    # nothing before the launch can have.
    launched_at = None
    if args.keep and not args.teardown:
        print("(--keep is now the default and does nothing; pass --teardown to "
              "stop the client at the verdict)", flush=True)
    if args.teardown:
        print("(--teardown: the client WILL be stopped when the verdict lands, "
              "and that stop will be recorded in %s)"
              % runledger.teardown_path(args.root), flush=True)

    # THE BOOT LEDGER. Printed before anything is launched, because its whole
    # job is to tell you -- in advance -- whether a crash on this boot will be
    # attributable at all. Last night ~7 commits landed per boot, so every
    # crash needed a bisect and two one-sample bisects gave wrong answers.
    bfacts = runledger.boot_facts(args.root)
    for line in runledger.boot_line(bfacts):
        print(line, flush=True)

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
        # Recorded like any other stop -- but see `not_before` below: a stop
        # that happened BEFORE this client existed can never explain its death,
        # and the ledger lookup is floored at the launch instant for exactly
        # that reason.
        runledger.record("run.py", "pre-launch stop: the host DLL is locked "
                                   "while the game runs" +
                         ("  (--dry-teardown: nothing was stopped)"
                          if args.dry_teardown else ""), root=args.root)
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
        # ARCHIVE THE PREVIOUS BOOT'S HOST AND BACKEND LOGS FIRST. The host
        # rewrites aowlspt-host.log on every start, and the client's own
        # D:\Aowlspt\Logs\<ts>\ never holds it. MEASURED 2026-09-05: a hung
        # boot's host log -- the only record of what the host did before the
        # freeze -- was overwritten by the two bisect boots that followed, so
        # the graft's timing in the hung boot is unknowable. One copy per
        # launch, named by the log's own mtime, never blocks the launch.
        archive_previous_logs(args.root)
        # THE CLIENT MUST NOT INHERIT OUR STDIO. MEASURED 2026-09-05 15:20:
        # `python tools/run.py --keep --until-phase MENU --timeout 300` run
        # through a PowerShell pipeline (`| Select-Object -Last 8`) printed
        # nothing for 16 minutes and the pipeline never ended, although the
        # host log showed MenuScreen::Show at 41 s and run.py itself had
        # exited: the launcher, and the game it starts, had inherited the
        # pipe's write handle, so the pipeline waited on the GAME. The same
        # inheritance is why stopping the shell task that launched a boot has
        # been measured to take the client down with it. Detached, with its
        # own process group and no handles of ours, the client outlives any
        # shell, and this script's verdict reaches its caller when it lands.
        flags = 0
        if os.name == "nt":
            flags = (subprocess.CREATE_NEW_PROCESS_GROUP |
                     getattr(subprocess, "DETACHED_PROCESS", 0x00000008))
        subprocess.Popen(cmd, cwd=install_dir(args.root),
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, close_fds=True,
                         creationflags=flags)
        launched_at = time.time()
        runledger.record_boot(args.root, facts=bfacts, when=launched_at)

    sup = Supervisor(args.root, args.until, args.stall, quiet,
                     phase_max=args.phase_max,
                     until_phase=args.until_phase,
                     menu_settle=args.menu_settle)
    state["sup"] = sup   # the signal handler reports from the live object
    if args.attach:
        # The host has been running for minutes; its one-shot `errdlg ARMED`
        # line is already on disk and will never be printed again. Without this
        # an --attach run can only ever answer UNKNOWN and downgrade IDLE to
        # INCONCLUSIVE -- measured 2026-09-02. See Supervisor.prescan_host.
        sup.prescan_host()
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
        # QUIET-AND-ALIVE. The rule and its exemptions live in the Supervisor
        # (`idle_verdict`) so that they are testable and stated once; inline
        # here, they were neither.
        idle = sup.idle_verdict(now, args.stall)
        if idle:
            verdict, why, evidence = idle
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
    # PARKED-BEFORE-MENU is included on purpose: the client is alive, quiet and
    # sitting on a real screen -- it is simply not the screen that was asked
    # for. That is exactly the case where an inspector batch is worth running,
    # because it can say which screen it IS.
    if args.inspect and verdict in ("REACHED", "IDLE", "PARKED-BEFORE-MENU"):
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
    # If the process is gone -- whatever the verdict says -- Unity may have
    # written a crash report, and reading it is the difference between "it is
    # gone" and "it faulted in sain::toJson". Asked for every gone-process
    # verdict, not just DIED: a TIMEOUT or POPUP run whose client vanished
    # under it has exactly the same evidence available. Checked BEFORE
    # teardown, so a teardown we perform cannot be mistaken for the death.
    crash = None
    if needs_forensics(verdict) or not harness.client_alive():
        crash = crash_evidence(started)

    # THE FORENSICS, collected FIRST -- because the OS's own record is what
    # decides whether a teardown entry beside the death is the explanation or a
    # coincidence. Doing it the other way round would let a stop that happened
    # to land within 10s of a real fail-fast bury the crash.
    forensics = None
    kind = crashwatch.DEATH_UNKNOWN
    if needs_forensics(verdict):
        try:
            forensics, kind = died_forensics(started, crash=crash)
        except Exception as e:
            forensics = [FORENSICS_HEADER,
                         "   forensics unavailable because collecting them "
                         "RAISED (%s: %s). That is a tool failure, not "
                         "evidence about the client."
                         % (type(e).__name__, e)]

    # DID A TOOL KILL IT? Only when nothing in the OS's record says otherwise.
    verdict, why, evidence, extra = classify_death(
        verdict, why, evidence, time.time(), kind, root=args.root,
        not_before=launched_at)
    if extra:
        forensics = (forensics or []) + [extra]

    tearing = bool(args.teardown) and not args.attach
    verdict_block(verdict, why, evidence, time.time() - started,
                  sup.errdlg_armed, logs, args.json, teardown=tearing,
                  crash=crash, notes=[sup.exception_note()],
                  forensics=forensics)

    if tearing:
        do_teardown(args.root, dry=args.dry_teardown)
    return exit_code(verdict)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
