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
2 timed out, 3 went idle without reaching the sentinel.
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
    if args.args:
        cmd += ["--args", args.args]

    started = time.time()
    print("$ %s" % " ".join(cmd))
    proc = subprocess.Popen(cmd, cwd=install_dir(root))

    try:
        state, why = watch(root, args.until, args.timeout, args.stall,
                           args.quiet, started)
    except KeyboardInterrupt:
        state, why = "INTERRUPTED", "ctrl-c"

    took = time.time() - started
    print("\n==== %s after %.0fs: %s" % (state, took, why))

    saved = capture(root, args.out)
    for s in saved:
        print("captured %s" % s)

    if not args.keep:
        # The launcher kills the backend it started when it exits; the client
        # it deliberately never kills, so that is ours to do.
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
            "IDLE": 3, "INTERRUPTED": 130}[state]


def cmd_watch(args):
    started = time.time()
    state, why = watch(args.root, args.until, args.timeout, args.stall,
                       args.quiet, started)
    print("\n==== %s: %s" % (state, why))
    return {"REACHED": 0, "DIED": 1, "TIMEOUT": 2, "IDLE": 3}[state]


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
    p.add_argument("--out", default=os.path.join(REPO, "build", "runs"),
                   help="where captured logs are copied")
    p.add_argument("--keep", action="store_true",
                   help="leave the client and backend running")
    p.add_argument("-q", "--quiet", action="store_true",
                   help="do not echo the log while waiting")
    args = p.parse_args()
    return cmd_run(args) if args.command == "run" else cmd_watch(args)


if __name__ == "__main__":
    sys.exit(main())
