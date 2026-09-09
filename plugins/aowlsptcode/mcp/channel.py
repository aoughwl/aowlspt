#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""channel.py -- the sentinel-guarded write/poll transport for the aowlspt
live inspector's file channel, plus parsers that turn its prose answers into
typed structures.

This is deliberately import-only (no stdio JSON-RPC here) so it can be unit
tested without a live game: `run_batch` takes an injectable `now`/`sleep`/
`read_out`/`write_cmd` so tests can fake the file channel entirely, and every
`parse_*` function operates on a plain string, no I/O at all.

STALENESS GUARANTEE (this is the property the whole task is about):
Every batch gets a per-call unique sentinel derived from a monotonic counter
plus wall clock, never reused within a process, and the sentinel is echoed
back as the LAST line of the batch (`echo aowl-batch-<serial>-<nonce>`). A
caller only accepts an out-file body if it contains that exact sentinel
string; anything else (old content, a different batch's answer, a partial
write) is treated as "no answer yet" and polled again, or as a timeout if the
deadline passes. Nothing is ever returned that is not provably the response
to the batch just sent -- there is no code path that reads the out-file and
hands its content back without checking for the current sentinel first.
"""
import errno
import hashlib
import itertools
import os
import re
import sys
import tempfile
import time

LIVE_DEFAULT = r"D:\Aowlspt\aowlspt"

_counter = itertools.count()


# ---------------------------------------------------------------------------
# SINGLE-WRITER DISCIPLINE
#
# MEASURED 2026-08-31: `tools/enterraid.py` and the aowlspt MCP inspector wrote
# the command file concurrently and dropped each other's batches -- the symptom
# was `inspector dropped a 1-command batch` on one side and a timeout on the
# other. The channel is ONE file with no protocol for two writers: B's write
# replaces A's before the host has read it, and A then waits out its whole
# timeout for an answer to a batch the host never saw.
#
# The sentinel already guarantees nobody READS a stale answer (see the module
# docstring). This adds the other half: only one process writes at a time.
#
# The lock lives in the SYSTEM TEMP DIR keyed by a hash of the live path, not in
# the live install -- a human may be mid-raid and this module has no business
# creating files next to the game. It is advisory (a cooperating writer that
# does not use channel.py is unaffected) and it self-heals: a lock older than
# LOCK_STALE_S is broken, because a crashed holder must not wedge the channel
# forever. Both facts are stated in the message when it gives up, so a lock
# contention never reads as a host fault.
# ---------------------------------------------------------------------------

LOCK_STALE_S = 180.0


def lock_path(live_dir=None):
    live = live_dir or os.environ.get("AOWLSPT_LIVE", LIVE_DEFAULT)
    h = hashlib.sha1(os.path.abspath(live).lower().encode("utf-8")).hexdigest()[:12]
    return os.path.join(tempfile.gettempdir(), "aowlspt-inspect-%s.lock" % h)


class _Lock(object):
    """A cross-process advisory lock over the file channel."""

    def __init__(self, path, timeout=60.0, now=time.time, sleep=time.sleep):
        self.path = path
        self.timeout = timeout
        self.now = now
        self.sleep = sleep
        self.held = False

    def __enter__(self):
        deadline = self.now() + self.timeout
        while True:
            try:
                fd = os.open(self.path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
                os.write(fd, ("%d %f\n" % (os.getpid(), time.time())).encode())
                os.close(fd)
                self.held = True
                return self
            except OSError as e:
                if e.errno != errno.EEXIST:
                    # Cannot lock at all (no temp dir, permissions). Say so and
                    # proceed unlocked rather than refusing to talk to the host;
                    # an unlocked write is what we did before, not a regression.
                    self.held = False
                    return self
            try:
                age = time.time() - os.path.getmtime(self.path)
            except OSError:
                age = 0.0
            if age > LOCK_STALE_S:
                try:
                    os.unlink(self.path)      # holder died; break it
                except OSError:
                    pass
                continue
            if self.now() >= deadline:
                holder = ""
                try:
                    with open(self.path) as f:
                        holder = f.read().strip()
                except OSError:
                    pass
                raise ChannelBusy(
                    "another process has held the inspector channel for %.0fs "
                    "(lock %s, holder %r). This is NOT a host fault and NOT a "
                    "timeout: two writers to one command file drop each "
                    "other's batches, so this one refused to write rather than "
                    "clobber theirs. A lock older than %.0fs is broken "
                    "automatically." % (age, self.path, holder, LOCK_STALE_S))
            self.sleep(0.1)

    def __exit__(self, *exc):
        if self.held:
            try:
                os.unlink(self.path)
            except OSError:
                pass
        return False


class InspectorError(Exception):
    """Base for all typed-error conditions this module raises. Every one of
    these must become a structured `error` field in the MCP tool result, not
    prose folded into a normal answer."""
    kind = "unknown"


class TimeoutErr(InspectorError):
    kind = "timeout"


class ChannelMissing(InspectorError):
    kind = "channel_missing"


class WriteNotAllowed(InspectorError):
    kind = "write_not_allowed"


class ChannelBusy(InspectorError):
    """Another process holds the single-writer lock over the file channel.

    DISTINCT from TimeoutErr on purpose: a timeout means the HOST did not
    answer; this means WE declined to write because someone else was mid-batch.
    Collapsing the two would blame the host for a shell-side collision."""
    kind = "channel_busy"


def paths(live_dir=None):
    live = live_dir or os.environ.get("AOWLSPT_LIVE", LIVE_DEFAULT)
    return {
        "live": live,
        "cmd": os.path.join(live, "aowlspt-inspect.txt"),
        "out": os.path.join(live, "aowlspt-inspect-out.txt"),
        "log": os.path.join(live, "aowlspt-host.log"),
    }


def _read(path):
    try:
        with open(path, "rb") as f:
            return f.read().decode("utf-8", "replace").lstrip("\ufeff")
    except OSError:
        return ""


def _write_cmd_file(path, body):
    # Byte write, no BOM, LF endings -- see CLAUDE.md section 2. This is the
    # one write in the whole module that touches the live channel.
    with open(path, "wb") as f:
        f.write(body.encode("utf-8"))


def diagnose(log_path, read=_read):
    log = read(log_path)
    if not log:
        return "the host log is absent or empty -- the host is not running."
    hits = [l.strip() for l in log.splitlines() if "live inspector" in l]
    if not hits:
        return ("the host log never mentions the live inspector at all -- " +
                "the `liveInspector` flag is likely off in aowlspt-host.json.")
    return "last of what the host said about the channel: " + " | ".join(hits[-3:])


def writer_tag():
    """A short, filesystem-derived name for THIS process, for the sentinel.

    `tools/ichannel.py` re-exports this module, so acceptance.py,
    nativetabs_check.py, inspector.py and the MCP server are all the same
    transport -- a hardcoded "mcp" would put the wrong writer's name in the
    host log, which is worse than no name. The tag is the running script's
    basename (`server.py` -> `mcp`, the name the tool surface is known by),
    sanitised to [a-z0-9] so it can never break the sentinel's tokenisation.
    """
    try:
        base = os.path.basename(sys.argv[0] or "")
    except Exception:
        base = ""
    base = os.path.splitext(base)[0].lower()
    if base in ("server", ""):
        base = "mcp"
    clean = "".join(c for c in base if c.isalnum())[:12]
    return clean or "py"


def new_sentinel():
    """Unique per call within this process: monotonic counter + wallclock ms,
    so two calls issued in the same millisecond still cannot collide.

    WRITER ATTRIBUTION. The tag `mcp<pid>` is in the sentinel deliberately,
    because the sentinel is the ONE part of a batch that reaches the host log:
    the host echoes every command it runs (`> echo aowl-batch-...`) and SKIPS
    `#`-prefixed serial lines without logging them (inspect.nim: "`#`-prefixed
    serial lines are skipped by design"), so a writer tag put only on the
    serial line would be invisible exactly where it is needed.

    Measured 2026-09-02, and this is what the tag is for: 9 unattributed
    batches ran in the first 23s of a client boot and had to be traced to a
    writer by the SHAPE of their sentinel (`aowl-batch-<6 digits>`, i.e.
    `tools/aowlui.nim`'s `nowMs() mod 1000000`) rather than by anything the
    log said. An attributed sentinel makes that a grep instead of an
    investigation."""
    n = next(_counter)
    return "aowl-batch-%s%d-%d-%d" % (writer_tag(), os.getpid(),
                                      int(time.time() * 1000), n)


def run_batch(lines, live_dir=None, timeout=25.0, write=False,
              sleep=time.sleep, now=time.time, read_out=None, write_cmd=None,
              lock=True):
    """Send one batch through the file channel and return (sentinel, raw_text).

    raw_text has the sentinel echo line already stripped. Raises TimeoutErr,
    ChannelMissing, or WriteNotAllowed(caller's responsibility to set `write`)
    on failure -- never returns a body that does not contain the sentinel.
    """
    p = paths(live_dir)
    read_out = read_out or (lambda: _read(p["out"]))
    write_cmd = write_cmd or (lambda body: _write_cmd_file(p["cmd"], body))

    if live_dir is None and not os.path.isdir(p["live"]):
        raise ChannelMissing("%s does not exist" % p["live"])

    body_lines = (["allow write"] if write else []) + list(lines)
    sentinel = new_sentinel()
    body = "#%s\n" % sentinel + "\n".join(body_lines) + "\necho %s\n" % sentinel

    # The lock spans the WHOLE write-then-poll window, not just the write: a
    # second writer landing between our write and the host's read is exactly the
    # dropped-batch case. `lock=False` is the escape hatch for tests.
    lk = (_Lock(lock_path(live_dir), timeout=timeout) if lock
          else _nolock())
    with lk:
        write_cmd(body)
        deadline = now() + timeout
        while now() < deadline:
            out = read_out()
            if sentinel in out:
                text = "\n".join(l for l in out.splitlines()
                                 if sentinel not in l)
                return sentinel, text
            sleep(0.15)
    raise TimeoutErr("no answer for %s within %gs. %s" %
                      (sentinel, timeout, diagnose(p["log"])))


class _nolock(object):
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


# ---------------------------------------------------------------------------
# Parsers: prose -> typed dict. Every one is defensive: on a line it cannot
# confidently parse it sets `parse_ok=False` rather than guessing, and the
# raw text always rides along under `raw` so a caller can fall back, but the
# typed fields are what a tool result actually returns as its PRIMARY shape.
# ---------------------------------------------------------------------------

# ONE regex for BOTH verbs' HIT lines. Measured shapes on this build
# (tools/fixtures/inspector/find.txt, findtext.txt -- verbatim host text):
#
#   find:      HIT 0x000001b0e84eb060 name="Preloader UI"   ($f1)
#   find:      HIT 0x000001b0e84e4200 name="TaskBar"  parent="Content"   ($f1)
#   findtext:  HIT 0x00000203094ddf60  name="Text"  parent="Settings Drop
#              Down(Clone)"  text="Interface language"  activeInHierarchy=true   ($f1)
#   findtext:  HIT 0x0000013be6206440  name="Text"  parent="LoadingSpinner"
#              text="Loading..."  activeInHierarchy=FALSE (unpressable)   ($f1)
#
# The previous pattern spelled the flag `active=` and then required `($fN)`
# immediately after `text="..."`. The host emits `activeInHierarchy=`, so the
# optional flag group never matched, the literal flag text sat between `text=`
# and `($fN)`, and the WHOLE line failed -- `parse_find`/`parse_findtext` (and
# so the MCP `inspect_findtext` tool) returned ZERO hits for every findtext
# answer, which is a search that cannot find. Fixed 2026-09-02 against the
# corpus; `tests/test_channel.py` now replays every recorded HIT line and
# asserts the count against the host's own `K match(es)` line.
#
# Notes on the shape, each load-bearing:
#  * `activeInHierarchy` is matched BEFORE the legacy `active` alternative and
#    the alternation is anchored with `=`, so `active=` cannot swallow the
#    prefix of `activeInHierarchy=`. The legacy spelling is kept because it
#    costs nothing and older recordings use it.
#  * the tail is `[^\n]*?` and not `\s*`: an INACTIVE hit prints
#    `activeInHierarchy=FALSE (unpressable)   ($f1)`, so the run-up to the
#    binding legitimately contains parentheses. `[^\n]` (not `.` under any
#    flag) makes it impossible for one HIT to reach across a line into the
#    NEXT line's `($fN)`.
#  * `\bHIT` so a word ending in HIT cannot start a match.
_HIT_RE = re.compile(
    r'\bHIT\s+(?P<ptr>0x[0-9a-fA-F]+)\s+name="(?P<name>[^"]*)"'
    r'(?:\s+parent="(?P<parent>[^"]*)")?'
    r'(?:\s+text="(?P<text>[^"]*)")?'
    r'(?:\s+(?:activeInHierarchy|active)=(?P<active>[Tt][Rr][Uu][Ee]|[Ff][Aa][Ll][Ss][Ee]))?'
    r'[^\n]*?\(\$(?P<var>f\d+)\)'
)

_INACTIVE_SKIPPED_RE = re.compile(r'(?P<n>\d+)\s+inactive.*skipped', re.I)


def _completeness(text):
    """EXHAUSTIVE vs STOPPED EARLY vs NOTHING EXAMINED vs hit-cap, from the
    shared `iFindReportGeneric` prose contract (inspect.nim ~1786-1838).
    Returns one of these exact strings -- never collapsed to a bool -- plus
    whether the result is safe to read as a negative ("genuinely NOT PRESENT").
    """
    low = text.lower()
    if "nothing was examined" in low:
        return "NOTHING_EXAMINED", False
    if "searched exhaustively" in low:
        return "EXHAUSTIVE", True
    if "stopped at the match cap" in low:
        return "HIT_CAP", False
    if "stopped early" in low:
        return "STOPPED_EARLY", False
    return "UNKNOWN", False


def parse_find(raw):
    """find / find more -> {hits: [...], completeness, exhaustive, can_trust_absence,
    visited, resumable, parse_ok, raw}"""
    hits = []
    for m in _HIT_RE.finditer(raw):
        a = m.group("active")
        hits.append({
            "ptr": m.group("ptr"),
            "name": m.group("name"),
            "parent": m.group("parent"),
            "text": m.group("text"),
            # THREE-state on purpose: True / False / None. `find` prints no
            # flag at all, and None means "not known whether anything renders
            # this", which is not the same as inactive. Fact #72: pressing an
            # inactive node returns success and does nothing.
            "active": None if a is None else a.lower() == "true",
            "var": "$" + m.group("var"),
        })
    completeness, can_trust_absence = _completeness(raw)
    visited_m = re.search(r'visited (\d+) node', raw)
    return {
        "hits": hits,
        "completeness": completeness,
        "can_trust_absence": can_trust_absence,
        "resumable": completeness in ("STOPPED_EARLY", "HIT_CAP"),
        "visited": int(visited_m.group(1)) if visited_m else None,
        "parse_ok": completeness != "UNKNOWN" or bool(hits),
        "raw": raw,
    }


def parse_findtext(raw):
    """findtext -> same shape as parse_find, plus explicit
    include_inactive/inactive_skipped fields -- the includeInactive scope
    must survive as data, never be silently folded into the hit list."""
    base = parse_find(raw)
    inactive_m = _INACTIVE_SKIPPED_RE.search(raw)
    base["inactive_skipped"] = int(inactive_m.group("n")) if inactive_m else 0
    base["scope"] = ("ALL_ACTIVE_AND_INACTIVE" if "ALL nodes, active and inactive" in raw
                      else "ACTIVE_ONLY" if "ACTIVE nodes only" in raw
                      else "UNKNOWN")
    return base


_ROOTS_BOUND_RE = re.compile(
    r'(?P<n>\d+)\s+root\(s\)\s+bound\s+to\s+\$r0\.\.\$r(?P<last>\d+)'
)


def parse_roots(raw):
    m = _ROOTS_BOUND_RE.search(raw)
    n = int(m.group("n")) if m else None
    roots = []
    if n:
        for i in range(n):
            roots.append({"transform_var": "$r%d" % i, "gameobject_var": "$rgo%d" % i})
    return {
        "count": n,
        "roots": roots,
        "parse_ok": m is not None,
        "raw": raw,
    }


def _has_err_line(raw):
    """`iErr` (inspect.nim:635) emits `iOut("  ! " & s)` -- every failure line
    is `!`, single, after the two-space indent iOut adds. Checked stripped-
    per-line, never `.startswith("!!")` (that string never occurs)."""
    return any(l.strip().startswith("!") for l in raw.splitlines())


_PARENT_LINE_RE = re.compile(
    r'\[(?P<level>\d+)\]\s+transform=(?P<ptr>0x[0-9a-fA-F]+)\s+'
    r'klass=(?P<klass>0x[0-9a-fA-F]+)'
    r'(?:\s+name="(?P<name>[^"]*)")?'
    r'(?:\s+go=(?P<go>0x[0-9a-fA-F]+)\s+activeSelf=(?P<active>true|false))?'
)


def parse_parent(raw):
    """`parent EXPR [DEPTH]` (iCmdParent, inspect.nim:1066) prints, per
    level: `    [N] transform=0xPTR klass=0xKLASS name="X" go=0xPTR
    activeSelf=true/false` -- a DIFFERENT shape from `children` (klass= and
    activeSelf=, no $cN/$gN anchors are bound by this verb at all) so it
    cannot share `parse_children`'s regex, which requires the `($cN)`
    anchor group that `parent` never emits. Terminates either with
    `(null parent -- this is the hierarchy root)` or `... stopped at depth N`."""
    items = []
    for line in raw.splitlines():
        m = _PARENT_LINE_RE.search(line)
        if m:
            items.append({
                "level": int(m.group("level")),
                "ptr": m.group("ptr"),
                "klass": m.group("klass"),
                "name": m.group("name"),
                "go": m.group("go"),
                "active_self": (m.group("active") == "true") if m.group("active") else None,
            })
    reached_root = "hierarchy root" in raw
    return {
        "levels": items,
        "reached_root": reached_root,
        "parse_ok": bool(items) or reached_root,
        "raw": raw,
    }


_CHILD_LINE_RE = re.compile(
    r'\[(?P<idx>\d+)\]\s+transform=(?P<ptr>0x[0-9a-fA-F]+)\s+\(\$c\d+\)'
    r'(?:\s+go=(?P<go>0x[0-9a-fA-F]+)\s+\(\$g\d+\))?'
    r'\s+name="(?P<name>[^"]*)"'
)


def parse_children(raw):
    """`children EXPR` (iCmdChildren, inspect.nim:1601) prints, per child:
    `    [i] transform=0xPTR ($cN)  go=0xPTR ($gN)  name="X"` -- or
    `    [i] <child not readable>`. Corrected against the real emit site;
    the previous regex looked for `name="..."` immediately after the first
    hex token, which is the transform pointer, so it never matched (the name
    is several tokens later, past `go=`) and this verb effectively always
    returned an empty list."""
    items = []
    for line in raw.splitlines():
        m = _CHILD_LINE_RE.search(line)
        if m:
            items.append({
                "index": int(m.group("idx")),
                "ptr": m.group("ptr"),
                "go": m.group("go"),
                "name": m.group("name"),
            })
        elif "not readable" in line and re.search(r'\[\d+\]', line):
            idx_m = re.search(r'\[(\d+)\]', line)
            items.append({"index": int(idx_m.group(1)) if idx_m else None,
                           "ptr": None, "go": None, "name": None,
                           "unreadable": True})
    count_m = re.search(r'childCount\s*=\s*(\d+)', raw)
    return {
        "children": items,
        "child_count": int(count_m.group(1)) if count_m else None,
        "parse_ok": bool(items) or "no children" in raw.lower(),
        "raw": raw,
    }


_TREE_LINE_RE = re.compile(
    r'^(?P<indent>\s*)(?P<plus>\+\s+)?"(?P<name>[^"]*)"\s+'
    r'(?P<ptr>0x[0-9a-fA-F]+)(?:\s+\((?P<nchild>\d+)\s+child\))?'
)


def parse_tree(raw):
    """`tree EXPR [DEPTH]` (iCmdTree, inspect.nim:2568) prints one line per
    node: `    ["+ "]"Name"  0xPTR  (N child)`, a shape entirely unlike
    `children` (no `transform=`/`name=` keys at all -- it is positional:
    quoted name, then pointer, then an optional child count in parens).
    Previously this verb was routed through `parse_children`, whose regex
    requires a `name="..."` key that tree's format never emits, so `tree`
    always came back with an empty item list regardless of what was on
    screen. Depth is inferred from indentation width and the leading `+ `."""
    items = []
    for line in raw.splitlines():
        m = _TREE_LINE_RE.match(line)
        if m:
            items.append({
                "name": m.group("name"),
                "ptr": m.group("ptr"),
                "child_count": int(m.group("nchild")) if m.group("nchild") else None,
                "is_root": m.group("plus") is None,
            })
    nodes_m = re.search(r'(\d+)\s+node\(s\)\s+printed', raw)
    truncated = "STOPPED EARLY" in raw
    return {
        "nodes": items,
        "node_count": int(nodes_m.group(1)) if nodes_m else len(items),
        "truncated": truncated,
        "complete": ("-- complete." in raw) and not truncated,
        "parse_ok": bool(items),
        "raw": raw,
    }


def parse_read(raw, expr, type_):
    """`read EXPR TYPE` (inspect.nim ~3982) prints
    `  0xPTR as TYPE = VALUE` on success, or a `  ! ...` error line via
    `iErr`. Value is the token after '=' on the matching `as TYPE =` line."""
    is_err = _has_err_line(raw)
    value = None
    for line in raw.splitlines():
        if " as " in line and "=" in line:
            value = line.split("=", 1)[1].strip()
    return {
        "expr": expr, "type": type_, "value": None if is_err else value,
        "parse_ok": (value is not None) or is_err, "raw": raw,
    }


def parse_label(raw):
    """`label EXPR` (iCmdLabel, inspect.nim:3031) prints
    `  text = "..."` on success, or a `  ! ...` refusal (e.g. "that is a
    TRANSFORM", "not a TMP_Text") via iErr."""
    text = None
    m = re.search(r'text\s*=\s*"([^"]*)"', raw)
    if m:
        text = m.group(1)
    refused = _has_err_line(raw)
    return {"text": text, "refused": refused, "parse_ok": m is not None or refused, "raw": raw}


def parse_component(raw):
    """`component EXPR TypeName` (iCmdComponent, inspect.nim:2654). Success:
    `  FOUND TypeName component = 0xPTR  klass=0xKLASS   ($comp)`. Failure is
    NOT always an `iErr` line -- a genuine "no such component" answer is
    `iErr("GetComponent returned NULL -- this is an ANSWER, not a crash...")`
    which DOES start with `!` (so _has_err_line catches it), but the old
    parser also required the literal substring "bound" or "->" to declare
    `bound`, which the real FOUND line never contains -- so it reported
    found=True, bound=False on every real success. Now `bound` follows
    `found` directly, both from the FOUND anchor string."""
    found = bool(re.search(r'\bFOUND\b.*\(\$comp\)', raw))
    is_err = _has_err_line(raw)
    return {"bound": found and not is_err, "found": found and not is_err,
            "var": "$comp" if found and not is_err else None,
            "parse_ok": True, "raw": raw}


_CALL_VOID_RE = re.compile(r'->\s*returned without faulting \(void\)')
_CALL_BOOL_RE = re.compile(r'->\s*bool\s+(true|false)')
_CALL_I32_RE = re.compile(r'->\s*i32\s+(-?\d+)')
_CALL_I64_RE = re.compile(r'->\s*i64\s+(-?\d+)\s*\((0x[0-9a-fA-F]+)\)')
_CALL_F32_RE = re.compile(r'->\s*f32\s+(-?[\d.]+(?:e[+-]?\d+)?)', re.I)
_CALL_STR_RE = re.compile(r'->\s*String\*\s+(0x[0-9a-fA-F]+)\s*=\s*"([^"]*)"')
_CALL_PTR_RE = re.compile(
    r'->\s*ptr\s+(0x[0-9a-fA-F]+)'
    r'(\s+NULL|\s+NOT readable|\s+readable, klass=(0x[0-9a-fA-F]+)\s*\(bound to \$_\))?'
)


def parse_call(raw):
    """`call TARGET SIG [ARGS]` (iCmdCall, inspect.nim:3619). Every return
    kind (`v`,`b`,`i`,`l`/`u`,`f`,`s`,`p`) has its own `-> ...` shape, e.g.
    `-> ptr 0xPTR  readable, klass=0xK   (bound to $_)` or
    `-> i64 N (0xHEX)` or `-> String* 0xPTR = "text"`. The previous regex
    (`(?:returned|->|result)\\s*[:=]?\\s*(hex|digit)`) required the numeric
    token to sit IMMEDIATELY after `->`/`:`/`=`, but every real line has a
    type-name word (`ptr`, `i64`, `bool`, ...) in between, so it matched
    almost nothing that this verb actually prints. Replaced with one regex
    per emitted shape, keyed off the actual retKind switch in iCmdCall."""
    is_err = _has_err_line(raw)
    ret_type, returned = None, None
    if _CALL_VOID_RE.search(raw):
        ret_type, returned = "void", None
    elif (m := _CALL_BOOL_RE.search(raw)):
        ret_type, returned = "bool", m.group(1)
    elif (m := _CALL_I64_RE.search(raw)):
        ret_type, returned = "i64", m.group(2)
    elif (m := _CALL_I32_RE.search(raw)):
        ret_type, returned = "i32", m.group(1)
    elif (m := _CALL_F32_RE.search(raw)):
        ret_type, returned = "f32", m.group(1)
    elif (m := _CALL_STR_RE.search(raw)):
        ret_type, returned = "string", m.group(2)
    elif (m := _CALL_PTR_RE.search(raw)):
        ret_type, returned = "ptr", m.group(1)
    return {"ok": not is_err, "ret_type": ret_type, "returned": returned,
            "parse_ok": (ret_type is not None) or is_err, "raw": raw}


def parse_press(raw):
    """`press EXPR [OFFSET]` (iCmdPress, inspect.nim:3171) has no dedicated
    success token -- on success the last output line is
    `  returned without faulting.` after printing the target's OnClick
    slot; any refusal path (`null pointer`, `not readable`, `slot is NULL`,
    `holds a GAMEOBJECT`, ...) is an `iErr` `  ! ...` line. `ok` now reflects
    the real absence of an error line, not a `!!` sentinel that iErr never
    emits."""
    is_err = _has_err_line(raw)
    fired = "returned without faulting" in raw
    return {"ok": not is_err and fired, "fired": fired, "parse_ok": True, "raw": raw}


FACTS_DB_DEFAULT = os.path.expandvars(r"%USERPROFILE%\.aowl\facts.db")


class RecipeNotFound(InspectorError):
    kind = "recipe_not_found"


def load_recipe(name, db_path=None):
    """Read-only lookup into the aowlfacts SQLite store's `recipe` table.
    `steps_json` is a plain JSON array of raw inspector command lines
    (comments starting with '#' allowed, stripped before sending). Returns
    (description, steps). Raises RecipeNotFound if absent."""
    import json
    import sqlite3
    path = db_path or FACTS_DB_DEFAULT
    if not os.path.isfile(path):
        raise RecipeNotFound("fact store not found at %s" % path)
    conn = sqlite3.connect("file:%s?mode=ro" % path, uri=True)
    try:
        row = conn.execute(
            "select description, steps_json, status from recipe where name = ?",
            (name,)).fetchone()
    finally:
        conn.close()
    if row is None:
        raise RecipeNotFound("no recipe named %r in the fact store" % name)
    description, steps_json, status = row
    steps = [s for s in json.loads(steps_json) if not s.strip().startswith("#")]
    return description, steps, status


def parse_state(raw):
    """`state` -- free-form status prose. No stable structured schema is
    known for this verb (not independently re-verified for this task), so
    this returns the raw text as the primary payload with parse_ok=False,
    honestly, rather than inventing fields that would silently be wrong."""
    return {"parse_ok": False, "raw": raw}
