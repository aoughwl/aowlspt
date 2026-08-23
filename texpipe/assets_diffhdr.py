"""
Explain a NON-byte-identical `.assets` round-trip.

`assets_identity.py` found sharedassets165 round-trips 4 bytes LARGER with an
identical object graph. "Identical graph, 4 bytes bigger" is precisely the shape of
answer that is comfortable to wave through, so this decodes the SerializedFile header
of both files and locates every differing byte range, rather than assuming the delta
is harmless padding.

SerializedFile header, Unity >= 2020 (version 22):
    u32 be  metadata_size_legacy (0)
    u32 be  file_size_legacy     (0)
    u32 be  version              (22)
    u32 be  data_offset_legacy   (0)
    u8      endianness
    u8[3]   reserved
    u32 be  metadata_size
    u64 be  file_size
    u64 be  data_offset
    u64 be  unknown

Usage: python assets_diffhdr.py A B
"""
from __future__ import annotations
import struct, sys


def hdr(b: bytes) -> dict:
    ml, fl, ver, dol = struct.unpack('>IIII', b[0:16])
    endian = b[16]
    meta, = struct.unpack('>I', b[20:24])
    fsize, doff, unk = struct.unpack('>QQQ', b[24:48])
    return dict(version=ver, endian=endian, metadata_size=meta,
                file_size=fsize, data_offset=doff, unknown=unk,
                legacy=(ml, fl, dol))


def ranges(a: bytes, b: bytes, limit=20, chunk=1 << 16):
    """Coalesced differing byte ranges over the common prefix length.

    The first version of this skipped ahead in 64K chunks and advanced `i` past the
    end of a chunk that was NOT equal, so it walked straight over real differences
    and printed "no differing ranges" for two files that differed. It reported a
    clean result for a comparison that had compared nothing -- the exact failure
    this repo treats as worst-case. It is now a plain scan over chunks that are
    known-equal, and byte-wise everywhere else, with no branch that can advance
    across an unexamined region.
    """
    n = min(len(a), len(b))
    out, i = [], 0
    while i < n and len(out) < limit:
        end = min(i + chunk, n)
        if a[i:end] == b[i:end]:
            i = end
            continue
        # this chunk differs somewhere: resolve it byte-wise
        while i < end and len(out) < limit:
            if a[i] == b[i]:
                i += 1
                continue
            j = i
            while j < n and a[j] != b[j]:
                j += 1
            out.append((i, j))
            i = j
    return out


def main():
    a = open(sys.argv[1], 'rb').read()
    b = open(sys.argv[2], 'rb').read()
    ha, hb = hdr(a), hdr(b)
    print(f'A {len(a):,}  B {len(b):,}   delta {len(b)-len(a):+,}')
    for k in ha:
        mark = '   ' if ha[k] == hb[k] else '  <<'
        print(f'  {k:16s} A={ha[k]!r:24s} B={hb[k]!r:24s}{mark}')

    print()
    print('metadata region  A[48:%d]  B[48:%d]  equal=%s'
          % (48 + ha['metadata_size'], 48 + hb['metadata_size'],
             a[48:48 + ha['metadata_size']] == b[48:48 + hb['metadata_size']]))
    pa = a[48 + ha['metadata_size']:ha['data_offset']]
    pb = b[48 + hb['metadata_size']:hb['data_offset']]
    print(f'pad before data  A={len(pa)} bytes {pa[:16].hex()}  '
          f'B={len(pb)} bytes {pb[:16].hex()}')
    da = a[ha['data_offset']:]
    db = b[hb['data_offset']:]
    print(f'data region      A={len(da):,}  B={len(db):,}  equal={da==db}')
    if da != db:
        print('  differing ranges inside data (relative to data_offset):')
        for s, e in ranges(da, db):
            print(f'    [{s}..{e}) {e-s} bytes  A={da[s:min(e,s+12)].hex()} '
                  f'B={db[s:min(e,s+12)].hex()}')


if __name__ == '__main__':
    main()
