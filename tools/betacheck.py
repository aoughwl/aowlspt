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
    quests     describe the startable quests as Locked, then accept them
    queststatus  strip the `status` key, as the stored SPT templates do
    hideout    remove area 21 from the profile, as the old constant did
    fence      report Fence's generated assort as empty
    descriptor add a ProfileDescriptor member we correctly never serve on this
               route, which MUST turn the descriptor check red
    lootpos    demand a NON-zero Position on static containers -- which BSG's
               own captured match/local/start does NOT send -- so a correct
               server must go red
    lootmap    add `Icebreaker` to the set of ids REQUIRED to serve loot.
               It is in the post-1.0 location table the real server sent us
               but has no database entry and no parent map to inherit one, so
               a correct server cannot answer it and must go red
    lootloose  raise every map's floor by its whole probabilistic spawn
               point count, so a correct server -- which rolls each point
               against its own probability -- must go red
"""

import argparse
import http.client
import json
import os
import random
import subprocess
import sys
import time
import zlib

OK, FAIL, INCONC = "PASS", "FAIL", "INCONCLUSIVE"
JAEGER = "5c0647fdd443bc2504c2d371"

# Members of the client's `EFT.ProfileDescriptor` that `/client/game/profile/list`
# must carry, with the wire name the [JsonProperty] attribute gives them.
#
# THIS LIST IS A CONSTANT HERE AND THAT IS A LIMITATION, stated rather than
# hidden: a check that compares our output to our own constant cannot notice
# the constant going stale.  The AUTHORITY is `tools/oursample.py`, which
# derives the whole member set from the decrypted global-metadata and diffs it
# against our own served payload; these three are the rows it reported as
# EXPECTED-BUT-MISSING on 2026-08-27.  betacheck's narrower job is to prove
# they are on the wire, on a re-read, and are not null.
#
# `Bonuses` is a real member of the profile document and IS served; the mutant
# below asks instead for `BTRLocalSettings`, which is a member of
# EFT.GlobalConfiguration and has no business on this route -- so the mutated
# run demands something genuinely absent and MUST go red.  That is the input
# which makes this check fail.
DESCRIPTOR_MEMBERS = ["CheckedChambers", "CheckedMagazines", "karmaValue"]
MUTANT_MEMBER = "BTRLocalSettings"
PRAPOR = "54cb50c76803fa8b248b4571"
# The map the ONE captured match/local/start body covers, so our served payload
# is compared against BSG's on the same location and nothing else.
LOOT_MAP = "Sandbox_start"
# A map the generator DOES answer for, so the Position-shape assertion is not
# silently skipped by the unrelated Sandbox_start mapping defect above.
LOOT_SHAPE_MAP = "sandbox"

# Every location id the CLIENT can put in `/client/match/local/start`, which is
# `base.Id` -- NOT the database key.  Measured from the captured request body
# (raid1/requests/158.json names the map "Sandbox_start", an `Id`) and from the
# `Id` member of all 24 maps in `mods/tarkov/data/post1/locations.json`, which
# is the table the real server sent this build.
#
# `LOOT_BEARING` are the ones whose database entry carries static loot tables,
# so an empty `Loot` for one of them is a DEFECT.  The rest -- develop,
# hideout, Private Area, Suburdbs, Terminal, Town -- have a `base` and nothing
# else in the database, and `Icebreaker` has no database entry at all, so an
# empty list for those is the CORRECT answer and asserting otherwise would be
# a check that fails on correct behaviour.
CLIENT_LOCATION_IDS = [
    "bigmap", "factory4_day", "factory4_night", "laboratory", "Interchange",
    "Labyrinth", "Lighthouse", "RezervBase", "Sandbox", "Sandbox_high",
    "Shoreline", "TarkovStreets", "Woods",
    # Variants: their own Id and _Id, sharing a parent map's `Name`.
    "Sandbox_start", "laboratory_dark", "Lighthouse2",
]
LOOT_BEARING = set(CLIENT_LOCATION_IDS)

# Ids the client can send that the database has NOTHING for, directly or by
# `Name`.  An empty `Loot` for these is correct, and `--mutate lootmap` demands
# loot for one of them precisely so that a correct server goes red.
UNMAPPABLE_IDS = ["Icebreaker", "Terminal_ui", "develop", "hideout",
                  "Private Area", "Suburbs", "Terminal", "Town"]
FENCE = "579dc571d53a0658a154fbec"

results = []


def _pid_on_port(port):
    """The pid listening on `port`, or None. `netstat -ano` rather than a
    dependency: this file has none and is not going to grow one for a number
    Windows already prints."""
    if os.name != "nt":
        return None
    try:
        out = subprocess.check_output(["netstat", "-ano", "-p", "TCP"],
                                      stderr=subprocess.DEVNULL).decode("latin1")
    except Exception:
        return None
    for line in out.splitlines():
        f = line.split()
        if len(f) >= 5 and f[3] == "LISTENING" and f[1].endswith(":%d" % port):
            try:
                return int(f[4])
            except ValueError:
                return None
    return None


def _working_set_mb(pid):
    """WorkingSet64, in MB, or None if the process cannot be opened."""
    import ctypes
    from ctypes import wintypes

    class _PMC(ctypes.Structure):
        _fields_ = [("cb", wintypes.DWORD), ("PageFaultCount", wintypes.DWORD),
                    ("PeakWorkingSetSize", ctypes.c_size_t),
                    ("WorkingSetSize", ctypes.c_size_t),
                    ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
                    ("QuotaPagedPoolUsage", ctypes.c_size_t),
                    ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
                    ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
                    ("PagefileUsage", ctypes.c_size_t),
                    ("PeakPagefileUsage", ctypes.c_size_t)]

    h = ctypes.windll.kernel32.OpenProcess(0x1000, False, pid)
    if not h:
        return None
    m = _PMC()
    m.cb = ctypes.sizeof(m)
    ok = ctypes.windll.psapi.GetProcessMemoryInfo(h, ctypes.byref(m), m.cb)
    ctypes.windll.kernel32.CloseHandle(h)
    if not ok:
        return None
    return m.WorkingSetSize / (1024.0 * 1024.0)


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
    ap.add_argument("--loose-dir", default="",
                    help="where the backend reads per-map looseLoot "
                         "sidecars from (default <repo>/build/db/looseloot)")
    a = ap.parse_args()
    w = Wire(a.port)
    mut = a.mutate

    tag = "%04d" % random.randrange(10000)
    std_session = ""
    std_profile = None

    # ---------------------------------------------------------------- 1 + 2
    # `a` is the argparse namespace for the whole of main(). Two loops below
    # used to rebind it -- one comprehension variable, one assort body -- so
    # every later `a.spt` / `a.port` died with AttributeError, and the
    # workaround was this local. They are `ar` and `assort` now; `spt_root`
    # stays because it reads better than `a.spt` at seven call sites.
    spt_root = a.spt
    loose_dir = a.loose_dir or os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "build", "db", "looseloot")
    std_char, std_trader = spt_template(spt_root, "Standard", "usec")
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
        std_session = session
        p, why = read_back(w, session) if session else (None, "no session")
        std_profile = p
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

    # ----------------------------------------------------------------- 4
    # BLOCKER 1 -- a fresh profile with no startable quest.
    #
    # Two independent negatives, because the cheap one cannot fail for the
    # right reason on its own:
    #
    #   (a) no quest is served WITHOUT a `status` key.  A missing key and
    #       `status: 0` are different documents to a deserialiser, and the
    #       stored SPT templates omit the key on 50 of 558.
    #   (b) NO QUEST THE SERVER WOULD ACCEPT IS SERVED AS LOCKED.  This is the
    #       one that matters and the one that can fail: it asks the server to
    #       accept quests it has just described as unstartable, and every
    #       acceptance is a contradiction in what it served.
    #
    # (b) mutates the profile it runs against, so it gets its OWN profile.
    st, doc, text = make_profile(w, "Quest" + tag, "standard")
    qsession = session_of(doc) if doc else ""
    if qsession:
        st, doc, text = w.call("/client/quest/list", {}, qsession)
    else:
        doc, text = None, ""
    quests = envelope(doc) if doc else None
    if not isinstance(quests, list) or not quests:
        record("quest-entry", INCONC,
               "/client/quest/list did not answer a non-empty array "
               "(%d bytes)" % len(text))
    else:
        nokey = [q.get("_id") for q in quests if "status" not in q]
        avail = [q for q in quests if q.get("status") == 1]
        locked = [q.get("_id") for q in quests if q.get("status") == 0]
        if mut == "queststatus":
            # Half of the PRE-FIX payload: the 50 stored templates that carry
            # no `status` key at all.  Proves negative (a) can fail.
            nokey = [q.get("_id") for q in avail][:50]
        if mut == "quests":
            # Reproduce the PRE-FIX payload: SPT's stored templates, where
            # `status` is a static field -- 0 on most and absent on the rest,
            # neither having anything to do with the player.  Both negatives
            # must then fire: (a) on the stripped keys, and (b) because the
            # 14 the server really will accept are described as Locked.
            avail_ids = [q.get("_id") for q in avail]
            locked = avail_ids + locked
        accepted = []
        for qid in locked[:40]:
            _, d2, _ = w.call("/client/game/profile/items/moving",
                              {"data": [{"Action": "QuestAccept", "qid": qid}],
                               "tm": 0, "reload": 0}, qsession)
            d2 = envelope(d2) if d2 else None
            if not isinstance(d2, dict):
                continue
            warns = d2.get("warnings")
            if not warns and d2.get("profileChanges"):
                accepted.append(qid)
        if nokey:
            record("quest-entry", FAIL,
                   "%d quest(s) served with NO status key, e.g. %s"
                   % (len(nokey), nokey[0]))
        elif accepted:
            record("quest-entry", FAIL,
                   "%d quest(s) served as Locked that the server ACCEPTED, "
                   "e.g. %s" % (len(accepted), accepted[0]))
        elif not avail:
            record("quest-entry", FAIL,
                   "%d quests served and not one is AvailableForStart"
                   % len(quests))
        else:
            record("quest-entry", OK,
                   "%d quests, %d AvailableForStart, every one carries a "
                   "status key, %d probed Locked quests all refused"
                   % (len(quests), len(avail), len(locked[:40])))

    # ----------------------------------------------------------------- 5
    # BLOCKER 2 -- hideout area type 21 absent from every new profile.
    #
    # The negative is general, not a test for 21: no area the server SERVES as
    # enabled may be missing from the profile it just created.  A check that
    # looked for `21` specifically could not detect area 28 being added.
    st, doc, text = w.call("/client/hideout/areas", {}, std_session)
    served = envelope(doc) if doc else None
    if not isinstance(served, list) or not served:
        record("hideout-areas", INCONC,
               "/client/hideout/areas did not answer a non-empty array")
    elif std_profile is None:
        record("hideout-areas", INCONC, "no fresh profile to compare against")
    else:
        want = set(ar["type"] for ar in served
                   if ar.get("enabled") and "type" in ar)
        got = set(ar["type"] for ar in
                  std_profile.get("Hideout", {}).get("Areas", [])
                  if "type" in ar)
        if mut == "hideout":
            got.discard(21)   # what the old 27-entry constant produced
        absent = sorted(want - got)
        if absent:
            record("hideout-areas", FAIL,
                   "%d enabled area type(s) served but absent from the fresh "
                   "profile: %s" % (len(absent), absent))
        else:
            record("hideout-areas", OK,
                   "%d enabled area types served, all present among the %d on "
                   "the fresh profile" % (len(want), len(got)))

    # ----------------------------------------------------------------- 6
    # BLOCKER 3 -- traders serving a permanently empty shop.
    #
    # The negative: no trader the client can already reach may serve a
    # zero-item assort unless this file names a REASON.  The allowlist is the
    # point of the check, not a hole in it -- adding to it is a deliberate,
    # reviewable statement that an empty shelf is correct for that trader.
    EMPTY_OK = {
        "638f541a29ffd1183d187f57":
            "Ref trades for GP coins, an Arena currency this server has no "
            "source of; a rouble-priced Ref would be a fabrication",
    }
    st, doc, text = w.call("/client/trading/api/traderSettings", {},
                           std_session)
    bases = envelope(doc) if doc else None
    if not isinstance(bases, list) or not bases:
        record("trader-assort", INCONC, "traderSettings answered no traders")
    else:
        probe = [b for b in bases if b.get("unlockedByDefault")]
        probe += [b for b in bases if b.get("_id") == FENCE
                  and not b.get("unlockedByDefault")]
        silent = []
        checked = 0
        fence_items = -1
        fence_unpriced = 0
        for b in probe:
            tid = b.get("_id")
            _, d3, _ = w.call("/client/trading/api/getTraderAssort/" + tid,
                              {}, std_session)
            assort = envelope(d3) if d3 else None
            if not isinstance(assort, dict):
                continue
            checked += 1
            its = assort.get("items") or []
            if tid == FENCE:
                fence_items = len(its)
                scheme = assort.get("barter_scheme") or {}
                lvl = assort.get("loyal_level_items") or {}
                if mut == "fence":
                    fence_items = 0
                # No Fence offer may lack a price or a loyalty entry -- a
                # generated item the client cannot buy is worse than none.
                fence_unpriced = sum(
                    1 for i in its
                    if not scheme.get(i.get("_id"))
                    or i.get("_id") not in lvl)
            if not its and tid not in EMPTY_OK:
                silent.append(b.get("nickname") or tid)
        if fence_items < 0:
            record("trader-assort", INCONC,
                   "Fence's assort never answered")
        elif fence_items == 0:
            record("trader-assort", FAIL,
                   "Fence serves a zero-item assort -- SPT does not ship his "
                   "stock, it must be generated")
        elif fence_unpriced:
            record("trader-assort", FAIL,
                   "%d of Fence's %d offers have no barter_scheme or no "
                   "loyal_level_items entry" % (fence_unpriced, fence_items))
        elif silent:
            record("trader-assort", FAIL,
                   "%d reachable trader(s) serve an empty assort with no "
                   "stated reason: %s" % (len(silent), ", ".join(silent[:4])))
        else:
            record("trader-assort", OK,
                   "%d reachable trader(s) checked, Fence generates %d fully "
                   "priced offers, %d empty-by-design and named"
                   % (checked, fence_items, len(EMPTY_OK)))
    # ----------------------------------------------------------------- 7
    # ProfileDescriptor members, asserted as a NEGATIVE on the finished
    # document that was READ BACK -- never on the create response.
    st, doc, text = make_profile(w, "Desc" + tag, "standard")
    session = session_of(doc) if doc else ""
    p, why = read_back(w, session) if session else (None, "no session")
    if p is None:
        record("descriptor", INCONC, why or "no profile to read")
    else:
        want = list(DESCRIPTOR_MEMBERS)
        if mut == "descriptor":
            want.append(MUTANT_MEMBER)
        absent = [m for m in want if m not in p]
        null = [m for m in want if m in p and p[m] is None]
        if absent:
            record("descriptor", FAIL,
                   "ProfileDescriptor member(s) absent from the served "
                   "profile: %s" % ", ".join(absent))
        elif null:
            # null and absent are the same thing to Newtonsoft for a reference
            # type, so a null must not read as present.
            record("descriptor", FAIL,
                   "ProfileDescriptor member(s) served as null: %s"
                   % ", ".join(null))
        else:
            record("descriptor", OK,
                   "%s all present and non-null (%s)"
                   % (", ".join(want),
                      ", ".join("%s=%s" % (m, json.dumps(p[m])[:20])
                                for m in want)))

    # ----------------------------------------------------------------- 8
    # locationLoot Position shape, asserted as a NEGATIVE against BSG's OWN
    # captured `/client/match/local/start` body (raid1/responses/158.json).
    #
    # MEASURED there, not assumed: all 41 `IsContainer` entries carry Position
    # (0,0,0) and all 94 non-container entries carry a NON-zero Position.  So
    # a zero on a container is CORRECT -- the client resolves a container by
    # its `Id` against the loaded scene, and 96-100% of every map's container
    # Ids exist verbatim in the client's own levelN files.  A zero on a LOOSE
    # entry is the real defect, and serving zero loose entries at all is the
    # hole this check names.
    #
    # The falsifying input: `--mutate lootpos` demands a NON-zero Position on
    # containers, which BSG itself does not send, so the mutated run must go
    # red on a correct server.
    def _start(loc):
        st, doc, text = w.call("/client/match/local/start",
                               {"serverId": None, "location": loc,
                                "timeVariant": "CURR", "mode": "TUTORIAL",
                                "playerSide": "Pmc", "transitionType": 0,
                                "transition": None},
                               session=std_session)
        body = envelope(doc) if doc else None
        if not isinstance(body, dict):
            return None, text
        return body.get("locationLoot", {}).get("Loot"), text

    # 8a -- parity with BSG on the ONE request body we actually captured.
    if not std_session:
        record("lootparity", INCONC, "no session to start a raid with")
    else:
        loot, text = _start(LOOT_MAP)
        if loot is None:
            record("lootparity", INCONC,
                   "match/local/start gave no locationLoot.Loot: %s"
                   % text[:140])
        elif not loot:
            record("lootparity", FAIL,
                   "location %r served an EMPTY locationLoot.Loot; BSG's "
                   "captured answer to this exact body (158.json) has 135 "
                   "entries. The raid id is not being mapped to a db location."
                   % LOOT_MAP)
        else:
            record("lootparity", OK,
                   "%r served %d loot entries (BSG's capture has 135)"
                   % (LOOT_MAP, len(loot)))

    # 8a2 -- THE GENERAL NEGATIVE, over every id the client can send.
    #
    # "No location id the client can send serves an empty `Loot` when its
    # database location has entries."  Stated as a negative on purpose: the
    # positive form ("Sandbox_start serves loot") is one string and was
    # special-cased away twice.
    #
    # This is the check that would have caught the real size of the hole.
    # MEASURED on this backend with the fix reverted: TEN of the thirteen
    # loot-bearing maps served ZERO -- Interchange, Labyrinth, Lighthouse,
    # RezervBase, Sandbox, Sandbox_high, Shoreline, TarkovStreets, Woods and
    # Sandbox_start -- because the id resolver matched only the database key
    # and `base._Id`, never the `base.Id` the client actually sends.  Only
    # bigmap, factory4_day, factory4_night and laboratory happened to spell
    # the key and the `Id` identically, which is why "loot works" was
    # believed: Customs, Factory and Labs are the maps people test on.
    if not std_session:
        record("lootmap", INCONC, "no session to start a raid with")
    else:
        want = list(CLIENT_LOCATION_IDS)
        if mut == "lootmap":
            want.append("Icebreaker")
        empty, unread = [], []
        for loc in want:
            loot, text = _start(loc)
            if loot is None:
                unread.append(loc)
            elif not loot:
                empty.append(loc)
        if unread:
            record("lootmap", INCONC,
                   "%d id(s) gave no locationLoot.Loot at all, so nothing was "
                   "proved about them: %s" % (len(unread), ", ".join(unread)))
        elif empty:
            record("lootmap", FAIL,
                   "%d of %d client-sendable location id(s) served an EMPTY "
                   "locationLoot.Loot: %s"
                   % (len(empty), len(want), ", ".join(empty)))
        else:
            record("lootmap", OK,
                   "all %d client-sendable location id(s) served a non-empty "
                   "Loot" % len(want))

    # 8a3 -- the other half of the same negative, so the fix above cannot be a
    # resolver that maps EVERYTHING to some map.  An id the database genuinely
    # has nothing for must still answer empty rather than silently inherit
    # another map's loot, which would put crates in mid-air.
    if not std_session:
        record("lootunmapped", INCONC, "no session to start a raid with")
    else:
        wrong = []
        for loc in UNMAPPABLE_IDS:
            loot, _ = _start(loc)
            if loot:
                wrong.append("%s(%d)" % (loc, len(loot)))
        if wrong:
            record("lootunmapped", FAIL,
                   "id(s) with no database location of their own were served "
                   "loot anyway -- the resolver is guessing: %s"
                   % ", ".join(wrong))
        else:
            record("lootunmapped", OK,
                   "all %d id(s) the database has nothing for served an empty "
                   "Loot rather than another map's" % len(UNMAPPABLE_IDS))

    # 8b -- the Position shape, on a map our generator does answer for.
    loot, text = (None, "") if not std_session else _start(LOOT_SHAPE_MAP)
    if not std_session:
        record("lootpos", INCONC, "no session to start a raid with")
    elif not loot:
        record("lootpos", INCONC,
               "%r served no loot to check the Position shape on: %s"
               % (LOOT_SHAPE_MAP, text[:120]))
    else:
        def _nz(e):
            p = e.get("Position") or {}
            return any(abs(p.get(k, 0) or 0) > 1e-6 for k in "xyz")
        conts = [e for e in loot if e.get("IsContainer")]
        loose = [e for e in loot if not e.get("IsContainer")]
        want_container_nonzero = (mut == "lootpos")
        bad_cont = [e["Id"] for e in conts
                    if _nz(e) != want_container_nonzero][:4]
        bad_loose = [e.get("Id") for e in loose if not _nz(e)][:4]
        if not conts:
            record("lootpos", INCONC,
                   "%d loot entries but none is a container" % len(loot))
        elif bad_cont:
            record("lootpos", FAIL,
                   "container Position must be %s (BSG's own 158.json sends "
                   "zeros); wrong on e.g. %s"
                   % ("non-zero" if want_container_nonzero else "(0,0,0)",
                      ", ".join(map(str, bad_cont))))
        elif bad_loose:
            record("lootpos", FAIL,
                   "%d loose entr(ies) served at Position (0,0,0); BSG sends a "
                   "real coordinate for every one: e.g. %s"
                   % (len(bad_loose), ", ".join(map(str, bad_loose))))
        elif not loose:
            record("lootpos", FAIL,
                   "%s served %d containers and ZERO loose loot entries; BSG's "
                   "capture for Sandbox_start sends 94 of 135. db.json has no "
                   "`looseLoot` key, so emu/loot.nim's loose path is dead."
                   % (LOOT_SHAPE_MAP, len(conts)))
        else:
            record("lootpos", OK,
                   "%d container(s) at (0,0,0) as BSG sends them, %d loose "
                   "entr(ies) all with a non-zero Position"
                   % (len(conts), len(loose)))

    # ----------------------------------------------------------------- 8c
    # THE PROBABILISTIC LOOSE-LOOT NEGATIVE.
    #
    # "No map whose database carries N probabilistic `spawnpoints` serves a
    # loose-entry count that is only its `spawnpointsForced` list."
    #
    # Stated that way because the failure it names is invisible to every check
    # above: `looseLoot` was imported, the loose path ran, and the payload came
    # back with a non-empty `Loot` -- so `lootmap`, `lootparity` and `lootpos`
    # all went green while 1232 of sandbox's 1232 probabilistic spawn points
    # emitted NOTHING and only the 15 forced ones survived.  The count is the
    # only thing that distinguishes the two, which is why this asserts on it.
    #
    # Three outcomes, not two.  A server whose database has no `looseLoot` for
    # a map serves zero loose entries, which is CORRECT for that database and
    # proves nothing about this bug -- so it is INCONCLUSIVE, never a pass.
    #
    # The falsifying input: `--mutate lootloose` demands more loose entries
    # than the map has spawn points at all, which no correct server can serve.
    if not std_session:
        record("lootloose", INCONC, "no session to start a raid with")
    else:
        locdir = os.path.join(spt_root, "SPT_Runtime", "SPT_Data", "database",
                              "locations")
        if not os.path.isdir(locdir):
            locdir = os.path.join(spt_root, "SPT_Data", "database", "locations")
        by_dir = dict((i.lower(), i) for i in CLIENT_LOCATION_IDS)
        rows, silent, absent, unread = [], [], [], []
        for d in (sorted(os.listdir(locdir)) if os.path.isdir(locdir) else []):
            loc = by_dir.get(d.lower())
            src = os.path.join(locdir, d, "looseLoot.json")
            if loc is None or not os.path.isfile(src):
                continue
            loot, _ = _start(loc)
            if loot is None:
                unread.append(loc)
                continue
            loose = len([e for e in loot if not e.get("IsContainer")])
            # THE SERVER's copy of the table, not SPT's.  A map the operator
            # did not import serves zero loose entries CORRECTLY, and calling
            # that a pass is the failure this file exists to avoid -- so it is
            # INCONCLUSIVE and named.  Presence is tested as the per-map
            # sidecar `--loose-dir` ships; a table EMBEDDED in db.json with
            # `--loose all` is not detected here, which is stated rather than
            # hidden: such a map that served zero would be reported
            # INCONCLUSIVE when it is really a FAIL.
            have = os.path.isfile(os.path.join(loose_dir, d + ".json"))
            if loose == 0 and not have:
                absent.append(loc)
                continue
            # Only now is the (large) source file worth parsing.
            with open(src, encoding="utf-8") as fh:
                tbl = json.load(fh)
            forced = len(tbl.get("spawnpointsForced") or [])
            points = tbl.get("spawnpoints") or []
            npts = len(points)
            psum = sum(float(sp.get("probability") or 0.0) for sp in points)
            mul = 1.0
            bp = os.path.join(locdir, d, "base.json")
            if os.path.isfile(bp):
                with open(bp, encoding="utf-8") as fh:
                    mul = float(json.load(fh).get(
                        "GlobalLootChanceModifier", 1.0) or 1.0)
            # Each point is rolled INDEPENDENTLY against its own probability,
            # so the served count is forced + a sum of len(points) Bernoullis.
            # Its standard deviation is sqrt(Sigma p(1-p)) after the modifier,
            # and that -- not a flat percentage -- is what "far from the
            # prediction" has to mean: 20% is 6 sigma on TarkovStreets and
            # under 1 sigma on Labyrinth, so a flat band both misses real bugs
            # on big maps and cries wolf on small ones.
            qs = [min(1.0, max(0.0, float(sp.get("probability") or 0.0) * mul))
                  for sp in points]
            expect = forced + sum(qs)
            sigma = sum(q * (1.0 - q) for q in qs) ** 0.5
            del tbl, points, qs
            rows.append((loc, loose, forced, expect, sigma, psum))
            floor = forced + npts if mut == "lootloose" else forced
            if loose <= floor:
                silent.append("%s: %d loose served, needed more than %d "
                              "(%d forced, %.1f probabilistic expected of "
                              "%d point(s))"
                              % (loc, loose, floor, forced,
                                 expect - forced, npts))
        print()
        print("  %-16s %8s %8s %9s %7s %7s" %
              ("map", "served", "forced", "expect", "sigma", "z"))
        for loc, n, f, expect, sigma, psum in rows:
            print("  %-16s %8d %8d %9.1f %7.1f %7s"
                  % (loc, n, f, expect, sigma,
                     "-" if sigma <= 0 else "%+.1f" % ((n - expect) / sigma)))
        for loc in absent:
            print("  %-16s %8s   (no table on the server)" % (loc, "-"))
        # 4 sigma.  One-sided tail probability under 1 in 30,000 per map, so
        # 13 maps false-alarm about once in 2,300 runs -- and a systematic
        # defect (a whole class of point never firing) is tens of sigma, not
        # four.  MEASURED: with the composedKey bug reverted every map sat at
        # its forced count, which is -13 to -40 sigma.
        skewed = ["%s: %d served, expected %.0f +- %.1f (%+.1f sigma)"
                  % (loc, n, expect, sigma, (n - expect) / sigma)
                  for loc, n, f, expect, sigma, psum in rows
                  if sigma > 0 and abs(n - expect) > 4.0 * sigma]
        if unread:
            record("lootloose", INCONC,
                   "%d id(s) gave no locationLoot.Loot at all: %s"
                   % (len(unread), ", ".join(unread)))
        elif not rows:
            record("lootloose", INCONC,
                   "no imported map served any loose loot; no looseLoot table "
                   "is on the server for %s (aowl importdb --loose sidecar)"
                   % (", ".join(absent) or "any map"))
        elif silent:
            record("lootloose", FAIL,
                   "%d map(s) served ONLY their forced loose spawns: %s"
                   % (len(silent), "; ".join(silent)))
        elif skewed:
            record("lootloose", FAIL,
                   "%d map(s) served a loose count more than 4 sigma from "
                   "forced + Sigma(probability x GlobalLootChanceModifier): %s"
                   % (len(skewed), "; ".join(skewed)))
        elif absent:
            record("lootloose", INCONC,
                   "%d of %d map(s) verified (%s); no table on the server for "
                   "%s, so nothing was proved about them"
                   % (len(rows), len(rows) + len(absent),
                      ", ".join(r[0] for r in rows), ", ".join(absent)))
        else:
            record("lootloose", OK,
                   "all %d imported map(s) served a loose count within 4 "
                   "sigma of forced + Sigma(probability x "
                   "GlobalLootChanceModifier)"
                   % len(rows))

    # --------------------------------------------------------------- raidmem
    #
    # "N consecutive raids on ONE map leave the server's working set within X MB
    # of where it stood after the FIRST raid on that map."
    #
    # A negative assertion, and stated against the post-first-raid reading on
    # purpose: raid one is allowed to be expensive, because it is what warms
    # every cache this server deliberately keeps. What must not happen is a
    # per-raid slope, which is what a player doing ten raids in a session pays.
    #
    # X is 24 MB and comes from measurement, not from taste. `tools/lootmem.py`
    # against a real db.json on `bigmap` measures one raid's *transient* peak at
    # roughly 9 MB, and the server serves large answers from a pool of 16
    # workers, each of which keeps its own allocator's high-water mark. So a
    # server with the retention bounded to ONE worker's peak sits near 9-11 MB
    # of drift and 24 MB is comfortably above it; a server that lets every
    # worker reach its own peak passes 24 MB by raid four and converges near
    # +176 MB. The two are not close, which is what makes the number safe.
    #
    # RAIDS is 8 rather than 16 because it has to fail on the CURRENT defect
    # while staying inside a check-suite's patience: the slope is ~9 MB/raid, so
    # eight raids is ~70 MB of drift against a 24 MB budget.
    #
    # The falsifying input: `--mutate raidmem` sets the budget to 0 MB, which no
    # real process can meet.
    RAIDS = 8
    budget = 0.0 if mut == "raidmem" else 24.0
    pid = _pid_on_port(a.port)
    if not std_session:
        record("raidmem", INCONC, "no session to start a raid with")
    elif pid is None:
        record("raidmem", INCONC,
               "nothing is listening on port %d that this can measure; the "
               "backend has to be a local process for its working set to be "
               "readable" % a.port)
    else:
        loc = "bigmap"
        samples = []
        for i in range(RAIDS):
            loot, _ = _start(loc)
            if loot is None:
                break
            time.sleep(0.3)
            samples.append(_working_set_mb(pid))
        if len(samples) < RAIDS or any(m is None for m in samples):
            record("raidmem", INCONC,
                   "only %d of %d raid(s) on %s could be started and measured"
                   % (len([m for m in samples if m is not None]), RAIDS, loc))
        else:
            drift = max(samples[1:]) - samples[0]
            slope = (samples[-1] - samples[0]) / (RAIDS - 1)
            detail = ("%d raids on %s: %.1f MB after the first, %.1f MB peak "
                      "after that -- drift %.1f MB (%.2f MB/raid), budget "
                      "%.1f MB" % (RAIDS, loc, samples[0], max(samples[1:]),
                                   drift, slope, budget))
            record("raidmem", FAIL if drift > budget else OK, detail)

    print()
    bad = [r for r in results if r[1] != OK]
    print("%d check(s), %d not PASS" % (len(results), len(bad)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
