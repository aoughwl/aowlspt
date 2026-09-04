#!/usr/bin/env python
"""Kernel census of an nvngx_dlssnr.dll: every CUDA fatbin, every cubin, per arch.

    python tools/dlssnr_census.py <dll> [--kernel NAME] [--compare OTHER.dll] [--json OUT]

Pure Python (struct + stdlib zstd/zlib; LZ4 block decoder inlined).  Reads the
file, never writes anything but the optional --json.  Measured facts it prints:

  * every fatbin (magic 0xBA55ED50) and every entry in it: kind (PTX/ELF), the
    arch the fatbin header claims, compression (raw / zstd / zlib / lz4 decided
    by payload MAGIC, not by a flag bit), stored and decoded sizes;
  * for every decoded cubin: e_flags, the sm the ELF itself says (bits 8..15 of
    e_flags -- NOT the low byte; the low byte is 0x02/0x04 on this build), the
    kernel names (.text.* sections, cross-checked against STT_FUNC symbols),
    per-kernel .text bytes, the count of kernels named *_fp8 vs not;
  * with --kernel NAME: NAME and NAME_fp8 on every arch -- .text bytes, SASS
    instruction count (bytes/16, Volta+ fixed width) and a histogram of the low
    12 opcode bits of each instruction (raw numbers; the mapping of 0x23c to
    HMMA and 0x27a to QMMA is INFERRED from public SASS tables, so it is
    printed as a number, not a mnemonic);
  * with --compare OTHER: which entries are byte-identical between the two
    files after decoding, and the byte runs that differ OUTSIDE the fatbins
    (host code / resources), with PE section attribution.

Three-state where it matters: an entry that fails to decode is reported as
UNDECODED, never counted as "no kernels".
"""
import argparse
import collections
import hashlib
import json
import re
import struct
import zlib

ELF_MAGIC = b"\x7fELF"
FATBIN_MAGIC = struct.pack("<I", 0xBA55ED50)
ZSTD_MAGIC = bytes.fromhex("28b52ffd")


def lz4_block(src):
    dst = bytearray()
    i = 0
    n = len(src)
    while i < n:
        tok = src[i]
        i += 1
        lit = tok >> 4
        if lit == 15:
            while True:
                b = src[i]
                i += 1
                lit += b
                if b != 255:
                    break
        dst += src[i:i + lit]
        i += lit
        if i >= n:
            break
        off = src[i] | (src[i + 1] << 8)
        i += 2
        if off == 0:
            raise ValueError("lz4: zero offset")
        ml = tok & 0xF
        if ml == 15:
            while True:
                b = src[i]
                i += 1
                ml += b
                if b != 255:
                    break
        ml += 4
        start = len(dst) - off
        if start < 0:
            raise ValueError("lz4: bad offset")
        if off >= ml:
            dst += dst[start:start + ml]
        else:
            chunk = dst[start:]
            while ml > 0:
                take = min(ml, len(chunk))
                dst += chunk[:take]
                ml -= take
    return bytes(dst)


def pe_sections(buf):
    e = struct.unpack_from("<I", buf, 0x3c)[0]
    nsec = struct.unpack_from("<H", buf, e + 6)[0]
    optsz = struct.unpack_from("<H", buf, e + 20)[0]
    p = e + 24 + optsz
    out = []
    for _ in range(nsec):
        name, vsize, va, rsize, raw = struct.unpack_from("<8sIIII", buf, p)
        p += 40
        out.append((name.rstrip(b"\0").decode(), va, vsize, raw, rsize))
    return out


def section_of(secs, off):
    for n, va, vs, raw, rs in secs:
        if raw <= off < raw + rs:
            return "%s+0x%x (RVA 0x%x)" % (n, off - raw, va + off - raw)
    return "header/none"


def parse_fatbins(buf):
    out = []
    pos = 0
    while True:
        pos = buf.find(FATBIN_MAGIC, pos)
        if pos < 0:
            break
        magic, ver, hsz, payload = struct.unpack_from("<IHHQ", buf, pos)
        fb = {"base": pos, "version": ver, "header_size": hsz, "payload": payload, "entries": []}
        p = pos + hsz
        endp = p + payload
        while p + 64 <= min(endp, len(buf)):
            (kind, unk1, ehsz, size, csize, unk2, minor, major, arch, oname_off, oname_len,
             flags, zero, dsize) = struct.unpack_from("<HHIQIIHHIIIQQQ", buf, p)
            if kind not in (1, 2) or ehsz == 0 or size == 0:
                break
            fb["entries"].append({"off": p, "kind": {1: "PTX", 2: "ELF"}[kind], "hdr": ehsz, "size": size,
                                  "csize": csize, "arch": arch, "flags": flags, "dsize": dsize})
            p += ehsz + size
        out.append(fb)
        pos += 4
    return out


def decode_entry(buf, e):
    payload = buf[e["off"] + e["hdr"]: e["off"] + e["hdr"] + e["size"]]
    if payload[:4] == ZSTD_MAGIC:
        from compression import zstd  # Python 3.14+ stdlib
        return zstd.decompress(payload[: e["csize"] or len(payload)]), "zstd"
    if payload[:1] == b"\x78":
        return zlib.decompress(payload[: e["csize"] or len(payload)]), "zlib"
    if payload.startswith(ELF_MAGIC) or payload.lstrip(b"\n\r\0").startswith((b"//", b".version")):
        return payload, "raw"
    if e["csize"]:
        return lz4_block(payload[: e["csize"]]), "lz4"
    return payload, "raw?"


def parse_cubin(blob):
    if blob[:4] != ELF_MAGIC or blob[4] != 2:
        return None
    e_machine = struct.unpack_from("<H", blob, 18)[0]
    e_shoff, e_flags = struct.unpack_from("<QI", blob, 40)
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", blob, 58)
    if e_machine != 0xBE or e_shentsize != 64:
        return {"e_machine": e_machine, "note": "not a CUDA ELF64"}
    shdrs = [struct.unpack_from("<IIQQQQIIQQ", blob, e_shoff + i * 64) for i in range(e_shnum)]
    shstr = shdrs[e_shstrndx]

    def nm(off):
        s = shstr[4] + off
        return blob[s:blob.find(b"\0", s)].decode("latin1")

    names = [nm(sh[0]) for sh in shdrs]
    text = {n[6:]: sh[5] for n, sh in zip(names, shdrs) if n.startswith(".text.")}
    funcs = set()
    for n, sh in zip(names, shdrs):
        if sh[1] == 2:
            strtab = shdrs[sh[6]]
            for k in range(sh[5] // 24):
                st_name, st_info = struct.unpack_from("<IB", blob, sh[4] + k * 24)
                if st_info & 0xF == 2:
                    s = strtab[4] + st_name
                    funcs.add(blob[s:blob.find(b"\0", s)].decode("latin1"))
    return {"e_flags": e_flags, "sm": (e_flags >> 8) & 0xFF, "low_byte": e_flags & 0xFF, "text": text,
            "kernels": sorted(text), "func_syms_match": funcs == set(text),
            "sections": [(n, sh[4], sh[5]) for n, sh in zip(names, shdrs)]}


def opcode_hist(blob, off, size):
    h = collections.Counter()
    for i in range(off, off + size - 15, 16):
        h[struct.unpack_from("<Q", blob, i)[0] & 0xFFF] += 1
    return h


def census(path, kernel=None):
    buf = open(path, "rb").read()
    secs = pe_sections(buf)
    rows = []
    for fi, fb in enumerate(parse_fatbins(buf)):
        for ei, e in enumerate(fb["entries"]):
            row = dict(fatbin=fi, fatbin_off=fb["base"], entry=ei, kind=e["kind"], arch=e["arch"],
                       flags=e["flags"], stored=e["size"], hdr=e["hdr"])
            try:
                blob, how = decode_entry(buf, e)
            except Exception as ex:  # noqa: BLE001 - report, never hide
                row.update(how="UNDECODED: %s" % ex, decoded=None, kernels=[])
                rows.append(row)
                continue
            row.update(how=how, decoded=len(blob), sha256=hashlib.sha256(blob).hexdigest(),
                       size_matches_header=(not e["dsize"]) or e["dsize"] == len(blob))
            if e["kind"] == "ELF":
                c = parse_cubin(blob)
                if not c or "kernels" not in c:
                    row.update(note="NOT A CUDA CUBIN after decode", kernels=[])
                    rows.append(row)
                    continue
                row.update(e_flags=c["e_flags"], elf_sm=c["sm"], e_flags_low=c["low_byte"],
                           kernels=c["kernels"], text=c["text"], func_syms_match=c["func_syms_match"])
                if kernel:
                    sd = {n: (o, s) for n, o, s in c["sections"]}
                    row["probe"] = {}
                    for kn in (kernel, kernel + "_fp8"):
                        if ".text." + kn in sd:
                            off, size = sd[".text." + kn]
                            h = opcode_hist(blob, off, size)
                            row["probe"][kn] = {"text": size, "instr": size // 16,
                                                "opc_0x23c": h.get(0x23c, 0), "opc_0x27a": h.get(0x27a, 0),
                                                "top": [(hex(k), v) for k, v in h.most_common(6)]}
            else:
                row["ptx_targets"] = sorted({t.decode() for t in re.findall(rb"\.target\s+(\S+)", blob)})
                row["kernels"] = [x.decode() for x in re.findall(rb"\.entry\s+([A-Za-z0-9_$]+)", blob)]
                row["ptx_ops"] = {k: blob.count(k.encode())
                                  for k in ("e4m3", "e5m2", "mma.sync", "wgmma", ".f16", ".bf16")}
                row["crlf"] = blob.count(b"\r\n")
            rows.append(row)
    return buf, secs, rows


def summarise(label, rows):
    print("== %s: %d fatbin entries" % (label, len(rows)))
    per = collections.defaultdict(lambda: dict(objs=0, k=0, fp8=0, non=0, stored=0, decoded=0, how=set(),
                                               names=set(), text_fp8=0, text_non=0))
    for r in rows:
        p = per[(r["kind"], r["arch"])]
        p["objs"] += 1
        p["stored"] += r["stored"]
        p["decoded"] += r.get("decoded") or 0
        p["how"].add(r["how"])
        ks = r.get("kernels", [])
        p["k"] += len(ks)
        p["fp8"] += sum("_fp8" in x for x in ks)
        p["non"] += sum("_fp8" not in x for x in ks)
        p["names"] |= set(ks)
        for n, sz in r.get("text", {}).items():
            p["text_fp8" if "_fp8" in n else "text_non"] += sz
    for key in sorted(per):
        p = per[key]
        extra = ""
        if key[0] == "ELF":
            extra = "  .text fp8=%d B (%d instr) non-fp8=%d B (%d instr)" % (
                p["text_fp8"], p["text_fp8"] // 16, p["text_non"], p["text_non"] // 16)
        print("  %s sm_%d: objs=%d kernels=%d (_fp8=%d non=%d distinct=%d) stored=%d decoded=%d via %s%s" % (
            key[0], key[1], p["objs"], p["k"], p["fp8"], p["non"], len(p["names"]), p["stored"], p["decoded"],
            "/".join(sorted(p["how"])), extra))
    und = [r for r in rows if r["how"].startswith("UNDECODED") or r.get("note")]
    if und:
        print("  UNDECODED/odd entries: %d -> %s" % (
            len(und), [(r["fatbin"], r["entry"], r["how"], r.get("note")) for r in und]))
    bad = [(r["fatbin"], r["entry"]) for r in rows if r.get("size_matches_header") is False]
    if bad:
        print("  decoded size != header decompressed size:", bad)
    mism = [(r["fatbin"], r["entry"]) for r in rows if r.get("func_syms_match") is False]
    if mism:
        print("  STT_FUNC symbols != .text.* sections:", mism)
    for r in rows:
        for kn, pr in (r.get("probe") or {}).items():
            print("  probe fb%02d sm_%-3d %-48s %7d B %5d instr opc[0x23c]=%4d opc[0x27a]=%4d top=%s" % (
                r["fatbin"], r["arch"], kn, pr["text"], pr["instr"], pr["opc_0x23c"], pr["opc_0x27a"], pr["top"]))
    return per


def compare(a, rows_a, secs_a, b, rows_b, label_a, label_b):
    key = lambda r: (r["fatbin"], r["kind"], r["arch"])  # noqa: E731
    sha_b = {key(r): r.get("sha256") for r in rows_b}
    same = [key(r) for r in rows_a if r.get("sha256") and sha_b.get(key(r)) == r["sha256"]]
    print("== compare: %d of %d %s entries byte-identical (after decode) to the same fatbin/kind/arch in %s" % (
        len(same), len(rows_a), label_a, label_b))
    fa, fbs = parse_fatbins(a), parse_fatbins(b)
    if [f["base"] for f in fa] != [f["base"] for f in fbs]:
        print("  fatbin offsets differ; host diff skipped")
        return
    n = min(len(a), len(b))
    mask = bytearray(n)
    for x, y in zip(fa, fbs):
        s, e = x["base"], x["base"] + 16 + max(x["payload"], y["payload"])
        mask[s:e] = b"\1" * (min(e, n) - s)
    runs = []
    ch = 1 << 16
    for c in range(0, n, ch):
        pa, pb = a[c:min(c + ch, n)], b[c:min(c + ch, n)]
        if pa != pb:
            for i in range(len(pa)):
                if pa[i] != pb[i] and not mask[c + i]:
                    if runs and runs[-1][1] == c + i:
                        runs[-1][1] = c + i + 1
                    else:
                        runs.append([c + i, c + i + 1])
    print("  outside the fatbins: %d differing byte runs, %d bytes; sizes %d vs %d" % (
        len(runs), sum(e - s for s, e in runs), len(a), len(b)))
    for s, e in runs[:12]:
        print("    0x%x len %d in %s | %s: %s | %s: %s" % (
            s, e - s, section_of(secs_a, s), label_a, a[s - 4:e + 4].hex(" "), label_b, b[s - 4:e + 4].hex(" ")))
    if len(runs) > 12:
        print("    ... (%d more runs; a run count this large means a whole region MOVED -- "
              "check the resource directory before calling it 'changed')" % (len(runs) - 12))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dll")
    ap.add_argument("--kernel")
    ap.add_argument("--compare")
    ap.add_argument("--json")
    args = ap.parse_args()
    a, secs_a, rows_a = census(args.dll, args.kernel)
    summarise(args.dll, rows_a)
    out = {"dll": args.dll, "rows": rows_a}
    if args.compare:
        b, secs_b, rows_b = census(args.compare, args.kernel)
        summarise(args.compare, rows_b)
        compare(a, rows_a, secs_a, b, rows_b, args.dll, args.compare)
        out["compare"] = {"dll": args.compare, "rows": rows_b}
    if args.json:
        json.dump(out, open(args.json, "w"), indent=1, default=list)
        print("json ->", args.json)


if __name__ == "__main__":
    main()
