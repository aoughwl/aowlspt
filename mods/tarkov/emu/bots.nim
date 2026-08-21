## Bots.
##
## `/client/game/bot/generate` is the client asking for a batch of AI profiles
## before a raid: a role, a difficulty, and how many. What it gets back is a
## profile per bot in the same shape as a player's — id, info, health,
## inventory, skills — because the client makes no distinction. That is the
## whole trick of it: a bot is a profile with `Info.Settings.Role` set.
##
## The database supplies the *content* (`bots.types.<role>`: the appearance,
## loadout tables, health ranges, names) and this supplies the assembly. With no
## bot data present a raid still starts, populated by bots wearing nothing —
## which is a strange raid and a working one, and is a great deal better than a
## client that cannot enter a raid at all.
##
## The one thing done carefully here is **cost**. Generating a batch is the
## largest single body the server builds in a session, and it happens at the
## worst possible moment: the player is staring at a loading screen. So the
## per-bot work is a handful of lookups and one string build, the loadout tables
## are read once per batch rather than once per bot, and the item table is
## touched twice per weapon rather than walked.
##
## ## The bots used to spawn naked
##
## This read three things out of `bots.types.<role>` -- `firstName`,
## `health.BodyParts[0]` and the first entry of each `appearance` list -- and
## nothing else. Not `inventory`, not `chances`, not `difficulty`. Every bot in
## every raid therefore had exactly two items: an equipment container and a
## stash, both empty.
##
## That is not a cosmetic gap, it is the difference between a faction existing
## and a faction being a set of names. A mod shipping seven loadout files, 322
## equipment ids across 58 slots, 642 mod roots with 2,122 references and 91
## ammo entries across 34 calibers had all of it land in the database correctly
## and none of it reach a single spawned bot.
##
## ## The bot is built on `bots.base`, and why that is the right call
##
## `bots/base.json` -- 2,241 bytes, imported to `bots.base` -- is SPT's own bot
## profile *skeleton*: the document every generated bot starts life as a copy
## of, before a role's tables fill anything in. This module used to build that
## skeleton out of literals instead, and the two did not agree. Read off the
## real file and off the client's own type rather than reasoned about, the
## disagreements were:
##
## - **`Customization.Voice` was missing, and the voice that was sent was in a
##   field that does not exist.** The base carries
##   `Customization: {Head, Body, Feet, Hands, Voice}`, with `Voice` a template
##   id (`67b877e7d2dc6a01d5059dd9`). This module wrote `Voice: "Bear_1"` into
##   `Info` -- and `Info` on the client's `BotBase`
##   (`reference/spt-4.1-surface.txt`) has no `Voice` member at all, while
##   `Customization.Voice` is there as `Nullable<MongoId>`. So every bot shipped
##   a voice the client cannot read, under a name it does not know, and nothing
##   at all under the name it does. `"Bear_1"` is not a MongoId either; voices
##   became template ids in this generation of the game.
## - **`Stats.Eft` was `{}`** and is a populated structure in the base:
##   `Victims`, `DamageHistory` (with `LethalDamagePart`), `SessionCounters`,
##   `SurvivorClass`.
## - `Health.Immortal`, `Hideout`, `Variables` and fifteen members of `Info`
##   (`LowerNickname`, `PrestigeLevel`, `BannedState`, `SavageLockTime`,
##   `NeedWipeOptions`, ...) had no counterpart here at all.
##
## So the profile is now **started from `bots.base` and overwritten**, which is
## the order SPT itself builds one in, rather than assembled from scratch and
## hoping the list of members is complete. It costs one cached `dbRead` of 2 KB
## per server run.
##
## The reason to do it rather than document the divergence is not the list of
## missing members -- it is that **the appearance fix needs a source for the
## default**. A role whose weight table is empty, or all zeroes, has to fall
## back to *something*, and the only honest something is the skeleton the real
## server falls back to. Writing four ids into this file and calling them a
## default is the invention the house rules forbid; reading them out of SPT's
## own base is not. The two fixes are therefore one fix.
##
## One disagreement is resolved the other way, and it is the rule about the
## client's type winning: **`WishList` is `[]` in `base.json` and `{}` here.**
## `BotBase.WishList` is `Dictionary<MongoId, Int32>`, so an array is the shape
## that is wrong, and `{}` is written over whatever the base says. `Encyclopedia`
## is `null` in the base and `{}` here for the same reason -- the type is a
## dictionary, and an empty one is a thing the client can enumerate. Everything
## the base carries *more* of than this module computes is kept.
##
## ## Two more shapes this module used to read wrongly on a real database
##
## Both found while establishing the above, and both invisible to `emutest`
## because `tests/fixtures/emu-full.json` is written in the shape this code
## expected rather than the shape the game ships:
##
## - `appearance.head`, `.body`, `.feet` and `.hands` are **weight maps**
##   (`{tpl: weight}`) in SPT 4.x, not lists -- 280 names and five weighted
##   appearance tables in `bots/types/assault.json`. `appearanceOf` read them
##   with `at(..., 0)`, and `at` requires a `[`, so on a real database all four
##   missed and **every bot in every raid wore the same four hardcoded ids**.
##   That is the "same hat" failure the note under `equipmentSlots` warns about,
##   one level up from where it was fixed. `appearance.voice` is a fifth weight
##   map and was not read at all.
## - `health.BodyParts` is a **list of variants**, and each part inside one is
##   `{min, max}`. `healthOf` tested `isObject` and then took `at(h, 0)`, so on
##   a real database the test failed and every bot got the literal full-health
##   human below -- 35/85/65, when `assault` in a stock database says 30/80/60.
##   Splicing a variant in raw would not fix it: the client reads
##   `{Health: {Current, Maximum}}` and the table says `{min, max}`, so a roll
##   between the two is what is done rather than a splice. `Hydration`, `Energy`
##   and `Temperature` are the same shape one level up, and `Temperature` is the
##   one range that is not degenerate in stock data (36..40 for a scav, 36.6..40
##   for a PMC), so it is the one a player could actually see.
##
## ## What the loadout is built from, and against what
##
## The shapes below were read off a real 41 MB database produced by
## `aowl importdb`, not off a fixture, because this is precisely the kind of
## code a fixture written by the same person as the code cannot check. Three of
## them would have been guessed wrong:
##
## - the chance tables are `chances.equipment`, `chances.weaponMods` and
##   `chances.equipmentMods` -- **not** a single `chances.mods`;
## - a mod slot name appears in **either casing** in stock data (`Helmet_top` on
##   59 items, `helmet_top` on 3), so a chance looked up by exact key silently
##   misses and the slot falls back to its default;
## - `inventory.equipment` has exactly the 14 slots the game has, and the value
##   under each is a **weight map** of template id to weight, not a list.
##
## A weight of zero means "never", and there are plenty: `Earpiece` is 0 for a
## plain scav and `SecondPrimaryWeapon` is 0 for nearly everything. So a slot
## whose chance is zero is skipped without a roll, and a pool whose weights sum
## to zero produces nothing rather than the first entry -- spawning element zero
## of an empty distribution is how every scav on a map ends up in the same hat.
##
## Everything is drawn from a generator seeded by the **bot own id**, which is
## itself a counter: the third scav of a batch is the same third scav every time
## the same server run generates that batch, which is what makes "the bot with
## the broken rifle" a thing that can be looked at rather than guessed at.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import numbers
import ids
import rand
import templates
import grid

type
  BotRequest* = object
    role*: string
    difficulty*: string
    count*: int

  BotTables* = object
    ## The database rows for one role, read once and reused for every bot in the
    ## batch. Reading them per bot turns a 20-bot request into 20 walks of the
    ## bot table, which is exactly the kind of cost that only shows up on
    ## someone else's machine.
    ok*: bool
    role*: string
    raw*: string

const
  MaxModDepth = 5
    ## How deep a mod tree is followed. Five is past every real weapon (a scope
    ## on a mount on a rail on a receiver on a weapon) and is a bound rather
    ## than a limit: a database with a cycle in `inventory.mods` -- a mod whose
    ## own mod list names its parent -- would otherwise build items until the
    ## server ran out of memory, and nothing in the data forbids one.
  MaxLootPerBot = 24
    ## How many loose items a bot may be carrying. The real weight tables top
    ## out at six in a backpack, four in pockets and six in a rig, so this is a
    ## bound on a pathological table rather than a limit on a real one.
  MaxWeaponModsPerBot = 60
    ## The other half of the same bound, and it is two numbers rather than one
    ## for the reason the flea's offer cap is shared between the traders and the
    ## handbook: **a single budget spent in slot order is not a bound on a bot,
    ## it is a preference for whatever the slot list happens to name first.**
    ##
    ## The 14 slots are walked in the order the game writes them, which puts
    ## Headwear, the armour and the rig ahead of every weapon -- so armour that
    ## carries eight plates and a helmet with six attachments could spend the
    ## whole allowance before `FirstPrimaryWeapon` was reached, and the loop
    ## stopped there: a bot with no gun at all, from data that says nothing of
    ## the sort. Two budgets means the plates can only ever cost the plates.
    ##
    ## 60 for the weapons: a fully kitted rifle is about 20 items, and this
    ## leaves room for two of them, a sidearm and a knife.
  MaxGearModsPerBot = 36
    ## And 36 for everything worn, which covers armour plates in every slot a
    ## real vest has plus a helmet with its full set of attachments. The two
    ## together are the 96 one bot used to be allowed, split rather than
    ## raised -- nothing here is a licence to build a bigger bot.

proc equipmentSlots(): seq[string] =
  ## The 14 slots the game has, in the order the real database writes them.
  ##
  ## Written out rather than taken from whatever keys `inventory.equipment`
  ## happens to have, so that a database naming a fifteenth cannot put an item
  ## in a slot the client has nowhere to draw -- which renders as a bot holding
  ## nothing and reads as this generator having failed.
  result = @["Headwear", "Earpiece", "FaceCover", "ArmorVest", "Eyewear",
             "ArmBand", "TacticalVest", "Backpack", "FirstPrimaryWeapon",
             "SecondPrimaryWeapon", "Holster", "Scabbard", "Pockets",
             "SecuredContainer"]

proc isWeaponSlot(slot: string): bool =
  ## Which of the 14 hold something whose mods come from `chances.weaponMods`
  ## rather than `chances.equipmentMods`. `Scabbard` is a knife and takes
  ## neither, but it has no mods either, so it costs nothing to call it a
  ## weapon here.
  case slot
  of "FirstPrimaryWeapon", "SecondPrimaryWeapon", "Holster", "Scabbard": true
  else: false

proc memberCI(j: JsonRef; name: string): JsonRef =
  ## A member, matched case-insensitively when an exact match fails.
  ##
  ## This exists because of one measured fact: in a stock database the mod slot
  ## `Helmet_top` appears on 59 items and `helmet_top` on 3. A chance table
  ## keyed one way and a mod table keyed the other means the chance is not
  ## found, the default is used, and a slot that should almost never be filled
  ## is filled every time -- with no error anywhere. The exact match is tried
  ## first so the common case costs nothing extra.
  result = j.field(name)
  if result.found:
    return
  result = notFound()
  if not j.found or not isObject(j):
    return
  let wanted = toLowerAscii(name)
  let names = keys(j)
  for k in names:
    if toLowerAscii(k) == wanted:
      return j.field(k)

proc chanceFor(chances: JsonRef; group, slot: string; fallback: int): int =
  ## The percentage chance a slot is filled. `fallback` when the table says
  ## nothing, because a database that does not mention a slot has not said
  ## "never" -- it has said nothing, and the required slots of a weapon are
  ## exactly the ones no chance table bothers to list.
  let g = chances.field(group)
  if not g.found:
    return fallback
  let v = memberCI(g, slot)
  if not v.found:
    return fallback
  result = v.asInt(fallback)

proc pickTemplate(pool: JsonRef; r: var Rng): string =
  ## One template id out of a weight map, in proportion to its weight.
  ##
  ## Returns "" when the pool is empty or every weight in it is zero, and the
  ## caller must be able to tell that from a pick -- a zero-weight entry means
  ## "this role does not use this", and there are a great many of them.
  result = ""
  if not pool.found or not isObject(pool):
    return
  let entries = members(pool)
  var names: seq[string] = @[]
  var weights: seq[float] = @[]
  for m in entries:
    let w = whole(m.value).asFloat(0.0)
    if w <= 0.0:
      continue
    names.add m.name
    weights.add w
  let at1 = pickWeighted(r, weights)
  if at1 < 0:
    return
  result = names[at1]

proc botItem(id, tpl, parent, slot: string): Doc =
  result = newDoc()
  setText(result, "_id", id)
  setText(result, "_tpl", tpl)
  setText(result, "parentId", parent)
  setText(result, "slotId", slot)

proc magazineCapacity(tpl: string): int =
  ## `_props.Cartridges[0]._max_count` -- how many rounds a magazine holds.
  ## Zero when the item table does not say, which means no rounds are put in it
  ## rather than a guessed number: a magazine claiming a capacity it does not
  ## have is a bot whose gun jams on the client.
  let v = dbRead("templates.items." & tpl & "._props.Cartridges")
  if not v.ok:
    return 0
  let first = at(whole(v.raw), 0)
  if not first.found:
    return 0
  result = first.field("_max_count").asInt(0)

proc weaponCaliber(tpl: string): string =
  let v = dbRead("templates.items." & tpl & "._props.ammoCaliber")
  if not v.ok:
    return ""
  result = v.asText()

proc fillMagazine(inv: JsonRef; items: var List; magId, magTpl, caliber: string;
                  r: var Rng) =
  ## Puts rounds in a magazine, drawn from `inventory.Ammo.<caliber>`.
  ##
  ## Silent when the caliber is unknown, the pool is empty or the capacity is
  ## not in the item table. An empty magazine is a bot that fires once and then
  ## does not; a magazine full of the wrong caliber is a bot the client refuses
  ## to spawn, and of the two only the first is recoverable by the player
  ## shooting it.
  if caliber.len == 0 or magTpl.len == 0:
    return
  let capacity = magazineCapacity(magTpl)
  if capacity <= 0:
    return
  let pool = inv.field("Ammo").field(caliber)
  let ammo = pickTemplate(pool, r)
  if ammo.len == 0:
    return
  var d = botItem(newId(), ammo, magId, "cartridges")
  setNumber(d, "location", 0)
  var upd = newDoc()
  setNumber(upd, "StackObjectsCount", capacity)
  setRaw(d, "upd", text(upd))
  items.add d

proc addMods(t: BotTables; inv, chances: JsonRef; items: var List;
             rootId, rootTpl: string; weapon: bool; r: var Rng;
             budget: var int) =
  ## The mod tree under one piece of equipment, resolved breadth-first.
  ##
  ## An explicit stack rather than recursion, and a depth *and* a count bound on
  ## it, because `inventory.mods` is data: a table whose mod list names its own
  ## parent is a loop, and a generator that trusts its input to be acyclic is a
  ## generator one bad row away from hanging the server at the moment a player
  ## presses "ready".
  let modTable = inv.field("mods")
  if not modTable.found:
    return
  let group = if weapon: "weaponMods" else: "equipmentMods"
  let caliber = if weapon: weaponCaliber(rootTpl) else: ""

  var ids: seq[string] = @[]
  var tpls: seq[string] = @[]
  var depths: seq[int] = @[]
  ids.add rootId
  tpls.add rootTpl
  depths.add 0
  var head = 0
  while head < ids.len:
    let parentId = ids[head]
    let parentTpl = tpls[head]
    let depth = depths[head]
    inc head
    if depth >= MaxModDepth:
      continue
    let slots = modTable.field(parentTpl)
    if not slots.found or not isObject(slots):
      continue
    let named = keys(slots)
    for slotName in named:
      if budget <= 0:
        return
      let pool = slots.field(slotName)
      let n = count(pool)
      if n <= 0:
        continue
      # A required slot is one no chance table lists, and it is filled. A slot
      # the table gives a zero to is never filled and is not rolled for.
      let pct = chanceFor(chances, group, slotName, 100)
      if pct <= 0:
        continue
      if pct < 100 and not chance(r, float(pct) / 100.0):
        continue
      let tpl = at(pool, nextInt(r, n)).asText("")
      if tpl.len == 0:
        continue
      let modId = newId()
      items.add botItem(modId, tpl, parentId, slotName)
      dec budget
      if toLowerAscii(slotName) == "mod_magazine":
        fillMagazine(inv, items, modId, tpl, caliber, r)
        dec budget
      ids.add modId
      tpls.add tpl
      depths.add depth + 1

# ---------------------------------------------------------------------------
# What the bot is carrying, as opposed to wearing
#
# `inventory.equipment` above dresses the bot. This is the other half:
# `inventory.items` -- a pool per container of what may be *in* it -- and
# `generation.items.<kind>.weights`, a map of "how many" to how likely that many
# is. Between them they are the reason a raid's rewards were thinner than the
# real game's: a scav you killed had a rig and a rifle and nothing whatever in
# its pockets.
#
# Both shapes were read off a real 41 MB database rather than off a fixture:
#
# - `inventory.items` has one member per container slot -- `TacticalVest`,
#   `Pockets`, `Backpack`, `SecuredContainer`, `SpecialLoot` -- and each is a
#   **weight map** of template id to weight, exactly like `inventory.equipment`.
#   A plain scav's `Backpack` pool has 1,851 entries in it.
# - `generation.items` has one member per *kind* of thing --  `backpackLoot`,
#   `pocketLoot`, `vestLoot`, `magazines`, `grenades`, `healing`, `drugs`,
#   `stims`, `food`, `drink`, `currency`, `specialItems` -- and each is
#   `{weights: {"0": 1, "1": 6, ...}, whitelist: []}`, where the *key* is a
#   count and the value is its weight. A weight on "0" is common and means "no
#   items of this kind", which is why a count is drawn rather than assumed.
#
# **Three of the twelve kinds are generated and nine are not, and the reason is
# the same for all nine.** `backpackLoot`, `pocketLoot` and `vestLoot` name a
# container, and the container has a pool in `inventory.items` under the same
# name -- so the count and the pool it applies to are both in the data. The
# other nine name a *category* of item: `healing` is "how many medical items",
# `grenades` is "how many throwables". Nothing in the database says which
# templates those are. It is the item's base class -- `_parent`, walked up the
# template tree to one of a set of well-known class ids -- and the set is the
# real server's source code, not its data. Generating them would mean writing
# that table of ids out here from memory, which is exactly the kind of guess
# that reads as data and is not.
#
# `SecuredContainer` and `SpecialLoot` have pools and **no** count kind naming
# them, so they are left empty for the mirror-image reason: the data says what
# may go in and never says how much.
# ---------------------------------------------------------------------------

type
  Container = object
    ## One equipped container a bot may be carrying loot in, with an occupancy
    ## map per grid. A rig has four grids of one or two cells; a `location`
    ## written without checking them puts two items in the same cell, which the
    ## client draws on top of each other and the player cannot pick up -- the
    ## same failure `emu/grid` exists to prevent in the player's own stash.
    id: string
    slot: string
    gridNames: seq[string]
    grids: seq[Grid]

proc openContainer(id, slot, tpl: string): Container =
  result = Container(id: id, slot: slot, gridNames: @[], grids: @[])
  let props = dbRead("templates.items." & tpl & "._props.Grids")
  if not props.ok:
    return
  let list = each(whole(props.raw))
  for g in list:
    let w = g.field("_props.cellsH").asInt(0)
    let h = g.field("_props.cellsV").asInt(0)
    if w <= 0 or h <= 0:
      continue
    result.gridNames.add g.field("_name").asText("main")
    result.grids.add newGrid(w, h)

proc placeIn(c: var Container; tpl: string; gridName: var string;
             location: var string): bool =
  ## First grid the item fits in, first fit within it. False when the whole
  ## container is full, which is a refusal and not a licence to write a
  ## location that overlaps something.
  gridName = ""
  location = ""
  var w = 1
  var h = 1
  itemSize(tpl, w, h)
  for i in 0 ..< c.grids.len:
    let spot = findSpace(c.grids[i], tpl)
    if not spot.ok:
      continue
    if spot.rotated:
      occupy(c.grids[i], spot.x, spot.y, h, w)
    else:
      occupy(c.grids[i], spot.x, spot.y, w, h)
    gridName = c.gridNames[i]
    location = locationJson(spot)
    return true
  result = false

proc drawCount(generation: JsonRef; kind: string; r: var Rng): int =
  ## How many of this kind go in, out of `generation.items.<kind>.weights`.
  ##
  ## Zero when the table says nothing -- a role with no `generation` block has
  ## not said "as many as you like", it has said nothing, and the honest reading
  ## of nothing is none.
  let weights = generation.field("items").field(kind).field("weights")
  if not weights.found or not isObject(weights):
    return 0
  let picked = pickTemplate(weights, r)
  if picked.len == 0:
    return 0
  # The key is the count. A key that is not a number is a table this generator
  # cannot read, and reading it as zero is the answer that adds nothing rather
  # than the one that adds something arbitrary.
  result = 0
  for ch in picked:
    if ch < '0' or ch > '9':
      return 0
    result = result * 10 + (ord(ch) - ord('0'))
  if result < 0:
    result = 0

proc addContainerLoot(inv, generation: JsonRef; items: var List;
                      c: var Container; kind: string; r: var Rng;
                      budget: var int) =
  ## Fills one equipped container from its own pool.
  let pool = inv.field("items").field(c.slot)
  if not pool.found or not isObject(pool):
    return
  var wanted = drawCount(generation, kind, r)
  if wanted <= 0:
    return
  # The same bound the mod tree has, and for the same reason: `generation` is
  # data, and a table naming a hundred would otherwise make one bot the size of
  # a raid.
  if wanted > budget:
    wanted = budget
  var placed = 0
  var tries = 0
  while placed < wanted and tries < wanted * 4:
    inc tries
    let tpl = pickTemplate(pool, r)
    if tpl.len == 0:
      return
    var gridName = ""
    var location = ""
    if not placeIn(c, tpl, gridName, location):
      # Full. Stopping rather than trying smaller items: a container that has
      # no room for the item drawn has very little for the next one, and the
      # loop above is already bounded.
      return
    var d = botItem(newId(), tpl, c.id, gridName)
    setRaw(d, "location", location)
    # One of the thing, and no `StackObjectsCount`. The pool gives template ids
    # and no counts, and `generation.items.<kind>` counts *items* rather than
    # rounds or roubles -- so a stack size here would be this file's invention.
    items.add d
    inc placed
    dec budget

proc addLoadout(t: BotTables; items: var List; equipmentId: string;
                r: var Rng) =
  ## Everything the bot is wearing and carrying, slot by slot.
  if not t.ok:
    return
  let inv = field(t.raw, "inventory")
  if not inv.found:
    return
  let chances = field(t.raw, "chances")
  let equipment = inv.field("equipment")
  if not equipment.found:
    return
  var weaponBudget = MaxWeaponModsPerBot
  var gearBudget = MaxGearModsPerBot
  let slots = equipmentSlots()
  # The containers that got filled, remembered as they are placed: loot goes in
  # after every slot is decided, because a bot's rig has to *exist* before there
  # is anywhere to put anything, and the equipment roll is what decides that.
  var carried: seq[Container] = @[]
  for slot in slots:
    let pool = equipment.field(slot)
    if not pool.found:
      continue
    let pct = chanceFor(chances, "equipment", slot, 100)
    if pct <= 0:
      continue
    if pct < 100 and not chance(r, float(pct) / 100.0):
      continue
    let tpl = pickTemplate(pool, r)
    if tpl.len == 0:
      continue
    # The worn item itself is never refused for want of a mod budget. There are
    # fourteen of these and the list is written out above, so they are bounded
    # by their own count -- it was the mod tree that needed bounding, and gating
    # the slot on it is what turned "this helmet has a lot of attachments" into
    # "this bot has no rifle".
    let itemId = newId()
    items.add botItem(itemId, tpl, equipmentId, slot)
    if slot == "TacticalVest" or slot == "Pockets" or slot == "Backpack":
      carried.add openContainer(itemId, slot, tpl)
    if isWeaponSlot(slot):
      addMods(t, inv, chances, items, itemId, tpl, true, r, weaponBudget)
    else:
      addMods(t, inv, chances, items, itemId, tpl, false, r, gearBudget)

  # And what is in them. A separate budget from the mod tree's: a bot with a
  # heavily modded rifle should still have something in its pockets, and one
  # bound shared between the two makes the loot the thing that gets dropped.
  let generation = field(t.raw, "generation")
  if not generation.found:
    return
  # And the same rule a third time: the containers are filled in slot order --
  # rig, then pack, then pockets -- and one budget between them meant a
  # generous `vestLoot` table left the pockets empty. Each container gets an
  # even share of what is left when its turn comes, so the first cannot spend
  # the last one's, and whatever it does not use passes on.
  var lootBudget = MaxLootPerBot
  for i in 0 ..< carried.len:
    if lootBudget <= 0:
      break
    var c = carried[i]
    let kind = case c.slot
               of "TacticalVest": "vestLoot"
               of "Pockets": "pocketLoot"
               else: "backpackLoot"
    var share = lootBudget div (carried.len - i)
    if share < 1:
      share = 1
    let had = share
    addContainerLoot(inv, generation, items, c, kind, r, share)
    lootBudget = lootBudget - (had - share)

proc difficultyOf*(role, difficulty: string): string =
  ## `bots.types.<role>.difficulty.<difficulty>`, or `bots.core` when the role
  ## or the difficulty is not in the database.
  ##
  ## The route behind this used to answer `bots.core` whatever it was asked,
  ## which is one set of brain settings for every bot on every map -- so a mod
  ## shipping per-role difficulty had it read out of the database correctly and
  ## then never used. `bots.core` remains the fallback because it is the shape
  ## the client parses and every role either overrides it or does not.
  let v = dbRead("bots.types." & toLowerAscii(role) & ".difficulty." &
                 toLowerAscii(difficulty))
  if v.ok and v.raw.len > 0:
    return v.raw
  let core = dbRead("bots.core")
  if core.ok and core.raw.len > 0:
    return core.raw
  result = "{}"

proc parseRequests*(body: string): seq[BotRequest] =
  ## The client sends `{"conditions":[{"Role":..,"Limit":..,"Difficulty":..}]}`.
  result = @[]
  let conds = each(field(body, "conditions"))
  for c in conds:
    var n = c.field("Limit").asInt(1)
    if n < 1: n = 1
    # A single request asking for hundreds is either a mistake or a client
    # trying it on; capped rather than honoured, because the body it would
    # produce is measured in tens of megabytes.
    if n > 64: n = 64
    result.add BotRequest(role: c.field("Role").asText("assault"),
                          difficulty: c.field("Difficulty").asText("normal"),
                          count: n)

proc loadTables*(role: string): BotTables =
  let v = dbRead("bots.types." & toLowerAscii(role))
  if v.ok and v.raw.len > 0:
    return BotTables(ok: true, role: role, raw: v.raw)
  result = BotTables(ok: false, role: role, raw: "")

proc pickName(t: BotTables; index: int): string =
  ## A name from the role's own list, chosen by position rather than at random.
  ## Deterministic on purpose: when a raid goes wrong, "the third scav" is a
  ## thing that can be looked up.
  if not t.ok:
    return t.role & "_" & $index
  let names = field(t.raw, "firstName")
  let n = count(names)
  if n == 0:
    return t.role & "_" & $index
  result = at(names, index mod n).asText(t.role & "_" & $index)

proc pickFromPool(pool: JsonRef; r: var Rng): string =
  ## One template id out of a pool written either way round.
  ##
  ## SPT 4.x writes `appearance.head` and its four siblings as **weight maps**
  ## -- `{tpl: weight}`, exactly like `inventory.equipment` -- and that is the
  ## shape `pickTemplate` reads. An array is accepted as well, drawn uniformly,
  ## and the reason is worth stating because it looks like laxity and is not:
  ## the failure mode of refusing an array here is *not* a refusal. It is the
  ## default id being used for every bot on the map, silently, which is the
  ## precise defect this proc exists to fix. Reading a shape that is present
  ## costs one branch; ignoring it costs a raid full of identical scavs.
  ##
  ## Returns "" when the pool is absent, empty, or every weight in it is zero.
  ## The caller must be able to tell that from a pick.
  if not pool.found:
    return ""
  if isArray(pool):
    let n = count(pool)
    if n <= 0:
      return ""
    return at(pool, nextInt(r, n)).asText("")
  result = pickTemplate(pool, r)

proc rolledRange(v: JsonRef; r: var Rng; fallbackLo, fallbackHi: float;
                 whole1: bool): string =
  ## `{min, max}` out of the database as the `{Current, Maximum}` the client
  ## reads.
  ##
  ## `Maximum` is the table's `max` rather than the roll: `max` is the ceiling
  ## the role declares, and a bot whose *maximum* health was randomly lowered is
  ## a bot a bandage cannot bring back to what its own table says it has.
  ## `Current` is drawn in `[min, max]`, which on stock data is a point for
  ## every body part (all 434 of them have `min == max`) and a real range for
  ## `Temperature`.
  var lo = fallbackLo
  var hi = fallbackHi
  if v.found:
    lo = v.field("min").asFloat(fallbackLo)
    hi = v.field("max").asFloat(fallbackHi)
  # A table with `max` below `min` is a table this cannot read as a range; the
  # floor is taken rather than a negative span being rolled over.
  if hi < lo:
    hi = lo
  var cur = lo
  if hi > lo:
    cur = lo + nextFloat(r) * (hi - lo)
  if whole1:
    cur = float(int(cur + 0.5))
    hi = float(int(hi + 0.5))
  result = "{\"Current\":" & numText(cur) & ",\"Maximum\":" & numText(hi) & "}"

proc bodyPartsOf(h: JsonRef; r: var Rng; into: var Doc): bool =
  ## One rolled set of body parts out of `health.BodyParts`.
  ##
  ## The table is a **list of variants** -- a scav has three, most roles have
  ## one -- and each variant is a map of part name to `{min, max}`. A variant is
  ## drawn uniformly (the list carries no weights) and every part in it rolled.
  ##
  ## False when nothing usable came out, and false is a refusal of the *whole*
  ## table rather than of one part: a body with six parts is a bot the client
  ## cannot spawn, so a table this cannot read entirely is one it does not read
  ## at all, and the caller falls back to a complete human.
  let bp = h.field("BodyParts")
  if not bp.found:
    return false
  var variant = bp
  if isArray(bp):
    let n = count(bp)
    if n <= 0:
      return false
    variant = at(bp, nextInt(r, n))
  if not variant.found or not isObject(variant):
    return false
  let named = keys(variant)
  if named.len == 0:
    return false
  for partName in named:
    let pv = variant.field(partName)
    let already = pv.field("Health")
    if already.found:
      # Already in the client's shape. Passed through rather than re-rolled --
      # a database written by hand may well say `{Health: {...}}` outright, and
      # rewriting it would be this file overriding what the data said.
      setRaw(into, partName, raw(pv))
      continue
    if not pv.field("max").found and not pv.field("min").found:
      return false
    setRaw(into, partName, "{\"Health\":" & rolledRange(pv, r, 0.0, 0.0, true) & "}")
  # Every part the client reads by name has to be there. A partial table is
  # refused whole, because half a body is worse than a default one: the client
  # spawns neither, and only one of the two says so in a log.
  let wanted = @["Head", "Chest", "Stomach", "LeftArm", "RightArm",
                 "LeftLeg", "RightLeg"]
  for w in wanted:
    if not has(into, w):
      return false
  result = true

proc healthOf(t: BotTables; base: string; r: var Rng): string =
  ## The role's health, rolled, on top of whatever `bots.base` says about the
  ## members this does not compute (`Immortal`, and `UpdateTime` when the base
  ## carries one).
  var health = parseObject(field(base, "Health"))
  var parts = newDoc()
  var fromTable = false
  if t.ok:
    let h = field(t.raw, "health")
    if h.found:
      fromTable = bodyPartsOf(h, r, parts)
      if fromTable:
        setRaw(health, "Hydration",
               rolledRange(h.field("Hydration"), r, 100.0, 100.0, true))
        setRaw(health, "Energy",
               rolledRange(h.field("Energy"), r, 100.0, 100.0, true))
        setRaw(health, "Temperature",
               rolledRange(h.field("Temperature"), r, 36.0, 40.0, false))
  if not fromTable:
    # A full-health human, for a role with no readable health table at all --
    # and these seven numbers are the one thing in this file that is neither in
    # the database nor in the client's type. They are a stock PMC's, they are
    # here because a profile with no `BodyParts` is a bot the client will not
    # spawn, and they are reached only when the role says nothing: every role in
    # a real database says something, and what it says is what is used. A
    # database that ships a *partial* body reaches this too, whole, rather than
    # having the missing legs filled in around what it did say.
    parts = newDoc()
    setRaw(parts, "Head", "{\"Health\":{\"Current\":35,\"Maximum\":35}}")
    setRaw(parts, "Chest", "{\"Health\":{\"Current\":85,\"Maximum\":85}}")
    setRaw(parts, "Stomach", "{\"Health\":{\"Current\":70,\"Maximum\":70}}")
    setRaw(parts, "LeftArm", "{\"Health\":{\"Current\":60,\"Maximum\":60}}")
    setRaw(parts, "RightArm", "{\"Health\":{\"Current\":60,\"Maximum\":60}}")
    setRaw(parts, "LeftLeg", "{\"Health\":{\"Current\":65,\"Maximum\":65}}")
    setRaw(parts, "RightLeg", "{\"Health\":{\"Current\":65,\"Maximum\":65}}")
    setRaw(health, "Hydration", "{\"Current\":100,\"Maximum\":100}")
    setRaw(health, "Energy", "{\"Current\":100,\"Maximum\":100}")
    setRaw(health, "Temperature", "{\"Current\":36,\"Maximum\":40}")
  setRaw(health, "BodyParts", text(parts))
  if not has(health, "UpdateTime"):
    setRaw(health, "UpdateTime", "0")
  result = text(health)

proc appearanceOf(t: BotTables; base: string; r: var Rng): string =
  ## `Customization` -- the four worn appearance ids and the voice.
  ##
  ## Three sources in order, and the order is the whole point: the role's own
  ## weighted table, then `bots.base.Customization`, then the ids below. The
  ## last of the three is the only one this file invents, it is reached only by
  ## a database that carries neither a role table nor a base, and it exists so
  ## that a bot on such a database is dressed rather than transparent.
  var c = parseObject(field(base, "Customization"))
  if not has(c, "Head"): setRaw(c, "Head", "\"5cc084dd14c02e000b0550a3\"")
  if not has(c, "Body"): setRaw(c, "Body", "\"5cde95ef7d6c8b04713c4f2d\"")
  if not has(c, "Feet"): setRaw(c, "Feet", "\"5cde95d97d6c8b647a3769b0\"")
  if not has(c, "Hands"): setRaw(c, "Hands", "\"5cc0876314c02e000c6bea6b\"")
  if t.ok:
    let a = field(t.raw, "appearance")
    if a.found:
      let head = pickFromPool(a.field("head"), r)
      if head.len > 0: setText(c, "Head", head)
      let body = pickFromPool(a.field("body"), r)
      if body.len > 0: setText(c, "Body", body)
      let feet = pickFromPool(a.field("feet"), r)
      if feet.len > 0: setText(c, "Feet", feet)
      let hands = pickFromPool(a.field("hands"), r)
      if hands.len > 0: setText(c, "Hands", hands)
      # The fifth table, and the one that was never read. `Customization.Voice`
      # is `Nullable<MongoId>` on the client's own type; `Info.Voice` is not a
      # member of anything, which is where the voice used to go.
      let voice = pickFromPool(a.field("voice"), r)
      if voice.len > 0: setText(c, "Voice", voice)
  result = text(c)

var gBotBase = ""
var gBotBaseRead = false

proc botBase*(): string =
  ## `bots.base`, read once per server run.
  ##
  ## SPT's own bot profile skeleton -- 2 KB -- and the document every generated
  ## bot starts life as a copy of. Cached because a 20-bot batch would otherwise
  ## walk the database for it 20 times at the worst possible moment, and it
  ## cannot change under a running server.
  ##
  ## "" when the database has no such entry, which is a real case: a small
  ## fixture carries `bots.types` and no base. Everything below therefore has to
  ## work with an empty skeleton, and the only difference it makes is that the
  ## members SPT ships and this module does not compute are absent.
  if not gBotBaseRead:
    gBotBaseRead = true
    let v = dbRead("bots.base")
    if v.ok and v.raw.len > 0 and isObject(whole(v.raw)):
      gBotBase = v.raw
  result = gBotBase

proc generateProfile*(t: BotTables; base: string; req: BotRequest;
                      index: int): string =
  ## One bot, as a copy of `base` with everything this module computes written
  ## over it. `base` is passed in rather than read here so that the whole of
  ## this is a pure function of its arguments -- which is what lets
  ## `selfCheckBots` run it.
  let id = newId()
  let equipment = newId()
  let stash = newId()

  # Three generators rather than one, each seeded from the bot's own id and a
  # name. The id is a counter, so a batch is still reproducible; the split is so
  # that adding one draw to the loadout does not repaint every bot in the game,
  # which would make "the scav in the red hat" stop meaning anything across a
  # change to an unrelated table.
  var ra = seededRng(id & ":appearance")
  var rh = seededRng(id & ":health")
  var r = seededRng(id)

  var settings = parseObject(field(base, "Info.Settings"))
  setText(settings, "Role", req.role)
  setText(settings, "BotDifficulty", req.difficulty)
  setNumber(settings, "Experience", 0)
  # `experience.standingForKill` and `experience.aggressorBonus` are keyed by
  # difficulty in a real database -- `{"easy":-0.03,"normal":-0.04,...}` -- so
  # the requested difficulty is what picks the row. Zero when the role does not
  # carry them, which is what a bot worth no reputation looks like.
  setRaw(settings, "StandingForKill",
         numText(field(t.raw, "experience.standingForKill." &
                       toLowerAscii(req.difficulty)).asFloat(0.0)))
  setRaw(settings, "AggressorBonus",
         numText(field(t.raw, "experience.aggressorBonus." &
                       toLowerAscii(req.difficulty)).asFloat(0.0)))

  var info = parseObject(field(base, "Info"))
  setText(info, "Nickname", pickName(t, index))
  # Side follows the role. A PMC role MUST carry a PMC side or the client's
  # boss-spawn scenario (which is how SPT injects PMCs -- a `BossLocationSpawn`
  # with `BossName`=`pmcBEAR`/`pmcUSEC`) refuses to place it: a profile that says
  # `Role=pmcUSEC` but `Side=Savage` is self-contradictory and the bot is
  # generated into the pool but never instantiated. `pmcBEAR`/`pmcbot` are BEAR,
  # `pmcUSEC` is USEC, everything else (assault, marksman, bosses, followers) is
  # `Savage`.
  let roleLc = toLowerAscii(req.role)
  setText(info, "Side",
          if roleLc == "pmcbear" or roleLc == "pmcbot": "Bear"
          elif roleLc == "pmcusec": "Usec"
          else: "Savage")
  # **Not `Voice`.** `Info` on the client's `BotBase` has no such member; the
  # voice is a `Nullable<MongoId>` on `Customization` and is written there.
  # Removed rather than merely not written, so that a base carrying the old
  # spelling cannot reintroduce it.
  remove(info, "Voice")
  setNumber(info, "Level", 1)
  setNumber(info, "Experience", 0)
  setNumber(info, "RegistrationDate", 0)
  setText(info, "GameVersion", "standard")
  setNumber(info, "AccountType", 0)
  setNumber(info, "MemberCategory", 0)
  setRaw(info, "Settings", text(settings))
  setRaw(info, "Bans", "[]")

  # The two containers a profile must have, even one that is never opened: the
  # client walks `Inventory.items` for the ids named beside it and a bot with a
  # dangling equipment id does not spawn.
  var items = newList()
  var eq = newDoc()
  setText(eq, "_id", equipment)
  setText(eq, "_tpl", "55d7217a4bdc2d86028b456d")
  items.add eq
  var st = newDoc()
  setText(st, "_id", stash)
  setText(st, "_tpl", "566abbc34bdc2d92178b4576")
  items.add st

  # And what it is wearing.
  addLoadout(t, items, equipment, r)

  var inventory = parseObject(field(base, "Inventory"))
  setRaw(inventory, "items", text(items))
  setText(inventory, "equipment", equipment)
  setText(inventory, "stash", stash)
  setText(inventory, "questRaidItems", "")
  setText(inventory, "questStashItems", "")
  setText(inventory, "sortingTable", "")
  if not has(inventory, "hideoutAreaStashes"):
    setRaw(inventory, "hideoutAreaStashes", "{}")
  if not has(inventory, "fastPanel"):
    setRaw(inventory, "fastPanel", "{}")
  if not has(inventory, "favoriteItems"):
    setRaw(inventory, "favoriteItems", "[]")

  var skills = parseObject(field(base, "Skills"))
  if not has(skills, "Common"): setRaw(skills, "Common", "[]")
  if not has(skills, "Mastering"): setRaw(skills, "Mastering", "[]")
  if not has(skills, "Points"): setRaw(skills, "Points", "0")

  # The skeleton, with everything computed above written over it. Members the
  # base carries and this does not compute -- `Health.Immortal`, `Hideout`,
  # `Variables`, `Stats.Eft`, and the fifteen `Info` members SPT ships -- are
  # kept exactly as they came, which is the whole reason for starting here.
  var p = parseObject(base)
  setText(p, "_id", id)
  setNumber(p, "aid", accountIdOf(id))
  setRaw(p, "savage", "null")
  setRaw(p, "Info", text(info))
  setRaw(p, "Customization", appearanceOf(t, base, ra))
  setRaw(p, "Health", healthOf(t, base, rh))
  setRaw(p, "Inventory", text(inventory))
  setRaw(p, "Skills", text(skills))
  # `Stats` only when the base has none. The base's `Stats.Eft` is a populated
  # structure -- `DamageHistory.LethalDamagePart`, `SurvivorClass`, the two
  # counter sets -- and `{Eft: {}}` written over it would be this file removing
  # members the client's own type declares.
  if not has(p, "Stats"):
    setRaw(p, "Stats", "{\"Eft\":{}}")
  # These three go the other way, and the rule is the one at the top of this
  # file: where the database and the client's declared type disagree, the type
  # wins. `BotBase.WishList` is `Dictionary<MongoId, Int32>` and `base.json`
  # says `[]`; `Encyclopedia` is `Dictionary<MongoId, Boolean>` and the base
  # says `null`. An empty map is what both of those are.
  setRaw(p, "Encyclopedia", "{}")
  setRaw(p, "WishList", "{}")
  if not has(p, "TaskConditionCounters"):
    setRaw(p, "TaskConditionCounters", "{}")
  if not has(p, "InsuredItems"):
    setRaw(p, "InsuredItems", "[]")
  if not has(p, "Bonuses"):
    setRaw(p, "Bonuses", "[]")
  # And the five the base does not carry at all. Every one is a member of
  # `BotBase`, and every one is read by the client on a profile it is given.
  setRaw(p, "Notes", "{\"Notes\":[]}")
  setRaw(p, "Quests", "[]")
  setRaw(p, "RagfairInfo", "{}")
  setRaw(p, "TradersInfo", "{}")
  setRaw(p, "UnlockedInfo", "{\"unlockedProductionRecipe\":[]}")
  result = text(p)

proc generateOne*(t: BotTables; req: BotRequest; index: int): string =
  result = generateProfile(t, botBase(), req, index)

proc generate*(body: string; generated: var int): string =
  ## The whole batch, as the array the client expects.
  generated = 0
  var out1 = arr()
  let requests = parseRequests(body)
  # Once for the batch, not once per bot: the same reason the role's tables are
  # read once. It is cached either way, and a cache hit still copies 2 KB.
  let base = botBase()
  for req in requests:
    let tables = loadTables(req.role)
    var i = 0
    while i < req.count:
      out1.add raw(generateProfile(tables, base, req, i))
      inc generated
      inc i
  result = done(out1).text

# ---------------------------------------------------------------------------
# The check
# ---------------------------------------------------------------------------

const ChkRole = """{
  "firstName": ["Chk"],
  "appearance": {
    "head": {"aaaaaaaaaaaaaaaaaaaaaa01": 5,
             "aaaaaaaaaaaaaaaaaaaaaa02": 5,
             "aaaaaaaaaaaaaaaaaaaaaa03": 0},
    "body": {"bbbbbbbbbbbbbbbbbbbbbb01": 1},
    "feet": {"ffffffffffffffffffffff01": 0,
             "ffffffffffffffffffffff02": 0},
    "hands": {"hhhhhhhhhhhhhhhhhhhhhh01": 1},
    "voice": {"vvvvvvvvvvvvvvvvvvvvvv01": 3,
              "vvvvvvvvvvvvvvvvvvvvvv02": 0}
  },
  "health": {
    "Hydration": {"min": 100, "max": 100},
    "Energy": {"min": 100, "max": 100},
    "Temperature": {"min": 36, "max": 40},
    "BodyParts": [
      {"Head": {"min": 30, "max": 30}, "Chest": {"min": 80, "max": 80},
       "Stomach": {"min": 70, "max": 70}, "LeftArm": {"min": 60, "max": 60},
       "RightArm": {"min": 60, "max": 60}, "LeftLeg": {"min": 50, "max": 70},
       "RightLeg": {"min": 60, "max": 60}},
      {"Head": {"min": 45, "max": 45}, "Chest": {"min": 85, "max": 85},
       "Stomach": {"min": 70, "max": 70}, "LeftArm": {"min": 60, "max": 60},
       "RightArm": {"min": 60, "max": 60}, "LeftLeg": {"min": 50, "max": 70},
       "RightLeg": {"min": 60, "max": 60}}
    ]
  }
}"""
  ## A role table in the shape a **real** database writes one, which is the
  ## whole reason this check exists: `tests/fixtures/emu-full.json` writes the
  ## appearance tables as arrays and carries no `health` at all, so every defect
  ## this file was fixed for was invisible from `emutest` by construction.
  ##
  ## Three things are deliberate. `head` carries a zero-weight entry, so "a
  ## weight of zero means never" is checkable. `feet` is *entirely* zero, so
  ## "a pool that sums to zero produces nothing rather than element zero" is
  ## checkable -- that one is the same-hat failure, and element zero of a
  ## degenerate distribution is exactly how a map ends up in one. And
  ## `BodyParts` has two variants and one part with a real range in it, so the
  ## roll can be told from a splice.

const ChkBase = """{
  "_id": "60dc8576337fdf54e60e1800",
  "aid": 0,
  "savage": null,
  "Info": {"Nickname": "BOTNAME", "LowerNickname": "", "Side": "Savage",
           "Level": 1, "SavageLockTime": 0, "BannedState": false,
           "NeedWipeOptions": [], "PrestigeLevel": 0,
           "Settings": {"Role": "assault", "BotDifficulty": "normal",
                        "Experience": -1, "UseSimpleAnimator": false}},
  "Customization": {"Head": "ccccccccccccccccccccc001",
                    "Body": "ccccccccccccccccccccc002",
                    "Feet": "ccccccccccccccccccccc003",
                    "Hands": "ccccccccccccccccccccc004",
                    "Voice": "ccccccccccccccccccccc005"},
  "Health": {"UpdateTime": 0, "Immortal": false},
  "Inventory": {"fastPanel": {}, "hideoutAreaStashes": {},
                "favoriteItems": []},
  "Skills": {"Common": [], "Mastering": [], "Points": 0},
  "Stats": {"Eft": {"Victims": [], "SurvivorClass": "Unknown",
                    "DamageHistory": {"LethalDamagePart": "Head"}}},
  "Encyclopedia": null,
  "TaskConditionCounters": {},
  "InsuredItems": [],
  "Hideout": null,
  "Bonuses": [],
  "WishList": [],
  "Variables": {}
}"""
  ## `bots/base.json`, cut to the members the checks below name, and keeping
  ## every one whose *shape* is the point: `WishList` as an array,
  ## `Encyclopedia` as null, `Customization.Voice` as a template id, and a
  ## populated `Stats.Eft`.

proc distinctCount(xs: seq[string]): int =
  var seen: seq[string] = @[]
  for x in xs:
    var have = false
    for s in seen:
      if s == x:
        have = true
    if not have:
      seen.add x
  result = seen.len

proc selfCheckBots*(into: var seq[string]): bool =
  ## Pure, over the two literals above. True when it added nothing.
  ##
  ## No database half, and that is a decision rather than an omission. The
  ## database-shaped assertions worth making about bots -- that every one of a
  ## real install's 57 roles names all seven body parts, that its five
  ## appearance tables are weight maps -- would make this server *refuse to
  ## load* on a database whose bot tables a mod had touched. A gate that fatal
  ## belongs over this file's own arithmetic, which no input can work around,
  ## and not over somebody else's data. Those checks want `realtest`, which
  ## runs against a real database and reports rather than refuses.
  let before = into.len
  let t = BotTables(ok: true, role: "assault", raw: ChkRole)
  let req = BotRequest(role: "assault", difficulty: "normal", count: 1)

  # Twenty-four bots rather than one. Every defect this checks for is a defect
  # of *sameness*, and one sample cannot see one.
  var heads: seq[string] = @[]
  var voices: seq[string] = @[]
  var feet: seq[string] = @[]
  var headHp: seq[string] = @[]
  var legLow = 1000.0
  var legHigh = -1000.0
  var tempLow = 1000.0
  var tempHigh = -1000.0
  var i = 0
  while i < 24:
    let p = generateProfile(t, ChkBase, req, i)
    let c = field(p, "Customization")
    heads.add c.field("Head").asText("")
    voices.add c.field("Voice").asText("")
    feet.add c.field("Feet").asText("")
    let parts = field(p, "Health.BodyParts")
    headHp.add numText(parts.field("Head.Health.Current").asFloat(-1.0))
    let leg = parts.field("LeftLeg.Health.Current").asFloat(-1.0)
    if leg < legLow: legLow = leg
    if leg > legHigh: legHigh = leg
    let temp = field(p, "Health.Temperature.Current").asFloat(-1.0)
    if temp < tempLow: tempLow = temp
    if temp > tempHigh: tempHigh = temp
    inc i

  # 1. The appearance tables are weight maps, and they are read.
  let headKinds = distinctCount(heads)
  if headKinds < 2:
    into.add "bots: 24 bots drew " & $headKinds & " distinct head(s) from a " &
             "two-entry weighted table -- the appearance pool is not being " &
             "read, which is every bot in every raid in the same hat"
  # One line per defect rather than one per sample: 24 copies of the same
  # sentence is a failure report nobody reads to the end of.
  var woreZero = false
  var woreDefault = false
  for h in heads:
    if h == "aaaaaaaaaaaaaaaaaaaaaa03": woreZero = true
    if h == "ccccccccccccccccccccc001": woreDefault = true
  if woreZero:
    into.add "bots: a head with a weight of zero was worn; a zero weight " &
             "means never, not rarely"
  if woreDefault:
    into.add "bots: the base's default head was worn although the role's " &
             "table names two with weight on them"

  # 2. A pool whose weights sum to zero produces nothing rather than element
  #    zero, and the fallback is the base's -- not this file's literal.
  var strayFoot = ""
  for f in feet:
    if f != "ccccccccccccccccccccc003": strayFoot = f
  if strayFoot.len > 0:
    into.add "bots: an all-zero appearance pool produced " & strayFoot &
             " rather than falling back to the base; element zero of an " &
             "empty distribution is how a map ends up in one hat"

  # 3. The voice is a MongoId on `Customization`, weighted, and `Info.Voice`
  #    does not exist.
  var strayVoice = ""
  for v in voices:
    if v != "vvvvvvvvvvvvvvvvvvvvvv01": strayVoice = v
  if strayVoice.len > 0:
    into.add "bots: Customization.Voice was " & strayVoice & ", which is " &
             "neither the role's only weighted voice nor a refusal"
  let one = generateProfile(t, ChkBase, req, 0)
  if field(one, "Info.Voice").found:
    into.add "bots: Info.Voice is being sent, and BotBase has no such member"
  if not field(one, "Customization.Voice").found:
    into.add "bots: Customization.Voice is absent, which is where the " &
             "client's own type says the voice lives"

  # 4. `health.BodyParts` is a list of variants, rolled, in the client's shape.
  let hpKinds = distinctCount(headHp)
  if hpKinds < 2:
    into.add "bots: 24 bots drew " & $hpKinds & " distinct head health " &
             "value(s) from a two-variant table -- the variant list is not " &
             "being drawn from"
  var strayHp = ""
  for hp in headHp:
    if hp != "30" and hp != "45": strayHp = hp
  if strayHp.len > 0:
    into.add "bots: head health came out as " & strayHp & ", which is in " &
             "neither variant of the table"
  if legLow < 50.0 or legHigh > 70.0:
    into.add "bots: a body part rolled outside its own {min, max}: " &
             numText(legLow) & ".." & numText(legHigh) & " against 50..70"
  if legLow == legHigh:
    into.add "bots: a body part with a real range rolled the same value 24 " &
             "times, which is a splice rather than a roll"
  if field(one, "Health.BodyParts.Head.min").found:
    into.add "bots: the health table's {min, max} reached the client, which " &
             "reads {Health: {Current, Maximum}}"
  if not field(one, "Health.BodyParts.Head.Health.Maximum").found:
    into.add "bots: a body part has no Health.Maximum"
  if field(one, "Health.BodyParts.LeftLeg.Health.Maximum").asFloat(0.0) != 70.0:
    into.add "bots: a body part's Maximum was rolled rather than taken from " &
             "the table's max, so a bandage cannot restore what the role says"
  if tempLow < 36.0 or tempHigh > 40.0:
    into.add "bots: Temperature rolled outside 36..40: " & numText(tempLow) &
             ".." & numText(tempHigh)

  # 5. The profile is the base with things written over it.
  if field(one, "WishList").raw != "{}":
    into.add "bots: WishList is " & field(one, "WishList").raw & "; BotBase " &
             "declares Dictionary<MongoId, Int32> and the base file's array " &
             "is the half that is wrong"
  if field(one, "Encyclopedia").raw != "{}":
    into.add "bots: Encyclopedia is " & field(one, "Encyclopedia").raw &
             " rather than an empty map"
  if not field(one, "Health.Immortal").found:
    into.add "bots: Health.Immortal was dropped, so the profile is not being " &
             "built on bots.base"
  if not field(one, "Info.LowerNickname").found or
     not field(one, "Info.PrestigeLevel").found or
     not field(one, "Hideout").found or
     not field(one, "Variables").found:
    into.add "bots: a member bots.base carries is missing from the " &
             "generated profile"
  if not field(one, "Stats.Eft.DamageHistory.LethalDamagePart").found:
    into.add "bots: Stats.Eft was overwritten with an empty object, which " &
             "removes members the client's own type declares"
  if not field(one, "Info.Settings.UseSimpleAnimator").found:
    into.add "bots: Info.Settings was replaced rather than written over, so " &
             "the base's own settings were lost"
  if field(one, "Info.Settings.Role").asText("") != "assault" or
     field(one, "Info.Settings.BotDifficulty").asText("") != "normal":
    into.add "bots: the request's role and difficulty did not survive the " &
             "merge onto the base's Info.Settings"
  # And the five `BotBase` members the base file does not carry.
  if not field(one, "Notes.Notes").found or
     not field(one, "Quests").found or
     not field(one, "RagfairInfo").found or
     not field(one, "TradersInfo").found or
     not field(one, "UnlockedInfo.unlockedProductionRecipe").found:
    into.add "bots: a BotBase member that bots.base does not carry is absent " &
             "from the generated profile"

  # 6. And the same generator with no skeleton at all, which is what a small
  #    fixture is. It must still produce a bot the client could spawn.
  let bare = generateProfile(t, "", req, 0)
  if not field(bare, "Customization.Head").found or
     not field(bare, "Health.BodyParts.RightLeg.Health.Current").found or
     not field(bare, "Inventory.equipment").found:
    into.add "bots: a database with no bots.base produced an incomplete " &
             "profile"
  if field(bare, "Customization.Feet").asText("") !=
     "5cde95d97d6c8b647a3769b0":
    into.add "bots: with no base and an all-zero pool, the last-resort " &
             "appearance id was not used"

  result = into.len == before
