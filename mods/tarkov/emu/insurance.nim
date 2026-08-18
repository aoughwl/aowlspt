## Insurance.
##
## Before a raid you pay a trader to insure some gear; if you die and nobody
## takes it, it comes back in the post a day later. The two halves are far apart
## in time, which is the only interesting thing about implementing it: the
## premium is taken now and the return has to survive a server restart, so the
## pending returns live in the store rather than in memory.
##
## What comes back is what the player did **not** bring home. The client hands
## back the profile it played the raid with, so the check is: of the items that
## were insured, which are no longer in the profile? Those are the ones lost,
## and those are the ones the trader posts back — the rest are already in the
## stash and returning them would duplicate them.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import mail

const
  KeyPrefix* = "insurance."
  DefaultPremiumPercent* = 10

proc insuranceKey*(profileId: string): string = KeyPrefix & profileId

proc pending*(profileId: string): List =
  let stored = load(insuranceKey(profileId))
  if not stored.ok or stored.raw.len == 0:
    return newList()
  result = parseArray(stored.raw)
  if not result.ok:
    result = newList()

proc savePending*(profileId: string; list: List): bool =
  result = save(insuranceKey(profileId), text(list)) == Ok

proc premiumFor*(handbookPrice, percent: int): int =
  ## What the trader charges. Never zero for an item with a price: a free
  ## premium makes insurance strictly better than not insuring, which is a
  ## decision the player should be making.
  if handbookPrice <= 0:
    return 0
  result = (handbookPrice * percent) div 100
  if result < 1:
    result = 1

proc insuredIds*(profileJson: string): seq[string] =
  ## The ids in the profile's `InsuredItems`.
  result = @[]
  let list = each(field(profileJson, "InsuredItems"))
  for entry in list:
    let id = entry.field("itemId").asText("")
    if id.len > 0:
      result.add id

proc lostAfterRaid*(beforeJson, afterJson: string): seq[string] =
  ## Which insured items are gone. Compared by id against the item list the
  ## client handed back, because "gone" is the only thing that makes an item
  ## eligible -- an insured rifle that came home is already in the stash.
  result = @[]
  let insured = insuredIds(beforeJson)
  if insured.len == 0:
    return
  let after = each(field(afterJson, "Inventory.items"))
  for id in insured:
    var stillThere = false
    for it in after:
      if it.field("_id").asText("") == id:
        stillThere = true
    if not stillThere:
      result.add id

proc itemsById*(profileJson: string; ids: seq[string]): string =
  ## The full item objects for a set of ids, out of the pre-raid profile -- the
  ## post-raid one no longer has them, which is the point.
  var out1 = newList()
  let items = each(field(profileJson, "Inventory.items"))
  for it in items:
    let id = it.field("_id").asText("")
    for wanted in ids:
      if wanted == id:
        out1.add raw(it)
  result = text(out1)

proc queueReturn*(profileId, traderId, itemsJson: string;
                  dueSeconds: int): bool =
  ## Records what a trader owes back, and when.
  if itemsJson.len == 0 or itemsJson == "[]":
    return true
  var list = pending(profileId)
  var d = newDoc()
  setText(d, "traderId", traderId)
  setNumber(d, "dueAt", dueSeconds)
  setRaw(d, "items", itemsJson)
  list.add d
  result = savePending(profileId, list)

proc deliverDue*(profileId: string; nowSeconds: int): int =
  ## Posts everything whose time has come, and returns how many returns went
  ## out. Called on a timer *and* at login: a server that was off when a return
  ## came due must still deliver it, and only checking on a timer means it never
  ## does.
  result = 0
  let list = pending(profileId)
  if list.len == 0:
    return
  var keep = newList()
  for i in 0 ..< list.len:
    let entry = whole(list.items[i])
    if entry.field("dueAt").asInt(0) > nowSeconds:
      keep.add list.items[i]
      continue
    let trader = entry.field("traderId").asText("")
    if deliver(profileId, trader, "Your insured gear was recovered.",
               mkInsuranceReturn, nowSeconds, raw(entry.field("items"))):
      inc result
    else:
      # Undeliverable stays queued rather than being dropped. A player whose
      # gear vanished because a write failed has no way to tell.
      keep.add list.items[i]
  discard savePending(profileId, keep)
