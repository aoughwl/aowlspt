#!/usr/bin/env python3
"""betacheck -- the four ship-blocking beta defects, checked over the wire.

Every check here is an INDEPENDENT RE-READ: nothing asserts on the response to
the write that made the thing.  A profile is created through the launcher route
and then read back from `/client/game/profile/list`; a trader assort is read
from `/client/trading/api/getTraderAssort/<id>`.  Every body is parsed
STRICTLY (`json.loads`), because the backend has shipped documents that were
not valid JSON at all and a `contains` check passed them for months.

Each check states PASS / FAIL / INCONCLUSIVE, never two outcomes.  "The server
did not answer" is INCONCLUSIVE, not a pass.

The expected numbers are read from SPT's own `templates/profiles.json` at run
time rather than written down here -- a constant copied out of the table cannot
detect the table changing, and a check that compares our output to our own
constant is the failure mode this file exists to avoid.

    python tools/betacheck.py --port 7788 --spt D:\\SPT
    python tools/betacheck.py --port 7788 --spt D:\\SPT --mutate inventory

`--mutate` runs a deliberately wrong variant to prove a check can FAIL:

    inventory  compare the served count against the WRONG edition's template
    traders    accept an all-1s loyalty distribution as gated
    tradersinfo  accept an empty TradersInfo
    edition    compare EoD against the standard template
"""

import argparse
import http.client
import json
import os
import random
import sys
import zlib

OK, FAIL, INCONC = "PASS", "FAIL", "INCONCLUSIVE"
JAEGER = "5c0647fdd443bc2504c2d371"
PRAPOR = "54cb50c76803fa8b248b4571"

results = []


def record(name, verdict, detail):
    results.append((name, verdict, detail))
    print("%-14s %-12s %s" % (verdict, name, detail))


class Wire:
    def __init__(self, port):
        self.port = port

    def call(self, path, body=None, session=""):
        """A route call.  Returns (status, parsed-json-or-None, raw-text).

        `Accept-Encoding: identity` is not optional: the backend deflates
        everything otherwise (fact #123) and the raw bytes are then a zlib
        stream, not JSON.  Both are handled, because a header the server
        ignores would otherwise look like a broken route.
        """
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=30)
        payload = b"" if body is None else json.dumps(body).encode()
        headers = {
            "Accept-Encoding": "identity",
            "Content-Type": "application/json",
            "Cookie": "PHPSESSID=" + session,
        }
        c.request("POST", path, payload, headers)
        r = c.getresponse()
        raw = r.read()
        c.close()
        if raw[:2] in (b"\x78\x01", b"\x78\x9c", b"\x78\xda"):
            raw = zlib.decompress(raw)
        text = raw.decode("utf-8", "replace")
        try:
            return r.status, json.loads(text), text
        except Exception:
            return r.status, None, text


def envelope(doc):
    """`data` out of the client envelope, or the document itself."""
    if isinstance(doc, dict) and "data" in doc and "err" in doc:
        return doc["data"]
    return doc


def spt_template(spt, edition, side):
    path = os.path.join(spt, "SPT_Runtime", "SPT_Data", "database",
                        "templates", "profiles.json")
    if not os.path.exists(path):
        path = os.path.join(spt, "SPT_Data", "database", "templates",
                            "profiles.json")
    with open(path, encoding="utf-8") as f:
        d = json.load(f)
    return d[edition][side]["character"], d[edition][side]["trader"]


def session_of(doc):
    """The session token out of a launcher create reply.

    The launcher routes answer a BARE object (`ok`/`token`/`profile`), not the
    client envelope, so `envelope()` alone does not reach it.
    """
    d = envelope(doc)
    if not isinstance(d, dict):
        return ""
    for k in ("token", "profileId", "id"):
        if isinstance(d.get(k), str) and d[k]:
            return d[k]
    prof = d.get("profile")
    if isinstance(prof, dict):
        for k in ("token", "id", "profileId"):
            if isinstance(prof.get(k), str) and prof[k]:
                return prof[k]
    return ""


def make_profile(w, nickname, edition):
    st, doc, text = w.call("/aowlspt/tarkov/launcher/profile/create",
                           {"nickname": nickname, "side": "Usec",
                            "edition": edition})
    return st, doc, text


def read_back(w, session):
    """The profile as the CLIENT sees it -- never the create response."""
    st, doc, text = w.call("/client/game/profile/list", {}, session)
    if doc is None:
        return None, "the profile list did not parse as JSON (%d bytes)" % len(text)
    data = envelope(doc)
    if not isinstance(data, list) or not data:
        return None, "the profile list is not a non-empty array"
    # The PMC of THIS session, by id.  Picking "the first PMC in the list" is
    # what made an Edge Of Darkness check read a Standard profile created
    # earlier in the same run and report GameVersion=standard -- a real-looking
    # failure with no defect behind it.
    for p in data:
        if p.get("_id") == session and            p.get("Info", {}).get("Side") in ("Usec", "Bear"):
            return p, ""
    for p in data:
        if p.get("Info", {}).get("Side") in ("Usec", "Bear"):
            return None, ("the profile list has PMCs but none with _id %s "
                          "-- refusing to read someone else's" % session)
    return None, "no PMC in the profile list"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=7788)
    ap.add_argument("--spt", default="D:\\SPT")
    ap.add_argument("--mutate", default="")
    a = ap.parse_args()
    w = Wire(a.port)
    mut = a.mutate

    tag = "%04d" % random.randrange(10000)

    # ---------------------------------------------------------------- 1 + 2
    std_char, std_trader = spt_template(a.spt, "Standard", "usec")
    eod_char, _ = spt_template(a.spt, "Edge Of Darkness", "usec")
    want_std = len(std_char["Inventory"]["items"])
    want_eod = len(eod_char["Inventory"]["items"])

    st, doc, text = make_profile(w, "Beta" + tag, "standard")
    if doc is None:
        record("inventory", INCONC, "create did not answer JSON: %r" % text[:120])
        record("edition", INCONC, "no profile to read")
        record("tradersinfo", INCONC, "no profile to read")
    else:
        session = session_of(doc)
        if not session:
            record("inventory", INCONC,
                   "create gave no profile id: %s" % json.dumps(doc)[:160])
            session = ""
        p, why = read_back(w, session) if session else (None, "no session")
        if p is None:
            record("inventory", INCONC, why)
            record("edition", INCONC, why)
            record("tradersinfo", INCONC, why)
        else:
            got = len(p.get("Inventory", {}).get("items", []))
            expect = want_eod if mut == "inventory" else want_std
            gv = p.get("Info", {}).get("GameVersion")
            # A negative, so it can be falsified: no slot SPT's template
            # equips may be missing from what was served.
            want_slots = set(i.get("slotId") for i in
                             std_char["Inventory"]["items"]
                             if i.get("parentId") ==
                             std_char["Inventory"]["equipment"])
            got_slots = set(i.get("slotId") for i in
                            p.get("Inventory", {}).get("items", [])
                            if i.get("parentId") ==
                            p.get("Inventory", {}).get("equipment"))
            missing = sorted(x for x in want_slots - got_slots if x)
            ids = [i.get("_id") for i in p.get("Inventory", {}).get("items", [])]
            dupes = len(ids) - len(set(ids))
            if got != expect:
                record("inventory", FAIL,
                       "served %d items, SPT's template has %d" % (got, expect))
            elif missing:
                record("inventory", FAIL,
                       "equipped slots missing: %s" % ",".join(missing))
            elif dupes:
                record("inventory", FAIL,
                       "%d duplicate _id(s) in the served inventory" % dupes)
            else:
                record("inventory", OK,
                       "%d items, all %d slots equipped, ids unique, "
                       "GameVersion=%s" % (got, len(want_slots), gv))

            ti = p.get("TradersInfo")
            if mut == "tradersinfo":
                ti = {}   # what the backend used to write, so the check fails
            if not isinstance(ti, dict) or not ti:
                record("tradersinfo", FAIL,
                       "TradersInfo is %s" % json.dumps(ti)[:60])
            else:
                want_loy = std_trader["initialLoyaltyLevel"]
                bad = [t for t, v in want_loy.items()
                       if t in ti and ti[t].get("loyaltyLevel") != v]
                jaeger = ti.get(JAEGER, {})
                if bad:
                    record("tradersinfo", FAIL,
                           "loyaltyLevel disagrees with the template for %s"
                           % ",".join(bad[:3]))
                elif jaeger and jaeger.get("unlocked") is not False:
                    record("tradersinfo", FAIL,
                           "Jaeger is unlocked on a fresh profile "
                           "(template says jaegerUnlocked:false)")
                else:
                    record("tradersinfo", OK,
                           "%d traders seeded, Jaeger unlocked=%s"
                           % (len(ti), jaeger.get("unlocked")))

    # ----------------------------------------------------------------- 2
    st, doc, text = make_profile(w, "Eod" + tag, "edge_of_darkness")
    if doc is None:
        record("edition", INCONC, "EoD create did not answer JSON")
    else:
        session = session_of(doc)
        p, why = read_back(w, session) if session else (None, "no session")
        if p is None:
            record("edition", INCONC, why)
        else:
            got = len(p.get("Inventory", {}).get("items", []))
            expect = want_std if mut == "edition" else want_eod
            gv = p.get("Info", {}).get("GameVersion")
            stash = [b for b in p.get("Bonuses", [])
                     if b.get("type") == "StashSize"]
            want_stash = [b for b in eod_char["Bonuses"]
                          if b.get("type") == "StashSize"]
            if gv != "edge_of_darkness":
                record("edition", FAIL, "GameVersion reads %r" % gv)
            elif got != expect:
                record("edition", FAIL,
                       "served %d items, EoD's template has %d" % (got, expect))
            elif len(stash) != len(want_stash):
                record("edition", FAIL,
                       "%d StashSize bonus(es), EoD's template has %d"
                       % (len(stash), len(want_stash)))
            else:
                record("edition", OK,
                       "GameVersion=%s, %d items, %d StashSize bonuses "
                       "(standard has %d items)"
                       % (gv, got, len(stash), want_std))

    # An edition the server cannot build must be REFUSED, not downgraded.
    st, doc, text = make_profile(w, "Bogus" + tag, "no_such_edition")
    if doc is None:
        record("edition-refusal", INCONC, "no JSON answer")
    else:
        d = envelope(doc)
        refused = (doc.get("err") not in (0, None)) or \
                  (isinstance(d, dict) and d.get("ok") is False) or \
                  (isinstance(d, dict) and "problem" in d)
        if refused:
            record("edition-refusal", OK, "refused: %s" % json.dumps(d)[:100])
        else:
            record("edition-refusal", FAIL,
                   "accepted an unknown edition: %s" % json.dumps(d)[:120])

    # ----------------------------------------------------------------- 3
    st, doc, text = w.call("/client/trading/api/getTraderAssort/" + PRAPOR,
                           {}, "")
    if doc is None:
        record("loyalty-gate", INCONC,
               "the assort did not parse as JSON (%d bytes)" % len(text))
    else:
        lli = envelope(doc).get("loyal_level_items")
        if not isinstance(lli, dict) or not lli:
            record("loyalty-gate", INCONC,
                   "Prapor's assort has no loyal_level_items")
        else:
            vals = list(lli.values())
            above1 = sum(1 for v in vals if v != 1)
            if mut == "traders":
                # The mutation must make the check FAIL, not pass: pretend the
                # distribution is the all-1s one the sandbox default produced.
                above1 = 0
            if above1 == 0:
                record("loyalty-gate", FAIL,
                       "all %d loyal_level_items entries are 1 -- every "
                       "offer is buyable at level 1" % len(vals))
            else:
                hist = {}
                for v in vals:
                    hist[v] = hist.get(v, 0) + 1
                record("loyalty-gate", OK,
                       "%d entries, distribution %s" %
                       (len(vals), json.dumps(hist, sort_keys=True)))

    print()
    bad = [r for r in results if r[1] != OK]
    print("%d check(s), %d not PASS" % (len(results), len(bad)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
