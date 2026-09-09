#!/usr/bin/env python3
r"""runledger.py -- the two on-disk ledgers that make a client death readable.

    python tools/runledger.py teardowns [N]     what stopped the client, when
    python tools/runledger.py boots [N]         what each boot carried
    python tools/runledger.py line              the boot line, without booting

## Why this exists

Two measured costs, both from last night, both the same shape: the tool that
caused the evidence never said so.

1. **A teardown reads as a crash.** `run.py` without `--keep` force-stopped the
   client the moment its verdict landed, and a TaskStop of the launching shell
   killed it too. Afterwards the host log simply ENDS, on a heartbeat, with no
   fault line and no Unity crash folder -- which is exactly the shape of a
   client that died on its own. Three times, ~20 minutes each, that was chased
   as a crash. So every tool that stops the client now appends a line here
   FIRST, and `run.py` reads it back: a death with a teardown entry beside it is
   `KILLED-BY-TOOL`, not `DIED`.

2. **A boot carried ~7 commits.** Every crash then needed a bisect, and a
   one-sample bisect gave the wrong answer twice. Nothing printed how much
   change a boot was carrying, so nobody knew a bisect was coming until it was.
   `boot_facts` derives that from the deployed DLL, from `git log` since the
   PREVIOUS recorded launch, and from `git status` -- never from a guess.

Both ledgers are JSONL in the install directory, beside the host log, because
whoever is reading a death after the fact is already in that directory and may
have no transcript at all.

## The rule that keeps this from lying

An entry is written BEFORE the kill, so it survives a teardown that hangs or a
killer that is itself reaped. And `near()` refuses to attribute a death to a
teardown that happened before the client under test was even launched -- see
`not_before`. Without that, `run.py`'s own pre-launch "stop whatever is up
first" would explain every early death, which is a check that cannot fail.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time

DEFAULT_ROOT = r"D:\Aowlspt"

TEARDOWN_LEDGER = "aowlspt-teardown.jsonl"
BOOT_LEDGER = "aowlspt-boot.jsonl"

# How close a teardown has to be to a death before it EXPLAINS the death. The
# process poll that notices a death runs every 5s, so the death is already up to
# 5s old when it is seen; 10s is that plus a stated margin. It is not a
# measurement of anything and is deliberately small: a teardown a minute earlier
# is a different event.
KILLED_WINDOW_S = 10.0

# The deployed host DLL -- `host` in tools/deploy.json, dst `aowlspt-host-il2cpp.dll`.
HOST_DLL = "aowlspt-host-il2cpp.dll"

# What "a host/mod change" means for the boot line. Deliberately narrow: a
# change under tools/ or docs/ cannot be in the DLL that just booted, and
# counting it would inflate the bisect warning until it was ignored.
CODE_PREFIXES = ("host/", "mods/", "backend/", "examples/")


def install_dir(root=None):
    return os.path.join(root or DEFAULT_ROOT, "aowlspt")


def teardown_path(root=None):
    return os.path.join(install_dir(root), TEARDOWN_LEDGER)


def boot_path(root=None):
    return os.path.join(install_dir(root), BOOT_LEDGER)


# -- reading ---------------------------------------------------------------

def read(path, limit=None):
    """Every parsable JSON object in a JSONL file, oldest first.

    A corrupt line is SKIPPED, not fatal: a half-written record (the writer was
    killed mid-append -- which is precisely the situation this file exists to
    describe) must not make the whole ledger unreadable. Never reads more than
    `limit` bytes from the end when one is given.
    """
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            if limit:
                try:
                    size = os.path.getsize(path)
                except OSError:
                    size = 0
                if size > limit:
                    f.seek(size - limit)
                    f.readline()       # discard the partial first line
            data = f.read()
    except OSError:
        return []
    out = []
    for line in data.split("\n"):
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        if isinstance(obj, dict):
            out.append(obj)
    return out


def _append(path, obj):
    """One JSON object, one line, LF, flushed. Returns the path or None.

    Never raises: bookkeeping must not be able to stop a teardown or a launch.
    The caller is told (None) so it can SAY the ledger could not be written
    rather than silently proceeding as if it had been.
    """
    try:
        d = os.path.dirname(path)
        if d and not os.path.isdir(d):
            os.makedirs(d)
        with open(path, "a", encoding="utf-8", newline="\n") as f:
            f.write(json.dumps(obj, separators=(",", ":")) + "\n")
            f.flush()
        return path
    except (OSError, TypeError, ValueError):
        return None


# -- the teardown ledger ---------------------------------------------------

def client_pids(probe=None):
    """PIDs of the running client, or None if we could not tell.

    Three states, never two: a list (possibly empty -- nothing was running) or
    None (the probe failed). An empty list and a failed probe mean opposite
    things and must never both read as "no client".
    """
    if probe is not None:
        return probe()
    try:
        r = subprocess.run(["tasklist", "/FI", "IMAGENAME eq EscapeFromTarkov.exe",
                            "/FO", "CSV", "/NH"],
                           capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode != 0:
        return None
    pids = []
    for line in (r.stdout or "").splitlines():
        parts = [p.strip().strip('"') for p in line.split('","')]
        if len(parts) >= 2 and parts[0].lower().startswith("escapefromtarkov"):
            try:
                pids.append(int(parts[1]))
            except ValueError:
                pass
    return pids


def record(tool, reason, root=None, pids=None, argv=None, when=None,
           probe=None):
    """Note that `tool` is about to stop the client. Call BEFORE the kill.

    One line per PID that was running, so a later reader can match a specific
    death. When the probe cannot answer, ONE line is written with `pid: null`
    and `pids_known: false` -- "we stopped the client but could not read its
    pid" is a fact; pretending we know it is not.

    Returns the ledger path, or None if it could not be written.
    """
    when = time.time() if when is None else when
    if pids is None:
        pids = client_pids(probe)
    known = pids is not None
    rows = list(pids) if known and pids else [None]
    argv = list(argv if argv is not None else sys.argv)
    path = teardown_path(root)
    ok = None
    for pid in rows:
        ok = _append(path, {
            "when": round(when, 3),
            "when_local": time.strftime("%Y-%m-%d %H:%M:%S",
                                        time.localtime(when)),
            "pid": pid,
            "pids_known": known,
            "tool": tool,
            "reason": reason,
            "argv": argv,
        }) or ok
    return ok


def near(when, root=None, window=KILLED_WINDOW_S, not_before=None, path=None):
    """The teardown entry that EXPLAINS a death at `when`, or None.

    `not_before` is the load-bearing argument. `run.py` stops whatever client is
    up before launching a new one, and that stop is recorded too -- so without a
    floor at the moment THIS client was launched, the tool's own pre-launch kill
    would explain every early death and `KILLED-BY-TOOL` would be a verdict that
    can never be wrong. Entries at or before `not_before` are ignored.

    Nearest entry inside the window wins. A teardown strictly AFTER the death is
    still accepted inside the window: the death is noticed by a 5s poll, so
    "killed, then noticed" and "noticed, then killed" are the same second.
    """
    best = None
    for e in read(path or teardown_path(root), limit=1 << 20):
        t = e.get("when")
        if not isinstance(t, (int, float)):
            continue
        if not_before is not None and t <= not_before:
            continue
        d = abs(when - t)
        if d > window:
            continue
        if best is None or d < best[0]:
            best = (d, e)
    return None if best is None else best[1]


# -- the boot ledger -------------------------------------------------------

def repo_root():
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _git(args, repo, runner=None):
    """(rc, text) or None when git could not be run at all.

    None is a THIRD state and callers must keep it: "git is not available here"
    is not "there are no commits".
    """
    if runner is not None:
        return runner(args)
    try:
        r = subprocess.run(["git", "-C", repo] + list(args),
                           capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None
    return r.returncode, (r.stdout or "")


def _porcelain_paths(text):
    """Paths out of `git status --porcelain`, rename-aware."""
    out = []
    for line in (text or "").splitlines():
        if len(line) < 4:
            continue
        p = line[3:].strip()
        if " -> " in p:
            p = p.split(" -> ", 1)[1]
        out.append(p.strip('"').replace("\\", "/"))
    return out


def last_boot(root=None, path=None):
    """The most recent recorded launch, or None. Never invents one."""
    rows = [e for e in read(path or boot_path(root), limit=1 << 20)
            if e.get("kind") == "launch" and isinstance(e.get("when"),
                                                        (int, float))]
    return rows[-1] if rows else None


def boot_facts(root=None, repo=None, now=None, git_runner=None, path=None):
    """Everything the boot line states, each item measured or explicitly None.

    Nothing here is inferred from a name or a habit: the DLL size and mtime come
    off the deployed file, the commit count comes from `git log --since` against
    the PREVIOUS recorded launch, and the uncommitted count comes from
    `git status --porcelain` filtered to the directories that can actually be in
    the DLL. Any of them may be None, and None means "not measured", which the
    line says out loud.
    """
    repo = repo or repo_root()
    now = time.time() if now is None else now
    f = {"dll": os.path.join(install_dir(root), HOST_DLL),
         "dll_size": None, "dll_mtime": None, "sha": None, "dirty": None,
         "commits": None, "since": None, "git_error": None, "now": now}
    try:
        st = os.stat(f["dll"])
        f["dll_size"] = st.st_size
        f["dll_mtime"] = st.st_mtime
    except OSError:
        pass

    g = _git(["rev-parse", "--short", "HEAD"], repo, git_runner)
    if g is None:
        f["git_error"] = "git could not be run at all"
        return f
    if g[0] == 0 and g[1].strip():
        f["sha"] = g[1].strip().splitlines()[0]
    else:
        f["git_error"] = "git rev-parse --short HEAD failed"
        return f

    g = _git(["status", "--porcelain"], repo, git_runner)
    if g is not None and g[0] == 0:
        f["dirty"] = [p for p in _porcelain_paths(g[1])
                      if p.startswith(CODE_PREFIXES)]
    else:
        f["git_error"] = "git status --porcelain failed"

    prev = last_boot(root, path=path)
    if prev is not None:
        f["since"] = prev.get("when")
        g = _git(["log", "--oneline", "--since=@%d" % int(f["since"])],
                 repo, git_runner)
        if g is not None and g[0] == 0:
            f["commits"] = len([l for l in g[1].splitlines() if l.strip()])
        else:
            f["git_error"] = "git log --since failed"
    return f


# The threshold above which a crash on this boot needs a bisect. 4 is a stated
# choice, not a measurement: last night carried ~7 changes per boot and every
# crash needed one. A boot carrying 5 changes is already past the point where a
# single sample names a cause.
BISECT_LIMIT = 4

WARN_BISECT = "WARN: a crash on this boot cannot be attributed without a bisect"


def boot_line(f):
    """The one line printed at launch, plus at most one WARN line.

    Returns a list of lines. Every unmeasured item is NAMED as unmeasured; this
    line must never read as a clean bill of health it did not establish.
    """
    if f.get("dll_size") is None:
        dll = "host DLL MISSING at %s (nothing is deployed there)" % f["dll"]
    else:
        dll = ("host DLL %s bytes built %s"
               % ("{:,}".format(f["dll_size"]),
                  time.strftime("%Y-%m-%d %H:%M:%S",
                                time.localtime(f["dll_mtime"]))))
    dirty = f.get("dirty")
    if f.get("sha") is None:
        src = "from an UNKNOWN source revision (%s)" % (f.get("git_error")
                                                        or "git said nothing")
    elif dirty is None:
        src = "from %s (uncommitted changes NOT counted: %s)" % (
            f["sha"], f.get("git_error") or "git status failed")
    elif dirty:
        src = "from dirty: %d files on top of %s" % (len(dirty), f["sha"])
    else:
        src = "from %s (clean)" % f["sha"]

    m = None if dirty is None else len(dirty)
    k = f.get("commits")
    if f.get("since") is None:
        tail = ("%s uncommitted host/mod file(s); NO previous boot is recorded, "
                "so the commit count since it is UNKNOWN"
                % ("?" if m is None else m))
    else:
        tail = ("%s commit(s) and %s uncommitted host/mod file(s) since the "
                "previous boot (%s)"
                % ("?" if k is None else k, "?" if m is None else m,
                   time.strftime("%Y-%m-%d %H:%M:%S",
                                 time.localtime(f["since"]))))
    lines = ["this boot carries: %s %s; %s" % (dll, src, tail)]
    if k is None and m is None:
        lines.append("WARN: how much change this boot carries could NOT be "
                     "measured (%s) -- that is INCONCLUSIVE, not 'a small "
                     "boot'" % (f.get("git_error") or "no git answer"))
    elif (k or 0) + (m or 0) > BISECT_LIMIT:
        lines.append(WARN_BISECT)
    return lines


def record_boot(root=None, facts=None, argv=None, when=None, path=None):
    """Append this launch, so the NEXT boot can count commits since it."""
    when = time.time() if when is None else when
    f = facts or {}
    return _append(path or boot_path(root), {
        "kind": "launch",
        "when": round(when, 3),
        "when_local": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(when)),
        "dll_size": f.get("dll_size"),
        "dll_mtime": f.get("dll_mtime"),
        "sha": f.get("sha"),
        "dirty": len(f["dirty"]) if f.get("dirty") is not None else None,
        "commits_since_previous": f.get("commits"),
        "argv": list(argv if argv is not None else sys.argv),
    })


# -- CLI -------------------------------------------------------------------

def main(argv):
    cmd = argv[1] if len(argv) > 1 else "boots"
    root = None
    if "--root" in argv:
        root = argv[argv.index("--root") + 1]
    n = 10
    for a in argv[2:]:
        if a.isdigit():
            n = int(a)
    if cmd == "teardowns":
        rows = read(teardown_path(root))
        if not rows:
            print("no teardowns recorded in %s" % teardown_path(root))
            return 1
        for e in rows[-n:]:
            print("%s  pid=%-6s %-14s %s"
                  % (e.get("when_local"), e.get("pid"), e.get("tool"),
                     e.get("reason")))
        return 0
    if cmd == "boots":
        rows = read(boot_path(root))
        if not rows:
            print("no boots recorded in %s" % boot_path(root))
            return 1
        for e in rows[-n:]:
            print("%s  dll=%-10s sha=%-10s dirty=%-4s commits=%s"
                  % (e.get("when_local"), e.get("dll_size"), e.get("sha"),
                     e.get("dirty"), e.get("commits_since_previous")))
        return 0
    if cmd == "line":
        for l in boot_line(boot_facts(root)):
            print(l)
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
