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
Exit codes: 0 ok, 1 a marker was missing or a copy failed, 2 bad usage.
"""

import argparse
import json
import os
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


def verify(art, src, C):
    """Return (ok, list-of-problem-strings). Reads the file once."""
    red, green, yellow, dim, reset = C
    problems = []
    if not os.path.isfile(src):
        return False, ["not built: %s" % src]
    size = os.path.getsize(src)
    floor = art.get("minBytes", 1)
    if size < floor:
        problems.append("only %d bytes (expected at least %d) -- a failed or "
                        "half-written build" % (size, floor))
        # No point scanning a truncated file for markers.
        return False, problems

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
    return (len(problems) == 0), problems


def cmd_check(args, cfg, C):
    red, green, yellow, dim, reset = C
    arts = select(cfg, args.only)
    bad = 0
    for art in arts:
        src = os.path.join(REPO, art["src"].replace("/", os.sep))
        ok, problems = verify(art, src, C)
        n = len(art.get("markers", []))
        if ok:
            print("%sok%s   %-8s %s  (%d marker%s, %s bytes)"
                  % (green, reset, art["name"], art["src"], n,
                     "" if n == 1 else "s", os.path.getsize(src)))
        else:
            bad += 1
            print("%sFAIL%s %-8s %s" % (red, reset, art["name"], art["src"]))
            for p in problems:
                print("       %s" % p)
    if bad:
        print("\n%s%d artifact(s) failed verification.%s" % (red, bad, reset))
        print("A missing marker means the feature's own text is not in the "
              "binary. Do NOT deploy this; rebuild from the right base.")
    return 1 if bad else 0


def backup_name(dst):
    return "%s.bak-%s" % (dst, time.strftime("%Y%m%d-%H%M%S"))


def cmd_deploy(args, cfg, C):
    red, green, yellow, dim, reset = C
    install = args.install or cfg["install"]
    arts = select(cfg, args.only)

    # Verify EVERYTHING first, then copy. A partial deploy -- new host DLL
    # against an old tarkov.dll -- is its own class of confusing bug, so if any
    # selected artifact is bad, nothing moves.
    rc = cmd_check(args, cfg, C)
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
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--no-color", action="store_true")
    args = p.parse_args()
    if args.target and not args.only:
        args.only = args.target

    C = _color(not args.no_color and sys.stdout.isatty())
    cfg = load_config()
    if args.command == "check":
        return cmd_check(args, cfg, C)
    if args.command == "deploy":
        return cmd_deploy(args, cfg, C)
    return cmd_rollback(args, cfg, C)


if __name__ == "__main__":
    sys.exit(main())
