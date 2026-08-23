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

## TYPE KEYS: the same index also answers "what is this Il2CppClass?"

A second key family lives in the same file, under a suffix no real method can
have:

    "Ns.Type::@type/0"   -> the RVA of the STATIC `Il2CppType` for that type

Two things need it.

  * `components <go>` must hand `UnityEngine.Component` to
    `GameObject::GetComponents(Type)`. A `System.Type` is obtained by calling
    `System.Type::GetTypeFromHandle(RuntimeTypeHandle)` -- a one-field struct
    whose value IS the `Il2CppType*` -- so a static VA is the whole input. No
    reflection, no `il2cpp_class_from_il2cpp_type`.
  * naming a component. `Il2CppClass.name`/`.namespaze` are read raw (see
    `abi/aowlspt_components.h` for how those two offsets were MEASURED out of
    the export table). A name read out of live memory is only trusted if it is
    PRESENT in this index; anything else prints as UNVERIFIED. That is what
    stops a wrong struct offset from inventing a plausible type name.

`@` cannot occur in a metadata method name, and generation ASSERTS that over
the whole method-name set rather than assuming it, so the two families cannot
collide. Types with two different static `Il2CppType` entries are resolved by
preferring `attrs == 0`; where that is still ambiguous the key is dropped, the
same policy as methods.

## Ambiguous keys are DROPPED, not resolved

Distinct metadata types can produce the same "Ns.Type::Method" string --
compiler-generated closure types (`<>c`), nested types that carry no namespace,
and so on. If one key maps to two DIFFERENT RVAs there is no correct answer, so
the key is removed from the index entirely and lookup reports "not found".
A refusal is recoverable; a wrong-but-mapped address is the corruption the whole
safety discipline exists to prevent. Duplicates that agree on the RVA collapse
harmlessly and are kept.

## SHARED RVAs: the inverse ambiguity, and the more dangerous one

Dropping "one name -> two RVAs" (above) is only half the problem. The other half
is **many names -> ONE RVA**, and the index used to say nothing about it.

The IL2CPP backend folds identical compiled bodies, so unrelated methods in
DIFFERENT images share an address. Measured on this build:
`Diz.Resources.EasyAssets::get_System` and `BundlesManager::get_DownloadingUrl`
BOTH resolve to 0x692A50 (`48 8B 41 28 C3` -- `mov rax,[rcx+0x28]; ret`), one
of 338 method keys on that single address. 0x628110 -- recorded elsewhere as "ForceMeshUpdate, a stripped
stub" -- is shared by 6438 methods: it is not ForceMeshUpdate's address at all,
it is this build's universal `ret 0`.

That address is technically CORRECT and catastrophic as a patch target: a detour
there fires for every one of those call sites. This is exactly the
confidently-wrong answer the ambiguity rule above exists to prevent, arriving
from the other direction.

So generation computes the RVA -> key-count distribution and writes it beside
the index as `<out>.shared` (see `shared_sidecar`), and `lookup` prints

    [SHARED: N methods resolve here -- hooking this fires for all of them]

Sharedness is IN THE INDEX, as of format version 2: a `u16 shareCount` per
entry, in a fourth parallel array. It used to live only in the sidecar, on the
argument that a format bump touched a file that change did not own -- and the
result was the actual bug: `gen` wrote a sidecar, nothing deployed it, and the
host had no sharedness data at all while by-name patching was live.

A sidecar can go missing independently of the index. A field cannot. One file,
one stamp, one staleness story: the host already refuses the WHOLE index on a
stamp mismatch, and a version-1 index -- which cannot answer "is this shared?"
-- is now refused by the same door rather than loaded and silently treated as
all-unshared. That is the property that matters, and it is why this is a field
and not a companion file.

The sidecar is still written, demoted to a HUMAN REPORT: it holds the NAMES of
the other methods on a shared RVA, which the index cannot (it stores hashes).
`lookup` refuses on the index field and consults the sidecar only to say who
else is there, so a missing sidecar degrades the explanation and never the
refusal.

shareCount semantics, identical here and in `abi/aowlspt_nameindex.h`:

    0    sharedness UNKNOWN -- not a code key, or not counted. NEVER read as
         "unshared". A patch target with 0 is REFUSED.
    1    this RVA is reached by this method only.
    >=2  this many method keys resolve here; saturates at 65535.

The policy the host implements: refuse a shared RVA for any PATCH target unless
explicitly overridden, allow it for a direct CALL. A call at a folded getter is
still the right code for the receiver you pass it; a detour there is a write
whose blast radius is every other method that folded onto it, and the host
cannot tell them apart at runtime.

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
  il2cpp_nameindex.py lookup <out.idx> <Ns.Type::Method> [arity] [--refuse-shared]
  il2cpp_nameindex.py shared <GameAssembly.dll> <global-metadata.dec.dat> [topN]
        # the RVA -> key-count distribution and the worst offenders
  il2cpp_nameindex.py type   <out.idx> <Ns.Type>
  il2cpp_nameindex.py typename <out.idx> <Ns.Type>

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
VERSION = 2
HEADER = 40  # magic8 ver4 count4 imageKey8 fileHash8 flags4 pad4
# v2 entry: u64 hash + u32 rva + u32 check + u16 shareCount, as four parallel
# arrays. The share count is IN the index, not in a companion file, so there is
# exactly ONE stamp and ONE staleness story -- see `write_shared_sidecar`.
ENTRY = 18
# shareCount semantics, and the host reads them identically:
#   0  -- NOT A CODE KEY, or not counted: sharedness UNKNOWN. Never "unshared".
#   1  -- this RVA is reached by this method only.
#  >=2 -- this many method keys resolve to this RVA. Saturates at 65535.
SHARE_UNKNOWN = 0
SHARE_MAX = 0xFFFF

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
    R._ensure_fields()          # MREG / TYPES_PTR, for the type-key family
    PC_OFF = 34  # parameterCount, u16 -- confirmed against both LoadAsset overloads
    exact = {}
    exact_bad = set()
    by_name = {}   # "Ns.Type::Method" -> set of (arity, rva)
    seen_method_names = set()
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
            seen_method_names.add(mname)
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

    tstats = add_type_keys(R, exact, seen_method_names)
    stats = dict(types=ntypes, methods=nmeth, unmapped=nomap,
                 dropped=len(exact_bad), star=star, names=len(by_name),
                 keys=len(exact))
    stats.update(tstats)
    return exact, stats


TYPE_SUFFIX = "::@type"
NAME_SUFFIX = "::@name"

# Il2CppTypeEnum values whose `data` field is a TYPEDEF INDEX, and which
# therefore name a type we can key on: valuetype (0x11) and class (0x12), plus
# the builtin scalars, which get their own enum rather than 0x12. That every
# builtin enum here resolves to exactly one typedef (System.String for 0x0E,
# System.Object for 0x1C, ...) was checked against this DLL, not assumed.
# Deliberately EXCLUDED: szarray/ptr/genericinst/var/mvar, whose `data` is a
# pointer or an element type, not a typedef index.
TYPE_ENUMS_WITH_TYPEDEF = frozenset((
    0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D,
    0x0E, 0x11, 0x12, 0x16, 0x18, 0x19, 0x1C))


def add_type_keys(R, exact, method_names):
    """Add `Ns.Type::@type/0` -> static Il2CppType RVA for every typedef.

    THE COLLISION GUARD IS CHECKED, NOT ASSUMED. `@` is not a legal C# method
    identifier character and the compiler-generated forms use `<>`, `$`, `|`
    and `.` -- but "should not occur" is exactly the class of claim this
    project keeps being burned by, so the whole method-name set is scanned and
    generation REFUSES if any name contains the suffix.
    """
    for mn in method_names:
        if "@type" in mn:
            raise SystemExit(
                "REFUSING TO EMIT: a metadata method name contains '@type' "
                "(%r), so the type-key family would collide with the method "
                "family. Change TYPE_SUFFIX and regenerate." % mn)

    ntypes_reg = struct.unpack_from("<I", R.b, R.v2f(R.MREG + 0x30))[0]
    # typedef index -> {attrs: rva}. Several static Il2CppType entries can
    # describe the same typedef, differing only in attribute bits.
    cand = {}
    scanned = 0
    for i in range(ntypes_reg):
        tva = R.rq(R.TYPES_PTR + i * 8)
        if not tva:
            continue
        fo = R.v2f(tva)
        if fo is None:
            continue
        data = struct.unpack_from("<Q", R.b, fo)[0]
        bits = struct.unpack_from("<I", R.b, fo + 8)[0]
        te = (bits >> 16) & 0xFF
        if te not in TYPE_ENUMS_WITH_TYPEDEF:
            continue
        # THE BITFIELD BYTE, MEASURED not recalled. Byte 11 of Il2CppType is
        # `num_mods:5, byref:1, pinned:1, valuetype:1`. Pinned to this DLL by
        # dumping every descriptor for four types: 0x80 appears on
        # System.Int32 and UnityEngine.Vector3 and NEVER on
        # UnityEngine.Component or Transform, so 0x80 is valuetype; 0x20
        # appears on all four equally and never combined with 0x80, which is
        # byref (a `ref Vector3` is a pointer, so its valuetype bit is clear).
        # An earlier draft of this filter tested `(bits >> 24) & 3` -- the
        # num_mods bits -- and so would have accepted BYREF descriptors as
        # `typeof(T)`. That is why the byte is documented here.
        bf = (bits >> 24) & 0xFF
        if bf & 0x7F:            # byref, pinned, or carrying custom modifiers
            continue
        if data >= R.NTYPES:
            continue
        rva = tva - R.IB
        if not (0 < rva < (1 << 32)):
            continue
        scanned += 1
        cand.setdefault(data, {}).setdefault(bits & 0xFFFF, set()).add(rva)

    # THE MEMBERSHIP FAMILY, separate on purpose.
    #
    #     "Ns.Type::@name/0" -> 1
    #
    # `@type` answers "give me the address of this type's descriptor" and is
    # conservative: an ambiguous name gets no entry, because a wrong address
    # is a wrong call. `@name` answers a strictly weaker question -- "is this
    # a real type name on this build" -- and ambiguity does not apply to it,
    # so every typedef gets one. That is what the host validates a klass name
    # against, so a name read out of live memory is checkable even for the
    # ~9% of types whose descriptor address is ambiguous. Value 1 is a
    # presence token, never an address.
    namekeys = 0
    for t in range(R.NTYPES):
        ns, nm = R.tname(t)
        full = (ns + "." + nm) if ns else nm
        k = full + NAME_SUFFIX + "/0"
        if k not in exact:
            exact[k] = 1
            namekeys += 1

    added = dropped = dupe_collapsed = 0
    for t in range(R.NTYPES):
        by_attr = cand.get(t)
        if not by_attr:
            continue
        # prefer the plain, unattributed entry -- that is what `typeof(T)`
        # compiles to; only fall back when there is exactly one alternative.
        pick = by_attr.get(0)
        if pick is None:
            if len(by_attr) != 1:
                dropped += 1
                continue
            pick = next(iter(by_attr.values()))
        if len(pick) != 1:
            # Several ADDRESSES for one (typedef, attrs). These are duplicate
            # descriptors emitted by different translation units, not rival
            # answers -- `System.String` has dozens. Duplication is not
            # ambiguity, but that has to be PROVEN, not asserted: require the
            # 16 descriptor bytes to be identical at every address, then take
            # the lowest so the choice is deterministic across runs. If they
            # differ they really are rival answers and the key is dropped.
            addrs = sorted(pick)
            ref = R.b[R.v2f(R.IB + addrs[0]):R.v2f(R.IB + addrs[0]) + 16]
            same = all(R.b[R.v2f(R.IB + a):R.v2f(R.IB + a) + 16] == ref
                       for a in addrs[1:])
            if not same:
                dropped += 1
                continue
            pick = {addrs[0]}
            dupe_collapsed += 1
        ns, nm = R.tname(t)
        full = (ns + "." + nm) if ns else nm
        key = full + TYPE_SUFFIX + "/0"
        rva = next(iter(pick))
        prev = exact.get(key)
        if prev is not None and prev != rva:
            exact.pop(key, None)   # ambiguous type NAME: same policy as methods
            dropped += 1
            continue
        exact[key] = rva
        added += 1
    return dict(typekeys=added, typedropped=dropped, typeentries=scanned,
                typedupes=dupe_collapsed, namekeys=namekeys)
SHARED_MAGIC = "AOWLSHARED1"


def is_method_key(k):
    """True for a real method key -- NOT a `/*` alias, NOT a type-family key.

    THIS PREDICATE IS THE WHOLE MERGE. Sharedness is a statement about CODE
    addresses, and two other key families now live in this same index:

      * `Ns.Type::@name/0` -> 1. That 1 is a presence TOKEN, not an address.
        Counting it would report a single "RVA 0x1" shared by all ~26k type
        names -- the largest and most confident wrong answer this tool could
        produce, and it would sit at the top of `worst offenders`.
      * `Ns.Type::@type/0` -> a static `Il2CppType` RVA in `.data`. Nobody
        detours `.data`, and duplicate descriptor addresses are not folded
        code; counting them would inflate the measured 28.3% with non-code.

    Both families are excluded BY NAME, not by hoping their values fail to
    alias a code RVA. `/*` aliases are excluded because they are the same
    method as their `/N` key and would double-count it.
    """
    return not (k.endswith("/*") or TYPE_SUFFIX + "/" in k
                or NAME_SUFFIX + "/" in k)


def shared_map(keys):
    """{rva: [key, ...]} for every RVA reached by MORE THAN ONE method key."""
    by_rva = {}
    for k, rva in keys.items():
        if not is_method_key(k):
            continue
        by_rva.setdefault(rva, []).append(k)
    return {r: sorted(v) for r, v in by_rva.items() if len(v) > 1}, len(by_rva)


def share_counts(keys):
    """key -> how many METHOD keys resolve to that key's RVA.

    0 means "not a code key, so sharedness is UNKNOWN" -- the `@type`/`@name`
    families, whose values are a `.data` descriptor address and a presence
    token, neither of which anybody detours. It is deliberately the same value
    the host treats as UNKNOWN, so a non-code key can never read as unshared.

    `/*` aliases are not COUNTED (they would double-count their own `/N` key,
    which is what `is_method_key` exists to prevent) but they do CARRY the
    count, because a by-name patch at arity -1 resolves through exactly that
    alias and has to be refused for exactly the same reason.
    """
    by_rva = {}
    for k, rva in keys.items():
        if is_method_key(k):
            by_rva[rva] = by_rva.get(rva, 0) + 1
    out = {}
    for k, rva in keys.items():
        if is_method_key(k) or k.endswith("/*"):
            out[k] = min(by_rva.get(rva, SHARE_UNKNOWN), SHARE_MAX)
        else:
            out[k] = SHARE_UNKNOWN
    return out


def shared_sidecar_path(idx_path):
    return idx_path + ".shared"


def write_shared_sidecar(path, shared, image_key, fhash, sample=8):
    """Text, one RVA per line: `0xRVA <count> <up to `sample` key names>`.

    NOT the host's source of truth any more, and not the host's input at all.
    Since index version 2 the share count is a field ON THE ENTRY, so there is
    one file, one stamp and one staleness story; the host never has to decide
    what to believe when two stamped files disagree, because there is only one.

    What this file still adds is the thing the index deliberately cannot hold:
    the NAMES of the other methods on a shared RVA (the index stores hashes).
    That is a report for a human deciding whether a detour is acceptable, and
    `lookup` prints it -- but the REFUSAL is driven by the index field, so a
    missing sidecar downgrades the explanation, never the safety.
    """
    with open(path, "w", encoding="utf8") as f:
        # THE SAME STAMP THE .idx CARRIES. A second file is a second
        # staleness story unless it is pinned to the first; it is pinned
        # here, and `lookup` treats a mismatch as "sharedness UNKNOWN"
        # rather than answering out of a sidecar that no longer belongs
        # to this DLL.
        f.write("%s %d %016x %016x\n"
                % (SHARED_MAGIC, len(shared), image_key, fhash))
        for rva in sorted(shared, key=lambda r: (-len(shared[r]), r)):
            ks = shared[rva]
            f.write("0x%X %d %s\n" % (rva, len(ks), " ".join(ks[:sample])))


def read_shared_sidecar(path, image_key=None, fhash=None):
    """{rva: (count, [sample keys])}, or None when absent OR STALE."""
    try:
        f = open(path, encoding="utf8")
    except OSError:
        return None
    with f:
        first = f.readline().split()
        if not first or first[0] != SHARED_MAGIC:
            return None
        if image_key is not None:
            if len(first) < 4:
                return None    # unstamped sidecar from an older gen
            if (int(first[2], 16), int(first[3], 16)) != (image_key, fhash):
                return None    # STALE: belongs to a different DLL
        out = {}
        for line in f:
            parts = line.split()
            if len(parts) < 2:
                continue
            out[int(parts[0], 16)] = (int(parts[1]), parts[2:])
        return out


def report_shared(shared, distinct, keys, top=10):
    hist = {}
    for v in shared.values():
        hist[len(v)] = hist.get(len(v), 0) + 1
    on_shared = sum(len(v) for v in shared.values())
    exact = sum(1 for k in keys if is_method_key(k))
    print("SHARED RVAs (one address, many methods -- the inverse of the "
          "ambiguity that gets dropped):")
    print("  distinct RVAs            %d" % distinct)
    print("  RVAs reached by >1 key   %d (%.1f%%)"
          % (len(shared), 100.0 * len(shared) / max(distinct, 1)))
    print("  exact keys on a shared RVA %d of %d (%.1f%%)"
          % (on_shared, exact, 100.0 * on_shared / max(exact, 1)))
    print("  keys-per-shared-RVA histogram (count: how many RVAs):")
    print("     " + "  ".join("%d:%d" % kv for kv in sorted(hist.items())[:10])
          + ("  ... max %d" % max(hist)))
    print("  worst offenders:")
    for rva in sorted(shared, key=lambda r: -len(shared[r]))[:top]:
        ks = shared[rva]
        print("     0x%-9X %5d methods   e.g. %s" % (rva, len(ks),
                                                     ", ".join(ks[:2])))


def pack(keys, image_key, fhash):
    """Sort by primary hash, refuse on ANY primary collision, emit SoA."""
    shares = share_counts(keys)
    rows = []
    for k, rva in keys.items():
        kb = k.encode("utf8")
        rows.append((h_primary(kb), h_check(kb), rva, k, shares[k]))
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
    out += b"".join(struct.pack("<H", r[4]) for r in rows)
    assert len(out) == HEADER + n * ENTRY
    return bytes(out)


def read_index(path):
    b = open(path, "rb").read()
    if len(b) < HEADER or b[:8] != MAGIC:
        sys.exit("not an aowlspt name index: " + path)
    ver, n = struct.unpack_from("<II", b, 8)
    ikey, fhash = struct.unpack_from("<QQ", b, 16)
    want = HEADER + n * ENTRY
    if ver != VERSION:
        sys.exit("index version %d, this tool speaks %d. Version %d carries a "
                 "per-entry share count and version 1 does NOT -- an old index "
                 "cannot answer 'is this RVA shared?', and answering it from "
                 "silence would read as 'unshared'. Regenerate with `gen`."
                 % (ver, VERSION, VERSION))
    if len(b) != want:
        sys.exit("index truncated: %d bytes, header claims %d entries (%d)"
                 % (len(b), n, want))
    return b, n, ikey, fhash


def idx_lookup(b, n, key):
    """The RVA, or None. `idx_lookup_full` also returns the share count."""
    r = idx_lookup_full(b, n, key)
    return None if r is None else r[0]


def idx_lookup_full(b, n, key):
    """(rva, shareCount) or None. shareCount 0 == UNKNOWN, never 'unshared'."""
    hs = HEADER
    rs = hs + n * 8
    cs = rs + n * 4
    ss = cs + n * 4
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
            return (struct.unpack_from("<I", b, rs + mid * 4)[0],
                    struct.unpack_from("<H", b, ss + mid * 2)[0])
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


# -- the type-key cross-check. There is no independently published table of
#    `Il2CppType` addresses to compare against, so the invariant checked is the
#    ROUND TRIP: take the RVA the index serves for a name, read the
#    `Il2CppType` at it out of the DLL, follow `data` back to a typedef, and
#    require the typedef's name to be the name we asked for. A wrong or stale
#    address does not round-trip. It also asserts the entry sits in `.data`
#    (never in code) and is 8-aligned.
TYPE_KNOWN = ["UnityEngine.Component", "UnityEngine.MonoBehaviour",
              "UnityEngine.RectTransform", "UnityEngine.UI.Toggle",
              "TMPro.TMP_Text", "System.String", "EFT.TarkovApplication"]


def type_round_trip(R, get, label):
    print("%-40s %-12s %s" % ("TYPE KEY", "Il2CppType", "ROUND TRIP"))
    ok = True
    names = {}
    for t in range(R.NTYPES):
        ns, nm = R.tname(t)
        names[(ns + "." + nm) if ns else nm] = t
    for full in TYPE_KNOWN:
        rva = get(full + TYPE_SUFFIX)
        why = ""
        good = False
        if not rva:
            why = "NOT IN INDEX"
        elif rva & 7:
            why = "not 8-aligned"
        else:
            sec = None
            for sn, vs, vz, raw, rz in R.SEC:
                if vs <= rva < vs + vz:
                    sec = sn
                    break
            fo = R.v2f(R.IB + rva)
            if sec != ".data":
                why = "lives in %s, not .data" % sec
            elif fo is None:
                why = "no file mapping"
            else:
                data = struct.unpack_from("<Q", R.b, fo)[0]
                back = None
                if data < R.NTYPES:
                    ns, nm = R.tname(data)
                    back = (ns + "." + nm) if ns else nm
                good = (back == full)
                why = "-> %s" % back
        ok = ok and good
        print("%-40s 0x%-10s %s %s"
              % (full, ("%X" % rva) if rva else "-", why, "OK" if good else "MISMATCH"))
    print(("ALL %d TYPE KEYS ROUND-TRIPPED (%s)" % (len(TYPE_KNOWN), label))
          if ok else ("TYPE ROUND TRIP FAILED (%s)" % label))
    return ok


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
              % (out, (len(blob) - HEADER) // ENTRY, len(blob),
                 len(blob) / 1048576.0))
        print("TYPE KEYS (Ns.Type::@type/0 -> static Il2CppType RVA): %d "
              "added, %d dropped as ambiguous, from %d class/valuetype "
              "Il2CppType entries (%d names had duplicate but "
              "BYTE-IDENTICAL descriptors and were collapsed, not dropped)"
              % (st["typekeys"], st["typedropped"], st["typeentries"],
                 st["typedupes"]))
        print("TYPE-NAME MEMBERSHIP KEYS (Ns.Type::@name/0 -> 1, what a klass "
              "name read from live memory is validated against): %d"
              % st["namekeys"])
        shared, distinct = shared_map(keys)
        side = shared_sidecar_path(out)
        write_shared_sidecar(side, shared, ikey, fhash)
        print("wrote %s: %d shared RVAs" % (side, len(shared)))
        report_shared(shared, distinct, keys)
        b, n, _, _ = read_index(out)
        g = lambda k: idx_lookup(b, n, k)
        okm = cross_check(g, "from the emitted index")
        okt = type_round_trip(R, lambda k: g(k + "/0"), "from the emitted index")
        sys.exit(0 if (okm and okt) else 1)

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

    if cmd == "typename":
        b, n, _, _ = read_index(sys.argv[2])
        r = idx_lookup(b, n, sys.argv[3] + NAME_SUFFIX + "/0")
        print("%s -> %s" % (sys.argv[3],
                            "IS a type on this build" if r else "NOT a type on this build"))
        sys.exit(0 if r else 1)

    if cmd == "type":
        b, n, _, _ = read_index(sys.argv[2])
        key = sys.argv[3] + TYPE_SUFFIX + "/0"
        r = idx_lookup(b, n, key)
        print("%s -> %s" % (key, ("static Il2CppType RVA 0x%X" % r) if r else
                            "NOT FOUND (absent, or ambiguous and dropped)"))
        sys.exit(0 if r else 1)
    if cmd == "shared":
        R = Resolver(sys.argv[2], sys.argv[3])
        top = int(sys.argv[4]) if len(sys.argv) > 4 else 20
        keys, _ = build_keys(R)
        shared, distinct = shared_map(keys)
        report_shared(shared, distinct, keys, top=top)
        sys.exit(0)

    if cmd == "lookup":
        argv = [a for a in sys.argv[2:] if not a.startswith("--")]
        refuse = "--refuse-shared" in sys.argv[2:]
        b, n, ikey, fh = read_index(argv[0])
        spec = argv[1]
        key = spec + "/" + (argv[2] if len(argv) > 2 else "*")
        full = idx_lookup_full(b, n, key)
        print("%s -> %s" % (key, ("0x%X" % full[0]) if full is not None else
                            "NOT FOUND (absent, or ambiguous and therefore dropped)"))
        if full is None:
            sys.exit(1)
        r, share = full
        # The INDEX FIELD is the authority -- one file, one stamp. The sidecar
        # is consulted only to name the other methods, and its absence changes
        # what can be explained, not what is refused.
        if share == SHARE_UNKNOWN:
            print("  [sharedness UNKNOWN -- this entry carries no share count "
                  "(it is not a code key, or it was written by a generator "
                  "that did not count). This is NOT a statement that the RVA "
                  "is unshared: absence of evidence is not evidence of "
                  "uniqueness. A DETOUR here is refused.]")
            sys.exit(2 if refuse else 0)
        if share >= 2:
            print("  [SHARED: %d methods resolve here -- hooking this fires for "
                  "all of them]" % share)
            sh = read_shared_sidecar(shared_sidecar_path(argv[0]), ikey, fh)
            hit = sh.get(r) if sh else None
            if hit:
                cnt, sample = hit
                print("  others here: %s%s"
                      % (", ".join(k for k in sample if k != key),
                         " ..." if cnt > len(sample) else ""))
            else:
                print("  others here: unknown -- %s is missing, unstamped or "
                      "belongs to a different DLL. The COUNT above still came "
                      "from the index itself and stands."
                      % shared_sidecar_path(argv[0]))
            print("  A DIRECT CALL is still correct for the receiver you pass. "
                  "A DETOUR is not: it is a write whose blast radius is all %d."
                  % share)
            if refuse:
                sys.exit(2)
        else:
            print("  [not shared: this RVA is reached by this method only]")
        sys.exit(0)

    sys.exit(__doc__)


if __name__ == "__main__":
    main()
