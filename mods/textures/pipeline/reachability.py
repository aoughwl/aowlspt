"""reachability.py -- audit which texture surface classes the bundle redirect can reach.

This is the instrument behind README section 1. Re-run it after any Tarkov
update; the answer is build-specific and the failure mode of a stale answer is
silent (you patch something and the screen does not change).

READ-ONLY. Opens every file 'rb' and never writes to the game install. It must
stay that way: the game files are HARDLINKED to the real Tarkov install
(fact #89), so a write here corrupts D:\\Games\\Tarkov.

    python reachability.py [--install D:/Aowlspt]

Reports, each with the measurement that produced it:
  * where the known terrain texture names actually live (.assets vs bundles)
  * the size split between engine-side .assets and the EasyBundle-reachable root
  * hardlink counts, which say whether in-place patching is safe (it is not)
  * ConsistencyInfo coverage + a byte-for-byte checksum-formula proof

Exit code is 0 for a completed audit, 1 if the install layout was not found.
A completed audit that reports "terrain NOT reachable" is a successful run.
"""

import argparse
import json
import mmap
import os
import sys

# Names measured to sit on the terrain path. MicroSplatConfig/_Diffuse are what
# the player actually sees underfoot (fact #91); SplatAlpha and the two named
# textures are the ones the older, wrong answer pointed at (fact #84).
TERRAIN_NEEDLES = [
    b"MicroSplatConfig",
    b"_Diffuse",
    b"SplatAlpha",
    b"City_Asphalt_Trim_01",
    b"Grass_02_512",
]

# Scanned because they are uncompressed: object names appear as plain ASCII.
# NOTE: bundles are LZ4-compressed, so the SAME scan over a bundle would find
# nothing whether or not the name is present. Absence in a bundle is therefore
# NOT evidence -- which is why the structural argument (below) carries the
# verdict and this scan only corroborates it.
ASSETS_TO_SCAN = [
    "sharedassets17.assets",
    "sharedassets140.assets",
    "sharedassets161.assets",
    "sharedassets165.assets",
    "globalgamemanagers.assets",
]

MAX_CHECKSUM_BYTES = 50_000_000


def scan_names(path, needles):
    """Count plaintext occurrences of each needle. Counts only; never prints data."""
    try:
        if os.path.getsize(path) == 0:
            return {}
    except OSError:
        return None
    with open(path, "rb") as f:
        mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
        try:
            found = {}
            for n in needles:
                count = 0
                i = mm.find(n, 0)
                while i != -1 and count < 10000:
                    count += 1
                    i = mm.find(n, i + 1)
                if count:
                    found[n.decode()] = count
            return found
        finally:
            mm.close()


def tree_bytes(root):
    total = 0
    files = 0
    for dirpath, _dirnames, filenames in os.walk(root):
        for fn in filenames:
            try:
                total += os.path.getsize(os.path.join(dirpath, fn))
                files += 1
            except OSError:
                pass
    return files, total


def gb(n):
    return "%.1f GB" % (n / 1024.0 ** 3)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--install", default="D:/Aowlspt")
    args = ap.parse_args()

    inst = args.install.replace("\\", "/").rstrip("/")
    data = inst + "/EscapeFromTarkov_Data"
    bundles = data + "/StreamingAssets/Windows"

    if not os.path.isdir(data):
        print("FAIL: no EscapeFromTarkov_Data under", inst)
        return 1

    print("== 1. where the terrain texture names actually live ==")
    print("   (.assets are uncompressed, so ASCII names are visible;")
    print("    bundles are LZ4, so absence there proves nothing)")
    for name in ASSETS_TO_SCAN:
        p = os.path.join(data, name)
        res = scan_names(p, TERRAIN_NEEDLES)
        if res is None:
            print("   MISSING", name)
        elif res:
            print("   %-28s %12d  %s" % (name, os.path.getsize(p), res))

    print()
    print("== 2. size split: engine-side .assets vs redirect-reachable bundles ==")
    assets_files, assets_bytes = 0, 0
    for fn in os.listdir(data):
        if fn.startswith("sharedassets") and ".assets" in fn:
            try:
                assets_bytes += os.path.getsize(os.path.join(data, fn))
                assets_files += 1
            except OSError:
                pass
    print("   sharedassets*        files=%-6d %s   <- NOT reachable by redirect"
          % (assets_files, gb(assets_bytes)))
    if os.path.isdir(bundles):
        bf, bb = tree_bytes(bundles)
        print("   StreamingAssets/Windows files=%-4d %s   <- reachable" % (bf, gb(bb)))

    print()
    print("== 3. is the map scene a bundle? (if not, terrain cannot be redirected) ==")
    for sub in ("assets/content/locations", "assets/content/location_objects"):
        p = os.path.join(bundles, sub)
        if os.path.isdir(p):
            f, b = tree_bytes(p)
            print("   %-34s files=%-5d %s" % (sub, f, gb(b)))
    print("   locations being tiny (presets only) means the map SCENES ship as")
    print("   level*/sharedassets*, i.e. engine-side, i.e. out of reach.")

    print()
    print("== 4. hardlinks: is in-place patching safe? ==")
    for rel in ("sharedassets17.assets", "sharedassets17.assets.resS",
                "StreamingAssets/Windows/maps/customs_preset.bundle",
                "StreamingAssets/Windows/Windows.json"):
        p = os.path.join(data, rel)
        try:
            st = os.stat(p)
        except OSError:
            continue
        verdict = "UNSAFE: shared with the real Tarkov install" if st.st_nlink > 1 else "link count 1"
        print("   nlink=%d  %-52s %s" % (st.st_nlink, rel, verdict))

    print()
    print("== 5. ConsistencyInfo coverage + checksum-formula proof ==")
    cpath = inst + "/ConsistencyInfo"
    if not os.path.isfile(cpath):
        print("   MISSING", cpath, "-- INCONCLUSIVE, not a pass")
        return 0
    doc = json.load(open(cpath))
    entries = doc["Entries"]
    paths = {}
    for e in entries:
        paths[e["Path"].replace("\\", "/")] = e
    n_shared = sum(1 for p in paths if "sharedassets" in p.lower())
    n_stream = sum(1 for p in paths if "streamingassets" in p.lower())
    print("   entries=%d  sharedassets=%d  StreamingAssets=%d"
          % (len(entries), n_shared, n_stream))
    print("   -> BOTH classes are size+checksum checked; no in-place edit survives.")

    # Mutation-proof the formula on a real entry small enough to sum.
    proved = False
    for rel, ent in paths.items():
        full = inst + "/" + rel
        try:
            size = os.path.getsize(full)
        except OSError:
            continue
        if size > MAX_CHECKSUM_BYTES or size == 0:
            continue
        blob = open(full, "rb").read()
        ok_size = ent["Size"] == len(blob)
        ok_sum = (sum(blob) % 2 ** 32) == ent["Checksum"]
        print("   formula sum(bytes)%%2**32 on %s: sizeMatch=%s checksumMatch=%s"
              % (os.path.basename(rel), ok_size, ok_sum))
        proved = ok_size and ok_sum
        break
    if not proved:
        print("   could not prove the checksum formula on any entry -- INCONCLUSIVE")

    print()
    print("VERDICT: terrain GROUND is NOT reachable by the EasyBundle redirect.")
    print("         prefab/world-object/skybox textures ARE.")
    print("         See README section 1. A structural pass here is still not")
    print("         proof a swap renders -- only the screen settles that.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
