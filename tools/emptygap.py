#!/usr/bin/env python
"""emptygap.py -- the hole the type audits structurally cannot see.

## Why this exists

`dtotype.py` and `dtodeep.py` audited 72 routes and 8,484 nested members and
reported ZERO fatals. Every one of those checks is about SHAPE: does the member
exist, is it an array where an array is declared, does a scalar sit where a
scalar belongs. All of them pass on this body:

    {"err":0,"data":{"equipmentBuilds":[],"weaponBuilds":[],
                     "magazineBuilds":[]},"errmsg":null}

which is 91 bytes of correct JSON, correctly typed on every key, and which
makes `EFT.UI.EquipmentBuildsScreen.Show` throw
`InvalidOperationException: Sequence contains no elements` out of
`Enumerable.First` -- the kits screen opens and closes in the same frame.
Measured live, the client's own `errors_000.log`, 2026-08-28 14:06:45.

The real backend sends 6,833 bytes there: twelve `BuildType: "Standard"`
loadouts, 352 items between them.

So the missing axis is not type. It is CONTENT. This module measures it:
for every route in a capture, how much the real backend actually SENDS, member
by member, and -- when our own served bodies are supplied -- how much of that
we do not.

## What "content weight" means, precisely

Shape says `[]` is a list. Weight says `[]` is nothing. For each JSON value:

    list        -> number of elements
    dict        -> number of members
    string      -> 1 if non-empty else 0
    number/bool -> 1
    null        -> 0

A member with weight 0 on our side and weight > 0 on BSG's is a HOLE: we
answer the route, we answer it in the right shape, and we answer it with
nothing in it. That is the class of defect this whole file is about, and it is
invisible to every check we had.

## Three outcomes, never two

  HOLE           BSG sends content here; we send none. A player can notice.
  THIN           we send content, but under a tenth of BSG's. Suspicious.
  OK             we send comparable content.
  INCONCLUSIVE   printed when our side was not supplied for a route, or when
                 a body could not be decoded. "I could not look" is not a
                 pass, and this never prints OK for a route it did not read.

Usage:

    python tools/emptygap.py bsg [--capture DIR] [--top N]
        rank the captured routes by how much the real backend sends.

    python tools/emptygap.py diff --ours DIR [--capture DIR]
        diff our served bodies against the capture, member by member.
        DIR holds one file per route, named as the route with '/' replaced by
        '_' (leading '_' dropped), e.g. `client_builds_list.json`.
"""

import argparse
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
DEFAULT_CAPTURE = os.path.join(REPO, "mods", "tarkov", "data", "capture", "raid1")


def weigh(v):
    """The content weight of one JSON value. See the module docstring."""
    if v is None:
        return 0
    if isinstance(v, list):
        return len(v)
    if isinstance(v, dict):
        return len(v)
    if isinstance(v, str):
        return 1 if v else 0
    return 1


def decode(path):
    """One capture body as parsed JSON, or (None, why)."""
    out = subprocess.run(
        [sys.executable, os.path.join(HERE, "bsgwire.py"), "decode", "--full", path],
        capture_output=True, text=True, encoding="utf-8", errors="replace")
    text = out.stdout
    start = text.find("{")
    if start < 0:
        return None, "no JSON object in the decoded body"
    try:
        return json.JSONDecoder().raw_decode(text[start:])[0], None
    except ValueError as exc:
        return None, "the decoded body is not valid JSON: %s" % exc


def payload(doc):
    """The part of an envelope a screen actually reads."""
    if isinstance(doc, dict) and "data" in doc and set(doc) <= {"err", "data", "errmsg"}:
        return doc["data"]
    return doc


def members(value):
    """Top-level members of a payload as {name: weight}, or None if it is
    not an object -- an array payload is weighed whole, under ''."""
    if isinstance(value, dict):
        return {k: weigh(v) for k, v in value.items()}
    return {"": weigh(value)}


def manifest(capture):
    with open(os.path.join(capture, "manifest.json"), "r", encoding="utf-8") as f:
        return json.load(f)


def responses(capture):
    """{url: (seq, declen)} keeping the LARGEST captured response per route.

    The largest, not the first: `/client/builds/list` appears three times and
    only the third (seq 441) has a player's own saved build in it. Ranking off
    a smaller sample would understate what the route really carries.
    """
    best = {}
    for e in manifest(capture):
        url = e.get("url", "")
        if not url or e.get("status") != "200":
            continue
        try:
            declen = int(e.get("resp_declen", 0))
        except (TypeError, ValueError):
            declen = 0
        if url not in best or declen > best[url][1]:
            best[url] = (e.get("seq", ""), declen)
    return best


def load_ours(directory, url):
    name = url.lstrip("/").replace("/", "_").split("?")[0] + ".json"
    path = os.path.join(directory, name)
    if not os.path.exists(path):
        return None, "no served body at %s" % path
    with open(path, "r", encoding="utf-8") as f:
        try:
            return json.load(f), None
        except ValueError as exc:
            return None, "our served body is not valid JSON: %s" % exc


def cmd_bsg(args):
    best = responses(args.capture)
    rows = []
    for url, (seq, declen) in best.items():
        rows.append((declen, url, seq))
    rows.sort(reverse=True)
    print("%8s  %5s  %s" % ("bytes", "seq", "route"))
    for declen, url, seq in rows[:args.top]:
        print("%8d  %5s  %s" % (declen, seq, url))
    print()
    print("%d routes captured; the size is the REAL backend's decompressed body."
          % len(rows))
    print("A route we answer in far fewer bytes is where to look next.")
    return 0


def cmd_diff(args):
    best = responses(args.capture)
    holes, thin, ok, inconclusive = [], [], [], []
    for url in sorted(best):
        seq, declen = best[url]
        ours, why = load_ours(args.ours, url)
        if ours is None:
            inconclusive.append((url, why))
            continue
        path = os.path.join(args.capture, "responses", "%s.json" % seq)
        if not os.path.exists(path):
            inconclusive.append((url, "no captured response file for seq %s" % seq))
            continue
        theirs, why = decode(path)
        if theirs is None:
            inconclusive.append((url, why))
            continue
        tm = members(payload(theirs))
        om = members(payload(ours))
        missing = []
        light = []
        for name, tw in sorted(tm.items()):
            ow = om.get(name)
            if ow is None:
                missing.append("%s (absent; BSG weight %d)" % (name or "<payload>", tw))
            elif tw > 0 and ow == 0:
                missing.append("%s (empty; BSG weight %d)" % (name or "<payload>", tw))
            elif tw > 0 and ow * 10 < tw:
                light.append("%s (%d vs %d)" % (name or "<payload>", ow, tw))
        if missing:
            holes.append((url, missing, light))
        elif light:
            thin.append((url, light))
        else:
            ok.append(url)

    for url, missing, light in holes:
        print("HOLE          %s" % url)
        for m in missing:
            print("                  %s" % m)
        for m in light:
            print("              thin: %s" % m)
    for url, light in thin:
        print("THIN          %s" % url)
        for m in light:
            print("                  %s" % m)
    for url in ok:
        print("OK            %s" % url)
    for url, why in inconclusive:
        print("INCONCLUSIVE  %s -- %s" % (url, why))
    print()
    print("%d HOLE, %d THIN, %d OK, %d INCONCLUSIVE"
          % (len(holes), len(thin), len(ok), len(inconclusive)))
    print("INCONCLUSIVE is not a pass. It means this did not look.")
    return 1 if holes else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd")
    b = sub.add_parser("bsg", help="rank captured routes by what BSG sends")
    b.add_argument("--capture", default=DEFAULT_CAPTURE)
    b.add_argument("--top", type=int, default=40)
    b.set_defaults(fn=cmd_bsg)
    d = sub.add_parser("diff", help="diff our served bodies against the capture")
    d.add_argument("--capture", default=DEFAULT_CAPTURE)
    d.add_argument("--ours", required=True)
    d.set_defaults(fn=cmd_diff)
    args = ap.parse_args()
    if not getattr(args, "fn", None):
        ap.print_help()
        return 2
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
