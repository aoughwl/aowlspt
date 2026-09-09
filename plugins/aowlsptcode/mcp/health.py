"""health.py -- is the client actually alive, or is it showing you a box?

Every other tool in this plugin asks the live client a question through the file
channel. This one asks a question ABOUT the client, from the outside, and it
exists because of a failure mode that made every other tool lie by omission.

## The problem

An in-game error dialog does not look like a failure from outside. The process
stays alive. The client writes nothing at Error level -- it does not consider a
modal window an error. The host log simply stops. That is BYTE-IDENTICAL to the
game sitting at profile-select waiting for a human, which is the normal, healthy
end state of every scripted launch.

So an inspector batch that times out, or a `state` call that comes back stale,
or an automated raid run that goes quiet, all have two possible explanations --
"it is idle and fine" and "it is dead and waiting for a click nobody will make"
-- and nothing in the toolbox could tell them apart. The measured cost of that
confusion, recorded in the project's fact store, is a session that sat stuck for
about twelve minutes on a raid-load break before anyone realised.

## The fix, and where the information comes from

The host detours the three `EFT.UI.PreloaderUI` error-screen entry points
read-only and writes ONE line per dialog to `aowlspt-host.log`:

    ERRORDIALOG kind=<message|exception|critical> header="..." text="..."

The dialog is never suppressed -- it still appears for the person at the
keyboard. This module reads that marker and reports it. Nothing here talks to
the game; it only reads files the install already writes, so it is safe to call
at any time, including when the channel is wedged or the client is gone.

## Three outcomes, never two

`ALIVE` / `ERRORDIALOG` / `GONE`, plus `UNKNOWN` when the host log cannot be
read at all. Critically, an `ALIVE` verdict is only reported as trustworthy when
the host actually ARMED the dialog catch -- the log says `errdlg ARMED` when it
did. If it did not, `errdlg_armed` is False and the caller is told that a quiet
log proves nothing, because a dialog would produce exactly this same shape.
"I could not look" is not a pass.
"""

from __future__ import annotations

import os
import re
import subprocess

LIVE_DEFAULT = r"D:\Aowlspt\aowlspt"

# `[0:00:21.844] warn   message`
HOSTLINE = re.compile(r"^\[(\d+:\d\d:\d\d\.\d+)\]\s+(\w+)\s+(.*)$")
ERRDLG = re.compile(r'ERRORDIALOG\s+kind=(\S+)\s+header="(.*?)"\s+text="(.*?)"')

# The host prints this once when it has hit its per-session print cap. It is the
# host saying it STOPPED printing, not another dialog; counting it as one would
# put a fabricated event in the report.
SUPPRESSED = 'header="<suppressed>"'

# Never read more than this from the tail of the host log. These files are
# measured token bombs in this project and an unwindowed read has ended sessions.
MAX_TAIL_BYTES = 2 << 20


def live_dir(live=None):
    return live or os.environ.get("AOWLSPT_LIVE", LIVE_DEFAULT)


def host_log(live=None):
    return os.path.join(live_dir(live), "aowlspt-host.log")


def client_running(exe="EscapeFromTarkov.exe"):
    """None means 'could not tell', which is NOT the same as 'not running'."""
    try:
        out = subprocess.run(["tasklist", "/FI", "IMAGENAME eq %s" % exe, "/NH"],
                             capture_output=True, text=True, timeout=15).stdout
    except Exception:
        return None
    return exe.lower() in out.lower()


# The `errdlg ARMED` line is written about ONE SECOND into the run, so on any
# long session it is at the very START of the log and a tail-only read never
# sees it. That produced a wrong `errdlg_armed: false` on a healthy 20-minute
# run -- measured. It failed in the SAFE direction (the caller is told not to
# trust a quiet log, rather than being told a dialog would have been caught when
# it would not), but it is still a wrong answer about our own configuration, and
# a tool that is confidently wrong is worse than one that is silent.
#
# So the head is read for the arming evidence and the tail for the events. Both
# are bounded; neither ever reads the whole file.
MAX_HEAD_BYTES = 256 << 10


def _head(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read(MAX_HEAD_BYTES).splitlines()
    except OSError:
        return None


def _tail(path):
    try:
        size = os.path.getsize(path)
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            if size > MAX_TAIL_BYTES:
                f.seek(size - MAX_TAIL_BYTES)
                f.readline()
            return f.read().splitlines()
    except OSError:
        return None


def check(live=None):
    """Report the client's health from the install's own files.

    Returns a dict with `verdict`, `errdlg_armed`, `can_trust_quiet`, the
    dialogs found, the run length, and the last few host-log lines -- bounded,
    because the caller is usually a model and the log is not.
    """
    path = host_log(live)
    lines = _tail(path)
    if lines is None:
        return {
            "verdict": "UNKNOWN",
            "why": ("no readable host log at %s -- the host has not run, so "
                    "nothing about the client can be established from here"
                    % path),
            "errdlg_armed": None,
            "can_trust_quiet": False,
            "dialogs": [],
            "host_log": path,
        }

    # Arming evidence comes from the HEAD (it is logged ~1s in); events come
    # from the tail. On a short log the two overlap, which is harmless.
    armed = any("errdlg ARMED" in l for l in (_head(path) or []))

    dialogs = []
    last_stamp = ""
    tail = []
    for raw in lines:
        m = HOSTLINE.match(raw)
        if not m:
            continue
        stamp, _level, msg = m.group(1), m.group(2), m.group(3)
        last_stamp = stamp
        tail.append("[%s] %s" % (stamp, msg))
        del tail[:-6]
        if "ERRORDIALOG kind=" in msg and SUPPRESSED not in msg:
            d = ERRDLG.search(msg)
            dialogs.append({
                "at": stamp,
                "kind": d.group(1) if d else "unknown",
                "header": d.group(2) if d else "",
                "text": d.group(3) if d else msg,
            })

    running = client_running()

    if dialogs:
        verdict = "ERRORDIALOG"
        why = ("the client raised %d error window(s) and is waiting for a "
               "click. It is NOT idle -- an unattended run will sit on this "
               "until it times out." % len(dialogs))
    elif running is False:
        verdict = "GONE"
        why = "no EscapeFromTarkov.exe process; the client is not running"
    elif running is None:
        verdict = "UNKNOWN"
        why = ("could not query the process list, so liveness is undetermined; "
               "this is not evidence the client is fine")
    else:
        verdict = "ALIVE"
        why = "the client process is running and no error dialog was logged"

    return {
        "verdict": verdict,
        "why": why,
        "errdlg_armed": armed,
        # The whole point. A quiet log only means "healthy and idle" when the
        # host was actually watching for the alternative.
        "can_trust_quiet": bool(armed),
        "quiet_caveat": None if armed else (
            "The host did NOT report `errdlg ARMED`, so in-game error dialogs "
            "were not being caught on this run. A quiet host log and a live "
            "process therefore do NOT distinguish a healthy idle client from "
            "one sitting on a modal error window -- treat any ALIVE/idle "
            "reading as INCONCLUSIVE rather than as a pass."),
        "dialogs": dialogs,
        "run_length": last_stamp,
        "client_running": running,
        "recent": tail,
        "host_log": path,
    }
