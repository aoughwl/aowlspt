#!/usr/bin/env python3
"""Verify feature markers in ANY built DLL -- mod DLLs especially.

`tools/deploy.py` does this for the HOST artifacts and only for those: its
marker sets live in `tools/deploy.json` and are tied to install destinations.
There was no equivalent for `mods/*/bin/*.dll`, so agents hand-rolled it, and
the hand-rolled version was:

    [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($p)).Contains($s)

which reported FOURTEEN markers missing from a mod DLL, including a literal
that predated the change under test. A confidently wrong "not in the artifact"
is the worst defect class in this repo, so this tool is built so it cannot
produce one:

  * it NEVER decodes the file. It encodes the NEEDLE (ascii, utf8, utf16le,
    latin1) and searches the raw bytes, and reports WHICH encoding matched.
    MEASURED on PowerShell 5.1.19041.6456:
    `[Text.Encoding]::ASCII.GetString([byte[]](0x41,0xE2,0x80,0xA6,0x42))`
    returns "A???B" -- every byte >= 0x80 becomes '?'. So a literal
    containing so much as a U+2026 can NEVER be found, and, worse, a needle
    containing a literal '?' can match rubbish. Both directions are wrong;
    neither is possible here. Repro, on maps.dll, of a real marker the idiom
    calls absent and this tool finds as utf8 (only) at byte offset 0x7c0fe:
        "(ents[i].id ? ' " + [char]0x2026 + "' + ents[i].id"
    And there is no quick fix over there: on that runtime
    `[Text.Encoding]::Latin1` evaluates to $NULL (the property is a .NET Core
    addition) -- and PowerShell returns $null for a missing static property
    instead of throwing, so a `try/catch` probe for it reports success. Use
    this tool.

  * it has THREE outcomes per marker, never two, because nimony stores each
    `&`-concatenated source fragment as a SEPARATE rodata entry: a sentence
    assembled from fragments is genuinely not in the bytes contiguously while
    every piece of it is. That is a SPLIT, not a removal, and calling it
    MISSING is the false negative above.

        PRESENT       a contiguous hit, with encodings and byte offset.
        MISSING       no contiguous hit, the surviving word-runs cover less
                      than 60% of the literal, AND a positive control matched.
        INCONCLUSIVE  no contiguous hit but most of it survives as word-runs
                      (a split), or NO positive control matched -- in which
                      case "not found" cannot be told apart from "we could not
                      look", which is not a verdict (CLAUDE.md 9b).

    The fragment logic is not reimplemented here: it is `tools/litscan.py`,
    shared with deploy.py, so the two cannot drift.

USAGE

    python tools/markers.py DLL "marker one" "marker two" ...
    python tools/markers.py DLL --markers-file mods/maps/markers.json
    python tools/markers.py DLL -f FILE --min-markers 21
    python tools/markers.py DLL --absent "old text" --control "known text"
    python tools/markers.py --selftest

    --encoding any|ascii|utf8|utf16|latin1     default any
    --json          machine-readable result on stdout
    --quiet         only the verdict lines

EXIT CODES.  0 present/pass, 1 MISSING or an --absent literal still present,
3 INCONCLUSIVE, 2 usage error.  **3 is not success.** A release script that
folds 3 into 0 has rebuilt the check-that-cannot-fail this tool exists to
avoid.

MARKERS AS DATA, WITHOUT THE ESCAPE HATCH
-----------------------------------------
`--markers-file` takes JSON (`["a","b"]`, or `{"markers": [...], "absent":
[...]}`) or a plain-text file, one marker per line, `#` comments. That mirrors
`tools/deploy.json` being data -- a mod owns its own fingerprints.

But data you can edit is data you can edit to make a red check green, and the
deploy.json rule ("never edit it to make a check pass") is enforced only by
prose. So this tool removes the quiet ways to do it:

  * markers given on the command line are ADDITIVE and cannot be switched off
    by any file;
  * there is NO per-marker `optional`, `skip` or `expect` key. An unrecognised
    key in a markers file is a usage error, so nobody can invent one;
  * an EMPTY marker set is INCONCLUSIVE, never a pass. Deleting the contents
    of the file therefore does not turn a failing check green, it turns it
    yellow;
  * `--min-markers N` asserts at least N markers were actually checked, and
    the report always prints the count and the SHA-256 of every markers file
    it read. Pin N in your CI line and shrinking the data file is loud;
  * the file cannot name the artifact. You pass the DLL, so a markers file
    cannot redirect the check at a binary where the markers happen to live.

None of that makes the data trustworthy; it makes a weakening EDIT VISIBLE in
the output, which is the most a tool on this side of the wall can do.
"""

import argparse
import hashlib
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import litscan  # noqa: E402

PRESENT = "present"
MISSING = "missing"
INCONCLUSIVE = litscan.INCONCLUSIVE

RESET, RED, GREEN, YELLOW, DIM = (
    "\033[0m", "\033[31m", "\033[32m", "\033[33m", "\033[2m")

_ALLOWED_KEYS = ("markers", "absent", "control", "why", "//", "note")


def _color(on):
    return (RED, GREEN, YELLOW, DIM, RESET) if on else ("",) * 5


def _sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


class UsageError(Exception):
    pass


def load_markers_file(path):
    """(markers, absent, controls, provenance-line) from ONE data file.

    Raises UsageError on anything ambiguous. There is deliberately no lenient
    path: a markers file that this tool half-understands is a marker set that
    silently shrank.
    """
    if not os.path.isfile(path):
        raise UsageError("no such markers file: %s" % path)
    with open(path, "r", encoding="utf-8-sig") as f:
        raw = f.read()
    markers, absent, controls = [], [], []
    stripped = raw.lstrip()
    if stripped[:1] in ("[", "{"):
        try:
            doc = json.loads(raw)
        except ValueError as e:
            raise UsageError("%s is not valid JSON: %s" % (path, e))
        if isinstance(doc, list):
            markers = list(doc)
        elif isinstance(doc, dict):
            bad = [k for k in doc
                   if k not in _ALLOWED_KEYS and not k.startswith("//")]
            if bad:
                raise UsageError(
                    "%s has unrecognised key(s) %s. Only %s are understood; "
                    "there is no `optional`/`skip`/`expect` key by design, "
                    "because that is how a marker set gets quietly weakened."
                    % (path, ", ".join(sorted(bad)),
                       ", ".join(_ALLOWED_KEYS[:3])))
            markers = list(doc.get("markers") or [])
            absent = list(doc.get("absent") or [])
            controls = list(doc.get("control") or [])
        else:
            raise UsageError("%s must be a JSON list or object" % path)
    else:
        for line in raw.splitlines():
            line = line.strip("\r\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            markers.append(line)
    for name, seq in (("markers", markers), ("absent", absent),
                      ("control", controls)):
        for item in seq:
            if not isinstance(item, str) or not item:
                raise UsageError("%s: %s must be a list of non-empty strings"
                                 % (path, name))
    prov = ("%s  sha256=%s  markers=%d absent=%d control=%d"
            % (path, _sha(path)[:16], len(markers), len(absent),
               len(controls)))
    return markers, absent, controls, prov


def classify(blob, encs, lit, control):
    """(outcome, detail-dict) for ONE marker expected to be PRESENT.

    `control` is a matched positive control (or None). It is the whole reason
    MISSING is allowed to be said at all: without proof that this search can
    find text in these bytes, "not found" is "we could not look".
    """
    hits, off = litscan.find_at(blob, encs, lit)
    if hits:
        return PRESENT, {"encodings": hits, "offset": off}
    frags, covered = litscan.fragment_cover(blob, encs, lit)
    ratio = litscan.coverage_ratio(covered, lit)
    d = {"encodings": [], "offset": -1, "coverage": ratio,
         "covered": covered, "length": len(lit),
         "fragments": [[t, e] for t, e in frags]}
    if ratio >= litscan.ABSENT_COVERAGE:
        d["reason"] = (
            "not contiguous, but %d of %d bytes (%.0f%%) survive as %d "
            "word-run(s) -- the shape of a literal SPLIT across rodata "
            "fragments, not of a removal."
            % (covered, len(lit), ratio * 100.0, len(frags)))
        return INCONCLUSIVE, d
    if control is None:
        d["reason"] = (
            "no positive control matched, so this search was never shown to "
            "be CAPABLE of finding text in these bytes; \"not found\" here is "
            "indistinguishable from \"we could not look\". Give a marker you "
            "know is present, or --control LIT.")
        return INCONCLUSIVE, d
    d["reason"] = (
        "no contiguous match at any searched encoding, and only %d of %d "
        "bytes (%.0f%%) survive as word-runs -- below the %.0f%% that would "
        "indicate a merely SPLIT literal."
        % (covered, len(lit), ratio * 100.0,
           litscan.ABSENT_COVERAGE * 100.0))
    d["control"] = control[1]
    return MISSING, d


def scan(path, markers, absent, controls, mode):
    """Scan ONE file. Returns a result dict; never raises on content."""
    encs = litscan.encodings(mode)
    searched = "/".join(lbl for lbl, _ in encs)
    res = {"file": path, "encodings": searched, "results": [],
           "absent": [], "verdict": INCONCLUSIVE, "note": None}
    if not os.path.isfile(path):
        res["note"] = ("no such file: %s -- nothing was searched, which is "
                       "NOT evidence any marker is absent." % path)
        return res
    try:
        with open(path, "rb") as f:
            blob = f.read()
    except OSError as e:
        res["note"] = ("could not read %s: %s -- nothing was searched."
                       % (path, e))
        return res
    res["size"] = len(blob)
    if not markers and not absent:
        res["note"] = ("no markers were supplied, so nothing was checked. An "
                       "empty marker set is INCONCLUSIVE, never a pass.")
        return res
    # The positive control: an explicit --control that matches, else the first
    # DECLARED MARKER that matches. Using the marker set itself is what makes
    # the common case work without ceremony -- if seven of twenty-one markers
    # are found, the search is demonstrably working and the other fourteen
    # can honestly be called MISSING.
    pool = [("--control", c) for c in (controls or [])]
    pool += [("marker", m) for m in markers]
    control = litscan.pick_control(blob, encs, pool)
    res["control"] = list(control) if control else None
    for lit in markers:
        outcome, detail = classify(blob, encs, lit, control)
        detail["marker"] = lit
        detail["outcome"] = outcome
        res["results"].append(detail)
    for lit in absent:
        hits, off = litscan.find_at(blob, encs, lit)
        if hits:
            res["absent"].append({"marker": lit, "outcome": "fail",
                                  "encodings": hits, "offset": off,
                                  "reason": "IS STILL PRESENT"})
            continue
        frags, covered = litscan.fragment_cover(blob, encs, lit)
        ratio = litscan.coverage_ratio(covered, lit)
        d = {"marker": lit, "coverage": ratio, "covered": covered,
             "length": len(lit), "fragments": [[t, e] for t, e in frags]}
        if ratio >= litscan.ABSENT_COVERAGE:
            d["outcome"] = INCONCLUSIVE
            d["reason"] = ("%d of %d bytes (%.0f%%) survive as word-runs -- "
                           "consistent with a SPLIT literal, not a removal."
                           % (covered, len(lit), ratio * 100.0))
        elif control is None:
            d["outcome"] = INCONCLUSIVE
            d["reason"] = ("no positive control matched; this search was "
                           "never shown capable of finding text here.")
        else:
            d["outcome"] = "pass"
            d["reason"] = ("in neither %s, only %.0f%% survives as word-runs, "
                           "and control %s DOES match at 0x%x."
                           % (searched, ratio * 100.0, ascii(control[1]), control[3]))
        res["absent"].append(d)
    outs = [r["outcome"] for r in res["results"]]
    aouts = [r["outcome"] for r in res["absent"]]
    if MISSING in outs or "fail" in aouts:
        res["verdict"] = "fail"
    elif INCONCLUSIVE in outs or INCONCLUSIVE in aouts:
        res["verdict"] = INCONCLUSIVE
    else:
        res["verdict"] = "ok"
    return res


def _q(s):
    """ASCII-safe quoting of a marker for printing.

    `repr()` keeps non-ASCII characters literal, and a Windows console on
    cp1252/cp437 then raises UnicodeEncodeError -- so printing the very
    marker class the PowerShell ASCII idiom gets wrong would crash the tool
    reporting it. `ascii()` escapes them (�) and stays unambiguous.
    """
    return ascii(s)


def report(res, C, quiet=False):
    red, green, yellow, dim, reset = C
    out = []
    if res.get("note"):
        out.append("%sINCONCLUSIVE%s %s" % (yellow, reset, res["note"]))
        return out
    out.append("%s%s  (%d bytes)  searched as %s%s"
               % (dim, res["file"], res["size"], res["encodings"], reset))
    ctl = res.get("control")
    if ctl:
        out.append("%s  positive control (%s) %s matches as %s at 0x%x%s"
                   % (dim, ctl[0], _q(ctl[1]), "+".join(ctl[2]), ctl[3],
                      reset))
    else:
        out.append("%s  NO positive control matched -- every miss below is "
                   "INCONCLUSIVE, not MISSING.%s" % (yellow, reset))
    for r in res["results"]:
        o = r["outcome"]
        if o == PRESENT:
            if not quiet:
                out.append("%sPRESENT%s      %s  as %s at 0x%x"
                           % (green, reset, _q(r["marker"]),
                              "+".join(r["encodings"]), r["offset"]))
            continue
        col = red if o == MISSING else yellow
        out.append("%s%s%s  %s" % (col, o.upper(), reset, _q(r["marker"])))
        out.append("    %s" % r["reason"])
        for t, e in r.get("fragments", []):
            out.append("      still present: %s (%d bytes, as %s)"
                       % (_q(t), len(t), "+".join(e)))
    for r in res["absent"]:
        o = r["outcome"]
        if o == "pass":
            out.append("%sabsent PASS%s  %s" % (green, reset, _q(r["marker"])))
        elif o == "fail":
            out.append("%sabsent FAIL%s  %s  as %s at 0x%x"
                       % (red, reset, _q(r["marker"]), "+".join(r["encodings"]),
                          r["offset"]))
        else:
            out.append("%sabsent INCONCLUSIVE%s  %s" %
                       (yellow, reset, _q(r["marker"])))
        out.append("    %s" % r["reason"])
    return out


# ---------------------------------------------------------------- self-test

# A fix you cannot make FAIL is not verified (CLAUDE.md 9b). So the self-test
# does not merely confirm that known-good markers are found -- anyone can
# write a check that only ever says yes. It asserts all THREE outcomes occur
# against real artifacts, including a marker that is genuinely absent and a
# literal that is present-but-SPLIT, plus the two cases that must degrade to
# INCONCLUSIVE rather than lie: no control, and no file.
_MODS = r"C:\Users\savant\Projects\aowlspt-wt-b6-settingsui\mods"


def _dll(name):
    return os.path.join(_MODS, name, "bin", name + ".dll")


SELFTEST = [
    # (label, dll, markers, absent, controls, expected-verdict,
    #  expected per-marker outcomes)
    ("PRESENT: declared markers of four mod DLLs",
     "uihub", ["groupOf"], [], [], "ok", [PRESENT]),
    ("PRESENT: espColor in debug.dll",
     "debug", ["espColor"], [], [], "ok", [PRESENT]),
    ("PRESENT: three tarkov loot markers, one with a trailing space",
     "tarkov", ["lootWeightMoney", "Loot/Item mix/Category weights",
                "the loot generator now reads: "], [], [], "ok",
     [PRESENT, PRESENT, PRESENT]),
    ("PRESENT: non-ASCII (U+2026) literal the PowerShell ASCII idiom "
     "reports as MISSING",
     "maps", ["(ents[i].id ? ' \u2026' + ents[i].id"], [], [], "ok",
     [PRESENT]),
    ("MISSING: a marker of debug.dll checked against uihub.dll, with "
     "uihub's own marker as the positive control",
     "uihub", ["groupOf", "espColorEspColorNotHere"], [], [], "fail",
     [PRESENT, MISSING]),
    ("INCONCLUSIVE: a literal SPLIT across rodata fragments by nimony's "
     "`&` concatenation -- present in source, not contiguous in bytes",
     "maps", ["LATE ARM", "LATE ARMS the feed in place"], [], [],
     INCONCLUSIVE, [PRESENT, INCONCLUSIVE]),
    ("INCONCLUSIVE: no positive control matched, so a miss cannot be "
     "told apart from 'we could not look'",
     "uihub", ["zzzNotAMarkerAtAll"], [], [], INCONCLUSIVE,
     [INCONCLUSIVE]),
    ("INCONCLUSIVE: empty marker set is never a pass",
     "uihub", [], [], [], INCONCLUSIVE, []),
    ("absent PASS: espColor is genuinely not in uihub.dll, and groupOf "
     "proves the search works there",
     "uihub", [], ["espColorEspColorNotHere"], ["groupOf"], "ok", []),
    ("absent FAIL: espColor IS in debug.dll",
     "debug", [], ["espColor"], ["espColor"], "fail", []),
]


def selftest(C):
    red, green, yellow, dim, reset = C
    ok = True
    seen = set()
    for (label, mod, mk, ab, ctl, want_v, want_o) in SELFTEST:
        path = _dll(mod)
        if not os.path.isfile(path):
            print("%sINCONCLUSIVE%s missing fixture %s -- self-test could "
                  "NOT be performed. This is not a pass."
                  % (yellow, reset, path))
            return 3
        res = scan(path, mk, ab, ctl, "any")
        got_o = [r["outcome"] for r in res["results"]]
        good = (res["verdict"] == want_v and got_o == want_o)
        seen.add(res["verdict"])
        seen.update(got_o)
        seen.update(r["outcome"] for r in res["absent"])
        print("%s%s%s %s" % (green if good else red,
                             "PASS" if good else "FAIL", reset, label))
        if not good:
            ok = False
            print("    wanted verdict=%s outcomes=%s" % (want_v, want_o))
            print("    got    verdict=%s outcomes=%s" % (res["verdict"],
                                                         got_o))
            for line in report(res, C):
                print("      " + line)
    # Unreachable-outcome guard: a self-test in which one of the three
    # outcomes never occurs is a self-test that cannot fail in that direction.
    need = {PRESENT, MISSING, INCONCLUSIVE, "ok", "fail", "pass"}
    absent_outcomes = sorted(need - seen)
    if absent_outcomes:
        ok = False
        print("%sFAIL%s these outcomes never occurred, so the self-test does "
              "not demonstrate them: %s" % (red, reset, absent_outcomes))
    # And the no-file case must degrade, not lie.
    r = scan(os.path.join(_MODS, "nope", "bin", "nope.dll"),
             ["groupOf"], [], [], "any")
    if r["verdict"] != INCONCLUSIVE:
        ok = False
        print("%sFAIL%s a missing FILE must be INCONCLUSIVE, got %s"
              % (red, reset, r["verdict"]))
    else:
        print("%sPASS%s INCONCLUSIVE: an unreadable artifact -- nothing was "
              "searched, so it is not a pass and not a failure" %
              (green, reset))
    print("%s%s%s" % (green if ok else red,
                      "self-test OK -- all three outcomes demonstrated"
                      if ok else "SELF-TEST FAILED", reset))
    return 0 if ok else 1


def main(argv):
    ap = argparse.ArgumentParser(
        prog="markers.py", add_help=True,
        description="Verify feature markers in a built DLL. Three outcomes: "
                    "PRESENT / MISSING / INCONCLUSIVE. Exit 0/1/3.")
    ap.add_argument("dll", nargs="?", help="the built artifact to scan")
    ap.add_argument("markers", nargs="*", help="markers expected PRESENT")
    ap.add_argument("-f", "--markers-file", action="append", default=[],
                    help="JSON or one-per-line marker data (repeatable); "
                         "ADDITIVE to markers given on the command line")
    ap.add_argument("--absent", action="append", default=[],
                    help="literal expected to be GONE (needs a control)")
    ap.add_argument("--control", action="append", default=[],
                    help="a literal you KNOW is in this artifact")
    ap.add_argument("--min-markers", type=int, default=0,
                    help="INCONCLUSIVE unless at least N markers were checked")
    ap.add_argument("--encoding", default="any",
                    choices=["any", "ascii", "utf8", "utf16", "latin1"])
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--quiet", action="store_true",
                    help="suppress the PRESENT lines")
    ap.add_argument("--no-color", action="store_true")
    ap.add_argument("--selftest", action="store_true",
                    help="prove all three outcomes against real mod DLLs")
    args = ap.parse_args(argv)
    C = _color(not args.no_color and sys.stdout.isatty())

    if args.selftest:
        return selftest(C)
    if not args.dll:
        ap.print_usage()
        print("markers.py: a DLL is required (or --selftest)")
        return 2

    markers = list(args.markers)
    absent = list(args.absent)
    controls = list(args.control)
    prov = []
    try:
        for f in args.markers_file:
            m, a, c, p = load_markers_file(f)
            markers += m
            absent += a
            controls += c
            prov.append(p)
    except UsageError as e:
        print("markers.py: %s" % e)
        return 2

    res = scan(args.dll, markers, absent, controls, args.encoding)
    res["provenance"] = prov
    res["markerCount"] = len(markers)
    if args.min_markers and len(markers) < args.min_markers:
        res["verdict"] = INCONCLUSIVE
        res["shortfall"] = (
            "only %d marker(s) were checked but --min-markers %d was "
            "required. The marker DATA may have shrunk; that must not read "
            "as a pass." % (len(markers), args.min_markers))
    if args.json:
        print(json.dumps(res, indent=2, sort_keys=True))
    else:
        for p in prov:
            print("%smarkers from %s%s" % (C[3], p, C[4]))
        for line in report(res, C, args.quiet):
            print(line)
        if res.get("shortfall"):
            print("%sINCONCLUSIVE%s %s" % (C[2], C[4], res["shortfall"]))
        print("verdict: %s  (%d marker(s), %d absent-check(s))"
              % (res["verdict"].upper(), len(markers), len(absent)))
    return {"ok": 0, "fail": 1, INCONCLUSIVE: 3}[res["verdict"]]


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
