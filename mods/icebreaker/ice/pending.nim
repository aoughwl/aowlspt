## Buffered database writes: build the whole contribution, then write it once.
##
## A copy of `mods/morebots/bots/pending.nim`, and deliberately a copy: mods are
## separate binaries and cannot import one another, so a helper two of them need
## is either duplicated or promoted into `aowlspt/server`. It belongs in
## `aowlspt/server` and until it is there, this is the honest way to have it
## twice.
##
## ---------------------------------------------------------------------------
## WHY, WITH THE MEASUREMENT
## ---------------------------------------------------------------------------
##
## The backend holds the database as one text document and a patch splices into
## it, throwing the member index away afterwards. The splice is linear in the
## document — an imported SPT database is 39 MiB — but what actually dominates a
## `dbWrite` is **the size of the object at the path**, because that is what the
## merge parses and rebuilds. Measured on the real import, timing only the
## `dbWrite` calls: about 3 ms for one `locations.<map>`, about 43 ms for
## `bots.types`, about 114 ms for the whole `locations` table. The shallow write
## is the expensive one.
##
## (This header, and the copy in `mods/morebots/bots/pending.nim` it was taken
## from, used to say "around 130 ms, whatever the patch says". That number was
## measured on an older backend, and the reasoning behind it — that the cost is
## the document's rather than the path's — did not survive being checked.)
##
## This mod registers a location with thirteen writes — the base document, four
## loot tables, exits, waves, boss spawns, spawn points, the bot cap, the scav
## raid timings and the locale rebrand — to write about 200 KB. Buffered, they
## fold into one document per second-level path and go in with three.
##
## The result is byte-identical: `dbPatch`'s rule (a member present in both
## sides recurses, anything else replaces) makes a merge of merges the same
## document as one merge of the merged patch.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json

# ---------------------------------------------------------------------------
# The merge
# ---------------------------------------------------------------------------
#
# The same rule `dbPatch` documents, reimplemented here over strings that are
# this mod's own and are kilobytes rather than megabytes. It has to be the same
# rule or the folded write would not equal the sequence of writes it replaces.

proc skipWs(s: string; i: var int) =
  while i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\n' or
                       s[i] == '\r'):
    inc i

proc skipStr(s: string; i: var int): bool =
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

proc skipVal(s: string; i: var int): bool =
  skipWs(s, i)
  if i >= s.len:
    return false
  if s[i] == '"':
    return skipStr(s, i)
  if s[i] == '{' or s[i] == '[':
    var depth = 0
    while i < s.len:
      let c = s[i]
      if c == '"':
        if not skipStr(s, i):
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
  while i < s.len and s[i] != ',' and s[i] != '}' and s[i] != ']':
    inc i
  result = true

proc isObj(s: string): bool =
  var i = 0
  skipWs(s, i)
  result = i < s.len and s[i] == '{'

proc memberNames(s: string; names, values: var seq[string]) =
  ## The immediate members of an object, split into names and raw values.
  names = @[]
  values = @[]
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
    let nameStart = i
    if not skipStr(s, i):
      return
    let name = s.substr(nameStart + 1, i - 2)
    skipWs(s, i)
    if i >= s.len or s[i] != ':':
      return
    inc i
    skipWs(s, i)
    let vs = i
    if not skipVal(s, i):
      return
    names.add name
    values.add strip(s.substr(vs, i - 1))
    skipWs(s, i)
    if i < s.len and s[i] == ',':
      inc i

proc mergeJson*(target, patch: string): string =
  ## Recursive object merge, patch on top. Anything that is not an object on
  ## both sides is replaced outright, which is what makes an array assignment
  ## an assignment.
  if not isObj(target) or not isObj(patch):
    return patch
  var tn: seq[string] = @[]
  var tv: seq[string] = @[]
  var pn: seq[string] = @[]
  var pv: seq[string] = @[]
  memberNames(target, tn, tv)
  memberNames(patch, pn, pv)

  var used: seq[bool] = @[]
  for i in 0 ..< pn.len:
    used.add false

  var outNames: seq[string] = @[]
  var outValues: seq[string] = @[]
  for i in 0 ..< tn.len:
    var hit = -1
    for j in 0 ..< pn.len:
      if pn[j] == tn[i]:
        hit = j
    if hit < 0:
      outNames.add tn[i]
      outValues.add tv[i]
    else:
      used[hit] = true
      if isObj(tv[i]) and isObj(pv[hit]):
        outNames.add tn[i]
        outValues.add mergeJson(tv[i], pv[hit])
      else:
        outNames.add tn[i]
        outValues.add pv[hit]
  for j in 0 ..< pn.len:
    if not used[j]:
      outNames.add pn[j]
      outValues.add pv[j]

  result = "{"
  for i in 0 ..< outNames.len:
    if i > 0:
      result.add ","
    result.add "\""
    result.add outNames[i]
    result.add "\":"
    result.add outValues[i]
  result.add "}"

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

proc parts*(path: string): seq[string] =
  result = @[]
  for p in split(path, '.'):
    if p.len > 0:
      result.add p

proc wrapFrom(ps: seq[string]; fromIndex: int; value: string): string =
  ## `{"a":{"b":<value>}}` for the segments from `fromIndex` on, innermost
  ## first — the only order that does not need a second pass.
  result = value
  var i = ps.len - 1
  while i >= fromIndex:
    result = "{\"" & ps[i] & "\":" & result & "}"
    dec i

proc isUnder(path, prefix: string): bool =
  ## `path` is strictly below `prefix`. The trailing dot matters:
  ## `bots.typesetter` is not under `bots.types`.
  result = path.len > prefix.len + 1 and path.startsWith(prefix) and
           path[prefix.len] == '.'

proc tailOf(path, prefix: string): string =
  result = path.substr(prefix.len + 1)

# ---------------------------------------------------------------------------
# The buffer
# ---------------------------------------------------------------------------

var gPaths: seq[string] = @[]
var gVals: seq[string] = @[]
var gWrites = 0        ## buffered writes, for the report
var gFlushes = 0       ## real `dbWrite` calls issued
var gArmed = false     ## a zero-delay flush timer is already scheduled

proc pendingCount*(): int = gPaths.len
proc bufferedWrites*(): int = gWrites
proc realWrites*(): int = gFlushes
proc dirty*(): bool = gPaths.len > 0

proc armed*(): bool = gArmed
proc arm*() = gArmed = true

proc indexOfPath(path: string): int =
  result = -1
  for i in 0 ..< gPaths.len:
    if gPaths[i] == path:
      return i

proc pendPut*(path, value: string) =
  ## Buffer a write. Afterwards no buffered path is an ancestor of another, so
  ## the fold at the end is a straight grouping rather than a reconciliation.
  inc gWrites
  if path.len == 0 or value.len == 0:
    return

  let exact = indexOfPath(path)
  if exact >= 0:
    gVals[exact] = mergeJson(gVals[exact], value)
    return

  # An ancestor is already buffered: rewrite the patch as a nested object and
  # merge it into that ancestor's value. This is the case that keeps a bot
  # template and the four `Mind` arrays later written inside it in one place.
  for i in 0 ..< gPaths.len:
    if isUnder(path, gPaths[i]):
      let rest = parts(tailOf(path, gPaths[i]))
      gVals[i] = mergeJson(gVals[i], wrapFrom(rest, 0, value))
      return

  # Descendants are buffered and this write sits above them: fold them into a
  # document, then merge the new value on top, because it is the later word.
  var base = ""
  var keptPaths: seq[string] = @[]
  var keptVals: seq[string] = @[]
  for i in 0 ..< gPaths.len:
    if isUnder(gPaths[i], path):
      let rest = parts(tailOf(gPaths[i], path))
      let wrapped = wrapFrom(rest, 0, gVals[i])
      base = (if base.len == 0: wrapped else: mergeJson(base, wrapped))
    else:
      keptPaths.add gPaths[i]
      keptVals.add gVals[i]
  if base.len > 0:
    gPaths = keptPaths
    gVals = keptVals
    gPaths.add path
    gVals.add mergeJson(base, value)
    return

  gPaths.add path
  gVals.add value

proc pendGet*(path: string; into: var string): bool =
  ## The buffered value at `path`, if this mod has written it or written
  ## something that contains it.
  into = ""
  for i in 0 ..< gPaths.len:
    if gPaths[i] == path:
      into = gVals[i]
      return true
  for i in 0 ..< gPaths.len:
    if isUnder(path, gPaths[i]):
      let f = field(gVals[i], tailOf(path, gPaths[i]))
      if f.found:
        into = f.raw()
        return true
      return false
  # Nothing at the path itself, but something below it — enough to answer an
  # existence probe, and the partial document is what this mod has written.
  var acc = ""
  for i in 0 ..< gPaths.len:
    if isUnder(gPaths[i], path):
      let wrapped = wrapFrom(parts(tailOf(gPaths[i], path)), 0, gVals[i])
      acc = (if acc.len == 0: wrapped else: mergeJson(acc, wrapped))
  if acc.len > 0:
    into = acc
    return true
  result = false

proc pendRead*(path: string): DbValue =
  ## `dbRead`, with this mod's own unwritten work in front of it, for a caller
  ## that has to read back something it has not committed yet.
  var v = ""
  if pendGet(path, v):
    return DbValue(ok: true, raw: v, error: "")
  result = dbRead(path)

# ---------------------------------------------------------------------------
# The fold
# ---------------------------------------------------------------------------

proc groupKey(path: string): string =
  ## Two segments, or one when that is all there is.
  ##
  ## Not one: `dbWrite("locations", ...)` makes the backend's merge walk every
  ## member of `locations` -- every map in the game -- and copy each one out as
  ## a string on the way past. Two segments starts the merge at
  ## `locations.suburbs`, which is the object actually being edited. Not three
  ## either: that is a write per table and back to where this started.
  let ps = parts(path)
  if ps.len <= 1:
    return path
  result = ps[0] & "." & ps[1]

proc flush*(): int =
  ## Write everything buffered, as few calls as the shape allows. Returns how
  ## many `dbWrite` calls it made.
  result = 0
  gArmed = false
  if gPaths.len == 0:
    return 0

  var keys: seq[string] = @[]
  for i in 0 ..< gPaths.len:
    let k = groupKey(gPaths[i])
    var have = false
    for x in keys:
      if x == k:
        have = true
    if not have:
      keys.add k

  var paths = gPaths
  var vals = gVals
  # Cleared before the writes rather than after: `dbWrite` can reach a route or
  # an event handler on some hosts, and a re-entrant flush must find an empty
  # buffer rather than writing everything twice.
  gPaths = @[]
  gVals = @[]

  for k in keys:
    var doc = ""
    for i in 0 ..< paths.len:
      if groupKey(paths[i]) != k:
        continue
      var wrapped = ""
      if paths[i] == k:
        wrapped = vals[i]
      else:
        wrapped = wrapFrom(parts(tailOf(paths[i], k)), 0, vals[i])
      doc = (if doc.len == 0: wrapped else: mergeJson(doc, wrapped))
    if doc.len == 0:
      continue
    if dbWrite(k, doc) != Ok:
      warn "icebreaker: could not write " & k & " (" & $doc.len & " bytes)"
    else:
      inc result
      inc gFlushes

proc resetPending*() =
  ## For the self-test, which drives the load path more than once.
  gPaths = @[]
  gVals = @[]
  gWrites = 0
  gFlushes = 0
  gArmed = false
