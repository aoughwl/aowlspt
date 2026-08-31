## Traders: who they are, and what they have for sale.
##
## Two shapes, and they are not interchangeable. `base` is the trader itself —
## name, currency, loyalty levels, insurance — and the client reads every one of
## them at the menu. `assort` is the stock: an item list, a barter scheme naming
## what each costs, and a loyalty gate per offer. A trader with a base and no
## assort is a trader you can visit and cannot buy from, which is a valid state
## and the one used when the database has no stock for them.
##
## Everything comes out of the database under `traders.<id>`, so a server with a
## live dump has the real traders and a server with the test fixture has none —
## and the menu still opens either way, which is the property that matters.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import numbers
import profile
import fence

proc traderIds*(): seq[string] =
  ## Every trader in the database, in document order.
  result = @[]
  let all = dbRead("traders")
  if not all.ok:
    return
  result = keys(whole(all.raw))

proc traderBase*(id: string): string =
  let v = dbRead("traders." & id & ".base")
  if v.ok and v.raw.len > 0:
    return v.raw
  result = ""

proc traderHidden*(base: string): bool =
  ## Whether a trader's base carries the `aowlHidden` flag.
  ##
  ## A general mechanism rather than one mod's special case: any mod can write
  ## `traders.<id>.base.aowlHidden = true` and that trader stops being offered
  ## to the client. `dbWrite` MERGES, so setting it leaves every other field of
  ## the base exactly as the database holds it, and clearing it restores the
  ## trader with nothing lost. Nothing is deleted, which is why this is
  ## reversible at all.
  ##
  ## Absent, or present and false, both mean visible. A trader is hidden only
  ## by an explicit `true` -- so a database that has never heard of this flag
  ## behaves exactly as it did before, which is the property that lets it ship
  ## on by default.
  if base.len == 0:
    return false
  let root = whole(base)
  if not isObject(root):
    return false
  result = field(root, "aowlHidden").asBool(false)

proc traderSettings*(): string =
  ## The array the client's trader screen is built from.
  var a = arr()
  let ids = traderIds()
  for id in ids:
    let base = traderBase(id)
    if base.len > 0 and not traderHidden(base):
      a.add raw(base)
  result = done(a).text

proc emptyAssort(): string =
  ## The shape of "this trader has nothing", spelled out. An empty *object*
  ## here instead of these three empty collections is a null dereference in the
  ## trading screen -- the client indexes `items` before it checks it.
  var o = obj()
  put(o, "nextResupply", 0)
  put(o, "items", arr())
  put(o, "barter_scheme", obj())
  put(o, "loyal_level_items", obj())
  result = done(o).text

proc stampRequirementTypes*(barterRaw: string): string =
  ## Post-1.0 stamps every barter-scheme requirement with a `type`
  ## discriminator -- `"ItemRequirement"` for the ordinary "hand over N of a
  ## template" cost. SPT's database, which is where our assorts come from,
  ## predates it and omits the field entirely: a requirement is just
  ## `{count, _tpl}`.
  ##
  ## The post-1.0 client will not confirm a purchase whose cost carries no
  ## type. The trade screen opens, the offer draws, and the buy button spins
  ## forever with no error on either side -- the client is waiting to classify
  ## a requirement it cannot, and nothing it receives back moves it on. So the
  ## field is stamped onto every requirement here, at serve time, leaving the
  ## stored assort exactly as the database holds it.
  let root = whole(barterRaw)
  if not isObject(root):
    return barterRaw
  var o = obj()
  for offerId in keys(root):
    var armsArr = arr()
    for arm in each(field(root, offerId)):
      var reqArr = arr()
      for req in each(arm):
        var r = obj()
        # `type` first, then the requirement's own fields verbatim -- numbers
        # stay numbers because each value is copied as the raw text it was.
        put(r, "type", "ItemRequirement")
        for k in keys(req):
          if k == "type":
            continue
          if k == "count":
            # The one field the price multiplier touches. Everything else is
            # copied as its own raw text, so numbers stay numbers.
            put(r, "count", scaleTraderCount(field(req, k).asInt(0)))
            continue
          put(r, k, raw(field(req, k).raw()))
        reqArr.add r
      armsArr.add reqArr
    put(o, offerId, armsArr)
  result = done(o).text

var gUnlockAllOffers* = false
  ## Sell a trader's whole stock from loyalty level 1.
  ##
  ## **Off.** It was `true`, and the effect was not subtle: `allLoyaltyOne`
  ## rewrote every value in `loyal_level_items` to 1, so Prapor's 422 gated
  ## entries and Jaeger's were all buyable at level 1 with nothing done. A
  ## player asking "is anything unlocked by quests here" got "no" without ever
  ## being told a switch had been flipped for them.
  ##
  ## Set `traderUnlockAllOffers` on the settings page to get the sandbox back.
  ## The default is the honest one; the shortcut is opt-in.

var gTraderPriceMultiplier = 1.0
  ## What every trader cost is multiplied by.
  ##
  ## Applied in TWO places and it has to be, which is why it lives here rather
  ## than at either of them: `stampRequirementTypes` builds the cost the CLIENT
  ## draws, and `schemeArm` in `emu/trading` reads the cost the server CHARGES.
  ## Scaling only the first produces a shop showing half price and refusing the
  ## payment; scaling only the second produces a shop that quietly takes a
  ## different number from the one on the label.

var gIgnoreStockLimits = false
  ## Whether a trader's `upd.StackObjectsCount` bounds a purchase.
  ##
  ## The assort's stock count is the per-item purchase limit -- the thing that
  ## makes `buyFromTrader` answer "that trader has only 2 of those". Turning
  ## this on removes that one check and nothing else: loyalty and quest gating
  ## are `traderUnlockAllOffers`, and the price is
  ## `traderPriceMultiplier`. Off by default, because unlimited stock is a
  ## different game and nobody should get it without asking.

var gMaxLoyalty* = false
  ## Whether every trader sits at their HIGHEST loyalty level regardless of the
  ## player's level, sales sum and standing.
  ##
  ## This is a different axis from `traderUnlockAllOffers`, and the two were
  ## being confused. `traderUnlockAllOffers` rewrites the ASSORT -- it moves
  ## every offer down to loyalty 1, so nothing is gated. `traderMaxLoyalty`
  ## moves the PLAYER up -- `TradersInfo.<id>.loyaltyLevel` becomes the last
  ## level the trader's `loyaltyLevels` array defines, which is also what
  ## `emu/health` and `emu/repair` read for their price coefficients and what
  ## `emu/production` reads to gate a hideout recipe. Neither one implies the
  ## other, and either alone answers "that offer needs loyalty level 2 and you
  ## are 1".
  ##
  ## It has to live in `loyaltyLevelFor` rather than being written once onto
  ## the profile: `refreshLoyalty` re-derives the stored number from that
  ## function after every purchase, quest reward and scav run, so a value only
  ## written to the profile is recomputed away by the next trade.

proc configureTraders*(unlockAll: bool; priceMultiplier: float;
                       ignoreStockLimits: bool; maxLoyalty = false) =
  gUnlockAllOffers = unlockAll
  gTraderPriceMultiplier = priceMultiplier
  gIgnoreStockLimits = ignoreStockLimits
  gMaxLoyalty = maxLoyalty

proc traderPriceMultiplier*(): float = gTraderPriceMultiplier

proc traderIgnoreStockLimits*(): bool = gIgnoreStockLimits

proc scaleTraderCount*(count: int): int =
  ## A requirement count with the price multiplier applied.
  ##
  ## Never below 1 for a cost that started above zero: rounding a price to zero
  ## turns "cheap" into "free", and free is a different game from cheap. A
  ## requirement that was already zero stays zero, because that is a gift the
  ## database is describing and not a price at all.
  if count <= 0:
    return count
  if gTraderPriceMultiplier == 1.0:
    return count
  result = int(float(count) * gTraderPriceMultiplier + 0.5)
  if result < 1:
    result = 1

proc allLoyaltyOne(loyalRaw: string): string =
  ## Every offer at loyalty level 1. `loyal_level_items` maps an offer id to the
  ## level it needs; rewriting every value to 1 unlocks the lot -- client-side
  ## nothing greys out, and server-side `offerLoyalty` then returns 1, which
  ## every profile meets, so `buyFromTrader` allows the purchase. No profile or
  ## character-level edit, so nothing here can break the menu boot.
  let root = whole(loyalRaw)
  if not isObject(root):
    return loyalRaw
  var o = obj()
  for offerId in keys(root):
    put(o, offerId, 1)
  result = done(o).text

const FenceRefreshSeconds* = 1800
  ## How long one generated Fence stock lasts. The same number is served as
  ## `nextResupply` and used to bucket the generator seed, so the countdown the
  ## client draws and the moment the stock actually changes are the same event.

proc traderAssort*(id: string; resupplyAt: int): string =
  # Fence is GENERATED, not stored.
  #
  # Four of the twelve traders serve a zero-item assort. Measured, and they are
  # not one problem:
  #
  #   Fence  `579dc571...`  -- SPT's assort.json is 68 bytes because SPT
  #       generates the stock at runtime. A stored-empty assort here is a
  #       missing generator, and `emu/fence` is it. FIXED.
  #   Ref    `638f541a...`  -- `unlockedByDefault: true`, and empty. Ref trades
  #       for GP coins, an Arena currency this server has no source of; an
  #       invented rouble-priced Ref would be a shop selling Arena rewards for
  #       money, which is a worse lie than an empty shelf. Deliberately left
  #       empty. STATED, not fixed.
  #   BTR    `656f0f98...`  -- `unlockedByDefault: false`, and not a shop at
  #       all: it is the armoured-transport service, whose interactions are the
  #       taxi and delivery routes, not an assort. Empty is CORRECT.
  #       (Its nickname is not empty either -- it is the Cyrillic "BTR".)
  #   Storyteller `6864e812f9fe664cb8b8e152` -- `unlockedByDefault: false`, no
  #       assort in SPT's own data, and gated behind content this server does
  #       not run. Empty is CORRECT.
  #
  # So exactly one of the four was a bug, and three item lists that would have
  # been invented are not invented.
  if id == FenceId:
    return fenceAssort(resupplyAt, FenceRefreshSeconds)
  let v = dbRead("traders." & id & ".assort")
  if not v.ok or v.raw.len == 0:
    return emptyAssort()
  # `nextResupply` is a timestamp the client counts down to. Taken from the
  # database when it is there and stamped here when it is not, because a
  # missing one shows as a stock timer that has already expired.
  let existing = field(v.raw, "nextResupply")
  var o = obj()
  if existing.found:
    put(o, "nextResupply", raw(existing.raw()))
  else:
    put(o, "nextResupply", resupplyAt)
  put(o, "items", raw(field(v.raw, "items").raw()))
  put(o, "barter_scheme",
      raw(stampRequirementTypes(field(v.raw, "barter_scheme").raw())))
  let loyal = field(v.raw, "loyal_level_items").raw()
  put(o, "loyal_level_items",
      raw(if gUnlockAllOffers: allLoyaltyOne(loyal) else: loyal))
  result = done(o).text

proc traderExists*(id: string): bool =
  result = traderBase(id).len > 0

# `newTradersInfo` used to live here and had zero callers, while
# `emu/profile` wrote `TradersInfo: {}` on every new profile. It is now
# `seedTradersInfo` in `emu/starterkit`, which is where the edition's
# `initialLoyaltyLevel` / `initialStanding` / `jaegerUnlocked` /
# `lockedByDefaultOverride` block is read -- and it is CALLED.

# ---------------------------------------------------------------------------
# The player's standing with a trader
# ---------------------------------------------------------------------------
#
# `TradersInfo.<id>` on the profile is the reference's `TraderInfo`:
# `loyaltyLevel`, `salesSum`, `standing`, `unlocked`, `disabled`,
# `nextResupply`. The trader's own `loyaltyLevels` array is the reference's
# `TraderLoyaltyLevel`, and the three fields that decide whether a level is
# reached are `minLevel`, `minSalesSum` and `minStanding`.
#
# Which means loyalty is not a thing the server *awards*. It is a thing the
# server *derives*, from three numbers it already keeps, and re-derived after
# every one of them moves. That matters more than it sounds: a level handed out
# once and stored is a level that survives the standing loss that should have
# taken it away, and the client gates the assort on the number the profile
# carries.

proc traderEntry*(p: Profile; traderId: string): Doc =
  ## One trader's entry, with the four fields the client reads before it draws
  ## the trader at all filled in when the profile has no entry yet.
  result = parseObject(getRaw(parseObject(p.field("TradersInfo").raw()),
                              traderId))
  if result.ok:
    return
  result = newDoc()
  setNumber(result, "loyaltyLevel", 1)
  setNumber(result, "salesSum", 0)
  setNumber(result, "standing", 0.0)
  setBool(result, "unlocked", true)
  setBool(result, "disabled", false)

proc putTraderEntry*(p: var Profile; traderId: string; entry: Doc) =
  var info = parseObject(p.field("TradersInfo").raw())
  if not info.ok:
    info = newDoc()
  setRaw(info, traderId, text(entry))
  p.setTopLevel("TradersInfo", text(info))

proc loyaltyLevelFor*(traderId: string; level, salesSum: int;
                      standing: float): int =
  ## The highest loyalty level whose three requirements are all met.
  ##
  ## Level 1 is the floor: every trader the player can talk to is at least LL1,
  ## and a trader whose base has no `loyaltyLevels` -- which is every trader on
  ## a server with no database -- stays there rather than becoming unreachable.
  ##
  ## The array is walked from the start and stops at the first level *not*
  ## reached, rather than taking the best match anywhere in it. The levels are
  ## ordered and their requirements are cumulative; a player who meets LL4's
  ## sales sum but not LL2's standing has not reached LL4.
  result = 1
  let base = traderBase(traderId)
  if base.len == 0:
    return
  let levels = each(field(base, "loyaltyLevels"))
  if gMaxLoyalty:
    # The top of the array this trader actually declares, not a fixed 4: the
    # levels are per trader and a number past the end is a level the client has
    # no row for.
    return (if levels.len > 1: levels.len else: 1)
  var index = 0
  for l in levels:
    inc index
    if index == 1:
      # The array's first entry describes LL1, which is where everyone starts.
      continue
    if level < l.field("minLevel").asInt(0):
      return
    if salesSum < l.field("minSalesSum").asInt(0):
      return
    if standing < l.field("minStanding").asFloat(0.0):
      return
    result = index

proc refreshLoyalty*(p: var Profile; traderId: string): int =
  ## Recomputes and stores one trader's loyalty level. Returns it.
  var entry = traderEntry(p, traderId)
  let now1 = loyaltyLevelFor(traderId, p.level,
                             get(entry, "salesSum").asInt(0),
                             get(entry, "standing").asFloat(0.0))
  setNumber(entry, "loyaltyLevel", now1)
  putTraderEntry(p, traderId, entry)
  result = now1

proc addStanding*(p: var Profile; traderId: string; delta: float) =
  ## Moves one trader's standing, leaving every other field of their entry --
  ## `salesSum`, `unlocked`, `nextResupply` -- exactly as it was, and then
  ## re-derives the loyalty level the new standing earns.
  if traderId.len == 0 or delta == 0.0:
    return
  var entry = traderEntry(p, traderId)
  # Through `numText` rather than the float overload of `setNumber`: `$` on a
  # float writes the shortest text that round-trips the binary value, so two
  # scav runs worth 0.01 each stored a standing of `0.020000000000000004` and
  # every further run made it longer. See `numText` in `emu/profile`.
  setRaw(entry, "standing",
         numText(get(entry, "standing").asFloat(0.0) + delta))
  putTraderEntry(p, traderId, entry)
  discard refreshLoyalty(p, traderId)

proc addSalesSum*(p: var Profile; traderId: string; roubles: int) =
  ## Credits money that changed hands with a trader.
  ##
  ## Standing is deliberately **not** moved here. The reference gives the three
  ## requirements a loyalty level has and says nothing about what a purchase is
  ## worth in reputation, and a rate invented here would be a number nobody can
  ## check. Standing moves where the reference does describe it: quest rewards,
  ## in `emu/quests`.
  if traderId.len == 0 or roubles <= 0:
    return
  var entry = traderEntry(p, traderId)
  setNumber(entry, "salesSum", get(entry, "salesSum").asInt(0) + roubles)
  putTraderEntry(p, traderId, entry)
  discard refreshLoyalty(p, traderId)

proc loyaltyOf*(p: Profile; traderId: string): int =
  result = get(traderEntry(p, traderId), "loyaltyLevel").asInt(1)
  if result < 1:
    result = 1

proc offerLoyalty*(traderId, offerId: string): int =
  ## The loyalty level an offer is gated behind. Zero means the assort does not
  ## say, which is not a gate.
  # `traderAssort` serves `allLoyaltyOne` when the switch is on, so the client
  # is shown every offer at loyalty 1. This function is the SERVER side of the
  # same gate and read the raw database, which meant the two disagreed: the shop
  # drew an ungated offer and `buyFromTrader` refused it with "that offer needs
  # loyalty level 2 and you are 1". Measured live today. The served assort is
  # the truth, so the gate follows it.
  if gUnlockAllOffers:
    return 0
  let v = dbRead("traders." & traderId & ".assort.loyal_level_items." & offerId)
  if not v.ok:
    return 0
  result = v.asInt(0)

# ---------------------------------------------------------------------------
# Fence, and the scav's karma
# ---------------------------------------------------------------------------
#
# Fence's standing is the scav's reputation, and the reference gives it exactly
# the same shape as every other trader's: `TraderInfo.standing`, gating
# `TraderLoyaltyLevel.MinStanding`.
#
# ## The rates that *are* the game's, and were not being read
#
# `bots.types.<role>.experience.standingForKill` is in the database for **all
# 57 bot roles**, keyed by difficulty, with BSG's own numbers:
#
#     assault   {"easy": -0.03, "normal": -0.04, "hard": -0.05}
#     bear      {"easy":  0.02, "normal":  0.02, "hard":  0.03}
#
# Twelve roles sit at -0.05, ten at -0.2, twenty-one at 0. `emu/bots` has read
# that exact path all along -- to hand the number to the *client*, as
# `Info.Settings.StandingForKill` on a generated bot. Nothing read it back.
#
# And there is no client fallback on the scav path to read it back for us.
# `emu/scav.newScavRecord` writes the played scav's own `StandingForKill` as
# 0.0 before the raid, and `endScavRaid` copies **only items** off the returned
# scav -- no `TradersInfo`, no `Stats`. So whatever standing the client computed
# during a scav raid is discarded by design, and until now nothing recomputed
# it: killing scavs as a scav was free and killing PMCs as a scav earned
# nothing.
#
# `scavKillKarma` below is the join. The key is `Stats.Eft.Victims[].Role` on
# the profile the client hands back -- the same list `emu/questcond.killCredit`
# already walks for quest kills.
#
# Two facts beside it, also in the database and also unused until now:
# `globals.config.FenceSettings.PmcBotKillStandingMultiplier` (1) and
# `globals.config.FenceSettings.FenceId`.
#
# ## The one number that is still invented, and why it stays
#
# Kills are the game's rate. **Extraction is not**: no figure for surviving a
# scav run exists anywhere in `build/db/db.json` or in
# `reference/spt-4.1-surface.json`. It is a server balance number, and it stays
# a setting:
#
#   fenceKarmaOnScavExtract   0.01   standing for walking out of a scav raid
#   fenceKarmaOnScavDeath     0.0    standing for dying in one
#
# What changed about it is the *claim*. The old comment here justified 0.01 as
# "a scale that makes the number mean something" -- it was the only input, so it
# alone had to make Fence's -7..+6 ladder reachable. That justification is now
# gone: the ladder's scale is set by BSG's own per-kill numbers, and 0.01 is a
# supplement to them rather than the whole system. It is kept at 0.01 rather
# than dropped to zero for the same reason the death penalty is zero --
# removing it takes something from the player and nothing can be pointed at to
# justify the removal -- but it is now the **only** invented figure in Fence's
# karma, it is worth a quarter of one `assault` kill, and
# `mods/tarkov/config.json` can set it to zero to leave the game's own numbers
# running on their own.

const
  FenceId* = "579dc571d53a0658a154fbec"
    ## Fence, as a compiled-in fallback. Preferred over it at run time is
    ## `globals.config.FenceSettings.FenceId`, which is the game's own statement
    ## of which trader is the scav trader -- the comment that used to stand here
    ## said no such flag existed, and it does, one level up from `TraderBase`.
    ## The constant stays because a database with no `globals.config` must still
    ## have karma, and because the two agree on every dump seen so far.

  KillDifficulty = "normal"
    ## Which column of `standingForKill` a victim is priced at.
    ##
    ## The raid report carries no per-victim difficulty and nothing else does
    ## either: `RaidSettings.BotSettings` in the reference dump is
    ## `{IsScavWars, BotAmount}` and `/client/match/local/start` answers
    ## `aiDifficulty: "AsOnline"`. So this is a default, and it is the honest
    ## one -- it is the column every one of the 57 roles carries, where `easy`
    ## and `hard` are present on only nine. A role that lacks it is refused by
    ## name rather than priced off a column nobody asked for.

proc fenceId*(): string =
  ## The scav trader. `globals.config.FenceSettings.FenceId` when the database
  ## has it, the constant when it does not.
  let v = dbRead("globals.config.FenceSettings.FenceId")
  if v.ok:
    let id = asText(v)
    if id.len == 24:
      return id
  result = FenceId

proc plainRoleKey(role: string): bool =
  ## Whether a victim's `Role` is safe to build a database path out of.
  ##
  ## `Role` is a `String` the client chooses, and it is about to become the
  ## middle of a dotted `dbRead` path. A role carrying a `.` would read a
  ## different table than the one it names.
  if role.len == 0 or role.len > 48:
    return false
  for ch in role:
    let okChar = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
                 (ch >= '0' and ch <= '9') or ch == '_'
    if not okChar:
      return false
  result = true

proc standingForKill*(role, difficulty: string; known: var bool): float =
  ## `bots.types.<role>.experience.standingForKill.<difficulty>`.
  ##
  ## The role is lower-cased before the lookup: the database keys these
  ## `pmcbear`, `bosskilla`, `followerbigpipe`, and the client's
  ## `WildSpawnType` spells the same values `pmcBEAR`, `bossKilla`,
  ## `followerBigPipe`. `known` is false for a role the table does not have and
  ## for a role that has no entry at this difficulty -- both are refusals to
  ## price, and neither is a zero.
  known = false
  result = 0.0
  if not plainRoleKey(role):
    return
  let t = dbRead("bots.types." & toLowerAscii(role) &
                 ".experience.standingForKill")
  if not t.ok or t.raw.len == 0:
    return
  let v = field(t.raw, toLowerAscii(difficulty))
  if not v.found or v.isNull:
    return
  known = true
  result = v.asFloat(0.0)

proc noteOnce(into: var seq[string]; what: string) =
  for r in into:
    if r == what:
      return
  into.add what

proc scavKillKarma*(playedScav: string; problems: var seq[string];
                    counted: var int): float =
  ## What one scav raid's kills are worth in Fence standing.
  ##
  ## Reads `Stats.Eft.Victims` off the profile the client hands back and prices
  ## every victim at the game's own `standingForKill` for its role. A victim
  ## whose role the database does not price is **skipped and named**, not
  ## guessed at and not silently dropped.
  ##
  ## PMC victims -- the ones the report's own `Side` calls `Bear` or `Usec` --
  ## are scaled by `FenceSettings.PmcBotKillStandingMultiplier`. That is 1 on
  ## every dump seen, so today it changes nothing; it is read rather than
  ## assumed because a mod that changes it means it. The join is on `Side`
  ## rather than on a list of PMC role names because `Side` is what the report
  ## states outright, where "is `pmcBEAR` a PMC" is an inference. *(That
  ## `WildSpawnTypeExtensions.IsPmc` exists in the reference dump is a fact; its
  ## body is not in the dump, so the mapping it makes is not.)*
  result = 0.0
  counted = 0
  let victims = field(playedScav, "Stats.Eft.Victims")
  if not victims.found:
    return
  var pmcMultiplier = 1.0
  let m = dbRead("globals.config.FenceSettings.PmcBotKillStandingMultiplier")
  if m.ok:
    pmcMultiplier = m.asFloat(1.0)
  let list = each(victims)
  for v in list:
    let role = v.field("Role").asText("")
    if role.len == 0:
      noteOnce(problems, "a kill with no role on it earned no standing")
      continue
    var known = false
    let rate = standingForKill(role, KillDifficulty, known)
    if not known:
      noteOnce(problems, "this database prices no kill of a " & role &
                         " at difficulty " & KillDifficulty &
                         "; that kill moved no standing")
      continue
    var delta = rate
    let side = v.field("Side").asText("")
    if side == "Bear" or side == "Usec":
      delta = delta * pmcMultiplier
    result = result + delta
    inc counted

proc applyScavKarma*(p: var Profile; survived: bool;
                     onExtract, onDeath: float; playedScav: string;
                     problems: var seq[string]; killed: var int): bool =
  ## Moves Fence's standing for one finished scav raid. Returns whether it
  ## changed anything, so a caller with nothing else to write does not save.
  ##
  ## Two inputs, added and written once: the configured survival figure, and
  ## the game's own per-kill rate summed over the raid's victim list. Written
  ## once rather than per kill because `addStanding` snaps to a 1/1,000,000
  ## grid on every write, and a raid with twelve victims in it should round
  ## once.
  ##
  ## Refused outright when the database has no Fence: writing standing into a
  ## `TradersInfo` entry for a trader that does not exist leaves a row the
  ## trader screen cannot draw and the player cannot spend.
  killed = 0
  let fence = fenceId()
  if traderBase(fence).len == 0:
    return false
  var delta = if survived: onExtract else: onDeath
  delta = delta + scavKillKarma(playedScav, problems, killed)
  if delta == 0.0:
    return false
  addStanding(p, fence, delta)
  result = true
