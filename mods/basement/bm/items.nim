## bm/items — free text -> real item templates (DESIGN.md §11).
##
## "There is a weapons cache at the quarry" has to become rows the client can
## actually spawn, or the whole grounding claim is prose. This module is the
## only place that knows what an item IS, and it learns it from the database
## the host loaded, never from a table written here.
##
## DECISIONS MADE HERE (the contract left them open):
##
## * **The index is built LAZILY and NEVER by reading `templates.items` whole.**
##   `dbKeysOrRead` asks the host to enumerate the member names; only then is a
##   per-item `_props.Name` read. On `aowlspt-backend` that is `dbKeys` (a list
##   of ids); on a host with no key enumeration it falls back to one subtree
##   read and SAYS SO in the note (`scanned`). 41 MB is never crossed as one
##   value by this module.
## * **Classification is by NAME WORDS, and the note says it is a heuristic.**
##   The real signal is `_parent` (the item's class id), and it is read and
##   counted -- but the ids mean nothing without the class table, and the
##   emutest fixture carries no `_parent` at all (MEASURED 2026-09-06: 34 of 34
##   items have neither `_name` nor `_parent`). So `data/lootkinds.json`
##   supplies the word lists, the resolver reports how many items it could
##   classify, and nothing pretends the classification is authoritative.
## * **No index is INCONCLUSIVE, never an empty success.** `resolveItems`
##   returns 0 with a note that begins `INCONCLUSIVE` when there is no
##   database, and the caller is expected to build the cache anyway -- with its
##   story and its guards -- rather than silently produce an empty cache that
##   reads exactly like a resolved one.
## * **Every random draw comes from the caller's `Rng`.** Generation must stay
##   reproducible from the seed, so this module holds no generator of its own.

import std/strutils
import aowlspt
import aowlspt/server as sv
import aowlspt/json as jr
import util
import rng

const ItemsPath = "templates.items"
const IndexCap = 60000
  ## A refusal bound, not a tuning knob: an index bigger than this is a
  ## database this walk should not be walking one key at a time, and the note
  ## says it stopped rather than letting a route sit there.

# ------------------------------------------------------------------ the index
var gTpl: seq[string] = @[]
var gName: seq[string] = @[]
var gClass: seq[string] = @[]
var gBuilt: bool = false
var gBuildNote: string = "not built"
var gParents: int = 0

# ------------------------------------------------------------------ the data
var gKindId: seq[string] = @[]
var gKindWords: seq[string] = @[]      ## space-joined, normalised
var gKindClasses: seq[string] = @[]    ## space-joined
var gKindMinItems: seq[int] = @[]
var gKindMaxItems: seq[int] = @[]
var gKindStackMin: seq[int] = @[]
var gKindStackMax: seq[int] = @[]

var gClassName: seq[string] = @[]
var gClassWords: seq[string] = @[]

var gNumWord: seq[string] = @[]
var gNumVal: seq[int] = @[]
var gStop: seq[string] = @[]
var gDataNote: string = "lootkinds.json not loaded"

proc itemsDataNote*(): string = gDataNote
proc itemsBuildNote*(): string = gBuildNote
proc itemsIndexReady*(): bool = gBuilt and gTpl.len > 0
proc itemsIndexSize*(): int = gTpl.len
proc itemsKindCount*(): int = gKindId.len

proc textList(j: JsonRef): seq[string] =
  result = @[]
  for e in jr.each(j):
    let t = jr.asText(e, "")
    if t.len > 0: result.add t

proc joinWords(items: seq[string]): string =
  result = ""
  for it in items:
    if result.len > 0: result.add " "
    result.add normalizeText(it)

proc wordsIn(s: string): seq[string] =
  result = @[]
  for w in s.split(' '):
    if w.len > 0: result.add w

proc itemsConfigure*(lootKindsJson: string) =
  ## `data/lootkinds.json`. An empty or unparsable document leaves every table
  ## empty and says so; the resolver then answers INCONCLUSIVE rather than
  ## resolving from something invented in here.
  gKindId = @[]; gKindWords = @[]; gKindClasses = @[]
  gKindMinItems = @[]; gKindMaxItems = @[]
  gKindStackMin = @[]; gKindStackMax = @[]
  gClassName = @[]; gClassWords = @[]
  gNumWord = @[]; gNumVal = @[]; gStop = @[]
  if lootKindsJson.len == 0:
    gDataNote = "data/lootkinds.json is missing or empty -- no kind words, so " &
                "a cache description resolves only by exact item name"
    return
  let root = jr.whole(lootKindsJson)
  if not jr.exists(root) or not jr.isObject(root):
    gDataNote = "data/lootkinds.json is not a JSON object -- nothing loaded"
    return
  for k in jr.each(jr.child(root, "kinds")):
    let id = jr.asText(jr.child(k, "id"), "")
    if id.len == 0: continue
    gKindId.add id
    gKindWords.add joinWords(textList(jr.child(k, "words")))
    gKindClasses.add joinWords(textList(jr.child(k, "classes")))
    gKindMinItems.add jr.asInt(jr.child(k, "minItems"), 1)
    gKindMaxItems.add jr.asInt(jr.child(k, "maxItems"), 2)
    gKindStackMin.add jr.asInt(jr.child(k, "stackMin"), 1)
    gKindStackMax.add jr.asInt(jr.child(k, "stackMax"), 1)
  for c in jr.each(jr.child(root, "classWords")):
    let cn = jr.asText(jr.child(c, "class"), "")
    if cn.len == 0: continue
    gClassName.add cn
    gClassWords.add joinWords(textList(jr.child(c, "words")))
  for n in jr.each(jr.child(root, "numberWords")):
    let w = normalizeText(jr.asText(jr.child(n, "word"), ""))
    if w.len == 0: continue
    gNumWord.add w
    gNumVal.add jr.asInt(jr.child(n, "n"), 1)
  gStop = wordsIn(joinWords(textList(jr.child(root, "stopWords"))))
  gDataNote = $gKindId.len & " kinds, " & $gClassName.len & " class word sets, " &
              $gNumWord.len & " number words, " & $gStop.len & " stop words"

proc classifyName(name: string): string =
  ## The heuristic, kept in one place. Returns "" when no class word matched --
  ## an unclassified item is still in the index and still resolvable BY NAME.
  let n = normalizeText(name)
  if n.len == 0: return ""
  var i = 0
  while i < gClassName.len:
    for w in wordsIn(gClassWords[i]):
      if containsWord(n, w): return gClassName[i]
    i = i + 1
  result = ""

proc itemsIndexBuild*(note: var string): int =
  ## Returns how many templates landed in the index. Safe to call twice: it
  ## rebuilds, because a host may have loaded a different database since.
  gTpl = @[]; gName = @[]; gClass = @[]
  gParents = 0
  gBuilt = false
  var keys: seq[string] = @[]
  var scanned = false
  let st = dbKeysOrRead(ItemsPath, keys, scanned)
  if st != Ok:
    gBuildNote = "no `" & ItemsPath & "` on this host (the db read was " &
                 "refused) -- no item can be resolved " &
                 "to a template. This is INCONCLUSIVE, not 'the cache is empty'."
    note = gBuildNote
    return 0
  if keys.len > IndexCap:
    gBuildNote = ItemsPath & " has " & $keys.len & " entries, over the " &
                 $IndexCap & " cap -- REFUSING to read them one at a time; " &
                 "no index was built"
    note = gBuildNote
    return 0
  var classified = 0
  var i = 0
  while i < keys.len:
    let id = keys[i]
    i = i + 1
    if id.len == 0: continue
    var nm = asText(dbRead(ItemsPath & "." & id & "._props.Name"))
    if nm.len == 0: nm = asText(dbRead(ItemsPath & "." & id & "._name"))
    let parent = asText(dbRead(ItemsPath & "." & id & "._parent"))
    if parent.len > 0: gParents = gParents + 1
    let cls = classifyName(nm)
    if cls.len > 0: classified = classified + 1
    gTpl.add id
    gName.add nm
    gClass.add cls
  gBuilt = true
  gBuildNote = $gTpl.len & " templates indexed from " & ItemsPath &
               (if scanned: " (by SUBTREE READ -- this host has no key " &
                            "enumeration)" else: " (by dbKeys)") & "; " &
               $classified & " classified by name word, " & $gParents &
               " carried a `_parent` (the authoritative class id, unused here " &
               "because the class table is not in the database this reads)"
  note = gBuildNote
  result = gTpl.len

proc itemName*(tpl: string): string =
  var i = 0
  while i < gTpl.len:
    if gTpl[i] == tpl: return gName[i]
    i = i + 1
  result = ""

proc itemsOfClass*(cls: string): seq[int] =
  result = @[]
  var i = 0
  while i < gTpl.len:
    if gClass[i] == cls: result.add i
    i = i + 1

proc numberBefore(words: seq[string]; at: int): int =
  ## The count word immediately in front of a matched name, if there is one.
  if at <= 0: return 1
  let w = words[at - 1]
  var i = 0
  while i < gNumWord.len:
    if gNumWord[i] == w:
      if gNumVal[i] > 0: return gNumVal[i]
      return 1
    i = i + 1
  var v = 0
  var any = false
  for ch in w:
    if ch >= '0' and ch <= '9':
      v = v * 10 + (ord(ch) - ord('0'))
      any = true
    else:
      return 1
  if any and v > 0: return v
  result = 1

proc isStop(w: string): bool =
  for s in gStop:
    if s == w: return true
  result = false

proc resolveItems*(text: string; r: var Rng; tpls: var seq[string];
                   counts: var seq[int]; note: var string): int =
  ## Free text -> (template, count) pairs, index-aligned.
  ##
  ## Two passes, in this order, because a named item is a fact and a kind word
  ## is a guess: exact item names first, then the kind words of
  ## `lootkinds.json`. Every unmatched word of three characters or more is
  ## listed in `note` -- an item resolver that quietly drops half the sentence
  ## is exactly the silent failure this project keeps paying for.
  tpls = @[]
  counts = @[]
  if not itemsIndexReady():
    note = "INCONCLUSIVE: no item template index (" & gBuildNote &
           "). No item was resolved; the cache still exists, with its story " &
           "and its guards."
    return 0
  let norm = normalizeText(text)
  let words = wordsIn(norm)
  var used: seq[string] = @[]
  var matchedWords: seq[string] = @[]

  # pass 1 -- exact item names
  var i = 0
  while i < gTpl.len:
    let nm = normalizeText(gName[i])
    if nm.len >= 3 and containsWord(norm, nm):
      let nw = wordsIn(nm)
      var at = -1
      var k = 0
      while k < words.len:
        if words[k] == nw[0]: at = k
        k = k + 1
      tpls.add gTpl[i]
      counts.add numberBefore(words, at)
      used.add gTpl[i]
      for w in nw: matchedWords.add w
    i = i + 1

  # pass 2 -- kind words from data/lootkinds.json
  var ki = 0
  while ki < gKindId.len:
    var hit = ""
    for w in wordsIn(gKindWords[ki]):
      if containsWord(norm, w):
        hit = w
        break
    if hit.len > 0:
      matchedWords.add hit
      let want = nextInt(r, gKindMinItems[ki], gKindMaxItems[ki])
      var pool: seq[int] = @[]
      for cls in wordsIn(gKindClasses[ki]):
        for idx in itemsOfClass(cls): pool.add idx
      if pool.len == 0:
        discard
      else:
        var picked = 0
        var guard = 0
        while picked < want and guard < 32:
          guard = guard + 1
          let idx = pool[nextInt(r, 0, pool.len - 1)]
          var already = false
          for u in used:
            if u == gTpl[idx]: already = true
          if already: continue
          tpls.add gTpl[idx]
          counts.add nextInt(r, gKindStackMin[ki], gKindStackMax[ki])
          used.add gTpl[idx]
          picked = picked + 1
    ki = ki + 1

  # what did NOT resolve
  var unresolved: seq[string] = @[]
  for w in words:
    if w.len < 3: continue
    if isStop(w): continue
    var seen = false
    for m in matchedWords:
      if m == w: seen = true
    if not seen:
      var dup = false
      for u in unresolved:
        if u == w: dup = true
      if not dup and unresolved.len < 8: unresolved.add w
  var names = ""
  var n = 0
  while n < tpls.len:
    if names.len > 0: names.add ", "
    names.add $counts[n] & "x " & itemName(tpls[n])
    n = n + 1
  note = $tpls.len & " item row(s) resolved from " & $gTpl.len &
         " templates: " & names
  if unresolved.len > 0:
    note.add "; NOT resolved: "
    var u = 0
    while u < unresolved.len:
      if u > 0: note.add " "
      note.add unresolved[u]
      u = u + 1
  result = tpls.len

# ---------------------------------------------------------------------------
# kind words, for the generator
# ---------------------------------------------------------------------------

proc itemsKindIds*(): seq[string] =
  result = @[]
  var i = 0
  while i < gKindId.len:
    result.add gKindId[i]
    i = i + 1

proc kindWordFor*(text: string; r: var Rng): string =
  ## Which kind of cache a faction's want describes ("ammunition in any
  ## calibre" -> `ammo`). No match draws one, so a faction always has a cache
  ## kind -- but the draw comes from the caller's `Rng`, so the world stays
  ## reproducible. "" only when `lootkinds.json` did not load at all.
  if gKindId.len == 0: return ""
  let norm = normalizeText(text)
  var i = 0
  while i < gKindId.len:
    for w in wordsIn(gKindWords[i]):
      if containsWord(norm, w): return gKindId[i]
    i = i + 1
  result = gKindId[nextInt(r, 0, gKindId.len - 1)]
