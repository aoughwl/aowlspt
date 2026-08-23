"""Scope the SPT 4.1.2 bundle inventory. (The post-1.0 pipeline is `scope_post1.py`.)

`INV` used to be hardcoded to one dead session's scratchpad directory, which meant
this pipeline could not be re-run by anyone but that session. It now defaults to
`out/inventory.json` beside the repo, overridable with the `TEXPIPE_INV` environment
variable, and `load()` fails with a message that says how to regenerate it rather
than a bare FileNotFoundError from a path nobody recognises.
"""
import json, collections, os, sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_REPO = os.path.dirname(_HERE)

INV = os.environ.get('TEXPIPE_INV', os.path.join(_REPO, 'out', 'inventory.json'))
WJ = os.environ.get(
    'TEXPIPE_WINDOWS_JSON',
    r'D:\SPT\EscapeFromTarkov_Data\StreamingAssets\Windows\Windows.json')
def in_scope(b):
    if b.startswith('assets/content/weapons/'): return False
    return ('/textures/' in b) or ('location_objects' in b) or ('rock and boulders' in b)
def load():
    for path, how in ((INV, 'python inventory.py --out ../out/inventory.json'),
                      (WJ, 'point TEXPIPE_WINDOWS_JSON at an SPT 4.1.2 install')):
        if not os.path.exists(path):
            sys.exit(f'scope.py: missing {path}\n  regenerate with: {how}\n'
                     f'  (override with TEXPIPE_INV / TEXPIPE_WINDOWS_JSON)')
    inv=json.load(open(INV))['textures']
    wj=json.load(open(WJ))
    keys={k.lower():k for k in wj}
    out=[]
    for t in inv:
        b=t['bundle']
        if not in_scope(b): continue
        cand=[b, b+'.bundle'] if not b.endswith('.bundle') else [b]
        key=next((keys[c.lower()] for c in cand if c.lower() in keys), None)
        if key is None: continue
        t=dict(t); t['key']=key
        t['file']=wj[t['key']]['FileName']
        out.append(t)
    return out
if __name__=='__main__':
    o=load()
    print('textures',len(o),'bundles',len({t['key'] for t in o}))
    print(collections.Counter(t['fmt'] for t in o))
    # top-level area
    c=collections.Counter(t['key'].split('/')[2] if t['key'].startswith('assets/content/') else t['key'].split('/')[1] for t in o)
    print(c.most_common(40))
