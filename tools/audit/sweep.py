"""Sweep every registered route and name the ones that answer emptily.

A 200 is not evidence. This asks each route once, parses strictly, and sorts
the answers into: MEANINGFUL (data is a non-empty object/array/scalar),
EMPTY-ENVELOPE (`err:0` with `data` `{}` / `[]` / null), ERROR-ENVELOPE
(`err` non-zero), NOT-JSON, and HTTP-4xx/5xx. The EMPTY-ENVELOPE column is the
silent-degradation census: those are the routes that look healthy and carry
nothing.

Routes whose name says they mutate are listed and NOT called -- reported as
INCONCLUSIVE rather than quietly skipped.
"""
import json, sys, re, urllib.request, urllib.error, argparse

MUTATING = re.compile(
    r"(select|create|delete|remove|reset|save|set|write|start|end|stop|"
    r"accept|complete|buy|sell|add|apply|upgrade|put|regenerate|fetch|"
    r"moving|raid/config|match/local|offline)", re.I)


def ask(port, route, sess):
    req = urllib.request.Request("http://127.0.0.1:%d%s" % (port, route),
                                 data=b"{}", method="POST")
    req.add_header("Accept-Encoding", "identity")
    req.add_header("Content-Type", "application/json")
    req.add_header("Cookie", "PHPSESSID=" + sess)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except Exception as e:
        return -1, str(e).encode()


def classify(status, raw):
    if status >= 400 or status < 0:
        return "HTTP-%s" % status, len(raw)
    try:
        doc = json.loads(raw)
    except Exception:
        return "NOT-JSON", len(raw)
    if isinstance(doc, dict) and "err" in doc and "data" in doc:
        err = doc.get("err")
        if err not in (0, None, "0"):
            return "ERROR-ENVELOPE", len(raw)
        d = doc.get("data")
        if d is None or d == {} or d == [] or d == "":
            return "EMPTY-ENVELOPE", len(raw)
        return "MEANINGFUL", len(raw)
    if doc in ({}, [], None):
        return "EMPTY-BODY", len(raw)
    return "MEANINGFUL(bare)", len(raw)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("routefile")
    ap.add_argument("--port", type=int, default=7313)
    ap.add_argument("--sess", required=True)
    a = ap.parse_args()
    routes = []
    for line in open(a.routefile, encoding="utf-8", errors="replace"):
        m = re.search(r"\bok\s+route\s+(\S+)", line)
        if m:
            routes.append(m.group(1))
    routes = sorted(set(routes))
    buckets = {}
    skipped = []
    for r in routes:
        if MUTATING.search(r):
            skipped.append(r)
            continue
        st, raw = ask(a.port, r, a.sess)
        k, n = classify(st, raw)
        buckets.setdefault(k, []).append((r, n))
    for k in sorted(buckets):
        print("== %s (%d)" % (k, len(buckets[k])))
        if k in ("MEANINGFUL", "MEANINGFUL(bare)"):
            continue
        for r, n in buckets[k]:
            print("   %-52s %d bytes" % (r, n))
    print("\n== NOT CALLED, name says it mutates (%d) -- INCONCLUSIVE"
          % len(skipped))
    print("   " + ", ".join(skipped))
    return 0


sys.exit(main())
