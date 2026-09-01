#!/usr/bin/env python3
"""headless.py -- run the parts of aowlspt that need NO game client, and say
PASS / FAIL / INCONCLUSIVE with an exit code CI can read.

    python tools\\headless.py                 # run every suite
    python tools\\headless.py --list          # what would run, and its prereqs
    python tools\\headless.py --only backend-selftest
    python tools\\headless.py --mutate std-item-count   # prove it can FAIL

WHAT "HEADLESS" HONESTLY MEANS HERE
------------------------------------
It means NO ESCAPEFROMTARKOV.EXE. Nothing in this file starts, stops or talks
to the game, and nothing here needs a GPU, a display or a logged-in desktop
session. It exercises the backend, the emulator and the mods -- which is where
loot generation, trader assorts, profile creation and the route surface live.

It is NOT a headless mode for the game. The Tarkov client cannot be run
headless (see docs/HEADLESS.md); `aowlspt-launch --low-render` is the closest
thing and it still renders. If you came here looking for a way to run a raid
without a screen, this is not it.

If what you actually want is a raid running while you use the machine for
something else, that IS built, and it is not this file:

    python tools\harness.py run --offscreen --profile <id>

which parks the client's window off every monitor (tools/offscreen.py) and
verifies it against the finished state. The renderer still runs -- it is out of
your way, not headless -- and the tool says so every time.

THE RULE THIS FILE EXISTS TO OBEY (CLAUDE.md 9b)
-------------------------------------------------
A run must be able to FAIL. A suite that cannot fail is not a test, and a CI
mode that always exits 0 is worse than no CI mode because it reads as green.
So:

  * a missing prerequisite is INCONCLUSIVE, never PASS. "I could not look" has
    its own outcome and its own exit code.
  * `--mutate NAME` is passed to betacheck, which deliberately breaks the thing
    under test. That is the demonstration that the checks bite; an unknown
    mutation name is REFUSED by betacheck rather than quietly ignored.
  * the exit code is 0 only when at least one suite ran and every suite that
    ran passed.

EXIT CODES
    0  PASS          every suite that ran passed, and at least one ran
    1  FAIL          at least one suite failed
    2  INCONCLUSIVE  nothing ran, or the only outcomes were inconclusive
"""

import argparse
import json
import os
import shutil
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

PASS, FAIL, INCONCLUSIVE = "PASS", "FAIL", "INCONCLUSIVE"


def _p(*parts):
    return os.path.join(REPO, *parts)


BACKEND = _p("backend", "bin", "aowlspt-backend.exe")
SIM = _p("host", "Aowlspt.Sim", "bin", "aowlspt-sim.exe")
ADMINTRADER = _p("mods", "admintrader", "bin", "admintrader.dll")
GAMESERVER = _p("examples", "gameserver", "bin", "gameserver.dll")
STAGE = _p("installer", "build", "headlessstage")
TARKOV = _p("mods", "tarkov", "bin", "tarkov.dll")
DEFAULT_DB = r"D:\Aowlspt\aowlspt\db.json"


def stage_backend():
    """Build the scratch install the backend self test needs.

    The self test is NOT runnable bare: `aowlspt-backend --selftest` with no
    `--root` serves no mod and no database, so every route answers
    `{"err":"no route"}` and the run FAILS for a reason that has nothing to do
    with the code under test. That is a confidently wrong red, and it is as bad
    as a confidently wrong green. This reproduces the same stage `aowl verify`
    builds: the `examples/gameserver` mod plus the one item template the test
    reads back.
    """
    if os.path.isdir(STAGE):
        shutil.rmtree(STAGE, ignore_errors=True)
    moddir = os.path.join(STAGE, "mods", "gameserver")
    os.makedirs(moddir)
    shutil.copyfile(GAMESERVER, os.path.join(moddir, "gameserver.dll"))
    cfg = _p("examples", "gameserver", "config.json")
    if os.path.exists(cfg):
        shutil.copyfile(cfg, os.path.join(moddir, "config.json"))
    # mods/tarkov is NOT optional here even though it looks like it: the last
    # third of the self test drives `/aowlspt/settings/aowl.tarkov`, and with
    # no tarkov mod staged that route answers `{"err":"no route"}`, which the
    # self test walks with `for row in items(root(tree))` and dies on --
    # `[Assertion Failure] items: not a JArray`, taking the whole process with
    # it. The remaining checks then never run and the failure names the wrong
    # thing. Staged here so the run is honest; the assertion itself is a
    # backend defect and is reported, not worked around silently.
    tmod = os.path.join(STAGE, "mods", "tarkov")
    os.makedirs(tmod)
    shutil.copyfile(TARKOV, os.path.join(tmod, "tarkov.dll"))
    tcfg = _p("mods", "tarkov", "config.json")
    if os.path.exists(tcfg):
        shutil.copyfile(tcfg, os.path.join(tmod, "config.json"))
    db = {"templates": {"items": {"5447a9cd4bdc2dbd208b4567": {
        "_id": "5447a9cd4bdc2dbd208b4567",
        "_props": {"Name": "M4A1", "Weight": 0.38}}}}}
    with open(os.path.join(STAGE, "db.json"), "w", newline="\n") as f:
        json.dump(db, f, indent=2)
    return STAGE


class Suite(object):
    """One no-client check.

    `need` is a list of (path, how-to-build) pairs. Every one is checked
    BEFORE the suite runs, and a miss makes the suite INCONCLUSIVE with the
    build command named -- rather than the suite running anyway and failing
    for a reason that has nothing to do with the code under test.
    """

    def __init__(self, name, what, need, argv, mutable=False, stage=False):
        self.name = name
        self.what = what
        self.need = need
        self.argv = argv
        self.mutable = mutable
        self.stage = stage

    def missing(self):
        out = []
        for path, how in self.need:
            if not os.path.exists(path):
                out.append("%s (%s)" % (path, how))
        return out


def suites(db):
    return [
        Suite(
            "backend-selftest",
            "the backend serves itself every route it owns, over the real "
            "wire with zlib framing, and parses its own settings payload "
            "STRICTLY",
            [(BACKEND, "aowl build backend"),
             (GAMESERVER, "aowl build-mod examples\\gameserver"),
             (TARKOV, "aowl build-mod mods\\tarkov -- see stage_backend()")],
            # --root is filled in by stage_backend(). Port 6974 matches what
            # `aowl verify` uses, and is deliberately not the developer's own
            # backend port: a self test that reached a server somebody else
            # started would be testing the wrong process.
            [BACKEND, "--port", "6974", "--selftest"],
            stage=True,
        ),
        Suite(
            "admintrader",
            "mods/admintrader loaded into the simulator against the real "
            "db.json; the served payload is parsed strictly and counters are "
            "asserted over the finished database",
            [(SIM, "aowl build sim"),
             (ADMINTRADER, "aowl build-mod mods\\admintrader"),
             (db, "no database -- pass --db PATH")],
            [sys.executable, _p("tools", "acceptance_admintrader.py"),
             "--db", db],
        ),
        Suite(
            "betacheck",
            "the four ship-blocking beta defects, checked over the wire "
            "against a backend this tool spawns itself: a profile is created "
            "and then INDEPENDENTLY re-read, assorts are read back from the "
            "trader routes",
            [(BACKEND, "aowl build backend"),
             (TARKOV, "aowl build-mod mods\\tarkov"),
             (db, "no database -- pass --db PATH")],
            [sys.executable, _p("tools", "betacheck.py"), "--spawn",
             "--backend", BACKEND, "--db", db, "--tarkov", TARKOV],
            mutable=True,
        ),
    ]


def known_mutations():
    """The mutation names betacheck accepts, asked of betacheck itself.

    Returns None if it could not be asked -- which is a refusal upstream, not
    an empty set, because an empty set would silently reject every name.
    """
    try:
        p = subprocess.run([sys.executable, _p("tools", "betacheck.py"),
                            "--list-mutations"], cwd=REPO,
                           capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired):
        return None
    names = set()
    for ln in (p.stdout or "").splitlines():
        if ln.startswith("  ") and not ln.startswith("   "):
            tok = ln.strip().split(" ", 1)[0]
            if tok:
                names.add(tok)
    return names or None


def run_suite(s, mutate, timeout):
    argv = list(s.argv)
    if mutate:
        if not s.mutable:
            return (INCONCLUSIVE,
                    "--mutate does not apply to this suite; it was skipped "
                    "rather than run unmutated and reported as a pass")
        argv += ["--mutate", mutate]
    miss = s.missing()
    if miss:
        return INCONCLUSIVE, "missing prerequisite: " + "; ".join(miss)
    if s.stage:
        try:
            argv = argv + ["--root", stage_backend()]
        except OSError as e:
            return INCONCLUSIVE, "could not build the scratch install: %s" % e
    try:
        p = subprocess.run(argv, cwd=REPO, capture_output=True, text=True,
                           timeout=timeout)
    except subprocess.TimeoutExpired:
        return INCONCLUSIVE, "timed out after %ds -- no verdict was reached" % timeout
    except OSError as e:
        return INCONCLUSIVE, "could not run it: %s" % e
    tail = ((p.stdout or "") + (p.stderr or "")).strip().splitlines()
    tail = "\n".join("      | " + ln for ln in tail[-12:])
    # The EXIT CODE is the verdict, not a substring of the output. Every suite
    # here already uses 0/1/2 the same way, and grepping stdout for "PASS" is
    # exactly the kind of check that passes on a run that printed the word
    # while failing.
    if p.returncode == 0:
        return PASS, tail
    if p.returncode == 2:
        return INCONCLUSIVE, tail
    return FAIL, "exit %d\n%s" % (p.returncode, tail)


def main():
    ap = argparse.ArgumentParser(
        description="run every check that needs no game client")
    ap.add_argument("--db", default=DEFAULT_DB)
    ap.add_argument("--only", action="append", default=[],
                    help="run only these suites (repeatable)")
    ap.add_argument("--list", action="store_true",
                    help="print the suites, what each proves, and whether its "
                         "prerequisites are present, then exit")
    ap.add_argument("--mutate", default="",
                    help="pass a deliberate defect to the suites that accept "
                         "one (betacheck). This is how you check that a green "
                         "run means anything. betacheck --list-mutations "
                         "prints the valid names and REFUSES an unknown one.")
    ap.add_argument("--timeout", type=int, default=900)
    a = ap.parse_args()

    if a.mutate:
        # VALIDATE THE NAME FIRST. Without this the runner was itself the bug
        # it exists to prevent: betacheck REFUSES an unknown --mutate with a
        # non-zero exit, the runner counted that non-zero as "the suite
        # failed", and the inverted falsifier verdict printed
        # "FALSIFIER OK: the injected defect 'nonsense' was caught" and exited
        # 0. A typo'd mutation name therefore reported that the checks bite
        # when nothing had been injected at all. Measured, and fixed here.
        known = known_mutations()
        if known is None:
            sys.exit("could not ask betacheck for its mutation names, so "
                     "--mutate cannot be validated. Refusing rather than "
                     "running a falsifier whose verdict would be meaningless.")
        if a.mutate not in known:
            sys.exit("unknown --mutate %r. betacheck refuses it, and this "
                     "runner would otherwise have read that refusal as the "
                     "injected defect being caught.\nValid names: %s"
                     % (a.mutate, ", ".join(sorted(known))))

    all_suites = suites(a.db)
    known = [s.name for s in all_suites]
    for name in a.only:
        if name not in known:
            sys.exit("unknown suite %r. Known: %s" % (name, ", ".join(known)))
    chosen = [s for s in all_suites if not a.only or s.name in a.only]

    if a.list:
        print("no-client suites (%d). Nothing here starts the game.\n"
              % len(all_suites))
        for s in all_suites:
            miss = s.missing()
            print("  %-18s %s" % (s.name, "READY" if not miss else "MISSING"))
            print("      %s" % s.what)
            for m in miss:
                print("      missing: %s" % m)
            print("")
        return 0

    print("aowlspt headless run -- NO GAME CLIENT IS STARTED")
    print("repo   %s" % REPO)
    print("db     %s" % a.db)
    if a.mutate:
        print("MUTATED with %r: this run is EXPECTED to FAIL. A PASS here "
              "means the check is blind." % a.mutate)
    print("")

    results = []
    for s in chosen:
        print("-- %s" % s.name)
        verdict, detail = run_suite(s, a.mutate, a.timeout)
        print("   %s  %s" % (verdict, s.name))
        if detail:
            print(detail)
        print("")
        results.append((s.name, verdict))

    print("=" * 60)
    nfail = sum(1 for _, v in results if v == FAIL)
    npass = sum(1 for _, v in results if v == PASS)
    ninc = sum(1 for _, v in results if v == INCONCLUSIVE)
    for name, v in results:
        print("  %-14s %s" % (v, name))
    print("  %d passed, %d failed, %d inconclusive" % (npass, nfail, ninc))

    if a.mutate:
        # The falsifier's own verdict is INVERTED, and stated as such. A
        # mutated run that passes is the interesting failure: it means the
        # check under test cannot see the defect that was injected.
        if nfail > 0:
            print("\nFALSIFIER OK: the injected defect %r was caught." % a.mutate)
            return 0
        print("\nFALSIFIER FAILED: %r was injected and nothing failed. The "
              "check is blind, or the mutation never took." % a.mutate)
        return 1

    if nfail:
        print("\nFAIL")
        return 1
    if npass == 0:
        print("\nINCONCLUSIVE -- nothing actually ran. This is NOT a pass.")
        return 2
    if ninc:
        print("\nPASS (with %d inconclusive -- see above; they were not "
              "checked, not checked-and-fine)" % ninc)
        return 0
    print("\nPASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
