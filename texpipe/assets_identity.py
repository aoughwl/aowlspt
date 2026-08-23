"""
Job 1.1 -- the identity control for a Unity SerializedFile (`.assets`).

The claim under test is STRONGER than the one we tested for AssetBundles last round.
A `.assets` file is loaded by Unity's own level loader, carries cross-file references
through its externals table, and streams most texture pixels out of a sibling
`.resS`. So before any terrain patch is even designed we ask one question:

    if UnityPy loads a `.assets` and re-serialises it with NOTHING changed,
    do we get the same file back?

Anything short of "yes, byte for byte" is reported as the number it actually is.
A round-trip that merely "looks fine" is exactly the confidently-wrong answer this
project treats as worst-case, so the control also re-loads the output and compares
the object graph: the (PathID, type) set, the externals table, and every texture's
name / dimensions / format / mip count / stream-data pointer.

This tool NEVER writes inside a game directory. It takes an explicit input path
(expected to be a scratch copy) and an explicit output directory.

Usage:
  python assets_identity.py --src <copy of X.assets> --out <scratch dir>
"""
from __future__ import annotations
import argparse, collections, hashlib, io, json, os, shutil, sys, time

import UnityPy


def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()[:16]


def first_diff(a: bytes, b: bytes) -> int:
    n = min(len(a), len(b))
    lo, hi = 0, n
    if a[:n] == b[:n]:
        return n if len(a) != len(b) else -1
    # binary search the first differing byte
    while lo < hi:
        mid = (lo + hi) // 2
        if a[lo:mid + 1] == b[lo:mid + 1]:
            lo = mid + 1
        else:
            hi = mid
    return lo


def describe(path: str) -> dict:
    """Read the object graph we care about, without decoding any pixels."""
    env = UnityPy.load(path)
    objs, texs, errs = [], {}, []
    for o in env.objects:
        objs.append((int(o.path_id), o.type.name))
        if o.type.name != 'Texture2D':
            continue
        try:
            d = o.read()
            sd = getattr(d, 'm_StreamData', None)
            texs[int(o.path_id)] = dict(
                name=str(d.m_Name or ''), w=int(d.m_Width), h=int(d.m_Height),
                fmt=int(d.m_TextureFormat), mips=int(d.m_MipCount or 1),
                idlen=int(len(d.image_data or b'')),
                sd_path=str(getattr(sd, 'path', '') or '') if sd else '',
                sd_off=int(getattr(sd, 'offset', 0) or 0) if sd else 0,
                sd_size=int(getattr(sd, 'size', 0) or 0) if sd else 0,
            )
        except Exception as e:
            errs.append((int(o.path_id), repr(e)[:120]))
    sf = env.file
    ext = []
    for e in (getattr(sf, 'externals', None) or []):
        ext.append(str(getattr(e, 'path', '') or ''))
    return dict(objs=objs, texs=texs, errs=errs, externals=ext,
                version=str(getattr(sf, 'unity_version', '')),
                n_obj=len(objs), n_tex=len(texs))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--src', required=True)
    ap.add_argument('--out', required=True)
    args = ap.parse_args()

    src = os.path.abspath(args.src)
    for bad in ('d:\\aowlspt\\', 'd:/aowlspt/', 'd:\\games\\', 'd:/games/'):
        if bad in (src.lower().replace('\\', '/').replace('/', '/')) or bad in src.lower():
            sys.exit('REFUSING: --src points inside a game install; work on a copy')
    os.makedirs(args.out, exist_ok=True)
    dst = os.path.join(args.out, os.path.basename(src) + '.roundtrip')

    orig = open(src, 'rb').read()
    print(f'src          {src}')
    print(f'             {len(orig):,} bytes  sha={sha(orig)}')

    t0 = time.time()
    before = describe(src)
    print(f'load+describe {time.time()-t0:.1f}s   objects={before["n_obj"]:,} '
          f'Texture2D={before["n_tex"]:,} unity={before["version"]} '
          f'externals={len(before["externals"])} read-errors={len(before["errs"])}')

    # --- the control: change NOTHING, re-serialise -------------------------
    t0 = time.time()
    env = UnityPy.load(src)
    data = env.file.save()
    with open(dst, 'wb') as f:
        f.write(data)
    print(f'save          {time.time()-t0:.1f}s   {len(data):,} bytes  sha={sha(data)}')

    same = (data == orig)
    print()
    print(f'BYTE-IDENTICAL: {same}')
    if not same:
        d = first_diff(orig, data)
        print(f'  size delta   {len(data)-len(orig):+,} bytes')
        print(f'  first diff   at offset {d} (0x{d:x}) of {len(orig)}')
        print(f'  orig[{d}:{d+16}] {orig[d:d+16].hex()}')
        print(f'  new [{d}:{d+16}] {data[d:d+16].hex()}')

    # --- semantic comparison ----------------------------------------------
    # A .resS sibling must be present next to the output or texture reads fail.
    ress = src + '.resS'
    if os.path.exists(ress):
        link = dst + '.resS'
        # UnityPy resolves stream data by the ORIGINAL basename, so name it that way
        want = os.path.join(args.out, os.path.basename(src) + '.resS')
        if not os.path.exists(want):
            shutil.copy2(ress, want)
    # to make basename resolution work, present the roundtrip under the real name
    named = os.path.join(args.out, os.path.basename(src))
    shutil.copy2(dst, named)
    after = describe(named)

    print()
    print(f'objects   before={before["n_obj"]:,} after={after["n_obj"]:,} '
          f'set-equal={set(before["objs"])==set(after["objs"])}')
    print(f'externals equal={before["externals"]==after["externals"]} '
          f'({len(before["externals"])} entries)')
    print(f'read-errors before={len(before["errs"])} after={len(after["errs"])}')

    tb, ta = before['texs'], after['texs']
    missing = set(tb) - set(ta)
    added = set(ta) - set(tb)
    changed = []
    for k in set(tb) & set(ta):
        if tb[k] != ta[k]:
            changed.append((k, tb[k], ta[k]))
    print(f'Texture2D before={len(tb):,} after={len(ta):,} '
          f'missing={len(missing)} added={len(added)} changed={len(changed)}')
    for k, a, b in changed[:5]:
        diffk = [f for f in a if a[f] != b[f]]
        print(f'   pathid {k}: {[(f, a[f], b[f]) for f in diffk]}')

    ok = (same and set(before['objs']) == set(after['objs'])
          and before['externals'] == after['externals']
          and not missing and not added and not changed
          and len(after['errs']) <= len(before['errs']))
    print()
    print('IDENTITY CONTROL:', 'PASS (byte-identical + graph-identical)' if ok
          else 'SEE ABOVE -- not a clean pass')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
