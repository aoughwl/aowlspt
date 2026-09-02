"""test_resolver_flags.py -- falsifiable tests for the additions made to
il2cpp_resolve.py: MethodAttributes (flags@28), the `holdersof` query, the
numeric-needle refusal, and the usage-text/VERBS agreement.

    python tools/test_resolver_flags.py D:/Games/Tarkov/GameAssembly.dll \
                                        .cache/global-metadata.dec.dat

Why this file exists (CLAUDE.md 9b): every assertion below is a property of an
INDEPENDENTLY-MEASURED finished state, not of the code that produces it.

  * flags@28 is asserted against a value measured by hand by another agent
    (EFT.Player getter rows read 0x09E6). Point `mflags` at any other offset
    -- 24 is the token, 34 is parameterCount -- and check 1 goes red. A check
    that read the value back through the same offset it wrote could not fail.
  * `holdersof` is asserted to find EFT.Player.Physical at 0x9D8, a field
    offset measured tonight. Both the offset AND the owner must match, so a
    holdersof that matched everything, or nothing, fails.
  * the numeric-needle refusal is asserted to REFUSE. The falsifying input is
    the old behaviour: a confident "no method name contains '16622'".
  * usage_gaps() is asserted EMPTY. Adding a verb without documenting it goes
    red, which is the defect that made two agents hand-roll arity filtering.

PASS / FAIL / and nothing in between: an assertion whose subject cannot be
resolved at all is a FAILURE here, not a skip. "I could not look" is not a pass.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import il2cpp_resolve as IR                                   # noqa: E402

FAILURES = []


def searched_names(blob):
    """True iff `methods` actually SEARCHED method names and found none.

    Matched case-insensitively and by both halves of the sentence, because the
    tool's own wording is not a stable API: it moved from "no method name
    contains" to "no METHOD NAME contains" and a case-sensitive `in` turned
    one check red and its partner's negative clause VACUOUS at the same time.
    """
    low = blob.lower()
    return "no method name contains" in low


def check(name, got, want):
    ok = got == want
    print("%-4s %-46s got=%-28r want=%r"
          % ("PASS" if ok else "FAIL", name, got, want))
    if not ok:
        FAILURES.append(name)


def method_flags(R, type_name, method_name):
    """Raw flags for exactly ONE method. Ambiguity is a FAILURE, never a
    silent first-match: EFT.Player declares get_Position twice (the public one
    and an explicit Dissonance.IDissonancePlayer implementation), so 'the
    first one' is a coin flip dressed up as an answer."""
    t = R.find_one(type_name)
    hits = [mi for mi in R.type_methods(t) if R.mname(mi) == method_name]
    if len(hits) != 1:
        return "<%d methods named %r on %s>" % (len(hits), method_name,
                                                type_name)
    return R.mflags(hits[0])


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    ga, md = sys.argv[1], sys.argv[2]
    R = IR.Resolver(ga, md)

    # 1-2. flags@28, against hand-measured EFT.Player values.
    check("EFT.Player::get_Position flags",
          method_flags(R, "EFT.Player", "get_Position"), 0x09E6)
    check("EFT.Player::get_IsAI flags",
          method_flags(R, "EFT.Player", "get_IsAI"), 0x09E6)

    # 3. and that those flags DECODE to a bind verdict, not just print.
    d = IR.decode_mattrs(0x09E6)
    check("0x09E6 decodes VIRTUAL+FINAL+NEWSLOT",
          all(w in d for w in ("VIRTUAL", "FINAL", "NEWSLOT", "PUBLIC")), True)
    # 4. The NEGATIVE direction -- what a "decoder" that always says the
    #    reassuring thing would get wrong. 0x00C6 is VIRTUAL and NOT FINAL.
    check("overridable virtual is called a HAZARD",
          "HAZARD" in IR.decode_mattrs(0x00C6), True)
    check("non-virtual is NOT called a hazard",
          "HAZARD" in IR.decode_mattrs(0x0086), False)

    # 5-6. holdersof finds a measured field, at its measured offset.
    t = R.find_one("EFT.Player")
    phys = [r for r in R.declared_fields_ex(t)
            if r["typename"] == "PhysicalBase"]
    check("EFT.Player holds exactly one PhysicalBase", len(phys), 1)
    check("EFT.Player.Physical offset",
          (phys[0]["name"], hex(phys[0]["off"])) if phys else None,
          ("Physical", "0x9d8"))

    # 7. the CLI path, end to end -- the library being right does not prove
    #    the verb is wired up.
    out = subprocess.run([sys.executable, os.path.join(HERE, "il2cpp_resolve.py"),
                          ga, md, "holdersof", "PhysicalBase", "--fields"],
                         capture_output=True, text=True).stdout
    check("holdersof CLI prints EFT.Player.Physical @0x9D8",
          "EFT.Player.Physical : PhysicalBase  @0x9D8" in out, True)

    # 8. the numeric needle must REFUSE, not answer. The falsifying output is
    #    the old one: "no method name contains '16622'".
    p = subprocess.run([sys.executable, os.path.join(HERE, "il2cpp_resolve.py"),
                        ga, md, "methods", "16622"],
                       capture_output=True, text=True)
    blob = p.stdout + p.stderr
    check("methods <number> refuses",
          ("usage error" in blob.lower() and "ambiguous" in blob.lower()
           and not searched_names(blob)),
          True)
    check("methods <number> exits non-zero", p.returncode != 0, True)

    # 9. and --name still lets you mean the digits. This is ALSO the positive
    #    control for check 8's negative clause: the two use the same matcher,
    #    so if searched_names() ever stops recognising the zero-hit line, THIS
    #    check goes red instead of check 8 passing vacuously. It did exactly
    #    that once -- the tool's wording changed case to "no METHOD NAME
    #    contains", a case-sensitive `in` stopped matching, check 9 failed and
    #    check 8's negative became a clause that could not fail.
    p = subprocess.run([sys.executable, os.path.join(HERE, "il2cpp_resolve.py"),
                        ga, md, "methods", "--name", "16622"],
                       capture_output=True, text=True)
    nblob = p.stdout + p.stderr
    check("methods --name <number> searches the substring",
          searched_names(nblob), True)
    check("methods --name <number> does NOT refuse", p.returncode == 0, True)

    # 10. usage text vs VERBS.
    check("no verb missing from the Usage: block", IR.usage_gaps(), [])

    print()
    if FAILURES:
        print("FAIL -- %d check(s) failed: %s"
              % (len(FAILURES), ", ".join(FAILURES)))
        return 1
    print("PASS -- 0 check(s) failed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
