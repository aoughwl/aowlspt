#!/usr/bin/env python3
"""Acceptance for the Waypoints mod, against a RUNNING backend.

    python mods/waypoints/tools/verify.py --base http://127.0.0.1:6971

Three outcomes per check: PASS / FAIL / INCONCLUSIVE. A check that could not
look (no network to GitHub, the tuning route not served because aowl.tarkov is
not loaded) reports INCONCLUSIVE and is NOT counted as a pass.

Every assertion is on the FINISHED STATE, and every one can fail:

 1. Each of the ten map documents parses STRICTLY as JSON (`json.loads`, not a
    substring test) and carries the schema string.
 2. The served coordinates are compared against DrakiaXYZ's ORIGINAL 1.3.4
    files fetched from GitHub -- not against the converted files this repo
    ships, and not against anything this mod wrote. Every point must match
    within 0.0005 m, the count must be exact, and the ORDER must match. A
    conversion that dropped, duplicated or reordered a patrol fails here.
 3. The negative: no served coordinate is NaN, infinite, or beyond +/-2000 m,
    and no patrol has an empty point list.
 4. The tuning is read back off `/client/game/bot/difficulty`, which is the
    route the CLIENT reads -- not off the mod's own status page -- for all
    EIGHT bear/usec x easy/normal/hard/impossible blocks. LOOK_TIME_BASE must
    be 3 (BSG ships 12), RESERVE_TIME_STAY 12, Mind.CAN_STAND_BY false (BSG
    ships true). If that route is absent (aowl.tarkov not loaded) the check is
    INCONCLUSIVE, never a pass.
 5. The status page's `skipped` list is counted against those same eight
    payloads: each key's `absentIn` must EQUAL the number of blocks it is
    really missing from. This is what catches a status page that says
    "SPRINT_BETWEEN_CACHED_POINTS was skipped" when it was written to six of
    the eight blocks -- which is exactly what an earlier revision of this mod
    reported.

`Accept-Encoding: identity` is sent on every request: the backend deflates
otherwise (fact #123) and a byte count off a deflated body means nothing.
"""
import argparse, json, math, sys, urllib.request

MAPS = ["bigmap", "factory4_day", "factory4_night", "interchange", "laboratory",
        "lighthouse", "rezervbase", "shoreline", "tarkovstreets", "woods"]
UPSTREAM = "https://raw.githubusercontent.com/DrakiaXYZ/SPT-Waypoints/1.3.4/Waypoints/Solarint/%s.json"
# The importer rounds to 3 decimal places, so the error is bounded at 0.0005 m
# BY CONSTRUCTION. The tolerance is a hair above that: at exactly 0.0005 the
# float comparison is a coin toss, and a check that fails on a coin toss is not
# a check. Anything larger than half a millimetre is a real conversion bug.
TOL = 0.0006

results = []


def record(name, outcome, detail=""):
    results.append((outcome, name, detail))
    print(f"{outcome:13s} {name}" + (f" -- {detail}" if detail else ""))


def get(base, path):
    req = urllib.request.Request(base + path, headers={"Accept-Encoding": "identity"})
    with urllib.request.urlopen(req, timeout=30) as f:
        return f.status, f.read()


def served_points(doc):
    """[(zone, patrolname, [(x,y,z), ...]), ...] in document order."""
    out = []
    for z in doc["zones"]:
        for p in z["patrols"]:
            out.append((z["zone"], p["name"], [tuple(pt) for pt in p["points"]]))
    return out


def upstream_points(raw):
    out = []
    for zname in sorted(raw):
        for pname in sorted(raw[zname]):
            pv = raw[zname][pname]
            pts = [(w["position"]["x"], w["position"]["y"], w["position"]["z"])
                   for w in (pv["waypoints"] or [])]
            if pts:
                out.append((zname, pv["name"], pts))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://127.0.0.1:6971")
    ap.add_argument("--no-upstream", action="store_true",
                    help="skip the GitHub comparison (reports INCONCLUSIVE)")
    a = ap.parse_args()

    docs = {}
    for m in MAPS:
        try:
            st, body = get(a.base, "/waypoints/points/" + m)
        except Exception as e:
            record(f"[1] {m} served", "INCONCLUSIVE", f"could not fetch: {e}")
            continue
        if st != 200:
            record(f"[1] {m} served", "FAIL", f"HTTP {st}")
            continue
        try:
            doc = json.loads(body.decode("utf-8"))
        except Exception as e:
            record(f"[1] {m} strict parse", "FAIL", f"{len(body)} bytes, not JSON: {e}")
            continue
        if doc.get("schema") != "aowlspt.waypoints/1" or doc.get("map") != m:
            record(f"[1] {m} strict parse", "FAIL",
                   f"schema={doc.get('schema')!r} map={doc.get('map')!r}")
            continue
        docs[m] = doc
        record(f"[1] {m} strict parse", "PASS", f"{len(body)} bytes")

    # 3. the negative, on whatever parsed
    bad = []
    for m, doc in docs.items():
        for zone, name, pts in served_points(doc):
            if not pts:
                bad.append(f"{m}/{zone}/{name}: empty")
            for x, y, z in pts:
                for v in (x, y, z):
                    if not isinstance(v, (int, float)) or math.isnan(v) or \
                       math.isinf(v) or abs(v) > 2000:
                        bad.append(f"{m}/{zone}/{name}: {v!r}")
    if not docs:
        record("[3] no degenerate coordinate", "INCONCLUSIVE", "nothing parsed")
    elif bad:
        record("[3] no degenerate coordinate", "FAIL", "; ".join(bad[:4]))
    else:
        n = sum(len(p) for d in docs.values() for _, _, p in served_points(d))
        record("[3] no degenerate coordinate", "PASS", f"{n} points checked")

    # 2. against upstream
    if a.no_upstream:
        record("[2] matches upstream 1.3.4", "INCONCLUSIVE", "--no-upstream")
    else:
        total, mismatch, unreached = 0, [], []
        for m in MAPS:
            if m not in docs:
                unreached.append(m)
                continue
            try:
                with urllib.request.urlopen(UPSTREAM % m, timeout=30) as f:
                    raw = json.loads(f.read().decode("utf-8-sig"))
            except Exception as e:
                unreached.append(f"{m}({e})")
                continue
            want, got = upstream_points(raw), served_points(docs[m])
            if len(want) != len(got):
                mismatch.append(f"{m}: {len(got)} patrols served, upstream has {len(want)}")
                continue
            for (wz, wn, wp), (gz, gn, gp) in zip(want, got):
                if wz != gz or wn != gn or len(wp) != len(gp):
                    mismatch.append(f"{m}/{wz}/{wn}: {len(gp)} vs {len(wp)}")
                    break
                for (wx, wy, wz3), (gx, gy, gz3) in zip(wp, gp):
                    if (abs(wx - gx) > TOL or abs(wy - gy) > TOL or abs(wz3 - gz3) > TOL):
                        mismatch.append(f"{m}/{wz}/{wn}: {(gx,gy,gz3)} != {(wx,wy,wz3)}")
                        break
                total += len(wp)
        if mismatch:
            record("[2] matches upstream 1.3.4", "FAIL", "; ".join(mismatch[:3]))
        elif unreached:
            record("[2] matches upstream 1.3.4", "INCONCLUSIVE",
                   f"{total} points matched, but not reached: {', '.join(unreached)}")
        else:
            record("[2] matches upstream 1.3.4", "PASS",
                   f"{total} points match within {TOL} m, same order")

    # 4/5. the tuning, off the route the CLIENT reads -- all eight blocks
    ROLES = ["bear", "usec"]
    DIFFS = ["easy", "normal", "hard", "impossible"]
    blocks = {}
    for role in ROLES:
        for d in DIFFS:
            try:
                st, body = get(a.base, f"/client/game/bot/difficulty?type={role}&difficulty={d}")
                doc = json.loads(body.decode())
                blocks[(role, d)] = doc.get("data", doc)
            except Exception as e:
                blocks[(role, d)] = None
                err = e
    if any(v is None for v in blocks.values()):
        record("[4] tuning reached the client route", "INCONCLUSIVE",
               "/client/game/bot/difficulty unavailable -- is aowl.tarkov loaded?")
        record("[5] the skipped list is accurate", "INCONCLUSIVE", "same reason")
    else:
        wrong = []
        for k, doc in blocks.items():
            look = doc.get("Patrol", {}).get("LOOK_TIME_BASE")
            stay = doc.get("Patrol", {}).get("RESERVE_TIME_STAY")
            stand = doc.get("Mind", {}).get("CAN_STAND_BY")
            if look != 3 or stay != 12 or stand is not False:
                wrong.append(f"{k[0]}/{k[1]}: LOOK={look!r} STAY={stay!r} STANDBY={stand!r}")
        if wrong:
            record("[4] tuning reached the client route", "FAIL", "; ".join(wrong[:3]))
        else:
            record("[4] tuning reached the client route", "PASS",
                   "all 8 bear/usec blocks: LOOK_TIME_BASE=3 (BSG 12), "
                   "RESERVE_TIME_STAY=12, CAN_STAND_BY=false (BSG true)")

        # 5. the status page's skipped list, counted against the real payloads.
        try:
            st, body = get(a.base, "/waypoints/status")
            status = json.loads(body.decode())
        except Exception as e:
            record("[5] the skipped list is accurate", "INCONCLUSIVE", f"no status: {e}")
        else:
            lying = []
            for e in status["tuning"]["skipped"]:
                key, claimed = e["key"], e["absentIn"]
                sect, leaf = key.split(".", 1)
                actual = sum(1 for doc in blocks.values() if leaf not in doc.get(sect, {}))
                if actual != claimed:
                    lying.append(f"{key}: status says absent in {claimed}, really {actual}")
            if e_of := status["tuning"]["skipped"]:
                if any(x["of"] != len(blocks) for x in e_of):
                    lying.append(f"status counted {e_of[0]['of']} blocks, there are {len(blocks)}")
            if lying:
                record("[5] the skipped list is accurate", "FAIL", "; ".join(lying[:3]))
            else:
                record("[5] the skipped list is accurate", "PASS",
                       f"{len(status['tuning']['skipped'])} skipped keys, each absent in "
                       "exactly the number of blocks the status page claims")

    print()
    for tag in ("FAIL", "INCONCLUSIVE", "PASS"):
        n = sum(1 for o, _, _ in results if o == tag)
        print(f"  {tag}: {n}")
    return 1 if any(o == "FAIL" for o, _, _ in results) else 0


if __name__ == "__main__":
    sys.exit(main())
