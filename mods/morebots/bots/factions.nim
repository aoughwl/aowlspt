## Factions: who a bot counts as one of us, and who it shoots on sight.
##
## A faction is a name and a set of roles, and factions nest — `savage` is the
## scavs plus the scav bosses plus the smugglers plus the bloodhounds plus the
## raiders, and a mod that wants to be hostile to all of that should say
## "savage" once rather than list thirty roles.
##
## The output of all this is unglamorous: four arrays inside every difficulty
## block of every bot type document.
##
##     bots.types.<key>.difficulty.<easy|normal|hard|impossible>.Mind
##         ENEMY_BOT_TYPES     [ints]
##         FRIENDLY_BOT_TYPES  [ints]
##         WARN_BOT_TYPES      [ints]
##         REVENGE_BOT_TYPES   [ints]
##
## Two things that are easy to get wrong and are handled here:
##
## **Hostility is not symmetric.** Adding the scavs to Black Division's enemy
## list makes Black Division shoot scavs; it does nothing to what the scavs
## think. Both directions have to be asked for, and the event carries a
## direction for exactly that reason.
##
## **The lists are arrays, and `dbWrite` replaces an array rather than
## appending to one.** So every relation is read-modify-write, and duplicates
## are filtered on the way in. Upstream used `AddRange` and grew the same id
## four times over across repeated loads; here a relation applied twice is the
## same as applied once, which is what makes the register-twice handshake in
## ../morebots.nim safe.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import spawntypes
import registry
import dbpath

type
  Faction* = object
    name*: string
    botTypes*: seq[string]     ## role names, vanilla or custom
    subFactions*: seq[string]  ## other faction names
    revengeAfterRaids*: bool
    revengeRaidAmount*: int

var gFactions: seq[Faction] = @[]

const
  Difficulties* = ["easy", "normal", "hard", "impossible"]

proc factionIndex*(name: string): int =
  result = -1
  for i in 0 ..< gFactions.len:
    if gFactions[i].name == name:
      return i

proc factionCount*(): int = gFactions.len

proc defineFaction*(f: Faction) =
  let i = factionIndex(f.name)
  if i >= 0:
    gFactions[i] = f
  else:
    gFactions.add f

proc simple(name: string; members: seq[string]): Faction =
  Faction(name: name, botTypes: members, subFactions: @[],
          revengeAfterRaids: false, revengeRaidAmount: 3)

proc umbrella(name: string; subs: seq[string]): Faction =
  Faction(name: name, botTypes: @[], subFactions: subs,
          revengeAfterRaids: false, revengeRaidAmount: 3)

proc loadDefaultFactions*() =
  ## The vanilla grouping, as the original had it. Worth keeping verbatim: mods
  ## are written against these names, and renaming `killaTagilla` because the
  ## casing is odd would break every mod that says `killaTagilla`.
  defineFaction simple("raiders", @["pmcBot"])
  defineFaction simple("rogues",
    @["exUsec", "bossKnight", "followerBigPipe", "followerBirdEye"])
  defineFaction simple("smugglers", @["arenaFighterEvent"])
  defineFaction simple("bloodhounds", @["arenaFighter"])
  defineFaction simple("scavs",
    @["assault", "assaultGroup", "cursedAssault", "marksman",
      "crazyAssaultEvent", "spiritSpring", "spiritWinter", "skier",
      "peacemaker"])
  defineFaction simple("cultists",
    @["sectantWarrior", "sectantPriest", "sectantOni", "sectantPrizrak",
      "sectantPredvestnik", "bossZryachiy", "followerZryachiy",
      "peacefullZryachiyEvent", "ravangeZryachiyEvent", "sectactPriestEvent"])
  defineFaction simple("infected",
    @["infectedAssault", "infectedCivil", "infectedLaborant", "infectedPmc",
      "infectedTagilla"])
  defineFaction simple("usec", @["pmcUSEC"])
  defineFaction simple("bear", @["pmcBEAR"])
  defineFaction umbrella("pmcs", @["usec", "bear"])
  defineFaction simple("killaTagilla",
    @["bossKilla", "bossTagilla", "followerTagilla", "bossTagillaAgro",
      "tagillaHelperAgro", "bossKillaAgro"])
  defineFaction simple("kabanKolontay",
    @["bossBoar", "bossBoarSniper", "followerBoar", "followerBoarClose1",
      "followerBoarClose2", "bossKolontay", "followerKolontayAssault",
      "followerKolontaySecurity"])
  defineFaction simple("reshala", @["bossBully", "followerBully"])
  defineFaction simple("shturman", @["bossKojaniy", "followerKojaniy"])
  defineFaction simple("gluhar",
    @["bossGluhar", "followerGluharAssault", "followerGluharSnipe",
      "followerGluharSecurity", "followerGluharScout"])
  defineFaction simple("sanitar", @["bossSanitar", "followerSanitar"])
  defineFaction simple("partisan", @["bossPartisan"])
  defineFaction simple("misc", @["shooterBTR", "gifter"])
  defineFaction umbrella("scavbosses",
    @["killaTagilla", "kabanKolontay", "reshala", "shturman", "gluhar",
      "sanitar"])
  defineFaction umbrella("criminals", @["scavs", "scavbosses"])
  defineFaction umbrella("savage",
    @["scavs", "scavbosses", "smugglers", "bloodhounds", "raiders"])

# ---------------------------------------------------------------------------
# Flattening
# ---------------------------------------------------------------------------

proc addUnique(s: var seq[string]; v: string) =
  for x in s:
    if x == v:
      return
  s.add v

proc allRoleNames*(factionName: string): seq[string] =
  ## Every role in a faction and in everything under it, once each.
  ##
  ## Iterative with an explicit worklist rather than recursive, and a `seen`
  ## list rather than none: `savage` contains `scavbosses` which contains six
  ## factions, and a mod is free to define a cycle. A cycle here would be a
  ## hang at load with no message, which is the worst possible way to report a
  ## typo in a config file.
  result = @[]
  var pending: seq[string] = @[]
  var seen: seq[string] = @[]
  pending.add factionName
  while pending.len > 0:
    let name = pending[pending.len - 1]
    shrink(pending, pending.len - 1)
    var already = false
    for s in seen:
      if s == name:
        already = true
    if already:
      continue
    seen.add name
    let i = factionIndex(name)
    if i < 0:
      warn "morebots: no such faction '" & name & "'"
      continue
    for t in gFactions[i].botTypes:
      addUnique(result, t)
    for sub in gFactions[i].subFactions:
      pending.add sub

proc allRoleIds*(factionName: string): seq[int] =
  ## The same, as the integers the difficulty document actually holds. A name
  ## with no known id is dropped with a warning: writing a wrong number into
  ## `ENEMY_BOT_TYPES` makes some unrelated bot hostile, and that is far harder
  ## to trace back than a line in the log.
  result = @[]
  let names = allRoleNames(factionName)
  for n in names:
    let id = roleId(n)
    if id < 0:
      warn "morebots: role '" & n & "' in faction '" & factionName &
           "' has no id on this build; it will not be counted"
      continue
    var already = false
    for x in result:
      if x == id:
        already = true
    if not already:
      result.add id

# ---------------------------------------------------------------------------
# Writing the relation
# ---------------------------------------------------------------------------

proc mindKey*(kind: string): string =
  case kind
  of "enemy": "ENEMY_BOT_TYPES"
  of "friendly": "FRIENDLY_BOT_TYPES"
  of "warn": "WARN_BOT_TYPES"
  of "revenge": "REVENGE_BOT_TYPES"
  else: ""

proc mergeIds(existingRaw: string; add1: seq[int]): string =
  ## The union, as a JSON array, existing order first. Order is not meaningful
  ## to the game but a stable one makes two runs diffable.
  var out1 = arr()
  var have: seq[int] = @[]
  if existingRaw.len > 0:
    let items = each(whole(existingRaw))
    for it in items:
      let v = it.asInt(-1)
      if v < 0:
        continue
      var dup = false
      for h in have:
        if h == v:
          dup = true
      if dup:
        continue
      have.add v
      out1.add v
  for v in add1:
    var dup = false
    for h in have:
      if h == v:
        dup = true
    if dup:
      continue
    have.add v
    out1.add v
  result = done(out1).text

proc relateOne*(targetKey, kind: string; ids: seq[int]): bool =
  ## One bot type, all four difficulties.
  let listName = mindKey(kind)
  if listName.len == 0:
    error "morebots: unknown relation kind '" & kind & "'"
    return false
  if not botTypeExists(targetKey):
    # Silent here, counted by the caller, reported once. `fromFaction: "savage"`
    # names thirty-seven roles, and a server whose database has no bot tables is
    # an ordinary state, not thirty-seven faults — and `debug` would not help,
    # because the backend's logger folds trace and debug into info.
    return false
  result = true
  # One patch for all four difficulty blocks rather than four.
  #
  # The four writes were four buffered changes, four ancestor scans and four
  # merges into the same `bots.types.<key>` document -- and `fromFaction:
  # "savage"` names thirty-seven roles, so one relation was a hundred and
  # forty-eight of them. Reading each block separately is still required (the
  # four are allowed to differ, and on a stock database some do), but the
  # *write* is one object, which is what the four merges were rebuilding
  # anyway.
  var patch = obj()
  for d in Difficulties:
    let path = "bots.types." & targetKey & ".difficulty." & d & ".Mind." &
               listName
    let cur = dbView(path)
    var existing = ""
    if cur.ok:
      existing = cur.raw
    var mind = obj()
    put(mind, listName, raw(mergeIds(existing, ids)))
    var block1 = obj()
    put(block1, "Mind", mind)
    put(patch, d, block1)
  if not dbPut("bots.types." & targetKey & ".difficulty", done(patch).text):
    warn "morebots: could not write bots.types." & targetKey & ".difficulty"
    result = false

proc relate*(payload: string): int =
  ## One `morebots.faction.relate` event. Returns how many bot types it edited.
  ##
  ##     {"kind": "enemy",
  ##      "types": ["blackDivAssault", ...],   # or "fromFaction": "savage"
  ##      "toward": "blackdiv"}
  ##
  ## `types` names the bots whose opinion changes; `toward` names the faction
  ## they get the opinion *about*. `fromFaction` is the same thing spelled with
  ## a faction name, which is how a mod makes the whole of `savage` hostile to
  ## it without listing the scavs.
  result = 0
  let doc = whole(payload)
  let kind = field(doc, "kind").asText("enemy")
  let toward = field(doc, "toward").asText("")
  if toward.len == 0:
    error "morebots: a relation arrived with no 'toward' faction"
    return
  if factionIndex(toward) < 0:
    # `optional: true` means "this faction belongs to a mod that may not be
    # installed". Warning about it on every default install teaches the reader
    # to skim warnings, which is the cost that matters -- and there is nothing
    # for them to fix. Named at info, with the consequence, rather than
    # silenced: a relation that did not happen is still a fact.
    if field(doc, "optional").asBool(false):
      info "morebots: relation toward '" & toward & "' was marked optional " &
           "and no mod has defined that faction, so it was not applied. " &
           "Nothing is broken; those bots simply have no opinion of each " &
           "other. Install the mod that defines '" & toward & "', or turn " &
           "the switch off in the asking mod's config.json to stop seeing this."
    else:
      warn "morebots: relation toward unknown faction '" & toward &
           "'. Nothing was written, so the bots that were meant to become " &
           "hostile will ignore each other. Either the faction has not been " &
           "defined yet (morebots.faction.define arrives before " &
           "morebots.faction.relate) or the name is a typo."
    return
  let ids = allRoleIds(toward)
  if ids.len == 0:
    warn "morebots: faction '" & toward & "' resolved to no roles"
    return

  var targets: seq[string] = @[]
  let fromFaction = field(doc, "fromFaction").asText("")
  if fromFaction.len > 0:
    targets = allRoleNames(fromFaction)
  else:
    let listed = each(field(doc, "types"))
    for t in listed:
      targets.add t.asText("")

  var missing: seq[string] = @[]
  for t in targets:
    if t.len == 0:
      continue
    if relateOne(lower(t), kind, ids):
      inc result
    else:
      missing.add t
  if missing.len > 0:
    # Named, because a count is not something a reader can check. On the real
    # 39 MiB import the four are `assaultGroup`, `followerTagilla`,
    # `followerGluharSnipe` and `arenaFighter` -- all four are genuine
    # `WildSpawnType` members, and none of them has a document under
    # `bots.types`. That is a database with no template for a role rather than
    # a typo in the faction table, and the difference is exactly what naming
    # them lets somebody establish.
    var names = missing[0]
    for i in 1 ..< missing.len:
      names = names & ", " & missing[i]
    warn "morebots: " & kind & " toward '" & toward & "' skipped " &
         $missing.len & " of " & $targets.len & " bot type(s) with no " &
         "document under bots.types -- " & names & ". They are real " &
         "WildSpawnType roles; this database simply carries no template for " &
         "them, so there is nothing to write the opinion into and any bot of " &
         "that role will ignore '" & toward & "'."

proc define*(payload: string): bool =
  ## One `morebots.faction.define` event.
  let doc = whole(payload)
  let name = field(doc, "name").asText("")
  if name.len == 0:
    error "morebots: a faction definition arrived without a name"
    return false
  var f = Faction(name: name, botTypes: @[], subFactions: @[],
                  revengeAfterRaids: field(doc, "revengeAfterRaids").asBool(false),
                  revengeRaidAmount: field(doc, "revengeRaidAmount").asInt(3))
  let bt = each(field(doc, "botTypes"))
  for t in bt:
    addUnique(f.botTypes, t.asText(""))
  let sf = each(field(doc, "subFactions"))
  for s in sf:
    addUnique(f.subFactions, s.asText(""))
  defineFaction f
  result = true

proc factionsJson*(): string =
  ## `/morebotsapi/getfactions`. Roles are reported as both names and ids: the
  ## name is what a mod author wrote and the id is what the game uses, and a
  ## reader that has only one of them cannot check the other.
  var o = obj()
  for i in 0 ..< gFactions.len:
    let f = gFactions[i]
    var names = arr()
    for n in f.botTypes:
      names.add n
    var subs = arr()
    for s in f.subFactions:
      subs.add s
    var ids = arr()
    let flat = allRoleIds(f.name)
    for v in flat:
      ids.add v
    var e = obj()
    put(e, "Name", f.name)
    put(e, "BotTypes", names)
    put(e, "SubFactions", subs)
    put(e, "AllRoleIds", ids)
    put(e, "RevengeAfterRaids", f.revengeAfterRaids)
    put(e, "RevengeRaidAmount", f.revengeRaidAmount)
    put(o, f.name, e)
  result = done(o).text

proc revengeAmountOf*(factionName: string): int =
  let i = factionIndex(factionName)
  if i < 0:
    return 0
  result = gFactions[i].revengeRaidAmount
