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
    python tools/bigjson.py keys    <file> [--path data.0]    # shape, never values
    python tools/bigjson.py topkeys <file> [--path data] [--json]
                                              # ONLY the key names, for scripts
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


def segments(args):
    """The path to walk: --path split on dots, then every --at verbatim."""
    parts = [x for x in (getattr(args, "path", None) or "").split(".") if x]
    parts += list(getattr(args, "at", None) or [])
    return parts


def walk(node, path):
    parts = path if isinstance(path, list) else [
        x for x in path.split(".") if x]
    for part in parts:
        try:
            node = node[int(part)] if part.lstrip("-").isdigit() else node[part]
        except Exception:
            hint = ""
            if isinstance(node, dict):
                near = [k for k in node
                        if isinstance(k, str) and k.startswith(part)][:5]
                if near:
                    # The overwhelmingly common cause: --path split a key on a
                    # dot the key legitimately contains.
                    hint = ("\n%d key(s) here START with %r. --path CANNOT "
                            "address them: it splits on '.'. Pass the key "
                            "whole with --at:%s"
                            % (len(near), part,
                               "".join("\n  --at %r" % k for k in near)))
            die("path stops at %r (type there was %s)%s"
                % (part, type(node).__name__, hint))
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
    # `--max-rows 0` means EVERY row. Without it the only honest reading of a
    # truncated listing was "there may be more", which is what `topkeys` was
    # added to work around; the cap is a default, not a limit.
    if args.max_rows <= 0:
        args.max_rows = 1 << 30
    node = walk(load(args.file), segments(args))
    if isinstance(node, dict):
        items = list(node.items())
        print("dict with %d key(s) at %r" % (len(items), args.path or "(root)"))
        for k, v in items[: args.max_rows]:
            print("  %-44s %s" % (clip(k, 44), describe(v, args.width)))
        if len(items) > args.max_rows:
            print("  ... %d more key(s) NOT SHOWN; use --path to descend, "
                  "--max-rows N to raise the cap, or --max-rows 0 for all"
                  % (len(items) - args.max_rows))
    elif isinstance(node, list):
        print("list with %d element(s) at %r" % (len(node), args.path or "(root)"))
        for i, v in enumerate(node[: args.max_rows]):
            print("  [%d] %s" % (i, describe(v, args.width)))
        if len(node) > args.max_rows:
            print("  ... %d more element(s) NOT SHOWN; --max-rows 0 for all"
                  % (len(node) - args.max_rows))
    else:
        print("%s at %r" % (describe(node, args.full or args.width), args.path or "(root)"))
    return 0


def cmd_topkeys(args):
    """Machine-readable top-level key list under --path. NOTHING else.

    `keys` is for humans: it prose-wraps, annotates types and TRUNCATES at
    --max-rows, so a script that parses it silently loses keys past row 80.
    This prints every key, one per line (or a JSON array with --json), with no
    header and no clipping, so `dtogap`-style diffs can consume it directly.
    An array at --path yields the keys of element 0 and says so on stderr; a
    scalar or an EMPTY container is an error, not an empty success, because
    "no keys" and "not an object" must not look alike.
    """
    node = walk(load(args.file), segments(args))
    if isinstance(node, list):
        if not node:
            die("empty list at %r -- no element to take keys from" % (args.path or "(root)"))
        sys.stderr.write("note: list at %r; keys taken from element [0] of %d\n"
                         % (args.path or "(root)", len(node)))
        node = node[0]
    if not isinstance(node, dict):
        die("%r is %s, not an object -- it has no top-level keys"
            % (args.path or "(root)", type(node).__name__))
    if not node:
        die("object at %r is EMPTY (0 keys). That is not the same as 'no gaps'."
            % (args.path or "(root)"))
    keys = list(node.keys())
    if args.json:
        print(json.dumps(keys))
    else:
        for k in keys:
            print(k)
    return 0


def cmd_get(args):
    if not segments(args):
        die("get needs --path or --at; with neither it would dump the whole "
            "document, which is the exact thing this tool exists to prevent.")
    node = walk(load(args.file), segments(args))
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
    doc = walk(load(args.file), segments(args))
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
    doc = walk(load(args.file), segments(args))
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
    # Windows hands us a cp1252 stdout, so `get` on any non-ASCII value died with
    # UnicodeEncodeError: 'charmap'. That is not a crash you read as "bad tool" --
    # it is a crash you read as "the field is broken". It is what produced the
    # measured-but-false claim that trader BTR has an EMPTY nickname; the nickname
    # is "БТР" and was always there. `keys` survived only because it
    # escapes. backslashreplace keeps output printable without inventing a value.
    for _s in (sys.stdout, sys.stderr):
        try:
            _s.reconfigure(encoding="utf-8", errors="backslashreplace")
        except (AttributeError, ValueError):
            pass
    ap = argparse.ArgumentParser(
        prog="bigjson.py",
        description="Inspect huge single-line JSON without printing it.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    ap.add_argument("--width", type=int, default=300, help="clip every value to N chars")
    ap.add_argument("--full", type=int, default=0, help="raise the clip to N chars, deliberately")
    ap.add_argument("--max-rows", type=int, default=MAX_ROWS,
                    help="rows to print (0 = no cap)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    def add(name, fn, help_):
        p = sub.add_parser(name, help=help_)
        p.add_argument("file")
        # MEASURED: `bigjson.py get FILE --path X --full 200000` died with
        # "unrecognized arguments: --full 200000", which reads as though the
        # flag does not exist at all -- it exists, but only BEFORE the
        # subcommand. Accepting it in either position costs three lines.
        # argparse.SUPPRESS is load-bearing: without it the subparser would
        # re-set these attributes to its own defaults and SILENTLY DISCARD a
        # value given in the global position -- trading a loud error for a
        # quietly ignored flag, which is strictly worse.
        p.add_argument("--width", type=int, default=argparse.SUPPRESS,
                       help="clip every value to N chars")
        p.add_argument("--full", type=int, default=argparse.SUPPRESS,
                       help="raise the clip to N chars, deliberately")
        p.add_argument("--max-rows", type=int, default=argparse.SUPPRESS,
                       help="rows to print (0 = no cap)")
        # --path is DOT-separated, so it cannot address a key that contains a
        # dot -- which is EVERY key in Windows.json
        # ("assets/content/audio/voice/scav/scav6.bundle": the slashes are
        # harmless, the ".bundle" is not). --at takes ONE literal segment per
        # occurrence and never splits, so any key is reachable:
        #   get FILE --at "assets/content/audio/voice/scav/scav6.bundle"
        # Repeat it to descend. --path is applied first, then every --at.
        p.add_argument("--at", action="append", default=None, metavar="KEY",
                       help="one LITERAL path segment, never split; repeat to "
                            "descend. Use this for a key containing a dot.")
        p.set_defaults(fn=fn)
        return p

    add("size", cmd_size, "bytes, line count, longest line")
    add("keys", cmd_keys, "shape at a path -- keys and types, not values").add_argument("--path")
    p = add("topkeys", cmd_topkeys,
            "MACHINE-READABLE top-level keys under --path, one per line, never truncated")
    p.add_argument("--path")
    p.add_argument("--json", action="store_true", help="emit a JSON array instead")
    p = add("get", cmd_get, "one value at a dotted path")
    p.add_argument("--path")
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
