#!/usr/bin/env python3
"""storelint.py -- fail the build on a RAW store into game-owned memory.

INTERACTION-LAYER-MAP M3/M6, and WRITE-AUDIT section 5.4. The typed path
(`host/Aowlspt.Host.Il2Cpp/hostfieldwrite.nim` over the generated
`abi/aowlspt_fieldrefs.h`) is only worth anything if a new store site CANNOT be
written without it. A rule in a document cannot fail closed; this can.

WHAT IT FLAGS
=============
Two shapes, in `host/**.nim`, `mods/**.nim` and the `{.emit.}` C inside them:

  1. a call to one of the RAW write primitives (`cUxWritePtr`, `cNuSetRef`,
     `cDuWrite*`, `cBcWriteI32`, `cBaWriteU8`, `breWritePtr`, `aowlscene`'s
     `writeI32/writeF32/writeU8/writeBool`, ...). These take a bare offset and
     their only guard is readability -- a test that cannot fail on the IL2CPP
     GC heap.
  2. a raw pointer store in Nim: `cast[ptr T](x)[] = v`.

It does NOT parse the C inside `{.emit.}` blocks. That is a real gap and it is
stated rather than implied: a new raw store written directly in emitted C would
not be seen. What IS seen is the Nim call that reaches it, which is where a new
store site is actually added.

WHERE IT DOES NOT FLAG
======================
* `abi/aowlspt_hostwrite.h` and `hostfieldwrite.nim` / `hostwrite.nim` -- they
  ARE the gate; the raw store has to live somewhere.
* Anything under `.claude/worktrees/`, `nimcache/`, `bin/`, `build/`.
* A line carrying an explicit annotation:

      # storelint: allow HOST-OWNED -- <reason>

  The reason is mandatory and is printed by `--list`, so an exemption is a
  visible decision rather than a silent one. HOST-OWNED is the only legitimate
  category: a buffer this process allocated, never the managed heap.
* The BASELINE below: sites that are known, deliberate and documented. The
  baseline can only shrink -- `--check-baseline` FAILS if a baselined site has
  disappeared (so the file cannot rot) and any site NOT in it fails outright.

THREE OUTCOMES, NEVER TWO
=========================
  exit 0  CLEAN
  exit 6  FINDINGS -- a raw store outside the gate
  exit 3  INCONCLUSIVE -- the tree could not be scanned (missing dirs), or the
          scanned root is not the checkout the BASELINE was written for, so the
          baseline half of the check could not be performed.

FALSIFIER
=========
`python tools/storelint.py --falsify` copies the tree's rules over a synthetic
file containing one raw store and asserts the lint FAILS on it, then asserts it
PASSES on the same file with the annotation. A lint that has never been shown
to fire is not a lint.
"""

import os
import re
import shutil
import sys
import tempfile

_HERE = os.path.dirname(os.path.abspath(__file__))
_REPO = os.path.dirname(_HERE)

SCAN_DIRS = ["host", "mods"]
SKIP_PARTS = (os.sep + ".claude" + os.sep, os.sep + "nimcache" + os.sep,
              os.sep + "bin" + os.sep, os.sep + "build" + os.sep,
              os.sep + "worktrees" + os.sep, os.sep + "data" + os.sep)

# The files that ARE the gate. A raw store has to live somewhere.
GATE_FILES = {
    os.path.join("host", "Aowlspt.Host.Il2Cpp", "hostfieldwrite.nim"),
    os.path.join("host", "Aowlspt.Host.Il2Cpp", "hostwrite.nim"),
}

# RAW write primitives: each takes a bare offset (or a bare address) and is
# guarded, at best, by readability.
RAW_CALLS = [
    "cUxWritePtr", "cNuSetRef", "cDuWriteU8", "cDuWriteI32", "cDuWriteF32",
    "cDuWriteColor", "cBcWriteI32", "cBaWriteU8", "breWritePtr",
    "cInspWriteBytes", "cSwWritePtr", "cSwWriteU8", "fov_write_float",
    "fovWriteFloat",
]
RAW_CALL_RE = re.compile(r"\b(" + "|".join(RAW_CALLS) + r")\s*\(")

# `writeI32`/`writeF32`/`writeU8`/`writeBool` are aowlscene's; the bare names
# are common enough that they are matched only as a call with a pointer-ish
# first argument, and they are currently DEAD (WRITE-AUDIT section 1).
RAW_SCENE_RE = re.compile(r"\b(writeI32|writeF32|writeU8|writeBool)\s*\(")

# A raw Nim pointer store.
NIM_STORE_RE = re.compile(r"cast\[\s*ptr\s+[A-Za-z0-9_\[\]]+\s*\]\s*\([^)]*\)\s*\[\s*\]\s*=")

ALLOW_RE = re.compile(r"#\s*storelint:\s*allow\s+HOST-OWNED\s*--\s*(\S.*)")

# ---------------------------------------------------------------------------
# THE BASELINE. Every entry is a site that is known, deliberate and documented.
# It can only SHRINK: --check-baseline fails when an entry no longer matches,
# so a routed site cannot leave a permanent hole behind it.
#
#   (path, needle, why)
# ---------------------------------------------------------------------------
BASELINE = [
    (os.path.join("host", "Aowlspt.Host.Il2Cpp", "inspect.nim"),
     "cInspWriteBytes",
     "WRITE-AUDIT #10: the ONE deliberate escape hatch. Arbitrary address, "
     "arbitrary width, gated by liveInspectorWrite PLUS an `allow write` line "
     "in the batch, and it now prints the FieldRef verdict for any address a "
     "generated row can claim."),
    (os.path.join("host", "Aowlspt.Host.Il2Cpp", "settingswrite.nim"),
     "cUxWritePtr",
     "WRITE-AUDIT #6: TMP_Text.m_text through the raw pointer store. NOT YET "
     "ROUTED -- it is outside the scope of the M3/M6 pass and is listed here "
     "so it cannot be forgotten. The FieldRef (AOWL_FR_TMP_MTEXT) exists."),
    (os.path.join("host", "Aowlspt.Host.Il2Cpp", "settingswrite.nim"),
     "cDuWriteU8",
     "WRITE-AUDIT #7: TMP_Text.m_havePropertiesChanged. NOT YET ROUTED; the "
     "field type is INFERRED in the audit, never re-measured, so no FieldRef "
     "has been generated for it."),
    (os.path.join("host", "Aowlspt.Host.Il2Cpp", "invoke2.nim"),
     "cUxWritePtr",
     "WRITE-AUDIT #6, second site: same TMP_Text.m_text store. NOT YET ROUTED."),
    (os.path.join("host", "Aowlspt.Host.Il2Cpp", "postfxrows.nim"),
     "cNuSetRef",
     "FOUND BY THIS LINT, and ABSENT from the 12-site WRITE-AUDIT inventory: "
     "raw 8-byte reference stores into ScrollRect.content and the settings "
     "tab's root. NOT YET ROUTED -- no FieldRef has been generated for either "
     "field, so routing them would mean guessing a type. Reported, not fixed."),
]
# REMOVED 2026-09-04: (mods/fov/fov.nim, "fovWriteFloat") -- WRITE-AUDIT #12,
# CameraManager._fov. Its baseline reason was "the field type is INFERRED ...
# not from the field table, so no FieldRef has been generated for it". That was
# never re-measured, and it was false: `python tools/fldoff.py fields
# EFT.CameraControl.CameraManager` reports `0xf8  _fov  float  private`, so
# tools/fieldrefs.py generates AOWL_FR_CM_FOV (off=0xf8 w=4 ref=0) and the site
# now goes through `aowl_fr_store_f32`. The baseline SHRANK, which is the only
# direction it may move. `fovWriteFloat` itself is retained in GATE_HELPERS
# above only for this module's own host-owned scratch.


# ---------------------------------------------------------------------------
# WHICH TREE THE BASELINE BELONGS TO.
#
# `audit(root)` is called by buildlock with an arbitrary root -- a worktree, or
# in the tests a synthetic temp repo. The BASELINE above is a statement about
# THIS checkout's source files. Against any other tree every entry reads GONE,
# and "the baseline has rotted" was returned as a FAIL: a confidently wrong
# answer about a tree the baseline never described, naming real-checkout paths
# that do not exist under the scanned root.
#
# So the baseline carries the identity of the tree it was written for. Rot is a
# FAIL only when the scanned root IS that tree; anywhere else it is
# INCONCLUSIVE with the reason stated. Findings themselves are still real
# everywhere -- a raw store is a raw store -- and are always named relative to
# the SCANNED root.
#
# Identity is by marker file rather than by git: a temp repo can be a git repo,
# and a worktree of this checkout is legitimately the same tree, which is
# exactly the "same source, different directory" case the baseline still
# describes.
# ---------------------------------------------------------------------------
BASELINE_ROOT_MARKERS = tuple(sorted(GATE_FILES)) + (
    os.path.join("host", "Aowlspt.Host.Il2Cpp", "inspect.nim"),
    os.path.join("tools", "storelint.py"),
)


def baseline_owner_missing(root):
    """-> [] when `root` is the tree the BASELINE was written for.

    Otherwise the marker paths that are absent, which is what the refusal
    prints. Deliberately checks several markers: one file could plausibly be
    copied into an unrelated tree; four is the checkout.
    """
    return [m for m in BASELINE_ROOT_MARKERS
            if not os.path.isfile(os.path.join(root, m))]


def rel(p):
    return os.path.relpath(p, _REPO)


def iter_files():
    for d in SCAN_DIRS:
        root = os.path.join(_REPO, d)
        if not os.path.isdir(root):
            return None
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [x for x in dirnames
                           if x not in ("nimcache", "bin", "build", "data",
                                        ".claude", "worktrees")]
            low = dirpath.lower() + os.sep
            if any(s in low for s in SKIP_PARTS):
                continue
            for fn in filenames:
                if fn.endswith(".nim"):
                    yield os.path.join(dirpath, fn)
    return True


def scan_text(path, text):
    """-> list of (lineno, kind, line). Pure text, no build required."""
    hits = []
    r = rel(path).replace("/", os.sep)
    if r in GATE_FILES:
        return hits
    for i, line in enumerate(text.split("\n"), 1):
        stripped = line.strip()
        if stripped.startswith("#") or stripped.startswith("##"):
            continue
        # An `importc` DECLARATION of a primitive is not a store. Flagging it
        # would make every finding permanent and unfixable, which is how a
        # lint gets switched off. The CALL SITES are what matter.
        if stripped.startswith("proc ") or stripped.startswith("func "):
            continue
        # Likewise a C function DEFINITION inside an {.emit.} block: the raw
        # store inside such a helper is the helper's job. What this lint is
        # about is who CALLS it.
        if stripped.startswith("static ") and stripped.endswith("{"):
            continue
        if ALLOW_RE.search(line):
            continue
        kind = None
        if RAW_CALL_RE.search(line):
            kind = "raw-write-primitive"
        elif RAW_SCENE_RE.search(line) and "cast[" in line:
            kind = "raw-write-primitive"
        elif NIM_STORE_RE.search(line):
            kind = "raw-nim-pointer-store"
        if kind:
            hits.append((i, kind, stripped))
    return hits


def baselined(path, line):
    r = rel(path).replace("/", os.sep)
    for bp, needle, _why in BASELINE:
        if r == bp and needle in line:
            return True
    return False


def run(verbose=False):
    files = list(iter_files() or [])
    if not files:
        print("INCONCLUSIVE: nothing to scan -- %s not found under %s" %
              (", ".join(SCAN_DIRS), _REPO))
        return 3
    findings = []
    seen_baseline = set()
    for f in files:
        try:
            with open(f, "rb") as fh:
                text = fh.read().decode("utf-8", errors="replace")
        except OSError as e:
            print("INCONCLUSIVE: could not read %s: %s" % (rel(f), e))
            return 3
        for ln, kind, line in scan_text(f, text):
            if baselined(f, line):
                r = rel(f).replace("/", os.sep)
                for bp, needle, _w in BASELINE:
                    if r == bp and needle in line:
                        seen_baseline.add((bp, needle))
                continue
            findings.append((rel(f), ln, kind, line))

    owner_missing = baseline_owner_missing(_REPO)

    if verbose:
        print("storelint: scanned %d nim file(s) under %s" %
              (len(files), ", ".join(SCAN_DIRS)))
        if owner_missing:
            print("  baseline NOT APPLICABLE to this root -- its entries "
                  "describe files that are not part of the scanned tree, so "
                  "they are not listed here.")
        else:
            for bp, needle, why in BASELINE:
                state = "present" if (bp, needle) in seen_baseline else "GONE"
                print("  baseline %-8s %s :: %s" % (state, bp, needle))
                print("           %s" % why)

    if findings:
        print("STORELINT FINDINGS: %d raw store(s) into game-owned memory "
              "outside the typed path." % len(findings))
        print("The typed path is `frStore*` / `frRecvOk` in "
              "host/Aowlspt.Host.Il2Cpp/hostfieldwrite.nim, over a FieldRef "
              "generated by tools/fieldrefs.py. A bare offset guarded by "
              "readability is not a guard: on the IL2CPP GC heap that test "
              "cannot fail (INTERACTION-LAYER-MAP M6).")
        for f, ln, kind, line in findings:
            print("  %s:%d  [%s]" % (f, ln, kind))
            print("      %s" % line[:160])
        print("If the memory is HOST-OWNED, annotate the line:")
        print("      # storelint: allow HOST-OWNED -- <reason>")
        return 6

    missing = [(bp, n, w) for bp, n, w in BASELINE
               if (bp, n) not in seen_baseline]
    if missing and owner_missing:
        print("storelint: INCONCLUSIVE -- the baseline belongs to the aowlspt "
              "checkout, and the scanned root is %s, which is not it. %d "
              "baseline entry(ies) do not match anything here; that is "
              "expected of a different tree and is NOT evidence of rot. The "
              "baseline was NOT checked." % (_REPO, len(missing)))
        print("  missing identity marker(s) under the scanned root: %s"
              % ", ".join(owner_missing))
        print("  %d nim file(s) WERE scanned for raw stores and none was "
              "found; only the baseline half is inconclusive." % len(files))
        return 3
    if missing:
        print("STORELINT: the baseline has rotted -- %d entry(ies) no longer "
              "match anything in the tree. Delete them; a baseline that lists "
              "sites which no longer exist is a hole with no owner." %
              len(missing))
        for bp, n, w in missing:
            print("  GONE  %s :: %s" % (bp, n))
        return 6

    print("storelint: CLEAN -- %d nim file(s), no raw store into game-owned "
          "memory outside hostfieldwrite.nim/hostwrite.nim and the %d "
          "documented baseline site(s)." % (len(files), len(BASELINE)))
    return 0


FALSIFY_BAD = '''proc synthetic(p: Il2CppPtr) =
  discard cUxWritePtr(p, 0x10'i32, cast[Il2CppPtr](0))
'''
FALSIFY_OK = '''proc synthetic(p: Il2CppPtr) =
  discard cUxWritePtr(p, 0x10'i32, cast[Il2CppPtr](0))  # storelint: allow HOST-OWNED -- synthetic
'''


def _falsify_baseline_scope():
    """The baseline-scope rule, and its falsifier.

    Two worlds, and BOTH have to come out the stated way or the rule is either
    a check that cannot fail or a check that fires on the wrong tree:

      A. a foreign root (a synthetic tree with a .nim under host/, exactly what
         tools/test_buildlock.py builds) -> INCONCLUSIVE, never FAIL, and the
         message must not name a real-checkout path.
      B. THE REAL ROOT with a baseline entry that matches nothing -> still
         FAIL. If B passed, the whole scope rule would be a way of never
         failing.
    """
    global BASELINE
    out = []
    tmp = tempfile.mkdtemp(prefix="storelint-falsify-")
    try:
        d = os.path.join(tmp, "host", "Aowlspt.Host.Il2Cpp")
        os.makedirs(d)
        with open(os.path.join(d, "hostmain.nim"), "w", newline="\n") as fh:
            fh.write("proc main() =\n  discard\n")
        os.makedirs(os.path.join(tmp, "mods"))
        rc = audit(tmp, quiet=False)
        if rc != INCONCLUSIVE:
            out.append("world A: a foreign tree returned %d, expected "
                       "INCONCLUSIVE (%d). A baseline written for another "
                       "checkout must not read as rot here."
                       % (rc, INCONCLUSIVE))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    # World B: the real root, with a deliberately rotten entry.
    saved = BASELINE
    try:
        BASELINE = list(saved) + [
            (os.path.join("host", "Aowlspt.Host.Il2Cpp", "hostmain.nim"),
             "cThisPrimitiveDoesNotExist",
             "synthetic falsifier entry -- must read as rot in THIS tree")]
        rc = audit(_REPO, quiet=True)
        if rc != FAIL:
            out.append("world B: the real checkout with a rotted baseline "
                       "entry returned %d, expected FAIL (%d). The scope rule "
                       "would then be a check that cannot fail."
                       % (rc, FAIL))
    finally:
        BASELINE = saved
    return out


def falsify():
    """A lint that has never been shown to fire is not a lint."""
    fake = os.path.join(_REPO, "host", "Aowlspt.Host.Il2Cpp", "_falsify.nim")
    bad = scan_text(fake, FALSIFY_BAD)
    ok = scan_text(fake, FALSIFY_OK)
    gate = scan_text(os.path.join(_REPO, "host", "Aowlspt.Host.Il2Cpp",
                                  "hostfieldwrite.nim"), FALSIFY_BAD)
    fails = []
    if len(bad) != 1:
        fails.append("a raw cUxWritePtr store was NOT flagged (got %d hits)" %
                     len(bad))
    if ok:
        fails.append("the HOST-OWNED annotation did not silence the finding "
                     "(got %d hits) -- an exemption that does not work means "
                     "every legitimate site becomes a permanent finding" %
                     len(ok))
    if gate:
        fails.append("the gate file itself was flagged (%d hits) -- the raw "
                     "store has to live somewhere" % len(gate))
    fails.extend(_falsify_baseline_scope())

    if fails:
        print("FALSIFIER FAILED -- this lint cannot be trusted:")
        for m in fails:
            print("  " + m)
        return 6
    print("storelint falsifier: PASS -- the lint fires on a synthetic raw "
          "store, stays silent on the annotated one, and exempts the gate.")
    return 0


# ---------------------------------------------------------------------------
# The buildlock pre-flight interface (`invariant_preflight` in
# tools/buildlock.py): a module with `audit(repo, **kw)` and the three-state
# constants. Refused BEFORE the lock is taken, so a build that must not ship
# does not first spend the queue and then hold the one serial resource.
#
# INCONCLUSIVE never refuses. "I could not look" must not read as a pass, and a
# gate that blocks on a machine missing an input becomes the flag everyone
# passes.
# ---------------------------------------------------------------------------
PASS, FAIL, INCONCLUSIVE = 0, 1, 3


def audit(root, quiet=False):
    global _REPO
    old = _REPO
    try:
        _REPO = root
        rc = run(verbose=not quiet)
    finally:
        _REPO = old
    if rc == 3:
        return INCONCLUSIVE
    if rc == 0:
        return PASS
    print("FAIL -- M3/M6: a raw store into game-owned memory outside the "
          "typed path (see the finding list above).")
    return FAIL


def main():
    a = sys.argv[1:]
    if "--falsify" in a:
        return falsify()
    if "--list" in a or "-v" in a or "--verbose" in a:
        return run(verbose=True)
    return run()


if __name__ == "__main__":
    sys.exit(main())
