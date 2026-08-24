#!/usr/bin/env python3
"""fldoff.py -- offline field-name -> field-offset resolver for the EFT IL2CPP build.

Thin CLI over the `Resolver` class already built in tools/il2cpp_resolve.py
(same PE/metadata parsing, same MetadataRegistration.fieldOffsets scan --
see that file's module docstring for the mechanism and why it must be
per-image / per-type, never guessed). This file adds nothing to the parsing;
it only exposes `fields`/`field` verbs with the self-check CLAUDE.md section 5
requires before any offset is trusted.

## The self-check (mandatory, not optional)

Before printing anything, this tool re-derives System.String's layout and
compares it against ground truth known independently of the resolver:
    _stringLength @ 0x10
    _firstChar    @ 0x14
If that fails, the resolver's fieldOffsets/MetadataRegistration scan found the
wrong site (or the metadata/binary do not match the offsets we think we're
reading) -- there is no such thing as a "probably still right" offset from a
resolver that failed its own sanity check. On failure this prints ONLY the
failure and exits non-zero. Nothing else is printed. A field-offset tool that
can be silently wrong is worse than no tool at all.

## Usage

  fldoff.py [GAMEASM] [METADEC] fields <Namespace.Type>
        -> every field declared on Type (and inherited), with offset and
           static/instance kind.

  fldoff.py [GAMEASM] [METADEC] field <Namespace.Type> <fieldName>
        -> just that field's offset, machine-readable ("0x120" or "MISSING").

GAMEASM defaults to D:/Games/Tarkov/GameAssembly.dll; METADEC defaults to
.cache/global-metadata.dec.dat (relative to CWD) -- both can be overridden by
passing them explicitly as the first two arguments, matching il2cpp_resolve.py's
convention. GameAssembly.dll is ASLR-relocated at runtime; every address here
is an RVA (VA - imagebase), never a hardcoded live address.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from il2cpp_resolve import Resolver  # noqa: E402

DEFAULT_GAMEASM = "D:/Games/Tarkov/GameAssembly.dll"
DEFAULT_METADEC = ".cache/global-metadata.dec.dat"


def self_check(R):
    """Reproduce System.String's known layout. Exit non-zero, print nothing
    else, if it disagrees."""
    want = {"_stringLength": 0x10, "_firstChar": 0x14}
    try:
        t = R.find_one("System.String")
        got = {name: off for _, name, off, st, _ in R.all_fields(t)
               if name in want and not st}
    except SystemExit as e:
        print("SELF-CHECK FAILED: could not resolve System.String fields: %s" % e)
        sys.exit(1)
    ok = all(got.get(k) == v for k, v in want.items())
    if not ok:
        print("SELF-CHECK FAILED: System.String layout disagrees with ground "
              "truth -- refusing to print any field offset from this build.")
        for k, v in want.items():
            g = got.get(k)
            print("   %-16s got=%s exp=%s" %
                  (k, hex(g) if g is not None else None, hex(v)))
        sys.exit(1)


def resolve_args():
    args = sys.argv[1:]
    # GAMEASM/METADEC are positional and optional: if the next two tokens
    # don't look like a known verb, treat them as paths.
    verbs = ("fields", "field")
    gameasm, metadec = DEFAULT_GAMEASM, DEFAULT_METADEC
    if len(args) >= 1 and args[0] not in verbs:
        gameasm = args[0]
        args = args[1:]
    if len(args) >= 1 and args[0] not in verbs:
        metadec = args[0]
        args = args[1:]
    if not args or args[0] not in verbs:
        sys.exit(__doc__)
    return gameasm, metadec, args


def main():
    gameasm, metadec, args = resolve_args()
    if not os.path.exists(gameasm):
        sys.exit("no such file: %s" % gameasm)
    if not os.path.exists(metadec):
        sys.exit("no such file: %s" % metadec)
    R = Resolver(gameasm, metadec)
    self_check(R)  # must pass BEFORE any field offset is printed

    cmd = args[0]
    if cmd == "fields":
        if len(args) < 2:
            sys.exit(__doc__)
        t = R.find_one(args[1])
        ns, nm = R.tname(t)
        full = (ns + "." + nm) if ns else nm
        print("FIELDS %d %s  image=%s" % (t, full, R.image_of_type(t)))
        print("  %-8s %-6s %-34s %-38s %s" %
              ("Offset", "Kind", "Field", "FieldType", "DeclaredBy"))
        for decl, name, off, st, ty in R.all_fields(t):
            print("  %-8s %-6s %-34s %-38s %s" %
                  (hex(off) if off is not None else "?",
                   "STATIC" if st else "inst", name, ty, decl))
    elif cmd == "field":
        if len(args) < 3:
            sys.exit(__doc__)
        t = R.find_one(args[1])
        rows = [(name, off, st) for _, name, off, st, _ in R.all_fields(t)
                if name == args[2]]
        if not rows:
            print("MISSING")
            sys.exit(1)
        name, off, st = rows[0]
        print(hex(off) if off is not None else "MISSING")
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
