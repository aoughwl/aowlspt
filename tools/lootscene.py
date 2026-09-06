#!/usr/bin/env python3
"""lootscene.py -- extract loot-spawn Id -> Position from the client scenes.

Reads the BuildSettings scene list out of globalgamemanagers, maps each
`levelN` serialized file to the .unity path at index N, groups those by the
`Assets/Content/Locations/<Group>/` folder, and sweeps every MonoBehaviour in
the group's levels for packed loot records (see unityassets.decode_records).

  scenes                          list levelN -> scene path (group, index)
  groups                          folder -> how many levels
  extract GROUP [--json OUT]      sweep one group's levels
  verify  --capture F --group G   check the decode against a REAL BSG payload
"""
import argparse
import collections
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import unityassets as ua  # noqa: E402  (handles the interpreter re-exec)

import gamepaths as _gp  # noqa: E402  (the data dir of the game the host runs against)
DATA = os.environ.get("EFT_DATA", _gp.datadir())


def scene_list():
    import UnityPy
    env = UnityPy.load(os.path.join(DATA, "globalgamemanagers"))
    for o in env.objects:
        if o.type.name == "BuildSettings":
            d = o.get_raw_data()
            return [m.group().decode()
                    for m in re.finditer(rb"Assets/[ -~]{4,}\.unity", d)]
    raise SystemExit("lootscene: NAMED-ERROR no-buildsettings")


def group_of(path):
    m = re.match(r"Assets/Content/Locations/([^/]+)/", path)
    return m.group(1) if m else "_other"


def levels_for(group):
    out = []
    for i, p in enumerate(scene_list()):
        if group_of(p) != group:
            continue
        f = os.path.join(DATA, "level%d" % i)
        if os.path.isfile(f):
            out.append((i, f, p))
    return out


def extract(group, progress=False):
    seen = {}
    per_level = []
    for i, f, p in levels_for(group):
        try:
            got = ua.scene_lootpos(f)
        except Exception as e:                       # a level we cannot parse
            per_level.append((i, p, "ERROR:%s" % type(e).__name__))
            continue
        new = 0
        for k, v in got.items():
            if k not in seen:
                seen[k] = v
                new += 1
        per_level.append((i, p, "%d ids (+%d new)" % (len(got), new)))
        if progress:
            sys.stderr.write("  level%-5d %-70s %s\n" % (i, p, per_level[-1][2]))
    return seen, per_level


def cmd_scenes(a):
    for i, p in enumerate(scene_list()):
        print("level%-5d %-12s %s" % (i, group_of(p), p))


def cmd_groups(a):
    c = collections.Counter(group_of(p) for p in scene_list())
    for g, n in sorted(c.items()):
        print("%-24s %d" % (g, n))


def cmd_extract(a):
    seen, per = extract(a.group, progress=a.verbose)
    if a.json:
        with open(a.json, "w") as fh:
            json.dump(seen, fh, indent=0, sort_keys=True)
    print("# group=%s levels=%d ids=%d" % (a.group, len(per), len(seen)))


def cmd_verify(a):
    """PASS/FAIL/INCONCLUSIVE against a real BSG match/local/start body.

    The only decode check worth anything: BSG's own server sent positions for
    these exact Ids.  We compare our scene-decoded Position to theirs.  A
    plausible-looking wrong float fails here; a lucky alignment cannot agree
    with an independently transmitted coordinate to 1e-2 on all three axes.
    """
    body = json.load(open(a.capture))
    loot = body.get("data", {}).get("locationLoot", {}).get("Loot")
    if not loot:
        print("INCONCLUSIVE: capture has no locationLoot.Loot")
        return 2
    seen, _ = extract(a.group, progress=a.verbose)
    agree = disagree = absent = 0
    ex = []
    for e in loot:
        p = e.get("Position") or {}
        if not any(abs(p.get(k, 0)) > 1e-6 for k in "xyz"):
            continue
        got = seen.get(e["Id"])
        if got is None:
            absent += 1
            continue
        if all(abs(got[k] - p[k]) < 1e-2 for k in "xyz"):
            agree += 1
        else:
            disagree += 1
            if len(ex) < 5:
                ex.append((e["Id"], p, got))
    print("agree=%d disagree=%d not-found-in-scene=%d" % (agree, disagree, absent))
    for i in ex:
        print("  MISMATCH", i)
    if agree and not disagree:
        print("PASS: every Id found in the scene decoded to BSG's own coordinate")
        return 0
    if disagree:
        print("FAIL: the decode disagrees with BSG for %d Id(s)" % disagree)
        return 1
    print("INCONCLUSIVE: no Id from the capture was found in these scenes")
    return 2


def main():
    ap = argparse.ArgumentParser(prog="lootscene.py")
    ap.add_argument("-v", "--verbose", action="store_true")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("scenes").set_defaults(fn=cmd_scenes)
    sub.add_parser("groups").set_defaults(fn=cmd_groups)
    p = sub.add_parser("extract")
    p.add_argument("group")
    p.add_argument("--json")
    p.set_defaults(fn=cmd_extract)
    p = sub.add_parser("verify")
    p.add_argument("--capture", required=True)
    p.add_argument("--group", required=True)
    p.set_defaults(fn=cmd_verify)
    a = ap.parse_args()
    sys.exit(a.fn(a) or 0)


if __name__ == "__main__":
    main()
