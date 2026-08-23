"""
Verify a terrain pack produced by `terrain_build.py`.

The point of this file is check 4 and check 6. Checks 1-3 and 5 confirm we did not
break anything, and a pack that only passes those is a green light from a comparison
that compared nothing: an unpatched copy of the `.resS` passes all four perfectly.

  1. the pack's `.resS` is exactly the same SIZE as the game's
  2. `sharedassets17.assets` was not touched at all (byte-identical to the game's)
  3. every byte OUTSIDE the patched slice ranges is identical to the original
  4. every patched slice's RGB ACTUALLY CHANGED, by more than DXT5 re-encode loss
  5. every `*_normSAO_*` array's bytes are untouched -- we do not write data maps
  6. every mip level of every patched slice decodes at the size the format demands,
     so the chain is intact rather than merely the right total length

THRESHOLDS ARE MEASURED, NOT CHOSEN.

`terrain_build.py --identity` runs the whole pipeline with each slice's own decoded
original as the source, so its RGB difference is pure DXT5 re-encode loss and nothing
else. That number is the floor a real pack has to clear, and `--rgb-min` belongs in
the gap between the identity control's ceiling and the real pack's minimum. Run
`terrain_negcontrol.py` to measure both; do not invent a number.

Usage:
  python terrain_verify.py --pack ../out/terrain-pack [--rgb-min N]
"""
from __future__ import annotations
import argparse, json, os, sys

import UnityPy
from PIL import Image

import tarray

DATA = 'D:/Aowlspt/EscapeFromTarkov_Data'
ASSETS = os.path.join(DATA, 'sharedassets17.assets')
RESS_NAME = 'sharedassets17.assets.resS'


def mad_rgb(a: Image.Image, b: Image.Image, n: int = 128) -> float:
    A = a.convert('RGB').resize((n, n), Image.LANCZOS).tobytes()
    B = b.convert('RGB').resize((n, n), Image.LANCZOS).tobytes()
    return sum(abs(x - y) for x, y in zip(A, B)) / len(A)


def read_arrays():
    env = UnityPy.load(ASSETS)
    out = {}
    for o in env.objects:
        if o.type.name != 'Texture2DArray':
            continue
        t = o.read_typetree()
        n = str(t.get('m_Name', ''))
        if n.startswith('MicroSplatConfig_'):
            out[n] = t
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--pack', required=True)
    ap.add_argument('--rgb-min', type=float, default=None,
                    help='if omitted, check 4 REPORTS numbers but does not gate; '
                         'run terrain_negcontrol.py to obtain a measured threshold')
    args = ap.parse_args()

    pack = os.path.abspath(args.pack)
    mp = os.path.join(pack, 'terrain-manifest.json')
    if not os.path.exists(mp):
        sys.exit(f'no manifest at {mp}')
    man = json.load(open(mp))
    new_ress = os.path.join(pack, RESS_NAME)
    old_ress = os.path.join(DATA, RESS_NAME)
    problems = []

    # ---- 1 size
    so, sn = os.path.getsize(old_ress), os.path.getsize(new_ress)
    print(f'[1] .resS size  original={so:,}  pack={sn:,}  '
          f'{"OK" if so == sn else "MISMATCH"}')
    if so != sn:
        problems.append('resS size changed')

    # ---- 2 .assets untouched
    packed_assets = os.path.join(pack, 'sharedassets17.assets')
    if os.path.exists(packed_assets):
        same = open(packed_assets, 'rb').read() == open(ASSETS, 'rb').read()
        print(f'[2] sharedassets17.assets in pack: byte-identical={same}')
        if not same:
            problems.append('.assets modified')
    else:
        print('[2] sharedassets17.assets not in the pack at all -- '
              'nothing to diverge (this method never touches it)')

    arrays = read_arrays()
    slices = man['slices']

    # ---- ranges
    patched = []
    for s in slices:
        patched.append((int(s['offset']), int(s['offset']) + int(s['nbytes'])))
    patched.sort()
    merged = []
    for a, b in patched:
        if merged and a <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], b))
        else:
            merged.append((a, b))
    total_patched = sum(b - a for a, b in merged)
    print(f'    manifest claims {len(slices)} slices, '
          f'{total_patched:,} bytes in {len(merged)} contiguous ranges')

    # ---- 3 everything outside the patched ranges identical
    CH = 1 << 22
    fo, fn = open(old_ress, 'rb'), open(new_ress, 'rb')
    outside_bad = 0
    pos, mi = 0, 0
    try:
        while pos < so:
            if mi < len(merged) and pos >= merged[mi][0]:
                pos = merged[mi][1]
                mi += 1
                continue
            end = merged[mi][0] if mi < len(merged) else so
            while pos < end:
                n = min(CH, end - pos)
                fo.seek(pos); fn.seek(pos)
                if fo.read(n) != fn.read(n):
                    outside_bad += 1
                    break
                pos += n
            else:
                continue
            break
        print(f'[3] bytes outside patched ranges identical: '
              f'{"YES" if outside_bad == 0 else "NO"}')
        if outside_bad:
            problems.append('bytes outside the patched ranges changed')

        # ---- 5 normSAO untouched
        bad_norm = []
        for name, t in arrays.items():
            if '_normSAO' not in name:
                continue
            sd = t['m_StreamData']
            off, size = int(sd['offset']), int(sd['size'])
            fo.seek(off); fn.seek(off)
            eq = True
            left = size
            while left > 0:
                n = min(CH, left)
                if fo.read(n) != fn.read(n):
                    eq = False
                    break
                left -= n
            if not eq:
                bad_norm.append(name)
        print(f'[5] normSAO arrays untouched: {len(arrays and [n for n in arrays if "_normSAO" in n]) - len(bad_norm)}'
              f'/{len([n for n in arrays if "_normSAO" in n])}')
        for n in bad_norm[:5]:
            print(f'    MODIFIED: {n}  <-- data map written; that is never correct')
        if bad_norm:
            problems.append(f'{len(bad_norm)} normSAO data maps were modified')

        # ---- 4 + 6
        mads, bad_mip = [], []
        for s in slices:
            t = arrays.get(s['array'])
            if t is None:
                problems.append(f'unknown array {s["array"]}')
                continue
            w, h, mips = int(t['m_Width']), int(t['m_Height']), int(t['m_MipCount'])
            per = int(s['nbytes'])
            off = int(s['offset'])
            fo.seek(off); fn.seek(off)
            ob, nb = fo.read(per), fn.read(per)
            mip0 = tarray.level_size_dxt5(w, h)
            oi = tarray.decode_dxt5(ob[:mip0], w, h)
            ni = tarray.decode_dxt5(nb[:mip0], w, h)
            mads.append((mad_rgb(oi, ni), s))
            # 6: walk the whole chain
            p = 0
            for (mw, mh) in tarray.mip_dims(w, h, mips):
                lz = tarray.level_size_dxt5(mw, mh)
                try:
                    im = tarray.decode_dxt5(nb[p:p + lz], mw, mh)
                    if im.size != (mw, mh):
                        raise ValueError(f'decoded {im.size}, want {(mw, mh)}')
                except Exception as e:
                    bad_mip.append((s['array'], s['slice'], mw, mh, repr(e)[:60]))
                    break
                p += lz
            if p != per:
                bad_mip.append((s['array'], s['slice'], w, h,
                                f'chain consumed {p} of {per} bytes'))
    finally:
        fo.close(); fn.close()

    vals = sorted(m for m, _ in mads)
    print(f'[6] mip chains intact: {len(slices)-len(bad_mip)}/{len(slices)}')
    for a, i, w, h, e in bad_mip[:5]:
        print(f'    {a} slice {i} {w}x{h}: {e}')
    if bad_mip:
        problems.append(f'{len(bad_mip)} slices have a broken mip chain')

    if vals:
        print(f'[4] RGB mean-abs-diff vs original: min {vals[0]:.1f}  '
              f'median {vals[len(vals)//2]:.1f}  max {vals[-1]:.1f}  (n={len(vals)})')
        worst = sorted(mads, key=lambda x: x[0])[:5]
        for m, s in worst:
            print(f'      lowest: {m:6.1f}  {s["array"]} s{s["slice"]} '
                  f'{s["surface"]} <- {s["acg"]}')
        if args.rgb_min is None:
            print('      (no --rgb-min given: REPORTED, NOT GATED. This check has '
                  'not been performed as a pass/fail.)')
        else:
            n_bad = sum(1 for m, _ in mads if m < args.rgb_min)
            print(f'      gate --rgb-min={args.rgb_min}: {n_bad} slice(s) below')
            if n_bad:
                problems.append(f'{n_bad} slices did not change enough '
                                f'(RGB mad < {args.rgb_min})')

    print()
    if problems:
        print(f'REJECTED -- {len(problems)} problem(s):')
        for p in problems:
            print('   -', p)
        return 1
    print('ACCEPTED' + ('' if args.rgb_min is not None else
                        '  (with check 4 reported but NOT gated)'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
