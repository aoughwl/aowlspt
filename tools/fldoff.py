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
        -> just that field's offset, machine-readable. Never a number the
           tool cannot stand behind:
             0x120              a real offset
             MISSING            (exit 1) no such field on the type
             NO-STORAGE         (exit 2) a C# const -- no address to read
             GENERIC-NO-LAYOUT  (exit 3) an UNINSTANTIATED generic definition
                                (``List`1``). IL2CPP stores an all-zero
                                fieldOffsets array for these because the
                                layout depends on the type arguments and is
                                built at runtime; it used to print 0x0.
             NO-OFFSET-TABLE    (exit 4) fieldOffsets[type] is null

  fldoff.py [GAMEASM] [METADEC] enum <Namespace.Type>
        -> every member of an enum with its ORDINAL, decoded from the
           fieldDefaultValues table + the default-value blob.

  fldoff.py [GAMEASM] [METADEC] enumval <Namespace.Type> <MemberName>
        -> that one ordinal, machine-readable (or MISSING / NO-VALUE /
           NOT-AN-ENUM, never a plausible-looking number).

`fields` prints the raw FieldAttributes word and its decoded names, and prints
`--` rather than `0x0` in the Offset column for a field with NO STORAGE. A C#
`const` is LITERAL|STATIC|HASDEFAULT (0x8056): the compiler inlines it at every
use site, so its fieldOffsets slot is meaningless. Without the attributes that
is indistinguishable from a `static readonly` at offset 0, which has real,
writable storage.

`enum`/`enumval` run a SECOND mandatory self-check (see `enum_self_check`)
reproducing 19 independently-known constants before printing anything.

GAMEASM defaults to the aowlspt install's GameAssembly.dll (tools/gamepaths.py); METADEC defaults to
.cache/global-metadata.dec.dat, resolved against the REPO (and, in a
worktree, the parent checkout) -- both can be overridden by
passing them explicitly as the first two arguments, matching il2cpp_resolve.py's
convention. GameAssembly.dll is ASLR-relocated at runtime; every address here
is an RVA (VA - imagebase), never a hardcoded live address.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from il2cpp_resolve import Resolver, const_check, print_field_rows  # noqa: E402

import gamepaths as _gp  # noqa: E402  (the binary the host runs against)
DEFAULT_GAMEASM = _gp.gameasm()
# Resolved against the REPO, not the CWD. It used to be a bare relative
# path, so every one of these tools failed in a git worktree -- the cache
# lives in the main checkout -- and the failure looked like a missing file
# rather than a wrong working directory.
_REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_METADEC = os.path.join(_REPO, ".cache", "global-metadata.dec.dat")
if not os.path.exists(DEFAULT_METADEC):
    # A worktree under <main>/.claude/worktrees/<name> has no cache of its
    # own; fall back to the checkout it was created from.
    _up = _REPO
    for _ in range(4):
        _up = os.path.dirname(_up)
        _cand = os.path.join(_up, ".cache", "global-metadata.dec.dat")
        if os.path.exists(_cand):
            DEFAULT_METADEC = _cand
            break


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


def enum_self_check(R):
    """Same discipline as `self_check`, for the constant decoder: reproduce 19
    constants known independently of this build (KeyCode.None/Space/A/Alpha0
    plus one per primitive width) before printing any enum value. Prints only
    the failure and exits non-zero if any disagrees."""
    ok, rows = const_check(R)
    if ok:
        return
    print("SELF-CHECK FAILED: the constant decoder does not reproduce known "
          "values -- refusing to print any enum value from this build.")
    for lbl, got, want, good in rows:
        if not good:
            print("   %-34s got=%r exp=%r" % (lbl, got, want))
    sys.exit(1)


def resolve_args():
    args = sys.argv[1:]
    # GAMEASM/METADEC are positional and optional: if the next two tokens
    # don't look like a known verb, treat them as paths.
    verbs = ("fields", "field", "enum", "enumval")
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
        print_field_rows(R.all_fields_ex(t))
    elif cmd == "field":
        if len(args) < 3:
            sys.exit(__doc__)
        t = R.find_one(args[1])
        rows = [r for r in R.all_fields_ex(t) if r["name"] == args[2]]
        if not rows:
            print("MISSING")
            sys.exit(1)
        r = rows[0]
        # A literal has no storage; printing 0x0 here would be a lie that a
        # caller would happily read or write through.
        if not r["has_storage"]:
            print("NO-STORAGE")
            sys.exit(2)
        # Same class of lie, one level up: an uninstantiated generic
        # definition's fieldOffsets array is all zeros, and 0x0 is a real
        # offset shape. Three outcomes, never two.
        if r["layout"] == "generic":
            print("GENERIC-NO-LAYOUT")
            sys.exit(3)
        if r["layout"] == "absent" or r["off"] is None:
            print("NO-OFFSET-TABLE")
            sys.exit(4)
        print(hex(r["off"]))
    elif cmd == "enum":
        enum_self_check(R)
        t = R.find_one(args[1])
        ns, nm = R.tname(t)
        full = (ns + "." + nm) if ns else nm
        if not R.is_enum(t):
            sys.exit("%s is not an enum (base class is not System.Enum)" % full)
        print("ENUM %d %s  image=%s" % (t, full, R.image_of_type(t)))
        for name, v in R.enum_members(t):
            print("  %-30s = %s" %
                  (name, v if v is not None
                   else "<no default-value entry in metadata>"))
    elif cmd == "enumval":
        # machine-readable single member: the value, or a refusal.
        if len(args) < 3:
            sys.exit(__doc__)
        enum_self_check(R)
        t = R.find_one(args[1])
        if not R.is_enum(t):
            print("NOT-AN-ENUM")
            sys.exit(1)
        hit = [v for n, v in R.enum_members(t) if n == args[2]]
        if not hit:
            print("MISSING")
            sys.exit(1)
        if hit[0] is None:
            print("NO-VALUE")
            sys.exit(1)
        print(hit[0])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
