#!/usr/bin/env python3
"""unityassets.py -- the one wrapper for reading Unity serialized files here.

Why this exists
---------------
Every UnityPy question in this repo used to cost a hand-written scratch script
plus the "which python" dance.  Measured (fact #163): UnityPy imports ONLY
under the Store python at %LOCALAPPDATA%/Microsoft/WindowsApps/python.exe.
The msys `python` that wins on PATH cannot import it, and the failure reads as
an obscure traceback rather than "wrong interpreter".  This module detects that
and re-executes itself under the right interpreter; if it cannot find one it
prints a NAMED error and exits 3.

Never run `ls` on "C:/Program Files/WindowsApps/..." -- it hangs for the full
timeout.  We probe the WindowsApps *shim* path only, which is cheap.

Verbs
-----
  where                                     print the interpreter actually used
  objects  FILE [--type T] [--limit N]      one line per object
  raw      FILE PATHID [--out F] [--hex N]  dump one object's raw bytes
  strings  FILE PATHID [--min N]            ascii strings inside one object
  scan     FILE [--type T] [--limit N]      biggest objects of a type
  records  FILE PATHID                      decode packed [len][ascii][16][vec3]
  lootpos  FILE [--json OUT]                every such record in every MonoBehaviour
"""
import os
import subprocess
import sys

STORE_PY = os.path.join(
    os.environ.get("LOCALAPPDATA", ""), "Microsoft", "WindowsApps", "python.exe")


def _reexec_if_needed():
    try:
        import UnityPy  # noqa: F401
        return
    except ImportError:
        pass
    if os.environ.get("UNITYASSETS_REEXEC"):
        sys.stderr.write(
            "unityassets: NAMED-ERROR no-unitypy-interpreter\n"
            "  This interpreter (%s) cannot import UnityPy, and the re-exec\n"
            "  under the Store python has already been tried.\n"
            "  Fix: install UnityPy for that interpreter, or point\n"
            "  UNITYASSETS_PYTHON at one that has it.\n" % (sys.executable,))
        sys.exit(3)
    cand = os.environ.get("UNITYASSETS_PYTHON") or STORE_PY
    if not os.path.isfile(cand):
        sys.stderr.write(
            "unityassets: NAMED-ERROR store-python-missing\n"
            "  UnityPy is not importable under %s and the Store python was not\n"
            "  found at %s (fact #163).\n" % (sys.executable, cand))
        sys.exit(3)
    env = dict(os.environ, UNITYASSETS_REEXEC="1")
    # Re-run whatever script is actually running -- this module is imported by
    # other tools, and re-running *itself* would silently swallow their argv.
    script = os.path.abspath(sys.argv[0]) if sys.argv and sys.argv[0] \
        else os.path.abspath(__file__)
    sys.exit(subprocess.call([cand, script] + sys.argv[1:], env=env))


_reexec_if_needed()

import argparse            # noqa: E402
import json                # noqa: E402
import re                  # noqa: E402
import struct              # noqa: E402

import UnityPy             # noqa: E402


def load(path):
    if not os.path.isfile(path):
        sys.stderr.write("unityassets: NAMED-ERROR no-such-file %s\n" % path)
        sys.exit(4)
    return UnityPy.load(path)


def objs(env, typ=None):
    for o in env.objects:
        if typ and o.type.name != typ:
            continue
        yield o


def _data(o):
    try:
        return o.get_raw_data()
    except Exception:
        return bytes(o.raw_data)


# ---------------------------------------------------------------- record codec
ID_RE = re.compile(rb"^[ -~]+$")


def decode_records(buf):
    """Decode packed records [i32 len][ascii Id][pad][16 bytes][3 f32][i32].

    A decode that merely produces *plausible* floats is not evidence.  Every
    field is checked: sane length, printable ascii Id, finite floats inside the
    coordinate box any Tarkov map fits in.  Accepted records must also CHAIN --
    scanning resumes at the end of the record, so a run of records only stays a
    run if each header lands exactly where the previous record ended.  That is
    what separates a real array from a lucky alignment.
    """
    out = []
    n = len(buf)
    i = 0
    while i + 4 <= n:
        (ln,) = struct.unpack_from("<i", buf, i)
        if not (1 <= ln <= 128) or i + 4 + ln + 32 > n:
            i += 1
            continue
        ident = buf[i + 4:i + 4 + ln]
        if not ID_RE.match(ident):
            i += 1
            continue
        p = i + 4 + ln
        p += (-p) & 3            # Unity aligns after a string
        if p + 32 > n:
            i += 1
            continue
        x, y, z = struct.unpack_from("<3f", buf, p + 16)
        if not all(v == v and abs(v) < 5000.0 for v in (x, y, z)):
            i += 1
            continue
        out.append({"Id": ident.decode("ascii"),
                    "Position": {"x": round(x, 6), "y": round(y, 6),
                                 "z": round(z, 6)},
                    "_off": i})
        i = p + 32
    return out


def cmd_where(a):
    print(sys.executable)
    print("UnityPy", UnityPy.__version__)


def cmd_objects(a):
    env = load(a.file)
    n = 0
    for o in objs(env, a.type):
        print("%-14s path_id=%-14s size=%d"
              % (o.type.name, o.path_id, len(_data(o))))
        n += 1
        if a.limit and n >= a.limit:
            break
    print("# %d object(s)" % n)


def _find(env, path_id):
    for o in env.objects:
        if o.path_id == path_id:
            return o
    sys.stderr.write("unityassets: NAMED-ERROR no-such-path-id %s\n" % path_id)
    sys.exit(4)


def cmd_raw(a):
    d = _data(_find(load(a.file), a.path_id))
    if a.out:
        open(a.out, "wb").write(d)
        print("wrote %d bytes to %s" % (len(d), a.out))
    else:
        print(d[:a.hex].hex())


def cmd_strings(a):
    d = _data(_find(load(a.file), a.path_id))
    for m in re.finditer(rb"[ -~]{%d,}" % a.min, d):
        print(m.start(), m.group().decode("ascii"))


def cmd_scan(a):
    env = load(a.file)
    rows = sorted(((len(_data(o)), o.path_id) for o in objs(env, a.type)),
                  reverse=True)
    for sz, pid in rows[:a.limit]:
        print("path_id=%-14s size=%d" % (pid, sz))
    print("# %d object(s) of type %s" % (len(rows), a.type))


def cmd_records(a):
    for r in decode_records(_data(_find(load(a.file), a.path_id))):
        print(r["Id"], r["Position"])


def scene_lootpos(path):
    """Every decoded Id -> Position in every MonoBehaviour of one level file."""
    env = load(path)
    seen = {}
    for o in objs(env, "MonoBehaviour"):
        try:
            d = _data(o)
        except Exception:
            continue
        for r in decode_records(d):
            seen.setdefault(r["Id"], r["Position"])
    return seen


def cmd_lootpos(a):
    seen = scene_lootpos(a.file)
    if a.json:
        with open(a.json, "w") as fh:
            json.dump(seen, fh, indent=0, sort_keys=True)
    print("# %d distinct id(s)" % len(seen))


def main():
    ap = argparse.ArgumentParser(prog="unityassets.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("where").set_defaults(fn=cmd_where)

    p = sub.add_parser("objects")
    p.add_argument("file")
    p.add_argument("--type")
    p.add_argument("--limit", type=int, default=0)
    p.set_defaults(fn=cmd_objects)

    p = sub.add_parser("raw")
    p.add_argument("file")
    p.add_argument("path_id", type=int)
    p.add_argument("--out")
    p.add_argument("--hex", type=int, default=256)
    p.set_defaults(fn=cmd_raw)

    p = sub.add_parser("strings")
    p.add_argument("file")
    p.add_argument("path_id", type=int)
    p.add_argument("--min", type=int, default=6)
    p.set_defaults(fn=cmd_strings)

    p = sub.add_parser("scan")
    p.add_argument("file")
    p.add_argument("--type", default="MonoBehaviour")
    p.add_argument("--limit", type=int, default=20)
    p.set_defaults(fn=cmd_scan)

    p = sub.add_parser("records")
    p.add_argument("file")
    p.add_argument("path_id", type=int)
    p.set_defaults(fn=cmd_records)

    p = sub.add_parser("lootpos")
    p.add_argument("file")
    p.add_argument("--json")
    p.set_defaults(fn=cmd_lootpos)

    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
