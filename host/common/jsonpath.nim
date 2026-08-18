## One JSON path lookup, shared by both hosts.
##
## It exists because there were two, and they disagreed. The backend read a mod
## config with a real key lookup and stripped the quotes off a string value; the
## client host searched the file for `"key"` as a substring and returned what
## followed it, quotes and all. So `setting("stashPath").asText()` gave
## `locations.suburbs.base` on the server and `"locations"."suburbs".base` on the
## client, and a mod using it to build a database path worked on one side and
## silently addressed nothing on the other.
##
## Two behaviours are fixed here, deliberately, and both are what the backend
## already did:
##
##  * **Dotted paths.** `"raid.insuranceHours"` addresses a nested member, so a
##    mod's config can be grouped the way its settings are grouped.
##  * **String values come back unquoted.** A mod asking for a string wants the
##    string, not a JSON literal it has to unwrap. Every other value comes back
##    as written, so a number is `"42"` and an object is its own text.
##
## A substring search is not a lookup: `"Health"` matches inside `"MaxHealth"`
## and inside any string value that happens to contain it. That is the bug this
## replaces.

import std/strutils

proc skipWs(s: string; i: var int) =
  while i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\n' or
                       s[i] == '\r'):
    inc i

proc skipString(s: string; i: var int): bool =
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

proc memberOf(s: string; objStart: int; key: string;
              valueStart, valueEnd: var int): bool =
  ## The value of `key` in the object beginning at `objStart`. Bounds are
  ## `[valueStart, valueEnd)`.
  result = false
  var i = objStart
  skipWs(s, i)
  if i >= s.len or s[i] != '{':
    return false
  inc i
  while i < s.len:
    skipWs(s, i)
    if i >= s.len or s[i] == '}':
      return false
    if s[i] != '"':
      return false
    let nameStart = i
    if not skipString(s, i):
      return false
    let name = s.substr(nameStart + 1, i - 2)
    skipWs(s, i)
    if i >= s.len or s[i] != ':':
      return false
    inc i
    skipWs(s, i)
    let vs = i
    if not skipValue(s, i):
      return false
    if name == key:
      valueStart = vs
      valueEnd = i
      return true
    skipWs(s, i)
    if i < s.len and s[i] == ',':
      inc i

proc locatePath*(text, path: string; valueStart, valueEnd: var int): bool =
  ## Walks a dotted path. An empty path is the whole document.
  valueStart = 0
  valueEnd = text.len
  if path.len == 0:
    return text.len > 0
  var cursor = 0
  skipWs(text, cursor)
  var part = ""
  var ok1 = true
  for ch in path & ".":
    if ch != '.':
      part.add ch
      continue
    if part.len == 0:
      continue
    var vs = 0
    var ve = 0
    if not memberOf(text, cursor, part, vs, ve):
      ok1 = false
      break
    cursor = vs
    valueStart = vs
    valueEnd = ve
    part = ""
  result = ok1

proc pathGet*(text, path: string; into: var string): bool =
  ## The value at a dotted path, with a string value unquoted.
  into = ""
  var vs = 0
  var ve = 0
  if not locatePath(text, path, vs, ve):
    return false
  var value = strip(text.substr(vs, ve - 1))
  if value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"':
    value = value.substr(1, value.len - 2)
  into = value
  result = true
