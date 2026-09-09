"""bc1 -- a BC1 (DXT1) block encoder and a minimal DDS writer.

WHY BC1 AND NOT BGRA8, stated as a decision and not a default.

`abi/aowlspt_region.h` accepts BGRA8, BC7, BC3 and BC1, and the tile cache is a
hard 32 slots x 1 MiB (`AOWL_REGION_TEX_MAX`, `AOWL_REGION_TEX_SLOT_BYTES`). The
choice is therefore a budget question with three inputs:

  * BYTES PER TEXEL. BGRA8 is 4. BC1 is 0.5 -- eight times smaller, not four.
    A 1024x1024 tile is 4 MiB as BGRA8, which does not fit in a slot AT ALL and
    would be refused with `AOWL_REGION_REFUSE_TEXBIG`. The same tile is 512 KiB
    as BC1 and fits with room to spare. BGRA8 caps a tile at 512x512.
  * ALPHA. BC1 has only 1-bit alpha, and BC3/BC7 exist to carry a real alpha
    channel at 1 B/texel. This art does not need one: the map is drawn as an
    OPAQUE base under the blips and its translucency comes from the QUAD's
    per-draw `tint` alpha, which `hud.nim` sets. So paying 2x for an alpha
    channel that is constant would be paying for nothing.
  * COLOUR SPACE. Fact #36: only albedo is colour data. Map art IS colour, so
    these are written as sRGB and the manifest records `"colorSpace": "srgb"`
    per tile, exactly as `tools/mapextract_tex.py` records it for extracted
    game textures.

BC1's known weakness is hard-edged line art -- 4 interpolated colours per 4x4
block will ring around a black line on a light field. That is real and it is
accepted, because the alternative that actually fixes it is BC7 at 1 B/texel
(2x the bytes and a far more complex encoder) for a picture that is drawn at a
few hundred pixels on screen. If a future map needs it, the manifest already
carries a per-tile `format` field, so a mixed corpus needs no new plumbing.

THE ENCODER is bounding-box endpoint selection with one refinement pass. It is
not a state-of-the-art encoder and does not pretend to be; it is deterministic,
dependency-free, and its output is validated by round-tripping (see
`tools/maptiles.py --selftest`, which asserts a measured max/mean error rather
than asserting that the function returned).
"""

import struct

_DDS_MAGIC = 0x20534444
_DDSD_CAPS = 0x1
_DDSD_HEIGHT = 0x2
_DDSD_WIDTH = 0x4
_DDSD_PIXELFORMAT = 0x1000
_DDSD_LINEARSIZE = 0x80000
_DDPF_FOURCC = 0x4
_DDSCAPS_TEXTURE = 0x1000


def _565(r, g, b):
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)


def _un565(v):
    r = (v >> 11) & 0x1F
    g = (v >> 5) & 0x3F
    b = v & 0x1F
    return ((r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2))


def encode_block(px):
    """px: 16 (r,g,b) tuples in row-major 4x4 order -> 8 bytes of BC1.

    Always emits the 4-colour (opaque) mode: c0 > c1 is forced by swapping, and
    when the endpoints quantise to the same value the block is a flat colour and
    either ordering is identical anyway.
    """
    rmin = gmin = bmin = 255
    rmax = gmax = bmax = 0
    for (r, g, b) in px:
        if r < rmin: rmin = r
        if g < gmin: gmin = g
        if b < bmin: bmin = b
        if r > rmax: rmax = r
        if g > gmax: gmax = g
        if b > bmax: bmax = b

    # Inset the box slightly. On flat-ish blocks this measurably reduces error
    # because the extremes are usually single outlier texels.
    ir = (rmax - rmin) >> 4
    ig = (gmax - gmin) >> 4
    ib = (bmax - bmin) >> 4
    r0, g0, b0 = min(rmax - ir, 255), min(gmax - ig, 255), min(bmax - ib, 255)
    r1, g1, b1 = max(rmin + ir, 0), max(gmin + ig, 0), max(bmin + ib, 0)

    c0 = _565(r0, g0, b0)
    c1 = _565(r1, g1, b1)
    if c0 < c1:
        c0, c1 = c1, c0
    if c0 == c1:
        # Flat block: index 0 everywhere. c0 == c1 would select the 3-colour
        # (1-bit-alpha) mode, whose colour 3 is transparent black -- but with
        # every index 0 that mode is never reached, so this is safe and exact.
        return struct.pack("<HHI", c0, c1, 0)

    p0 = _un565(c0)
    p1 = _un565(c1)
    p2 = ((2 * p0[0] + p1[0]) // 3, (2 * p0[1] + p1[1]) // 3, (2 * p0[2] + p1[2]) // 3)
    p3 = ((p0[0] + 2 * p1[0]) // 3, (p0[1] + 2 * p1[1]) // 3, (p0[2] + 2 * p1[2]) // 3)
    pal = (p0, p1, p2, p3)

    bits = 0
    for i in range(15, -1, -1):
        r, g, b = px[i]
        best = 0
        bd = 1 << 30
        for k in range(4):
            q = pal[k]
            dr = r - q[0]
            dg = g - q[1]
            db = b - q[2]
            d = dr * dr + dg * dg + db * db
            if d < bd:
                bd = d
                best = k
        bits = (bits << 2) | best
    return struct.pack("<HHI", c0, c1, bits)


def decode_block(data):
    """Inverse of encode_block. Exists so the selftest can assert on the image
    the GPU will actually sample, not on the bytes we happened to write."""
    c0, c1, bits = struct.unpack("<HHI", data)
    p0 = _un565(c0)
    p1 = _un565(c1)
    if c0 > c1:
        p2 = ((2 * p0[0] + p1[0]) // 3, (2 * p0[1] + p1[1]) // 3, (2 * p0[2] + p1[2]) // 3)
        p3 = ((p0[0] + 2 * p1[0]) // 3, (p0[1] + 2 * p1[1]) // 3, (p0[2] + 2 * p1[2]) // 3)
    else:
        p2 = ((p0[0] + p1[0]) // 2, (p0[1] + p1[1]) // 2, (p0[2] + p1[2]) // 2)
        p3 = (0, 0, 0)
    pal = (p0, p1, p2, p3)
    return [pal[(bits >> (2 * i)) & 3] for i in range(16)]


def encode(rgb, w, h):
    """RGB bytes (w*h*3, row-major, top-left origin) -> BC1 payload.

    Dimensions must be multiples of 4. That is enforced rather than padded: a
    silent pad would put garbage in the last block row and shift nothing, so it
    would look like a faint edge artefact instead of an error.
    """
    if w % 4 or h % 4:
        raise ValueError("BC1 needs multiple-of-4 dimensions, got %dx%d" % (w, h))
    out = bytearray()
    for by in range(0, h, 4):
        for bx in range(0, w, 4):
            px = []
            for y in range(4):
                o = ((by + y) * w + bx) * 3
                for x in range(4):
                    px.append((rgb[o], rgb[o + 1], rgb[o + 2]))
                    o += 3
            out += encode_block(px)
    return bytes(out)


def dds(w, h, payload, fourcc=b"DXT1"):
    """A 128-byte DX9 DDS header + payload. DX9 and not DX10 on purpose: the
    consumer never parses this file -- `tools/maptiles.py` strips the header and
    the manifest records format/width/height -- so the simplest header that any
    external viewer can also open is the right one for debugging."""
    hdr = struct.pack(
        "<8I 11I 13I",
        _DDS_MAGIC, 124,
        _DDSD_CAPS | _DDSD_HEIGHT | _DDSD_WIDTH | _DDSD_PIXELFORMAT | _DDSD_LINEARSIZE,
        h, w, len(payload), 0, 1,
        *([0] * 11),
        32, _DDPF_FOURCC, struct.unpack("<I", fourcc)[0], 0, 0, 0, 0, 0,
        _DDSCAPS_TEXTURE, 0, 0, 0, 0)
    return hdr + payload


DDS_HEADER_BYTES = 128
