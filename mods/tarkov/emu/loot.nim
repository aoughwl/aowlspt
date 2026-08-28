## What is lying on the floor when a raid starts.
##
## A map's loot is three tables the database keeps apart, and the client wants
## them as one flat array:
##
## - `locations.<map>.staticContainers` ??? the crates, safes and jackets that are
##   welded to the map. Each one carries the transform the level was built with,
##   and a probability that this particular crate exists at all this raid.
## - the **static loot distribution** for a container's own template ??? a pool of
##   item templates with relative weights, plus a distribution over *how many*
##   things are in it. Read from `loot.staticLoot`, with
##   `locations.<map>.staticLoot` accepted as well because databases dumped at
##   different times put it in different places.
## - `locations.<map>.looseLoot` ??? spawn points on the ground, each with a
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
##   no sights ??? the client draws it, and it is not a gun.
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
## addition to `emu/grid` ??? see the note at `packInto`.
##
## ## Determinism
##
## Every roll comes out of `emu/rand`, seeded from the raid id and the map name
## and nothing else. The same raid id against the same database produces the
## same floor down to the item ids, so "the crate by the gas station on raid
## 65f1a2??? was empty" is a reproducible statement rather than a story. This is
## the reason there is no ambient RNG in this project.
##
## ## With no tables at all
##
## Every read has a fallback and the fallback is always "nothing here". A
## database with no locations, no item table and no globals yields `[]` ??? an
## empty, well-formed loot list that loads and plays. That property is what
## makes a raid testable against the small fixture, and it is why nothing below
## is allowed to assume a table exists.
##
## ## Magazines
##
## A preset's magazine spawns **loaded**, from `locations.<map>.staticAmmo` ???
## the map's own weighted cartridge table, which was imported and read by
## nothing until this. The cartridge is the intersection of the weapon's
## `ammoCaliber` bucket and the magazine's own `Cartridges` filter, so it both
## fits the magazine and fires from the gun; a magazine with no intersection is
## left empty rather than filled with a guess. See `fillMagazine`.
##
## ## Not done here
##
## - **Spawn point clustering.** SPT thins loose loot by picking a target count
##   for the map and choosing points to hit it; here every point is rolled
##   independently against its own probability. The totals are close and the
##   distribution is flatter.

import std/strutils
import std/syncio
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
  ## `itemcountDistribution` ??? how many things are in this container. One when
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

proc effectiveSizeOf(d: LootDb; p: PresetIndex; tpl: string;
                     width, height: var int) =
  ## The footprint the CLIENT will compute for this item, which for a weapon is
  ## NOT its template's `Width`/`Height`.
  ##
  ## A weapon receiver is a 1x1 stub in `templates.items`; the gun the player
  ## sees is the receiver plus every mod the preset bolts on, and a barrel, a
  ## stock or a scope each declares how far past the receiver it sticks out.
  ## `packInto` reserved the stub, the client drew the whole gun, and the
  ## overflow landed on top of whatever was packed next -- "(x:0,y:0) in grid
  ## main in item barrel_cache is taken by another item".
  ##
  ## The rule, measured rather than remembered:
  ##
  ## - only a template with `MergesWithChildren` grows at all (2,226 of 4,673
  ##   in `build/db/db.json`),
  ## - a child WITHOUT `ExtraSizeForceAdd` contributes the MAXIMUM of its
  ##   `ExtraSize{Up,Down,Left,Right}` against the other children -- two mods
  ##   that each hang one cell below hang one cell below, not two,
  ##   (`ExtraSizeLeft` is non-zero on 340 templates, `Right` 153, `Down` 224,
  ##   `Up` 9)
  ## - a child WITH it contributes ADDITIVELY on top of that (120 templates,
  ##   e.g. `stock_ar15_colt_stock_tube`, the buffer tube every AR stock sits
  ##   on).
  ##
  ## Checked against real BSG placement, not against itself: in the captured
  ## player stash (`capture/raid1/responses/large/208.json`, one 10x30 grid,
  ## 105 items) a `weapon_colt_m4a1_556x45` -- template 1x1 -- sits at (0,14)
  ## with the next item on row 14 at x=5 and row 15 empty below it until row 16
  ## begins again at x=0. That hole is 5 wide and 2 tall. This rule answers
  ## 5x2. The second M4A1, rotated, at (6,19) abuts a backpack that starts at
  ## y=24 exactly five rows later. A width-only variant of the same rule
  ## (5x1) leaves row 15 unexplained, so the vertical term is measured too.
  ##
  ## Folding is NOT modelled, and does not need to be here: every `Foldable`
  ## in every one of the 399 `globals.ItemPresets` is `{"Folded": false}` (42
  ## occurrences, zero true), and `spawnItem` emits the root with no `upd`
  ## fold state at all, so the client computes the unfolded size -- which is
  ## what this returns. Should a folded preset ever appear, this over-states
  ## the footprint, and over-stating leaves a gap where under-stating throws
  ## `InventoryException`.
  sizeOf(d, tpl, width, height)
  let props = itemProps(d, tpl)
  if props.len == 0:
    return
  if not field(props, "MergesWithChildren").asBool(false):
    return
  let preset = presetFor(p, tpl)
  if preset.len == 0:
    return
  let list = parseArray(preset)
  if not list.ok or list.len < 2:
    return
  var maxUp = 0
  var maxDown = 0
  var maxLeft = 0
  var maxRight = 0
  var addUp = 0
  var addDown = 0
  var addLeft = 0
  var addRight = 0
  for i in 1 ..< list.len:
    let childTpl = field(list.items[i], "_tpl").asText("")
    let cp = itemProps(d, childTpl)
    if cp.len == 0:
      continue
    let j = whole(cp)
    let up = j.field("ExtraSizeUp").asInt(0)
    let down = j.field("ExtraSizeDown").asInt(0)
    let left = j.field("ExtraSizeLeft").asInt(0)
    let right = j.field("ExtraSizeRight").asInt(0)
    if j.field("ExtraSizeForceAdd").asBool(false):
      addUp = addUp + up
      addDown = addDown + down
      addLeft = addLeft + left
      addRight = addRight + right
    else:
      if up > maxUp: maxUp = up
      if down > maxDown: maxDown = down
      if left > maxLeft: maxLeft = left
      if right > maxRight: maxRight = right
  width = width + maxLeft + maxRight + addLeft + addRight
  height = height + maxUp + maxDown + addUp + addDown
  if width < 1: width = 1
  if height < 1: height = 1

# --- the map's ammunition --------------------------------------------------
#
# `locations.<map>.staticAmmo` is a per-map, per-caliber weighted list of
# cartridges:
#
#     "staticAmmo": { "Caliber762x39": [ {"tpl": "...", "relativeProbability":
#     12154}, ... ], ... }
#
# 28 calibers on most maps, 13 maps in an imported database. It was imported
# and read by nothing, and `docs/IMPORTDB.md` guessed it belonged in
# `expandAmmoBox`. It does not: **every one of the 213 ammo-box templates in a
# real `templates.items` has exactly one cartridge in its `StackSlots` filter**,
#
#     ammo box StackSlots filter sizes, build/db/db.json:  1 -> 213 (all of them)
#
# so the box's own filter is not a choice at all and a weighted pick over it
# would change nothing. Magazines are the other story:
#
#     magazine Cartridges filter sizes:  1 -> 3, 4 -> 9, 8 -> 29, 9 -> 51,
#                                        13 -> 33, ... up to 13+
#
# and `loot.nim` has carried "magazines are not filled -- doing it properly
# means resolving the weapon's caliber to `loot.staticAmmo`" as a stated gap
# since it was written. That is what this is.

type
  AmmoTable = object
    ## One map's `staticAmmo`, by caliber. Empty on a database that has none,
    ## which leaves every magazine empty -- the behaviour before this existed.
    calibers: seq[string]
    dists: seq[Distribution]

proc readAmmoTable(d: LootDb; locationId: string): AmmoTable =
  result = AmmoTable(calibers: @[], dists: @[])
  let root = sub(d, "locations." & locationId & ".staticAmmo")
  if root.len == 0:
    return
  let j = whole(root)
  if not isObject(j):
    return
  for k in keys(j):
    # Caliber keys carry no dots, so a one-step lookup is exact.
    let dist = readDistribution(raw(j.field(k)))
    if dist.keys.len == 0:
      continue
    result.calibers.add k
    result.dists.add dist

proc cartridgeFor(a: AmmoTable; caliber: string; allowed: JsonRef;
                  r: var Rng): string =
  ## A cartridge of `caliber` that this magazine will physically take, drawn
  ## with the map's own weights.
  ##
  ## The **intersection** is the whole safety property. `allowed` is the
  ## magazine's own `Cartridges[0]._props.filters[0].Filter`, so nothing that
  ## does not fit can come out of here however the map's table is weighted; the
  ## caliber bucket is what stops a magazine whose filter lists two calibers
  ## from being loaded with the one the gun does not fire. Either restriction
  ## alone is wrong, which is why both are applied.
  ##
  ## "" when the map has no bucket for this caliber, or when nothing in the
  ## bucket fits: the magazine is then left empty rather than filled with a
  ## guess. One weapon preset in a real database hits that (`Caliber9x18PMM`,
  ## which `bigmap`'s table does not carry) and 263 of the 264 do not.
  result = ""
  if caliber.len == 0 or not allowed.found:
    return
  var keep: seq[string] = @[]
  var weights: seq[float] = @[]
  for i in 0 ..< a.calibers.len:
    if a.calibers[i] != caliber:
      continue
    let dist = a.dists[i]
    for k in 0 ..< dist.keys.len:
      var fits = false
      for e in each(allowed):
        if e.asText("") == dist.keys[k]:
          fits = true
          break
      if fits:
        keep.add dist.keys[k]
        weights.add dist.weights[k]
  if keep.len == 0:
    return
  let pickAt = pickWeighted(r, weights)
  if pickAt < 0:
    return
  result = keep[pickAt]

proc fillMagazine(s: var ItemSink; d: LootDb; a: AmmoTable; r: var Rng;
                  magTpl, magId, caliber: string) =
  ## Loads one magazine, if the map's table and the magazine's filter agree on
  ## a cartridge.
  ##
  ## **How many** is `_max_count` -- the magazine's stated capacity, and the
  ## only round count anything in the database gives. The real game spawns
  ## partly-loaded magazines, and a fraction of capacity would be a constant
  ## nobody could check against anything: neither `globals.config` nor the
  ## reference dump says what it is (`grep` over `globals` finds
  ## `MagazineMalfChanceMult`, `EliteMagChanceReduceMult` and nothing about
  ## fill). So the magazine comes out full, which is generous in the player's
  ## favour and is a number that came from the database rather than from here.
  if caliber.len == 0:
    return
  let props = itemProps(d, magTpl)
  if props.len == 0:
    return
  let slots = field(props, "Cartridges")
  if not isArray(slots):
    return
  for slot in each(slots):
    let rounds = slot.field("_max_count").asInt(0)
    if rounds <= 0:
      continue
    let allowed = at(slot.field("_props.filters"), 0).field("Filter")
    let cartridge = cartridgeFor(a, caliber, allowed, r)
    if cartridge.len == 0:
      continue
    var doc = simpleItem(mongoId(r), cartridge)
    setText(doc, "parentId", magId)
    setText(doc, "slotId", slot.field("_name").asText("cartridges"))
    # One stack per `Cartridges` slot, so index 0 -- stated, not implied.
    # `bots.fillMagazine` already states it; an implied 0 is the same latent
    # defect `expandAmmoBox` shipped.
    setNumber(doc, "location", 0)
    var upd = newDoc()
    setNumber(upd, "StackObjectsCount", rounds)
    setRaw(doc, "upd", text(upd))
    s.emit text(doc)

proc expandPreset(s: var ItemSink; d: LootDb; a: AmmoTable; r: var Rng;
                  presetItems, rootId: string) =
  ## Every mod of a preset, re-parented onto `rootId` with fresh ids, and every
  ## magazine among them loaded from the map's `staticAmmo`.
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
  # The caliber comes from the *weapon* -- the preset's root -- because that is
  # the only thing in the tree that states one; a magazine states only what it
  # will physically hold, which is a different question on a mag that takes two.
  let rootTpl = field(list.items[0], "_tpl").asText("")
  let caliber = field(itemProps(d, rootTpl), "ammoCaliber").asText("")
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
    # And if that mod is a magazine, load it.
    fillMagazine(s, d, a, r, get(doc, "_tpl").asText(""), newIds[i], caliber)

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
    # `location` is MANDATORY here, and it is a bare integer -- not the
    # `{x,y,r}` object a grid child carries. A `StackSlot` addresses its
    # children by INDEX, and a child that omits `location` is read by the
    # client as index 0, so a 120-round box split into two 60-round stacks
    # threw exactly one `InventoryException` per box:
    #   "... at position 0 but the slot already contains item ... at this
    #    position."  (client log, Woods raid: six boxes, six exceptions)
    # Shape measured on the wire, capture/raid1/requests/204.json:
    #   {"slotId":"cartridges","location":0,"upd":{"StackObjectsCount":2},...}
    while total > 0 and guard < 64:
      var n2 = perStack
      if n2 > total: n2 = total
      var doc = simpleItem(mongoId(r), cartridge)
      setText(doc, "parentId", rootId)
      setText(doc, "slotId", slotName)
      setNumber(doc, "location", guard)
      var upd = newDoc()
      setNumber(upd, "StackObjectsCount", n2)
      setRaw(doc, "upd", text(upd))
      s.emit text(doc)
      total = total - n2
      produced = true
      inc guard
  result = produced

# --- one spawned item ------------------------------------------------------

proc spawnItem(s: var ItemSink; d: LootDb; p: PresetIndex; a: AmmoTable;
               r: var Rng;
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
      expandPreset(s, d, a, r, preset, id)
  result = id

# ---------------------------------------------------------------------------
# Filling a container
# ---------------------------------------------------------------------------

proc packInto(s: var ItemSink; d: LootDb; p: PresetIndex; a: AmmoTable;
              r: var Rng;
              grids: var seq[Cells]; containerId, tpl: string): bool =
  ## First fit across a container's grids, upright then rotated -- the same
  ## scan `emu/grid.findSpace` does, over sizes read through `LootDb`. False
  ## when there is nowhere left, which the caller must treat as "stop", not as
  ## "put it at 0,0": an overlapping item is drawn on top of another and neither
  ## can be picked up.
  var w = 1
  var h = 1
  effectiveSizeOf(d, p, tpl, w, h)
  for gi in 0 ..< grids.len:
    var y = 0
    while y < grids[gi].h:
      var x = 0
      while x < grids[gi].w:
        if fitsAt(grids[gi], x, y, w, h):
          occupy(grids[gi], x, y, w, h)
          discard spawnItem(s, d, p, a, r, tpl, containerId, grids[gi].name,
                            locationRaw(x, y, false))
          return true
        if w != h and fitsAt(grids[gi], x, y, h, w):
          occupy(grids[gi], x, y, h, w)
          discard spawnItem(s, d, p, a, r, tpl, containerId, grids[gi].name,
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
  ## `staticForced` ??? the items a specific crate always holds, quest items
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

proc staticContainers(d: LootDb; p: PresetIndex; a: AmmoTable; r: var Rng;
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
        discard packInto(sink, d, p, a, r, grids, containerId, tpl)

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
          if not packInto(sink, d, p, a, r, grids, containerId, tpl):
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

proc rootIdForKey(list: List; key: string): string =
  ## A drawn `itemDistribution` key, resolved to the `_id` of the item it names.
  ##
  ## The key is the candidate's **`composedKey`**, not its `_id`. Measured on
  ## sandbox's `looseLoot.json`: 1232 of 1232 spawn points carry a
  ## distribution, every drawn key matches some item's `composedKey`, and
  ## **none of them matches any `_id`** in the same point. Treating the key as
  ## an `_id` therefore selected an item that does not exist, `descendants`
  ## picked nothing, and every probabilistic loose spawn point on every map
  ## returned the empty string -- only `spawnpointsForced`, which carries no
  ## distribution at all, survived to the client.
  ##
  ## An `_id` is still accepted, because the static tables and older dumps key
  ## their distributions that way. A key that matches neither resolves to the
  ## empty string and the point spawns nothing -- never a fallback to the first
  ## candidate, because a wrong item on the floor is worse than a bare one.
  result = ""
  for i in 0 ..< list.len:
    let it = whole(list.items[i])
    var ck = it.field("composedKey").asText("")
    if ck.len == 0:
      ck = it.field("composedKey.key").asText("")
    if ck.len > 0 and ck == key:
      return it.field("_id").asText("")
  for i in 0 ..< list.len:
    let id = whole(list.items[i]).field("_id").asText("")
    if id == key:
      return id

proc looseSpawn(d: LootDb; p: PresetIndex; a: AmmoTable; r: var Rng;
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
    let id = rootIdForKey(list, k)
    if id.len == 0:
      return ""
    rootId = id

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
        expandPreset(sink, d, a, r, preset, newRoot)

  budget = budget - sink.items.len
  result = lootEntry(raw(tmpl), newRoot, itemsArray(sink))

proc parentDirOf(p: string): string =
  var i = p.len - 1
  while i >= 0 and p[i] != '/' and p[i] != '\\': dec i
  if i <= 0: return ""
  result = p.substr(0, i - 1)

proc looseSidecarDir*(): string =
  ## Where a map's `looseLoot` table lives when it is NOT in `db.json`.
  ##
  ## The whole of SPT's loose loot is 548 MiB minified -- lighthouse alone is
  ## 126 MiB -- so importing it turns a 39 MiB database into a 587 MiB one that
  ## the backend parses at every boot and holds resident for the life of the
  ## process, to read one map of it per raid. It ships as one file per map
  ## instead, read at raid start and dropped when the raid's loot is built.
  ##
  ## The default is `<install root>/looseloot`, derived the same way
  ## `capability` derives the registry: `modDir()` is `<root>/mods/<mod>`, so
  ## two steps up is the directory the backend loaded `db.json` from. A
  ## `looseLootDir` setting overrides it, because `--db` can point the backend
  ## at a database somewhere else entirely.
  result = setting("looseLootDir").asText("")
  if result.len > 0:
    return
  let md = modDir()
  if md.len == 0:
    return ""
  let mods = parentDirOf(md)
  if mods.len == 0:
    return ""
  let root = parentDirOf(mods)
  if root.len == 0:
    return ""
  result = root & "/looseloot"

proc readSidecar(locationId: string): string =
  ## One map's sidecar, or the empty string. Absent is not an error: a database
  ## imported with `--loose none` and no sidecars is a supported install, and
  ## it is the one that has shipped until now.
  result = ""
  let dir = looseSidecarDir()
  if dir.len == 0:
    return ""
  let path = dir & "/" & locationId & ".json"
  try:
    result = readFile(path)
  except:
    result = ""
  if result.len >= 3 and ord(result[0]) == 0xEF and ord(result[1]) == 0xBB and
     ord(result[2]) == 0xBF:
    result = result.substr(3, result.len - 1)

proc looseLoot(d: LootDb; p: PresetIndex; a: AmmoTable; r: var Rng;
               cfg: LootConfig;
               locationId: string; chanceMul: float;
               budget: var int): seq[string] =
  result = @[]
  # In the database first -- that is what the fixture and `--loose all` use, and
  # a sidecar must never shadow a table the operator deliberately imported.
  var root = sub(d, "locations." & locationId & ".looseLoot")
  if root.len == 0:
    root = readSidecar(locationId)
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
      let e = looseSpawn(d, p, a, r, pt, budget)
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
    let e = looseSpawn(d, p, a, r, pt, budget)
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
  # The map's own cartridge table, read once. Threaded rather than held in a
  # module variable: two raids on two maps can be generated at the same time,
  # and a shared one would load a Woods magazine out of Factory's table.
  let ammo = readAmmoTable(d, locationId)
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
  let statics = staticContainers(d, p, ammo, r, cfg, locationId, containerMul,
                                 staticBudget)
  for e in statics:
    out1.add e
  # `staticBudget` is what that pass did *not* spend, so the sum of the two
  # halves is still exactly `maxItems`.
  var looseBudget = budget - staticShare + staticBudget
  let loose = looseLoot(d, p, ammo, r, cfg, locationId, looseMul, looseBudget)
  for e in loose:
    out1.add e
  result = text(out1)

proc lootFor*(locationId, raidId: string): string =
  ## What `emu/raid` calls: the loaded database, the mod's config, one line.
  ##
  ## With no loot tables present every read inside returns nothing and this
  ## returns `[]` -- a valid, empty floor. A raid on the test fixture starts.
  ##
  ## An empty floor is VALID and it is also the shape of every way this can go
  ## wrong -- a map id that resolves to nothing, a rebuild from a base that
  ## predates the id fix, `lootEnabled` off, `maxLootItems` at zero. All four
  ## used to be the same silent `[]`, served in a few milliseconds with nothing
  ## anywhere saying which. Ten of thirteen maps were empty for a day on
  ## exactly that silence. So: an empty answer NAMES ITS REASON, once per
  ## raid, and the reason is read off the finished state rather than assumed.
  let d = liveDb()
  let cfg = lootConfig()
  result = generateLoot(d, cfg, locationId, raidId)
  if result.len > 2:
    return
  if not cfg.enabled:
    warn "loot: " & locationId & " served NO loot because `lootEnabled` is " &
         "false in this mod's config.json"
    return
  if cfg.maxItems <= 0:
    warn "loot: " & locationId & " served NO loot because `maxLootItems` is " &
         $cfg.maxItems & " in this mod's config.json"
    return
  let base = sub(d, "locations." & locationId & ".base")
  if base.len == 0:
    warn "loot: " & locationId & " served NO loot -- the database has no " &
         "`locations." & locationId & "` at all, so the raid's map id was " &
         "not resolved to a database location. This is what an id-mapping " &
         "regression looks like, not an empty map."
    return
  let statics = sub(d, "locations." & locationId & ".staticContainers")
  let loose = sub(d, "locations." & locationId & ".looseLoot")
  let side = readSidecar(locationId)
  if statics.len == 0 and loose.len == 0 and side.len == 0:
    warn "loot: " & locationId & " served NO loot -- the location IS in the " &
         "database but carries no staticContainers and no looseLoot, and " &
         "there is no sidecar at " & looseSidecarDir() & "/" & locationId &
         ".json. Import loot for this map, or expect a bare floor."
    return
  warn "loot: " & locationId & " served NO loot even though its tables are " &
       "present (staticContainers " & $statics.len & " bytes, looseLoot " &
       $loose.len & " bytes, sidecar " & $side.len & " bytes). Every spawn " &
       "was refused -- check staticLootMultiplier/looseLootMultiplier and " &
       "the map's own chance modifiers."

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
      "staticAmmo": {
        "TestCaliber": [
          { "tpl": "aaaaammo0000000000000001", "relativeProbability": 1000 }
        ],
        "OtherCaliber": [
          { "tpl": "zzzzammo0000000000000009", "relativeProbability": 1000 }
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
        "itemcountDistribution": [ { "count": 3, "relativeProbability": 1 } ],
        "itemDistribution": [
          { "tpl": "aaaaammo0000000000000001", "relativeProbability": 5 },
          { "tpl": "bbbbbox00000000000000002", "relativeProbability": 5 },
          { "tpl": "wwwwgun00000000000000001", "relativeProbability": 40 }
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
            "parentId": "r0000000000000000000000r", "slotId": "mod_magazine" },
          { "_id": "b0000000000000000000000b", "_tpl": "bbbbbrl00000000000000001",
            "parentId": "r0000000000000000000000r", "slotId": "mod_barrel" },
          { "_id": "s0000000000000000000000s", "_tpl": "sssstck00000000000000001",
            "parentId": "r0000000000000000000000r", "slotId": "mod_stock" }
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
          "Grids": [ { "_name": "main", "_props": { "cellsH": 8, "cellsV": 4 } } ]
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
        "_props": { "Name": "Test rifle", "Width": 1, "Height": 1, "StackMaxSize": 1,
                    "MergesWithChildren": true,
                    "ammoCaliber": "TestCaliber" }
      },
      "bbbbbrl00000000000000001": {
        "_id": "bbbbbrl00000000000000001",
        "_props": { "Name": "Test barrel", "Width": 2, "Height": 1, "StackMaxSize": 1,
                    "ExtraSizeLeft": 2, "ExtraSizeForceAdd": false }
      },
      "sssstck00000000000000001": {
        "_id": "sssstck00000000000000001",
        "_props": { "Name": "Test buffer tube", "Width": 1, "Height": 1, "StackMaxSize": 1,
                    "ExtraSizeRight": 1, "ExtraSizeForceAdd": true }
      },
      "mmmmmag00000000000000001": {
        "_id": "mmmmmag00000000000000001",
        "_props": { "Name": "Test magazine", "Width": 1, "Height": 1, "StackMaxSize": 1,
          "ExtraSizeDown": 1,
          "Cartridges": [
            {
              "_name": "cartridges",
              "_max_count": 30,
              "_props": { "filters": [ { "Filter": [ "aaaaammo0000000000000001",
                                                     "zzzzammo0000000000000009" ] } ] }
            }
          ]
        }
      },
      "zzzzammo0000000000000009": {
        "_id": "zzzzammo0000000000000009",
        "_props": { "Name": "Wrong-caliber cartridge", "Width": 1, "Height": 1,
                    "StackMaxSize": 60 }
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

proc scanAddresses*(payload: string; collisions: var int;
                    firstCollision: var string; boxesSeen: var int) =
  ## NO TWO CHILDREN OF ONE PARENT MAY SHARE ONE (slotId, location).
  ##
  ## An item's address inside its parent is (slotId, location). Two children at
  ## one address is an `EFT.InventoryException` at load, and one of the two is
  ## dropped:
  ##   "... to slot StackSlot cartridges in item item_ammo_box_545x39_120_T
  ##    at position 0 but the slot already contains item ... at this position."
  ##
  ## Stated as a property of the FINISHED payload rather than of any one
  ## generator, so it catches ammo boxes, magazines, grids and presets alike.
  ##
  ## An ABSENT `location` normalises to `"0"`, and that is the whole point: the
  ## client defaults it, so two stacks that both omit it are two stacks at
  ## position 0 -- which is the bug. A key that gave "absent" a value of its own
  ## would pass over the exact defect it was written to catch.
  ##
  ## The two shapes are kept distinct because they are not interchangeable on
  ## the wire: a grid child carries `{"x","y","r"}` and a `StackSlot` child
  ## carries a bare integer (measured, capture/raid1/requests/204.json), and
  ## Newtonsoft throws on the mismatch.
  let spots = parseArray(payload)
  for i in 0 ..< spots.len:
    let e = whole(spots.items[i])
    let inside = parseArray(e.field("Items"))
    var seen: seq[string] = @[]
    for k in 0 ..< inside.len:
      let it = whole(inside.items[k])
      if it.field("_tpl").asText("") == "bbbbbox00000000000000002":
        inc boxesSeen
      let parent = it.field("parentId").asText("")
      let slot = it.field("slotId").asText("")
      if parent.len == 0 or slot.len == 0:
        continue
      let loc = it.field("location")
      var pos = "0"
      if loc.found:
        if loc.field("x").found:
          pos = "g" & $loc.field("x").asInt(-1) & "," &
                $loc.field("y").asInt(-1) & "," & loc.field("r").asText("")
        else:
          pos = $loc.asInt(-1)
      let slotAddr = parent & "|" & slot & "|" & pos
      var dup = false
      for n in 0 ..< seen.len:
        if seen[n] == slotAddr:
          dup = true
      if dup:
        inc collisions
        if firstCollision.len == 0:
          firstCollision = slotAddr
      seen.add slotAddr

proc scanCells*(d: LootDb; payload: string; overlaps: var int;
                firstOverlap: var string; gridItems: var int;
                modded: var int; placed: var string) =
  ## NO TWO ITEMS IN A GRID MAY OCCUPY OVERLAPPING CELLS, where each item's
  ## footprint is the one the CLIENT computes -- template size PLUS whatever
  ## its attached mods add.
  ##
  ## This is deliberately not "no two items START in the same cell", which is
  ## the weaker claim the check above it makes and which a 5x2 rifle reserved
  ## as 1x1 walks straight through: the two rifles in the Woods `barrel_cache`
  ## had different origins and still landed on top of each other.
  ##
  ## It reads the footprint off the FINISHED payload -- the children actually
  ## emitted, found by `parentId` -- and not off `PresetIndex`. That is the
  ## point: if it asked the same preset table `packInto` asked, it would be
  ## comparing the generator against itself and could not fail. Here the input
  ## that makes it fail is exactly the one that made the client throw.
  ##
  ## `modded` is the denominator and must be asserted separately: a payload
  ## with no multi-cell weapon in it satisfies this vacuously.
  let spots = parseArray(payload)
  for i in 0 ..< spots.len:
    let e = whole(spots.items[i])
    let inside = parseArray(e.field("Items"))
    var ids: seq[string] = @[]
    var tpls: seq[string] = @[]
    var parents: seq[string] = @[]
    for k in 0 ..< inside.len:
      let it = whole(inside.items[k])
      ids.add it.field("_id").asText("")
      tpls.add it.field("_tpl").asText("")
      parents.add it.field("parentId").asText("")
    # occupied cells, keyed by grid
    var cellGrid: seq[string] = @[]
    var cellX: seq[int] = @[]
    var cellY: seq[int] = @[]
    var cellBy: seq[string] = @[]
    for k in 0 ..< inside.len:
      let it = whole(inside.items[k])
      let loc = it.field("location")
      if not loc.found or not loc.field("x").found:
        continue
      let tpl = tpls[k]
      var w = 1
      var h = 1
      sizeOf(d, tpl, w, h)
      let bareW = w
      let bareH = h
      let props = itemProps(d, tpl)
      if props.len > 0 and field(props, "MergesWithChildren").asBool(false):
        # every descendant of this item, gathered from the payload itself
        var frontier: seq[string] = @[ids[k]]
        var maxUp = 0
        var maxDown = 0
        var maxLeft = 0
        var maxRight = 0
        var addUp = 0
        var addDown = 0
        var addLeft = 0
        var addRight = 0
        var guard = 0
        while frontier.len > 0 and guard < 4096:
          inc guard
          let cur = frontier[frontier.len - 1]
          frontier.setLen(frontier.len - 1)
          for n in 0 ..< ids.len:
            if parents[n] != cur:
              continue
            frontier.add ids[n]
            let cp = itemProps(d, tpls[n])
            if cp.len == 0:
              continue
            let j = whole(cp)
            let up = j.field("ExtraSizeUp").asInt(0)
            let down = j.field("ExtraSizeDown").asInt(0)
            let left = j.field("ExtraSizeLeft").asInt(0)
            let right = j.field("ExtraSizeRight").asInt(0)
            if j.field("ExtraSizeForceAdd").asBool(false):
              addUp = addUp + up
              addDown = addDown + down
              addLeft = addLeft + left
              addRight = addRight + right
            else:
              if up > maxUp: maxUp = up
              if down > maxDown: maxDown = down
              if left > maxLeft: maxLeft = left
              if right > maxRight: maxRight = right
        w = w + maxLeft + maxRight + addLeft + addRight
        h = h + maxUp + maxDown + addUp + addDown
      if w < 1: w = 1
      if h < 1: h = 1
      if w != bareW or h != bareH:
        inc modded
      inc gridItems
      if placed.len < 400:
        placed.add tpl & ":" & $bareW & "x" & $bareH & "->" & $w & "x" & $h & " "
      if loc.field("r").asText("") == "Vertical":
        let t = w
        w = h
        h = t
      let grid = parents[k] & "|" & it.field("slotId").asText("")
      let x0 = loc.field("x").asInt(-1)
      let y0 = loc.field("y").asInt(-1)
      var yy = y0
      while yy < y0 + h:
        var xx = x0
        while xx < x0 + w:
          for n in 0 ..< cellX.len:
            if cellGrid[n] == grid and cellX[n] == xx and cellY[n] == yy:
              inc overlaps
              if firstOverlap.len == 0:
                firstOverlap = grid & " cell (" & $xx & "," & $yy & ") " &
                               tpls[k] & " " & $w & "x" & $h &
                               " over " & cellBy[n]
          cellGrid.add grid
          cellX.add xx
          cellY.add yy
          cellBy.add tpls[k]
          inc xx
        inc yy

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
  #
  # GRID children only, and keyed by the grid they are in. This check used to
  # take every item with a `location` and compare `x`/`y` defaulted to -1,
  # which meant it also compared items that have no cell at all -- a
  # `StackSlot` child carries a bare integer, so both its `x` and its `y` read
  # -1 and two cartridge stacks in one box looked like two items in one cell.
  # It only ever passed because those stacks were emitted with no `location`
  # field at all, which was itself the bug. Scoping it is what makes it a
  # statement about cells rather than about the shape of a JSON value.
  var overlapFree = true
  for i in 0 ..< entries.len:
    let e = whole(entries.items[i])
    let inside = parseArray(e.field("Items"))
    var owners: seq[string] = @[]
    var xs: seq[int] = @[]
    var ys: seq[int] = @[]
    for k in 0 ..< inside.len:
      let it = whole(inside.items[k])
      let loc = it.field("location")
      if not loc.found or not loc.field("x").found:
        continue
      let owner = it.field("parentId").asText("") & "|" &
                  it.field("slotId").asText("")
      let x = loc.field("x").asInt(-1)
      let y = loc.field("y").asInt(-1)
      for n in 0 ..< xs.len:
        if owners[n] == owner and xs[n] == x and ys[n] == y:
          overlapFree = false
      owners.add owner
      xs.add x
      ys.add y
  check(result, overlapFree, "no two items start in the same cell")

  # And the stronger claim the one above cannot make: no two items in a grid
  # OVERLAP, footprints computed the way the client computes them. The fixture
  # rifle is a 1x1 template that a 2-cell barrel, a forced-add buffer tube and
  # a magazine grow to 4x2 -- the same shape as a real M4A1 -- and the crate is
  # 8x4, so two of them fit side by side and only side by side. Sized off the
  # bare template they are both placed within one cell of the origin.
  var cellOverlaps = 0
  var firstCellOverlap = ""
  var gridPlaced = 0
  var grownPlaced = 0
  var placedSample = ""
  scanCells(d, a, cellOverlaps, firstCellOverlap, gridPlaced, grownPlaced,
            placedSample)
  scanCells(d, c, cellOverlaps, firstCellOverlap, gridPlaced, grownPlaced,
            placedSample)
  check(result, grownPlaced > 0,
        "a weapon whose mods grow it past its template was placed at all" &
        " (grid-placed " & $gridPlaced & ", grown " & $grownPlaced & "): " &
        placedSample)
  check(result, cellOverlaps == 0,
        "no two items in a grid overlap, mod extensions included" &
        (if cellOverlaps == 0: "" else: " -- " & firstCellOverlap))

  # A weapon arrives with its preset expanded.
  check(result, countOccurrences(a, "mmmmmag00000000000000001") >= 1,
        "the rifle spawned with its magazine")
  check(result, countOccurrences(a, "\"r0000000000000000000000r\"") == 0,
        "the preset's own ids were replaced")

  # -- the magazine is loaded, out of `staticAmmo` -------------------------
  #
  # Asserted through the *parentage*, not by counting a template: the fixture's
  # static pool spawns the same cartridge on its own, so a check that only
  # counted `aaaaammo...` would be green with `fillMagazine` deleted.
  var magRounds = -1
  var magCartridge = ""
  for i in 0 ..< entries.len:
    let inside = parseArray(whole(entries.items[i]).field("Items"))
    var magIds: seq[string] = @[]
    for k in 0 ..< inside.len:
      let it = whole(inside.items[k])
      if it.field("_tpl").asText("") == "mmmmmag00000000000000001":
        magIds.add it.field("_id").asText("")
    for k in 0 ..< inside.len:
      let it = whole(inside.items[k])
      for m in magIds:
        if m.len > 0 and it.field("parentId").asText("") == m:
          magCartridge = it.field("_tpl").asText("")
          magRounds = it.field("upd.StackObjectsCount").asInt(-1)
  check(result, magCartridge == "aaaaammo0000000000000001",
        "the magazine is loaded with a cartridge of the weapon's own caliber")
  check(result, magRounds == 30,
        "and with the magazine's stated capacity, from `_max_count`")
  check(result, countOccurrences(a, "zzzzammo0000000000000009") == 0,
        "the other caliber in the same filter is never loaded")

  # And the source of it. With `staticAmmo` taken out of the document and
  # nothing else changed, the magazine has to come back empty -- which is what
  # makes the two checks above claims about the table rather than about the
  # magazine's own filter.
  var stripped = ""
  var si = 0
  let marker = "\"staticAmmo\""
  while si < document.len:
    if si + marker.len <= document.len and
       document.substr(si, si + marker.len - 1) == marker:
      stripped.add "\"notStaticAmmo\""
      si = si + marker.len
    else:
      stripped.add document[si]
      inc si
  let noAmmo = generateLoot(textDb(stripped), cfg, "testmap", "raid-one")
  var loadedWithout = false
  let noEntries = parseArray(noAmmo)
  for i in 0 ..< noEntries.len:
    let inside = parseArray(whole(noEntries.items[i]).field("Items"))
    var magIds: seq[string] = @[]
    for k in 0 ..< inside.len:
      let it = whole(inside.items[k])
      if it.field("_tpl").asText("") == "mmmmmag00000000000000001":
        magIds.add it.field("_id").asText("")
    for k in 0 ..< inside.len:
      let it = whole(inside.items[k])
      for m in magIds:
        if m.len > 0 and it.field("parentId").asText("") == m:
          loadedWithout = true
  check(result, noEntries.len >= 3 and not loadedWithout,
        "with no `staticAmmo` table the magazine spawns empty")

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

  # -- THE NEGATIVE ---------------------------------------------------------
  # Three different floors, because one seed is not a property.
  var collisions = 0
  var firstCollision = ""
  var boxesSeen = 0
  scanAddresses(a, collisions, firstCollision, boxesSeen)
  scanAddresses(c, collisions, firstCollision, boxesSeen)
  scanAddresses(big, collisions, firstCollision, boxesSeen)
  # The denominator first: the check below is vacuously green on a floor with
  # no multi-stack container in it at all. The fixture's ammo box holds 100
  # rounds of a cartridge that stacks to 60, so every one that spawns splits
  # into two stacks -- which is what makes the check falsifiable. It FAILS on
  # the generator as it stood before the `location` fix.
  check(result, boxesSeen > 0,
        "the fixture spawned a multi-stack ammo box to check against")
  check(result, collisions == 0,
        "no container holds two items at the same (slotId, location)")

proc selfCheck*(): string = selfCheck(Fixture)
