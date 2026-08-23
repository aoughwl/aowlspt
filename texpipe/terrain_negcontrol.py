"""
Three deliberately-wrong terrain packs the verifier MUST reject.

A verifier nobody has ever seen say "no" is not a verifier. Each control here breaks
exactly one thing, and the run is only a success if each is rejected FOR ITS OWN
REASON -- a control rejected for the wrong reason is a passing test hiding a broken
check.

  copy      the pack .resS is the game's, unmodified, with a truthful manifest.
            Passes checks 1, 2, 3, 5 and 6 perfectly. Must fail check 4.
            This is the control that matters: it is what a build that silently did
            nothing looks like.

  identity  every slice re-encoded from its OWN decoded original through the real
            pipeline. Measures pure DXT5 re-encode loss, which is where --rgb-min's
            floor comes from. Must fail check 4.

  normsao   the same pack, but the normal/smoothness/AO arrays were written too.
            Must fail check 5.

Usage: python terrain_negcontrol.py --scratch DIR [--seasons summer]
"""
from __future__ import annotations
import argparse, json, os, shutil, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
PY = sys.executable
DATA = 'D:/Aowlspt/EscapeFromTarkov_Data'
RESS_NAME = 'sharedassets17.assets.resS'


def run(args, **kw):
    return subprocess.run([PY] + args, cwd=HERE, capture_output=True, text=True, **kw)


def build(out, seasons, extra=()):
    r = run(['terrain_build.py', '--out', out, '--seasons', seasons, *extra])
    if r.returncode != 0:
        print(r.stdout[-2000:]); print(r.stderr[-2000:])
        sys.exit(f'build failed for {out}')
    return r


def verify(pack, rgb_min):
    r = run(['terrain_verify.py', '--pack', pack, '--rgb-min', str(rgb_min)])
    return r.returncode, r.stdout


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--scratch', required=True)
    ap.add_argument('--seasons', default='summer')
    ap.add_argument('--rgb-min', type=float, default=5.0)
    args = ap.parse_args()
    sc = os.path.abspath(args.scratch)
    os.makedirs(sc, exist_ok=True)

    real = os.path.join(sc, 'nc-real')
    ident = os.path.join(sc, 'nc-identity')
    norm = os.path.join(sc, 'nc-normsao')
    copyp = os.path.join(sc, 'nc-copy')

    print('building the REAL pack (must be accepted) ...')
    build(real, args.seasons)
    print('building the IDENTITY control ...')
    build(ident, args.seasons, ('--identity',))
    print('building the NORMSAO control ...')
    build(norm, args.seasons, ('--touch-normsao',))

    print('building the COPY control ...')
    os.makedirs(copyp, exist_ok=True)
    shutil.copy2(os.path.join(DATA, RESS_NAME), os.path.join(copyp, RESS_NAME))
    # a truthful manifest: it claims exactly the ranges the real pack claims
    shutil.copy2(os.path.join(real, 'terrain-manifest.json'),
                 os.path.join(copyp, 'terrain-manifest.json'))

    print()
    results = []
    for label, pack, want_reject, want_reason in (
            ('real',     real,  False, None),
            ('copy',     copyp, True,  'did not change enough'),
            ('identity', ident, True,  'did not change enough'),
            ('normsao',  norm,  True,  'normSAO data maps were modified')):
        rc, out = verify(pack, args.rgb_min)
        rejected = rc != 0
        reason_ok = (want_reason is None) or (want_reason in out)
        ok = (rejected == want_reject) and reason_ok
        results.append((label, ok, rejected, reason_ok))
        tail = [l for l in out.splitlines() if l.strip().startswith('-')]
        print(f'[{label:9s}] {"REJECTED" if rejected else "ACCEPTED"}  '
              f'expected {"REJECT" if want_reject else "ACCEPT"}  '
              f'{"OK" if ok else "*** WRONG ***"}')
        for l in tail[:4]:
            print(f'              {l.strip()}')
        if not reason_ok:
            print(f'              expected reason not found: {want_reason!r}')

    print()
    bad = [r for r in results if not r[1]]
    print(f'controls behaving correctly: {len(results)-len(bad)}/{len(results)}')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
