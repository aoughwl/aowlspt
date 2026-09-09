#!/usr/bin/env python3
r"""Read the wire logs (`aowlspt-backend.log`, `nettrace.log`) without pasting
six figures of JSON into a context window.

Why this exists, measured
-------------------------
`aowlspt-backend.log` logs every probed exchange as ONE line containing the
whole body. A single observed `PROBE RES /client/game/profile/list` line was
**115,477 bytes**. `nettrace.log` is **3.1 MB / 42,107 lines**. A `grep` for a
route name against either can return more characters than a whole session of
useful work. Every subcommand here therefore truncates by default and tells you
how much it withheld.

    python tools/wirelog.py summary                 # boot lines + route census + errors
    python tools/wirelog.py routes                  # one row per route: count, bytes, status
    python tools/wirelog.py route profile/list      # exchanges for a route, body PREVIEW
    python tools/wirelog.py route profile/list --full 4000
    python tools/wirelog.py errors                  # every err!=0 / warn / error line
    python tools/wirelog.py grep <regex>            # line-capped grep, never a 115 KB line
    python tools/wirelog.py body profile/list --path data.0._id     # one field, not the body
    python tools/wirelog.py nettrace                # socket/route census of nettrace.log
    python tools/wirelog.py nettrace --grep quest   # capped grep over nettrace

`--root PATH` picks the install (default D:\Aowlspt\aowlspt).

Rules this tool enforces on itself
----------------------------------
* No subcommand ever prints an unbounded line. `--width` (default 200) caps
  every single line; `--full N` raises the cap for bodies only, deliberately.
* No subcommand ever prints more than `--max-lines` rows (default 60); it says
  how many it dropped so you can narrow the query instead of widening the cap.
"""

import argparse
import json
import os
import re
import sys

DEFAULT_ROOT = r"D:\Aowlspt\aowlspt"

# host/backend line format: [h:mm:ss.mmm] <level>  <message>
LINE = re.compile(r"^\[(\d+:\d\d:\d\d\.\d\d\d)\] (info |warn |error|ok   )  (.*)$")

# PROBE REQ/RES <route> len=<n> body=<json>
PROBE = re.compile(
    r"^PROBE (REQ|RES)\s+(\S+)(?:\s+len=(\d+))?(?:\s+body=(.*))?$", re.S
)

# nettrace: [ticks] serve sock=N served=M tls=1 bytes=B req=[METHOD /path HTTP/1.1]
NT_SERVE = re.compile(
    r"serve sock=(\d+) served=(\d+) tls=(\d+) bytes=(\d+) req=\[(\S+) (\S+)"
)
NT_EVENT = re.compile(r"^\[(\d+)\] (\w+)")


def die(msg):
    sys.stderr.write(msg.rstrip() + "\n")
    raise SystemExit(1)


def logpath(args, which):
    name = "nettrace.log" if which == "nettrace" else "aowlspt-backend.log"
    p = args.file or os.path.join(args.root, name)
    if not os.path.isfile(p):
        die("no such log: %s\n(pass --root or --file)" % p)
    # Always name the FULL path being read. Two agents were answered about a
    # different file than they asked for, and the output showed only the
    # basename -- identical for the default and the requested log -- so nothing
    # on screen could reveal it.
    print("reading %s" % os.path.abspath(p))
    return p


def read_lines(path):
    """Read a log line-wise. Never returns the file as one blob."""
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for n, line in enumerate(fh, 1):
            yield n, line.rstrip("\r\n")


def clip(s, width):
    if s is None:
        return ""
    s = s.replace("\r", " ").replace("\n", " ")
    if len(s) <= width:
        return s
    return "%s  ...[+%d chars, use --full to see more]" % (s[:width], len(s) - width)


class Out:
    """Bounded printer. Refuses to be the thing this tool exists to prevent."""

    def __init__(self, args, width=None):
        self.width = width if width is not None else args.width
        self.max_lines = args.max_lines
        self.n = 0
        self.dropped = 0

    def __call__(self, s=""):
        if self.n >= self.max_lines:
            self.dropped += 1
            return
        self.n += 1
        print(clip(s, self.width) if self.width else s)

    def done(self):
        if self.dropped:
            print(
                "\n... %d more line(s) not shown (cap --max-lines=%d). "
                "Narrow the query rather than raising the cap."
                % (self.dropped, self.max_lines)
            )


def parse_probes(path):
    """Yield (lineno, stamp, kind, route, declared_len, body, raw_len)."""
    for n, raw in read_lines(path):
        m = LINE.match(raw)
        if not m:
            continue
        stamp, _level, msg = m.groups()
        p = PROBE.match(msg)
        if not p:
            continue
        kind, route, dlen, body = p.groups()
        yield n, stamp, kind, route, int(dlen) if dlen else None, body or "", len(raw)


# --------------------------------------------------------------------------- #


def unmangle(pat):
    """Recover a route pattern that MSYS turned into a Windows path.

    Git Bash rewrites an argument that LOOKS like a POSIX absolute path
    before the process is even spawned, so
        wirelog.py route /aowlspt/status
    arrives as 'C:/Program Files/Git/aowlspt/status'. MSYS_NO_PATHCONV=1 does
    NOT help -- the rewrite happens in the argument marshaller, not the
    shell. A route verb that cannot take a route path is a real gap, so this
    detects the rewrite and undoes it, LOUDLY (never silently: a silent
    rewrite of the user's search term is its own confidently-wrong answer).

    Returns (pattern, note-or-None).
    """
    if not pat:
        return pat, None
    m = re.match(r"^[A-Za-z]:[\\/](.*)$", pat)
    if not m:
        return pat, None
    tail = m.group(1).replace("\\", "/")
    # Drop the installation prefix MSYS prepended. Everything from the first
    # segment that is not part of a known msys/git root is the real route.
    parts = tail.split("/")
    for i, seg in enumerate(parts):
        if seg.lower() in ("msys64", "git", "usr", "mingw64", "ucrt64",
                           "program files", "program files (x86)"):
            continue
        tail = "/".join(parts[i:])
        break
    fixed = "/" + tail
    return fixed, ("MSYS path-mangling detected: the shell rewrote your "
                   "argument to %r before this tool saw it. Searching for %r "
                   "instead. (MSYS_NO_PATHCONV=1 does not prevent this; to "
                   "pass it verbatim, drop the leading slash: %r)"
                   % (pat, fixed, tail))


def cmd_routes(args):
    path = logpath(args, "backend")
    stats = {}
    for _n, _stamp, kind, route, dlen, body, raw_len in parse_probes(path):
        s = stats.setdefault(
            route, {"req": 0, "res": 0, "bytes": 0, "logged": 0, "err": 0, "max": 0}
        )
        s["req" if kind == "REQ" else "res"] += 1
        if dlen:
            s["bytes"] += dlen
            s["max"] = max(s["max"], dlen)
        s["logged"] += raw_len
        if kind == "RES" and body and '"err":0' not in body[:40]:
            s["err"] += 1
    if not stats:
        print("no PROBE lines in %s (is the wire probe enabled?)" % path)
        return 0
    out = Out(args)
    out("%-46s %4s %4s %10s %10s %5s" % ("route", "req", "res", "body B", "max B", "err"))
    for route, s in sorted(stats.items(), key=lambda kv: -kv[1]["bytes"]):
        out(
            "%-46s %4d %4d %10d %10d %5d"
            % (route[:46], s["req"], s["res"], s["bytes"], s["max"], s["err"])
        )
    out.done()
    total = sum(s["logged"] for s in stats.values())
    print("\n%d route(s); %d bytes of PROBE text in the log." % (len(stats), total))
    return 0


def cmd_route(args):
    path = logpath(args, "backend")
    width = args.full if args.full else args.preview
    out = Out(args, width=None)  # we clip bodies ourselves
    hits = 0
    for n, stamp, kind, route, dlen, body, _raw in parse_probes(path):
        if args.pattern.lower() not in route.lower():
            continue
        hits += 1
        head = "%s L%-6d %s %-3s %s" % (stamp, n, "", kind, route)
        if dlen is not None:
            head += "  len=%d" % dlen
        out(head)
        if body:
            out("    " + clip(body, width))
    out.done()
    if not hits:
        print("no route matching %r. Try: python tools/wirelog.py routes" % args.pattern)
    return 0


def cmd_body(args):
    """Extract ONE field out of the last matching response body."""
    path = logpath(args, "backend")
    last = None
    for _n, _stamp, kind, route, _dlen, body, _raw in parse_probes(path):
        if kind == "RES" and args.pattern.lower() in route.lower() and body:
            last = (route, body)
    if not last:
        die("no RES body for a route matching %r" % args.pattern)
    route, body = last
    try:
        doc = json.loads(body)
    except Exception as exc:
        die(
            "the logged body for %s is not complete JSON (%s).\n"
            "The backend truncates long bodies in the log; use the capture files "
            "with tools/bigjson.py instead." % (route, exc)
        )
    node = doc
    if args.path:
        for part in args.path.split("."):
            try:
                node = node[int(part)] if part.lstrip("-").isdigit() else node[part]
            except Exception:
                die("path %r stops at %r" % (args.path, part))
    print("%s  %s" % (route, args.path or "(root)"))
    if isinstance(node, (dict, list)):
        print("  type=%s len=%d" % (type(node).__name__, len(node)))
        if isinstance(node, dict):
            print("  keys: " + clip(", ".join(list(node)[:60]), args.width))
        else:
            print("  " + clip(json.dumps(node[:3]), args.full or args.preview))
    else:
        print("  " + clip(json.dumps(node), args.full or args.preview))
    return 0


def cmd_errors(args):
    path = logpath(args, "backend")
    out = Out(args)
    for n, raw in read_lines(path):
        m = LINE.match(raw)
        if not m:
            continue
        _stamp, level, msg = m.groups()
        bad = level.strip() in ("warn", "error")
        if not bad:
            p = PROBE.match(msg)
            bad = bool(p and p.group(1) == "RES" and '"err":0' not in (p.group(4) or "")[:40])
        if bad:
            out("L%-6d %s %s" % (n, level, msg))
    out.done()
    return 0


def cmd_grep(args):
    path = logpath(args, "nettrace" if args.nettrace else "backend")
    rx = re.compile(args.pattern, re.IGNORECASE)
    out = Out(args)
    hits = 0
    for n, raw in read_lines(path):
        if rx.search(raw):
            hits += 1
            out("L%-6d %s" % (n, raw))
    out.done()
    print("\n%d matching line(s) in %s." % (hits, os.path.basename(path)))
    return 0


def cmd_summary(args):
    path = logpath(args, "backend")
    print("== %s ==" % path)
    print("   %d bytes on disk" % os.path.getsize(path))
    head = Out(args)
    for n, raw in read_lines(path):
        if n > 14:
            break
        head(raw)
    print("\n== routes ==")
    cmd_routes(args)
    print("\n== faults ==")
    cmd_errors(args)
    return 0


def cmd_nettrace(args):
    path = logpath(args, "nettrace")
    if args.grep:
        args.pattern, args.nettrace = args.grep, True
        return cmd_grep(args)
    routes, events, socks = {}, {}, set()
    total = 0
    for _n, raw in read_lines(path):
        total += 1
        e = NT_EVENT.match(raw)
        if e:
            events[e.group(2)] = events.get(e.group(2), 0) + 1
        for m in NT_SERVE.finditer(raw):
            sock, _served, _tls, nbytes, method, route = m.groups()
            socks.add(sock)
            r = routes.setdefault("%s %s" % (method, route), {"n": 0, "bytes": 0})
            r["n"] += 1
            r["bytes"] += int(nbytes)
    print("%s: %d lines, %d bytes, %d sockets" % (path, total, os.path.getsize(path), len(socks)))
    out = Out(args)
    out("\nevents: " + ", ".join("%s=%d" % kv for kv in sorted(events.items(), key=lambda kv: -kv[1])))
    out("\n%-52s %6s %10s" % ("request", "n", "bytes"))
    for route, r in sorted(routes.items(), key=lambda kv: -kv[1]["bytes"]):
        out("%-52s %6d %10d" % (route[:52], r["n"], r["bytes"]))
    out.done()
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(
        prog="wirelog.py",
        description=__doc__.split("Why this")[0].strip(),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    # These are declared on a PARENT parser and attached to every subcommand
    # as well as the top level, because argparse otherwise accepts them ONLY
    # before the subcommand -- so the documented
    #     wirelog.py route profile/list --full 4000
    # died with "unrecognized arguments: --full 4000". Nothing about that
    # error says "move the flag left".
    # These are accepted BEFORE or AFTER the subcommand. The trap, measured
    # twice on 2026-09-01 by two different agents: with ordinary defaults, a
    # flag given BEFORE the subcommand was parsed by `ap`, and then the
    # subparser (which inherits the same options via `parents`) ran and its
    # own default `None` OVERWROTE the value. `--file X grep P` silently read
    # the DEFAULT log and printed the same basename, so nothing revealed it
    # had answered about another file -- a confidently wrong answer that once
    # nearly made an agent conclude its fix had not taken. `SUPPRESS` makes a
    # parser set the attribute only when the flag was actually given; the real
    # defaults are applied once, after parsing.
    GL_DEFAULTS = {"root": DEFAULT_ROOT, "file": None, "width": 200,
                   "max_lines": 60, "preview": 200, "full": 0}
    S = argparse.SUPPRESS
    gl = argparse.ArgumentParser(add_help=False)
    gl.add_argument("--root", default=S)
    gl.add_argument("--file", default=S, help="read this log file instead of --root/<name>")
    gl.add_argument("--width", type=int, default=S, help="hard cap per printed line")
    gl.add_argument("--max-lines", type=int, default=S, help="hard cap on rows printed")
    gl.add_argument("--preview", type=int, default=S, help="default body preview chars")
    gl.add_argument("--full", type=int, default=S, help="raise the BODY cap to N chars")
    for _a in gl._actions:
        ap._add_action(_a)
    sub = ap.add_subparsers(dest="cmd", required=True, parser_class=(
        lambda **kw: argparse.ArgumentParser(parents=[gl], **kw)))

    sub.add_parser("summary", help="boot lines + route census + faults").set_defaults(fn=cmd_summary)
    sub.add_parser("routes", help="one row per route: count, bytes, errors").set_defaults(fn=cmd_routes)
    sub.add_parser("errors", help="warn/error lines and err!=0 responses").set_defaults(fn=cmd_errors)

    p = sub.add_parser("route", help="exchanges for one route, body PREVIEW only")
    p.add_argument("pattern")
    p.set_defaults(fn=cmd_route)

    p = sub.add_parser("body", help="pull ONE field out of a response body")
    p.add_argument("pattern")
    p.add_argument("--path", help="dotted path, e.g. data.0._id")
    p.set_defaults(fn=cmd_body)

    p = sub.add_parser("grep", help="line-capped grep (never a 115 KB line)")
    p.add_argument("pattern")
    p.add_argument("--nettrace", action="store_true")
    p.set_defaults(fn=cmd_grep)

    p = sub.add_parser("nettrace", help="socket/route census of nettrace.log")
    p.add_argument("--grep", help="capped grep over nettrace.log instead")
    p.set_defaults(fn=cmd_nettrace)

    args = ap.parse_args(argv)
    for _k, _v in GL_DEFAULTS.items():
        if not hasattr(args, _k):
            setattr(args, _k, _v)
    if getattr(args, "pattern", None):
        args.pattern, note = unmangle(args.pattern)
        if note:
            print(note)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
