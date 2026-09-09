#!/usr/bin/env python3
r"""repowrite.py -- rewrite a TRACKED repo file without flipping its line endings.

Why this exists, measured
-------------------------
`open(path, "w")` in text mode on Windows translates every "\n" to "\r\n" on
the way out; `core.autocrlf=true` then translates back on the way in. A tool
that read a CRLF file, changed one value, and wrote it back in text mode
converted the WHOLE TREE to LF and turned a 100-line patch into a 21,000-line
diff. Nothing warned; the diff just got enormous.

`.gitattributes` in this repo says `* -text` **deliberately** (the comment in
it explains why): a CRLF file commits as CRLF, so a later merge against an LF
branch conflicts on EVERY line. One such merge turned a ~200-line disjoint
diff into a 1192-line whole-file conflict. Do not "fix" that by editing
`.gitattributes`.

So: anything under `tools/` that rewrites a repo file must go through here.

    from repowrite import write_text, read_text
    text, nl = read_text(path)          # nl is "\r\n", "\n", or None (new file)
    write_text(path, new_text, nl)      # preserves it

`write_text` with `nl=None` sniffs the file's CURRENT endings and reuses them;
for a file that does not exist yet it writes LF. It never uses text-mode
translation -- everything is encoded and written as bytes.

Detecting the endings of a file
-------------------------------
`grep -c $'\r' file` LIES on this machine: MSYS grep applies its own
translation, so a CRLF file can report 0. Count bytes instead --
`endings(path)` does exactly that, and `python tools/repowrite.py check <path>`
prints it, which is the only measurement of a file's endings this repo trusts.
"""
import io
import os
import sys


def endings(path):
    """(crlf_count, lf_only_count) measured in BYTES, not by any text mode."""
    with open(path, "rb") as f:
        b = f.read()
    crlf = b.count(b"\r\n")
    return crlf, b.count(b"\n") - crlf


def dominant(path):
    """The newline this file predominantly uses, or None if it has none."""
    if not os.path.isfile(path):
        return None
    crlf, lf = endings(path)
    if crlf == 0 and lf == 0:
        return None
    return "\r\n" if crlf >= lf else "\n"


def read_text(path, encoding="utf-8"):
    """Return (text-with-LF-endings, the file's actual newline)."""
    with open(path, "rb") as f:
        raw = f.read()
    nl = dominant(path)
    return raw.decode(encoding).replace("\r\n", "\n"), nl


def write_text(path, text, nl=None, encoding="utf-8"):
    """Write `text` (LF-separated) using `nl`, or the file's existing endings.

    Returns the newline actually used, so a caller can report it.
    """
    if nl is None:
        nl = dominant(path) or "\n"
    body = text.replace("\r\n", "\n")
    if nl != "\n":
        body = body.replace("\n", nl)
    with open(path, "wb") as f:
        f.write(body.encode(encoding))
    return nl


def open_text(path, mode="w", encoding="utf-8"):
    """`open(path, "w", newline="")` with the file's existing endings baked in.

    For call sites that want a file object (json.dump, print(file=...)). The
    caller must emit "\n"; this translates on close via a small wrapper.
    """
    nl = dominant(path) or "\n"
    return io.open(path, mode, encoding=encoding, newline=nl)


def main():
    if len(sys.argv) != 3 or sys.argv[1] != "check":
        sys.exit("usage: repowrite.py check <path>\n"
                 "Prints the file's line endings, counted in bytes. "
                 "`grep -c $'\\r'` is not trustworthy here.")
    p = sys.argv[2]
    if not os.path.isfile(p):
        sys.exit("no such file: %s" % p)
    crlf, lf = endings(p)
    print("%s  CRLF=%d  LF-only=%d  -> %s"
          % (p, crlf, lf,
             "CRLF" if crlf and not lf else
             "LF" if lf and not crlf else
             "MIXED (%d CRLF, %d LF) -- a rewrite will normalise this; say so"
             % (crlf, lf) if (crlf and lf) else "no line endings at all"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
