#!/usr/bin/env python
r"""PreToolUse guard: refuse reads that dump six figures of characters into
context.

The single failure this exists to prevent
-----------------------------------------
Several files in this project are ONE LINE. A grep that matches, a `cat`, a
`head -1`, or a `Read` without `limit` returns the WHOLE FILE. Measured:

    D:\Aowlspt\aowlspt\db.json                        41,313,127 B   1 line
    capture/raid1/responses/large/045.json            18,297,513 B   1 line
    capture/raid1/responses/large/076.json            13,252,394 B   1 line
    mods/tarkov/data/post1/locale_en.json              2,766,414 B   1 line
    mods/tarkov/data/post1/locations.json              1,907,774 B   1 line
    D:\Aowlspt\aowlspt\nettrace.log                    3,101,235 B  42,107 lines
    aowlspt-backend.log  PROBE lines up to 6,082 B each, bodies len=115,477

At ~3.5 chars/token a single unlucky `grep` is a five-figure token bill and the
information gained is zero, because nobody reads 40 MB of JSON. Every one of
these files has a summarising accessor in `tools/`, so the condition is narrow
and checkable: a READER command aimed at a MEASURED-HUGE path, with no output
cap. That is why this is a hook and the rest of the discipline is a skill.

Deliberately NOT blocked
------------------------
* Writing, copying, deleting or deploying these files. Only readers match.
* `ls`, `stat`, `wc`, `du`, `Get-Item` on them -- those are the right way to size a file.
* `aowlspt-host.log` (14 KB, 91 lines): `tail`/`grep` on it is fine; only a
  whole-file read is redirected to `tools/hostlog.py`.
* Any command that invokes one of the safe accessors, even if a huge path
  appears in the arguments -- that is exactly the intended usage.

Contract: stdin is the PreToolUse JSON payload. We emit a structured
`permissionDecision: deny` on stdout AND the reason on stderr, then exit 2, so
the block lands whichever mechanism the harness honours. Anything unexpected is
allowed through -- a guard that fires wrongly is worse than no guard.
"""

import json
import os
import re
import sys

# --------------------------------------------------------------------------- #
# 1. The measured-dangerous paths. Matched against a normalised (forward-slash,
#    lowercased) form of any path-looking token in the command.
# --------------------------------------------------------------------------- #

HUGE = [
    # (regex on normalised path, human name, the accessor to use instead)
    (r"(^|/)db\.json$", "db.json (41.3 MB, ONE line)",
     "python tools/bigjson.py keys D:/Aowlspt/aowlspt/db.json\n"
     "    python tools/bigjson.py find D:/Aowlspt/aowlspt/db.json --key <name>\n"
     "    python tools/bigjson.py get  D:/Aowlspt/aowlspt/db.json --path <a.b.c>"),
    (r"(^|/)nettrace\.log$", "nettrace.log (3.1 MB, 42,107 lines)",
     "python tools/wirelog.py nettrace            # socket/route census\n"
     "    python tools/wirelog.py nettrace --grep <term>   # capped grep"),
    (r"(^|/)aowlspt-backend\.log$", "aowlspt-backend.log (PROBE lines up to 6 KB each)",
     "python tools/wirelog.py summary             # boot + route census + faults\n"
     "    python tools/wirelog.py routes\n"
     "    python tools/wirelog.py route <route> [--full N]\n"
     "    python tools/wirelog.py grep <regex>        # line-capped"),
    (r"/data/capture/", "a raid capture payload (50 MB over 705 files; 045.json is 18.3 MB on one line)",
     "python tools/bigjson.py keys <file>         # shape, not values\n"
     "    python tools/bigjson.py get  <file> --path <a.b.c>\n"
     "    python tools/bsgwire.py scan <capture>      # classify bodies"),
    (r"/data/post1/(locale_[a-z]{2}|locations)\.json$",
     "a post1 data blob (locale_en.json 2.77 MB / locations.json 1.91 MB, ONE line each)",
     "python tools/bigjson.py keys <file>\n"
     "    python tools/bigjson.py search <file> --value <string>\n"
     "    python tools/bigjson.py get <file> --path <a.b.c>"),
]

# Whole-file reads only; tail/grep on this one are fine (it is 14 KB).
HOST_LOG = re.compile(r"(^|/)aowlspt-host\.log$")
HOST_LOG_ADVICE = (
    "python tools/hostlog.py summary          # did it boot? what broke?\n"
    "    python tools/hostlog.py faults | feature <name> | config | boot\n"
    "    python tools/hostlog.py grep <regex> | tail"
)

# Subagent JSONL transcripts. Reading one overflows context by design.
TRANSCRIPT = re.compile(r"/tasks/[0-9a-f]+\.output$|/tasks/.*\.jsonl$")

# --------------------------------------------------------------------------- #
# 2. Command classification
# --------------------------------------------------------------------------- #

# Anything that invokes a summarising accessor is always allowed, whatever
# paths appear in its arguments.
SAFE_ACCESSOR = re.compile(
    r"\btools[/\\](?:wirelog|bigjson|hostlog|bsgwire|bsgaes|metablob|il2cpp_resolve|harness|hostcfg|deploy)\.py\b",
    re.I,
)

# Whole-file readers, at a command position so that a mere mention is not a match.
CMD_POS = r"(?:^|[|&;(]|\$\(|`|\bthen\b|\bdo\b|\belse\b)\s*"
WHOLE_READER = re.compile(
    CMD_POS + r"(?:[\w./\\-]*[/\\])?"
    r"(cat|type|more|less|head|tail|bat|Get-Content|gc)\b",
    re.I,
)
GREPPER = re.compile(
    CMD_POS + r"(?:[\w./\\-]*[/\\])?"
    r"(grep|egrep|fgrep|rg|ripgrep|ag|Select-String|sls|findstr)\b",
    re.I,
)

# Flags/pipes that bound the output of a grep. If any is present the grep is
# capped and we let it through.
CAPPED = re.compile(
    r"(?:^|\s)-{1,2}(?:o|only-matching|c|count|l|files-with-matches|files-without-match"
    r"|L|max-columns|m|quiet|q|silent)\b"
    r"|--max-columns[= ]"
    r"|\|\s*head\s+-c\b"
    r"|\|\s*cut\s+-c\b"
    r"|\|\s*(?:awk|Select-Object)\b"
    r"|-List\b|-Quiet\b"
    r"|\bsubstr\(",
)

# A token that could be a path. Deliberately loose; HUGE decides what matters.
TOKEN = re.compile(r"[^\s'\"|&;<>()]+")


def normalise(tok):
    tok = tok.strip("'\"")
    return tok.replace("\\", "/").lower()


def _grep_pattern_spans(text):
    """Spans of the SEARCH PATTERN of each grep in `text`.

    A grep's pattern is not a file it reads. `grep -n "db.json" some_hook.py`
    reads nothing of db.json, and blocking it is a false positive that has cost
    real time -- an agent could not locate the file and had to learn its path
    from the block message itself.

    The pattern is the first non-flag token after the grep verb. This only ever
    REMOVES that one token from consideration, so a genuine target beside it is
    still caught.
    """
    spans = []
    for m in GREPPER.finditer(text):
        i = m.end()
        for tok in TOKEN.finditer(text, i):
            s = tok.group()
            if s.startswith("-"):
                continue  # a flag, not the pattern
            spans.append((tok.start(), tok.end()))
            break
    return spans


def huge_hits(text, ignore_spans=()):
    """Return [(name, advice)] for every measured-huge path in the text."""
    hits, seen = [], set()
    for tok in TOKEN.finditer(text):
        if any(a <= tok.start() < b for a, b in ignore_spans):
            continue
        p = normalise(tok.group())
        for rx, name, advice in HUGE:
            if re.search(rx, p) and name not in seen:
                seen.add(name)
                hits.append((name, advice))
    return hits


def block(reason):
    payload = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }
    sys.stdout.write(json.dumps(payload))
    sys.stderr.write(reason + "\n")
    return 2


def refusal(what, why, instead):
    return (
        "BLOCKED (context bomb): %s\n\n%s\n\n"
        "Run this INSTEAD:\n\n    %s\n\n"
        "If you genuinely need more of it, the accessors take --full N / --max-lines N.\n"
        "See the `token-discipline` skill." % (what, why, instead)
    )


# --------------------------------------------------------------------------- #


def check_bash(command):
    if not command.strip():
        return 0

    text = command
    norm = normalise(text)

    if TRANSCRIPT.search(norm):
        return block(refusal(
            "reading a subagent transcript under the tasks directory",
            "Those .output files are the full subagent JSONL -- tens of thousands of\n"
            "tokens of tool traffic you already have the conclusion for.",
            "wait for the completion notification; it carries the agent's report.",
        ))

    if SAFE_ACCESSOR.search(text):
        return 0

    reads_whole = bool(WHOLE_READER.search(text))
    greps = bool(GREPPER.search(text))
    if not (reads_whole or greps):
        return 0  # writing/copying/sizing these files is fine

    hits = huge_hits(text, _grep_pattern_spans(text) if greps else ())
    if hits:
        name, advice = hits[0]
        if greps and not reads_whole and CAPPED.search(text):
            return 0  # a capped grep cannot return the whole line
        why = (
            "That file is measured huge and single-line-heavy: one match returns\n"
            "the whole thing. %s" % name
        ) if greps and not reads_whole else (
            "%s -- a whole-file read of it is the single largest avoidable\n"
            "context cost in this project." % name
        )
        return block(refusal("%s on %s" % ("grep" if greps and not reads_whole else "a whole-file read", name), why, advice))

    if reads_whole:
        # aowlspt-host.log: only cat/Get-Content (no line bound) is redirected.
        for tok in TOKEN.findall(text):
            if HOST_LOG.search(normalise(tok)):
                if re.search(r"-(?:n|c)\s*\d|--?(?:Tail|TotalCount|First|Last)\b|\btail\b|\bhead\b", text, re.I):
                    return 0  # bounded read of a 14 KB file: fine
                return block(refusal(
                    "a whole-file read of aowlspt-host.log",
                    "The host log is the only channel out of the client and gets re-read\n"
                    "every cycle. hostlog.py answers the same four questions in a fraction\n"
                    "of the size, and separates self-disabled features from mere warnings.",
                    HOST_LOG_ADVICE,
                ))
    return 0


def check_read(tool_input):
    path = tool_input.get("file_path")
    if not isinstance(path, str):
        return 0
    p = normalise(path)

    if TRANSCRIPT.search(p):
        return block(refusal(
            "Read of a subagent transcript under the tasks directory",
            "Those .output files are the full subagent JSONL and will overflow context.",
            "wait for the completion notification; it carries the agent's report.",
        ))

    for rx, name, advice in HUGE:
        if re.search(rx, p):
            if tool_input.get("limit") and tool_input.get("offset") is not None:
                # An explicit window is a deliberate act -- but on a ONE-LINE file
                # a window of 1 line is still the whole file.
                try:
                    size = os.path.getsize(path)
                except OSError:
                    size = 0
                if size and size > 512 * 1024 and _one_line(path):
                    return block(refusal(
                        "Read of %s" % name,
                        "offset/limit does not help: this file is a SINGLE LINE, so any\n"
                        "window of >=1 line is the entire %d-byte file." % size,
                        advice,
                    ))
                return 0
            return block(refusal(
                "Read of %s without offset+limit" % name,
                "Read ingests as much of the file as fits, and this one is far larger\n"
                "than any useful answer.",
                advice,
            ))
    return 0


def _one_line(path):
    try:
        with open(path, "rb") as fh:
            return b"\n" not in fh.read(1 << 20)
    except OSError:
        return False


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0  # unparseable input is not grounds for blocking

    tool = payload.get("tool_name")
    ti = payload.get("tool_input") or {}
    try:
        if tool in ("Bash", "PowerShell"):
            cmd = ti.get("command")
            return check_bash(cmd) if isinstance(cmd, str) else 0
        if tool == "Read":
            return check_read(ti)
    except Exception:
        return 0  # never let a bug in this guard block ordinary work
    return 0


if __name__ == "__main__":
    sys.exit(main())
