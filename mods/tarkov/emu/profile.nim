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
import numbers
import starter
import starterkit
import shapes

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

  ## The equipment root every character hangs its worn gear off.
  DefaultInventoryTpl* = "55d7217a4bdc2d86028b456d"

  ## Pockets, and **not optional**.
  ##
  ## `EFT.Player::HasMarkOfUnknown` (GameAssembly RVA 0x726c40) is the reason.
  ## It walks
  ##
  ##     Player.InventoryController        (virtual, vtable slot +0xa68)
  ##       .Inventory                      (+0x100)
  ##       .Equipment                      (+0x18)
  ##       .Slots[8]                       (+0x90, array; index 8 is Pockets in
  ##                                        EFT.InventoryLogic.EquipmentSlot)
  ##       .ContainedItem                  (virtual get_ContainedItem)
  ##       .Slots                          (+0x80, the pocket sub-slots)
  ##
  ## and every one of those loads is followed by `test rax,rax / je 0x726e5f`,
  ## where 0x726e5f is the throw-NullReference helper. In particular the
  ## `ContainedItem` at +0x726d51 is checked and **thrown on**, so a Pockets slot
  ## with nothing in it is not "no mark of unknown", it is an exception.
  ##
  ## `BotsGroup..ctor` calls `IsPlayerEnemy` over every player in the raid, which
  ## reaches this through `BotsGroupMarkOfUnknown.HasMarkOfUnknown`. The throw
  ## unwinds out of `BotSpawner.GetGroupAndSetEnemies`, so the bot being
  ## activated never reaches `GameWorld.RegisterPlayer` -- which is exactly the
  ## "the server generates 28 bots and three ever appear" symptom, once per bot,
  ## forever, because our profile had an equipment root with nothing on it.
  ##
  ## `627a4e6b255f7527fb05a0f6` is the post-1.0 pockets with `SpecialSlot1..3`,
  ## which is where a `MarkOfUnknown` (a `SpecItem`) actually lives -- so the
  ## walk above terminates the way the client expects rather than on an empty
  ## `Slots` array it never meant to see.
  PocketsTpl* = "627a4e6b255f7527fb05a0f6"

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

proc docId*(p: Profile): string =
  ## The `_id` INSIDE the document, which is what the client keys on -- NOT
  ## `p.id`, which is derived from the store FILENAME. The two diverge exactly
  ## when a stray copy sits beside the real file: on 2026-08-31 a backup named
  ## `profile.<id>.bak-availableAfter-<ts>` gave a different filename key but
  ## carried the same `_id`, so both were served and the client's
  ## `SingleOrDefault` threw "Sequence contains more than one matching element".
  ## Dedup on THIS, and no stray file in the store dir can reproduce it.
  result = p.field("_id").asText("")

# ---------------------------------------------------------------------------
# What a new character looks like
# ---------------------------------------------------------------------------

proc defaultCustomisation*(sideName: string): seq[string] =
  ## The starting `Customization` block, in the order `Head`, `Body`, `Feet`,
  ## `Hands`, `DogTag`.
  ##
  ## A list rather than five literals inline, because these are the ids
  ## `emu/customise` checks at load against the real `templates.customization`
  ## — the same validator a `CustomizationSet` goes through — and a check that
  ## cannot see the values it is checking is not a check.
  ##
  ## **It found them wrong.** Every one of these used to be written inline and
  ## seven of the eight were the wrong entry: the head was `DefaultBearHead` on
  ## Usec characters, the Usec body was `DefaulUsecFeet`, the Bear feet were
  ## `DefaultUsecHands`, and so on down a list that had plainly been pasted out
  ## of order. Nothing failed, because the client resolves these against its own
  ## bundles and a wrong id is a model that does not appear.
  ##
  ## They are literals and not a query against the database, for the reason the
  ## whole of `newProfileText` is: a profile that only exists when a 40MB
  ## template table is loaded is a profile that cannot be tested. The load-time
  ## check is what ties the literals to the table when there is one.
  # Order: Head, Body, Feet, Hands, Voice, DogTag. Post-1.0 requires a `Voice`
  # entry in the Customization dictionary -- the menu load does `dict["Voice"]`
  # and throws KeyNotFoundException without it, which stalls the profile load
  # forever. It is a customization template id, distinct from `Info.Voice`.
  if sideName == "Bear":
    return @["5cc084dd14c02e000b0550a3",  # DefaultBearHead
             "5cc0858d14c02e000c6bea66",  # DefaultBearBody
             "5cc085bb14c02e000e67a5c5",  # DefaultBearFeet
             "5cc0876314c02e000c6bea6b",  # DefaultBearHands
             "5fc6151b0b735e7b024c76eb",  # DefaultBearVoice
             "674731c8bafff850080488bb"]  # dogtag_bear_default
  result = @["5cde96047d6c8b20b577f016",  # DefaultUsecHead
             "5cde95d97d6c8b647a3769b0",  # DefaultUsecBody
             "5cde95ef7d6c8b04713c4f2d",  # DefaulUsecFeet (the table's spelling)
             "5cde95fa7d6c8b04737c2d13",  # DefaultUsecHands
             "5fc615110b735e7b024c76ea",  # DefaultUsecVoice
             "674731d1170146228c0d222a"]  # dogtag_usec_default

proc defaultVoice*(sideName: string): string =
  ## `Info.Voice` holds a voice's **name**, not its id — which is why this is a
  ## string and the rest are ids. Both names are `_props.Name` on an entry under
  ## the `Voice` node, and the load-time check confirms they still are.
  if sideName == "Bear": "Bear_1" else: "Usec_1"

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

  # The edition's starting kit, out of `templates.profiles` (see `starterkit`).
  # When it is not there the profile is still built -- with five containers and
  # a money stack, as it always was -- but the log says so, because a player who
  # spawns unarmed and unarmoured deserves an explanation on the server that
  # made them.
  let kit = starterKit(edition, sideName, startingRoubles)
  var gameVersion = normalEdition(edition)
  if gameVersion.len == 0:
    gameVersion = "standard"
  if not kit.ok:
    warn "starting gear: " & kit.reason
    warn "starting gear: this profile gets containers and cash only. Import " &
         "templates/profiles.json with `aowl importdb` to fix it."

  var info = obj()
  put(info, "Nickname", nickname)
  put(info, "LowerNickname", toLowerAscii(nickname))
  put(info, "Side", sideName)
  put(info, "Voice", defaultVoice(sideName))
  put(info, "Level", 1)
  put(info, "Experience", 0)
  put(info, "RegistrationDate", nowSeconds)
  put(info, "GameVersion", gameVersion)
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
  # The default heads, bodies and dog tag, out of `defaultCustomisation` above
  # so that `emu/customise` can check them against the real table at load. The
  # client resolves these against its own bundles, so a wrong id is a missing
  # model rather than a crash -- which is exactly why they were wrong for as
  # long as they were.
  let look = defaultCustomisation(sideName)
  put(customization, "Head", look[0])
  put(customization, "Body", look[1])
  put(customization, "Feet", look[2])
  put(customization, "Hands", look[3])
  put(customization, "Voice", look[4])
  put(customization, "DogTag", look[5])

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
  put(equipItem, "_tpl", DefaultInventoryTpl)
  items.add equipItem
  # Pockets. See `PocketsTpl` above for why this is load-bearing and not
  # cosmetic: without it every bot activation in a raid throws.
  var pocketsItem = obj()
  put(pocketsItem, "_id", newId())
  put(pocketsItem, "_tpl", PocketsTpl)
  put(pocketsItem, "parentId", equipment)
  put(pocketsItem, "slotId", "Pockets")
  items.add pocketsItem
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
  put(inventory, "hideoutAreaStashes", arr())
  put(inventory, "fastPanel", obj())
  put(inventory, "favoriteItems", arr())

  # The kit wins when it is there. `inventoryText` is what goes on the profile;
  # the seven-item build above is the fallback and nothing else reads it.
  let inventoryText = if kit.ok: kit.inventory else: done(inventory).text

  var skills = obj()
  # The 54 Common skills and the one Mastering entry a fresh standard-edition
  # profile carries (capture seq 096), all at Progress 0. An empty list here is
  # not fatal but leaves the Skills screen blank; the client renders from these.
  put(skills, "Common", raw(StarterSkillsCommon))
  put(skills, "Mastering", raw(StarterSkillsMastering))
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
  # All 27 hideout areas at their standard-edition starting levels (capture seq
  # 096): the stash starts at level 1, the rest unbuilt. An empty Areas list
  # leaves the hideout screen with nothing to draw and no stash area to key on.
  put(hideout, "Areas", raw(StarterHideoutAreas))
  put(hideout, "Improvements", obj())
  # The two maps `emu/decorate` writes: which floor, wall, ceiling and target
  # the hideout wears, and which pose each mannequin is in. Empty rather than
  # absent, because the reference DTO has both and a client reading a map that
  # is not there is a different case from one reading an empty one -- and
  # because `setRaw` on a profile does nothing to a path that does not exist,
  # so an absent block is a write that vanishes.
  put(hideout, "Customization", obj())
  put(hideout, "MannequinPoses", obj())
  put(hideout, "Production", obj())
  # Post-1.0 deserialises Hideout.Seed as a STRING (a 32-hex hideout RNG seed);
  # SPT's pre-1.0 profile had it as an object, which makes the client throw
  # "Unexpected token: StartObject. Path '[0].Hideout.Seed'" on the profile list
  # and never finish loading the menu.
  put(hideout, "Seed", "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6")
  put(hideout, "sptUpdateLastRunTimestamp", nowSeconds)

  var p = obj()
  put(p, "_id", id)
  put(p, "aid", accountIdOf(id))
  put(p, "savage", scav)
  put(p, "Info", info)
  put(p, "Customization", customization)
  put(p, "Health", health)
  put(p, "Inventory", raw(inventoryText))
  put(p, "Skills", skills)
  put(p, "Stats", stats)
  put(p, "Encyclopedia", raw(if kit.ok: kit.encyclopedia else: "{}"))
  put(p, "TaskConditionCounters", obj())
  put(p, "InsuredItems", arr())
  put(p, "Hideout", hideout)
  # The two bonuses a fresh standard profile carries (capture seq 096): the
  # StashSize bonus (which is what gives the stash its grid) and the starting
  # weapon-modification unlock. Without the StashSize bonus the stash renders at
  # its base template size.
  put(p, "Bonuses", raw(if kit.ok: kit.bonuses else: StarterBonuses))
  put(p, "Notes", objOf("Notes", arr()))
  # Starting quests are left empty on purpose: capture 096 shows two intro
  # quests pre-started, but those ids are game-version specific and pre-starting
  # a quest the emulator's quest tables may not carry risks a broken hand-in.
  # The client draws all available quests from /client/quest/list regardless.
  put(p, "Quests", arr())
  put(p, "ConditionCounters", objOf("Counters", arr()))
  var ragfair = obj()
  put(ragfair, "rating", 0.2)
  put(ragfair, "isRatingGrowing", true)
  put(ragfair, "offers", arr())
  put(ragfair, "sellSum", 0)
  put(p, "RagfairInfo", ragfair)
  put(p, "TradersInfo", raw(seedTradersInfo(kit.trader)))
  put(p, "UnlockedInfo", objOf("unlockedProductionRecipe", arr()))
  put(p, "WishList", obj())
  put(p, "moneyTransferLimitData", obj())
  put(p, "Achievements", obj())
  put(p, "Prestige", obj())
  # Post-1.0 top-level members the client's Profile DTO reads (capture seq 096).
  # Empty is the fresh-profile state; the point is that the key is present, so a
  # read of `profile.Variables[...]` or the seasonal/battle-pass screens find a
  # collection to index rather than null.
  put(p, "Variables", obj())
  put(p, "CompletableItems", obj())
  put(p, "UnlockedLocations", arr())
  # Ending carries {current, achieved}.
  var ending = obj()
  put(ending, "current", "")
  put(ending, "achieved", arr())
  put(p, "Ending", ending)
  put(p, "QuestNotes", obj())
  put(p, "ReadQuestData", arr())
  put(p, "SeasonalPerks", arr())
  put(p, "SeasonalPerkEffectParameters", obj())
  put(p, "SeasonalRewards", obj())
  put(p, "BattlePassProgress", arr())
  put(p, "BattlePassUniversalDocumentBalance", 0)
  put(p, "battlePassDocumentLimitData", obj())
  # Three more members of the client's `EFT.ProfileDescriptor` that this
  # profile never carried. MEASURED by `tools/oursample.py` against OUR OWN
  # served `/client/game/profile/list` -- not against a BSG capture, which is
  # what every earlier gap number was accidentally measuring.
  #
  # `CheckedChambers` (List<MongoID>) and `CheckedMagazines`
  # (Dictionary<MongoID,int>) are REFERENCE types: absent from the JSON,
  # Newtonsoft leaves them NULL, and the empty collection is both the correct
  # fresh-profile state -- a new character has inspected no chamber and no
  # magazine -- and the value that cannot NRE. `karmaValue` is a float and
  # would silently default to 0, which is also the right starting value; it is
  # written explicitly so the key exists rather than relying on that.
  #
  # Whether the client DEREFERENCES any of the three is NOT established here.
  # That needs disassembly of the consumer, which nobody has done. These are
  # filled because the correct value is knowable and costs nothing, not
  # because a crash was proved.
  put(p, "CheckedChambers", arr())
  put(p, "CheckedMagazines", obj())
  put(p, "karmaValue", 0.0)
  result = done(p).text

proc replaceValue(text, path, newValue: string): string =
  ## Replaces the value at a dotted path, leaving the rest of the document
  ## byte-for-byte. Text surgery rather than reserialisation: the profile holds
  ## fields this emulator does not model, and a round trip through a builder
  ## would drop every one of them.
  ##
  ## Defined here rather than beside the other editing helpers because
  ## `ensurePockets` below runs on every load and has to exist before
  ## `readProfile` does.
  let target = field(text, path)
  if not target.found:
    return text
  result = text.substr(0, target.first - 1) & newValue &
           text.substr(target.last + 1)

proc ensurePockets*(p: var Profile): bool =
  ## Puts a Pockets item on the equipment root of a profile that has none, and
  ## says whether it had to.
  ##
  ## Repairs a profile that was created before this was known to matter. New
  ## profiles get pockets in `newProfileText`; profiles already on disk were
  ## written with a bare equipment root, and those are the ones a player has --
  ## so a fix that only reaches new characters fixes nobody. See `PocketsTpl`
  ## for what the client does with a missing one.
  ##
  ## In memory only: the repaired document is what every route serves from this
  ## load onward, and the next ordinary whole-document write persists it. Saving
  ## from inside a read would put a write on every request thread that merely
  ## looked at a profile, which is the concurrency the version counter below
  ## exists to complain about.
  result = false
  if not p.ok or p.text.len == 0:
    return
  let equipment = p.field("Inventory.equipment").asText("")
  if equipment.len == 0:
    return
  let itemsRef = p.field("Inventory.items")
  if not itemsRef.isArray:
    return
  let existing = itemsRef.each()
  for it in existing:
    if it.child("slotId").asText("") == "Pockets" and
       it.child("parentId").asText("") == equipment:
      return
  var list = parseArray(itemsRef)
  if not list.ok:
    return
  var d = newDoc()
  setText(d, "_id", newId())
  setText(d, "_tpl", PocketsTpl)
  setText(d, "parentId", equipment)
  setText(d, "slotId", "Pockets")
  list.add d
  p.text = replaceValue(p.text, "Inventory.items", text(list))
  result = true

const DescriptorDefaults = [
  # (member, JSON literal). Members of the client's `EFT.ProfileDescriptor`
  # that a profile written before they were known does not carry. MEASURED
  # against OUR OWN `/client/game/profile/list` by `tools/oursample.py`.
  ("CheckedChambers", "[]"),
  ("CheckedMagazines", "{}"),
  ("karmaValue", "0.0"),
]

proc ensureDescriptorMembers*(p: var Profile): seq[string] =
  ## Adds any missing `ProfileDescriptor` member listed in
  ## `DescriptorDefaults`, and returns the names it had to add.
  ##
  ## Same reasoning as `ensurePockets` directly above: new profiles get these
  ## from `newProfileText`, and every profile already on disk does not -- so a
  ## fix that only reaches new characters fixes nobody. In memory only, for the
  ## same reason.
  ##
  ## Returning the NAMES rather than a bool on purpose: "it added something" is
  ## not a result a caller can check against anything, while the list is
  ## exactly what a wire check can assert has become empty.
  result = @[]
  if not p.ok or p.text.len == 0:
    return
  var wanted: seq[(string, string)] = @[]
  for pair in DescriptorDefaults:
    if not p.field(pair[0]).found:
      wanted.add pair
  if wanted.len == 0:
    return
  var d = parseObject(p.text)
  if not d.ok:
    # Unparseable here is NOT "nothing was missing" -- say nothing rather than
    # report a repair that did not happen.
    return
  for pair in wanted:
    setRaw(d, pair[0], pair[1])
    result.add pair[0]
  p.text = text(d)

const DictionaryMembers* = [
  # Members the client's DTO declares as a Dictionary and this emulator used to
  # emit as an empty ARRAY. Newtonsoft does not degrade on a shape mismatch: it
  # throws, and the throw propagates out of the client's own request handling --
  # the same class of defect that killed a raid load when
  # `/client/mail/dialog/list` sent `systemData: false` where a class was
  # declared. Declared types, for the record:
  #   Hideout.MannequinPoses  Dictionary<string, MongoID>
  #   WishList                Dictionary<MongoID, byte>
  #   Achievements            Dictionary<MongoID, int>
  #   Prestige                Dictionary<MongoID, int>
  #   CompletableItems        Dictionary<MongoID, bool>
  #   SeasonalRewards         Dictionary<MongoID, SeasonalRewardData>
  # SPT's own profile template sends `{}` for Achievements and Prestige, which
  # is a second implementation agreeing, not a guess.
  "Hideout.MannequinPoses",
  "WishList",
  "Achievements",
  "Prestige",
  "CompletableItems",
  "SeasonalRewards",
]

proc ensureDictionaryShapes*(p: var Profile): seq[string] =
  ## Rewrites any member of `DictionaryMembers` that is an EMPTY ARRAY into an
  ## empty object, and returns the paths it had to rewrite.
  ##
  ## New profiles get `{}` from `newProfileText`; every profile already on disk
  ## carries `[]`, so a fix that only reaches new characters fixes nobody --
  ## same reasoning as `ensurePockets`. In memory only.
  ##
  ## Deliberately narrow: ONLY the literal empty array is rewritten. A
  ## non-empty array here is a different bug with a different repair, and
  ## quietly turning it into `{}` would destroy data while reporting success.
  result = @[]
  if not p.ok or p.text.len == 0:
    return
  for path in DictionaryMembers:
    let r = p.field(path)
    if not r.found:
      continue
    var raw = r.raw()
    var compact = ""
    for ch in raw:
      if ch > chr(32): compact.add ch
    if compact != "[]":
      continue
    p.text = replaceValue(p.text, path, "{}")
    result.add path

# ---------------------------------------------------------------------------
# Persistence
# ---------------------------------------------------------------------------

type
  ProfileRead* = enum
    ## Why a profile is not in hand. Three answers, not two -- see below.
    prLoaded, prMissing, prUnreadable

proc readProfile*(id: string; why: var ProfileRead): Profile =
  ## Reads a profile back off disk, saying **which kind of failure** it was.
  ##
  ## This distinction had a catastrophic bug behind it and is worth the extra
  ## enum. `load` used to answer `ok: false` for two completely different
  ## situations -- "there is no such profile", which is ordinary and happens
  ## every time the launcher asks about an account that has not been created,
  ## and "the profile is there and could not be read", which is a sharing
  ## violation, a disk error or a file somebody has open. The recovery for the
  ## first is *to create one*. Applied to the second, that recovery writes a
  ## brand-new character over a real player's account, and nothing anywhere
  ## says so: the read failure is invisible, the create succeeds, and the client
  ## is handed a level 1 profile with 500,000 roubles where a career was.
  ##
  ## The shape of that bug is worth recognising elsewhere, because it is not
  ## about profiles: **two different situations answering the same value, where
  ## the recovery for one is destructive to the other.** Anywhere "not found"
  ## leads to creating something, the question to ask is whether the read
  ## underneath can fail for a reason that is not absence.
  ##
  ## `Stored.missing` is the store's answer to it: `ok: false, missing: true` is
  ## genuinely nothing there, and `ok: false, missing: false` is a read that
  ## failed. The host logs the failure and answers `ErrGeneric` rather than
  ## `ErrNotFound`, so the two can no longer be confused.
  why = prMissing
  result = Profile(id: id, text: "", ok: false)
  let stored = load(profileKey(id))
  if stored.ok and stored.raw.len > 0:
    result.text = stored.raw
    result.ok = true
    why = prLoaded
    # Type-shape repair FIRST, before anything else reads a value out of this
    # document. A boolean where the client's DTO declares an integer does not
    # degrade -- Newtonsoft throws and the player gets a modal dialog we do not
    # see (measured 2026-08-31: `Path '[0].Quests[558].availableAfter'`). See
    # `emu/shapes` for how each rule is measured against the real db.
    block shapeRepair:
      let original = result.text
      let findings = repairScalarShapes(result.text)
      if findings.len == 0:
        break shapeRepair
      var repaired = 0
      var refused = 0
      for f in findings:
        if f.repaired: inc repaired else: inc refused
      if repaired > 0:
        # Back up the pre-repair document ONCE per profile, keyed separately so
        # `allProfileIds` (prefix "profile.") never sees it. Only if there is no
        # backup yet: a second load must not overwrite the original evidence
        # with an already-repaired copy.
        let bak = "profilebak." & id & ".shapes"
        let existing = load(bak)
        if not (existing.ok and existing.raw.len > 0):
          if save(bak, original) != Ok:
            error "profile " & id & " type-shape repair: could NOT write the " &
                  "pre-repair backup " & bak & "; repairing in memory anyway " &
                  "(the on-disk document is still the original until a save)"
        error "profile " & id & " had values of the WRONG JSON TYPE; " &
              "repaired " & $repaired & " in memory (backup key " & bak & "): " &
              summarise(findings)
      if refused > 0:
        error "profile " & id & " has " & $refused & " wrong-typed values this " &
              "repair REFUSES to touch (not scalars): " & summarise(findings) &
              " -- the client will still throw on these; fix them by hand"
    if ensurePockets(result):
      info "profile " & id & " had no Pockets item; added one (see PocketsTpl)"
    let reshaped = ensureDictionaryShapes(result)
    if reshaped.len > 0:
      var paths = ""
      for n in reshaped:
        if paths.len > 0: paths.add ", "
        paths.add n
      info "profile " & id & " had Dictionary members stored as empty " &
           "arrays: " & paths & " (rewritten to {})"
    let added = ensureDescriptorMembers(result)
    if added.len > 0:
      var names = ""
      for n in added:
        if names.len > 0: names.add ", "
        names.add n
      info "profile " & id & " was missing ProfileDescriptor members: " &
           names & " (added, empty)"
    return
  if not stored.ok and not stored.missing:
    why = prUnreadable
    error "profile " & id & " exists and could not be read: " & stored.error
    return
  if stored.ok and stored.raw.len == 0:
    # Present and empty. Not absence either: an empty profile document is a
    # write that was interrupted before the store became atomic, or a file
    # somebody has truncated. Creating over it is the same destruction.
    why = prUnreadable
    error "profile " & id & " is present and empty; refusing to treat that " &
          "as a profile that does not exist"

proc loadProfile*(id: string): Profile =
  ## `readProfile` for the callers that only need the profile. An unreadable
  ## profile is `ok: false` here as well -- so every caller that already refuses
  ## on `not ok` keeps refusing -- and the *only* caller that must tell the two
  ## apart is the one that would otherwise create a replacement.
  var why = prMissing
  result = readProfile(id, why)

# ---------------------------------------------------------------------------
# Noticing that two requests edited the same profile
# ---------------------------------------------------------------------------
#
# Every route here is read-modify-write over the whole document, and the backend
# answers requests on a pool of threads. Six concurrent purchases on one profile
# all answered `err:0`; three rifles arrived and three were silently thrown
# away, because each request had loaded the document before any of them saved
# it. Nothing was duplicated and no money went missing -- the arithmetic was
# self-consistent every time -- and the client was still told three things
# happened that did not.
#
# So every save stamps a counter, and a request that is about to save checks the
# counter has not moved since it read the document. Not moved means nobody else
# wrote in between; moved means this request has been working from a document
# that no longer exists, and the honest answer is a failure the client can retry
# rather than a success it cannot.
#
# **Why a counter and not a re-read.** Reading the stored profile immediately
# before writing it is the obvious version of this and it does not work: the
# store replaces the file atomically, and the open-for-read that had just
# happened made the replace fail with a sharing violation -- every split, every
# purchase, refused. A fix for a silent discard cannot be a new way to lose the
# write.
#
# **Why a fixed array and not a table.** This is touched from several request
# threads at once and there is no lock in the mod API -- and there should not
# be, because a mod holding a lock across a request is a mod that can stop the
# server. A `seq` reallocates, and a reallocation racing a read is a crash. A
# fixed array of ints never moves. Two profiles whose ids hash to the same slot
# share a counter, which costs a spurious retry when both are written in the
# same instant and nothing else.
#
# **This narrows the window; it does not close it.** Two writers can still both
# read the counter, both pass, and both write. Closing it means the host
# serialising item-event handling per profile -- one request at a time for a
# given profile id -- which is a change in `backend/`. What this buys is that
# the ordinary case, a second request arriving while the first is still working,
# is reported instead of discarded.

const VersionSlots = 64

var gProfileVersion: array[VersionSlots, int]

proc versionSlot(id: string): int =
  var h = 0
  for c in id:
    h = h + ord(c)
  result = h mod VersionSlots

proc profileVersion*(id: string): int =
  ## The value a request captures when it reads a profile and hands back to
  ## `saveIfUnchanged` when it writes one.
  result = gProfileVersion[versionSlot(id)]

proc saveProfile*(p: Profile): bool =
  ## Writes the whole document back. Whole-document rather than field-by-field
  ## because a half-written profile is unrecoverable and the client would load
  ## it anyway -- the write is the commit point, so it happens once, with
  ## everything in it.
  if p.id.len == 0 or p.text.len == 0:
    return false
  result = save(profileKey(p.id), p.text) == Ok
  if result:
    # Every write stamps the counter, not just the guarded ones: a raid result
    # saved on one thread is exactly the kind of write an item event on another
    # has to notice.
    let slot = versionSlot(p.id)
    gProfileVersion[slot] = gProfileVersion[slot] + 1

proc saveIfUnchanged*(p: Profile; asRead: int): bool =
  ## `saveProfile`, refused when somebody else has written this profile since
  ## `asRead` was taken. See the note above for what that does and does not
  ## guarantee.
  if p.id.len == 0 or p.text.len == 0:
    return false
  if profileVersion(p.id) != asRead:
    return false
  result = saveProfile(p)

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

proc setNumber*(p: var Profile; path: string; value: int) =
  p.text = replaceValue(p.text, path, $value)

proc setText*(p: var Profile; path, value: string) =
  p.text = replaceValue(p.text, path, jstr(value).text)

proc setRaw*(p: var Profile; path, valueJson: string) =
  ## For a whole subtree -- `Inventory.items` after a move, say.
  p.text = replaceValue(p.text, path, valueJson)

proc setTopLevel*(p: var Profile; name, rawValue: string) =
  ## Sets a top-level member of the profile, adding it when it is missing.
  ##
  ## `setRaw` replaces a value that is already there and does nothing when it is
  ## not, which is right for a path into a document nobody promised a shape for
  ## -- and wrong for `TaskConditionCounters` or `InsuredItems` on a profile
  ## that predates the module writing them, where "nothing happened" means every
  ## value written is dropped without a word. The fallback re-serialises the top
  ## level through `Doc`, which keeps every other member as the raw text it
  ## already was.
  if p.field(name).found:
    setRaw(p, name, rawValue)
    return
  var d = parseObject(p.text)
  if not d.ok:
    return
  setRaw(d, name, rawValue)
  p.text = text(d)

proc addExperience*(p: var Profile; amount: int) =
  if amount <= 0: return
  setNumber(p, "Info.Experience", p.experience + amount)
