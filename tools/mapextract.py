#!/usr/bin/env python3
"""Map geometry extractor for Escape From Tarkov (IL2CPP, Unity 2022.3).

READ-ONLY against the game install. Never writes under the Tarkov directory.

MUST be run under the Store Python, which is the only interpreter on this
machine that can import UnityPy (fact #163):

    %LOCALAPPDATA%\\Microsoft\\WindowsApps\\python.exe tools/mapextract.py ...

Subcommands
-----------
  inventory              which maps exist, which scenes each is built from,
                         and how big those scenes are on disk
  scan MAP [--scene S]   object / mesh / triangle counts per scene (slow-ish)
  extract MAP            emit glTF + hierarchy JSON + manifest per scene
  verify MAP             re-parse the emitted glTF independently and compare
                         against the manifest.  PASS / FAIL / INCONCLUSIVE.

Two source shapes exist (fact #159): built-in scenes live in
``levelN`` + ``sharedassetsN.assets``; the ``maps/*_preset.bundle`` files hold
only an ``EFT.ScenesPreset`` naming those built-in scenes (fact #166) -- they
carry no geometry themselves.
"""

import argparse
import json
import os
import struct
import sys
from collections import Counter, OrderedDict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mapextract_terrain as TER   # noqa: E402
import mapextract_tex as TEX       # noqa: E402

import gamepaths as _gp  # noqa: E402  (the data dir of the game the host runs against)
GAME_DIR = _gp.datadir()
DEFAULT_OUT = r"D:\MapExtract"

# ---------------------------------------------------------------------------
# environment


def _require_unitypy():
    try:
        import UnityPy  # noqa: F401
    except Exception as exc:  # pragma: no cover
        sys.stderr.write(
            "UnityPy is not importable under this interpreter (%s).\n"
            "Fact #163: only the Store Python can import it. Re-run with\n"
            "  %%LOCALAPPDATA%%\\Microsoft\\WindowsApps\\python.exe\n"
            "underlying error: %r\n" % (sys.executable, exc)
        )
        raise SystemExit(2)


def data_dir(args):
    d = getattr(args, "game_dir", None) or GAME_DIR
    if not os.path.isdir(d):
        raise SystemExit("game data dir not found: %s" % d)
    return d


# ---------------------------------------------------------------------------
# build settings: scene path -> level index


def load_build_settings(ddir):
    import UnityPy

    env = UnityPy.load(os.path.join(ddir, "globalgamemanagers"))
    for obj in env.objects:
        if obj.type.name == "BuildSettings":
            tree = obj.read_typetree()
            return list(tree.get("scenes", []))
    raise SystemExit("BuildSettings not found in globalgamemanagers")


def scene_index_map(ddir):
    scenes = load_build_settings(ddir)
    idx = {}
    for i, path in enumerate(scenes):
        idx[path] = i
        idx[path.lower()] = i
    return scenes, idx


# ---------------------------------------------------------------------------
# presets


def read_presets(ddir):
    """Return {map_key: {...}} parsed from maps/*_preset.bundle.

    A bundle holds several EFT.ScenesPreset MonoBehaviours forming a tree.  The
    root is the one no other preset lists in ChildPresets.
    """
    import UnityPy

    maps_dir = os.path.join(ddir, "StreamingAssets", "Windows", "maps")
    out = OrderedDict()
    for fn in sorted(os.listdir(maps_dir)):
        if not fn.endswith(".bundle"):
            continue
        full = os.path.join(maps_dir, fn)
        env = UnityPy.load(full)
        nodes = {}
        child_ids = set()
        for obj in env.objects:
            if obj.type.name != "MonoBehaviour":
                continue
            try:
                tree = obj.read_typetree()
            except Exception:
                continue
            if "_scenesResourceKeys" not in tree:
                continue
            pid = obj.path_id
            nodes[pid] = tree
            for ch in tree.get("ChildPresets") or []:
                if ch.get("m_FileID", 0) == 0:
                    child_ids.add(ch["m_PathID"])
        roots = [p for p in nodes if p not in child_ids]
        if not nodes:
            out[fn[:-7]] = {"bundle": fn, "error": "no ScenesPreset found"}
            continue

        def walk(pid, acc, seen):
            if pid in seen:
                return
            seen.add(pid)
            t = nodes.get(pid)
            if t is None:
                return
            for k in t.get("_scenesResourceKeys") or []:
                p = k.get("path")
                if p:
                    acc.append((p, bool(k.get("_onlyOffline", 0))))
            for ch in t.get("ChildPresets") or []:
                if ch.get("m_FileID", 0) == 0:
                    walk(ch["m_PathID"], acc, seen)

        scenes = []
        seen = set()
        for r in roots:
            walk(r, scenes, seen)
        root_tree = nodes[roots[0]] if roots else {}
        # de-dup preserving order
        uniq = []
        seen_paths = set()
        for p, off in scenes:
            if p not in seen_paths:
                seen_paths.add(p)
                uniq.append({"path": p, "onlyOffline": off})
        out[fn[:-7]] = {
            "bundle": fn,
            "presetName": root_tree.get("m_Name"),
            "serverName": root_tree.get("ServerName"),
            "activeSceneName": root_tree.get("_activeSceneName"),
            "presetCount": len(nodes),
            "scenes": uniq,
        }
    return out


# ---------------------------------------------------------------------------
# scene file resolution


def level_files(ddir, index):
    """Return (main, [resS/companions]) for a build-settings scene index."""
    main = os.path.join(ddir, "level%d" % index)
    extras = []
    for suffix in (".resS", ".resource"):
        p = main + suffix
        if os.path.exists(p):
            extras.append(p)
    return main, extras


def file_size(p):
    try:
        return os.path.getsize(p)
    except OSError:
        return 0


def human(n):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return "%.1f%s" % (n, unit)
        n /= 1024.0


def externals_of(path):
    """Names of the .assets files a scene file references."""
    import UnityPy

    env = UnityPy.load(path)
    names = []
    for f in env.files.values():
        for ext in getattr(f, "externals", []) or []:
            names.append(ext.path)
    return names


def open_scene_env(ddir, level_path):
    """Load a level file together with every external it names that exists.

    Loading the whole data directory is not an option: it is ~33 GB.  We open
    exactly the level file plus its declared externals, so cross-file PPtrs
    (meshes live in sharedassetsN.assets, not in levelN) resolve.
    """
    import UnityPy

    wanted = [level_path]
    missing = []
    for name in externals_of(level_path):
        base = os.path.basename(name.replace("\\", "/"))
        cand = os.path.join(ddir, base)
        if os.path.exists(cand):
            if cand not in wanted:
                wanted.append(cand)
        else:
            missing.append(name)
    env = UnityPy.load(*wanted)
    return env, wanted, missing


def files_by_name(env):
    """env.files is keyed by whatever path was passed in. Key by basename."""
    out = {}
    for k, v in env.files.items():
        out[os.path.basename(str(k).replace("\\", "/")).lower()] = v
    return out


# ---------------------------------------------------------------------------
# scanning


def scan_scene(ddir, level_path, deep=True):
    from UnityPy.helpers.MeshHelper import MeshHandler

    env, opened, missing = open_scene_env(ddir, level_path)
    types = Counter()
    mesh_refs = Counter()
    for obj in env.objects:
        types[obj.type.name] += 1
    # unique meshes actually referenced by this scene's MeshFilters/Colliders
    uniq = {}
    for obj in env.objects:
        if obj.assets_file is not files_by_name(env)[os.path.basename(level_path).lower()]:
            continue
        if obj.type.name not in ("MeshFilter", "MeshCollider", "SkinnedMeshRenderer"):
            continue
        try:
            tree = obj.read_typetree()
        except Exception:
            continue
        ptr = tree.get("m_Mesh") or tree.get("m_SharedMesh")
        if not ptr or ptr.get("m_PathID", 0) == 0:
            continue
        mesh_refs[(ptr["m_FileID"], ptr["m_PathID"])] += 1

    verts = tris = 0
    decoded = failed = 0
    if deep:
        for obj in env.objects:
            key = None
            if obj.type.name != "Mesh":
                continue
        # walk unique refs instead: resolve through a MeshFilter read
    return {
        "level": os.path.basename(level_path),
        "opened": [os.path.basename(p) for p in opened],
        "missingExternals": missing,
        "types": dict(types.most_common()),
        "uniqueMeshRefs": len(mesh_refs),
        "meshInstances": sum(mesh_refs.values()),
    }


# ---------------------------------------------------------------------------
# glTF 2.0 writer (pure python; no numpy / pygltflib on this machine)

COMP_FLOAT = 5126
COMP_UINT = 5125
COMP_USHORT = 5123


class GltfBuilder(object):
    """Minimal but valid glTF 2.0 emitter: one .gltf + one .bin.

    Coordinate handling: Unity is left-handed (X right, Y up, Z forward);
    glTF is right-handed.  We negate X on positions/normals and mirror the
    rotation quaternion (x, -y, -z, w), reversing triangle winding to keep
    faces outward.  Unity's own glTF importers apply the inverse on import, so
    a round trip back into the editor lands in the original orientation.
    Pass convert=False to keep raw Unity coordinates instead.
    """

    def __init__(self, convert=True):
        self.convert = convert
        self.bin = bytearray()
        self.buffer_views = []
        self.accessors = []
        self.meshes = []
        self.nodes = []
        self.materials = []

    # -- buffer plumbing ---------------------------------------------------
    def _align(self, n=4):
        while len(self.bin) % n:
            self.bin.append(0)

    def _view(self, blob, target=None):
        self._align(4)
        off = len(self.bin)
        self.bin.extend(blob)
        bv = {"buffer": 0, "byteOffset": off, "byteLength": len(blob)}
        if target is not None:
            bv["target"] = target
        self.buffer_views.append(bv)
        return len(self.buffer_views) - 1

    def add_vec(self, values, ncomp):
        """values: flat list of floats. Returns accessor index."""
        count = len(values) // ncomp
        blob = struct.pack("<%df" % len(values), *values)
        bv = self._view(blob, 34962)
        mins = [min(values[i::ncomp]) for i in range(ncomp)] if count else [0.0] * ncomp
        maxs = [max(values[i::ncomp]) for i in range(ncomp)] if count else [0.0] * ncomp
        self.accessors.append(
            {
                "bufferView": bv,
                "componentType": COMP_FLOAT,
                "count": count,
                "type": {2: "VEC2", 3: "VEC3", 4: "VEC4"}[ncomp],
                "min": mins,
                "max": maxs,
            }
        )
        return len(self.accessors) - 1

    def add_indices(self, idx, vertex_count):
        if vertex_count <= 65535:
            blob = struct.pack("<%dH" % len(idx), *idx)
            ctype = COMP_USHORT
        else:
            blob = struct.pack("<%dI" % len(idx), *idx)
            ctype = COMP_UINT
        bv = self._view(blob, 34963)
        self.accessors.append(
            {
                "bufferView": bv,
                "componentType": ctype,
                "count": len(idx),
                "type": "SCALAR",
            }
        )
        return len(self.accessors) - 1

    # -- content -----------------------------------------------------------
    def add_material(self, name):
        self.materials.append(
            {"name": name, "pbrMetallicRoughness": {"metallicFactor": 0.0, "roughnessFactor": 0.9}}
        )
        return len(self.materials) - 1

    def add_mesh(self, name, verts, normals, uvs, submeshes, material_indices):
        """verts/normals: flat xyz lists.  uvs: flat uv list or None.
        submeshes: list of (first_index, index_count) into a shared index list
        already sliced by the caller -> here submeshes is list of index lists.
        """
        if self.convert:
            verts = list(verts)
            for i in range(0, len(verts), 3):
                verts[i] = -verts[i]
            if normals:
                normals = list(normals)
                for i in range(0, len(normals), 3):
                    normals[i] = -normals[i]

        pos_acc = self.add_vec(verts, 3)
        attrs = {"POSITION": pos_acc}
        if normals and len(normals) == len(verts):
            attrs["NORMAL"] = self.add_vec(normals, 3)
        if uvs and len(uvs) // 2 == len(verts) // 3:
            uv = list(uvs)
            # glTF UV origin is top-left, Unity bottom-left
            for i in range(1, len(uv), 2):
                uv[i] = 1.0 - uv[i]
            attrs["TEXCOORD_0"] = self.add_vec(uv, 2)

        vcount = len(verts) // 3
        prims = []
        for si, idx in enumerate(submeshes):
            if self.convert:
                flipped = []
                for i in range(0, len(idx) - 2, 3):
                    flipped.extend((idx[i], idx[i + 2], idx[i + 1]))
                idx = flipped
            if not idx:
                continue
            prim = {"attributes": attrs, "indices": self.add_indices(idx, vcount), "mode": 4}
            if material_indices and si < len(material_indices) and material_indices[si] is not None:
                prim["material"] = material_indices[si]
            prims.append(prim)
        if not prims:
            return None
        self.meshes.append({"name": name, "primitives": prims})
        return len(self.meshes) - 1

    def add_node(self, name, t, r, s, mesh=None, children=None, extras=None):
        if self.convert:
            t = (-t[0], t[1], t[2])
            r = (r[0], -r[1], -r[2], r[3])
        node = {"name": name}
        if t != (0.0, 0.0, 0.0):
            node["translation"] = list(t)
        if r != (0.0, 0.0, 0.0, 1.0):
            node["rotation"] = list(r)
        if s != (1.0, 1.0, 1.0):
            node["scale"] = list(s)
        if mesh is not None:
            node["mesh"] = mesh
        if children:
            node["children"] = children
        if extras:
            node["extras"] = extras
        self.nodes.append(node)
        return len(self.nodes) - 1

    def write(self, gltf_path, bin_name, roots, scene_name):
        gltf = {
            "asset": {"version": "2.0", "generator": "aowlspt tools/mapextract.py"},
            "scene": 0,
            "scenes": [{"name": scene_name, "nodes": roots}],
            "nodes": self.nodes,
            "meshes": self.meshes,
            "accessors": self.accessors,
            "bufferViews": self.buffer_views,
            "buffers": [{"uri": bin_name, "byteLength": len(self.bin)}],
        }
        if self.materials:
            gltf["materials"] = self.materials
        with open(gltf_path, "w", newline="\n", encoding="utf-8") as fh:
            json.dump(gltf, fh, separators=(",", ":"))
        with open(os.path.join(os.path.dirname(gltf_path), bin_name), "wb") as fh:
            fh.write(self.bin)


# ---------------------------------------------------------------------------
# extraction


def _v3(d, default=(0.0, 0.0, 0.0)):
    if d is None:
        return default
    if isinstance(d, dict):
        return (float(d.get("x", 0)), float(d.get("y", 0)), float(d.get("z", 0)))
    return (float(d[0]), float(d[1]), float(d[2]))


def _v4(d):
    if d is None:
        return (0.0, 0.0, 0.0, 1.0)
    if isinstance(d, dict):
        return (
            float(d.get("x", 0)),
            float(d.get("y", 0)),
            float(d.get("z", 0)),
            float(d.get("w", 1)),
        )
    return tuple(float(x) for x in d)


def _trs(t, r, s):
    """4x4 row-major TRS matrix in UNITY coordinates."""
    x, y, z, w = r
    xx, yy, zz = x * x, y * y, z * z
    xy, xz, yz, wx, wy, wz = x * y, x * z, y * z, w * x, w * y, w * z
    m = [
        (1 - 2 * (yy + zz)) * s[0], (2 * (xy - wz)) * s[1], (2 * (xz + wy)) * s[2], t[0],
        (2 * (xy + wz)) * s[0], (1 - 2 * (xx + zz)) * s[1], (2 * (yz - wx)) * s[2], t[1],
        (2 * (xz - wy)) * s[0], (2 * (yz + wx)) * s[1], (1 - 2 * (xx + yy)) * s[2], t[2],
        0.0, 0.0, 0.0, 1.0,
    ]
    return m


def _matmul(a, b):
    out = [0.0] * 16
    for i in range(4):
        for j in range(4):
            out[i * 4 + j] = sum(a[i * 4 + k] * b[k * 4 + j] for k in range(4))
    return out


_IDENTITY = [1.0, 0, 0, 0, 0, 1.0, 0, 0, 0, 0, 1.0, 0, 0, 0, 0, 1.0]


def _xform(m, p):
    return (m[0] * p[0] + m[1] * p[1] + m[2] * p[2] + m[3],
            m[4] * p[0] + m[5] * p[1] + m[6] * p[2] + m[7],
            m[8] * p[0] + m[9] * p[1] + m[10] * p[2] + m[11])


def extract_scene(ddir, level_path, out_dir, scene_label, convert=True,
                  max_meshes=None, skip_lods=False, verbose=True,
                  tex_exporter=None, terrain=True, terrain_stride=1):
    from UnityPy.helpers.MeshHelper import MeshHandler

    env, opened, missing = open_scene_env(ddir, level_path)
    byname = files_by_name(env)
    main_file = byname[os.path.basename(level_path).lower()]

    # ---- index objects of the scene file
    transforms = {}     # pathid -> typetree
    gameobjects = {}    # pathid -> typetree
    comps = {}          # pathid -> (typename, reader)
    for obj in env.objects:
        if obj.assets_file is not main_file:
            continue
        tn = obj.type.name
        if tn in ("Transform", "RectTransform"):
            transforms[obj.path_id] = obj.read_typetree()
        elif tn == "GameObject":
            gameobjects[obj.path_id] = obj.read_typetree()
        elif tn in ("MeshFilter", "MeshRenderer", "MeshCollider", "BoxCollider",
                    "SphereCollider", "CapsuleCollider", "LODGroup", "Terrain",
                    "TerrainCollider", "SkinnedMeshRenderer"):
            comps[obj.path_id] = (tn, obj)

    if verbose:
        sys.stderr.write("  %s: %d GameObjects, %d Transforms, %d tracked components\n"
                         % (scene_label, len(gameobjects), len(transforms), len(comps)))

    # ---- material / texture resolution (cached).  Full property dump plus,
    # when a TextureExporter is supplied, the actual image files.
    mat_cache = {}
    tex_cache = {}

    def resolve_material(ptr):
        key = (ptr.get("m_FileID", 0), ptr.get("m_PathID", 0))
        if key[1] == 0:
            return None
        if key in mat_cache:
            return mat_cache[key]
        info = TEX.read_material(env, main_file, ptr, _deref, _try_name,
                                 tex_exporter, tex_cache)
        mat_cache[key] = info
        return info

    # ---- mesh decoding, deduplicated by (fileID, pathID)
    mesh_cache = {}
    stats = {"meshDecoded": 0, "meshFailed": 0, "vertices": 0, "triangles": 0}
    builder = GltfBuilder(convert=convert)
    gltf_mat_index = {}

    def material_index(minfo):
        if minfo is None:
            return None
        key = minfo["ref"]
        if key not in gltf_mat_index:
            gltf_mat_index[key] = builder.add_material(minfo.get("name") or ("mat_" + key))
        return gltf_mat_index[key]

    def get_mesh(ptr, mat_infos):
        key = (ptr.get("m_FileID", 0), ptr.get("m_PathID", 0))
        if key[1] == 0:
            return None
        if key in mesh_cache:
            return mesh_cache[key]
        if max_meshes is not None and stats["meshDecoded"] >= max_meshes:
            mesh_cache[key] = None
            return None
        result = None
        try:
            reader = _deref(env, main_file, ptr)
            mesh = reader.read()
            handler = MeshHandler(mesh)
            handler.process()
            verts = handler.m_Vertices or []
            idx = handler.m_IndexBuffer or []
            if verts and idx:
                flat_v = [c for v in verts for c in v[:3]]
                flat_n = [c for v in (handler.m_Normals or []) for c in v[:3]]
                flat_uv = [c for v in (handler.m_UV0 or []) for c in v[:2]]
                subs = []
                mat_ids = []
                sublist = getattr(mesh, "m_SubMeshes", None) or []
                if sublist:
                    for si, sm in enumerate(sublist):
                        first = int(sm.firstByte // (2 if handler.m_Use16BitIndices else 4)) \
                            if hasattr(sm, "firstByte") else int(getattr(sm, "firstIndex", 0))
                        cnt = int(getattr(sm, "indexCount", 0))
                        subs.append(list(idx[first:first + cnt]))
                        mat_ids.append(material_index(mat_infos[si]) if si < len(mat_infos) else None)
                else:
                    subs = [list(idx)]
                    mat_ids = [material_index(mat_infos[0]) if mat_infos else None]
                mi = builder.add_mesh(getattr(mesh, "m_Name", "mesh"), flat_v, flat_n,
                                      flat_uv, subs, mat_ids)
                if mi is not None:
                    result = mi
                    stats["meshDecoded"] += 1
                    stats["vertices"] += len(verts)
                    stats["triangles"] += sum(len(s) for s in subs) // 3
        except Exception:
            stats["meshFailed"] += 1
        mesh_cache[key] = result
        return result

    # ---- walk the transform hierarchy
    children_of = {}
    roots = []
    for pid, tr in transforms.items():
        father = (tr.get("m_Father") or {}).get("m_PathID", 0)
        if father and father in transforms:
            children_of.setdefault(father, []).append(pid)
        else:
            roots.append(pid)
    roots.sort()

    hierarchy = []
    node_index = {}
    terrain_records = []
    terrain_stats = {"seen": 0, "meshes": 0, "vertices": 0, "triangles": 0,
                     "pass": 0, "fail": 0, "inconclusive": 0}

    def build_terrain(ctree, name, world_m, hnode_entry):
        """Emit a real grid mesh for one Terrain component. Returns mesh idx."""
        terrain_stats["seen"] += 1
        rec = {"object": name, "scene": scene_label}
        tdptr = ctree.get("m_TerrainData") or {}
        rec["terrainDataRef"] = "%d:%d" % (tdptr.get("m_FileID", 0), tdptr.get("m_PathID", 0))
        if not terrain:
            rec["verdict"] = "INCONCLUSIVE"
            rec["reason"] = "terrain extraction disabled (--no-terrain)"
            terrain_stats["inconclusive"] += 1
            terrain_records.append(rec)
            return None
        try:
            reader = _deref(env, main_file, tdptr)
            if reader is None:
                raise ValueError("TerrainData pointer did not resolve")
            tdtree = reader.read_typetree()
        except Exception as exc:
            rec["verdict"] = "INCONCLUSIVE"
            rec["reason"] = "TerrainData unreadable: %r" % (exc,)
            terrain_stats["inconclusive"] += 1
            terrain_records.append(rec)
            return None

        td = TER.read_terrain_data(tdtree)
        rec["terrainDataName"] = td["name"]
        rec["heightmapResolution"] = td["resolution"]
        rec["heightmapScale"] = list(td["scale"])
        rec["declaredSize"] = td["size"]
        built, meta = TER.build_terrain_mesh(td, stride=terrain_stride)
        if built is None:
            rec["verdict"] = "INCONCLUSIVE"
            rec["reason"] = meta
            terrain_stats["inconclusive"] += 1
            terrain_records.append(rec)
            return None
        verts, normals, uvs, idx = built
        verdict, problems = TER.check_terrain_mesh(meta, td)
        rec["verdict"] = verdict
        rec["problems"] = problems
        rec.update({k: meta[k] for k in ("resolution", "stride", "gridDim",
                                         "vertexCount", "triangleCount",
                                         "fullResolution", "localBBoxMin",
                                         "localBBoxMax", "heightDivisor")})
        terrain_stats[verdict.lower()] += 1

        # world bbox of the terrain mesh corners, composed through the node
        # chain -- this is the check that can falsify a wrong hierarchy.
        lo, hi = meta["localBBoxMin"], meta["localBBoxMax"]
        corners = [(lo[0] if a else hi[0], lo[1] if b else hi[1], lo[2] if c else hi[2])
                   for a in (0, 1) for b in (0, 1) for c in (0, 1)]
        wpts = [_xform(world_m, p) for p in corners]
        rec["worldBBoxMin"] = [min(p[i] for p in wpts) for i in range(3)]
        rec["worldBBoxMax"] = [max(p[i] for p in wpts) for i in range(3)]
        origin = _xform(world_m, (0.0, 0.0, 0.0))
        rec["worldOrigin"] = list(origin)
        # NOTE: these are UNITY world coordinates, composed from the raw
        # Transform chain.  The glTF verifier reports its bbox in glTF space,
        # where X is negated -- do not compare the two numbers directly.
        rec["coordinateSpace"] = "unity"

        mi = builder.add_mesh("terrain_" + (td["name"] or name), verts, normals,
                              uvs, [idx], [material_index(
                                  {"ref": "terrain:" + rec["terrainDataRef"],
                                   "name": "TERRAIN_PLACEHOLDER_" + (td["name"] or name)})])
        if mi is None:
            rec["verdict"] = "INCONCLUSIVE"
            rec["reason"] = "grid produced no primitive"
            return None
        terrain_stats["meshes"] += 1
        terrain_stats["vertices"] += meta["vertexCount"]
        terrain_stats["triangles"] += meta["triangleCount"]
        stats["vertices"] += meta["vertexCount"]
        stats["triangles"] += meta["triangleCount"]

        rec["splat"] = TER.read_splat(tdtree, env, reader.assets_file, _deref,
                                      _try_name, tex_exporter, tex_cache)
        rec["detail"] = TER.read_detail(tdtree, td, origin, env,
                                        reader.assets_file, _try_name)
        terrain_records.append(rec)
        hnode_entry["terrain"] = {
            "verdict": verdict, "vertexCount": meta["vertexCount"],
            "declaredSize": td["size"],
            "worldBBox": [rec["worldBBoxMin"], rec["worldBBoxMax"]],
        }
        return mi

    def build(pid, depth, hier_parent, parent_m=None):
        tr = transforms[pid]
        go_id = (tr.get("m_GameObject") or {}).get("m_PathID", 0)
        go = gameobjects.get(go_id) or {}
        name = go.get("m_Name") or "GameObject"
        t = _v3(tr.get("m_LocalPosition"))
        r = _v4(tr.get("m_LocalRotation"))
        s = _v3(tr.get("m_LocalScale"), (1.0, 1.0, 1.0))
        world_m = _matmul(parent_m if parent_m is not None else _IDENTITY, _trs(t, r, s))

        hnode = {
            "name": name,
            "active": bool(go.get("m_IsActive", 1)),
            "layer": go.get("m_Layer"),
            "tag": go.get("m_TagString"),
            "t": list(t), "r": list(r), "s": list(s),
            "components": [],
            "children": [],
        }

        mesh_idx = None
        if skip_lods and ("_LOD" in name and not name.endswith("_LOD0")):
            pass
        else:
            mat_infos = []
            mesh_ptr = None
            terrain_ctree = None
            for cptr in go.get("m_Component") or []:
                cid = (cptr.get("component") or cptr).get("m_PathID", 0)
                if cid not in comps:
                    continue
                tn, reader = comps[cid]
                try:
                    ctree = reader.read_typetree()
                except Exception:
                    hnode["components"].append({"type": tn, "error": "typetree read failed"})
                    continue
                entry = {"type": tn}
                if tn == "MeshRenderer" or tn == "SkinnedMeshRenderer":
                    mats = []
                    for mp in ctree.get("m_Materials") or []:
                        mi = resolve_material(mp)
                        mats.append(mi)
                    mat_infos = mats
                    entry["materials"] = [
                        {"name": (m or {}).get("name"),
                         "textures": [tx.get("name") for tx in (m or {}).get("textures", [])]}
                        for m in mats
                    ]
                    entry["enabled"] = bool(ctree.get("m_Enabled", 1))
                    entry["castShadows"] = ctree.get("m_CastShadows")
                elif tn == "MeshFilter":
                    mesh_ptr = ctree.get("m_Mesh")
                    entry["meshRef"] = "%d:%d" % (mesh_ptr.get("m_FileID", 0),
                                                 mesh_ptr.get("m_PathID", 0))
                elif tn == "MeshCollider":
                    mp = ctree.get("m_Mesh") or {}
                    entry["meshRef"] = "%d:%d" % (mp.get("m_FileID", 0), mp.get("m_PathID", 0))
                    entry["convex"] = bool(ctree.get("m_Convex", 0))
                elif tn == "BoxCollider":
                    entry["center"] = list(_v3(ctree.get("m_Center")))
                    entry["size"] = list(_v3(ctree.get("m_Size")))
                elif tn == "SphereCollider":
                    entry["center"] = list(_v3(ctree.get("m_Center")))
                    entry["radius"] = ctree.get("m_Radius")
                elif tn == "CapsuleCollider":
                    entry["center"] = list(_v3(ctree.get("m_Center")))
                    entry["radius"] = ctree.get("m_Radius")
                    entry["height"] = ctree.get("m_Height")
                elif tn == "LODGroup":
                    entry["lodCount"] = len(ctree.get("m_LODs") or [])
                elif tn == "Terrain":
                    entry["drawHeightmap"] = ctree.get("m_DrawHeightmap")
                    entry["terrainDataRef"] = "%d:%d" % (
                        (ctree.get("m_TerrainData") or {}).get("m_FileID", 0),
                        (ctree.get("m_TerrainData") or {}).get("m_PathID", 0))
                    terrain_ctree = ctree
                hnode["components"].append(entry)
            if mesh_ptr is not None:
                mesh_idx = get_mesh(mesh_ptr, mat_infos)
            if mesh_idx is None and terrain_ctree is not None:
                mesh_idx = build_terrain(terrain_ctree, name, world_m, hnode)

        kids = []
        for ch in sorted(children_of.get(pid, [])):
            kids.append(build(ch, depth + 1, hnode, world_m))
        ni = builder.add_node(name, t, r, s, mesh=mesh_idx, children=kids or None,
                              extras={"active": hnode["active"]} if not hnode["active"] else None)
        node_index[pid] = ni
        if hier_parent is None:
            hierarchy.append(hnode)
        else:
            hier_parent["children"].append(hnode)
        return ni

    gltf_roots = [build(pid, 0, None) for pid in roots]

    # ---- write
    os.makedirs(out_dir, exist_ok=True)
    base = scene_label
    gltf_path = os.path.join(out_dir, base + ".gltf")
    builder.write(gltf_path, base + ".bin", gltf_roots, scene_label)

    with open(os.path.join(out_dir, base + ".hierarchy.json"), "w",
              newline="\n", encoding="utf-8") as fh:
        json.dump({"scene": scene_label, "source": os.path.basename(level_path),
                   "roots": hierarchy}, fh, separators=(",", ":"))

    # ---- sidecars: materials (rebuildable) and terrain (with its own verdicts)
    mats = [m for m in mat_cache.values() if m]
    mat_summary = TEX.summarize(mats)
    with open(os.path.join(out_dir, base + ".materials.json"), "w",
              newline="\n", encoding="utf-8") as fh:
        json.dump({"scene": scene_label, "summary": mat_summary,
                   "materials": mats}, fh, separators=(",", ":"))
    if terrain_records:
        with open(os.path.join(out_dir, base + ".terrain.json"), "w",
                  newline="\n", encoding="utf-8") as fh:
            json.dump({"scene": scene_label, "stats": terrain_stats,
                       "terrains": terrain_records}, fh, separators=(",", ":"))

    # ---- manifest: what the SOURCE said, for an independent re-read to check
    bbox_min = [1e30] * 3
    bbox_max = [-1e30] * 3
    total_verts = 0
    for acc in builder.accessors:
        if acc["type"] == "VEC3" and acc.get("min") and len(acc["min"]) == 3:
            pass
    # bbox computed from node-transformed mesh positions is expensive; use the
    # union of per-mesh POSITION accessor min/max in LOCAL space plus the node
    # translations, both of which the verifier recomputes independently.
    manifest = {
        "scene": scene_label,
        "source": os.path.basename(level_path),
        "openedFiles": [os.path.basename(p) for p in opened],
        "missingExternals": missing,
        "axisConverted": convert,
        "counts": {
            "gameObjects": len(gameobjects),
            "transforms": len(transforms),
            "gltfNodes": len(builder.nodes),
            "gltfMeshes": len(builder.meshes),
            "gltfMaterials": len(builder.materials),
            "meshDecoded": stats["meshDecoded"],
            "meshFailed": stats["meshFailed"],
            "sourceVertices": stats["vertices"],
            "sourceTriangles": stats["triangles"],
        },
        "terrain": terrain_stats,
        "terrains": terrain_records,
        "materials": mat_summary,
        "outputs": {
            "gltf": base + ".gltf",
            "bin": base + ".bin",
            "hierarchy": base + ".hierarchy.json",
            "materials": base + ".materials.json",
            "terrain": (base + ".terrain.json") if terrain_records else None,
        },
        "sizes": {
            "gltf": file_size(gltf_path),
            "bin": file_size(os.path.join(out_dir, base + ".bin")),
            "hierarchy": file_size(os.path.join(out_dir, base + ".hierarchy.json")),
        },
    }
    with open(os.path.join(out_dir, base + ".manifest.json"), "w",
              newline="\n", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=1)
    return manifest


def _deref(env, from_file, ptr):
    """Resolve a PPtr dict against from_file's external list."""
    fid = ptr.get("m_FileID", 0)
    pid = ptr.get("m_PathID", 0)
    if pid == 0:
        return None
    target = from_file
    if fid != 0:
        exts = getattr(from_file, "externals", []) or []
        if fid - 1 >= len(exts):
            return None
        name = os.path.basename(exts[fid - 1].path.replace("\\", "/"))
        target = files_by_name(env).get(name.lower())
        if target is None:
            return None
    objs = getattr(target, "objects", None)
    if objs is None:
        return None
    return objs.get(pid)


def _try_name(env, from_file, ptr):
    try:
        r = _deref(env, from_file, ptr)
        if r is None:
            return None
        return r.read_typetree().get("m_Name")
    except Exception:
        return None


# ---------------------------------------------------------------------------
# verification: independent re-read of the emitted glTF


def verify_gltf(out_dir, base):
    """Re-parse the emitted glTF WITHOUT reusing the writer's state.

    Returns (verdict, details) where verdict is PASS / FAIL / INCONCLUSIVE.
    """
    gltf_path = os.path.join(out_dir, base + ".gltf")
    man_path = os.path.join(out_dir, base + ".manifest.json")
    if not os.path.exists(gltf_path):
        return "INCONCLUSIVE", {"reason": "no glTF at %s" % gltf_path}
    if not os.path.exists(man_path):
        return "INCONCLUSIVE", {"reason": "no manifest at %s" % man_path}
    with open(man_path, "r", encoding="utf-8") as fh:
        man = json.load(fh)
    with open(gltf_path, "r", encoding="utf-8") as fh:
        g = json.load(fh)

    bin_path = os.path.join(out_dir, g["buffers"][0]["uri"])
    if not os.path.exists(bin_path):
        return "INCONCLUSIVE", {"reason": "buffer %s missing" % bin_path}
    blob = open(bin_path, "rb").read()
    if len(blob) != g["buffers"][0]["byteLength"]:
        return "FAIL", {"reason": "buffer byteLength %d != actual %d"
                        % (g["buffers"][0]["byteLength"], len(blob))}

    fails = []
    # 1. structural counts
    got = {
        "gltfNodes": len(g.get("nodes", [])),
        "gltfMeshes": len(g.get("meshes", [])),
        "gltfMaterials": len(g.get("materials", [])),
    }
    for k, v in got.items():
        if man["counts"].get(k) != v:
            fails.append("%s: manifest %r, glTF %r" % (k, man["counts"].get(k), v))

    # 2. decode every POSITION accessor straight out of the .bin and recount
    #    vertices + triangles, and recompute the bbox.  This is the check that
    #    can actually fail: it reads bytes, not the writer's variables.
    comp_size = {5126: 4, 5125: 4, 5123: 2, 5121: 1, 5122: 2, 5120: 1}
    ncomp = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}
    total_verts = 0
    total_tris = 0
    bmin = [1e30, 1e30, 1e30]
    bmax = [-1e30, -1e30, -1e30]
    degenerate = 0
    oob = 0

    def read_acc(ai):
        acc = g["accessors"][ai]
        bv = g["bufferViews"][acc["bufferView"]]
        n = acc["count"] * ncomp[acc["type"]]
        off = bv.get("byteOffset", 0) + acc.get("byteOffset", 0)
        sz = comp_size[acc["componentType"]] * n
        if off + sz > len(blob):
            raise ValueError("accessor %d reads past end of buffer" % ai)
        fmt = {5126: "f", 5125: "I", 5123: "H"}[acc["componentType"]]
        return struct.unpack_from("<%d%s" % (n, fmt), blob, off), acc

    for mi, mesh in enumerate(g.get("meshes", [])):
        pos_acc_ids = set()
        for prim in mesh["primitives"]:
            pos_acc_ids.add(prim["attributes"]["POSITION"])
            try:
                idx, iacc = read_acc(prim["indices"])
            except ValueError as exc:
                fails.append(str(exc))
                continue
            if len(idx) % 3:
                fails.append("mesh %d prim index count %d not a multiple of 3" % (mi, len(idx)))
            total_tris += len(idx) // 3
        for pa in pos_acc_ids:
            try:
                vals, acc = read_acc(pa)
            except ValueError as exc:
                fails.append(str(exc))
                continue
            total_verts += acc["count"]
            for i in range(0, len(vals), 3):
                for c in range(3):
                    v = vals[i + c]
                    if v < bmin[c]:
                        bmin[c] = v
                    if v > bmax[c]:
                        bmax[c] = v
                    if v != v or abs(v) > 1e12:
                        oob += 1
            # index range check
            for prim in mesh["primitives"]:
                if prim["attributes"]["POSITION"] != pa:
                    continue
                try:
                    idx, _ = read_acc(prim["indices"])
                except ValueError:
                    continue
                if idx and max(idx) >= acc["count"]:
                    fails.append("mesh %d: index %d >= vertex count %d"
                                 % (mi, max(idx), acc["count"]))
                    break

    if man["counts"]["sourceVertices"] != total_verts:
        fails.append("vertices: source read %d, glTF holds %d"
                     % (man["counts"]["sourceVertices"], total_verts))
    if man["counts"]["sourceTriangles"] != total_tris:
        fails.append("triangles: source read %d, glTF holds %d"
                     % (man["counts"]["sourceTriangles"], total_tris))
    if oob:
        fails.append("%d position components are NaN or absurd (>1e12)" % oob)

    # 3. every node's mesh index must exist; every root must be in range
    nmesh = len(g.get("meshes", []))
    for i, node in enumerate(g.get("nodes", [])):
        if "mesh" in node and not (0 <= node["mesh"] < nmesh):
            fails.append("node %d references mesh %d of %d" % (i, node["mesh"], nmesh))
        for c in node.get("children", []):
            if not (0 <= c < len(g["nodes"])):
                fails.append("node %d has out-of-range child %d" % (i, c))

    # 4. WORLD-space bbox: compose node TRS down the tree and transform each
    #    referenced mesh's local bbox corners.  A scene whose meshes decode but
    #    whose hierarchy is wrong shows up here as a collapsed or absurd extent,
    #    which the per-mesh local bbox cannot detect.
    mesh_bbox = {}
    for mi, mesh in enumerate(g.get("meshes", [])):
        lo = [1e30] * 3
        hi = [-1e30] * 3
        for prim in mesh["primitives"]:
            acc = g["accessors"][prim["attributes"]["POSITION"]]
            for c in range(3):
                lo[c] = min(lo[c], acc["min"][c])
                hi[c] = max(hi[c], acc["max"][c])
        mesh_bbox[mi] = (lo, hi)

    wmin = [1e30] * 3
    wmax = [-1e30] * 3
    placed = 0

    def mat_mul(a, b):
        return [sum(a[r * 4 + k] * b[k * 4 + c] for k in range(4))
                for r in range(4) for c in range(4)]

    def trs(node):
        t = node.get("translation", [0.0, 0.0, 0.0])
        q = node.get("rotation", [0.0, 0.0, 0.0, 1.0])
        s = node.get("scale", [1.0, 1.0, 1.0])
        x, y, z, w = q
        rm = [
            1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w), 0.0,
            2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w), 0.0,
            2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y), 0.0,
            0.0, 0.0, 0.0, 1.0,
        ]
        for r in range(3):
            for c in range(3):
                rm[r * 4 + c] *= s[c]
        rm[3], rm[7], rm[11] = 0.0, 0.0, 0.0
        rm[3 * 4 + 0], rm[3 * 4 + 1], rm[3 * 4 + 2] = 0.0, 0.0, 0.0
        m = list(rm)
        m[0 * 4 + 3] = t[0]
        m[1 * 4 + 3] = t[1]
        m[2 * 4 + 3] = t[2]
        return m

    IDENT = [1.0, 0, 0, 0, 0, 1.0, 0, 0, 0, 0, 1.0, 0, 0, 0, 0, 1.0]
    stack = [(r, IDENT) for r in reversed(g["scenes"][g.get("scene", 0)]["nodes"])]
    visited = 0
    while stack:
        ni, parent = stack.pop()
        visited += 1
        if visited > 2000000:
            fails.append("world bbox walk exceeded 2,000,000 nodes -- cycle?")
            break
        node = g["nodes"][ni]
        world = mat_mul(parent, trs(node))
        if "mesh" in node and node["mesh"] in mesh_bbox:
            lo, hi = mesh_bbox[node["mesh"]]
            for cx in (lo[0], hi[0]):
                for cy in (lo[1], hi[1]):
                    for cz in (lo[2], hi[2]):
                        for c in range(3):
                            v = (world[c * 4 + 0] * cx + world[c * 4 + 1] * cy
                                 + world[c * 4 + 2] * cz + world[c * 4 + 3])
                            if v < wmin[c]:
                                wmin[c] = v
                            if v > wmax[c]:
                                wmax[c] = v
            placed += 1
        for ch in node.get("children", []):
            stack.append((ch, world))

    world_bbox = None
    if placed:
        world_bbox = {"min": wmin, "max": wmax}
        extent = [wmax[c] - wmin[c] for c in range(3)]
        if max(extent) < 1.0:
            fails.append("world bbox collapsed to %r -- hierarchy did not place meshes"
                         % extent)
        if max(extent) > 1e6:
            fails.append("world bbox absurd (%r) -- transforms are wrong" % extent)
    else:
        fails.append("no node in the scene graph references a mesh")

    details = {
        "meshNodesPlaced": placed,
        "nodesWalked": visited,
        "bboxWorld": world_bbox,
        "verticesInGltf": total_verts,
        "trianglesInGltf": total_tris,
        "meshes": len(g.get("meshes", [])),
        "nodes": len(g.get("nodes", [])),
        "bboxLocal": {"min": bmin, "max": bmax} if total_verts else None,
        "binBytes": len(blob),
        "failures": fails,
    }
    if total_verts == 0:
        return "INCONCLUSIVE", dict(details, reason="glTF contains no vertices to check")
    return ("FAIL" if fails else "PASS"), details


# ---------------------------------------------------------------------------
# commands


def cmd_inventory(args):
    ddir = data_dir(args)
    scenes, idx = scene_index_map(ddir)
    presets = read_presets(ddir)
    report = {"gameDir": ddir, "buildSettingsSceneCount": len(scenes), "maps": OrderedDict()}
    print("%-26s %-18s %5s %5s %12s" % ("MAP (preset bundle)", "serverName", "scn", "found", "on-disk"))
    print("-" * 72)
    for key, info in presets.items():
        if "error" in info:
            print("%-26s %s" % (key, info["error"]))
            continue
        entries = []
        total = 0
        found = 0
        for sc in info["scenes"]:
            i = idx.get(sc["path"], idx.get(sc["path"].lower()))
            e = {"path": sc["path"], "onlyOffline": sc["onlyOffline"], "buildIndex": i}
            if i is not None:
                found += 1
                main, extras = level_files(ddir, i)
                sz = file_size(main) + sum(file_size(x) for x in extras)
                e["level"] = "level%d" % i
                e["bytes"] = sz
                total += sz
            entries.append(e)
        info2 = dict(info, scenes=entries, totalBytes=total)
        report["maps"][key] = info2
        print("%-26s %-18s %5d %5d %12s"
              % (key, (info.get("serverName") or "-")[:18], len(entries), found, human(total)))
    out = args.out or os.path.join(DEFAULT_OUT, "inventory.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", newline="\n", encoding="utf-8") as fh:
        json.dump(report, fh, indent=1)
    print("\nwrote %s" % out)
    print("NOTE: on-disk bytes are levelN + levelN.resS only. Meshes for a scene")
    print("      live in sharedassetsN.assets(+.resS), which are SHARED between")
    print("      scenes and are NOT counted here.")


def cmd_scan(args):
    ddir = data_dir(args)
    scenes, idx = scene_index_map(ddir)
    presets = read_presets(ddir)
    info = presets.get(args.map)
    if info is None:
        raise SystemExit("unknown map %r; known: %s" % (args.map, ", ".join(presets)))
    for sc in info["scenes"]:
        i = idx.get(sc["path"])
        if i is None:
            print("%-70s UNRESOLVED" % sc["path"])
            continue
        if args.scene and args.scene.lower() not in sc["path"].lower():
            continue
        main, _ = level_files(ddir, i)
        r = scan_scene(ddir, main)
        t = r["types"]
        print("%-60s level%-4d GO=%-6d MF=%-6d MR=%-6d MC=%-5d uniqMesh=%-5d"
              % (os.path.basename(sc["path"]), i, t.get("GameObject", 0),
                 t.get("MeshFilter", 0), t.get("MeshRenderer", 0),
                 t.get("MeshCollider", 0), r["uniqueMeshRefs"]))
        if r["missingExternals"]:
            print("    missing externals: %s" % r["missingExternals"])


def cmd_extract(args):
    ddir = data_dir(args)
    scenes, idx = scene_index_map(ddir)
    presets = read_presets(ddir)
    info = presets.get(args.map)
    if info is None:
        raise SystemExit("unknown map %r; known: %s" % (args.map, ", ".join(presets)))
    root = args.out or DEFAULT_OUT
    out_dir = os.path.join(root, args.map)
    os.makedirs(out_dir, exist_ok=True)
    # Textures are deduplicated by content hash into ONE pool shared by every
    # scene and every map, because the same atlas is reused everywhere.
    tex_exporter = None
    if not args.no_textures:
        tex_exporter = TEX.TextureExporter(os.path.join(root, "_textures"),
                                           mode=args.tex_format,
                                           compat=args.dds_compat)
    results = []
    for sc in info["scenes"]:
        i = idx.get(sc["path"])
        if i is None:
            sys.stderr.write("UNRESOLVED scene %s -- skipped\n" % sc["path"])
            continue
        label = os.path.splitext(os.path.basename(sc["path"]))[0]
        if args.scene and args.scene.lower() not in label.lower():
            continue
        main, _ = level_files(ddir, i)
        sys.stderr.write("extracting %s (level%d)\n" % (label, i))
        man = extract_scene(ddir, main, out_dir, label,
                            convert=not args.raw_axes,
                            max_meshes=args.max_meshes,
                            skip_lods=args.skip_lods,
                            tex_exporter=tex_exporter,
                            terrain=not args.no_terrain,
                            terrain_stride=args.terrain_stride)
        results.append(man)
        c = man["counts"]
        t = man["terrain"]
        print("%-40s meshes=%-6d verts=%-9d tris=%-9d bin=%-9s terrain=%d(%dP/%dF/%dI) slots=%d/%d"
              % (label, c["gltfMeshes"], c["sourceVertices"], c["sourceTriangles"],
                 human(man["sizes"]["bin"]), t["seen"], t["pass"], t["fail"],
                 t["inconclusive"], man["materials"]["slotsResolved"],
                 man["materials"]["slotsResolved"] + man["materials"]["slotsUnresolved"]))
    summary = {"map": args.map, "preset": info.get("presetName"),
               "serverName": info.get("serverName"), "scenes": results}
    if tex_exporter is not None:
        summary["textures"] = dict(tex_exporter.stats)
        summary["textures"]["uniqueFiles"] = len(tex_exporter.by_hash)
        with open(os.path.join(root, "_textures", "_index.json"), "w",
                  newline="\n", encoding="utf-8") as fh:
            json.dump({"mode": args.tex_format,
                       "note": ("colorSpace comes from Texture2D.m_ColorSpace "
                                "(1=sRGB colour, 0=linear DATA -- fact #36), "
                                "not from the file name"),
                       "stats": summary["textures"],
                       "unresolved": tex_exporter.unresolved,
                       "textures": tex_exporter.records}, fh, indent=1)
    with open(os.path.join(out_dir, "_map.json"), "w", newline="\n", encoding="utf-8") as fh:
        json.dump(summary, fh, indent=1)
    if tex_exporter is not None:
        s = tex_exporter.stats
        print("\ntextures: %d unique written (%s), %d references deduped (%s saved), "
              "%d PARTIAL, %d UNRESOLVED"
              % (s["exported"], human(s["bytesWritten"]), s["deduped"],
                 human(s["bytesSaved"]), s["partial"], s["unresolved"]))
    print("\noutput: %s" % out_dir)


def verify_sidecars(out_dir, base, tex_dir):
    """Independent re-check of the texture and terrain sidecars.

    Textures: every material slot that claims status OK must name a file that
    EXISTS, and -- for DDS -- whose width/height/mipCount re-read FROM THE
    BYTES ON DISK must equal what the Unity metadata declared.  A slot that
    claims OK and whose file is absent or mismatched is a FAIL, not a
    rounding error.  Unresolved slots are counted and reported, never
    silently dropped.

    Terrain: the per-terrain verdict is recomputed here from the recorded
    declaredSize and vertex counts rather than trusted from the manifest.
    """
    det = {"slotsOK": 0, "slotsUnresolved": 0, "slotsPartial": 0, "slotsEmpty": 0,
           "filesChecked": 0, "filesMissing": 0, "headerMismatch": 0,
           "terrainPass": 0, "terrainFail": 0, "terrainInconclusive": 0,
           "failures": []}
    mpath = os.path.join(out_dir, base + ".materials.json")
    if os.path.isfile(mpath):
        with open(mpath, "rb") as fh:
            mats = json.loads(fh.read().decode("utf-8"))
        checked = set()
        for m in mats.get("materials", []):
            for t in m.get("textures", []):
                st = t.get("status")
                if st == "EMPTY":
                    det["slotsEmpty"] += 1
                    continue
                if st == "PARTIAL":
                    det["slotsPartial"] += 1
                    if len(det["failures"]) < 40:
                        det["failures"].append(
                            "PARTIAL slot %s on material %s: %s"
                            % (t.get("slot"), m.get("name"), t.get("caveat") or "?"))
                elif st != "OK":
                    det["slotsUnresolved"] += 1
                    if len(det["failures"]) < 40:
                        det["failures"].append(
                            "UNRESOLVED slot %s on material %s: %s"
                            % (t.get("slot"), m.get("name"), t.get("reason") or st))
                    continue
                else:
                    det["slotsOK"] += 1
                fn = t.get("file")
                if not fn:
                    det["failures"].append("slot %s claims OK with no file" % t.get("slot"))
                    det["filesMissing"] += 1
                    continue
                if fn in checked:
                    continue
                checked.add(fn)
                path = os.path.join(tex_dir, fn)
                det["filesChecked"] += 1
                if not os.path.isfile(path):
                    det["filesMissing"] += 1
                    det["failures"].append("texture file MISSING: %s" % fn)
                    continue
                if fn.endswith(".dds"):
                    with open(path, "rb") as fh:
                        head = fh.read(160)
                    hdr = TEX.parse_dds(head)
                    if hdr is None:
                        det["headerMismatch"] += 1
                        det["failures"].append("not a readable DDS: %s" % fn)
                    else:
                        for key in ("width", "height", "mipCount"):
                            want = t.get(key)
                            if want is not None and hdr.get(key) != want:
                                det["headerMismatch"] += 1
                                det["failures"].append(
                                    "%s: on-disk %s=%s but metadata declared %s"
                                    % (fn, key, hdr.get(key), want))
                                break
    tpath = os.path.join(out_dir, base + ".terrain.json")
    if os.path.isfile(tpath):
        with open(tpath, "rb") as fh:
            terr = json.loads(fh.read().decode("utf-8"))
        for rec in terr.get("terrains", []):
            v = rec.get("verdict")
            if v == "PASS":
                # recompute rather than trust
                n = rec.get("gridDim") or 0
                ok = rec.get("vertexCount") == n * n
                lo, hi = rec.get("localBBoxMin"), rec.get("localBBoxMax")
                size = rec.get("declaredSize")
                if ok and lo and hi and size:
                    ok = (abs((hi[0] - lo[0]) - size[0]) <= max(1e-3, abs(size[0]) * 1e-5)
                          and abs((hi[2] - lo[2]) - size[2]) <= max(1e-3, abs(size[2]) * 1e-5))
                if ok:
                    det["terrainPass"] += 1
                else:
                    det["terrainFail"] += 1
                    det["failures"].append(
                        "terrain %s recorded PASS but re-check disagrees" % rec.get("object"))
            elif v == "FAIL":
                det["terrainFail"] += 1
                det["failures"].append("terrain %s FAIL: %s"
                                       % (rec.get("object"), "; ".join(rec.get("problems") or [])))
            else:
                det["terrainInconclusive"] += 1
    return det


def cmd_verify(args):
    out_dir = os.path.join(args.out or DEFAULT_OUT, args.map)
    if not os.path.isdir(out_dir):
        print("INCONCLUSIVE: nothing extracted at %s" % out_dir)
        return 2
    bases = sorted(f[: -len(".manifest.json")] for f in os.listdir(out_dir)
                   if f.endswith(".manifest.json"))
    if not bases:
        print("INCONCLUSIVE: no manifests in %s -- nothing was extracted" % out_dir)
        return 2
    verdicts = Counter()
    side = []
    tex_dir = os.path.join(args.out or DEFAULT_OUT, "_textures")
    for b in bases:
        if args.scene and args.scene.lower() not in b.lower():
            continue
        verdict, det = verify_gltf(out_dir, b)
        verdicts[verdict] += 1
        print("%-8s %-44s meshes=%-6s verts=%-9s tris=%-9s"
              % (verdict, b, det.get("meshes"), det.get("verticesInGltf"),
                 det.get("trianglesInGltf")))
        if det.get("bboxWorld"):
            bb = det["bboxWorld"]
            print("         world bbox min=%s max=%s  (%d mesh nodes placed, %d walked)"
                  % (["%.1f" % v for v in bb["min"]], ["%.1f" % v for v in bb["max"]],
                     det.get("meshNodesPlaced", 0), det.get("nodesWalked", 0)))
        for f in det.get("failures", [])[:10]:
            print("         FAIL: %s" % f)
        if det.get("reason"):
            print("         %s" % det["reason"])

        sc = verify_sidecars(out_dir, b, tex_dir)
        side.append(sc)
        if sc["slotsOK"] or sc["slotsUnresolved"] or sc["terrainPass"] or sc["terrainFail"]:
            print("         textures: %d slots OK / %d PARTIAL / %d UNRESOLVED / %d empty; "
                  "%d files checked, %d missing, %d header mismatch"
                  % (sc["slotsOK"], sc["slotsPartial"], sc["slotsUnresolved"],
                     sc["slotsEmpty"], sc["filesChecked"], sc["filesMissing"],
                     sc["headerMismatch"]))
            if sc["terrainPass"] or sc["terrainFail"] or sc["terrainInconclusive"]:
                print("         terrain:  %d PASS / %d FAIL / %d INCONCLUSIVE"
                      % (sc["terrainPass"], sc["terrainFail"], sc["terrainInconclusive"]))
            for f in sc["failures"][:6]:
                print("         SIDECAR: %s" % f)

    agg = {}
    for sc in side:
        for k, v in sc.items():
            if isinstance(v, int):
                agg[k] = agg.get(k, 0) + v
    print("\n%s" % ", ".join("%s=%d" % kv for kv in sorted(verdicts.items())))
    if agg:
        print("textures: %d slots resolved, %d PARTIAL, %d UNRESOLVED, %d files "
              "missing, %d header mismatches"
              % (agg.get("slotsOK", 0), agg.get("slotsPartial", 0),
                 agg.get("slotsUnresolved", 0), agg.get("filesMissing", 0),
                 agg.get("headerMismatch", 0)))
        print("terrain:  %d PASS / %d FAIL / %d INCONCLUSIVE"
              % (agg.get("terrainPass", 0), agg.get("terrainFail", 0),
                 agg.get("terrainInconclusive", 0)))
    bad = (verdicts["FAIL"] or agg.get("filesMissing", 0) or
           agg.get("headerMismatch", 0) or agg.get("terrainFail", 0))
    return 1 if bad else 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--game-dir", default=GAME_DIR)
    ap.add_argument("--out", default=None, help="output root (default %s)" % DEFAULT_OUT)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("inventory")
    p.set_defaults(fn=cmd_inventory)

    p = sub.add_parser("scan")
    p.add_argument("map")
    p.add_argument("--scene", default=None)
    p.set_defaults(fn=cmd_scan)

    p = sub.add_parser("extract")
    p.add_argument("map")
    p.add_argument("--scene", default=None)
    p.add_argument("--raw-axes", action="store_true",
                   help="keep Unity left-handed coords instead of glTF convention")
    p.add_argument("--max-meshes", type=int, default=None)
    p.add_argument("--skip-lods", action="store_true",
                   help="omit objects whose name contains _LOD but not _LOD0")
    p.add_argument("--no-textures", action="store_true",
                   help="do not export texture images (names only, old behaviour)")
    p.add_argument("--tex-format", choices=("dds", "png"), default="dds",
                   help="dds = lossless block copy (default); png = decode, lossy for BC")
    p.add_argument("--dds-compat", action="store_true",
                   help="emit plain FourCC DXT1/DXT5 even for sRGB textures. "
                        "MEASURED: Pillow cannot decode the sRGB-typed DX10 form "
                        "(DXGI 72/78); with this flag the colour space survives "
                        "only in the sidecar, not in the container")
    p.add_argument("--no-terrain", action="store_true",
                   help="do not emit terrain grid meshes")
    p.add_argument("--terrain-stride", type=int, default=1,
                   help="heightmap sample stride; 1 = full resolution (default)")
    p.set_defaults(fn=cmd_extract)

    p = sub.add_parser("verify")
    p.add_argument("map")
    p.add_argument("--scene", default=None)
    p.set_defaults(fn=cmd_verify)

    args = ap.parse_args(argv)
    _require_unitypy()
    rc = args.fn(args)
    return rc or 0


if __name__ == "__main__":
    sys.exit(main())
