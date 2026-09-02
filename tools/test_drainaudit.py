#!/usr/bin/env python3
"""The falsifier for tools/drainaudit.py.

A verifier ships with the negative control that makes its FAIL fire, or it is
not a verifier. drainaudit's whole job is to refuse a POSTFIX detour on a call
that uses more than four register slots, so the control that matters is a
fixture tree containing exactly that -- a 7-slot postfix -- which MUST come back
FAIL. Case 0 is the positive control: the same fixture with a legal slot count
must NOT fail, so a FAIL in the other cases is attributable to the mutation and
not to the fixture being malformed. Without case 0 every other case could pass
vacuously.

Run:  python tools/test_drainaudit.py
Exit: 0 all cases behaved, 1 otherwise.
"""

from __future__ import annotations

import os
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import drainaudit as D                                          # noqa: E402


HEADER = """\
#ifndef FIXTURE_H
#define FIXTURE_H
typedef struct AowlFixTarget {
    const char*         name;
    uint32_t            rva;
    const unsigned char sig[16];
    int32_t             siglen;
    int32_t             slots;
} AowlFixTarget;

static const AowlFixTarget aowl_fix_targets[] = {
    { "EFT.UI.MenuScreen::Show", 0x15387A0u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x30,0x80,0x3D,0x2F,
        0x61,0x93,0x05 }, 16, %(TABLE_SLOTS)s },
};
static int32_t aowl_fix_target_slots(int32_t i) {
    if (i < 0 || i >= 1) return 0;
    return aowl_fix_targets[i].slots;
}
#endif
"""

NIM = """\
proc cFixTargetSlots(i: int32): int32 {.importc: "aowl_fix_target_slots",
  nodecl.}

proc bindFixture(verbose: bool): bool =
  ## A fixture site. The doc comment deliberately contains an unbalanced
  ## parenthesis ( and a typed literal 8'i32, because both broke the real
  ## parser once.
  if attachDrain("EFT.UI.MenuScreen::Show", fn, cast[Il2CppMethod](0),
                 false, verbose, 3'i32, true%(SITE_SLOTS)s):
    okLog "bound"
    return true
  result = false
"""


def make_tree(table_slots="3", site_slots=", 3'i32", header=True,
              hide_table=False):
    d = tempfile.mkdtemp(prefix="drainaudit-fix-")
    os.makedirs(os.path.join(d, "abi"))
    os.makedirs(os.path.join(d, "host", "Fix"))
    if header:
        text = HEADER % {"TABLE_SLOTS": table_slots}
        if hide_table:
            # The accessor still says `.slots`, so a table IS read at run time
            # -- but this tool can no longer see its rows. That is the shape
            # the anonymous typedef in aowlspt_uihooks.h really had.
            text = text.replace("static const AowlFixTarget aowl_fix_targets",
                                "AOWL_TABLE(AowlFixTarget) aowl_fix_targets")
        with open(os.path.join(d, "abi", "aowlspt_fix.h"), "w") as f:
            f.write(text)
    with open(os.path.join(d, "host", "Fix", "fix.nim"), "w") as f:
        f.write(NIM % {"SITE_SLOTS": site_slots})
    return d


class Case:
    def __init__(self, name, kw, want, why):
        self.name, self.kw, self.want, self.why = name, kw, want, why


CASES = [
    # ---- POSITIVE CONTROL. Without this one, every FAIL below could be the
    # fixture rather than the mutation, and the suite would pass vacuously.
    Case("legal postfix (3 slots), declared everywhere",
         dict(table_slots="3", site_slots=", 3'i32"),
         D.INCONCLUSIVE,
         "a legal fixture must NOT fail; INCONCLUSIVE because --no-metadata "
         "means the declared counts were not cross-checked, which is not a "
         "pass either"),

    # ---- THE CONTROL THIS TOOL EXISTS FOR ---------------------------------
    Case("7-slot POSTFIX site (the measured crash shape)",
         dict(table_slots="7", site_slots=", 7'i32"),
         D.FAIL,
         "EFT.UI.MenuScreen::Show(5-arg) uses 7 register slots; a postfix "
         "there is the three-dead-boots shape and must be refused"),

    Case("5-slot POSTFIX site (one argument on the stack)",
         dict(table_slots="5", site_slots=", 5'i32"),
         D.FAIL,
         "the boundary: FOUR is legal and FIVE is not, so the limit must bite "
         "at exactly one stack argument, not only at a dramatic one"),

    Case("4-slot POSTFIX site (the boundary, legal side)",
         dict(table_slots="4", site_slots=", 4'i32"),
         D.INCONCLUSIVE,
         "the other half of the boundary. A gate that also refused 4 would be "
         "'always FAIL', which is indistinguishable from a working gate on "
         "the failing cases alone"),

    Case("POSTFIX site with NO slots argument",
         dict(table_slots="3", site_slots=""),
         D.FAIL,
         "an undeclared shape is a refusal, not a default. 'I could not look' "
         "is not a pass"),

    Case("table row declaring slots=0 (undeclared)",
         dict(table_slots="0", site_slots=", 3'i32"),
         D.FAIL,
         "zero is what a C zero-fill produces for a row somebody added "
         "without the column; it must read as undeclared, never as 'no "
         "arguments'"),

    Case("slots read from an audited table column",
         dict(table_slots="3", site_slots=", cFixTargetSlots(int32(i))"),
         D.INCONCLUSIVE,
         "the table-driven form is the one every real site uses; it must be "
         "traced to its column and NOT reported as untraceable"),

    Case("slots read from a table this tool cannot parse",
         dict(table_slots="3", site_slots=", cFixTargetSlots(int32(i))",
              hide_table=True),
         D.FAIL,
         "the accessor proves a slots column is read at run time, but no rows "
         "were parsed, so nothing was audited -- and an audit of nothing must "
         "not print PASS. This is the anonymous-typedef hole that really "
         "occurred, where nine uihooks rows were skipped under a PASS"),

    Case("slots from an accessor that has no table at all",
         dict(table_slots="3", site_slots=", cFixTargetSlots(int32(i))",
              header=False),
         D.FAIL,
         "the site passes a slot count this audit cannot trace to any column "
         "or literal. A slot count that cannot be checked offline is not a "
         "checked slot count"),
]


def main():
    bad = 0
    for c in CASES:
        d = make_tree(**c.kw)
        try:
            got = D.audit(d, "", "", quiet=True)
        finally:
            shutil.rmtree(d, ignore_errors=True)
        ok = (got == c.want)
        bad += 0 if ok else 1
        print("%-6s %-52s want=%d got=%d\n         %s"
              % ("PASS" if ok else "FAIL", c.name, c.want, got, c.why))

    # ---- the metadata cross-check, when the inputs are here ---------------
    if os.path.exists(D.GAMEASM_DEFAULT) and os.path.exists(D.METADEC_DEFAULT):
        d = make_tree(table_slots="2", site_slots=", 2'i32")
        try:
            got = D.audit(d, D.GAMEASM_DEFAULT, D.METADEC_DEFAULT, quiet=True)
        finally:
            shutil.rmtree(d, ignore_errors=True)
        ok = (got == D.FAIL)
        bad += 0 if ok else 1
        print("%-6s %-52s want=%d got=%d\n         %s"
              % ("PASS" if ok else "FAIL",
                 "declared slots=2 vs the metadata's 7", D.FAIL, got,
                 "a declared column that is wrong in the LOW direction is the "
                 "dangerous direction -- it would bind a postfix on a call "
                 "with stack arguments -- so the metadata, not the comment, "
                 "is the ground truth"))
    else:
        print("SKIP   metadata cross-check: GameAssembly.dll or the decrypted "
              "metadata is absent. NOT a pass.")

    print("\n%s -- %d case(s) misbehaved" % ("FAIL" if bad else "PASS", bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
