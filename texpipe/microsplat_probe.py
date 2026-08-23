"""
Is the TerrainLayer diffuse texture the thing the player actually SEES?

`terrain_probe.py` resolved 19 terrain slices -> 12 TerrainLayers -> 12 named
1024x1024 DXT5 albedos in sharedassets17.assets. Every layer is named
`microsplat_layer_*`, and that matters enormously:

**MicroSplat does not render from TerrainLayer.m_DiffuseTexture.** It bakes the layer
albedos into a `Texture2DArray` at author time and the terrain shader samples the
array. The TerrainLayer objects can remain in the file as authoring leftovers that
nothing reads at runtime. If that is what is happening here, replacing those 12
Texture2Ds would be a perfectly measurable patch that changes nothing on screen --
a false positive of exactly the kind this project cares most about catching.

So this asks the file, instead of assuming either way:

  * are there Texture2DArray objects, and how big are they (a 12-layer 1024 DXT5
    array is a very specific size)?
  * what Material / Shader does the terrain use, and which textures does that
    material actually bind?

Read-only.

Usage: python microsplat_probe.py [--files sharedassets17.assets,...]
"""
from __future__ import annotations
import argparse, collections, json, os, re, sys

import UnityPy

DATA = 'D:/Aowlspt/EscapeFromTarkov_Data'
PAT = re.compile(r'^(sharedassets\d+\.assets|resources\.assets|globalgamemanagers\.assets|level\d+)$')


def census(paths):
    """Count Texture2DArray everywhere, and describe the ones we find."""
    tot = collections.Counter()
    arrays = []
    for p in paths:
        try:
            env = UnityPy.load(p)
        except Exception as e:
            print('  ERR', os.path.basename(p), repr(e)[:80])
            continue
        for o in env.objects:
            tot[o.type.name] += 1
            if o.type.name == 'Texture2DArray':
                try:
                    t = o.read_typetree()
                    arrays.append(dict(
                        file=os.path.basename(p), path_id=int(o.path_id),
                        name=str(t.get('m_Name', '')),
                        w=int(t.get('m_Width', 0)), h=int(t.get('m_Height', 0)),
                        depth=int(t.get('m_Depth', 0)),
                        fmt=int(t.get('m_Format', 0)),
                        mips=int(t.get('m_MipCount', 0) or 0),
                        datasize=int(t.get('m_DataSize', 0) or 0),
                    ))
                except Exception as e:
                    arrays.append(dict(file=os.path.basename(p),
                                       path_id=int(o.path_id), err=repr(e)[:80]))
    return tot, arrays


def materials(path, want_shader_kw=('microsplat', 'terrain')):
    """Every Material in `path` whose shader/name looks terrain-ish, plus its
    texture bindings (env-resolved names are not attempted; PPtrs are reported)."""
    env = UnityPy.load(path)
    names = {}
    for o in env.objects:
        if o.type.name in ('Texture2D', 'Texture2DArray'):
            try:
                names[int(o.path_id)] = str(o.read_typetree().get('m_Name', ''))
            except Exception:
                pass
    out = []
    for o in env.objects:
        if o.type.name != 'Material':
            continue
        try:
            t = o.read_typetree()
        except Exception:
            continue
        nm = str(t.get('m_Name', ''))
        if not any(k in nm.lower() for k in want_shader_kw):
            continue
        binds = []
        saved = (t.get('m_SavedProperties') or {})
        for entry in (saved.get('m_TexEnvs') or []):
            try:
                k = entry[0] if isinstance(entry, (list, tuple)) else entry.get('first')
                v = entry[1] if isinstance(entry, (list, tuple)) else entry.get('second')
                tex = (v or {}).get('m_Texture') or {}
                fid, pid = int(tex.get('m_FileID', 0)), int(tex.get('m_PathID', 0))
                if pid == 0:
                    continue
                binds.append((str(k), fid, pid, names.get(pid, '' if fid else '<not here>')))
            except Exception:
                pass
        out.append(dict(name=nm, path_id=int(o.path_id), binds=binds))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--files', default='')
    ap.add_argument('--all', action='store_true',
                    help='census Texture2DArray across every serialized file')
    args = ap.parse_args()

    if args.all:
        paths = [os.path.join(DATA, f) for f in os.listdir(DATA) if PAT.match(f)]
    else:
        fl = args.files or ('sharedassets17.assets,sharedassets140.assets,'
                            'sharedassets165.assets,sharedassets25.assets,'
                            'sharedassets63.assets,sharedassets200.assets')
        paths = [os.path.join(DATA, f.strip()) for f in fl.split(',') if f.strip()]

    print(f'scanning {len(paths)} file(s) for Texture2DArray')
    tot, arrays = census(paths)
    print(f'Texture2DArray objects: {len(arrays)}')
    for a in arrays:
        if 'err' in a:
            print(f'   {a["file"]} pathid={a["path_id"]} ERR {a["err"]}')
            continue
        print(f'   {a["file"]:26s} {a["name"]:40s} {a["w"]}x{a["h"]} '
              f'depth={a["depth"]:<3d} fmt={a["fmt"]:<3d} mips={a["mips"]:<3d} '
              f'data={a["datasize"]:,}')

    print()
    print('terrain-ish Materials and their texture bindings:')
    for p in paths:
        try:
            ms = materials(p)
        except Exception as e:
            print('  ERR', os.path.basename(p), repr(e)[:80])
            continue
        for m in ms:
            print(f'  [{os.path.basename(p)}] {m["name"]}  (pathid {m["path_id"]})')
            for k, fid, pid, nm in m['binds']:
                print(f'       {k:34s} fileID={fid:<3d} pathID={pid:<22d} {nm}')


if __name__ == '__main__':
    main()
