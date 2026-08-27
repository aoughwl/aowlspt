## Fence's stock, generated.
##
## SPT's `assort.json` for Fence is **68 bytes** -- the three empty collections
## and nothing else -- because SPT does not ship Fence's stock, it GENERATES it
## at runtime from the item table on every resupply. Serving that file verbatim,
## which is what this server did, gives a beta tester a Fence who is reachable,
## greetable and permanently empty. That is not a database gap to be filled in;
## it is a generator that was never written.
##
## What Fence is, and therefore what this generates: a fence buys what other
## people looted and resells it used, at a markup, in small quantities, with no
## loyalty gate. So -- ordinary handbook-priced items, `StackObjectsCount` in
## the low single digits, priced at the handbook price plus a markup, every
## offer at loyalty level 1.
##
## **Deterministic, not random.** The stock is a pure function of a seed, and
## the seed is the resupply timestamp bucketed to the refresh interval. Two
## requests inside one resupply window get the identical list -- a shop whose
## contents change between the moment the player opens it and the moment they
## click buy is a purchase that fails with no reason the player can see.
##
## The handbook is walked with the same every-nth stride `emu/market`'s
## `offersFromHandbook` uses, and for the same measured reason: the handbook is
## written in category order, so taking a prefix gives a Fence who sells
## nothing but ammunition.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import ids

const FenceId* = "579dc571d53a0658a154fbec"

const FenceOfferCount* = 90
  ## How many offers Fence carries. SPT's own default is in the same range.
  ## Bounded deliberately: the assort is serialised on every trader screen
  ## open, and an unbounded one is a multi-megabyte body for a scrap dealer.

const FenceMarkupPercent* = 120
  ## Fence sells above the handbook. He is the one trader with no loyalty gate,
  ## so price is the only thing making him a worse option than Prapor.

const
  Roubles* = "5449016a4bdc2d6f028b456f"
  Dollars* = "5696686a4bdc2da3298b456a"
  Euros*   = "569668774bdc2da2298b4568"
    ## Spelled out here rather than imported from `emu/trading`.
    ## NOT a style choice: `emu/traders` imports this module, and `emu/trading`
    ## imports `emu/traders`, so `import trading` here is an import CYCLE and
    ## the build says so (`cycle detected: trading.nim <-> traders.nim`).
    ## These three ids are the most stable constants in the database.

proc isCurrency(tpl: string): bool =
  tpl == Roubles or tpl == Dollars or tpl == Euros

proc mix(x: int): int =
  ## A small deterministic scrambler. Not cryptographic and not trying to be --
  ## it exists so that consecutive handbook indices do not give consecutive
  ## stack sizes, which reads as a shop stocked by a machine.
  var v = x * 2654435761
  v = v xor (v shr 13)
  v = v * 1274126177
  result = abs(v xor (v shr 16))

proc fenceAssort*(resupplyAt: int; refreshSeconds: int): string =
  ## The generated assort, in the exact shape `traderAssort` returns.
  ##
  ## Returns the three empty collections -- never a bare `{}` -- when the
  ## handbook cannot supply anything, because the client indexes `items`
  ## before it checks it.
  var items = arr()
  var barter = obj()
  var loyal = obj()

  let hb = dbRead("templates.handbook.Items")
  var taken = 0
  if hb.ok and hb.raw.len > 0:
    let entries = each(whole(hb.raw))

    # Pass one: how many entries are priced and are not currency. The stride
    # below and this count have to agree or the walk runs off the end of the
    # table and Fence ends up with a prefix again.
    var eligible = 0
    for e in entries:
      let tpl = e.field("Id").asText("")
      let price = e.field("Price").asInt(0)
      if tpl.len > 0 and price > 0 and not isCurrency(tpl):
        inc eligible

    if eligible > 0:
      let want = min(FenceOfferCount, eligible)
      let stride = max(1, eligible div want)
      # The seed changes once per resupply window and not once per request.
      let bucket = if refreshSeconds > 0: resupplyAt div refreshSeconds
                   else: resupplyAt
      let skew = mix(bucket) mod stride

      var seen = 0
      for e in entries:
        let tpl = e.field("Id").asText("")
        let price = e.field("Price").asInt(0)
        if tpl.len == 0 or price <= 0 or isCurrency(tpl):
          continue
        let index = seen
        inc seen
        if taken >= want:
          break
        if (index + skew) mod stride != 0:
          continue

        let offerId = newId()
        let noise = mix(bucket + index)

        var it = obj()
        put(it, "_id", offerId)
        put(it, "_tpl", tpl)
        put(it, "parentId", "hideout")
        put(it, "slotId", "hideout")
        var upd = obj()
        # 1..3. A fence deals in what one person carried out of one raid.
        put(upd, "StackObjectsCount", 1 + (noise mod 3))
        put(it, "upd", raw(done(upd).text))
        items.add raw(done(it).text)

        # Handbook price plus the markup, wobbled by up to a tenth so the
        # column is not a straight multiple of the handbook the player can
        # read off. Never below 1: a free item is a duplication bug.
        var cost = (price * FenceMarkupPercent) div 100
        cost = cost + ((cost div 10) * (noise mod 3)) div 2
        if cost < 1:
          cost = 1

        var req = obj()
        put(req, "count", cost)
        put(req, "_tpl", Roubles)
        # The same discriminator `stampRequirementTypes` puts on a stored
        # scheme. Written here directly rather than round-tripping this
        # through that proc, which would reparse the whole document.
        put(req, "type", "ItemRequirement")
        var inner = arr()
        inner.add raw(done(req).text)
        var outer = arr()
        outer.add raw(done(inner).text)
        put(barter, offerId, raw(done(outer).text))

        # No loyalty gate. Fence is the trader every profile can already buy
        # from; gating him would make the generated shop as unreachable as
        # the empty one it replaces.
        put(loyal, offerId, 1)
        inc taken

  var o = obj()
  put(o, "nextResupply", resupplyAt)
  put(o, "items", raw(done(items).text))
  put(o, "barter_scheme", raw(done(barter).text))
  put(o, "loyal_level_items", raw(done(loyal).text))
  result = done(o).text
