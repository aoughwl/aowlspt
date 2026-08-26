"""Strict-parsing probe for a standalone aowlspt backend.

Every response is parsed with json.loads (never `contains`), and the tool
reports PASS / FAIL / INCONCLUSIVE-shaped facts: status, byte length, whether
the body is strict JSON, and either a requested path or the top-level shape.
"""
import sys, json, argparse, urllib.request, urllib.error

def call(port, route, body=None, method=None, sess=None):
    url = "http://127.0.0.1:%d%s" % (port, route)
    data = None
    if body is not None:
        data = body.encode() if isinstance(body, str) else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method or ("POST" if data is not None else "GET"))
    req.add_header("Accept-Encoding", "identity")
    req.add_header("Content-Type", "application/json")
    if sess:
        req.add_header("Cookie", "PHPSESSID=" + sess)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()

def shape(v, depth=0):
    if isinstance(v, dict):
        return {k: shape(x, depth+1) for k, x in list(v.items())[:40]} if depth < 1 else "{%d keys}" % len(v)
    if isinstance(v, list):
        return ["[%d items]" % len(v)] + ([shape(v[0], depth+1)] if v and depth < 1 else [])
    return type(v).__name__

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("route")
    ap.add_argument("--port", type=int, default=7313)
    ap.add_argument("--body", default=None)
    ap.add_argument("--method", default=None)
    ap.add_argument("--path", default=None, help="dotted path into the parsed body")
    ap.add_argument("--raw", type=int, default=0, help="print N raw chars")
    ap.add_argument("--json", action="store_true", help="dump the selected value as JSON")
    ap.add_argument("--maxchars", type=int, default=2500)
    ap.add_argument("--sess", default=None, help="PHPSESSID cookie value")
    a = ap.parse_args()
    st, raw = call(a.port, a.route, a.body, a.method, a.sess)
    print("%s  status=%d bytes=%d" % (a.route, st, len(raw)))
    if a.raw:
        print("RAW:", raw[:a.raw])
    try:
        doc = json.loads(raw)
    except Exception as e:
        print("STRICT-JSON: FAIL (%s)" % e)
        return 2
    print("STRICT-JSON: PASS")
    v = doc
    if a.path:
        for part in a.path.split("."):
            if part == "":
                continue
            if isinstance(v, list):
                v = v[int(part)]
            elif isinstance(v, dict):
                if part not in v:
                    print("PATH MISSING at %r; keys=%s" % (part, list(v.keys())[:30]))
                    return 3
                v = v[part]
            else:
                print("PATH DEAD-ENDS at %r on %s" % (part, type(v).__name__))
                return 3
    out = json.dumps(v if a.json else shape(v), indent=1, default=str)
    print(out[:a.maxchars] + ("\n...[truncated, %d chars total]" % len(out) if len(out) > a.maxchars else ""))
    return 0

sys.exit(main())
