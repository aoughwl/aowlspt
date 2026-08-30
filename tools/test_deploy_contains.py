#!/usr/bin/env python3
"""test_deploy_contains.py -- falsifiable tests for deploy.py's literal scan.

Run:
  python tools/test_deploy_contains.py

Why this file exists. `aowl build-mod` prints `ok mod X` with NO marker
verification, and `deploy.py check --only NAME` verifies a marker set that
PREDATES tonight's edit -- it proves the artifact is a valid build of that
target, not that your change is in it. So agents hand-rolled byte probes, and
the obvious PowerShell one
(`[Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes(p)).Contains(s)`)
returns SELECTIVE false negatives (facts #151/#152). `--contains` /
`--absent` replace that. This file is the first automated coverage deploy.py's
CLI has ever had.

What is asserted, in both directions -- a test that only checked "found it"
would pass for an implementation that answers PASS to everything:

  1. utf8 hit                  -- literal stored as plain bytes is found
  2. utf16-only hit            -- a literal that exists ONLY as UTF-16LE must
                                  NOT read as absent (the measured case:
                                  /aowlspt/settings/aowl.uihub), and the
                                  report must name the encoding that matched
  3. absent                    -- a literal in neither encoding is NO-MATCH /
                                  INCONCLUSIVE (never FAIL: a miss does not
                                  prove absence), and the message names the
                                  literal, the encodings searched, the path
                                  and the size
  4. --absent inverse          -- passes when gone, FAILs when still present
  5. --encoding override       -- utf8 alone must MISS a utf16-only literal
                                  (this is what makes check 2 meaningful)
  6. additive, never a rescue  -- a passing --contains must not turn a missing
                                  MARKER into ok, and a failing --contains
                                  must make an otherwise-ok artifact FAIL
  7. unreadable file           -- INCONCLUSIVE, not FAIL and not ok (9b)
  8. CLI end-to-end            -- exit 0 on pass, non-zero on fail, through
                                  argparse, on a real temp artifact
  9. fragmentation             -- the measured defect: a literal spanning a
                                  Nim `&` concatenation is stored as separate
                                  rodata fragments, so it can NEVER match
                                  contiguously. It must come back NO-MATCH /
                                  INCONCLUSIVE with the longest present
                                  fragment named -- not a flat FAIL reading
                                  "the feature is missing". And --absent must
                                  NOT report a removal as done when a long
                                  fragment of the literal survives.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import deploy                                   # noqa: E402

DEPLOY = os.path.join(HERE, "deploy.py")
NOCOLOR = ("", "", "", "", "")

FAILURES = []


def check(name, cond, detail=""):
    print("%-6s %s%s" % ("ok" if cond else "FAIL", name,
                         "" if cond else "   <- " + detail))
    if not cond:
        FAILURES.append(name)


def joined(lines):
    return "\n".join(lines)


def main():
    tmp = tempfile.mkdtemp(prefix="deploycontains-")
    art = os.path.join(tmp, "fake-artifact.dll")
    # A COPY of deploy.py in a temp tools/ dir, so the CLI half of this test
    # runs against a throwaway deploy.json. Deliberately not an env-var
    # override in deploy.py itself: CLAUDE.md forbids making a check pass by
    # editing marker data, and "point the tool at another config" would be a
    # bigger version of exactly that hole. CONFIG is derived from the script's
    # own directory, so copying the script is enough.
    tools = os.path.join(tmp, "tools")
    os.makedirs(tools)
    shutil.copyfile(DEPLOY, os.path.join(tools, "deploy.py"))
    # A fake artifact shaped like the real ones: one string only as raw bytes,
    # one string ONLY as UTF-16LE, and padding so a size is reported.
    with open(art, "wb") as f:
        f.write(b"\x00" * 64)
        f.write(b"launchHint WRITTEN to aowl.uihub")
        f.write(b"\x00" * 32)
        f.write("/aowlspt/settings/aowl.uihub".encode("utf-16-le"))
        f.write(b"\x00" * 64)
        # The measured nimony shape: `"the feed " & x & " ARMED in place"`
        # compiles to SEPARATE rodata strings, so the assembled sentence is
        # nowhere in the file even though both halves are.
        f.write(b"the feed was NEVER")
        f.write(b"\x00" * 16)
        f.write(b"ARMED in place")
        f.write(b"\x00" * 64)

    UTF8_LIT = "launchHint WRITTEN to aowl.uihub"
    U16_LIT = "/aowlspt/settings/aowl.uihub"
    GONE = "zzz-this-literal-does-not-exist-9f3a"

    # 1. utf8 hit
    v, lines = deploy.verify_literals(art, [UTF8_LIT], [], "any", NOCOLOR)
    check("1 utf8 hit", v == deploy.OK and "as utf8" in joined(lines),
          joined(lines))

    # 2. utf16-only hit must not read as absent, and must name the encoding
    v, lines = deploy.verify_literals(art, [U16_LIT], [], "any", NOCOLOR)
    check("2 utf16-only hit", v == deploy.OK and "as utf16le" in joined(lines),
          joined(lines))

    # 3. a miss is NO-MATCH / INCONCLUSIVE, diagnostically -- NOT FAIL.
    v, lines = deploy.verify_literals(art, [GONE], [], "any", NOCOLOR)
    text = joined(lines)
    check("3 miss is INCONCLUSIVE, not FAIL",
          v == deploy.INCONCLUSIVE and "NO-MATCH" in text and GONE in text and "utf8/utf16le" in text
          and art in text and str(os.path.getsize(art)) in text, text)

    # 4. --absent inverse, both directions
    v, lines = deploy.verify_literals(art, [], [GONE], "any", NOCOLOR)
    check("4a absent-passes-when-gone", v == deploy.OK, joined(lines))
    v, lines = deploy.verify_literals(art, [], [UTF8_LIT], "any", NOCOLOR)
    check("4b absent-FAILs-when-present",
          v == deploy.FAIL and "IS STILL PRESENT" in joined(lines),
          joined(lines))
    # ... and the inverse must respect UTF-16 too, or a removal reads as done
    v, lines = deploy.verify_literals(art, [], [U16_LIT], "any", NOCOLOR)
    check("4c absent-sees-utf16", v == deploy.FAIL, joined(lines))

    # 5. --encoding override: utf8 alone MISSES the utf16-only literal.
    #    This is what makes check 2 falsifiable rather than tautological.
    v, _ = deploy.verify_literals(art, [U16_LIT], [], "utf8", NOCOLOR)
    check("5a utf8-only misses utf16 literal", v == deploy.INCONCLUSIVE)
    v, _ = deploy.verify_literals(art, [U16_LIT], [], "utf16", NOCOLOR)
    check("5b utf16-only finds it", v == deploy.OK)
    v, _ = deploy.verify_literals(art, [UTF8_LIT], [], "utf16", NOCOLOR)
    check("5c utf16-only misses utf8 literal", v == deploy.INCONCLUSIVE)

    # 7. unreadable file is INCONCLUSIVE -- neither a pass nor a content fail
    v, lines = deploy.verify_literals(os.path.join(tmp, "nope.dll"),
                                      [UTF8_LIT], [], "any", NOCOLOR)
    check("7 missing file INCONCLUSIVE",
          v == deploy.INCONCLUSIVE and "nothing was searched" in joined(lines),
          joined(lines))

    # 6 + 8. End-to-end through the CLI against a throwaway deploy.json, so
    # the marker path and the literal path are exercised together.
    cfgpath = os.path.join(tools, "deploy.json")
    relsrc = "fake-artifact.dll"        # relative to the copy's REPO (= tmp)
    cfg = {"install": tmp,
           "artifacts": [{"name": "fake", "src": relsrc, "dst": "fake.dll",
                          "minBytes": 1,
                          "markers": ["launchHint WRITTEN to aowl.uihub"]},
                         {"name": "brokenmarker", "src": relsrc,
                          "dst": "fake.dll", "minBytes": 1,
                          "markers": [GONE]}]}
    with open(cfgpath, "w", newline="\n") as f:
        json.dump(cfg, f)

    def run(*a):
        p = subprocess.run([sys.executable, os.path.join(tools, "deploy.py"),
                            "check", "--no-color", "--artifact", art]
                           + list(a), capture_output=True, text=True)
        return p.returncode, p.stdout + p.stderr

    rc, out = run("--only", "fake", "--contains", UTF8_LIT,
                  "--contains", U16_LIT)
    check("8a CLI both literals pass -> exit 0", rc == 0, "rc=%d\n%s" % (rc, out))
    check("8b CLI reports the encodings",
          "as utf8" in out and "as utf16le" in out, out)

    rc, out = run("--only", "fake", "--contains", GONE)
    check("8c CLI missing literal -> exit 3 (INCONCLUSIVE), not 1",
          rc == 3 and "NO-MATCH" in out, "rc=%d\n%s" % (rc, out))

    rc, out = run("--only", "fake", "--contains", "was NEVER ARMED in place")
    check("8f CLI fragmented literal -> exit 3 with the hint",
          rc == 3 and "longest present fragment" in out,
          "rc=%d\n%s" % (rc, out))

    rc, out = run("--only", "fake", "--absent", GONE)
    check("8d CLI --absent passes -> exit 0", rc == 0, "rc=%d\n%s" % (rc, out))

    rc, out = run("--only", "fake", "--absent", UTF8_LIT)
    check("8e CLI --absent present -> non-zero", rc != 0,
          "rc=%d\n%s" % (rc, out))

    # 9. FRAGMENTATION. "was NEVER ARMED" is in the source of the fake
    #    artifact's two halves but can never appear contiguously.
    FRAG = "was NEVER ARMED in place"
    v, lines = deploy.verify_literals(art, [FRAG], [], "any", NOCOLOR)
    text = joined(lines)
    check("9a fragmented literal is INCONCLUSIVE, not FAIL",
          v == deploy.INCONCLUSIVE and "NO-MATCH" in text, text)
    check("9b names the longest present fragment",
          "longest present fragment: 'ARMED in place'" in text, text)
    check("9c says a miss is not proof of absence",
          "NOT proof the feature is absent" in text
          and "&` concatenation" in text, text)
    # ... and the genuinely-absent literal must NOT claim a fragment, or the
    #     hint would fire on everything and mean nothing.
    v, lines = deploy.verify_literals(art, [GONE], [], "any", NOCOLOR)
    check("9d genuinely-absent claims no fragment",
          "longest present fragment" not in joined(lines)
          and "may well be genuinely absent" in joined(lines), joined(lines))
    # 9e THE DANGEROUS DIRECTION: --absent must not certify a removal that
    #    did not happen just because the sentence is stored in pieces.
    v, lines = deploy.verify_literals(art, [], [FRAG], "any", NOCOLOR)
    check("9e --absent under fragmentation is INCONCLUSIVE",
          v == deploy.INCONCLUSIVE
          and "removal is NOT demonstrated" in joined(lines), joined(lines))
    # 9f ... while a truly gone literal still PASSes --absent, carrying the
    #     caveat. Without this, 9e would be satisfied by "always unsure".
    v, lines = deploy.verify_literals(art, [], [GONE], "any", NOCOLOR)
    check("9f --absent still PASSes when truly gone, with the caveat",
          v == deploy.OK and "caveat" in joined(lines), joined(lines))

    # 6. ADDITIVE: a passing --contains must NOT rescue a missing marker.
    rc, out = run("--only", "brokenmarker", "--contains", UTF8_LIT)
    check("6 passing --contains does not rescue a missing marker",
          rc != 0 and "MISSING" in out, "rc=%d\n%s" % (rc, out))

    print("")
    if FAILURES:
        print("%d check(s) FAILED: %s" % (len(FAILURES), ", ".join(FAILURES)))
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
