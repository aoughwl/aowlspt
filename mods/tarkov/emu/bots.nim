## Bots.
##
## `/client/game/bot/generate` is the client asking for a batch of AI profiles
## before a raid: a role, a difficulty, and how many. What it gets back is a
## profile per bot in the same shape as a player's — id, info, health,
## inventory, skills — because the client makes no distinction. That is the
## whole trick of it: a bot is a profile with `Info.Settings.Role` set.
##
## The database supplies the *content* (`bots.types.<role>`: the appearance,
## loadout tables, health ranges, names) and this supplies the assembly. With no
## bot data present a raid still starts, populated by bots wearing nothing —
## which is a strange raid and a working one, and is a great deal better than a
## client that cannot enter a raid at all.
##
## The one thing done carefully here is **cost**. Generating a batch is the
## largest single body the server builds in a session, and it happens at the
## worst possible moment: the player is staring at a loading screen. So the
## per-bot work is a handful of lookups and one string build, the loadout tables
## are read once per batch rather than once per bot, and nothing here parses the
## item table.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import ids

type
  BotRequest* = object
    role*: string
    difficulty*: string
    count*: int

  BotTables* = object
    ## The database rows for one role, read once and reused for every bot in the
    ## batch. Reading them per bot turns a 20-bot request into 20 walks of the
    ## bot table, which is exactly the kind of cost that only shows up on
    ## someone else's machine.
    ok*: bool
    role*: string
    raw*: string

proc parseRequests*(body: string): seq[BotRequest] =
  ## The client sends `{"conditions":[{"Role":..,"Limit":..,"Difficulty":..}]}`.
  result = @[]
  let conds = each(field(body, "conditions"))
  for c in conds:
    var n = c.field("Limit").asInt(1)
    if n < 1: n = 1
    # A single request asking for hundreds is either a mistake or a client
    # trying it on; capped rather than honoured, because the body it would
    # produce is measured in tens of megabytes.
    if n > 64: n = 64
    result.add BotRequest(role: c.field("Role").asText("assault"),
                          difficulty: c.field("Difficulty").asText("normal"),
                          count: n)

proc loadTables*(role: string): BotTables =
  let v = dbRead("bots.types." & toLowerAscii(role))
  if v.ok and v.raw.len > 0:
    return BotTables(ok: true, role: role, raw: v.raw)
  result = BotTables(ok: false, role: role, raw: "")

proc pickName(t: BotTables; index: int): string =
  ## A name from the role's own list, chosen by position rather than at random.
  ## Deterministic on purpose: when a raid goes wrong, "the third scav" is a
  ## thing that can be looked up.
  if not t.ok:
    return t.role & "_" & $index
  let names = field(t.raw, "firstName")
  let n = count(names)
  if n == 0:
    return t.role & "_" & $index
  result = at(names, index mod n).asText(t.role & "_" & $index)

proc healthOf(t: BotTables): string =
  ## The role's health block, or a full-health human. The client reads every
  ## body part by name, so a missing one is a bot it cannot spawn.
  if t.ok:
    let h = field(t.raw, "health.BodyParts")
    if h.found and isObject(h):
      let first = at(h, 0)
      if first.found:
        return raw(first)
  var parts = obj()
  put(parts, "Head", objOf("Health", raw("{\"Current\":35,\"Maximum\":35}")))
  put(parts, "Chest", objOf("Health", raw("{\"Current\":85,\"Maximum\":85}")))
  put(parts, "Stomach", objOf("Health", raw("{\"Current\":70,\"Maximum\":70}")))
  put(parts, "LeftArm", objOf("Health", raw("{\"Current\":60,\"Maximum\":60}")))
  put(parts, "RightArm", objOf("Health", raw("{\"Current\":60,\"Maximum\":60}")))
  put(parts, "LeftLeg", objOf("Health", raw("{\"Current\":65,\"Maximum\":65}")))
  put(parts, "RightLeg", objOf("Health", raw("{\"Current\":65,\"Maximum\":65}")))
  var health = obj()
  put(health, "Hydration", raw("{\"Current\":100,\"Maximum\":100}"))
  put(health, "Energy", raw("{\"Current\":100,\"Maximum\":100}"))
  put(health, "Temperature", raw("{\"Current\":36,\"Maximum\":40}"))
  put(health, "BodyParts", parts)
  put(health, "UpdateTime", 0)
  result = done(health).text

proc appearanceOf(t: BotTables): JsonObject =
  result = obj()
  var head = "5cc084dd14c02e000b0550a3"
  var body = "5cde95ef7d6c8b04713c4f2d"
  var feet = "5cde95d97d6c8b647a3769b0"
  var hands = "5cc0876314c02e000c6bea6b"
  if t.ok:
    let a = field(t.raw, "appearance")
    if a.found:
      let h = at(a.field("head"), 0)
      if h.found: head = h.asText(head)
      let b = at(a.field("body"), 0)
      if b.found: body = b.asText(body)
      let f = at(a.field("feet"), 0)
      if f.found: feet = f.asText(feet)
      let hd = at(a.field("hands"), 0)
      if hd.found: hands = hd.asText(hands)
  put(result, "Head", head)
  put(result, "Body", body)
  put(result, "Feet", feet)
  put(result, "Hands", hands)

proc generateOne*(t: BotTables; req: BotRequest; index: int): string =
  let id = newId()
  let equipment = newId()
  let stash = newId()

  var settings = obj()
  put(settings, "Role", req.role)
  put(settings, "BotDifficulty", req.difficulty)
  put(settings, "Experience", 0)
  put(settings, "StandingForKill", 0.0)
  put(settings, "AggressorBonus", 0.0)

  var info = obj()
  put(info, "Nickname", pickName(t, index))
  put(info, "Side", if toLowerAscii(req.role) == "pmcbot": "Bear" else: "Savage")
  put(info, "Voice", "Bear_1")
  put(info, "Level", 1)
  put(info, "Experience", 0)
  put(info, "RegistrationDate", 0)
  put(info, "GameVersion", "standard")
  put(info, "AccountType", 0)
  put(info, "MemberCategory", 0)
  put(info, "Settings", settings)
  put(info, "Bans", arr())

  # The two containers a profile must have, even one that is never opened: the
  # client walks `Inventory.items` for the ids named beside it and a bot with a
  # dangling equipment id does not spawn.
  var items = arr()
  var eq = obj()
  put(eq, "_id", equipment)
  put(eq, "_tpl", "55d7217a4bdc2d86028b456d")
  items.add eq
  var st = obj()
  put(st, "_id", stash)
  put(st, "_tpl", "566abbc34bdc2d92178b4576")
  items.add st

  var inventory = obj()
  put(inventory, "items", items)
  put(inventory, "equipment", equipment)
  put(inventory, "stash", stash)
  put(inventory, "questRaidItems", "")
  put(inventory, "questStashItems", "")
  put(inventory, "sortingTable", "")
  put(inventory, "hideoutAreaStashes", obj())
  put(inventory, "fastPanel", obj())
  put(inventory, "favoriteItems", arr())

  var skills = obj()
  put(skills, "Common", arr())
  put(skills, "Mastering", arr())
  put(skills, "Points", 0)

  var p = obj()
  put(p, "_id", id)
  put(p, "aid", accountIdOf(id))
  put(p, "savage", jnull())
  put(p, "Info", info)
  put(p, "Customization", appearanceOf(t))
  put(p, "Health", raw(healthOf(t)))
  put(p, "Inventory", inventory)
  put(p, "Skills", skills)
  put(p, "Stats", objOf("Eft", obj()))
  put(p, "Encyclopedia", obj())
  put(p, "TaskConditionCounters", obj())
  put(p, "InsuredItems", arr())
  put(p, "Bonuses", arr())
  put(p, "Notes", objOf("Notes", arr()))
  put(p, "Quests", arr())
  put(p, "RagfairInfo", obj())
  put(p, "TradersInfo", obj())
  put(p, "UnlockedInfo", objOf("unlockedProductionRecipe", arr()))
  put(p, "WishList", obj())
  result = done(p).text

proc generate*(body: string; generated: var int): string =
  ## The whole batch, as the array the client expects.
  generated = 0
  var out1 = arr()
  let requests = parseRequests(body)
  for req in requests:
    let tables = loadTables(req.role)
    var i = 0
    while i < req.count:
      out1.add raw(generateOne(tables, req, i))
      inc generated
      inc i
  result = done(out1).text
