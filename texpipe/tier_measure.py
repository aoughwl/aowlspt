"""
Does the ambientCG SOURCE resolution actually change the result in a fixed slot?

Job 3 asks for 1K / 2K / 4K tiers. But every slot this pipeline writes has its size
fixed by the original texture -- an in-place `.resS` patch must produce exactly the
same byte count, so a 4K source into a 1024 slot IS a 1024 texture. The only thing
the source tier can change is how that 1024 was filtered down.

Rather than assert that is negligible (or that it matters), this measures it: encode
the same ambientCG set into the same slot from each source tier and compare the
decoded results pairwise. If 1K and 4K land within DXT5 re-encode noise of each
other, shipping three separate multi-hundred-MB packs that differ only in source
tier would be selling the user three copies of the same thing.

The identity control's ceiling (2.6 mean-abs RGB, measured by
`terrain_build.py --identity`) is the noise floor to compare against.

Usage: python tier_measure.py [--sets Grass003,Concrete041A,...] [--slot 1024]
"""
from __future__ import annotations
import argparse, os, sys

from PIL import Image

import tarray
from terrain_build import ACG_ROOT, acg_catalogue, color_path

IDENTITY_CEILING = 2.6   # measured: terrain_build.py --identity, summer, 36 slices


def mad(a: Image.Image, b: Image.Image, n: int = 256) -> float:
    A = a.convert('RGB').resize((n, n), Image.LANCZOS).tobytes()
    B = b.convert('RGB').resize((n, n), Image.LANCZOS).tobytes()
    return sum(abs(x - y) for x, y in zip(A, B)) / len(A)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--sets', default='Grass003,Concrete041A,Asphalt016,Ground109,Rock058')
    ap.add_argument('--slot', type=int, default=1024)
    args = ap.parse_args()

    cat = acg_catalogue()
    slot = args.slot
    mips = slot.bit_length()          # 1024 -> 11 levels, matching the game's arrays
    print(f'slot {slot}x{slot}, {mips} mips, DXT5; identity-control noise floor '
          f'{IDENTITY_CEILING}')
    print()
    rows = []
    for name in [s.strip() for s in args.sets.split(',') if s.strip()]:
        if name not in cat:
            print(f'  {name}: not in the library -- skipped')
            continue
        imgs = {}
        for res in ('1K', '2K', '4K'):
            if res not in cat[name]:
                continue
            src = Image.open(color_path(cat, name, res))
            data = tarray.build_chain(src, slot, slot, mips)
            imgs[res] = tarray.decode_dxt5(data[:tarray.level_size_dxt5(slot, slot)],
                                           slot, slot)
        if len(imgs) < 2:
            continue
        d12 = mad(imgs['1K'], imgs['2K']) if '2K' in imgs else float('nan')
        d14 = mad(imgs['1K'], imgs['4K']) if '4K' in imgs else float('nan')
        d24 = (mad(imgs['2K'], imgs['4K'])
               if '2K' in imgs and '4K' in imgs else float('nan'))
        rows.append((name, d12, d14, d24))
        print(f'  {name:16s} 1K-vs-2K {d12:6.2f}   1K-vs-4K {d14:6.2f}   '
              f'2K-vs-4K {d24:6.2f}')

    if not rows:
        sys.exit('nothing measured')
    worst = max(max(r[1], r[2], r[3]) for r in rows)
    print()
    print(f'largest source-tier difference in a fixed {slot} slot: {worst:.2f}')
    print(f'identity-control noise floor:                         {IDENTITY_CEILING:.2f}')
    if worst <= IDENTITY_CEILING:
        print('=> source tier is WITHIN re-encode noise for this slot. Shipping '
              'separate 1K/2K/4K packs would ship the same pack three times.')
    else:
        print('=> source tier is measurably above the noise floor; separate packs '
              'are defensible for this slot size.')


if __name__ == '__main__':
    main()
