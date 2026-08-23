"""
Read, verify and re-sync `D:\\Aowlspt\\ConsistencyInfo`.

The client refuses to boot if a listed file's Size or Checksum disagrees with the
manifest. The manifest is plain UTF-8 JSON:

    {"Version": "...", "Entries": [{"Path": "...", "Size": N, "Checksum": N}, ...]}

`Checksum` is `sum(bytes) & 0xFFFFFFFF` **reinterpreted as a signed int32** -- the
signedness matters and is easy to miss, because the six small files it was first
verified against all happened to have sums below 2^31. Roughly half of the real
entries are negative. `verify` below re-derives the checksum from the bytes on disk
for every entry that exists, so the formula is re-measured rather than trusted.

Paths inside the manifest use BACKSLASHES and are relative to the install root.

Subcommands:
  verify  [--n N] [--filter SUB]   re-derive size+checksum for entries on disk
  show    PATHSUB                  print the manifest entries matching a substring
  sync    --file REL [--file ...]  rewrite Size+Checksum for those entries from disk

`sync` ALWAYS writes a timestamped backup of ConsistencyInfo first and refuses to
run if the backup cannot be made. It only ever touches entries named explicitly:
there is no "resync everything" mode, because that would paper over a file that
changed by accident.
"""
from __future__ import annotations
import argparse, json, os, shutil, struct, sys, time

ROOT = 'D:/Aowlspt'
MANIFEST = os.path.join(ROOT, 'ConsistencyInfo')


def checksum(path: str) -> int:
    """sum of every byte, mod 2^32, as a signed int32 (the manifest's encoding)."""
    s = 0
    with open(path, 'rb') as f:
        while True:
            b = f.read(1 << 22)
            if not b:
                break
            s += sum(b)
    return struct.unpack('<i', struct.pack('<I', s & 0xFFFFFFFF))[0]


def load(path: str = MANIFEST) -> dict:
    with open(path, 'r', encoding='utf-8') as f:
        return json.load(f)


def disk_path(rel: str) -> str:
    return os.path.join(ROOT, rel.replace('\\', os.sep))


def cmd_verify(args):
    d = load()
    ents = d['Entries']
    if args.filter:
        ents = [e for e in ents if args.filter.lower() in e['Path'].lower()]
    present = [e for e in ents if os.path.exists(disk_path(e['Path']))]
    if args.n:
        present = present[:args.n]
    print(f'manifest {len(d["Entries"])} entries, version {d["Version"]}')
    print(f'checking {len(present)} of {len(ents)} selected (present on disk)')
    okc = oks = 0
    bad = []
    for e in present:
        p = disk_path(e['Path'])
        sz = os.path.getsize(p)
        cs = checksum(p)
        s_ok, c_ok = (sz == e['Size']), (cs == e['Checksum'])
        oks += s_ok
        okc += c_ok
        if not (s_ok and c_ok):
            bad.append((e['Path'], e['Size'], sz, e['Checksum'], cs))
    print(f'  Size     matches: {oks}/{len(present)}')
    print(f'  Checksum matches: {okc}/{len(present)}')
    for p, es, ds, ec, dc in bad[:20]:
        print(f'  MISMATCH {p}\n     size manifest={es} disk={ds}\n'
              f'     cksum manifest={ec} disk={dc}')
    return 0 if not bad else 1


def cmd_show(args):
    d = load()
    for e in d['Entries']:
        if args.sub.lower() in e['Path'].lower():
            p = disk_path(e['Path'])
            ex = os.path.exists(p)
            print(f'{e["Path"]}\n   Size={e["Size"]} Checksum={e["Checksum"]} '
                  f'onDisk={ex}' + (f' diskSize={os.path.getsize(p)}' if ex else ''))
    return 0


def cmd_sync(args):
    files = list(args.files or [])
    if args.files_from:
        # 179 repeated --file arguments is not a usable command line; the prefab pack
        # alone touches 178 .resS files.
        with open(args.files_from, encoding='utf-8') as f:
            files += [l.strip() for l in f if l.strip() and not l.startswith('#')]
    args.files = files
    if not files:
        sys.exit('sync needs at least one --file or a --files-from list')
    d = load()
    idx = {e['Path'].lower(): e for e in d['Entries']}
    stamp = time.strftime('%Y%m%d-%H%M%S')
    bak = f'{MANIFEST}.bak-{stamp}'
    if os.path.exists(bak):
        sys.exit(f'backup {bak} already exists; refusing')
    shutil.copy2(MANIFEST, bak)
    if not os.path.exists(bak) or os.path.getsize(bak) != os.path.getsize(MANIFEST):
        sys.exit('backup did not take; refusing to modify ConsistencyInfo')
    print(f'backup -> {bak}')

    changed = 0
    for rel in args.files:
        key = rel.replace('/', '\\').lower()
        e = idx.get(key)
        if e is None:
            sys.exit(f'no manifest entry for {rel!r} -- refusing (nothing invented)')
        p = disk_path(e['Path'])
        if not os.path.exists(p):
            sys.exit(f'{p} does not exist -- refusing')
        sz, cs = os.path.getsize(p), checksum(p)
        print(f'{e["Path"]}\n   Size     {e["Size"]} -> {sz}\n'
              f'   Checksum {e["Checksum"]} -> {cs}')
        e['Size'], e['Checksum'] = sz, cs
        changed += 1

    tmp = MANIFEST + '.tmp'
    with open(tmp, 'w', encoding='utf-8', newline='\n') as f:
        json.dump(d, f, separators=(',', ':'))
    os.replace(tmp, MANIFEST)
    print(f'rewrote {MANIFEST}: {changed} entr(ies) updated')
    print(f'ROLLBACK:  copy /Y "{bak}" "{MANIFEST}"')
    return 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest='cmd', required=True)
    v = sub.add_parser('verify'); v.add_argument('--n', type=int, default=0)
    v.add_argument('--filter', default=''); v.set_defaults(fn=cmd_verify)
    s = sub.add_parser('show'); s.add_argument('sub'); s.set_defaults(fn=cmd_show)
    y = sub.add_parser('sync'); y.add_argument('--file', dest='files', action='append')
    y.add_argument('--files-from', default='',
                   help='a file of install-relative paths, one per line')
    y.set_defaults(fn=cmd_sync)
    args = ap.parse_args()
    return args.fn(args)


if __name__ == '__main__':
    sys.exit(main())
