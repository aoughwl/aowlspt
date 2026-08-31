#!/usr/bin/env python3
"""What TYPE does a JSON field actually hold, across a whole document?

The instrument behind `mods/tarkov/emu/shapes.nim`'s ScalarShapes table. Every
line of that table is a claim about stock data -- "availableAfter is always a
number" -- and this is how the claim is measured rather than guessed.

It is a byte scanner, not a parser: `db.json` is 41 MB on ONE line and parsing
it costs more memory than the machine wants to give. It finds every occurrence
of `"<name>"` in KEY position (the previous non-space byte is `{` or `,`),
reads the value token that follows, and classifies it.

    python tools/fieldshape.py D:/Aowlspt/aowlspt/db.json availableAfter
    python tools/fieldshape.py D:/Aowlspt/aowlspt/db.json insurance_price_coef

Output is a kind histogram plus a few sample values per kind, never the whole
document. A field with MORE THAN ONE kind is not automatically a bug: stock
data is genuinely polymorphic in places (`insurance_price_coef` is a string in
5 traders and a number in 7), and that is exactly why the nim table takes a SET
of allowed kinds. A rule written from a single observation is a rule that will
condemn valid data.

Exit code is 0 whatever it finds -- this reports, it does not judge.
"""

import argparse
import json
import os
import sys


def classify(buf, i):
    """Return (kind, end_index_exclusive) for the value token starting at i."""
    c = buf[i:i + 1]
    if c == b'"':
        j = i + 1
        while j < len(buf):
            if buf[j:j + 1] == b'\\':
                j += 2
                continue
            if buf[j:j + 1] == b'"':
                return "string", j + 1
            j += 1
        return "string", len(buf)
    if buf[i:i + 4] == b"true":
        return "bool", i + 4
    if buf[i:i + 5] == b"false":
        return "bool", i + 5
    if buf[i:i + 4] == b"null":
        return "null", i + 4
    if c == b"{":
        return "object", i + 1
    if c == b"[":
        return "array", i + 1
    j = i
    while j < len(buf) and buf[j:j + 1] in b"-+.0123456789eE":
        j += 1
    if j > i:
        return "number", j
    return "?", i + 1


def scan(path, name, samples):
    with open(path, "rb") as f:
        buf = f.read()
    needle = b'"' + name.encode("utf-8") + b'"'
    kinds = {}
    vals = {}
    at = 0
    while True:
        i = buf.find(needle, at)
        if i < 0:
            break
        at = i + len(needle)
        # KEY position: previous non-space byte must open an object or a pair.
        k = i - 1
        while k >= 0 and buf[k:k + 1] in b" \t\r\n":
            k -= 1
        if buf[k:k + 1] not in (b"{", b","):
            continue
        j = at
        while j < len(buf) and buf[j:j + 1] in b" \t\r\n":
            j += 1
        if buf[j:j + 1] != b":":
            continue
        j += 1
        while j < len(buf) and buf[j:j + 1] in b" \t\r\n":
            j += 1
        kind, end = classify(buf, j)
        kinds[kind] = kinds.get(kind, 0) + 1
        if kind in ("object", "array"):
            text = kind
        else:
            text = buf[j:end].decode("utf-8", "replace")[:60]
        bucket = vals.setdefault(kind, {})
        bucket[text] = bucket.get(text, 0) + 1
    return kinds, vals


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("file")
    p.add_argument("name", help="the JSON key to profile")
    p.add_argument("--samples", type=int, default=8,
                   help="distinct sample values to show per kind (default 8)")
    p.add_argument("--json", action="store_true", help="machine-readable output")
    a = p.parse_args()
    if not os.path.exists(a.file):
        print("no such file: %s" % a.file)
        return 2
    kinds, vals = scan(a.file, a.name, a.samples)
    total = sum(kinds.values())
    if a.json:
        print(json.dumps({"field": a.name, "total": total, "kinds": kinds}))
        return 0
    print("field      : %s" % a.name)
    print("file       : %s (%d bytes)" % (a.file, os.path.getsize(a.file)))
    print("occurrences: %d in key position" % total)
    if total == 0:
        print("VERDICT    : field not present -- no shape claim can be made")
        return 0
    for k in sorted(kinds, key=lambda x: -kinds[x]):
        print("  %-7s %6d  (%.1f%%)" % (k, kinds[k], 100.0 * kinds[k] / total))
        top = sorted(vals[k].items(), key=lambda kv: -kv[1])[:a.samples]
        for text, n in top:
            print("      %6dx  %s" % (n, text))
    if len(kinds) == 1:
        print("VERDICT    : MONOMORPHIC -- allowed set is {%s}"
              % list(kinds)[0])
    else:
        print("VERDICT    : POLYMORPHIC -- allowed set is {%s}; a rule naming "
              "only one of these would condemn valid stock data"
              % ", ".join(sorted(kinds)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
