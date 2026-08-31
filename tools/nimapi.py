#!/usr/bin/env python3
"""nimapi.py -- extract the exported API out of Nim/nimony source.

This exists because a hand-written API reference drifts, silently, and reads as
authoritative the whole time it is wrong. Everything the docs site says about a
signature is therefore lifted out of the source file it lives in, and printed
with the `file:line` it came from, so a reader can check it.

It is a lexical extractor, not a compiler front end. That is a deliberate
trade: `aowl/src/aowlspt/*.nim` is nimony, so there is no `nim doc` to lean on,
and a lexical pass over a file we control is honest as long as it SAYS when it
could not parse something. It never invents a signature -- an entry it cannot
read back is dropped and counted, and the count is printed on the page.

What it finds:

  * routines  -- `proc` / `func` / `template` / `macro` / `iterator` /
                 `converter` / `method` declared at column 0 and EXPORTED
                 (a `*` on the name). Unexported symbols are deliberately
                 excluded: they are not API.
  * types     -- exported entries inside a `type` block, with their body.
  * consts    -- exported entries inside a `const` block.
  * module doc -- the leading `##` block, if the file opens with one.

Overloads are kept separate and NOT merged, because in this codebase the
overloads differ in behaviour (`server.put` has five), and collapsing them
would hide exactly the thing a caller needs to choose between.
"""

import os
import re

ROUTINE_KINDS = ("proc", "func", "template", "macro", "iterator",
                 "converter", "method")

# Column 0, a routine keyword, then a name carrying an export marker. The name
# may be an operator in backticks (`` `==` ``), which this codebase uses.
ROUTINE_RE = re.compile(
    r"^(%s)\s+(`[^`]+`|[A-Za-z_][A-Za-z0-9_]*)\*" % "|".join(ROUTINE_KINDS))

# Inside a `type` / `const` block: two-space indent, an exported name.
MEMBER_RE = re.compile(r"^  (`[^`]+`|[A-Za-z_][A-Za-z0-9_]*)\*\s*(\{\.|[:=*])")


def _strip_code(line):
    """Blank out string/char literals and the trailing comment.

    Depth counting is the whole basis of finding where a signature ends, so a
    `)` inside a string or a `#` inside one must not be seen. Cheap and
    sufficient for this source; it does not attempt triple-quoted strings,
    which none of these signatures contain.
    """
    out, i, n = [], 0, len(line)
    while i < n:
        c = line[i]
        if c == '"':
            j = i + 1
            while j < n:
                if line[j] == "\\":
                    j += 2
                    continue
                if line[j] == '"':
                    break
                j += 1
            out.append(" " * (min(j, n - 1) - i + 1))
            i = j + 1
            continue
        if c == "'":
            j = i + 1
            while j < n and line[j] != "'":
                j += 2 if line[j] == "\\" else 1
            out.append(" " * (min(j, n - 1) - i + 1))
            i = j + 1
            continue
        if c == "#":
            out.append(" " * (n - i))
            break
        out.append(c)
        i += 1
    return "".join(out)


def _depth(text):
    d = 0
    for c in text:
        if c in "([{":
            d += 1
        elif c in ")]}":
            d -= 1
    return d


def _top_level_eq(text):
    """Index of the `=` that opens the body, or -1.

    Must skip `==`, `<=`, `>=`, `!=`, `+=` and a default value inside the
    parameter list -- hence the depth check. Getting this wrong truncates a
    signature mid-parameter, which is worse than printing nothing.
    """
    d = 0
    for i, c in enumerate(text):
        if c in "([{":
            d += 1
        elif c in ")]}":
            d -= 1
        elif c == "=" and d == 0:
            if i and text[i - 1] in "=<>!+-*/%~&|^":
                continue
            if i + 1 < len(text) and text[i + 1] == "=":
                continue
            return i
    return -1


def _doc_after(lines, i):
    """The `##` block that follows line `i`, dedented, as prose.

    Nim puts a routine's doc comment on the lines AFTER the signature, indented
    into the body. Blank lines inside the block are kept; the block ends at the
    first indented line that is not a `##`.
    """
    out = []
    j = i
    while j < len(lines):
        s = lines[j]
        t = s.strip()
        if t.startswith("##"):
            out.append(t[2:].lstrip() if len(t) > 2 else "")
            j += 1
            continue
        if not t and out:
            # A blank line only continues the block if more `##` follows.
            k = j
            while k < len(lines) and not lines[k].strip():
                k += 1
            if k < len(lines) and lines[k].strip().startswith("##"):
                out.append("")
                j = k
                continue
        break
    while out and not out[0]:
        out.pop(0)
    while out and not out[-1]:
        out.pop()
    return "\n".join(out)


def _module_doc(lines):
    """The file's own `##` block, only if it is genuinely at the top.

    Requires the block to start within the first few lines and before any code,
    so a doc comment belonging to the first proc is never promoted into a module
    summary it does not describe.
    """
    i = 0
    while i < len(lines) and not lines[i].strip():
        i += 1
    if i >= len(lines) or not lines[i].strip().startswith("##"):
        return ""
    return _doc_after(lines, i)


def _routine(lines, i):
    """Read one routine starting at line `i`. Returns (entry, next_i)."""
    buf = []
    j = i
    while j < len(lines) and j - i < 60:
        buf.append(lines[j])
        joined = "\n".join(buf)
        if _depth(_strip_code(joined)) <= 0:
            stripped = _strip_code(joined)
            eq = _top_level_eq(stripped)
            sig = joined[:eq].rstrip() if eq >= 0 else joined.rstrip()
            # A one-line body (`proc f*(x: int): int = x + 1`) ends the routine
            # on this same line; a block body continues, but we only ever want
            # the signature, so either way the signature is complete here.
            return {
                "kind": lines[i].split(None, 1)[0],
                "name": ROUTINE_RE.match(lines[i]).group(2).strip("`"),
                "signature": re.sub(r"\s*\n\s*", " ", sig).strip(),
                "line": i + 1,
                "doc": _doc_after(lines, j + 1),
            }, j + 1
        j += 1
    return None, i + 1


def _member(lines, i, kind):
    """Read one exported `type` or `const` member starting at line `i`."""
    name = MEMBER_RE.match(lines[i]).group(1).strip("`")
    body = [lines[i]]
    j = i + 1
    doc_start = None
    while j < len(lines):
        s = lines[j]
        if not s.strip():
            # A blank line ends the member only if what follows is not deeper.
            k = j
            while k < len(lines) and not lines[k].strip():
                k += 1
            if k >= len(lines) or not lines[k].startswith("    "):
                break
            body.append("")
            j = k
            continue
        if not s.startswith("    "):
            break
        if s.strip().startswith("##") and doc_start is None and j == i + 1:
            doc_start = j
        body.append(s)
        j += 1
    doc = _doc_after(lines, doc_start) if doc_start is not None else ""
    if doc:
        body = [b for b in body if not b.strip().startswith("##")]
    while body and not body[-1].strip():
        body.pop()
    return {
        "kind": kind,
        "name": name,
        "definition": "\n".join(body),
        "line": i + 1,
        "doc": doc,
    }, j


def parse(path):
    """Parse one Nim file. Never raises on malformed input; counts it instead."""
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        text = f.read()
    lines = text.split("\n")

    routines, types, consts = [], [], []
    unparsed = 0
    block = None          # "type" | "const" | None
    i = 0
    while i < len(lines):
        line = lines[i]
        if line[:1] not in (" ", "\t", ""):
            # Any column-0 line closes an open type/const block.
            if re.match(r"^type\b", line):
                block = "type"
                i += 1
                continue
            if re.match(r"^const\b", line):
                block = "const"
                i += 1
                continue
            block = None
            if ROUTINE_RE.match(line):
                entry, i = _routine(lines, i)
                if entry is None:
                    unparsed += 1
                else:
                    routines.append(entry)
                continue
            i += 1
            continue
        if block and MEMBER_RE.match(line):
            entry, i = _member(lines, i, block)
            (types if block == "type" else consts).append(entry)
            continue
        i += 1

    return {
        "path": path,
        "module": os.path.splitext(os.path.basename(path))[0],
        "doc": _module_doc(lines),
        "routines": routines,
        "types": types,
        "consts": consts,
        "unparsed": unparsed,
        "lines": len(lines),
    }
