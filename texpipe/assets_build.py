"""
Build a PATCH PACK for prefab environment surfaces in the serialized files.

The terrain pack could ship a whole rewritten `.resS` because there is only one file.
The prefab worklist touches 178 different `.resS` files totalling many gigabytes, so
shipping copies is not sensible. This emits instead:

    <pack>/blobs/<resS>__<offset>.bin      the replacement bytes for one texture
    <pack>/assets-manifest.json            what each blob replaces, and its provenance

Each blob is EXACTLY as long as the range it replaces, so applying the pack is a
seek-and-write with no resizing, every `.assets` stays byte-identical, and every
`.resS` keeps its SIZE -- only its ConsistencyInfo Checksum changes.

This tool does not apply anything and cannot: it refuses to write inside a game
install, and the deploy step (which must break the D:\\Games\\Tarkov hardlink first)
belongs to the coordinating session.

WHAT IT REPLACES

Only rows the scoper matched: streamed, DXT1/DXT5, albedo by suffix (or by name-guess
with --allow-unsuffixed). Normals, gloss, AO, masks, decals, posters, wood and glass
are not here -- see `assets_scope.py` for the counts and the reasons.

ALPHA IS PRESERVED. Many of these slots are alpha-cut cards (fences, grates,
foliage); an ambientCG Color map is opaque, so RGB is replaced and the original's
alpha is carried through per mip level.

Usage:
  python assets_build.py --worklist ../out/worklist-assets.json --out ../out/assets-pack
"""
from __future__ import annotations
import argparse, collections, hashlib, json, os, sys, time

from PIL import Image

import tarray
from terrain_build import acg_catalogue, color_path

DATA = 'D:/Aowlspt/EscapeFromTarkov_Data'


def pick_res(edge: int, cat_entry: dict, forced: str | None):
    """Smallest available ambientCG tier that is >= the slot. Never upscale."""
    order = ['1K', '2K', '4K']
    if forced:
        return forced if forced in cat_entry else None
    for r in order:
        if r in cat_entry and int(r[:-1]) * 1024 >= edge:
            return r
    # nothing big enough: fall back to the largest we have, and say so
    return max((r for r in order if r in cat_entry),
               key=lambda r: int(r[:-1]), default=None)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--worklist', default='../out/worklist-assets.json')
    ap.add_argument('--out', required=True)
    ap.add_argument('--source-tier', default=None, choices=['1K', '2K', '4K'])
    ap.add_argument('--limit', type=int, default=0)
    ap.add_argument('--identity', action='store_true',
                    help='NEGATIVE CONTROL: re-encode each slot from its OWN decoded '
                         'original. Measures pure re-encode loss; must be REJECTED.')
    ap.add_argument('--no-alpha', action='store_true',
                    help='NEGATIVE CONTROL: take the source alpha (opaque) instead of '
                         "the original's. Must be REJECTED by the alpha check.")
    args = ap.parse_args()

    out = os.path.abspath(args.out)
    low = out.lower().replace('\\', '/')
    if low.startswith('d:/aowlspt') or low.startswith('d:/games'):
        sys.exit('REFUSING: --out is inside a game install.')
    blobs = os.path.join(out, 'blobs')
    os.makedirs(blobs, exist_ok=True)

    work = json.load(open(args.worklist))['work']
    if args.limit:
        work = work[:args.limit]
    cat = acg_catalogue()

    print(f'worklist: {len(work)} textures, {len({w["res"] for w in work})} .resS files')
    t0 = time.time()
    entries, skipped = [], []
    upscaled = 0
    src_cache = {}
    by_res = collections.defaultdict(list)
    for w in work:
        by_res[w['res']].append(w)

    done = 0
    for resname, rows in sorted(by_res.items()):
        path = os.path.join(DATA, resname)
        if not os.path.exists(path):
            for w in rows:
                skipped.append((w['name'], f'{resname} not on disk'))
            continue
        with open(path, 'rb') as f:
            for w in rows:
                done += 1
                fmt, W, H, M = w['fmt'], w['w'], w['h'], w['mips']
                want = tarray.chain_bytes_fmt(W, H, M, fmt)
                if want != w['size']:
                    skipped.append((w['name'],
                                    f'chain arithmetic {want} != m_StreamData.size '
                                    f'{w["size"]}; refusing rather than guessing'))
                    continue
                f.seek(w['off'])
                orig = f.read(w['size'])
                if len(orig) != w['size']:
                    skipped.append((w['name'], 'short read from .resS'))
                    continue
                mip0 = tarray.level_size(W, H, fmt)
                orig_img = tarray.decode_bc(orig[:mip0], W, H, fmt)

                mat = w['acg_material']
                res = pick_res(max(W, H), cat.get(mat, {}), args.source_tier)
                if res is None:
                    skipped.append((w['name'], f'no ambientCG tier for {mat}'))
                    continue
                if int(res[:-1]) * 1024 < max(W, H):
                    upscaled += 1
                if args.identity:
                    src = orig_img
                else:
                    key = (mat, res)
                    if key not in src_cache:
                        src_cache[key] = Image.open(color_path(cat, mat, res)).convert('RGBA')
                    src = src_cache[key]

                alpha_from = None if args.no_alpha else orig_img
                data = tarray.build_chain_fmt(src, W, H, M, fmt, alpha_from=alpha_from)
                if len(data) != w['size']:
                    skipped.append((w['name'],
                                    f'built {len(data)} bytes, want {w["size"]}'))
                    continue

                blob = f'{resname}__{w["off"]}.bin'
                with open(os.path.join(blobs, blob), 'wb') as bf:
                    bf.write(data)
                entries.append(dict(
                    blob=blob, res=resname, file=w['file'], path_id=w['path_id'],
                    name=w['name'], off=w['off'], size=w['size'],
                    w=W, h=H, fmt=fmt, mips=M,
                    acg=(mat if not args.identity else '<identity control>'),
                    acg_res=res, kw=w.get('kw', ''),
                    keep_alpha=not args.no_alpha,
                    sha=hashlib.sha256(data).hexdigest()[:16],
                ))
                if done % 100 == 0:
                    print(f'  {done}/{len(work)}  {time.time()-t0:.0f}s')

    print(f'built {len(entries)} blobs in {time.time()-t0:.0f}s, '
          f'skipped {len(skipped)}')
    if upscaled:
        print(f'  NOTE: {upscaled} slot(s) had no ambientCG tier large enough and '
              f'were filled from a smaller source (upscaled).')
    for n, why in skipped[:10]:
        print(f'  SKIP {n}: {why}')

    man = dict(method='resS-blob-patch', data_dir=DATA,
               source_tier=args.source_tier or 'auto',
               identity=args.identity, no_alpha=args.no_alpha,
               ress_files=sorted({e['res'] for e in entries}),
               entries=entries, skipped=skipped)
    mp = os.path.join(out, 'assets-manifest.json')
    with open(mp, 'w', newline='\n') as f:
        json.dump(man, f)
    print('wrote', mp)
    print(f'pack touches {len(man["ress_files"])} .resS files; '
          f'{sum(e["size"] for e in entries)/1e9:.2f} GB of replacement bytes')
    return 0


if __name__ == '__main__':
    sys.exit(main())
