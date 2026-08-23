"""
Post-1.0 replacement-bundle builder.

Same approach as build.py and for the same reason (see texpipe/README.md): PATCH IN
PLACE. Each original .bundle is loaded with UnityPy, only the targeted Texture2D
objects are re-encoded, and the archive is re-serialised. Every other object keeps its
original bytes and its original PathID, so nothing can be lost.

Differences from build.py:
  * reads the post-1.0 game at D:/Aowlspt, not the SPT 4.1.2 install
  * writes real ambientCG imagery instead of a hue tint
  * preserves the ORIGINAL ALPHA channel: everything in scope is an alpha-cut foliage
    card, and an ambientCG Color map is opaque
  * albedo only (fact #36)

It NEVER writes inside the game directory. Output goes to --out.

Usage:
  python build_post1.py --out ../out/post1-pack [--limit N] [--only SUBSTR]
"""
from __future__ import annotations
import argparse, collections, json, os, time, traceback

import UnityPy
from PIL import Image

from inventory import GAME_ROOT, WJ, game_path, fmt_name


def build_mip_chain(img: Image.Image, fmt: int, mip_count: int):
    """Encode img and its mip chain to fmt. Returns (bytes, levels, tex_fmt)."""
    from UnityPy.export import Texture2DConverter as C
    w, h = img.size
    data = b''
    n = 0
    tex_fmt = fmt
    for _ in range(max(1, mip_count)):
        lvl = img if (w, h) == img.size else img.resize((w, h), Image.Resampling.BICUBIC)
        enc, tex_fmt = C.image_to_texture2d(lvl, fmt)
        data += enc
        n += 1
        if w == 1 and h == 1:
            break
        w = max(1, w // 2)
        h = max(1, h // 2)
    return data, n, tex_fmt


_SRC_CACHE: dict = {}


def load_src(path: str, size) -> Image.Image:
    """ambientCG Color map, resized to the original's exact dimensions."""
    key = (path, size)
    hit = _SRC_CACHE.get(key)
    if hit is None:
        im = Image.open(path).convert('RGB')
        if im.size != size:
            im = im.resize(size, Image.Resampling.LANCZOS)
        _SRC_CACHE[key] = hit = im
        if len(_SRC_CACHE) > 24:
            _SRC_CACHE.pop(next(iter(_SRC_CACHE)))
    return hit


def compose(original: Image.Image, src_path: str, keep_alpha: bool) -> Image.Image:
    """RGB from ambientCG, alpha from the ORIGINAL. The alpha of every foliage card in
    scope is its cutout mask; taking the source's (opaque) alpha would turn each grass
    quad into a solid rectangle."""
    orig = original.convert('RGBA')
    new_rgb = load_src(src_path, orig.size)
    if keep_alpha:
        return Image.merge('RGBA', new_rgb.split() + (orig.split()[3],))
    return new_rgb.convert('RGBA')


def patch_bundle(key: str, src: str, targets: dict, dst: str, report: list, packer='lz4'):
    env = UnityPy.load(src)
    before = sorted((o.path_id, o.type.name) for o in env.objects)
    touched = 0

    for obj in env.objects:
        if obj.type.name != 'Texture2D':
            continue
        d = obj.read()
        rec = targets.get((d.m_Name or '').lower())
        if rec is None:
            continue
        orig_fmt = int(d.m_TextureFormat)
        orig_w, orig_h, orig_mips = int(d.m_Width), int(d.m_Height), int(d.m_MipCount or 1)
        # the inventory is the contract; if the live object disagrees, do not guess
        if (orig_fmt, orig_w, orig_h) != (rec['fmt_id'], rec['w'], rec['h']):
            report.append(dict(key=key, tex=d.m_Name, status='inventory-mismatch',
                               live=[orig_fmt, orig_w, orig_h],
                               inv=[rec['fmt_id'], rec['w'], rec['h']]))
            continue
        try:
            img = d.image
        except Exception as e:
            report.append(dict(key=key, tex=d.m_Name, status='decode-failed', error=repr(e)))
            continue

        newimg = compose(img, rec['src'], rec.get('keep_alpha', True))
        data, levels, tex_fmt = build_mip_chain(newimg, orig_fmt, orig_mips)

        d.image_data = data
        d.m_CompleteImageSize = len(data)
        d.m_Width, d.m_Height = orig_w, orig_h
        d.m_TextureFormat = tex_fmt
        if d.m_MipCount is not None:
            d.m_MipCount = levels
        if d.m_MipMap is not None:
            d.m_MipMap = levels > 1
        if d.m_StreamData is not None:
            # pixels are inlined into the object; the original .resS is not ours to edit
            d.m_StreamData.path = ''
            d.m_StreamData.offset = 0
            d.m_StreamData.size = 0
        d.save()
        touched += 1
        report.append(dict(key=key, tex=d.m_Name, status='replaced',
                           acg=rec['acg_material'], acg_res=rec['acg_res'],
                           map=rec['map'], kw=rec['kw'],
                           w=orig_w, h=orig_h,
                           fmt=fmt_name(tex_fmt), fmt_orig=fmt_name(orig_fmt),
                           mips=levels, mips_orig=orig_mips,
                           kept_alpha=bool(rec.get('keep_alpha', True)),
                           bytes=len(data)))

    if not touched:
        return False

    blob = env.file.save(packer=packer)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(dst, 'wb') as f:
        f.write(blob)

    after = sorted((o.path_id, o.type.name) for o in UnityPy.load(dst).objects)
    if before != after:
        raise RuntimeError(f'object census changed: {len(before)} -> {len(after)}')
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', required=True)
    ap.add_argument('--worklist', default='../out/worklist-post1.json')
    ap.add_argument('--limit', type=int, default=0)
    ap.add_argument('--only', default=None)
    ap.add_argument('--packer', default='lz4', choices=['lz4', 'original', 'none', 'lzma'])
    args = ap.parse_args()

    out = os.path.abspath(args.out)
    if out.lower().startswith(('d:\\aowlspt\\escapefromtarkov_data', 'd:\\spt')):
        raise SystemExit('refusing to write inside the game install')

    wj = json.load(open(WJ))
    work = json.load(open(args.worklist))['work']
    by_key = collections.defaultdict(dict)
    for t in work:
        by_key[t['key']][t['lname']] = t
    keys = sorted(by_key)
    if args.only:
        keys = [k for k in keys if args.only in k]
    if args.limit:
        keys = keys[:args.limit]

    bundles_dir = os.path.join(out, 'bundles')
    report, manifest, failures, skipped = [], [], [], []
    t0 = time.time()
    for i, key in enumerate(keys, 1):
        src = game_path(wj[key]['FileName'])
        # the file on disk is named EXACTLY like the key; 214 of the SPT keys had no
        # .bundle extension and normalising one on breaks the lookup.
        dst = os.path.join(bundles_dir, key.replace('/', os.sep))
        try:
            ok = patch_bundle(key, src, by_key[key], dst, report, args.packer)
        except Exception as e:
            failures.append(dict(key=key, error=repr(e), tb=traceback.format_exc()[-1200:]))
            print(f'[{i}/{len(keys)}] FAIL {key}: {e}', flush=True)
            continue
        if ok:
            manifest.append(dict(key=key, dependencyKeys=list(wj[key].get('Dependencies') or [])))
            print(f'[{i}/{len(keys)}] ok   {key}', flush=True)
        else:
            skipped.append(key)
            print(f'[{i}/{len(keys)}] skip {key}', flush=True)

    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, 'bundles.json'), 'w', newline='\n') as f:
        json.dump({'manifest': manifest}, f, indent=2)
    with open(os.path.join(out, 'build-report.json'), 'w', newline='\n') as f:
        json.dump(dict(game_root=GAME_ROOT, elapsed_s=round(time.time() - t0, 1),
                       built=len(manifest), skipped=skipped, failures=failures,
                       textures=report), f, indent=2)
    n = sum(1 for r in report if r['status'] == 'replaced')
    print(f'\nbuilt {len(manifest)} bundles, {n} textures replaced, '
          f'{len(skipped)} skipped, {len(failures)} failed in {time.time()-t0:.1f}s')


if __name__ == '__main__':
    main()
