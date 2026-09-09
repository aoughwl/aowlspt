#!/usr/bin/env python3
"""Referential-integrity check for served item-template references.

Every item template a served payload REFERENCES must resolve to an item template
the server serves in `/client/items`. A reference to a tpl not in the served item
table makes the client throw

    Cannot find template with id '<tpl>' for item

and hang (a wrong-shape / unresolvable response hangs rather than errors). This is
the class of hole the emptygap audit did not cover: it checked each route's own
body, not the cross-reference between a payload and the item DB.

WHAT COUNTS AS AN ITEM-TEMPLATE REFERENCE (measured against db.json, not guessed):
  * `_tpl`                       always an item-template reference
  * `itemId`                     reward/requirement item (the throwing case)
  * `templateId`                 quest-note item reference (ids land in item space)
  * `value` where sibling
    `field == "_tpl"`            a condition filter whose value IS an item tpl
NOT item references (resolve against other tables, excluded):
  * `id` `_id` `chapterId` `parentId` `traderId` `seasonId` `Id` `Root` (self ids)
  * `target` under type CustomizationDirect, `mailTemplateId` (other entity kinds)

SERVED ITEM SET (set B):
  templates.items keys of db.json, PLUS keys of post1/itemsadd.json (whole new
  BSG templates spliced in by emu/itemsadd.nim), PLUS the _props-only augmentation
  in post1/itemsgaps.json touches EXISTING ids only, so it changes no key here.

Three outcomes per missing tpl (CLAUDE.md 9b):
  FAIL         missing but PRESENT in a BSG capture -> add from capture (RED until).
  INCONCLUSIVE missing and NOT in any capture -> cannot source; strip + log.
  PASS         every reference resolves.

Exit 0 iff GREEN.
"""
import json, os, sys, argparse

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
POST1 = os.path.join(REPO, "mods", "tarkov", "data", "post1")
DEF_DB = r"D:\Aowlspt\aowlspt\db.json"

# Capture bodies are gitignored and live only in a full checkout. Try the
# worktree first, then the canonical main checkout.
CAP_REL = os.path.join("mods", "tarkov", "data", "capture", "raid1",
                       "responses", "large")
CAP_ROOTS = [REPO, r"C:\Users\savant\Projects\aowlspt"]
CAP_FILES = ["045.json", "043.json"]

# post1 files that embed item references. Enumerated, not globbed: a new payload
# is a deliberate edit here so the check's scope is auditable.
SERVED_PAYLOADS = [
    "battlepassactive.json",
    "defaultequipmentpresets.json",
    "endinglist.json",
    "seasonactive.json",
    "seasonalperks.json",
    "mainquestnotes.json",
]

REF_KEYS = ("_tpl", "itemId", "templateId")


def collect_refs(node, out):
    """Add every item-template reference in `node` to set `out` (context-aware)."""
    if isinstance(node, dict):
        fld = node.get("field")
        for k, v in node.items():
            if isinstance(v, str):
                if k in REF_KEYS:
                    out.add(v)
                elif k == "value" and fld == "_tpl":
                    out.add(v)
            collect_refs(v, out)
    elif isinstance(node, list):
        for v in node:
            collect_refs(v, out)


def payload_refs():
    """{payload_name: set(referenced tpls)} for every served payload present."""
    result = {}
    for name in SERVED_PAYLOADS:
        path = os.path.join(POST1, name)
        if not os.path.exists(path):
            continue
        with open(path, "r", encoding="utf-8") as f:
            doc = json.load(f)
        refs = set()
        collect_refs(doc, refs)
        result[name] = refs
    return result


def served_set(db_path):
    with open(db_path, "r", encoding="utf-8") as f:
        db = json.load(f)
    served = set(db.get("templates", {}).get("items", {}).keys())
    add_path = os.path.join(POST1, "itemsadd.json")
    added = set()
    if os.path.exists(add_path):
        with open(add_path, "r", encoding="utf-8") as f:
            added = set(json.load(f).keys())
        served |= added
    return served, added


def capture_ids():
    ids = set()
    for root in CAP_ROOTS:
        for fn in CAP_FILES:
            p = os.path.join(root, CAP_REL, fn)
            if not os.path.exists(p):
                continue
            try:
                with open(p, "r", encoding="utf-8") as f:
                    doc = json.load(f)
            except Exception:
                continue
            data = doc.get("data") if isinstance(doc, dict) else None
            if isinstance(data, dict):
                ids |= set(data.keys())
        if ids:
            break
    return ids


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default=DEF_DB)
    ap.add_argument("--no-capture", action="store_true")
    args = ap.parse_args()

    if not os.path.exists(args.db):
        print(f"INCONCLUSIVE: db not found: {args.db}")
        return 2

    served, added = served_set(args.db)
    print(f"served item templates: {len(served)} "
          f"(db + {len(added)} from itemsadd.json)")

    per = payload_refs()
    cap = set() if args.no_capture else capture_ids()
    if not args.no_capture:
        print(f"capture /client/items ids: {len(cap)}")

    print()
    all_missing = set()
    total = 0
    for name, refs in per.items():
        missing = sorted(refs - served)
        all_missing |= set(missing)
        total += len(missing)
        tag = "OK" if not missing else "MISSING"
        print(f"[{tag}] {name}: {len(refs)} refs, {len(missing)} missing")
        for t in missing:
            where = ("in-capture(FAIL->add)" if t in cap
                     else "NOT-in-capture(INCONCLUSIVE->strip)")
            print(f"        {t}  {where}")

    print()
    if total == 0:
        print("PASS: every referenced item template resolves to a served item.")
        return 0
    addable = sum(1 for t in all_missing if t in cap)
    print(f"FAIL: {total} missing reference(s), {len(all_missing)} distinct; "
          f"{addable} addable from capture, {len(all_missing)-addable} inconclusive.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
