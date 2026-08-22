#!/usr/bin/env python3
r"""imagecache.py -- give the post-1.0 client its trader avatars and quest icons
by filling the cache directory the client itself reads *before* it ever touches
the network.

Why this exists (the short version; the long one is in
`docs/timbuktu/IMAGE-LOADING-RE2.md`)
------------------------------------------------------------------------------
`EFT.ClientBackendSession.LoadTextureWithCache(url, baseUrl)` runs, in order:

  1. `UnityResourcesProxy.Load<Texture2D>(url.ConvertToResourceLocation())`
     -- returns the texture if the build ships one under `Resources`.
  2. `diskPath = Application.temporaryCachePath + url`
     `if (File.Exists(diskPath)) return await DownloadTexture2D(new Uri(diskPath).AbsoluteUri);`
     -- a `file://` UnityWebRequest. No socket, no TLS, no DNS.
  3. otherwise `await LoadTexture(baseUrl + url)` -> `DownloadTexture2D(https://...)`
     and, on success, writes the PNG to `diskPath` for next time.

Step 3 is the one that is broken against this emulator, and it is broken below
HTTP: `DownloadTexture2D` builds a bare `UnityEngine.Networking.UnityWebRequest`
and never assigns a `certificateHandler`, so Unity's own transport validates the
server certificate. The emulator's HTTPS listener presents a self-signed cert,
Unity rejects it, and the connection dies in the TLS handshake -- which is why
`nettrace.log` shows bursts of `accept` + `handshake FATAL` with no request line,
why the backend logs no `/files/` request, and why the getaddrinfo hook saw no
hostname (the URL is the IP literal `127.0.0.1`; there is nothing to resolve).
The client's own log records the attempt and the empty result:

    Load texture at : https://127.0.0.1/files/quest/icon/<id>.jpg
    Warning! Downloaded sprite is null: /files/quest/icon/<id>.jpg

EFT's ordinary `/client/*` traffic is unaffected because it goes through the
managed HTTP stack, which post-1.0 configures to accept any certificate.

Step 2 has none of that problem, and it is the client's own designed path: a
real-server session leaves exactly this tree behind. So this tool populates it.

What it does
------------------------------------------------------------------------------
* reads every `/files/...` URL out of the emulator's database (`db.json`),
* resolves each against an image source tree laid out the same way
  (`<src>/trader/avatar/<id>.png`, `<src>/quest/icon/<id>.jpg`, ...), matching
  the exact filename first and then the same stem under any other image
  extension -- BSG's URL says `.jpg` for a good number of icons that ship as
  `.png`, and Unity's texture loader sniffs the bytes, not the name,
* copies it to `<temporaryCachePath>/files/<same relative path>`, using the
  extension the *URL* asks for, because that is the name `File.Exists` tests.

It never overwrites a file that is already there, so a genuine download always
wins, and re-running it is free.

The assets with no source at all
------------------------------------------------------------------------------
The SPT image tree predates a few of the traders and icons post-1.0 asks for.
Trader **Ref** (`/files/trader/avatar/5824657996560e1be8000848.png`) is the one
that shows: SPT 3.x never shipped his avatar, so the client cache misses, the
request falls through to the emulator's `/files/` listener, and `onFiles` hands
back the 77-byte placeholder -- which the Traders screen draws as a permanent
spinner.

`--fill-missing` closes that hole. For every URL with no source it writes a
generated, correctly-sized image instead of leaving nothing:

* trader avatars reuse the source tree's own `trader/avatar/unknown.png` when it
  is there -- that is BSG-shaped art the install already has, and it reads as a
  deliberate "no portrait" rather than as a bug;
* anything else (and an avatar with no `unknown.png` to borrow) gets a plain
  128x128 PNG synthesised here with `zlib` alone: dark plate, thin border,
  head-and-shoulders silhouette.

A generated file is still a file the next real download would replace, and the
tool still refuses to overwrite, so this is a floor and not a ceiling. Nothing
BSG-owned is redistributed by this repo: the fill is either generated at run
time or copied out of the user's own install.

Missing assets are self-reporting from the other side too: `onFiles` in
`mods/tarkov/tarkov.nim` logs each distinct path it had to answer with the
placeholder, so `aowlspt-backend.log` names anything this tool did not cover.

Where the cache is
------------------------------------------------------------------------------
Unity's `Application.temporaryCachePath` on Windows is

    %USERPROFILE%\AppData\Local\Temp\<company>\<product>

with `<company>`/`<product>` being the first two lines of
`<game>\EscapeFromTarkov_Data\app.info` -- "Battlestate Games" and
"EscapeFromTarkov" for this build. `--game` points at the install so the names
are read rather than assumed; `--cache` overrides the whole path.

Usage
------------------------------------------------------------------------------
    python tools/imagecache.py --db D:/Aowlspt/aowlspt/db.json \
                               --src D:/SPT/SPT_Runtime/SPT_Data/images \
                               --game D:/Aowlspt

    python tools/imagecache.py --db ... --src ... --dry-run

    # and, to leave nothing showing a spinner (Ref's avatar is the one that did)
    python tools/imagecache.py --db D:/Aowlspt/aowlspt/db.json \
                               --src D:/SPT/SPT_Runtime/SPT_Data/images \
                               --game D:/Aowlspt --fill-missing

Stdlib only. Makes no network calls. Reads the source tree, writes only under
the cache directory.
"""

import argparse
import os
import re
import shutil
import struct
import sys
import zlib

IMAGE_EXTS = (".png", ".jpg", ".jpeg", ".bmp", ".tga")

# The prefix every asset URL in the database carries. `LoadTextureWithCache`
# concatenates `temporaryCachePath + url` verbatim, leading slash included, so
# the cache tree mirrors the URL tree exactly -- `files/` and all.
URL_PREFIX = "/files/"
URL_RE = re.compile(r"/files/[A-Za-z0-9_.\-/]+")


def read_text(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def urls_from_db(db_path):
    """Every distinct `/files/...` URL the database hands to the client.

    A regex over the raw text rather than a JSON walk: these URLs live in a
    dozen different shapes (trader `base.avatar`, quest `image`, handbook and
    achievement icons, hideout art) and the set of keys has changed between
    builds, but the literal is always the same and always a JSON string. The
    text is scanned with JSON's escaped solidus (`\\/`) folded back to `/`,
    which is how BSG's own dumps spell it.
    """
    text = read_text(db_path).replace(chr(92) + "/", "/")
    out = set()
    for u in URL_RE.findall(text):
        # Trim a trailing separator or a bare directory reference; the database
        # carries a couple of those and there is nothing to copy for them.
        if u.endswith("/"):
            continue
        rel = u[len(URL_PREFIX):]
        if rel:
            out.add(rel)
    return sorted(out)


def index_source(src_root):
    """Map the source tree twice: by exact relative path, and by path-without-
    extension, both lowercased. The second index is what lets a URL ending in
    `.jpg` find a file that ships as `.png`."""
    exact = {}
    by_stem = {}
    for dirpath, _dirs, names in os.walk(src_root):
        for name in names:
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, src_root).replace(os.sep, "/")
            low = rel.lower()
            exact[low] = full
            stem, ext = os.path.splitext(low)
            if ext in IMAGE_EXTS and stem not in by_stem:
                by_stem[stem] = full
    return exact, by_stem


def resolve(rel_url, exact, by_stem):
    low = rel_url.lower()
    hit = exact.get(low)
    if hit:
        return hit
    stem = os.path.splitext(low)[0]
    return by_stem.get(stem)


AVATAR_PREFIX = "trader/avatar/"
FALLBACK_AVATAR = AVATAR_PREFIX + "unknown.png"
GEN_SIZE = 128


def _png(width, height, rgb_rows):
    """A minimal RGB PNG. `rgb_rows` is a list of `bytearray` scanlines, each
    `width * 3` bytes. Filter type 0 on every line -- the images are tiny and a
    predictor would only buy bytes nobody counts."""
    raw = bytearray()
    for row in rgb_rows:
        raw.append(0)
        raw.extend(row)

    def chunk(tag, payload):
        return (struct.pack(">I", len(payload)) + tag + payload
                + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
            + chunk(b"IEND", b""))


def generated_avatar(size=GEN_SIZE):
    """A 128x128 "no portrait" plate, drawn with arithmetic.

    Deliberately plain and deliberately in the game's palette: the point is that
    the Traders screen shows *something* framed like every other avatar, so a
    missing image looks like a missing image and not like a hung download.
    """
    half = size / 2.0
    rows = []
    for y in range(size):
        row = bytearray()
        for x in range(size):
            # Vertical gradient plate, darker at the bottom.
            t = y / float(size - 1)
            r = int(46 - 14 * t)
            g = int(45 - 14 * t)
            b = int(42 - 13 * t)
            # Head: a circle in the upper half.
            dx = x - half
            dy = y - (size * 0.40)
            if dx * dx + dy * dy <= (size * 0.16) ** 2:
                r, g, b = 116, 112, 100
            # Shoulders: a wide ellipse rooted below the frame.
            sy = y - (size * 1.02)
            sx = dx / 1.55
            if sy < 0 and sx * sx + sy * sy <= (size * 0.42) ** 2:
                r, g, b = 100, 96, 86
            # Thin border, so the plate has an edge like the real avatars.
            if x < 2 or y < 2 or x >= size - 2 or y >= size - 2:
                r, g, b = 24, 24, 22
            row.append(r)
            row.append(g)
            row.append(b)
        rows.append(row)
    return _png(size, size, rows)


def unity_temp_cache(game_dir, company_default="Battlestate Games",
                     product_default="EscapeFromTarkov"):
    """`Application.temporaryCachePath` for the install at `game_dir`.

    Unity writes the company and product names, one per line, into
    `<product>_Data/app.info`; reading them is the difference between a path
    that is right for this install and one that happens to be right for mine.
    """
    company, product = company_default, product_default
    if game_dir:
        info = os.path.join(game_dir, "EscapeFromTarkov_Data", "app.info")
        if os.path.isfile(info):
            lines = [ln.strip() for ln in read_text(info).splitlines() if ln.strip()]
            if len(lines) >= 2:
                company, product = lines[0], lines[1]
    local = os.environ.get("LOCALAPPDATA")
    if not local:
        profile = os.environ.get("USERPROFILE", "")
        local = os.path.join(profile, "AppData", "Local")
    return os.path.join(local, "Temp", company, product)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--db", required=True,
                    help="emulator database json (the deployed db.json)")
    ap.add_argument("--src", required=True,
                    help="image source tree laid out like the /files/ URL tree")
    ap.add_argument("--game", default="",
                    help="game install dir, read for app.info company/product")
    ap.add_argument("--cache", default="",
                    help="override Application.temporaryCachePath entirely")
    ap.add_argument("--dry-run", action="store_true",
                    help="report what would be written and write nothing")
    ap.add_argument("--fill-missing", action="store_true",
                    help="write a generated image for every URL with no source "
                         "(trader avatars borrow the install's unknown.png), so "
                         "a missing asset is a plain plate and not a spinner")
    ap.add_argument("--force", action="store_true",
                    help="overwrite cache files that already exist "
                         "(default is to leave a real download alone)")
    args = ap.parse_args(argv)

    if not os.path.isfile(args.db):
        sys.exit("no database at " + args.db)
    if not os.path.isdir(args.src):
        sys.exit("no image source at " + args.src)

    cache_root = args.cache or unity_temp_cache(args.game)
    files_root = os.path.join(cache_root, "files")

    urls = urls_from_db(args.db)
    exact, by_stem = index_source(args.src)

    # The generated plate is built at most once, and only if it is needed.
    generated_bytes = [None]

    def fallback_for(rel):
        """Bytes to write for a URL with no source, or None to leave it alone.

        An avatar borrows the install's own `unknown.png` first -- it is the art
        the game already uses for a trader with no portrait, so it is both the
        best-looking and the least presumptuous answer. Everything else, and an
        avatar with no `unknown.png` in reach, gets the synthesised plate.
        """
        if rel.lower().startswith(AVATAR_PREFIX):
            borrowed = exact.get(FALLBACK_AVATAR)
            if borrowed:
                with open(borrowed, "rb") as f:
                    return f.read()
        if generated_bytes[0] is None:
            generated_bytes[0] = generated_avatar()
        return generated_bytes[0]

    copied = skipped = missing = filled = 0
    missing_examples = []
    filled_paths = []
    for rel in urls:
        src = resolve(rel, exact, by_stem)
        dst = os.path.join(files_root, rel.replace("/", os.sep))
        if not src:
            missing += 1
            if len(missing_examples) < 10:
                missing_examples.append(rel)
            if not args.fill_missing:
                continue
            if os.path.exists(dst) and not args.force:
                skipped += 1
                continue
            filled += 1
            if len(filled_paths) < 20:
                filled_paths.append(rel)
            if args.dry_run:
                continue
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            with open(dst, "wb") as f:
                f.write(fallback_for(rel))
            continue
        if os.path.exists(dst) and not args.force:
            skipped += 1
            continue
        if args.dry_run:
            copied += 1
            continue
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copyfile(src, dst)
        copied += 1

    print("cache      : " + files_root)
    print("urls       : %d" % len(urls))
    print("%s: %d" % ("would copy " if args.dry_run else "copied     ", copied))
    print("already there: %d" % skipped)
    print("no source  : %d" % missing)
    for m in missing_examples:
        print("   missing " + m)
    print("%s: %d" % ("would fill " if args.dry_run else "filled     ", filled))
    for m in filled_paths:
        print("   filled  " + m)
    if missing and not args.fill_missing:
        print("(re-run with --fill-missing to give these a generated image "
              "instead of an in-game spinner)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
