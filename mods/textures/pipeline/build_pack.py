#!/usr/bin/env python3
"""build_pack.py -- turn TarkovTextures/ into a deployable aowlspt texture pack.

This is the overhaul of the original TarkovTextures pipeline. It reads the
match table the original matcher already produced (`output/match_report.json`)
and emits a compact, curated, quality-tiered `manifest.json` that the aowlspt
`mods/textures` client mod loads at runtime.

WHAT IT FIXES vs the original BepInEx pipeline
----------------------------------------------
The original had three load-bearing bugs, all in the map-resolution step:

  1. The C# plugin's `PickBestReplacementFile` searched `*.png` with tokens
     like `_COL_`/`_NRM_`, but the real ambientcg PBR maps on disk are `.jpg`
     named `..._2K-JPG_Color.jpg`, `..._2K-JPG_NormalDX.jpg`. The lookup never
     hit, so EVERY swap fell back to the single colour *preview* PNG -- normal
     and roughness slots got an albedo image.

  2. `Match-Textures.py` only indexed `.png`, so it never even considered the
     real `.jpg` maps.

  3. Threshold mismatch: the report was generated at 0.3 but the plugin
     re-filtered at 0.5.

This script resolves each BSG texture to the CORRECT ambientcg map by its BSG
suffix (`_n` -> NormalDX, `_g`/`_r` -> Roughness, `_ao` -> AmbientOcclusion,
`_d`/unknown -> Color), from the actual `.jpg` files, at the requested tier.

CURATION / VRAM
---------------
A full 3,472-entry swap of 2K textures would be gigabytes of VRAM. So the pack
is bounded: per category, keep the highest-confidence N entries, and stamp a
`tier`. The runtime mod enforces a hard VRAM budget on top of this, so the pack
is the soft bound and the mod is the hard one.

USAGE
-----
  python build_pack.py                       # default: read ../.. paths, emit manifest
  python build_pack.py --src PATH            # TarkovTextures root
  python build_pack.py --out PATH            # manifest.json output path
  python build_pack.py --min-conf 0.5        # confidence floor
  python build_pack.py --per-cat 120         # max entries per category (curation)
  python build_pack.py --tier 2K             # 2K (only tier present today) or 4K
  python build_pack.py --copy PACKDIR        # also assemble a self-contained pack
                                             #   (copies the chosen .jpg maps)

The default emits paths RELATIVE to the TarkovTextures root, and the mod's
config.json `packRoot` points at that root. `--copy` instead assembles a
self-contained directory and rewrites paths relative to it, for shipping the
pack independently of the source tree.
"""

import argparse
import json
import os
import shutil
import sys
from collections import defaultdict, Counter

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_SRC = os.path.abspath(os.path.join(HERE, "..", "..", "..", "..",
                                           "TarkovTextures"))
DEFAULT_OUT = os.path.abspath(os.path.join(HERE, "..", "data", "manifest.json"))

# BSG suffix -> which ambientcg PBR map to pull, in preference order (first
# present wins). The tokens are the actual ambientcg filename fragments.
SUFFIX_MAP = {
    "_n":  ("normal",    ["NormalDX", "NormalGL"]),
    "_g":  ("roughness", ["Roughness", "Gloss"]),
    "_r":  ("roughness", ["Roughness"]),
    "_ao": ("ao",        ["AmbientOcclusion"]),
    "_h":  ("height",    ["Displacement"]),
    "_m":  ("metalness", ["Metalness"]),
    # _d, _s, _e and the empty/unknown suffix all become base colour.
    "_d":  ("albedo",    ["Color"]),
    "_s":  ("albedo",    ["Color"]),
    "":    ("albedo",    ["Color"]),
}

# High-impact surfaces first. All six ambientcg categories are surface classes,
# so all are eligible; order controls the curation quota when --per-cat bites.
CATEGORY_ORDER = ["Metal", "Wood", "Concrete", "Brick", "Fabric", "Ground"]


def resolve_map(material_dir, suffix, tier):
    """Return (abs_path, map_kind) for the correct PBR map, or (preview, kind)."""
    kind, tokens = SUFFIX_MAP.get(suffix, SUFFIX_MAP[""])
    if not os.path.isdir(material_dir):
        return None, kind
    files = os.listdir(material_dir)
    # Try the requested tier first, then any tier (only 2K exists today; 4K is
    # a future download tier and degrades to 2K cleanly).
    for want_tier in (tier, "2K", "4K", "1K"):
        for token in tokens:
            needle = f"{want_tier}-JPG_{token}".lower()
            for f in files:
                if f.lower().endswith(".jpg") and needle in f.lower():
                    return os.path.join(material_dir, f), kind
    # Fall back to the colour preview PNG rather than nothing.
    for f in files:
        if f.lower().endswith(".png"):
            return os.path.join(material_dir, f), kind + "/preview"
    return None, kind


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=DEFAULT_SRC)
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--min-conf", type=float, default=0.5)
    ap.add_argument("--per-cat", type=int, default=120)
    ap.add_argument("--tier", default="2K")
    ap.add_argument("--copy", default="")
    args = ap.parse_args()

    report = os.path.join(args.src, "output", "match_report.json")
    if not os.path.isfile(report):
        print(f"error: no match_report.json at {report}", file=sys.stderr)
        print("run the original Match-Textures.py first, or point --src at the "
              "TarkovTextures tree.", file=sys.stderr)
        return 2

    with open(report, "r", encoding="utf-8") as fh:
        entries = json.load(fh)

    # Group matched entries by category, filter by confidence.
    by_cat = defaultdict(list)
    for e in entries:
        m = e.get("matched_ambientcg")
        if not m:
            continue
        if float(e.get("confidence", 0.0)) < args.min_conf:
            continue
        by_cat[e.get("category", "Unknown")].append(e)

    # Curate: highest confidence first, capped per category.
    chosen = []
    for cat in CATEGORY_ORDER:
        lst = sorted(by_cat.get(cat, []),
                     key=lambda e: -float(e.get("confidence", 0.0)))
        chosen.extend(lst[: args.per_cat])

    src_root = os.path.abspath(args.src)
    pack_root = os.path.abspath(args.copy) if args.copy else src_root
    if args.copy:
        os.makedirs(args.copy, exist_ok=True)

    out_entries = []
    stats = Counter()
    seen_names = set()
    copied = {}
    for e in chosen:
        bsg = e["bsg_texture"]
        name = os.path.splitext(os.path.basename(bsg))[0].lower()
        if name in seen_names:      # first (highest-conf) wins on a name clash
            continue
        material_dir = os.path.dirname(e["matched_ambientcg"])
        suffix = e.get("bsg_suffix", "") or ""
        path, kind = resolve_map(material_dir, suffix, args.tier)
        if not path or not os.path.isfile(path):
            stats["unresolved"] += 1
            continue
        seen_names.add(name)

        if args.copy:
            # Assemble a self-contained pack: <cat>/<materialfolder>/<file>.
            rel = os.path.join(e.get("category", "Unknown"),
                               os.path.basename(material_dir),
                               os.path.basename(path))
            dst = os.path.join(args.copy, rel)
            if rel not in copied:
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                shutil.copy2(path, dst)
                copied[rel] = True
            file_rel = rel.replace("\\", "/")
        else:
            file_rel = os.path.relpath(path, pack_root).replace("\\", "/")

        out_entries.append({
            "name": name,
            "file": file_rel,
            "map":  kind,
            "cat":  e.get("category", "Unknown"),
            "tier": args.tier,
            "conf": round(float(e.get("confidence", 0.0)), 3),
        })
        stats[e.get("category", "Unknown")] += 1
        stats["_total"] += 1

    out_entries.sort(key=lambda r: r["name"])
    manifest = {
        "version": 1,
        "tier": args.tier,
        "packRootHint": "" if args.copy else "TarkovTextures root",
        "count": len(out_entries),
        "entries": out_entries,
    }
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=0, separators=(",", ":"))
        fh.write("\n")

    print(f"manifest: {args.out}")
    print(f"  entries: {len(out_entries)}  (min-conf {args.min_conf}, "
          f"per-cat {args.per_cat}, tier {args.tier})")
    for cat in CATEGORY_ORDER:
        if stats[cat]:
            print(f"    {cat:9s} {stats[cat]}")
    if stats["unresolved"]:
        print(f"  unresolved (no map file on disk): {stats['unresolved']}")
    if args.copy:
        print(f"  pack assembled at {args.copy}: {len(copied)} image files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
