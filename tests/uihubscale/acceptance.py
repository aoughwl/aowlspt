"""Acceptance for the settings surface at scale -- ROUTES and PAYLOADS.

Runs against a standalone backend; no game client, no TLS, no cert:

    aowl build backend
    aowl build-mod mods/uihub
    aowl build-mod tests/uihubscale
    # copy backend/bin/aowlspt-backend.exe, mods/uihub/bin/uihub.dll,
    # mods/settingshub/bin/settingshub.dll and tests/uihubscale/bin/uihubscale.dll
    # (each into <root>/mods/<name>/) into a SCRATCH root, with a
    # mods/aowlspt-selection.json naming aowl.uihub, aowl.settingshub,
    # aowl.uihubscale -- never against D:/Aowlspt while anyone may be playing
    aowlspt-backend.exe --root <scratch> --port 18443
    python tests/uihubscale/acceptance.py

Every response is parsed with json.loads -- never a substring `contains`,
which is the false positive CLAUDE.md 9b names. Companions:
`acceptance-lib.js` (the served library's pure functions, node) and
`acceptance-dom.js` (the whole page in jsdom -- run it from a directory
where `npm i jsdom` has been done, since node resolves from the script's own
directory; both node scripts read `served-lib.js`, written by this one).
"""
import json, urllib.request, sys

B = 'http://127.0.0.1:18443'
def req(path, body=None):
    d = None if body is None else json.dumps(body).encode()
    r = urllib.request.Request(B+path, data=d, method='POST' if d else 'GET',
                               headers={'Accept-Encoding':'identity',
                                        'Content-Type':'application/json'})
    with urllib.request.urlopen(r, timeout=20) as f:
        return f.status, f.headers.get('Content-Type'), f.read()

fails = []
def check(name, cond, detail=''):
    print(('PASS ' if cond else 'FAIL ') + name + (' :: '+str(detail) if detail else ''))
    if not cond: fails.append(name)

# 1. page + library routes
st, ct, page = req('/aowlspt/ui/page/settings')
check('page 200 text/html', st==200 and 'text/html' in ct, ct)
check('page has NO inline settings logic, only the lib tag',
      b'/aowlspt/ui/lib/settings.js' in page and b'function controlFor' not in page)
st, ct, lib = req('/aowlspt/ui/lib/settings.js?ident=1')
check('lib 200 javascript', st==200 and 'javascript' in ct, ct)
open('served-lib.js','wb').write(lib)
check('lib carries the public surface', b'global.AowlSettings' in lib and b'function mount' in lib)

# 2. index + schema strictly parse
st, ct, raw = req('/aowlspt/settings/index?ident=1')
idx = json.loads(raw)                      # strict parse, not `contains`
mods = idx['mods']
check('index parses and names the fixture', any(m['guid']=='aowl.uihubscale' for m in mods), [m['guid'] for m in mods])
st, ct, raw = req('/aowlspt/settings/aowl.uihubscale?ident=1')
rows = json.loads(raw)
check('schema parses strictly, 278 rows', isinstance(rows, list) and len(rows)==278, len(rows))
byk = {r['key']: r for r in rows}

# 2b. ARBITRARY-DEPTH GROUPING, on the finished payload.
#
# The assertions below are about the SERVED document, not about the builder
# that produced it: every one of them can be falsified by a payload that
# parses. `path` is the ordered group path; `category`/`subcategory` are still
# there verbatim, so a renderer that never heard of `path` is unaffected.
deep = byk['deepRegen0']
check('a row carries an ordered `path` to arbitrary depth',
      deep.get('path') == ['Deep','Player','Health','Regeneration'], deep.get('path'))
check('`category` and `subcategory` are still emitted verbatim beside it',
      deep.get('category') == 'Deep/Player/Health/Regeneration', deep.get('category'))
bleed = byk['deepBleed0']
check('a path spanning BOTH fields concatenates in declaration order',
      bleed.get('path') == ['Deep','Player','Health','Damage','Bleeding'], bleed.get('path'))
stray = byk['deepStray']
check('stray separators collapse -- NO empty segment ever reaches the UI',
      stray.get('path') == ['Deep','Player','Movement'], stray.get('path'))
# The negative, over the WHOLE document: not one row anywhere may carry a
# nameless group. This is the property "no group renders without a title"
# reduced to the payload, and it fails the moment any segment is blank.
nameless = [r['key'] for r in rows
            if any((not seg) or not seg.strip() for seg in r.get('path', []))]
check('NO row anywhere carries an empty path segment', nameless == [], nameless)
# ...and every path is a proper tree: each row's parent prefix is reachable.
paths = {tuple(r['path']) for r in rows if r.get('path')}
orphans = sorted({'/'.join(p) for p in paths
                  for i in range(1, len(p))
                  if tuple(p[:i]) not in paths
                  and not any(q[:i] == p[:i] for q in paths)})
check('every group path prefix is itself a group somebody can walk through',
      orphans == [], orphans)
# A row with no grouping at all must still be representable -- and must NOT
# invent an empty path.
check('an ungrouped row omits `path` rather than sending an empty one',
      all(r.get('path') != [] for r in rows))

# 3. the NEW schema fields, on the finished payload
sel = byk['itemInline']
check('itemInline is type select with 900 inline options',
      sel['type']=='select' and len(sel['options'])==900)
check('optionLabels is parallel and present',
      len(sel.get('optionLabels',[]))==900 and sel['optionLabels'][0]!=sel['options'][0])
rem = byk['itemRemote']
check('itemRemote declares optionsUrl and ships no options',
      rem.get('optionsUrl')=='/aowlspt/settings/aowl.uihubscale/items' and not rem.get('options'))
check('subcategory reaches the wire', rem.get('subcategory')=='Core' and rem.get('category')=='Loot')
cats = sorted({r.get('category','') for r in rows})
subs = sorted({r.get('subcategory','') for r in rows})
check('8 categories x 3 subcategories', len(cats)==8 and len(subs)==3, (cats, subs))

# 4. NOTHING regressed: every pre-existing key of an old-shape row is unchanged
old = byk['k3']
check('int row keeps min/max/step and no new keys leak in',
      old['type']=='int' and old['min']==0 and old['max']==100 and old['step']==1
      and 'optionsUrl' not in old and 'optionLabels' not in old, sorted(old.keys()))
check('a row with no subcategory omits the field entirely',
      all(('subcategory' in r) == bool(r.get('subcategory')) for r in rows))

# 5. the optionsUrl contract, as a third party would call it
st, ct, raw = req('/aowlspt/settings/aowl.uihubscale/items?q=helmet&limit=25&ident=1')
res = json.loads(raw)
opts = res['options']
check('options route: capped at limit, reports full match count',
      len(opts)==25 and res['matched']>25, (len(opts), res['matched']))
check('options route: every hit really matches the term',
      all('helmet' in o['label'].lower() or 'helmet' in o['value'].lower() for o in opts))
st, ct, raw = req('/aowlspt/settings/aowl.uihubscale/items?q=zzzznotathing&limit=25&ident=1')
check('options route: a term that matches nothing returns an EMPTY list, not everything',
      json.loads(raw)['matched']==0)

# 6. write + reset round trip, asserted on the RE-READ state
st, ct, raw = req('/aowlspt/settings/aowl.uihubscale?ident=1', {'key':'k3','value':42})
reply = json.loads(raw)
check('POST reply is the bare array (persisted)', isinstance(reply, list))
after = {r['key']: r for r in json.loads(req('/aowlspt/settings/aowl.uihubscale?ident=1')[2])}
check('re-read shows 42, not the old value', after['k3']['value']==42, after['k3']['value'])
st, ct, raw = req('/aowlspt/settings/aowl.uihubscale?ident=1', {'key':'itemRemote','value':'5447494a1b2c'})
after = {r['key']: r for r in json.loads(req('/aowlspt/settings/aowl.uihubscale?ident=1')[2])}
check('a select value persists as a plain string', after['itemRemote']['value']=='5447494a1b2c', after['itemRemote']['value'])
req('/aowlspt/settings/aowl.uihubscale/reset?ident=1', {'key':'k3'})
after = {r['key']: r for r in json.loads(req('/aowlspt/settings/aowl.uihubscale?ident=1')[2])}
check('per-row reset restores the declared default', after['k3']['value']==after['k3']['default']==5, after['k3']['value'])
req('/aowlspt/settings/aowl.uihubscale/reset?ident=1', {})
after = {r['key']: r for r in json.loads(req('/aowlspt/settings/aowl.uihubscale?ident=1')[2])}
check('page reset restores every row', all(r['value']==r['default'] for r in after.values()),
      [k for k,r in after.items() if r['value']!=r['default']])

# 7. a bad write must still be distinguishable
st, ct, raw = req('/aowlspt/settings/aowl.uihubscale?ident=1', {'nokey':1})
bad = json.loads(raw)
check('a malformed write replies with an OBJECT carrying err', isinstance(bad, dict) and bad.get('err'))

print()
print('FAILED: ' + ', '.join(fails) if fails else 'ALL PASS')
sys.exit(1 if fails else 0)
