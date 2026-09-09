#!/usr/bin/env python3
"""makedds.py -- generate a DXT1/DXT5 DDS with a full mip chain, without any
image library. Pure stdlib, runs under any Python 3.

Two modes, and both exist for the live test described in the README:

  --solid R,G,B   every block is that colour, alpha 255. Use magenta for the
                  "did my write land" probe.
  --noise SEED    deterministic pseudo-random block bytes. Same LENGTH as a
                  valid image, but the decoded result is garbage. This is the
                  NEGATIVE CONTROL: if the screen looks unchanged after writing
                  it, the game is not reading your bytes (fact #50), and a
                  magenta wall that "did not appear" proves nothing on its own.

    python makedds.py --w 1024 --h 1024 --format dxt5 --solid 255,0,255 -o m.dds
    python makedds.py --w 1024 --h 1024 --format dxt5 --noise 1 -o garbage.dds
"""

import argparse
import random
import struct
import sys

BLOCK = {"dxt1": (8, b"DXT1"), "dxt5": (16, b"DXT5")}


def rgb565(r, g, b):
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)


def solid_block(fmt, r, g, b):
    c = struct.pack("<HH", rgb565(r, g, b), rgb565(r, g, b)) + b"\x00\x00\x00\x00"
    if fmt == "dxt1":
        return c
    return b"\xff\xff" + b"\x00" * 6 + c   # alpha0=alpha1=255, all indices 0


def dds_header(w, h, mips, fmt):
    bpb, fourcc = BLOCK[fmt]
    linear = max(1, (w + 3) // 4) * max(1, (h + 3) // 4) * bpb
    flags = 0x1 | 0x2 | 0x4 | 0x1000 | 0x80000 | (0x20000 if mips > 1 else 0)
    caps = 0x1000 | ((0x8 | 0x400000) if mips > 1 else 0)
    # size, flags, height, width, pitchOrLinearSize, depth, mipMapCount,
    # reserved1[11], then DDS_PIXELFORMAT, then caps[4] + reserved2.
    hdr = (b"DDS " + struct.pack("<IIIIIII", 124, flags, h, w, linear, 0, mips)
           + b"\x00" * 44
           + struct.pack("<II", 32, 0x4) + fourcc + struct.pack("<IIIII", 0, 0, 0, 0, 0)
           + struct.pack("<IIIII", caps, 0, 0, 0, 0))
    assert len(hdr) == 128, len(hdr)
    return hdr


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--w", type=int, required=True)
    p.add_argument("--h", type=int, required=True)
    p.add_argument("--mips", type=int, default=0, help="0 = full chain")
    p.add_argument("--format", choices=sorted(BLOCK), default="dxt5")
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--solid", help="R,G,B")
    g.add_argument("--noise", type=int, metavar="SEED")
    p.add_argument("--truncate-blocks", type=int, default=0,
                   help="drop N blocks from the tail -- for testing that a "
                        "wrong-length input is REFUSED")
    p.add_argument("-o", "--out", required=True)
    a = p.parse_args(argv)

    mips = a.mips
    if mips <= 0:
        mips = 1
        w, h = a.w, a.h
        while w > 1 or h > 1:
            w, h = max(1, w >> 1), max(1, h >> 1)
            mips += 1

    bpb, _ = BLOCK[a.format]
    blocks = 0
    for i in range(mips):
        lw, lh = max(1, a.w >> i), max(1, a.h >> i)
        blocks += ((lw + 3) // 4) * ((lh + 3) // 4)
    blocks -= a.truncate_blocks

    if a.solid:
        r, g_, b = (int(x) for x in a.solid.split(","))
        payload = solid_block(a.format, r, g_, b) * blocks
    else:
        rnd = random.Random(a.noise)
        payload = bytes(rnd.randrange(256) for _ in range(blocks * bpb))

    with open(a.out, "wb") as fh:
        fh.write(dds_header(a.w, a.h, mips, a.format))
        fh.write(payload)
    print("wrote %s: %s %dx%d mip%d, %d payload bytes"
          % (a.out, a.format.upper(), a.w, a.h, mips, len(payload)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
