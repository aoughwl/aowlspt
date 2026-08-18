## The high-level backend API — the server half of the pipeline.
##
## Deliberately the same shape as `aowlspt/game`. A mod author moving between
## the two should be changing what they reach for, not how they write:
##
##     # client
##     var Player = gameType("EFT.Player")
##     discard Player.invoke("Heal", 50)
##
##     # server
##     discard get "/aowlspt/status":
##       json {"ok": true}
##
## What this wraps is `route_register`, `db_get`/`db_patch` and `config_get`.
## Underneath it is the same ABI the client uses, which is why one mod binary
## can serve both sides with a `side()` guard.

import std/strutils
import ".." / aowlspt

# ---------------------------------------------------------------------------
# Building JSON without a JSON library
# ---------------------------------------------------------------------------
#
# A backend route returns text, and almost all of that text is small objects
# assembled from a handful of values. A document model would be more machinery
# than the job needs; what it does need is to never produce invalid JSON by
# accident, which is what the escaping here is for.

type
  Json* = object
    text*: string

proc raw*(s: string): Json =
  ## Text that is already JSON. The escape hatch, and the one place a mod can
  ## produce something malformed.
  Json(text: s)

proc escapeText*(s: string): string =
  result = ""
  for ch in s:
    case ch
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    else:
      if ord(ch) < 0x20:
        # Control characters are not legal raw in a JSON string, and a mod
        # echoing one back from a request body would otherwise produce a
        # document the client silently fails to parse.
        result.add "\\u00"
        const hex = "0123456789abcdef"
        result.add hex[(ord(ch) shr 4) and 0xF]
        result.add hex[ord(ch) and 0xF]
      else:
        result.add ch

proc jstr*(s: string): Json = Json(text: "\"" & escapeText(s) & "\"")
proc jint*(i: int): Json = Json(text: $i)
proc jfloat*(f: float): Json = Json(text: $f)
proc jbool*(b: bool): Json = Json(text: (if b: "true" else: "false"))
proc jnull*(): Json = Json(text: "null")

type
  JsonObject* = object
    parts: seq[string]

proc obj*(): JsonObject = JsonObject(parts: @[])

proc put*(o: var JsonObject; key: string; value: Json) =
  o.parts.add "\"" & escapeText(key) & "\":" & value.text

proc put*(o: var JsonObject; key, value: string) = put(o, key, jstr(value))
proc put*(o: var JsonObject; key: string; value: int) = put(o, key, jint(value))
proc put*(o: var JsonObject; key: string; value: float) = put(o, key, jfloat(value))
proc put*(o: var JsonObject; key: string; value: bool) = put(o, key, jbool(value))

proc done*(o: JsonObject): Json =
  var s = "{"
  for i in 0 ..< o.parts.len:
    if i > 0: s.add ","
    s.add o.parts[i]
  s.add "}"
  result = Json(text: s)

proc text*(j: Json): string = j.text

proc okJson*(): string = "{\"ok\":true}"
proc errJson*(message: string): string =
  "{\"ok\":false,\"err\":\"" & escapeText(message) & "\"}"

# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

type
  Handler* = proc (url, body, session: string): string

proc serve*(url: string; handler: Handler): Status =
  ## An exact-match route.
  result = route(url, rkStatic, handler)

proc servePrefix*(prefix: string; handler: Handler): Status =
  ## A prefix route: everything under `prefix` reaches this handler, which reads
  ## the rest out of the `url` it is given. The client's endpoints carry ids in
  ## the path, so this is how most real routes are written.
  result = route(prefix, rkDynamic, handler)

proc pathAfter*(url, prefix: string): string =
  ## The part of `url` past `prefix`, for a prefix route.
  if url.len <= prefix.len:
    return ""
  result = url.substr(prefix.len)

# ---------------------------------------------------------------------------
# The database
# ---------------------------------------------------------------------------

type
  DbValue* = object
    ok*: bool
    raw*: string
    error*: string

proc dbRead*(path: string): DbValue =
  ## Reads a dotted path out of the loaded database.
  var out1 = ""
  let st = dbGet(path, out1)
  if st == Ok:
    result = DbValue(ok: true, raw: out1, error: "")
  else:
    result = DbValue(ok: false, raw: "", error: lastError())

proc asText*(v: DbValue): string =
  if v.raw.len >= 2 and v.raw[0] == '"' and v.raw[v.raw.len - 1] == '"':
    result = v.raw.substr(1, v.raw.len - 2)
  else:
    result = v.raw

proc asFloat*(v: DbValue; default: float = 0.0): float =
  result = default
  if not v.ok or v.raw.len == 0:
    return
  var whole = 0.0
  var frac = 0.0
  var scale = 0.1
  var neg = false
  var seenDot = false
  var any = false
  var i = 0
  if v.raw[0] == '-':
    neg = true
    i = 1
  while i < v.raw.len:
    let ch = v.raw[i]
    if ch >= '0' and ch <= '9':
      any = true
      if seenDot:
        frac = frac + float(ord(ch) - ord('0')) * scale
        scale = scale * 0.1
      else:
        whole = whole * 10.0 + float(ord(ch) - ord('0'))
    elif ch == '.' and not seenDot:
      seenDot = true
    else:
      return default
    inc i
  if not any:
    return default
  let value = whole + frac
  result = (if neg: -value else: value)

proc asInt*(v: DbValue; default: int = 0): int =
  result = int(asFloat(v, float(default)))

proc dbWrite*(path: string; patch: Json): Status =
  ## Merges `patch` into the object at `path`.
  ##
  ## A merge, not a replace: two mods editing sibling fields of the same item
  ## must not clobber one another. That is the difference between a mod system
  ## and a pile of mods that happen to coexist.
  result = dbPatch(path, patch.text)

proc dbWrite*(path, patchJson: string): Status =
  result = dbPatch(path, patchJson)

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

type
  ConfigValue* = object
    ok*: bool
    raw*: string

proc setting*(key: string): ConfigValue =
  var out1 = ""
  if configGet(key, out1) == Ok:
    result = ConfigValue(ok: true, raw: out1)
  else:
    result = ConfigValue(ok: false, raw: "")

proc asText*(c: ConfigValue; default: string = ""): string =
  if c.ok: c.raw else: default

proc asFloat*(c: ConfigValue; default: float = 0.0): float =
  if not c.ok:
    return default
  var v = DbValue(ok: true, raw: c.raw, error: "")
  result = asFloat(v, default)

proc asInt*(c: ConfigValue; default: int = 0): int =
  result = int(asFloat(c, float(default)))

proc asBool*(c: ConfigValue; default: bool = false): bool =
  if not c.ok: return default
  if c.raw == "true": return true
  if c.raw == "false": return false
  result = default
