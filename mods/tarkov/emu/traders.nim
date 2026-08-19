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

proc traderSettings*(): string =
  ## The array the client's trader screen is built from.
  var a = arr()
  let ids = traderIds()
  for id in ids:
    let base = traderBase(id)
    if base.len > 0:
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

proc traderAssort*(id: string; resupplyAt: int): string =
  let v = dbRead("traders." & id & ".assort")
  if not v.ok or v.raw.len == 0:
    return emptyAssort()
  # `nextResupply` is a timestamp the client counts down to. Taken from the
  # database when it is there and stamped here when it is not, because a
  # missing one shows as a stock timer that has already expired.
  let existing = field(v.raw, "nextResupply")
  if existing.found:
    return v.raw
  var o = obj()
  put(o, "nextResupply", resupplyAt)
  put(o, "items", raw(field(v.raw, "items").raw()))
  put(o, "barter_scheme", raw(field(v.raw, "barter_scheme").raw()))
  put(o, "loyal_level_items", raw(field(v.raw, "loyal_level_items").raw()))
  result = done(o).text

proc traderExists*(id: string): bool =
  result = traderBase(id).len > 0

proc newTradersInfo*(): string =
  ## What a fresh profile knows about each trader: nothing bought, nothing
  ## unlocked, standing at zero. Built from whatever traders the database has,
  ## so a profile created on a server with no traders does not carry entries for
  ## traders that do not exist.
  var o = obj()
  let ids = traderIds()
  for id in ids:
    var t = obj()
    put(t, "loyaltyLevel", 1)
    put(t, "salesSum", 0)
    put(t, "standing", 0.0)
    put(t, "nextResupply", 0)
    put(t, "unlocked", true)
    put(t, "disabled", false)
    put(o, id, t)
  result = done(o).text

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
# `TraderLoyaltyLevel.MinStanding`. What it does **not** give, anywhere, is the
# rate -- how much standing one scav run is worth, or what dying in one costs.
# That is a balance number and it lives in the real server's own config file,
# which is not part of the database dump this reads.
#
# So the rate is a setting, with a default this file is allowed to have an
# opinion about and not allowed to present as fact:
#
#   fenceKarmaOnScavExtract   0.01   standing for walking out of a scav raid
#   fenceKarmaOnScavDeath     0.0    standing for dying in one
#
# 0.01 is chosen so that a hundred successful scav runs move the standing by
# 1.0, which is the granularity Fence's loyalty levels are written at in the
# live trader base -- it is a scale that makes the number mean something, not a
# figure recovered from the game. Zero for a death because the reference gives
# no penalty and inventing one takes something from the player that nothing can
# be pointed at to justify. Both are in `mods/tarkov/config.json` and either can
# be set to zero to turn the system off entirely.

const FenceId* = "579dc571d53a0658a154fbec"
  ## Fence. Hard-coded because it is an id in the game's own data rather than a
  ## thing this server can look up: there is no "is this the scav trader" flag
  ## on `TraderBase`. A database without this trader in it simply has no karma,
  ## because `addStanding` writes an entry and `loyaltyLevelFor` finds no base
  ## to derive a level from -- which is the same state as before.

proc applyScavKarma*(p: var Profile; survived: bool;
                     onExtract, onDeath: float): bool =
  ## Moves Fence's standing for one finished scav raid. Returns whether it
  ## changed anything, so a caller with nothing else to write does not save.
  ##
  ## Refused outright when the database has no Fence: writing standing into a
  ## `TradersInfo` entry for a trader that does not exist leaves a row the
  ## trader screen cannot draw and the player cannot spend.
  if traderBase(FenceId).len == 0:
    return false
  let delta = if survived: onExtract else: onDeath
  if delta == 0.0:
    return false
  addStanding(p, FenceId, delta)
  result = true
