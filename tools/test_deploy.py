#!/usr/bin/env python3
r"""test_deploy.py -- falsifiable tests for deploy.py's two PRE-COPY refusals.

    python tools/test_deploy.py
    python tools/test_deploy.py -v

Never touches D:\Aowlspt. Every case runs against a temp repo and a temp
install root, and asserts on the FINISHED STATE -- whether the destination file
exists and what bytes it holds -- not on the return code alone. A test that
only read the exit code would pass for a `deploy` that refused loudly and
copied anyway, which is precisely the shape of bug this repo keeps producing.

What is asserted, in BOTH directions, because a refusal that always fires is as
useless as one that never does:

  1. baseline               -- a good artifact with a green gate IS copied
  2. sidecar match          -- a `<artifact>.built.json` whose sha256 agrees
                               does not interfere
  3. ARTIFACT REPLACED      -- a sidecar whose sha256 DISAGREES refuses, names
                               the file, and copies NOTHING
  4. sidecar absent         -- a one-line NOTE, and the deploy still proceeds
                               (older builds have no sidecar; refusing them
                               would only teach people to pass --no-selftest)
  5. --expect match/mismatch-- accepted / refused, nothing copied on refusal
  6. --expect + many arts   -- refused: one sha cannot vouch for two files
  7. selftest gate RED      -- refuses, names the runner, copies NOTHING
  8. selftest gate GREEN    -- copies
  9. --no-selftest          -- copies, and SAYS SO in the output (the escape
                               must be loud or it is a silent bypass)
 10. cached green           -- the gate does not re-run the suite
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import contextlib
import shutil
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import deploy                                        # noqa: E402
import selftests                                     # noqa: E402
import stage                                         # noqa: E402

VERBOSE = "-v" in sys.argv
MARKER = "aowlsptTestMarkerOne"
FAILURES = []


def check(label, ok, note=""):
    print("%-4s %s%s" % ("ok" if ok else "FAIL", label, ("  -- " + note)
                         if note and not ok else ""))
    if not ok:
        FAILURES.append(label)


class Bed:
    """A temp repo with one built artifact, and a temp install root."""

    def __init__(self, n_arts=1):
        self.root = tempfile.mkdtemp(prefix="aowl-deploytest-")
        self.repo = os.path.join(self.root, "repo")
        self.install = os.path.join(self.root, "install")
        os.makedirs(os.path.join(self.repo, "bin"))
        os.makedirs(self.install)
        arts = []
        for i in range(n_arts):
            name = "fake%d" % i
            rel = "bin/%s.dll" % name
            with open(os.path.join(self.repo, rel.replace("/", os.sep)),
                      "wb") as f:
                f.write(b"\x00" * 32 + MARKER.encode("utf-8") + b"\x00" * 32
                        + name.encode("utf-8"))
            arts.append({"name": name, "src": rel, "dst": "%s.dll" % name,
                         "markers": [MARKER]})
        self.cfg = {"install": self.install, "artifacts": arts}

    def src(self, i=0):
        return os.path.join(self.repo, "bin", "fake%d.dll" % i)

    def dst(self, i=0):
        return os.path.join(self.install, "fake%d.dll" % i)

    def sha(self, i=0):
        h = hashlib.sha256()
        with open(self.src(i), "rb") as f:
            h.update(f.read())
        return h.hexdigest()

    def sidecar(self, sha, i=0):
        doc = {"target": "build fake", "artifact": "bin/fake%d.dll" % i,
               "sha256": sha, "size": os.path.getsize(self.src(i)),
               "mtime": os.path.getmtime(self.src(i)), "started": 0,
               "finished": 0, "finished_h": "2026-09-02 00:00:00",
               "pid": 1234, "git_head": "deadbeef"}
        with open(self.src(i) + ".built.json", "w", encoding="utf-8",
                  newline="\n") as f:
            json.dump(doc, f, indent=1)

    def stage(self, i=0, payload=None, stale=False, finished=None,
              marker=True):
        """Put a build into `.stage/`, the way buildlock.py does.

        `payload` distinguishes one staged build from another BY ITS BYTES, so
        a test can assert WHICH build was deployed rather than merely that
        something was. `marker=False` stages bytes the marker check must
        reject; `stale=True` stages a build whose sidecar says its sources
        moved under it.
        """
        rel = "bin/fake%d.dll" % i
        src = self.src(i)
        keep = open(src, "rb").read() if os.path.isfile(src) else None
        body = b"\x00" * 32
        if marker:
            body += MARKER.encode("utf-8")
        body += (payload or "staged").encode("utf-8")
        with open(src, "wb") as f:
            f.write(body)
        sha = hashlib.sha256(body).hexdigest()
        doc = {"target": "build fake", "artifact": rel, "sha256": sha,
               "size": len(body), "mtime": os.path.getmtime(src),
               "started": 0,
               "finished": time.time() if finished is None else finished,
               "finished_h": "2026-09-04 00:00:00", "pid": 4321,
               "git_head": "cafe" * 10,
               "source_check": "CHANGED" if stale else "clean",
               "stale_sources": bool(stale)}
        with open(src + ".built.json", "w", encoding="utf-8",
                  newline="\n") as f:
            json.dump(doc, f, indent=1)
        rec, why = stage.put(self.repo, "build fake", src, artifact_src=rel,
                             name="fake%d" % i)
        assert rec, why
        if keep is not None:
            with open(src, "wb") as f:
                f.write(keep)
            os.unlink(src + ".built.json")
        return rec

    def unbuild(self, i=0):
        """What `aowl` does at the start of every build: remove the output."""
        for p in (self.src(i), self.src(i) + ".built.json"):
            if os.path.exists(p):
                os.unlink(p)

    def dst_bytes(self, i=0):
        with open(self.dst(i), "rb") as f:
            return f.read()

    def drop(self):
        shutil.rmtree(self.root, ignore_errors=True)


class FakeRun:
    """Stands in for subprocess.run inside selftest_gate."""

    def __init__(self, rc):
        self.rc = rc
        self.calls = []

    def __call__(self, cmd, **kw):
        self.calls.append(cmd)
        return argparse.Namespace(returncode=self.rc)


def deploy_once(bed, gate_rc=0, cached=None, **flags):
    """Run the real cmd_deploy against the bed. -> (rc, output, gate_calls)."""
    args = argparse.Namespace(install=None, only=None, artifact=None,
                              contains=None, absent=None, control=None,
                              encoding="any", dry_run=False, re_enable=False,
                              no_color=True, no_selftest=False, expect=None,
                              repo=None)
    for k, v in flags.items():
        setattr(args, k, v)
    fake = FakeRun(gate_rc)
    old_repo, old_run = deploy.REPO, deploy.subprocess.run
    old_cache = selftests.cache_is_green
    deploy.REPO = bed.repo
    deploy.subprocess.run = fake
    selftests.cache_is_green = (lambda *a, **k: cached) if cached else \
        (lambda *a, **k: (False, "test: cache ignored"))
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            rc = deploy.cmd_deploy(args, bed.cfg, deploy._color(False))
    finally:
        deploy.REPO, deploy.subprocess.run = old_repo, old_run
        selftests.cache_is_green = old_cache
    out = buf.getvalue()
    if VERBOSE:
        print(out)
    return rc, out, fake.calls


# ---- 1 / 8: baseline, green gate -> the file IS copied --------------------
b = Bed()
rc, out, calls = deploy_once(b, gate_rc=0)
check("baseline: green gate deploys", rc == 0 and os.path.isfile(b.dst()),
      "rc=%s exists=%s" % (rc, os.path.isfile(b.dst())))
check("baseline: the gate actually ran the runner",
      any("selftests.py" in " ".join(c) for c in calls), "calls=%r" % calls)
b.drop()

# ---- 4: no sidecar -> a NOTE, not a refusal ------------------------------
b = Bed()
rc, out, _ = deploy_once(b, gate_rc=0)
check("no sidecar: deploys, with a NOTE",
      rc == 0 and "NOTE no fake0.dll.built.json" in out, out[-400:])
b.drop()

# ---- 2: sidecar agrees -> no interference --------------------------------
b = Bed()
b.sidecar(b.sha())
rc, out, _ = deploy_once(b, gate_rc=0)
check("sidecar sha matches: deploys",
      rc == 0 and os.path.isfile(b.dst()) and "sha matches" in out, out[-400:])
b.drop()

# ---- 3: THE REFUSAL. sidecar disagrees -----------------------------------
b = Bed()
b.sidecar("0" * 64)
rc, out, _ = deploy_once(b, gate_rc=0)
check("ARTIFACT REPLACED: refuses", rc == 1, "rc=%s" % rc)
check("ARTIFACT REPLACED: says so and names the file",
      "ARTIFACT REPLACED SINCE BUILD" in out and "fake0.dll" in out, out[-400:])
check("ARTIFACT REPLACED: copies NOTHING", not os.path.exists(b.dst()),
      "the destination exists after a refusal")
b.drop()

# ---- 5: --expect ---------------------------------------------------------
b = Bed()
rc, out, _ = deploy_once(b, gate_rc=0, expect=b.sha())
check("--expect matching sha: deploys",
      rc == 0 and os.path.isfile(b.dst()), out[-400:])
b.drop()

b = Bed()
rc, out, _ = deploy_once(b, gate_rc=0, expect="f" * 64)
check("--expect wrong sha: refuses", rc == 1, "rc=%s" % rc)
check("--expect wrong sha: copies NOTHING", not os.path.exists(b.dst()))
check("--expect wrong sha: prints both hashes",
      "EXPECTED SHA MISMATCH" in out and b.sha()[:16] in out, out[-400:])
b.drop()

# ---- 6: --expect cannot vouch for two artifacts --------------------------
b = Bed(n_arts=2)
rc, out, _ = deploy_once(b, gate_rc=0, expect=b.sha(0))
check("--expect with 2 artifacts: refuses",
      rc == 1 and not os.path.exists(b.dst(0)) and not os.path.exists(b.dst(1)),
      out[-400:])
b.drop()

# ---- 7: THE REFUSAL. the self-test suite is red --------------------------
b = Bed()
rc, out, _ = deploy_once(b, gate_rc=1)
check("selftests red: refuses", rc == 1, "rc=%s" % rc)
check("selftests red: copies NOTHING", not os.path.exists(b.dst()),
      "the destination exists after a refusal")
check("selftests red: names the runner and how to see the table",
      "selftests.py --fast" in out, out[-400:])
b.drop()

# ---- 9: --no-selftest is an escape, and it is LOUD -----------------------
b = Bed()
rc, out, calls = deploy_once(b, gate_rc=1, no_selftest=True)
check("--no-selftest: deploys despite a red suite",
      rc == 0 and os.path.isfile(b.dst()), "rc=%s" % rc)
check("--no-selftest: does not even run the suite", not calls, "calls=%r" % calls)
check("--no-selftest: says so, loudly",
      "--no-selftest" in out and "NOT" in out, out[-400:])
b.drop()

# ---- 10: a cached green run skips the suite ------------------------------
b = Bed()
rc, out, calls = deploy_once(b, gate_rc=1, cached=(True, "cached green run"))
check("cached green: does not re-run the suite",
      rc == 0 and not calls and "cached green run" in out, out[-400:])
b.drop()


# ---- STAGING: the 2026-09-04 race ----------------------------------------
# MEASURED 08:58: a clean `build host` finished; before the deploy copied it,
# a queued build took the lock and `aowl` deleted the artifact. The deploy
# refused (correctly) and the launcher ran the OLD host DLL. Every case below
# asserts the deployed BYTES, so "something was copied" cannot pass for "the
# right build was copied".

b = Bed()
rec = b.stage(payload="first")
rc, out, _ = deploy_once(b, gate_rc=0)
check("stage: a staged build is what gets deployed",
      rc == 0 and b"first" in b.dst_bytes() and "from STAGE" in out,
      out[-600:])
b.drop()

# THE INCIDENT, reproduced: the stage exists, bin/ has been deleted by the
# next build. The bytes must still reach the install.
b = Bed()
rec = b.stage(payload="first")
b.unbuild()
rc, out, _ = deploy_once(b, gate_rc=0, sha=rec["sha"])
check("stage: --sha deploys the first build AFTER a later build deleted bin/",
      rc == 0 and os.path.isfile(b.dst()) and b"first" in b.dst_bytes(),
      "rc=%s\n%s" % (rc, out[-800:]))
b.drop()

# THE FALSIFIER. Identical situation with NO stage: the deploy must refuse and
# copy nothing. Without this, the case above would pass for a deploy that had
# been reading bin/ all along.
b = Bed()
b.unbuild()
rc, out, _ = deploy_once(b, gate_rc=0)
check("stage FALSIFIER: with bin/ deleted and NO stage, the deploy refuses",
      rc == 3 and not os.path.exists(b.dst()),
      "rc=%s exists=%s\n%s" % (rc, os.path.exists(b.dst()), out[-600:]))
b.drop()

# --sha that names nothing must refuse, not fall back to some other build.
b = Bed()
b.stage(payload="first")
rc, out, _ = deploy_once(b, gate_rc=0, sha="0123456789ab")
check("stage: --sha with no such stage REFUSES and copies nothing",
      rc == 1 and not os.path.exists(b.dst()) and "no stage matches" in out,
      "rc=%s\n%s" % (rc, out[-600:]))
b.drop()

# stale_sources is never auto-selected: the NEWER stage is stale, so the older
# clean one must be the one that lands. Asserted on the deployed BYTES.
b = Bed()
b.stage(payload="clean", finished=1000.0)
b.stage(payload="stalebuild", stale=True, finished=2000.0)
b.unbuild()
rc, out, _ = deploy_once(b, gate_rc=0)
check("stage: a stale_sources stage is skipped for an older CLEAN one",
      rc == 0 and os.path.isfile(b.dst()) and b"clean" in b.dst_bytes()
      and b"stalebuild" not in b.dst_bytes(),
      "rc=%s\n%s" % (rc, out[-800:]))
check("stage: and it says which stage it skipped, and why",
      "stale_sources" in out, out[-600:])
b.drop()

# ... and when the ONLY stage is stale, naming it explicitly is refused too.
b = Bed()
r = b.stage(payload="stalebuild", stale=True)
b.unbuild()
rc, out, _ = deploy_once(b, gate_rc=0, sha=r["sha"])
check("stage: --sha pointing AT a stale_sources stage is refused",
      rc == 1 and not os.path.exists(b.dst()), "rc=%s\n%s" % (rc, out[-600:]))
b.drop()

# A staged build whose MARKERS are missing is not a deployable build. The
# older marker-bearing stage must win -- selection is not by age alone.
b = Bed()
b.stage(payload="good", finished=1000.0)
b.stage(payload="nomarker", marker=False, finished=2000.0)
b.unbuild()
rc, out, _ = deploy_once(b, gate_rc=0)
check("stage: a stage that fails its markers is skipped",
      rc == 0 and os.path.isfile(b.dst()) and b"good" in b.dst_bytes(),
      "rc=%s\n%s" % (rc, out[-800:]))
b.drop()

# The escape hatch, and it must be visible.
b = Bed()
b.stage(payload="first")
rc, out, _ = deploy_once(b, gate_rc=0, no_stage=True)
check("stage: --no-stage deploys from bin/ and says so",
      rc == 0 and b"first" not in b.dst_bytes() and "--no-stage" in out,
      "rc=%s\n%s" % (rc, out[-600:]))
b.drop()

# --stage-only refuses instead of falling back; the default does fall back,
# loudly -- artifacts built before staging existed have no stage and must not
# become undeployable.
b = Bed()
rc, out, _ = deploy_once(b, gate_rc=0, stage_only=True)
check("stage: --stage-only refuses when nothing is staged",
      rc == 1 and not os.path.exists(b.dst()), "rc=%s\n%s" % (rc, out[-600:]))
b.drop()

b = Bed()
rc, out, _ = deploy_once(b, gate_rc=0)
check("stage CONTROL: bin/ present and no stage -- deploys, and SAYS it is "
      "not staged",
      rc == 0 and os.path.isfile(b.dst()) and "NO USABLE STAGE" in out,
      "rc=%s\n%s" % (rc, out[-600:]))
b.drop()

# Retention: six per artifact, oldest pruned, newest kept.
b = Bed()
kept = [b.stage(payload="p%d" % i, finished=1000.0 + i) for i in range(9)]
recs = stage.stages(b.repo, artifact_src="bin/fake0.dll")
check("stage: retention keeps %d and prunes the rest" % stage.KEEP,
      len(recs) == stage.KEEP, "kept %d" % len(recs))
check("stage: the pruned ones are the OLDEST",
      recs and recs[0]["sha"] == kept[-1]["sha"]
      and all(r["sha"] != kept[0]["sha"] for r in recs),
      str([r["sha"] for r in recs]))
b.drop()

# ---- the cache is not a way to pass a red run ----------------------------
ok, why = True, ""
doc_cases = [
    ({"git_head": "x", "dirty_hash": "y", "timestamp": 0, "exit": 0,
      "mode": "fast"}, "a stale timestamp"),
    ({"git_head": "nope", "dirty_hash": "y", "timestamp": 9e9, "exit": 0,
      "mode": "fast"}, "a different HEAD"),
]
tmpd = tempfile.mkdtemp(prefix="aowl-cachetest-")
old_cache_path = selftests.CACHE
for doc, label in doc_cases:
    selftests.CACHE = os.path.join(tmpd, "c.json")
    with open(selftests.CACHE, "w", encoding="utf-8", newline="\n") as f:
        json.dump(doc, f)
    green, why = selftests.cache_is_green()
    check("cache_is_green rejects %s" % label, not green, why)
selftests.CACHE = os.path.join(tmpd, "missing.json")
green, why = selftests.cache_is_green()
check("cache_is_green rejects an absent cache", not green, why)
selftests.CACHE = old_cache_path
shutil.rmtree(tmpd, ignore_errors=True)

print("\n%s -- %d failure(s)" % ("FAIL" if FAILURES else "PASS", len(FAILURES)))
for f in FAILURES:
    print("  - %s" % f)
sys.exit(1 if FAILURES else 0)
