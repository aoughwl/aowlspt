#!/usr/bin/env python3
r"""test_modbuild_failcache.py -- a cached failure is still a FAILURE.

    python tools/test_modbuild_failcache.py

Caching a failure is the kind of optimisation that turns into a lie if any one
of four things is wrong, so all four are checked, each with a control:

  1. an unchanged broken mod is reported FAILED without recompiling -- fast;
  2. it is still `status == "failed"`, so the loading step still shows FAILED
     and the exit code is still non-zero. A cached failure that reported
     `cached` would silently release a broken mod to the player;
  3. touching the mod's SOURCE retries it -- the record is keyed, not sticky;
  4. an UNDIAGNOSED failure is NOT cached, because those are the environmental
     ones that fix themselves.

These run against real files in a temp directory and a fake compiler, so no
nimony is required and the test takes under a second.
"""

from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import modbuild  # noqa: E402

FAILURES = []


def check(name, cond, detail=""):
    if cond:
        print("  PASS  %s" % name)
    else:
        print("  FAIL  %s   %s" % (name, detail))
        FAILURES.append(name)


DIAG = ["mgr/cfgscan.nim(47, 1) Error: file not found: jsonpath.nim"]


def main():
    print("modbuild: a cached failure is still a failure")
    tmp = tempfile.mkdtemp(prefix="failcache-")
    try:
        binp = os.path.join(tmp, "bin")
        os.makedirs(binp)
        ff = os.path.join(binp, "m.failkey")

        print("\nthe record round-trips under its key")
        ok = modbuild.write_failure(ff, "KEY1", "nimony exited 1", DIAG,
                                    "err text", "")
        check("a diagnosed failure IS recorded", ok and os.path.isfile(ff))
        rec = modbuild.read_failure(ff, "KEY1")
        check("it reads back under the same key", rec is not None)
        check("it carries the diagnostics, not just a flag",
              rec and rec.get("output") == DIAG, str(rec and rec.get("output")))
        check("it carries the raw output for investigation",
              rec and "err text" in (rec.get("raw") or ""))

        print("\nit is KEYED -- a changed input retries")
        check("a DIFFERENT key does not read the record back",
              modbuild.read_failure(ff, "KEY2") is None,
              "a sticky failure would freeze a mod as broken after it was fixed")
        # Control: prove the miss above is about the key, not about the file
        # being unreadable -- otherwise this passes for the wrong reason.
        check("...and the same key still does (control)",
              modbuild.read_failure(ff, "KEY1") is not None)

        print("\nan UNDIAGNOSED failure is NOT cached")
        ff2 = os.path.join(binp, "n.failkey")
        ok2 = modbuild.write_failure(ff2, "KEY1", "nimony exited 1", [],
                                     "some opaque noise", "")
        check("write_failure refuses an empty diagnostic list",
              not ok2 and not os.path.exists(ff2),
              "an environmental failure must be retried, not frozen")
        # Control: the same call WITH diagnostics does write, so the refusal
        # above is about the diagnostics and not about the path.
        check("...but the same path WITH diagnostics does write (control)",
              modbuild.write_failure(ff2, "KEY1", "why", DIAG, "e", "")
              and os.path.exists(ff2))

        print("\ncorrupt / absent records are misses, not crashes")
        bad = os.path.join(binp, "bad.failkey")
        with open(bad, "w", encoding="utf-8") as f:
            f.write("{not json")
        check("a corrupt record reads as a miss", modbuild.read_failure(bad, "K") is None)
        check("an absent record reads as a miss",
              modbuild.read_failure(os.path.join(binp, "nope.failkey"), "K") is None)
        with open(bad, "w", encoding="utf-8") as f:
            json.dump(["not", "a", "dict"], f)
        check("a well-formed but wrong-shaped record reads as a miss",
              modbuild.read_failure(bad, "K") is None)

        print("\nbuild_one reports it as FAILED, from cache, without compiling")
        mod = os.path.join(tmp, "brokenmod")
        os.makedirs(os.path.join(mod, "bin"))
        src = os.path.join(mod, "brokenmod.nim")
        with open(src, "w", encoding="utf-8", newline="\n") as f:
            f.write("# a mod that will not compile\n")
        abi = os.path.join(tmp, "abi")
        aowl = os.path.join(tmp, "aowl")
        os.makedirs(abi)
        os.makedirs(aowl)
        fake_nimony = os.path.join(tmp, "nimony.exe")
        with open(fake_nimony, "wb") as f:
            f.write(b"not a real compiler")

        cmd = modbuild.compile_cmd(fake_nimony, tmp, abi, aowl, mod, src,
                                   os.path.join(mod, "bin", "brokenmod.dll"))
        key = modbuild.cache_key(mod, abi, aowl, fake_nimony, cmd)
        modbuild.write_failure(os.path.join(mod, "bin", "brokenmod.failkey"),
                               key, "nimony exited 1", DIAG, "raw", "")

        res = modbuild.build_one(mod, abi, aowl, fake_nimony, tmp,
                                 force=False, check=False, verbose=False,
                                 env=dict(os.environ))
        check("status is 'failed', NOT 'cached'", res.get("status") == "failed",
              str(res))
        check("it says the verdict came from cache",
              res.get("from_cache") is True, str(res))
        check("it still carries the diagnostics", res.get("output") == DIAG,
              str(res.get("output")))
        check("no .dll was produced or implied",
              not os.path.isfile(os.path.join(mod, "bin", "brokenmod.dll")))

        # THE CONTROL THAT MATTERS: with --force the record must be ignored and
        # a real compile attempted. The fake compiler cannot run, so the result
        # is still 'failed' -- but it must NOT be from_cache.
        res2 = modbuild.build_one(mod, abi, aowl, fake_nimony, tmp,
                                  force=True, check=False, verbose=False,
                                  env=dict(os.environ))
        check("--force ignores the cached failure and really retries",
              res2.get("status") == "failed"
              and not res2.get("from_cache"), str(res2))

        # And a source edit must retry too.
        modbuild.write_failure(os.path.join(mod, "bin", "brokenmod.failkey"),
                               key, "nimony exited 1", DIAG, "raw", "")
        with open(src, "a", encoding="utf-8", newline="\n") as f:
            f.write("# edited\n")
        res3 = modbuild.build_one(mod, abi, aowl, fake_nimony, tmp,
                                  force=False, check=False, verbose=False,
                                  env=dict(os.environ))
        check("editing the source retries instead of reusing the verdict",
              not res3.get("from_cache"), str(res3))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print("\n%s -- %d failure(s)"
          % ("FAIL" if FAILURES else "PASS", len(FAILURES)))
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
