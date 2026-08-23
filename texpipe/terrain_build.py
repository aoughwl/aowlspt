"""
Replace the MicroSplat terrain ground albedos with ambientCG surfaces.

WHAT THIS PATCHES, AND WHY IT IS THE RIGHT THING

`SplatAlpha 0/1/2` are blend-weight masks and contain no colour; the 12
`microsplat_layer_*` Texture2Ds are authoring inputs. The pixels the player actually
sees come from `Texture2DArray MicroSplatConfig_<season>_diff[_NormalTex|_LowTex]_tarray`,
bound as `_Diffuse` on the `MicroSplat_HQ/NQ/LQ_<season>` materials -- measured, see
`microsplat_probe.py`. Those 18 arrays are what this writes.

WHAT IT DOES NOT PATCH

The 18 `*_normSAO_*` arrays are normal + smoothness + AO. Only albedo is colour;
we own no honest transform for a data map, so they are left exactly alone. Leaving
the original normals under a new albedo is a compromise, not a win -- the surface
relief will not match the new colour. It is still far better than writing an sRGB
photograph into a normal map.

HOW IT WRITES -- and why this is safer than re-serialising

Every array's pixels live in `sharedassets17.assets.resS` at a fixed offset with a
fixed size, and our replacement is exactly the same number of bytes. So we copy the
`.resS`, overwrite byte ranges in the copy, and never touch `sharedassets17.assets`
at all. The `.assets` stays byte-identical, the `.resS` stays the same SIZE, and the
only thing ConsistencyInfo needs is a new Checksum for one entry.

That matters because `assets_identity.py` measured UnityPy's `.assets`
re-serialisation to be content-preserving but NOT byte-identical (it relocated 4,896
of 9,356 objects in sharedassets161). Correct, most likely -- but not something to
lean on when an equivalent patch needs none of it.

HARDLINK WARNING

`D:\\Aowlspt\\EscapeFromTarkov_Data\\*` is HARDLINKED to `D:\\Games\\Tarkov\\...`
(link count 2, measured with `fsutil hardlink list`). Writing through one path
modifies the real Tarkov install. This tool therefore writes ONLY into an output
directory of its own and refuses to write anywhere near a game install; breaking the
link at deploy time is the coordinating session's job, not this tool's.

SOURCE SELECTION

Each of the 12 slices gets a hand-written set of allowed ambientCG FAMILIES -- that
part is semantic and a human should read it. Within those families the specific set
is chosen by the closest mean RGB to the ORIGINAL slice, per season. That keeps the
ground reading approximately as it should (a sand layer stays sandy, an autumn layer
stays autumnal) instead of a name-hash pick that can drop a grey gravel into a grass
slot.

SEASONS

`winter` was EXCLUDED because the library had zero snow sets. That is no longer true:
the 2026-08-23 drop added 22 Snow sets (Snow001..Snow015 with A/B/C variants), and
`WINTER_FAMILIES` below routes the winter slices to them. It is still OFF by default
because the mapping is a judgement and no winter build has been produced or verified.
Pass `--seasons all` (or `--seasons winter`) to build it, knowingly.

Usage:
  python terrain_build.py --out ../out/terrain-pack [--source-tier auto|1K|2K|4K]
                          [--seasons all|summer,autumn,...] [--dump-preview DIR]
"""
from __future__ import annotations
import argparse, json, os, re, shutil, sys, time

import UnityPy
from PIL import Image

import tarray

DATA = 'D:/Aowlspt/EscapeFromTarkov_Data'
ASSETS = os.path.join(DATA, 'sharedassets17.assets')
RESS_NAME = 'sharedassets17.assets.resS'
ACG_ROOT = r'C:/Users/savant/Desktop/ambieentcg2/extracted'

ALL_SEASONS = ('summer', 'autumn', 'autumn_late', 'spring', 'spring_early', 'winter')
DEFAULT_SEASONS = tuple(s for s in ALL_SEASONS if s != 'winter')

# tier suffix in the array name -> the slot's edge length
TIERS = {'': 1024, '_NormalTex': 512, '_LowTex': 256}
TIER_LABEL = {'': 'HQ', '_NormalTex': 'NQ', '_LowTex': 'LQ'}

# slice index -> (surface name, allowed ambientCG families)
# Families only. The specific set is picked by mean-colour proximity to the original.
SLICE_FAMILIES = {
    0:  ('Grass',          ['Grass']),
    1:  ('Ground',         ['Ground']),
    2:  ('Gravel_Road_A',  ['Road', 'Asphalt', 'Gravel']),
    3:  ('Forest_Ground',  ['Ground', 'Foliage']),
    4:  ('Stone_Ground',   ['Rock', 'PavingStones', 'Gravel']),
    5:  ('Rock_Ground',    ['Rock', 'Gravel']),
    6:  ('Gravel_Road_B',  ['Road', 'Gravel', 'Asphalt']),
    7:  ('Gravel',         ['Gravel', 'Rock', 'PavingStones']),
    8:  ('Grassy_Ground',  ['Grass', 'Ground']),
    9:  ('Sand',           ['Ground']),
    10: ('Pebbles_Ground', ['Gravel', 'PavingStones', 'Rock']),
    11: ('Soil_Grass',     ['Ground', 'Grass']),
}

# Winter override. 2026-08-23: the library gained 22 Snow sets, so winter is no longer
# refused outright.
#
# The mean RGB of all 12 winter HQ slices WAS measured (sharedassets17.assets.resS,
# read-only) before these were written, so this is not a guess about which layers are
# actually white:
#
#   0 Grass (159,166,175)  1 Ground (183,186,193)   2 Gravel_Road_A (131,123,117)
#   3 Forest_Ground (138,129,120)  4 Stone_Ground (143,142,140)
#   5 Rock_Ground (116,115,114)    6 Gravel_Road_B (140,137,137)
#   7 Gravel (166,166,168)         8 Grassy_Ground (159,166,175)
#   9 Sand (135,117, 99)          10 Pebbles_Ground (140,138,135)
#  11 Soil_Grass (119,118,111)
#
# Layers 0,1,4,6,7,8,10 are bright and neutral -- snow-covered, and the nearest Snow
# set lands within dist 2.0..15.6. Layers 2,5,9,11 are NOT: 9 Sand is a warm brown
# (nearest Snow is dist 43.6) and 5 Rock_Ground is dark (dist 41.1). Those keep their
# summer families first so the colour picker can choose bare ground where the game
# itself shows bare ground.
#
# What is still a JUDGEMENT: nobody has looked at the IMAGES, only their mean colour,
# and a snow-dusted gravel road is not the same texture as a snowfield. Winter is
# OPT-IN (`--seasons winter`) and NO winter build has been produced or verified.
WINTER_FAMILIES = {
    0:  ['Snow'],
    1:  ['Snow'],
    2:  ['Snow', 'Road', 'Gravel'],
    3:  ['Snow', 'Ground'],
    4:  ['Snow', 'Rock', 'Rocks'],
    5:  ['Rock', 'Rocks', 'Snow'],
    6:  ['Snow', 'Road', 'Gravel'],
    7:  ['Snow', 'Gravel'],
    8:  ['Snow'],
    9:  ['Ground', 'Snow'],
    10: ['Snow', 'Gravel'],
    11: ['Ground', 'Grass', 'Snow'],
}

ARRAY_RE = re.compile(
    r'^MicroSplatConfig_(?P<season>summer|autumn_late|autumn|spring_early|spring|winter)'
    r'_(?P<kind>diff|normSAO)(?P<tier>|_NormalTex|_LowTex)_tarray$')


# ------------------------------------------------------------------ catalogue

def acg_catalogue():
    """{set_name: {'1K': dir, '2K': dir, '4K': dir}} for sets with a Color map."""
    mats = {}
    for s in os.listdir(ACG_ROOT):
        m = re.match(r'^(.+?)_(\d+K)-PNG$', s)
        if not m:
            continue
        name, res = m.group(1), m.group(2)
        d = os.path.join(ACG_ROOT, s)
        if not os.path.isfile(os.path.join(d, f'{name}_{res}-PNG_Color.png')):
            continue
        mats.setdefault(name, {})[res] = d
    return mats


def family_of(name: str) -> str:
    return re.match(r'^([A-Za-z]+?)(?=\d)', name).group(1)


def color_path(cat, name, res):
    return os.path.join(cat[name][res], f'{name}_{res}-PNG_Color.png')


def mean_rgb(img: Image.Image, n: int = 64):
    im = img.convert('RGB').resize((n, n), Image.LANCZOS)
    px = im.tobytes()
    tot = len(px) // 3
    r = sum(px[0::3]) / tot
    g = sum(px[1::3]) / tot
    b = sum(px[2::3]) / tot
    return (r, g, b)


def dist(a, b):
    return sum((x - y) ** 2 for x, y in zip(a, b)) ** 0.5


# --------------------------------------------------------------------- build

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', required=True)
    ap.add_argument('--source-tier', default='auto', choices=['auto', '1K', '2K', '4K'])
    ap.add_argument('--seasons', default=','.join(DEFAULT_SEASONS))
    ap.add_argument('--dump-preview', default='')
    ap.add_argument('--json', default='')
    ap.add_argument('--identity', action='store_true',
                    help='NEGATIVE CONTROL: feed each slice its OWN decoded original '
                         'back through the identical encode path. Measures the pure '
                         'DXT5 re-encode loss, which is the floor a real pack must '
                         'clear. The verifier must REJECT the result.')
    ap.add_argument('--touch-normsao', action='store_true',
                    help='NEGATIVE CONTROL: also overwrite the normSAO arrays, which '
                         'the pipeline must never do. The verifier must REJECT.')
    args = ap.parse_args()

    out = os.path.abspath(args.out)
    low = out.lower().replace('\\', '/')
    if '/aowlspt/escapefromtarkov_data' in low or low.startswith('d:/games') \
            or '/d:/aowlspt' in low or low.startswith('d:/aowlspt'):
        sys.exit('REFUSING: --out is inside a game install. This tool writes packs, '
                 'not deployments; the .resS there is hardlinked to D:\\Games\\Tarkov.')
    os.makedirs(out, exist_ok=True)

    seasons = (list(ALL_SEASONS) if args.seasons.strip().lower() == 'all'
               else [s.strip() for s in args.seasons.split(',') if s.strip()])
    bad = [s for s in seasons if s not in ALL_SEASONS]
    if bad:
        sys.exit(f'unknown season(s): {bad}')
    print(f'seasons: {seasons}')
    if 'winter' in seasons:
        print('  NOTE: winter included. 22 Snow sets now exist, and WINTER_FAMILIES '
              'routes the ground-plane slices to them -- but that mapping is a '
              'JUDGEMENT and no winter build has been verified yet.')

    cat = acg_catalogue()
    by_fam = {}
    for name in cat:
        by_fam.setdefault(family_of(name), []).append(name)
    for v in by_fam.values():
        v.sort()
    print(f'ambientCG: {len(cat)} sets with a Color map; families '
          + ', '.join(f'{k}={len(v)}' for k, v in sorted(by_fam.items())))

    # ------------------------------------------------ enumerate target arrays
    env = UnityPy.load(ASSETS)
    arrays = []
    for o in env.objects:
        if o.type.name != 'Texture2DArray':
            continue
        t = o.read_typetree()
        m = ARRAY_RE.match(str(t.get('m_Name', '')))
        if not m:
            continue
        arrays.append((m.groupdict(), t))
    print(f'MicroSplat arrays found: {len(arrays)}')

    want_kinds = ('diff', 'normSAO') if args.touch_normsao else ('diff',)
    targets = [(g, t) for g, t in arrays
               if g['kind'] in want_kinds and g['season'] in seasons]
    skipped_norm = [t['m_Name'] for g, t in arrays if g['kind'] == 'normSAO']
    skipped_season = [t['m_Name'] for g, t in arrays
                      if g['kind'] == 'diff' and g['season'] not in seasons]
    print(f'  TARGET (albedo)      : {len(targets)}')
    print(f'  refused (normSAO)    : {len(skipped_norm)}  '
          f'-- data maps, not colour; left untouched')
    print(f'  skipped (season off) : {len(skipped_season)}')

    if not targets:
        sys.exit('nothing to do')

    # -------------------------------------------------------- copy the .resS
    src_ress = os.path.join(DATA, RESS_NAME)
    dst_ress = os.path.join(out, RESS_NAME)
    if not os.path.exists(dst_ress) or os.path.getsize(dst_ress) != os.path.getsize(src_ress):
        print(f'copying {RESS_NAME} ({os.path.getsize(src_ress)/1e6:.0f} MB) -> {out}')
        shutil.copy2(src_ress, dst_ress)
    orig_size = os.path.getsize(src_ress)

    src_cache = {}
    report = []
    t0 = time.time()

    fh = open(dst_ress, 'r+b')
    orig_fh = open(src_ress, 'rb')
    try:
        for g, t in sorted(targets, key=lambda x: x[1]['m_Name']):
            name = t['m_Name']
            w, h = int(t['m_Width']), int(t['m_Height'])
            depth, mips = int(t['m_Depth']), int(t['m_MipCount'])
            sd = t['m_StreamData']
            if sd.get('path') != RESS_NAME:
                print(f'  SKIP {name}: stream path {sd.get("path")!r} is not {RESS_NAME}')
                continue
            per = tarray.assert_layout(w, h, mips, depth, int(t['m_DataSize']))
            if depth != len(SLICE_FAMILIES):
                sys.exit(f'{name}: depth {depth} but {len(SLICE_FAMILIES)} slice rules')
            base = int(sd['offset'])
            tier = TIER_LABEL[g['tier']]
            print(f'\n{name}  [{tier}] {w}x{h} depth={depth} mips={mips} '
                  f'slice={per:,}B @{base:,}')

            mip0 = tarray.level_size_dxt5(w, h)
            for i in range(depth):
                surface, fams = SLICE_FAMILIES[i]
                if g['season'] == 'winter':
                    fams = WINTER_FAMILIES[i]
                orig_fh.seek(base + i * per)
                orig_img = tarray.decode_dxt5(orig_fh.read(mip0), w, h)
                target_mean = mean_rgb(orig_img)

                # pick the source tier: never upscale
                if args.source_tier == 'auto':
                    res = next((r for r in ('1K', '2K', '4K')
                                if int(r[:-1]) * 1024 >= w), '4K')
                else:
                    res = args.source_tier
                    if int(res[:-1]) * 1024 < w:
                        sys.exit(f'{name} slice {i}: source tier {res} is smaller than '
                                 f'the {w}px slot; upscaling is refused')

                cands = [c for f in fams for c in by_fam.get(f, []) if res in cat[c]]
                if not cands:
                    sys.exit(f'{name} slice {i} ({surface}): no ambientCG set in '
                             f'families {fams} at {res}')
                best, bestd = None, None
                for c in cands:
                    key = (c, res)
                    if key not in src_cache:
                        src_cache[key] = mean_rgb(Image.open(color_path(cat, c, res)))
                    d = dist(src_cache[key], target_mean)
                    if bestd is None or d < bestd:
                        best, bestd = c, d

                if args.identity:
                    best, res = '<identity control: the original slice>', '-'
                    img = orig_img
                else:
                    img = Image.open(color_path(cat, best, res))
                data = tarray.build_chain(img, w, h, mips)
                if len(data) != per:
                    sys.exit(f'{name} slice {i}: built {len(data)} bytes, want {per}')
                fh.seek(base + i * per)
                fh.write(data)

                report.append(dict(array=name, tier=tier, season=g['season'],
                                   slice=i, surface=surface, families=fams,
                                   acg=best, acg_res=res,
                                   orig_mean=[round(x, 1) for x in target_mean],
                                   src_mean=[round(x, 1) for x in
                                             src_cache.get((best, res), target_mean)],
                                   mean_dist=round(bestd, 1),
                                   offset=base + i * per, nbytes=per))
                print(f'   s{i:<2d} {surface:16s} <- {best:<16s} {res}  '
                      f'origRGB=({target_mean[0]:.0f},{target_mean[1]:.0f},'
                      f'{target_mean[2]:.0f}) d={bestd:.0f}')
                if args.dump_preview:
                    os.makedirs(args.dump_preview, exist_ok=True)
                    orig_img.save(os.path.join(args.dump_preview,
                                               f'{name}_s{i:02d}_ORIG.png'))
                    tarray.decode_dxt5(data[:mip0], w, h).save(
                        os.path.join(args.dump_preview, f'{name}_s{i:02d}_NEW.png'))
    finally:
        fh.close()
        orig_fh.close()

    new_size = os.path.getsize(dst_ress)
    print()
    print(f'built {len(report)} slices across {len({r["array"] for r in report})} '
          f'arrays in {time.time()-t0:.0f}s')
    print(f'.resS size {orig_size:,} -> {new_size:,}  '
          f'{"UNCHANGED (good)" if orig_size == new_size else "CHANGED (BAD)"}')
    if orig_size != new_size:
        sys.exit('the .resS changed size; that must never happen with this method')

    manifest = dict(
        method='resS-inplace',
        assets_untouched='sharedassets17.assets',
        ress=RESS_NAME, ress_size=new_size,
        seasons=seasons, source_tier=args.source_tier,
        refused_normSAO=sorted(skipped_norm),
        skipped_season=sorted(skipped_season),
        slices=report,
    )
    mp = os.path.join(out, 'terrain-manifest.json')
    with open(mp, 'w', newline='\n') as f:
        json.dump(manifest, f, indent=1)
    print('wrote', mp)
    if args.json:
        with open(args.json, 'w', newline='\n') as f:
            json.dump(manifest, f, indent=1)
    print()
    print('DEPLOY IS NOT DONE HERE. To install, the coordinating session must:')
    print(f'  1. back up D:\\Aowlspt\\EscapeFromTarkov_Data\\{RESS_NAME}')
    print(f'  2. BREAK THE HARDLINK: delete that path first, then copy the pack file '
          f'in (a plain copy over it would write through to D:\\Games\\Tarkov)')
    print(f'  3. python consistency.py sync --file "EscapeFromTarkov_Data\\{RESS_NAME}"')
    return 0


if __name__ == '__main__':
    sys.exit(main())
