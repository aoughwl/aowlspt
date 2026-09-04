#!/usr/bin/env python3
"""Verify built artifacts, back up the live ones, and copy the new ones in.

This replaces a sequence that was being typed by hand every single deploy:
`grep -a` for a handful of feature strings in the freshly built DLL, a manual
`copy` to a `.bak-<something>` name, then a manual copy into the install. The
step that got skipped was the first one, and the failure it prevents is the
expensive one: a rebuild from a wrong base silently drops a feature, the binary
ships, the game starts fine, and the feature is simply absent. Nothing fails.
You find out from a human playing the game twenty minutes later.

So the rule here is: **a missing marker refuses the deploy.** Not a warning.
The marker list lives in `tools/deploy.json` beside this file, so adding a
feature and adding its fingerprint are one edit in one place.

    python tools/deploy.py check                 # verify only, touch nothing
    python tools/deploy.py check --only host
    python tools/deploy.py deploy                # verify, back up, copy
    python tools/deploy.py deploy --only host,tarkov
    python tools/deploy.py deploy --dry-run      # print the plan, do nothing
    python tools/deploy.py status                # what is OFF / MISSING / stale
    python tools/deploy.py where host,sain       # where do these live, exactly
    python tools/deploy.py rollback              # list restorable backups
    python tools/deploy.py rollback host         # restore host's newest backup

WHERE IS THIS ARTIFACT, EXACTLY?
--------------------------------
`where` answers the question that was being guessed at: it prints, per named
artifact, the SOURCE path both repo-relative and absolute, whether that file
exists with its size and mtime, the install DESTINATION, the installed file's
size and mtime, and whether the two are byte-identical (both are hashed --
mtime is not evidence). Measured 2026-09-01: two agents guessed `build\\host\\...`
for the host DLL and got INCONCLUSIVE out of `check`, which named the path it
expected only on the ok line. `check` now names the expected source path on
every verdict, and `where` exists so the path never has to be guessed at all.
It is read-only: it copies nothing, verifies no markers, and never deploys.
Three outcomes as everywhere else -- a source that is absent because a BUILD IS
IN PROGRESS is INCONCLUSIVE and says so, never "not built".

`--install PATH` overrides the destination from `deploy.json`.

IS MY CHANGE ACTUALLY IN THIS BUILD?
------------------------------------
Markers answer "is this a valid build of that target"; they were written
before your edit existed and cannot answer "did tonight's edit land". And
`aowl build-mod` prints `ok mod X` with NO verification at all. So `check`
takes ad-hoc literals, repeatable, ADDITIVE to the markers:

    python tools/deploy.py check --artifact PATH --only host \
        --contains "launchHint WRITTEN to aowl.uihub" \
        --contains "/aowlspt/settings/aowl.uihub"
    python tools/deploy.py check --artifact PATH --only settingshub \
        --absent "Settings Panel" \
        --control "a literal you KNOW is there"   # prove a REMOVAL
    ... --encoding utf8|utf16|any          # default any

A literal is searched in the RAW BYTES as UTF-8 *and* UTF-16LE, and the
report says which matched -- a string that only exists in the UTF-16 table
must never read as absent. Do NOT hand-roll this in PowerShell:
`[Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes(p)).Contains(s)`
gives SELECTIVE false negatives (facts #151/#152).

A MATCH PROVES PRESENCE; A BARE MISS PROVES NOTHING. nimony stores each
`&`-concatenated source fragment as a SEPARATE rodata string, so a sentence
assembled from fragments (or from variables, or a C function name from
`abi/*.h`, which is a symbol and not a runtime string) can NEVER appear
contiguously. So `--contains` is THREE-way, and the decision is delegated to
`tools/markers.py` (which shares `tools/litscan.py` with this file, so the
mod-side and host-side tools cannot drift): PASS on a contiguous match; FAIL
(exit 1) when a POSITIVE CONTROL matched and under 60% of the literal
survives as word-runs -- the shape of a removal; NO-MATCH / INCONCLUSIVE
(exit 3) otherwise, with the longest surviving word-run, which usually shows
you where the split is. Pick a substring that lives inside ONE source
fragment. Until FAIL was reachable, `--contains` could not assert a specific
new marker string at all, and agents fell back to `grep -a`.

`--absent` carries the same caveat and is likewise THREE-way. It FAILs on a
contiguous hit (reported with the byte offset), is INCONCLUSIVE when MOST of
the literal survives as word-runs -- the shape of a `&`-split sentence rather
than of a removal -- and PASSes only when the miss is backed by a POSITIVE
CONTROL: a literal known to be in the artifact that the same search DOES
find, by default one of the artifact's own declared markers, or `--control
LIT`. Without a control that matches, "not found" cannot be told apart from
"we could not look", so it is INCONCLUSIVE. The previous version treated any
surviving 6-character word-run as INCONCLUSIVE, which made `--absent` unable
to PASS at all on a sentence -- a check with no reachable pass, the mirror of
the defect in 9b -- and quoted that one short generic run as the evidence.

`--contains` is a CLI argument on purpose: `tools/deploy.json`'s marker list
must never be edited to make a check pass, and a passing literal can only
add to the verdict, never rescue a missing marker. An unreadable artifact is
INCONCLUSIVE, not a pass and not a content failure.

Three outcomes, never two (CLAUDE.md 9b). An artifact whose own INPUT is
absent was not verified -- it did not fail. `.cache/global-metadata.dec.dat`
is gitignored, so in a fresh worktree `aowl build host` cannot emit the name
index at all; calling that FAIL says "the feature was dropped" about a thing
nobody looked at, and the measured consequence is that subagents stop
trusting this tool and hand-scan binaries instead. So:

    ok            built, every marker is present, every declared PE export
                  is in the export table
    FAIL          built, and a marker or a required export is MISSING -- the
                  feature was dropped, or is unreachable by name
    INCONCLUSIVE  not built (nothing was verified), or the export table could
                  not be read

EXPORTS ARE NOT MARKERS
-----------------------
A marker asserts a string is somewhere in the binary, and the compiler puts
that string there whether or not anything can reach the function at runtime.
Measured 2026-08-27: the shipped host DLL had 16 PE exports, all
`aowl_region_*_x`, and ZERO `aowl_host_*` -- while `aowl_host_gameworld`'s
code and name were both in the file. Nim's `{.exportc.}` emits a C symbol,
not a PE export. `GetProcAddress` returned NULL and mods/admin, mods/sain and
mods/morebots refused, correctly and silently, for an unknown length of time.
Markers could not have caught it. So an artifact may declare:

    "exports": ["aowl_host_gameworld", "aowl_region_fill_x", ...]

and every name is looked up in the real export directory. The list is the
names MODS RESOLVE BY NAME (grep the mod sources for GetProcAddress), never a
transcript of what the DLL happens to export today -- transcribing would
enshrine exactly the absence this check exists to find.

An artifact declares its input with `"requiresInput"` in `deploy.json`:

    "requiresInput": {"path": ".cache/global-metadata.dec.dat",
                      "why":  "gitignored; copy it from the main checkout"}

That downgrade applies ONLY when the artifact is absent AND the input is
absent. If the input is present and the artifact still is not, that is a
real build failure and stays FAIL; if the artifact exists, its markers are
checked exactly as before and a missing one still FAILs loudly. There is no
path by which declaring an input can weaken a marker.

DATA IS PART OF THE ARTIFACT
----------------------------
Until 2026-08-27 this tool shipped DLLs and executables and nothing else, and
three separate live failures in one day were all that same hole:

  * `mods/tarkov/data/post1/globalsgaps.json` was not shipped. tarkov.dll's
    own self-check found it missing and registered ONLY its selfcheck route;
    what the player saw was "unable to check client version".
  * `registry/mods.json` was not shipped, so the manager could not find
    `aowl.list.beta` and quietly loaded two mods instead of eight.
  * `mods/maps/data/**` was not shipped -- 8 maps reported no data.

Every one of them was silent at the point of failure and loud somewhere
unrelated. So an artifact may now declare the data it needs:

    "data": [{"src": "mods/tarkov/data", "dst": "mods/tarkov/data",
              "exclude": ["capture/**", "*.md"], "minFiles": 600,
              "why": "the emulator refuses to start a raid without post1/"}]

The file list is DERIVED by walking `src`, never enumerated by hand -- a
hardcoded list rots the day someone adds a data file, which is the same class
of bug as the duplicated build list removed earlier the same day.

The exclusion set is not invented here. `aowl payload` / `stageTarkovData` in
`tools/aowl.nim` already established it for staging, for reasons that apply
verbatim: `data/capture/**` is a recording of the real backend kept to check
this server AGAINST -- 690 files the server never serves, most of them
regenerated rather than stored, so a payload built on one machine would carry
them and one built on another would not. It is skipped by NAME, not by size,
because "large" is not the reason. `*.md` is documentation
(`data/post1/README.md` and friends); nothing loads it.

Marker verification is SOURCE side and gates the deploy. Data verification is
INSTALL side -- it asks whether the live install actually holds the bytes, so
it is a post-condition, not a precondition:

    check    markers on the built file  +  data present and identical in the
             install. A data file that is absent or differs is a FAIL, named.
    deploy   markers gate the copy; data is copied; then the same install-side
             data verification runs AGAIN, and a deploy whose post-condition
             does not hold reports FAIL rather than success.

If a declared data source directory is missing from the repo, or derives zero
files, nothing was verified -- that is INCONCLUSIVE (exit 3), never a pass.

Exit codes: 0 ok, 1 a marker was missing, a data file was absent/different, or
a copy failed, 2 bad usage, 3 nothing failed but at least one artifact was
INCONCLUSIVE. A release script can therefore refuse on 1 and tolerate 3 with a
visible notice.
"""

import argparse
import fnmatch
import hashlib
import json
import os
import posixpath
import re
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
CONFIG = os.path.join(HERE, "deploy.json")
if HERE not in sys.path:                 # so `from litscan import ...` works
    sys.path.insert(0, HERE)             # however this file was invoked

RESET = "\033[0m"
RED = "\033[31m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
DIM = "\033[2m"


def _color(enabled):
    if enabled:
        return RED, GREEN, YELLOW, DIM, RESET
    return "", "", "", "", ""


def load_config():
    with open(CONFIG, "r", encoding="utf-8-sig") as f:
        cfg = json.load(f)
    return cfg


def select(cfg, only):
    arts = [a for a in cfg["artifacts"] if not a["name"].startswith("//")]
    if not only:
        return arts
    want = [w.strip() for w in only.split(",") if w.strip()]
    known = {a["name"] for a in arts}
    bad = [w for w in want if w not in known]
    if bad:
        sys.exit("unknown artifact(s): %s (known: %s)"
                 % (", ".join(bad), ", ".join(sorted(known))))
    return [a for a in arts if a["name"] in want]


# The three verdicts and the byte-scanning primitives live in tools/litscan.py
# so that deploy.py (host DLL) and tools/markers.py (mod DLLs) cannot drift
# apart. Re-exported under the names this file already used.
import litscan                                       # noqa: E402
import stage                                         # noqa: E402
import markers                                       # noqa: E402  (classify)
from litscan import OK, FAIL, INCONCLUSIVE           # noqa: E402
from litscan import FRAGMENT_NOTE                    # noqa: E402
from litscan import fragment_cover as _fragment_cover           # noqa: E402
from litscan import find_at as _find_at                         # noqa: E402
from litscan import pick_control as _pick_control               # noqa: E402
from litscan import coverage_ratio as _coverage_ratio           # noqa: E402
from litscan import longest_present_fragment as _longest_present_fragment  # noqa: E402,E501
from litscan import ABSENT_COVERAGE as _ABSENT_COVERAGE         # noqa: E402
from litscan import MIN_FRAGMENT as _MIN_FRAGMENT               # noqa: E402,F401


def missing_input(art):
    """The artifact's declared input, if it is declared AND absent.

    Returns (path, why) or None. Only consulted when the artifact itself is
    missing -- see the module docstring.
    """
    req = art.get("requiresInput")
    if not req:
        return None
    rel = req.get("path", "")
    if not rel:
        return None
    full = os.path.join(REPO, rel.replace("/", os.sep))
    if os.path.exists(full):
        return None
    return rel, req.get("why", "")


def _excluded(rel, patterns):
    """Does this repo-relative posix path match any exclusion pattern?

    `a/**` excludes the directory `a` and everything under it. Anything else
    is an fnmatch against the whole relative path AND against the basename,
    so `*.md` catches `post1/README.md` as well as `README.md`.
    """
    for pat in patterns:
        if pat.endswith("/**"):
            head = pat[:-3]
            if rel == head or rel.startswith(head + "/"):
                return True
        elif fnmatch.fnmatch(rel, pat) or \
                fnmatch.fnmatch(posixpath.basename(rel), pat):
            return True
    return False


def derive_data(rule):
    """Walk the rule's source directory. Returns (files, note).

    `files` is a sorted list of repo-relative-to-src posix paths. `note` is
    None on success, or a string saying why nothing could be derived -- which
    the caller must surface as INCONCLUSIVE, never as an empty pass.
    """
    rel_src = rule["src"].replace("/", os.sep)
    root = os.path.join(REPO, rel_src)
    if not os.path.isdir(root):
        return [], "declared data source is not a directory: %s" % rule["src"]
    excl = rule.get("exclude", [])
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        rel_dir = os.path.relpath(dirpath, root).replace(os.sep, "/")
        if rel_dir == ".":
            rel_dir = ""
        # Prune excluded directories rather than walking into them -- on
        # `data/capture` that is 690 files and tens of megabytes of stat calls.
        keep = []
        for d in dirnames:
            rd = posixpath.join(rel_dir, d) if rel_dir else d
            if not _excluded(rd, excl):
                keep.append(d)
        dirnames[:] = keep
        for fn in filenames:
            rel = posixpath.join(rel_dir, fn) if rel_dir else fn
            if not _excluded(rel, excl):
                out.append(rel)
    out.sort()
    if not out:
        return [], ("derived ZERO files from %s -- the exclusion set ate "
                    "everything, so nothing was verified" % rule["src"])
    return out, None


def _sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            b = f.read(1 << 20)
            if not b:
                return h.hexdigest()
            h.update(b)


SIDECAR_SUFFIX = ".built.json"


def sidecar_check(src, expect=None):
    """Do these bytes still match the build that produced them?

    `tools/buildlock.py` writes `<artifact>.built.json` beside every artifact
    it builds. A verifier opening the DLL minutes later otherwise has no way to
    tell whether it is reading the build it thinks it is -- and a hand-copied
    file with a fresh mtime and stale bytes is a measured state, not a
    hypothetical one.

    THREE outcomes. A MISSING sidecar is a one-line NOTE, not a refusal:
    artifacts built before the lock existed have none, and refusing them would
    only teach people to pass --no-selftest. A sidecar that DISAGREES is a
    refusal, because it is positive evidence the file changed.

    -> (ok, lines)
    """
    lines = []
    side = src + SIDECAR_SUFFIX
    try:
        with open(side, "r", encoding="utf-8") as f:
            doc = json.load(f)
    except (OSError, ValueError):
        doc = None
    have = None
    if doc or expect:
        try:
            have = _sha(src)
        except OSError as e:
            return False, ["INCONCLUSIVE: could not hash %s (%s) -- that is "
                           "not a pass." % (src, e)]
    if doc is None:
        lines.append("NOTE no %s -- this artifact was not built through "
                     "buildlock.py, so nothing vouches for its bytes."
                     % os.path.basename(side))
    else:
        want = doc.get("sha256")
        if not want:
            lines.append("NOTE %s has no sha256 field -- it vouches for "
                         "nothing." % os.path.basename(side))
        elif want != have:
            lines.append("ARTIFACT REPLACED SINCE BUILD: %s" % src)
            lines.append("  built  %s  (target %r, pid %s, %s)"
                         % (want, doc.get("target"), doc.get("pid"),
                            doc.get("finished_h") or doc.get("finished")))
            lines.append("  now    %s" % have)
            lines.append("  The file on disk is not the one the build "
                         "recorded. Rebuild, or find out who overwrote it "
                         "-- do NOT deploy these bytes.")
            return False, lines
        elif doc.get("stale_sources"):
            # MEASURED 2026-09-03 19:24: buildlock reported success for a
            # build whose sources were edited AFTER the lock was acquired.
            # The bytes are internally consistent -- the sha matches -- and
            # they are still a PRE-EDIT snapshot, so every marker check on
            # them measures the wrong build. That is why this refusal is
            # separate from the sha one: agreement with the sidecar proves
            # nothing about which revision was compiled.
            lines.append("SOURCES CHANGED DURING THAT BUILD: %s" % src)
            lines.append("  the sidecar records stale_sources=true (%s)"
                         % (doc.get("source_check_why") or "no reason "
                            "recorded"))
            for f in (doc.get("sources_changed") or [])[:8]:
                lines.append("    %s   mtime %s"
                             % (f.get("path"), f.get("mtime_h")))
            lines.append("  These bytes predate those edits. Rebuild before "
                         "deploying; do NOT marker-check this artifact.")
            return False, lines
        else:
            lines.append("built %s by %r at %s (sha matches)"
                         % (want[:12], doc.get("target"),
                            doc.get("finished_h") or doc.get("finished")))
            if doc.get("source_check") == "not-performed":
                lines.append("NOTE the source-change check was NOT PERFORMED "
                             "for that build (%s) -- which revision of the "
                             "sources these bytes are is unestablished."
                             % (doc.get("source_check_why") or ""))
    if expect:
        if have is None:
            try:
                have = _sha(src)
            except OSError as e:
                return False, ["INCONCLUSIVE: could not hash %s (%s)"
                               % (src, e)]
        if have.lower() != expect.lower():
            lines.append("EXPECTED SHA MISMATCH: %s" % src)
            lines.append("  --expect %s" % expect)
            lines.append("  actual   %s" % have)
            return False, lines
        lines.append("--expect matches")
    return True, lines


def is_build_output(rel):
    """Is this artifact WRITTEN by a build, or checked-in data a deploy ships?

    Only a build output can be deleted out from under a deploy by another
    build, and only a build output is ever staged. `registry/mods.json` is the
    second kind: it is in git, no build writes it, and looking for a stage of
    it would report a missing stage for every deploy.
    """
    r = rel.replace("\\", "/")
    return ("/bin/" in r or r.startswith("bin/")
            or r.startswith("installer/build/"))


def stage_accept(art, C):
    """The predicate `stage.pick` applies to each candidate: do the STAGED
    bytes pass this artifact's own marker/export check?

    It is the same `verify()` the deploy already runs, pointed at the staged
    file. Selecting a stage on age alone would be a choice made without
    looking, and the marker rule (CLAUDE.md 4) is not weakened by where the
    bytes live.
    """
    def accept(rec):
        verdict, problems = verify(art, rec["path"], C)
        if verdict == OK:
            return True, ""
        return False, "%s -- %s" % (verdict, "; ".join(problems[:2])
                                    or "no detail")
    return accept


def resolve_stages(args, arts, C):
    """Which bytes each artifact will be deployed FROM. -> (map, notes, refuse).

    `map` is artifact-name -> stage record. An artifact absent from it is
    deployed from the repo path exactly as before.

    MEASURED 2026-09-04 08:58: a good `build host` was deleted by the next
    build before the deploy could copy it, and the launcher ran the old DLL.
    Deploying from `.stage/` closes that window, because no build writes there.

    Three outcomes, and the middle one is the point:

      * a stage exists and passes its markers -> deploy those bytes;
      * `--sha` was given and no such stage exists -> REFUSE (never silently
        substitute different bytes for the ones that were named);
      * no stage exists at all -> a loud NOTE and a fall back to bin/, unless
        `--stage-only`. Artifacts built before staging existed have none, and
        refusing them by default would make this change a deploy outage rather
        than a safety net. The fallback is the pre-existing behaviour, with the
        pre-existing sidecar guard still in front of it.
    """
    notes, out = [], {}
    if getattr(args, "no_stage", False):
        notes.append("--no-stage: deploying from bin/. A build running now "
                     "can delete a file mid-copy (measured 2026-09-04).")
        return out, notes, False
    repo = REPO
    sha = getattr(args, "sha", None)
    if sha and len(arts) != 1:
        notes.append("--sha names ONE build but %d artifacts are selected. "
                     "Use --only." % len(arts))
        return out, notes, True
    refuse = False
    for art in arts:
        if not is_build_output(art["src"]):
            notes.append("%-8s is checked-in data, not a build output -- no "
                         "stage is expected; deploying from the repo copy."
                         % art["name"])
            continue
        rec, why = stage.pick(repo, artifact_src=art["src"].replace("\\", "/"),
                              artifact=os.path.basename(art["src"]),
                              sha_prefix=sha, accept=stage_accept(art, C))
        for w in why:
            notes.append("%-8s %s" % (art["name"], w))
        if rec:
            out[art["name"]] = rec
            notes.append("%-8s deploying from STAGE %s (built %s, git %s)"
                         % (art["name"], rec["sha"], rec["built_h"],
                            (rec["git_head"] or "?")[:12]))
            continue
        if sha:
            notes.append("%-8s REFUSING: --sha %s named a stage that does not "
                         "exist or was rejected above." % (art["name"], sha))
            refuse = True
            continue
        if getattr(args, "stage_only", False):
            notes.append("%-8s REFUSING: --stage-only and no usable stage. "
                         "Rebuild through tools/buildlock.py." % art["name"])
            refuse = True
            continue
        notes.append("%-8s NO USABLE STAGE -- falling back to %s. A build "
                     "running right now can delete that file mid-copy; that "
                     "is the race staging exists to close."
                     % (art["name"], art["src"]))
    return out, notes, refuse


def art_source(art, args):
    """The path this artifact is verified AND copied from. One function, so a
    deploy can never check one file and copy another."""
    override = getattr(args, "artifact", None)
    if override:
        return os.path.abspath(override)
    smap = getattr(args, "_stage_map", None) or {}
    rec = smap.get(art["name"])
    if rec:
        return rec["path"]
    return os.path.join(REPO, art["src"].replace("/", os.sep))


def selftest_gate(args, C):
    """Run `selftests.py --fast` before copying anything. -> (ok, why).

    Six verifiers reported PASS on visibly wrong state on 2026-09-01 because
    their checks could not fail. Each got a self-test afterwards; nothing ran
    them, and when a runner was finally pointed at the tree it found six
    already red. A gate is the difference between a suite that exists and a
    suite that is true.
    """
    red, green, yellow, dim, reset = C
    if getattr(args, "no_selftest", False):
        print("%s!! --no-selftest: the self-test suite was NOT run. Nothing "
              "has checked that this repo's verifiers can still fail.%s"
              % (yellow, reset))
        return True, "skipped by --no-selftest"
    runner = os.path.join(HERE, "selftests.py")
    if not os.path.isfile(runner):
        print("%sNOTE%s selftests.py is not present in this checkout -- the "
              "deploy gate could not run. That is INCONCLUSIVE, not a pass."
              % (yellow, reset))
        return True, "runner absent"
    try:
        sys.path.insert(0, HERE)
        import selftests                                # noqa: E402
        fresh, why = selftests.cache_is_green()
    except Exception as e:                              # noqa: BLE001
        fresh, why = False, "could not read the cache (%s)" % e
    if fresh:
        print("self-tests: %s%s%s" % (green, why, reset))
        return True, why
    print("self-tests: %s -- running `selftests.py --fast`" % why)
    r = subprocess.run([sys.executable, runner, "--fast"], cwd=REPO)
    if r.returncode == 0:
        print("%sself-tests green%s" % (green, reset))
        return True, "ran green"
    return False, ("selftests.py --fast exited %d. Re-run "
                   "`python tools/selftests.py --fast` for the table; the "
                   "failing items are named there." % r.returncode)


ENABLED = "ENABLED"
SWITCHED_OFF = "SWITCHED OFF"
MISSING = "MISSING"
AMBIGUOUS = "AMBIGUOUS"


def off_path(dst):
    return dst + ".off"


def live_state(dst):
    """Which of four states the live install is in for one artifact path.

    Returns (state, path_that_exists_or_None).

    The only name that counts as switched off is EXACTLY `<dst>.off`, and the
    lookup is two `isfile` calls on known paths -- never a glob and never a
    walk. Both of those restrictions are load-bearing:

      * the live install carries `mods/fov/fov.dll.off.disabled-orig`, a stale
        rename from 2026-08-19, sitting beside a perfectly live `fov.dll`.
        Any pattern loose enough to match `*.off*` reports fov as switched
        off, which is wrong -- fov is ENABLED.
      * `<install>/mods-newbuilds-20260825/` holds seven more `.dll.off` files
        (blackdivision, classicmovement, fov, morebots, perf, sain, sway).
        Those are a BACKUP DIRECTORY, not live state. A recursive glob picks
        them up and reports mods as switched off that the install does not
        even have -- the same shape of error that made fact #128 read as
        current when it was stale.
      * there are 140+ `.bak-<timestamp>` files across the install. Keying off
        exact paths ignores all of them for free.

    AMBIGUOUS -- both `<dst>` and `<dst>.off` present -- is reported rather
    than resolved. The loader takes the enabled one, but the pair means some
    earlier deploy or hand-edit left a stray behind, and silently calling that
    ENABLED hides it.
    """
    off = off_path(dst)
    if os.path.isfile(dst):
        return (AMBIGUOUS if os.path.isfile(off) else ENABLED), dst
    if os.path.isfile(off):
        return SWITCHED_OFF, off
    return MISSING, None


def verify_data(art, install, C):
    """Install-side: does the live install hold every declared data file?

    Returns (verdict, problems). This is a post-condition, so it compares the
    DESTINATION against the repo, not the repo against itself -- a check whose
    only input is our own write is the failure mode CLAUDE.md 9b names.
    """
    rules = art.get("data", [])
    if not rules and not art.get("verifyInstalled"):
        return OK, []
    if not os.path.isdir(install):
        return INCONCLUSIVE, ["install directory does not exist: %s -- the "
                              "data could not be looked at at all" % install]
    problems = []
    unknown = []
    checked = 0

    # `verifyInstalled` is for an artifact whose SOURCE is checked-in data
    # rather than a build output -- `registry/mods.json`. Its markers are
    # scanned in the repo copy, so marker verification alone says nothing
    # about the install, and that is precisely how a registry a day old sat
    # live while `check` printed ok. Compare the bytes.
    if art.get("verifyInstalled"):
        s = os.path.join(REPO, art["src"].replace("/", os.sep))
        d = os.path.join(install, art["dst"].replace("/", os.sep))
        if not os.path.isfile(s):
            unknown.append("source is absent: %s -- nothing to compare the "
                           "install against" % art["src"])
        elif not os.path.isfile(d):
            problems.append("ABSENT from the install: %s" % art["dst"])
        elif os.path.getsize(s) != os.path.getsize(d) or _sha(s) != _sha(d):
            problems.append("the installed %s DIFFERS from the repo copy -- "
                            "the install is running a stale one" % art["dst"])

    for rule in rules:
        files, note = derive_data(rule)
        if note:
            unknown.append(note)
            continue
        floor = rule.get("minFiles", 1)
        if len(files) < floor:
            problems.append(
                "%s derived only %d file(s), below the declared floor of %d "
                "-- data is missing from the REPO, not just the install"
                % (rule["src"], len(files), floor))
            continue
        src_root = os.path.join(REPO, rule["src"].replace("/", os.sep))
        dst_root = os.path.join(install, rule["dst"].replace("/", os.sep))
        missing = []
        differs = []
        for rel in files:
            s = os.path.join(src_root, rel.replace("/", os.sep))
            d = os.path.join(dst_root, rel.replace("/", os.sep))
            if not os.path.isfile(d):
                missing.append(rel)
                continue
            checked += 1
            if os.path.getsize(s) != os.path.getsize(d) or _sha(s) != _sha(d):
                differs.append(rel)
        if missing:
            problems.append("%s: %d of %d data file(s) ABSENT from the install:"
                            % (rule["dst"], len(missing), len(files)))
            for rel in missing[:12]:
                problems.append("    MISSING  %s/%s" % (rule["dst"], rel))
            if len(missing) > 12:
                problems.append("    ... and %d more" % (len(missing) - 12))
        if differs:
            problems.append("%s: %d of %d data file(s) DIFFER from the repo:"
                            % (rule["dst"], len(differs), len(files)))
            for rel in differs[:12]:
                problems.append("    DIFFERS  %s/%s" % (rule["dst"], rel))
            if len(differs) > 12:
                problems.append("    ... and %d more" % (len(differs) - 12))
        if (missing or differs) and rule.get("why"):
            problems.append("    why it matters: %s" % rule["why"])
    if problems:
        return FAIL, problems
    if unknown:
        return INCONCLUSIVE, unknown + [
            "nothing was verified for this artifact's data -- this is NOT "
            "evidence the install is correct."]
    return OK, []


def verify_seed(art, install):
    """Install-side: does every SEED file this artifact declares exist there?

    A seed is a file the install needs to have but that the install OWNS once
    it exists -- `config.json` is the only kind today. It is emphatically not
    a data file: data is copied every deploy and must be byte-identical to the
    repo, whereas a config.json legitimately DIVERGES the moment a player
    moves a slider. So the post-condition here is EXISTENCE, not equality.
    Asserting equality would fail every install that had ever been configured,
    and asserting nothing is how this was missed.

    Measured 2026-08-28: no artifact shipped config.json at all. The mods that
    had one in the live install got it from some earlier hand-copy; the three
    newest -- debug, textures, waypoints -- never did. The user-visible symptom
    was the F3 profiler toggle doing nothing, four times, while the host log
    said exactly why ("no config.json for aowl.debug") and nobody was reading
    that line. The setting rendered, the edit was accepted and queued, and it
    had nowhere to land.

    Returns (verdict, problems).
    """
    rules = art.get("seed", [])
    if not rules:
        return OK, []
    if not os.path.isdir(install):
        return INCONCLUSIVE, ["install directory does not exist: %s -- the "
                              "seed files could not be looked at at all"
                              % install]
    problems = []
    unknown = []
    for rule in rules:
        s = os.path.join(REPO, rule["src"].replace("/", os.sep))
        d = os.path.join(install, rule["dst"].replace("/", os.sep))
        if not os.path.isfile(s):
            unknown.append("seed source is absent from the REPO: %s -- so "
                           "nothing can be said about the install" % rule["src"])
            continue
        if not os.path.isfile(d):
            problems.append(
                "SEED ABSENT from the install: %s -- every setting this mod "
                "declares will be read at its schema default, and every edit "
                "the settings UI accepts will be DISCARDED (the host answers "
                "ErrNotFound for a config set with no file)." % rule["dst"])
            if rule.get("why"):
                problems.append("    why it matters: %s" % rule["why"])
    if problems:
        return FAIL, problems
    if unknown:
        return INCONCLUSIVE, unknown
    return OK, []


def data_count(art):
    """How many data files this artifact declares, for the ok line."""
    n = 0
    for rule in art.get("data", []):
        files, note = derive_data(rule)
        n += len(files)
    return n


def pe_exports(path):
    """Names in a PE image's export directory. Returns (names, note).

    A marker asserts a STRING IS IN THE FILE, which the compiler puts there
    whether or not the function is reachable by name. Measured 2026-08-27:
    the shipped host DLL contained `aowl_host_gameworld`'s code AND its name
    as text, and had ZERO `aowl_host_*` PE exports -- Nim's `{.exportc.}`
    emits a C symbol, not an export. `GetProcAddress` returned NULL and three
    mods logged an honest refusal for an unknown length of time. So this
    reads the export table itself; nothing else can tell the two apart.

    `note` is non-None when the table could not be READ (not a PE, no export
    directory, truncated) -- the caller must treat that as INCONCLUSIVE, not
    as "no exports".
    """
    import struct
    with open(path, "rb") as f:
        b = f.read()
    if len(b) < 0x40 or b[:2] != b"MZ":
        return None, "not a PE image (no MZ)"
    e_lfanew = struct.unpack_from("<I", b, 0x3C)[0]
    if e_lfanew + 24 > len(b) or b[e_lfanew:e_lfanew + 4] != b"PE\0\0":
        return None, "not a PE image (no PE signature)"
    coff = e_lfanew + 4
    nsec, opt_size = struct.unpack_from("<H", b, coff + 2)[0],         struct.unpack_from("<H", b, coff + 16)[0]
    opt = coff + 20
    magic = struct.unpack_from("<H", b, opt)[0]
    if magic == 0x20B:      # PE32+
        dirs = opt + 112
    elif magic == 0x10B:    # PE32
        dirs = opt + 96
    else:
        return None, "unknown optional-header magic 0x%X" % magic
    exp_rva, exp_size = struct.unpack_from("<II", b, dirs)
    sects = []
    sh = opt + opt_size
    for i in range(nsec):
        o = sh + i * 40
        vsize, vaddr, rsize, raddr = struct.unpack_from("<IIII", b, o + 8)
        sects.append((vaddr, max(vsize, rsize), raddr))

    def off(rva):
        for vaddr, vsize, raddr in sects:
            if vaddr <= rva < vaddr + vsize:
                return raddr + (rva - vaddr)
        return None

    if not exp_rva or not exp_size:
        return [], None   # a valid PE that simply exports nothing
    d = off(exp_rva)
    if d is None or d + 40 > len(b):
        return None, "export directory RVA 0x%X is not in any section" % exp_rva
    nnames = struct.unpack_from("<I", b, d + 24)[0]
    names_rva = struct.unpack_from("<I", b, d + 32)[0]
    na = off(names_rva)
    if na is None:
        return None, "export name table RVA 0x%X is not mapped" % names_rva
    out = []
    for i in range(nnames):
        if na + i * 4 + 4 > len(b):
            return None, "export name table is truncated"
        so = off(struct.unpack_from("<I", b, na + i * 4)[0])
        if so is None:
            return None, "an export name string is not mapped"
        end = b.find(b"\0", so)
        out.append(b[so:end].decode("ascii", "replace"))
    return sorted(out), None


def build_in_progress():
    """Describe the running build, or None.

    Shares the lock file `tools/buildlock.py` writes, so the two cannot
    disagree about whether a build is running. Deliberately read-only and
    failure-tolerant: it only IMPROVES an error message, so it must never
    raise, and must never block a deploy on its own.
    """
    try:
        import json as _json
        with open(os.path.join(REPO, ".aowl-build.lock"),
                  "r", encoding="utf-8") as f:
            held = _json.load(f)
        return "pid %s running %r since %s" % (
            held.get("pid"), held.get("cmd"), held.get("started_h"))
    except Exception:
        return None


def verify(art, src, C):
    """Return (verdict, list-of-problem-strings). Reads the file once."""
    red, green, yellow, dim, reset = C
    problems = []
    if not os.path.isfile(src):
        gone = missing_input(art)
        if gone:
            rel, why = gone
            msg = ["not built: %s" % src,
                   "its declared input is ABSENT: %s" % rel]
            if why:
                msg.append("    %s" % why)
            msg.append("nothing was verified -- this is NOT evidence the "
                       "markers are missing.")
            return INCONCLUSIVE, msg
        # "I did not build it" is not a marker failure. Reporting it as FAIL
        # put 16 red lines in front of every agent working in a fresh
        # worktree and trained them to scroll past FAIL -- which is how a
        # real dropped feature gets waved through. Nothing was verified, so
        # the honest verdict is INCONCLUSIVE (CLAUDE.md 9b). A missing
        # MARKER in a file that IS built stays FAIL, loudly.
        # A BUILD IN PROGRESS is a different fact from "never built", and
        # saying the wrong one sends the reader to rebuild something that is
        # already being rebuilt. `aowl` removes the output before writing it,
        # so an artifact vanishes for the whole build -- measured: a deploy
        # issued while a subagent's build was running reported "not built" for
        # a DLL that had verified 87 markers a minute earlier.
        building = build_in_progress()
        if building:
            return INCONCLUSIVE, [
                "not built YET: %s" % src,
                "a BUILD IS IN PROGRESS: %s" % building,
                "the artifact is absent because it is being rebuilt right "
                "now, not because it was never built. Wait for the build to "
                "finish (python tools/buildlock.py --status) and re-run."]
        return INCONCLUSIVE, ["not built: %s" % src,
                              "nothing was verified -- this is NOT evidence "
                              "the markers or exports are missing. Build it, "
                              "or narrow with --only."]
    size = os.path.getsize(src)
    floor = art.get("minBytes", 1)
    if size < floor:
        problems.append("only %d bytes (expected at least %d) -- a failed or "
                        "half-written build" % (size, floor))
        # No point scanning a truncated file for markers.
        return FAIL, problems

    with open(src, "rb") as f:
        blob = f.read()
    missing = []
    # Search the RAW bytes -- never decode the file (litscan's docstring says
    # why). The needle is encoded, in every encoding this tool's --contains
    # and --absent paths use: litscan.encodings("deploy") is utf8 + utf16le.
    # Until 2026-08-31 this loop searched utf8 ONLY, so a declared marker
    # stored as UTF-16LE would have read MISSING and REFUSED A DEPLOY -- a
    # false negative in the one code path that is allowed to block a release.
    # MEASURED when the fix landed: over all 20 declared artifacts, all built,
    # the utf8-only and utf8+utf16le answers agreed on EVERY marker, so no
    # artifact's verdict changed. The fix removes a latent false negative; it
    # did not paper over a real miss.
    _encs = litscan.encodings("deploy")
    for m in art.get("markers", []):
        hits, _off = litscan.find_at(blob, _encs, m)
        if not hits:
            missing.append(m)
    if missing:
        problems.append("%d of %d marker(s) MISSING from the built file:"
                        % (len(missing), len(art.get("markers", []))))
        for m in missing:
            problems.append("    %s" % m)

    want = art.get("exports", [])
    if want:
        names, note = pe_exports(src)
        if names is None:
            problems.append("could not read the export table: %s" % note)
            return INCONCLUSIVE, problems
        have = set(names)
        gone = [e for e in want if e not in have]
        if gone:
            problems.append("%d of %d required PE export(s) ABSENT from the "
                            "built file (the file has %d export(s)):"
                            % (len(gone), len(want), len(names)))
            for e in gone:
                problems.append("    %s" % e)
            problems.append("A mod resolves this name with GetProcAddress. "
                            "The code can be compiled in and the name can be "
                            "present as text while the export is not there: "
                            "Nim's {.exportc.} emits a C symbol, NOT a PE "
                            "export. Wrap it in a __declspec(dllexport) C "
                            "shim, as region.nim does.")
    return (OK if not problems else FAIL), problems


def _encodings(mode):
    """(label, encoder) pairs. Delegates to litscan; default set unchanged.

    deploy.py historically searched utf8 + utf16le only, and its output is
    quoted in docs, so "any" here keeps meaning that pair. tools/markers.py
    additionally searches the explicit `ascii` form, which is what the broken
    PowerShell idiom claimed to be doing.
    """
    if mode in ("utf8", "utf16"):
        return litscan.encodings(mode)
    return litscan.encodings("deploy")



def verify_literals(src, contains, absent, mode, C, controls=None):
    """Assert raw-byte presence/absence of ad-hoc literals in ONE file.

    Additive to the marker check, never a substitute for it: markers say "this
    is a valid build of that target", a literal says "tonight's edit is in
    THIS file". `aowl build-mod` prints `ok mod X` without verifying anything,
    so a successful build is not evidence your edit landed.

    Raw bytes, like the marker scan -- deliberately NOT the PowerShell idiom
    `[Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes(p)).Contains(s)`,
    which returns SELECTIVE false negatives (facts #151/#152: False for four
    markers `grep -c` finds in the same bytes, True for a fifth in the same
    loop).

    A literal may be embedded UTF-8 or UTF-16LE (Nim/C# string tables differ
    within one artifact), so by default BOTH are searched and the matching
    encoding is reported. A literal present only as UTF-16 must never read as
    absent.

    WHAT A MISS DOES NOT MEAN. `--contains` is SOUND as a positive signal; a
    bare miss is unsound as a negative one. A contiguous match proves the text
    is in the file. A miss is only a FAIL when a positive control matched and
    the literal's word-runs cover under ABSENT_COVERAGE of it -- that call is
    `markers.classify()`, shared with tools/markers.py via litscan, not
    reimplemented here. nimony stores each `&`-concatenated source
    fragment as a SEPARATE rodata string, so a sentence assembled from
    fragments never appears contiguously and no substring search at any
    encoding can ever match it. Measured on mods/maps/bin/maps.dll (764,416
    bytes, fix-maps-late-arm@a62b427): "was NEVER ARMED", "LATE ARMS the feed
    in place" and "no draw participant is registered" all missed while
    "LATE ARM", "and no draw participant is " and five other single-fragment
    literals from the same source lines matched. So a miss is INCONCLUSIVE,
    never FAIL -- a flat FAIL there reads as "the feature is missing, do not
    deploy", which is exactly the confidently-wrong answer this tool exists
    to prevent. On a miss the longest whitespace-delimited word-run of the
    literal that IS present is reported, which usually shows the split.

    `--absent` inherits the same limitation in the more dangerous direction:
    a literal can be "absent" merely because it was assembled. So it is
    THREE-way, and each outcome has to be reachable:

      FAIL          a contiguous hit -- the text is demonstrably still there,
                    reported with its byte offset.
      INCONCLUSIVE  the literal is not contiguous but most of it survives as
                    word-runs (the shape of a `&`-split sentence), OR no
                    positive control matched, so the search was never shown
                    to be capable of finding anything here.
      PASS          a miss, with low fragment coverage, AND a positive
                    control that DID match.

    The positive control is what stops this from being a check that cannot
    fail in the other direction. By default it is the artifact's own declared
    markers from deploy.json (data, never edited to make a check pass);
    `--control` supplies one explicitly.

    The earlier version treated ANY surviving word-run of >=6 characters as
    INCONCLUSIVE, which made `--absent` UNABLE TO PASS on any sentence-length
    literal -- a generic run like 'the walk finished' matches almost any
    build -- and then printed that short shared fragment as if it were the
    evidence for a verdict about a 50-character literal. Both are fixed:
    coverage is measured over the whole literal and every surviving run is
    listed with its size, never one cherry-picked fragment.

    Returns (verdict, lines). An unreadable file is INCONCLUSIVE too: nothing
    was searched, which is neither a pass nor a content failure (CLAUDE.md 9b).
    """
    red, green, yellow, dim, reset = C
    encs = _encodings(mode)
    searched = "/".join(lbl for lbl, _ in encs)
    if not os.path.isfile(src):
        return INCONCLUSIVE, ["--contains/--absent: no such file: %s" % src,
                              "nothing was searched -- this is NOT evidence "
                              "the literal is absent."]
    try:
        with open(src, "rb") as f:
            blob = f.read()
    except OSError as e:
        return INCONCLUSIVE, ["--contains/--absent: could not read %s: %s"
                              % (src, e),
                              "nothing was searched -- this is NOT evidence "
                              "the literal is absent."]
    size = len(blob)
    lines = []
    bad = 0
    unknown = 0
    where = "    searched %s over %s (%d bytes)" % (searched, src, size)
    # ONE control for both directions. `--absent` always needed it; `--contains`
    # needs it too now that a miss is allowed to be called MISSING -- that is
    # the entire licence for saying so (CLAUDE.md 9b).
    control = _pick_control(blob, encs, controls) if (contains or absent) \
        else None
    for lit in contains:
        # DELEGATED to tools/markers.py, which owns this three-way decision and
        # shares tools/litscan.py with this file, so the mod-side tool and the
        # host-side tool cannot answer the same question differently.
        outcome, d = markers.classify(blob, encs, lit, control)
        if outcome == markers.PRESENT:
            lines.append("%scontains%s PASS  %r  as %s"
                         % (green, reset, lit, "+".join(d["encodings"])))
            continue
        if outcome == markers.MISSING:
            # A miss is a FINDING when, and only when, the search was shown
            # capable of finding text in these bytes AND almost none of the
            # literal survives as word-runs. Below that bar it stays
            # INCONCLUSIVE, because a nimony `&` concatenation is stored as
            # separate rodata fragments and can never match contiguously.
            # Until this branch existed, `--contains` could not fail, so two
            # agents in one night fell back to `grep -a` to assert a specific
            # new marker string, which is the gap this closes.
            bad += 1
            lines.append("%scontains%s FAIL  %r  MISSING" % (red, reset, lit))
            lines.append(where)
            lines.append("    %s" % d["reason"])
            lines.append("    positive control %r (%s) DOES match as %s at "
                         "byte offset %d -- the search can find text in these "
                         "bytes, so this miss is a finding."
                         % (control[1], control[0], "+".join(control[2]),
                            control[3]))
            for frag, fhits in d.get("fragments", []):
                lines.append("      still present: %r (%d bytes, as %s)"
                             % (frag, len(frag), "+".join(fhits)))
            continue
        unknown += 1
        lines.append("%scontains%s NO-MATCH  %r  (INCONCLUSIVE)"
                     % (yellow, reset, lit))
        lines.append(where)
        lines.append("    %s" % d["reason"])
        frag, fhits = _longest_present_fragment(blob, encs, lit)
        if frag:
            lines.append("    no contiguous match; longest present fragment: "
                         "%r (%d bytes, as %s) -- consistent with a literal "
                         "split across rodata fragments."
                         % (frag, len(frag), "+".join(fhits)))
        else:
            lines.append("    no word-run of this literal is present either, "
                         "so it may well be genuinely absent -- but that is "
                         "still not proven here.")
        lines.append("    NOTE: %s" % FRAGMENT_NOTE)
        lines.append("    This is NOT proof the feature is absent.")
    for lit in absent:
        hits, off = _find_at(blob, encs, lit)
        if hits:
            bad += 1
            lines.append("%sabsent%s   FAIL  %r  IS STILL PRESENT as %s "
                         "at byte offset %d (0x%x)"
                         % (red, reset, lit, "+".join(hits), off, off))
            lines.append(where)
            continue
        # A miss is THREE-WAY, never two. It is a removal only if (a) the
        # literal is not merely SPLIT across rodata fragments, and (b) the
        # search demonstrably could have found it. Anything else is
        # INCONCLUSIVE, and INCONCLUSIVE never exits as success.
        frags, covered = _fragment_cover(blob, encs, lit)
        ratio = (float(covered) / len(lit)) if lit else 0.0
        cover_txt = ("%d of %d bytes (%.0f%%) of it survive as %d word-run(s)"
                     % (covered, len(lit), ratio * 100.0, len(frags)))
        reasons = []
        if ratio >= _ABSENT_COVERAGE:
            reasons.append(
                "the literal is not contiguous, but %s -- the shape of a "
                "sentence SPLIT across rodata fragments, not of a removal."
                % cover_txt)
        if control is None:
            reasons.append(
                "no positive control matched, so this search was never shown "
                "to be CAPABLE of finding text in these bytes; \"not found\" "
                "here is indistinguishable from \"we could not look\". Pass "
                "--control with a literal you know is present%s."
                % ("" if controls else
                   " (this artifact declares no markers to use as one)"))
        if reasons:
            unknown += 1
            lines.append("%sabsent%s   NO-MATCH  %r  (INCONCLUSIVE)"
                         % (yellow, reset, lit))
            lines.append(where)
            for r in reasons:
                lines.append("    %s" % r)
            for frag, fhits in frags:
                lines.append("      still present: %r (%d bytes, as %s)"
                             % (frag, len(frag), "+".join(fhits)))
            lines.append("    NOTE: %s" % FRAGMENT_NOTE)
            continue
        lines.append("%sabsent%s   PASS  %r  in neither %s"
                     % (green, reset, lit, searched))
        lines.append(where)
        lines.append("    positive control %r (%s) DOES match as %s at byte "
                     "offset %d -- the search can find text in these bytes, "
                     "so this miss is a finding."
                     % (control[1], control[0], "+".join(control[2]),
                        control[3]))
        lines.append("    only %s, below the %.0f%% that would indicate a "
                     "merely SPLIT literal."
                     % (cover_txt, _ABSENT_COVERAGE * 100.0))
        for frag, fhits in frags:
            lines.append("      still present: %r (%d bytes, as %s)"
                         % (frag, len(frag), "+".join(fhits)))
    if bad:
        return FAIL, lines
    return (INCONCLUSIVE if unknown else OK), lines


def cmd_check(args, cfg, C, check_data=True):
    """`check_data=False` verifies markers only.

    Used by `deploy` for its PRE-check: before a deploy the install is
    expected to be out of date -- that is why you are deploying -- so letting
    an install-side data mismatch refuse the copy would make the tool unable
    to fix the exact failure it exists to catch. The data check runs again
    after the copy, where it is a real post-condition.
    """
    red, green, yellow, dim, reset = C
    install = args.install or cfg["install"]
    arts = select(cfg, args.only)
    override = getattr(args, "artifact", None)
    if override:
        # Verify a build that has NOT been deployed. Every agent has
        # hand-rolled this with PowerShell ReadAllBytes + .Contains, which
        # has returned FALSE NEGATIVES five separate times (facts #151,
        # #152) -- reporting 4 of 4 markers absent from a build `strings -a`
        # and this tool both confirm as correct. Use this instead.
        override = os.path.abspath(override)
        if not os.path.isfile(override):
            sys.exit("--artifact: no such file: %s" % override)
        if len(arts) != 1:
            base = os.path.basename(override).lower()
            cand = [a for a in arts
                    if os.path.basename(a["src"]).lower() == base]
            if len(cand) != 1:
                sys.exit(
                    "--artifact needs to know WHICH marker set to apply.\n"
                    "%s by basename, so pass --only NAME.\n"
                    "Known: %s"
                    % ("%d artifacts match %r" % (len(cand), base) if cand
                       else "No artifact matches %r" % base,
                       ", ".join(a["name"] for a in arts)))
            arts = cand
        # An undeployed file has no install beside it; the data check would
        # compare against whatever is live and report a mismatch that says
        # nothing about this file.
        check_data = False
        print("%s--artifact%s verifying %s against marker set %r "
              "(install-side data check NOT performed)"
              % (dim, reset, override, arts[0]["name"]))
    contains = list(getattr(args, "contains", None) or [])
    absent = list(getattr(args, "absent", None) or [])
    controls = list(getattr(args, "control", None) or [])
    encmode = getattr(args, "encoding", "any") or "any"
    bad = 0
    unknown = 0
    for art in arts:
        src = art_source(art, args)
        verdict, problems = verify(art, src, C)
        if contains or absent:
            # ADDITIVE. The literal scan can only make the verdict worse; a
            # passing --contains never masks a missing marker.
            # Positive controls for `--absent`: explicit --control first,
            # then this artifact's own markers -- literals a valid build is
            # required to contain, taken from deploy.json as DATA.
            ctrls = ([("--control", c) for c in controls]
                     + [("declared marker", m)
                        for m in art.get("markers", [])])
            lverdict, llines = verify_literals(src, contains, absent,
                                               encmode, C, ctrls)
            for ln in llines:
                print("     %s" % ln)
            if lverdict == FAIL:
                verdict = FAIL
                problems = list(problems) + [
                    "%d literal check(s) FAILED (see the contains/absent lines "
                    "above)." % sum(1 for l in llines if "FAIL" in l)]
            elif lverdict == INCONCLUSIVE and verdict == OK:
                verdict = INCONCLUSIVE
                problems = list(problems) + [
                    "%d literal check(s) returned NO-MATCH (see the lines "
                    "above). A miss is INCONCLUSIVE, not a failure: %s"
                    % (sum(1 for l in llines if "NO-MATCH" in l),
                       FRAGMENT_NOTE)]
        if verdict == OK and check_data:
            dverdict, dproblems = verify_data(art, install, C)
            if dverdict != OK:
                verdict, problems = dverdict, dproblems
        if verdict == OK and check_data:
            sverdict, sproblems = verify_seed(art, install)
            if sverdict != OK:
                verdict, problems = sverdict, sproblems
        n = len(art.get("markers", []))
        if verdict == OK:
            extra = ""
            if check_data and art.get("data"):
                extra = ", %d data file%s" % (data_count(art),
                                              "" if data_count(art) == 1 else "s")
            ne = len(art.get("exports", []))
            if ne:
                extra = ", %d export%s%s" % (ne, "" if ne == 1 else "s", extra)
            print("%sok%s   %-8s %s  (%d marker%s%s, %s bytes)"
                  % (green, reset, art["name"],
                     override if override else art["src"], n,
                     "" if n == 1 else "s", extra, os.path.getsize(src)))
            continue
        # NAME THE PATH ON EVERY VERDICT, not only on the ok line. Measured
        # 2026-09-01: two agents guessed the host DLL's source path
        # (`build\host\...`), got INCONCLUSIVE, and had no way to see which
        # path this tool had actually looked at -- so they guessed again. The
        # absolute path is the one that settles it, and `where` prints the
        # same pair without running a check at all.
        if verdict == INCONCLUSIVE:
            unknown += 1
            print("%sINCONCLUSIVE%s %-8s %s"
                  % (yellow, reset, art["name"], art["src"]))
        else:
            bad += 1
            print("%sFAIL%s %-8s %s" % (red, reset, art["name"], art["src"]))
        print("       expected source: %s" % src)
        for p in problems:
            print("       %s" % p)
    if bad:
        print("\n%s%d artifact(s) FAILED verification.%s" % (red, bad, reset))
        print("A missing marker means the feature's own text is not in the "
              "binary. Do NOT deploy this; rebuild from the right base.")
        print("A MISSING or DIFFERS data line means the install does not hold "
              "the bytes the artifact needs; `deploy` is what fixes that.")
        print("An ABSENT export means a mod's GetProcAddress will return NULL "
              "and the feature will decline at runtime even though its code "
              "and its name are both in the binary.")
    if unknown:
        print("\n%s%d artifact(s) INCONCLUSIVE -- "
              "not built, or its declared data could not be derived, or its "
              "export table could not be read, or a --contains/--absent "
              "literal returned NO-MATCH.%s" % (yellow, unknown, reset))
        print("This is not a pass and not a failure: nothing was verified. "
              "Read the reason printed above the summary, supply what is "
              "missing and re-run, or narrow to the artifacts you did build "
              "(--only).")
    if bad:
        return 1
    return 3 if unknown else 0


def backup_name(dst):
    return "%s.bak-%s" % (dst, time.strftime("%Y%m%d-%H%M%S"))


def cmd_deploy(args, cfg, C):
    red, green, yellow, dim, reset = C
    install = args.install or cfg["install"]
    arts = select(cfg, args.only)

    # WHICH BYTES. Resolved BEFORE the pre-check, and stored on `args`, so
    # that cmd_check verifies exactly the file cmd_deploy will copy. Checking
    # bin/ and then copying a stage (or the reverse) would be a verification
    # of the wrong file -- the failure shape CLAUDE.md 9b is about.
    smap, snotes, srefuse = resolve_stages(args, arts, C)
    args._stage_map = smap
    if snotes:
        print("source of the bytes:")
        for ln in snotes:
            print("  %s" % ln)
    if srefuse:
        print("\n%srefusing to deploy: the requested build is not staged.%s"
              % (red, reset))
        return 1

    # Verify EVERYTHING first, then copy. A partial deploy -- new host DLL
    # against an old tarkov.dll -- is its own class of confusing bug, so if any
    # selected artifact is bad, nothing moves.
    rc = cmd_check(args, cfg, C, check_data=False)
    if rc == 3:
        # Not a failure -- but an artifact that was never built cannot be
        # copied either, so the deploy still stops. The distinction matters
        # for what you do next: supply the input, do not go rebuild.
        print("\n%srefusing to deploy: INCONCLUSIVE, not failed.%s"
              % (yellow, reset))
        return 3
    if rc != 0:
        print("\n%srefusing to deploy.%s" % (red, reset))
        return 1

    # The bytes are verified; now verify the INSTRUMENTS that verified them,
    # and that these are still the bytes the build produced. Both run BEFORE
    # any copy, for the same reason the marker check does: a partial deploy is
    # its own class of confusing bug.
    if getattr(args, "expect", None) and len(arts) != 1:
        print("\n%srefusing to deploy: --expect names ONE sha256 but %d "
              "artifacts are selected. Use --only.%s"
              % (red, len(arts), reset))
        return 1
    ok, lines = True, []
    for art in arts:
        src = art_source(art, args)
        if not os.path.isfile(src):
            continue
        good, ls = sidecar_check(src, getattr(args, "expect", None)
                                 if len(arts) == 1 else None)
        for ln in ls:
            lines.append("%-8s %s" % (art["name"], ln))
        ok = ok and good
    if lines:
        print()
        for ln in lines:
            print("  %s" % ln)
    if not ok:
        print("\n%srefusing to deploy: the artifact is not the build that was "
              "recorded.%s" % (red, reset))
        return 1
    if not args.dry_run:
        green_gate, why = selftest_gate(args, C)
        if not green_gate:
            print("\n%srefusing to deploy: %s%s" % (red, why, reset))
            print("  Pass --no-selftest to deploy anyway. It says so, loudly, "
                  "in the output.")
            return 1

    if not os.path.isdir(install):
        sys.exit("install directory does not exist: %s" % install)

    print("\ninstall %s" % install)
    rollbacks = []
    for art in arts:
        src = art_source(art, args)
        dst = os.path.join(install, art["dst"].replace("/", os.sep))
        if args.dry_run:
            off = off_path(dst)
            if live_state(dst)[0] == SWITCHED_OFF:
                print("%s(dry-run)%s %-8s is switched OFF -> would refresh %s "
                      "and LEAVE it off%s"
                      % (dim, reset, art["name"], os.path.basename(off),
                         "" if not getattr(args, "re_enable", False)
                         else "  [--re-enable: would switch it ON]"))
                continue
            print("%s(dry-run)%s %-8s -> %s" % (dim, reset, art["name"], dst))
            for rule in art.get("data", []):
                files, note = derive_data(rule)
                print("%s(dry-run)%s          %s -> %s"
                      % (dim, reset,
                         note if note else "%d data file(s)" % len(files),
                         rule["dst"]))
            for rel in art.get("invalidates", []):
                print("%s(dry-run)%s          would invalidate %s"
                      % (dim, reset, rel))
            continue
        os.makedirs(os.path.dirname(dst), exist_ok=True)

        # A mod switched OFF in the live install is renamed to `<name>.dll.off`,
        # so the path we are about to write does not exist. Every guard below
        # keys off `os.path.isfile(dst)`, which is therefore False -- no backup
        # is taken, nothing is printed, and `copy2` CREATES the enabled DLL.
        # The result is a mod that was switched off on purpose coming back at
        # the next launch, and the marker check cannot notice because the bytes
        # it verifies are correct. That is exactly how sain and textures were
        # resurrected (fact #156).
        #
        # The switch is the player's, not the deploy's. So the bytes still go
        # out -- an artifact that is off should not also be stale, or switching
        # it back on later silently gets you an old build -- but they go to the
        # `.off` path, and the state is left as it was found. `--re-enable`
        # opts in to the old behaviour, loudly, one artifact at a time.
        off = off_path(dst)
        if live_state(dst)[0] == SWITCHED_OFF:
            if not getattr(args, "re_enable", False):
                try:
                    shutil.copy2(off, backup_name(off))
                    shutil.copy2(src, off)
                except PermissionError:
                    print("%sFAIL%s %s is locked -- the game or "
                          "aowlspt-backend.exe is still running."
                          % (red, reset, off))
                    return 1
                print("%sOFF %s %-8s -> %s"
                      % (yellow, reset, art["name"], off))
                print("     this mod is switched OFF in the install and was "
                      "LEFT off. The new bytes were written to the .off file, "
                      "so it is current if you switch it on. Pass --re-enable "
                      "to switch it on now.")
                continue
            print("%sRE-ENABLING%s %s -- it was switched off (%s) and "
                  "--re-enable was passed."
                  % (yellow, reset, art["name"], os.path.basename(off)))

        if os.path.isfile(dst):
            bak = backup_name(dst)
            shutil.copy2(dst, bak)
            rollbacks.append((art["name"], bak, dst))
            print("     backed up -> %s" % os.path.basename(bak))
        try:
            shutil.copy2(src, dst)
        except PermissionError:
            # The single most common deploy failure: the game or the backend
            # still has the file mapped. Say so, rather than let a stack trace
            # imply something subtler.
            print("%sFAIL%s %s is locked -- the game or aowlspt-backend.exe is "
                  "still running. Close it and run this again." % (red, reset, dst))
            return 1
        print("%sok%s   %-8s -> %s" % (green, reset, art["name"], dst))

        # The data the artifact declares, derived and copied with it. Copied
        # unconditionally rather than "if newer": mtime is not evidence, and a
        # hand-copied file with a fresh mtime and stale bytes is exactly the
        # state three of today's failures were found in.
        for rule in art.get("data", []):
            files, note = derive_data(rule)
            if note:
                print("     %sINCONCLUSIVE%s %s -- no data was copied"
                      % (yellow, reset, note))
                continue
            src_root = os.path.join(REPO, rule["src"].replace("/", os.sep))
            dst_root = os.path.join(install, rule["dst"].replace("/", os.sep))
            wrote = 0
            for rel in files:
                s = os.path.join(src_root, rel.replace("/", os.sep))
                d = os.path.join(dst_root, rel.replace("/", os.sep))
                os.makedirs(os.path.dirname(d), exist_ok=True)
                try:
                    shutil.copy2(s, d)
                except PermissionError:
                    print("%sFAIL%s %s is locked -- the game or "
                          "aowlspt-backend.exe is still running."
                          % (red, reset, d))
                    return 1
                wrote += 1
            print("     data  %d file(s) -> %s" % (wrote, rule["dst"]))

        # SEED files: copied ONLY when the destination does not exist.
        #
        # The opposite rule from `data` above, deliberately. A config.json is
        # the player's own state the moment they touch a slider, so copying it
        # unconditionally would silently reset every setting on every deploy --
        # a far worse bug than the one this fixes. "Absent" is the only state
        # where we know we are not destroying an answer somebody gave.
        for rule in art.get("seed", []):
            s = os.path.join(REPO, rule["src"].replace("/", os.sep))
            d = os.path.join(install, rule["dst"].replace("/", os.sep))
            if not os.path.isfile(s):
                print("     %sINCONCLUSIVE%s seed source absent from the repo: "
                      "%s" % (yellow, reset, rule["src"]))
                continue
            if os.path.isfile(d):
                print("     seed  %s already present -- LEFT ALONE (it is the "
                      "install's own settings state)" % rule["dst"])
                continue
            os.makedirs(os.path.dirname(d), exist_ok=True)
            try:
                shutil.copy2(s, d)
            except PermissionError:
                print("%sFAIL%s %s is locked -- the game or "
                      "aowlspt-backend.exe is still running."
                      % (red, reset, d))
                return 1
            print("     seed  %s was ABSENT -- seeded from the repo defaults"
                  % rule["dst"])

        # A DERIVED file downstream of what we just replaced is not evidence
        # of anything once its input changes. `mods/aowlspt-selection.json` is
        # written by the manager from `store/aowl.manager/selection` PLUS the
        # registry; when the registry was stale it silently degraded to two
        # mods and read as a working selection. Move it aside so the manager
        # recomputes rather than trusting a file computed against a registry
        # that no longer exists.
        for rel in art.get("invalidates", []):
            victim = os.path.join(install, rel.replace("/", os.sep))
            if not os.path.isfile(victim):
                continue
            bak = backup_name(victim)
            shutil.move(victim, bak)
            print("     invalidated %s (derived from this artifact; the "
                  "manager will recompute it) -> %s"
                  % (rel, os.path.basename(bak)))

    if not args.dry_run and any(a.get("data") or a.get("verifyInstalled")
                                or a.get("seed") for a in arts):
        # THE POST-CONDITION. Not a restatement of the copy above: it re-reads
        # the install and hashes what is actually there. A deploy that copied
        # and still does not hold the right bytes must not print success.
        print("\nverifying the install now holds the declared data:")
        post_bad = 0
        post_unknown = 0
        for art in arts:
            if (not art.get("data") and not art.get("verifyInstalled")
                    and not art.get("seed")):
                continue
            v, probs = verify_data(art, install, C)
            if v == OK:
                v, probs = verify_seed(art, install)
            if v == OK:
                n = data_count(art)
                what = ("%d data file(s)" % n) if n else "the installed copy"
                print("%sok%s   %-8s %s present and identical"
                      % (green, reset, art["name"], what))
            elif v == INCONCLUSIVE:
                post_unknown += 1
                print("%sINCONCLUSIVE%s %-8s" % (yellow, reset, art["name"]))
                for p in probs:
                    print("       %s" % p)
            else:
                post_bad += 1
                print("%sFAIL%s %-8s the copy did not take"
                      % (red, reset, art["name"]))
                for p in probs:
                    print("       %s" % p)
        if post_bad:
            print("\n%sthe deploy POST-CONDITION does not hold.%s"
                  % (red, reset))
            return 1
        if post_unknown:
            print("\n%sdata post-condition INCONCLUSIVE -- the binaries were "
                  "deployed, the data was not verified.%s" % (yellow, reset))

    if rollbacks:
        print("\nrollback:")
        for name, bak, dst in rollbacks:
            print('  copy /y "%s" "%s"   :: %s' % (bak, dst, name))
        print("  (or: python tools/deploy.py rollback %s)"
              % ",".join(n for n, _, _ in rollbacks))
    return 0


def _mtime(path):
    return time.strftime("%Y-%m-%d %H:%M",
                         time.localtime(os.path.getmtime(path)))


CURRENT = "current"
STALE = "STALE"
UNKNOWN = "?"


def freshness(live, src):
    """Does the live file hold the bytes of the built one?

    Returns (verdict, detail). UNKNOWN whenever the question could not be
    ASKED -- nothing live, nothing built, or a read that failed -- because
    "I could not compare" must not print as "they match" (CLAUDE.md 9b).
    """
    if live is None:
        return UNKNOWN, "nothing in the install to compare"
    if not src or not os.path.isfile(src):
        return UNKNOWN, "not built in this checkout -- cannot compare"
    try:
        same = _sha(live) == _sha(src)
    except OSError as e:
        return UNKNOWN, "unreadable: %s" % e
    if same:
        return CURRENT, "matches the built artifact"
    return STALE, ("live %s (%s) DIFFERS from built %s (%s)"
                   % (os.path.basename(live), _mtime(live),
                      os.path.basename(src), _mtime(src)))


def unmanaged_mods(install, arts):
    """Mod directories present in the live install that no artifact declares.

    One level deep under `<install>/mods` only. It does NOT recurse, so the
    sibling backup tree `<install>/mods-newbuilds-*` is never even opened --
    that directory is where every other `.dll.off` on the machine lives.
    """
    root = os.path.join(install, "mods")
    if not os.path.isdir(root):
        return []
    known = set()
    for art in arts:
        parts = art["dst"].replace("\\", "/").split("/")
        if len(parts) > 1 and parts[0] == "mods":
            known.add(parts[1].lower())
    out = []
    for name in sorted(os.listdir(root)):
        d = os.path.join(root, name)
        if not os.path.isdir(d) or name.lower() in known:
            continue
        dll = os.path.join(d, name + ".dll")
        out.append((name, live_state(dll)))
    return out


def cmd_status(args, cfg, C):
    """Report the SWITCHED-OFF and staleness state of the live install.

    `check` verifies the bytes of a BUILT file and is blind to this by
    construction: a mod the install has switched off as `<name>.dll.off` has
    correct bytes, so every marker passes while the mod does not load at all
    (fact #156). This is the verb that says so out loud.
    """
    red, green, yellow, dim, reset = C
    install = args.install or cfg["install"]
    # Which checkout's build outputs the live files are compared AGAINST.
    # Defaults to this one. A worktree that has not been built has no build
    # outputs at all, and then every artifact honestly reports "not built in
    # this checkout -- cannot compare" rather than a freshness verdict; point
    # --repo at the checkout you actually build in to get one.
    repo = os.path.abspath(args.repo) if args.repo else REPO
    arts = select(cfg, args.only)
    print("install: %s" % install)
    if repo != REPO:
        print("compared against build outputs in: %s" % repo)
    if not os.path.isdir(install):
        print("%sthe install directory does not exist -- nothing to "
              "report.%s" % (red, reset))
        return 3
    print("")

    off_n = miss_n = stale_n = amb_n = unknown_n = 0
    for art in arts:
        dst = os.path.join(install, art["dst"].replace("/", os.sep))
        src = os.path.join(repo, art["src"].replace("/", os.sep))
        state, live = live_state(dst)
        fresh, detail = freshness(live, src)

        if state == ENABLED:
            tag, col = "ENABLED     ", green
        elif state == SWITCHED_OFF:
            tag, col = "SWITCHED OFF", yellow
            off_n += 1
        elif state == AMBIGUOUS:
            tag, col = "AMBIGUOUS   ", red
            amb_n += 1
        else:
            tag, col = "MISSING     ", yellow
            miss_n += 1
        if fresh == STALE:
            stale_n += 1
        elif fresh == UNKNOWN:
            unknown_n += 1

        print("%s%s%s %-14s %s" % (col, tag, reset, art["name"], detail))
        if state == SWITCHED_OFF:
            print("     %soff since %s  (%s)%s"
                  % (dim, _mtime(live), os.path.basename(live), reset))
        elif state == AMBIGUOUS:
            print("     %sboth exist: %s (%s) is LIVE, and %s.off (%s) is a "
                  "stray. This is the fact-#156 shape -- a deploy re-created "
                  "the enabled dll beside an .off somebody switched off on "
                  "purpose, so the mod is loading again.%s"
                  % (dim, os.path.basename(dst), _mtime(dst),
                     os.path.basename(dst), _mtime(off_path(dst)), reset))
        elif state == MISSING:
            print("     %sneither %s nor %s.off is in the install%s"
                  % (dim, art["dst"], art["dst"], reset))

    extra = unmanaged_mods(install, select(cfg, None))
    if extra:
        print("\nmod directories in the install that no artifact declares "
              "(not deployed by this tool):")
        for name, (state, live) in extra:
            note = ("off since %s" % _mtime(live)) if state == SWITCHED_OFF \
                else state.lower()
            print("     %s%-14s %s%s" % (dim, name, note, reset))

    print("\n%d artifact(s): %d switched off, %d missing, %d ambiguous, "
          "%d stale, %d not comparable."
          % (len(arts), off_n, miss_n, amb_n, stale_n, unknown_n))
    if off_n:
        print("%sa switched-off mod does NOT load. `check` cannot see this -- "
              "its bytes are correct. Nothing here re-enables anything; "
              "`deploy --re-enable` does, one artifact at a time.%s"
              % (yellow, reset))
    if stale_n or amb_n:
        return 1
    if off_n or miss_n or unknown_n:
        return 3
    return 0


def _stamp(path):
    return time.strftime("%Y-%m-%d %H:%M:%S",
                         time.localtime(os.path.getmtime(path)))


IDENTICAL = "IDENTICAL"
DIFFERS = "DIFFERS"


def where_one(art, install, repo=None):
    """Everything locatable about ONE artifact. Returns (verdict, lines).

    Read-only and deliberately dumb: it states paths and bytes, it does not
    verify markers and it does not deploy. The verdict is only about the
    byte comparison of source vs installed file:

        IDENTICAL     both exist and hash the same
        DIFFERS       both exist and hash differently -- the install is not
                      running these bytes
        INCONCLUSIVE  one of them is not there, or could not be read, so the
                      comparison was never made. A source that is absent
                      while a BUILD IS IN PROGRESS says so, because "not
                      built" and "being rebuilt right now" send the reader to
                      do different things (and one of them is redundant).
    """
    repo = repo or REPO
    rel = art["src"]
    src = os.path.join(repo, rel.replace("/", os.sep))
    dst = os.path.join(install, art["dst"].replace("/", os.sep))
    state, live = live_state(dst)

    lines = ["  source      %s" % rel,
             "              %s" % src]
    src_ok = os.path.isfile(src)
    if src_ok:
        lines.append("              PRESENT  %d bytes  %s"
                     % (os.path.getsize(src), _stamp(src)))
    else:
        building = build_in_progress()
        if building:
            lines.append("              ABSENT -- a BUILD IS IN PROGRESS: %s"
                         % building)
            lines.append("              it is absent because it is being "
                         "rebuilt right now, not because it was never built.")
        else:
            lines.append("              ABSENT -- not built in this checkout")

    lines.append("  destination %s" % dst)
    if state == ENABLED:
        lines.append("              PRESENT  %d bytes  %s"
                     % (os.path.getsize(live), _stamp(live)))
    elif state == SWITCHED_OFF:
        lines.append("              the enabled path does NOT exist; the "
                     "install has this SWITCHED OFF as:")
        lines.append("              %s" % live)
        lines.append("              PRESENT  %d bytes  %s  -- a .off file "
                     "does not load" % (os.path.getsize(live), _stamp(live)))
    elif state == AMBIGUOUS:
        lines.append("              PRESENT  %d bytes  %s"
                     % (os.path.getsize(live), _stamp(live)))
        lines.append("              AMBIGUOUS: %s also exists (%d bytes, %s). "
                     "The enabled one is what loads."
                     % (off_path(dst), os.path.getsize(off_path(dst)),
                        _stamp(off_path(dst))))
    else:
        lines.append("              ABSENT -- neither %s nor %s.off is in "
                     "the install" % (art["dst"], art["dst"]))

    if not src_ok or live is None:
        lines.append("  identical   INCONCLUSIVE -- %s, so the two were never "
                     "compared. This is NOT evidence they differ."
                     % ("the source is absent" if not src_ok
                        else "there is nothing installed to compare against"))
        return INCONCLUSIVE, lines
    try:
        hs, hd = _sha(src), _sha(live)
    except OSError as e:
        lines.append("  identical   INCONCLUSIVE -- could not read one of "
                     "them: %s" % e)
        return INCONCLUSIVE, lines
    if hs == hd:
        lines.append("  identical   YES  sha256 %s (both)" % hs[:16])
        lines.append("              %s" % (
            "the installed file is switched OFF, so these bytes are current "
            "but NOT loading." if state == SWITCHED_OFF
            else "the install is running exactly these bytes."))
        return (INCONCLUSIVE if state == SWITCHED_OFF else OK), lines
    lines.append("  identical   NO   source  sha256 %s" % hs[:16])
    lines.append("                   install sha256 %s" % hd[:16])
    lines.append("              the install is NOT running the built bytes. "
                 "`deploy` is what fixes that (it verifies markers first).")
    return FAIL, lines


def cmd_where(args, cfg, C):
    """Print, per artifact, where it comes from and where it goes.

    This verb exists because the path was being GUESSED. `check` printed the
    source path only on its ok line, so an agent who guessed wrong got
    INCONCLUSIVE and no correction (measured twice, 2026-09-01). Nothing here
    writes, so it is safe to run against a live install at any time.
    """
    red, green, yellow, dim, reset = C
    install = args.install or cfg["install"]
    repo = os.path.abspath(args.repo) if args.repo else REPO
    arts = select(cfg, args.only)
    print("repo:    %s" % repo)
    print("install: %s%s" % (install,
                             "" if os.path.isdir(install)
                             else "   (this directory DOES NOT EXIST)"))
    bad = unknown = 0
    for art in arts:
        verdict, lines = where_one(art, install, repo)
        col, tag = ((green, IDENTICAL) if verdict == OK else
                    (red, DIFFERS) if verdict == FAIL else
                    (yellow, INCONCLUSIVE))
        if verdict == FAIL:
            bad += 1
        elif verdict != OK:
            unknown += 1
        print("\n%s%s%s  %s" % (col, tag, reset, art["name"]))
        for ln in lines:
            print(ln)
    print("\n%d artifact(s): %d differ, %d inconclusive."
          % (len(arts), bad, unknown))
    if bad:
        return 1
    return 3 if unknown else 0


def find_backups(install, art):
    dst = os.path.join(install, art["dst"].replace("/", os.sep))
    d = os.path.dirname(dst)
    base = os.path.basename(dst) + ".bak-"
    if not os.path.isdir(d):
        return dst, []
    got = [os.path.join(d, f) for f in os.listdir(d) if f.startswith(base)]
    got.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return dst, got


def cmd_rollback(args, cfg, C):
    red, green, yellow, dim, reset = C
    install = args.install or cfg["install"]
    arts = select(cfg, args.only)
    did = 0
    for art in arts:
        dst, baks = find_backups(install, art)
        if not baks:
            print("%-8s no backups beside %s" % (art["name"], dst))
            continue
        if not args.only:
            # No target named: this is the listing mode.
            print("%-8s %d backup(s), newest first:" % (art["name"], len(baks)))
            for b in baks[:5]:
                print("    %s  %s" % (
                    time.strftime("%Y-%m-%d %H:%M:%S",
                                  time.localtime(os.path.getmtime(b))),
                    os.path.basename(b)))
            continue
        shutil.copy2(baks[0], dst)
        did += 1
        print("%sok%s   %-8s restored %s" % (green, reset, art["name"],
                                             os.path.basename(baks[0])))
    if not args.only:
        print("\nname an artifact to actually restore, e.g. "
              "python tools/deploy.py rollback --only host")
    return 0


def cmd_stages(args, cfg, C):
    """`stages [NAME]` -- what is deployable, and what is live.

    NAME is matched against BOTH an artifact name from deploy.json and a stage
    target key, because those are two different vocabularies for the same
    thing (`host` happens to be both) and guessing which one the reader meant
    is how a listing comes back empty for a stage that exists. Which
    interpretation matched is printed.

    `DEPLOYED` compares the staged bytes with the INSTALLED file by sha, not
    by mtime -- a hand-copied file with a fresh mtime and stale bytes is a
    measured state in this repo, not a hypothetical one.
    """
    red, green, yellow, dim, reset = C
    install = args.install or cfg["install"]
    want = (args.target or args.only or "").strip()
    arts = [a for a in cfg["artifacts"] if not a["name"].startswith("//")]
    by_name = {a["name"]: a for a in arts}
    recs = stage.stages(REPO)
    if want:
        keys = {stage.target_key(want), want.lower()}
        art = by_name.get(want)
        sel = [r for r in recs
               if r["target_key"] in keys
               or (art and (r["artifact_src"] == art["src"]
                            or r["artifact"] == os.path.basename(art["src"])))
               or r["name"] == want]
        print("stages matching %r (as %s)"
              % (want, "an artifact name and a target key" if art
                 else "a target key"))
        recs = sel
    if not recs:
        print("NO STAGES%s. .stage/ is written by tools/buildlock.py after a "
              "successful build; nothing here means no build has been staged "
              "%s, NOT that a build failed."
              % ((" match %r" % want) if want else "",
                 "for that target" if want else "in this checkout"))
        return 3
    # What is live, per staged artifact, so DEPLOYED can be stated as a fact.
    live = {}
    for r in recs:
        art = None
        for a in arts:
            if a["src"] == r["artifact_src"] or                     os.path.basename(a["src"]) == r["artifact"]:
                art = a
                break
        if not art:
            continue
        d = os.path.join(install, art["dst"].replace("/", os.sep))
        if os.path.isfile(d):
            try:
                live[r["sha"]] = _sha(d)
            except OSError:
                pass
    for r in recs:
        flags = []
        if r["stale_sources"]:
            flags.append("STALE_SOURCES (never auto-selected)")
        if r.get("source_check") == "not-performed":
            flags.append("source-check NOT PERFORMED")
        got = live.get(r["sha"])
        if got is None:
            flags.append("live copy NOT COMPARED")
        elif got.lower() == r["sha256"].lower():
            flags.append("DEPLOYED")
        print("  %-10s %-12s %-19s git %-12s %s%s"
              % (r["target_key"], r["sha"], r["built_h"] or "?",
                 (r["git_head"] or "?")[:12], r["artifact"],
                 ("   [%s]" % ", ".join(flags)) if flags else ""))
    print("\ndeploy a specific one with: python tools/deploy.py deploy "
          "--only NAME --sha PREFIX")
    return 0


def main():
    p = argparse.ArgumentParser(
        description="verify, back up and deploy aowlspt build artifacts",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__)
    p.add_argument("command", choices=["check", "deploy", "rollback",
                                     "status", "where", "stages"])
    p.add_argument("target", nargs="?", default=None,
                   help="artifact name(s), comma separated; same as --only")
    p.add_argument("--only", default=None,
                   help="comma-separated artifact names (host,tarkov,backend,launch)")
    p.add_argument("--install", default=None, help="override the install directory")
    p.add_argument("--artifact", default=None, metavar="PATH",
                   help="check THIS file instead of the artifact's usual "
                        "src (for an undeployed build in a worktree, a "
                        "staging dir, or a downloaded binary). `check` only. "
                        "Skips the install-side data check, which does not "
                        "apply to a file that has not been deployed.")
    p.add_argument("--contains", action="append", default=None,
                   metavar="LITERAL",
                   help="`check` only, repeatable: additionally assert the "
                        "artifact's RAW BYTES contain this literal. Searched "
                        "as UTF-8 and UTF-16LE by default; the matching "
                        "encoding is reported. ADDITIVE to the marker check, "
                        "never a substitute for it. THREE outcomes, decided by "
                        "tools/markers.py: PASS on a contiguous match; FAIL "
                        "(exit 1) when a positive control DID match and almost "
                        "none of the literal survives as word-runs -- a real "
                        "removal; NO-MATCH / INCONCLUSIVE (exit 3) otherwise, "
                        "because a literal spanning a Nim `&` concatenation is "
                        "stored as separate rodata fragments and can never "
                        "match contiguously -- pick a substring inside ONE "
                        "source fragment.")
    p.add_argument("--absent", action="append", default=None,
                   metavar="LITERAL",
                   help="`check` only, repeatable: assert the literal is NOT "
                        "in the artifact's raw bytes. Same encoding rules as "
                        "--contains -- and the same limitation, in the more "
                        "dangerous direction: a literal is equally 'absent' "
                        "when it was merely assembled from fragments. Three "
                        "outcomes: FAIL if it is contiguously present (with "
                        "the byte offset); PASS if it is missing, MOST of it "
                        "is missing too, and a positive control DID match; "
                        "INCONCLUSIVE (exit 3) if most of the literal "
                        "survives as word-runs, or if no control matched.")
    p.add_argument("--control", action="append", default=None,
                   metavar="LITERAL",
                   help="`check` only, repeatable: a literal you KNOW is in "
                        "the artifact, used as the positive control that lets "
                        "an --absent check reach PASS. Without one, the "
                        "artifact's declared markers are tried; if none of "
                        "them match either, every --absent miss is "
                        "INCONCLUSIVE, because a search not shown to be "
                        "capable of finding anything cannot demonstrate a "
                        "removal.")
    p.add_argument("--encoding", default="any",
                   choices=["utf8", "utf16", "any"],
                   help="which encoding(s) --contains/--absent search "
                        "(default: any = UTF-8 and UTF-16LE)")
    p.add_argument("--repo", default=None, metavar="PATH",
                   help="`status`/`where` only: the checkout whose build "
                        "outputs the live files are compared against "
                        "(default: this one)")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--re-enable", action="store_true",
                   help="switch a mod back ON that the install had switched "
                        "off as <name>.dll.off. Without this, deploy refreshes "
                        "the .off file and LEAVES it off (fact #156).")
    p.add_argument("--no-selftest", action="store_true",
                   help="`deploy` only: skip the `selftests.py --fast` gate. "
                        "Prints a loud line saying nothing checked that this "
                        "repo's verifiers can still fail.")
    p.add_argument("--expect", default=None, metavar="SHA256",
                   help="`deploy` only, with a single --only artifact: refuse "
                        "unless the artifact's sha256 is exactly this. Use it "
                        "when you hashed a build in a worktree and want the "
                        "install to get THOSE bytes.")
    p.add_argument("--sha", default=None, metavar="PREFIX",
                   help="deploy THIS staged build (a sha256 prefix from "
                        "`stages`). Refuses if no such stage exists; it never "
                        "silently substitutes other bytes.")
    p.add_argument("--no-stage", action="store_true",
                   help="deploy from bin/ instead of .stage/. A build running "
                        "now can delete the file mid-copy -- that is the race "
                        "measured on 2026-09-04.")
    p.add_argument("--stage-only", action="store_true",
                   help="refuse rather than fall back to bin/ when a build "
                        "output has no usable stage.")
    p.add_argument("--no-color", action="store_true")
    args = p.parse_args()
    if args.target and not args.only:
        args.only = args.target

    C = _color(not args.no_color and sys.stdout.isatty())
    cfg = load_config()
    if (args.contains or args.absent
            or args.control) and args.command != "check":
        sys.exit("--contains/--absent/--control are only meaningful with "
                 "`check`.")
    if args.control and not (args.absent or args.contains):
        sys.exit("--control is the positive control for --contains/--absent; "
                 "it does nothing on its own. Use --contains to assert "
                 "presence, --absent to assert removal.")
    if (args.no_selftest or args.expect) and args.command != "deploy":
        sys.exit("--no-selftest/--expect are only meaningful with `deploy`.")
    if args.artifact and args.command != "check":
        sys.exit("--artifact is only meaningful with `check`: it verifies a "
                 "file in place and never copies anything.")
    if (args.sha or args.stage_only) and args.command != "deploy":
        sys.exit("--sha/--stage-only are only meaningful with `deploy`.")
    if args.command == "stages":
        return cmd_stages(args, cfg, C)
    if args.command == "status":
        return cmd_status(args, cfg, C)
    if args.command == "where":
        return cmd_where(args, cfg, C)
    if args.command == "check":
        return cmd_check(args, cfg, C)
    if args.command == "deploy":
        return cmd_deploy(args, cfg, C)
    return cmd_rollback(args, cfg, C)


if __name__ == "__main__":
    sys.exit(main())
