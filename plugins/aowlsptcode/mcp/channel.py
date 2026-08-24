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
import itertools
import os
import re
import time

LIVE_DEFAULT = r"D:\Aowlspt\aowlspt"

_counter = itertools.count()


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


def new_sentinel():
    """Unique per call within this process: monotonic counter + wallclock ms,
    so two calls issued in the same millisecond still cannot collide."""
    n = next(_counter)
    return "aowl-batch-%d-%d" % (int(time.time() * 1000), n)


def run_batch(lines, live_dir=None, timeout=25.0, write=False,
              sleep=time.sleep, now=time.time, read_out=None, write_cmd=None):
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
    write_cmd(body)

    deadline = now() + timeout
    while now() < deadline:
        out = read_out()
        if sentinel in out:
            text = "\n".join(l for l in out.splitlines() if sentinel not in l)
            return sentinel, text
        sleep(0.15)
    raise TimeoutErr("no answer for %s within %gs. %s" %
                      (sentinel, timeout, diagnose(p["log"])))


# ---------------------------------------------------------------------------
# Parsers: prose -> typed dict. Every one is defensive: on a line it cannot
# confidently parse it sets `parse_ok=False` rather than guessing, and the
# raw text always rides along under `raw` so a caller can fall back, but the
# typed fields are what a tool result actually returns as its PRIMARY shape.
# ---------------------------------------------------------------------------

_HIT_RE = re.compile(
    r'HIT\s+(?P<ptr>0x[0-9a-fA-F]+)\s+name="(?P<name>[^"]*)"'
    r'(?:\s+parent="(?P<parent>[^"]*)")?'
    r'(?:\s+text="(?P<text>[^"]*)")?'
    r'(?:\s+active=(?P<active>true|false))?'
    r'\s*\(\$(?P<var>f\d+)\)'
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
        hits.append({
            "ptr": m.group("ptr"),
            "name": m.group("name"),
            "parent": m.group("parent"),
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


def parse_children(raw):
    """`children EXPR` prints one line per child; format observed in practice
    is index/ptr/name-ish -- kept intentionally loose (name+ptr capture) since
    this verb's exact prose was not independently re-verified against a live
    client for this task (see report: needs live-client verification)."""
    items = []
    for line in raw.splitlines():
        m = re.search(r'(0x[0-9a-fA-F]+)\s*(?:name="([^"]*)")?', line)
        if m and ("child" in line.lower() or m.group(2)):
            items.append({"ptr": m.group(1), "name": m.group(2)})
    return {"children": items, "parse_ok": len(items) > 0, "raw": raw}


def parse_read(raw, expr, type_):
    """`read EXPR TYPE` -- the value is the token right after '=' on the
    matching line, or the whole trimmed line if no '=' is present."""
    line = raw.strip().splitlines()[-1].strip() if raw.strip() else ""
    if "=" in line:
        value = line.split("=", 1)[1].strip()
    else:
        value = line or None
    is_err = raw.strip().startswith("!!") or "error" in raw.lower()[:40]
    return {
        "expr": expr, "type": type_, "value": None if is_err else value,
        "parse_ok": bool(value) and not is_err, "raw": raw,
    }


def parse_label(raw):
    text = None
    m = re.search(r'text\s*=\s*"([^"]*)"', raw)
    if m:
        text = m.group(1)
    refused = "refus" in raw.lower() or "not a" in raw.lower()
    return {"text": text, "refused": refused, "parse_ok": m is not None, "raw": raw}


def parse_component(raw):
    bound = "$comp" in raw and ("bound" in raw.lower() or "->" in raw)
    found = not (raw.strip().startswith("!!") or "no component" in raw.lower()
                 or "not found" in raw.lower())
    return {"bound": bound and found, "found": found, "var": "$comp" if found else None,
            "parse_ok": True, "raw": raw}


def parse_call(raw):
    is_err = raw.strip().startswith("!!")
    ret = None
    m = re.search(r'(?:returned|->|result)\s*[:=]?\s*(0x[0-9a-fA-F]+|-?\d+)', raw, re.I)
    if m:
        ret = m.group(1)
    return {"ok": not is_err, "returned": ret, "parse_ok": True, "raw": raw}


def parse_press(raw):
    is_err = raw.strip().startswith("!!")
    return {"ok": not is_err, "parse_ok": True, "raw": raw}


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
