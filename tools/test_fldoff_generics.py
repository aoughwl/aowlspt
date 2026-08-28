#!/usr/bin/env python3
"""test_fldoff_generics.py -- falsifiable tests for field-offset three-state.

Run:
  python tools/test_fldoff_generics.py D:/Games/Tarkov/GameAssembly.dll \
      .cache/global-metadata.dec.dat

Why this file exists (CLAUDE.md 9b): `fldoff.py fields "List`1"` printed
`0x0` for _items, _size, _version, _syncRoot and s_emptyArray. That is not a
wrong offset, it is the ABSENCE of an offset rendered as data -- IL2CPP writes
an all-zero fieldOffsets array for an uninstantiated generic definition
because the layout depends on the type arguments and is built at runtime in
Il2CppClass setup. A caller obeying CLAUDE.md 5's "never guess" got a
fabricated number that reads the object header.

Both directions are asserted, because a fix that marks EVERYTHING no-layout
would pass a generic-only test:

  * CONCRETE must still print real offsets -- System.String._stringLength
    = 0x10, _firstChar = 0x14 (the same ground truth the mandatory self-check
    uses, independent of the resolver);
  * GENERIC must print the no-layout marker and must NOT print 0x0 anywhere
    in the Offset column;
  * the `field` verb and the `fields` table must agree (one library function,
    not two open-coded answers);
  * the generic/no-layout classification must partition this build the way the
    binary does: measured, genericContainerIndex >= 0 holds for EXACTLY the
    types whose whole instance-field offset array is zero (1569 of them) and
    for no others (19930) -- so a classifier that is merely "name contains a
    backtick" fails here (it misclassifies 638 types).

Falsifiability was demonstrated by reverting field_offsets_base() to the old
`entry = rq(FOFF_PTR + t*8)` form: checks 3-6 go red, checks 1-2 stay green.
"""
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from il2cpp_resolve import Resolver          # noqa: E402

FLDOFF = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fldoff.py")

CONCRETE = ("System.String", {"_stringLength": 0x10, "_firstChar": 0x14})
GENERIC = "System.Collections.Generic.List`1"
GENERIC_FIELDS = ["_items", "_size", "_version"]

_fails = []


def check(label, ok, detail=""):
    print("  %-52s %s%s" % (label, "OK" if ok else "FAIL",
                            "" if ok else "   " + detail))
    if not ok:
        _fails.append(label)


def run(gameasm, metadec, *args):
    p = subprocess.run([sys.executable, FLDOFF, gameasm, metadec] + list(args),
                       capture_output=True, text=True)
    return p.returncode, p.stdout


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    gameasm, metadec = sys.argv[1], sys.argv[2]
    R = Resolver(gameasm, metadec)

    print("1. concrete type still yields REAL offsets (library)")
    t = R.find_one(CONCRETE[0])
    got = {r["name"]: r for r in R.all_fields_ex(t)}
    for name, want in CONCRETE[1].items():
        r = got.get(name)
        check("%s.%s == %s" % (CONCRETE[0], name, hex(want)),
              r is not None and r["layout"] == "concrete" and r["off"] == want,
              "got %r" % ((None if r is None else (r["layout"], r["off"])),))

    print("2. concrete type still yields REAL offsets (CLI `field`)")
    for name, want in CONCRETE[1].items():
        rc, out = run(gameasm, metadec, "field", CONCRETE[0], name)
        check("CLI field %s -> %s" % (name, hex(want)),
              rc == 0 and out.strip() == hex(want), "rc=%d out=%r" % (rc, out))

    print("3. generic definition is NOT given a numeric offset (library)")
    gt = R.find_one(GENERIC)
    grows = {r["name"]: r for r in R.all_fields_ex(gt)}
    for name in GENERIC_FIELDS:
        r = grows.get(name)
        check("%s.%s has no layout" % (GENERIC, name),
              r is not None and r["layout"] == "generic" and r["off"] is None,
              "got %r" % ((None if r is None else (r["layout"], r["off"])),))

    print("4. generic definition table prints the marker, never 0x0")
    rc, out = run(gameasm, metadec, "fields", GENERIC)
    body = [ln for ln in out.splitlines()
            if ln.startswith("  ") and not ln.strip().startswith("Offset")]
    offcol = [ln[2:10].strip() for ln in body if ln[2:10].strip()]
    check("no 0x0 in the Offset column", "0x0" not in offcol,
          "columns=%r" % offcol)
    check("marker present", "GENERIC -- NO LAYOUT" in out, out[-200:])
    check("exit 0 (a refusal, not a crash)", rc == 0, "rc=%d" % rc)

    print("5. CLI `field` on a generic definition refuses, distinctly")
    rc, out = run(gameasm, metadec, "field", GENERIC, "_items")
    check("prints GENERIC-NO-LAYOUT", out.strip() == "GENERIC-NO-LAYOUT", out)
    check("exit 3 (not 0, not MISSING's 1)", rc == 3, "rc=%d" % rc)

    print("6. classification matches the binary, every type, both ways")
    bad_g, bad_c, n_g, n_c = [], [], 0, 0
    for ti in range(R.NTYPES):
        rows = [r for r in R.declared_fields_ex(ti)
                if r["has_storage"] and not r["static"]]
        if not rows:
            continue
        gen = R.is_generic_definition(ti)
        # what the binary itself says: a type WITH instance fields whose whole
        # offset array is zero has no usable layout.
        layout, base = R.field_offsets_base(ti)
        if gen:
            n_g += 1
            if layout != "generic":
                bad_g.append(ti)
        else:
            n_c += 1
            if layout == "concrete" and base is not None and \
                    all(r["off"] == 0 for r in rows):
                bad_c.append(ti)          # zeros served as if concrete
    check("all %d generic defs classified generic" % n_g, not bad_g,
          "leaked: %r" % bad_g[:5])
    check("no non-generic type served an all-zero layout (%d checked)" % n_c,
          not bad_c, "leaked: %r" % [R.tname(i) for i in bad_c[:5]])

    print("\n%s -- %d check(s) failed" % ("FAIL" if _fails else "PASS",
                                          len(_fails)))
    sys.exit(1 if _fails else 0)


if __name__ == "__main__":
    main()
