#!/usr/bin/env python3
r"""wtcheck.py -- catch the worktree that would let an agent commit a mass deletion.

    python tools/wtcheck.py               report
    python tools/wtcheck.py --json
    python tools/wtcheck.py --prune       deregister the GUTTED ones (safe)
    python tools/wtcheck.py --quiet       exit code only

## The failure this exists to prevent

"Worktrees -- we cannot all work on the same code, and this causes code to get
lost sometimes." Here is the actual mechanism, measured 2026-09-01:

22 of this repo's 102 registered worktrees lived under `%TEMP%`. Windows' temp
cleanup deleted their FILES but left the directories, so git still trusted them
as checkouts -- each reporting ~1,100 tracked files as ` D` (deleted in the
working tree, unstaged). 14 were in that state.

A worktree in that state is a loaded gun. An agent that cd's into one and runs
`git commit -a`, or `git add -A && git commit`, commits the deletion of the
entire repository onto that branch, and it looks like an ordinary commit. No
tool in the repo could see this.

## What it does NOT do, and why that matters

Removing a worktree NEVER loses a commit. Branches live in the shared object
store in the main repo's `.git`; a worktree is a checkout plus a registration.
`--prune` therefore only ever deregisters, never deletes a branch, and it
refuses any worktree that is not gutted -- including one with real uncommitted
edits, which is the only state where files can actually be lost.

## Three states, never two

    OK       a real checkout with its files present.
    GUTTED   registered, directory present, tracked files deleted en masse.
             This is the dangerous one.
    VOLATILE a real checkout that lives under a temp path. Not broken yet;
             it is the state GUTTED comes from, so it is worth naming before
             it converts.

`INCONCLUSIVE` is reported for any worktree git lists that cannot be inspected
-- "I could not look" is not "it is fine" (CLAUDE.md 9b).
"""

from __future__ import annotations

import argparse
import json as jsonmod
import os
import subprocess
import sys

# A worktree is GUTTED, rather than mid-edit, when this many tracked files are
# deleted at once. A person deletes a handful; temp cleanup deletes everything.
# Deliberately high: a false GUTTED would deregister real work, so the bar is
# "no plausible human edit looks like this".
GUTTED_DELETIONS = 200

VOLATILE_MARKERS = ("\\temp\\", "/temp/", "\\tmp\\", "/tmp/",
                    "\\appdata\\local\\temp", "/appdata/local/temp")


def git(args, cwd=None):
    try:
        r = subprocess.run(["git"] + args, cwd=cwd, capture_output=True,
                           text=True, timeout=120)
        return r.returncode, r.stdout, r.stderr
    except Exception as e:
        return 1, "", str(e)


def worktrees(repo):
    """(path, branch) for every registered worktree."""
    rc, out, _ = git(["worktree", "list", "--porcelain"], cwd=repo)
    if rc != 0:
        return None
    items, path = [], None
    for line in out.splitlines():
        if line.startswith("worktree "):
            path = line[9:].strip()
        elif line.startswith("branch ") and path:
            items.append((path, line[7:].strip().replace("refs/heads/", "")))
            path = None
        elif line.strip() == "" and path:
            items.append((path, None))
            path = None
    if path:
        items.append((path, None))
    return items


def classify(path, branch, main):
    volatile = any(m in path.lower().replace("/", os.sep).replace("\\", os.sep)
                   .replace(os.sep, "/") or m in path.lower()
                   for m in VOLATILE_MARKERS)
    if not os.path.isdir(path):
        return {"path": path, "branch": branch, "state": "MISSING",
                "deleted": 0, "volatile": volatile,
                "note": "registered but the directory is gone; `git worktree "
                        "prune` removes it"}
    rc, out, err = git(["status", "--porcelain"], cwd=path)
    if rc != 0:
        return {"path": path, "branch": branch, "state": "INCONCLUSIVE",
                "deleted": 0, "volatile": volatile,
                "note": "could not read status: %s" % (err.strip()[:120],)}
    deleted = sum(1 for l in out.splitlines() if l[:2] in (" D", "D ", "AD"))
    other = sum(1 for l in out.splitlines()
                if l.strip() and not l.startswith("??") and l[:2] not in
                (" D", "D ", "AD"))
    if deleted >= GUTTED_DELETIONS and other == 0:
        return {"path": path, "branch": branch, "state": "GUTTED",
                "deleted": deleted, "volatile": volatile,
                "note": "%d tracked files deleted in the working tree and no "
                        "other change: an agent running `git commit -a` here "
                        "would commit the removal of the whole tree" % deleted}
    if volatile:
        return {"path": path, "branch": branch, "state": "VOLATILE",
                "deleted": deleted, "volatile": True,
                "note": "a real checkout, but under a temp path that the OS "
                        "may clear -- this is where GUTTED comes from"}
    return {"path": path, "branch": branch, "state": "OK", "deleted": deleted,
            "volatile": False, "note": ""}


def main():
    p = argparse.ArgumentParser(
        description="find worktrees that would let an agent commit a mass "
                    "deletion",
        formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    p.add_argument("--repo", default=os.path.dirname(
        os.path.dirname(os.path.abspath(__file__))))
    p.add_argument("--json", action="store_true")
    p.add_argument("--quiet", action="store_true")
    p.add_argument("--prune", action="store_true",
                   help="deregister GUTTED worktrees. Never touches a branch, "
                        "and refuses anything not GUTTED.")
    a = p.parse_args()

    wts = worktrees(a.repo)
    if wts is None:
        print("INCONCLUSIVE -- `git worktree list` failed; nothing was checked.")
        return 3

    rows = [classify(pth, br, a.repo) for pth, br in wts]
    gutted = [r for r in rows if r["state"] == "GUTTED"]
    volatile = [r for r in rows if r["state"] == "VOLATILE"]
    unknown = [r for r in rows if r["state"] == "INCONCLUSIVE"]
    missing = [r for r in rows if r["state"] == "MISSING"]

    pruned = []
    if a.prune:
        for r in gutted:
            # Record the tip FIRST. Deregistering cannot lose it, but the
            # record is what makes that claim checkable rather than asserted.
            tip = ""
            if r["branch"]:
                _rc, out, _ = git(["rev-parse", r["branch"]], cwd=a.repo)
                tip = out.strip()
            rc, _out, err = git(["worktree", "remove", "--force", r["path"]],
                                cwd=a.repo)
            pruned.append({"path": r["path"], "branch": r["branch"],
                           "tip": tip, "ok": rc == 0,
                           "error": err.strip()[:160]})

    if a.json:
        print(jsonmod.dumps({"worktrees": rows, "pruned": pruned},
                            separators=(",", ":")))
    elif not a.quiet:
        print("%d worktree(s): %d OK, %d GUTTED, %d VOLATILE, %d MISSING, "
              "%d INCONCLUSIVE"
              % (len(rows), len(rows) - len(gutted) - len(volatile)
                 - len(missing) - len(unknown), len(gutted), len(volatile),
                 len(missing), len(unknown)))
        for r in gutted + missing + unknown:
            print("\n  %-12s %s" % (r["state"], r["path"]))
            print("               branch %s" % (r["branch"] or "(detached)"))
            print("               %s" % r["note"])
        if volatile:
            print("\n  VOLATILE (%d): real checkouts under a temp path --"
                  % len(volatile))
            for r in volatile:
                print("      %-40s %s" % (r["branch"] or "(detached)",
                                          r["path"]))
        if pruned:
            print("\n  deregistered %d GUTTED worktree(s). No branch was "
                  "touched; every tip is recorded here:" % len(pruned))
            for q in pruned:
                print("      %-38s %s  %s" % (q["branch"], q["tip"][:12],
                                              "ok" if q["ok"] else q["error"]))
        if gutted and not a.prune:
            print("\n  Fix: python tools/wtcheck.py --prune")

    if unknown:
        return 3
    return 1 if gutted else 0


if __name__ == "__main__":
    sys.exit(main())
