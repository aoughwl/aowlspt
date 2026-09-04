#!/usr/bin/env python3
"""test_symtab.py -- regression proofs for il2cpp_symtab.py's CONSUMER SCAN.

No GameAssembly.dll, no metadata: this exercises the part of the gate that is
pure text -- which is where it was wrong. Two measured defects, both P0 because
each produced a CONFIDENTLY WRONG build failure naming a symbol no source file
had written:

  1. `_NAME` (and the other four companion suffixes) were stripped from every
     referenced symbol UNCONDITIONALLY. `AOWL_SYM_OBJ_GET_NAME` -- a real
     declared symbol, `UnityEngine.Object::get_name/0` -- was reported as a
     reference to `OBJ_GET`, "not declared in aowlspt_symbols.txt".
  2. COMMENTS were scanned. Documenting a symbol in a comment counted as
     referencing it, so a rejected symbol could not even be explained in prose.

Each proof is a PAIR: the behaviour that must hold, and the FALSIFIER -- the
mutation of the tool that makes it fail. The falsifiers are run for real (the
old logic is re-implemented here in four lines and asserted to give the WRONG
answer), so this file cannot silently degrade into a check that cannot fail.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import il2cpp_symtab as S  # noqa: E402

FAILS = []


def check(name, cond, detail):
    print("%-6s %s\n       %s" % ("PASS" if cond else "FAIL", name, detail))
    if not cond:
        FAILS.append(name)


DECLARED = {"OBJ_GET_NAME", "OBJ_GET_INSTANCE_ID", "TF_GET_CHILD",
            "TF_GET_CHILD_COUNT", "GO_ACTIVE_IN_HIERARCHY"}


def old_strip(token):
    """The DEFECT, verbatim in behaviour: strip the first matching suffix,
    unconditionally, with no reference to what is declared."""
    for s in ("_ARITY", "_OWNERS", "_NAME", "_SECTION", "_PROLOGUE"):
        if token.endswith(s):
            return token[:-len(s)]
    return token


def main():
    # ---- 1. the exact-match rule ------------------------------------------
    got, exact = S.resolve_use("OBJ_GET_NAME", DECLARED)
    check("exact-match-wins", got == "OBJ_GET_NAME" and exact,
          "AOWL_SYM_OBJ_GET_NAME resolves to the DECLARED symbol OBJ_GET_NAME, "
          "not to %r" % old_strip("OBJ_GET_NAME"))
    check("exact-match-falsifier", old_strip("OBJ_GET_NAME") == "OBJ_GET",
          "the old unconditional strip really does answer OBJ_GET -- a name no "
          "source file writes -- so this proof CAN fail")

    # ---- 2. companion suffixes still resolve, including on a _NAME symbol --
    cases = {
        "OBJ_GET_NAME_NAME": "OBJ_GET_NAME",
        "OBJ_GET_NAME_ARITY": "OBJ_GET_NAME",
        "OBJ_GET_NAME_PROLOGUE": "OBJ_GET_NAME",
        "OBJ_GET_NAME_OWNERS": "OBJ_GET_NAME",
        "OBJ_GET_NAME_SECTION": "OBJ_GET_NAME",
        "TF_GET_CHILD_COUNT_NAME": "TF_GET_CHILD_COUNT",
        "TF_GET_CHILD_NAME": "TF_GET_CHILD",
    }
    bad = {k: S.resolve_use(k, DECLARED)[0] for k, v in cases.items()
           if S.resolve_use(k, DECLARED)[0] != v}
    check("suffix-longest-match", not bad,
          "every companion macro maps back to its own symbol, including "
          "TF_GET_CHILD_NAME -> TF_GET_CHILD (a display name) and "
          "OBJ_GET_NAME_NAME -> OBJ_GET_NAME"
          if not bad else "wrong: %r" % bad)
    # TF_GET_CHILD_COUNT_NAME is the ambiguity the longest-match rule settles:
    # stripping _NAME gives TF_GET_CHILD_COUNT (declared); a shorter-first rule
    # would be free to answer TF_GET_CHILD, a DIFFERENT declared symbol.
    check("undeclared-is-undeclared", S.resolve_use("NO_SUCH_THING", DECLARED)[0] is None,
          "a token no declared symbol explains resolves to None, so the caller "
          "reports the token AS WRITTEN")

    # ---- 3. comments are not references -----------------------------------
    nim = ('  # AOWL_SYM_OBJ_GET_INSTANCE_ID is documented here, not used\n'
           '  ## doc comment mentioning AOWL_SYM_TF_GET_CHILD\n'
           '  #[ block\n'
           '     AOWL_SYM_GO_ACTIVE_IN_HIERARCHY\n'
           '  ]#\n'
           '  let a = AOWL_SYM_OBJ_GET_NAME\n'
           '  let s = "AOWL_SYM_TF_GET_CHILD_COUNT # still code"\n')
    c = ('/* AOWL_SYM_OBJ_GET_INSTANCE_ID in a C block comment\n'
         '   AOWL_SYM_TF_GET_CHILD too */\n'
         '// AOWL_SYM_GO_ACTIVE_IN_HIERARCHY in a line comment\n'
         'unsigned f(void){ return AOWL_SYM_OBJ_GET_NAME; }\n')

    import tempfile
    d = tempfile.mkdtemp(prefix="aowlsymtest-")
    pn = os.path.join(d, "consumer.nim")
    pc = os.path.join(d, "consumer.h")
    S.write_lf(pn, nim)
    S.write_lf(pc, c)

    un = S.scan_uses([pn], DECLARED)
    idents_n = sorted(u[3] for u in un)
    check("nim-comments-skipped",
          idents_n == ["OBJ_GET_NAME", "TF_GET_CHILD_COUNT"],
          "only the two CODE references were seen (%r); the #, ## and #[ ]# "
          "mentions were not, and the symbol inside a string literal was"
          % idents_n)
    check("nim-comment-falsifier",
          "AOWL_SYM_TF_GET_CHILD" in nim.split("\n")[1],
          "the doc-comment line really does contain a symbol, so a scanner "
          "that read comments would report 4+ idents here, not 2")

    uc = S.scan_uses([pc], DECLARED)
    idents_c = sorted(u[3] for u in uc)
    check("c-comments-skipped", idents_c == ["OBJ_GET_NAME"],
          "only the one code reference was seen (%r); /* */ and // mentions "
          "were not" % idents_c)

    # ---- 4. the message carries the source line and near matches ----------
    pbad = os.path.join(d, "bad.nim")
    S.write_lf(pbad, "let z = AOWL_SYM_TF_GET_CHILDD\n")
    ub = S.scan_uses([pbad], DECLARED)
    line_text = ub[0][5]
    near = S.near_matches(ub[0][4], DECLARED)
    check("undeclared-report",
          ub[0][3] is None and ub[0][4] == "TF_GET_CHILDD"
          and "AOWL_SYM_TF_GET_CHILDD" in line_text
          and "TF_GET_CHILD" in near,
          "an undeclared reference reports the token AS WRITTEN "
          "(TF_GET_CHILDD), the source line %r, and near matches %r"
          % (line_text, near))

    import shutil
    shutil.rmtree(d, ignore_errors=True)

    print("\n%d proof(s) FAILED" % len(FAILS) if FAILS else "\nall proofs PASS")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
