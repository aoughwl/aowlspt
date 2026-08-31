#!/usr/bin/env python3
"""Assert that a payload WE SERVE carries no value of the wrong JSON type.

The falsifiable negative behind `mods/tarkov/emu/shapes.nim`. Not "the repair
ran" and not "the writer was fixed" -- both of those are self-comparisons. This
asks the finished payload, off the wire, and fails if ANY occurrence of a ruled
field has a kind outside its measured allowed set.

    python tools/shapeaudit.py --port 6969 /client/game/profile/list
    python tools/shapeaudit.py --port 6969 --all
    python tools/shapeaudit.py --selftest

Why a live backend and not a unit test: the boolean that killed the client on
2026-08-31 was written by `emu/quests.setState`'s ADD branch, which only fires
for a quest not already in the profile -- i.e. exactly for a MOD-ADDED quest
(`ad0000000000000000000101`, the admintrader) and for nothing else. A test over
literals cannot see that; the served list can. **The admintrader mod must be
enabled in `mods\\aowlspt-selection.json` or the bug cannot appear** -- a mod on
disk but absent from the selection is silently not loaded, and this tool says so
rather than passing on an empty world.

Exit 0 = clean, 1 = a wrong-typed value is being served, 2 = INCONCLUSIVE
(nothing to look at). Three outcomes, never two.

The rules are duplicated from `emu/shapes.nim` on purpose: an audit that
imported the thing it audits would agree with a bug in the table.
"""

import argparse
import http.client
import json
import os
import sys
import zlib

# (field, allowed kinds). Measured with tools/fieldshape.py against the live
# db.json; see emu/shapes.nim for the numbers and the reasoning.
RULES = {
    "availableAfter": {"number"},
    "insurance_price_coef": {"number", "string"},
}

# Routes worth auditing, with a body when the route needs a POST.
ROUTES = [
    ("/client/game/profile/list", {}),
    ("/client/trading/api/getTradersList", {}),
    ("/client/items", {}),
]


def kind(v):
    if v is True or v is False:
        return "boolean"
    if v is None:
        return "null"
    if isinstance(v, str):
        return "string"
    if isinstance(v, (int, float)):
        return "number"
    if isinstance(v, list):
        return "array"
    if isinstance(v, dict):
        return "object"
    return "?"


def walk(node, path, out):
    """Every (json-path, field, kind, value) in `node` that a rule covers."""
    if isinstance(node, dict):
        for k, v in node.items():
            p = "%s.%s" % (path, k) if path else k
            if k in RULES and kind(v) not in RULES[k]:
                out.append((p, k, kind(v), v))
            walk(v, p, out)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            walk(v, "%s[%d]" % (path, i), out)


def call(host, port, path, body, timeout=60):
    c = http.client.HTTPConnection(host, port, timeout=timeout)
    payload = b"" if body is None else json.dumps(body).encode("utf-8")
    c.request("POST" if body is not None else "GET", path, payload, {
        "Accept-Encoding": "identity",
        "Content-Type": "application/json",
        "Cookie": "PHPSESSID=",
    })
    r = c.getresponse()
    raw = r.read()
    status = r.status
    c.close()
    if raw[:2] in (b"\x78\x01", b"\x78\x9c", b"\x78\xda"):
        try:
            raw = zlib.decompress(raw)
        except zlib.error:
            pass
    text = raw.decode("utf-8", "replace")
    try:
        return status, text, json.loads(text)
    except ValueError:
        return status, text, None


def audit_route(host, port, path, body, verbose):
    try:
        status, text, doc = call(host, port, path, body)
    except (OSError, http.client.HTTPException) as e:
        # Never a traceback: "I could not look" is a THIRD outcome, and an
        # exception here would read as a crash with no verdict. NOTE for the
        # caller: MSYS/Git-Bash rewrites a leading-slash argument into a Windows
        # path, so run this from PowerShell or set MSYS_NO_PATHCONV=1.
        print("INCONCLUSIVE %-42s could not reach the backend: %s" % (path, e))
        return None
    if doc is None:
        print("INCONCLUSIVE %-42s status %s, body is not JSON (%d bytes)"
              % (path, status, len(text)))
        return None
    payload = doc.get("data", doc) if isinstance(doc, dict) else doc
    if payload is None or payload == [] or payload == {}:
        print("INCONCLUSIVE %-42s served an EMPTY payload -- nothing to audit. "
              "Is the mod enabled in aowlspt-selection.json?" % path)
        return None
    bad = []
    walk(payload, "", bad)
    if bad:
        print("FAIL         %-42s %d wrong-typed value(s)" % (path, len(bad)))
        for p, f, k, v in bad[:20]:
            print("    %s = %s (%s); stock data uses only {%s}"
                  % (p, json.dumps(v)[:40], k, ", ".join(sorted(RULES[f]))))
        if len(bad) > 20:
            print("    ... and %d more" % (len(bad) - 20))
    else:
        n = []
        walk_all(payload, n)
        print("ok           %-42s %d ruled field(s) checked, all correct"
              % (path, n[0] if n else 0))
    return bad


def walk_all(node, acc, seen=None):
    """Count every occurrence of a ruled field, right or wrong -- so 'ok' on a
    payload that contained none of them can be told apart from a real pass."""
    if not acc:
        acc.append(0)
    if isinstance(node, dict):
        for k, v in node.items():
            if k in RULES:
                acc[0] += 1
            walk_all(v, acc)
    elif isinstance(node, list):
        for v in node:
            walk_all(v, acc)


def selftest():
    """Prove the auditor can FAIL, on the exact document that killed the client."""
    doc = {"data": [{"Quests": [{"qid": "a", "availableAfter": 0},
                                {"qid": "ad0000000000000000000101",
                                 "availableAfter": False}]}]}
    bad = []
    walk(doc["data"], "", bad)
    ok = len(bad) == 1 and bad[0][2] == "boolean" and "[1]" in bad[0][0]
    print("%-4s the reproduced live document is FLAGGED (path %s)"
          % ("ok" if ok else "FAIL", bad[0][0] if bad else "<nothing found>"))
    clean = {"Quests": [{"availableAfter": 0}, {"availableAfter": 86400}]}
    b2 = []
    walk(clean, "", b2)
    ok2 = not b2
    print("%-4s a correct document is NOT flagged" % ("ok" if ok2 else "FAIL"))
    poly = {"a": {"insurance_price_coef": "17"},
            "b": {"insurance_price_coef": 10}}
    b3 = []
    walk(poly, "", b3)
    ok3 = not b3
    print("%-4s polymorphic insurance_price_coef (string AND number, both "
          "stock) is NOT flagged" % ("ok" if ok3 else "FAIL"))
    bad_all = ok and ok2 and ok3
    print("\n%s" % ("PASS" if bad_all else "FAIL"))
    return 0 if bad_all else 1


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("routes", nargs="*", help="routes to audit (default: --all)")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int,
                   default=int(os.environ.get("AOWL_PORT", "6969")),
                   help="backend port (default 6969 -- MEASURED, the backend "
                        "does NOT listen on 80 for this)")
    p.add_argument("--all", action="store_true", help="audit every known route")
    p.add_argument("--selftest", action="store_true",
                   help="prove the auditor can fail; needs no backend")
    p.add_argument("-v", "--verbose", action="store_true")
    a = p.parse_args()
    if a.selftest:
        return selftest()
    todo = ROUTES if (a.all or not a.routes) else [(r, {}) for r in a.routes]
    any_bad = False
    any_looked = False
    for path, body in todo:
        bad = audit_route(a.host, a.port, path, body, a.verbose)
        if bad is None:
            continue
        any_looked = True
        if bad:
            any_bad = True
    if not any_looked:
        print("\nINCONCLUSIVE: nothing was audited. 'I could not look' is not a "
              "pass. Is aowlspt-backend.exe running on port %d?" % a.port)
        return 2
    print("\n%s" % ("FAIL: we are serving values of the wrong JSON type"
                    if any_bad else
                    "PASS: no ruled field is served with a wrong type"))
    return 1 if any_bad else 0


if __name__ == "__main__":
    sys.exit(main())
