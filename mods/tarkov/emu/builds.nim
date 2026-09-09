## Saved builds: weapon presets, equipment loadouts and magazine templates.
##
## The client reads all three from one route at the menu — `/client/builds/list`
## — and that route used to answer `{}`. Which is worse than a 404: `UserBuilds`
## in the reference is three **lists**, `equipmentBuilds`, `weaponBuilds` and
## `magazineBuilds`, and a body with none of them present gives the presets
## screen three nulls to index. The failure lands later and somewhere else, on a
## screen that has nothing to do with the request that caused it.
##
## So the shape is always all three lists, even when every one of them is empty.
##
## ## Why these live beside the profile rather than in it
##
## A build is not part of the character. `/client/match/local/end` hands back
## the whole profile document as the *client* has it, and this server takes that
## document as the new profile — which is the right thing to do for health and
## the stash and is exactly the wrong thing for a list the client did not touch.
## Builds kept inside the profile would be whatever the raid's copy of them
## happened to be. Kept under their own store key, they are the server's.
##
## A build's `Items` are copies, not references: the player saves a preset off a
## rifle and then sells the rifle, and the preset has to survive that. Nothing
## here looks the ids up in the inventory, on purpose.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import store
import ids
import post1

const
  KeyPrefix* = "builds."

  ## The client will not draw more than a screenful and a player cannot
  ## meaningfully use hundreds. The bound is what stops a stuck client from
  ## growing the store without limit -- the same reasoning as the mailbox's.
  MaxPerKind* = 64

proc buildsKey*(profileId: string): string = KeyPrefix & profileId

proc emptyBuilds(): Doc =
  result = newDoc()
  setRaw(result, "equipmentBuilds", "[]")
  setRaw(result, "weaponBuilds", "[]")
  setRaw(result, "magazineBuilds", "[]")

proc loadBuilds*(profileId: string; usable: var bool): Doc =
  ## The three lists, and whether the key could be read. An unreadable key
  ## answered as "no builds" is every saved loadout deleted by the next save --
  ## see `emu/store`.
  let raw1 = readKey(buildsKey(profileId), usable)
  if raw1.len == 0:
    return emptyBuilds()
  result = parseObject(raw1)
  if not result.ok:
    return emptyBuilds()
  # A key written by an older build of this mod may be missing one of the three.
  # Filled in here rather than at the route, so every reader gets the whole
  # shape.
  if not has(result, "equipmentBuilds"): setRaw(result, "equipmentBuilds", "[]")
  if not has(result, "weaponBuilds"): setRaw(result, "weaponBuilds", "[]")
  if not has(result, "magazineBuilds"): setRaw(result, "magazineBuilds", "[]")

proc loadBuilds*(profileId: string): Doc =
  ## For the list route, which writes nothing.
  var usable = true
  result = loadBuilds(profileId, usable)

proc saveBuilds*(profileId: string; d: Doc): bool =
  result = save(buildsKey(profileId), text(d)) == Ok

proc listOf(d: Doc; kind: string): List =
  result = parseArray(getRaw(d, kind))
  if not result.ok:
    result = newList()

proc containsId(list: List; id: string): bool =
  for i in 0 ..< list.len:
    if field(list.items[i], "Id").asText("") == id:
      return true
  result = false

proc defaultEquipmentBuilds*(): List =
  ## The twelve stock loadouts the real backend ships with every profile --
  ## Papasha, Hunter, Shotgunner, Scout, Fighter, Guard, Gunslinger,
  ## Sharpshooter, Operator, Marksman, Raider, Robber -- each
  ## `BuildType: "Standard"`. Lifted verbatim from capture seq 123/253 (the
  ## same twelve appear again in 441 alongside a player's own `Custom`), so
  ## this is the backend's own data rather than an invention.
  ##
  ## They are NOT stored under the profile's builds key. A stock preset the
  ## player never saved must not become a row the player can delete, and must
  ## not be written back by the next save; it is a constant of the install.
  result = parseArray(post1Table("defaultequipmentpresets"))
  if not result.ok:
    result = newList()

proc withDefaultEquipment*(all: var Doc) =
  ## Merges the stock loadouts into `equipmentBuilds`, after the player's own.
  ##
  ## ## Why an empty list is not a valid answer
  ##
  ## `EquipmentBuildsScreen.Show` calls `System.Linq.Enumerable.First` on this
  ## list. With zero entries that throws `InvalidOperationException: Sequence
  ## contains no elements` *during* `Show`, so the screen opens and closes in
  ## the same frame -- the client logs `_buildList empty` from
  ## `UpdateBuildList()` immediately before it. Measured live, client
  ## `errors_000.log`, 2026-08-28 14:06:45.
  ##
  ## The response was well-formed, correctly typed and complete on every key
  ## the audit checks. It was empty, and empty is what broke it.
  let defaults = defaultEquipmentBuilds()
  if defaults.len == 0:
    return
  var eq = listOf(all, "equipmentBuilds")
  for i in 0 ..< defaults.len:
    let id = field(defaults.items[i], "Id").asText("")
    # A saved build carrying a stock id wins: it is the player's edit of it.
    if id.len > 0 and not containsId(eq, id):
      eq.add defaults.items[i]
  setRaw(all, "equipmentBuilds", text(eq))

proc buildsJson*(profileId: string): string =
  ## The body `/client/builds/list` answers with.
  var all = loadBuilds(profileId)
  withDefaultEquipment(all)
  result = text(all)

proc replaceOrAdd(list: var List; id, entry: string): bool =
  ## Saving a build under a name that already exists replaces it rather than
  ## adding a second one -- which is what the client's own dialog offers, and
  ## what makes re-saving a preset after tweaking it not leave two.
  for i in 0 ..< list.len:
    if field(list.items[i], "Id").asText("") == id:
      list.replaceAt(i, entry)
      return true
  if list.len >= MaxPerKind:
    return false
  list.add entry
  result = true

proc saveBuild*(profileId, kind, body: string; problem: var string): string =
  ## Stores one build and returns its id, or "" with `problem` set.
  ##
  ## `kind` is one of the three list names. The id is the request's when it has
  ## one -- the client re-saves an existing preset by sending it back with its
  ## own id -- and a fresh one when it does not.
  problem = ""
  let name = field(body, "Name").asText(field(body, "name").asText(""))
  if name.len == 0:
    problem = "a build needs a name"
    return ""
  var id = field(body, "Id").asText(field(body, "id").asText(""))
  if id.len == 0:
    id = newId()

  var entry = newDoc()
  setText(entry, "Id", id)
  setText(entry, "Name", name)
  # `type` is a discriminator the client reads on every build to route it to the
  # right list on the loadout screen (capture seq 441): "weapon"/"equipment"/
  # "magazine". A build without it is dropped from the screen it belongs on.
  setText(entry, "type",
    (if kind == "weaponBuilds": "weapon"
     elif kind == "equipmentBuilds": "equipment"
     else: "magazine"))
  let root = field(body, "Root").asText(field(body, "root").asText(""))
  if root.len > 0:
    setText(entry, "Root", root)
  let items = field(body, "Items")
  if items.found and isArray(items):
    setRaw(entry, "Items", items.raw())
  elif field(body, "items").found:
    setRaw(entry, "Items", field(body, "items").raw())
  else:
    setRaw(entry, "Items", "[]")
  if kind == "magazineBuilds":
    # `SetMagazineRequest` carries these three and nothing here interprets them
    # -- they are the client's own description of how the magazine is filled,
    # stored and handed back.
    setText(entry, "Caliber", field(body, "Caliber").asText(
      field(body, "caliber").asText("")))
    setNumber(entry, "TopCount", field(body, "TopCount").asInt(
      field(body, "topCount").asInt(0)))
    setNumber(entry, "BottomCount", field(body, "BottomCount").asInt(
      field(body, "bottomCount").asInt(0)))
  if kind == "equipmentBuilds":
    # `EquipmentBuild.BuildType`, one of `Custom`, `Standard`, `Storage`. The
    # client's own save dialog only ever produces `Custom`; the value is taken
    # from the request when it sends one rather than being decided here.
    let t = field(body, "BuildType").asText(
      field(body, "buildType").asText("Custom"))
    setText(entry, "BuildType", t)

  var usable = true
  var all = loadBuilds(profileId, usable)
  if not usable:
    problem = "the saved builds could not be read; refusing to replace them"
    return ""
  var list = listOf(all, kind)
  if not replaceOrAdd(list, id, text(entry)):
    problem = "there is no room for another build"
    return ""
  setRaw(all, kind, text(list))
  if not saveBuilds(profileId, all):
    problem = "could not save the build"
    return ""
  result = id

proc removeBuild*(profileId, id: string): bool =
  ## Deletes by id from whichever of the three lists holds it. Returns whether
  ## anything was actually removed -- a delete of something that is not there is
  ## a client out of step, and answering "done" to it hides that.
  if id.len == 0:
    return false
  var usable = true
  var all = loadBuilds(profileId, usable)
  if not usable:
    return false
  var removedAny = false
  let kinds = @["equipmentBuilds", "weaponBuilds", "magazineBuilds"]
  for kind in kinds:
    var list = listOf(all, kind)
    var here = false
    var i = 0
    while i < list.len:
      if field(list.items[i], "Id").asText("") == id:
        list.removeAt(i)
        here = true
      else:
        inc i
    if here:
      setRaw(all, kind, text(list))
      removedAny = true
  if not removedAny:
    return false
  result = saveBuilds(profileId, all)
