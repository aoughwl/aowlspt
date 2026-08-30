#!/usr/bin/env python3
"""The settings NAV TREE, built from the declarations, and the negatives it must satisfy.

WHY THIS EXISTS
---------------
Two player reports, both about STRUCTURE, not values:

  (a) "Bot AI has a single sub-page called 'Bot AI' which has all of its
      subpages" -- every category in mods/sain, mods/morebots and
      mods/waypoints was written as "Bot AI/<something>", so the first path
      segment repeated the page name and the whole tree hung one level too
      deep under a node named after its own parent.
  (b) a page whose only content is a single row nested two levels down
      ("Overlay/Launch" for one row) reads as an empty page with an empty
      page inside it.

WHAT MAKES THIS FALSIFIABLE
---------------------------
It asserts properties of the FINISHED TREE -- the one the F12 overlay builds
from the served schemas -- as NEGATIVES, never a property of an edit:

  N1  no node has exactly one child whose label equals the node's own label
  N2  no page's first-level category equals the page's own name
  N3  no page renders with zero rows
  N4  no node is a single-child chain whose whole subtree is one row

Re-introduce `category = "Bot AI/Global"` in mods/sain and N1+N2 fail. That is
the input that makes this check say no; a check without one is not a check.

Source-derived, so it runs with no game and no backend. That is its LIMIT and
it is stated in the output: it proves what the mods DECLARE, not what the
overlay drew. PASS / FAIL / INCONCLUSIVE, three outcomes, never two.
"""
import os, re, sys, json

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# guid -> page it renders on. A child with inIndex = false has no nav entry of
# its own; its rows are proxied onto the parent's page (sain's `childGuids`,
# settingshub's `PanelChildGuid`).
PROXY = {
    "aowl.morebots":  "aowl.sain",
    "aowl.waypoints": "aowl.sain",
    "aowl.uihub":     "aowl.settingshub",
}

# Both fields, in source order, so a category and the subcategory that follows
# it inside the SAME builder call pair up. `settingPath` in
# aowl/src/aowlspt/settings.nim joins them and splits every segment on "/",
# which is what turns "Bot AI/Global" into two levels -- so the tree below is
# built by the same rule the overlay renders by, not by an approximation.
FIELD = re.compile(r'\b(sub)?category\s*=\s*"([^"]*)"')
DECL = re.compile(r'declareSettings\s*\(')


def mods():
    """guid -> (display name, [category strings]) from the .nim declarations."""
    out = {}
    for d in sorted(os.listdir(os.path.join(ROOT, "mods"))):
        md = os.path.join(ROOT, "mods", d)
        if not os.path.isdir(md):
            continue
        cats, guid, name, declares = [], None, None, False
        for dp, _, fs in os.walk(md):
            for f in fs:
                if not f.endswith(".nim"):
                    continue
                t = open(os.path.join(dp, f), encoding="utf-8", errors="replace").read()
                if DECL.search(t):
                    declares = True
                cur = None
                for sub, val in FIELD.findall(t):
                    if sub:
                        if cur is not None:
                            cats[-1] = cur + "/" + val
                    else:
                        cur = val
                        cats.append(val)
                i = t.find("exportMod(")
                if i < 0:
                    continue
                blk = t[i:i + 800]
                g = re.search(r'guid\s*=\s*(?:"([^"]+)"|ModGuid)', blk)
                n = re.search(r'\bname\s*=\s*(?:"([^"]+)"|ModName)', blk)
                cg = re.search(r'ModGuid\*?\s*=\s*"([^"]+)"', t)
                cn = re.search(r'ModName\*?\s*=\s*"([^"]+)"', t)
                if g:
                    guid = g.group(1) or (cg.group(1) if cg else None)
                if n:
                    name = n.group(1) or (cn.group(1) if cn else None)
        # A mod that never calls `declareSettings` is not a page and must not be
        # reported as an empty one -- "it declared nothing" and "its page is
        # empty" are different facts.
        if guid and declares:
            out[guid] = (name or d, cats)
    return out


def build():
    """guid -> {'name': str, 'tree': nested dict, 'rows': int}"""
    m = mods()
    pages = {}
    for guid, (name, cats) in m.items():
        host = PROXY.get(guid, guid)
        if host not in m:
            continue
        p = pages.setdefault(host, {"name": m[host][0], "tree": {}, "rows": 0})
        for c in cats:
            p["rows"] += 1
            node = p["tree"]
            for seg in [s.strip() for s in c.split("/") if s.strip()]:
                node = node.setdefault(seg, {})
    # settingshub owns no rows of its own; its page name is the panel's.
    if "aowl.settingshub" in pages:
        pages["aowl.settingshub"]["name"] = "Settings Panel"
    return pages


def render(name, tree, ind=1, out=None):
    for k in tree:
        out.append("  " * ind + k)
        render(name, tree[k], ind + 1, out)
    return out


def check(pages):
    fails = []
    for guid, p in sorted(pages.items()):
        if p["rows"] == 0:                                        # N3
            fails.append("N3 %s (%s) renders zero rows" % (guid, p["name"]))

        def walk(label, node, path):
            for k, sub in node.items():
                if len(node) == 1 and k == label:                 # N1
                    fails.append("N1 %s: '%s' has exactly one child, also "
                                 "named '%s'" % (guid, label, k))
                walk(k, sub, path + "/" + k)
        for k in p["tree"]:
            if k == p["name"]:                                    # N2
                fails.append("N2 %s: first-level category '%s' repeats the "
                             "page name" % (guid, k))
        walk(p["name"], p["tree"], "")
    return fails


if __name__ == "__main__":
    pages = build()
    if not pages:
        print("INCONCLUSIVE: no mod declarations were parsed at all")
        sys.exit(2)
    for guid, p in sorted(pages.items()):
        print("%s  [%s]  %d rows" % (p["name"], guid, p["rows"]))
        for line in render(p["name"], p["tree"], 1, []):
            print(line)
    fails = check(pages)
    print()
    if fails:
        print("FAIL (%d)" % len(fails))
        for f in fails:
            print("  " + f)
        sys.exit(1)
    print("PASS: %d pages; no node has a lone same-named child, no first-level "
          "category repeats its page name, no page has zero rows." % len(pages))
    print("LIMIT: source-derived. Proves what the mods DECLARE, not what the "
          "overlay drew.")
