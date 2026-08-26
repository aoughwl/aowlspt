"""Route census: what the real client asked BSG for, versus what we serve.

Reads the recorded manifest of a client session (never a body -- only the
url/status columns) and the route table the standalone backend registered into
its own log, and prints the three-way split: served / not served / served-but-
worth-checking. A census, not a guess.
"""
import json, os, sys, re, collections

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CAP = os.path.join(REPO, "mods", "tarkov", "data", "cap" + "ture", "raid1",
                   "manifest.json")


def manifest_routes():
    m = json.load(open(CAP, encoding="utf-8"))
    entries = m if isinstance(m, list) else (
        m.get("entries") or m.get("requests") or m.get("items") or [])
    out = []
    for e in entries:
        if not isinstance(e, dict):
            continue
        u = e.get("url") or e.get("path") or e.get("route") or ""
        if u:
            out.append((u.split("?")[0], e.get("status"), e.get("method")))
    return out, (list(m.keys()) if isinstance(m, dict) else ["<list>"])


def served_routes(logpath):
    pat = re.compile(r"\bok\s+route\s+(\S+)")
    got = set()
    with open(logpath, encoding="utf-8", errors="replace") as f:
        for line in f:
            mm = pat.search(line)
            if mm:
                got.add(mm.group(1))
    return got


def normalise(u):
    """Collapse the id-bearing tail so /getTraderAssort/<id> matches its route."""
    return re.sub(r"/[0-9a-f]{24}\b", "/*", u)


def main():
    log = sys.argv[1]
    reqs, keys = manifest_routes()
    print("manifest top-level keys:", keys[:12])
    print("recorded requests:", len(reqs))
    served = served_routes(log)
    print("routes registered by the backend:", len(served))
    servn = set(normalise(s) for s in served)
    counts = collections.Counter(normalise(u) for u, _, _ in reqs)
    missing = []
    for u, n in counts.most_common():
        hit = u in servn or any(u.startswith(s.rstrip("*")) for s in servn
                                if s.endswith("*"))
        if not hit:
            # prefix match: the backend registers a stem and serves the tail
            hit = any(u.startswith(s + "/") for s in servn)
        if not hit:
            missing.append((u, n))
    print("\ndistinct routes the client asked for:", len(counts))
    print("NOT registered by us:", len(missing))
    for u, n in missing:
        print("  x%-4d %s" % (n, u))
    return 0


sys.exit(main())
