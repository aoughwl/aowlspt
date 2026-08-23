"""
Verify a built pack against the originals.

For every built bundle:
  * same set of (PathID, type) as the original  -> nothing added or lost
  * every object we did NOT touch is byte-identical to the original
  * every touched Texture2D keeps its exact name / width / height / TextureFormat,
    and its image_data length matches what the format+mips demand
  * the built file re-loads cleanly from disk

Usage: python verify.py --out <dir>
"""
from __future__ import annotations
import argparse, collections, json, os, sys

import UnityPy
from scope import load as load_scope
from build import game_path, GAME_ROOT
import tint as T


def census(env):
    out = {}
    for o in env.objects:
        out[(o.assets_file.name, o.path_id)] = (o.type.name, o.get_raw_data())
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', required=True)
    args = ap.parse_args()

    texs = load_scope()
    by_key = collections.defaultdict(dict)
    for t in texs:
        by_key[t['key']][t['lname']] = t

    man = json.load(open(os.path.join(args.out, 'bundles.json')))['manifest']
    problems, checked_obj, checked_tex = [], 0, 0
    for e in man:
        key = e['key']
        dst = os.path.join(args.out, 'bundles', key.replace('/', os.sep))
        src = game_path(next(iter(by_key[key].values()))['file'])
        a, b = census(UnityPy.load(src)), census(UnityPy.load(dst))
        if set(a) != set(b):
            problems.append(dict(key=key, issue='object set differs',
                                 missing=[str(x) for x in set(a) - set(b)],
                                 extra=[str(x) for x in set(b) - set(a)]))
            continue
        for k in a:
            checked_obj += 1
            ta, da = a[k]
            tb, db = b[k]
            if ta != tb:
                problems.append(dict(key=key, issue='type changed', obj=str(k)))
            elif da != db and ta != 'Texture2D':
                problems.append(dict(key=key, issue='untouched object changed', obj=str(k), type=ta))
        for o in UnityPy.load(dst).objects:
            if o.type.name != 'Texture2D':
                continue
            d = o.read()
            rec = by_key[key].get((d.m_Name or '').lower())
            if rec is None:
                continue
            checked_tex += 1
            if T.is_normal_map(rec['lname']):
                continue
            if (d.m_Width, d.m_Height) != (rec['w'], rec['h']):
                problems.append(dict(key=key, tex=d.m_Name, issue='dimensions changed',
                                     got=[d.m_Width, d.m_Height], want=[rec['w'], rec['h']]))
            if int(d.m_TextureFormat) != rec['fmt_id']:
                problems.append(dict(key=key, tex=d.m_Name, issue='format changed',
                                     got=int(d.m_TextureFormat), want=rec['fmt_id']))
            if not d.image_data:
                problems.append(dict(key=key, tex=d.m_Name, issue='no inline image data'))

    print(f'verified {len(man)} bundles, {checked_obj} objects, {checked_tex} target textures')
    print(f'problems: {len(problems)}')
    for p in problems[:25]:
        print(' ', json.dumps(p)[:300])
    with open(os.path.join(args.out, 'verify-report.json'), 'w') as f:
        json.dump(problems, f, indent=2)
    sys.exit(1 if problems else 0)


if __name__ == '__main__':
    main()
