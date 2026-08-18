## The six members of Black Division, and how they are handed to morebots.
##
## Five of them share one template — the same body, difficulty and loot pools —
## and differ only in the loadout overlaid on top. Wedge has his own. That is
## upstream's `sharedTypes` / `types` split, and it survives the port unchanged
## because it is a good idea: one file to edit when the faction's aim or health
## changes, rather than six that drift.
##
## The role ids are upstream's and are not negotiable. `848420` is the ASCII of
## `TT` with two zeros appended, per MoreBotsAPI's convention for picking a range
## nobody else has claimed; the sixth is `848426` rather than `848425` because
## that is what shipped, and renumbering it would make this port disagree with
## every existing Black Division save and every published compatibility note.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import data

type
  BdType* = object
    name*: string
    id*: int
    scavRole*: string
    display*: string
    description*: string
    templateFile*: string
    configFile*: string
    loadoutFile*: string
    isBossForStats*: bool

const
  BaseBrain* = 9         ## pmcBot — the brain these bots borrow
  SharedTemplate* = "types/blackDiv.json"
  SharedConfig* = "config/blackDiv.json"

proc allTypes*(): seq[BdType] =
  ## In upstream's order, which matters only for the log.
  result = @[
    BdType(name: "blackDivLead", id: 848420, scavRole: "BlackDiv",
           display: "Black Division Lead",
           description: "A team leader of Black Division.",
           templateFile: SharedTemplate, configFile: SharedConfig,
           loadoutFile: "", isBossForStats: false),
    BdType(name: "blackDivAssault", id: 848421, scavRole: "BlackDiv",
           display: "Black Division Assault",
           description: "An assault member of Black Division, using rifles, " &
                        "carbines, and battle rifles.",
           templateFile: SharedTemplate, configFile: SharedConfig,
           loadoutFile: "loadouts/blackdivassault.json", isBossForStats: false),
    BdType(name: "blackDivBreacher", id: 848422, scavRole: "BlackDiv",
           display: "Black Division Breacher",
           description: "A breacher member of Black Division, focusing on " &
                        "close combat.",
           templateFile: SharedTemplate, configFile: SharedConfig,
           loadoutFile: "", isBossForStats: false),
    BdType(name: "blackDivSupport", id: 848423, scavRole: "BlackDiv",
           display: "Black Division Support",
           description: "A support member of Black Division, using heavy " &
                        "weapons to provide suppression.",
           templateFile: SharedTemplate, configFile: SharedConfig,
           loadoutFile: "", isBossForStats: false),
    BdType(name: "bossWedge", id: 848424, scavRole: "Boss",
           display: "Wedge",
           description: "A hyper-lethal leader within Black Division.",
           templateFile: "types/bossWedge.json",
           configFile: "config/bossWedge.json",
           loadoutFile: "loadouts/bosswedge.json", isBossForStats: true),
    BdType(name: "blackDivIb", id: 848426, scavRole: "BlackDiv",
           display: "Black Division Raider",
           description: "A member of Black Division that is a part of a " &
                        "raiding party.",
           templateFile: SharedTemplate, configFile: SharedConfig,
           loadoutFile: "loadouts/blackdivib.json", isBossForStats: false)]

proc typeNames*(): seq[string] =
  result = @[]
  let all = allTypes()
  for t in all:
    result.add t.name

proc registrationFor*(t: BdType; templateJson, configJson: string): string =
  ## One `morebots.type.register` payload.
  ##
  ## `excludedDifficulties` is `[0,2,3]` — easy, hard and impossible removed,
  ## leaving only normal. The template ships all four blocks and they are all
  ## tuned identically, so offering the player a difficulty choice that changes
  ## nothing would be a lie in a settings menu.
  var o = obj()
  put(o, "name", t.name)
  put(o, "id", t.id)
  put(o, "scavRole", t.scavRole)
  put(o, "displayName", t.display)
  put(o, "description", t.description)
  put(o, "section", "Black Division")
  put(o, "baseBrain", BaseBrain)
  # isBoss and isFollower both true: every one of them can lead a squad and
  # every one of them can be in someone else's. That is what makes a mixed
  # Wedge-plus-raiders group legal.
  put(o, "isBoss", true)
  put(o, "isFollower", true)
  put(o, "hostileToAll", false)
  put(o, "countAsBoss", t.isBossForStats)
  put(o, "excludedDifficulties", raw("[0,2,3]"))
  if templateJson.len > 2:
    put(o, "template", raw(templateJson))
  if configJson.len > 2:
    put(o, "config", raw(configJson))
  result = done(o).text

proc overlayFor*(names: seq[string]; patchJson: string): string =
  ## One `morebots.type.overlay` payload: a loadout, or the CS-gas grenade, or
  ## anything else that is a partial bot document.
  var a = arr()
  for n in names:
    a.add n
  var o = obj()
  put(o, "names", a)
  put(o, "patch", raw(patchJson))
  result = done(o).text

proc factionDefinition*(): string =
  ## `blackdiv`: the six of them, and no revenge.
  ##
  ## `revengeAfterRaids` is false, as upstream had it. Black Division does not
  ## hold a grudge across raids — it does not need to, because its bots are
  ## unconditionally hostile to the player already (`DEFAULT_*_BEHAVIOUR` is
  ## `AlwaysEnemies` in the template). Revenge would only make them hostile to
  ## someone they were going to shoot anyway.
  var a = arr()
  let names = typeNames()
  for n in names:
    a.add n
  var o = obj()
  put(o, "name", "blackdiv")
  put(o, "botTypes", a)
  put(o, "subFactions", arr())
  put(o, "revengeAfterRaids", false)
  put(o, "revengeRaidAmount", 3)
  result = done(o).text

proc relationTypesToward*(faction: string): string =
  ## "Black Division is hostile to <faction>."
  var a = arr()
  let names = typeNames()
  for n in names:
    a.add n
  var o = obj()
  put(o, "kind", "enemy")
  put(o, "types", a)
  put(o, "toward", faction)
  result = done(o).text

proc relationFactionTowardBd*(faction: string): string =
  ## "...and <faction> is hostile to Black Division."
  ##
  ## The other direction, and it has to be asked for separately: an enemy list
  ## is one bot's opinion, not a relationship. Upstream made exactly this pair
  ## of calls for each faction and it is worth keeping the symmetry visible.
  var o = obj()
  put(o, "kind", "enemy")
  put(o, "fromFaction", faction)
  put(o, "toward", "blackdiv")
  result = done(o).text

proc relationRevengeOwn*(): string =
  ## Black Division avenges its own dead: a bot that watches a squadmate die
  ## goes looking for whoever did it.
  var a = arr()
  let names = typeNames()
  for n in names:
    a.add n
  var o = obj()
  put(o, "kind", "revenge")
  put(o, "types", a)
  put(o, "toward", "blackdiv")
  result = done(o).text
