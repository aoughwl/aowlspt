"""
Per-object raw-byte comparison of two `.assets` files.

`assets_identity.py` showed sharedassets161 does NOT round-trip byte-identically:
UnityPy moves the first object (a 48-byte `LightManager`) to the end of the data
section and decrements every other object's `byte_start` by 48. The object graph and
all 668 Texture2D headers survive, so it *looks* self-consistent.

"Looks self-consistent" is not a measurement. This reads the ObjectInfo table out of
both files directly and compares each object's RAW BYTES at its own recorded
(byte_start, byte_size). If UnityPy had updated an offset wrongly -- or updated the
table but not the payload -- objects would decode as garbage while the header-level
comparison still reported a clean pass. That is the failure mode being excluded here.

Only the ObjectInfo table is parsed by hand; everything else is left alone.

Usage: python assets_objbytes.py A B
"""
from __future__ import annotations
import struct, sys, collections


def read_header(b: bytes):
    ver, = struct.unpack('>I', b[8:12])
    if ver != 22:
        raise SystemExit(f'unsupported SerializedFile version {ver}')
    meta, = struct.unpack('>I', b[20:24])
    fsize, doff, _ = struct.unpack('>QQQ', b[24:48])
    endian = b[16]
    return dict(version=ver, metadata_size=meta, file_size=fsize,
                data_offset=doff, endian=endian)


def read_objects(b: bytes):
    """Walk the metadata far enough to reach the ObjectInfo array.

    Layout after the 48-byte header, little-endian for endian==0:
        cstr    unity version
        i32     target platform
        u8      has type tree
        i32     type count
        <types>            -- variable, so we do NOT parse it; see below
        i32     object count
        <objects>          -- aligned to 4, 24 bytes each

    Parsing the type tree properly is a lot of surface area for a check whose only
    job is to locate a table. Instead the array is LOCATED by search: for every
    4-aligned candidate offset we test whether reading it as (count, count*24 bytes)
    yields entries whose byte_start/byte_size all land inside the data section and do
    not overlap. A wrong guess essentially cannot satisfy that for thousands of
    entries. The candidate is rejected loudly if none validates.
    """
    h = read_header(b)
    meta_end = 48 + h['metadata_size']
    data_len = len(b) - h['data_offset']
    best = None
    off = 48
    while off + 4 <= meta_end:
        n, = struct.unpack('<i', b[off:off + 4])
        if 1 <= n <= 2_000_000 and off + 4 + n * 24 <= meta_end:
            ok, ents, seen = True, [], []
            for i in range(n):
                p = off + 4 + i * 24
                pid, start, size, tid = struct.unpack('<qQII', b[p:p + 24])
                if size == 0 or start + size > data_len or start > data_len:
                    ok = False
                    break
                ents.append((pid, start, size, tid))
            if ok and n >= 2:
                # entries should be ascending by byte_start and non-overlapping
                s = sorted(ents, key=lambda e: e[1])
                for x, y in zip(s, s[1:]):
                    if x[1] + x[2] > y[1]:
                        ok = False
                        break
                if ok and (best is None or n > best[0]):
                    best = (n, off, ents)
        off += 4
    if best is None:
        raise SystemExit('could not locate the ObjectInfo table')
    return h, best[2]


def main():
    pa, pb = sys.argv[1], sys.argv[2]
    a = open(pa, 'rb').read()
    b = open(pb, 'rb').read()
    ha, ea = read_objects(a)
    hb, eb = read_objects(b)
    print(f'A objects {len(ea):,}   B objects {len(eb):,}')
    da, db = ha['data_offset'], hb['data_offset']

    ma = {e[0]: e for e in ea}
    mb = {e[0]: e for e in eb}
    only_a = set(ma) - set(mb)
    only_b = set(mb) - set(ma)
    print(f'path_ids only in A: {len(only_a)}   only in B: {len(only_b)}')

    same, diff, moved, sizediff = 0, [], 0, []
    for pid in set(ma) & set(mb):
        _, sa, za, ta = ma[pid]
        _, sb, zb, tb = mb[pid]
        if za != zb:
            sizediff.append((pid, za, zb))
            continue
        if sa != sb:
            moved += 1
        if a[da + sa:da + sa + za] == b[db + sb:db + sb + zb]:
            same += 1
        else:
            diff.append(pid)

    print(f'byte_size differs : {len(sizediff)}')
    print(f'relocated (offset changed, payload compared anyway): {moved:,}')
    print(f'payload IDENTICAL : {same:,}')
    print(f'payload DIFFERENT : {len(diff):,}')
    for pid in diff[:10]:
        _, sa, za, _ = ma[pid]
        _, sb, zb, _ = mb[pid]
        print(f'   pathid {pid} A@{sa}+{za} B@{sb}+{zb}')
        print(f'      A {a[da+sa:da+sa+min(za,24)].hex()}')
        print(f'      B {b[db+sb:db+sb+min(zb,24)].hex()}')

    ok = not only_a and not only_b and not sizediff and not diff
    print()
    print('PER-OBJECT PAYLOAD:', 'ALL IDENTICAL (re-serialise is content-preserving)'
          if ok else 'NOT identical -- see above')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
