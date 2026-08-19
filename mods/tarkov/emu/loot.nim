## What is lying on the floor when a raid starts.
##
## A map's loot is three tables the database keeps apart, and the client wants
## them as one flat array:
##
## - `locations.<map>.staticContainers` — the crates, safes and jackets that are
##   welded to the map. Each one carries the transform the level was built with,
##   and a probability that this particular crate exists at all this raid.
## - the **static loot distribution** for a container's own template — a pool of
##   item templates with relative weights, plus a distribution over *how many*
##   things are in it. Read from `loot.staticLoot`, with
##   `locations.<map>.staticLoot` accepted as well because databases dumped at
##   different times put it in different places.
## - `locations.<map>.looseLoot` — spawn points on the ground, each with a
##   probability and a set of candidate items already laid out in the point's
##   own template.
##
## Two kinds of item cannot be spawned as a bare template and have to have their
## children generated with them, because the client renders the parent from what
## its children say:
##
## - an **ammo box** is a box plus cartridge stacks; an empty one shows a full
##   box that gives nothing when opened,
## - a **weapon** is a receiver plus every mod bolted to it. A rifle with no
##   preset expanded is a floating receiver with no magazine, no handguard and
##   no sights — the client draws it, and it is not a gun.
##
## ## Placement
##
## Two items in the same crate must not overlap: the client draws a container
## from the cells the server sent, and an item on top of another is an item that
## cannot be picked up. So each container gets an occupancy map per grid from
## its own template and a first-fit scan, and an item that does not fit is
## dropped rather than stacked on one that did.
##
## `emu/grid` solves the same problem for the stash and is **not** reused here,
## for one reason: its size lookup goes straight to `dbRead`, so a container
## packed through it could only ever be tested against a live database. The
## occupancy code below reads sizes through `LootDb`, which is what lets the
## whole of this module be run against a fixture. Closing that would take one
## addition to `emu/grid` — see the note at `packInto`.
##
## ## Determinism
##
## Every roll comes out of `emu/rand`, seeded from the raid id and the map name
## and nothing else. The same raid id against the same database produces the
## same floor down to the item ids, so "the crate by the gas station on raid
## 65f1a2… was empty" is a reproducible statement rather than a story. This is
## the reason there is no ambient RNG in this project.
##
## ## With no tables at all
##
## Every read has a fallback and the fallback is always "nothing here". A
## database with no locations, no item table and no globals yields `[]` — an
## empty, well-formed loot list that loads and plays. That property is what
## makes a raid testable against the small fixture, and it is why nothing below
## is allowed to assume a table exists.
##
## ## Not done here
##
## - **Magazines are not filled.** A preset's magazine spawns empty. Doing it
##   properly means resolving the weapon's caliber to `loot.staticAmmo`, and a
##   half-done version that guesses a cartridge puts the wrong ammo in the gun,
##   which is worse than an empty magazine the player can see is empty.
## - **Spawn point clustering.** SPT thins loose loot by picking a target count
##   for the map and choosing points to hit it; here every point is rolled
##   independently against its own probability. The totals are close and the
##   distribution is flatter.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import rand

# ---------------------------------------------------------------------------
# Reading the database
# ---------------------------------------------------------------------------
#
# Generation reads a dozen different subtrees, and it has to be runnable over a
# fixture rather than only over the loaded database -- otherwise the only way to
# test the loot on a map is to have that map's real 30MB of tables present.
#
# So every read goes through `LootDb`, which is either the host database or one
# JSON document standing in for it. The paths are identical in both cases, which
# is what keeps the fixture an honest test of the real code path.

type
  LootDb* = object
    live*: bool    ## read through `dbRead`
    raw*: string   ## when not live, a whole database document

proc liveDb*(): LootDb =
  ## The host's loaded database.
  LootDb(live: true, raw: "")

proc textDb*(document: string): LootDb =
  ## A database standing in one string. What the self-check runs against.
  LootDb(live: false, raw: document)

proc sub*(d: LootDb; path: string): string =
  ## A dotted subtree as raw JSON, or the empty string when it is not there.
  ## "Not there" is never an error here: half of these paths are absent on a
  ## server with no loot tables, which is a supported way to run.
  if d.live:
    let v = dbRead(path)
    if v.ok:
      return v.raw
    return ""
  if d.raw.len == 0:
    return ""
  let j = field(d.raw, path)
  if not j.found:
    return ""
  result = raw(j)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

type
  LootConfig* = object
    enabled*: bool          ## turn loot generation off entirely
    staticMultiplier*: float  ## scales container spawn chance and fill
    looseMultiplier*: float   ## scales loose spawn point chance
    maxItems*: int          ## hard ceiling on the items in one response

proc defaultLootConfig*(): LootConfig =
  ## The shipped behaviour: the map's own numbers, unscaled.
  LootConfig(enabled: true, staticMultiplier: 1.0, looseMultiplier: 1.0,
             maxItems: 20000)

proc lootConfig*(): LootConfig =
  ## Read from the mod's `config.json`. Four keys, all optional -- a config file
  ## that predates this module still produces the default behaviour rather than
  ## a map with no loot on it.
  result = defaultLootConfig()
  result.enabled = setting("lootEnabled").asBool(true)
  result.staticMultiplier = setting("staticLootMultiplier").asFloat(1.0)
  result.looseMultiplier = setting("looseLootMultiplier").asFloat(1.0)
  result.maxItems = setting("maxLootItems").asInt(20000)
  if result.staticMultiplier < 0.0: result.staticMultiplier = 0.0
  if result.looseMultiplier < 0.0: result.looseMultiplier = 0.0
  if result.maxItems < 0: result.maxItems = 0

# ---------------------------------------------------------------------------
# Item templates
# ---------------------------------------------------------------------------

proc itemProps(d: LootDb; tpl: string): string =
  if tpl.len == 0:
    return ""
  result = sub(d, "templates.items." & tpl & "._props")

proc sizeOf(d: LootDb; tpl: string; width, height: var int) =
  ## A template's footprint, defaulting to 1x1. An item the database does not
  ## describe still has to be placed somewhere -- refusing it would mean a
  ## fixture-sized database spawns nothing at all.
  width = 1
  height = 1
  let props = itemProps(d, tpl)
  if props.len == 0:
    return
  let j = whole(props)
  width = j.field("Width").asInt(1)
  height = j.field("Height").asInt(1)
  if width < 1: width = 1
  if height < 1: height = 1

proc stackMaxOf(d: LootDb; tpl: string): int =
  ## The stack limit, or 1 when unknown.
  ##
  ## Note this is the opposite convention from `templates.itemStackLimit`, which
  ## answers zero for "unknown" so that a merge is not refused. Here the number
  ## is used to *divide* a count into stacks, and dividing by zero-meaning-
  ## unknown would either loop forever or emit one absurd stack. One is the safe
  ## answer for loot: more item entries than necessary, never an invalid one.
  let props = itemProps(d, tpl)
  if props.len == 0:
    return 1
  result = field(props, "StackMaxSize").asInt(1)
  if result < 1: result = 1

# ---------------------------------------------------------------------------
# Weighted distributions
# ---------------------------------------------------------------------------

type
  Distribution = object
    ## A pool of keys with relative weights. The keys are template ids for
    ## static loot and item ids within a spawn point's own list for loose loot,
    ## which is why this holds strings and not templates.
    keys: seq[string]
    weights: seq[float]

proc newDistribution(): Distribution =
  Distribution(keys: @[], weights: @[])

proc len(dist: Distribution): int = dist.keys.len

proc entryKey(e: JsonRef): string =
  ## The key of one distribution entry.
  ##
  ## Four spellings are accepted because four are in circulation: `tpl` in the
  ## current static loot tables, `composedKey.key` in loose loot, and `_id` /
  ## `itemtpl` in older dumps. Guessing one and ignoring the rest produces a
  ## silently empty pool on a database that is perfectly good.
  var k = e.field("tpl").asText("")
  if k.len > 0: return k
  k = e.field("composedKey.key").asText("")
  if k.len > 0: return k
  k = e.field("_id").asText("")
  if k.len > 0: return k
  result = e.field("itemtpl").asText("")

proc readDistribution(listJson: string): Distribution =
  ## An `itemDistribution` array. Entries with no key, or with a weight that is
  ## zero or negative, are dropped rather than kept at weight zero -- a pool
  ## that is entirely zero-weighted must come out empty so the caller can tell.
  result = newDistribution()
  if listJson.len == 0:
    return
  let j = whole(listJson)
  if not isArray(j):
    return
  let entries = each(j)
  for e in entries:
    let k = entryKey(e)
    if k.len == 0:
      continue
    var w = e.field("relativeProbability").asFloat(-1.0)
    if w < 0.0:
      w = e.field("relativeProbability").asFloat(1.0)
    if w <= 0.0:
      continue
    result.keys.add k
    result.weights.add w

proc pick(dist: Distribution; r: var Rng): string =
  let i = pickWeighted(r, dist.weights)
  if i < 0:
    return ""
  result = dist.keys[i]

proc readCount(listJson: string; r: var Rng): int =
  ## `itemcountDistribution` — how many things are in this container. One when
  ## the table says nothing, because a container that exists and is empty is
  ## indistinguishable from a bug.
  if listJson.len == 0:
    return 1
  let j = whole(listJson)
  if not isArray(j):
    return 1
  var counts: seq[int] = @[]
  var weights: seq[float] = @[]
  let entries = each(j)
  for e in entries:
    let w = e.field("relativeProbability").asFloat(0.0)
    if w <= 0.0:
      continue
    counts.add e.field("count").asInt(0)
    weights.add w
  if counts.len == 0:
    return 1
  let i = pickWeighted(r, weights)
  if i < 0:
    return 1
  result = counts[i]
  if result < 0: result = 0

# ---------------------------------------------------------------------------
# Occupancy
# ---------------------------------------------------------------------------
#
# The same first-fit scan `emu/grid` does for the stash, with the sizes read
# through `LootDb` instead of `dbRead`. If `emu/grid` ever exports
# `findSpaceSized(g: Grid; w, h: int)` and its `fits`, this whole section
# becomes three lines that call it -- the only thing standing in the way is
# that `findSpace` looks its own sizes up.

type
  Cells = object
    name: string   ## the grid's `_name`; the client's `slotId` for the item
    w: int
    h: int
    used: seq[bool]

proc newCells(name: string; w, h: int): Cells =
  Cells(name: name, w: w, h: h, used: newSeq[bool](w * h))

proc fitsAt(c: Cells; x, y, w, h: int): bool =
  if x < 0 or y < 0 or x + w > c.w or y + h > c.h:
    return false
  var ry = y
  while ry < y + h:
    var rx = x
    while rx < x + w:
      if c.used[ry * c.w + rx]:
        return false
      inc rx
    inc ry
  result = true

proc occupy(c: var Cells; x, y, w, h: int) =
  var ry = y
  while ry < y + h:
    var rx = x
    while rx < x + w:
      if rx >= 0 and ry >= 0 and rx < c.w and ry < c.h:
        c.used[ry * c.w + rx] = true
      inc rx
    inc ry

proc containerGrids(d: LootDb; tpl: string): seq[Cells] =
  ## A container template's grids.
  ##
  ## Empty when the template is not in the database, and that is deliberate: the
  ## alternative is to invent a default size, and a container whose real size is
  ## unknown would then be filled with items the client draws outside its own
  ## window. Nothing in an unknown container is a visible, harmless failure.
  result = @[]
  let props = itemProps(d, tpl)
  if props.len == 0:
    return
  let grids = field(props, "Grids")
  if not isArray(grids):
    return
  let gs = each(grids)
  var index = 0
  for g in gs:
    var name = g.field("_name").asText("")
    if name.len == 0:
      name = "main"
    let w = g.field("_props.cellsH").asInt(0)
    let h = g.field("_props.cellsV").asInt(0)
    if w > 0 and h > 0:
      # A pathological grid would allocate a cell map measured in gigabytes;
      # nothing in the game is larger than this and a row that is has been
      # corrupted somewhere upstream.
      if w * h <= 4096:
        result.add newCells(name, w, h)
    inc index

# ---------------------------------------------------------------------------
# Building items
# ---------------------------------------------------------------------------

type
  ItemSink = object
    ## The flat item list one loot entry carries, built up as children are
    ## generated. A `seq` of raw JSON objects rather than a tree: the client's
    ## format *is* flat -- parentage is a field, not nesting -- and building it
    ## flat means the parent/child relationship is written once.
    items: seq[string]

proc newSink(): ItemSink = ItemSink(items: @[])

proc emit(s: var ItemSink; itemJson: string) = s.items.add itemJson

proc simpleItem(id, tpl: string): Doc =
  var doc = newDoc()
  setText(doc, "_id", id)
  setText(doc, "_tpl", tpl)
  result = doc

proc locationRaw(x, y: int; rotated: bool): string =
  var loc = newDoc()
  setNumber(loc, "x", x)
  setNumber(loc, "y", y)
  setText(loc, "r", (if rotated: "Vertical" else: "Horizontal"))
  result = text(loc)

# --- presets ---------------------------------------------------------------

type
  PresetIndex = object
    ## `globals.ItemPresets`, turned inside out: root template -> the preset's
    ## item list. Built once per raid because the presets object holds a couple
    ## of thousand entries and a scan of it per spawned weapon is the kind of
    ## cost that only shows up on someone else's loading screen.
    tpls: seq[string]
    items: seq[string]
    encyclopedia: seq[bool]  ## whether this is the item's *default* preset

proc newPresetIndex(): PresetIndex =
  PresetIndex(tpls: @[], items: @[], encyclopedia: @[])

proc buildPresets(d: LootDb): PresetIndex =
  result = newPresetIndex()
  let raw0 = sub(d, "globals.ItemPresets")
  if raw0.len == 0:
    return
  let j = whole(raw0)
  if not isObject(j):
    return
  let names = keys(j)
  for n in names:
    let p = child(j, n)
    let itemsRef = p.field("_items")
    if not isArray(itemsRef):
      continue
    let rootTpl = itemsRef.field("[0]._tpl").asText("")
    if rootTpl.len == 0:
      continue
    let isDefault = p.field("_encyclopedia").asText("").len > 0
    # A default preset replaces an earlier non-default one for the same weapon;
    # anything else keeps the first seen, so the choice does not depend on the
    # order the database happens to serialise its object in.
    var replaced = false
    for i in 0 ..< result.tpls.len:
      if result.tpls[i] == rootTpl:
        if isDefault and not result.encyclopedia[i]:
          result.items[i] = raw(itemsRef)
          result.encyclopedia[i] = true
        replaced = true
        break
    if replaced:
      continue
    result.tpls.add rootTpl
    result.items.add raw(itemsRef)
    result.encyclopedia.add isDefault

proc presetFor(p: PresetIndex; tpl: string): string =
  for i in 0 ..< p.tpls.len:
    if p.tpls[i] == tpl:
      return p.items[i]
  result = ""

proc expandPreset(s: var ItemSink; r: var Rng; presetItems, rootId: string) =
  ## Every mod of a preset, re-parented onto `rootId` with fresh ids.
  ##
  ## The preset's own ids are reused across every copy of the weapon in the
  ## database, so they cannot go out as-is: two rifles on the floor sharing a
  ## magazine id is a client that shows one of them and loses the other. The
  ## remap keeps the shape of the tree and replaces only the identity.
  let list = parseArray(presetItems)
  if not list.ok or list.len == 0:
    return
  var oldIds: seq[string] = @[]
  var newIds: seq[string] = @[]
  for i in 0 ..< list.len:
    let it = whole(list.items[i])
    oldIds.add it.field("_id").asText("")
    if i == 0:
      newIds.add rootId   # the preset's root *is* the item already emitted
    else:
      newIds.add mongoId(r)
  for i in 1 ..< list.len:
    var doc = parseObject(list.items[i])
    if not doc.ok:
      continue
    setText(doc, "_id", newIds[i])
    let parent = get(doc, "parentId").asText("")
    var mapped = rootId
    for k in 0 ..< oldIds.len:
      if oldIds[k] == parent:
        mapped = newIds[k]
        break
    setText(doc, "parentId", mapped)
    s.emit text(doc)

# --- ammo boxes ------------------------------------------------------------

proc expandAmmoBox(s: var ItemSink; d: LootDb; r: var Rng;
                   tpl, rootId: string): bool =
  ## Cartridge stacks for a box that has `StackSlots`. Returns whether this
  ## template was an ammo box at all, so the caller does not also try to treat
  ## it as a weapon.
  ##
  ## The cartridge is chosen from the box's *own* filter rather than from
  ## `loot.staticAmmo`: the filter is what the box can physically hold, and it
  ## is present in the item table the client already has. Picking off the ammo
  ## table would let a 5.45 box spawn full of 7.62.
  let props = itemProps(d, tpl)
  if props.len == 0:
    return false
  let slots = field(props, "StackSlots")
  if not isArray(slots):
    return false
  let slotList = each(slots)
  if slotList.len == 0:
    return false
  var produced = false
  for slot in slotList:
    let filters = slot.field("_props.filters")
    let f0 = at(filters, 0)
    let allowed = f0.field("Filter")
    let n = count(allowed)
    if n == 0:
      continue
    let cartridge = at(allowed, nextInt(r, n)).asText("")
    if cartridge.len == 0:
      continue
    var total = slot.field("_max_count").asInt(0)
    if total <= 0:
      continue
    let perStack = stackMaxOf(d, cartridge)
    let slotName = slot.field("_name").asText("cartridges")
    var guard = 0
    while total > 0 and guard < 64:
      var n2 = perStack
      if n2 > total: n2 = total
      var doc = simpleItem(mongoId(r), cartridge)
      setText(doc, "parentId", rootId)
      setText(doc, "slotId", slotName)
      var upd = newDoc()
      setNumber(upd, "StackObjectsCount", n2)
      setRaw(doc, "upd", text(upd))
      s.emit text(doc)
      total = total - n2
      produced = true
      inc guard
  result = produced

# --- one spawned item ------------------------------------------------------

proc spawnItem(s: var ItemSink; d: LootDb; p: PresetIndex; r: var Rng;
               tpl, parentId, slotId, locationJson: string): string =
  ## One item and everything it needs to be a real item, appended to `s`.
  ## Returns the new item's id.
  let id = mongoId(r)
  var doc = simpleItem(id, tpl)
  if parentId.len > 0:
    setText(doc, "parentId", parentId)
    setText(doc, "slotId", slotId)
  if locationJson.len > 0:
    setRaw(doc, "location", locationJson)
  let limit = stackMaxOf(d, tpl)
  if limit > 1:
    # Stackables spawn as a partial stack. Full stacks of everything would make
    # every med case on the map worth the same, which is a flat economy.
    var n = 1 + nextInt(r, limit)
    if n > limit: n = limit
    var upd = newDoc()
    setNumber(upd, "StackObjectsCount", n)
    setRaw(doc, "upd", text(upd))
  s.emit text(doc)

  if not expandAmmoBox(s, d, r, tpl, id):
    let preset = presetFor(p, tpl)
    if preset.len > 0:
      expandPreset(s, r, preset, id)
  result = id

# ---------------------------------------------------------------------------
# Filling a container
# ---------------------------------------------------------------------------

proc packInto(s: var ItemSink; d: LootDb; p: PresetIndex; r: var Rng;
              grids: var seq[Cells]; containerId, tpl: string): bool =
  ## First fit across a container's grids, upright then rotated -- the same
  ## scan `emu/grid.findSpace` does, over sizes read through `LootDb`. False
  ## when there is nowhere left, which the caller must treat as "stop", not as
  ## "put it at 0,0": an overlapping item is drawn on top of another and neither
  ## can be picked up.
  var w = 1
  var h = 1
  sizeOf(d, tpl, w, h)
  for gi in 0 ..< grids.len:
    var y = 0
    while y < grids[gi].h:
      var x = 0
      while x < grids[gi].w:
        if fitsAt(grids[gi], x, y, w, h):
          occupy(grids[gi], x, y, w, h)
          discard spawnItem(s, d, p, r, tpl, containerId, grids[gi].name,
                            locationRaw(x, y, false))
          return true
        if w != h and fitsAt(grids[gi], x, y, h, w):
          occupy(grids[gi], x, y, h, w)
          discard spawnItem(s, d, p, r, tpl, containerId, grids[gi].name,
                            locationRaw(x, y, true))
          return true
        inc x
      inc y
  result = false

proc staticPool(d: LootDb; locationId, tpl: string): string =
  ## A container template's loot distribution. `loot.staticLoot` is where a
  ## current dump keeps it; the per-map copy is checked as well because older
  ## ones put it under the location.
  var v = sub(d, "loot.staticLoot." & tpl)
  if v.len > 0: return v
  v = sub(d, "locations." & locationId & ".staticLoot." & tpl)
  if v.len > 0: return v
  result = sub(d, "staticLoot." & tpl)

# ---------------------------------------------------------------------------
# The loot entry envelope
# ---------------------------------------------------------------------------

proc lootEntry(templateJson, rootId, itemsJson: string): string =
  ## One element of the `Loot` array: the level's own transform for this spawn,
  ## with the generated items in it.
  ##
  ## Built member-wise off the database's template rather than from scratch. The
  ## template carries `Position`, `Rotation`, `useGravity`, `IsGroupPosition`
  ## and several fields that differ between map versions, and a builder that
  ## names the ones this module knows about would drop the rest -- which is an
  ## item spawning in the wrong place, or under the floor.
  var doc = parseObject(templateJson)
  if not doc.ok:
    return ""
  setText(doc, "Root", rootId)
  setRaw(doc, "Items", itemsJson)
  result = text(doc)

proc itemsArray(s: ItemSink): string =
  var l = newList()
  for it in s.items:
    l.add it
  result = text(l)

# ---------------------------------------------------------------------------
# Static containers
# ---------------------------------------------------------------------------

proc forcedFor(forcedJson, containerId: string): seq[string] =
  ## `staticForced` — the items a specific crate always holds, quest items
  ## mostly. Keyed by the *spawn point's* id, not by the template, because two
  ## crates of the same kind on one map do not both hold the quest item.
  result = @[]
  if forcedJson.len == 0 or containerId.len == 0:
    return
  let j = whole(forcedJson)
  if not isArray(j):
    return
  let entries = each(j)
  for e in entries:
    if e.field("containerId").asText("") != containerId:
      continue
    let tpl = e.field("itemTpl").asText("")
    if tpl.len > 0:
      result.add tpl

proc staticContainers(d: LootDb; p: PresetIndex; r: var Rng;
                      cfg: LootConfig; locationId: string;
                      chanceMul: float; budget: var int): seq[string] =
  result = @[]
  let root = sub(d, "locations." & locationId & ".staticContainers")
  if root.len == 0:
    return
  let rootRef = whole(root)
  # Two shapes in circulation: the object with `staticContainers` /
  # `staticForced` / `staticWeapons` inside it, and a bare array of containers.
  var listRef = rootRef
  var forcedJson = ""
  if isObject(rootRef):
    listRef = child(rootRef, "staticContainers")
    let f = child(rootRef, "staticForced")
    if f.found:
      forcedJson = raw(f)
  if not isArray(listRef):
    return

  let entries = each(listRef)
  for entry in entries:
    if budget <= 0:
      return
    let tmpl = entry.field("template")
    if not tmpl.found:
      continue
    let probability = entry.field("probability").asFloat(1.0) * chanceMul
    let alwaysSpawn = tmpl.field("IsAlwaysSpawn").asBool(false)
    if not alwaysSpawn and not chance(r, probability):
      continue

    let containerTpl = tmpl.field("Items[0]._tpl").asText("")
    if containerTpl.len == 0:
      continue
    let spawnId = tmpl.field("Id").asText("")

    var sink = newSink()
    let containerId = mongoId(r)
    var containerDoc = simpleItem(containerId, containerTpl)
    sink.emit text(containerDoc)

    var grids = containerGrids(d, containerTpl)
    if grids.len > 0:
      let forced = forcedFor(forcedJson, spawnId)
      for tpl in forced:
        discard packInto(sink, d, p, r, grids, containerId, tpl)

      let pool = staticPool(d, locationId, containerTpl)
      if pool.len > 0:
        let poolRef = whole(pool)
        let dist = readDistribution(raw(child(poolRef, "itemDistribution")))
        var n = readCount(raw(child(poolRef, "itemcountDistribution")), r)
        # The multiplier scales how full a crate is as well as whether it is
        # there, which is what "more loot" means to a player who asks for it.
        n = int(float(n) * cfg.staticMultiplier + 0.5)
        if n > 64: n = 64
        var k = 0
        while k < n and dist.len > 0:
          let tpl = pick(dist, r)
          if tpl.len == 0:
            break
          if not packInto(sink, d, p, r, grids, containerId, tpl):
            break   # full: every further item would land on one already there
          inc k

    let entryJson = lootEntry(raw(tmpl), containerId, itemsArray(sink))
    if entryJson.len == 0:
      continue
    budget = budget - sink.items.len
    result.add entryJson

# ---------------------------------------------------------------------------
# Loose loot
# ---------------------------------------------------------------------------

proc descendants(list: List; rootId: string; picked: var seq[int]) =
  ## The chosen root's index in the spawn point's item list, plus everything
  ## parented to it, transitively. A spawn point's `Items` holds *all* of its
  ## candidates at once -- taking the whole list would spawn a jacket's entire
  ## catalogue in one pile.
  picked = @[]
  var frontier: seq[string] = @[rootId]
  for i in 0 ..< list.len:
    if whole(list.items[i]).field("_id").asText("") == rootId:
      picked.add i
  var guard = 0
  while guard < 16:
    var added: seq[string] = @[]
    for i in 0 ..< list.len:
      var seen = false
      for k in picked:
        if k == i:
          seen = true
          break
      if seen:
        continue
      let parent = whole(list.items[i]).field("parentId").asText("")
      for f in frontier:
        if parent == f:
          picked.add i
          added.add whole(list.items[i]).field("_id").asText("")
          break
    if added.len == 0:
      return
    frontier = added
    inc guard

proc looseSpawn(d: LootDb; p: PresetIndex; r: var Rng;
                point: JsonRef; budget: var int): string =
  ## One loose spawn point, resolved to a loot entry.
  let tmpl = point.field("template")
  if not tmpl.found:
    return ""
  let itemsRef = tmpl.field("Items")
  if not isArray(itemsRef):
    return ""
  let list = parseArray(itemsRef)
  if not list.ok or list.len == 0:
    return ""

  # Which of the point's candidates spawns. With no distribution the point has
  # exactly one candidate and the whole list is it.
  var rootId = whole(list.items[0]).field("_id").asText("")
  let dist = readDistribution(raw(point.field("itemDistribution")))
  if dist.len > 0:
    let k = pick(dist, r)
    if k.len == 0:
      return ""
    rootId = k

  var picked: seq[int] = @[]
  descendants(list, rootId, picked)
  if picked.len == 0:
    return ""

  # Fresh ids, parentage remapped -- the database's ids are shared by every map
  # that reuses this spawn point.
  var oldIds: seq[string] = @[]
  var newIds: seq[string] = @[]
  for i in picked:
    oldIds.add whole(list.items[i]).field("_id").asText("")
    newIds.add mongoId(r)

  var sink = newSink()
  var newRoot = ""
  for n in 0 ..< picked.len:
    var doc = parseObject(list.items[picked[n]])
    if not doc.ok:
      continue
    setText(doc, "_id", newIds[n])
    if oldIds[n] == rootId:
      newRoot = newIds[n]
      # A loose item is parented to the world, not to a container.
      remove(doc, "parentId")
      remove(doc, "slotId")
      remove(doc, "location")
    else:
      let parent = get(doc, "parentId").asText("")
      for k in 0 ..< oldIds.len:
        if oldIds[k] == parent:
          setText(doc, "parentId", newIds[k])
          break
    sink.emit text(doc)
  if newRoot.len == 0:
    return ""

  # A weapon or an ammo box laid out by hand in the spawn point keeps what the
  # database gave it; one that arrived bare gets its children generated, which
  # is the case that would otherwise put a receiver with no magazine on the
  # floor.
  if sink.items.len == 1:
    let tpl = whole(sink.items[0]).field("_tpl").asText("")
    if not expandAmmoBox(sink, d, r, tpl, newRoot):
      let preset = presetFor(p, tpl)
      if preset.len > 0:
        expandPreset(sink, r, preset, newRoot)

  budget = budget - sink.items.len
  result = lootEntry(raw(tmpl), newRoot, itemsArray(sink))

proc looseLoot(d: LootDb; p: PresetIndex; r: var Rng; cfg: LootConfig;
               locationId: string; chanceMul: float;
               budget: var int): seq[string] =
  result = @[]
  let root = sub(d, "locations." & locationId & ".looseLoot")
  if root.len == 0:
    return
  let rootRef = whole(root)

  # Forced points are quest and key spawns; they ignore probability entirely.
  let forced = child(rootRef, "spawnpointsForced")
  if isArray(forced):
    let pts = each(forced)
    for pt in pts:
      if budget <= 0:
        return
      let e = looseSpawn(d, p, r, pt, budget)
      if e.len > 0:
        result.add e

  let points = child(rootRef, "spawnpoints")
  if not isArray(points):
    return
  let pts = each(points)
  for pt in pts:
    if budget <= 0:
      return
    let probability = pt.field("probability").asFloat(0.0) *
                      cfg.looseMultiplier * chanceMul
    if not chance(r, probability):
      continue
    let e = looseSpawn(d, p, r, pt, budget)
    if e.len > 0:
      result.add e

# ---------------------------------------------------------------------------
# The entry point
# ---------------------------------------------------------------------------

proc generateLoot*(d: LootDb; cfg: LootConfig;
                   locationId, raidId: string): string =
  ## The whole `Loot` array for one raid, as JSON text.
  ##
  ## Pure in everything except `d`: the same database, config, map and raid id
  ## give the same string. `raidId` is the seed and it is the only source of
  ## variation, which is why it must be the raid's real id and not a clock --
  ## seeding from the time makes the loot on a reported raid unreachable.
  if not cfg.enabled or cfg.maxItems <= 0:
    return "[]"
  var r = seededRng(raidId & "|" & locationId)
  var budget = cfg.maxItems

  # The map's own modifiers. A map that says nothing gets 1.0 rather than 0 --
  # a missing modifier must not empty the map.
  var containerMul = cfg.staticMultiplier
  var looseMul = 1.0
  let base = sub(d, "locations." & locationId & ".base")
  if base.len > 0:
    let b = whole(base)
    containerMul = containerMul * b.field("GlobalContainerChanceModifier").asFloat(1.0)
    looseMul = b.field("GlobalLootChanceModifier").asFloat(1.0)
  if containerMul < 0.0: containerMul = 0.0
  if looseMul < 0.0: looseMul = 0.0

  let p = buildPresets(d)
  var out1 = newList()

  # The budget, shared out, and it is the same rule the flea's offer cap
  # follows: **a bounded list filled from one source before the other gets a
  # turn is not a bound, it is a preference nobody stated.** The containers are
  # walked first and were handed the whole of `maxItems`, so a map whose crates
  # alone can spend it -- a big map with a generous `staticLootMultiplier`, or
  # anyone who raises the multiplier because they want more loot -- would come
  # back with the crates full and **no loose loot at all**: no jackets, no floor
  # spawns, nothing to pick up on the way past, and no log line saying why.
  #
  # Half each, with the containers' unspent half handed on to the loose pass.
  # The other direction cannot arise, because the containers run first; and on
  # every real map measured so far neither half binds at all -- three maps out
  # of the imported database produce 1,826 items between them against a budget
  # of 20,000 -- so this is a bound on a pathological table rather than a change
  # to what a map holds.
  var staticShare = budget div 2
  if staticShare < 1:
    staticShare = budget
  var staticBudget = staticShare
  let statics = staticContainers(d, p, r, cfg, locationId, containerMul,
                                 staticBudget)
  for e in statics:
    out1.add e
  # `staticBudget` is what that pass did *not* spend, so the sum of the two
  # halves is still exactly `maxItems`.
  var looseBudget = budget - staticShare + staticBudget
  let loose = looseLoot(d, p, r, cfg, locationId, looseMul, looseBudget)
  for e in loose:
    out1.add e
  result = text(out1)

proc lootFor*(locationId, raidId: string): string =
  ## What `emu/raid` calls: the loaded database, the mod's config, one line.
  ##
  ## With no loot tables present every read inside returns nothing and this
  ## returns `[]` -- a valid, empty floor. A raid on the test fixture starts.
  result = generateLoot(liveDb(), lootConfig(), locationId, raidId)

# ---------------------------------------------------------------------------
# Self-check
# ---------------------------------------------------------------------------
#
# The module is a pure function over a JSON document, so it can be checked
# without a server, without a database and without the network. This is what
# proves the fixture path before `emu/raid` imports any of it.
#
# `Fixture` is the same document as `tests/fixtures/emu-loot.json`. It is
# duplicated here rather than read from disk so that the check runs inside a
# mod, which has no file access of its own.

const Fixture* = """{
  "locations": {
    "testmap": {
      "base": {
        "_Id": "testmap",
        "Name": "Test Map",
        "EscapeTimeLimit": 35,
        "GlobalLootChanceModifier": 1.0,
        "GlobalContainerChanceModifier": 1.0
      },
      "staticContainers": {
        "staticContainers": [
          {
            "probability": 1.0,
            "template": {
              "Id": "crate_1",
              "IsStatic": true,
              "useGravity": false,
              "randomRotation": false,
              "Position": { "x": 1.0, "y": 2.0, "z": 3.0 },
              "Rotation": { "x": 0.0, "y": 90.0, "z": 0.0 },
              "IsGroupPosition": false,
              "GroupPositions": [],
              "Root": "cccccccccccccccccccccccc",
              "Items": [
                { "_id": "cccccccccccccccccccccccc", "_tpl": "ccccbox00000000000000001" }
              ]
            }
          },
          {
            "probability": 0.0,
            "template": {
              "Id": "crate_never",
              "IsStatic": true,
              "Position": { "x": 9.0, "y": 0.0, "z": 9.0 },
              "Root": "dddddddddddddddddddddddd",
              "Items": [
                { "_id": "dddddddddddddddddddddddd", "_tpl": "ccccbox00000000000000001" }
              ]
            }
          }
        ],
        "staticForced": [
          { "containerId": "crate_1", "itemTpl": "qqqquest0000000000000001" }
        ]
      },
      "looseLoot": {
        "spawnpointCount": { "mean": 2, "std": 0 },
        "spawnpointsForced": [
          {
            "locationId": "forced_1",
            "probability": 1.0,
            "template": {
              "Id": "forced_1",
              "IsStatic": false,
              "useGravity": true,
              "Position": { "x": 4.0, "y": 0.0, "z": 4.0 },
              "Root": "eeeeeeeeeeeeeeeeeeeeeeee",
              "Items": [
                { "_id": "eeeeeeeeeeeeeeeeeeeeeeee", "_tpl": "qqqquest0000000000000001" }
              ]
            }
          }
        ],
        "spawnpoints": [
          {
            "locationId": "loose_1",
            "probability": 1.0,
            "template": {
              "Id": "loose_1",
              "IsStatic": false,
              "useGravity": true,
              "Position": { "x": 5.0, "y": 0.0, "z": 6.0 },
              "Root": "ffffffffffffffffffffffff",
              "Items": [
                { "_id": "ffffffffffffffffffffffff", "_tpl": "wwwwgun00000000000000001" },
                { "_id": "ffffffffffffffffffffff02", "_tpl": "aaaaammo0000000000000001" }
              ]
            },
            "itemDistribution": [
              { "composedKey": { "key": "ffffffffffffffffffffffff" }, "relativeProbability": 1 }
            ]
          },
          {
            "locationId": "loose_never",
            "probability": 0.0,
            "template": {
              "Id": "loose_never",
              "Position": { "x": 0.0, "y": 0.0, "z": 0.0 },
              "Root": "1111111111111111111111ff",
              "Items": [
                { "_id": "1111111111111111111111ff", "_tpl": "aaaaammo0000000000000001" }
              ]
            }
          }
        ]
      }
    }
  },
  "loot": {
    "staticLoot": {
      "ccccbox00000000000000001": {
        "itemcountDistribution": [ { "count": 2, "relativeProbability": 1 } ],
        "itemDistribution": [
          { "tpl": "aaaaammo0000000000000001", "relativeProbability": 5 },
          { "tpl": "bbbbbox00000000000000002", "relativeProbability": 5 }
        ]
      }
    }
  },
  "globals": {
    "ItemPresets": {
      "pppppppppppppppppppppppp": {
        "_id": "pppppppppppppppppppppppp",
        "_encyclopedia": "wwwwgun00000000000000001",
        "_items": [
          { "_id": "r0000000000000000000000r", "_tpl": "wwwwgun00000000000000001" },
          { "_id": "m0000000000000000000000m", "_tpl": "mmmmmag00000000000000001",
            "parentId": "r0000000000000000000000r", "slotId": "mod_magazine" }
        ]
      }
    }
  },
  "templates": {
    "items": {
      "ccccbox00000000000000001": {
        "_id": "ccccbox00000000000000001",
        "_props": {
          "Name": "Test crate",
          "Width": 2, "Height": 2,
          "Grids": [ { "_name": "main", "_props": { "cellsH": 3, "cellsV": 3 } } ]
        }
      },
      "aaaaammo0000000000000001": {
        "_id": "aaaaammo0000000000000001",
        "_props": { "Name": "Test cartridge", "Width": 1, "Height": 1, "StackMaxSize": 60 }
      },
      "bbbbbox00000000000000002": {
        "_id": "bbbbbox00000000000000002",
        "_props": {
          "Name": "Test ammo box", "Width": 1, "Height": 1, "StackMaxSize": 1,
          "StackSlots": [
            {
              "_name": "cartridges",
              "_max_count": 100,
              "_props": { "filters": [ { "Filter": [ "aaaaammo0000000000000001" ] } ] }
            }
          ]
        }
      },
      "qqqquest0000000000000001": {
        "_id": "qqqquest0000000000000001",
        "_props": { "Name": "Test quest item", "Width": 1, "Height": 1, "StackMaxSize": 1 }
      },
      "wwwwgun00000000000000001": {
        "_id": "wwwwgun00000000000000001",
        "_props": { "Name": "Test rifle", "Width": 4, "Height": 2, "StackMaxSize": 1 }
      },
      "mmmmmag00000000000000001": {
        "_id": "mmmmmag00000000000000001",
        "_props": { "Name": "Test magazine", "Width": 1, "Height": 1, "StackMaxSize": 1 }
      }
    }
  }
}"""

proc countOccurrences(haystack, needle: string): int =
  result = 0
  if needle.len == 0 or haystack.len < needle.len:
    return
  var i = 0
  while i <= haystack.len - needle.len:
    if haystack.substr(i, i + needle.len - 1) == needle:
      inc result
      i = i + needle.len
    else:
      inc i

proc check(report: var string; ok: bool; what: string) =
  if ok:
    report.add "ok    " & what & "\n"
  else:
    report.add "FAIL  " & what & "\n"

proc selfCheck*(document: string): string =
  ## Runs the generator over a fixture and reports. Callable from a scratch
  ## build (`echo selfCheck(Fixture)`) with no server around it.
  result = ""
  let d = textDb(document)
  let cfg = defaultLootConfig()

  let a = generateLoot(d, cfg, "testmap", "raid-one")
  let b = generateLoot(d, cfg, "testmap", "raid-one")
  let c = generateLoot(d, cfg, "testmap", "raid-two")
  check(result, a == b, "the same raid id gives the same loot")
  check(result, a != c, "a different raid id gives different loot")

  let entries = parseArray(a)
  check(result, entries.ok and entries.len >= 3,
        "the crate, the forced point and the loose point all spawned")
  check(result, countOccurrences(a, "\"crate_never\"") == 0,
        "a zero-probability container does not spawn")
  check(result, countOccurrences(a, "\"loose_never\"") == 0,
        "a zero-probability spawn point does not spawn")

  # The crate: its own item, the forced quest item, and two from the pool.
  var crateItems = 0
  var crateOk = false
  for i in 0 ..< entries.len:
    let e = whole(entries.items[i])
    if e.field("Id").asText("") != "crate_1":
      continue
    crateOk = true
    crateItems = count(e.field("Items"))
    check(result, e.field("Position.y").asFloat(0.0) == 2.0,
          "the level's transform survives generation")
    let root = e.field("Root").asText("")
    check(result, root.len == 24 and root != "cccccccccccccccccccccccc",
          "the container root is a fresh id, not the database's")
  check(result, crateOk, "the static container is in the list")
  check(result, crateItems >= 4,
        "the crate holds itself, the forced item and its pool roll")

  # No two items in one container may share a cell.
  var overlapFree = true
  for i in 0 ..< entries.len:
    let e = whole(entries.items[i])
    let inside = parseArray(e.field("Items"))
    var xs: seq[int] = @[]
    var ys: seq[int] = @[]
    for k in 0 ..< inside.len:
      let it = whole(inside.items[k])
      let loc = it.field("location")
      if not loc.found:
        continue
      let x = loc.field("x").asInt(-1)
      let y = loc.field("y").asInt(-1)
      for n in 0 ..< xs.len:
        if xs[n] == x and ys[n] == y:
          overlapFree = false
      xs.add x
      ys.add y
  check(result, overlapFree, "no two items start in the same cell")

  # A weapon arrives with its preset expanded.
  check(result, countOccurrences(a, "mmmmmag00000000000000001") >= 1,
        "the rifle spawned with its magazine")
  check(result, countOccurrences(a, "\"r0000000000000000000000r\"") == 0,
        "the preset's own ids were replaced")

  # An ammo box arrives with cartridges, split to the stack limit.
  let manyRaids = generateLoot(d, cfg, "testmap", "raid-ammo-check")
  check(result, countOccurrences(manyRaids, "aaaaammo0000000000000001") >= 1,
        "the pool spawns its items")

  # Degradation: no tables at all, and no database at all.
  let empty = generateLoot(textDb("{}"), cfg, "testmap", "raid-one")
  check(result, empty == "[]", "a database with no loot tables gives []")
  let none = generateLoot(textDb(""), cfg, "testmap", "raid-one")
  check(result, none == "[]", "no database at all gives []")
  let unknownMap = generateLoot(d, cfg, "not-a-map", "raid-one")
  check(result, unknownMap == "[]", "a map the database does not have gives []")

  var offCfg = defaultLootConfig()
  offCfg.enabled = false
  check(result, generateLoot(d, offCfg, "testmap", "raid-one") == "[]",
        "lootEnabled=false gives []")

  var bigCfg = defaultLootConfig()
  bigCfg.staticMultiplier = 3.0
  let big = generateLoot(d, bigCfg, "testmap", "raid-one")
  check(result, countOccurrences(big, "\"_tpl\"") >
               countOccurrences(a, "\"_tpl\""),
        "the static multiplier puts more in the crate")

proc selfCheck*(): string = selfCheck(Fixture)
