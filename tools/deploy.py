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
    python tools/deploy.py rollback              # list restorable backups
    python tools/deploy.py rollback host         # restore host's newest backup

`--install PATH` overrides the destination from `deploy.json`.

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
import shutil
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
CONFIG = os.path.join(HERE, "deploy.json")

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


OK = "ok"
FAIL = "fail"
INCONCLUSIVE = "inconclusive"


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
    for m in art.get("markers", []):
        # The host writes its log text as plain bytes; markers are ASCII
        # literals. Search the raw bytes so this works on a DLL, an EXE or
        # anything else, with no assumption about encoding or sections.
        if blob.find(m.encode("utf-8")) < 0:
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
    bad = 0
    unknown = 0
    for art in arts:
        src = (override if override
               else os.path.join(REPO, art["src"].replace("/", os.sep)))
        verdict, problems = verify(art, src, C)
        if verdict == OK and check_data:
            dverdict, dproblems = verify_data(art, install, C)
            if dverdict != OK:
                verdict, problems = dverdict, dproblems
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
        if verdict == INCONCLUSIVE:
            unknown += 1
            print("%sINCONCLUSIVE%s %-8s %s"
                  % (yellow, reset, art["name"], art["src"]))
        else:
            bad += 1
            print("%sFAIL%s %-8s %s" % (red, reset, art["name"], art["src"]))
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
              "export table could not be read.%s" % (yellow, unknown, reset))
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

    if not os.path.isdir(install):
        sys.exit("install directory does not exist: %s" % install)

    print("\ninstall %s" % install)
    rollbacks = []
    for art in arts:
        src = os.path.join(REPO, art["src"].replace("/", os.sep))
        dst = os.path.join(install, art["dst"].replace("/", os.sep))
        if args.dry_run:
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
                                for a in arts):
        # THE POST-CONDITION. Not a restatement of the copy above: it re-reads
        # the install and hashes what is actually there. A deploy that copied
        # and still does not hold the right bytes must not print success.
        print("\nverifying the install now holds the declared data:")
        post_bad = 0
        post_unknown = 0
        for art in arts:
            if not art.get("data") and not art.get("verifyInstalled"):
                continue
            v, probs = verify_data(art, install, C)
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


def main():
    p = argparse.ArgumentParser(
        description="verify, back up and deploy aowlspt build artifacts",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__)
    p.add_argument("command", choices=["check", "deploy", "rollback"])
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
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--no-color", action="store_true")
    args = p.parse_args()
    if args.target and not args.only:
        args.only = args.target

    C = _color(not args.no_color and sys.stdout.isatty())
    cfg = load_config()
    if args.artifact and args.command != "check":
        sys.exit("--artifact is only meaningful with `check`: it verifies a "
                 "file in place and never copies anything.")
    if args.command == "check":
        return cmd_check(args, cfg, C)
    if args.command == "deploy":
        return cmd_deploy(args, cfg, C)
    return cmd_rollback(args, cfg, C)


if __name__ == "__main__":
    sys.exit(main())
