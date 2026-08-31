## Spawning items into a stash from the settings page.
##
## The headline of the singleplayer surface: type part of an item's name, say
## how many and in what condition, and have them appear in the stash.
##
## Why it is not a "setting"
## -------------------------
## Spawning is an ACTION, and the settings wire format carries values --
## `{"key":..., "value":...}` in, a schema array back. So a spawn is expressed
## as five ordinary rows, and the action is a boolean that unsets itself:
##
##   spawnQuery     select   the template id, chosen by typeahead against
##                           `/aowlspt/settings/<guid>/items` (`optionsUrl`)
##   spawnCount     int      how many
##   spawnCondition int      durability/resource as a percentage
##   spawnNow       bool     flipping this to true PERFORMS the spawn
##   spawnResult    string   what happened, or exactly why nothing did
##
## `spawnNow` is a momentary control: the POST that sets it true is intercepted
## in `tarkov.nim`, the spawn runs, and the key is written straight back to
## `false` so the row is armed again and the page never shows a checkbox stuck
## on.
##
## 4,673 item templates is far too many to inline in a schema, which is what
## the UI's `optionsUrl` contract exists for -- `onSpawnItemOptions` in
## `tarkov.nim` is this module's `searchItemsCounted` behind that route.
##
## Searching
## ---------
## By id when the query looks like one, because that is exact and free. By name
## otherwise, which means scanning the English locale -- 2.7 MB in one object of
## `id Name` -> text members. It is scanned in ONE linear pass looking for the
## `" Name":"` member suffix, never parsed into a map: `keys()` over that
## document is a seq of ~40,000 strings for a question that wants at most ten
## answers.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import ids
import templates
import inventory
import grid
import profile
import trading

type
  ItemHit* = object
    tpl*: string
    name*: string

  SpawnOutcome* = object
    ok*: bool
    message*: string   ## always populated, on success and on refusal alike

proc isTemplateId*(s: string): bool =
  ## A 24-character lowercase hex string is a template id and nothing else.
  ## Checked rather than assumed so a search for "0" does not try to spawn it.
  if s.len != 24:
    return false
  for i in 0 ..< s.len:
    let c = s[i]
    if not ((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or
            (c >= 'A' and c <= 'F')):
      return false
  result = true

proc unescapeName(s: string): string =
  ## Enough JSON string unescaping to render a name. Names in the locale carry
  ## `\"` and the odd `\\`; a full decoder is not needed to display one.
  result = ""
  var i = 0
  while i < s.len:
    if s[i] == '\\' and i + 1 < s.len:
      let c = s[i + 1]
      if c == 'n': result.add ' '
      elif c == 't': result.add ' '
      elif c == 'u': i = i + 4          # skip the code point, keep going
      else: result.add c
      i = i + 2
    else:
      result.add s[i]
      inc i

proc localeNameOf*(tpl: string): string =
  ## One item's display name, straight out of the locale by path. A miss is an
  ## empty string, not the id: a caller that wants the id already has it.
  let v = dbRead("locales.global.en." & tpl & " Name")
  if v.ok:
    return unescapeName(asText(v))
  result = ""

proc searchItemsCounted*(query: string; limit: int;
                         matched: var int): seq[ItemHit] =
  ## Items whose English name contains `query`, case-insensitively.
  ##
  ## `limit` bounds what comes BACK; `matched` reports how many there really
  ## were. Those are two different numbers and collapsing them is how a
  ## truncated list gets presented as a complete one -- "no such item" when the
  ## item was the fifty-first match. The scan still visits the whole document
  ## when it has to, because counting is the question being asked.
  result = @[]
  matched = 0
  if query.len == 0:
    return
  if isTemplateId(query):
    let low = toLowerAscii(query)
    if itemExists(low):
      matched = 1
      result.add ItemHit(tpl: low, name: localeNameOf(low))
    return
  let doc = dbRead("locales.global.en")
  if not doc.ok or doc.raw.len == 0:
    return
  let hay = doc.raw
  let want = toLowerAscii(query)
  const Marker = " Name\":\""
  var at = hay.find(Marker, 0)
  while at >= 0:
    # The key runs from the quote before the id back to `"`; the id is the 24
    # characters immediately before ` Name`.
    let idEnd = at
    let idStart = idEnd - 24
    var valueStart = at + Marker.len
    var i = valueStart
    var value = ""
    while i < hay.len:
      if hay[i] == '\\':
        i = i + 2
        continue
      if hay[i] == '"':
        break
      inc i
    if i <= hay.len and idStart > 0 and hay[idStart - 1] == '"':
      value = hay.substr(valueStart, i - 1)
      let tpl = hay.substr(idStart, idEnd - 1)
      if isTemplateId(tpl) and toLowerAscii(value).find(want, 0) >= 0:
        # The locale carries names for things that are not items -- quests,
        # traders, areas. `itemExists` is what makes this an ITEM search.
        if itemExists(tpl):
          matched = matched + 1
          if result.len < limit:
            result.add ItemHit(tpl: tpl, name: unescapeName(value))
    at = hay.find(Marker, at + Marker.len)

proc searchItems*(query: string; limit: int): seq[ItemHit] =
  ## `searchItemsCounted` for a caller that does not care how many were cut off.
  var matched = 0
  result = searchItemsCounted(query, limit, matched)

proc searchSummary*(query: string; limit: int): string =
  ## The hits as one line, for the read-only result row.
  var matched = 0
  let hits = searchItemsCounted(query, limit, matched)
  if hits.len == 0:
    return "no item matches \"" & query & "\""
  result = ""
  for h in hits:
    if result.len > 0: result.add "; "
    result.add h.name & " (" & h.tpl & ")"
  if matched > hits.len:
    result = $hits.len & " of " & $matched & " matches: " & result

proc applyCondition(d: var Doc; tpl: string; percent: int) =
  ## Durability / resource, as a percentage of the template's own maximum.
  ##
  ## Read from the TEMPLATE rather than assumed, and written only for the
  ## properties the template actually declares: writing `Repairable` onto a
  ## medkit produces an item the client has no component for, and an item the
  ## client cannot construct is one that never appears -- which looks exactly
  ## like the spawn having failed.
  if percent >= 100 or percent <= 0:
    return
  let scale = float(percent) / 100.0
  var upd = parseObject(getRaw(d, "upd"))
  if not upd.ok:
    upd = newDoc()
  let maxDur = itemProp(tpl, "MaxDurability")
  if maxDur.ok:
    let m = maxDur.asFloat(0.0)
    if m > 0.0:
      var rep = newDoc()
      setNumber(rep, "Durability", m * scale)
      setNumber(rep, "MaxDurability", m)
      setRaw(upd, "Repairable", text(rep))
  let maxRes = itemProp(tpl, "MaxResource")
  if maxRes.ok:
    let m = maxRes.asFloat(0.0)
    if m > 0.0:
      var res = newDoc()
      setNumber(res, "Value", m * scale)
      setRaw(upd, "Resource", text(res))
  let maxHp = itemProp(tpl, "MaxHpResource")
  if maxHp.ok:
    let m = maxHp.asFloat(0.0)
    if m > 0.0:
      var med = newDoc()
      setNumber(med, "HpResource", m * scale)
      setRaw(upd, "MedKit", text(med))
  let maxFood = itemProp(tpl, "MaxResource")
  discard maxFood
  setRaw(d, "upd", text(upd))

proc spawnInto*(profileId, query: string; count, condition: int): SpawnOutcome =
  ## Put `count` of the item `query` names into that profile's stash.
  ##
  ## Every refusal carries its own reason. A spawn that quietly does nothing is
  ## the exact failure this project keeps paying for, and there are five
  ## distinct ways for this to decline -- no profile, no match, an ambiguous
  ## match, no room, and a save that lost a race -- which a bare `false` would
  ## flatten into one.
  result = SpawnOutcome(ok: false, message: "")
  if query.len == 0:
    result.message = "type part of an item name, or a template id, first"
    return
  if profileId.len == 0:
    result.message = "no profile is logged in; log in before spawning"
    return
  var n = count
  if n < 1: n = 1
  if n > 5000:
    result.message = "refusing to spawn " & $count &
                     " items; 5000 is the cap"
    return

  var matched = 0
  let hits = searchItemsCounted(query, 8, matched)
  if hits.len == 0:
    result.message = "no item matches \"" & query & "\""
    return
  if matched > 1 and not isTemplateId(query):
    # Refused rather than "the first one", because the first one is an
    # arbitrary document order and spawning the wrong item is a stash to clean
    # up by hand. The candidates are named so the query can be narrowed.
    var names = ""
    for h in hits:
      if names.len > 0: names.add "; "
      names.add h.name & " (" & h.tpl & ")"
    result.message = "\"" & query & "\" matches " & $matched &
                     " items -- narrow it or paste an id: " & names
    return
  let tpl = hits[0].tpl
  let label = (if hits[0].name.len > 0: hits[0].name else: tpl)

  var p = loadProfile(profileId)
  if not p.ok:
    result.message = "could not read profile " & profileId
    return
  let asRead = profileVersion(profileId)
  let stash = stashId(p)
  if stash.len == 0:
    result.message = "profile " & profileId & " has no stash"
    return

  var inv = openInventory(p.field("Inventory.items").raw)
  var ch = newChange()
  if not giveItem(inv, tpl, stash, n, ch):
    var why = "the stash has no room for " & $n & " x " & label
    if ch.problems.len > 0:
      why = ch.problems[0]
    result.message = why
    return

  # Condition is applied to the items this spawn CREATED, by id, after they are
  # placed -- `giveItem` owns placement and stacking and must not be reimplemented
  # here to sneak an `upd` in.
  if condition > 0 and condition < 100:
    for k in 0 ..< ch.created.len:
      let id = field(ch.created.items[k], "_id").asText("")
      if id.len == 0:
        continue
      let at = indexOf(inv, id)
      if at < 0:
        continue
      var d = itemAt(inv, at)
      applyCondition(d, tpl, condition)
      inv.items.replaceAt(at, text(d))
      inv.dirty = true

  if not inv.dirty:
    result.message = "nothing was placed"
    return
  setRaw(p, "Inventory.items", text(inv.items))
  if not saveIfUnchanged(p, asRead):
    result.message = "the profile changed while spawning; nothing was saved"
    return
  result.ok = true
  result.message = "spawned " & $n & " x " & label & " (" & tpl &
                   ") into the stash"

# ---------------------------------------------------------------------------
# READING A PROFILE BACK -- what the native inventory screen renders, and what
# makes a mint VERIFIABLE rather than merely acknowledged.
# ---------------------------------------------------------------------------
#
# `spawnInto` above returns a sentence. A sentence is not a readback: it says
# what the code believed it did. The two procs here answer the only questions
# that settle it from the FINISHED STATE of the profile on disk --
#
#   `stashRows`      what is actually in the stash right now
#   `templateCount`  how many of one template the profile holds, RIGHT NOW
#
# -- and `templateCount` reports READABILITY separately from the number, because
# "the profile holds zero" and "I could not open the profile" are different
# answers and a caller that collapses them turns "I could not look" into a FAIL.

type
  InvRow* = object
    tpl*: string
    name*: string
    count*: int      ## stack size, or 1 for a non-stacking item

  CountResult* = object
    readable*: bool  ## the profile opened and its item list parsed
    count*: int      ## total units of the template, 0 when unreadable
    why*: string     ## populated only when `readable` is false

proc stackOf(itemRaw: string): int =
  ## `upd.StackObjectsCount`, defaulting to 1. An item with no `upd` is one
  ## item, not zero -- reading a missing stack count as zero would make a rack
  ## of loose items vanish from the screen that is meant to show them.
  let upd = field(itemRaw, "upd")
  if not exists(upd):
    return 1
  let n = field(upd.raw, "StackObjectsCount").asInt(1)
  if n < 1: 1 else: n

proc templateCount*(profileId, tpl: string): CountResult =
  ## Units of `tpl` anywhere in the profile's item list.
  ##
  ## THE MINT READBACK. Deliberately counted over the WHOLE list rather than
  ## just the stash root: `giveItem` decides placement, and a check that only
  ## looked where it expected the item to land would report FAIL for an item
  ## that was correctly placed somewhere else. The question being asked is "did
  ## the profile gain these units", and the whole list is what answers it.
  ##
  ## One linear pass, bounded by the list length. No `descendantsOf`, whose
  ## `seen` scan is quadratic and which answers a different question.
  result = CountResult(readable: false, count: 0, why: "")
  if profileId.len == 0 or tpl.len == 0:
    result.why = "no profile id or no template id to count"
    return
  let p = loadProfile(profileId)
  if not p.ok:
    result.why = "could not read profile " & profileId
    return
  let itemsRaw = p.field("Inventory.items")
  if not exists(itemsRaw):
    result.why = "profile " & profileId & " has no Inventory.items to count"
    return
  let inv = openInventory(itemsRaw.raw)
  let want = toLowerAscii(tpl)
  var total = 0
  for i in 0 ..< inv.items.len:
    let raw = inv.items.items[i]
    if toLowerAscii(field(raw, "_tpl").asText("")) == want:
      total = total + stackOf(raw)
  result.readable = true
  result.count = total

proc stashRows*(profileId: string; limit: int; total: var int): seq[InvRow] =
  ## The TOP LEVEL of the stash, one row per distinct template, with the units
  ## of each summed.
  ##
  ## Direct children of the stash root only -- `childrenOf`, not
  ## `descendantsOf`. That is what an inventory screen shows: the things lying
  ## in the grid, not every screw inside every rig. Descending would list a
  ## magazine's rounds as top-level stash contents, which is not what is in the
  ## stash.
  ##
  ## `limit` bounds what comes BACK; `total` reports how many distinct templates
  ## there really are. Two numbers, for the same reason `searchItemsCounted`
  ## returns two: a truncated list presented as a complete one is how "you have
  ## no bandages" gets said about a stash with bandages in row 40.
  result = @[]
  total = 0
  if profileId.len == 0:
    return
  let p = loadProfile(profileId)
  if not p.ok:
    return
  let itemsRaw = p.field("Inventory.items")
  if not exists(itemsRaw):
    return
  let inv = openInventory(itemsRaw.raw)
  let stash = stashId(p)
  if stash.len == 0:
    return

  # Two parallel seqs rather than a table: this module has no hash map and the
  # row count is bounded by the stash's top level, so a linear "have I seen this
  # template" scan is bounded by (rows seen)^2 with rows in the low hundreds.
  var tpls: seq[string] = @[]
  var qtys: seq[int] = @[]
  for i in 0 ..< inv.items.len:               # bounded: the item list length
    let raw = inv.items.items[i]
    if field(raw, "parentId").asText("") != stash:
      continue
    let tpl = field(raw, "_tpl").asText("")
    if tpl.len == 0:
      continue
    let n = stackOf(raw)
    var at = -1
    for k in 0 ..< tpls.len:
      if tpls[k] == tpl:
        at = k
        break
    if at >= 0:
      qtys[at] = qtys[at] + n
    else:
      tpls.add tpl
      qtys.add n
  total = tpls.len
  var emitted = 0
  for k in 0 ..< tpls.len:
    if emitted >= limit:
      break
    let nm = localeNameOf(tpls[k])
    result.add InvRow(tpl: tpls[k],
                      name: (if nm.len > 0: nm else: tpls[k]),
                      count: qtys[k])
    emitted = emitted + 1

proc selfCheckSpawn*(into: var seq[string]): bool =
  ## What this module can prove with no database and no profile.
  result = true
  if not isTemplateId("5449016a4bdc2d6f028b456f"):
    into.add "spawn: a real 24-hex template id was not recognised as one"
    result = false
  if isTemplateId("bandage"):
    into.add "spawn: a plain word was mistaken for a template id"
    result = false
  if isTemplateId("5449016a4bdc2d6f028b456"):
    into.add "spawn: a 23-character id was accepted"
    result = false
  # A refusal must carry a reason. An empty message is the silent decline.
  let noProfile = spawnInto("", "bandage", 1, 100)
  if noProfile.ok or noProfile.message.len == 0:
    into.add "spawn: a spawn with no profile did not refuse with a reason"
    result = false
  let noQuery = spawnInto("x", "", 1, 100)
  if noQuery.ok or noQuery.message.len == 0:
    into.add "spawn: an empty query did not refuse with a reason"
    result = false
  let tooMany = spawnInto("x", "bandage", 99999, 100)
  if tooMany.ok or tooMany.message.find("5000") < 0:
    into.add "spawn: the count cap did not refuse, or did not say the cap"
    result = false
