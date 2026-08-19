## Checking this mod's own data, before a raid does it for us.
##
## ---------------------------------------------------------------------------
## WHY THIS FILE EXISTS
## ---------------------------------------------------------------------------
##
## The failure mode of a data-driven bot mod is not a crash. It is a faction
## that is **silently three quarters there**. A loadout whose weapon pool is
## empty gives a bot with no gun; a `chances.equipment` entry naming a slot the
## loadout has no pool for gives a bot that rolls for a helmet it can never
## have; a template id with a typo in it gives a bot wearing nothing where the
## helmet should be. In every one of those cases the bot **still spawns**, still
## has a name, still shoots at you, and the mod still logs "6 bot type(s)
## registered". Nothing looks wrong. The only symptom is that the faction is a
## bit worse than it was supposed to be, forever, and nobody can say why.
##
## So the self-test does not ask "did the files parse". It asks the questions
## whose wrong answers are invisible:
##
##  * **Is every template id well-formed?** A MongoId is 24 lower-case hex
##    digits. `5e00c1ad86f774747333222c` is one; `5e00c1ad86f7747473332 2c`,
##    `5E00C1AD86F774747333222C` and a truncated paste are not, and the game's
##    item lookup answers `null` for all three without complaining.
##  * **Is every equipment slot a slot the game has?** `TacticalVest` fills;
##    `Tacticalvest` does not, and neither does `Vest`. The list of real slots
##    is short, fixed and known, so this is decidable here.
##  * **Does every chance have a pool, and every pool a chance?** These are two
##    halves of one decision written in two different objects, and they drift.
##  * **Does every pool have a positive total weight?** A pool of entries all
##    weighted 0 is an empty pool with entries in it.
##  * **Are the ids unique?** Two roles sharing a `WildSpawnType` integer is one
##    role with two names and a faction graph that disagrees with itself.
##
## ---------------------------------------------------------------------------
## WHAT IT DELIBERATELY DOES NOT CHECK
## ---------------------------------------------------------------------------
##
## **Whether an id exists in `templates.items`.** Not in the offline pass, and
## it should not pretend to: `aowl run` with no `--db` has no database. What
## the offline pass does is check the id's *shape*, which catches every typo.
##
## Existence is a second pass with a separate verdict — `checkAgainstDatabase`
## at the end of this file — and it runs only when a database is actually
## attached. **This paragraph named that proc for a long time before the proc
## existed**, and `config.json` promised its output to the user; both are now
## true, and the gap is recorded here because a promise the code does not keep
## is worse than no promise at all.
##
## Ids in the shipped loadouts that a stock database does not have are not
## automatically faults: WTT-ContentBackport's rigs, packs and face covers are
## legitimately absent, and a pass that reported each one as an error would
## produce a screenful of errors on a correct install and teach its reader to
## skip the section. So absence is *reported* and the fault rule is asked one
## level up, per pool: a slot where **nothing** resolves is a slot that is
## always bare.
##
## **The first run of this pass found that six pools are exactly that**, which
## is the answer nobody had because nobody had asked. Against a stock SPT 4.x
## database, 44 of this mod's 850 distinct ids are absent, and the absences are
## not spread evenly: `blackdivassault` and `blackdivib` have no rig and no
## backpack left at all, and `bosswedge` has neither rig nor face cover. This
## file used to say that every slot holding a WTT id also holds a db-verified
## alternative, so a player without WTT would get an operator in a BlackHawk!
## Commando rig rather than an operator in nothing. For those six slots that
## was false. It is a content gap in `data/loadouts/*.json` rather than a bug
## in any code, and closing it means adding a stock fallback id to each of the
## six -- a decision about which item, which is not one a validator should make
## on its own. Until then it is named on every run.
##
## **Severity follows the rule this file already applies to maps.** A hunt map
## with no spawn points is reported and does not fail the self-test, because it
## is a fact about the database attached rather than about this mod's data --
## and an absent WTT rig is the same kind of fact, since the same loadout
## against a database with WTT installed has no empty pool at all. A verdict
## that changes with whichever database is lying around is not a gate. The
## exception is a **weapon** slot: a bot with no rig is a worse bot, a bot with
## no gun is not a bot, and that fails outright. In practice that can only fire
## for `armoryLoadouts` with WTT-Armory absent, which is exactly the case
## `config.json` warns about and exactly the case nothing checked before.

import std/strutils
import aowlspt
import aowlspt/json
import aowlspt/server   # `dbRead` -- the database pass at the end of this file
import data

type
  Report* = object
    ## What one pass found. Counts, not adjectives — "ok" is not a number and
    ## a report that only says "ok" cannot tell a full data set from a tenth of
    ## one, which is the whole problem this file was written for.
    files*: int
    equipmentSlots*: int
    equipmentIds*: int
    modRoots*: int
    modRefs*: int
    ammoCalibers*: int
    ammoRounds*: int
    chanceKeys*: int
    names*: int
    badIds*: int
    badSlots*: int
    badWeights*: int
    orphanChances*: int
    orphanPools*: int
    duplicates*: int
    problems*: int

const
  EquipmentSlots* = [
    "FirstPrimaryWeapon", "SecondPrimaryWeapon", "Holster", "Scabbard",
    "Headwear", "FaceCover", "Eyewear", "Earpiece", "ArmorVest",
    "TacticalVest", "Backpack", "Pockets", "SecuredContainer", "ArmBand"]
    ## Every equipment slot the game has, and no others. This is not a
    ## convention: `Info.Inventory` names these fourteen and a fifteenth string
    ## reaches no slot at all. `Dogtag` is absent on purpose — a bot is not
    ## generated wearing one.

  ArmorPlateSlots* = [
    "front_plate", "back_plate", "left_side_plate", "right_side_plate",
    "soft_armor_front", "soft_armor_back", "soft_armor_left",
    "soft_armor_right", "collar", "groin", "groin_back",
    "shoulder_l", "shoulder_r", "helmet_top", "helmet_back", "helmet_ears",
    "helmet_eyes", "helmet_jaw", "dogtag",
    "specialslot1", "specialslot2", "specialslot3"]
    ## The armour, helmet and utility sub-slots, which are *not* spelled
    ## `mod_*` — which is why "starts with mod_" is not a sufficient test.
    ##
    ## Held lower-cased and compared lower-cased, and that is a fact about
    ## BSG's data rather than laziness here. A stock database contains **both
    ## casings of most of these, on different items**: `Helmet_top` on 59 items
    ## and `helmet_top` on 3; `Soft_armor_left` on 45 and `soft_armor_left` on
    ## 2. And the pair is not even consistent — `soft_armor_right` occurs on 47
    ## items and `Soft_armor_right` on none at all, so a validator that picked
    ## the capitalised form "for consistency" would reject the only spelling
    ## that exists. Both are legal because the game matches them literally
    ## against the item that declares them; a mod's job is to copy whichever
    ## the item uses, and this file's job is to not reject either.

proc isMongoId*(s: string): bool =
  ## 24 lower-case hex digits, and nothing else.
  ##
  ## Case matters and is not folded. The game's item table is keyed by the
  ## lower-case form; an upper-case paste out of a wiki page looks identical in
  ## a diff and resolves to nothing.
  if s.len != 24:
    return false
  for ch in s:
    let ok = (ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f')
    if not ok:
      return false
  result = true

proc isEquipmentSlot*(s: string): bool =
  for k in EquipmentSlots:
    if k == s:
      return true
  result = false

proc lowerOf(s: string): string =
  result = ""
  for ch in s:
    if ch >= 'A' and ch <= 'Z':
      result.add char(ord(ch) + 32)
    else:
      result.add ch

proc isModSlot*(s: string): bool =
  ## A weapon-mod slot (`mod_*`, `patron_in_weapon*`, `cartridges`, `camora_*`)
  ## or one of the named armour sub-slots, either casing.
  if s.startsWith("mod_") or s.startsWith("patron_in_weapon") or
     s.startsWith("camora_") or s == "cartridges":
    return true
  let low = lowerOf(s)
  for k in ArmorPlateSlots:
    if k == low:
      return true
  result = false

proc contains*(s: seq[string]; v: string): bool =
  ## `v in s`, spelled out. nimony has no generic `contains` for a `seq` and a
  ## hand-rolled one twice is worse than one exported here.
  for x in s:
    if x == v:
      return true
  result = false

# ---------------------------------------------------------------------------
# One loadout document
# ---------------------------------------------------------------------------

proc checkLoadout*(label, text: string; templateChances: seq[string];
                   r: var Report) =
  ## The whole of one `data/loadouts/*.json`.
  ##
  ## `templateChances` is the equipment-chance key set of the bot template this
  ## overlay lands on. It has to be passed in rather than assumed, because a
  ## loadout legitimately omits a chance the template already carries — that is
  ## the *point* of the template/overlay split — and a validator that does not
  ## know what the template says would report every one of those as a fault and
  ## teach the reader to ignore it.
  if text.len < 3:
    error "  " & label & ": missing or empty"
    inc r.problems
    return
  let doc = whole(text)
  if not isObject(doc):
    error "  " & label & ": not a JSON object"
    inc r.problems
    return

  let inv = child(doc, "inventory")
  let chances = child(doc, "chances")
  if not inv.found:
    error "  " & label & ": no `inventory`, so it overlays nothing at all"
    inc r.problems
    return

  # --- the equipment pools.
  var pooled: seq[string] = @[]
  let equip = child(inv, "equipment")
  if equip.found:
    let slots = keys(equip)
    for slot in slots:
      inc r.equipmentSlots
      pooled.add slot
      if not isEquipmentSlot(slot):
        error "  " & label & ": `" & slot & "` is not an equipment slot the " &
              "game has; nothing will ever be put in it"
        inc r.badSlots
        inc r.problems
      let pool = child(equip, slot)
      let ids = keys(pool)
      if ids.len == 0:
        error "  " & label & "." & slot & ": the pool is empty, so this slot " &
              "is always bare no matter what its chance says"
        inc r.badWeights
        inc r.problems
        continue
      var total = 0
      for id in ids:
        inc r.equipmentIds
        if not isMongoId(id):
          error "  " & label & "." & slot & ": `" & id & "` is not a " &
                "24-digit lower-case hex template id"
          inc r.badIds
          inc r.problems
        let w = child(pool, id).asInt(0)
        if w < 0:
          error "  " & label & "." & slot & "." & id & ": negative weight " & $w
          inc r.badWeights
          inc r.problems
        total = total + w
      if total <= 0:
        error "  " & label & "." & slot & ": " & $ids.len & " entries and a " &
              "total weight of " & $total & " -- a pool that can never roll " &
              "is an empty slot with contents"
        inc r.badWeights
        inc r.problems

  # --- the mod graph.
  let mods1 = child(inv, "mods")
  if mods1.found:
    let roots = keys(mods1)
    for root in roots:
      inc r.modRoots
      if not isMongoId(root):
        error "  " & label & ".mods: `" & root & "` is not a template id"
        inc r.badIds
        inc r.problems
      let slots = child(mods1, root)
      let names = keys(slots)
      for slot in names:
        if not isModSlot(slot):
          error "  " & label & ".mods." & root & ": `" & slot & "` is not a " &
                "mod slot; it will attach nothing"
          inc r.badSlots
          inc r.problems
        let lst = child(slots, slot)
        let entries = each(lst)
        for e in entries:
          inc r.modRefs
          let id = e.asText("")
          if not isMongoId(id):
            error "  " & label & ".mods." & root & "." & slot & ": `" & id &
                  "` is not a template id"
            inc r.badIds
            inc r.problems

  # --- ammunition.
  let ammo = child(inv, "Ammo")
  if ammo.found:
    let cals = keys(ammo)
    for cal in cals:
      inc r.ammoCalibers
      if not cal.startsWith("Caliber"):
        error "  " & label & ".Ammo: `" & cal & "` is not a caliber key " &
              "(they all begin `Caliber`); the guns that use it get nothing " &
              "to fire"
        inc r.badSlots
        inc r.problems
      let rounds = keys(child(ammo, cal))
      if rounds.len == 0:
        error "  " & label & ".Ammo." & cal & ": no rounds, so every weapon " &
              "in that caliber spawns with an empty magazine"
        inc r.badWeights
        inc r.problems
      var total = 0
      for rd in rounds:
        inc r.ammoRounds
        if not isMongoId(rd):
          error "  " & label & ".Ammo." & cal & ": `" & rd & "` is not a " &
                "template id"
          inc r.badIds
          inc r.problems
        total = total + child(child(ammo, cal), rd).asInt(0)
      if total <= 0:
        error "  " & label & ".Ammo." & cal & ": total weight " & $total
        inc r.badWeights
        inc r.problems

  # --- the two halves of one decision: a chance and a pool.
  if chances.found:
    let ce = child(chances, "equipment")
    if ce.found:
      let named = keys(ce)
      for slot in named:
        inc r.chanceKeys
        let pct = child(ce, slot).asInt(-1)
        if pct < 0 or pct > 100:
          error "  " & label & ".chances.equipment." & slot & ": " & $pct &
                " is not a percentage"
          inc r.badWeights
          inc r.problems
        if pct > 0 and not contains(pooled, slot):
          # Not fatal: the shared template may carry the pool. Counted anyway,
          # because in this mod's own layout the loadout is where pools live,
          # and a chance without one here is usually a rename that only got
          # done on one side.
          inc r.orphanChances
      for slot in pooled:
        if not child(ce, slot).found and not contains(templateChances, slot):
          error "  " & label & ": a pool for " & slot & " and no chance for " &
                "it in either this file or the bot template. An unnamed " &
                "chance is 0, so every id in that pool is unreachable"
          inc r.orphanPools
          inc r.problems

# ---------------------------------------------------------------------------
# The bot templates
# ---------------------------------------------------------------------------

proc chanceKeysOf*(text: string): seq[string] =
  ## The equipment-chance key set of a bot template, for the loadout check.
  result = @[]
  if text.len < 3:
    return
  let ce = child(child(whole(text), "chances"), "equipment")
  if ce.found:
    result = keys(ce)

proc checkTemplate*(label, text: string; r: var Report) =
  if text.len < 3:
    error "  " & label & ": missing or empty"
    inc r.problems
    return
  let doc = whole(text)

  # Appearance is the one part of a bot template the emulator reads, and it
  # reads index 0 of each list and nothing else. So an empty list is a bot with
  # a null body, and a list whose *first* entry is the broken one is a bot with
  # a null body even though the list has four good ids after it.
  let app = child(doc, "appearance")
  let wanted = ["head", "body", "feet", "hands"]
  for part in wanted:
    let lst = child(app, part)
    if not lst.found or count(lst) == 0:
      error "  " & label & ".appearance." & part & ": empty. The server reads " &
            "index 0 of this list for every bot it generates, so the bot has " &
            "no " & part & " at all"
      inc r.problems
      continue
    let entries = each(lst)
    for e in entries:
      let id = e.asText("")
      if not isMongoId(id):
        error "  " & label & ".appearance." & part & ": `" & id &
              "` is not a customisation id"
        inc r.badIds
        inc r.problems

  # Health likewise: `health.BodyParts[0]` is taken whole as the bot's health.
  let bp = child(doc, "health")
  let parts = child(bp, "BodyParts")
  if not parts.found or count(parts) == 0:
    error "  " & label & ".health.BodyParts: empty, so every bot of this type " &
          "falls back to the generator's stock 35/85/70 human and this " &
          "template's health tuning does nothing"
    inc r.problems
  else:
    let first = at(parts, 0)
    let need = ["Head", "Chest", "Stomach", "LeftArm", "RightArm",
                "LeftLeg", "RightLeg"]
    for limb in need:
      if not child(first, limb).found:
        error "  " & label & ".health.BodyParts[0]: no `" & limb &
              "`. The client reads every body part by name; a missing one is " &
              "a bot it cannot spawn"
        inc r.problems

  # Names. The emulator picks by `index mod n`, deterministically, so the list's
  # *contents* are visible in every raid and a junk entry is not cosmetic.
  let first = child(doc, "firstName")
  var seen: seq[string] = @[]
  if not first.found or count(first) == 0:
    error "  " & label & ".firstName: empty; every bot is named `<role>_<n>`"
    inc r.problems
  else:
    let entries = each(first)
    for e in entries:
      let n = e.asText("")
      inc r.names
      if n.len == 0:
        error "  " & label & ".firstName: an empty name"
        inc r.problems
      elif contains(seen, n):
        error "  " & label & ".firstName: `" & n & "` appears twice"
        inc r.duplicates
        inc r.problems
      else:
        seen.add n

proc checkAchievements*(label, text, localeText: string; r: var Report) =
  ## Unique ids, and a locale string for each — an achievement with no locale
  ## shows the player its raw MongoId, which is worse than not shipping it.
  if text.len < 3:
    return
  let list = each(whole(text))
  var ids: seq[string] = @[]
  let loc = whole(localeText)
  for a in list:
    let id = field(a, "id").asText("")
    if not isMongoId(id):
      error "  " & label & ": `" & id & "` is not a well-formed achievement id"
      inc r.badIds
      inc r.problems
      continue
    if contains(ids, id):
      error "  " & label & ": achievement " & id & " is listed twice"
      inc r.duplicates
      inc r.problems
      continue
    ids.add id
    if not child(loc, id & " name").found and
       not child(loc, id & " Name").found:
      warn "  " & label & ": achievement " & id & " has no locale name; the " &
           "player would see the raw id"
      inc r.orphanChances

# ---------------------------------------------------------------------------
# With a database attached
# ---------------------------------------------------------------------------
#
# This section header sat over nothing for as long as the file's own comment
# above promised a `checkAgainstDatabase` "below", and `config.json` promised
# that `aowl run mods/blackdivision` "names the ids it cannot verify". Neither
# was true: there was no database pass anywhere in this mod. A promise in a
# config file that the code does not keep is worse than no promise, because the
# person reading it stops looking.
#
# **What the check is, and what it is not.** It is not "does every id exist" —
# that question has a wrong answer built into this mod's own data. Dozens of ids
# in the shipped loadouts are WTT-ContentBackport's rigs, packs and face covers
# and are legitimately absent from a stock database -- 44 of 850 measured, and
# 146 of 967 with the Armory loadout switched on; a pass that reported those as
# faults would produce a screenful of errors on a correct install and teach its
# reader to ignore the whole section. (The figure here used to be "eighteen",
# from before anything counted them.)
#
# The question with no wrong answer is asked **per pool**: after removing the
# ids this database does not have, *can this slot still roll anything*? An
# equipment pool with three ids where two are WTT content is a bot that
# sometimes wears the third — fine, and worth seeing. An equipment pool where
# every id is absent is a slot that is **always bare**, which is a bot with no
# gun, and it is indistinguishable at a glance from the working case.
#
# That is exactly the `armoryLoadouts` failure `config.json` warns about: all
# eleven weapon ids in `armory-blackdivassault.json` belong to WTT-Armory, so
# without that mod the assault role's primary-weapon pool is empty and those
# bots spawn unarmed. Nothing checked it before this. Now the check names it,
# and the same rule catches the next content dependency without being told
# about it.
#
# **`_id` rather than the whole item.** The probe reads
# `templates.items.<id>._id`, a short string, because `dbRead` copies the
# object at the path and the item documents are large — `templates.items` is
# 4.25 MB on a real import. Three hundred whole item documents to answer three
# hundred yes/no questions is a self-test nobody runs twice.
#
# **No database is not a pass.** The caller says whether one is attached, from
# a probe it has already done, and with none the pass reports `unchecked` and
# says what running with `--db` would settle. A check that quietly returns "no
# problems" because it never ran is the failure species this whole file exists
# to catch.

type
  DbCheck* = object
    ## What one database pass found. Counts, and the names behind them.
    attached*: bool
    ids*: int            ## distinct ids put to the database
    present*: int
    absent*: int
    pools*: int          ## pools examined (equipment slots and calibers)
    emptiedPools*: int   ## pools where nothing at all resolved
    emptied*: seq[string]
    emptiedArmed*: seq[string]
      ## The subset of `emptied` that is a **weapon** slot.
      ##
      ## Split out because the two are not the same severity and this file has
      ## already decided that question once, for maps: a hunt map with no
      ## spawn points is reported and does not fail the self-test, because it
      ## is a fact about the database attached rather than about this mod's
      ## data. An absent WTT rig is the same kind of fact — the same loadout
      ## against a database with WTT content installed has no empty pool at
      ## all — and a verdict that depends on which database happens to be
      ## lying around is useless as a gate.
      ##
      ## A weapon slot is where that stops. A bot with no rig is a worse bot;
      ## a bot with no gun is not a bot. That one fails.
    absentIds*: seq[string]

const
  WeaponSlots* = [
    "FirstPrimaryWeapon", "SecondPrimaryWeapon", "Holster", "Scabbard"]
    ## The four slots whose emptiness is not a cosmetic loss.

proc isWeaponSlot*(s: string): bool =
  for k in WeaponSlots:
    if k == s:
      return true
  result = false

proc emptyDbCheck*(): DbCheck =
  DbCheck(attached: false, ids: 0, present: 0, absent: 0, pools: 0,
          emptiedPools: 0, emptied: @[], emptiedArmed: @[], absentIds: @[])

proc itemExists(id: string): bool =
  ## One id, against `templates.items`.
  ##
  ## Shape is checked first and a malformed id is answered `false` without
  ## touching the database: `isMongoId` already reported it as a fault, and
  ## asking the database about `5E00C1AD...` would add a second, differently
  ## worded complaint about the same typo.
  if not isMongoId(id):
    return false
  let v = dbRead("templates.items." & id & "._id")
  result = v.ok and v.raw.len > 2

proc noteId(c: var DbCheck; id: string; seen: var seq[string]): bool =
  ## Probe one id at most once across the whole pass, and return whether the
  ## database has it. Deduplicated because the same rig appears in four role
  ## loadouts and four identical `dbRead`s is three wasted copies and three
  ## duplicate lines in the absent list.
  var known = -1
  for k in 0 ..< seen.len:
    if seen[k] == id:
      known = k
  if known >= 0:
    # Already probed. Its verdict is whether it landed in `absentIds`.
    for a in c.absentIds:
      if a == id:
        return false
    return true
  seen.add id
  inc c.ids
  if itemExists(id):
    inc c.present
    return true
  inc c.absent
  c.absentIds.add id
  result = false

proc checkPools(label: string; doc: JsonRef; c: var DbCheck;
                seen: var seq[string]) =
  ## Every pool in one loadout document, by the "can it still roll" rule.
  let inv = child(doc, "inventory")
  if not inv.found:
    return

  let equip = child(inv, "equipment")
  if equip.found:
    for slot in keys(equip):
      let pool = child(equip, slot)
      let ids = keys(pool)
      if ids.len == 0:
        continue
      inc c.pools
      var live = 0
      for id in ids:
        if noteId(c, id, seen):
          inc live
      if live == 0:
        inc c.emptiedPools
        let line = label & "." & slot & " (" & $ids.len & " id(s), none in " &
                   "this database)"
        c.emptied.add line
        if isWeaponSlot(slot):
          c.emptiedArmed.add line

  let ammo = child(inv, "Ammo")
  if ammo.found:
    for cal in keys(ammo):
      let rounds = keys(child(ammo, cal))
      if rounds.len == 0:
        continue
      inc c.pools
      var live = 0
      for rd in rounds:
        if noteId(c, rd, seen):
          inc live
      if live == 0:
        inc c.emptiedPools
        c.emptied.add label & ".Ammo." & cal & " (" & $rounds.len &
                      " round(s), none in this database)"

  # The mod graph is probed for presence but is not subject to the pool rule: a
  # weapon whose attachments are all absent is still a weapon, and the game
  # attaches what it can find. Counted so the absent list is complete.
  let mods1 = child(inv, "mods")
  if mods1.found:
    for root in keys(mods1):
      discard noteId(c, root, seen)
      let slots = child(mods1, root)
      for slot in keys(slots):
        for e in each(child(slots, slot)):
          let id = e.asText("")
          if id.len > 0:
            discard noteId(c, id, seen)

proc checkAgainstDatabase*(labels, texts: seq[string];
                           attached: bool): DbCheck =
  ## Every id in every shipped loadout, against the database that is loaded.
  ##
  ## `attached` is passed in rather than probed here, because the caller has
  ## already answered it — `locationExists` on a hunt map — and a second probe
  ## would be a second thing that can disagree. With no database this returns
  ## immediately with `attached: false` and every count zero, and the caller is
  ## expected to report that as *unchecked* and never as *clean*.
  var c = emptyDbCheck()
  c.attached = attached
  if not attached:
    return c
  var seen: seq[string] = @[]
  for i in 0 ..< labels.len:
    if i >= texts.len:
      break
    if texts[i].len < 3:
      continue
    let doc = whole(texts[i])
    if not isObject(doc):
      continue
    checkPools(labels[i], doc, c, seen)
  result = c

proc describeDbCheck*(c: DbCheck): string =
  ## Counts, never a verdict.
  if not c.attached:
    return "no database attached, so 0 of this mod's template ids were " &
           "verified. Run `aowlspt-sim mods/blackdivision --side sim --db " &
           "<file>` to settle it; until then an id that resolves to nothing " &
           "and an id that resolves are the same thing here"
  result = $c.present & " of " & $c.ids & " distinct template id(s) are in " &
           "this database (" & $c.absent & " absent) across " & $c.pools &
           " pool(s)"
  if c.emptiedPools > 0:
    result = result & "; " & $c.emptiedPools & " pool(s) have nothing left " &
             "that can roll, " & $c.emptiedArmed.len & " of them weapon slot(s)"

proc summarise*(r: Report): string =
  ## The counts, in one line, because a number is the only thing that
  ## distinguishes a complete data set from a plausible fragment.
  result = $r.files & " file(s): " & $r.equipmentIds & " equipment id(s) " &
           "across " & $r.equipmentSlots & " slot(s), " & $r.modRoots &
           " mod root(s) with " & $r.modRefs & " reference(s), " &
           $r.ammoRounds & " round(s) in " & $r.ammoCalibers & " caliber(s), " &
           $r.chanceKeys & " equipment chance(s), " & $r.names & " name(s)"
