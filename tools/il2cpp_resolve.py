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

## Field offsets (added -- Phase 0 of native settings)

Method RVAs live in per-image `methodPointers`; FIELD offsets do NOT live in
global-metadata at all. They live in `GameAssembly.dll` via the registration
struct `Il2CppMetadataRegistration.fieldOffsets` -- an `int32*[]` indexed by
`typeDefinitionIndex`, each entry pointing to that type's `int32[]` of per-field
byte offsets. The field NAMES + type indices come from metadata `fields`
(prop 11, `Il2CppFieldDefinition` = nameIndex@0, typeIndex@4, token@8, 12 bytes),
sliced by the type's `fieldStart@32`/`field_count@68` in `Il2CppTypeDefinition`.

We locate `Il2CppMetadataRegistration` by a self-checking signature scan of
`.data`/`.rdata`: it is the ONLY 8-aligned site where u32@+0x50 (fieldOffsetsCount)
== NTYPES and u32@+0x60 (typeDefinitionsSizesCount) == NTYPES with valid image
pointers at +0x58 and +0x68. The static struct layout (64-bit) is a run of
`{int32 count; void* ptr}` pairs: genericClasses(0x00), genericInsts(0x10),
genericMethodTable(0x20), types(0x30), methodSpecs(0x40), fieldOffsets(0x50),
typeDefinitionsSizes(0x60), metadataUsages(0x70).

Static-vs-instance + field TYPE come from the field's `Il2CppType` (in
`metadataRegistration.types`, index = FieldDefinition.typeIndex): a 16-byte
struct `{void* data; u32 bits; ...}` where `bits & 0xFFFF` = attrs
(FIELD_ATTRIBUTE_STATIC = 0x10), `(bits>>16)&0xFF` = the Il2CppTypeEnum. For a
CLASS/VALUETYPE type, `data` is the referenced typeDefinitionIndex, so field
type names resolve back to real class names (and the parent chain walks the same
way: `types[typedef.parentIndex@16].data` = the base type's typeDefinitionIndex).

BUILT-IN SELF-CHECK: `System.String` must show `_stringLength` @ +0x10 and
`_firstChar` @ +0x14 (the exact layout the live version-brand raw write relied
on). `verify-fields` asserts it, the same way `verify-be` asserts the BE RVAs.

## Signatures (added)

`Il2CppMethodDefinition` (36 bytes, v31) is, MEASURED on this build against both
`UnityEngine.AssetBundle::LoadAsset` overloads:

    nameIndex@0  declaringType@4  returnType@8  returnParameterToken@12
    parameterStart@16  genericContainerIndex@20  token@24
    flags@28(u16) iflags@30(u16) slot@32(u16) parameterCount@34(u16)

`returnType` and each parameter's `typeIndex` are indices into
`Il2CppMetadataRegistration.types` -- the SAME table field types already resolve
through -- so full parameter and return TYPE NAMES are reachable, not just the
count. Parameters are metadata property 10 (`Il2CppParameterDefinition` =
nameIndex@0, token@4, typeIndex@8; 12 bytes). Proof: rid 6 reads
`Object LoadAsset(string name)` and rid 7 `Object LoadAsset(string name, Type type)`,
which is the documented Unity API.

## Shared thunks: one RVA, many methods

The IL2CPP backend FOLDS identical compiled bodies. Two entirely unrelated
methods, in different images, can share one address:
`Diz.Resources.EasyAssets::get_System` and `BundlesManager::get_DownloadingUrl`
BOTH resolve to `0x692A50` (measured; 338 keys total land there). `0x628110` --
the address CLAUDE.md records as "ForceMeshUpdate, a stripped stub" -- is shared
by **6438** methods: it is not ForceMeshUpdate's, it is the build's universal
empty-body `ret`.

A shared RVA is a technically-correct answer that is useless as a PATCH target: a
detour there fires for every one of those call sites. `shared` / `--shared`
annotate it; see `il2cpp_nameindex.py shared` for the full distribution.

## Thunk shapes

Postfix-detouring a thunk is unsafe (there is no meaningful "after"), so the
obvious shapes are classified from the bytes:

  * `TAILJUMP`   -- a few setup bytes then `E9 rel32`, `CC` padding after.
    e.g. `BundlesManager::LoadBundleAsync@0x191B9E0` = `45 33 C9 E9 C8 13 00 00 CC`
  * `VDISPATCH`  -- load through `rcx`, then `jmp`/`call` through a vtable slot.
    e.g. `AssetBundleRequest::get_asset@0xB196C0` =
    `48 8B 11 48 8B 82 78 01 00 00 48 8B 92 80 01 00 00 48 FF E0`. NOTE it takes
    21 bytes to see the `jmp rax`, so classification reads 32, not 16.
  * `STUB`       -- an immediate `C3`, `C2 imm16`, or `xor eax,eax; ret`: no
    body. MEASURED CORRECTION: `0x628110` is `C2 00 00` (`ret 0`), not a bare
    `C3` as CLAUDE.md says.
  * `JMPTABLE`   -- an immediate `FF 25` (RIP-relative indirect jump).
  * `TRIVIAL`    -- `mov rax,[rcx+disp8]; ret`. A real body, but so small that
    the linker folds every getter at that offset onto it; these are the top
    shared-RVA offenders. `0x692A50` is `48 8B 41 28 C3` = `[rcx+0x28]`.

Anything not matching prints nothing -- absence of an annotation is NOT proof a
function is a real body.

Usage:
  il2cpp_resolve.py <GameAssembly.dll> <global-metadata.dec.dat> find <substr>
  il2cpp_resolve.py <GameAssembly.dll> <global-metadata.dec.dat> type <idx>...
        # per method: rid, RVA, arity, full signature, section, thunk shape.
        # add --shared to also annotate RVAs shared with other methods (this
        # costs one full metadata walk, ~1.2s)
  il2cpp_resolve.py <GameAssembly.dll> <global-metadata.dec.dat> bytes <RVA> [N]
        # containing PE section + N bytes (default 16) as hex, + thunk shape.
        # Generated code lives in the `il2cpp` section, NOT `.text`.
  il2cpp_resolve.py <GameAssembly.dll> <global-metadata.dec.dat> verify-be
  il2cpp_resolve.py <GameAssembly.dll> <global-metadata.dec.dat> fields <TypeName>
        # every field (incl. inherited) with offset, FieldAttributes (raw +
        # decoded), and the constant value for a literal. A field with NO
        # STORAGE (a C# `const`) prints `--` for its offset, not `0x0`.
        # <TypeName> is an exact full name or a unique substring
  il2cpp_resolve.py <GameAssembly.dll> <global-metadata.dec.dat> enum <TypeName>
        # every member of an enum with its decoded ordinal
  il2cpp_resolve.py <GameAssembly.dll> <global-metadata.dec.dat> verify-fields
        # System.String _stringLength@0x10 / _firstChar@0x14 self-check
  il2cpp_resolve.py <GameAssembly.dll> <global-metadata.dec.dat> verify-consts
        # the constant decoder against 19 independently-known values
        # (KeyCode.None/Space/A/Alpha0 + one per primitive width)
  il2cpp_resolve.py <GameAssembly.dll> <global-metadata.dec.dat> settings-table
        # the SettingsScreen/SettingControl offset table Phase 1 will probe
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

    # ---- code bytes / sections / thunk shapes -----------------------------

    def section_of_rva(self, rva):
        """(name, file_offset, bytes_available) for an RVA, or (None, None, 0)."""
        for name, vs, vz, raw, rz in self.SEC:
            if vs <= rva < vs + vz:
                off = rva - vs
                if off >= rz:
                    return name, None, 0        # in a section, but not on disk
                return name, raw + off, rz - off
        return None, None, 0

    def code_bytes(self, rva, n=16):
        _, fo, avail = self.section_of_rva(rva)
        if fo is None:
            return None
        return self.b[fo:fo + min(n, avail)]

    @staticmethod
    def classify_thunk(bs):
        """(KIND, explanation) for an obvious non-body shape, else None.

        Conservative on purpose: NOT matching is not evidence of a real body.
        """
        if not bs or len(bs) < 4:
            return None
        if bs[0] == 0xC3:
            return ("STUB", "immediate ret -- empty body, nothing to detour")
        if bs[0] == 0xC2:
            return ("STUB", "ret 0x%X -- empty body, nothing to detour"
                    % struct.unpack_from("<H", bs, 1)[0])
        if bs[:3] == b"\x33\xC0\xC3" or bs[:4] == b"\x48\x33\xC0\xC3":
            return ("STUB", "xor eax,eax; ret -- returns 0, no body")
        # mov rax,[rcx+disp8]; ret  -- the folded field getter. A REAL body, but
        # every getter at the same offset compiles to the identical 5 bytes and
        # the linker folds them, so these are the top shared-RVA offenders.
        if bs[:3] == b"\x48\x8B\x41" and len(bs) > 4 and bs[4] == 0xC3:
            return ("TRIVIAL", "mov rax,[rcx+0x%02X]; ret -- one-instruction "
                    "field getter; bodies this small are FOLDED, expect the "
                    "RVA to be shared" % bs[3])
        if bs[:2] == b"\xFF\x25":
            return ("JMPTABLE", "jmp [rip+disp32] -- indirect jump, not a body")
        # tail jump: up to 8 bytes of register setup then E9 rel32
        for i in range(0, min(9, len(bs) - 4)):
            if bs[i] == 0xE9:
                tail = bs[i + 5:i + 7]
                pad = tail[:1] in (b"\xCC", b"") or tail[:1] == b"\x90"
                if i == 0 or pad:
                    return ("TAILJUMP",
                            "jmp rel32 at +%d -- tail-call thunk; a postfix "
                            "detour here has no return site" % i)
                break
        # virtual dispatch: load `this`/vtable then jmp/call through it
        if bs[:3] in (b"\x48\x8B\x11", b"\x48\x8B\x01", b"\x48\x8B\x09"):
            for i in range(3, min(len(bs) - 1, 20)):
                if bs[i] == 0xFF and (bs[i + 1] & 0x38) in (0x20, 0x10):
                    return ("VDISPATCH",
                            "loads through rcx then jmp/call through a vtable "
                            "slot -- dispatch thunk, not the implementation")
        return None

    def annotate_rva(self, rva, nbytes=32):
        """' [il2cpp] TAILJUMP: ...' style suffix for a resolved RVA."""
        sec, fo, _ = self.section_of_rva(rva)
        bits = ["sec=%s" % (sec or "UNMAPPED")]
        if fo is not None:
            th = self.classify_thunk(self.code_bytes(rva, nbytes))
            if th:
                bits.append("%s: %s" % th)
        return "  [" + "; ".join(bits) + "]"

    # ---- signatures --------------------------------------------------------

    def _ensure_params(self):
        if not hasattr(self, "PAR_OFF"):
            self.PAR_OFF = struct.unpack_from("<i", self.m, 8 + 10*8)[0]
            self.PARS = 12
            self._ensure_fields()      # needs TYPES_PTR for type names

    def method_sig(self, mi):
        """(return_type, [(param_name, param_type)], arity) for method index mi.

        Types come from metadataRegistration.types, the same table field types
        resolve through. Anything unresolvable prints as '?', never a guess.
        """
        self._ensure_params()
        base = self.M_OFF + mi*self.MS
        rt = struct.unpack_from("<i", self.m, base + 8)[0]
        ps = struct.unpack_from("<i", self.m, base + 16)[0]
        pc = struct.unpack_from("<H", self.m, base + 34)[0]
        ret = self.field_typename(rt) if rt >= 0 else "?"
        ps_list = []
        for i in range(pc):
            ni, _tok, ti = struct.unpack_from("<iIi", self.m,
                                              self.PAR_OFF + (ps + i)*self.PARS)
            ps_list.append((self.s(ni), self.field_typename(ti) if ti >= 0 else "?"))
        return ret, ps_list, pc

    def sig_string(self, mi, name):
        ret, ps, pc = self.method_sig(mi)
        return "%s %s(%s)" % (ret, name,
                              ", ".join("%s %s" % (t, n) for n, t in ps)), pc

    # ---- shared-RVA histogram ---------------------------------------------

    def shared_rva_counts(self):
        """{rva: number_of_distinct_methods_resolving_there}, all images.

        Built from the same per-image methodPointers walk the name index uses,
        so the two cannot disagree. ~1.2s over 208k methods.
        """
        if hasattr(self, "_SHARED"):
            return self._SHARED
        counts = {}
        for t in range(self.NTYPES):
            mp = self.MOD.get(self.image_of_type(t))
            if not mp or not mp[0]:
                continue
            base, cnt = mp
            for mi in self.type_methods(t):
                rid = self.mtoken(mi) & 0xFFFFFF
                if not (1 <= rid <= cnt):
                    continue
                va = self.rq(base + (rid - 1)*8)
                if va:
                    r = va - self.IB
                    counts[r] = counts.get(r, 0) + 1
        self._SHARED = counts
        return counts

    def find(self, needle):
        needle = needle.lower()
        for t in range(self.NTYPES):
            ns, nm = self.tname(t)
            full = (ns + "." + nm) if ns else nm
            if needle in full.lower():
                yield t, full

    # ---- field-offset resolution (Il2CppMetadataRegistration.fieldOffsets) ----

    # Il2CppTypeEnum -> short name; primitives are exact, the rest a category.
    TENUM = {1: "void", 2: "bool", 3: "char", 4: "sbyte", 5: "byte", 6: "short",
             7: "ushort", 8: "int", 9: "uint", 0xa: "long", 0xb: "ulong",
             0xc: "float", 0xd: "double", 0xe: "string", 0xf: "ptr",
             0x11: "valuetype", 0x12: "class", 0x13: "var", 0x14: "array",
             0x15: "genericinst", 0x16: "typedref", 0x18: "IntPtr",
             0x19: "UIntPtr", 0x1b: "fnptr", 0x1c: "object", 0x1d: "szarray",
             0x1e: "mvar"}

    def _fields_meta(self):
        # metadata `fields` = property 11 (Il2CppFieldDefinition, 12 bytes)
        self.FLD_OFF = struct.unpack_from("<i", self.m, 8 + 11*8)[0]

    def _find_metadata_registration(self):
        """Signature scan: the unique .data/.rdata site with fieldOffsetsCount
        (+0x50) and typeDefinitionsSizesCount (+0x60) both == NTYPES and valid
        image pointers following each. Returns the struct VA."""
        N = self.NTYPES
        cand = []
        for name, vs, vz, raw, rz in self.SEC:
            if name not in (".data", ".rdata", ".data1"):
                continue
            for fo in range(raw, raw + (rz & ~7) - 0x28, 8):
                if struct.unpack_from("<I", self.b, fo)[0] != N:
                    continue
                p1 = struct.unpack_from("<Q", self.b, fo + 8)[0]
                if self.v2f(p1) is None:
                    continue
                if struct.unpack_from("<I", self.b, fo + 0x10)[0] != N:
                    continue
                p2 = struct.unpack_from("<Q", self.b, fo + 0x18)[0]
                if self.v2f(p2) is None:
                    continue
                cand.append(self.f2v(fo) - 0x50)
        if len(cand) != 1:
            sys.exit("metadata-registration scan found %d candidates (want 1); "
                     "field-offset layout may differ on this build" % len(cand))
        self.MREG = cand[0]
        self.TYPES_PTR = self.rq(self.MREG + 0x38)   # types[] (Il2CppType*[])
        self.FOFF_PTR = self.rq(self.MREG + 0x58)    # fieldOffsets (int32*[])

    def _ensure_fields(self):
        if not hasattr(self, "FOFF_PTR"):
            self._fields_meta()
            self._find_metadata_registration()

    def _typename_va(self, tva, depth=0):
        """Readable name of the Il2CppType at VA `tva`."""
        if tva is None or depth > 4:
            return "?"
        bits = struct.unpack_from("<I", self.b, self.v2f(tva) + 8)[0]
        te = (bits >> 16) & 0xFF
        data = self.rq(tva)
        if te in (0x11, 0x12) and data is not None and data < self.NTYPES:
            return self.tname(data)[1]
        if te == 0x1d and data is not None:      # szarray: data -> element type
            return self._typename_va(data, depth+1) + "[]"
        if te == 0x0f and data is not None:      # ptr
            return self._typename_va(data, depth+1) + "*"
        if te == 0x15 and data is not None:      # genericinst -> Il2CppGenericClass
            return self._genericinst_name(data, depth)
        return self.TENUM.get(te, hex(te))

    def _genericinst_name(self, gc_va, depth=0):
        # Il2CppGenericClass { Il2CppType* type; GenericContext{ class_inst*,
        #                       method_inst* }; Il2CppClass* cached_class }
        gd = self.rq(gc_va)                      # Il2CppType* of the generic def
        class_inst = self.rq(gc_va + 8)          # Il2CppGenericInst* (class args)
        gdata = self.rq(gd) if gd is not None else None
        base = self.tname(gdata)[1] if (gdata is not None and gdata < self.NTYPES) \
            else "?"
        base = base.split("`")[0]
        args = []
        if class_inst:
            argc = struct.unpack_from("<Q", self.b, self.v2f(class_inst))[0]
            argv = self.rq(class_inst + 8)
            for i in range(min(argc, 6)):
                args.append(self._typename_va(self.rq(argv + i*8), depth+1))
        return "%s<%s>" % (base, ",".join(args))

    def field_typename(self, tidx):
        return self._typename_va(self.rq(self.TYPES_PTR + tidx*8))

    def field_is_static(self, tidx):
        tva = self.rq(self.TYPES_PTR + tidx*8)
        attrs = struct.unpack_from("<I", self.b, self.v2f(tva) + 8)[0] & 0xFFFF
        return bool(attrs & 0x10)

    def field_attrs(self, tidx):
        """Raw FieldAttributes (u16) for the field whose Il2CppType index is
        tidx. Same word `field_is_static` masks 0x10 out of."""
        tva = self.rq(self.TYPES_PTR + tidx*8)
        return struct.unpack_from("<I", self.b, self.v2f(tva) + 8)[0] & 0xFFFF

    FATTR = [(0x0010, "STATIC"), (0x0020, "INITONLY"), (0x0040, "LITERAL"),
             (0x0080, "NOTSERIALIZED"), (0x0100, "HASFIELDRVA"),
             (0x0200, "SPECIALNAME"), (0x0400, "RTSPECIALNAME"),
             (0x1000, "HASFIELDMARSHAL"), (0x2000, "PINVOKEIMPL"),
             (0x8000, "HASDEFAULT")]
    FACCESS = ["PrivateScope", "private", "FamANDAssem", "internal",
               "protected", "FamORAssem", "public", "?"]

    @classmethod
    def attr_names(cls, attrs):
        out = [cls.FACCESS[attrs & 7]]
        out += [n for bit, n in cls.FATTR if attrs & bit]
        return out

    # ---- default values (const / literal fields) -------------------------
    #
    # Metadata property 7 = `fieldDefaultValues`, an array of
    # Il2CppFieldDefaultValue = { int32 fieldIndex; int32 typeIndex;
    # int32 dataIndex; } (12 bytes). `dataIndex` is a BYTE OFFSET into
    # property 8 (`fieldAndParameterDefaultValueData`) -- it is NOT the field
    # index, and the blob is NOT a flat array of int32.
    #
    # MEASURED encoding on this build (see the self-check in `enum_self_check`,
    # which reproduces 19 independently-known constants across every primitive
    # class): the blob is RAW little-endian for every width EXCEPT I4/U4, which
    # are stored as il2cpp's ECMA-335-style COMPRESSED integers, big-endian,
    # with zigzag applied for the signed form. That is why a naive
    # `int32 at blob[dataIndex]` reads KeyCode.None as -25161728: it is reading
    # one zigzag-compressed byte (0x00 = 0) plus the next three neighbouring
    # constants' bytes as if they were the upper 24 bits of an int32.
    def _read_compressed_u32(self, p):
        """il2cpp ReadCompressedUInt32. Returns (value, nbytes); (None, 0) if
        the lead byte is not a legal encoding."""
        m, b = self.m, self.m[p]
        if b == 0xFF:
            return 0xFFFFFFFF, 1
        if b == 0xFE:
            return 0xFFFFFFFE, 1
        if b == 0xF0:
            return int.from_bytes(m[p+1:p+5], "little"), 5
        if b < 0x80:
            return b, 1
        if (b & 0xC0) == 0x80:
            return ((b & 0x3F) << 8) | m[p+1], 2
        if (b & 0xE0) == 0xC0:
            return (((b & 0x1F) << 24) | (m[p+1] << 16) |
                    (m[p+2] << 8) | m[p+3]), 4
        return None, 0

    def _read_compressed_i32(self, p):
        u, n = self._read_compressed_u32(p)
        if u is None:
            return None
        if u == 0xFFFFFFFF:
            return -2**31
        return -((u >> 1) + 1) if (u & 1) else (u >> 1)

    def _ensure_defaults(self):
        if hasattr(self, "DEFV"):
            return
        self._ensure_fields()
        fo, fs = struct.unpack_from("<ii", self.m, 8 + 7*8)
        self.DEFB = struct.unpack_from("<ii", self.m, 8 + 8*8)[0]
        self.DEFV = {}
        for i in range(fs // 12):
            fi, ti, di = struct.unpack_from("<iii", self.m, fo + i*12)
            self.DEFV[fi] = (ti, di)

    def type_enum_of(self, tidx):
        tva = self.rq(self.TYPES_PTR + tidx*8)
        return (struct.unpack_from("<I", self.b, self.v2f(tva) + 8)[0] >> 16) & 0xFF

    def field_default(self, field_index):
        """Decoded constant for metadata field `field_index`, or None if the
        field has no default-value entry. Returns (value, typeenum); value is
        the string '<undecoded:0xNN>' for a shape we have not MEASURED, never a
        plausible-looking number."""
        self._ensure_defaults()
        e = self.DEFV.get(field_index)
        if e is None:
            return None
        ti, di = e
        te = self.type_enum_of(ti)
        p = self.DEFB + di
        m = self.m
        if te == 0x02:
            return (bool(m[p]), te)
        if te == 0x03:
            return (struct.unpack_from("<H", m, p)[0], te)
        if te == 0x04:
            return (struct.unpack_from("<b", m, p)[0], te)
        if te == 0x05:
            return (m[p], te)
        if te == 0x06:
            return (struct.unpack_from("<h", m, p)[0], te)
        if te == 0x07:
            return (struct.unpack_from("<H", m, p)[0], te)
        if te == 0x08:
            return (self._read_compressed_i32(p), te)
        if te == 0x09:
            return (self._read_compressed_u32(p)[0], te)
        if te == 0x0A:
            return (struct.unpack_from("<q", m, p)[0], te)
        if te == 0x0B:
            return (struct.unpack_from("<Q", m, p)[0], te)
        if te == 0x0C:
            return (struct.unpack_from("<f", m, p)[0], te)
        if te == 0x0D:
            return (struct.unpack_from("<d", m, p)[0], te)
        return ("<undecoded:%#x>" % te, te)

    def is_enum(self, t):
        """True iff t's base class is System.Enum."""
        p = self.parent_type(t)
        return p is not None and self.tname(p) == ("System", "Enum")

    def enum_members(self, t):
        """[(name, value_or_None)] for the LITERAL fields of enum type t, in
        metadata declaration order. `value__` (the instance storage slot) is
        excluded. A member with no default-value entry yields None -- that is
        an honest 'metadata does not say', not a zero."""
        out = []
        for r in self.declared_fields_ex(t):
            if not (r["attrs"] & 0x40):     # FIELD_ATTRIBUTE_LITERAL
                continue
            dv = self.field_default(r["fidx"])
            out.append((r["name"], None if dv is None else dv[0]))
        return out

    def declared_fields_ex(self, t):
        """Rich per-field rows for fields DECLARED on t. Superset of
        `declared_fields`, which keeps its 4-tuple shape for existing callers.

        keys: fidx name off attrs static literal has_storage typename default
        `has_storage` is False for a LITERAL (C# `const`): the compiler inlines
        it at every use site and the fieldOffsets entry is meaningless -- it
        reads 0x0, which is indistinguishable from a real static at offset 0
        unless the attributes are shown."""
        self._ensure_fields()
        bb = self.TD_OFF + t*self.TDS
        fs = struct.unpack_from("<i", self.m, bb+32)[0]
        fc = struct.unpack_from("<H", self.m, bb+68)[0]
        entry = self.rq(self.FOFF_PTR + t*8)
        base = self.v2f(entry) if entry else None
        out = []
        for i in range(fc):
            ni, ti = struct.unpack_from("<ii", self.m, self.FLD_OFF + (fs+i)*12)
            off = struct.unpack_from("<i", self.b, base + i*4)[0] if base else None
            attrs = self.field_attrs(ti)
            lit = bool(attrs & 0x40)
            dv = self.field_default(fs + i)
            out.append({"fidx": fs + i, "name": self.s(ni), "off": off,
                        "attrs": attrs, "static": bool(attrs & 0x10),
                        "literal": lit, "has_storage": not lit,
                        "typename": self.field_typename(ti),
                        "default": None if dv is None else dv[0]})
        return out

    def all_fields_ex(self, t):
        """declared_fields_ex over the full parent chain, base classes first;
        each row gains 'declared_by'."""
        chain, cur, seen = [], t, set()
        while cur is not None and cur not in seen:
            seen.add(cur)
            chain.append(cur)
            cur = self.parent_type(cur)
        rows = []
        for ct in reversed(chain):
            ns, nm = self.tname(ct)
            full = (ns + "." + nm) if ns else nm
            for r in self.declared_fields_ex(ct):
                r["declared_by"] = full
                rows.append(r)
        return rows

    def declared_fields(self, t):
        """[(name, offset, is_static, typename)] for fields DECLARED on type t."""
        self._ensure_fields()
        bb = self.TD_OFF + t*self.TDS
        fs = struct.unpack_from("<i", self.m, bb+32)[0]
        fc = struct.unpack_from("<H", self.m, bb+68)[0]
        entry = self.rq(self.FOFF_PTR + t*8)
        base = self.v2f(entry) if entry else None
        out = []
        for i in range(fc):
            ni, ti = struct.unpack_from("<ii", self.m, self.FLD_OFF + (fs+i)*12)
            off = struct.unpack_from("<i", self.b, base + i*4)[0] if base else None
            out.append((self.s(ni), off, self.field_is_static(ti),
                        self.field_typename(ti)))
        return out

    def parent_type(self, t):
        """typeDefinitionIndex of t's base class, or None."""
        self._ensure_fields()
        par = struct.unpack_from("<i", self.m, self.TD_OFF + t*self.TDS + 16)[0]
        if par < 0:
            return None
        tva = self.rq(self.TYPES_PTR + par*8)
        if tva is None:
            return None
        bits = struct.unpack_from("<I", self.b, self.v2f(tva) + 8)[0]
        if ((bits >> 16) & 0xFF) not in (0x11, 0x12):
            return None
        data = self.rq(tva)
        return data if (data is not None and 0 <= data < self.NTYPES) else None

    def all_fields(self, t):
        """Fields including inherited: [(declaring_full, name, off, static, ty)],
        base classes first."""
        chain = []
        cur = t
        seen = set()
        while cur is not None and cur not in seen:
            seen.add(cur)
            chain.append(cur)
            cur = self.parent_type(cur)
        rows = []
        for ct in reversed(chain):
            ns, nm = self.tname(ct)
            full = (ns + "." + nm) if ns else nm
            for name, off, st, ty in self.declared_fields(ct):
                rows.append((full, name, off, st, ty))
        return rows

    def find_one(self, name):
        """Resolve a type name EXACTLY -- full name, or unique short name.

        It used to fall back to "the only substring match", which is how
        `fields EFT.CharacterController` silently answered for
        `EFT.CharacterControllerFootprint` (fact #179). A near-miss type
        yields offsets that are structurally plausible, pass a nil check,
        and kill the client on first use. There is no safe way to guess
        which type the caller meant, so this never guesses: it refuses and
        prints the substring matches as CANDIDATES.
        """
        hits = list(self.find(name))
        full_exact = [t for t, f in hits if f == name]
        if len(full_exact) == 1:
            return full_exact[0]
        if len(full_exact) > 1:
            sys.exit("AMBIGUOUS: %d types have the exact full name %r "
                     "(indices %s) -- refusing to pick one."
                     % (len(full_exact), name,
                        ", ".join(str(t) for t in full_exact)))
        short_exact = [(t, f) for t, f in hits if f.split(".")[-1] == name]
        if len(short_exact) == 1:
            return short_exact[0][0]
        if len(short_exact) > 1:
            sys.exit("AMBIGUOUS short name %r -- %d types match exactly; "
                     "pass the full name:%s"
                     % (name, len(short_exact),
                        "".join("\n  " + f for _, f in short_exact[:20])))
        if not hits:
            sys.exit("NO SUCH TYPE: %r. No type name even CONTAINS that "
                     "string (searched all %d types exhaustively)."
                     % (name, self.NTYPES))
        sys.exit("NO SUCH TYPE: %r -- no type has that exact name.\n"
                 "Refusing to substitute a near-miss: an offset read from the "
                 "wrong type passes a nil check and kills the client.\n"
                 "%d name(s) CONTAIN it; if you meant one, name it exactly:"
                 "%s%s"
                 % (name, len(hits),
                    "".join("\n  " + f for _, f in hits[:20]),
                    ("\n  ... and %d more" % (len(hits) - 20))
                    if len(hits) > 20 else ""))


# Ground truth for the constant decoder, known independently of this build:
# these are C# language / Unity API constants. Every one of them must come back
# exactly, or the decoder is wrong and no constant it prints may be trusted.
# The four KeyCode entries are the oracle the enum verb was written against;
# the rest pin down one primitive width each, so a decoder that is right only
# for int32 cannot pass.
ENUM_ORACLE = [
    ("UnityEngine.KeyCode", "None", 0),
    ("UnityEngine.KeyCode", "Space", 32),
    ("UnityEngine.KeyCode", "A", 97),
    ("UnityEngine.KeyCode", "Alpha0", 48),
    ("System.Int32", "MaxValue", 2147483647),
    ("System.Int32", "MinValue", -2147483648),
    ("System.UInt32", "MaxValue", 4294967295),
    ("System.Int16", "MaxValue", 32767),
    ("System.Int16", "MinValue", -32768),
    ("System.UInt16", "MaxValue", 65535),
    ("System.Byte", "MaxValue", 255),
    ("System.Char", "MaxValue", 65535),
    ("System.Char", "MinValue", 0),
    ("System.Int64", "MaxValue", 9223372036854775807),
    ("System.Int64", "MinValue", -9223372036854775808),
    ("System.UInt64", "MaxValue", 18446744073709551615),
    ("System.Single", "MaxValue", 3.4028234663852886e38),
    ("System.Single", "Epsilon", 1.401298464324817e-45),
    ("System.Double", "MaxValue", 1.7976931348623157e308),
]


def print_field_rows(rows):
    """Shared field table. The Offset column prints `--` for a field with NO
    STORAGE (a C# `const` = LITERAL|STATIC|HASDEFAULT). It used to print 0x0
    there, which is a real offset for a real static and so made a const
    indistinguishable from a `static readonly` -- a distinction that decides
    whether a field can be written at all."""
    print("  %-8s %-34s %-30s %-40s %-22s %s" %
          ("Offset", "Field", "FieldType", "Attrs", "Const", "DeclaredBy"))
    for r in rows:
        if not r["has_storage"]:
            off = "--"
        elif r["off"] is None:
            off = "?"
        else:
            off = hex(r["off"])
        dv = r["default"]
        print("  %-8s %-34s %-30s %-40s %-22s %s" %
              (off, r["name"], r["typename"],
               "%#06x %s" % (r["attrs"], "|".join(Resolver.attr_names(r["attrs"]))),
               "" if dv is None else repr(dv), r["declared_by"]))


def const_check(R):
    """Returns (ok, rows). A member the metadata does not contain at all is a
    FAILURE here, not a pass -- these 19 are all reachable on this build, and
    'I could not look' is not a pass. (Note that IL2CPP managed stripping DOES
    remove unreferenced consts in general: System.SByte.MaxValue and
    System.Math.PI are genuinely absent from this build's metadata, which is
    why they are not in the oracle.)"""
    rows, ok = [], True
    for tn, fn, want in ENUM_ORACLE:
        try:
            t = R.find_one(tn)
            hit = [r for r in R.declared_fields_ex(t) if r["name"] == fn]
            got = hit[0]["default"] if hit else "<field absent from metadata>"
        except SystemExit as e:
            got = "<unresolved: %s>" % e
        good = (got == want) and (type(got) is type(want) or
                                  isinstance(got, (int, float)))
        ok = ok and good
        rows.append((tn + "." + fn, got, want, good))
    return ok, rows


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    R = Resolver(sys.argv[1], sys.argv[2])
    cmd = sys.argv[3]
    if cmd == "find":
        needle = sys.argv[4]
        n = 0
        for t, full in R.find(needle):
            print(t, full, " image=", R.image_of_type(t))
            n += 1
        # An empty stdout with exit 0 is indistinguishable from "not found",
        # and two agents read it as "the tool broke". Always say which.
        if n == 0:
            if "::" in needle:
                ty, _, meth = needle.partition("::")
                print("NO TYPE NAME CONTAINS %r (searched all %d types "
                      "EXHAUSTIVELY)." % (needle, R.NTYPES))
                print("`find` matches TYPE names ONLY -- %r looks like a "
                      "Type::Method spec." % needle)
                print("Try instead:")
                print("  ... methods %s          # search by METHOD name"
                      % (meth or "<name>"))
                print("  ... type %s             # every method on that type"
                      % (ty or "<Type>"))
                sys.exit(1)
            print("NO TYPE NAME CONTAINS %r (searched all %d types "
                  "EXHAUSTIVELY). This is a genuine zero-hit answer, not an "
                  "error." % (needle, R.NTYPES))
            sys.exit(1)
        print("-- %d type name(s) contain %r (searched all %d EXHAUSTIVELY)"
              % (n, needle, R.NTYPES))
    elif cmd == "methods":
        # `find` searches TYPE names only; this searches METHOD names, which is
        # what you want when you know a call site's name (LocalRaidEnded) but
        # not its declaring type, and it prints the full signature + RVA +
        # sharedness so the answer is directly actionable.
        needle = sys.argv[4].lower()
        want_shared = "--shared" in sys.argv[5:]
        shared = R.shared_rva_counts() if want_shared else {}
        lim = 200
        for a in sys.argv[5:]:
            if a.startswith("--limit="):
                lim = int(a.split("=", 1)[1])
        hits = 0
        for t in range(R.NTYPES):
            ms = R.type_methods(t)
            names = [R.mname(mi) for mi in ms]
            if not any(needle in n.lower() for n in names):
                continue
            full, img, resolved = R.resolve_type(t)
            for (nm, rid, va), mi in zip(resolved, ms):
                if needle not in nm.lower():
                    continue
                if hits >= lim:
                    print("... limit %d reached; re-run with --limit=N. This is "
                          "NOT 'no more matches'." % lim)
                    return
                hits += 1
                try:
                    sig, pc = R.sig_string(mi, nm)
                except Exception:
                    sig, pc = nm + "(?)", -1
                rva = (va - R.IB) if va else None
                print("%s::%s  arity=%s RVA=%s  image=%s"
                      % (full, sig, pc if pc >= 0 else "?",
                         hex(rva) if rva is not None else "None", img))
                if rva is None:
                    continue
                note = R.annotate_rva(rva)
                n = shared.get(rva, 1)
                if n > 1:
                    note += ("  [SHARED: %d methods resolve here -- hooking "
                             "this fires for all of them]" % n)
                if note.strip():
                    print("      " + note.strip())
        if hits == 0:
            print("no method name contains %r (searched all %d types "
                  "EXHAUSTIVELY)" % (sys.argv[4], R.NTYPES))
    elif cmd == "type":
        args = [a for a in sys.argv[4:] if not a.startswith("--")]
        want_shared = "--shared" in sys.argv[4:]
        shared = R.shared_rva_counts() if want_shared else {}
        # `type` used to take a numeric index ONLY -- an index that only
        # `find` produces -- while fldoff.py's `fields` took a name. The two
        # CLIs disagreeing is a papercut that pushed agents into hand-rolling.
        # A NAME goes through find_one, so it gets the same exact-match
        # refusal (never a near-miss) as `fields`.
        idxs = []
        for a in args:
            try:
                idxs.append(int(a, 0))
            except ValueError:
                idxs.append(R.find_one(a))
        for t in idxs:
            full, img, ms = R.resolve_type(t)
            print("TYPE", t, full, "image=", img)
            for (nm, rid, va), mi in zip(ms, R.type_methods(t)):
                try:
                    sig, pc = R.sig_string(mi, nm)
                except Exception:
                    sig, pc = "unknown", -1
                rva = (va - R.IB) if va else None
                print("   %-52s rid=%-6d arity=%-3s RVA=%s" %
                      (sig, rid, pc if pc >= 0 else "?",
                       hex(rva) if rva is not None else None))
                if rva is None:
                    continue
                note = R.annotate_rva(rva)
                n = shared.get(rva, 1)
                if n > 1:
                    note += ("  [SHARED: %d methods resolve here -- hooking "
                             "this fires for all of them]" % n)
                    # NOTE: this counts METHOD DEFINITIONS. il2cpp_nameindex.py
                    # counts index KEYS, which is slightly lower because it has
                    # already dropped the name-ambiguous ones. Neither is wrong;
                    # they answer marginally different questions.
                print("      " + note.strip())
    elif cmd == "bytes":
        rva = int(sys.argv[4], 0)
        if rva > R.IB:
            rva -= R.IB          # accept a VA too
        n = int(sys.argv[5], 0) if len(sys.argv) > 5 else 16
        cls_n = max(n, 32)     # classification needs the whole thunk
        sec, fo, avail = R.section_of_rva(rva)
        print("RVA      0x%X   (VA 0x%X)" % (rva, R.IB + rva))
        print("section  %s%s" % (sec or "NONE -- rva is not inside any section",
                                 "" if sec != "il2cpp" else "   (generated code)"))
        if sec and sec != "il2cpp":
            print("         NOTE: generated IL2CPP method bodies live in the "
                  "`il2cpp` section, not %s." % sec)
        if fo is None:
            print("bytes    unavailable (section has no raw data at this offset)")
            sys.exit(1)
        bs = R.code_bytes(rva, n)
        print("bytes    " + " ".join("%02X" % c for c in bs))
        th = R.classify_thunk(R.code_bytes(rva, cls_n))
        print("shape    %s -- %s" % th if th else
              "shape    no known thunk shape matched (this is NOT proof of a "
              "real body)")
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
    elif cmd == "fields":
        t = R.find_one(sys.argv[4])
        R._ensure_fields()
        ns, nm = R.tname(t)
        full = (ns + "." + nm) if ns else nm
        print("FIELDS", t, full, " image=", R.image_of_type(t))
        print("  MetadataRegistration @ %s  fieldOffsets @ %s" %
              (hex(R.MREG) if hasattr(R, "MREG") else "?",
               hex(R.FOFF_PTR) if hasattr(R, "FOFF_PTR") else "?"))
        print_field_rows(R.all_fields_ex(t))
    elif cmd == "verify-fields":
        t = R.find_one("System.String")
        want = {"_stringLength": 0x10, "_firstChar": 0x14}
        got = {name: off for _, name, off, st, _ in R.all_fields(t)
               if name in want and not st}
        ok = all(got.get(k) == v for k, v in want.items())
        for k, v in want.items():
            g = got.get(k)
            print("   %-16s got=%s exp=%s %s" %
                  (k, hex(g) if g is not None else None, hex(v),
                   "OK" if g == v else "MISMATCH"))
        print("STRING LAYOUT SELF-CHECK PASSED" if ok else "RESOLVER WRONG")
        if not ok:
            sys.exit(1)
    elif cmd == "enum":
        ok, rows = const_check(R)
        if not ok:
            print("CONSTANT SELF-CHECK FAILED -- refusing to print any enum "
                  "value from this build.")
            for lbl, got, want, good in rows:
                if not good:
                    print("   %-32s got=%r exp=%r" % (lbl, got, want))
            sys.exit(1)
        t = R.find_one(sys.argv[4])
        ns, nm = R.tname(t)
        full = (ns + "." + nm) if ns else nm
        if not R.is_enum(t):
            sys.exit("%s is not an enum (base class is not System.Enum)" % full)
        print("ENUM", t, full, " image=", R.image_of_type(t))
        for name, v in R.enum_members(t):
            print("  %-30s = %s" %
                  (name, v if v is not None
                   else "<no default-value entry in metadata>"))
    elif cmd == "verify-consts":
        ok, rows = const_check(R)
        for lbl, got, want, good in rows:
            print("   %-34s got=%-24r exp=%-24r %s" %
                  (lbl, got, want, "OK" if good else "MISMATCH"))
        print("CONSTANT DECODER SELF-CHECK PASSED" if ok else "RESOLVER WRONG")
        if not ok:
            sys.exit(1)
    elif cmd == "settings-table":
        # the offsets Phase 1 of native-settings will probe. Names are matched
        # against EFT.UI.Settings.* full names to avoid ambiguity.
        targets = [
            "EFT.UI.Settings.SettingsScreen",
            "EFT.UI.Settings.SettingsTab",
            "EFT.UI.Settings.SettingControl",
            "EFT.UI.Settings.SettingFloatSlider",
            "EFT.UI.Settings.SettingToggle",
            "EFT.UI.Settings.SettingDropDown",
            "EFT.UI.Settings.SettingSelectSlider",
        ]
        print("%-22s %-34s %-8s %-6s %-38s %s" %
              ("Type", "Field", "Offset", "Kind", "FieldType", "DeclaredBy"))
        for name in targets:
            try:
                t = R.find_one(name)
            except SystemExit:
                print("%-22s <unresolved>" % name.split(".")[-1])
                continue
            short = name.split(".")[-1]
            # own declared fields only for the table (inherited shown under base)
            for fname, off, st, ty in R.declared_fields(t):
                print("%-22s %-34s %-8s %-6s %-38s %s" %
                      (short, fname, hex(off) if off is not None else "?",
                       "STATIC" if st else "inst", ty, short))

    else:
        # This used to fall off the end of the if-chain and exit 0 having
        # printed nothing, which reads as "searched, found nothing". Two
        # separate agents lost round trips to it. Say what happened.
        sys.exit(
            "unknown subcommand %r.\n"
            "Known: find, type, bytes, verify-be, fields, enum, "
            "verify-fields, verify-consts, settings-table.\n"
            "NOTE: `find` matches TYPE names only. To search by METHOD name "
            "use\n"
            "  python tools/il2cpp_symtab.py find-method <dll> <metadec> "
            "<substr>\n"
            "which also prints the owner count, the PE section, and a warning "
            "if the\nname lands on a shared RVA or on this build's universal "
            "stub." % cmd)


if __name__ == "__main__":
    main()
