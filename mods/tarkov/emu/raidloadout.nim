## AutoRaid's ephemeral loadout: mint gear for a raid, and make sure it never
## reaches the stash.
##
## WHAT THIS IS FOR
## ----------------
## `mods/autoraid` can drive the client into a raid with no clicks. Its
## `loadoutMode = spawned` says the character goes in wearing gear that was
## CREATED for the raid rather than owned. Created gear that survives the raid
## is a duplication glitch with a friendly face, so every id this module mints
## is recorded and stripped out of the profile the client posts back at
## `/client/match/local/end`.
##
## THE MEASURED WIRE ORDER, AND THE CONSEQUENCE
## --------------------------------------------
## Measured from the real capture `mods/tarkov/data/capture/raid1/manifest.json`
## (the manifest's own `seq` numbers, one raid start and two later menu cycles):
##
##     096  POST /client/game/profile/list      <- the LAST profile/list
##     098  POST /client/game/profile/select
##     156  POST /client/raid/configuration
##     158  POST /client/match/local/start
##     204  POST /client/match/local/end
##     208  POST /client/game/profile/list      <- next cycle, back in the menu
##     273  POST /client/game/profile/list
##     275  POST /client/game/profile/select
##     368  POST /client/raid/configuration
##
## `/client/game/profile/list` is **NOT re-fetched** after `profile/select` and
## **NOT re-fetched** after `raid/configuration`. `onMatchStart` sends
## `profile: null`, so the inventory the character spawns with is the one
## delivered at that last `profile/list`.
##
## Therefore: NEITHER `tarkov.profile.selected` NOR `tarkov.raid.configured`
## precedes the last `profile/list` of a raid. Both fire AFTER it. A loadout
## applied when either event lands is written to the store correctly and is
## **not seen by the client for the raid that is starting** -- it is seen at the
## next `profile/list`, i.e. the next menu cycle.
##
## That is why `autoraid.loadout.apply` is honoured the moment it arrives and
## its result says WHEN it will land rather than pretending the timing is free.
## The two orderings that DO reach the client, and the only two, are:
##
##   * an apply that lands before the menu's `profile/list` -- which is what a
##     command-line-armed AutoRaid gets, because the backend and the mod are up
##     long before the character screen; and
##   * an apply that lands during a raid or at its end, which the NEXT raid
##     spawns with.
##
## `tarkov.raid.configured` remains the right trigger for the *bookkeeping* (the
## map is known there and nowhere earlier) and for a NEXT-raid loadout. It is
## the wrong trigger for a same-raid one, and this module says so in its status
## route rather than leaving the caller to discover it inside a raid.
##
## HOW EPHEMERALITY IS PROVEN, NOT ASSERTED
## ----------------------------------------
## The minted set is **not** taken from the builder's own bookkeeping.
## `GearReq.mintedId` records ONE id per request and the builder mints more than
## that: magazines (`mountMagazine`), cartridge stacks (`fillCartridges`),
## chambered rounds (`chamberRound`), every `_required` mod slot it fills, every
## extra stack past a stack limit inside a container, and everything
## `trading.giveItem` creates in the stash. Trusting `mintedId` would leave all
## of those in the profile forever -- the classic self-report.
##
## So the set is a DIFFERENCE of two finished states: every `_id` in the profile
## before `applyLoadout`, subtracted from every `_id` in the profile re-read
## after it. Nothing this module counted; two independent reads.
##
## And the end-of-raid verdict is a NEGATIVE over the SAVED profile text: after
## the save, re-read the profile off the store and assert that not one recorded
## id occurs anywhere in it. The input that makes it FAIL is concrete -- remove
## the strip call and every id is still there -- which is what CLAUDE.md 9b asks
## for.
##
## NEVER DESTROY GEAR
## ------------------
## Before a loadout is applied, whatever the character is wearing is MOVED to
## the stash, into real free cells found by `emu/grid.findSpace`. The whole move
## is planned before a byte is written and REFUSED whole -- with the slot and
## template named -- when any one item has nowhere to go, because half a move
## leaves a rig in the stash and its magazines worn.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import profile
import inventory
import grid
import templates
import loadout
import store

const
  ARMintedPrefix* = "autoraid.minted."
    ## Store key per profile: `autoraid.minted.<profileId>`, a JSON array of
    ## item `_id`s this module minted and owes the player nothing for.
  ARApplyEvent* = "autoraid.loadout.apply"
  ARResultEvent* = "autoraid.loadout.result"
  StandardStashTpl = "5811ce572459770cba1a34ea"
  ARWireOrder* = "profile/list -> profile/select -> raid/configuration -> match/local/start (measured: mods/tarkov/data/capture/raid1/manifest.json seq 096, 098, 156, 158; profile/list is NOT re-fetched after either of the last two, so a loadout applied at select or configuration time reaches the client at the NEXT profile/list, not this raid)"

var
  gARLastResult = "{}"
  gARLastProfile = ""
  gARApplies = 0
  gARMode = "current"
    ## "current" until an apply with `ephemeral:true` has been honoured, then
    ## "spawned". This module cannot read `mods/autoraid`'s config -- a client
    ## mod's config.json does not reach the backend -- so the mode reported here
    ## is what has actually been ASKED FOR on the bus, not what a file says.

proc arMintedKey*(profileId: string): string = ARMintedPrefix & profileId

# ---------------------------------------------------------------------------
# The minted set
# ---------------------------------------------------------------------------

proc arReadMinted*(profileId: string; usable: var bool): seq[string] =
  result = @[]
  let raw1 = readKey(arMintedKey(profileId), usable)
  if not usable or raw1.len == 0:
    return
  let list = whole(raw1)
  let n = count(list)
  for i in 0 ..< n:
    let one = at(list, i).asText("")
    if one.len > 0:
      result.add one

proc arWriteMinted*(profileId: string; ids: seq[string]): bool =
  var a = arr()
  for id in ids:
    add(a, id)
  result = save(arMintedKey(profileId), done(a)) == Ok

proc arClearMinted*(profileId: string): bool =
  result = save(arMintedKey(profileId), "[]") == Ok

proc arItemIds*(itemsJson: string): seq[string] =
  ## Every `_id` in an item array, in order.
  result = @[]
  let list = parseArray(itemsJson)
  if not list.ok:
    return
  for i in 0 ..< list.len:
    let id = field(list.items[i], "_id").asText("")
    if id.len > 0:
      result.add id

proc arHas(ids: seq[string]; id: string): bool =
  result = false
  for one in ids:
    if one == id:
      return true

# ---------------------------------------------------------------------------
# Moving the worn gear to the stash
# ---------------------------------------------------------------------------

proc arStashTemplate(inv: Inventory; stash: string): string =
  ## `emu/trading` has this and does not export it; duplicated rather than
  ## widening another module's surface for one caller. The fallback is the
  ## standard stash, which is what `grid.stashGrid` falls back to anyway.
  result = StandardStashTpl
  for i in 0 ..< inv.items.len:
    if field(inv.items.items[i], "_id").asText("") == stash:
      let tpl = field(inv.items.items[i], "_tpl").asText("")
      if tpl.len > 0:
        return tpl

proc arStashWornGear*(p: var Profile; moved: var int; why: var string): bool =
  ## Move every worn item -- and, by parentage, its whole subtree -- into the
  ## stash.
  ##
  ## Pockets and SecuredContainer are left alone, for the same reason
  ## `loadout.clearEquipment` leaves them: a character with no Pockets item does
  ## not spawn at all.
  ##
  ## `false` means NOTHING was written and `why` names the slot and template
  ## that had nowhere to go.
  moved = 0
  why = ""
  let equipmentId = p.field("Inventory.equipment").asText("")
  let stash = stashId(p)
  if equipmentId.len == 0:
    why = "profile " & p.id & " has no Inventory.equipment, so nothing is worn"
    return false
  if stash.len == 0:
    why = "profile " & p.id & " has no Inventory.stash to move gear into"
    return false
  var inv = openInventory(p.field("Inventory.items").raw)
  if not inv.items.ok:
    why = "profile " & p.id & "'s Inventory.items did not parse as an array"
    return false

  var wornIds: seq[string] = @[]
  var wornTpls: seq[string] = @[]
  var wornSlots: seq[string] = @[]
  for i in 0 ..< inv.items.len:
    let one = whole(inv.items.items[i])
    if one.field("parentId").asText("") != equipmentId:
      continue
    let slot = one.field("slotId").asText("")
    if slot == "Pockets" or slot == "SecuredContainer":
      continue
    let id = one.field("_id").asText("")
    if id.len == 0:
      continue
    wornIds.add id
    wornTpls.add one.field("_tpl").asText("")
    wornSlots.add slot
  if wornIds.len == 0:
    return true

  var g = stashGrid(arStashTemplate(inv, stash))
  markOccupied(g, text(inv.items), stash)
  var places: seq[Placement] = @[]
  for i in 0 ..< wornTpls.len:
    let pl = findSpace(g, wornTpls[i])
    if not pl.ok:
      why = "the stash has no free cell for " & wornTpls[i] & " worn in " &
            wornSlots[i] & ". " & $wornIds.len &
            " worn item(s) were to be moved and NONE were: the whole move is " &
            "refused rather than leaving a rig in the stash and its magazines worn"
      return false
    var w = 1
    var h = 1
    itemSize(wornTpls[i], w, h)
    if pl.rotated:
      let t = w
      w = h
      h = t
    occupy(g, pl.x, pl.y, w, h)
    places.add pl

  for i in 0 ..< wornIds.len:
    let at1 = indexOf(inv, wornIds[i])
    if at1 < 0:
      continue
    var d = parseObject(inv.items.items[at1])
    setText(d, "parentId", stash)
    setText(d, "slotId", "hideout")
    setRaw(d, "location", locationJson(places[i]))
    replaceAt(inv.items, at1, text(d))
    inc moved
  setRaw(p, "Inventory.items", text(inv.items))
  result = true

# ---------------------------------------------------------------------------
# Stripping
# ---------------------------------------------------------------------------

proc arStripIds*(itemsJson: string; minted: seq[string];
                 stripped: var int): string =
  ## Remove every subtree rooted at a recorded minted id. Returns the new item
  ## array text; `stripped` counts the ROOTS actually found (a root that is not
  ## there -- lost in the raid, sold, never delivered -- is counted as absent,
  ## not as an error).
  stripped = 0
  result = itemsJson
  var inv = openInventory(itemsJson)
  if not inv.items.ok:
    return
  var doomed: seq[string] = @[]
  for id in minted:
    if id.len == 0:
      continue
    if indexOf(inv, id) < 0:
      continue
    inc stripped
    if not arHas(doomed, id):
      doomed.add id
    let kids = descendantsOf(inv, id)
    for k in kids:
      if k.len > 0 and not arHas(doomed, k):
        doomed.add k
  if doomed.len == 0:
    return
  var kept = newList()
  for i in 0 ..< inv.items.len:
    let id = field(inv.items.items[i], "_id").asText("")
    if id.len > 0 and arHas(doomed, id):
      continue
    add(kept, inv.items.items[i])
  result = text(kept)

proc arStripBeforeSave*(updated: var Profile; profileId: string;
                        minted: var seq[string]): bool =
  ## Called from `onMatchEnd` on the profile that is ABOUT to be saved.
  ##
  ## `minted` comes back populated so the caller can run the after-the-save
  ## verdict against it; the store key is cleared here, because the raid it
  ## belonged to is over whatever happens next.
  minted = @[]
  var usable = true
  minted = arReadMinted(profileId, usable)
  if not usable:
    error "autoraid loadout: " & arMintedKey(profileId) &
          " exists and could not be read, so NOTHING was stripped -- the " &
          "minted gear stays in the profile rather than guessing at an empty set"
    return false
  if minted.len == 0:
    return false
  var stripped = 0
  let itemsJson = updated.field("Inventory.items").raw
  let after = arStripIds(itemsJson, minted, stripped)
  if stripped > 0:
    setRaw(updated, "Inventory.items", after)
  info "autoraid loadout: STRIPPED " & $stripped & " of " & $minted.len &
       " minted item(s)"
  discard arClearMinted(profileId)
  result = true

proc arEndVerdict*(profileId: string; minted: seq[string]) =
  ## The negative, over the SAVED profile text. Re-read off the store, not the
  ## in-memory copy that was just written.
  if minted.len == 0:
    return
  let saved = loadProfile(profileId)
  if not saved.ok:
    info "autoraid loadout END VERDICT INCONCLUSIVE: profile " & profileId &
         " could not be re-read after the save"
    return
  var survivors: seq[string] = @[]
  for id in minted:
    if id.len > 0 and saved.text.contains(id):
      survivors.add id
  if survivors.len == 0:
    info "autoraid loadout END VERDICT PASS -- none of " & $minted.len &
         " minted id(s) occurs anywhere in the saved profile"
  else:
    error "autoraid loadout END VERDICT FAIL -- " & $survivors.len & " of " &
          $minted.len & " minted id(s) survived the save, first is " &
          survivors[0]

# ---------------------------------------------------------------------------
# The apply
# ---------------------------------------------------------------------------

proc arResultJson(profileId, verdict, why, reason: string;
                  requested, minted, placed, rejected: int): string =
  var o = obj()
  put(o, "profileId", profileId)
  put(o, "verdict", verdict)
  put(o, "requested", requested)
  put(o, "minted", minted)
  put(o, "placed", placed)
  put(o, "rejected", rejected)
  put(o, "reason", reason)
  put(o, "why", why)
  result = done(o).text

proc arFinish(profileId, verdict, why, reason: string;
              requested, minted, placed, rejected: int): string =
  result = arResultJson(profileId, verdict, why, reason, requested, minted,
                        placed, rejected)
  gARLastResult = result
  gARLastProfile = profileId
  discard emit(ARResultEvent, result)

proc arApply*(payload: string): string =
  ## The `autoraid.loadout.apply` handler.
  ##
  ## `{"profileId":"<24hex>","spec":{"clear":bool,"gear":[..]},
  ##   "ephemeral":true,"reason":".."}`
  inc gARApplies
  let profileId = field(payload, "profileId").asText("")
  let spec = field(payload, "spec")
  let ephemeral = field(payload, "ephemeral").asBool(true)
  let reason = field(payload, "reason").asText("")
  if profileId.len == 0:
    return arFinish("", "INCONCLUSIVE",
                    "the apply names no `profileId`; nothing was looked at",
                    reason, 0, 0, 0, 0)
  if not exists(spec):
    return arFinish(profileId, "INCONCLUSIVE",
                    "the apply carries no `spec`; nothing was looked at",
                    reason, 0, 0, 0, 0)

  # The minted set must be READABLE before anything is minted. A present-and-
  # unreadable key means a previous raid's set may still be owed a strip, and
  # minting on top of it would make two raids' gear indistinguishable.
  var usable = true
  let previous = arReadMinted(profileId, usable)
  if not usable:
    return arFinish(profileId, "INCONCLUSIVE",
                    arMintedKey(profileId) & " exists and could not be read, " &
                    "so no gear was minted -- a second set on top of an " &
                    "unknown one cannot be told apart later",
                    reason, 0, 0, 0, 0)
  if previous.len > 0:
    warn "autoraid loadout: " & $previous.len & " minted id(s) from an earlier " &
         "raid are still recorded for " & profileId &
         "; they are stripped now, before this apply"
    var p0 = loadProfile(profileId)
    if p0.ok:
      var strippedOld = 0
      let afterOld = arStripIds(p0.field("Inventory.items").raw, previous,
                                strippedOld)
      if strippedOld > 0:
        setRaw(p0, "Inventory.items", afterOld)
        discard saveProfile(p0)
      info "autoraid loadout: STRIPPED " & $strippedOld & " of " &
           $previous.len & " minted item(s)"
    discard arClearMinted(profileId)

  var p = loadProfile(profileId)
  if not p.ok:
    return arFinish(profileId, "INCONCLUSIVE",
                    "could not read profile " & profileId &
                    " -- the question was never asked", reason, 0, 0, 0, 0)

  let before = arItemIds(p.field("Inventory.items").raw)

  # The player's own gear goes to the stash FIRST, and a refusal here stops the
  # whole operation: minting on top of worn gear that could not be put away is
  # how a loadout silently overwrites what someone owns.
  var moved = 0
  var whyMove = ""
  if not arStashWornGear(p, moved, whyMove):
    return arFinish(profileId, "FAIL",
                    "the worn gear could not be moved to the stash, so " &
                    "nothing was minted: " & whyMove, reason, 0, 0, 0, 0)
  if moved > 0:
    if not saveProfile(p):
      return arFinish(profileId, "INCONCLUSIVE",
                      "the worn gear was moved but the profile would not save",
                      reason, 0, 0, 0, 0)
    info "autoraid loadout: moved " & $moved &
         " worn item(s) to the stash before minting"

  # `applyLoadout` re-reads the profile off the store, which is why the move
  # above is SAVED first rather than handed over in memory.
  var gearRaw = spec.field("gear").raw
  if gearRaw.len == 0:
    gearRaw = "[]"
  var body = obj()
  put(body, "profileId", profileId)
  put(body, "clear", spec.field("clear").asBool(false))
  put(body, "gear", raw(gearRaw))
  let rep = applyLoadout(done(body).text)

  let after = loadProfile(profileId)
  if not after.ok:
    return arFinish(profileId, "INCONCLUSIVE",
                    "the profile could not be re-read after the mint, so the " &
                    "minted set is unknown and NOTHING is recorded as ephemeral",
                    reason, rep.requested, rep.minted, rep.placed,
                    rep.rejected.len)
  let afterIds = arItemIds(after.field("Inventory.items").raw)
  var mintedIds: seq[string] = @[]
  for id in afterIds:
    if not arHas(before, id):
      mintedIds.add id

  if ephemeral:
    gARMode = "spawned"
    if not arWriteMinted(profileId, mintedIds):
      return arFinish(profileId, "FAIL",
                      "the gear was minted and the minted set could NOT be " &
                      "recorded, so it cannot be stripped at raid end -- " &
                      $mintedIds.len & " item(s) would become permanent",
                      reason, rep.requested, rep.minted, rep.placed,
                      rep.rejected.len)
  else:
    discard arClearMinted(profileId)

  var why = rep.reason
  if rep.rejected.len > 0:
    why = why & " | " & rep.rejected[0]
  why = why & " | moved " & $moved & " worn item(s) to the stash, recorded " &
        $mintedIds.len & " minted id(s) as " &
        (if ephemeral: "EPHEMERAL" else: "PERMANENT") &
        " | the client sees this at its NEXT /client/game/profile/list -- " &
        ARWireOrder
  result = arFinish(profileId, rep.verdict, why, reason, rep.requested,
                    rep.minted, rep.placed, rep.rejected.len)

# ---------------------------------------------------------------------------
# Restart sweep
# ---------------------------------------------------------------------------

proc arSweepStale*(): int =
  ## At load: no raid can be in progress in a process that has just started, so
  ## any recorded minted set is left over from a raid that never ended -- a
  ## crash, a kill of the client, a backend restart mid-raid. Strip it and say
  ## so, rather than letting minted gear age into owned gear.
  result = 0
  var keysJson = ""
  if storeList(ARMintedPrefix, keysJson) != Ok:
    return
  let keys = whole(keysJson)
  let n = count(keys)
  for i in 0 ..< n:
    let key = at(keys, i).asText("")
    if not key.startsWith(ARMintedPrefix):
      continue
    let profileId = key.substr(ARMintedPrefix.len)
    if profileId.len == 0:
      continue
    var usable = true
    let minted = arReadMinted(profileId, usable)
    if not usable:
      error "autoraid loadout: stale set " & key & " is unreadable; it is " &
            "LEFT ALONE rather than treated as empty"
      continue
    if minted.len == 0:
      continue
    var p = loadProfile(profileId)
    if not p.ok:
      warn "autoraid loadout: stale set " & key & " names a profile that " &
           "cannot be read; nothing was stripped"
      continue
    var stripped = 0
    let itemsAfter = arStripIds(p.field("Inventory.items").raw, minted, stripped)
    if stripped > 0:
      setRaw(p, "Inventory.items", itemsAfter)
      if not saveProfile(p):
        error "autoraid loadout: stale set " & key & " could not be stripped " &
              "-- the profile would not save"
        continue
    warn "autoraid loadout: a raid ended without a match/local/end for " &
         profileId & " (backend restart); STRIPPED " & $stripped & " of " &
         $minted.len & " minted item(s) now"
    discard arClearMinted(profileId)
    arEndVerdict(profileId, minted)
    inc result

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------

proc arStatusJson*(): string =
  var o = obj()
  put(o, "mode", gARMode)
  put(o, "applies", gARApplies)
  put(o, "lastProfile", gARLastProfile)
  put(o, "lastResult", raw(gARLastResult))
  put(o, "wireOrder", ARWireOrder)
  # Named as a FALSE rather than left out: the whole point of the measurement is
  # that an apply triggered by either tarkov event misses the raid it was
  # triggered for.
  put(o, "loadoutLandsBeforeLastProfileList", false)
  var pending = arr()
  var keysJson = ""
  var readable = false
  if storeList(ARMintedPrefix, keysJson) == Ok:
    readable = true
    let keys = whole(keysJson)
    let n = count(keys)
    for i in 0 ..< n:
      let key = at(keys, i).asText("")
      if not key.startsWith(ARMintedPrefix):
        continue
      let profileId = key.substr(ARMintedPrefix.len)
      if profileId.len == 0:
        continue
      var usable = true
      let minted = arReadMinted(profileId, usable)
      var one = obj()
      put(one, "profileId", profileId)
      put(one, "minted", minted.len)
      put(one, "readable", usable)
      add(pending, done(one))
  put(o, "pendingReadable", readable)
  put(o, "pending", done(pending))
  result = done(o).text

# ---------------------------------------------------------------------------
# Self-check
# ---------------------------------------------------------------------------

proc selfCheckRaidLoadout*(into: var seq[string]): bool =
  ## What can be proven with no database, no host store and no profile.
  ##
  ## The subject is the STRIP, because the strip is the only thing standing
  ## between a minted loadout and a duplicated stash. Every assertion below is
  ## over a synthetic item array built here, and each one can fail: delete the
  ## `descendantsOf` walk and case 2 goes red; count roots that were not found
  ## and case 3 goes red; make `findSpace` optimistic and case 4 goes red.
  result = true

  # 1. A minted set round-trips through the JSON the store holds.
  var a = arr()
  add(a, "aaaaaaaaaaaaaaaaaaaaaaaa")
  add(a, "bbbbbbbbbbbbbbbbbbbbbbbb")
  let roundTrip = done(a).text
  var back: seq[string] = @[]
  let list = whole(roundTrip)
  let backN = count(list)
  for i in 0 ..< backN:
    back.add at(list, i).asText("")
  if back.len != 2 or back[0] != "aaaaaaaaaaaaaaaaaaaaaaaa" or
     back[1] != "bbbbbbbbbbbbbbbbbbbbbbbb":
    into.add "raidloadout: a minted set did not round-trip through its JSON"
    result = false

  # 2. A NESTED minted item is stripped whole: rifle -> magazine -> cartridges,
  #    with an owned item beside it that must survive.
  let items = "[{\"_id\":\"stash000000000000000000\",\"_tpl\":\"" &
    StandardStashTpl & "\"}," &
    "{\"_id\":\"owned000000000000000000o\",\"_tpl\":\"t1\"," &
    "\"parentId\":\"stash000000000000000000\",\"slotId\":\"hideout\"}," &
    "{\"_id\":\"rifle000000000000000000r\",\"_tpl\":\"t2\"," &
    "\"parentId\":\"equip000000000000000000e\",\"slotId\":\"FirstPrimaryWeapon\"}," &
    "{\"_id\":\"mag00000000000000000000m\",\"_tpl\":\"t3\"," &
    "\"parentId\":\"rifle000000000000000000r\",\"slotId\":\"mod_magazine\"}," &
    "{\"_id\":\"ammo0000000000000000000a\",\"_tpl\":\"t4\"," &
    "\"parentId\":\"mag00000000000000000000m\",\"slotId\":\"cartridges\"}]"
  var stripped = 0
  let afterText = arStripIds(items, @["rifle000000000000000000r"], stripped)
  if stripped != 1:
    into.add "raidloadout: stripping one PRESENT root counted " & $stripped &
             " rather than 1"
    result = false
  let afterIds = arItemIds(afterText)
  if afterIds.len != 2:
    into.add "raidloadout: a nested minted subtree left " & $afterIds.len &
             " item(s) rather than 2 -- the magazine or its cartridges survived"
    result = false
  if arHas(afterIds, "mag00000000000000000000m") or
     arHas(afterIds, "ammo0000000000000000000a"):
    into.add "raidloadout: a child of a minted item survived the strip"
    result = false
  if not arHas(afterIds, "owned000000000000000000o"):
    into.add "raidloadout: an item the player OWNED was stripped"
    result = false

  # 3. An id that is not there -- lost in the raid -- is not counted and is not
  #    an error. The negative control for case 2's count.
  var absent = 0
  let untouched = arStripIds(items, @["nothere0000000000000000n"], absent)
  if absent != 0:
    into.add "raidloadout: an absent minted id was counted as stripped"
    result = false
  if arItemIds(untouched).len != 5:
    into.add "raidloadout: stripping an absent id changed the item array"
    result = false

  # 4. The no-room refusal. A full grid must have nowhere to put worn gear --
  #    and an EMPTY grid of the same size must have somewhere, or case 4 would
  #    be passing because `findSpace` refuses everything.
  var full = newGrid(1, 1)
  occupy(full, 0, 0, 1, 1)
  if findSpace(full, "t2").ok:
    into.add "raidloadout: a FULL grid answered ok to findSpace, so the " &
             "no-room refusal cannot fire"
    result = false
  var empty1 = newGrid(1, 1)
  if not findSpace(empty1, "t2").ok:
    into.add "raidloadout: an EMPTY grid refused, so case 4 proves nothing " &
             "about fullness"
    result = false

  # 5. An apply naming no profile must refuse with a reason and must never PASS.
  let noProfile = arApply("{\"spec\":{\"gear\":[]}}")
  if field(noProfile, "verdict").asText("") != "INCONCLUSIVE":
    into.add "raidloadout: an apply with no profileId answered \"" &
             field(noProfile, "verdict").asText("") &
             "\" rather than INCONCLUSIVE"
    result = false
  if field(noProfile, "why").asText("").len == 0:
    into.add "raidloadout: an apply that refused did not say why"
    result = false

  # 6. An apply with a profile but no `spec` is a DIFFERENT refusal and must say
  #    so -- otherwise one message covers two causes.
  let noSpec = arApply("{\"profileId\":\"aaaaaaaaaaaaaaaaaaaaaaaa\"}")
  if field(noSpec, "verdict").asText("") == "PASS":
    into.add "raidloadout: an apply with no spec reported PASS"
    result = false
