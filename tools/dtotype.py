"""dtotype.py -- does the JSON TYPE we emit agree with the type the client DECLARES?

## The hole this closes

`oursample.py`/`dtogap.py` answer "is this member PRESENT?". They never look at
the member's VALUE. That blind spot shipped a live crash: `/client/mail/dialog/list`
emitted `"systemData": false`, the client's `DialogueChatMessageSerializer` declares
that member as `ChatMessageSystemData` (a class, measured with tools/fldoff.py), and
Newtonsoft threw

    Could not cast or convert from System.Boolean to ChatShared.ChatMessageSystemData

inside ExecuteRequest -- which does not fail the inbox, it kills the raid load.
Presence was perfect. The TYPE was wrong. Nothing we had could see it.

## The check, and how it can FAIL

For every member the client would bind (dtogap's property-aware member model,
[JsonProperty] renames included), the emitted JSON value is classified and
compared with the declared type. Three verdicts, never two:

  MISMATCH  the value can NOT deserialize into the declared type. This is the
            crash class: bool/number/string into a class, null into a
            non-nullable value type, object into an array.
  OK        it can.
  UNKNOWN   we cannot decide (unmapped/generic/interface/object declared type,
            or a member the payload does not carry). NOT a pass.

Only MISMATCH is asserted on, and every MISMATCH names the falsifying value, so
a wrong verdict here is visible rather than plausible.

Usage:
    python tools/dtotype.py --sample S.json --dto TypeName [--path data]
    python tools/dtotype.py --manifest <oursample ours-manifest.json>
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dtogap as G                                   # noqa: E402

MISMATCH, OK, UNKNOWN = "MISMATCH", "OK", "UNKNOWN"

INT_TYPES = {"int", "long", "short", "byte", "sbyte", "uint", "ulong",
             "ushort", "Int32", "Int64", "Int16", "Byte", "UInt32", "UInt64"}
NUM_TYPES = INT_TYPES | {"float", "double", "decimal", "Single", "Double"}
BOOL_TYPES = {"bool", "Boolean"}
STR_TYPES = {"string", "String", "MongoID", "MongoId"}


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


def is_collection(ty):
    return (ty.endswith("[]") or ty.startswith("List<") or ty.startswith("IList<")
            or ty.startswith("HashSet<") or ty.startswith("IEnumerable<")
            or ty.startswith("IReadOnlyList<"))


def is_map(ty):
    return (ty.startswith("Dictionary<") or ty.startswith("IDictionary<")
            or ty.startswith("IReadOnlyDictionary<"))


def classify(declared, kind, value):
    """(verdict, why). `kind` is dtogap's VALUE/REF tag on the declared type."""
    ty = declared
    nullable = ty.startswith("Nullable<") or ty.endswith("?")
    if nullable:
        ty = ty[len("Nullable<"):-1] if ty.startswith("Nullable<") else ty[:-1]
    jk = jkind(value)

    if jk == "null":
        if kind == "REF" or nullable:
            return OK, "null into a reference/nullable member"
        return MISMATCH, "null into non-nullable value type %r" % declared

    if ty in BOOL_TYPES:
        return (OK, "") if jk == "bool" else (MISMATCH, "%s into bool" % jk)
    if ty in INT_TYPES:
        return (OK, "") if jk in ("int", "float") else (MISMATCH, "%s into %s" % (jk, ty))
    if ty in NUM_TYPES:
        return (OK, "") if jk in ("int", "float") else (MISMATCH, "%s into %s" % (jk, ty))
    if ty in STR_TYPES:
        # Newtonsoft will happily read a number/bool into a string.
        return (OK, "") if jk in ("string", "int", "float", "bool") \
            else (MISMATCH, "%s into string" % jk)
    if ty in ("object", "Object", "JObject", "JToken", "JsonElement"):
        return UNKNOWN, "declared type is untyped (%s)" % ty
    if is_collection(ty) or is_map(ty):
        if is_map(ty):
            return (OK, "") if jk == "object" else (MISMATCH, "%s into %s" % (jk, ty))
        return (OK, "") if jk == "array" else (MISMATCH, "%s into %s" % (jk, ty))
    if "<" in ty:
        return UNKNOWN, "generic declared type %s" % ty
    if kind == "VALUE":
        # enum or struct. Enums bind from a number or a name; a struct needs an
        # object -- and we cannot tell them apart from the typename alone.
        if jk in ("int", "string", "object", "float"):
            return UNKNOWN, "value type %s from %s (enum-or-struct)" % (ty, jk)
        return MISMATCH, "%s into value type %s" % (jk, ty)
    # a plain class: THE CRASH CLASS.
    if jk in ("object",):
        return OK, ""
    if jk == "array":
        return MISMATCH, "array into class %s" % ty
    return MISMATCH, "%s into class %s -- Newtonsoft cannot convert" % (jk, ty)


def at_path(doc, jpath):
    for part in [p for p in jpath.split(".") if p]:
        if isinstance(doc, list):
            try:
                doc = doc[int(part)]
            except (ValueError, IndexError):
                return None
        elif isinstance(doc, dict):
            if part not in doc:
                return None
            doc = doc[part]
        else:
            return None
    return doc


def sweep(r, at, dto, obj):
    """[(verdict, member, wire, declared, jsonkind, why)] -- one row per member
    the payload actually CARRIES. Members it does not carry are dtogap's job."""
    t = r.find_one(dto)
    flds, _sk = G.dto_fields(r, t, at)
    low = {k.lower(): k for k in obj.keys()}
    rows = []
    for n, w, ty, kind, _dec, _st, _o in flds:
        cands = [c for c in (w, n) if c]
        key = next((low[c.lower()] for c in cands if c.lower() in low), None)
        if key is None:
            continue
        v = obj[key]
        verdict, why = classify(ty, kind, v)
        rows.append((verdict, n, key, ty, jkind(v), why))
    return rows


def bsg_kind(route, jpath, key):
    """What JSON kind BSG's OWN capture put at this key, or None.

    This is the falsifier for the tool itself. `/client/weather` reported
    MISMATCH `weather` object into `WeatherNode[]` -- and BSG's captured
    weather body (raid1/responses/131.json) sends an OBJECT there too. A shape
    BSG itself serves to this client is not our type error; it falsifies the
    DTO/[JsonProperty] mapping instead. Such a row is downgraded to UNKNOWN and
    says so, rather than being printed as a defect we do not have.
    """
    try:
        p = G.find_capture(route)
    except Exception:
        return None
    if not p or not os.path.exists(p):
        return None
    try:
        with open(p, encoding="utf-8", errors="replace") as f:
            doc = json.load(f)
    except (ValueError, OSError):
        return None
    o = at_path(doc, jpath or "data")
    if isinstance(o, list):
        o = o[0] if o else None
    if not isinstance(o, dict):
        return None
    low = {k.lower(): k for k in o}
    k = low.get(key.lower())
    return None if k is None else jkind(o[k])


def run_one(r, at, label, obj, dto, route=None, jpath=None):
    if not isinstance(obj, dict):
        print("%-11s %s  (no object to check)" % (UNKNOWN, label))
        return 0
    rows = sweep(r, at, dto, obj)
    bad, suppressed = [], []
    for x in rows:
        if x[0] != MISMATCH:
            continue
        same = bsg_kind(route, jpath, x[2]) if route else None
        if same == x[4]:
            suppressed.append(x)
        else:
            bad.append(x)
    for v, n, k, ty, jk, why in suppressed:
        print("  UNKNOWN   %-28s wire=%-24s declared=%-32s emitted=%s  BSG's own "
              "capture sends %s here too -- the DTO mapping is what this "
              "falsifies, not our payload" % (n, k, ty, jk, jk))
    unk = [x for x in rows if x[0] == UNKNOWN]
    for v, n, k, ty, jk, why in bad:
        print("  MISMATCH  %-28s wire=%-24s declared=%-32s emitted=%s  %s"
              % (n, k, ty, jk, why))
    print("%-11s %s  DTO=%s  %d members checked, %d MISMATCH, %d UNKNOWN"
          % ("FAIL" if bad else "PASS", label, dto, len(rows), len(bad), len(unk)))
    return len(bad)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sample")
    ap.add_argument("--dto")
    ap.add_argument("--path", default="data")
    ap.add_argument("--manifest")
    a = ap.parse_args()
    from il2cpp_resolve import Resolver
    import il2cpp_attrs
    r = Resolver(G.GAMEASM, G.METADEC)
    G.selfcheck(r)
    at = il2cpp_attrs.selfcheck(r)
    G.member_selfcheck(r, at)
    bad = 0
    if a.sample:
        if not a.dto:
            raise SystemExit("INCONCLUSIVE: --sample needs --dto")
        with open(a.sample, encoding="utf-8", errors="replace") as f:
            doc = json.load(f)
        obj = at_path(doc, a.path)
        if isinstance(obj, list):
            obj = obj[0] if obj else None
        if obj is None:
            raise SystemExit("INCONCLUSIVE: nothing at --path %r in %s"
                             % (a.path, a.sample))
        bad = run_one(r, at, a.sample, obj, a.dto)
    elif a.manifest:
        with open(a.manifest, encoding="utf-8") as f:
            man = json.load(f)
        root = os.path.dirname(os.path.abspath(a.manifest))
        for e in man.get("entries", []):
            route = e["route"]
            ent = G.ROUTES.get(route)
            dto = ent[0] if ent else None
            if not dto:
                print("%-11s %s  no DTO mapped -- TYPES NOT CHECKED" % (UNKNOWN, route))
                continue
            p = os.path.join(root, e["sample"])
            if not os.path.exists(p):
                print("%-11s %s  sample missing" % (UNKNOWN, route))
                continue
            with open(p, encoding="utf-8", errors="replace") as f:
                try:
                    doc = json.load(f)
                except ValueError:
                    print("%-11s %s  sample is not JSON" % (UNKNOWN, route))
                    continue
            obj = at_path(doc, e.get("path") or "data")
            if isinstance(obj, list):
                obj = obj[0] if obj else None
            if not isinstance(obj, dict):
                print("%-11s %s  nothing to check at %r" % (UNKNOWN, route, e.get("path")))
                continue
            bad += run_one(r, at, route, obj, dto, route, e.get("path") or "data")
    else:
        raise SystemExit("give --sample/--dto or --manifest")
    print("---- %d MISMATCH total" % bad)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
