#!/usr/bin/env python3
"""resspatch.py -- in-place, length-identical texture replacement in a Unity
`.assets` / `.resS` pair.

Read the README next to this file BEFORE running anything that writes.
The one-line version of the hazard: the shipped `.assets`/`.resS` are HARDLINKS
shared with the real Tarkov install. Writing them in place corrupts the real
game. `unlink` must be run first; every write verb refuses until it has been.

Requires UnityPy for `enumerate` / `verify-length` only, and UnityPy is
installed under the **Microsoft Store Python**, not the msys `python` on PATH:

    %LOCALAPPDATA%\\Microsoft\\WindowsApps\\python.exe resspatch.py ...

`write` / `restore` / `resync` are pure stdlib and run under any Python 3.9+,
but they consume an index produced by `enumerate --json` (or the cache it
writes next to the .assets).
"""

import argparse
import hashlib
import json
import os
import shutil
import struct
import sys
import time

# ---------------------------------------------------------------- formats

# Unity TextureFormat -> (name, bytes-per-block, block-edge). bytes-per-block
# None => not a plain block format; its length cannot be recomputed and it is
# never writable.
FORMATS = {
    1:  ("Alpha8",        1, 1),
    3:  ("RGB24",         3, 1),
    4:  ("RGBA32",        4, 1),
    5:  ("ARGB32",        4, 1),
    9:  ("R16",           2, 1),
    10: ("DXT1",          8, 4),
    12: ("DXT5",         16, 4),
    14: ("BGRA32",        4, 1),
    24: ("BC6H",         16, 4),
    25: ("BC7",          16, 4),
    26: ("BC4",           8, 4),
    27: ("BC5",          16, 4),
    28: ("DXT1Crunched", None, None),
    29: ("DXT5Crunched", None, None),
}

CRUNCHED = {28, 29}


def fmt_name(f):
    return FORMATS.get(f, ("Unknown(%s)" % f, None, None))[0]


def level_size(w, h, fmt):
    """Bytes for one mip level."""
    entry = FORMATS.get(fmt)
    if entry is None or entry[1] is None:
        return None
    _, bpb, edge = entry
    if edge == 1:
        return w * h * bpb
    bw = (w + edge - 1) // edge
    bh = (h + edge - 1) // edge
    return bw * bh * bpb


def payload_len(w, h, fmt, mips, mips_stripped=0):
    """Total bytes of the stored mip chain, from the descriptor alone."""
    total = 0
    for i in range(mips_stripped, max(1, mips)):
        s = level_size(max(1, w >> i), max(1, h >> i), fmt)
        if s is None:
            return None
        total += s
    return total


# ------------------------------------------------------- fact #69 classify

_SEASONS = ("_summer", "_winter", "_autumn", "_spring", "_fall")
_NORMAL = ("_normal", "_nrm", "_nmp", "_nm", "_n")
_GLOSS = ("_gloss", "_g", "_r")
_HEIGHT = ("_displacement", "_h")
_AO = ("_ao",)
_MASK = ("_mask", "_mt", "_m")
_ALBEDO = ("_albedo", "_diffuse", "_dif", "_a2", "_d", "_a", "_c")


def classify(name):
    """Albedo / normal / gloss / ao / height / mask, per fact #69.

    Lowercase, strip the season tail BEFORE looking at the suffix. A bare name
    with no recognised suffix is albedo. Masks are never replaced.
    """
    n = name.lower()
    for s in _SEASONS:
        if n.endswith(s):
            n = n[: -len(s)]
            break
    for group, kind in ((_NORMAL, "normal"), (_GLOSS, "gloss"), (_AO, "ao"),
                        (_HEIGHT, "height"), (_MASK, "mask"), (_ALBEDO, "albedo")):
        for suf in group:
            if n.endswith(suf):
                return kind
    return "albedo"  # bare name, no suffix


# ------------------------------------------------------------------ index

def build_index(assets_path):
    """Enumerate every Texture2D. Needs UnityPy (Store Python)."""
    try:
        import UnityPy  # noqa
    except ImportError:
        sys.exit(
            "FAIL: UnityPy is not importable under this interpreter\n"
            "      (%s).\n"
            "      It is installed only under the Microsoft Store Python. Use:\n"
            "      \"%s\\Microsoft\\WindowsApps\\python.exe\" resspatch.py ..."
            % (sys.executable, os.environ.get("LOCALAPPDATA", "%LOCALAPPDATA%")))
    env = UnityPy.load(assets_path)
    out = []
    for o in env.objects:
        if o.type.name != "Texture2D":
            continue
        d = o.read_typetree()
        sd = d.get("m_StreamData") or {}
        out.append({
            "name": d["m_Name"],
            "path_id": getattr(o, "path_id", None),
            "width": d["m_Width"],
            "height": d["m_Height"],
            "format": d["m_TextureFormat"],
            "format_name": fmt_name(d["m_TextureFormat"]),
            "mips": d.get("m_MipCount", 1),
            "mips_stripped": d.get("m_MipsStripped", 0),
            "complete_image_size": d.get("m_CompleteImageSize"),
            "stream_path": sd.get("path", ""),
            "offset": int(sd.get("offset", 0)),
            "size": int(sd.get("size", 0)),
            "kind": classify(d["m_Name"]),
        })
    return {
        "assets": os.path.abspath(assets_path),
        "assets_size": os.path.getsize(assets_path),
        "generated": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "textures": out,
    }


def load_index(args, assets_path):
    if getattr(args, "index", None):
        with open(args.index, "r", encoding="utf-8") as fh:
            return json.load(fh)
    cached = assets_path + ".resspatch-index.json"
    if os.path.exists(cached) and os.path.getmtime(cached) >= os.path.getmtime(assets_path):
        with open(cached, "r", encoding="utf-8") as fh:
            return json.load(fh)
    idx = build_index(assets_path)
    with open(cached, "w", encoding="utf-8") as fh:
        json.dump(idx, fh, indent=1)
    return idx


def stream_file(assets_path, tex):
    sp = tex["stream_path"]
    if not sp:
        return None
    return os.path.join(os.path.dirname(os.path.abspath(assets_path)),
                        os.path.basename(sp))


# ------------------------------------------------------------- hardlinks

def link_info(path):
    st = os.stat(path)
    return {"links": st.st_nlink, "inode": st.st_ino, "size": st.st_size}


def sha256(path, chunk=1 << 22):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        while True:
            b = fh.read(chunk)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def cmd_unlink(args):
    rc = 0
    for path in args.paths:
        before = link_info(path)
        if before["links"] == 1:
            print("PASS %s already links=1 inode=%d (nothing to do)"
                  % (os.path.basename(path), before["inode"]))
            continue
        print("%s links=%d inode=%d size=%d -- breaking"
              % (os.path.basename(path), before["links"], before["inode"], before["size"]))
        digest = sha256(path)
        tmp = path + ".resspatch-unlink.tmp"
        shutil.copyfile(path, tmp)
        if sha256(tmp) != digest:
            os.remove(tmp)
            print("FAIL copy of %s is not byte-identical -- aborted, nothing changed"
                  % path)
            rc = 1
            continue
        os.replace(tmp, path)
        after = link_info(path)
        identical = sha256(path) == digest
        ok = after["links"] == 1 and after["inode"] != before["inode"] and identical
        print("%s %s links %d->%d inode %d->%d content-identical=%s"
              % ("PASS" if ok else "FAIL", os.path.basename(path),
                 before["links"], after["links"], before["inode"], after["inode"],
                 identical))
        if not ok:
            rc = 1
    return rc


def require_unlinked(path):
    info = link_info(path)
    if info["links"] != 1:
        sys.exit("REFUSED: %s still has links=%d -- it is HARDLINKED to another "
                 "install, and writing it would corrupt that install too. Run "
                 "`resspatch.py unlink` on it first." % (path, info["links"]))


# ------------------------------------------------------------- enumerate

def cmd_enumerate(args):
    idx = load_index(args, args.assets)
    tex = idx["textures"]
    if args.filter:
        f = args.filter.lower()
        tex = [t for t in tex if f in t["name"].lower()]
    if args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump(dict(idx, textures=tex), fh, indent=1)
        print("wrote %s (%d textures)" % (args.json, len(tex)))
    if not args.quiet:
        print("%-40s %-13s %9s %4s %12s %11s  %s"
              % ("name", "format", "dims", "mip", "offset", "length", "kind"))
        for t in sorted(tex, key=lambda t: t["offset"]):
            print("%-40s %-13s %4dx%-4d %4d %12d %11d  %s"
                  % (t["name"][:40], t["format_name"], t["width"], t["height"],
                     t["mips"], t["offset"], t["size"], t["kind"]))
    print("-- %d Texture2D, %d bytes of payload"
          % (len(tex), sum(t["size"] for t in tex)))
    return 0


# ---------------------------------------------------------- verify-length

def check_lengths(idx):
    ok, mismatch, skipped = [], [], []
    for t in idx["textures"]:
        if t["format"] in CRUNCHED:
            skipped.append(t)
            continue
        exp = payload_len(t["width"], t["height"], t["format"], t["mips"],
                          t.get("mips_stripped", 0))
        if exp is None:
            skipped.append(t)
        elif exp == t["size"]:
            ok.append(t)
        else:
            mismatch.append((t, exp))
    return ok, mismatch, skipped


def overlap_report(idx):
    spans = sorted(((t["offset"], t["size"], t["name"]) for t in idx["textures"]
                    if t["stream_path"]), key=lambda s: s[0])
    overlaps, gaps, gap_bytes = [], 0, 0
    end = None
    for off, size, name in spans:
        if end is not None:
            if off < end:
                overlaps.append((name, off, end))
            elif off > end:
                gaps += 1
                gap_bytes += off - end
        end = off + size
    return overlaps, gaps, gap_bytes, (spans[-1][0] + spans[-1][1]) if spans else 0


def cmd_verify_length(args):
    idx = load_index(args, args.assets)
    ok, mismatch, skipped = check_lengths(idx)
    n = len(idx["textures"])
    for t, exp in mismatch:
        print("MISMATCH %-40s %s %dx%d mip%d stored=%d recomputed=%d"
              % (t["name"], t["format_name"], t["width"], t["height"],
                 t["mips"], t["size"], exp))
    for t in skipped:
        print("SKIP     %-40s %s -- variable-length, length cannot be recomputed, "
              "NEVER writable" % (t["name"], t["format_name"]))
    ov, gaps, gap_bytes, packed_end = overlap_report(idx)
    for name, off, end in ov:
        print("OVERLAP  %s at %d overlaps previous payload ending %d" % (name, off, end))
    print("-- %d/%d payload lengths reproduced from (w,h,format,mipCount); "
          "%d skipped (variable-length); %d mismatches"
          % (len(ok), n, len(skipped), len(mismatch)))
    print("-- packing: %d overlaps, %d gaps totalling %d bytes, payload ends at %d"
          % (len(ov), gaps, gap_bytes, packed_end))
    if mismatch or ov:
        print("FAIL verify-length -- writing is REFUSED while any mismatch or "
              "overlap stands")
        return 1
    print("PASS verify-length")
    return 0


# ------------------------------------------------------------------- DDS

DXGI_TO_UNITY = {70: 10, 71: 10, 72: 10, 76: 12, 77: 12, 78: 12,
                 79: 26, 80: 26, 82: 27, 83: 27, 95: 24, 96: 24,
                 97: 25, 98: 25, 99: 25}
FOURCC_TO_UNITY = {b"DXT1": 10, b"DXT5": 12, b"BC4U": 26, b"ATI2": 27, b"BC5U": 27}


def parse_dds(path):
    with open(path, "rb") as fh:
        blob = fh.read()
    if len(blob) < 128 or blob[:4] != b"DDS ":
        sys.exit("REFUSED: %s is not a DDS file" % path)
    height, width = struct.unpack_from("<II", blob, 12)
    mips = struct.unpack_from("<I", blob, 28)[0] or 1
    fourcc = blob[84:88]
    if fourcc == b"DX10":
        dxgi = struct.unpack_from("<I", blob, 128)[0]
        fmt = DXGI_TO_UNITY.get(dxgi)
        hdr = 148
        why = "DX10 dxgiFormat=%d" % dxgi
    else:
        fmt = FOURCC_TO_UNITY.get(fourcc)
        hdr = 128
        why = "fourCC=%r" % fourcc
    if fmt is None:
        sys.exit("REFUSED: %s has an unsupported pixel format (%s)" % (path, why))
    return {"width": width, "height": height, "mips": mips, "format": fmt,
            "payload": blob[hdr:], "source": why}


# ----------------------------------------------------------------- journal

def journal_dir(res_path):
    d = os.path.join(os.path.dirname(os.path.abspath(res_path)), ".resspatch")
    os.makedirs(d, exist_ok=True)
    return d


def journal_path(res_path):
    return os.path.join(journal_dir(res_path), "journal.jsonl")


def read_bytes(path, off, length):
    with open(path, "rb") as fh:
        fh.seek(off)
        b = fh.read(length)
    if len(b) != length:
        sys.exit("REFUSED: %s is too short for offset=%d length=%d" % (path, off, length))
    return b


def cmd_write(args):
    idx = load_index(args, args.assets)
    ok, mismatch, skipped = check_lengths(idx)
    if mismatch:
        sys.exit("REFUSED: verify-length reports %d mismatches; resolve them "
                 "before any write." % len(mismatch))
    hits = [t for t in idx["textures"] if t["name"] == args.texture]
    if len(hits) != 1:
        sys.exit("REFUSED: %d textures named %r (need exactly 1)"
                 % (len(hits), args.texture))
    t = hits[0]
    if t["format"] in CRUNCHED:
        sys.exit("REFUSED: %s is %s -- entropy-coded and variable-length, so a "
                 "same-length overwrite is not possible. Skip it."
                 % (t["name"], t["format_name"]))
    if not t["stream_path"]:
        sys.exit("REFUSED: %s is not streamed to a .resS; in-place patching is "
                 "only implemented for streamed payloads." % t["name"])
    res = stream_file(args.assets, t)
    require_unlinked(res)
    require_unlinked(args.assets)

    dds = parse_dds(args.dds)
    if dds["format"] != t["format"]:
        sys.exit("REFUSED: format mismatch -- asset is %s, DDS is %s (%s)"
                 % (t["format_name"], fmt_name(dds["format"]), dds["source"]))
    if (dds["width"], dds["height"]) != (t["width"], t["height"]):
        sys.exit("REFUSED: dimension mismatch -- asset is %dx%d, DDS is %dx%d"
                 % (t["width"], t["height"], dds["width"], dds["height"]))
    if len(dds["payload"]) != t["size"]:
        sys.exit("REFUSED: length mismatch -- asset payload is %d bytes, DDS "
                 "payload is %d bytes (delta %+d). resspatch NEVER pads and "
                 "NEVER truncates."
                 % (t["size"], len(dds["payload"]), len(dds["payload"]) - t["size"]))

    before = read_bytes(res, t["offset"], t["size"])
    stamp = "%s.%d.%d" % (t["name"], t["offset"], int(time.time() * 1000))
    blob = os.path.join(journal_dir(res), stamp + ".orig")
    with open(blob, "wb") as fh:
        fh.write(before)
    with open(res, "r+b") as fh:
        fh.seek(t["offset"])
        fh.write(dds["payload"])
        fh.flush()
        os.fsync(fh.fileno())
    after = read_bytes(res, t["offset"], t["size"])
    entry = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "file": os.path.abspath(res),
        "texture": t["name"], "offset": t["offset"], "length": t["size"],
        "backup": os.path.basename(blob),
        "sha_before": hashlib.sha256(before).hexdigest(),
        "sha_after": hashlib.sha256(after).hexdigest(),
        "dds": os.path.abspath(args.dds),
    }
    with open(journal_path(res), "a", encoding="utf-8") as fh:
        fh.write(json.dumps(entry) + "\n")
    if after != dds["payload"]:
        print("FAIL write did not land -- read-back differs from the DDS payload")
        return 1
    print("PASS wrote %s: %d bytes at offset %d in %s"
          % (t["name"], t["size"], t["offset"], os.path.basename(res)))
    print("     sha before %s" % entry["sha_before"][:16])
    print("     sha after  %s" % entry["sha_after"][:16])
    print("     restore with: resspatch.py restore %s" % args.assets)
    return 0


def cmd_restore(args):
    idx = load_index(args, args.assets)
    res_files = {stream_file(args.assets, t) for t in idx["textures"] if t["stream_path"]}
    rc = 0
    done = 0
    for res in sorted(f for f in res_files if f):
        jp = journal_path(res)
        if not os.path.exists(jp):
            continue
        with open(jp, "r", encoding="utf-8") as fh:
            entries = [json.loads(l) for l in fh if l.strip()]
        keep = []
        for e in reversed(entries):
            if args.texture and e["texture"] != args.texture:
                keep.append(e)
                continue
            cur = read_bytes(e["file"], e["offset"], e["length"])
            if hashlib.sha256(cur).hexdigest() != e["sha_after"]:
                print("INCONCLUSIVE %s at %d: the bytes there now are not the ones "
                      "this journal entry wrote, so restoring would clobber "
                      "something unknown. Refusing." % (e["texture"], e["offset"]))
                keep.append(e)
                rc = 1
                continue
            with open(os.path.join(journal_dir(res), e["backup"]), "rb") as bf:
                orig = bf.read()
            if hashlib.sha256(orig).hexdigest() != e["sha_before"]:
                print("FAIL backup blob %s does not match sha_before" % e["backup"])
                keep.append(e)
                rc = 1
                continue
            with open(e["file"], "r+b") as fh:
                fh.seek(e["offset"])
                fh.write(orig)
                fh.flush()
                os.fsync(fh.fileno())
            back = read_bytes(e["file"], e["offset"], e["length"])
            if hashlib.sha256(back).hexdigest() != e["sha_before"]:
                print("FAIL restore of %s did not read back as the original" % e["texture"])
                rc = 1
                keep.append(e)
                continue
            print("PASS restored %s (%d bytes at %d)"
                  % (e["texture"], e["length"], e["offset"]))
            done += 1
        with open(jp, "w", encoding="utf-8") as fh:
            for e in reversed(keep):
                fh.write(json.dumps(e) + "\n")
    if done == 0 and rc == 0:
        print("nothing to restore -- journal is empty")
    return rc


# ------------------------------------------------------------------ resync

def bsg_checksum(path, chunk=1 << 22):
    """Byte-sum mod 2**32, reported as a signed int32 -- that is how the shipped
    ConsistencyInfo stores it."""
    total = 0
    with open(path, "rb") as fh:
        while True:
            b = fh.read(chunk)
            if not b:
                break
            total += sum(b)
    total &= 0xFFFFFFFF
    return total - (1 << 32) if total >= (1 << 31) else total


def cmd_resync(args):
    ci = os.path.abspath(args.consistency)
    root = os.path.dirname(ci)
    with open(ci, "r", encoding="utf-8") as fh:
        doc = json.load(fh)
    by_path = {e["Path"]: e for e in doc["Entries"]}
    changed = 0
    rc = 0
    for f in args.files:
        f = os.path.abspath(f)
        rel = os.path.relpath(f, root).replace("/", "\\")
        e = by_path.get(rel)
        if e is None:
            print("FAIL %s is not listed in ConsistencyInfo" % rel)
            rc = 1
            continue
        size = os.path.getsize(f)
        cks = bsg_checksum(f)
        state = "unchanged" if (size == e["Size"] and cks == e["Checksum"]) else "DIFFERS"
        print("%-52s Size %d->%d  Checksum %d->%d  (%s)"
              % (rel, e["Size"], size, e["Checksum"], cks, state))
        if state == "DIFFERS":
            if size != e["Size"]:
                print("     NOTE size changed -- resspatch writes are supposed to "
                      "be length-identical. Investigate before shipping this.")
            e["Size"], e["Checksum"] = size, cks
            changed += 1
    if args.check:
        print("-- check only, %d entr%s would change"
              % (changed, "y" if changed == 1 else "ies"))
        return rc
    if changed:
        tmp = ci + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(doc, fh, separators=(",", ":"))
        os.replace(tmp, ci)
        print("-- rewrote %s, %d entr%s updated"
              % (ci, changed, "y" if changed == 1 else "ies"))
    else:
        print("-- nothing to change")
    return rc


# -------------------------------------------------------------------- main

def main(argv=None):
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    def with_index(sp):
        sp.add_argument("assets")
        sp.add_argument("--index", help="reuse a JSON index instead of parsing")
        return sp

    e = with_index(sub.add_parser("enumerate"))
    e.add_argument("--json")
    e.add_argument("--filter")
    e.add_argument("--quiet", action="store_true")
    e.set_defaults(fn=cmd_enumerate)

    v = with_index(sub.add_parser("verify-length"))
    v.set_defaults(fn=cmd_verify_length)

    u = sub.add_parser("unlink")
    u.add_argument("paths", nargs="+")
    u.set_defaults(fn=cmd_unlink)

    w = with_index(sub.add_parser("write"))
    w.add_argument("--texture", required=True)
    w.add_argument("--dds", required=True)
    w.set_defaults(fn=cmd_write)

    r = with_index(sub.add_parser("restore"))
    r.add_argument("--texture", help="restore only this texture")
    r.set_defaults(fn=cmd_restore)

    c = sub.add_parser("resync")
    c.add_argument("consistency")
    c.add_argument("files", nargs="+")
    c.add_argument("--check", action="store_true")
    c.set_defaults(fn=cmd_resync)

    a = p.parse_args(argv)
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
