## The hideout: areas, and the levels the player has built them to.
##
## The profile carries one entry per area — its type, its level, whether it is
## running — and the database carries what each level costs and produces. As
## everywhere else here, the state is the profile's and the content is the
## database's, so a server with no hideout data still tracks a hideout: the
## player can upgrade areas the server knows nothing about, and the client draws
## them from its own bundles.
##
## Upgrades are two steps, and it matters that they are. `HideoutUpgrade` starts
## one and takes the materials; `HideoutUpgradeComplete` raises the level when
## the timer has run. Collapsing them into one would give a player the level the
## moment they clicked, which is the difference between a hideout and a menu.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json

type
  HideoutAction* = enum
    haNone, haUpgrade, haUpgradeComplete, haToggleArea, haPutItems, haTakeItems

proc hideoutAction*(name: string): HideoutAction =
  case name
  of "HideoutUpgrade": haUpgrade
  of "HideoutUpgradeComplete": haUpgradeComplete
  of "HideoutToggleArea": haToggleArea
  of "HideoutPutItemsInAreaSlots": haPutItems
  of "HideoutTakeItemsFromAreaSlots": haTakeItems
  else: haNone

proc findArea(list: List; areaType: int): int =
  result = -1
  for i in 0 ..< list.len:
    if field(list.items[i], "type").asInt(-1) == areaType:
      return i

proc newArea(areaType: int): Doc =
  result = newDoc()
  setNumber(result, "type", areaType)
  setNumber(result, "level", 0)
  setBool(result, "active", true)
  setBool(result, "passiveBonusesEnabled", true)
  setNumber(result, "completeTime", 0)
  setBool(result, "constructing", false)
  setRaw(result, "slots", "[]")
  setNumber(result, "lastRecipe", 0)

proc upgradeSeconds*(areaType, level: int): int =
  ## How long the next level takes, out of the database. Zero when it is not
  ## there -- an upgrade with no known duration completes immediately, which is
  ## a server with no data being permissive rather than a player being stuck.
  let areas = dbRead("hideout.areas")
  if not areas.ok:
    return 0
  let list = each(whole(areas.raw))
  for a in list:
    if a.field("type").asInt(-1) != areaType:
      continue
    let stages = a.field("stages." & $level)
    if stages.found:
      return stages.field("constructionTime").asInt(0)
  result = 0

proc applyHideout*(areasJson: string; action: HideoutAction; body: JsonRef;
                   nowSeconds: int; problem: var string): string =
  ## Returns the new `Hideout.Areas` array.
  problem = ""
  var list = parseArray(areasJson)
  if not list.ok:
    list = newList()
  let areaType = body.field("areaType").asInt(-1)
  if areaType < 0:
    problem = "that hideout action names no area"
    return areasJson

  var at = findArea(list, areaType)
  if at < 0:
    list.add newArea(areaType)
    at = list.len - 1

  var d = parseObject(list.items[at])
  case action
  of haUpgrade:
    let level = get(d, "level").asInt(0)
    let seconds = upgradeSeconds(areaType, level + 1)
    setBool(d, "constructing", true)
    setNumber(d, "completeTime", nowSeconds + seconds)
  of haUpgradeComplete:
    if not get(d, "constructing").asBool(false):
      # Refused rather than granted. A complete without a start is either a
      # replayed request or a client out of step, and granting it is a free
      # level either way.
      problem = "that area is not being upgraded"
      return areasJson
    setNumber(d, "level", get(d, "level").asInt(0) + 1)
    setBool(d, "constructing", false)
    setNumber(d, "completeTime", 0)
  of haToggleArea:
    setBool(d, "active", body.field("enabled").asBool(true))
  of haPutItems, haTakeItems:
    # The items themselves move through the ordinary inventory actions the
    # client sends alongside; what changes here is only which slots are filled.
    let slots = body.field("items")
    if slots.found:
      setRaw(d, "slots", raw(slots))
  of haNone:
    problem = "not a hideout action"
    return areasJson
  list.replaceAt(at, text(d))
  result = text(list)
