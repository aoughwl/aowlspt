## The bot GEAR and BOT LOOT control surface.
##
## ## What this is, and what it deliberately is not
##
## `emu/bots` assembles a bot out of the database's own tables: `inventory`
## (the pools), `chances` (the percentage each slot is filled) and `generation`
## (how many loose items go in each carried container). Before this module the
## only knob over any of it was `configs.botLoot.richnessMultiplier`, published
## into the shared database by the Bot AI mod -- one number, for every bot in
## the game.
##
## This adds three axes on top, and NOTHING else:
##
##   * **per bot family** -- a gear multiplier and a loot multiplier for each of
##     nine families the 57 database roles fall into;
##   * **per equipment slot** -- a multiplier on that slot's own fill chance,
##     for the twelve slots that are actually rolled;
##   * **the mod trees** -- one multiplier for weapon attachments and one for
##     equipment attachments.
##
## Every one of them is a MULTIPLIER ON THE DATABASE'S OWN NUMBER. None of them
## invents a chance where the table gave none, and none of them can put an item
## in a slot the role's pool does not name. That is the difference between a
## control surface and a second, competing generator: at 1.0 every path here is
## arithmetic that returns its input, so an untouched settings page reproduces
## the previous bot exactly, roll for roll.
##
## ## The two slots that are NOT here, and why
##
## `Pockets` and `SecuredContainer` are absent on purpose. `emu/bots.addLoadout`
## documents the measured reason: the client dereferences `Equipment.Slots[8]`
## (Pockets) unconditionally in `EFT.Player::HasMarkOfUnknown`, and a bot whose
## pockets roll failed does not spawn without pockets -- it takes the whole
## activation down with it. A slider that can set that chance to zero is a
## slider that crashes raids, so it is not offered.
##
## ## The family table is measured, not guessed
##
## The 57 role keys under `bots.types` were read out of this install's own
## `db.json` (tools/bigjson.py, 2026-08-31) and are classified by prefix below.
## A role that matches nothing lands in `other`, which has its own pair of
## rows -- so no role is silently ungoverned, and the page never claims to
## cover a role it does not.

import std/strutils
import aowlspt
import aowlspt/server
import knobs

type
  BotFamily* = enum
    famScav, famUsec, famBear, famRaider, famRogue, famBoss, famFollower,
    famCultist, famOther

const
  FamilyGearKeys*: array[9, string] = [
    "botGearScav", "botGearUsec", "botGearBear", "botGearRaider",
    "botGearRogue", "botGearBoss", "botGearFollower", "botGearCultist",
    "botGearOther"]
  FamilyLootKeys*: array[9, string] = [
    "botLootScav", "botLootUsec", "botLootBear", "botLootRaider",
    "botLootRogue", "botLootBoss", "botLootFollower", "botLootCultist",
    "botLootOther"]

  FamilyAmmoKeys*: array[9, string] = [
    "botAmmoScav", "botAmmoUsec", "botAmmoBear", "botAmmoRaider",
    "botAmmoRogue", "botAmmoBoss", "botAmmoFollower", "botAmmoCultist",
    "botAmmoOther"]
  FamilyArmorKeys*: array[9, string] = [
    "botArmorScav", "botArmorUsec", "botArmorBear", "botArmorRaider",
    "botArmorRogue", "botArmorBoss", "botArmorFollower", "botArmorCultist",
    "botArmorOther"]

  ## The twelve slots a multiplier is offered for, paired with their settings
  ## key. The order is `emu/bots.equipmentSlots`' order minus Pockets and
  ## SecuredContainer, so the two lists can be read side by side.
  SlotNames*: array[12, string] = [
    "Headwear", "Earpiece", "FaceCover", "ArmorVest", "Eyewear", "ArmBand",
    "TacticalVest", "Backpack", "FirstPrimaryWeapon", "SecondPrimaryWeapon",
    "Holster", "Scabbard"]
  SlotKeys*: array[12, string] = [
    "botSlotHeadwear", "botSlotEarpiece", "botSlotFaceCover",
    "botSlotArmorVest", "botSlotEyewear", "botSlotArmBand",
    "botSlotTacticalVest", "botSlotBackpack", "botSlotPrimaryWeapon",
    "botSlotSecondaryWeapon", "botSlotHolster", "botSlotScabbard"]

proc familyOf*(role: string): BotFamily =
  ## Which family a database role key belongs to.
  ##
  ## Prefix matching over the lowercased key, because that is how the database
  ## itself groups them (`bossknight`/`followerbigpipe` are the Goons; every
  ## cultist is `sectant*`). `usec`/`bear` are the plain PMC keys and
  ## `pmcusec`/`pmcbear` the generated ones -- both exist in this database and
  ## both are the same faction, so both map to the same family.
  let r = toLowerAscii(role)
  if r.startsWith("sectant"):
    return famCultist
  if r.startsWith("boss"):
    return famBoss
  if r.startsWith("follower") or r == "tagillahelperagro" or r == "shooterbtr":
    return famFollower
  if r == "exusec":
    return famRogue
  if r == "pmcbot":
    return famRaider
  if r == "pmcusec" or r == "usec":
    return famUsec
  if r == "pmcbear" or r == "bear":
    return famBear
  if r.startsWith("assault") or r == "cursedassault" or
     r == "crazyassaultevent" or r == "marksman" or
     r == "arenafighterevent" or r == "peacemaker" or r == "gifter":
    return famScav
  result = famOther

type
  BotGearConfig* = object
    ## Read ONCE per generation batch, and read UNCONDITIONALLY: every key is
    ## consulted whatever its value, so `emu/knobs`' ledger reports the set the
    ## generator really asked for rather than the set that happened to be off
    ## its default. A conditional read would let a slider at 1.0 be reported as
    ## a dead control, which is the opposite of the truth.
    enabled*: bool
    globalGear*: float
    globalLoot*: float
    familyGear*: array[9, float]
    familyLoot*: array[9, float]
    slotMul*: array[12, float]
    weaponModMul*: float
    equipModMul*: float
    spareMags*: int
    maxLootPerBot*: int
    moneyStacks*: MoneyStackConfig

    # --- The loadout-quality axis -------------------------------------------
    #
    # Everything above scales HOW OFTEN a slot is filled. Nothing above can
    # change WHAT goes in it -- a scav with a gear multiplier of 10 wears more
    # things, all drawn from the same pool with the same weights. The four
    # fields below are the other axis, and they work the one way that cannot
    # invent an item: they RE-WEIGHT the role's own pool by a number the
    # template itself declares.
    #
    # At 0.0 -- every default -- the biased pick is not merely equivalent to
    # the plain one, it IS the plain one: `pickTemplateBiased` returns
    # `pickTemplate(pool, r)` unchanged, so the draw count and therefore the
    # whole RNG stream is byte-identical to a build without this feature.
    # That is what makes "turning nothing on changes nothing" checkable rather
    # than asserted.
    ammoBias*: float
      ## -1..1 over `_props.PenetrationPower`. Above 0 the role's own ammo pool
      ## leans toward its harder-hitting rounds; below 0 toward its softer ones.
      ## Never adds a round the role does not already list, and never one the
      ## magazine's own filter refuses.
    ammoBiasFam*: array[9, float]
    armorBias*: float
      ## -1..1 over `_props.armorClass`, applied to the equipment pools. The
      ## "armour tier" knob: same pool, leaned toward its heavier or lighter
      ## entries.
    armorBiasFam*: array[9, float]

    # --- Magazines ----------------------------------------------------------
    sparesPerWeapon*: int
      ## Spares carried per weapon that took a magazine. Was the compiled-in
      ## `SparesPerWeapon = 2` -- and 2 is exactly how many circular magazines
      ## the player counted beside the single-fed shotgun, which is what named
      ## this path as the cause.
    spareInternalMags*: bool
      ## OFF, the fix: a fixed tube or cylinder (`ReloadMagType:
      ## InternalMagazine`) is never duplicated into a rig, as a spare or as
      ## loose loot. ON restores the shipped behaviour, bug and all, because a
      ## fix worth having is worth being able to turn off and see.
    magFill*: float
      ## 0..1, the fraction of a magazine's capacity that is loaded. 1.0 is
      ## full, which is what the generator always did.

    # --- Per-container loot ------------------------------------------------
    lootVest*: float
    lootPockets*: float
    lootBackpack*: float
      ## Multipliers on the count drawn for `vestLoot` / `pocketLoot` /
      ## `backpackLoot` specifically, under the global and per-family rows. The
      ## other nine `generation.items` kinds are NOT offered and the reason is
      ## measured, not an oversight: they name a CATEGORY (`healing`,
      ## `grenades`) that nothing in the database resolves to templates, so the
      ## generator does not produce them at all and a row for them would be a
      ## control wired to nothing. See the long comment in `emu/bots`.

proc clamp01to*(v, lo, hi: float): float =
  if v < lo: lo
  elif v > hi: hi
  else: v

proc defaultBotGearConfig*(): BotGearConfig =
  result = BotGearConfig(enabled: true, globalGear: 1.0, globalLoot: 1.0,
                         weaponModMul: 1.0, equipModMul: 1.0,
                         spareMags: 4, maxLootPerBot: 24,
                         moneyStacks: MoneyStackConfig(multiplier: 1.0,
                                                       floorCount: 0,
                                                       ceilCount: 0),
                         ammoBias: 0.0, armorBias: 0.0,
                         sparesPerWeapon: 2, spareInternalMags: false,
                         magFill: 1.0,
                         lootVest: 1.0, lootPockets: 1.0, lootBackpack: 1.0)
  for i in 0 ..< 9:
    result.familyGear[i] = 1.0
    result.familyLoot[i] = 1.0
    result.ammoBiasFam[i] = 0.0
    result.armorBiasFam[i] = 0.0
  for i in 0 ..< 12:
    result.slotMul[i] = 1.0

proc botGearConfig*(): BotGearConfig =
  result = defaultBotGearConfig()
  result.enabled = knob("botGearEnabled").asBool(true)
  result.globalGear = clamp01to(knob("botGearMultiplier").asFloat(1.0), 0.0, 10.0)
  result.globalLoot = clamp01to(knob("botLootMultiplier").asFloat(1.0), 0.0, 10.0)
  for i in 0 ..< 9:
    result.familyGear[i] =
      clamp01to(knob(FamilyGearKeys[i]).asFloat(1.0), 0.0, 10.0)
    result.familyLoot[i] =
      clamp01to(knob(FamilyLootKeys[i]).asFloat(1.0), 0.0, 10.0)
  for i in 0 ..< 12:
    result.slotMul[i] = clamp01to(knob(SlotKeys[i]).asFloat(1.0), 0.0, 10.0)
  result.weaponModMul =
    clamp01to(knob("botWeaponModChance").asFloat(1.0), 0.0, 10.0)
  result.equipModMul =
    clamp01to(knob("botEquipmentModChance").asFloat(1.0), 0.0, 10.0)
  result.spareMags = knob("botSpareMagazines").asInt(4)
  if result.spareMags < 0: result.spareMags = 0
  if result.spareMags > 16: result.spareMags = 16
  result.maxLootPerBot = knob("botLootMaxItems").asInt(24)
  if result.maxLootPerBot < 0: result.maxLootPerBot = 0
  if result.maxLootPerBot > 200: result.maxLootPerBot = 200
  result.moneyStacks = moneyStackConfig()

  result.ammoBias = clamp01to(knob("botAmmoQuality").asFloat(0.0), -1.0, 1.0)
  result.armorBias = clamp01to(knob("botArmorTier").asFloat(0.0), -1.0, 1.0)
  for i in 0 ..< 9:
    result.ammoBiasFam[i] =
      clamp01to(knob(FamilyAmmoKeys[i]).asFloat(0.0), -1.0, 1.0)
    result.armorBiasFam[i] =
      clamp01to(knob(FamilyArmorKeys[i]).asFloat(0.0), -1.0, 1.0)
  result.sparesPerWeapon = knob("botSparesPerWeapon").asInt(2)
  if result.sparesPerWeapon < 0: result.sparesPerWeapon = 0
  if result.sparesPerWeapon > 8: result.sparesPerWeapon = 8
  result.spareInternalMags = knob("botSpareInternalMagazines").asBool(false)
  result.magFill = clamp01to(knob("botMagazineFill").asFloat(1.0), 0.0, 1.0)
  result.lootVest = clamp01to(knob("botLootVest").asFloat(1.0), 0.0, 10.0)
  result.lootPockets = clamp01to(knob("botLootPockets").asFloat(1.0), 0.0, 10.0)
  result.lootBackpack =
    clamp01to(knob("botLootBackpack").asFloat(1.0), 0.0, 10.0)

proc slotIndex*(slot: string): int =
  ## -1 for a slot with no row -- Pockets and SecuredContainer, and anything a
  ## future database names that this table does not. -1 means "no multiplier",
  ## never "chance zero": an unknown slot keeps the database's own number.
  for i in 0 ..< 12:
    if SlotNames[i] == slot:
      return i
  result = -1

proc scalePercent*(pct: int; mul: float): int =
  ## Scale a 0..100 fill chance. A multiplier above 1 can make a slot certain
  ## but never more than certain; below 1 it thins it; exactly 1.0 returns the
  ## input UNCHANGED with no arithmetic at all, which is what keeps the RNG
  ## stream identical for anyone who never opens the page.
  if mul == 1.0:
    return pct
  if pct <= 0:
    return pct
  var n = int(float(pct) * mul + 0.5)
  if n > 100: n = 100
  if n < 0: n = 0
  result = n

proc gearMultiplier*(cfg: BotGearConfig; fam: BotFamily; slot: string): float =
  ## The one number `addLoadout` needs for a slot: global x family x slot.
  ## Composable by construction, which is the answer to "200 rows" -- a user
  ## who only wants everything richer touches one row and the other two stay
  ## at 1.0.
  if not cfg.enabled:
    return 1.0
  var m = cfg.globalGear * cfg.familyGear[ord(fam)]
  let i = slotIndex(slot)
  if i >= 0:
    m = m * cfg.slotMul[i]
  result = m

proc lootMultiplier*(cfg: BotGearConfig; fam: BotFamily): float =
  if not cfg.enabled:
    return 1.0
  result = cfg.globalLoot * cfg.familyLoot[ord(fam)]

proc modMultiplier*(cfg: BotGearConfig; weapon: bool): float =
  if not cfg.enabled:
    return 1.0
  result = if weapon: cfg.weaponModMul else: cfg.equipModMul

proc ammoBiasFor*(cfg: BotGearConfig; fam: BotFamily): float =
  ## Global + family, ADDED rather than multiplied, then clamped -- a bias is a
  ## direction on a scale that already has a zero, and multiplying two of them
  ## would make "global 0, scavs +1" come out at 0, which is the opposite of
  ## what the two rows say. Clamped to -1..1 so the family row can cancel the
  ## global one but neither can run off the end.
  if not cfg.enabled:
    return 0.0
  clamp01to(cfg.ammoBias + cfg.ammoBiasFam[ord(fam)], -1.0, 1.0)

proc armorBiasFor*(cfg: BotGearConfig; fam: BotFamily): float =
  if not cfg.enabled:
    return 0.0
  clamp01to(cfg.armorBias + cfg.armorBiasFam[ord(fam)], -1.0, 1.0)

proc containerLootMultiplier*(cfg: BotGearConfig; kind: string): float =
  ## The per-container row for one `generation.items` kind. 1.0 for any kind
  ## with no row, which is "the database's own count, untouched" -- never zero.
  if not cfg.enabled:
    return 1.0
  case kind
  of "vestLoot": cfg.lootVest
  of "pocketLoot": cfg.lootPockets
  of "backpackLoot": cfg.lootBackpack
  else: 1.0

proc declaredBotKeys*(): seq[string] =
  ## Every key this module reads, in one place, for the ledger to check
  ## against. It is derived from the SAME arrays `botGearConfig` reads, so the
  ## two cannot drift -- and the falsifiable half is the other direction: a key
  ## declared on the settings page and absent here is what `tools/lootledger.py`
  ## goes red on.
  result = @["botGearEnabled", "botGearMultiplier", "botLootMultiplier",
             "botWeaponModChance", "botEquipmentModChance",
             "botSpareMagazines", "botLootMaxItems",
             "moneyStackMultiplier", "moneyStackMin", "moneyStackMax",
             "botAmmoQuality", "botArmorTier", "botSparesPerWeapon",
             "botSpareInternalMagazines", "botMagazineFill",
             "botLootVest", "botLootPockets", "botLootBackpack"]
  for i in 0 ..< 9:
    result.add FamilyGearKeys[i]
    result.add FamilyLootKeys[i]
    result.add FamilyAmmoKeys[i]
    result.add FamilyArmorKeys[i]
  for i in 0 ..< 12:
    result.add SlotKeys[i]
