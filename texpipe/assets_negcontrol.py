"""
Three deliberately-wrong prefab packs the verifier MUST reject.

  copy      blobs are the ORIGINAL bytes, with correct lengths and correct shas.
            Passes checks 1, 2, 3 and 4 perfectly. Must fail check 5.
            This is what a build that silently did nothing looks like, and it is the
            reason checks 1-4 alone are not a result.

  identity  every slot re-encoded from its OWN decoded original through the real
            pipeline. Its RGB difference is pure DXT re-encode loss, which is where
            --rgb-min's floor comes from. Must fail check 5.

  noalpha   the ambientCG source's (opaque) alpha instead of the original's. Every
            alpha-cut card -- fence, grate, foliage -- becomes a solid rectangle.
            Must fail check 6.

A control rejected for the WRONG reason is a passing test hiding a broken check, so
each expected rejection reason is asserted, not just the exit code.

Usage: python assets_negcontrol.py --scratch DIR [--limit 120]
"""
from __future__ import annotations
import argparse, hashlib, json, os, shutil, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
PY = sys.executable
DATA = 'D:/Aowlspt/EscapeFromTarkov_Data'


def run(args):
    return subprocess.run([PY] + args, cwd=HERE, capture_output=True, text=True)


def build(out, worklist, limit, extra=()):
    a = ['assets_build.py', '--worklist', worklist, '--out', out, *extra]
    if limit:
        a += ['--limit', str(limit)]
    r = run(a)
    if r.returncode != 0:
        print(r.stdout[-1500:]); print(r.stderr[-1500:])
        sys.exit(f'build failed: {out}')


def make_copy_pack(src_pack, dst_pack):
    """A pack whose blobs are the original bytes, with truthful lengths and shas."""
    man = json.load(open(os.path.join(src_pack, 'assets-manifest.json')))
    os.makedirs(os.path.join(dst_pack, 'blobs'), exist_ok=True)
    ents = []
    handles = {}
    for e in man['entries']:
        p = os.path.join(DATA, e['res'])
        if p not in handles:
            handles[p] = open(p, 'rb')
        handles[p].seek(e['off'])
        data = handles[p].read(e['size'])
        with open(os.path.join(dst_pack, 'blobs', e['blob']), 'wb') as f:
            f.write(data)
        e = dict(e)
        e['sha'] = hashlib.sha256(data).hexdigest()[:16]
        e['acg'] = '<copy control: the original bytes>'
        ents.append(e)
    for h in handles.values():
        h.close()
    man = dict(man); man['entries'] = ents
    with open(os.path.join(dst_pack, 'assets-manifest.json'), 'w', newline='\n') as f:
        json.dump(man, f)


def verify(pack, rgb_min, alpha_tol):
    r = run(['assets_verify.py', '--pack', pack, '--rgb-min', str(rgb_min),
             '--alpha-tol', str(alpha_tol)])
    return r.returncode, r.stdout


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--scratch', required=True)
    ap.add_argument('--worklist', default='../out/worklist-assets.json')
    ap.add_argument('--limit', type=int, default=120)
    ap.add_argument('--rgb-min', type=float, default=4.0)
    ap.add_argument('--alpha-tol', type=float, default=2.0)
    args = ap.parse_args()
    sc = os.path.abspath(args.scratch)
    os.makedirs(sc, exist_ok=True)

    real = os.path.join(sc, 'nc-real')
    ident = os.path.join(sc, 'nc-identity')
    noal = os.path.join(sc, 'nc-noalpha')
    cp = os.path.join(sc, 'nc-copy')

    print('building real ...');      build(real, args.worklist, args.limit)
    print('building identity ...');  build(ident, args.worklist, args.limit, ('--identity',))
    print('building noalpha ...');   build(noal, args.worklist, args.limit, ('--no-alpha',))
    print('building copy ...');      make_copy_pack(real, cp)
    print()

    results = []
    for label, pack, want_reject, reason in (
            ('real',     real,  False, None),
            ('copy',     cp,    True,  'did not change enough'),
            ('identity', ident, True,  'did not change enough'),
            ('noalpha',  noal,  True,  'lost their alpha channel')):
        rc, out = verify(pack, args.rgb_min, args.alpha_tol)
        rejected = rc != 0
        reason_ok = reason is None or reason in out
        ok = (rejected == want_reject) and reason_ok
        results.append(ok)
        print(f'[{label:9s}] {"REJECTED" if rejected else "ACCEPTED"}  '
              f'expected {"REJECT" if want_reject else "ACCEPT"}  '
              f'{"OK" if ok else "*** WRONG ***"}')
        for l in out.splitlines():
            s = l.strip()
            if s.startswith('-') or s.startswith('[5]') or s.startswith('[6]'):
                print(f'              {s}')
        if not reason_ok:
            print(f'              expected reason missing: {reason!r}')
    print()
    print(f'controls behaving correctly: {sum(results)}/{len(results)}')
    return 0 if all(results) else 1


if __name__ == '__main__':
    sys.exit(main())
