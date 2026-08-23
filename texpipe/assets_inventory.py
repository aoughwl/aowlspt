"""
Full Texture2D census of the game's serialized files (`.assets` / `level*`).

Job 2 asked for prefab surfaces -- concrete walls, brick, metal, wood. The post-1.0
BUNDLE census says those are not in the bundles: of 26,959 bundle Texture2Ds, 14,510
are items, 6,264 pocketmap, 2,228 weapons, 1,379 characters, 612 hands, and only 881
are `location_objects` of which 608 are the hideout. That leaves a few hundred
grass cards and props -- nowhere near "the environment".

The terrain work established that the map's real content lives in the serialized
files, and that those are patchable in place through their `.resS`. So this censuses
them the same way `inventory.py` censuses bundles, recording for every Texture2D the
data needed to patch it: format, dimensions, mip count, and whether its pixels are
inline or at a fixed offset in a sibling `.resS`.

Read-only. Never writes into a game directory.

Usage:
  python assets_inventory.py --out ../out/inv-assets.json [--jobs 8]
"""
from __future__ import annotations
import argparse, collections, json, os, re, time
from concurrent.futures import ProcessPoolExecutor

DATA = 'D:/Aowlspt/EscapeFromTarkov_Data'
PAT = re.compile(r'^(sharedassets\d+\.assets|resources\.assets|'
                 r'globalgamemanagers\.assets|level\d+)$')

FMT = {1: 'Alpha8', 3: 'RGB24', 4: 'RGBA32', 5: 'ARGB32', 7: 'RGB565', 10: 'DXT1',
       12: 'DXT5', 13: 'RGBA4444', 14: 'BGRA32', 22: 'RGB9e5Float', 25: 'BC7',
       26: 'BC4', 27: 'BC5', 24: 'BC6H', 28: 'DXT1Crunched', 29: 'DXT5Crunched',
       41: 'RG16', 63: 'RG32'}


def scan(path):
    import UnityPy
    name = os.path.basename(path)
    try:
        env = UnityPy.load(path)
        rows = []
        for o in env.objects:
            if o.type.name != 'Texture2D':
                continue
            try:
                t = o.read_typetree()
            except Exception:
                continue
            sd = t.get('m_StreamData') or {}
            rows.append(dict(
                file=name, path_id=int(o.path_id),
                name=str(t.get('m_Name', '')),
                w=int(t.get('m_Width', 0)), h=int(t.get('m_Height', 0)),
                fmt=int(t.get('m_TextureFormat', 0)),
                mips=int(t.get('m_MipCount', 1) or 1),
                inline=int(len(t.get('image data') or b'')),
                res=str(sd.get('path', '') or ''),
                off=int(sd.get('offset', 0) or 0),
                size=int(sd.get('size', 0) or 0),
            ))
        return name, rows, None
    except Exception as e:
        return name, [], repr(e)[:200]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', default='../out/inv-assets.json')
    ap.add_argument('--jobs', type=int, default=8)
    args = ap.parse_args()

    files = [os.path.join(DATA, f) for f in os.listdir(DATA) if PAT.match(f)]
    files.sort(key=lambda p: -os.path.getsize(p))
    print(f'scanning {len(files)} serialized files '
          f'({sum(os.path.getsize(p) for p in files)/1e9:.1f} GB)')

    t0 = time.time()
    rows, errs = [], []
    with ProcessPoolExecutor(max_workers=args.jobs) as ex:
        for name, rr, err in ex.map(scan, files, chunksize=4):
            if err:
                errs.append((name, err))
            rows.extend(rr)
    print(f'{len(rows):,} Texture2D in {time.time()-t0:.0f}s, errors={len(errs)}')
    for n, e in errs[:10]:
        print('  ERR', n, e)

    C = collections.Counter
    print(f'distinct names : {len({r["name"].lower() for r in rows}):,}')
    print('formats        :', C(FMT.get(r['fmt'], r['fmt']) for r in rows).most_common())
    print('storage        : inline='
          f'{sum(1 for r in rows if r["inline"]):,}  '
          f'streamed={sum(1 for r in rows if r["res"]):,}')
    print('sizes          :', C(f'{r["w"]}x{r["h"]}' for r in rows).most_common(10))
    print('top files      :', C(r['file'] for r in rows).most_common(10))

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, 'w', newline='\n') as f:
        json.dump(dict(textures=rows, errors=errs, scanned=len(files)), f)
    print('wrote', args.out)


if __name__ == '__main__':
    main()
