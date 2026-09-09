#!/usr/bin/env python3
"""test_resolver_shared.py -- falsifiable tests for Resolver sharedness.

Run:
  python tools/test_resolver_shared.py D:/Games/Tarkov/GameAssembly.dll \
      .cache/global-metadata.dec.dat

Why this file exists (CLAUDE.md 9b): sharedness was decided in TWO places --
`Resolver.shared_rva_counts()` for library callers and an open-coded
`shared.get(rva, 1)` in each of two CLI verbs. The literal `1` default meant
"an address I have never heard of" read back as "one owner == safe to detour",
which is a check that cannot fail. The assertions below are chosen so each one
CAN fail:

  * a KNOWN-SHARED address must report shared, with the exact owner count;
  * a KNOWN-UNIQUE address must report NOT shared -- this direction is what a
    blanket "everything is shared" fix would break;
  * a VA and an address that is in no table must NOT be reported unique;
  * the CLI text and the library verdict must AGREE on the same input -- the
    assertion that would have caught the original divergence.

Ground truth (measured on build 1.1.0.1.46777, imagebase 0x180000000):
  0x52A8A80  UnityEngine.GameObject::AddComponent(Type)  SHARED with
             Internal_AddComponentWithType -> 2 owners
  0x52A8F40  UnityEngine.GameObject::.ctor(string)       unique
  0x52B8380  UnityEngine.Transform::SetParent            unique
"""
import os, subprocess, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from il2cpp_resolve import Resolver          # noqa: E402

TOOL = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                    "il2cpp_resolve.py")

SHARED_CASES = [(0x52A8A80, 2)]
UNIQUE_CASES = [0x52A8F40, 0x52B8380]
# not a code address in the histogram; must NOT come back "unique"
BOGUS = 0x999999


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    gameasm, metadec = sys.argv[1], sys.argv[2]
    R = Resolver(gameasm, metadec)
    fails = []

    def check(name, cond, detail):
        print("%-4s %s   %s" % ("PASS" if cond else "FAIL", name, detail))
        if not cond:
            fails.append(name)

    for rva, want in SHARED_CASES:
        state, n = R.sharedness(rva)
        check("shared/rva 0x%X" % rva, state == "shared" and n == want,
              "got state=%s owners=%d (want shared/%d)" % (state, n, want))
        # the SAME address expressed as a VA must give the SAME verdict; the
        # old open-coded .get() silently said "not shared" for the VA form.
        vs, vn = R.sharedness(R.IB + rva)
        check("shared/va  0x%X" % (R.IB + rva), (vs, vn) == (state, n),
              "VA form got %s/%d, RVA form %s/%d" % (vs, vn, state, n))

    for rva in UNIQUE_CASES:
        state, n = R.sharedness(rva)
        check("unique/rva 0x%X" % rva, state == "unique" and n == 1,
              "got state=%s owners=%d (want unique/1)" % (state, n))
        check("unique/note 0x%X" % rva, R.sharedness_note(rva) == "",
              "a known-unique address must produce no warning text")

    state, n = R.sharedness(BOGUS)
    check("unknown 0x%X" % BOGUS, state == "unknown",
          "an address absent from the histogram must be UNKNOWN, never "
          "unique; got %s/%d" % (state, n))

    # CLI vs library. This is the assertion that catches divergence: it does
    # not re-implement the answer, it reads what the CLI PRINTS.
    cli_cache = {}

    def cli_lines(typename):
        if typename not in cli_cache:
            cli_cache[typename] = subprocess.run(
                [sys.executable, TOOL, gameasm, metadec, "type", typename,
                 "--shared"], capture_output=True, text=True).stdout.splitlines()
        return cli_cache[typename]

    for rva, typename in ((0x52A8A80, "UnityEngine.GameObject"),
                          (0x52A8F40, "UnityEngine.GameObject"),
                          (0x52B8380, "UnityEngine.Transform")):
        lines = cli_lines(typename)
        tag = "RVA=" + hex(rva)
        idx = [i for i, l in enumerate(lines) if tag in l]
        if not idx:
            check("cli/lib 0x%X" % rva, False,
                  "CLI printed no line containing %s" % tag)
            continue
        cli_says_shared = any("[SHARED:" in lines[i + 1]
                              for i in idx if i + 1 < len(lines))
        lib_says_shared = R.sharedness(rva)[0] == "shared"
        check("cli/lib 0x%X" % rva, cli_says_shared == lib_says_shared,
              "CLI shared=%s  library shared=%s" % (cli_says_shared,
                                                    lib_says_shared))

    print("\n%s -- %d check(s) failed" % ("FAIL" if fails else "PASS",
                                          len(fails)))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
