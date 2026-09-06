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
import knobs
import lootconfig
import lootcats
import planting

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

proc parseNumber(s: string; dflt: float): float =
  ## A number out of text, without raising -- `parseFloat` is `.raises`, and a
  ## raising call here would drag a `try` into every config read. A string that
  ## is not a number at all comes back as `dflt`, so a typo in a key=value list
  ## is DROPPED by the caller rather than silently read as zero (which for a
  ## multiplier means "delete this map's loot").
  if s.len == 0:
    return dflt
  var i = 0
  var neg = false
  if s[i] == '-' or s[i] == '+':
    neg = s[i] == '-'
    inc i
  var digits = 0
  var whole1 = 0.0
  while i < s.len and s[i] >= '0' and s[i] <= '9':
    whole1 = whole1 * 10.0 + float(ord(s[i]) - ord('0'))
    inc i
    inc digits
  var frac = 0.0
  var scale = 0.1
  if i < s.len and s[i] == '.':
    inc i
    while i < s.len and s[i] >= '0' and s[i] <= '9':
      frac = frac + float(ord(s[i]) - ord('0')) * scale
      scale = scale * 0.1
      inc i
      inc digits
  if digits == 0 or i != s.len:
    return dflt
  result = whole1 + frac
  if neg:
    result = -result

type
  KvList* = object
    ## A `name=number` list out of one settings string. Two of the new loot
    ## knobs are open-ended maps -- per-map multipliers and per-container-type
    ## chances -- and neither has a fixed set of keys that could be drawn as
    ## rows, so both are carried as text and parsed here.
    keys*: seq[string]
    vals*: seq[float]

proc newKvList(): KvList = KvList(keys: @[], vals: @[])

proc len(kv: KvList): int = kv.keys.len

proc parseKvList*(s: string): KvList =
  ## `"bigmap=1.5, woods=0.5"`. A pair that is malformed -- no `=`, an empty
  ## name, a value that is not a number -- is dropped and the rest is kept, and
  ## the count of what survived is reported by `lootConfigSummary` so a typo is
  ## VISIBLE rather than being read as "that map now has no loot".
  result = newKvList()
  for part in s.split(','):
    let t = strip(part)
    if t.len == 0:
      continue
    var eq = -1
    for i in 0 ..< t.len:
      if t[i] == '=':
        eq = i
        break
    if eq <= 0 or eq >= t.len - 1:
      continue
    let k = strip(t.substr(0, eq - 1))
    let v = parseNumber(strip(t.substr(eq + 1, t.len - 1)), -1.0)
    if k.len == 0 or v < 0.0:
      continue
    result.keys.add k
    result.vals.add v

proc setKv(kv: var KvList; key: string; v: float) =
  ## Set or replace one pair. Replace, not append: `lookup` returns the FIRST
  ## match, so appending a second entry for the same id would silently keep the
  ## old value -- an override that overrides nothing.
  for i in 0 ..< kv.keys.len:
    if kv.keys[i] == key:
      kv.vals[i] = v
      return
  kv.keys.add key
  kv.vals.add v

proc lookup*(kv: KvList; key: string; dflt: float): float =
  for i in 0 ..< kv.keys.len:
    if kv.keys[i] == key:
      return kv.vals[i]
  result = dflt

type
  LootConfig* = object
    ## Every knob the loot pipeline actually reads. The defaults below are the
    ## behaviour this module shipped with -- a config file that predates any of
    ## these keys, or an operator who never touches the Loot page, gets exactly
    ## the floor they got before, item for item and id for id (the RNG stream is
    ## unchanged when every knob is at its default, because each new knob is
    ## skipped entirely at its default rather than rolled and ignored).
    enabled*: bool            ## turn loot generation off entirely
    staticMultiplier*: float  ## scales container spawn chance and fill
    looseMultiplier*: float   ## scales loose spawn point chance
    maxItems*: int            ## hard ceiling on the items in one response

    globalMultiplier*: float  ## on top of BOTH of the two above
    staticEnabled*: bool      ## run the static-container pass at all
    looseEnabled*: bool       ## run the loose-loot pass at all
    forcedSpawns*: bool       ## honour `spawnpointsForced` (quest/key spawns)
    staticBudgetShare*: float ## fraction of `maxItems` offered to containers
    perMap*: KvList           ## extra multiplier per location id, both passes

    containerChanceMul*: float ## extra on a container's own `probability`
    containerFillMul*: float   ## extra on the drawn item COUNT per container
    containerMaxItems*: int    ## per-container item cap (was hardcoded 64)
    containerTypeChance*: KvList ## per container TEMPLATE spawn multiplier

    loosePointLimit*: int      ## max loose points that may spawn, 0 = no limit

    valueBias*: float          ## <0 cheap, 0 off, >0 expensive
    valuePivot*: float         ## the handbook price `valueBias` pivots around
    minPrice*: int             ## drop pool entries cheaper than this, 0 = off
    maxPrice*: int             ## drop pool entries dearer than this, 0 = off
    rarityCommon*: float
    rarityRare*: float
    raritySuperrare*: float
    categoryWeights*: KvList   ## `_parent` base-class id -> weight

    stackRandomRange*: bool    ## roll StackMinRandom..StackMaxRandom when declared
    stackMultiplier*: float    ## scale the rolled stack count
    stackMaxFraction*: float   ## cap the roll at this fraction of StackMaxSize
    money*: MoneyStackConfig   ## currency-only stack shaping, shared with bots

    rules*: RuleSet            ## the shared resolver, see `emu/lootconfig`
    explainTpl*: string        ## template id to trace at generation time
    staticPerMap*: KvList      ## per-map multiplier, CONTAINER pass only
    loosePerMap*: KvList       ## per-map multiplier, LOOSE pass only
    containerTypeFill*: KvList ## per container TEMPLATE item-count multiplier

proc defaultLootConfig*(): LootConfig =
  ## The shipped behaviour: the map's own numbers, unscaled.
  LootConfig(enabled: true, staticMultiplier: 1.0, looseMultiplier: 1.0,
             maxItems: 20000,
             globalMultiplier: 1.0, staticEnabled: true, looseEnabled: true,
             forcedSpawns: true, staticBudgetShare: 0.5, perMap: newKvList(),
             containerChanceMul: 1.0, containerFillMul: 1.0,
             containerMaxItems: 64, containerTypeChance: newKvList(),
             loosePointLimit: 0,
             valueBias: 0.0, valuePivot: 20000.0, minPrice: 0, maxPrice: 0,
             rarityCommon: 1.0, rarityRare: 1.0, raritySuperrare: 1.0,
             categoryWeights: newKvList(),
             stackRandomRange: false, stackMultiplier: 1.0,
             stackMaxFraction: 1.0,
             money: MoneyStackConfig(multiplier: 1.0, floorCount: 0,
                                     ceilCount: 0),
             rules: newRuleSet(), explainTpl: "",
             staticPerMap: newKvList(), loosePerMap: newKvList(),
             containerTypeFill: newKvList())

proc clampLow(v: float; lo: float): float =
  if v < lo: lo else: v

const
  ## THE NAMED CATEGORY SLIDERS -- the settings key on the Loot page paired with
  ## the base-class template id it multiplies.
  ##
  ## These five ids are the SPT-community-known base classes; they were NOT
  ## verified against this install's database here, which is exactly what they
  ## were already documented as on the free-text row this replaces. Nothing was
  ## invented: this table is the same five ids, moved out of a description and
  ## into sliders, so nobody has to paste a 24-character id to make loot commoner.
  ##
  ## The check that this is not decorative is not a count of the sliders --
  ## that would agree with itself. It is `lootConfigSummary`, which reports how
  ## many pool entries the weights ACTUALLY touched, and the server log line it
  ## already emits when the answer is zero.
  ## MEASURED, 2026-08-31, against this install's own `db.json` via
  ## `tools/bigjson.py get --path templates.items.<id>._name`. Every id below
  ## returned the `_name` in its comment; the one candidate that did NOT resolve
  ## in this database (`57864ee62459775490116fbf`, "building material" in
  ## community lists) was DROPPED rather than shipped as a row that reweights
  ## nothing. That is the whole reason this table grew from five to twenty-two
  ## instead of from five to thirty: the ids are checked, not collected.
  CategoryWeightKeys*: array[22, string] = [
    "lootWeightMoney", "lootWeightAmmo", "lootWeightMeds",
    "lootWeightKeys", "lootWeightBarter",
    "lootWeightAmmoBoxes", "lootWeightFood", "lootWeightElectronics",
    "lootWeightValuables", "lootWeightWeapons", "lootWeightKnives",
    "lootWeightMods", "lootWeightMagazines", "lootWeightArmor",
    "lootWeightHelmets", "lootWeightRigs", "lootWeightBackpacks",
    "lootWeightGrenades", "lootWeightContainers", "lootWeightStims",
    "lootWeightTools", "lootWeightSpecial"]
  CategoryWeightIds*: array[22, string] = [
    "543be5dd4bdc2deb348b4569",   # Money
    "5485a8684bdc2da71d8b4567",   # Ammo
    "543be5664bdc2dd4348b4569",   # Meds
    "543be5e94bdc2df1348b4568",   # Key
    "5448eb774bdc2d0a728b4567",   # BarterItem
    "543be5cb4bdc2deb348b4568",   # AmmoBox
    "543be6674bdc2df1348b4569",   # FoodDrink
    "57864a66245977548f04a81f",   # Electronics
    "57864a3d24597754843f8721",   # Jewelry
    "5422acb9af1c889c16000029",   # Weapon
    "5447e1d04bdc2dff2f8b4567",   # Knife
    "5448fe124bdc2da5018b4567",   # Mod
    "5448bc234bdc2d3c308b4569",   # Magazine
    "5448e54d4bdc2dcc718b4568",   # Armor
    "5a341c4086f77401f2541505",   # Headwear
    "5448e5284bdc2dcb718b4567",   # Vest
    "5448e53e4bdc2d60728b4567",   # Backpack
    "543be6564bdc2df4348b4568",   # ThrowWeap
    "5795f317245977243854e041",   # SimpleContainer
    "5448f3a64bdc2d60728b456a",   # Stimulator
    "57864bb7245977548b3b66c2",   # Tool
    "5447e0e74bdc2d3c308b4567"]   # SpecItem

  ## The three currencies, as their own rows, so "more roubles and fewer
  ## dollars" is two sliders rather than a hand-written id list. They are
  ## TEMPLATE ids, not base classes; `parseKvList`/`setKv` and the pool shaper
  ## already accept either, and a template entry is strictly more specific than
  ## the Money base class above -- both apply, and both multiply.
  CurrencyWeightKeys*: array[3, string] = [
    "lootCurrencyRoubles", "lootCurrencyDollars", "lootCurrencyEuros"]
  CurrencyWeightIds*: array[3, string] = [
    "5449016a4bdc2d6f028b456f",   # Rubles   (StackMinRandom 5500..13500)
    "5696686a4bdc2da3298b456a",   # Dollars  (45..100)
    "569668774bdc2da2298b4568"]   # Euro     (35..90)

proc categoryWeightsFromSettings(): KvList =
  ## The five named sliders, then `lootCategoryWeights` ON TOP.
  ##
  ## Ordering is the whole design. A slider left at 1.0 contributes NOTHING --
  ## not an entry worth 1.0 -- so `shapesPool`/`needsPrices` still skip the
  ## shaping code entirely at defaults, and the RNG stream is unchanged for
  ## anyone who never opens the page. The free-text row is applied last and
  ## REPLACES rather than appends, so a hand-written `543be5dd...=0` beats the
  ## Money slider instead of losing to it silently: two controls that disagree
  ## must have a stated winner, and the advanced one wins.
  result = newKvList()
  for i in 0 ..< CategoryWeightKeys.len:
    let w = knob(CategoryWeightKeys[i]).asFloat(1.0)
    if w != 1.0:
      setKv(result, CategoryWeightIds[i], (if w < 0.0: 0.0 else: w))
  # The currency rows go in AFTER the families, so a specific currency beats
  # the Money family where both are set -- the same "the more specific control
  # wins, and it is stated" rule the free-text row below follows.
  for i in 0 ..< CurrencyWeightKeys.len:
    let w = knob(CurrencyWeightKeys[i]).asFloat(1.0)
    if w != 1.0:
      setKv(result, CurrencyWeightIds[i], (if w < 0.0: 0.0 else: w))
  let extra = parseKvList(knob("lootCategoryWeights").asText(""))
  for i in 0 ..< extra.keys.len:
    setKv(result, extra.keys[i], extra.vals[i])

proc lootRulesFromSettings*(): RuleSet =
  ## Every named category slider, then the free-text rules ON TOP.
  ##
  ## Load ORDER is the tie-break, and it is stated here rather than left to
  ## whatever iteration happened to produce: base classes, then handbook
  ## categories, then the legacy `lootCategoryWeights` list, then `lootRules`.
  ## `lootconfig.beats` gives the LAST declaration the win on an exact
  ## specificity tie, so the free-text rule -- the advanced control, the one
  ## somebody had to type an id into -- beats a slider it ties with, and never
  ## loses to it silently.
  ##
  ## A slider at exactly 1.0 contributes NO RULE (see `addMul`), so an operator
  ## who never opened the page leaves this empty, `active` is false, and the
  ## resolver is skipped rather than run with neutral numbers.
  result = newRuleSet()
  for i in 0 ..< BaseClassRows.len:
    let row = BaseClassRows[i]
    addMul(result, selBase, row.id, knob(row.key).asFloat(1.0), row.key)
  for i in 0 ..< HandbookRows.len:
    let row = HandbookRows[i]
    addMul(result, selHb, row.id, knob(row.key).asFloat(1.0), row.key)
  addRuleText(result, knob("lootRules").asText(""))

proc rulesNeedPrices(rs: RuleSet): bool =
  for r in rs.rules:
    if r.sel == selPriceAbove or r.sel == selPriceBelow:
      return true
  result = false

proc rulesNeedHandbook(rs: RuleSet): bool =
  for r in rs.rules:
    if r.sel == selHb:
      return true
  result = false

proc lootConfig*(): LootConfig =
  ## Read from the mod's `config.json`. Every key is optional and every default
  ## is the pre-existing behaviour, so a config file that predates this module
  ## still produces the same floor rather than a map with no loot on it.
  result = defaultLootConfig()
  result.enabled = knob("lootEnabled").asBool(true)
  result.staticMultiplier = knob("staticLootMultiplier").asFloat(1.0)
  result.looseMultiplier = knob("looseLootMultiplier").asFloat(1.0)
  result.maxItems = knob("maxLootItems").asInt(20000)

  result.globalMultiplier = knob("lootGlobalMultiplier").asFloat(1.0)
  result.staticEnabled = knob("staticLootEnabled").asBool(true)
  result.looseEnabled = knob("looseLootEnabled").asBool(true)
  result.forcedSpawns = knob("lootForcedSpawns").asBool(true)
  result.staticBudgetShare = knob("lootStaticBudgetShare").asFloat(0.5)
  result.perMap = parseKvList(knob("lootPerMapMultipliers").asText(""))

  result.containerChanceMul = knob("containerSpawnChanceMultiplier").asFloat(1.0)
  result.containerFillMul = knob("containerFillMultiplier").asFloat(1.0)
  result.containerMaxItems = knob("containerMaxItems").asInt(64)
  result.containerTypeChance = parseKvList(knob("containerTypeChances").asText(""))

  result.loosePointLimit = knob("looseLootPointLimit").asInt(0)

  result.valueBias = knob("lootValueBias").asFloat(0.0)
  result.valuePivot = knob("lootValuePivot").asFloat(20000.0)
  result.minPrice = knob("lootMinHandbookPrice").asInt(0)
  result.maxPrice = knob("lootMaxHandbookPrice").asInt(0)
  result.rarityCommon = knob("lootRarityCommon").asFloat(1.0)
  result.rarityRare = knob("lootRarityRare").asFloat(1.0)
  result.raritySuperrare = knob("lootRaritySuperrare").asFloat(1.0)
  result.categoryWeights = categoryWeightsFromSettings()

  result.stackRandomRange = knob("lootStackRandomRange").asBool(false)
  result.stackMultiplier = knob("lootStackMultiplier").asFloat(1.0)
  result.stackMaxFraction = knob("lootStackMaxFraction").asFloat(1.0)
  result.money = moneyStackConfig()

  result.rules = lootRulesFromSettings()
  result.explainTpl = strip(knob("lootRuleExplain").asText(""))
  result.staticPerMap = parseKvList(knob("staticLootPerMap").asText(""))
  result.loosePerMap = parseKvList(knob("looseLootPerMap").asText(""))
  result.containerTypeFill = parseKvList(knob("containerTypeFill").asText(""))

  # Clamping, not refusing: a negative multiplier is a slider dragged past its
  # own minimum, and "no loot from this source" is the honest reading of it.
  result.staticMultiplier = clampLow(result.staticMultiplier, 0.0)
  result.looseMultiplier = clampLow(result.looseMultiplier, 0.0)
  result.globalMultiplier = clampLow(result.globalMultiplier, 0.0)
  result.containerChanceMul = clampLow(result.containerChanceMul, 0.0)
  result.containerFillMul = clampLow(result.containerFillMul, 0.0)
  result.rarityCommon = clampLow(result.rarityCommon, 0.0)
  result.rarityRare = clampLow(result.rarityRare, 0.0)
  result.raritySuperrare = clampLow(result.raritySuperrare, 0.0)
  result.stackMultiplier = clampLow(result.stackMultiplier, 0.0)
  if result.maxItems < 0: result.maxItems = 0
  if result.containerMaxItems < 1: result.containerMaxItems = 1
  if result.containerMaxItems > 512: result.containerMaxItems = 512
  if result.loosePointLimit < 0: result.loosePointLimit = 0
  if result.minPrice < 0: result.minPrice = 0
  if result.maxPrice < 0: result.maxPrice = 0
  if result.valuePivot < 1.0: result.valuePivot = 1.0
  if result.valueBias < -2.0: result.valueBias = -2.0
  if result.valueBias > 2.0: result.valueBias = 2.0
  if result.stackMaxFraction <= 0.0: result.stackMaxFraction = 0.0
  if result.stackMaxFraction > 1.0: result.stackMaxFraction = 1.0
  if result.staticBudgetShare < 0.0: result.staticBudgetShare = 0.0
  if result.staticBudgetShare > 1.0: result.staticBudgetShare = 1.0

proc declaredLootKeys*(): seq[string] =
  ## Every settings key the loot generator reads, named once. Derived from the
  ## same two arrays `categoryWeightsFromSettings` iterates, so the category
  ## half cannot drift; the rest is written out because `lootConfig` reads them
  ## as literals and a list that is generated from the reads would agree with
  ## itself by construction.
  result = @["lootEnabled", "staticLootMultiplier", "looseLootMultiplier",
             "maxLootItems", "lootGlobalMultiplier", "staticLootEnabled",
             "looseLootEnabled", "lootForcedSpawns", "lootStaticBudgetShare",
             "lootPerMapMultipliers", "containerSpawnChanceMultiplier",
             "containerFillMultiplier", "containerMaxItems",
             "containerTypeChances", "looseLootPointLimit", "lootValueBias",
             "lootValuePivot", "lootMinHandbookPrice", "lootMaxHandbookPrice",
             "lootRarityCommon", "lootRarityRare", "lootRaritySuperrare",
             "lootCategoryWeights", "lootStackRandomRange",
             "lootStackMultiplier", "lootStackMaxFraction",
             "moneyStackMultiplier", "moneyStackMin", "moneyStackMax",
             "lootRules", "lootRuleExplain", "staticLootPerMap",
             "looseLootPerMap", "containerTypeFill"]
  for i in 0 ..< CategoryWeightKeys.len:
    result.add CategoryWeightKeys[i]
  for i in 0 ..< CurrencyWeightKeys.len:
    result.add CurrencyWeightKeys[i]
  for i in 0 ..< BaseClassRows.len:
    result.add BaseClassRows[i].key
  for i in 0 ..< HandbookRows.len:
    result.add HandbookRows[i].key

proc shapesPool*(cfg: LootConfig): bool =
  ## Whether ANY pool-shaping knob is off its default. When this is false the
  ## shaping code is skipped entirely -- not run with neutral numbers -- which
  ## is what makes "defaults preserve current behaviour" a property of the code
  ## rather than a claim about arithmetic.
  cfg.valueBias != 0.0 or cfg.minPrice > 0 or cfg.maxPrice > 0 or
    cfg.rarityCommon != 1.0 or cfg.rarityRare != 1.0 or
    cfg.raritySuperrare != 1.0 or cfg.categoryWeights.len > 0 or
    cfg.rules.active

proc needsPrices*(cfg: LootConfig): bool =
  ## Whether the handbook price index has to be built at all.
  cfg.valueBias != 0.0 or cfg.minPrice > 0 or cfg.maxPrice > 0 or
    rulesNeedPrices(cfg.rules)

proc needsHandbookCats*(cfg: LootConfig): bool =
  ## Whether the template -> handbook-category index has to be built. Separate
  ## from `needsPrices` because a rule set full of `hb:` rules and no price
  ## rules must still get the category index, and a price-only rule set must
  ## not pay for one.
  rulesNeedHandbook(cfg.rules)

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
# Pool shaping
# ---------------------------------------------------------------------------
#
# Rarity, value and category bias all act in ONE place: the weights of a pool,
# just before something is drawn from it. That is deliberate. Biasing after the
# draw (rerolling an item the player did not want) changes how many things spawn
# as well as which, and biasing at emit time cannot drop an item without leaving
# a hole in a container. Reweighting the distribution changes only the mix.
#
# All of it is SKIPPED unless a knob is off its default -- see `shapesPool`.

type
  PoolShaper* = object
    active*: bool
    prices*: bool           ## the handbook index was built and is non-empty
    tpls: seq[string]       ## handbook item ids
    price: seq[float]       ## ... and their base prices
    rarityHits*: int        ## pool entries that carried a rarity field
    rarityMisses*: int      ## ... and that did not
    priceHits*: int
    priceMisses*: int
    dropped*: int           ## entries removed by the min/max price gates
    hbcat: seq[string]      ## ... and the handbook category each one sits in
    hbcats*: bool           ## the category index was built and is non-empty
    catId: seq[string]      ## `templates.handbook.Categories[].Id`
    catParent: seq[string]  ## ... and its ParentId, for the chain walk
    ruleHits*: int          ## pool entries any rule matched
    ruleDrops*: int         ## ... and entries a rule removed
    explained*: string      ## the `lootRuleExplain` trace, once

proc newPoolShaper(): PoolShaper =
  PoolShaper(active: false, prices: false, tpls: @[], price: @[],
             rarityHits: 0, rarityMisses: 0, priceHits: 0, priceMisses: 0,
             dropped: 0, hbcat: @[], hbcats: false, catId: @[],
             catParent: @[], ruleHits: 0, ruleDrops: 0, explained: "")

proc buildShaper(d: LootDb; cfg: LootConfig): PoolShaper =
  ## Built once per raid, like `buildPresets`, and for the same reason: the
  ## handbook is a few thousand entries and a scan of it per drawn item is a
  ## cost that only ever shows up on someone else's loading screen.
  result = newPoolShaper()
  if not shapesPool(cfg):
    return
  result.active = true
  let wantPrices = needsPrices(cfg)
  let wantCats = needsHandbookCats(cfg)
  if not wantPrices and not wantCats:
    return
  let raw0 = sub(d, "templates.handbook.Items")
  if raw0.len == 0:
    return
  let j = whole(raw0)
  if not isArray(j):
    return
  let entries = each(j)
  for e in entries:
    let id = e.field("Id").asText("")
    if id.len == 0:
      continue
    result.tpls.add id
    result.price.add e.field("Price").asFloat(0.0)
    result.hbcat.add e.field("ParentId").asText("")
  result.prices = wantPrices and result.tpls.len > 0
  if not wantCats:
    return
  let rawc = sub(d, "templates.handbook.Categories")
  if rawc.len == 0:
    return
  let jc = whole(rawc)
  if not isArray(jc):
    return
  for c in each(jc):
    let id = c.field("Id").asText("")
    if id.len == 0:
      continue
    result.catId.add id
    result.catParent.add c.field("ParentId").asText("")
  result.hbcats = result.catId.len > 0

proc priceOf(s: PoolShaper; tpl: string): float =
  ## The handbook base price, or -1 when the handbook does not list this item.
  ## -1 is NOT zero: an unlisted item must not be treated as worthless and
  ## dropped by `lootMinHandbookPrice`, because "the handbook has no row for it"
  ## and "it is worth nothing" are different facts and only one of them is a
  ## reason to remove an item from the game.
  for i in 0 ..< s.tpls.len:
    if s.tpls[i] == tpl:
      return s.price[i]
  result = -1.0

proc rarityOf(d: LootDb; tpl: string): string =
  ## The template's own rarity band, lowercased, or "" when it declares none.
  ## Two spellings are read because two are in circulation: `RarityPvE` on a
  ## current dump and `Rarity` on an older one.
  let props = itemProps(d, tpl)
  if props.len == 0:
    return ""
  let j = whole(props)
  var v = j.field("RarityPvE").asText("")
  if v.len == 0:
    v = j.field("Rarity").asText("")
  result = toLowerAscii(v)

proc categoryFactor(d: LootDb; cfg: LootConfig; tpl: string): float =
  ## The product of every `lootCategoryWeights` entry that matches this item's
  ## own template id or ANY id on its `_parent` chain. Walking the chain is what
  ## makes one entry -- a base class id -- cover a whole family without naming
  ## the hundreds of templates in it.
  ##
  ## The walk is capped and refuses to revisit a template, because `_parent`
  ## comes from data and a cycle in data must not hang a raid's loading screen.
  result = 1.0
  if cfg.categoryWeights.len == 0:
    return
  var cur = tpl
  var hops = 0
  var seen: seq[string] = @[]
  while cur.len > 0 and hops < 12:
    result = result * lookup(cfg.categoryWeights, cur, 1.0)
    seen.add cur
    var parent = strip(sub(d, "templates.items." & cur & "._parent"))
    # `sub` hands back RAW json, so a string member arrives quoted. Unquoted by
    # hand rather than by re-parsing: a bare scalar is not an object and the
    # object readers used everywhere else in this file do not accept one.
    if parent.len >= 2 and parent[0] == '"' and parent[parent.len - 1] == '"':
      parent = parent.substr(1, parent.len - 2)
    if parent.len == 0:
      break
    var loop = false
    for s in seen:
      if s == parent:
        loop = true
        break
    if loop:
      break
    cur = parent
    inc hops

proc valueFactor(cfg: LootConfig; price: float): float =
  ## Monotone in `price`, 1.0 at the pivot, 1.0 everywhere when `valueBias` is
  ## zero. Deliberately NOT a power law: `pow` is not reached for here, and a
  ## bounded linear/reciprocal pair is easier to reason about and cannot produce
  ## an infinite weight from one absurd handbook price. The ratio is capped at
  ## 20x the pivot so a single 2,000,000-rouble entry cannot swallow a pool.
  if cfg.valueBias == 0.0 or price < 0.0:
    return 1.0
  var ratio = price / cfg.valuePivot
  if ratio > 20.0: ratio = 20.0
  if ratio < 0.0: ratio = 0.0
  if cfg.valueBias > 0.0:
    result = 1.0 + cfg.valueBias * ratio
  else:
    result = 1.0 / (1.0 + (-cfg.valueBias) * ratio)

proc rarityFactor(cfg: LootConfig; band: string): float =
  case band
  of "common": cfg.rarityCommon
  of "rare": cfg.rarityRare
  of "superrare": cfg.raritySuperrare
  else: 1.0

proc parentChain(d: LootDb; tpl: string): seq[string] =
  ## The `_parent` chain, NEAREST FIRST, excluding `tpl` itself. Capped and
  ## cycle-refusing for the same reason `categoryFactor` is: `_parent` comes
  ## from data, and a cycle in data must not hang a raid's loading screen.
  result = @[]
  var cur = tpl
  var hops = 0
  while cur.len > 0 and hops < 24:
    var parent = strip(sub(d, "templates.items." & cur & "._parent"))
    if parent.len >= 2 and parent[0] == '"' and parent[parent.len - 1] == '"':
      parent = parent.substr(1, parent.len - 2)
    if parent.len == 0:
      break
    var loop = parent == tpl
    for s in result:
      if s == parent:
        loop = true
        break
    if loop:
      break
    result.add parent
    cur = parent
    inc hops

proc hbChain(s: PoolShaper; tpl: string): seq[string] =
  ## The handbook category chain for a template, nearest first. Empty when the
  ## index was not built or the handbook has no row for this template -- which
  ## is NOT the same as "it is in no category", and is why an `hb:` rule simply
  ## fails to match rather than matching a guessed root.
  result = @[]
  if not s.hbcats:
    return
  var cat = ""
  for i in 0 ..< s.tpls.len:
    if s.tpls[i] == tpl:
      cat = s.hbcat[i]
      break
  var hops = 0
  while cat.len > 0 and hops < 12:
    var loop = false
    for c in result:
      if c == cat:
        loop = true
        break
    if loop:
      break
    result.add cat
    var nxt = ""
    for i in 0 ..< s.catId.len:
      if s.catId[i] == cat:
        nxt = s.catParent[i]
        break
    cat = nxt
    inc hops

proc subjectFor*(d: LootDb; s: PoolShaper; tpl, map, ctx: string;
                 ctxKind: CtxKind): Subject =
  ## One candidate, in one situation, in the shape `emu/lootconfig` resolves.
  ## `emu/bots` builds the same thing with `ckBot` and the bot's role as `ctx`;
  ## that is the entire difference between world loot and carried loot as far
  ## as the weighting system is concerned.
  Subject(tpl: tpl, parents: parentChain(d, tpl), hb: hbChain(s, tpl),
          rarity: rarityOf(d, tpl), price: priceOf(s, tpl),
          map: map, ctx: ctx, ctxKind: ctxKind)

proc shapePool(d: LootDb; cfg: LootConfig; s: var PoolShaper;
               dist: Distribution; map = ""; ctx = "";
               ctxKind = ckAny): Distribution =
  ## The pool a draw actually happens against. Entries whose weight falls to
  ## zero, and entries outside the price gates, are REMOVED rather than kept at
  ## weight zero -- `pick` would never return them either way, but a removed
  ## entry makes `dist.len == 0` reachable, which is how the caller learns the
  ## whole pool was gated away instead of drawing forever from a dead list.
  if not s.active:
    return dist
  result = newDistribution()
  for i in 0 ..< dist.keys.len:
    let tpl = dist.keys[i]
    var w = dist.weights[i]

    if cfg.minPrice > 0 or cfg.maxPrice > 0 or cfg.valueBias != 0.0:
      let p = priceOf(s, tpl)
      if p < 0.0:
        s.priceMisses = s.priceMisses + 1
      else:
        s.priceHits = s.priceHits + 1
        if cfg.minPrice > 0 and p < float(cfg.minPrice):
          s.dropped = s.dropped + 1
          continue
        if cfg.maxPrice > 0 and p > float(cfg.maxPrice):
          s.dropped = s.dropped + 1
          continue
      w = w * valueFactor(cfg, p)

    if cfg.rarityCommon != 1.0 or cfg.rarityRare != 1.0 or
       cfg.raritySuperrare != 1.0:
      let band = rarityOf(d, tpl)
      if band.len == 0:
        s.rarityMisses = s.rarityMisses + 1
      else:
        s.rarityHits = s.rarityHits + 1
      w = w * rarityFactor(cfg, band)

    w = w * categoryFactor(d, cfg, tpl)

    # The shared resolver, LAST. It runs after the legacy scalar knobs rather
    # than instead of them, so an existing `config.json` keeps behaving as it
    # did and a rule set is strictly additional. When no rule is declared the
    # whole block is skipped -- not run with a neutral rule set -- which is
    # what keeps the default RNG stream identical.
    if cfg.rules.active:
      let subj = subjectFor(d, s, tpl, map, ctx, ctxKind)
      if cfg.explainTpl.len > 0 and cfg.explainTpl == tpl and
         s.explained.len == 0:
        s.explained = explain(cfg.rules, subj, w)
      let o = resolve(cfg.rules, subj, w)
      if o.matched > 0:
        s.ruleHits = s.ruleHits + 1
      if o.dropped:
        s.ruleDrops = s.ruleDrops + 1
        s.dropped = s.dropped + 1
        continue
      w = o.weight

    if w <= 0.0:
      s.dropped = s.dropped + 1
      continue
    result.keys.add tpl
    result.weights.add w

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

proc stackRange(d: LootDb; tpl: string; lo, hi: var int): bool =
  ## `_props.StackMinRandom` / `StackMaxRandom` -- the DATA's own statement of
  ## how large a stack of this thing spawns. This is exactly the discriminator
  ## `emu/bots.randomStackCount` already uses for scav money, read here rather
  ## than duplicated: on stock data the fields are present on currency and loose
  ## ammunition and on nothing else, so an item that declares neither is left to
  ## the `StackMaxSize` path below.
  lo = 0
  hi = 0
  let props = itemProps(d, tpl)
  if props.len == 0:
    return false
  let j = whole(props)
  let hiRef = j.field("StackMaxRandom")
  if not hiRef.found:
    return false
  lo = j.field("StackMinRandom").asInt(1)
  hi = hiRef.asInt(1)
  if lo < 1: lo = 1
  if hi < lo: hi = lo
  result = true

proc spawnItem(s: var ItemSink; d: LootDb; p: PresetIndex; a: AmmoTable;
               r: var Rng; cfg: LootConfig;
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
    #
    # `lootStackRandomRange` (default OFF, i.e. exactly the roll below) swaps
    # that uniform 1..StackMaxSize roll for the template's OWN declared spawn
    # range where it has one. It is off by default only because this task's
    # brief is that defaults change nothing -- on stock data StackMaxSize for a
    # rouble stack is far larger than any range the game itself spawns, so the
    # uniform roll produces money piles the range would not. Turn it on to get
    # the data's numbers.
    var n = 0
    var rlo = 0
    var rhi = 0
    if cfg.stackRandomRange and stackRange(d, tpl, rlo, rhi):
      n = rlo + nextInt(r, rhi - rlo + 1)
    else:
      n = 1 + nextInt(r, limit)
    if cfg.stackMultiplier != 1.0:
      n = int(float(n) * cfg.stackMultiplier + 0.5)
    var ceiling = limit
    if cfg.stackMaxFraction < 1.0:
      ceiling = int(float(limit) * cfg.stackMaxFraction)
    if ceiling < 1: ceiling = 1
    if n > ceiling: n = ceiling
    if n < 1: n = 1
    # Loot > Money. The three money rows are applied LAST and only to the three
    # currency templates, so the money floor/ceiling a player sets is the
    # number that reaches the map -- it is not then re-capped by the generic
    # stack fraction above, which is what would make a "minimum rouble stack"
    # row silently do nothing on a map where the fraction is low. It is still
    # bounded by the item's own StackMaxSize, which is the client's limit and
    # not ours to exceed.
    if isMoneyTpl(tpl):
      n = applyMoneyStack(cfg.money, n)
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
              r: var Rng; cfg: LootConfig;
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
          discard spawnItem(s, d, p, a, r, cfg, tpl, containerId, grids[gi].name,
                            locationRaw(x, y, false))
          return true
        if w != h and fitsAt(grids[gi], x, y, h, w):
          occupy(grids[gi], x, y, h, w)
          discard spawnItem(s, d, p, a, r, cfg, tpl, containerId, grids[gi].name,
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
                      cfg: LootConfig; s: var PoolShaper; locationId: string;
                      chanceMul: float; budget: var int): seq[string] =
  result = @[]
  if not cfg.staticEnabled:
    return
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
    # The container's TEMPLATE has to be known before its chance is rolled,
    # because `containerTypeChances` is keyed by template. Reading it first
    # costs nothing: an entry with no template was already skipped above.
    let containerTpl = tmpl.field("Items[0]._tpl").asText("")
    if containerTpl.len == 0:
      continue
    var probability = entry.field("probability").asFloat(1.0) * chanceMul *
                      cfg.containerChanceMul
    if cfg.containerTypeChance.len > 0:
      probability = probability *
                    lookup(cfg.containerTypeChance, containerTpl, 1.0)
    let alwaysSpawn = tmpl.field("IsAlwaysSpawn").asBool(false)
    if not alwaysSpawn and not chance(r, probability):
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
        discard packInto(sink, d, p, a, r, cfg, grids, containerId, tpl)

      let pool = staticPool(d, locationId, containerTpl)
      if pool.len > 0:
        let poolRef = whole(pool)
        let dist = shapePool(d, cfg, s,
                     readDistribution(raw(child(poolRef, "itemDistribution"))),
                     locationId, containerTpl, ckStatic)
        var n = readCount(raw(child(poolRef, "itemcountDistribution")), r)
        # The multiplier scales how full a crate is as well as whether it is
        # there, which is what "more loot" means to a player who asks for it.
        # `containerFillMultiplier` separates the two halves of that for anyone
        # who wants more crates but not fuller ones, or the reverse.
        var fillMul = cfg.staticMultiplier * cfg.containerFillMul
        if cfg.containerTypeFill.len > 0:
          fillMul = fillMul * lookup(cfg.containerTypeFill, containerTpl, 1.0)
        n = int(float(n) * fillMul + 0.5)
        if n > cfg.containerMaxItems: n = cfg.containerMaxItems
        var k = 0
        while k < n and dist.len > 0:
          let tpl = pick(dist, r)
          if tpl.len == 0:
            break
          if not packInto(sink, d, p, a, r, cfg, grids, containerId, tpl):
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

proc tplForKey(list: List; key: string): string =
  ## The TEMPLATE a loose point's candidate id refers to. Loose distributions
  ## are keyed by the point's own item ids while every shaping knob is defined
  ## over templates, so without this mapping the loose pass could not be shaped
  ## at all and the knobs would silently apply to containers only.
  for i in 0 ..< list.len:
    let it = whole(list.items[i])
    if it.field("_id").asText("") == key:
      return it.field("_tpl").asText("")
  result = ""

proc shapeLoosePool(d: LootDb; cfg: LootConfig; s: var PoolShaper;
                    list: List; dist: Distribution;
                    map = ""): Distribution =
  ## `shapePool` over a loose point, with the id -> template mapping applied
  ## before shaping and undone after, so the returned keys are still the ids the
  ## caller has to resolve against the point.
  if not s.active or dist.len == 0:
    return dist
  result = newDistribution()
  # Shape each entry on its own so the id it came from is never lost -- shaping
  # the whole pool at once would return a list with holes in it and no way back
  # to the ids.
  for i in 0 ..< dist.keys.len:
    let tpl = tplForKey(list, dist.keys[i])
    if tpl.len == 0:
      # Unresolvable: kept, UNSHAPED. Dropping it would let a data shape this
      # module does not understand quietly delete a spawn point.
      result.keys.add dist.keys[i]
      result.weights.add dist.weights[i]
      continue
    var one = newDistribution()
    one.keys.add tpl
    one.weights.add dist.weights[i]
    let shaped = shapePool(d, cfg, s, one, map, "", ckLoose)
    if shaped.keys.len == 0:
      continue
    result.keys.add dist.keys[i]
    result.weights.add shaped.weights[0]

proc passesGates(d: LootDb; cfg: LootConfig; s: var PoolShaper;
                 tpl: string; map = ""): bool =
  ## Whether one template survives the item-mix knobs on its own. Used for a
  ## loose point that has NO distribution -- one candidate, laid out by hand.
  ## Without this the whole item-mix section would silently apply to containers
  ## and multi-candidate points only, which is most of a knob that does nothing.
  if not s.active or tpl.len == 0:
    return true
  var one = newDistribution()
  one.keys.add tpl
  one.weights.add 1.0
  result = shapePool(d, cfg, s, one, map, "", ckLoose).keys.len > 0

proc looseSpawn(d: LootDb; p: PresetIndex; a: AmmoTable; r: var Rng;
                cfg: LootConfig; s: var PoolShaper;
                point: JsonRef; budget: var int; map = ""): string =
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
  # A loose point's distribution is keyed by the point's OWN item ids, not by
  # template ids, so the pool shaper is fed the template each candidate resolves
  # to. `shapeLoosePool` below does that mapping; with no shaping active it
  # returns the distribution untouched and nothing is looked up at all.
  let rawDist = readDistribution(raw(point.field("itemDistribution")))
  let dist = shapeLoosePool(d, cfg, s, list, rawDist, map)
  # EVERY candidate gated away is "this point spawns nothing", not "fall back to
  # the first candidate". The fallback below is for a point that never had a
  # distribution at all, and letting a gated-empty pool reach it was a MEASURED
  # bug: with lootRaritySuperrare=0 the fixture's loose point still spawned its
  # superrare rifle, because dropping the only weighted entry made `dist.len`
  # zero and that reads identically to "no distribution here".
  if rawDist.len > 0 and dist.len == 0:
    return ""
  if rawDist.len == 0 and s.active:
    # One candidate, laid out by hand: gate it directly.
    if not passesGates(d, cfg, s, tplForKey(list, rootId), map):
      return ""
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
               cfg: LootConfig; sh: var PoolShaper;
               locationId: string; chanceMul: float;
               budget: var int): seq[string] =
  result = @[]
  if not cfg.looseEnabled:
    return
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
  if cfg.forcedSpawns and isArray(forced):
    let pts = each(forced)
    for pt in pts:
      if budget <= 0:
        return
      let e = looseSpawn(d, p, a, r, cfg, sh, pt, budget, locationId)
      if e.len > 0:
        result.add e

  let points = child(rootRef, "spawnpoints")
  if not isArray(points):
    return
  var spawned = 0
  let pts = each(points)
  for pt in pts:
    if budget <= 0:
      return
    if cfg.loosePointLimit > 0 and spawned >= cfg.loosePointLimit:
      return
    let probability = pt.field("probability").asFloat(0.0) *
                      cfg.looseMultiplier * chanceMul
    if not chance(r, probability):
      continue
    let e = looseSpawn(d, p, a, r, cfg, sh, pt, budget, locationId)
    if e.len > 0:
      result.add e
      spawned = spawned + 1

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
  # THE PLANTING ROUND-TRIP, and it runs BEFORE the config gates below on
  # purpose: a planted item is a thing another mod's world says is really
  # there, and `lootEnabled=false` is a statement about the GENERATOR, not a
  # licence to delete somebody else's truth. With no planter subscribed this
  # returns an empty seq and every line below is byte-identical to before it
  # existed -- which is the negative control `plantcheck` asserts.
  let planted = composeLoot(if d.live: "" else: d.raw, locationId, raidId)
  if not cfg.enabled or cfg.maxItems <= 0:
    if planted.len == 0:
      return "[]"
    var only = newList()
    for e in planted:
      only.add e
    return text(only)
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
  # The global knob and the per-map override, both of which act on BOTH passes.
  # `perMap` is keyed by the DATABASE location id, which is what this proc was
  # handed -- an override naming a client-side map name resolves to nothing and
  # is reported by `lootConfigSummary`, not silently ignored.
  let mapMul = lookup(cfg.perMap, locationId, 1.0)
  containerMul = containerMul * cfg.globalMultiplier * mapMul
  looseMul = looseMul * cfg.globalMultiplier * mapMul
  # And the per-PASS per-map overrides, which are strictly more specific than
  # `lootPerMapMultipliers` above and therefore MULTIPLY it rather than replace
  # it: "half as much loot on Woods" and "and a third as much of it loose" are
  # two statements, and an operator who wrote both meant both. A map absent
  # from either list contributes 1.0, so a missing entry can never empty a map.
  containerMul = containerMul * lookup(cfg.staticPerMap, locationId, 1.0)
  looseMul = looseMul * lookup(cfg.loosePerMap, locationId, 1.0)
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
  # `lootStaticBudgetShare` is that half, made adjustable. At its default of
  # 0.5 this is byte-identical to the `budget div 2` it replaces.
  var staticShare = int(float(budget) * cfg.staticBudgetShare)
  if staticShare < 1:
    staticShare = budget
  if staticShare > budget:
    staticShare = budget
  var shaper = buildShaper(d, cfg)
  var staticBudget = staticShare
  let statics = staticContainers(d, p, ammo, r, cfg, shaper, locationId,
                                 containerMul, staticBudget)
  for e in statics:
    out1.add e
  # `staticBudget` is what that pass did *not* spend, so the sum of the two
  # halves is still exactly `maxItems`.
  var looseBudget = budget - staticShare + staticBudget
  let loose = looseLoot(d, p, ammo, r, cfg, shaper, locationId, looseMul,
                        looseBudget)
  for e in loose:
    out1.add e
  # How the shaping knobs LANDED, off the finished pass rather than off the
  # config that asked for it. A rarity weight that matched nothing, or a price
  # gate that found no handbook rows, says so here instead of reading to the
  # player as "the slider does nothing".
  if shaper.active:
    info "loot: " & locationId & " pool shaping applied -- price rows hit " &
         $shaper.priceHits & ", missed " & $shaper.priceMisses &
         "; rarity rows hit " & $shaper.rarityHits & ", missed " &
         $shaper.rarityMisses & "; entries removed " & $shaper.dropped
    if shaper.priceHits == 0 and needsPrices(cfg):
      warn "loot: a VALUE knob (lootValueBias/lootMinHandbookPrice/" &
           "lootMaxHandbookPrice) is set but NOT ONE pool entry was found in " &
           "templates.handbook.Items, so it changed nothing on " & locationId
    if shaper.rarityHits == 0 and (cfg.rarityCommon != 1.0 or
       cfg.rarityRare != 1.0 or cfg.raritySuperrare != 1.0):
      warn "loot: a RARITY knob is set but no pool entry on " & locationId &
           " declares _props.RarityPvE or _props.Rarity, so it changed nothing"
    if cfg.rules.active:
      info "loot: " & locationId & " " & summary(cfg.rules) &
           "; pool entries a rule touched " & $shaper.ruleHits &
           ", removed " & $shaper.ruleDrops
      # The falsifiable half. A rule set that matched NOTHING is the failure
      # this whole system is most likely to produce -- a mistyped id reweights
      # an empty set and everything reports success -- so it gets a warning of
      # its own rather than a zero buried in the line above.
      if shaper.ruleHits == 0:
        warn "loot: " & $cfg.rules.len & " loot rule(s) are declared but NOT " &
             "ONE pool entry on " & locationId & " matched any of them. " &
             "Set lootRuleExplain to a template id to see why."
    if shaper.explained.len > 0:
      info "loot: lootRuleExplain " & cfg.explainTpl & " on " & locationId &
           "\n" & shaper.explained
    elif cfg.explainTpl.len > 0:
      info "loot: lootRuleExplain " & cfg.explainTpl & " -- that template " &
           "never appeared in any pool on " & locationId & ", so there is " &
           "nothing to explain. That is INCONCLUSIVE, not 'no rule matched'."
  # Appended last so the generator's own budget arithmetic above is untouched
  # by them: a planted item is not a roll and must not displace one.
  for e in planted:
    out1.add e
  result = text(out1)

proc fmt2(v: float): string =
  ## `1.50` out of a float without `formatFloat` (which is `.raises`). Two
  ## decimals is enough for every multiplier on the Loot page and the summary
  ## line is prose, not a value anyone parses back.
  var x = v
  var sign = ""
  if x < 0.0:
    sign = "-"
    x = -x
  let whole1 = int(x)
  var frac = int((x - float(whole1)) * 100.0 + 0.5)
  var carry = 0
  if frac >= 100:
    frac = frac - 100
    carry = 1
  var fs = $frac
  if fs.len < 2: fs = "0" & fs
  result = sign & $(whole1 + carry) & "." & fs

proc lootConfigSummary*(): string =
  ## One sentence describing what the CURRENT loot configuration will do,
  ## written back into the `lootSummary` row so the Loot page is legible without
  ## the documentation. Derived from `lootConfig()` -- the same object generation
  ## reads -- so it cannot describe a configuration the generator is not using.
  let cfg = lootConfig()
  if not cfg.enabled:
    return "OFF -- every map spawns an empty floor (lootEnabled is false)."
  if cfg.maxItems <= 0:
    return "OFF -- maxLootItems is 0, so nothing can spawn."
  if not cfg.staticEnabled and not cfg.looseEnabled:
    return "OFF -- both the container pass and the loose pass are disabled."
  let containers = cfg.globalMultiplier * cfg.staticMultiplier *
                   cfg.containerChanceMul
  let fill = cfg.globalMultiplier * cfg.staticMultiplier * cfg.containerFillMul
  let loose = cfg.globalMultiplier * cfg.looseMultiplier
  result = "Containers x" & fmt2(containers) & " to spawn, x" & fmt2(fill) &
           " as full (cap " & $cfg.containerMaxItems & " items each)"
  if not cfg.staticEnabled:
    result = "Containers OFF"
  var loosePart = "; loose loot x" & fmt2(loose)
  if not cfg.looseEnabled:
    loosePart = "; loose loot OFF"
  elif cfg.loosePointLimit > 0:
    loosePart = loosePart & ", at most " & $cfg.loosePointLimit & " points"
  result = result & loosePart
  if not cfg.forcedSpawns:
    result = result & "; quest/key forced spawns OFF"
  if cfg.valueBias > 0.0:
    result = result & "; biased toward items dearer than " &
             $int(cfg.valuePivot) & " roubles"
  elif cfg.valueBias < 0.0:
    result = result & "; biased toward items cheaper than " &
             $int(cfg.valuePivot) & " roubles"
  if cfg.minPrice > 0:
    result = result & "; nothing under " & $cfg.minPrice & " roubles"
  if cfg.maxPrice > 0:
    result = result & "; nothing over " & $cfg.maxPrice & " roubles"
  if cfg.rarityCommon != 1.0 or cfg.rarityRare != 1.0 or
     cfg.raritySuperrare != 1.0:
    result = result & "; rarity weights common x" & fmt2(cfg.rarityCommon) &
             " rare x" & fmt2(cfg.rarityRare) & " superrare x" &
             fmt2(cfg.raritySuperrare)
  if cfg.categoryWeights.len > 0:
    result = result & "; " & $cfg.categoryWeights.len &
             " category weight(s) in effect"
  if cfg.stackRandomRange:
    result = result & "; stacks use the template's own StackMin/MaxRandom range"
  if cfg.stackMultiplier != 1.0:
    result = result & "; stack sizes x" & fmt2(cfg.stackMultiplier)
  if cfg.stackMaxFraction < 1.0:
    result = result & "; stacks capped at " &
             $int(cfg.stackMaxFraction * 100.0) & "% of the item's stack limit"
  if cfg.perMap.len > 0:
    result = result & "; " & $cfg.perMap.len & " per-map override(s)"
  if cfg.containerTypeChance.len > 0:
    result = result & "; " & $cfg.containerTypeChance.len &
             " per-container-type chance(s)"
  result = result & "."

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
  # The new gates get the same treatment as the two above: an empty floor names
  # the knob that emptied it. Each of these is individually capable of producing
  # exactly the `[]` that used to mean "something is broken".
  if not cfg.staticEnabled and not cfg.looseEnabled:
    warn "loot: " & locationId & " served NO loot because BOTH " &
         "`staticLootEnabled` and `looseLootEnabled` are false"
    return
  if cfg.globalMultiplier == 0.0:
    warn "loot: " & locationId & " served NO loot because " &
         "`lootGlobalMultiplier` is 0"
    return
  if lookup(cfg.perMap, locationId, 1.0) == 0.0:
    warn "loot: " & locationId & " served NO loot because " &
         "`lootPerMapMultipliers` sets this map to 0"
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
    "handbook": {
      "Items": [
        { "Id": "aaaaammo0000000000000001", "ParentId": "hb_ammo", "Price": 100 },
        { "Id": "bbbbbox00000000000000002", "ParentId": "hb_ammo", "Price": 2000 },
        { "Id": "wwwwgun00000000000000001", "ParentId": "hb_guns", "Price": 50000 },
        { "Id": "qqqquest0000000000000001", "ParentId": "hb_quest", "Price": 1 }
      ]
    },
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
        "_parent": "pppparent000000000000ammo",
        "_props": { "Name": "Test cartridge", "Width": 1, "Height": 1, "StackMaxSize": 60,
                    "StackMinRandom": 2, "StackMaxRandom": 4,
                    "RarityPvE": "Common" }
      },
      "pppparent000000000000ammo": {
        "_id": "pppparent000000000000ammo",
        "_props": { "Name": "Test ammo base class" }
      },
      "bbbbbox00000000000000002": {
        "_id": "bbbbbox00000000000000002",
        "_parent": "pppparent000000000000ammo",
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
                    "RarityPvE": "Superrare",
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

proc hex16(v: uint64): string =
  const Digits = "0123456789abcdef"
  result = ""
  var i = 60
  while i >= 0:
    result.add Digits[int((v shr uint64(i)) and 0xF'u64)]
    i = i - 4

proc lootBatchHash*(d: LootDb; cfg: LootConfig; locationId, seed: string;
                    n: int; items: var int; bytes: var int): string =
  ## Generate `n` consecutive raids from a fixed seed and hash every byte of
  ## every payload into one number.
  ##
  ## This exists because "the defaults reproduce the previous behaviour" was
  ## being asserted by construction -- "each new knob is skipped at its
  ## default, therefore the stream is unchanged" -- and an argument about
  ## control flow is not a measurement of output. A claim about generated loot
  ## has to be checked against generated loot.
  ##
  ## The check it enables has BOTH halves, and the second is the one that
  ## matters: same seed + defaults before and after must give the SAME digest,
  ## and one knob moved must give a DIFFERENT one. Without the second half the
  ## instrument could be returning a constant and the first half would still
  ## pass, which is the check-that-cannot-fail this repository keeps shipping.
  ##
  ## The digest is order- and position-sensitive (the running hash is folded
  ## with the raid index and the payload length as well as the text), so two
  ## batches that contain the same items in a different order do NOT collide.
  var h = hashText("aowl-loot-batch|" & locationId & "|" & seed)
  items = 0
  bytes = 0
  for i in 0 ..< n:
    let raidId = seed & "#" & $i
    let payload = generateLoot(d, cfg, locationId, raidId)
    bytes = bytes + payload.len
    items = items + countOccurrences(payload, "\"_tpl\"")
    h = h xor hashText(payload)
    h = h * 0x100000001B3'u64
    h = h xor uint64(i * 2654435761)
    h = h xor uint64(payload.len)
    h = h * 0x100000001B3'u64
  result = hex16(h)

proc lootBatchHashText*(document, locationId, seed, ruleText: string;
                        n: int; items: var int; bytes: var int): string =
  ## `lootBatchHash` over a JSON document, with an optional rule set applied on
  ## top of the DEFAULT config. `ruleText` empty means "defaults, untouched" --
  ## and `addRuleText("")` adds no rule at all, so the defaults path is
  ## byte-identical to the one a stock install takes, not a neighbouring one.
  var cfg = defaultLootConfig()
  addRuleText(cfg.rules, ruleText)
  result = lootBatchHash(textDb(document), cfg, locationId, seed, n,
                         items, bytes)

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

  # -- THE NEW KNOBS --------------------------------------------------------
  #
  # Every one of these is a NEGATIVE or a difference against the default floor
  # `a`, never a re-read of what the knob was set to. The default-preserving
  # claim is the first and the most important: it is falsified the moment any
  # new field's default is not the old hardcoded value.
  var freshCfg = defaultLootConfig()
  # The default-preservation claim, stated so that it CAN fail.
  #
  # Comparing `generateLoot` at defaults against `generateLoot` at defaults is a
  # tautology and was the first version of this check -- it passed with the
  # container cap default deliberately changed from 64 to 63, which is exactly
  # the class of check this repo's rule 9b is about. So the defaults are named
  # against the constants the generator used to hardcode, one by one.
  check(result, freshCfg.globalMultiplier == 1.0 and
                freshCfg.staticEnabled and freshCfg.looseEnabled and
                freshCfg.forcedSpawns and
                freshCfg.staticBudgetShare == 0.5 and
                freshCfg.containerChanceMul == 1.0 and
                freshCfg.containerFillMul == 1.0 and
                freshCfg.containerMaxItems == 64 and
                freshCfg.loosePointLimit == 0 and
                freshCfg.valueBias == 0.0 and
                freshCfg.minPrice == 0 and freshCfg.maxPrice == 0 and
                freshCfg.rarityCommon == 1.0 and freshCfg.rarityRare == 1.0 and
                freshCfg.raritySuperrare == 1.0 and
                freshCfg.categoryWeights.len == 0 and
                freshCfg.perMap.len == 0 and
                freshCfg.containerTypeChance.len == 0 and
                (not freshCfg.stackRandomRange) and
                freshCfg.stackMultiplier == 1.0 and
                freshCfg.stackMaxFraction == 1.0,
        "every new knob's DEFAULT is the constant the generator hardcoded " &
        "before it existed (64-item cap, half the budget, no shaping)")
  check(result, not shapesPool(freshCfg),
        "at defaults the pool-shaping code is SKIPPED, not run with neutral " &
        "numbers -- which is what makes 'defaults change nothing' structural")

  # Strict JSON, not `contains`. `parseArray(...).ok` is the whole-document
  # parser, so a payload that is not valid JSON fails here rather than passing
  # on a substring the way this project's flea selftest did for months.
  var payloads: seq[string] = @[]
  var names: seq[string] = @[]

  var noStatic = defaultLootConfig()
  noStatic.staticEnabled = false
  let pNoStatic = generateLoot(d, noStatic, "testmap", "raid-one")
  check(result, countOccurrences(pNoStatic, "\"crate_1\"") == 0,
        "staticLootEnabled=false: the crate is GONE from the floor")
  payloads.add pNoStatic
  names.add "staticLootEnabled=false"

  var noLoose = defaultLootConfig()
  noLoose.looseEnabled = false
  let pNoLoose = generateLoot(d, noLoose, "testmap", "raid-one")
  check(result, countOccurrences(pNoLoose, "\"crate_1\"") > 0 and
                countOccurrences(pNoLoose, "\"_tpl\"") <
                countOccurrences(a, "\"_tpl\""),
        "looseLootEnabled=false: the crate stays, the floor loses items")
  payloads.add pNoLoose
  names.add "looseLootEnabled=false"

  var zeroGlobal = defaultLootConfig()
  zeroGlobal.globalMultiplier = 0.0
  let pZero = generateLoot(d, zeroGlobal, "testmap", "raid-one")
  check(result, countOccurrences(pZero, "\"crate_1\"") == 0,
        "lootGlobalMultiplier=0 removes every chance-rolled container")
  payloads.add pZero
  names.add "lootGlobalMultiplier=0"

  var perMapZero = defaultLootConfig()
  perMapZero.perMap = parseKvList("testmap=0")
  check(result, generateLoot(d, perMapZero, "testmap", "raid-one") != a,
        "lootPerMapMultipliers reaches the map it names")
  var perMapOther = defaultLootConfig()
  perMapOther.perMap = parseKvList("othermap=0")
  check(result, generateLoot(d, perMapOther, "testmap", "raid-one") == a,
        "lootPerMapMultipliers does NOT reach a map it does not name")

  var capOne = defaultLootConfig()
  capOne.containerMaxItems = 1
  let pCap = generateLoot(d, capOne, "testmap", "raid-one")
  check(result, countOccurrences(pCap, "\"_tpl\"") <
                countOccurrences(a, "\"_tpl\""),
        "containerMaxItems caps what a crate can hold")
  payloads.add pCap
  names.add "containerMaxItems=1"

  var fillUp = defaultLootConfig()
  fillUp.containerFillMul = 4.0
  check(result, countOccurrences(generateLoot(d, fillUp, "testmap", "raid-one"),
                                 "\"_tpl\"") >
               countOccurrences(a, "\"_tpl\""),
        "containerFillMultiplier puts more in the crate")

  var chanceOff = defaultLootConfig()
  chanceOff.containerChanceMul = 0.0
  check(result, countOccurrences(generateLoot(d, chanceOff, "testmap",
                                              "raid-one"), "\"crate_1\"") == 0,
        "containerSpawnChanceMultiplier=0 stops containers spawning")

  var typeOff = defaultLootConfig()
  typeOff.containerTypeChance = parseKvList("ccccbox00000000000000001=0")
  check(result, countOccurrences(generateLoot(d, typeOff, "testmap",
                                              "raid-one"), "\"crate_1\"") == 0,
        "containerTypeChances=0 on the crate's TEMPLATE stops it spawning")
  var typeOther = defaultLootConfig()
  typeOther.containerTypeChance = parseKvList("notacontainer00000000000=0")
  check(result, generateLoot(d, typeOther, "testmap", "raid-one") == a,
        "containerTypeChances does NOT touch a template it does not name")

  var noForced = defaultLootConfig()
  noForced.forcedSpawns = false
  let pForced = generateLoot(d, noForced, "testmap", "raid-one")
  check(result, countOccurrences(pForced, "\"_tpl\"") <
                countOccurrences(a, "\"_tpl\""),
        "lootForcedSpawns=false drops the forced spawn point")
  payloads.add pForced
  names.add "lootForcedSpawns=false"

  var pointCap = defaultLootConfig()
  pointCap.loosePointLimit = 1
  payloads.add generateLoot(d, pointCap, "testmap", "raid-one")
  names.add "looseLootPointLimit=1"

  # The price gate. The fixture's handbook prices the cartridge at 100 and the
  # rifle at 50,000, so a floor of 10,000 must remove the CARTRIDGE from every
  # crate and leave the rifle. A negative, over three seeds, so it cannot pass
  # on one lucky roll.
  var shaped = defaultLootConfig()
  shaped.minPrice = 10000
  # The counted item is the AMMO BOX (handbook 2,000): it is only ever produced
  # by a pool draw. The cartridge cannot be counted this way -- it is also
  # emitted as a CHILD of magazines and ammo boxes, which is not a pool draw and
  # is correctly not gated, so counting it would test the wrong thing.
  var cheapSeen = 0
  var dearSeen = 0
  var pShaped = ""
  for seedName in @["raid-one", "raid-two", "raid-three"]:
    let g = generateLoot(d, shaped, "testmap", seedName)
    if pShaped.len == 0: pShaped = g
    cheapSeen = cheapSeen +
                countOccurrences(g, "\"bbbbbox00000000000000002\"")
    dearSeen = dearSeen + countOccurrences(g, "\"wwwwgun00000000000000001\"")
  var cheapDefault = 0
  for seedName in @["raid-one", "raid-two", "raid-three"]:
    cheapDefault = cheapDefault +
      countOccurrences(generateLoot(d, freshCfg, "testmap", seedName),
                       "\"bbbbbox00000000000000002\"")
  check(result, cheapDefault > 0,
        "the fixture spawns the cheap item by default on the SAME three " &
        "seeds (the price gate has a denominator)")
  check(result, dearSeen > 0,
        "lootMinHandbookPrice=10000: the 50,000-rouble item still spawns")
  check(result, cheapSeen == 0,
        "lootMinHandbookPrice=10000: the 2,000-rouble item is GONE from " &
        "every pool on three seeds")
  payloads.add pShaped
  names.add "lootMinHandbookPrice"

  # Rarity. Superrare is weighted to zero, so the rifle -- the fixture's only
  # superrare -- must not appear, while the common cartridge still does.
  var rare = defaultLootConfig()
  rare.raritySuperrare = 0.0
  var rifleSeen = 0
  var ammoSeen = 0
  var pRare = ""
  for seedName in @["raid-one", "raid-two", "raid-three"]:
    let g = generateLoot(d, rare, "testmap", seedName)
    if pRare.len == 0: pRare = g
    rifleSeen = rifleSeen + countOccurrences(g, "\"wwwwgun00000000000000001\"")
    ammoSeen = ammoSeen + countOccurrences(g, "\"aaaaammo0000000000000001\"")
  check(result, ammoSeen > 0,
        "the common item still spawns when superrare is zeroed")
  check(result, rifleSeen == 0,
        "lootRaritySuperrare=0: the superrare item is GONE on three seeds")
  payloads.add pRare
  names.add "lootRaritySuperrare=0"

  # Category weights, via the `_parent` walk: the cartridge's BASE CLASS is
  # zeroed, not the cartridge itself, so this fails if the chain is not walked.
  var cats = defaultLootConfig()
  cats.categoryWeights = parseKvList("pppparent000000000000ammo=0")
  var catAmmo = 0
  var pCats = ""
  for seedName in @["raid-one", "raid-two", "raid-three"]:
    let g = generateLoot(d, cats, "testmap", seedName)
    if pCats.len == 0: pCats = g
    catAmmo = catAmmo + countOccurrences(g, "\"bbbbbox00000000000000002\"")
  check(result, catAmmo == 0,
        "lootCategoryWeights=0 on the PARENT class removes the child item " &
        "(the ammo box is named nowhere; only its _parent is)")
  payloads.add pCats
  names.add "lootCategoryWeights"

  # Stacks. The fixture cartridge stacks to 60 and declares StackMinRandom 2 /
  # StackMaxRandom 4, so the two stack knobs have visibly different ranges.
  var stacks = defaultLootConfig()
  stacks.stackMaxFraction = 0.01
  var stacksDiffer = false
  var pStacks = ""
  for seedName in @["raid-one", "raid-two", "raid-three"]:
    let g = generateLoot(d, stacks, "testmap", seedName)
    if pStacks.len == 0: pStacks = g
    if g != generateLoot(d, freshCfg, "testmap", seedName):
      stacksDiffer = true
  check(result, stacksDiffer,
        "lootStackMaxFraction changes the emitted stack counts")
  payloads.add pStacks
  names.add "lootStackMaxFraction=0.01"

  var stackRange1 = defaultLootConfig()
  stackRange1.stackRandomRange = true
  var rangeDiffers = false
  var pRange = ""
  for seedName in @["raid-one", "raid-two", "raid-three"]:
    let g = generateLoot(d, stackRange1, "testmap", seedName)
    if pRange.len == 0: pRange = g
    if g != generateLoot(d, freshCfg, "testmap", seedName):
      rangeDiffers = true
  check(result, rangeDiffers,
        "lootStackRandomRange uses the template's declared 2..4 range instead " &
        "of the 1..60 StackMaxSize roll")
  payloads.add pRange
  names.add "lootStackRandomRange=true"

  var share = defaultLootConfig()
  share.staticBudgetShare = 1.0
  payloads.add generateLoot(d, share, "testmap", "raid-one")
  names.add "lootStaticBudgetShare=1.0"

  # STRICT parse of every payload above. A generator that emits a truncated or
  # malformed array fails here even when the item counts happen to look right.
  var allParse = true
  var firstBad = ""
  for i in 0 ..< payloads.len:
    let arr = parseArray(payloads[i])
    if not arr.ok:
      allParse = false
      if firstBad.len == 0: firstBad = names[i]
  check(result, payloads.len >= 10,
        "there are payloads to parse (the strict check is not vacuous)")
  check(result, allParse,
        "every knob's payload parses STRICTLY as a JSON array" &
        (if firstBad.len > 0: " (first failure: " & firstBad & ")" else: ""))

  # The kv parser: a typo must not empty the list, and must not be read as 0.
  let kv = parseKvList("bigmap=1.5, woods = 0.5, broken, alsobroken=, x=abc")
  check(result, kv.len == 2 and lookup(kv, "bigmap", -1.0) == 1.5 and
                lookup(kv, "woods", -1.0) == 0.5,
        "parseKvList keeps the good pairs and drops the malformed ones")
  check(result, lookup(kv, "alsobroken", 7.0) == 7.0 and
                lookup(kv, "x", 7.0) == 7.0,
        "a malformed pair is ABSENT, not present as zero")

proc selfCheck*(): string = selfCheck(Fixture)

