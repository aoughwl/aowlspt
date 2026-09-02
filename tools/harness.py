#!/usr/bin/env python3
"""Launch the client, wait for the log to reach a state, capture it, shut down.

Most of the questions we ask the client are answered entirely by lines in
`aowlspt-host.log`. Those questions were costing a human ninety seconds of
staring at a loading screen each. They should cost nobody anything.

    python tools/harness.py run
    python tools/harness.py run --until "host running"
    python tools/harness.py run --until "settings pages:" --timeout 240
    python tools/harness.py run --profile <id> --keep
    python tools/harness.py watch --until "debugui:"     # game already running
    python tools/harness.py run --offscreen --profile <id>   # off your screen

`--offscreen` keeps the client off every monitor for the whole run and says
PARKED / NOT PARKED / INCONCLUSIVE at the end, re-checked against the finished
state rather than against the move it made minutes earlier. It is NOT a headless
mode and never claims to be -- the GPU renders normally. See docs/HEADLESS.md.

`run` starts `aowlspt-launch.exe --no-logs` (which starts the backend, starts
the client suspended, injects the host and resumes it), watches the host log as
it is written, stops when the wanted state is reached, saves a copy of both
logs, prints the summary, and kills what it started.

## The idle-vs-hung problem, and how readiness is decided here

The game takes over a minute to reach profile-select and then **waits forever
for a human**. An idle game and a hung game look identical from outside, so a
plain timeout cannot tell them apart: it either fires early on a slow-but-fine
boot, or it waits out a real hang for the full duration.

So readiness is never a timeout alone. Three things are tracked:

  * **the sentinel** -- the literal from `--until`. Reached: done, exit 0.
  * **progress** -- any new byte in the log resets a stall clock. The host
    writes unbuffered, one open/write/close per line, so silence in the log is
    real silence, not buffering.
  * **the stall clock** (`--stall`, default 45s). No new log line for that long
    while the client process is still alive means the client is *sitting*
    there. That is reported as `IDLE`, distinctly from `TIMEOUT`, because it is
    usually the correct and expected end state: the boot finished and the game
    is waiting at profile-select for a person who is not coming.

`--timeout` (default 300s) remains as a backstop only.

A fourth outcome is checked before any of them: if the client process exits,
that is reported immediately rather than waited out.

Exit codes: 0 sentinel reached, 1 the client died or a fault was logged,
2 timed out, 3 went idle without reaching the sentinel, 4 the client raised an
IN-GAME ERROR DIALOG.

4 is deliberately distinct from 3. A dialog and an idle client look identical
from outside -- alive process, quiet log -- and conflating them is what let an
unattended run sit on a broken client for its whole timeout. The host reports
the difference (`catchErrorDialogs`, on by default) and this believes it.
"""

import argparse
import os
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
DEFAULT_ROOT = r"D:\Aowlspt"

sys.path.insert(0, HERE)
import hostlog  # noqa: E402  -- reuse the parser, do not write a second one
import offscreen  # noqa: E402  -- one window classifier, not two


def park_offscreen(deadline_s, first):
    """Move the client's window off every monitor, once it HAS a window.

    Called from `run --offscreen`. Three outcomes and it says which:

      PARKED       the window verifiably intersects no monitor
      NOT PARKED   there was a window and it is still visible
      INCONCLUSIVE no window appeared inside the deadline

    The deadline matters and is not a formality: the client takes over a
    minute to put its render window up, so a check at 20s finds nothing and
    "no window yet" must never be reported as "parked". This polls instead of
    sleeping a fixed guess.
    """
    offscreen._dpi_aware()
    ns = argparse.Namespace(exe=offscreen.CLIENT_EXE, first=first)
    end = time.time() + deadline_s
    hwnd = None
    while time.time() < end:
        hwnd, err = offscreen._one_client_window(ns)
        if hwnd:
            break
        time.sleep(2.0)
    if not hwnd:
        return "INCONCLUSIVE", ("no client window inside %ds -- %s"
                                % (deadline_s, err[1] if err else "unknown"))
    verdict, state, d, why = offscreen.park(hwnd, offscreen.monitors())
    if verdict == offscreen.PASS:
        return "PARKED", ("%s; rect=%s intersects 0 of %d monitor(s)"
                          % (why, d["rect"], len(d["monitors"])))
    return "NOT PARKED", ("the window is %s (rect=%s, %d visible px). If the "
                          "client is in exclusive fullscreen it cannot be "
                          "moved -- add --low-render so it launches windowed."
                          % (state, d.get("rect"), d.get("visible_pixels", -1)))


def install_dir(root):
    return os.path.join(root, "aowlspt")


def hostlog_path(root):
    return os.path.join(install_dir(root), "aowlspt-host.log")


def backendlog_path(root):
    return os.path.join(install_dir(root), "aowlspt-backend.log")


def client_alive(exe="EscapeFromTarkov.exe"):
    try:
        out = subprocess.run(
            ["tasklist", "/FI", "IMAGENAME eq %s" % exe, "/NH"],
            capture_output=True, text=True, timeout=15).stdout
    except Exception:
        return True  # can't tell: assume alive rather than end the run early
    return exe.lower() in out.lower()


def watch(root, until, timeout, stall, quiet, started_at):
    """Follow the host log until the sentinel, a stall, a death or a timeout."""
    p = hostlog_path(root)
    pos = 0
    seen_any = False
    last_progress = time.time()
    deadline = started_at + timeout
    last_alive_check = 0.0
    alive = True

    while True:
        now = time.time()
        try:
            size = os.path.getsize(p)
        except OSError:
            size = -1

        if size >= 0:
            if size < pos:
                # Truncation means the host attached and started a fresh run.
                pos = 0
                if not quiet:
                    print("---- host attached, log restarted ----")
            if size > pos:
                with open(p, "r", encoding="utf-8", errors="replace") as f:
                    f.seek(pos)
                    chunk = f.read()
                    pos = f.tell()
                seen_any = True
                last_progress = now
                for line in chunk.splitlines():
                    if not quiet:
                        print(line)
                    # AN ERROR DIALOG IS NOT IDLE. Checked BEFORE the sentinel,
                    # because a run that puts a modal error window on screen has
                    # already failed even if some later line happens to contain
                    # the literal being waited for.
                    #
                    # Without this the client raises a dialog, stops making
                    # progress, and the stall clock reports IDLE -- which reads
                    # as "the boot finished and the game is waiting for a
                    # person", the normal and expected end state. That is how an
                    # unattended run sits on a dead client for its whole
                    # timeout. The two states are indistinguishable from the
                    # outside, so the host says which it is (`errdlg`, on by
                    # default) and this is where that gets believed.
                    #
                    # The host's own once-per-session suppression notice carries
                    # header="<suppressed>" and is not itself a dialog.
                    if ("ERRORDIALOG kind=" in line
                            and 'header="<suppressed>"' not in line):
                        return "ERRORDIALOG", line.strip()
                    if until and until in line:
                        return "REACHED", line

        if now - last_alive_check > 5:
            last_alive_check = now
            alive = client_alive()
            if not alive and seen_any:
                return "DIED", "the client process is gone"
            if not alive and now - started_at > 60:
                return "DIED", "the client never appeared"

        if seen_any and now - last_progress > stall:
            return "IDLE", ("no new log line for %ds" % stall)
        if now > deadline:
            return "TIMEOUT", ("%ds elapsed" % timeout)
        time.sleep(0.3)


def capture(root, outdir):
    os.makedirs(outdir, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    saved = []
    for src in (hostlog_path(root), backendlog_path(root)):
        if os.path.isfile(src):
            dst = os.path.join(outdir, "%s-%s" % (stamp, os.path.basename(src)))
            shutil.copy2(src, dst)
            saved.append(dst)
    return saved


def cmd_run(args):
    root = args.root
    launcher = os.path.join(install_dir(root), "aowlspt-launch.exe")
    if not os.path.isfile(launcher):
        sys.exit("no launcher at %s" % launcher)

    cmd = [launcher, "--root", root, "--no-logs"]
    if args.profile:
        cmd += ["--profile", args.profile]
    else:
        # Without a profile the client stops at profile-select and waits for a
        # human. That is a legitimate mode -- plenty of questions are answered
        # by the boot log alone -- but say so, because the run will end in IDLE
        # rather than in the sentinel unless the sentinel is a boot line.
        print("note: no --profile, so the client will stop at profile-select "
              "and wait. Expect IDLE unless --until names a boot line.")
    if args.offscreen and not args.low_render:
        # A borderless-fullscreen Unity window at the primary origin is the
        # observed default here (measured 2026-08-31: rect (0,0)-(3840,2160)),
        # and exclusive fullscreen cannot be moved off its display at all. So
        # --offscreen implies --low-render rather than parking something that
        # will bounce back and reporting success.
        print("note: --offscreen implies --low-render (a fullscreen window "
              "cannot be parked). Pass --low-render explicitly to silence this.")
        args.low_render = True
    if args.low_render:
        cmd += ["--low-render", "--render-size", args.render_size]
    if args.args:
        cmd += ["--args", args.args]
    # Raw pass-through for launcher flags this harness does not model yet
    # (e.g. `--modbuild PATH`, `--no-mod-build`, `--rebuild-mods`, added to
    # aowllaunch.nim 2026-09-01). Kept raw on purpose: modelling every
    # launcher flag here is how a harness drifts behind the thing it drives.
    for extra in (getattr(args, "launcher_arg", None) or []):
        cmd += extra.split(" ", 1) if " " in extra else [extra]

    started = time.time()
    print("$ %s" % " ".join(cmd))
    proc = subprocess.Popen(cmd, cwd=install_dir(root))

    park_state = park_why = None
    if args.offscreen:
        park_state, park_why = park_offscreen(args.park_deadline, args.first)
        print("---- offscreen: %s -- %s ----" % (park_state, park_why))

    try:
        state, why = watch(root, args.until, args.timeout, args.stall,
                           args.quiet, started)
    except KeyboardInterrupt:
        state, why = "INTERRUPTED", "ctrl-c"

    took = time.time() - started
    print("\n==== %s after %.0fs: %s" % (state, took, why))

    if args.offscreen:
        # RE-CHECK AT THE END. The move happened early; the client changes its
        # own resolution and window mode several times during boot and can put
        # itself back on a monitor. Asserting the state we WROTE minutes ago is
        # exactly the check that cannot fail. Assert the finished state.
        offscreen._dpi_aware()
        ns = argparse.Namespace(exe=offscreen.CLIENT_EXE, first=args.first)
        hwnd, err = offscreen._one_client_window(ns)
        if not hwnd:
            park_state, park_why = "INCONCLUSIVE", (
                "no client window at the end of the run (%s), so I cannot say "
                "whether anything was on your screen" % (err[1] if err else "?"))
        else:
            v, s, d = offscreen.classify(hwnd)
            if v == offscreen.PASS:
                park_state = "PARKED"
                park_why = ("still off every monitor at the end: rect=%s"
                            % (d["rect"],))
            else:
                park_state = "NOT PARKED"
                park_why = ("the window is %s at the END of the run (%d "
                            "visible px) -- it drifted back onto a display"
                            % (s, d.get("visible_pixels", -1)))
        print("==== offscreen (final): %s -- %s" % (park_state, park_why))
        if park_state != "PARKED" and state == "REACHED":
            # Do not report a clean 0. The run may have reached its sentinel,
            # but the thing --offscreen promised did not happen.
            print("     the sentinel was reached but the client was NOT kept "
                  "off your screen. Reporting 3 (idle/incomplete), not 0.")
            state = "IDLE"

    saved = capture(root, args.out)
    for s in saved:
        print("captured %s" % s)

    if not args.keep:
        # The launcher kills the backend it started when it exits; the client
        # it deliberately never kills, so that is ours to do.
        # Recorded BEFORE the kill, so run.py can report a death here as
        # KILLED-BY-TOOL instead of as a crash. See tools/runledger.py; a
        # silently stopped client is indistinguishable from a crashed one.
        try:
            sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
            import runledger as _rl
            _rl.record("harness.py",
                       "harness run finished without --keep: stopping the "
                       "client and the backend", root=root)
        except Exception:
            pass
        try:
            proc.terminate()
        except Exception:
            pass
        subprocess.run(["taskkill", "/F", "/IM", "EscapeFromTarkov.exe"],
                       capture_output=True)
        subprocess.run(["taskkill", "/F", "/IM", "aowlspt-backend.exe"],
                       capture_output=True)
        print("stopped the client and the backend (use --keep to leave them up)")
    else:
        print("left running (--keep)")

    print()
    ns = argparse.Namespace(root=install_dir(root), backend=False,
                            no_color=True, pattern="")
    hostlog.cmd_summary(ns, False)

    return {"REACHED": 0, "DIED": 1, "TIMEOUT": 2,
            "IDLE": 3, "ERRORDIALOG": 4, "INTERRUPTED": 130}[state]


def cmd_watch(args):
    started = time.time()
    state, why = watch(args.root, args.until, args.timeout, args.stall,
                       args.quiet, started)
    print("\n==== %s: %s" % (state, why))
    return {"REACHED": 0, "DIED": 1, "TIMEOUT": 2, "IDLE": 3,
            "ERRORDIALOG": 4}[state]


def main():
    p = argparse.ArgumentParser(
        description="launch the client and capture its log without a human",
        formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    p.add_argument("command", choices=["run", "watch"])
    p.add_argument("--root", default=DEFAULT_ROOT,
                   help=r"install root (contains aowlspt\); default D:\Aowlspt")
    p.add_argument("--until", default="host running",
                   help="literal to wait for in the host log")
    p.add_argument("--timeout", type=int, default=300)
    p.add_argument("--stall", type=int, default=45,
                   help="seconds of log silence that count as IDLE")
    p.add_argument("--profile", default=None,
                   help="play this profile instead of stopping at the picker")
    p.add_argument("--args", default=None, help="extra client arguments")
    p.add_argument("--launcher-arg", action="append", default=[],
                   metavar="FLAG[ VALUE]",
                   help="raw flag passed to aowlspt-launch.exe, repeatable "
                        "(e.g. --launcher-arg \"--modbuild C:/x/modbuild.py\")")
    p.add_argument("--out", default=os.path.join(REPO, "build", "runs"),
                   help="where captured logs are copied")
    p.add_argument("--keep", action="store_true",
                   help="leave the client and backend running")
    p.add_argument("-q", "--quiet", action="store_true",
                   help="do not echo the log while waiting")
    p.add_argument("--offscreen", action="store_true",
                   help="park the client's window off every monitor once it "
                        "appears, and VERIFY it again at the end of the run. "
                        "This is NOT headless: the renderer runs at full "
                        "speed, the window is merely on no display. Implies "
                        "--low-render, because a fullscreen window cannot be "
                        "moved. See tools/offscreen.py and docs/HEADLESS.md.")
    p.add_argument("--low-render", action="store_true",
                   help="pass --low-render to aowlspt-launch (windowed, "
                        "popupwindow, --render-size)")
    p.add_argument("--render-size", default="1280x720")
    p.add_argument("--park-deadline", type=int, default=180,
                   help="seconds to wait for the client to put a window up "
                        "before --offscreen reports INCONCLUSIVE. The default "
                        "is deliberately >60s: the client is slow to appear "
                        "and 'not yet' is not 'never'.")
    p.add_argument("--first", action="store_true",
                   help="if several client windows qualify, take the largest "
                        "rather than refusing to choose")
    args = p.parse_args()
    return cmd_run(args) if args.command == "run" else cmd_watch(args)


if __name__ == "__main__":
    sys.exit(main())
