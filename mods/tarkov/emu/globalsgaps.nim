## The members of `globals.config` that REAL BSG sends and our database does not.
##
## Why this exists
## ---------------
## `db.json` is a pre-1.0 SPT dump. A post-1.0 BSG session was captured
## (`data/capture/raid1`, seq **084** `GET /client/globals`, 179 KB decoded,
## `resp_xenc: aes`) and its `data.config` holds **119** members; the database
## holds **107**, and every one of the 107 is also in BSG's 119. So the gap is
## exactly the 12 members BSG sends and we do not:
##
##   BattlePassUniversalDocument  ExtensionsSettings  FinalConsequenceSettings
##   FinalMissionSettings  GroupQuestSetting  KolotunSettings
##   MatchMakerEstimateSettings  MaxMatchingTimeInSeconds  PasscodeSettings
##   SteamStatusSettings  Tutorial  WishlistSettings
##
## Ten of those are DECLARED by `EFT.GlobalConfiguration` (measured with
## `tools/dtogap.py /client/globals`); nine of the ten are REFERENCE types, so
## absent from the JSON they stay **null** and any dereference is a crash or a
## hang. The remaining two -- `FinalConsequenceSettings`,
## `MatchMakerEstimateSettings` -- are sent by BSG but not declared by the
## client on this build; they are carried anyway, because matching BSG exactly
## is a smaller guess than deciding which of BSG's own members the client does
## not want.
##
## What is NOT claimed
## -------------------
## That any of these is dereferenced. `dtogap` reads a field's TYPE, not its
## use, and no consumer was disassembled. The claim here is narrower and
## checkable: **the document the client receives no longer differs from the
## captured BSG document in its top-level `config` member set.** The client
## reaches the menu today without them, so none of these is boot-fatal.
##
## What this deliberately does not do
## ----------------------------------
## Overwrite. A member the database already has always wins, so re-importing a
## newer `db.json` silently retires this table member by member instead of
## being shadowed by a stale capture. And it does not invent the 24 fields
## `EFT.GlobalConfiguration` declares that **BSG itself never sent** -- shaping
## an empty object for those would diverge from the real server rather than
## converge on it.

import aowlspt
import aowlspt/server
import aowlspt/json
import post1

var gApplied = false
var gAddedNames: seq[string] = @[]
var gCache = ""
var gCacheFor = ""

## The members this module actually added, after the last apply. Empty before
## the first `/client/globals`, and empty afterwards ONLY if the database
## already had all twelve.
proc globalsGapNames*(): seq[string] = gAddedNames

proc globalsGapsApplied*(): bool = gApplied

proc mergeInto(globalsText: string): string =
  let table = post1Table("globalsgaps")
  if table.len == 0:
    # `post1Table` has already warned. Serving the database document unchanged
    # is what happened before this module existed, so this degrades to the
    # previous behaviour rather than to a broken document.
    return globalsText
  var gaps = parseObject(table)
  if not gaps.ok:
    warn "globals: data/post1/globalsgaps.json is not a JSON object; " &
         "the BSG-only config members will NOT be served"
    return globalsText
  var doc = parseObject(globalsText)
  if not doc.ok or not doc.has("config"):
    warn "globals: the database document has no `config` member; " &
         "the BSG-only config members will NOT be served"
    return globalsText
  var cfg = parseObject(getRaw(doc, "config"))
  if not cfg.ok:
    warn "globals: `config` is not a JSON object; the BSG-only config " &
         "members will NOT be served"
    return globalsText
  gAddedNames = @[]
  for m in gaps.fields:
    if cfg.has(m.name):
      continue
    setRaw(cfg, m.name, m.value)
    gAddedNames.add m.name
  if gAddedNames.len == 0:
    gApplied = true
    return globalsText
  setRaw(doc, "config", text(cfg))
  gApplied = true
  result = text(doc)

proc applyGlobalsGaps*(globalsText: string): string =
  ## The globals document with BSG's own missing `config` members spliced in.
  ##
  ## Cached against the input text: the document is ~700 KB and is reparsed
  ## once, not once per request. `/client/globals` is answered on every menu
  ## load (and 304'd thereafter), so "once per request" would be a reparse of
  ## 700 KB in the middle of a menu transition.
  if gCacheFor.len > 0 and gCacheFor == globalsText:
    return gCache
  let merged = mergeInto(globalsText)
  gCacheFor = globalsText
  gCache = merged
  result = merged

proc selfCheckGlobalsGaps*(into: var seq[string]): bool =
  ## Negative assertions about the FINISHED document (CLAUDE.md 9b). Each names
  ## an input that makes it fail; none of them re-reads this module's own write
  ## by comparing it to what it wrote.
  result = true

  let table = post1Table("globalsgaps")
  if table.len == 0:
    into.add "globals gaps: data/post1/globalsgaps.json is not installed"
    return false
  let gaps = parseObject(table)
  if not gaps.ok or gaps.fields.len == 0:
    into.add "globals gaps: globalsgaps.json did not parse as a non-empty " &
             "JSON object"
    return false

  # Every member must itself be valid JSON when read back through the reader,
  # not merely non-empty text. Fact #122: a payload that "contains" the right
  # substring can still be invalid JSON.
  var bad = 0
  for m in gaps.fields:
    let v = whole(m.value)
    if not v.exists:
      inc bad
  if bad > 0:
    into.add $bad & " member(s) of globalsgaps.json are not valid JSON values"
    result = false

  # NEGATIVE, end to end: after the merge, no member of the gap table is
  # absent from the finished document's `config`. A stub that returned its
  # input unchanged fails this.
  block:
    let src = """{"config":{"Kept":1},"other":[1,2,3]}"""
    let saveCacheFor = gCacheFor
    let saveCache = gCache
    let saveNames = gAddedNames
    gCacheFor = ""
    let outText = applyGlobalsGaps(src)
    gCacheFor = saveCacheFor
    gCache = saveCache
    gAddedNames = saveNames
    let cfg = field(outText, "config")
    if not cfg.exists or not cfg.isObject:
      into.add "globals gaps: the merged document has no object `config`"
      return false
    var absent = 0
    for m in gaps.fields:
      if not cfg.child(m.name).exists:
        inc absent
    if absent > 0:
      into.add $absent & " gap member(s) are still absent from `config` " &
               "after the merge"
      result = false
    # And the database's own members must survive it. A merge that rebuilt
    # `config` from the gap table alone would pass the check above.
    if not cfg.child("Kept").exists:
      into.add "globals gaps: the merge dropped a member the database had"
      result = false
    if not field(outText, "other").exists:
      into.add "globals gaps: the merge dropped a sibling of `config`"
      result = false

  # Never overwrite: a database that already holds a gap member must keep its
  # own value.
  block:
    let first = gaps.fields[0].name
    let src = "{\"config\":{\"" & first & "\":\"MINE\"}}"
    let saveCacheFor = gCacheFor
    let saveCache = gCache
    let saveNames = gAddedNames
    gCacheFor = ""
    let outText = applyGlobalsGaps(src)
    gCacheFor = saveCacheFor
    gCache = saveCache
    gAddedNames = saveNames
    if field(outText, "config").child(first).asText("") != "MINE":
      into.add "globals gaps: the merge OVERWROTE `" & first &
               "`, which the database already had"
      result = false
