## Planting -- the generic round-trip that lets ANOTHER server mod put real
## loose loot and real bot groups into a raid this emulator is serving.
##
## ## Why a round-trip and not a call
##
## `emit` returns no payload (`aowl/src/aowlspt.nim`), so a mod cannot ASK
## another mod for anything. What it CAN do is rely on delivery being
## **synchronous and in subscription order, to every subscriber but the
## emitter**. So the shape is:
##
##   1. this module emits `tarkov.loot.compose {map, raidId}`
##   2. a planter's handler, running inside that emit, emits
##      `tarkov.loot.plant {raidId, items:[...]}`
##   3. this module's OWN `tarkov.loot.plant` subscriber appends to a pending
##      list
##   4. `emit(compose)` returns and this module reads the list
##
## The same shape for bots (`tarkov.bots.compose` / `tarkov.bots.plant`), and a
## one-way `tarkov.loot.taken` at raid end.
##
## ## What this module deliberately does NOT do
##
## * **It does not invent an item.** A `tpl` that is not in `templates.items`
##   is REFUSED with a warning naming it, and never reaches the client. A
##   template the client cannot resolve is a raid that does not load, and a
##   silent drop would make that look like the planter never answered.
## * **It does not put `groupId`/`factionId` on the served bot profile.**
##   Measured: `Info` on this build's bot base (see `emu/bots.ChkBase` and the
##   `botBase()` document) carries no `GroupId` member, and inventing one on a
##   profile the client deserialises is a change with an unbounded failure
##   mode. Both ids are carried in the LOG line instead, and this paragraph is
##   the "say so" the contract asks for.
## * **It prints nothing when nobody answered.** No planter subscribed is the
##   normal case, and a census of zeros every raid is noise that hides the one
##   raid where the number is wrong.

import aowlspt
import aowlspt/server
import aowlspt/json

const
  EvLootCompose* = "tarkov.loot.compose"
  EvLootPlant* = "tarkov.loot.plant"
  EvBotsCompose* = "tarkov.bots.compose"
  EvBotsPlant* = "tarkov.bots.plant"
  EvLootTaken* = "tarkov.loot.taken"

var
  gInstalled = false
  gMap = ""
  gRaidId = ""
  gComposing = ""
    ## The raid a compose is currently open for. A `*.plant` naming any other
    ## raid is ignored with a note -- never applied "close enough", because the
    ## planter and this server can disagree about which raid is running and the
    ## visible symptom would be loot from the LAST raid.
  gLootIn: seq[string] = @[]      ## raw `items[]` elements, as received
  gGroupsIn: seq[string] = @[]    ## raw `groups[]` elements, as received
  gAnswered = false               ## did any planter answer for THIS raid
  gPlanted: seq[string] = @[]     ## ids actually SERVED this raid
  gRefused = 0
  gGroups = 0
  gLastCensus = ""

proc resetRaid(map, raidId: string) =
  if raidId == gRaidId and map == gMap:
    return
  gMap = map
  gRaidId = raidId
  gAnswered = false
  gPlanted = @[]
  gRefused = 0
  gGroups = 0
  gLastCensus = ""

proc setRaidContext*(map, raidId: string) =
  ## What the bot compose uses, because `bot/generate` names neither the map
  ## nor the raid.
  resetRaid(map, raidId)

proc currentRaidId*(): string = gRaidId
proc currentMap*(): string = gMap

# ---------------------------------------------------------------------------
# The two `*.plant` subscribers
# ---------------------------------------------------------------------------

proc deliverLootPlant*(payload: string): string =
  result = ""
  let rid = field(payload, "raidId").asText("")
  if gComposing.len == 0:
    info "planting: a " & EvLootPlant & " arrived while no loot compose was " &
         "open -- ignored. The round-trip is synchronous: plant from inside " &
         "the " & EvLootCompose & " handler."
    return
  if rid != gComposing:
    info "planting: a " & EvLootPlant & " named raid '" & rid &
         "' while composing '" & gComposing & "' -- ignored"
    return
  let items = each(field(payload, "items"))
  for it in items:
    gLootIn.add raw(it)
  gAnswered = true

proc deliverBotsPlant*(payload: string): string =
  result = ""
  let rid = field(payload, "raidId").asText("")
  if gComposing.len == 0:
    info "planting: a " & EvBotsPlant & " arrived while no bot compose was " &
         "open -- ignored"
    return
  if rid != gComposing:
    info "planting: a " & EvBotsPlant & " named raid '" & rid &
         "' while composing '" & gComposing & "' -- ignored"
    return
  let groups = each(field(payload, "groups"))
  for g in groups:
    gGroupsIn.add raw(g)
  gAnswered = true

proc installPlanting*(): bool =
  ## Idempotent. Returns whether both subscriptions are in place -- a `false`
  ## here means every plant afterwards would be silently dropped, so the caller
  ## must say so rather than carry on.
  if gInstalled:
    return true
  if onEvent(EvLootPlant, deliverLootPlant) != Ok:
    return false
  if onEvent(EvBotsPlant, deliverBotsPlant) != Ok:
    return false
  gInstalled = true
  result = true

proc plantingInstalled*(): bool = gInstalled

# ---------------------------------------------------------------------------
# The local-planter seam, and the ONE thing it cannot prove
# ---------------------------------------------------------------------------
#
# MEASURED 2026-09-06, `host/Aowlspt.Sim/aowlsim.nim:540` --
# `deliverEvent` skips `gSubs[i].modIndex == fromIndex`, i.e. an emit is
# delivered to every subscriber **except those belonging to the emitting mod**.
# The backend and the client host take the same reference. So a planter that
# lives inside `aowl.tarkov` -- which is exactly what a self-check planter is
# -- can NEVER hear this module's own compose, and the round-trip is
# untestable from inside the mod through the bus.
#
# This seam is how the self-check reaches the rest of the machine anyway: it
# registers a planter that `compose` calls DIRECTLY, immediately after the
# broadcast, with the identical payload. Everything downstream of that point --
# the raid-id gate, the template refusal, the entry shape, the append, the
# census, the bot batch -- is the same code on both paths.
#
# **What it therefore does NOT prove, and nothing in this repo can prove
# offline: that the HOST delivers `tarkov.loot.plant` from another mod back
# into this one inside the compose.** That is one line of host behaviour, it is
# quoted above from the host's own source, and it is INCONCLUSIVE here rather
# than passed. A live two-mod run is the only thing that settles it.

type
  LocalPlanter* = proc (payload: string): string

proc noPlanter(payload: string): string = ""

var
  gLocalLoot: LocalPlanter = noPlanter
  gLocalBots: LocalPlanter = noPlanter
  gLocalOn = false

proc setLocalPlanters*(lootPlanter, botsPlanter: LocalPlanter) =
  ## For the self-check ONLY. Nothing on a serving path calls this.
  gLocalLoot = lootPlanter
  gLocalBots = botsPlanter
  gLocalOn = true

proc clearLocalPlanters*() =
  gLocalLoot = noPlanter
  gLocalBots = noPlanter
  gLocalOn = false

# ---------------------------------------------------------------------------
# The census
# ---------------------------------------------------------------------------

proc census() =
  ## One line per raid, and ONLY when a planter answered. Reprinted only when
  ## the numbers have moved (the bots compose lands after the loot one), so a
  ## raid that was only given loot gets exactly one line.
  if not gAnswered:
    return
  let line = "planting: loot " & $gPlanted.len & " item(s) (" & $gRefused &
             " refused), bots " & $gGroups & " group(s)"
  if line == gLastCensus:
    return
  gLastCensus = line
  info line

# ---------------------------------------------------------------------------
# Loose loot
# ---------------------------------------------------------------------------

proc tplKnown(dbText, tpl: string): bool =
  ## `templates.items.<tpl>` in the live database, or in a document standing in
  ## for it (which is what `emu/loot`'s fixture path hands down).
  if tpl.len == 0:
    return false
  if dbText.len == 0:
    return dbRead("templates.items." & tpl).ok
  result = field(dbText, "templates.items." & tpl).found

proc lootEntryFor(it: JsonRef): string =
  ## One element of the served `Loot` array, in the shape `emu/loot.lootEntry`
  ## produces for a LOOSE item: the level's transform, then `Root` and `Items`.
  let id = it.field("id").asText("")
  let tpl = it.field("tpl").asText("")
  var item = newDoc()
  setText(item, "_id", id)
  setText(item, "_tpl", tpl)
  let n = it.field("count").asInt(1)
  if n > 1:
    var upd = newDoc()
    setNumber(upd, "StackObjectsCount", n)
    setRaw(item, "upd", text(upd))
  var items = newList()
  items.add text(item)

  var pos = newDoc()
  setNumber(pos, "x", it.field("x").asFloat(0.0))
  setNumber(pos, "y", it.field("y").asFloat(0.0))
  setNumber(pos, "z", it.field("z").asFloat(0.0))
  var rot = newDoc()
  setNumber(rot, "x", 0.0)
  setNumber(rot, "y", 0.0)
  setNumber(rot, "z", 0.0)

  var e = newDoc()
  setText(e, "Id", "planted_" & id)
  setBool(e, "IsStatic", false)
  setBool(e, "useGravity", false)
  setBool(e, "randomRotation", false)
  setRaw(e, "Position", text(pos))
  setRaw(e, "Rotation", text(rot))
  setBool(e, "IsGroupPosition", false)
  setRaw(e, "GroupPositions", "[]")
  setText(e, "Root", id)
  setRaw(e, "Items", text(items))
  result = text(e)

proc composeLoot*(dbText, map, raidId: string): seq[string] =
  ## Emit the compose, then turn whatever a planter handed back into loot
  ## entries. Returns the entries to append to the served `Loot` array.
  result = @[]
  resetRaid(map, raidId)
  if not gInstalled:
    return
  # Per GENERATION, not per raid: `generateLoot` is called twice on the same
  # raid id by the self-check and by anything that regenerates a map, and a
  # tally that accumulated across those calls would report double.
  gPlanted = @[]
  gRefused = 0
  gLootIn = @[]
  gComposing = raidId
  var o = newDoc()
  setText(o, "map", map)
  setText(o, "raidId", raidId)
  discard broadcast(EvLootCompose, text(o))
  if gLocalOn:
    discard gLocalLoot(text(o))
  gComposing = ""
  for rawItem in gLootIn:
    let it = whole(rawItem)
    let id = it.field("id").asText("")
    let tpl = it.field("tpl").asText("")
    if id.len == 0:
      warn "planting: a planted item carries no `id` -- refused"
      gRefused = gRefused + 1
      continue
    if not tplKnown(dbText, tpl):
      warn "planting: REFUSED planted item " & id & " -- its tpl '" & tpl &
           "' is not in templates.items, so the client could not resolve it"
      gRefused = gRefused + 1
      continue
    let entry = lootEntryFor(it)
    if entry.len == 0:
      gRefused = gRefused + 1
      continue
    result.add entry
    gPlanted.add id
    let cacheId = it.field("cacheId").asText("")
    if cacheId.len > 0:
      info "planting: item " & id & " (" & tpl & ") from cache " & cacheId
  gLootIn = @[]
  census()

proc plantedIds*(): seq[string] = gPlanted

# ---------------------------------------------------------------------------
# Bot groups
# ---------------------------------------------------------------------------

type
  PlantedGroup* = object
    groupId*: string
    factionId*: string
    role*: string
    count*: int
    names*: seq[string]

proc composeBots*(map, raidId: string; wave: int; requestsJson: string):
    seq[PlantedGroup] =
  ## Emit the bots compose and return the groups a planter asked for.
  ##
  ## `requested` is passed through verbatim from what the CLIENT asked for, so
  ## a planter decides with the wave in front of it rather than guessing.
  result = @[]
  if not gInstalled:
    return
  resetRaid(map, raidId)
  gGroupsIn = @[]
  gComposing = raidId
  var o = newDoc()
  setText(o, "map", map)
  setText(o, "raidId", raidId)
  setNumber(o, "wave", wave)
  if requestsJson.len > 0:
    setRaw(o, "requested", requestsJson)
  else:
    setRaw(o, "requested", "[]")
  discard broadcast(EvBotsCompose, text(o))
  if gLocalOn:
    discard gLocalBots(text(o))
  gComposing = ""
  for rawGroup in gGroupsIn:
    let g = whole(rawGroup)
    var n = g.field("count").asInt(0)
    if n < 1:
      warn "planting: a planted bot group asked for " & $n &
           " bot(s) -- refused"
      continue
    if n > 32:
      warn "planting: a planted bot group asked for " & $n &
           " bots; capped at 32"
      n = 32
    # The name list is built BEFORE the object rather than appended to a field
    # of it: nimony miscompiles `add` into a `seq` field of a locally
    # constructed object here (`'PlantedGroup' has no member named ...` out of
    # the C backend, 2026-09-06). Building it first is equivalent and compiles.
    var nms: seq[string] = @[]
    let names = each(g.field("names"))
    for nm in names:
      nms.add nm.asText("")
    let one = PlantedGroup(groupId: g.field("groupId").asText(""),
                           factionId: g.field("factionId").asText(""),
                           role: g.field("role").asText("assault"),
                           count: n, names: nms)
    result.add one
    gGroups = gGroups + 1
    # `groupId`/`factionId` are carried HERE and not on the profile: `Info` has
    # no `GroupId` member on this build (see the module header).
    info "planting: bot group " & one.groupId & " (faction " & one.factionId &
         ") -- " & $n & " x " & one.role
  gGroupsIn = @[]
  census()

# ---------------------------------------------------------------------------
# Raid end
# ---------------------------------------------------------------------------

proc emitTaken*(profileText: string) =
  ## `tarkov.loot.taken` for the planted ids that came home. **Only planted
  ## ids** -- the whole inventory is not this event's business.
  ##
  ## Nothing is emitted when nothing planted came home, so a planter that
  ## receives this knows a pickup happened rather than having to diff.
  if gPlanted.len == 0:
    return
  var found = newList()
  let items = each(field(profileText, "Inventory.items"))
  for it in items:
    let id = it.field("_id").asText("")
    if id.len == 0:
      continue
    for p in gPlanted:
      if p == id:
        found.add quoted(id)
        break
  if found.len == 0:
    return
  var o = newDoc()
  setText(o, "raidId", gRaidId)
  setRaw(o, "itemIds", text(found))
  discard broadcast(EvLootTaken, text(o))
  info "planting: " & $found.len & " of " & $gPlanted.len &
       " planted item(s) came home from " & gMap
