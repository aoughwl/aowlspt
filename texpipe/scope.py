import json, collections, os, sys
INV=r'C:\Users\savant\AppData\Local\Temp\claude\C--Users-savant-Projects\db70f9b8-6156-4536-ab1f-ffe40cf18538\scratchpad\texture-inventory\inventory.json'
WJ=r'D:\SPT\EscapeFromTarkov_Data\StreamingAssets\Windows\Windows.json'
def in_scope(b):
    if b.startswith('assets/content/weapons/'): return False
    return ('/textures/' in b) or ('location_objects' in b) or ('rock and boulders' in b)
def load():
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
