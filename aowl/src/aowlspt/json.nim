## Reading JSON, for mods.
##
##     let name = body.field("Info.Nickname").asText
##     let n    = body.field("items").count
##     for it in body.field("items").each:
##       echo it.field("_id").asText
##
## A mod on either side spends most of its time reading a document it did not
## build: a request body, a template out of the database, its own saved state.
## Without this it would either hand-scan strings or pull in a parser, and the
## first is what produces the class of bug where a nested `"_id"` is mistaken
## for the outer one.
##
## **It scans; it does not build a tree.** A `JsonRef` is a pair of offsets into
## text somebody else owns, so `field` costs a walk of the document and nothing
## else — no allocation, no copy, and no lifetime to think about beyond the text
## it came from. That is the right trade for the access pattern here (a handful
## of paths out of each body) and the wrong one for walking a 40MB item table
## field by field, which is what `count`/`each` exist to avoid needing.
##
## Paths are dotted, with `[n]` for array elements:
##
##     "Info.Nickname"          "items[0]._id"          "data[2].Slots[1]"
##
## A key containing a dot is reachable with `child`, one step at a time. That is
## deliberate: an escaping rule inside the path syntax would be one more thing
## to get wrong at a call site that reads fine.
## **Error semantics:** `field`, `child`, and `at` return `notFound` in two
## cases: (1) a step in the path does not exist, or (2) the path navigation
## was incorrect (mismatched braces, reached array boundary, etc). The API does
## not distinguish these two cases. Callers should validate document structure
## before relying on specific paths; use `exists()` to check if a reference was
## found. Reading a notFound ref is safe (returns empty string or default values)
## and will not crash, but confidently reading a default value as if it were the
## actual data is a silent failure. This is intentional: distinguishing "absent"
## from "mis-navigated" would require a three-value result type, making every
## call site more verbose.

import std/strutils

type
  JsonRef* = object
    ## A view of one JSON value inside `text`. `found` distinguishes "the path
    ## is not there" from "the path is there and holds null", which is a
    ## distinction the game's own bodies rely on.
    text*: string
    first*: int   ## index of the value's first character
    last*: int    ## index of its last character, inclusive
    found*: bool

func notFound*(): JsonRef =
  JsonRef(text: "", first: 0, last: -1, found: false)

# --------------------------------------------------------------- scanning

proc skipWs(s: string; i: var int) =
  while i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\n' or
                       s[i] == '\r'):
    inc i

proc skipString(s: string; i: var int): bool =
  ## `i` is at the opening quote; leaves it just past the closing one. Escapes
  ## are stepped over two characters at a time, which is what keeps a `\"`
  ## inside a value from ending it.
  if i >= s.len or s[i] != '"':
    return false
  inc i
  while i < s.len:
    if s[i] == '\\':
      i = i + 2
      continue
    if s[i] == '"':
      inc i
      return true
    inc i
  result = false

proc skipValue(s: string; i: var int): bool =
  ## Leaves `i` one past a complete value. Depth-counting rather than parsing:
  ## the question is where the value ends, not what it means.
  skipWs(s, i)
  if i >= s.len:
    return false
  case s[i]
  of '"':
    return skipString(s, i)
  of '{', '[':
    var depth = 0
    while i < s.len:
      let c = s[i]
      if c == '"':
        if not skipString(s, i):
          return false
        continue
      if c == '{' or c == '[':
        inc depth
      elif c == '}' or c == ']':
        dec depth
        if depth == 0:
          inc i
          return true
      inc i
    return false
  else:
    while i < s.len and s[i] != ',' and s[i] != '}' and s[i] != ']':
      inc i
    return true

proc unquote(s: string): string =
  ## The JSON string escapes, decoded. `\u` is decoded for the ASCII range and
  ## otherwise left as written -- a mod reading a Cyrillic locale string gets
  ## the escape rather than a wrong character, which is visible instead of
  ## silently mangled.
  result = ""
  var i = 0
  while i < s.len:
    if s[i] != '\\':
      result.add s[i]
      inc i
      continue
    inc i
    if i >= s.len:
      break
    case s[i]
    of '"': result.add '"'
    of '\\': result.add '\\'
    of '/': result.add '/'
    of 'n': result.add '\n'
    of 'r': result.add '\r'
    of 't': result.add '\t'
    of 'b': result.add '\b'
    of 'f': result.add '\f'
    of 'u':
      var code = 0
      var got = 0
      var k = i + 1
      while k < s.len and got < 4:
        let ch = s[k]
        var d = -1
        if ch >= '0' and ch <= '9': d = ord(ch) - ord('0')
        elif ch >= 'a' and ch <= 'f': d = ord(ch) - ord('a') + 10
        elif ch >= 'A' and ch <= 'F': d = ord(ch) - ord('A') + 10
        if d < 0: break
        code = code * 16 + d
        inc got
        inc k
      if got == 4 and code >= 0x20 and code < 0x80:
        result.add char(code)
        i = k - 1
      else:
        result.add "\\u"
        # Copied through as written rather than guessed at.
        var m = i + 1
        while m < i + 1 + got:
          result.add s[m]
          inc m
        i = m - 1
    else:
      result.add s[i]
    inc i

# --------------------------------------------------------------- accessors

proc raw*(j: JsonRef): string =
  ## The value exactly as it appears, `"quotes"` and all.
  if not j.found or j.last < j.first:
    return ""
  result = j.text.substr(j.first, j.last)

proc exists*(j: JsonRef): bool = j.found

proc isNull*(j: JsonRef): bool =
  let r = raw(j)
  result = r == "null"

proc isText*(j: JsonRef): bool =
  let r = raw(j)
  result = r.len >= 2 and r[0] == '"'

proc isObject*(j: JsonRef): bool =
  let r = raw(j)
  result = r.len >= 2 and r[0] == '{'

proc isArray*(j: JsonRef): bool =
  let r = raw(j)
  result = r.len >= 2 and r[0] == '['

proc asText*(j: JsonRef; default: string = ""): string =
  ## A string value, unescaped. A non-string value comes back as written, so
  ## reading a number as text gives "42" rather than the empty string.
  if not j.found:
    return default
  let r = raw(j)
  if r.len >= 2 and r[0] == '"' and r[r.len - 1] == '"':
    return unquote(r.substr(1, r.len - 2))
  result = r

proc asFloat*(j: JsonRef; default: float = 0.0): float =
  if not j.found:
    return default
  let r = raw(j)
  if r.len == 0:
    return default
  var i = 0
  var neg = false
  if r[0] == '-':
    neg = true
    i = 1
  elif r[0] == '+':
    i = 1
  var whole = 0.0
  var frac = 0.0
  var scale = 0.1
  var seenDot = false
  var any = false
  var expPart = 0
  var expNeg = false
  var inExp = false
  while i < r.len:
    let ch = r[i]
    if ch >= '0' and ch <= '9':
      any = true
      if inExp:
        expPart = expPart * 10 + (ord(ch) - ord('0'))
      elif seenDot:
        frac = frac + float(ord(ch) - ord('0')) * scale
        scale = scale * 0.1
      else:
        whole = whole * 10.0 + float(ord(ch) - ord('0'))
    elif ch == '.' and not seenDot and not inExp:
      seenDot = true
    elif (ch == 'e' or ch == 'E') and not inExp:
      inExp = true
      if i + 1 < r.len and (r[i + 1] == '-' or r[i + 1] == '+'):
        expNeg = r[i + 1] == '-'
        inc i
    else:
      # Anything else means this was not a number.
      return default
    inc i
  if not any:
    return default
  var value = whole + frac
  var k = 0
  while k < expPart:
    if expNeg: value = value / 10.0
    else: value = value * 10.0
    inc k
  result = (if neg: -value else: value)

proc asInt*(j: JsonRef; default: int = 0): int =
  if not j.found: return default
  result = int(asFloat(j, float(default)))

proc asBool*(j: JsonRef; default: bool = false): bool =
  if not j.found: return default
  let r = raw(j)
  if r == "true": return true
  if r == "false": return false
  result = default

# --------------------------------------------------------------- navigation

proc child*(j: JsonRef; key: string): JsonRef =
  ## One member of an object, by exact key. The step `field` is built from, and
  ## the way to reach a key that contains a dot.
  result = notFound()
  if not j.found:
    return
  let s = j.text
  var i = j.first
  skipWs(s, i)
  if i > j.last or s[i] != '{':
    return
  inc i
  while i < s.len:
    skipWs(s, i)
    if i >= s.len or s[i] == '}':
      return
    if s[i] != '"':
      return
    let nameStart = i
    if not skipString(s, i):
      return
    let name = unquote(s.substr(nameStart + 1, i - 2))
    skipWs(s, i)
    if i >= s.len or s[i] != ':':
      return
    inc i
    skipWs(s, i)
    let valueStart = i
    if not skipValue(s, i):
      return
    if name == key:
      var stop = i - 1
      while stop > valueStart and (s[stop] == ' ' or s[stop] == '\n' or
                                  s[stop] == '\r' or s[stop] == '\t'):
        dec stop
      return JsonRef(text: s, first: valueStart, last: stop, found: true)
    skipWs(s, i)
    if i < s.len and s[i] == ',':
      inc i

proc count*(j: JsonRef): int =
  ## The number of elements in an array, or of members in an object. Zero for
  ## anything else, including a value that is not there.
  result = 0
  if not j.found:
    return
  let s = j.text
  var i = j.first
  skipWs(s, i)
  if i > j.last:
    return
  let isArr = s[i] == '['
  let isObj = s[i] == '{'
  if not (isArr or isObj):
    return
  inc i
  while i <= j.last:
    skipWs(s, i)
    if i > j.last or s[i] == ']' or s[i] == '}':
      return
    if isObj:
      if s[i] != '"':
        return
      if not skipString(s, i):
        return
      skipWs(s, i)
      if i > j.last or s[i] != ':':
        return
      inc i
    if not skipValue(s, i):
      return
    inc result
    skipWs(s, i)
    if i <= j.last and s[i] == ',':
      inc i

proc at*(j: JsonRef; index: int): JsonRef =
  ## One element of an array. Out of range is `notFound`, not a crash: an index
  ## from a request body is not something a mod should have to bounds-check
  ## before it can read it.
  result = notFound()
  if not j.found or index < 0:
    return
  let s = j.text
  var i = j.first
  skipWs(s, i)
  if i > j.last or s[i] != '[':
    return
  inc i
  var n = 0
  while i <= j.last:
    skipWs(s, i)
    if i > j.last or s[i] == ']':
      return
    let valueStart = i
    if not skipValue(s, i):
      return
    if n == index:
      var stop = i - 1
      while stop > valueStart and (s[stop] == ' ' or s[stop] == '\n' or
                                  s[stop] == '\r' or s[stop] == '\t'):
        dec stop
      return JsonRef(text: s, first: valueStart, last: stop, found: true)
    inc n
    skipWs(s, i)
    if i <= j.last and s[i] == ',':
      inc i

proc keys*(j: JsonRef): seq[string] =
  ## The member names of an object, in document order.
  result = @[]
  if not j.found:
    return
  let s = j.text
  var i = j.first
  skipWs(s, i)
  if i > j.last or s[i] != '{':
    return
  inc i
  while i <= j.last:
    skipWs(s, i)
    if i > j.last or s[i] == '}':
      return
    if s[i] != '"':
      return
    let nameStart = i
    if not skipString(s, i):
      return
    result.add unquote(s.substr(nameStart + 1, i - 2))
    skipWs(s, i)
    if i > j.last or s[i] != ':':
      return
    inc i
    if not skipValue(s, i):
      return
    skipWs(s, i)
    if i <= j.last and s[i] == ',':
      inc i

proc each*(j: JsonRef): seq[JsonRef] =
  ## Every element of an array, as views. Built once so a loop over it is a walk
  ## of a sequence rather than a rescan of the document per index -- `at` in a
  ## loop is quadratic and this is the reason not to write that.
  result = @[]
  if not j.found:
    return
  let s = j.text
  var i = j.first
  skipWs(s, i)
  if i > j.last or s[i] != '[':
    return
  inc i
  while i <= j.last:
    skipWs(s, i)
    if i > j.last or s[i] == ']':
      return
    let valueStart = i
    if not skipValue(s, i):
      return
    var stop = i - 1
    while stop > valueStart and (s[stop] == ' ' or s[stop] == '\n' or
                                s[stop] == '\r' or s[stop] == '\t'):
      dec stop
    result.add JsonRef(text: s, first: valueStart, last: stop, found: true)
    skipWs(s, i)
    if i <= j.last and s[i] == ',':
      inc i

# --------------------------------------------------------------- paths

proc whole*(text: string): JsonRef =
  ## The document itself, as a value.
  if text.len == 0:
    return notFound()
  var i = 0
  skipWs(text, i)
  if i >= text.len:
    return notFound()
  var stop = text.len - 1
  while stop > i and (text[stop] == ' ' or text[stop] == '\n' or
                      text[stop] == '\r' or text[stop] == '\t'):
    dec stop
  result = JsonRef(text: text, first: i, last: stop, found: true)

proc step(j: JsonRef; token: string): JsonRef =
  ## One path token: a key, then any number of `[n]` suffixes.
  var name = ""
  var i = 0
  while i < token.len and token[i] != '[':
    name.add token[i]
    inc i
  var cur = j
  if name.len > 0:
    cur = child(cur, name)
  while i < token.len and cur.found:
    if token[i] != '[':
      return notFound()
    inc i
    var n = 0
    var any = false
    while i < token.len and token[i] >= '0' and token[i] <= '9':
      n = n * 10 + (ord(token[i]) - ord('0'))
      any = true
      inc i
    if not any or i >= token.len or token[i] != ']':
      return notFound()
    inc i
    cur = at(cur, n)
  result = cur

proc field*(j: JsonRef; path: string): JsonRef =
  ## A dotted path from this value. An empty path is the value itself.
  if path.len == 0:
    return j
  var cur = j
  var token = ""
  for ch in path:
    if ch == '.':
      if token.len > 0:
        cur = step(cur, token)
        token = ""
        if not cur.found:
          return notFound()
    else:
      token.add ch
  if token.len > 0:
    cur = step(cur, token)
  result = cur

proc field*(text, path: string): JsonRef =
  ## A dotted path from a document.
  result = field(whole(text), path)

# ---------------------------------------------------------------------------
# Editing
# ---------------------------------------------------------------------------
#
# Reading is half the job. A mod that changes a profile, a trader's stock or its
# own saved state has to write the document back — and the naive way to do that
# is to rebuild it from a builder, which silently drops every field the mod does
# not know about. The client's documents are full of such fields.
#
# So editing here is member-wise: an object is taken apart into its members with
# their values kept as raw text, the ones being changed are changed, and the
# rest go back out byte for byte. What a mod does not touch, it cannot break.

type
  Member* = object
    name*: string
    value*: string   ## the member's value as raw JSON

  Doc* = object
    ## A JSON object, taken apart for editing. `ok` is false when the text was
    ## not an object -- reported rather than raised, because the text usually
    ## came from a request body and a malformed one is an answer to give, not a
    ## crash to take.
    fields*: seq[Member]
    ok*: bool

  List* = object
    ## A JSON array, taken apart for editing. Elements stay as raw text.
    items*: seq[string]
    ok*: bool

proc members*(j: JsonRef): seq[Member] =
  result = @[]
  if not j.found:
    return
  let s = j.text
  var i = j.first
  skipWs(s, i)
  if i > j.last or s[i] != '{':
    return
  inc i
  while i <= j.last:
    skipWs(s, i)
    if i > j.last or s[i] == '}':
      return
    if s[i] != '"':
      return
    let nameStart = i
    if not skipString(s, i):
      return
    let name = unquote(s.substr(nameStart + 1, i - 2))
    skipWs(s, i)
    if i > j.last or s[i] != ':':
      return
    inc i
    skipWs(s, i)
    let valueStart = i
    if not skipValue(s, i):
      return
    var stop = i - 1
    while stop > valueStart and (s[stop] == ' ' or s[stop] == '\n' or
                                s[stop] == '\r' or s[stop] == '\t'):
      dec stop
    result.add Member(name: name, value: s.substr(valueStart, stop))
    skipWs(s, i)
    if i <= j.last and s[i] == ',':
      inc i

proc parseObject*(text: string): Doc =
  let j = whole(text)
  if not isObject(j):
    return Doc(fields: @[], ok: false)
  result = Doc(fields: members(j), ok: true)

proc parseObject*(j: JsonRef): Doc =
  if not isObject(j):
    return Doc(fields: @[], ok: false)
  result = Doc(fields: members(j), ok: true)

proc newDoc*(): Doc = Doc(fields: @[], ok: true)

proc has*(d: Doc; name: string): bool =
  for f in d.fields:
    if f.name == name:
      return true
  result = false

proc getRaw*(d: Doc; name: string): string =
  for f in d.fields:
    if f.name == name:
      return f.value
  result = ""

proc get*(d: Doc; name: string): JsonRef =
  for f in d.fields:
    if f.name == name:
      return whole(f.value)
  result = notFound()

proc escapeText*(s: string): string =
  ## The JSON string escapes. Present here as well as in `aowlspt/server`
  ## because a client-side mod editing a document must not have to import the
  ## server API to do it.
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
        const hexd = "0123456789abcdef"
        result.add "\\u00"
        result.add hexd[(ord(ch) shr 4) and 0xF]
        result.add hexd[ord(ch) and 0xF]
      else:
        result.add ch

proc quoted*(s: string): string = "\"" & escapeText(s) & "\""

proc setRaw*(d: var Doc; name, rawValue: string) =
  ## Sets a member, keeping its position if it is already there. Position
  ## matters less than it looks: it keeps a diff of two saved profiles readable,
  ## which is the difference between finding a bug and re-reading the whole file.
  for i in 0 ..< d.fields.len:
    if d.fields[i].name == name:
      d.fields[i].value = rawValue
      return
  d.fields.add Member(name: name, value: rawValue)

proc setText*(d: var Doc; name, value: string) = setRaw(d, name, quoted(value))
proc setNumber*(d: var Doc; name: string; value: int) = setRaw(d, name, $value)
proc setNumber*(d: var Doc; name: string; value: float) = setRaw(d, name, $value)
proc setBool*(d: var Doc; name: string; value: bool) =
  setRaw(d, name, (if value: "true" else: "false"))

proc remove*(d: var Doc; name: string) =
  var keep: seq[Member] = @[]
  for f in d.fields:
    if f.name != name:
      keep.add f
  d.fields = keep

proc text*(d: Doc): string =
  result = "{"
  for i in 0 ..< d.fields.len:
    if i > 0: result.add ","
    result.add quoted(d.fields[i].name)
    result.add ":"
    result.add d.fields[i].value
  result.add "}"

proc parseArray*(text: string): List =
  let j = whole(text)
  if not isArray(j):
    return List(items: @[], ok: false)
  var raws: seq[string] = @[]
  let elems = each(j)
  for e in elems:
    raws.add raw(e)
  result = List(items: raws, ok: true)

proc parseArray*(j: JsonRef): List =
  if not isArray(j):
    return List(items: @[], ok: false)
  var raws: seq[string] = @[]
  let elems = each(j)
  for e in elems:
    raws.add raw(e)
  result = List(items: raws, ok: true)

proc newList*(): List = List(items: @[], ok: true)

proc len*(l: List): int = l.items.len

proc at*(l: List; index: int): JsonRef =
  if index < 0 or index >= l.items.len:
    return notFound()
  result = whole(l.items[index])

proc add*(l: var List; rawValue: string) = l.items.add rawValue
proc add*(l: var List; d: Doc) = l.items.add text(d)

proc replaceAt*(l: var List; index: int; rawValue: string) =
  if index >= 0 and index < l.items.len:
    l.items[index] = rawValue

proc removeAt*(l: var List; index: int) =
  if index < 0 or index >= l.items.len:
    return
  var keep: seq[string] = @[]
  for i in 0 ..< l.items.len:
    if i != index:
      keep.add l.items[i]
  l.items = keep

proc text*(l: List): string =
  result = "["
  for i in 0 ..< l.items.len:
    if i > 0: result.add ","
    result.add l.items[i]
  result.add "]"
