"""
Scope the serialized-file Texture2D census to PREFAB ENVIRONMENT SURFACES,
and match only what can honestly be matched to the ambientCG library.

Job 2 wants "concrete walls with our 4k concrete" -- brick, metal, wood too. The
bundles do not contain those (measured last round: of 26,959 bundle Texture2Ds,
14,510 are items, 6,264 pocketmap, 2,228 weapons, 1,379 characters, 612 hands, and
only 881 are location_objects of which 608 are the hideout). They are in the
serialized files, alongside the terrain, e.g. `City_Concrete_Rough_Blocks_d`,
`City_Concrete_Panels_D`, `Block_concrete_01_D`.

The discipline from `scope_post1.py` is kept in full and is the reason the counts
here are smaller than a keyword grep would suggest:

  * ONLY ALBEDO IS COLOUR. normal / gloss / specular / AO / height / mask / metalness
    are DATA and are refused with a reason, never replaced with an sRGB photo.
  * Season suffixes are stripped BEFORE map-type detection, or `_D_autumn` reads as
    "unsuffixed" and a diffuse gets misfiled as a guess.
  * `terrain` is not a family keyword; it matched only tree impostors.
  * No fuzzy matching. Fact #65: fuzzy at 0.75 on this data returned only noise.

Two constraints specific to the in-place `.resS` method:

  * the texture's pixels must be STREAMED (in a `.resS` at a fixed offset), because
    that is what can be overwritten without re-serialising the `.assets`;
  * the format must be one we can re-encode to the SAME byte count. DXT1 and DXT5
    qualify. Anything else is refused rather than converted, because changing format
    changes size and the whole method depends on the size not changing.

WOOD IS NOT AVAILABLE. The library has 16 families -- Asphalt, Bricks, Concrete,
CorrugatedSteel, Fabric, Foliage, Grass, Gravel, Ground, Metal, PaintedPlaster,
PavingStones, Road, Rock, Rubber, Tiles -- and ZERO wood/plank/timber sets. `wood`
is the single largest environment keyword in the census (474 names). It is reported
as unmatched, not substituted with concrete.

Usage:
  python assets_scope.py --inv ../out/inv-assets.json --json ../out/worklist-assets.json
"""
from __future__ import annotations
import argparse, collections, json, os, re, sys

from scope_post1 import MAP_RULES, SEASON, stem_of, map_type, crc
from terrain_build import acg_catalogue, family_of, color_path

# formats whose byte length is a pure function of (w, h, mips), so a replacement
# can be written in place. Values are TextureFormat enum members.
REENCODABLE = {10: 'DXT1', 12: 'DXT5'}

# --------------------------------------------------------------- family rules
# Superset of scope_post1's, widened for prefab surfaces. Order matters: the first
# keyword found in the name wins, so specific terms precede generic ones.
FAMILY_RULES = [
    ('corrugated', ['CorrugatedSteel']),
    ('profnastil', ['CorrugatedSteel']),
    ('asphalt', ['Asphalt', 'Road']),
    ('asfalt', ['Asphalt', 'Road']),
    ('road', ['Road', 'Asphalt']),
    ('brick', ['Bricks']),
    ('kirpich', ['Bricks']),
    ('concrete', ['Concrete']),
    ('beton', ['Concrete']),
    ('cement', ['Concrete']),
    ('plaster', ['PaintedPlaster', 'Concrete']),
    ('shtukaturka', ['PaintedPlaster', 'Concrete']),
    ('paving', ['PavingStones']),
    ('curb', ['Concrete']),
    ('tile', ['Tiles']),
    ('plitka', ['Tiles']),
    ('gravel', ['Gravel']),
    ('pebble', ['Gravel', 'PavingStones']),
    ('cliff', ['Rock']),
    ('boulder', ['Rock']),
    ('rock', ['Rock']),
    ('stone', ['Rock', 'PavingStones']),
    ('rust', ['Metal']),
    ('steel', ['Metal', 'CorrugatedSteel']),
    ('metall', ['Metal']),
    ('metal', ['Metal']),
    ('iron', ['Metal']),
    ('zhelezo', ['Metal']),
    ('fence', ['Metal']),
    ('grass', ['Grass']),
    ('trava', ['Grass']),
    ('foliage', ['Foliage']),
    ('leaf', ['Foliage']),
    ('leaves', ['Foliage']),
    ('moss', ['Foliage', 'Grass']),
    ('dirt', ['Ground']),
    ('soil', ['Ground']),
    ('mud', ['Ground']),
    ('sand', ['Ground']),
    ('earth', ['Ground']),
    ('ground', ['Ground']),
    ('rubber', ['Rubber']),
    ('fabric', ['Fabric']),
    ('cloth', ['Fabric']),
    ('tarp', ['Fabric']),
]

# Keywords that name a real environment surface we CANNOT serve. Kept separate from
# "no keyword matched" so the gap is visible instead of blending into the noise.
UNSERVED = [
    ('wood',   'no wood/plank/timber set exists in the ambientCG library'),
    ('derevo', 'no wood/plank/timber set exists in the ambientCG library'),
    ('doska',  'no wood/plank/timber set exists in the ambientCG library'),
    ('plank',  'no wood/plank/timber set exists in the ambientCG library'),
    ('glass',  'no glass set exists in the ambientCG library'),
    ('steklo', 'no glass set exists in the ambientCG library'),
    ('snow',   'no snow set exists in the ambientCG library'),
]

# Names that are not world surfaces at all. These are substrings; a hit means OUT.
DENY_SUBSTR = (
    'icon', 'ui_', '_ui', 'avatar', 'portrait', 'face', 'skin', 'hair', 'eye',
    'cloth_char', 'hand', 'weapon', 'scope', 'muzzle', 'magazine', 'ammo',
    'lut', 'noise', 'gradient', 'ramp', 'flare', 'lensdirt', 'vignette',
    'font', 'atlas_ui', 'cursor', 'crosshair', 'minimap', 'pocketmap',
    'decal_blood', 'blood', 'wound', 'bandage', 'medkit', 'syringe',
    'default', 'checker', 'placeholder', 'test_', 'dummy',
)

# Names that ARE world art but are not TILING surfaces: alpha-masked overlays and
# unique artwork. Pasting a tiling ambientCG photo over one replaces a graffiti tag
# or a wall decal with a rectangle of concrete. Counted as a refusal, not silently
# dropped, because the distinction is the whole point.
NONTILING_SUBSTR = (
    'decal', 'poster', 'sign_', '_sign', 'graffiti', 'sticker', 'label', 'logo',
    'billboard', 'banner', 'scratches', 'stain', 'splatter', 'overlay', 'trim_sheet',
)

# A tiling world surface is not 32x32 and not a 4096-wide strip of UI.
MIN_EDGE = 256

# `tile` is a substring of `textile`, which is Fabric, not Tiles. Without this the
# keyword scan silently files cloth under floor tiling.
KW_GUARD = {'tile': ('textile',)}


def deny(lname: str):
    for d in DENY_SUBSTR:
        if d in lname:
            return d
    return None


def nontiling(lname: str):
    for s in NONTILING_SUBSTR:
        if s in lname:
            return s
    return None


def match_family(lname: str):
    for kw, fams in FAMILY_RULES:
        if kw not in lname:
            continue
        if any(g in lname for g in KW_GUARD.get(kw, ())):
            continue
        return kw, fams
    return None, None


def unserved(lname: str):
    for kw, why in UNSERVED:
        if kw in lname:
            return kw, why
    return None, None


def build(inv_path: str, allow_unsuffixed: bool = False):
    inv = json.load(open(inv_path))
    cat = acg_catalogue()
    by_fam = {}
    for m in cat:
        by_fam.setdefault(family_of(m), []).append(m)
    for v in by_fam.values():
        v.sort()

    work, refused, unmatched, gap = [], [], [], []
    considered = 0
    for r0 in inv['textures']:
        r = dict(r0)
        lname = r['name'].lower()
        if not lname:
            continue
        stem = stem_of(r['name'])
        r['stem'] = stem
        r['map'] = map_type(stem.lower())

        def refuse(why):
            rr = dict(r); rr['reason'] = why; refused.append(rr)

        d = deny(lname)
        if d:
            continue                      # not a world surface; not even counted
        if max(r['w'], r['h']) < MIN_EDGE:
            continue
        considered += 1

        if not r['res']:
            refuse('pixels are inline, not in a .resS; the in-place method needs a '
                   'fixed stream offset')
            continue
        if r['fmt'] not in REENCODABLE:
            refuse(f'format {r["fmt"]} cannot be re-encoded to the same byte count')
            continue
        nt = nontiling(lname)
        if nt:
            refuse(f"'{nt}' -- an alpha-masked overlay or unique artwork, not a "
                   f'tiling surface')
            continue
        if r['map'] not in ('albedo', 'unsuffixed'):
            refuse(f"map type '{r['map']}' is data, not colour; no honest replacement")
            continue
        if r['map'] == 'unsuffixed' and not allow_unsuffixed:
            refuse('map type is only GUESSED from the name (no _D/_N/_G suffix); '
                   'pass --allow-unsuffixed to include these')
            continue

        kw, why = unserved(lname)
        if kw:
            rr = dict(r); rr['kw'] = kw; rr['reason'] = why; gap.append(rr)
            continue

        kw, fams = match_family(lname)
        if kw is None:
            unmatched.append(r)
            continue
        r['kw'] = kw
        cands = [m for f in fams for m in by_fam.get(f, [])]
        if not cands:
            refuse(f'no ambientCG material in families {fams}')
            continue
        pick = cands[crc(stem.lower()) % len(cands)]
        r['acg_material'] = pick
        r['families'] = fams
        work.append(r)

    return dict(work=work, refused=refused, unmatched=unmatched, gap=gap,
                considered=considered, total=len(inv['textures']))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--inv', default='../out/inv-assets.json')
    ap.add_argument('--json', default=None)
    ap.add_argument('--allow-unsuffixed', action='store_true',
                    help='include textures whose map type is only inferred from the '
                         'absence of a suffix. Kept OFF by default so the headline '
                         'number is the one we can defend.')
    args = ap.parse_args()
    r = build(args.inv, allow_unsuffixed=args.allow_unsuffixed)
    C = collections.Counter

    print(f'census            : {r["total"]:,} Texture2D in serialized files')
    print(f'plausible surfaces: {r["considered"]:,} '
          f'(after name denylist and a {MIN_EDGE}px minimum edge)')
    print(f'  MATCHED         : {len(r["work"]):,} in '
          f'{len({x["file"] for x in r["work"]})} files, '
          f'{len({x["stem"].lower() for x in r["work"]})} distinct stems')
    print(f'  refused         : {len(r["refused"]):,}')
    print(f'  library gap     : {len(r["gap"]):,} '
          f'(a real surface we have no set for)')
    print(f'  unmatched       : {len(r["unmatched"]):,} '
          f'(albedo, but no keyword we trust)')
    print()
    print('matched keywords  :', C(x['kw'] for x in r['work']).most_common(20))
    print('matched formats   :', C(x['fmt'] for x in r['work']).most_common())
    print('matched map types :', C(x['map'] for x in r['work']).most_common())
    print('matched sizes     :', C(f'{x["w"]}x{x["h"]}' for x in r['work']).most_common(8))
    print('matched top files :', C(x['file'] for x in r['work']).most_common(8))
    print()
    print('refusal reasons   :')
    for a, b in C(x['reason'] for x in r['refused']).most_common():
        print(f'   {b:6,d}  {a}')
    print('library gap       :')
    for a, b in C(x['kw'] for x in r['gap']).most_common():
        print(f'   {b:6,d}  {a}')
    print()
    print('sample MATCHED    :')
    for x in sorted(r['work'], key=lambda z: z['name'].lower())[:20]:
        print(f'   {x["name"]:44s} {x["w"]}x{x["h"]} kw={x["kw"]:<10s} '
              f'-> {x["acg_material"]}   [{x["file"]}]')
    print('sample unmatched  :',
          sorted({x['stem'] for x in r['unmatched']})[:20])

    if args.json:
        os.makedirs(os.path.dirname(os.path.abspath(args.json)), exist_ok=True)
        with open(args.json, 'w', newline='\n') as f:
            json.dump(r, f)
        print('wrote', args.json)


if __name__ == '__main__':
    main()
