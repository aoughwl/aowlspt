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

  GAMEASM   path to GameAssembly.dll (default: the aowlspt install's copy, tools/gamepaths.py)
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

EVERY verb takes the two paths FIRST:
  il2cpp_resolve.py <GameAssembly.dll> <global-metadata.dec.dat> <verb> ...
Invoking a verb without them is REFUSED with the full command line; it is not
guessed at.

  il2cpp_resolve.py <GameAssembly.dll> <global-metadata.dec.dat> find <substr>
        # searches TYPE names ONLY. To search member names use `member`.
  il2cpp_resolve.py <GameAssembly.dll> <global-metadata.dec.dat> member <name>
                                       [--argc N] [--limit=N] [--exact]
        # searches METHOD/MEMBER names across all types. Per hit: owning type,
        # member name, RVA, arity, full DERIVED signature, thunk shape, and a
        # three-state sharedness verdict (shared/unique/unknown) that is ALWAYS
        # printed -- `unknown` is a refusal, never "safe to detour".
        # --argc N filters by parameter count: a member that exists only at an
        # arity you never call is a member you can never bind.
  il2cpp_resolve.py <GameAssembly.dll> <global-metadata.dec.dat> methods <name>
                                       [--argc N] [--shared] [--limit=N] [--name]
        # the older, terser member search. Same walk; sharedness is OPT-IN via
        # --shared. Prefer `member` for a full report.
        # A BARE NUMBER is REFUSED, not searched as a substring: `methods 16622`
        # used to answer "no method name contains '16622'" for what was plainly
        # a TYPE INDEX. Use `type 16622`, or `methods --name 16622` if you
        # really did mean the digits.
  il2cpp_resolve.py <GameAssembly.dll> <global-metadata.dec.dat> typemethods <Type>
                                       [--inherited]
        # every method DECLARED BY a type -- which `methods` cannot answer,
        # because it matches METHOD NAMES only. Per method: DERIVED signature
        # (returnType@8 / parameterStart@16 / parameterCount@34, never
        # inferred from the name), arity, RVA from the PER-IMAGE
        # methodPointers, MethodAttributes, thunk shape, and the three-state
        # sharedness verdict. `NO-CODE` is printed for an uninstantiated
        # generic method; it is not address 0.
  il2cpp_resolve.py <GameAssembly.dll> <global-metadata.dec.dat> genericmethods <Type>[::<Name>]
        # the INSTANTIATED generic methods -- the bodies `typemethods` reports
        # as NO-CODE. One address PER INSTANTIATION, with its type arguments,
        # from Il2CppCodeRegistration.genericMethodPointers via
        # genericMethodTable -> methodSpecs. Gated on `verify-generics`; on a
        # failed self-check it prints NO address at all.
  il2cpp_resolve.py <GameAssembly.dll> <global-metadata.dec.dat> verify-generics
        # the four-property self-check behind `genericmethods`, including a
        # NEGATIVE control (a non-generic method must have zero rows).
  il2cpp_resolve.py <GameAssembly.dll> <global-metadata.dec.dat> verify-parents
        # the base-class walk self-check, including a type whose base is a
        # GENERIC INSTANCE. An EMPTY parent chain FAILS loudly.
  il2cpp_resolve.py <GameAssembly.dll> <global-metadata.dec.dat> holdersof <Type>
                                       [--limit=N] [--fields|--getters] [--exact]
        # CAPABILITY-FIRST: who HOLDS a value of this type. Prints FIELD rows
        # (owning type, field name, static offset -- `--` for a const, never a
        # fabricated 0x0) and GETTER rows (zero-arg methods RETURNING it, with
        # RVA, MethodAttributes and the three-state sharedness verdict).
        # Matches the type name AS THE METADATA SPELLS IT (short name).
  il2cpp_resolve.py <GameAssembly.dll> <global-metadata.dec.dat> shared <RVA-or-VA>
        # the three-state detour-safety verdict for ONE address:
        # shared (n owners -- do not detour) / unique / unknown (a refusal:
        # the address is not in the methodPointers histogram at all).
        # exit 0 only for `unique`.
  il2cpp_resolve.py <GameAssembly.dll> <global-metadata.dec.dat> symbolize <RVA-or-VA>
                                       [--base 0x...] [--max-gap N] [--no-generics]
        # a CRASH ADDRESS -> the method whose body contains it: the greatest
        # methodPointers (or generic-body) start <= the address, with the
        # derived signature, the offset into the body, the PE section and the
        # three-state sharedness of that start. Unity has no PDB for
        # GameAssembly.dll, so its own label is the nearest EXPORT
        # (`mono_class_has_parent` for almost everything) -- a wrong answer.
        # Pass --base with the module base the report printed; a live
        # ASLR address with no --base is REFUSED, not rebased off 0x180000000.
        # INCONCLUSIVE (exit 3) outside the `il2cpp` section, past --max-gap
        # (default 0x10000), or on a generic-SHARED body.
  il2cpp_resolve.py <GameAssembly.dll> <global-metadata.dec.dat> symbolize-report <Player.log>
                                       [--max-gap N]
        # the same, for every CRASH-SITE frame of a Unity crash report, using
        # the report's own module base lines. Frames from other modules pass
        # through unchanged. A report with no GameAssembly base line says so
        # per frame rather than guessing, and a report whose GameAssembly
        # `size:` disagrees with ours is refused as a DIFFERENT BUILD.
  il2cpp_resolve.py <GameAssembly.dll> <global-metadata.dec.dat> callers <RVA-or-Type::Method>
                                       [--base 0x...] [--max-gap N] [--limit=N] [--no-cache]
        # WHO REACHES THIS METHOD. Scans the `il2cpp` and `.text` sections once
        # for `E8 rel32` (call) and `E9 rel32` (tail jmp) edges, caches the
        # ~2.4M-edge map under .cache/callgraph-<sha256-of-GameAssembly>.bin,
        # and prints every site as `<site RVA> in <Owner::Method @start +off>
        # [unique|shared xN|generic-body]`. Owners come from the SAME index
        # `symbolize` uses, so a site inside an inflated generic body is named
        # as such instead of being credited to the ordinary method before it.
        # `0 direct callers -- reached only through a vtable/delegate/event` is
        # a REAL ANSWER (exit 0): this finds direct edges only, so virtual
        # dispatch, delegates and event subscriptions leave no trace here.
        # INCONCLUSIVE (exit 3) when the address is NOT a method start -- an
        # address mid-body has no edges of its own and "0 callers" for it would
        # be a wrong answer; it offers `symbolize` instead. A name that matches
        # several distinct addresses is REFUSED with the candidates listed.
  il2cpp_resolve.py <GameAssembly.dll> <global-metadata.dec.dat> disasm <RVA-or-VA-or-Type::Method>
                                       [--count N | -n N | --len N | --to RVA]
                                       [--base 0x...] [--max-gap N] [--no-fields]
        # WINDOW FLAGS, all mutually exclusive: `--count N` (== `-n N`,
        # == `--insns N`) N INSTRUCTIONS; `--len N` (== `--length N`) N BYTES;
        # `--to RVA` up to an address. Default 64 BYTES. Every run ends with a
        # `window` line stating instructions/bytes decoded and `limit reached:
        # YES/no`, so a truncated window can never read as a whole function.
        # An unknown flag is REFUSED (exit 2) -- `--count` was once ignored
        # silently and 16 instructions read as the function's whole body.
        # THE INSTRUCTIONS AROUND AN ADDRESS -- what `bytes` cannot give you,
        # and what crash triage needs (`From @0x141ffd0 +0x11f` is
        # `cmp qword ptr [rbx + 0x118], r12`). Needs `capstone`; without it the
        # verb REFUSES with the install line and prints no instructions.
        # Decoding starts at the OWNER'S START, never mid-stream, because x86
        # has no instruction alignment and decoding backwards from a guessed
        # boundary yields plausible WRONG mnemonics; 0x20 bytes of preceding
        # context are shown when the start is known, and NONE when it is not
        # (a `.text` address), which it says. The requested address is marked
        # `>>`. `call/jmp rel32` targets are resolved through the SAME
        # symbolize index (owner @start +off). `[reg+disp]` is annotated with
        # the FIELD NAME only when the register traces back to a reference-type
        # argument and exactly one candidate type has a field there -- anything
        # else prints `?`, never a guessed name. Default length 64 bytes.
  il2cpp_resolve.py <GameAssembly.dll> <global-metadata.dec.dat> type <idx-or-Name>...
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
import array, bisect, hashlib, os, re, struct, sys, time

# ---- output encoding ------------------------------------------------------
# MEASURED: `fldoff.py fields EFT.MatchmakerOperation` died with
#   UnicodeEncodeError: 'charmap' codec can't encode character ''
# on a stock Windows cp1252 console. Some IL2CPP field/type/method names in
# this metadata carry Private-Use-Area characters (U+E000..U+F8FF), and cp1252
# has no mapping for them, so the tool CRASHED at print time after having
# already done all the work correctly.
#
# Two-part fix, and the order matters:
#  1. `vis()` escapes anything outside printable ASCII to a literal \uXXXX
#     BEFORE it is printed. The substitution is therefore VISIBLE in the
#     output -- a name containing U+E000 reads as ``, never as a
#     silently dropped character. A silently mangled field name is a
#     confidently wrong answer, which CLAUDE.md 10 rates worse than a crash.
#  2. stdout/stderr are reconfigured to UTF-8 with errors="backslashreplace"
#     as a backstop, so any path that forgets `vis()` still cannot die on
#     encoding -- it degrades to a visible \uXXXX escape too, never to a
#     dropped character and never to a traceback.
def _force_utf8_streams():
    for st in (sys.stdout, sys.stderr):
        try:
            st.reconfigure(encoding="utf-8", errors="backslashreplace")
        except Exception:
            pass          # non-reconfigurable stream (a pipe wrapper, a test
                          # capture); vis() still carries the guarantee.


_force_utf8_streams()


def vis(s):
    """Render a metadata string with every non-printable-ASCII character as a
    visible \\uXXXX escape. Never drops a character silently."""
    if s is None:
        return s
    if not isinstance(s, str):
        return s
    if all(0x20 <= ord(c) < 0x7F for c in s):
        return s
    out = []
    for c in s:
        o = ord(c)
        if 0x20 <= o < 0x7F:
            out.append(c)
        elif o <= 0xFFFF:
            out.append("\\u%04x" % o)
        else:
            out.append("\\U%08x" % o)
    return "".join(out)


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

    def mflags(self, mi):
        """Raw MethodAttributes (`flags`@28 of Il2CppMethodDefinition, uint16).

        Load-bearing, not decoration: VIRTUAL-vs-FINAL decides whether a BOUND
        DIRECT (non-virtual) call at the RVA is what the game itself does.
        0x09E6 = PUBLIC|FINAL|VIRTUAL|HIDEBYSIG|NEWSLOT|SPECIALNAME -- a sealed
        override, so a direct call is exactly the dispatch the game performs.
        A method that is VIRTUAL and NOT FINAL is genuinely overridable, and a
        direct call to the base RVA will silently run the WRONG body for a
        derived receiver -- a plausible answer, not a crash.
        """
        return struct.unpack_from("<H", self.m, self.M_OFF + mi*self.MS + 28)[0]

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

    def method_sig_indices(self, mi):
        """(return_type_index, [(param_name, param_type_index)]) -- the RAW
        Il2CppType indices behind `method_sig`, which returns rendered names.
        `disasm` needs the indices because a NAME is ambiguous: 'Profile'
        matches both EFT.Profile and uLipSync.Profile, and picking the wrong
        one yields field offsets that are structurally plausible and wrong."""
        self._ensure_params()
        base = self.M_OFF + mi*self.MS
        rt = struct.unpack_from("<i", self.m, base + 8)[0]
        ps = struct.unpack_from("<i", self.m, base + 16)[0]
        pc = struct.unpack_from("<H", self.m, base + 34)[0]
        out = []
        for i in range(pc):
            ni, _tok, ti = struct.unpack_from("<iIi", self.m,
                                              self.PAR_OFF + (ps + i)*self.PARS)
            out.append((self.s(ni), ti))
        return rt, out

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

    # The ONE place sharedness is decided. Both the library and every CLI verb
    # go through this, so the two cannot drift apart -- the previous shape was
    # `shared.get(rva, 1)` open-coded at two call sites, and that default of 1
    # is a check that cannot fail (CLAUDE.md 9b): a VA, an ASLR-rebased
    # address or a typo'd RVA is not in the table, so it silently reads back as
    # "1 owner == safe to detour". Three outcomes, never two.
    #   ("shared", n>1) ("unique", 1) ("unknown", 0)
    def sharedness(self, addr):
        """(state, owner_count) for a code address. Accepts an RVA or a VA."""
        rva = addr - self.IB if addr > self.IB else addr
        n = self.shared_rva_counts().get(rva)
        if n is None:
            return ("unknown", 0)
        return ("shared" if n > 1 else "unique", n)

    def sharedness_note(self, addr):
        """The human-readable annotation. Empty string ONLY for a known-unique
        address -- an address we cannot find is stated, never silently passed."""
        state, n = self.sharedness(addr)
        if state == "shared":
            return ("[SHARED: %d methods resolve here -- hooking this fires "
                    "for all of them]" % n)
        if state == "unknown":
            return ("[SHARENESS UNKNOWN: %s is not in the methodPointers "
                    "histogram at all -- this is NOT 'not shared'. Check you "
                    "passed a static RVA/VA from this same GameAssembly.dll, "
                    "not a live ASLR address.]" % hex(addr))
        return ""

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

    def generic_container_index(self, t):
        """Il2CppTypeDefinition.genericContainerIndex@+0x18, or -1 for a
        non-generic type. Measured on this build: >= 0 for exactly the 1,569
        types-with-instance-fields whose whole fieldOffsets array is zero, and
        -1 for all 19,930 others -- no exceptions in either direction. It is
        also strictly better than testing the name for a backtick, which
        misclassifies 638 types (compiler display classes and nested generics
        carry no backtick)."""
        self._ensure_fields()
        return struct.unpack_from("<i", self.m, self.TD_OFF + t*self.TDS + 24)[0]

    def is_generic_definition(self, t):
        return self.generic_container_index(t) >= 0

    # The ONE place a field-offset table is decided, for the same reason
    # sharedness() is (CLAUDE.md 9b). Three outcomes, never two:
    #   ("concrete", file_offset)  the type has a real static layout
    #   ("generic",  None)         an UNINSTANTIATED generic definition. IL2CPP
    #                              writes an all-zero array here because the
    #                              layout depends on the type arguments and is
    #                              built at runtime in Il2CppClass setup. Those
    #                              zeros are NOT offsets. Reading them as 0x0
    #                              is a field read of the object header.
    #   ("absent",   None)         fieldOffsets[t] is a null pointer
    def field_offsets_base(self, t):
        self._ensure_fields()
        if self.is_generic_definition(t):
            return ("generic", None)
        entry = self.rq(self.FOFF_PTR + t*8)
        base = self.v2f(entry) if entry else None
        if base is None:
            return ("absent", None)
        return ("concrete", base)

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
        layout, base = self.field_offsets_base(t)
        out = []
        for i in range(fc):
            ni, ti = struct.unpack_from("<ii", self.m, self.FLD_OFF + (fs+i)*12)
            off = struct.unpack_from("<i", self.b, base + i*4)[0] if base else None
            attrs = self.field_attrs(ti)
            lit = bool(attrs & 0x40)
            dv = self.field_default(fs + i)
            out.append({"fidx": fs + i, "name": self.s(ni), "off": off,
                        "attrs": attrs, "static": bool(attrs & 0x10),
                        "layout": layout,
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
        _layout, base = self.field_offsets_base(t)
        out = []
        for i in range(fc):
            ni, ti = struct.unpack_from("<ii", self.m, self.FLD_OFF + (fs+i)*12)
            off = struct.unpack_from("<i", self.b, base + i*4)[0] if base else None
            out.append((self.s(ni), off, self.field_is_static(ti),
                        self.field_typename(ti)))
        return out

    # Il2CppTypeEnums whose `data` field IS a typeDefinitionIndex. MEASURED on
    # this build over all 31,282 typedefs' parentIndex: 16,747 bases are 0x12
    # CLASS, 11,571 are 0x1c OBJECT (all 11,571 resolve to System.Object) and
    # 1,517 are 0x15 GENERICINST; 1,447 types have no base at all. The old
    # (0x11, 0x12) test therefore dropped 13,088 of 29,835 real base classes --
    # not just the generic ones -- and answered None, i.e. "no base class".
    TE_TYPEDEF = (0x11, 0x12, 0x0e, 0x1c)

    # ---- instantiated GENERIC METHODS ------------------------------------
    # A generic method definition (`SettingDropDown::BindTo<T>`) has NO entry
    # in its image's methodPointers table -- `typemethods` correctly prints
    # NO-CODE for it. The compiled bodies are one per INSTANTIATION and live
    # in `Il2CppCodeRegistration.genericMethodPointers`, indexed through
    # `Il2CppMetadataRegistration.genericMethodTable` -> `methodSpecs`.
    #
    #   Il2CppGenericMethodFunctionsDefinitions (16 bytes, MEASURED -- a
    #     12-byte stride puts 3,718 of the first 5,000 rows out of range,
    #     16 puts ZERO of all 206,826 out of range):
    #       int32 genericMethodIndex   -> methodSpecs
    #       int32 methodIndex          -> genericMethodPointers
    #       int32 invokerIndex         -> invokerPointers
    #       int32 adjustorThunk
    #   Il2CppMethodSpec (12 bytes):
    #       int32 methodDefinitionIndex   int32 classIndexIndex
    #       int32 methodIndexIndex        (the last two index genericInsts)
    #
    # NOTHING here is trusted without `self_check_generics`, and the CODE
    # REGISTRATION is DISCOVERED by a property (its array must point into the
    # `il2cpp` section) rather than by a hardcoded struct offset.

    def _find_generic_method_pointers(self):
        """(count, va) of genericMethodPointers, or None -- never a guess.

        Located from the codeGenModules array (the one pointer array in
        .data/.rdata whose entries are structs beginning with a "*.dll"
        string): Il2CppCodeRegistration ends with that array, so the
        genericMethodPointers pair sits a short way back. Candidate pairs are
        accepted ONLY if the count is within 4x of genericMethodTableCount AND
        a 256-entry sample lands overwhelmingly in the `il2cpp` section, which
        is where generated bodies live.
        """
        if hasattr(self, "_GMP"):
            return self._GMP
        self._ensure_fields()
        self._GMP = None
        gmt_cnt = struct.unpack_from("<I", self.b, self.v2f(self.MREG + 0x20))[0]

        def looks_module(pv):
            if not pv or self.v2f(pv) is None:
                return False
            nmp = self.rq(pv)
            if nmp is None:
                return False
            nm = self.cstr_va(nmp)
            return bool(nm and nm.endswith(".dll"))

        sites = []
        for name, vs, vz, raw, rz in self.SEC:
            if name not in (".data", ".rdata"):
                continue
            for fo in range(raw, raw + (rz & ~7), 8):
                pv = struct.unpack_from("<Q", self.b, fo)[0]
                if looks_module(pv):
                    sites.append(self.f2v(fo))
        if not sites:
            return None
        arr = sites[0]                       # base of the codeGenModules array
        refs = []
        for name, vs, vz, raw, rz in self.SEC:
            if name not in (".data", ".rdata"):
                continue
            for fo in range(raw, raw + (rz & ~7), 8):
                if struct.unpack_from("<Q", self.b, fo)[0] == arr:
                    refs.append(self.f2v(fo))
        for ref in refs:
            for delta in range(-0x100, 0, 8):
                va = ref + delta
                f = self.v2f(va)
                if f is None:
                    continue
                cnt = struct.unpack_from("<I", self.b, f)[0]
                ptr = self.rq(va + 8)
                if not ptr or self.v2f(ptr) is None:
                    continue
                if not (gmt_cnt // 4 <= cnt <= gmt_cnt * 4):
                    continue
                good = tot = 0
                for i in range(0, min(cnt, 4096), 16):
                    q = self.rq(ptr + i * 8)
                    if not q:
                        continue
                    tot += 1
                    if self.section_of_rva(q - self.IB)[0] == "il2cpp":
                        good += 1
                if tot >= 32 and good >= tot * 0.95:
                    self._GMP = (cnt, ptr)
                    return self._GMP
        return None

    def _generic_index(self):
        """{method_definition_index: [(rva_or_None, class_inst_idx,
        method_inst_idx)]} for every instantiation in genericMethodTable."""
        if hasattr(self, "_GIDX"):
            return self._GIDX
        found = self._find_generic_method_pointers()
        self._GIDX = {}
        if not found:
            return self._GIDX
        gmp_cnt, gmp = found
        gmt_cnt = struct.unpack_from("<I", self.b, self.v2f(self.MREG + 0x20))[0]
        gmt = self.rq(self.MREG + 0x28)
        ms = self.rq(self.MREG + 0x48)
        ms_cnt = struct.unpack_from("<I", self.b, self.v2f(self.MREG + 0x40))[0]
        gfo, mfo = self.v2f(gmt), self.v2f(ms)
        self._GMT_ROWS = gmt_cnt
        self._GMT_BAD = 0
        for i in range(gmt_cnt):
            gmi, mi, _inv, _adj = struct.unpack_from("<iiii", self.b, gfo + i*16)
            if not (0 <= gmi < ms_cnt and 0 <= mi < gmp_cnt):
                self._GMT_BAD += 1
                continue
            md, ci, mii = struct.unpack_from("<iii", self.b, mfo + gmi*12)
            va = self.rq(gmp + mi*8)
            self._GIDX.setdefault(md, []).append(
                ((va - self.IB) if va else None, ci, mii))
        return self._GIDX

    def generic_inst_args(self, idx):
        """The type arguments of genericInsts[idx], or None for -1."""
        if idx is None or idx < 0:
            return None
        gi = self.rq(self.MREG + 0x18)
        p = self.rq(gi + idx*8)
        if not p or self.v2f(p) is None:
            return None
        argc = struct.unpack_from("<Q", self.b, self.v2f(p))[0]
        argv = self.rq(p + 8)
        if not argv or argc > 32:
            return None
        return [self._typename_va(self.rq(argv + k*8)) for k in range(argc)]

    def generic_instantiations(self, mi):
        """[(rva, [class args] or None, [method args] or None)] for method
        definition index mi. EMPTY for a non-generic method, which is a real
        answer -- a non-generic method's code is in methodPointers."""
        out = []
        for rva, ci, mii in self._generic_index().get(mi, []):
            out.append((rva, self.generic_inst_args(ci),
                        self.generic_inst_args(mii)))
        return out

    def typedef_of_type_va(self, tva):
        """typeDefinitionIndex behind an `Il2CppType*`, or None.

        Handles THREE type enums, not two:
          0x11 VALUETYPE / 0x12 CLASS -- `data` IS the typeDefinitionIndex.
          0x15 GENERICINST            -- `data` is an `Il2CppGenericClass*`;
                                         its `type` field points at the
                                         Il2CppType of the GENERIC DEFINITION,
                                         whose data is the index.

        Dropping 0x15 is what made `parent_type` answer None -- i.e. "no base
        class" -- for every type whose base is a generic instance, e.g.
        ``EFT.UI.UIAnimatedToggleSpawner <- UISpawner`1<AnimatedToggle>``.
        A "does X derive from Y" answer of False that is really "I did not
        look" is the confidently-wrong-answer class of bug (CLAUDE.md 9b), so
        this returns the generic DEFINITION index -- the only thing metadata
        actually knows -- and never invents an instantiation.
        """
        if tva is None:
            return None
        fo = self.v2f(tva)
        if fo is None:
            return None
        te = (struct.unpack_from("<I", self.b, fo + 8)[0] >> 16) & 0xFF
        data = self.rq(tva)
        if data is None:
            return None
        if te in self.TE_TYPEDEF:
            return data if 0 <= data < self.NTYPES else None
        if te == 0x15:
            # Il2CppGenericClass { Il2CppType* type; GenericContext; ... }
            gd = self.rq(data)
            if gd is None:
                return None
            gfo = self.v2f(gd)
            if gfo is None:
                return None
            gte = (struct.unpack_from("<I", self.b, gfo + 8)[0] >> 16) & 0xFF
            if gte not in (0x11, 0x12):
                return None
            gdata = self.rq(gd)
            return gdata if (gdata is not None
                             and 0 <= gdata < self.NTYPES) else None
        return None

    def parent_type(self, t):
        """typeDefinitionIndex of t's base class, or None.

        A GENERIC-INSTANCE base (`Foo : Bar`1<Baz>`) resolves to ``Bar`1``,
        the generic DEFINITION -- see `typedef_of_type_va`. Its field layout
        is `GENERIC` (no offsets exist offline); its METHOD list is real.
        """
        self._ensure_fields()
        par = struct.unpack_from("<i", self.m, self.TD_OFF + t*self.TDS + 16)[0]
        if par < 0:
            return None
        return self.typedef_of_type_va(self.rq(self.TYPES_PTR + par*8))

    def parent_chain(self, t):
        """[t, base, base-of-base, ...] as typeDefinitionIndexes, cycle-safe."""
        chain, cur, seen = [], t, set()
        while cur is not None and cur not in seen:
            seen.add(cur)
            chain.append(cur)
            cur = self.parent_type(cur)
        return chain

    def derives_from(self, t, ancestor_name):
        """Does t derive from the named type? TWO outcomes only when the walk
        actually completed: the chain always terminates at System.Object (or at
        t itself for System.Object), so an EMPTY-but-for-t chain on a type that
        is not System.Object means the walk failed and is reported by
        `self_check_parents`, not silently as False."""
        for ct in self.parent_chain(t)[1:]:
            ns, nm = self.tname(ct)
            full = (ns + "." + nm) if ns else nm
            if full == ancestor_name or nm == ancestor_name:
                return True
        return False

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
    whether a field can be written at all.

    It also prints `GENERIC` for a field of an UNINSTANTIATED generic
    definition (``List`1``), where IL2CPP's fieldOffsets array is all zeros
    because the layout is built per-instantiation at runtime. That case used
    to render as a confident `0x0` for every field -- a caller obeying
    CLAUDE.md 5's "never guess" got a fabricated offset that reads the object
    header."""
    print("  %-8s %-34s %-30s %-40s %-22s %s" %
          ("Offset", "Field", "FieldType", "Attrs", "Const", "DeclaredBy"))
    generic = False
    for r in rows:
        if not r["has_storage"]:
            off = "--"
        elif r.get("layout") == "generic":
            off = "GENERIC"
            generic = True
        elif r.get("layout") == "absent":
            off = "ABSENT"
        elif r["off"] is None:
            off = "?"
        else:
            off = hex(r["off"])
        dv = r["default"]
        # vis(): field names in this metadata can carry Private-Use-Area
        # characters, which killed this function outright on a cp1252 console.
        print("  %-8s %-34s %-30s %-40s %-22s %s" %
              (off, vis(r["name"]), vis(r["typename"]),
               "%#06x %s" % (r["attrs"], "|".join(Resolver.attr_names(r["attrs"]))),
               "" if dv is None else vis(repr(dv)), vis(r["declared_by"])))
    if generic:
        print("  GENERIC -- NO LAYOUT: this is an uninstantiated generic type "
              "definition.")
        print("  IL2CPP has no static field offsets for it (the fieldOffsets "
              "array is all zeros);")
        print("  a concrete layout exists only per instantiation, built at "
              "runtime in Il2CppClass")
        print("  setup, and is NOT in GameAssembly.dll -- every "
              "Il2CppGenericClass.cached_class in")
        print("  the file is null. This tool cannot give you List<int>'s "
              "offsets; read them from a")
        print("  LIVE object's klass, or take the layout from a verified "
              "header and say it is borrowed.")


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


VERBS = ("find", "methods", "member", "type", "typemethods", "bytes",
         "shared", "verify-be", "fields", "verify-fields", "verify-parents",
         "enum", "verify-consts", "settings-table", "holdersof",
         "genericmethods", "verify-generics", "symbolize", "symbolize-report",
         "callers", "disasm")

# ---- the flags each verb ACCEPTS -------------------------------------------
# An unknown flag used to be silently dropped: `disasm ... --count 200` printed
# the DEFAULT 64-byte window, which read as "the function is 16 instructions
# long" -- a confidently wrong answer (CLAUDE.md 10). Every verb now refuses
# a flag it does not implement, naming the full command line and its own flag
# list. A verb with no flags is listed with an empty tuple ON PURPOSE, so that
# adding a flag without registering it here fails LOUDLY rather than silently.
VERB_FLAGS = {
    "find": (),
    "methods": ("--name", "--shared", "--argc", "--limit"),
    "member": ("--name", "--argc", "--limit", "--exact"),
    "holdersof": ("--limit", "--fields", "--getters", "--exact"),
    "type": ("--shared",),
    "typemethods": ("--inherited",),
    "genericmethods": (),
    "bytes": (),
    "shared": (),
    "fields": (),
    "enum": (),
    "verify-be": (),
    "verify-fields": (),
    "verify-parents": (),
    "verify-consts": (),
    "verify-generics": (),
    "settings-table": (),
    "symbolize": ("--base", "--max-gap", "--no-generics"),
    "symbolize-report": ("--max-gap",),
    "callers": ("--base", "--max-gap", "--limit", "--no-cache"),
    "disasm": ("--count", "-n", "--insns", "--len", "--length", "--to",
               "--base", "--max-gap", "--no-fields"),
}


def _looks_like_flag(tok):
    """A leading '-' that is not a number. `-0x10` is an address, not a flag."""
    if not tok.startswith("-") or tok == "-":
        return False
    try:
        int(tok, 0)
        return False
    except ValueError:
        return True


def unknown_flags(cmd, args):
    """Every token in `args` that looks like a flag and is not accepted."""
    ok = VERB_FLAGS.get(cmd)
    if ok is None:
        return []
    bad = []
    for tok in args:
        if not _looks_like_flag(tok):
            continue
        name = tok.split("=", 1)[0]
        if name not in ok:
            bad.append(tok)
    return bad

# ---- MethodAttributes ------------------------------------------------------
# ECMA-335 II.23.1.10. Only the bits that change a BIND DECISION are decoded;
# the raw value is always printed alongside so nothing is hidden by omission.
_MATTR_ACCESS = {0: "COMPILERCONTROLLED", 1: "PRIVATE", 2: "FAMANDASSEM",
                 3: "ASSEM", 4: "FAMILY", 5: "FAMORASSEM", 6: "PUBLIC"}
_MATTR_BITS = ((0x0010, "STATIC"), (0x0020, "FINAL"), (0x0040, "VIRTUAL"),
               (0x0080, "HIDEBYSIG"), (0x0100, "NEWSLOT"),
               (0x0400, "ABSTRACT"), (0x0800, "SPECIALNAME"))


def decode_mattrs(flags):
    """'0x09e6 PUBLIC|FINAL|VIRTUAL|... (sealed override: ...)'.

    The trailing parenthetical is the only part that is an INTERPRETATION, and
    it is worded so it cannot read as a blanket approval: a non-virtual method
    is stated as such, a sealed override is stated as such, and an overridable
    virtual is stated as a HAZARD. Nothing here says 'safe to detour' -- that
    is `shared`'s question, and it is answered separately.
    """
    names = [_MATTR_ACCESS.get(flags & 0x7, "ACCESS?%d" % (flags & 0x7))]
    names += [n for b, n in _MATTR_BITS if flags & b]
    if flags & 0x0400:
        verdict = "ABSTRACT: no body of its own; the RVA is not callable"
    elif not (flags & 0x0040):
        verdict = "non-virtual: a direct call at the RVA is the only dispatch"
    elif flags & 0x0020:
        verdict = ("sealed override: a direct call is exactly what the game "
                   "itself makes")
    else:
        verdict = ("OVERRIDABLE VIRTUAL -- HAZARD: a direct call runs THIS "
                   "body even for a derived receiver that overrides it")
    return "0x%04x %s (%s)" % (flags, "|".join(names), verdict)


def parse_argc(rest):
    """`--argc N` / `--argc=N` -> int or None. Shared by `member` and `methods`
    so the two flag parsers cannot drift apart."""
    for i, a in enumerate(rest):
        if a == "--argc":
            if i + 1 >= len(rest):
                sys.exit("usage error: --argc needs a parameter count, "
                         "e.g. --argc 2")
            return int(rest[i + 1], 0)
        if a.startswith("--argc="):
            return int(a.split("=", 1)[1], 0)
    return None


def refuse_numeric_needle(verb, needle):
    """MEASURED DEFECT: `methods 16622` searched for the SUBSTRING '16622' in
    method names, found none, and printed a confident
    "no method name contains '16622' (searched all 31282 types EXHAUSTIVELY)".
    The caller had a TYPE INDEX -- the exact form `type` accepts -- and the
    tool answered a question nobody asked, plausibly.

    A bare integer is genuinely ambiguous here and there is no safe guess, so
    this REFUSES and names BOTH readings. It never silently picks one.
    """
    if not needle.strip():
        return
    try:
        int(needle, 0)
    except ValueError:
        return
    sys.exit(
        "usage error: %r is a bare number and `%s` takes a NAME SUBSTRING, so "
        "this is ambiguous.\n"
        "  as a TYPE INDEX      -> you want:  ... type %s\n"
        "                          (%s does NOT accept a type index)\n"
        "  as a NAME SUBSTRING  -> say so:    ... %s --name %s\n"
        "REFUSED rather than guessed: searching for the literal substring %r "
        "would have printed a confident zero-hit EXHAUSTIVELY-searched verdict "
        "-- a wrong answer to a question you did not ask."
        % (needle, verb, needle, verb, verb, needle, needle))


def cmd_member(R, argv):
    """`member <name> [--argc N] [--limit=N] [--exact]`.

    `find` searches TYPE names only. Before this verb existed, answering "who
    declares get_Stamina, at what arity, and is that RVA safe to detour?"
    meant hand-rolling a ~40-line walk over all 31,282 types -- which every
    RVA-table session then rewrote from scratch.

    Three things this prints that a hand-rolled walk reliably omits:

    * the DERIVED signature (returnType@8 / parameterStart@16 /
      parameterCount@34), never a shape inferred from the method's name;
    * the three-state sharedness verdict from Resolver.sharedness(), ALWAYS,
      not opt-in. `unknown` means the address is not in the methodPointers
      histogram at all and is a REFUSAL, not "one owner, safe to detour" --
      that was exactly the `shared_rva_counts().get(rva, 1)` bug CLAUDE.md
      calls out;
    * a STUB flag when the body is this build's universal empty-body stub
      (`C2 00 00` / `C3`), shared by 6,438 methods. A stub that passes a
      signature check is the worst case there is: it binds, it returns, and
      it does nothing.

    Bounded by --limit (default 60) because a bare `member get_Position` hits
    many types; hitting the limit says so explicitly and is never reported as
    "no more matches".
    """
    positional = [a for a in argv if not a.startswith("--")]
    needle_raw = positional[0] if positional else argv[0]
    if "--name" not in argv:
        refuse_numeric_needle("member", needle_raw)
    needle = needle_raw.lower()
    exact = "--exact" in argv[1:]
    lim = 60
    rest = argv[1:]
    argc = parse_argc(rest)
    for a in rest:
        if a.startswith("--limit="):
            lim = int(a.split("=", 1)[1])

    def matches(n):
        return (n.lower() == needle) if exact else (needle in n.lower())

    hits = 0
    arity_rejected = 0
    truncated = False
    for t in range(R.NTYPES):
        ms = list(R.type_methods(t))
        names = [R.mname(mi) for mi in ms]
        if not any(matches(n) for n in names):
            continue
        full, img, resolved = R.resolve_type(t)
        for (nm, _rid, va), mi in zip(resolved, ms):
            if not matches(nm):
                continue
            try:
                sig, pc = R.sig_string(mi, nm)
            except Exception:
                sig, pc = nm + "(?)", -1
            if argc is not None and pc != argc:
                # Counted, not hidden: "several members exist but ONLY at an
                # arity the caller never asks for" is the answer, and it is
                # only visible if the filtered-out hits are reported.
                arity_rejected += 1
                continue
            if hits >= lim:
                truncated = True
                break
            hits += 1
            rva = (va - R.IB) if va else None
            print("%s::%s" % (vis(full), vis(sig)))
            print("    arity=%s  RVA=%s  image=%s"
                  % (pc if pc >= 0 else "?",
                     hex(rva) if rva is not None else "None (no method pointer)",
                     img))
            print("    attrs=%s" % decode_mattrs(R.mflags(mi)))
            if rva is None:
                print("    UNBINDABLE at a single address: no entry in this "
                      "image's Il2CppCodeGenModule.methodPointers.")
                ninst = len(R.generic_instantiations(mi))
                if ninst:
                    print("    ...because it is GENERIC: %d instantiated "
                          "bodie(s) exist, one per type argument. Use "
                          "`genericmethods %s::%s`."
                          % (ninst, full, nm))
                continue
            sec, fo, _ = R.section_of_rva(rva)
            th = R.classify_thunk(R.code_bytes(rva, 32)) if fo is not None else None
            state, n = R.sharedness(rva)
            print("    section=%s  sharedness=%s owners=%d"
                  % (sec or "UNMAPPED", state.upper(), n))
            if th:
                if th[0] == "STUB":
                    print("    STUB: %s" % th[1])
                    print("    WARNING: this is an empty body. It will bind and "
                          "pass a signature check and DO NOTHING.")
                else:
                    print("    %s: %s" % th)
            note = R.sharedness_note(rva)
            if note:
                print("    " + note)
        if truncated:
            break

    if truncated:
        print("... limit %d reached; re-run with --limit=N. This is NOT "
              "'no more matches'." % lim)
        return 0
    if hits == 0:
        if argc is not None and arity_rejected:
            print("NO MEMBER NAMED %r EXISTS AT ARITY %d (searched all %d types "
                  "EXHAUSTIVELY)." % (needle_raw, argc, R.NTYPES))
            print("It DOES exist at %d other aritie(s). Re-run without --argc "
                  "to see them." % arity_rejected)
            print("A member that exists only at an arity you never call is a "
                  "member you can never bind.")
            return 1
        print("NO METHOD NAME %s %r ANYWHERE IN THE IMAGE (searched all %d "
              "types EXHAUSTIVELY). This is a genuine zero-hit answer, not an "
              "error." % ("EQUALS" if exact else "CONTAINS",
                          needle_raw, R.NTYPES))
        return 1
    print("-- %d member(s) %s %r (searched all %d types EXHAUSTIVELY%s)"
          % (hits, "named" if exact else "matching", needle_raw, R.NTYPES,
             "; %d more rejected by --argc %d" % (arity_rejected, argc)
             if argc is not None and arity_rejected else ""))
    return 0


def cmd_holdersof(R, argv):
    """`holdersof <TypeName> [--limit=N] [--fields|--getters] [--exact]`.

    CAPABILITY-FIRST archaeology: "who HOLDS a PhysicalBase?" rather than
    "does a symbol named X exist?". Two sessions wrote this loop by hand on
    the same night; it found 7 of 12 otherwise-dead symbols.

    Reports two DIFFERENT things and never conflates them, because they are
    not interchangeable at a call site:
      FIELD  -- a static offset. Read it directly; no call, no MethodInfo*.
      GETTER -- a zero-arg method whose RETURN type matches. It must be
                CALLED, so its sharedness and its MethodAttributes matter,
                and both are printed.

    Matching is on the type NAME as the metadata spells it (the short name
    the field-type table yields), substring by default, `--exact` for equality.
    It is deliberately NOT resolved through find_one: the field-type table
    stores short/decorated names (`PhysicalBase`, `List`1<Foo>`) that a
    typedef lookup would refuse, and refusing a query that CAN be answered is
    its own failure.
    """
    positional = [a for a in argv if not a.startswith("--")]
    if not positional:
        sys.exit("usage error: `holdersof` needs a type name.\n"
                 "  il2cpp_resolve.py GAMEASM METADEC holdersof <TypeName> "
                 "[--limit=N] [--fields|--getters] [--exact]")
    want_raw = positional[0]
    refuse_numeric_needle("holdersof", want_raw)
    want = want_raw.lower()
    exact = "--exact" in argv
    only_f = "--fields" in argv
    only_g = "--getters" in argv
    lim = 80
    for a in argv:
        if a.startswith("--limit="):
            lim = int(a.split("=", 1)[1])

    def hit(tn):
        return (tn.lower() == want) if exact else (want in tn.lower())

    nf = ng = 0
    truncated = False
    for t in range(R.NTYPES):
        if truncated:
            break
        ns, nm = R.tname(t)
        owner = (ns + "." + nm) if ns else nm
        if not only_g:
            try:
                flds = R.declared_fields_ex(t)
            except Exception:
                flds = []
            for r in flds:
                if not hit(r["typename"]):
                    continue
                if nf + ng >= lim:
                    truncated = True
                    break
                nf += 1
                # A LITERAL has no storage; printing 0x0 for it is the
                # fabricated-offset bug fields/ fldoff already refuse to make.
                if not r["has_storage"]:
                    off = "--  (const: NO STORAGE)"
                elif r["off"] is None:
                    off = "--  (%s: no offset table)" % (r["layout"] or "?")
                else:
                    off = "0x%X" % r["off"]
                print("FIELD   %s.%s : %s  @%s%s"
                      % (vis(owner), vis(r["name"]), vis(r["typename"]), off,
                         "  [static]" if r["static"] else ""))
        if truncated:
            break
        if only_f:
            continue
        ms = list(R.type_methods(t))
        if not ms:
            continue
        _full, img, resolved = R.resolve_type(t)
        for (mn, _rid, va), mi in zip(resolved, ms):
            try:
                ret, _ps, pc = R.method_sig(mi)
            except Exception:
                continue
            if pc != 0 or not hit(ret):
                continue
            if nf + ng >= lim:
                truncated = True
                break
            ng += 1
            rva = (va - R.IB) if va else None
            print("GETTER  %s::%s() -> %s  RVA=%s  image=%s"
                  % (vis(owner), vis(mn), vis(ret),
                     hex(rva) if rva is not None else "None", img))
            print("        attrs=%s" % decode_mattrs(R.mflags(mi)))
            if rva is not None:
                state, n = R.sharedness(rva)
                print("        sharedness=%s owners=%d" % (state.upper(), n))

    if truncated:
        print("... limit %d reached; re-run with --limit=N. This is NOT "
              "'no more holders'." % lim)
        return 0
    if nf + ng == 0:
        print("NO FIELD OR ZERO-ARG GETTER OF A TYPE %s %r ANYWHERE (searched "
              "all %d types EXHAUSTIVELY). Genuine zero-hit, not an error."
              % ("NAMED" if exact else "MATCHING", want_raw, R.NTYPES))
        print("Note: this searches the type name AS THE METADATA SPELLS IT; "
              "try the short name (`PhysicalBase`, not `EFT.PhysicalBase`).")
        return 1
    print("-- %d field(s) + %d zero-arg getter(s) of a type %s %r (all %d "
          "types searched EXHAUSTIVELY)"
          % (nf, ng, "named" if exact else "matching", want_raw, R.NTYPES))
    return 0


PARENT_SELF_CHECK = [
    # (derived type, expected ancestor, why it is the oracle)
    ("EFT.UI.UIAnimatedToggleSpawner", "UISpawner`1",
     "base class is a GENERIC INSTANCE (UISpawner`1<AnimatedToggle>); this is "
     "the case parent_type used to answer None for"),
    ("System.String", "System.Object",
     "the ordinary 0x12 CLASS path -- a control, so a pass here plus a fail "
     "above means the generic path specifically is broken"),
]


def self_check_parents(R):
    """PASS/FAIL/INCONCLUSIVE for the base-class walk.

    An EMPTY parent chain is the failure this exists to catch: it reads as
    "X does not derive from Y" and is really "I did not look". Every row is
    checked BOTH ways -- the ancestor must be reached AND the chain must be
    longer than one -- so a walk that silently stops cannot pass.
    """
    rows, ok = [], True
    for tyname, anc, _why in PARENT_SELF_CHECK:
        try:
            t = R.find_one(tyname)
        except SystemExit:
            rows.append((tyname, anc,
                         "INCONCLUSIVE: type not found on this build"))
            ok = False
            continue
        chain = R.parent_chain(t)
        if len(chain) < 2:
            rows.append((tyname, anc,
                         "FAIL: parent chain is EMPTY (len=%d) -- the walk "
                         "did not look" % len(chain)))
            ok = False
            continue
        names = []
        for c in chain:
            ns, nm = R.tname(c)
            names.append((ns + "." + nm) if ns else nm)
        hit = R.derives_from(t, anc)
        rows.append((tyname, anc,
                     ("PASS" if hit else "FAIL") + ": " + " <- ".join(names)))
        ok = ok and hit
    return ok, rows


def method_rva_of(r, t, mi):
    """The method's RVA via the PER-IMAGE Il2CppCodeGenModule.methodPointers,
    indexed by (token & 0xFFFFFF) - 1. Using another image's table for a type
    is a documented past bug, so there is exactly ONE implementation of this
    walk and gen_uimap.py imports it. None means the RID is out of range for
    its image -- a real state (no generated code), not an error."""
    mp = r.MOD.get(r.image_of_type(t))
    if not mp or not mp[0]:
        return None
    base, cnt = mp
    rid = r.mtoken(mi) & 0xFFFFFF
    if not (1 <= rid <= cnt):
        return None
    va = r.rq(base + (rid - 1) * 8)
    return (va - r.IB) if va else None


def self_check_generics(R):
    """PASS/FAIL/INCONCLUSIVE for the generic-method-instantiation walk.

    Four properties, each of which a wrong table would break. This refuses
    rather than printing a plausible address: an address that is merely
    well-formed is exactly the failure mode this repo treats as worst-case.
    """
    rows, ok = [], True

    found = R._find_generic_method_pointers()
    if not found:
        return False, [("genericMethodPointers", "INCONCLUSIVE: not located on "
                        "this build -- refusing to print any instantiation "
                        "address")]
    cnt, va = found
    rows.append(("genericMethodPointers",
                 "FOUND count=%d @ VA 0x%x" % (cnt, va)))

    idx = R._generic_index()
    bad = getattr(R, "_GMT_BAD", -1)
    rows.append(("genericMethodTable rows in range",
                 ("PASS" if bad == 0 else "FAIL") +
                 ": %d of %d rows out of range" % (bad, getattr(R, "_GMT_ROWS", 0))))
    ok = ok and bad == 0

    # every method that HAS instantiations must itself be generic, or be
    # declared by a generic type. A table read at the wrong stride sprays
    # ordinary methods across this set.
    nong = 0
    for k in idx:
        gc = struct.unpack_from("<i", R.m, R.M_OFF + k*R.MS + 20)[0]
        dt = struct.unpack_from("<i", R.m, R.M_OFF + k*R.MS + 4)[0]
        if gc < 0 and not R.is_generic_definition(dt):
            nong += 1
    rows.append(("every owner is generic",
                 ("PASS" if nong == 0 else "FAIL") +
                 ": %d of %d method definitions are neither a generic method "
                 "nor declared by a generic type" % (nong, len(idx))))
    ok = ok and nong == 0

    # NEGATIVE control: an ordinary non-generic method must have ZERO rows.
    t = R.find_one("System.String")
    ctl = [m for m in R.type_methods(t) if R.mname(m) == "get_Length"]
    n = sum(len(idx.get(m, [])) for m in ctl)
    rows.append(("negative control System.String::get_Length",
                 ("PASS" if n == 0 else "FAIL") + ": %d instantiation row(s)" % n))
    ok = ok and n == 0

    # every sampled body must live in the generated-code section.
    tot = good = 0
    for k in list(idx)[:400]:
        for rva, _c, _m in idx[k]:
            if rva is None:
                continue
            tot += 1
            if R.section_of_rva(rva)[0] == "il2cpp":
                good += 1
    rows.append(("sampled bodies in the `il2cpp` section",
                 ("PASS" if tot and good == tot else
                  "FAIL" if tot else "INCONCLUSIVE: nothing sampled") +
                 ": %d of %d" % (good, tot)))
    ok = ok and tot and good == tot
    return bool(ok), rows


def cmd_genericmethods(R, argv):
    """Instantiated generic METHODS: `<Type>` or `<Type>::<Name>`.

    This is the table `typemethods` honestly reports as NO-CODE. There is one
    compiled body per instantiation, so there is no single "the" address --
    every instantiation is printed with its type arguments.

    Sharedness is reported as it is measured, which is NOT the same instrument
    as for ordinary methods: `Resolver.sharedness` is a histogram over the
    per-image methodPointers tables, and a generic body is not in those, so it
    answers `unknown` -- a REFUSAL, not "safe to detour". What CAN be measured
    here is duplication WITHIN genericMethodPointers, and it is real: on this
    build `SettingDropDown::BindTo<AspectRatio>` and `BindTo<EftResolution>`
    are the SAME address (0x2b811a0), because IL2CPP shares one body between
    instantiations of identical layout. That count is printed as
    `body-shared-with-N-instantiations`.
    """
    ok, rows = self_check_generics(R)
    for label, verdict in rows:
        print("   selfcheck %-46s %s" % (label, verdict))
    if not ok:
        print("GENERIC-METHOD SELF-CHECK FAILED -- refusing to print any "
              "instantiation address from this build.")
        return 1
    args = [a for a in argv if not a.startswith("--")]
    if not args:
        sys.exit("usage error: `genericmethods` needs <Type> or <Type>::<Name>")
    spec = args[0]
    tyname, _, want = spec.partition("::")
    t = R.find_one(tyname)
    idx = R._generic_index()
    dup = {}
    for k in idx:
        for rva, _c, _m in idx[k]:
            if rva is not None:
                dup[rva] = dup.get(rva, 0) + 1
    ns, nm = R.tname(t)
    full = (ns + "." + nm) if ns else nm
    print("GENERIC INSTANTIATIONS declared by %s%s"
          % (full, ("::" + want) if want else ""))
    total = 0
    for mi in R.type_methods(t):
        mn = R.mname(mi)
        if want and mn != want:
            continue
        insts = R.generic_instantiations(mi)
        if not insts:
            continue
        try:
            sig, _pc = R.sig_string(mi, mn)
        except Exception:
            sig = mn
        print("  %s  -- %d instantiation(s)" % (sig, len(insts)))
        for rva, ca, ma in sorted(insts, key=lambda x: (x[0] or 0)):
            total += 1
            print("     RVA=%-11s class<%s> method<%s>  %s"
                  % ("0x%x" % rva if rva is not None else "-",
                     ",".join(ca) if ca else "",
                     ",".join(ma) if ma else "",
                     "body-shared-with-%d-instantiations" % dup.get(rva, 0)
                     if rva is not None and dup.get(rva, 0) > 1
                     else "body-unique-in-genericMethodPointers"
                     if rva is not None else "NO BODY in the table"))
    if total == 0:
        print("  NO instantiated generic method on this type. That is a real "
              "answer for a non-generic type; for a generic one it means the "
              "compiler emitted no instantiation, NOT that a call site exists "
              "at some other address.")
    else:
        print("-- %d instantiation(s). Sharedness by the ordinary instrument "
              "(`shared <RVA>`) will say UNKNOWN for these: generic bodies are "
              "not in the per-image methodPointers histogram. That is a "
              "refusal, not 'unshared'." % total)
    return 0


def cmd_typemethods(R, argv):
    """Every method DECLARED BY a type, with a DERIVED signature, its RVA and
    a three-state sharedness verdict.

    This exists because `methods <substr>` matches METHOD NAMES only, so
    `methods EFT.UI.Settings.SettingToggle` printed a zero-hit "searched
    EXHAUSTIVELY" that reads as "this type has no methods" -- a statement
    about a TYPE that the search never made.

    Signatures are DERIVED from metadata (returnType@8, parameterStart@16,
    parameterCount@34), never inferred from the name. `--inherited` walks the
    base chain as well (base classes first), which now includes generic-
    instance bases.
    """
    args = [a for a in argv if not a.startswith("--")]
    if not args:
        sys.exit("usage error: `typemethods` needs a type name or index.\n"
                 "  il2cpp_resolve.py GAMEASM METADEC typemethods <Type> "
                 "[--inherited]")
    want_inherited = "--inherited" in argv
    try:
        t = int(args[0], 0)
    except ValueError:
        t = R.find_one(args[0])
    chain = R.parent_chain(t) if want_inherited else [t]
    total = uniq = shared = unknown = nocode = 0
    for ct in reversed(chain):
        ns, nm = R.tname(ct)
        full = (ns + "." + nm) if ns else nm
        ms = R.type_methods(ct)
        print("TYPE %d %s  image=%s  (%d declared method(s))"
              % (ct, full, R.image_of_type(ct), len(ms)))
        if ct != t:
            print("   [inherited from this base class]")
        for mi in ms:
            try:
                mname = R.mname(mi)
            except Exception:
                continue
            try:
                sig, pc = R.sig_string(mi, mname)
            except Exception:
                sig, pc = mname + "(?)", -1
            rva = method_rva_of(R, ct, mi)
            total += 1
            if rva is None:
                nocode += 1
                print("   %-64s arity=%-3s RVA=-           sharedness=NO-CODE"
                      % (sig, pc if pc >= 0 else "?"))
                print("      no methodPointers entry: an uninstantiated "
                      "generic method, or abstract/extern. NOT address 0.")
                ninst = len(R.generic_instantiations(mi))
                if ninst:
                    print("      GENERIC: %d instantiated bodie(s) exist, one "
                          "per type argument -- `genericmethods %s::%s`."
                          % (ninst, full, mname))
                continue
            state, n = R.sharedness(rva)
            if state == "unique":
                uniq += 1
            elif state == "shared":
                shared += 1
            else:
                unknown += 1
            print("   %-64s arity=%-3s RVA=0x%-9x sharedness=%s"
                  % (sig, pc if pc >= 0 else "?", rva,
                     state.upper() if state != "shared" else "SHARED x%d" % n))
            print("      attrs=%s" % decode_mattrs(R.mflags(mi)))
            note = R.annotate_rva(rva)
            sn = R.sharedness_note(rva)
            if sn:
                note = (note + "  " + sn).strip()
            if note.strip():
                print("      " + note.strip())
        print("")
    print("-- %d method(s) DECLARED BY %s%s: %d unique, %d SHARED (correct to "
          "CALL, never to detour by name), %d unknown (a refusal, not "
          "'probably safe'), %d no-code"
          % (total, args[0], " and its base chain" if want_inherited else "",
             uniq, shared, unknown, nocode))
    if not want_inherited:
        par = R.parent_type(t)
        if par is not None:
            pns, pnm = R.tname(par)
            print("   base class: %s -- its methods are NOT listed here; "
                  "re-run with --inherited."
                  % ((pns + "." + pnm) if pns else pnm))
    return 0


# ---------------------------------------------------------------------------
# symbolize -- a crash-report ADDRESS back to the method whose body contains it
#
# WHY THIS EXISTS. Unity's crash handler has no PDB for GameAssembly.dll, so it
# labels every frame with the NEAREST EXPORT. On this build that is nearly
# always `mono_class_has_parent` or `il2cpp_alloc` -- a label that names a
# function 20 MB away and is therefore a confidently wrong answer, which is the
# exact failure class CLAUDE.md 9b is about. The truth is recoverable offline:
#
#   1. rebase the frame VA to an RVA using the module base line the report
#      itself prints (`GameAssembly.dll (00007FFB2ABB0000), size: 126812160`);
#   2. find the method whose methodPointers entry is the GREATEST start <= RVA.
#
# MEASURED against Crash_2026-09-02_045551684, whose two crash-site frames a
# human hand-walked first:
#   0x00007FFB2BFD0103 -> RVA 0x1420103 -> EFT.UI.SeasonWidgetData::From
#                                          @0x141ffd0 +0x133
#   0x00007FFB2C0E9134 -> RVA 0x1539134 -> EFT.UI.MenuScreen::Show
#                                          @0x15387a0 +0x994
#
# `shared <RVA>` cannot do this: it matches EXACT starts and answers `unknown`
# for every mid-function address, which is a refusal, not an attribution.
#
# THREE OUTCOMES, NEVER TWO. A nearest-start walk will happily name a method for
# any address you give it, including an address in another section, an address
# in a hole between functions, and an address inside an inflated generic body
# whose start is not in methodPointers at all. Each of those is refused:
#
#   * not in the `il2cpp` PE section  -- generated code lives there, not in
#     `.text`. A `.text` address is engine/runtime C++ we have no symbols for.
#   * gap to the nearest start > --max-gap (default 64 KB) -- past the end of
#     any plausible function body; the nearest start is printed as a CANDIDATE
#     and the verdict stays INCONCLUSIVE.
#   * the nearest start is a GENERIC-SHARED body -- one compiled body serving
#     several generic method definitions (2,684 such RVAs on this build). The
#     owners are listed; which one the frame was executing is NOT recoverable
#     from the address, so it is not asserted.
#
# The start table is built from BOTH pointer tables: the per-image
# `methodPointers` AND `Il2CppCodeRegistration.genericMethodPointers` (65,022
# distinct RVAs here). Including the generic bodies is what stops an address
# inside an inflated generic from being attributed to whatever ordinary method
# happens to precede it in the section -- a wrong answer with a small,
# innocent-looking gap. If the generic table cannot be found, or
# `verify-generics` fails, the index says so IN EVERY VERDICT rather than
# quietly narrowing.

DEFAULT_MAX_GAP = 0x10000


def default_paths():
    """(GAMEASM, METADEC) -- the same defaults fldoff.py and friends use.

    Overridable with $AOWLSPT_GAMEASM / $AOWLSPT_METADEC. METADEC is resolved
    against the REPO, then against up to four parent directories, because a
    git worktree has no `.cache` of its own -- it lives in the main checkout.
    """
    import gamepaths as _gp
    gameasm = _gp.gameasm()
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    metadec = os.environ.get(
        "AOWLSPT_METADEC",
        os.path.join(repo, ".cache", "global-metadata.dec.dat"))
    if not os.path.exists(metadec):
        up = repo
        for _ in range(4):
            up = os.path.dirname(up)
            cand = os.path.join(up, ".cache", "global-metadata.dec.dat")
            if os.path.exists(cand):
                metadec = cand
                break
    return gameasm, metadec


def size_of_image(b):
    """SizeOfImage from a PE's optional header -- the number Unity's crash
    report prints as `size:`. Comparing the two is how we know the report came
    from THIS GameAssembly.dll and not another build."""
    e = struct.unpack_from("<I", b, 0x3C)[0]
    return struct.unpack_from("<I", b, e + 4 + 20 + 56)[0]


class Sym(object):
    """One symbolization. `ok` False means INCONCLUSIVE, never 'no match'."""

    __slots__ = ("rva", "ok", "why", "start", "offset", "owner", "kind",
                 "section", "shared_state", "shared_n", "owners", "caveat")

    def __init__(self, rva):
        self.rva, self.ok, self.why = rva, False, ""
        self.start = self.offset = None
        self.owner = self.kind = None
        self.section = None
        self.shared_state, self.shared_n = "unknown", 0
        self.owners = []
        self.caveat = ""

    def line(self):
        if not self.ok:
            s = "INCONCLUSIVE: %s" % self.why
            if self.start is not None:
                s += ("  [nearest start 0x%x +0x%x: %s]"
                      % (self.start, self.offset, self.owner))
            return s
        sh = ("[SHARED: %d methods folded onto this body -- the owner named "
              "above is one of them]" % self.shared_n
              if self.shared_state == "shared" else "[%s]" % self.shared_state)
        s = ("%s @0x%x +0x%x [section %s] %s"
             % (self.owner, self.start, self.offset, self.section, sh))
        if self.caveat:
            s += "  " + self.caveat
        return s


class SymbolIndex(object):
    """Every compiled method START in GameAssembly.dll, sorted, with its owner.

    Built once (~15 s: 5 s for methodPointers, ~10 s for the generic table) and
    cached per (gameasm, metadec) by `symbol_index()`.
    """

    def __init__(self, R, generics=True):
        self.R = R
        self.owners = {}            # rva -> [("m", t, mi) | ("g", mi, nInst)]
        self.mi_type = {}           # method index -> declaring type index
        self.generics_note = ""
        for t in range(R.NTYPES):
            mp = R.MOD.get(R.image_of_type(t))
            base, cnt = mp if mp else (None, 0)
            for mi in R.type_methods(t):
                self.mi_type[mi] = t
                if not base:
                    continue
                rid = R.mtoken(mi) & 0xFFFFFF
                if not (1 <= rid <= cnt):
                    continue
                va = R.rq(base + (rid - 1) * 8)
                if va:
                    self.owners.setdefault(va - R.IB, []).append(("m", t, mi))
        self.n_method_starts = len(self.owners)
        self.n_generic_starts = 0
        if generics:
            self._add_generics()
        else:
            self.generics_note = ("generic bodies were EXCLUDED (--no-generics)"
                                  ": an address inside an inflated generic will "
                                  "be attributed to the ordinary method that "
                                  "precedes it, which is a WRONG answer")
        self.starts = sorted(self.owners)

    def _add_generics(self):
        R = self.R
        try:
            ok, _rows = self_check_generics(R)
        except Exception as e:                      # pragma: no cover
            ok, _rows = False, e
        if not ok:
            self.generics_note = (
                "the generic-body table was NOT used: verify-generics FAILED, "
                "so an address inside an inflated generic may be attributed to "
                "the ordinary method preceding it")
            return
        gi = R._generic_index()
        if not gi:
            self.generics_note = (
                "genericMethodPointers was NOT FOUND, so inflated generic "
                "bodies are missing from this index")
            return
        seen = {}
        for md, rows in gi.items():
            for rva, _ci, _mii in rows:
                if rva:
                    seen.setdefault(rva, {}).setdefault(md, 0)
                    seen[rva][md] += 1
        for rva, mds in seen.items():
            for md, n in mds.items():
                self.owners.setdefault(rva, []).append(("g", md, n))
        self.n_generic_starts = len(seen)

    # -- naming ----------------------------------------------------------
    def label(self, entry):
        R = self.R
        if entry[0] == "m":
            _, t, mi = entry
            ns, nm = R.tname(t)
            full = (ns + "." + nm) if ns else nm
            try:
                sig, _pc = R.sig_string(mi, R.mname(mi))
            except Exception:
                sig = R.mname(mi) + "(?)"
            return vis("%s::%s" % (full, sig))
        _, mi, n = entry
        t = self.mi_type.get(mi)
        full = "<type %s>" % t
        if t is not None:
            ns, nm = R.tname(t)
            full = (ns + "." + nm) if ns else nm
        try:
            sig, _pc = R.sig_string(mi, R.mname(mi))
        except Exception:
            sig = R.mname(mi) + "(?)"
        return vis("%s::%s [generic body, %d instantiation(s) here]"
                   % (full, sig, n))

    # -- the lookup ------------------------------------------------------
    def lookup(self, rva, max_gap=DEFAULT_MAX_GAP):
        s = Sym(rva)
        sec = self.R.section_of_rva(rva)[0]
        s.section = sec or "<not in any section>"
        if sec != "il2cpp":
            s.why = ("0x%x is in %s, not the `il2cpp` section where IL2CPP "
                     "generated code lives -- methodPointers cannot name it. "
                     "(A `.text` address is engine/runtime C++; an address in "
                     "no section at all was not rebased from this image.)"
                     % (rva, s.section))
            return s
        i = bisect.bisect_right(self.starts, rva) - 1
        if i < 0:
            s.why = ("0x%x is below the FIRST known method start 0x%x"
                     % (rva, self.starts[0]))
            return s
        start = self.starts[i]
        entries = self.owners[start]
        s.start, s.offset = start, rva - start
        s.owner = self.label(entries[0])
        s.owners = entries
        s.kind = entries[0][0]
        gcount = sum(1 for e in entries if e[0] == "g")
        if s.offset > max_gap:
            s.why = ("0x%x is 0x%x bytes past the nearest method start "
                     "(0x%x), which is more than --max-gap 0x%x -- no "
                     "plausible function body is that long, so this address "
                     "is NOT attributed to it"
                     % (rva, s.offset, start, max_gap))
            return s
        if gcount and (gcount > 1 or len(entries) > 1):
            s.why = ("the nearest start 0x%x is a GENERIC-SHARED body: %d "
                     "method definition(s) compile to it, and which one this "
                     "frame was executing is not recoverable from the address. "
                     "Owners: %s"
                     % (start, len(entries),
                        "; ".join(self.label(e) for e in entries[:4])
                        + (" ..." if len(entries) > 4 else "")))
            return s
        st, n = self.R.sharedness(start)
        s.shared_state, s.shared_n = st, n
        if s.kind == "g":
            s.shared_state = "generic body (single owner)"
            s.caveat = ("[sharedness: NOT APPLICABLE -- a generic body is not "
                        "in the methodPointers histogram]")
        elif st == "unknown":
            s.caveat = self.R.sharedness_note(start)
        if self.generics_note:
            s.caveat += "  [index caveat: %s]" % self.generics_note
        s.ok = True
        return s


_SYMIDX = {}


def symbol_index(R, key=None, generics=True):
    """A cached SymbolIndex. `key` should identify the (gameasm, metadec)."""
    k = (key, generics)
    if k not in _SYMIDX:
        _SYMIDX[k] = SymbolIndex(R, generics=generics)
    return _SYMIDX[k]


# ---------------------------------------------------------------------------
# callers -- who reaches this method, from a rel32 edge scan of the image
# ---------------------------------------------------------------------------
# MEASURED need (2026-09-01/02): agents twice wrote throwaway E8-rel32 scanners
# to answer "who calls this RVA" -- once to establish that
# `MenuScreen::Show(EMenuScreenType)` @0x15387a0 has exactly ONE caller, at
# 0x1538790 inside `MenuScreen::Show(controller)` @0x1538760, and once to
# establish that `OnActionButtonPressed` @0x13f61b0 has ZERO direct callers
# because it is wired through `CompositeDisposable::SubscribeEvent`. A third
# scratchpad `callers.py` mislabelled owners inside generic-body regions,
# because it attributed sites with a nearest-start walk over methodPointers
# ONLY -- exactly the wrong answer `SymbolIndex._add_generics` exists to stop.
# So the edge scan is here, it shares the symbolize index, and it is cached.
#
# WHAT THIS IS, precisely -- it is a BYTE SCAN, not a disassembler:
#   every `E8 rel32` (call) and `E9 rel32` (jmp) byte pattern in the `il2cpp`
#   and `.text` sections whose computed target lands inside those sections.
# Two consequences that are stated in the output rather than hidden:
#   * FALSE POSITIVES are possible -- a jump table, a float constant or the
#     middle of a longer instruction can spell E8/E9 followed by four bytes
#     that happen to point at a method start. Every site is therefore printed
#     with its owner, and a site that lands in no attributable body is tagged
#     `<unattributed>` rather than counted as a caller.
#   * FALSE NEGATIVES are CERTAIN for indirect edges -- virtual dispatch,
#     delegates, events, `call [rax]`, `call qword ptr [rip+...]`. "0 direct
#     callers" therefore means exactly that and is worded to say so.


CALLGRAPH_SECTIONS = ("il2cpp", ".text")
_CALLGRAPH_MAGIC = b"AOWLCG01"


def cache_dir_for(metadec=None):
    """The shared `.cache` directory. Prefers the one the DECRYPTED metadata
    was found in, because `default_paths()` resolves that against parent
    directories: a git worktree has no `.cache` of its own, so a worktree run
    reuses the main checkout's cache instead of rebuilding a 2.4M-edge graph
    per worktree."""
    if metadec:
        d = os.path.dirname(os.path.abspath(metadec))
        if os.path.basename(d).lower() == ".cache":
            return d
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(repo, ".cache")


class CallGraph(object):
    """target RVA -> [(site RVA, kind)], kind 0 = `call` (E8), 1 = `jmp` (E9).

    Held as three parallel arrays sorted by target so the cache file is a raw
    dump and a lookup is a bisect. ~2.4M edges on this build = ~21 MB.
    """

    __slots__ = ("T", "S", "K", "n_scanned", "sections", "source",
                 "build_secs", "load_secs", "path")

    def __init__(self, T, S, K, n_scanned, sections):
        self.T, self.S, self.K = T, S, K
        self.n_scanned = n_scanned
        self.sections = sections
        self.source = "?"
        self.build_secs = self.load_secs = 0.0
        self.path = None

    # -- build -----------------------------------------------------------
    @classmethod
    def build(cls, R):
        t0 = time.time()
        b = R.b
        lo = hi = None
        segs = []
        for name, vs, vz, raw, rz in R.SEC:
            if name not in CALLGRAPH_SECTIONS:
                continue
            lo = vs if lo is None else min(lo, vs)
            hi = vs + vz if hi is None else max(hi, vs + vz)
            segs.append((name, vs, raw, min(rz, vz)))
        if not segs:
            raise RuntimeError("neither `il2cpp` nor `.text` is present in "
                               "this PE -- refusing to build a call graph")
        rows = []
        add = rows.append
        n_scanned = 0
        for _name, vs, raw, size in segs:
            end = raw + size
            n_scanned += size
            for op, kind in ((0xE8, 0), (0xE9, 1)):
                pat = bytes((op,))
                i = b.find(pat, raw, end - 5)
                while i != -1:
                    tgt = (vs + (i - raw) + 5
                           + struct.unpack_from("<i", b, i + 1)[0])
                    if lo <= tgt < hi:
                        add((tgt, vs + (i - raw), kind))
                    i = b.find(pat, i + 1, end - 5)
        rows.sort()
        g = cls(array.array("I", [r[0] for r in rows]),
                array.array("I", [r[1] for r in rows]),
                array.array("B", [r[2] for r in rows]),
                n_scanned, [s[0] for s in segs])
        g.source = "built"
        g.build_secs = time.time() - t0
        return g

    # -- disk cache ------------------------------------------------------
    @staticmethod
    def cache_path(gameasm_bytes, cdir):
        h = hashlib.sha256(gameasm_bytes).hexdigest()[:16]
        return os.path.join(cdir, "callgraph-%s.bin" % h)

    def save(self, path):
        tmp = path + ".tmp%d" % os.getpid()
        d = os.path.dirname(path)
        if d and not os.path.isdir(d):
            os.makedirs(d)
        with open(tmp, "wb") as fh:
            fh.write(_CALLGRAPH_MAGIC)
            fh.write(struct.pack("<QQ", len(self.T), self.n_scanned))
            self.T.tofile(fh)
            self.S.tofile(fh)
            self.K.tofile(fh)
        os.replace(tmp, path)
        self.path = path

    @classmethod
    def load(cls, path, sections):
        """A CallGraph, or None if the file is absent/short/wrong-magic. A
        truncated cache must read as a MISS, never as a graph with fewer
        edges -- that would silently under-report callers."""
        try:
            with open(path, "rb") as fh:
                head = fh.read(len(_CALLGRAPH_MAGIC) + 16)
                if (len(head) < len(_CALLGRAPH_MAGIC) + 16
                        or head[:len(_CALLGRAPH_MAGIC)] != _CALLGRAPH_MAGIC):
                    return None
                n, n_scanned = struct.unpack_from(
                    "<QQ", head, len(_CALLGRAPH_MAGIC))
                want = len(_CALLGRAPH_MAGIC) + 16 + n * 9
                if os.path.getsize(path) != want:
                    return None
                T, S, K = array.array("I"), array.array("I"), array.array("B")
                T.fromfile(fh, n)
                S.fromfile(fh, n)
                K.fromfile(fh, n)
        except (OSError, EOFError, ValueError):
            return None
        g = cls(T, S, K, n_scanned, sections)
        g.source = "cache"
        g.path = path
        return g

    # -- query -----------------------------------------------------------
    def edges_to(self, rva):
        """[(site RVA, kind)] for an EXACT target address, in address order."""
        i = bisect.bisect_left(self.T, rva)
        out = []
        T, S, K = self.T, self.S, self.K
        n = len(T)
        while i < n and T[i] == rva:
            out.append((S[i], K[i]))
            i += 1
        out.sort()
        return out

    def note(self):
        if self.source == "cache":
            return ("callgraph: CACHE HIT -- %d rel32 edge(s) loaded in "
                    "%.2fs from %s" % (len(self.T), self.load_secs, self.path))
        return ("callgraph: CACHE MISS -- scanned %d byte(s) of %s for E8/E9 "
                "rel32, %d edge(s), built in %.2fs%s"
                % (self.n_scanned, "+".join(self.sections), len(self.T),
                   self.build_secs,
                   (", cached at " + self.path) if self.path else
                   " (NOT cached -- the cache directory was not writable)"))


_CALLGRAPH = {}


def call_graph(R, key=None, cache_dir=None, use_cache=True):
    """A CallGraph for this image: process cache, then disk cache, then build.

    Keyed on disk by the sha256 of GameAssembly.dll's BYTES, so a Tarkov update
    misses rather than answering from the previous build's edges.
    """
    if key in _CALLGRAPH:
        return _CALLGRAPH[key]
    cdir = cache_dir or cache_dir_for(key[1] if isinstance(key, tuple) else None)
    path = CallGraph.cache_path(R.b, cdir)
    g = None
    if use_cache:
        t0 = time.time()
        g = CallGraph.load(path, list(CALLGRAPH_SECTIONS))
        if g is not None:
            g.load_secs = time.time() - t0
    if g is None:
        g = CallGraph.build(R)
        if use_cache:
            try:
                g.save(path)
            except OSError:
                g.path = None
    _CALLGRAPH[key] = g
    return g


def method_starts(idx):
    """The set of addresses `callers` will accept: every methodPointers start
    plus every inflated generic-body start, i.e. exactly the keys the
    symbolize index owns."""
    return idx.owners


def site_tag(R, idx, site, max_gap=DEFAULT_MAX_GAP):
    """(owner_label, start, offset, tag) for a call SITE, or (None, ...) when
    the site is not attributable. `tag` is one of unique / shared(n) /
    generic-body / <unattributed>."""
    s = idx.lookup(site, max_gap=max_gap)
    if s.start is None:
        return (None, None, None, "<unattributed>")
    entries = idx.owners.get(s.start, [])
    if any(e[0] == "g" for e in entries):
        tag = "generic-body"
        if len(entries) > 1:
            tag = "generic-body, %d owners" % len(entries)
    else:
        st, n = R.sharedness(s.start)
        tag = "shared x%d" % n if st == "shared" else st
    if not s.ok and s.offset is not None and s.offset > max_gap:
        return (None, s.start, s.offset, "<unattributed>")
    return (s.owner, s.start, s.offset, tag)


def resolve_callee_name(R, spec):
    """(rva, label) for a `Type::Method` or bare method name, or (None, msg).

    Never guesses: more than one candidate address is a refusal that PRINTS
    the candidates, because "the only substring match" is how `fields
    EFT.CharacterController` once answered for a different type entirely.
    """
    tyname, sep, mname = spec.partition("::")
    cands = []
    if sep:
        wanted_types = [t for t, full in R.find(tyname)
                        if full == tyname or full.split(".")[-1] == tyname]
        if not wanted_types:
            return (None, "NO SUCH TYPE %r (searched all %d exhaustively)."
                    % (tyname, R.NTYPES))
    else:
        mname = tyname
        wanted_types = range(R.NTYPES)
    for t in wanted_types:
        for mi in R.type_methods(t):
            if R.mname(mi) != mname:
                continue
            rva = method_rva_of(R, t, mi)
            ns, nm = R.tname(t)
            full = (ns + "." + nm) if ns else nm
            try:
                sig, _pc = R.sig_string(mi, R.mname(mi))
            except Exception:
                sig = mname + "(?)"
            cands.append((rva, vis("%s::%s" % (full, sig))))
    if not cands:
        return (None, "NO METHOD NAMED %r%s (searched exhaustively). "
                "`callers` matches the method name EXACTLY; use `member %s` "
                "to search by substring."
                % (mname, (" on type %r" % tyname) if sep else "", mname))
    addrs = set(a for a, _ in cands if a is not None)
    if len(addrs) == 1 and len(cands) == 1:
        return (cands[0][0], cands[0][1])
    if len(addrs) == 1:
        # Several overloads folded onto ONE address is itself the answer worth
        # stating: the caller list below is the union over all of them.
        return (sorted(addrs)[0],
                "%s  [%d definitions resolve to this one address]"
                % (cands[0][1], len(cands)))
    lines = ["AMBIGUOUS: %d method(s) named %r, at %d distinct addresses -- "
             "refusing to pick one. Pass an RVA, or Type::Method:"
             % (len(cands), mname, len(addrs))]
    for a, lab in cands[:20]:
        lines.append("  %-12s %s" % ("NO-CODE" if a is None else hex(a), lab))
    if len(cands) > 20:
        lines.append("  ... and %d more" % (len(cands) - 20))
    return (None, "\n".join(lines))


def cmd_callers(R, argv, key=None):
    if not argv:
        print("usage: callers <RVA-or-VA-or-Type::Method> [--base 0x...] "
              "[--max-gap N] [--no-cache] [--limit=N]")
        return 2
    max_gap = DEFAULT_MAX_GAP
    base = None
    use_cache = True
    limit = 200
    rest = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--max-gap" and i + 1 < len(argv):
            max_gap = int(argv[i + 1], 0); i += 2; continue
        if a.startswith("--max-gap="):
            max_gap = int(a.split("=", 1)[1], 0); i += 1; continue
        if a == "--base" and i + 1 < len(argv):
            base = int(argv[i + 1], 0); i += 2; continue
        if a.startswith("--base="):
            base = int(a.split("=", 1)[1], 0); i += 1; continue
        if a == "--no-cache":
            use_cache = False; i += 1; continue
        if a.startswith("--limit="):
            limit = int(a.split("=", 1)[1], 0); i += 1; continue
        rest.append(a); i += 1
    if not rest:
        print("callers: no address or name given")
        return 2
    spec = rest[0]
    label = None
    try:
        addr = int(spec, 0)
    except ValueError:
        rva, label = resolve_callee_name(R, spec)
        if rva is None:
            print(label)
            return 3
        addr = rva
        base = None
    else:
        if base is not None:
            addr -= base
            if addr < 0:
                print("INCONCLUSIVE: 0x%x is BELOW the --base you gave -- "
                      "that address is not in this module." % (addr + base))
                return 3
        elif addr >= R.IB + 0x10000000:
            print("INCONCLUSIVE: 0x%x looks like a LIVE (ASLR-relocated) "
                  "address, not an RVA. GameAssembly.dll is relocated at "
                  "runtime; pass --base 0x<module base>. Subtracting the "
                  "PREFERRED base 0x%x from a relocated address is the "
                  "classic wrong answer." % (addr, R.IB))
            return 3
        elif addr >= R.IB:
            addr -= R.IB
    rva = addr

    idx = symbol_index(R, key=key)
    print("index: %d methodPointers start(s) + %d generic body start(s)"
          % (idx.n_method_starts, idx.n_generic_starts))
    if idx.generics_note:
        print("NOTE: %s" % idx.generics_note)

    # -- the refusal: `callers` answers for a method START, nothing else.
    if rva not in idx.owners:
        sec = R.section_of_rva(rva)[0] or "<no section>"
        s = idx.lookup(rva, max_gap=max_gap)
        print("INCONCLUSIVE: 0x%x is NOT a method start (section %s). "
              "`callers` matches an EXACT rel32 target; an address in the "
              "middle of a body has no call edges of its own, and answering "
              "'0 callers' for it would be a confidently wrong answer."
              % (rva, sec))
        if s.start is not None and s.offset is not None:
            print("  nearest start 0x%x is +0x%x below: %s"
                  % (s.start, s.offset, s.owner))
            print("  did you mean:  callers 0x%x" % s.start)
        print("  to name the containing method instead:  symbolize 0x%x"
              % rva)
        return 3

    entries = idx.owners[rva]
    if label is None:
        label = idx.label(entries[0])
    print("callee: 0x%x  %s" % (rva, label))
    if len(entries) > 1:
        print("WARNING: %d method definitions share this address, so the "
              "callers below are the UNION over all of them and cannot be "
              "split apart:" % len(entries))
        for e in entries[:6]:
            print("    %s" % idx.label(e))
        if len(entries) > 6:
            print("    ... and %d more" % (len(entries) - 6))
    else:
        st, n = R.sharedness(rva)
        if st == "shared":
            print("WARNING: %s" % R.sharedness_note(rva))

    g = call_graph(R, key=key, use_cache=use_cache)
    print(g.note())

    edges = g.edges_to(rva)
    n_call = n_jmp = n_unattr = 0
    shown = 0
    self_rec = 0
    for site, kind in edges:
        owner, start, off, tag = site_tag(R, idx, site, max_gap=max_gap)
        if owner is None:
            n_unattr += 1
        elif kind == 0:
            n_call += 1
        else:
            n_jmp += 1
        if start == rva:
            self_rec += 1
        if shown < limit:
            shown += 1
            if owner is None:
                print("  0x%-9x %-4s in <unattributed> -- no method body "
                      "contains this site (nearest start %s). Most likely a "
                      "byte coincidence in data, NOT a call."
                      % (site, "call" if kind == 0 else "jmp",
                         ("0x%x, +0x%x away" % (start, off))
                         if start is not None else "none"))
            else:
                print("  0x%-9x %-4s in %s @0x%x +0x%x [%s]%s"
                      % (site, "call" if kind == 0 else "jmp", owner, start,
                         off, tag, "  <- SELF (recursion)"
                         if start == rva else ""))
    if shown < len(edges):
        print("  ... %d more site(s) suppressed by --limit=%d"
              % (len(edges) - shown, limit))

    total = n_call + n_jmp
    if total == 0:
        if n_unattr:
            print("   (%d rel32 byte pattern(s) DO point here but lie in no "
                  "attributable method body -- counted as data coincidences, "
                  "not callers. They are listed above so you can judge.)"
                  % n_unattr)
        print("-- 0 direct callers -- reached only through a vtable/delegate/"
              "event. That is a REAL ANSWER, not a failure: this scan finds "
              "`E8 rel32` / `E9 rel32` edges only, so a virtual dispatch, a "
              "delegate, an event subscription (e.g. via "
              "CompositeDisposable::SubscribeEvent) or a `call [reg]` leaves "
              "no edge here. It also means NOTHING inlined this body away.")
        return 0
    print("-- %d direct caller site(s): %d call (E8), %d tail jmp (E9)%s%s"
          % (total, n_call, n_jmp,
             ("; %d self-recursive" % self_rec) if self_rec else "",
             ("; %d unattributed candidate(s) NOT counted" % n_unattr)
             if n_unattr else ""))
    print("   (a tail `jmp` is a real edge -- the compiler reused the "
          "caller's frame -- but the caller does not return through it.)")
    return 0


# `D:\Aowlspt\GameAssembly.dll:GameAssembly.dll (00007FFB2ABB0000), size:
#  126812160 (result: 0), SymType: '-deferred-', PDB: ''`
MODBASE_RX = re.compile(
    r"^.*?[:\\/]([^\\/:]+?)\.(?:dll|exe)\s*:\s*[^\s(]+\s+"
    r"\(([0-9A-Fa-f]{8,16})\)\s*,\s*size:\s*(\d+)", re.IGNORECASE)


def parse_module_bases(lines):
    """{module_stem_lower: (base_va, size_of_image)} from a Unity crash report.

    Unity prints the loaded-module list twice in some reports (a `-deferred-`
    pass and an `-exported-` one). Both passes agree in every report measured;
    if a second pass ever disagreed, the FIRST is kept and the conflict is
    recorded under the key `<name>:conflict`, so a caller can refuse rather
    than rebase against an arbitrary one of two bases.
    """
    if isinstance(lines, str):
        lines = lines.splitlines()
    out = {}
    for ln in lines:
        m = MODBASE_RX.match(ln)
        if not m:
            continue
        name = m.group(1).lower()
        base, size = int(m.group(2), 16), int(m.group(3))
        if name in out:
            if out[name] != (base, size):
                out[name + ":conflict"] = (base, size)
            continue
        out[name] = (base, size)
    return out


def symbolize_frames(R, frames, bases, index=None, max_gap=DEFAULT_MAX_GAP,
                     module="gameassembly", key=None):
    """[(frame, Sym-or-None, note)] for crash-report frames.

    `frames` is any sequence of objects with `.addr` (hex string or int) and
    `.module`. A frame in another module yields (frame, None, "") -- it is
    passed through, never guessed at. A GameAssembly frame with no base line,
    or with a base line whose `size:` disagrees with our GameAssembly.dll,
    yields (frame, None, <why not>) -- stated, never silently skipped.
    """
    idx = index if index is not None else symbol_index(R, key=key)
    got = bases.get(module)
    conflict = (module + ":conflict") in bases
    ours = size_of_image(R.b)
    why = None
    if got is None:
        why = ("no `%s` module base line in this report, so its frames CANNOT "
               "be rebased to RVAs -- not symbolized (this is not 'no match')"
               % module)
    elif conflict:
        why = ("this report lists TWO DIFFERENT bases for %s; refusing to "
               "pick one" % module)
    elif got[1] != ours:
        why = ("the report's %s is SizeOfImage %d but ours is %d -- a "
               "DIFFERENT BUILD. Refusing to symbolize against it."
               % (module, got[1], ours))
    out = []
    for f in frames:
        mod = (getattr(f, "module", "") or "").lower()
        if mod != module:
            out.append((f, None, ""))
            continue
        if why:
            out.append((f, None, why))
            continue
        addr = f.addr if isinstance(f.addr, int) else int(str(f.addr), 16)
        out.append((f, idx.lookup(addr - got[0], max_gap=max_gap), ""))
    return out


def _report_frames(lines):
    """Crash-site frames of a report. Delegates to crashwatch's parser -- the
    ONE place the report format is known -- imported lazily so the two modules
    can import each other without a cycle."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import crashwatch
    blocks = crashwatch.parse_stack_blocks(lines)
    if blocks is None:
        return None
    return blocks[0] if blocks else []


def cmd_symbolize(R, argv, key=None):
    if not argv:
        print("usage: symbolize <RVA-or-VA> [--base 0x...] [--max-gap N] "
              "[--no-generics]")
        return 2
    max_gap = DEFAULT_MAX_GAP
    base = None
    gen = True
    rest = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--max-gap" and i + 1 < len(argv):
            max_gap = int(argv[i + 1], 0)
            i += 2
            continue
        if a.startswith("--max-gap="):
            max_gap = int(a.split("=", 1)[1], 0)
            i += 1
            continue
        if a == "--base" and i + 1 < len(argv):
            base = int(argv[i + 1], 0)
            i += 2
            continue
        if a.startswith("--base="):
            base = int(a.split("=", 1)[1], 0)
            i += 1
            continue
        if a == "--no-generics":
            gen = False
            i += 1
            continue
        rest.append(a)
        i += 1
    if not rest:
        print("symbolize: no address given")
        return 2
    addr = int(rest[0], 0)
    if base is not None:
        rva = addr - base
        if rva < 0:
            print("INCONCLUSIVE: 0x%x is BELOW the --base 0x%x you gave -- "
                  "that address is not in this module." % (addr, base))
            return 3
    elif addr >= R.IB + 0x10000000:
        # A live ASLR address with no --base. Refuse: subtracting the PREFERRED
        # base 0x180000000 from a relocated address is the classic wrong answer.
        print("INCONCLUSIVE: 0x%x looks like a LIVE (ASLR-relocated) address, "
              "not an RVA. GameAssembly.dll is relocated at runtime, so pass "
              "the module base the crash report printed: --base 0x<base>."
              % addr)
        return 3
    else:
        rva = addr - R.IB if addr >= R.IB else addr
    idx = symbol_index(R, key=key, generics=gen)
    print("index: %d methodPointers start(s) + %d generic body start(s); "
          "max-gap 0x%x" % (idx.n_method_starts, idx.n_generic_starts, max_gap))
    if idx.generics_note:
        print("NOTE: %s" % idx.generics_note)
    s = idx.lookup(rva, max_gap=max_gap)
    print("0x%x  %s" % (rva, s.line()))
    return 0 if s.ok else 3


def cmd_symbolize_report(R, argv, key=None):
    if not argv:
        print("usage: symbolize-report <Player.log> [--max-gap N]")
        return 2
    max_gap = DEFAULT_MAX_GAP
    path = None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--max-gap" and i + 1 < len(argv):
            max_gap = int(argv[i + 1], 0)
            i += 2
            continue
        if a.startswith("--max-gap="):
            max_gap = int(a.split("=", 1)[1], 0)
            i += 1
            continue
        path = a
        i += 1
    if not path or not os.path.isfile(path):
        print("no such file: %r" % path)
        return 2
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        lines = fh.read().splitlines()
    frames = _report_frames(lines)
    if frames is None:
        print("INCONCLUSIVE: %s has no `OUTPUTTING STACK TRACE` section -- it "
              "is a log, not a crash report." % path)
        return 3
    if not frames:
        print("INCONCLUSIVE: the stack section of %s contains no frames."
              % path)
        return 3
    bases = parse_module_bases(lines)
    out = symbolize_frames(R, frames, bases, max_gap=max_gap, key=key)
    n_ok = 0
    for f, s, note in out:
        print("   %s" % f.text)
        if s is None:
            if note:
                print("       -> %s" % note)
            continue
        print("       -> %s" % s.line())
        n_ok += 1 if s.ok else 0
    print("%d of %d crash-site frame(s) symbolized; the rest are other "
          "modules or refusals stated above." % (n_ok, len(out)))
    return 0 if n_ok else 3


# ---------------------------------------------------------------------------
# disasm -- the instructions AROUND an address, not 16 raw bytes
# ---------------------------------------------------------------------------
# MEASURED need (2026-09-02): two agents in one night wrote throwaway capstone
# scripts, because `bytes` prints 16 bytes and crash triage needs the code
# around a fault offset. The worked example both wanted:
#   `From @0x141ffd0 +0x11f` -> `cmp qword ptr [rbx + 0x118], r12`, where rbx
#   holds the `profile` argument, so 0x118 is `EFT.Profile.BattlePass`.
#
# THREE things this does that a throwaway script does not:
#   * it decodes from the OWNER'S START, never from the middle. x86 has no
#     instruction alignment: decoding from `fault - 0x20` produces plausible,
#     WRONG mnemonics. When the start is unknown (a `.text` address) it says so
#     and shows NO preceding context rather than inventing it.
#   * `call/jmp rel32` targets go through the SAME symbolize index the
#     `symbolize`/`callers` verbs use, so a target names its owner and offset.
#   * `[reg+disp]` is annotated with a FIELD NAME only when the register can be
#     traced back to an argument whose type is a reference type with a concrete
#     layout, and only when exactly one candidate type has a field at that
#     displacement. Everything else prints `?`. The Win64 mapping is a
#     best-effort inference (a value-type return steals RCX for a hidden return
#     buffer, and whether a small struct does that is not decidable offline),
#     so BOTH mappings are tried and a name is printed only if they agree on
#     one field. A wrong field name would be exactly the confidently-wrong
#     answer this repo treats as worst-case.

DISASM_DEFAULT_LEN = 64
DISASM_CONTEXT = 0x20            # bytes of preceding context, when reachable
DISASM_MAX_BACKSCAN = 0x20000    # refuse to decode a longer run-up than this

# every sub-register name -> its 64-bit root. Built explicitly; capstone's
# register ids are not stable enough across versions to key on.
_GPR64 = {}
for _r in ("ax", "bx", "cx", "dx", "si", "di", "bp", "sp"):
    _full = "r" + _r
    _GPR64[_full] = _full
    _GPR64["e" + _r] = _full
    _GPR64[_r] = _full
    if _r in ("ax", "bx", "cx", "dx"):
        _GPR64[_r[0] + "l"] = _full
        _GPR64[_r[0] + "h"] = _full
    else:
        _GPR64[_r + "l"] = _full
for _n in range(8, 16):
    _full = "r%d" % _n
    for _sfx in ("", "b", "w", "d"):
        _GPR64[_full + _sfx] = _full
del _r, _n


def reg_root(name):
    """'ebx' -> 'rbx'; None for xmm/segment/unknown."""
    return _GPR64.get((name or "").lower())


def import_capstone():
    """(module, None) or (None, refusal-text). Never raises."""
    try:
        import capstone
    except Exception as e:                                  # pragma: no cover
        return (None, "disasm: capstone is NOT importable (%s), so there is "
                "nothing to disassemble. This verb prints NO instructions "
                "rather than guessing at them.\n"
                "  install it:   python -m pip install capstone\n"
                "  meanwhile:    `bytes <RVA> <N>` still prints raw bytes."
                % e)
    return (capstone, None)


class FieldAtOffset(object):
    """{typedef index -> {offset -> [ 'Full.Name' ]}} for INSTANCE fields with
    a concrete layout. A generic definition contributes NOTHING: its
    fieldOffsets array is all zeros and reading it as offsets is the fabricated
    answer `field_offsets_base` exists to refuse."""

    def __init__(self, R):
        self.R = R
        self._c = {}

    def table(self, tdi):
        if tdi in self._c:
            return self._c[tdi]
        t = {}
        try:
            rows = self.R.all_fields_ex(tdi)
        except Exception:
            rows = []
        for r in rows:
            if r["static"] or not r["has_storage"]:
                continue
            if r["off"] is None or r["layout"] != "concrete":
                continue
            t.setdefault(r["off"], []).append(
                "%s.%s" % (r["declared_by"].split(".")[-1], r["name"]))
        self._c[tdi] = t
        return t

    def at(self, tdi, off):
        return self.table(tdi).get(off, [])


def arg_register_map(R, t, mi):
    """({reg -> [(tdi, 'arg name')]}, [display strings], [caveats]).

    Win64 + IL2CPP: RCX/RDX/R8/R9 carry, in order, a hidden return buffer (only
    when the return value does not fit in a register), `this` for an instance
    method, then the declared parameters, then the hidden trailing
    `const MethodInfo*`. Only CLASS-typed slots (type enum 0x12) become
    annotation candidates -- a value type may be passed by hidden pointer and
    its field offsets are relative to a different base, which is precisely the
    kind of plausible-but-wrong offset this file refuses elsewhere.
    """
    REGS = ("rcx", "rdx", "r8", "r9")
    caveats = []
    static = bool(R.mflags(mi) & 0x10)
    rt, params = R.method_sig_indices(mi)
    ret_te = R.type_enum_of(rt) if (rt is not None and rt >= 0) else None
    ret_name = R.field_typename(rt) if (rt is not None and rt >= 0) else "?"

    def slots(with_sret):
        s = []
        if with_sret:
            s.append(("<retbuf: %s>" % ret_name, None))
        if not static:
            ns, nm = R.tname(t)
            s.append(("this: %s" % nm, t if _is_class_type_def(R, t) else None))
        for pname, ti in params:
            tdi = R.typedef_of_type_va(R.rq(R.TYPES_PTR + ti * 8))
            te = R.type_enum_of(ti)
            usable = (te == 0x12) and tdi is not None
            s.append(("%s %s" % (R.field_typename(ti), pname),
                      tdi if usable else None))
        s.append(("<MethodInfo*>", None))
        return s

    # A VALUE-TYPE return MAY take RCX as a hidden buffer (measured on this
    # build: a 16-byte Rect does, an 8-byte Vector2 does not -- it comes back
    # in RAX). Which one applies is not decidable from metadata, so both
    # mappings are carried and only an offset both agree on is ever named.
    maybe_sret = ret_te in (0x11, 0x15)
    prim = slots(maybe_sret)
    alt = slots(not maybe_sret) if maybe_sret else None
    if maybe_sret:
        caveats.append(
            "return type %s is a VALUE TYPE: RCX is shown as the hidden return "
            "buffer, but a struct of 8 bytes or less is returned in RAX and "
            "every argument shifts down one register. BOTH mappings are tried "
            "for field annotation and a name is printed ONLY if they agree."
            % ret_name)

    cand = {}
    disp = []
    for i, reg in enumerate(REGS):
        labels = []
        for s in (prim, alt):
            if not s or i >= len(s):
                continue
            lbl, tdi = s[i]
            if lbl not in labels:
                labels.append(lbl)
            if tdi is not None:
                cand.setdefault(reg, []).append((tdi, lbl))
        if labels:
            disp.append("%s=%s" % (reg, " | ".join(labels)))
    over = max(len(prim), len(alt) if alt else 0) - len(REGS)
    if over > 0:
        caveats.append("%d further argument slot(s) are passed on the STACK "
                       "and are not traced." % over)
    return cand, disp, caveats


def _is_class_type_def(R, tdi):
    """True when the typedef is a reference type (so a register holding it
    points AT the object header and metadata field offsets apply directly)."""
    if tdi is None:
        return False
    if R.is_generic_definition(tdi):
        return False
    try:
        return not R.derives_from(tdi, "System.ValueType")
    except Exception:
        return False


class RegTrace(object):
    """A deliberately dumb forward tracer: 64-bit register-to-register moves
    and argument homing to the stack frame, nothing else.

    It is STRAIGHT-LINE only -- it walks the bytes in address order and knows
    nothing about branches, so a register written on a path it did not follow
    is simply DROPPED, never carried. Dropping yields `?`; carrying would yield
    a wrong field name. Every write that is not an understood copy clears the
    destination.
    """

    def __init__(self, cand):
        self.regs = {r: list(v) for r, v in cand.items()}
        self.slots = {}
        self.rsp = 0
        self.rsp_ok = True

    def types_of(self, reg):
        return self.regs.get(reg, [])

    def step(self, cs, ins):
        ops = [o for o in ins.operands]
        mn = ins.mnemonic
        copy = None
        store = None
        load = None
        if mn == "mov" and len(ops) == 2:
            d, s = ops[0], ops[1]
            if (d.type == cs.x86.X86_OP_REG and s.type == cs.x86.X86_OP_REG
                    and d.size == 8 and s.size == 8):
                copy = (reg_root(ins.reg_name(d.reg)),
                        reg_root(ins.reg_name(s.reg)))
            elif (d.type == cs.x86.X86_OP_MEM and s.type == cs.x86.X86_OP_REG
                  and s.size == 8):
                fo = self._frame_off(cs, ins, d)
                if fo is not None:
                    store = (fo, reg_root(ins.reg_name(s.reg)))
            elif (d.type == cs.x86.X86_OP_REG and s.type == cs.x86.X86_OP_MEM
                  and d.size == 8):
                fo = self._frame_off(cs, ins, s)
                if fo is not None:
                    load = (reg_root(ins.reg_name(d.reg)), fo)
        # every written register loses its type unless the write is a copy we
        # understand; this is applied FIRST so a copy can then reinstate it.
        try:
            _read, written = ins.regs_access()
        except Exception:                                   # pragma: no cover
            written = []
        for w in written:
            root = reg_root(ins.reg_name(w))
            if root and root != "rsp":
                self.regs.pop(root, None)
        if copy and copy[0] and copy[1] is not None:
            src = self.regs.get(copy[1])
            if src:
                self.regs[copy[0]] = list(src)
        if load and load[0]:
            got = self.slots.get(load[1])
            if got:
                self.regs[load[0]] = list(got)
        if store and store[1]:
            got = self.regs.get(store[1])
            if got:
                self.slots[store[0]] = list(got)
        self._track_rsp(cs, ins, ops)

    def _frame_off(self, cs, ins, op):
        """Frame offset (relative to the entry RSP) for an [rsp+disp] operand,
        or None. Anything that makes RSP unknown disables slot tracking."""
        if not self.rsp_ok:
            return None
        m = op.mem
        if m.index != 0 or m.base == 0:
            return None
        if reg_root(ins.reg_name(m.base)) != "rsp":
            return None
        return self.rsp + m.disp

    def _track_rsp(self, cs, ins, ops):
        if not self.rsp_ok:
            return
        mn = ins.mnemonic
        if mn == "push":
            self.rsp -= 8
            return
        if mn == "pop":
            self.rsp += 8
            return
        if mn in ("sub", "add") and len(ops) == 2:
            d, s = ops[0], ops[1]
            if (d.type == cs.x86.X86_OP_REG
                    and reg_root(ins.reg_name(d.reg)) == "rsp"):
                if s.type == cs.x86.X86_OP_IMM:
                    self.rsp += (-s.imm if mn == "sub" else s.imm)
                    return
                self.rsp_ok = False
                self.slots = {}
                return
            return
        try:
            _r, written = ins.regs_access()
        except Exception:                                   # pragma: no cover
            written = []
        for w in written:
            if reg_root(ins.reg_name(w)) == "rsp":
                self.rsp_ok = False
                self.slots = {}
                return


def _mem_annotation(R, cs, ins, trace, fmap, idx, max_gap):
    """'; Profile.BattlePass@0x118 (rbx <- arg ...)' for one instruction, or
    '' when there is no memory operand worth a word. `?` is printed rather
    than a guess whenever the base register's type is not derivable."""
    for op in ins.operands:
        if op.type != cs.x86.X86_OP_MEM:
            continue
        m = op.mem
        base = reg_root(ins.reg_name(m.base)) if m.base else None
        if m.base and ins.reg_name(m.base) == "rip":
            tgt = ins.address + ins.size + m.disp
            sec = R.section_of_rva(tgt)[0] or "no section"
            return "; rip-> 0x%x [%s]" % (tgt, sec)
        if base in (None, "rsp", "rbp"):
            continue
        if m.index or m.disp <= 0:
            continue
        cands = trace.types_of(base)
        if not cands:
            return "; [%s+0x%x] -> ? (%s's type is not derivable here)" % (
                base, m.disp, base)
        names = []
        for tdi, lbl in cands:
            for n in fmap.at(tdi, m.disp):
                if n not in names:
                    names.append(n)
        if len(names) == 1:
            return "; %s@0x%x  (%s <- %s)" % (names[0], m.disp, base,
                                              cands[0][1])
        if not names:
            return ("; [%s+0x%x] -> ? (no field of %s at that offset)"
                    % (base, m.disp, "/".join(sorted(
                        set(l for _t, l in cands)))))
        return ("; [%s+0x%x] -> AMBIGUOUS: %s" % (base, m.disp,
                                                  " | ".join(names)))
    return ""


def _branch_annotation(R, cs, ins, idx, max_gap):
    """'-> Owner @0xstart +0xoff' for a direct call/jmp, else ''."""
    if ins.mnemonic not in ("call", "jmp") and not ins.mnemonic.startswith("j"):
        return ""
    ops = ins.operands
    if len(ops) != 1 or ops[0].type != cs.x86.X86_OP_IMM:
        return ""
    tgt = ops[0].imm
    if ins.mnemonic.startswith("j") and ins.mnemonic not in ("jmp",):
        return ""                      # conditional: stays inside the body
    sec = R.section_of_rva(tgt)[0]
    if sec is None:
        return "-> 0x%x [not in any section]" % tgt
    s = idx.lookup(tgt, max_gap=max_gap)
    if not s.ok:
        return "-> 0x%x [%s: no IL2CPP owner]" % (tgt, sec)
    off = "" if s.offset == 0 else " +0x%x" % s.offset
    lab = s.owner
    if len(lab) > 96:
        lab = lab[:93] + "..."
    return "-> %s @0x%x%s" % (lab, s.start, off)


def cmd_disasm(R, argv, key=None):
    if not argv:
        print("usage: disasm <RVA-or-VA-or-Type::Method> "
              "[--count N | -n N | --len N | --to RVA] "
              "[--base 0x...] [--max-gap N] [--no-fields]\n"
              "  --count N / -n N / --insns N   N INSTRUCTIONS\n"
              "  --len N   / --length N         N BYTES (default %d)\n"
              "  --to RVA                       decode up to that address"
              % DISASM_DEFAULT_LEN)
        return 2
    length = None
    count = None
    to = None
    base = None
    max_gap = DEFAULT_MAX_GAP
    want_fields = True
    rest = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("--len", "--length") and i + 1 < len(argv):
            length = int(argv[i + 1], 0)
            i += 2
            continue
        if a.startswith("--len="):
            length = int(a.split("=", 1)[1], 0)
            i += 1
            continue
        if a in ("--count", "-n", "--insns") and i + 1 < len(argv):
            count = int(argv[i + 1], 0)
            i += 2
            continue
        if (a.startswith("--count=") or a.startswith("--insns=")
                or a.startswith("-n=")):
            count = int(a.split("=", 1)[1], 0)
            i += 1
            continue
        if a == "--to" and i + 1 < len(argv):
            to = int(argv[i + 1], 0)
            i += 2
            continue
        if a.startswith("--to="):
            to = int(a.split("=", 1)[1], 0)
            i += 1
            continue
        if a == "--base" and i + 1 < len(argv):
            base = int(argv[i + 1], 0)
            i += 2
            continue
        if a.startswith("--base="):
            base = int(a.split("=", 1)[1], 0)
            i += 1
            continue
        if a == "--max-gap" and i + 1 < len(argv):
            max_gap = int(argv[i + 1], 0)
            i += 2
            continue
        if a.startswith("--max-gap="):
            max_gap = int(a.split("=", 1)[1], 0)
            i += 1
            continue
        if a == "--no-fields":
            want_fields = False
            i += 1
            continue
        rest.append(a)
        i += 1
    if not rest:
        print("disasm: no address or Type::Method given")
        return 2
    if len(rest) > 1:
        print("usage error: disasm takes ONE address or Type::Method, but got "
              "%d positional tokens: %s\n"
              "  a stray token is never ignored here: an ignored argument "
              "produced a default window that read as the whole function."
              % (len(rest), " ".join(repr(x) for x in rest)))
        return 2
    given = [n for n, v in (("--len", length), ("--to", to),
                            ("--count", count)) if v is not None]
    if len(given) > 1:
        print("disasm: %s are mutually exclusive; pass one."
              % " and ".join(given))
        return 2

    cs, refusal = import_capstone()
    if cs is None:
        print(refusal)
        return 4

    spec = rest[0]
    named = None
    try:
        addr = int(spec, 0)
    except ValueError:
        rva, msg = resolve_callee_name(R, spec)
        if rva is None:
            print(msg)
            return 3
        named, addr, base = msg, rva, None
    if base is not None:
        rva = addr - base
        if rva < 0:
            print("INCONCLUSIVE: 0x%x is BELOW the --base 0x%x you gave -- "
                  "that address is not in this module." % (addr, base))
            return 3
    elif named is not None:
        rva = addr
    elif addr >= R.IB + 0x10000000:
        print("INCONCLUSIVE: 0x%x looks like a LIVE (ASLR-relocated) address, "
              "not an RVA. GameAssembly.dll is relocated at runtime, so pass "
              "the module base the crash report printed: --base 0x<base>."
              % addr)
        return 3
    else:
        rva = addr - R.IB if addr >= R.IB else addr

    sec, fo, avail = R.section_of_rva(rva)
    print("disasm   0x%x  (VA 0x%x)   section %s"
          % (rva, R.IB + rva, sec or "NONE -- not inside any section"))
    if fo is None:
        print("REFUSED: no raw bytes are mapped at that address, so there is "
              "nothing to decode.")
        return 3

    idx = symbol_index(R, key=key)
    s = idx.lookup(rva, max_gap=max_gap)
    if named:
        print("named    %s" % named)
    print("owner    %s" % s.line())

    # ---- where decoding STARTS. Never mid-instruction-stream guessing.
    start = None
    if s.start is not None and 0 <= rva - s.start <= DISASM_MAX_BACKSCAN:
        start = s.start
    if start is None:
        start = rva
        print("NOTE     no owner start is known for this address, so decoding "
              "begins AT it and NO preceding context is shown -- x86 has no "
              "instruction alignment and decoding backwards from a guessed "
              "boundary produces plausible, WRONG mnemonics.")
    show_from = rva if start == rva else max(start, rva - DISASM_CONTEXT)
    if to is not None:
        end = (to - base) if base is not None else (
            to - R.IB if to >= R.IB else to)
        if end <= rva:
            print("disasm: --to 0x%x is not above the start address 0x%x."
                  % (end, rva))
            return 2
    elif count is not None:
        # 15 bytes is the x86-64 maximum instruction length, so this cannot
        # cut the requested instruction count short; the count itself stops it.
        end = rva + 15 * count + 16
    else:
        end = rva + (DISASM_DEFAULT_LEN if length is None else length)
    if count is not None:
        window_req = "%d instructions (--count)" % count
    elif to is not None:
        window_req = "up to 0x%x (--to)" % end
    elif length is not None:
        window_req = "%d bytes (--len)" % length
    else:
        window_req = "%d bytes (DEFAULT -- no window flag given)" % \
            DISASM_DEFAULT_LEN

    # ---- argument registers, for the field annotation
    fmap = FieldAtOffset(R)
    cand, disp, caveats = {}, [], []
    if want_fields and s.start is not None:
        entries = idx.owners.get(s.start, [])
        mentries = [e for e in entries if e[0] == "m"]
        if len(mentries) == 1 and len(entries) == 1:
            try:
                cand, disp, caveats = arg_register_map(R, mentries[0][1],
                                                       mentries[0][2])
            except Exception as e:                          # pragma: no cover
                caveats = ["argument mapping FAILED (%s); every [reg+disp] "
                           "below reads `?`" % e]
        elif entries:
            caveats = ["%d method definitions share this body, so an argument "
                       "register has no single type -- every [reg+disp] below "
                       "reads `?`" % len(entries)]
    if disp:
        print("args     %s" % "  ".join(disp))
    for c in caveats:
        print("CAVEAT   %s" % c)
    if start != rva:
        print("decoding from the owner start 0x%x (exact instruction "
              "boundaries); showing from 0x%x" % (start, show_from))

    nbytes = (end - start) + 16
    blob = R.code_bytes(start, nbytes)
    if not blob:
        print("REFUSED: no raw bytes at 0x%x." % start)
        return 3
    md = cs.Cs(cs.CS_ARCH_X86, cs.CS_MODE_64)
    md.detail = True
    trace = RegTrace(cand)
    print("window   requested %s" % window_req)
    print("%-2s %-10s %-22s %s" % ("", "RVA", "BYTES", "INSTRUCTION"))
    printed = 0
    hit = False
    decoded_to = start
    first_printed = None
    truncated = False
    last_mnemonic = ""
    for ins in md.disasm(bytes(blob), start):
        if ins.address >= end:
            truncated = True
            break
        if count is not None and printed >= count:
            truncated = True
            break
        decoded_to = ins.address + ins.size
        marker = "  "
        inside = 0
        if ins.address <= rva < ins.address + ins.size:
            marker = ">>"
            hit = True
            inside = rva - ins.address
        note = ""
        if ins.address >= show_from:
            note = _branch_annotation(R, cs, ins, idx, max_gap)
            if not note and want_fields:
                note = _mem_annotation(R, cs, ins, trace, fmap, idx, max_gap)
        trace.step(cs, ins)
        if ins.address < show_from:
            continue
        printed += 1
        if first_printed is None:
            first_printed = ins.address
        last_mnemonic = ins.mnemonic
        print("%-2s 0x%-8x %-22s %s %s%s"
              % (marker, ins.address, ins.bytes.hex(), ins.mnemonic,
                 ins.op_str, ("   " + note) if note else ""))
        if inside:
            # The requested address is not an instruction boundary. Saying so
            # matters: a fault reported at +0x11f2 that is really 3 bytes into
            # one instruction is a different fact from a fault at its start.
            print("   ^^ requested 0x%x is INSIDE this instruction, at byte "
                  "+%d of %d -- it is NOT an instruction boundary."
                  % (rva, inside, ins.size))
    if not printed:
        print("REFUSED: capstone decoded NOTHING in this range -- these bytes "
              "are not valid x86-64 at this boundary. This is not an empty "
              "function.")
        return 3
    print("window   %d instructions / %d bytes decoded, 0x%x..0x%x   "
          "limit reached: %s"
          % (printed, decoded_to - (first_printed if first_printed is not None
                                    else decoded_to),
             first_printed if first_printed is not None else decoded_to,
             decoded_to, "YES" if truncated else "no"))
    if truncated:
        print("         TRUNCATED -- this window ENDED AT THE LIMIT, not at "
              "the end of the function. Do NOT read the last instruction as "
              "the last instruction of the body. Re-run with a bigger "
              "--count N / --len N, or --to <RVA>.")
    elif last_mnemonic in ("ret", "jmp", "int3", "ud2"):
        print("         complete within the requested window; it ends on "
              "`%s`, which MAY be the end of the body (a tail `jmp` or a "
              "mid-body `ret` is not proof)." % last_mnemonic)
    else:
        print("         the decoder stopped before the limit (capstone could "
              "not decode the next bytes) -- this is NOT proof the body ends "
              "here.")
    if not hit:
        print("NOTE     0x%x itself was NOT reached: the decode stopped at "
              "0x%x. It is INSIDE no instruction printed above."
              % (rva, decoded_to))
        return 3
    return 0


def usage_gaps():
    """VERBS that the Usage: block does not document, and documented verbs that
    do not exist. MEASURED: `methods`, `shared`, `enum`, `settings-table` and
    the whole verify-* family were live and heavily used while absent from the
    usage text; one agent was told to use a `member --argc` that the docs never
    mentioned and hand-filtered arity against Resolver internals instead. Stale
    usage text is a confidently wrong answer about the tool itself, so it is
    now CHECKED rather than maintained by hope."""
    usage = __doc__.split("Usage:", 1)[1] if "Usage:" in __doc__ else ""
    undocumented = [v for v in VERBS
                    if ("> " + v + " ") not in usage
                    and ("> " + v + "\n") not in usage]
    return undocumented


def main():
    gaps = usage_gaps()
    if gaps:
        sys.stderr.write("WARNING: these verbs exist but are NOT in the "
                         "Usage: block: %s\n" % ", ".join(gaps))
    # The VERB-in-argv[1] check runs BEFORE the arity check. It used to run
    # after, so `il2cpp_resolve.py member get_Position` (3 args) fell through
    # to `sys.exit(__doc__)` and dumped ~200 lines of module docstring -- in
    # which the one-line answer ("argv[1] must be GameAssembly.dll") is buried.
    # A refusal nobody reads is a refusal that does not work.
    if len(sys.argv) > 1 and sys.argv[1] in VERBS:
        sys.exit(
            "usage error: %r is a VERB, but argv[1] must be the path to "
            "GameAssembly.dll.\n"
            "  every verb is:  il2cpp_resolve.py GAMEASM METADEC %s ...\n"
            "  you ran:        il2cpp_resolve.py %s\n"
            "  e.g.  python tools/il2cpp_resolve.py D:/Games/Tarkov/"
            "GameAssembly.dll .cache/global-metadata.dec.dat %s\n"
            % (sys.argv[1], sys.argv[1], " ".join(sys.argv[1:]),
               " ".join(sys.argv[1:])))
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    # EVERY verb takes GAMEASM and METADEC FIRST. Agents read CLAUDE.md 5's
    # shorthand ("`bytes <RVA>`") as the whole command line, ran
    # `il2cpp_resolve.py bytes 0x52a8a80 8`, and got a raw FileNotFoundError
    # traceback out of Resolver -- one hand-rolled a PE section walker rather
    # than work out that argv[1] was being opened as GameAssembly.dll. Say it.
    for p in (sys.argv[1], sys.argv[2]):
        if not os.path.exists(p):
            sys.exit("usage error: %r does not exist. argv[1] must be "
                     "GameAssembly.dll and argv[2] the DECRYPTED "
                     "global-metadata (see tools/metablob.py; the encrypted "
                     "file on disk will NOT parse)." % p)
    cmd = sys.argv[3]
    if cmd not in VERBS:
        sys.exit("usage error: unknown verb %r. Known verbs: %s"
                 % (cmd, ", ".join(VERBS)))
    missing_reg = [v for v in VERBS if v not in VERB_FLAGS]
    if missing_reg:
        sys.stderr.write("WARNING: these verbs have no VERB_FLAGS entry, so "
                         "their flags are NOT checked: %s\n"
                         % ", ".join(missing_reg))
    # Refuse unknown flags BEFORE loading the metadata: an ignored flag is a
    # wrong answer, and this one costs nothing to catch.
    bad = unknown_flags(cmd, sys.argv[4:])
    if bad:
        accepted = VERB_FLAGS.get(cmd) or ()
        sys.exit(
            "usage error: `%s` does not accept %s.\n"
            "  you ran:   %s\n"
            "  `%s` accepts: %s\n"
            "  NOTHING was disassembled/searched. An unknown flag is REFUSED "
            "rather than ignored, because an ignored window flag makes a "
            "DEFAULT-sized result read as a complete one."
            % (cmd, ", ".join(repr(b) for b in bad),
               " ".join([os.path.basename(sys.argv[0])] + sys.argv[1:]),
               cmd, ", ".join(accepted) if accepted
               else "no flags at all (positional arguments only)"))
    R = Resolver(sys.argv[1], sys.argv[2])
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
                print("  ... member %s           # search by MEMBER name "
                      "(+ arity, signature, sharedness)" % (meth or "<name>"))
                print("  ... type %s             # every method on that type"
                      % (ty or "<Type>"))
                sys.exit(1)
            print("NO TYPE NAME CONTAINS %r (searched all %d types "
                  "EXHAUSTIVELY). This is a genuine zero-hit answer, not an "
                  "error." % (needle, R.NTYPES))
            sys.exit(1)
        print("-- %d type name(s) contain %r (searched all %d EXHAUSTIVELY)"
              % (n, needle, R.NTYPES))
    elif cmd == "member":
        if len(sys.argv) < 5:
            sys.exit("usage error: `member` needs a member name.\n"
                     "  il2cpp_resolve.py GAMEASM METADEC member <name> "
                     "[--argc N] [--limit=N] [--exact]")
        sys.exit(cmd_member(R, sys.argv[4:]))
    elif cmd == "holdersof":
        sys.exit(cmd_holdersof(R, sys.argv[4:]))
    elif cmd == "methods":
        # `find` searches TYPE names only; this searches METHOD names, which is
        # what you want when you know a call site's name (LocalRaidEnded) but
        # not its declaring type, and it prints the full signature + RVA +
        # sharedness so the answer is directly actionable.
        raw_needle = sys.argv[4]
        forced_name = "--name" in sys.argv[4:]
        if forced_name:
            rest_n = [a for a in sys.argv[4:] if not a.startswith("--")]
            if not rest_n:
                sys.exit("usage error: --name needs a member name after it.")
            raw_needle = rest_n[0]
        else:
            refuse_numeric_needle("methods", raw_needle)
        needle = raw_needle.lower()
        want_shared = "--shared" in sys.argv[5:]
        argc = parse_argc(sys.argv[5:])
        arity_rejected = 0
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
                if argc is not None:
                    try:
                        _pc = R.method_sig(mi)[2]
                    except Exception:
                        _pc = -1
                    if _pc != argc:
                        # Counted, never hidden: "it exists, but only at an
                        # arity you never call" is itself the answer.
                        arity_rejected += 1
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
                print("      attrs=%s" % decode_mattrs(R.mflags(mi)))
                if rva is None:
                    continue
                note = R.annotate_rva(rva)
                if want_shared:
                    sn = R.sharedness_note(rva)
                    if sn:
                        note += "  " + sn
                if note.strip():
                    print("      " + note.strip())
        if hits == 0:
            if argc is not None and arity_rejected:
                print("NO METHOD NAMED %r EXISTS AT ARITY %d (searched all %d "
                      "types EXHAUSTIVELY)." % (raw_needle, argc, R.NTYPES))
                print("It DOES exist at %d other aritie(s). Re-run without "
                      "--argc to see them." % arity_rejected)
            else:
                print("no METHOD NAME contains %r (searched the method "
                      "names of all %d types EXHAUSTIVELY)"
                      % (raw_needle, R.NTYPES))
                print("NOTE: `methods` matches METHOD NAMES ONLY. This is NOT "
                      "a statement about a TYPE -- if %r names a type, this "
                      "zero-hit says nothing about whether it has methods."
                      % raw_needle)
                if "." in raw_needle:
                    print("      For every method DECLARED BY a type, use:")
                    print("        ... typemethods %s" % raw_needle)
        elif argc is not None and arity_rejected:
            print("-- %d hit(s) at arity %d; %d more rejected by --argc"
                  % (hits, argc, arity_rejected))
    elif cmd == "symbolize":
        sys.exit(cmd_symbolize(R, sys.argv[4:],
                               key=(sys.argv[1], sys.argv[2])))
    elif cmd == "symbolize-report":
        sys.exit(cmd_symbolize_report(R, sys.argv[4:],
                                      key=(sys.argv[1], sys.argv[2])))
    elif cmd == "callers":
        sys.exit(cmd_callers(R, sys.argv[4:], key=(sys.argv[1], sys.argv[2])))
    elif cmd == "disasm":
        sys.exit(cmd_disasm(R, sys.argv[4:], key=(sys.argv[1], sys.argv[2])))
    elif cmd == "typemethods":
        sys.exit(cmd_typemethods(R, sys.argv[4:]))
    elif cmd == "genericmethods":
        sys.exit(cmd_genericmethods(R, sys.argv[4:]))
    elif cmd == "verify-generics":
        ok, rows = self_check_generics(R)
        for label, verdict in rows:
            print("   %-46s %s" % (label, verdict))
        print("GENERIC-METHOD SELF-CHECK PASSED" if ok
              else "GENERIC-METHOD SELF-CHECK FAILED")
        if not ok:
            sys.exit(1)
    elif cmd == "verify-parents":
        ok, rows = self_check_parents(R)
        for tyname, anc, verdict in rows:
            print("   %-34s derives from %-16s %s" % (tyname, anc, verdict))
        print("PARENT-CHAIN SELF-CHECK PASSED" if ok
              else "PARENT-CHAIN SELF-CHECK FAILED -- base-class answers from "
                   "this build are NOT trustworthy")
        if not ok:
            sys.exit(1)
    elif cmd == "type":
        args = [a for a in sys.argv[4:] if not a.startswith("--")]
        want_shared = "--shared" in sys.argv[4:]
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
                if want_shared:
                    # NOTE: this counts METHOD DEFINITIONS. il2cpp_nameindex.py
                    # counts index KEYS, which is slightly lower because it has
                    # already dropped the name-ambiguous ones. Neither is wrong;
                    # they answer marginally different questions.
                    sn = R.sharedness_note(rva)
                    if sn:
                        note += "  " + sn
                if note.strip():
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
    elif cmd == "shared":
        # The verb an agent actually wants before detouring: one address in,
        # a tri-state verdict out. Same Resolver.sharedness the library and
        # `type --shared` / `methods --shared` use -- there is no second path.
        addr = int(sys.argv[4], 0)
        state, n = R.sharedness(addr)
        rva = addr - R.IB if addr > R.IB else addr
        print("RVA 0x%X   sharedness=%s   owners=%d" % (rva, state.upper(), n))
        note = R.sharedness_note(addr)
        if note:
            print("  " + note)
        if state == "shared":
            print("  DO NOT DETOUR by name: the write fires for all %d." % n)
        elif state == "unique":
            print("  exactly one method definition resolves here.")
        sys.exit(0 if state == "unique" else 1)
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
