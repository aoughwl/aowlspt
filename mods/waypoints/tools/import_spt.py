#!/usr/bin/env python3
"""Convert DrakiaXYZ SPT-Waypoints patrol JSON into aowlspt.waypoints/1.

Source: https://github.com/DrakiaXYZ/SPT-Waypoints tag 1.3.4,
        Waypoints/Solarint/<map>.json  (MIT, (c) 2023 DrakiaXYZ; points by Solarint)

The upstream shape is {zone: {patrol: {name, waypoints[], patrolType,
maxPersons, blockRoles}}} where each waypoint is
{position:{x,y,z}, canUseByBoss, patrolPointType, shallSit, waypoints}.

Measured over all ten upstream maps (8556 points, 197 patrols, 87 zones):
nested `waypoints` is null EVERYWHERE, `patrolPointType` is always
"checkPoint", `canUseByBoss` is always true, `patrolType` is always
"patrolling".  Those four are therefore hoisted to document-level constants
and asserted here rather than repeated 8556 times; if a future source file
violates one, this script FAILS instead of silently dropping the difference.
`shallSit` is true for 127 points and is kept as an index list per patrol.

    python tools/import_spt.py raw data
"""
import json, os, sys, glob

SCHEMA = "aowlspt.waypoints/1"
SOURCE = {
    "mod": "SPT-Waypoints", "version": "1.3.4", "author": "DrakiaXYZ",
    "points": "Solarint", "license": "MIT",
    "url": "https://github.com/DrakiaXYZ/SPT-Waypoints",
}


def convert(src, dst):
    raw = json.load(open(src, encoding="utf-8-sig"))
    zones, np, nz = [], 0, 0
    for zname in sorted(raw):
        patrols = []
        for pname in sorted(raw[zname]):
            pv = raw[zname][pname]
            if pv["patrolType"] != "patrolling":
                raise SystemExit(f"{src}: unexpected patrolType {pv['patrolType']!r}")
            pts, sit = [], []
            for i, w in enumerate(pv["waypoints"] or []):
                if w["waypoints"]:
                    raise SystemExit(f"{src}: nested waypoints present, schema/1 cannot carry them")
                if w["patrolPointType"] != "checkPoint":
                    raise SystemExit(f"{src}: unexpected patrolPointType {w['patrolPointType']!r}")
                if not w["canUseByBoss"]:
                    raise SystemExit(f"{src}: canUseByBoss false, schema/1 hoists it as true")
                p = w["position"]
                pts.append([round(p["x"], 3), round(p["y"], 3), round(p["z"], 3)])
                if w["shallSit"]:
                    sit.append(i)
            if not pts:
                continue
            patrol = {
                "name": pv["name"], "patrolType": pv["patrolType"],
                "maxPersons": pv["maxPersons"], "blockRoles": pv["blockRoles"],
                "points": pts,
            }
            if sit:
                patrol["sit"] = sit
            patrols.append(patrol)
            np += 1
        if patrols:
            zones.append({"zone": zname, "patrols": patrols})
            nz += 1
    doc = {
        "schema": SCHEMA,
        "map": os.path.splitext(os.path.basename(src))[0],
        "space": "unity-world",
        "units": "metres",
        "pointType": "checkPoint",
        "bossUsable": True,
        "source": SOURCE,
        "counts": {"zones": nz, "patrols": np,
                   "points": sum(len(p["points"]) for z in zones for p in z["patrols"])},
        "zones": zones,
    }
    with open(dst, "w", encoding="utf-8", newline="\n") as f:
        json.dump(doc, f, separators=(",", ":"), ensure_ascii=False)
    return doc["counts"]


def main():
    src_dir, dst_dir = sys.argv[1], sys.argv[2]
    os.makedirs(dst_dir, exist_ok=True)
    total = {"zones": 0, "patrols": 0, "points": 0}
    for src in sorted(glob.glob(os.path.join(src_dir, "*.json"))):
        dst = os.path.join(dst_dir, os.path.basename(src))
        c = convert(src, dst)
        for k in total:
            total[k] += c[k]
        print(f"{os.path.basename(src):20s} {os.path.getsize(src):>8d} -> {os.path.getsize(dst):>8d}  {c}")
    print("TOTAL", total)


if __name__ == "__main__":
    main()
