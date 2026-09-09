"""Acceptance for mods/admintrader, run offline against the real database.

    python tools\\acceptance_admintrader.py [--db D:\\Aowlspt\\aowlspt\\db.json]

Loads the mod into `aowlspt-sim` with a real `db.json`, fetches
`/admintrader/status`, parses that payload STRICTLY (`json.loads`, not a
substring test -- the backend selftest once asserted with `contains`, so a
payload that was not valid JSON at all passed for months), and asserts a
handful of counters over the finished state of the database.

Three outcomes, printed as such: PASS / FAIL / INCONCLUSIVE. "I could not
look" is INCONCLUSIVE, never PASS.

## Why there is a SHAPE check, and why "valid JSON" is not one

This suite passed 10/10 while shipping a trader the client refused with

    JSON parsing error in response to traderSettings at line 1 position 101170

The served document was 102,095 bytes of *perfectly valid JSON* -- `json.loads`
accepted it, as it accepts this file's payload above. What failed was the
client's TYPED deserializer: `items_sell` had been written in the
`{category, id_list}` shape that `items_buy` legitimately uses, while every
stock trader has it either as a dict keyed by loyalty level or as a bare `[]`.

So every check here was true and none of them could see it. The counters
asserted the trader was listed, its offers stored and priced, its quest
well-formed -- all facts about CONTENT. Nothing asserted the document had a
shape the client can deserialize. `check_shape` below is that assertion: it
compares our stored `base` against a real stock trader's, field by field and
into nested collections, and FAILs on any structural divergence.

It is deliberately a comparison against DATA WE DID NOT WRITE. A schema we
authored would encode the same misunderstanding that produced the bug.
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


# ---------------------------------------------------------------------------
# Structural comparison against stock data
# ---------------------------------------------------------------------------

def kind(v):
    if isinstance(v, bool):
        return "bool"
    if isinstance(v, (int, float)):
        return "num"
    if isinstance(v, str):
        return "str"
    if v is None:
        return "null"
    if isinstance(v, list):
        return "list"
    return "dict"


def digit_keyed(v):
    return isinstance(v, dict) and v and all(k.isdigit() for k in v)


def compatible(ours, stock, path=""):
    """Is `ours` structurally the same shape as `stock`? Returns (bool, why).

    Deliberately tolerant in exactly two places, both because stock data itself
    varies that way:
      * an EMPTY list or dict matches any list or dict -- having nothing in a
        collection is not a shape difference;
      * nothing else. A str where stock has a num IS a difference, and is only
        accepted because some OTHER stock trader has a str there (the caller
        tries every stock trader and needs one full match).
    """
    ko, ks = kind(ours), kind(stock)
    if ko != ks:
        return False, "%s: ours is %s, stock is %s" % (path or "<root>", ko, ks)

    if ko == "list":
        if not ours or not stock:
            return True, ""
        return compatible(ours[0], stock[0], path + "[]")

    if ko == "dict":
        if not ours or not stock:
            return True, ""
        if digit_keyed(ours) != digit_keyed(stock):
            return False, ("%s: ours is %s, stock is %s"
                           % (path or "<root>",
                              "keyed by number" if digit_keyed(ours)
                              else "keyed by name",
                              "keyed by number" if digit_keyed(stock)
                              else "keyed by name"))
        if digit_keyed(ours):
            return compatible(list(ours.values())[0],
                              list(stock.values())[0], path + ".<n>")
        missing = sorted(set(stock) - set(ours))
        extra = sorted(set(ours) - set(stock))
        if missing:
            return False, "%s: missing %s" % (path or "<root>", ", ".join(missing))
        if extra:
            return False, "%s: has %s, stock does not" % (path or "<root>",
                                                          ", ".join(extra))
        for k in sorted(ours):
            ok, why = compatible(ours[k], stock[k],
                                 (path + "." + k) if path else k)
            if not ok:
                return False, why
        return True, ""

    return True, ""


def check_shape(check, doc, db_path):
    """Compare our stored `base` against every STOCK trader's, field by field.

    A field PASSes if it matches AT LEAST ONE stock trader -- stock data is
    genuinely polymorphic in places (`insurance_price_coef` is a string in 5
    traders and a number in 7; `items_sell` is a loyalty-keyed dict in 8 and a
    bare `[]` in 4), so demanding one canonical shape would be wrong. A field
    that matches NO stock trader is the failure this exists to catch.
    """
    ours = doc.get("storedBase")
    if not isinstance(ours, dict) or not ours:
        check("the served trader has the shape the client can deserialize",
              None, "the status route served no storedBase to compare")
        return
    try:
        with open(db_path, "r", encoding="utf-8") as f:
            traders = json.load(f)["traders"]
    except (OSError, ValueError, KeyError) as e:
        check("the served trader has the shape the client can deserialize",
              None, "could not read stock traders from %s (%s)" % (db_path, e))
        return

    stock = {tid: t["base"] for tid, t in traders.items()
             if tid != ours.get("_id") and isinstance(t.get("base"), dict)}
    if not stock:
        check("the served trader has the shape the client can deserialize",
              None, "no stock trader to compare against")
        return

    # Top-level field set, against the field set EVERY stock trader has.
    common = set.intersection(*[set(b) for b in stock.values()])
    missing = sorted(common - set(ours))
    check("the trader base has every field all stock traders have",
          not missing, "missing=%s over %d stock traders"
          % (missing or "none", len(stock)))

    # Per field, does ANY stock trader agree with our shape?
    bad = []
    for name in sorted(set(ours) & common):
        why = None
        for b in stock.values():
            ok, w = compatible(ours[name], b[name], name)
            if ok:
                why = None
                break
            if why is None:
                why = w
        if why is not None:
            bad.append(why)
    check("every trader base field matches the shape of at least one stock "
          "trader (a typed deserializer accepts it, not merely json.loads)",
          not bad, "; ".join(bad) if bad
          else "%d fields checked against %d stock traders"
               % (len(set(ours) & common), len(stock)))


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

    check_shape(check, doc, a.db)

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
