"""dtodeep.py -- the RECURSIVE half of the JSON-type audit.

## The hole this closes

`dtotype.py` compares the emitted JSON against the client's declared types for
the members of ONE object: the top level of the payload. Every nested member
across all 70 routes was unaudited -- and that is exactly where the crash-class
bugs have been. `MainQuestSettings` sits at `globals.config.MainQuest`;
`TraderDialogsDTO`, `AvailableCustomizationsResponse` and `SeasonalPerksData`
were likewise nested. All four were found by reading the CLIENT'S OWN error log
after a crash, because the sweep structurally could not see them.

This module descends. For every mapped route it walks the payload and the
declared type together -- into objects, into array elements, into
`Dictionary<,>` values -- and reports each mismatch with a FULL PATH
(`globals.config.MainQuest.SomeMember`), never a bare member name.

## Why the type INDEX and not the type NAME

Nesting by name does not work. `field_typename` yields SHORT names, so
`Dictionary<String,MainQuestSettings>` has to be re-parsed, and a short name
that is not unique in the metadata cannot be resolved at all -- `find_one`
correctly refuses to guess (fact #179). Every nested member here is resolved
from its parent's Il2CppType index (`dto_fields(..., with_tidx=True)`), so the
descent is exact or it is explicitly UNKNOWN.

## Verdicts -- four, not two

  FATAL      Newtonsoft THROWS. Object-vs-array, array-vs-object, scalar into
             a class, null into a non-nullable value type. This is the class
             that does not fail the route -- it kills the raid load.
  COERCIBLE  Newtonsoft converts it silently. A number into a string, a
             numeric string into a number, 0/1 into a bool. BSG's own server
             does this; it is NOT a bug and is never asserted on.
  OK         binds cleanly.
  UNKNOWN    we could not decide: an untyped/interface/unresolvable declared
             type, a generic we do not model, or a member the payload omits.
             NOT a pass, and counted separately in the coverage line.

## The trap this tool is built around

Three times in one day an audit nearly made us "fix" CORRECT data. So when a
row would be FATAL, the SAME PATH is looked up in BSG's own captured traffic
(`mods/tarkov/data/capture/raid1`). If BSG sends the same JSON kind at that
path, the row is downgraded to UNKNOWN and says so: a shape BSG's real server
serves to this client is not our type error, it falsifies the DTO mapping
instead. This also covers the ~20 routes we serve from capture VERBATIM, where
`--provenance ours` would otherwise attribute BSG's shape to us and
manufacture FATALs.
"""
import json
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import dtogap as G                                        # noqa: E402

FATAL, COERCIBLE, OK, UNKNOWN, HETERO = (
    "FATAL", "COERCIBLE", "OK", "UNKNOWN", "HETERO")

INT_TYPES = {"int", "long", "short", "byte", "sbyte", "uint", "ulong",
             "ushort", "Int32", "Int64", "Int16", "Byte", "UInt32", "UInt64"}
NUM_TYPES = INT_TYPES | {"float", "double", "decimal", "Single", "Double"}
BOOL_TYPES = {"bool", "Boolean"}
STR_TYPES = {"string", "String", "MongoID", "MongoId"}
UNTYPED = {"object", "Object", "JObject", "JToken", "JArray", "JsonElement"}

LIST_BASES = {"List", "IList", "ICollection", "IEnumerable", "IReadOnlyList",
              "IReadOnlyCollection", "HashSet", "ISet", "Collection",
              "LinkedList", "Queue", "Stack"}
DICT_BASES = {"Dictionary", "IDictionary", "IReadOnlyDictionary",
              "SortedDictionary", "SortedList", "ConcurrentDictionary"}


def jkind(v):
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "bool"
    if isinstance(v, int):
        return "int"
    if isinstance(v, float):
        return "float"
    if isinstance(v, str):
        return "string"
    if isinstance(v, list):
        return "array"
    return "object"


def numeric_string(s):
    try:
        float(s)
        return True
    except (TypeError, ValueError):
        return False


# --------------------------------------------------------- the type layer
#
# Everything here works on Il2CppType VAs, because that is the only
# representation that survives generics and arrays without going through a
# name. `r` is an il2cpp_resolve.Resolver.

def tva_of(r, tidx):
    if tidx is None or tidx < 0:
        return None
    return r.rq(r.TYPES_PTR + tidx * 8)


def te_of(r, tva):
    if tva is None:
        return None
    try:
        return (struct.unpack_from("<I", r.b, r.v2f(tva) + 8)[0] >> 16) & 0xFF
    except Exception:
        return None


def generic_parts(r, gc_va):
    """(base short name, [argument Il2CppType VA]) for an Il2CppGenericClass."""
    gd = r.rq(gc_va)
    class_inst = r.rq(gc_va + 8)
    gdata = r.rq(gd) if gd is not None else None
    base = "?"
    if gdata is not None and gdata < r.NTYPES:
        base = r.tname(gdata)[1].split("`")[0]
    args = []
    if class_inst:
        try:
            argc = struct.unpack_from("<Q", r.b, r.v2f(class_inst))[0]
        except Exception:
            argc = 0
        argv = r.rq(class_inst + 8)
        for i in range(min(argc, 6)):
            args.append(r.rq(argv + i * 8))
    return base, args


def decompose(r, tva):
    """('class', typedef-index) | ('array', element-VA) |
       ('list', element-VA) | ('map', value-VA) |
       ('generic', base-name) | ('prim', None) | ('?', None)"""
    te = te_of(r, tva)
    if te is None:
        return "?", None
    data = r.rq(tva)
    if te in (0x11, 0x12):                    # class / valuetype
        return ("class", data) if (data is not None and data < r.NTYPES) \
            else ("?", None)
    if te == 0x1d:                            # szarray
        return "array", data
    if te == 0x14:                            # general array: Il2CppArrayType*
        try:
            return "array", r.rq(data)
        except Exception:
            return "?", None
    if te == 0x15:                            # generic instance
        base, args = generic_parts(r, data)
        if base in LIST_BASES and len(args) == 1:
            return "list", args[0]
        if base in DICT_BASES and len(args) == 2:
            return "map", args[1]
        if base == "Nullable" and len(args) == 1:
            return decompose(r, args[0])
        return "generic", base
    return "prim", None


# ------------------------------------------------------------ the verdict

def classify(declared, kind, value):
    """(verdict, why) for ONE value against ONE declared type.

    Split out of dtotype.classify so that MISMATCH becomes two different
    things. Newtonsoft converting a number to a string is what BSG's own
    server does -- measured on the capture -- so calling it a defect burns a
    cycle on correct data. Only the throwing cases are FATAL.
    """
    ty = declared
    nullable = ty.startswith("Nullable<") or ty.endswith("?")
    if nullable:
        ty = ty[len("Nullable<"):-1] if ty.startswith("Nullable<") else ty[:-1]
    jk = jkind(value)

    if jk == "null":
        if kind == "REF" or nullable:
            return OK, ""
        return FATAL, "null into non-nullable value type %s" % declared

    if ty in BOOL_TYPES:
        if jk == "bool":
            return OK, ""
        if jk == "int" and value in (0, 1):
            return COERCIBLE, "%r into bool -- Newtonsoft accepts 0/1" % value
        if jk == "string" and value.lower() in ("true", "false", "0", "1"):
            return COERCIBLE, "%r into bool -- Newtonsoft parses it" % value
        return FATAL, "%s into bool" % jk
    if ty in NUM_TYPES:
        if jk in ("int", "float"):
            return OK, ""
        if jk == "string" and numeric_string(value):
            return COERCIBLE, "numeric string into %s" % ty
        return FATAL, "%s into %s" % (jk, ty)
    if ty in STR_TYPES:
        if jk == "string":
            return OK, ""
        if jk in ("int", "float", "bool"):
            return COERCIBLE, "%s into string -- Newtonsoft stringifies it" % jk
        return FATAL, "%s into string" % jk
    if ty in UNTYPED:
        return UNKNOWN, "declared type is untyped (%s)" % ty
    return None, ""          # structural: the caller decides from decompose()


# ------------------------------------------------------------- the walker

class Walk(object):
    def __init__(self, r, at, max_depth=8, max_elems=6, max_nodes=400000):
        self.r, self.at = r, at
        self.max_depth, self.max_elems = max_depth, max_elems
        self.max_nodes, self.nodes = max_nodes, 0
        self.rows = []            # (verdict, path, declared, jsonkind, why)
        self.found = 0            # members the payload carried at all
        self.truncated = False
        self._fcache = {}
        self._basecache = {}
        self.downgraded = 0   # FATAL rows BSG's own capture excused

    @property
    def unknown(self):
        return sum(1 for x in self.rows if x[0] == UNKNOWN)

    @property
    def checked(self):
        """Members whose declared type we actually RESOLVED and decided on.

        Derived by subtraction, not counted up: an incrementing counter said
        `552 type-checked / 552 found` on a route that had also emitted 130
        UNKNOWN rows -- a coverage number that could not fall below 100%,
        which is the shape CLAUDE.md 9b is about. A member we could not decide
        is UNKNOWN and is NOT part of the coverage numerator.
        """
        return max(0, self.found - self.unknown)

    # ---- member model, cached: dto_fields is the expensive call
    def members(self, td):
        if td not in self._fcache:
            try:
                flds, _sk = G.dto_fields(self.r, td, self.at, with_tidx=True)
            except Exception as e:
                self._fcache[td] = ("ERR", str(e))
                return self._fcache[td]
            self._fcache[td] = ("OK", flds)
        return self._fcache[td]

    def row(self, verdict, path, declared, jk, why):
        self.rows.append((verdict, path, declared, jk, why))

    def budget(self):
        self.nodes += 1
        if self.nodes > self.max_nodes:
            self.truncated = True
            return False
        return True

    # ---- the descent
    def walk(self, value, tva, path, depth, bsg):
        """`value` is our JSON node, `tva` its DECLARED Il2CppType VA, `bsg`
        the node at the same path in BSG's capture (or None)."""
        if depth > self.max_depth or not self.budget():
            self.truncated = True
            return
        shape, payload = decompose(self.r, tva)
        jk = jkind(value)

        if shape == "class":
            # An ENUM is a class-tagged typedef whose base is System.Enum, and
            # it binds from a NUMBER or from a member name -- so reporting
            # `int into class EMemberCategory` as fatal is a false positive.
            # A non-enum STRUCT (DateTime, Vector3) from a scalar is genuinely
            # undecidable here, because a [JsonConverter] can make it legal;
            # that is UNKNOWN, not FATAL. Both of these were printed as FATAL
            # by the first version of this walker -- 18 ragfair rows and every
            # DateTime on the surface -- which is exactly the "audit disagrees
            # with correct data" trap.
            if self.is_enum(payload):
                if jk in ("int", "string"):
                    return
                if jk == "float":
                    self.row(COERCIBLE, path, self.name(tva), jk,
                             "float into enum %s" % self.name(tva))
                    return
                self.emit(FATAL, path, self.name(tva), jk,
                          "%s into enum %s" % (jk, self.name(tva)), bsg)
                return
            if jk in ("int", "float", "string", "bool") and self.is_struct(payload):
                self.row(UNKNOWN, path, self.name(tva), jk,
                         "%s into struct %s -- legal only with a "
                         "[JsonConverter]; undecidable offline"
                         % (jk, self.name(tva)))
                return
            if jk == "object":
                self.walk_object(value, payload, path, depth, bsg)
            elif jk == "null":
                pass                     # a class member is a reference
            elif jk == "array":
                self.emit(FATAL, path, self.name(tva), jk,
                          "array into class %s" % self.name(tva), bsg)
            else:
                self.emit(FATAL, path, self.name(tva), jk,
                          "%s into class %s -- Newtonsoft cannot convert"
                          % (jk, self.name(tva)), bsg)
        elif shape in ("array", "list"):
            if jk == "array":
                self.walk_array(value, payload, path, depth, bsg)
            elif jk == "null":
                pass
            else:
                self.emit(FATAL, path, self.name(tva), jk,
                          "%s where %s is declared" % (jk, self.name(tva)), bsg)
        elif shape == "map":
            if jk == "object":
                self.walk_map(value, payload, path, depth, bsg)
            elif jk == "null":
                pass
            else:
                self.emit(FATAL, path, self.name(tva), jk,
                          "%s into %s" % (jk, self.name(tva)), bsg)
        elif shape == "generic":
            self.row(UNKNOWN, path, self.name(tva), jk,
                     "generic %s<> is not modelled" % payload)
        else:
            self.row(UNKNOWN, path, self.name(tva), jk,
                     "declared type did not resolve")

    def _base_names(self, td):
        if td in self._basecache:
            return self._basecache[td]
        names, cur, seen = [], td, set()
        while cur is not None and cur not in seen and len(names) < 8:
            seen.add(cur)
            try:
                ns, nm = self.r.tname(cur)
            except Exception:
                break
            names.append((ns + "." + nm) if ns else nm)
            try:
                cur = self.r.parent_type(cur)
            except Exception:
                break
        self._basecache[td] = names
        return names

    def is_enum(self, td):
        return td is not None and "System.Enum" in self._base_names(td)

    def is_struct(self, td):
        n = self._base_names(td)
        return td is not None and "System.ValueType" in n and "System.Enum" not in n

    def name(self, tva):
        try:
            return self.r._typename_va(tva)
        except Exception:
            return "?"

    def walk_object(self, obj, td, path, depth, bsg):
        st, flds = self.members(td)
        if st != "OK":
            self.row(UNKNOWN, path, "?", "object",
                     "member model unavailable: %s" % flds)
            return
        low = {k.lower(): k for k in obj}
        for m in flds:
            n, w, ty, kind = m[0], m[1], m[2], m[3]
            mtidx = m[7] if len(m) > 7 else None
            key = next((low[c.lower()] for c in (w, n)
                        if c and c.lower() in low), None)
            if key is None:
                continue                  # absence is dtogap's question
            self.found += 1
            v = obj[key]
            sub = path + "." + key
            bsub = bsg.get(key) if isinstance(bsg, dict) else None
            verdict, why = classify(ty, kind, v)
            if verdict is not None:
                if verdict == UNKNOWN:
                    self.row(UNKNOWN, sub, ty, jkind(v), why)
                else:

                    if verdict != OK:
                        self.emit(verdict, sub, ty, jkind(v), why, bsub)
                continue
            mtva = tva_of(self.r, mtidx)
            if mtva is None:
                self.row(UNKNOWN, sub, ty, jkind(v),
                         "no Il2CppType index for this member")
                continue

            self.walk(v, mtva, sub, depth + 1, bsub)

    def walk_array(self, arr, elem_va, path, depth, bsg):
        """First N elements, plus every element whose SHAPE differs from
        element 0 -- a heterogeneous array is itself a finding, and checking
        only element 0 is how a 4000-element array hides one bad row."""
        if not arr:
            return
        sig0 = self.sig(arr[0])
        idx = list(range(min(len(arr), self.max_elems)))
        # Two different things, deliberately not conflated. A differing KEY SET
        # is normal -- Newtonsoft omits null/default members -- so it is a
        # reason to WALK that element (it carries members element 0 does not),
        # never a finding. A differing JSON KIND in one array is a finding:
        # nothing can deserialize a mixed array into T[].
        odd = [i for i in range(len(arr)) if self.sig(arr[i]) != sig0]
        kinds = {jkind(x) for x in arr}
        if len(kinds) > 1:
            self.row(HETERO, path, "%s[]" % self.name(elem_va), "array",
                     "HETEROGENEOUS: %d elements span JSON kinds %s"
                     % (len(arr), "/".join(sorted(kinds))))
        if odd:
            idx += odd[:self.max_elems]
        for i in sorted(set(idx)):
            b = None
            if isinstance(bsg, list) and bsg:
                b = bsg[i] if i < len(bsg) else bsg[0]
            self.walk(arr[i], elem_va, "%s[%d]" % (path, i), depth + 1, b)

    def walk_map(self, obj, val_va, path, depth, bsg):
        keys = list(obj)
        if not keys:
            return
        sig0 = self.sig(obj[keys[0]])
        take = keys[:self.max_elems]
        odd = [k for k in keys if self.sig(obj[k]) != sig0]
        kinds = {jkind(obj[k]) for k in keys}
        if len(kinds) > 1:
            self.row(HETERO, path, "Dictionary<,%s>" % self.name(val_va),
                     "object", "HETEROGENEOUS: %d values span JSON kinds %s"
                     % (len(keys), "/".join(sorted(kinds))))
        if odd:
            take += odd[:self.max_elems]
        for k in dict.fromkeys(take):
            # A Dictionary's KEYS are data (item ids, hideout stage numbers),
            # so BSG's capture almost never holds the same ones we serve.
            # Looking up our key and finding nothing made the BSG falsifier
            # go silent on exactly the routes it mattered most for -- the six
            # `barter_scheme` rows and the eight `stages` rows below were all
            # reported FATAL while BSG's own capture sends the identical
            # shape. Any sibling value has the same DECLARED type, so it
            # answers the only question being asked: what JSON KIND does the
            # real server put here?
            b = None
            if isinstance(bsg, dict):
                b = bsg.get(k)
                if b is None and bsg:
                    b = bsg[next(iter(bsg))]
            self.walk(obj[k], val_va, "%s.%s" % (path, k), depth + 1, b)

    @staticmethod
    def sig(v):
        if isinstance(v, dict):
            return ("object",) + tuple(sorted(v))
        return (jkind(v),)

    # ---- THE FALSIFIER FOR THIS TOOL ITSELF
    def emit(self, verdict, path, declared, jk, why, bsg):
        """A FATAL that BSG's own capture also sends is not our defect.

        Container positions, /client/weather and getMainQuestNotesList each
        nearly cost a "fix" to correct data. If the captured BSG response
        carries the SAME JSON kind at this path, the row is downgraded and
        says what it really falsifies: the DTO mapping.
        """
        if verdict == FATAL and bsg is not None and jkind(bsg) == jk:
            self.downgraded += 1
            self.row(UNKNOWN, path, declared, jk,
                     "BSG's own capture sends %s here too -- this falsifies "
                     "the DTO mapping, not our payload" % jk)
            return
        self.row(verdict, path, declared, jk, why)
