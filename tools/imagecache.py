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
wins, and re-running it is free -- with ONE exception. When the client is
launched before this tool has seeded an icon, step 3 fetches it over the
network and, against this emulator, gets back the tiny grey PLACEHOLDER PNG
(`onFiles` in `mods/tarkov/tarkov.nim` serves one dark-grey 16x16 image for
every `/files/*` it cannot supply a real asset for) -- and then WRITES THAT
PLACEHOLDER INTO THE CACHE. From then on step 2 finds the placeholder on disk
and the quest renders grey forever, and a plain "skip anything already there"
re-run cannot fix it because the poison file exists. So an existing cache file
whose size is at or below `--placeholder-max` bytes (default 1024) is treated
as poison, not as a genuine download, and is RESEEDED from the source: no real
trader/quest/handbook asset is that small (the smallest source icon measured is
~8 KB), while the emulator placeholder is under 100 bytes. This was the observed
"some quest images are grey" bug: five quest icons the player had opened before
seeding sat in the cache as ~93-byte placeholders.

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

Stdlib only. Makes no network calls. Reads the source tree, writes only under
the cache directory.
"""

import argparse
import os
import re
import shutil
import sys

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
    ap.add_argument("--force", action="store_true",
                    help="overwrite cache files that already exist "
                         "(default is to leave a real download alone)")
    ap.add_argument("--placeholder-max", type=int, default=1024,
                    help="an existing cache file at or below this many bytes is "
                         "treated as the emulator's grey placeholder (poison "
                         "written by the client) and RESEEDED from source; no "
                         "genuine asset is this small (default 1024)")
    args = ap.parse_args(argv)

    if not os.path.isfile(args.db):
        sys.exit("no database at " + args.db)
    if not os.path.isdir(args.src):
        sys.exit("no image source at " + args.src)

    cache_root = args.cache or unity_temp_cache(args.game)
    files_root = os.path.join(cache_root, "files")

    urls = urls_from_db(args.db)
    exact, by_stem = index_source(args.src)

    copied = skipped = missing = reseeded = 0
    missing_examples = []
    reseeded_examples = []
    for rel in urls:
        src = resolve(rel, exact, by_stem)
        if not src:
            missing += 1
            if len(missing_examples) < 10:
                missing_examples.append(rel)
            continue
        dst = os.path.join(files_root, rel.replace("/", os.sep))
        if os.path.exists(dst) and not args.force:
            # A genuine seed matches its source's size; a poisoned placeholder
            # the client wrote is tiny. Reseed the poison, leave real art alone.
            try:
                dst_size = os.path.getsize(dst)
            except OSError:
                dst_size = -1
            if dst_size < 0 or dst_size > args.placeholder_max:
                skipped += 1
                continue
            reseeded += 1
            if len(reseeded_examples) < 10:
                reseeded_examples.append(rel)
            if args.dry_run:
                continue
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copyfile(src, dst)
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
    print("%s: %d" % ("would reseed" if args.dry_run else "reseeded    ", reseeded)
          + "  (poisoned placeholders <= %d bytes)" % args.placeholder_max)
    print("no source  : %d" % missing)
    for r in reseeded_examples:
        print("   reseed  " + r)
    for m in missing_examples:
        print("   missing " + m)
    return 0


if __name__ == "__main__":
    sys.exit(main())
