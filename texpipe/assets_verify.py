"""
Verify a prefab-surface patch pack WITHOUT applying it.

Every blob is checked against the bytes it would overwrite, read live out of the
game's own `.resS`. Nothing is written and no game file is opened for writing.

  1. blob length == the range it claims == what the format and mip chain demand
     (three independent numbers that must agree; one of them being right is not
     enough, and this is what stops a wrong stride writing plausible garbage)
  2. blob sha256 matches the manifest -- the pack has not rotted since it was built
  3. no two blobs overlap within one .resS, and none runs past its end
  4. every mip level decodes at the size the chain demands
  5. RGB ACTUALLY CHANGED versus the original, by more than re-encode loss
  6. ALPHA PRESERVED within tolerance -- the cutout masks survived

Checks 1-4 are satisfied perfectly by a pack whose blobs are just copies of the
original bytes. 5 and 6 are the ones that mean something.

THRESHOLDS ARE MEASURED. Run `assets_negcontrol.py`: it builds an identity pack
(each slot re-encoded from its own original) whose RGB difference is pure re-encode
loss, and that is the floor `--rgb-min` has to sit above.

Usage:
  python assets_verify.py --pack ../out/assets-pack [--rgb-min N] [--alpha-tol N]
"""
from __future__ import annotations
import argparse, collections, hashlib, json, os, sys

from PIL import Image

import tarray

DATA = 'D:/Aowlspt/EscapeFromTarkov_Data'


def band_mad(a: Image.Image, b: Image.Image, band: int, n: int = 128) -> float:
    A = a.convert('RGBA').resize((n, n), Image.LANCZOS).split()[band].tobytes()
    B = b.convert('RGBA').resize((n, n), Image.LANCZOS).split()[band].tobytes()
    return sum(abs(x - y) for x, y in zip(A, B)) / len(A)


def rgb_mad(a: Image.Image, b: Image.Image, n: int = 128) -> float:
    A = a.convert('RGB').resize((n, n), Image.LANCZOS).tobytes()
    B = b.convert('RGB').resize((n, n), Image.LANCZOS).tobytes()
    return sum(abs(x - y) for x, y in zip(A, B)) / len(A)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--pack', required=True)
    ap.add_argument('--rgb-min', type=float, default=None)
    ap.add_argument('--alpha-tol', type=float, default=2.0)
    ap.add_argument('--limit', type=int, default=0)
    args = ap.parse_args()

    pack = os.path.abspath(args.pack)
    man = json.load(open(os.path.join(pack, 'assets-manifest.json')))
    ents = man['entries']
    if args.limit:
        ents = ents[:args.limit]
    problems = []

    # ---- 3 overlap / bounds, per .resS
    by_res = collections.defaultdict(list)
    for e in ents:
        by_res[e['res']].append(e)
    overlaps, oob = 0, 0
    for resname, rows in by_res.items():
        p = os.path.join(DATA, resname)
        if not os.path.exists(p):
            problems.append(f'{resname} not on disk')
            continue
        sz = os.path.getsize(p)
        rows.sort(key=lambda e: e['off'])
        for a, b in zip(rows, rows[1:]):
            if a['off'] + a['size'] > b['off']:
                overlaps += 1
        for e in rows:
            if e['off'] + e['size'] > sz:
                oob += 1
    print(f'[3] .resS files {len(by_res)}   overlapping ranges {overlaps}   '
          f'out-of-bounds {oob}')
    if overlaps:
        problems.append(f'{overlaps} overlapping blob ranges')
    if oob:
        problems.append(f'{oob} blobs run past the end of their .resS')

    len_bad = sha_bad = mip_bad = 0
    rgbs, alphas = [], []
    worst_alpha = []
    n = 0
    for resname, rows in sorted(by_res.items()):
        p = os.path.join(DATA, resname)
        if not os.path.exists(p):
            continue
        with open(p, 'rb') as f:
            for e in rows:
                n += 1
                blobp = os.path.join(pack, 'blobs', e['blob'])
                data = open(blobp, 'rb').read()
                W, H, M, fmt = e['w'], e['h'], e['mips'], e['fmt']
                want = tarray.chain_bytes_fmt(W, H, M, fmt)
                # ---- 1
                if not (len(data) == e['size'] == want):
                    len_bad += 1
                    continue
                # ---- 2
                if hashlib.sha256(data).hexdigest()[:16] != e['sha']:
                    sha_bad += 1
                    continue
                f.seek(e['off'])
                orig = f.read(e['size'])
                mip0 = tarray.level_size(W, H, fmt)
                oi = tarray.decode_bc(orig[:mip0], W, H, fmt)
                ni = tarray.decode_bc(data[:mip0], W, H, fmt)
                # ---- 4
                pos, ok = 0, True
                for (mw, mh) in tarray.mip_dims(W, H, M):
                    lz = tarray.level_size(mw, mh, fmt)
                    try:
                        im = tarray.decode_bc(data[pos:pos + lz], mw, mh, fmt)
                        if im.size != (mw, mh):
                            ok = False
                            break
                    except Exception:
                        ok = False
                        break
                    pos += lz
                if not ok or pos != len(data):
                    mip_bad += 1
                    continue
                # ---- 5, 6
                rgbs.append((rgb_mad(oi, ni), e))
                if fmt == 12:
                    am = band_mad(oi, ni, 3)
                    alphas.append(am)
                    worst_alpha.append((am, e))

    print(f'[1] length agrees (blob == range == chain arithmetic): {n-len_bad}/{n}')
    print(f'[2] blob sha256 matches manifest: {n-len_bad-sha_bad}/{n}')
    print(f'[4] mip chains intact: {len(rgbs)}/{n}')
    for label, cnt, msg in (('1', len_bad, 'blobs whose length disagrees'),
                            ('2', sha_bad, 'blobs whose sha does not match'),
                            ('4', mip_bad, 'blobs with a broken mip chain')):
        if cnt:
            problems.append(f'{cnt} {msg}')

    if rgbs:
        v = sorted(x for x, _ in rgbs)
        print(f'[5] RGB mean-abs-diff: min {v[0]:.1f}  median {v[len(v)//2]:.1f}  '
              f'max {v[-1]:.1f}  (n={len(v)})')
        for m, e in sorted(rgbs, key=lambda x: x[0])[:5]:
            print(f'      lowest {m:6.1f}  {e["name"]} <- {e["acg"]} [{e["res"]}]')
        if args.rgb_min is None:
            print('      (no --rgb-min: REPORTED, NOT GATED -- this check has not '
                  'been performed as a pass/fail)')
        else:
            bad = sum(1 for m, _ in rgbs if m < args.rgb_min)
            print(f'      gate --rgb-min={args.rgb_min}: {bad} below')
            if bad:
                problems.append(f'{bad} textures did not change enough '
                                f'(RGB mad < {args.rgb_min})')
    if alphas:
        a = sorted(alphas)
        print(f'[6] ALPHA mean-abs-diff: min {a[0]:.2f}  median {a[len(a)//2]:.2f}  '
              f'max {a[-1]:.2f}  (n={len(a)}, DXT5 only)')
        bad = sum(1 for x in alphas if x > args.alpha_tol)
        for m, e in sorted(worst_alpha, key=lambda x: -x[0])[:5]:
            print(f'      worst {m:6.2f}  {e["name"]}')
        print(f'      gate --alpha-tol={args.alpha_tol}: {bad} above')
        if bad:
            problems.append(f'{bad} textures lost their alpha channel '
                            f'(alpha mad > {args.alpha_tol})')

    print()
    if problems:
        print(f'REJECTED -- {len(problems)} problem(s):')
        for p in problems:
            print('   -', p)
        return 1
    print('ACCEPTED' + ('' if args.rgb_min is not None
                        else '  (with check 5 reported but NOT gated)'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
