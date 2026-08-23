"""
Negative controls for verify_post1.py.

A verifier that passes on everything is worse than no verifier, so two deliberately bad
packs are built and the verifier must reject BOTH, each for its own stated reason:

  copy     the ORIGINAL bundles, copied unmodified. In these bundles the target pixels
           are STREAMED from a .resS, so image_data is empty and check 4 ("pixels are
           inline") fires on every texture. Measured: 123/123.

  identity the pipeline run end to end, but writing the ORIGINAL image back instead of
           the ambientCG one. Everything structural is correct and inline, so checks 1-4
           pass; check 5 ("RGB actually changed") is the only thing standing between a
           real replacement and a very expensive no-op, and it must fire on every row.
           This is the control that matters.

  opaque   the pipeline run end to end, but taking the ambientCG map's OPAQUE alpha
           instead of the original's cutout mask. This is the exact failure that would
           turn every grass billboard into a solid rectangle, and it is structurally
           perfect, so only check 6 can catch it. It must fire on every row.

Thresholds are set from measurement, not taste: the identity control's RGB mean-abs-diff
tops out at 4.9 (that is pure DXT5 re-encode loss) and the real pack's floor is 24.6, so
--rgb-min sits at 12.0, in the gap.

Usage: python negcontrol_post1.py [--mode all|copy|identity|opaque]
"""
from __future__ import annotations
import argparse, collections, json, os, shutil, subprocess, sys

import UnityPy
from inventory import game_path, WJ
import build_post1 as B


def run_verifier(out):
    r = subprocess.run([sys.executable, 'verify_post1.py', '--out', out],
                       capture_output=True, text=True)
    probs = json.load(open(os.path.join(out, 'verify-report.json')))
    return r.returncode, probs


def control_copy(man, wj, out):
    if os.path.isdir(out):
        shutil.rmtree(out)
    for e in man:
        dst = os.path.join(out, 'bundles', e['key'].replace('/', os.sep))
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copyfile(game_path(wj[e['key']]['FileName']), dst)
    with open(os.path.join(out, 'bundles.json'), 'w', newline='\n') as f:
        json.dump({'manifest': man}, f, indent=2)


def control_composed(man, wj, out, worklist, fake_compose):
    """Same pipeline, but with compose() swapped for a deliberately broken one."""
    if os.path.isdir(out):
        shutil.rmtree(out)
    work = json.load(open(worklist))['work']
    by_key = collections.defaultdict(dict)
    for t in work:
        by_key[t['key']][t['lname']] = t
    orig_compose = B.compose
    B.compose = fake_compose
    try:
        report = []
        for e in man:
            key = e['key']
            dst = os.path.join(out, 'bundles', key.replace('/', os.sep))
            B.patch_bundle(key, game_path(wj[key]['FileName']), by_key[key], dst, report)
    finally:
        B.compose = orig_compose
    with open(os.path.join(out, 'bundles.json'), 'w', newline='\n') as f:
        json.dump({'manifest': man}, f, indent=2)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--pack', default='../out/post1-pack')
    ap.add_argument('--worklist', default='../out/worklist-post1.json')
    ap.add_argument('--mode', default='all',
                    choices=['all', 'copy', 'identity', 'opaque'])
    args = ap.parse_args()

    wj = json.load(open(WJ))
    man = json.load(open(os.path.join(args.pack, 'bundles.json')))['manifest']
    bad = False

    if args.mode in ('all', 'copy'):
        out = '../out/post1-neg-copy'
        control_copy(man, wj, out)
        rc, probs = run_verifier(out)
        hit = [p for p in probs if p.get('issue') == 'no inline image data']
        print(f'[copy]     rc={rc} problems={len(probs)} '
              f'"no inline image data"={len(hit)}/{len(man)}')
        if rc == 0:
            print('  FAIL: the verifier PASSED an unmodified pack.'); bad = True
        elif len(hit) != len(man):
            print('  FAIL: expected that check to fire on every texture.'); bad = True
        else:
            print('  OK')

    def check(label, out, compose_fn, want_issue, human):
        nonlocal bad
        control_composed(man, wj, out, args.worklist, compose_fn)
        rc, probs = run_verifier(out)
        hit = [p for p in probs if want_issue in p.get('issue', '')]
        other = [p for p in probs if want_issue not in p.get('issue', '')]
        print(f'[{label}] rc={rc} problems={len(probs)} '
              f'"{human}"={len(hit)}/{len(man)}, other={len(other)}')
        if rc == 0:
            print(f'  FAIL: the verifier PASSED a pack that was deliberately broken. '
                  f'It is vacuous for {label}.')
            bad = True
        elif len(hit) != len(man):
            print(f'  FAIL: that check fired on only {len(hit)} of {len(man)}.')
            for p in other[:5]:
                print('   other:', json.dumps(p)[:200])
            bad = True
        else:
            print('  OK: only the intended check fired, and it fired on every texture.')

    if args.mode in ('all', 'identity'):
        check('identity', '../out/post1-neg-identity',
              lambda original, src_path, keep_alpha: original.convert('RGBA'),
              'no-op', 'RGB did not change')

    if args.mode in ('all', 'opaque'):
        check('opaque', '../out/post1-neg-opaque',
              # capture the REAL compose now; control_composed rebinds B.compose, so
              # calling B.compose from inside the lambda would recurse forever.
              (lambda real: (lambda original, src_path, keep_alpha:
                             real(original, src_path, False)))(B.compose),
              'alpha (cutout mask) not preserved', 'alpha not preserved')

    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
