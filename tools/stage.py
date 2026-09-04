#!/usr/bin/env python3
r"""stage.py -- keep a COPY of every build, so a later build cannot delete it.

MEASURED 2026-09-04 08:58. `buildlock.py build host` finished cleanly (exit 0,
sidecar written, sha recorded). Before `deploylock.py deploy host` could copy
the bytes, another agent's queued `build host` took the lock and `aowl` -- which
REMOVES its output before writing it -- deleted the artifact. The deploy refused
with "the artifact is not the build that was recorded", which was the correct
answer, and the launcher therefore ran the OLD host DLL.

With several agents building in one checkout that race is not exotic, it is the
normal case. The build lock cannot close it: the deletion happens after the
first build's lock has been released, and holding the build slot for the whole
of somebody's verify-and-deploy pass would serialise the wrong thing.

So the bytes are COPIED out of `bin/` the moment the build that made them
proves them, into a location no build ever writes:

    .stage/<target>/<sha256[:12]>/<basename>
    .stage/<target>/<sha256[:12]>/<basename>.built.json   (the sidecar, verbatim)
    .stage/<target>/<sha256[:12]>/stage.json              (what this stage IS)

`.stage/` is repo-local and gitignored. A deploy reads from there, so a build
running at that instant cannot remove the file mid-copy.

## What a stage is NOT

It is not a second source of truth about whether a build was good. Everything
that decides that -- the sidecar's sha, `stale_sources`, the marker list in
`tools/deploy.json` -- is unchanged and is applied to the STAGED bytes exactly
as it was applied to `bin/`. A stage only removes the window in which the file
can vanish. If the staged bytes fail a marker check they are refused like any
others; `pick()` below never selects a stage whose sidecar says
`stale_sources`, and its caller applies the marker check on top.

## Three outcomes here too

`put()` returns `(record, None)` or `(None, why)`. A staging failure must NOT
fail an otherwise good build -- the artifact is still in `bin/` and is still
deployable the old way -- but it must be printed, because a silent staging
failure would reappear later as "no stage for host" with no explanation.

## Retention

`KEEP` (6) stages per (target, artifact), oldest pruned by build time. Per
ARTIFACT rather than per target, deliberately: `build mods` produces a dozen
artifacts in one run, and a flat "6 newest under this target" would evict five
mods' only stage every time one mod is rebuilt.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import time

STAGE_DIR = ".stage"
SIDECAR_SUFFIX = ".built.json"
STAGE_META = "stage.json"
KEEP = 6
SHA_PREFIX = 12


def stage_root(repo):
    return os.path.join(repo, STAGE_DIR)


def target_key(target):
    """`build host` -> `host`; `build mod maps` -> `mod-maps`.

    A directory name, so it is slugged. An unrecognisable target still gets a
    key rather than being dropped -- an unstaged build is the failure this file
    exists to prevent, so the fallback direction is "stage it somewhere" and
    never "stage nothing".
    """
    words = [w for w in (target or "").split() if not w.startswith("-")]
    if words and words[0] == "build":
        words = words[1:]
    key = "-".join(words) if words else "unnamed"
    key = re.sub(r"[^A-Za-z0-9._-]+", "-", key).strip("-")
    return key.lower() or "unnamed"


def _read_json(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _write_json(path, doc):
    tmp = path + ".tmp%d" % os.getpid()
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        json.dump(doc, f, indent=1, sort_keys=True)
    os.replace(tmp, path)


def put(repo, target, artifact_path, artifact_src=None, name=None,
        keep=KEEP):
    """Copy one built artifact (and its sidecar) into the stage.

    Returns `(record, None)` or `(None, why)`. `record` is the same shape
    `stages()` yields.
    """
    if not os.path.isfile(artifact_path):
        return None, "nothing at %s" % artifact_path
    side_src = artifact_path + SIDECAR_SUFFIX
    side = _read_json(side_src)
    if not side or not side.get("sha256"):
        return None, ("no usable sidecar beside %s -- a stage with no record "
                      "of which build made it would vouch for nothing"
                      % artifact_path)
    sha = str(side["sha256"])
    key = target_key(target)
    base = os.path.basename(artifact_path)
    d = os.path.join(stage_root(repo), key, sha[:SHA_PREFIX])
    try:
        os.makedirs(d, exist_ok=True)
        shutil.copy2(artifact_path, os.path.join(d, base))
        shutil.copy2(side_src, os.path.join(d, base + SIDECAR_SUFFIX))
        meta = {"target": target, "target_key": key, "artifact": base,
                "artifact_src": artifact_src or "", "name": name or "",
                "sha256": sha, "staged_at": time.time(),
                "staged_h": time.strftime("%Y-%m-%d %H:%M:%S")}
        _write_json(os.path.join(d, STAGE_META), meta)
    except OSError as e:
        return None, "%s: %s" % (type(e).__name__, e)
    prune(repo, key, base, keep=keep)
    recs = [r for r in stages(repo, key) if r["sha256"] == sha
            and r["artifact"] == base]
    if not recs:
        return None, "the stage was written but could not be read back: %s" % d
    return recs[0], None


def stages(repo, target_key_=None, artifact=None, artifact_src=None):
    """Every stage, NEWEST FIRST. Never raises; an unreadable stage is skipped.

    Filters are exact: `target_key_` on the directory name, `artifact` on the
    basename, `artifact_src` on the repo-relative source path recorded at
    staging time (which is what a deploy actually knows).
    """
    root = stage_root(repo)
    out = []
    try:
        keys = sorted(os.listdir(root))
    except OSError:
        return out
    for key in keys:
        if target_key_ and key != target_key_:
            continue
        kdir = os.path.join(root, key)
        try:
            shas = sorted(os.listdir(kdir))
        except OSError:
            continue
        for sha in shas:
            d = os.path.join(kdir, sha)
            meta = _read_json(os.path.join(d, STAGE_META))
            if not meta:
                continue
            base = meta.get("artifact") or ""
            path = os.path.join(d, base)
            if not os.path.isfile(path):
                continue
            side = _read_json(path + SIDECAR_SUFFIX) or {}
            if artifact and base != artifact:
                continue
            if artifact_src and (meta.get("artifact_src") or "") != artifact_src:
                continue
            built = side.get("finished")
            if not built:
                try:
                    built = os.path.getmtime(path)
                except OSError:
                    built = meta.get("staged_at") or 0
            out.append({
                "target": meta.get("target") or key,
                "target_key": key,
                "sha": sha,
                "sha256": meta.get("sha256") or side.get("sha256") or sha,
                "artifact": base,
                "artifact_src": meta.get("artifact_src") or "",
                "name": meta.get("name") or "",
                "path": path,
                "dir": d,
                "sidecar": side,
                "git_head": side.get("git_head"),
                "built_at": float(built or 0),
                "built_h": side.get("finished_h") or meta.get("staged_h") or "",
                "stale_sources": bool(side.get("stale_sources")),
                "source_check": side.get("source_check"),
            })
    out.sort(key=lambda r: r["built_at"], reverse=True)
    return out


def prune(repo, target_key_, artifact, keep=KEEP):
    """Drop all but the `keep` newest stages of ONE artifact. -> removed dirs."""
    recs = stages(repo, target_key_, artifact=artifact)
    removed = []
    for r in recs[keep:]:
        try:
            shutil.rmtree(r["dir"])
            removed.append(r["dir"])
        except OSError:
            pass
    return removed


def pick(repo, artifact_src=None, artifact=None, target_key_=None,
         sha_prefix=None, accept=None):
    """Choose the stage to deploy. -> `(record, notes)` or `(None, notes)`.

    `notes` always explains the choice, including every stage that was
    considered and REJECTED and why -- a selection that silently skipped a
    stale build would read exactly like a checkout that had none.

    Default: the newest stage that is not `stale_sources` and that `accept`
    (the caller's marker check, if any) approves. With `sha_prefix` the choice
    is that stage or NOTHING -- an explicit sha is a request for specific
    bytes, and quietly substituting different ones is the confidently-wrong
    answer this whole mechanism exists to avoid.
    """
    notes = []
    recs = stages(repo, target_key_, artifact=artifact,
                  artifact_src=artifact_src)
    if sha_prefix:
        want = sha_prefix.lower()
        hit = [r for r in recs if r["sha256"].lower().startswith(want)
               or r["sha"].lower().startswith(want)]
        if not hit:
            notes.append("no stage matches sha %s (%d stage(s) exist: %s)"
                         % (sha_prefix, len(recs),
                            ", ".join(r["sha"] for r in recs[:8]) or "none"))
            return None, notes
        if len(hit) > 1:
            notes.append("sha %s matches %d stages (%s) -- give more of it"
                         % (sha_prefix, len(hit),
                            ", ".join(r["sha"] for r in hit)))
            return None, notes
        r = hit[0]
        if r["stale_sources"]:
            notes.append("stage %s was named explicitly and its sidecar says "
                         "stale_sources -- REFUSED, those bytes predate an "
                         "edit made during their own build" % r["sha"])
            return None, notes
        notes.append("stage %s selected by --sha" % r["sha"])
        return r, notes
    if not recs:
        notes.append("no stage exists for this artifact")
        return None, notes
    for r in recs:
        if r["stale_sources"]:
            notes.append("skipped %s (%s): stale_sources -- the sources were "
                         "edited during that build" % (r["sha"], r["built_h"]))
            continue
        if accept is not None:
            ok, why = accept(r)
            if not ok:
                notes.append("skipped %s (%s): %s"
                             % (r["sha"], r["built_h"], why))
                continue
        notes.append("selected %s (%s), git %s"
                     % (r["sha"], r["built_h"], (r["git_head"] or "?")[:12]))
        return r, notes
    notes.append("every one of the %d stage(s) was rejected -- see above; "
                 "nothing was selected" % len(recs))
    return None, notes


def lines(recs, deployed_sha=None):
    """Human rows for `--status` / `stages`. One line per stage."""
    out = []
    for r in recs:
        flags = []
        if r["stale_sources"]:
            flags.append("STALE_SOURCES")
        if r.get("source_check") == "not-performed":
            flags.append("source-check NOT PERFORMED")
        if deployed_sha and r["sha256"].lower() == str(deployed_sha).lower():
            flags.append("DEPLOYED")
        out.append("  %-10s %-12s %-19s git %-12s %s%s"
                   % (r["target_key"], r["sha"], r["built_h"] or "?",
                      (r["git_head"] or "?")[:12], r["artifact"],
                      ("   [%s]" % ", ".join(flags)) if flags else ""))
    return out
