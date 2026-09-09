#!/usr/bin/env python3
"""clientlog.py - mine the CLIENT's own logs under D:\\Aowlspt\\Logs.

The client's error log is a better oracle for crash-class payload bugs than any
type sweep we run over our own DTOs: it reports what the deserializer actually
choked on, including nested types a top-level sweep structurally cannot see.

    python tools/clientlog.py sweep            # deduped, ranked table
    python tools/clientlog.py sweep --sessions 20
    python tools/clientlog.py show <n>         # full text of one shape
    python tools/clientlog.py routes           # routes the logs actually cover

Dedupe is by SHAPE - (throwing type, normalised message, route) - not by text,
so one bug logged 500 times counts once. Everything is truncated by default.
"""
from __future__ import annotations
import argparse, os, re, sys, glob, json
from collections import OrderedDict

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

LOGS = r"D:\Aowlspt\Logs"
WANT = ("errors_", "backend_", "application_", "output_")

TS = re.compile(r"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+\|")
URL = re.compile(r"https?://[^\s,;]+")
# Known-benign: documented stock EFT behaviour, with the reason.
BENIGN = [
    (re.compile(r"SpawnPointMarkers? (Id:.*fix message:\s*Position marker|fixes:)"),
     "stock EFT spawn-marker snap, ~95/raid, not ours"),
    (re.compile(r"Couldn't create a Convex Mesh.*maximum polygons limit"),
     "stock asset warning, PhysX convex limit in BSG's own meshes"),
    (re.compile(r"Non-convex MeshCollider with non-kinematic Rigidbody"),
     "stock Unity asset warning"),
    (re.compile(r"The referenced script.*is missing"),
     "stock EFT bundle warning"),
]

NORM = [
    (re.compile(r"\b[0-9a-f]{24}\b"), "<mongoid>"),
    (re.compile(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"), "<guid>"),
    (re.compile(r"\b\d+\b"), "<n>"),
    (re.compile(r"0x[0-9a-fA-F]+"), "<hex>"),
    (re.compile(r"\s+"), " "),
]
# throwing type from a stack frame or an exception header
EXTYPE = re.compile(r"^\s*([A-Za-z][\w.`+]*(?:Exception|Error))\s*:", re.M)
FRAME = re.compile(r"^\s*at ([\w.`+<>]+\.[\w`<>]+) ?\(", re.M)
PARSE_ROUTE = re.compile(r"in response to (https?://[^\s]+?)(?::| at |\s|$)")
PARSE_INTO = re.compile(r"JSON parsing into ([\w.\[\]`+]+)")


def sessions(limit=None):
    ds = sorted(d for d in glob.glob(os.path.join(LOGS, "log_*")) if os.path.isdir(d))
    return ds[-limit:] if limit else ds


def records(path):
    """Yield multi-line records: a timestamped header plus its continuations."""
    cur = []
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if TS.match(line):
                if cur:
                    yield "".join(cur)
                cur = [line]
            elif cur:
                if len(cur) < 60:
                    cur.append(line)
    if cur:
        yield "".join(cur)


def interesting(rec):
    head = rec.split("\n", 1)[0]
    parts = head.split("|")
    lvl = parts[2] if len(parts) > 3 else ""
    if lvl in ("Error", "Fatal", "Critical"):
        return True
    if "Exception" in rec and "at " in rec:
        return True
    if "JSON parsing" in rec or "parsing error" in rec:
        return True
    return False


def benign(rec):
    for rx, why in BENIGN:
        if rx.search(rec):
            return why
    return None


def normalise(s):
    for rx, rep in NORM:
        s = rx.sub(rep, s)
    return s.strip()[:220]


def shape(rec):
    head = rec.split("\n", 1)[0]
    msg = head.split("|", 4)[-1]
    msg = re.sub(r"^(backend|application|errors|[a-z-]+)\|", "", msg)
    msg = re.sub(r"^<--- Response HTTPS, id \[\d+\]: ", "", msg)
    m = URL.search(rec)
    route = ""
    if m:
        route = re.sub(r"^https?://[^/]+", "", m.group(0)).rstrip(".,")
    pr = PARSE_ROUTE.search(rec)
    if pr:
        route = re.sub(r"^https?://[^/]+", "", pr.group(1))
    et = EXTYPE.search(rec)
    thrower = et.group(1) if et else ""
    frames = FRAME.findall(rec)[:3]
    frame = " <- ".join(frames)
    into = PARSE_INTO.search(rec)
    dto = into.group(1) if into else ""
    key = (thrower, frame, route, normalise(msg))
    return key, dict(thrower=thrower, frame=frame, route=route, dto=dto,
                     msg=normalise(msg), sample=rec[:1800])


def collect(limit=None):
    agg = OrderedDict()
    dedupe = set()
    ben = {}
    seen_routes = {}
    sess = sessions(limit)
    for d in sess:
        for f in os.listdir(d):
            if not f.endswith(".log"):
                continue
            if not any(w in f for w in WANT):
                continue
            p = os.path.join(d, f)
            for rec in records(p):
                h = rec.split("\n", 1)[0]
                dk = (d, h)
                if dk in dedupe:
                    continue
                dedupe.add(dk)
                if "---> Request HTTPS" in rec:
                    m = URL.search(rec)
                    if m:
                        r = re.sub(r"^https?://[^/]+", "", m.group(0)).rstrip(".,")
                        seen_routes[r] = seen_routes.get(r, 0) + 1
                    continue
                if not interesting(rec):
                    continue
                why = benign(rec)
                if why:
                    ben[why] = ben.get(why, 0) + 1
                    continue
                key, info = shape(rec)
                e = agg.get(key)
                if e is None:
                    info["count"] = 0
                    info["sessions"] = set()
                    agg[key] = info
                    e = info
                e["count"] += 1
                e["sessions"].add(os.path.basename(d))
    return sess, agg, ben, seen_routes


RAID = ("raid", "match", "location", "getLocalloot", "profile", "game/start")


def rank(e):
    """Blast radius: raid/unhandled first, then screens, then cosmetic."""
    r = e["route"] or ""
    s = 0
    if e["thrower"] or "Exception" in e["msg"]:
        s += 40
    if e["dto"] or "JSON parsing" in e["msg"]:
        s += 30
    if any(k in r for k in RAID):
        s += 30
    if r:
        s += 10
    s += min(len(e["sessions"]), 10)
    return s


def cmd_sweep(a):
    sess, agg, ben, routes = collect(a.sessions)
    items = sorted(agg.values(), key=rank, reverse=True)
    print(f"sessions swept: {len(sess)}  distinct shapes: {len(items)}  "
          f"benign suppressed: {sum(ben.values())}")
    for why, n in ben.items():
        print(f"  benign x{n}: {why}")
    print()
    print(f"{'#':>3} {'hits':>6} {'sess':>4}  {'route':<38} {'thrower/dto':<34} message")
    for i, e in enumerate(items[: a.top]):
        td = e["dto"] or e["thrower"] or e["frame"]
        print(f"{i:>3} {e['count']:>6} {len(e['sessions']):>4}  "
              f"{(e['route'] or '-')[:38]:<38} {td[:34]:<34} {e['msg'][:90]}")
    if len(items) > a.top:
        print(f"... {len(items)-a.top} more (--top N)")
    if a.json:
        for e in items:
            e["sessions"] = sorted(e["sessions"])
        open(a.json, "w").write(json.dumps(items, indent=1))
        print("wrote", a.json)


def cmd_show(a):
    _, agg, _, _ = collect(a.sessions)
    items = sorted(agg.values(), key=rank, reverse=True)
    e = items[a.n]
    print(f"hits={e['count']} sessions={len(e['sessions'])} route={e['route']} dto={e['dto']}")
    print(sorted(e["sessions"])[-1])
    print(e["sample"][: a.chars])


def cmd_routes(a):
    _, _, _, routes = collect(a.sessions)
    for r, n in sorted(routes.items(), key=lambda kv: -kv[1]):
        print(f"{n:>6}  {r}")
    print(f"-- {len(routes)} distinct routes actually exercised")


def cmd_dtos(a):
    """route -> the DTO THE CLIENT ITSELF NAMES, and whether dtogap agrees.

    ## This is the best route->DTO instrument we have, and it was buried

    When Newtonsoft throws, the client logs `JSON parsing into <Type>` next to
    the URL. That is the client STATING its deserialization target -- strictly
    better evidence than dtogap's `--whichdto`, which ranks types by wire-key
    overlap and therefore cannot say anything at all about a payload with one
    or two generic keys ({"elements": [...]}, {"status": "ok"}): hundreds of
    the assembly's 18,629 types declare those names, so a 1.000 score is
    meaningless. The 28 routes that had no mapping were overwhelmingly of that
    shape, which is exactly why key ranking had left them unmapped.

    `sweep` already parsed this field and printed it in a 34-character column,
    truncated, mixed into an error table -- so answering "what type does the
    client deserialize route X into" meant reading the sweep, guessing which
    row, and running `show N` for each. It is one table.

    Three outcomes per row, never two: `agree`, `DISAGREE` (dtogap maps a
    different type -- one of the two is wrong and it is worth knowing which),
    and `UNMAPPED` (the client named a type dtogap does not carry). Absence
    from this table is NOT evidence a route is fine: the client only names a
    type when it THREW, so a route that never failed never appears.
    """
    _, agg, _, _ = collect(a.sessions)
    seen = {}
    for e in agg.values():
        r, d = e.get("route"), e.get("dto")
        if not r or not d:
            continue
        r = r.split("?")[0].rstrip(":")
        cur = seen.setdefault(r, {})
        cur[d] = cur.get(d, 0) + e["count"]
    try:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import dtogap as G
        table = G.ROUTES
    except Exception:
        table = None
    print(f"{'route':<44} {'type the CLIENT named':<44} hits  vs dtogap")
    for r in sorted(seen):
        for d, n in sorted(seen[r].items(), key=lambda kv: -kv[1]):
            bare = d[:-2] if d.endswith("[]") else d
            # The client prints a NESTED type CLR-style,
            # `EFT.GlobalConfiguration+MainQuestSettings`, while il2cpp
            # metadata (and therefore dtogap) names it `MainQuestSettings`.
            # Comparing the raw strings reported DISAGREE for a route where
            # the two agree exactly -- a false alarm in a column whose whole
            # value is that DISAGREE means something.
            bare = bare.rsplit("+", 1)[-1]
            if table is None:
                verdict = "?"
            elif r not in table:
                verdict = "UNMAPPED in dtogap"
            elif table[r][0] is None:
                verdict = "dtogap says n/a"
            elif table[r][0] == bare or table[r][0].endswith("." + bare):
                verdict = "agree"
            else:
                verdict = "DISAGREE: dtogap has " + table[r][0]
            print(f"{r[:44]:<44} {d[:44]:<44} {n:>4}  {verdict}")
    print(f"-- {len(seen)} route(s) the client NAMED a type for. A route absent "
          f"here never threw, which is not the same as never being wrong.")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--sessions", type=int, default=None,
                   help="only the last N sessions (default: all)")
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("sweep"); s.add_argument("--top", type=int, default=40)
    s.add_argument("--json"); s.set_defaults(fn=cmd_sweep)
    s = sub.add_parser("show"); s.add_argument("n", type=int)
    s.add_argument("--chars", type=int, default=1800); s.set_defaults(fn=cmd_show)
    s = sub.add_parser("routes"); s.set_defaults(fn=cmd_routes)
    s = sub.add_parser("dtos"); s.set_defaults(fn=cmd_dtos)
    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
