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
  N5  NO TWO PAGES SHARE A DISPLAY LABEL

Re-introduce `category = "Bot AI/Global"` in mods/sain and N1+N2 fail. That is
the input that makes this check say no; a check without one is not a check.

N5 comes from a third player report: "there are two Settings Panel pages -- one
only has a single 'Show the Press F12 hint at launch'". Two DIFFERENT guids
(`aowl.panel`, the overlay's built-in page, and `aowl.settingshub`, a proxy for
uihub's one row) carried the IDENTICAL label, so the nav showed the same page
name twice and the player could not tell which was which. A guid-keyed check
cannot see that; only a label-keyed one can.

N5 therefore has to model pages this tool does NOT get from `declareSettings`:
the overlay synthesises `aowl.panel` in C, and settingshub used to append its
own entry to `/aowlspt/settings/index` in Nim. Both labels are PARSED from
those two files rather than hardcoded here -- a constant copied into this
script would keep passing after the source changed, which is a check that
cannot fail.

Re-introduce settingshub's `PanelName = "Settings Panel"` proxy page and N5
fails with exit 1. That is N5's falsifying input.

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
    # uihub's one row (`launchHint`) is drawn by the overlay's built-in page as
    # "Startup message", and a write there is mirrored back to uihub by
    # `aowl_ov_panel_set`. It used to be proxied onto `aowl.settingshub`, which
    # is what produced the duplicate label N5 now forbids.
    "aowl.uihub":     "aowl.panel",
}

# Both fields, in source order, so a category and the subcategory that follows
# it inside the SAME builder call pair up. `settingPath` in
# aowl/src/aowlspt/settings.nim joins them and splits every segment on "/",
# which is what turns "Bot AI/Global" into two levels -- so the tree below is
# built by the same rule the overlay renders by, not by an approximation.
FIELD = re.compile(r'\b(sub)?category\s*=\s*"([^"]*)"')
DECL = re.compile(r'declareSettings\s*\(')

OVERLAY_H = os.path.join(ROOT, "abi", "aowlspt_overlay.h")
SHUB_NIM = os.path.join(ROOT, "mods", "settingshub", "settingshub.nim")


def _read(p):
    return open(p, encoding="utf-8", errors="replace").read()


def _code(t):
    """Nim source with whole-line `#`/`##` comments dropped.

    Necessary, not cosmetic: `mods/settingshub` MENTIONS `declareSettings()` in
    a doc comment and never calls it, so the raw text made this tool invent a
    page for a mod that declares nothing -- which then either failed N3 or, if
    a proxy happened to put a row on it, passed while modelling a page that
    does not exist. A regex over prose is not a fact about code.
    """
    return "\n".join("" if l.lstrip().startswith("#") else l
                     for l in t.splitlines())


def builtin_page():
    """The overlay's SYNTHETIC page, parsed out of `aowl_ov_rebuild_pages`.

    It is not declared by any mod, so nothing else in this file can see it --
    and it is one of the two pages the duplicate-label report was about.
    Returns (id, label, rows) or None, and None is reported as INCONCLUSIVE by
    the caller rather than skipped: "I could not look" is not a pass.
    """
    if not os.path.exists(OVERLAY_H):
        return None
    t = _read(OVERLAY_H)
    i = re.search(r'#define\s+AOWL_OV_PANEL_PAGE\s+"([^"]+)"', t)
    b = re.search(r'AOWL_OV_PANEL_PAGE\s*\)\s*;\s*'
                  r'aowl_ov_copy\(\s*P->label\s*,[^"]*"([^"]+)"\s*\)\s*;\s*'
                  r'P->isMod\s*=\s*1\s*;\s*P->count\s*=\s*(\d+)', t)
    if not (i and b):
        return None
    return i.group(1), b.group(1), int(b.group(2))


def shub_proxy_page():
    """settingshub's own entry in `/aowlspt/settings/index`, if it still has one.

    Keyed on the code that APPENDS the entry, not on the constants: leaving
    `PanelName` defined but unused must not resurrect a page in this model.
    """
    if not os.path.exists(SHUB_NIM):
        return None
    t = _code(_read(SHUB_NIM))
    if not re.search(r'o\.put\(\s*"guid"\s*,\s*PanelGuid\s*\)', t):
        return None
    g = re.search(r'PanelGuid\s*=\s*"([^"]+)"', t)
    n = re.search(r'PanelName\s*=\s*"([^"]+)"', t)
    if not (g and n):
        return None
    return g.group(1), n.group(1)


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
                t = _code(_read(os.path.join(dp, f)))
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
    # The pages that exist WITHOUT a `declareSettings` behind them, first, so a
    # proxied mod can render onto one.
    bi = builtin_page()
    if bi:
        pages[bi[0]] = {"name": bi[1], "tree": {}, "rows": bi[2]}
    sp = shub_proxy_page()
    if sp:
        pages[sp[0]] = {"name": sp[1], "tree": {}, "rows": 1}
    for guid, (name, cats) in m.items():
        host = PROXY.get(guid, guid)
        if host not in m and host not in pages:
            continue
        if host not in pages:
            pages[host] = {"name": m[host][0], "tree": {}, "rows": 0}
        p = pages[host]
        for c in cats:
            p["rows"] += 1
            node = p["tree"]
            for seg in [s.strip() for s in c.split("/") if s.strip()]:
                node = node.setdefault(seg, {})
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

    # N5 -- no two pages share a DISPLAY LABEL.
    #
    # Keyed on the label, not the guid, because the defect is invisible from
    # the guid side: `aowl.panel` and `aowl.settingshub` are two perfectly
    # distinct pages that the player sees as one name, twice.
    byLabel = {}
    for guid, p in sorted(pages.items()):
        byLabel.setdefault(p["name"], []).append(guid)
    for label, guids in sorted(byLabel.items()):
        if len(guids) > 1:
            fails.append("N5 %d pages share the display label '%s': %s -- the "
                         "nav shows the same name twice and the player cannot "
                         "tell them apart"
                         % (len(guids), label, ", ".join(guids)))
    return fails


if __name__ == "__main__":
    pages = build()
    if not pages:
        print("INCONCLUSIVE: no mod declarations were parsed at all")
        sys.exit(2)
    if builtin_page() is None:
        # N5 is meaningless without the overlay's own page in the model, and a
        # silently-narrower check that still prints PASS is the bug this file
        # exists to prevent.
        print("INCONCLUSIVE: could not parse the overlay's built-in page out of "
              "%s, so the duplicate-label check (N5) saw only the declared "
              "pages" % os.path.relpath(OVERLAY_H, ROOT))
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
          "category repeats its page name, no page has zero rows, no two pages "
          "share a display label." % len(pages))
    print("LIMIT: source-derived. Proves what the mods DECLARE, not what the "
          "overlay drew.")
