"""svgraster -- a pure-stdlib SVG rasteriser for the map art in mods/maps/data/maps.

WHY THIS EXISTS AT ALL, since writing a rasteriser is normally the wrong answer.

The map art this project ships is SVG. The overlay's region ABI takes RASTER
(`AOWL_REGION_CMD_QUAD` + `aowl_region_texture_define`, ABI 2). Something has to
bridge those, and the only two places it can happen are:

  * at DRAW time, inside the game's `Present` hook -- an SVG parser and scanline
    filler on the render thread, per frame. That is what `mods/maps/maps.nim`
    correctly refused to do, and its refusal is still right.
  * OFFLINE, at build time, emitting tiles the game only has to `memcpy`.

This is the second one. Nothing here ever runs in the client. It runs on a
developer's machine, its output is committed, and the client's hot path sees
block-compressed bytes and a JSON manifest.

WHY NOT cairosvg / Pillow / resvg. MEASURED on this machine 2026-08-28: the only
Python on PATH is the msys2 UCRT build, which has **no pip** (`No module named
pip`), and the CPython under AppData is an empty leftover holding only `Lib`.
`resvg`, `rsvg-convert`, `inkscape` and ImageMagick are all absent; the `convert`
that IS on PATH is Windows' FAT-to-NTFS utility, not ImageMagick. So there was no
rasteriser to call, and adding one would have meant a machine-global `pacman`
install standing between this repo and a build. Stdlib it is.

WHAT SUBSET IS SUPPORTED, and it is not a guess -- it is the measured vocabulary
of all 36 shipped SVGs:

    4386 <path>   385 <polygon>   265 <g>   201 <rect>
      42 <line>    36 <svg>        30 <style> 28 <defs>
      24 <polyline> 16 <circle>     1 <pattern>

  * `<style>` blocks with plain `.class { prop: value; }` rules (the Illustrator
    export shape), plus presentation attributes and inline `style=`.
  * `transform=` -- the shipped art uses only `translate(...)` (124 occurrences,
    zero of anything else), but `scale`, `rotate` and `matrix` are implemented
    too so that a future map does not fail silently.
  * path commands M L H V C S Q T A Z in both cases (absolute and relative).
  * `<pattern>` is NOT resolved. There is exactly one in the corpus. A paint that
    references a pattern is rendered as its `fallbackColor` and the fact is
    COUNTED and REPORTED, never silently dropped -- see `RasterStats.patterns`.

EVERY UNSUPPORTED THING IS COUNTED. `RasterStats` carries `unknownElements`,
`unknownCommands`, `patterns` and `badPaints`. The caller prints them. A
rasteriser that quietly skipped a quarter of a map would produce art that looks
plausible and is wrong, which is precisely the failure mode this repo keeps
paying for -- so "I did not draw that" is a number, not a shrug.

ANTI-ALIASING is 3x3 supersampling followed by a box downsample. That is chosen
rather than analytic coverage because it is ~40 lines instead of ~400 and it is
obviously correct; the cost is offline time, which nobody is waiting on.
"""

import math
import re
import xml.etree.ElementTree as ET

SVG_NS = "{http://www.w3.org/2000/svg}"

# ---------------------------------------------------------------- colour

# The subset of SVG named colours the corpus actually uses, plus the common ones.
# A name that is NOT here is a counted `badPaint`, not a silent black.
NAMED = {
    "none": None,
    "black": (0, 0, 0), "white": (255, 255, 255), "gold": (255, 215, 0),
    "red": (255, 0, 0), "green": (0, 128, 0), "blue": (0, 0, 255),
    "gray": (128, 128, 128), "grey": (128, 128, 128),
    "silver": (192, 192, 192), "yellow": (255, 255, 0),
    "orange": (255, 165, 0), "brown": (165, 42, 42),
    "darkgray": (169, 169, 169), "darkgrey": (169, 169, 169),
    "lightgray": (211, 211, 211), "lightgrey": (211, 211, 211),
    "cyan": (0, 255, 255), "magenta": (255, 0, 255),
    "purple": (128, 0, 128), "navy": (0, 0, 128), "teal": (0, 128, 128),
    "olive": (128, 128, 0), "maroon": (128, 0, 0), "lime": (0, 255, 0),
    "pink": (255, 192, 203), "tan": (210, 180, 140),
    "beige": (245, 245, 220), "khaki": (240, 230, 140),
    "transparent": None,
}


def _opacity(s):
    """An opacity / fill-opacity / stroke-opacity value -> a float in [0,1].
    Absent or unparseable reads as fully opaque (1.0), which is SVG's initial
    value and the safe default: a bad opacity must never silently blank a shape.
    A trailing '%' is honoured."""
    if s is None:
        return 1.0
    s = s.strip().lower()
    if not s:
        return 1.0
    try:
        if s.endswith("%"):
            v = float(s[:-1]) / 100.0
        else:
            v = float(s)
    except ValueError:
        return 1.0
    return max(0.0, min(1.0, v))


def parse_color(s, stats):
    """-> (r,g,b) or None for 'no paint'. An unrecognised paint is COUNTED."""
    if s is None:
        return None
    s = s.strip().lower()
    if not s:
        return None
    if s.startswith("url("):
        # A pattern/gradient reference. Counted; the caller substitutes a
        # fallback so the shape is still visible rather than invisible.
        stats.patterns += 1
        return "PATTERN"
    if s.startswith("#"):
        h = s[1:]
        if len(h) == 3:
            return (int(h[0] * 2, 16), int(h[1] * 2, 16), int(h[2] * 2, 16))
        if len(h) == 6:
            return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16))
        stats.badPaints.add(s)
        return None
    if s.startswith("rgb("):
        try:
            parts = [p.strip() for p in s[4:].rstrip(")").split(",")]
            out = []
            for p in parts[:3]:
                if p.endswith("%"):
                    out.append(int(float(p[:-1]) * 255.0 / 100.0))
                else:
                    out.append(int(float(p)))
            return tuple(max(0, min(255, v)) for v in out)
        except Exception:
            stats.badPaints.add(s)
            return None
    if s in NAMED:
        return NAMED[s]
    stats.badPaints.add(s)
    return None


# ---------------------------------------------------------------- transforms

def mat_mul(a, b):
    """2x3 affine compose: apply b, then a. (a,b,c,d,e,f) = [[a c e],[b d f]]."""
    a0, a1, a2, a3, a4, a5 = a
    b0, b1, b2, b3, b4, b5 = b
    return (a0 * b0 + a2 * b1,
            a1 * b0 + a3 * b1,
            a0 * b2 + a2 * b3,
            a1 * b2 + a3 * b3,
            a0 * b4 + a2 * b5 + a4,
            a1 * b4 + a3 * b5 + a5)


IDENT = (1.0, 0.0, 0.0, 1.0, 0.0, 0.0)


def mat_apply(m, x, y):
    return (m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5])


_XF_RE = re.compile(r"([a-zA-Z]+)\s*\(([^)]*)\)")
_NUM_RE = re.compile(r"[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?")


def parse_transform(s, stats):
    if not s:
        return IDENT
    m = IDENT
    for name, args in _XF_RE.findall(s):
        v = [float(t) for t in _NUM_RE.findall(args)]
        name = name.strip().lower()
        if name == "translate":
            t = (1.0, 0.0, 0.0, 1.0, v[0] if v else 0.0,
                 v[1] if len(v) > 1 else 0.0)
        elif name == "scale":
            sx = v[0] if v else 1.0
            sy = v[1] if len(v) > 1 else sx
            t = (sx, 0.0, 0.0, sy, 0.0, 0.0)
        elif name == "rotate":
            a = math.radians(v[0] if v else 0.0)
            c, s2 = math.cos(a), math.sin(a)
            t = (c, s2, -s2, c, 0.0, 0.0)
            if len(v) >= 3:
                t = mat_mul(mat_mul((1, 0, 0, 1, v[1], v[2]), t),
                            (1, 0, 0, 1, -v[1], -v[2]))
        elif name == "matrix" and len(v) >= 6:
            t = tuple(v[:6])
        elif name == "skewx":
            t = (1.0, 0.0, math.tan(math.radians(v[0])), 1.0, 0.0, 0.0)
        elif name == "skewy":
            t = (1.0, math.tan(math.radians(v[0])), 0.0, 1.0, 0.0, 0.0)
        else:
            stats.unknownTransforms.add(name)
            continue
        m = mat_mul(m, t)
    return m


# ---------------------------------------------------------------- path parsing

_CMD_RE = re.compile(r"([MmZzLlHhVvCcSsQqTtAa])|([-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?)")


def _tokenise(d):
    for cmd, num in _CMD_RE.findall(d):
        yield ("c", cmd) if cmd else ("n", float(num))


def _bezier3(p0, p1, p2, p3, n):
    out = []
    for i in range(1, n + 1):
        t = i / float(n)
        u = 1.0 - t
        out.append((u * u * u * p0[0] + 3 * u * u * t * p1[0]
                    + 3 * u * t * t * p2[0] + t * t * t * p3[0],
                    u * u * u * p0[1] + 3 * u * u * t * p1[1]
                    + 3 * u * t * t * p2[1] + t * t * t * p3[1]))
    return out


def _bezier2(p0, p1, p2, n):
    out = []
    for i in range(1, n + 1):
        t = i / float(n)
        u = 1.0 - t
        out.append((u * u * p0[0] + 2 * u * t * p1[0] + t * t * p2[0],
                    u * u * p0[1] + 2 * u * t * p1[1] + t * t * p2[1]))
    return out


def _arc(p0, rx, ry, phi, large, sweep, p1, n):
    """Endpoint-parameterised elliptical arc -> polyline. SVG F.6.5 verbatim."""
    if rx == 0 or ry == 0 or (abs(p0[0] - p1[0]) < 1e-12 and abs(p0[1] - p1[1]) < 1e-12):
        return [p1]
    rx, ry = abs(rx), abs(ry)
    phi = math.radians(phi)
    cp, sp = math.cos(phi), math.sin(phi)
    dx2 = (p0[0] - p1[0]) / 2.0
    dy2 = (p0[1] - p1[1]) / 2.0
    x1p = cp * dx2 + sp * dy2
    y1p = -sp * dx2 + cp * dy2
    lam = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
    if lam > 1.0:
        s = math.sqrt(lam)
        rx *= s
        ry *= s
    num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
    den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
    co = math.sqrt(max(0.0, num / den)) if den else 0.0
    if large == sweep:
        co = -co
    cxp = co * rx * y1p / ry
    cyp = -co * ry * x1p / rx
    cx = cp * cxp - sp * cyp + (p0[0] + p1[0]) / 2.0
    cy = sp * cxp + cp * cyp + (p0[1] + p1[1]) / 2.0

    def ang(ux, uy, vx, vy):
        d = math.sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
        if d == 0:
            return 0.0
        c = max(-1.0, min(1.0, (ux * vx + uy * vy) / d))
        a = math.acos(c)
        return -a if (ux * vy - uy * vx) < 0 else a

    th1 = ang(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
    dth = ang((x1p - cxp) / rx, (y1p - cyp) / ry,
              (-x1p - cxp) / rx, (-y1p - cyp) / ry)
    if not sweep and dth > 0:
        dth -= 2 * math.pi
    elif sweep and dth < 0:
        dth += 2 * math.pi
    out = []
    for i in range(1, n + 1):
        t = th1 + dth * (i / float(n))
        out.append((cx + rx * math.cos(t) * cp - ry * math.sin(t) * sp,
                    cy + rx * math.cos(t) * sp + ry * math.sin(t) * cp))
    return out


def path_to_subpaths(d, curve_steps, stats):
    """SVG `d` -> [(points, closed), ...] in USER space.

    `closed` is tracked separately from "first point == last point" because a
    fill treats every subpath as closed while a STROKE must not draw the closing
    segment of an open one -- and conflating those draws a spurious line across
    every open path, which reads as a map feature.
    """
    toks = list(_tokenise(d))
    i, n = 0, len(toks)
    subs = []
    pts = []
    closed = False
    cur = (0.0, 0.0)
    start = (0.0, 0.0)
    prev_c2 = None
    prev_q1 = None
    cmd = None

    def flush():
        nonlocal pts, closed
        if len(pts) >= 2:
            subs.append((pts, closed))
        pts = []
        closed = False

    while i < n:
        k, v = toks[i]
        if k == "c":
            cmd = v
            i += 1
            if cmd in "Zz":
                if pts:
                    closed = True
                    flush()
                cur = start
                prev_c2 = prev_q1 = None
                continue
        if cmd is None:
            i += 1
            continue

        def nums(count):
            nonlocal i
            out = []
            for _ in range(count):
                if i < n and toks[i][0] == "n":
                    out.append(toks[i][1])
                    i += 1
                else:
                    out.append(0.0)
            return out

        rel = cmd.islower()
        C = cmd.upper()
        if C == "M":
            x, y = nums(2)
            if rel:
                x, y = cur[0] + x, cur[1] + y
            flush()
            cur = start = (x, y)
            pts = [cur]
            # An implicit run after M is L (l for m).
            cmd = "l" if rel else "L"
            prev_c2 = prev_q1 = None
        elif C == "L":
            x, y = nums(2)
            if rel:
                x, y = cur[0] + x, cur[1] + y
            cur = (x, y)
            pts.append(cur)
            prev_c2 = prev_q1 = None
        elif C == "H":
            (x,) = nums(1)
            if rel:
                x = cur[0] + x
            cur = (x, cur[1])
            pts.append(cur)
            prev_c2 = prev_q1 = None
        elif C == "V":
            (y,) = nums(1)
            if rel:
                y = cur[1] + y
            cur = (cur[0], y)
            pts.append(cur)
            prev_c2 = prev_q1 = None
        elif C == "C":
            x1, y1, x2, y2, x, y = nums(6)
            if rel:
                x1, y1 = cur[0] + x1, cur[1] + y1
                x2, y2 = cur[0] + x2, cur[1] + y2
                x, y = cur[0] + x, cur[1] + y
            pts.extend(_bezier3(cur, (x1, y1), (x2, y2), (x, y), curve_steps))
            prev_c2 = (x2, y2)
            prev_q1 = None
            cur = (x, y)
        elif C == "S":
            x2, y2, x, y = nums(4)
            if rel:
                x2, y2 = cur[0] + x2, cur[1] + y2
                x, y = cur[0] + x, cur[1] + y
            c1 = (2 * cur[0] - prev_c2[0], 2 * cur[1] - prev_c2[1]) if prev_c2 else cur
            pts.extend(_bezier3(cur, c1, (x2, y2), (x, y), curve_steps))
            prev_c2 = (x2, y2)
            prev_q1 = None
            cur = (x, y)
        elif C == "Q":
            x1, y1, x, y = nums(4)
            if rel:
                x1, y1 = cur[0] + x1, cur[1] + y1
                x, y = cur[0] + x, cur[1] + y
            pts.extend(_bezier2(cur, (x1, y1), (x, y), curve_steps))
            prev_q1 = (x1, y1)
            prev_c2 = None
            cur = (x, y)
        elif C == "T":
            x, y = nums(2)
            if rel:
                x, y = cur[0] + x, cur[1] + y
            c1 = (2 * cur[0] - prev_q1[0], 2 * cur[1] - prev_q1[1]) if prev_q1 else cur
            pts.extend(_bezier2(cur, c1, (x, y), curve_steps))
            prev_q1 = c1
            prev_c2 = None
            cur = (x, y)
        elif C == "A":
            rx, ry, rot, la, sw, x, y = nums(7)
            if rel:
                x, y = cur[0] + x, cur[1] + y
            pts.extend(_arc(cur, rx, ry, rot, int(la) != 0, int(sw) != 0,
                            (x, y), max(curve_steps, 8)))
            cur = (x, y)
            prev_c2 = prev_q1 = None
        else:
            stats.unknownCommands.add(cmd)
            i += 1
    flush()
    return subs


# ---------------------------------------------------------------- the canvas

class Canvas:
    """RGB byte canvas with an origin and a uniform scale. No alpha channel.

    Alpha is deliberately absent. The quad the client draws carries a per-quad
    TINT with an alpha byte, so the map's translucency against the game is a
    draw-time decision made by `mods/maps/sp/hud.nim`, not baked into the art.
    Baking it would also have forced BC3 over BC1 and doubled every byte shipped.
    """

    __slots__ = ("w", "h", "buf")

    def __init__(self, w, h, bg):
        self.w = w
        self.h = h
        self.buf = bytearray(bytes(bg) * (w * h))

    def fill_polys(self, polys, rgb, evenodd, alpha=1.0):
        """Scanline-fill a set of subpaths as ONE shape (so holes work).

        `alpha` is the effective paint opacity (opacity * fill-opacity, or the
        stroke equivalent). At alpha >= 1 this is the original opaque write --
        byte-for-byte, so opaque art is unchanged. Below 1 each covered texel is
        SRC-OVER composited onto what is already there: dst = src*a + dst*(1-a).
        This is why the Woods no-go zones -- declared `fill-opacity: .4` in the
        source SVG and previously painted SOLID RED -- now bake as a translucent
        red tint over the terrain. There is no alpha channel to carry forward
        (the canvas is opaque RGB); the blend is resolved against the current
        canvas at draw time, so ORDER matters and these overlays must be drawn
        after the terrain they tint, which the SVG document order already is."""
        edges = []
        ymin, ymax = 1e30, -1e30
        for pts in polys:
            m = len(pts)
            if m < 3:
                continue
            for j in range(m):
                x0, y0 = pts[j]
                x1, y1 = pts[(j + 1) % m]
                if y0 == y1:
                    continue
                edges.append((y0, y1, x0, x1))
                ymin = min(ymin, y0, y1)
                ymax = max(ymax, y0, y1)
        if not edges:
            return
        if alpha <= 0.0:
            return
        y0i = max(0, int(math.floor(ymin)))
        y1i = min(self.h - 1, int(math.ceil(ymax)))
        r, g, b = rgb
        buf = self.buf
        W = self.w
        # Integer 0..256 blend weight; 256 is the opaque fast path.
        ai = 256 if alpha >= 1.0 else max(0, min(256, int(alpha * 256.0 + 0.5)))
        na = 256 - ai
        for y in range(y0i, y1i + 1):
            sy = y + 0.5
            xs = []
            for (ey0, ey1, ex0, ex1) in edges:
                if (ey0 <= sy < ey1) or (ey1 <= sy < ey0):
                    t = (sy - ey0) / (ey1 - ey0)
                    xs.append((ex0 + t * (ex1 - ex0), 1 if ey1 > ey0 else -1))
            if not xs:
                continue
            xs.sort()
            spans = []
            if evenodd:
                for k in range(0, len(xs) - 1, 2):
                    spans.append((xs[k][0], xs[k + 1][0]))
            else:
                wind = 0
                sx = 0.0
                for (x, d) in xs:
                    if wind == 0:
                        sx = x
                    wind += d
                    if wind == 0:
                        spans.append((sx, x))
            base = y * W * 3
            for (sa, sb) in spans:
                a = max(0, int(math.ceil(sa - 0.5)))
                bb = min(W - 1, int(math.floor(sb - 0.5)))
                if ai >= 256:
                    for x in range(a, bb + 1):
                        o = base + x * 3
                        buf[o] = r
                        buf[o + 1] = g
                        buf[o + 2] = b
                else:
                    for x in range(a, bb + 1):
                        o = base + x * 3
                        buf[o] = (r * ai + buf[o] * na) >> 8
                        buf[o + 1] = (g * ai + buf[o + 1] * na) >> 8
                        buf[o + 2] = (b * ai + buf[o + 2] * na) >> 8

    def stroke(self, pts, closed, rgb, width, alpha=1.0):
        """Stroke as a run of quads plus a square join at each vertex.

        Not a real join/cap model. At the widths in this art (fractions of a
        user unit, supersampled) the difference is sub-pixel, and a correct
        miter solver would be another 150 lines for no visible change.
        """
        hw = max(width, 1e-6) * 0.5
        m = len(pts)
        if m < 2:
            return
        last = m if closed else m - 1
        for j in range(last):
            x0, y0 = pts[j]
            x1, y1 = pts[(j + 1) % m]
            dx, dy = x1 - x0, y1 - y0
            L = math.hypot(dx, dy)
            if L < 1e-9:
                continue
            nx, ny = -dy / L * hw, dx / L * hw
            self.fill_polys([[(x0 + nx, y0 + ny), (x1 + nx, y1 + ny),
                              (x1 - nx, y1 - ny), (x0 - nx, y0 - ny)]],
                            rgb, False, alpha)
        if hw > 0.6:
            for (x, y) in pts:
                self.fill_polys([[(x - hw, y - hw), (x + hw, y - hw),
                                  (x + hw, y + hw), (x - hw, y + hw)]],
                                rgb, False, alpha)

    def downsample(self, ss):
        """ss x ss box downsample -> a new Canvas. This IS the anti-aliasing."""
        ow, oh = self.w // ss, self.h // ss
        out = Canvas(ow, oh, (0, 0, 0))
        src, dst, W = self.buf, out.buf, self.w
        inv = 1.0 / (ss * ss)
        for y in range(oh):
            for x in range(ow):
                r = g = b = 0
                for sy in range(ss):
                    row = ((y * ss + sy) * W + x * ss) * 3
                    for sx in range(ss):
                        o = row + sx * 3
                        r += src[o]
                        g += src[o + 1]
                        b += src[o + 2]
                o = (y * ow + x) * 3
                dst[o] = int(r * inv)
                dst[o + 1] = int(g * inv)
                dst[o + 2] = int(b * inv)
        return out


# ---------------------------------------------------------------- stats

class RasterStats:
    def __init__(self):
        self.shapes = 0
        self.fills = 0
        self.strokes = 0
        self.patterns = 0
        self.unknownElements = set()
        self.unknownCommands = set()
        self.unknownTransforms = set()
        self.badPaints = set()

    def problems(self):
        """The one string a caller prints. Empty means genuinely nothing was
        skipped -- not 'I did not look'."""
        out = []
        if self.unknownElements:
            out.append("elements not drawn: " + ",".join(sorted(self.unknownElements)))
        if self.unknownCommands:
            out.append("path cmds ignored: " + ",".join(sorted(self.unknownCommands)))
        if self.unknownTransforms:
            out.append("transforms ignored: " + ",".join(sorted(self.unknownTransforms)))
        if self.badPaints:
            out.append("paints unparsed: " + ",".join(sorted(self.badPaints)[:6]))
        if self.patterns:
            out.append("%d pattern/gradient paints drawn as fallback" % self.patterns)
        return "; ".join(out)


# ---------------------------------------------------------------- CSS

_RULE_RE = re.compile(r"([^{}]+)\{([^{}]*)\}")


def parse_css(text):
    out = {}
    for sel, body in _RULE_RE.findall(text or ""):
        props = {}
        for decl in body.split(";"):
            if ":" in decl:
                k, v = decl.split(":", 1)
                props[k.strip().lower()] = v.strip()
        for s in sel.split(","):
            s = s.strip()
            if s.startswith("."):
                out.setdefault(s[1:], {}).update(props)
    return out


def _style_attr(s):
    props = {}
    for decl in (s or "").split(";"):
        if ":" in decl:
            k, v = decl.split(":", 1)
            props[k.strip().lower()] = v.strip()
    return props


# ---------------------------------------------------------------- the walk

_SHAPES = ("path", "polygon", "polyline", "rect", "line", "circle", "ellipse")
_SKIP = ("defs", "style", "title", "desc", "metadata", "pattern",
         "lineargradient", "radialgradient", "clippath", "mask", "filter",
         "symbol", "marker")


def _tag(el):
    t = el.tag
    if t.startswith("{"):
        t = t.split("}", 1)[1]
    return t.lower()


def _shape_subpaths(el, tag, curve_steps, stats):
    """-> [(points, closed)] in USER space, or None if the element is not art."""
    g = el.get
    if tag == "path":
        d = g("d")
        return path_to_subpaths(d, curve_steps, stats) if d else []
    if tag in ("polygon", "polyline"):
        v = [float(t) for t in _NUM_RE.findall(g("points") or "")]
        pts = list(zip(v[0::2], v[1::2]))
        return [(pts, tag == "polygon")] if len(pts) >= 2 else []
    if tag == "rect":
        x = float(g("x") or 0)
        y = float(g("y") or 0)
        w = float(g("width") or 0)
        h = float(g("height") or 0)
        if w <= 0 or h <= 0:
            return []
        return [([(x, y), (x + w, y), (x + w, y + h), (x, y + h)], True)]
    if tag == "line":
        return [([(float(g("x1") or 0), float(g("y1") or 0)),
                  (float(g("x2") or 0), float(g("y2") or 0))], False)]
    if tag in ("circle", "ellipse"):
        cx = float(g("cx") or 0)
        cy = float(g("cy") or 0)
        if tag == "circle":
            rx = ry = float(g("r") or 0)
        else:
            rx = float(g("rx") or 0)
            ry = float(g("ry") or 0)
        if rx <= 0 or ry <= 0:
            return []
        n = max(12, curve_steps * 4)
        pts = [(cx + rx * math.cos(2 * math.pi * i / n),
                cy + ry * math.sin(2 * math.pi * i / n)) for i in range(n)]
        return [(pts, True)]
    return None


def render(svg_text, width, height, bg=(20, 24, 30), supersample=3,
           curve_steps=8, fallback_rgb=(120, 124, 130), stats=None):
    """Rasterise `svg_text` into a `width` x `height` RGB Canvas.

    The whole viewBox is mapped onto the whole output, PRESERVING NOTHING about
    aspect. That is deliberate and it is what the calibration requires: a
    layer's `imageBounds` rectangle is declared to be exactly what the art
    covers, so the art must be stretched onto that rectangle. Letterboxing here
    would put a border inside the world rect and slide every feature.
    """
    stats = stats if stats is not None else RasterStats()
    root = ET.fromstring(svg_text)

    vb = root.get("viewBox")
    if vb:
        v = [float(t) for t in _NUM_RE.findall(vb)]
        vx, vy, vw, vh = v[0], v[1], v[2], v[3]
    else:
        vw = float(_NUM_RE.findall(root.get("width") or "100")[0])
        vh = float(_NUM_RE.findall(root.get("height") or "100")[0])
        vx = vy = 0.0
    if vw <= 0 or vh <= 0:
        raise ValueError("svg has a degenerate viewBox")

    ss = max(1, int(supersample))
    cv = Canvas(width * ss, height * ss, bg)
    base = mat_mul(((width * ss) / vw, 0.0, 0.0, (height * ss) / vh, 0.0, 0.0),
                   (1.0, 0.0, 0.0, 1.0, -vx, -vy))

    css = {}
    for el in root.iter():
        if _tag(el) == "style":
            css.update(parse_css("".join(el.itertext())))

    # Stroke widths must scale with the transform, so the walk carries the
    # accumulated uniform scale alongside the matrix.
    def scale_of(m):
        return math.sqrt(abs(m[0] * m[3] - m[1] * m[2])) or 1.0

    def props_of(el, inherited):
        p = dict(inherited)
        cls = el.get("class")
        if cls:
            for c in cls.split():
                p.update(css.get(c, {}))
        for k in ("fill", "stroke", "stroke-width", "fill-rule", "display",
                  "opacity", "fill-opacity", "stroke-opacity"):
            v = el.get(k)
            if v is not None:
                p[k] = v
        p.update(_style_attr(el.get("style")))
        return p

    def walk(el, m, inherited):
        tag = _tag(el)
        if tag in _SKIP:
            return
        p = props_of(el, inherited)
        m2 = mat_mul(m, parse_transform(el.get("transform"), stats))
        if (p.get("display") or "").strip().lower() == "none":
            return
        if tag in ("g", "svg", "a"):
            for ch in el:
                walk(ch, m2, p)
            return
        subs = _shape_subpaths(el, tag, curve_steps, stats)
        if subs is None:
            stats.unknownElements.add(tag)
            return
        if not subs:
            return
        stats.shapes += 1

        dev = [([mat_apply(m2, x, y) for (x, y) in pts], cl) for (pts, cl) in subs]

        # SVG's initial fill is black. An element with no fill declared anywhere
        # is therefore FILLED, not skipped -- getting this wrong empties a map.
        # OPACITY. `props_of` already collected opacity / fill-opacity /
        # stroke-opacity; before this they were read and then DROPPED, so a
        # `fill-opacity: .4` overlay was baked SOLID -- the Woods no-go zones
        # coming out as opaque red blobs was exactly this. The element `opacity`
        # multiplies both paints; the per-paint opacity applies to its own paint.
        op = _opacity(p.get("opacity"))
        fillA = op * _opacity(p.get("fill-opacity"))
        strokeA = op * _opacity(p.get("stroke-opacity"))

        fspec = p.get("fill", "black")
        fill = parse_color(fspec, stats)
        if fill == "PATTERN":
            fill = fallback_rgb
        if fill is not None and fillA > 0.0:
            evenodd = (p.get("fill-rule", "nonzero").strip().lower() == "evenodd")
            cv.fill_polys([pts for (pts, _) in dev], fill, evenodd, fillA)
            stats.fills += 1

        stroke = parse_color(p.get("stroke"), stats)
        if stroke == "PATTERN":
            stroke = fallback_rgb
        if stroke is not None and strokeA > 0.0:
            try:
                sw = float(_NUM_RE.findall(p.get("stroke-width", "1"))[0])
            except Exception:
                sw = 1.0
            sw *= scale_of(m2)
            for (pts, cl) in dev:
                cv.stroke(pts, cl, stroke, max(sw, 0.9), strokeA)
            stats.strokes += 1

    walk(root, base, {})
    return (cv.downsample(ss) if ss > 1 else cv), stats
