#!/usr/bin/env python3
"""Two negatives about the settings TREE, asserted against the RENDERED payload.

Not against the source, and not against `tools/nametree.py` -- checking a
generator with its own generator is the check that cannot fail. This fetches
what the backend actually serves (every mod page via `settingsdump.fetch`, and
every SPT catalogue page) and looks for counter-examples:

  A. NO node at depth >= 2 holds zero settings of its own and exactly one child.
     That is the `Ballistics / Armour / ArmorMaterials` defect: two levels, one
     count, nothing to choose between them. Depth-1 nodes are reported
     separately and NOT failed -- a top-level heading with one section under it
     is `Ballistics / Armor Materials`, which is the shape that was asked for.

  B. NO rendered label or path segment contains a lowercase letter immediately
     followed by an uppercase one. That is a machine name on screen.

Fact #122: `value` can be emitted unquoted, so a page can be INVALID JSON.
`settingsdump.fetch_page` repairs tolerantly AND reports; an unparseable page
here is INCONCLUSIVE, never a pass.

    python tools/settingstree_check.py [--port N]
"""
import argparse
import collections
import re
import sys

import settingsdump as sd

CAMEL = re.compile(r"[a-z][A-Z]")


def counts(paths):
    own, kids = collections.Counter(), collections.defaultdict(set)
    for q in paths:
        for i in range(1, len(q) + 1):
            k = tuple(q[:i])
            own[k] += 1 if i == len(q) else 0
            if i > 1:
                kids[tuple(q[:i - 1])].add(k)
    return own, kids


def path_of(row):
    p = row.get("path")
    if isinstance(p, list) and p:
        return [str(x) for x in p]
    cat = row.get("category") or ""
    sub = row.get("subcategory") or ""
    return [x.strip() for x in (cat + "/" + sub).split("/") if x.strip()]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=None)
    a = ap.parse_args()
    port = sd.backend_port(a.port)

    pages = []          # (name, rows)
    inconclusive = []

    _, idx, bad = sd.fetch(port, "/aowlspt/settings/index")
    if idx is None:
        print("INCONCLUSIVE: the mod settings index did not answer: %s" % bad)
        return 2
    for m in (sd.parse_schema(idx)[0] or {}).get("mods", []):
        guid = m.get("guid")
        _, body, err = sd.fetch(port, "/aowlspt/settings/" + guid)
        if body is None:
            inconclusive.append("%s: %s" % (guid, err))
            continue
        doc, invalid, _n = sd.parse_schema(body)
        rows = sd.rows_of(doc) if doc is not None else None
        if invalid:
            inconclusive.append("%s: page is not strict JSON (%s)" % (guid, invalid))
        if isinstance(rows, list):
            pages.append((guid, rows))
        else:
            inconclusive.append("%s: page was not an array" % guid)

    _, sidx, err = sd.fetch(port, "/aowlspt/settings/spt/index")
    if sidx is None:
        inconclusive.append("the SPT catalogue index did not answer: %s" % err)
    else:
        for p in (sd.parse_schema(sidx)[0] or {}).get("pages", []):
            pid = p.get("id")
            _, body, err = sd.fetch(port, "/aowlspt/settings/spt/page/" + pid)
            if body is None:
                inconclusive.append("%s: %s" % (pid, err))
                continue
            doc, invalid, _n = sd.parse_schema(body)
            if invalid:
                inconclusive.append("%s: not strict JSON (%s)" % (pid, invalid))
            if doc is None:
                continue
            pages.append((pid, doc.get("settings", []) + doc.get("nested", [])))

    deep, shallow, camel = [], [], []
    for name, rows in pages:
        paths = [path_of(r) for r in rows]
        own, kids = counts([q for q in paths if q])
        for k in own:
            if own[k] == 0 and len(kids[k]) == 1:
                (deep if len(k) >= 2 else shallow).append(
                    "%s > %s" % (name, " / ".join(k)))
        for r, q in zip(rows, paths):
            for seg in q + [str(r.get("label", ""))]:
                if CAMEL.search(seg):
                    camel.append("%s > %s" % (name, seg))

    print("pages read: %d (%d rows)" % (len(pages), sum(len(r) for _, r in pages)))
    print("A. redundant levels (depth>=2, no own settings, one child): %d" % len(deep))
    for x in deep[:20]:
        print("     FAIL " + x)
    print("   depth-1 single-child headings, kept by design: %s"
          % (", ".join(sorted(set(shallow))) or "none"))
    print("B. labels/segments with a lower->upper boundary: %d" % len(camel))
    for x in sorted(set(camel))[:20]:
        print("     FAIL " + x)
    if inconclusive:
        print("INCONCLUSIVE: %d page(s) could not be read or did not parse strictly:"
              % len(inconclusive))
        for x in inconclusive[:10]:
            print("     " + x)
        return 2
    ok = not deep and not camel
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
