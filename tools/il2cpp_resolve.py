#!/usr/bin/env python3
"""il2cpp_resolve.py -- offline type::method -> code RVA for the EFT IL2CPP build.

This is the resolver that produced every static RVA in `abi/aowlspt_bridge.h` and
that reproduces, byte-for-byte, all five BE-bypass RVAs in `abi/aowlspt_beclient.h`
and every VA in `docs/SETTINGS.md`. Those two independent ground truths are what
make its output trustworthy.

## Why a per-module resolver (the bug this fixes)

IL2CPP stores compiled method addresses in a PER-ASSEMBLY table:
`Il2CppCodeGenModule.methodPointers`, indexed by `(method_token & 0xFFFFFF) - 1`.
A method's token RID is per-IMAGE, so you MUST use the methodPointers table of the
image the method's declaring type belongs to. An earlier version used
`Assembly-CSharp.dll`'s table for every type; that silently misresolves any type
in another module -- e.g. `BattlEye.BEClient`, which lives in
`Assembly-CSharp-firstpass.dll` (table base 0x186BF1380), not Assembly-CSharp.dll.

So: type -> its image (metadata images table, by typeStart/typeCount range) ->
that image's codeGenModule (matched by name) -> methodPointers[rid-1] -> VA ->
RVA (VA - imagebase). Then byte-verify the prologue against GameAssembly.dll.

## Inputs (all offline; the game is never run)

  GAMEASM   path to GameAssembly.dll (D:/Games/Tarkov/GameAssembly.dll)
  METADEC   path to the DECRYPTED global-metadata.dat. Produce it with
            `tools/metablob.py` + the installed layout blob:
                from metablob import decrypt_with_layout, parse_layout, ...
            or via the MetadataDecryptor pipeline. The encrypted file on disk
            will NOT parse -- it must be decrypted first.

## Metadata header offsets (this build, 1.1.0.1.46777)

The decrypted header is `magic(4) version(4)` then 31 (offset,size) int32 pairs.
Property i lives at byte `8 + i*8`. For this build:
  prop 2  = string table         -> STR_OFF (strings are NUL-terminated)
  prop 5  = methods              (Il2CppMethodDefinition, 36 bytes)
  prop 19 = typeDefinitions      (Il2CppTypeDefinition, 88 bytes)
  prop 20 = images               (Il2CppImageDefinition, 40 bytes)
The values below are read from that header at runtime, not hardcoded, so this
stays correct if BSG shuffles section sizes within the same struct layout.

Field offsets within the structs (v31, this build):
  Il2CppTypeDefinition:  nameIndex@0, namespaceIndex@4, methodStart@36 (int32),
                         methodCount@64 (uint16)
  Il2CppMethodDefinition: nameIndex@0, token@24 (uint32)
  Il2CppImageDefinition: nameIndex@0, assemblyIndex@4, typeStart@8, typeCount@12

Usage:
  il2cpp_resolve.py <GameAssembly.dll> <global-metadata.dec.dat> find <substr>
  il2cpp_resolve.py <GameAssembly.dll> <global-metadata.dec.dat> type <idx>...
  il2cpp_resolve.py <GameAssembly.dll> <global-metadata.dec.dat> verify-be
"""
import struct, sys


def load_pe(path):
    b = open(path, "rb").read()
    e_lfanew = struct.unpack_from("<I", b, 0x3C)[0]
    assert b[e_lfanew:e_lfanew+4] == b"PE\0\0"
    coff = e_lfanew + 4
    nsec = struct.unpack_from("<H", b, coff+2)[0]
    optsz = struct.unpack_from("<H", b, coff+16)[0]
    opt = coff + 20
    imagebase = struct.unpack_from("<Q", b, opt+24)[0]
    sect = opt + optsz
    secs = []
    for i in range(nsec):
        o = sect + i*40
        name = b[o:o+8].rstrip(b"\0").decode("latin1")
        vsize, vaddr, rawsize, rawptr = struct.unpack_from("<IIII", b, o+8)
        secs.append((name, vaddr, vsize, rawptr, rawsize))
    return b, imagebase, secs


class Resolver:
    def __init__(self, gameasm, metadec):
        self.b, self.IB, self.SEC = load_pe(gameasm)
        self.m = open(metadec, "rb").read()
        if self.m[:4] != b"\xAF\x1B\xB1\xFA":
            sys.exit("metadata is not decrypted (magic AF 1B B1 FA missing); "
                     "decrypt it with tools/metablob.py first")
        prop = lambda i: struct.unpack_from("<ii", self.m, 8 + i*8)
        self.STR_OFF = prop(2)[0]
        self.M_OFF, self.M_SIZE = prop(5)
        self.TD_OFF, self.TD_SIZE = prop(19)
        self.IMG_OFF, self.IMG_SIZE = prop(20)
        self.TDS, self.MS, self.IMGS = 88, 36, 40
        self.NTYPES = self.TD_SIZE // self.TDS
        self._modules()
        self._images()

    # -- PE address helpers
    def v2f(self, va):
        r = va - self.IB
        for _, vs, vz, raw, rz in self.SEC:
            if vs <= r < vs + vz:
                off = r - vs
                return raw + off if off < rz else None
        return None

    def rq(self, va):
        fo = self.v2f(va)
        return struct.unpack_from("<Q", self.b, fo)[0] if fo is not None else None

    def cstr_va(self, va):
        fo = self.v2f(va)
        if fo is None:
            return None
        e = self.b.index(b"\0", fo)
        return self.b[fo:e].decode("utf8", "replace")

    def f2v(self, fo):
        for _, vs, vz, raw, rz in self.SEC:
            if raw <= fo < raw + rz:
                return self.IB + vs + (fo - raw)
        return None

    # -- metadata strings
    def s(self, i):
        if i < 0:
            return "<none>"
        p = self.STR_OFF + i
        e = self.m.index(b"\0", p)
        return self.m[p:e].decode("utf8", "replace")

    # -- enumerate codeGenModules generically: a run of pointers, each to a
    #    struct whose +0 is a "*.dll" string, +8 a count, +16 a methodPointers ptr
    def _modules(self):
        self.MOD = {}

        def looks(p):
            if not p:
                return None
            nm = self.rq(p)
            if nm is None:
                return None
            ss = self.cstr_va(nm)
            return ss if (ss and ss.endswith(".dll")) else None
        # scan .data for any module struct, then widen to its array neighbours
        seen = set()
        for name, vs, vz, raw, rz in self.SEC:
            if name not in (".data", ".rdata"):
                continue
            for fo in range(raw, raw + (rz & ~7), 8):
                p = struct.unpack_from("<Q", self.b, fo)[0]
                if p in seen or not looks(p):
                    continue
                cnt = struct.unpack_from("<I", self.b, self.v2f(p) + 8)[0]
                mptr = self.rq(p + 16)
                nm = looks(p)
                if 0 <= cnt < 300000 and (mptr is None or self.v2f(mptr) is not None):
                    self.MOD[nm] = (mptr, cnt)
                    seen.add(p)

    def _images(self):
        self.IMAGES = []
        for k in range(self.IMG_SIZE // self.IMGS):
            base = self.IMG_OFF + k*self.IMGS
            ni, ai, ts, tc = struct.unpack_from("<iiiI", self.m, base)
            self.IMAGES.append((self.s(ni), ts, tc))

    def image_of_type(self, t):
        for nm, ts, tc in self.IMAGES:
            if ts <= t < ts + tc:
                return nm
        return None

    def tname(self, t):
        bb = self.TD_OFF + t*self.TDS
        ni, nsi = struct.unpack_from("<ii", self.m, bb)
        return self.s(nsi), self.s(ni)

    def type_methods(self, t):
        bb = self.TD_OFF + t*self.TDS
        ms = struct.unpack_from("<i", self.m, bb+36)[0]
        mc = struct.unpack_from("<H", self.m, bb+64)[0]
        return range(ms, ms+mc)

    def mname(self, mi):
        return self.s(struct.unpack_from("<i", self.m, self.M_OFF + mi*self.MS)[0])

    def mtoken(self, mi):
        return struct.unpack_from("<I", self.m, self.M_OFF + mi*self.MS + 24)[0]

    def resolve_type(self, t):
        img = self.image_of_type(t)
        ns, nm = self.tname(t)
        full = (ns + "." + nm) if ns else nm
        mp = self.MOD.get(img)
        out = []
        base, cnt = (mp if mp else (None, 0))
        for mi in self.type_methods(t):
            rid = self.mtoken(mi) & 0xFFFFFF
            va = self.rq(base + (rid-1)*8) if (base and 1 <= rid <= cnt) else None
            out.append((self.mname(mi), rid, va))
        return full, img, out

    def find(self, needle):
        needle = needle.lower()
        for t in range(self.NTYPES):
            ns, nm = self.tname(t)
            full = (ns + "." + nm) if ns else nm
            if needle in full.lower():
                yield t, full


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    R = Resolver(sys.argv[1], sys.argv[2])
    cmd = sys.argv[3]
    if cmd == "find":
        for t, full in R.find(sys.argv[4]):
            print(t, full, " image=", R.image_of_type(t))
    elif cmd == "type":
        for t in map(int, sys.argv[4:]):
            full, img, ms = R.resolve_type(t)
            print("TYPE", t, full, "image=", img)
            for nm, rid, va in ms:
                print("   %-40s rid=%d RVA=%s" %
                      (nm, rid, hex(va - R.IB) if va else None))
    elif cmd == "verify-be":
        known = {"IsInstanceSuccessfully": 0x6699C0, "Update": 0x669390,
                 "Stop": 0x668E80, "Run": 0x667700}
        for t, full in R.find("BattlEye.BEClient"):
            if full != "BattlEye.BEClient":
                continue
            _, img, ms = R.resolve_type(t)
            print("BEClient image=", img)
            ok = True
            for nm, rid, va in ms:
                if nm in known:
                    got = va - R.IB if va else None
                    m = "OK" if got == known[nm] else "MISMATCH"
                    ok = ok and got == known[nm]
                    print("   %-24s rid=%d got=%s exp=%s %s" %
                          (nm, rid, hex(got) if got else None, hex(known[nm]), m))
            print("ALL BE RVAs REPRODUCED" if ok else "RESOLVER WRONG")


if __name__ == "__main__":
    main()
