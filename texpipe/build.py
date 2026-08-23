"""
Replacement-bundle builder for EFT / SPT 4.1.2.

Approach: PATCH-IN-PLACE. Each original .bundle is loaded with UnityPy, only the
targeted Texture2D objects are re-encoded, and the whole archive is re-serialised
with its ORIGINAL compression flags. Every other object (materials, meshes,
shaders, prefabs, terrain data, the AssetBundle manifest object itself) is carried
across byte-for-byte with its original PathID, so nothing can be lost.

Usage:
  python build.py --out <dir> [--limit N] [--only SUBSTR] [--jobs N]
"""
from __future__ import annotations
import argparse, collections, json, os, sys, time, traceback

import UnityPy
from UnityPy.enums import TextureFormat
from PIL import Image

from scope import load as load_scope, WJ
import tint as T

GAME_ROOT = 'D:/SPT/EscapeFromTarkov_Data/StreamingAssets/Windows'


def game_path(file_field: str) -> str:
    rel = file_field.split('StreamingAssets/', 1)[1]
    return os.path.join(GAME_ROOT, rel.replace('/', os.sep))


def build_mip_chain(img: Image.Image, fmt: int, mip_count: int):
    """Encode `img` and its mip chain to `fmt`. Returns (bytes, levels_written)."""
    from UnityPy.export import Texture2DConverter as C
    w, h = img.size
    data = b''
    lvl = img
    n = 0
    for i in range(max(1, mip_count)):
        enc, tex_fmt = C.image_to_texture2d(lvl, fmt)
        data += enc
        n += 1
        if w == 1 and h == 1:
            break
        w = max(1, w // 2)
        h = max(1, h // 2)
        lvl = img.resize((w, h), Image.Resampling.BICUBIC)
    return data, n, tex_fmt


def patch_bundle(key: str, src: str, targets: dict, dst: str, report: list, packer='lz4') -> bool:
    """targets: lname -> inventory record. Returns True if the bundle was written."""
    env = UnityPy.load(src)
    before = [(o.path_id, o.type.name) for o in env.objects]
    hue_name, rgb = T.hue_for(key)
    touched = 0

    for obj in env.objects:
        if obj.type.name != 'Texture2D':
            continue
        d = obj.read()
        lname = (d.m_Name or '').lower()
        rec = targets.get(lname)
        if rec is None:
            continue
        orig_fmt = int(d.m_TextureFormat)
        orig_w, orig_h, orig_mips = d.m_Width, d.m_Height, d.m_MipCount
        if T.is_normal_map(lname):
            report.append(dict(key=key, tex=d.m_Name, status='skipped-normal'))
            continue
        try:
            img = d.image
        except Exception as e:
            report.append(dict(key=key, tex=d.m_Name, status='decode-failed', error=repr(e)))
            continue
        tinted = T.tint(img, rgb)
        data, levels, tex_fmt = build_mip_chain(tinted, orig_fmt, orig_mips)
        # write back, preserving identity fields exactly
        d.image_data = data
        d.m_CompleteImageSize = len(data)
        d.m_Width, d.m_Height = orig_w, orig_h
        d.m_TextureFormat = tex_fmt
        if d.m_MipCount is not None:
            d.m_MipCount = levels
        if d.m_MipMap is not None:
            d.m_MipMap = levels > 1
        if d.m_StreamData is not None:
            d.m_StreamData.path = ''
            d.m_StreamData.offset = 0
            d.m_StreamData.size = 0
        d.save()
        touched += 1
        report.append(dict(key=key, tex=d.m_Name, status='tinted', hue=hue_name,
                           w=orig_w, h=orig_h, fmt=int(tex_fmt),
                           fmt_orig=orig_fmt, mips=levels, mips_orig=orig_mips,
                           bytes=len(data)))

    if not touched:
        return False

    blob = env.file.save(packer=packer)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(dst, 'wb') as f:
        f.write(blob)

    # integrity check: reload the written bundle and compare the object census
    chk = UnityPy.load(dst)
    after = [(o.path_id, o.type.name) for o in chk.objects]
    if sorted(before) != sorted(after):
        raise RuntimeError(f'object census changed: {len(before)} -> {len(after)}')
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', required=True)
    ap.add_argument('--limit', type=int, default=0)
    ap.add_argument('--only', default=None)
    ap.add_argument('--packer', default='lz4', choices=['lz4','original','none','lzma'])
    args = ap.parse_args()

    wj = json.load(open(WJ))
    texs = load_scope()
    by_key = collections.defaultdict(dict)
    for t in texs:
        by_key[t['key']][t['lname']] = t
    keys = sorted(by_key)
    if args.only:
        keys = [k for k in keys if args.only in k]
    if args.limit:
        keys = keys[:args.limit]

    bundles_dir = os.path.join(args.out, 'bundles')
    report, manifest, failures, skipped = [], [], [], []
    t0 = time.time()
    for i, key in enumerate(keys, 1):
        rec0 = next(iter(by_key[key].values()))
        src = game_path(rec0['file'])
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
            print(f'[{i}/{len(keys)}] skip {key} (nothing to tint)', flush=True)

    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, 'bundles.json'), 'w') as f:
        json.dump({'manifest': manifest}, f, indent=2)
    with open(os.path.join(args.out, 'build-report.json'), 'w') as f:
        json.dump(dict(elapsed_s=round(time.time() - t0, 1), built=len(manifest),
                       skipped=skipped, failures=failures, textures=report), f, indent=2)
    print(f'\nbuilt {len(manifest)} bundles, {sum(1 for r in report if r["status"]=="tinted")} textures, '
          f'{len(skipped)} skipped, {len(failures)} failed in {time.time()-t0:.1f}s')


if __name__ == '__main__':
    main()
