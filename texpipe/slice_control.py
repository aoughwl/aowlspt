"""
CONTROL: is slice N of the MicroSplat array really the layer whose name ends in _N?

The 12 TerrainLayers are named `microsplat_layer_<Surface>_summer_D_<N>`, so the
index looks obvious. "Looks obvious" is how you end up replacing grass with gravel
across a whole map and only finding out when a human loads in.

This decodes slice N mip 0 out of `MicroSplatConfig_summer_diff_tarray` in the
sharedassets17 `.resS`, decodes the standalone `Texture2D` the corresponding
TerrainLayer points at, and reports the mean absolute RGB difference between them.
If the naming convention holds, each slice should match its own layer far better
than it matches any other -- so the check is not just "small diff" but "smallest
diff is on the diagonal", which a coincidence cannot satisfy 12 times.

Read-only.

Usage: python slice_control.py [--dump DIR]
"""
from __future__ import annotations
import argparse, os, sys

import UnityPy
from PIL import Image

import tarray

DATA = 'D:/Aowlspt/EscapeFromTarkov_Data'
ASSETS = os.path.join(DATA, 'sharedassets17.assets')
ARRAY_NAME = 'MicroSplatConfig_summer_diff_tarray'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dump', default='')
    args = ap.parse_args()

    env = UnityPy.load(ASSETS)
    arr = None
    layers = {}
    texs = {}
    for o in env.objects:
        n = o.type.name
        if n == 'Texture2DArray':
            t = o.read_typetree()
            if t.get('m_Name') == ARRAY_NAME:
                arr = t
        elif n == 'TerrainLayer':
            t = o.read_typetree()
            nm = str(t.get('m_Name', ''))
            if nm.startswith('microsplat_layer_'):
                idx = int(nm.rsplit('_', 1)[1])
                d = t.get('m_DiffuseTexture') or {}
                layers[idx] = (nm, int(d.get('m_FileID', 0)), int(d.get('m_PathID', 0)))
        elif n == 'Texture2D':
            texs[int(o.path_id)] = o
    if arr is None:
        sys.exit(f'{ARRAY_NAME} not found')

    sd = arr['m_StreamData']
    w, h, depth, mips = arr['m_Width'], arr['m_Height'], arr['m_Depth'], arr['m_MipCount']
    per = tarray.assert_layout(w, h, mips, depth, arr['m_DataSize'])
    print(f'{ARRAY_NAME}: {w}x{h} depth={depth} mips={mips} '
          f'per-slice={per:,}B  resS={sd["path"]}@{sd["offset"]:,}')

    ress = os.path.join(DATA, sd['path'])
    mip0 = tarray.level_size_dxt5(w, h)
    slices = {}
    with open(ress, 'rb') as f:
        for i in range(depth):
            f.seek(sd['offset'] + i * per)
            slices[i] = tarray.decode_dxt5(f.read(mip0), w, h)

    # the standalone layer albedos
    refs = {}
    for idx, (nm, fid, pid) in sorted(layers.items()):
        if fid != 0 or pid not in texs:
            print(f'  layer {idx} {nm}: diffuse not in this file (fileID={fid}) -- skipped')
            continue
        d = texs[pid].read()
        refs[idx] = (nm, d.image.convert('RGBA'))

    def mad(a, b):
        """Mean absolute RGB difference, pure PIL (this venv has no numpy).

        Compared at a reduced size: the question is 'is this the same surface',
        not 'is this bit-identical', and 12x12 full-resolution comparisons of
        1024x1024 images in pure Python is minutes of pointless work.
        """
        n = 128
        A = a.convert('RGB').resize((n, n), Image.LANCZOS).tobytes()
        B = b.convert('RGB').resize((n, n), Image.LANCZOS).tobytes()
        return sum(abs(x - y) for x, y in zip(A, B)) / len(A)

    idxs = sorted(refs)
    print()
    print('mean-abs RGB diff, array slice (rows) vs TerrainLayer albedo (cols):')
    print('        ' + ''.join(f'{j:>7d}' for j in idxs))
    diag_best = 0
    for i in idxs:
        row = [mad(slices[i], refs[j][1]) for j in idxs]
        best = idxs[row.index(min(row))]
        diag_best += (best == i)
        mark = ' OK' if best == i else f'  <-- best is {best}'
        print(f'  s{i:<3d}  ' + ''.join(f'{v:7.1f}' for v in row) + mark)
    print()
    print(f'slices whose BEST match is their own layer: {diag_best}/{len(idxs)}')
    print('SLICE INDEX MAPPING:',
          'CONFIRMED' if diag_best == len(idxs) else 'NOT confirmed -- do not build')

    if args.dump:
        os.makedirs(args.dump, exist_ok=True)
        for i in idxs:
            slices[i].save(os.path.join(args.dump, f'slice{i:02d}_{refs[i][0]}.png'))
        print('dumped slices to', args.dump)
    return 0 if diag_best == len(idxs) else 1


if __name__ == '__main__':
    sys.exit(main())
