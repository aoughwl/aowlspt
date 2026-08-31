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
