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

proc pathItems*(text, path: string; into: var seq[string]): bool =
  ## The elements of the JSON array at a dotted path, each as its own text.
  ##
  ## Here rather than in a caller because it is the same walk `skipValue`
  ## already does and the same thing both hosts want next: a lookup that can
  ## only reach a scalar makes every list in a document -- a mod set, a load
  ## order, a list of maps -- unreadable without a second parser, which is how
  ## the two divergent readers this module replaced came about in the first
  ## place.
  ##
  ## False for a path that is absent or is not an array. An empty array is
  ## true with no elements: "there are none" and "there is no such key" are
  ## different answers and a caller acting on a mod set has to tell them apart.
  into = @[]
  var vs = 0
  var ve = 0
  if not locatePath(text, path, vs, ve):
    return false
  var i = vs
  skipWs(text, i)
  if i >= ve or text[i] != '[':
    return false
  inc i
  var closed = false
  var broken = false
  while not closed and not broken:
    skipWs(text, i)
    if i >= ve:
      # Ran off the end without a `]`. Only reachable on a truncated document,
      # and false is the answer: a partial array read as a whole one is exactly
      # the mistake this module exists to stop.
      broken = true
    elif text[i] == ']':
      closed = true
    else:
      let start = i
      if not skipValue(text, i):
        broken = true
      else:
        into.add strip(text.substr(start, i - 1))
        skipWs(text, i)
        if i < ve and text[i] == ',':
          inc i
  if broken:
    into = @[]
    return false
  result = true

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

# ---------------------------------------------------------------------------
# "Did this document parse at all?"
# ---------------------------------------------------------------------------
#
# `pathGet` answers one question -- is this key here -- and it answers `false`
# for both of the reasons a key can fail to arrive: the document does not hold
# it, and the document is not readable. Those are the same word to the lookup
# and they are opposite sentences to whoever has to fix it. One says "this
# setting is absent, the mod's default stands"; the other says "none of this
# mod's settings are real and it has been running on defaults all session".
#
# What that cost is on the record: a three-byte UTF-8 BOM -- which Notepad and
# `Set-Content -Encoding utf8` write by default -- made the mod manager read
# its `activeLists` as empty, resolve nothing, and write a selection file
# naming only itself. The next start loaded one mod out of ten, with no error
# anywhere. `readTextFile` now strips that BOM, so that trigger is gone; a
# trailing comma, a half-finished write and a UTF-16 save reproduce it exactly.
#
# So the readability question gets its own answer, here, once, shared by the
# three hosts -- because three hosts that each decide for themselves is how
# they came to disagree about it in the first place.
#
# It is a *validator*, not a parser: it walks the document and reports the
# first place it stops making sense, and it is strict where `skipValue` is
# lenient on purpose. `skipValue` exists to get past a member it was not asked
# about and a lenient skip is right for that; a trailing comma must not get
# past this one, because a trailing comma is the second most common way a
# hand-edited config stops parsing.

proc showByte(c: char): string =
  ## A byte in a form a log line survives. Printable ASCII as itself in
  ## quotes, everything else as hex -- because the bytes that cause this are
  ## exactly the ones an editor will not show: a BOM, a NUL from a UTF-16
  ## save, a stray 0x00 from a truncated write.
  let u = int(uint8(c))
  if u >= 32 and u < 127:
    var one = " "
    one[0] = c
    result = "`" & one & "`"
  else:
    let hex = "0123456789ABCDEF"
    var two = "  "
    two[0] = hex[(u shr 4) and 15]
    two[1] = hex[u and 15]
    result = "byte 0x" & two

proc plural(n: int; one, many: string): string =
  if n == 1: one else: many

proc jsonFault*(text: string; into: var string): bool =
  ## True when `text` is **not** a readable JSON object, with `into` set to a
  ## sentence naming where and why. False -- no fault -- when it parses.
  ##
  ## The message names a byte offset rather than a line, deliberately: the
  ## documents this runs on are frequently one line, and half of the causes
  ## (BOM, NUL, truncation) have no line to speak of. An offset can be found
  ## in any editor and points at the byte the writer got wrong.
  into = ""

  # Encodings first. These never reach the scanner as text at all, and the
  # scanner's answer for them -- "the top level is 0xFF" -- is true but names
  # a byte where the real sentence is about how the file was saved.
  if text.len == 0:
    into = "the file is empty (0 bytes)"
    return true
  if text.len >= 2 and ((text[0] == '\xFF' and text[1] == '\xFE') or
                        (text[0] == '\xFE' and text[1] == '\xFF')):
    into = "the file begins with a UTF-16 byte-order mark, so it was saved as " &
           "UTF-16; save it as UTF-8 instead"
    return true
  if text.len >= 3 and text[0] == '\xEF' and text[1] == '\xBB' and
     text[2] == '\xBF':
    # Only reachable if the file was read by something other than
    # `readTextFile`, which drops this. Named anyway: a message that said
    # "the top level is byte 0xEF" would send somebody looking at the JSON.
    into = "the file begins with a UTF-8 byte-order mark (EF BB BF); those " &
           "three bytes are invisible in an editor and no JSON reader " &
           "accepts them"
    return true
  var nulAt = -1
  var n = 0
  while n < text.len and nulAt < 0:
    if text[n] == '\x00': nulAt = n
    inc n
  if nulAt >= 0:
    into = "there is a NUL byte at offset " & $nulAt & "; the file is either " &
           "UTF-16 without a byte-order mark or was half-written"
    return true

  var i = 0
  skipWs(text, i)
  if i >= text.len:
    into = "the file is " & $text.len & " bytes of whitespace and holds no JSON"
    return true
  if text[i] != '{':
    into = "the top level is " & showByte(text[i]) & " at offset " & $i &
           ", not the `{` an object must begin with"
    return true

  # The scan. `stack` holds the open brackets; `state` is what may come next.
  #
  #   0  a value, and only a value      3  a `,` or the matching closer
  #   1  a member name or `}`           4  nothing: the document is complete
  #   2  a `:`                          5  a value or `]`
  #   6  a member name, and only one
  #
  # States 0 and 6 are the strict twins of 5 and 1: after a comma a closer is
  # a trailing comma, and that pair is the whole reason both exist.
  var stack: seq[char] = @[]
  var state = 0

  while true:
    skipWs(text, i)

    if state == 4:
      if i < text.len:
        into = "there is more text after the closing `}` -- " &
               showByte(text[i]) & " at offset " & $i &
               " -- so the file holds two documents, or one was appended to"
        return true
      return false

    if i >= text.len:
      into = "the document ends at offset " & $text.len & " with " &
             $stack.len & " unclosed " &
             plural(stack.len, "bracket", "brackets") &
             "; the file looks truncated"
      return true

    let c = text[i]
    var completed = false

    if state == 2:
      if c != ':':
        into = "expected `:` after a member name but found " & showByte(c) &
               " at offset " & $i
        return true
      inc i
      state = 0
      continue

    if state == 1 or state == 6:
      if c == '}':
        if state == 6:
          into = "there is a trailing comma before the `}` at offset " & $i &
                 "; JSON does not allow one"
          return true
        setLen(stack, stack.len - 1)
        inc i
        completed = true
      elif c == '"':
        if not skipString(text, i):
          into = "a member name starting at offset " & $i & " is never closed"
          return true
        state = 2
        continue
      else:
        into = "expected a quoted member name but found " & showByte(c) &
               " at offset " & $i
        return true

    elif state == 3:
      if c == ',':
        inc i
        if stack[stack.len - 1] == '{':
          state = 6
        else:
          state = 0
        continue
      elif c == '}' or c == ']':
        var want = ']'
        if stack[stack.len - 1] == '{': want = '}'
        if c != want:
          into = "the bracket at offset " & $i &
                 " does not close the one it was opened with"
          return true
        setLen(stack, stack.len - 1)
        inc i
        completed = true
      else:
        into = "expected `,` or a closing bracket but found " & showByte(c) &
               " at offset " & $i
        return true

    else:
      # A value is wanted. State 5 also accepts the `]` that ends an array;
      # state 0 does not, and the difference is a trailing comma.
      if c == ']':
        if state != 5:
          into = "there is a trailing comma before the `]` at offset " & $i &
                 "; JSON does not allow one"
          return true
        setLen(stack, stack.len - 1)
        inc i
        completed = true
      elif c == '{':
        stack.add '{'
        inc i
        state = 1
        continue
      elif c == '[':
        stack.add '['
        inc i
        state = 5
        continue
      elif c == '"':
        if not skipString(text, i):
          into = "a string starting at offset " & $i & " is never closed"
          return true
        completed = true
      elif c == 't' or c == 'f' or c == 'n':
        var word = "null"
        if c == 't': word = "true"
        elif c == 'f': word = "false"
        if i + word.len <= text.len and
           text.substr(i, i + word.len - 1) == word:
          i = i + word.len
          completed = true
        else:
          into = "expected `" & word & "` at offset " & $i &
                 " but the word is misspelled, or is a bare word that " &
                 "should have been quoted"
          return true
      elif c == '-' or (c >= '0' and c <= '9'):
        let start = i
        if c == '-': inc i
        var digits = 0
        while i < text.len and text[i] >= '0' and text[i] <= '9':
          inc digits
          inc i
        if digits == 0:
          into = "a number starting at offset " & $start & " has no digits"
          return true
        if i < text.len and text[i] == '.':
          inc i
          digits = 0
          while i < text.len and text[i] >= '0' and text[i] <= '9':
            inc digits
            inc i
          if digits == 0:
            into = "a number starting at offset " & $start &
                   " has a `.` with no digits after it"
            return true
        if i < text.len and (text[i] == 'e' or text[i] == 'E'):
          inc i
          if i < text.len and (text[i] == '+' or text[i] == '-'): inc i
          digits = 0
          while i < text.len and text[i] >= '0' and text[i] <= '9':
            inc digits
            inc i
          if digits == 0:
            into = "a number starting at offset " & $start &
                   " has an exponent with no digits"
            return true
        completed = true
      else:
        var hint = ""
        if c == '\'':
          hint = " -- JSON strings use double quotes"
        into = "expected a value but found " & showByte(c) & " at offset " &
               $i & hint
        return true

    if completed:
      if stack.len == 0:
        state = 4
      else:
        state = 3
