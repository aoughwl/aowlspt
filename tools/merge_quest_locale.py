#!/usr/bin/env python3
"""Merge missing quest locale strings into the post-1.0 served locale.

The served locale (mods/tarkov/data/post1/locale_en.json) is decoded from a
real post-1.0 client capture (~33k keys). It carries quest NAMES but is missing
most quest DESCRIPTIONS, condition text, success/fail/player messages -- so
in-game the description renders as the raw locale key ("<questId> description").

This fills those gaps from the SPT 4.x database locale (locales.global.en),
restricted to the ids the server actually serves: the 558 quest ids in
templates.quests and every condition id nested inside them. A key is added ONLY
when the real capture lacks it -- the capture is the true post-1.0 text and wins
every conflict; SPT only fills holes.

Sources (edit paths if they move):
  DB   = build/db/db.json          (importdb output; has templates.quests + locales)
  Out  = mods/tarkov/data/post1/locale_en.json  (rewritten in place, minified UTF-8)
"""
import json, sys

REPO = "C:/Users/savant/Projects/aowlspt-questloc"
# db.json is the importdb output; it lives in the main checkout's build dir.
DB   = "C:/Users/savant/Projects/aowlspt/build/db/db.json"
OUT  = REPO + "/mods/tarkov/data/post1/locale_en.json"

def main():
    db = json.load(open(DB, encoding="utf-8"))
    quests = db["templates"]["quests"]
    spt = db["locales"]["global"]["en"]          # SPT full en locale
    ours = json.load(open(OUT, encoding="utf-8"))

    qids = set(quests.keys())
    cond = set()
    def walk(o):
        if isinstance(o, dict):
            v = o.get("id")
            if isinstance(v, str):
                cond.add(v)
            for x in o.values():
                walk(x)
        elif isinstance(o, list):
            for x in o:
                walk(x)
    for q in quests.values():
        walk(q.get("conditions", {}))

    served = qids | cond
    lead = lambda k: k.split(" ", 1)[0]

    added = {}
    for k, v in spt.items():
        if lead(k) in served and k not in ours:
            added[k] = v

    for k, v in added.items():
        ours[k] = v

    # minified single line, UTF-8, no ASCII escaping (matches source file style)
    with open(OUT, "w", encoding="utf-8", newline="") as f:
        json.dump(ours, f, ensure_ascii=False, separators=(",", ":"))

    # report
    from collections import Counter
    c = Counter()
    for k in added:
        p = k.split(" ", 1)
        c[p[1] if len(p) > 1 else "(condition text: id-only key)"] += 1
    print(f"served quest ids: {len(qids)}   nested condition ids: {len(cond)}")
    print(f"keys added (missing from capture, sourced from SPT): {len(added)}")
    for s, n in c.most_common():
        print(f"  {n:5} {s!r}")
    no_desc = [q for q in qids if f"{q} description" not in ours]
    no_name = [q for q in qids if f"{q} name" not in ours]
    print(f"served quests still missing name:        {len(no_name)} {no_name[:5]}")
    print(f"served quests still missing description: {len(no_desc)} {no_desc[:5]}")
    print(f"total locale keys now: {len(ours)}")

if __name__ == "__main__":
    main()
