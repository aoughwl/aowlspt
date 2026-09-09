"""maptiles -- the BUILD STEP that turns mods/maps' SVG map art into GPU tiles.

    python tools/maptiles.py build   [--maps A,B] [--px N] [--grid N] [--jobs N]
    python tools/maptiles.py selftest
    python tools/maptiles.py verify
    python tools/maptiles.py size

Run as `aowl build maptiles`. Nothing here executes in the client.

------------------------------------------------------------------ the problem
`mods/maps/data/maps/` holds 36 layer SVGs plus per-map calibration (bounds,
imageBounds, gameBounds, coordinateRotation). The overlay region draws textured
quads (`AOWL_REGION_CMD_QUAD`, ABI 2) out of a 32-slot x 1 MiB tile cache. SVG is
not a texture. `mods/maps/maps.nim` used to argue from this that the map had to
be a browser page, because the alternative was "an SVG rasteriser in C inside the
game's Present hook". That inference was sound and its premise was that
rasterising happens at DRAW time. It does not have to. This rasterises once,
offline, and the client memcpys blocks.

------------------------------------------------------------------ the output
    mods/maps/data/maptiles/manifest.json
    mods/maps/data/maptiles/<mapId>/<layerSlug>/z0_<col>x<row>.dds

The manifest is the ONLY thing the mod parses. For each layer it records the
tile grid, and for each tile the WORLD-PLANE RECT it covers -- precomputed here
from `imageBounds`, so the client does no calibration arithmetic beyond a lerp,
and so a wrong transform is falsifiable offline against a number in a file
rather than only against a screenshot.

------------------------------------------------------------ the transform, once
Taken verbatim from `mods/maps/sp/page.nim`'s derivation (which cites the
DynamicMaps fork's own `MathUtils.ConvertToMapPosition` and `Plugin/README.md`);
it is NOT re-derived here:

  1. world (x, y, z) -> map plane (x, z), height y.
  2. imageBounds Min/Max is the map-plane rect the layer art covers. SVG y
     points DOWN while map +y points UP, so imageY = Max.y - mapY.
  3. coordinateRotation rotates the whole container -- art AND markers together
     -- about the centre of the bounds. Because it moves both, it changes which
     way is up ON SCREEN and changes NOTHING about art-to-marker registration.
     So it is neither baked into these pixels nor applied by the client: it is
     copied into the manifest, checked against the calibration by `verify`, and
     `mods/maps/sp/mapart.h` documents why it is deliberately unused.
  4. gameBounds boxes are in MAP-PLANE coordinates with z as HEIGHT.

Point 3 is the one worth restating: baking rotation into the raster WOULD have
rotated the art and not the blips, and the result looks like a map.

--------------------------------------------------------------- what tiles cost
Per layer the art is rasterised once at `grid*px` square and cut into
`grid x grid` tiles of `px` x `px`. Defaults px=512, grid=2 -> a 1024px layer in
4 tiles of 128 KiB each (BC1 is 0.5 B/texel).

Against the cache bound of 32 slots x 1 MiB: one tile occupies one slot whatever
its size, so the binding constraint is the TILE COUNT, not the byte count. A
2x2 grid means a layer is at most 4 slots and the whole visible set is always
resident -- there is nothing to thrash. `--grid 4` (16 tiles) still fits. The
manifest records `slotsNeeded` per layer and `build` REFUSES a grid whose tile
count exceeds `AOWL_REGION_TEX_MAX`, rather than emitting art the client can
only ever partly show.
"""

import argparse
import json
import math
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bc1                      # noqa: E402
import svgraster                # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(REPO, "mods", "maps", "data", "maps")
OUT = os.path.join(REPO, "mods", "maps", "data", "maptiles")

# Mirrors abi/aowlspt_region.h. Kept as named constants and CHECKED, because a
# build that silently emits 40 tiles for a 32-slot cache produces a map with
# holes in it at runtime and no error anywhere.
TEX_MAX = 32
SLOT_BYTES = 1 << 20

SCHEMA = "aowlspt.maptiles/1"
BG = (18, 22, 28)


def slug(s):
    return re.sub(r"[^A-Za-z0-9]+", "_", s).strip("_")


def load_index():
    with open(os.path.join(SRC, "index.json"), "r", encoding="utf-8") as f:
        return json.load(f)


def load_map(map_id):
    with open(os.path.join(SRC, map_id + ".json"), "r", encoding="utf-8") as f:
        return json.load(f)


def tile_world_rect(ib, cols, rows, col, row):
    """The map-plane rect a tile covers.

    Columns run with +x. Rows run DOWNWARD in image space, and map +y points UP,
    so row 0 is the TOP of the image and therefore the HIGH-y end of the world
    rect. That inversion is the same one `mm_tile_index` in
    `mods/maps/sp/mapmath.h` already encodes (`r = (rows-1) - floor(...)`), and
    the two must agree or every tile lands mirrored vertically -- which still
    looks like a map. `verify` asserts they agree.
    """
    x0, x1 = float(ib["Min"]["x"]), float(ib["Max"]["x"])
    y0, y1 = float(ib["Min"]["y"]), float(ib["Max"]["y"])
    if x1 < x0:
        x0, x1 = x1, x0
    if y1 < y0:
        y0, y1 = y1, y0
    tw = (x1 - x0) / cols
    th = (y1 - y0) / rows
    return {
        "minX": x0 + col * tw,
        "maxX": x0 + (col + 1) * tw,
        # row 0 is the top of the image = the HIGH y edge of the world rect
        "maxY": y1 - row * th,
        "minY": y1 - (row + 1) * th,
    }


def build(map_ids=None, px=512, grid=2, verbose=True):
    if grid * grid > TEX_MAX:
        raise SystemExit(
            "REFUSED: grid %d gives %d tiles per layer, but the region tile "
            "cache is %d slots (AOWL_REGION_TEX_MAX). A layer that cannot be "
            "fully resident would draw with holes and report nothing."
            % (grid, grid * grid, TEX_MAX))
    if px % 4:
        raise SystemExit("REFUSED: --px must be a multiple of 4 (BC1 blocks)")
    tile_bytes = px * px // 2
    if tile_bytes > SLOT_BYTES:
        raise SystemExit(
            "REFUSED: a %dx%d BC1 tile is %d bytes, over the %d-byte slot "
            "(AOWL_REGION_TEX_SLOT_BYTES); define would return TEXBIG."
            % (px, px, tile_bytes, SLOT_BYTES))

    idx = load_index()
    wanted = set(map_ids) if map_ids else None
    manifest = {
        "schema": SCHEMA,
        "generator": "tools/maptiles.py",
        "tilePx": px,
        "grid": grid,
        "format": "BC1",
        "colorSpace": "srgb",
        "tileBytes": tile_bytes,
        "texMax": TEX_MAX,
        "slotBytes": SLOT_BYTES,
        "maps": [],
    }
    total_bytes = 0
    problems = []
    t_all = time.time()

    for entry in idx["maps"]:
        mid = entry["id"]
        if wanted and mid not in wanted:
            continue
        cal = load_map(mid)
        layers = cal.get("layers") or {}
        mrec = {
            "id": mid,
            "displayName": cal.get("displayName", mid),
            "internalNames": cal.get("internalNames", []),
            "coordinateRotation": cal.get("coordinateRotation", 0),
            "bounds": cal.get("bounds"),
            "defaultLevel": cal.get("defaultLevel", 0),
            "layers": [],
        }
        for lname, L in layers.items():
            img = L.get("image")
            if not img:
                problems.append("%s/%s has no image" % (mid, lname))
                continue
            svg_path = os.path.join(SRC, img.replace("/", os.sep))
            if not os.path.isfile(svg_path):
                problems.append("%s/%s: missing %s" % (mid, lname, img))
                continue
            ib = L.get("imageBounds") or cal.get("bounds")
            if not ib:
                problems.append("%s/%s has no imageBounds and the map has no "
                                "bounds" % (mid, lname))
                continue

            t0 = time.time()
            with open(svg_path, "r", encoding="utf-8") as f:
                svg_text = f.read()
            full = px * grid
            canvas, st = svgraster.render(svg_text, full, full, bg=BG)
            lslug = slug(lname)
            ldir = os.path.join(OUT, mid, lslug)
            os.makedirs(ldir, exist_ok=True)

            tiles = []
            for row in range(grid):
                for col in range(grid):
                    sub = bytearray(px * px * 3)
                    for y in range(px):
                        so = ((row * px + y) * full + col * px) * 3
                        do = y * px * 3
                        sub[do:do + px * 3] = canvas.buf[so:so + px * 3]
                    payload = bc1.encode(sub, px, px)
                    name = "z0_%dx%d.dds" % (col, row)
                    with open(os.path.join(ldir, name), "wb") as f:
                        f.write(bc1.dds(px, px, payload))
                    total_bytes += len(payload) + bc1.DDS_HEADER_BYTES
                    tiles.append({
                        "col": col, "row": row,
                        "file": "%s/%s/%s" % (mid, lslug, name),
                        "world": tile_world_rect(ib, grid, grid, col, row),
                    })

            mrec["layers"].append({
                "name": lname,
                "slug": lslug,
                "level": L.get("level", 0),
                "imageBounds": ib,
                "gameBounds": L.get("gameBounds", []),
                "cols": grid, "rows": grid,
                "tilePx": px,
                "slotsNeeded": grid * grid,
                "tiles": tiles,
            })
            if verbose:
                p = st.problems()
                print("  %-28s %-22s %d shapes %5.1fs%s"
                      % (mid, lname, st.shapes, time.time() - t0,
                         ("  [" + p + "]") if p else ""))
            if st.problems():
                problems.append("%s/%s: %s" % (mid, lname, st.problems()))
        manifest["maps"].append(mrec)

    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "manifest.json"), "w", encoding="utf-8",
              newline="\n") as f:
        json.dump(manifest, f, indent=1)
        f.write("\n")
    write_bin(manifest)

    nlayers = sum(len(m["layers"]) for m in manifest["maps"])
    print("maptiles: %d maps, %d layers, %d tiles, %.2f MiB, %.0fs"
          % (len(manifest["maps"]), nlayers, nlayers * grid * grid,
             total_bytes / 1048576.0, time.time() - t_all))
    if problems:
        # Printed, never swallowed. A layer that did not rasterise cleanly is a
        # layer whose art is wrong on screen, and it must be visible here.
        print("maptiles: %d PROBLEM(S):" % len(problems))
        for p in problems[:40]:
            print("  ! " + p)
    return manifest


# ------------------------------------------------------------ binary manifest
#
# WHY A SECOND FORMAT, when manifest.json already exists.
#
# The consumer is host C running inside the game. A JSON parser there is code
# that runs on the Unity thread, allocates, and can be fed a malformed file --
# three things the host safety rules exist to avoid. This emits the SAME
# information as a fixed-layout little-endian record file that C reads with one
# `fread` and a bounds check, with no parsing and no allocation.
#
# manifest.json stays because a human (and `verify`) must be able to read it.
# `verify` checks the two against each other, so they cannot drift.
#
# LAYOUT -- all little-endian, all fixed size, offsets in records not bytes:
#   header  : u32 magic 'AMT1', u32 version=1, u32 tilePx, u32 grid,
#             u32 nMaps, u32 nLayers, u32 nTiles, u32 tileBytes
#   map[]   : char[32] id, char[16] internal[4], i32 rotation, i32 defaultLevel,
#             i32 layer0, i32 nLayers, f32 bMinX,bMinY,bMaxX,bMaxY
#   layer[] : i32 level, f32 ibMinX,ibMinY,ibMaxX,ibMaxY, i32 cols, i32 rows,
#             i32 tile0, i32 nTiles, i32 nBoxes, f32 box[8][6]
#   tile[]  : i32 col, i32 row, f32 wMinX,wMinY,wMaxX,wMaxY, char[96] file
#
# `internal[4]` is FOUR fixed 16-byte slots and not a variable list on purpose:
# the widest map in the corpus declares two internal names, and a fixed slot
# count means the reader never walks a length it was told by the file.

BIN_MAGIC = 0x31544D41            # 'AMT1' little-endian
BIN_MAX_BOXES = 8
BIN_MAX_INTERNAL = 4


def _fixed(s, n):
    b = (s or "").encode("utf-8")[:n - 1]
    return b + b"\0" * (n - len(b))


def write_bin(man):
    import struct as _s
    maps, layers, tiles = [], [], []
    for m in man["maps"]:
        l0 = len(layers)
        for L in m["layers"]:
            t0 = len(tiles)
            for t in L["tiles"]:
                w = t["world"]
                tiles.append(_s.pack("<2i4f", t["col"], t["row"],
                                     w["minX"], w["minY"], w["maxX"], w["maxY"])
                             + _fixed(t["file"], 96))
            boxes = []
            for gb in (L.get("gameBounds") or [])[:BIN_MAX_BOXES]:
                boxes.append((float(gb["Min"]["x"]), float(gb["Min"]["y"]),
                              float(gb["Min"]["z"]), float(gb["Max"]["x"]),
                              float(gb["Max"]["y"]), float(gb["Max"]["z"])))
            nb = len(boxes)
            while len(boxes) < BIN_MAX_BOXES:
                boxes.append((0.0,) * 6)
            ib = L["imageBounds"]
            layers.append(
                _s.pack("<i4f5i", L["level"],
                        float(ib["Min"]["x"]), float(ib["Min"]["y"]),
                        float(ib["Max"]["x"]), float(ib["Max"]["y"]),
                        L["cols"], L["rows"], t0, len(L["tiles"]), nb)
                + b"".join(_s.pack("<6f", *b) for b in boxes))
        bb = m.get("bounds") or {"Min": {"x": 0, "y": 0}, "Max": {"x": 0, "y": 0}}
        names = (m.get("internalNames") or [])[:BIN_MAX_INTERNAL]
        maps.append(
            _fixed(m["id"], 32)
            + b"".join(_fixed(n, 16) for n in names)
            + b"\0" * 16 * (BIN_MAX_INTERNAL - len(names))
            + _s.pack("<4i4f", m["coordinateRotation"], m["defaultLevel"],
                      l0, len(m["layers"]),
                      float(bb["Min"]["x"]), float(bb["Min"]["y"]),
                      float(bb["Max"]["x"]), float(bb["Max"]["y"])))
    hdr = _s.pack("<8I", BIN_MAGIC, 1, man["tilePx"], man["grid"],
                  len(maps), len(layers), len(tiles), man["tileBytes"])
    with open(os.path.join(OUT, "maptiles.bin"), "wb") as f:
        f.write(hdr + b"".join(maps) + b"".join(layers) + b"".join(tiles))


# ------------------------------------------------------------------ selftest

def selftest():
    """PASS/FAIL/INCONCLUSIVE on the pieces, asserting on DECODED OUTPUT.

    Every check here is falsifiable: each asserts a property of the rasterised
    or round-tripped image, never that a function returned without raising.
    """
    ok = [0]
    bad = []

    def chk(cond, what):
        if cond:
            ok[0] += 1
        else:
            bad.append(what)

    # 1. BC1 round-trips a flat block EXACTLY. A block of one colour has zero
    #    representation error unless the encoder is broken.
    px = [(0x70, 0x77, 0x7F)] * 16
    dec = bc1.decode_block(bc1.encode_block(px))
    err = max(max(abs(a - b) for a, b in zip(d, px[0])) for d in dec)
    chk(err <= 4, "flat BC1 block round-trip error %d > 4" % err)

    # 2. A two-colour block keeps both colours distinguishable. This is the
    #    property that matters for line art and it can fail.
    px = [(0, 0, 0)] * 8 + [(255, 255, 255)] * 8
    dec = bc1.decode_block(bc1.encode_block(px))
    chk(sum(dec[0]) < 64 and sum(dec[8]) > 700,
        "BC1 lost a hard black/white edge: %r / %r" % (dec[0], dec[8]))

    # 3. The rasteriser fills. A 100x100 viewBox with a rect covering the left
    #    half must paint the left half and NOT the right -- a fill that painted
    #    everything, or nothing, both fail.
    svg = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">'
           '<rect x="0" y="0" width="50" height="100" fill="#ff0000"/></svg>')
    cv, st = svgraster.render(svg, 64, 64, bg=(0, 0, 0), supersample=1)

    def at(c, x, y):
        o = (y * c.w + x) * 3
        return (c.buf[o], c.buf[o + 1], c.buf[o + 2])

    chk(at(cv, 8, 32) == (255, 0, 0), "left half not filled: %r" % (at(cv, 8, 32),))
    chk(at(cv, 56, 32) == (0, 0, 0), "right half wrongly filled: %r" % (at(cv, 56, 32),))

    # 4. SVG y points DOWN. A rect on the TOP half of the viewBox must land in
    #    the TOP rows of the raster. Getting this backwards mirrors every map
    #    vertically and still looks like a map.
    svg = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">'
           '<rect x="0" y="0" width="100" height="50" fill="#00ff00"/></svg>')
    cv, _ = svgraster.render(svg, 64, 64, bg=(0, 0, 0), supersample=1)
    chk(at(cv, 32, 8) == (0, 255, 0), "SVG +y is not DOWN in the raster")
    chk(at(cv, 32, 56) == (0, 0, 0), "bottom half wrongly painted")

    # 5. CSS classes resolve. The shipped art paints entirely through them, so
    #    a class that does not resolve produces a black map that renders fine.
    svg = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">'
           '<defs><style>.st0 { fill: #0000ff; }</style></defs>'
           '<rect class="st0" x="0" y="0" width="10" height="10"/></svg>')
    cv, _ = svgraster.render(svg, 8, 8, bg=(0, 0, 0), supersample=1)
    chk(at(cv, 4, 4) == (0, 0, 255), "CSS class fill did not resolve: %r"
        % (at(cv, 4, 4),))

    # 6. translate() moves art. 124 of the shipped elements carry one.
    svg = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">'
           '<g transform="translate(50,0)">'
           '<rect x="0" y="0" width="50" height="100" fill="#ffff00"/></g></svg>')
    cv, _ = svgraster.render(svg, 64, 64, bg=(0, 0, 0), supersample=1)
    chk(at(cv, 56, 32) == (255, 255, 0), "translate() did not move the rect")
    chk(at(cv, 8, 32) == (0, 0, 0), "translate() left art behind")

    # 7. Path close + fill-rule. A ring drawn as two nested squares with
    #    evenodd must be HOLLOW in the middle. Under nonzero (same winding) it
    #    would be solid -- so this check can genuinely go either way.
    svg = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">'
           '<path fill="#ffffff" fill-rule="evenodd" '
           'd="M10,10 H90 V90 H10 Z M30,30 H70 V70 H30 Z"/></svg>')
    cv, _ = svgraster.render(svg, 100, 100, bg=(0, 0, 0), supersample=1)
    chk(at(cv, 50, 50) == (0, 0, 0), "evenodd hole was filled")
    chk(at(cv, 20, 50) == (255, 255, 255), "evenodd ring body not filled")

    # 7b. fill-opacity composites, it does not paint solid. A red rect at
    #     fill-opacity .5 over a white ground must come out ~ (255,127,127) --
    #     NOT (255,0,0). This is the Woods RED-blob bug: the no-go zones are
    #     `fill-opacity: .4` and were baked opaque. Assert the FINISHED texel,
    #     the negative ("it is not solid red") being the falsifiable half.
    svg = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">'
           '<rect x="0" y="0" width="10" height="10" '
           'style="fill: red; fill-opacity: .5"/></svg>')
    cv, _ = svgraster.render(svg, 8, 8, bg=(255, 255, 255), supersample=1)
    r, g, b = at(cv, 4, 4)
    chk(r == 255 and 110 <= g <= 145 and 110 <= b <= 145,
        "fill-opacity .5 red over white did not composite: %r" % ((r, g, b),))
    chk((r, g, b) != (255, 0, 0), "fill-opacity was IGNORED (baked solid red)")
    # A .4 opacity over white -> ~ (255,153,153), and 0 opacity paints nothing.
    svg0 = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">'
            '<rect x="0" y="0" width="10" height="10" fill="red" '
            'fill-opacity="0"/></svg>')
    cv0, _ = svgraster.render(svg0, 8, 8, bg=(255, 255, 255), supersample=1)
    chk(at(cv0, 4, 4) == (255, 255, 255),
        "fill-opacity 0 still painted: %r" % (at(cv0, 4, 4),))

    # 8. tile_world_rect: row 0 is the TOP of the image, i.e. the HIGH-y end.
    ib = {"Min": {"x": -65.0, "y": -64.5}, "Max": {"x": 77.6, "y": 67.2}}
    t00 = tile_world_rect(ib, 2, 2, 0, 0)
    t01 = tile_world_rect(ib, 2, 2, 0, 1)
    chk(abs(t00["maxY"] - 67.2) < 1e-6, "row 0 is not the top of the image")
    chk(abs(t00["minY"] - t01["maxY"]) < 1e-6, "tile rows do not tessellate")
    chk(abs(t00["minX"] + 65.0) < 1e-6, "col 0 is not the min-x edge")
    chk(t01["minY"] < t00["minY"], "row 1 is not BELOW row 0 in world y")

    # 9. tile_world_rect must agree with mm_tile_index's row inversion. Pick a
    #    world point in the top-left tile and confirm the header's formula names
    #    (col 0, row 0). Disagreement mirrors every map and is invisible.
    cols = rows = 2
    origin_x, origin_y = ib["Min"]["x"], ib["Min"]["y"]
    tsz = (ib["Max"]["x"] - ib["Min"]["x"]) / cols
    tszy = (ib["Max"]["y"] - ib["Min"]["y"]) / rows
    wy = ib["Max"]["y"] - 0.25 * (ib["Max"]["y"] - ib["Min"]["y"])   # upper band
    wx = ib["Min"]["x"] + 0.25 * (ib["Max"]["x"] - ib["Min"]["x"])   # left band
    mm_col = int(math.floor((wx - origin_x) / tsz))
    mm_row = (rows - 1) - int(math.floor((wy - origin_y) / tszy))
    chk((mm_col, mm_row) == (0, 0),
        "mm_tile_index formula disagrees with tile_world_rect: got (%d,%d)"
        % (mm_col, mm_row))
    tw = tile_world_rect(ib, cols, rows, mm_col, mm_row)
    chk(tw["minX"] <= wx <= tw["maxX"] and tw["minY"] <= wy <= tw["maxY"],
        "the tile mm_tile_index picked does not contain the point")

    print("maptiles selftest: %d PASS, %d FAIL" % (ok[0], len(bad)))
    for b in bad:
        print("  FAIL " + b)
    return 0 if not bad else 1


# -------------------------------------------------------------------- verify

def verify():
    """Does the SHIPPED output match the SHIPPED calibration? Three outcomes."""
    mpath = os.path.join(OUT, "manifest.json")
    if not os.path.isfile(mpath):
        print("maptiles verify: INCONCLUSIVE -- no manifest at %s. "
              "Run `python tools/maptiles.py build`." % mpath)
        return 2
    with open(mpath, "r", encoding="utf-8") as f:
        man = json.load(f)
    if man.get("schema") != SCHEMA:
        print("maptiles verify: FAIL -- schema %r, expected %r"
              % (man.get("schema"), SCHEMA))
        return 1
    bad, n, missing = [], 0, 0
    want = man["tilePx"] * man["tilePx"] // 2 + bc1.DDS_HEADER_BYTES
    for m in man["maps"]:
        cal = load_map(m["id"])
        if cal.get("coordinateRotation", 0) != m["coordinateRotation"]:
            bad.append("%s: manifest rotation %s != calibration %s"
                       % (m["id"], m["coordinateRotation"],
                          cal.get("coordinateRotation", 0)))
        for L in m["layers"]:
            if L["slotsNeeded"] > TEX_MAX:
                bad.append("%s/%s needs %d slots, cache has %d"
                           % (m["id"], L["name"], L["slotsNeeded"], TEX_MAX))
            for t in L["tiles"]:
                n += 1
                p = os.path.join(OUT, t["file"].replace("/", os.sep))
                if not os.path.isfile(p):
                    missing += 1
                    bad.append("missing tile " + t["file"])
                elif os.path.getsize(p) != want:
                    bad.append("%s is %d bytes, expected %d"
                               % (t["file"], os.path.getsize(p), want))
                w = t["world"]
                if not (w["maxX"] > w["minX"] and w["maxY"] > w["minY"]):
                    bad.append("degenerate world rect on " + t["file"])
    if bad:
        print("maptiles verify: FAIL -- %d problem(s) over %d tiles" % (len(bad), n))
        for b in bad[:20]:
            print("  ! " + b)
        return 1
    # The binary manifest must exist and must be exactly the size its own
    # record counts imply. A short file is the failure mode that would make the
    # host read past the end, so it is checked here and not trusted there.
    bp = os.path.join(OUT, "maptiles.bin")
    if not os.path.isfile(bp):
        print("maptiles verify: FAIL -- manifest.json is present but "
              "maptiles.bin is not; the host reads the binary one")
        return 1
    nl = sum(len(m["layers"]) for m in man["maps"])
    want_bin = 32 + 128 * len(man["maps"]) + 232 * nl + 120 * n
    got_bin = os.path.getsize(bp)
    if got_bin != want_bin:
        print("maptiles verify: FAIL -- maptiles.bin is %d bytes, but %d maps "
              "/ %d layers / %d tiles imply %d"
              % (got_bin, len(man["maps"]), nl, n, want_bin))
        return 1
    print("maptiles verify: PASS -- %d tiles, all present at %d bytes, "
          "rotations match calibration, maptiles.bin %d bytes matches its "
          "record counts" % (n, want, got_bin))
    return 0


def rebin():
    """Regenerate maptiles.bin from manifest.json without re-rasterising."""
    with open(os.path.join(OUT, "manifest.json"), "r", encoding="utf-8") as f:
        write_bin(json.load(f))
    print("maptiles: maptiles.bin rewritten from manifest.json")
    return 0


def size():
    tot = nf = 0
    for root, _, files in os.walk(OUT):
        for f in files:
            tot += os.path.getsize(os.path.join(root, f))
            nf += 1
    print("maptiles: %d files, %.2f MiB under %s"
          % (nf, tot / 1048576.0, os.path.relpath(OUT, REPO)))
    return 0


def main(argv):
    ap = argparse.ArgumentParser(prog="maptiles")
    sub = ap.add_subparsers(dest="cmd")
    b = sub.add_parser("build")
    b.add_argument("--maps", default="")
    b.add_argument("--px", type=int, default=512)
    b.add_argument("--grid", type=int, default=2)
    sub.add_parser("selftest")
    sub.add_parser("verify")
    sub.add_parser("size")
    sub.add_parser("rebin")
    a = ap.parse_args(argv)
    if a.cmd == "build":
        build([s for s in a.maps.split(",") if s] or None, a.px, a.grid)
        return 0
    if a.cmd == "selftest":
        return selftest()
    if a.cmd == "verify":
        return verify()
    if a.cmd == "size":
        return size()
    if a.cmd == "rebin":
        return rebin()
    ap.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
