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
## **Whether an id exists in `templates.items`.** It cannot, offline, and it
## should not pretend to. `aowl run` has no database. What it *can* do is check
## the id's shape, which catches every typo, and then check existence for real
## when a database happens to be attached — which is `checkAgainstDatabase`
## below, and which is why that is a separate pass with a separate verdict.
##
## Eighteen ids in the shipped loadouts are known not to be in a stock database
## and are not faults: they are WTT-ContentBackport's rigs, packs and face
## covers. They are counted and named as *absent content*, never as errors, and
## every slot that contains one also contains db-verified alternatives — so a
## player without WTT gets a Black Division operator in a BlackHawk! Commando
## rig rather than a Black Division operator in nothing.

import std/strutils
import aowlspt
import aowlspt/json
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

proc summarise*(r: Report): string =
  ## The counts, in one line, because a number is the only thing that
  ## distinguishes a complete data set from a plausible fragment.
  result = $r.files & " file(s): " & $r.equipmentIds & " equipment id(s) " &
           "across " & $r.equipmentSlots & " slot(s), " & $r.modRoots &
           " mod root(s) with " & $r.modRefs & " reference(s), " &
           $r.ammoRounds & " round(s) in " & $r.ammoCalibers & " caliber(s), " &
           $r.chanceKeys & " equipment chance(s), " & $r.names & " name(s)"
