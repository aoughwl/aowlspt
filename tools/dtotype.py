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
import dtodeep as D                                  # noqa: E402

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


def bsg_kind(route, jpath, key, dto=None):
    """What JSON kind BSG's OWN capture put at this key, or None.

    This is the falsifier for the tool itself. `/client/weather` reported
    MISMATCH `weather` object into `WeatherNode[]` -- and BSG's captured
    weather body (raid1/responses/131.json) sends an OBJECT there too. A shape
    BSG itself serves to this client is not our type error; it falsifies the
    DTO/[JsonProperty] mapping instead. Such a row is downgraded to UNKNOWN and
    says so, rather than being printed as a defect we do not have.

    ## AN EMPTY FIRST BODY SILENTLY DISABLED THIS FALSIFIER

    This used to call `G.find_capture`, which returns the FIRST captured body
    for the route. For `/client/game/profile/list` that is seq 083, captured
    before a profile existed, so `data` is an EMPTY LIST -- `o` came out None
    and the function returned None, which the caller reads as "BSG never sent
    this key", which is indistinguishable from "BSG sent a different kind".
    dtogap.find_captures was fixed for exactly this and documents it in its own
    docstring; this consumer was left on the old accessor and so reproduced the
    bug it warns about. It now walks EVERY captured body in manifest order and
    uses the first one that actually carries the key.

    Returning None still means "no evidence", and no evidence is not an
    excusal: the caller keeps the FATAL. What changed is that an empty body no
    longer counts as evidence of absence.
    """
    try:
        paths = list(G.find_captures(route) or [])
    except Exception:
        return None
    # ## THE EVIDENCE BELONGS TO THE DTO, NOT TO THE ROUTE
    #
    # /client/game/bot/generate deserializes into EFT.ProfileDescriptor, and
    # raid1 captured no bot/generate body at all -- so route-keyed lookup found
    # nothing and printed 7 FATAL rows (.Inventory.equipment/stash/
    # questRaidItems/questStashItems/sortingTable "string into ItemDescriptor",
    # and .Stats.Eft.DamageHistory.BodyParts "array into Dictionary").
    # /client/game/profile/list uses THE SAME DTO and IS captured, five times:
    # every one of 096/208/273/398/472 sends `equipment` as a bare string, and
    # three of the five send `BodyParts` as an array. Our payload is byte-shaped
    # like BSG's. All 7 were the audit being wrong, for the fifth time.
    #
    # A shape BSG serves for a DTO is evidence about THAT DTO wherever it
    # appears. Same-route captures are still tried FIRST, so a route with its
    # own evidence is never overruled by a sibling's.
    if dto:
        for other, ent in sorted(G.ROUTES.items()):
            if other == route or ent[0] != dto:
                continue
            try:
                paths.extend(G.find_captures(other) or [])
            except Exception:
                pass
    for p in paths:
        if not p or not os.path.exists(p):
            continue
        try:
            with open(p, encoding="utf-8", errors="replace") as f:
                doc = json.load(f)
        except (ValueError, OSError):
            continue
        o = at_path(doc, jpath or "data")
        if isinstance(o, list):
            o = o[0] if o else None
        if not isinstance(o, dict):
            continue          # empty/absent body: NO evidence, not evidence of absence
        low = {k.lower(): k for k in o}
        k = low.get(key.lower())
        if k is not None:
            return jkind(o[k])
    return None


def run_one(r, at, label, obj, dto, route=None, jpath=None):
    if not isinstance(obj, dict):
        print("%-11s %s  (no object to check)" % (UNKNOWN, label))
        return 0
    rows = sweep(r, at, dto, obj)
    bad, suppressed = [], []
    for x in rows:
        if x[0] != MISMATCH:
            continue
        same = bsg_kind(route, jpath, x[2], dto) if route else None
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



# ---------------------------------------------------------------- the deep walk
#
# The top-level sweep above could not see `globals.config.MainQuest`, and that
# is where MainQuestSettings -- one of four crash-class bugs found by reading
# the client's error log instead of by this tool -- actually lived. dtodeep
# descends; this is the reporting shell around it.

_CAPCACHE = {}


def capture_doc(route, jpath, dto=None):
    """BSG's own captured body for `route`, positioned at `jpath`.

    ## THE EVIDENCE BELONGS TO THE DTO, NOT ONLY TO THE ROUTE

    /client/game/bot/generate deserializes into EFT.ProfileDescriptor and raid1
    captured NO bot/generate body at all, so this returned None and the deep
    walk printed 7 FATAL rows with `0 BSG-excused`:
    `.Inventory.equipment|stash|questRaidItems|questStashItems|sortingTable`
    as "string into class ItemDescriptor", plus
    `.Stats.Eft.DamageHistory.BodyParts` as "array into Dictionary".
    /client/game/profile/list uses THE SAME DTO and is captured five times --
    096, 208, 273, 398, 472 -- and every one of them sends `equipment` as a
    bare string; three of the five send `BodyParts` as an array. Our payload is
    shaped exactly like BSG's, so all 7 were the audit being wrong, which is
    now the FIFTH time (container positions, /client/weather,
    getMainQuestNotesList, 152 nested rows, and these).

    A shape BSG serves for a DTO is evidence about that DTO wherever it
    appears. The route's OWN captures are still tried first and win outright;
    a sibling route sharing the DTO is only consulted when the route itself has
    no usable body. No capture anywhere still returns None, and None still
    means "no evidence" -- the FATAL is kept.
    """
    if route in _CAPCACHE:
        return _CAPCACHE[route]
    # The FIRST capture for a route can be empty -- seq 083 for
    # /client/game/profile/list was recorded before a profile existed -- and an
    # empty falsifier is indistinguishable from an absent one, which is how
    # five correct `Inventory.*` members got reported FATAL. Take the first
    # capture that actually has something at `jpath`.
    paths = list(G.find_captures(route) or [])
    if dto:
        for other, ent in sorted(G.ROUTES.items()):
            if other != route and ent[0] == dto:
                paths.extend(G.find_captures(other) or [])
    doc = None
    for p in paths:
        try:
            with open(p, encoding="utf-8", errors="replace") as f:
                d = at_path(json.load(f), jpath or "data")
        except (ValueError, OSError):
            continue
        if isinstance(d, list):
            d = d[0] if d else None
        if isinstance(d, dict) and d:
            doc = d
            break
    _CAPCACHE[route] = doc
    return doc


def deep_one(r, at, label, obj, dto, route=None, jpath="data",
             depth=8, elems=6, verbose=False):
    """(fatal-rows, checked, found, truncated)."""
    t = r.find_one(dto)
    if t is None:
        print("UNKNOWN     %s  DTO %s did not resolve -- NOT type-checked"
              % (label, dto))
        return [], 0, 0, False, 0
    w = D.Walk(r, at, max_depth=depth, max_elems=elems)
    bsg = capture_doc(route, jpath, dto) if route else None
    if isinstance(bsg, list):
        bsg = bsg[0] if bsg else None
    w.walk_object(obj, t, "", 0, bsg)
    fatal = [x for x in w.rows if x[0] == D.FATAL]
    hetero = [x for x in w.rows if x[0] == D.HETERO]
    unk = [x for x in w.rows if x[0] == D.UNKNOWN]
    coer = [x for x in w.rows if x[0] == D.COERCIBLE]
    for v, path, decl, jk, why in fatal:
        print("  FATAL     %-52s declared=%-28s emitted=%s  %s"
              % (path or "<root>", decl, jk, why))
    for v, path, decl, jk, why in hetero:
        print("  HETERO    %-52s %s" % (path or "<root>", why))
    if verbose:
        for v, path, decl, jk, why in coer + unk:
            print("  %-9s %-52s declared=%-28s emitted=%s  %s"
                  % (v, path or "<root>", decl, jk, why))
    print("%-11s %-46s DTO=%s  %d members type-checked / %d found, "
          "%d FATAL, %d COERCIBLE, %d UNKNOWN, %d BSG-excused%s"
          % ("FAIL" if fatal else ("INCONCL." if w.truncated else "PASS"),
             label, dto.split(".")[-1], w.checked, w.found, len(fatal),
             len(coer), len(unk), w.downgraded,
             ", TRUNCATED" if w.truncated else ""))
    return fatal + hetero, w.checked, w.found, w.truncated, w.downgraded


def selftest(r, at, manifest):
    """Can the recursive walk actually go RED, and does it go red BELOW the
    top level? A sweep that reports 0 FATAL is worth nothing until this
    passes, because 0 is also what a walk that never descends prints.

    Three plants at NESTED paths in a real served payload, one per fatal
    class. Each must be caught, and the row's path must be more than one
    component deep -- otherwise the walk found it at the top level and proved
    nothing about nesting.
    """
    with open(manifest, encoding="utf-8") as f:
        man = json.load(f)
    root = os.path.dirname(os.path.abspath(manifest))
    ent = next((e for e in man.get("entries", [])
                if e["route"] == "/client/globals"), None)
    if ent is None:
        print("INCONCLUSIVE: the manifest has no /client/globals entry")
        return 2
    with open(os.path.join(root, ent["sample"]), encoding="utf-8") as f:
        base = at_path(json.load(f), ent.get("path") or "data")
    dto = G.ROUTES["/client/globals"][0]
    t = r.find_one(dto)

    def find_nested(pred, node, path, depth=0):
        if depth > 3 or not isinstance(node, dict):
            return None
        for k, v in node.items():
            if depth > 0 and pred(v):
                return path + [k]
            got = find_nested(pred, v, path + [k], depth + 1)
            if got:
                return got
        return None

    plants = [
        ("array into a declared class",
         lambda v: isinstance(v, dict) and bool(v), lambda v: [{"x": 1}]),
        ("string into a declared number",
         lambda v: isinstance(v, (int, float)) and not isinstance(v, bool),
         lambda v: "not a number at all"),
        ("object into a declared array",
         lambda v: isinstance(v, list) and bool(v), lambda v: {"x": 1}),
    ]
    bad = 0
    for label, pred, make in plants:
        doc = json.loads(json.dumps(base))
        where = find_nested(pred, doc, [])
        if where is None or len(where) < 2:
            print("INCONCLUSIVE  %-34s no nested site to plant it at" % label)
            bad += 1
            continue
        node = doc
        for k in where[:-1]:
            node = node[k]
        node[where[-1]] = make(node[where[-1]])
        w = D.Walk(r, at)
        w.walk_object(doc, t, "", 0, None)      # no BSG falsifier: the plant
        hits = [x for x in w.rows                # is ours, not BSG's
                if x[0] in (D.FATAL, D.COERCIBLE)
                and x[1] == "." + ".".join(where)]
        deep = [x for x in hits if x[1].count(".") > 1]
        if deep:
            print("PASS          %-34s caught at %s" % (label, deep[0][1]))
        else:
            print("FAIL          %-34s planted at .%s and NOT reported -- the "
                  "walk is not descending" % (label, ".".join(where)))
            bad += 1
    print("---- selftest: %s" % ("FAIL" if bad else
                                 "PASS, the walk can go red below the top level"))
    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sample")
    ap.add_argument("--dto")
    ap.add_argument("--path", default="data")
    ap.add_argument("--manifest")
    ap.add_argument("--selftest", action="store_true",
                    help="plant a known-bad value at a NESTED path in a real "
                         "sample and prove the walk reports it. 0 FATAL means "
                         "nothing until this passes.")
    ap.add_argument("--shallow", action="store_true",
                    help="the pre-2026-08-27 behaviour: check ONLY the "
                         "top-level members. Every nested member goes "
                         "unaudited, which is where the last four "
                         "crash-class bugs were.")
    ap.add_argument("--depth", type=int, default=8)
    ap.add_argument("--elems", type=int, default=6,
                    help="array/dictionary elements examined per node, on top "
                         "of every element whose SHAPE differs from the first")
    ap.add_argument("-v", "--verbose", action="store_true",
                    help="also print COERCIBLE and UNKNOWN rows")
    a = ap.parse_args()
    from il2cpp_resolve import Resolver
    import il2cpp_attrs
    r = Resolver(G.GAMEASM, G.METADEC)
    G.selfcheck(r)
    at = il2cpp_attrs.selfcheck(r)
    G.member_selfcheck(r, at)
    bad = checked = found = routes_deep = excused = 0
    unmapped, truncated = [], []
    if a.selftest:
        if not a.manifest:
            raise SystemExit("INCONCLUSIVE: --selftest needs --manifest")
        return selftest(r, at, a.manifest)
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
        if a.shallow:
            bad = run_one(r, at, a.sample, obj, a.dto)
        else:
            rows, ck, fd, _tr, _dg = deep_one(r, at, a.sample, obj, a.dto,
                                         None, a.path, a.depth, a.elems,
                                         a.verbose)
            bad, checked, found = len(rows), ck, fd
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
                unmapped.append(route)
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
            if a.shallow:
                bad += run_one(r, at, route, obj, dto, route,
                               e.get("path") or "data")
            else:
                rows, ck, fd, tr, dg = deep_one(r, at, route, obj, dto, route,
                                            e.get("path") or "data",
                                            a.depth, a.elems, a.verbose)
                bad += len(rows)
                checked += ck
                found += fd
                routes_deep += 1
                excused += dg
                if tr:
                    truncated.append(route)
    else:
        raise SystemExit("give --sample/--dto or --manifest")
    if a.shallow:
        print("---- %d MISMATCH total (TOP LEVEL ONLY -- every nested member "
              "went unaudited)" % bad)
        return 1 if bad else 0
    print("---- %d FATAL/HETERO total across %d routes walked recursively"
          % (bad, routes_deep))
    print("---- coverage: %d nested members TYPE-CHECKED out of %d the "
          "payloads carry; %d are UNKNOWN, which is NOT a pass"
          % (checked, found, found - checked))
    print("---- %d row(s) would have been FATAL but BSG's OWN CAPTURE sends "
          "the same JSON kind at that exact path -- those falsify the DTO "
          "mapping, not our payload. 0 FATAL with a large number here is "
          "NOT the same claim as 0 FATAL with none." % excused)
    if unmapped:
        print("---- %d routes have no DTO mapped and were NOT checked at all: "
              "%s" % (len(unmapped), ", ".join(unmapped)))
    if truncated:
        print("---- INCONCLUSIVE on %d route(s) -- the node budget ran out "
              "before the walk finished: %s"
              % (len(truncated), ", ".join(truncated)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
