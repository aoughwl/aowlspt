## The `_props` members of `/client/items` that REAL BSG sends and our
## database does not.
##
## Why this exists
## ---------------
## `/client/items` is the biggest document this server serves (12.7 MB, 4,673
## item templates) and until now it had never been diffed against anything.
## `tools/dtogap.py` reported it as NO-DTO -- the payload is a dict keyed by
## item id, so there is no single top-level class -- and "no number" was read
## as "no gap".
##
## It was then measured two ways, and both say the same thing:
##
## 1. Against the CLIENT's declarations. Each item's `_props` was diffed
##    against the best-matching `EFT.InventoryLogic.*Template` (ranked by wire
##    key overlap, the `--whichdto` method), across all 94 distinct `_props`
##    key-set signatures in our payload.
## 2. Against REAL BSG. `data/capture/raid1`, seq **045** `GET /client/items`,
##    1,036 KB gzipped / 18.3 MB decoded, `resp_xenc: aes`, `PHPSESSID`. Its
##    4,673 ids that we also serve are the ground truth used here.
##
## The BSG diff is what this table is built from, and it is narrow on purpose:
## **only keys BSG actually sent for that exact item id**. Nothing is invented
## and nothing is defaulted. 4,672 items needed at least one key; 18,309 key
## insertions in total. The largest cohorts:
##
##   RagfairLevelToTrade                             4,672 items  (every one)
##   IsNotDeletableFromQuestStashAfterQuestComplete  4,672 items  (every one)
##   CategoryAnimationModId                          2,044 items
##   AudioSettings   (WeaponTemplateAudioSettings)     177 items  REF
##   WeaponAimSettings (WeaponAiming)                  177 items  REF
##   FaceCoverMask / MaskSize                          120 items
##   the full ItemTemplate base props on the 95 category NODES that our
##   database ships with an EMPTY `_props` and BSG ships fully populated
##
## What is NOT claimed
## -------------------
## That any of these is dereferenced. `dtogap` reads a member's TYPE, not its
## use, and no consumer was disassembled. The claim is narrower and checkable:
## **for every id we serve that BSG also served, our `_props` key set is no
## longer a strict subset of BSG's.** The REF rows are the ones that would
## matter if they were dereferenced (absent -> null -> crash or hang); the
## VALUE rows take the CLR default and are carried for exactness, not urgency.
##
## What this deliberately does not do
## ----------------------------------
## Overwrite. A `_props` member the database already has always wins, so
## re-importing a newer `db.json` retires this table key by key instead of
## being shadowed by a stale capture. It does not touch the 1,154 ids BSG
## serves and we do not have -- inventing a whole template is a different and
## much larger guess than filling a member of one we already ship. And it does
## not remove `DropSoundType`, the one key we send on 4,577 items that BSG
## never sent: an extra key is ignored by Newtonsoft, an absent one is not.

import aowlspt
import aowlspt/server
import aowlspt/json
import post1

var gApplied = false
var gAddedItems = 0
var gAddedKeys = 0
var gCache = ""
var gCacheFor = ""

## How many items were touched, and how many `_props` members inserted, by the
## last apply. Both zero before the first `/client/items`, and zero afterwards
## ONLY if the database already held everything BSG sent.
proc itemsGapCounts*(): (int, int) = (gAddedItems, gAddedKeys)

proc itemsGapsApplied*(): bool = gApplied

proc mergeInto(itemsText: string): string =
  let table = post1Table("itemsgaps")
  if table.len == 0:
    # `post1Table` has already warned. Serving the database document unchanged
    # is what happened before this module existed, so this degrades to the
    # previous behaviour rather than to a broken document.
    return itemsText
  var gaps = parseObject(table)
  if not gaps.ok:
    warn "items: data/post1/itemsgaps.json is not a JSON object; " &
         "the BSG-only template members will NOT be served"
    return itemsText
  var doc = parseObject(itemsText)
  if not doc.ok:
    warn "items: the database document is not a JSON object; " &
         "the BSG-only template members will NOT be served"
    return itemsText
  gAddedItems = 0
  gAddedKeys = 0
  for g in gaps.fields:
    if not doc.has(g.name):
      continue                      # BSG had it; this database does not. Skip.
    var item = parseObject(getRaw(doc, g.name))
    if not item.ok or not item.has("_props"):
      continue
    var props = parseObject(getRaw(item, "_props"))
    if not props.ok:
      continue
    var add = parseObject(g.value)
    if not add.ok:
      continue
    var added = 0
    for m in add.fields:
      if props.has(m.name):
        continue                    # the database wins, always.
      setRaw(props, m.name, m.value)
      inc added
    if added == 0:
      continue
    setRaw(item, "_props", text(props))
    setRaw(doc, g.name, text(item))
    inc gAddedItems
    gAddedKeys += added
  gApplied = true
  if gAddedItems == 0:
    return itemsText
  result = text(doc)

proc applyItemsGaps*(itemsText: string): string =
  ## The item-template document with BSG's own `_props` members spliced in.
  ##
  ## Cached against the input text: the document is ~12.7 MB and is reparsed
  ## once, not once per request. `/client/items` is answered on the first menu
  ## load and 304'd thereafter, but a reparse of 12.7 MB per request would be
  ## a stall in the middle of a menu transition even so.
  if gCacheFor.len > 0 and gCacheFor == itemsText:
    return gCache
  let merged = mergeInto(itemsText)
  gCacheFor = itemsText
  gCache = merged
  result = merged

proc selfCheckItemsGaps*(into: var seq[string]): bool =
  ## Negative assertions about the FINISHED document (CLAUDE.md 9b). Each names
  ## an input that makes it fail; none of them re-reads this module's own write
  ## by comparing it to what it wrote.
  result = true

  let table = post1Table("itemsgaps")
  if table.len == 0:
    into.add "items gaps: data/post1/itemsgaps.json is not installed"
    return false
  let gaps = parseObject(table)
  if not gaps.ok or gaps.fields.len == 0:
    into.add "items gaps: itemsgaps.json did not parse as a non-empty " &
             "JSON object"
    return false

  # Every per-item entry must itself be a valid, non-empty JSON OBJECT when
  # read back through the reader, not merely non-empty text. Fact #122: a
  # payload that "contains" the right substring can still be invalid JSON.
  var bad = 0
  for g in gaps.fields:
    let v = whole(g.value)
    if not v.exists or not v.isObject:
      inc bad
  if bad > 0:
    into.add $bad & " entr(ies) of itemsgaps.json are not valid JSON objects"
    result = false

  # NEGATIVE, end to end, on a MINIATURE document built from the real table's
  # first entry: after the merge, no member of that entry is absent from the
  # finished item's `_props`. A stub that returned its input unchanged fails
  # this, and so does one that merged at the wrong depth.
  block:
    let id = gaps.fields[0].name
    let src = "{\"" & id & "\":{\"_id\":\"" & id &
              "\",\"_type\":\"Item\",\"_props\":{\"Kept\":1}},\"zzz\":{}}"
    let saveCacheFor = gCacheFor
    let saveCache = gCache
    gCacheFor = ""
    let outText = applyItemsGaps(src)
    gCacheFor = saveCacheFor
    gCache = saveCache
    let props = field(outText, id).child("_props")
    if not props.exists or not props.isObject:
      into.add "items gaps: the merged document has no object `_props` for " &
               "the item it was supposed to fill"
      return false
    var absent = 0
    let add = parseObject(gaps.fields[0].value)
    for m in add.fields:
      if not props.child(m.name).exists:
        inc absent
    if absent > 0:
      into.add $absent & " gap member(s) are still absent from `_props` " &
               "after the merge"
      result = false
    # The database's own members must survive it. A merge that rebuilt
    # `_props` from the gap table alone would pass the check above.
    if not props.child("Kept").exists:
      into.add "items gaps: the merge dropped a `_props` member the " &
               "database had"
      result = false
    # And so must the item's siblings, and its own non-`_props` members.
    if not field(outText, id).child("_id").exists:
      into.add "items gaps: the merge dropped `_id` from the item"
      result = false
    if not field(outText, "zzz").exists:
      into.add "items gaps: the merge dropped a sibling item"
      result = false

  # Never overwrite: a database that already holds a gap member must keep its
  # own value.
  block:
    let id = gaps.fields[0].name
    let add = parseObject(gaps.fields[0].value)
    if add.ok and add.fields.len > 0:
      let first = add.fields[0].name
      let src = "{\"" & id & "\":{\"_props\":{\"" & first & "\":\"MINE\"}}}"
      let saveCacheFor = gCacheFor
      let saveCache = gCache
      gCacheFor = ""
      let outText = applyItemsGaps(src)
      gCacheFor = saveCacheFor
      gCache = saveCache
      if field(outText, id).child("_props").child(first).asText("") != "MINE":
        into.add "items gaps: the merge OVERWROTE `_props." & first &
                 "`, which the database already had"
        result = false

  # An id BSG had and this database does not must NOT be conjured into
  # existence. Absent-and-skipped is the contract; absent-and-invented would
  # ship a template with a `_props` and no `_id`.
  block:
    let src = """{"zzz":{"_props":{}}}"""
    let saveCacheFor = gCacheFor
    let saveCache = gCache
    gCacheFor = ""
    let outText = applyItemsGaps(src)
    gCacheFor = saveCacheFor
    gCache = saveCache
    if field(outText, gaps.fields[0].name).exists:
      into.add "items gaps: the merge INVENTED an item id the database " &
               "does not have"
      result = false
