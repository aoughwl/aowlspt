"""Acceptance for mods/admintrader, run offline against the real database.

    python tools\\acceptance_admintrader.py [--db D:\\Aowlspt\\aowlspt\\db.json]

Loads the mod into `aowlspt-sim` with a real `db.json`, fetches
`/admintrader/status`, parses that payload STRICTLY (`json.loads`, not a
substring test -- the backend selftest once asserted with `contains`, so a
payload that was not valid JSON at all passed for months), and asserts a
handful of counters over the finished state of the database.

Three outcomes, printed as such: PASS / FAIL / INCONCLUSIVE. "I could not
look" is INCONCLUSIVE, never PASS.
"""

import argparse
import json
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SIM = os.path.join(REPO, "host", "Aowlspt.Sim", "bin", "aowlspt-sim.exe")
MOD = os.path.join(REPO, "mods", "admintrader")
ROUTE = "/admintrader/status"


def run(db):
    if not os.path.exists(SIM):
        return None, "no aowlspt-sim.exe -- run: aowl build sim"
    if not os.path.exists(os.path.join(MOD, "bin", "admintrader.dll")):
        return None, "no admintrader.dll -- run: aowl build-mod mods\\admintrader"
    if not os.path.exists(db):
        return None, "no database at %s" % db
    p = subprocess.run([SIM, MOD, "--side", "server", "--db", db,
                        "--ticks", "1", "--route", ROUTE],
                       capture_output=True, text=True, timeout=600)
    out = p.stdout + p.stderr
    m = re.search(re.escape(ROUTE) + r" -> (\{.*)", out, re.S)
    if not m:
        return None, "the simulator never answered %s\n%s" % (ROUTE, out[-2000:])
    # STRICT. A payload that does not parse is a FAIL, not a near miss.
    try:
        return json.loads(m.group(1).strip()), None
    except ValueError as e:
        return None, "the served payload is not valid JSON: %s" % e


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default=r"D:\Aowlspt\aowlspt\db.json")
    a = ap.parse_args()

    doc, why = run(a.db)
    if doc is None:
        print("INCONCLUSIVE  %s" % why)
        return 2

    fails = []
    inconc = []

    def check(name, ok, detail):
        if ok is None:
            inconc.append("%s  (%s)" % (name, detail))
        elif ok:
            print("PASS          %s  %s" % (name, detail))
        else:
            fails.append("%s  (%s)" % (name, detail))

    listed = doc.get("listedInTradersTable")
    check("trader is in the table the trader list is built from",
          None if str(listed).startswith("unknown") else listed == "yes",
          "listedInTradersTable=%r, tradersInTable=%r"
          % (listed, doc.get("tradersInTable")))

    stored = doc.get("offersStored", 0)
    check("the assort is non-empty", stored > 0, "offersStored=%d" % stored)
    # Vacuous truth is not a pass. "No offer costs anything" is trivially true
    # of an empty assort, so with nothing stored these two are INCONCLUSIVE --
    # they were not exercised.
    check("every offer prices to zero",
          (doc.get("offersNotFree") == 0) if stored else None,
          "offersNotFree=%r over %d offers"
          % (doc.get("offersNotFree"), stored))
    check("every offer has a price at all",
          (doc.get("offersUnpriced") == 0) if stored else None,
          "offersUnpriced=%r over %d offers"
          % (doc.get("offersUnpriced"), stored))
    check("the trader has a readable name",
          bool(doc.get("traderNameLocalised")),
          "traderNameLocalised=%r" % doc.get("traderNameLocalised"))

    check("the quest is in the database", bool(doc.get("questInDatabase")),
          "questInDatabase=%r" % doc.get("questInDatabase"))
    check("the quest belongs to this trader",
          doc.get("questTrader") == doc.get("traderId"),
          "questTrader=%r" % doc.get("questTrader"))
    check("the quest can be started and finished",
          doc.get("questStartConditions", 0) > 0
          and doc.get("questFinishConditions", 0) > 0,
          "start=%r finish=%r" % (doc.get("questStartConditions"),
                                  doc.get("questFinishConditions")))
    check("the quest pays something", doc.get("questRewards", 0) > 0,
          "questRewards=%r" % doc.get("questRewards"))
    check("the quest has a readable name", bool(doc.get("questNameLocalised")),
          "questNameLocalised=%r" % doc.get("questNameLocalised"))

    for f in inconc:
        print("INCONCLUSIVE  %s" % f)
    for f in fails:
        print("FAIL          %s" % f)
    if fails:
        return 1
    if inconc:
        return 2
    print("\nall checks PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
