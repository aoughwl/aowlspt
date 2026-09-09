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

    python tools/markers.py --string "some literal" path\to\built.dll
    python tools/markers.py DLL "marker one" "marker two" ...
    python tools/markers.py DLL --markers-file mods/maps/markers.json
    python tools/markers.py DLL -f FILE --min-markers 21
    python tools/markers.py DLL --absent "old text" --control "known text"
    python tools/markers.py --for maps
    python tools/markers.py --for maps --artifact <worktree>/mods/maps/bin/maps.dll
    python tools/markers.py --list-artifacts
    python tools/markers.py --selftest

THE ONE-LINER: `--string LITERAL FILE`
-------------------------------------
This is the mode that exists so that NOBODY reaches for the PowerShell idiom
again. It answers exactly the ad-hoc question -- "is this exact string in this
file?" -- against an arbitrary PATH (a build in a worktree; nothing here needs
to be a declared artifact, and nothing here deploys):

    python tools/markers.py --string "settingsColorWidget" mods/uihub/bin/uihub.dll

`--string` is repeatable, is ADDITIVE to any positional markers, and goes
through the identical machinery as every other mode: multi-encoding needle
search (never decoding the file), byte offset and matched encoding on a hit,
fragment-coverage so a nimony `&`-split literal is INCONCLUSIVE rather than
MISSING, and the same exit codes 0/1/3.

Positive-control gating still applies, and in this mode it is AUTOMATIC: the
PE DOS-stub string is used as a last-resort control, so a lone `--string` that
misses can still be reported as an honest MISSING rather than "we could not
look". Any explicit `--control`, or any other marker that matched, is
preferred over it. The scan additionally refuses (INCONCLUSIVE) if the file's
own PE section table says it should be longer than the bytes we read -- the
recorded case where a freshly-built DLL came back TRUNCATED and every marker
therefore read MISSING.

GIT BASH REWRITES A MARKER THAT STARTS WITH `/`
-----------------------------------------------
MEASURED: under Git Bash (MSYSTEM set), `--string "/aowlspt/keybinds"` reaches
python as `C:/Program Files/Git/aowlspt/keybinds` -- the MSYS runtime converts
POSIX-looking absolute paths to Windows paths before the process starts -- and
the tool reported a confident MISSING for a marker that IS in the DLL. EVERY
marker beginning with `/` is affected. The original cannot be recovered, so
markers.py now REFUSES (INCONCLUSIVE, exit 3) when a literal has the rewritten
shape, and names it. Run such a check as:

    MSYS_NO_PATHCONV=1 python tools/markers.py --string "/aowlspt/keybinds" DLL

or from PowerShell. A leading `//` stops the conversion but leaves the extra
slash in the literal, so it is not a fix. Only the root-prefixed shape is
detectable: `/c/Users` becomes `C:/Users`, which is indistinguishable from an
intentional literal and is still searched as given.

Use `--string` when you have just ADDED a marker and want to assert it landed
in the build. Do NOT add it to `tools/deploy.json` for that purpose, and above
all never relax an existing entry there to make a check pass.

MARKERS FROM deploy.json: `--for ARTIFACT`
------------------------------------------
Until this existed, an agent verifying a DLL it had just built had to TYPE THE
MARKERS IN -- i.e. re-read its own writes, which is the check-that-cannot-fail
shape CLAUDE.md 9b is about. The deploy path never had that problem because
its markers are DATA in `tools/deploy.json`. `--for NAME` reads that same
declared set (read-only -- nothing here ever writes deploy.json, and there is
no flag to drop, relax or override a declared marker), and `--artifact PATH`
points the scan at a build that has NOT been deployed, which is the actual
case: subagents build and must never deploy. `--artifact` changes WHICH FILE
is scanned, never WHICH MARKERS are required. Declared PE exports are NOT
checked here -- markers.py scans bytes, and an `{.exportc.}` name is present
as text without being in the export directory; use `deploy.py check` for those
(it says so in the provenance line, rather than leaving you to assume).

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
import io
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
        hint = ""
        if not _looks_like_path(path):
            hint = (" -- that does not look like a path at all. `-f/"
                    "--markers-file` takes a FILE of markers; if you meant it "
                    "as the literal to search for, use `--string %s` instead."
                    % _q(path))
        raise UsageError("no such markers file: %s%s" % (path, hint))
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


REPO = os.path.dirname(HERE)
DEPLOY_JSON = os.path.join(HERE, "deploy.json")


def load_deploy_artifacts(path=DEPLOY_JSON):
    """The DECLARED artifact table from tools/deploy.json, as data.

    READ-ONLY, always. `tools/deploy.json` is the deploy path's source of
    truth for what a valid build must contain (CLAUDE.md 4), and the rule
    "never edit it to make a check pass" is what makes it worth anything.
    Nothing in this file writes it, and `--for` deliberately offers no way to
    override, extend or disable an artifact's declared set from the command
    line -- extra `markers` on argv are additive, exactly as elsewhere.
    """
    if not os.path.isfile(path):
        raise UsageError("no deploy config at %s -- the declared marker sets "
                         "could not be read, so nothing was checked." % path)
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            cfg = json.load(f)
    except ValueError as e:
        raise UsageError("%s is not valid JSON: %s" % (path, e))
    arts = [a for a in cfg.get("artifacts", [])
            if isinstance(a, dict) and not str(a.get("name", "")).startswith("//")]
    if not arts:
        raise UsageError("%s declares no artifacts" % path)
    return arts


def resolve_for(name, artifact=None, path=DEPLOY_JSON):
    """(dll-path, markers, exports, provenance) for a DECLARED artifact.

    This closes the gap that made every subagent verification tonight the
    shape CLAUDE.md 9b warns about: `markers.py` took its markers from argv,
    so an agent checking a DLL it had just built typed in the literals IT had
    just written -- re-reading your own writes, which cannot fail. The deploy
    path never had that problem because its markers are DATA. `--for` gives
    the same data to the non-deploy path.

    `artifact` overrides WHICH FILE is scanned (a build in a worktree that
    must never be deployed), never WHICH MARKERS are required.
    """
    arts = load_deploy_artifacts(path)
    known = ", ".join(a["name"] for a in arts)
    match = [a for a in arts if a.get("name") == name]
    if not match:
        raise UsageError("--for %s: no such artifact in %s. Known: %s"
                         % (name, path, known))
    art = match[0]
    markers = list(art.get("markers") or [])
    exports = list(art.get("exports") or [])
    if artifact:
        dll = os.path.abspath(artifact)
    else:
        dll = os.path.join(REPO, str(art.get("src", "")).replace("/", os.sep))
    prov = ("--for %s: %d declared marker(s) from %s  sha256=%s%s"
            % (name, len(markers), path, _sha(path)[:16],
               ("  (%d declared PE export(s) NOT checked here -- markers.py "
                "scans bytes and an exportc name is present as TEXT without "
                "being in the export directory; use `deploy.py check` for "
                "those)" % len(exports)) if exports else ""))
    return dll, markers, exports, prov


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


# A string every PE on this planet carries in its DOS stub. It is a LAST-RESORT
# positive control for `--string`, where the caller may legitimately supply a
# single literal that is genuinely absent: without some control, that miss is
# INCONCLUSIVE forever and the mode is useless, which is exactly what pushes
# people back to the PowerShell one-liner.
DOS_STUB = "This program cannot be run in DOS mode"


def pe_short(blob):
    """None, or WHY the PE's own headers say this buffer is TRUNCATED.

    Recorded case: `[IO.File]::ReadAllBytes` on a freshly-built DLL returned
    2,399,232 bytes of a 2,454,016-byte file, so every marker past the cut
    read MISSING. A short read must be INCONCLUSIVE, never absence.
    Returns None as well when the bytes are not a PE at all -- this check
    can only ever FIRE, never bless.
    """
    try:
        if len(blob) < 0x40 or blob[:2] != b"MZ":
            return None
        e_lfanew = int.from_bytes(blob[0x3c:0x40], "little")
        if e_lfanew + 24 > len(blob) or blob[e_lfanew:e_lfanew + 4] != b"PE\0\0":
            return None
        nsec = int.from_bytes(blob[e_lfanew + 6:e_lfanew + 8], "little")
        opt = int.from_bytes(blob[e_lfanew + 20:e_lfanew + 22], "little")
        base = e_lfanew + 24 + opt
        end = 0
        for i in range(nsec):
            s = base + 40 * i
            if s + 40 > len(blob):
                return ("the PE section table itself is cut off at %d byte(s)"
                        % len(blob))
            raw = int.from_bytes(blob[s + 20:s + 24], "little")
            size = int.from_bytes(blob[s + 16:s + 20], "little")
            if raw:
                end = max(end, raw + size)
        if end > len(blob):
            return ("the PE section table describes %d byte(s) of file data "
                    "but only %d were read -- a TRUNCATED buffer. Anything "
                    "past the cut would read MISSING, so nothing here is "
                    "evidence of absence." % (end, len(blob)))
    except Exception:                                   # pragma: no cover
        return None
    return None


def scan(path, markers, absent, controls, mode, auto_control=False):
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
    short = pe_short(blob)
    if short:
        res["note"] = ("%s: %s" % (path, short))
        return res
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
    if auto_control:
        pool.append(("auto-control (PE DOS stub)", DOS_STUB))
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
#
# The fixtures are BUILT mod DLLs, and `mods/*/bin/` is gitignored, so a fresh
# worktree has none. They used to be a hardcoded path into one particular
# worktree; when that worktree was removed the self-test went INCONCLUSIVE
# (exit 3 -- correctly not a pass, but also not a check). Resolution order,
# most trustworthy first, and the chosen root is always PRINTED so a fixture
# borrowed from another checkout is visible rather than assumed:
#
#   1. $AOWLSPT_MARKERS_FIXTURES
#   2. mods/ in THIS checkout
#   3. mods/ in any sibling checkout under the parent directory
#
# If none of them yields the fixtures, the self-test says INCONCLUSIVE and
# exits 3. It never silently passes on a reduced case list.
# MEASURED while writing this: choosing a root by FILE EXISTENCE alone picked
# a sibling worktree holding an OLDER build of uihub.dll in which the self-
# test's own control literal `groupOf` is not present -- so six cases failed
# and the whole run was reported as a broken tool rather than a stale fixture.
# A root is therefore only accepted if the literals the cases DEPEND ON are
# actually in those bytes. Same 9b rule as everywhere else: prove the search
# can find text here before believing anything it says about these files.
_FIXTURE_MODS = ["uihub", "debug", "tarkov", "maps"]
_FIXTURE_SENTINELS = [
    ("uihub", "groupOf"),
    ("debug", "espColor"),
    ("maps", "LATE ARM"),
    ("tarkov", "lootWeightMoney"),
]


def _fixture_roots():
    roots = []
    env = os.environ.get("AOWLSPT_MARKERS_FIXTURES")
    if env:
        roots.append(env)
    roots.append(os.path.join(REPO, "mods"))
    parent = os.path.dirname(REPO)
    try:
        sibs = sorted(os.listdir(parent))
    except OSError:
        sibs = []
    for s in sibs:
        p = os.path.join(parent, s, "mods")
        if p not in roots and os.path.isdir(p):
            roots.append(p)
    return roots


def _pick_mods_root():
    """(root, why) -- the first root holding EVERY fixture DLL, or (None, why)."""
    tried = []
    encs = litscan.encodings("any")
    for root in _fixture_roots():
        miss = [m for m in _FIXTURE_MODS
                if not os.path.isfile(os.path.join(root, m, "bin", m + ".dll"))]
        if miss:
            tried.append("%s (not built: %s)" % (root, ", ".join(miss)))
            continue
        stale = []
        for mod, lit in _FIXTURE_SENTINELS:
            p = os.path.join(root, mod, "bin", mod + ".dll")
            try:
                with open(p, "rb") as f:
                    blob = f.read()
            except OSError as e:
                stale.append("%s unreadable (%s)" % (mod, e))
                continue
            hits, _ = litscan.find_at(blob, encs, lit)
            if not hits:
                stale.append("%s.dll lacks %s" % (mod, ascii(lit)))
        if stale:
            tried.append("%s (STALE build: %s)" % (root, "; ".join(stale)))
            continue
        return root, root
    return None, "; ".join(tried) if tried else "no candidate roots"


_MODS = None


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
    global _MODS
    red, green, yellow, dim, reset = C
    root, why = _pick_mods_root()
    if root is None:
        print("%sINCONCLUSIVE%s no checkout under %s has all of %s built, so "
              "the self-test could NOT be performed. This is not a pass. "
              "Tried: %s. Build the mods, or set AOWLSPT_MARKERS_FIXTURES."
              % (yellow, reset, os.path.dirname(REPO),
                 ", ".join(_FIXTURE_MODS), why))
        return 3
    _MODS = root
    print("%sfixtures: %s%s" % (dim, root, reset))
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
    if not for_selftest(C):
        ok = False
    if not string_selftest(C):
        ok = False
    if not deploy_parity(C):
        ok = False
    print("%s%s%s" % (green if ok else red,
                      "self-test OK -- all three outcomes demonstrated"
                      if ok else "SELF-TEST FAILED", reset))
    return 0 if ok else 1


# ------------------------------------------------------- `--for` self-test
#
# A `--for` that can only ever pass is worse than no `--for`: it would hand
# every subagent a green light with the authority of deploy.json behind it.
# So these cases drive the REAL command line (main()) end to end -- argument
# parsing, deploy.json load, artifact resolution, scan, exit code -- and
# assert all three exit codes occur. The MISSING case applies debug.dll's
# DECLARED marker set to uihub.dll with a uihub literal as the positive
# control; the INCONCLUSIVE case is the same scan with the control removed,
# which is exactly the distinction 9b demands.
FOR_SELFTEST = [
    ("--for PRESENT: uihub.dll against uihub's declared marker set",
     ["--for", "uihub", "--artifact", ("uihub",)], 0),
    ("--for MISSING: debug's declared markers against uihub.dll, with a "
     "uihub literal as the positive control",
     ["--for", "debug", "--artifact", ("uihub",), "--control", "groupOf"], 1),
    ("--for INCONCLUSIVE: the same scan with NO control -- a miss cannot be "
     "told apart from 'we could not look'",
     ["--for", "debug", "--artifact", ("uihub",)], 3),
    ("--for INCONCLUSIVE: --artifact naming a file that does not exist -- "
     "nothing was searched, which is not evidence of absence",
     ["--for", "uihub", "--artifact",
      os.path.join(REPO, "mods", "uihub", "bin", "nope-not-built.dll")], 3),
    ("--for INCONCLUSIVE: --min-markers above the declared count, so a "
     "SHRUNK deploy.json marker list cannot read as a pass",
     ["--for", "uihub", "--artifact", ("uihub",), "--min-markers", "9999"], 3),
]


def for_selftest(C):
    red, green, yellow, dim, reset = C
    ok = True
    seen = set()
    for (label, argv, want) in FOR_SELFTEST:
        av = [(_dll(a[0]) if isinstance(a, tuple) else a) for a in argv]
        av += ["--quiet", "--no-color"]
        buf = io.StringIO()
        keep = sys.stdout
        sys.stdout = buf
        try:
            got = main(av)
        except SystemExit as e:                 # argparse usage error
            got = e.code
        finally:
            sys.stdout = keep
        seen.add(got)
        good = (got == want)
        print("%s%s%s %s" % (green if good else red,
                             "PASS" if good else "FAIL", reset, label))
        if not good:
            ok = False
            print("    wanted exit %s, got %s  (argv: %s)" % (want, got, av))
            for ln in buf.getvalue().splitlines():
                print("      " + ln)
    for code in (0, 1, 3):
        if code not in seen:
            ok = False
            print("%sFAIL%s `--for` never exited %d, so that outcome is not "
                  "demonstrated and may be unreachable." % (red, reset, code))
    # And --for must refuse an artifact name it does not know, rather than
    # checking nothing and calling it a pass.
    try:
        resolve_for("no-such-artifact-name")
    except UsageError:
        print("%sPASS%s --for refuses an undeclared artifact name" %
              (green, reset))
    else:
        ok = False
        print("%sFAIL%s --for accepted an undeclared artifact name" %
              (red, reset))
    return ok


# ------------------------------------------------------ `--string` self-test
#
# `--string` is the mode that exists to replace the PowerShell idiom, so it is
# worth nothing unless it can FAIL. These cases drive the real command line end
# to end and assert all three exit codes occur, plus the two defects that
# actually fooled agents: a literal containing U+2026 (which the ASCII idiom
# can NEVER find), and a TRUNCATED buffer (which made every marker read
# MISSING). The non-ASCII case additionally re-derives the broken idiom in
# Python and asserts it STILL gets the wrong answer -- if that ever starts
# working, this case is telling you the regression fixture is stale.
ELLIPSIS_LIT = "(ents[i].id ? ' …' + ents[i].id"

STRING_SELFTEST = [
    ("--string PRESENT: a literal that IS in uihub.dll",
     ["--string", "groupOf", ("uihub",)], 0),
    ("--string PRESENT (REGRESSION): the U+2026 literal in maps.dll that the "
     "PowerShell ASCII.GetString idiom reports ABSENT",
     ["--string", ELLIPSIS_LIT, ("maps",)], 0),
    ("--string MISSING: a literal genuinely not in uihub.dll -- trustworthy "
     "because the automatic PE DOS-stub control matched",
     ["--string", "zzzNotAMarkerAtAll", ("uihub",)], 1),
    ("--string INCONCLUSIVE: a nimony `&`-SPLIT literal is not a removal",
     ["--string", "LATE ARMS the feed in place", ("maps",)], 3),
    ("--string INCONCLUSIVE: a file that does not exist -- nothing searched",
     ["--string", "groupOf",
      os.path.join(REPO, "mods", "uihub", "bin", "nope-not-built.dll")], 3),
    ("--for usage error: a PATH given where a LOGICAL NAME belongs",
     ["--for", ("uihub",)], 2),
    # The `--` sentinel: a literal that starts with a dash. Without
    # `absorb_sentinels` argparse reads `--groupOf-not-a-flag` as an unknown
    # OPTION and exits 2, so a plain MISSING (1) here is the whole proof.
    ("--string -- <dash-leading literal>: parsed as a LITERAL, not an option",
     ["--string", "--", "--zzzNotAMarkerAtAll", ("uihub",)], 1),
    ("--string -- <dash-leading literal> that IS present",
     ["--string", "--", "--" + "app:lib", ("uihub",)], 1),
]


def string_selftest(C):
    red, green, yellow, dim, reset = C
    ok = True
    seen = set()
    for (label, argv, want) in STRING_SELFTEST:
        av = [(_dll(a[0]) if isinstance(a, tuple) else a) for a in argv]
        av += ["--quiet", "--no-color"]
        buf, keep = io.StringIO(), sys.stdout
        sys.stdout = buf
        try:
            got = main(av)
        except SystemExit as e:
            got = e.code
        finally:
            sys.stdout = keep
        seen.add(got)
        good = (got == want)
        if not good:
            ok = False
        print("%s%s%s %s" % (green if good else red,
                             "PASS" if good else "FAIL", reset, label))
        if not good:
            print("    wanted exit %s, got %s  (argv: %s)" % (want, got, av))
            for ln in buf.getvalue().splitlines():
                print("      " + ln)
    for code in (0, 1, 3):
        if code not in seen:
            ok = False
            print("%sFAIL%s `--string` never exited %d, so that outcome is "
                  "not demonstrated and may be unreachable."
                  % (red, reset, code))
    # The defect itself, reproduced: ASCII decoding with '?' for every byte
    # >= 0x80 -- exactly what PowerShell 5.1 does -- must still LOSE the
    # ellipsis literal that --string found above.
    try:
        with open(_dll("maps"), "rb") as f:
            blob = f.read()
    except OSError as e:
        ok = False
        print("%sFAIL%s could not read maps.dll for the idiom repro: %s"
              % (red, reset, e))
    else:
        lossy = "".join(chr(b) if b < 0x80 else "?" for b in blob)
        if lossy.find(ELLIPSIS_LIT) != -1:
            ok = False
            print("%sFAIL%s the ASCII-lossy idiom FOUND the U+2026 literal; "
                  "this regression fixture no longer reproduces the defect."
                  % (red, reset))
        elif litscan.find_at(blob, litscan.encodings("any"), ELLIPSIS_LIT)[0]:
            print("%sPASS%s regression: the ASCII-lossy idiom loses the "
                  "U+2026 literal that --string finds at 0x%x"
                  % (green, reset,
                     litscan.find_at(blob, litscan.encodings("any"),
                                     ELLIPSIS_LIT)[1]))
        else:
            ok = False
            print("%sFAIL%s neither method found the U+2026 literal -- the "
                  "fixture is stale, not a pass." % (red, reset))
    # MSYS path conversion. Both cases run through the REAL command line with
    # a synthetic root list, so they behave identically under bash, PowerShell
    # and CI -- and the CONTROL is the half that matters: a genuine `C:/...`
    # literal that is not under an MSYS root must still be SEARCHED, or the
    # refusal would just be a new way to answer nothing.
    fake_root = "C:/Program Files/Git"
    saved = {k: os.environ.get(k) for k in
             ("MSYSTEM", "MSYS_NO_PATHCONV", "AOWLSPT_MSYS_ROOTS")}
    os.environ["MSYSTEM"] = "MINGW64"
    os.environ.pop("MSYS_NO_PATHCONV", None)
    os.environ["AOWLSPT_MSYS_ROOTS"] = fake_root
    try:
        for (label, lit, want) in (
            ("MSYS INCONCLUSIVE: an argument path-converted by Git Bash "
             "(a marker typed as `/aowlspt/keybinds`) is REFUSED, not "
             "reported MISSING",
             fake_root + "/aowlspt/keybinds", 3),
            ("MSYS control: a genuine C:/ literal NOT under the MSYS root is "
             "searched normally (an honest MISSING, not a refusal)",
             "C:/Users/nobody/zzzNotAMarkerAtAll", 1),
        ):
            av = ["--string", lit, _dll("uihub"), "--quiet", "--no-color"]
            buf, keep = io.StringIO(), sys.stdout
            sys.stdout = buf
            try:
                got = main(av)
            except SystemExit as e:
                got = e.code
            finally:
                sys.stdout = keep
            good = (got == want)
            if not good:
                ok = False
            print("%s%s%s %s" % (green if good else red,
                                 "PASS" if good else "FAIL", reset, label))
            if not good:
                print("    wanted exit %s, got %s  (literal %s)"
                      % (want, got, ascii(lit)))
                for ln in buf.getvalue().splitlines():
                    print("      " + ln)
        # And the refusal must not fire when conversion was disabled -- the
        # very command line the refusal tells you to run must WORK.
        os.environ["MSYS_NO_PATHCONV"] = "1"
        if pathconv_suspect(fake_root + "/aowlspt/keybinds") is not None:
            ok = False
            print("%sFAIL%s the refusal still fires under MSYS_NO_PATHCONV=1, "
                  "so the fix it recommends does not work." % (red, reset))
        else:
            print("%sPASS%s MSYS_NO_PATHCONV=1 disables the refusal, so the "
                  "recommended re-run actually searches" % (green, reset))
    finally:
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
    # And a TRUNCATED read must be INCONCLUSIVE, never MISSING.
    import tempfile
    src = _dll("uihub")
    with open(src, "rb") as f:
        full = f.read()
    cut = full[:len(full) * 3 // 4]
    tmp = os.path.join(tempfile.gettempdir(), "markers-truncated-fixture.dll")
    with open(tmp, "wb") as f:
        f.write(cut)
    r = scan(tmp, ["groupOf"], [], [], "any", auto_control=True)
    if r["verdict"] != INCONCLUSIVE or not r.get("note"):
        ok = False
        print("%sFAIL%s a TRUNCATED buffer must be INCONCLUSIVE, got %s"
              % (red, reset, r["verdict"]))
    else:
        print("%sPASS%s INCONCLUSIVE: a truncated %d-of-%d-byte DLL is "
              "refused, not read as MISSING" % (green, reset, len(cut),
                                                len(full)))
    try:
        os.remove(tmp)
    except OSError:
        pass
    return ok


# `deploy.py check --contains` decides PRESENT/MISSING/INCONCLUSIVE by calling
# classify() above. That delegation is the whole point -- the host-side tool
# and the mod-side tool must not answer the same question differently -- so it
# is worth exactly nothing unless something FAILS when it is undone. These
# cases drive deploy.verify_literals() directly and assert all three verdicts
# occur; deleting the delegation, or making --contains unable to FAIL again
# (which is the gap this closes: agents fell back to `grep -a` because a
# genuinely absent marker read as "we could not look"), breaks this list.
DEPLOY_PARITY = [
    ("deploy --contains PASS: a marker that IS in uihub.dll",
     "uihub", "groupOf", ["groupOf"], litscan.OK),
    ("deploy --contains FAIL: debug.dll's espColor asserted against "
     "uihub.dll, with uihub's own marker as the positive control",
     "uihub", "espColorEspColorNotHere", ["groupOf"], litscan.FAIL),
    ("deploy --contains INCONCLUSIVE: a literal SPLIT across nimony rodata "
     "fragments is NOT a removal",
     "maps", "LATE ARMS the feed in place", ["LATE ARM"], INCONCLUSIVE),
    ("deploy --contains INCONCLUSIVE: no positive control matched, so a miss "
     "cannot be told apart from 'we could not look'",
     "uihub", "zzzNotAMarkerAtAll", [], INCONCLUSIVE),
]


def deploy_parity(C):
    red, green, yellow, dim, reset = C
    try:
        import deploy                       # noqa: E402 (cycle: deploy->markers)
    except Exception as e:                  # pragma: no cover
        print("%sINCONCLUSIVE%s could not import tools/deploy.py (%s) -- the "
              "delegation was NOT checked. This is not a pass."
              % (yellow, reset, e))
        return False
    ok = True
    seen = set()
    for (label, mod, lit, ctl, want) in DEPLOY_PARITY:
        path = _dll(mod)
        if not os.path.isfile(path):
            print("%sINCONCLUSIVE%s missing fixture %s -- deploy parity was "
                  "NOT checked. This is not a pass." % (yellow, reset, path))
            return False
        got, lines = deploy.verify_literals(
            path, [lit], [], "any", ("", "", "", "", ""),
            [("--control", c) for c in ctl])
        seen.add(got)
        good = (got == want)
        print("%s%s%s %s" % (green if good else red,
                             "PASS" if good else "FAIL", reset, label))
        if not good:
            ok = False
            print("    wanted %s, got %s" % (want, got))
            for ln in lines:
                print("      " + ln)
    need = {litscan.OK, litscan.FAIL, INCONCLUSIVE}
    gone = sorted(need - seen)
    if gone:
        ok = False
        print("%sFAIL%s deploy.py --contains never produced these verdicts, "
              "so the delegation is not demonstrated: %s" % (red, reset, gone))
    return ok


# ------------------------------------------------- MSYS argument rewriting
#
# MEASURED under Git Bash (MSYSTEM=MINGW64) on this machine:
#
#     $ python -c 'import sys;print(sys.argv[1:])' --string "/aowlspt/keybinds" x
#     ['--string', 'C:/Program Files/Git/aowlspt/keybinds', 'x']
#     $ MSYS_NO_PATHCONV=1 python ... --string "/aowlspt/keybinds" x
#     ['--string', '/aowlspt/keybinds', 'x']
#
# The MSYS runtime rewrites any argument that looks like a POSIX absolute path
# into a Windows path BEFORE the process starts, so Python never sees what was
# typed. `markers.py --string "/aowlspt/keybinds" mod.dll` therefore searched
# for `C:/Program Files/Git/aowlspt/keybinds` and reported a confident MISSING
# for a marker that is in the DLL. That is precisely the confidently-wrong
# answer this whole tool exists to prevent, and EVERY marker beginning with `/`
# is affected.
#
# We cannot recover the original -- the information is gone before main() runs
# -- so the only honest outcome is a REFUSAL (INCONCLUSIVE, exit 3) naming the
# rewritten string.
#
# KNOWN LIMIT, stated rather than papered over: only the root-prefixed shape is
# detectable. `/c/Users` is rewritten to `C:/Users`, which carries no MSYS root
# prefix and is byte-identical to a literal somebody may genuinely want to
# search for; that case is NOT detected and will still be searched as given.
MSYS_ROOT_FILES = (("usr", "bin", "bash.exe"), ("etc", "fstab"))


def _is_msys_root(d):
    """True if `d` is the install root of an MSYS/Git-Bash environment."""
    return all(os.path.isfile(os.path.join(d, *parts))
               for parts in MSYS_ROOT_FILES)


def pathconv_suspect(lit, env=None):
    """(root, recovered-original) if `lit` looks MSYS-rewritten, else None.

    Only fires when the process was actually started from an MSYS shell
    (`MSYSTEM` set) with conversion enabled (`MSYS_NO_PATHCONV` unset), the
    literal has the `<X>:/` shape conversion produces, AND some prefix of it is
    a real MSYS install root. That last condition is what keeps a genuine
    `C:/...` literal that is not under such a root from being refused.

    `AOWLSPT_MSYS_ROOTS` (os.pathsep-separated) replaces the filesystem probe
    with an explicit root list; the self-test uses it so both the positive and
    the negative case are deterministic on any machine.
    """
    env = os.environ if env is None else env
    if not env.get("MSYSTEM") or env.get("MSYS_NO_PATHCONV"):
        return None
    if len(lit) < 4 or not lit[0].isalpha() or lit[1:3] != ":/":
        return None
    forced = env.get("AOWLSPT_MSYS_ROOTS")
    roots = None
    if forced:
        roots = [os.path.normcase(r.rstrip("/\\").replace("\\", "/"))
                 for r in forced.split(os.pathsep) if r]
    for i, ch in enumerate(lit):
        if ch != "/" or i < 3:          # i==2 is the drive's own slash
            continue
        cand = lit[:i]
        hit = (os.path.normcase(cand) in roots if roots is not None
               else _is_msys_root(cand))
        if hit:
            return cand, lit[i:]
    return None


def pathconv_refusal(lits, env=None):
    """None, or the INCONCLUSIVE refusal text for the first rewritten literal."""
    for lit in lits:
        hit = pathconv_suspect(lit, env)
        if not hit:
            continue
        root, orig = hit
        return (
            "the literal reaching this process is %s, which is an MSYS "
            "path-converted argument, NOT what you typed: the shell rewrote a "
            "leading %s into %s%s before python started. Searching for the "
            "rewritten form would report a confident MISSING for a marker that "
            "may well be in the file, so nothing was searched.\n"
            "  re-run with conversion off:\n"
            "      MSYS_NO_PATHCONV=1 python tools/markers.py --string %s FILE\n"
            "  (or run it from PowerShell, which does not rewrite arguments.)\n"
            "  NOTE, measured: prefixing the argument with `//` does stop the "
            "conversion, but the literal then still carries the extra leading "
            "slash -- `//aowlspt/keybinds` arrives verbatim, not as "
            "`/aowlspt/keybinds` -- so it is NOT a fix for this."
            % (_q(lit), _q(orig), root, "" if root.endswith("/") else "/",
               _q(orig)))
    return None


def _looks_like_path(s):
    # `os.path.isfile`, NOT `os.path.exists`. MEASURED 2026-08-31: `--for host`
    # was refused from the repo root as "looks like a path", because the repo
    # root contains a DIRECTORY named `host/` and `exists()` said yes. `host` is
    # a declared artifact name and the refusal was simply wrong -- an agent lost
    # a check to it. A directory is never the artifact file, so it cannot be the
    # thing that makes a name look like a path.
    return ("/" in s or "\\" in s or s.lower().endswith((".dll", ".exe"))
            or os.path.isfile(s))


def _is_declared_artifact(name):
    """True if `name` is a logical artifact declared in deploy.json.

    Consulted BEFORE the heuristic: a name that is actually declared is a name,
    whatever it happens to look like. The heuristic exists only to give a good
    error for something that is NOT declared.
    """
    try:
        return any(a.get("name") == name for a in load_deploy_artifacts())
    except Exception:
        return False


# Options that take a LITERAL as their value -- i.e. ones whose value may
# legitimately start with a dash, because the thing being searched for is a
# command-line flag inside the binary.
SENTINEL_OPTS = ("-s", "--string", "--absent", "--control")


def absorb_sentinels(argv):
    r"""Rewrite `OPT -- VALUE` as `OPT=VALUE` for the literal-taking options.

    argparse cannot express "the next token is a value even though it starts
    with a dash". `-s --no-mod-build` is parsed as the option `--no-mod-build`
    and fails with `expected one argument`, and `--` is argparse's own
    end-of-options marker, so it does not help either.

    That bit for real: verifying the launcher's new flags meant asking whether
    the string `--no-mod-build` was in the built exe, and there was no way to
    say it. `-s=--no-mod-build` does work, but it is not what anyone types and
    it is not what the error message suggests.

    So `--string -- --no-mod-build` now means what it looks like it means. Only
    the options in SENTINEL_OPTS are touched, and only when the very next token
    is exactly `--`; anything else is passed through untouched, so argparse's
    ordinary end-of-options behaviour elsewhere on the line is unchanged.
    """
    out = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in SENTINEL_OPTS and i + 2 < len(argv) and argv[i + 1] == "--":
            out.append("%s=%s" % (a, argv[i + 2]))
            i += 3
            continue
        if a in SENTINEL_OPTS and i + 2 == len(argv) and argv[i + 1] == "--":
            # `--string --` with nothing after it. Left alone so argparse
            # produces its own "expected one argument" rather than this
            # silently swallowing the option.
            out.append(a)
            i += 1
            continue
        out.append(a)
        i += 1
    return out


def main(argv):
    argv = absorb_sentinels(argv)
    ap = argparse.ArgumentParser(
        prog="markers.py", add_help=True,
        description="Verify feature markers in a built DLL. Three outcomes: "
                    "PRESENT / MISSING / INCONCLUSIVE. Exit 0/1/3.")
    ap.add_argument("dll", nargs="?", help="the built artifact to scan")
    ap.add_argument("markers", nargs="*", help="markers expected PRESENT")
    ap.add_argument("-s", "--string", action="append", default=[],
                    metavar="LITERAL", dest="strings",
                    help="an exact literal to look for in the given FILE "
                         "(repeatable). This is the ad-hoc 'is this string in "
                         "this DLL' check -- use it INSTEAD of a PowerShell "
                         "ASCII.GetString(...).Contains(...) one-liner, which "
                         "turns every byte >= 0x80 into '?' and reports real "
                         "markers ABSENT.")
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
    ap.add_argument("--for", dest="for_", metavar="ARTIFACT",
                    help="take the marker set from tools/deploy.json's "
                         "DECLARED set for this artifact, instead of typing "
                         "in literals you just wrote yourself")
    ap.add_argument("--artifact", metavar="PATH",
                    help="scan THIS file instead of the artifact's declared "
                         "src -- for a build in a worktree that must not be "
                         "deployed. Changes which FILE, never which MARKERS.")
    ap.add_argument("--list-artifacts", action="store_true",
                    help="print the declared artifact names and marker counts")
    ap.add_argument("--selftest", action="store_true",
                    help="prove all three outcomes against real mod DLLs")
    args = ap.parse_args(argv)
    C = _color(not args.no_color and sys.stdout.isatty())

    if args.selftest:
        return selftest(C)
    # Before ANY searching: was an argv literal mangled by MSYS path conversion?
    # Only argv-borne literals can be -- markers read from a file are untouched.
    refusal = pathconv_refusal(list(args.strings) + list(args.markers)
                              + list(args.absent) + list(args.control))
    if refusal:
        print("%sINCONCLUSIVE%s markers.py: %s" % (C[2], C[4], refusal))
        return 3
    if args.list_artifacts:
        try:
            for a in load_deploy_artifacts():
                print("%-14s %3d marker(s)  %3d export(s)  %s"
                      % (a["name"], len(a.get("markers") or []),
                         len(a.get("exports") or []), a.get("src", "")))
        except UsageError as e:
            print("markers.py: %s" % e)
            return 2
        return 0

    declared_prov = None
    if (args.for_ and not _is_declared_artifact(args.for_)
            and _looks_like_path(args.for_)):
        # Two agents hit this and could not tell WHY, because the old error
        # echoed the path back without saying what --for actually takes.
        print("markers.py: --for takes a LOGICAL ARTIFACT NAME declared in "
              "%s (see --list-artifacts), not a file path. You passed %s, "
              "which looks like a path." % (DEPLOY_JSON, args.for_))
        print("  to scan an arbitrary FILE for literals you choose:")
        print("      python tools/markers.py --string \"some literal\" %s"
              % args.for_)
        print("  to scan an arbitrary FILE against a DECLARED marker set:")
        print("      python tools/markers.py --for <name> --artifact %s"
              % args.for_)
        return 2
    if args.for_:
        try:
            dll, dmarkers, _dexports, declared_prov = resolve_for(
                args.for_, args.artifact)
        except UsageError as e:
            print("markers.py: %s" % e)
            return 2
        if args.dll:
            print("markers.py: --for takes the artifact from --artifact PATH; "
                  "a positional DLL as well is ambiguous. Drop one.")
            return 2
        if not dmarkers:
            print("markers.py: artifact %r declares NO markers, so nothing "
                  "would be checked. An empty declared set is INCONCLUSIVE, "
                  "never a pass." % args.for_)
            print(declared_prov)
            return 3
        args.dll = dll
        args.markers = list(args.markers) + dmarkers
    elif args.artifact:
        if args.dll:
            # An agent hit this having meant the positional as a MARKER. Say
            # what both readings are instead of only rejecting one.
            print("markers.py: two files were named -- --artifact %s and the "
                  "positional %r -- and the positional slot is the FILE, not "
                  "a marker." % (args.artifact, args.dll))
            print("  if %r was meant as a literal to look for, pass it as a "
                  "string and drop --artifact:" % args.dll)
            print("      python tools/markers.py --string %s %s"
                  % (_q(args.dll), args.artifact))
            return 2
        args.dll = args.artifact
    if not args.dll:
        ap.print_usage()
        print("markers.py: a FILE to scan is required (or --selftest). For an "
              "ad-hoc check of one literal in one binary:")
        print("      python tools/markers.py --string \"some literal\" "
              "path/to/built.dll")
        return 2

    markers = list(args.markers) + list(args.strings)
    absent = list(args.absent)
    controls = list(args.control)
    prov = [declared_prov] if declared_prov else []
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

    res = scan(args.dll, markers, absent, controls, args.encoding,
               auto_control=bool(args.strings))
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
