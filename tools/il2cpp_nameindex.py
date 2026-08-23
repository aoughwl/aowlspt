#!/usr/bin/env python3
"""il2cpp_nameindex.py -- generate an offline name -> code-RVA index for the host.

## Why this exists

By-name method resolution is DEAD on this build. `findClass`/`findMethod` return
non-nil handles into unmapped memory, and every `MethodInfo` probed is
unreadable -- measured on BOTH the host thread and the Unity main thread (6/6
unreadable on each), so it is not a thread-affinity problem. No MethodInfo means
no token, which means the `Il2CppCodeGenModule.methodPointers` table -- which is
itself sound -- cannot be indexed by name AT RUNTIME.

Everything needed to do it OFFLINE is present, though, and
`tools/il2cpp_resolve.py` already does it for one type at a time. This tool runs
that same resolution over EVERY type in the metadata and freezes the answer into
a binary index the host can binary-search without touching IL2CPP at all.

The resolution chain is `il2cpp_resolve.py`'s, unchanged and imported rather
than reimplemented, so the two cannot drift:

    name -> image -> typeDefinition (typeStart/typeCount)
         -> methodDefinition (methodStart+i, 36 bytes, token@24)
         -> rid = token & 0xFFFFFF
         -> THAT IMAGE's codeGenModule.methodPointers[rid-1] -> VA -> RVA

The per-image selection is not optional. Using `Assembly-CSharp.dll`'s table for
everything is a documented past bug in that resolver: `BattlEye.BEClient` lives
in `Assembly-CSharp-firstpass.dll`. `verify` below checks `BEClient::Update`
precisely because it is in a different image and is independently known from
`abi/aowlspt_beclient.h`.

## Overloads

A name alone is ambiguous: `UnityEngine.AssetBundle::LoadAsset` has two, at
0x5250100 and 0x5250340. So every key carries an arity:

    "Ns.Type::Method/2"     -- exactly the 2-argument overload
    "Ns.Type::Method/*"     -- emitted ONLY when the name has ONE overload

The `/*` form is what makes the host's existing "-1 matches any arity" lookup
safe: it exists when there is nothing to be ambiguous about, and is absent --
so the lookup REFUSES -- the moment there is. `parameterCount` is at byte 34 of
`Il2CppMethodDefinition`, confirmed by dumping both `LoadAsset` overloads and
reading 1 and 2 out of that slot.

## Ambiguous keys are DROPPED, not resolved

Distinct metadata types can produce the same "Ns.Type::Method" string --
compiler-generated closure types (`<>c`), nested types that carry no namespace,
and so on. If one key maps to two DIFFERENT RVAs there is no correct answer, so
the key is removed from the index entirely and lookup reports "not found".
A refusal is recoverable; a wrong-but-mapped address is the corruption the whole
safety discipline exists to prevent. Duplicates that agree on the RVA collapse
harmlessly and are kept.

## Hash, and why a collision cannot survive generation

Entries are `u64 primary hash` (FNV-1a-64), not verbatim names: 8.8 MB of names
versus 3.3 MB, and the host never needs to print a name it did not already have.
Two independent guards make that safe:

  * a PRIMARY collision -- two distinct keys hashing to the same u64 -- is
    detected here, offline, over the complete key set, and generation REFUSES to
    emit. It cannot reach the host.
  * a lookup for a key that is NOT in the index could still hash-hit an entry
    that is. So each entry also stores a 32-bit CHECK hash from an independent
    basis/prime, verified after the binary search. A false hit needs both to
    collide: ~2^-96.

## Staleness is the main hazard

A stale RVA is a wrong-but-mapped function -- worse than a missing one. The
index is stamped with two keys:

  * `imageKey`  -- packed from the PE headers (TimeDateStamp, SizeOfImage,
    AddressOfEntryPoint, CheckSum). These do not change when the module is
    loaded, so the HOST can verify it in microseconds against the already-mapped
    GameAssembly.dll, with no file I/O and no 124 MB hash.
  * `fileHash`  -- SHA-256 of GameAssembly.dll, truncated to 64 bits. Stronger,
    and what `check` verifies at build time.

On mismatch the host refuses the WHOLE index rather than serving any entry from
it. Prologue byte-verification before patching is still mandatory regardless --
this stamp narrows the window, it does not replace the check.

## Usage

  il2cpp_nameindex.py gen    <GameAssembly.dll> <global-metadata.dec.dat> <out.idx>
  il2cpp_nameindex.py verify <GameAssembly.dll> <global-metadata.dec.dat>
  il2cpp_nameindex.py check  <GameAssembly.dll> <out.idx>
  il2cpp_nameindex.py lookup <out.idx> <Ns.Type::Method> [arity]

`check` is the build-time guard: it re-derives the stamp from the DLL present
and fails loudly when the index does not belong to it.
"""
import hashlib
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from il2cpp_resolve import Resolver, load_pe  # noqa: E402

MAGIC = b"AOWLNIDX"
VERSION = 1
HEADER = 40  # magic8 ver4 count4 imageKey8 fileHash8 flags4 pad4

# -- the two hashes. Independent basis AND prime, so a primary collision does
#    not drag the check along with it.
FNV64_BASIS, FNV64_PRIME = 0xCBF29CE484222325, 0x100000001B3
CHK64_BASIS, CHK64_PRIME = 0x9E3779B97F4A7C15, 0x00000100000001B7
M64 = (1 << 64) - 1


def h_primary(s: bytes) -> int:
    h = FNV64_BASIS
    for c in s:
        h = ((h ^ c) * FNV64_PRIME) & M64
    return h


def h_check(s: bytes) -> int:
    h = CHK64_BASIS
    for c in s:
        h = ((h ^ c) * CHK64_PRIME) & M64
    # fold to 32 bits, using the HIGH half so it does not share low-bit
    # structure with the primary
    return ((h >> 32) ^ (h & 0xFFFFFFFF)) & 0xFFFFFFFF


def pe_image_key(path):
    """A build identity readable from the LOADED module, not just the file.

    TimeDateStamp/SizeOfImage/AddressOfEntryPoint/CheckSum all live in headers
    that are mapped verbatim and are not touched by the loader, so the host can
    reproduce this from GameAssemblyBase without reading the file back.
    """
    b = open(path, "rb").read(0x400)
    e = struct.unpack_from("<I", b, 0x3C)[0]
    coff = e + 4
    tds = struct.unpack_from("<I", b, coff + 4)[0]
    opt = coff + 20
    entry = struct.unpack_from("<I", b, opt + 16)[0]
    sizeimg = struct.unpack_from("<I", b, opt + 56)[0]
    csum = struct.unpack_from("<I", b, opt + 64)[0]
    k = (tds ^ (sizeimg * 0x100000001B3)) & M64
    k = ((k * FNV64_PRIME) ^ entry) & M64
    k = ((k * FNV64_PRIME) ^ csum) & M64
    return k, (tds, sizeimg, entry, csum)


def file_hash(path):
    hsh = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            chunk = f.read(1 << 20)
            if not chunk:
                break
            hsh.update(chunk)
    return struct.unpack_from("<Q", hsh.digest(), 0)[0]


def build_keys(R, report=None):
    """Walk every type and return {key_string: rva}, ambiguities removed.

    Returns (keys, stats). `stats` carries the counts the report needs, and in
    particular `dropped` -- keys that had two different RVAs and were therefore
    excluded rather than guessed at.
    """
    PC_OFF = 34  # parameterCount, u16 -- confirmed against both LoadAsset overloads
    exact = {}
    exact_bad = set()
    by_name = {}   # "Ns.Type::Method" -> set of (arity, rva)
    ntypes = nmeth = nomap = 0

    for t in range(R.NTYPES):
        ns, nm = R.tname(t)
        full = (ns + "." + nm) if ns else nm
        img = R.image_of_type(t)
        mp = R.MOD.get(img)
        if not mp:
            continue
        base, cnt = mp
        if not base:
            continue
        ntypes += 1
        for mi in R.type_methods(t):
            nmeth += 1
            rid = R.mtoken(mi) & 0xFFFFFF
            if not (1 <= rid <= cnt):
                nomap += 1
                continue
            va = R.rq(base + (rid - 1) * 8)
            if not va:
                nomap += 1
                continue
            rva = va - R.IB
            if not (0 < rva < (1 << 32)):
                nomap += 1
                continue
            arity = struct.unpack_from("<H", R.m, R.M_OFF + mi * R.MS + PC_OFF)[0]
            mname = R.mname(mi)
            spec = full + "::" + mname
            k = "%s/%d" % (spec, arity)
            prev = exact.get(k)
            if prev is not None and prev != rva:
                exact_bad.add(k)          # two different answers -> no answer
            else:
                exact[k] = rva
            by_name.setdefault(spec, set()).add((arity, rva))

    for k in exact_bad:
        exact.pop(k, None)

    # `/*` only where the name is unambiguous: exactly one arity AND one RVA.
    star = 0
    for spec, variants in by_name.items():
        if len(variants) != 1:
            continue
        arity, rva = next(iter(variants))
        if ("%s/%d" % (spec, arity)) not in exact:
            continue      # its exact key was dropped; do not resurrect it here
        exact[spec + "/*"] = rva
        star += 1

    stats = dict(types=ntypes, methods=nmeth, unmapped=nomap,
                 dropped=len(exact_bad), star=star, names=len(by_name),
                 keys=len(exact))
    return exact, stats


def pack(keys, image_key, fhash):
    """Sort by primary hash, refuse on ANY primary collision, emit SoA."""
    rows = []
    for k, rva in keys.items():
        kb = k.encode("utf8")
        rows.append((h_primary(kb), h_check(kb), rva, k))
    rows.sort(key=lambda r: r[0])

    for i in range(1, len(rows)):
        if rows[i][0] == rows[i - 1][0]:
            raise SystemExit(
                "REFUSING TO EMIT: 64-bit primary hash collision between\n"
                "    %r\n    %r\nboth -> 0x%016x. A collision cannot be allowed "
                "to reach the host, where it would be a silent wrong address. "
                "Change the hash basis and regenerate."
                % (rows[i - 1][3], rows[i][3], rows[i][0]))

    n = len(rows)
    out = bytearray()
    out += MAGIC
    out += struct.pack("<II", VERSION, n)
    out += struct.pack("<QQ", image_key, fhash)
    out += struct.pack("<II", 0, 0)
    assert len(out) == HEADER
    out += b"".join(struct.pack("<Q", r[0]) for r in rows)
    out += b"".join(struct.pack("<I", r[2]) for r in rows)
    out += b"".join(struct.pack("<I", r[1]) for r in rows)
    return bytes(out)


def read_index(path):
    b = open(path, "rb").read()
    if len(b) < HEADER or b[:8] != MAGIC:
        sys.exit("not an aowlspt name index: " + path)
    ver, n = struct.unpack_from("<II", b, 8)
    ikey, fhash = struct.unpack_from("<QQ", b, 16)
    want = HEADER + n * 16
    if ver != VERSION:
        sys.exit("index version %d, this tool speaks %d" % (ver, VERSION))
    if len(b) != want:
        sys.exit("index truncated: %d bytes, header claims %d entries (%d)"
                 % (len(b), n, want))
    return b, n, ikey, fhash


def idx_lookup(b, n, key):
    hs = HEADER
    rs = hs + n * 8
    cs = rs + n * 4
    kb = key.encode("utf8")
    want, chk = h_primary(kb), h_check(kb)
    lo, hi = 0, n - 1
    guard = 0
    while lo <= hi:
        guard += 1
        if guard > 64:
            return None
        mid = (lo + hi) // 2
        got = struct.unpack_from("<Q", b, hs + mid * 8)[0]
        if got == want:
            if struct.unpack_from("<I", b, cs + mid * 4)[0] != chk:
                return None       # primary hit, check hash disagrees -> not ours
            return struct.unpack_from("<I", b, rs + mid * 4)[0]
        if got < want:
            lo = mid + 1
        else:
            hi = mid - 1
    return None


# -- the cross-check set. Every RVA here is independently known: from
#    abi/aowlspt_bridge.h, abi/aowlspt_beclient.h and docs/SETTINGS.md.
#    BEClient::Update is the strongest single entry, because it lives in
#    Assembly-CSharp-firstpass.dll and is only correct if per-image
#    methodPointers selection is correct.
KNOWN = [
    ("UnityEngine.AssetBundle::LoadAsset", 1, 0x5250100),
    ("UnityEngine.AssetBundle::LoadAsset", 2, 0x5250340),
    ("EFT.TarkovApplication::Update", None, 0x977B10),
    ("EFT.GameWorld::Update", None, 0x2500A20),
    ("UnityEngine.Time::get_deltaTime", None, 0x7E99B0),
    ("BattlEye.BEClient::Update", None, 0x669390),
    ("BattlEye.BEClient::Stop", None, 0x668E80),
    ("BattlEye.BEClient::Run", None, 0x667700),
    ("BattlEye.BEClient::IsInstanceSuccessfully", None, 0x6699C0),
]


def cross_check(get, label):
    print("%-52s %-10s %-10s %s" % ("KEY", "EXPECTED", "GOT", ""))
    ok = True
    for spec, arity, exp in KNOWN:
        key = "%s/%d" % (spec, arity) if arity is not None else spec + "/*"
        got = get(key)
        good = got == exp
        ok = ok and good
        print("%-52s 0x%-8X %-10s %s"
              % (key, exp, ("0x%X" % got) if got is not None else "NOT FOUND",
                 "OK" if good else "MISMATCH"))
    print(("ALL %d CROSS-CHECKS REPRODUCED (%s)" % (len(KNOWN), label))
          if ok else ("CROSS-CHECK FAILED (%s)" % label))
    return ok


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    cmd = sys.argv[1]

    if cmd == "gen":
        gameasm, metadec, out = sys.argv[2], sys.argv[3], sys.argv[4]
        R = Resolver(gameasm, metadec)
        keys, st = build_keys(R)
        ikey, parts = pe_image_key(gameasm)
        fhash = file_hash(gameasm)
        blob = pack(keys, ikey, fhash)
        open(out, "wb").write(blob)
        print("types=%d methods=%d unmapped=%d" % (st["types"], st["methods"], st["unmapped"]))
        print("distinct names=%d  exact keys+star=%d  '/*' keys=%d"
              % (st["names"], st["keys"], st["star"]))
        print("AMBIGUOUS KEYS DROPPED (two different RVAs, so no correct "
              "answer): %d" % st["dropped"])
        print("imageKey=0x%016X (TimeDateStamp=0x%08X SizeOfImage=0x%X "
              "Entry=0x%X CheckSum=0x%08X)" % ((ikey,) + parts))
        print("fileHash=0x%016X" % fhash)
        print("wrote %s: %d entries, %d bytes (%.2f MB)"
              % (out, (len(blob) - HEADER) // 16, len(blob),
                 len(blob) / 1048576.0))
        b, n, _, _ = read_index(out)
        sys.exit(0 if cross_check(lambda k: idx_lookup(b, n, k), "from the emitted index") else 1)

    if cmd == "verify":
        R = Resolver(sys.argv[2], sys.argv[3])
        keys, _ = build_keys(R)
        sys.exit(0 if cross_check(keys.get, "from il2cpp_resolve walk") else 1)

    if cmd == "check":
        gameasm, idx = sys.argv[2], sys.argv[3]
        b, n, ikey, fhash = read_index(idx)
        wk, parts = pe_image_key(gameasm)
        wf = file_hash(gameasm)
        print("index:  imageKey=0x%016X fileHash=0x%016X entries=%d" % (ikey, fhash, n))
        print("dll:    imageKey=0x%016X fileHash=0x%016X" % (wk, wf))
        if ikey != wk or fhash != wf:
            sys.exit("STALE INDEX: it was generated from a DIFFERENT "
                     "GameAssembly.dll than the one present. Every RVA in it is "
                     "a wrong-but-mapped address. Regenerate with `gen`.")
        ok = cross_check(lambda k: idx_lookup(b, n, k), "index vs known RVAs")
        print("INDEX MATCHES THE DLL PRESENT" if ok else "stamp matched but cross-check FAILED")
        sys.exit(0 if ok else 1)

    if cmd == "lookup":
        b, n, _, _ = read_index(sys.argv[2])
        spec = sys.argv[3]
        key = spec + "/" + (sys.argv[4] if len(sys.argv) > 4 else "*")
        r = idx_lookup(b, n, key)
        print("%s -> %s" % (key, ("0x%X" % r) if r is not None else
                            "NOT FOUND (absent, or ambiguous and therefore dropped)"))
        sys.exit(0 if r is not None else 1)

    sys.exit(__doc__)


if __name__ == "__main__":
    main()
