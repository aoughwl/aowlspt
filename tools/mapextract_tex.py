#!/usr/bin/env python3
"""Texture + material export for tools/mapextract.py.

Two things the geometry extractor never retained: the actual texture IMAGES
(it emitted names only, so a map opened in Unity referencing nothing) and the
material PROPERTIES (shader, colours, scalars, per-slot tiling) needed to
rebuild a material rather than merely re-skin one.

Design decisions, each measured rather than assumed
---------------------------------------------------
*Container.*  Unity ships these textures to D3D11 already block-compressed
(measured on ``level165``'s environment: 1948 DXT5, 946 RGBA32, 559 DXT1, 183
RGB24, 46 BC7 of 3819 Texture2D).  For every block-compressed format we copy
the blocks BYTE-FOR-BYTE into a DDS container and never decode.  That is
lossless and fast.  PNG is available via ``--tex-format png`` and is a decode,
therefore lossy for BC and slow; it is deliberately not the default.

*Colour space.*  Fact #36 says only ALBEDO is colour and normal/roughness/ao/
height/metalness are DATA.  We do not guess that from the file name -- the
asset states it: ``m_ColorSpace`` is 1 for sRGB and 0 for linear.  Measured:
``glass_dirt01`` -> 1, ``concrete5_nmp`` -> 0.  We record that per texture in
the sidecar AND encode it into the DDS DXGI format where the format has an
sRGB variant, so a re-import cannot silently gamma-decode a normal map.

*Dedup.*  Keyed on the SHA-256 of the raw image bytes, so the same atlas
reused across scenes and maps is written once.  The per-scene sidecar still
lists every reference, pointing at the shared file.

*Honesty.*  A texture we cannot export is recorded with a reason and counted
as UNRESOLVED.  It is never silently dropped, and an unresolved slot is
reported by the verifier as such -- not as a pass.
"""

import hashlib
import json
import os
import struct
import sys

# --- Unity TextureFormat -> block-compressed DDS description ---------------
# (dxgi_unorm, dxgi_srgb, fourcc_or_None, block_bytes, block_dim)
_BC = {
    10: ("DXT1", 71, 72, b"DXT1", 8, 4),    # BC1
    12: ("DXT5", 77, 78, b"DXT5", 16, 4),   # BC3
    25: ("BC7", 98, 99, None, 16, 4),
    26: ("BC4", 80, None, None, 8, 4),
    27: ("BC5", 83, None, None, 16, 4),
    24: ("BC6H", 95, None, None, 16, 4),
}

# Uncompressed formats we can wrap losslessly in a DDS as well.
# name -> (dxgi_unorm, dxgi_srgb, bytes_per_pixel, channel_swizzle)
_UNCOMPRESSED = {
    4: ("RGBA32", 28, 29, 4),    # DXGI_FORMAT_R8G8B8A8_UNORM(_SRGB)
    63: ("R8", 61, None, 1),     # DXGI_FORMAT_R8_UNORM
}

_FMT_NAMES = {
    1: "Alpha8", 3: "RGB24", 4: "RGBA32", 5: "ARGB32", 10: "DXT1", 12: "DXT5",
    20: "RGBAFloat", 24: "BC6H", 25: "BC7", 26: "BC4", 27: "BC5",
    28: "DXT1Crunched", 29: "DXT5Crunched", 63: "R8", 74: "RGBA64",
}

DDS_MAGIC = b"DDS "
DDSD_CAPS, DDSD_HEIGHT, DDSD_WIDTH, DDSD_PIXELFORMAT = 0x1, 0x2, 0x4, 0x1000
DDSD_MIPMAPCOUNT, DDSD_LINEARSIZE, DDSD_PITCH = 0x20000, 0x80000, 0x8
DDPF_FOURCC, DDPF_RGB, DDPF_ALPHAPIXELS, DDPF_LUMINANCE = 0x4, 0x40, 0x1, 0x20000
DDSCAPS_TEXTURE, DDSCAPS_MIPMAP, DDSCAPS_COMPLEX = 0x1000, 0x400000, 0x8


def format_name(fmt):
    return _FMT_NAMES.get(fmt, "Format%d" % fmt)


def _dds_header(width, height, mips, pf_flags, fourcc, bitcount, masks,
                pitch_or_linear, linear, cube=False):
    flags = DDSD_CAPS | DDSD_HEIGHT | DDSD_WIDTH | DDSD_PIXELFORMAT
    flags |= DDSD_LINEARSIZE if linear else DDSD_PITCH
    if mips > 1:
        flags |= DDSD_MIPMAPCOUNT
    caps = DDSCAPS_TEXTURE | ((DDSCAPS_MIPMAP | DDSCAPS_COMPLEX) if mips > 1 else 0)
    caps2 = 0
    if cube:
        caps |= DDSCAPS_COMPLEX
        caps2 = DDSCAPS2_CUBEMAP_ALLFACES
    return struct.pack(
        "<4sIIIIIII44sII4sIIIIIIIIII",
        DDS_MAGIC, 124, flags, height, width, pitch_or_linear, 0, mips,
        b"\0" * 44,
        32, pf_flags, fourcc or b"\0\0\0\0", bitcount,
        masks[0], masks[1], masks[2], masks[3],
        caps, caps2, 0, 0, 0,
    )


DDSCAPS2_CUBEMAP_ALLFACES = 0xFE00  # CUBEMAP | POSITIVEX..NEGATIVEZ
DDS_RESOURCE_MISC_TEXTURECUBE = 0x4


def _dx10_header(dxgi, cube=False):
    # resourceDimension=3 (TEXTURE2D), arraySize=1, miscFlags2=0
    misc = DDS_RESOURCE_MISC_TEXTURECUBE if cube else 0
    return struct.pack("<IIIII", dxgi, 3, misc, 1, 0)


def build_dds(fmt, width, height, mips, srgb, data, cube=False, compat=False):
    """Wrap raw Unity image bytes in a DDS. Returns (bytes, dds_format_note)
    or (None, reason) when the format is not directly wrappable."""
    if fmt in _BC:
        name, dxgi_u, dxgi_s, fourcc, blk_bytes, blk_dim = _BC[fmt]
        bw = max(1, (width + blk_dim - 1) // blk_dim)
        bh = max(1, (height + blk_dim - 1) // blk_dim)
        linear_size = bw * bh * blk_bytes
        dxgi = dxgi_s if (srgb and dxgi_s is not None) else dxgi_u
        use_dx10 = fourcc is None or cube or (srgb and dxgi_s is not None and not compat)
        if use_dx10:
            hdr = _dds_header(width, height, mips, DDPF_FOURCC, b"DX10", 0,
                              (0, 0, 0, 0), linear_size, True, cube)
            hdr += _dx10_header(dxgi, cube)
            note = "%s (DX10 dxgi=%d%s)" % (name, dxgi, ", cubemap" if cube else "")
        else:
            hdr = _dds_header(width, height, mips, DDPF_FOURCC, fourcc, 0,
                              (0, 0, 0, 0), linear_size, True, cube)
            note = "%s (FourCC)" % name
        return hdr + data, note
    if fmt in _UNCOMPRESSED:
        name, dxgi_u, dxgi_s, bpp = _UNCOMPRESSED[fmt]
        dxgi = dxgi_s if (srgb and dxgi_s is not None) else dxgi_u
        hdr = _dds_header(width, height, mips, DDPF_FOURCC, b"DX10", 0,
                          (0, 0, 0, 0), width * bpp, False, cube)
        hdr += _dx10_header(dxgi, cube)
        return hdr + data, "%s (DX10 dxgi=%d%s)" % (name, dxgi,
                                                    ", cubemap" if cube else "")
    return None, "format %s has no direct DDS wrapping" % format_name(fmt)


def parse_dds(blob):
    """Independent re-read of a DDS we wrote: returns dict or None.

    Deliberately does NOT share code with build_dds beyond the constants --
    it re-derives width/height/mips/format from the bytes on disk so the
    verifier is checking the FILE, not our intent.
    """
    if len(blob) < 128 or blob[:4] != DDS_MAGIC:
        return None
    (size, flags, height, width, pitch, depth, mips) = struct.unpack_from("<7I", blob, 4)
    # DDS_PIXELFORMAT begins at byte 76: dwSize@76, dwFlags@80, dwFourCC@84
    pf_flags, fourcc = struct.unpack_from("<I4s", blob, 80)
    out = {"width": width, "height": height, "mipCount": mips, "fourcc": None,
           "dxgi": None}
    if pf_flags & DDPF_FOURCC:
        out["fourcc"] = fourcc.decode("ascii", "replace")
        if fourcc == b"DX10" and len(blob) >= 148:
            out["dxgi"] = struct.unpack_from("<I", blob, 128)[0]
    return out


# ---------------------------------------------------------------------------


class TextureExporter(object):
    """Content-hash-deduplicated texture writer shared across scenes/maps."""

    def __init__(self, tex_dir, mode="dds", verbose=True, compat=False):
        self.tex_dir = tex_dir
        self.mode = mode
        # compat=True emits the plain FourCC DXT1/DXT5 form for BC1/BC3 even
        # when the texture is sRGB.  MEASURED trade-off: Pillow 11 decodes the
        # FourCC and linear DX10 files but raises "Unimplemented DXGI format
        # 72/78" on the sRGB-typed ones, so many simple readers will choke on
        # the correct file.  Default is still the sRGB-typed DX10, because the
        # container then states its own colour space and cannot be silently
        # gamma-decoded (fact #36); with compat the colour space survives only
        # in the sidecar's colorSpace field.
        self.compat = compat
        self.verbose = verbose
        os.makedirs(tex_dir, exist_ok=True)
        self.by_ref = {}      # "fid:pid" (scene-scoped) -> record
        self.by_hash = {}     # sha256 -> filename
        self.records = {}     # filename -> record
        self.stats = {"exported": 0, "deduped": 0, "unresolved": 0,
                      "partial": 0, "bytesWritten": 0, "bytesSaved": 0}
        self.unresolved = []

    def _fail(self, ref, name, reason):
        self.stats["unresolved"] += 1
        rec = {"ref": ref, "name": name, "status": "UNRESOLVED", "reason": reason}
        self.unresolved.append(rec)
        return rec

    def export(self, reader, ref, cache):
        """reader: UnityPy ObjectReader for a Texture2D. Returns a record."""
        if ref in cache:
            return cache[ref]
        rec = self._export(reader, ref)
        cache[ref] = rec
        return rec

    def _export(self, reader, ref):
        try:
            tree = reader.read_typetree()
        except Exception as exc:
            return self._fail(ref, None, "typetree read failed: %r" % (exc,))
        name = tree.get("m_Name") or ("tex_" + ref.replace(":", "_"))
        fmt = tree.get("m_TextureFormat")
        width = int(tree.get("m_Width") or 0)
        height = int(tree.get("m_Height") or 0)
        mips = max(1, int(tree.get("m_MipCount") or 1))
        # m_ColorSpace: 1 = sRGB (colour), 0 = linear (DATA). Fact #36 --
        # taken from the asset, never guessed from the name.
        srgb = int(tree.get("m_ColorSpace") or 0) == 1
        colour_space = "sRGB" if srgb else "linear"
        if width <= 0 or height <= 0:
            return self._fail(ref, name, "degenerate dimensions %dx%d" % (width, height))
        # m_TextureDimension 4 == Cube; m_ImageCount is then 6.
        cube = int(tree.get("m_TextureDimension") or 2) == 4 or \
            int(tree.get("m_ImageCount") or 1) == 6

        try:
            obj = reader.read()
            data = obj.get_image_data()
        except Exception as exc:
            return self._fail(ref, name, "image data unreadable: %r" % (exc,))
        if not data:
            sd = tree.get("m_StreamData") or {}
            return self._fail(ref, name, "no image bytes (streamData path=%r size=%s)"
                              % (sd.get("path"), sd.get("size")))

        digest = hashlib.sha256(data).hexdigest()
        if digest in self.by_hash:
            fn = self.by_hash[digest]
            self.stats["deduped"] += 1
            self.stats["bytesSaved"] += len(data)
            base = dict(self.records[fn])
            base.update({"ref": ref, "name": name, "status": "OK",
                         "file": fn, "dedup": True,
                         "colorSpace": colour_space})
            return base

        safe = "".join(c if (c.isalnum() or c in "._-") else "_" for c in name)[:96]
        if self.mode == "png":
            blob, note, ext = self._as_png(obj, name)
            if blob is None:
                return self._fail(ref, name, note)
        else:
            blob, note = build_dds(fmt, width, height, mips, srgb, data, cube,
                                   self.compat)
            ext = ".dds"
            if blob is None:
                # crunched / exotic formats have no lossless container path
                blob, note2, ext = self._as_png(obj, name)
                if blob is None:
                    return self._fail(ref, name, note + "; png fallback: " + note2)
                note = note + "; DECODED to PNG instead"

        # A cubemap that fell through to the PNG decode keeps only what PIL
        # hands back -- the other five faces are gone.  That must NOT read as
        # a clean success, so it is PARTIAL, counted and reported separately.
        status = "OK"
        caveat = None
        if cube and ext == ".png":
            status = "PARTIAL"
            caveat = ("cubemap flattened by the PNG decode: faces beyond the "
                      "first are NOT present in this file")
            self.stats["partial"] += 1

        fn = "%s.%s%s" % (safe, digest[:12], ext)
        path = os.path.join(self.tex_dir, fn)
        if not os.path.exists(path):
            with open(path, "wb") as fh:
                fh.write(blob)
        self.by_hash[digest] = fn
        self.stats["exported"] += 1
        self.stats["bytesWritten"] += len(blob)
        rec = {
            "ref": ref, "name": name, "status": status, "file": fn,
            "width": width, "height": height, "mipCount": mips,
            "unityFormat": format_name(fmt), "unityFormatId": fmt,
            "colorSpace": colour_space, "container": note,
            "sha256": digest, "dedup": False, "cubemap": cube,
        }
        if caveat:
            rec["caveat"] = caveat
        self.records[fn] = rec
        return rec

    def _as_png(self, obj, name):
        try:
            img = obj.image
            if img is None:
                return None, "UnityPy could not decode to an image", None
            import io
            buf = io.BytesIO()
            img.save(buf, format="PNG")
            return buf.getvalue(), "PNG (decoded)", ".png"
        except Exception as exc:
            return None, "PNG decode failed: %r" % (exc,), None


# ---------------------------------------------------------------------------
# materials


def read_material(env, from_file, ptr, deref, try_name, tex_exporter, tex_cache):
    """Full material dump: shader name, every texture slot (with tiling and an
    exported file), every colour and every float. Returns a dict."""
    key = "%d:%d" % (ptr.get("m_FileID", 0), ptr.get("m_PathID", 0))
    info = {"ref": key, "name": None, "shader": None, "textures": [],
            "colors": {}, "floats": {}, "keywords": None}
    try:
        reader = deref(env, from_file, ptr)
        if reader is None:
            info["error"] = "material pointer did not resolve"
            return info
        tree = reader.read_typetree()
        info["name"] = tree.get("m_Name")
        info["renderQueue"] = tree.get("m_CustomRenderQueue")
        kw = tree.get("m_ValidKeywords") or tree.get("m_ShaderKeywords")
        info["keywords"] = kw if isinstance(kw, list) else (
            [k for k in str(kw).split() if k] if kw else [])
        sptr = tree.get("m_Shader") or {}
        if sptr.get("m_PathID", 0):
            info["shaderRef"] = "%d:%d" % (sptr.get("m_FileID", 0), sptr["m_PathID"])
            nm = try_name(env, reader.assets_file, sptr)
            # An empty string here is NOT "the shader is unnamed" -- it means
            # the Shader object was not reachable from the files we opened.
            # Say that, rather than emitting "" and letting it read as a name.
            if nm:
                info["shader"] = nm
            else:
                info["shader"] = None
                info["shaderStatus"] = "UNRESOLVED: Shader object not reachable " \
                                       "from the opened asset files"
        saved = tree.get("m_SavedProperties") or {}

        def _pairs(seq):
            for entry in seq or []:
                if isinstance(entry, (list, tuple)) and len(entry) == 2:
                    yield entry[0], entry[1]
                elif isinstance(entry, dict):
                    yield entry.get("first"), entry.get("second")

        for slot, tex in _pairs(saved.get("m_TexEnvs")):
            texptr = (tex or {}).get("m_Texture") or {}
            scale = (tex or {}).get("m_Scale") or {}
            offset = (tex or {}).get("m_Offset") or {}
            ent = {
                "slot": slot,
                "scale": [scale.get("x", 1.0), scale.get("y", 1.0)],
                "offset": [offset.get("x", 0.0), offset.get("y", 0.0)],
            }
            if not texptr.get("m_PathID", 0):
                ent["status"] = "EMPTY"
                info["textures"].append(ent)
                continue
            tref = "%d:%d" % (texptr.get("m_FileID", 0), texptr["m_PathID"])
            ent["ref"] = tref
            ent["name"] = try_name(env, reader.assets_file, texptr)
            if tex_exporter is None:
                ent["status"] = "NOT_EXPORTED"
                info["textures"].append(ent)
                continue
            treader = deref(env, reader.assets_file, texptr)
            if treader is None:
                ent["status"] = "UNRESOLVED"
                ent["reason"] = "texture pointer did not resolve"
            elif treader.type.name not in ("Texture2D", "Cubemap"):
                ent["status"] = "UNRESOLVED"
                ent["reason"] = "unsupported texture type %s" % treader.type.name
            else:
                rec = tex_exporter.export(treader, tref, tex_cache)
                ent.update({k: v for k, v in rec.items() if k not in ("ref",)})
            info["textures"].append(ent)

        for slot, col in _pairs(saved.get("m_Colors")):
            if isinstance(col, dict):
                info["colors"][slot] = [col.get("r", 0.0), col.get("g", 0.0),
                                        col.get("b", 0.0), col.get("a", 1.0)]
        for slot, val in _pairs(saved.get("m_Floats")):
            try:
                info["floats"][slot] = float(val)
            except Exception:
                pass
    except Exception as exc:
        info["error"] = repr(exc)
    return info


def summarize(materials):
    """resolved vs unresolved texture-slot counts across a material list."""
    resolved = unresolved = empty = partial = 0
    for m in materials:
        for t in m.get("textures", []):
            st = t.get("status")
            if st == "EMPTY":
                empty += 1
            elif st == "OK":
                resolved += 1
            elif st == "PARTIAL":
                partial += 1
            else:
                unresolved += 1
    return {"slotsResolved": resolved, "slotsUnresolved": unresolved,
            "slotsPartial": partial, "slotsEmpty": empty}
