#!/usr/bin/env python3
"""assemble_pack.py -- materialise the ambientCG Overhaul resource pack.

This resource pack ships its `manifest.json` in git, but NOT the ~2.2 GB of
CC0 ambientCG images it references. This script copies exactly the images the
committed manifest lists, out of your local `TarkovTextures` source tree, into
the pack's `assets/` directory -- producing the self-contained, distributable
pack.

It is a PURE COPY of the files named in `manifest.json` (no re-matching), so the
assembled `assets/` tree always matches the committed manifest exactly. It is
idempotent and resumable: files already present with the right size are skipped.

USAGE
-----
  python assemble_pack.py                      # src defaults to ../../../TarkovTextures
  python assemble_pack.py --src PATH           # your ambientCG source root
  python assemble_pack.py --regen-manifest     # also rebuild manifest.json from
                                               #   mods/textures/data/manifest.json

The source root must contain the ambientCG maps under `ambientcg/<Cat>/...`,
i.e. the same `TarkovTextures` tree the mods/textures pipeline uses.
"""
import argparse, json, os, shutil, sys

HERE = os.path.dirname(os.path.abspath(__file__))
# packs/ambientcg-overhaul -> repo root is two up; TarkovTextures is a sibling of the repo.
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
DEFAULT_SRC = os.path.abspath(os.path.join(REPO_ROOT, "..", "TarkovTextures"))
SRC_MANIFEST = os.path.join(REPO_ROOT, "mods", "textures", "data", "manifest.json")
PACK_MANIFEST = os.path.join(HERE, "manifest.json")


def src_rel_for(override_file):
    """assets/<cat>/<material>/<file>  ->  ambientcg/<cat>/<material>/<file>"""
    p = override_file.replace("\\", "/")
    if p.startswith("assets/"):
        p = p[len("assets/"):]
    return "ambientcg/" + p


def regen_manifest():
    """Rebuild manifest.json from the mods/textures curated manifest."""
    with open(SRC_MANIFEST, "r", encoding="utf-8") as fh:
        src = json.load(fh)
    textures = []
    for e in src["entries"]:
        f = e["file"].replace("\\", "/")
        if f.startswith("ambientcg/"):
            f = f[len("ambientcg/"):]
        textures.append({
            "name": e["name"],
            "file": "assets/" + f,   # pack-relative; loader resolves it
            "map":  e["map"],
            "cat":  e["cat"],
            "tier": e["tier"],
            "conf": e["conf"],
        })
    manifest = {
        "_schemaStatus": "reconciled to aowlspt.resourcepack v1",
        "schema": "aowlspt.resourcepack",
        "schemaVersion": 1,
        "name": "ambientCG Overhaul",
        "version": "1.0.0",
        "author": "savannt",
        "description": ("Revamped, non-Tarkov-style PBR surface textures sourced "
                        "from ambientCG (CC0). Replaces metal, wood, concrete, "
                        "brick, fabric and ground surfaces with clean, high-detail "
                        "physically-based materials."),
        "capabilities": ["textures"],
        "textures": textures,
    }
    with open(PACK_MANIFEST, "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=0, separators=(",", ":"))
        fh.write("\n")
    print(f"regenerated {PACK_MANIFEST}: {len(textures)} textures")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default="", help="ambientCG source root (has ambientcg/)")
    ap.add_argument("--regen-manifest", action="store_true")
    args = ap.parse_args()

    if args.regen_manifest:
        regen_manifest()

    # Resolve source root: explicit --src, else the sibling default, else fall
    # back to the mods/textures config.json packRoot (which already points at the
    # ambientCG tree on a configured install).
    if not args.src:
        args.src = DEFAULT_SRC
        if not os.path.isdir(os.path.join(args.src, "ambientcg")):
            cfg = os.path.join(REPO_ROOT, "mods", "textures", "config.json")
            try:
                with open(cfg, "r", encoding="utf-8") as fh:
                    pr = json.load(fh).get("packRoot", "")
                if pr and os.path.isdir(os.path.join(pr, "ambientcg")):
                    args.src = pr
            except (OSError, ValueError):
                pass

    if not os.path.isfile(PACK_MANIFEST):
        print(f"error: no manifest.json at {PACK_MANIFEST}", file=sys.stderr)
        return 2
    with open(PACK_MANIFEST, "r", encoding="utf-8") as fh:
        manifest = json.load(fh)

    src_root = os.path.abspath(args.src)
    if not os.path.isdir(os.path.join(src_root, "ambientcg")):
        print(f"error: {src_root} has no ambientcg/ subdir.", file=sys.stderr)
        print("Point --src at your TarkovTextures root (the ambientCG download tree).",
              file=sys.stderr)
        return 2

    copied = skipped = missing = 0
    for ov in manifest["textures"]:
        dst = os.path.join(HERE, ov["file"].replace("/", os.sep))
        src = os.path.join(src_root, src_rel_for(ov["file"]).replace("/", os.sep))
        if not os.path.isfile(src):
            print(f"  MISSING source: {src}", file=sys.stderr)
            missing += 1
            continue
        if os.path.isfile(dst) and os.path.getsize(dst) == os.path.getsize(src):
            skipped += 1
            continue
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(src, dst)
        copied += 1

    print(f"assemble: copied {copied}, skipped {skipped}, missing {missing}, "
          f"total {len(manifest['textures'])}")
    if missing:
        print("WARNING: some source images were missing; pack is incomplete.",
              file=sys.stderr)
        return 1
    print(f"pack assembled at {os.path.join(HERE, 'assets')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
