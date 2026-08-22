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
import time

LIVE = os.environ.get("AOWLSPT_LIVE", r"D:\Aowlspt\aowlspt")
CMD = os.path.join(LIVE, "aowlspt-inspect.txt")
OUT = os.path.join(LIVE, "aowlspt-inspect-out.txt")
LOG = os.path.join(LIVE, "aowlspt-host" + ".log")


def read(path):
    try:
        with open(path, "rb") as f:
            return f.read().decode("utf-8", "replace").lstrip("\ufeff")
    except OSError:
        return ""


def diagnose():
    """Say WHY there was no answer, from the host's own words. A timeout with
    no explanation is the failure mode this whole project keeps paying for."""
    log = read(LOG)
    if not log:
        return "the host log is absent or empty -- the host is not running."
    hits = [l.strip() for l in log.splitlines() if "live inspector" in l]
    if not hits:
        return ("the host log never mentions the live inspector at all -- the "
                "`liveInspector` flag is off in aowlspt-host.json.")
    return "last of what the host said about the channel:\n   " + \
           "\n   ".join(hits[-3:])


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("cmds", nargs="*", help="one inspector command per argument")
    ap.add_argument("-f", "--file", help="read the batch from a file ('-' = stdin)")
    ap.add_argument("--timeout", type=float, default=25.0,
                    help="seconds to wait for THIS batch's answer (default 25)")
    ap.add_argument("--write", action="store_true",
                    help="prepend 'allow write' (still needs liveInspectorWrite)")
    ap.add_argument("--raw", action="store_true", help="print the answer only")
    a = ap.parse_args()

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

    serial = int(time.time() * 1000) % 1000000
    sentinel = "aowl-batch-%d" % serial
    body = "#%d\n" % serial + "\n".join(lines) + "\necho %s\n" % sentinel

    # A plain byte write, no BOM, LF endings. PowerShell's utf8 encoder emits a
    # BOM; the host tolerates one only because it was taught to, and a byte
    # write cannot regress that way.
    with open(CMD, "wb") as f:
        f.write(body.encode("utf-8"))

    deadline = time.time() + a.timeout
    while time.time() < deadline:
        out = read(OUT)
        if sentinel in out:
            if not a.raw:
                print("--- batch %d: %d command(s) ---" % (serial, len(lines)))
            # Drop our own sentinel echo; it is bookkeeping, not an answer.
            print("\n".join(l for l in out.splitlines() if sentinel not in l))
            return 0
        time.sleep(0.15)

    print("!! no answer for batch %d within %gs." % (serial, a.timeout),
          file=sys.stderr)
    print(diagnose(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
