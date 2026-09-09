## Buffered database writes: build the whole contribution, then write it once.
##
## ---------------------------------------------------------------------------
## WHY THIS EXISTS, WITH THE MEASUREMENT
## ---------------------------------------------------------------------------
##
## `dbWrite` is not a cheap call, and the reason is structural rather than
## incidental. The backend holds the database as one text document and a patch
## splices into it:
##
##     gDoc = gDoc.substr(0, vs - 1) & merged & gDoc.substr(ve)
##     docReplaced()          # and the whole member index is thrown away
##
## **What that costs, measured rather than assumed.** This header used to say
## "around 130 ms, whatever the patch says — the cost is the size of the
## document, not of the patch". The first half of that is out of date and the
## second half was never right, and both were worth re-measuring rather than
## repeating. On the 39 MiB import, timing only the `dbWrite` calls:
##
##     path                     per call
##     locations.<one map>      ~3 ms      (18 calls, 53 ms)
##     bots.types               ~43 ms     (2 calls with bots.config, 86 ms)
##     locations (whole table)  ~114 ms    (1 call)
##
## The splice is linear in the document and is not what dominates; what
## dominates is **the size of the object at the path**, because that is what the
## merge parses and rebuilds. A write is cheap or expensive according to how
## deep it aims, and the shallowest write is the most expensive one. That is
## also why `gGroupDepth` below is two and not one.
##
## Buffering is still worth having by a wide margin, because what it saves is
## the *count*. This mod used to issue **363** patches during a default boot
## with `mods/blackdivision` attached: six bot types × eight paths, seven
## loadout overlays, and — the bulk of it — twelve faction relations, each
## rewriting four `Mind` arrays on every bot type it names. `fromFaction:
## "savage"` alone names thirty-seven roles. At `bots.types` prices that is
## fifteen seconds of rebuilding the same table; buffered, it is two calls and
## 86 ms.
##
## ---------------------------------------------------------------------------
## WHAT THIS DOES INSTEAD
## ---------------------------------------------------------------------------
##
## Every write goes into a list of `(path, value)` pairs held in this process,
## and every read consults that list before the database. At the end of the
## registration burst the list is folded into one nested document per
## second-level path and written with two `dbWrite` calls — `bots.types` and
## `bots.config`.
##
## The fold itself has to be cheap, and for a long time it was not: it merged
## the buffered entries one at a time into a growing accumulator, so the n-th
## entry re-parsed and re-serialised the n-1 before it, six 60 KB bot templates
## among them. Measured on the real registration: **238 ms folding against
## 81 ms writing** — a buffer costing three times what the writes it exists to
## avoid cost. `foldTree` groups by path segment in one pass instead, and the
## same registration now folds in under a millisecond. The two are compared
## byte for byte by the self-test, on four shapes, because the fold is the one
## piece of this file whose output nobody ever reads.
##
## The *result* is byte-identical, and that is the point rather than a hope: a
## merge of a merge of a merge is the same document as one merge of the merged
## patch, because `dbPatch`'s rule (an object member present in both recurses,
## anything else replaces) is associative in exactly that way. What changes is
## how many times the 41 MB moves.
##
## The list is kept flat rather than as a tree because the interesting
## operations are "is this path, or an ancestor of it, already buffered" and
## "fold everything under this prefix", and both are one pass over a list that
## never exceeds a few hundred entries. A tree would need the same merge
## function underneath and a node pool on top of it.
##
## ---------------------------------------------------------------------------
## WHEN IT IS WRITTEN
## ---------------------------------------------------------------------------
##
## `flush()` is called from three places, and the redundancy is deliberate:
##
##   * the `morebots.flush` event, which is how a dependent that knows it has
##     finished registering says so. `mods/blackdivision` sends it at the end of
##     its handshake, so the default mod set is fully written **before the
##     backend starts listening** — nothing observes a half-applied database.
##   * the top of every route this mod serves, so an HTTP caller can never read
##     around the buffer.
##   * a zero-delay timer armed by the first buffered write, so a dependent that
##     does *not* know about `morebots.flush` is still correct — one server tick
##     later rather than immediately.
##
## A mod that never flushes explicitly loses nothing but ordering: the timer
## fires on the first tick of the serve loop.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import aowlspt/fast

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
var gBufNs: int64 = 0  ## nanoseconds spent merging into the buffer
var gFoldNs: int64 = 0 ## nanoseconds spent folding the buffer into documents
var gWriteNs: int64 = 0## nanoseconds spent inside dbWrite

proc bufferNanos*(): int64 = gBufNs
proc foldNanos*(): int64 = gFoldNs
proc writeNanos*(): int64 = gWriteNs

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

proc pendPutInner(path, value: string) =
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

proc pendPut*(path, value: string) =
  let t0 = perfCounter()
  pendPutInner(path, value)
  gBufNs = gBufNs + nanosBetween(t0, perfCounter())

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
  ## `dbRead`, with this mod's own unwritten work in front of it. Every read in
  ## this mod goes through here: a relation that reads back a `Mind` array it
  ## buffered two events ago must see what it buffered, or the union it writes
  ## drops half its ids.
  var v = ""
  if pendGet(path, v):
    return DbValue(ok: true, raw: v, error: "")
  result = dbRead(path)

# ---------------------------------------------------------------------------
# The fold
# ---------------------------------------------------------------------------

var gGroupDepth = 2
  ## How many path segments a write is grouped on: one `dbWrite` per distinct
  ## prefix of this length.
  ##
  ## The trade goes both ways and was measured rather than reasoned about.
  ## Shallower means fewer calls, and a call costs the size of the database.
  ## Deeper means the backend's merge starts closer to the members actually
  ## being edited, and it copies every sibling it passes on the way.
  ##
  ## Two, for this mod, because one was tried and is slower -- twice, on two
  ## different tables, and by a wider margin the second time.
  ##
  ## On `bots`: grouping at depth 1 folds `bots.types` and `bots.config` into a
  ## single write, and that single write took **573 ms** against **508 ms** for
  ## the two it replaced. The merge has to walk and rebuild `bots.core` and
  ## `bots.base` to reach the two members being changed.
  ##
  ## On `locations`, where the argument for depth 1 looks much stronger -- the
  ## population pass touches *every* one of the nineteen members, so there are
  ## no siblings to walk for nothing, and depth 2 means nineteen splices of a
  ## 39 MiB document to edit one object. It is still slower: **114 ms for the
  ## one write against 34 ms for the eighteen it replaced**, measured on the
  ## real import. The nineteen small merges each rebuild one map; the one big
  ## merge rebuilds the whole table, and `locations` is about half the
  ## database. Fewer calls is the goal right up to the point where the call is
  ## doing work nobody asked for, and that point arrives sooner than it looks.

proc setGroupDepth*(depth: int) =
  if depth >= 1:
    gGroupDepth = depth

proc groupKey(path: string): string =
  let ps = parts(path)
  if ps.len <= gGroupDepth:
    return path
  result = ps[0]
  for i in 1 ..< gGroupDepth:
    result = result & "." & ps[i]

proc foldTree(segs: seq[seq[string]]; vals: seq[string]; idx: seq[int];
              depth: int): string =
  ## The buffered entries named by `idx`, all of which share the first `depth`
  ## path segments, as one JSON document for that prefix.
  ##
  ## This used to be `doc = mergeJson(doc, wrapped)` in a loop over every
  ## entry, and that loop was the single most expensive thing this mod did.
  ## The accumulator is the *whole* contribution -- six 60 KB bot templates
  ## among them -- so merging the n-th entry re-parsed and re-serialised all
  ## n-1 before it. Measured on the 39 MiB database: **238 ms folding, against
  ## 81 ms actually writing**, which is a buffer that costs three times what
  ## the writes it exists to avoid cost.
  ##
  ## Grouping by path segment instead makes it one pass. `pendPut` guarantees
  ## no buffered path is an ancestor of another, so at each node either exactly
  ## one entry terminates -- and then it is the only entry there and its value
  ## is the answer -- or every entry goes deeper and the node is an object of
  ## its distinct next segments. Neither case merges anything, which is why
  ## this is linear in the size of the output rather than quadratic in it.
  ##
  ## The `mergeJson` below is kept for the case the invariant does not hold
  ## (a caller reaching past `pendPut`): a wrong answer is worse than a slow
  ## one, and on the real data it never runs.
  if idx.len == 0:
    return ""
  var here = ""
  var names: seq[string] = @[]
  var starts: seq[seq[int]] = @[]
  for i in idx:
    if segs[i].len <= depth:
      here = (if here.len == 0: vals[i] else: mergeJson(here, vals[i]))
      continue
    let name = segs[i][depth]
    var hit = -1
    for j in 0 ..< names.len:
      if names[j] == name:
        hit = j
    if hit < 0:
      var one: seq[int] = @[]
      one.add i
      names.add name
      starts.add one
    else:
      starts[hit].add i
  if names.len == 0:
    return here
  var body = "{"
  for j in 0 ..< names.len:
    if j > 0:
      body.add ","
    body.add "\""
    body.add names[j]
    body.add "\":"
    body.add foldTree(segs, vals, starts[j], depth + 1)
  body.add "}"
  if here.len > 0:
    return mergeJson(here, body)
  result = body

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

  # Split once, not once per group: `parts` over a few hundred short paths is
  # cheap, and doing it inside the group loop made it quadratic again.
  var segs: seq[seq[string]] = @[]
  for i in 0 ..< paths.len:
    segs.add parts(paths[i])

  for k in keys:
    let tf = perfCounter()
    var mine: seq[int] = @[]
    for i in 0 ..< paths.len:
      if groupKey(paths[i]) == k:
        mine.add i
    if mine.len == 0:
      continue
    let doc = foldTree(segs, vals, mine, parts(k).len)
    if doc.len == 0:
      continue
    gFoldNs = gFoldNs + nanosBetween(tf, perfCounter())
    let tw = perfCounter()
    if dbWrite(k, doc) != Ok:
      warn "morebots: could not write " & k & " (" & $doc.len & " bytes)"
    else:
      inc result
      inc gFlushes
    gWriteNs = gWriteNs + nanosBetween(tw, perfCounter())

proc foldCases*(paths, vals: seq[string]; k: string): bool =
  ## One group, both ways, compared byte for byte. Takes its buffer as
  ## arguments rather than reading the globals so the self-test can drive
  ## shapes a default registration does not happen to produce.
  var segs: seq[seq[string]] = @[]
  for i in 0 ..< paths.len:
    segs.add parts(paths[i])
  var mine: seq[int] = @[]
  var slow = ""
  for i in 0 ..< paths.len:
    mine.add i
    var wrapped = ""
    if paths[i] == k:
      wrapped = vals[i]
    else:
      wrapped = wrapFrom(parts(tailOf(paths[i], k)), 0, vals[i])
    slow = (if slow.len == 0: wrapped else: mergeJson(slow, wrapped))
  let fast = foldTree(segs, vals, mine, parts(k).len)
  result = fast == slow

proc foldSelfCheck*(): int =
  ## The shapes the fold has to get right, each checked against the sequential
  ## merge it replaced. Returns how many disagreed.
  ##
  ## Driven from a written-out buffer rather than from whatever a registration
  ## happens to leave behind: by the time the self-test runs, `onLoad` has
  ## already flushed, so the live buffer is empty and a check that read it
  ## would report "nothing to check" for ever while looking like a test.
  result = 0

  # Siblings under one parent -- the ordinary case, and the one the old
  # sequential merge spent all its time on.
  var p1: seq[string] = @[]
  var v1: seq[string] = @[]
  p1.add "bots.types.a.difficulty.easy.Mind.ENEMY_BOT_TYPES"
  v1.add "[1,2]"
  p1.add "bots.types.a.difficulty.hard.Mind.ENEMY_BOT_TYPES"
  v1.add "[3]"
  p1.add "bots.types.b.difficulty.easy.Mind.FRIENDLY_BOT_TYPES"
  v1.add "[4]"
  if not foldCases(p1, v1, "bots.types"):
    inc result

  # An ancestor buffered beside its own descendants. `pendPut` folds this away
  # before it reaches the fold, so the fold should never see it -- which is
  # exactly why it is checked: the `mergeJson` branch in `foldTree` that
  # handles it is otherwise unreached code that would rot.
  var p2: seq[string] = @[]
  var v2: seq[string] = @[]
  p2.add "bots.types.a"
  v2.add """{"x":1,"difficulty":{"easy":{"Mind":{"WARN_BOT_TYPES":[9]}}}}"""
  p2.add "bots.types.a.difficulty.easy.Mind.ENEMY_BOT_TYPES"
  v2.add "[5]"
  if not foldCases(p2, v2, "bots.types"):
    inc result

  # A single entry that *is* the group key: the value must come through raw,
  # not re-serialised, or a member order somebody depends on quietly changes.
  var p3: seq[string] = @[]
  var v3: seq[string] = @[]
  p3.add "bots.config"
  v3.add """{"a":1,"b":{"c":[1,2,3]}}"""
  if not foldCases(p3, v3, "bots.config"):
    inc result

  # Two writes to the same leaf: the later one wins, both ways.
  var p4: seq[string] = @[]
  var v4: seq[string] = @[]
  p4.add "locations.m.base"
  v4.add """{"BotMax":10,"MaxBotPerZone":3}"""
  p4.add "locations.m.base.waves"
  v4.add "[{}]"
  if not foldCases(p4, v4, "locations.m"):
    inc result

proc foldMatchesSequentialMerge*(): bool =
  ## Does the grouped fold produce the same document as merging the buffered
  ## entries one at a time, in order?
  ##
  ## This is the property `flush` was rewritten to keep, so it is asserted
  ## rather than reasoned about. The sequential merge is what this file did
  ## before -- 238 ms of it on a real registration -- and it is kept here as
  ## the *specification* of the fast path, which is the only thing a slow
  ## reference implementation is good for.
  ##
  ## Answered against whatever is buffered right now, so the self-test calls it
  ## after driving a registration and before flushing.
  if gPaths.len == 0:
    return true
  var segs: seq[seq[string]] = @[]
  for i in 0 ..< gPaths.len:
    segs.add parts(gPaths[i])
  var keys: seq[string] = @[]
  for i in 0 ..< gPaths.len:
    let k = groupKey(gPaths[i])
    var have = false
    for x in keys:
      if x == k:
        have = true
    if not have:
      keys.add k
  result = true
  for k in keys:
    var mine: seq[int] = @[]
    var slow = ""
    for i in 0 ..< gPaths.len:
      if groupKey(gPaths[i]) != k:
        continue
      mine.add i
      var wrapped = ""
      if gPaths[i] == k:
        wrapped = gVals[i]
      else:
        wrapped = wrapFrom(parts(tailOf(gPaths[i], k)), 0, gVals[i])
      slow = (if slow.len == 0: wrapped else: mergeJson(slow, wrapped))
    let fast = foldTree(segs, gVals, mine, parts(k).len)
    # Byte equality, not "equivalent". Both walk the buffer in the same order
    # and both emit members first-seen, so there is no formatting difference to
    # allow for -- and allowing for one would be allowing for the class of bug
    # this is looking for.
    if fast != slow:
      result = false

proc resetPending*() =
  ## For the self-test, which drives the load path more than once.
  gPaths = @[]
  gVals = @[]
  gWrites = 0
  gFlushes = 0
  gArmed = false
  gBufNs = 0
  gFoldNs = 0
  gWriteNs = 0
