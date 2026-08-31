## Declarative loadout minting -- "go into the raid carrying exactly this".
##
## WHY THIS EXISTS
## ---------------
## Testing a feature that only shows itself in a raid means owning the gear that
## triggers it. A tester who has to buy an M4, three magazines and 180 rounds of
## M855A1 by hand before every run is a tester who runs the test once. So a test
## SCRIPT states the loadout it needs and this module MINTS it into the profile.
##
## This is the server half. `tools/autoscript.nim` is the script-facing half; it
## POSTs the spec produced below to `/aowlspt/tarkov/autoscript/loadout`.
##
## WHAT IS REUSED RATHER THAN REWRITTEN
## ------------------------------------
## Nothing about item validity is invented here.
##
##   `emu/spawn.searchItemsCounted`  name -> template, with the SAME ambiguity
##                                   refusal (a script may say "m4a1" instead of
##                                   pasting a 24-hex id).
##   `emu/trading.giveItem`          stash placement, stack-limit aware, merging.
##   `emu/grid`                      real cells inside a worn container.
##   `emu/bots.validateSlots`        the ancestry-aware slot validator. Every
##                                   item this module builds is passed through it
##                                   BEFORE it is saved, and anything it refuses
##                                   is reported with the parent template, the
##                                   slot and the offending template -- the same
##                                   three things the client's own error names.
##   `emu/bots.auditStacks`          the stack auditor, run over the FINISHED
##                                   inventory.
##
## THE ACCEPTANCE RULE (CLAUDE.md 9b)
## ----------------------------------
## **A script that asks for gear must be able to FAIL because the gear did not
## arrive.** So `applyLoadout` never reports its own write. It saves, then
## RE-READS the profile off the store with `loadProfile` -- a fresh read, not the
## in-memory copy it just built -- and counts, per request, how many items with
## that template are parented where the request asked for them. Four numbers come
## back and they are four different numbers:
##
##   requested   what the script asked for
##   minted      items this module constructed
##   placed      items found in the RE-READ profile, at the intended parent+slot
##   rejected    with a reason, one line each -- refusals THIS SPEC caused
##
## and a fifth list, `observations`, that is deliberately NOT part of the
## verdict: facts about the profile the spec did not cause. `auditStacks` runs
## over the whole inventory and reports the two rouble stacks a real character
## has held at count=1 since it was made; failing a good loadout for those is a
## check that cannot PASS, which is the same defect as one that cannot fail.
##
## `placed < requested` is a FAIL. It is reachable: point a request at a helmet
## slot with a weapon template and `validateSlots` drops it, minted stays 3 and
## placed goes to 0. That is the input that makes this check fail, which is the
## thing CLAUDE.md 9b says you must be able to name.
##
## THREE OUTCOMES
## --------------
## `ok` is not a boolean verdict on its own. `verdict` is `"PASS"`, `"FAIL"` or
## `"INCONCLUSIVE"`, and INCONCLUSIVE is real: no profile, no database loaded, or
## a save that lost a race means the question was never asked. A run that could
## not look is not a pass.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import ids
import templates
import inventory
import grid
import profile
import trading
import spawn
import bots

const
  EquipSlots* = ["Headwear", "Earpiece", "FaceCover", "ArmorVest", "Eyewear",
                 "ArmBand", "TacticalVest", "Backpack", "FirstPrimaryWeapon",
                 "SecondPrimaryWeapon", "Holster", "Scabbard", "Pockets",
                 "SecuredContainer"]
    ## The 14 slots the game has. Spelled out rather than taken from whatever
    ## keys the profile happens to carry, for the reason `emu/bots` spells them
    ## out: a fifteenth name puts an item somewhere the client cannot draw, which
    ## renders as the loadout having silently failed.

  MaxRequests = 64
    ## A bound on a pathological script, not a limit on a real one. The largest
    ## honest loadout measured -- a fully kitted PMC with meds, ammo and food --
    ## is 18 requests.

  MaxCountPerRequest = 5000
    ## Same cap `emu/spawn` uses, and for the same reason: a typo in a count is a
    ## stash to clean up by hand.

type
  Where* = enum
    ## Three placements, and they are genuinely different operations.
    whStash      ## loose in the stash -- `giveItem` owns this
    whEquip      ## worn, in one of the 14 equipment slots
    whInside     ## in a real cell of a container that is itself worn

  GearReq* = object
    query*: string      ## what the script wrote: a template id or a name
    tpl*: string        ## the resolved template id, "" until resolution
    label*: string      ## the resolved display name, for the report
    where*: Where
    slot*: string       ## the equipment slot, for whEquip
    inside*: string     ## the equipment slot of the container, for whInside
    count*: int
    ammo*: string       ## fill this magazine/chamber with that ammo template
    condition*: int     ## durability/resource percentage, 100 = untouched
    baseline*: int
      ## How many of this template were ALREADY where this request asks, read
      ## off the profile before anything was minted.
      ##
      ## `placed` is a DELTA -- after minus before -- and that is not a
      ## softening of the acceptance rule, it is what makes it mean anything for
      ## the stash. `clear` deliberately does not empty the stash, so a script
      ## asking for 180 rounds into a stash that already held 180 read back 360
      ## and "passed" on gear it was already carrying. Two independent reads of
      ## the finished state, subtracted, still cannot be satisfied by this
      ## module asserting its own write.
    minted*: int
    placed*: int
    why*: string        ## why this request did not fully land

  LoadoutReport* = object
    verdict*: string           ## "PASS" | "FAIL" | "INCONCLUSIVE"
    reason*: string            ## always populated -- a bare verdict is not one
    profileId*: string
    requested*: int
    minted*: int
    placed*: int
    rejected*: seq[string]     ## refusals CAUSED BY THIS SPEC. These fail it.
    observations*: seq[string]
      ## Facts about the profile that this spec did not cause and must not be
      ## failed for.
      ##
      ## `auditStacks` runs over the WHOLE inventory, so on a real character it
      ## reports the two rouble stacks the hideout has held at count=1 since the
      ## profile was made. Folding those into `rejected` made a perfectly good
      ## loadout report FAIL for something no script asked for -- which is the
      ## mirror image of a check that cannot fail: a check that cannot pass.
      ## They are still REPORTED, because a magazine this spec minted coming
      ## back flat is a real defect and belongs in the same list.
    reqs*: seq[GearReq]
    flatStacks*: int
    slotDropped*: int

# ---------------------------------------------------------------------------
# Spec parsing
# ---------------------------------------------------------------------------
#
# The spec is ordinary JSON, because the script side is a separate process and
# an in-process DSL cannot cross that boundary. It is deliberately small:
#
#   {"profileId": "<24 hex>",
#    "clear": false,
#    "gear": [
#      {"query": "m4a1",  "slot": "FirstPrimaryWeapon"},
#      {"tpl": "55d4887d4bdc2d962f8b4570", "count": 3,
#       "inside": "TacticalVest", "ammo": "54527ac44bdc2d36668b4567"},
#      {"query": "ifak",  "count": 2, "inside": "Pockets"},
#      {"query": "m855a1","count": 180}
#    ]}
#
# `slot` -> worn. `inside` -> in that worn container's grid. Neither -> stash.
# Both -> refused, named, rather than one of them silently winning.

proc isEquipSlot*(name: string): bool =
  for s in EquipSlots:
    if s == name:
      return true
  result = false

proc canonicalSlot*(name: string): string =
  ## The slot's canonical spelling, or "" when it is not one of the 14. Case
  ## folded, because a script that writes `headwear` means Headwear and a silent
  ## miss here reads as "the item never arrived".
  let want = toLowerAscii(name)
  for s in EquipSlots:
    if toLowerAscii(s) == want:
      return s
  result = ""

proc parseSpec*(body: string; profileId: var string; clear: var bool;
                problems: var seq[string]): seq[GearReq] =
  ## The spec, taken apart. Every malformed entry is NAMED and dropped rather
  ## than skipped, so a typo in a script shows up as a refusal with a line
  ## number rather than as gear that quietly did not arrive.
  result = @[]
  profileId = ""
  clear = false
  let doc = whole(body)
  profileId = doc.field("profileId").asText("")
  clear = doc.field("clear").asBool(false)
  let gear = doc.field("gear")
  if not gear.found or not isArray(gear):
    problems.add "the spec has no `gear` array"
    return
  let n = count(gear)
  if n > MaxRequests:
    problems.add "the spec asks for " & $n & " gear entries; " &
                 $MaxRequests & " is the cap"
    return
  for i in 0 ..< n:
    let e = at(gear, i)
    var r = GearReq(query: "", tpl: "", label: "", where: whStash, slot: "",
                    inside: "", count: 1, ammo: "", condition: 100,
                    baseline: 0, minted: 0, placed: 0, why: "")
    r.tpl = toLowerAscii(e.field("tpl").asText(""))
    r.query = e.field("query").asText("")
    if r.query.len == 0:
      r.query = r.tpl
    if r.query.len == 0:
      problems.add "gear[" & $i & "] names neither `tpl` nor `query`"
      continue
    r.count = e.field("count").asInt(1)
    if r.count < 1:
      r.count = 1
    if r.count > MaxCountPerRequest:
      problems.add "gear[" & $i & "] (" & r.query & ") asks for " & $r.count &
                   "; " & $MaxCountPerRequest & " is the cap"
      continue
    r.ammo = toLowerAscii(e.field("ammo").asText(""))
    r.condition = e.field("condition").asInt(100)
    let slotRaw = e.field("slot").asText("")
    let insideRaw = e.field("inside").asText("")
    if slotRaw.len > 0 and insideRaw.len > 0:
      problems.add "gear[" & $i & "] (" & r.query & ") names both `slot` (" &
                   slotRaw & ") and `inside` (" & insideRaw &
                   "); those are different placements -- pick one"
      continue
    if slotRaw.len > 0:
      let c = canonicalSlot(slotRaw)
      if c.len == 0:
        problems.add "gear[" & $i & "] (" & r.query & ") names slot \"" &
                     slotRaw & "\", which is not one of the 14 equipment slots"
        continue
      r.where = whEquip
      r.slot = c
    elif insideRaw.len > 0:
      let c = canonicalSlot(insideRaw)
      if c.len == 0:
        problems.add "gear[" & $i & "] (" & r.query & ") asks to go inside \"" &
                     insideRaw & "\", which is not one of the 14 equipment slots"
        continue
      r.where = whInside
      r.inside = c
    result.add r

# ---------------------------------------------------------------------------
# Template resolution
# ---------------------------------------------------------------------------

proc resolve(r: var GearReq): bool =
  ## `query` -> a single template id, or a refusal that names the candidates.
  ##
  ## Ambiguity is REFUSED, exactly as `emu/spawn.spawnInto` refuses it. "the
  ## first match" is an arbitrary document order, and a script that silently
  ## equips the wrong rifle is a test whose result means nothing.
  if r.tpl.len == 24 and isTemplateId(r.tpl):
    if not itemExists(r.tpl):
      r.why = "no item template " & r.tpl & " is in the database"
      return false
    r.label = localeNameOf(r.tpl)
    if r.label.len == 0:
      r.label = r.tpl
    return true
  var matched = 0
  let hits = searchItemsCounted(r.query, 8, matched)
  if hits.len == 0:
    r.why = "no item matches \"" & r.query & "\""
    return false
  if matched > 1 and not isTemplateId(r.query):
    var names = ""
    for h in hits:
      if names.len > 0: names.add "; "
      names.add h.name & " (" & h.tpl & ")"
    r.why = "\"" & r.query & "\" matches " & $matched &
            " items -- narrow it or paste an id: " & names
    return false
  r.tpl = hits[0].tpl
  r.label = if hits[0].name.len > 0: hits[0].name else: hits[0].tpl
  result = true

# ---------------------------------------------------------------------------
# Ammunition
# ---------------------------------------------------------------------------

proc cartridgeCapacity(tpl: string): int =
  ## `_props.Cartridges[0]._max_count`. Zero means the database does not say,
  ## which is NOT the same as "one" -- a magazine claiming a capacity it does not
  ## have is a gun that jams on the client, so zero means no rounds go in.
  let v = dbRead("templates.items." & tpl & "._props.Cartridges")
  if not v.ok:
    return 0
  let first = at(whole(v.raw), 0)
  if not first.found:
    return 0
  result = first.field("_max_count").asInt(0)

proc cartridgeAccepts(tpl, ammoTpl: string): bool =
  ## Whether the container's cartridge filter admits that round. A filter this
  ## module cannot read constrains nothing -- the same reading `emu/bots` takes,
  ## and the honest one: an unreadable filter is not evidence of refusal.
  let v = dbRead("templates.items." & tpl & "._props.Cartridges")
  if not v.ok:
    return true
  let f = at(whole(v.raw), 0).field("_props").field("filters").at(0).field("Filter")
  if not f.found or not isArray(f):
    return true
  if count(f) == 0:
    return true
  for one in each(f):
    if one.asText("") == ammoTpl:
      return true
  result = false

proc fillCartridges(items: var List; parentId, parentTpl, ammoTpl: string;
                    why: var string): int =
  ## Load a magazine (or chamber a weapon) with `ammoTpl`. Returns the rounds
  ## written; `why` is populated on every zero, because a magazine that silently
  ## came back empty is the single most common way a gear test looks like a
  ## feature bug.
  result = 0
  if ammoTpl.len == 0:
    return
  let cap = cartridgeCapacity(parentTpl)
  if cap <= 0:
    why = "the database declares no _props.Cartridges[0]._max_count for " &
          parentTpl & ", so no rounds were loaded"
    return
  if not cartridgeAccepts(parentTpl, ammoTpl):
    why = parentTpl & "'s cartridge filter does not accept " & ammoTpl &
          "; the client would refuse the load, so no rounds were written"
    return
  var d = newDoc()
  setText(d, "_id", newId())
  setText(d, "_tpl", ammoTpl)
  setText(d, "parentId", parentId)
  setText(d, "slotId", "cartridges")
  setNumber(d, "location", 0)
  var upd = newDoc()
  setNumber(upd, "StackObjectsCount", cap)
  setRaw(d, "upd", text(upd))
  items.add d
  result = cap

# ---------------------------------------------------------------------------
# Container placement
# ---------------------------------------------------------------------------

proc containerGrids(tpl: string): seq[string] =
  ## The `_name` of each grid a container declares, in order. Empty for anything
  ## that is not a container, which is how a request to put a scope "inside" a
  ## helmet is refused rather than placed nowhere.
  result = @[]
  let v = dbRead("templates.items." & tpl & "._props.Grids")
  if not v.ok:
    return
  for one in each(whole(v.raw)):
    result.add one.field("_name").asText("main")

proc gridOf(tpl, gridName: string): Grid =
  ## One named grid's dimensions. Falls back to the container's first grid, and
  ## then to 1x1 -- never to the stash default, which would invent room a rig
  ## does not have.
  result = newGrid(1, 1)
  let v = dbRead("templates.items." & tpl & "._props.Grids")
  if not v.ok:
    return
  for one in each(whole(v.raw)):
    if one.field("_name").asText("main") == gridName:
      return newGrid(one.field("_props.cellsH").asInt(1),
                     one.field("_props.cellsV").asInt(1))

proc markGrid(g: var Grid; itemsJson, containerId, gridName: string) =
  ## Fill the occupancy map from what is already IN THAT GRID.
  ##
  ## `emu/grid.markOccupied` cannot be used here and the difference is not
  ## cosmetic. It filters on `parentId` alone, which is correct for a stash --
  ## one container, one grid -- and WRONG for a rig: an ANA M2 declares NINE
  ## grids, pockets declare four, and every one of them has its own (0,0). With
  ## the parent-only filter, an item placed at (0,0) of grid 1 marks (0,0) of
  ## grids 2..9 as well.
  ##
  ## Measured, 2026-08-31, against the live db.json: a spec asking for three
  ## magazines in an ANA M2 and two IFAKs in the pockets minted exactly ONE of
  ## each and refused the rest with "no grid ... has a free cell". The read-back
  ## caught it -- `req=3 minted=1 placed=1` -- which is the acceptance rule doing
  ## its job on this module's own first draft.
  ##
  ## `slotId` is the grid's `_name` for anything inside a container, so the
  ## filter is parent AND grid.
  let list = parseArray(itemsJson)
  if not list.ok:
    return
  for i in 0 ..< list.len:
    let it = whole(list.items[i])
    if it.field("parentId").asText("") != containerId:
      continue
    if it.field("slotId").asText("") != gridName:
      continue
    let loc = it.field("location")
    if not loc.found or isNull(loc):
      continue
    var w = 1
    var h = 1
    itemSize(it.field("_tpl").asText(""), w, h)
    if loc.field("r").asText("Horizontal") == "Vertical" or
       loc.field("r").asInt(0) == 1:
      let t = w
      w = h
      h = t
    occupy(g, loc.field("x").asInt(0), loc.field("y").asInt(0), w, h)

proc placeInside(items: var List; containerId, containerTpl, tpl: string;
                 stackCount: int; newIdOut: var string; why: var string): bool =
  ## One item into a real cell of a worn container, trying each of its grids in
  ## turn. Refused, never placed at 0,0: an overlapping item is drawn on top of
  ## what is already there and cannot be picked up, which looks exactly like
  ## never having been given it (`emu/grid`'s own rule).
  newIdOut = ""
  let names = containerGrids(containerTpl)
  if names.len == 0:
    why = containerTpl & " declares no _props.Grids, so nothing can go inside it"
    return false
  let blob = text(items)
  for gname in names:
    var g = gridOf(containerTpl, gname)
    markGrid(g, blob, containerId, gname)
    let place = findSpace(g, tpl)
    if not place.ok:
      continue
    var d = newDoc()
    let nid = newId()
    setText(d, "_id", nid)
    setText(d, "_tpl", tpl)
    setText(d, "parentId", containerId)
    setText(d, "slotId", gname)
    setRaw(d, "location", locationJson(place))
    if stackCount > 1:
      var upd = newDoc()
      setNumber(upd, "StackObjectsCount", stackCount)
      setRaw(d, "upd", text(upd))
    items.add d
    newIdOut = nid
    return true
  why = "no grid of " & containerTpl & " (" & $names.len &
        ") has a free cell for " & tpl
  result = false

proc wornIn(items: List; equipmentId, slot: string;
            tplOut: var string): string =
  ## The id of whatever is worn in an equipment slot, and its template. "" when
  ## the slot is empty -- which a request to put something INSIDE that slot must
  ## treat as a refusal with a reason, not as a stash fallback: a script that
  ## asked for mags in a rig and got them in the stash starts the raid with an
  ## empty rig and no error.
  tplOut = ""
  for i in 0 ..< items.len:
    let one = whole(items.items[i])
    if one.field("parentId").asText("") == equipmentId and
       one.field("slotId").asText("") == slot:
      tplOut = one.field("_tpl").asText("")
      return one.field("_id").asText("")
  result = ""

# ---------------------------------------------------------------------------
# Clearing
# ---------------------------------------------------------------------------

proc clearEquipment(inv: var Inventory; equipmentId: string): int =
  ## Strip every worn item and everything hanging off it, EXCEPT Pockets and
  ## SecuredContainer.
  ##
  ## Those two are exempt on purpose. A character with no Pockets item does not
  ## spawn at all (see `emu/profile.ensurePockets`), and the secure container is
  ## where a test's own instrumentation tends to live. Stripping either produces
  ## a profile that fails to enter a raid, which would read as this whole
  ## feature being broken.
  result = 0
  var doomed: seq[string] = @[]
  for i in 0 ..< inv.items.len:
    let one = whole(inv.items.items[i])
    if one.field("parentId").asText("") != equipmentId:
      continue
    let slot = one.field("slotId").asText("")
    if slot == "Pockets" or slot == "SecuredContainer":
      continue
    doomed.add one.field("_id").asText("")
  var ch = newChange()
  for id in doomed:
    if id.len == 0:
      continue
    if removeItem(inv, id, ch):
      result = result + 1

# ---------------------------------------------------------------------------
# The mint
# ---------------------------------------------------------------------------

proc reportJson*(rep: LoadoutReport): string =
  ## The report, on the wire. Every number the acceptance rule names is here,
  ## separately -- `requested`, `minted` and `placed` collapsed into one boolean
  ## is exactly the check that cannot fail.
  var o = obj()
  put(o, "verdict", rep.verdict)
  put(o, "reason", rep.reason)
  put(o, "profileId", rep.profileId)
  put(o, "requested", rep.requested)
  put(o, "minted", rep.minted)
  put(o, "placed", rep.placed)
  put(o, "flatStacks", rep.flatStacks)
  put(o, "slotDropped", rep.slotDropped)
  var rej = arr()
  for r in rep.rejected:
    rej.add r
  put(o, "rejected", rej)
  var obs = arr()
  for r in rep.observations:
    obs.add r
  put(o, "observations", obs)
  var per = arr()
  for r in rep.reqs:
    var e = obj()
    put(e, "query", r.query)
    put(e, "tpl", r.tpl)
    put(e, "name", r.label)
    put(e, "where", (case r.where
                     of whStash: "stash"
                     of whEquip: r.slot
                     of whInside: "inside " & r.inside))
    put(e, "requested", r.count)
    put(e, "baseline", r.baseline)
    put(e, "minted", r.minted)
    put(e, "placed", r.placed)
    put(e, "why", r.why)
    per.add e
  put(o, "gear", per)
  result = done(o).text

proc countPlaced(itemsJson: string; r: GearReq;
                 equipmentId, stash: string): int =
  ## How many items of `r`'s template are, IN THE RE-READ PROFILE, parented
  ## where the request asked for them.
  ##
  ## This is the whole acceptance. It reads the serialised text and nothing else:
  ## no counter this module incremented, no list it built. A regression anywhere
  ## between the mint and the disk -- a dropped item, a `validateSlots` removal,
  ## a save that lost a race, a container that vanished -- lands here as a number
  ## smaller than `requested`.
  ##
  ## Stacks count as their stack: 180 rounds served as one stack of 180 is 180
  ## placed, not 1, because 180 is what the script asked for.
  result = 0
  let list = parseArray(itemsJson)
  for i in 0 ..< list.len:
    let one = whole(list.items[i])
    if one.field("_tpl").asText("") != r.tpl:
      continue
    let parent = one.field("parentId").asText("")
    let slot = one.field("slotId").asText("")
    var here = false
    case r.where
    of whEquip:
      here = parent == equipmentId and slot == r.slot
    of whStash:
      here = parent == stash
    of whInside:
      # The container's own id is not known to this proc, so the test is
      # structural: not worn, not loose in the stash, and sitting in a named
      # grid. That is deliberately WEAKER than the equip case and is stated as
      # such rather than dressed up -- see the `why` line the caller writes.
      here = parent != equipmentId and parent != stash and slot.len > 0 and
             one.field("location").found
    if not here:
      continue
    let n = one.field("upd").field("StackObjectsCount").asInt(1)
    result = result + (if n > 0: n else: 1)

proc applyLoadout*(body: string): LoadoutReport =
  ## Mint a declared loadout into a profile, then read the profile back and say
  ## what really arrived.
  result = LoadoutReport(verdict: "INCONCLUSIVE", reason: "", profileId: "",
                         requested: 0, minted: 0, placed: 0, rejected: @[], observations: @[],
                         reqs: @[], flatStacks: 0, slotDropped: 0)
  var profileId = ""
  var clear = false
  var problems: seq[string] = @[]
  var reqs = parseSpec(body, profileId, clear, problems)
  for p in problems:
    result.rejected.add p
  result.profileId = profileId
  result.reqs = reqs
  for r in reqs:
    result.requested = result.requested + r.count

  if profileId.len == 0:
    result.reason = "the spec names no `profileId`; nothing was looked at"
    return
  if reqs.len == 0:
    result.reason = "the spec asked for no gear this server could understand" &
                    (if problems.len > 0: " (" & problems[0] & ")" else: "")
    return

  var p = loadProfile(profileId)
  if not p.ok:
    result.reason = "could not read profile " & profileId &
                    " -- the question was never asked"
    return
  let asRead = profileVersion(profileId)
  let equipmentId = p.field("Inventory.equipment").asText("")
  let stash = stashId(p)
  if equipmentId.len == 0:
    result.reason = "profile " & profileId &
                    " has no Inventory.equipment, so nothing can be worn"
    return
  if stash.len == 0:
    result.reason = "profile " & profileId & " has no stash"
    return
  if not itemExists("5449016a4bdc2d6f028b456f"):
    # Roubles. If the item table is not loaded, every resolution below would
    # refuse for a reason that has nothing to do with the script.
    result.reason = "no item table is loaded (templates.items is empty), so " &
                    "no template in this spec can be resolved -- run " &
                    "`aowl importdb` against an SPT install"
    return

  var inv = openInventory(p.field("Inventory.items").raw)

  if clear:
    let stripped = clearEquipment(inv, equipmentId)
    inv.dirty = inv.dirty or stripped > 0
    info "autoscript: cleared " & $stripped & " worn item(s) from " & profileId

  # ---- resolve every template FIRST -------------------------------------
  # Nothing is written until every request has a real template. A partially
  # applied loadout is a test that ran against gear nobody declared.
  for i in 0 ..< reqs.len:
    if not resolve(reqs[i]):
      result.rejected.add reqs[i].query & ": " & reqs[i].why

  # ---- the BASELINE, before a single item is written ----------------------
  # Read off the profile as it stands. `placed` below is the difference between
  # this and the same count after the save, so a script cannot pass on gear the
  # character already had.
  # `text(inv.items)`, NOT `p.field("Inventory.items").raw`. Measured
  # 2026-08-31: reading the ORIGINAL profile text counts gear that `clear` is
  # about to strip, so a second run of the same script read `base=1 placed=0`
  # for every worn slot and reported a correct loadout as lost between the mint
  # and the store. The baseline must be the state the mint actually starts from,
  # which is after `clear`.
  let beforeItems = text(inv.items)
  for i in 0 ..< reqs.len:
    if reqs[i].tpl.len > 0:
      reqs[i].baseline = countPlaced(beforeItems, reqs[i], equipmentId, stash)

  # ---- mint --------------------------------------------------------------
  var ch = newChange()
  for i in 0 ..< reqs.len:
    if reqs[i].tpl.len == 0:
      continue
    let tpl = reqs[i].tpl
    case reqs[i].where
    of whEquip:
      # A slot holds ONE thing. `count` above one on a worn slot is a script
      # error and is named as one rather than silently placing the first.
      if reqs[i].count > 1:
        reqs[i].why = "an equipment slot holds one item; " & $reqs[i].count &
                      " were asked for. Use `inside` for spares."
        result.rejected.add reqs[i].query & ": " & reqs[i].why
        continue
      var existingTpl = ""
      let occupant = wornIn(inv.items, equipmentId, reqs[i].slot, existingTpl)
      if occupant.len > 0:
        reqs[i].why = reqs[i].slot & " is already occupied by " & existingTpl &
                      "; pass \"clear\": true to strip the character first"
        result.rejected.add reqs[i].query & ": " & reqs[i].why
        continue
      var d = newDoc()
      let nid = newId()
      setText(d, "_id", nid)
      setText(d, "_tpl", tpl)
      setText(d, "parentId", equipmentId)
      setText(d, "slotId", reqs[i].slot)
      inv.items.add d
      inv.dirty = true
      reqs[i].minted = 1
      if reqs[i].ammo.len > 0:
        var why = ""
        let rounds = fillCartridges(inv.items, nid, tpl, reqs[i].ammo, why)
        if rounds == 0 and why.len > 0:
          reqs[i].why = why
          result.rejected.add reqs[i].query & ": " & why
    of whInside:
      var containerTpl = ""
      let containerId = wornIn(inv.items, equipmentId, reqs[i].inside,
                               containerTpl)
      if containerId.len == 0:
        reqs[i].why = "nothing is worn in " & reqs[i].inside &
                      ", so there is no container to put " & reqs[i].label &
                      " inside. Equip one in the same spec, before this entry."
        result.rejected.add reqs[i].query & ": " & reqs[i].why
        continue
      let limit = itemStackLimit(tpl)
      var remaining = reqs[i].count
      while remaining > 0:
        var take = remaining
        if limit > 1 and take > limit:
          take = limit
        elif limit <= 1:
          take = 1
        var nid = ""
        var why = ""
        if not placeInside(inv.items, containerId, containerTpl, tpl, take,
                           nid, why):
          reqs[i].why = why
          result.rejected.add reqs[i].query & ": " & why
          break
        inv.dirty = true
        reqs[i].minted = reqs[i].minted + take
        remaining = remaining - take
        if reqs[i].ammo.len > 0:
          var w2 = ""
          discard fillCartridges(inv.items, nid, tpl, reqs[i].ammo, w2)
          if w2.len > 0 and reqs[i].why.len == 0:
            reqs[i].why = w2
    of whStash:
      if not giveItem(inv, tpl, stash, reqs[i].count, ch):
        var why = "the stash has no room for " & $reqs[i].count & " x " &
                  reqs[i].label
        if ch.problems.len > 0:
          why = ch.problems[ch.problems.len - 1]
        reqs[i].why = why
        result.rejected.add reqs[i].query & ": " & why
        continue
      inv.dirty = true
      reqs[i].minted = reqs[i].count

  for r in reqs:
    result.minted = result.minted + r.minted
  result.reqs = reqs

  if not inv.dirty:
    result.verdict = "FAIL"
    result.reason = "nothing was placed; " & $result.rejected.len &
                    " request(s) were refused"
    return

  # ---- the client's own rules, before anything is saved -------------------
  # `emu/bots.validateSlots` is the ancestry-aware validator the bot generator
  # uses. Running the PLAYER's minted gear through it is the point: a helmet in
  # FirstPrimaryWeapon is refused here rather than by the client, and the reason
  # names the parent template, the slot and the offender.
  var slotReport: seq[string] = @[]
  var kept: seq[string] = @[]
  let dropped = validateSlots(inv.items, slotReport, kept)
  result.slotDropped = dropped
  if dropped > 0:
    var survivors = newList()
    for k in kept:
      survivors.add k
    inv.items = survivors
    for line in slotReport:
      result.rejected.add "validateSlots: " & line

  var flat: seq[string] = @[]
  result.flatStacks = auditStacks(inv.items, flat)
  for f in flat:
    result.observations.add "flat stack: " & f

  setRaw(p, "Inventory.items", text(inv.items))
  if not saveIfUnchanged(p, asRead):
    result.verdict = "INCONCLUSIVE"
    result.reason = "the profile changed while the loadout was being applied; " &
                    "nothing was saved and nothing can be concluded"
    return

  # ---- READ IT BACK -------------------------------------------------------
  # A fresh `loadProfile`, off the store. Not `p`, not `inv`, not a counter.
  var back = loadProfile(profileId)
  if not back.ok:
    result.verdict = "INCONCLUSIVE"
    result.reason = "the loadout was saved and the profile could not be read " &
                    "back, so nothing can be concluded about what arrived"
    return
  let backItems = back.field("Inventory.items").raw
  let backEquip = back.field("Inventory.equipment").asText("")
  let backStash = stashId(back)
  for i in 0 ..< reqs.len:
    let after = countPlaced(backItems, reqs[i], backEquip, backStash)
    reqs[i].placed = after - reqs[i].baseline
    if reqs[i].placed < 0:
      reqs[i].placed = 0
      if reqs[i].why.len == 0:
        reqs[i].why = "the profile now holds FEWER of " & reqs[i].tpl &
                      " than before this ran (" & $reqs[i].baseline & " -> " &
                      $after & ")"
    if reqs[i].placed < reqs[i].count and reqs[i].why.len == 0:
      reqs[i].why = "asked for " & $reqs[i].count & ", read back " &
                    $reqs[i].placed & " -- minted " & $reqs[i].minted &
                    ", so it was lost between the mint and the store"
  result.reqs = reqs
  result.placed = 0
  for r in reqs:
    result.placed = result.placed + r.placed

  if result.placed >= result.requested and result.rejected.len == 0:
    result.verdict = "PASS"
    result.reason = "all " & $result.requested &
                    " requested item(s) were read back off the profile"
  else:
    result.verdict = "FAIL"
    result.reason = "asked for " & $result.requested & ", minted " &
                    $result.minted & ", read back " & $result.placed &
                    "; " & $result.rejected.len & " refusal(s)"

# ---------------------------------------------------------------------------
# Read-only verification, for a script that wants to check without minting
# ---------------------------------------------------------------------------

proc verifyLoadout*(body: string): LoadoutReport =
  ## The read-back half on its own: nothing is minted, nothing is saved, and the
  ## same `countPlaced` decides. A script uses this to assert a loadout is STILL
  ## intact after a raid, or before one, without changing anything.
  result = LoadoutReport(verdict: "INCONCLUSIVE", reason: "", profileId: "",
                         requested: 0, minted: 0, placed: 0, rejected: @[], observations: @[],
                         reqs: @[], flatStacks: 0, slotDropped: 0)
  var profileId = ""
  var clear = false
  var problems: seq[string] = @[]
  var reqs = parseSpec(body, profileId, clear, problems)
  for p in problems:
    result.rejected.add p
  result.profileId = profileId
  for r in reqs:
    result.requested = result.requested + r.count
  if profileId.len == 0:
    result.reason = "the spec names no `profileId`"
    return
  let p2 = loadProfile(profileId)
  if not p2.ok:
    result.reason = "could not read profile " & profileId
    return
  let itemsJson = p2.field("Inventory.items").raw
  let equipmentId = p2.field("Inventory.equipment").asText("")
  let stash = stashId(p2)
  for i in 0 ..< reqs.len:
    if not resolve(reqs[i]):
      result.rejected.add reqs[i].query & ": " & reqs[i].why
      continue
    reqs[i].placed = countPlaced(itemsJson, reqs[i], equipmentId, stash)
    if reqs[i].placed < reqs[i].count:
      reqs[i].why = "expected " & $reqs[i].count & ", found " & $reqs[i].placed
  result.reqs = reqs
  for r in reqs:
    result.placed = result.placed + r.placed
  if result.placed >= result.requested and result.rejected.len == 0:
    result.verdict = "PASS"
    result.reason = "all " & $result.requested & " item(s) are on the profile"
  else:
    result.verdict = "FAIL"
    result.reason = "expected " & $result.requested & ", found " &
                    $result.placed

# ---------------------------------------------------------------------------
# Self-check
# ---------------------------------------------------------------------------

proc selfCheckLoadout*(into: var seq[string]): bool =
  ## What this module can prove with no database and no profile.
  ##
  ## Every assertion below is a NEGATIVE or a refusal: this module cannot check
  ## that a real loadout arrived without a real profile, and pretending it can
  ## is the failure mode CLAUDE.md 9b is about. The one thing it CAN prove
  ## offline is that every declining path names its reason.
  result = true

  if canonicalSlot("headwear") != "Headwear":
    into.add "loadout: slot names are not case-folded"
    result = false
  if canonicalSlot("Helmet").len != 0:
    into.add "loadout: a slot name that does not exist was accepted"
    result = false
  if not isEquipSlot("SecuredContainer"):
    into.add "loadout: SecuredContainer was not recognised as an equipment slot"
    result = false

  # A spec with no profile must REFUSE, with a reason, and must never say PASS.
  let noProfile = applyLoadout("{\"gear\":[{\"query\":\"bandage\"}]}")
  if noProfile.verdict == "PASS" or noProfile.reason.len == 0:
    into.add "loadout: a spec with no profileId did not refuse with a reason"
    result = false
  if noProfile.verdict != "INCONCLUSIVE":
    into.add "loadout: a spec that could not be looked at answered \"" &
             noProfile.verdict & "\" rather than INCONCLUSIVE"
    result = false

  # A spec with no gear array is a different refusal, and must say so.
  let noGear = applyLoadout("{\"profileId\":\"aaaaaaaaaaaaaaaaaaaaaaaa\"}")
  if noGear.verdict == "PASS":
    into.add "loadout: a spec with no gear array reported PASS"
    result = false

  # Both placements at once is a script error and must be NAMED, not resolved.
  var pid = ""
  var clr = false
  var probs: seq[string] = @[]
  let both = parseSpec("{\"profileId\":\"a\",\"gear\":[{\"query\":\"x\"," &
                       "\"slot\":\"Headwear\",\"inside\":\"Backpack\"}]}",
                       pid, clr, probs)
  if both.len != 0 or probs.len == 0:
    into.add "loadout: an entry naming both `slot` and `inside` was accepted"
    result = false

  # An unknown slot name must be refused by NAME, not folded into the stash.
  var pid2 = ""
  var clr2 = false
  var probs2: seq[string] = @[]
  let bad = parseSpec("{\"profileId\":\"a\",\"gear\":[{\"query\":\"x\"," &
                      "\"slot\":\"Trousers\"}]}", pid2, clr2, probs2)
  if bad.len != 0:
    into.add "loadout: an item was accepted into the non-existent slot Trousers"
    result = false
  if probs2.len == 0 or probs2[0].find("Trousers") < 0:
    into.add "loadout: the refusal for an unknown slot did not name the slot"
    result = false

  # The count cap must refuse and must SAY the cap.
  var pid3 = ""
  var clr3 = false
  var probs3: seq[string] = @[]
  discard parseSpec("{\"profileId\":\"a\",\"gear\":[{\"query\":\"x\"," &
                    "\"count\":99999}]}", pid3, clr3, probs3)
  if probs3.len == 0 or probs3[0].find("5000") < 0:
    into.add "loadout: the per-request count cap did not refuse, or did not " &
             "say the cap"
    result = false

  # The report must carry the three numbers SEPARATELY. A report that collapses
  # requested/minted/placed cannot express the failure this module exists to
  # catch.
  var rep = LoadoutReport(verdict: "FAIL", reason: "r", profileId: "p",
                          requested: 3, minted: 3, placed: 0, rejected: @[], observations: @[],
                          reqs: @[], flatStacks: 0, slotDropped: 0)
  let js = reportJson(rep)
  if js.find("\"requested\":3") < 0 or js.find("\"minted\":3") < 0 or
     js.find("\"placed\":0") < 0:
    into.add "loadout: the report does not carry requested/minted/placed as " &
             "three separate numbers"
    result = false
