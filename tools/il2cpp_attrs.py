#!/usr/bin/env python
"""il2cpp_attrs.py -- decode IL2CPP custom-attribute BLOBS out of decrypted
global-metadata, and in particular resolve C# [JsonProperty("wire_name")]
renames so a declared field name can be mapped to the name it takes on the wire.

## What was MEASURED (not assumed), 2026-08-27, metadata version 31

header pair index 24 = attributeData (a byte blob), 25 = attributeDataRange
(8-byte entries {uint32 token; uint32 startOffset}).  The range table is sorted
by token WITHIN an image's [customAttributeStart, +customAttributeCount) slice
(verified: the Assembly-CSharp slice is sorted), and an entry's blob ends where
the NEXT entry's startOffset begins.  Il2CppImageDefinition is 10 int32s;
customAttributeStart/Count are the last two.

Blob layout, decoded from a known ground truth
(`JsonType.KeepAliveResponse.UtcTime`, token 0x04007dd3):

    01 8c 42 02 00 01 00 00 0e 10 'utc_time'
    ^  ^-----------^ ^  ^  ^  ^  ^--- compressed *SIGNED* int32 length, ZIGZAG
    |  |             |  |  |  +------ Il2CppTypeEnum tag 0x0e = string
    |  |             |  |  +--------- compressed uint32: named-property count
    |  |             |  +------------ compressed uint32: named-field count
    |  |             +--------------- compressed uint32: ctor-arg count
    |  +----------------------------- RAW LE uint32 method index of the .ctor
    +-------------------------------- compressed uint32: attribute count

Two things there are easy to get wrong and were pinned by measurement:

  * the ctor index is a RAW 4-byte little-endian method index, NOT a compressed
    integer.  148108 -> Newtonsoft.Json.JsonPropertyAttribute::.ctor and
    40873 -> EFT.JsonEnumNameAttribute::.ctor; reading it compressed yields
    3138 / 10655, which are also valid method indices and therefore look
    perfectly plausible while being wrong.
  * a string's length is a compressed SIGNED int32 (zigzag), so it is stored as
    2*len: 0x10 for the 8-char "utc_time", 0x26 for the 19-char
    "ItemsCommonSettings".  -1 (encoded 0x01) means a null string.

## The self-check

`selfcheck()` re-derives five renames that are known ground truth
(ItemsSettings->ItemsCommonSettings, CustomizationInfo->Customization,
Experience->exp, ClientSettings->config, UtcTime->utc_time).  It prints NOTHING
on success.  A parser that does not reproduce all five is wrong, and every
consumer here calls it before returning any mapping.

## What this CANNOT do

An attribute whose argument list uses a type tag this reader does not model
makes the whole remaining blob unparseable (the encoding is not
self-delimiting).  That case is reported as UNPARSEABLE for that token, never
silently skipped and never guessed: a field with an unparseable blob keeps its
declared name and is flagged.
"""
import argparse, os, struct, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
REPO = os.path.dirname(HERE)


class Unparseable(Exception):
    pass


def _cuint(b, o):
    """il2cpp ReadCompressedUInt32 -> (value, newoffset)."""
    x = b[o]
    if (x & 0x80) == 0:
        return x, o + 1
    if (x & 0xC0) == 0x80:
        return ((x & 0x7F) << 8) | b[o + 1], o + 2
    if (x & 0xE0) == 0xC0:
        return (((x & 0x1F) << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) |
                b[o + 3]), o + 4
    if x == 0xF0:
        return struct.unpack_from("<I", b, o + 1)[0], o + 5
    if x == 0xFE:
        return 0xFFFFFFFE, o + 1
    if x == 0xFF:
        return 0xFFFFFFFF, o + 1
    raise Unparseable("bad compressed uint prefix 0x%02x" % x)


def _cint(b, o):
    """il2cpp ReadCompressedInt32 -- zigzag over ReadCompressedUInt32."""
    u, o = _cuint(b, o)
    if u == 0xFFFFFFFF:
        return -2147483648, o
    neg = u & 1
    u >>= 1
    return (-(u + 1) if neg else u), o


# Il2CppTypeEnum tags that can appear as an attribute argument, and how many
# RAW bytes each consumes.  None = handled specially below.
_FIXED = {0x02: 1, 0x03: 2, 0x04: 1, 0x05: 1, 0x06: 2, 0x07: 2,
          0x0A: 8, 0x0B: 8, 0x0C: 4, 0x0D: 8}


def _read_value(b, o, tag, depth=0):
    """-> (python value, newoffset). Raises Unparseable on an unmodelled tag."""
    if depth > 4:
        raise Unparseable("argument nesting too deep")
    if tag in _FIXED:
        n = _FIXED[tag]
        return b[o:o + n], o + n
    if tag == 0x08:                                    # I4
        return _cint(b, o)
    if tag == 0x09:                                    # U4
        return _cuint(b, o)
    if tag == 0x0E:                                    # string
        ln, o = _cint(b, o)
        if ln < 0:
            return None, o
        if o + ln > len(b):
            raise Unparseable("string length %d runs past blob end" % ln)
        return b[o:o + ln].decode("utf8", "replace"), o + ln
    if tag == 0x11 or tag == 0x55:                     # valuetype / enum
        _tidx, o = _cuint(b, o)                        # Il2CppType index
        return _cint(b, o)                             # value, int32 underlying
    if tag == 0xFF:                                    # IL2CPP_TYPE_INDEX (System.Type)
        return _cuint(b, o)
    if tag == 0x1D:                                    # SZARRAY
        n, o = _cint(b, o)
        if n < 0:
            return None, o
        et, o = b[o], o + 1
        vals = []
        for _ in range(n):
            if et == 0x51:                             # array of object
                it, o = b[o], o + 1
                v, o = _read_value(b, o, it, depth + 1)
            else:
                v, o = _read_value(b, o, et, depth + 1)
            vals.append(v)
        return vals, o
    if tag == 0x51:                                    # boxed object
        it, o = b[o], o + 1
        return _read_value(b, o, it, depth + 1)
    raise Unparseable("unmodelled Il2CppTypeEnum tag 0x%02x" % tag)


def parse_blob(b):
    try:
        return _parse_blob(b)
    except (IndexError, struct.error, UnicodeDecodeError) as e:
        raise Unparseable("ran off the end of the blob (%s)" % e)


def _parse_blob(b):
    """[(ctorMethodIndex, [ctorArgs], {namedName: value})] or raise Unparseable.

    Fully consumes the blob; a trailing-bytes mismatch is an error, not a
    shrug -- it is the only cheap evidence that the decoding drifted.
    """
    o = 0
    n, o = _cuint(b, o)
    ctors = []
    for _ in range(n):
        if o + 4 > len(b):
            raise Unparseable("ctor index array runs past blob end")
        ctors.append(struct.unpack_from("<I", b, o)[0])
        o += 4
    out = []
    for c in ctors:
        argc, o = _cuint(b, o)
        fldc, o = _cuint(b, o)
        propc, o = _cuint(b, o)
        args = []
        for _ in range(argc):
            tag, o = b[o], o + 1
            v, o = _read_value(b, o, tag)
            args.append(v)
        named = {}
        for _ in range(fldc + propc):
            tag, o = b[o], o + 1
            v, o = _read_value(b, o, tag)
            idx, o = _cint(b, o)
            named[idx] = (tag, v)
        out.append((c, args, named))
    if o != len(b):
        raise Unparseable("blob not fully consumed (%d of %d bytes)" % (o, len(b)))
    return out


class Attrs:
    """Custom-attribute reader bolted onto an il2cpp_resolve.Resolver."""

    def __init__(self, r):
        self.r = r
        m = r.m
        prop = lambda i: struct.unpack_from("<ii", m, 8 + i * 8)
        self.AD, self.ADS = prop(24)
        self.AR, self.ARS = prop(25)
        self.NR = self.ARS // 8
        # token -> range slot, built once over every image slice.  Built as a
        # dict rather than bisected per image so a token that belongs to no
        # image slice simply is not found instead of silently matching a
        # neighbour.
        self.slot = {}
        for k in range(r.IMG_SIZE // r.IMGS):
            bb = r.IMG_OFF + k * r.IMGS
            st, cnt = struct.unpack_from("<ii", m, bb + 32)
            for i in range(st, st + cnt):
                self.slot[struct.unpack_from("<I", m, self.AR + i * 8)[0]] = i

    def blob(self, token):
        i = self.slot.get(token)
        if i is None:
            return None
        st = struct.unpack_from("<I", self.r.m, self.AR + i * 8 + 4)[0]
        en = (struct.unpack_from("<I", self.r.m, self.AR + (i + 1) * 8 + 4)[0]
              if i + 1 < self.NR else self.ADS)
        if en < st or en > self.ADS:
            return None
        return self.r.m[self.AD + st:self.AD + en]

    def attrs(self, token):
        """[(attrTypeFullName, args, named)] ; raises Unparseable."""
        b = self.blob(token)
        if b is None:
            return []
        out = []
        for c, args, named in parse_blob(b):
            base = self.r.M_OFF + c * self.r.MS
            if c * self.r.MS + self.r.MS > self.r.M_SIZE:
                raise Unparseable("ctor method index %d out of range" % c)
            dt = struct.unpack_from("<i", self.r.m, base + 4)[0]
            ns, nm = self.r.tname(dt)
            out.append(((ns + "." + nm) if ns else nm, args, named))
        return out

    def type_property_tokens(self, t):
        """property name -> metadata token, for one type index.

        Needed because C# puts [JsonProperty] on the PROPERTY, while the field
        that metadata lists is the compiler-generated `<Name>k__BackingField`,
        which carries no attribute of its own. MEASURED: Il2CppTypeDefinition
        propertyStart@44 / propertyCount@66(u16); Il2CppPropertyDefinition is
        20 bytes {name, get, set, attrs, token}. Cross-checked against
        TraderSettings, whose 5 auto-properties decode to items_buy /
        items_sell / items_buy_prohibited / transferableItems /
        prohibitedTransferableItems -- all four of which appear verbatim as
        keys in the served payload.
        """
        r = self.r
        if not hasattr(self, "PROP_OFF"):
            self.PROP_OFF = struct.unpack_from("<i", r.m, 8 + 4 * 8)[0]
        bb = r.TD_OFF + t * r.TDS
        ps = struct.unpack_from("<i", r.m, bb + 44)[0]
        pc = struct.unpack_from("<H", r.m, bb + 66)[0]
        out = {}
        for i in range(pc):
            ni = struct.unpack_from("<i", r.m, self.PROP_OFF + (ps + i) * 20)[0]
            tok = struct.unpack_from("<I", r.m, self.PROP_OFF + (ps + i) * 20 + 16)[0]
            out[r.s(ni)] = tok
        return out

    # Il2CppMethodDefinition: flags@28 (u16 MethodAttributes); the low 3 bits
    # are the member-access mask, 6 == public. MEASURED on
    # EFT.GlobalConfiguration, whose 10 property getters all read 0x886
    # (public|hidebysig|specialname).
    MAS_PUBLIC = 6

    def method_flags(self, mi):
        return struct.unpack_from("<H", self.r.m, self.r.M_OFF + mi * self.r.MS + 28)[0]

    def type_properties(self, t):
        """[(name, token, get_mi, set_mi)] for one type index, or [].

        MEASURED: Il2CppPropertyDefinition is 20 bytes
        {nameIndex, get, set, attrs, token}, and `get`/`set` are indices
        RELATIVE TO THE DECLARING TYPE'S methodStart (@36), not absolute
        method indices -- verified on EFT.GlobalConfiguration, where
        get==0,2,4.. resolve to get_PrestigeSettings, get_MainQuest,
        get_QuestNotes in declaration order. -1 means absent.
        """
        r = self.r
        if not hasattr(self, "PROP_OFF"):
            self.PROP_OFF = struct.unpack_from("<i", r.m, 8 + 4 * 8)[0]
        bb = r.TD_OFF + t * r.TDS
        ms = struct.unpack_from("<i", r.m, bb + 36)[0]
        ps = struct.unpack_from("<i", r.m, bb + 44)[0]
        pc = struct.unpack_from("<H", r.m, bb + 66)[0]
        out = []
        for i in range(pc):
            ni, g, s, _at, tok = struct.unpack_from("<iiiII", r.m,
                                                    self.PROP_OFF + (ps + i) * 20)
            out.append((r.s(ni), tok,
                        (ms + g) if g >= 0 else None,
                        (ms + s) if s >= 0 else None))
        return out

    def json_name(self, token):
        """wire name for this field token, or None. Raises Unparseable."""
        for name, args, named in self.attrs(token):
            if name != "Newtonsoft.Json.JsonPropertyAttribute":
                continue
            for v in args:
                if isinstance(v, str):
                    return v
            # [JsonProperty(PropertyName = "x")]: named args are keyed by member
            # INDEX, not by name (that is what the blob stores), so the only
            # honest rule is "the single string named argument".
            strs = [v for _t, v in named.values() if isinstance(v, str)]
            if len(strs) == 1:
                return strs[0]
        return None

    def type_field_wire_names(self, t):
        """declared field name -> (wire name or None, 'ok'|'UNPARSEABLE').

        Instance fields of type index `t` only (no inheritance walk -- the
        caller owns the chain, exactly as dtogap does).
        """
        r = self.r
        r._ensure_fields()
        bb = r.TD_OFF + t * r.TDS
        fs = struct.unpack_from("<i", r.m, bb + 32)[0]
        fc = struct.unpack_from("<H", r.m, bb + 68)[0]
        out = {}
        for i in range(fc):
            ni, ti, tok = struct.unpack_from("<iiI", r.m, r.FLD_OFF + (fs + i) * 12)
            if r.field_is_static(ti):
                continue
            try:
                out[r.s(ni)] = (self.json_name(tok), "ok")
            except Unparseable as e:
                out[r.s(ni)] = (None, "UNPARSEABLE: %s" % e)
        return out


# ---------------------------------------------------------------- self-check
# Ground truth: five renames independently known to be what the wire carries.
GROUND = [("JsonType.KeepAliveResponse", "UtcTime", "utc_time"),
          ("JsonType.SelectProfileResponse", "ClientSettings", "config"),
          ("EFT.Profile.ProfileInfo", "ItemsSettings", "ItemsCommonSettings")]
# the remaining two are matched by (fieldName -> wireName) anywhere in the
# assembly, because their declaring type is not needed to falsify the decoder.
GROUND_ANY = [("Experience", "exp"), ("CustomizationInfo", "Customization")]


def selfcheck(r, a=None, verbose=False):
    """Mandatory. Prints only on FAILURE, then exits non-zero."""
    a = a or Attrs(r)
    bad = []
    r._ensure_fields()
    nf = struct.unpack_from("<ii", r.m, 8 + 11 * 8)[1] // 12
    seen = {}
    for i in range(nf):
        ni, ti, tok = struct.unpack_from("<iiI", r.m, r.FLD_OFF + i * 12)
        nm = r.s(ni)
        if nm not in ("Experience", "CustomizationInfo", "UtcTime",
                      "ClientSettings", "ItemsSettings"):
            continue
        try:
            w = a.json_name(tok)
        except Unparseable as e:
            bad.append("%s: blob UNPARSEABLE (%s)" % (nm, e))
            continue
        if w:
            seen.setdefault(nm, set()).add(w)
    for fld, want in GROUND_ANY + [(f, w) for _t, f, w in GROUND]:
        if want not in seen.get(fld, ()):
            bad.append("%s -> %r NOT decoded (got %r)"
                       % (fld, want, sorted(seen.get(fld, ()))))
    if bad:
        sys.stderr.write(
            "ATTRIBUTE SELF-CHECK FAILED -- the [JsonProperty] decoder does not\n"
            "reproduce known ground truth, so NO rename it reports is\n"
            "trustworthy. Nothing else printed.\n  " + "\n  ".join(bad) + "\n")
        sys.exit(3)
    if verbose:
        print("attribute self-check PASS: %s"
              % ", ".join("%s->%s" % (k, "/".join(sorted(v)))
                          for k, v in sorted(seen.items())))
    return a


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("verb", choices=["type", "selfcheck", "coverage"])
    ap.add_argument("name", nargs="?")
    ag = ap.parse_args()

    from il2cpp_resolve import Resolver
    import gamepaths as _gp
    GAMEASM = _gp.gameasm()
    METADEC = os.environ.get("AOWL_METADEC",
                             os.path.join(REPO, ".cache", "global-metadata.dec.dat"))
    r = Resolver(GAMEASM, METADEC)
    a = selfcheck(r, verbose=(ag.verb == "selfcheck"))

    if ag.verb == "type":
        t = r.find_one(ag.name)
        for n, (w, st) in a.type_field_wire_names(t).items():
            if st != "ok":
                print("%-38s %s" % (n, st))
            elif w and w != n:
                print("%-38s -> %s" % (n, w))
            else:
                print("%-38s (no rename)" % n)
    elif ag.verb == "coverage":
        ok = failed = named = 0
        for tok in a.slot:
            try:
                for nm, args, _nd in a.attrs(tok):
                    if nm == "Newtonsoft.Json.JsonPropertyAttribute":
                        named += 1
                ok += 1
            except Unparseable:
                failed += 1
        print("blobs parsed OK %d  UNPARSEABLE %d (%.2f%%)  JsonProperty attrs %d"
              % (ok, failed, 100.0 * failed / max(1, ok + failed), named))


if __name__ == "__main__":
    main()
