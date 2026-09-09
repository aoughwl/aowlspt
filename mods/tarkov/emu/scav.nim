## The scav: the second character behind every profile.
##
## A PMC profile carries a `savage` id from the day it is created, and until now
## there was nothing behind it — an id pointing at no character. The client wants
## a whole second profile there: its own name, its own face, its own inventory,
## its own cooldown timer, and the *same stash* as the PMC.
##
## That last word is the design. "Shared stash" could be implemented by copying
## the PMC's stash into the scav document and copying it back afterwards, and
## that is a synchronisation problem with two writers and no lock — the failure
## mode being a stash that quietly diverges and a player who loses whichever
## copy was written second. So the scav's stash is not stored at all.
##
## What is stored, under `scav.<pmc id>`, is only what is *the scav's*: identity,
## appearance, cooldown, and the gear hanging off its equipment container. The
## document handed to the client is that record with the PMC's stash — the
## container item and everything beneath it — spliced in at read time. There is
## exactly one copy of the stash, in the PMC profile, and the scav is a view of
## it. It cannot diverge because there is nothing to diverge from.
##
## The scav is deliberately **not** stored under `profile.` — `allProfileIds`
## drives the launcher's profile list, `nicknameTaken`, and the "bind the session
## to the only profile" fallback in the mod, and a scav appearing in all three
## would break every one of them.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import store
import ids
import profile
import inventory
import grid

const
  KeyPrefix* = "scav."

  ## The containers a scav needs to exist and to carry anything. Pockets is a
  ## real item with real children, not a flag: loot a scav picks up goes into it
  ## and comes home out of it.
  DefaultInventoryTpl = "55d7217a4bdc2d86028b456d"
  PocketsTpl = "627a4e6b255f7527fb05a0f6"
    ## The post-1.0 pockets, with `SpecialSlot1..3`, rather than the pre-1.0
    ## `557ffd194bdc2d28148b457f` that has none. Same 1x4 grid either way, so
    ## nothing about what a scav can carry changes -- but the client's
    ## `HasMarkOfUnknown` walks the pockets item's *slot* list, and giving it the
    ## item shape it expects there costs nothing. See `emu/profile.nim`.

  ## Equipment slots that are part of the character rather than gear. Their
  ## *contents* come home from a survived raid; the containers themselves do
  ## not, because a pair of pockets in the stash is not a thing.
  PassThroughSlots = ["Pockets", "SecuredContainer", "Scabbard", "Dogtag",
                      "ArmBand"]

proc scavKey*(pmcId: string): string = KeyPrefix & pmcId

# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------

proc dbList(path: string): List =
  let v = dbRead(path)
  if not v.ok or v.raw.len == 0:
    return newList()
  result = parseArray(v.raw)
  if not result.ok:
    result = newList()

proc pickFrom(l: List; salt: int; fallback: string): string =
  ## One entry out of a database list, chosen by an integer the caller varies.
  ## Not a random number generator -- there isn't one, and there does not need
  ## to be: what a scav name has to be is *different from the last one*, which a
  ## rolling counter gives, and reproducible from a log line, which a random
  ## number does not.
  if l.len == 0:
    return fallback
  var i = salt mod l.len
  if i < 0: i = -i
  result = at(l, i).asText(fallback)

proc scavName(salt: int): string =
  ## Out of the `assault` bot tables when the database has them. A server with
  ## no bot data gets "Scav" plus the salt, which is a name, is unique, and is
  ## visibly a placeholder rather than pretending to be content.
  let first = dbList("bots.types.assault.firstName")
  let last = dbList("bots.types.assault.lastName")
  if first.len == 0:
    return "Scav " & hex(int64(salt), 4)
  result = pickFrom(first, salt, "Scav")
  if last.len > 0:
    let surname = pickFrom(last, salt div 7 + 1, "")
    if surname.len > 0:
      result = result & " " & surname

proc pickLook(path: string; salt: int; fallback: string): string =
  ## One appearance id, out of a table written **either way round**.
  ##
  ## This read `dbList` alone, i.e. it assumed an array -- and SPT 4.x writes
  ## `appearance.head` and its siblings as **weight maps** (`{tpl: weight}`),
  ## as all 57 roles in a real import do. So on any real database the list came
  ## back empty and the player's scav wore the four hard-coded ids below,
  ## every single raid. `emu/bots.nim` had the identical bug one file over.
  ##
  ## It was invisible from the fixture in both files for the same reason: the
  ## fixture's arrays held exactly these four ids, so the fallback and the
  ## table agreed and no check could tell them apart. The fixture ships weight
  ## maps now.
  ##
  ## A weight of zero means never -- that is the shape's own rule, and it is
  ## why this cannot simply take the first key. A pool that is absent, empty,
  ## or all zero falls back, which is safe here in a way it is not everywhere:
  ## a wrong customisation id is a missing model in the client, not a crash.
  let pool = dbRead(path)
  if pool.ok and pool.raw.len > 0:
    let whole = whole(pool.raw)
    if whole.found:
      if isArray(whole):
        let n = count(whole)
        if n > 0:
          var i = salt mod n
          if i < 0: i = -i
          return at(whole, i).asText(fallback)
      else:
        # Weighted, by the same rule `emu/bots` uses: skip zero weights, and
        # walk the cumulative total with the caller's salt so the answer is
        # reproducible from a log line rather than merely varied.
        var keys: seq[string] = @[]
        var weights: seq[int] = @[]
        var total = 0
        for m in members(whole):
          let w = whole(m.value).asInt(0)
          if w > 0:
            keys.add m.name
            weights.add w
            total = total + w
        if total > 0:
          var pick = salt mod total
          if pick < 0: pick = -pick
          for i in 0 ..< keys.len:
            pick = pick - weights[i]
            if pick < 0:
              return keys[i]
  result = fallback

proc scavLooks(salt: int): JsonObject =
  ## A face. The four customisation ids the client resolves against its own
  ## bundles -- a wrong one is a missing model, not a crash, which is why the
  ## fallbacks are safe to hard-code.
  result = obj()
  put(result, "Head", pickLook("bots.types.assault.appearance.head",
                               salt, "5cc084dd14c02e000b0550a3"))
  put(result, "Body", pickLook("bots.types.assault.appearance.body",
                               salt, "5cde95ef7d6c8b04713c4f2d"))
  put(result, "Feet", pickLook("bots.types.assault.appearance.feet",
                               salt, "5cde95d97d6c8b647a3769b0"))
  put(result, "Hands", pickLook("bots.types.assault.appearance.hands",
                                salt, "5cc0876314c02e000c6bea6b"))

proc healthPart(current, maximum: int): JsonObject =
  var h = obj()
  put(h, "Current", current)
  put(h, "Maximum", maximum)
  result = h

proc scavHealth(nowSeconds: int): JsonObject =
  ## The eleven hit zones by name. A scav missing one is a character the client
  ## cannot spawn, exactly as for a PMC.
  var parts = obj()
  put(parts, "Head", objOf("Health", healthPart(35, 35)))
  put(parts, "Chest", objOf("Health", healthPart(85, 85)))
  put(parts, "Stomach", objOf("Health", healthPart(70, 70)))
  put(parts, "LeftArm", objOf("Health", healthPart(60, 60)))
  put(parts, "RightArm", objOf("Health", healthPart(60, 60)))
  put(parts, "LeftLeg", objOf("Health", healthPart(65, 65)))
  put(parts, "RightLeg", objOf("Health", healthPart(65, 65)))
  result = obj()
  put(result, "Hydration", healthPart(100, 100))
  put(result, "Energy", healthPart(100, 100))
  put(result, "Temperature", healthPart(36, 40))
  put(result, "BodyParts", parts)
  put(result, "UpdateTime", nowSeconds)
  put(result, "Immortal", false)

# ---------------------------------------------------------------------------
# The stored record
# ---------------------------------------------------------------------------

proc newScavRecord(pmc: Profile; scavId: string; salt, nowSeconds: int): string =
  ## Everything the scav owns, and nothing the PMC owns.
  ##
  ## `Inventory.stash` and the three other container ids point at the *PMC's*
  ## containers, and the items behind them are not in this document. They are
  ## spliced in by `scavText`, which is what makes the stash shared rather than
  ## copied.
  let equipment = newId()

  var settings = obj()
  put(settings, "Role", "assault")
  put(settings, "BotDifficulty", "normal")
  put(settings, "Experience", 0)
  put(settings, "StandingForKill", 0.0)
  put(settings, "AggressorBonus", 0.0)

  let name = scavName(salt)
  var info = obj()
  put(info, "Nickname", name)
  put(info, "LowerNickname", toLowerAscii(name))
  put(info, "Side", "Savage")
  put(info, "Voice", "Bear_1")
  put(info, "Level", 1)
  put(info, "Experience", 0)
  put(info, "RegistrationDate", nowSeconds)
  put(info, "GameVersion", "standard")
  put(info, "AccountType", 0)
  put(info, "MemberCategory", 0)
  put(info, "SelectedMemberCategory", 0)
  put(info, "lockedMoveCommands", false)
  # Zero is "no cooldown", which is what a freshly generated scav has. The
  # client reads this field to decide whether the scav button is playable and
  # what number to count down; a missing one is a button it draws as locked
  # forever.
  put(info, "SavageLockTime", 0)
  put(info, "LastTimePlayedAsSavage", 0)
  put(info, "BannedState", false)
  put(info, "BannedUntil", 0)
  put(info, "Settings", settings)
  put(info, "Bans", arr())

  # The scav's own two containers. Everything it wears or loots hangs off the
  # equipment item, and that is precisely the set of things a survived raid
  # brings home -- so the boundary between "the scav's" and "the player's" is
  # this parent id, not a rule written down somewhere else.
  var items = arr()
  var eq = obj()
  put(eq, "_id", equipment)
  put(eq, "_tpl", DefaultInventoryTpl)
  items.add eq
  var pockets = obj()
  put(pockets, "_id", newId())
  put(pockets, "_tpl", PocketsTpl)
  put(pockets, "parentId", equipment)
  put(pockets, "slotId", "Pockets")
  items.add pockets

  var inventory = obj()
  put(inventory, "items", items)
  put(inventory, "equipment", equipment)
  put(inventory, "stash", pmc.stashId)
  put(inventory, "questRaidItems",
      pmc.field("Inventory.questRaidItems").asText(""))
  put(inventory, "questStashItems",
      pmc.field("Inventory.questStashItems").asText(""))
  put(inventory, "sortingTable",
      pmc.field("Inventory.sortingTable").asText(""))
  put(inventory, "hideoutAreaStashes", obj())
  put(inventory, "fastPanel", obj())
  put(inventory, "favoriteItems", arr())

  var skills = obj()
  put(skills, "Common", arr())
  put(skills, "Mastering", arr())
  put(skills, "Points", 0)

  var p = obj()
  put(p, "_id", scavId)
  put(p, "aid", pmc.field("aid").asInt(0))
  put(p, "savage", jnull())
  put(p, "Info", info)
  put(p, "Customization", scavLooks(salt))
  put(p, "Health", scavHealth(nowSeconds))
  put(p, "Inventory", inventory)
  put(p, "Skills", skills)
  put(p, "Stats", objOf("Eft", objOf("OverallCounters", objOf("Items", arr()))))
  put(p, "Encyclopedia", obj())
  put(p, "TaskConditionCounters", obj())
  put(p, "InsuredItems", arr())
  put(p, "Hideout", objOf("Areas", arr()))
  put(p, "Bonuses", arr())
  put(p, "Notes", objOf("Notes", arr()))
  put(p, "Quests", arr())
  put(p, "ConditionCounters", objOf("Counters", arr()))
  put(p, "RagfairInfo", obj())
  put(p, "TradersInfo", obj())
  put(p, "UnlockedInfo", objOf("unlockedProductionRecipe", arr()))
  put(p, "WishList", obj())
  put(p, "Achievements", obj())
  put(p, "Prestige", obj())
  result = done(p).text

proc loadRecord(pmcId: string; usable: var bool): string =
  ## The scav's own document, and whether the key could be read. "" with
  ## `usable` true means there is genuinely no scav yet, which is what makes one
  ## get created; "" with `usable` false means there is one and it could not be
  ## read, and creating over that discards the cooldown and the character. See
  ## `emu/store`.
  result = readKey(scavKey(pmcId), usable)

proc loadRecord(pmcId: string): string =
  var usable = true
  result = loadRecord(pmcId, usable)

proc saveRecord(pmcId, recordJson: string): bool =
  result = save(scavKey(pmcId), recordJson) == Ok

proc regenerateScav*(pmc: Profile; nowSeconds: int): bool =
  ## A new scav: new name, new face, empty gear, no cooldown.
  ##
  ## The `savage` id is *kept*. The client caches it from the profile list and
  ## from the raid it just played, and handing it a different one mid-session
  ## produces a scav it cannot find. Regeneration replaces the character, not
  ## the identity -- which is also what the game does between scav runs.
  let scavId = pmc.scavId
  if scavId.len == 0:
    warn "profile " & pmc.id & " has no savage id; no scav can be made for it"
    return false
  let salt = int(nowMs() and 0xFFFF'i64) + pmc.stashId.len
  result = saveRecord(pmc.id, newScavRecord(pmc, scavId, salt, nowSeconds))

# ---------------------------------------------------------------------------
# The shared stash
# ---------------------------------------------------------------------------

proc subtreeItems(inv: Inventory; rootId: string): seq[string] =
  ## A container and everything beneath it, as raw items.
  result = @[]
  if rootId.len == 0:
    return
  let at = indexOf(inv, rootId)
  if at < 0:
    return
  result.add inv.items.items[at]
  let kids = descendantsOf(inv, rootId)
  for k in kids:
    let ki = indexOf(inv, k)
    if ki >= 0:
      result.add inv.items.items[ki]

proc sharedItems(pmc: Profile): seq[string] =
  ## The four containers the scav shares with the PMC, with their contents.
  ## All four, not just the stash: the scav document names them in
  ## `Inventory`, and a container id in there with no item behind it is an
  ## inventory screen the client draws empty and does not report.
  let inv = openInventory(pmc.field("Inventory.items").raw())
  result = @[]
  let roots = [pmc.stashId,
               pmc.field("Inventory.sortingTable").asText(""),
               pmc.field("Inventory.questRaidItems").asText(""),
               pmc.field("Inventory.questStashItems").asText("")]
  for r in roots:
    let part = subtreeItems(inv, r)
    for it in part:
      result.add it

proc scavText*(pmc: Profile; nowSeconds: int): string =
  ## The whole scav profile as the client wants it: the stored record with the
  ## PMC's stash spliced into its item list. "" when there is no scav and one
  ## could not be made.
  var record = loadRecord(pmc.id)
  if record.len == 0:
    if not regenerateScav(pmc, nowSeconds):
      return ""
    record = loadRecord(pmc.id)
    if record.len == 0:
      return ""

  var doc = parseObject(record)
  if not doc.ok:
    return ""
  var invDoc = parseObject(getRaw(doc, "Inventory"))
  if not invDoc.ok:
    return ""
  var items = parseArray(getRaw(invDoc, "items"))
  if not items.ok:
    items = newList()
  let shared = sharedItems(pmc)
  for it in shared:
    items.add it
  setRaw(invDoc, "items", text(items))
  setRaw(doc, "Inventory", text(invDoc))
  result = text(doc)

# ---------------------------------------------------------------------------
# The cooldown
# ---------------------------------------------------------------------------

proc setScavLock*(pmc: Profile; untilSeconds, nowSeconds: int): bool =
  ## When the scav can next be played. Written on the scav record because that
  ## is the document the client reads the timer out of, and mirrored onto the
  ## PMC by the caller because `Info.SavageLockTime` exists there too and a
  ## disagreement between the two is a button whose state depends on which
  ## screen you came from.
  let record = loadRecord(pmc.id)
  if record.len == 0:
    return false
  var doc = parseObject(record)
  if not doc.ok:
    return false
  var info = parseObject(getRaw(doc, "Info"))
  if not info.ok:
    return false
  setNumber(info, "SavageLockTime", untilSeconds)
  setNumber(info, "LastTimePlayedAsSavage", nowSeconds)
  setRaw(doc, "Info", text(info))
  result = saveRecord(pmc.id, text(doc))

proc scavLockTime*(pmc: Profile): int =
  let record = loadRecord(pmc.id)
  if record.len == 0:
    return 0
  result = field(record, "Info.SavageLockTime").asInt(0)

# ---------------------------------------------------------------------------
# Coming out of a raid
# ---------------------------------------------------------------------------

proc isPassThrough(slotId: string): bool =
  for s in PassThroughSlots:
    if s == slotId:
      return true
  result = false

proc stashTemplate(inv: Inventory; stashId: string): string =
  let at = indexOf(inv, stashId)
  if at < 0:
    return ""
  result = field(inv.items.items[at], "_tpl").asText("")

proc bringHome(inv: var Inventory; played: Inventory; stashId, rootId: string;
               problems: var seq[string]): bool =
  ## One item and its whole subtree, out of the scav's gear and into the stash.
  ##
  ## The item keeps its id. That is what makes this safe to run twice: an item
  ## already in the PMC's inventory is one that came home already, and the
  ## caller checks for exactly that before calling. Minting a fresh id here
  ## would turn a retried request into a duplicated rifle.
  let src = indexOf(played, rootId)
  if src < 0:
    return false
  var root = parseObject(played.items.items[src])
  if not root.ok:
    return false

  var g = stashGrid(stashTemplate(inv, stashId))
  markOccupied(g, text(inv.items), stashId)
  let place = findSpace(g, get(root, "_tpl").asText(""))
  if not place.ok:
    # Refused, not dropped at 0,0. An item overlapping another is drawn on top
    # of it and cannot be picked up, which is indistinguishable from never
    # having got it -- and this is the one path where the player is watching a
    # results screen tell them what they kept.
    problems.add "no room in the stash for " & get(root, "_tpl").asText("") &
                 "; it was left behind"
    return false

  setText(root, "parentId", stashId)
  setText(root, "slotId", "hideout")
  setRaw(root, "location", locationJson(place))
  inv.items.add text(root)

  # The subtree goes across untouched: a magazine's parent is still the rifle,
  # and rewriting any of that is how a gun arrives home with its mods in the
  # wrong slots.
  let kids = descendantsOf(played, rootId)
  for k in kids:
    let ki = indexOf(played, k)
    if ki >= 0:
      inv.items.add played.items.items[ki]
  inv.dirty = true
  result = true

proc endScavRaid*(pmc: var Profile; playedScav: string; survived: bool;
                  nowSeconds, cooldownSeconds: int;
                  brought: var int; problems: var seq[string]): bool =
  ## The whole of what a scav run is worth.
  ##
  ## Survive and the gear on the scav's back becomes the player's, in real cells
  ## of the real stash. Die and it does not — there is nothing to undo, because
  ## the scav's gear was never in the PMC document in the first place.
  ##
  ## Either way the scav is regenerated and the cooldown starts, which is also
  ## what discards a dead scav's loadout: the record is replaced rather than
  ## edited, so there is no state left over from the raid that just ended.
  brought = 0
  if survived:
    var inv = openInventory(pmc.field("Inventory.items").raw())
    if not inv.items.ok:
      problems.add "the profile has no item list; nothing was brought home"
    else:
      let played = openInventory(field(playedScav, "Inventory.items").raw())
      let equipment = field(playedScav, "Inventory.equipment").asText("")
      if equipment.len == 0:
        problems.add "the raid result named no equipment container"
      else:
        # What comes home: every direct child of the equipment container,
        # except the slots that are part of the character rather than gear --
        # for those, their contents come home instead.
        var roots: seq[string] = @[]
        let worn = childrenOf(played, equipment)
        for w in worn:
          let wi = indexOf(played, w)
          if wi < 0: continue
          let slot = field(played.items.items[wi], "slotId").asText("")
          if isPassThrough(slot):
            let inside = childrenOf(played, w)
            for i in inside:
              roots.add i
          else:
            roots.add w

        let stashId = pmc.stashId
        for r in roots:
          # Already in the PMC's inventory means it came home on an earlier
          # attempt at this same request, or it was never the scav's to begin
          # with. Either way, bringing it a second time makes two of it.
          if indexOf(inv, r) >= 0:
            continue
          if bringHome(inv, played, stashId, r, problems):
            inc brought
        if inv.dirty:
          setRaw(pmc, "Inventory.items", text(inv.items))

  # The cooldown, and then a new scav. In that order: `setScavLock` edits the
  # record that `regenerateScav` is about to replace, so doing it the other way
  # round would write the lock and then throw it away.
  let until = nowSeconds + cooldownSeconds
  if not regenerateScav(pmc, nowSeconds):
    problems.add "could not regenerate the scav"
    return false
  if not setScavLock(pmc, until, nowSeconds):
    problems.add "could not write the scav cooldown"
    return false
  setNumber(pmc, "Info.SavageLockTime", until)
  setNumber(pmc, "Info.LastTimePlayedAsSavage", nowSeconds)
  result = true

# ---------------------------------------------------------------------------
# Selling the scav's run to Fence
# ---------------------------------------------------------------------------

proc sellAllAction*(name: string): bool =
  ## `ItemEventActions.SELL_ALL_FROM_SAVAGE`. The reference dump carries the
  ## enum's member names and not their values, so this is the wire spelling the
  ## client uses -- the same convention `emu/personal` and `emu/gym` state.
  result = name == "SellAllFromSavage"

proc refuseSellAll*(action: JsonRef; ch: var Change) =
  ## "Sell all to Fence" on the scav's results screen, refused by name.
  ##
  ## **This one is not blocked on data.** The handbook prices are loaded, Fence
  ## is in `traders` with his `PriceModifier` and his loyalty levels, and
  ## `emu/mail` can pay roubles. What is missing is *the items*: there is
  ## nothing left in the scav to sell by the time this request can arrive.
  ##
  ## `endScavRaid` above moves everything a surviving scav carried into the PMC
  ## stash, in real cells, at `/client/match/local/end` -- which the client
  ## posts before it draws the screen this button is on. And that is not an
  ## accident to be undone here: the scav has no stash of its own *by design*
  ## (see this file's header, and `docs/BACKLOG.md`'s Group F), so there is no
  ## second inventory this could sell out of. Selling "everything in the scav's
  ## inventory" against the document this server serves would sell the player's
  ## whole stash, because the stash is spliced into it.
  ##
  ## So: refused, and the player is told the loot is already home rather than
  ## watching a button do nothing. The consequence is one lost convenience --
  ## the items are in the stash and have to be sold from there.
  ##
  ## The request carries one member, `TotalValue`, and **it is the client's
  ## arithmetic, not the server's.** It is logged in the refusal rather than
  ## acted on: a server that paid out a number the client chose, for items it
  ## never saw, would be taking dictation. Nothing here could check it even if
  ## the items were present in a form this could price.
  let claimed = action.field("totalValue").asInt(0)
  ch.problems.add "selling the scav's run to Fence is not something this " &
                  "server does: everything your scav survived with was moved " &
                  "into your stash when the raid ended, so there is nothing " &
                  "left in the scav to sell" &
                  (if claimed > 0: " (your client valued it at " & $claimed &
                                   "); sell it from the stash instead"
                   else: "; sell it from the stash instead")
