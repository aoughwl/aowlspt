"""
Shared helpers for the MicroSplat `Texture2DArray` terrain patch.

A Unity `Texture2DArray` stores its pixels as `depth` consecutive, independent mip
chains -- slice 0's full chain, then slice 1's, and so on. Each chain is the usual
sequence w x h, w/2 x h/2, ... down to 1x1, with every level padded up to whole 4x4
blocks and therefore a 16-byte floor for BC3/DXT5.

Getting that arithmetic wrong would produce a file of exactly the right total length
whose slices are all offset by a few bytes -- garbage that still passes a size check.
So `chain_sizes` is asserted against the game's own `m_DataSize` before anything is
written; see `assert_layout`.

Format note: these arrays report `m_Format = 101`, which is a GraphicsFormat
(`RGBA_DXT5_UNorm`), NOT a TextureFormat. 12 slices x 11 mips of 1024x1024 BC3 comes
to exactly 16,777,536 bytes, which is the reported `m_DataSize`, so DXT5 is measured
here rather than assumed from the enum value.
"""
from __future__ import annotations
import io
from typing import List, Tuple

from PIL import Image

BLOCK_BYTES_DXT5 = 16

# TextureFormat -> bytes per 4x4 block. Only block-compressed formats whose length is
# a pure function of (w, h, mip count) belong here: that is what makes an in-place
# `.resS` overwrite possible at all.
BLOCK_BYTES = {10: 8, 12: 16}          # 10 = DXT1, 12 = DXT5
FMT_NAME = {10: 'DXT1', 12: 'DXT5'}


def mip_dims(w: int, h: int, n: int) -> List[Tuple[int, int]]:
    out = []
    for _ in range(n):
        out.append((w, h))
        w = max(1, w // 2)
        h = max(1, h // 2)
    return out


def level_size_dxt5(w: int, h: int) -> int:
    bw = max(1, (w + 3) // 4)
    bh = max(1, (h + 3) // 4)
    return bw * bh * BLOCK_BYTES_DXT5


def chain_sizes(w: int, h: int, mips: int) -> List[int]:
    return [level_size_dxt5(a, b) for a, b in mip_dims(w, h, mips)]


def chain_bytes(w: int, h: int, mips: int) -> int:
    return sum(chain_sizes(w, h, mips))


def assert_layout(w: int, h: int, mips: int, depth: int, data_size: int) -> int:
    """Return the per-slice byte length, having proved it against m_DataSize."""
    per = chain_bytes(w, h, mips)
    if per * depth != data_size:
        raise SystemExit(
            f'mip arithmetic disagrees with the file: {w}x{h} mips={mips} '
            f'depth={depth} -> {per}*{depth}={per*depth} but m_DataSize={data_size}. '
            f'Refusing: a wrong slice stride writes garbage that still passes a '
            f'size check.')
    return per


def encode_dxt5(img: Image.Image, flip: bool = True) -> bytes:
    """Encode one mip level to DXT5, padding to whole 4x4 blocks."""
    from UnityPy.export import Texture2DConverter
    from UnityPy.enums import TextureFormat
    im = img.convert('RGBA')
    w, h = im.size
    pw, ph = max(4, (w + 3) // 4 * 4), max(4, (h + 3) // 4 * 4)
    if (pw, ph) != (w, h):
        canvas = Image.new('RGBA', (pw, ph))
        canvas.paste(im, (0, 0))
        # replicate edges into the pad so the block encoder is not fitting to black
        if w < pw:
            canvas.paste(im.crop((w - 1, 0, w, h)).resize((pw - w, h)), (w, 0))
        if h < ph:
            canvas.paste(canvas.crop((0, h - 1, pw, h)).resize((pw, ph - h)), (0, h))
        im = canvas
    data, _ = Texture2DConverter.image_to_texture2d(im, TextureFormat.DXT5, flip=flip)
    want = level_size_dxt5(w, h)
    if len(data) != want:
        raise SystemExit(f'DXT5 encode of {w}x{h} gave {len(data)} bytes, want {want}')
    return data


def build_chain(src: Image.Image, w: int, h: int, mips: int) -> bytes:
    """Downscale `src` to w x h and emit the full DXT5 mip chain.

    Downscaling only. `src` is expected to be at least as large as `w x h`; the
    caller picks the ambientCG tier that satisfies that. Upscaling a smaller source
    into a bigger slot is refused by the caller, not silently interpolated here.
    """
    out = bytearray()
    base = src.convert('RGBA')
    for (mw, mh) in mip_dims(w, h, mips):
        lvl = base.resize((mw, mh), Image.LANCZOS) if base.size != (mw, mh) else base
        out += encode_dxt5(lvl)
    return bytes(out)


def decode_dxt5(data: bytes, w: int, h: int) -> Image.Image:
    return decode_bc(data, w, h, 12)


# ---------------------------------------------------------- format-generic API
# The terrain path above is DXT5-only and stays that way; the prefab-surface path
# also has to handle DXT1, so the same arithmetic is repeated here parameterised by
# block size rather than duplicated with a different constant hidden in it.

def level_size(w: int, h: int, fmt: int) -> int:
    bb = BLOCK_BYTES.get(fmt)
    if bb is None:
        raise SystemExit(f'format {fmt} is not block-compressed; refusing')
    return max(1, (w + 3) // 4) * max(1, (h + 3) // 4) * bb


def chain_bytes_fmt(w: int, h: int, mips: int, fmt: int) -> int:
    return sum(level_size(a, b, fmt) for a, b in mip_dims(w, h, mips))


def encode(img: Image.Image, fmt: int, flip: bool = True) -> bytes:
    from UnityPy.export import Texture2DConverter
    from UnityPy.enums import TextureFormat
    tf = {10: TextureFormat.DXT1, 12: TextureFormat.DXT5}[fmt]
    im = img.convert('RGBA')
    w, h = im.size
    pw, ph = max(4, (w + 3) // 4 * 4), max(4, (h + 3) // 4 * 4)
    if (pw, ph) != (w, h):
        canvas = Image.new('RGBA', (pw, ph))
        canvas.paste(im, (0, 0))
        if w < pw:
            canvas.paste(im.crop((w - 1, 0, w, h)).resize((pw - w, h)), (w, 0))
        if h < ph:
            canvas.paste(canvas.crop((0, h - 1, pw, h)).resize((pw, ph - h)), (0, h))
        im = canvas
    data, _ = Texture2DConverter.image_to_texture2d(im, tf, flip=flip)
    want = level_size(w, h, fmt)
    if len(data) != want:
        raise SystemExit(f'{FMT_NAME[fmt]} encode of {w}x{h} gave {len(data)} bytes, '
                         f'want {want}')
    return data


def decode_bc(data: bytes, w: int, h: int, fmt: int) -> Image.Image:
    import texture2ddecoder
    pw, ph = max(4, (w + 3) // 4 * 4), max(4, (h + 3) // 4 * 4)
    dec = {10: texture2ddecoder.decode_bc1, 12: texture2ddecoder.decode_bc3}[fmt]
    im = Image.frombytes('RGBA', (pw, ph), dec(data, pw, ph), 'raw', 'BGRA')
    if (pw, ph) != (w, h):
        im = im.crop((0, 0, w, h))
    return im.transpose(Image.FLIP_TOP_BOTTOM)


def build_chain_fmt(src: Image.Image, w: int, h: int, mips: int, fmt: int,
                    alpha_from: Image.Image | None = None) -> bytes:
    """Full mip chain at `fmt`, optionally keeping an ORIGINAL's alpha channel.

    `alpha_from` exists because a great many of these slots are alpha-cut cards --
    foliage, fences, grates. An ambientCG `_Color` map is fully opaque, so pasting it
    whole turns a chain-link fence into a solid metal panel. RGB is replaced; alpha
    is the original's, resampled per mip level alongside it.
    """
    out = bytearray()
    base = src.convert('RGBA')
    ab = alpha_from.convert('RGBA').split()[3] if alpha_from is not None else None
    for (mw, mh) in mip_dims(w, h, mips):
        lvl = base.resize((mw, mh), Image.LANCZOS) if base.size != (mw, mh) else base
        if ab is not None:
            lvl = lvl.copy()
            lvl.putalpha(ab.resize((mw, mh), Image.LANCZOS))
        out += encode(lvl, fmt)
    return bytes(out)
