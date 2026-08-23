"""
Where do post-1.0 in-raid terrain textures actually live?

The StreamingAssets bundle set turned out to hold very few tiling ground surfaces, so
this probes the game's serialized files (level*, sharedassets*.assets, resources.assets)
for Texture2D names. Those files are NOT AssetBundles: the EasyBundle._path redirect
(fact #82) cannot reach them, and every one of them is listed in ConsistencyInfo.

This is a measurement tool only. It never writes into the game directory.

Usage: python probe_levels.py [--n 25]
"""
from __future__ import annotations
import argparse, collections, json, os, re, time, traceback
from concurrent.futures import ProcessPoolExecutor

DATA = 'D:/Aowlspt/EscapeFromTarkov_Data'
KW = ('terrain', 'ground', 'grass', 'dirt', 'soil', 'mud', 'sand', 'gravel',
      'asphalt', 'road', 'rock', 'cliff', 'splat', 'landscape')


def scan(path):
    import UnityPy
    from inventory import fmt_name
    try:
        env = UnityPy.load(path)
        rows = []
        for o in env.objects:
            if o.type.name != 'Texture2D':
                continue
            d = o.read()
            rows.append((d.m_Name or '', int(d.m_Width), int(d.m_Height),
                         fmt_name(d.m_TextureFormat), int(d.m_MipCount or 1)))
        return os.path.basename(path), rows, None
    except Exception as e:
        return os.path.basename(path), [], repr(e)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--n', type=int, default=25)
    ap.add_argument('--jobs', type=int, default=6)
    args = ap.parse_args()
    cands = [os.path.join(DATA, f) for f in os.listdir(DATA)
             if re.match(r'^(sharedassets\d+\.assets|resources\.assets|level\d+)$', f)]
    cands.sort(key=lambda p: -os.path.getsize(p))
    cands = cands[:args.n]
    print(f'probing {len(cands)} largest serialized files '
          f'({sum(os.path.getsize(p) for p in cands)/1e9:.1f} GB)')
    t0 = time.time()
    total, hits, errs = 0, [], []
    with ProcessPoolExecutor(max_workers=args.jobs) as ex:
        for name, rows, err in ex.map(scan, cands):
            if err:
                errs.append((name, err))
                continue
            total += len(rows)
            for r in rows:
                if any(k in r[0].lower() for k in KW):
                    hits.append((name,) + r)
    print(f'{total} Texture2D in those files, {len(hits)} name-match terrain keywords, '
          f'{len(errs)} unreadable, {time.time()-t0:.0f}s')
    for e in errs[:5]:
        print('  ERR', e[0], e[1][:120])
    for h in sorted(hits)[:60]:
        print(f'  {h[0]:26s} {h[1][:44]:46s} {h[2]}x{h[3]} {h[4]} mips={h[5]}')


if __name__ == '__main__':
    main()
