"""
Scope the post-1.0 inventory to in-raid terrain / foliage / environment surfaces,
and match only what can honestly be matched to the ambientCG library.

Rules, in order of authority:

  * Nothing is salvaged from packs/ambientcg-overhaul. Fact #65: only 52 of its 512
    names (10.2%) existed in EFT 0.16.9, and fuzzy matching at 0.75 on the 460 misses
    returned empty. Everything here is derived from out/inv-post1-full.json.
  * Items, weapons, characters and the hideout are OUT. The brief is in-raid world
    surfaces, "not item textures/weapons"; fact #65's 52 real hits were overwhelmingly
    hideout customisation, which is exactly what is not wanted.
  * ONLY ALBEDO IS COLOUR (fact #36). normal / roughness / AO / height / metalness /
    mask are DATA. We do not own an honest transform for any of them, so they are
    REFUSED with a reason rather than replaced with an sRGB photo.
  * The original ALPHA channel is always carried through. Every grass / foliage texture
    in scope is an alpha-cut billboard card; an ambientCG tiling Color map is opaque, so
    pasting it whole would turn every grass quad into a solid rectangle. RGB is replaced,
    alpha is the original's.

Two false positives this module exists to block, both found by inspecting output:

  * `vetky5_big_terrain_AlbedoAlpha` matched the keyword "terrain". It is a GPU-instancer
    billboard impostor of a whole tree ("vetky" = branches), not terrain. All impostors
    are refused.
  * `Field_grass_D_autumn` classified as map type "unsuffixed" because the seasonal
    suffix hides the `_D`. Season suffixes are stripped before map-type detection.

Usage:
  python scope_post1.py --inv ../out/inv-post1-full.json --json ../out/worklist-post1.json
"""
from __future__ import annotations
import argparse, collections, json, os, re, zlib

ACG_ROOT = r'C:/Users/savant/Desktop/ambieentcg2/extracted'

# ---------------------------------------------------------------- bundle scope

IN_SCOPE_PREFIX = (
    'assets/content/location_objects/',
    'assets/content/rock and boulders',
    'assets/gpuinstancer/prototypedata/',
    'assets/content/textures/',
    'assets/content/materials',
    'assets/content/prefabs/',
    'assets/content/commonprefabs/',
)

OUT_PREFIX = (
    'assets/content/weapons/', 'assets/content/items/', 'assets/content/characters/',
    'assets/content/hands/', 'assets/content/audio/', 'assets/content/pocketmap/',
    'assets/systems/', 'assets/paroxe/', 'assets/commonassets/', 'assets/scripts/',
)

OUT_SUBSTR = ('/00_hideout/', '/lootable/', '/holemanager/')


def bundle_in_scope(key: str) -> bool:
    k = key.lower()
    if any(k.startswith(p) for p in OUT_PREFIX):
        return False
    if any(s in k for s in OUT_SUBSTR):
        return False
    return any(k.startswith(p) for p in IN_SCOPE_PREFIX)


def is_impostor(key: str, lname: str) -> bool:
    """GPU-instancer billboard atlases of whole trees/bushes. A tiling ambientCG
    surface is not a counterpart for one of these, at any confidence."""
    return '/impostors/' in key.lower() or 'albedoalpha' in lname or 'normaldepth' in lname


# ------------------------------------------------------------------ map types

SEASON = re.compile(r'(_autumn_late|_autumn|_spring_early|_spring|_winter|_summer)$', re.I)


def stem_of(name: str) -> str:
    s = name
    while True:
        s2 = SEASON.sub('', s)
        if s2 == s:
            return s
        s = s2


MAP_RULES = [
    (r'(_n|_nrm|_norm|_normal|_normals|_normaldepth|_bump)$', 'normal'),
    (r'(_ao|_occlusion|_occ)$', 'ao'),
    (r'(_h|_height|_disp|_displacement|_parallax)$', 'height'),
    (r'(_rough|_roughness)$', 'roughness'),
    (r'(_g|_s|_spec|_specular|_gloss|_glossiness|_smoothness)$', 'specular'),
    (r'(_m|_metal|_metallic|_metalness)$', 'metalness'),
    (r'(_mask|_masks|_msk|_mts|_blend|_splat|_control|splatalpha)$', 'mask'),
    (r'(_e|_em|_emis|_emission|_emissive|_illum)$', 'emission'),
    (r'(_albedoalpha)$', 'albedo'),
    (r'(_d|_diff|_diffuse|_albedo|_col|_color|_basecolor|_c|_a)$', 'albedo'),
]


def map_type(stem_l: str) -> str:
    for pat, kind in MAP_RULES:
        if re.search(pat, stem_l):
            return kind
    # No recognised suffix. In these bundles a bare name is conventionally the diffuse,
    # but that is an INFERENCE and it is kept in its own bucket so the count is visible.
    return 'unsuffixed'


# ------------------------------------------------ EFT name -> ambientCG family
# Substring keywords only. There is deliberately no fuzzy/similarity matching: fact #65
# records that fuzzy matching at 0.75 on this data returned nothing but noise.
FAMILY_RULES = [
    ('asphalt', ['Asphalt', 'Road']),
    ('asfalt', ['Asphalt', 'Road']),
    ('road', ['Road', 'Asphalt']),
    ('gravel', ['Gravel', 'Ground']),
    ('krapiva', ['Foliage']),      # nettle
    ('romashka', ['Foliage']),     # daisy
    ('oduvanchik', ['Foliage']),   # dandelion
    ('trava', ['Grass']),
    ('grass', ['Grass']),
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
    ('rock', ['Rock']),
    ('stone', ['Rock', 'PavingStones']),
    ('cliff', ['Rock']),
    ('boulder', ['Rock']),
    ('concrete', ['Concrete']),
    ('beton', ['Concrete']),
    ('cement', ['Concrete']),
    ('plaster', ['PaintedPlaster', 'Concrete']),
    ('brick', ['Bricks']),
    ('kirpich', ['Bricks']),
    ('tile', ['Tiles']),
    ('paving', ['PavingStones']),
    ('curb', ['Concrete']),
    ('corrugated', ['CorrugatedSteel']),
    ('profnastil', ['CorrugatedSteel']),
    ('metall', ['Metal']),
    ('metal', ['Metal']),
    ('steel', ['Metal', 'CorrugatedSteel']),
    ('iron', ['Metal']),
    ('rust', ['Metal']),
    ('fence', ['Metal']),
    ('fabric', ['Fabric']),
    ('cloth', ['Fabric']),
    ('tarp', ['Fabric']),
    ('rubber', ['Rubber']),
]

# 'terrain' is deliberately ABSENT from FAMILY_RULES. The only bundle textures whose
# names contain it are tree impostors (vetky*_big_terrain_*), and matching on it
# produced 24 confidently-wrong rows.


def acg_catalogue():
    mats = collections.defaultdict(dict)
    for s in os.listdir(ACG_ROOT):
        m = re.match(r'^(.+?)_(\d+K)-PNG$', s)
        if m:
            mats[m.group(1)][m.group(2)] = os.path.join(ACG_ROOT, s)
    return dict(mats)


def family_of(mat: str) -> str:
    return re.match(r'^([A-Za-z ]+)', mat).group(1)


def match_family(lname: str):
    for kw, fams in FAMILY_RULES:
        if kw in lname:
            return kw, fams
    return None, None


def res_for(w: int, h: int) -> str:
    n = max(int(w), int(h))
    return '4K' if n >= 4096 else ('2K' if n >= 2048 else '1K')


def crc(s: str) -> int:
    return zlib.crc32(s.encode()) & 0x7fffffff


def build(inv_path: str, allow_unsuffixed: bool = True):
    inv = json.load(open(inv_path))
    cat = acg_catalogue()
    by_family = collections.defaultdict(list)
    for mat in cat:
        by_family[family_of(mat)].append(mat)
    for v in by_family.values():
        v.sort()

    scoped, work, refused, unmatched = [], [], [], []
    for r0 in inv['textures']:
        if not bundle_in_scope(r0['key']):
            continue
        r = dict(r0)
        stem = stem_of(r['name'])
        r['stem'] = stem
        r['season'] = r['name'][len(stem):] or ''
        r['map'] = map_type(stem.lower())
        scoped.append(r)

        def refuse(why):
            rr = dict(r); rr['reason'] = why; refused.append(rr)

        if is_impostor(r['key'], r['lname']):
            refuse('GPU-instancer tree/bush impostor billboard; no tiling counterpart')
            continue
        if r['map'] == 'unsuffixed' and not allow_unsuffixed:
            refuse('map type not determinable from the name')
            continue
        if r['map'] not in ('albedo', 'unsuffixed'):
            # fact #36: these are DATA, not colour.
            refuse(f"map type '{r['map']}' is data, not colour; no honest replacement")
            continue

        kw, fams = match_family(stem.lower())
        if kw is None:
            unmatched.append(r)
            continue
        r['kw'] = kw
        cands = [m for f in fams for m in by_family.get(f, [])]
        if not cands:
            refuse(f'no ambientCG material in families {fams}')
            continue
        # Deterministic pick, stable across rebuilds. Seasonal variants of one stem all
        # get the SAME ambientCG material (keyed on the stem, not the full name) so a
        # surface does not change material as the season changes.
        pick = cands[crc(stem.lower()) % len(cands)]
        res = res_for(r['w'], r['h'])
        src = os.path.join(cat[pick][res], f'{pick}_{res}-PNG_Color.png')
        if not os.path.exists(src):
            refuse(f'ambientCG set {pick} {res} has no Color map')
            continue
        r['acg_material'] = pick
        r['acg_res'] = res
        r['src'] = src.replace('\\', '/')
        r['srgb'] = True            # albedo only, so always colour
        r['keep_alpha'] = True      # alpha is a cutout mask; never take the source's
        work.append(r)
    return dict(scoped=scoped, work=work, refused=refused, unmatched=unmatched)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--inv', default='../out/inv-post1-full.json')
    ap.add_argument('--json', default=None)
    args = ap.parse_args()
    r = build(args.inv)
    inv = json.load(open(args.inv))
    C = collections.Counter
    print(f"inventory:   {len(inv['textures'])} Texture2D / "
          f"{len({t['lname'] for t in inv['textures']})} distinct names / "
          f"{inv['scanned_bundles']} bundles")
    print(f"in-scope:    {len(r['scoped'])} textures in {len({x['key'] for x in r['scoped']})} bundles")
    print(f"  MATCHED:   {len(r['work'])} in {len({x['key'] for x in r['work']})} bundles")
    print(f"  refused:   {len(r['refused'])}")
    print(f"  unmatched: {len(r['unmatched'])} (in scope, albedo, but no keyword we trust)")
    print()
    print('scoped map types :', C(x['map'] for x in r['scoped']).most_common())
    print('matched keywords :', C(x['kw'] for x in r['work']).most_common())
    print('matched formats  :', C(x['fmt'] for x in r['work']).most_common())
    print('matched stems    :', len({x['stem'] for x in r['work']}))
    print('matched bundles  :', C('/'.join(x['key'].split('/')[:4]) for x in r['work']).most_common(8))
    print('refusal reasons  :')
    for a, b in C(x['reason'] for x in r['refused']).most_common():
        print(f'   {b:5d}  {a}')
    print('unmatched stems  :', sorted({x['stem'] for x in r['unmatched']})[:30])
    if args.json:
        os.makedirs(os.path.dirname(os.path.abspath(args.json)), exist_ok=True)
        with open(args.json, 'w', newline='\n') as f:
            json.dump(r, f)
        print('wrote', args.json)


if __name__ == '__main__':
    main()
