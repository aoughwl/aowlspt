"""
Apply a terrain and/or prefab pack into the live install, and re-sync ConsistencyInfo.

THIS IS THE ONLY TOOL IN THE PIPELINE THAT WRITES INTO A GAME DIRECTORY, and it is
DRY-RUN unless `--commit` is passed. It was written by a subagent that is not allowed
to deploy; running it for real is the coordinating session's decision, with the game
stopped.

THE HARDLINK. Measured with `fsutil hardlink list`: every file under
`D:\\Aowlspt\\EscapeFromTarkov_Data` has link count 2 and its twin is
`D:\\Games\\Tarkov\\EscapeFromTarkov_Data`. Opening one for writing modifies BOTH --
it would silently corrupt the real Tarkov install. So for each file this tool
touches it:

    1. copies the original to a timestamped backup (which also preserves the twin's
       content independently of what happens next),
    2. DELETES the path in D:\\Aowlspt, which breaks the link and leaves
       D:\\Games\\Tarkov holding the only remaining copy of the original,
    3. writes a fresh, unlinked file at that path,
    4. re-verifies the link count is now 1.

Step 4 is not decoration. If it still reads 2, the write went through to the real
install and the run is aborted before anything else is touched.

CONSISTENCY. Both packs preserve every `.resS` SIZE exactly, so only the Checksum
changes. `consistency.py sync` rewrites just the named entries and backs the manifest
up first. Sizes are re-derived from disk anyway, so a size change would be picked up
rather than assumed away.

Usage:
  python apply.py --terrain ../out/terrain-pack --assets ../out/assets-pack   # dry run
  python apply.py ... --commit
"""
from __future__ import annotations
import argparse, hashlib, json, os, shutil, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = 'D:/Aowlspt'
DATA = os.path.join(ROOT, 'EscapeFromTarkov_Data')
TERRAIN_RESS = 'sharedassets17.assets.resS'


def link_count(path: str) -> int:
    try:
        out = subprocess.run(['fsutil', 'hardlink', 'list', path.replace('/', '\\')],
                             capture_output=True, text=True)
        return len([l for l in out.stdout.splitlines() if l.strip()])
    except Exception:
        return -1


def unlink_and_write(dst: str, produce, stamp: str, commit: bool, log: list):
    """Back up, break the hardlink, write. `produce(fh)` fills the new file."""
    bak = os.path.join(os.path.dirname(dst), 'backup-' + stamp)
    bpath = os.path.join(bak, os.path.basename(dst))
    lc = link_count(dst)
    log.append(f'  {os.path.basename(dst)}  links={lc}  backup -> {bpath}')
    if not commit:
        return
    os.makedirs(bak, exist_ok=True)
    shutil.copy2(dst, bpath)
    if os.path.getsize(bpath) != os.path.getsize(dst):
        sys.exit(f'backup of {dst} is the wrong size; aborting')
    os.remove(dst)                       # breaks the hardlink
    with open(dst, 'wb') as f:
        produce(f)
    lc2 = link_count(dst)
    if lc2 > 1:
        sys.exit(f'{dst} still has {lc2} links after rewrite -- the write may have '
                 f'gone through to D:\\Games\\Tarkov. ABORTING.')
    log.append(f'    rewritten, links now {lc2}')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--terrain', default='')
    ap.add_argument('--assets', default='')
    ap.add_argument('--commit', action='store_true')
    args = ap.parse_args()
    if not args.terrain and not args.assets:
        sys.exit('nothing to apply')

    stamp = time.strftime('%Y%m%d-%H%M%S')
    log, touched = [], []

    if args.terrain:
        src = os.path.join(os.path.abspath(args.terrain), TERRAIN_RESS)
        dst = os.path.join(DATA, TERRAIN_RESS)
        if not os.path.exists(src):
            sys.exit(f'no {TERRAIN_RESS} in {args.terrain}')
        if os.path.getsize(src) != os.path.getsize(dst):
            sys.exit('terrain pack .resS differs in SIZE from the installed one; '
                     'that must never happen with this method')
        log.append(f'TERRAIN: replace {TERRAIN_RESS} '
                   f'({os.path.getsize(src):,} bytes, size unchanged)')
        unlink_and_write(dst, lambda f: shutil.copyfileobj(open(src, 'rb'), f, 1 << 22),
                         stamp, args.commit, log)
        touched.append(f'EscapeFromTarkov_Data\\{TERRAIN_RESS}')

    if args.assets:
        pack = os.path.abspath(args.assets)
        man = json.load(open(os.path.join(pack, 'assets-manifest.json')))
        by_res = {}
        for e in man['entries']:
            by_res.setdefault(e['res'], []).append(e)
        log.append(f'PREFAB: {len(man["entries"])} textures across {len(by_res)} .resS')
        for resname, rows in sorted(by_res.items()):
            dst = os.path.join(DATA, resname)
            if not os.path.exists(dst):
                sys.exit(f'{dst} missing')
            size = os.path.getsize(dst)

            def produce(f, dst=dst, rows=rows, size=size):
                with open(dst + '.__orig', 'rb') as src:
                    shutil.copyfileobj(src, f, 1 << 22)
                for e in rows:
                    blob = open(os.path.join(pack, 'blobs', e['blob']), 'rb').read()
                    if len(blob) != e['size']:
                        sys.exit(f'blob {e["blob"]} wrong length')
                    f.seek(e['off'])
                    f.write(blob)
                f.seek(0, 2)
                if f.tell() != size:
                    sys.exit(f'{dst} changed size; aborting')

            log.append(f'  {resname}: {len(rows)} textures, '
                       f'{sum(e["size"] for e in rows):,} bytes, size {size:,} unchanged')
            if args.commit:
                # keep the pre-write bytes reachable while we rewrite in place
                os.rename(dst, dst + '.__orig')
                try:
                    with open(dst, 'wb') as f:
                        produce(f)
                    lc = link_count(dst)
                    if lc > 1:
                        sys.exit(f'{dst} still has {lc} links; ABORTING')
                    bak = os.path.join(DATA, 'backup-' + stamp)
                    os.makedirs(bak, exist_ok=True)
                    shutil.move(dst + '.__orig', os.path.join(bak, resname))
                except Exception:
                    if os.path.exists(dst + '.__orig'):
                        if os.path.exists(dst):
                            os.remove(dst)
                        os.rename(dst + '.__orig', dst)
                    raise
            touched.append(f'EscapeFromTarkov_Data\\{resname}')

    print('\n'.join(log))
    print()
    print(f'files to touch: {len(touched)}')
    if not args.commit:
        print('DRY RUN -- nothing was written. Re-run with --commit, game stopped.')
        print('After --commit, ConsistencyInfo MUST be re-synced:')
    else:
        print('applied. Now re-syncing ConsistencyInfo ...')
    listing = os.path.join(HERE, f'apply-touched-{stamp}.txt')
    with open(listing, 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(touched) + '\n')
    cmd = [sys.executable, 'consistency.py', 'sync', '--files-from', listing]
    print(f'   (list of {len(touched)} paths written to {listing})')
    print('   ' + ' '.join(f'"{c}"' if ' ' in c else c for c in cmd))
    if args.commit:
        r = subprocess.run(cmd, cwd=HERE)
        return r.returncode
    return 0


if __name__ == '__main__':
    sys.exit(main())
