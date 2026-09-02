#!/usr/bin/env python3
r"""selftests.py -- run every self-test in this repo, and prove every verifier
can fail.

    python tools/selftests.py              # --fast (default), ~45 s
    python tools/selftests.py --all        # everything, including the slow set
    python tools/selftests.py --list       # the registry, run nothing
    python tools/selftests.py --falsifiers # the falsifier audit only

## Why this exists

On 2026-09-01 six separate verifiers reported PASS on state that was visibly
wrong, because none of their checks could fail:

  * `nativetabs_check` accepted a FAIL verdict as "geometry unchanged";
  * `acceptance.py` read an `echo` as geometry and `activeInHierarchy` as `isOn`;
  * the maps draw check FAILed at the menu, which only meant "not in a raid";
  * a row relabel re-read its own write and called that a readback;
  * the backend selftest asserted with substring `contains`, so a payload that
    was not JSON at all passed;
  * `--phase-max` bounded nothing.

Each of those got a self-test AFTER the fact. Nothing ran them all, and nothing
gated a deploy on them -- so when this runner was first pointed at the tree it
found SIX self-tests already red that no one knew about. A self-test nobody runs
is documentation.

## Three outcomes, never two

PASS / FAIL / INCONCLUSIVE. INCONCLUSIVE means the item COULD NOT RUN -- a
missing input, a missing build, a timeout. It is never folded into PASS, and it
is never folded into FAIL either, because "I could not look" is a different
fact from "I looked and it was wrong" (CLAUDE.md 9b).

`--fast` exits 0 only if every fast item PASSED. An INCONCLUSIVE fast item is a
non-zero exit, with one exception that is stated in the table: an item whose
declared `needs` are absent is reported SKIP(needs) and excluded, because the
input genuinely is not on this machine and that is not the runner's finding to
make. Every skip is printed with the path that was missing.

## The falsifier registry

A verifier ships with its falsifier or this runner fails. `VERIFIERS` below
lists every tool in `tools/` that emits a verdict, each with the negative
control that makes its FAIL fire and a `proof` string saying where that control
lives. Three states:

  * `falsifier` names a registry item  -> audited, and that item is run
  * `gap` gives a reason               -> KNOWN DEBT: printed every single run,
                                          counted as a runner FAIL under
                                          `--strict` and `--all`, a loud NOTE
                                          under `--fast`
  * neither, or not in the registry    -> UNTRIAGED: a hard FAIL in every mode

That asymmetry is deliberate and is the only judgement call in this file. Debt
that already exists is enumerated so it cannot hide; debt that is NEW cannot be
added at all, because a tool that starts printing verdicts and is not in this
registry fails the runner immediately. A gate that refused every deploy on day
one would simply be routed around with `--no-selftest`, which is the outcome
this whole file exists to prevent.
"""

from __future__ import annotations

import argparse
import glob
import hashlib
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
CACHE = os.path.join(REPO, ".aowl-selftests.json")

PASS, FAIL, INCONCLUSIVE, SKIP = "PASS", "FAIL", "INCONCLUSIVE", "SKIP"

# Inputs that several items need and that are NOT in the repo. An item that
# declares one of these and does not find it is SKIP(needs), never PASS.
GAMEASM = r"D:\Games\Tarkov\GameAssembly.dll"
METADEC = os.path.join(REPO, ".cache", "global-metadata.dec.dat")


# --------------------------------------------------------------------------
# The item registry.
#
# `speed` is a MEASURED class, not an aspiration -- the seconds in the comments
# were timed in this checkout on 2026-09-02. fast: the whole fast set is under
# ~60 s serial. slow: anything above ~10 s, plus anything that blocks.
#
# `args` are the arguments the item genuinely requires. Three tests here were
# reported red for months by anyone who ran them bare; they were not red, they
# were being run without the two paths every resolver verb takes first.
# --------------------------------------------------------------------------

def T(name, speed, args=(), needs=(), note=""):
    """A `tools/test_*.py` item."""
    return {"name": name, "kind": "test", "cmd": [sys.executable,
            os.path.join(HERE, name)] + list(args), "speed": speed,
            "needs": list(needs), "note": note}


def S(name, speed, args=("--selftest",), needs=(), note="", label=None):
    """A tool exposing a self-test."""
    return {"name": label or ("%s %s" % (name, " ".join(args))).strip(),
            "kind": "selftest",
            "cmd": [sys.executable, os.path.join(HERE, name)] + list(args),
            "speed": speed, "needs": list(needs), "note": note}


ITEMS = [
    # ---- fast tests -------------------------------------------------------
    # NOT fast, however fast it looks. It runs `aowl` through
    # `buildlock.py --wait 1800`, so it is 2.2 s when the build slot is free
    # and up to THIRTY MINUTES when another agent holds it. Measured on
    # 2026-09-02: it queued behind a `build host` that had been running 725 s.
    # An item in the deploy gate that blocks on the one genuinely serial
    # resource in this repo would make the gate the reason deploys hang.
    T("test_aowlbuild.py", "slow",
      note="waits on the build lock: 2s free, up to 30 min contended"),
    T("test_autoenter.py", "fast"),                    # 0.8s
    T("test_crashwatch.py", "fast"),                   # 12.1s
    T("test_deploy_contains.py", "fast"),              # 1.5s
    T("test_hostlog.py", "fast"),                      # 6.4s
    T("test_inspect_silence.py", "fast"),              # 0.1s
    T("test_modbuild_diag.py", "fast"),                # 0.1s
    T("test_modbuild_failcache.py", "fast"),           # 0.1s
    T("test_modloadfmt.py", "fast"),                   # 0.1s
    T("test_popups_classify.py", "fast"),              # 0.1s
    T("test_raidprof.py", "fast"),                     # 0.6s
    T("test_startup_race.py", "fast"),                 # 4.2s
    T("test_supervise.py", "fast"),                    # 5.7s
    T("test_deploy.py", "fast"),                       # the gate's own tests

    # ---- fast self-tests --------------------------------------------------
    S("botaudit.py", "fast"),                          # 0.1s
    S("crashwatch.py", "fast"),                        # 0.9s
    S("entergame.py", "fast"),                         # 0.1s
    S("exitraid.py", "fast"),                          # 3.1s
    S("hostcfg.py", "fast"),                           # 0.2s
    S("inspector.py", "fast"),                         # 0.9s
    S("irepl.py", "fast"),                             # 0.5s
    S("markers.py", "fast"),                           # 0.5s
    S("modharness.py", "fast"),                        # 0.6s
    S("offscreen.py", "fast"),                         # 1.7s
    S("shapeaudit.py", "fast"),                        # 0.1s
    S("nimlint.py", "fast"),                           # 0.1s
    S("acceptance.py", "fast", args=("selftest",)),    # 0.2s -- positional
    S("nativetabs_check.py", "fast", args=("selftest",)),
    S("uihooks_check.py", "fast", args=("selftest",)),

    # ---- falsifiers (negative controls) that are themselves items ---------
    S("irepl_mutation.py", "fast", args=(),
      note="proves irepl.py --selftest CAN fail"),
    T("test_markers_falsifier.py", "fast",
      note="proves markers.py cannot answer PRESENT to everything"),
    T("test_hostcfg_falsifier.py", "fast",
      note="proves hostcfg.py --selftest CAN fail"),
    T("test_uihooks_falsifier.py", "fast",
      note="proves uihooks_check selftest CAN fail"),

    # ---- slow -------------------------------------------------------------
    T("test_buildlock.py", "slow", note="spawns real lock contenders; >90s"),
    T("test_il2cpp_callers.py", "slow"),               # 18.0s
    T("test_il2cpp_disasm.py", "slow"),                # 12.6s
    T("test_il2cpp_symbolize.py", "slow"),             # 12.4s
    T("test_fldoff_generics.py", "slow", args=(GAMEASM, METADEC),
      needs=(GAMEASM, METADEC)),                       # 28s
    T("test_resolver_flags.py", "slow", args=(GAMEASM, METADEC),
      needs=(GAMEASM, METADEC)),                       # 22s
    T("test_resolver_shared.py", "slow", args=(GAMEASM, METADEC),
      needs=(GAMEASM, METADEC)),                       # 16s
    S("enterraid.py", "slow",
      note="blocks past 90s in this checkout -- see the findings"),
    S("dtotype.py", "slow", args=("--selftest", "--manifest"),
      needs=("<dtotype manifest>",),
      note="refuses without --manifest; no manifest is checked in"),

    # ---- items that are NOT python, and cannot run without a build --------
    {"name": "mods/tarkov/emu/seasoncheck.nim", "kind": "nim", "cmd": None,
     "speed": "slow", "needs": ("a built emutest binary",),
     "note": "Nim; reachable only via `aowl build emutest`. Always "
             "INCONCLUSIVE from this runner -- never PASS."},
]

# `--selftest` appears in these files only as prose, or as a flag the tool does
# not actually define. Listed so discovery does not report them as drift every
# run, and so the reason survives.
NOT_ITEMS = {
    "bc1.py": "mentions maptiles.py --selftest in a comment; defines none",
    "headless.py": "documents `aowlspt-backend --selftest`, a Nim binary; the "
                   "python wrapper defines no such flag (argparse rejects it)",
}


# --------------------------------------------------------------------------
# The falsifier registry.
#
# Every tool in tools/ that emits a verdict must appear here. `proof` says
# WHERE the negative control lives, in words rather than line numbers, because
# line numbers rot and a rotted proof reads as a valid one.
# --------------------------------------------------------------------------

def V(tool, falsifier=None, proof="", gap="", reason=""):
    return {"tool": tool, "falsifier": falsifier, "proof": proof,
            "gap": gap, "reason": reason}


VERIFIERS = [
    # ---- audited: a registered negative control exists ---------------------
    V("irepl.py", "irepl_mutation.py",
      "injects the 3-state->2-state collapse into modctl.classify and asserts "
      "irepl.selftest() goes red"),
    V("modctl.py", "irepl_mutation.py",
      "the mutation is applied to modctl.classify itself"),
    V("deploy.py", "test_deploy_contains.py",
      "case 4 (--absent must FAIL when the literal is still present), case 6 "
      "(a failing --contains must make an otherwise-ok artifact FAIL), and the "
      "new ARTIFACT REPLACED / selftest-gate refusals in test_deploy.py"),
    V("run.py", "test_supervise.py",
      "drives the real Supervisor against synthetic logs; three NEGATIVE cases "
      "assert STALLED does NOT fire on changing phases and that heartbeats do "
      "not refresh the progress clock"),
    V("crashwatch.py", "test_crashwatch.py",
      "replays measured Crash_* reports and asserts the attribution line is "
      "absent when the module cannot be named"),
    V("il2cpp_resolve.py", "test_resolver_shared.py",
      "asserts sharedness answers unknown (not 'unique') for an address that "
      "is not in the methodPointers histogram -- the .get(rva,1) bug"),
    V("markers.py", "test_markers_falsifier.py",
      "asserts MISSING for an absent literal and INCONCLUSIVE for a truncated "
      "read, so PRESENT is not the only reachable answer"),
    V("hostcfg.py", "test_hostcfg_falsifier.py",
      "breaks the key table and asserts hostcfg's own --selftest goes red"),
    V("uihooks_check.py", "test_uihooks_falsifier.py",
      "feeds a per-frame action trail and asserts FAIL, so PASS is not the "
      "only reachable verdict"),
    V("nativetabs_check.py", "nativetabs_check.py selftest",
      "self-test case 4 is the negative control: changed geometry must make "
      "the comparison FAIL. This is the check that once accepted a FAIL "
      "verdict string as 'geometry unchanged'"),
    V("acceptance.py", "acceptance.py selftest",
      "offline replay of measured inspector prose; the falsifying inputs are "
      "an echo standing in for geometry and activeInHierarchy standing in for "
      "isOn -- the two 2026-09-01 vacuous passes"),
    V("modharness.py", "modharness.py --selftest",
      "tests/modharness_bad is a mod built to fault; the harness FAILs naming "
      "the phase, and reports INCONCLUSIVE rather than PASS when that control "
      "is not built"),
    V("botaudit.py", "botaudit.py --selftest",
      "drives the audit against a synthetic memory image with the bad case "
      "planted"),
    V("offscreen.py", "offscreen.py --selftest",
      "creates a real window and checks the detector against it; states "
      "explicitly that it says nothing about the client"),
    V("entergame.py", "entergame.py --selftest",
      "offline; presses nothing and asserts the refusal paths"),
    V("exitraid.py", "exitraid.py --selftest"),
    V("shapeaudit.py", "shapeaudit.py --selftest"),

    # ---- KNOWN DEBT: a verifier with no negative control yet ---------------
    # Each of these needs a fixture the runner cannot synthesise in <30 lines.
    V("buildlock.py", gap="under active edit by another agent as of "
      "2026-09-02; tools/test_buildlock.py exercises it but is SLOW (>90 s, "
      "it spawns real lock contenders) so it is not in the fast gate. Wire "
      "its negative controls in once that work lands."),
    V("nimlint.py", gap="under active edit by another agent as of 2026-09-02; "
      "no test_nimlint.py exists yet"),
    V("headless.py", gap="a wrapper around the Nim backend's own --selftest; "
      "falsifying it needs a built aowlspt-backend.exe, which this runner "
      "must not build"),
    V("enterraid.py", gap="its --selftest blocks past 90 s in this checkout "
      "(see findings); falsifying it needs the hang diagnosed first"),
    V("betacheck.py", gap="needs a synthetic db.json + locale fixture pair"),
    V("bossalive.py", gap="reads live raid state; needs an inspector fixture"),
    V("botdigest.py", gap="needs a captured bot-log fixture"),
    V("catchcaption.py", gap="needs a live caption stream fixture"),
    V("dtotype.py", gap="its --selftest refuses without --manifest and no "
      "manifest is checked in -- so today it cannot even PASS, let alone fail"),
    V("dtogap.py", gap="needs a DTO corpus fixture"),
    V("emptygap.py", gap="needs a DTO corpus fixture"),
    V("factimport.py", gap="needs a facts.db fixture"),
    V("fieldshape.py", gap="needs GameAssembly + metadata; belongs with the "
      "resolver suite"),
    V("harness.py", gap="drives the live client end to end"),
    V("idxbind.py", gap="needs a live index"),
    V("il2cpp_gatevalidate.py", gap="needs GameAssembly; probe-driven"),
    V("il2cpp_symtab.py", gap="needs GameAssembly"),
    V("itemrefs.py", gap="needs db.json (41 MB, one line)"),
    V("litscan.py", gap="covered indirectly by test_deploy_contains.py, but "
      "has no direct negative control of its own"),
    V("lootscene.py", gap="needs a Unity scene fixture"),
    V("mapextract.py", gap="needs a Unity bundle fixture"),
    V("mapextract_terrain.py", gap="needs a Unity bundle fixture"),
    V("maptiles.py", gap="documents a measured max/mean error self-test that "
      "is not wired to a flag here"),
    V("oursample.py", gap="needs a wire capture fixture"),
    V("profiledupcheck.py", gap="needs a profile fixture"),
    V("relayexport.py", gap="needs a relay fixture"),
    V("routeproof.py", gap="needs a running backend"),
    V("settingsdump.py", gap="needs a live client"),
    V("settingstree.py", gap="needs a live client"),
    V("skillstill.py", gap="needs a live client"),
    V("sptsettings_check.py", gap="needs a running backend"),
    V("xferproof.py", gap="needs a running backend"),
    V("acceptance_admintrader.py", gap="needs a running backend + live client"),
    V("inspectfixtures.py", reason="a fixture LIBRARY, not a verifier -- it "
      "carries the measured inspector prose the other self-tests replay. It "
      "is exercised by every fixture-driven item above."),
    V("inspector.py", "inspector.py --selftest",
      "replays measured inspector prose including the silence case; "
      "test_inspect_silence.py additionally asserts the suite can DISTINGUISH "
      "a broken HEAD from a fixed one and goes red when it cannot"),
]


# --------------------------------------------------------------------------
# Discovery -- so the registry cannot silently drift from the tree.
# --------------------------------------------------------------------------

def discover_selftest_tools():
    """Tools whose source mentions `--selftest`, by grep, as the task asks."""
    found = []
    for p in sorted(glob.glob(os.path.join(HERE, "*.py"))):
        base = os.path.basename(p)
        if base.startswith("test_"):
            continue
        try:
            with open(p, "r", encoding="utf-8", errors="replace") as f:
                src = f.read()
        except OSError:
            continue
        # `--selftest` ONLY. An earlier version also matched the bare string
        # "selftest" anywhere in the source, which reported eight tools as
        # registry drift every run for merely mentioning the word -- drift
        # noise that is always on trains the reader to ignore it, which is the
        # same failure as a check that never fires.
        if "--selftest" in src:
            found.append(base)
    return found


# Tools whose self-test is a POSITIONAL command rather than a flag, so the
# `--selftest` grep cannot see them. They are registry items; this set stops
# the drift check from also demanding a flag they do not have.
POSITIONAL_SELFTEST = {"acceptance.py", "nativetabs_check.py",
                       "uihooks_check.py"}


def discover_tests():
    return sorted(os.path.basename(p)
                  for p in glob.glob(os.path.join(HERE, "test_*.py")))


VERDICT_RE = re.compile(r"VERDICT")


def discover_verifiers():
    """Every tool that emits a verdict.

    The signature is deliberately mechanical: it says VERDICT, or it can say
    both INCONCLUSIVE and PASS. A tool that starts printing verdicts is
    therefore picked up WITHOUT anyone remembering to add it here.
    """
    found = []
    for p in sorted(glob.glob(os.path.join(HERE, "*.py"))):
        base = os.path.basename(p)
        if base.startswith("test_") or base == "selftests.py":
            continue
        try:
            with open(p, "r", encoding="utf-8", errors="replace") as f:
                src = f.read()
        except OSError:
            continue
        if VERDICT_RE.search(src) or ("INCONCLUSIVE" in src
                                      and re.search(r"\bPASS\b", src)):
            found.append(base)
    return found


# --------------------------------------------------------------------------
# Running
# --------------------------------------------------------------------------

TIMEOUT = {"fast": 120, "slow": 900}


def missing_needs(item):
    out = []
    for n in item["needs"]:
        if n.startswith("<") or not os.path.isabs(n):
            # A described need, not a path -- e.g. "a built emutest binary".
            if not os.path.exists(os.path.join(REPO, n)):
                out.append(n)
        elif not os.path.exists(n):
            out.append(n)
    return out


def run_item(item, verbose=False):
    """-> (status, seconds, detail). Never returns PASS for something unrun."""
    miss = missing_needs(item)
    if miss:
        return SKIP, 0.0, "needs " + ", ".join(miss)
    if item["cmd"] is None:
        return INCONCLUSIVE, 0.0, item.get("note") or "no runnable command"
    if not os.path.exists(item["cmd"][1]):
        return INCONCLUSIVE, 0.0, "not present: %s" % item["cmd"][1]
    t0 = time.time()
    try:
        r = subprocess.run(item["cmd"], capture_output=True, text=True,
                           timeout=TIMEOUT[item["speed"]], cwd=REPO)
    except subprocess.TimeoutExpired:
        return INCONCLUSIVE, time.time() - t0, ("TIMED OUT after %ds -- it did "
                                                "not answer, which is not a "
                                                "pass" % TIMEOUT[item["speed"]])
    except OSError as e:
        return INCONCLUSIVE, time.time() - t0, "could not launch: %s" % e
    dt = time.time() - t0
    text = (r.stdout or "") + (r.stderr or "")
    if verbose:
        sys.stdout.write(text)
    last = ""
    for line in reversed(text.strip().splitlines()):
        if line.strip():
            last = line.strip()[:100]
            break
    rc = r.returncode
    if rc == 0:
        return PASS, dt, last
    # A tool that answers 3 is saying INCONCLUSIVE in this repo's convention.
    if rc == 3 or "INCONCLUSIVE" in text.upper()[:0]:
        return INCONCLUSIVE, dt, last or "exit 3"
    if rc == 2 and "unrecognized arguments" in text:
        return INCONCLUSIVE, dt, "the flag this registry passes does not exist"
    return FAIL, dt, last or ("exit %s" % rc)


# --------------------------------------------------------------------------
# Falsifier audit
# --------------------------------------------------------------------------

def audit_falsifiers():
    """-> (untriaged, gaps, audited). `untriaged` is always a hard FAIL."""
    known = {v["tool"]: v for v in VERIFIERS}
    untriaged, gaps, audited = [], [], []
    for tool in discover_verifiers():
        v = known.get(tool)
        if v is None:
            untriaged.append(tool)
        elif v["falsifier"]:
            audited.append(v)
        elif v["reason"]:
            continue                       # explicitly not a verifier, with why
        elif v["gap"]:
            gaps.append(v)
        else:
            untriaged.append(tool)
    # A registered falsifier that names an item nobody runs is decorative.
    names = {i["name"] for i in ITEMS}
    for v in audited:
        if v["falsifier"] not in names:
            untriaged.append("%s -> falsifier %r is not a registry item"
                             % (v["tool"], v["falsifier"]))
    return untriaged, gaps, audited


# --------------------------------------------------------------------------
# Cache
# --------------------------------------------------------------------------

def _git(*a):
    try:
        r = subprocess.run(["git"] + list(a), capture_output=True, text=True,
                           cwd=REPO, timeout=60)
        return r.stdout if r.returncode == 0 else ""
    except (OSError, subprocess.SubprocessError):
        return ""


def tree_key():
    """(head, dirty_hash). The dirty hash covers the CONTENT of every dirty
    source file, not just its name -- an edit that does not change the porcelain
    listing must still invalidate the cache."""
    head = _git("rev-parse", "HEAD").strip() or "no-head"
    status = _git("status", "--porcelain=v1", "-uall")
    h = hashlib.sha256(status.encode("utf-8", "replace"))
    for line in status.splitlines():
        rel = line[3:].strip().strip('"')
        if " -> " in rel:
            rel = rel.split(" -> ", 1)[1]
        if os.path.splitext(rel)[1] not in (".py", ".nim", ".json", ".md"):
            continue
        p = os.path.join(REPO, rel.replace("/", os.sep))
        try:
            if os.path.getsize(p) > 4 << 20:
                continue
            with open(p, "rb") as f:
                h.update(rel.encode("utf-8", "replace"))
                h.update(f.read())
        except OSError:
            h.update(b"<unreadable>" + rel.encode("utf-8", "replace"))
    return head, h.hexdigest()


def read_cache():
    try:
        with open(CACHE, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def cache_is_green(max_age_s=1800):
    """-> (ok, why). Used by deploy.py. Only a GREEN, MATCHING, YOUNG cache
    counts; every other case is a reason to re-run, never a pass."""
    doc = read_cache()
    if not doc:
        return False, "no cached self-test result"
    head, dirty = tree_key()
    if doc.get("git_head") != head:
        return False, "cache is for a different HEAD"
    if doc.get("dirty_hash") != dirty:
        return False, "the working tree changed since the cached run"
    age = time.time() - doc.get("timestamp", 0)
    if age > max_age_s:
        return False, "cache is %.0f min old (limit %.0f)" % (age / 60.0,
                                                              max_age_s / 60.0)
    if doc.get("exit") != 0:
        return False, "the cached run was RED"
    if doc.get("mode") != "fast" and doc.get("mode") != "all":
        return False, "the cached run was not a full fast run"
    return True, "cached green run %.0f min ago" % (age / 60.0)


def write_cache(mode, code, rows, untriaged, gaps):
    head, dirty = tree_key()
    doc = {"git_head": head, "dirty_hash": dirty, "timestamp": time.time(),
           "timestamp_h": time.strftime("%Y-%m-%d %H:%M:%S"),
           "mode": mode, "exit": code,
           "untriaged_verifiers": untriaged,
           "falsifier_gaps": [v["tool"] for v in gaps],
           "items": [{"name": n, "status": s, "sec": round(d, 2),
                      "detail": t} for n, s, d, t in rows]}
    try:
        with open(CACHE, "w", encoding="utf-8", newline="\n") as f:
            json.dump(doc, f, indent=1)
    except OSError as e:
        print("  (could not write %s: %s -- the next run will not be able to "
              "reuse this result, which is the safe direction)" % (CACHE, e))


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

MARK = {PASS: "PASS", FAIL: "FAIL", INCONCLUSIVE: "INCONC", SKIP: "SKIP"}


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="run every self-test; audit every verifier's falsifier")
    ap.add_argument("--fast", action="store_true",
                    help="fast items only (default)")
    ap.add_argument("--all", action="store_true", help="fast + slow")
    ap.add_argument("--list", action="store_true", help="print the registry")
    ap.add_argument("--falsifiers", action="store_true",
                    help="run the falsifier audit only")
    ap.add_argument("--strict", action="store_true",
                    help="count KNOWN-DEBT falsifier gaps as failures too "
                         "(implied by --all)")
    ap.add_argument("--only", default=None,
                    help="substring filter on item names")
    ap.add_argument("-v", "--verbose", action="store_true",
                    help="stream each item's output")
    ap.add_argument("--no-cache-write", action="store_true")
    args = ap.parse_args(argv)

    mode = "all" if args.all else "fast"
    strict = args.strict or args.all

    untriaged, gaps, audited = audit_falsifiers()

    if args.list:
        for it in ITEMS:
            print("%-6s %-42s %s" % (it["speed"], it["name"],
                                     it.get("note", "")))
        print("\n%d items; %d verifiers audited, %d gaps, %d untriaged"
              % (len(ITEMS), len(audited), len(gaps), len(untriaged)))
        return 0

    if args.falsifiers:
        report_falsifiers(untriaged, gaps, audited)
        return 1 if untriaged or (strict and gaps) else 0

    items = [i for i in ITEMS if args.all or i["speed"] == "fast"]
    if args.only:
        items = [i for i in items if args.only in i["name"]]

    # Drift: something in the tree that the registry has never heard of.
    reg_files = set()
    for i in ITEMS:
        if i["cmd"]:
            reg_files.add(os.path.basename(i["cmd"][1]))
    reg_files |= POSITIONAL_SELFTEST | {"selftests.py"}
    drift = [t for t in discover_tests() if t not in reg_files]
    drift += [t for t in discover_selftest_tools()
              if t not in reg_files and t not in NOT_ITEMS]

    print("aowlspt self-tests -- %s (%d items)" % (mode, len(items)))
    print("=" * 78)
    rows = []
    t_all = time.time()
    for it in items:
        sys.stdout.write("%-44s " % it["name"][:44])
        sys.stdout.flush()
        st, dt, detail = run_item(it, args.verbose)
        rows.append((it["name"], st, dt, detail))
        print("%-6s %6.1fs  %s" % (MARK[st], dt, detail[:60]))
    total = time.time() - t_all

    print("=" * 78)
    n = {k: sum(1 for r in rows if r[1] == k) for k in (PASS, FAIL,
                                                        INCONCLUSIVE, SKIP)}
    print("%d PASS  %d FAIL  %d INCONCLUSIVE (could not run)  %d SKIP (needs "
          "absent)   %.1fs" % (n[PASS], n[FAIL], n[INCONCLUSIVE], n[SKIP],
                               total))

    bad = [r for r in rows if r[1] == FAIL]
    unrun = [r for r in rows if r[1] == INCONCLUSIVE]
    if bad:
        print("\nFAILED:")
        for name, _s, _d, detail in bad:
            print("  %-42s %s" % (name, detail))
    if unrun:
        print("\nCOULD NOT RUN (this is NOT a pass):")
        for name, _s, _d, detail in unrun:
            print("  %-42s %s" % (name, detail))
    skipped = [r for r in rows if r[1] == SKIP]
    if skipped:
        print("\nSKIPPED, input absent on this machine:")
        for name, _s, _d, detail in skipped:
            print("  %-42s %s" % (name, detail))

    report_falsifiers(untriaged, gaps, audited)

    if drift:
        print("\nREGISTRY DRIFT -- in the tree, not in ITEMS:")
        for d in sorted(set(drift)):
            print("  %s" % d)

    code = 0
    if bad or unrun:
        code = 1 if bad else 3
    if untriaged or drift:
        code = 1
    if strict and gaps:
        code = 1

    print("\nexit %d" % code)
    if not args.no_cache_write:
        write_cache(mode, code, rows, untriaged, gaps)
    return code


def report_falsifiers(untriaged, gaps, audited):
    print("\nfalsifier audit: %d verifiers with a registered negative control, "
          "%d KNOWN-DEBT gaps, %d untriaged" % (len(audited), len(gaps),
                                                len(untriaged)))
    for v in gaps:
        print("  VERIFIER WITHOUT FALSIFIER: %-26s %s" % (v["tool"], v["gap"]))
    for t in untriaged:
        print("  VERIFIER NOT TRIAGED (hard fail): %s" % t)
    if untriaged:
        print("  -- a tool that prints verdicts must be added to VERIFIERS in "
              "tools/selftests.py with a falsifier or a stated gap.")


if __name__ == "__main__":
    sys.exit(main())
