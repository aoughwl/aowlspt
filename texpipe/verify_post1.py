"""
Verify the post-1.0 pack against the originals.

For every built bundle it checks, and reports separately:

  1. the set of (PathID, type) is IDENTICAL to the original      -> nothing added or lost
  2. every object we did NOT touch is byte-identical             -> nothing mutated
  3. each replaced Texture2D keeps name / width / height / TextureFormat / mip count
  4. its image_data length equals what that format + mip chain demands, and the pixels
     are INLINE (m_StreamData cleared) rather than pointing at the game's .resS
  5. the RGB actually CHANGED against the original                -> the check is not
     vacuous; a no-op build would fail here
  6. the ALPHA is preserved within tolerance                      -> the cutout mask
     survived (exact equality is not expected: DXT5 alpha is block-interpolated, so
     re-encoding the same alpha is lossy)

A pass on 1-4 alone would be a green light from a comparison that compared nothing;
5 and 6 are what make it mean something.

Usage: python verify_post1.py --out ../out/post1-pack
"""
from __future__ import annotations
import argparse, collections, json, math, os, sys

import UnityPy
from inventory import game_path, WJ, fmt_name

BLOCK_BYTES = {10: 8, 28: 8, 26: 8, 12: 16, 25: 16, 27: 16, 24: 16}   # DXT1/BC4 8, DXT5/BC7/BC5/BC6H 16
PIXEL_BYTES = {4: 4, 5: 4, 14: 4, 3: 3, 1: 1, 63: 1, 62: 2}


def expected_bytes(fmt: int, w: int, h: int, mips: int) -> int | None:
    total = 0
    for _ in range(mips):
        if fmt in BLOCK_BYTES:
            total += max(1, math.ceil(w / 4)) * max(1, math.ceil(h / 4)) * BLOCK_BYTES[fmt]
        elif fmt in PIXEL_BYTES:
            total += w * h * PIXEL_BYTES[fmt]
        else:
            return None
        if w == 1 and h == 1:
            break
        w = max(1, w // 2)
        h = max(1, h // 2)
    return total


def census(env):
    return {(o.assets_file.name, o.path_id): (o.type.name, o.get_raw_data())
            for o in env.objects}


def band_stats(a, b, idx):
    pa, pb = a.convert('RGBA').split()[idx], b.convert('RGBA').split()[idx]
    n = pa.size[0] * pa.size[1]
    ha, hb = pa.histogram(), pb.histogram()
    # mean absolute difference computed per-pixel
    import itertools
    da = pa.tobytes(); db = pb.tobytes()
    s = sum(abs(x - y) for x, y in zip(da, db))
    return s / max(1, len(da))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', required=True)
    ap.add_argument('--worklist', default='../out/worklist-post1.json')
    ap.add_argument('--alpha-tol', type=float, default=2.0)
    ap.add_argument('--rgb-min', type=float, default=12.0)
    args = ap.parse_args()

    wj = json.load(open(WJ))
    work = json.load(open(args.worklist))['work']
    by_key = collections.defaultdict(dict)
    for t in work:
        by_key[t['key']][t['lname']] = t

    man = json.load(open(os.path.join(args.out, 'bundles.json')))['manifest']
    problems, checked_obj, checked_tex = [], 0, 0
    alpha_mads, rgb_mads = [], []

    for e in man:
        key = e['key']
        dst = os.path.join(args.out, 'bundles', key.replace('/', os.sep))
        src = game_path(wj[key]['FileName'])
        senv, denv = UnityPy.load(src), UnityPy.load(dst)
        a, b = census(senv), census(denv)
        if set(a) != set(b):
            problems.append(dict(key=key, issue='object set differs',
                                 missing=[str(x) for x in list(set(a) - set(b))[:5]],
                                 extra=[str(x) for x in list(set(b) - set(a))[:5]]))
            continue
        for k in a:
            checked_obj += 1
            ta, da = a[k]
            tb, db = b[k]
            if ta != tb:
                problems.append(dict(key=key, issue='type changed', obj=str(k)))
            elif da != db and ta != 'Texture2D':
                problems.append(dict(key=key, issue='untouched object changed',
                                     obj=str(k), type=ta))

        orig_img = {}
        for o in UnityPy.load(src).objects:
            if o.type.name == 'Texture2D':
                d = o.read()
                if (d.m_Name or '').lower() in by_key[key]:
                    try:
                        orig_img[o.path_id] = d.image
                    except Exception as ex:
                        problems.append(dict(key=key, tex=d.m_Name,
                                             issue='original would not decode', error=repr(ex)))

        for o in UnityPy.load(dst).objects:
            if o.type.name != 'Texture2D':
                continue
            d = o.read()
            rec = by_key[key].get((d.m_Name or '').lower())
            if rec is None:
                continue
            checked_tex += 1
            got = (int(d.m_Width), int(d.m_Height), int(d.m_TextureFormat))
            want = (rec['w'], rec['h'], rec['fmt_id'])
            if got != want:
                problems.append(dict(key=key, tex=d.m_Name, issue='identity changed',
                                     got=list(got), want=list(want)))
                continue
            if int(d.m_MipCount or 1) != rec['mips']:
                problems.append(dict(key=key, tex=d.m_Name, issue='mip count changed',
                                     got=int(d.m_MipCount or 1), want=rec['mips']))
            if not d.image_data:
                problems.append(dict(key=key, tex=d.m_Name, issue='no inline image data'))
                continue
            if d.m_StreamData is not None and getattr(d.m_StreamData, 'path', ''):
                problems.append(dict(key=key, tex=d.m_Name, issue='still streamed from .resS',
                                     path=d.m_StreamData.path))
            exp = expected_bytes(rec['fmt_id'], rec['w'], rec['h'], int(d.m_MipCount or 1))
            if exp is not None and len(d.image_data) != exp:
                problems.append(dict(key=key, tex=d.m_Name, issue='image_data length wrong',
                                     got=len(d.image_data), want=exp,
                                     fmt=fmt_name(rec['fmt_id'])))
            oi = orig_img.get(o.path_id)
            if oi is None:
                continue
            try:
                ni = d.image
            except Exception as ex:
                problems.append(dict(key=key, tex=d.m_Name, issue='result would not decode',
                                     error=repr(ex)))
                continue
            rgb_mad = max(band_stats(oi, ni, i) for i in range(3))
            a_mad = band_stats(oi, ni, 3)
            rgb_mads.append(rgb_mad)
            alpha_mads.append(a_mad)
            if rgb_mad < args.rgb_min:
                problems.append(dict(key=key, tex=d.m_Name,
                                     issue='RGB did not change (replacement was a no-op)',
                                     rgb_mad=round(rgb_mad, 2)))
            if rec.get('keep_alpha') and a_mad > args.alpha_tol:
                problems.append(dict(key=key, tex=d.m_Name,
                                     issue='alpha (cutout mask) not preserved',
                                     alpha_mad=round(a_mad, 2)))

    print(f'verified {len(man)} bundles, {checked_obj} objects, {checked_tex} replaced textures')
    if rgb_mads:
        print(f'  RGB  mean-abs-diff vs original: min {min(rgb_mads):.1f} '
              f'median {sorted(rgb_mads)[len(rgb_mads)//2]:.1f} max {max(rgb_mads):.1f}  '
              f'(must be >= {args.rgb_min})')
        print(f'  ALPHA mean-abs-diff vs original: min {min(alpha_mads):.2f} '
              f'median {sorted(alpha_mads)[len(alpha_mads)//2]:.2f} max {max(alpha_mads):.2f}  '
              f'(must be <= {args.alpha_tol})')
    print(f'problems: {len(problems)}')
    for p in problems[:25]:
        print(' ', json.dumps(p)[:280])
    with open(os.path.join(args.out, 'verify-report.json'), 'w', newline='\n') as f:
        json.dump(problems, f, indent=2)
    sys.exit(1 if problems else 0)


if __name__ == '__main__':
    main()
