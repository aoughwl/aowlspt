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
##     proc status(url, body, session: string): string =
##       var o = obj()
##       o.put("ok", true)
##       envelope(o)
##
##     discard serve("/aowlspt/status", status)
##
## What this wraps is `route_register`, `db_get`/`db_patch` and `config_get`.
## Underneath it is the same ABI the client uses, which is why one mod binary
## can serve both sides with a `side()` guard.

import std/strutils
import ".." / aowlspt
import "." / json

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

proc len*(o: JsonObject): int = o.parts.len

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

# ------------------------------------------------------------ key enumeration
#
# The five procs below decode JSON strings, which `aowlspt/json` already does
# and does identically. They are written out again here rather than imported,
# and the reason is narrow: `aowlspt/json` exports an `escapeText` with the
# same signature as the one this module defines above, and importing it would
# make every call to that one *inside this module* ambiguous. A mod importing
# both is unaffected -- ambiguity bites at a call site, and a mod calls one or
# the other -- but this module cannot import it without renaming its own.
#
# So: duplicated deliberately, and kept behaviourally identical to
# `json.unquote`, `json.skipValue` and `json.keys`. A mod must be able to
# replace `keys(whole(dbRead(path).raw))` with `dbKeys(path, names)` and get
# the same `seq[string]` out, escapes and all -- that is the whole point of
# the wrapper, and a second decoder that disagreed about `\"` would break it.

proc keySkipWs(s: string; i: var int) =
  while i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\n' or
                       s[i] == '\r'):
    inc i

proc keySkipString(s: string; i: var int): bool =
  ## `i` at the opening quote, left just past the closing one. Escapes are
  ## stepped two at a time, which is what stops a `\"` inside a name ending it.
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

proc keySkipValue(s: string; i: var int): bool =
  ## `json.skipValue`. Depth-counting rather than parsing: where the value
  ## ends, not what it means.
  keySkipWs(s, i)
  if i >= s.len:
    return false
  case s[i]
  of '"':
    return keySkipString(s, i)
  of '{', '[':
    var depth = 0
    while i < s.len:
      let c = s[i]
      if c == '"':
        if not keySkipString(s, i):
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

proc keyUnquote(s: string): string =
  ## `json.unquote`, character for character. `\u` is decoded for the ASCII
  ## range and otherwise left as written, so a Cyrillic locale key comes back
  ## visibly escaped rather than silently mangled.
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
        var m = i + 1
        while m < i + 1 + got:
          result.add s[m]
          inc m
        i = m - 1
    else:
      result.add s[i]
    inc i

proc keyArray(text: string): seq[string] =
  ## `["a","b"]` as a `seq[string]`. This parses the host's own answer and
  ## nothing else, so it gives up on anything that is not an array of strings
  ## rather than guessing at it.
  result = @[]
  var i = 0
  keySkipWs(text, i)
  if i >= text.len or text[i] != '[':
    return
  inc i
  while i < text.len:
    keySkipWs(text, i)
    if i < text.len and text[i] == ',':
      inc i
      keySkipWs(text, i)
    if i >= text.len or text[i] == ']':
      return
    if text[i] != '"':
      return
    let start = i
    if not keySkipString(text, i):
      return
    result.add keyUnquote(text.substr(start + 1, i - 2))

proc objectKeys(text: string): seq[string] =
  ## `json.keys`: the member names of an object's text, in document order.
  ## Only the fallback path in `dbKeysOrRead` uses it.
  result = @[]
  var i = 0
  keySkipWs(text, i)
  if i >= text.len or text[i] != '{':
    return
  inc i
  while i < text.len:
    keySkipWs(text, i)
    if i >= text.len or text[i] == '}':
      return
    if text[i] != '"':
      return
    let nameStart = i
    if not keySkipString(text, i):
      return
    result.add keyUnquote(text.substr(nameStart + 1, i - 2))
    keySkipWs(text, i)
    if i >= text.len or text[i] != ':':
      return
    inc i
    if not keySkipValue(text, i):
      return
    keySkipWs(text, i)
    if i < text.len and text[i] == ',':
      inc i

const DbKeysSigil* = "?keys "
  ## The reserved path prefix that asks a `db_get` for an object's member names
  ## instead of its value. Exposed so a mod can read the wrappers below and see
  ## what they send, not so it has to compose one by hand.

proc dbKeysReady*(): bool =
  ## Whether this host can enumerate keys.
  ##
  ## **Not a size test**, because this is not an ABI entry. The probe is the
  ## sigil with no path after it: a host that implements key enumeration
  ## refuses that with `ErrBadArg` -- there is nothing to enumerate -- and a
  ## host that does not walks a path called `"?keys "`, finds no root member by
  ## that name, and answers `ErrNotFound`. One call, no ABI surface, and no
  ## guessing.
  ##
  ## `aowlspt-backend` answers true. The simulator and the in-game client host
  ## answer false, and will until somebody adds the sigil to them; a mod should
  ## treat false as "read the subtree instead", which is what it did before
  ## this existed.
  var out1 = ""
  result = dbGet(DbKeysSigil, out1) == ErrBadArg

proc dbKeys*(path: string; into: var seq[string]): Status =
  ## The immediate member names of the object at `path`, in document order.
  ##
  ## The answer is the same `seq[string]` that `keys(whole(text))` gives for
  ## the same object -- it *is* that call, over the array the host sends back
  ## -- so a mod can swap one for the other without changing the code that
  ## consumes it.
  ##
  ## Four answers, and the difference between the last two is the point:
  ##
  ##  * `Ok` -- `into` holds the names. An object with no members is `Ok` and
  ##    an empty `into`.
  ##  * `ErrBadArg` -- the path is an **array or a scalar**. A list has no
  ##    keys, and it is not answered with `["0","1",...]`: for a large table
  ##    that is a huge reply to a question whose real form is "how long is it",
  ##    and a caller that wanted indices already has the length from `dbRead`.
  ##  * `ErrNotFound` -- **there is no such path**. That is not the same as an
  ##    object with no members, and a caller that treats them alike will create
  ##    something over the top of a table it failed to read.
  ##  * `ErrNotFound` **again**, from a host that does not implement this at
  ##    all: it looked for a root member literally named `?keys <path>` and did
  ##    not find one. The two are indistinguishable from this call alone, which
  ##    is the price of not spending an ABI revision. `dbKeysReady()` separates
  ##    them for one call, and `dbKeysOrRead` does it for you.
  ##
  ## ## What it costs
  ##
  ## Not nothing. The reply is `sum(len(name)) + 3n` bytes for `n` members --
  ## about 2.7 MB for a table of 100k Mongo ids. That is roughly 200x smaller
  ## than reading the subtree, and it is still megabytes crossing the ABI and
  ## then being parsed into a `seq[string]` on this side. Ask for it once and
  ## keep the answer for as long as you would have kept the read.
  ##
  ## It is a **snapshot**, not an index. Another mod may patch that object
  ## between this call and the `dbRead` of a child, and the order is the
  ## document's -- which a merge can change. Nobody promised the order.
  into = @[]
  var out1 = ""
  result = dbGet(DbKeysSigil & path, out1)
  if result != Ok:
    return
  into = keyArray(out1)

proc dbKeysOrRead*(path: string; into: var seq[string]; scanned: var bool): Status =
  ## `dbKeys`, falling back to reading the whole subtree on a host that has no
  ## key enumeration -- and **saying which it did**, in `scanned`.
  ##
  ## The fallback is the read a mod was doing before this existed, and it is
  ## the expensive one: `locations` on a stock import is 13.5 MB and on one
  ## with loose loot it is over half a gigabyte. `scanned` is true when that is
  ## what happened, so a mod can log what the answer cost instead of leaving a
  ## user wondering where the second went.
  ##
  ## `ErrNotFound` from this means the path is genuinely not there: the host
  ## was asked twice, the second time for the subtree itself.
  into = @[]
  scanned = false
  result = dbKeys(path, into)
  if result == Ok or result == ErrBadArg:
    return
  # `ErrNotFound` -- either no such path, or no such feature. One read tells
  # both apart and answers the question at the same time.
  scanned = true
  let v = dbRead(path)
  if not v.ok:
    return ErrNotFound
  var i = 0
  keySkipWs(v.raw, i)
  if i >= v.raw.len or v.raw[i] != '{':
    return ErrBadArg
  into = objectKeys(v.raw)
  result = Ok

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

proc lastDotIn(s: string): int =
  result = -1
  for i in 0 ..< s.len:
    if s[i] == '.':
      result = i

proc dbWritePath(path, patchJson: string): Status =
  ## Merges into `path`, **creating it when it is not there**.
  ##
  ## Three mods hand-rolled this same fallback under three different names,
  ## which is the signal that it belongs here. The reason each of them needed
  ## it: a patch of a member that has never been written is refused with "no
  ## such database path", which is right for *patching* something and wrong for
  ## a mod adding a table of its own -- a faction's bot types, a location the
  ## database has never held, an achievement list.
  ##
  ## `aowlspt-backend` creates the path itself, so the fallback below never
  ## runs there. It exists for the hosts that do not: a miss is retried as a
  ## one-member object merged into the parent, and into *its* parent if that is
  ## missing too, wrapping as it goes.
  ##
  ## It stops one segment short of the root, because an empty path locates
  ## nothing -- so a database with no top-level `locations` at all is reported
  ## rather than silently skipped.
  result = dbPatch(path, patchJson)
  if result == Ok:
    return
  let cut = lastDotIn(path)
  if cut < 0:
    return
  let parent = path.substr(0, cut - 1)
  let leaf = path.substr(cut + 1)
  result = dbWritePath(parent, "{\"" & leaf & "\":" & patchJson & "}")

proc dbWrite*(path: string; patch: Json): Status =
  ## Merges `patch` into the object at `path`, creating the path if the
  ## database has never held it.
  ##
  ## A merge, not a replace: two mods editing sibling fields of the same item
  ## must not clobber one another. That is the difference between a mod system
  ## and a pile of mods that happen to coexist.
  result = dbWritePath(path, patch.text)

proc dbWrite*(path, patchJson: string): Status =
  result = dbWritePath(path, patchJson)

proc dbWrite*(path: string; patch: JsonObject): Status =
  ## The overload that was missing, so `dbWrite(path, obj)` had to be written
  ## `dbWrite(path, done(obj))` -- and `done(obj)` at every call site is
  ## ceremony that says nothing.
  result = dbWritePath(path, done(patch).text)

proc dbWrite*(path: string; patch: JsonArray): Status =
  result = dbWritePath(path, done(patch).text)

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

type
  ConfigValue* = object
    ok*: bool
    raw*: string
    faulted*: bool
      ## The config file exists and did not parse, so **no** setting read
      ## through this mod is real -- not just this one.
      ##
      ## Appended rather than folded into `ok`, and that is the compatibility
      ## story: `ok` is false in this case exactly as it was before, so every
      ## `asText(default)` and every `if v.ok` in every mod already written
      ## behaves identically. What is new is that a mod which cares can now
      ## ask, and the ones that should care are the ones whose defaults are a
      ## *decision* rather than a fallback -- a load order, an enabled set, a
      ## list of maps. `lastError()` carries the file and the fault.

proc setting*(key: string): ConfigValue =
  var out1 = ""
  let st = configGet(key, out1)
  if st == Ok:
    result = ConfigValue(ok: true, raw: out1, faulted: false)
  else:
    # `raw` is kept on a parse fault, and only there. `setting("")` on a broken
    # file hands back the bytes that are on disk, which is what a mod that
    # parses its own document needs in order to say *what* is wrong with it --
    # and what the backend and the client host used to return with a bare `Ok`,
    # so a mod already written that way keeps working unchanged. `ok` is false
    # either way, so nothing that reads through `asText` and friends can see a
    # difference.
    result = ConfigValue(ok: false, raw: out1, faulted: st == ErrConfigParse)

proc configFaulted*(): bool =
  ## Whether this mod's `config.json` is present and unreadable.
  ##
  ## The question asked once, at load, by a mod that would rather refuse than
  ## run on defaults it did not choose. It reads the whole document, which is
  ## the cheapest way to ask -- an empty key is one round trip on every host.
  var whole = ""
  result = configGet("", whole) == ErrConfigParse

proc asText*(c: ConfigValue; default: string = ""): string =
  ## The quotes come off here, whichever host is underneath.
  ##
  ## They did not, and the three hosts disagreed: the backend and the client
  ## host strip them on the way out, while the simulator -- then a C# program,
  ## since rewritten in nimony -- handed back the raw JSON literal. So
  ## `setting("edition").asText()` was `standard` on a server and
  ## `"standard"` in the simulator -- an empty string setting had length two,
  ## and a value used to build a database path addressed nothing on one side
  ## while working on the other. Two mods had already grown their own private
  ## unquoting helper by the time it was noticed, which is the shape of a
  ## missing library function.
  ##
  ## Stripping here rather than in each host is what makes it true everywhere,
  ## including on a host written later.
  if not c.ok:
    return default
  if c.raw.len >= 2 and c.raw[0] == '"' and c.raw[c.raw.len - 1] == '"':
    return c.raw.substr(1, c.raw.len - 2)
  result = c.raw

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

# ---------------------------------------------------------------------------
# Arrays and nesting
# ---------------------------------------------------------------------------
#
# `obj()` covers a flat object, which covers a status endpoint and almost
# nothing else the game asks for. Real responses are arrays of objects, so the
# builder has to nest without the mod concatenating text by hand -- the moment
# it does that, one missing comma produces a body the client rejects with no
# error anywhere.

type
  JsonArray* = object
    parts: seq[string]

proc arr*(): JsonArray = JsonArray(parts: @[])

proc add*(a: var JsonArray; value: Json) = a.parts.add value.text
proc add*(a: var JsonArray; value: string) = a.parts.add jstr(value).text
proc add*(a: var JsonArray; value: int) = a.parts.add jint(value).text
proc add*(a: var JsonArray; value: float) = a.parts.add jfloat(value).text
proc add*(a: var JsonArray; value: bool) = a.parts.add jbool(value).text

proc len*(a: JsonArray): int = a.parts.len

proc done*(a: JsonArray): Json =
  var s = "["
  for i in 0 ..< a.parts.len:
    if i > 0: s.add ","
    s.add a.parts[i]
  s.add "]"
  result = Json(text: s)

proc put*(o: var JsonObject; key: string; value: JsonArray) =
  put(o, key, done(value))

proc put*(o: var JsonObject; key: string; value: JsonObject) =
  put(o, key, done(value))

proc add*(a: var JsonArray; value: JsonObject) = a.parts.add done(value).text
proc add*(a: var JsonArray; value: JsonArray) = a.parts.add done(value).text

proc objOf*(key: string; value: Json): JsonObject =
  ## A one-member object. The client's bodies are full of single-key wrappers
  ## (`{"Health":{...}}`, `{"Counters":[]}`), and writing each as three lines of
  ## builder buries the shape of the response in ceremony.
  result = obj()
  put(result, key, value)

proc objOf*(key: string; value: JsonObject): JsonObject = objOf(key, done(value))
proc objOf*(key: string; value: JsonArray): JsonObject = objOf(key, done(value))
proc objOf*(key, value: string): JsonObject = objOf(key, jstr(value))
proc objOf*(key: string; value: int): JsonObject = objOf(key, jint(value))
proc objOf*(key: string; value: bool): JsonObject = objOf(key, jbool(value))

proc emptyArray*(): Json = Json(text: "[]")
proc emptyObject*(): Json = Json(text: "{}")

# ---------------------------------------------------------------------------
# The response envelope
# ---------------------------------------------------------------------------
#
# Every `/client/*` endpoint answers with the same wrapper, and the client reads
# `err` before it looks at anything else. A route that returns bare data gets a
# client that treats a perfectly good response as a failure, which is a whole
# evening to find and one function to prevent.

proc envelope*(data: Json): string =
  ## `{"err":0,"errmsg":null,"data":...}` -- what the client expects from every
  ## `/client/*` route.
  result = "{\"err\":0,\"errmsg\":null,\"data\":" & data.text & "}"

proc envelope*(dataText: string): string =
  result = "{\"err\":0,\"errmsg\":null,\"data\":" & dataText & "}"

proc envelope*(o: JsonObject): string = envelope(done(o))
proc envelope*(a: JsonArray): string = envelope(done(a))

proc envelopeNull*(): string =
  ## A successful response carrying nothing. Distinct from an empty object: some
  ## endpoints are checked for `data === null` by the client.
  result = "{\"err\":0,\"errmsg\":null,\"data\":null}"

proc failure*(code: int; message: string): string =
  ## The error shape. `code` is the client's own error number; zero would say
  ## success, so it is refused rather than sent.
  var c = code
  if c == 0: c = 1
  result = "{\"err\":" & $c & ",\"errmsg\":\"" & escapeText(message) &
           "\",\"data\":null}"

# ---------------------------------------------------------------------------
# Persistence
# ---------------------------------------------------------------------------
#
# What a mod must still know next time: profiles, progress, anything it owns.
# Not `dbWrite` -- that is the shared game database, loaded from disk and common
# to every mod, and patching it to store a player's stash would put one mod's
# save state where every other mod reads templates.

type
  Stored* = object
    ok*: bool
    raw*: string
    error*: string
    missing*: bool
      ## True when there is no such key, false when there *is* one and it could
      ## not be read.
      ##
      ## The difference is not cosmetic and it is not a logging detail. A mod
      ## that keeps a player's progress reacts to "nothing saved yet" by making
      ## a new one, which is right on a first run and is the worst possible
      ## answer to "your save is on disk and the host could not read it": it
      ## writes a new character over a file that a copy out of the store's
      ## history would very likely have recovered. Anything that creates on a
      ## failed `load` must check this first and refuse loudly when it is
      ## false.

proc save*(key: string; value: Json): Status =
  ## Write this mod's value at `key`, durably. Keys are flat and
  ## `[A-Za-z0-9._-]`; anything else is refused rather than mangled into a
  ## filename that might collide with another key.
  result = storeSet(key, value.text)

proc save*(key, value: string): Status =
  result = storeSet(key, value)

proc save*(key: string; value: JsonObject): Status = save(key, done(value))

proc load*(key: string): Stored =
  ## Read this mod's value at `key`. `ok` is false and `error` says why when it
  ## was never written -- which is the normal first-run case, not a fault --
  ## and `missing` separates that case from a value that is there and unreadable.
  var text = ""
  let st = storeGet(key, text)
  if st == Ok:
    result = Stored(ok: true, raw: text, error: "", missing: false)
  else:
    result = Stored(ok: false, raw: "", error: lastError(),
                    missing: st == ErrNotFound)

proc saved*(key: string): bool =
  var text = ""
  result = storeGet(key, text) == Ok

proc savedKeys*(prefix: string = ""): seq[string] =
  ## This mod's keys beginning with `prefix`, so "every profile" is expressible
  ## without the mod knowing where the host put them.
  result = @[]
  var listJson = ""
  if storeList(prefix, listJson) != Ok:
    return
  # A flat array of quoted names. Parsed here rather than through the JSON
  # reader so `aowlspt/server` does not force every mod to import it.
  var i = 0
  while i < listJson.len:
    if listJson[i] == '"':
      var name = ""
      inc i
      while i < listJson.len and listJson[i] != '"':
        name.add listJson[i]
        inc i
      result.add name
    inc i

# ---------------------------------------------------------------------------
# Events and timers
# ---------------------------------------------------------------------------

proc broadcast*(name: string; payload: Json): Status =
  ## Tell every other mod something happened. The emitter does not receive its
  ## own event: a mod that owns an event usually also subscribes to it, and
  ## delivering it back would be a loop nobody wrote.
  result = emit(name, payload.text)

proc broadcast*(name, payload: string): Status = emit(name, payload)
proc broadcast*(name: string; payload: JsonObject): Status =
  emit(name, done(payload).text)
proc broadcast*(name: string; payload: JsonArray): Status =
  emit(name, done(payload).text)

proc onEvent*(name: string; handler: EventHandler): Status =
  result = on(name, handler)

proc afterMs*(delayMs: int; handler: TickHandler): Status =
  ## Run `handler` once, `delayMs` from now, from the server's own loop rather
  ## than from a request thread.
  result = after(delayMs, handler)

proc everyMs*(intervalMs: int; handler: TickHandler): Status =
  ## Run `handler` on a repeating timer, off the request threads. What a
  ## periodic sweep -- expiring offers, posting insurance returns -- is for.
  result = every(intervalMs, handler)
