## The ATTACHMENT depth surface: which mod slots get filled, and how expensive
## the thing that lands in them is allowed to be.
##
## ## What was here before
##
## One number. `botWeaponModChance` multiplied every optional weapon-mod slot's
## chance, `botEquipmentModChance` did the same for equipment, and the pick
## itself was `at(pool, nextInt(r, n))` -- a UNIFORM draw over the role's own
## list. A scav was exactly as likely to be handed the 480,000-rouble thermal in
## its `mod_scope` list as the 12-rouble iron sight, because nothing anywhere
## ranked them.
##
## ## The rarity model, and why it is PRICE
##
## Three candidate rankings were measured against this install's `db.json` on
## 2026-08-31, over the **2,397** distinct templates named by any role's
## `inventory.mods.<weapon>.<slot>` list -- the exact population this file
## picks from:
##
##   * `_props.Rarity` -- **does not exist. Not on one of the 4,673 templates.**
##     Zero. A tier scheme keyed on it would be a control wired to nothing that
##     looked like it worked. (`emu/loot.rarityOf` reads it as a fallback
##     spelling for older dumps; on THIS dump that fallback never fires.)
##   * `_props.RarityPvE` -- present on all 2,397, but it is not a ranking of
##     attachments: 1,100 of them (**46%**) are `Not_exist`, which is BSG's "does
##     not spawn as loose loot" marker and says nothing about how good the part
##     is. The rest are Rare 789, Superrare 301, Common 207. Four bands, one of
##     which is half the population and means nothing here.
##   * `templates.handbook.Items[].Price` -- **2,395 of the 2,397 carry one.**
##     It ranks a 12-rouble iron sight below a 480,000-rouble thermal, which is
##     the question the user actually asked.
##
## So the tier is the handbook price, and the two unpriced templates are NO
## OPINION -- never tier zero, never dropped.
##
## `emu/loot` shapes WORLD loot by `RarityPvE`, and that is right for world
## loot: there, "does this spawn on the floor" IS the question. The two axes are
## therefore genuinely different questions over the same items, and a merge
## should keep both rather than pick one -- see the precedence note below for
## the part that should be shared.
##
## Six tiers, with the boundaries chosen so each holds a usable share of the
## 2,395 rather than so they read nicely. Measured shares, same pass:
##
##   trash      < 1,000        319   13.3%
##   common     1,000..4,999   890   37.1%
##   uncommon   5,000..14,999  666   27.8%
##   rare       15,000..39,999 364   15.2%
##   epic       40,000..99,999 143    6.0%
##   legendary  >= 100,000      13    0.5%
##
## "A scav gets a cheap sight but never a thermal" is therefore expressible
## exactly: set the scav family's `legendary` and `epic` tier weights to 0. The
## thermal stays in the pool -- this module never edits a pool -- it just cannot
## be drawn.
##
## ## The slot groups are the database's own names, collapsed
##
## The 57 roles' `chances.weaponMods` name **52** distinct slots between them and
## `chances.equipmentMods` names **11**, overlapping in three (`mod_flashlight`,
## `mod_mount`, `mod_nvg`) for **60 distinct**. All 60 are enumerated in
## `SlotGroupMembers` below and every one is assigned; `sgOther` exists for a
## name a future database invents, and it has its own rows, so no slot is ever
## silently ungoverned. `mod_scope_002` is the same KIND of decision as
## `mod_scope`, which is why the knobs are per GROUP (19 of them) and not per
## raw name -- 20 groups x 9 families is already 180 rows, and 60 x 9 would be
## 540 rows that say the same thing three times.
##
## ## PRECEDENCE -- the whole of it, in one place
##
## Two kinds of number, and they compose by two DIFFERENT rules, because they
## have two different identities:
##
##   * a **MULTIPLIER** is around 1.0 and composes MULTIPLICATIVELY.
##       chance = table% x global x slotGroup x (family,slotGroup) x weaponClass
##       tierWeight = globalTier x famTier x slotTier
##   * a **BIAS** is around 0.0, is a direction on a signed scale, and composes
##     ADDITIVELY then clamps to -1..1.
##       rarity = global + family + slotGroup + (family,slotGroup) + weaponClass
##
## Multiplying two biases would make "global 0, scavs +1" come out at 0, which
## is the opposite of what the two rows say. This is the SAME rule
## `emu/botgear.ammoBiasFor` already uses; it is written out here so the two
## cannot be read as coincidence.
##
## `emu/lootconfig` (world loot, a sibling change) is expected to adopt this
## vocabulary: the six tier names, the price-derived tiering, and the
## multiplier-multiplies / bias-adds precedence. `tierOfPrice` and `ModTier` are
## exported for exactly that, and hold no bot-specific state.
##
## ## The identity path is LITERAL, not arithmetic
##
## `pickModTemplate` checks `activeFor` FIRST and, when nothing applies, returns
## `at(pool, nextInt(r, n))` -- the byte-identical expression `emu/bots.addMods`
## used before this module existed. Not "a weighted pick that happens to be
## uniform": `pickWeighted` draws `nextFloat` and `nextInt` draws `nextU64`, so
## a uniform weight vector would consume the same amount of stream and land on a
## DIFFERENT index. Equal-looking arithmetic is not equal behaviour, and the
## defaults-reproduce-current-behaviour claim rests on the early return.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import rand
import knobs
import botgear

# ---------------------------------------------------------------------------
# Tiers
# ---------------------------------------------------------------------------

type
  ModTier* = enum
    trTrash, trCommon, trUncommon, trRare, trEpic, trLegendary

const
  TierCount* = 6
  TierNames*: array[6, string] = [
    "Trash", "Common", "Uncommon", "Rare", "Epic", "Legendary"]
  TierBounds*: array[5, int] = [1_000, 5_000, 15_000, 40_000, 100_000]
    ## Upper-exclusive boundaries. `TierBounds[i]` is the price at which tier `i`
    ## becomes tier `i+1`. Five boundaries for six tiers.

proc tierOfPrice*(price: int): ModTier =
  ## The tier a handbook price falls in. Total over every int, including
  ## negatives -- a negative price is not a thing the handbook contains, and if
  ## it ever is, it is trash.
  var i = 0
  while i < 5 and price >= TierBounds[i]:
    inc i
  result = ModTier(i)

# ---------------------------------------------------------------------------
# The handbook price index
# ---------------------------------------------------------------------------
#
# `templates.handbook.Items` is a 4,288-entry list of `{Id, ParentId, Price}`.
# Scanning it per pick would be 4,288 string compares for every attachment on
# every bot in a 20-bot batch; so it is read ONCE and bucketed.
#
# Hand-rolled buckets rather than `std/tables`: nothing else in this emulator
# imports it (measured -- zero files under `emu/`), and a new stdlib dependency
# in the generator is not a thing to introduce as a side effect of a settings
# page.

const PriceBuckets = 2048

var gPriceReady = false
var gPriceIds: array[PriceBuckets, seq[string]]
var gPriceVals: array[PriceBuckets, seq[int]]
var gPriceCount = 0

proc bucketOf(tpl: string): int =
  result = int(hashText(tpl) mod uint64(PriceBuckets))

proc loadPrices() =
  ## Idempotent, and it sets `gPriceReady` EVEN WHEN THE READ FAILED. That is
  ## deliberate: with no database loaded (`aowl selfcheck` runs out of process
  ## and has none) every price is unknown, every mod is NO OPINION, and the
  ## rarity axis is inert. Retrying per pick would turn a missing database into
  ## a 4,288-entry parse per attachment.
  if gPriceReady:
    return
  gPriceReady = true
  let v = dbRead("templates.handbook.Items")
  if not v.ok:
    return
  let list = each(whole(v.raw))
  for e in list:
    let id = e.field("Id").asText("")
    if id.len == 0:
      continue
    let p = e.field("Price")
    if not p.found:
      continue
    let b = bucketOf(id)
    gPriceIds[b].add id
    gPriceVals[b].add p.asInt(0)
    inc gPriceCount

proc priceIndexSize*(): int =
  ## How many templates the index actually holds. The falsifiable half of "the
  ## rarity axis is wired to real data": a zero here with a database loaded says
  ## the handbook path is wrong, and the tier knobs are all no-ops.
  loadPrices()
  result = gPriceCount

proc modPrice*(tpl: string): int =
  ## The handbook price of a template, or **-1 for "the handbook does not say"**.
  ## -1 is not zero and callers must not treat it as a cheap item: 2 of the 2,397
  ## mod templates land here, and an unranked item is one the tier model has no
  ## opinion about.
  loadPrices()
  if tpl.len == 0:
    return -1
  let b = bucketOf(tpl)
  for i in 0 ..< gPriceIds[b].len:
    if gPriceIds[b][i] == tpl:
      return gPriceVals[b][i]
  result = -1

# ---------------------------------------------------------------------------
# Slot groups
# ---------------------------------------------------------------------------

type
  SlotGroup* = enum
    sgScope, sgSight, sgMuzzle, sgMagazine, sgTactical, sgFlashlight, sgNvg,
    sgForegrip, sgStock, sgPistolGrip, sgHandguard, sgMount, sgReceiver,
    sgBarrel, sgBipod, sgLauncher, sgInternal, sgArmorPlate, sgEquipment,
    sgOther

const
  SlotGroupCount* = 20
  SlotGroupNames*: array[20, string] = [
    "Scope", "Sight", "Muzzle", "Magazine", "Tactical", "Flashlight", "Nvg",
    "Foregrip", "Stock", "PistolGrip", "Handguard", "Mount", "Receiver",
    "Barrel", "Bipod", "Launcher", "Internal", "ArmorPlate", "Equipment",
    "OtherSlot"]

proc slotGroupOf*(slotName: string): SlotGroup =
  ## Which group a raw database slot name belongs to.
  ##
  ## Exact match on the lowercased name for every one of the 60 names measured
  ## in this database, then a prefix fallback so a slot BSG adds next patch
  ## (`mod_scope_004`) lands in the right group instead of in `sgOther`. The
  ## fallback is ordered longest-discriminator-first: `mod_pistol_grip` must be
  ## tested before `mod_pistolgrip` cannot help, but `mod_sight` must be tested
  ## before nothing, and `mod_stock_akms` is caught by the `mod_stock` prefix.
  let s = toLowerAscii(slotName)
  if s.startsWith("mod_scope"): return sgScope
  if s.startsWith("mod_sight"): return sgSight
  if s.startsWith("mod_muzzle"): return sgMuzzle
  if s == "mod_magazine": return sgMagazine
  if s.startsWith("mod_tactical"): return sgTactical
  if s.startsWith("mod_flashlight"): return sgFlashlight
  if s.startsWith("mod_nvg"): return sgNvg
  if s.startsWith("mod_foregrip"): return sgForegrip
  if s.startsWith("mod_stock"): return sgStock
  if s.startsWith("mod_pistol_grip") or s.startsWith("mod_pistolgrip"):
    return sgPistolGrip
  if s.startsWith("mod_handguard"): return sgHandguard
  if s.startsWith("mod_mount"): return sgMount
  # The database spells it `mod_reciever`. Both spellings, because the typo is
  # BSG's and a corrected one would otherwise fall into `sgOther`.
  if s.startsWith("mod_reciever") or s.startsWith("mod_receiver"):
    return sgReceiver
  if s.startsWith("mod_barrel") or s.startsWith("mod_gas_block"):
    return sgBarrel
  if s.startsWith("mod_bipod"): return sgBipod
  if s.startsWith("mod_launcher"): return sgLauncher
  if s.startsWith("mod_charge") or s.startsWith("mod_catch") or
     s.startsWith("mod_hammer") or s.startsWith("mod_trigger"):
    return sgInternal
  if s.endsWith("_plate"): return sgArmorPlate
  if s.startsWith("mod_equipment"): return sgEquipment
  result = sgOther

# ---------------------------------------------------------------------------
# Weapon classes
# ---------------------------------------------------------------------------

type
  WeaponClass* = enum
    wcSmg, wcAssaultRifle, wcPistol, wcShotgun, wcSniperRifle,
    wcAssaultCarbine, wcMarksmanRifle, wcMachinegun, wcGrenadeLauncher,
    wcSpecialWeapon, wcOtherClass

const
  WeaponClassCount* = 11
  WeaponClassNames*: array[11, string] = [
    "Smg", "AssaultRifle", "Pistol", "Shotgun", "SniperRifle",
    "AssaultCarbine", "MarksmanRifle", "Machinegun", "GrenadeLauncher",
    "SpecialWeapon", "OtherClass"]
  WeaponClassProps*: array[10, string] = [
    "smg", "assaultRifle", "pistol", "shotgun", "sniperRifle",
    "assaultCarbine", "marksmanRifle", "machinegun", "grenadeLauncher",
    "specialWeapon"]
    ## The ten `_props.weapClass` strings this database uses, measured
    ## 2026-08-31: 34 smg, 46 assaultRifle, 29 pistol, 15 shotgun, 9
    ## sniperRifle, 9 assaultCarbine, 10 marksmanRifle, 10 machinegun, 5
    ## grenadeLauncher, 9 specialWeapon -- 176 weapons, and every one classified.

proc weaponClassOf*(tpl: string): WeaponClass =
  ## The weapon class of a template, `wcOtherClass` for anything with no
  ## `_props.weapClass` -- which includes every piece of EQUIPMENT, so an
  ## equipment mod tree is governed by the `OtherClass` row rather than by a
  ## weapon row that does not apply to it.
  if tpl.len == 0:
    return wcOtherClass
  let v = dbRead("templates.items." & tpl & "._props.weapClass")
  if not v.ok:
    return wcOtherClass
  let s = whole(v.raw).asText("")
  if s.len == 0:
    return wcOtherClass
  for i in 0 ..< 10:
    if WeaponClassProps[i] == s:
      return WeaponClass(i)
  result = wcOtherClass

# ---------------------------------------------------------------------------
# The key names
# ---------------------------------------------------------------------------
#
# Generated from the same three name arrays the config reads, so a key can
# never be declared under one spelling and read under another. `declaredModKeys`
# below walks the identical loops.

const
  FamilyTokens*: array[9, string] = [
    "Scav", "Usec", "Bear", "Raider", "Rogue", "Boss", "Follower", "Cultist",
    "Other"]

proc keyChanceSlot*(sg: int): string = "botModChanceSlot" & SlotGroupNames[sg]
proc keyChanceFamSlot*(fam, sg: int): string =
  "botModChanceFam" & FamilyTokens[fam] & "Slot" & SlotGroupNames[sg]
proc keyChanceClass*(wc: int): string =
  "botModChanceCls" & WeaponClassNames[wc]
proc keyRarityFam*(fam: int): string = "botModRarityFam" & FamilyTokens[fam]
proc keyRaritySlot*(sg: int): string = "botModRaritySlot" & SlotGroupNames[sg]
proc keyRarityFamSlot*(fam, sg: int): string =
  "botModRarityFam" & FamilyTokens[fam] & "Slot" & SlotGroupNames[sg]
proc keyRarityClass*(wc: int): string =
  "botModRarityCls" & WeaponClassNames[wc]
proc keyTier*(t: int): string = "botModTier" & TierNames[t]
proc keyTierFam*(fam, t: int): string =
  "botModTierFam" & FamilyTokens[fam] & TierNames[t]
proc keyTierSlot*(sg, t: int): string =
  "botModTierSlot" & SlotGroupNames[sg] & TierNames[t]

# ---------------------------------------------------------------------------
# The config
# ---------------------------------------------------------------------------

type
  ModRarityConfig* = object
    ## Flat arrays rather than arrays-of-arrays throughout: index arithmetic is
    ## written out at each use and there is exactly one place per axis that can
    ## be wrong.
    enabled*: bool
    chanceSlot*: array[20, float]
    chanceFamSlot*: array[180, float]      # fam*20 + sg
    chanceClass*: array[11, float]
    rarityGlobal*: float
    rarityFam*: array[9, float]
    raritySlot*: array[20, float]
    rarityFamSlot*: array[180, float]      # fam*20 + sg
    rarityClass*: array[11, float]
    tierGlobal*: array[6, float]
    tierFam*: array[54, float]             # fam*6 + tier
    tierSlot*: array[120, float]           # sg*6 + tier
    anyRarity*: bool
      ## Any rarity bias or tier weight is off its default. Precomputed once per
      ## batch because it decides, per pick, whether the identity path is taken,
      ## and re-deriving it from 389 numbers inside the pick loop would be the
      ## whole point of caching thrown away.
    anyChance*: bool

proc defaultModRarityConfig*(): ModRarityConfig =
  result = ModRarityConfig(enabled: true, rarityGlobal: 0.0,
                           anyRarity: false, anyChance: false)
  for i in 0 ..< 20: result.chanceSlot[i] = 1.0
  for i in 0 ..< 180: result.chanceFamSlot[i] = 1.0
  for i in 0 ..< 11: result.chanceClass[i] = 1.0
  for i in 0 ..< 9: result.rarityFam[i] = 0.0
  for i in 0 ..< 20: result.raritySlot[i] = 0.0
  for i in 0 ..< 180: result.rarityFamSlot[i] = 0.0
  for i in 0 ..< 11: result.rarityClass[i] = 0.0
  for i in 0 ..< 6: result.tierGlobal[i] = 1.0
  for i in 0 ..< 54: result.tierFam[i] = 1.0
  for i in 0 ..< 120: result.tierSlot[i] = 1.0

proc modRarityConfig*(): ModRarityConfig =
  ## Every key read UNCONDITIONALLY, whatever its value, so `emu/knobs`' ledger
  ## reports the set the generator really asked for. 612 reads per batch, not
  ## per bot -- `emu/bots` caches this alongside `BotGearConfig`.
  result = defaultModRarityConfig()
  result.enabled = knob("botModRarityEnabled").asBool(true)
  result.rarityGlobal = clamp01to(knob("botModRarity").asFloat(0.0), -1.0, 1.0)
  for sg in 0 ..< 20:
    result.chanceSlot[sg] =
      clamp01to(knob(keyChanceSlot(sg)).asFloat(1.0), 0.0, 10.0)
    result.raritySlot[sg] =
      clamp01to(knob(keyRaritySlot(sg)).asFloat(0.0), -1.0, 1.0)
    for t in 0 ..< 6:
      result.tierSlot[sg * 6 + t] =
        clamp01to(knob(keyTierSlot(sg, t)).asFloat(1.0), 0.0, 10.0)
  for fam in 0 ..< 9:
    result.rarityFam[fam] =
      clamp01to(knob(keyRarityFam(fam)).asFloat(0.0), -1.0, 1.0)
    for sg in 0 ..< 20:
      result.chanceFamSlot[fam * 20 + sg] =
        clamp01to(knob(keyChanceFamSlot(fam, sg)).asFloat(1.0), 0.0, 10.0)
      result.rarityFamSlot[fam * 20 + sg] =
        clamp01to(knob(keyRarityFamSlot(fam, sg)).asFloat(0.0), -1.0, 1.0)
    for t in 0 ..< 6:
      result.tierFam[fam * 6 + t] =
        clamp01to(knob(keyTierFam(fam, t)).asFloat(1.0), 0.0, 10.0)
  for wc in 0 ..< 11:
    result.chanceClass[wc] =
      clamp01to(knob(keyChanceClass(wc)).asFloat(1.0), 0.0, 10.0)
    result.rarityClass[wc] =
      clamp01to(knob(keyRarityClass(wc)).asFloat(0.0), -1.0, 1.0)
  for t in 0 ..< 6:
    result.tierGlobal[t] =
      clamp01to(knob(keyTier(t)).asFloat(1.0), 0.0, 10.0)

  # The two summary bits. Computed from the LOADED values rather than tracked as
  # the keys are read, so a value that was clamped back onto its default counts
  # as a default -- which is what the generator will actually do with it.
  var ar = result.rarityGlobal != 0.0
  for i in 0 ..< 9:
    if result.rarityFam[i] != 0.0: ar = true
  for i in 0 ..< 20:
    if result.raritySlot[i] != 0.0: ar = true
  for i in 0 ..< 180:
    if result.rarityFamSlot[i] != 0.0: ar = true
  for i in 0 ..< 11:
    if result.rarityClass[i] != 0.0: ar = true
  for i in 0 ..< 6:
    if result.tierGlobal[i] != 1.0: ar = true
  for i in 0 ..< 54:
    if result.tierFam[i] != 1.0: ar = true
  for i in 0 ..< 120:
    if result.tierSlot[i] != 1.0: ar = true
  result.anyRarity = ar
  var ac = false
  for i in 0 ..< 20:
    if result.chanceSlot[i] != 1.0: ac = true
  for i in 0 ..< 180:
    if result.chanceFamSlot[i] != 1.0: ac = true
  for i in 0 ..< 11:
    if result.chanceClass[i] != 1.0: ac = true
  result.anyChance = ac

# ---------------------------------------------------------------------------
# Resolution
# ---------------------------------------------------------------------------

proc modChanceMultiplier*(cfg: ModRarityConfig; fam: BotFamily;
                          slotName: string; wc: WeaponClass): float =
  ## The slot-group half of the fill chance. MULTIPLIES with
  ## `botgear.modMultiplier`, which stays exactly as it was -- this is a new
  ## factor on the same product, so a user who only ever moved the old global
  ## slider gets the old number back.
  if not cfg.enabled or not cfg.anyChance:
    return 1.0
  let sg = ord(slotGroupOf(slotName))
  result = cfg.chanceSlot[sg] * cfg.chanceFamSlot[ord(fam) * 20 + sg] *
           cfg.chanceClass[ord(wc)]

proc modRarityBias*(cfg: ModRarityConfig; fam: BotFamily; slotName: string;
                    wc: WeaponClass): float =
  ## Global + family + slotGroup + (family,slotGroup) + weaponClass, ADDED, then
  ## clamped to -1..1. See the precedence note at the top of this file for why
  ## added and not multiplied.
  if not cfg.enabled:
    return 0.0
  let sg = ord(slotGroupOf(slotName))
  clamp01to(cfg.rarityGlobal + cfg.rarityFam[ord(fam)] + cfg.raritySlot[sg] +
            cfg.rarityFamSlot[ord(fam) * 20 + sg] + cfg.rarityClass[ord(wc)],
            -1.0, 1.0)

proc tierWeight*(cfg: ModRarityConfig; fam: BotFamily; slotName: string;
                 tier: ModTier): float =
  ## global x family x slotGroup, all three defaulting to 1.0.
  if not cfg.enabled:
    return 1.0
  let sg = ord(slotGroupOf(slotName))
  let t = ord(tier)
  result = cfg.tierGlobal[t] * cfg.tierFam[ord(fam) * 6 + t] *
           cfg.tierSlot[sg * 6 + t]

proc logScale(price: int): float =
  ## Prices in this data span 12 to 480,000 -- four and a half decades. A LINEAR
  ## normalisation over that puts 99% of a pool within 5% of the bottom and the
  ## bias becomes a switch that only ever moves the single most expensive entry.
  ## A log scale is what makes "lean cheap" and "lean expensive" both mean
  ## something. `price + 1` so a price of 0 is finite rather than -inf.
  var p = price
  if p < 0: p = 0
  var v = 1.0
  var acc = float(p) + 1.0
  # ln by repeated halving/doubling would be a loop; nimony has no `math.ln`
  # available to this module without a new import, so this is log2 by exponent
  # extraction plus a linear interpolation of the mantissa. Monotone, which is
  # the only property the normalisation needs -- it never has to be accurate,
  # it has to ORDER correctly and be smooth.
  var e = 0.0
  while acc >= 2.0:
    acc = acc / 2.0
    e = e + 1.0
  v = e + (acc - 1.0)
  result = v

proc pickModTemplate*(cfg: ModRarityConfig; pool: JsonRef; n: int; r: var Rng;
                      fam: BotFamily; slotName: string;
                      wc: WeaponClass): string =
  ## One template out of a mod slot's LIST.
  ##
  ## **The first branch is the whole defaults guarantee.** With nothing turned
  ## on it returns `at(pool, nextInt(r, n)).asText("")`, character for
  ## character what `emu/bots.addMods` did before this file existed -- one
  ## `nextU64` draw, same modulo, same index. It is NOT a weighted pick with
  ## uniform weights: `pickWeighted` draws `nextFloat`, which would land
  ## somewhere else and repaint every bot in the game.
  if n <= 0:
    return ""
  if not cfg.enabled or not cfg.anyRarity:
    return at(pool, nextInt(r, n)).asText("")

  var names: seq[string] = @[]
  var weights: seq[float] = @[]
  var vals: seq[float] = @[]
  var lo = 0.0
  var hi = 0.0
  var seen = false
  for i in 0 ..< n:
    let tpl = at(pool, i).asText("")
    if tpl.len == 0:
      continue
    let p = modPrice(tpl)
    # The pool was uniform, so every entry starts at weight 1. An UNPRICED
    # template keeps weight 1 and is excluded from the normalisation -- it is
    # "no opinion", never "tier trash". Two of the 2,397 land here.
    var w = 1.0
    if p >= 0:
      w = tierWeight(cfg, fam, slotName, tierOfPrice(p))
      let s = logScale(p)
      vals.add s
      if not seen:
        lo = s
        hi = s
        seen = true
      else:
        if s < lo: lo = s
        if s > hi: hi = s
    else:
      vals.add -1.0
    names.add tpl
    weights.add w

  let bias = modRarityBias(cfg, fam, slotName, wc)
  if bias != 0.0 and seen and hi > lo:
    for i in 0 ..< weights.len:
      if vals[i] < 0.0:
        continue
      let nrm = (vals[i] - lo) / (hi - lo)
      var f = 1.0 + bias * (2.0 * nrm - 1.0)
      if f < 0.0: f = 0.0
      weights[i] = weights[i] * f

  let at1 = pickWeighted(r, weights)
  if at1 < 0:
    # Every candidate was weighted to zero. That is a REAL answer -- "this
    # family may not have anything in this slot" is exactly what setting all six
    # tier weights to 0 asks for -- and the caller reads "" as "leave the slot
    # empty", which for an optional slot is correct. A required slot falls back
    # to the item's own filter in `addMods`, so a gun still cannot ship with a
    # hole in it.
    return ""
  result = names[at1]

# ---------------------------------------------------------------------------

proc declaredModKeys*(): seq[string] =
  ## Every key `modRarityConfig` reads, generated by the SAME loops, so the two
  ## cannot drift. 612 plus the enable switch.
  result = @["botModRarityEnabled", "botModRarity"]
  for sg in 0 ..< 20:
    result.add keyChanceSlot(sg)
    result.add keyRaritySlot(sg)
    for t in 0 ..< 6:
      result.add keyTierSlot(sg, t)
  for fam in 0 ..< 9:
    result.add keyRarityFam(fam)
    for sg in 0 ..< 20:
      result.add keyChanceFamSlot(fam, sg)
      result.add keyRarityFamSlot(fam, sg)
    for t in 0 ..< 6:
      result.add keyTierFam(fam, t)
  for wc in 0 ..< 11:
    result.add keyChanceClass(wc)
    result.add keyRarityClass(wc)
  for t in 0 ..< 6:
    result.add keyTier(t)

# ---------------------------------------------------------------------------

const
  MeasuredSlotNames*: array[60, string] = [
    "mod_barrel", "mod_bipod", "mod_catch", "mod_charge", "mod_charge_001",
    "mod_flashlight", "mod_foregrip", "mod_gas_block", "mod_hammer",
    "mod_handguard", "mod_launcher", "mod_magazine", "mod_mount",
    "mod_mount_000", "mod_mount_001", "mod_mount_002", "mod_mount_003",
    "mod_mount_004", "mod_mount_005", "mod_mount_006", "mod_muzzle",
    "mod_muzzle_000", "mod_muzzle_001", "mod_nvg", "mod_pistol_grip",
    "mod_pistol_grip_akms", "mod_pistolgrip", "mod_pistolgrip_000",
    "mod_reciever", "mod_scope", "mod_scope_000", "mod_scope_001",
    "mod_scope_002", "mod_scope_003", "mod_sight_front", "mod_sight_rear",
    "mod_stock", "mod_stock_000", "mod_stock_001", "mod_stock_002",
    "mod_stock_akms", "mod_stock_axis", "mod_tactical", "mod_tactical001",
    "mod_tactical002", "mod_tactical_000", "mod_tactical_001",
    "mod_tactical_002", "mod_tactical_003", "mod_tactical_004",
    "mod_tactical_2", "mod_trigger", "back_plate", "front_plate",
    "left_side_plate", "right_side_plate", "mod_equipment",
    "mod_equipment_000", "mod_equipment_001", "mod_equipment_002"]
    ## EVERY slot name any of the 57 roles' `chances.weaponMods` (52) or
    ## `chances.equipmentMods` (11, three shared) names in this install's
    ## `db.json`, read out with `tools/bigjson.py` on 2026-08-31. Written down so
    ## the coverage check below has something it can FAIL against: a name that
    ## falls through to `sgOther` is a slot with no row of its own, and the whole
    ## claim of this file is that there is no such slot.

proc selfCheckModRarity*(into: var seq[string]) =
  ## Four checks, all runnable with NO database -- `aowl selfcheck` runs out of
  ## process and has none, and a check that only runs on a live server is a
  ## check that does not run.

  # 1. THE IDENTITY CHECK, and it is the important one. At defaults,
  #    `pickModTemplate` must return the SAME element AND leave the generator in
  #    the SAME state as the expression `emu/bots.addMods` used before this file
  #    existed. Delete the early return in `pickModTemplate` and this fails --
  #    which is the input that makes it falsifiable, and the reason it is
  #    written as a comparison against the OLD expression rather than against a
  #    recorded constant.
  let cfg = defaultModRarityConfig()
  let pool = whole("[\"aaa\",\"bbb\",\"ccc\",\"ddd\",\"eee\",\"fff\",\"ggg\"]")
  var mine = seededRng("modrarity-identity")
  var theirs = seededRng("modrarity-identity")
  var drifted = 0
  for i in 0 ..< 64:
    let a = pickModTemplate(cfg, pool, 7, mine, famScav, "mod_scope",
                            wcAssaultRifle)
    let b = at(pool, nextInt(theirs, 7)).asText("")
    if a != b:
      inc drifted
  if drifted != 0 or mine.state != theirs.state:
    into.add "modrarity: at DEFAULTS the mod pick is no longer the old " &
             "uniform draw -- " & $drifted & "/64 picks differed and the " &
             "generator state " &
             (if mine.state == theirs.state: "matched" else: "DIVERGED") &
             "; every bot in the game moves"

  # 2. Every measured slot name has a row. `sgOther` is the catch-all for a
  #    name a FUTURE database invents; a name this one already uses landing
  #    there is an ungoverned slot.
  var unassigned: seq[string] = @[]
  for i in 0 ..< 60:
    if slotGroupOf(MeasuredSlotNames[i]) == sgOther:
      unassigned.add MeasuredSlotNames[i]
  if unassigned.len > 0:
    var named = ""
    for u in unassigned:
      if named.len > 0: named = named & ", "
      named = named & u
    into.add "modrarity: " & $unassigned.len & " of the 60 slot names this " &
             "database actually uses fall through to sgOther and have no row " &
             "of their own: " & named

  # 3. The tier boundaries are exactly where the doc comment says. A boundary
  #    that drifts silently re-tiers 2,395 templates.
  if tierOfPrice(999) != trTrash or tierOfPrice(1_000) != trCommon or
     tierOfPrice(4_999) != trCommon or tierOfPrice(5_000) != trUncommon or
     tierOfPrice(14_999) != trUncommon or tierOfPrice(15_000) != trRare or
     tierOfPrice(39_999) != trRare or tierOfPrice(40_000) != trEpic or
     tierOfPrice(99_999) != trEpic or tierOfPrice(100_000) != trLegendary:
    into.add "modrarity: the price tier boundaries do not match the six " &
             "documented ranges"

  # 4. No key is declared twice. A duplicate would be read twice, reported once,
  #    and would make the ledger's count a lie.
  let declared = declaredModKeys()
  var dups = 0
  for i in 0 ..< declared.len:
    for j in (i + 1) ..< declared.len:
      if declared[i] == declared[j]:
        inc dups
  if dups != 0:
    into.add "modrarity: " & $dups & " duplicate key(s) among the " &
             $declared.len & " declared attachment settings"
