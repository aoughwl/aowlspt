#!/usr/bin/env python
"""Does the backend SURVIVE serving a raid whose boss roll KEPT something?

Why this exists
---------------
A report said `aowlspt-backend.exe` exits 1 mid-session immediately after
`boss roll: seed=woods kept=bossKojaniy`, with no game client running, and that
`kept=bossKojaniy` was "the first time the roll kept anything". The 200 is
delivered first -- Woods returned 370,131 bytes -- and the process is gone a
second later.

That last sentence is the whole problem with checking this by response code.
A check that asserts "getLocalloot returned 200" PASSES on the very run where
the process dies, because the death is after the write. So this tool asserts a
DIFFERENT, finished-state property:

    after each response, the backend PROCESS IS STILL ALIVE
    (proc.poll() is None), and at the end of the sweep it is still alive AND
    still answering a fresh request on the same socket.

Three outcomes, never two:

  PASS          every map served AND the process outlived the whole sweep AND
                at least one roll actually KEPT a boss.
  FAIL          the process is gone, or stopped answering. The last map served
                and its `kept=` line are printed, from the backend's own log.
  INCONCLUSIVE  the sweep completed with the process alive but NO roll ever
                kept a boss -- the kept-path was never exercised, so this run
                says nothing about it. "The roll kept nothing this run" is
                never a pass.

Forcing the kept-path rather than waiting for luck
--------------------------------------------------
`--force` POSTs `bossSpawnChanceMultiplier` up through the mod's own settings
route before the sweep, so every map's BossChance saturates at 1.0 and EVERY
boss map keeps its boss. That turns a 45%-per-raid coin flip into a
deterministic exercise of the branch under suspicion, and it is what makes an
INCONCLUSIVE run distinguishable from a lucky one.

`--repeat N` runs the whole map sweep N times against ONE long-lived backend,
because the reported death was mid-session -- a fresh process per map would
hide exactly the accumulation this is looking for.

Usage
-----
    python tools/bossalive.py --force --repeat 5
    python tools/bossalive.py --maps Woods --repeat 200
"""
import argparse
import json
import os
import sys
import time
import urllib.request
import urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import betacheck  # noqa: E402  -- reuse its measured staging recipe


# The client-sendable location ids, in the order `/client/locations` lists
# them. Woods is deliberately NOT last: the report has the death right after
# Woods, so anything after Woods here is the evidence that it survived.
MAPS = ["bigmap", "factory4_day", "factory4_night", "laboratory",
        "Interchange", "Labyrinth", "Lighthouse", "RezervBase", "Sandbox",
        "Sandbox_high", "Shoreline", "TarkovStreets", "Woods",
        "Sandbox_start", "laboratory_dark", "Lighthouse2"]

SETTINGS_ROUTE = "/aowlspt/settings/aowl.tarkov"


def backend_log_tail(root, n=40):
    """The backend's own last lines -- the instrument, not our narration."""
    p = os.path.join(root, "aowlspt-backend.log")
    if not os.path.isfile(p):
        return "(no aowlspt-backend.log at %s)" % p
    with open(p, "r", encoding="utf-8", errors="replace") as f:
        return "".join(f.readlines()[-n:])


def kept_lines(root):
    """Every `boss roll: ... kept=` line the backend logged, in order."""
    p = os.path.join(root, "aowlspt-backend.log")
    if not os.path.isfile(p):
        return []
    out = []
    with open(p, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            if "boss roll:" in line:
                out.append(line.strip())
    return out


def force_boss_multiplier(w, value):
    """Saturate every BossChance so the kept-path is taken on purpose.

    Returns (ok, why). A refusal is reported, never assumed to have worked --
    a silently-ignored POST here would make every later run INCONCLUSIVE while
    looking like a forced one.
    """
    body = json.dumps({"key": "bossSpawnChanceMultiplier",
                       "value": json.dumps(value)}).encode("utf-8")
    url = "http://127.0.0.1:%d%s" % (w, SETTINGS_ROUTE)
    req = urllib.request.Request(url, data=body,
                                 headers={"Content-Type": "application/json"})
    try:
        raw = urllib.request.urlopen(req, timeout=10).read()
    except Exception as e:                       # noqa: BLE001
        return False, "POST %s failed: %s" % (SETTINGS_ROUTE, e)
    txt = raw.decode("utf-8", "replace")
    if "no route" in txt:
        return False, ("%s answered `no route` -- mods/tarkov is not loaded "
                       "on this backend, so nothing could be forced"
                       % SETTINGS_ROUTE)
    # Read it BACK rather than trusting the echo: asserting our own write is
    # the check-that-cannot-fail this repo keeps producing.
    try:
        back = urllib.request.urlopen(
            "http://127.0.0.1:%d%s" % (w, SETTINGS_ROUTE), timeout=10).read()
        rows = json.loads(back.decode("utf-8", "replace"))
    except Exception as e:                       # noqa: BLE001
        return False, "could not re-read %s: %s" % (SETTINGS_ROUTE, e)
    if not isinstance(rows, list):
        return False, ("%s answered %r, not the array of rows the settings "
                       "wire is" % (SETTINGS_ROUTE, str(rows)[:120]))
    for row in rows:
        if isinstance(row, dict) and row.get("key") == \
                "bossSpawnChanceMultiplier":
            got = row.get("value")
            if str(got) in (str(value), str(float(value))):
                return True, "bossSpawnChanceMultiplier read back as %s" % got
            return False, ("bossSpawnChanceMultiplier read back as %r, not "
                           "%r -- the write did not persist" % (got, value))
    return False, ("no bossSpawnChanceMultiplier row in %s; this build does "
                   "not declare the setting" % SETTINGS_ROUTE)


def serve_one(port, loc, sess):
    """One getLocalloot. Returns (status, nbytes) or raises."""
    body = json.dumps({"locationId": loc, "variantId": 0}).encode("utf-8")
    req = urllib.request.Request(
        "http://127.0.0.1:%d/client/location/getLocalloot" % port,
        data=body,
        headers={"Content-Type": "application/json", "Cookie":
                 "PHPSESSID=" + sess})
    r = urllib.request.urlopen(req, timeout=120)
    data = r.read()
    return r.status, len(data)


def main():
    ap = argparse.ArgumentParser(
        description="assert the backend OUTLIVES a boss-kept raid response")
    ap.add_argument("--repeat", type=int, default=3,
                    help="full map sweeps against ONE long-lived backend")
    ap.add_argument("--maps", action="append", default=None,
                    help="restrict to these location ids (repeatable)")
    ap.add_argument("--force", action="store_true",
                    help="POST bossSpawnChanceMultiplier so EVERY boss map "
                         "keeps its boss, instead of waiting for a 45% roll")
    ap.add_argument("--multiplier", type=float, default=10.0)
    ap.add_argument("--db", default=None)
    ap.add_argument("--root", default=None)
    ap.add_argument("--backend", default=None)
    ap.add_argument("--tarkov", default=None)
    ap.add_argument("--port", dest="port_explicit", type=int, default=0)
    ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()

    proc, port, root = betacheck.spawn_backend(a)
    maps = a.maps or MAPS
    sess = "000000000000000000000001"

    forced = False
    if a.force:
        ok, why = force_boss_multiplier(port, a.multiplier)
        print("force: %s -- %s" % ("ok" if ok else "REFUSED", why))
        forced = ok
        if not ok:
            print("      continuing UNFORCED; a run with no kept boss will "
                  "report INCONCLUSIVE, not PASS.")

    served = 0
    total = 0
    for sweep in range(a.repeat):
        for loc in maps:
            # The response FIRST ...
            try:
                st, n = serve_one(port, loc, sess)
            except Exception as e:               # noqa: BLE001
                print("FAIL  %s: the request itself failed: %s" % (loc, e))
                print("      backend exit code: %r" % proc.poll())
                print(backend_log_tail(root))
                return 1
            served += 1
            total += n
            # ... and THEN the finished-state assertion. This ordering is the
            # entire point: the 200 is delivered before the death, so a check
            # that stops at `st == 200` passes on the failing run.
            time.sleep(0.25)
            rc = proc.poll()
            if rc is not None:
                print("FAIL  the backend EXITED with code %d after serving "
                      "%s (%d bytes, HTTP %d)." % (rc, loc, n, st))
                print("      sweep %d/%d, request %d, %d bytes served total."
                      % (sweep + 1, a.repeat, served, total))
                print("      the backend's own last lines:")
                print(backend_log_tail(root))
                return 1
            print("      %-16s HTTP %d  %9d bytes   alive" % (loc, st, n))

    # Alive is not enough: a wedged process is alive. Make it answer again.
    try:
        urllib.request.urlopen(
            "http://127.0.0.1:%d/aowlspt/status" % port, timeout=10).read()
        answering = True
    except urllib.error.HTTPError:
        answering = True
    except Exception as e:                       # noqa: BLE001
        print("FAIL  the process is alive but stopped answering: %s" % e)
        return 1

    rolls = kept_lines(root)
    kept = [ln for ln in rolls if "kept=" in ln and "kept=(none)" not in ln]
    print("")
    print("  %d request(s), %d bytes, %d boss roll(s), %d of them KEPT a boss"
          % (served, total, len(rolls), len(kept)))
    if not kept:
        print("INCONCLUSIVE  the process outlived every request and is still "
              "answering (%s), but NO roll kept a boss this run, so the "
              "kept-path was never executed. Re-run with --force."
              % ("yes" if answering else "no"))
        return 2
    print("  a kept roll, from the backend's own log:")
    print("    " + kept[-1])
    print("PASS  the backend served %d request(s) including %d boss-KEPT "
          "roll(s) and is still alive and answering. Asserted by "
          "proc.poll() is None after EVERY response, not by the response "
          "code.%s" % (served, len(kept),
                       "" if forced else " (roll not forced)"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
