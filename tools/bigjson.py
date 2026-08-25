#!/usr/bin/env python3
r"""Inspect the huge single-line JSON files without ever printing one.

Why this exists, measured
-------------------------
These files are ONE line each, so `cat`, `head -1`, `Get-Content -TotalCount 1`,
`Read` and any `grep` that matches all return the WHOLE FILE:

    D:\Aowlspt\aowlspt\db.json                              41,313,127 bytes, 1 line
    mods\tarkov\data\capture\raid1\responses\large\045.json 18,297,513 bytes, 1 line
    mods\tarkov\data\capture\raid1\responses\large\076.json 13,252,394 bytes, 1 line
    mods\tarkov\data\post1\locale_en.json                    2,766,414 bytes, 1 line
    mods\tarkov\data\post1\locations.json                    1,907,774 bytes, 1 line

One match is one line is the entire file. There is no safe raw read of any of
them, so use this instead:

    python tools/bigjson.py size   <file>
    python tools/bigjson.py keys   <file> [--path data.0]     # shape, never values
    python tools/bigjson.py get    <file> --path data.0._id   # one field
    python tools/bigjson.py find   <file> --key Chances       # where does a key live
    python tools/bigjson.py search <file> --value 5449016a...   # which paths hold a string

Every value printed is clipped to `--width` (default 300). `--full N` raises
that cap deliberately, for one value, when you have decided you need it.
"""

import argparse
import json
import os
import sys

MAX_ROWS = 80


def die(msg):
    sys.stderr.write(msg.rstrip() + "\n")
    raise SystemExit(1)


def clip(s, width):
    s = str(s).replace("\r", " ").replace("\n", " ")
    if len(s) <= width:
        return s
    return "%s  ...[+%d chars]" % (s[:width], len(s) - width)


def load(path):
    if not os.path.isfile(path):
        die("no such file: %s" % path)
    size = os.path.getsize(path)
    if size > 200 * 1024 * 1024:
        die("%s is %d bytes -- too large even for this tool." % (path, size))
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        try:
            return json.load(fh)
        except Exception as exc:
            die("%s is not parseable JSON: %s" % (path, exc))


def walk(node, path):
    for part in path.split("."):
        if part == "":
            continue
        try:
            node = node[int(part)] if part.lstrip("-").isdigit() else node[part]
        except Exception:
            die("path stops at %r (type there was %s)" % (part, type(node).__name__))
    return node


def describe(v, width):
    if isinstance(v, dict):
        return "dict(%d)" % len(v)
    if isinstance(v, list):
        return "list(%d)" % len(v)
    if v is None:
        return "null"
    return "%s %s" % (type(v).__name__, clip(json.dumps(v), width))


def cmd_size(args):
    p = args.file
    if not os.path.isfile(p):
        die("no such file: %s" % p)
    size = os.path.getsize(p)
    longest = 0
    lines = 0
    with open(p, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            lines += 1
            longest = max(longest, len(line))
    print("%s\n  %d bytes, %d line(s), longest line %d chars" % (p, size, lines, longest))
    if longest > 20000:
        print("  ! a single line is %d chars -- never cat/Read/grep this file raw." % longest)
    return 0


def cmd_keys(args):
    node = walk(load(args.file), args.path or "")
    if isinstance(node, dict):
        items = list(node.items())
        print("dict with %d key(s) at %r" % (len(items), args.path or "(root)"))
        for k, v in items[: args.max_rows]:
            print("  %-44s %s" % (clip(k, 44), describe(v, args.width)))
        if len(items) > args.max_rows:
            print("  ... %d more key(s); use --path to descend" % (len(items) - args.max_rows))
    elif isinstance(node, list):
        print("list with %d element(s) at %r" % (len(node), args.path or "(root)"))
        for i, v in enumerate(node[: args.max_rows]):
            print("  [%d] %s" % (i, describe(v, args.width)))
        if len(node) > args.max_rows:
            print("  ... %d more element(s)" % (len(node) - args.max_rows))
    else:
        print("%s at %r" % (describe(node, args.full or args.width), args.path or "(root)"))
    return 0


def cmd_get(args):
    node = walk(load(args.file), args.path or "")
    width = args.full or args.width
    if isinstance(node, (dict, list)):
        print(clip(json.dumps(node, ensure_ascii=False), width))
        print("\n(%s -- use `keys --path %s` for its shape)" % (describe(node, 0), args.path or ""))
    else:
        print(clip(json.dumps(node, ensure_ascii=False), width))
    return 0


def _paths(node, prefix, key, want_value, hits, limit, depth):
    if len(hits) >= limit or depth > 12:
        return
    if isinstance(node, dict):
        for k, v in node.items():
            p = "%s.%s" % (prefix, k) if prefix else k
            if key is not None and k == key:
                hits.append((p, v))
            if want_value is not None and isinstance(v, str) and want_value in v:
                hits.append((p, v))
            _paths(v, p, key, want_value, hits, limit, depth + 1)
    elif isinstance(node, list):
        for i, v in enumerate(node[:200]):
            p = "%s.%d" % (prefix, i) if prefix else str(i)
            if want_value is not None and isinstance(v, str) and want_value in v:
                hits.append((p, v))
            _paths(v, p, key, want_value, hits, limit, depth + 1)


def cmd_find(args):
    doc = walk(load(args.file), args.path or "")
    hits = []
    _paths(doc, args.path or "", args.key, None, hits, args.max_rows, 0)
    if not hits:
        print("no key named %r found (depth<=12, first 200 list elems)" % args.key)
        return 0
    for p, v in hits:
        print("  %-60s %s" % (clip(p, 60), describe(v, args.width)))
    print("\n%d hit(s). Read one with: get --path <path>" % len(hits))
    return 0


def cmd_search(args):
    doc = walk(load(args.file), args.path or "")
    hits = []
    _paths(doc, args.path or "", None, args.value, hits, args.max_rows, 0)
    if not hits:
        print("no string value containing %r" % args.value)
        return 0
    for p, v in hits:
        print("  %-60s %s" % (clip(p, 60), clip(json.dumps(v), args.width)))
    print("\n%d hit(s)." % len(hits))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(
        prog="bigjson.py",
        description="Inspect huge single-line JSON without printing it.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    ap.add_argument("--width", type=int, default=300, help="clip every value to N chars")
    ap.add_argument("--full", type=int, default=0, help="raise the clip to N chars, deliberately")
    ap.add_argument("--max-rows", type=int, default=MAX_ROWS)
    sub = ap.add_subparsers(dest="cmd", required=True)

    def add(name, fn, help_):
        p = sub.add_parser(name, help=help_)
        p.add_argument("file")
        p.set_defaults(fn=fn)
        return p

    add("size", cmd_size, "bytes, line count, longest line")
    add("keys", cmd_keys, "shape at a path -- keys and types, not values").add_argument("--path")
    p = add("get", cmd_get, "one value at a dotted path")
    p.add_argument("--path", required=True)
    p = add("find", cmd_find, "which paths carry a given key name")
    p.add_argument("--key", required=True)
    p.add_argument("--path", help="search only under this subtree")
    p = add("search", cmd_search, "which paths hold a string value")
    p.add_argument("--value", required=True)
    p.add_argument("--path")

    args = ap.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
