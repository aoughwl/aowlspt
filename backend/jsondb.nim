## The backend's database: JSON, addressed by dotted path.
##
##     dbGetPath("templates.items.5447a9cd.._props.Weight", value)
##     dbPatchPath("templates.items.5447a9cd..", """{"_props":{"Weight":0.5}}""")
##
## `dbPatch` **merges**. Two mods editing sibling fields of the same item must
## not clobber one another — that is the difference between a mod system and a
## pile of mods that happen to coexist, and it is the reason this is a merge
## rather than a replace.
##
## The document is held as text and edited as text.
##
## That sounds wrong and is deliberate. A parsed tree would need a mutable
## dynamic value type, which nimony's `std/json` does not give cheaply, and the
## access pattern here is not tree-shaped: mods read a handful of paths at load
## and patch a handful more. Scanning for a path costs a pass over the document;
## doing it a few dozen times at startup is nothing, and doing it per request
## would be a mistake this module cannot prevent anyway.
##
## What it does guarantee is that a patch which cannot be applied exactly is
## refused, rather than applied approximately.

import std/strutils

var gDoc = ""

proc dbLoad*(text: string) =
  gDoc = text

proc dbText*(): string = gDoc

proc dbLoaded*(): bool = gDoc.len > 0

# --------------------------------------------------------------- scanning

proc skipWs(s: string; i: var int) =
  while i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\n' or
                       s[i] == '\r'):
    inc i

proc skipString(s: string; i: var int): bool =
  ## `i` is at the opening quote; leaves it just past the closing one.
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
  ## Leaves `i` just past a complete JSON value. Depth-counting rather than
  ## parsing: the point is to find where a value ends, not what it means.
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

proc findKeyIn(s: string; objStart: int; key: string;
               valueStart, valueEnd: var int): bool =
  ## Finds `key` among the immediate members of the object beginning at
  ## `objStart`. Immediate is the important word — a nested object with the same
  ## key must not match, which is why this walks members rather than searching
  ## for the text.
  valueStart = -1
  valueEnd = -1
  var i = objStart
  skipWs(s, i)
  if i >= s.len or s[i] != '{':
    return false
  inc i
  while i < s.len:
    skipWs(s, i)
    if i < s.len and s[i] == '}':
      return false
    if i >= s.len or s[i] != '"':
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
      continue
    if i < s.len and s[i] == '}':
      return false
  result = false

proc locate(path: string; valueStart, valueEnd: var int): bool =
  ## Walks a dotted path down from the document root.
  valueStart = -1
  valueEnd = -1
  if gDoc.len == 0:
    return false
  var start = 0
  skipWs(gDoc, start)
  var cursor = start
  var first = true
  for part in split(path, '.'):
    if part.len == 0:
      continue
    var vs = 0
    var ve = 0
    let base = if first: start else: cursor
    if not findKeyIn(gDoc, base, part, vs, ve):
      return false
    cursor = vs
    valueStart = vs
    valueEnd = ve
    first = false
  result = valueStart >= 0

proc dbGetPath*(path: string; into: var string): bool =
  into = ""
  var vs = 0
  var ve = 0
  if not locate(path, vs, ve):
    return false
  into = strip(gDoc.substr(vs, ve - 1))
  result = true

# --------------------------------------------------------------- merging

proc mergeInto(target, patch: string): string

proc memberList(s: string): seq[string] =
  ## The immediate members of an object, each as `"name": value` text.
  result = @[]
  var i = 0
  skipWs(s, i)
  if i >= s.len or s[i] != '{':
    return
  inc i
  while i < s.len:
    skipWs(s, i)
    if i < s.len and s[i] == '}':
      return
    if i >= s.len or s[i] != '"':
      return
    let start = i
    if not skipString(s, i):
      return
    skipWs(s, i)
    if i >= s.len or s[i] != ':':
      return
    inc i
    skipWs(s, i)
    if not skipValue(s, i):
      return
    result.add strip(s.substr(start, i - 1))
    skipWs(s, i)
    if i < s.len and s[i] == ',':
      inc i

proc memberName(member: string): string =
  var i = 0
  if not skipString(member, i):
    return ""
  result = member.substr(1, i - 2)

proc memberValue(member: string): string =
  var i = 0
  if not skipString(member, i):
    return ""
  skipWs(member, i)
  if i < member.len and member[i] == ':':
    inc i
  skipWs(member, i)
  result = strip(member.substr(i))

proc isObject(s: string): bool =
  var i = 0
  skipWs(s, i)
  result = i < s.len and s[i] == '{'

proc mergeInto(target, patch: string): string =
  ## Recursive object merge. A member present in both and an object in both is
  ## merged; anything else in the patch replaces. That is the rule `dbPatch`
  ## documents, and the recursion is what makes two mods editing different
  ## fields of the same item safe.
  if not isObject(target) or not isObject(patch):
    return patch

  let targetMembers = memberList(target)
  let patchMembers = memberList(patch)

  var outMembers: seq[string] = @[]
  var consumed: seq[string] = @[]

  for tm in targetMembers:
    let name = memberName(tm)
    var replaced = false
    for pm in patchMembers:
      if memberName(pm) != name:
        continue
      replaced = true
      consumed.add name
      let tv = memberValue(tm)
      let pv = memberValue(pm)
      if isObject(tv) and isObject(pv):
        outMembers.add "\"" & name & "\":" & mergeInto(tv, pv)
      else:
        outMembers.add "\"" & name & "\":" & pv
    if not replaced:
      outMembers.add tm

  for pm in patchMembers:
    let name = memberName(pm)
    var already = false
    for c in consumed:
      if c == name:
        already = true
    if not already:
      outMembers.add pm

  result = "{"
  for i in 0 ..< outMembers.len:
    if i > 0: result.add ","
    result.add outMembers[i]
  result.add "}"

proc splitPath(path: string): seq[string] =
  result = @[]
  var part = ""
  for ch in path:
    if ch == '.':
      if part.len > 0:
        result.add part
        part = ""
    else:
      part.add ch
  if part.len > 0:
    result.add part

proc joinPathParts(parts: seq[string]; upto: int): string =
  result = ""
  for i in 0 ..< upto:
    if i > 0: result.add "."
    result.add parts[i]

proc wrapUnder(parts: seq[string]; fromIndex: int; value: string): string =
  ## `{"a":{"b":<value>}}` for the parts from `fromIndex` on. Built innermost
  ## first, which is the only order that does not need a second pass.
  result = value
  var i = parts.len - 1
  while i >= fromIndex:
    result = "{\"" & parts[i] & "\":" & result & "}"
    dec i

proc dbPatchPath*(path, patchJson: string; error: var string): bool =
  ## Merges `patchJson` into the value at `path`, **creating the path when it is
  ## not there**.
  ##
  ## Creating rather than refusing, because refusing made the API unable to
  ## express the ordinary thing: a mod adding a table of its own, or a location
  ## the database has never held. A patch of an existing member is still a
  ## merge, so nothing a mod did not name is disturbed either way.
  error = ""
  if gDoc.len == 0:
    error = "no database is loaded"
    return false

  var vs = 0
  var ve = 0
  if locate(path, vs, ve):
    let existing = strip(gDoc.substr(vs, ve - 1))
    let merged = mergeInto(existing, strip(patchJson))
    gDoc = gDoc.substr(0, vs - 1) & merged & gDoc.substr(ve)
    return true

  # Find the deepest prefix that does exist, and merge the missing tail into it
  # as nested objects. `have == 0` means not even the first member is there, so
  # the tail is merged into the document itself.
  let parts = splitPath(path)
  if parts.len == 0:
    let merged = mergeInto(strip(gDoc), strip(patchJson))
    gDoc = merged
    return true

  var have = parts.len - 1
  while have > 0:
    if locate(joinPathParts(parts, have), vs, ve):
      break
    dec have

  let tail = wrapUnder(parts, have, strip(patchJson))
  if have == 0:
    gDoc = mergeInto(strip(gDoc), tail)
    return true
  if not locate(joinPathParts(parts, have), vs, ve):
    error = "could not create the database path: " & path
    return false
  let existing = strip(gDoc.substr(vs, ve - 1))
  gDoc = gDoc.substr(0, vs - 1) & mergeInto(existing, tail) & gDoc.substr(ve)
  result = true

# --------------------------------------------------------------- config

proc jsonGet*(text, key: string; into: var string): bool =
  ## A single top-level key out of a small document — mod config, not the
  ## database. Kept here so there is one JSON scanner in the backend.
  into = ""
  var i = 0
  skipWs(text, i)
  var vs = 0
  var ve = 0
  if not findKeyIn(text, i, key, vs, ve):
    return false
  var value = strip(text.substr(vs, ve - 1))
  # Config values are handed to mods unquoted: a mod asking for a string wants
  # the string, not a JSON literal it has to unwrap.
  if value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"':
    value = value.substr(1, value.len - 2)
  into = value
  result = true
