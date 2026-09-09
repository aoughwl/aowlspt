#!/usr/bin/env python3
"""Read `aowlspt-host.log` the way we actually ask questions of it.

The host log is the only channel out of the client, and every cycle it was
being read with ad-hoc greps that had to be guessed in advance. The questions
are always the same four, so they are subcommands here:

    python tools/hostlog.py summary            # did it boot? what broke?
    python tools/hostlog.py faults             # everything that went wrong
    python tools/hostlog.py feature debugui    # one subsystem, whole run
    python tools/hostlog.py config             # what config the host ACTUALLY read
    python tools/hostlog.py boot               # the boot milestone checklist
    python tools/hostlog.py grep <regex>
    python tools/hostlog.py tail               # last --max lines, then EXIT
    python tools/hostlog.py tail --follow      # ...and keep watching (blocks)
    python tools/hostlog.py shape              # level histogram + top first tokens

`tail` USED to follow unconditionally, and that made it unusable from any
script: `hostlog.py tail --max 6` printed "following ... ctrl-c to stop" and
never returned, so a scripted call sat there until the caller's timeout killed
it (measured 2026-09-01: a full 2-minute tool timeout burned on what was meant
to be a six-line read). A tool whose default never terminates cannot be called
by anything except a human. So the default now prints the last `--max` lines
and exits; `--follow`/`-f` is the blocking behaviour, and it is opt-in.

`--root PATH` picks the install (default D:\\Aowlspt\\aowlspt); `--backend`
reads aowlspt-backend.log instead.

One thing that makes this easy and is worth knowing: **the host truncates the
log at every start** (`modhost.openLog` writes the banner with
`writeTextFile`). So the file is always exactly one run -- "since the last
launch" is the whole file, and the banner at the top is the proof of which run
it is. There is no need to seek to a marker.

Line format, from `host/common/modhost.nim:480`:

    [h:mm:ss.mmm] <level>  <message>

where <level> is one of `info `, `warn `, `error`, `ok   ` -- fixed five
characters, then TWO spaces. The stamp is elapsed time since host attach, not
wall clock, so it answers "how long into the run" directly.
"""

import argparse
import os
import re
import sys
import time

DEFAULT_ROOT = r"D:\Aowlspt\aowlspt"

LINE = re.compile(r"^\[(\d+:\d\d:\d\d\.\d\d\d)\] (info |warn |error|ok   )  (.*)$")

RESET = "\033[0m"
RED = "\033[31m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
CYAN = "\033[36m"
DIM = "\033[2m"
BOLD = "\033[1m"

# A fault is not only a level. A feature that catches its own exception and
# keeps going logs at `info`, and a feature that spends its fault budget and
# switches itself off is the single most important line in the file -- it means
# everything you are about to test was not running. So the level test is
# widened by the vocabulary the host actually uses.
FAULT = re.compile(
    r"FAULTED|fault caught|fault #|switched itself OFF|switching itself off"
    r"|REFUSING|refusing|refused|DECLINED|did not arm|did not start"
    r"|was not persisted|is not readable|no usable code pointer",
    re.IGNORECASE)

# The subset that means "this feature is DEAD for the rest of the run".
DEAD = re.compile(
    r"switched itself OFF|switching itself off|REFUSING TO BUILD|DECLINED"
    r"|did not arm|did not start|refusing to ride",
    re.IGNORECASE)

# Boot milestones, in order, with the literal that proves each one. Derived
# from host/Aowlspt.Host.Il2Cpp/aowlhost.nim. `host running` is the sentinel
# the launcher itself waits for.
MILESTONES = [
    ("battleye answered",   "BattlEye is not installed, started or loaded"),
    ("il2cpp up",           "IL2CPP is up after"),
    ("il2cpp bound",        "IL2CPP runtime bound, all essential entry points present"),
    ("anti-cheat patched",  "anti-cheat:"),
    ("exit fix",            "exit fix:"),
    ("runtime reported",    "assemblies loaded"),
    ("mods loaded",         "loaded on aowlspt-host-il2cpp"),
    ("overlay ready",       "overlay ready"),
    ("backend polling",     "which client mods should be running"),
    ("HOST RUNNING",        "host running"),
    ("Unity thread live",   "NOT the host thread -> Unity's main thread"),
]

# `<key> is set: <explanation>` is logged once per enabled flag at boot. That
# line is the only honest answer to "what config did this run use", because it
# is what the host read, not what the JSON says.
CONFIG_ECHO = re.compile(r"^(\w+)(/\w+)? is set:")


def logpath(args):
    name = "aowlspt-backend.log" if args.backend else "aowlspt-host.log"
    return os.path.join(args.root, name)


def read(args):
    p = logpath(args)
    if not os.path.isfile(p):
        sys.exit("no log at %s (has the game been launched?)" % p)
    with open(p, "r", encoding="utf-8", errors="replace") as f:
        return p, f.read().splitlines()


def parse(lines):
    """Yield (stamp, level, msg, raw). Unparsed lines (the banner) get level ''."""
    for raw in lines:
        m = LINE.match(raw)
        if m:
            yield m.group(1), m.group(2).strip(), m.group(3), raw
        else:
            yield "", "", raw, raw


def paint(level, msg, C):
    if not C:
        return ""
    if level == "error":
        return RED
    if level == "warn":
        return YELLOW
    if DEAD.search(msg):
        return RED
    if FAULT.search(msg):
        return YELLOW
    if level == "ok":
        return GREEN
    return ""


def show(rows, C, stamps=True):
    for stamp, level, msg, raw in rows:
        c = paint(level, msg, C)
        if not level:
            print(("%s%s%s" % (DIM, raw, RESET)) if C else raw)
            continue
        head = "[%s] %-5s " % (stamp, level) if stamps else ""
        if C:
            print("%s%s%s%s%s" % (DIM if C else "", head, RESET if C else "",
                                  c, msg + (RESET if c else "")))
        else:
            print(head + msg)


def banner(lines):
    """The first four unstamped lines: name, version, directory, thread."""
    out = []
    for raw in lines:
        if LINE.match(raw):
            break
        if raw.strip():
            out.append(raw.strip())
    return out


def age(p):
    dt = time.time() - os.path.getmtime(p)
    if dt < 90:
        return "%.0fs ago" % dt
    if dt < 5400:
        return "%.0f min ago" % (dt / 60)
    return "%.1f h ago" % (dt / 3600)


def cmd_summary(args, C):
    p, lines = read(args)
    rows = list(parse(lines))
    b = banner(lines)
    print("%s%s%s   last written %s" % (BOLD if C else "", p, RESET if C else "",
                                        age(p)))
    for l in b:
        print("  " + l)
    stamped = [r for r in rows if r[1]]
    if stamped:
        print("  run length %s, %d logged lines" % (stamped[-1][0], len(stamped)))
    print()

    print("%sboot%s" % (BOLD if C else "", RESET if C else ""))
    reached = cmd_boot(args, C, rows=rows, quiet=False)
    print()

    dead = [r for r in stamped if DEAD.search(r[2])]
    errs = [r for r in stamped if r[1] in ("error", "warn")]
    faults = [r for r in stamped if r[1] not in ("error", "warn")
              and FAULT.search(r[2]) and not DEAD.search(r[2])]

    if dead:
        print("%sFEATURES THAT TURNED THEMSELVES OFF OR NEVER ARMED (%d)%s"
              % (RED + BOLD if C else "", len(dead), RESET if C else ""))
        show(dead, C)
        print()
    if errs:
        print("%swarnings and errors (%d)%s"
              % (BOLD if C else "", len(errs), RESET if C else ""))
        show(errs, C)
        print()
    if faults:
        print("%sfaults caught and survived (%d)%s"
              % (BOLD if C else "", len(faults), RESET if C else ""))
        show(faults, C)
        print()
    if not (dead or errs or faults):
        print("%sno faults, warnings or self-disables.%s"
              % (GREEN if C else "", RESET if C else ""))
    return 0 if reached else 1


def cmd_boot(args, C, rows=None, quiet=False):
    if rows is None:
        _, lines = read(args)
        rows = list(parse(lines))
    text = "\n".join(r[2] for r in rows)
    running = False
    for label, lit in MILESTONES:
        hit = None
        for stamp, level, msg, _ in rows:
            if lit in msg:
                hit = stamp
                break
        if hit is not None:
            if label == "HOST RUNNING":
                running = True
            mark = "%sok  %s" % (GREEN if C else "", RESET if C else "")
            print("  %s [%s] %s" % (mark, hit, label))
        else:
            mark = "%s--  %s" % (DIM if C else "", RESET if C else "")
            print("  %s %-14s %s" % (mark, "", label))
    return running


def cmd_faults(args, C):
    _, lines = read(args)
    rows = [r for r in parse(lines)
            if r[1] in ("error", "warn") or (r[1] and FAULT.search(r[2]))]
    if not rows:
        print("no faults, warnings or self-disables.")
        return 0
    show(rows, C)
    return 1


def cmd_feature(args, C):
    _, lines = read(args)
    # A feature's lines are the ones whose message mentions it. The host's
    # convention is a `<subsystem>: ` prefix, but the same feature is also named
    # in its arm/refuse/config-echo lines without the colon, and those are
    # exactly the ones you want when the answer is "it never armed". So this
    # matches the word anywhere in the message, case-insensitively.
    pat = re.compile(re.escape(args.pattern), re.IGNORECASE)
    rows = [r for r in parse(lines) if r[1] and pat.search(r[2])]
    if not rows:
        print("nothing in the log mentions %r." % args.pattern)
        print("that is itself an answer: the feature logged nothing at all, so "
              "it was almost certainly compiled out or never reached.")
        return 1
    show(rows, C)
    dead = [r for r in rows if DEAD.search(r[2])]
    if dead:
        print("\n%s-- this feature was not running for (part of) the run.%s"
              % (RED if C else "", RESET if C else ""))
        return 1
    return 0


def cmd_config(args, C):
    _, lines = read(args)
    rows = [r for r in parse(lines) if r[1] and CONFIG_ECHO.match(r[2])]
    print("flags the host reported as ON this run (from its own boot echo):")
    if not rows:
        print("  (none -- every flag was off or absent)")
    for stamp, level, msg, _ in rows:
        key = CONFIG_ECHO.match(msg).group(0).rstrip(":")
        print("  %s%s%s" % (GREEN if C else "", key, RESET if C else ""))
    print("\nnote: this is what the host READ. Compare with the JSON via")
    print("  python tools/hostcfg.py show")
    return 0


def cmd_grep(args, C):
    """Matching lines, BOUNDED by default.

    `summary` has always had sane bounds; `grep` had none, and this is the one
    subcommand whose output size is chosen by the LOG rather than by the
    caller. Measured 2026-09-01: one word emitted 25KB and had to be truncated
    by the harness, and the maps profiler alone appends a multi-thousand-
    character block every ~2s -- so a pattern matching it returns megabytes.
    CLAUDE.md 8: a single unwindowed read of the wrong file ends a session, and
    a tool that exists to protect against that must not itself be the bomb.

    Default is the LAST --max matches, not the first: on a log the newest
    entries are almost always the ones being asked about, and a head-limit
    would return the oldest and silently hide the reason you ran the command.
    The count of what was withheld is always printed -- a truncated answer that
    does not say it was truncated is a wrong answer.
    """
    _, lines = read(args)
    pat = re.compile(args.pattern, 0 if args.case else re.IGNORECASE)
    rows = [r for r in parse(lines) if pat.search(r[2])]
    total = len(rows)
    shown = rows
    if args.max > 0 and total > args.max:
        shown = rows[-args.max:] if not args.head else rows[:args.max]
    show(shown, C)
    if total > len(shown):
        print("-- %d of %d match(es) shown (%s). %d withheld; raise with "
              "--max N, or --max 0 for all."
              % (len(shown), total, "oldest" if args.head else "newest",
                 total - len(shown)))
    return 0 if rows else 1


def cmd_tail(args, C):
    """The last `--max` lines, and then RETURN. `--follow` to keep watching.

    The blocking version was the default until 2026-09-01 and it is the reason
    this docstring exists: a subcommand that never terminates is a subcommand no
    script can call, and the failure mode is not an error -- it is a caller
    hanging until its own timeout, with the output it asked for already sitting
    unflushed on a pipe. Bounded by default, blocking only when asked.
    """
    p, lines = read(args)          # `read` refuses (exit 1) if there is no log
    rows = list(parse(lines))
    n = args.max
    shown = rows if n <= 0 else rows[-n:]
    show(shown, C)
    if len(shown) < len(rows):
        print("-- last %d of %d line(s). --max N for more, --max 0 for all."
              % (len(shown), len(rows)))
    if not args.follow:
        return 0
    return follow(p, C)


def follow(p, C):
    """`tail -f`: everything APPENDED from now on. Blocks until Ctrl-C.

    Starts at the current end of file on purpose. The old code started at byte
    0, so turning on following also dumped the entire log -- and the host log is
    a measured token bomb (CLAUDE.md 8). The bounded last-N lines are printed by
    the caller before this is entered, which is what `tail -f` actually does.
    """
    print("following %s -- ctrl-c to stop" % p, flush=True)
    try:
        pos = os.path.getsize(p)
    except OSError:
        pos = 0
    while True:
        try:
            st = os.stat(p)
        except OSError:
            time.sleep(0.4)
            continue
        # The host truncates on restart, so a size that went backwards means a
        # new run started; reopen from the top and say so.
        if st.st_size < pos:
            print("\n%s---- log truncated: a new run started ----%s"
                  % (CYAN if C else "", RESET if C else ""))
            pos = 0
        if st.st_size > pos:
            with open(p, "r", encoding="utf-8", errors="replace") as f:
                f.seek(pos)
                chunk = f.read()
                pos = f.tell()
            show(list(parse(chunk.splitlines())), C)
        time.sleep(0.4)


def cmd_shape(args, C):
    """"What shape are these lines?" -- a level histogram plus the top-N
    leading tokens, in one call.

    This existed as a throwaway awk/python one-liner in at least three
    sessions, each written slightly differently, so the answers were not
    comparable between them. It answers: how big is this log, how much of it
    is errors, and what subsystems are actually talking. `--backend` points
    it at aowlspt-backend.log, so the backend equivalent is the same verb.
    """
    p, lines = read(args)
    rows = list(parse(lines))
    print("%s  %d line(s), %d bytes" % (p, len(lines), os.path.getsize(p)))

    levels = {}
    toks = {}
    unparsed = 0
    for _stamp, level, msg, _raw in rows:
        if not level:
            unparsed += 1
        levels[level or "(no level -- banner/continuation)"] = \
            levels.get(level or "(no level -- banner/continuation)", 0) + 1
        # First token of the MESSAGE, which is how this codebase prefixes
        # subsystems ("settings:", "betanotice:", "modstab:").
        t = msg.strip().split(" ", 1)[0].rstrip(":,") if msg.strip() else ""
        if t:
            toks[t] = toks.get(t, 0) + 1

    print("\nlevels")
    for lv, n in sorted(levels.items(), key=lambda kv: -kv[1]):
        print("  %-40s %6d  %5.1f%%"
              % (lv, n, 100.0 * n / max(len(rows), 1)))

    n_top = args.top
    ordered = sorted(toks.items(), key=lambda kv: -kv[1])
    print("\ntop %d first token(s), of %d distinct" % (n_top, len(ordered)))
    for t, n in ordered[:n_top]:
        print("  %-40s %6d" % (t[:40], n))
    if len(ordered) > n_top:
        rest = sum(n for _, n in ordered[n_top:])
        print("  %-40s %6d   (%d more distinct token(s) -- this is a "
              "TRUNCATED list, not the whole set; raise --top)"
              % ("... everything else", rest, len(ordered) - n_top))
    if unparsed:
        print("\n%d line(s) did not match the timestamped log format and "
              "carry no level; they are counted above under "
              "'(no level ...)', not dropped." % unparsed)
    return 0


def main():
    p = argparse.ArgumentParser(
        description="read the aowlspt host log",
        formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    p.add_argument("command",
                   choices=["summary", "boot", "faults", "feature", "config",
                            "grep", "tail", "shape"])
    p.add_argument("pattern", nargs="?", default="")
    p.add_argument("--root", default=DEFAULT_ROOT)
    p.add_argument("--backend", action="store_true",
                   help="read aowlspt-backend.log instead")
    p.add_argument("--case", action="store_true", help="grep case-sensitively")
    p.add_argument("--follow", "-f", action="store_true",
                   help="with `tail`: keep watching for appended lines instead "
                        "of returning. THIS BLOCKS until Ctrl-C -- never use it "
                        "from a script.")
    p.add_argument("--max", type=int, default=60,
                   help="cap `grep` matches / `tail` lines at N (default 60, "
                        "0 = all). "
                        "The host log is a measured token bomb; an unbounded "
                        "grep on it has emitted 25KB for a single word.")
    p.add_argument("--head", action="store_true",
                   help="with --max, keep the OLDEST matches instead of the "
                        "newest")
    p.add_argument("--top", type=int, default=25,
                   help="how many leading tokens `shape` lists (default 25)")
    p.add_argument("--no-color", action="store_true")
    args = p.parse_args()
    C = (not args.no_color) and sys.stdout.isatty()

    if args.command in ("feature", "grep") and not args.pattern:
        sys.exit("%s needs a pattern" % args.command)
    try:
        return {
            "summary": cmd_summary, "boot": lambda a, c: (0 if cmd_boot(a, c) else 1),
            "faults": cmd_faults, "feature": cmd_feature, "config": cmd_config,
            "grep": cmd_grep, "tail": cmd_tail, "shape": cmd_shape,
        }[args.command](args, C)
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main())
