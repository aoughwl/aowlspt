## Profiles: creating them, keeping them, handing them back.
##
## A profile is the whole of a player's persistent state — character, stash,
## skills, quests, traders, hideout — and the client asks for all of it in one
## body at `/client/game/start`. Everything else the emulator does is a read or
## an edit of this document.
##
## It is held **as JSON text**, and edited through `aowlspt/json` plus the
## builders in `aowlspt/server`. There is no profile *object*.
##
## That is a deliberate choice and worth defending, because the obvious design
## is a nimony type per section. The client's profile has several hundred fields
## across a dozen nested sections, most of which this emulator neither reads nor
## understands, and it must hand every one of them back unchanged. A typed model
## would have to name all of them to avoid dropping any — and the day the client
## adds a field, a typed model silently deletes it from every saved profile it
## touches. Text plus a merge keeps what it does not know about.
##
## Persistence is `save`/`load` from `aowlspt/server`, keyed `profile.<id>`, so
## the host owns where profiles live and the emulator does not know.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import ids

const
  KeyPrefix* = "profile."

  ## The stash a starting profile gets. `5811ce572459770cba1a34ea` is the
  ## standard-edition 10x28 stash in the live templates; if the loaded database
  ## has it, its grid is used, and if not the profile still works with a stash
  ## the client sizes from its own bundle.
  StandardStash* = "5811ce572459770cba1a34ea"

  ## Roubles. The client knows this template from its own bundles, so a starting
  ## stack works with or without an item database loaded.
  Roubles* = "5449016a4bdc2d6f028b456f"

type
  Profile* = object
    ## A loaded profile. `text` is the whole document; `id` is cached because
    ## every route needs it and rescanning for it per request is waste.
    id*: string
    text*: string
    ok*: bool

proc profileKey*(id: string): string = KeyPrefix & id

# ---------------------------------------------------------------------------
# Reading
# ---------------------------------------------------------------------------

proc field*(p: Profile; path: string): JsonRef =
  ## A dotted path into the profile: `"Info.Nickname"`, `"Inventory.stash"`.
  result = field(p.text, path)

proc nickname*(p: Profile): string = p.field("Info.Nickname").asText("")
proc side*(p: Profile): string = p.field("Info.Side").asText("Usec")
proc level*(p: Profile): int = p.field("Info.Level").asInt(1)
proc experience*(p: Profile): int = p.field("Info.Experience").asInt(0)
proc stashId*(p: Profile): string = p.field("Inventory.stash").asText("")
proc scavId*(p: Profile): string = p.field("savage").asText("")

# ---------------------------------------------------------------------------
# Building a new one
# ---------------------------------------------------------------------------

proc healthPart(current, maximum: int): JsonObject =
  var h = obj()
  put(h, "Current", current)
  put(h, "Maximum", maximum)
  result = h

proc bodyParts(): JsonObject =
  ## The eleven hit zones, at full health. The names are the client's own and
  ## are not negotiable: a missing zone is a character the client cannot render.
  var parts = obj()
  put(parts, "Head", objOf("Health", healthPart(35, 35)))
  put(parts, "Chest", objOf("Health", healthPart(85, 85)))
  put(parts, "Stomach", objOf("Health", healthPart(70, 70)))
  put(parts, "LeftArm", objOf("Health", healthPart(60, 60)))
  put(parts, "RightArm", objOf("Health", healthPart(60, 60)))
  put(parts, "LeftLeg", objOf("Health", healthPart(65, 65)))
  put(parts, "RightLeg", objOf("Health", healthPart(65, 65)))
  result = parts

proc newProfileText*(id, nickname, sideName, edition: string;
                     nowSeconds: int; startingRoubles: int = 500000): string =
  ## A complete, valid starting profile.
  ##
  ## Synthesised rather than copied out of the database, because the database a
  ## server is started with may be anything — a full live dump, or the small
  ## fixture the tests use. A profile that only exists when a 40MB template
  ## table is present is a profile that cannot be tested.
  let stash = newId()
  let equipment = newId()
  let questRaid = newId()
  let questStash = newId()
  let sorting = newId()
  let scav = newId()

  var info = obj()
  put(info, "Nickname", nickname)
  put(info, "LowerNickname", toLowerAscii(nickname))
  put(info, "Side", sideName)
  put(info, "Voice", if sideName == "Bear": "Bear_1" else: "Usec_1")
  put(info, "Level", 1)
  put(info, "Experience", 0)
  put(info, "RegistrationDate", nowSeconds)
  put(info, "GameVersion", edition)
  put(info, "AccountType", 0)
  put(info, "MemberCategory", 0)
  put(info, "SelectedMemberCategory", 0)
  put(info, "lockedMoveCommands", false)
  put(info, "SavageLockTime", 0)
  put(info, "LastTimePlayedAsSavage", 0)
  put(info, "BannedState", false)
  put(info, "BannedUntil", 0)
  put(info, "IsStreamerModeAvailable", false)
  put(info, "NicknameChangeDate", 0)
  var settings = obj()
  put(settings, "Role", "assault")
  put(settings, "BotDifficulty", "normal")
  put(settings, "Experience", 0)
  put(settings, "StandingForKill", 0.0)
  put(settings, "AggressorBonus", 0.0)
  put(info, "Settings", settings)
  var bans = arr()
  put(info, "Bans", bans)

  var customization = obj()
  # The default heads and bodies. The client resolves these against its own
  # bundles, so a wrong id is a missing model rather than a crash.
  put(customization, "Head", "5cc084dd14c02e000b0550a3")
  put(customization, "Body", if sideName == "Bear": "5cde95d97d6c8b647a3769b0"
                             else: "5cde95ef7d6c8b04713c4f2d")
  put(customization, "Feet", if sideName == "Bear": "5cde95fa7d6c8b04737c2d13"
                             else: "5cde95d97d6c8b647a3769b0")
  put(customization, "Hands", "5cc0876314c02e000c6bea6b")
  put(customization, "DogTag", "59f32c3b86f77472a31742f0")

  var health = obj()
  put(health, "Hydration", healthPart(100, 100))
  put(health, "Energy", healthPart(100, 100))
  put(health, "Temperature", healthPart(36, 40))
  put(health, "BodyParts", bodyParts())
  put(health, "UpdateTime", nowSeconds)
  put(health, "Immortal", false)

  # The four container items every profile must have. The client walks
  # `Inventory.items` looking for the ids named beside it, and a stash id that
  # is not in `items` is an empty inventory screen with no error.
  var items = arr()
  var equipItem = obj()
  put(equipItem, "_id", equipment)
  put(equipItem, "_tpl", "55d7217a4bdc2d86028b456d")
  items.add equipItem
  var stashItem = obj()
  put(stashItem, "_id", stash)
  put(stashItem, "_tpl", StandardStash)
  items.add stashItem
  var qrItem = obj()
  put(qrItem, "_id", questRaid)
  put(qrItem, "_tpl", "5963866286f7747bf429b572")
  items.add qrItem
  var qsItem = obj()
  put(qsItem, "_id", questStash)
  put(qsItem, "_tpl", "5963866b86f7747bfa1c4462")
  items.add qsItem
  var sortItem = obj()
  put(sortItem, "_id", sorting)
  put(sortItem, "_tpl", "602543c13fee350cd564d032")
  items.add sortItem

  # A starting stack of roubles in the stash.
  #
  # Not decoration: it is the first item a new profile has that is *not* a
  # container, which makes every inventory operation -- move, split, merge,
  # examine -- reachable from a fresh install. A profile whose only items are
  # the five containers cannot exercise any of them.
  var money = obj()
  put(money, "_id", newId())
  put(money, "_tpl", Roubles)
  put(money, "parentId", stash)
  put(money, "slotId", "hideout")
  var loc = obj()
  put(loc, "x", 0)
  put(loc, "y", 0)
  put(loc, "r", "Horizontal")
  put(money, "location", loc)
  put(money, "upd", objOf("StackObjectsCount", startingRoubles))
  items.add money

  var inventory = obj()
  put(inventory, "items", items)
  put(inventory, "equipment", equipment)
  put(inventory, "stash", stash)
  put(inventory, "questRaidItems", questRaid)
  put(inventory, "questStashItems", questStash)
  put(inventory, "sortingTable", sorting)
  put(inventory, "hideoutAreaStashes", obj())
  put(inventory, "fastPanel", obj())
  put(inventory, "favoriteItems", arr())

  var skills = obj()
  put(skills, "Common", arr())
  put(skills, "Mastering", arr())
  put(skills, "Points", 0)

  var stats = obj()
  var eft = obj()
  put(eft, "SessionCounters", objOf("Items", arr()))
  put(eft, "OverallCounters", objOf("Items", arr()))
  put(eft, "SessionExperienceMult", 0.0)
  put(eft, "ExperienceBonusMult", 0.0)
  put(eft, "TotalSessionExperience", 0)
  put(eft, "LastSessionDate", nowSeconds)
  put(eft, "Aggressor", jnull())
  put(eft, "DroppedItems", arr())
  put(eft, "FoundInRaidItems", arr())
  put(eft, "Victims", arr())
  put(eft, "TotalInGameTime", 0)
  put(eft, "SurvivorClass", "Unknown")
  put(stats, "Eft", eft)

  var hideout = obj()
  put(hideout, "Areas", arr())
  put(hideout, "Improvements", obj())
  put(hideout, "Production", obj())
  put(hideout, "Seed", obj())
  put(hideout, "sptUpdateLastRunTimestamp", nowSeconds)

  var p = obj()
  put(p, "_id", id)
  put(p, "aid", accountIdOf(id))
  put(p, "savage", scav)
  put(p, "Info", info)
  put(p, "Customization", customization)
  put(p, "Health", health)
  put(p, "Inventory", inventory)
  put(p, "Skills", skills)
  put(p, "Stats", stats)
  put(p, "Encyclopedia", obj())
  put(p, "TaskConditionCounters", obj())
  put(p, "InsuredItems", arr())
  put(p, "Hideout", hideout)
  put(p, "Bonuses", arr())
  put(p, "Notes", objOf("Notes", arr()))
  put(p, "Quests", arr())
  put(p, "ConditionCounters", objOf("Counters", arr()))
  var ragfair = obj()
  put(ragfair, "rating", 0.2)
  put(ragfair, "isRatingGrowing", true)
  put(ragfair, "offers", arr())
  put(ragfair, "sellSum", 0)
  put(p, "RagfairInfo", ragfair)
  put(p, "TradersInfo", obj())
  put(p, "UnlockedInfo", objOf("unlockedProductionRecipe", arr()))
  put(p, "WishList", obj())
  put(p, "moneyTransferLimitData", obj())
  put(p, "Achievements", obj())
  put(p, "Prestige", obj())
  result = done(p).text

# ---------------------------------------------------------------------------
# Persistence
# ---------------------------------------------------------------------------

proc loadProfile*(id: string): Profile =
  ## Reads a profile back off disk. A missing profile is `ok: false`, not an
  ## error worth logging: the launcher asks for profiles it has not created yet.
  result = Profile(id: id, text: "", ok: false)
  let stored = load(profileKey(id))
  if not stored.ok or stored.raw.len == 0:
    return
  result.text = stored.raw
  result.ok = true

proc saveProfile*(p: Profile): bool =
  ## Writes the whole document back. Whole-document rather than field-by-field
  ## because a half-written profile is unrecoverable and the client would load
  ## it anyway -- the write is the commit point, so it happens once, with
  ## everything in it.
  if p.id.len == 0 or p.text.len == 0:
    return false
  result = save(profileKey(p.id), p.text) == Ok

proc allProfileIds*(): seq[string] =
  ## Every profile the store holds. The launcher's profile list is this.
  result = @[]
  let keys = savedKeys(KeyPrefix)
  for k in keys:
    if k.len > KeyPrefix.len:
      result.add k.substr(KeyPrefix.len)

proc createProfile*(nickname, sideName, edition: string;
                    nowSeconds: int; startingRoubles: int = 500000): Profile =
  ## A new profile, saved before it is returned. Saved first because the client
  ## follows `create` with `start`, and a profile that only exists in memory
  ## would work until the server restarted -- the worst kind of working.
  let id = newId()
  result = Profile(id: id, text: "", ok: false)
  result.text = newProfileText(id, nickname, sideName, edition, nowSeconds,
                               startingRoubles)
  if not saveProfile(result):
    return Profile(id: id, text: "", ok: false)
  result.ok = true

proc nicknameTaken*(name: string): bool =
  ## Case-insensitively, because the client treats two nicknames differing only
  ## in case as the same one and would let a player create a profile it then
  ## refuses to log in to.
  let wanted = toLowerAscii(name)
  let ids = allProfileIds()
  for id in ids:
    let p = loadProfile(id)
    if p.ok and toLowerAscii(p.nickname) == wanted:
      return true
  result = false

# ---------------------------------------------------------------------------
# Editing
# ---------------------------------------------------------------------------

proc replaceValue(text, path, newValue: string): string =
  ## Replaces the value at a dotted path, leaving the rest of the document
  ## byte-for-byte. Text surgery rather than reserialisation: the profile holds
  ## fields this emulator does not model, and a round trip through a builder
  ## would drop every one of them.
  let target = field(text, path)
  if not target.found:
    return text
  result = text.substr(0, target.first - 1) & newValue &
           text.substr(target.last + 1)

proc setNumber*(p: var Profile; path: string; value: int) =
  p.text = replaceValue(p.text, path, $value)

proc setText*(p: var Profile; path, value: string) =
  p.text = replaceValue(p.text, path, jstr(value).text)

proc setRaw*(p: var Profile; path, valueJson: string) =
  ## For a whole subtree -- `Inventory.items` after a move, say.
  p.text = replaceValue(p.text, path, valueJson)

proc addExperience*(p: var Profile; amount: int) =
  if amount <= 0: return
  setNumber(p, "Info.Experience", p.experience + amount)
