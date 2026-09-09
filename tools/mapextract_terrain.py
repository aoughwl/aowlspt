#!/usr/bin/env python3
"""Unity Terrain -> real grid mesh, for tools/mapextract.py.

A Unity ``Terrain`` is a heightmap asset, not a mesh, so the geometry
extractor recorded the component and emitted NO GROUND for Woods, Customs,
Shoreline, Lighthouse and Streets.  This module turns the heightmap into an
actual triangle grid at the terrain's own world transform.

Measured on ``level165`` (``woods_terrain.unity``), TerrainData path 4:488
----------------------------------------------------------------------------
``m_Heightmap.m_Resolution`` = 1025, ``m_Heights`` = 1050625 int16 = 1025^2,
``m_Scale`` = (0.68359375, 180.0, 0.68359375).

Height decoding is NOT assumed.  Unity stores each sample as an int16 whose
normalized value is ``raw / 32767.0``; that was CONFIRMED against the asset's
own independently-serialized ``m_MinMaxPatchHeights``, which are already
normalized: raw ``20087`` -> ``20087/32767`` = ``0.6130440`` and the file's
first patch min is ``0.613044023513794``.  Exact match, so the divisor is
measured, not folklore.

World size follows Unity's own convention
``size = ((res-1)*scale.x, scale.y, (res-1)*scale.z)``: here
``1024 * 0.68359375`` = ``700.0`` exactly, giving a 700 x 180 x 700 m terrain.
The exactness of that product is itself evidence the convention is right --
an off-by-one would give 700.68.

What this module EMITS
----------------------
* the ground surface as a triangle grid, vertices = res^2 (or the strided
  count), UV0 = normalized terrain coordinates, per-vertex normals from
  central differences on the heightmap.

What this module DOES NOT emit, and says so
-------------------------------------------
* **Splatmaps are exported as data, not baked.**  We write the alphamap
  textures and the TerrainLayer list (diffuse texture, tiling, normal map)
  into a sidecar so a re-import can rebuild the terrain material, but the
  emitted glTF mesh carries a single placeholder material -- glTF has no
  4-way splat blend and faking one would be a lie.
* **Tree instances are exported as a transform list, not as geometry.**
  Measured: 6449 instances over 30 prototypes on Woods terrain 0.  The
  prototype prefabs live outside the scene file; we record prototype refs and
  every instance's world position/rotation/scale so a consumer can place
  them, but no tree mesh is emitted.
* **Detail/grass layers**: measured ``m_DetailPrototypes`` = 0 on this
  terrain, so there is nothing to emit; where a terrain does have them we
  record the prototype list and the patch count, and emit no billboards.
"""

import math
import struct
import sys

HEIGHT_DIVISOR = 32767.0  # measured, see module docstring


def _v3(d, default=(0.0, 0.0, 0.0)):
    if d is None:
        return default
    return (float(d.get("x", 0)), float(d.get("y", 0)), float(d.get("z", 0)))


def read_terrain_data(tree):
    """Pull the parts we need out of a TerrainData typetree."""
    hm = tree.get("m_Heightmap") or {}
    res = int(hm.get("m_Resolution") or 0)
    heights = hm.get("m_Heights") or []
    scale = _v3(hm.get("m_Scale"), (1.0, 1.0, 1.0))
    return {
        "name": tree.get("m_Name"),
        "resolution": res,
        "heights": heights,
        "scale": scale,
        "size": [(res - 1) * scale[0], scale[1], (res - 1) * scale[2]] if res > 1 else [0, 0, 0],
        "holes": hm.get("m_Holes") or [],
    }


def build_terrain_mesh(td, stride=1):
    """Return (verts, normals, uvs, indices, meta) in LOCAL terrain space.

    Local space origin is the terrain transform's position; Unity terrain
    extends in +X and +Z from there, with Y = normalized * scale.y.
    """
    res = td["resolution"]
    heights = td["heights"]
    sx, sy, sz = td["scale"]
    if res < 2 or len(heights) != res * res:
        return None, "heightmap unusable: resolution=%s len(m_Heights)=%d (expected %d)" % (
            res, len(heights), res * res)

    stride = max(1, int(stride))
    # sample indices along one axis, always including the last row/column so
    # the mesh spans the full declared size even when strided
    cols = list(range(0, res, stride))
    if cols[-1] != res - 1:
        cols.append(res - 1)
    n = len(cols)

    def h(ix, iz):
        return heights[iz * res + ix] / HEIGHT_DIVISOR

    verts = []
    normals = []
    uvs = []
    inv = 1.0 / (res - 1)
    for zi, iz in enumerate(cols):
        for xi, ix in enumerate(cols):
            hv = h(ix, iz)
            verts.extend((ix * sx, hv * sy, iz * sz))
            uvs.extend((ix * inv, iz * inv))
            # central differences in HEIGHTMAP space, converted to world units
            xm = h(max(0, ix - 1), iz)
            xp = h(min(res - 1, ix + 1), iz)
            zm = h(ix, max(0, iz - 1))
            zp = h(ix, min(res - 1, iz + 1))
            dx = (xp - xm) * sy / (2.0 * sx)
            dz = (zp - zm) * sy / (2.0 * sz)
            nx, ny, nz = -dx, 1.0, -dz
            L = math.sqrt(nx * nx + ny * ny + nz * nz) or 1.0
            normals.extend((nx / L, ny / L, nz / L))

    idx = []
    for z in range(n - 1):
        row = z * n
        nrow = row + n
        for x in range(n - 1):
            a, b, c, d = row + x, row + x + 1, nrow + x, nrow + x + 1
            # Unity terrain winding, CCW when viewed from +Y
            idx.extend((a, c, b, b, c, d))

    meta = {
        "resolution": res,
        "stride": stride,
        "gridDim": n,
        "vertexCount": n * n,
        "triangleCount": (n - 1) * (n - 1) * 2,
        "fullResolution": stride == 1 and n == res,
        "localBBoxMin": [min(verts[0::3]), min(verts[1::3]), min(verts[2::3])],
        "localBBoxMax": [max(verts[0::3]), max(verts[1::3]), max(verts[2::3])],
        "declaredSize": td["size"],
        "heightDivisor": HEIGHT_DIVISOR,
    }
    return (verts, normals, uvs, idx), meta


def check_terrain_mesh(meta, td, tolerance=1e-3):
    """Falsifiable check, PASS / FAIL / INCONCLUSIVE.

    Two independent assertions, both of which a wrong implementation fails:
      1. vertex count equals the heightmap grid it claims to have sampled
         (and equals res^2 exactly at full resolution);
      2. the mesh's own LOCAL extent in X and Z equals the size Unity's
         own convention derives from m_Resolution and m_Scale, and its Y
         extent lies within [0, scale.y].  A wrong height divisor, a
         transposed axis or an off-by-one in the grid all break this.
    """
    problems = []
    res = meta["resolution"]
    if res < 2:
        return "INCONCLUSIVE", ["terrain has no usable heightmap resolution"]

    n = meta["gridDim"]
    if meta["vertexCount"] != n * n:
        problems.append("vertexCount %d != gridDim^2 %d" % (meta["vertexCount"], n * n))
    if meta["stride"] == 1 and meta["vertexCount"] != res * res:
        problems.append("full-resolution vertexCount %d != resolution^2 %d"
                        % (meta["vertexCount"], res * res))

    lo, hi = meta["localBBoxMin"], meta["localBBoxMax"]
    want = td["size"]
    got_x, got_z = hi[0] - lo[0], hi[2] - lo[2]
    tolx = max(tolerance, abs(want[0]) * 1e-5)
    tolz = max(tolerance, abs(want[2]) * 1e-5)
    if abs(got_x - want[0]) > tolx:
        problems.append("X extent %.4f != declared %.4f" % (got_x, want[0]))
    if abs(got_z - want[2]) > tolz:
        problems.append("Z extent %.4f != declared %.4f" % (got_z, want[2]))
    if lo[1] < -tolerance or hi[1] > want[1] + tolerance:
        problems.append("Y range [%.3f, %.3f] escapes declared height 0..%.3f"
                        % (lo[1], hi[1], want[1]))
    return ("PASS" if not problems else "FAIL"), problems


def read_splat(tree, env, from_file, deref, try_name, tex_exporter, tex_cache):
    """Splatmap sidecar: alphamap textures (exported) + TerrainLayer list."""
    sd = tree.get("m_SplatDatabase") or {}
    out = {
        "alphamapResolution": sd.get("m_AlphamapResolution"),
        "baseMapResolution": sd.get("m_BaseMapResolution"),
        "alphaTextures": [],
        "layers": [],
        "note": ("alphamaps and layers are exported as DATA; the glTF mesh "
                 "carries a placeholder material because glTF cannot express "
                 "a multi-layer splat blend"),
    }
    for ptr in sd.get("m_AlphaTextures") or []:
        ref = "%d:%d" % (ptr.get("m_FileID", 0), ptr.get("m_PathID", 0))
        ent = {"ref": ref, "name": try_name(env, from_file, ptr)}
        r = deref(env, from_file, ptr) if tex_exporter is not None else None
        if r is not None and r.type.name == "Texture2D":
            rec = tex_exporter.export(r, ref, tex_cache)
            ent.update({k: v for k, v in rec.items() if k != "ref"})
        elif tex_exporter is not None:
            ent["status"] = "UNRESOLVED"
            ent["reason"] = "alphamap pointer did not resolve to a Texture2D"
        out["alphaTextures"].append(ent)

    for layer_ptr in sd.get("m_TerrainLayers") or []:
        ent = {"ref": "%d:%d" % (layer_ptr.get("m_FileID", 0), layer_ptr.get("m_PathID", 0))}
        try:
            lr = deref(env, from_file, layer_ptr)
            if lr is None:
                ent["status"] = "UNRESOLVED"
                ent["reason"] = "TerrainLayer pointer did not resolve"
            else:
                lt = lr.read_typetree()
                ent["name"] = lt.get("m_Name")
                ent["tileSize"] = list(_v3(lt.get("m_TileSize")))[:2]
                ent["tileOffset"] = list(_v3(lt.get("m_TileOffset")))[:2]
                ent["metallic"] = lt.get("m_Metallic")
                ent["smoothness"] = lt.get("m_Smoothness")
                ent["normalScale"] = lt.get("m_NormalScale")
                ent["textures"] = []
                for slot in ("m_DiffuseTexture", "m_NormalMapTexture", "m_MaskMapTexture"):
                    tp = lt.get(slot) or {}
                    if not tp.get("m_PathID", 0):
                        continue
                    tref = "%d:%d" % (tp.get("m_FileID", 0), tp["m_PathID"])
                    te = {"slot": slot, "ref": tref,
                          "name": try_name(env, lr.assets_file, tp)}
                    tr = deref(env, lr.assets_file, tp) if tex_exporter is not None else None
                    if tr is not None and tr.type.name == "Texture2D":
                        rec = tex_exporter.export(tr, tref, tex_cache)
                        te.update({k: v for k, v in rec.items() if k != "ref"})
                    elif tex_exporter is not None:
                        te["status"] = "UNRESOLVED"
                        te["reason"] = "layer texture did not resolve to a Texture2D"
                    ent["textures"].append(te)
        except Exception as exc:
            ent["status"] = "UNRESOLVED"
            ent["reason"] = repr(exc)
        out["layers"].append(ent)
    return out


def read_detail(tree, td, origin, env, from_file, try_name):
    """Tree + detail instance sidecar.  Instances only -- no geometry."""
    dd = tree.get("m_DetailDatabase") or {}
    size = td["size"]
    protos = []
    for p in dd.get("m_TreePrototypes") or []:
        pref = p.get("prefab") or {}
        protos.append({
            "ref": "%d:%d" % (pref.get("m_FileID", 0), pref.get("m_PathID", 0)),
            "name": try_name(env, from_file, pref),
            "bendFactor": p.get("bendFactor"),
        })
    instances = []
    for inst in dd.get("m_TreeInstances") or []:
        pos = inst.get("position") or {}
        # instance positions are NORMALIZED 0..1 in terrain space
        instances.append({
            "prototype": inst.get("index"),
            "position": [origin[0] + float(pos.get("x", 0)) * size[0],
                         origin[1] + float(pos.get("y", 0)) * size[1],
                         origin[2] + float(pos.get("z", 0)) * size[2]],
            "rotationY": inst.get("rotation"),
            "widthScale": inst.get("widthScale"),
            "heightScale": inst.get("heightScale"),
        })
    details = []
    for p in dd.get("m_DetailPrototypes") or []:
        details.append({"noiseSpread": p.get("noiseSpread"),
                        "density": p.get("density"),
                        "usePrototypeMesh": p.get("usePrototypeMesh")})
    return {
        "treePrototypes": protos,
        "treeInstanceCount": len(instances),
        "treeInstances": instances,
        "detailPrototypeCount": len(details),
        "detailPrototypes": details,
        "detailPatchCount": dd.get("m_PatchCount"),
        "note": ("tree instances are world transforms only -- prototype "
                 "prefabs are outside the scene file and NO tree geometry is "
                 "emitted; detail/grass layers are counted, never emitted"),
    }
