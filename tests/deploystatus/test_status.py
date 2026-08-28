#!/usr/bin/env python3
"""Fixture test for `deploy.py status`.

The point is NOT "status printed something". It is that each of the six
shapes the real install actually contains is classified correctly, and that
the assertions can FAIL -- run with `--break <mutation>` to deliberately
corrupt the classifier and watch the same assertions go red. If a check has
no input that falsifies it, it is not a check (CLAUDE.md 9b).

The fixture reproduces, in a temp dir, exactly the traps measured in the live
install on 2026-08-28:

  enabled     mods/alpha/alpha.dll                     -> ENABLED, current
  stale       mods/delta/delta.dll (different bytes)   -> ENABLED, STALE
  off         mods/bravo/bravo.dll.off                 -> SWITCHED OFF
  missing     mods/charlie/ has neither                -> MISSING
  decoy       mods/echo/echo.dll + echo.dll.off.disabled-orig
                                                       -> ENABLED  (NOT off)
  ambiguous   mods/foxtrot/foxtrot.dll + foxtrot.dll.off -> AMBIGUOUS
  backups     mods-newbuilds-20260825/*/**.dll.off     -> must NOT appear
  noise       140-ish .bak-<ts> files everywhere       -> must NOT appear

Usage:
    python tests/deploystatus/test_status.py
    python tests/deploystatus/test_status.py --break glob
    python tests/deploystatus/test_status.py --break recursive
    python tests/deploystatus/test_status.py --break nocompare
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
DEPLOY = os.path.join(REPO, "tools", "deploy.py")

MODS = [
    # name,     src bytes,   live bytes (None = no live dll), extra files
    ("alpha",   b"ALPHA-1",  b"ALPHA-1",  []),
    ("delta",   b"DELTA-2",  b"DELTA-1",  []),
    ("bravo",   b"BRAVO-1",  None,        [("bravo.dll.off", b"BRAVO-1")]),
    ("charlie", b"CHAR-1",   None,        []),
    ("echo",    b"ECHO-1",   b"ECHO-1",
     [("echo.dll.off.disabled-orig", b"ECHO-OLD")]),
    ("foxtrot", b"FOX-1",    b"FOX-1",    [("foxtrot.dll.off", b"FOX-OLD")]),
]

EXPECT = {
    "alpha":   ("ENABLED", "matches the built artifact"),
    "delta":   ("ENABLED", "DIFFERS from built"),
    "bravo":   ("SWITCHED OFF", None),
    "charlie": ("MISSING", None),
    "echo":    ("ENABLED", "matches the built artifact"),
    "foxtrot": ("AMBIGUOUS", None),
}

BACKUP_DIR = "mods-newbuilds-20260825"
BACKUP_MODS = ["blackdivision", "classicmovement", "fov", "morebots",
               "perf", "sain", "sway"]


def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)


def build_fixture(root):
    repo = os.path.join(root, "repo")
    install = os.path.join(root, "install")
    for name, srcb, liveb, extra in MODS:
        write(os.path.join(repo, "mods", name, "bin", name + ".dll"), srcb)
        d = os.path.join(install, "mods", name)
        os.makedirs(d, exist_ok=True)
        if liveb is not None:
            write(os.path.join(d, name + ".dll"), liveb)
        for fn, b in extra:
            write(os.path.join(d, fn), b)
        # timestamped backup noise, the same shape as the 140+ real ones
        for i in range(3):
            write(os.path.join(d, "%s.dll.bak-2026082%d-1200%d0"
                               % (name, i, i)), b"OLD")
    # the sibling backup tree that a recursive glob wrongly picks up
    for name in BACKUP_MODS:
        write(os.path.join(install, BACKUP_DIR, name, name + ".dll.off"),
              b"BACKUP")
    return repo, install


def config_for(root):
    return {"install": os.path.join(root, "install"),
            "artifacts": [{"name": n,
                           "src": "mods/%s/bin/%s.dll" % (n, n),
                           "dst": "mods/%s/%s.dll" % (n, n),
                           "markers": []}
                          for n, _, _, _ in MODS]}


MUTATIONS = {
    # each mutation is (needle, replacement) applied to live_state / status
    "glob": (
        '    off = off_path(dst)\n'
        '    if os.path.isfile(dst):\n',
        '    import glob as _g\n'
        '    _hits = _g.glob(dst + ".off*")\n'
        '    if _hits:\n'
        '        return SWITCHED_OFF, _hits[0]\n'
        '    off = off_path(dst)\n'
        '    if os.path.isfile(dst):\n'),
    "recursive": (
        '    for name in sorted(os.listdir(root)):\n'
        '        d = os.path.join(root, name)\n'
        '        if not os.path.isdir(d) or name.lower() in known:\n'
        '            continue\n',
        '    for base, _, files in os.walk(os.path.dirname(root)):\n'
        '        name = os.path.basename(base)\n'
        '        d = base\n'
        '        if not any(f.endswith(".off") for f in files):\n'
        '            continue\n'),
    "nocompare": (
        '    if not src or not os.path.isfile(src):\n'
        '        return UNKNOWN, "not built in this checkout -- cannot '
        'compare"\n',
        '    if not src or not os.path.isfile(src):\n'
        '        return CURRENT, "matches the built artifact"\n'
        '    return CURRENT, "matches the built artifact"\n'),
}


def make_deploy(root, mutation):
    """Return the path to the deploy.py to run (a copy if mutated)."""
    if not mutation:
        return DEPLOY
    with open(DEPLOY, "r", encoding="utf-8", newline="") as f:
        s = f.read()
    needle, repl = MUTATIONS[mutation]
    if needle not in s:
        sys.exit("mutation %r no longer matches deploy.py -- the test's "
                 "falsifiability proof is broken, fix it before trusting a "
                 "PASS" % mutation)
    tools = os.path.join(root, "tools")
    os.makedirs(tools, exist_ok=True)
    out = os.path.join(tools, "deploy.py")
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write(s.replace(needle, repl))
    shutil.copy2(os.path.join(REPO, "tools", "deploy.json"),
                 os.path.join(tools, "deploy.json"))
    return out


def run_status(root, script, cfgpath):
    env = dict(os.environ)
    p = subprocess.run([sys.executable, script, "status", "--no-color"],
                       capture_output=True, text=True, env=env,
                       cwd=root)
    return p.returncode, p.stdout + p.stderr


def parse(out):
    """artifact name -> (state, whole line)."""
    got = {}
    for line in out.splitlines():
        for st in ("SWITCHED OFF", "ENABLED", "AMBIGUOUS", "MISSING"):
            if line.startswith(st):
                rest = line[len(st):].split()
                if rest:
                    got[rest[0]] = (st, line)
                break
    return got


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--break", dest="mut", choices=sorted(MUTATIONS),
                    default=None)
    a = ap.parse_args()

    root = tempfile.mkdtemp(prefix="deploystatus-")
    try:
        repo, install = build_fixture(root)
        script = make_deploy(root, a.mut)
        # the script under test computes REPO from its own location, so a
        # mutated copy lives at <root>/tools/deploy.py with <root>/repo as
        # the source tree. Point both at the fixture.
        if not a.mut:
            script = os.path.join(root, "tools", "deploy.py")
            os.makedirs(os.path.dirname(script), exist_ok=True)
            shutil.copy2(DEPLOY, script)
        cfgpath = os.path.join(root, "tools", "deploy.json")
        with open(cfgpath, "w", encoding="utf-8", newline="\n") as f:
            json.dump(config_for(root), f, indent=1)
        # deploy.py derives REPO as the parent of its own dir; the fixture
        # sources live under <root>/repo, so mirror them at <root>/mods.
        for name, srcb, _, _ in MODS:
            write(os.path.join(root, "mods", name, "bin", name + ".dll"),
                  srcb)

        rc, out = run_status(root, script, cfgpath)
        print(out)

        fails = []
        got = parse(out)
        for name, (state, fresh) in EXPECT.items():
            if name not in got:
                fails.append("%s: not reported at all" % name)
                continue
            g, line = got[name]
            if g != state:
                fails.append("%s: reported %s, expected %s\n    %s"
                             % (name, g, state, line))
            elif fresh and fresh not in line:
                fails.append("%s: expected freshness %r in\n    %s"
                             % (name, fresh, line))

        # NEGATIVE: nothing from the backup tree may appear anywhere.
        if BACKUP_DIR in out:
            fails.append("the backup dir %s leaked into the report" % BACKUP_DIR)
        for name in BACKUP_MODS:
            if name in ("fov", "sain", "morebots"):
                continue  # those names are not fixture artifacts anyway
            if name in out:
                fails.append("backup-only mod %r leaked into the report" % name)
        # NEGATIVE: no .bak- noise.
        if ".bak-" in out:
            fails.append(".bak- backup files leaked into the report")
        # NEGATIVE: the decoy must never be quoted as the reason echo is off.
        if "disabled-orig" in out:
            fails.append("the stale .disabled-orig decoy leaked into the "
                         "report")
        # Summary must count exactly one switched-off and one missing.
        if "1 switched off, 1 missing, 1 ambiguous, 1 stale" not in out:
            fails.append("summary line does not read "
                         "'1 switched off, 1 missing, 1 ambiguous, 1 stale'")
        # stale/ambiguous present -> exit 1
        if rc != 1:
            fails.append("exit code %d, expected 1 (stale + ambiguous)" % rc)

        if fails:
            print("FAIL (%d)" % len(fails))
            for f in fails:
                print("  - " + f)
            return 1
        print("PASS  6 artifacts classified, 5 negatives held, exit 1")
        return 0
    finally:
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
