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
import knobs
import botgear
import modrarity
import planting

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

const
  PocketsTpl = "627a4e6b255f7527fb05a0f6"
    ## The post-1.0 pockets, with `SpecialSlot1..3`. Spelled out here rather
    ## than imported from `emu/profile` so that the bot generator does not take
    ## a dependency on the player-profile module for one string. See the note in
    ## `emu/profile.nim` beside its copy for why a character without this does
    ## not spawn.

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

var gGear = defaultBotGearConfig()
var gGearLoaded = false
var gModRar = defaultModRarityConfig()

proc refreshBotGear*() =
  ## Re-read the Bot gear/loot page. Called once per BATCH -- not once per bot,
  ## which would be 30 config reads on the loading screen for one answer, and
  ## not once per process, which would make an edit take a restart when the
  ## whole point of the page is that it does not.
  ##
  ## The attachment page is re-read on the SAME tick and cached in the same
  ## place, because it is 613 more reads and doing them per bot would put ~12k
  ## config lookups on a 20-bot loading screen.
  gGear = botGearConfig()
  gModRar = modRarityConfig()
  gGearLoaded = true

proc botGear(): BotGearConfig =
  if not gGearLoaded:
    refreshBotGear()
  result = gGear

proc modRar(): ModRarityConfig =
  if not gGearLoaded:
    refreshBotGear()
  result = gModRar

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

var gInternalMagSuppressed = 0
  ## Spare/loose copies of an INTERNAL magazine (a fixed tube or cylinder)
  ## suppressed. The reported shotgun bug, counted at source. Zero on a batch
  ## that generated no tube-fed weapon, which is why `auditInternalMags` is the
  ## verdict and this is only the diagnosis.

var gInternalMagServed = 0
  ## Internal magazines found in a FINISHED, about-to-be-served bot inventory
  ## sitting anywhere OTHER than a `mod_magazine` slot -- i.e. carried loose.
  ## **This is the number that must be zero.** It is a negative assertion on the
  ## serialised payload, so it can fail; "did I skip the spare?" could not.

var gFam = famOther
  ## The family of the bot currently being assembled, set once per bot by
  ## `addLoadout`. A module var rather than a parameter threaded through eleven
  ## procs: generation is one bot at a time on one thread, and the alternative
  ## was touching every signature in this file to carry a number that is
  ## constant for the whole call.

proc numProp(tpl, name: string): float =
  ## One numeric `_props` member, or NaN-as-"absent" expressed as `found`.
  ## Returns 0.0 and `false` when the database does not say, which the caller
  ## must read as "no opinion" and not as "zero" -- an item with no armour class
  ## is not an item with armour class 0 for weighting purposes, it is an item
  ## the bias has nothing to say about.
  let v = dbRead("templates.items." & tpl & "._props." & name)
  if not v.ok:
    return -1.0
  result = whole(v.raw).asFloat(-1.0)

proc pickTemplateBiased(pool: JsonRef; r: var Rng; prop: string;
                        bias: float): string =
  ## `pickTemplate`, with the pool's own weights leaned toward high or low
  ## values of one numeric template property.
  ##
  ## **At `bias == 0.0` this IS `pickTemplate`** -- the same call, one draw from
  ## the same weight vector, so the RNG stream and therefore every bot in the
  ## raid is byte-identical to a build without this feature. That equality is
  ## the whole design: it is what makes "the defaults change nothing" a fact
  ## about the code rather than a claim about the arithmetic.
  ##
  ## When it is not zero, each entry's weight is multiplied by
  ## `1 + bias * (2n - 1)` where `n` is that entry's property value normalised
  ## over the pool's own min..max. So the factor runs 0..2 and an entry can be
  ## made rare but never impossible and never negative; a pool whose entries all
  ## declare the same value (or none) normalises to a constant and the bias is a
  ## no-op, which is the honest answer for a pool the property cannot rank.
  ##
  ## It re-weights and never rewrites: a template the role's pool does not name
  ## cannot be produced here, whatever the slider says.
  if bias == 0.0:
    return pickTemplate(pool, r)
  result = ""
  if not pool.found or not isObject(pool):
    return
  let entries = members(pool)
  var names: seq[string] = @[]
  var weights: seq[float] = @[]
  var vals: seq[float] = @[]
  var lo = 0.0
  var hi = 0.0
  var seen = false
  for m in entries:
    let w = whole(m.value).asFloat(0.0)
    if w <= 0.0:
      continue
    names.add m.name
    weights.add w
    let v = numProp(m.name, prop)
    vals.add v
    if v >= 0.0:
      if not seen:
        lo = v
        hi = v
        seen = true
      else:
        if v < lo: lo = v
        if v > hi: hi = v
  if seen and hi > lo:
    for i in 0 ..< weights.len:
      if vals[i] < 0.0:
        continue
      let n = (vals[i] - lo) / (hi - lo)
      var f = 1.0 + bias * (2.0 * n - 1.0)
      if f < 0.0: f = 0.0
      weights[i] = weights[i] * f
  let at1 = pickWeighted(r, weights)
  if at1 < 0:
    # Every weight was driven to zero by an extreme bias. Fall back to the
    # unbiased draw rather than serving nothing: a slider must not be able to
    # take a bot's rifle away by making it picky.
    return pickTemplate(pool, r)
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

proc isInternalMagazine(tpl: string): bool =
  ## `_props.ReloadMagType == "InternalMagazine"` -- a magazine that is PART OF
  ## THE WEAPON: a pump shotgun's tube, a revolver's cylinder, a Mosin's box.
  ##
  ## THE MEASURED CAUSE OF THE REPORTED SHOTGUN BUG. A player pulled a single-fed
  ## shotgun off a scav and found TWO circular magazines beside it in the rig
  ## that held no extra rounds and fitted nothing. Two earlier hypotheses were
  ## tested and killed -- it is not loose rig loot on its own (271 loose
  ## magazines were refused live and the drums stayed), and it is not filter
  ## generalisation by ancestry (0 of 2,897 weapon-mod filters name a base
  ## class). Both were looking for an ILLEGAL placement. There is none: measured
  ## over this install's own `db.json`, all 8 shotgun `mod_magazine` pools on
  ## role `assault` are 100 per cent inside the weapon's own `Filter`.
  ##
  ## The illegitimate items are the COPIES. `addMods` records every
  ## `mod_magazine` fitment as a `SpareMag` and `addSpareMags` then places
  ## `SparesPerWeapon` -- **exactly 2**, which is exactly what the player counted
  ## -- of that same template in a carried container. For an external magazine
  ## that is correct and is the reason a bot survives a reload. For an internal
  ## one it is a duplicate of a fixed part of the gun: it cannot be swapped in,
  ## it holds nothing, and it is indistinguishable on screen from a drum.
  ##
  ## MEASURED over `bots.types` (all 57 roles, `db.json`, 2026-08-31): of the
  ## 502 distinct (weapon, magazine) pairs any role's `mod_magazine` pool names,
  ## **470 are `ExternalMagazine` and 32 are `InternalMagazine`** -- among them
  ## `mag_mc255_ckib_mc255_cylinder_std_12g_5` and
  ## `mag_rsh12_kbp_rsh12_cylinder_127x55_5`, both literally cylinders, and the
  ## MR-133 / MR-153 / 870 / 590 / Benelli M3 tubes. 12 of the database's 15
  ## shotguns take one.
  ##
  ## `dbRead` rather than `itemMember` because this is called from the generator,
  ## which sits above `itemMember` in this file; the fixture-honouring twin used
  ## by the finished-state audit is `internalMagAudit`.
  let v = dbRead("templates.items." & tpl & "._props.ReloadMagType")
  if not v.ok:
    return false
  result = toLowerAscii(v.asText()) == "internalmagazine"

proc weaponCaliber(tpl: string): string =
  let v = dbRead("templates.items." & tpl & "._props.ammoCaliber")
  if not v.ok:
    return ""
  result = v.asText()

proc magAcceptedAmmo(magTpl: string): JsonRef =
  ## `_props.Cartridges[0]._props.filters[0].Filter` -- the list of ammo
  ## templates a magazine will physically accept, verified against a real
  ## database (`564ca99c...` lists 13). This is the coherence oracle for what
  ## goes in a mag: the client refuses to load a cartridge that is not in here,
  ## so a mag "filled" with an ammo the filter omits is a bot that spawns with
  ## an empty gun. `notFound` when the item declares no cartridge filter, which
  ## the caller reads as "no constraint to check against".
  let v = dbRead("templates.items." & magTpl & "._props.Cartridges")
  if not v.ok:
    return notFound()
  let first = at(whole(v.raw), 0)
  if not first.found:
    return notFound()
  result = first.field("_props").field("filters").at(0).field("Filter")

proc listContains(list: JsonRef; want: string): bool =
  ## Whether a JSON array of strings carries `want`.
  if not list.found or not isArray(list):
    return false
  let n = count(list)
  var i = 0
  while i < n:
    if at(list, i).asText("") == want:
      return true
    inc i
  result = false

proc pickAcceptedAmmo(pool, accepted: JsonRef; r: var Rng): string =
  ## One ammo template that the caliber pool offers AND the magazine accepts.
  ##
  ## The pool is `inventory.Ammo.<caliber>`, a weight map the role prefers; the
  ## filter is the magazine's own accepted list. Their intersection is the only
  ## coherent answer: a round the role wants but the mag cannot hold jams the
  ## gun, and a round the mag holds but the role never lists is not this role's
  ## ammo. Rebuilds the weight map down to the accepted entries and draws from
  ## it, so the role's weighting still decides *which* accepted round. When the
  ## magazine declares no filter (`accepted` absent) the whole pool is eligible,
  ## which is the pre-existing behaviour and the right one -- an unfiltered mag
  ## constrains nothing.
  if not pool.found or not isObject(pool):
    return ""
  let haveFilter = accepted.found and isArray(accepted) and count(accepted) > 0
  let entries = members(pool)
  var names: seq[string] = @[]
  var weights: seq[float] = @[]
  for m in entries:
    let w = whole(m.value).asFloat(0.0)
    if w <= 0.0:
      continue
    if haveFilter and not listContains(accepted, m.name):
      continue
    names.add m.name
    weights.add w
  # Bots > Quality > Ammunition. The role's own weighting still decides, leaned
  # toward the harder- or softer-hitting of the rounds IT ALREADY LISTS and the
  # magazine already accepts -- the intersection above is computed first and the
  # bias never widens it. At the default 0.0 the loop below does not run and the
  # draw is the one this proc always made.
  let bias = ammoBiasFor(botGear(), gFam)
  if bias != 0.0 and names.len > 1:
    var lo = 0.0
    var hi = 0.0
    var seen = false
    var vals: seq[float] = @[]
    for nm2 in names:
      let v = numProp(nm2, "PenetrationPower")
      vals.add v
      if v >= 0.0:
        if not seen:
          lo = v
          hi = v
          seen = true
        else:
          if v < lo: lo = v
          if v > hi: hi = v
    if seen and hi > lo:
      for i in 0 ..< weights.len:
        if vals[i] < 0.0:
          continue
        let n2 = (vals[i] - lo) / (hi - lo)
        var f = 1.0 + bias * (2.0 * n2 - 1.0)
        if f < 0.0: f = 0.0
        weights[i] = weights[i] * f
  let at1 = pickWeighted(r, weights)
  if at1 < 0:
    return ""
  result = names[at1]

proc fillMagazine(inv: JsonRef; items: var List; magId, magTpl, caliber: string;
                  r: var Rng) =
  ## Puts rounds in a magazine, drawn from `inventory.Ammo.<caliber>` and
  ## constrained to what the magazine itself accepts.
  ##
  ## Silent when the caliber is unknown, the pool is empty, the capacity is not
  ## in the item table, or no round satisfies both the role's pool and the mag's
  ## filter. An empty magazine is a bot that fires once and then does not; a
  ## magazine loaded with a round it does not accept is a bot the client refuses
  ## to spawn -- so the ammo is intersected with the mag's own
  ## `Cartridges[0].filters` (`pickAcceptedAmmo`) rather than assuming the role's
  ## caliber pool and this specific magazine agree. They do on stock data; the
  ## check is what keeps a caliber-conversion mag or a hand-edited table from
  ## producing the empty gun a player pulled off a corpse.
  if caliber.len == 0 or magTpl.len == 0:
    return
  let capacity = magazineCapacity(magTpl)
  if capacity <= 0:
    return
  let pool = inv.field("Ammo").field(caliber)
  let accepted = magAcceptedAmmo(magTpl)
  let ammo = pickAcceptedAmmo(pool, accepted, r)
  if ammo.len == 0:
    return
  # Bots > Quality > Magazine fill. A fraction of the magazine's own declared
  # capacity, never a number of rounds -- the same slider then means the same
  # thing on a 6-round tube and a 60-round drum. Floored at ONE round rather
  # than at zero: an empty magazine served to the client is a bot that never
  # fires, and a row that can produce one is a row that can empty a raid. The
  # default 1.0 short-circuits to `capacity` with no arithmetic, so a magazine
  # is loaded exactly as it always was.
  let fill = botGear().magFill
  var rounds = capacity
  if fill != 1.0:
    rounds = int(float(capacity) * fill + 0.5)
    if rounds < 1: rounds = 1
    if rounds > capacity: rounds = capacity
  var d = botItem(newId(), ammo, magId, "cartridges")
  setNumber(d, "location", 0)
  var upd = newDoc()
  setNumber(upd, "StackObjectsCount", rounds)
  setRaw(d, "upd", text(upd))
  items.add d

proc slotDefs(tpl: string): JsonRef =
  ## `templates.items.<tpl>._props.Slots` -- the item's OWN slot definitions,
  ## the source of `_required` (which slots make a functional weapon: receiver,
  ## barrel, pistol grip, gas block) and of each slot's compatible-item filter.
  ## Read once per mod-tree node, not once per slot, because a `dbRead` per slot
  ## per bot in a 20-bot batch is exactly the loading-screen cost this module is
  ## written to avoid. `notFound` when the item declares no slots.
  let v = dbRead("templates.items." & tpl & "._props.Slots")
  if not v.ok:
    return notFound()
  result = whole(v.raw)

proc slotDefFor(defs: JsonRef; name: string): JsonRef =
  ## The one slot definition whose `_name` matches, case-insensitively -- stock
  ## data spells the same slot in either casing (`Helmet_top`/`helmet_top`), the
  ## same fact `memberCI` exists for one level up.
  if not defs.found:
    return notFound()
  let wanted = toLowerAscii(name)
  let n = count(defs)
  for i in 0 ..< n:
    let s = at(defs, i)
    if toLowerAscii(s.field("_name").asText("")) == wanted:
      return s
  result = notFound()

proc slotFilter(def: JsonRef; r: var Rng): string =
  ## A random compatible template from a slot's own filter --
  ## `_props.Slots[i].filters[0].Filter`. This is the fallback for a REQUIRED
  ## slot the bot table names no pool for (measured: 2 of 2,878 required root
  ## slots in stock data, plus required child slots). A weapon missing a required
  ## part does not function on the client, so fitting a stock-compatible part is
  ## strictly better than serving the broken gun the player actually saw.
  ##
  ## MEASURED 2026-09-01, and this is the defect that shipped a bare receiver to
  ## a player: the filter array is nested ONE level deeper than this proc used to
  ## read. A stock slot definition is
  ## `{_name, _parent, _props: {filters: [{Filter: [...]}]}}` -- there is no
  ## top-level `filters` key at all, so `def.field("filters")` was `notFound`,
  ## `count` was 0, and EVERY required slot came back "names no template". Every
  ## other reader in this module and in `emu/loadout` already spelled it
  ## `_props.filters`; this one proc did not. `slotFilterNestedProps` is the
  ## marker for that fix.
  if not def.found:
    return ""
  var f0 = at(def.field("_props").field("filters"), 0)
  if not f0.found:
    # A hand-written fixture or a future schema that omits the `_props` wrapper.
    # Accepted, but never in place of the real nesting above.
    f0 = at(def.field("filters"), 0)
  let list = f0.field("Filter")
  let n = count(list)
  if n <= 0:
    return ""
  result = at(list, nextInt(r, n)).asText("")

# ---------------------------------------------------------------------------
# Required slots, as ONE implementation shared with the player loadout path
# ---------------------------------------------------------------------------
#
# `addMods` above honours `_required` for every slot the BOT TABLE names. That
# is the proven path and it is not changed. But two things it cannot do were
# paid for on 2026-08-31 by a player who spawned holding the RECEIVER of a rifle
# and nothing else:
#
#  1. `emu/loadout` -- the automation gear-minting path -- had no notion of
#     `_required` at all. It wrote one item document per request and called
#     `validateSlots`, which DROPS invalid children and never FILLS missing
#     required ones. A minted M4A1 was therefore the bare base template.
#  2. `addMods` iterates `keys(inv.mods.<tpl>)` -- the bot table's own slot
#     names. A required slot the table does not mention is never visited, so
#     `slotFilter`'s fallback never gets a chance at it.
#
# `fillRequiredSlots` below is the single implementation of "walk the template's
# OWN `_props.Slots`, and every slot marked `_required` must end up with a
# child". Both paths call it, so the two cannot drift into two different notions
# of "required". For the bot path it is a POST-PASS over an already-built mod
# tree: it only ever touches a required slot that is still EMPTY, so it cannot
# change any weapon `addMods` already completed, and it descends THROUGH the
# parts the bot table chose (a receiver the table fitted still gets its required
# barrel, and that barrel its required gas block).
#
# MEASURED against the live 41 MB db.json on 2026-08-31 (4,673 templates):
#
#  * 1,011 of 3,765 `_props.Slots` entries are `_required`. The commonest are
#    `mod_barrel` (94), `mod_pistol_grip` (86), `mod_handguard` (68),
#    `mod_reciever` (58), `mod_stock` (58), `mod_gas_block` (56).
#  * **0 of 148 `_props.Chambers` entries are `_required`.** So this walk reads
#    `Slots` ONLY, and that is a measurement rather than an oversight: a chamber
#    holds AMMUNITION, not a part, and both callers already load chambers
#    deliberately (`chamberRounds` here, `chamberRound` in `emu/loadout`).
#    Filling a chamber from its filter here would put a random cartridge in a
#    gun the caller had already chambered, or had deliberately left empty.
#  * Required slots NEST, which is why this is a walk and not a loop: the M4A1
#    requires `mod_pistol_grip`, `mod_reciever`, `mod_stock` and `mod_charge`,
#    and the receiver in turn requires `mod_barrel` and `mod_handguard`, and
#    that barrel requires `mod_gas_block`. A one-level fill still ships a gun
#    with no barrel.
#  * 0 of those 1,011 required slots names an EMPTY filter -- so on stock data
#    every required slot is fillable. "Required but unfillable" is still handled
#    explicitly and LOUDLY (`unfillable`, one line naming parent template and
#    slot) rather than silently producing a broken weapon, because the bot-table
#    flavour of that state is real (2 of 2,878 required root slots name no pool
#    in the bot table) and because a database change must announce itself.

type
  RequiredFill* = object
    ## What one `fillRequiredSlots` walk did. Deliberately five numbers, not a
    ## bool: "I minted 4 parts" is not "the weapon is complete", and neither is
    ## "nothing was dropped".
    found*: int
      ## Required slots discovered anywhere in the tree, recursively.
    already*: int
      ## Of those, ones that already had an occupant when the walk started.
    minted*: int
      ## Items this walk added. `found == already + minted` is the clean case.
    unfillable*: seq[string]
      ## Required slots that could NOT be filled, one line each, naming the
      ## parent template and the slot. A non-empty list is a weapon that is
      ## still broken and the caller must surface it, not swallow it.

const
  MaxRequiredDepth* = 8
    ## Deeper than any measured required chain (the M4A1's is 3) and a bound on
    ## a database whose filters point back at their own parent.
  MaxRequiredMints* = 64
    ## A bound on one walk. A fully required-kitted weapon measured 7 parts.

proc fillRequiredSlots*(items: var List; rootId, rootTpl: string; r: var Rng;
                        stat: var RequiredFill) =
  ## Fill every `_required` slot, recursively, under `rootId`.
  ##
  ## Slots that already have an occupant are LEFT ALONE and the walk descends
  ## into the occupant, so this is safe to run over a tree another generator
  ## already built. Nothing is ever replaced.
  ##
  ## `items` is appended to; nothing is removed. The caller still runs
  ## `validateSlots` afterwards, which is what proves the parts fit -- every
  ## template here comes out of the slot's OWN
  ## `_props.filters[0].Filter`, so `validateSlots` accepting them is expected
  ## and its REFUSING one is a real signal.
  ##
  ## One owned string is read at entry (`text(items)`), for the reason spelled
  ## out on `validateSlots`: `raw(items.at(i))` faults on this nimony because
  ## `at` takes its `List` by value.
  if rootId.len == 0 or rootTpl.len == 0:
    return

  # Who already occupies what. Keyed "<parentId>\x1f<lowercased slot>", with the
  # occupant's id and template alongside so the walk can descend into it.
  var takenKey: seq[string] = @[]
  var takenId: seq[string] = @[]
  var takenTpl: seq[string] = @[]
  let blob = text(items)
  let doc = whole(blob)
  let n0 = count(doc)
  for i in 0 ..< n0:
    let one = at(doc, i)
    let par = one.field("parentId").asText("")
    let sl = one.field("slotId").asText("")
    if par.len == 0 or sl.len == 0:
      continue
    takenKey.add par & "\x1f" & toLowerAscii(sl)
    takenId.add one.field("_id").asText("")
    takenTpl.add one.field("_tpl").asText("")

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
    if depth >= MaxRequiredDepth:
      continue
    let defs = slotDefs(parentTpl)
    if not defs.found:
      continue
    let ns = count(defs)
    for i in 0 ..< ns:
      let def = at(defs, i)
      if not def.field("_required").asBool(false):
        continue
      let slotName = def.field("_name").asText("")
      if slotName.len == 0:
        continue
      inc stat.found
      let key = parentId & "\x1f" & toLowerAscii(slotName)
      var occupied = -1
      for k in 0 ..< takenKey.len:
        if takenKey[k] == key:
          occupied = k
          break
      if occupied >= 0:
        # Already fitted -- by the bot table, by the caller, or by an earlier
        # iteration of this walk. Descend into it; a fitted receiver still
        # requires a barrel.
        inc stat.already
        if takenId[occupied].len > 0 and takenTpl[occupied].len > 0:
          ids.add takenId[occupied]
          tpls.add takenTpl[occupied]
          depths.add depth + 1
        continue
      if stat.minted >= MaxRequiredMints:
        stat.unfillable.add parentTpl & "." & slotName &
          ": required, but the " & $MaxRequiredMints &
          "-part budget for one item was already spent, so this slot is EMPTY"
        continue
      let tpl = slotFilter(def, r)
      if tpl.len == 0:
        stat.unfillable.add parentTpl & "." & slotName &
          ": required, but its _props.Slots[]._props.filters[0].Filter names " &
          "no template, so nothing can be fitted and the item is INCOMPLETE " &
          "[slotFilterNestedProps]"
        continue
      let modId = newId()
      items.add botItem(modId, tpl, parentId, slotName)
      takenKey.add key
      takenId.add modId
      takenTpl.add tpl
      inc stat.minted
      ids.add modId
      tpls.add tpl
      depths.add depth + 1

proc auditRequiredSlots*(itemsJson, rootId: string;
                         empty: var seq[string]; found: var int): int =
  ## THE FINISHED-STATE CHECK. Re-derives which slots are required straight from
  ## the database and walks the parent/child tree of an item list as it actually
  ## exists -- so it can be pointed at a profile RE-READ off the store, and it
  ## shares not one variable with whatever minted the tree.
  ##
  ## This is the falsifiable negative: **no required slot under `rootId` is
  ## empty**. `empty` gets one line per violation, naming the parent template
  ## and the slot. The input that makes it FAIL is a tree with a required slot
  ## unfilled, which is exactly the receiver-only rifle it exists to catch --
  ## and `emu/loadout`'s self-check drives that input deliberately.
  ##
  ## Returns how many required slots are FILLED. `found` is the total. The two
  ## being equal, with `empty` empty, is the pass.
  ##
  ## Counting what was minted would not do: `validateSlots` runs between the
  ## mint and the save and can remove a part, and the save itself can be lost.
  found = 0
  result = 0
  if rootId.len == 0 or itemsJson.len == 0:
    return

  let doc = whole(itemsJson)
  let n = count(doc)
  var ids: seq[string] = @[]
  var tpls: seq[string] = @[]
  var parents: seq[string] = @[]
  var slots: seq[string] = @[]
  for i in 0 ..< n:
    let one = at(doc, i)
    ids.add one.field("_id").asText("")
    tpls.add one.field("_tpl").asText("")
    parents.add one.field("parentId").asText("")
    slots.add toLowerAscii(one.field("slotId").asText(""))

  var rootTpl = ""
  for i in 0 ..< ids.len:
    if ids[i] == rootId:
      rootTpl = tpls[i]
      break
  if rootTpl.len == 0:
    # The root is not in this list. INCONCLUSIVE, and the caller can tell:
    # `found` is 0 and so is the result, with no violations claimed.
    return

  var walkId: seq[string] = @[]
  var walkTpl: seq[string] = @[]
  var depths: seq[int] = @[]
  walkId.add rootId
  walkTpl.add rootTpl
  depths.add 0
  var head = 0
  while head < walkId.len:
    let parentId = walkId[head]
    let parentTpl = walkTpl[head]
    let depth = depths[head]
    inc head
    if depth >= MaxRequiredDepth:
      continue
    let defs = slotDefs(parentTpl)
    if not defs.found:
      continue
    let ns = count(defs)
    for i in 0 ..< ns:
      let def = at(defs, i)
      if not def.field("_required").asBool(false):
        continue
      let slotName = def.field("_name").asText("")
      if slotName.len == 0:
        continue
      inc found
      let want = toLowerAscii(slotName)
      var childId = ""
      var childTpl = ""
      for k in 0 ..< ids.len:
        if parents[k] == parentId and slots[k] == want:
          childId = ids[k]
          childTpl = tpls[k]
          break
      if childId.len == 0:
        empty.add parentTpl & "." & slotName &
                  " is REQUIRED and EMPTY on the saved item tree"
        continue
      result = result + 1
      walkId.add childId
      walkTpl.add childTpl
      depths.add depth + 1

var gRequiredFound = 0
  ## Required slots seen by the template-driven backstop across every generated
  ## weapon this process.
var gRequiredBackfilled = 0
  ## Of those, ones the backstop had to fill because the bot table left them
  ## EMPTY -- the receiver-only-rifle counter. Non-zero is not a fault: it is
  ## the measure of how much the bot table alone was missing.
var gRequiredUnfillable: seq[string] = @[]
  ## Required slots that could not be filled at all, capped at 16 lines. **This
  ## must be empty.** A weapon named here went out with a hole in it, and the
  ## line says which template and which slot, rather than the player finding out
  ## in a raid.

var gChambered = 0
  ## Chamber slots actually loaded this process. Reported per batch, because a
  ## chambering that silently declines is exactly the failure mode this whole
  ## module was rewritten for.
var gChamberSkipped = 0
  ## Chamber slots left empty because no round satisfied both the role's caliber
  ## pool and the chamber's own filter.
var gSlotDropped = 0
  ## Items the pre-serve validator REMOVED because the parent template does not
  ## declare that slot, the slot's filter refuses that template, or the slot was
  ## already occupied. Every one of these would have been an
  ## `ItemFactory.FlatItemsToTree` "Cannot put item ... to slot ..." on the
  ## client, and 28 of them in one batch killed a raid load on 2026-08-30.
var gSlotUnknown = 0
  ## Items the validator could not judge -- the parent id is not in the bot's own
  ## item list, or the parent template is absent from the database. INCONCLUSIVE
  ## is not a failure: these are KEPT, and counted separately so a database gap
  ## never reads as a clean run.
var gModRefused = 0
  ## Of `gSlotDropped`, the ones removed because a WEAPON MOD slot's own
  ## `Filter` does not name that template -- the falsifiable negative for
  ## "no generated weapon carries a mod in a slot whose Filter does not admit
  ## it". **This is a number that must be zero.** It is not the same as
  ## `gSlotDropped`, which also counts undeclared slots and duplicates, and a
  ## total alone cannot tell the three apart.
var gSlotDup = 0
  ## Of `gSlotDropped`, the ones removed because that (parent, slot) pair was
  ## ALREADY filled -- the falsifiable negative for "no generated weapon carries
  ## more than one item in any single-cardinality slot", i.e. the two-magazines
  ## half of the shotgun report. **Also must be zero.**
var gWeapons = 0
  ## Weapons served (an item in `FirstPrimaryWeapon` / `SecondPrimaryWeapon` /
  ## `Holster` whose template declares a `weapClass`).
var gShotguns = 0
  ## Of those, shotguns. A batch that generated NO shotgun cannot say anything
  ## about the shotgun bug: that run is INCONCLUSIVE, not a pass, and the
  ## counter line has to make that readable without a second instrument.
var gStackAudited = 0
  ## Items in a FINISHED, about-to-be-served bot inventory whose template
  ## declares a random spawn range (`_props.StackMaxRandom`) -- currency and
  ## loose ammunition on stock data. Counted by reading the serialised payload
  ## back, not by trusting the generator's own locals: the "roll a real stack"
  ## code path already existed once and still shipped $1 bills.
var gStackFlat = 0
  ## Of those, how many were served with `upd.StackObjectsCount` MISSING or <= 1
  ## -- i.e. the single dollar the player pulls off a corpse. **This is the
  ## number that must be zero.** It is a negative assertion on the finished
  ## state, so it can actually fail; the previous check ("did I write an upd?")
  ## could not.
var gStackSum = 0
  ## Total units across every audited stack, so the reported average says whether
  ## the roll is plausible (dollars 45..100) rather than merely non-one.

proc chamberRounds(inv: JsonRef; items: var List;
                   weaponId, weaponTpl, caliber: string; r: var Rng;
                   filled: var seq[string]) =
  ## A live round in each of the weapon's chamber slots, drawn from the same
  ## caliber pool the magazine draws from and constrained the same way -- to what
  ## the chamber itself accepts (`Chambers[i]._props.filters[0].Filter`, fed to
  ## `pickAcceptedAmmo`). Read from the weapon's own `_props.Chambers` so a
  ## revolver's cylinder or a break-action's two barrels are chambered exactly as
  ## the data describes them, not assumed to be one `patron_in_weapon`.
  ##
  ## Silent, like `fillMagazine`: an unchambered weapon is a bot that racks the
  ## bolt before its first shot, which it will; a chamber loaded with a round it
  ## does not accept is a bot the client refuses to spawn, so a chamber for which
  ## no accepted round exists is left empty rather than forced.
  if caliber.len == 0 or weaponTpl.len == 0:
    return
  let ch = dbRead("templates.items." & weaponTpl & "._props.Chambers")
  if not ch.ok:
    return
  let pool = inv.field("Ammo").field(caliber)
  let list = each(whole(ch.raw))
  for slot in list:
    let name = slot.field("_name").asText("")
    if name.len == 0:
      continue
    let accepted = slot.field("_props").field("filters").at(0).field("Filter")
    let ammo = pickAcceptedAmmo(pool, accepted, r)
    if ammo.len == 0:
      inc gChamberSkipped
      continue
    var d = botItem(newId(), ammo, weaponId, name)
    var upd = newDoc()
    setNumber(upd, "StackObjectsCount", 1)
    setRaw(d, "upd", text(upd))
    items.add d
    inc gChambered
    # Claim the slot. `bots.types.<role>.inventory.mods.<weaponTpl>` ALSO carries
    # a `patron_in_weapon` list on most weapons (measured: `bots.types.assault
    # .inventory.mods.59e6152586f77473dc057aa1.patron_in_weapon` is a 4-entry
    # list), and the mod-tree walk below iterates those keys blindly. Chambering
    # here and then filling the same slot there put TWO rounds in one chamber,
    # which is the placement the client refused.
    filled.add toLowerAscii(name)

type
  SpareMag = object
    ## A magazine model the bot was given in a weapon, remembered so a spare of
    ## the same model -- guaranteed to fit -- can be put in a carried container.
    tpl: string
    caliber: string

const
  SparesPerWeapon = 2
    ## Spare magazines carried per weapon that took one. Two is a reload and a
    ## bit, which is what a real PMC's rig holds; a target, not a floor -- a spare
    ## is dropped silently when the rig has no room for it.
  MaxSpareMags = 4
    ## The cap across all weapons, so a bot with two rifles and a pistol does not
    ## turn into a walking magazine dump.

proc addMods(t: BotTables; inv, chances: JsonRef; items: var List;
             rootId, rootTpl: string; weapon: bool; r: var Rng;
             budget: var int; spares: var seq[SpareMag]) =
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
  # Bots > Attachments. Read once for this whole mod tree: the config off the
  # batch cache, and the weapon class off the ROOT template -- an optic bolted
  # to a mount bolted to a rifle is still a rifle's optic, which is what makes
  # the per-weapon-class rows mean the thing a player would expect. Equipment
  # has no `weapClass` and resolves to `wcOtherClass`, its own row.
  let mr = modRar()
  let wclass = weaponClassOf(rootTpl)

  # A round in the chamber, once, before the mod tree is walked. Costs no mod
  # budget -- it is not a mod, it is the weapon being loaded -- and is skipped
  # for a knife (empty caliber) by `chamberRounds` itself.
  var chambered: seq[string] = @[]
  if weapon and caliber.len > 0:
    chamberRounds(inv, items, rootId, rootTpl, caliber, r, chambered)

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
    # The item's own slot definitions, read once for this parent. `_required`
    # lives here, not in the chance table, and it is the whole of the fix: a
    # required slot is filled REGARDLESS of what the chance table says, because
    # stock data lists `mod_pistol_grip` at chance 0 and `mod_stock` at 48 on an
    # AK that cannot function without either -- honouring the chance produced the
    # receiver-only weapon a player pulled off a dead scav. The chance roll and
    # the zero-skip govern OPTIONAL slots only.
    let defs = slotDefs(parentTpl)
    for slotName in named:
      if budget <= 0:
        return
      # A chamber this weapon was ALREADY loaded with is not available to the mod
      # table, whatever the table says. Only the weapon root can have been
      # chambered, so the guard is scoped to it.
      if parentId == rootId and chambered.len > 0 and
         toLowerAscii(slotName) in chambered:
        continue
      let def = slotDefFor(defs, slotName)
      let required = def.found and def.field("_required").asBool(false)
      let pool = slots.field(slotName)
      let n = count(pool)
      if not required:
        if n <= 0:
          continue
        # Bots > Attachments. A multiplier on the TABLE'S OWN chance, so a
        # slot the database never fills stays unfilled and a required slot is
        # untouched (this branch only runs when `required` is false).
        #
        # Two factors on one product now: the old global weapon/equipment
        # slider, and the new slot-group x family x weapon-class number, which
        # is 1.0 unless a row on the Attachments page was moved. `scalePercent`
        # still returns its input UNCHANGED at exactly 1.0, so the product
        # being 1.0 is the same no-arithmetic path it always was.
        let pct = scalePercent(chanceFor(chances, group, slotName, 100),
                               modMultiplier(botGear(), weapon) *
                               modChanceMultiplier(mr, gFam, slotName, wclass))
        if pct <= 0:
          continue
        if pct < 100 and not chance(r, float(pct) / 100.0):
          continue
      var tpl = ""
      if n > 0:
        # Bots > Attachments > Rarity. With nothing turned on this IS
        # `at(pool, nextInt(r, n)).asText("")`, by an early return rather than
        # by arithmetic that happens to agree -- see `pickModTemplate`.
        tpl = pickModTemplate(mr, pool, n, r, gFam, slotName, wclass)
      if tpl.len == 0 and required:
        # The bot table named no usable pool for a slot the weapon must have.
        # Fit a stock-compatible part from the item's own filter rather than
        # ship a gun with a hole in it.
        tpl = slotFilter(def, r)
      if tpl.len == 0:
        continue
      let modId = newId()
      items.add botItem(modId, tpl, parentId, slotName)
      dec budget
      if toLowerAscii(slotName) == "mod_magazine":
        fillMagazine(inv, items, modId, tpl, caliber, r)
        dec budget
        # Remember the model so a spare of it can go in the rig. Same tpl, so it
        # is guaranteed to fit the weapon; same caliber, so it can be loaded.
        #
        # UNLESS it is an INTERNAL magazine -- a tube or a cylinder that is part
        # of the gun. A spare of one of those cannot be swapped in, holds no
        # extra rounds, and renders as a second circular magazine in the rig.
        # That is the reported shotgun bug; see `isInternalMagazine` for the
        # measurement. The row exists to put the old behaviour back.
        if caliber.len > 0:
          if isInternalMagazine(tpl) and not botGear().spareInternalMags:
            inc gInternalMagSuppressed
          else:
            spares.add SpareMag(tpl: tpl, caliber: caliber)
      ids.add modId
      tpls.add tpl
      depths.add depth + 1

  # THE BACKSTOP. Everything above is driven by `keys(inv.mods.<tpl>)` -- the
  # bot table's own slot names -- so a required slot the table does not mention
  # is never visited at all, and `slotFilter`'s fallback above never gets a
  # chance at it. This pass is driven by the TEMPLATE's `_props.Slots` instead,
  # and it only ever fills a required slot that is still EMPTY, so it cannot
  # change a weapon the table already completed. Same proc `emu/loadout` calls,
  # so the player's minted gun and the bot's generated one cannot end up with
  # two different ideas of what "required" means.
  if weapon:
    var rf = RequiredFill(found: 0, already: 0, minted: 0, unfillable: @[])
    fillRequiredSlots(items, rootId, rootTpl, r, rf)
    gRequiredFound = gRequiredFound + rf.found
    gRequiredBackfilled = gRequiredBackfilled + rf.minted
    for u in rf.unfillable:
      if gRequiredUnfillable.len < 16:
        gRequiredUnfillable.add u

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

proc lootRichness(): float =
  ## A global multiplier on how much loose loot a bot carries. Owned by the
  ## Bot AI mod and published into `configs.botLoot.richnessMultiplier` on the
  ## shared database at server start; read here rather than compiled in, so the
  ## Bot AI > Loadout page changes bot loot with no rebuild. 1.0 is stock
  ## generosity (what the weight tables say), 2.0 is "crazy full", 0.0 empties
  ## the pockets. Absent or unparseable -> 1.0, never 0.0: a loot pass that read
  ## a missing knob as zero is a silent regression to naked bots, which is the
  ## exact failure this module was written to end. Clamped to [0, 5] so a typo
  ## in the config cannot build one bot the size of a raid.
  let v = dbRead("configs.botLoot.richnessMultiplier")
  if not v.ok:
    return 1.0
  var m = v.asFloat(1.0)
  if m < 0.0: m = 0.0
  if m > 5.0: m = 5.0
  result = m

proc randomStackCount(tpl: string; r: var Rng): int =
  ## How large a stack of `tpl` a bot carries, or **zero** for an item that is
  ## not stacked at spawn.
  ##
  ## This is the fix for scav money always being a single unit. A plain scav's
  ## pocket/vest/backpack pool contains currency template ids (dollars, roubles,
  ## euros), and `addContainerLoot` placed whatever it drew as one item with no
  ## `StackObjectsCount` -- which the client renders as a stack of ONE, i.e. the
  ## $1 bill the player kept pulling off corpses. The stack size was never rolled
  ## because the loot generator treats a pool as "template ids, no counts".
  ##
  ## The stackable items are exactly the ones whose template declares a random
  ## spawn range -- `_props.StackMinRandom`/`StackMaxRandom` -- which on stock
  ## data is currency and loose ammunition and nothing else (a medkit has no such
  ## field). So the discriminator is the data's own, not a hardcoded currency
  ## list: an item that declares the range gets a stack rolled inside it, off the
  ## client's own numbers (dollars 45..100, roubles 5500..13500, euros 35..90),
  ## and everything else keeps the single-item behaviour by returning zero.
  let hi = itemProp(tpl, "StackMaxRandom")
  if not hi.ok:
    return 0
  let lo = itemProp(tpl, "StackMinRandom")
  var a = lo.asInt(1)
  var b = hi.asInt(1)
  if a < 1: a = 1
  if b < a: b = a
  result = a + nextInt(r, b - a + 1)
  # Loot > Money. The three money rows shape a CURRENCY stack only; loose
  # ammunition declares the same range and is deliberately left alone, because
  # a row labelled "money" that also halved every bot's ammo would be a control
  # that does something other than it says. At the defaults (x1.0, no floor, no
  # ceiling) `applyMoneyStack` returns its input and this costs one comparison.
  if isMoneyTpl(tpl):
    result = applyMoneyStack(botGear().moneyStacks, result)

var gLooseMagRefused = 0
  ## Loose magazines refused from container loot because no weapon the bot is
  ## carrying can take them. See `addContainerLoot`.


proc declaresCartridges(tpl: string): bool =
  ## A MAGAZINE, discriminated by the template's own declaration rather than by
  ## a base-class id written out from memory. MEASURED: exactly 224 templates in
  ## the shipped database declare `_props.Cartridges`, and they are the
  ## magazines; ammunition packs declare `StackSlots` instead, and weapons
  ## declare `Chambers`.
  ##
  ## `dbRead` rather than `itemMember`: this proc is defined above `itemMember`,
  ## and the loot path it guards has no fixture seam to honour anyway.
  let v = dbRead("templates.items." & tpl & "._props.Cartridges")
  if not v.ok:
    return false
  result = at(whole(v.raw), 0).found

proc magazinesFitting(weaponTpls: seq[string]): seq[string] =
  ## Every magazine template named by the `mod_magazine` filter of any weapon
  ## the bot is actually carrying. Concrete ids -- see `isModSlot` for the
  ## measurement that says a weapon mod filter never names a class.
  result = @[]
  for w in weaponTpls:
    let def = slotDefFor(slotDefs(w), "mod_magazine")
    if not def.found:
      continue
    let list = def.field("_props").field("filters").at(0).field("Filter")
    if not list.found or not isArray(list):
      continue
    for i in 0 ..< count(list):
      let one = at(list, i).asText("")
      if one.len == 0 or one in result:
        continue
      # The other half of the same fix. "Fits a gun I am carrying" was read as
      # "is named by that gun's mod_magazine Filter", and for a pump shotgun
      # that Filter names its own fixed TUBE. A loose tube in the rig is the
      # bug by the container-loot route rather than the spare route, and it is
      # why refusing 271 loose magazines live did not make the drums go away:
      # these were never among the refused.
      if isInternalMagazine(one) and not botGear().spareInternalMags:
        continue
      result.add one

proc addContainerLoot(inv, generation: JsonRef; items: var List;
                      c: var Container; kind: string; r: var Rng;
                      budget: var int; richness: float;
                      fittingMags: seq[string]) =
  ## Fills one equipped container from its own pool.
  ##
  ## ## Loose magazines are filtered against the bot's own guns
  ##
  ## The container pools are NOT weapon-aware: measured on the shipped database,
  ## a plain scav's `TacticalVest` pool has 150 entries of which **39 are
  ## magazines**, in every caliber the game has, and the `Backpack` pool has
  ## **181 of 1,851** -- including 75-round drums. Drawn blind, a scav carrying a
  ## single-fed shotgun ends up with two drum magazines in his rig that fit
  ## nothing he owns. That is the reported bug, and it is a LOOT bug, not a slot
  ## bug: nothing was ever attached to the shotgun (the mod-slot pools were
  ## audited against every shotgun's own `Filter` and are clean), the magazines
  ## were loose in the rig beside it.
  ##
  ## So a magazine is only placed here if some weapon the bot is carrying names
  ## it. A bot with no firearm at all therefore carries no loose magazine, which
  ## is the same rule and the right answer. Every other loot kind is untouched.
  let pool = inv.field("items").field(c.slot)
  if not pool.found or not isObject(pool):
    return
  var wanted = drawCount(generation, kind, r)
  # The Bot AI richness knob scales what the weight table rolled. It multiplies
  # a real count rather than inventing one, so a table that said "nothing this
  # time" still yields nothing -- richness makes a stocked bot richer, it does
  # not conjure loot into an empty roll.
  # Bots > Loot > Per container. Composed with the richness above rather than
  # replacing it, and at the default 1.0 the multiplication is skipped outright
  # so the count is the table's own integer with no rounding applied to it.
  let perKind = containerLootMultiplier(botGear(), kind)
  let scale = richness * perKind
  if scale != 1.0 and wanted > 0:
    wanted = int(float(wanted) * scale + 0.5)
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
    if declaresCartridges(tpl) and tpl notin fittingMags:
      inc gLooseMagRefused
      continue
    var gridName = ""
    var location = ""
    if not placeIn(c, tpl, gridName, location):
      # Full. Stopping rather than trying smaller items: a container that has
      # no room for the item drawn has very little for the next one, and the
      # loop above is already bounded.
      return
    var d = botItem(newId(), tpl, c.id, gridName)
    setRaw(d, "location", location)
    # Most loot is one of the thing with no `StackObjectsCount`: the pool gives
    # template ids and no counts, and `generation.items.<kind>` counts *items*
    # rather than rounds or roubles, so a stack size for an ordinary item would
    # be this file's invention. The exception is a template that declares its own
    # spawn range -- currency and loose ammo -- where the count is the client's
    # data, not ours: `randomStackCount` rolls it, and a currency stack is
    # therefore a realistic amount instead of a flat $1.
    let stack = randomStackCount(tpl, r)
    if stack >= 1:
      var upd = newDoc()
      setNumber(upd, "StackObjectsCount", stack)
      setRaw(d, "upd", text(upd))
    items.add d
    inc placed
    dec budget

proc addSpareMags(inv: JsonRef; items: var List; carried: var seq[Container];
                  spares: seq[SpareMag]; r: var Rng) =
  ## Spare, loaded magazines in a carried container -- the reason a bot with a
  ## rifle is still in the fight after the first reload rather than swinging it
  ## like a club. Each is the same model the weapon was given, so it fits, and is
  ## filled through `fillMagazine`, so it carries the correct caliber. Bounded by
  ## `MaxSpareMags`; a spare that finds no room in any grid is dropped rather
  ## than written to a cell that overlaps something.
  if carried.len == 0:
    return
  # Bots > Ammunition. `MaxSpareMags` was a compiled-in 4; it is now the
  # default of a row, clamped to 0..16 in `botgear`. Zero is a real answer --
  # a bot with one magazine and no reload -- and it is the player's to choose.
  let maxSpares = botGear().spareMags
  var placed = 0
  for m in spares:
    if placed >= maxSpares:
      break
    if m.tpl.len == 0:
      continue
    var n = 0
    # Bots > Loot. `SparesPerWeapon` was a compiled-in 2 and is now the default
    # of a row; the const stays as that default's single source.
    let perWeapon = botGear().sparesPerWeapon
    while n < perWeapon and placed < maxSpares:
      inc n
      var gridName = ""
      var location = ""
      var idx = -1
      for i in 0 ..< carried.len:
        if placeIn(carried[i], m.tpl, gridName, location):
          idx = i
          break
      if idx < 0:
        break
      let magId = newId()
      var d = botItem(magId, m.tpl, carried[idx].id, gridName)
      setRaw(d, "location", location)
      items.add d
      fillMagazine(inv, items, magId, m.tpl, m.caliber, r)
      inc placed

# ---------------------------------------------------------------------------
# The pre-serve validator
#
# On 2026-08-30 a raid load died with 28 identical client errors:
#
#   Item deserialization error: Cannot put item patron_762x39_T45M to slot
#   patron_in_weapon in item weapon_molot_vepr_km_vpo_136_762x39
#   ... EFT.ItemFactory:FlatItemsToTree -> EFT.Profile:.ctor -> LoadBots
#
# and no other error of any kind. Measured against the shipped database, the
# slot EXISTS (`templates.items.59e6152586f77473dc057aa1._props.Chambers[0]
# ._name == "patron_in_weapon"`) and its filter DOES accept the cartridge
# (`59e4cf5286f7741778269d8a` is in that Filter). The placement was refused
# because the slot was ALREADY FULL: `chamberRounds` loaded it, and then the
# mod-tree walk loaded it again from `bots.types.<role>.inventory.mods
# .<weaponTpl>.patron_in_weapon`, which stock data carries on most weapons.
#
# The duplicate is fixed at source above. This is the guard that makes the whole
# CLASS unshippable, because the next one will not be a chamber. It asserts a
# property of the FINISHED item list rather than of any one writer:
#
#   1. every child's `slotId` is declared by its parent's own template, in
#      `_props.Slots`, `_props.Chambers`, `_props.Cartridges` (the `cartridges`
#      pseudo-slot) or `_props.Grids` (a container cell);
#   2. for a Slot/Chamber/Cartridges placement, the child's `_tpl` is in that
#      slot's `filters[0].Filter` when the slot declares one, and NOT in its
#      `ExcludedFilter`;
#   3. no non-grid slot on one parent is filled twice.
#
# A violating item is REMOVED, together with everything hanging off it, so the
# bot is served without the extra rather than served broken. Three outcomes, not
# two: a parent id that is not in the list, or a parent template the database
# does not have, is INCONCLUSIVE -- kept, and counted in `gSlotUnknown`.
# ---------------------------------------------------------------------------

type
  SlotVerdict = enum
    svUnknown   ## cannot judge -- no parent, or no such template
    svGrid      ## a container cell, validated by `emu/grid`, not here
    svOk        ## declared, and the filter accepts this template
    svBad       ## declared and refused, or not declared at all

var gFixtureItems = ""
  ## A test-only item table, as raw JSON `{"<tpl>": {"_props": {...}}, ...}`.
  ## Empty in every real run, in which case the validator reads the real
  ## database. The seam exists because `aowl selfcheck` runs out-of-process with
  ## NO database loaded, and a check that cannot run is not a check.

proc setSlotFixture*(raw: string) = gFixtureItems = raw

proc itemMember(tpl, member: string): JsonRef =
  ## `templates.items.<tpl><member>`, from the fixture when one is installed and
  ## from the database otherwise. `notFound()` means "the data does not say",
  ## which the callers must treat as INCONCLUSIVE, never as "absent".
  if gFixtureItems.len > 0:
    let root = whole(gFixtureItems).field(tpl)
    if not root.found:
      return notFound()
    if member.len == 0:
      return root
    return root.field(member)
  let path = "templates.items." & tpl & (if member.len == 0: "" else: "." & member)
  let v = dbRead(path)
  if not v.ok:
    return notFound()
  result = whole(v.raw)

proc ancestry(tpl: string): seq[string] =
  ## `<tpl>` followed by its `_parent` chain through `templates.items`, capped.
  ##
  ## THIS is what a slot filter is written against. Measured against the shipped
  ## database on 2026-08-30: `templates.items.55d7217a4bdc2d86028b456d` (the
  ## equipment root every bot hangs off) declares `Headwear` with a filter of
  ## exactly ONE entry, `5a341c4086f77401f2541505` -- the Headwear *base class*,
  ## not any concrete hat. An exact-membership test therefore refuses EVERY
  ## helmet, vest, rig, backpack and weapon a bot is given; live, that dropped
  ## 3,308 items in one raid, ~25 per bot, i.e. the entire loadout. The client
  ## resolves the filter through the template inheritance chain, so we must too.
  var out2: seq[string] = @[]
  var cur = tpl
  var hops = 0
  while cur.len > 0 and hops < 12:
    out2.add cur
    let p = itemMember(cur, "_parent")
    if not p.found:
      break
    let nxt = p.asText("")
    if nxt.len == 0 or nxt == cur:
      break
    cur = nxt
    hops = hops + 1
  result = out2

proc isModSlot(slot: string): bool =
  ## True for a WEAPON MOD slot, where a filter is written against concrete
  ## template ids, as opposed to an EQUIPMENT slot, where it is written against
  ## base classes.
  ##
  ## MEASURED against the shipped database on 2026-08-31, over every `Slots`
  ## entry of all 4,673 templates: of the **2,897** slots named `mod_*` or
  ## `patron*`, **ZERO** name a base class in `filters[0].Filter` -- every entry
  ## is a concrete item. Of the **868** equipment slots, **26** do name a class,
  ## and those 26 are the whole reason `ancestry` exists (an exact test refused
  ## every helmet and rig and dropped 3,308 items in one raid).
  ##
  ## So the generalisation is NEEDED on equipment and is never needed on a
  ## weapon mod slot, where it can only ever say yes to something the client
  ## will say no to: a Remington 870's `mod_magazine` filter is three specific
  ## tube extensions, and every magazine in the database -- including the
  ## MD Arms 20-round Saiga DRUM -- shares the ancestor `5448bc234bdc2d3c308b4569`.
  ## That is the shotgun-with-a-drum-magazine bug, exactly.
  ##
  ## `Cartridges` and `Chambers` filters were measured the same way and are also
  ## 0-of-224 and 0-of-148 class entries, so ammo is exact too.
  let s = toLowerAscii(slot)
  s.startsWith("mod_") or s.startsWith("patron") or s.startsWith("camora") or
    s == "cartridges"

proc listContainsAny(list: JsonRef; names: seq[string]): bool =
  for one in names:
    if listContains(list, one):
      return true
  result = false

proc filterAccepts(def: JsonRef; tpl: string; exact: bool = false): bool =
  ## `filters[0].Filter` / `ExcludedFilter`, resolved through the template's own
  ## inheritance chain (see `ancestry`) -- unless `exact`, in which case the
  ## ALLOW list is matched against the template id ITSELF and nothing else.
  ## `exact` is set for weapon mod slots only; see `isModSlot` for the
  ## measurement that says the chain buys nothing there and costs correctness.
  ##
  ## `ExcludedFilter` stays chain-resolved in both modes on purpose: a
  ## denial written against a base class must still deny its members, and
  ## widening a denial cannot admit anything the client would refuse.
  ## A slot that declares no filter
  ## constrains nothing and accepts everything -- that is stock behaviour and the
  ## right reading; only a NON-EMPTY Filter is authoritative.
  let f0 = def.field("_props").field("filters").at(0)
  let f1 = if f0.found: f0 else: def.field("filters").at(0)
  if not f1.found:
    return true
  let excluded = f1.field("ExcludedFilter")
  let allow = f1.field("Filter")
  let hasExcl = excluded.found and isArray(excluded) and count(excluded) > 0
  let hasAllow = allow.found and isArray(allow) and count(allow) > 0
  if not hasExcl and not hasAllow:
    return true
  let chain = ancestry(tpl)
  if hasExcl and listContainsAny(excluded, chain):
    return false
  if not hasAllow:
    return true
  if exact:
    return listContains(allow, tpl)
  result = listContainsAny(allow, chain)

proc gridDeclares(parentTpl, slotName: string): bool =
  let g = itemMember(parentTpl, "_props.Grids")
  if not g.found:
    return false
  let wanted = toLowerAscii(slotName)
  let list = each(g)
  for one in list:
    if toLowerAscii(one.field("_name").asText("")) == wanted:
      return true
  result = false

proc judgeSlot(parentTpl, slotName, tpl: string): SlotVerdict =
  ## One placement, judged against the parent's own template.
  if parentTpl.len == 0 or slotName.len == 0:
    return svUnknown
  if not itemMember(parentTpl, "").found:
    return svUnknown
  let wanted = toLowerAscii(slotName)
  let exact = isModSlot(wanted)

  if wanted == "cartridges":
    let first = itemMember(parentTpl, "_props.Cartridges").at(0)
    if not first.found:
      return svBad
    return if filterAccepts(first, tpl, exact): svOk else: svBad

  for member in ["_props.Slots", "_props.Chambers"]:
    let v = itemMember(parentTpl, member)
    if not v.found:
      continue
    let def = slotDefFor(v, slotName)
    if def.found:
      return if filterAccepts(def, tpl, exact): svOk else: svBad

  if gridDeclares(parentTpl, slotName):
    return svGrid
  result = svBad

var gDropKeys: seq[string] = @[]
var gDropCounts: seq[int] = @[]
  ## The permanent drop histogram: one bucket per
  ## `<rule>|<parentTpl>|<childTpl>|<slotId>`. A total alone cannot tell an
  ## over-rejecting validator from a mis-generating generator -- that is exactly
  ## how "slot-dropped 3308" sat in the log for a whole raid reading like a
  ## success. The buckets name the rule, so the next one is one grep.

proc noteDrop(rule, parentTpl, childTpl, slotId: string) =
  let key = rule & "|" & parentTpl & "|" & childTpl & "|" & slotId
  for i in 0 ..< gDropKeys.len:
    if gDropKeys[i] == key:
      gDropCounts[i] = gDropCounts[i] + 1
      return
  if gDropKeys.len >= 400:
    return
  gDropKeys.add key
  gDropCounts.add 1

proc botDropHistogram*(top: int): string =
  ## The top `top` buckets, most-dropped first, as `count rule|parent|child|slot`
  ## lines. Empty string when nothing was dropped.
  var order: seq[int] = @[]
  for i in 0 ..< gDropKeys.len:
    order.add i
  for a in 0 ..< order.len:
    for b in (a + 1) ..< order.len:
      if gDropCounts[order[b]] > gDropCounts[order[a]]:
        # Both sides read into locals first: `order[a] = order[b]` is rejected
        # by this nimony as "mutable argument aliases with immutable parameter".
        let ta = order[a]
        let tb = order[b]
        order[a] = tb
        order[b] = ta
  var out2 = ""
  var shown = 0
  for i in order:
    if shown >= top:
      break
    out2 = out2 & "\n  " & $gDropCounts[i] & "  " & gDropKeys[i]
    shown = shown + 1
  result = out2

proc validateSlots*(items: List; report: var seq[string];
                    kept: var seq[string]): int =
  ## Removes every placement the client would refuse, and returns how many items
  ## were removed. `report` gets one line per violation, naming the parent
  ## template, the slot and the offending template -- the three things the client
  ## error names, so a failure here reads like the failure it prevents.
  ##
  ## The surviving items are written to `kept` as RAW JSON STRINGS, and `items`
  ## itself is not mutated. Both halves of that are toolchain constraints rather
  ## than taste, and each was bisected on 2026-08-30 against
  ## `seqimpl.nim(167): i < s.len and 0 <= i`:
  ##
  ## * appending to a `List` reached through a `var` parameter, while a second
  ##   `List` is also passed by value to the same call, faulted; appending to a
  ##   `var seq[string]` in the same position does not. Hence `kept`'s type.
  ## * `raw(items.at(i))` faulted: `at` takes its `List` by value, so the
  ##   `JsonRef` it hands back points into a copy that `raw`'s `substr` then
  ##   indexes after it has gone. Everything below therefore reads ONE owned
  ##   string, `blob`, which is the pattern the rest of this file already uses.
  ##
  ## Exported because the selftest asserts on it directly.

  # Everything below reads ONE owned string. `raw(items.at(i))` -- a `List.at`
  # feeding `raw` -- faulted in `seqimpl.nim(167): i < s.len and 0 <= i` on this
  # nimony: `at` takes its `List` by value, so the `JsonRef` it returns points at
  # a copy that is already gone by the time `raw` calls `substr`. Bisected
  # 2026-08-30; the identical loop returning before the `raw` call did not fault.
  # `text(items)` once, held in a local, is the pattern the rest of this file
  # uses and it is stable.
  let blob = text(items)
  let doc = whole(blob)
  let n = count(doc)

  var ids: seq[string] = @[]
  var tpls: seq[string] = @[]
  var raws: seq[string] = @[]
  for i in 0 ..< n:
    let one = at(doc, i)
    ids.add one.field("_id").asText("")
    tpls.add one.field("_tpl").asText("")
    raws.add raw(one)

  var drop: seq[bool] = @[]
  for i in 0 ..< n:
    drop.add false
  var taken: seq[string] = @[]   ## "<parentId>\x1f<slot>" already filled

  for i in 0 ..< n:
    let one = at(doc, i)
    let parent = one.field("parentId").asText("")
    let slot = one.field("slotId").asText("")
    if parent.len == 0 or slot.len == 0:
      continue
    let tpl = tpls[i]
    # What KIND of weapon this bot got, counted here because this loop already
    # holds every item and its slot. A weapon is never a drop candidate, so
    # counting before the drops is the same number as counting after. Only the
    # three weapon-bearing equipment slots are looked up, so this is at most
    # three template reads per bot, not one per item.
    if isWeaponSlot(slot):
      let wc = toLowerAscii(itemMember(tpl, "_props").field("weapClass").asText(""))
      if wc.len > 0:
        inc gWeapons
        if wc == "shotgun":
          inc gShotguns
    var parentTpl = ""
    for k in 0 ..< ids.len:
      if ids[k] == parent:
        parentTpl = tpls[k]
        break
    if parentTpl.len == 0:
      inc gSlotUnknown
      continue
    case judgeSlot(parentTpl, slot, tpl)
    of svUnknown:
      inc gSlotUnknown
    of svGrid:
      discard
    of svBad:
      drop[i] = true
      if isModSlot(slot):
        inc gModRefused
      noteDrop("refused", parentTpl, tpl, slot)
      report.add "slot refused: " & tpl & " -> " & slot & " on " & parentTpl
    of svOk:
      let key = parent & "\x1f" & toLowerAscii(slot)
      if key in taken:
        drop[i] = true
        inc gSlotDup
        noteDrop("duplicate", parentTpl, tpl, slot)
        report.add "slot already filled: " & tpl & " -> " & slot &
                   " on " & parentTpl
      else:
        taken.add key

  # Anything hanging off a dropped item goes with it, to a fixpoint -- a mag left
  # parented to a removed weapon is the same dangling-id crash by another name.
  var changed = true
  while changed:
    changed = false
    for i in 0 ..< n:
      if drop[i]:
        continue
      let parent = at(doc, i).field("parentId").asText("")
      if parent.len == 0:
        continue
      for j in 0 ..< ids.len:
        if drop[j] and ids[j] == parent:
          drop[i] = true
          changed = true
          noteDrop("descendant", tpls[j], tpls[i],
                   at(doc, i).field("slotId").asText(""))
          break

  var removed = 0
  for i in 0 ..< n:
    if drop[i]:
      removed = removed + 1
    else:
      kept.add raws[i]
  gSlotDropped = gSlotDropped + removed
  result = removed

proc auditStacks*(items: List; flat: var seq[string]): int =
  ## Reads a FINISHED bot inventory back and returns how many stackable items
  ## were served as a stack of one or fewer.
  ##
  ## This is the check the last money fix did not have. That fix asserted its own
  ## write ("I called `setNumber(upd, ...)`"), which is a check that cannot fail
  ## (CLAUDE.md 9b). This one asserts the finished state, as a negative: of the
  ## items in the payload whose TEMPLATE declares `_props.StackMaxRandom`, none
  ## may carry `upd.StackObjectsCount` missing or <= 1. A regression anywhere
  ## between the roll and the wire -- a dropped `upd`, an `upd` overwritten by a
  ## later `setRaw`, a template whose range vanished from the database -- shows
  ## up here, because the only thing consulted is the serialised text.
  ##
  ## Ammunition inside a magazine is deliberately IN scope: a chambered round is
  ## legitimately a stack of one, but it is written by `chamberRounds` with an
  ## explicit count, and a magazine filled with one round is a bug of the same
  ## family. `flat` names the offenders (`<tpl> in <slotId>`) so the counter line
  ## can say which template, not just how many.
  ##
  ## Same `text(items)`-once discipline as `validateSlots`, and for the same
  ## measured reason: `raw(items.at(i))` faults on this nimony.
  let blob = text(items)
  let doc = whole(blob)
  let n = count(doc)
  result = 0
  for i in 0 ..< n:
    let one = at(doc, i)
    let tpl = one.field("_tpl").asText("")
    if tpl.len == 0:
      continue
    # The template's own declaration is the discriminator, exactly as in
    # `randomStackCount` -- never a hardcoded currency list, which would go stale
    # the moment the database gains a currency.
    # `itemMember`, not `itemProp`: it honours the test fixture, so this check
    # also runs under `aowl selfcheck`, which has NO database loaded. A check
    # that cannot run is not a check. `_props` is fetched whole and then
    # traversed, because the fixture seam matches a member name literally and
    # would read a dotted path as one key.
    let hi = itemMember(tpl, "_props").field("StackMaxRandom")
    if not hi.found:
      continue
    inc gStackAudited
    let cnt = one.field("upd").field("StackObjectsCount").asInt(0)
    if cnt <= 1:
      inc gStackFlat
      result = result + 1
      if flat.len < 8:
        flat.add tpl & " in " & one.field("slotId").asText("(grid)") &
                 " count=" & $cnt
    else:
      gStackSum = gStackSum + cnt

proc auditInternalMags*(items: List; flat: var seq[string]): int =
  ## Reads a FINISHED bot inventory back and returns how many INTERNAL magazines
  ## are sitting somewhere other than a `mod_magazine` slot.
  ##
  ## This is the falsifiable form of "the shotgun bug is fixed". It asserts a
  ## property of the serialised payload, as a negative -- *no served item whose
  ## template declares `ReloadMagType: InternalMagazine` has a `slotId` other
  ## than `mod_magazine`* -- rather than re-reading the branch that skipped the
  ## spare. It fails if the spare path regresses, if the loose-loot path
  ## regresses, if a third path is added that neither knows about, or if the
  ## user turns the row back on; the negative control in `selfCheckBots` plants
  ## exactly one such item and requires this to come back 1.
  ##
  ## A tube fitted to its own weapon (`mod_magazine`) is legitimate and is NOT
  ## counted -- that is the gun working. Only the copies are.
  ##
  ## `itemMember`, not `dbRead`, so it honours the fixture and therefore runs
  ## under `aowl selfcheck`, which has no database. Same `text(items)`-once
  ## discipline as `validateSlots`; `raw(items.at(i))` faults on this nimony.
  let blob = text(items)
  let doc = whole(blob)
  let n = count(doc)
  result = 0
  for i in 0 ..< n:
    let one = at(doc, i)
    let tpl = one.field("_tpl").asText("")
    if tpl.len == 0:
      continue
    let rmt = itemMember(tpl, "_props").field("ReloadMagType")
    if not rmt.found:
      continue
    if toLowerAscii(rmt.asText("")) != "internalmagazine":
      continue
    let slot = toLowerAscii(one.field("slotId").asText(""))
    if slot == "mod_magazine":
      continue
    # The LIVE counter is NOT touched here. MEASURED 2026-09-05: it was, so
    # the self-check's planted tube (below) counted as a served bug at every
    # backend start, and the census line said `served loose: 2 -- FAIL, this
    # must be zero` on every raid of every boot regardless of what was served
    # -- a check that always fails is as blind as one that cannot. The live
    # call site adds this proc's return value; the self-check asserts the
    # counter did not move.
    result = result + 1
    if flat.len < 8:
      flat.add tpl & " in " & (if slot.len == 0: "(grid)" else: slot)

proc botGuardCounters*(): string =
  ## The one line a live raid gets to say what happened, instead of nothing.
  "bots: chambered " & $gChambered & ", chamber-skipped " & $gChamberSkipped &
  " (no accepted round), slot-dropped " & $gSlotDropped &
  " (mod-filter-refused: " & $gModRefused & ", slot-dup: " & $gSlotDup & ")" &
  ", weapons " & $gWeapons & " (shotguns: " & $gShotguns &
  (if gShotguns == 0: " -- INCONCLUSIVE for the shotgun check" else: "") & ")" &
  ", loose-mags-refused " & $gLooseMagRefused &
  ", internal-mag copies suppressed " & $gInternalMagSuppressed &
  " (served loose: " & $gInternalMagServed &
  (if gInternalMagServed > 0: " -- FAIL, this must be zero" else: "") & ")" &
  ", required slots " & $gRequiredFound & " (backfilled " &
  $gRequiredBackfilled & ", UNFILLABLE " & $gRequiredUnfillable.len &
  (if gRequiredUnfillable.len > 0:
     " -- FAIL, this must be zero: " & gRequiredUnfillable[0]
   else: "") & ")" &
  ", slot-unjudged " & $gSlotUnknown &
  ", stackable " & $gStackAudited & " (flat<=1: " & $gStackFlat &
  ", avg " & (if gStackAudited > gStackFlat:
                $(gStackSum div (gStackAudited - gStackFlat))
              else: "n/a") & ")" &
  (if gSlotDropped > 0: ", top drops (count rule|parent|child|slot):" &
                        botDropHistogram(10)
   else: "")

proc addLoadout(t: BotTables; items: var List; equipmentId: string;
                r: var Rng) =
  ## Everything the bot is wearing and carrying, slot by slot.
  if not t.ok:
    return
  let inv = field(t.raw, "inventory")
  if not inv.found:
    return
  let chances = field(t.raw, "chances")
  # Read once for this bot, off the batch-cached object: the family the role
  # belongs to decides which pair of family rows applies.
  let g = botGear()
  let fam = familyOf(t.role)
  # Published for the picks further down the call chain (ammo inside a magazine,
  # armour out of an equipment pool) that have no way to be handed a role.
  gFam = fam
  let equipment = inv.field("equipment")
  if not equipment.found:
    return
  var weaponBudget = MaxWeaponModsPerBot
  var gearBudget = MaxGearModsPerBot
  # The magazine models the weapons took, so spares of them can be added to the
  # rig once the rig is known to exist.
  var spares: seq[SpareMag] = @[]
  let slots = equipmentSlots()
  # The containers that got filled, remembered as they are placed: loot goes in
  # after every slot is decided, because a bot's rig has to *exist* before there
  # is anywhere to put anything, and the equipment roll is what decides that.
  var carried: seq[Container] = @[]
  ## Every weapon this bot ends up holding, so that loose loot can be told which
  ## magazines are its own. Collected as the slots are decided, because the
  ## loot pass runs after all of them.
  var weaponTpls: seq[string] = @[]
  var gotPockets = false
  for slot in slots:
    let pool = equipment.field(slot)
    if not pool.found:
      continue
    # Bots > Gear. global x family x slot, all three defaulting to 1.0, and
    # `scalePercent` returns its input unchanged at exactly 1.0 -- so an
    # untouched page draws the same slot with the same roll as before.
    let pct = scalePercent(chanceFor(chances, "equipment", slot, 100),
                           gearMultiplier(g, fam, slot))
    if pct <= 0:
      continue
    if pct < 100 and not chance(r, float(pct) / 100.0):
      continue
    # Bots > Quality > Armour tier. At the default 0.0 this is `pickTemplate`
    # itself, one draw, same stream. `armorClass` is declared by helmets, rigs
    # and body armour and by nothing else, so on a weapon or an armband pool it
    # normalises to a constant and does nothing -- which is why one row can
    # cover every slot without a table of which slots are armour.
    let tpl = pickTemplateBiased(pool, r, "armorClass", armorBiasFor(g, fam))
    if tpl.len == 0:
      continue
    # The worn item itself is never refused for want of a mod budget. There are
    # fourteen of these and the list is written out above, so they are bounded
    # by their own count -- it was the mod tree that needed bounding, and gating
    # the slot on it is what turned "this helmet has a lot of attachments" into
    # "this bot has no rifle".
    let itemId = newId()
    items.add botItem(itemId, tpl, equipmentId, slot)
    if slot == "Pockets":
      gotPockets = true
    if slot == "TacticalVest" or slot == "Pockets" or slot == "Backpack":
      carried.add openContainer(itemId, slot, tpl)
    if isWeaponSlot(slot):
      weaponTpls.add tpl
      addMods(t, inv, chances, items, itemId, tpl, true, r, weaponBudget, spares)
    else:
      addMods(t, inv, chances, items, itemId, tpl, false, r, gearBudget, spares)

  # Pockets is the one slot that is not allowed to come out empty.
  #
  # Every other slot is a roll: a bot with no helmet is a bot with no helmet.
  # `Pockets` is different because the client dereferences it unconditionally --
  # `EFT.Player::HasMarkOfUnknown` reads `Equipment.Slots[8].ContainedItem` and
  # throws NullReference when it is null, and `BotsGroup..ctor` runs that over
  # every player in the raid while the bot is being activated. A bot whose
  # pockets roll failed does not spawn without pockets; it does not spawn at
  # all, and takes the activation with it. So a database that names no pockets
  # pool, or a chance roll that came up short, still gets pockets.
  if not gotPockets:
    let pocketsId = newId()
    items.add botItem(pocketsId, PocketsTpl, equipmentId, "Pockets")
    carried.add openContainer(pocketsId, "Pockets", PocketsTpl)

  # Spare magazines go in before loose loot does, so a full `vestLoot` table
  # cannot leave a rifleman with no reload -- the ammo is what makes the bot a
  # threat, and the trinkets can have whatever room is left.
  addSpareMags(inv, items, carried, spares, r)

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
  # The richness knob also raises the per-bot loot BOUND when it is above one,
  # or the extra items the multiplier asks for would have nowhere in the budget
  # to go -- the cap stays a cap (5x at most), it just tracks the setting.
  # The Bot AI mod's database-published richness, THEN the settings page's
  # global x family multiplier on top of it. Two owners, one number, and the
  # order is stated: the page scales whatever the Bot AI mod published rather
  # than replacing it, so neither control silently wins.
  let richness = lootRichness() * lootMultiplier(g, fam)
  # The magazines that actually fit a weapon this bot is carrying. The loot
  # tables are slot-blind -- a plain scav's `TacticalVest` pool is 150 entries
  # of which 39 are magazines of arbitrary caliber -- so `addContainerLoot`
  # needs this set to refuse a drum beside a tube-fed shotgun. Computed from
  # the weapons, so it is unaffected by either richness owner above.
  let fittingMags = magazinesFitting(weaponTpls)
  let cap = g.maxLootPerBot
  var lootBudget = cap
  if richness > 1.0:
    lootBudget = int(float(cap) * richness)
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
    addContainerLoot(inv, generation, items, c, kind, r, share, richness,
                     fittingMags)
    lootBudget = lootBudget - (had - share)

# ---------------------------------------------------------------------------
# The instrument: a hash of the FINISHED loadout, at a stated seed
# ---------------------------------------------------------------------------
#
# The claim this exists to settle is "defaults reproduce current behaviour
# exactly". Before this, that claim was true BY CONSTRUCTION -- every new path
# early-returns at its default -- and by-construction is an argument, not a
# measurement. An argument cannot fail, and §9b says a check that cannot fail is
# the bug.
#
# So: generate a loadout at a stated seed, canonicalise it, hash it. Same seed
# and defaults across two builds must give the same number; moving ONE knob must
# give a different one. The second half is what proves the first half could have
# failed.
#
# **Ids are stripped, deliberately.** `newId()` counts from a run number that
# comes out of the store, so the ids in two runs of the same build differ and a
# digest over them would report a difference every single time -- a check that
# always fails is as useless as one that always passes. What is hashed is the
# SHAPE: for each item in emission order, its template, its slot, the ORDINAL of
# its parent within the same payload, and its stack count. That is exactly the
# thing the generator decides and the RNG stream governs.

proc canonicalLoadout*(items: List): string =
  ## The generated loadout as id-free text, one line per item, in emission
  ## order. Same `text(items)`-once discipline as `auditInternalMags` --
  ## `raw(items.at(i))` faults on this nimony.
  let blob = text(items)
  let doc = whole(blob)
  let n = count(doc)
  var ids: seq[string] = @[]
  for i in 0 ..< n:
    ids.add at(doc, i).field("_id").asText("")
  result = ""
  for i in 0 ..< n:
    let one = at(doc, i)
    let parent = one.field("parentId").asText("")
    var pidx = -1
    for k in 0 ..< ids.len:
      if ids[k] == parent:
        pidx = k
        break
    # -1 for the equipment root, whose parent is the bot's own inventory id and
    # is not itself an item. Not an error and not skipped: it is a real line and
    # it anchors the ordinals.
    result = result & $i & "|" & one.field("_tpl").asText("") & "|" &
             one.field("slotId").asText("") & "|" & $pidx & "|" &
             $one.field("upd").field("StackObjectsCount").asInt(-1) & "\n"

proc loadoutDigest*(t: BotTables; seed: string; n: int; into: var int): string =
  ## `n` loadouts for one role at one seed, hashed together.
  ##
  ## The RNG is seeded from `seed & ":" & $i` -- an EXPLICIT string, not the
  ## bot's id -- so the stream is a function of the caller's argument and
  ## nothing else. `into` comes back with the number of items hashed, which is
  ## the INCONCLUSIVE detector: a digest over zero items is a stable hash of the
  ## empty string and would agree with itself forever.
  into = 0
  # Forced, not lazy. `botGear()` loads once per process and the caller of this
  # is a tool flipping one knob between two calls -- a cached config would make
  # the "one knob changes the hash" half of the proof silently unable to fail.
  refreshBotGear()
  var acc = ""
  for i in 0 ..< n:
    var r = seededRng(seed & ":" & $i)
    var items = newList()
    # A literal equipment root id rather than `newId()`, for the same reason the
    # ids are stripped: the digest must not move because the store's run number
    # advanced.
    items.add botItem("digestequipmentroot0000", "root", "digestowner00000000000", "")
    addLoadout(t, items, "digestequipmentroot0000", r)
    let canon = canonicalLoadout(items)
    into = into + items.len
    acc = acc & canon
  result = $hashText(acc)

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

proc botSideForRole(role: string): string =
  ## The `Info.Side` a role spawns on. Read off the role name because that is
  ## the only thing the client hands us: a PMC wave asks for `pmcUSEC`/`pmcBEAR`,
  ## and a bot generated for one has to come back on the `Usec`/`Bear` side or
  ## the client counts it as a scav -- the whole point of spawning PMCs.
  ##
  ## Everything not named here is `Savage`, which is the honest default: a scav,
  ## a boss and his followers, the cultists and the infected all fight as
  ## Savage. `pmcBot` stays `Bear` as it was, and `exUsec` (the Rogues) is
  ## Savage in this generation of the game, not a PMC.
  case toLowerAscii(role)
  of "pmcusec", "usec": "Usec"
  of "pmcbear", "bear", "pmcbot": "Bear"
  else: "Savage"

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
  setText(info, "Side", botSideForRole(req.role))
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

  # Nothing reaches the client without passing this. A bot served without an
  # extra is a bot; a bot served with a placement `FlatItemsToTree` refuses is a
  # dead raid load.
  var violations: seq[string] = @[]
  var survivors: seq[string] = @[]
  let removed = validateSlots(items, violations, survivors)
  if removed > 0:
    var cleaned = newList()
    for s in survivors:
      cleaned.add s
    items = cleaned
    if removed > 6:
      # A validator that quietly discards a whole loadout is the silent-success
      # failure this file keeps producing. Six is above any plausible number of
      # genuinely bad placements on one bot and far below a stripped one.
      aowlspt.warn("bots: WARN dropped " & $removed & " placement(s) from ONE " &
                   "bot -- that is a stripped loadout, not a stray extra: " &
                   violations[0])
    else:
      aowlspt.warn("bots: dropped " & $removed &
                   " invalid placement(s) from a bot: " & violations[0])

  # And the money check, on the list that is about to be serialised into the
  # response -- after the validator, so it audits exactly what the client gets.
  # Warn once per bot with the offending template named: "the scavs spawn with a
  # single dollar" was reported live, and the counter line alone would have said
  # nothing at all about it.
  var flatStacks: seq[string] = @[]
  let flatN = auditStacks(items, flatStacks)
  if flatN > 0:
    aowlspt.warn("bots: WARN " & $flatN & " stackable item(s) served with " &
                 "StackObjectsCount <= 1 -- currency/ammo rolled flat: " &
                 flatStacks[0])

  # The shotgun check, on the same about-to-be-serialised list and for the same
  # reason: a fixed tube or cylinder carried as a spare is the reported bug, and
  # the only place it can be seen for certain is the finished payload.
  var looseTubes: seq[string] = @[]
  let tubeN = auditInternalMags(items, looseTubes)
  gInternalMagServed = gInternalMagServed + tubeN
  if tubeN > 0:
    aowlspt.warn("bots: WARN " & $tubeN & " internal magazine(s) served " &
                 "outside mod_magazine -- a fixed tube/cylinder carried as a " &
                 "spare, which is the shotgun-with-two-drums report: " &
                 looseTubes[0])

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
  ##
  ## Offline PMCs are NOT produced here. Server-side conversion of a fraction of
  ## an `assault` batch into `pmcUSEC`/`pmcBEAR` profiles was tried and PROVEN
  ## inert live (2026-08-30): the client sets a spawned bot's `Side` from the
  ## ROLE it requested for the wave, not from the `Info.Side` of the profile it
  ## is handed, so a converted PMC in an `assault` batch still spawns Savage.
  ## PMCs are produced instead by emitting real `pmcUSEC`/`pmcBEAR` waves that
  ## can place -- see `emu/raid.offlineScavWaves` and the `BotPmc` spawn-point
  ## sides in `post1/locations.json`. This proc simply honours whatever role the
  ## client asks for.
  generated = 0
  # Once per batch, before any bot is built: an edit made on the settings page
  # between two raids is in force for the next one without a restart.
  refreshBotGear()
  var out1 = arr()
  let requests = parseRequests(body)
  # Diagnostic: make the requested role/limit/difficulty visible. The backend
  # logs only "REQ POST /client/game/bot/generate" with no body, so before this
  # there was no way to see what role the client actually asked for -- exactly
  # the gap that made the offline-PMC problem hard to see. This is how the wave
  # approach is confirmed: a `Role=pmcUSEC` line here proves the client acted on
  # a placeable PMC wave.
  for req in requests:
    info "bot/generate request: Role=" & req.role & " Limit=" & $req.count &
         " Difficulty=" & req.difficulty
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
  # One line per batch saying what the loadout guards actually did. Before this,
  # a chamber that declined and a placement the client would refuse were both
  # perfectly silent; the refusal only surfaced 28 times over, in the CLIENT's
  # error log, after the raid load had already died.
  # THE PLANTING ROUND-TRIP for bots. Emitted with what the CLIENT asked for
  # in front of the planter, and answered synchronously; with no planter
  # subscribed `composeBots` returns an empty seq and the batch below is
  # byte-identical to the one above.
  let groups = composeBots(currentMap(), currentRaidId(), 0,
                           raw(field(body, "conditions")))
  for g in groups:
    let gTables = loadTables(g.role)
    var k = 0
    while k < g.count:
      var one = parseObject(generateProfile(gTables, base,
                    BotRequest(role: g.role, difficulty: "normal",
                               count: g.count), k))
      if one.ok:
        if k < g.names.len and g.names[k].len > 0:
          var pInfo = parseObject(get(one, "Info"))
          if pInfo.ok:
            setText(pInfo, "Nickname", g.names[k])
            setRaw(one, "Info", text(pInfo))
        out1.add raw(text(one))
        generated = generated + 1
      k = k + 1
  info botGuardCounters()
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

const ChkItems = """{
  "wpn": {"_props": {
    "Chambers": [{"_name": "patron_in_weapon",
                  "_props": {"filters": [{"Filter": ["ammoOk"]}]}}],
    "Slots": [{"_name": "mod_magazine",
               "_props": {"filters": [{"Filter": ["mag"]}]}}]}},
  "mag": {"_props": {
    "Cartridges": [{"_name": "cartridges",
                    "_props": {"filters": [{"Filter": ["ammoOk"]}]}}]}},
  "rig": {"_props": {"Grids": [{"_name": "main",
                                "_props": {"cellsH": 4, "cellsV": 4}}]}},
  "ammoOk": {"_props": {}},
  "ammoNo": {"_props": {}},
  "eqroot": {"_props": {"Slots": [
    {"_name": "Headwear",
     "_props": {"filters": [{"Filter": ["helmetClass"],
                             "ExcludedFilter": ["helmetBanned"]}]}}]}},
  "helmetClass": {"_props": {}},
  "helmetReal": {"_parent": "helmetClass", "_props": {"Slots": [
    {"_name": "mod_nvg", "_props": {"filters": [{"Filter": ["nvg"]}]}}]}},
  "helmetBanned": {"_parent": "helmetClass", "_props": {}},
  "nvg": {"_props": {}},
  "notHelmet": {"_props": {}},
  "magClass": {"_props": {}},
  "tubemag": {"_parent": "magClass",
              "_props": {"ReloadMagType": "InternalMagazine"}},
  "drummag": {"_parent": "magClass",
              "_props": {"ReloadMagType": "ExternalMagazine"}},
  "shotgun": {"_props": {"weapClass": "shotgun", "Slots": [
    {"_name": "mod_magazine",
     "_props": {"filters": [{"Filter": ["tubemag", "magClass"]}]}}]}}
}"""
  ## `shotgun`'s magazine filter names `tubemag` AND the class `magClass`, which
  ## is the input that TELLS THE TWO RULES APART: the ancestry rule accepts
  ## `drummag` through its `_parent`, the exact rule does not. Shipped data has
  ## no such weapon-mod filter (measured: 0 of 2,897 name a class), so this is a
  ## synthetic worst case on purpose -- a fixture that both rules answer the
  ## same way would be a check that cannot fail.
  ## A five-template item table shaped exactly like the real one at the members
  ## the validator reads: a weapon with one chamber and one magazine slot, each
  ## with a filter; a magazine with a `Cartridges` filter; a rig with a grid.
  ## `ammoNo` is a real cartridge template that NO filter names -- the stand-in
  ## for the caliber-conversion case a filter check exists to catch.

proc slotItem(id, tpl, parent, slot: string): string =
  var d = newDoc()
  setText(d, "_id", id)
  setText(d, "_tpl", tpl)
  if parent.len > 0:
    setText(d, "parentId", parent)
    setText(d, "slotId", slot)
  result = text(d)

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
  # Force a real read of the whole Bot gear/loot page before the fixture pass,
  # so the ledger in `emu/knobs` records what THIS generation actually asked
  # for. Without it the lazy path would serve a default object and the ledger
  # would show nothing read -- which the ledger reports as INCONCLUSIVE, not as
  # a pass, but a check that is always inconclusive is no better than one that
  # always passes.
  refreshBotGear()
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

  # 7. The slot validator, over a fixture item table.
  #
  #    This asserts a property of the FINISHED item list -- "no surviving item
  #    violates its parent slot" -- and never of any writer's own intent, which
  #    is the shape of check that caught nothing here for six weeks. Every case
  #    below was FALSIFIED first: with `validateSlots` stubbed to `return 0`,
  #    cases (b)..(e) all report, naming the weapon and the cartridge.
  setSlotFixture(ChkItems)
  block:
    var v = newList()
    v.add slotItem("w1", "wpn", "", "")                    # the weapon
    v.add slotItem("a1", "ammoOk", "w1", "patron_in_weapon")   # (a) legal
    v.add slotItem("a2", "ammoOk", "w1", "patron_in_weapon")   # (b) DUPLICATE
    v.add slotItem("w2", "wpn", "", "")                        # a second weapon
    v.add slotItem("a3", "ammoNo", "w2", "patron_in_weapon")   # (c) refused
    # (c) hangs off `w2`, not `w1`, ON PURPOSE. Parented to `w1` it was ALSO a
    # duplicate, so rule 3 caught it and rule 2 was never exercised -- with
    # `filterAccepts` stubbed to `return true` the whole check still passed
    # GREEN. That is exactly the check-that-cannot-fail this file keeps
    # producing; on its own chamber, disabling the filter check turns it RED.
    v.add slotItem("a4", "ammoOk", "w1", "mod_nonexistent")    # (d) no slot
    v.add slotItem("m1", "mag", "w1", "mod_magazine")          # legal
    v.add slotItem("c1", "ammoOk", "m1", "cartridges")         # legal
    v.add slotItem("r1", "mag", "rig1", "main")                # a grid cell
    v.add slotItem("r2", "mag", "nosuchparent", "main")        # unjudgeable
    v.add slotItem("x1", "mag", "a4", "mod_magazine")          # (e) orphan of d
    v.add slotItem("rig1", "rig", "", "")
    # The inheritance cases. Stock equipment slots filter by BASE CLASS id, not
    # by concrete template (`Headwear` on the equipment root names exactly one
    # entry, the Headwear class), so an exact-membership test refuses every real
    # helmet. Each of the three below fails for its OWN rule alone:
    v.add slotItem("eq1", "eqroot", "", "")
    v.add slotItem("h1", "helmetReal", "eq1", "Headwear")   # (f) via _parent
    v.add slotItem("n1", "nvg", "h1", "mod_nvg")            # (g) mod under (f)
    v.add slotItem("h2", "notHelmet", "eq1", "Headwear")    # (h) genuinely wrong
    v.add slotItem("h3", "helmetBanned", "eq1", "Headwear") # (i) ExcludedFilter
    # The reported bug, as a fixture. `sg1` is a tube-fed shotgun whose
    # `mod_magazine` filter names exactly ONE concrete tube extension; `tubemag`
    # and `drummag` are siblings under the same `magClass` ancestor, which is
    # what EVERY magazine in the shipped database shares. Under the ancestry
    # rule (f)'s generalisation reached here too and (k) was ACCEPTED -- a drum
    # magazine bolted to a single-fed shotgun, which is what the player saw.
    # (j) must still survive, or the fix has merely broken magazines.
    v.add slotItem("sg1", "shotgun", "", "")
    v.add slotItem("sm1", "tubemag", "sg1", "mod_magazine")  # (j) legal, exact
    v.add slotItem("sg2", "shotgun", "", "")
    v.add slotItem("sm2", "drummag", "sg2", "mod_magazine")  # (k) class-only
    # (k) hangs off a SECOND shotgun, not off `sg1`, for the same reason (c)
    # hangs off `w2`: parented to `sg1` it would also be a duplicate, the
    # duplicate rule would drop it, and stubbing the exact rule back to the
    # ancestry rule would leave this check GREEN. On its own weapon it goes RED.
    #
    # (h) is in the fixture so that "walk the parent chain" cannot degrade into
    # "accept anything"; (i) so that ExcludedFilter is still consulted along the
    # chain. (h) and (i) hang off `eq1` alongside (f), which is legal only
    # because a REFUSED item never takes the slot -- if it did, (h)/(i) would be
    # caught by the duplicate rule and the filter rule would go unexercised,
    # which is exactly how rule 2 hid behind rule 3 above.

    var report: seq[string] = @[]
    var survivors: seq[string] = @[]
    let removed = validateSlots(v, report, survivors)
    var out2 = newList()
    for s in survivors:
      out2.add s

    # STRICT parse of the finished list -- not a substring test. A payload that
    # is not JSON must not be able to pass this.
    let survivorText = text(out2)
    let parsed = parseArray(whole(survivorText))
    if not parsed.ok:
      into.add "bots: validateSlots produced something that is not a JSON array"
    if removed != 7:
      into.add "bots: validateSlots removed " & $removed &
               " item(s); the fixture plants exactly 7 (duplicate chamber, " &
               "filtered-out cartridge, undeclared slot, orphan of the " &
               "undeclared slot, an item of the wrong class, an item its " &
               "slot's ExcludedFilter names, a drum magazine on a tube-fed " &
               "shotgun)"
    var survived: seq[string] = @[]
    for i in 0 ..< parsed.len:
      survived.add parsed.at(i).field("_id").asText("")
    for bad in ["a2", "a3", "a4", "x1", "h2", "h3", "sm2"]:
      if bad in survived:
        into.add "bots: an invalid placement (" & bad & ") survived the " &
                 "validator -- this is the placement FlatItemsToTree refuses"
    for good in ["w1", "w2", "a1", "m1", "c1", "r1", "r2", "rig1",
                 "eq1", "h1", "n1", "sg1", "sg2", "sm1"]:
      if good notin survived:
        into.add "bots: the validator removed a LEGAL placement (" & good &
                 "); serving a bot without its gear is not the fix"
    var named = false
    for line in report:
      # "slot refused", specifically -- a "slot already filled" line also names
      # both, and accepting it is how rule 2 hid behind rule 3.
      if find(line, "slot refused") >= 0 and find(line, "ammoNo") >= 0 and
         find(line, "wpn") >= 0:
        named = true
    if not named:
      into.add "bots: the validator's report does not name the offending " &
               "template and weapon, so a live failure says nothing"

  block internalMags:
    # 7b. The reported shotgun bug, as a finished-state assertion WITH ITS OWN
    #     NEGATIVE CONTROL.
    #
    #     The measured cause is not an illegal placement -- every shotgun
    #     `mod_magazine` pool in this install's database is 100 per cent inside
    #     the weapon's own Filter, so the validator above has nothing to say
    #     about it. The cause is DUPLICATION: `SparesPerWeapon` copies of a
    #     FIXED tube or cylinder placed in a carried container, which is exactly
    #     the two circular magazines the player counted.
    #
    #     So the check is on the payload, phrased as a negative: no served item
    #     whose template says `InternalMagazine` may sit anywhere but
    #     `mod_magazine`. `good` is the same tube fitted to its own gun and must
    #     NOT be counted, or the check would "pass" by counting everything and
    #     "fail" by counting nothing. `bad` is the deliberate injection.
    let servedBefore = gInternalMagServed
    var clean = newList()
    clean.add slotItem("sg1", "shotgun", "", "")
    clean.add slotItem("sm1", "tubemag", "sg1", "mod_magazine")   # legitimate
    clean.add slotItem("rig1", "rig", "", "")
    clean.add slotItem("d1", "drummag", "rig1", "main")           # legitimate
    var cleanFlat: seq[string] = @[]
    let cleanN = auditInternalMags(clean, cleanFlat)
    if cleanN != 0:
      into.add "bots: auditInternalMags counted " & $cleanN &
               " on a CLEAN list -- a tube fitted to its own weapon and an " &
               "external drum in a rig are both legal, and a check that " &
               "flags them flags every bot in the game"

    # The negative control. One tube, in a rig cell. If this comes back 0 the
    # audit is a check that cannot fail, and the whole fix is unverified.
    var dirty = newList()
    dirty.add slotItem("sg1", "shotgun", "", "")
    dirty.add slotItem("sm1", "tubemag", "sg1", "mod_magazine")
    dirty.add slotItem("rig1", "rig", "", "")
    dirty.add slotItem("bad1", "tubemag", "rig1", "main")   # INJECTED: the bug
    var dirtyFlat: seq[string] = @[]
    let dirtyN = auditInternalMags(dirty, dirtyFlat)
    if dirtyN != 1:
      into.add "bots: the negative control failed -- an internal magazine was " &
               "planted loose in a rig and auditInternalMags returned " &
               $dirtyN & " rather than 1, so the shotgun check cannot fail " &
               "and proves nothing"
    if gInternalMagServed != servedBefore:
      into.add "bots: the self-check's planted tube LEAKED into the live " &
               "served-loose counter (" & $servedBefore & " -> " &
               $gInternalMagServed & "), so the census line would report " &
               "FAIL on every raid on the strength of this fixture alone"
    var namedTube = false
    for line in dirtyFlat:
      if find(line, "tubemag") >= 0:
        namedTube = true
    if not namedTube:
      into.add "bots: auditInternalMags does not name the offending template, " &
               "so a live failure says which count but not which item"

  block moneyStacks:
    # The live report was "the scavs spawn with a single dollar". The generator
    # already rolls a stack; what was missing is a check that could SAY it did
    # not. This exercises the detector against a payload that contains the bug,
    # so the detector itself cannot be a check that only says yes.
    setSlotFixture("{" &
      "\"dollars\": {\"_props\": {\"StackMinRandom\": 45, " &
                                 "\"StackMaxRandom\": 100}}," &
      "\"medkit\": {\"_props\": {\"Width\": 1}}}")
    let savedAudited = gStackAudited
    let savedFlat = gStackFlat
    let savedSum = gStackSum
    var money = newList()
    money.add "{\"_id\":\"k1\",\"_tpl\":\"dollars\",\"slotId\":\"Pockets\"," &
              "\"upd\":{\"StackObjectsCount\":73}}"
    money.add "{\"_id\":\"k2\",\"_tpl\":\"dollars\",\"slotId\":\"Pockets\"}"
    money.add "{\"_id\":\"k3\",\"_tpl\":\"dollars\",\"slotId\":\"Pockets\"," &
              "\"upd\":{\"StackObjectsCount\":1}}"
    money.add "{\"_id\":\"k4\",\"_tpl\":\"medkit\",\"slotId\":\"Pockets\"}"

    # STRICT parse first: the backend selftest once asserted with substring
    # `contains`, so a payload that was not JSON at all passed for months.
    let moneyText = text(money)
    let moneyDoc = parseArray(whole(moneyText))
    if not moneyDoc.ok:
      into.add "bots: the money fixture is not a JSON array"

    var flat: seq[string] = @[]
    let flatN = auditStacks(money, flat)
    if flatN != 2:
      into.add "bots: auditStacks found " & $flatN & " flat stack(s); the " &
               "fixture plants exactly 2 (a currency item with NO upd, and " &
               "one with StackObjectsCount 1) and one legitimate stack of 73"
    if gStackAudited - savedAudited != 3:
      into.add "bots: auditStacks audited " & $(gStackAudited - savedAudited) &
               " item(s); it must audit the 3 that declare StackMaxRandom and " &
               "NOT the medkit -- a detector that counts every item would " &
               "report every bot as broken"
    var namedTpl = false
    for line in flat:
      if find(line, "dollars") >= 0:
        namedTpl = true
    if not namedTpl:
      into.add "bots: auditStacks does not name the offending template, so a " &
               "live warning says nothing more than the counter already does"
    gStackAudited = savedAudited
    gStackFlat = savedFlat
    gStackSum = savedSum
  setSlotFixture("")

  result = into.len == before
