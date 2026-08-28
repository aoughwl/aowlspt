#!/usr/bin/env python3
r"""monotree.py -- reconstruct Unity SERIALISATION layouts for game MonoBehaviours
from the decrypted IL2CPP metadata, and decode scene bytes with them.

## Why this exists

Tarkov's level files are built with type trees STRIPPED.  Measured on
`D:\Games\Tarkov\EscapeFromTarkov_Data\level525` and `level526`: every
`SerializedType` entry reports `nodes=None`, and 65 / 31 of them respectively
are class_id 114 (MonoBehaviour).  UnityPy therefore falls back to its built-in
MonoBehaviour base node -- `m_GameObject, m_Enabled, m_Script, m_Name` -- and
either stops there or raises

    ValueError('Expected to read 68 bytes, but only read 32 bytes')

the moment a derived field appears.  So every BSG script's field VALUES are
unreadable out of the box, which is exactly why `mapextract.py`'s hierarchy
sidecars contain only Unity built-ins.

The layout is recoverable, because the metadata we already decrypt carries each
type's fields in DECLARATION ORDER with their types and their CUSTOM
ATTRIBUTES, and Unity's serialiser walks fields in declaration order, base
class first.

## Nothing here is guessed

The one datum that decides whether a non-public field is written --
`[SerializeField]` -- is read from the metadata attribute blob, not inferred:

    header prop 24 = attributeData       (blob)
    header prop 25 = attributeDataRange  (uint32 token, uint32 startOffset), 8B
    a range's data ends where the NEXT range begins (starts are monotonic;
    tokens are NOT sorted, so a binary search over tokens is wrong)
    blob = compressed-uint32 count, then `count` x uint32 LE ctor METHOD INDEX
    ctor method -> Il2CppMethodDefinition.declaringType@4 -> attribute type name

Measured end to end: `EFT.Game.Spawning.SpawnPointMarker._spawnPoint`
(field token 0x40104d9) has one attribute, ctor method index 0x26a6d, whose
declaring type is `UnityEngine.SerializeField`.  Its sibling `_debugInfo` has
no attribute range at all.

That agrees independently with the BYTES: a 168-byte `SpawnPointMarker`
payload in level534 is consumed exactly by `_spawnPoint` + `_collider` +
`Color` and by nothing else.  An earlier version of this module treated every
non-public field as an unknown and searched subsets; more than 64 subsets
round-tripped all 126 instances, because equal-width fields are not
distinguishable from bytes alone (a trailing empty `string` and a trailing
`int` both consume 4 bytes).  Reading the attribute is what makes the layout
identifiable; the search was papering over missing information and is gone.

## The check that can fail

A built layout is still only a hypothesis, so every decode is verified:
the layout must consume the payload to the LAST BYTE, and re-serialising the
decoded values must reproduce the source bytes EXACTLY.  Three outcomes:

    DECODED     round-tripped byte-exactly
    UNRESOLVED  no layout could be built, or the round trip failed
                (recorded WITH the type name and the raw payload length --
                 never dropped, never guessed)

## Layout rules (measured against SpawnPointMarker payloads in level534)

    string      int32 length + raw bytes + align to 4
                (the 26-byte name "PMCspawn_exp_Area_01_D (2)" is followed by
                 exactly 2 pad bytes; the 36-byte GUID string by none)
    align4      after bool / int8 / uint8 / int16 / uint16 / char
    PPtr        int32 fileID + int64 pathID, no trailing align
    array/List  int32 count + elements + align to 4
    struct      members inline, no extra align of its own

`tools/il2cpp_resolve.py` supplies every metadata read; its mandatory
`System.String._stringLength@0x10 / _firstChar@0x14` self-check is re-run here
(`Layouts.selfcheck`) before any layout is built, alongside a second self-check
that re-derives the SerializeField attribute above.
"""

import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from il2cpp_resolve import Resolver          # noqa: E402


# ---------------------------------------------------------------------------
# Il2CppTypeEnum values this module lays out.

TE_BOOL = 0x02
TE_CHAR = 0x03
TE_I1, TE_U1 = 0x04, 0x05
TE_I2, TE_U2 = 0x06, 0x07
TE_I4, TE_U4 = 0x08, 0x09
TE_I8, TE_U8 = 0x0A, 0x0B
TE_R4, TE_R8 = 0x0C, 0x0D
TE_STRING = 0x0E
TE_VALUETYPE = 0x11
TE_CLASS = 0x12
TE_GENERICINST = 0x15
TE_SZARRAY = 0x1D

# size, struct code, align4-after
PRIMITIVES = {
    TE_BOOL: (1, "?", True),
    TE_CHAR: (2, "H", True),
    TE_I1: (1, "b", True),
    TE_U1: (1, "B", True),
    TE_I2: (2, "h", True),
    TE_U2: (2, "H", True),
    TE_I4: (4, "i", False),
    TE_U4: (4, "I", False),
    TE_I8: (8, "q", False),
    TE_U8: (8, "Q", False),
    TE_R4: (4, "f", False),
    TE_R8: (8, "d", False),
}

SERIALIZE_FIELD = "UnityEngine.SerializeField"
SERIALIZE_REFERENCE = "UnityEngine.SerializeReference"

# TypeAttributes. `[Serializable]` is NOT a custom attribute -- the C# compiler
# turns it into this FLAG, so looking for `System.SerializableAttribute` in the
# attribute blob finds nothing and wrongly rejects every serialisable class
# (measured: it rejected EFT.Game.Spawning.SpawnPoint, which the bytes prove is
# written inline).
TA_INTERFACE = 0x00000020
TA_ABSTRACT = 0x00000080
TA_SERIALIZABLE = 0x00002000

# FieldAttributes
FA_ACCESS = 0x0007
FA_PUBLIC = 0x0006
FA_STATIC = 0x0010
FA_LITERAL = 0x0040
FA_NOTSERIALIZED = 0x0080

MAX_DEPTH = 10


class LayoutError(Exception):
    """A layout could not be BUILT -- distinct from one that failed to decode."""


class UnserialisableType(LayoutError):
    """This field's TYPE is one Unity itself never writes (a delegate, an
    interface, a non-[Serializable] class, an unsupported generic).

    The field is skipped, exactly as Unity skips it. This is deliberately a
    DIFFERENT condition from 'we cannot compute this type's width', which stays
    fatal -- guessing a width shifts every following field and produces values
    that look entirely real."""


class DecodeError(Exception):
    """A built layout did not fit the bytes."""


class Node(object):
    __slots__ = ("name", "kind", "type_name", "children", "fmt", "size",
                 "align", "elem", "tindex")

    def __init__(self, name, kind, type_name):
        self.name = name
        self.kind = kind            # prim | str | pptr | struct | array
        self.type_name = type_name
        self.children = []
        self.fmt = None
        self.size = 0
        self.align = False
        self.elem = None
        self.tindex = None      # metadata type index, when this node HAS one


def _align4(off):
    return off + ((-off) % 4)


def _prim(name, te, type_name):
    size, code, align = PRIMITIVES[te]
    n = Node(name, "prim", type_name)
    n.size, n.fmt, n.align = size, code, align
    return n


def _struct(name, type_name, children):
    n = Node(name, "struct", type_name)
    n.children = children
    return n


def _builtin_animation_curve(name):
    """UnityEngine.AnimationCurve is native-backed: it carries no [Serializable]
    flag and its il2cpp field list is a single m_Ptr, so the metadata cannot
    describe its on-disk shape. This is the shape Unity actually writes
    (2019.3+), and like every other layout here it only counts if the byte-exact
    round trip passes."""
    key = _struct("data", "UnityEngine.Keyframe", [
        _prim("time", TE_R4, "float"),
        _prim("value", TE_R4, "float"),
        _prim("inSlope", TE_R4, "float"),
        _prim("outSlope", TE_R4, "float"),
        _prim("weightedMode", TE_I4, "int"),
        _prim("inWeight", TE_R4, "float"),
        _prim("outWeight", TE_R4, "float"),
    ])
    curve = Node("m_Curve", "array", "UnityEngine.Keyframe[]")
    curve.elem = key
    return _struct(name, "UnityEngine.AnimationCurve", [
        curve,
        _prim("m_PreInfinity", TE_I4, "int"),
        _prim("m_PostInfinity", TE_I4, "int"),
        _prim("m_RotationOrder", TE_I4, "int"),
    ])


def _builtin_layermask(name):
    return _struct(name, "UnityEngine.LayerMask",
                   [_prim("m_Mask", TE_U4, "uint")])


# Unity types whose serialised shape is NOT derivable from il2cpp metadata,
# because the managed side is a handle to a native object. Anything not listed
# here and not describable from metadata is reported UNRESOLVED, never guessed.
BUILTIN_LAYOUTS = {
    "UnityEngine.AnimationCurve": _builtin_animation_curve,
    "UnityEngine.LayerMask": _builtin_layermask,
}


# ---------------------------------------------------------------------------


class Layouts(object):
    """Builds and caches serialisation layouts, keyed by metadata type index."""

    def __init__(self, gameasm, metadec):
        self.r = Resolver(gameasm, metadec)
        self._byname = None
        self._cache = {}
        self._objroot = None
        self._attr_cache = {}
        self._init_attributes()
        self.selfcheck()

    # -- attribute blob --------------------------------------------------
    def _init_attributes(self):
        """Index the attribute ranges PER IMAGE.

        Metadata tokens are per-image RIDs, so the SAME token value occurs in
        `Assembly-CSharp.dll` and in `Unity.AI.Navigation.dll`.  A single global
        token -> range dict therefore lets one image's attributes answer for
        another image's field -- the same shape of bug as using one image's
        `methodPointers` table for another image's method.  Measured: it made
        `Unity.AI.Navigation.NavMeshModifier` come back with no serialised
        fields at all (layout consumed 0 of 32 bytes), because its
        [SerializeField] fields were looked up against Assembly-CSharp's ranges.

        `Il2CppImageDefinition` (40 bytes) carries the bounds:
            nameIndex@0 assemblyIndex@4 typeStart@8 typeCount@12
            exportedTypeStart@16 exportedTypeCount@20 entryPointIndex@24
            token@28 customAttributeStart@32 customAttributeCount@36
        """
        m = self.r.m
        self.ATTR_DATA, self.ATTR_DATA_SZ = struct.unpack_from("<ii", m, 8 + 24 * 8)
        rng_off, rng_sz = struct.unpack_from("<ii", m, 8 + 25 * 8)
        n = rng_sz // 8
        ent = [struct.unpack_from("<II", m, rng_off + i * 8) for i in range(n)]
        # Starts are monotonic; TOKENS ARE NOT SORTED. A range ends where the
        # next one begins, in FILE order -- not in token order.
        self._attr_ent = ent
        self._attr_end = [ent[i + 1][1] if i + 1 < n else self.ATTR_DATA_SZ
                          for i in range(n)]
        self._img_bounds = []       # (name, typeStart, typeCount, caStart, caCount)
        for k in range(self.r.IMG_SIZE // self.r.IMGS):
            base = self.r.IMG_OFF + k * self.r.IMGS
            ni, _ai, ts, tc = struct.unpack_from("<iiiI", m, base)
            cas, cac = struct.unpack_from("<ii", m, base + 32)
            self._img_bounds.append((self.r.s(ni), ts, tc, cas, cac))
        self._img_attr = {}

    def image_index_of_type(self, t):
        for k, (_nm, ts, tc, _cas, _cac) in enumerate(self._img_bounds):
            if ts <= t < ts + tc:
                return k
        return None

    def _image_attr_map(self, img):
        """token -> (start, end) for image `img` only."""
        got = self._img_attr.get(img)
        if got is not None:
            return got
        _nm, _ts, _tc, cas, cac = self._img_bounds[img]
        out = {}
        for i in range(cas, min(cas + cac, len(self._attr_ent))):
            out[self._attr_ent[i][0]] = (self._attr_ent[i][1], self._attr_end[i])
        self._img_attr[img] = out
        return out

    @staticmethod
    def _cu32(m, p):
        b = m[p]
        if b < 0x80:
            return b, p + 1
        if (b & 0xC0) == 0x80:
            return ((b & 0x3F) << 8) | m[p + 1], p + 2
        if (b & 0xE0) == 0xC0:
            return (((b & 0x1F) << 24) | (m[p + 1] << 16)
                    | (m[p + 2] << 8) | m[p + 3]), p + 4
        if b == 0xF0:
            return struct.unpack_from("<I", m, p + 1)[0], p + 5
        raise LayoutError("unrecognised compressed-uint lead byte %#x" % b)

    def attributes_of(self, token, img):
        """Set of attribute type full names on metadata `token` within image
        `img`, or an empty set. Never raises for a token with no range."""
        key = (img, token)
        if key in self._attr_cache:
            return self._attr_cache[key]
        rng = None if img is None else self._image_attr_map(img).get(token)
        out = set()
        if rng is not None:
            m = self.r.m
            p = self.ATTR_DATA + rng[0]
            try:
                cnt, p = self._cu32(m, p)
                for _ in range(cnt):
                    (ctor,) = struct.unpack_from("<I", m, p)
                    p += 4
                    if ctor * self.r.MS + 8 > self.r.M_SIZE:
                        raise LayoutError("ctor index out of range")
                    dt = struct.unpack_from("<i", m,
                                            self.r.M_OFF + ctor * self.r.MS + 4)[0]
                    if 0 <= dt < self.r.NTYPES:
                        ns, nm = self.r.tname(dt)
                        out.add((ns + "." + nm) if ns else nm)
            except (LayoutError, struct.error, IndexError):
                out = set()
        self._attr_cache[key] = out
        return out

    def type_token(self, t):
        return struct.unpack_from("<I", self.r.m,
                                  self.r.TD_OFF + t * self.r.TDS + 84)[0]

    def type_flags(self, t):
        return struct.unpack_from("<I", self.r.m,
                                  self.r.TD_OFF + t * self.r.TDS + 28)[0]

    # -- mandatory self-checks -------------------------------------------
    def selfcheck(self):
        """Ground truth this module cannot be right without.

        1. `System.String._stringLength@0x10`, `_firstChar@0x14` -- known
           independently of this build. A resolver that cannot reproduce them
           found the wrong fieldOffsets site, and no layout derived from it may
           be trusted.
        2. `UnityEngine.Vector3` must have exactly the three public instance
           float fields x, y, z, in that order -- the shape every decoded
           position depends on.
        3. The attribute decoder must find `UnityEngine.SerializeField` on
           `EFT.Game.Spawning.SpawnPointMarker._spawnPoint` and find NOTHING on
           its sibling `_debugInfo`. An attribute reader that returns the empty
           set for everything would silently drop every private serialised
           field and still look like it worked.
        """
        t = self.type_index("System.String")
        if t is None:
            raise LayoutError("SELF-CHECK FAILED: System.String not in metadata")
        got = {row["name"]: row["off"] for row in self.r.declared_fields_ex(t)}
        if got.get("_stringLength") != 0x10 or got.get("_firstChar") != 0x14:
            raise LayoutError(
                "SELF-CHECK FAILED: System.String._stringLength=%r _firstChar=%r "
                "(expected 0x10 / 0x14). The metadata and the binary do not "
                "agree; refusing to emit any layout."
                % (got.get("_stringLength"), got.get("_firstChar")))

        v3 = self.type_index("UnityEngine.Vector3")
        names = [r["name"] for r in self._rows(v3)
                 if not (r["attrs"] & (FA_STATIC | FA_LITERAL))]
        if names != ["x", "y", "z"]:
            raise LayoutError(
                "SELF-CHECK FAILED: UnityEngine.Vector3 instance fields are %r, "
                "not ['x','y','z']; every decoded position would be wrong."
                % (names,))

        spm = self.type_index("EFT.Game.Spawning.SpawnPointMarker")
        if spm is not None:
            rows = {r["name"]: r for r in self._rows(spm)}
            img = self.image_index_of_type(spm)
            if "_spawnPoint" in rows and "_debugInfo" in rows:
                a = self.attributes_of(rows["_spawnPoint"]["token"], img)
                b = self.attributes_of(rows["_debugInfo"]["token"], img)
                if SERIALIZE_FIELD not in a or b:
                    raise LayoutError(
                        "SELF-CHECK FAILED: attribute decoder returned %r for "
                        "SpawnPointMarker._spawnPoint (expected to contain %s) "
                        "and %r for _debugInfo (expected empty). Every private "
                        "serialised field would be dropped."
                        % (sorted(a), SERIALIZE_FIELD, sorted(b)))

        # 4. The attribute index must be PER IMAGE. NavMeshModifier lives in
        #    Unity.AI.Navigation.dll and its serialised state is entirely
        #    private [SerializeField] fields; a global token index answers with
        #    Assembly-CSharp's ranges and yields ZERO fields, which decodes as
        #    "consumed 0 of 32 bytes" rather than as an error.
        nmm = self.type_index("Unity.AI.Navigation.NavMeshModifier")
        if nmm is not None:
            img = self.image_index_of_type(nmm)
            if self.r.IMAGES[img][0] != "Unity.AI.Navigation.dll":
                raise LayoutError(
                    "SELF-CHECK FAILED: NavMeshModifier maps to image %r, not "
                    "Unity.AI.Navigation.dll; the image bounds are wrong."
                    % (self.r.IMAGES[img][0],))
            marked = [r["name"] for r in self._rows(nmm)
                      if SERIALIZE_FIELD in self.attributes_of(r["token"], img)]
            if not marked:
                raise LayoutError(
                    "SELF-CHECK FAILED: no [SerializeField] found on "
                    "Unity.AI.Navigation.NavMeshModifier. The attribute index "
                    "is not resolving per image, so every non-Assembly-CSharp "
                    "script would silently decode as having no fields.")
        return True

    # -- name lookup ----------------------------------------------------
    def _build_names(self):
        if self._byname is not None:
            return
        self._byname = {}
        for t in range(self.r.NTYPES):
            ns, nm = self.r.tname(t)
            full = (ns + "." + nm) if ns else nm
            self._byname.setdefault(full, []).append(t)

    def type_index(self, full_name, assembly=None):
        """Metadata type index for an EXACT full name, or None.

        Unlike `Resolver.find_one` this never exits the process, and it never
        falls back to a near-miss substring match (fact #179). A name that is
        ambiguous even after the assembly filter returns None -- there is no
        safe way to pick."""
        self._build_names()
        hits = self._byname.get(full_name)
        if not hits:
            return None
        if len(hits) == 1:
            return hits[0]
        if assembly:
            narrowed = [t for t in hits if self.r.image_of_type(t) == assembly]
            if len(narrowed) == 1:
                return narrowed[0]
        return None

    # -- metadata helpers ------------------------------------------------
    def _rows(self, t):
        """Fields DECLARED on t: name, attrs, Il2CppType index, metadata token.

        `declared_fields_ex` does not expose the type index or the token, both
        of which this module needs."""
        self.r._ensure_fields()
        bb = self.r.TD_OFF + t * self.r.TDS
        fs = struct.unpack_from("<i", self.r.m, bb + 32)[0]
        fc = struct.unpack_from("<H", self.r.m, bb + 68)[0]
        out = []
        for i in range(fc):
            base = self.r.FLD_OFF + (fs + i) * 12
            ni, ti = struct.unpack_from("<ii", self.r.m, base)
            (tok,) = struct.unpack_from("<I", self.r.m, base + 8)
            out.append({"name": self.r.s(ni), "attrs": self.r.field_attrs(ti),
                        "tidx": ti, "token": tok,
                        "typename": self.r.field_typename(ti)})
        return out

    def _full(self, t):
        ns, nm = self.r.tname(t)
        return (ns + "." + nm) if ns else nm

    def _derives_from_unity_object(self, t):
        if self._objroot is None:
            self._objroot = self.type_index("UnityEngine.Object")
        seen, cur = set(), t
        while cur is not None and cur not in seen:
            if cur == self._objroot:
                return True
            seen.add(cur)
            cur = self.r.parent_type(cur)
        return False

    def _is_delegate(self, t):
        seen, cur = set(), t
        while cur is not None and cur not in seen:
            if self._full(cur) in ("System.Delegate", "System.MulticastDelegate"):
                return True
            seen.add(cur)
            cur = self.r.parent_type(cur)
        return False

    def _enum_underlying(self, t):
        for row in self._rows(t):
            if row["name"] == "value__":
                p = PRIMITIVES.get(self.r.type_enum_of(row["tidx"]))
                if p:
                    return p
        return PRIMITIVES[TE_I4]

    def _generic_args(self, tva):
        gc = self.r.rq(tva)
        if gc is None:
            return None, []
        gd = self.r.rq(gc)
        class_inst = self.r.rq(gc + 8)
        gdata = self.r.rq(gd) if gd is not None else None
        args = []
        if class_inst:
            fo = self.r.v2f(class_inst)
            if fo is None:
                return gdata, []
            (argc,) = struct.unpack_from("<Q", self.r.b, fo)
            argv = self.r.rq(class_inst + 8)
            for i in range(min(argc, 8)):
                args.append(self.r.rq(argv + i * 8))
        return gdata, args

    # -- node construction ----------------------------------------------
    def node_for_type_va(self, name, tva, depth, stack):
        """Layout node for the Il2CppType at VA `tva`.

        Raises LayoutError for anything this module cannot lay out. It never
        substitutes a plausible fallback: a wrong width here shifts every
        following field and yields values that look real."""
        if depth > MAX_DEPTH:
            raise LayoutError("nesting deeper than %d at %r" % (MAX_DEPTH, name))
        fo = self.r.v2f(tva)
        if fo is None:
            raise LayoutError("unreadable Il2CppType for %r" % name)
        te = (struct.unpack_from("<I", self.r.b, fo + 8)[0] >> 16) & 0xFF
        data = self.r.rq(tva)
        tn = self.r._typename_va(tva)

        if te in PRIMITIVES:
            size, code, align = PRIMITIVES[te]
            n = Node(name, "prim", tn)
            n.size, n.fmt, n.align = size, code, align
            return n

        if te == TE_STRING:
            return Node(name, "str", "string")

        if te == TE_SZARRAY:
            n = Node(name, "array", tn)
            n.elem = self.node_for_type_va("data", data, depth + 1, stack)
            return n

        if te == TE_GENERICINST:
            gdata, args = self._generic_args(tva)
            base = ""
            if gdata is not None and gdata < self.r.NTYPES:
                base = self._full(gdata)
            if base.startswith("System.Collections.Generic.List`1") and len(args) == 1:
                n = Node(name, "array", tn)
                try:
                    n.elem = self.node_for_type_va("data", args[0], depth + 1,
                                                   stack)
                except UnserialisableType:
                    # A List of an unserialisable element type is itself not
                    # written -- Unity does not emit an empty count for it.
                    raise UnserialisableType("%s has an unserialisable element"
                                             % tn)
                return n
            raise UnserialisableType("generic %s is not a serialisable shape" % tn)

        if te in (TE_VALUETYPE, TE_CLASS):
            if data is None or not (0 <= data < self.r.NTYPES):
                raise LayoutError("unresolvable type for %r" % name)
            builtin = BUILTIN_LAYOUTS.get(self._full(data))
            if builtin is not None:
                return builtin(name)
            flags = self.type_flags(data)
            if te == TE_CLASS and self._derives_from_unity_object(data):
                n = Node(name, "pptr", tn)
                n.size = 12
                n.tindex = data
                return n
            if self.r.is_enum(data):
                size, code, align = self._enum_underlying(data)
                n = Node(name, "prim", tn)
                n.size, n.fmt, n.align = size, code, align
                n.tindex = data
                return n
            if flags & TA_INTERFACE:
                raise UnserialisableType("%s is an interface" % tn)
            if te == TE_CLASS:
                if self._is_delegate(data):
                    raise UnserialisableType("%s is a delegate" % tn)
                # A plain class is written inline only when it is [Serializable].
                if not (flags & TA_SERIALIZABLE):
                    raise UnserialisableType("%s is not [Serializable]" % tn)
            if data in stack:
                raise UnserialisableType(
                    "%s nests inside itself; Unity stops at depth 7 rather than "
                    "recursing, and this module does not model that" % tn)
            n = Node(name, "struct", self._full(data))
            n.tindex = data
            n.children.extend(self.fields_of(data, depth + 1, stack | {data}))
            return n

        raise LayoutError("Il2CppTypeEnum %#x (%s) not laid out for %r"
                          % (te, tn, name))

    def fields_of(self, t, depth, stack):
        """Serialised fields DECLARED on t, in declaration order.

        Unity writes an instance field when it is public, or non-public and
        marked [SerializeField]. `[NonSerialized]` (FieldAttributes 0x0080),
        statics and consts are never written.

        A field whose TYPE is not serialisable is SKIPPED, not fatal -- that is
        Unity's own behaviour, and it is why `EFT.Interactive.ExfiltrationPoint`
        is layoutable at all despite a public `Action<ExfiltrationPoint,Player>`
        field. The distinction matters: `UnserialisableType` means "Unity would
        skip this too", while every other LayoutError means "we do not know the
        width", which shifts every following field and must stay fatal."""
        img = self.image_index_of_type(t)
        out = []
        for row in self._rows(t):
            attrs = row["attrs"]
            if attrs & (FA_STATIC | FA_LITERAL | FA_NOTSERIALIZED):
                continue
            if (attrs & FA_ACCESS) != FA_PUBLIC:
                fattrs = self.attributes_of(row["token"], img)
                if SERIALIZE_FIELD not in fattrs:
                    continue
                if SERIALIZE_REFERENCE in fattrs:
                    raise LayoutError(
                        "%s.%s is [SerializeReference]; its on-disk shape is a "
                        "managed-reference table this module does not read"
                        % (self._full(t), row["name"]))
            tva = self.r.rq(self.r.TYPES_PTR + row["tidx"] * 8)
            try:
                out.append(self.node_for_type_va(row["name"], tva, depth, stack))
            except UnserialisableType:
                continue
        return out

    def behaviour_layout(self, t):
        """(root_node, None) for a MonoBehaviour subclass, or (None, reason).

        Covers every class between t and UnityEngine.MonoBehaviour, BASE FIRST.
        The four base header fields (m_GameObject, m_Enabled, m_Script,
        m_Name) are read separately and are NOT part of this layout.

        A ScriptableObject is accepted on the same terms: it is stored with
        class_id 114 too, and its header is the same four fields (m_GameObject
        and m_Enabled are simply always 0)."""
        if t in self._cache:
            return self._cache[t]
        stops = {self.type_index("UnityEngine.MonoBehaviour"),
                 self.type_index("UnityEngine.ScriptableObject")}
        stops.discard(None)
        chain, cur, seen = [], t, set()
        while cur is not None and cur not in seen and cur not in stops:
            seen.add(cur)
            chain.append(cur)
            cur = self.r.parent_type(cur)
        if cur not in stops:
            res = (None, "derives from neither UnityEngine.MonoBehaviour nor "
                         "UnityEngine.ScriptableObject")
            self._cache[t] = res
            return res
        root = Node(self._full(t), "struct", self._full(t))
        root.tindex = t
        try:
            for ct in reversed(chain):
                root.children.extend(self.fields_of(ct, 1, {ct}))
        except LayoutError as exc:
            res = (None, str(exc))
            self._cache[t] = res
            return res
        res = (root, None)
        self._cache[t] = res
        return res


# ---------------------------------------------------------------------------
# reader / writer


class Reader(object):
    def __init__(self, data, off=0):
        self.d = data
        self.p = off

    def need(self, n):
        if n < 0 or self.p + n > len(self.d):
            raise DecodeError("short read")
        return self.p

    def align(self):
        self.p = _align4(self.p)


def decode(node, rd):
    k = node.kind
    if k == "prim":
        p = rd.need(node.size)
        (v,) = struct.unpack_from("<" + node.fmt, rd.d, p)
        rd.p += node.size
        if node.align:
            rd.align()
        if node.fmt in ("f", "d") and (v != v or v in (float("inf"),
                                                       float("-inf"))):
            raise DecodeError("non-finite float in %s" % node.name)
        return v
    if k == "str":
        rd.need(4)
        (n,) = struct.unpack_from("<i", rd.d, rd.p)
        if n < 0 or n > (1 << 20):
            raise DecodeError("absurd string length %d" % n)
        rd.p += 4
        rd.need(n)
        s = rd.d[rd.p:rd.p + n].decode("utf-8", "replace")
        rd.p += n
        rd.align()
        return s
    if k == "pptr":
        p = rd.need(12)
        fid, pid = struct.unpack_from("<iq", rd.d, p)
        rd.p += 12
        return {"m_FileID": fid, "m_PathID": pid}
    if k == "array":
        rd.need(4)
        (n,) = struct.unpack_from("<i", rd.d, rd.p)
        if n < 0 or n > (1 << 22):
            raise DecodeError("absurd array count %d" % n)
        rd.p += 4
        out = [decode(node.elem, rd) for _ in range(n)]
        rd.align()
        return out
    if k == "struct":
        return {ch.name: decode(ch, rd) for ch in node.children}
    raise DecodeError("unknown node kind %r" % k)


class Writer(object):
    def __init__(self):
        self.buf = bytearray()

    def align(self):
        self.buf.extend(b"\0" * ((-len(self.buf)) % 4))


def encode(node, value, wr):
    k = node.kind
    if k == "prim":
        wr.buf.extend(struct.pack("<" + node.fmt, value))
        if node.align:
            wr.align()
        return
    if k == "str":
        b = value.encode("utf-8", "replace")
        wr.buf.extend(struct.pack("<i", len(b)))
        wr.buf.extend(b)
        wr.align()
        return
    if k == "pptr":
        wr.buf.extend(struct.pack("<iq", value["m_FileID"], value["m_PathID"]))
        return
    if k == "array":
        wr.buf.extend(struct.pack("<i", len(value)))
        for v in value:
            encode(node.elem, v, wr)
        wr.align()
        return
    if k == "struct":
        for ch in node.children:
            encode(ch, value[ch.name], wr)
        return
    raise DecodeError("unknown node kind %r" % k)


def decode_verified(root, payload):
    """(value, None) if the layout round-trips `payload` byte-exactly, else
    (None, reason).

    The check is a property of the FINISHED bytes, not of our own read: the
    layout must consume the payload to the last byte AND re-serialise to the
    identical bytes.  A layout that is one field short, one field long, or
    wrong in any width fails it."""
    rd = Reader(payload)
    try:
        val = decode(root, rd)
    except (DecodeError, struct.error, UnicodeDecodeError) as exc:
        return None, "decode failed: %s" % exc
    if rd.p != len(payload):
        return None, ("layout consumed %d of %d bytes"
                      % (rd.p, len(payload)))
    wr = Writer()
    try:
        encode(root, val, wr)
    except Exception as exc:                 # noqa: BLE001
        return None, "re-encode failed: %r" % (exc,)
    if bytes(wr.buf) != payload:
        return None, "round trip differed from the source bytes"
    return val, None
