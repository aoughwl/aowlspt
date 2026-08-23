"""
Post-1.0 texture inventory, built FROM THE BUNDLES, never from a name dump.

Fact #65 is why: the ambientcg-overhaul manifest was scoped against a text dump of a
different build and only 52 of its 512 names (10.2%) existed in EFT 0.16.9. Names are
never salvaged here; everything downstream is derived from this scan.

Emits one JSON row per Texture2D: name, path_id, bundle key, format (mapped to a real
name, not the bare int), width, height, mip count, whether the pixels are streamed to a
.resS side file.

Usage:
  python inventory.py --out ../out/inv-post1.json [--prefix assets/content/location_objects] [--jobs 8]
"""
from __future__ import annotations
import argparse, json, os, sys, time, traceback
from concurrent.futures import ProcessPoolExecutor

GAME_ROOT = 'D:/Aowlspt/EscapeFromTarkov_Data/StreamingAssets/Windows'
WJ = os.path.join(GAME_ROOT, 'Windows.json')

# UnityPy gotcha, measured: d.m_TextureFormat is a bare int on 1.25.3, so
# getattr(fmt, 'name', str(fmt)) silently yields "12". Map it explicitly.
TEXFMT = {
    1: 'Alpha8', 2: 'ARGB4444', 3: 'RGB24', 4: 'RGBA32', 5: 'ARGB32', 7: 'RGB565',
    9: 'R16', 10: 'DXT1', 12: 'DXT5', 13: 'RGBA4444', 14: 'BGRA32', 15: 'RHalf',
    16: 'RGHalf', 17: 'RGBAHalf', 18: 'RFloat', 19: 'RGFloat', 20: 'RGBAFloat',
    21: 'YUY2', 22: 'RGB9e5Float', 24: 'BC6H', 25: 'BC7', 26: 'BC4', 27: 'BC5',
    28: 'DXT1Crunched', 29: 'DXT5Crunched', 41: 'EAC_R', 45: 'ETC2_RGB',
    47: 'ETC2_RGBA8', 48: 'ASTC_4x4', 62: 'RG16', 63: 'R8',
}


def fmt_name(v: int) -> str:
    return TEXFMT.get(int(v), f'UNKNOWN_{int(v)}')


def game_path(file_field: str) -> str:
    rel = file_field.split('StreamingAssets/', 1)[1]
    return os.path.join(GAME_ROOT, rel.replace('/', os.sep))


def scan_one(arg):
    key, path = arg
    import UnityPy
    rows = []
    try:
        env = UnityPy.load(path)
        n_obj = 0
        for o in env.objects:
            n_obj += 1
            if o.type.name != 'Texture2D':
                continue
            d = o.read()
            sd = getattr(d, 'm_StreamData', None)
            rows.append(dict(
                name=d.m_Name or '', lname=(d.m_Name or '').lower(),
                path_id=o.path_id, key=key,
                fmt_id=int(d.m_TextureFormat), fmt=fmt_name(d.m_TextureFormat),
                w=int(d.m_Width), h=int(d.m_Height),
                mips=int(d.m_MipCount or 1),
                streamed=bool(sd is not None and getattr(sd, 'path', '')),
            ))
        return key, rows, n_obj, None
    except Exception as e:
        return key, [], 0, repr(e) + '|' + traceback.format_exc()[-400:]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', required=True)
    ap.add_argument('--prefix', action='append', default=None)
    ap.add_argument('--jobs', type=int, default=8)
    ap.add_argument('--limit', type=int, default=0)
    args = ap.parse_args()

    wj = json.load(open(WJ))
    keys = sorted(wj)
    if args.prefix:
        keys = [k for k in keys if any(k.startswith(p) for p in args.prefix)]
    work = []
    missing = []
    for k in keys:
        p = game_path(wj[k]['FileName'])
        if os.path.exists(p):
            work.append((k, p))
        else:
            missing.append(k)
    if args.limit:
        work = work[:args.limit]

    t0 = time.time()
    rows, errors, objs, done = [], [], 0, 0
    with ProcessPoolExecutor(max_workers=args.jobs) as ex:
        for key, r, n, err in ex.map(scan_one, work, chunksize=4):
            done += 1
            objs += n
            rows.extend(r)
            if err:
                errors.append(dict(key=key, error=err))
            if done % 250 == 0:
                print(f'  {done}/{len(work)} bundles, {len(rows)} textures, '
                      f'{time.time()-t0:.0f}s', flush=True)

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, 'w', newline='\n') as f:
        json.dump(dict(
            root=GAME_ROOT, scanned_bundles=len(work), missing_files=missing,
            total_objects=objs, elapsed_s=round(time.time() - t0, 1),
            errors=errors, textures=rows), f)

    import collections
    print(f'scanned {len(work)} bundles ({len(missing)} keys had no file on disk), '
          f'{objs} objects, {len(rows)} Texture2D, '
          f'{len({r["lname"] for r in rows})} distinct names, '
          f'{len(errors)} errors, {time.time()-t0:.0f}s')
    print(collections.Counter(r['fmt'] for r in rows).most_common())


if __name__ == '__main__':
    main()
