"""
Job 1.3 -- what ARE the terrain textures, really?

Last round found `SplatAlpha 0/1/2` (1024x1024 RGBA32) and called them terrain. They
are TerrainData splat CONTROL maps: per-channel weight masks that say how much of
layer 0..3 to blend at each texel. They contain no colour. Pasting a concrete photo
into one would not make the ground concrete; it would scramble the blend weights and
produce noise. So replacing them is not merely useless, it is actively wrong.

The textures a player actually SEES on the ground are the TerrainLayer albedos that
those masks blend between. This tool finds them, by walking the real reference chain
rather than guessing from names:

    TerrainData.m_SplatDatabase.m_TerrainLayers[] -> PPtr<TerrainLayer>
    TerrainLayer.m_DiffuseTexture                 -> PPtr<Texture2D>

A PPtr with m_FileID != 0 points into ANOTHER file via the externals table, so the
answer to "where do the layer albedos live" may well be a different file from the
TerrainData -- possibly an AssetBundle, possibly another .assets. That is the actual
question, and it is resolved here rather than assumed.

Read-only. Never writes anywhere.

Usage:
  python terrain_probe.py --json ../out/terrain.json [--jobs 8]
"""
from __future__ import annotations
import argparse, collections, json, os, re, sys, time, traceback
from concurrent.futures import ProcessPoolExecutor

DATA = 'D:/Aowlspt/EscapeFromTarkov_Data'
PAT = re.compile(r'^(sharedassets\d+\.assets|resources\.assets|globalgamemanagers\.assets|level\d+)$')


def _tt(o):
    """Typetree dict for an object, or None. UnityPy's class wrappers do not expose
    every TerrainData field by attribute, so we read the raw tree."""
    try:
        return o.read_typetree()
    except Exception:
        return None


def scan(path: str):
    import UnityPy
    name = os.path.basename(path)
    try:
        env = UnityPy.load(path)
        sf = env.file
        externals = []
        for e in (getattr(sf, 'externals', None) or []):
            externals.append(str(getattr(e, 'path', '') or ''))

        terrains, layers, texnames = [], {}, {}
        counts = collections.Counter()
        for o in env.objects:
            counts[o.type.name] += 1
            if o.type.name == 'TerrainData':
                t = _tt(o)
                if not t:
                    continue
                sd = t.get('m_SplatDatabase', {}) or {}
                lay = sd.get('m_TerrainLayers') or []
                refs = [(int(p.get('m_FileID', 0)), int(p.get('m_PathID', 0)))
                        for p in lay if isinstance(p, dict)]
                terrains.append(dict(
                    file=name, path_id=int(o.path_id),
                    tname=str(t.get('m_Name', '')),
                    n_layers=len(refs), layers=refs,
                    splat_res=int((t.get('m_SplatDatabase', {}) or {})
                                  .get('m_AlphamapResolution', 0) or 0),
                ))
            elif o.type.name == 'TerrainLayer':
                t = _tt(o)
                if not t:
                    continue
                def p(k):
                    v = t.get(k) or {}
                    return (int(v.get('m_FileID', 0)), int(v.get('m_PathID', 0)))
                ts = t.get('m_TileSize') or {}
                layers[int(o.path_id)] = dict(
                    file=name, name=str(t.get('m_Name', '')),
                    diffuse=p('m_DiffuseTexture'), normal=p('m_NormalMapTexture'),
                    mask=p('m_MaskMapTexture'),
                    tile=[float(ts.get('x', 0) or 0), float(ts.get('y', 0) or 0)],
                )
            elif o.type.name == 'Texture2D':
                try:
                    d = o.read()
                    texnames[int(o.path_id)] = (str(d.m_Name or ''), int(d.m_Width),
                                                int(d.m_Height), int(d.m_TextureFormat))
                except Exception:
                    pass
        return dict(file=name, externals=externals, terrains=terrains,
                    layers=layers, texnames=texnames,
                    n_obj=sum(counts.values()), err=None)
    except Exception as e:
        return dict(file=name, externals=[], terrains=[], layers={}, texnames={},
                    n_obj=0, err=repr(e)[:200])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--json', default='../out/terrain.json')
    ap.add_argument('--jobs', type=int, default=8)
    ap.add_argument('--limit', type=int, default=0)
    args = ap.parse_args()

    files = [os.path.join(DATA, f) for f in os.listdir(DATA) if PAT.match(f)]
    files.sort(key=lambda p: -os.path.getsize(p))
    if args.limit:
        files = files[:args.limit]
    print(f'scanning {len(files)} serialized files '
          f'({sum(os.path.getsize(p) for p in files)/1e9:.1f} GB), jobs={args.jobs}')

    t0 = time.time()
    res, errs = [], []
    done = 0
    with ProcessPoolExecutor(max_workers=args.jobs) as ex:
        for r in ex.map(scan, files, chunksize=4):
            done += 1
            if r['err']:
                errs.append((r['file'], r['err']))
            else:
                res.append(r)
            if done % 200 == 0:
                print(f'  {done}/{len(files)}  {time.time()-t0:.0f}s')
    print(f'scanned {done} in {time.time()-t0:.0f}s, errors={len(errs)}')
    for f, e in errs[:10]:
        print('  ERR', f, e)

    # index
    layers_by_file = {r['file']: r['layers'] for r in res}
    tex_by_file = {r['file']: r['texnames'] for r in res}
    ext_by_file = {r['file']: r['externals'] for r in res}
    terrains = [t for r in res for t in r['terrains']]
    n_layers_total = sum(len(r['layers']) for r in res)

    print()
    print(f'TerrainData objects : {len(terrains)} in '
          f'{len({t["file"] for t in terrains})} files')
    print(f'TerrainLayer objects: {n_layers_total} in '
          f'{len([f for f,v in layers_by_file.items() if v])} files')

    def resolve(host_file, ref):
        """(m_FileID, m_PathID) -> (file, path_id) using the host's externals table."""
        fid, pid = ref
        if pid == 0:
            return None
        if fid == 0:
            return (host_file, pid)
        ext = ext_by_file.get(host_file, [])
        if fid - 1 < 0 or fid - 1 >= len(ext):
            return ('<fileid %d unresolved>' % fid, pid)
        return (os.path.basename(ext[fid - 1].replace('\\', '/')), pid)

    rows, unresolved = [], collections.Counter()
    for t in terrains:
        for ref in t['layers']:
            L = resolve(t['file'], ref)
            if L is None:
                continue
            lf, lp = L
            lay = layers_by_file.get(lf, {}).get(lp) or layers_by_file.get(lf, {}).get(str(lp))
            if lay is None:
                unresolved[f'TerrainLayer in {lf}'] += 1
                rows.append(dict(terrain=t['tname'], tfile=t['file'],
                                 layer_file=lf, layer_path=lp, layer=None))
                continue
            D = resolve(lf, tuple(lay['diffuse']))
            tex = None
            if D:
                df, dp = D
                tex = tex_by_file.get(df, {}).get(dp) or tex_by_file.get(df, {}).get(str(dp))
                if tex is None:
                    unresolved[f'Texture2D in {df}'] += 1
            rows.append(dict(terrain=t['tname'], tfile=t['file'],
                             layer_file=lf, layer=lay['name'], tile=lay['tile'],
                             tex_file=(D[0] if D else None),
                             tex_path=(D[1] if D else None),
                             tex=tex))

    print()
    print(f'terrain layer slots : {len(rows)}')
    named = [r for r in rows if r.get('tex')]
    print(f'  albedo RESOLVED   : {len(named)}')
    print(f'  albedo unresolved : {len(rows)-len(named)}')
    if unresolved:
        print('  unresolved targets (top):')
        for k, v in unresolved.most_common(10):
            print(f'     {v:5d}  {k}')

    print()
    print('DISTINCT terrain layer albedo textures:')
    dist = collections.Counter()
    for r in named:
        nm, w, h, fmt = r['tex']
        dist[(nm, w, h, fmt, r['tex_file'])] += 1
    for (nm, w, h, fmt, src), c in dist.most_common(80):
        print(f'  {c:4d}x  {nm:44s} {w}x{h} fmt={fmt:<3d} in {src}')
    print(f'  ({len(dist)} distinct albedo textures total)')

    os.makedirs(os.path.dirname(os.path.abspath(args.json)), exist_ok=True)
    with open(args.json, 'w', newline='\n') as f:
        json.dump(dict(rows=rows, terrains=terrains,
                       layers={k: v for k, v in layers_by_file.items() if v},
                       tex={k: v for k, v in tex_by_file.items() if v},
                       externals=ext_by_file, errors=errs), f)
    print('wrote', args.json)


if __name__ == '__main__':
    main()
