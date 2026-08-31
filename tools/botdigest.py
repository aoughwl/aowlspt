"""Ask a running backend for a hash of N generated bot loadouts at a stated seed.

THE INSTRUMENT for "defaults reproduce current behaviour exactly". Before this,
that claim rested on reading the code and seeing that every new path
early-returns at its default -- an argument, which cannot fail. This is a
number: two builds at the same seed with the same settings must print the same
one, and moving ONE knob must print a different one. The second half is what
proves the first half was capable of failing.

The digest is over the FINISHED loadout with every id stripped -- template,
slot, parent ordinal, stack count, in emission order. Ids come from a run
counter that advances per process, so hashing them would report a difference on
every run and be as useless as a check that always passes.

Usage
  python tools/botdigest.py --port 6971 --role assault --seed S1 --n 8
  python tools/botdigest.py --port 6971 --prove-defaults BASELINE.json
  python tools/botdigest.py --port 6971 --knob botModTierFamScavLegendary=0

`--prove-defaults` writes/compares a baseline across the roles it samples.
Any digest whose `items` is 0 is reported INCONCLUSIVE and never as a pass:
the hash of an empty loadout agrees with itself across every possible change.
"""

import argparse
import json
import sys
import urllib.request

ROLES = ["assault", "marksman", "pmcusec", "pmcbear", "bossknight",
         "exusec", "sectantpriest", "followerbigpipe", "pmcbot"]


def fetch(port, role, seed, n):
    url = f"http://127.0.0.1:{port}/aowlspt/tarkov/botdigest/{role}/{seed}/{n}"
    req = urllib.request.Request(url, headers={"Accept-Encoding": "identity"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read().decode("utf-8"))


def sample(port, seed, n, roles):
    out = {}
    for role in roles:
        d = fetch(port, role, seed, n)
        if not d.get("ok"):
            out[role] = {"verdict": "INCONCLUSIVE",
                         "reason": d.get("reason", "route said not ok")}
        else:
            out[role] = {"digest": d["digest"], "items": d["items"]}
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=6971)
    ap.add_argument("--role")
    ap.add_argument("--seed", default="S1")
    ap.add_argument("--n", type=int, default=8)
    ap.add_argument("--save")
    ap.add_argument("--compare")
    a = ap.parse_args()

    roles = [a.role] if a.role else ROLES
    got = sample(a.port, a.seed, a.n, roles)

    if a.save:
        with open(a.save, "w", encoding="utf-8") as f:
            json.dump({"seed": a.seed, "n": a.n, "roles": got}, f, indent=1)
        print(f"saved baseline: {a.save}")

    if a.compare:
        with open(a.compare, encoding="utf-8") as f:
            base = json.load(f)
        if base["seed"] != a.seed or base["n"] != a.n:
            print("INCONCLUSIVE: baseline was taken at a different seed/count")
            return 2
        same, diff, inc = [], [], []
        for role, v in got.items():
            b = base["roles"].get(role)
            if b is None or "digest" not in b or "digest" not in v:
                inc.append(role)
            elif v["items"] == 0 or b["items"] == 0:
                inc.append(role + " (0 items)")
            elif v["digest"] == b["digest"]:
                same.append(role)
            else:
                diff.append(f"{role} {b['digest']} -> {v['digest']}")
        print(f"IDENTICAL {len(same)}  CHANGED {len(diff)}  "
              f"INCONCLUSIVE {len(inc)}")
        for d in diff:
            print("  changed:", d)
        for i in inc:
            print("  inconclusive:", i)
        return 0 if not inc else 3

    for role, v in got.items():
        print(role, v)
    return 0


if __name__ == "__main__":
    sys.exit(main())
