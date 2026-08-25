## Spawning items into a stash from the settings page.
##
## The headline of the singleplayer surface: type part of an item's name, say
## how many and in what condition, and have them appear in the stash.
##
## Why it is not a "setting"
## -------------------------
## Spawning is an ACTION, and the settings wire format only carries values --
## `{"key":..., "value":...}` in, a schema array back. Rather than invent a new
## control type that the settings UI would have to grow support for before any
## of this worked, a spawn is expressed as four ordinary rows that already
## render everywhere:
##
##   spawnQuery     string   part of a name, or a bare 24-hex template id
##   spawnCount     int      how many
##   spawnCondition int      durability/resource as a percentage
##   spawnNow       bool     flipping this to true PERFORMS the spawn
##
## `spawnNow` is a momentary control: the POST that sets it true is intercepted
## here, the spawn runs, and the key is written straight back to `false` so the
## row is armed again and the page never shows a checkbox stuck on. The result
## -- what was spawned, or precisely why nothing was -- goes into `spawnResult`,
## a read-only string row the page renders under the button.
##
## This is the "new control type" the settings UI could offer instead: a
## search-select box plus an action button. Until it does, the four rows above
## work with the schema shape that already ships.
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

proc searchItems*(query: string; limit: int): seq[ItemHit] =
  ## Items whose English name contains `query`, case-insensitively.
  ##
  ## `limit` bounds the answer AND the work: the scan stops at the limit rather
  ## than collecting every match and slicing, because "find me everything called
  ## bolt" over 40,000 members is a large seq built to be thrown away.
  result = @[]
  if query.len == 0:
    return
  if isTemplateId(query):
    let low = toLowerAscii(query)
    if itemExists(low):
      result.add ItemHit(tpl: low, name: localeNameOf(low))
    return
  let doc = dbRead("locales.global.en")
  if not doc.ok or doc.raw.len == 0:
    return
  let hay = doc.raw
  let want = toLowerAscii(query)
  const Marker = " Name\":\""
  var at = hay.find(Marker, 0)
  while at >= 0 and result.len < limit:
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
          result.add ItemHit(tpl: tpl, name: unescapeName(value))
    at = hay.find(Marker, at + Marker.len)

proc searchSummary*(query: string; limit: int): string =
  ## The hits as one line, for the read-only result row.
  let hits = searchItems(query, limit)
  if hits.len == 0:
    return "no item matches \"" & query & "\""
  result = ""
  for h in hits:
    if result.len > 0: result.add "; "
    result.add h.name & " (" & h.tpl & ")"

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

  let hits = searchItems(query, 8)
  if hits.len == 0:
    result.message = "no item matches \"" & query & "\""
    return
  if hits.len > 1 and not isTemplateId(query):
    # Refused rather than "the first one", because the first one is an
    # arbitrary document order and spawning the wrong item is a stash to clean
    # up by hand. The candidates are named so the query can be narrowed.
    var names = ""
    for h in hits:
      if names.len > 0: names.add "; "
      names.add h.name & " (" & h.tpl & ")"
    result.message = "\"" & query & "\" matches " & $hits.len &
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
