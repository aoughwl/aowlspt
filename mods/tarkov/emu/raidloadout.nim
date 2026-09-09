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
## THE ONE PLACE A LOADOUT CAN LAND FOR THE COMING RAID
## ----------------------------------------------------
## The measurement above leaves exactly one window: BEFORE `onProfileList`
## builds its response. So `onProfileList` emits `tarkov.profile.listing`
## `{session, profileId, cycle}` before it loads a single profile, and a
## subscriber may emit `autoraid.loadout.apply` from inside that event.
## `applyLoadout` writes the store, `onProfileList` then loads the profiles
## fresh, and the UPDATED text is what goes on the wire -- so the raid that
## follows this menu cycle spawns with it.
##
## `arListingBegin` / `arListingEnd` bracket that window. An apply honoured
## inside it reports `landsThisCycle: true`; one honoured outside it reports
## false, because it does not, and saying otherwise would be a status route
## that cannot be wrong.
##
## IDEMPOTENT INSIDE THE WINDOW
## ----------------------------
## The client fetches `profile/list` more than once per session (measured: seq
## 083 and 096 in the same menu, and again at 208/273 after a raid). A second
## apply while a minted set is still ACTIVE -- a raid configured with no
## `match/local/end` yet -- would mint a second kit on top of the first and
## make the two indistinguishable at strip time. So it is REFUSED and says so;
## `"force": true` in the payload is the deliberate override, which strips the
## previous set first.
##
## `tarkov.raid.configured` and `tarkov.profile.selected` are still emitted and
## are still useful signals -- the map is known at the first and nowhere
## earlier -- but both are TOO LATE for the raid they announce. They are the
## right trigger for a NEXT-raid loadout and the wrong one for this raid, and
## this module says so in its status route rather than leaving the caller to
## discover it inside a raid.
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
  gARInListing = false
    ## True only between `arListingBegin` and `arListingEnd`, i.e. while
    ## `onProfileList` is about to build a response. An apply honoured here is
    ## seen by the client THIS menu cycle; one honoured anywhere else is not.
  gARLastAtListing = false
  gARListingCycles = 0

proc arListingBegin*() =
  ## `onProfileList` is about to emit `tarkov.profile.listing`. Everything a
  ## subscriber does until `arListingEnd` lands on the wire in this response.
  inc gARListingCycles
  gARInListing = true

proc arListingEnd*() =
  gARInListing = false

proc arListingCycle*(): int = gARListingCycles

proc arRefusesRemint*(activeMinted: int; force: bool): bool =
  ## The idempotency decision, on its own so it can be checked without a store.
  ##
  ## An ACTIVE minted set means a kit was minted and no `match/local/end` has
  ## taken it back. Minting again would put two kits in the profile with one
  ## recorded set, and the strip would then be unable to tell them apart. The
  ## only way past it is an explicit `force`.
  result = activeMinted > 0 and not force

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

proc arStripIdsD*(itemsJson: string; minted: seq[string];
                  stripped: var int; doomed: var seq[string]): string =
  ## Remove every subtree rooted at a recorded minted id. Returns the new item
  ## array text; `stripped` counts the ROOTS actually found (a root that is not
  ## there -- lost in the raid, sold, never delivered -- is counted as absent,
  ## not as an error). `doomed` comes back as every id removed -- roots AND
  ## descendants -- so the caller can prune REFERENCES to them elsewhere.
  stripped = 0
  result = itemsJson
  var inv = openInventory(itemsJson)
  if not inv.items.ok:
    return
  doomed = @[]
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

proc arStripIds*(itemsJson: string; minted: seq[string];
                 stripped: var int): string =
  ## `arStripIdsD` without the doomed list, for callers that only need the
  ## item array back.
  var doomed: seq[string] = @[]
  result = arStripIdsD(itemsJson, minted, stripped, doomed)

# ---------------------------------------------------------------------------
# References OUTSIDE the item array.
#
# MEASURED 2026-09-05, the first live raid with a spawned kit: the END VERDICT
# found 3 of 29 minted ids surviving the save, and all three were KEYS of
# `CheckedMagazines` -- the map the client posts back at match end for the
# magazines it inspected in the raid. A dangling item id there is the
# "Cannot find ... for item" class of client throw, so every place the profile
# can name an item id is pruned with the same doomed set. Each helper is pure
# over JSON text, returns the input unchanged when nothing matched, and is
# exercised by `selfCheckRaidLoadout` with a positive AND a negative case.
# ---------------------------------------------------------------------------

proc arPruneObjectKeys*(objText: string; doomed: seq[string];
                        pruned: var int): string =
  ## `{"<itemId>": v, ...}` (CheckedMagazines) without the doomed keys.
  result = objText
  let j = whole(objText)
  if not isObject(j):
    return
  var o = obj()
  var hit = 0
  for k in keys(j):
    if arHas(doomed, k):
      inc hit
      continue
    put(o, k, raw(field(j, k).raw))
  if hit == 0:
    return
  pruned = pruned + hit
  result = done(o).text

proc arPruneObjectValues*(objText: string; doomed: seq[string];
                          pruned: var int): string =
  ## `{"<slot>": "<itemId>", ...}` (Inventory.fastPanel) without the entries
  ## whose VALUE is a doomed id.
  result = objText
  let j = whole(objText)
  if not isObject(j):
    return
  var o = obj()
  var hit = 0
  for k in keys(j):
    let v = field(j, k).asText("")
    if v.len > 0 and arHas(doomed, v):
      inc hit
      continue
    put(o, k, raw(field(j, k).raw))
  if hit == 0:
    return
  pruned = pruned + hit
  result = done(o).text

proc arPruneList*(listText: string; doomed: seq[string]; keyField: string;
                  pruned: var int): string =
  ## `["<itemId>", ...]` (keyField == "", favoriteItems) or
  ## `[{"<keyField>": "<itemId>", ...}, ...]` (InsuredItems.itemId) without
  ## the entries that name a doomed id.
  result = listText
  let j = whole(listText)
  if not isArray(j):
    return
  var l = newList()
  var hit = 0
  let n = count(j)
  for i in 0 ..< n:
    let e = at(j, i)
    let id = if keyField.len == 0: e.asText("") else: e.field(keyField).asText("")
    if id.len > 0 and arHas(doomed, id):
      inc hit
      continue
    add(l, e.raw)
  if hit == 0:
    return
  pruned = pruned + hit
  result = text(l)

proc arPruneReferences*(updated: var Profile; doomed: seq[string]): int =
  ## Apply the three prunes to the profile about to be saved. Returns how many
  ## references went; zero is the ordinary case and is not a failure.
  result = 0
  if doomed.len == 0:
    return
  let cm = updated.field("CheckedMagazines")
  if cm.found and isObject(cm):
    let t = arPruneObjectKeys(cm.raw, doomed, result)
    if t != cm.raw:
      setRaw(updated, "CheckedMagazines", t)
  let fp = updated.field("Inventory.fastPanel")
  if fp.found and isObject(fp):
    let t = arPruneObjectValues(fp.raw, doomed, result)
    if t != fp.raw:
      setRaw(updated, "Inventory.fastPanel", t)
  let fav = updated.field("Inventory.favoriteItems")
  if fav.found and isArray(fav):
    let t = arPruneList(fav.raw, doomed, "", result)
    if t != fav.raw:
      setRaw(updated, "Inventory.favoriteItems", t)
  let ins = updated.field("InsuredItems")
  if ins.found and isArray(ins):
    let t = arPruneList(ins.raw, doomed, "itemId", result)
    if t != ins.raw:
      setRaw(updated, "InsuredItems", t)

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
  var doomed: seq[string] = @[]
  let itemsJson = updated.field("Inventory.items").raw
  let after = arStripIdsD(itemsJson, minted, stripped, doomed)
  if stripped > 0:
    setRaw(updated, "Inventory.items", after)
  # The recorded set covers roots; what the client posted back may reference
  # any descendant too (a magazine inside the minted rifle). Prune by the
  # recorded ids AND everything the strip removed.
  var refs = minted
  for d in doomed:
    if not arHas(refs, d):
      refs.add d
  let pruned = arPruneReferences(updated, refs)
  info "autoraid loadout: STRIPPED " & $stripped & " of " & $minted.len &
       " minted item(s)" &
       (if pruned > 0: ", and " & $pruned & " reference(s) to them outside " &
                       "Inventory.items (CheckedMagazines / fastPanel / " &
                       "favoriteItems / InsuredItems)"
        else: "")
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
  # Whether this apply reaches the client for the raid that follows THIS menu
  # cycle. True only inside the `tarkov.profile.listing` window; anywhere else
  # the client has already been handed its profile and will not ask again.
  put(o, "landsThisCycle", gARInListing)
  put(o, "cycle", gARListingCycles)
  result = done(o).text

proc arFinish(profileId, verdict, why, reason: string;
              requested, minted, placed, rejected: int): string =
  result = arResultJson(profileId, verdict, why, reason, requested, minted,
                        placed, rejected)
  gARLastResult = result
  gARLastProfile = profileId
  gARLastAtListing = gARInListing
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
  let force = field(payload, "force").asBool(false)
  if arRefusesRemint(previous.len, force):
    # The client asks for `profile/list` more than once per menu (measured: seq
    # 083 and 096 in the same cycle), so this fires on the ordinary path, not
    # only on a fault. It is an announcement, not a failure.
    return arFinish(profileId, "INCONCLUSIVE",
                    "a minted set of " & $previous.len & " item(s) is ALREADY " &
                    "ACTIVE for " & profileId & " -- a raid was armed and no " &
                    "/client/match/local/end has taken it back yet -- so " &
                    "nothing was minted again. Two kits under one recorded set " &
                    "could not be told apart at strip time. Pass " &
                    "\"force\": true to strip the active set and mint afresh.",
                    reason, 0, 0, 0, 0)
  if previous.len > 0:
    warn "autoraid loadout: `force` was asked for, so the " & $previous.len &
         " minted id(s) still recorded for " & profileId &
         " are stripped now, before this apply"
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
        (if gARInListing:
           " | applied INSIDE the tarkov.profile.listing window (cycle " &
           $gARListingCycles & "), so the profile served by this " &
           "/client/game/profile/list carries it and the raid that follows " &
           "this menu cycle spawns with it"
         else:
           " | applied OUTSIDE the tarkov.profile.listing window, so the " &
           "client does NOT see it for the raid it is arming -- it sees it at " &
           "the NEXT /client/game/profile/list. " & ARWireOrder)
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
  # The measured fact, per apply rather than as a constant: an apply honoured
  # inside the `tarkov.profile.listing` window DOES reach the coming raid; one
  # triggered by `tarkov.profile.selected` or `tarkov.raid.configured` does not,
  # because the client has already been handed its profile by then.
  put(o, "loadoutLandsBeforeLastProfileList", gARLastAtListing)
  put(o, "listingCycles", gARListingCycles)
  put(o, "inListingWindow", gARInListing)
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

  # 5. References OUTSIDE the item array go with the items -- and ONLY the
  #    doomed ones. The positive half: a CheckedMagazines key, a fastPanel
  #    value and an InsuredItems entry naming a doomed id are pruned while
  #    their neighbours survive. The negative half: a doomed set that names
  #    nothing present leaves every text byte-identical and counts zero.
  let doomedIds = @["mag00000000000000000000m"]
  var pruned5 = 0
  let cm = arPruneObjectKeys(
    "{\"mag00000000000000000000m\":2,\"keep0000000000000000000k\":1}",
    doomedIds, pruned5)
  if cm.contains("mag00000000000000000000m") or
     not cm.contains("keep0000000000000000000k"):
    into.add "raidloadout: CheckedMagazines prune kept a doomed key or " &
             "dropped an owned one: " & cm
    result = false
  let fp = arPruneObjectValues(
    "{\"4\":\"mag00000000000000000000m\",\"5\":\"keep0000000000000000000k\"}",
    doomedIds, pruned5)
  if fp.contains("mag00000000000000000000m") or
     not fp.contains("keep0000000000000000000k"):
    into.add "raidloadout: fastPanel prune kept a doomed value or dropped " &
             "an owned one: " & fp
    result = false
  let ins = arPruneList(
    "[{\"tid\":\"t\",\"itemId\":\"mag00000000000000000000m\"}," &
    "{\"tid\":\"t\",\"itemId\":\"keep0000000000000000000k\"}]",
    doomedIds, "itemId", pruned5)
  if ins.contains("mag00000000000000000000m") or
     not ins.contains("keep0000000000000000000k"):
    into.add "raidloadout: InsuredItems prune kept a doomed entry or " &
             "dropped an owned one: " & ins
    result = false
  if pruned5 != 3:
    into.add "raidloadout: three references to a doomed id should count 3, " &
             "counted " & $pruned5
    result = false
  var pruned5n = 0
  let cmSame = "{\"keep0000000000000000000k\":1}"
  if arPruneObjectKeys(cmSame, @["nothere0000000000000000n"], pruned5n) != cmSame or
     pruned5n != 0:
    into.add "raidloadout: pruning an absent id changed CheckedMagazines or " &
             "counted a reference"
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

  # 7. THE IDEMPOTENCY DECISION, on its own. An active minted set must refuse a
  #    second mint, `force` must get past it, and no active set must not refuse
  #    -- that third one is the negative control, without which the rule would
  #    be "always refuse" and would pass for the wrong reason.
  if not arRefusesRemint(3, false):
    into.add "raidloadout: an ACTIVE minted set of 3 did not refuse a second " &
             "mint, so two kits could be minted under one recorded set"
    result = false
  if arRefusesRemint(3, true):
    into.add "raidloadout: `force` did not get past the active-set refusal"
    result = false
  if arRefusesRemint(0, false):
    into.add "raidloadout: an EMPTY minted set refused a mint, so case 7 " &
             "proves nothing -- the rule would be `always refuse`"
    result = false

  # 8. THE LISTING WINDOW. An apply honoured inside it must SAY it lands this
  #    cycle, and one outside it must say it does not. Run over the synthetic
  #    profile `aaaaaaaaaaaaaaaaaaaaaaaa`, which does not exist -- the verdict
  #    is INCONCLUSIVE either way and that is not what is being asserted here.
  #    What is asserted is the window bookkeeping, which is what decides whether
  #    the gear reaches the coming raid.
  let cycleBefore = arListingCycle()
  arListingBegin()
  if not gARInListing:
    into.add "raidloadout: arListingBegin did not open the listing window"
    result = false
  let inside = arApply("{\"profileId\":\"aaaaaaaaaaaaaaaaaaaaaaaa\"," &
                       "\"spec\":{\"gear\":[]},\"reason\":\"selfcheck\"}")
  if not field(inside, "landsThisCycle").asBool(false):
    into.add "raidloadout: an apply INSIDE the listing window reported that " &
             "it does not land this cycle"
    result = false
  arListingEnd()
  if gARInListing:
    into.add "raidloadout: arListingEnd did not close the listing window"
    result = false
  let outside = arApply("{\"profileId\":\"aaaaaaaaaaaaaaaaaaaaaaaa\"," &
                        "\"spec\":{\"gear\":[]},\"reason\":\"selfcheck\"}")
  if field(outside, "landsThisCycle").asBool(true):
    into.add "raidloadout: an apply OUTSIDE the listing window claimed it " &
             "lands this cycle -- the status route would then be unable to be " &
             "wrong, which is the defect CLAUDE.md 9b names"
    result = false
  if arListingCycle() != cycleBefore + 1:
    into.add "raidloadout: the listing cycle counter did not advance by one"
    result = false
