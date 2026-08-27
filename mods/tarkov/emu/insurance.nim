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
##
## ## The life of an insured id
##
## `InsuredItems` is a list of `{tid, itemId}` on the profile, and the whole of
## what this server knows about who is covered. An id gets **in** exactly once,
## from `emu/personal.doInsure`, which refuses to write a second entry for an
## item already in the list -- so "insured twice" is one entry and one premium.
##
## Getting **out** has four moments in the real game, and this emulator can
## reach one of them honestly:
##
## - **Queued for return.** The item was lost, the trader now owes it back, and
##   the cover is spent. This is the removal, and `withoutInsured` is it. It
##   was missing entirely until it was noticed that one raid could pay out the
##   same three kits that the previous raid had already paid out.
## - **Returned to the stash.** Too late to be the removal, and by a whole day:
##   see `withoutInsured` for why anything that waits for the post sees the
##   loss twice. Nothing extra is needed here -- the id left the cover when the
##   return was queued, and an item recovered from the post is uninsured until
##   the player pays for it again, which is the game's rule too.
## - **Sold, or otherwise gone from the stash without a raid.** Not modelled:
##   `emu/trading.sellToTrader` and the flea take the item and leave the entry
##   behind, so a sold rifle still reads as covered. The end of the next raid
##   is where that shows, and it is handled there rather than at the sale --
##   an entry whose item the pre-raid profile does not hold cannot be posted
##   back by anybody, so it is discharged with no message rather than left to
##   ask the same unanswerable question every raid.
## - **Expired in the post.** Not modelled, and cannot be: `emu/mail.prune`
##   never drops a message that still holds items. See `KeyFound` below.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import store
import mail
import dialogue

const
  KeyPrefix* = "insurance."
  DefaultPremiumPercent* = 10

  DefaultTrader* = "54cb50c76803fa8b248b4571"
    ## Prapor. Only ever used for an insured item whose profile entry does not
    ## name who insured it -- `InsuredItems` carries a `tid` and `emu/personal`
    ## writes it, so this is for entries written before it did. It is the id
    ## this module posted *everything* under until the queue learned to keep
    ## the trader, and keeping it as the fallback means those returns arrive
    ## from the same trader they would have.

  KeyStart* = "insuranceStart"
  KeyFound* = "insuranceFound"
    ## The two situations this emulator can actually tell apart, out of the
    ## seven `traders.<id>.dialogue` carries. `insuranceStart` is the moment a
    ## return is queued and `insuranceFound` is the moment it is posted.
    ##
    ## The other five are **not** used, and each for a reason rather than for
    ## want of trying:
    ##
    ## - `insuranceFailed`, `insuranceFailedLabs` and `insuranceFailedLabyrinth`
    ##   are "somebody got to your stuff before we did". This server returns
    ##   everything that was lost, every time -- there is no roll for another
    ##   player having taken it, so there is no failure to report. Saying one
    ##   happened would be inventing an outcome the emulator does not have.
    ## - `insuranceExpired` is the storage time running out. `emu/mail` sets
    ##   `maxStorageTime` on a message that carries items and nothing enforces
    ##   it: `prune` never drops a message still holding something, at any age.
    ##   So no return ever expires here and there is nothing to say.
    ## - `insuranceComplete` closes the case once the player has taken
    ##   everything. `emu/mail.removeAttachments` does know the moment the last
    ##   item leaves an insurance message -- so this one is distinguishable --
    ##   but whether the real server sends it then, or on some other event, is
    ##   not something the dump answers, and a message the game does not send is
    ##   as wrong as a wrong message.

  DefaultReturnText* = "Your insured gear was recovered."
    ## What this module said for every trader and every outcome before it read
    ## `dialogue`, and what it still says whenever the trader has no line, the
    ## locale does not resolve, or a placeholder cannot be filled. Plain, but a
    ## player can read it -- which an empty message and a message reading "lost
    ## somewhere on {location}" both are not.

proc insuranceKey*(profileId: string): string = KeyPrefix & profileId

proc pending*(profileId: string; usable: var bool): List =
  ## The queue, and whether it could be read at all. See `emu/store`: an
  ## unreadable queue answered as an empty one is a queue the next `queueReturn`
  ## overwrites, and everything already owed to the player goes with it.
  let raw1 = readKey(insuranceKey(profileId), usable)
  if raw1.len == 0:
    return newList()
  result = parseArray(raw1)
  if not result.ok:
    result = newList()

proc pending*(profileId: string): List =
  ## For the read-only callers.
  var usable = true
  result = pending(profileId, usable)

proc savePending*(profileId: string; list: List): bool =
  result = save(insuranceKey(profileId), text(list)) == Ok

proc premiumFor*(handbookPrice, percent: int): int =
  ## What the trader charges. Never zero for an item with a price: a free
  ## premium makes insurance strictly better than not insuring, which is a
  ## decision the player should be making.
  ##
  ## A percent of exactly 0 IS free, and is the one way to get there: it is the
  ## "insurance costs nothing" setting, asked for by name. The floor below
  ## applies to every other percent, so a cheap item is never rounded to free
  ## by accident -- which is the case this floor was written for.
  if handbookPrice <= 0:
    return 0
  if percent <= 0:
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

proc traderOf*(profileJson, itemId: string): string =
  ## Who insured one item, out of the profile's own `InsuredItems`. Falls back
  ## to `DefaultTrader` for an entry with no `tid`, because a return that comes
  ## from nobody cannot be posted at all.
  let list = each(field(profileJson, "InsuredItems"))
  for entry in list:
    if entry.field("itemId").asText("") == itemId:
      let tid = entry.field("tid").asText("")
      if tid.len > 0:
        return tid
      return DefaultTrader
  result = DefaultTrader

proc insuringTraders*(profileJson: string; ids: seq[string]): seq[string] =
  ## The distinct traders that insured a set of items, in first-seen order.
  ##
  ## The queue used to post every return from Prapor whatever the profile said,
  ## and the profile has always said: `emu/personal.doInsure` writes the `tid`
  ## the client sent. That mattered little while the message was one hardcoded
  ## sentence and matters entirely now that the trader's own words are used --
  ## the Therapist saying "my dogs" is a worse bug than Prapor saying nothing
  ## in particular.
  result = @[]
  for id in ids:
    let tid = traderOf(profileJson, id)
    var known = false
    for t in result:
      if t == tid:
        known = true
    if not known:
      result.add tid

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

proc idsForTrader*(profileJson: string; ids: seq[string];
                   trader: string): seq[string] =
  ## The subset of `ids` that `trader` insured.
  result = @[]
  for id in ids:
    if traderOf(profileJson, id) == trader:
      result.add id

proc withoutInsured*(insuredJson: string; ids: seq[string]): string =
  ## `InsuredItems` with every entry naming one of `ids` taken out.
  ##
  ## This is the half of the lifecycle that was missing. An id went **into**
  ## `InsuredItems` when the player paid for cover and nothing ever took one
  ## out, so an item lost in one raid was still "insured and not in the
  ## profile" at the end of the next one -- which is exactly what
  ## `lostAfterRaid` asks -- and was queued for return again, and again, once
  ## per raid until it was collected from the post.
  ##
  ## The removal belongs at **queueing**, not at delivery and not at
  ## collection, for a reason the two later moments cannot meet: between the
  ## raid that lost the item and the day the return arrives, the player raids
  ## again. At that point the item is not in the profile and is not yet in the
  ## post either, so any rule that waits for it to arrive sees the same "lost"
  ## item a second time. Delivery is a day too late and collection later still
  ## -- `emu/mail.prune` never drops a message that still holds items, so a
  ## return the player leaves in the inbox is a duplicate machine that keeps
  ## running for the life of the profile.
  ##
  ## Queueing is also the moment the obligation actually moves: from then on
  ## the trader owes the item back, and the cover the player paid for has been
  ## spent. What comes home comes home uninsured, which is the game's own rule
  ## -- an item recovered from the post has to be insured again before the
  ## next raid.
  ##
  ## An unreadable or absent list answers as an empty one. There is nothing in
  ## it that can be kept and nothing that can be lost.
  let list = parseArray(insuredJson)
  if not list.ok:
    return "[]"
  var out1 = newList()
  for i in 0 ..< list.len:
    let id = field(list.items[i], "itemId").asText("")
    var drop = false
    for d in ids:
      if d.len > 0 and d == id:
        drop = true
    if not drop:
      out1.add list.items[i]
  result = text(out1)

proc queueReturn*(profileId, traderId, itemsJson: string;
                  dueSeconds: int; location: string = "";
                  lostAt: int = 0): bool =
  ## Records what a trader owes back, and when.
  ##
  ## `location` and `lostAt` are what the trader's own line needs to read as
  ## anything but a form letter -- "lost somewhere on Customs", "insured on
  ## 18.08.2025 at 15:05". They are recorded here rather than worked out at
  ## delivery because by then the raid is a day gone: `deliverDue` runs on a
  ## timer with nobody logged in and has no way back to it.
  ##
  ## Both are optional, and an entry without them is the case that made them
  ## optional: a queue written by an older build of this server, still sitting
  ## in a player's store. Those deliver with whichever line needs neither, and
  ## fall back to `DefaultReturnText` when the trader has none.
  if itemsJson.len == 0 or itemsJson == "[]":
    return true
  var usable = true
  var list = pending(profileId, usable)
  if not usable:
    # The queue exists and could not be read. Appending to an empty list here
    # would write one entry over everything the player is already owed.
    return false
  var d = newDoc()
  setText(d, "traderId", traderId)
  setNumber(d, "dueAt", dueSeconds)
  if location.len > 0:
    setText(d, "location", location)
  if lostAt > 0:
    setNumber(d, "lostAt", lostAt)
  setRaw(d, "items", itemsJson)
  list.add d
  result = savePending(profileId, list)

proc messageSeed(profileId, traderId, key: string; atSeconds: int): string =
  ## What the choice of line is a function of, and nothing else.
  ##
  ## Every part of it is in the store: the profile, the trader and the second
  ## the raid ended are the queue entry, and the situation is a constant. So a
  ## delivery whose save fails and is retried an hour later composes the same
  ## sentence, and a test that knows the raid's timestamp knows the line. See
  ## `emu/ids` for why "just use a random number" is not available here.
  result = profileId & "." & traderId & "." & key & "." & $atSeconds

proc traderLine*(profileId, traderId, key, location: string;
                 atSeconds: int): string =
  ## The trader's own words for a situation, or `DefaultReturnText`.
  ##
  ## Resolved here, at the moment the message is composed, and against the
  ## language the client last asked for -- not at load and not into English.
  ## The message is stored as text, so a line resolved in the wrong language is
  ## wrong in the player's inbox for as long as the message lives.
  let lang = languageOf(profileId)
  let spoken = say(traderId, key, lang,
                   messageSeed(profileId, traderId, key, atSeconds),
                   location, atSeconds)
  if spoken.ok:
    return spoken.text
  # Only worth a line in the log when the trader *has* something to say and it
  # could not be used -- a missing locale entry, or a placeholder this server
  # had no value for. A trader with no list for the situation is the ordinary
  # case on a database without `dialogue`, and warning about it every delivery
  # would be noise around a fallback that is working as designed.
  if dialogueLines(traderId, key).len > 0:
    warn "trader " & traderId & " has " & key & " lines and none of them " &
         "could be used in " & lang &
         " -- either the locale has no text for them or this server had no " &
         "value for a placeholder they carry; using the plain wording"
  result = DefaultReturnText

proc announceStart*(profileId, traderId, location: string;
                    nowSeconds: int): bool =
  ## "Okay, I sent my guys to go retrieve your stuff."
  ##
  ## Sent when a return is queued, which is the one moment this emulator can
  ## match to `insuranceStart`. Unlike the return message it has **no** plain
  ## fallback: there is nothing this server used to say here, so a trader with
  ## no `insuranceStart` line says nothing at all rather than something made up.
  ## `false` means "nothing was sent", which includes that case and is not an
  ## error the caller should report.
  ##
  ## `mkNpcTrader` rather than `mkInsuranceReturn`: it carries no items, and it
  ## is an ordinary line of trader chat in the dialog the return will arrive in.
  let lang = languageOf(profileId)
  let spoken = say(traderId, KeyStart, lang,
                   messageSeed(profileId, traderId, KeyStart, nowSeconds),
                   location, nowSeconds)
  if not spoken.ok:
    return false
  result = deliver(profileId, traderId, spoken.text, mkNpcTrader, nowSeconds)

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
    # What the trader says, in the player's language, about the raid this entry
    # came out of. `lostAt` is the second the raid ended -- what `{date}` and
    # `{time}` mean in the line, which is when the gear was lost and not when
    # it is being handed back.
    let text1 = traderLine(profileId, trader, KeyFound,
                           entry.field("location").asText(""),
                           entry.field("lostAt").asInt(0))
    if deliver(profileId, trader, text1,
               mkInsuranceReturn, nowSeconds, raw(entry.field("items"))):
      inc result
    else:
      # Undeliverable stays queued rather than being dropped. A player whose
      # gear vanished because a write failed has no way to tell.
      keep.add list.items[i]
  discard savePending(profileId, keep)

# ---------------------------------------------------------------------------
# The load-time check
# ---------------------------------------------------------------------------

const
  ScProfile = """{"_id":"pid","InsuredItems":[
    {"tid":"prapor","itemId":"kit1"},
    {"tid":"thera","itemId":"kit2"},
    {"itemId":"kit3"},
    {"tid":"prapor","itemId":"gone"}],
    "Inventory":{"items":[
    {"_id":"kit1","_tpl":"t1","parentId":"stash"},
    {"_id":"kit2","_tpl":"t2","parentId":"stash"},
    {"_id":"kit3","_tpl":"t3","parentId":"stash"},
    {"_id":"stash","_tpl":"ts"}]}}"""
    ## One profile, four kinds of insured entry: two named traders, one entry
    ## with no `tid` at all (written before `emu/personal` recorded one) and
    ## one whose item is not in the inventory any more -- sold, or eaten. The
    ## last is not a hypothetical: nothing else in this emulator takes an id
    ## out of `InsuredItems`, so a sold rifle leaves its cover behind.

  ScAfterLost = """{"_id":"pid","Inventory":{"items":[
    {"_id":"kit3","_tpl":"t3","parentId":"stash"},
    {"_id":"stash","_tpl":"ts"}]}}"""
    ## What the client hands back from a raid that lost `kit1` and `kit2` and
    ## brought `kit3` home.

  ScAfterAll = """{"_id":"pid","Inventory":{"items":[
    {"_id":"stash","_tpl":"ts"}]}}"""
    ## And from one that lost everything.

proc listed(ids: seq[string]): string =
  ## `join` over a `seq[string]` is not available in this toolchain.
  result = ""
  for id in ids:
    if result.len > 0:
      result.add ", "
    result.add id

proc has(ids: seq[string]; wanted: string): bool =
  for id in ids:
    if id == wanted:
      return true
  result = false

proc selfCheckInsurance*(into: var seq[string]): bool =
  ## Pure, over the literals above: who insured what, what a raid lost, and --
  ## the one this exists for -- that a loss cannot be queued twice.
  ##
  ## None of it is reachable from `emutest` with any precision. `emutest` can
  ## see that a return arrived; it cannot see that the *second* raid of a day
  ## queued nothing, because that is the absence of a message and the absence
  ## of a message is what the bug looked like from outside for as long as it
  ## lived. So the closed loop is written out here as arithmetic.
  let before = into.len

  # The premium. Never free for an item with a price, never charged for one
  # without.
  if premiumFor(0, 10) != 0:
    into.add "insurance: a priceless item was quoted " & $premiumFor(0, 10)
  if premiumFor(100000, 10) != 10000:
    into.add "insurance: 10% of 100000 quoted as " & $premiumFor(100000, 10)
  if premiumFor(5, 10) != 1:
    into.add "insurance: a cheap item was quoted " & $premiumFor(5, 10) &
             ", and a free premium makes insuring strictly better than not"

  # Who is covered, and by whom.
  let insured = insuredIds(ScProfile)
  if insured.len != 4:
    into.add "insurance: " & $insured.len & " insured ids out of a profile " &
             "with four"
  if traderOf(ScProfile, "kit2") != "thera":
    into.add "insurance: kit2 was insured by " & traderOf(ScProfile, "kit2")
  if traderOf(ScProfile, "kit3") != DefaultTrader:
    into.add "insurance: an entry with no tid fell back to " &
             traderOf(ScProfile, "kit3")
  if traderOf(ScProfile, "nosuch") != DefaultTrader:
    into.add "insurance: an unknown item answered " &
             traderOf(ScProfile, "nosuch")

  # What one raid lost, and the split into one queue entry per trader.
  let lost1 = lostAfterRaid(ScProfile, ScAfterLost)
  if lost1.len != 3 or not has(lost1, "kit1") or not has(lost1, "kit2") or
     not has(lost1, "gone"):
    into.add "insurance: a raid that kept kit3 lost " & $lost1.len &
             " insured item(s)"
  let traders1 = insuringTraders(ScProfile, lost1)
  if traders1.len != 2 or traders1[0] != "prapor" or traders1[1] != "thera":
    into.add "insurance: " & $traders1.len & " insuring trader(s), in the " &
             "order " & listed(traders1)
  let prapors = idsForTrader(ScProfile, lost1, "prapor")
  if prapors.len != 2 or not has(prapors, "kit1") or not has(prapors, "gone"):
    into.add "insurance: prapor's share of the loss was " & $prapors.len &
             " item(s)"
  # `gone` is insured and has no item behind it, so the post gets one object
  # for `kit1` and nothing for it. A trader cannot return what the profile
  # does not hold.
  let goods = itemsById(ScProfile, prapors)
  if goods.len == 0 or goods == "[]" or goods.contains("\"gone\""):
    into.add "insurance: prapor's return carried " & goods

  # The loop this module got wrong. Queue the loss, take the ids out of the
  # cover, and ask the same question again: a profile that has already been
  # paid out for a raid must lose nothing further in the next one.
  let after1 = withoutInsured(field(ScProfile, "InsuredItems").raw(), lost1)
  let settled = """{"_id":"pid","InsuredItems":""" & after1 &
                ""","Inventory":{"items":[
    {"_id":"kit3","_tpl":"t3","parentId":"stash"},
    {"_id":"stash","_tpl":"ts"}]}}"""
  let stillCovered = insuredIds(settled)
  if stillCovered.len != 1 or stillCovered[0] != "kit3":
    into.add "insurance: after a payout the cover names " &
             listed(stillCovered) & " -- an id left behind here is queued " &
             "for return again at the end of every later raid"
  let lost2 = lostAfterRaid(settled, ScAfterLost)
  if lost2.len != 0:
    into.add "insurance: the raid after a payout lost " & $lost2.len &
             " already-returned item(s) a second time"

  # And the neighbour that a careless fix breaks: kit3 was still covered, so
  # the raid that finally loses it must still pay out -- once.
  let lost3 = lostAfterRaid(settled, ScAfterAll)
  if lost3.len != 1 or lost3[0] != "kit3":
    into.add "insurance: the item that came home and was lost later paid " &
             "out " & $lost3.len & " time(s)"
  let after3 = withoutInsured(after1, lost3)
  if insuredIds("""{"InsuredItems":""" & after3 & "}").len != 0:
    into.add "insurance: a fully paid-out profile still carries cover"
  if lostAfterRaid("""{"InsuredItems":""" & after3 &
                   ""","Inventory":{"items":[]}}""", ScAfterAll).len != 0:
    into.add "insurance: an empty cover still found something to return"

  # Removal is by id and by id only: an unnamed entry stays, and a list that
  # cannot be read is not mistaken for a list with things in it.
  let nothing: seq[string] = @[]
  if withoutInsured(field(ScProfile, "InsuredItems").raw(), nothing) !=
     text(parseArray(field(ScProfile, "InsuredItems").raw())):
    into.add "insurance: removing nothing changed the cover"
  if withoutInsured("not json", @["kit1"]) != "[]":
    into.add "insurance: an unreadable cover answered " &
             withoutInsured("not json", @["kit1"])
  if withoutInsured(field(ScProfile, "InsuredItems").raw(),
                    @["kit1"]).contains("\"kit1\""):
    into.add "insurance: kit1 survived its own removal"

  # The seed behind the trader's line. A redelivery must compose the same
  # sentence, so it is a function of the profile, the trader, the situation
  # and the second the gear was lost, and of nothing that moves.
  if messageSeed("pid", "prapor", KeyFound, 1755529500) !=
     "pid.prapor.insuranceFound.1755529500":
    into.add "insurance: the message seed is " &
             messageSeed("pid", "prapor", KeyFound, 1755529500)

  result = into.len == before
