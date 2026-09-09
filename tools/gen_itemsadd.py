#!/usr/bin/env python3
"""Generate mods/tarkov/data/post1/itemsadd.json.

The whole item templates that our served payloads REFERENCE but our pre-1.0
db.json does not contain -- lifted verbatim from BSG's captured /client/items
response (capture/raid1 seq 045, `resp_xenc: aes`, decoded). This is the sibling
of itemsgaps.json: itemsgaps splices _props MEMBERS into ids we already ship;
this adds WHOLE ids we do not ship at all (the 1,154 itemsgaps deliberately
skipped are the pool these come from).

Nothing is invented: an id that a payload references but that is absent from the
capture is NOT written here -- it is reported so the reference can be stripped
from its payload instead (there are currently none).

Deterministic: ids sorted, template objects copied verbatim from the capture.
Re-run after changing a served payload; diff the result.
"""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import itemrefs  # noqa: E402

OUT = os.path.join(itemrefs.POST1, "itemsadd.json")


def capture_templates():
    """{id: full template obj} from the /client/items capture (seq 045)."""
    for root in itemrefs.CAP_ROOTS:
        p = os.path.join(root, itemrefs.CAP_REL, "045.json")
        if os.path.exists(p):
            with open(p, "r", encoding="utf-8") as f:
                return json.load(f)["data"]
    raise SystemExit("capture 045.json not found in any known root")


def main():
    db_path = sys.argv[1] if len(sys.argv) > 1 else itemrefs.DEF_DB
    with open(db_path, "r", encoding="utf-8") as f:
        served = set(json.load(f)["templates"]["items"].keys())

    refs = set()
    for s in itemrefs.payload_refs().values():
        refs |= s
    missing = refs - served

    templates = capture_templates()
    add, absent = {}, []
    for tid in sorted(missing):
        if tid in templates:
            add[tid] = templates[tid]
        else:
            absent.append(tid)

    if absent:
        print(f"WARNING: {len(absent)} referenced tpls not in capture "
              f"(strip these from their payloads, do not fabricate):")
        for t in absent:
            print("   ", t)

    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        json.dump(add, f, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
    print(f"wrote {OUT}: {len(add)} whole item templates, "
          f"{os.path.getsize(OUT)} bytes")


if __name__ == "__main__":
    main()
