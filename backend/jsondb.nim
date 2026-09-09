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
## access pattern here is not tree-shaped.
##
## What it does guarantee is that a patch which cannot be applied exactly is
## refused, rather than applied approximately.
##
## ## The index
##
## Text alone was not enough. The original comment here said mods read "a
## handful of paths at load", and that turned out to be wrong the moment a real
## game server ran on this: the emulator reads a template's `Width`, `Height`
## and `StackMaxSize` on every inventory operation, and `/client/items` reads
## `templates.items` on every request. Each of those was a fresh walk from the
## document root, and each walk had to *skip over* every value it passed --
## which for anything living after `templates.items` means stepping through
## four megabytes of JSON, per lookup.
##
## So each object is indexed the first time something addresses it: its
## immediate members are enumerated once, and every later lookup into that
## object is a hash lookup instead of a scan. Building the index for an object
## costs exactly the scan the first lookup was going to cost anyway, so nothing
## is slower and repeated access is bounded by the depth of the path rather
## than by the size of the document.
##
## ## What a write costs
##
## It used to cost the document. `dbPatchPath` ended in
##
##     gDoc = gDoc.substr(0, vs - 1) & merged & gDoc.substr(ve)
##     docReplaced()
##
## -- two whole copies of the document, and then the index thrown away so the
## next read rebuilt it by scanning. On the 41 MB imported database that is
## **160 ms for a two-hundred-byte patch**, and it is 160 ms whatever the patch
## says: the cost was `writes x sizeof(document)`. It stayed invisible while
## every test ran against a fixture of a few dozen entries, and it surfaced as a
## 54 second server boot. Four mods had grown their own write buffering to get
## around it, which is a thing no mod should have to know.
##
## Two changes take it apart.
##
## **The splice happens in place.** `beginStore` hands back the string's own
## buffer, so a patch is one `moveMem` of the bytes after the edit and a
## `copyMem` of the patch -- no allocation at all when the replacement fits the
## capacity the document already has, which after the first growth it does.
##
## **The index survives.** The index is byte offsets, and a splice moves every
## offset after it -- but by a *known* delta. So the index is not held in the
## document's live coordinates at all: it is held in **anchor coordinates**, the
## coordinates the document had when the index was last rebuilt, and every
## splice appends to a short list of edited regions that maps between the two.
## A lookup is one binary search over that list per path segment, which is
## nothing beside the hash lookup it accompanies.
##
## Three rules keep it honest, and each of them fails *closed* -- to a
## re-anchor, which is exactly the old behaviour of throwing the index away:
##
##  * An anchor offset that lands **strictly inside** a region some later patch
##    rewrote has no meaning any more. It is refused rather than translated, and
##    the caller re-anchors. This is the case the old comment here worried
##    about: handing a mod a byte range out of the middle of some other item.
##  * Text a patch *wrote* has no anchor coordinate at all -- it did not exist
##    when the anchor was taken. So the first read that has to index inside a
##    patched value re-anchors, and after that reads are indexed again. In the
##    ordinary shape of a run -- mods patch at load, the game reads afterwards
##    -- that is one re-anchor for the whole session.
##  * The list is bounded (`EditCeiling`). A run that patches without ever
##    reading cannot grow it without limit.
##
## The document itself stays one contiguous string, deliberately. Holding it in
## segments would make a splice free, and would put an indirection under every
## byte of `skipValue` and under the 12.5 MB `substr` that answers
## `/client/items` -- paying on the request path to save on the load path, which
## is the wrong way round.
##
## ## A patch racing a read
##
## It used to be undefended, and said so. Reads took no lock at all, so a
## `dbPatch` from a request thread while another request was reading was a
## use-after-free waiting to happen: the old code rebound `gDoc`, dropping the
## last reference to the buffer a reader was copying out of; the in-place splice
## that replaced it reads bytes mid-`moveMem` instead, and becomes the same
## use-after-free the first time the buffer has to grow. With sixteen workers
## serving concurrently and mods patching from route handlers and from timers,
## that is reachable rather than theoretical.
##
## It is closed by **a reader-writer lock on the document** -- see "the two
## locks" below for which lock guards what, and why there are two.
##
## The alternatives, and why not:
##
##  * **A sequence number the reader validates and redoes on.** It does not
##    address the hazard. The failure here is not a torn read that can be
##    noticed afterwards and repeated; it is a `substr` copying out of a buffer
##    that was freed *during* the copy. Validating after the fact arrives too
##    late, and making it arrive in time means keeping the old buffer alive --
##    hazard pointers, or an allocator that never reuses -- which is more
##    machinery than a lock and harder to be sure of.
##  * **Copy-on-write for the duration of a read.** The document is 41 MB and
##    `/client/items` is answered out of it several times a second. Refcounting
##    the buffer instead of copying it would work in principle and is defeated
##    in practice by the in-place splice, which is the change this file exists
##    to keep.
##  * **Serialising writes onto the poller thread.** It moves the writer without
##    moving the readers, and the race is between a writer and a *reader*. It
##    would close nothing.
##
## What it costs is the thing to check rather than to assert, so it was
## measured against the real 41 MB database, over the wire, before and after:
##
## | | before | after |
## |---|---|---|
## | the whole mix | 227 req/s | 230 req/s |
## | `/client/items` | 83.5 ms | 81.5 ms |
## | `db_get` | 187 us | 186 us |
##
## Which is what a shared acquire should cost: one interlocked compare-and-swap
## in and one out, tens of nanoseconds against a call that means a hundred and
## eighty microseconds. It is also the reason the lock is reader-writer rather
## than the critical section that was already in this file -- an exclusive lock
## held over the 12.5 MB copy that answers `/client/items` would have serialised
## the workers behind each other on exactly the request that carries the bytes.
##
## And it is checked rather than argued: `backend/dbrace.nim` runs readers and
## writers on one document at once and asserts on the *answers* rather than on
## survival. Against this file it does seventy thousand concurrent read passes
## in eight seconds without a wrong answer. Against a copy of this file with the
## four lock calls made no-ops, it dies inside a second -- three access
## violations and two bounds failures in five runs.

import std/[strutils, tables]

# Only the lock is wanted here, so this includes `aowlspt_lock.h` rather than
# `aowlspt_net.h`: the index has no business dragging winsock and zlib into
# its translation unit to guard a table.
{.emit: """#include "aowlspt_lock.h" """.}

proc cLock() {.importc: "aowl_lock", nodecl.}
proc cUnlock() {.importc: "aowl_unlock", nodecl.}

# ------------------------------------------------------------ the two locks
#
# There are two, and which one guards what is the whole of the concurrency
# story in this file.
#
# **`cLock` guards the index.** The member table, the indexed set, the dirty
# set, the edit list and the anchor generation. It is a critical section --
# exclusive -- because every one of those is written on the *read* path: the
# first lookup into an object indexes it.
#
# **The document lock guards `gDoc`'s bytes**, and it is a reader-writer lock
# because the read path is the hot one and reads do not disturb each other.
# A read holds it shared for the whole of `dbGetPath` -- the walk *and* the
# `substr` that copies the answer out -- and a patch holds it exclusive for the
# whole of `dbPatchPath`.
#
# The order is always document first, index second, and never the other way,
# which is what makes the pair impossible to deadlock. Nothing in this file
# takes `cLock` and then reaches for the document lock.
#
# `SRWLOCK_INIT` is all zero bits, so a `static` needs no initialisation call
# and there is no order to get wrong -- the same reason `aowlspt_net.h`
# zero-initialises its session table lock. Uncontended, each of these is one
# interlocked compare-and-swap in and one out, with no kernel transition:
# tens of nanoseconds against a `db_get` that means 187 microseconds.
#
# It is emitted here rather than added to `aowlspt_lock.h` for the reason that
# file exists at all. `aowlspt_lock.h` is shared with the injected client host,
# which has no document; this lock is the database's and belongs to the
# database. Everything in `abi/` is `static` and nimony emits one translation
# unit per module, so a lock declared there would in any case be a *different*
# lock in every module that included it -- which is exactly the trap the
# websocket table fell into.
{.emit: """
static SRWLOCK aowl_db_doc_lock;
static void aowl_db_read_begin(void)  { AcquireSRWLockShared(&aowl_db_doc_lock); }
static void aowl_db_read_end(void)    { ReleaseSRWLockShared(&aowl_db_doc_lock); }
static void aowl_db_write_begin(void) { AcquireSRWLockExclusive(&aowl_db_doc_lock); }
static void aowl_db_write_end(void)   { ReleaseSRWLockExclusive(&aowl_db_doc_lock); }
""".}

proc docRead() {.importc: "aowl_db_read_begin", nodecl.}
proc docReadEnd() {.importc: "aowl_db_read_end", nodecl.}
proc docWrite() {.importc: "aowl_db_write_begin", nodecl.}
proc docWriteEnd() {.importc: "aowl_db_write_end", nodecl.}

var gDoc = ""

# Member ranges, keyed by "<object offset><unit separator><member name>", packed
# as (start shl 32) or end. Zero is not a reachable packing -- a member's value
# always begins after the object's own `{` -- so it doubles as "not there".
var gMembers = initTable[string, int64]()
var gIndexed = initTable[int, bool]()

var gNames = initTable[int, string]()
  ## The immediate member names of an object, as the **finished JSON array
  ## text**, keyed by the same anchor offset as `gIndexed`.
  ##
  ## Two things about the shape, both deliberate.
  ##
  ## It is the answer rather than the ingredients. `gMembers` already holds
  ## every name -- inside its keys, as `"<offset><US><name>"` -- so answering
  ## "the keys of this object" from it means scanning every entry in the table
  ## for a matching prefix, which is O(every indexed member in the document)
  ## for a question about one object. That is the wrong shape. Holding the
  ## array text instead means the answer is a table lookup and a copy, and it
  ## needs no re-escaping: a name is stored here exactly as the document spells
  ## it, escapes and all, so wrapping it in quotes reproduces valid JSON.
  ##
  ## It is filled only for objects somebody **asked** about, never for every
  ## object a path walk happens to index. That is mitigation (a) of the two
  ## `docs/API-GAPS.md` lists, and it is the one that keeps the memory honest:
  ## a walk down `templates.items.<id>._props.Weight` indexes four objects and
  ## one of them has 100k members, none of which anybody asked to enumerate.
  ## The price is that "already indexed" is not the same as "already asked" --
  ## the first `dbKeysPath` on a table pays one scan of it even if a read has
  ## been there before, which is the scan the read had already paid once. It
  ## is paid again rather than remembered, and that is the trade.
  ##
  ## Every entry is an anchor offset, so everything that drops a `gIndexed`
  ## entry must drop the matching one here. There are three such places and
  ## they are named in `docs/API-GAPS.md`: `indexClear`, `rebaseLocked`, and
  ## the `IndexCeiling` branch of `indexedFind` -- which reaches this through
  ## `indexClear`. A miss is stale names against a re-anchored document, which
  ## is the one failure the anchor-coordinate design exists to refuse.

const IndexCeiling = 2_000_000
  ## Members held before the index is thrown away and rebuilt on demand. A
  ## database is bounded, but a mod addressing a million distinct paths is not,
  ## and an index that can only grow is a leak with a slow fuse.
  ##
  ## `gNames` has no ceiling of its own and does not need one: it holds one
  ## entry per object a mod has *enumerated*, which is bounded by the tables a
  ## mod knows the name of, and it is emptied by this one anyway.

proc indexClear() =
  clear(gMembers)
  clear(gIndexed)
  clear(gNames)

# ------------------------------------------------------------- the edit list
#
# Anchor coordinates, and the map from them to the document as it stands now.
# Every offset in `gMembers` and every key in `gIndexed` is an anchor offset.

type
  Edit = object
    ## One region that a patch replaced. `aStart`/`aStop` are where it was in
    ## anchor coordinates; `newLen` is how many bytes stand there now.
    ## `shiftBefore` is the sum of every earlier edit's delta, cached so that
    ## either translation is a binary search rather than a walk.
    aStart: int
    aStop: int
    newLen: int
    shiftBefore: int

var gEdits: seq[Edit] = @[]
  ## Sorted by `aStart` and disjoint. Both properties are maintained by
  ## `recordEdit` and relied on by both translations.

var gShiftAll = 0
  ## The shift that applies past the last edit.

var gAnchorGen = 0
  ## Bumped every time the anchor moves -- every `reanchorLocked`, and every
  ## `rebaseLocked` that actually had edits to fold in.
  ##
  ## This is what makes anchor coordinates safe to hand between the segments of
  ## one path walk while *other* readers are walking too. A read holds the
  ## document lock shared, so no patch can be running -- but a second reader
  ## can, and a reader re-anchors: the first lookup that lands inside text a
  ## patch wrote folds the edit list away. That silently changes what every
  ## anchor offset in flight means, including the cursor the first reader is
  ## halfway down a path with, and the result would be a byte range out of the
  ## middle of some other item -- the one failure this file's whole design
  ## exists to refuse.
  ##
  ## So a walk records the generation it started in and every lookup re-checks
  ## it. A mismatch is not an error and not a miss: it is a restart, which is
  ## the same answer the walk already had for its own re-anchor.

const EditCeiling = 4096
  ## Edits held before the index is re-anchored. The list is only as long as
  ## the number of *distinct* regions patched -- patching the same item twice
  ## coalesces -- but a mod that writes in a loop and never reads would
  ## otherwise grow it without bound, and a translation is only cheap while it
  ## is short.

var gPartial = -1
  ## An object whose indexing was abandoned part-way, so that a rebase drops
  ## what it did manage to record rather than keeping half an object.

var gDirty = initTable[int, bool]()
  ## Objects whose *value* a patch replaced, by anchor offset.
  ##
  ## Their entry in `gIndexed` survives a translation -- the value still starts
  ## where it started -- but the member table behind it describes text that is
  ## no longer there. Without this, a member the patch added is looked up in the
  ## old table, missed, and reported as a path that does not exist: the one
  ## thing a merge must never do. Re-indexing such an object always re-anchors,
  ## because everything in it is text a patch wrote, so this set is emptied by
  ## every rebase.

proc reanchorLocked() =
  ## Drop the index and take the current document as the new anchor. This is
  ## what a wholesale replacement of the document leaves, and it is exactly
  ## what this file used to do on every single write.
  indexClear()
  clear(gDirty)
  gPartial = -1
  gEdits = @[]
  gShiftAll = 0
  inc gAnchorGen

proc toCur(a: int; okOut: var bool): int =
  ## An anchor offset, in the coordinates the document has now.
  ##
  ## Refused -- `okOut` false -- when it lands strictly inside a region a patch
  ## rewrote, because there is no honest answer: the bytes it named are gone.
  okOut = true
  if gEdits.len == 0:
    return a
  var lo = 0
  var hi = gEdits.len
  while lo < hi:
    let mid = (lo + hi) div 2
    if gEdits[mid].aStop <= a: lo = mid + 1
    else: hi = mid
  if lo >= gEdits.len:
    return a + gShiftAll
  if gEdits[lo].aStart < a:
    okOut = false
    return -1
  result = a + gEdits[lo].shiftBefore

proc toAnchor(c: int; okOut: var bool): int =
  ## A current offset, in anchor coordinates.
  ##
  ## Refused when it points into text a patch *wrote*: that text did not exist
  ## when the anchor was taken, so it has no anchor coordinate. The boundary of
  ## such a region does -- which is what lets one patched value be patched
  ## again without re-anchoring.
  okOut = true
  if gEdits.len == 0:
    return c
  var lo = 0
  var hi = gEdits.len
  while lo < hi:
    let mid = (lo + hi) div 2
    if gEdits[mid].aStart + gEdits[mid].shiftBefore + gEdits[mid].newLen <= c:
      lo = mid + 1
    else:
      hi = mid
  if lo >= gEdits.len:
    return c - gShiftAll
  let curStart = gEdits[lo].aStart + gEdits[lo].shiftBefore
  if c < curStart:
    return c - gEdits[lo].shiftBefore
  if c == curStart:
    return gEdits[lo].aStart
  okOut = false
  result = -1

proc recordEdit(aStart, aStop, newLen: int) =
  ## Fold one splice into the list. Edits wholly inside the new region are
  ## dropped: their text has just been replaced along with everything else
  ## between `aStart` and `aStop`, so the one new entry describes all of it.
  ##
  ## Nothing can *partially* overlap. `aStart` and `aStop` came back from
  ## `toAnchor`, which only ever returns an offset outside every edit or the
  ## exact start of one -- never a point in the middle -- so an existing edit is
  ## either disjoint from the new region or contained in it.
  var next: seq[Edit] = @[]
  for e in gEdits:
    if e.aStop <= aStart:
      next.add e
  next.add Edit(aStart: aStart, aStop: aStop, newLen: newLen, shiftBefore: 0)
  for e in gEdits:
    if e.aStart >= aStop:
      next.add e
  var shift = 0
  var i = 0
  while i < next.len:
    next[i].shiftBefore = shift
    shift = shift + next[i].newLen - (next[i].aStop - next[i].aStart)
    inc i
  gEdits = next
  gShiftAll = shift

proc rebaseLocked() =
  ## Take the current document as the new anchor **without throwing the index
  ## away**: every offset is translated, and only the entries that cannot be --
  ## the ones naming text a patch wrote, which never had an anchor coordinate
  ## -- are dropped.
  ##
  ## This is the difference between a re-anchor costing a hash pass over the
  ## index and costing a fresh scan of the document. A mod filling in a table it
  ## created itself re-anchors on every write, because every write puts the next
  ## lookup inside text the previous one wrote; with a clear that is a full walk
  ## of a 41 MB document per entry, and with this it is a walk of an index that
  ## has ten things in it.
  ##
  ## An object is dropped whenever *any* of its members is, and never kept with
  ## a hole in it: an object present in `gIndexed` is a promise that its member
  ## table is complete, and a lookup that finds it half-filled reports a path
  ## that exists as missing.
  if gEdits.len == 0:
    gPartial = -1
    return
  inc gAnchorGen
  # Which objects lose something, before anything is built: an object that
  # cannot keep all of its members must keep none of them.
  var dropped = initTable[int, bool]()
  if gPartial >= 0:
    dropped[gPartial] = true
  for k, v in pairs(gDirty):
    dropped[k] = true
  for k, v in pairs(gMembers):
    var i = 0
    var obj = 0
    while i < k.len and k[i] != char(31):
      obj = obj * 10 + (ord(k[i]) - ord('0'))
      inc i
    var okObj = true
    discard toCur(obj, okObj)
    var okStart = true
    discard toCur(int(v shr 32'i64), okStart)
    var okStop = true
    discard toCur(int(v and 0xFFFFFFFF'i64), okStop)
    if i >= k.len or not okObj or not okStart or not okStop:
      dropped[obj] = true

  var members = initTable[string, int64]()
  for k, v in pairs(gMembers):
    var i = 0
    var obj = 0
    while i < k.len and k[i] != char(31):
      obj = obj * 10 + (ord(k[i]) - ord('0'))
      inc i
    if i >= k.len or hasKey(dropped, obj):
      continue
    var okObj = true
    let objCur = toCur(obj, okObj)
    var okStart = true
    let vsCur = toCur(int(v shr 32'i64), okStart)
    var okStop = true
    let veCur = toCur(int(v and 0xFFFFFFFF'i64), okStop)
    if not okObj or not okStart or not okStop:
      continue
    members[$objCur & k.substr(i)] = (int64(vsCur) shl 32) or int64(veCur)

  var indexed = initTable[int, bool]()
  for k, v in pairs(gIndexed):
    if hasKey(dropped, k):
      continue
    var ok = true
    let cur = toCur(k, ok)
    if ok:
      indexed[cur] = v

  # The names, translated by exactly the rule above them and dropped by exactly
  # the same `dropped` set. An object that loses one member loses its whole
  # member table, and a key list that outlived the members it names would be a
  # list of paths a caller is about to be told do not exist.
  var names = initTable[int, string]()
  for k, v in pairs(gNames):
    if hasKey(dropped, k):
      continue
    var ok = true
    let cur = toCur(k, ok)
    if ok:
      names[cur] = v

  gMembers = members
  gIndexed = indexed
  gNames = names
  clear(gDirty)
  gPartial = -1
  gEdits = @[]
  gShiftAll = 0

proc spliceDoc(vs, ve: int; repl: string) =
  ## `gDoc[vs ..< ve] = repl`, in the document's own buffer.
  ##
  ## `beginStore` returns a pointer to the string's data and, for a string that
  ## is already long and uniquely owned with room, does no allocation and no
  ## copy -- so the whole cost here is one `moveMem` of the bytes after the edit.
  ## The three-way `substr & repl & substr` this replaced allocated two whole
  ## copies of the document and then copied both of them again into the
  ## concatenation.
  let oldLen = gDoc.len
  let tail = oldLen - ve
  let newLen = oldLen - (ve - vs) + repl.len
  # Grow first, always: `beginStore` with a shorter length would publish the
  # shorter length before the tail has been moved out of the way.
  let widest = if newLen > oldLen: newLen else: oldLen
  let p = beginStore(gDoc, widest)
  if tail > 0 and repl.len != ve - vs:
    moveMem(cast[pointer](cast[uint](p) + uint(vs + repl.len)),
            cast[pointer](cast[uint](p) + uint(ve)), tail)
  if repl.len > 0:
    copyMem(cast[pointer](cast[uint](p) + uint(vs)),
            cast[pointer](readRawData(repl)), repl.len)
  endStore(gDoc)
  if newLen < widest:
    setLen(gDoc, newLen)

proc docReplaced() =
  ## Called after `gDoc` is replaced *wholesale* -- a load, or a patch of the
  ## document root. Nothing of the old coordinates survives that, so the index
  ## goes and the new document becomes the anchor.
  cLock()
  reanchorLocked()
  cUnlock()

proc dbLoad*(text: string) =
  docWrite()
  gDoc = text
  docReplaced()
  docWriteEnd()

proc dbText*(): string =
  docRead()
  result = gDoc
  docReadEnd()

proc dbLoaded*(): bool =
  docRead()
  result = gDoc.len > 0
  docReadEnd()

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

# ----------------------------------------------------------------- the index

proc memberKey(objStart: int; name: string): string =
  ## The unit separator rather than a dot or a colon: a member name may contain
  ## either (`"5449016a4bdc2d6f028b456f Name"` in the locale table contains a
  ## space, and nothing stops a name containing a dot), and a separator that can
  ## appear in the name lets two different members collide on one key.
  result = $objStart
  result.add char(31)
  result.add name

proc indexObject(objA: int; wantNames: bool): bool =
  ## Enumerates the immediate members of the object at anchor offset `objA` and
  ## records each one's byte range, in anchor coordinates. Caller holds the
  ## lock.
  ##
  ## `wantNames` additionally records the member *names*, as the JSON array
  ## text `dbKeysPath` answers with. It is off for every ordinary path walk:
  ## the enumeration is free -- these names are read and discarded here either
  ## way -- but *keeping* them is not, and a walk indexes objects nobody asked
  ## to enumerate. See `gNames`.
  ##
  ## This is `findKeyIn`'s loop with the early return taken out: the scan it
  ## does to find one member finds all of them on the way past, and throwing
  ## that away was the waste.
  ##
  ## False means "not in these coordinates" -- either the object itself or one
  ## of its members lives in text a patch wrote, which has no anchor
  ## coordinate. The caller re-anchors and asks again. It is never a report
  ## that the object is malformed; a malformed object indexes as far as it
  ## parses and returns true, exactly as it always did.
  var ok = true
  let objStart = toCur(objA, ok)
  if not ok:
    return false
  gIndexed[objA] = true
  # Whatever was remembered about this object's names describes the text that
  # was here before, and this call is re-reading it. Dropped **first**, so that
  # every path out of the loop below -- including the two that give up part-way
  # -- leaves no entry rather than a stale one. Fail closed: no answer is a
  # scan next time, a wrong answer is a list of paths that are not there.
  if wantNames:
    del(gNames, objA)
  # The array is built as the loop goes and stored at **every** exit that
  # returns true, including the four that give up on malformed text. An object
  # that indexes as far as it parses answers with the members it has, exactly
  # as `gMembers` describes the members it has -- the alternative is a
  # `dbKeysPath` that rescans a truncated object on every single call.
  var names = "["
  var i = objStart
  skipWs(gDoc, i)
  if i >= gDoc.len or gDoc[i] != '{':
    if wantNames:
      names.add ']'
      gNames[objA] = names
    return true
  inc i
  while i < gDoc.len:
    skipWs(gDoc, i)
    if i < gDoc.len and gDoc[i] == '}':
      if wantNames:
        names.add ']'
        gNames[objA] = names
      return true
    if i >= gDoc.len or gDoc[i] != '"':
      if wantNames:
        names.add ']'
        gNames[objA] = names
      return true
    let nameStart = i
    if not skipString(gDoc, i):
      if wantNames:
        names.add ']'
        gNames[objA] = names
      return true
    let name = gDoc.substr(nameStart + 1, i - 2)
    skipWs(gDoc, i)
    if i >= gDoc.len or gDoc[i] != ':':
      if wantNames:
        names.add ']'
        gNames[objA] = names
      return true
    inc i
    skipWs(gDoc, i)
    let vs = i
    if not skipValue(gDoc, i):
      if wantNames:
        names.add ']'
        gNames[objA] = names
      return true
    var okStart = true
    let vsA = toAnchor(vs, okStart)
    var okStop = true
    let veA = toAnchor(i, okStop)
    if not okStart or not okStop:
      gPartial = objA
      return false
    gMembers[memberKey(objA, name)] = (int64(vsA) shl 32) or int64(veA)
    if wantNames:
      # The document's own bytes, quoted. `name` is the *source* text between
      # the quotes, so whatever escaping the document used is carried through
      # unchanged and the result is valid JSON without re-escaping anything --
      # which also means a name is answered with exactly the spelling a caller
      # would have to hand back to `db_get`.
      if names.len > 1:
        names.add ','
      names.add '"'
      names.add name
      names.add '"'
    skipWs(gDoc, i)
    if i < gDoc.len and gDoc[i] == ',':
      inc i
      continue
    if i < gDoc.len and gDoc[i] == '}':
      if wantNames:
        names.add ']'
        gNames[objA] = names
      return true
  # Ran off the end of the document: a truncated object. Same rule.
  if wantNames:
    names.add ']'
    gNames[objA] = names
  result = true

const RestartCeiling = 8
  ## Restarts one `locate` will take before it reports the path as missing.
  ## See the loop at the bottom of `locate` for why a single retry is no longer
  ## enough and why this cannot spin.

# `gRestart` used to be a `var` up here, set when a lookup gave up its
# coordinates so that `locate` would walk the path again rather than report a
# path that is there as missing. One global, written by every reader.
#
# With one thread that is a flag. With sixteen it is a lost retry and a
# spurious one at once: reader A re-anchors and sets it, reader B's next
# `locate` clears it, and A's walk answers "no such path" for a path that is
# there -- which the emulator reads as a missing item template. It is a
# parameter now, threaded down the walk, so a restart belongs to the walk that
# earned it.

proc indexedFind(objA: int; key: string; valueStart, valueEnd: var int;
                 gen: var int; restart: var bool): bool =
  ## `objA` and the range returned are anchor offsets. `gen` is the anchor
  ## generation this walk believes it is in.
  valueStart = -1
  valueEnd = -1
  cLock()
  if gen != gAnchorGen:
    # Another reader re-anchored between two segments of this walk. `objA` is
    # in coordinates that have stopped meaning anything, and translating it
    # would answer with somebody else's bytes. Start again from the root.
    cUnlock()
    restart = true
    return false
  var obj = objA
  if not hasKey(gIndexed, obj) or hasKey(gDirty, obj):
    if len(gMembers) > IndexCeiling:
      indexClear()
    if not indexObject(obj, false):
      # The object, or something in it, is text a patch wrote. Re-anchor --
      # after which anchor coordinates *are* current ones -- and index it
      # there. `toCur` is taken before the re-anchor, while the old
      # coordinates still mean something.
      var ok = true
      let cur = toCur(obj, ok)
      rebaseLocked()
      gen = gAnchorGen
      if not ok:
        # `objA` itself was stale: the caller is walking with an offset from
        # before some patch, and the walk has to start again.
        restart = true
        cUnlock()
        return false
      obj = cur
      discard indexObject(obj, false)
  let packed = getOrDefault(gMembers, memberKey(obj, key), 0'i64)
  cUnlock()
  if packed == 0'i64:
    return false
  valueStart = int(packed shr 32'i64)
  valueEnd = int(packed and 0xFFFFFFFF'i64)
  result = true

proc locateOnce(path: string; valueStart, valueEnd: var int;
                restart: var bool): bool =
  ## One walk. Anchor coordinates on the way down, current ones on the way out,
  ## so every caller above this line sees the document as it is now.
  ##
  ## The caller holds the document lock -- shared for a read, exclusive for a
  ## patch -- so `gDoc` cannot move underneath this. What it does not hold is
  ## the index lock, which is taken and dropped per segment; every stretch of
  ## anchor arithmetic below is inside it, because `toAnchor` and `toCur` read
  ## the edit list and another reader's re-anchor rewrites it. That the root's
  ## translation was outside it was a genuine hole and not a stylistic one.
  valueStart = -1
  valueEnd = -1
  if gDoc.len == 0:
    return false
  var start = 0
  skipWs(gDoc, start)
  cLock()
  var gen = gAnchorGen
  var okRoot = true
  let rootA = toAnchor(start, okRoot)
  if not okRoot:
    # The document's first byte is inside something a patch wrote -- a patch of
    # the root itself. Nothing of the old coordinates is worth keeping.
    rebaseLocked()
    cUnlock()
    restart = true
    return false
  cUnlock()
  var cursor = rootA
  var first = true
  for part in split(path, '.'):
    if part.len == 0:
      continue
    var vs = 0
    var ve = 0
    let base = if first: rootA else: cursor
    if not indexedFind(base, part, vs, ve, gen, restart):
      return false
    cursor = vs
    valueStart = vs
    valueEnd = ve
    first = false
  if valueStart < 0:
    return false
  # Out of anchor coordinates. A refusal here is a stale index entry -- an
  # offset inside a region some later patch rewrote -- and is answered by
  # re-anchoring and walking again, never by reporting the path as missing.
  cLock()
  if gen != gAnchorGen:
    cUnlock()
    restart = true
    return false
  var okStart = true
  let curStart = toCur(valueStart, okStart)
  var okStop = true
  let curStop = toCur(valueEnd, okStop)
  if not okStart or not okStop:
    rebaseLocked()
    cUnlock()
    restart = true
    return false
  cUnlock()
  valueStart = curStart
  valueEnd = curStop
  result = true

proc locate(path: string; valueStart, valueEnd: var int): bool =
  ## Walks a dotted path down from the document root, one indexed lookup per
  ## part. The first part is looked up in the root object, whose index is the
  ## one full pass over the document that this design pays exactly once.
  ##
  ## The caller holds the document lock.
  var restart = false
  result = locateOnce(path, valueStart, valueEnd, restart)
  var tries = 0
  while not result and restart and tries < RestartCeiling:
    # A second walk normally runs against a freshly anchored index, in which
    # every offset is a current offset and nothing can be stale -- so one retry
    # was the whole of this while one thread was the whole story.
    #
    # It is not enough now. A read holds the document lock *shared*, so a
    # second reader can re-anchor between this walk and its retry and send it
    # back again. Each restart is progress -- there is one anchor, the
    # generation only moves forward, and a re-anchor leaves anchor coordinates
    # equal to current ones -- but the progress is not bounded by one, so this
    # is a bounded loop rather than a single retry. Bounded rather than open so
    # that it cannot become a spin: reaching the ceiling reports the path as
    # missing, which is the honest answer about a database being re-anchored
    # faster than it can be read.
    restart = false
    inc tries
    result = locateOnce(path, valueStart, valueEnd, restart)

proc isDocWs(c: char): bool =
  ## The four characters JSON allows between tokens.
  result = c == ' ' or c == '\t' or c == '\n' or c == '\r'

proc trimmed(start, stop1: int): string =
  ## `gDoc[start ..< stop1]` with the whitespace trimmed by moving the indices,
  ## not by copying twice.
  ##
  ## `strip(gDoc.substr(a, b))` reads as one operation and is two allocations
  ## of the whole value: `substr` cuts it out, `strip` copies the result again
  ## to shave whitespace off the ends. On `templates.items` that is four
  ## megabytes copied for nothing -- `locate` already left `valueStart` past
  ## the leading whitespace, so in the ordinary case `strip` has nothing at all
  ## to do and the second copy is pure waste.
  var a = start
  var b = stop1
  while a < b and (gDoc[a] == ' ' or gDoc[a] == '\t' or gDoc[a] == '\n' or
                   gDoc[a] == '\r'):
    inc a
  while b > a and (gDoc[b - 1] == ' ' or gDoc[b - 1] == '\t' or
                   gDoc[b - 1] == '\n' or gDoc[b - 1] == '\r'):
    dec b
  if b <= a:
    return ""
  result = gDoc.substr(a, b - 1)

proc dbGetPath*(path: string; into: var string): bool =
  ## The read path, and the hot one.
  ##
  ## The document lock is held **shared for the whole of this**, walk and copy
  ## alike, and the copy is the half that matters: `trimmed` is a 12.5 MB
  ## `substr` out of `gDoc`'s buffer for `/client/items`, and a patch that
  ## spliced or grew that buffer underneath it is a use-after-free, not a torn
  ## read. Shared means readers still do not wait for each other -- which is
  ## the property this whole file is arranged around -- and a patch waits for
  ## them, which is the cost, and it is a cost writes already pay in
  ## milliseconds.
  into = ""
  docRead()
  var vs = 0
  var ve = 0
  if not locate(path, vs, ve):
    docReadEnd()
    return false
  into = trimmed(vs, ve)
  docReadEnd()
  result = true

proc dbHoldPath*(path: string; at: var pointer; length: var int): bool =
  ## `dbGetPath` without the copy: the value is left where it lives, and this
  ## returns a pointer straight into the document's own buffer.
  ##
  ## **It returns with the document read lock still held**, and the caller must
  ## call `dbRelease()` when it has finished with the bytes. That is a shape
  ## worth being uncomfortable about, so here is why it is the right one and
  ## what makes it safe.
  ##
  ## The only caller is `hostDbGet`, whose whole job is to put the value into a
  ## host buffer for a mod. Through `dbGetPath` that is *two* copies of the
  ## value -- `trimmed` cuts it out of the document into a nimony string, and
  ## `aowl_out_copy` then copies that string into the host buffer -- and on
  ## `templates.items` against a real database each of those is 12.5 MB. One of
  ## them is pure transit.
  ##
  ## The lock is held for no longer than `dbGetPath` already held it. `trimmed`
  ## copies *under* the read lock, and for exactly the reason this must: the
  ## document lock is what stops a concurrent `dbPatchPath` splicing or
  ## reallocating the buffer the copy is reading. Shared means readers still do
  ## not wait on each other; a writer waits for them, which it did before.
  ##
  ## What the caller must not do is take any other lock while holding this, or
  ## call back into `jsondb`. `hostDbGet` does neither: between the two calls it
  ## makes one `aowl_out_copy`, which allocates and memcpys and nothing else.
  ## The order this file keeps -- document first, index second, never `cLock`
  ## then the document -- is unchanged, because no second lock is taken at all.
  at = cast[pointer](0)
  length = 0
  docRead()
  var vs = 0
  var ve = 0
  if not locate(path, vs, ve):
    docReadEnd()
    return false
  var a = vs
  var b = ve
  while a < b and isDocWs(gDoc[a]):
    inc a
  while b > a and isDocWs(gDoc[b - 1]):
    dec b
  at = cast[pointer](cast[uint](readRawData(gDoc)) + uint(a))
  length = b - a
  result = true

proc dbRelease*() =
  ## The other half of `dbHoldPath`. Separate rather than a template taking a
  ## block because there is one call site and a block form would invite more.
  docReadEnd()

# ------------------------------------------------------------ key enumeration

const
  KeysNoSuchPath* = 1
    ## `dbKeysPath` refused: there is no such path. Distinct from an object
    ## with no members, which answers `true` with `[]`.
  KeysNotAnObject* = 2
    ## `dbKeysPath` refused: the path is an array or a scalar.

const KeysSigil* = "?keys "
  ## The reserved prefix that turns a `db_get` into a key enumeration.
  ##
  ## The whole of `docs/API-GAPS.md`'s gap 2 comes down to this string, and it
  ## is a string rather than an ABI entry on purpose. A host entry means
  ## revision 6, and revision 6 cannot be reached by the simulator without it
  ## first claiming revision 5 -- installing a refusing `notify_push` it has no
  ## socket for -- which flips `notifyReady()` from an honest `false` to `true`
  ## in the one host a mod author develops against. A sigil costs none of that
  ## and **degrades without a capability test**: a host that has never heard of
  ## it walks the path, finds no root member literally named `?keys locations`,
  ## and answers `ErrNotFound`, which is exactly the answer a caller needs.
  ##
  ## The cost is that it is a side channel in a string, and the collision is
  ## real rather than theoretical: nothing stops a JSON member name containing
  ## a space, a question mark, or both -- `memberKey`'s own comment is about
  ## names with spaces in them. A root member literally named `?keys locations`
  ## would be shadowed by this. The root of an SPT database has members named
  ## `templates`, `locations`, `globals`, `traders`; the collision is not
  ## credible, and it is still a collision, and this comment is where it is
  ## written down. Only the **root** is exposed: a nested member named
  ## `?keys x` is unreachable through this only if the whole path begins with
  ## the sigil, and `"a.?keys b"` is not affected at all.

proc dbKeysRequest*(path: string; rest: var string): bool =
  ## Splits `KeysSigil` off the front of a `db_get` path.
  ##
  ## True means this is a key enumeration and `rest` is the path to enumerate,
  ## **which may be empty**: `"?keys "` on its own is a deliberate answer and
  ## not an accident. A host that implements this refuses it with
  ## `ErrBadArg`; a host that does not answers `ErrNotFound`, because there is
  ## no root member called `"?keys "`. That difference is the capability probe,
  ## and it costs one call and no ABI surface.
  rest = ""
  if path.len < KeysSigil.len:
    return false
  var i = 0
  while i < KeysSigil.len:
    if path[i] != KeysSigil[i]:
      return false
    inc i
  rest = path.substr(KeysSigil.len)
  result = true

proc dbKeysPath*(path: string; into: var string; why: var int): bool =
  ## The immediate member names of the object at `path`, as JSON array text,
  ## in document order, duplicates included if the document has them.
  ##
  ## False sets `why` to `KeysNoSuchPath` or `KeysNotAnObject`, and the caller
  ## turns those into `ErrNotFound` and `ErrBadArg`. **The two are not the
  ## same question and must not be folded together**: an object with no members
  ## answers `true` with `[]`, and a caller that reads "no keys" out of "no
  ## such path" will create a table over the top of one it failed to read.
  ##
  ## An array is refused rather than answered with `["0","1",...]`. For a
  ## hundred thousand elements that is a 700 KB reply to a question whose real
  ## form is "how long is it", and a caller that wanted indices already has the
  ## length from a `db_get`.
  ##
  ## ## What it costs
  ##
  ## The answer is `sum(len(name)) + 3n` bytes for `n` members -- about 2.7 MB
  ## for a table of 100k Mongo ids, which is 200x smaller than reading that
  ## subtree and is **not small**. The doc comment gives the formula rather
  ## than the word "cheap" for that reason.
  ##
  ## The first call on an object walks it once: `skipValue` steps over every
  ## byte of the subtree without parsing any of it, and nothing is copied out
  ## of it. That is the same walk the next `db_get` into that object was going
  ## to pay, so it makes later reads faster rather than slower. Later calls on
  ## the same object are a table lookup and a copy of the answer.
  ##
  ## ## What it is not
  ##
  ## It is a **snapshot**, not an index. Between this and a `db_get` of a child
  ## another mod may patch; that is true of every read here, and a key list
  ## looks enough like an index to invite being cached when it should not be.
  ## Document order is the document's, and `dbPatchPath` merges -- `mergeInto`
  ## can move a member -- so the order may change when anything patches that
  ## object. Nobody promised the order; this says so.
  into = ""
  why = 0
  docRead()
  var vs = 0
  var ve = 0
  if not locate(path, vs, ve):
    docReadEnd()
    why = KeysNoSuchPath
    return false
  var i = vs
  while i < ve and isDocWs(gDoc[i]):
    inc i
  if i >= ve or gDoc[i] != '{':
    docReadEnd()
    why = KeysNotAnObject
    return false

  # From here down is the index, and the order of the two locks is the order
  # this file keeps everywhere: the document lock is held (shared, from
  # `docRead` above) and the index lock is taken **inside** it, never the other
  # way round. `dbGetPath` and `dbHoldPath` are the same shape.
  #
  # Everything that reads or writes `gNames` is inside one `cLock`, which is
  # what makes it safe to key by an anchor offset computed from a current one:
  # `toAnchor(i)` is only meaningful while the edit list is what it was when it
  # was taken, and no other reader can re-anchor between the translation and
  # the lookup because a re-anchor is under this same lock. The document lock
  # being held shared means no *patch* can run at all, so `i` itself cannot
  # move. There is no walk in flight here to invalidate -- `locate` has already
  # returned -- so unlike `indexedFind` this has no generation to re-check and
  # no restart to report.
  cLock()
  var okA = true
  var objA = toAnchor(i, okA)
  if okA and not hasKey(gDirty, objA):
    let cached = getOrDefault(gNames, objA, "")
    if cached.len > 0:
      into = cached
      cUnlock()
      docReadEnd()
      return true
  if not okA or not indexObject(objA, true):
    # The object, or a member of it, is text a patch wrote and has no anchor
    # coordinate. Re-anchor, after which anchor coordinates *are* current ones
    # -- and `i` is a current offset that no patch can have moved, because the
    # document lock has been held shared throughout. So unlike `indexedFind`
    # there is nothing to translate and nothing that can fail twice.
    rebaseLocked()
    objA = i
    discard indexObject(objA, true)
  into = getOrDefault(gNames, objA, "")
  cUnlock()
  docReadEnd()
  if into.len == 0:
    # `indexObject` returning true always leaves an entry, so this is
    # unreachable -- and it is written down rather than assumed, because the
    # honest answer to "I do not have the names" is not an empty key list.
    why = KeysNotAnObject
    return false
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

proc applyPatch(vs, ve: int; merged: string) =
  ## Put `merged` where `gDoc[vs ..< ve]` is, and keep the index.
  ##
  ## The two translations are taken *before* the splice, while the coordinates
  ## still describe the document the index was read from; the edit is recorded
  ## after, so a reader that arrives between them sees either the old document
  ## with the old map or the new document with the new one, and never a map
  ## that describes neither.
  cLock()
  var okStart = true
  var aStart = toAnchor(vs, okStart)
  var okStop = true
  var aStop = toAnchor(ve, okStop)
  if not okStart or not okStop or gEdits.len >= EditCeiling:
    # Either this patch lands in text an earlier one wrote -- which has no
    # anchor coordinate to record against -- or the list has grown as long as
    # it is allowed to. Both are answered by folding what is there into a new
    # anchor first, after which anchor coordinates and current ones are the
    # same thing and this patch records against them cleanly.
    rebaseLocked()
    aStart = vs
    aStop = ve
  spliceDoc(vs, ve, merged)
  recordEdit(aStart, aStop, merged.len)
  gDirty[aStart] = true
  cUnlock()

proc patchLocked(path, patchJson: string; error: var string): bool =
  ## The caller holds the document lock exclusively.
  error = ""
  if gDoc.len == 0:
    error = "no database is loaded"
    return false

  var vs = 0
  var ve = 0
  if locate(path, vs, ve):
    let existing = trimmed(vs, ve)
    let merged = mergeInto(existing, strip(patchJson))
    applyPatch(vs, ve, merged)
    return true

  # Find the deepest prefix that does exist, and merge the missing tail into it
  # as nested objects. `have == 0` means not even the first member is there, so
  # the tail is merged into the document itself.
  let parts = splitPath(path)
  if parts.len == 0:
    let merged = mergeInto(strip(gDoc), strip(patchJson))
    gDoc = merged
    docReplaced()
    return true

  var have = parts.len - 1
  while have > 0:
    if locate(joinPathParts(parts, have), vs, ve):
      break
    dec have

  let tail = wrapUnder(parts, have, strip(patchJson))
  if have == 0:
    gDoc = mergeInto(strip(gDoc), tail)
    docReplaced()
    return true
  if not locate(joinPathParts(parts, have), vs, ve):
    error = "could not create the database path: " & path
    return false
  let existing = trimmed(vs, ve)
  applyPatch(vs, ve, mergeInto(existing, tail))
  result = true

proc dbPatchPath*(path, patchJson: string; error: var string): bool =
  ## Merges `patchJson` into the value at `path`, **creating the path when it is
  ## not there**.
  ##
  ## Creating rather than refusing, because refusing made the API unable to
  ## express the ordinary thing: a mod adding a table of its own, or a location
  ## the database has never held. A patch of an existing member is still a
  ## merge, so nothing a mod did not name is disturbed either way.
  ##
  ## The document lock is held **exclusively across the whole operation**, not
  ## merely across the splice. The splice is not the only part that touches the
  ## document: the merge reads the existing value out of it first, and a merge
  ## against a value some other patch has since replaced writes back text that
  ## was never there -- a lost update rather than a crash, which is the harder
  ## kind to notice. Read, merge and write are one operation or they are a race,
  ## and this is the only place that can say so.
  ##
  ## It is the whole of `dbPatchPath` rather than of `applyPatch` for the same
  ## reason the session lock in `aowlbackend.nim` wraps the whole handler rather
  ## than the store call: anything narrower leaves the same race in a smaller
  ## window.
  docWrite()
  result = patchLocked(path, patchJson, error)
  docWriteEnd()

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
